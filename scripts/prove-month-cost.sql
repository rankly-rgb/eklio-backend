-- ============================================================================
-- VÉRIFICATION 6.6 — ce qu'un mois de 30 publications coûte VRAIMENT
-- ============================================================================
-- ⚠ LE CHIFFRE EST AGRÉGÉ DEPUIS `credit_ledger`, PAS CALCULÉ ICI.
--
-- Ce script simule un mois pour une utilisatrice fictive : il réserve un
-- crédit par publication AVANT l'appel, règle chacun APRÈS avec le coût réel
-- que le modèle de facturation donne, et lit ensuite `content_month_cost`.
--
-- Il ne calcule donc pas le total : il fait passer la dépense par le même
-- chemin que la production, et relit ce que ce chemin a enregistré. Un script
-- qui additionnerait lui-même prouverait que son arithmétique est juste, ce qui
-- n'est pas la question.
--
-- ── LE MODÈLE DE COÛT, ET D'OÙ VIENNENT SES NOMBRES ─────────────────────
--
-- Haiku 4.5, en Batch (-50 % entrée et sortie), avec prompt caching.
--   entrée         1,00 $ / MTok
--   sortie         5,00 $ / MTok
--   lecture cache  0,1 × entrée
--   écriture cache 1,25 × entrée
--
-- Par carte, mesuré sur les gabarits de `lib/content/generate/copy-batch.ts` :
--   ~1200 tokens de préfixe (marque, six règles, format, schéma d'archétype)
--   ~60 tokens de partie variable (le sujet, le check-in)
--   ~300 tokens de sortie (payload + caption + alt + rationale)
--
-- La PREMIÈRE carte écrit le cache ; les vingt-neuf suivantes le lisent. C'est
-- tout l'intérêt d'un préfixe stable, et c'est ce que le total ci-dessous
-- mesure.
-- ============================================================================
\set ON_ERROR_STOP on
begin;

create temporary table cost_probe (k text primary key, v uuid) on commit drop;

do $$
declare
  v_user uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_user, 'cost-proof@example.invalid');
  -- Comp plutôt qu'un abonnement fabriqué : `subscriptions.stripe_subscription_id`
  -- est `not null unique`, et inventer un identifiant Stripe pour une preuve de
  -- coût serait exactement le piège que `comp_grants` existe pour éviter.
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_user, 'cost proof', 'scripts/prove-month-cost.sql', now() + interval '1 day');
  insert into cost_probe values ('user', v_user);
end $$;


-- ============================================================================
-- Le mois : trente réservations, trente règlements
-- ============================================================================
do $$
declare
  v_user       uuid := (select v from cost_probe where k = 'user');
  v_month      date := date_trunc('month', now())::date;
  i            integer;
  v_res        jsonb;
  -- $/MTok
  c_in         numeric := 1.0;
  c_out        numeric := 5.0;
  c_batch      numeric := 0.5;
  c_cache_read numeric := 0.1;
  c_cache_wr   numeric := 1.25;
  -- tokens per card
  t_prefix     integer := 1200;
  t_variable   integer := 60;
  t_output     integer := 300;
  v_actual     numeric;
  v_estimated  numeric;
begin
  -- L'estimation vaut pour toutes : elle est faite AVANT de savoir si le cache
  -- a servi, donc elle suppose le pire (préfixe payé plein tarif).
  v_estimated :=
      (t_prefix + t_variable)::numeric / 1e6 * c_in  * c_batch
    + t_output::numeric                     / 1e6 * c_out * c_batch;

  for i in 1..30 loop
    v_res := public.reserve_credit(
      v_user, 'post_generation', 'month card ' || i,
      'content_topic', gen_random_uuid(),
      v_estimated, 'anthropic', 'claude-haiku-4-5-20251001', v_month
    );

    if not (v_res ->> 'ok')::boolean then
      raise exception 'la réservation % a été refusée: %', i, v_res;
    end if;

    -- Le coût réel: la première carte écrit le cache, les suivantes le lisent.
    if i = 1 then
      v_actual :=
          t_prefix::numeric   / 1e6 * c_in * c_cache_wr   * c_batch
        + t_variable::numeric / 1e6 * c_in                * c_batch
        + t_output::numeric   / 1e6 * c_out               * c_batch;
    else
      v_actual :=
          t_prefix::numeric   / 1e6 * c_in * c_cache_read * c_batch
        + t_variable::numeric / 1e6 * c_in                * c_batch
        + t_output::numeric   / 1e6 * c_out               * c_batch;
    end if;

    perform public.settle_credit((v_res ->> 'reservation_id')::uuid, v_actual, true);
  end loop;
end $$;


-- ============================================================================
-- Le rapport, relu depuis le ledger
-- ============================================================================
\echo ''
\echo '== PREUVE DE COÛT — un mois de 30 publications =='
\echo ''

select
  jsonb_pretty(public.content_month_cost(
    (select v from cost_probe where k = 'user'),
    date_trunc('month', now())::date
  )) as "ventilation par poste";

select
  count(*)                                   as "entrées de journal",
  count(*) filter (where entry_type = 'reservation') as "réservations",
  count(*) filter (where entry_type = 'settlement')  as "règlements",
  count(*) filter (where entry_type = 'release')     as "libérations",
  round(sum(estimated_cost_usd), 6)          as "estimé $",
  round(sum(actual_cost_usd), 6)             as "réel $",
  round(sum(estimated_cost_usd) - sum(actual_cost_usd), 6) as "écart $",
  round(sum(actual_cost_usd) / 30, 6)        as "réel $ / publication"
from public.credit_ledger
where user_id = (select v from cost_probe where k = 'user');

\echo ''
\echo '-- Le rendu vectoriel est absent de ce tableau parce qu''il ne coûte rien :'
\echo '-- ni appel d''API, ni crédit. C''est le fait central du chantier, et son'
\echo '-- absence ici EST la mesure.'
\echo ''

rollback;
