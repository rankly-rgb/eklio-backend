-- Les trois mois inclus dans Signature sont payés : le quota ne les lit pas
-- comme un essai. Trouvé en jouant le parcours Stripe (F54 vu depuis le quota).
begin;

do $$
declare
  v_user uuid;
  v_purchase uuid;
begin
  insert into auth.users (email) values ('paid-trial@eklio-test.invalid') returning id into v_user;
  insert into public.subscriptions (user_id, stripe_subscription_id, status)
       values (v_user, 'sub_paid_trial', 'trialing');

  assert public.credit_plan_for(v_user) = 'trial',
    'un abonnement trialing sans achat qui le couvre doit rester un essai';
  assert (public.credit_remaining(v_user, 'post_generation') ->> 'remaining')::int = 8,
    'l''essai non payé garde ses huit posts';

  insert into public.purchases (user_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
       values (v_user, 'signature', 'cs_paid_trial', 24900, 'paid', now())
    returning id into v_purchase;

  assert public.credit_plan_for(v_user) = 'standard',
    'Signature payé : ses trois mois inclus sont le produit complet, pas un essai';
  assert (public.credit_remaining(v_user, 'post_generation') ->> 'remaining')::int = 30,
    'le mois promis compte trente posts, et le quota doit les couvrir';

  -- Remboursé, l'achat cesse de couvrir l'essai.
  perform public.record_purchase_status_event(v_purchase, 'evt_paid_trial_refund', 'refunded', 'charge.refunded');
  assert public.credit_plan_for(v_user) = 'trial',
    'un Signature remboursé ne couvre plus rien';

  -- Un autre palier payé ne transforme pas un essai en abonnement payé.
  insert into public.purchases (user_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
       values (v_user, 'starter', 'cs_paid_trial_starter', 7900, 'paid', now());
  assert public.credit_plan_for(v_user) = 'trial',
    'seul Signature inclut des mois : un Starter payé ne couvre pas un essai';
end $$;

-- Toujours fermée aux clients.
do $$
begin
  assert not has_function_privilege('authenticated', 'public.credit_plan_for(uuid)', 'execute'),
    'credit_plan_for est redevenue exécutable par un client';
end $$;

rollback;
