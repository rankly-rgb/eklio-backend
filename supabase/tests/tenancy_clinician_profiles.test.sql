-- ============================================================================
-- Tests — tenancy layer, lot C2/C4: clinician_profiles, join tables,
-- default_supervisor_name / clinician_effective_supervisor
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('c0000001-0000-0000-0000-000000000001', 'owner-c2@example.com'),
  ('c0000002-0000-0000-0000-000000000002', 'clinician-a@example.com'),
  ('c0000003-0000-0000-0000-000000000003', 'clinician-b@example.com');

do $$
declare
  org_owner  uuid;
  prj_a      uuid := 'ca000001-0001-0001-0001-000000000001';
  prj_b      uuid := 'ca000002-0002-0002-0002-000000000002';
  member_a   uuid;
  member_b   uuid;
begin
  select id into org_owner from public.organizations
   where owner_user_id = 'c0000001-0000-0000-0000-000000000001';

  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values
    (org_owner, 'c0000002-0000-0000-0000-000000000002', 'clinician', 'active', now()),
    (org_owner, 'c0000003-0000-0000-0000-000000000003', 'clinician', 'active', now());

  select id into member_a from public.organization_members
   where organization_id = org_owner and user_id = 'c0000002-0000-0000-0000-000000000002';
  select id into member_b from public.organization_members
   where organization_id = org_owner and user_id = 'c0000003-0000-0000-0000-000000000003';

  insert into public.projects (id, user_id, organization_id, name) values
    (prj_a, 'c0000002-0000-0000-0000-000000000002', org_owner, 'Clinician A'),
    (prj_b, 'c0000003-0000-0000-0000-000000000003', org_owner, 'Clinician B');

  insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
  values
    (org_owner, prj_a, member_a, 'Clinician A', 'licensed'),
    (org_owner, prj_b, member_b, 'Clinician B', 'associate');
end
$$;

-- ---------------------------------------------------------------------------
-- A supervised_intern needs an effective supervisor — insert fails without
-- one, succeeds once the org has a default, and the org default is what
-- clinician_effective_supervisor returns.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  prj_c     uuid := 'ca000003-0003-0003-0003-000000000003';
  member_c  uuid;
  ok        boolean := false;
begin
  select id into org_owner from public.organizations
   where owner_user_id = 'c0000001-0000-0000-0000-000000000001';

  insert into auth.users (id, email) values
    ('c0000004-0000-0000-0000-000000000004', 'clinician-c@example.com');
  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values (org_owner, 'c0000004-0000-0000-0000-000000000004', 'clinician', 'active', now());
  select id into member_c from public.organization_members
   where organization_id = org_owner and user_id = 'c0000004-0000-0000-0000-000000000004';
  insert into public.projects (id, user_id, organization_id, name)
  values (prj_c, 'c0000004-0000-0000-0000-000000000004', org_owner, 'Clinician C');

  begin
    insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
    values (org_owner, prj_c, member_c, 'Clinician C', 'supervised_intern');
  exception when others then ok := true;
  end;
  assert ok, 'a supervised_intern with no supervisor_name and no org default was allowed to be created';

  update public.organizations set default_supervisor_name = 'Dr. Practice Default' where id = org_owner;

  insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
  values (org_owner, prj_c, member_c, 'Clinician C', 'supervised_intern');

  assert (select public.clinician_effective_supervisor(id) from public.clinician_profiles where project_id = prj_c)
         = 'Dr. Practice Default',
         'clinician_effective_supervisor did not fall back to the org default';

  -- One statement on organizations changes every non-overriding intern.
  update public.organizations set default_supervisor_name = 'Dr. New Default' where id = org_owner;
  assert (select public.clinician_effective_supervisor(id) from public.clinician_profiles where project_id = prj_c)
         = 'Dr. New Default',
         'changing organizations.default_supervisor_name did not change the non-overriding intern''s effective supervisor';

  -- An intern who names her own supervisor is not affected by the org default.
  update public.clinician_profiles set supervisor_name = 'Dr. Own Supervisor' where project_id = prj_c;
  update public.organizations set default_supervisor_name = 'Dr. Yet Another Default' where id = org_owner;
  assert (select public.clinician_effective_supervisor(id) from public.clinician_profiles where project_id = prj_c)
         = 'Dr. Own Supervisor',
         'an intern''s own supervisor_name was overridden by the org default';
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: a clinician may write her own profile, never another's; the owner
-- may write either.
-- ---------------------------------------------------------------------------
do $$
declare
  prj_a uuid := 'ca000001-0001-0001-0001-000000000001';
  prj_b uuid := 'ca000002-0002-0002-0002-000000000002';
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c0000002-0000-0000-0000-000000000002"}';

  update public.clinician_profiles set philosophy_quote = 'Written by A' where project_id = prj_a;
  assert (select philosophy_quote from public.clinician_profiles where project_id = prj_a) = 'Written by A',
         'clinician A could not write her own profile';

  update public.clinician_profiles set philosophy_quote = 'Written by A, on B' where project_id = prj_b;
  assert (select philosophy_quote from public.clinician_profiles where project_id = prj_b) is distinct from 'Written by A, on B',
         'clinician A was able to write clinician B''s profile';

  reset role;
