-- ============================================================================
-- Eklio — tenancy layer, lot A2: anon_surface_baseline replaces the static
-- anon-SELECT / anon-EXECUTE allowlists in assert_tenancy_invariants()
-- ============================================================================
-- The two allowlists in 20260903103000_tenancy_invariants.sql were derived by
-- grepping migration files — an environment assumption, not a design fact,
-- and one this session already found wrong once (extension-owned functions).
-- A snapshot beats a hard-coded list here because it needs no assumption
-- about what the live database holds: it just records that, once, and flags
-- what changes. Invariant 1's allowlist is untouched in kind — which tables
-- are deliberately zero-policy is a designed fact, known at migration time,
-- not something to baseline — but grows from five entries to six, because
-- this migration adds exactly one more table in that same class.
-- ============================================================================

create table public.anon_surface_baseline (
  object_kind text not null check (object_kind in ('table', 'function')),
  object_name text not null,
  recorded_at timestamptz not null default now(),
  constraint anon_surface_baseline_pkey primary key (object_kind, object_name)
);

comment on table public.anon_surface_baseline is
  'Snapshot of anon-reachable public objects (SELECT-able tables, EXECUTE-able functions, matched by name — not by signature, so overloads share one row), recorded once below from whatever the database actually held at that moment. assert_tenancy_invariants() raises only on objects added since — a growing anon surface is a defect, a shrinking one is progress, never flagged.';

alter table public.anon_surface_baseline enable row level security;
revoke all on public.anon_surface_baseline from anon, authenticated;
-- No client policy: RLS on, zero policy, zero privilege — the same
-- service-role-only pattern as stripe_events/comp_grants, and why this
-- table is now the sixth entry in invariant 1's allowlist below, not a
-- seventh table invariant 1 would otherwise raise on immediately.

insert into public.anon_surface_baseline (object_kind, object_name)
select 'table', c.relname
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind = 'r'
   and has_table_privilege('anon', c.oid, 'select');

insert into public.anon_surface_baseline (object_kind, object_name)
select distinct 'function', p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and has_function_privilege('anon', p.oid, 'execute')
   and not exists (
     select 1 from pg_depend d
      where d.objid = p.oid and d.deptype = 'e'
   );


create or replace function public.assert_tenancy_invariants()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad_table       text;
  v_bad_grant_table text;
  v_bad_func        text;
  v_null_org        bigint;
  v_bad_owner_count bigint;
begin
  -- 1. Every RLS-enabled table in public has at least one policy, except the
  -- six deliberately service-role-only tables.
  select c.relname into v_bad_table
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relrowsecurity
     and c.relname not in (
       'app_settings', 'banned_phrases', 'comp_grants', 'stripe_events',
       'usp_stopwords', 'anon_surface_baseline'
     )
     and not exists (
       select 1 from pg_policies pol
        where pol.schemaname = 'public' and pol.tablename = c.relname
     )
   limit 1;

  if v_bad_table is not null then
    raise exception 'assert_tenancy_invariants: table % has RLS enabled and no policy', v_bad_table;
  end if;

  -- 2. No table grants SELECT to anon beyond what anon_surface_baseline
  -- recorded — a NEW anon-readable table is what raises, not any name absent
  -- from a list nobody re-derives.
  select c.relname into v_bad_grant_table
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and has_table_privilege('anon', c.oid, 'select')
     and not exists (
       select 1 from public.anon_surface_baseline b
        where b.object_kind = 'table' and b.object_name = c.relname
     )
   limit 1;

  if v_bad_grant_table is not null then
    raise exception 'assert_tenancy_invariants: table % grants SELECT to anon and is not in anon_surface_baseline — the anon surface grew', v_bad_grant_table;
  end if;

  -- 3. No function grants EXECUTE to anon beyond the baseline, still
  -- excluding extension-owned functions by pg_depend (not by name — see
  -- 20260903103000_tenancy_invariants.sql for why a name-based exclusion
  -- broke on pg_trgm/pgcrypto/citext's own support functions).
  select p.proname into v_bad_func
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and not exists (
       select 1 from pg_depend d
        where d.objid = p.oid and d.deptype = 'e'
     )
     and not exists (
       select 1 from public.anon_surface_baseline b
        where b.object_kind = 'function' and b.object_name = p.proname
     )
   limit 1;

  if v_bad_func is not null then
    raise exception 'assert_tenancy_invariants: function % is executable by anon and is not in anon_surface_baseline — the anon surface grew', v_bad_func;
  end if;

  -- 4. Every project has an organization.
  select count(*) into v_null_org from public.projects where organization_id is null;
  if v_null_org > 0 then
    raise exception 'assert_tenancy_invariants: % project(s) have a null organization_id', v_null_org;
  end if;

  -- 5. Every organization has exactly one active owner.
  select count(*) into v_bad_owner_count
    from public.organizations o
   where (
     select count(*) from public.organization_members m
      where m.organization_id = o.id and m.role = 'owner' and m.status = 'active'
   ) <> 1;

  if v_bad_owner_count > 0 then
    raise exception 'assert_tenancy_invariants: % organization(s) do not have exactly one active owner', v_bad_owner_count;
  end if;
end;
$$;

comment on function public.assert_tenancy_invariants() is
  'Push-time gate: raises on the first violated tenancy invariant. Invariants 2 and 3 diff against anon_surface_baseline rather than a hard-coded list — see that table''s comment. Run by the terminal select in this migration; not a client entry point.';

select public.assert_tenancy_invariants();
