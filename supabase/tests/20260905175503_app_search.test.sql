-- ============================================================================
-- Tests — 20260905175503_app_search.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000061','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000062','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000061','aaaaaaaa-0000-0000-0000-000000000061','Elm & Ember'),
  ('bbbbbbbb-0000-0000-0000-000000000062','aaaaaaaa-0000-0000-0000-000000000062','Someone Else');
-- `on_brand_kit_created` (20260827104000) already seeds every kit's
-- launch_checklist_items on insert -- including 'email_signature': "Install
-- your email signature" -- so there is nothing to insert here.
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000061','bbbbbbbb-0000-0000-0000-000000000061'),
  ('cccccccc-0000-0000-0000-000000000062','bbbbbbbb-0000-0000-0000-000000000062');

-- ---------------------------------------------------------------------------
-- Finds a catalog asset by a partial label match, and a launch step by a
-- partial label match -- case-insensitively.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000061"}';

  result := public.app_search('cccccccc-0000-0000-0000-000000000061', 'signature');

  assert jsonb_array_length(result -> 'assets') >= 1,
         format('expected at least one asset matching "signature", got: %s', result -> 'assets');
  assert exists (
    select 1 from jsonb_array_elements(result -> 'assets') a
     where a ->> 'key' = 'email_signature_png'
  ), 'expected email_signature_png among the asset results';

  -- The default seed's booking_link and first_post descriptions both
  -- mention "signature" too ("your email signature", "the signature
  -- template") -- a real, correct match on description text, not a bug.
  assert exists (
    select 1 from jsonb_array_elements(result -> 'launch_steps') s
     where s ->> 'key' = 'email_signature'
  ), format('expected the email_signature launch step among the matches, got: %s', result -> 'launch_steps');
end
$$;

-- ---------------------------------------------------------------------------
-- An empty query returns empty results rather than everything.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000061"}';

  result := public.app_search('cccccccc-0000-0000-0000-000000000061', '   ');
  assert result -> 'assets' = '[]'::jsonb, 'a blank query must not return every asset';
  assert result -> 'launch_steps' = '[]'::jsonb, 'a blank query must not return every launch step';
end
$$;

-- ---------------------------------------------------------------------------
-- Ownership: a stranger's kit id returns not_found and no data leak.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000062"}';

  result := public.app_search('cccccccc-0000-0000-0000-000000000061', 'signature');
  assert result -> 'error' ->> 'code' = 'not_found',
         format('a stranger must not search another user''s kit, got: %s', result);
end
$$;

-- ---------------------------------------------------------------------------
-- launch_steps are scoped to the p_brand_kit_id passed in: a query that
-- matches nothing in EITHER kit's descriptions (unlike "signature", which
-- every default seed's booking_link/first_post text also mentions) proves
-- the scoping without relying on the shared default seed being distinctive.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000062"}';

  result := public.app_search('cccccccc-0000-0000-0000-000000000062', 'google business');
  assert jsonb_array_length(result -> 'launch_steps') = 1,
         format('expected the stranger''s own kit to match its own google_profile step, got: %s', result -> 'launch_steps');
  assert (result -> 'launch_steps' -> 0 ->> 'key') = 'google_profile',
         'expected the stranger''s own google_profile step';
end
$$;

-- ---------------------------------------------------------------------------
-- Not callable by anon.
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('anon', 'public.app_search(uuid, text)', 'execute'),
         'app_search must not be executable by anon';
end
$$;

rollback;
