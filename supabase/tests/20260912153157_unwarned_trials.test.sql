-- ============================================================================
-- Tests — `unwarned_trials()`, and the three-valued logic that nearly hid a
-- charge
-- ============================================================================
-- This file exists because the first version of the function said one thing in
-- its comment and the opposite in its SQL, and the difference was a NULL.
--
--   and not (stamped_for = trial_end and state in ('accepted','delivered'))
--
-- With `state` NULL that predicate is NULL, and a NULL predicate does not pass
-- a WHERE clause — so a row stamped by the OLD code (which recorded an attempt,
-- not an acceptance) disappeared from the report and read as warned. The glance
-- would have said zero while somebody was about to be charged unwarned.
--
-- ⚠ EVERY CASE BELOW IS A WAY OF NOT KNOWING. That is the whole subject: the
-- function must answer "prove it was warned", so anything unknown has to fall
-- on the side of unwarned. A test that only checked the happy path would have
-- passed against the broken version.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. ANTI-VACUITY
-- ---------------------------------------------------------------------------
do $$
declare v_missing text;
begin
  select string_agg(want.name, ', ' order by want.name) into v_missing
    from (values
           ('trial_notice_state'), ('trial_notice_provider_id'),
           ('trial_notice_accepted_at'), ('trial_extensions'),
           ('trial_guard_acted_at')
         ) as want(name)
   where not exists (
     select 1 from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = 'subscriptions'
        and c.column_name = want.name);
  assert v_missing is null,
    format('subscriptions is missing %s — every test below is vacuous', v_missing);

  assert to_regprocedure('public.unwarned_trials(integer)') is not null,
    'unwarned_trials(integer) does not exist';
end
$$;

-- Eklio's own instrument: it names other people's accounts and trial dates.
do $$
begin
  assert not has_function_privilege('anon', 'public.unwarned_trials(integer)', 'execute')
     and not has_function_privilege('authenticated', 'public.unwarned_trials(integer)', 'execute'),
    'unwarned_trials() is reachable from the browser — it lists other accounts';
end
$$;

-- ---------------------------------------------------------------------------
-- 1. EVERY WAY OF NOT KNOWING COUNTS AS UNWARNED
-- ---------------------------------------------------------------------------
do $$
declare
  v_end timestamptz := now() + interval '5 days';
  v_ids uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
                        gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  v_total int;
begin
  insert into auth.users (id, email)
  select v_ids[i], format('unwarned-%s@example.test', i) from generate_series(1, 6) i;

  insert into public.subscriptions
    (user_id, stripe_subscription_id, status, trial_end, trial_notice_sent_for, trial_notice_state)
  values
    -- ⚠ THE REGRESSION: stamped for the right date, but nothing is known about
    -- what happened to the message. The old code stamped exactly like this.
    (v_ids[1], 'sub_null_state', 'trialing', v_end, v_end, null),
    -- Never stamped at all.
    (v_ids[2], 'sub_never',      'trialing', v_end, null,  null),
    -- Stamped for a DIFFERENT date: that notice announced a charge that is no
    -- longer the one coming. An extended trial lands here.
    (v_ids[3], 'sub_stale',      'trialing', v_end, v_end - interval '9 days', 'accepted'),
    -- Bounced is the clearest possible evidence she was NOT told.
    (v_ids[4], 'sub_bounced',    'trialing', v_end, v_end, 'bounced'),
    (v_ids[5], 'sub_failed',     'trialing', v_end, v_end, 'failed'),
    -- The only warned row in the set.
    (v_ids[6], 'sub_ok',         'trialing', v_end, v_end, 'accepted');

  v_total := ((public.unwarned_trials(14))->>'total')::int;
  assert v_total = 5,
    format('expected 5 unwarned of 6, got %s — an unknown is being read as warned', v_total);

  -- And the warned one is genuinely excluded rather than the count being a
  -- coincidence: with only the accepted row in window, the answer is zero.
  delete from public.subscriptions where stripe_subscription_id <> 'sub_ok';
  v_total := ((public.unwarned_trials(14))->>'total')::int;
  assert v_total = 0,
    format('an accepted notice for the current trial_end must count as warned, got %s', v_total);
end
$$;

-- ---------------------------------------------------------------------------
-- 2. THE WINDOW IS CLOSED AT BOTH ENDS
-- ---------------------------------------------------------------------------
-- A trial that ended yesterday has no notice left to send, only an invoice; a
-- trial ending in three months is not this morning's problem and would make
-- the glance noise that people learn to scroll past.
do $$
declare
  v_soon uuid := gen_random_uuid(); v_far uuid := gen_random_uuid(); v_past uuid := gen_random_uuid();
begin
  delete from public.subscriptions;
  insert into auth.users (id, email) values
    (v_soon,'soon@example.test'), (v_far,'far@example.test'), (v_past,'past@example.test');
  insert into public.subscriptions
    (user_id, stripe_subscription_id, status, trial_end, trial_notice_sent_for, trial_notice_state)
  values
    (v_soon, 'sub_soon', 'trialing', now() + interval '2 days',  null, null),
    (v_far,  'sub_far',  'trialing', now() + interval '60 days', null, null),
    (v_past, 'sub_past', 'trialing', now() - interval '1 day',   null, null);

  assert ((public.unwarned_trials(14))->>'total')::int = 1,
    'the 14-day window must hold exactly the one trial ending in 2 days';
  assert ((public.unwarned_trials(90))->>'total')::int = 2,
    'a wider window must reach the far trial but never the one already past';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. A SUBSCRIPTION THAT IS NOT TRIALING HAS NO NOTICE OWING
-- ---------------------------------------------------------------------------
do $$
declare v_u uuid := gen_random_uuid();
begin
  delete from public.subscriptions;
  insert into auth.users (id, email) values (v_u, 'active@example.test');
  insert into public.subscriptions
    (user_id, stripe_subscription_id, status, trial_end, trial_notice_sent_for, trial_notice_state)
  values (v_u, 'sub_active', 'active', now() + interval '3 days', null, null);

  assert ((public.unwarned_trials(14))->>'total')::int = 0,
    'an already-paying subscription has no trial conversion to announce';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. THE VOCABULARY IS CLOSED, AND A STATE CANNOT FLOAT FREE OF ITS DATE
-- ---------------------------------------------------------------------------
do $$
declare v_u uuid := gen_random_uuid(); v_refused boolean;
begin
  delete from public.subscriptions;
  insert into auth.users (id, email) values (v_u, 'vocab@example.test');

  v_refused := false;
  begin
    insert into public.subscriptions
      (user_id, stripe_subscription_id, status, trial_end, trial_notice_sent_for, trial_notice_state)
    values (v_u, 'sub_bad', 'trialing', now() + interval '3 days', now() + interval '3 days', 'sent');
  exception when others then v_refused := true;
  end;
  assert v_refused, '''sent'' was accepted — the vocabulary must not admit words that mean an attempt';

  v_refused := false;
  begin
    insert into public.subscriptions
      (user_id, stripe_subscription_id, status, trial_end, trial_notice_sent_for, trial_notice_state)
    values (v_u, 'sub_floating', 'trialing', now() + interval '3 days', null, 'accepted');
  exception when others then v_refused := true;
  end;
  assert v_refused, 'a notice state was accepted without the date it is a statement about';
end
$$;

rollback;
