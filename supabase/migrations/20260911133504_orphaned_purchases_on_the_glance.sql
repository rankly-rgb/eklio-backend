-- ============================================================================
-- Eklio — a paid purchase that names no project, on the morning report
-- ============================================================================
-- `purchases.project_id` can be null, and three things produce one:
--
--   1. `/pricing` links to `/app/checkout?plan=…` with no project at all. A
--      real path, not an accident.
--   2. The brief claim fails at signup, so the checkout page's RLS read finds
--      no project and the metadata carries an empty project id.
--   3. `purchases_project_id_fkey` is ON DELETE SET NULL. Deleting a project
--      DETACHES its purchase instead of removing it -- the teardown in
--      REHEARSAL.md is itself one of the entrances.
--
-- ⚠ AND SUCH A ROW BUYS NOTHING. `grant_plan_allowance` returns false on a
-- null project (measured, session 4), and `brand_kit_entitled` is scoped to
-- the project. Until session 4 the three TypeScript readers counted it for
-- EVERY project the account owned, so the screen said "paid" while the
-- database refused -- she chose a direction and was bounced to checkout for a
-- kit she appeared to have bought. Those readers are now scoped too.
--
-- Which leaves one honest problem: somebody has paid and has nothing. That is
-- fixable by hand in seconds -- one UPDATE naming the project -- and it is
-- invisible, so it would never be fixed. Hence this: it goes on the glance
-- beside the cap, where zero every morning is the answer and any other number
-- is something to act on that day.
-- ============================================================================

create or replace function public.orphaned_purchases()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  with orphans as (
    select p.id, p.user_id, p.tier, p.amount_cents, p.created_at,
           /*
            * How many of her projects have no paid purchase of their own, and
            * which one if there is exactly one. Offered as a SUGGESTION in the
            * report and never applied here: money is not moved by a function
            * nobody asked to run, and "the obvious home" is a judgement that
            * belongs to a person.
            */
           (select count(*) from public.projects pr
             where pr.user_id = p.user_id
               and not exists (
                 select 1 from public.purchases q
                  where q.project_id = pr.id and q.status = 'paid')) as candidates,
           (select pr.id from public.projects pr
             where pr.user_id = p.user_id
               and not exists (
                 select 1 from public.purchases q
                  where q.project_id = pr.id and q.status = 'paid')
             order by pr.created_at
             limit 1) as first_candidate
      from public.purchases p
     where p.project_id is null
       and p.status = 'paid'
  )
  select jsonb_build_object(
    'total', (select count(*) from orphans),
    'amount_cents', coalesce((select sum(amount_cents) from orphans), 0),
    'oldest', (select min(created_at) from orphans),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id,
        'user_id', o.user_id,
        'tier', o.tier,
        'amount_cents', o.amount_cents,
        'created_at', o.created_at,
        -- Null unless exactly one unpaid project of hers is the obvious home.
        'suggested_project_id', case when o.candidates = 1 then o.first_candidate end
      ) order by o.created_at)
      from orphans o
    ), '[]'::jsonb)
  );
$function$;

revoke execute on function public.orphaned_purchases() from public, anon, authenticated;
grant  execute on function public.orphaned_purchases() to service_role;

comment on function public.orphaned_purchases() is
  'Paid purchases with no project attached: somebody paid and got no allowance. suggested_project_id is a hint for a manual UPDATE, never applied here.';


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare v_j jsonb; v_user uuid; v_project uuid; v_n integer; v_before integer;
begin
  -- Shape first: the reader prints these four keys.
  v_j := public.orphaned_purchases();
  if not (v_j ? 'total' and v_j ? 'amount_cents' and v_j ? 'rows' and v_j ? 'oldest') then
    raise exception 'orphaned purchases: missing keys in %', v_j;
  end if;
  if jsonb_typeof(v_j -> 'rows') <> 'array' then
    raise exception 'orphaned purchases: rows is not an array';
  end if;
  v_before := (v_j ->> 'total')::integer;

  -- ⚠ AND IT MUST ACTUALLY FIND ONE. A function that returns an empty list
  -- because its WHERE clause is wrong looks exactly like a clean morning.
  select id into v_user from auth.users order by created_at limit 1;
  if v_user is not null then
    insert into public.projects (user_id, name)
    values (v_user, 'guard rail probe') returning id into v_project;

    insert into public.purchases
      (user_id, project_id, tier, stripe_checkout_session_id,
       stripe_payment_intent_id, amount_cents, currency, status, paid_at)
    values (v_user, null, 'starter', 'cs_orphan_guard_rail',
            'pi_orphan_guard_rail', 7900, 'usd', 'paid', now());

    v_j := public.orphaned_purchases();
    if (v_j ->> 'total')::integer <> v_before + 1 then
      raise exception 'orphaned purchases: a real orphan was not found';
    end if;
    if (v_j ->> 'amount_cents')::integer < 7900 then
      raise exception 'orphaned purchases: the amount is not summed';
    end if;

    -- A purchase that DOES name a project must never appear here.
    update public.purchases set project_id = v_project
     where stripe_checkout_session_id = 'cs_orphan_guard_rail';
    v_j := public.orphaned_purchases();
    if (v_j ->> 'total')::integer <> v_before then
      raise exception 'orphaned purchases: an attached purchase still shows as orphaned';
    end if;

    -- ⚠ CLEAN UP PURCHASES BEFORE THE PROJECT. The FK is ON DELETE SET NULL,
    -- so the other order would leave this probe behind as a real orphan --
    -- which is the exact trap this function exists to make visible.
    delete from public.purchases where stripe_checkout_session_id = 'cs_orphan_guard_rail';
    delete from public.projects where id = v_project;

    select count(*) into v_n from public.purchases
     where stripe_checkout_session_id = 'cs_orphan_guard_rail';
    if v_n <> 0 then
      raise exception 'orphaned purchases: the probe left a row behind';
    end if;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function public.orphaned_purchases();
