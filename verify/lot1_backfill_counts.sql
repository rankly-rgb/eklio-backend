-- ============================================================================
-- Tenancy layer, lot 1 — backfill sanity check
-- ============================================================================
-- Read-only. Run by hand after applying the 20260903* migrations, to confirm
-- the backfill did what the migration's own `-- expect:` comment says it
-- should. Not a test file — no assertions, no rollback.
--
-- Against the real project (2 profiles today, per the earlier recon report),
-- expect 2/2/2/2, i.e. organizations_created = total_users and
-- active_owner_rows = total_users and projects_with_organization =
-- total_projects. Locally (verify/local_stack/), the numbers depend on
-- whatever fixtures the test suite happened to leave — which is exactly why
-- every count here is printed ALONGSIDE the total it should equal, instead of
-- alone: a bare "2" means nothing without knowing there were 2 users to
-- backfill in the first place.
--
--   supabase db push --db-url <dev branch url>
--   psql <dev branch url> -f verify/lot1_backfill_counts.sql
--
-- or, against the local stack:
--   psql postgresql://postgres:postgres@localhost:5432/eklio_verify \
--     -f verify/lot1_backfill_counts.sql
-- ============================================================================

select
  (select count(*) from auth.users)            as total_users,
  (select count(*) from public.organizations)  as organizations_created;

select
  (select count(*) from auth.users) as total_users,
  (select count(*)
     from public.organization_members
    where role = 'owner' and status = 'active') as active_owner_rows;

select
  (select count(*) from public.projects) as total_projects,
  (select count(*)
     from public.projects
    where organization_id is not null)   as projects_with_organization;
