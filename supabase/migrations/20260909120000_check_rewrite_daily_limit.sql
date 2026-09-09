-- ============================================================================
-- Eklio — the Check rewrite is bounded by a daily count, not by a credit
-- ============================================================================
-- WHAT THIS UNDOES. `POST /api/check/rewrite` called `consume_generation_credit`
-- on every rewrite that resolved. That meter is the DIRECTIONS ladder: three
-- to twelve regenerations of a whole brand, priced at 79 to 249 USD. A Check
-- rewrite is one text call costing a fraction of a cent. Charging a brand
-- regeneration for it was absurd in the only direction that matters — she
-- would run out of the expensive thing by using the cheap one.
--
-- WHAT REPLACES IT. A per-user daily count. Not money, because the call is not
-- meaningfully money; a bound on the tight loop, which is the only real risk a
-- cheap endpoint carries.
--
-- ⚠ WHY IT IS IN THE DATABASE AND NOT IN THE PROCESS.
-- `lib/api/rate-limit.ts` exists and says so itself: it is per-process,
-- two serverless instances count separately, and a redeploy resets it. That is
-- a SLOWER, not a limit. A daily ceiling that a deploy clears is not a ceiling,
-- so this one is a row.
--
-- ⚠ CHECK AND CONSUME IN ONE STATEMENT. `on conflict … do update … where` is
-- the same single-statement technique `consume_generation_credit` uses: the
-- limit is enforced by the WHERE, so two simultaneous rewrites cannot both read
-- an under-limit count and both increment it. Verify-then-consume, collapsed
-- into one atomic step, which is strictly stronger than doing it in two.
-- ============================================================================

create table if not exists public.check_rewrite_usage (
  user_id uuid    not null references public.profiles (id) on delete cascade,
  day     date    not null,
  used    integer not null default 0,
  constraint check_rewrite_usage_pkey primary key (user_id, day),
  constraint check_rewrite_usage_used_check check (used >= 0)
);

comment on table public.check_rewrite_usage is
  'One row per user per UTC day, counting Check rewrites. A BOUND ON A TIGHT LOOP, not a money meter -- a rewrite is a fraction of a cent. Written only by consume_check_rewrite.';

-- Same day boundary as `brand_image_daily_spend` (`current_date`, UTC), so the
-- product has one notion of "today" for its daily meters rather than two.
comment on column public.check_rewrite_usage.day is
  'UTC calendar day, matching brand_image_daily_spend. Not the America/New_York day the CONTENT calendar uses -- that one is about when she posts, this one is about when a server counted.';

alter table public.check_rewrite_usage enable row level security;

-- She may read her own count (a UI could show "3 rewrites left today").
-- Nothing writes from a client: the RPC below is the only writer.
drop policy if exists check_rewrite_usage_select_own on public.check_rewrite_usage;
create policy check_rewrite_usage_select_own
  on public.check_rewrite_usage for select
  using (user_id = (select auth.uid()));

drop policy if exists check_rewrite_usage_insert_denied on public.check_rewrite_usage;
create policy check_rewrite_usage_insert_denied
  on public.check_rewrite_usage for insert with check (false);
drop policy if exists check_rewrite_usage_update_denied on public.check_rewrite_usage;
create policy check_rewrite_usage_update_denied
  on public.check_rewrite_usage for update using (false);
drop policy if exists check_rewrite_usage_delete_denied on public.check_rewrite_usage;
create policy check_rewrite_usage_delete_denied
  on public.check_rewrite_usage for delete using (false);

revoke insert, update, delete on public.check_rewrite_usage from anon, authenticated;
grant select on public.check_rewrite_usage to authenticated;

-- >>> CHECK REWRITE LIMIT (mirrored verbatim in supabase/seed.sql) >>>
-- ⚠ THIS NUMBER IS THE DECISION, and it lives here so it moves without a
-- deploy. Twenty a day: far past any honest editing session on one piece of
-- copy, far short of a script.
insert into public.app_settings (key, value) values
  ('check_rewrites_per_user_per_day', '20')
on conflict (key) do nothing;
-- <<< CHECK REWRITE LIMIT <<<

create or replace function public.consume_check_rewrite()
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_user  uuid    := (select auth.uid());
  v_day   date    := current_date;
  v_limit integer;
  v_used  integer;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'reason', 'unauthenticated');
  end if;

  select coalesce((value #>> '{}')::integer, 20)
    into v_limit
    from public.app_settings
   where key = 'check_rewrites_per_user_per_day';
  v_limit := coalesce(v_limit, 20);

  /*
   * ⚠ ONE STATEMENT. The WHERE is the limit: when it does not hold, no row is
   * updated, nothing is returned, and `v_used` stays null. Two concurrent
   * rewrites cannot both pass.
   */
  insert into public.check_rewrite_usage (user_id, day, used)
  values (v_user, v_day, 1)
  on conflict (user_id, day) do update
     set used = public.check_rewrite_usage.used + 1
   where public.check_rewrite_usage.used < v_limit
  returning used into v_used;

  if v_used is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'daily_limit',
      'limit', v_limit,
      'used', v_limit,
      'remaining', 0,
      'resets_at', ((v_day + 1)::timestamptz)
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'reason', 'consumed',
    'limit', v_limit,
    'used', v_used,
    'remaining', greatest(v_limit - v_used, 0),
    'resets_at', ((v_day + 1)::timestamptz)
  );
end;
$$;

comment on function public.consume_check_rewrite() is
  'Atomically counts one Check rewrite against the caller''s daily allowance and refuses past it. auth.uid()-scoped. NOT a money meter: a rewrite costs a fraction of a cent, and this exists to stop a tight loop, not to ration a deliverable. Never touches consume_generation_credit.';

revoke execute on function public.consume_check_rewrite() from public, anon;
grant execute on function public.consume_check_rewrite() to authenticated, service_role;

-- ============================================================================
-- Self-check
-- ============================================================================
do $$
begin
  -- Unauthenticated must refuse rather than count against a null user.
  if (public.consume_check_rewrite() ->> 'ok')::boolean is not false then
    raise exception 'consume_check_rewrite: an anonymous call did not refuse.';
  end if;

  if not exists (
    select 1 from public.app_settings where key = 'check_rewrites_per_user_per_day'
  ) then
    raise exception 'consume_check_rewrite: the limit setting was not seeded.';
  end if;
end $$;
