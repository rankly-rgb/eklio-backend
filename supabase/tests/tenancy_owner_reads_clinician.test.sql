-- ============================================================================
-- Tests — tenancy layer: an org owner reads (never writes) an active
-- clinician's data; the clinician reads none of the owner's.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('f1111111-1111-1111-1111-111111111111', 'owner@example.com'),
  ('f2222222-2222-2222-2222-222222222222', 'clinician@example.com');

do $$
declare
  org_owner uuid;
  prj_c uuid := 'fa111111-1111-1111-1111-111111111111';
  kit_c uuid := 'fa222222-2222-2222-2222-222222222222';
  prj_o uuid := 'fa333333-3333-3333-3333-333333333333';
begin
  select id into org_owner from public.organizations where owner_user_id = 'f1111111-1111-1111-1111-111111111111';

  -- The clinician becomes an ACTIVE member of the owner's organization —
  -- this test is about read/write scope, not the invite mechanics (see
  -- tenancy_invites.test.sql), so the membership is inserted directly.
  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values (org_owner, 'f2222222-2222-2222-2222-222222222222', 'clinician', 'active', now());

  -- The owner's own project, in her own organization.
  insert into public.projects (id, user_id, organization_id, name)
  values (prj_o, 'f1111111-1111-1111-1111-111111111111', org_owner, 'Owner''s Own Project');

  -- The clinician's project lives in the OWNER's organization (the practice),
  -- not in the clinician's own auto-created organization-of-one.
  insert into public.projects (id, user_id, organization_id, name)
  values (prj_c, 'f2222222-2222-2222-2222-222222222222', org_owner, 'Clinician''s Project');

  insert into public.project_briefs (project_id, practice_name, license_type_id, city, state)
  values (prj_c, 'Clinician''s Project', 'lcsw', 'Eugene', 'OR');

  insert into public.directions (project_id, "position", name, description, palette, heading_font, body_font)
  values (prj_c, 1, 'D1', 'desc', '{}'::jsonb, 'Font', 'Font');

  insert into public.brand_kits (id, project_id) values (kit_c, prj_c);

  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url,
     hero, pages)
  values (kit_c, 'f2222222-2222-2222-2222-222222222222', '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
          '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb, public.site_spec_default_pages(null, null));

  -- launch_checklist_items is NOT inserted here: handle_new_brand_kit()
  -- already auto-seeded six rows for kit_c via on_brand_kit_created.

  insert into public.monthly_presence_content (user_id, brand_kit_id, month, day_of_month, type)
  values ('f2222222-2222-2222-2222-222222222222', kit_c, date_trunc('month', now())::date, 1, 'post');

  insert into public.direction_assets (brand_kit_id, direction_index) values (kit_c, 0);
end
$$;

-- ---------------------------------------------------------------------------
-- The owner reads the clinician's rows on every rewritten table
-- ---------------------------------------------------------------------------
do $$
declare
  prj_c uuid := 'fa111111-1111-1111-1111-111111111111';
  kit_c uuid := 'fa222222-2222-2222-2222-222222222222';
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"f1111111-1111-1111-1111-111111111111"}';

  assert exists (select 1 from public.projects where id = prj_c), 'owner could not read clinician''s project';
  assert exists (select 1 from public.project_briefs where project_id = prj_c), 'owner could not read clinician''s brief';
  assert exists (select 1 from public.directions where project_id = prj_c), 'owner could not read clinician''s directions';
  assert exists (select 1 from public.brand_kits where id = kit_c), 'owner could not read clinician''s kit';
  assert exists (select 1 from public.site_specs where brand_kit_id = kit_c), 'owner could not read clinician''s site spec';
  assert exists (select 1 from public.launch_checklist_items where brand_kit_id = kit_c), 'owner could not read clinician''s checklist';
  assert exists (select 1 from public.monthly_presence_content where brand_kit_id = kit_c), 'owner could not read clinician''s calendar';
  assert exists (select 1 from public.direction_assets where brand_kit_id = kit_c), 'owner could not read clinician''s asset';

  -- ⚠ reads, never writes: the owner does not edit a clinician's project.
  update public.projects set name = 'Renamed by owner' where id = prj_c;
  assert (select count(*) from public.projects where id = prj_c and name = 'Renamed by owner') = 0,
         'the owner was able to write the clinician''s project';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- The clinician reads none of the owner's rows
-- ---------------------------------------------------------------------------
do $$
declare
  prj_o uuid := 'fa333333-3333-3333-3333-333333333333';
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"f2222222-2222-2222-2222-222222222222"}';

  assert not exists (select 1 from public.projects where id = prj_o), 'the clinician read the owner''s own project';
  -- ⚠ she DOES see the owner's organization row itself (is_org_member, not
  -- is_org_owner, gates SELECT on organizations) — that is intended: a
  -- clinician can see which practice she belongs to.
  reset role;
end
$$;

rollback;
