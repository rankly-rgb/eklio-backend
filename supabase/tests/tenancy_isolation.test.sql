-- ============================================================================
-- Tests — tenancy layer: cross-organization isolation
-- ============================================================================
-- User A reads none of user B's rows on every table this lot rewrote; anon
-- reads zero rows and gets no error on each. Two independent owners, each
-- with a full stack of her own data — no organization relationship between
-- them at all.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('c1111111-1111-1111-1111-111111111111', 'iso-a@example.com'),
  ('c2222222-2222-2222-2222-222222222222', 'iso-b@example.com');

do $$
declare
  org_a uuid; org_b uuid;
  prj_a uuid := 'd1111111-1111-1111-1111-111111111111';
  prj_b uuid := 'd2222222-2222-2222-2222-222222222222';
  kit_a uuid := 'e1111111-1111-1111-1111-111111111111';
  kit_b uuid := 'e2222222-2222-2222-2222-222222222222';
begin
  select id into org_a from public.organizations where owner_user_id = 'c1111111-1111-1111-1111-111111111111';
  select id into org_b from public.organizations where owner_user_id = 'c2222222-2222-2222-2222-222222222222';

  insert into public.projects (id, user_id, organization_id, name) values
    (prj_a, 'c1111111-1111-1111-1111-111111111111', org_a, 'A''s Practice'),
    (prj_b, 'c2222222-2222-2222-2222-222222222222', org_b, 'B''s Practice');

  insert into public.project_briefs (project_id, practice_name, license_type_id, city, state) values
    (prj_a, 'A''s Practice', 'lcsw', 'Portland', 'OR'),
    (prj_b, 'B''s Practice', 'lcsw', 'Salem', 'OR');

  insert into public.directions (project_id, "position", name, description, palette, heading_font, body_font) values
    (prj_a, 1, 'D1', 'desc', '{}'::jsonb, 'Font', 'Font'),
    (prj_b, 1, 'D1', 'desc', '{}'::jsonb, 'Font', 'Font');

  insert into public.brand_kits (id, project_id) values (kit_a, prj_a), (kit_b, prj_b);

  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url,
     hero, pages)
  values
    (kit_a, 'c1111111-1111-1111-1111-111111111111', '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
     '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb, public.site_spec_default_pages(null, null)),
    (kit_b, 'c2222222-2222-2222-2222-222222222222', '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
     '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb, public.site_spec_default_pages(null, null));

  -- launch_checklist_items is NOT inserted here: handle_new_brand_kit()
  -- already auto-seeded six rows per kit via on_brand_kit_created (found by
  -- actually inserting a kit and observing a unique_violation on a second,
  -- manual insert — see the checkpoint report).

  insert into public.monthly_presence_content (user_id, brand_kit_id, month, day_of_month, type) values
    ('c1111111-1111-1111-1111-111111111111', kit_a, date_trunc('month', now())::date, 1, 'post'),
    ('c2222222-2222-2222-2222-222222222222', kit_b, date_trunc('month', now())::date, 1, 'post');

  insert into public.direction_assets (brand_kit_id, direction_index) values (kit_a, 0), (kit_b, 0);
end
$$;

-- ---------------------------------------------------------------------------
-- A reads her own, never B's; each table individually
-- ---------------------------------------------------------------------------
do $$
declare
  prj_b uuid := 'd2222222-2222-2222-2222-222222222222';
  kit_b uuid := 'e2222222-2222-2222-2222-222222222222';
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c1111111-1111-1111-1111-111111111111"}';

  assert (select count(*) from public.organizations)         = 1, 'A saw more than her own organization';
  assert (select count(*) from public.projects)               = 1, 'A saw more than her own project';
  assert (select count(*) from public.project_briefs)         = 1, 'A saw more than her own brief';
  assert (select count(*) from public.directions)             = 1, 'A saw more than her own directions';
  assert (select count(*) from public.brand_kits)             = 1, 'A saw more than her own kit';
  assert (select count(*) from public.site_specs)             = 1, 'A saw more than her own spec';
  assert (select count(*) from public.launch_checklist_items) = 6, 'A saw more or less than her own six-item checklist';
  assert (select count(*) from public.monthly_presence_content) = 1, 'A saw more than her own calendar';
  assert (select count(*) from public.direction_assets)       = 1, 'A saw more than her own asset';

  assert not exists (select 1 from public.projects where id = prj_b), 'A read B''s project by id';
  assert not exists (select 1 from public.brand_kits where id = kit_b), 'A read B''s kit by id';
  assert not exists (select 1 from public.site_specs where brand_kit_id = kit_b), 'A read B''s site spec by id';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- anon reads zero rows, no error, on every rewritten table
-- ---------------------------------------------------------------------------
do $$
declare ok boolean := false;
begin
  set local role anon;
  -- ⚠ request.jwt.claims is a GUC and survives a role change (see
  -- supabase/tests/README.md, "Tester la RLS") — the previous block left A's
  -- sub claim set, and without clearing it here, auth.uid() under `anon`
  -- would still resolve to A, silently proving nothing. Found by actually
  -- running this block and getting a count of 1, not 0, for public.projects.
  set local request.jwt.claims = '{}';

  -- ⚠ organizations/organization_members are held to a STRICTER standard
  -- than every other table here: Step 1 explicitly revokes ALL privileges
  -- from anon on both (not just RLS-gated SELECT), so anon gets a hard
  -- permission-denied error, not a silent empty result — found by actually
  -- running this assertion the RLS-only way first and getting exactly that
  -- error. A real, stronger guarantee (nothing to see even via a raw scan
  -- with no RLS at all), matching the repo's existing belt-and-suspenders
  -- pattern for stripe_events/comp_grants — not the "no error" shape every
  -- other table in this list uses.
  begin
    perform count(*) from public.organizations;
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'anon was not flatly denied on organizations';

  ok := false;
  begin
    perform count(*) from public.organization_members;
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'anon was not flatly denied on organization_members';

  assert (select count(*) from public.projects)                 = 0, 'anon read projects';
  assert (select count(*) from public.project_briefs)           = 0, 'anon read project_briefs';
  assert (select count(*) from public.directions)                = 0, 'anon read directions';
  assert (select count(*) from public.generation_credits)       = 0, 'anon read generation_credits';
  assert (select count(*) from public.brand_kits)                = 0, 'anon read brand_kits';
  assert (select count(*) from public.site_specs)                = 0, 'anon read site_specs';
  assert (select count(*) from public.launch_checklist_items)   = 0, 'anon read launch_checklist_items';
  assert (select count(*) from public.monthly_presence_content) = 0, 'anon read monthly_presence_content';
  assert (select count(*) from public.direction_assets)         = 0, 'anon read direction_assets';
  reset role;
end
$$;

rollback;
