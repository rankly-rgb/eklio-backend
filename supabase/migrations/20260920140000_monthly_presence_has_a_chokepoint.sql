-- ============================================================================
-- Eklio — Monthly Presence gets the database chokepoint it never had
-- ============================================================================
-- This migration LIFTS A DOCUMENTED STOP. `20260901182419_comp_grant_entitlement`
-- ended its header with this, and then did nothing about it:
--
--   > Monthly Presence entitlement is NOT centralised in the database. […]
--   > There is no database chokepoint to OR a comp check into without either
--   > (a) writing a fabricated `subscriptions` row, which
--   > `stripe_subscription_id text not null unique` makes impossible without
--   > inventing a fake Stripe id, or (b) an application-code special case,
--   > which is out of scope. Per instruction for exactly this case: STOPPING
--   > here rather than centralising Monthly Presence myself. A comp grant does
--   > not currently unlock Monthly Presence; this is a known, reported gap,
--   > not an oversight.
--
-- ── WHY THE OBJECTION NO LONGER HOLDS ────────────────────────────────────
--
-- Objection (a) was about writing a ROW. Nothing here writes one: the comp
-- clause is a function call, exactly as `brand_kit_entitled` already does it.
-- Objection (b) was about scattering a special case through the callers; a
-- single function is the opposite of that.
--
-- What remains is the real reason it was left in TypeScript, stated in
-- `20260827106000_subscription_state`: the past_due grace period needs a
-- CLOCK, and a clock has no place in a stored generated column. True — of a
-- COLUMN. `subscriptions.active` stays exactly what it is (Stripe liveness,
-- never the gate). A FUNCTION may read `now()`, and every other gate in this
-- schema already does.
--
-- ── WHY IT HAS TO MOVE NOW ───────────────────────────────────────────────
--
-- Because the content pipeline is about to spend money. `canUseMonthlyPresence`
-- in TypeScript is a fine answer to "what should this screen show"; it is not
-- a place to decide whether a paid API call may happen, because nothing stops
-- the next caller from not asking. Every credit reservation in
-- `20260920140100` goes through this function, in the database, and a caller
-- that forgets gets no credit rather than a free one.
--
-- ── THE TWO-FUNCTION SHAPE, AND WHY IT IS NOT ONE ────────────────────────
--
-- The same shape `comp_grant_active` / `comp_access_active` already uses, for
-- the same reason. A function that takes an arbitrary `p_user` and answers a
-- question about their money must NEVER be callable by a signed-in client:
-- that is a subscription-status probe on any account whose uuid you can guess.
-- So:
--
--   check_monthly_presence_entitlement(uuid)  arbitrary user, service_role only
--   monthly_presence_entitled()               auth.uid()-scoped, authenticated
--
-- The second is defined FROM the first, so the rule is written once.
--
-- ⚠ NULL-SAFETY. Every branch below answers true or false and never NULL:
--   * `exists` never returns NULL;
--   * `comp_grant_active` is `<integer> is not null`, which never returns NULL;
--   * `p_user is not null and (...)` short-circuits before either.
-- The past_due arm never compares NULL to the clock: `current_period_end is
-- not null` is tested before the addition, never as `not (… <= now())`, which
-- a NULL would make TRUE. That is the same trap `comp_grants` names in its own
-- table comment, and it is the one that leaks a permissive default.
-- ============================================================================


-- ============================================================================
-- 1. monthly_presence_past_due_grace — three days, written once
-- ============================================================================
-- It was `PAST_DUE_GRACE_DAYS = 3` in `lib/billing/entitlements.ts`, and that
-- file keeps it as a constant it EXPORTS for copy and for tests — but it is no
-- longer the constant anything DECIDES with. A function rather than a literal
-- inside the gate below, so that changing the commercial choice is a migration
-- with a diff rather than an edit inside a WHERE clause.
--
-- It exists for a card that was refused this morning: Stripe retries, and three
-- days is almost always enough. It is not a grace on cancellation.

create or replace function public.monthly_presence_past_due_grace()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '3 days'
$$;

comment on function public.monthly_presence_past_due_grace() is
  'How long a past_due subscription keeps Monthly Presence while Stripe retries the card. THE one place the three days are written. A commercial choice, so it is a function with a diff rather than a literal buried in a predicate.';

