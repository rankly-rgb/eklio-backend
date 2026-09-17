-- ============================================================================
-- Le sigle appartient au couple, pas au catalogue — et il peut être ABSENT
-- ============================================================================
-- `20260915122121` a posé `licensed_psychologist` avec le libellé « LP », en
-- écrivant que c'était un placeholder. La vérification l'a tranché : « LP » est
-- FAUX dans quatre États sur cinq.
--
--   TX  écrit « Licensed Psychologist (LP) »      → le sigle existe
--   CA  n'a AUCUN sigle — « PSY » est un préfixe de NUMÉRO de licence,
--       pas une abréviation du titre
--   NY  aucun sigle
--   PA  aucun sigle
--   FL  exige les mots EN TOUTES LETTRES sur toute publicité
--
-- Le même titre d'exercice, cinq façons de l'écrire. Donc :
--
--   ⚠ LE SIGLE EST UNE PROPRIÉTÉ DU COUPLE (titre, État), PAS DU TITRE.
--   C'est la même leçon que LPC/LPCC/LCPC/LMHC, d'un cran plus profond : non
--   seulement le NOM du titre change d'un État à l'autre, mais sa FORME
--   IMPRIMABLE aussi.
--
--   ⚠ ET « PAS DE SIGLE » N'EST PAS UN SIGLE VIDE. Une chaîne vide se
--   concatène, se compare à '' et finit imprimée comme « Nora Whitfield,  ».
--   L'absence est NULL, elle a un sens, et ce sens est « dans cet État, on
--   écrit les mots ».
--
-- ── CE QUE DEVIENT `license_types.label` ────────────────────────────────
--
-- Elle RESTE, bornée à 12 caractères, et elle CESSE D'ÊTRE UN CREDENTIAL.
-- Ce n'est plus « le sigle de ce titre » — cette phrase n'a pas de référent —
-- mais une POIGNÉE COURTE, interne, pour les listes d'administration et les
-- messages d'erreur. Rien de ce qu'une cliente lit ne doit en venir : ce
-- qu'on imprime est soit `license_type_states.abbreviation` (le sigle de SON
-- État), soit `license_types.description` (les mots en toutes lettres), qui
-- est vrai partout.
--
-- Le commentaire de colonne le dit, et `title_abbreviation()` en bas est ce
-- qui donne aux appelants la bonne réponse sans qu'ils aient à la composer.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Les trois colonnes du couple
-- ---------------------------------------------------------------------------
alter table public.license_type_states
  add column if not exists abbreviation text,
  add column if not exists source_url   text,
  add column if not exists note         text;

/*
 * ⚠ PAS DE CHAÎNE VIDE, JAMAIS. Sans ce CHECK, « pas de sigle » arriverait
 * tantôt en NULL tantôt en '', et les deux se liraient différemment selon
 * l'appelant — exactement le défaut permissif que ce dépôt révoque à la main.
 * Une seule façon de dire « aucun » : NULL.
 */
alter table public.license_type_states drop constraint if exists license_type_states_abbrev_check;
alter table public.license_type_states
  add constraint license_type_states_abbrev_check check (
    abbreviation is null or btrim(abbreviation) = abbreviation and abbreviation <> ''
  );

alter table public.license_type_states drop constraint if exists license_type_states_source_check;
alter table public.license_type_states
  add constraint license_type_states_source_check check (
    source_url is null or source_url ~ '^https?://'
  );

comment on column public.license_type_states.abbreviation is
  'The abbreviation this state allows in advertising, or NULL when there is none to print -- CA, NY and PA have no abbreviation for Licensed Psychologist, and FL requires the words in full on all advertising. NULL is a fact, not a gap; an empty string is forbidden by CHECK so the two can never be confused.';
comment on column public.license_type_states.source_url is
  'The board page this pair was read from. Not decoration: it is what lets someone re-check the row in two years without redoing the work.';
comment on column public.license_type_states.note is
  'The board''s own wording when it does not fit the columns -- e.g. Florida requiring full words on advertising.';

/*
 * ⚠ LE PIÈGE DE CE LOT, ÉCRIT AVANT QU'IL NE COÛTE QUELQUE CHOSE.
 *
 * `abbreviation IS NULL` veut dire DEUX choses selon `verified_at` :
 *
 *   vérifié   + NULL → cet État n'a pas de sigle imprimable. Un FAIT.
 *   non vérifié + NULL → personne n'a regardé. Une IGNORANCE.
 *
 * Les confondre imprimerait « rien » là où il fallait un sigle, ou
 * inversement. On ne résout pas ça par une convention : on le résout par la
 * fonction ci-dessous, qui ne rend un sigle QUE sur une ligne vérifiée. Et la
 * garde de vente (`state_is_sellable`) fait que le cas « non vérifié »
 * n'atteint jamais une page publique.
 */
create or replace function public.title_abbreviation(
  p_license_type_id text,
  p_state text
)
returns text
language sql
stable
security invoker
set search_path = ''
as $function$
  select s.abbreviation
    from public.license_type_states s
   where s.license_type_id = p_license_type_id
     and s.state_code = upper(btrim(coalesce(p_state, '')))
     and s.verified_at is not null
$function$;

revoke execute on function public.title_abbreviation(text, text) from public;
grant execute on function public.title_abbreviation(text, text)
  to anon, authenticated, service_role;

comment on function public.title_abbreviation(text, text) is
  'The abbreviation printable for this title in this state, or NULL. Returns NULL for an UNVERIFIED pair on purpose: nobody has read the board, so there is no answer to give -- and the caller must fall back to license_types.description, which is true everywhere.';


