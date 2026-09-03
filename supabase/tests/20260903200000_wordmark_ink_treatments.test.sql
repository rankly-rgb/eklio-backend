-- ============================================================================
-- Tests — 20260903200000_wordmark_ink_treatments.sql
-- ============================================================================
begin;

do $$
declare
  v_kind text;
  v_width int;
  v_height int;
  v_group text;
begin
  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'wordmark_svg_light';
  assert v_kind = 'svg', format('wordmark_svg_light: expected kind svg, got %s', v_kind);
  assert v_width is null, 'wordmark_svg_light: expected width null (trims to ink)';
  assert v_height is null, 'wordmark_svg_light: expected height null (trims to ink)';
  assert v_group = 'identity', format('wordmark_svg_light: expected group identity, got %s', v_group);

  select kind, width, height into v_kind, v_width, v_height
    from public.asset_catalog where key = 'wordmark_svg_mono_black';
  assert v_kind = 'svg', format('wordmark_svg_mono_black: expected kind svg, got %s', v_kind);
  assert v_width is null and v_height is null, 'wordmark_svg_mono_black: expected null dims';

  select kind, width, height into v_kind, v_width, v_height
    from public.asset_catalog where key = 'wordmark_svg_mono_white';
  assert v_kind = 'svg', format('wordmark_svg_mono_white: expected kind svg, got %s', v_kind);
  assert v_width is null and v_height is null, 'wordmark_svg_mono_white: expected null dims';

  select kind, width, height into v_kind, v_width, v_height
    from public.asset_catalog where key = 'wordmark_png_light_1200';
  assert v_kind = 'png', format('wordmark_png_light_1200: expected kind png, got %s', v_kind);
  assert v_width = 1200, format('wordmark_png_light_1200: expected width 1200, got %s', v_width);
  assert v_height is null, 'wordmark_png_light_1200: expected height null (aspect varies)';

  select kind, width, height into v_kind, v_width, v_height
    from public.asset_catalog where key = 'wordmark_png_light_2400';
  assert v_kind = 'png', format('wordmark_png_light_2400: expected kind png, got %s', v_kind);
  assert v_width = 2400, format('wordmark_png_light_2400: expected width 2400, got %s', v_width);
  assert v_height is null, 'wordmark_png_light_2400: expected height null (aspect varies)';
end
$$;

do $$
declare v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
  select count(*) into v_count from public.asset_catalog
    where key in (
      'wordmark_svg_light', 'wordmark_svg_mono_black', 'wordmark_svg_mono_white',
      'wordmark_png_light_1200', 'wordmark_png_light_2400'
    );
  reset role;
  assert v_count = 5, format('expected all five new keys visible to an authenticated caller, got %s', v_count);
end
$$;

rollback;
