-- ============================================================================
-- Eklio — Lot 4 : facturation (paiement unique + abonnement Monthly Presence)
-- ============================================================================
-- Fait suite à `20260823150000_cleanup_inherited_anomalies.sql` (dernière
-- migration réellement appliquée sur `fobgdsupyfslxbswfuay`, us-east-1) et
-- recouvre partiellement `20260825120000_lot3_brand_kits_us.sql`, écrit mais
-- NI fusionné dans `main` NI appliqué — voir la section 1.
--
-- MODÈLE ÉCONOMIQUE COUVERT
-- -------------------------
--   * kit de marque      : paiement UNIQUE, 3 tiers
--                          Starter $79 / Practice $149 / Signature $249
--   * Monthly Presence   : ABONNEMENT $39/mois (12 posts, 4 stories,
--                          calendrier éditorial mensuel), add-on par défaut
--                          au checkout
--
-- Les deux flux sont distincts et le restent en base : un achat de kit est un
-- ÉVÉNEMENT daté (`purchases`), un abonnement est un ÉTAT courant qui change
-- dans le temps (`subscriptions`). Les confondre dans une table unique
-- obligerait à des colonnes nullables selon le type de ligne.
--
-- CE QUE CE FICHIER NE FAIT PAS
-- -----------------------------
-- Aucune clé Stripe, aucun secret, aucun webhook, aucun code applicatif : le
-- branchement Stripe et le gating sont l'affaire du repo `eklio-frontend`.
-- Ici, uniquement le schéma que ce code consommera.
--
-- DEUX CHEMINS D'ACCÈS, À GARDER EN TÊTE POUR CHAQUE POLICY
-- --------------------------------------------------------
--   1. WEBHOOK STRIPE — écrit avec `service_role`. Aucune table n'étant en
--      FORCE ROW LEVEL SECURITY (cf. README), `service_role` contourne la RLS.
--      Il n'a donc besoin d'AUCUNE policy : lui en écrire une serait du bruit.
--   2. LECTURE CLIENT — le navigateur lit son propre statut d'abonnement et
--      ses propres achats avec la clé anon + JWT. Ce chemin passe par la RLS,
--      d'où une policy SELECT propriétaire sur chaque table cliente.
--
-- L'écriture cliente est refusée partout : un utilisateur qui pourrait insérer
-- sa propre ligne `subscriptions` s'offrirait l'abonnement. Les refus sont
-- écrits EXPLICITEMENT (policy `using (false)`) plutôt que laissés implicites,
-- comme le fait déjà `profiles` depuis le nettoyage : sous RLS, l'absence de
-- policy refuse déjà, mais ne documente rien et se relit comme un oubli.
--
-- L'event trigger plateforme `ensure_rls` active la RLS sur toute table créée
-- dans `public` — vérifié : sa fonction `rls_auto_enable` ne fait QUE
-- `enable row level security`, elle ne crée aucune policy. Sans les policies
-- ci-dessous, les nouvelles tables seraient donc inaccessibles à tout le monde
-- sauf `service_role`. On active quand même la RLS explicitement : le schéma
-- doit rester rejouable sur une base sans cet event trigger.
-- ============================================================================


-- ============================================================================
-- 1. brand_kits.tier — périmètre du livrable, promu depuis `content`
-- ============================================================================
-- ⚠ RECOUVREMENT ASSUMÉ avec `20260825120000_lot3_brand_kits_us.sql`, qui
-- ajoute déjà cette colonne mais n'est ni fusionné ni appliqué. Les deux
-- fichiers sont idempotents et posent la MÊME définition (`text` + CHECK sur
-- les trois tiers, défaut `'starter'`) : quel que soit l'ordre d'application,
-- le résultat est identique et aucun des deux n'échoue.
--
-- CE QUE LE LOT 3 NE FAIT PAS, et qui est corrigé ici : il a été écrit en
-- supposant `brand_kits` vide (« La table contient 0 ligne à ce jour »). Ce
-- n'est plus vrai — la base US porte 1 kit de test dont `content->>'tier'`
-- vaut `'signature'`. Appliqué seul, le Lot 3 déclasserait silencieusement ce
-- kit en `'starter'` via le défaut de colonne. Le backfill ci-dessous
-- rapatrie la valeur depuis `content` avant toute exploitation.
--
-- Pourquoi promouvoir : le tier doit être requêtable (métriques de vente par
-- tier, gating) et contraint. Dans du JSONB libre il n'est ni l'un ni l'autre.
-- Convention `text` + CHECK, comme `projects.status` : le schéma n'utilise
-- aucun enum Postgres, et un CHECK s'amende sans ALTER TYPE.
--
-- ⚠ SÉMANTIQUE : cette colonne décrit CE QUE CONTIENT CE KIT, pas ce à quoi
-- l'utilisateur a droit. C'est un instantané du périmètre à la génération. Le
-- droit courant vit dans `purchases` / `subscriptions` ci-dessous, qui ne
-- redéfinissent jamais ce champ. Sur upgrade : on régénère ou complète le kit,
-- PUIS on met `tier` à jour — il suit le livrable, pas la facturation.

