-- ============================================================================
-- Eklio — tenancy layer, lot 1: can_access_project / can_access_brand_kit
-- ============================================================================
-- Split from is_org_member/is_org_owner (20260903100000) because both of
-- these need `projects.organization_id`, added in 20260903100500.
--
-- can_access_brand_kit is Amendment A over the original brief: three tables
-- rewritten in the next migration (site_specs, launch_checklist_items,
-- monthly_presence_content) and one not originally named there
-- (direction_assets) are keyed on brand_kit_id, not project_id — see the
-- Step 0 inventory contradiction in the checkpoint report. There is no
-- project_id on any of those four tables, so can_access_project cannot be
-- their SELECT predicate directly; can_access_brand_kit does the extra hop.
-- ============================================================================

create or replace function public.can_access_project(p_project_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid;
  v_org_id   uuid;
begin
  if auth.uid() is null then
    return false;
  end if;

  select p.user_id, p.organization_id
    into v_owner_id, v_org_id
    from public.projects p
   where p.id = p_project_id;

  if not found then
    return false;
  end if;

  return v_owner_id = auth.uid() or public.is_org_owner(v_org_id);
end;
$$;

comment on function public.can_access_project(uuid) is
  'True iff the calling user is the project''s own user_id, or the active owner of the organization it belongs to. False for anon, and false for a non-existent project. Read access only — this is not a write check.';

create or replace function public.can_access_brand_kit(p_brand_kit_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_project_id uuid;
begin
  if auth.uid() is null then
    return false;
  end if;

  select bk.project_id
    into v_project_id
    from public.brand_kits bk
   where bk.id = p_brand_kit_id;

  if not found then
    return false;
  end if;

  return public.can_access_project(v_project_id);
end;
$$;

comment on function public.can_access_brand_kit(uuid) is
  'True iff can_access_project holds for the brand kit''s project. Used as the SELECT predicate on the brand_kit_id-keyed tables (site_specs, launch_checklist_items, monthly_presence_content, direction_assets), which carry no project_id of their own.';

-- ⚠ GRANTED TO anon TOO — found necessary by actually running an anon query
-- against `projects` and hitting "permission denied for function
-- can_access_project" instead of the expected empty result. Both functions
-- are named directly in a `using (...)` clause on tables anon otherwise still
-- has raw SELECT privilege on (the repo's RLS-only convention — see the
-- Step 0 inventory); Postgres requires the QUERYING role to hold EXECUTE on
-- every function an RLS policy calls, or evaluating the policy itself raises
-- instead of silently filtering. Harmless to grant: both return `false` on
-- `auth.uid() is null`, the first line of each body, so a client calling
-- either directly (as a stray RPC, not through a policy) learns nothing.
-- is_org_member/is_org_owner do NOT need this — they are only reached via
-- can_access_project's own SECURITY DEFINER body (no separate privilege
-- check on an internal call) or via policies on organizations/
-- organization_members, where anon has zero table privilege at all and the
-- table-level check fails first.
revoke execute on function public.can_access_project(uuid)   from public;
grant  execute on function public.can_access_project(uuid)   to anon, authenticated;
revoke execute on function public.can_access_brand_kit(uuid) from public;
grant  execute on function public.can_access_brand_kit(uuid) to anon, authenticated;
