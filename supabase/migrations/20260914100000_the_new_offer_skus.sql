-- ============================================================================
-- Les SKU de l'offre du 13 septembre
-- ============================================================================
-- Six choses à vendre, et elles ne sont pas de la même nature :
--
--   The Foundation              390 $   une fois
--   The Roster                  690 $   une fois, jusqu'à 5 cliniciennes
--   Identité visuelle (add-on)   89 $   une fois, accessoire
--   Clinicienne supplémentaire  120 $   une fois, par siège au-delà de 5
--   The Fill (solo)              59 $   par mois
--   The Fill (cabinet)           69 $   par mois ET PAR CLINICIENNE
--
-- ⚠ `price_cents` SEUL MENTIRAIT. 5900 ne dit pas s'il s'agit d'un paiement
-- unique ou d'un loyer, et 6900 ne dit pas qu'il se multiplie par le nombre de
-- cliniciennes. Un catalogue qui ne sait pas dire ça est un catalogue dont
-- chaque lecteur redevine la réponse — et c'est exactement la famille de défaut
-- que ce dépôt a déjà payée deux fois (un lecteur qui réinterprète au lieu de
-- lire). D'où trois colonnes, et pas une de plus :
--
--   kind            ce que la ligne EST (kit, addon, seat, subscription)
--   billing_period  once | month
--   per_seat        le prix se multiplie-t-il par clinicienne
--   included_seats  combien de sièges sont compris (The Roster : 5)
--
-- ── CE QUE CETTE MIGRATION NE FAIT PAS ──────────────────────────────────────
--
-- Elle décrit ce qui est vendu. Elle ne facture rien, ne touche ni
-- `subscriptions` ni le webhook, et ne dit pas comment un siège se paie : la
-- quantité d'abonnement et la proration sont un autre lot. `per_seat` est ici
-- une PROPRIÉTÉ DU CATALOGUE — « ce prix se multiplie » — pas un calcul.
--
-- Elle ne supprime rien non plus. `starter`, `practice`, `signature` et `free`
-- restent, avec leurs prix et leurs allocations : des gens les ont achetés, et
-- `purchases` est un registre d'argent encaissé.
-- ============================================================================

-- ── 1. Ce qu'une ligne de `plans` peut être ─────────────────────────────────

alter table public.plans
  add column if not exists kind           text,
  add column if not exists billing_period text,
  add column if not exists per_seat       boolean,
  add column if not exists included_seats integer;

-- Les quatre lignes existantes sont toutes des kits payés une fois, non
-- multipliés. Écrit AVANT le NOT NULL, sinon il n'y a rien à remplir.
update public.plans
   set kind           = coalesce(kind, 'kit'),
       billing_period = coalesce(billing_period, 'once'),
       per_seat       = coalesce(per_seat, false);

-- ⚠ DES DÉFAUTS, ET ILS NE SONT PAS DE LA COMMODITÉ. Le bloc PLAN DATA de
-- `20260830062321` est mirroré verbatim dans `seed.sql` et rejoué après les
-- migrations à chaque `db reset`. Il ne nomme pas ces colonnes — il ne pouvait
-- pas, il est antérieur — et sans défaut il échouait sur le NOT NULL, ce qui
-- cassait la réplication complète. Corriger le bloc mirroré aurait été le
-- mauvais geste : il doit rester octet pour octet identique à sa migration,
-- c'est tout l'objet de `check_seed_mirrors.sh`.
--
-- Les valeurs par défaut disent la vérité sur ce que ces lignes-là sont : des
-- kits payés une fois, non multipliés par un nombre de cliniciennes.
alter table public.plans
  alter column kind           set default 'kit',
  alter column billing_period set default 'once',
  alter column per_seat       set default false;

