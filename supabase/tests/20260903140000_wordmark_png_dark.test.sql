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
  -- NOT 960x240: this migration seeded the untrimmed satori canvas size,
  -- but 20260903160000_asset_catalog_trimmed_dims_null.sql supersedes it —
  -- trim-to-ink-bounds means the real output size varies per kit, so the
  -- catalog-level value is null from that migration onward. The full test
  -- suite runs against the CUMULATIVE state after every migration, this
  -- one included, so this assertion has to match what's true NOW, not what
  -- was true for the few minutes between these two migrations.
  assert v_width is null, format('expected width null (superseded by 20260903160000), got %s', v_width);
  assert v_height is null, format('expected height null (superseded by 20260903160000), got %s', v_height);
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
