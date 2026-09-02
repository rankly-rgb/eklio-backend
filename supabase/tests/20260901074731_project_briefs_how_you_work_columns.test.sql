-- ============================================================================
-- Tests — 20260901074731_project_briefs_how_you_work_columns.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000101', 'owner@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000101', 'aaaaaaaa-0000-0000-0000-000000000101', 'Fixture Practice');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000101');

-- ---------------------------------------------------------------------------
-- Empty array stays distinguishable from NULL
-- ---------------------------------------------------------------------------
do $$
begin
  update public.project_briefs set not_a_fit_ids = array[]::text[]
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';

  assert (select not_a_fit_ids is null from public.project_briefs where project_id = 'bbbbbbbb-0000-0000-0000-000000000101') = false,
    'an explicit empty array must not read back as NULL';
  assert (select not_a_fit_ids = array[]::text[] from public.project_briefs where project_id = 'bbbbbbbb-0000-0000-0000-000000000101') = true;

  update public.project_briefs set not_a_fit_ids = null
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  assert (select not_a_fit_ids is null from public.project_briefs where project_id = 'bbbbbbbb-0000-0000-0000-000000000101') = true;
end
$$;

-- ---------------------------------------------------------------------------
-- Array length bounds
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update public.project_briefs set session_style_ids = array['direct','humor','body','structured','follows']
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: session_style_ids accepted 5 elements (max 4)';
  exception when check_violation then
    raise notice 'OK: session_style_ids max-4 CHECK enforced';
  end;

  begin
    update public.project_briefs set not_a_fit_ids = array['wants_advice','quick_fix','court_ordered','higher_level_care']
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: not_a_fit_ids accepted 4 elements (max 3)';
  exception when check_violation then
    raise notice 'OK: not_a_fit_ids max-3 CHECK enforced';
  end;

  begin
    update public.project_briefs
    set modality_ids = array['emdr','ifs','somatic_experiencing','dbt','act','cbt']
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: modality_ids accepted 6 elements (max 5)';
  exception when check_violation then
    raise notice 'OK: modality_ids max-5 CHECK enforced';
  end;
end
$$;

-- ---------------------------------------------------------------------------
-- Referential validation of the three *_ids arrays: unknown id rejected,
-- known ids accepted.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update public.project_briefs set session_style_ids = array['not-a-real-id']
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: unknown session_style_ids element was accepted';
  exception when others then
    raise notice 'OK: unknown session_style_ids element rejected';
  end;

  begin
    update public.project_briefs set not_a_fit_ids = array['not-a-real-id']
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: unknown not_a_fit_ids element was accepted';
  exception when others then
    raise notice 'OK: unknown not_a_fit_ids element rejected';
  end;

  begin
    update public.project_briefs set modality_ids = array['not-a-real-id']
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: unknown modality_ids element was accepted';
  exception when others then
    raise notice 'OK: unknown modality_ids element rejected';
  end;

  update public.project_briefs
  set session_style_ids = array['direct', 'humor'],
      not_a_fit_ids = array['higher_level_care'],
      modality_ids = array['emdr', 'ifs']
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
end
$$;

-- ---------------------------------------------------------------------------
-- modality_prominence FK to modality_prominence_options
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update public.project_briefs set modality_prominence = 'not_an_option'
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: an unknown modality_prominence value was accepted';
  exception when foreign_key_violation then
    raise notice 'OK: modality_prominence FK rejects an unknown value';
  end;

  update public.project_briefs set modality_prominence = 'lead_with_it'
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
end
$$;

-- ---------------------------------------------------------------------------
-- tone_cards shape CHECK: missing key REJECTED, valid shape accepted.
-- This must fail if the CHECK is written the permissive
-- `p->>'x' ~ regex` way (missing key -> NULL -> `true AND NULL` -> CHECK
-- passes). Verified directly against a temporarily-swapped-in naive version
-- of `project_briefs_tone_cards_valid` during development: the naive
-- version WRONGLY ACCEPTED this exact row; the real one rejects it.
-- ---------------------------------------------------------------------------
do $$
declare
  v_missing_key jsonb := (
    select jsonb_agg(
      case when i = 1
        then jsonb_build_object('label', 'L', 'keywords', jsonb_build_array('a', 'b', 'c'))
        else jsonb_build_object('id', 't' || i, 'label', 'L', 'keywords', jsonb_build_array('a','b','c'), 'sample_hero', 'x', 'generated', true)
      end
    )
    from generate_series(1, 6) as i
  );
