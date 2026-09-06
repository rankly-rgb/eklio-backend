-- ============================================================================
-- Eklio — content_items: the editorial calendar she can actually write in
-- ============================================================================
-- WHY A NEW TABLE RATHER THAN `monthly_presence_content`
-- ------------------------------------------------------
-- The brief's own contingency, taken deliberately. `monthly_presence_content`
-- (20260827105000) stores posts as rows, but every client write is refused by
-- policy — `insert with check (false)`, `update using (false)`,
-- `delete using (false)` — and it holds ZERO rows on this project. LOT 6 needs
-- autosave and a "mark as posted" toggle, which are UPDATEs, and it needs
-- `archetype`, `tags`, `alt_text`, `category`, `image_slot` and `scheduled_for`,
-- none of which that table has. Reusing it would mean widening its CHECKs,
-- inverting its RLS posture from deny-all to owner-write, and bolting on six
-- columns — at which point it is not the same table any more, only the same
-- name.
--
-- ⚠ `monthly_presence_content` IS LEFT EXACTLY AS IT IS. Not dropped, not
-- altered, not renamed. It is now dead — nothing reads it once LOT 6 lands —
-- and that fact is recorded in eklio-frontend's FINDINGS.md rather than acted
-- on here, because dropping a table is a decision with no undo and this
-- migration does not need it gone to be correct.
--
-- ── OWNERSHIP IS THROUGH THE KIT, AND ONLY THROUGH THE KIT ─────────────────
--
-- No `user_id` column. `brand_kit_id` → `projects.user_id` is the one path, the
-- same one `brand_images` uses. The older table carried both and had to keep
-- them in agreement; a second column recording the same fact is a second column
-- that can be wrong.
--
-- ── THE LOG IS THE PUBLICATION STATE ───────────────────────────────────────
--
-- `content_items` has NO `published` status and NO `published_at`. Whether an
-- item is posted is derived from the last row in `content_publications`, which
-- is append-only and which clients cannot write at all. That is the whole
-- reason the log can be trusted: there is no second copy of the same fact for
-- it to drift from, and "unpost then repost" leaves a history rather than
-- overwriting one. `status` is authoring state only: draft, ready, archived.
--
-- ── NOTHING HERE GENERATES ANYTHING ────────────────────────────────────────
--
-- No model call, no credit, no budget. `consume_generation_credit` and
-- `plans.image_budget_cents` are not referenced by any function in this file,
-- and a guard rail at the bottom fails the migration if that ever stops being
-- true. Filling a caption from a model is a later lot's job; this one gives
-- those rows somewhere to land and gives her the ability to write them herself.
-- ============================================================================


-- ============================================================================
-- 1. content_items
-- ============================================================================
create table if not exists public.content_items (
  id            uuid primary key default gen_random_uuid(),
  brand_kit_id  uuid not null,
  archetype     text not null,
  status        text not null default 'draft',
  title         text,
  caption       text,
  alt_text      text,
  tags          text[] not null default '{}'::text[],
  category      text,
  image_slot    text,
  scheduled_for date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint content_items_brand_kit_id_fkey foreign key (brand_kit_id)
    references public.brand_kits (id) on delete cascade,

  -- The brief's five archetypes. They already exist as asset catalogue keys
  -- (post_statement_1080, post_question_1080, post_notes_1080,
  -- post_signature_1080, story_1080x1920); this is the same vocabulary as
  -- data rather than as filenames.
  constraint content_items_archetype_check check (archetype in
    ('statement','question','notes','signature','story')),

  -- Authoring state ONLY. 'published' is deliberately absent — see the header.
  constraint content_items_status_check check (status in
    ('draft','ready','archived')),

  -- The same 34 characters the calendar tile has always allowed: the caption
  -- under a thumbnail is one line at 14px, and a title that wraps there is a
  -- title that was never going to fit.
  constraint content_items_title_check check
    (title is null or char_length(title) <= 34),
  -- Instagram's own ceiling. A caption she cannot post is not a caption.
  constraint content_items_caption_check check
    (caption is null or char_length(caption) <= 2200),
  constraint content_items_alt_text_check check
    (alt_text is null or char_length(alt_text) <= 420),
  constraint content_items_category_check check
    (category is null or char_length(category) <= 40),
  constraint content_items_tags_check check (coalesce(array_length(tags, 1), 0) <= 8),

  -- The seven photograph slots, by name. NO foreign key to `brand_images`:
  -- an item may name the slot it wants long before that slot has generated,
  -- and a kit whose photographs are stale still has items pointing at them.
  -- The name is a reference to a SLOT, not to a row.
  constraint content_items_image_slot_check check (image_slot is null or image_slot in
    ('hero','ambient_a','ambient_b','post_bg_1','post_bg_2','post_bg_3','texture'))
);

