-- ============================================================================
-- Eklio — the Content system's schema
-- ============================================================================
-- The month must arrive FULL. That needs three things she tells us (a standing
-- voice profile from the brief, preferences asked once, a check-in asked
-- monthly), a record of what was generated and from what, and a meter that
-- pays for the photographs without touching the ones she bought outright.
--
-- ── ⚠ REGISTER IS NOT ARCHETYPE, AND THEY ARE MADE DISJOINT ON PURPOSE ───
--
-- `content_items.archetype` is a LAYOUT: statement | question | notes |
-- signature | story. It maps to the satori renderer's catalogue keys
-- (post_statement_1080, …) and it does not change.
--
-- `content_items.register` is an EDITORIAL SHAPE with its own safety rule. It
-- governs what a caption may say and what it may never say.
--
-- A named feeling can be laid out as a statement or as notes. A practical note
-- is usually notes but does not have to be. Extending the archetype CHECK
-- would make a layout pretend to be a safety category; mapping the two would
-- claim they are the same thing.
--
-- The failure mode to avoid is the one this repo already produced once with
-- `min_tier`: two vocabularies that agree only because both are currently
-- permissive, until the day one moves. So the two value sets are DISJOINT by
-- construction — the obvious collision, `question`, is called
-- `reflective_question` as a register — and a guard rail at the bottom fails
-- this migration if they ever overlap. A value that belongs to one axis can
-- then never be silently accepted by the other.
--
-- ── WHY THE REGISTERS ARE A TABLE AND NOT A CHECK ────────────────────────
--
-- Because the six are needed in TWO places: one per item, and a set per kit in
-- `content_preferences.accepted_registers`. Two CHECK lists holding the same
-- six strings is precisely the drift above. A catalogue table gives the item a
-- real foreign key, gives the array a trigger that validates against the same
-- rows, and gives the generator its safety rules as DATA rather than as prose
-- in a prompt file.
-- ============================================================================


-- ============================================================================
-- 1. content_registers — the six editorial shapes, and their safety rules
-- ============================================================================
create table if not exists public.content_registers (
  id          text primary key,
  label       text not null,
  -- The rule the generator must satisfy, and the reviewer must be able to
  -- read. Stored rather than hidden in a prompt string so that changing what
  -- a register is allowed to say is a migration with a diff, not an edit
  -- buried in a template.
  safety_rule text not null,
  sort_order  smallint not null,
  constraint content_registers_label_check check (char_length(label) between 1 and 60),
  constraint content_registers_rule_check  check (char_length(safety_rule) between 10 and 400)
);

comment on table public.content_registers is
  'The six editorial shapes a generated caption may take, each with the safety rule that bounds it. NOT layouts -- content_items.archetype is the layout axis, and the two value sets are asserted disjoint.';

insert into public.content_registers (id, label, safety_rule, sort_order) values
  ('named_feeling', 'A named feeling',
   'Describes an experience, in the second person or with no subject. Never attributed to a client, real or composite.', 1),
  ('reflective_question', 'A question',
   'Invites reflection. Never a symptom list, never "do you suffer from...".', 2),
  ('how_the_work_works', 'How the work works',
   'Describes the work, never its outcome. Highest-converting in private practice and also the safest.', 3),
  ('permission', 'A permission',
   'Grants permission to feel or do something. No promise attached.', 4),
  ('practical_note', 'A practical note',
   'A verifiable fact from the brief or the check-in: telehealth states, sliding scale, waitlist, insurance, evening hours. Never invented, never estimated.', 5),
  ('seasonal_note', 'A seasonal note',
   'Anchored on the calendar and connected to her specialty without diagnosing.', 6)
on conflict (id) do update
  set label = excluded.label,
      safety_rule = excluded.safety_rule,
      sort_order = excluded.sort_order;

alter table public.content_registers enable row level security;

drop policy if exists "content_registers_select_all"    on public.content_registers;
drop policy if exists "content_registers_insert_denied" on public.content_registers;
drop policy if exists "content_registers_update_denied" on public.content_registers;
drop policy if exists "content_registers_delete_denied" on public.content_registers;

-- A catalogue: readable by any signed-in user (the UI lists it in the
-- preferences step), writable by nobody but a migration.
create policy "content_registers_select_all" on public.content_registers
  for select to authenticated using (true);
create policy "content_registers_insert_denied" on public.content_registers
  for insert with check (false);
create policy "content_registers_update_denied" on public.content_registers
  for update using (false);
create policy "content_registers_delete_denied" on public.content_registers
  for delete using (false);


