-- ============================================================================
-- Tests — 20260831105000_usp_distinct_and_banned_phrase_checks.sql
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- usp_banned_phrases_check: mid-sentence, case-insensitive, no false
-- substring positive.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- usp_check_distinct: SECURITY DEFINER lets an authenticated user call it
-- (banned_phrases-style privilege lockdown does not apply to this function's
-- own grant); empty scope, collision, exclusion, and scope isolation.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000401', 'owner@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000401', 'aaaaaaaa-0000-0000-0000-000000000401', 'Owner Practice');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000401');

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000401"}';

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

insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized) values
  ('aaaaaaaa-0000-0000-0000-000000000401', 'bbbbbbbb-0000-0000-0000-000000000401', 'trauma:or',
   'I work with first responders carrying trauma from the job',
   public.usp_normalize('I work with first responders carrying trauma from the job'));

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000401"}';

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
rollback;