alter table public.brand_kits
  add column if not exists tier text not null default 'starter';

-- Backfill depuis le JSONB, avant la contrainte : une valeur inattendue dans
-- `content` doit faire échouer la migration, pas passer inaperçue.
update public.brand_kits
   set tier = content->>'tier'
 where content ? 'tier'
   and content->>'tier' is distinct from tier;

alter table public.brand_kits
  drop constraint if exists brand_kits_tier_check;

alter table public.brand_kits
  add constraint brand_kits_tier_check check (
    tier = any (array['starter'::text, 'practice'::text, 'signature'::text])
  );

comment on column public.brand_kits.tier is
  'Périmètre livré par ce kit (starter/practice/signature). Instantané à la génération, pas le droit courant : celui-ci vit dans purchases.';


-- ============================================================================
-- 2. profiles.stripe_customer_id — la correspondance user <-> client Stripe
-- ============================================================================
-- Un même utilisateur achète un kit (paiement unique) ET souscrit Monthly
-- Presence (abonnement) : c'est UN SEUL client Stripe pour les deux flux. La
-- correspondance ne peut donc pas vivre uniquement sur `subscriptions`, sinon
-- un acheteur de kit sans abonnement n'a nulle part où la ranger, et un second
-- client Stripe finit par être créé pour lui.
--
-- Elle vit sur `profiles`, table 1:1 avec `auth.users`, en `unique` : c'est
-- aussi le chemin par lequel le webhook résout `customer` -> utilisateur.
-- Volontairement NON dupliquée sur `subscriptions` : une même valeur écrite à
-- deux endroits par deux handlers de webhook finit par diverger.
--
-- Lisible par son propriétaire (policy `profiles_select_own` existante,
-- inchangée), écrite par le `service_role` uniquement — `profiles` n'expose
-- ni INSERT ni DELETE aux clients, et l'UPDATE client reste possible mais ne
-- porte que sur ses propres lignes.

alter table public.profiles
  add column if not exists stripe_customer_id text;

create unique index if not exists profiles_stripe_customer_id_key
  on public.profiles (stripe_customer_id)
  where stripe_customer_id is not null;

comment on column public.profiles.stripe_customer_id is
  'Identifiant client Stripe (cus_…), unique. Correspondance canonique user <-> Stripe, partagée par le paiement unique et l''abonnement.';