-- ============================================================================
-- 2. content_preferences — asked ONCE, one row per kit
-- ============================================================================
create table if not exists public.content_preferences (
  brand_kit_id       uuid primary key references public.brand_kits (id) on delete cascade,
  -- 1, 2 or 3 posts per week. Not a free integer: the whole generation plan
  -- (how many posts, how many grounds, how many stories) is a table indexed by
  -- this, and a 7 would have no row in it.
  cadence_per_week   smallint not null,
  -- A subset of content_registers.id. Never empty: a kit that accepts no
  -- register can be sent no month at all, which is a state the product has no
  -- way to explain to her.
  accepted_registers text[] not null,
  -- Short free text. Bounded because it goes into a prompt, and an unbounded
  -- field there is both a cost and an injection surface.
  off_limits         text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint content_preferences_cadence_check check (cadence_per_week in (1, 2, 3)),
  constraint content_preferences_registers_nonempty_check
    check (coalesce(array_length(accepted_registers, 1), 0) between 1 and 6),
  constraint content_preferences_off_limits_check
    check (off_limits is null or char_length(off_limits) <= 500)
);

comment on table public.content_preferences is
  'What she told us once about how she wants the month shaped: cadence, which registers she accepts, and what is off limits. One row per kit.';

/*
 * ⚠ A TRIGGER, BECAUSE AN ARRAY CANNOT CARRY A FOREIGN KEY.
 *
 * Without this, `accepted_registers` would be a bag of arbitrary strings that
 * merely looks like it references the catalogue — and a typo would silently
 * narrow her month instead of failing. The whole point of §1 is that the six
 * live in ONE place; validating against a second hard-coded list here would
 * undo it.
 */
create or replace function public.content_preferences_validate_registers()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unknown text;
begin
  select r into v_unknown
    from unnest(new.accepted_registers) as r
   where r not in (select id from public.content_registers)
   limit 1;

  if v_unknown is not null then
    raise exception 'content_preferences: % is not a known register', v_unknown
      using errcode = 'check_violation';
  end if;

  -- Duplicates would let one register weigh twice in the generator's draw.
  if array_length(new.accepted_registers, 1)
     <> (select count(distinct r) from unnest(new.accepted_registers) as r) then
    raise exception 'content_preferences: accepted_registers contains duplicates'
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

drop trigger if exists content_preferences_validate_registers on public.content_preferences;
create trigger content_preferences_validate_registers
  before insert or update on public.content_preferences
  for each row execute function public.content_preferences_validate_registers();

alter table public.content_preferences enable row level security;

drop policy if exists "content_preferences_select_own"    on public.content_preferences;
drop policy if exists "content_preferences_insert_denied" on public.content_preferences;
drop policy if exists "content_preferences_update_denied" on public.content_preferences;
drop policy if exists "content_preferences_delete_denied" on public.content_preferences;

create policy "content_preferences_select_own" on public.content_preferences
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = content_preferences.brand_kit_id
       and pr.user_id = (select auth.uid())
  ));
create policy "content_preferences_insert_denied" on public.content_preferences
  for insert with check (false);
create policy "content_preferences_update_denied" on public.content_preferences
  for update using (false);
create policy "content_preferences_delete_denied" on public.content_preferences
  for delete using (false);


-- ============================================================================
-- 3. content_checkins — three questions, sixty seconds, one row per month
-- ============================================================================
create table if not exists public.content_checkins (
  id             uuid primary key default gen_random_uuid(),
  brand_kit_id   uuid not null references public.brand_kits (id) on delete cascade,
  month          date not null,
  -- "What has been coming up in your sessions this month?"
  sessions_theme text,
  -- "Are you taking new clients?" -- governs whether a post may carry a call
  -- to action, and which one. Not a boolean: a waitlist is a third answer with
  -- its own copy, and squeezing it into yes/no would put "book now" on the
  -- page of someone who cannot take anyone.
  taking_clients text,
  -- "Anything happening this month?" -- optional, and stays optional.
  happening      text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint content_checkins_kit_month_key unique (brand_kit_id, month),
  constraint content_checkins_month_check check (month = date_trunc('month', month)::date),
  constraint content_checkins_taking_check
    check (taking_clients is null or taking_clients in ('yes', 'waitlist', 'no')),
  constraint content_checkins_sessions_check
    check (sessions_theme is null or char_length(sessions_theme) <= 600),
  constraint content_checkins_happening_check
    check (happening is null or char_length(happening) <= 600)
);

comment on table public.content_checkins is
  'Her monthly sixty seconds: what came up in sessions, whether she is taking clients (yes/waitlist/no), and anything happening. All three nullable -- an unanswered check-in means generate from the brief alone and leave it open at the top of the calendar, never block the month.';

