-- ============================================================================
-- Eklio — lot C6: organization_seo_grid()
-- ============================================================================
-- Proves the schema already supports the grid field research found actually
-- draws organic traffic: modality x licensed state, and modality x
-- population, each cell a clinician count for one practice. No schema
-- change beyond the join tables added in lot C2 was needed — this function
-- is two counting joins over clinician_modalities, clinician_licensed_states
-- and clinician_populations.
-- ============================================================================

create or replace function public.organization_seo_grid(p_organization_id uuid)
returns table (
  grid             text,
  modality_id      text,
  axis_id          text,
  clinician_count  bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  select 'modality_state'::text, cm.modality_id, cls.state_code, count(distinct cm.profile_id)
    from public.clinician_modalities cm
    join public.clinician_licensed_states cls on cls.profile_id = cm.profile_id
    join public.clinician_profiles cp on cp.id = cm.profile_id
   where cp.organization_id = p_organization_id
   group by cm.modality_id, cls.state_code

  union all

  select 'modality_population'::text, cm.modality_id, cpop.population_id, count(distinct cm.profile_id)
    from public.clinician_modalities cm
    join public.clinician_populations cpop on cpop.profile_id = cm.profile_id
    join public.clinician_profiles cp on cp.id = cm.profile_id
   where cp.organization_id = p_organization_id
   group by cm.modality_id, cpop.population_id;
$$;

comment on function public.organization_seo_grid(uuid) is
  'One row per (modality, state) or (modality, population) cell that has at least one clinician, with the clinician count for that cell — the two SEO-axis grids a practice page draws organic traffic from. SECURITY INVOKER: scoped by clinician_profiles/its join tables'' own RLS, same as organization_profile_health — an owner sees the whole practice''s grid, a clinician sees only cells her own profile contributes to.';

revoke execute on function public.organization_seo_grid(uuid) from public, anon;
grant  execute on function public.organization_seo_grid(uuid) to authenticated;
