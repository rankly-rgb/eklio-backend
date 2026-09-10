-- ============================================================================
-- Eklio — four model calls on the free path were outside the wall
-- ============================================================================
-- `20260910192157_anonymous_briefs.sql` put a ceiling on anonymous generation
-- and then guarded exactly one route with it. FOUR others call the model on the
-- same free path and were never counted:
--
--   POST /api/briefs/[id]/suggest      "Write it for me", x4 fields
--   POST /api/briefs/[id]/rephrase     "Help me say it", x2 fields
--   POST /api/briefs/[id]/tone-cards   step 5, "How you work"
--   POST /api/briefs/[id]/usp-options  the positioning screen, x3 rounds
--
-- Measured from the production prompt builders, at claude-opus-5 prices: one
-- anonymous visitor's whole walk costs $0.0871 realistically and $1.0858 at
-- the absolute worst. $0.0495 of the realistic figure -- 57% of it -- was in
-- those four routes, outside the wall, reachable by anyone with a cookie.
--
-- ── WHY A SECOND KIND RATHER THAN THE SAME COUNTER ─────────────────────────
--
-- Counting them in the same bucket would have been worse than leaving them
-- out. The per-IP ceiling is 3, and ONE honest walk through the brief spends
-- about five assist calls plus a reveal. Her own first brief would have
-- refused her own reveal, twice over.
--
-- They are not the same instrument, because they are not the same magnitude
-- (measured, realistic / worst):
--
--   reveal  $0.0376 / $0.2140   the thing the ceiling is actually for
--   assist  $0.0099 / $0.0387   averaged over one walk's mix of the four
--
-- So: two kinds, two pairs of ceilings, one atomic function. The bucket key
-- carries the kind ('assist:@global', 'assist:<ip hash>'); the reveal keys are
-- untouched, so today's rows keep meaning exactly what they meant.
--
-- ── THE NUMBERS, AND WHERE THEY COME FROM ──────────────────────────────────
--
-- The two ratios are different because the two ceilings do different jobs.
--
-- GLOBAL is the budget instrument, so it takes the ratio a real population
-- produces: 5 assist calls per reveal, measured over one walk (2 suggest,
-- 1 rephrase, 1 tone-cards, 1 positioning).
--
--   anon_generation_daily_global   150   ->  anon_assist_daily_global   750
--
-- PER-IP is the anti-grind instrument, so it takes the ratio one determined
-- visitor produces: 15 assist calls per brief, one short of the 17 she could
-- physically press.
--
--   anon_generation_daily_per_ip   3     ->  anon_assist_daily_per_ip    45
--
-- At those four values: a realistic day costs $13.06 and needs 50 distinct
-- IPs to fill; the worst day anyone could construct costs $61.12; and any one
-- IP, in any one day, can cost at most $2.38.
-- ============================================================================

-- ── The two new ceilings ────────────────────────────────────────────────────
insert into public.app_settings (key, value) values
  -- anon_generation_daily_per_ip x 15: what ONE determined visitor can press.
  ('anon_assist_daily_per_ip', '45'::jsonb),
  -- anon_generation_daily_global x 5: what a real population averages.
  ('anon_assist_daily_global', '750'::jsonb)
on conflict (key) do nothing;

-- ── The same function, now told which ceiling it is spending ────────────────
--
-- A defaulted parameter cannot be added in place, so the one-argument form is
-- dropped and replaced. Every caller ships in the same commit, through one
-- helper (`lib/anon/spend.ts`) rather than five copies of the same paragraph.
drop function if exists public.consume_anon_generation(text);