-- ============================================================================
-- 3. subscriptions — Monthly Presence, l'ÉTAT courant de l'abonnement
-- ============================================================================
-- Une ligne par utilisateur, pas par période : Stripe conserve le même
-- `sub_…` d'un mois sur l'autre et pousse un événement à chaque changement.
-- Le webhook fait donc un upsert sur `user_id`, contrainte `unique` — clé
-- naturelle de l'upsert, et garde-fou contre deux abonnements concurrents pour
-- un même utilisateur (l'offre est un add-on unique à $39/mois).
--
-- `user_id` référence `profiles(id)`, PAS `auth.users(id)` : c'est la
-- convention de `projects`, seule table applicative porteuse d'un `user_id`.
-- Le README documente ce choix comme délibéré (`profiles.id` cascade lui-même
-- depuis `auth.users`, et `profiles` reste la seule table couplée à `auth`).
-- S'en écarter ici créerait deux conventions dans le même schéma.
--
-- `status` : le CHECK reprend l'ENSEMBLE des statuts que Stripe peut émettre,
-- pas seulement ceux qui nous intéressent. Un statut absent du CHECK ferait
-- ÉCHOUER le webhook au moment précis où il rapporte un changement d'état —
-- l'abonnement resterait affiché actif alors que Stripe le sait impayé. La
-- règle de gating (« actif ou en période de grâce ») est une affaire de code
-- applicatif, pas de contrainte d'intégrité.
--
-- `cancel_at_period_end` : une résiliation Stripe ne bascule pas `status` en
-- `canceled` immédiatement, elle laisse l'abonnement `active` jusqu'à la fin
-- de la période payée. Sans ce drapeau, impossible de distinguer un abonné
-- qui a résilié d'un abonné qui reconduit — l'UI doit le dire.

create table if not exists public.subscriptions (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null unique
                           references public.profiles (id) on delete cascade,
  stripe_subscription_id text not null unique,
  stripe_price_id        text,
  status                 text not null,
  current_period_end     timestamptz,
  cancel_at_period_end   boolean not null default false,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

alter table public.subscriptions
  drop constraint if exists subscriptions_status_check;

alter table public.subscriptions
  add constraint subscriptions_status_check check (
    status = any (array[
      'incomplete'::text, 'incomplete_expired'::text, 'trialing'::text,
      'active'::text, 'past_due'::text, 'canceled'::text, 'unpaid'::text,
      'paused'::text
    ])
  );

comment on table public.subscriptions is
  'Abonnement Monthly Presence ($39/mois). Une ligne par utilisateur, upsert par le webhook Stripe (service_role). Lecture client : propriétaire uniquement.';


-- ============================================================================
-- 4. purchases — achats de kit, l'ÉVÉNEMENT de paiement unique
-- ============================================================================
-- TABLE plutôt que des colonnes sur `projects` / `brand_kits`. Le choix a été
-- pesé ; les colonnes échouent sur quatre points :
--
--   * UPGRADE. Passer de Starter à Signature est un SECOND paiement, avec sa
--     propre session Stripe et son propre montant. Des colonnes n'en gardent
--     qu'un : le premier est écrasé, l'historique de facturation disparaît.
--   * DURÉE DE VIE. Un projet peut être supprimé ; la trace comptable du
--     paiement, non. D'où `project_id` NULLABLE en `on delete set null` : le
--     projet part, la ligne de vente reste (montant, date, tier, session
--     Stripe). Des colonnes sur `projects` partiraient avec lui.
--   * REMBOURSEMENT. C'est une transition d'état d'un achat, pas du projet.
--   * IDEMPOTENCE. `stripe_checkout_session_id` unique fait de la table sa
--     propre garde : un `checkout.session.completed` rejoué se heurte à la
--     contrainte au lieu de facturer deux fois. Une colonne ne contraint rien.
--
-- `amount_cents` en entier, jamais un flottant : c'est l'unité que Stripe
-- transmet (7900 = $79.00) et l'arithmétique décimale binaire n'a pas sa place
-- dans un montant. `currency` explicite malgré le marché US unique — un jour
-- il y en aura deux, et un montant sans devise n'est pas un montant.
--
-- `status` : la ligne peut naître à la CRÉATION de la session (`pending`,
-- avant paiement) et non seulement à sa complétion. Le front sait ainsi qu'un
-- checkout est en cours, et un abandon reste visible au lieu de disparaître.
-- `paid_at` reste NULL tant que Stripe n'a pas confirmé — c'est `paid_at`, pas
-- `created_at`, qui fait foi pour « ce kit est payé ».

create table if not exists public.purchases (
  id                         uuid primary key default gen_random_uuid(),
  user_id                    uuid not null
                               references public.profiles (id) on delete cascade,
  project_id                 uuid
                               references public.projects (id) on delete set null,
  tier                       text not null,
  stripe_checkout_session_id text not null unique,
  stripe_payment_intent_id   text,
  amount_cents               integer not null,
  currency                   text not null default 'usd',
  status                     text not null default 'pending',
  paid_at                    timestamptz,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now()
);

alter table public.purchases drop constraint if exists purchases_tier_check;
alter table public.purchases
  add constraint purchases_tier_check check (
    tier = any (array['starter'::text, 'practice'::text, 'signature'::text])
  );

alter table public.purchases drop constraint if exists purchases_status_check;
alter table public.purchases
  add constraint purchases_status_check check (
    status = any (array['pending'::text, 'paid'::text,
                        'refunded'::text, 'failed'::text])
  );

alter table public.purchases drop constraint if exists purchases_amount_cents_check;
alter table public.purchases
  add constraint purchases_amount_cents_check check (amount_cents >= 0);

-- Un achat payé doit être daté : sans ça, `status = 'paid'` et `paid_at null`
-- coexistent et plus rien ne dit quand le droit a été ouvert.
alter table public.purchases drop constraint if exists purchases_paid_at_check;
alter table public.purchases
  add constraint purchases_paid_at_check check (
    (status = 'paid') = (paid_at is not null)
  );

-- Index sur les colonnes référençantes : « mes achats » (écran facturation)
-- et « ce projet est-il payé ? » (gating) sont les deux seules lectures.
create index if not exists purchases_user_id_idx    on public.purchases (user_id);
create index if not exists purchases_project_id_idx on public.purchases (project_id);

comment on table public.purchases is
  'Achats de kit (paiement unique, 3 tiers). Un ÉVÉNEMENT par paiement : un upgrade ajoute une ligne. Écrite par le webhook Stripe (service_role).';


-- ============================================================================
-- 5. stripe_events — idempotence des webhooks
-- ============================================================================
-- Stripe REJOUE ses webhooks : à la moindre réponse non-2xx, à la moindre
-- latence, et manuellement depuis le dashboard. Sans cette table, un
-- `checkout.session.completed` rejoué débite deux fois un compteur, un
-- `customer.subscription.deleted` rejoué écrase un abonnement re-souscrit
-- entre-temps. Le handler doit donc insérer l'identifiant AVANT de traiter :
-- si l'insertion viole la clé, l'événement a déjà été traité, on répond 200 et
-- on ne fait rien.
--
-- `stripe_event_id` est la CLÉ PRIMAIRE, pas une colonne unique à côté d'un
-- `uuid` de complaisance : l'identifiant Stripe (`evt_…`) est déjà stable,
-- unique et transmis à chaque appel. Une clé de substitution n'ajouterait
-- qu'une seconde identité pour la même chose.
--
-- `payload` conserve l'événement brut : c'est ce qui permet de rejouer à la
-- main un traitement bogué, et de trancher un litige de facturation sans
-- dépendre de la rétention Stripe. Contenu sensible (montants, e-mail client),
-- d'où l'accès `service_role` exclusif ci-dessous.

create table if not exists public.stripe_events (
  stripe_event_id text primary key,
  type            text not null,
  payload         jsonb,
  processed_at    timestamptz not null default now()
);

comment on table public.stripe_events is
  'Journal d''idempotence des webhooks Stripe. Écrite et lue par le service_role UNIQUEMENT : RLS activée, aucune policy, privilèges anon/authenticated révoqués.';


-- ============================================================================
-- 6. monthly_presence_content — le livrable mensuel de l'abonnement
-- ============================================================================
-- Calquée sur `brand_kits` : le contenu d'un mois (12 posts, 4 stories,
-- calendrier éditorial) est de forme variable et n'a pas à être éclaté en
-- colonnes — c'est le cas d'usage du JSONB, et c'est déjà la convention du
-- repo pour un livrable généré.
--
-- `month` est un `date` calé au PREMIER JOUR DU MOIS, contraint : un mois
-- n'est pas un instant, et laisser deux représentations (`2026-09-01` et
-- `2026-09-15`) coexister ferait passer l'unicité à côté de son but. Le CHECK
-- rend la normalisation obligatoire plutôt que conventionnelle.
--
-- `unique (project_id, month)` : la génération mensuelle est déclenchée par un
-- job, donc rejouable. Sans cette contrainte, un double déclenchement produit
-- deux mois de septembre et l'UI en choisit un au hasard.
--
-- `status` reprend les valeurs de `brand_kits.status` (Lot 3) : une génération
-- interrompue doit être discernable d'un mois complet sans inspecter les clés
-- du JSON.
--
-- Rattachée au PROJET et non à l'utilisateur : le contenu décline l'identité
-- de marque d'un projet précis (palette, voix, ton). Un utilisateur à deux
-- projets a deux fils de contenu distincts.

