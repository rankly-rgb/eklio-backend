-- ============================================================================
-- Tests — 20260910192157_anonymous_briefs.sql
-- ============================================================================
-- One question above all others: can one token read another's brief?
--
-- Everything else in this feature is a convenience. That one is the reason a
-- stranger's answers about her practice, her clients and how she works can sit
-- in a table with no account attached to them.
--
-- ⚠ THE TOKENS HERE ARE 43 CHARACTERS, like the real ones. A shorter one is
-- refused by `anon_token_hash()`'s own plausibility check before it reaches an
-- index — which is correct, and which made the first draft of this file pass
-- for the wrong reason.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000a001','owner@example.com');

insert into public.projects (id, user_id, name, anon_token_hash, anon_expires_at) values
  ('bbbbbbbb-0000-0000-0000-0000000000a1', null, 'A',
   encode(extensions.digest('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAalice','sha256'),'hex'), now() + interval '30 days'),
  ('bbbbbbbb-0000-0000-0000-0000000000b1', null, 'B',
   encode(extensions.digest('BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBbob','sha256'),'hex'), now() + interval '30 days'),
  ('bbbbbbbb-0000-0000-0000-0000000000c1', null, 'C',
   encode(extensions.digest('CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCexpired','sha256'),'hex'), now() - interval '1 minute'),
  ('bbbbbbbb-0000-0000-0000-0000000000d1', 'aaaaaaaa-0000-0000-0000-00000000a001', 'D', null, null);

insert into public.project_briefs (project_id) values
  ('bbbbbbbb-0000-0000-0000-0000000000a1'),('bbbbbbbb-0000-0000-0000-0000000000b1'),
  ('bbbbbbbb-0000-0000-0000-0000000000c1'),('bbbbbbbb-0000-0000-0000-0000000000d1');

-- ---------------------------------------------------------------------------
-- 1. Isolation
-- ---------------------------------------------------------------------------
do $$
declare v_n integer; v_refused boolean;
begin
  set local role anon;

  -- Her token sees exactly one project and exactly one brief: hers.
  set local request.headers = '{"x-anon-token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAalice"}';
  select count(*) into v_n from public.projects;
  assert v_n = 1, format('alice saw %s projects', v_n);
  assert (select name from public.projects) = 'A', 'alice saw the wrong project';
  select count(*) into v_n from public.project_briefs;
  assert v_n = 1, format('alice saw %s briefs', v_n);

  -- ⚠ THE ONE THAT MATTERS. Naming the row by id changes nothing.
  set local request.headers = '{"x-anon-token":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBbob"}';
  select count(*) into v_n from public.projects
   where id = 'bbbbbbbb-0000-0000-0000-0000000000a1';
  assert v_n = 0, 'bob read alice''s project';
  select count(*) into v_n from public.project_briefs
   where project_id = 'bbbbbbbb-0000-0000-0000-0000000000a1';
  assert v_n = 0, 'bob read alice''s brief';

  -- …and cannot write it either.
  update public.project_briefs set progress_step = 7
   where project_id = 'bbbbbbbb-0000-0000-0000-0000000000a1';
  get diagnostics v_n = row_count;
  assert v_n = 0, 'bob wrote alice''s brief';

  -- 2. No token sees NOTHING. Null matches no row -- not every row whose hash
  --    is also null, which is what a naive `= anon_token_hash()` would do to
  --    every claimed project in the table.
  set local request.headers = '{}';
  select count(*) into v_n from public.projects;
  assert v_n = 0, format('a request with no token saw %s projects', v_n);

  -- 3. An expired brief is refused BEFORE the purge runs. The deadline lives
  --    in the policy; the cron is housekeeping, and a cron that fails to run
  --    must not quietly extend anyone's access.
  set local request.headers = '{"x-anon-token":"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCexpired"}';
  select count(*) into v_n from public.projects;
  assert v_n = 0, 'an expired anonymous brief was still readable';

  -- 4. A guessed token matches nothing.
  set local request.headers = '{"x-anon-token":"ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZguess"}';
  select count(*) into v_n from public.projects;
  assert v_n = 0, 'a guessed token matched something';

  -- 5. ⚠ CLAIMING FROM THE BROWSER IS REFUSED OUTRIGHT. A WITH CHECK violation
  --    raises 42501 rather than updating zero rows -- the stronger of the two,
  --    and worth pinning as the behaviour rather than the accident.
  set local request.headers = '{"x-anon-token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAalice"}';
  v_refused := false;
  begin
    update public.projects set user_id = 'aaaaaaaa-0000-0000-0000-00000000a001'
     where id = 'bbbbbbbb-0000-0000-0000-0000000000a1';
  exception when insufficient_privilege then v_refused := true;
  end;
  assert v_refused, 'a token holder claimed a brief from the browser';

  -- …nor hand it to a stranger.
  v_refused := false;
  begin
    update public.projects
       set anon_token_hash = encode(extensions.digest('BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBbob','sha256'),'hex')
     where id = 'bbbbbbbb-0000-0000-0000-0000000000a1';
  exception when insufficient_privilege then v_refused := true;
  end;
  assert v_refused, 'a token holder gave her brief to another token';

  -- 6. But she can write her own brief, which is the entire point.
  update public.project_briefs set progress_step = 3
   where project_id = 'bbbbbbbb-0000-0000-0000-0000000000a1';
  get diagnostics v_n = row_count;
  assert v_n = 1, 'alice could not write her own brief';

  reset role;
