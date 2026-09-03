-- ============================================================================
-- Tests — 20260903230000_color_export_formats.sql
-- ============================================================================
begin;

do $$
declare
  v_kind text;
  v_group text;
begin
  select kind, "group" into v_kind, v_group from public.asset_catalog where key = 'palette_ase';
  assert v_kind = 'ase' and v_group = 'color', 'palette_ase: unexpected shape';

  select kind, "group" into v_kind, v_group from public.asset_catalog where key = 'tokens_json';
  assert v_kind = 'json' and v_group = 'color', 'tokens_json: unexpected shape';

  select kind, "group" into v_kind, v_group from public.asset_catalog where key = 'colors_css';
  assert v_kind = 'css' and v_group = 'color', 'colors_css: unexpected shape';
end
$$;

do $$
declare v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
  select count(*) into v_count from public.asset_catalog
    where key in ('palette_ase', 'tokens_json', 'colors_css');
  reset role;
  assert v_count = 3, format('expected all three new keys visible to an authenticated caller, got %s', v_count);
end
$$;

rollback;
