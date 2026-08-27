-- ============================================================================
-- Eklio — monthly content calendar
-- ============================================================================
-- RECONCILIATION DECISION, stated up front because §6 asked for it:
-- `public.monthly_presence_content` is RESHAPED IN PLACE. No
-- `content_calendar_items` table is created. There is exactly one table holding
-- monthly content at the end of this migration, and it is this one.
--
-- WHY RESHAPE RATHER THAN EXTEND
-- ------------------------------
-- Lot 4 created the table at the wrong GRAIN, not with the wrong columns. It
-- held ONE ROW PER MONTH — `unique (project_id, month)` with the whole month's
-- output in a `content` jsonb blob. What the home screen renders is a grid of
-- individually locked, blurred, dated tiles: one row per ITEM, sixteen a month,
-- each with its own status and publication date. Extending a one-row-per-month
-- table into that would have meant keeping a `content` blob nothing reads
-- beside sixteen rows that do.
--
-- WHY THIS IS SAFE TO DO IN PLACE
-- -------------------------------
-- The table holds 0 rows on `fobgdsupyfslxbswfuay` — verified against the live
-- project before writing this, not assumed. The guard rail in section 1 refuses
-- to run if that is ever untrue, because a grain change cannot be a silent data
-- migration: one old row is sixteen new ones, and only the frontend knows how
-- to split a `content` blob into them.
--
-- `project_id` and `content` are DROPPED. Ownership is now `user_id` directly
-- plus `brand_kit_id` — the content declines a specific kit's palette and
-- voice, and the project is reachable through it. Keeping a third path to the
-- same fact would leave three columns to keep in agreement.
--
-- ⚠ NO SCHEDULER. pg_cron is not installed and no job is created here. The
-- monthly run needs LLM calls, so it is orchestrated from `eklio-frontend` on
-- its own schedule. What this repo guarantees is that calling
-- `ensure_month_skeleton` twice is harmless.
-- ============================================================================


-- ============================================================================
-- 1. Guard rail — refuse to reshape a populated table
-- ============================================================================
do $$
declare
  n bigint;
begin
  select count(*) into n from public.monthly_presence_content;
  if n > 0 then
    raise exception
      'monthly_content_calendar: monthly_presence_content holds % row(s). This migration changes the table GRAIN from one row per month to one row per item; one existing row becomes sixteen, and only the frontend can split its content blob. Nothing has been modified. Migrate the data explicitly, then re-run.', n;
  end if;
end
$$;


-- ============================================================================
-- 2. Reshape
-- ============================================================================
-- Policies first: they reference `project_id`, which is about to go.

drop policy if exists "monthly_presence_content_select_own"    on public.monthly_presence_content;
drop policy if exists "monthly_presence_content_insert_denied" on public.monthly_presence_content;
drop policy if exists "monthly_presence_content_update_denied" on public.monthly_presence_content;
drop policy if exists "monthly_presence_content_delete_denied" on public.monthly_presence_content;

alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_project_id_month_key;
drop index if exists public.monthly_presence_content_project_id_idx;

alter table public.monthly_presence_content
  add column if not exists user_id      uuid,
  add column if not exists brand_kit_id uuid,
  add column if not exists day_of_month int,
  add column if not exists type         text,
  add column if not exists title        text,
  add column if not exists caption      text,
  add column if not exists visual_spec  jsonb,
  add column if not exists published_at timestamptz;

alter table public.monthly_presence_content
  drop column if exists project_id,
  drop column if exists content;

-- The table is empty (guarded above), so NOT NULL can go on directly.
alter table public.monthly_presence_content
  alter column user_id      set not null,
  alter column brand_kit_id set not null,
  alter column day_of_month set not null,
  alter column type         set not null;

alter table public.monthly_presence_content
  add constraint monthly_presence_content_user_id_fkey
  foreign key (user_id) references public.profiles (id) on delete cascade;

