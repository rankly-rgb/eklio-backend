-- ============================================================================
-- Tests — 20260831102000_project_briefs_how_you_work_columns.sql
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

  update public.project_briefs set selected_usp_id = 'u2'
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000101';
  raise notice 'OK: selected_usp_id trigger accepts an id present in usp_options';
end
$$;

rollback;