alter table public.plans
  alter column kind           set not null,
  alter column billing_period set not null,
  alter column per_seat       set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'plans_kind_check') then
    alter table public.plans add constraint plans_kind_check
      check (kind = any (array['kit', 'addon', 'seat', 'subscription']));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_billing_period_check') then
    alter table public.plans add constraint plans_billing_period_check
      check (billing_period = any (array['once', 'month']));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_included_seats_check') then
    -- ⚠ `is null or` EN TÊTE, PAS `between` SEUL. `included_seats between 1
    -- and 500` rend NULL sur une colonne nulle, et un CHECK ACCEPTE NULL : la
    -- contrainte ne refuserait que ce qui est renseigné et faux, jamais ce qui
    -- est absent. C'est le premier des quatre défauts permissifs du README, et
    -- il a déjà troué cinq validateurs au lot 6.
    alter table public.plans add constraint plans_included_seats_check
      check (included_seats is null or included_seats between 1 and 500);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_seats_only_where_they_mean_something') then
    -- Un nombre de sièges compris n'a de sens que sur une ligne qui en porte.
    alter table public.plans add constraint plans_seats_only_where_they_mean_something
      check (included_seats is null or kind = 'kit');
  end if;
end $$;

-- ⚠ EN ANGLAIS, comme tout `comment on` de ce dépôt. Les commentaires DE CODE
-- sont en français ; les commentaires de SCHÉMA sont de la donnée, ils sortent
-- par `information_schema` et par les types générés, et
-- `20260827107000_english_only_schema.test.sql` les refuse en français. Il a
-- refusé ceux-ci à la première exécution.
comment on column public.plans.kind is
  'What the row IS. kit: produces a brand_kits row. addon: an accessory attached to an existing kit. seat: one more clinician on a Roster. subscription: a monthly rent. Read to decide whether a row may be granted as a generation allowance at all - grant_plan_allowance must never be handed a subscription.';
comment on column public.plans.billing_period is
  'once or month. price_cents alone cannot say whether 5900 is a one-time charge or a rent, and every reader that guesses eventually guesses wrong.';
comment on column public.plans.per_seat is
  'true when price_cents multiplies by the number of clinicians. A CATALOGUE PROPERTY, not a calculation: the quantity actually billed lives in subscriptions and is not written here.';
comment on column public.plans.included_seats is
  'Seats included in the price. The Roster: 5. NULL everywhere else, solo tiers included - a solo plan does not have "1 seat included", it has no seats at all.';

-- ── 2. Les allocations n'existent que là où elles veulent dire quelque chose ─
--
-- `directions_limit` et `regenerations_limit` mesurent une génération de kit.
-- Sur un abonnement mensuel ou sur un siège, elles n'ont aucun sens — et une
-- valeur inventée serait pire que leur absence : `consume_generation_credit`
-- les lirait et laisserait passer.
--
-- ⚠ ET L'ABSENCE ÉCHOUE FERMÉ, ce qui est ce qu'on veut. La fonction fait
-- déjà `if v_per_run is null then return false; end if;` — une ligne sans
-- allocation ne peut rien générer, par le chemin qui existe déjà, sans
-- branche nouvelle.

alter table public.plans
  alter column directions_limit    drop not null,
  alter column regenerations_limit drop not null;

do $$
begin
  -- L'ancienne contrainte de bornes rendait NULL sur une colonne devenue
  -- nullable, donc elle acceptait tout. Remplacée par sa version explicite.
  if exists (select 1 from pg_constraint where conname = 'plans_directions_check') then
    alter table public.plans drop constraint plans_directions_check;
  end if;
  alter table public.plans add constraint plans_directions_check
    check (directions_limit is null or directions_limit between 1 and 12);

  if exists (select 1 from pg_constraint where conname = 'plans_regenerations_check') then
    alter table public.plans drop constraint plans_regenerations_check;
  end if;
  alter table public.plans add constraint plans_regenerations_check
    check (regenerations_limit is null or regenerations_limit >= 0);

  -- ⚠ UN `case`, ET LA PREMIÈRE VERSION ÉTAIT UNE ÉQUIVALENCE QUI NE TENAIT
  -- PAS. Elle disait :
  --
  --   (kind in ('kit','addon')) = (directions_limit is not null
  --                                and regenerations_limit is not null)
  --
  -- Sur un abonnement à qui on posait UNE SEULE des deux allocations, le côté
  -- droit valait `true and false` = false, le côté gauche valait false, et
  -- `false = false` PASSAIT. La sonde de l'auto-contrôle en bas de ce fichier
  -- l'a trouvé à la première exécution — ce qui est précisément pourquoi elle
  -- tente l'écriture au lieu de relire la définition de la contrainte.
  --
  -- Les deux branches ne rendent jamais NULL : `kind` est NOT NULL, et
  -- `x is null` / `x is not null` sont toujours booléens. La contrainte ne
  -- peut répondre que TRUE ou FALSE, elle n'a pas de porte dérobée.
  alter table public.plans drop constraint if exists plans_allowance_matches_kind;
  alter table public.plans add constraint plans_allowance_matches_kind
    check (
      case when kind = any (array['kit', 'addon'])
           then directions_limit is not null and regenerations_limit is not null
           else directions_limit is null     and regenerations_limit is null
      end
    );