alter table public.monthly_presence_content
  add constraint monthly_presence_content_brand_kit_id_fkey
  foreign key (brand_kit_id) references public.brand_kits (id) on delete cascade;

-- `status` changes vocabulary completely: lot 4's pending/generating/complete/
-- failed described a GENERATION run over a whole month. These four describe an
-- ITEM's availability to the user, which is what the tiles render.
alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_status_check;
alter table public.monthly_presence_content
  add constraint monthly_presence_content_status_check check (
    status = any (array['locked'::text, 'draft'::text,
                        'ready'::text, 'published'::text])
  );
alter table public.monthly_presence_content
  alter column status set default 'locked';

alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_type_check;
alter table public.monthly_presence_content
  add constraint monthly_presence_content_type_check check (
    type = any (array['post'::text, 'story'::text])
  );

alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_day_of_month_check;
alter table public.monthly_presence_content
  add constraint monthly_presence_content_day_of_month_check check (
    day_of_month between 1 and 31
  );

-- ⚠ THE SECURITY-RELEVANT CONSTRAINT ON THIS TABLE. The home screen renders a
-- locked tile BLURRED, with its title legible underneath — the blur is CSS, so
-- everything the row carries has already crossed the wire. A locked row must
-- therefore hold nothing that is being withheld: title yes, caption and visual
-- spec no. Without this, `filter: blur(9px)` is the entire paywall.
alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_locked_is_empty_check;
alter table public.monthly_presence_content
  add constraint monthly_presence_content_locked_is_empty_check check (
    status <> 'locked' or (caption is null and visual_spec is null)
  );

-- Same shape as `purchases_paid_at_check`: a published item is dated, and an
-- unpublished one is not.
alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_published_at_check;
alter table public.monthly_presence_content
  add constraint monthly_presence_content_published_at_check check (
    (status = 'published') = (published_at is not null)
  );

-- §4's calendar limit, on the column rather than through a jsonb probe: the
-- tile caption under each thumbnail is one line at 14px.
alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_title_check;
alter table public.monthly_presence_content
  add constraint monthly_presence_content_title_check check (
    title is null or char_length(title) <= 34
  );

-- The idempotence guarantee for `ensure_month_skeleton`: one slot per
-- (kit, month, type, day). A second run collides and does nothing.
alter table public.monthly_presence_content
  add constraint monthly_presence_content_slot_key
  unique (brand_kit_id, month, type, day_of_month);

create index if not exists monthly_presence_content_user_id_month_idx
  on public.monthly_presence_content (user_id, month);
create index if not exists monthly_presence_content_brand_kit_id_idx
  on public.monthly_presence_content (brand_kit_id);

comment on table public.monthly_presence_content is
  'Monthly content calendar, ONE ROW PER ITEM (12 posts + 4 stories a month). Reshaped from lot 4''s one-row-per-month stub. Written by the frontend with service_role; clients read their own rows only.';
comment on column public.monthly_presence_content.status is
  'Availability of this item to its owner: locked (paywalled teaser, title only), draft, ready, published.';


-- ============================================================================
-- 3. RLS — rewritten on the new ownership column
-- ============================================================================
-- Direct `user_id` now, instead of lot 4's EXISTS through `projects`. Same
-- verdict, one less join, and it matches the column the FK protects.
--
-- Writes stay refused to clients, for lot 4's reason and one more: this content
-- is a paid deliverable, and a client that could INSERT would manufacture a
-- month of Monthly Presence without a subscription.

alter table public.monthly_presence_content enable row level security;

create policy "monthly_presence_content_select_own"
  on public.monthly_presence_content for select
  using (user_id = (select auth.uid()));

create policy "monthly_presence_content_insert_denied"
  on public.monthly_presence_content for insert with check (false);

create policy "monthly_presence_content_update_denied"
  on public.monthly_presence_content for update using (false);

create policy "monthly_presence_content_delete_denied"
  on public.monthly_presence_content for delete using (false);


