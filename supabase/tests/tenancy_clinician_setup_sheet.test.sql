-- ============================================================================
-- Tests — lot F: clinician_setup_sheet, ensure_clinician_slug,
-- organization_setup_sheet_rows
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('fa111111-1111-4111-8111-111111111111', 'f-owner@example.com'),
  ('fa222222-2222-4222-8222-222222222222', 'f-complete@example.com'),
  ('fa333333-3333-4333-8333-333333333333', 'f-incomplete@example.com'),
  ('fa444444-4444-4444-8444-444444444444', 'f-jane-a@example.com'),
  ('fa555555-5555-4555-8555-555555555555', 'f-jane-b@example.com');

do $$
declare
  org_owner  uuid;
  prj_full   uuid := 'fb000001-0001-0001-0001-000000000001';
  prj_bare   uuid := 'fb000002-0002-0002-0002-000000000002';
  prj_jane_a uuid := 'fb000003-0003-0003-0003-000000000003';
  prj_jane_b uuid := 'fb000004-0004-0004-0004-000000000004';
  member_full   uuid;
  member_bare   uuid;
  member_jane_a uuid;
  member_jane_b uuid;
  profile_full  uuid;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fa111111-1111-4111-8111-111111111111';
  update public.organizations set name = 'Willow Practice' where id = org_owner;

  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values
    (org_owner, 'fa222222-2222-4222-8222-222222222222', 'clinician', 'active', now()),
    (org_owner, 'fa333333-3333-4333-8333-333333333333', 'clinician', 'active', now()),
    (org_owner, 'fa444444-4444-4444-8444-444444444444', 'clinician', 'active', now()),
    (org_owner, 'fa555555-5555-4555-8555-555555555555', 'clinician', 'active', now());

  select id into member_full   from public.organization_members where organization_id = org_owner and user_id = 'fa222222-2222-4222-8222-222222222222';
  select id into member_bare   from public.organization_members where organization_id = org_owner and user_id = 'fa333333-3333-4333-8333-333333333333';
  select id into member_jane_a from public.organization_members where organization_id = org_owner and user_id = 'fa444444-4444-4444-8444-444444444444';
  select id into member_jane_b from public.organization_members where organization_id = org_owner and user_id = 'fa555555-5555-4555-8555-555555555555';

  insert into public.projects (id, user_id, organization_id, name) values
    (prj_full,   'fa222222-2222-4222-8222-222222222222', org_owner, 'Full'),
    (prj_bare,   'fa333333-3333-4333-8333-333333333333', org_owner, 'Bare'),
    (prj_jane_a, 'fa444444-4444-4444-8444-444444444444', org_owner, 'Jane A'),
    (prj_jane_b, 'fa555555-5555-4555-8555-555555555555', org_owner, 'Jane B');

  insert into public.clinician_profiles
    (organization_id, project_id, member_id, full_name, credentials, status,
     philosophy_quote, outside_the_room, session_rate_cents, rate_is_public, booking_url, photo_provided)
  values
    (org_owner, prj_full, member_full, 'Full Profile', 'LPC-MHSP', 'licensed',
     'I meet clients where they are.', 'Runs trail races on weekends.',
     15000, true, 'https://example.com/book', true)
  returning id into profile_full;

  insert into public.clinician_licensed_states (profile_id, state_code) values (profile_full, 'OR'), (profile_full, 'WA');
  insert into public.clinician_modalities (profile_id, modality_id) values (profile_full, 'emdr'), (profile_full, 'cbt');
  insert into public.clinician_populations (profile_id, population_id) values (profile_full, 'couples');

  -- The bare minimum a row can hold.
  insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
  values (org_owner, prj_bare, member_bare, 'Bare Profile', 'licensed');

  -- Two clinicians who happen to share a first+last name.
  insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, credentials, status)
  values
    (org_owner, prj_jane_a, member_jane_a, 'Jane Doe', 'LPC', 'licensed'),
    (org_owner, prj_jane_b, member_jane_b, 'Jane Doe', 'LMFT', 'licensed');
end
$$;

-- ---------------------------------------------------------------------------
-- A complete profile produces every section.
-- ---------------------------------------------------------------------------
do $$
declare
  prj_full uuid := 'fb000001-0001-0001-0001-000000000001';
  prof     uuid;
  sheet    jsonb;
  titles   text[];