end $$;

-- ── 3. Les trois CHECK de `tier` ────────────────────────────────────────────
--
-- `plans.tier`      le catalogue : les six nouveautés
-- `purchases.tier`  ce qui s'encaisse une fois : les quatre `once`
-- `brand_kits.tier` ce qui PRODUIT un kit : Foundation et Roster
--
-- Le quatrième porteur de `tier` — `generation_credits.plan_tier` — est une
-- clé étrangère vers `plans.tier` et suit toute seule.
--
-- ⚠ The Fill n'entre dans AUCUN des deux derniers. Ce n'est pas un achat
-- unique et ça ne produit pas de kit : c'est une ligne `subscriptions`, et
-- cette table n'a pas de colonne `tier` du tout aujourd'hui. La brancher est
-- un autre lot ; l'inscrire dans `purchases.tier` maintenant laisserait croire
-- qu'un loyer mensuel peut s'y écrire.

do $$
begin
  alter table public.plans drop constraint if exists plans_tier_check;
  alter table public.plans add constraint plans_tier_check
    check (tier = any (array[
      -- L'offre précédente. Conservée : des gens l'ont achetée.
      'free', 'starter', 'practice', 'signature',
      -- L'offre du 13 septembre.
      'foundation', 'roster', 'identity_addon', 'roster_seat',
      'fill_solo', 'fill_practice'
    ]));

  alter table public.purchases drop constraint if exists purchases_tier_check;
  alter table public.purchases add constraint purchases_tier_check
    check (tier = any (array[
      'starter', 'practice', 'signature',
      'foundation', 'roster', 'identity_addon', 'roster_seat'
    ]));

  alter table public.brand_kits drop constraint if exists brand_kits_tier_check;
  alter table public.brand_kits add constraint brand_kits_tier_check
    check (tier = any (array[
      'starter', 'practice', 'signature',
      'foundation', 'roster'
    ]));
end $$;

