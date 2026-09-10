-- ============================================================================
-- Eklio — the funnel, from first landing to paid kit
-- ============================================================================
-- `lib/analytics.ts` has been right about everything except where it puts the
-- data. Server-side, first-party, no vendor, no cookie, no consent banner, and
-- a properties discipline that admits ids, counts and machine reasons but
-- never free text. What it does with all that is:
--
--     console.info(`[analytics] ${event} ${JSON.stringify(properties)}`);
--
-- On Vercel, function logs live hours to days without a Log Drain. A week
-- after the cold emails land, the evidence is gone. So this is a SINK and a
-- SCHEMA, not a rewrite: one table, one writer, one way to read it.
--
-- ── WHOSE DATA THIS IS ─────────────────────────────────────────────────────
--
-- It is Eklio's, and it is about Eklio's own funnel. It is NOT the
-- practitioner's data and it informs NO screen she will ever see: nothing
-- under `app/` reads this table, and a test in the frontend keeps it that way.
-- The moment a number from here appears in the product, it stops being
-- measurement and starts being a claim about other people.
--
-- ── WHAT MAY NEVER BE IN HERE ──────────────────────────────────────────────
--
-- A word she wrote. Not her positioning, not her referral quote, not the text
-- she pasted into Check, not truncated, not hashed. The frontend already says
-- so in a comment; a comment is not a mechanism, so `props` carries a CHECK
-- (`funnel_props_are_safe`) that refuses anything but flat scalars with short
-- strings. A new call site cannot forget it.
--
-- ── HOW A VISITOR IS FOLLOWED, AND HOW FAR ─────────────────────────────────
--
-- Two keys, both already in the product, NEITHER of them cross-site:
--
--   visitor_day   the same daily-salted IP hash the spend ceilings use. It
--                 joins the pre-account steps -- landing, pricing, the start
--                 of the brief -- and it is USELESS THE NEXT DAY, by
--                 construction. No cookie was added for this.
--   project_id    from the first brief answer onward, and it survives signup,
--                 so it joins the anonymous half of the walk to the paid half.
--
-- ⚠ AND ITS LIMITS, SO NO ONE READS MORE INTO IT THAN IT SAYS. Two people
-- behind one office router share a visitor_day. One person who starts on
-- cellular and finishes on wifi is two. A walk that crosses midnight UTC is
-- two. Counts of EVENTS are exact; counts of VISITORS are an estimate, and the
-- report labels them as such.
-- ============================================================================


