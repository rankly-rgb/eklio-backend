-- ============================================================================
-- Tests — 20260915125159_the_abbreviation_belongs_to_the_pair.sql
-- ============================================================================
-- La vérification a tranché « LP » : faux dans quatre États sur cinq. Le sigle
-- appartient donc au COUPLE (titre, État), et il peut être ABSENT — ce qui
-- n'est pas un sigle vide.
--
-- ⚠ CE FICHIER GARDE SURTOUT LA DISTINCTION QUI COÛTE : `abbreviation IS NULL`
-- veut dire deux choses selon `verified_at`, et les confondre imprimerait une
-- supposition sur une page publique.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. « Pas de sigle » n'est pas « un sigle vide »
-- ---------------------------------------------------------------------------
do $$
declare v_refused boolean := false;
begin
  begin
    update public.license_type_states set abbreviation = ''
     where license_type_id = 'lcsw' and state_code = 'CA';
  exception when check_violation then v_refused := true;
  end;
  assert v_refused, 'une chaîne vide a été acceptée comme sigle';

  -- Les espaces non plus : « ' ' » se concatène comme un sigle.
  v_refused := false;
  begin
    update public.license_type_states set abbreviation = ' LCSW '
     where license_type_id = 'lcsw' and state_code = 'CA';
  exception when check_violation then v_refused := true;
  end;
  assert v_refused, 'un sigle entouré d''espaces a été accepté';

  -- Et NULL passe : c'est la façon de dire « aucun ».
  update public.license_type_states set abbreviation = null
   where license_type_id = 'lcsw' and state_code = 'CA';
end $$;

-- L'URL de source doit ressembler à une URL, ou être absente.
do $$
declare v_refused boolean := false;
begin
  begin
    update public.license_type_states set source_url = 'bbs.ca.gov'
     where license_type_id = 'lcsw' and state_code = 'CA';
  exception when check_violation then v_refused := true;
  end;
  assert v_refused, 'une source qui n''est pas une URL a été acceptée';

  update public.license_type_states
     set source_url = 'https://www.bbs.ca.gov/applicants/lcsw.html'
   where license_type_id = 'lcsw' and state_code = 'CA';
end $$;


-- ---------------------------------------------------------------------------
-- 2. ⚠ UN SIGLE NE SORT QUE D'UNE LIGNE VÉRIFIÉE
-- ---------------------------------------------------------------------------
/*
 * C'est LA règle de ce lot. Une ligne non vérifiée peut porter un sigle
 * pré-rempli — la table arrive d'un tableur — et ce sigle n'est PAS une
 * réponse tant que personne n'a lu le board. `title_abbreviation` rend NULL,
 * et l'appelant retombe sur les mots en toutes lettres, vrais partout.
 */
do $$
declare v_abbrev text;
begin
  update public.license_type_states
     set abbreviation = 'LCSW'
   where license_type_id = 'lcsw' and state_code = 'CA';

  select public.title_abbreviation('lcsw', 'CA') into v_abbrev;
  assert v_abbrev is null,
    format('un sigle (%s) est sorti d''une ligne NON vérifiée', v_abbrev);

  update public.license_type_states
     set verified_at = now(), verified_by = 'test'
   where license_type_id = 'lcsw' and state_code = 'CA';

  select public.title_abbreviation('lcsw', 'CA') into v_abbrev;
  assert v_abbrev = 'LCSW',
    'une ligne vérifiée ne rend pas son sigle : la porte est un mur';
end $$;

/*
 * ⚠ ET UNE LIGNE VÉRIFIÉE SANS SIGLE REND NULL, PAS UNE ERREUR. C'est le cas
 * de la Californie, de New York et de la Pennsylvanie pour « Licensed
 * Psychologist », et celui de la Floride qui exige les mots en toutes lettres.
 * Ne rien avoir à imprimer est une réponse.
 */
