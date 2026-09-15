-- ============================================================================
-- The catalog an anonymous brief could not read
-- ============================================================================
-- ⚠ THE BUG THIS FIXES IS THE SILENT KIND THIS REPO KEEPS FINDING.
--
-- Screen 1 of the brief asks for a license type and a set of specialties. For
-- a visitor who has not signed up — the anonymous brief of
-- `20260910192157_anonymous_briefs.sql`, which is the FIRST thing a new
-- practitioner touches — both chip groups rendered EMPTY. No error, no blank
-- state, no console line: a label with nothing under it.
--
-- The cause is one clause written three weeks before the anonymous brief
-- existed. `20260827100000_catalog_reference_data.sql` created eleven catalog
-- policies as:
--
--     for select to authenticated using (true)
--
-- and `20260901074612_how_you_work_catalogs.sql` copied the idiom for four
-- more. `to authenticated` was the right call AT THE TIME and its reasoning is
-- still right: `using (true)` has none of the self-closing property that the
-- ownership predicates elsewhere in this schema have, so without the clause it
-- would publish the whole product catalog to anybody holding the anon key.
--
-- What changed is that the product grew a caller who is `anon` and is
-- nonetheless legitimately filling in a brief. To that caller a policy that
-- names only `authenticated` returns zero rows and RAISES NOTHING — the fourth
-- row of the README's table in a new costume: the default is permissive about
-- being WRONG, not about being open. PostgREST answered 200 with `[]`, the
-- frontend mapped `[]` to zero chips, and the first screen of the funnel asked
-- a question it offered no way to answer.
--
-- ⚠ THE FIX IS NOT `to anon, authenticated using (true)`. That would publish
-- the catalog to anyone with the anon key, which is exactly what the original
-- author refused, and refused for a reason that has not expired. The catalog
-- is opened to the anon caller WHO HOLDS A LIVE BRIEF — the same token, the
-- same hash comparison, the same expiry deadline as every other anonymous
-- policy. A request with no token, a guessed token, or a token whose brief has
-- expired reads the catalog exactly as it did before this migration: nothing.
--
-- One policy per table, replaced in place. NOT a second permissive policy
-- beside the old one: two permissive policies OR together, and a future reader
-- auditing one of them would be reading half the rule.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Does this request hold a live anonymous brief?
-- ---------------------------------------------------------------------------
/*
 * The sibling of `owns_project(uuid)`, asking the same question without naming
 * a row: not "is THIS project mine" but "am I anybody at all". A catalog has no
 * project to be checked against, so this is the only shape the question can
 * take here.
 *
 * ⚠ `exists` NEVER RETURNS NULL, which is the point in a schema whose recurring
 * defect is a permissive NULL. A policy predicate that evaluates to NULL denies
 * the row, so a null here would fail closed rather than open — but it would
 * fail closed INVISIBLY, which is the failure mode that produced this migration
 * in the first place. TRUE and FALSE are the only reachable answers.
 *
 * ⚠ `stable`, not `immutable`: it reads `request.headers` through
 * `anon_token_hash()`, constant within a statement and not across them.
 *
 * ⚠ `security definer` with an empty `search_path`, like every other predicate
 * helper here: the anon role reads `public.projects` only through the policy
 * this function is about to be used by, and a predicate cannot depend on the
 * predicate it defines.
 *
 * ⚠ `auth.uid() IS NULL` IS THE IN-BODY AUTHORITY CHECK, and it is not
 * decoration to satisfy `20260911170458_function_surface.test.sql`. The
 * question this function answers is "am I an ANONYMOUS visitor holding a live
 * brief", and someone with a session is not one — she is `authenticated`, she
 * is covered by the other half of the policy, and a token cookie left over on
 * her device must not be what decides what she can read. It also makes the
 * function fail closed the way the surface test demands: a SECURITY DEFINER
 * function the browser can call asks who is calling, in its body, where a
 * REVOKE that drifts cannot unask it.
 */
create or replace function public.holds_anon_brief()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select (select auth.uid()) is null
     and exists (
    select 1 from public.projects p
     where p.anon_token_hash is not null
       and p.anon_token_hash = public.anon_token_hash()
       and p.anon_expires_at > now()
  );
$function$;

/*
 * ⚠ THE FOURTH DEFAULT, REVOKED BY HAND. `anon` receives EXECUTE on every
 * function created in `public` — the README's own table records what that cost
 * once already. The grant below is deliberate, and the revoke above it is what
 * makes it deliberate rather than inherited.
 */
revoke execute on function public.holds_anon_brief() from public;
grant execute on function public.holds_anon_brief() to anon, authenticated, service_role;

comment on function public.holds_anon_brief() is
  'True when the x-anon-token on this request matches an unexpired anonymous project. The catalog policies read it; a null token matches no row, so a request without one is false.';


-- ---------------------------------------------------------------------------
-- 2. The fifteen catalog policies, rewritten in place
-- ---------------------------------------------------------------------------
/*
 * The predicate reads `current_user`, NOT `auth.uid()`.
 *
 * ⚠ THAT IS DELIBERATE, AND THE EXISTING TESTS DEPEND ON IT. `auth.uid()` is
 * null under a bare `set local role authenticated` with no JWT claims — which
 * is precisely how `20260827100000_catalog_reference_data.test.sql` and
 * `20260901074612_how_you_work_catalogs.test.sql` assert that an authenticated
 * user can read a catalog. A predicate on `auth.uid()` would turn those green
 * assertions red while changing nothing about what a browser can see.
 * `current_user` is what `to authenticated` was already testing; this writes
 * the same test explicitly so the OR can be put beside it.
 *
 * Both operands are wrapped in `(select …)` so the planner lifts them into an
 * InitPlan evaluated once per statement. Without it, `holds_anon_brief()` — a
 * query — is a candidate for evaluation per row, on tables that are read with
 * no WHERE clause at all.
 */
