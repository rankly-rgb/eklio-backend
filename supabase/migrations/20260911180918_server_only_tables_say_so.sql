-- ============================================================================
-- Seven tables that deny everything, and now say so
-- ============================================================================
-- RLS on with no policy already returns zero rows to `anon` and
-- `authenticated` and raises nothing. The effect was right; the INTENT was
-- nowhere — a reader could not tell "server-only, deliberately" from "somebody
-- forgot the policy", and the two look identical in `pg_policies`.
--
-- This changes no behaviour whatsoever. Every one of these policies is
-- `using (false) with check (false)`, which is what the absence already meant.
-- `service_role` has BYPASSRLS and is unaffected, exactly as before.
--
-- ⚠ THE POINT IS THE ENUMERATION TEST. It demands that every table be either
-- reachable from an organization or explicitly denied. With these seven silent,
-- the test would have shipped with seven exemptions on its first run, and a
-- list of seven exemptions is where the eighth hides.
--
-- The idiom is copied exactly from `funnel_events_denied` and
-- `anon_counters_denied`, which have carried it since they were built.
-- ============================================================================

-- Eklio's own instruments and configuration. Nobody's data, nobody's screen.
drop policy if exists app_settings_denied on public.app_settings;
create policy app_settings_denied on public.app_settings
  for all using (false) with check (false);

drop policy if exists brand_image_daily_spend_denied on public.brand_image_daily_spend;
create policy brand_image_daily_spend_denied on public.brand_image_daily_spend
  for all using (false) with check (false);

drop policy if exists direction_asset_daily_spend_denied on public.direction_asset_daily_spend;
create policy direction_asset_daily_spend_denied on public.direction_asset_daily_spend
  for all using (false) with check (false);

drop policy if exists stripe_events_denied on public.stripe_events;
create policy stripe_events_denied on public.stripe_events
  for all using (false) with check (false);

-- Guardrail vocabularies. Read by the server while validating what she wrote;
-- publishing them would be publishing the rules she is being judged against.
drop policy if exists banned_phrases_denied on public.banned_phrases;
create policy banned_phrases_denied on public.banned_phrases
  for all using (false) with check (false);

drop policy if exists usp_stopwords_denied on public.usp_stopwords;
create policy usp_stopwords_denied on public.usp_stopwords
  for all using (false) with check (false);

/*
 * ⚠ `comp_grants` IS THE ONE TO LOOK AT TWICE, and this policy records a
 * decision rather than a default. It carries a `user_id` and grants
 * complimentary access — so it is the one table here where "server-only" could
 * plausibly have been an oversight rather than a choice.
 *
 * It is a choice. A comp grant is an act of Eklio's, taken outside the
 * product; the person it benefits sees the access, never the grant. Reading
 * one's own row would tell a customer they are on a comp — which is Eklio's
 * business to raise, not a table's to leak. It is denied to the browser and
 * read by `comp_grant_entitlement` with the service role.
 */
drop policy if exists comp_grants_denied on public.comp_grants;
create policy comp_grants_denied on public.comp_grants
  for all using (false) with check (false);

comment on table public.comp_grants is
  'Complimentary access, granted by Eklio outside the product. Server-only by decision, not by oversight: the beneficiary sees the access, never the grant.';

do $$
declare v_silent integer;
begin
  select count(*) into v_silent
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
     and not exists (select 1 from pg_policies p
                      where p.schemaname = 'public' and p.tablename = c.relname);
  assert v_silent = 0, format('%s tables still have RLS on and no policy at all', v_silent);
end
$$;
