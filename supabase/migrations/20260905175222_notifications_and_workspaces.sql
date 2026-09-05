-- ============================================================================
-- Eklio — notifications and the one-entry workspace switcher (post-purchase-v2,
-- Lot 2: app chrome)
-- ============================================================================
-- Two independent, small pieces:
--
--   1. `notifications` — a real table, owner-RLS'd, populated by
--      `sync_notifications` from the SAME two signals `home_recent_activity`
--      (Lot 9, 20260903290000) already reads for "Since you were here" — new
--      `brand_assets` rows and `monthly_presence_content` rows that became
--      ready — plus one new one, site-instructions staleness
--      (`site_specs`'s own `stale` diff flag, already computed by
--      `site_spec_diff`/`site_spec_get`, not re-derived here). This is a
--      DIFFERENT surface from home's "since you were here" banner (the bell
--      persists until read, independent of home visits), so it needs its own
--      baseline rather than sharing `home_content_seen_at` — same NULL-means-
--      never-synced convention as that migration: the first sync arms the
--      baseline and reports nothing, so turning this on never dumps a kit's
--      entire render history into her bell at once.
--
--   2. `workspaces` — a view, not a table (nothing to enable RLS on; it
--      filters by `auth.uid()` in its own definition, so a caller only ever
--      sees their own row regardless of who else exists). Returns exactly one
--      row today: her personal workspace. The Practice offer will add rows
--      later without needing the view's shape, or the frontend switcher, to
--      change.
-- ============================================================================

alter table public.brand_kits
  add column if not exists notifications_synced_at timestamptz;

comment on column public.brand_kits.notifications_synced_at is
  'When sync_notifications last ran for this kit. NULL means never synced: the first call arms the baseline and reports nothing, exactly like home_content_seen_at (20260903290000) -- there is no "before" to compare to, and existing history is not a backlog of unread notifications.';

-- ----------------------------------------------------------------------------
-- notifications
-- ----------------------------------------------------------------------------
create table public.notifications (
  id           uuid        not null default gen_random_uuid(),
  user_id      uuid        not null references public.profiles (id) on delete cascade,
  brand_kit_id uuid        not null references public.brand_kits (id) on delete cascade,
  kind         text        not null check (kind in ('asset_rendered', 'site_stale', 'content_ready')),
  payload      jsonb       not null default '{}'::jsonb,
  read_at      timestamptz,
  created_at   timestamptz not null default now(),
  constraint notifications_pkey primary key (id)
);

create index notifications_user_id_read_at_idx
  on public.notifications (user_id, read_at, created_at desc);

-- Dedup, one index per kind, so `sync_notifications` can run twice (a
-- retried request, two near-simultaneous calls) without ever inserting the
-- same event twice -- ON CONFLICT DO NOTHING against these is what makes the
-- function idempotent, not the timestamp comparison alone.
create unique index notifications_asset_rendered_idx
  on public.notifications (brand_kit_id, (payload ->> 'asset_id'))
  where kind = 'asset_rendered';

create unique index notifications_content_ready_idx
  on public.notifications (brand_kit_id, (payload ->> 'item_id'))
  where kind = 'content_ready';

-- 'site_stale' has no natural id to key on -- one UNREAD row per kit at a
-- time is the dedup instead. A read one can be re-created if the site goes
-- stale again after she cleared it.
create unique index notifications_site_stale_unread_idx
  on public.notifications (brand_kit_id)
  where kind = 'site_stale' and read_at is null;

alter table public.notifications enable row level security;

create policy "notifications_select_own"
  on public.notifications for select
  using (user_id = (select auth.uid()));

create policy "notifications_insert_denied"
  on public.notifications for insert
  with check (false);

create policy "notifications_update_denied"
  on public.notifications for update
  using (false);

create policy "notifications_delete_denied"
  on public.notifications for delete
  using (false);

-- ----------------------------------------------------------------------------
-- sync_notifications(p_brand_kit_id) -- arm-or-advance the baseline, insert
-- rows for what moved since it, return the current unread rows.
-- ----------------------------------------------------------------------------
create or replace function public.sync_notifications(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_since   timestamptz;
  v_stale   boolean;
begin
  select p.user_id, bk.notifications_synced_at into v_user_id, v_since
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null or v_user_id <> (select auth.uid()) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such brand kit.'
    ));
  end if;

  if v_since is null then
    update public.brand_kits set notifications_synced_at = now() where id = p_brand_kit_id;
  else
    insert into public.notifications (user_id, brand_kit_id, kind, payload)
    select v_user_id, p_brand_kit_id, 'asset_rendered',
           jsonb_build_object('key', a.key, 'asset_id', a.id)
      from public.brand_assets a
     where a.brand_kit_id = p_brand_kit_id
       and a.created_at > v_since
    on conflict (brand_kit_id, (payload ->> 'asset_id')) where (kind = 'asset_rendered') do nothing;

    insert into public.notifications (user_id, brand_kit_id, kind, payload)
    select v_user_id, p_brand_kit_id, 'content_ready',
           jsonb_build_object('title', c.title, 'item_id', c.id)
      from public.monthly_presence_content c
     where c.brand_kit_id = p_brand_kit_id
       and c.status in ('ready', 'published')
       and c.updated_at > v_since
    on conflict (brand_kit_id, (payload ->> 'item_id')) where (kind = 'content_ready') do nothing;

    -- site_spec_get degrades to an {error:...} envelope (no 'diff' key) for a
    -- kit with no spec row yet or that isn't entitled -- the extraction below
    -- is then simply NULL, coalesced to false, no special-casing needed.
    v_stale := coalesce(
      (public.site_spec_get(p_brand_kit_id) -> 'diff' ->> 'stale')::boolean,
      false
    );

    if v_stale then
      insert into public.notifications (user_id, brand_kit_id, kind, payload)
      values (v_user_id, p_brand_kit_id, 'site_stale', '{}'::jsonb)
      on conflict (brand_kit_id) where (kind = 'site_stale' and read_at is null) do nothing;
    end if;

    update public.brand_kits set notifications_synced_at = now() where id = p_brand_kit_id;
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', n.id, 'kind', n.kind, 'payload', n.payload,
        'read_at', n.read_at, 'created_at', n.created_at
      )
      order by n.created_at desc
    )
    from public.notifications n
    where n.brand_kit_id = p_brand_kit_id and n.read_at is null
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.sync_notifications(uuid) from public, anon;
grant execute on function public.sync_notifications(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- mark_notifications_read(p_brand_kit_id) -- opening the bell clears it.
-- ----------------------------------------------------------------------------
create or replace function public.mark_notifications_read(p_brand_kit_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return false;
  end if;

  update public.notifications n
     set read_at = now()
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id
     and n.brand_kit_id = bk.id
     and n.user_id = (select auth.uid())
     and p.user_id = (select auth.uid())
     and n.read_at is null;

  return true;
end;
$$;

revoke all on function public.mark_notifications_read(uuid) from public, anon;
grant execute on function public.mark_notifications_read(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- workspaces -- one row today, her personal workspace. Practice offer adds
-- rows here later without a frontend/switcher change.
-- ----------------------------------------------------------------------------
create view public.workspaces
with (security_invoker = true)
as
select
  p.id as id,
  coalesce(p.full_name, p.email) as owner_name,
  'Your workspace'::text as name,
  true as is_current
from public.profiles p
where p.id = (select auth.uid());

revoke all on public.workspaces from anon;
grant select on public.workspaces to authenticated;