create table if not exists public.monthly_presence_content (
  id         uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  month      date not null,
  content    jsonb not null default '{}'::jsonb,
  status     text not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint monthly_presence_content_project_id_month_key unique (project_id, month)
);

alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_month_check;
alter table public.monthly_presence_content
  add constraint monthly_presence_content_month_check check (
    month = date_trunc('month', month)::date
  );

alter table public.monthly_presence_content
  drop constraint if exists monthly_presence_content_status_check;
alter table public.monthly_presence_content
  add constraint monthly_presence_content_status_check check (
    status = any (array['pending'::text, 'generating'::text,
                        'complete'::text, 'failed'::text])
  );

create index if not exists monthly_presence_content_project_id_idx
  on public.monthly_presence_content (project_id);

comment on table public.monthly_presence_content is
  'Livrable mensuel Monthly Presence, un enregistrement par (projet, mois). Généré côté serveur (service_role) ; lecture client propriétaire uniquement.';


-- ============================================================================
-- 7. RLS
-- ============================================================================
-- Redondant avec l'event trigger `ensure_rls` sur cette base, indispensable
-- ailleurs. `enable` est idempotent.

alter table public.subscriptions             enable row level security;
alter table public.purchases                 enable row level security;
alter table public.stripe_events             enable row level security;
alter table public.monthly_presence_content  enable row level security;

