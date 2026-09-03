-- ============================================================================
-- Tests — 20260903260000_launch_checklist_first_week.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000011','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000012','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000011','aaaaaaaa-0000-0000-0000-000000000011','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000011','bbbbbbbb-0000-0000-0000-000000000011');

-- ---------------------------------------------------------------------------
-- A fresh kit gets all eight items: choose_direction plus the seven
-- "Your first week" steps, in the brief's order and wording.
-- ---------------------------------------------------------------------------
do $$
declare
  expected text[][] := array[
    ['0','choose_direction',  'Choose your creative direction'],
    ['1','site_setup',        'Put your brand on your site'],
    ['2','update_directory',  'Update your Psychology Today profile'],
    ['3','google_profile',    'Claim or update your Google Business Profile'],
    ['4','social_setup',      'Set up Instagram and Facebook'],
    ['5','email_signature',   'Install your email signature'],
    ['6','booking_link',      'Put your booking link everywhere'],
    ['7','first_post',        'Publish your first post']
  ];
  i int;
  r record;
begin
  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000011') = 8,
         'kit creation must seed exactly eight checklist items';

  for i in 1 .. array_length(expected, 1) loop
    select * into r from public.launch_checklist_items
     where brand_kit_id='cccccccc-0000-0000-0000-000000000011'
       and key = expected[i][2];
    assert r.key is not null,                  format('checklist item %s is missing', expected[i][2]);
    assert r.label      = expected[i][3],      format('checklist label %s drifted from the brief', expected[i][2]);
    assert r.sort_order = expected[i][1]::int, format('checklist item %s is in the wrong position', expected[i][2]);
  end loop;

  assert not exists (
    select 1 from public.launch_checklist_items
     where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key = 'paste_site_prompt'
  ), 'the retired paste_site_prompt key must not be seeded';
end
$$;

-- ---------------------------------------------------------------------------
-- Idempotence: re-seeding never duplicates, and never resets progress
-- ---------------------------------------------------------------------------
do $$
declare
  first_done timestamptz;
begin
  update public.launch_checklist_items set done_at = now()
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='site_setup';
  select done_at into first_done from public.launch_checklist_items
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='site_setup';

  assert public.seed_launch_checklist('cccccccc-0000-0000-0000-000000000011') = 0,
         're-seeding must insert nothing';
  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000011') = 8,
         're-seeding produced duplicates';
  assert (select done_at from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='site_setup') = first_done,
         're-seeding wiped progress the user had already made';

  -- reset for the sections below
  update public.launch_checklist_items set done_at = null
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='site_setup';
end
$$;

-- ---------------------------------------------------------------------------
-- get_launch_progress: seven steps, choose_direction excluded, correct shape
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000011"}';

  result := public.get_launch_progress('cccccccc-0000-0000-0000-000000000011');
  assert result -> 'error' is null, format('get_launch_progress errored: %s', result);
  assert jsonb_array_length(result -> 'items') = 7,
         'get_launch_progress must list the seven "Your first week" steps, not choose_direction';
  assert (result ->> 'total')::int = 7, 'total must exclude choose_direction';
  assert (result ->> 'resolved_count')::int = 0, 'a fresh kit must have nothing resolved yet';
  assert not exists (
    select 1 from jsonb_array_elements(result -> 'items') e where e ->> 'key' = 'choose_direction'
  ), 'choose_direction leaked into "Your first week"';
  assert (
    select e ->> 'status' from jsonb_array_elements(result -> 'items') e where e ->> 'key' = 'site_setup'
  ) = 'todo', 'an unresolved step must report status todo';

  -- a stranger, or a kit that is not theirs, gets an error, not someone else''s data
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000012"}';
  result := public.get_launch_progress('cccccccc-0000-0000-0000-000000000011');
  assert result -> 'error' ->> 'code' = 'not_found',
         'a stranger must not be able to read another user''s launch progress';
end
$$;

