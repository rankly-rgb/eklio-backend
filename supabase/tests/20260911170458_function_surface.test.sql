-- ============================================================================
-- Tests — the anonymous function surface
-- ============================================================================
-- THE THIRD ENUMERATION IN THIS PROJECT, and the same shape as the other two:
-- routes are enumerated in the frontend, tables are enumerated by their
-- policies, and functions are enumerated here. That is not repetition. This
-- codebase does not fail with errors, it fails with plausible values, and
-- enumeration is the only thing that catches a plausible value.
--
-- ── WHY THIS FILE EXISTS AND THE MIGRATION'S OWN GUARD RAIL DOES NOT SUFFICE
--
-- 20260902090000 revoked EXECUTE on eighteen functions and carried a guard
-- rail asserting `anon` could no longer call them. It passed. Seventeen of the
-- eighteen have their grants back today.
--
-- A guard rail inside a migration asserts A MOMENT: the instant that migration
-- ran, once, months ago. This file asserts A STATE, on a database rebuilt by
-- replaying every migration, on every push. That is the whole difference, and
-- it is why the rule moved out of the migration and into here.
--
-- ⚠ IT IS NOT A SUBSTITUTE FOR THE CHECK INSIDE THE FUNCTION. CI rebuilds from
-- migrations; it cannot see production drift. The in-body authority check
-- (20260911170458) is what holds when the grants move underneath us. This file
-- stops the NEXT function being written without one.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 0. Anti-vacuous: the sweep finds a surface at all
-- ---------------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f';
  -- A broken sweep would make every assertion below vacuously true, which is
  -- the worst kind of green.
  assert v_n > 80, format('only %s functions found in public — the sweep is broken', v_n);

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef;
  assert v_n > 50, format('only %s SECURITY DEFINER functions found — the sweep is broken', v_n);
end
$$;

-- ---------------------------------------------------------------------------
-- 1. No trigger or event-trigger function is in the anonymous surface
-- ---------------------------------------------------------------------------
-- They fail if called as an RPC, but they are PUBLISHED in PostgREST's
-- anonymous OpenAPI document, which is how someone learns the schema.
do $$
declare offenders text;
begin
  select string_agg(p.proname || '()', ', ' order by p.proname)
    into offenders
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
     and (has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));

  assert offenders is null, coalesce(
    'Trigger functions reachable from the browser: ' || offenders ||
    '. Revoke them: they are called by the database, never by a client.', '');
end
$$;

