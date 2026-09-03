-- ============================================================================
-- Eklio — tenancy layer, lot 1: RLS rewrite for org-scoped read access
-- ============================================================================
-- Read = owner or self, write = self, billing stays user-scoped. Every SELECT
-- policy touched here is DROPPED BY NAME and RECREATED — never left alongside
-- the old user_id-only policy, which would silently keep the narrower
-- behavior alive under OR.
--
-- project_id-keyed tables (can_access_project): projects, project_briefs,
-- directions, generation_credits, brand_kits.
-- brand_kit_id-keyed tables, no project_id column (can_access_brand_kit, see
-- Amendment A and the migration before this one): site_specs,
-- launch_checklist_items, monthly_presence_content, direction_assets.
-- ============================================================================


-- ============================================================================
-- 1. projects
-- ============================================================================

drop policy if exists "projects_select_own" on public.projects;
drop policy if exists "projects_insert_own" on public.projects;
drop policy if exists "projects_update_own" on public.projects;
drop policy if exists "projects_delete_own" on public.projects;

create policy "projects_select_org"
  on public.projects for select
  using (public.can_access_project(id));

-- Writes stay owner-only: the org owner reads a clinician's project in this
-- lot, she does not edit it.
create policy "projects_insert_own"
  on public.projects for insert
  with check (user_id = (select auth.uid()));

create policy "projects_update_own"
  on public.projects for update
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "projects_delete_own"
  on public.projects for delete
  using (user_id = (select auth.uid()));


-- ============================================================================
-- 2. project_briefs — SELECT only; insert/update/delete unchanged
-- ============================================================================

drop policy if exists "project_briefs_select_own" on public.project_briefs;

create policy "project_briefs_select_org"
  on public.project_briefs for select
  using (public.can_access_project(project_id));


-- ============================================================================
-- 3. directions — SELECT only; insert/update/delete unchanged
-- ============================================================================

drop policy if exists "directions_select_own" on public.directions;

create policy "directions_select_org"
  on public.directions for select
  using (public.can_access_project(project_id));


-- ============================================================================
-- 4. generation_credits — SELECT only; insert/update/delete stay denied
-- ============================================================================

drop policy if exists generation_credits_select_own on public.generation_credits;

create policy generation_credits_select_org
  on public.generation_credits for select
  using (public.can_access_project(project_id));


-- ============================================================================
-- 5. brand_kits — was one FOR ALL policy; split so SELECT can widen without
--    widening writes
-- ============================================================================

drop policy if exists "brand_kits_all_own" on public.brand_kits;

create policy "brand_kits_select_org"
  on public.brand_kits for select
  using (public.can_access_project(project_id));

create policy "brand_kits_insert_own"
  on public.brand_kits for insert
  with check (exists (
    select 1 from public.projects p
    where p.id = brand_kits.project_id and p.user_id = (select auth.uid())
  ));

create policy "brand_kits_update_own"
  on public.brand_kits for update
  using (exists (
    select 1 from public.projects p
    where p.id = brand_kits.project_id and p.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.projects p
    where p.id = brand_kits.project_id and p.user_id = (select auth.uid())
  ));

create policy "brand_kits_delete_own"
  on public.brand_kits for delete
  using (exists (
    select 1 from public.projects p
    where p.id = brand_kits.project_id and p.user_id = (select auth.uid())
  ));
-- The share_slug public-read TODO from the reference migration is untouched:
-- still no policy lets anon read a shared kit. Out of scope for this lot.


-- ============================================================================
-- 6. site_specs — SELECT only, keyed on brand_kit_id via can_access_brand_kit
-- ============================================================================

drop policy if exists "site_specs_select_own" on public.site_specs;

create policy "site_specs_select_org"
  on public.site_specs for select
  using (public.can_access_brand_kit(brand_kit_id));
-- site_specs_update_own, _insert_denied, _delete_denied unchanged: a
-- clinician or owner still only writes her own row (user_id = auth.uid()),
-- and inherited-field lock enforcement is a later lot (see the field_sources
-- comment in the next migration).


-- ============================================================================
-- 7. launch_checklist_items — SELECT only
-- ============================================================================

drop policy if exists "launch_checklist_items_select_own" on public.launch_checklist_items;

create policy "launch_checklist_items_select_org"
  on public.launch_checklist_items for select
  using (public.can_access_brand_kit(brand_kit_id));


-- ============================================================================
-- 8. monthly_presence_content — SELECT only
-- ============================================================================

drop policy if exists "monthly_presence_content_select_own" on public.monthly_presence_content;

create policy "monthly_presence_content_select_org"
  on public.monthly_presence_content for select
  using (public.can_access_brand_kit(brand_kit_id));


-- ============================================================================
-- 9. direction_assets — SELECT only, `to authenticated` kept
-- ============================================================================

drop policy if exists "direction_assets_select_own" on public.direction_assets;

create policy "direction_assets_select_org"
  on public.direction_assets
  for select
  to authenticated
  using (public.can_access_brand_kit(brand_kit_id));


-- ============================================================================
-- 10. Billing — organization_id added for the future, no backfill, no policy
--     change. purchases.project_id is nullable already (a sale outlives a
--     deleted project); organization_id follows the same shape.
-- ============================================================================

alter table public.purchases     add column organization_id uuid references public.organizations (id);
alter table public.subscriptions add column organization_id uuid references public.organizations (id);


-- ============================================================================
-- Tables deliberately left untouched, and why — see the checkpoint report for
-- the same list with reasoning; restated here for anyone reading the schema
-- cold:
--
--   Billing, unchanged (Stripe-facing; per-seat billing is a separate lot):
--     purchases, subscriptions, plan_grants, plans, stripe_events,
--     purchase_status_events.
--   Personal/internal, unchanged (account-level, not project-level; an org
--   owner has no standing to read them):
--     comp_grants, usp_fingerprints, direction_asset_daily_spend, and every
--     reference catalog.
-- ============================================================================
