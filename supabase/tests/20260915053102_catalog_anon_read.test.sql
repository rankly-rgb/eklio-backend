-- ============================================================================
-- Tests — 20260915053102_the_catalog_the_anonymous_brief_cannot_read.sql
-- ============================================================================
-- Two questions, and they pull in opposite directions:
--
--   1. Can the anonymous brief READ the catalog? It could not, and screen 1 of
--      the funnel rendered "License type" with nothing under it.
--   2. Can anyone ELSE? The original `to authenticated` clause existed to stop
--      the product catalog being served to anybody holding the anon key, and
--      that reasoning has not expired.
--
-- A fix that answers only the first is not a fix, it is a leak — and `to anon,
-- authenticated using (true)` answers only the first while passing every
-- structural assertion anybody would think to write. So the reads below are
-- performed, not inspected.
--
-- ⚠ THE TOKENS HERE ARE 43 CHARACTERS, like the real ones. A shorter one is
-- refused by `anon_token_hash()`'s own plausibility check before it reaches an
-- index, which would make this file pass for the wrong reason.
-- ============================================================================
begin;

insert into public.projects (id, user_id, name, anon_token_hash, anon_expires_at) values
  ('cafe0000-0000-4000-8000-000000000001', null, 'live',
   encode(extensions.digest('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAalice','sha256'),'hex'),
   now() + interval '30 days'),
  ('cafe0000-0000-4000-8000-000000000002', null, 'expired',
   encode(extensions.digest('CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCexpired','sha256'),'hex'),
   now() - interval '1 minute');

insert into public.project_briefs (project_id) values
  ('cafe0000-0000-4000-8000-000000000001'),
  ('cafe0000-0000-4000-8000-000000000002');


-- ---------------------------------------------------------------------------
-- 1. Every catalog table, for every caller
-- ---------------------------------------------------------------------------
/*
 * All fifteen, not just the two the bug report named. `license_types` and
 * `specialties` are what a visitor SEES first; `tone_cards`, `palette_families`
 * and `type_pairings` are what screens 5 and 6 are made of, and they would have
 * come up empty for the same caller for the same reason.
 *
 * The expected count is "the same as the migration role sees" rather than a
 * literal: the row counts are pinned by the catalog migrations' own guards, and
 * repeating them here would only add a second place to update.
 */
do $$
declare
  t text;
  v_tables text[] := array[
    'tone_cards', 'palette_families', 'type_pairings', 'client_persona_cards',
    'problem_cards', 'gain_cards', 'ethics_rules', 'license_types',
    'specialties', 'site_goals', 'primary_actions',
    'session_style_cards', 'not_a_fit_cards', 'modality_cards',
    'modality_prominence_options'
  ];
  v_all int;
  v_seen int;
begin
  foreach t in array v_tables
  loop
    execute format('select count(*) from public.%I', t) into v_all;
    assert v_all > 0, format('%s is empty; this test would pass vacuously', t);

    -- ⚠ THE BUG. A live anonymous brief must see the whole catalog.
    set local role anon;
    set local request.headers = '{"x-anon-token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAalice"}';
    execute format('select count(*) from public.%I', t) into v_seen;
    assert v_seen = v_all,
      format('an anonymous brief saw %s of %s rows in %s', v_seen, v_all, t);

    -- ⚠ THE LEAK THE FIX MUST NOT INTRODUCE. The anon key alone is not a brief.
    set local request.headers = '{}';
    execute format('select count(*) from public.%I', t) into v_seen;
    assert v_seen = 0,
      format('a request with NO token read %s rows from %s', v_seen, t);

    -- A guess is not a brief either.
    set local request.headers = '{"x-anon-token":"ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZguess"}';
    execute format('select count(*) from public.%I', t) into v_seen;
    assert v_seen = 0,
      format('a guessed token read %s rows from %s', v_seen, t);

    -- An expired brief is refused before the purge runs, here as everywhere.
    set local request.headers = '{"x-anon-token":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCexpired"}';
    execute format('select count(*) from public.%I', t) into v_seen;
    assert v_seen = 0,
      format('an expired anonymous brief read %s rows from %s', v_seen, t);

    -- And the caller who could always read it, still can — with no token at
    -- all, which is the state every signed-in browser is in.
    set local role authenticated;
    set local request.headers = '{}';
    execute format('select count(*) from public.%I', t) into v_seen;
    assert v_seen = v_all,
      format('an authenticated user saw %s of %s rows in %s', v_seen, v_all, t);

    reset role;
  end loop;

  set local request.headers = '{}';
