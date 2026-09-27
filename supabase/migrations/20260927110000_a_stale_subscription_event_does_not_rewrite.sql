-- ============================================================================
-- ⚠ UN ÉVÉNEMENT D'ABONNEMENT EN RETARD RÉÉCRIVAIT L'ÉTAT COURANT
-- ============================================================================
--
-- Trouvé le 2026-09-27 en JOUANT le parcours sur la base locale. Stripe ne
-- garantit pas l'ordre de livraison, et le webhook faisait un `upsert` aveugle
-- de l'objet reçu :
--
--   · `deleted` (annulé) puis un `updated` ANTÉRIEUR arrivé en retard →
--     l'abonnement redevenait `active` : accès rouvert, mois mis en file, pour
--     une cliente qui a résilié ;
--   · `updated` (active) puis `created` (incomplete) de la même seconde →
--     l'abonnement redescendait en `incomplete` : plus d'accès, pour une
--     cliente qui vient de payer.
--
-- ── DEUX RÈGLES, PARCE QUE L'HORODATAGE SEUL NE SUFFIT PAS ───────────────
--
-- 1. L'HORODATAGE DE L'ÉVÉNEMENT. `stripe_event_at` porte `event.created` ; un
--    événement strictement plus ancien que celui déjà appliqué ne réécrit rien.
--    Mais Stripe horodate à la SECONDE, et `created` et `updated` partagent
--    souvent la même.
-- 2. LES ÉTATS SANS RETOUR, pour le même `stripe_subscription_id` — des faits
--    de la machine d'états de Stripe, pas des préférences :
--      · `canceled` et `incomplete_expired` sont terminaux ;
--      · on ne revient jamais à `incomplete` après l'avoir quitté.
--
-- Un NOUVEL abonnement (autre `stripe_subscription_id`) sur le même compte
-- passe toujours : la ligne est clé sur `user_id`, et se réabonner après une
-- résiliation est légitime.
--
-- ⚠ LA LIGNE EST GARDÉE, PAS REFUSÉE. Lever ferait rendre 500 au webhook et
-- Stripe rejouerait indéfiniment un événement qui ne sera jamais plus récent.
-- Le trigger rend OLD : l'écriture devient sans effet, l'événement est traité.
alter table public.subscriptions
  add column if not exists stripe_event_at timestamptz;

comment on column public.subscriptions.stripe_event_at is
  'created of the most recent Stripe event applied to this row. An older event does not rewrite it (20260927110000).';

create or replace function public.subscriptions_refuse_stale_event()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if new.stripe_subscription_id is distinct from old.stripe_subscription_id then
    return new;
  end if;

  if new.stripe_event_at is not null and old.stripe_event_at is not null
     and new.stripe_event_at < old.stripe_event_at then
    return old;
  end if;

  if old.status in ('canceled', 'incomplete_expired') and new.status is distinct from old.status then
    return old;
  end if;

  if new.status = 'incomplete' and old.status <> 'incomplete' then
    return old;
  end if;

  -- Une écriture sans horodatage (un cron qui pose une notice) garde le dernier.
  if new.stripe_event_at is null then
    new.stripe_event_at := old.stripe_event_at;
  end if;

  return new;
end
$$;

comment on function public.subscriptions_refuse_stale_event() is
  'Keeps a late Stripe event from rewriting a subscription: an older event, a move out of a terminal state, or a return to incomplete for the same stripe_subscription_id leaves the row as it was. Returns OLD rather than raising, so the webhook answers 2xx and Stripe stops replaying (20260927110000).';

revoke all on function public.subscriptions_refuse_stale_event() from public, anon, authenticated;

drop trigger if exists subscriptions_refuse_stale_event on public.subscriptions;
create trigger subscriptions_refuse_stale_event
  before update on public.subscriptions
  for each row execute function public.subscriptions_refuse_stale_event();
