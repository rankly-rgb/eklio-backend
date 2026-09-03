-- ============================================================================
-- Eklio — soft-deleting a brand kit (Lot 9)
-- ============================================================================
-- `deleted_at`, three owner-scoped RPCs, and nothing that touches money:
-- deletion never refunds (the brief is explicit), so this migration never
-- goes near `purchases` or `subscriptions` — a soft-deleted kit's purchase
-- record is untouched, exactly as it should be.
--
-- THE 30-DAY WINDOW IS NOT ENFORCED HERE. `deleted_at` only marks when the
-- clock started; the actual hard-delete + storage purge is a separate,
-- externally-scheduled cron (`app/api/cron/purge-deleted-kits`, eklio-
-- frontend, following the exact same `authorizeCron`/service_role pattern
-- `app/api/cron/monthly` already established) — nothing in this migration
-- runs it, and nothing here is irreversible. `restore_brand_kit` undoes a
-- soft delete at any point before that cron actually removes the row.
--
-- RLS's SELECT policy on `brand_kits` is deliberately left untouched: a
-- soft-deleted kit stays visible to its owner (that's how `list_deleted_
-- brand_kits` and a "Recently deleted" screen work at all). Every READ that
-- should treat a deleted kit as gone — the workspace, home's kit lookup —
-- filters `deleted_at is null` at the query level, in eklio-frontend; this
-- migration is schema and write-path only.
-- ============================================================================

alter table public.brand_kits
  add column if not exists deleted_at timestamptz;

comment on column public.brand_kits.deleted_at is
  'Soft delete, set by delete_brand_kit and cleared by restore_brand_kit. RLS SELECT is unchanged (the owner can still read a deleted kit) -- every read that should hide one filters this at the query level. A kit deleted 30+ days ago is the purge cron''s candidate list, not something this column enforces itself.';


-- ============================================================================
-- delete_brand_kit / restore_brand_kit — idempotent, owner-scoped
-- ============================================================================

create or replace function public.delete_brand_kit(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_deleted_at timestamptz;
begin
  select p.user_id into v_user_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null or v_user_id <> (select auth.uid()) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such brand kit.'
    ));
  end if;

  update public.brand_kits
     set deleted_at = coalesce(deleted_at, now())
   where id = p_brand_kit_id
  returning deleted_at into v_deleted_at;

  return jsonb_build_object('ok', true, 'deleted_at', v_deleted_at);
end
$$;

comment on function public.delete_brand_kit(uuid) is
  'Soft-deletes the caller''s own kit. Idempotent -- re-marking an already-deleted kit does not move its deleted_at. Never touches purchases/subscriptions: deletion does not refund.';

revoke execute on function public.delete_brand_kit(uuid) from public, anon;
grant execute on function public.delete_brand_kit(uuid) to authenticated, service_role;

create or replace function public.restore_brand_kit(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  select p.user_id into v_user_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null or v_user_id <> (select auth.uid()) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such brand kit.'
    ));
  end if;

  update public.brand_kits
     set deleted_at = null
   where id = p_brand_kit_id
     and deleted_at is not null;

  if not found then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'This kit is not in Recently deleted.'
    ));
  end if;

  return jsonb_build_object('ok', true);
end
$$;

comment on function public.restore_brand_kit(uuid) is
  'Undoes a soft delete, any time before the purge cron actually removes the row. Refuses a kit that is not currently deleted -- "nothing to restore" is the same not_found shape as "not yours" or "does not exist," so this never confirms to a caller which case they hit.';

revoke execute on function public.restore_brand_kit(uuid) from public, anon;
grant execute on function public.restore_brand_kit(uuid) to authenticated, service_role;


-- ============================================================================
-- list_deleted_brand_kits — the "Recently deleted" read
-- ============================================================================
-- Bounded to the 30-day window on purpose: a kit whose window has technically
-- lapsed but that the purge cron hasn't reached yet (a missed run, a slow
-- day) should not still read as "recently deleted, N days left" with a
-- negative number -- it should simply stop appearing here, same as if it
-- had already been purged.

create or replace function public.list_deleted_brand_kits()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'brand_kit_id', bk.id,
      'practice_name', coalesce(pb.practice_name, p.name),
      'deleted_at', bk.deleted_at,
      'purge_at', bk.deleted_at + interval '30 days'
    )
    order by bk.deleted_at desc
  ), '[]'::jsonb)
  from public.brand_kits bk
  join public.projects p on p.id = bk.project_id
  left join public.project_briefs pb on pb.project_id = p.id
  where p.user_id = (select auth.uid())
    and bk.deleted_at is not null
    and bk.deleted_at > now() - interval '30 days';
$$;

comment on function public.list_deleted_brand_kits() is
  'The caller''s own soft-deleted kits still inside the 30-day window, newest first. practice_name falls back to the project name, matching the frontend''s own hydrate() fallback (lib/data/brand-kit.ts) -- the same name shown everywhere else for this kit, not a second guess at it.';

revoke execute on function public.list_deleted_brand_kits() from public, anon;
grant execute on function public.list_deleted_brand_kits() to authenticated, service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  leaked text;
begin
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into leaked
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('delete_brand_kit', 'restore_brand_kit', 'list_deleted_brand_kits')
     and has_function_privilege('anon', p.oid, 'execute');
  if leaked is not null then
    raise exception 'brand_kits: still executable by anon: %.', leaked;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   revoke execute on function public.list_deleted_brand_kits() from authenticated, service_role;
--   drop function if exists public.list_deleted_brand_kits();
--   revoke execute on function public.restore_brand_kit(uuid) from authenticated, service_role;
--   drop function if exists public.restore_brand_kit(uuid);
--   revoke execute on function public.delete_brand_kit(uuid) from authenticated, service_role;
--   drop function if exists public.delete_brand_kit(uuid);
--   -- deleted_at is not dropped: doing so would silently un-delete every
--   -- currently-deleted kit rather than reversing the feature cleanly.
-- ============================================================================
