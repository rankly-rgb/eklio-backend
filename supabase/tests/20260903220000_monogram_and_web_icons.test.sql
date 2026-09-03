-- ============================================================================
-- Tests — 20260903220000_monogram_and_web_icons.sql
-- ============================================================================
begin;

do $$
declare
  v_kind text;
  v_width int;
  v_height int;
  v_group text;
  v_min_tier text;
begin
  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'monogram_svg';
  assert v_kind = 'svg' and v_width is null and v_height is null and v_group = 'identity',
    'monogram_svg: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'monogram_png_512_primary';
  assert v_kind = 'png' and v_width = 512 and v_height = 512 and v_group = 'identity',
    'monogram_png_512_primary: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'monogram_png_512_paper';
  assert v_kind = 'png' and v_width = 512 and v_height = 512 and v_group = 'identity',
    'monogram_png_512_paper: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'monogram_png_512_transparent';
  assert v_kind = 'png' and v_width = 512 and v_height = 512 and v_group = 'identity',
    'monogram_png_512_transparent: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'favicon_16';
  assert v_kind = 'png' and v_width = 16 and v_height = 16 and v_group = 'web',
    'favicon_16: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'favicon_32';
  assert v_kind = 'png' and v_width = 32 and v_height = 32 and v_group = 'web',
    'favicon_32: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'apple_touch_icon_180';
  assert v_kind = 'png' and v_width = 180 and v_height = 180 and v_group = 'web',
    'apple_touch_icon_180: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'icon_512';
  assert v_kind = 'png' and v_width = 512 and v_height = 512 and v_group = 'web',
    'icon_512: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'manifest_values_json';
  assert v_kind = 'json' and v_width is null and v_height is null and v_group = 'web',
    'manifest_values_json: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'avatar_400';
  assert v_kind = 'png' and v_width = 400 and v_height = 400 and v_group = 'social',
    'avatar_400: unexpected shape';
end
$$;

do $$
declare v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
  select count(*) into v_count from public.asset_catalog
    where key in (
      'monogram_svg', 'monogram_png_512_primary', 'monogram_png_512_paper',
      'monogram_png_512_transparent', 'favicon_16', 'favicon_32',
      'apple_touch_icon_180', 'icon_512', 'manifest_values_json', 'avatar_400'
    );
  reset role;
  assert v_count = 10, format('expected all ten new keys visible to an authenticated caller, got %s', v_count);
end
$$;

rollback;
