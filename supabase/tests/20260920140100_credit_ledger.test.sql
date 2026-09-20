-- ============================================================================
-- Tests — le chokepoint Monthly Presence et le ledger, vus DEPUIS UN CLIENT
-- ============================================================================
-- Les deux migrations du 20 septembre portent déjà des garde-fous, et ils sont
-- copieux. Ce fichier ne les répète pas : il pose les questions qu'une sonde
-- de migration ne PEUT pas poser, parce qu'elle s'exécute en propriétaire.
--
--   * la RLS, telle qu'un appelant `authenticated` la subit — le ledger d'une
--     autre est-il visible, et la sienne l'est-elle ;
--   * `monthly_presence_entitled()` sous une vraie identité JWT, y compris
--     l'appelant anonyme ;
--   * `credit_meter()` sous la même identité, et l'illimité rendu en NULL
--     plutôt qu'en nombre ;
--   * l'isolation entre deux utilisatrices : le plafond de l'une n'est pas
--     celui de l'autre.
--
-- ⚠ POURQUOI ÇA NE PEUT PAS ÊTRE DANS LA MIGRATION. Un bloc `do $$` de
-- migration tourne en propriétaire de la base, qui contourne la RLS. Y écrire
-- « la RLS refuse » prouverait seulement que le propriétaire n'a pas essayé.
-- Ici on `set local role authenticated` et on pose le claim `sub`, ce qui est
-- la seule façon de faire répondre `auth.uid()` autre chose que NULL.
-- ============================================================================
begin;

-- ── Deux utilisatrices, l'une comp, l'autre rien du tout ──────────────────
create temporary table _probe (k text primary key, v uuid) on commit drop;

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_r jsonb;
begin
  insert into auth.users (id, email) values (v_a, 'ledger-a@example.invalid');
  insert into auth.users (id, email) values (v_b, 'ledger-b@example.invalid');
  insert into _probe values ('a', v_a), ('b', v_b);

  -- A est comp : le produit payant complet, sans ligne Stripe.
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_a, 'test du ledger', 'supabase/tests', now() + interval '1 day');

  -- B n'a rien : ni abonnement, ni octroi.
  if public.check_monthly_presence_entitlement(v_b) then
    raise exception 'B n''a rien acheté et le chokepoint l''a laissée passer.';
  end if;

  -- A dépense, B est refusée. Même appel, deux réponses.
  v_r := public.reserve_credit(v_a, 'regeneration', 'A régénère');
  assert (v_r ->> 'ok')::boolean, format('A a été refusée : %s', v_r);
  insert into _probe values ('a_res', (v_r ->> 'reservation_id')::uuid);

  v_r := public.reserve_credit(v_b, 'regeneration', 'B régénère');
  assert (v_r ->> 'reason') = 'not_entitled',
    format('B a obtenu un crédit sans droit : %s', v_r);
end $$;


-- ============================================================================
-- 1. La RLS : chacune voit sa ligne, et seulement la sienne
-- ============================================================================
do $$
declare
  v_a uuid := (select v from _probe where k = 'a');
  v_b uuid := (select v from _probe where k = 'b');
  v_n integer;
begin
  -- ── A, signée ───────────────────────────────────────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a)::text, true);

  select count(*) into v_n from public.credit_ledger;
  assert v_n = 1, format('A voit %s ligne(s) de ledger, elle en a écrit 1', v_n);

  select count(*) into v_n from public.credit_balances;
  assert v_n = 1, format('A voit %s solde(s), elle en a 1', v_n);

  -- ⚠ ET ELLE NE VOIT PAS CELUI DE B. Pas « B n'a rien écrit » : on repose la
  -- question sur l'identifiant de B explicitement, pour que l'assertion porte
  -- sur la policy et pas sur l'absence de données.
  select count(*) into v_n from public.credit_ledger where user_id = v_b;
  assert v_n = 0, 'A voit des lignes au nom de B';

  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- ── B, signée, et le ledger de A lui est invisible ─────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b)::text, true);

  select count(*) into v_n from public.credit_ledger;
  assert v_n = 0, format('B voit %s ligne(s) de ledger de quelqu''un d''autre', v_n);

  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- ── Personne, non signée ────────────────────────────────────────────────
  set local role anon;
  perform set_config('request.jwt.claims', null, true);

  select count(*) into v_n from public.credit_ledger;
  assert v_n = 0, format('un appelant anonyme voit %s ligne(s) de ledger', v_n);

  reset role;
end $$;


