-- ============================================================================
-- ⚠ LES TROIS MOIS INCLUS DANS SIGNATURE SONT PAYÉS, ET LE QUOTA LES LISAIT
--   COMME UN ESSAI GRATUIT
-- ============================================================================
--
-- Trouvé le 2026-09-27 en JOUANT le parcours Stripe sur la base locale (cas F54,
-- « les deux bouts s'accordent-ils réellement ») :
--
--   · le webhook reçoit l'achat Signature (249 $), crée chez Stripe l'abonnement
--     des trois mois inclus avec `trial_period_days: 90`, et pose la ligne du
--     mois suivant en `generating` ;
--   · `credit_plan_for` voit `subscriptions.status = 'trialing'` et rend `trial` ;
--   · `credit_quotas(trial, post_generation)` vaut 8 ; le mois en promet 30 ;
--   · l'énumération des dues l'écarte (« quota épuisé : 8 pour 30 ») et le
--     préalable le refuserait pour la même raison.
--
-- La ligne payée restait donc en `generating` pour toujours, sur la cliente qui
-- a payé le plus cher. Chaque bout avait son test, et chaque test passait.
--
-- ── POURQUOI LA CORRECTION EST ICI ET PAS DANS LE QUOTA ─────────────────
--
-- Le quota d'essai est juste pour ce qu'il décrit : « a trial that has not
-- charged a card yet ». Ce qui était faux, c'est d'appeler essai un abonnement
-- `trialing` que la cliente a PAYÉ. Dans ce produit, `trial_period_days` n'est
-- posé qu'à un seul endroit — `grantIncludedMonthlyPresence`, pour Signature —
-- mais la règle ne s'appuie pas sur ce fait : elle demande l'achat lui-même.
--
-- Un achat Signature ENTITLING (`paid`, `partially_refunded` — la liste de
-- `lib/billing/entitlements.ts` et de 20260830062227) rend le plan `standard`.
-- Remboursé ou contesté, il cesse de compter et l'essai redevient un essai.
create or replace function public.credit_plan_for(p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    -- A comp grant is the full paid product, so it is never on trial credits.
    when public.comp_grant_active(p_user) then 'standard'
    -- ⚠ A trial she paid for is not a trial: Signature's three included months.
    when exists (
      select 1 from public.purchases pu
       where pu.user_id = p_user
         and pu.tier = 'signature'
         and pu.status in ('paid', 'partially_refunded')
    ) then 'standard'
    when exists (
      select 1 from public.subscriptions s
       where s.user_id = p_user and s.status = 'trialing'
    ) then 'trial'
    else 'standard'
  end
$$;

comment on function public.credit_plan_for(uuid) is
  'Which row of credit_quotas applies to this user: trial while the Stripe subscription is trialing AND nothing paid covers it; standard otherwise -- for a comp grant, and for an entitling Signature purchase, whose three included months are a paid trial (20260927100000). Derived, never stored. INTERNAL ONLY.';

revoke all on function public.credit_plan_for(uuid) from public, anon, authenticated;
