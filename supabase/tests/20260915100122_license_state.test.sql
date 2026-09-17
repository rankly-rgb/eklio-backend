-- ============================================================================
-- Tests — 20260915100122_a_title_a_state_does_not_issue.sql
-- ============================================================================
-- LA SONDE DEMANDÉE : un brief avec État = OR et titre = LMHC doit passer au
-- rouge. Pas « la fonction rend faux » — une ÉCRITURE, refusée, par le chemin
-- qu'emprunte l'autosave de l'écran 1.
--
-- ⚠ ET SON CONTRAIRE, À CHAQUE FOIS. Une matrice qui refuserait TOUT passerait
-- la moitié rouge de ce fichier sans en rater une ligne. Chaque refus est donc
-- accompagné de l'acceptation qui prouve qu'on n'a pas simplement fermé la
-- porte.
--
-- ⚠ LA MATRICE ELLE-MÊME N'EST PAS VÉRIFIÉE BOARD PAR BOARD (voir l'en-tête de
-- la migration). Ce fichier prouve le MÉCANISME et les quelques couples dont
-- le rapport dépend, pas les 290 lignes.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('dddddddd-0000-0000-0000-00000000d001', 'or@example.com');

insert into public.projects (id, user_id, name) values
  ('dddddddd-0000-4000-8000-000000000001', 'dddddddd-0000-0000-0000-00000000d001', 'Oregon');

insert into public.project_briefs (project_id) values
  ('dddddddd-0000-4000-8000-000000000001');


-- ---------------------------------------------------------------------------
-- 1. ⚠ LE DÉFAUT SIGNALÉ, À L'ÉCRITURE
-- ---------------------------------------------------------------------------
/*
 * « Licensed Mental Health Counselor (LMHC) in Portland, Oregon » est parti en
 * production parce que CETTE écriture-ci était acceptée. C'est elle qu'on
 * refuse, et c'est elle qu'on teste — pas le prédicat tout seul, qui pourrait
 * être juste sans que le trigger soit posé.
 */
do $$
declare v_refused boolean := false; v_msg text;
begin
  begin
    update public.project_briefs
       set license_type_id = 'lmhc', state = 'OR', city = 'Portland'
     where project_id = 'dddddddd-0000-4000-8000-000000000001';
  exception when others then
    v_refused := true;
    v_msg := sqlerrm;
  end;

  assert v_refused, 'lmhc + OR a été ÉCRIT. Le titre faux repart en production.';
  assert v_msg like '%license_state_mismatch%',
    format('refusé, mais pas par la bonne garde : %s', v_msg);

  -- Rien n'est resté : un refus qui écrirait la moitié serait pire que rien.
  assert (select license_type_id from public.project_briefs
           where project_id = 'dddddddd-0000-4000-8000-000000000001') is null,
    'le titre refusé a quand même été posé';
end $$;


-- ---------------------------------------------------------------------------
-- 2. ⚠ ET LE COUPLE LÉGITIME PASSE
-- ---------------------------------------------------------------------------
-- L'Oregon délivre bien un LPC. Sans cette moitié, « tout refuser » serait
-- vert.
do $$
begin
  update public.project_briefs
     set license_type_id = 'lpc', state = 'OR', city = 'Portland'
   where project_id = 'dddddddd-0000-4000-8000-000000000001';

  assert (select license_type_id from public.project_briefs
           where project_id = 'dddddddd-0000-4000-8000-000000000001') = 'lpc',
    'lpc + OR a été refusé : la matrice refuse tout';
end $$;

-- Et le même titre LMHC passe là où il existe vraiment.
do $$
begin
  update public.project_briefs
     set license_type_id = 'lmhc', state = 'NY', city = 'Brooklyn'
   where project_id = 'dddddddd-0000-4000-8000-000000000001';

  assert (select state from public.project_briefs
           where project_id = 'dddddddd-0000-4000-8000-000000000001') = 'NY',
    'lmhc + NY a été refusé';
