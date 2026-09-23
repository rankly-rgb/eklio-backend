-- ============================================================================
-- Eklio — tout appel payant est dans le livre
-- ============================================================================
--
-- ⚠ MESURÉ : DIX MOIS, TROIS CENTS POSTS, `credit_ledger` INCHANGÉ.
--
-- Le 2026-09-23, après dix générations mensuelles, le livre de crédits portait
-- toujours ses 844 lignes du 21. Le chemin Batch ne réservait rien (F25), et
-- il est LE chemin de production : le synchrone ne sert qu'au premier mois
-- d'un compte, « une nouvelle abonnée n'attend pas trente minutes ».
--
-- Ce trou est bouché côté TypeScript. Mais en le bouchant, trois autres
-- appels payants se sont révélés n'être dans aucun compteur :
--
--   * la RÉPARATION d'un payload qui dépasse son budget de mots ;
--   * la DÉRIVATION DES THÈMES depuis le bilan mensuel ;
--   * le JUGE DE COMPLÉTUDE, ajouté le 24 pour les contrôles de F26.
--
-- Et un quatrième, plus gros, n'y était jamais entré : la GÉNÉRATION DE KIT.
-- C'est la seule ligne du total d'une session qu'on ne savait pas prouver.
--
-- ── ⚠ CES APPELS NE CONSOMMENT PAS DE CRÉDIT, ET DOIVENT ÊTRE AU LIVRE ──
--
-- Un crédit est un post que la praticienne a acheté. Une réparation, un juge,
-- une dérivation de thèmes sont des FRAIS GÉNÉRAUX : les facturer prendrait à
-- la cliente un post qu'elle n'a pas eu. Mais ne pas les écrire du tout, c'est
-- exactement le défaut qu'on répare — une dépense qui n'apparaît nulle part.
--
-- D'où un `kind` de plus, `overhead`, qui prend ZÉRO crédit et porte son coût.
-- `swap` faisait déjà ça (delta 0, quota illimité) ; réutiliser son nom pour
-- un juge de syntaxe aurait rendu le livre illisible.
-- ============================================================================

-- ── 1. Le nouveau genre, et sa gratuité inscrite dans la table ───────────

alter table public.credit_ledger drop constraint if exists credit_ledger_kind_check;
alter table public.credit_ledger
  add constraint credit_ledger_kind_check
  check (kind in ('post_generation', 'swap', 'regeneration', 'custom_visual', 'overhead'));

-- ⚠ LA GRATUITÉ EST UNE CONTRAINTE, PAS UNE CONVENTION. `credit_ledger` a
-- déjà `credit_ledger_swap_is_free_check` pour la même raison : une ligne
-- d'overhead à delta -1 prendrait un post à quelqu'un, et aucune relecture de
-- code ne rattrape ça aussi sûrement qu'un CHECK.
alter table public.credit_ledger drop constraint if exists credit_ledger_overhead_is_free_check;
alter table public.credit_ledger
  add constraint credit_ledger_overhead_is_free_check
  check (kind <> 'overhead' or delta = 0);

comment on constraint credit_ledger_overhead_is_free_check on public.credit_ledger is
  'Overhead entries carry their cost and take no credit. A credit is a post the practitioner bought; a repair, a completeness judge or a theme derivation is not one, and charging her for it would take away a post she never got.';

-- ── 2. La ligne de quota, sans quoi le garde échoue fermé ────────────────
--
-- ⚠ `credit_ledger_apply()` LÈVE EK011 QUAND LE COUPLE (plan, kind) MANQUE,
-- et c'est voulu : `credit_monthly_limit` rend NULL pour « illimité » ET pour
-- « pas de ligne », et lire le second comme le premier rendrait un `kind`
-- mal orthographié gratuit et infini. Il faut donc la poser pour chaque plan.

-- ── ⚠ LA LISTE DES GENRES VIT DANS TROIS TABLES, ET IL FAUT LES TROIS ───
--
-- Trouvé en deux échecs successifs du même rejeu, pas en relisant :
--
--   1. `credit_quotas_kind_check` → l'insertion de la ligne de quota échoue ;
--   2. `credit_balances_kind_check` → `reserve_credit` échoue à la PREMIÈRE
--      réservation, sur un message qui ne parle pas de genre.
--
-- ⚠ C'EST LA MÊME CLASSE DE DÉFAUTS QUE F18 À F25 : une valeur juste, écrite
-- à un endroit, pas lue aux autres. La requête qui les trouve tient en une
-- ligne et n'avait jamais été posée :
--
--   select conrelid::regclass, conname from pg_constraint
--    where pg_get_constraintdef(oid) like '%post_generation%';

alter table public.credit_quotas drop constraint if exists credit_quotas_kind_check;
alter table public.credit_quotas
  add constraint credit_quotas_kind_check
  check (kind in ('post_generation', 'swap', 'regeneration', 'custom_visual', 'overhead'));