-- ============================================================================
-- 4. ensure_month_skeleton — structure only, idempotent
-- ============================================================================
-- Inserts the sixteen slots for a month if they are missing. It creates
-- STRUCTURE: which day, post or story, and whether the item starts locked.
-- Titles, captions and visual specs are written afterwards by the frontend,
-- which is where the LLM lives.
--
-- THE DAY SPREAD stops at day 28 on purpose: every day used has to exist in
-- February as well as in January, and a skeleton that produced a different
-- number of items depending on the month would make "16 items" a lie eleven
-- months a year.
--
-- INITIAL STATUS follows the subscription, because that is structure too:
--   * subscriber      -> 16 draft items, the whole month opened up
--   * non-subscriber  -> 1 ready, 15 locked; the free preview the home screen
--                        shows above `11 MORE LOCKED`
-- The one preview item starts with a NULL caption — the skeleton necessarily
-- runs before any content exists. Filling it is the frontend's next step. The
-- `locked_is_empty` constraint is what keeps the other fifteen empty, and it is
-- checked by the database rather than trusted to that same step.
--
-- ⚠ SECURITY INVOKER, so it must be called with `service_role`. Client INSERT
-- is refused by policy, so an authenticated caller gets a policy violation
-- rather than a month of free content. Making it SECURITY DEFINER would hand
-- every logged-in user a way to seed rows for any uuid they can name.
--
-- ⚠ ONE KIT PER USER, resolved as the most recently created one. The signature
-- given is (user_id, month) with no kit, and a user with two projects has two
-- brand kits; this seeds for the newest. If multi-project Monthly Presence ever
-- ships, this signature is the thing that has to change.

create or replace function public.ensure_month_skeleton(p_user_id uuid, p_month date)
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_brand_kit_id uuid;
  v_subscribed   boolean;
  v_inserted     int;
  -- 12 posts and 4 stories, all on days that exist in every month.
  v_post_days  int[] := array[1, 3, 5, 8, 10, 12, 15, 17, 19, 22, 24, 26];
  v_story_days int[] := array[7, 14, 21, 28];
begin
  if p_month is null or p_month <> date_trunc('month', p_month)::date then
    raise exception
      'ensure_month_skeleton: p_month must be the first day of a month, got %.', p_month;
  end if;

  select bk.id into v_brand_kit_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where p.user_id = p_user_id
   order by bk.created_at desc, bk.id desc
   limit 1;

  if v_brand_kit_id is null then
    raise exception
      'ensure_month_skeleton: user % has no brand kit; there is no identity to decline into monthly content.', p_user_id;
  end if;

  -- Subscription decides how much of the month starts open. Status only, never
  -- the grace-period question — that stays in the frontend, see the
  -- subscription migration.
  select coalesce(bool_or(s.status in ('active', 'trialing')), false)
    into v_subscribed
    from public.subscriptions s
   where s.user_id = p_user_id;

  insert into public.monthly_presence_content
    (user_id, brand_kit_id, month, day_of_month, type, status)
  select
    p_user_id,
    v_brand_kit_id,
    p_month,
    d.day,
    d.type,
    case
      when v_subscribed then 'draft'
      -- the single free preview: the first post of the month
      when d.type = 'post' and d.day = v_post_days[1] then 'ready'
      else 'locked'
    end
  from (
    select unnest(v_post_days)  as day, 'post'::text  as type
    union all
    select unnest(v_story_days) as day, 'story'::text as type
  ) as d
  on conflict on constraint monthly_presence_content_slot_key do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end
$$;

comment on function public.ensure_month_skeleton(uuid, date) is
  'Create the 16 empty slots for a month (12 posts, 4 stories) if missing. Idempotent: returns rows actually inserted, 0 on re-run. Structure only; titles and captions are written by eklio-frontend. Call with service_role.';


