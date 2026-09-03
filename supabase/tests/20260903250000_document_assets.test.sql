-- ============================================================================
-- Tests — 20260903250000_document_assets.sql
-- ============================================================================
begin;

-- The new kind is accepted; an unlisted one is still refused.
do $$
begin
  insert into public.asset_catalog (key, "group", label, description, kind, min_tier)
  values ('probe_md', 'document', 'probe', 'probe', 'md', 'starter');
  assert (select count(*) from public.asset_catalog where key = 'probe_md') = 1;

  begin
    insert into public.asset_catalog (key, "group", label, description, kind, min_tier)
    values ('probe_bogus2', 'document', 'probe', 'probe', 'bogus', 'starter');
    raise exception 'expected asset_catalog_kind_check to still reject an unlisted kind';
  exception
    when check_violation then null;
  end;
end
$$;

do $$
declare
  v_kind text;
  v_width int;
  v_height int;
  v_group text;
begin
  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'email_signature_html';
  assert v_kind = 'html' and v_width is null and v_height is null and v_group = 'document',
    'email_signature_html: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'email_signature_png';
  assert v_kind = 'png' and v_width = 640 and v_height = 220 and v_group = 'document',
    'email_signature_png: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'site_setup_md';
  assert v_kind = 'md' and v_width is null and v_height is null and v_group = 'document',
    'site_setup_md: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'brand_kit_zip';
  assert v_kind = 'zip' and v_width is null and v_height is null and v_group = 'document',
    'brand_kit_zip: unexpected shape';
end
$$;

do $$
declare v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
  select count(*) into v_count from public.asset_catalog
    where key in ('email_signature_html', 'email_signature_png', 'site_setup_md', 'brand_kit_zip');
  reset role;
  assert v_count = 4, format('expected all four new keys visible to an authenticated caller, got %s', v_count);
end
$$;

rollback;