-- ---------------------------------------------------------------------------
-- 2. `label` cesse d'être un credential
-- ---------------------------------------------------------------------------
comment on column public.license_types.label is
  'A SHORT INTERNAL HANDLE, max 12 chars. NOT a credential and never printed to a client: "LP" is wrong in four of the five states checked first. What gets printed is license_type_states.abbreviation (her state''s, which may be NULL) or license_types.description (the words in full, true everywhere).';

/*
 * « LP » part. Ce n'était le sigle de personne — c'était une supposition, et
 * elle est fausse en CA, NY, PA et FL. La poignée devient `PSYCH`, qui ne
 * ressemble à aucun sigle de board et ne sera donc jamais pris pour un.
 */
-- >>> PSYCHOLOGIST HANDLE CORRECTION (mirrored verbatim in supabase/seed.sql) >>>

update public.license_types
   set label = 'PSYCH'
 where id = 'licensed_psychologist';

-- <<< PSYCHOLOGIST HANDLE CORRECTION <<<


-- ---------------------------------------------------------------------------
-- 3. Pennsylvanie : LSW, et pas LMSW
-- ---------------------------------------------------------------------------
/*
 * L'équivalent pennsylvanien de LMSW s'appelle « Licensed Social Worker », et
 * la Pennsylvanie ne délivre PAS de LMSW. Une ligne de catalogue de plus, pas
 * un filtrage : c'est le point que la vérification a établi et que le
 * catalogue national ne pouvait pas porter.
 *
 * ⚠ UNE SEULE JURIDICTION POSÉE ICI, ET C'EST VOULU. D'autres États délivrent
 * un LSW ; les ajouter de mémoire serait refaire l'erreur que ce lot entier
 * répare. La matrice vérifiée dira lesquels.
 */
-- >>> LSW CATALOG ROW (mirrored verbatim in supabase/seed.sql) >>>

insert into public.license_types (id, label, description, sort_order, active) values
  ('lsw', 'LSW', 'Licensed Social Worker', 10, true)
on conflict (id) do update
  set label = excluded.label,
      description = excluded.description;

insert into public.license_type_states (license_type_id, state_code) values
  ('lsw', 'PA')
on conflict do nothing;

delete from public.license_type_states
 where license_type_id = 'lmsw' and state_code = 'PA';

-- <<< LSW CATALOG ROW <<<


-- ---------------------------------------------------------------------------
-- 4. Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_n int; v_abbrev text;
begin
  -- La chaîne vide est refusée, et NULL passe : les deux moitiés.
  begin
    update public.license_type_states set abbreviation = ''
     where license_type_id = 'lcsw' and state_code = 'CA';
    raise exception 'abbrev: une chaîne vide a été acceptée comme sigle. Migration abandonnée.';
  exception when check_violation then
    null;  -- attendu
  end;

  update public.license_type_states set abbreviation = null
   where license_type_id = 'lcsw' and state_code = 'CA';

  -- ⚠ UN SIGLE NE SORT QUE D'UNE LIGNE VÉRIFIÉE. C'est la moitié qui empêche
  -- d'imprimer une supposition.
  update public.license_type_states
     set abbreviation = 'LCSW'
   where license_type_id = 'lcsw' and state_code = 'CA';

  select public.title_abbreviation('lcsw', 'CA') into v_abbrev;
  if v_abbrev is not null then
    raise exception
      'abbrev: un sigle est rendu depuis une ligne NON vérifiée (%). Migration abandonnée.', v_abbrev;
  end if;

  update public.license_type_states
     set verified_at = now(), verified_by = 'migration probe'
   where license_type_id = 'lcsw' and state_code = 'CA';

  select public.title_abbreviation('lcsw', 'CA') into v_abbrev;
  if v_abbrev <> 'LCSW' then
    raise exception
      'abbrev: une ligne vérifiée ne rend pas son sigle. Migration abandonnée.';
  end if;

  -- Et la sonde ne laisse rien derrière elle.
  update public.license_type_states
     set abbreviation = null, verified_at = null, verified_by = null
   where license_type_id = 'lcsw' and state_code = 'CA';

  select count(*) into v_n
    from public.license_type_states
   where verified_at is not null or abbreviation is not null;
  if v_n <> 0 then
    raise exception
      'abbrev: la sonde a laissé % ligne(s) marquées. Migration abandonnée.', v_n;
  end if;

  -- « LP » ne doit plus exister nulle part.
  if exists (select 1 from public.license_types where label = 'LP') then
    raise exception 'abbrev: la poignée « LP » est encore là. Migration abandonnée.';
  end if;

  -- LSW existe, en Pennsylvanie, et LMSW n'y est plus.
  if not exists (
    select 1 from public.license_type_states
     where license_type_id = 'lsw' and state_code = 'PA'
  ) then
    raise exception 'abbrev: lsw + PA manque. Migration abandonnée.';
  end if;
  if public.license_state_allowed('lmsw', 'PA') then
    raise exception
      'abbrev: la Pennsylvanie délivre encore un LMSW. Migration abandonnée.';
  end if;

  -- Et le couple du rapport reste refusé : un lot ne rouvre pas le précédent.
  if public.license_state_allowed('lmhc', 'OR') then
    raise exception 'abbrev: lmhc + OR est redevenu acceptable. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.title_abbreviation(text, text);
--   alter table public.license_type_states
--     drop column if exists abbreviation,
--     drop column if exists source_url,
--     drop column if exists note;
--   delete from public.license_type_states where license_type_id = 'lsw';
--   delete from public.license_types where id = 'lsw';
