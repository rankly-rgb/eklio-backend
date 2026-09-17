-- ============================================================================
-- Les pages deviennent une donnée
-- ============================================================================
-- `site_spec_page_keys()` rendait `array['home','about','services','contact']`,
-- écrit en dur. The Foundation y tient tout juste — « l'accroche de son site +
-- 3 pages ». The Fill, qui ajoute UNE PAGE PAR MOIS en requête-patient, n'y
-- tient pas du tout : à la cinquième page, `site_spec_pages_valid` refuse
-- d'écrire.
--
-- ── LE RECENSEMENT, FAIT AVANT DE TOUCHER À QUOI QUE CE SOIT ────────────────
--
-- Quatre fonctions nomment une clé de page ou lisent la source (interrogé sur
-- `pg_proc`, pas deviné) :
--
--   site_spec_page_keys()        LA SOURCE — liste en dur      → devient une lecture
--   site_spec_pages_valid(jsonb) lit la source                 → inchangé, déjà juste
--   site_spec_default_pages(…)   nomme les quatre par défaut   → inchangé, c'est un SEMEUR
--   site_spec_section_types()    ne nomme aucune page          → hors sujet ici
--
-- Plus une DONNÉE qui les nomme : `section_types.allowed_pages`.
--
-- ⚠ `site_spec_default_pages` GARDE SA LISTE, ET CE N'EST PAS UNE EXCEPTION
-- QU'ON S'ACCORDE. Cette fonction ne VALIDE rien : elle construit les pages
-- initiales avec leurs sections, leurs libellés et leur ordre. « Quelles pages
-- existent » et « par quelles pages on commence » sont deux questions
-- différentes, et confondre les deux voudrait dire qu'ajouter une page
-- mensuelle au catalogue l'ajoute aussi à tous les nouveaux sites. Ce que la
-- garde ci-dessous exige d'elle, c'est que les pages qu'elle sème EXISTENT.
--
-- ── CE QUI CHANGE DE CATÉGORIE ──────────────────────────────────────────────
--
-- `site_spec_page_keys` passe d'IMMUTABLE à STABLE : elle lit une table. Et
-- `site_spec_pages_valid` doit suivre, parce qu'une fonction IMMUTABLE qui
-- appelle une STABLE est un mensonge que PostgreSQL ne vérifie pas et dont il
-- se sert quand même (mise en cache, planification).
--
-- ⚠ CE QUE ÇA IMPLIQUE POUR LE CHECK, et il faut le dire : le CHECK de
-- `site_specs.pages` est évalué À L'ÉCRITURE, contre la table telle qu'elle est
-- à ce moment-là. Les lignes déjà écrites ne sont pas revalidées quand on
-- ajoute une page. C'est exactement le comportement voulu — une page ajoutée
-- devient écrivable tout de suite, et rien de ce qui existe ne casse — mais
-- cela veut dire aussi qu'on ne peut pas RETIRER une clé de page sans que des
-- lignes valides hier deviennent non modifiables aujourd'hui. D'où la garde de
-- retrait en fin de fichier.
-- ============================================================================

create table if not exists public.site_pages (
  key         text        not null,
  label       text        not null,
  sort_order  smallint    not null,
  created_at  timestamptz not null default now(),
  constraint site_pages_pkey primary key (key),
  -- La clé est un identifiant, pas une phrase : elle entre dans une URL, dans
  -- un `key` de jsonb et dans un nom de fichier.
  constraint site_pages_key_check   check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  constraint site_pages_label_check check (btrim(label) <> '')
);

comment on table public.site_pages is
  'Which page keys a site specification may carry. THE single source: site_spec_page_keys() reads it, and site_spec_pages_valid() reads that. Adding a page is an INSERT - which is what The Fill needs, since it adds one page a month and the previous four-value hard-coded list refused the fifth.';

alter table public.site_pages enable row level security;

drop policy if exists site_pages_select_all on public.site_pages;
create policy site_pages_select_all on public.site_pages
  for select to anon, authenticated using (true);
drop policy if exists site_pages_insert_denied on public.site_pages;
create policy site_pages_insert_denied on public.site_pages for insert with check (false);
drop policy if exists site_pages_update_denied on public.site_pages;
create policy site_pages_update_denied on public.site_pages for update using (false);
drop policy if exists site_pages_delete_denied on public.site_pages;
create policy site_pages_delete_denied on public.site_pages for delete using (false);

grant select on public.site_pages to anon, authenticated;

-- >>> SITE PAGE DATA (mirrored verbatim in supabase/seed.sql) >>>

-- Les quatre d'aujourd'hui, à l'identique. Ce lot OUVRE la liste ; il n'ajoute
-- aucune page, parce qu'aucune page mensuelle n'est encore produite et qu'une
-- clé au catalogue que rien ne remplit est une promesse vide.
insert into public.site_pages (key, label, sort_order) values
  ('home',     'Home',     1),
  ('about',    'About',    2),
  ('services', 'Services', 3),
  ('contact',  'Contact',  4)