-- ---------------------------------------------------------------------------
-- 2. ⚠ THE RULE: a SECURITY DEFINER function the browser can call must
--    assert its own caller
-- ---------------------------------------------------------------------------
-- "Asserts its own caller" is computed as a TRANSITIVE CLOSURE over function
-- bodies: a function qualifies if it reads `auth.uid()` or `auth.role()`
-- itself, or if it calls something that does. A first attempt at this rule
-- guessed at helper names instead and produced a false accusation against
-- `brand_kit_select_direction`, which gates correctly through
-- `site_spec_entitlement_error`. Guessing at names does not scale to 100
-- functions; following the call graph does.
do $$
declare offenders text;
begin
  with recursive fn as (
    select p.oid, p.proname, p.prosecdef,
           p.prorettype::regtype::text as rettype,
           pg_get_functiondef(p.oid) as def,
           pg_get_function_identity_arguments(p.oid) as args,
           p.proacl as acl
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
  ),
  gated as (
    select oid, proname from fn where def ~ 'auth\.(uid|role)\(\)'
    union
    select f.oid, f.proname
      from fn f join gated g on f.def ~ ('\m' || g.proname || '\s*\(')
     where f.proname <> g.proname
  )
  select string_agg(f.proname || '(' || f.args || ')', ', ' order by f.proname)
    into offenders
    from fn f
   where f.prosecdef
     and f.rettype not in ('trigger', 'event_trigger')
     /*
      * ⚠ `has_function_privilege('PUBLIC', …)` IS NOT A THING — PUBLIC is a
      * grant target, not a role, and that spelling raises 42704 "role PUBLIC
      * does not exist". The PUBLIC grant is the ACL entry with an empty
      * grantee (`=X/owner`), which `aclexplode` reports as grantee 0; a NULL
      * acl means the column was never touched, which in PostgreSQL means
      * PUBLIC has EXECUTE.
      */
     and (has_function_privilege('anon', f.oid, 'execute')
       or f.acl is null
       or exists (select 1 from aclexplode(f.acl) a
                   where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
     and f.oid not in (select oid from gated)
     /*
      * ⚠ THE ONE EXEMPTION, AND IT IS NAMED RATHER THAN INFERRED.
      *
      * `anon_token_hash()` MUST be callable by `anon`: the RLS policies on
      * `projects` call it, and a policy executes as the CALLER's role.
      * Revoking it would lock every anonymous visitor out of her own brief.
      * It reads one request header and returns a sha256 of it — it grants
      * nothing, reveals nothing, and takes no argument to be indexed by.
      *
      * Anything else appearing here is a function the browser can call that
      * never asks who is calling. Add an in-body check, or revoke it.
      */
     and f.proname <> 'anon_token_hash';

  assert offenders is null, coalesce(
    'SECURITY DEFINER functions callable by anon/PUBLIC with no in-body ' ||
    'authority check: ' || offenders ||
    '. A REVOKE is a fact about a moment; a check in the body is a fact about ' ||
    'the function. Write the check.', '');
end
$$;

-- ---------------------------------------------------------------------------
-- 3. CANARY — the rule bites
-- ---------------------------------------------------------------------------
-- A rule that has stopped matching anything looks exactly like a rule that is
-- satisfied. This creates the offence the rule exists to catch and requires
-- the same query to find it, then rolls it away.
do $$
declare found boolean;
begin
  execute $fn$
    create or replace function public.zzz_canary_gateless(p_id uuid)
    returns text language sql stable security definer set search_path = ''
    as 'select ''leaked'''
  $fn$;
  execute 'grant execute on function public.zzz_canary_gateless(uuid) to anon';

  with recursive fn as (
    select p.oid, p.proname, p.prosecdef,
           p.prorettype::regtype::text as rettype,
           pg_get_functiondef(p.oid) as def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
  ),
  gated as (
    select oid, proname from fn where def ~ 'auth\.(uid|role)\(\)'
    union
    select f.oid, f.proname from fn f join gated g on f.def ~ ('\m' || g.proname || '\s*\(')
     where f.proname <> g.proname
  )
  select exists (
    select 1 from fn f
     where f.prosecdef
       and f.rettype not in ('trigger','event_trigger')
       and has_function_privilege('anon', f.oid, 'execute')
       and f.oid not in (select oid from gated)
       and f.proname = 'zzz_canary_gateless'
  ) into found;

  assert found, 'the rule in section 2 did not catch a deliberately gateless, anon-callable SECURITY DEFINER function';

  execute 'drop function public.zzz_canary_gateless(uuid)';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. The three functions rewritten on 2026-09-11 still carry their checks
-- ---------------------------------------------------------------------------
do $$
declare missing text;
begin
  select string_agg(name, ', ' order by name) into missing
    from (values ('purchase_status_before'), ('site_spec_default_target'),
                 ('brand_images_setting_int')) as t(name)
   where not exists (
     select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = t.name
        and pg_get_functiondef(p.oid) like '%auth.role()%');

  assert missing is null, coalesce(
    'These lost their in-body authority check: ' || missing, '');
end
$$;

-- `site_spec_default_target` in particular must resolve through
-- `owns_project`, which honours the anonymous token — `brand_kit_is_owned` is
-- auth.uid()-only and would silently degrade every anonymous kit to 'generic'.
do $$
begin
  assert exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'site_spec_default_target'
       and pg_get_functiondef(p.oid) like '%owns_project%'),
    'site_spec_default_target must use owns_project (token-aware), not brand_kit_is_owned';
end
$$;

rollback;