-- ============================================================================
-- 2. Un client ne peut ni écrire ni effacer le journal
-- ============================================================================
-- Les policies disent `false` ; ce test le vérifie du côté où ça compte.
do $$
declare
  v_a    uuid := (select v from _probe where k = 'a');
  v_rows integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a)::text, true);

  begin
    insert into public.credit_ledger (user_id, kind, entry_type, delta, reason, month)
    values (v_a, 'custom_visual', 'release', 1, 'je me rends un crédit',
            date_trunc('month', now())::date);
    reset role;
    raise exception 'une cliente a pu s''écrire un crédit dans le journal.';
  exception when insufficient_privilege then null;
  end;

  -- ⚠ UN UPDATE REFUSÉ PAR POLICY NE LÈVE PAS : il ne touche AUCUNE LIGNE.
  -- C'est la différence qui rend ce cas piégeux, et c'est pourquoi on compte
  -- les lignes touchées plutôt que d'attendre une exception.
  update public.credit_ledger set reason = 'réécrit';
  get diagnostics v_rows = row_count;
  assert v_rows = 0, format('une cliente a réécrit %s ligne(s) du journal', v_rows);

  delete from public.credit_ledger;
  get diagnostics v_rows = row_count;
  assert v_rows = 0, format('une cliente a effacé %s ligne(s) du journal', v_rows);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;


-- ============================================================================
-- 3. `monthly_presence_entitled()` et `credit_meter()` sous une vraie identité
-- ============================================================================
do $$
declare
  v_a uuid := (select v from _probe where k = 'a');
  v_b uuid := (select v from _probe where k = 'b');
  v_m jsonb;