alter table public.credit_balances drop constraint if exists credit_balances_kind_check;
alter table public.credit_balances
  add constraint credit_balances_kind_check
  check (kind in ('post_generation', 'swap', 'regeneration', 'custom_visual', 'overhead'));

insert into public.credit_quotas (plan, kind, monthly_limit)
select p.plan, 'overhead', null
  from (select distinct plan from public.credit_quotas) p
on conflict (plan, kind) do nothing;

-- ── 3. Le point d'étranglement accepte le genre, et le garde gratuit ─────

create or replace function public.reserve_credit(
  p_user uuid,
  p_kind text,
  p_reason text,
  p_ref_type text default null,
  p_ref_id uuid default null,
  p_estimated_cost_usd numeric default null,
  p_provider text default null,
  p_model text default null,
  p_month date default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, now()))::date;
  v_id    uuid;
  v_delta integer;
begin
  if p_user is null then
    return jsonb_build_object('ok', false, 'reason', 'no_user');
  end if;

  if p_kind is null
     or p_kind not in ('post_generation', 'swap', 'regeneration', 'custom_visual', 'overhead') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_kind');
  end if;

  -- ⚠ THE CHOKEPOINT. Comp grants are already inside it.
  if not public.check_monthly_presence_entitlement(p_user) then
    return jsonb_build_object('ok', false, 'reason', 'not_entitled');
  end if;

  if p_estimated_cost_usd is not null and p_estimated_cost_usd < 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_cost');
  end if;

  -- A swap takes nothing; overhead takes nothing; everything else takes one.
  v_delta := case when p_kind in ('swap', 'overhead') then 0 else -1 end;

  begin
    insert into public.credit_ledger
      (user_id, kind, entry_type, delta, reason, ref_type, ref_id, month,
       estimated_cost_usd, provider, model)
    values
      (p_user, p_kind, 'reservation', v_delta, coalesce(nullif(btrim(p_reason), ''), p_kind),
       p_ref_type, p_ref_id, v_month,
       case when p_kind = 'swap' then null else p_estimated_cost_usd end,
       p_provider, p_model)
    returning id into v_id;
  exception
    -- ⚠ ONLY THE TWO CODES credit_ledger_apply() RAISES, NEVER
    -- `check_violation` WHOLESALE. The first version caught check_violation,
    -- and the guard rail below caught it doing so: a malformed call (a
    -- ref_type with no ref_id, which the row's own CHECK refuses) came back to
    -- the caller as `quota_exhausted`. That is a lie about her account, and it
    -- would have sent someone to a checkout page to buy credits she already
    -- had. A shape violation is a programming error and must keep crossing
    -- the boundary as one.
    when sqlstate 'EK010' then
      return jsonb_build_object('ok', false, 'reason', 'quota_exhausted',
                                'kind', p_kind, 'month', v_month);
    when sqlstate 'EK011' then
      return jsonb_build_object('ok', false, 'reason', 'no_quota_configured',
                                'kind', p_kind);
  end;

  return jsonb_build_object('ok', true, 'reason', 'reserved',
                            'reservation_id', v_id, 'month', v_month);
end
$$;

comment on function public.reserve_credit(uuid, text, text, text, uuid, numeric, text, text, date) is
  'The only door to a paid call. Every path -- batch, synchronous, repair, theme derivation, completeness judge, kit generation -- goes through it, and the quota ceiling is enforced by credit_ledger_apply() in the same statement that moves the number. `overhead` takes no credit and still books its cost: a dollar spent nowhere in the book is the defect F18 through F25 kept finding.';

-- ── 4. Ce qu'un mois doit faire grossir, en une requête ──────────────────
--
-- ⚠ ELLE N'AVAIT JAMAIS ÉTÉ POSÉE, et c'est pour ça que dix mois ont pu ne
-- rien écrire. Une vue rend la vérification triviale, donc faisable à chaque
-- mise en production plutôt qu'une fois par incident.

create or replace view public.credit_month_audit as
  select l.user_id,
         l.month,
         l.kind,
         count(*) filter (where l.entry_type = 'reservation') as reservations,
         count(*) filter (where l.entry_type = 'settlement')  as settlements,
         count(*) filter (where l.entry_type = 'release')     as releases,
         sum(coalesce(l.actual_cost_usd, l.estimated_cost_usd, 0))::numeric(12, 5) as cost_usd
    from public.credit_ledger l
   group by l.user_id, l.month, l.kind;

comment on view public.credit_month_audit is
  'One row per (user, month, kind): how many reservations, settlements and releases, and what they cost. A generated month must show thirty post_generation reservations; if it shows none, no credit was taken and the counter is not counting.';

-- ⚠ La vue hérite de la RLS de `credit_ledger` (security_invoker), donc une
-- cliente n'y voit que ses lignes. Sans ce réglage une vue est lue avec les
-- droits de son PROPRIÉTAIRE, et celle-ci ouvrirait le livre entier.
alter view public.credit_month_audit set (security_invoker = on);