create index if not exists content_checkins_kit_month_idx
  on public.content_checkins (brand_kit_id, month desc);

alter table public.content_checkins enable row level security;

drop policy if exists "content_checkins_select_own"    on public.content_checkins;
drop policy if exists "content_checkins_insert_denied" on public.content_checkins;
drop policy if exists "content_checkins_update_denied" on public.content_checkins;
drop policy if exists "content_checkins_delete_denied" on public.content_checkins;

create policy "content_checkins_select_own" on public.content_checkins
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = content_checkins.brand_kit_id
       and pr.user_id = (select auth.uid())
  ));
create policy "content_checkins_insert_denied" on public.content_checkins
  for insert with check (false);
create policy "content_checkins_update_denied" on public.content_checkins
  for update using (false);
create policy "content_checkins_delete_denied" on public.content_checkins
  for delete using (false);


-- ============================================================================
-- 4. content_months — PROVENANCE, not a date filter
-- ============================================================================
-- ⚠ THE MONTH IS NOT DERIVED FROM `scheduled_for`, and the difference matters
-- twice over:
--
--   * an item can be UNSCHEDULED. Production holds one right now. Derived from
--     a nullable date, it would belong to no month at all;
--   * if she drags an October post to November, it still belongs to OCTOBER's
--     plan and composes on October's grounds. Which month GENERATED an item is
--     a different fact from when it is DUE, and only one of them is a date on
--     the item.

create table if not exists public.content_months (
  id           uuid primary key default gen_random_uuid(),
  brand_kit_id uuid not null references public.brand_kits (id) on delete cascade,
  month        date not null,
  -- The month's themes, in order. A ground is generated per theme, and a post
  -- composes on the ground of its own theme. Bounded 1..6 rather than pinned
  -- to four: how many themes a cadence earns is the generator's decision
  -- (Session 3), and a CHECK is the wrong place to freeze a number that
  -- session has not made yet.
  themes       text[] not null default '{}'::text[],
  status       text not null default 'generating',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint content_months_kit_month_key unique (brand_kit_id, month),
  constraint content_months_month_check check (month = date_trunc('month', month)::date),
  constraint content_months_themes_check check (coalesce(array_length(themes, 1), 0) <= 6),
  constraint content_months_status_check
    check (status in ('generating', 'proposed', 'approved', 'failed'))
);

comment on table public.content_months is
  'One generated plan per (kit, month): its themes, and the state of the batch. Items link to it by month_id -- which month GENERATED them, never which month they are scheduled in.';
comment on column public.content_months.status is
  'generating -> proposed -> approved, or failed. Approving moves the batch of proposed items to draft; the month row records that it happened.';

alter table public.content_months enable row level security;

drop policy if exists "content_months_select_own"    on public.content_months;
drop policy if exists "content_months_insert_denied" on public.content_months;
drop policy if exists "content_months_update_denied" on public.content_months;
drop policy if exists "content_months_delete_denied" on public.content_months;

create policy "content_months_select_own" on public.content_months
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = content_months.brand_kit_id
       and pr.user_id = (select auth.uid())
  ));
create policy "content_months_insert_denied" on public.content_months
  for insert with check (false);
create policy "content_months_update_denied" on public.content_months
  for update using (false);
create policy "content_months_delete_denied" on public.content_months
  for delete using (false);


-- ============================================================================
-- 5. content_grounds — rows, not a jsonb array on the month
-- ============================================================================
-- Each ground carries money and a lifecycle: a fingerprint, a storage path, a
-- cost in cents and a reserve/settle state. A jsonb array could hold the first
-- two; it could not be indexed on the third, could not be updated one ground
-- at a time under concurrency, and could not be summed. Anything that spends
-- is a row.

create table if not exists public.content_grounds (
  id            uuid primary key default gen_random_uuid(),
  month_id      uuid not null references public.content_months (id) on delete cascade,
  theme         text not null,
  fingerprint   text not null,
  -- Null until the image actually lands. A path written before the bytes
  -- exist is a broken <img> that looks like a product bug.
  storage_path  text,
  cost_cents    integer not null default 0,
  state         text not null default 'reserved',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint content_grounds_month_theme_key unique (month_id, theme),
  constraint content_grounds_theme_check check (char_length(theme) between 1 and 80),
  constraint content_grounds_cost_check check (cost_cents >= 0),
  constraint content_grounds_state_check
    check (state in ('reserved', 'settled', 'released', 'failed')),
  -- A settled ground has bytes; anything else has not. Without this, "settled"
  -- and "there is an image" could disagree, and the composer would be asked to
  -- draw on nothing.
  constraint content_grounds_settled_has_path_check
    check ((state = 'settled') = (storage_path is not null))
);

