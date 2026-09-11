-- ============================================================================
-- Eklio — see the ceiling coming, instead of meeting it
-- ============================================================================
-- Today, the FIRST sign of reaching the daily cap is a real therapist being
-- refused at the generate step, seven screens into her evening. Everything
-- needed to see it coming already exists in `anon_generation_counters` -- it
-- was simply never read anywhere a human looks.
--
-- This is the morning glance: what has been spent, what is left, and whether
-- anyone has already been turned away.
--
-- ── THE COST RATES LIVE IN app_settings, NOT IN CODE ───────────────────────
--
-- Every dollar figure here is COUNT x RATE, and the rate is an estimate
-- measured from the production prompt builders (ACQUISITION_WALK.md §12.3) at
-- claude-opus-5 prices -- not a billed amount. No request has ever been made
-- to the Anthropic API from any session that built this, so the first real
-- invoice is the only thing that settles it. When it arrives, correct these
-- two rows and every figure downstream corrects with them, without a deploy:
--
--   anon_reveal_cost_usd   0.0376   one generate press, realistic output
--   anon_assist_cost_usd   0.0099   one tone-card / positioning / suggest /
--                                   rephrase call, averaged over a walk's mix
--
-- The worst case is 5.7x the first and 3.9x the second. The report prints both
-- and names which is which, because a ceiling against loss and a ceiling
-- against catastrophe are not the same instrument.
-- ============================================================================

insert into public.app_settings (key, value) values
  ('anon_reveal_cost_usd', '0.0376'::jsonb),
  ('anon_assist_cost_usd', '0.0099'::jsonb),
  -- The worst case each call can reach, for the second column of the glance.
  ('anon_reveal_cost_usd_max', '0.2140'::jsonb),
  ('anon_assist_cost_usd_max', '0.0387'::jsonb)
on conflict (key) do nothing;


