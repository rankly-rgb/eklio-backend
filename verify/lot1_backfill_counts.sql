-- ============================================================================
-- Tenancy layer, lot 1 — backfill sanity check
-- ============================================================================
-- Read-only. Run by hand against a dev branch after applying the
-- 20260903* migrations, to confirm the backfill did what the migration's own
-- `-- expect:` comment says it should. Not a test file — no assertions, no
-- rollback; it just prints three counts for a human to compare against what
-- they expect from their data.
--
--   supabase db push --db-url <dev branch url>
--   psql <dev branch url> -f verify/lot1_backfill_counts.sql
-- ============================================================================

select count(*) as organizations_created from public.organizations;

select count(*) as active_owner_rows
  from public.organization_members
 where role = 'owner' and status = 'active';

select count(*) as projects_with_organization
  from public.projects
 where organization_id is not null;
