-- ============================================================================
-- RLS on `direction_asset_daily_spend` — drift the enumeration caught on its
-- very first run
-- ============================================================================
-- ⚠ THIS IS A NO-OP AGAINST THE LIVE DATABASE, WHERE RLS IS ALREADY ON. It is
-- not a no-op against a rebuild, and that is the whole point.
--
-- The table is created by `20260901074421_direction_assets.sql`, which never
-- enables row level security. The event trigger that would have done it
-- automatically, `rls_auto_enable`, is only codified by
-- `20260901190000_codify_rls_auto_enable.sql` — eleven migrations LATER. So on
-- any clean replay of this repository's own migration history, the table comes
-- out with RLS OFF, and `20260911180918` then puts a `using (false)` policy on
-- a table that does not enforce policies. A deny-all that denies nothing.
--
-- Live it is on, by some route that is not in this repository. That is drift in
-- the safe direction, which is why nothing ever noticed: production is correct
-- and the source of truth is wrong. The first thing the tenancy enumeration did
-- when the CI replay finally reached it was say so.
--
-- ⚠ IT IS ALSO THE ANSWER TO "WHY ENUMERATE AT ALL". Nobody would have found
-- this by reading: the table looks right in the dashboard, the policy exists in
-- a migration, and the effect in production is correct. Only a rebuild from the
-- migrations disagrees with production, and only something that checks every
-- table notices which one.
-- ============================================================================

alter table public.direction_asset_daily_spend enable row level security;

do $$
declare v_off text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_off
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  assert v_off is null, format('RLS is still off on: %s', v_off);
end
$$;
