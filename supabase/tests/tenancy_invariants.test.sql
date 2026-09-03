-- ============================================================================
-- Tests — tenancy layer: assert_tenancy_invariants()
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- The gate passes on the schema as this migration set left it
-- ---------------------------------------------------------------------------
do $$
declare ok boolean := true;
begin
  begin
    perform public.assert_tenancy_invariants();
  exception when others then ok := false;
  end;
  assert ok, 'assert_tenancy_invariants raised on an unmodified schema';
end
$$;

-- ---------------------------------------------------------------------------
-- It is service_role only
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('anon', 'public.assert_tenancy_invariants()'::regprocedure, 'EXECUTE'),
         'anon can execute assert_tenancy_invariants';
  assert not has_function_privilege('authenticated', 'public.assert_tenancy_invariants()'::regprocedure, 'EXECUTE'),
         'a signed-in client can execute assert_tenancy_invariants';
end
$$;

-- ---------------------------------------------------------------------------
-- The table-enumeration test actually catches an unpolicied RLS table
-- ---------------------------------------------------------------------------
-- create table fires the ensure_rls event trigger, same as any real table:
-- RLS on, zero policies. This proves invariant 1 is load-bearing, not a
-- no-op — inside this same transaction, rolled back at the end either way.
do $$
declare ok boolean := false;
begin
  create table public.tenancy_invariants_throwaway (id int primary key);

  begin
    perform public.assert_tenancy_invariants();
  exception when others then ok := true;
  end;
  assert ok, 'assert_tenancy_invariants did not catch an RLS-enabled table with no policy';
end
$$;

rollback;