-- `stripe_events` : RLS + AUCUNE policy suffit à bloquer anon/authenticated
-- via PostgREST. La révocation des privilèges ajoute une seconde barrière,
-- indépendante de la RLS, contre une policy ajoutée par inadvertance plus
-- tard. Les privilèges viennent des DEFAULT PRIVILEGES Supabase, posés à la
-- création de la table ; on les retire explicitement.
revoke all on table public.stripe_events from anon, authenticated;


-- ============================================================================
-- 8. Policies — propriétaire uniquement en lecture, écriture refusée
-- ============================================================================
-- Sans clause TO, donc accordées à `public` : évaluées pour `anon` comme pour
-- `authenticated`, et pour `anon` `auth.uid()` vaut NULL — rien n'est visible.
-- Convention `(select auth.uid())` du jeu 2, reprise par le nettoyage :
-- l'appel est évalué une fois par requête et non une fois par ligne.
--
-- `service_role` n'apparaît nulle part : il contourne la RLS (aucune table en
-- FORCE ROW LEVEL SECURITY). Le webhook écrit donc sans policy, par
-- construction.

-- ---- subscriptions ---------------------------------------------------------
drop policy if exists "subscriptions_select_own"    on public.subscriptions;
drop policy if exists "subscriptions_insert_denied" on public.subscriptions;
drop policy if exists "subscriptions_update_denied" on public.subscriptions;
drop policy if exists "subscriptions_delete_denied" on public.subscriptions;

create policy "subscriptions_select_own"
  on public.subscriptions for select
  using (user_id = (select auth.uid()));

-- Refus explicites : c'est Stripe qui décide de l'existence et de l'état d'un
-- abonnement. Un client capable d'insérer sa ligne s'offrirait Monthly
-- Presence ; capable de la modifier, il repousserait sa date d'échéance.
-- La résiliation elle-même passe par l'API Stripe côté serveur, jamais par un
-- DELETE : supprimer la ligne ne résilie rien chez Stripe et ferait diverger
-- la base de la source de vérité.
create policy "subscriptions_insert_denied"
  on public.subscriptions for insert with check (false);

create policy "subscriptions_update_denied"
  on public.subscriptions for update using (false);

create policy "subscriptions_delete_denied"
  on public.subscriptions for delete using (false);

-- ---- purchases -------------------------------------------------------------
drop policy if exists "purchases_select_own"    on public.purchases;
drop policy if exists "purchases_insert_denied" on public.purchases;
drop policy if exists "purchases_update_denied" on public.purchases;
drop policy if exists "purchases_delete_denied" on public.purchases;

create policy "purchases_select_own"
  on public.purchases for select
  using (user_id = (select auth.uid()));

-- Même raisonnement : un INSERT client, c'est un kit payé gratuitement. La
-- session de checkout est créée côté serveur, la ligne aussi.
create policy "purchases_insert_denied"
  on public.purchases for insert with check (false);

create policy "purchases_update_denied"
  on public.purchases for update using (false);

create policy "purchases_delete_denied"
  on public.purchases for delete using (false);

-- ---- monthly_presence_content ----------------------------------------------
-- Propriété INDIRECTE, via le projet : même forme que les policies de
-- `directions`, `project_briefs` et `brand_kits`.
drop policy if exists "monthly_presence_content_select_own"    on public.monthly_presence_content;
drop policy if exists "monthly_presence_content_insert_denied" on public.monthly_presence_content;
drop policy if exists "monthly_presence_content_update_denied" on public.monthly_presence_content;
drop policy if exists "monthly_presence_content_delete_denied" on public.monthly_presence_content;

