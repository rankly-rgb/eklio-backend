-- ============================================================================
-- usp_check_distinct, usp_banned_phrases_check
-- ============================================================================
-- Both SECURITY DEFINER, both with a locked search_path, for different
-- reasons -- reviewed as such below, matching the repo's convention of
-- justifying every SECURITY DEFINER at the point it's declared (see
-- `seed_site_spec` in `20260829100000_site_spec.sql` for the prior-art
-- rationale this follows).
--
-- ⚠ BOTH ARE `service_role` ONLY, NOT `authenticated`. Call them from the
-- Next.js server-side route handler using the service-role key, never by
-- forwarding the user's JWT -- the route handler itself is what checks the
-- caller owns the brief in question. Granting either to `authenticated`
-- would make it directly callable through PostgREST by any signed-in user:
--   - `usp_check_distinct` returns another practitioner's confirmed
--     statement text on collision (`conflicting_statement`). Direct access
--     turns it into a competitor-probing oracle -- try candidate USPs
--     against a scope_key and read back what's already claimed there.
--   - `usp_banned_phrases_check` becomes a phrase-testing oracle for the
--     very list it exists to enforce: probe it directly and iterate until
--     a phrasing returns zero hits, defeating gate 1 of the generation
--     pipeline before gate 2 ever runs.
-- A plain `revoke ... from public` is NOT enough on its own: `anon` and
-- `authenticated` each get their own EXECUTE grant from Supabase's default
-- privileges at function-creation time, independent of the `public`
-- pseudo-role -- both must be revoked by name.

-- ============================================================================
-- 1. usp_check_distinct
-- ============================================================================
-- SECURITY DEFINER because it necessarily reads across users: distinctness
-- is meaningless scoped to one caller's own rows. It returns ONLY the
-- boolean, the float, and the conflicting statement text -- never a user id,
-- brief id, or any other column from `usp_fingerprints` -- so a caller can
-- never learn WHO holds the colliding statement, only that one exists and
-- what it says. `conflicting_statement` must never be rendered to a user in
-- the frontend (see FRONTEND_CONTRACT.md); this function does its part by
-- not leaking anything beyond that one field.
--
-- `p_exclude_brief` lets re-saving your own confirmed statement skip
-- colliding with the fingerprint row it already wrote for itself.

create or replace function public.usp_check_distinct(
  p_scope_key     text,
  p_statement     text,
  p_exclude_brief uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_threshold        double precision;
  v_normalized       text;
  v_best_similarity  double precision;
  v_conflicting      text;
begin
  select (value #>> '{}')::double precision into v_threshold
  from public.app_settings
  where key = 'usp_similarity_threshold';

  v_threshold := coalesce(v_threshold, 0.55);
  v_normalized := public.usp_normalize(p_statement);

  select f.similarity, f.statement
  into v_best_similarity, v_conflicting
  from (
    select
      public.similarity(uf.normalized, v_normalized) as similarity,
      uf.statement
    from public.usp_fingerprints uf
    where uf.scope_key = p_scope_key
      and (p_exclude_brief is null or uf.brief_id <> p_exclude_brief)
    order by public.similarity(uf.normalized, v_normalized) desc
    limit 1
  ) as f;

  v_best_similarity := coalesce(v_best_similarity, 0);

  return jsonb_build_object(
    'distinct', v_best_similarity < v_threshold,
    'best_similarity', v_best_similarity,
    'conflicting_statement', case when v_best_similarity >= v_threshold then v_conflicting else null end
  );
end;
$function$;

revoke all on function public.usp_check_distinct(text, text, uuid) from public, anon, authenticated;
grant execute on function public.usp_check_distinct(text, text, uuid) to service_role;

-- ============================================================================
-- 2. usp_banned_phrases_check
-- ============================================================================
-- SECURITY DEFINER for a different reason than above: `banned_phrases` has
-- no policies and revoked anon/authenticated privileges (previous
-- migration), by design -- an authenticated caller cannot read it directly.
-- This function is the ONLY sanctioned path from an authenticated JWT to a
-- yes/no read of that table, and it only ever returns the phrases that
-- MATCHED, not the catalog itself.
--
-- Word-boundary matching (`\y` in Postgres's ARE regex dialect) so a banned
-- phrase is caught mid-sentence but not as a false-positive substring of an
-- unrelated word (e.g. "safe space" must not fire on "safeguarding spaces").
-- Metacharacters in a phrase are escaped before being spliced into the
-- pattern -- none of the seeded phrases contain any today, but a future
-- phrase might.

create or replace function public.usp_banned_phrases_check(p_text text)
returns text[]
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    array_agg(bp.phrase order by bp.phrase),
    array[]::text[]
  )
  from public.banned_phrases bp
  where bp.active
    and p_text ~* ('\y' || regexp_replace(bp.phrase, '([.^$*+?()\[\]{}\\|])', '\\\1', 'g') || '\y')
$function$;

revoke all on function public.usp_banned_phrases_check(text) from public, anon, authenticated;
grant execute on function public.usp_banned_phrases_check(text) to service_role;

-- DOWN
-- revoke all on function public.usp_banned_phrases_check(text) from service_role;
-- drop function if exists public.usp_banned_phrases_check(text);
-- revoke all on function public.usp_check_distinct(text, text, uuid) from service_role;
-- drop function if exists public.usp_check_distinct(text, text, uuid);
