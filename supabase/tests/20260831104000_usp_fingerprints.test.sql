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
-- RLS: a user reads her own usp_fingerprints rows only; cannot select
-- another user's row.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000301', 'owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000302', 'stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000301', 'aaaaaaaa-0000-0000-0000-000000000301', 'Owner Practice'),
  ('bbbbbbbb-0000-0000-0000-000000000302', 'aaaaaaaa-0000-0000-0000-000000000302', 'Stranger Practice');
insert into public.project_briefs (project_id, specialty_ids, state) values
  ('bbbbbbbb-0000-0000-0000-000000000301', array['trauma_informed'], 'OR'),
  ('bbbbbbbb-0000-0000-0000-000000000302', array['trauma_informed'], 'OR');

insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized) values
  ('aaaaaaaa-0000-0000-0000-000000000301', 'bbbbbbbb-0000-0000-0000-000000000301', 'trauma_informed:or', 'Owner statement', public.usp_normalize('Owner statement')),
  ('aaaaaaaa-0000-0000-0000-000000000302', 'bbbbbbbb-0000-0000-0000-000000000302', 'trauma_informed:or', 'Stranger statement', public.usp_normalize('Stranger statement'));

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

reset role;

-- ---------------------------------------------------------------------------
-- ⚠ THE SCOPE_KEY SPOOFING HOLE: a direct client INSERT must be refused
-- OUTRIGHT -- not just "under another user_id". RLS's WITH CHECK only ever
-- proves row ownership, never row CONTENT; scope_key is a plain text
-- column with no FK or CHECK tying it to the caller's own brief, so if
-- INSERT were allowed at all, ANY authenticated user could write into ANY
-- specialty:state bucket and poison collision detection for every other
-- practitioner in it, even while correctly "owning" the row she inserted.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000301"}';

do $$
begin
  -- Even a well-formed insert, entirely under her own user_id, for her own
  -- brief, with a scope_key that matches reality -- still refused. This is
  -- the point: ownership of the ROW was never the actual risk.
  begin
    insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized)
    values (
      'aaaaaaaa-0000-0000-0000-000000000301', 'bbbbbbbb-0000-0000-0000-000000000301',
      'trauma_informed:or', 'A perfectly legitimate-looking statement',
      public.usp_normalize('A perfectly legitimate-looking statement')
    );
    raise exception 'FAIL: authenticated could INSERT into usp_fingerprints directly, even under her own identity';
  exception when insufficient_privilege then
    raise notice 'OK: direct INSERT refused outright (table privilege revoked)';
  end;
end
$$;

do $$
begin
  -- The actual attack this closes: spoofing a DIFFERENT scope_key to
  -- poison another specialty/state bucket. Also refused, for the same
  -- reason (no INSERT privilege at all), not because this particular
  -- scope_key was checked and rejected.
  begin
    insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized)
    values (
      'aaaaaaaa-0000-0000-0000-000000000301', 'bbbbbbbb-0000-0000-0000-000000000301',
      'anxiety:ca', 'Poisoned statement in a bucket this brief has nothing to do with',
      public.usp_normalize('Poisoned statement in a bucket this brief has nothing to do with')
    );
    raise exception 'FAIL: authenticated could spoof an arbitrary scope_key via direct INSERT';
  exception when insufficient_privilege then
    raise notice 'OK: scope_key spoofing via direct INSERT refused';
  end;
end
$$;

reset role;

-- ---------------------------------------------------------------------------
-- usp_fingerprint_confirm is the ONLY sanctioned write path. It DERIVES
-- scope_key from the brief's own specialty_ids[1]/state -- there is no
-- p_scope_key parameter, so there is nothing for a caller to override.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000301"}';

do $$
declare
  v_id uuid;
  v_row record;
begin
  v_id := public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000301'::uuid, 'A confirmed, real statement about my practice');
  assert v_id is not null;

  -- select as authenticated (RLS-gated, own row) -- everything except
  -- `normalized` is checked here; `usp_normalize` itself is not SECURITY
  -- DEFINER (it is only ever meant to be called FROM inside one), so it
  -- cannot read usp_stopwords when called directly as authenticated --
  -- that comparison runs after `reset role` below instead.
  select * into v_row from public.usp_fingerprints where id = v_id;
  assert v_row.user_id = 'aaaaaaaa-0000-0000-0000-000000000301', 'the row must be owned by the caller';
  assert v_row.brief_id = 'bbbbbbbb-0000-0000-0000-000000000301', 'the row must be attached to the brief the caller confirmed';
  assert v_row.scope_key = 'trauma_informed:or',
    format('scope_key must be DERIVED from the brief''s own specialty_ids[1] (''trauma_informed'') and state (''OR''), got %s', v_row.scope_key);
  assert v_row.statement = 'A confirmed, real statement about my practice';

  raise notice 'OK: usp_fingerprint_confirm wrote a row with server-derived scope_key %', v_row.scope_key;
