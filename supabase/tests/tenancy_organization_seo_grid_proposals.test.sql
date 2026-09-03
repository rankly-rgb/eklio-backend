-- ============================================================================
-- Tests — lot G: organization_seo_grid_proposals
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('ea111111-1111-4111-8111-111111111111', 'g-owner@example.com');

do $$
declare
  org_owner uuid;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ea111111-1111-4111-8111-111111111111';
  update public.organizations set name = 'Willow Practice' where id = org_owner;
end
$$;

-- ---------------------------------------------------------------------------
-- No clinicians: an empty result, not an error.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  n int;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ea111111-1111-4111-8111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ea111111-1111-4111-8111-111111111111"}';
  select count(*) into n from public.organization_seo_grid_proposals(org_owner);
  reset role;

  assert n = 0, format('expected an empty grid for an org with no clinicians, got %s rows', n);
end
$$;

-- ---------------------------------------------------------------------------
-- 3 clinicians, 2 states, up to 2 modalities each: the expected cells,
-- each with a proposed title/slug built from the same generator as F,
-- and has_page always false (Eklio never tracks or builds pages).
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ea111111-1111-4111-8111-111111111111';

  insert into auth.users (id, email) values
    ('ea222222-2222-4222-8222-222222222222', 'g-a@example.com'),
    ('ea333333-3333-4333-8333-333333333333', 'g-b@example.com'),
    ('ea444444-4444-4444-8444-444444444444', 'g-c@example.com');

  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values
    (org_owner, 'ea222222-2222-4222-8222-222222222222', 'clinician', 'active', now()),
    (org_owner, 'ea333333-3333-4333-8333-333333333333', 'clinician', 'active', now()),
    (org_owner, 'ea444444-4444-4444-8444-444444444444', 'clinician', 'active', now());

  insert into public.projects (id, user_id, organization_id, name) values
    ('eb000001-0001-0001-0001-000000000001', 'ea222222-2222-4222-8222-222222222222', org_owner, 'A'),
    ('eb000002-0002-0002-0002-000000000002', 'ea333333-3333-4333-8333-333333333333', org_owner, 'B'),
    ('eb000003-0003-0003-0003-000000000003', 'ea444444-4444-4444-8444-444444444444', org_owner, 'C');

  insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
  select org_owner, p.id, m.id, 'Clinician ' || p.name, 'licensed'
    from public.projects p
    join public.organization_members m on m.user_id = p.user_id and m.organization_id = org_owner
   where p.id in ('eb000001-0001-0001-0001-000000000001','eb000002-0002-0002-0002-000000000002','eb000003-0003-0003-0003-000000000003');

  -- A: emdr + OR.  B: emdr + cbt + OR + WA.  C: cbt + WA.
  insert into public.clinician_licensed_states (profile_id, state_code)
  select cp.id, x.code from public.clinician_profiles cp
    join public.projects p on p.id = cp.project_id
    cross join lateral (
      select unnest(case p.name when 'A' then array['OR'] when 'B' then array['OR','WA'] else array['WA'] end) as code
    ) x
   where p.organization_id = org_owner;

  insert into public.clinician_modalities (profile_id, modality_id)
  select cp.id, x.mid from public.clinician_profiles cp
    join public.projects p on p.id = cp.project_id
    cross join lateral (
      select unnest(case p.name when 'A' then array['emdr'] when 'B' then array['emdr','cbt'] else array['cbt'] end) as mid
    ) x
   where p.organization_id = org_owner;
end
$$;

do $$
declare
  org_owner uuid;
  n_emdr_or int;
  n_cbt_wa  int;
  title_emdr_or text;
  slug_emdr_or  text;
  has_page_val  boolean;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ea111111-1111-4111-8111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ea111111-1111-4111-8111-111111111111"}';

  select clinician_count, proposed_title, proposed_slug, has_page
    into n_emdr_or, title_emdr_or, slug_emdr_or, has_page_val
    from public.organization_seo_grid_proposals(org_owner)
   where grid = 'modality_state' and modality_id = 'emdr' and axis_id = 'OR';
  assert n_emdr_or = 2, format('emdr x OR count was %s, expected 2 (A and B)', n_emdr_or);
  assert title_emdr_or = 'EMDR Therapy in Oregon | Willow Practice',
         format('unexpected proposed title: %s', title_emdr_or);
  assert slug_emdr_or = 'emdr-oregon', format('unexpected proposed slug: %s', slug_emdr_or);
  assert has_page_val = false, 'has_page was true for a cell Eklio never built a page for';

  select clinician_count into n_cbt_wa from public.organization_seo_grid_proposals(org_owner)
   where grid = 'modality_state' and modality_id = 'cbt' and axis_id = 'WA';
  assert n_cbt_wa = 2, format('cbt x WA count was %s, expected 2 (B and C)', n_cbt_wa);

  reset role;
end
$$;

rollback;
