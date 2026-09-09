-- ============================================================================
-- Tests — 20260909150116_subscription_trial_end_and_notice.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('99999999-0000-0000-0000-000000000101','trial@example.com');

insert into public.subscriptions
  (user_id, stripe_subscription_id, stripe_price_id, status, current_period_end,
   cancel_at_period_end, trial_end)
values
  ('99999999-0000-0000-0000-000000000101','sub_trial_1','price_monthly_presence',
   'trialing', timestamptz '2026-12-08 00:00:00+00', false,
   timestamptz '2026-12-08 00:00:00+00');

-- ---------------------------------------------------------------------------
-- Both columns round-trip
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  select trial_end, trial_notice_sent_for into r
    from public.subscriptions where stripe_subscription_id = 'sub_trial_1';

  assert r.trial_end = timestamptz '2026-12-08 00:00:00+00', 'trial_end did not round-trip';
  assert r.trial_notice_sent_for is null, 'a fresh trial has been warned about nothing';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ THE ONE THAT MATTERS: trial_end is NOT an entitlement input.
--
-- `active` must stay true for `trialing` whatever trial_end says — including
-- when it is NULL and when it is long past. If a future edit ever wires the
-- clock into `active`, these three assertions are what catches it, and they
-- catch it here rather than on someone's kit.
-- ---------------------------------------------------------------------------
do $$
declare t timestamptz;
begin
  foreach t in array array[
    timestamptz '2036-01-01 00:00:00+00',   -- far future
    timestamptz '2000-01-01 00:00:00+00',   -- long past
    null                                     -- never on a trial
  ]
  loop
    update public.subscriptions set trial_end = t
     where stripe_subscription_id = 'sub_trial_1';

    assert (select active from public.subscriptions
             where stripe_subscription_id = 'sub_trial_1') is true,
           format('active must follow status alone; trial_end = %s changed it', coalesce(t::text,'null'));
  end loop;

  -- And the mirror image: trial_end in the future does not rescue a canceled
  -- subscription. Cancelling removes Monthly Presence the moment Stripe says so.
  update public.subscriptions
     set status = 'canceled', trial_end = timestamptz '2036-01-01 00:00:00+00'
   where stripe_subscription_id = 'sub_trial_1';

  assert (select active from public.subscriptions
           where stripe_subscription_id = 'sub_trial_1') is false,
         'a canceled subscription with a future trial_end must NOT read active';
end
$$;

-- ---------------------------------------------------------------------------
-- The notice predicate: owed / not owed / owed again after an extension
-- ---------------------------------------------------------------------------
do $$
declare owed boolean;
begin
  update public.subscriptions
     set status = 'trialing',
         trial_end = timestamptz '2026-12-08 00:00:00+00',
         trial_notice_sent_for = null
   where stripe_subscription_id = 'sub_trial_1';

  select trial_notice_sent_for is distinct from trial_end into owed
    from public.subscriptions where stripe_subscription_id = 'sub_trial_1';
  assert owed, 'a trial never warned about is owed a notice';

  -- Sent.
  update public.subscriptions set trial_notice_sent_for = trial_end
   where stripe_subscription_id = 'sub_trial_1';

  select trial_notice_sent_for is distinct from trial_end into owed
    from public.subscriptions where stripe_subscription_id = 'sub_trial_1';
  assert not owed, 'a replayed sweep must not warn twice about the same date';

  -- Extended — the charge she was warned about is no longer the charge she
  -- will get, so she is owed a fresh notice. A boolean would have swallowed this.
  update public.subscriptions set trial_end = timestamptz '2027-03-08 00:00:00+00'
   where stripe_subscription_id = 'sub_trial_1';

  select trial_notice_sent_for is distinct from trial_end into owed
    from public.subscriptions where stripe_subscription_id = 'sub_trial_1';
  assert owed, 'an EXTENDED trial must earn a fresh notice';
end
$$;

-- ---------------------------------------------------------------------------
-- The sweep's index exists and is scoped to trialing rows
-- ---------------------------------------------------------------------------
do $$
begin
  assert exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and indexname = 'subscriptions_trialing_ending_idx'
       and indexdef like '%trialing%'
  ), 'the partial index the daily sweep relies on is missing';
end
$$;

rollback;