revoke all on function public.monthly_presence_past_due_grace() from public;
grant execute on function public.monthly_presence_past_due_grace() to authenticated, service_role;


-- ============================================================================
-- 2. check_monthly_presence_entitlement — THE gate, arbitrary user, internal
-- ============================================================================
-- The exact sentence `isEntitledToMonthlyPresence` was computing, plus the comp
-- clause it could never reach:
--
--   status ∈ {active, trialing}
--   OR (status = 'past_due' AND current_period_end + grace > now())
--   OR an active comp grant
--
-- ⚠ `comp_grant_active` IS NOT GRANTED TO ANYONE, and must not become so. It
-- is reachable here because a SECURITY DEFINER body runs with the owner's
-- privileges for the duration of the call — the same way `brand_kit_entitled`
-- reaches it. Adding a GRANT to make this "work" would open a comp-status
-- probe on every account, which its own migration's guard rail refuses.

create or replace function public.check_monthly_presence_entitlement(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user is not null
     and (
       exists (
         select 1
           from public.subscriptions s
          where s.user_id = p_user
            and (
              s.status in ('active', 'trialing')
              or (
                s.status = 'past_due'
                -- A past_due with no known period end opens nothing: we do not
                -- invent a grace date we were never given.
                and s.current_period_end is not null
                and s.current_period_end + public.monthly_presence_past_due_grace() > now()
              )
            )
       )
       or public.comp_grant_active(p_user)
     )
$$;

comment on function public.check_monthly_presence_entitlement(uuid) is
  'THE definition of "this user may use Monthly Presence": an active or trialing subscription, or a past_due one still inside the retry grace, or an active comp grant. Every credit reservation goes through this. INTERNAL ONLY — it answers about an arbitrary user, so granting it to authenticated would be a subscription-status probe on any uuid. Clients call monthly_presence_entitled() instead. Never returns NULL.';

revoke all on function public.check_monthly_presence_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.check_monthly_presence_entitlement(uuid) to service_role;


-- ============================================================================
-- 3. monthly_presence_entitled — the same sentence, about yourself
-- ============================================================================
-- What `lib/billing/entitlements.ts` calls from a SESSION client. It decides
-- nothing of its own: it is §2 with `auth.uid()` substituted, so there is one
-- rule and not two that agree for now.

create or replace function public.monthly_presence_entitled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.check_monthly_presence_entitlement((select auth.uid()))
$$;

comment on function public.monthly_presence_entitled() is
  'Whether the CALLING user may use Monthly Presence. auth.uid()-scoped, defined from check_monthly_presence_entitlement so the rule is written exactly once. False when there is no caller.';

revoke all on function public.monthly_presence_entitled() from public, anon;
grant execute on function public.monthly_presence_entitled() to authenticated, service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_user uuid;
  v_sub  uuid;
begin
  -- ---- NULL answers false, never NULL ------------------------------------
  if public.check_monthly_presence_entitlement(null) is not false then
    raise exception 'check_monthly_presence_entitlement: a null user did not answer false.';
  end if;
  if public.monthly_presence_entitled() is not false then
    raise exception 'monthly_presence_entitled: no caller did not answer false.';
  end if;

  -- ---- the probe is closed ------------------------------------------------
  if has_function_privilege('anon', 'public.check_monthly_presence_entitlement(uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'anon can execute check_monthly_presence_entitlement.';
  end if;
  if has_function_privilege('authenticated', 'public.check_monthly_presence_entitlement(uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'authenticated can execute check_monthly_presence_entitlement, which is a subscription probe on any uuid.';
  end if;

  -- ---- the self-scoped one is open to signed-in callers, never to anon ----
  if has_function_privilege('anon', 'public.monthly_presence_entitled()'::regprocedure, 'EXECUTE') then
    raise exception 'anon can execute monthly_presence_entitled.';
  end if;
  if not has_function_privilege('authenticated', 'public.monthly_presence_entitled()'::regprocedure, 'EXECUTE') then
    raise exception 'authenticated cannot execute monthly_presence_entitled.';
  end if;

  -- ---- comp_grant_active stayed shut -------------------------------------
  -- Reaching it from a SECURITY DEFINER body must not have required opening it.
  if has_function_privilege('authenticated', 'public.comp_grant_active(uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'comp_grant_active was opened to authenticated; it must stay internal.';
  end if;

  -- ---- the four arms of the sentence, against real rows -------------------
  -- Built and rolled back inside this block: the guard rail must prove the
  -- predicate, not merely assert its privileges.
  -- ⚠ `auth.users` CARRIES A TRIGGER. `handle_new_user` mirrors the row into
  -- `public.profiles`, whose `email` is NOT NULL — so the email goes on the
  -- auth row and the profile is never inserted by hand here.
  v_user := gen_random_uuid();
  insert into auth.users (id, email) values (v_user, 'grace-probe@example.invalid');

  -- no subscription at all
  if public.check_monthly_presence_entitlement(v_user) is not false then
    raise exception 'entitlement: a user with no subscription was entitled.';
  end if;

  insert into public.subscriptions (user_id, stripe_subscription_id, status, current_period_end)
  values (v_user, 'sub_grace_probe', 'active', now() + interval '20 days')
  returning id into v_sub;

  if public.check_monthly_presence_entitlement(v_user) is not true then
    raise exception 'entitlement: an active subscription was not entitled.';
  end if;

  update public.subscriptions set status = 'trialing' where id = v_sub;
  if public.check_monthly_presence_entitlement(v_user) is not true then
    raise exception 'entitlement: a trialing subscription was not entitled.';
  end if;

  -- past_due INSIDE the grace: period ended an hour ago, grace is three days
  update public.subscriptions
     set status = 'past_due', current_period_end = now() - interval '1 hour'
   where id = v_sub;
  if public.check_monthly_presence_entitlement(v_user) is not true then
    raise exception 'entitlement: a past_due subscription inside the grace was refused.';
  end if;

  -- past_due OUTSIDE the grace
  update public.subscriptions
     set current_period_end = now() - interval '4 days'
   where id = v_sub;
  if public.check_monthly_presence_entitlement(v_user) is not false then
    raise exception 'entitlement: a past_due subscription past the grace was entitled.';
  end if;

  -- ⚠ past_due with NO period end. The trap: written as `not (period_end <=
  -- now())` this arm would be TRUE on a NULL and hand out the product.
  update public.subscriptions set current_period_end = null where id = v_sub;
  if public.check_monthly_presence_entitlement(v_user) is not false then
    raise exception 'entitlement: a past_due subscription with no period end was entitled -- the NULL arm leaks.';
  end if;

  -- canceled is canceled
  update public.subscriptions
     set status = 'canceled', current_period_end = now() + interval '20 days'
   where id = v_sub;
  if public.check_monthly_presence_entitlement(v_user) is not false then
    raise exception 'entitlement: a canceled subscription was entitled.';
  end if;

  -- ---- and the comp grant reaches it, which is the whole point ------------
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_user, 'chokepoint guard rail', 'migration 20260920140000', now() + interval '1 day');

  if public.check_monthly_presence_entitlement(v_user) is not true then
    raise exception 'entitlement: an active comp grant did not unlock Monthly Presence -- the gap 20260901182419 reported is still open.';
  end if;

  -- an expired grant grants nothing
  update public.comp_grants set expires_at = now() - interval '1 second' where user_id = v_user;
  if public.check_monthly_presence_entitlement(v_user) is not false then
    raise exception 'entitlement: an EXPIRED comp grant still unlocked Monthly Presence.';
  end if;

  -- a revoked grant grants nothing
  update public.comp_grants
     set expires_at = now() + interval '1 day', revoked_at = now()
   where user_id = v_user;
  if public.check_monthly_presence_entitlement(v_user) is not false then
    raise exception 'entitlement: a REVOKED comp grant still unlocked Monthly Presence.';
  end if;

  delete from public.comp_grants   where user_id = v_user;
  delete from public.subscriptions where user_id = v_user;
  delete from public.profiles      where id      = v_user;
  delete from auth.users           where id      = v_user;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.monthly_presence_entitled();
--   drop function if exists public.check_monthly_presence_entitlement(uuid);
--   drop function if exists public.monthly_presence_past_due_grace();
--   -- and lib/billing/entitlements.ts goes back to deciding it in TypeScript.
