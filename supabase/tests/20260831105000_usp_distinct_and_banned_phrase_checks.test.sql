-- ============================================================================
-- Tests — 20260831105000_usp_distinct_and_banned_phrase_checks.sql
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Both functions are service_role ONLY. `authenticated` must be refused
-- outright -- calling either directly through PostgREST must not be
-- possible, or usp_check_distinct becomes a competitor-probing oracle and
-- usp_banned_phrases_check becomes a phrase-testing oracle for gate 1.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
begin
  begin
    perform public.usp_banned_phrases_check('a safe space');
    raise exception 'FAIL: authenticated could call usp_banned_phrases_check directly';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated blocked from usp_banned_phrases_check';
  end;

  begin
    perform public.usp_check_distinct('trauma:or', 'anything');
    raise exception 'FAIL: authenticated could call usp_check_distinct directly';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated blocked from usp_check_distinct';
  end;
end
$$;

reset role;

-- ---------------------------------------------------------------------------
-- usp_banned_phrases_check as service_role (how the route handler actually
-- calls it): mid-sentence, case-insensitive, no false substring positive.
-- ---------------------------------------------------------------------------
set local role service_role;

do $$
declare v_hits text[];
begin
  v_hits := public.usp_banned_phrases_check('This is a SAFE SPACE for everyone to heal.');
  assert 'safe space' = any(v_hits), format('expected safe space in %s', v_hits);

  v_hits := public.usp_banned_phrases_check('We prioritize safeguarding spaces for growth.');
  assert not ('safe space' = any(v_hits)), format('false positive substring match: %s', v_hits);

  v_hits := public.usp_banned_phrases_check('A calm, ordinary Tuesday afternoon session.');
  assert v_hits = array[]::text[], format('expected no hits, got %s', v_hits);
end
$$;

reset role;

-- ---------------------------------------------------------------------------
-- usp_check_distinct as service_role: empty scope, collision, exclusion,
-- scope isolation, and the no-leak shape of the return payload.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000401', 'owner@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000401', 'aaaaaaaa-0000-0000-0000-000000000401', 'Owner Practice');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000401');

set local role service_role;

do $$
declare v_result jsonb;
begin
  v_result := public.usp_check_distinct('brand_new_scope:us', 'A completely fresh statement');
  assert (v_result->>'distinct')::boolean = true;
  assert (v_result->>'best_similarity')::float = 0;
  assert v_result->'conflicting_statement' = 'null'::jsonb;
end
$$;

reset role;

-- Written directly here (not through usp_fingerprint_confirm) since this
-- file is about usp_check_distinct's own read-side behavior; the write
-- path itself is covered in 20260831104000's test file.
insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized) values
  ('aaaaaaaa-0000-0000-0000-000000000401', 'bbbbbbbb-0000-0000-0000-000000000401', 'trauma:or',
   'I work with first responders carrying trauma from the job',
   public.usp_normalize('I work with first responders carrying trauma from the job'));

set local role service_role;

do $$
declare v_result jsonb;
begin
  v_result := public.usp_check_distinct('trauma:or', 'I work with first responders, carrying trauma from the job.');
  assert (v_result->>'distinct')::boolean = false, format('expected collision, got %s', v_result);
  assert v_result->>'conflicting_statement' = 'I work with first responders carrying trauma from the job';
  -- Never leaks the owning user_id or brief_id -- only the three documented keys.
  assert (select array_agg(k order by k) from jsonb_object_keys(v_result) as k) = array['best_similarity','conflicting_statement','distinct'];

  v_result := public.usp_check_distinct('trauma:or', 'I specialize in EMDR for new parents navigating postpartum anxiety');
  assert (v_result->>'distinct')::boolean = true, format('expected distinct, got %s', v_result);

  v_result := public.usp_check_distinct('trauma:or', 'I work with first responders, carrying trauma from the job.', 'bbbbbbbb-0000-0000-0000-000000000401'::uuid);
  assert (v_result->>'distinct')::boolean = true, 'p_exclude_brief must let re-saving your own statement skip colliding with itself';

  v_result := public.usp_check_distinct('anxiety:ca', 'I work with first responders, carrying trauma from the job.');
  assert (v_result->>'distinct')::boolean = true, 'the same statement in a different scope_key must not collide';
end
$$;

reset role;

-- ---------------------------------------------------------------------------
-- Threshold is READ from app_settings, not hardcoded. Same pair collides
-- at the seeded 0.55, stops colliding once the threshold is raised to
-- 0.99, and collides again once restored.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000402', 'threshold@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000402', 'aaaaaaaa-0000-0000-0000-000000000402', 'Threshold Practice');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000402');
insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized) values
  ('aaaaaaaa-0000-0000-0000-000000000402', 'bbbbbbbb-0000-0000-0000-000000000402', 'threshold_test:us',
   'I run trauma-focused sessions for new parents adjusting to a changed identity',
   public.usp_normalize('I run trauma-focused sessions for new parents adjusting to a changed identity'));