-- ⚠ ET UNE GARDE QUI DIT LA RÈGLE PLUTÔT QUE DE L'ESPÉRER. Rien n'empêchait,
-- avant, d'ajouter un tier à `purchases` sans l'ajouter à `plans` : l'achat
-- serait passé, et `grant_plan_allowance` aurait levé à l'encaissement, sur de
-- l'argent déjà pris. Cette garde s'exécute à CHAQUE replay et compare les deux
-- listes telles qu'elles sont réellement écrites dans `pg_constraint`.
-- Une fonction temporaire plutôt qu'une sous-requête recopiée deux fois : elle
-- disparaît avec la session de replay et ne laisse rien derrière elle.
create or replace function pg_temp.tier_enum(p_conname text)
returns text[]
language sql
stable
as $fn$
  select coalesce(array_agg(m[1] order by m[1]), array[]::text[])
    from pg_constraint c,
         lateral regexp_matches(pg_get_constraintdef(c.oid),
                                '''([a-z_]+)''::text', 'g') as m
   where c.connamespace = 'public'::regnamespace
     and c.conname = p_conname;
$fn$;

do $$
declare
  v_orphan text;
begin
  select string_agg(t, ', ' order by t) into v_orphan
    from (select unnest(pg_temp.tier_enum('purchases_tier_check')) as t
          except
          select unnest(pg_temp.tier_enum('plans_tier_check'))) missing;

  if v_orphan is not null then
    raise exception
      'purchases.tier accepte des paliers absents de plans.tier (%) — un achat encaissé sans ligne de catalogue lève à grant_plan_allowance, après le paiement',
      v_orphan;
  end if;

  select string_agg(t, ', ' order by t) into v_orphan
    from (select unnest(pg_temp.tier_enum('brand_kits_tier_check')) as t
          except
          select unnest(pg_temp.tier_enum('plans_tier_check'))) missing;

  if v_orphan is not null then
    raise exception 'brand_kits.tier accepte des paliers absents de plans.tier (%)', v_orphan;
  end if;

  -- ⚠ ET LA GARDE ELLE-MÊME EST VÉRIFIÉE. Une liste vide ferait passer
  -- l'EXCEPT sans rien dire — c'est-à-dire une garde verte qui n'a rien lu,
  -- exactement le défaut de TENANCY.md §10.7. Si le motif cesse de trouver les
  -- littéraux, on lève ici plutôt que de rassurer.
  if coalesce(array_length(pg_temp.tier_enum('plans_tier_check'), 1), 0) = 0
  or coalesce(array_length(pg_temp.tier_enum('purchases_tier_check'), 1), 0) = 0 then
    raise exception 'la garde des paliers n''a lu aucun littéral : elle ne vérifie plus rien';
  end if;
end $$;

-- ── 4. Les six lignes ───────────────────────────────────────────────────────

-- >>> OFFER SKU DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ⚠ CES NOMBRES SONT LA DÉCISION, comme pour le bloc PLAN DATA au-dessus.
-- Changer un prix est un UPDATE ici et nulle part ailleurs. Les identifiants
-- de prix Stripe ne sont PAS ici : ils diffèrent entre le mode test et le mode
-- live, donc ils viennent de l'environnement (cf. ENV_REQUIRED.md).
--
-- `sort_order` reprend à 10 : l'offre précédente occupe 0 à 3, et intercaler
-- aurait renuméroté des lignes que personne n'a demandé à déplacer.
insert into public.plans
  (tier, label, price_cents, kind, billing_period, per_seat, included_seats,
   directions_limit, regenerations_limit, image_budget_cents, sort_order)
values
  -- Le livrable de tête de l'offre solo.
  ('foundation', 'The Foundation', 39000, 'kit', 'once', false, null,
   3, 6, 400, 10),

  -- L'offre cabinet. Cinq cliniciennes comprises ; la sixième est un `seat`.
  ('roster', 'The Roster', 69000, 'kit', 'once', false, 5,
   3, 12, 600, 11),

  -- ⚠ L'ACTUEL LIVRABLE DE TÊTE, DEVENU ACCESSOIRE. Il porte une allocation
  -- parce qu'il en a besoin : produire logo, couleurs et typographie est une
  -- vraie génération, avec ses reprises. Ce qui change est son prix et sa
  -- place dans l'offre, pas ce qu'il fait.
  ('identity_addon', 'Visual identity', 8900, 'addon', 'once', false, null,
   3, 3, 200, 12),

  -- ⚠ PAS D'ALLOCATION, ET C'EST VOULU. Ce qu'une clinicienne de plus reçoit
  -- — son pack complet — est déclenché par son arrivée dans le cabinet, pas
  -- par cette ligne de catalogue. Tant que ce déclenchement n'est pas écrit,
  -- l'absence d'allocation fait échouer fermé plutôt que d'ouvrir une
  -- génération que personne n'a branchée.
  ('roster_seat', 'Additional clinician', 12000, 'seat', 'once', true, null,
   null, null, 0, 13),

  -- Les deux loyers. Ils ne produisent pas de kit : pas d'allocation.
  ('fill_solo', 'The Fill', 5900, 'subscription', 'month', false, null,
   null, null, 0, 14),
  ('fill_practice', 'The Fill (practice)', 6900, 'subscription', 'month', true, null,
   null, null, 0, 15)
on conflict (tier) do update set
  label               = excluded.label,
  price_cents         = excluded.price_cents,
  kind                = excluded.kind,
  billing_period      = excluded.billing_period,
  per_seat            = excluded.per_seat,
  included_seats      = excluded.included_seats,
  directions_limit    = excluded.directions_limit,
  regenerations_limit = excluded.regenerations_limit,
  image_budget_cents  = excluded.image_budget_cents,
  sort_order          = excluded.sort_order;

-- <<< OFFER SKU DATA <<<

-- ── 5. Auto-contrôle ────────────────────────────────────────────────────────
--
-- ⚠ IL NE PROBE PAS AVEC UNE LIGNE EXISTANTE. Le garde-fou de
-- `20260910144421` insérait `select … from brand_kits limit 1` : sur une base
-- fraîche il n'y a pas de kit, l'INSERT n'écrit rien, RIEN NE LÈVE, et la
-- garde n'a jamais rien vérifié en CI (TENANCY.md §10.7). Ici, tout ce qui est
-- probé l'est avec des valeurs fabriquées sur place, donc sur une base vide
-- comme sur une base pleine.

do $$
declare
  v_count  integer;
  v_broke  boolean;
begin
  -- Les six existent, avec la bonne nature.
  select count(*) into v_count from public.plans
   where tier in ('foundation','roster','identity_addon','roster_seat','fill_solo','fill_practice');
  if v_count <> 6 then
    raise exception 'les six SKU de l''offre ne sont pas tous en base : % trouvés', v_count;
  end if;

  -- Les prix, en toutes lettres. Une faute de frappe sur un prix est de
  -- l'argent, pas un détail de présentation.
  if (select price_cents from public.plans where tier = 'foundation')     <> 39000
  or (select price_cents from public.plans where tier = 'roster')         <> 69000
  or (select price_cents from public.plans where tier = 'identity_addon') <>  8900
  or (select price_cents from public.plans where tier = 'roster_seat')    <> 12000
  or (select price_cents from public.plans where tier = 'fill_solo')      <>  5900
  or (select price_cents from public.plans where tier = 'fill_practice')  <>  6900 then
    raise exception 'un prix de l''offre ne correspond pas à la décision du 13 septembre';
  end if;

  -- The Roster comprend cinq cliniciennes, et lui seul.
  if (select included_seats from public.plans where tier = 'roster') <> 5 then
    raise exception 'The Roster ne comprend pas cinq cliniciennes';
  end if;
  if exists (select 1 from public.plans where included_seats is not null and tier <> 'roster') then
    raise exception 'un palier autre que The Roster porte des sièges compris';
  end if;

  -- Les deux prix qui se multiplient, et eux seuls.
  if (select array_agg(tier order by tier) from public.plans where per_seat)
     is distinct from array['fill_practice','roster_seat'] then
    raise exception 'la liste des prix par siège n''est pas celle de l''offre';
  end if;

  -- ── Et la règle qui garde l'argent est PARCOURUE, pas seulement écrite ──
  -- Un abonnement ne doit pas pouvoir porter une allocation de génération.
  -- Les DEUX à la fois...
  begin
    update public.plans
       set directions_limit = 3, regenerations_limit = 3
     where tier = 'fill_solo';
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un abonnement a pu recevoir une allocation de génération';
  end if;

  -- ...et UNE SEULE des deux, qui est le cas que la première version de la
  -- contrainte laissait passer.
  begin
    update public.plans set directions_limit = 3 where tier = 'fill_solo';
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un abonnement a pu recevoir une demi-allocation de génération';
  end if;

  -- Et un kit ne doit pas pouvoir en être privé.
  begin
    update public.plans set directions_limit = null where tier = 'foundation';
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'The Foundation a pu perdre son allocation de génération';
  end if;

  -- Un palier hors catalogue ne s'encaisse pas.
  begin
    insert into public.plans (tier, label, price_cents, kind, billing_period, per_seat,
                              directions_limit, regenerations_limit, sort_order)
    values ('not_an_offer', 'X', 100, 'kit', 'once', false, 3, 3, 99);
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    delete from public.plans where tier = 'not_an_offer';
    raise exception 'plans.tier accepte un palier qui n''est pas dans l''offre';
  end if;
end $$;