-- ============================================================================
-- 5. calendar_summary — one query for the home screen
-- ============================================================================
-- The home screen needs the tiles, the ready count and the locked count in one
-- round trip. Three separate queries would be three RLS evaluations of the same
-- rows, and a moment where the counts disagree with the grid.
--
-- SECURITY INVOKER: RLS decides whose rows are counted. Asking for another
-- user's month returns zero items and two zeroes, not an error.

create or replace function public.calendar_summary(p_user_id uuid, p_month date)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with items as (
    select m.*
      from public.monthly_presence_content m
     where m.user_id = p_user_id
       and m.month = p_month
     order by m.day_of_month, m.type
  )
  select jsonb_build_object(
    'items', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'id',           i.id,
                'month',        i.month,
                'day_of_month', i.day_of_month,
                'type',         i.type,
                'status',       i.status,
                'title',        i.title,
                'caption',      i.caption,
                'visual_spec',  i.visual_spec,
                'published_at', i.published_at))
         from items i), '[]'::jsonb),
    'ready_count',  (select count(*) from items where status = 'ready'),
    'locked_count', (select count(*) from items where status = 'locked')
  )
$$;

comment on function public.calendar_summary(uuid, date) is
  'One-round-trip model for the retention home: items in render order, ready_count, locked_count. SECURITY INVOKER, so RLS decides whose rows are counted.';

grant execute on function public.ensure_month_skeleton(uuid, date) to service_role;
grant execute on function public.calendar_summary(uuid, date)     to authenticated, service_role;


-- ============================================================================
-- 6. Guard rails
-- ============================================================================
do $$
declare
  n int;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception
      'monthly_content_calendar: pg_cron is installed. Scheduling belongs to eklio-frontend, which is where the LLM calls are; this repo must not create a job.';
  end if;

  select count(*) into n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'monthly_presence_content'
     and column_name in ('project_id', 'content');
  if n > 0 then
    raise exception 'monthly_content_calendar: the old one-row-per-month columns are still present.';
  end if;

  -- Exactly one table holds monthly content.
  if to_regclass('public.content_calendar_items') is not null then
    raise exception
      'monthly_content_calendar: content_calendar_items exists as well as monthly_presence_content. There must be exactly one monthly content table.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Reverses to lot 4's shape. Only valid while the table is empty, for the same
-- grain reason the forward path is guarded.
--
--   drop function if exists public.calendar_summary(uuid, date);
--   drop function if exists public.ensure_month_skeleton(uuid, date);
--   drop policy if exists "monthly_presence_content_delete_denied" on public.monthly_presence_content;
--   drop policy if exists "monthly_presence_content_update_denied" on public.monthly_presence_content;
--   drop policy if exists "monthly_presence_content_insert_denied" on public.monthly_presence_content;
--   drop policy if exists "monthly_presence_content_select_own"    on public.monthly_presence_content;
--   alter table public.monthly_presence_content
--     drop constraint if exists monthly_presence_content_slot_key,
--     drop constraint if exists monthly_presence_content_title_check,
--     drop constraint if exists monthly_presence_content_published_at_check,
--     drop constraint if exists monthly_presence_content_locked_is_empty_check,
--     drop constraint if exists monthly_presence_content_day_of_month_check,
--     drop constraint if exists monthly_presence_content_type_check,
--     drop constraint if exists monthly_presence_content_brand_kit_id_fkey,
--     drop constraint if exists monthly_presence_content_user_id_fkey;
--   alter table public.monthly_presence_content
--     drop column if exists published_at, drop column if exists visual_spec,
--     drop column if exists caption,      drop column if exists title,
--     drop column if exists type,         drop column if exists day_of_month,
--     drop column if exists brand_kit_id, drop column if exists user_id,
--     add column project_id uuid not null references public.projects (id) on delete cascade,
--     add column content jsonb not null default '{}'::jsonb;
--   -- then re-create lot 4's status check, unique (project_id, month) and policies.
