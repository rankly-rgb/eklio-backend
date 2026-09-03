-- ============================================================================
-- Eklio — the delivery moment: brand_kits.delivered_seen_at (Lot 2)
-- ============================================================================
-- `/app/brand-kits/[id]/delivered` is reachable exactly once per kit: the
-- first load renders the 2.4s ceremony and marks the kit delivered; every
-- later load — a refresh, a bookmark, a back button — redirects straight to
-- the workspace instead of replaying it ("No replay button," per the brief).
--
-- `brand_kits` has no client-writable columns today (every other write on
-- this table goes through a SECURITY DEFINER RPC — `brand_kit_select_direction`
-- for the direction, `enforceEthics` for `ethics_check`, and so on), so this
-- follows the same shape: a nullable timestamp, and one RPC that sets it
-- exactly once and reports whether THIS call was the one that did.
-- ============================================================================

alter table public.brand_kits
  add column if not exists delivered_seen_at timestamptz;

comment on column public.brand_kits.delivered_seen_at is
  'Set once, by mark_brand_kit_delivered, the first time /delivered is loaded for this kit. Never reset — the delivery ceremony has no replay.';


-- ============================================================================
-- mark_brand_kit_delivered — idempotent, race-safe, owner-scoped
-- ============================================================================
-- The UPDATE's own `where ... and delivered_seen_at is null` is the atomicity:
-- under two concurrent calls only one can be the row that actually changes,
-- and plpgsql's `found` after an UPDATE reports exactly that — no read-then-
-- write race window the way a separate SELECT-then-UPDATE would have.

create or replace function public.mark_brand_kit_delivered(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_first_view boolean;
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
     set delivered_seen_at = now()
   where id = p_brand_kit_id
     and delivered_seen_at is null;

  v_first_view := found;

  return jsonb_build_object('first_view', v_first_view);
end
$$;

comment on function public.mark_brand_kit_delivered(uuid) is
  'Marks this kit''s delivery ceremony as seen, once. Returns {"first_view": true} exactly the one time it actually sets delivered_seen_at; every call after that (including concurrent ones) gets {"first_view": false} — the caller''s cue to redirect to the workspace instead of rendering the ceremony.';

revoke execute on function public.mark_brand_kit_delivered(uuid) from public, anon;
grant execute on function public.mark_brand_kit_delivered(uuid) to authenticated, service_role;


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
     and p.proname = 'mark_brand_kit_delivered'
     and has_function_privilege('anon', p.oid, 'execute');
  if leaked is not null then
    raise exception 'brand_kits: mark_brand_kit_delivered is still executable by anon: %.', leaked;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   revoke execute on function public.mark_brand_kit_delivered(uuid) from authenticated, service_role;
--   drop function if exists public.mark_brand_kit_delivered(uuid);
--   alter table public.brand_kits drop column if exists delivered_seen_at;
-- ============================================================================