begin
  select id into prof from public.clinician_profiles where project_id = prj_full;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fa222222-2222-4222-8222-222222222222"}';
  sheet := public.clinician_setup_sheet(prof);
  reset role;

  assert jsonb_array_length(sheet->'blocking') = 0, format('a full profile had blocking items: %s', sheet->'blocking');

  select array_agg(s->>'title') into titles from jsonb_array_elements(sheet->'steps') s;
  assert 'Page title' = any(titles), 'missing Page title section';
  assert 'URL slug' = any(titles), 'missing URL slug section';
  assert 'Meta title' = any(titles), 'missing Meta title section';
  assert 'Meta description' = any(titles), 'missing Meta description section';
  assert 'Bio copy' = any(titles), 'missing Bio copy section';
  assert 'Credentials' = any(titles), 'missing Credentials section';
  assert 'Licensed in' = any(titles), 'missing Licensed in section';
  assert 'Modalities' = any(titles), 'missing Modalities section';
  assert 'Who she works with' = any(titles), 'missing Who she works with section';
  assert 'Rate' = any(titles), 'missing Rate section (rate_is_public true)';
  assert 'Booking link' = any(titles), 'missing Booking link section';
  assert 'Photo' = any(titles), 'missing Photo section';

  assert sheet->>'slug' is not null, 'sheet has no slug';
end
$$;

-- ---------------------------------------------------------------------------
-- An incomplete profile: sheet still produced, blocking listed at top,
-- absent sections simply not present (not placeholder rows).
-- ---------------------------------------------------------------------------
do $$
declare
  prj_bare uuid := 'fb000002-0002-0002-0002-000000000002';
  prof     uuid;
  sheet    jsonb;
  titles   text[];
begin
  select id into prof from public.clinician_profiles where project_id = prj_bare;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fa333333-3333-4333-8333-333333333333"}';
  sheet := public.clinician_setup_sheet(prof);
  reset role;

  assert jsonb_array_length(sheet->'blocking') > 0, 'an incomplete profile reported no blocking items';
  assert sheet->'blocking' ? 'credentials', 'credentials missing from blocking list';
  assert sheet->'blocking' ? 'licensed_states', 'licensed_states missing from blocking list';
  assert sheet->'blocking' ? 'philosophy_quote', 'philosophy_quote missing from blocking list';

  select array_agg(s->>'title') into titles from jsonb_array_elements(sheet->'steps') s;
  assert not ('Bio copy' = any(titles)), 'Bio copy section present despite no philosophy_quote';
  assert not ('Credentials' = any(titles)), 'Credentials section present despite no credentials';
  assert not ('Licensed in' = any(titles)), 'Licensed in section present despite no licensed states';
  assert not ('Rate' = any(titles)), 'Rate section present despite no rate';
  -- Page title, URL slug, Photo always have something to say.
  assert 'Page title' = any(titles), 'Page title missing even for a bare profile';
  assert 'URL slug' = any(titles), 'URL slug missing even for a bare profile';
  assert 'Photo' = any(titles), 'Photo missing even for a bare profile';
end
$$;

-- ---------------------------------------------------------------------------
-- Two clinicians with the same name get different slugs.
-- ---------------------------------------------------------------------------
do $$
declare
  prj_a uuid := 'fb000003-0003-0003-0003-000000000003';
  prj_b uuid := 'fb000004-0004-0004-0004-000000000004';
  prof_a uuid;
  prof_b uuid;
  slug_a text;
  slug_b text;
begin
  select id into prof_a from public.clinician_profiles where project_id = prj_a;
  select id into prof_b from public.clinician_profiles where project_id = prj_b;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fa444444-4444-4444-8444-444444444444"}';
  slug_a := public.ensure_clinician_slug(prof_a);
  reset role;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fa555555-5555-4555-8555-555555555555"}';
  slug_b := public.ensure_clinician_slug(prof_b);
  reset role;

  assert slug_a = 'jane-doe', format('expected jane-doe, got %s', slug_a);
  assert slug_b = 'jane-doe-2', format('expected jane-doe-2 (collision within the same org), got %s', slug_b);
  assert slug_a is distinct from slug_b, 'two same-named clinicians got the same slug';

  -- Idempotent: calling again returns the SAME value, not a new one.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fa444444-4444-4444-8444-444444444444"}';
  assert public.ensure_clinician_slug(prof_a) = slug_a, 'ensure_clinician_slug regenerated a slug on a second call';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- organization_setup_sheet_rows: owner sees every clinician, a clinician
-- sees only her own row.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  n int;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fa111111-1111-4111-8111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fa111111-1111-4111-8111-111111111111"}';
  select count(*) into n from public.organization_setup_sheet_rows(org_owner);
  assert n = 4, format('the owner saw %s rows, expected 4', n);
  reset role;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fa222222-2222-4222-8222-222222222222"}';
  select count(*) into n from public.organization_setup_sheet_rows(org_owner);
  assert n = 1, format('a clinician saw %s rows, expected 1 (her own)', n);
  reset role;
end
$$;

rollback;
