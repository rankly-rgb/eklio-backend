-- ============================================================================
-- Tests — tenancy layer, lot C3: clinician_profile_completeness /
-- organization_profile_health
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('e0000001-0000-0000-0000-000000000001', 'owner-c3@example.com'),
  ('e0000002-0000-0000-0000-000000000002', 'empty-c3@example.com'),
  ('e0000003-0000-0000-0000-000000000003', 'full-c3@example.com'),
  ('e0000004-0000-0000-0000-000000000004', 'intern-c3@example.com');

do $$
declare
  org_owner  uuid;
  prj_empty  uuid := 'eb000001-0001-0001-0001-000000000001';
  prj_full   uuid := 'eb000002-0002-0002-0002-000000000002';
  prj_intern uuid := 'eb000003-0003-0003-0003-000000000003';
  member_empty  uuid;
  member_full   uuid;
  member_intern uuid;
  profile_full  uuid;
begin
  select id into org_owner from public.organizations
   where owner_user_id = 'e0000001-0000-0000-0000-000000000001';

  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values
    (org_owner, 'e0000002-0000-0000-0000-000000000002', 'clinician', 'active', now()),
    (org_owner, 'e0000003-0000-0000-0000-000000000003', 'clinician', 'active', now()),
    (org_owner, 'e0000004-0000-0000-0000-000000000004', 'clinician', 'active', now());

  select id into member_empty  from public.organization_members where organization_id = org_owner and user_id = 'e0000002-0000-0000-0000-000000000002';
  select id into member_full   from public.organization_members where organization_id = org_owner and user_id = 'e0000003-0000-0000-0000-000000000003';
  select id into member_intern from public.organization_members where organization_id = org_owner and user_id = 'e0000004-0000-0000-0000-000000000004';

  insert into public.projects (id, user_id, organization_id, name) values
    (prj_empty,  'e0000002-0000-0000-0000-000000000002', org_owner, 'Empty'),
    (prj_full,   'e0000003-0000-0000-0000-000000000003', org_owner, 'Full'),
    (prj_intern, 'e0000004-0000-0000-0000-000000000004', org_owner, 'Intern');

  -- The bare minimum a row can hold (full_name/status are NOT NULL).
  insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
  values (org_owner, prj_empty, member_empty, 'Empty Profile', 'licensed');

  -- Every field, every join row.
  insert into public.clinician_profiles
    (organization_id, project_id, member_id, full_name, credentials, status,
     philosophy_quote, outside_the_room, personality_note, session_rate_cents,
     rate_is_public, booking_url, photo_provided)
  values
    (org_owner, prj_full, member_full, 'Full Profile', 'LPC-MHSP', 'licensed',
     'Therapy is collaborative, not prescriptive.', 'Runs trail races on weekends.',
     'Direct, warm, a little dry.', 15000, true, 'https://example.com/book', true)
  returning id into profile_full;

  insert into public.clinician_licensed_states (profile_id, state_code) values (profile_full, 'OR');
  insert into public.clinician_modalities (profile_id, modality_id) values (profile_full, 'emdr');
  insert into public.clinician_populations (profile_id, population_id) values (profile_full, 'couples');

  -- A supervised_intern who relies on the org default, which will be
  -- cleared in a later step to exercise the staleness-not-absence path.
  update public.organizations set default_supervisor_name = 'Dr. Practice Default' where id = org_owner;
  insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
  values (org_owner, prj_intern, member_intern, 'Intern Profile', 'supervised_intern');
end
$$;

-- ---------------------------------------------------------------------------
-- Empty profile: score 0, every blocking field listed.
-- ---------------------------------------------------------------------------
do $$
declare
  prj_empty uuid := 'eb000001-0001-0001-0001-000000000001';
  prof      uuid;
  result    jsonb;
begin
  select id into prof from public.clinician_profiles where project_id = prj_empty;
  result := public.clinician_profile_completeness(prof);

  assert (result->>'score')::int = 0, format('empty profile scored %s, expected 0', result->>'score');
  assert jsonb_array_length(result->'blocking_missing') = 5,
         format('empty profile listed %s blocking fields, expected 5', jsonb_array_length(result->'blocking_missing'));
  assert result->'blocking_missing' ? 'credentials', 'credentials missing from blocking list';
  assert result->'blocking_missing' ? 'licensed_states', 'licensed_states missing from blocking list';
  assert result->'blocking_missing' ? 'modalities', 'modalities missing from blocking list';
  assert result->'blocking_missing' ? 'populations', 'populations missing from blocking list';
  assert result->'blocking_missing' ? 'philosophy_quote', 'philosophy_quote missing from blocking list';
  assert (result->>'is_stale')::boolean = false, 'a freshly-created profile was flagged stale';