create or replace function public.anon_spend_today()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  with day as (select (now() at time zone 'utc')::date as d),
  settings as (
    select
      coalesce((select (value #>> '{}')::boolean from public.app_settings
                 where key = 'anon_generation_enabled'), false)            as enabled,
      (select (value #>> '{}')::integer from public.app_settings
        where key = 'anon_generation_daily_global')                        as reveal_cap,
      (select (value #>> '{}')::integer from public.app_settings
        where key = 'anon_assist_daily_global')                            as assist_cap,
      (select (value #>> '{}')::numeric from public.app_settings
        where key = 'anon_reveal_cost_usd')                                as reveal_rate,
      (select (value #>> '{}')::numeric from public.app_settings
        where key = 'anon_assist_cost_usd')                                as assist_rate,
      (select (value #>> '{}')::numeric from public.app_settings
        where key = 'anon_reveal_cost_usd_max')                            as reveal_rate_max,
      (select (value #>> '{}')::numeric from public.app_settings
        where key = 'anon_assist_cost_usd_max')                            as assist_rate_max
  ),
  used as (
    select
      coalesce((select c.used from public.anon_generation_counters c, day
                 where c.day = day.d and c.bucket = '@global'), 0)         as reveals,
      coalesce((select c.used from public.anon_generation_counters c, day
                 where c.day = day.d and c.bucket = 'assist:@global'), 0)  as assists,
      /*
       * The busiest single address today. One IP climbing towards its own
       * ceiling of 3 while the global is barely touched is a different
       * problem from broad demand, and it is the one that looks like a
       * script rather than a campaign.
       */
      coalesce((select max(c.used) from public.anon_generation_counters c, day
                 where c.day = day.d and c.bucket <> '@global'
                   and c.bucket not like 'assist:%'), 0)                   as busiest_ip_reveals,
      coalesce((select count(*) from public.anon_generation_counters c, day
                 where c.day = day.d and c.bucket <> '@global'
                   and c.bucket not like 'assist:%'), 0)                   as distinct_ips
  ),
  /*
   * ⚠ REFUSALS ARE THE CONFIRMATION, HEADROOM IS THE WARNING. A refusal means
   * somebody has already been turned away -- by then it is too late to be
   * early. Both are shown, and the refusal count is the one that should never
   * be non-zero without you knowing why.
   */
  refused as (
    select
      coalesce(count(*), 0)                                                as total,
      coalesce(count(*) filter (where e.props ->> 'reason' = 'ip_cap'), 0) as ip_cap,
      coalesce(count(*) filter (where e.props ->> 'reason' = 'global_cap'), 0) as global_cap,
      coalesce(count(*) filter (where e.props ->> 'reason' = 'disabled'), 0)   as disabled,
      coalesce(count(*) filter (where e.props ->> 'reason' = 'unreadable'), 0) as unreadable
    from public.funnel_events e, day
    where e.event = 'generation_refused'
      and e.occurred_at >= day.d::timestamptz
  )
  select jsonb_build_object(
    'day', (select d from day),
    'enabled', s.enabled,
    'reveals', jsonb_build_object(
      'used', u.reveals,
      'cap', s.reveal_cap,
      'left', greatest(0, coalesce(s.reveal_cap, 0) - u.reveals),
      'pct', case when coalesce(s.reveal_cap, 0) = 0 then null
                  else round(100.0 * u.reveals / s.reveal_cap, 1) end
    ),
    'assists', jsonb_build_object(
      'used', u.assists,
      'cap', s.assist_cap,
      'left', greatest(0, coalesce(s.assist_cap, 0) - u.assists),
      'pct', case when coalesce(s.assist_cap, 0) = 0 then null
                  else round(100.0 * u.assists / s.assist_cap, 1) end
    ),
    'spend_usd', round(u.reveals * coalesce(s.reveal_rate, 0)
                     + u.assists * coalesce(s.assist_rate, 0), 2),
    'spend_usd_max', round(u.reveals * coalesce(s.reveal_rate_max, 0)
                         + u.assists * coalesce(s.assist_rate_max, 0), 2),
    'headroom_usd', round(greatest(0, coalesce(s.reveal_cap, 0) - u.reveals) * coalesce(s.reveal_rate, 0)
                        + greatest(0, coalesce(s.assist_cap, 0) - u.assists) * coalesce(s.assist_rate, 0), 2),
    'rates', jsonb_build_object(
      'reveal', s.reveal_rate, 'assist', s.assist_rate,
      'reveal_max', s.reveal_rate_max, 'assist_max', s.assist_rate_max
    ),
    'distinct_ips', u.distinct_ips,
    'busiest_ip_reveals', u.busiest_ip_reveals,
    'refused', jsonb_build_object(
      'total', r.total, 'ip_cap', r.ip_cap, 'global_cap', r.global_cap,
      'disabled', r.disabled, 'unreadable', r.unreadable
    )
  )
  from settings s, used u, refused r;
$function$;

revoke execute on function public.anon_spend_today() from public, anon, authenticated;
grant  execute on function public.anon_spend_today() to service_role;

comment on function public.anon_spend_today() is
  'Today''s anonymous spend against the ceilings. Dollar figures are COUNT x an ESTIMATED rate from app_settings, never a billed amount.';


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare v_j jsonb; v_n integer;
begin
  -- The four rates exist; a missing one would silently price a day at zero.
  select count(*) into v_n from public.app_settings
   where key in ('anon_reveal_cost_usd', 'anon_assist_cost_usd',
                 'anon_reveal_cost_usd_max', 'anon_assist_cost_usd_max');
  if v_n <> 4 then
    raise exception 'anon spend glance: % of 4 cost rates present', v_n;
  end if;

  v_j := public.anon_spend_today();

  -- Every key the reader prints must be there, or the morning glance shows a
  -- blank where a number should be and nobody notices for a week.
  if not (v_j ? 'reveals' and v_j ? 'assists' and v_j ? 'spend_usd'
          and v_j ? 'headroom_usd' and v_j ? 'refused' and v_j ? 'rates'
          and v_j ? 'enabled' and v_j ? 'busiest_ip_reveals') then
    raise exception 'anon spend glance: missing keys in %', v_j;
  end if;

  -- The cap that is actually shipped must be the one reported.
  if (v_j -> 'reveals' ->> 'cap')::integer <>
     (select (value #>> '{}')::integer from public.app_settings
       where key = 'anon_generation_daily_global') then
    raise exception 'anon spend glance: reveal cap disagrees with app_settings';
  end if;

  -- Headroom + spend must reconstruct the full-day cost of the ceiling, so a
  -- reader can trust that "left" and "spent" are two halves of one number.
  if abs((v_j ->> 'headroom_usd')::numeric + (v_j ->> 'spend_usd')::numeric
         - (
             (select (value #>> '{}')::integer from public.app_settings where key = 'anon_generation_daily_global')
               * (select (value #>> '{}')::numeric from public.app_settings where key = 'anon_reveal_cost_usd')
           + (select (value #>> '{}')::integer from public.app_settings where key = 'anon_assist_daily_global')
               * (select (value #>> '{}')::numeric from public.app_settings where key = 'anon_assist_cost_usd')
           )) > 0.02 then
    raise exception 'anon spend glance: headroom and spend do not add up to the ceiling';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function public.anon_spend_today();
--   delete from public.app_settings where key in
--     ('anon_reveal_cost_usd','anon_assist_cost_usd',
--      'anon_reveal_cost_usd_max','anon_assist_cost_usd_max');