-- ---------------------------------------------------------------------------
-- set_launch_step: done / skipped / todo, mutual exclusivity, ownership,
-- and choose_direction is off-limits (it is not one of the seven).
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
  row_now record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000011"}';

  result := public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'social_setup', 'done');
  assert (result ->> 'ok')::boolean, format('set_launch_step done failed: %s', result);
  select * into row_now from public.launch_checklist_items
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='social_setup';
  assert row_now.done_at is not null, 'social_setup must be marked done';
  assert row_now.skipped_at is null, 'done must clear skipped_at';

  result := public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'booking_link', 'skipped');
  assert (result ->> 'ok')::boolean, format('set_launch_step skipped failed: %s', result);
  select * into row_now from public.launch_checklist_items
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='booking_link';
  assert row_now.skipped_at is not null, 'booking_link must be marked skipped';
  assert row_now.done_at is null, 'skipped must clear done_at';

  -- flipping done -> skipped moves it cleanly, no leftover done_at
  result := public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'social_setup', 'skipped');
  select * into row_now from public.launch_checklist_items
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='social_setup';
  assert row_now.done_at is null and row_now.skipped_at is not null,
         'switching a step from done to skipped left both timestamps set';

  -- back to todo clears both
  result := public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'social_setup', 'todo');
  select * into row_now from public.launch_checklist_items
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='social_setup';
  assert row_now.done_at is null and row_now.skipped_at is null,
         'todo must clear both done_at and skipped_at';

  -- re-marking done does not move an already-earned timestamp
  perform public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'first_post', 'done');
  select done_at into row_now from public.launch_checklist_items
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='first_post';
  perform pg_sleep(0.01);
  perform public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'first_post', 'done');
  assert (select done_at from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='first_post') = row_now.done_at,
         're-marking an already-done step moved its timestamp';

  -- choose_direction is not one of the seven; it must be refused here
  result := public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'choose_direction', 'done');
  assert result -> 'error' ->> 'code' = 'not_found',
         'set_launch_step must refuse choose_direction — it is not part of "Your first week"';

  -- an invalid status is rejected
  result := public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'site_setup', 'whatever');
  assert result -> 'error' ->> 'code' = 'invalid_format',
         'set_launch_step must reject an unrecognized status';

  -- a stranger cannot touch another user''s checklist
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000012"}';
  result := public.set_launch_step('cccccccc-0000-0000-0000-000000000011', 'site_setup', 'done');
  assert result -> 'error' ->> 'code' = 'not_found',
         'a stranger was able to modify another user''s launch checklist';
end
$$;

-- ---------------------------------------------------------------------------
-- Column grants: done_at stays directly writable (the existing home-screen
-- toggle keeps working); skipped_at is not — only set_launch_step writes it.
-- ---------------------------------------------------------------------------
do $$
declare
  blocked boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000011"}';

  update public.launch_checklist_items set done_at = now()
   where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='email_signature';

  begin
    update public.launch_checklist_items set skipped_at = now()
     where brand_kit_id='cccccccc-0000-0000-0000-000000000011' and key='update_directory';
    blocked := false;
  exception when insufficient_privilege then blocked := true; end;
  assert blocked, 'an authenticated user could write skipped_at directly, bypassing set_launch_step';
end
$$;

-- ---------------------------------------------------------------------------
-- Neither seed_launch_checklist nor the internal helpers are callable by
-- anon — the same guard the revoke-surface migration checks for.
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('anon', 'public.seed_launch_checklist(uuid)', 'execute'),
         'seed_launch_checklist must not be executable by anon';
  assert not has_function_privilege('anon', 'public.get_launch_progress(uuid)', 'execute'),
         'get_launch_progress must not be executable by anon';
  assert not has_function_privilege('anon', 'public.set_launch_step(uuid,text,text)', 'execute'),
         'set_launch_step must not be executable by anon';
  assert has_function_privilege('authenticated', 'public.get_launch_progress(uuid)', 'execute'),
         'get_launch_progress must be executable by authenticated';
  assert has_function_privilege('authenticated', 'public.set_launch_step(uuid,text,text)', 'execute'),
         'set_launch_step must be executable by authenticated';
end
$$;

rollback;
