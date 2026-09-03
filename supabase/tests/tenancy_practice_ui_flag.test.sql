-- ============================================================================
-- Tests — tenancy layer, lot D1: practice_ui_enabled
-- ============================================================================
begin;

do $$
begin
  assert (select value from public.app_settings where key = 'practice_ui_enabled') = 'false'::jsonb,
    'practice_ui_enabled must default to false';
end
$$;

-- ---------------------------------------------------------------------------
-- Same lockdown as every other app_settings row: authenticated cannot read
-- it directly (isPracticeUiEnabled() must run server-side with the
-- service-role key, never as a client-side read).
-- ---------------------------------------------------------------------------
do $$
begin
  set local role authenticated;
  begin
    perform 1 from public.app_settings where key = 'practice_ui_enabled';
    raise exception 'FAIL: authenticated could select from app_settings';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated blocked from app_settings';
  end;
  reset role;
end
$$;

rollback;
