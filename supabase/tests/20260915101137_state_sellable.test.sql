-- ============================================================================
-- Tests — 20260915101137_an_unverified_state_is_not_sellable.sql
-- ============================================================================
-- La migration précédente a écrit « cette matrice n'est pas vérifiée, à relire
-- avant la mise en vente ». Un commentaire ne vérifie rien. Celle-ci en fait
-- une garde, et ce fichier prouve qu'elle mord dans LES DEUX SENS — une
-- fonction qui rendrait toujours faux passerait toute la moitié « refuse ».
--
-- ⚠ CE FICHIER MODIFIE `verified_at` PUIS ROLLBACK. Rien n'est vérifié pour de
-- vrai ici : marquer une juridiction dans un test serait exactement la copie à
-- côté de la source qu'on refuse. La section 4 le prouve.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. Aujourd'hui, rien n'est ouvert
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from public.license_type_states where verified_at is not null;
  assert v_n = 0, format('%s ligne(s) sont marquées vérifiées sans que personne ne l''ait fait', v_n);

  select count(*) into v_n from public.sellable_states where sellable;
  assert v_n = 0, format('%s État(s) sont ouverts alors qu''aucune ligne n''est vérifiée', v_n);

  assert not public.state_is_sellable('OR'), 'OR est vendable sans vérification';
  assert not public.state_is_sellable('NY'), 'NY est vendable sans vérification';

  -- Ne rien savoir n'est pas « tout est permis ».
  assert not public.state_is_sellable('ZZ'), 'un État inconnu est vendable';
end $$;

-- ---------------------------------------------------------------------------
-- 2. ⚠ ET LA GARDE S'OUVRE QUAND ON VÉRIFIE
-- ---------------------------------------------------------------------------
/*
 * Sans cette section, `state_is_sellable` pourrait rendre `false` en toutes
 * circonstances et la section 1 serait verte. C'est la moitié qui prouve que
 * la porte est une porte et pas un mur.
 */
do $$
declare v_n int;
begin
  update public.license_type_states
     set verified_at = now(), verified_by = 'test'
   where state_code = 'OR';

  assert public.state_is_sellable('OR'), 'OR reste fermé alors que toutes ses lignes sont vérifiées';
  assert not public.state_is_sellable('NY'), 'vérifier OR a ouvert NY';

  select count(*) into v_n from public.sellable_states where sellable;
  assert v_n = 1, format('la vue compte %s États ouverts, attendu 1', v_n);

  -- ⚠ « PRESQUE VÉRIFIÉ » N'OUVRE RIEN. Une seule ligne manquante referme
  -- l'État : c'est l'écran 1 qui propose les titres, et il les propose tous.
  update public.license_type_states
     set verified_at = null, verified_by = null
   where state_code = 'OR' and license_type_id = 'lpc';

  assert not public.state_is_sellable('OR'),
    'OR reste ouvert alors qu''une de ses lignes n''est pas vérifiée';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Un brief sans État, et un projet sans brief
-- ---------------------------------------------------------------------------
/*
 * ⚠ UN ÉTAT VIDE EST VENDABLE, et c'est une DÉCISION : aucune juridiction
 * n'est revendiquée, donc aucun couple n'est à vérifier, et « je suis LPC »
 * sans État n'affirme rien de faux. Le jour où le produit déduit un État de la
 * ville, cette ligne devient fausse et doit tomber avec.
 *
 * ⚠ UN PROJET SANS BRIEF N'EST PAS VENDABLE. Répondre oui à une question qu'on
 * n'a pas pu lire est exactement la forme du défaut d'origine.
 */
insert into auth.users (id, email) values
  ('eeeeeeee-0000-0000-0000-00000000e001', 'sellable@example.com');

insert into public.projects (id, user_id, name) values
  ('eeeeeeee-0000-4000-8000-000000000001', 'eeeeeeee-0000-0000-0000-00000000e001', 'sans État'),
  ('eeeeeeee-0000-4000-8000-000000000002', 'eeeeeeee-0000-0000-0000-00000000e001', 'en Oregon'),
  ('eeeeeeee-0000-4000-8000-000000000003', 'eeeeeeee-0000-0000-0000-00000000e001', 'sans brief');

insert into public.project_briefs (project_id, license_type_id, state) values
  ('eeeeeeee-0000-4000-8000-000000000001', 'lpc', null),
  ('eeeeeeee-0000-4000-8000-000000000002', 'lpc', 'OR');

do $$
begin
  assert public.state_is_sellable(null), 'un brief sans État est déclaré invendable';
  assert public.state_is_sellable('   '), 'un État blanc est traité comme un État';

  assert public.project_state_is_sellable('eeeeeeee-0000-4000-8000-000000000001'),
    'un projet dont le brief n''a pas d''État est invendable';
  assert not public.project_state_is_sellable('eeeeeeee-0000-4000-8000-000000000002'),
    'un projet en Oregon non vérifié est vendable';
  assert not public.project_state_is_sellable('eeeeeeee-0000-4000-8000-000000000003'),
    'un projet SANS BRIEF est déclaré vendable';
  assert not public.project_state_is_sellable('eeeeeeee-0000-4000-8000-0000000000ff'),
    'un projet inexistant est déclaré vendable';
end $$;

-- ---------------------------------------------------------------------------
-- 4. La surface
-- ---------------------------------------------------------------------------
do $$
begin
  -- L'écran lit la vue : elle doit être lisible par les deux rôles du brief.
  assert has_table_privilege('anon', 'public.sellable_states', 'select'),
    'la vue des États ouverts n''est pas lisible par un brief anonyme';
  assert has_table_privilege('authenticated', 'public.sellable_states', 'select'),
    'la vue des États ouverts n''est pas lisible par une session';

  assert has_function_privilege('anon', 'public.state_is_sellable(text)', 'execute'),
    'le prédicat n''est pas appelable';
  assert has_function_privilege(
    'authenticated', 'public.project_state_is_sellable(uuid)', 'execute'),
    'le prédicat par projet n''est pas appelable par une session';
end $$;

rollback;

-- ⚠ APRÈS LE ROLLBACK : la matrice est intacte. La section 2 a marqué des
-- lignes comme vérifiées pour prouver que la porte s'ouvre ; aucune ne l'est
-- restée, et c'est ce que la requête suivante établit plutôt que de le
-- supposer.
do $$
declare v_n int;
begin
  select count(*) into v_n from public.license_type_states where verified_at is not null;
  assert v_n = 0,
    format('le test a laissé %s ligne(s) marquées vérifiées hors de sa transaction', v_n);
end $$;