on conflict (key) do update set
  label = excluded.label, sort_order = excluded.sort_order;

-- <<< SITE PAGE DATA <<<

-- ── La source, qui lit désormais ────────────────────────────────────────────

create or replace function public.site_spec_page_keys()
returns text[]
language sql
stable
set search_path to ''
as $$
  select coalesce(
           (select array_agg(sp.key order by sp.sort_order, sp.key)
              from public.site_pages sp),
           array[]::text[]
         )
$$;

comment on function public.site_spec_page_keys() is
  'The page keys a site specification may carry, read from site_pages. STABLE rather than IMMUTABLE because it reads a table - and site_spec_pages_valid follows, since an IMMUTABLE function calling a STABLE one is a lie Postgres does not check and does use.';

-- ⚠ MÊME CORPS, CATÉGORIE CHANGÉE. Le corps est recopié à l'identique plutôt
-- que modifié : ce lot ouvre une liste, il ne rouvre pas une validation qui
-- marche. La seule différence est `stable` au lieu d'`immutable`.
create or replace function public.site_spec_pages_valid(p jsonb)
returns boolean
language sql
stable
set search_path to ''
as $$
  select case
    when p is null then false
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) = 0 then false
    else
      not exists (
        select 1 from jsonb_array_elements(p) as pg
        where jsonb_typeof(pg.value) <> 'object'
           or not (pg.value->>'key' = any (public.site_spec_page_keys()))
           or jsonb_typeof(pg.value->'label')    is distinct from 'string'
           or jsonb_typeof(pg.value->'enabled')  is distinct from 'boolean'
           or jsonb_typeof(pg.value->'sections') is distinct from 'array'
           or exists (
             select 1 from jsonb_array_elements(pg.value->'sections') as s
             where jsonb_typeof(s.value) <> 'object'
                or jsonb_typeof(s.value->'key')  is distinct from 'string'
                or btrim(coalesce(s.value->>'key', '')) = ''
                or not (s.value->>'type' = any (public.site_spec_section_types()))
                or jsonb_typeof(s.value->'enabled') is distinct from 'boolean'
                or jsonb_typeof(s.value->'order')   is distinct from 'number'
                or (s.value->>'order')::numeric <> trunc((s.value->>'order')::numeric)
                or jsonb_typeof(s.value->'fields')  is distinct from 'object'
           )
           -- A section key is the handle the frontend edits by. Two sections
           -- sharing one inside a page make an edit ambiguous.
           or (select count(distinct s.value->>'key')
                 from jsonb_array_elements(pg.value->'sections') s)
              <> jsonb_array_length(pg.value->'sections')
      )
      -- and one page per key, for the same reason
      and (select count(distinct pg.value->>'key') from jsonb_array_elements(p) pg)
          = jsonb_array_length(p)
  end
$$;

-- ── La garde : aucune liste en dur ailleurs ─────────────────────────────────
--
-- ⚠ ELLE EST ÉCRITE COMME UN REGISTRE, PAS COMME UNE LISTE. Une fonction qui
-- nomme une clé de page doit soit lire la source, soit être inscrite ici AVEC
-- SA RAISON. `20260911170458` a établi la forme et la phrase qui va avec : un
-- nom sans raison est précisément ce que ce genre de fichier existe pour
-- empêcher.

