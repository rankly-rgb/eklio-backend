-- ============================================================================
-- Codify rls_auto_enable() and the ensure_rls event trigger
--
-- Both are live on the hosted project (fobgdsupyfslxbswfuay) and load-bearing
-- — every table anyone has created since this project existed came up with
-- RLS auto-enabled — but neither has ever had a migration. Found while
-- claude/eklio-v1-priorities-ssmasp's revoke_internal_function_surface
-- migration tried to REVOKE EXECUTE on rls_auto_enable() and failed against
-- a fresh replay: the function doesn't exist anywhere in git history.
--
-- Transcribed verbatim from `pg_get_functiondef('rls_auto_enable')` and
-- `pg_event_trigger` on the live project. No renaming, no guard added, no
-- tidying — this migration's only job is to make the repo describe what is
-- already deployed. If it should change, that is a separate migration.
--
-- Must sort before 20260902090000_revoke_internal_function_surface.sql,
-- which revokes EXECUTE on this function and therefore requires it to
-- already exist.
-- ============================================================================

create or replace function public.rls_auto_enable()
 returns event_trigger
 language plpgsql
 security definer
 set search_path to 'pg_catalog'
as $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

drop event trigger if exists ensure_rls;
create event trigger ensure_rls
  on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function public.rls_auto_enable();

-- ============================================================================
-- ⚠ WHAT THIS ACTUALLY DOES, CONFIRMED LIVE, NOT ASSUMED
--
-- `enable row level security` (not `force`) — a fresh table gets RLS turned
-- on and zero policies. Postgres's default with RLS on and no policies is
-- deny-all for every role except the table owner and roles with BYPASSRLS.
--
-- Checked directly against fobgdsupyfslxbswfuay: created a throwaway table
-- inside a transaction (rolled back after), let this event trigger fire on
-- it as it does on any real one, inserted 3 rows, then queried as each role:
--   anon           -> 0 rows
--   authenticated  -> 0 rows
--   service_role   -> 3 rows (rolbypassrls = true, confirmed via pg_roles)
-- No permission-denied error at any point — default privileges on `public`
-- already grant anon/authenticated/service_role full table access, so RLS
-- is the only gate, and it fails silently: the query succeeds, returns
-- valid empty JSON, and looks like a healthy zero-result response.
--
-- THE RULE THIS MEANS FOR EVERY NEW TABLE FROM HERE ON:
-- every new table ships its RLS policies in the SAME migration that creates
-- it. `create table` alone is not a working table — `ensure_rls` guarantees
-- it is an RLS-enabled table with no policies, i.e. silently unreadable and
-- unwritable to anon/authenticated, healthy-looking and empty. This is the
-- same defect family as the README's permissive-default note: nothing
-- errors, everything looks fine, and the answer is quietly empty.
-- ============================================================================