comment on table public.content_items is
  'Her editorial calendar, one row per post or story, owner-writable through SECURITY DEFINER RPCs. Replaces monthly_presence_content, which is left in place but dead. Publication state is NOT here — it is derived from content_publications.';
comment on column public.content_items.status is
  'Authoring state only: draft, ready, archived. Whether an item has been posted comes from content_publications, never from this column.';
comment on column public.content_items.image_slot is
  'Which of the seven brand_images slots this item wants behind it, by name. Deliberately not a foreign key: an item may name a slot before that slot has generated.';

create index if not exists content_items_kit_scheduled_idx
  on public.content_items (brand_kit_id, scheduled_for);
create index if not exists content_items_kit_created_idx
  on public.content_items (brand_kit_id, created_at desc);


-- ============================================================================
-- 2. content_publications — append-only, and the reason the log is truthful
-- ============================================================================
create table if not exists public.content_publications (
  id              uuid primary key default gen_random_uuid(),
  content_item_id uuid not null,
  action          text not null,
  channel         text,
  occurred_at     timestamptz not null default now(),

  constraint content_publications_item_fkey foreign key (content_item_id)
    references public.content_items (id) on delete cascade,
  constraint content_publications_action_check check (action in ('published','unpublished')),
  constraint content_publications_channel_check check (channel is null or channel in
    ('instagram','facebook','linkedin','newsletter','other'))
);

comment on table public.content_publications is
  'Append-only publishing log: one row each time she marks an item posted or un-posts it. Clients cannot INSERT, UPDATE or DELETE here at all — every row is written by mark_content_posted. An item is "posted" iff its most recent row says published.';

create index if not exists content_publications_item_idx
  on public.content_publications (content_item_id, occurred_at desc);


-- ============================================================================
-- 3. RLS — in the same migration that creates the tables
-- ============================================================================
-- SELECT is owner-scoped through the kit. Every write is refused to clients and
-- goes through the RPCs below, which is where the entitlement check and the
-- not_found-before-payment_required ordering live. One place to get it right.

alter table public.content_items        enable row level security;
alter table public.content_publications enable row level security;

drop policy if exists "content_items_select_own"     on public.content_items;
drop policy if exists "content_items_insert_denied"  on public.content_items;
drop policy if exists "content_items_update_denied"  on public.content_items;
drop policy if exists "content_items_delete_denied"  on public.content_items;

create policy "content_items_select_own"
  on public.content_items for select to authenticated
  using (
    exists (
      select 1
        from public.brand_kits bk
        join public.projects pr on pr.id = bk.project_id
       where bk.id = content_items.brand_kit_id
         and pr.user_id = (select auth.uid())
    )
  );

create policy "content_items_insert_denied"
  on public.content_items for insert to authenticated with check (false);
create policy "content_items_update_denied"
  on public.content_items for update to authenticated using (false);
create policy "content_items_delete_denied"
  on public.content_items for delete to authenticated using (false);

drop policy if exists "content_publications_select_own"    on public.content_publications;
drop policy if exists "content_publications_insert_denied" on public.content_publications;
drop policy if exists "content_publications_update_denied" on public.content_publications;
drop policy if exists "content_publications_delete_denied" on public.content_publications;

create policy "content_publications_select_own"
  on public.content_publications for select to authenticated
  using (
    exists (
      select 1
        from public.content_items ci
        join public.brand_kits bk on bk.id = ci.brand_kit_id
        join public.projects  pr on pr.id = bk.project_id
       where ci.id = content_publications.content_item_id
         and pr.user_id = (select auth.uid())
    )
  );

-- Append-only is enforced here, not by convention: even the owner cannot
-- rewrite her own history through the client.
create policy "content_publications_insert_denied"
  on public.content_publications for insert to authenticated with check (false);
create policy "content_publications_update_denied"
  on public.content_publications for update to authenticated using (false);
create policy "content_publications_delete_denied"
  on public.content_publications for delete to authenticated using (false);


-- ============================================================================
-- 4. content_kit_access — the ordering, written once
-- ============================================================================
-- Returns NULL when the caller may write to this kit, else the error code the
-- RPCs return. `not_found` comes FIRST and on its own: a stranger's kit must
-- never answer `payment_required`, because that confirms the kit exists.

