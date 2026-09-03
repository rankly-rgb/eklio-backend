-- ============================================================================
-- Eklio — "Since you were here" on the home screen (Lot 9)
-- ============================================================================
-- ONE nullable marker, `brand_kits.home_content_seen_at`, and one RPC that
-- reads what changed since it, then moves it forward. Two real signals, both
-- already-existing data with no new pipeline behind either:
--
--   - NEW RENDERED ASSETS — `brand_assets` rows (each one IS a fingerprinted
--     asset; a new row appearing IS its fingerprint changing) created after
--     the marker. "The asset fingerprint," the brief's own words.
--   - CONTENT THAT BECAME READY — `monthly_presence_content` rows whose
--     `status` moved to `ready`/`published` after the marker.
--
-- NOT REUSED: `site_spec_diff`/`change_marks` ("the existing diff" the
-- brief's wording most literally points at) is scoped to "since you last
-- copied your site to a builder," a different life event from "since you
-- last opened home" — reusing it here would mean adding a second baseline
-- column to `site_specs` and a near-duplicate of its parsing logic to avoid
-- touching an already-shipped, tested function. Two real, DB-native signals
-- (assets, content) cover the same spirit — "what's new since you were
-- here" — without that added surface. Recorded as a deliberate scope call,
-- not silently narrower than asked.
-- ============================================================================

alter table public.brand_kits
  add column if not exists home_content_seen_at timestamptz;

comment on column public.brand_kits.home_content_seen_at is
  'When home_recent_activity was last called for this kit -- the baseline "Since you were here" compares against. NULL means never visited: the first call reports nothing (there is no "before" to compare to) and sets this for next time, rather than reporting everything that has ever happened as if it just did.';


-- ============================================================================
-- home_recent_activity — read what changed, then move the marker forward
-- ============================================================================

create or replace function public.home_recent_activity(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_since timestamptz;
  v_new_assets jsonb;
  v_content_ready jsonb;
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
    v_content_ready := '[]'::jsonb;
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

    select coalesce(jsonb_agg(
             jsonb_build_object(
               'type', mpc.type,
               'title', mpc.title,
               'day_of_month', mpc.day_of_month
             )
             order by mpc.day_of_month
           ), '[]'::jsonb)
      into v_content_ready
      from public.monthly_presence_content mpc
     where mpc.brand_kit_id = p_brand_kit_id
       and mpc.status in ('ready', 'published')
       and mpc.updated_at > v_since;
  end if;

  update public.brand_kits
     set home_content_seen_at = now()
   where id = p_brand_kit_id;

  return jsonb_build_object(
    'since', v_since,
    'new_assets', v_new_assets,
    'content_ready', v_content_ready
  );
end
$$;

comment on function public.home_recent_activity(uuid) is
  '"Since you were here" -- new brand_assets rows and monthly_presence_content items that became ready/published since the last call, then advances home_content_seen_at to now(). A NULL prior marker (never visited) reports nothing rather than the kit''s entire history.';

revoke execute on function public.home_recent_activity(uuid) from public, anon;
grant execute on function public.home_recent_activity(uuid) to authenticated, service_role;


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
     and p.proname = 'home_recent_activity'
     and has_function_privilege('anon', p.oid, 'execute');
  if leaked is not null then
    raise exception 'brand_kits: home_recent_activity is still executable by anon: %.', leaked;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   revoke execute on function public.home_recent_activity(uuid) from authenticated, service_role;
--   drop function if exists public.home_recent_activity(uuid);
--   alter table public.brand_kits drop column if exists home_content_seen_at;
-- ============================================================================