do $$
declare
  v_seeded    jsonb;
  v_candidate text := 'I run identity-focused sessions for new parents adjusting after a trauma';
  v_at_055    jsonb;
  v_at_099    jsonb;
  v_restored  jsonb;
begin
  assert (select value from public.app_settings where key = 'usp_similarity_threshold') = '0.55'::jsonb,
    'usp_similarity_threshold must still be seeded at 0.55 going into this test';

  set local role service_role;
  v_at_055 := public.usp_check_distinct('threshold_test:us', v_candidate);
  reset role;

  assert (v_at_055->>'best_similarity')::float > 0 and (v_at_055->>'best_similarity')::float < 1,
    format('candidate must be a partial, non-trivial match, got best_similarity=%s -- pick a different candidate pair', v_at_055->>'best_similarity');

  -- Raise the threshold above this pair's similarity -- must STOP colliding.
  update public.app_settings set value = '0.99' where key = 'usp_similarity_threshold';

  set local role service_role;
  v_at_099 := public.usp_check_distinct('threshold_test:us', v_candidate);
  reset role;

  assert (v_at_099->>'distinct')::boolean = true,
    format('raising the threshold to 0.99 must stop this pair from colliding (best_similarity=%s); if this fails, the threshold may be hardcoded rather than read from app_settings', v_at_099->>'best_similarity');

  -- Restore, and confirm it collides again -- proves the READ, not just a
  -- one-way effect.
  update public.app_settings set value = '0.55' where key = 'usp_similarity_threshold';

  set local role service_role;
  v_restored := public.usp_check_distinct('threshold_test:us', v_candidate);
  reset role;

  assert (v_restored->>'distinct')::boolean = false,
    'restoring the threshold to 0.55 must make the same pair collide again -- confirms usp_check_distinct actually reads app_settings on every call, not a cached/hardcoded value';

  raise notice 'OK: threshold genuinely read from app_settings (best_similarity=%, collides at 0.55, not at 0.99)', v_at_055->>'best_similarity';
end
$$;

-- ---------------------------------------------------------------------------
-- Boundary test: a pair engineered to sit near 0.55 in EACH direction, not
-- similarity=1 or obviously-distinct like every other test in this file.
-- Same base statement, two variants -- confirmed with pg_trgm's own
-- similarity() during development to land at 0.5486 (just below 0.55, must
-- NOT collide) and 0.5782 (just above 0.55, must collide).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000403', 'boundary@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000403', 'aaaaaaaa-0000-0000-0000-000000000403', 'Boundary Practice');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000403');
insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized) values
  ('aaaaaaaa-0000-0000-0000-000000000403', 'bbbbbbbb-0000-0000-0000-000000000403', 'boundary_test:us',
   'I work with new parents who are exhausted, overwhelmed, and grieving the identity they had before the baby arrived, using EMDR to process the losses underneath the fatigue',
   public.usp_normalize('I work with new parents who are exhausted, overwhelmed, and grieving the identity they had before the baby arrived, using EMDR to process the losses underneath the fatigue'));

do $$
declare
  v_below jsonb;
  v_above jsonb;
begin
  set local role service_role;
  v_below := public.usp_check_distinct('boundary_test:us',
    'I work with new parents who are exhausted, overwhelmed, and mourning the identity they had before the baby came, using EMDR to work through what sits underneath the tiredness');
  v_above := public.usp_check_distinct('boundary_test:us',
    'I work with new parents navigating exhaustion, overwhelm, and a changed sense of identity since the baby arrived, using talk therapy to process what is underneath the fatigue');
  reset role;

  assert (v_below->>'best_similarity')::float between 0.53 and 0.55,
    format('expected the "below" candidate to land just under the 0.55 threshold, got %s', v_below->>'best_similarity');
  assert (v_below->>'distinct')::boolean = true,
    format('a candidate just BELOW the threshold must be distinct: %s', v_below);

  assert (v_above->>'best_similarity')::float between 0.55 and 0.60,
    format('expected the "above" candidate to land just over the 0.55 threshold, got %s', v_above->>'best_similarity');
  assert (v_above->>'distinct')::boolean = false,
    format('a candidate just ABOVE the threshold must collide: %s', v_above);

  raise notice 'OK: boundary region exercised -- below=% (distinct), above=% (collides)',
    v_below->>'best_similarity', v_above->>'best_similarity';
end
$$;

rollback;