comment on table public.content_grounds is
  'One photographic ground per (month, theme). Carries its own fingerprint, storage path, cost in cents and reserve/settle state -- rows rather than a jsonb array on the month, because each one spends money and moves independently.';

create index if not exists content_grounds_month_idx on public.content_grounds (month_id);

alter table public.content_grounds enable row level security;

drop policy if exists "content_grounds_select_own"    on public.content_grounds;
drop policy if exists "content_grounds_insert_denied" on public.content_grounds;
drop policy if exists "content_grounds_update_denied" on public.content_grounds;
drop policy if exists "content_grounds_delete_denied" on public.content_grounds;

create policy "content_grounds_select_own" on public.content_grounds
  for select using (exists (
    select 1 from public.content_months cm
      join public.brand_kits bk on bk.id = cm.brand_kit_id
      join public.projects pr on pr.id = bk.project_id
     where cm.id = content_grounds.month_id
       and pr.user_id = (select auth.uid())
  ));
create policy "content_grounds_insert_denied" on public.content_grounds
  for insert with check (false);
create policy "content_grounds_update_denied" on public.content_grounds
  for update using (false);
create policy "content_grounds_delete_denied" on public.content_grounds
  for delete using (false);


-- ============================================================================
-- 6. content_image_allowance — a RECURRING meter, and not the kit's pot
-- ============================================================================
-- ⚠ THIS IS NOT `plans.image_budget_cents`, AND CONFLATING THEM WOULD BE THEFT.
--
--   * `plans.image_budget_cents` is a LIFETIME pot attached to a ONE-TIME
--     purchase. She bought seven photographs with her kit; that money is hers
--     until she spends it.
--   * this is a RECURRING allowance that RESETS every month, attached to a
--     $39/month subscription.
--
-- One row per (kit, month) is what makes the reset structural rather than a
-- job that has to remember to run: a new month has no row, so it has its full
-- allowance, and last month's exhaustion cannot reach it. Three months of
-- content could otherwise eat the photographs she paid for outright.
--
-- Same discipline as the kit's meter: reserve BEFORE the call, settle after,
-- release on failure. There is still no post-purchase refund primitive.

create table if not exists public.content_image_allowance (
  brand_kit_id   uuid not null references public.brand_kits (id) on delete cascade,
  month          date not null,
  budget_cents   integer not null,
  reserved_cents integer not null default 0,
  used_cents     integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  primary key (brand_kit_id, month),
  constraint content_image_allowance_month_check check (month = date_trunc('month', month)::date),
  constraint content_image_allowance_budget_check   check (budget_cents >= 0),
  constraint content_image_allowance_reserved_check check (reserved_cents >= 0),
  constraint content_image_allowance_used_check     check (used_cents >= 0),
  -- The invariant the whole meter exists to hold. Enforced in the row rather
  -- than only in the RPC, so a future writer that forgets the check still
  -- cannot overspend her.
  constraint content_image_allowance_within_budget_check
    check (reserved_cents + used_cents <= budget_cents)
);

comment on table public.content_image_allowance is
  'Monthly Presence image spend, per (kit, month), in cents. SEPARATE from plans.image_budget_cents: that one is a lifetime pot bought once, this one is a recurring allowance that resets. A new month has no row, so the reset is structural rather than a job that must remember to run.';

alter table public.content_image_allowance enable row level security;

drop policy if exists "content_image_allowance_select_own"    on public.content_image_allowance;
drop policy if exists "content_image_allowance_insert_denied" on public.content_image_allowance;
drop policy if exists "content_image_allowance_update_denied" on public.content_image_allowance;
drop policy if exists "content_image_allowance_delete_denied" on public.content_image_allowance;

create policy "content_image_allowance_select_own" on public.content_image_allowance
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = content_image_allowance.brand_kit_id
       and pr.user_id = (select auth.uid())
  ));
create policy "content_image_allowance_insert_denied" on public.content_image_allowance
  for insert with check (false);
create policy "content_image_allowance_update_denied" on public.content_image_allowance
  for update using (false);
create policy "content_image_allowance_delete_denied" on public.content_image_allowance
  for delete using (false);

/*
 * The monthly ceiling, in app_settings so it moves without a deploy.
 *
 * ARITHMETIC, so the number is not a guess: a ground is one gpt-image-1 image
 * at medium 1024x1024, $0.042, which `priceCents` rounds up to 5 cents. At the
 * largest cadence (3 posts/week) the month draws four square grounds — 20
 * cents. Brand-colour posts cost nothing to generate: satori composes them.
 *
 * 100 cents is therefore five times the largest honest month, which buys room
 * for retries and for a quality bump without a migration, while still capping
 * a runaway loop at about 2.6% of the $39 subscription.
 */
