-- Un événement d'abonnement en retard ne réécrit pas l'état courant.
begin;

do $$
declare
  v_user uuid;
  v_row  public.subscriptions;
  t      timestamptz := '2026-09-27 10:00:00+00';
begin
  insert into auth.users (email) values ('stale-event@eklio-test.invalid') returning id into v_user;

  -- 1. Un event plus ancien ne réécrit pas.
  insert into public.subscriptions (user_id, stripe_subscription_id, status, stripe_event_at)
       values (v_user, 'sub_a', 'active', t + interval '10 seconds');
  update public.subscriptions set status = 'past_due', stripe_event_at = t where user_id = v_user;
  select * into v_row from public.subscriptions where user_id = v_user;
  assert v_row.status = 'active' and v_row.stripe_event_at = t + interval '10 seconds',
    format('un event plus ancien a réécrit l''abonnement : %s', v_row.status);

  -- 2. Même seconde, mais on ne revient pas à incomplete.
  update public.subscriptions set status = 'incomplete', stripe_event_at = t + interval '10 seconds' where user_id = v_user;
  select * into v_row from public.subscriptions where user_id = v_user;
  assert v_row.status = 'active', 'un created (incomplete) de la même seconde a rétrogradé l''abonnement';

  -- 3. Un event plus récent passe.
  update public.subscriptions set status = 'canceled', stripe_event_at = t + interval '20 seconds' where user_id = v_user;
  select * into v_row from public.subscriptions where user_id = v_user;
  assert v_row.status = 'canceled', 'un event plus récent n''a pas été appliqué';

  -- 4. canceled est terminal, même à horodatage égal ou sans horodatage.
  update public.subscriptions set status = 'active', stripe_event_at = t + interval '20 seconds' where user_id = v_user;
  update public.subscriptions set status = 'past_due' where user_id = v_user;
  select * into v_row from public.subscriptions where user_id = v_user;
  assert v_row.status = 'canceled', format('un abonnement résilié est revenu en %s', v_row.status);

  -- 5. Un NOUVEL abonnement sur le même compte passe : se réabonner est légitime.
  update public.subscriptions
     set stripe_subscription_id = 'sub_b', status = 'active', stripe_event_at = t
   where user_id = v_user;
  select * into v_row from public.subscriptions where user_id = v_user;
  assert v_row.stripe_subscription_id = 'sub_b' and v_row.status = 'active',
    'un nouvel abonnement a été bloqué par l''horodatage de l''ancien';

  -- 6. Une écriture sans horodatage (un cron) garde le dernier horodatage.
  update public.subscriptions set cancel_at_period_end = true where user_id = v_user;
  select * into v_row from public.subscriptions where user_id = v_user;
  assert v_row.stripe_event_at = t and v_row.cancel_at_period_end,
    'une écriture de cron a effacé l''horodatage ou a été refusée';

  -- 7. Par l'upsert du webhook (ON CONFLICT DO UPDATE), la même règle tient.
  insert into public.subscriptions (user_id, stripe_subscription_id, status, stripe_event_at)
       values (v_user, 'sub_b', 'incomplete', t - interval '5 seconds')
  on conflict (user_id) do update
     set status = excluded.status, stripe_event_at = excluded.stripe_event_at;
  select * into v_row from public.subscriptions where user_id = v_user;
  assert v_row.status = 'active', 'l''upsert d''un event ancien a réécrit l''abonnement';
end $$;

do $$
begin
  assert not has_function_privilege('authenticated', 'public.subscriptions_refuse_stale_event()', 'execute'),
    'la fonction de trigger est exécutable par un client';
end $$;

rollback;
