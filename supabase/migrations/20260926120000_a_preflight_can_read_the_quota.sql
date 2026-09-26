-- ════════════════════════════════════════════════════════════════════════
--  LE PRÉALABLE DOIT POUVOIR LIRE LE QUOTA SANS LE CONSOMMER
-- ════════════════════════════════════════════════════════════════════════
--
-- F45 porte le générateur du harnais sur le chemin produit. Son premier étage
-- est le PRÉALABLE : refuser une génération impossible AVANT la première
-- dépense. Il sait déjà refuser un brief sans mention de licence et une banque
-- trop courte ; il ne sait pas dire « le quota du mois est déjà épuisé ».
--
-- ⚠ ET IL NE DOIT PAS L'APPRENDRE EN RÉSERVANT. `reserve_credit` répond
-- `quota_exhausted`, mais il ÉCRIT une ligne au livre pour le découvrir — et
-- l'invariant `credit_ledger_one_outcome_per_reservation` exige alors un
-- dénouement. Sonder le quota en réservant laisserait une réservation à solder
-- pour une question.
--
-- ── ⚠ ET SURTOUT : ON N'A PAS RECOPIÉ LA BORNE ──────────────────────────
--
-- La tentation était d'écrire la jointure dans le code TypeScript du préalable.
-- Elle aurait été juste le jour de son écriture. La borne vit dans
-- `credit_ledger_apply()`, qui lit `credit_quotas` par `credit_plan_for(user)` ;
-- le compteur vit dans `credit_balances.consumed`. Deux sources, et un troisième
-- lecteur qui les joint à sa façon est un troisième endroit où la règle peut
-- diverger. C'est exactement la classe de F27 — et de F41, où un tirage dérivé
-- d'un ratio tautologique s'est confirmé lui-même pendant deux sessions.
--
-- Cette fonction lit donc LES MÊMES DEUX SOURCES, dans le même ordre, avec la
-- même lecture du NULL. Si la borne change, elle suit.
--
-- ⚠ ELLE ÉCHOUE FERMÉ, comme `credit_ledger_apply`. Un couple (plan, kind)
-- absent de `credit_quotas` rend `remaining = 0`, pas « illimité » :
-- `monthly_limit` vaut NULL pour « illimité » ET pour « pas de ligne », et lire
-- le second comme le premier ouvrirait la dépense à un compte sans droit.

create or replace function public.credit_remaining(
  p_user  uuid,
  p_kind  text,
  p_month date default date_trunc('month', now())::date
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with quota as (
    select q.monthly_limit, true as has_row
      from public.credit_quotas q
     where q.plan = public.credit_plan_for(p_user)
       and q.kind = p_kind
  ),
  used as (
    select coalesce(b.consumed, 0) as consumed
      from public.credit_balances b
     where b.user_id = p_user
       and b.kind = p_kind
       and b.month = date_trunc('month', p_month)::date
  )
  select jsonb_build_object(
    /*
     * ⚠ `unlimited` N'EST VRAI QUE SI LA LIGNE EXISTE ET QUE SA BORNE EST NULL.
     * Sans la ligne, ce n'est pas illimité : c'est un plan qui n'achète pas ce
     * genre de crédit.
     */
    'unlimited',  coalesce((select has_row from quota), false)
                  and (select monthly_limit from quota) is null,
    'limit',      (select monthly_limit from quota),
    'consumed',   coalesce((select consumed from used), 0),
    'remaining',
      case
        when not coalesce((select has_row from quota), false) then 0
        when (select monthly_limit from quota) is null then null
        else greatest(
          0,
          (select monthly_limit from quota) - coalesce((select consumed from used), 0)
        )
      end,
    'month',      date_trunc('month', p_month)::date
  )
$$;

comment on function public.credit_remaining(uuid, text, date) is
  'Le quota restant d''un mois, EN LECTURE SEULE. Lit les deux mêmes sources '
  'que credit_ledger_apply() — credit_quotas par credit_plan_for(), et '
  'credit_balances.consumed — pour qu''un préalable ne puisse pas diverger de la '
  'borne qu''il annonce. Échoue fermé : pas de ligne de quota => remaining 0. '
  'remaining NULL signifie illimité, et unlimited le dit explicitement.';

/*
 * ⚠ `service_role` SEUL. Le préalable tourne côté serveur ; une praticienne n'a
 * pas à interroger le livre de crédit, et `credit_balances` porte déjà des RLS
 * qui le disent. Une fonction `security definer` accordée à `authenticated`
 * serait un contournement de ces policies.
 */
revoke all on function public.credit_remaining(uuid, text, date) from public;
grant execute on function public.credit_remaining(uuid, text, date) to service_role;