end
$$;

-- ---------------------------------------------------------------------------
-- Full profile: score 100, nothing missing.
-- ---------------------------------------------------------------------------
do $$
declare
  prj_full uuid := 'eb000002-0002-0002-0002-000000000002';
  prof     uuid;
  result   jsonb;
begin
  select id into prof from public.clinician_profiles where project_id = prj_full;
  result := public.clinician_profile_completeness(prof);

  assert (result->>'score')::int = 100, format('full profile scored %s, expected 100', result->>'score');
  assert jsonb_array_length(result->'blocking_missing') = 0, 'a full profile reported a blocking field missing';
  assert jsonb_array_length(result->'non_blocking_missing') = 0, 'a full profile reported a non-blocking field missing';
end
$$;

-- ---------------------------------------------------------------------------
-- A supervised_intern with no effective supervisor is blocking — the org
-- default is cleared out from under her after the row was saved.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner  uuid;
  prj_intern uuid := 'eb000003-0003-0003-0003-000000000003';
  prof       uuid;
  result     jsonb;
begin
  select id into org_owner from public.organizations where owner_user_id = 'e0000001-0000-0000-0000-000000000001';
  select id into prof from public.clinician_profiles where project_id = prj_intern;

  result := public.clinician_profile_completeness(prof);
  assert not (result->'blocking_missing' ? 'supervisor'),
         'the intern was flagged missing a supervisor while the org default still covered her';

  update public.organizations set default_supervisor_name = null where id = org_owner;

  result := public.clinician_profile_completeness(prof);
  assert result->'blocking_missing' ? 'supervisor',
         'clearing the org default did not flag the relying intern as missing a supervisor';
end
$$;

-- ---------------------------------------------------------------------------
-- A profile untouched for 200 days is flagged stale.
-- ---------------------------------------------------------------------------
do $$
declare
  prj_full uuid := 'eb000002-0002-0002-0002-000000000002';
  prof     uuid;
  result   jsonb;
begin
  select id into prof from public.clinician_profiles where project_id = prj_full;

  alter table public.clinician_profiles disable trigger set_clinician_profiles_updated_at;
  update public.clinician_profiles set updated_at = now() - interval '200 days' where id = prof;
  alter table public.clinician_profiles enable trigger set_clinician_profiles_updated_at;

  result := public.clinician_profile_completeness(prof);
  assert (result->>'is_stale')::boolean = true, 'a profile untouched for 200 days was not flagged stale';
end
$$;

-- ---------------------------------------------------------------------------
-- organization_profile_health: the owner sees every profile, blocking and
-- stale ones sorted first; a clinician sees only her own row.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  rows_seen int;
  first_full_name text;
begin
  select id into org_owner from public.organizations where owner_user_id = 'e0000001-0000-0000-0000-000000000001';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e0000001-0000-0000-0000-000000000001"}';

  select count(*) into rows_seen from public.organization_profile_health(org_owner);
  assert rows_seen = 3, format('the owner saw %s rows from organization_profile_health, expected 3', rows_seen);

  select full_name into first_full_name from public.organization_profile_health(org_owner) limit 1;
  assert first_full_name in ('Empty Profile', 'Intern Profile'),
         format('organization_profile_health did not sort a blocking profile first (got %s)', first_full_name);

  reset role;
end
$$;

do $$
declare
  org_owner uuid;
  rows_seen int;
  seen_name text;
begin
  select id into org_owner from public.organizations where owner_user_id = 'e0000001-0000-0000-0000-000000000001';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e0000002-0000-0000-0000-000000000002"}';

  select count(*) into rows_seen from public.organization_profile_health(org_owner);
  assert rows_seen = 1, format('a non-owner clinician saw %s rows from organization_profile_health, expected 1', rows_seen);

  select full_name into seen_name from public.organization_profile_health(org_owner) limit 1;
  assert seen_name = 'Empty Profile', 'a clinician saw a profile health row that was not her own';

  reset role;
end
$$;

rollback;