do $$
declare
  v_offenders text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_offenders
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     -- Elle nomme une clé de page…
     and exists (
       select 1 from public.site_pages sp
        where pg_get_functiondef(p.oid) ~ ('''' || sp.key || '''')
     )
     -- …sans lire la source…
     and pg_get_functiondef(p.oid) !~ 'site_spec_page_keys'
     -- …et sans être inscrite.
     and p.proname not in (
       /*
        * `site_spec_default_pages` — LE SEMEUR. Elle construit les pages
        * initiales d'un nouveau site, avec leurs sections, leurs libellés et
        * leur ordre. « Quelles pages peuvent exister » et « par quelles pages
        * on commence » sont deux questions différentes : les confondre
        * voudrait dire qu'ajouter une page mensuelle au catalogue l'ajoute
        * aussi à tous les nouveaux sites. Ce que la garde du dessous exige
        * d'elle, c'est que les pages qu'elle sème existent — ce qui est la
        * vraie contrainte, et elle est vérifiée.
        */
       'site_spec_default_pages',

       /*
        * `site_spec_section_types` — ⚠ UNE COLLISION DE VOCABULAIRE, PAS UNE
        * LISTE DE PAGES. Elle rend les onze TYPES DE SECTION, et deux d'entre
        * eux s'appellent `contact` et `services` — les mêmes mots que deux
        * clés de page, parce qu'une page « Contact » contient une section
        * « Contact ». Elle ne nomme aucune page.
        *
        * C'est la limite de cette garde, et elle est dite plutôt que masquée :
        * elle cherche des LITTÉRAUX, et un littéral ne porte pas ce qu'il
        * désigne. La rendre plus fine (analyser le contexte d'appel) la
        * rendrait fragile pour un gain nul ; l'inscription, avec cette
        * raison-ci, coûte une ligne et se relit.
        *
        * Ce qui la protège vraiment est ailleurs : `site_spec_pages_valid` ne
        * compare jamais un type de section à une clé de page, et l'inverse non
        * plus — les deux listes sont lues par deux fonctions distinctes, sur
        * deux champs distincts du jsonb.
        */
       'site_spec_section_types'
     );

  if v_offenders is not null then
    raise exception
      'fonction(s) portant leur propre liste de pages au lieu de lire site_spec_page_keys(): %. Faites-les lire la source, ou inscrivez-les dans cette garde AVEC LA RAISON.',
      v_offenders;
  end if;
end $$;

-- ── Auto-contrôle ──────────────────────────────────────────────────────────

do $$
declare
  v_keys  text[];
  v_page  text;
  v_spec  jsonb;
  v_extra text[];
begin
  -- La source rend ce que la table porte.
  v_keys := public.site_spec_page_keys();
  if v_keys is distinct from array['home','about','services','contact'] then
    raise exception 'site_spec_page_keys() ne rend pas les quatre pages de site_pages : %', v_keys;
  end if;

  -- ⚠ ET ELLE N'EST PLUS FERMÉE. La preuve est faite en AJOUTANT une page et
  -- en vérifiant qu'une spec qui la porte devient valide — puis en défaisant.
  -- Relire la définition de la fonction n'aurait rien prouvé : c'est
  -- exactement l'erreur du garde-fou de `20260910144421`, qui décrivait son
  -- intention au lieu de parcourir son chemin.
  v_spec := jsonb_build_array(jsonb_build_object(
    'key', 'anxiety_therapy_portland', 'label', 'Anxiety therapy in Portland',
    'enabled', true,
    'sections', jsonb_build_array(jsonb_build_object(
      'key','intro','type','intro','enabled',true,'order',1,'fields','{}'::jsonb))));

  if public.site_spec_pages_valid(v_spec) then
    raise exception 'une page absente du catalogue est déjà acceptée';
  end if;

  insert into public.site_pages (key, label, sort_order)
  values ('anxiety_therapy_portland', 'Probe', 99);

  if not public.site_spec_pages_valid(v_spec) then
    raise exception
      'une page ajoutée au catalogue reste refusée : la liste n''est pas réellement ouverte';
  end if;

  delete from public.site_pages where key = 'anxiety_therapy_portland';

  if public.site_spec_pages_valid(v_spec) then
    raise exception 'une page retirée du catalogue reste acceptée';
  end if;

  -- Les pages que le semeur pose doivent exister.
  for v_page in
    select value ->> 'key'
      from jsonb_array_elements(public.site_spec_default_pages(array[]::text[], array[]::text[]))
  loop
    if not (v_page = any (public.site_spec_page_keys())) then
      raise exception 'site_spec_default_pages sème "%" qui n''est pas dans site_pages', v_page;
    end if;
  end loop;

  -- Et `section_types.allowed_pages`, qui est la DONNÉE qui nomme des pages.
  -- ⚠ `allowed_pages` EST UN `text[]`, PAS UN jsonb. Trouvé en exécutant :
  -- `jsonb_array_elements(text[])` n'existe pas, et la lecture JSON de la
  -- colonne — qui rend bien `["home"]` — donnait exactement l'impression
  -- inverse.
  select array_agg(distinct page) into v_extra
    from public.section_types st,
         lateral unnest(st.allowed_pages) as page
   where not (page = any (public.site_spec_page_keys()));

  if v_extra is not null then
    raise exception
      'section_types.allowed_pages nomme des pages absentes de site_pages : %', v_extra;
  end if;

  -- ⚠ ET LA GARDE DE RETRAIT. Le CHECK n'est évalué qu'à l'écriture : retirer
  -- une clé rend non modifiables des lignes valides hier. On refuse donc de
  -- laisser partir une page qu'une spec porte encore.
  select array_agg(distinct value ->> 'key') into v_extra
    from public.site_specs ss, lateral jsonb_array_elements(ss.pages)
   where not (value ->> 'key' = any (public.site_spec_page_keys()));

  if v_extra is not null then
    raise exception
      'des specs portent des pages absentes de site_pages (%) : elles ne seraient plus modifiables',
      v_extra;
  end if;
end $$;
