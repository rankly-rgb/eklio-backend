-- ============================================================================
-- Tests — 20260903160000_asset_catalog_trimmed_dims_null.sql
-- ============================================================================
begin;

do $$
declare
  v_width int;
  v_height int;
begin
  select width, height into v_width, v_height
    from public.asset_catalog where key = 'wordmark_png_dark';

  assert v_width is null, format('expected wordmark_png_dark.width null, got %s', v_width);
  assert v_height is null, format('expected wordmark_png_dark.height null, got %s', v_height);
end
$$;

rollback;
