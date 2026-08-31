-- ============================================================================
-- Tests — 20260831106000_project_briefs_data_shape.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000301', 'owner301@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000301', 'aaaaaaaa-0000-0000-0000-000000000301', 'Fixture Practice');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000301');

-- ---------------------------------------------------------------------------
-- Direct function checks: never returns NULL, empty object is valid, unknown
-- keys tolerated (open variant), each of the eleven known keys individually
-- refuses a wrong-typed value.
-- ---------------------------------------------------------------------------
do $$
declare
  wrong record;
begin
  assert public.project_briefs_data_valid(null::jsonb) is false, 'SQL NULL must return false, not NULL';
  assert public.project_briefs_data_valid('null'::jsonb) is false, 'JSON null must return false';
  assert public.project_briefs_data_valid('[1,2,3]'::jsonb) is false,
    'a bare JSON array must be refused -- this is the hole the naive version had';
  assert public.project_briefs_data_valid('"a string"'::jsonb) is false, 'a bare JSON string must be refused';
  assert public.project_briefs_data_valid('42'::jsonb) is false, 'a bare JSON number must be refused';
  assert public.project_briefs_data_valid('true'::jsonb) is false, 'a bare JSON boolean must be refused';
  raise notice 'OK: degenerate inputs never return NULL, and non-objects are refused';

  assert public.project_briefs_data_valid('{}'::jsonb) is true,
    'FAIL: {} (the column default) was rejected -- every key is optional';
  raise notice 'OK: {} is accepted';

  assert public.project_briefs_data_valid('{"some_future_gap_fill_key": {"anything": [1,2,3]}}'::jsonb) is true,
    'FAIL: an unrecognized key caused rejection -- this must stay the OPEN variant, unlike a closed shape';
  raise notice 'OK: an unrecognized key is tolerated, whatever shape its own value takes';

  assert public.project_briefs_data_valid('{
    "stage": "starting",
    "problem_text": "p",
    "gain_text": "g",
    "builder_target": "squarespace",
    "existing_url": "example.com",
    "practitioner_name": "Nora Whitfield",
    "practitioner_line": "Nora Whitfield, LCSW",
    "suggestion_notice_seen": true,
    "selected_tone_card_id": "abc123",
    "usp_regenerate_count": 1,
    "usp_options_inputs_hash": "deadbeef"
  }'::jsonb) is true, 'FAIL: all eleven known keys, correctly typed together, were rejected';
  raise notice 'OK: all eleven known keys, correctly typed together, are accepted';

  -- ⚠ every known key, wrong type, in turn — this is the requirement a key
  -- present with the wrong type must be REFUSED.
  for wrong in select * from (values
    ('stage', '1'),
    ('problem_text', '1'),
    ('gain_text', '1'),
    ('builder_target', '1'),
    ('existing_url', '1'),
    ('practitioner_name', '1'),
    ('practitioner_line', '1'),
    ('suggestion_notice_seen', '"not-a-bool"'),
    ('selected_tone_card_id', '1'),
    ('usp_regenerate_count', '"not-a-number"'),
    ('usp_options_inputs_hash', '1')
  ) as t(k, badval)
  loop
    assert public.project_briefs_data_valid(jsonb_build_object(wrong.k, wrong.badval::jsonb)) is false,
      format('FAIL: key "%s" accepted a wrong-typed value %s', wrong.k, wrong.badval);
  end loop;
  raise notice 'OK: every one of the eleven known keys individually refuses a wrong-typed value';
end
$$;

-- ---------------------------------------------------------------------------
-- The live CHECK constraint, exercised through a real UPDATE — a wrong-typed
-- known key is refused at the table, a well-typed known key alongside an
-- unknown one is accepted.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update public.project_briefs set data = '{"usp_regenerate_count": "oops"}'::jsonb
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000301';
    raise exception 'FAIL: a wrong-typed known key reached the table via UPDATE';
  exception when check_violation then
    raise notice 'OK: project_briefs_data_shape_check rejects a wrong-typed known key at the table';
  end;

  begin
    update public.project_briefs set data = '[1,2,3]'::jsonb
    where project_id = 'bbbbbbbb-0000-0000-0000-000000000301';
    raise exception 'FAIL: a bare JSON array reached the table via UPDATE';
  exception when check_violation then
    raise notice 'OK: project_briefs_data_shape_check rejects a non-object data value at the table';
  end;

  update public.project_briefs
  set data = '{"stage": "starting", "some_future_key": {"nested": true}}'::jsonb
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000301';
  raise notice 'OK: a well-typed known key plus an unknown key is accepted at the table';

  -- the column default itself must still write cleanly
  update public.project_briefs set data = '{}'::jsonb
  where project_id = 'bbbbbbbb-0000-0000-0000-000000000301';
  raise notice 'OK: {} still writes cleanly';
end
$$;

rollback;
