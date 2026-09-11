-- ============================================================================
-- Tests — 20260906112044_image_regeneration_budget.sql
--
-- Deux choses à tenir, et elles se ratent silencieusement toutes les deux :
--   1. elle n'est JAMAIS facturée pour une photographie qu'elle n'a pas reçue ;
--   2. régénérer une photo ne touche PAS le compteur des directions. Ce sont
--      deux mètres différents, tarifés différemment (cf. FINDINGS.md).
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-0000000000b1','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-0000000000b2','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000b1','aaaaaaaa-0000-0000-0000-0000000000b1','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000b1','bbbbbbbb-0000-0000-0000-0000000000b1');
insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-0000000000b1','bbbbbbbb-0000-0000-0000-0000000000b1',
        'starter','cs_test_b1',7900,'paid',now());

-- Exactement ce que fait le webhook de paiement : sans cet appel, le projet
-- n'a pas d'allocation et le budget photo vaut zéro -- ce qui est correct, et
-- ce que ce test a d'abord constaté en échouant.
select public.grant_plan_allowance('bbbbbbbb-0000-0000-0000-0000000000b1','starter','evt_test_b1');

-- ---------------------------------------------------------------------------
-- Réserver avant, libérer sur échec, régler sur succès. Et le plafond tient.
-- ---------------------------------------------------------------------------
/*
 * ⚠ 200, PAS 100 — LE PLAFOND A ÉTÉ RELEVÉ EXPRÈS. `plans.image_budget_cents`
 * pour `starter` est passé de 100 à 200 le 9 septembre
 * (20260909100346_raise_image_budgets_and_rewrite_ceiling), qui porte sa
 * propre garde épinglant 200/400/600. Ce fichier disait encore 100 et toute
 * son arithmétique en découlait ; il n'a jamais été rejoué, parce que la
 * rediffusion CI était bloquée depuis le 10 septembre.
 *
 * Le nombre reste ÉPINGLÉ ici — une baisse silencieuse à 150 doit échouer —
 * mais une seule fois : le reste du bloc se calcule à partir de `v_budget`,
 * de sorte que ce qui est affirmé est le COMPORTEMENT (réserver compte,
 * refuser ne réserve rien, exactement le reste passe, un centime de plus est
 * refusé) et non une seconde copie du chiffre.
 */
do $$
declare v jsonb; b jsonb; v_budget int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000b1"}';

  b := public.get_image_regeneration_budget('cccccccc-0000-0000-0000-0000000000b1');
  v_budget := (b->>'budget_cents')::int;
  assert v_budget = 200,
    format('le budget starter devrait être de 200 centimes depuis le 9 septembre, reçu %s', b);
  assert (b->>'remaining_cents')::int = v_budget, format('restant initial : %s', b);

  -- La dépense en vol compte dès qu'elle commence.
  v := public.reserve_image_regeneration('cccccccc-0000-0000-0000-0000000000b1', 25);
  assert (v->>'ok')::boolean, format('la réservation aurait dû passer, reçu %s', v);
  b := public.get_image_regeneration_budget('cccccccc-0000-0000-0000-0000000000b1');
  assert (b->>'reserved_cents')::int = 25 and (b->>'remaining_cents')::int = v_budget - 25,
    format('la réservation n''est pas comptée : %s', b);

  -- ÉCHEC : tout revient, rien n'est facturé.
  v := public.settle_image_regeneration('cccccccc-0000-0000-0000-0000000000b1', 25, false);
  assert v->>'reason' = 'released', format('un échec doit libérer, reçu %s', v);
  b := public.get_image_regeneration_budget('cccccccc-0000-0000-0000-0000000000b1');
  assert (b->>'reserved_cents')::int = 0 and (b->>'used_cents')::int = 0
     and (b->>'remaining_cents')::int = v_budget,
    format('elle a été facturée pour une photographie qu''elle n''a pas reçue : %s', b);

  -- SUCCÈS : la réservation devient dépense réelle.
  v := public.reserve_image_regeneration('cccccccc-0000-0000-0000-0000000000b1', 25);
  v := public.settle_image_regeneration('cccccccc-0000-0000-0000-0000000000b1', 25, true);
  assert v->>'reason' = 'settled', format('un succès doit régler, reçu %s', v);
  b := public.get_image_regeneration_budget('cccccccc-0000-0000-0000-0000000000b1');
  assert (b->>'used_cents')::int = 25 and (b->>'remaining_cents')::int = v_budget - 25,
    format('après succès : %s', b);

  -- Le plafond refuse, et ne réserve rien en refusant.
  v := public.reserve_image_regeneration('cccccccc-0000-0000-0000-0000000000b1', v_budget - 24);
  assert v->>'reason' = 'budget_exhausted',
    format('un centime de plus que le reste doit être refusé, reçu %s', v);
  b := public.get_image_regeneration_budget('cccccccc-0000-0000-0000-0000000000b1');
  assert (b->>'remaining_cents')::int = v_budget - 25, format('un refus a quand même réservé : %s', b);

  -- Exactement ce qui reste passe, et rien après.
  v := public.reserve_image_regeneration('cccccccc-0000-0000-0000-0000000000b1', v_budget - 25);
  assert (v->>'ok')::boolean, format('le reste exact doit passer, reçu %s', v);
  v := public.reserve_image_regeneration('cccccccc-0000-0000-0000-0000000000b1', 1);
  assert v->>'reason' = 'budget_exhausted', format('un centime de trop doit être refusé, reçu %s', v);
end
$$;

-- ---------------------------------------------------------------------------
-- LES DEUX MÈTRES SONT SÉPARÉS. Régénérer une photographie ne doit pas
-- consommer une régénération de DIRECTION -- elles ne coûtent pas la même
-- chose et elles ne mesurent pas la même chose.
-- ---------------------------------------------------------------------------
do $$
declare v_dirs int; v_regens int;
begin
  reset role;
  select directions_generated, regenerations_used into v_dirs, v_regens
    from public.generation_credits where project_id = 'bbbbbbbb-0000-0000-0000-0000000000b1';
  assert v_dirs = 0 and v_regens = 0,
    format('une régénération de photo a touché le compteur des directions : %s / %s', v_dirs, v_regens);
end
$$;

-- ---------------------------------------------------------------------------
-- Rien de tout cela ne s'ouvre à une autre.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000b2"}';
  v := public.reserve_image_regeneration('cccccccc-0000-0000-0000-0000000000b1', 5);
  assert v->>'reason' = 'payment_required', format('réservation par une inconnue : %s', v);
  v := public.get_image_regeneration_budget('cccccccc-0000-0000-0000-0000000000b1');
  assert v->'error'->>'code' = 'payment_required', format('lecture par une inconnue : %s', v);
end
$$;

reset role;
rollback;