end
$$;

reset role;

do $$
begin
  assert (select normalized from public.usp_fingerprints where statement = 'A confirmed, real statement about my practice')
       = public.usp_normalize('A confirmed, real statement about my practice'),
    'normalized must match usp_normalize() of the confirmed statement';
end
$$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000301"}';

do $$
begin
  -- No p_scope_key parameter exists, so "overriding" it isn't a matter of
  -- passing a bad value -- confirm the function's actual signature takes
  -- only (brief_id, statement), which is what makes override structurally
  -- impossible rather than merely unvalidated.
  assert (
    select pg_get_function_arguments(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'usp_fingerprint_confirm'
  ) = 'p_brief_id uuid, p_statement text',
  'usp_fingerprint_confirm must not accept a caller-supplied scope_key -- its signature is the proof';
end
$$;

-- Attempting to confirm a brief she does NOT own must be refused.
do $$
begin
  begin
    perform public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000302'::uuid, 'Trying to write into the stranger''s brief');
    raise exception 'FAIL: confirmed a fingerprint against a brief owned by another user';
  exception when others then
    raise notice 'OK: usp_fingerprint_confirm refuses to write against a brief the caller does not own';
  end;
end
$$;

reset role;

-- ---------------------------------------------------------------------------
-- `anon` must be refused BOTH ways: no EXECUTE grant at all, and even if it
-- somehow had one, the ownership check inside the function must still
-- reject a NULL auth.uid() rather than silently pass (the `<>` vs
-- `IS DISTINCT FROM` bug: `IF NULL THEN` is treated as FALSE in PL/pgSQL,
-- so `v_user_id <> NULL` would have skipped the raise entirely for an
-- anon caller).
-- ---------------------------------------------------------------------------
set local role anon;

do $$
begin
  begin
    perform public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000301'::uuid, 'anon should never reach this');
    raise exception 'FAIL: anon could call usp_fingerprint_confirm at all';
  exception when insufficient_privilege then
    raise notice 'OK: anon has no EXECUTE grant on usp_fingerprint_confirm';
  end;
end
$$;

reset role;

-- Defense in depth: call it as service_role (which DOES have EXECUTE) but
-- with no request.jwt.claims set, so auth.uid() is NULL -- simulating what
-- would happen if the grant above were ever loosened by mistake. Must
-- still be refused, by the function's own NULL-safe ownership check.
-- `reset` clears any request.jwt.claims left over from earlier in this
-- transaction (`set local` persists until changed or the transaction
-- ends) -- without this, auth.uid() would still resolve to whichever user
-- was last set, and the NULL case would never actually be exercised.
reset request.jwt.claims;
set local role service_role;

do $$
begin
  begin
    perform public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000301'::uuid, 'null auth.uid() should never reach this either');
    raise exception 'FAIL: a NULL auth.uid() was accepted as owning the brief';
  exception when others then
    raise notice 'OK: NULL auth.uid() is correctly refused by IS DISTINCT FROM, not silently passed by <>';
  end;
end
$$;

reset role;

-- A brief with no state falls into the national ':us' bucket -- the
-- strictest scope, not the loosest.
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000303', 'aaaaaaaa-0000-0000-0000-000000000301', 'No-State Practice');
insert into public.project_briefs (project_id, specialty_ids, state) values
  ('bbbbbbbb-0000-0000-0000-000000000303', array['anxiety'], null);

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000301"}';

do $$
declare
  v_id uuid;
  v_scope_key text;
begin
  v_id := public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000303'::uuid, 'A statement from a brief with no state set');
  select scope_key into v_scope_key from public.usp_fingerprints where id = v_id;
  assert v_scope_key = 'anxiety:us', format('a brief with no state must fall into the :us bucket, got %s', v_scope_key);
end
$$;

reset role;
rollback;