end $$;


-- ---------------------------------------------------------------------------
-- 3. Les chemins par lesquels le couple pourrait rentrer autrement
-- ---------------------------------------------------------------------------
/*
 * ⚠ LE TRIGGER EST SUR `UPDATE OF license_type_id, state`. Changer l'ÉTAT
 * seul, en laissant le titre en place, est exactement la façon dont le couple
 * redeviendrait impossible sans que le titre bouge — et c'est le cas qu'un
 * trigger mal colonné raterait.
 */
do $$
declare v_refused boolean := false;
begin
  -- On est en lmhc + NY. Déménager en Oregon doit être refusé.
  begin
    update public.project_briefs set state = 'OR'
     where project_id = 'dddddddd-0000-4000-8000-000000000001';
  exception when others then v_refused := true;
  end;
  assert v_refused, 'changer seulement l''État a fait passer lmhc en Oregon';
end $$;

-- Et l'INSERT, pas seulement l'UPDATE : un brief peut naître faux.
do $$
declare v_refused boolean := false;
begin
  insert into public.projects (id, user_id, name) values
    ('dddddddd-0000-4000-8000-000000000002',
     'dddddddd-0000-0000-0000-00000000d001', 'Insert');

  begin
    insert into public.project_briefs (project_id, license_type_id, state)
    values ('dddddddd-0000-4000-8000-000000000002', 'lmhc', 'OR');
  exception when others then v_refused := true;
  end;
  assert v_refused, 'un brief est NÉ avec lmhc + OR';
end $$;

-- La casse ne décide de rien : `state` garde ce qu'elle a tapé.
do $$
declare v_refused boolean := false;
begin
  begin
    update public.project_briefs set license_type_id = 'lmhc', state = 'or'
     where project_id = 'dddddddd-0000-4000-8000-000000000001';
  exception when others then v_refused := true;
  end;
  assert v_refused, '« or » en minuscules a fait passer lmhc';
end $$;


-- ---------------------------------------------------------------------------
-- 4. Un brief INCOMPLET n'est pas un brief FAUX
-- ---------------------------------------------------------------------------
/*
 * Le cas qui casserait le produit si on le ratait : l'écran 1 écrit champ par
 * champ, par autosave. Elle tape son État avant de choisir son titre, ou
 * l'inverse. Aucun de ces états intermédiaires ne doit lever — c'est l'étape 1
 * qui dit ce qui manque, avec sa phrase, pas un trigger avec la sienne.
 */
do $$
begin
  update public.project_briefs
     set license_type_id = null, state = null
   where project_id = 'dddddddd-0000-4000-8000-000000000001';

  -- L'État seul.
  update public.project_briefs set state = 'OR'
   where project_id = 'dddddddd-0000-4000-8000-000000000001';

  -- Puis le titre, compatible.
  update public.project_briefs set license_type_id = 'lpc'
   where project_id = 'dddddddd-0000-4000-8000-000000000001';

  -- Et l'ordre inverse, sur un brief remis à zéro.
  update public.project_briefs set license_type_id = null, state = null
   where project_id = 'dddddddd-0000-4000-8000-000000000001';
  update public.project_briefs set license_type_id = 'lmhc'
   where project_id = 'dddddddd-0000-4000-8000-000000000001';

  assert (select license_type_id from public.project_briefs
           where project_id = 'dddddddd-0000-4000-8000-000000000001') = 'lmhc',
    'un titre sans État a été refusé — l''autosave ne pourrait plus écrire';
end $$;


