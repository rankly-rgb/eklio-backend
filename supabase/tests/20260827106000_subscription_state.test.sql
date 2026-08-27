-- ============================================================================
-- Tests — 20260827106000_subscription_state.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('99999999-0000-0000-0000-000000000001','sub@example.com'),
  ('99999999-0000-0000-0000-000000000002','stranger@example.com');

-- ---------------------------------------------------------------------------
-- The whole documented state is readable in one row
-- ---------------------------------------------------------------------------
insert into public.subscriptions
  (user_id, stripe_subscription_id, stripe_price_id, status, current_period_end, cancel_at_period_end)
values
  ('99999999-0000-0000-0000-000000000001','sub_state_1','price_monthly_presence',
   'active', timestamptz '2026-09-30 00:00:00+00', true);

do $$
declare
  r record;
begin
  select active, status, current_period_end, cancel_at_period_end, stripe_subscription_id
    into r
    from public.subscriptions
   where user_id = '99999999-0000-0000-0000-000000000001';

  assert r.active is true,                        'active must be true for an active subscription';
  assert r.status = 'active',                     'status did not round-trip';
  assert r.current_period_end is not null,        'current_period_end did not round-trip';
  assert r.cancel_at_period_end is true,          'cancel_at_period_end did not round-trip';
  assert r.stripe_subscription_id = 'sub_state_1','stripe_subscription_id did not round-trip';
end
$$;

-- ---------------------------------------------------------------------------
-- active tracks status, and cannot be written independently of it
-- ---------------------------------------------------------------------------
do $$
declare
  s text;
  blocked boolean;
begin
  foreach s in array array['active','trialing'] loop
    update public.subscriptions set status = s where user_id='99999999-0000-0000-0000-000000000001';
    assert (select active from public.subscriptions
             where user_id='99999999-0000-0000-0000-000000000001') is true,
           format('active must be true for status %s', s);
  end loop;

  foreach s in array array['incomplete','incomplete_expired','past_due','canceled','unpaid','paused'] loop
    update public.subscriptions set status = s where user_id='99999999-0000-0000-0000-000000000001';
    assert (select active from public.subscriptions
             where user_id='99999999-0000-0000-0000-000000000001') is false,
           format('active must be false for status %s', s);
  end loop;

  -- past_due deliberately reads as inactive here: any grace period is a
  -- commercial decision and belongs to eklio-frontend.
  update public.subscriptions set status = 'past_due' where user_id='99999999-0000-0000-0000-000000000001';
  assert (select active from public.subscriptions
           where user_id='99999999-0000-0000-0000-000000000001') is false,
         'past_due must not be reported as active by the database';

  begin
    update public.subscriptions set active = true where user_id='99999999-0000-0000-0000-000000000001';
    blocked := false;
  exception when others then blocked := true; end;
  assert blocked, 'active could be written directly; it must be generated from status';

  update public.subscriptions set status = 'active' where user_id='99999999-0000-0000-0000-000000000001';
end
$$;

-- ---------------------------------------------------------------------------
-- The uniqueness the webhook handler upserts on
-- ---------------------------------------------------------------------------
do $$
declare
  rejected boolean;
begin
  -- a replayed webhook must not create a second row
  begin
    insert into public.subscriptions (user_id, stripe_subscription_id, status)
    values ('99999999-0000-0000-0000-000000000002','sub_state_1','active');
    rejected := false;
  exception when unique_violation then rejected := true; end;
  assert rejected, 'the same Stripe subscription id was stored twice';

  -- one user cannot hold two concurrent subscriptions
  begin
    insert into public.subscriptions (user_id, stripe_subscription_id, status)
    values ('99999999-0000-0000-0000-000000000001','sub_state_2','active');
    rejected := false;
  exception when unique_violation then rejected := true; end;
  assert rejected, 'a user was given two concurrent subscriptions';

  -- an unknown Stripe status must fail loudly rather than be stored
  begin
    update public.subscriptions set status = 'invented'
     where user_id='99999999-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'an unknown subscription status was stored';
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: own row readable, nobody else's, and no client writes at all
-- ---------------------------------------------------------------------------
do $$
declare
  blocked boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"99999999-0000-0000-0000-000000000002"}';
  assert (select count(*) from public.subscriptions
           where user_id='99999999-0000-0000-0000-000000000001') = 0,
         'a stranger could read another user''s subscription';

  set local request.jwt.claims = '{"sub":"99999999-0000-0000-0000-000000000001"}';
  assert (select count(*) from public.subscriptions
           where user_id='99999999-0000-0000-0000-000000000001') = 1,
         'the owner must be able to read their own subscription';

  -- a client that could insert would give itself Monthly Presence
  begin
    insert into public.subscriptions (user_id, stripe_subscription_id, status)
    values ('99999999-0000-0000-0000-000000000001','sub_self_served','active');
    blocked := false;
  exception when insufficient_privilege then blocked := true;
            when unique_violation      then blocked := true; end;
  assert blocked, 'an authenticated user granted themselves a subscription';

  -- and one that could update would push its own renewal date out
  update public.subscriptions set cancel_at_period_end = false
   where user_id='99999999-0000-0000-0000-000000000001';
  assert (select cancel_at_period_end from public.subscriptions
           where user_id='99999999-0000-0000-0000-000000000001') is true,
         'an authenticated user modified their own subscription row';
end
$$;

rollback;