end $$;

-- ---------------------------------------------------------------------------
-- 7. The caps
-- ---------------------------------------------------------------------------
update public.app_settings set value = '2'::jsonb where key = 'anon_generation_daily_per_ip';
update public.app_settings set value = '3'::jsonb where key = 'anon_generation_daily_global';

do $$
declare r jsonb; v_global integer;
begin
  r := public.consume_anon_generation('ip_one'); assert (r->>'ok')::boolean, format('1: %s', r);
  r := public.consume_anon_generation('ip_one'); assert (r->>'ok')::boolean, format('2: %s', r);
  r := public.consume_anon_generation('ip_one');
  assert not (r->>'ok')::boolean and r->>'reason' = 'ip_cap', format('3: %s', r);

  -- ⚠ THE REFUSED ATTEMPT GAVE THE GLOBAL COUNT BACK. Without it, one visitor
  --   refreshing a page eats the day's ceiling for everyone else.
  select used into v_global from public.anon_generation_counters
   where day = (now() at time zone 'utc')::date and bucket = '@global';
  assert v_global = 2, format('global should still be 2, is %s', v_global);

  r := public.consume_anon_generation('ip_two'); assert (r->>'ok')::boolean, format('4: %s', r);
  r := public.consume_anon_generation('ip_three');
  assert not (r->>'ok')::boolean and r->>'reason' = 'global_cap', format('5: %s', r);

  -- The kill switch wins over everything.
  update public.app_settings set value = 'false'::jsonb where key = 'anon_generation_enabled';
  r := public.consume_anon_generation('ip_new');
  assert not (r->>'ok')::boolean and r->>'reason' = 'disabled', format('6: %s', r);

  -- ⚠ FAIL CLOSED. A deleted or unreadable setting is "no", never "unlimited"
  --   -- a typo in a row someone edits at seven in the morning must not open
  --   the tap.
  update public.app_settings set value = 'true'::jsonb where key = 'anon_generation_enabled';
  delete from public.app_settings where key = 'anon_generation_daily_global';
  r := public.consume_anon_generation('ip_new');
  assert not (r->>'ok')::boolean and r->>'reason' = 'disabled', format('7: %s', r);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Spending is server-only
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('anon','public.consume_anon_generation(text)','execute'),
    'anon can spend';
  assert not has_function_privilege('authenticated','public.consume_anon_generation(text)','execute'),
    'a browser session can spend';
  -- The counters are not a browser's business either.
  assert not exists (
    select 1 from pg_policies
     where schemaname='public' and tablename='anon_generation_counters'
       and coalesce(qual,'') <> 'false'
  ), 'the counters have a readable policy';
end $$;

rollback;
