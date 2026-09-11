-- ============================================================================
-- Tests — 20260910212308_funnel_events.sql
-- ============================================================================
-- ⚠ WHY THIS EXISTS WHEN THE MIGRATION ALREADY HAS GUARD RAILS.
--
-- That migration's guard rails are thorough, and they do re-run on every CI
-- replay. What they cannot do is notice a LATER migration dropping the CHECK,
-- renaming the function, or widening the thresholds — because by then they have
-- already run and passed. A migration guard asserts the moment it ran; this
-- file asserts the state at the end of the whole replay, which is the only
-- place a regression introduced afterwards becomes visible.
--
-- It is also the file that `20260829112000_null_safe_jsonb_validators.test.sql`
-- points at when it lists `funnel_props_are_safe` under `array_validators`
-- ("has its own coverage elsewhere in the suite"). That claim has to be true.
--
-- ── WHAT IS ACTUALLY BEING PROTECTED ────────────────────────────────────────
--
-- Not a schema. A promise: **no word she wrote is ever in this table.** Not her
-- positioning, not her referral quote, not the text she pasted into Check, not
-- truncated and not hashed. For months that promise was a comment in
-- `lib/analytics.ts`; it is now a CHECK on a column, and a CHECK is the only
-- form of it a new call site cannot forget.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. The CHECK is still attached to the column
-- ---------------------------------------------------------------------------
-- The function existing is not the defence. The function being wired to the
-- column is. A later migration that recreates the table without the constraint
-- would leave every assertion below still passing on the function alone.
do $$
declare v_def text;
begin
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'public.funnel_events'::regclass
     and c.conname = 'funnel_events_props_check';

  assert v_def is not null,
    'funnel_events_props_check is gone — props accepts free text again';
  assert v_def like '%funnel_props_are_safe%',
    format('the props CHECK no longer calls funnel_props_are_safe: %s', v_def);
end
$$;

-- ---------------------------------------------------------------------------
-- 2. ⚠ THE THRESHOLDS, PINNED
-- ---------------------------------------------------------------------------
-- These four numbers are duplicated in `lib/funnel/sink.ts` (`safeProps`),
-- which trims a payload client-side so that one bad property loses itself
-- rather than losing the whole event to a constraint violation. The two copies
-- must agree; `lib/funnel/__tests__/funnel.test.ts` pins the frontend half and
-- this pins the database half. If you change one, this file is how you find
-- out you changed only one.
do $$
begin
  -- 64 characters is the boundary, and it is inclusive on both sides.
  assert public.funnel_props_are_safe(jsonb_build_object('id', repeat('y', 64))),
    'a 64-character string is legitimate and was refused';
  assert not public.funnel_props_are_safe(jsonb_build_object('quote', repeat('x', 65))),
    '⚠ A 65-CHARACTER STRING WAS ACCEPTED — prose can reach the table';

  -- Twelve keys, inclusive.
  assert public.funnel_props_are_safe(
    (select jsonb_object_agg('k' || i, i) from generate_series(1, 12) i)),
    'twelve keys is legitimate and was refused';
  assert not public.funnel_props_are_safe(
    (select jsonb_object_agg('k' || i, i) from generate_series(1, 13) i)),
    'thirteen keys was accepted';

  -- 40-character keys, inclusive. A long key is a sentence wearing a hat.
  assert public.funnel_props_are_safe(jsonb_build_object(repeat('k', 40), 1)),
    'a 40-character key is legitimate and was refused';
  assert not public.funnel_props_are_safe(jsonb_build_object(repeat('k', 41), 1)),
    'a 41-character key was accepted';

  -- No nesting, in either shape: an object or an array is where a paragraph
  -- hides from a length check.
  assert not public.funnel_props_are_safe('{"nested":{"text":"hi"}}'::jsonb),
    'a nested object was accepted';
  assert not public.funnel_props_are_safe('{"list":["a","b"]}'::jsonb),
    'a nested array was accepted';

  -- And what the product actually sends still passes, or the guard is useless
  -- in the other direction.
  assert public.funnel_props_are_safe('{"step":4,"reason":"ip_cap","ok":true,"id":null}'::jsonb),
    'the guard refuses a legitimate payload';
  assert public.funnel_props_are_safe('{}'::jsonb),
    'the empty object is the column default and must pass';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. The CHECK bites on a real insert, not only in the function
-- ---------------------------------------------------------------------------
do $$
declare v_n integer;
begin
  begin
    insert into public.funnel_events (event, props)
    values ('test_probe', jsonb_build_object('text', repeat('y', 200)));
    assert false, 'the props CHECK did not fire on insert';
  exception when check_violation then null;
  end;

  begin
    insert into public.funnel_events (event) values ('Not A Valid Event');
    assert false, 'the event-name CHECK did not fire';
  exception when check_violation then null;
  end;

  -- Nothing a refused probe attempted may have landed.
  select count(*) into v_n from public.funnel_events where event = 'test_probe';
  assert v_n = 0, 'a refused probe still wrote a row';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. It is Eklio's data, and no browser may reach it
-- ---------------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n from pg_policies
   where schemaname = 'public'
     and tablename in ('funnel_events', 'funnel_steps')
     and qual = 'false';
  assert v_n = 2, format('%s of 2 deny-all policies present on the funnel tables', v_n);

  assert not has_function_privilege('anon', 'public.record_funnel_events(jsonb)', 'execute'),
    'anon can write the funnel';
  assert not has_function_privilege('authenticated', 'public.record_funnel_events(jsonb)', 'execute'),
    'a signed-in browser can write the funnel';
  assert not has_function_privilege('anon', 'public.funnel_report(timestamptz, timestamptz)', 'execute'),
    'anon can read the funnel report';
  assert not has_function_privilege('authenticated', 'public.funnel_report(timestamptz, timestamptz)', 'execute'),
    'a signed-in browser can read the funnel report';
end
$$;

-- ---------------------------------------------------------------------------
-- 5. The named funnel is still twelve contiguous steps
-- ---------------------------------------------------------------------------
-- The order is not decoration: step 8 was moved from position 8 to 12 by
-- 20260910212828 because choosing a direction happens AFTER paying
-- (`lib/reveal/use-select-direction.ts` sends an unpaid visitor to checkout
-- first). A funnel whose steps are out of order blames the wrong screen, and
-- does it consistently enough to be believed.
do $$
declare v_n integer; v_chose integer; v_paid integer;
begin
  select count(*) into v_n from public.funnel_steps;
  assert v_n = 12, format('%s named steps, expected 12', v_n);

  select count(*) into v_n from public.funnel_steps where step_no between 1 and 12;
  assert v_n = 12, 'the step numbers are not 1..12 without gaps';

  select step_no into v_chose from public.funnel_steps where step_key = 'chose';
  select step_no into v_paid  from public.funnel_steps where step_key = 'paid';
  assert v_chose > v_paid,
    format('"chose a direction" (%s) must come after "paid" (%s) — an unpaid visitor is sent to checkout before she can choose',
           v_chose, v_paid);

  -- The report runs and returns every step even with nothing recorded.
  select count(*) into v_n from public.funnel_report(now() - interval '1 day');
  assert v_n = 12, format('funnel_report returned %s rows, expected 12', v_n);
end
$$;

rollback;