begin
  -- ── A : comp actif, donc ouverte ───────────────────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a)::text, true);

  assert public.monthly_presence_entitled(),
    'A est comp et monthly_presence_entitled() rend faux';

  v_m := public.credit_meter();

  -- ⚠ L'ILLIMITÉ EST NULL, PAS UN NOMBRE. La PHASE 5.5 imprime un mot à cet
  -- endroit ; un grand nombre y ferait afficher un plafond qui n'existe pas.
  assert v_m #> '{swap,limit}' = 'null'::jsonb,
    format('le plafond de swap devrait être null (illimité), il vaut %s', v_m #> '{swap,limit}');
  assert v_m #> '{swap,remaining}' = 'null'::jsonb,
    'un reste chiffré a été calculé pour un plafond illimité';

  assert (v_m #>> '{regeneration,limit}')::integer = 10,
    format('plafond de régénération inattendu : %s', v_m #>> '{regeneration,limit}');
  assert (v_m #>> '{regeneration,consumed}')::integer = 1,
    format('A a réservé une régénération, le compteur dit %s', v_m #>> '{regeneration,consumed}');
  assert (v_m #>> '{regeneration,remaining}')::integer = 9,
    format('reste inattendu : %s', v_m #>> '{regeneration,remaining}');

  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- ── B : rien, donc fermée — et son compteur est à zéro, pas absent ──────
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b)::text, true);

  assert not public.monthly_presence_entitled(),
    'B n''a rien et monthly_presence_entitled() rend vrai';

  v_m := public.credit_meter();
  assert (v_m #>> '{regeneration,consumed}')::integer = 0,
    format('le compteur de B n''est pas vierge : %s', v_m);

  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- ── Personne ────────────────────────────────────────────────────────────
  -- ⚠ DEUX REFUS DIFFÉRENTS, ET IL FAUT LES DEUX.
  --
  -- `anon` n'a pas le droit d'EXÉCUTER la fonction : le refus est un refus de
  -- privilège, pas une réponse `false`. C'est voulu — un visiteur non
  -- authentifié n'a aucune raison de poser la question — et c'est autre chose
  -- que le second cas.
  set local role anon;
  begin
    perform public.monthly_presence_entitled();
    reset role;
    raise exception 'anon a pu exécuter monthly_presence_entitled.';
  exception when insufficient_privilege then null;
  end;
  reset role;

  -- Le second cas : un rôle qui A le droit d'appeler, mais aucune identité
  -- derrière. `auth.uid()` est NULL, et la réponse doit être FALSE — jamais
  -- NULL, qu'un appelant lirait comme « on ne sait pas » et qu'un `if` en
  -- TypeScript lirait comme faux par accident plutôt que par règle.
  set local role authenticated;
  perform set_config('request.jwt.claims', null, true);
  assert public.monthly_presence_entitled() is false,
    'sans identité, monthly_presence_entitled() ne rend pas false';
  assert public.credit_meter() = '{}'::jsonb,
    'sans identité, credit_meter() ne rend pas un objet vide';
  reset role;
end $$;


-- ============================================================================
-- 4. Un client ne peut pas sonder le droit d'autrui
-- ============================================================================
-- Le cœur de la forme à deux fonctions. `check_monthly_presence_entitlement`
-- prend un uuid quelconque ; ouverte, elle répondrait « cette personne est-elle
-- abonnée » sur n'importe quel compte dont on devine l'identifiant.
do $$
declare
  v_a uuid := (select v from _probe where k = 'a');
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a)::text, true);

  begin
    perform public.check_monthly_presence_entitlement(v_a);
    reset role;
    raise exception 'une cliente a pu appeler check_monthly_presence_entitlement.';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.credit_plan_for(v_a);
    reset role;
    raise exception 'une cliente a pu appeler credit_plan_for.';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.reserve_credit(v_a, 'custom_visual', 'je me sers');
    reset role;
    raise exception 'une cliente a pu appeler reserve_credit directement.';
  exception when insufficient_privilege then null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;


-- ============================================================================
-- 5. Le plafond de l'une n'est pas celui de l'autre
-- ============================================================================
do $$
declare
  v_a uuid := (select v from _probe where k = 'a');
  v_c uuid := gen_random_uuid();
  v_r jsonb;
  v_i integer;
begin
  insert into auth.users (id, email) values (v_c, 'ledger-c@example.invalid');
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_c, 'test du ledger', 'supabase/tests', now() + interval '1 day');

  -- A épuise son mois (1 déjà consommée, 9 de plus).
  for v_i in 1..9 loop
    v_r := public.reserve_credit(v_a, 'regeneration', 'A remplit');
    assert (v_r ->> 'ok')::boolean, format('A refusée au tour %s : %s', v_i, v_r);
  end loop;
  v_r := public.reserve_credit(v_a, 'regeneration', 'la onzième de A');
  assert (v_r ->> 'reason') = 'quota_exhausted',
    format('A a obtenu une onzième régénération : %s', v_r);

  -- C, elle, n'a rien dépensé.
  v_r := public.reserve_credit(v_c, 'regeneration', 'C régénère');
  assert (v_r ->> 'ok')::boolean,
    format('le plafond de A a fermé celui de C : %s', v_r);
end $$;


-- ============================================================================
-- 6. La grâce de trois jours, épinglée des deux côtés
-- ============================================================================
-- ⚠ LE NOMBRE EXISTE DEUX FOIS, ET C'EST ASSUMÉ. La décision est ici ; mais
-- `lib/billing/entitlements.ts` garde `PAST_DUE_GRACE_DAYS = 3` pour choisir
-- un TEXTE sans aller-retour réseau sur `/app/checkout/success`.
--
-- Deux copies d'un même nombre veulent deux épingles qui se nomment l'une
-- l'autre. Celle-ci tient le côté base ; `entitlements-single-source.test.ts`
-- (frontend) tient l'autre. Si la règle commerciale change par migration sans
-- que la constante suive, l'écran et le portefeuille diront deux choses
-- différentes — et une des deux épingles tombera d'abord.
do $$
declare
  v_user uuid := gen_random_uuid();
begin
  assert public.monthly_presence_past_due_grace() = interval '3 days',
    format('la grâce vaut %s, et lib/billing/entitlements.ts dit 3 jours',
           public.monthly_presence_past_due_grace());

  -- Et elle est bien CELLE QUI EST APPLIQUÉE, pas seulement celle qui est
  -- déclarée : la borne est probée à un jour de part et d'autre.
  insert into auth.users (id, email) values (v_user, 'grace@example.invalid');
  insert into public.subscriptions (user_id, stripe_subscription_id, status, current_period_end)
  values (v_user, 'sub_grace_test', 'past_due', now() - interval '2 days');
  assert public.check_monthly_presence_entitlement(v_user),
    'une période finie il y a deux jours devrait tenir dans une grâce de trois';

  update public.subscriptions
     set current_period_end = now() - interval '4 days'
   where user_id = v_user;
  assert not public.check_monthly_presence_entitlement(v_user),
    'une période finie il y a quatre jours a survécu à une grâce de trois';
end $$;


-- ============================================================================
-- 7. Le catalogue de quotas est lisible, et immuable depuis un client
-- ============================================================================
do $$
declare
  v_a    uuid := (select v from _probe where k = 'a');
  v_n    integer;
  v_rows integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a)::text, true);

  select count(*) into v_n from public.credit_quotas;
  assert v_n = 8, format('le catalogue de quotas montre %s lignes, attendu 8', v_n);

  update public.credit_quotas set monthly_limit = 9999;
  get diagnostics v_rows = row_count;
  assert v_rows = 0, format('une cliente a relevé %s plafond(s)', v_rows);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

rollback;

-- ⚠ APRÈS LE ROLLBACK : rien n'est resté. Le journal refuse DELETE, donc un
-- test qui laisserait des lignes derrière lui ne pourrait pas les reprendre —
-- il faudrait supprimer les comptes. La transaction annulée est la seule
-- forme sûre pour ce fichier, et on le vérifie plutôt que de le supposer.
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.credit_ledger l
    join auth.users u on u.id = l.user_id
   where u.email like 'ledger-%@example.invalid';
  assert v_n = 0, format('le test a laissé %s ligne(s) de journal hors de sa transaction', v_n);
end $$;
