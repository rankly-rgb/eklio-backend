-- ============================================================================
-- Eklio — lot G: organization_seo_grid_proposals
-- ============================================================================
-- Wraps organization_seo_grid (lot C6) with a proposed page title and slug
-- per cell, using the SAME generator lot F's setup sheet uses
-- (slugify_text / practice_page_title, 20260903160000) — not a second
-- title/slug scheme.
--
-- has_page is always false. Eklio hosts nothing and has no way to know
-- whether a real page exists for a cell on the practice's own Squarespace
-- site — there is no "pages" table to check. Every cell this function
-- returns is therefore, honestly, "no page yet" from Eklio's point of
-- view: that is the literal, uniform answer, not a placeholder for a
-- feature this lot does not build. The column exists so the frontend has
-- something explicit to read rather than assuming.
-- ============================================================================

create or replace function public.organization_seo_grid_proposals(p_organization_id uuid)
returns table (
  grid            text,
  modality_id     text,
  axis_id         text,
  clinician_count bigint,
  proposed_title  text,
  proposed_slug   text,
  has_page        boolean
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_org_name text;
begin
  select name into v_org_name from public.organizations where id = p_organization_id;

  return query
  select
    g.grid,
    g.modality_id,
    g.axis_id,
    g.clinician_count,
    public.practice_page_title(
      array[mc.label || case when g.grid = 'modality_state'
                              then ' Therapy in ' || s.name
                              else ' for ' || pc.label
                         end],
      coalesce(v_org_name, 'the practice')
    ),
    public.slugify_text(mc.label || '-' || coalesce(s.name, pc.label)),
    false
  from public.organization_seo_grid(p_organization_id) g
  join public.modality_cards mc on mc.id = g.modality_id
  left join public.us_states s on g.grid = 'modality_state' and s.code = g.axis_id
  left join public.population_cards pc on g.grid = 'modality_population' and pc.id = g.axis_id;
end;
$$;

comment on function public.organization_seo_grid_proposals(uuid) is
  'organization_seo_grid, enriched with a proposed page title and slug per cell (proposals only — no page is written anywhere). Same scoping as organization_seo_grid: an owner sees the whole practice''s grid, a clinician sees only cells her own profile contributes to.';

revoke execute on function public.organization_seo_grid_proposals(uuid) from public, anon;
grant  execute on function public.organization_seo_grid_proposals(uuid) to authenticated;
