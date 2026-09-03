-- ============================================================================
-- Tests — tenancy layer, lot C6: organization_seo_grid()
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('d0000001-0000-0000-0000-000000000001', 'owner-c6@example.com'),
  ('d0000002-0000-0000-0000-000000000002', 'a-c6@example.com'),
  ('d0000003-0000-0000-0000-000000000003', 'b-c6@example.com');

do $$
declare
  org_owner uuid;
  prj_a uuid := 'dc000001-0001-0001-0001-000000000001';
  prj_b uuid := 'dc000002-0002-0002-0002-000000000002';
  member_a uuid;
  member_b uuid;
  prof_a uuid;
  prof_b uuid;
begin
  select id into org_owner from public.organizations where owner_user_id = 'd0000001-0000-0000-0000-000000000001';

  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values
    (org_owner, 'd0000002-0000-0000-0000-000000000002', 'clinician', 'active', now()),
    (org_owner, 'd0000003-0000-0000-0000-000000000003', 'clinician', 'active', now());

  select id into member_a from public.organization_members where organization_id = org_owner and user_id = 'd0000002-0000-0000-0000-000000000002';
  select id into member_b from public.organization_members where organization_id = org_owner and user_id = 'd0000003-0000-0000-0000-000000000003';

  insert into public.projects (id, user_id, organization_id, name) values
    (prj_a, 'd0000002-0000-0000-0000-000000000002', org_owner, 'A'),
    (prj_b, 'd0000003-0000-0000-0000-000000000003', org_owner, 'B');

  insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
  values
    (org_owner, prj_a, member_a, 'Clinician A', 'licensed'),
    (org_owner, prj_b, member_b, 'Clinician B', 'licensed');

  select id into prof_a from public.clinician_profiles where project_id = prj_a;
  select id into prof_b from public.clinician_profiles where project_id = prj_b;

  -- Both clinicians do EMDR, licensed in OR; only A also does CBT and works
  -- with couples; only B is licensed in WA.
  insert into public.clinician_modalities (profile_id, modality_id) values
    (prof_a, 'emdr'), (prof_a, 'cbt'), (prof_b, 'emdr');
  insert into public.clinician_licensed_states (profile_id, state_code) values
    (prof_a, 'OR'), (prof_b, 'OR'), (prof_b, 'WA');
  insert into public.clinician_populations (profile_id, population_id) values
    (prof_a, 'couples');
end
$$;

-- ---------------------------------------------------------------------------
-- The owner sees the whole practice's grid, with correct per-cell counts.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  n_emdr_or int;
  n_cbt_or  int;
  n_emdr_wa int;
  n_cbt_couples int;
begin
  select id into org_owner from public.organizations where owner_user_id = 'd0000001-0000-0000-0000-000000000001';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"d0000001-0000-0000-0000-000000000001"}';

  select clinician_count into n_emdr_or from public.organization_seo_grid(org_owner)
   where grid = 'modality_state' and modality_id = 'emdr' and axis_id = 'OR';
  assert n_emdr_or = 2, format('emdr x OR count was %s, expected 2 (both clinicians)', n_emdr_or);

  select clinician_count into n_cbt_or from public.organization_seo_grid(org_owner)
   where grid = 'modality_state' and modality_id = 'cbt' and axis_id = 'OR';
  assert n_cbt_or = 1, format('cbt x OR count was %s, expected 1 (only A)', n_cbt_or);

  select clinician_count into n_emdr_wa from public.organization_seo_grid(org_owner)
   where grid = 'modality_state' and modality_id = 'emdr' and axis_id = 'WA';
  assert n_emdr_wa = 1, format('emdr x WA count was %s, expected 1 (only B)', n_emdr_wa);

  select clinician_count into n_cbt_couples from public.organization_seo_grid(org_owner)
   where grid = 'modality_population' and modality_id = 'cbt' and axis_id = 'couples';
  assert n_cbt_couples = 1, format('cbt x couples count was %s, expected 1', n_cbt_couples);

  -- No cell for a modality/state combination nobody holds.
  assert not exists (
    select 1 from public.organization_seo_grid(org_owner)
     where grid = 'modality_state' and modality_id = 'cbt' and axis_id = 'WA'
  ), 'a grid cell existed for a modality/state combination with zero clinicians';

  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- A non-owner clinician sees only cells her own profile contributes to.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  n int;
begin
  select id into org_owner from public.organizations where owner_user_id = 'd0000001-0000-0000-0000-000000000001';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"d0000002-0000-0000-0000-000000000002"}';

  assert not exists (
    select 1 from public.organization_seo_grid(org_owner)
     where grid = 'modality_state' and modality_id = 'emdr' and axis_id = 'WA'
  ), 'clinician A saw a grid cell (emdr x WA) she does not contribute to';

  select clinician_count into n from public.organization_seo_grid(org_owner)
   where grid = 'modality_state' and modality_id = 'emdr' and axis_id = 'OR';
  assert n = 1, format('clinician A''s own-scoped emdr x OR count was %s, expected 1', n);

  reset role;
end
$$;

rollback;