-- ── The properties guard, as a mechanism rather than a comment ──────────────
create or replace function public.funnel_props_are_safe(p_props jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $function$
  select p_props is not null
     and jsonb_typeof(p_props) = 'object'
     -- A dozen keys is more than any event here has ever needed.
     and (select count(*) from jsonb_object_keys(p_props)) <= 12
     and not exists (
       select 1 from jsonb_each(p_props) as kv(key, value)
        where
          -- No nesting: an object or an array is where a paragraph hides.
          jsonb_typeof(kv.value) in ('object', 'array')
          -- A short string is an id, a slug or a machine reason. A long one
          -- is prose, and prose is the thing this table must never hold.
          or (jsonb_typeof(kv.value) = 'string' and length(kv.value #>> '{}') > 64)
          or length(kv.key) > 40
     );
$function$;

comment on function public.funnel_props_are_safe(jsonb) is
  'CHECK helper for funnel_events.props: flat object, <=12 keys, no nesting, strings <=64 chars. Refuses free text at the door.';


-- ── One table ───────────────────────────────────────────────────────────────
create table if not exists public.funnel_events (
  id           bigint      generated always as identity,
  occurred_at  timestamptz not null default now(),
  event        text        not null,
  /* Daily-salted IP hash. Null when the request had no address to hash. */
  visitor_day  text,
  project_id   uuid,
  brand_kit_id uuid,
  user_id      uuid,
  anonymous    boolean     not null default false,
  props        jsonb       not null default '{}'::jsonb,

  constraint funnel_events_pkey primary key (id),
  constraint funnel_events_event_check
    check (event ~ '^[a-z][a-z0-9_]{2,48}$'),
  constraint funnel_events_visitor_day_check
    check (visitor_day is null or visitor_day ~ '^[0-9a-f]{32}$'),
  constraint funnel_events_props_check
    check (public.funnel_props_are_safe(props))
);

/*
 * ⚠ NO FOREIGN KEYS, ON PURPOSE. An event is a fact about something that
 * happened, and the anonymous purge deletes projects thirty days later. A
 * cascade would quietly erase the record that a hundred people started a brief
 * the morning the emails went out -- which is precisely the number this table
 * exists to keep. The ids are recorded, not enforced.
 */

create index if not exists funnel_events_occurred_at_idx
  on public.funnel_events (occurred_at desc);
create index if not exists funnel_events_event_time_idx
  on public.funnel_events (event, occurred_at desc);
create index if not exists funnel_events_visitor_day_idx
  on public.funnel_events (visitor_day) where visitor_day is not null;
create index if not exists funnel_events_project_idx
  on public.funnel_events (project_id) where project_id is not null;

alter table public.funnel_events enable row level security;
-- Nobody but the server. There is nothing here for a browser to read, and a
-- table with no policy in this project returns zero rows and raises nothing --
-- so the denial is written down rather than left implied.
drop policy if exists "funnel_events_denied" on public.funnel_events;
create policy "funnel_events_denied" on public.funnel_events
  for all using (false) with check (false);

comment on table public.funnel_events is
  'Eklio''s own funnel. Server-only, first-party, no cross-site identifier. Never carries a word the practitioner wrote, and informs no screen in the product.';


-- ── The named steps, in order ───────────────────────────────────────────────
--
-- The funnel's SHAPE lives here rather than in a query, so that renaming a
-- step or inserting one is a row, not a deploy. `match_prop`/`match_value`
-- exist because one event name carries several milestones: finishing step 4 of
-- the brief is `brief_step_completed` with `step` = 4, and that is a named
-- step of the funnel while finishing step 2 is not.
create table if not exists public.funnel_steps (
  step_key    text    not null,
  step_no     integer not null,
  label       text    not null,
  phase       text    not null,
  event       text    not null,
  match_prop  text,
  match_value text,

  constraint funnel_steps_pkey primary key (step_key),
  constraint funnel_steps_step_no_key unique (step_no),
  constraint funnel_steps_phase_check
    check (phase in ('reach', 'brief', 'reveal', 'account', 'paid')),
  constraint funnel_steps_match_check
    check ((match_prop is null) = (match_value is null))
);

alter table public.funnel_steps enable row level security;
drop policy if exists "funnel_steps_denied" on public.funnel_steps;
create policy "funnel_steps_denied" on public.funnel_steps
  for all using (false) with check (false);

insert into public.funnel_steps (step_no, step_key, label, phase, event, match_prop, match_value) values
  ( 1, 'landed',        'Landed on the site',        'reach',   'landing_viewed',       null,   null),
  ( 2, 'pricing',       'Looked at pricing',         'reach',   'pricing_viewed',       null,   null),
  ( 3, 'brief_started', 'Started the brief',         'brief',   'brief_started',        null,   null),
  ( 4, 'brief_step_4',  'Finished "How you work"',   'brief',   'brief_step_completed', 'step', '4'),
  ( 5, 'brief_review',  'Reached the review',        'brief',   'brief_reviewed',       null,   null),
  ( 6, 'generate',      'Pressed generate',          'reveal',  'generation_started',   null,   null),
  ( 7, 'directions',    'Saw three directions',      'reveal',  'generation_succeeded', null,   null),
  ( 8, 'chose',         'Chose a direction',         'reveal',  'direction_chosen',     null,   null),
  ( 9, 'signup',        'Started an account',        'account', 'signup_started',       null,   null),
  (10, 'account',       'Created an account',        'account', 'account_created',      null,   null),
  (11, 'checkout',      'Opened checkout',           'paid',    'checkout_opened',      null,   null),
  (12, 'paid',          'Paid',                      'paid',    'purchase_completed',   null,   null)
on conflict (step_key) do nothing;

comment on table public.funnel_steps is
  'The named funnel, in order. Editing a row changes the report without a deploy.';


-- ── One writer ──────────────────────────────────────────────────────────────
--
-- A batch, because a single request can produce several events and one round
-- trip is cheaper than three. Every row goes through the same CHECKs; a bad
-- row in the batch fails the batch, which is the correct direction for a table
-- whose whole value is that you can trust what is in it.
create or replace function public.record_funnel_events(p_events jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_count integer;
begin
  if p_events is null or jsonb_typeof(p_events) <> 'array' then
    return 0;
  end if;

  insert into public.funnel_events
    (occurred_at, event, visitor_day, project_id, brand_kit_id, user_id, anonymous, props)
  select
    coalesce((e ->> 'occurred_at')::timestamptz, now()),
    e ->> 'event',
    nullif(e ->> 'visitor_day', ''),
    nullif(e ->> 'project_id', '')::uuid,
    nullif(e ->> 'brand_kit_id', '')::uuid,
    nullif(e ->> 'user_id', '')::uuid,
    coalesce((e ->> 'anonymous')::boolean, false),
    coalesce(e -> 'props', '{}'::jsonb)
  from jsonb_array_elements(p_events) as e;

  get diagnostics v_count = row_count;
  return v_count;
end
$function$;

revoke execute on function public.record_funnel_events(jsonb) from public, anon, authenticated;
grant  execute on function public.record_funnel_events(jsonb) to service_role;


-- ── One way to read it ──────────────────────────────────────────────────────
--
-- Ordered named steps with their counts and both conversions, so that reading
-- the funnel is one call and never a query written at midnight.
create or replace function public.funnel_report(
  p_from timestamptz,
  p_to   timestamptz default now()
)
returns table (
  step_no          integer,
  step_key          text,
  label             text,
  phase             text,
  events            bigint,
  visitors          bigint,
  projects          bigint,
  pct_of_first      numeric,
  pct_of_previous   numeric
)
language sql
stable
security definer
set search_path = ''
as $function$
  with counted as (
    select
      s.step_no, s.step_key, s.label, s.phase,
      count(e.id)                                     as events,
      count(distinct e.visitor_day)                   as visitors,
      count(distinct e.project_id)                    as projects
    from public.funnel_steps s
    left join public.funnel_events e
      on e.event = s.event
     and e.occurred_at >= p_from
     and e.occurred_at <  p_to
     and (s.match_prop is null or e.props ->> s.match_prop = s.match_value)
    group by s.step_no, s.step_key, s.label, s.phase
  ),
  /*
   * The denominator is the WIDEST count each step has, because the first two
   * steps only ever have visitors and everything from the brief onward has
   * projects. Mixing them in one column would be a lie; picking the widest and
   * saying which was picked is the honest compromise, and the reader prints
   * both columns beside it.
   */
  reached as (
    select *, greatest(visitors, projects) as reach from counted
  )
  select
    r.step_no, r.step_key, r.label, r.phase, r.events, r.visitors, r.projects,
    case when first_value(r.reach) over w = 0 then null
         else round(100.0 * r.reach / first_value(r.reach) over w, 1) end,
    case when lag(r.reach) over w is null then null
         when lag(r.reach) over w = 0 then null
         else round(100.0 * r.reach / lag(r.reach) over w, 1) end
  from reached r
  window w as (order by r.step_no)
  order by r.step_no;
$function$;

revoke execute on function public.funnel_report(timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function public.funnel_report(timestamptz, timestamptz) to service_role;

comment on function public.funnel_report(timestamptz, timestamptz) is
  'The named funnel between two instants. `visitors` is an ESTIMATE (daily-salted IP hash); `events` is exact.';


-- ── Retention ───────────────────────────────────────────────────────────────
insert into public.app_settings (key, value) values
  -- Long enough to compare one campaign against the next, short enough that
  -- nothing here becomes a permanent record of anybody's traffic.
  ('funnel_retention_days', '180'::jsonb)
on conflict (key) do nothing;

create or replace function public.purge_funnel_events()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_days  integer;
  v_count integer;
begin
  select (value #>> '{}')::integer into v_days
    from public.app_settings where key = 'funnel_retention_days';

  -- Unreadable setting: keep the data. Deleting is the irreversible direction,
  -- so THIS one fails open -- the opposite of the spend ceilings, and for the
  -- same reason: fail towards the outcome you can still undo.
  if v_days is null or v_days < 1 then
    return 0;
  end if;

  delete from public.funnel_events
   where occurred_at < now() - make_interval(days => v_days);

  get diagnostics v_count = row_count;
  return v_count;
end
$function$;

revoke execute on function public.purge_funnel_events() from public, anon, authenticated;
grant  execute on function public.purge_funnel_events() to service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare v_n integer; v_ok boolean;
begin
  -- Twelve named steps, contiguous from 1, no gaps and no duplicates.
  select count(*) into v_n from public.funnel_steps;
  if v_n <> 12 then
    raise exception 'funnel: % named steps, expected 12', v_n;
  end if;
  select count(*) into v_n from public.funnel_steps
   where step_no between 1 and 12;
  if v_n <> 12 then
    raise exception 'funnel: step numbers are not 1..12';
  end if;

  -- Both tables refuse the browser outright.
  select count(*) into v_n from pg_policies
   where schemaname = 'public'
     and tablename in ('funnel_events', 'funnel_steps')
     and qual = 'false';
  if v_n <> 2 then
    raise exception 'funnel: % of 2 deny-all policies present', v_n;
  end if;

  -- ⚠ THE PROPERTIES GUARD MUST BITE, not merely exist. Four shapes that must
  -- be refused, proven rather than asserted.
  if public.funnel_props_are_safe(jsonb_build_object('quote', repeat('x', 65))) then
    raise exception 'funnel: a 65-character string was accepted into props';
  end if;
  if public.funnel_props_are_safe('{"nested":{"text":"hi"}}'::jsonb) then
    raise exception 'funnel: a nested object was accepted into props';
  end if;
  if public.funnel_props_are_safe('{"list":["a","b"]}'::jsonb) then
    raise exception 'funnel: an array was accepted into props';
  end if;
  if public.funnel_props_are_safe('"just a string"'::jsonb) then
    raise exception 'funnel: a non-object was accepted into props';
  end if;
  -- ... and must NOT refuse what the product actually sends.
  if not public.funnel_props_are_safe('{"step":4,"reason":"ip_cap","ok":true,"id":null}'::jsonb) then
    raise exception 'funnel: the guard refuses a legitimate payload';
  end if;

  -- The CHECK is on the column, not only in the function: an insert with a
  -- paragraph in it must fail.
  begin
    insert into public.funnel_events (event, props)
    values ('guard_rail_probe', jsonb_build_object('text', repeat('y', 200)));
    raise exception 'funnel: props CHECK did not fire on insert';
  exception
    when check_violation then null;
  end;

  -- A malformed event name is refused too.
  begin
    insert into public.funnel_events (event) values ('Not A Valid Event');
    raise exception 'funnel: event name CHECK did not fire';
  exception
    when check_violation then null;
  end;

  -- The report runs and returns the twelve steps in order, on an empty table.
  select count(*) into v_n from public.funnel_report(now() - interval '1 day');
  if v_n <> 12 then
    raise exception 'funnel_report returned % rows, expected 12', v_n;
  end if;

  -- Nothing the probes attempted may have landed.
  select count(*) into v_n from public.funnel_events where event = 'guard_rail_probe';
  if v_n <> 0 then
    raise exception 'funnel: a refused probe still wrote a row';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function public.purge_funnel_events();
--   drop function public.funnel_report(timestamptz, timestamptz);
--   drop function public.record_funnel_events(jsonb);
--   drop table public.funnel_steps;
--   drop table public.funnel_events;      -- the props CHECK goes with it
--   drop function public.funnel_props_are_safe(jsonb);
--   delete from public.app_settings where key = 'funnel_retention_days';
