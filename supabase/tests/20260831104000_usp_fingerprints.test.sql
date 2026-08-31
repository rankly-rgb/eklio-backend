-- ============================================================================
-- Tests — 20260831104000_usp_fingerprints.sql
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- usp_normalize: punctuation/digit strip, stopword removal, order-preserving,
-- stable across repeated calls.
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.usp_normalize('Trauma-informed care for FIRST responders (24/7).')
       = public.usp_normalize('trauma informed care for first responders'),
       'punctuation and digits must not affect normalization';

  assert public.usp_normalize('I run a therapy practice for clients who are new parents') = 'run new parents',
       format('got: [%s]', public.usp_normalize('I run a therapy practice for clients who are new parents'));

  assert public.usp_normalize('new parents adjusting to loss') <> public.usp_normalize('loss adjusting to new parents'),
       'the same words in a different order must normalize differently -- order is preserved on purpose';

  assert public.usp_normalize('EMDR for first responders') = public.usp_normalize('EMDR for first responders'),
       'usp_normalize must be stable across repeated calls in the same session';
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: a user reads and inserts her own usp_fingerprints rows only; cannot
-- select another user's row, cannot insert under another user_id.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000301', 'owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000302', 'stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000301', 'aaaaaaaa-0000-0000-0000-000000000301', 'Owner Practice'),
  ('bbbbbbbb-0000-0000-0000-000000000302', 'aaaaaaaa-0000-0000-0000-000000000302', 'Stranger Practice');
insert into public.project_briefs (project_id) values
  ('bbbbbbbb-0000-0000-0000-000000000301'),
  ('bbbbbbbb-0000-0000-0000-000000000302');

insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized) values
  ('aaaaaaaa-0000-0000-0000-000000000301', 'bbbbbbbb-0000-0000-0000-000000000301', 'trauma:or', 'Owner statement', public.usp_normalize('Owner statement')),
  ('aaaaaaaa-0000-0000-0000-000000000302', 'bbbbbbbb-0000-0000-0000-000000000302', 'trauma:or', 'Stranger statement', public.usp_normalize('Stranger statement'));

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000301"}';

do $$
declare n int;
begin
  select count(*) into n from public.usp_fingerprints;
  assert n = 1, format('the owner must see exactly her own row, saw %s', n);

  select count(*) into n from public.usp_fingerprints where statement = 'Stranger statement';
  assert n = 0, 'the owner must not be able to select the stranger''s row';
end
$$;

do $$
begin
  begin
    insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized)
    values ('aaaaaaaa-0000-0000-0000-000000000302', 'bbbbbbbb-0000-0000-0000-000000000302', 'x:us', 'sneaky', public.usp_normalize('sneaky'));
    raise exception 'FAIL: inserted a usp_fingerprints row under another user_id';
  exception when insufficient_privilege then
    raise notice 'OK: insert under another user_id blocked';
  end;
end
$$;

reset role;
rollback;
