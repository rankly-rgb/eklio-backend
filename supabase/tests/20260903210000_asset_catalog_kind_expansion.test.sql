-- ============================================================================
-- Tests — 20260903210000_asset_catalog_kind_expansion.sql
-- ============================================================================
begin;

-- Every new kind is now accepted by the CHECK constraint.
do $$
declare v_kind text;
begin
  foreach v_kind in array array['json', 'css', 'ase', 'html', 'zip']
  loop
    insert into public.asset_catalog (key, "group", label, description, kind, min_tier)
    values ('probe_' || v_kind, 'web', 'probe', 'probe', v_kind, 'starter');
  end loop;

  perform 1 from public.asset_catalog where key like 'probe_%';
  assert (select count(*) from public.asset_catalog where key like 'probe_%') = 5,
    'expected all five new kinds to be insertable';
end
$$;

-- An unlisted kind is still refused.
do $$
begin
  begin
    insert into public.asset_catalog (key, "group", label, description, kind, min_tier)
    values ('probe_bogus', 'web', 'probe', 'probe', 'bogus', 'starter');
    raise exception 'expected asset_catalog_kind_check to reject an unlisted kind';
  exception
    when check_violation then
      null; -- expected
  end;
end
$$;

-- brand_assets carries the same widened set (its FK to asset_catalog.key
-- already forces kind to match the catalog row, but the CHECK is
-- independent and must not be stricter than the catalog's own).
do $$
declare
  v_user uuid := 'b1111111-1111-1111-1111-111111111111';
  v_project uuid := 'b2222222-2222-2222-2222-222222222222';
  v_kit uuid := 'b3333333-3333-3333-3333-333333333333';
begin
  insert into auth.users (id, email) values (v_user, 'kindtest@example.com');
  insert into public.projects (id, user_id, name) values (v_project, v_user, 'Kind Test');
  insert into public.project_briefs (project_id, practice_name, license_type_id, city, state)
    values (v_project, 'Kind Test', 'lcsw', 'Salem', 'OR');
  insert into public.brand_kits (id, project_id) values (v_kit, v_project);

  insert into public.brand_assets (brand_kit_id, user_id, key, kind, byte_size, storage_path, fingerprint)
  values (v_kit, v_user, 'probe_json', 'json', 10, v_kit::text || '/f/probe_json.json', repeat('a', 16));

  assert (select kind from public.brand_assets where key = 'probe_json') = 'json',
    'expected brand_assets to accept kind=json now that asset_catalog does';
end
$$;

rollback;
