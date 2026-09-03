-- ============================================================================
-- Tests — lot B2: import_brand_identity
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('ff111111-1111-4111-8111-111111111111', 'import-owner@example.com'),
  ('ff222222-2222-4222-8222-222222222222', 'import-stranger@example.com');

do $$
declare
  org_owner uuid;
  prj       uuid := 'e1111111-1111-4111-8111-111111111111';
  kit       uuid := 'e2222222-2222-4222-8222-222222222222';
begin
  select id into org_owner from public.organizations where owner_user_id = 'ff111111-1111-4111-8111-111111111111';

  insert into public.projects (id, user_id, organization_id, name)
  values (prj, 'ff111111-1111-4111-8111-111111111111', org_owner, 'Import Test');
  insert into public.brand_kits (id, project_id) values (kit, prj);
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url,
     hero, pages)
  values (kit, 'ff111111-1111-4111-8111-111111111111', '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
          '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb, public.site_spec_default_pages(null, null));
end
$$;

-- ---------------------------------------------------------------------------
-- A two-field payload: only those two change, origin becomes mixed, no
-- generation credit spent
-- ---------------------------------------------------------------------------
do $$
declare
  prj uuid := 'e1111111-1111-4111-8111-111111111111';
  kit uuid := 'e2222222-2222-4222-8222-222222222222';
  before_credits public.generation_credits%rowtype;
  after_credits  public.generation_credits%rowtype;
  spec record;
begin
  select * into before_credits from public.generation_credits where project_id = prj;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ff111111-1111-4111-8111-111111111111"}';
  perform public.import_brand_identity(prj, '{"primary_hex":"#AA3311","logo_svg_path":"org/11111111-1111-1111-1111-111111111111/logo.svg"}'::jsonb);
  reset role;

  select primary_hex, secondary_hex, logo_svg_path, field_sources into spec
    from public.site_specs where brand_kit_id = kit;

  assert spec.primary_hex = '#AA3311', 'the imported primary_hex was not written';
  assert spec.secondary_hex = '#000000', 'an untouched field changed';
  assert spec.logo_svg_path = 'org/11111111-1111-1111-1111-111111111111/logo.svg',
         'the imported logo path was not written';
  assert spec.field_sources->>'primary_hex' = 'imported', 'primary_hex was not marked imported';
  assert spec.field_sources->>'logo' = 'imported', 'logo was not marked imported';
  assert spec.field_sources->>'secondary_hex' is null or spec.field_sources->>'secondary_hex' <> 'imported',
         'an untouched field was marked imported';

  assert (select origin from public.brand_kits where id = kit) = 'mixed',
         'a partial import did not set origin to mixed';

  select * into after_credits from public.generation_credits where project_id = prj;
  assert before_credits.directions_generated = after_credits.directions_generated
     and before_credits.regenerations_used = after_credits.regenerations_used,
     'import_brand_identity consumed a generation credit';
end
$$;

-- ---------------------------------------------------------------------------
-- Importing every tracked field sets origin to imported
-- ---------------------------------------------------------------------------
do $$
declare
  prj uuid := 'e1111111-1111-4111-8111-111111111111';
  kit uuid := 'e2222222-2222-4222-8222-222222222222';
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ff111111-1111-4111-8111-111111111111"}';
  perform public.import_brand_identity(prj, jsonb_build_object(
    'secondary_hex', '#112233', 'accent_hex', '#334455',
    'light_neutral_hex', '#FFFFFF', 'dark_neutral_hex', '#000000', 'paper_hex', '#FAFAFA',
    'heading_font', 'Playfair Display', 'body_font', 'Source Sans 3'
  ));
  reset role;

  assert (select origin from public.brand_kits where id = kit) = 'imported',
         'importing every tracked field did not set origin to imported';
end
$$;

-- ---------------------------------------------------------------------------
-- Re-importing an already-imported field succeeds (the bypass, not a lock
-- violation) and updates the value
-- ---------------------------------------------------------------------------
do $$
declare
  prj uuid := 'e1111111-1111-4111-8111-111111111111';
  kit uuid := 'e2222222-2222-4222-8222-222222222222';
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ff111111-1111-4111-8111-111111111111"}';
  perform public.import_brand_identity(prj, '{"primary_hex":"#00FF00"}'::jsonb);
  reset role;

  assert (select primary_hex from public.site_specs where brand_kit_id = kit) = '#00FF00',
         're-importing an already-imported field was blocked by its own prior lock';
end
$$;

-- ---------------------------------------------------------------------------
-- Validation: bad hex, bad logo path
-- ---------------------------------------------------------------------------
do $$
declare
  prj uuid := 'e1111111-1111-4111-8111-111111111111';
  ok  boolean := false;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ff111111-1111-4111-8111-111111111111"}';

  begin
    perform public.import_brand_identity(prj, '{"primary_hex":"not-a-hex"}'::jsonb);
  exception when others then ok := true;
  end;
  assert ok, 'a malformed hex was accepted';

  ok := false;
  begin
    perform public.import_brand_identity(prj, '{"logo_svg_path":"not/org/scoped.svg"}'::jsonb);
  exception when others then ok := true;
  end;
  assert ok, 'a logo path outside org/ was accepted';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- A stranger — neither the project's own user nor the org owner — is refused
-- ---------------------------------------------------------------------------
do $$
declare
  prj uuid := 'e1111111-1111-4111-8111-111111111111';
  ok  boolean := false;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ff222222-2222-4222-8222-222222222222"}';
  begin
    perform public.import_brand_identity(prj, '{"primary_hex":"#123456"}'::jsonb);
  exception when others then ok := true;
  end;
  reset role;
  assert ok, 'a stranger imported a brand identity into someone else''s project';
end
$$;

rollback;