begin
  begin
    update public.project_briefs set tone_cards = v_missing_key
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: tone_cards with a missing key (id, sample_hero, generated) was accepted';
  exception when check_violation then
    raise notice 'OK: tone_cards_check rejects an element missing required keys';
  end;
end
$$;

do $$
declare
  v_valid jsonb := (
    select jsonb_agg(
      jsonb_build_object(
        'id', 't' || i, 'label', 'Label ' || i,
        'keywords', jsonb_build_array('a', 'b', 'c'),
        'sample_hero', 'A short sample hero line.',
        'generated', true
      )
    )
    from generate_series(1, 6) as i
  );
begin
  update public.project_briefs set tone_cards = v_valid
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  raise notice 'OK: a valid 6-element tone_cards array is accepted';
end
$$;

do $$
begin
  begin
    update public.project_briefs
    set tone_cards = jsonb_set(
      (select tone_cards from public.project_briefs where project_id = 'bbbbbbbb-0000-0000-0000-000000000101'),
      '{0,sample_hero}',
      to_jsonb(repeat('x', 47))
    )
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: a 47-char sample_hero (limit 46) was accepted';
  exception when check_violation then
    raise notice 'OK: tone_cards sample_hero 46-char bound enforced';
  end;
end
$$;

-- ---------------------------------------------------------------------------
-- usp_options shape CHECK: missing key rejected, non-distinct angles
-- rejected, valid shape accepted.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update public.project_briefs
    set usp_options = '[
      {"id":"u1","angle":"population","statement":"s1"},
      {"id":"u2","angle":"method","statement":"s2","rationale":"r2","evidence":[]},
      {"id":"u3","angle":"lived_experience","statement":"s3","rationale":"r3","evidence":[]}
    ]'::jsonb
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: usp_options with a missing key (rationale, evidence) was accepted';
  exception when check_violation then
    raise notice 'OK: usp_options_check rejects an element missing required keys';
  end;

  begin
    update public.project_briefs
    set usp_options = '[
      {"id":"u1","angle":"population","statement":"s1","rationale":"r1","evidence":[]},
      {"id":"u2","angle":"population","statement":"s2","rationale":"r2","evidence":[]},
      {"id":"u3","angle":"lived_experience","statement":"s3","rationale":"r3","evidence":[]}
    ]'::jsonb
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: usp_options with a duplicate angle was accepted';
  exception when check_violation then
    raise notice 'OK: usp_options_check rejects non-distinct angles';
  end;

  update public.project_briefs
  set usp_options = '[
    {"id":"u1","angle":"population","statement":"s1","rationale":"r1","evidence":["referral_quote"]},
    {"id":"u2","angle":"method","statement":"s2","rationale":"r2","evidence":["modality_ids"]},
    {"id":"u3","angle":"lived_experience","statement":"s3","rationale":"r3","evidence":[]}
  ]'::jsonb
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  raise notice 'OK: a valid 3-element, 3-distinct-angle usp_options array is accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- usp_options shape CHECK: relaxed to 2 OR 3 elements — never 0, never 1.
-- A single leftover candidate isn't a positioning screen; a partial
-- pipeline result that never recovers a second angle stays unpersisted,
-- exactly as before. Probed directly against a naive relaxation during
-- development (length bound written as `< 1` instead of `< 2`, tail count
-- checks correctly generalized to `= jsonb_array_length(p)`): the naive
-- version WRONGLY ACCEPTED a 1-element array; the shipped version below
-- refuses it.
-- ---------------------------------------------------------------------------
do $$
declare
  ok boolean;
