-- ============================================================================
-- Tests — lot B1: field-source lock enforcement and charter application
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('fd111111-1111-4111-8111-111111111111', 'charter-owner@example.com'),
  ('fd222222-2222-4222-8222-222222222222', 'charter-clinician@example.com');

do $$
declare
  org_owner   uuid;
  prj_owner   uuid := 'fe111111-1111-4111-8111-111111111111';
  kit_owner   uuid := 'fe222222-2222-4222-8222-222222222222';
  prj_clin    uuid := 'fe333333-3333-4333-8333-333333333333';
  kit_clin    uuid := 'fe444444-4444-4444-8444-444444444444';
begin
  select id into org_owner from public.organizations where owner_user_id = 'fd111111-1111-4111-8111-111111111111';

  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values (org_owner, 'fd222222-2222-4222-8222-222222222222', 'clinician', 'active', now());

  -- the owner's own project/kit becomes the charter
  insert into public.projects (id, user_id, organization_id, name)
  values (prj_owner, 'fd111111-1111-4111-8111-111111111111', org_owner, 'Charter Project');
  insert into public.brand_kits (id, project_id) values (kit_owner, prj_owner);
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url,
     hero, pages)
  values (kit_owner, 'fd111111-1111-4111-8111-111111111111', '#111111','#222222','#333333','#FFFFFF','#000000','#FAFAFA','Fraunces','Nunito Sans','u',
          '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb, public.site_spec_default_pages(null, null));

  update public.organizations set brand_charter_kit_id = kit_owner where id = org_owner;

  -- the clinician's own project/kit, not yet charter-applied
  insert into public.projects (id, user_id, organization_id, name)
  values (prj_clin, 'fd222222-2222-4222-8222-222222222222', org_owner, 'Clinician Project');
  insert into public.brand_kits (id, project_id) values (kit_clin, prj_clin);
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url,
     hero, pages)
  values (kit_clin, 'fd222222-2222-4222-8222-222222222222', '#AAAAAA','#BBBBBB','#CCCCCC','#FFFFFF','#000000','#FAFAFA','Font','Font','u',
          '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb, public.site_spec_default_pages(null, null));
end
$$;

-- ---------------------------------------------------------------------------
-- The owner applies the charter; every copied field becomes inherited
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  prj_clin  uuid := 'fe333333-3333-4333-8333-333333333333';
  kit_clin  uuid := 'fe444444-4444-4444-8444-444444444444';
  spec      record;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fd111111-1111-4111-8111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fd111111-1111-4111-8111-111111111111"}';
  perform public.apply_charter_to_project(org_owner, prj_clin);
  reset role;

  select primary_hex, secondary_hex, heading_font, field_sources into spec
    from public.site_specs where brand_kit_id = kit_clin;

  assert spec.primary_hex = '#111111', 'the charter primary_hex was not copied';
  assert spec.secondary_hex = '#222222', 'the charter secondary_hex was not copied';
  assert spec.heading_font = 'Fraunces', 'the charter heading_font was not copied';
  assert spec.field_sources->>'primary_hex' = 'inherited', 'primary_hex was not marked inherited';
  assert spec.field_sources->>'heading_font' = 'inherited', 'heading_font was not marked inherited';
end
$$;

-- ---------------------------------------------------------------------------
-- The clinician cannot edit an inherited field directly
-- ---------------------------------------------------------------------------
do $$
declare
  kit_clin uuid := 'fe444444-4444-4444-8444-444444444444';
  ok boolean := false;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fd222222-2222-4222-8222-222222222222"}';
  begin
    update public.site_specs set primary_hex = '#999999' where brand_kit_id = kit_clin;
  exception when others then ok := true;
  end;
  reset role;
  assert ok, 'the clinician was able to change an inherited primary_hex directly';

  assert (select primary_hex from public.site_specs where brand_kit_id = kit_clin) = '#111111',
         'the value changed despite the lock rejecting the write';
end
$$;

-- ---------------------------------------------------------------------------
-- A generated field stays editable — the lock is per-field, not per-row
-- ---------------------------------------------------------------------------
do $$
declare
  kit_clin uuid := 'fe444444-4444-4444-8444-444444444444';
begin
  -- about_excerpt has no field_sources entry at all (never a tracked key) and
  -- is not among the locked columns; hero, a real editable field, is used
  -- here via site_spec_patch-equivalent direct column write is out of scope
  -- for this test — instead prove the SAME row still accepts an update to a
  -- column the lock trigger does not govern at all: about_excerpt.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fd222222-2222-4222-8222-222222222222"}';
  update public.site_specs set about_excerpt = 'Still editable.' where brand_kit_id = kit_clin;
  reset role;

  assert (select about_excerpt from public.site_specs where brand_kit_id = kit_clin) = 'Still editable.',
         'a column the lock does not govern was blocked';
end
$$;

-- ---------------------------------------------------------------------------
-- Applying the (unchanged) charter twice changes nothing
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  prj_clin  uuid := 'fe333333-3333-4333-8333-333333333333';
  kit_clin  uuid := 'fe444444-4444-4444-8444-444444444444';
  before_row record;
  after_row  record;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fd111111-1111-4111-8111-111111111111';
  select primary_hex, secondary_hex, accent_hex, heading_font, body_font, field_sources
    into before_row from public.site_specs where brand_kit_id = kit_clin;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fd111111-1111-4111-8111-111111111111"}';
  perform public.apply_charter_to_project(org_owner, prj_clin);
  reset role;

  select primary_hex, secondary_hex, accent_hex, heading_font, body_font, field_sources
    into after_row from public.site_specs where brand_kit_id = kit_clin;

  assert before_row.primary_hex = after_row.primary_hex
     and before_row.secondary_hex = after_row.secondary_hex
     and before_row.accent_hex = after_row.accent_hex
     and before_row.heading_font = after_row.heading_font
     and before_row.body_font = after_row.body_font
     and before_row.field_sources = after_row.field_sources,
     'applying the same charter twice changed something';
end
$$;

-- ---------------------------------------------------------------------------
-- A project from another organization is refused
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner   uuid;
  other_org   uuid;
  other_prj   uuid := 'fe555555-5555-4555-8555-555555555555';
  ok boolean := false;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fd111111-1111-4111-8111-111111111111';

  insert into auth.users (id, email) values ('fd333333-3333-4333-8333-333333333333', 'other-owner@example.com');
  select id into other_org from public.organizations where owner_user_id = 'fd333333-3333-4333-8333-333333333333';
  insert into public.projects (id, user_id, organization_id, name)
  values (other_prj, 'fd333333-3333-4333-8333-333333333333', other_org, 'Someone Else''s Project');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fd111111-1111-4111-8111-111111111111"}';
  begin
    perform public.apply_charter_to_project(org_owner, other_prj);
  exception when others then ok := true;
  end;
  reset role;
  assert ok, 'a project from another organization accepted a foreign charter';
end
$$;

-- ---------------------------------------------------------------------------
-- set_field_sources: owner-only when inherited is set, lifted, or reassigned
-- ---------------------------------------------------------------------------
do $$
declare
  kit_clin uuid := 'fe444444-4444-4444-8444-444444444444';
  spec_id  uuid;
  ok boolean := false;
begin
  select id into spec_id from public.site_specs where brand_kit_id = kit_clin;

  -- the clinician cannot lift her own inherited lock
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fd222222-2222-4222-8222-222222222222"}';
  begin
    perform public.set_field_sources(spec_id, (select field_sources from public.site_specs where id = spec_id) || '{"primary_hex":"generated"}'::jsonb);
  exception when others then ok := true;
  end;
  assert ok, 'the clinician lifted her own inherited lock via set_field_sources';

  -- but she can still call it for a non-owner-only change (no-op payload, same shape)
  ok := false;
  begin
    perform public.set_field_sources(spec_id, (select field_sources from public.site_specs where id = spec_id));
  exception when others then ok := true;
  end;
  assert not ok, 'a no-op set_field_sources call was refused for a non-owner';
  reset role;
end
$$;

rollback;
