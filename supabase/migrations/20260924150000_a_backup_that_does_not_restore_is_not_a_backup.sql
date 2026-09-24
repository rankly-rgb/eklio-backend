-- ============================================================================
-- Eklio — une sauvegarde qui ne se restaure pas n'est pas une sauvegarde
-- ============================================================================
--
-- ⚠ TROUVÉ EN RÉPÉTANT LA MISE EN PRODUCTION À BLANC, le 2026-09-24. L'étape 2
-- de la liste dit « sauvegarde de la base de production, et vérification
-- qu'elle se restaure ». Elle ne se restaure pas.
--
--   pg_restore: error: COPY failed for table "section_types":
--     violates check constraint "section_types_allowed_pages_check"
--
-- Mesuré sur la base réelle : `section_types` porte **onze** lignes et s'en
-- restaure **zéro**. Et la base restaurée paraît intacte — 89 tables, 301
-- fonctions, 210 policies, identiques de part et d'autre. Seul le compte de
-- lignes d'une table de référence diffère, et personne ne le comptait.
--
-- ── ⚠ LE MÉCANISME : UNE `CHECK` QUI LIT UNE AUTRE TABLE ────────────────
--
-- `section_types_allowed_pages_check` appelle `site_spec_page_keys()`, qui lit
-- `public.site_pages`. À la restauration, `pg_restore` copie `section_types`
-- AVANT `site_pages` — l'ordre est alphabétique, pas dépendanciel pour les
-- références passant par une fonction. La fonction rend donc un tableau vide,
-- et les onze lignes échouent une à une.
--
-- ⚠ ET AUCUNE INVOCATION DE `pg_restore` NE SAUVE ÇA. Sans
-- `--single-transaction`, la table se restaure vide en silence. AVEC, la
-- restauration entière avorte et la base est inutilisable. Une `CHECK` est
-- immédiate par construction : elle ne se diffère pas.
--
-- ── CE QUI CHANGE, ET CE QUI NE CHANGE PAS ──────────────────────────────
--
-- L'invariant est juste et il est GARDÉ : une section ne peut pas s'annoncer
-- sur une page qui n'existe pas. Ce qui change est l'endroit où il se vérifie.
--
--   ce qui reste en `CHECK`       le tableau n'est pas vide — intra-ligne,
--                                 donc restaurable par construction ;
--   ce qui devient un TRIGGER     l'appartenance aux pages de `site_pages`,
--     `DEFERRABLE INITIALLY       vérifiée au COMMIT et non à la ligne, donc
--     DEFERRED`                   satisfaite dès que les deux tables sont là.
--
-- ⚠ LA RESTAURATION SE FAIT DÉSORMAIS AVEC `--single-transaction`, et c'est
-- une consigne, pas une préférence : c'est elle qui rend le contrôle différé
-- utile. Elle est écrite dans l'étape 2 de la liste de mise en production.
--
-- ⚠ ET LE VRAI CORRECTIF DURABLE EST AILLEURS. `allowed_pages` est un
-- `text[]` ; l'invariant est une intégrité référentielle, et une clé étrangère
-- se restaure NATIVEMENT parce que `pg_dump` repose les clés étrangères APRÈS
-- toutes les données. La forme juste est une table de jointure
-- `section_type_pages(section_type_id, page_key)` avec deux clés étrangères.
-- Elle touche le code applicatif : elle est écrite dans `FOLLOWUP.md` plutôt
-- que faite ici, à la fin d'une session de sécurité.
-- ============================================================================

alter table public.section_types drop constraint if exists section_types_allowed_pages_check;

-- ⚠ Intra-ligne seulement. Rien qui lise une autre table.
alter table public.section_types
  add constraint section_types_allowed_pages_check
  check (coalesce(array_length(allowed_pages, 1), 0) > 0);

create or replace function public.section_types_pages_exist()
returns trigger
language plpgsql
set search_path to ''
as $$
declare
  v_missing text[];
begin
  select array_agg(k) into v_missing
    from unnest(new.allowed_pages) as k
   where k not in (select sp.key from public.site_pages sp);

  if v_missing is not null then
    raise exception
      'section_types.allowed_pages cite des pages qui n''existent pas dans site_pages: %',
      array_to_string(v_missing, ', ');
  end if;
  return null;
end;
$$;

comment on function public.section_types_pages_exist() is
  'Checks that allowed_pages names only pages that exist, at COMMIT rather than per row. It used to be a CHECK calling site_spec_page_keys(), and that made the database unrestorable: pg_restore copies section_types before site_pages, so the function saw no pages and all eleven rows failed -- silently, leaving a reference table empty in a backup that otherwise looked identical.';

drop trigger if exists section_types_pages_exist_trigger on public.section_types;
create constraint trigger section_types_pages_exist_trigger
  after insert or update of allowed_pages on public.section_types
  deferrable initially deferred
  for each row execute function public.section_types_pages_exist();

/*
 * ── ⚠ LA PREUVE, DANS LES DEUX SENS ─────────────────────────────────────
 *
 * Sans elle, ce fichier n'affirmerait la correction que par sa mise en page.
 */
do $$
declare
  v_pages text[];
begin
  select array_agg(key) into v_pages from public.site_pages;
  if v_pages is null then return; end if;

  -- Les lignes existantes passent encore.
  if exists (
    select 1 from public.section_types st
     where not (st.allowed_pages <@ v_pages)
  ) then
    raise exception 'une ligne de section_types cite déjà une page inexistante';
  end if;

  -- Et une page inventée est toujours refusée, au COMMIT.
  begin
    insert into public.section_types
      (id, sort_order, label, description, fields, default_enabled, allowed_pages)
    values ('__rehearsal__', 999, 'x', 'y', '[]'::jsonb, false, array['__no_such_page__']);
    -- ⚠ Le trigger est différé : il ne parle qu'ici.
    raise exception '__expected__';
  exception
    when others then
      if position('__no_such_page__' in sqlerrm) = 0 and sqlerrm <> '__expected__' then
        raise exception 'le trigger n''a pas refusé une page inventée: %', sqlerrm;
      end if;
  end;
end $$;
