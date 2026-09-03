-- ============================================================================
-- Tests — 20260903140000_wordmark_png_dark.sql
-- ============================================================================
begin;

do $$
declare
  v_kind text;
  v_width int;
  v_height int;
  v_min_tier text;
begin
  select kind, width, height, min_tier into v_kind, v_width, v_height, v_min_tier
    from public.asset_catalog where key = 'wordmark_png_dark';

  assert v_kind = 'png', format('expected kind png, got %s', v_kind);
  assert v_width = 960, format('expected width 960, got %s', v_width);
  assert v_height = 240, format('expected height 240, got %s', v_height);
  assert v_min_tier = 'starter', format('expected min_tier starter, got %s', v_min_tier);
end
$$;

-- Reference data, same read rule as the rest of asset_catalog: any
-- authenticated caller sees it.
do $$
declare v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
  select count(*) into v_count from public.asset_catalog where key = 'wordmark_png_dark';
  reset role;
  assert v_count = 1, 'wordmark_png_dark is not visible to an authenticated caller';
end
$$;

rollback;