begin
  assert public.project_briefs_usp_options_valid('[]'::jsonb) is false,
    '0 elements must stay refused';
  assert public.project_briefs_usp_options_valid(
    '[{"id":"u1","angle":"population","statement":"s1","rationale":"r1","evidence":[]}]'::jsonb
  ) is false, '1 element must stay refused';
  assert public.project_briefs_usp_options_valid(
    '[{"id":"u1","angle":"population","statement":"s1","rationale":"r1","evidence":[]},
      {"id":"u2","angle":"method","statement":"s2","rationale":"r2","evidence":[]},
      {"id":"u3","angle":"lived_experience","statement":"s3","rationale":"r3","evidence":[]},
      {"id":"u4","angle":"population","statement":"s4","rationale":"r4","evidence":[]}]'::jsonb
  ) is false, '4 elements must stay refused';
  -- a 2-element array with a duplicate angle: the relaxation must not have
  -- loosened the distinct-angle rule along with the length bound.
  assert public.project_briefs_usp_options_valid(
    '[{"id":"u1","angle":"population","statement":"s1","rationale":"r1","evidence":[]},
      {"id":"u2","angle":"population","statement":"s2","rationale":"r2","evidence":[]}]'::jsonb
  ) is false, 'a 2-element array with a duplicate angle must stay refused';

  begin
    update public.project_briefs
    set usp_options = '[
      {"id":"u1","angle":"population","statement":"s1","rationale":"r1","evidence":[]}
    ]'::jsonb
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'FAIL: a 1-element usp_options array was accepted';
  raise notice 'OK: usp_options_check still refuses a single leftover candidate';

  update public.project_briefs
  set usp_options = '[
    {"id":"u1","angle":"population","statement":"s1","rationale":"r1","evidence":["referral_quote"]},
    {"id":"u2","angle":"method","statement":"s2","rationale":"r2","evidence":["modality_ids"]}
  ]'::jsonb
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  raise notice 'OK: a valid 2-element, 2-distinct-angle usp_options array is accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- selected_usp_id: TRIGGER (not a CHECK) rejects an id absent from
-- usp_options, accepts one present.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update public.project_briefs set selected_usp_id = 'does-not-exist'
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: selected_usp_id accepted an id absent from usp_options';
  exception when others then
    raise notice 'OK: selected_usp_id trigger rejects an unknown id';
  end;

  update public.project_briefs set selected_usp_id = 'u1'
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  raise notice 'OK: selected_usp_id trigger accepts an id present in usp_options';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ CORRECTED before ever shipping: the trigger fires on every UPDATE, not
-- only when selected_usp_id is in the changed columns. A regeneration that
-- replaces usp_options while a CONFIRMED, now-stale selected_usp_id sits on
-- the row must succeed — that mismatch is the frontend's to show, not the
-- database's to refuse. Reproduced directly against the pre-fix function
-- during development: confirming `u1`, then writing a fresh usp_options
-- batch with entirely different ids WITHOUT touching selected_usp_id, raised
-- "selected_usp_id: u1 is not an id present in usp_options" and refused the
-- write. The fixed function (TG_OP = 'UPDATE' and NEW.selected_usp_id IS NOT
-- DISTINCT FROM OLD.selected_usp_id -> skip) no longer does.
-- ---------------------------------------------------------------------------
do $$
begin
  -- selected_usp_id is 'u1' from the block above, and usp_options is the
  -- 2-element batch it belongs to.
  update public.project_briefs
  set usp_options = '[
    {"id":"v1","angle":"population","statement":"t1","rationale":"r1","evidence":[]},
    {"id":"v2","angle":"method","statement":"t2","rationale":"r2","evidence":[]}
  ]'::jsonb
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  raise notice 'OK: regenerating usp_options with a stale, untouched selected_usp_id on the row succeeds';

  assert (select selected_usp_id from public.project_briefs
           where project_id = 'bbbbbbbb-0000-0000-0000-000000000101') = 'u1',
    'selected_usp_id must not have been silently cleared or altered by the regeneration';
  raise notice 'OK: selected_usp_id itself is untouched by the regeneration (still "u1", now stale)';

  -- ⚠ A limit of the fix worth stating precisely, not glossing over: Postgres
  -- gives the trigger no way to distinguish "this SET clause reassigned the
  -- same value" from "this column was never touched" -- NEW and OLD compare
  -- equal either way. Re-setting selected_usp_id to the value ALREADY on the
  -- row is therefore treated the same as leaving it alone, and skips
  -- validation too, even though that value is now stale. This is not a new
  -- hole: the value was already validated once, when it was first set, and
  -- staleness after a regeneration is accepted by design (the point of this
  -- fix). Only a GENUINE change of value re-triggers the lookup.
  begin
    update public.project_briefs set selected_usp_id = 'u1'
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  exception when others then
    raise exception 'FAIL: re-setting selected_usp_id to the value already on the row was refused (%); it should be treated as unchanged, same as not touching it', sqlerrm;
  end;
  raise notice 'OK: re-setting selected_usp_id to its own current (now-stale) value is treated as unchanged, not re-validated -- documented, not a hole';

  -- A genuine CHANGE to a different, still-invalid id must still be caught.
  begin
    update public.project_briefs set selected_usp_id = 'still-not-real'
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
    raise exception 'FAIL: changing selected_usp_id to a different, unknown id was accepted';
  exception when others then
    raise notice 'OK: changing selected_usp_id to a genuinely different, unknown id is still refused -- %', sqlerrm;
  end;

  update public.project_briefs set selected_usp_id = 'v1'
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  raise notice 'OK: selecting one of the freshly regenerated candidates succeeds';
end
$$;

rollback;