create function public.consume_anon_generation(
  p_ip_hash text,
  p_kind    text default 'reveal'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_enabled  boolean;
  v_per_ip   integer;
  v_global   integer;
  v_prefix   text;
  v_day      date := (now() at time zone 'utc')::date;
  v_ok       boolean;
begin
  if p_kind not in ('reveal', 'assist') then
    -- An unknown kind is a caller bug, and a caller bug must not be free.
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  -- ONE kill switch for both kinds: turning anonymous generation off must
  -- turn off everything it pays for, not leave the cheap half running.
  select (value #>> '{}')::boolean into v_enabled
    from public.app_settings where key = 'anon_generation_enabled';

  if p_kind = 'assist' then
    v_prefix := 'assist:';
    select (value #>> '{}')::integer into v_per_ip
      from public.app_settings where key = 'anon_assist_daily_per_ip';
    select (value #>> '{}')::integer into v_global
      from public.app_settings where key = 'anon_assist_daily_global';
  else
    v_prefix := '';
    select (value #>> '{}')::integer into v_per_ip
      from public.app_settings where key = 'anon_generation_daily_per_ip';
    select (value #>> '{}')::integer into v_global
      from public.app_settings where key = 'anon_generation_daily_global';
  end if;

  /*
   * ⚠ A MISSING OR UNREADABLE SETTING IS "NO", NEVER "UNLIMITED". Fail closed
   * is the standing rule everywhere money is involved, and a typo in a row
   * someone edits at seven in the morning must not open the tap.
   */
  if v_enabled is not true or v_per_ip is null or v_global is null then
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  -- The global ceiling first: it is the one that bounds the bill.
  insert into public.anon_generation_counters (day, bucket, used)
  values (v_day, v_prefix || '@global', 1)
  on conflict (day, bucket) do update
    set used = public.anon_generation_counters.used + 1
    where public.anon_generation_counters.used < v_global
  returning true into v_ok;

  if not coalesce(v_ok, false) then
    return jsonb_build_object('ok', false, 'reason', 'global_cap');
  end if;

  insert into public.anon_generation_counters (day, bucket, used)
  values (v_day, v_prefix || p_ip_hash, 1)
  on conflict (day, bucket) do update
    set used = public.anon_generation_counters.used + 1
    where public.anon_generation_counters.used < v_per_ip
  returning true into v_ok;

  if not coalesce(v_ok, false) then
    /*
     * ⚠ GIVE THE GLOBAL COUNT BACK. It was taken a moment ago for a generation
     * that is not going to happen, and leaving it spent would let one visitor
     * refreshing a page eat the day's ceiling for everyone else.
     */
    update public.anon_generation_counters
       set used = greatest(0, used - 1)
     where day = v_day and bucket = v_prefix || '@global';
    return jsonb_build_object('ok', false, 'reason', 'ip_cap');
  end if;

  return jsonb_build_object('ok', true);
end
$function$;

revoke execute on function public.consume_anon_generation(text, text) from public, anon, authenticated;
grant  execute on function public.consume_anon_generation(text, text) to service_role;

comment on function public.consume_anon_generation(text, text) is
  'Verify-then-consume, one statement per ceiling. p_kind ''reveal'' spends anon_generation_daily_*; ''assist'' spends anon_assist_daily_* under an assist: bucket prefix. Returns {ok, reason}.';


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare v_n integer;
begin
  -- Five settings now, not three, and all five are read by the same function.
  select count(*) into v_n from public.app_settings
   where key in ('anon_generation_enabled',
                 'anon_generation_daily_per_ip', 'anon_generation_daily_global',
                 'anon_assist_daily_per_ip', 'anon_assist_daily_global');
  if v_n <> 5 then
    raise exception 'anon assist ceiling: % of 5 spend settings present', v_n;
  end if;

  -- The one-argument form must be GONE, not sitting beside the new one: an
  -- overload resolving to the old body would spend the reveal ceiling on a
  -- tone-card call and nobody would see it.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'consume_anon_generation'
       and p.pronargs = 1
  ) then
    raise exception 'anon assist ceiling: the one-argument consume_anon_generation still exists';
  end if;

  -- Fail-closed, proven rather than asserted: an unknown kind refuses.
  if (public.consume_anon_generation('guard-rail-probe', 'nonsense') ->> 'ok') <> 'false' then
    raise exception 'anon assist ceiling: an unknown kind was allowed through';
  end if;

  -- ... and refuses WITHOUT counting: the probe above must have written nothing.
  select count(*) into v_n from public.anon_generation_counters
   where bucket like '%guard-rail-probe%';
  if v_n <> 0 then
    raise exception 'anon assist ceiling: a refused call still spent a count';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function public.consume_anon_generation(text, text);
--   then re-create the one-argument form from
--   20260910192157_anonymous_briefs.sql verbatim, and
--   delete from public.app_settings
--    where key in ('anon_assist_daily_per_ip','anon_assist_daily_global');
--   Assist rows in anon_generation_counters ('assist:%') age out on their own.
