-- ============================================================================
-- Tests — 20260901190000_codify_rls_auto_enable.sql
-- ============================================================================
-- Proves the event trigger actually fires and actually enables RLS with zero
-- policies — the same live check this migration's PR description reports,
-- reproduced here so it stays true.
-- ============================================================================
begin;

create table public._rls_auto_enable_probe (id int);
insert into public._rls_auto_enable_probe values (1), (2), (3);

do $$
declare
  v_rls    boolean;
  v_force  boolean;
  v_npol   int;
begin
  select relrowsecurity, relforcerowsecurity into v_rls, v_force
    from pg_class where relname = '_rls_auto_enable_probe';
  select count(*) into v_npol from pg_policies where tablename = '_rls_auto_enable_probe';

  assert v_rls is true,
    'ensure_rls did not enable RLS on a freshly created public table';
  assert v_force is false,
    'this migration only does ENABLE, never FORCE, row level security';
  assert v_npol = 0,
    'a table created with no policy statements should have zero policies';
end
$$;

-- The behavior this exists to prevent someone from re-discovering by hand:
-- RLS on with no policies is deny-all for anon/authenticated, and NOT an
-- error — a query that returns 0 rows looks exactly like an empty table.
do $$
declare
  v_count int;
begin
  set local role authenticated;
  select count(*) into v_count from public._rls_auto_enable_probe;
  reset role;
  assert v_count = 0,
    format('expected authenticated to see 0 rows (deny-all, no policies), got %s', v_count);
end
$$;

do $$
declare
  v_count int;
begin
  set local role anon;
  select count(*) into v_count from public._rls_auto_enable_probe;
  reset role;
  assert v_count = 0,
    format('expected anon to see 0 rows (deny-all, no policies), got %s', v_count);
end
$$;

do $$
declare
  v_count int;
begin
  set local role service_role;
  select count(*) into v_count from public._rls_auto_enable_probe;
  reset role;
  assert v_count = 3,
    format('expected service_role to bypass RLS and see all 3 rows, got %s', v_count);
end
$$;

rollback;