create policy "monthly_presence_content_select_own"
  on public.monthly_presence_content for select
  using (exists (
    select 1 from public.projects p
    where p.id = monthly_presence_content.project_id
      and p.user_id = (select auth.uid())
  ));

-- ⚠ ÉCART DÉLIBÉRÉ avec `brand_kits`, qui est en `FOR ALL` (écriture cliente
-- autorisée sur ses propres lignes). Ici l'écriture est refusée : ce contenu
-- est le livrable d'un abonnement payant, produit par le serveur. Autoriser
-- l'écriture cliente permettrait de fabriquer un mois de contenu sans
-- abonnement — le gating serait alors purement applicatif.
create policy "monthly_presence_content_insert_denied"
  on public.monthly_presence_content for insert with check (false);

create policy "monthly_presence_content_update_denied"
  on public.monthly_presence_content for update using (false);

create policy "monthly_presence_content_delete_denied"
  on public.monthly_presence_content for delete using (false);

-- ---- stripe_events ---------------------------------------------------------
-- AUCUNE policy, volontairement. RLS activée + aucune policy = table
-- invisible et inécrivable pour anon et authenticated ; `service_role`
-- contourne la RLS et garde un accès plein. Le journal contient les payloads
-- Stripe bruts : il n'a aucune raison d'être exposé au navigateur.


-- ============================================================================
-- 9. Triggers updated_at
-- ============================================================================
-- Réutilise `public.set_updated_at()`, déjà en place sur les six tables
-- existantes. `stripe_events` n'en a pas : une ligne de journal ne se modifie
-- jamais.

drop trigger if exists set_subscriptions_updated_at on public.subscriptions;
create trigger set_subscriptions_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();

drop trigger if exists set_purchases_updated_at on public.purchases;
create trigger set_purchases_updated_at
  before update on public.purchases
  for each row execute function public.set_updated_at();

drop trigger if exists set_monthly_presence_content_updated_at on public.monthly_presence_content;
create trigger set_monthly_presence_content_updated_at
  before update on public.monthly_presence_content
  for each row execute function public.set_updated_at();


-- ============================================================================
-- 10. Garde-fous — vérifié, pas supposé
-- ============================================================================
-- Une table de facturation sans cloisonnement laisserait n'importe quel compte
-- lire les achats et les abonnements de tous les autres. La migration doit
-- échouer plutôt que de laisser croire le contraire.

do $$
declare
  t text;
begin
  -- RLS active sur les quatre nouvelles tables.
  foreach t in array array['subscriptions', 'purchases',
                           'stripe_events', 'monthly_presence_content']
  loop
    if not (select relrowsecurity
              from pg_class
             where oid = ('public.' || t)::regclass) then
      raise exception
        'lot4_billing: RLS desactivee sur %. Migration interrompue.', t;
    end if;
  end loop;

  -- Cloisonnement propriétaire en lecture sur les trois tables clientes.
  foreach t in array array['subscriptions', 'purchases',
                           'monthly_presence_content']
  loop
    if not exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t
         and cmd = 'SELECT' and qual is not null
    ) then
      raise exception
        'lot4_billing: aucune policy SELECT proprietaire sur %. Migration interrompue.', t;
    end if;
  end loop;

  -- `stripe_events` ne doit être exposée à personne d'autre que service_role.
  if exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'stripe_events'
  ) then
    raise exception
      'lot4_billing: une policy existe sur stripe_events, qui doit rester service_role uniquement. Migration interrompue.';
  end if;

  -- L'idempotence des webhooks repose entièrement sur cette unicité.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.stripe_events'::regclass and contype = 'p'
  ) then
    raise exception
      'lot4_billing: cle primaire absente sur stripe_events, l''idempotence des webhooks n''est plus garantie. Migration interrompue.';
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.purchases'::regclass
       and contype = 'u'
       and pg_get_constraintdef(oid) like '%stripe_checkout_session_id%'
  ) then
    raise exception
      'lot4_billing: unicite absente sur purchases.stripe_checkout_session_id, un checkout rejoue facturerait deux fois. Migration interrompue.';
  end if;

  -- Le backfill du tier ne doit avoir laissé aucun kit déclassé.
  if exists (
    select 1 from public.brand_kits
     where content ? 'tier' and content->>'tier' is distinct from tier
  ) then
    raise exception
      'lot4_billing: au moins un brand_kit a un tier different de content->>tier apres backfill. Migration interrompue.';
  end if;
end
$$;
