-- ============================================================================
-- The fourth instance, and the one that is in the money path
-- ============================================================================
-- `grant_plan_allowance` derives its idempotency key, when none is passed, from
-- the most recent purchase of that tier on that project:
--
--     order by pu.created_at desc limit 1
--
-- `created_at` defaulted to `now()`, which is the START of the transaction and
-- does not advance within it. Two purchases written together therefore tie, and
-- `id` is `gen_random_uuid()`, so there is nothing to break the tie with.
-- Measured against production: two rows, ONE distinct `created_at`, and the
-- query returned the FIRST purchase's session id — the wrong one.
--
-- ⚠ WHY THIS ONE IS WORSE THAN THE OTHER THREE. The value it picks becomes
-- `plan_grants.grant_key`, which is the idempotency key: the insert is
-- `on conflict (grant_key) do nothing`, and the function returns false when
-- nothing was inserted. So picking the wrong purchase does not merely mislabel
-- a grant — it can key the grant to a purchase that is not the one being
-- processed, and the call for the real one then collides and **grants nothing**.
-- A paid customer with no allowance, and a `false` return that looks exactly
-- like the legitimate "already granted".
--
-- It is reachable today rather than theoretically: the Practice Suite path
-- writes a purchase and a subscription in the same breath, and a double submit
-- writes two purchases in one transaction — a case this repository has already
-- measured once (E1: $158 charged for a $79 kit, both grants succeeding).
--
-- ── TWO HALVES, BECAUSE ONE IS NOT ENOUGH ───────────────────────────────────
--
-- 1. `created_at` becomes `clock_timestamp()`, as `content_publications.
--    occurred_at` did in 20260911193259. Two purchases genuinely happen at two
--    instants and the column should say so.
-- 2. The ORDER BY gains a total-order tiebreaker anyway, because half 1 does
--    nothing for rows that already exist. `stripe_checkout_session_id` is
--    unique and NOT NULL, so it makes the order total; it carries no meaning as
--    a sort key and is not pretending to — it is there so that two rows which
--    tie on everything real still come back in the same order twice.
--
-- ⚠ `id desc` WOULD NOT DO. That is what `content_publications` had, and a
-- `gen_random_uuid()` tiebreaker is a coin flip wearing the clothes of care. It
-- is worse than no tiebreaker, because it stops the next person looking.
--
-- Existing rows are untouched: a default and an ORDER BY, not data.
-- ============================================================================

alter table public.purchases
  alter column created_at set default clock_timestamp();

comment on column public.purchases.created_at is
  'When the purchase row was written. clock_timestamp(), not now(): two purchases written in one transaction must be orderable, and now() is frozen for the whole transaction.';

create or replace function public.grant_plan_allowance(
  p_project_id uuid,
  p_tier       text,
  p_grant_key  text default null::text
)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_key uuid;
  v_k   text;
begin
  if p_project_id is null or p_tier is null then
    return false;
  end if;
  if not exists (select 1 from public.plans where tier = p_tier) then
    raise exception 'grant_plan_allowance: "%" is not a plan.', p_tier;
  end if;

  v_k := coalesce(nullif(btrim(p_grant_key), ''), (
    select pu.stripe_checkout_session_id
      from public.purchases pu
     where pu.project_id = p_project_id
       and pu.tier = p_tier
     /*
      * ⚠ THE SECOND KEY IS NOT DECORATION. `created_at` alone is not an order
      * when two purchases were written in one transaction, and the value this
      * picks becomes the idempotency key of the grant.
      */
     order by pu.created_at desc, pu.stripe_checkout_session_id desc
     limit 1));
  if v_k is null then
    raise exception
      'grant_plan_allowance: no grant key given and no % purchase on this project to take one from.', p_tier;
  end if;

  insert into public.plan_grants (project_id, tier, grant_key)
  values (p_project_id, p_tier, v_k)
  on conflict (grant_key) do nothing
  returning id into v_key;

  if v_key is null then
    return false;
  end if;

  insert into public.generation_credits (project_id) values (p_project_id)
  on conflict (project_id) do nothing;

  update public.generation_credits
     set plan_tier            = p_tier,
         directions_generated = 0,
         regenerations_used   = 0
   where project_id = p_project_id;

  return true;
end
$function$;

-- ---------------------------------------------------------------------------
-- Guard rail — two purchases in ONE transaction, which is the reachable case
-- ---------------------------------------------------------------------------
do $$
declare
  v_user uuid := gen_random_uuid();
  v_proj uuid := gen_random_uuid();
  v_org  uuid;
  v_n    integer;
  v_key  text;
begin
  insert into auth.users (id, email) values (v_user, 'grant-guard-' || v_user || '@example.invalid');
  select m.organization_id into v_org
    from public.organization_members m where m.user_id = v_user and m.role = 'owner';
  insert into public.projects (id, user_id, name) values (v_proj, v_user, 'grant guard rail');

  insert into public.purchases
    (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
  values (v_user, v_proj, 'starter', 'cs_guard_first_'  || v_proj, 4900, 'paid', now()),
         (v_user, v_proj, 'starter', 'cs_guard_second_' || v_proj, 4900, 'paid', now());

  select count(distinct created_at) into v_n
    from public.purchases where project_id = v_proj;
  assert v_n = 2,
    format('two purchases in one transaction share a created_at (%s distinct) — the grant key is a coin flip', v_n);

  select pu.stripe_checkout_session_id into v_key
    from public.purchases pu
   where pu.project_id = v_proj and pu.tier = 'starter'
   order by pu.created_at desc, pu.stripe_checkout_session_id desc
   limit 1;
  assert v_key = 'cs_guard_second_' || v_proj,
    format('the derived grant key is %L, not the most recent purchase', v_key);

  -- ⚠ CLEAN UP PURCHASES BEFORE THE PROJECT. purchases_project_id_fkey is
  -- ON DELETE SET NULL, so the other order leaves these behind as real orphans
  -- on the morning report — the exact trap orphaned_purchases() exists to show.
  delete from public.purchases where project_id = v_proj;
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;

  assert not exists (select 1 from public.purchases where stripe_checkout_session_id like 'cs_guard_%' || v_proj),
    'the guard rail left a purchase behind';
end
$$;