-- ---------------------------------------------------------------------------
-- 5. Le catalogue, et la surface qu'il expose
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  /*
   * ⚠ ANTI-VACUITÉ DÉRIVÉE, PAS UN NOMBRE ÉCRIT EN DUR. Un plancher figé était
   * ici (250) et il est devenu faux le jour où `psyd`/`phd` ont quitté les
   * licences pour devenir des diplômes : 290 lignes sont tombées à 239 et le
   * test a viré au rouge sur un défaut qui n'existait pas. C'est la même
   * famille que les trois défauts de la semaine, dans ce fichier.
   *
   * Ce qu'on veut prouver n'est pas « combien de lignes » mais « c'est une
   * MATRICE, pas un produit cartésien » — car un cross join rendrait tous les
   * États identiques et ferait passer chaque assertion « tel titre est
   * délivré ici ». Donc : les 51 juridictions sont couvertes, et elles ne
   * délivrent PAS toutes le même nombre de titres.
   */
  select count(distinct state_code) into v_n from public.license_type_states;
  assert v_n = 51, format('la matrice ne couvre que %s juridictions', v_n);

  select count(distinct c) into v_n
    from (select count(*) as c from public.license_type_states group by state_code) t;
  assert v_n > 1,
    'toutes les juridictions délivrent le même nombre de titres : c''est un produit cartésien, pas une matrice';

  -- Les dix titres du catalogue y figurent tous : un titre proposé à l'écran 1
  -- sans aucune juridiction serait un titre impossible à choisir partout.
  select count(*) into v_n
    from public.license_types lt
   where not exists (
     select 1 from public.license_type_states s where s.license_type_id = lt.id
   );
  assert v_n = 0, format('%s titre(s) du catalogue ne sont délivrés nulle part', v_n);

  -- ⚠ ET LA LIGNE DU RAPPORT, NOMMÉE. Si quelqu'un ajoute un jour ('lmhc','OR')
  -- « pour débloquer un test », c'est ici que ça se voit.
  assert not exists (
    select 1 from public.license_type_states
     where license_type_id = 'lmhc' and state_code = 'OR'
  ), 'la matrice porte lmhc + OR. L''Oregon délivre un LPC.';
  assert exists (
    select 1 from public.license_type_states
     where license_type_id = 'lpc' and state_code = 'OR'
  ), 'la matrice ne porte pas lpc + OR';
end $$;

-- La fonction de trigger n'est pas une RPC : elle est appelée par la base.
do $$
begin
  assert not has_function_privilege(
    'anon', 'public.project_briefs_license_state_gate()', 'execute'),
    'la fonction de trigger est exposée à anon';
  assert not has_function_privilege(
    'authenticated', 'public.project_briefs_license_state_gate()', 'execute'),
    'la fonction de trigger est exposée à une session';

  -- Le prédicat, lui, DOIT être appelable : l'écran 1 filtre ses puces avec.
  assert has_function_privilege(
    'anon', 'public.license_state_allowed(text, text)', 'execute'),
    'le prédicat n''est pas appelable par un brief anonyme';
end $$;

-- Le catalogue se lit comme les autres : une session oui, un anonyme sans
-- jeton non.
do $$
declare v_n int; v_total int;
begin
  /*
   * ⚠ ON COMPARE À LA MATRICE, PAS À UN NOMBRE. Un plancher écrit en dur était
   * ici et il a viré au rouge le jour où `psyd`/`phd` sont devenus des
   * diplômes — sur un défaut qui n'existait pas. Ce qui compte est que la
   * session voie TOUT, et l'anonyme sans jeton RIEN.
   */
  select count(*) into v_total from public.license_type_states;
  assert v_total > 51,
    'la matrice est trop courte pour que cette lecture prouve quoi que ce soit';

  set local role authenticated;
  set local request.headers = '{}';
  select count(*) into v_n from public.license_type_states;
  assert v_n = v_total,
    format('une session voit %s lignes sur les %s de la matrice', v_n, v_total);

  set local role anon;
  select count(*) into v_n from public.license_type_states;
  assert v_n = 0, format('un anonyme SANS jeton a lu %s lignes du catalogue', v_n);

  reset role;
end $$;

rollback;