do $$
declare
  t text;
begin
  foreach t in array array[
    'tone_cards', 'palette_families', 'type_pairings', 'client_persona_cards',
    'problem_cards', 'gain_cards', 'ethics_rules', 'license_types',
    'specialties', 'site_goals', 'primary_actions',
    'session_style_cards', 'not_a_fit_cards', 'modality_cards',
    'modality_prominence_options'
  ]
  loop
    execute format('drop policy if exists %I on public.%I', t || '_select_all', t);
    execute format(
      'create policy %I on public.%I for select to anon, authenticated'
      || ' using ((select current_user) = ''authenticated'''
      || '        or (select public.holds_anon_brief()))',
      t || '_select_all', t);
  end loop;
end
$$;


-- ---------------------------------------------------------------------------
-- 3. Guard rails — verified, not assumed
-- ---------------------------------------------------------------------------
-- The failure this migration fixes was silent, and so is its regression: a
-- policy that drops back to `authenticated` only, and one that widens to `anon`
-- unconditionally, both look like a working catalog from the inside.

do $$
declare
  t text;
  n int;
begin
  foreach t in array array[
    'tone_cards', 'palette_families', 'type_pairings', 'client_persona_cards',
    'problem_cards', 'gain_cards', 'ethics_rules', 'license_types',
    'specialties', 'site_goals', 'primary_actions',
    'session_style_cards', 'not_a_fit_cards', 'modality_cards',
    'modality_prominence_options'
  ]
  loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'catalog_anon_read: RLS is off on %. Migration aborted.', t;
    end if;

    -- Still exactly one policy, still SELECT only. A write policy on a catalog
    -- would let a browser rewrite product copy.
    select count(*) into n from pg_policies where schemaname = 'public' and tablename = t;
    if n <> 1 then
      raise exception
        'catalog_anon_read: % has % policies, expected exactly 1 (select-only). Migration aborted.', t, n;
    end if;

    if not exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t and cmd = 'SELECT'
         and roles @> array['anon', 'authenticated']::name[]
    ) then
      raise exception
        'catalog_anon_read: the policy on % is not a SELECT policy for anon+authenticated. Migration aborted.', t;
    end if;
  end loop;
end
$$;

/*
 * And the behaviour itself, on the table the report named.
 *
 * ⚠ THE SHAPE CHECK ABOVE CANNOT SEE THE MISTAKE THAT MATTERS. `to anon,
 * authenticated using (true)` passes every assertion in it and publishes the
 * product catalog to the internet. Only a read as `anon` can tell the two
 * apart, so one is done here, against probe rows that are deleted before the
 * migration ends.
 */
do $$
declare
  n int;
begin
  insert into public.projects (id, user_id, name, anon_token_hash, anon_expires_at)
  values
    ('0e0e0e0e-0000-4000-8000-0000000000e1', null, 'catalog read probe (live)',
     encode(extensions.digest('GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGguard', 'sha256'), 'hex'),
     now() + interval '30 days'),
    ('0e0e0e0e-0000-4000-8000-0000000000e2', null, 'catalog read probe (expired)',
     encode(extensions.digest('HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHstale', 'sha256'), 'hex'),
     now() - interval '1 minute');

  set local role anon;

  -- ⚠ THE BUG. A live anonymous brief must see the license types.
  set local request.headers = '{"x-anon-token":"GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGguard"}';
  select count(*) into n from public.license_types;
  if n = 0 then
    raise exception
      'catalog_anon_read: an anonymous brief still reads 0 license_types. Migration aborted.';
  end if;

  -- ⚠ WHAT THE FIX MUST NOT BECOME. No token, no catalog.
  set local request.headers = '{}';
  select count(*) into n from public.license_types;
  if n <> 0 then
    raise exception
      'catalog_anon_read: a request with NO token read % license_types. The catalog is public. Migration aborted.', n;
  end if;

  -- An expired brief is refused before the purge runs, here as everywhere.
  set local request.headers = '{"x-anon-token":"HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHstale"}';
  select count(*) into n from public.license_types;
  if n <> 0 then
    raise exception
      'catalog_anon_read: an EXPIRED anonymous brief read % license_types. Migration aborted.', n;
  end if;

  reset role;
  set local request.headers = '{}';

  delete from public.projects
   where id in ('0e0e0e0e-0000-4000-8000-0000000000e1',
                '0e0e0e0e-0000-4000-8000-0000000000e2');
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Reverting re-breaks the anonymous brief's first screen. It is written out
-- because the alternative is archaeology, not because it should be run.
--
--   do $$
--   declare t text;
--   begin
--     foreach t in array array[
--       'tone_cards', 'palette_families', 'type_pairings', 'client_persona_cards',
--       'problem_cards', 'gain_cards', 'ethics_rules', 'license_types',
--       'specialties', 'site_goals', 'primary_actions',
--       'session_style_cards', 'not_a_fit_cards', 'modality_cards',
--       'modality_prominence_options'
--     ]
--     loop
--       execute format('drop policy if exists %I on public.%I', t || '_select_all', t);
--       execute format(
--         'create policy %I on public.%I for select to authenticated using (true)',
--         t || '_select_all', t);
--     end loop;
--   end
--   $$;
--   drop function if exists public.holds_anon_brief();