do $$
declare v_abbrev text;
begin
  update public.license_type_states
     set abbreviation = null, verified_at = now(), verified_by = 'test',
         note = 'No abbreviation; PSY is a licence-number prefix, not a title.'
   where license_type_id = 'licensed_psychologist' and state_code = 'CA';

  select public.title_abbreviation('licensed_psychologist', 'CA') into v_abbrev;
  assert v_abbrev is null, 'un sigle est apparu là où il n''y en a pas';

  -- La ligne existe pourtant, et le titre est bien délivré en Californie.
  assert public.license_state_allowed('licensed_psychologist', 'CA'),
    'le psychologue n''exerce plus en Californie';
end $$;

-- Un couple inexistant rend NULL aussi, sans lever.
do $$
begin
  assert public.title_abbreviation('lmhc', 'OR') is null,
    'un couple impossible a rendu un sigle';
  assert public.title_abbreviation(null, 'CA') is null,
    'un titre absent a rendu un sigle';
  assert public.title_abbreviation('lcsw', null) is null,
    'un État absent a rendu un sigle';
end $$;


-- ---------------------------------------------------------------------------
-- 3. `label` n'est plus un credential
-- ---------------------------------------------------------------------------
do $$
begin
  -- « LP » était une supposition, fausse en CA, NY, PA et FL.
  assert not exists (select 1 from public.license_types where label = 'LP'),
    'la poignée « LP » est encore au catalogue';
  assert (select label from public.license_types where id = 'licensed_psychologist')
         = 'PSYCH',
    'la poignée du psychologue n''est pas celle attendue';

  -- L'intitulé complet, lui, reste vrai partout : c'est le repli.
  assert (select description from public.license_types where id = 'licensed_psychologist')
         = 'Licensed Psychologist',
    'l''intitulé du psychologue a bougé';
end $$;


-- ---------------------------------------------------------------------------
-- 4. Pennsylvanie : LSW oui, LMSW non
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('ffffffff-0000-0000-0000-00000000f001', 'pa@example.com');
insert into public.projects (id, user_id, name) values
  ('ffffffff-0000-4000-8000-000000000001', 'ffffffff-0000-0000-0000-00000000f001', 'PA');
insert into public.project_briefs (project_id) values
  ('ffffffff-0000-4000-8000-000000000001');

do $$
declare v_refused boolean := false;
begin
  assert public.license_state_allowed('lsw', 'PA'),
    'la Pennsylvanie ne délivre pas de LSW';
  assert not public.license_state_allowed('lmsw', 'PA'),
    'la Pennsylvanie délivre encore un LMSW';

  -- Et le refus est réel, à l'écriture, pas seulement dans le prédicat.
  begin
    update public.project_briefs set license_type_id = 'lmsw', state = 'PA'
     where project_id = 'ffffffff-0000-4000-8000-000000000001';
  exception when others then v_refused := true;
  end;
  assert v_refused, 'un brief LMSW en Pennsylvanie a été écrit';

  update public.project_briefs set license_type_id = 'lsw', state = 'PA'
   where project_id = 'ffffffff-0000-4000-8000-000000000001';
  assert (select license_type_id from public.project_briefs
           where project_id = 'ffffffff-0000-4000-8000-000000000001') = 'lsw',
    'un brief LSW en Pennsylvanie a été refusé';
end $$;


-- ---------------------------------------------------------------------------
-- 5. La surface
-- ---------------------------------------------------------------------------
do $$
begin
  assert has_function_privilege('anon', 'public.title_abbreviation(text, text)', 'execute'),
    'le sigle n''est pas lisible par un brief anonyme';
  assert has_function_privilege(
    'authenticated', 'public.title_abbreviation(text, text)', 'execute'),
    'le sigle n''est pas lisible par une session';
end $$;

rollback;

-- Rien n'a fui hors de la transaction : la matrice reste non vérifiée.
do $$
declare v_n int;
begin
  select count(*) into v_n
    from public.license_type_states
   where verified_at is not null or abbreviation is not null;
  assert v_n = 0,
    format('le test a laissé %s ligne(s) marquées hors de sa transaction', v_n);
end $$;