end $$;


-- ---------------------------------------------------------------------------
-- 2. Reading is all that was opened
-- ---------------------------------------------------------------------------
/*
 * The catalog is product copy. A caller who could write it could rewrite the
 * list of credentials a practitioner is offered — so widening the read must not
 * have widened anything else, and "there is no insert policy" is checked by
 * attempting the insert rather than by reading `pg_policies`.
 */
do $$
declare
  v_refused boolean := false;
  v_n int;
begin
  set local role anon;
  set local request.headers = '{"x-anon-token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAalice"}';

  begin
    insert into public.license_types (id, sort_order, active, label, description)
    values ('forged', 999, true, 'Forged', 'not hers to write');
  exception when others then
    v_refused := true;
  end;
  assert v_refused, 'an anonymous brief inserted a license type';

  update public.license_types set label = 'Forged';
  get diagnostics v_n = row_count;
  assert v_n = 0, format('an anonymous brief updated %s license types', v_n);

  delete from public.license_types;
  get diagnostics v_n = row_count;
  assert v_n = 0, format('an anonymous brief deleted %s license types', v_n);

  reset role;
  set local request.headers = '{}';
end $$;


-- ---------------------------------------------------------------------------
-- 3. The shape of the rule
-- ---------------------------------------------------------------------------
-- Exactly one policy per table, still SELECT only. Two permissive policies OR
-- together, and a reader auditing one of them would be reading half the rule.
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
    select count(*) into n from pg_policies
     where schemaname = 'public' and tablename = t;
    assert n = 1, format('%s carries %s policies, expected exactly 1', t, n);

    assert exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t and cmd = 'SELECT'
         and roles @> array['anon', 'authenticated']::name[]
    ), format('the policy on %s is not a SELECT policy for anon+authenticated', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 4. `holds_anon_brief()` itself
-- ---------------------------------------------------------------------------
/*
 * ⚠ IT MUST NEVER RETURN NULL. A null policy predicate denies the row, so a
 * null here fails CLOSED — and an invisible closed failure is precisely the
 * defect this migration exists to undo. `exists` is what guarantees it; this
 * asserts the guarantee rather than trusting the reading.
 */
do $$
begin
  set local role anon;

  set local request.headers = '{}';
  assert public.holds_anon_brief() is not null, 'holds_anon_brief() returned null with no token';
  assert public.holds_anon_brief() = false, 'a request with no token holds a brief';

  -- Below `anon_token_hash()`'s plausibility floor: refused before any index.
  set local request.headers = '{"x-anon-token":"short"}';
  assert public.holds_anon_brief() = false, 'an implausible token holds a brief';

  set local request.headers = '{"x-anon-token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAalice"}';
  assert public.holds_anon_brief() = true, 'a live token does not hold a brief';

  set local request.headers = '{"x-anon-token":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCexpired"}';
  assert public.holds_anon_brief() = false, 'an expired token holds a brief';

  /*
   * ⚠ A SESSION IS NOT AN ANONYMOUS BRIEF, even carrying a live token. She
   * signed in; a cookie left over on the device must not be what decides what
   * she reads. The catalog still reaches her — through the other half of the
   * policy, which is the half that has always covered her.
   */
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"cafe0000-0000-4000-8000-0000000000ff"}';
  set local request.headers = '{"x-anon-token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAalice"}';
  assert public.holds_anon_brief() = false,
    'a signed-in caller carrying a token was treated as an anonymous brief';
  assert (select count(*) from public.license_types) > 0,
    'a signed-in caller carrying a token lost the catalog';

  reset role;
  reset request.jwt.claims;
  set local request.headers = '{}';
end $$;

-- The fourth default: `anon` gets EXECUTE on every function created in
-- `public`. Here that is wanted — but wanted deliberately, and the revoke in
-- the migration is what makes the grant a decision. Both roles need it: the
-- policy is evaluated as the querying role.
do $$
begin
  assert has_function_privilege('anon', 'public.holds_anon_brief()', 'execute'),
    'anon cannot execute the predicate its own policy depends on';
  assert has_function_privilege('authenticated', 'public.holds_anon_brief()', 'execute'),
    'authenticated cannot execute holds_anon_brief()';
end $$;

rollback;