insert into public.app_settings (key, value)
values ('content_image_budget_cents_per_month', '100'::jsonb)
on conflict (key) do nothing;


-- ============================================================================
-- 7. content_items — the register, the month link, and `proposed`
-- ============================================================================
alter table public.content_items
  add column if not exists register text references public.content_registers (id);

alter table public.content_items
  add column if not exists month_id uuid references public.content_months (id) on delete set null;

comment on column public.content_items.register is
  'The editorial shape this caption was written under, with its own safety rule. NOT the layout -- that is `archetype`, and the two value sets are asserted disjoint. Null for items she wrote herself before the generator existed.';
comment on column public.content_items.month_id is
  'Which generated month produced this item. NOT derived from scheduled_for: an item can be unscheduled, and moving a post to another month does not move which plan it belongs to or which ground it composes on. Null for items that predate the system.';

create index if not exists content_items_month_id_idx on public.content_items (month_id);

/*
 * ⚠ `proposed` GOES IN FRONT OF `draft`, and it changes what the counts mean.
 *
 *   proposed -> draft -> ready -> archived
 *
 * A proposed item is one Eklio wrote and she has not yet seen. It counts in
 * NEITHER `Ready` nor `Posted`. Today "Ready 0" is true only by vacuity — she
 * has three untitled drafts and nothing else — and the moment a month arrives
 * full, a status that counted proposals would report work she has never read.
 *
 * Approving the month moves the batch to `draft`. Past proposed items stay on
 * their dates, greyed: we stop counting her content, we never delete it.
 *
 * `posted` is deliberately NOT here. It is derived from content_publications,
 * which is append-only and which clients cannot write. One copy of the fact.
 */
alter table public.content_items drop constraint if exists content_items_status_check;
alter table public.content_items add constraint content_items_status_check
  check (status in ('proposed', 'draft', 'ready', 'archived'));


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_overlap text;
  v_missing text;
begin
  -- ⚠ THE ONE THIS MIGRATION EXISTS TO PROTECT. Register ids and archetype
  -- values must never intersect. If they do, a value belonging to one axis can
  -- be silently accepted by the other, and the two vocabularies start agreeing
  -- by accident -- which is how `min_tier` went wrong.
  select r.id into v_overlap
    from public.content_registers r
   where r.id in ('statement', 'question', 'notes', 'signature', 'story')
   limit 1;

  if v_overlap is not null then
    raise exception
      'content schema: register "%" collides with an archetype value. The two axes must stay disjoint.', v_overlap;
  end if;

  if (select count(*) from public.content_registers) <> 6 then
    raise exception 'content schema: expected exactly six registers, found %',
      (select count(*) from public.content_registers);
  end if;

  -- Every new table carries RLS AND four policies. A table with RLS on and no
  -- policy returns zero rows to a client and everything to service_role,
  -- silently -- this repo's signature defect.
  foreach v_missing in array array[
    'content_registers', 'content_preferences', 'content_checkins',
    'content_months', 'content_grounds', 'content_image_allowance'
  ]
  loop
    if not (select relrowsecurity from pg_class
             where oid = ('public.' || v_missing)::regclass) then
      raise exception 'content schema: RLS is not enabled on %', v_missing;
    end if;
    if (select count(*) from pg_policies
         where schemaname = 'public' and tablename = v_missing) <> 4 then
      raise exception 'content schema: % does not carry four policies (found %)',
        v_missing, (select count(*) from pg_policies
                     where schemaname='public' and tablename=v_missing);
    end if;
  end loop;

  if not exists (select 1 from public.app_settings
                  where key = 'content_image_budget_cents_per_month') then
    raise exception 'content schema: the monthly image ceiling was not seeded';
  end if;

  -- The three pre-existing items must be untouched: they predate the system.
  if (select count(*) from public.content_items
       where month_id is not null or register is not null) <> 0 then
    raise exception 'content schema: a pre-existing item was given a month or a register';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   alter table public.content_items drop constraint content_items_status_check;
--   alter table public.content_items add constraint content_items_status_check
--     check (status in ('draft','ready','archived'));
--   alter table public.content_items drop column month_id, drop column register;
--   drop table public.content_image_allowance, public.content_grounds,
--              public.content_months, public.content_checkins,
--              public.content_preferences, public.content_registers cascade;
--   delete from public.app_settings where key = 'content_image_budget_cents_per_month';
