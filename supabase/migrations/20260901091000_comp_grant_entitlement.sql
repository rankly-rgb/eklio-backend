-- ============================================================================
-- Eklio — an active comp grant satisfies entitlement like a paid purchase
-- ============================================================================
-- Follows `20260901090000_comp_access_grants.sql`.
--
-- MEASURED, NOT ASSUMED (full audit in the PR/commit description):
--   * Kit access, the PDF, and the site editor all gate through the ONE
--     chokepoint `brand_kit_entitled(uuid)`
--     (`20260829123000_entitlement_and_generation_credits.sql`), directly or
--     via `site_spec_entitlement_error`. That is the ONLY function this
--     migration changes for those three surfaces.
--   * Generation credits are a SEPARATE question from entitlement as of
--     `20260829125000_plans_and_granted_allowance.sql`: `consume_generation_credit`
--     no longer has an entitled/not branch at all, it reads the allowance from
--     `generation_credits.plan_tier` -> `plans`. Every plan, including `free`,
--     already grants `directions_limit = 3`; only `regenerations_limit` varies
--     by tier. A comp grant therefore only needs to widen the regeneration
--     ceiling — never bypass the counter that enforces it.
--   * Monthly Presence entitlement is NOT centralised in the database. It is
--     `isEntitledToMonthlyPresence()` in `eklio-frontend/lib/billing/entitlements.ts`,
--     a pure function over a raw `subscriptions` row — the DB deliberately
--     holds no clock (`subscriptions.active` is Stripe-liveness only; the
--     `past_due` grace period is explicitly application code, by design, per
--     that migration's own comments). There is no database chokepoint to OR a
--     comp check into without either (a) writing a fabricated `subscriptions`
--     row, which `stripe_subscription_id text not null unique` makes
--     impossible without inventing a fake Stripe id, or (b) an application-code
--     special case, which is out of scope ("no bypass in application code").
--     Per instruction for exactly this case: STOPPING here rather than
--     centralising Monthly Presence myself. A comp grant does not currently
--     unlock Monthly Presence; this is a known, reported gap, not an oversight.
-- ============================================================================


-- ============================================================================
-- 1. comp_grant_credits / comp_grant_active — the active predicate, once
-- ============================================================================
-- INTERNAL ONLY. Neither is granted to anon or authenticated: both take an
-- arbitrary p_user_id, and a signed-in caller must never be able to probe
-- another user's comp status by passing their id. They are called from inside
-- other SECURITY DEFINER function bodies below, which needs no grant of its
-- own — the object owner's privileges apply for the duration of the call.

create or replace function public.comp_grant_credits(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select g.generation_credits
    from public.comp_grants g
   where g.user_id = p_user_id
     and g.revoked_at is null
     and g.expires_at > now()
   limit 1
$$;

comment on function public.comp_grant_credits(uuid) is
  'The generation_credits of p_user_id''s active comp grant, or NULL when none is active. THE one place the active predicate is written: revoked_at IS NULL AND expires_at > now(), never `not (expires_at <= now())` — a NULL on either side must read as inactive, not active. INTERNAL ONLY, not granted to anon or authenticated.';

revoke execute on function public.comp_grant_credits(uuid) from public, anon, authenticated;

create or replace function public.comp_grant_active(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.comp_grant_credits(p_user_id) is not null
$$;

comment on function public.comp_grant_active(uuid) is
  'Whether p_user_id currently holds an active comp grant. Defined from comp_grant_credits so the active predicate is written exactly once. `is not null` on an integer-or-null never itself returns NULL, so this is never NULL either. INTERNAL ONLY, not granted to anon or authenticated.';

revoke execute on function public.comp_grant_active(uuid) from public, anon, authenticated;


-- ============================================================================
-- 2. brand_kit_entitled — the sentence gains one clause, still written once
-- ============================================================================
-- Same signature, same auth.uid() scoping, same ownership-before-entitlement
-- ordering (a stranger's kit still answers `not_found`, never `payment_required`,
-- because ownership is checked outside and before this OR). The only change is
-- the OR itself.

create or replace function public.brand_kit_entitled(p_brand_kit_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- ⚠ NOT `coalesce(..., false)` by accident: `exists` never returns NULL, and
  -- the auth.uid() comparison is inside it, so an unauthenticated caller gets
  -- FALSE rather than NULL.
  select exists (
    select 1
      from public.brand_kits bk
      join public.projects  pr on pr.id = bk.project_id
     where bk.id = p_brand_kit_id
       and pr.user_id = (select auth.uid())
       and (
         exists (
           select 1
             from public.purchases pu
            where pu.project_id = pr.id
              and pu.user_id = (select auth.uid())
              and pu.status = any (public.brand_kit_entitling_statuses())
         )
         or public.comp_grant_active((select auth.uid()))
       ))
$$;

comment on function public.brand_kit_entitled(uuid) is
  'THE definition of "this caller has paid for this brand kit" — an active comp grant satisfies it exactly like a paid purchase does. Everything that gates on payment calls this and nothing re-states it. auth.uid()-scoped: false for a kit that is not the caller''s, false when there is no caller, false when it is hers and neither bought nor comp''d. Covers kit access, the PDF route, and every site-editor RPC via site_spec_entitlement_error, since all of them already call this one function.';


-- ============================================================================
-- 3. consume_generation_credit — a comp grant widens the regeneration ceiling
-- ============================================================================
-- ⚠ NEVER LOWERS what a real purchase already granted (`greatest`), and never
-- touches `directions_limit` — every plan, including `free`, already grants the
-- same 3 directions per run; only `regenerations_limit` varies by tier. The
-- UPDATE statement, the atomicity, and the counter are UNCHANGED: a comp
-- account still spends from `generation_credits` and is still capped by it.
-- An account that never meets a limit cannot test the limit.

create or replace function public.consume_generation_credit(p_brand_kit_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_project     uuid;
  v_per_run     smallint;
  v_regen_limit smallint;
  v_comp_regen  integer;
  v_consumed    boolean;
begin
  if (select auth.uid()) is null then
    return false;
  end if;

  select bk.project_id into v_project
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
   where bk.id = p_brand_kit_id
     and pr.user_id = (select auth.uid());
  if v_project is null then
    return false;
  end if;

  insert into public.generation_credits (project_id) values (v_project)
  on conflict (project_id) do nothing;

  select pl.directions_limit, pl.regenerations_limit
    into v_per_run, v_regen_limit
    from public.generation_credits gc
    join public.plans pl on pl.tier = gc.plan_tier
   where gc.project_id = v_project;
  if v_per_run is null then
    return false;
  end if;

  v_comp_regen := public.comp_grant_credits((select auth.uid()));
  if v_comp_regen is not null then
    v_regen_limit := greatest(v_regen_limit, least(v_comp_regen, 32767)::smallint);
  end if;

  -- ⚠ ONE STATEMENT. The UPDATE takes the row lock, and under READ COMMITTED a
  -- concurrent caller that was waiting re-evaluates this WHERE against the row
  -- as the winner left it. Two simultaneous POSTs cannot both pass.
  update public.generation_credits gc
     set directions_generated =
           gc.directions_generated
           + case when gc.directions_generated = 0 then v_per_run else 0 end,
         regenerations_used =
           gc.regenerations_used
           + case when gc.directions_generated = 0 then 0 else 1 end
   where gc.project_id = v_project
     and (gc.directions_generated = 0 or gc.regenerations_used < v_regen_limit)
  returning true into v_consumed;

  return coalesce(v_consumed, false);
end
$$;

comment on function public.consume_generation_credit(uuid) is
  'Atomically spends one generation run, or returns false having spent nothing. The allowance comes from the project''s granted plan, widened (never narrowed) by an active comp grant''s generation_credits on the regeneration ceiling only. Calling this is the ONLY correct way to check: reading the counters and deciding is a race two concurrent requests both win.';


-- ============================================================================
-- 4. comp_access_active — the one signal the frontend may read
-- ============================================================================
-- auth.uid()-scoped only, no by-id variant: this can answer about yourself and
-- nothing else. It decides NOTHING about access — brand_kit_entitled and
-- consume_generation_credit above are still the only gates — it exists purely
-- so the UI can render a "Comp access" indicator without exposing reason,
-- granted_by, or expires_at from comp_grants.

create or replace function public.comp_access_active()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(public.comp_grant_active((select auth.uid())), false)
$$;

comment on function public.comp_access_active() is
  'Whether the CALLING user currently holds an active comp grant. auth.uid()-scoped only. Display signal for a "Comp access" indicator; grants no access on its own — brand_kit_entitled and consume_generation_credit remain the only gates.';

revoke execute on function public.comp_access_active() from public, anon;
grant execute on function public.comp_access_active() to authenticated, service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare fn text;
begin
  -- internal predicates: nobody but the owner may call them
  foreach fn in array array['comp_grant_credits(uuid)', 'comp_grant_active(uuid)'] loop
    if has_function_privilege('anon', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'anon can execute %', fn;
    end if;
    if has_function_privilege('authenticated', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'authenticated can execute %, which would let a client probe another user''s comp status', fn;
    end if;
  end loop;

  -- the display signal: authenticated only, never anon
  if has_function_privilege('anon', 'public.comp_access_active()'::regprocedure, 'EXECUTE') then
    raise exception 'anon can execute comp_access_active';
  end if;
  if not has_function_privilege('authenticated', 'public.comp_access_active()'::regprocedure, 'EXECUTE') then
    raise exception 'authenticated cannot execute comp_access_active';
  end if;

  -- entitlement is still never NULL
  if public.brand_kit_entitled(null) is not false then
    raise exception 'brand_kit_entitled: a null kit id did not answer false.';
  end if;
  if public.comp_grant_active(null) is not false then
    raise exception 'comp_grant_active: a null user id did not answer false.';
  end if;
  if public.consume_generation_credit(null) is not false then
    raise exception 'consume_generation_credit: a null kit id did not answer false.';
  end if;

  -- the paywall RPC surface is unchanged by this migration: still callable by
  -- authenticated, still refused to anon
  foreach fn in array array[
    'brand_kit_entitled(uuid)', 'brand_kit_is_owned(uuid)',
    'brand_kit_select_direction(uuid,text)', 'consume_generation_credit(uuid)',
    'site_spec_entitlement_error(uuid)'
  ] loop
    if has_function_privilege('anon', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'anon can still execute %', fn;
    end if;
    if not has_function_privilege('authenticated', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'authenticated can no longer execute %', fn;
    end if;
  end loop;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   grant execute on function public.comp_grant_active(uuid) to anon, authenticated;
--   -- restore consume_generation_credit from 20260829125000 (drops v_comp_regen);
--   -- restore brand_kit_entitled from 20260829123000 (drops the comp_grant_active OR);
--   drop function if exists public.comp_access_active();
--   drop function if exists public.comp_grant_active(uuid);
--   drop function if exists public.comp_grant_credits(uuid);