end
$$;

do $$
declare
  prj_b uuid := 'ca000002-0002-0002-0002-000000000002';
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c0000001-0000-0000-0000-000000000001"}';

  update public.clinician_profiles set philosophy_quote = 'Written by the owner' where project_id = prj_b;
  assert (select philosophy_quote from public.clinician_profiles where project_id = prj_b) = 'Written by the owner',
         'the active org owner could not write a clinician''s profile';

  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- Join tables: reuse of modality_cards / modality_prominence_options,
-- own us_states / population_cards, scoped the same way as the profile.
-- ---------------------------------------------------------------------------
do $$
declare
  prj_a    uuid := 'ca000001-0001-0001-0001-000000000001';
  prof_a   uuid;
begin
  select id into prof_a from public.clinician_profiles where project_id = prj_a;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c0000002-0000-0000-0000-000000000002"}';

  insert into public.clinician_licensed_states (profile_id, state_code) values (prof_a, 'OR'), (prof_a, 'WA');
  insert into public.clinician_modalities (profile_id, modality_id, prominence) values (prof_a, 'emdr', 'lead_with_it');
  insert into public.clinician_populations (profile_id, population_id) values (prof_a, 'couples');

  assert (select count(*) from public.clinician_licensed_states where profile_id = prof_a) = 2,
         'clinician A could not insert her own licensed states';
  assert (select count(*) from public.clinician_modalities where profile_id = prof_a) = 1,
         'clinician A could not insert her own modality';
  assert (select count(*) from public.clinician_populations where profile_id = prof_a) = 1,
         'clinician A could not insert her own population';

  reset role;

  -- Clinician B may not touch clinician A's join rows. Every count check
  -- below runs AFTER `reset role` — checking it while still impersonating
  -- clinician B would read through her own SELECT policy and read 0
  -- regardless of whether the write actually landed, hiding the real bug.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c0000003-0000-0000-0000-000000000003"}';
  begin
    insert into public.clinician_licensed_states (profile_id, state_code) values (prof_a, 'CA');
  exception when others then null;
  end;
  reset role;
  assert (select count(*) from public.clinician_licensed_states where profile_id = prof_a) = 2,
         'clinician B was able to insert a licensed state on clinician A''s profile';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c0000003-0000-0000-0000-000000000003"}';
  delete from public.clinician_licensed_states where profile_id = prof_a and state_code = 'OR';
  reset role;
  assert (select count(*) from public.clinician_licensed_states where profile_id = prof_a) = 2,
         'clinician B was able to delete clinician A''s licensed state';

  -- Everyone in the practice (here: clinician B, via can_access_project's
  -- is_org_owner branch does not apply to her — she reads via her own
  -- membership only if can_access_project allows org-mates; confirm the
  -- read actually reflects can_access_project's real rule instead of
  -- assuming it).
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c0000001-0000-0000-0000-000000000001"}';
  assert (select count(*) from public.clinician_licensed_states where profile_id = prof_a) = 2,
         'the org owner could not read clinician A''s licensed states';
  reset role;
end
$$;

rollback;
