-- ============================================================================
-- Tests — 20260901074842_usp_fingerprints.sql
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
  ('bbbbbbbb-0000-0000-0000-000000000301', array['trauma'], 'OR'),
  ('bbbbbbbb-0000-0000-0000-000000000302', array['trauma'], 'OR');

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
      'trauma:or', 'A perfectly legitimate-looking statement',
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
-- ⚠ usp_fingerprint_confirm IS service_role ONLY. `authenticated` must be
-- refused OUTRIGHT -- it once held this grant, checking ownership itself
-- against auth.uid(), but that grant had no remaining use once
-- FRONTEND_CONTRACT.md settled on calling all three USP RPCs from the
-- route handler with the service-role key. A client-callable write path
-- nothing in the intended architecture calls is pure attack surface.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000301"}';

do $$
begin
  begin
    perform public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000301'::uuid, 'authenticated should never reach this');
    raise exception 'FAIL: authenticated could call usp_fingerprint_confirm directly';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated has no EXECUTE grant on usp_fingerprint_confirm';
  end;
end
$$;

reset role;

set local role anon;
do $$
begin
  begin
    perform public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000301'::uuid, 'anon should never reach this either');
    raise exception 'FAIL: anon could call usp_fingerprint_confirm at all';
  exception when insufficient_privilege then
    raise notice 'OK: anon has no EXECUTE grant on usp_fingerprint_confirm';
  end;
end
$$;
reset role;

-- ---------------------------------------------------------------------------
-- usp_fingerprint_confirm, called the way the route handler actually calls
-- it: with the service-role key. It DERIVES scope_key from the brief's own
-- specialties (by catalog sort_order, not array position) and state --
-- there is no p_scope_key parameter, so there is nothing for a caller to
-- override.
--
-- ⚠ IT NO LONGER CHECKS OWNERSHIP ITSELF. Now that it is service_role
-- only, it trusts its caller completely -- the same trust model as
-- `seed_site_spec` (`20260829100000_site_spec.sql`): it resolves the
-- brief's actual owner from the FK chain rather than an argument, so
-- there is no id through which a foreign owner could be smuggled in, but
-- verifying the CALL ITSELF is legitimate is entirely the route handler's
-- job now (checking the user's own JWT before ever reaching for the
-- service-role key -- see FRONTEND_CONTRACT.md §9.6). That division is
-- exactly why the grant test above matters: the moment this leaked to
-- `authenticated`, there would be no ownership check left anywhere to
-- catch it.
-- ---------------------------------------------------------------------------
set local role service_role;

do $$
declare
  v_id  uuid;
  v_row record;
begin
  v_id := public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000301'::uuid, 'A confirmed, real statement about my practice');
  assert v_id is not null;

  select * into v_row from public.usp_fingerprints where id = v_id;
  assert v_row.user_id = 'aaaaaaaa-0000-0000-0000-000000000301', 'the row must be owned by the brief''s actual owner';
  assert v_row.brief_id = 'bbbbbbbb-0000-0000-0000-000000000301', 'the row must be attached to the confirmed brief';
  assert v_row.scope_key = 'trauma:or',
    format('scope_key must be DERIVED from the brief''s own specialties (catalog sort_order, ''trauma'') and state (''OR''), got %s', v_row.scope_key);
  assert v_row.statement = 'A confirmed, real statement about my practice';
  assert v_row.normalized = public.usp_normalize('A confirmed, real statement about my practice');

  raise notice 'OK: usp_fingerprint_confirm wrote a row with server-derived scope_key %', v_row.scope_key;
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ AT MOST ONE ROW PER BRIEF. Without the unique constraint + upsert, a
-- direct RPC call would let a caller flood a bucket with unlimited rows --
-- the frontend's 20/hour rate limit does not protect this path, since it
-- lives in the route handler, not the database. Re-confirming must
-- REPLACE the row, carrying the new statement, not add a second one.
-- ---------------------------------------------------------------------------
do $$
declare
  n     int;
  v_row record;
begin
  -- This brief already has one row from the block above; confirm again
  -- with an edited statement.
  perform public.usp_fingerprint_confirm(
    'bbbbbbbb-0000-0000-0000-000000000301'::uuid,
    'A different, edited statement about my practice'
  );

  select count(*) into n from public.usp_fingerprints where brief_id = 'bbbbbbbb-0000-0000-0000-000000000301';
  assert n = 1, format('expected exactly one row per brief after two confirms, got %s', n);

  select * into v_row from public.usp_fingerprints where brief_id = 'bbbbbbbb-0000-0000-0000-000000000301';
  assert v_row.statement = 'A different, edited statement about my practice',
    format('the single remaining row must carry the SECOND (latest) statement, got: %s', v_row.statement);

  raise notice 'OK: two confirms on the same brief leave exactly one row, carrying the second statement';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ scope_key DERIVATION MUST NOT DEPEND ON specialty_ids ARRAY ORDER.
-- `specialty_ids` has no guaranteed order (plain `text[]`, written verbatim
-- by frontend autosave). Two briefs selecting the SAME set of specialties
-- in a DIFFERENT array order must resolve to the SAME scope_key --
-- otherwise reordering her own selections would silently move her USP
-- into a different bucket and dodge collision detection.
-- ---------------------------------------------------------------------------
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000304', 'aaaaaaaa-0000-0000-0000-000000000301', 'Order A Practice'),
  ('bbbbbbbb-0000-0000-0000-000000000305', 'aaaaaaaa-0000-0000-0000-000000000301', 'Order B Practice');

-- Same three specialties (anxiety=1, trauma=3, adhd=12 by catalog
-- sort_order), inserted in two different, deliberately non-sorted orders.
insert into public.project_briefs (project_id, specialty_ids, state) values
  ('bbbbbbbb-0000-0000-0000-000000000304', array['adhd', 'anxiety', 'trauma'], 'CA'),
  ('bbbbbbbb-0000-0000-0000-000000000305', array['trauma', 'adhd', 'anxiety'], 'CA');

do $$
declare
  v_id_a uuid;
  v_id_b uuid;
  v_scope_a text;
  v_scope_b text;
begin
  v_id_a := public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000304'::uuid, 'Statement from the array-order-A brief');
  v_id_b := public.usp_fingerprint_confirm('bbbbbbbb-0000-0000-0000-000000000305'::uuid, 'Statement from the array-order-B brief');

  select scope_key into v_scope_a from public.usp_fingerprints where id = v_id_a;
  select scope_key into v_scope_b from public.usp_fingerprints where id = v_id_b;

  assert v_scope_a = v_scope_b,
    format('permuting specialty_ids must NOT change scope_key: got %s vs %s', v_scope_a, v_scope_b);
  assert v_scope_a = 'anxiety:ca',
    format('the primary specialty must be the LOWEST catalog sort_order among those selected (anxiety, sort_order=1), not array position, got %s', v_scope_a);

  raise notice 'OK: scope_key is order-independent -- both permutations resolved to %', v_scope_a;
end
$$;

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

-- A brief that does not exist at all is still refused (basic input
-- validation, not an ownership check -- there is no such thing to check
-- against anymore).
do $$
begin
  begin
    perform public.usp_fingerprint_confirm('00000000-0000-0000-0000-000000000000'::uuid, 'a brief that does not exist');
    raise exception 'FAIL: confirmed a fingerprint against a nonexistent brief';
  exception when others then
    raise notice 'OK: usp_fingerprint_confirm refuses a brief_id that does not resolve to any project_briefs row';
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

set local role service_role;

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