create or replace function public.content_kit_access(p_brand_kit_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (
      select 1
        from public.brand_kits bk
        join public.projects pr on pr.id = bk.project_id
       where bk.id = p_brand_kit_id
         and pr.user_id = (select auth.uid())
    ) then 'not_found'
    when not public.brand_kit_entitled(p_brand_kit_id) then 'payment_required'
    else null
  end
$$;

comment on function public.content_kit_access(uuid) is
  'NULL when the caller owns this kit and has paid for it; otherwise the error code every content RPC returns. not_found is checked first and alone, so a kit that is not hers never answers payment_required.';

create or replace function public.content_error(p_code text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('error', jsonb_build_object(
    'code', p_code,
    'message', case p_code
      when 'not_found'        then 'No such content item.'
      when 'payment_required' then 'This brand kit is not yet paid for.'
      else p_code
    end
  ))
$$;


-- ============================================================================
-- 5. Normalizing the free text she types
-- ============================================================================
-- Tags are hers to invent, so they are not constrained to a vocabulary — but
-- they ARE normalized, because "Anxiety", "anxiety " and "anxiety" are one tag
-- and a filter that treats them as three is a filter she stops trusting.

create or replace function public.content_normalize_tags(p_tags text[])
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    (select array_agg(t order by t)
       from (
         select distinct left(lower(btrim(tag)), 24) as t
           from unnest(coalesce(p_tags, '{}'::text[])) as tag
          where btrim(tag) <> ''
       ) cleaned
    ),
    '{}'::text[]
  )
$$;

comment on function public.content_normalize_tags(text[]) is
  'Trim, lowercase, truncate to 24 characters, drop blanks, de-duplicate, sort. Applied by the write RPCs so the stored array is canonical; the 8-tag ceiling is a CHECK on the column.';


-- ============================================================================
-- 6. The write surface
-- ============================================================================

-- 6.1 create_content_item
create or replace function public.create_content_item(
  p_brand_kit_id  uuid,
  p_archetype     text,
  p_scheduled_for date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_error text;
  v_id    uuid;
begin
  v_error := public.content_kit_access(p_brand_kit_id);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  insert into public.content_items (brand_kit_id, archetype, scheduled_for)
  values (p_brand_kit_id, p_archetype, p_scheduled_for)
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end
$$;

-- 6.2 update_content_item — a PATCH, because autosave sends what changed
--
-- A jsonb patch rather than nine positional arguments: only the keys PRESENT
-- are written, so clearing a caption (key present, value null) is a different
-- request from not touching it (key absent). Nine nullable arguments cannot
-- express that difference at all.
create or replace function public.update_content_item(
  p_id    uuid,
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kit   uuid;
  v_error text;
  v_bad   text;
begin
  select ci.brand_kit_id into v_kit
    from public.content_items ci
   where ci.id = p_id;

  if v_kit is null then
    return public.content_error('not_found');
  end if;

  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  -- An unknown key is a caller bug, and silently dropping it would let a
  -- renamed field autosave into nothing for a release before anyone noticed.
  select string_agg(key, ', ') into v_bad
    from jsonb_object_keys(p_patch) as key
   where key not in ('archetype','status','title','caption','alt_text',
                     'tags','category','image_slot','scheduled_for');
  if v_bad is not null then
    return public.content_error('unknown_field');
  end if;

  update public.content_items ci set
    archetype     = case when p_patch ? 'archetype'  then p_patch ->> 'archetype'  else ci.archetype end,
    status        = case when p_patch ? 'status'     then p_patch ->> 'status'     else ci.status end,
    title         = case when p_patch ? 'title'      then p_patch ->> 'title'      else ci.title end,
    caption       = case when p_patch ? 'caption'    then p_patch ->> 'caption'    else ci.caption end,
    alt_text      = case when p_patch ? 'alt_text'   then p_patch ->> 'alt_text'   else ci.alt_text end,
    category      = case when p_patch ? 'category'   then p_patch ->> 'category'   else ci.category end,
    image_slot    = case when p_patch ? 'image_slot' then p_patch ->> 'image_slot' else ci.image_slot end,
    scheduled_for = case when p_patch ? 'scheduled_for'
                         then nullif(p_patch ->> 'scheduled_for', '')::date else ci.scheduled_for end,
    tags          = case when p_patch ? 'tags'
                         then public.content_normalize_tags(
                                array(select jsonb_array_elements_text(p_patch -> 'tags')))
                         else ci.tags end,
    updated_at    = now()
  where ci.id = p_id;

  return jsonb_build_object('id', p_id, 'saved_at', now());
end
$$;

-- 6.3 delete_content_item
create or replace function public.delete_content_item(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kit   uuid;
  v_error text;
begin
  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = p_id;
  if v_kit is null then
    return public.content_error('not_found');
  end if;

  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  -- The log goes with it, by cascade. An item she deleted is not a publication
  -- history she wants to keep reading.
  delete from public.content_items where id = p_id;
  return jsonb_build_object('deleted', true);
end
$$;

-- 6.4 mark_content_posted — the ONLY writer of the log
create or replace function public.mark_content_posted(
  p_id      uuid,
  p_posted  boolean,
  p_channel text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kit     uuid;
  v_error   text;
  v_current text;
  v_action  text;
begin
  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = p_id;
  if v_kit is null then
    return public.content_error('not_found');
  end if;

  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  v_action := case when p_posted then 'published' else 'unpublished' end;

  -- Idempotent: marking an already-posted item posted again writes nothing.
  -- Without this the log fills with duplicate rows every time a double click
  -- or a retried request lands, and a log with phantom entries is worse than
  -- no log.
  select cp.action into v_current
    from public.content_publications cp
   where cp.content_item_id = p_id
   order by cp.occurred_at desc, cp.id desc
   limit 1;

  if coalesce(v_current, 'unpublished') = v_action then
    return jsonb_build_object('posted', p_posted, 'changed', false);
  end if;

  insert into public.content_publications (content_item_id, action, channel)
  values (p_id, v_action, case when p_posted then p_channel else null end);

  return jsonb_build_object('posted', p_posted, 'changed', true);
end
$$;


-- ============================================================================
-- 7. The read surface
-- ============================================================================
-- One shape, built in one place: an item plus its derived publication state.
create or replace function public.content_item_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',            ci.id,
    'brand_kit_id',  ci.brand_kit_id,
    'archetype',     ci.archetype,
    'status',        ci.status,
    'title',         ci.title,
    'caption',       ci.caption,
    'alt_text',      ci.alt_text,
    'tags',          to_jsonb(ci.tags),
    'category',      ci.category,
    'image_slot',    ci.image_slot,
    'scheduled_for', ci.scheduled_for,
    'created_at',    ci.created_at,
    'updated_at',    ci.updated_at,
    'posted',        coalesce(last_pub.action = 'published', false),
    'posted_at',     case when last_pub.action = 'published' then last_pub.occurred_at end,
    'channel',       case when last_pub.action = 'published' then last_pub.channel end
  )
  from public.content_items ci
  left join lateral (
    select cp.action, cp.occurred_at, cp.channel
      from public.content_publications cp
     where cp.content_item_id = ci.id
     order by cp.occurred_at desc, cp.id desc
     limit 1
  ) last_pub on true
  where ci.id = p_id
$$;

-- 7.1 get_content_month — the calendar, in one round trip
create or replace function public.get_content_month(
  p_brand_kit_id uuid,
  p_month        date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_error text;
  v_start date;
begin
  v_error := public.content_kit_access(p_brand_kit_id);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  v_start := date_trunc('month', p_month)::date;

  return jsonb_build_object(
    'month', v_start,
    'items', coalesce((
      select jsonb_agg(public.content_item_json(ci.id) order by ci.scheduled_for, ci.created_at)
        from public.content_items ci
       where ci.brand_kit_id = p_brand_kit_id
         and ci.scheduled_for >= v_start
         and ci.scheduled_for < (v_start + interval '1 month')::date
         and ci.status <> 'archived'
    ), '[]'::jsonb),
    'unscheduled', coalesce((
      select jsonb_agg(public.content_item_json(ci.id) order by ci.created_at desc)
        from public.content_items ci
       where ci.brand_kit_id = p_brand_kit_id
         and ci.scheduled_for is null
         and ci.status <> 'archived'
    ), '[]'::jsonb),
    'counts', (
      select jsonb_build_object(
        'scheduled', count(*) filter (where ci.scheduled_for is not null),
        'ready',     count(*) filter (where ci.status = 'ready'),
        'posted',    count(*) filter (where public.content_item_json(ci.id) ->> 'posted' = 'true')
      )
        from public.content_items ci
       where ci.brand_kit_id = p_brand_kit_id
         and ci.status <> 'archived'
         and (ci.scheduled_for is null
              or (ci.scheduled_for >= v_start
                  and ci.scheduled_for < (v_start + interval '1 month')::date))
    )
  );
end
$$;

-- 7.2 get_content_item — one item, for the editor
create or replace function public.get_content_item(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_kit   uuid;
  v_error text;
begin
  select ci.brand_kit_id into v_kit from public.content_items ci where ci.id = p_id;
  if v_kit is null then
    return public.content_error('not_found');
  end if;

  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  return public.content_item_json(p_id);
end
$$;

-- 7.3 get_publishing_log — what she has actually posted, most recent first
create or replace function public.get_publishing_log(
  p_brand_kit_id uuid,
  p_limit        int default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_error text;
begin
  v_error := public.content_kit_access(p_brand_kit_id);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  return jsonb_build_object('entries', coalesce((
    select jsonb_agg(entry order by (entry ->> 'occurred_at') desc)
      from (
        select jsonb_build_object(
                 'id',          cp.id,
                 'item_id',     ci.id,
                 'title',       ci.title,
                 'archetype',   ci.archetype,
                 'action',      cp.action,
                 'channel',     cp.channel,
                 'occurred_at', cp.occurred_at
               ) as entry
          from public.content_publications cp
          join public.content_items ci on ci.id = cp.content_item_id
         where ci.brand_kit_id = p_brand_kit_id
         order by cp.occurred_at desc, cp.id desc
         limit greatest(1, least(coalesce(p_limit, 50), 200))
      ) rows
  ), '[]'::jsonb));
end
$$;


-- ============================================================================
-- 8. Grants
-- ============================================================================
-- `content_item_json` is a shared helper, not a surface: it takes an id and
-- performs no access check of its own, so it is NOT granted to authenticated.
--
-- `from public` as well as the two roles: without it the default PUBLIC grant
-- survives the revoke and the helper stays callable by anyone. Removing
-- service_role's right along with it is intended -- these are called only from
-- inside the SECURITY DEFINER functions below, which run as their owner.
revoke execute on function public.content_item_json(uuid)        from public, anon, authenticated;
revoke execute on function public.content_kit_access(uuid)       from public, anon, authenticated;
revoke execute on function public.content_error(text)            from public, anon, authenticated;
revoke execute on function public.content_normalize_tags(text[]) from public, anon, authenticated;

grant execute on function public.create_content_item(uuid, text, date)    to authenticated;
grant execute on function public.update_content_item(uuid, jsonb)         to authenticated;
grant execute on function public.delete_content_item(uuid)                to authenticated;
grant execute on function public.mark_content_posted(uuid, boolean, text) to authenticated;
grant execute on function public.get_content_month(uuid, date)            to authenticated;
grant execute on function public.get_content_item(uuid)                   to authenticated;
grant execute on function public.get_publishing_log(uuid, int)            to authenticated;


-- ============================================================================
-- 9. Guard rails
-- ============================================================================
do $$
declare
  v_bad text;
begin
  -- Nothing in this lot may spend anything. Not a comment: a check.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('create_content_item','update_content_item','delete_content_item',
                       'mark_content_posted','get_content_month','get_content_item',
                       'get_publishing_log','content_item_json','content_kit_access')
     and (p.prosrc like '%consume_generation_credit%'
       or p.prosrc like '%image_budget_cents%'
       or p.prosrc like '%reserve_image_regeneration%');
  if v_bad is not null then
    raise exception 'content_items: % reference a spending path. Content is not a generation.', v_bad;
  end if;

  -- The older table is untouched: same policy count, still write-denied.
  if (select count(*) from pg_policies
       where schemaname = 'public' and tablename = 'monthly_presence_content') <> 4 then
    raise exception 'content_items: monthly_presence_content policies changed. This migration must not touch it.';
  end if;

  -- Publication state has exactly one home.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'content_items'
       and column_name in ('published_at', 'posted_at')
  ) then
    raise exception 'content_items: publication state must live in content_publications only.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.get_publishing_log(uuid, int);
--   drop function if exists public.get_content_item(uuid);
--   drop function if exists public.get_content_month(uuid, date);
--   drop function if exists public.content_item_json(uuid);
--   drop function if exists public.mark_content_posted(uuid, boolean, text);
--   drop function if exists public.delete_content_item(uuid);
--   drop function if exists public.update_content_item(uuid, jsonb);
--   drop function if exists public.create_content_item(uuid, text, date);
--   drop function if exists public.content_normalize_tags(text[]);
--   drop function if exists public.content_error(text);
--   drop function if exists public.content_kit_access(uuid);
--   drop table if exists public.content_publications;
--   drop table if exists public.content_items;
