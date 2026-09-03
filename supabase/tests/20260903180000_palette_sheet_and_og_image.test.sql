-- ============================================================================
-- Tests — 20260903180000_palette_sheet_and_og_image.sql
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
    from public.asset_catalog where key = 'palette_sheet_png';
  assert v_kind = 'png', format('palette_sheet_png: expected kind png, got %s', v_kind);
  assert v_width = 1200, format('palette_sheet_png: expected width 1200, got %s', v_width);
  assert v_height = 600, format('palette_sheet_png: expected height 600, got %s', v_height);
  assert v_group = 'color', format('palette_sheet_png: expected group color, got %s', v_group);

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'og_image_1200x630';
  assert v_kind = 'png', format('og_image_1200x630: expected kind png, got %s', v_kind);
  assert v_width = 1200, format('og_image_1200x630: expected width 1200, got %s', v_width);
  assert v_height = 630, format('og_image_1200x630: expected height 630, got %s', v_height);
  assert v_group = 'web', format('og_image_1200x630: expected group web, got %s', v_group);
end
$$;

do $$
declare v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
  select count(*) into v_count from public.asset_catalog
    where key in ('palette_sheet_png', 'og_image_1200x630');
  reset role;
  assert v_count = 2, format('expected both new keys visible to an authenticated caller, got %s', v_count);
end
$$;

rollback;
