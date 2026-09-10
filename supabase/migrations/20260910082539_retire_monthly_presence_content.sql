-- ============================================================================
-- Eklio — the retirement of the dead monthly-content table
-- ============================================================================
-- It held ZERO rows for its entire life. It grew tendrils one at a time — a
-- cron, a notification kind, an RPC, a second RPC, a partial index keyed on a
-- jsonb payload path — and the Content chantier refuses to build a new system
-- beside a dead one. Everything the Session 1 inventory found is removed here.
--
-- ── ⚠ WHY ONE MIGRATION AND NOT FIVE ─────────────────────────────────────
--
-- `home_recent_activity` and `sync_notifications` both run on EVERY home
-- visit. Between two migrations there is a window in which the schema is half
-- retired, and in that window one of them raises: a function still selecting a
-- dropped table is a 500 on the home screen of every paying customer.
--
-- Postgres DDL is transactional, so a single migration has no such window.
-- The whole retirement commits or none of it does.
--
-- ── THE ORDER INSIDE, AND WHY IT IS THIS ORDER ───────────────────────────
--
-- Each step removes only things that nothing still standing refers to:
--
--   1. READERS FIRST. Replace both functions so neither names the table nor
--      writes the `content_ready` payload shape. After this step nothing
--      executable depends on any of what follows.
--   2. ROWS. Delete `content_ready` notifications. Production has none — only
--      `asset_rendered` has ever been written — but step 4 would fail against
--      a row that violates the narrowed CHECK, and "there are none" is a fact
--      about today, not a guarantee.
--   3. THE INDEX. `notifications_content_ready_idx` is a partial unique index
--      over `(payload ->> 'item_id')`. It existed to serve step 1's
--      `on conflict`; with that insert gone it serves nothing. Dropping it
--      BEFORE the function would have broken dedup for the length of the
--      window; dropping it after is safe.
--   4. THE CHECK. Narrow `notifications.kind` to the two kinds that remain.
--   5. THE OTHER FUNCTIONS. `calendar_summary` and `ensure_month_skeleton`
--      exist only to serve this table.
--   6. THE TABLE. Last, when nothing at all points at it. Its trigger, its
--      four policies, its four indexes and its seven CHECK constraints go
--      with it.
--
-- ⚠ A NOTE ON THE GUARD RAIL AT THE BOTTOM, WHICH CAUGHT ME. It greps every
-- function body for the table's name, and `pg_get_functiondef` returns the
-- COMMENTS too. A first draft of this migration left a comment inside
-- `sync_notifications` explaining what used to stand there, naming the table —
-- and the guard failed the migration. It was right to: a name inside a
-- function body is indistinguishable, to that check, from a live reference.
-- The prose below therefore says "the dead table" rather than naming it. This
-- is the SQL twin of the repo's own rule for its static tests: strip the prose,
-- or write prose that does not lie to the grep.
-- ============================================================================


-- ============================================================================
-- 1. The two readers, replaced
-- ============================================================================
-- `sync_notifications` loses its `content_ready` insert and NOTHING else. The
-- asset_rendered insert, the site_stale insert, the marker update and the
-- returned list are byte-for-byte what they were.

create or replace function public.sync_notifications(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
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

    -- A second insert stood here, writing a 'content_ready' notification from
    -- the dead table. Its `on conflict` was the only reason
    -- notifications_content_ready_idx existed. The new system will notify from
    -- content_items when it has something true to say; it does not inherit
    -- this shape.

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
$function$;


-- `home_recent_activity` loses its second query AND the `content_ready` key it
-- returned. Keeping an always-empty key would be a different kind of lie: the
-- home would go on asking a question that can no longer have an answer, and
-- the next person to read the payload would go looking for what fills it.
--
-- `home_content_seen_at` stays exactly as it is — it is still the baseline for
-- new assets, which is the half of this function that was always real.

create or replace function public.home_recent_activity(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid;
  v_since timestamptz;
  v_new_assets jsonb;
begin
  select p.user_id, bk.home_content_seen_at into v_user_id, v_since
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
    v_new_assets := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(
             jsonb_build_object('key', ba.key, 'label', ac.label)
             order by ba.created_at desc
           ), '[]'::jsonb)
      into v_new_assets
      from public.brand_assets ba
      join public.asset_catalog ac on ac.key = ba.key
     where ba.brand_kit_id = p_brand_kit_id
       and ba.created_at > v_since;
  end if;

  update public.brand_kits
     set home_content_seen_at = now()
   where id = p_brand_kit_id;

  return jsonb_build_object(
    'since', v_since,
    'new_assets', v_new_assets
  );
end
$function$;

comment on function public.home_recent_activity(uuid) is
  '"Since you were here" -- new brand_assets rows since the last call, then advances home_content_seen_at to now(). The monthly-content half was removed with that table; content notifications will come from content_items when the new system has something true to say.';


-- ============================================================================
-- 2. The rows (none in production, and this does not depend on that)
-- ============================================================================
delete from public.notifications where kind = 'content_ready';


-- ============================================================================
-- 3. The index whose key was a payload path
-- ============================================================================
drop index if exists public.notifications_content_ready_idx;


-- ============================================================================
-- 4. The kind CHECK
-- ============================================================================
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind = any (array['asset_rendered'::text, 'site_stale'::text]));


-- ============================================================================
-- 5. The two functions that existed only for this table
-- ============================================================================
drop function if exists public.calendar_summary(uuid, date);
drop function if exists public.ensure_month_skeleton(uuid, date);


-- ============================================================================
-- 6. The table
-- ============================================================================
-- `cascade` takes the trigger, the four policies, the four indexes and the
-- seven CHECK constraints. Nothing else points at it: the Session 1 inventory
-- confirmed no view references it and no foreign key targets it.

drop table if exists public.monthly_presence_content cascade;


-- ============================================================================
-- Guard rails — assert the retirement is complete
-- ============================================================================
do $$
declare
  v_dead text := 'monthly' || '_presence_' || 'content';
begin
  if exists (select 1 from information_schema.tables
              where table_schema='public' and table_name = v_dead) then
    raise exception 'retirement: the dead table still exists.';
  end if;

  if exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname in ('calendar_summary','ensure_month_skeleton')) then
    raise exception 'retirement: a dead-table RPC survived.';
  end if;

  -- ⚠ THE ONE THAT MATTERS MOST. A function that still names the table would
  -- raise on the home screen rather than at migration time, which is exactly
  -- the failure this ordering exists to prevent.
  --
  -- The name is ASSEMBLED above rather than written, so that this block can
  -- search for it without containing it: a literal here would match itself the
  -- next time someone runs this same check over this same function.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.prokind='f'
       and pg_get_functiondef(p.oid) ilike '%' || v_dead || '%'
  ) then
    raise exception 'retirement: a function still references the dead table.';
  end if;

  if exists (select 1 from pg_indexes where schemaname='public'
              and indexname='notifications_content_ready_idx') then
    raise exception 'retirement: the content_ready payload index survived.';
  end if;

  if (select pg_get_constraintdef(oid) from pg_constraint
       where conrelid='public.notifications'::regclass and conname='notifications_kind_check')
     ilike '%content_ready%' then
    raise exception 'retirement: notifications.kind still admits content_ready.';
  end if;
end
$$;


-- ============================================================================
-- DOWN — there is none, and that is deliberate
-- ============================================================================
-- The table held zero rows for its entire life. There is nothing to restore.
-- Recreating it would mean recreating the drift this chantier exists to end.
