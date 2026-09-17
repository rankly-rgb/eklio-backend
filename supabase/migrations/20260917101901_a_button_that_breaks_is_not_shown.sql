-- ============================================================================
-- On ne montre pas un bouton qui casse
-- ============================================================================
-- `The Foundation` (390 $) et `The Roster` (690 $) sont `sellable = true` en
-- base, et le lot 3 les fait apparaître au catalogue de l'écran. Ni l'un ni
-- l'autre ne peut aboutir aujourd'hui, pour DEUX raisons indépendantes — et
-- c'est le fait qu'elles soient indépendantes qui compte : réparer l'une
-- laisserait l'autre.
--
--   1. AUCUN PRIX STRIPE. `lib/billing/plans.ts` les déclare sous
--      `STRIPE_PRICE_FOUNDATION` et `STRIPE_PRICE_ROSTER`, deux variables qui
--      ne sont ni dans `.env.example` ni dans l'environnement. Le checkout
--      échoue à la création de la session — après le clic, sur une page
--      d'erreur, pas avant.
--
--   2. AUCUN ÉTAT VÉRIFIÉ. `license_type_states` porte 240 couples et zéro
--      `verified_at`, donc `state_is_sellable` rend false pour les 51 États et
--      `project_state_is_sellable` refuse la génération en 409. Une cliente qui
--      paierait recevrait « We're not open in OR yet » à l'étape suivante.
--
-- Encaisser puis refuser est pire que ne pas vendre. Le premier des deux
-- défauts se voit tout de suite ; le second ne se voit qu'après le paiement.
--
-- ⚠ CE N'EST PAS UN RETRAIT DE L'OFFRE. `sellable` est lu par le CHEMIN DE
-- CHECKOUT, pas par l'affichage : la ligne reste au catalogue, avec son prix et
-- son libellé, et c'est la porte qui est fermée. Rouvrir est un UPDATE, pas un
-- déploiement — c'est exactement pour ça que la colonne existe
-- (`20260914091622_a_sku_that_cannot_be_delivered_cannot_be_sold`).
--
-- ── CE QU'IL FAUT VÉRIFIER POUR ROUVRIR ─────────────────────────────────
--
-- Les trois, ensemble, et chacune se lit en une requête :
--
--   a) le prix existe des deux côtés :
--        STRIPE_PRICE_FOUNDATION et STRIPE_PRICE_ROSTER dans l'environnement
--        de production, pointant sur des prix Stripe actifs en mode LIVE
--        (les quatre achats de test portent des `cs_test_…` ; personne n'a
--        encore encaissé un dollar réel).
--
--   b) au moins un État est vendable :
--        select count(*) from public.sellable_states where sellable;
--      Aujourd'hui : 0. Il faut au moins un État dont TOUS les couples sont
--      vérifiés — c'est la définition de `state_is_sellable`, pas une
--      approximation.
--
--   c) la plateforme peut recevoir une publication :
--        select id from public.site_platforms where status = 'accepted';
--      Aujourd'hui : wordpress, et lui seul. Les deux SKU portent
--      `requires_publishable_platform = true`, donc une cliente sur Wix,
--      Squarespace ou sans site ne peut pas les acheter même une fois (a) et
--      (b) réglés — et c'est voulu : ils promettent une publication.
--
-- Quand les trois tiennent, la réouverture est :
--   update public.plans set sellable = true where tier in ('foundation','roster');
-- dans une migration neuve qui REVÉRIFIE (a), (b) et (c) avant de le faire.
-- ============================================================================

-- >>> FOUNDATION AND ROSTER CLOSED (mirrored verbatim in supabase/seed.sql) >>>

update public.plans set sellable = false
 where tier = any (array['foundation', 'roster']);

-- <<< FOUNDATION AND ROSTER CLOSED <<<

/*
 * ⚠ ET LE COMMENTAIRE DE LA COLONNE SUIT, PARCE QU'UN TEST L'EXIGE.
 * `20260914190000_sellability.test.sql` vérifie que le commentaire de
 * `plans.sellable` NOMME le propriétaire de chaque ligne fermée : « la colonne
 * dit QUE la vente est refusée ; le commentaire est le seul endroit qui dit QUI
 * la rouvre ». Fermer deux lignes de plus sans toucher au commentaire les
 * laisserait fermées sans propriétaire — ce que ce test appelle un TODO, et un
 * TODO ne rouvre rien.
 */
comment on column public.plans.sellable is
  'False when this SKU cannot be delivered yet, read by the CHECKOUT PATH before any call to Stripe - not by the display, which may still show a price, and not by a CHECK on purchases, which would arrive after the money moved and would lose the record rather than refuse the sale. FIVE rows are false today. roster_seat: a bought seat delivers nothing until a clinician arrives and triggers her pack (L21 flips it back). fill_solo: sells a monthly content cycle that does not exist (L18). fill_practice: needs that cycle AND per-seat quantity on the subscription line (L18 and L20, both). foundation and roster: no Stripe price is configured (STRIPE_PRICE_FOUNDATION / STRIPE_PRICE_ROSTER are absent from the environment) and no state is verified, so the generation that follows payment answers 409 - they reopen when both hold, in a fresh migration that re-checks them. The owning lot flips its own row back to true in its own migration.';


do $$
declare v_n int; v_open text;
begin
  select count(*) into v_n from public.plans
   where tier = any (array['foundation', 'roster']) and not sellable;
  if v_n <> 2 then
    raise exception
      'closed: % des 2 SKU de la nouvelle offre sont fermés. Un tier renommé rouvrirait une porte qui ne mène nulle part.', v_n;
  end if;

  /*
   * ⚠ ET LES CINQ LIGNES DE L'ANCIENNE OFFRE RESTENT OUVERTES. Fermer trop est
   * un défaut symétrique de fermer trop peu, et il ne lèverait rien non plus :
   * le catalogue paraîtrait simplement vide. Elles n'ont ni prix manquant ni
   * promesse de publication — starter, practice et signature encaissent
   * aujourd'hui, en mode test, avec un prix Stripe configuré.
   */
  select string_agg(tier, ', ' order by sort_order) into v_open
    from public.plans
   where sellable and tier = any (array['free','starter','practice','signature','identity_addon']);
  if v_open is distinct from 'free, starter, practice, signature, identity_addon' then
    raise exception
      'closed: les lignes ouvertes de l''ancienne offre sont « % » et non les cinq attendues.', coalesce(v_open, '(aucune)');
  end if;

  -- Et les trois déjà fermées le restent : un lot ne rouvre pas le précédent.
  select count(*) into v_n from public.plans
   where tier = any (array['roster_seat','fill_solo','fill_practice']) and not sellable;
  if v_n <> 3 then
    raise exception 'closed: les trois SKU non livrables ne sont plus tous fermés (%).', v_n;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   update public.plans set sellable = true where tier in ('foundation','roster');
--   — et ne le faites que si (a), (b) et (c) ci-dessus tiennent.
