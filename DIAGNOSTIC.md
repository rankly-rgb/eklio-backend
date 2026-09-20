# DIAGNOSTIC.md — état réel avant le chantier Content

Rapport de PHASE 0. **Lecture seule** : rien n'a été écrit en base, aucune migration
n'a été créée, aucune branche de développement Supabase n'a été ouverte.

Mesuré le 2026-09-20 sur :

- `rankly-rgb/eklio-backend`, branche `claude/great-brahmagupta-za7qmx`, HEAD `960b5f3`
- `rankly-rgb/eklio-frontend`, branche `claude/great-brahmagupta-za7qmx`, HEAD `60f7708`
- projet Supabase de production `fobgdsupyfslxbswfuay` (lecture de
  `supabase_migrations.schema_migrations` via `list_migrations`, rien d'autre)

---

## 0. CLAUSE D'ARRÊT — les six écarts entre le prompt et l'état réel

Ils sont listés en tête parce qu'ils changent ce qui peut être construit, et deux
d'entre eux changent ce qui peut être **vérifié**.

### 0.1 ⚠ La production porte 14 migrations que le dépôt de travail n'a pas

`list_migrations` sur `fobgdsupyfslxbswfuay` rend **148** versions. La branche
`claude/great-brahmagupta-za7qmx` en porte **133**. Les 14 manquantes existent
dans le dépôt, mais sur une autre branche — `origin/claude/stoic-ritchie-1liqrz`
(9 commits, tête `46d4111`) — qui n'est mergée ni dans `main` ni ici :

```
20260917160202  california_is_the_first_verified_state
20260917164228  lep_the_fourth_bbs_licence
20260917164434  a_closure_is_a_decision_with_a_snapshot
20260917164505  florida_settles_the_national_description
20260917165937  the_decision_table_says_no_out_loud
20260917210004  positioning_is_a_second_family_of_rules
20260918185950  the_ten_positioning_rules_v1
20260918190034  how_many_findings_the_free_report_shows
20260918193221  third_person_becomes_present_without_and_the_cap_is_decided
20260919132507  third_person_is_anchored_not_capitalised
20260919172421  the_window_does_the_work_not_the_sentence_boundary
20260919200211  the_model_is_told_the_thirty_phrases
20260920081353  an_anonymised_testimonial_is_still_a_testimonial
20260920081641  two_craft_cliches_join_the_thirty
```

**Ce que ça casse, précisément.** La vérification n°3 de la PHASE 6 demande que le CI
rejoue toutes les migrations depuis zéro sur une stack Postgres locale. Rejouées
depuis cette branche, elles produisent un schéma qui **n'est pas celui de la
production** : il lui manque la seconde famille de règles de positionnement, les deux
États vérifiés, et les deux derniers ajouts à `banned_phrases`. Or la PHASE 4.5 fait
passer chaque label de diagramme par `banned_phrases` : la liste contre laquelle le
moteur sera testé ici ne sera pas la liste qui refusera en production.

Les 14 touchent le licensing et le positionnement — **aucune** ne touche
`content_*`, `comp_grants`, `credit*` ni le rendu. Le chantier Content peut donc
avancer sans elles, à une condition tenue dans tout ce qui suit : **aucune migration
neuve de ce chantier ne référence un objet introduit par ces 14**, et le contrôle de
`banned_phrases` se fait par RPC (`usp_banned_phrases_check`) plutôt qu'en recopiant
la liste.

Ce n'est pas réparé ici : réconcilier des branches est explicitement hors périmètre.
Versé dans `FOLLOWUP.md`.

### 0.2 ⚠ La branche de référence citée n'est pas la branche courante

Le prompt donne `claude/eklio-reveal-rebuild-28o625` comme branche frontend de
référence. Elle existe (`d3e02a8` côté backend, `e7d5855` côté frontend) mais elle a
**divergé** : côté frontend sa tête est le merge de la PR #15, très en arrière du
tronc courant (`git merge-base --is-ancestor` rend faux). Le travail se fait sur
`claude/great-brahmagupta-za7qmx`, la branche désignée, qui est à jour.

### 0.3 ⚠ 2923 tests, pas 601

`npx vitest run` sur le frontend : **149 fichiers, 2923 tests, tous au vert**, 13,1 s.
Le chiffre de 601 du prompt est périmé d'un facteur ~4,9. La contrainte de non-régression
de la PHASE 6.1 est donc lue comme : **2923 au vert, aucune régression**.

### 0.4 ⚠ Les trois « migrations en attente » sont appliquées

Les trois sont en production et dans le dépôt :

| ce que le prompt décrit | migration réelle | statut |
|---|---|---|
| correctif de trigger | `20260901074731` §6, trigger `selected_usp_id` ↔ `usp_options` | **appliquée** |
| relâchement du CHECK pour 2–3 options d'USP | `20260901074731` §5, `project_briefs_usp_options_valid` : `< 2` et `> 3` | **appliquée** |
| CHECK sur la forme de `project_briefs.data` | `20260901074933_project_briefs_data_shape` | **appliquée** |

Rien n'est en attente de ce côté.

### 0.5 ⚠ Le modèle de données n'est pas par utilisateur, il est par kit

Le prompt écrit `user_id` partout (`topic_assignments`, `rendered_assets`,
`credit_ledger`, `next_topic_for_user`). **Toute la couche Content existante est
clefée sur `brand_kit_id`**, et la propriété se lit par jointure
`brand_kits → projects.user_id`. C'est le motif de RLS répété à l'identique dans
chacune des six tables de `20260910083735`.

L'écart n'est pas cosmétique. Un `user_id` porterait un second axe de propriété à côté
du premier, et les deux divergeraient au premier compte à deux projets — qui existe
(`countUnpaidProjects` plafonne à trois briefs par compte, donc trois kits).

**Il faut trancher, et c'est une décision produit, pas technique** — voir §7.

### 0.6 ⚠ Une grande part du chantier existe déjà, sous d'autres noms

Créer les tables telles que le prompt les nomme dupliquerait de l'infrastructure en
service. Correspondances mesurées :

| ce que le prompt demande | ce qui existe déjà | verdict |
|---|---|---|
| réservation/règlement de crédit | `reserve_content_image` / `settle_content_image` / `content_image_allowance` (`20260910084320` §4) | **même discipline, même invariant** ; le ledger neuf doit s'y adosser, pas le doubler |
| idempotence `(user_id, month)` des runs | `content_months`, `unique (brand_kit_id, month)`, statut `generating→proposed→approved\|failed` | **existe** |
| moteur de composition Satori + resvg | `satori@0.33.4` et `@resvg/resvg-js@2.6.2` déjà en dépendances ; `lib/kit/render/` (17 modules) dont `social-posts.ts` rend déjà `post_*_1080` / `story_1080x1920` | **socle présent**, à étendre, pas à refonder |
| cron mensuel | `app/api/cron/content-month/route.ts` + `lib/content/generate/` (11 modules : `plan`, `queue`, `run`, `ground`, `themes`, `capacity`, `ceiling`, `armed`…) | **existe** |
| archétypes | `content_items.archetype ∈ {statement,question,notes,signature,story}` — **5**, pas 11 | à étendre ; voir §7 |
| validation éthique des sorties | `ethics_scan` / `ethics_blocks` + trigger `content_items_ethics_gate` **dans l'écriture** | **existe et mord déjà** |

---

## 1. Schéma réel des tables de contenu

`/app/content` et `/app/content/[id]` lisent, via `lib/data/content.ts` :
`content_items`, `content_months`, `content_checkins`, `content_preferences`,
`content_registers`. `/app/content/[id]` lit en plus `brand_images` (photo, par URL
signée, TTL 300 s, bucket `brand-assets`).

### 1.1 `content_items` — `20260906155600`, amendée 4 fois

```
id uuid pk default gen_random_uuid()
brand_kit_id uuid not null → brand_kits(id) on delete cascade
archetype text not null      -- statement|question|notes|signature|story
status text not null default 'draft'   -- draft|ready|archived  ('published' absent, volontairement)
title text                   -- ≤ 34 car.
caption text                 -- ≤ 2200 car. (plafond Instagram)
alt_text text                -- ≤ 420 car.
tags text[] not null default '{}'   -- ≤ 8
category text                -- ≤ 40 car.
image_slot text              -- hero|ambient_a|ambient_b|post_bg_1..3|texture, PAS de FK
scheduled_for date
created_at / updated_at timestamptz not null default now()
```

Amendements : `20260910100415` (texte sur image), `20260910100758` (forme du JSON de
restauration), `20260910102753` (`theme`), `20260914084054` (trigger éthique).

`image_slot` n'a **pas** de clé étrangère, et c'est documenté : un item peut nommer
le slot qu'il veut avant que la photo existe.

### 1.2 `content_months` — provenance, pas filtre de date

`unique (brand_kit_id, month)`, `month = date_trunc('month', month)`,
`themes text[]` borné à 6, `status ∈ {generating, proposed, approved, failed}`.
Le commentaire de table est explicite : **quel mois a GÉNÉRÉ un item est un fait
distinct de quand il est DÛ**, et seul le second est une date sur l'item.

### 1.3 `content_grounds` — l'argent est une ligne, jamais un élément de jsonb

`unique (month_id, theme)`, `fingerprint text not null`, `storage_path text` (null
tant que les octets n'existent pas), `cost_cents integer`, `state ∈ {reserved,
settled, released, failed}`, et l'invariant

```sql
check ((state = 'settled') = (storage_path is not null))
```

C'est **exactement la déduplication par hash** que la PHASE 2.4 demande, un cran plus
bas : un `fingerprint` par (mois, thème).

### 1.4 `content_image_allowance` — compteur récurrent, remis à zéro structurellement

`primary key (brand_kit_id, month)`, `budget_cents`, `reserved_cents`, `used_cents`, et

```sql
check (reserved_cents + used_cents <= budget_cents)
```

Le commentaire de table nomme le piège évité : ce n'est **pas**
`plans.image_budget_cents`, qui est une cagnotte à vie attachée à un achat unique.
Un mois neuf n'a pas de ligne, donc il a tout son budget : le reset est structurel,
pas un job qui doit penser à tourner.

### 1.5 `content_preferences`, `content_checkins`, `content_registers`

- `content_preferences` : une ligne par kit, `cadence_per_week ∈ {1,2,3}`,
  `accepted_registers text[]` validé **par trigger** contre `content_registers`
  (un tableau ne porte pas de clé étrangère), `off_limits` ≤ 500 car.
- `content_checkins` : `unique (brand_kit_id, month)`, les trois questions,
  `taking_clients ∈ {yes, waitlist, no}` — **pas un booléen**, parce qu'une liste
  d'attente est une troisième réponse avec sa propre copie.
- `content_registers` : six formes éditoriales, chacune avec sa `safety_rule`
  **en données**. Disjointes des archétypes par construction, avec un garde-fou qui
  fait échouer la migration si les deux vocabulaires se recouvrent.

### 1.6 RLS — le même motif six fois, sans exception

Les six tables ont `enable row level security`. Le motif est invariant :

```sql
create policy "<t>_select_own" on public.<t>
  for select using (exists (
    select 1 from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
     where bk.id = <t>.brand_kit_id
       and pr.user_id = (select auth.uid())));
create policy "<t>_insert_denied" on public.<t> for insert with check (false);
create policy "<t>_update_denied" on public.<t> for update using (false);
create policy "<t>_delete_denied" on public.<t> for delete using (false);
```

**Aucune écriture par le client, jamais.** Tout passe par un RPC `SECURITY DEFINER`.
`content_registers` est la seule à ouvrir le `select` à tout `authenticated` : c'est
un catalogue.

---

## 2. `lib/billing/entitlements.ts` — ce qui est décidé en TypeScript

Le fichier fait 480 lignes. Ce qui est **décidé** (et non relu depuis la base) :

### 2.1 `isEntitledToMonthlyPresence(subscription, now)` — pure, et c'est là tout le sujet

```
entitled = status ∈ {active, trialing}
        || (status = 'past_due' ET current_period_end + 3 jours > maintenant)
```

`PAST_DUE_GRACE_DAYS = 3`. `now` est un paramètre pour que les quatre bornes soient
testables sans geler l'horloge. Un `past_due` sans `current_period_end` n'ouvre rien.

### 2.2 `canUseMonthlyPresence(supabase, subscription, now)` — LE point d'étranglement actuel

`isEntitledToMonthlyPresence(...)` **OU** `comp_access_active()`. Dans cet ordre, et
l'ordre est commenté : l'abonnement est déjà en mémoire, le comp est un aller-retour
réseau ; une abonnée payante ne paie jamais la requête.

### 2.3 Ce qui est déjà délégué à la base

- `isBrandKitEntitled` → RPC `brand_kit_entitled` (la base fait autorité, aucune
  seconde implémentation)
- `isCompAccessActive` → RPC `comp_access_active`

### 2.4 Ce qui reste décidé ici, et qui n'a pas d'équivalent SQL

- la grâce de 3 jours sur `past_due` (§2.1)
- `ENTITLING_STATUSES = {paid, partially_refunded}` — **transcription** de
  `brand_kit_entitling_statuses()`, épinglée des deux côtés par
  `entitlements-single-source.test.ts`
- `REVERSED_STATUSES = {refunded, disputed}` — choix de **texte**, pas de droit
- `resolveEntitledTier` : le plus généreux des achats `kind='tier'` **de ce projet**,
  relevé au dernier palier si un comp est actif
- `countUnpaidProjects` : plafond anti-abus, **fail-open** assumé

### 2.5 ⚠ Pourquoi le chokepoint SQL n'existe pas — c'est écrit, et c'était un arrêt

`20260901182419_comp_grant_entitlement.sql` s'arrête explicitement là-dessus, en
en-tête de migration :

> Monthly Presence entitlement is NOT centralised in the database. […] There is no
> database chokepoint to OR a comp check into without either (a) writing a fabricated
> `subscriptions` row, which `stripe_subscription_id text not null unique` makes
> impossible without inventing a fake Stripe id, or (b) an application-code special
> case, which is out of scope. Per instruction for exactly this case: **STOPPING**
> here rather than centralising Monthly Presence myself. A comp grant does not
> currently unlock Monthly Presence; this is a known, reported gap, not an oversight.

La PHASE 1.1 est donc la levée d'un arrêt documenté, pas une réécriture. Et l'objection
(a) ne tient plus dès lors qu'on écrit une **fonction** plutôt qu'une ligne : rien
n'oblige à fabriquer une `subscriptions`. Reste l'objection d'horloge — la base a
`now()`, la question était de savoir si la grâce devait y vivre. Le prompt tranche :
oui.

---

## 3. Ethics Guard et `banned_phrases`

### 3.1 `ethics_rules` — `20260827100000` §5

Six règles **en données** : `id`, `sort_order`, `active`, `short_label`,
`description`, `example_forbidden`. Un garde-fou de fin de migration refuse un compte
différent de 6. Lisible par `authenticated`, écriture refusée à tous.

### 3.2 `ethics_patterns` + les scanners — `20260914084054`

```
ethics_patterns(rule_id → ethics_rules(id), …)
```

Commentaire de table : « They lived only in TypeScript, where no SQL function can read
them — and a scan that runs only in the application does not cover text written straight
through a RPC. »

Deux fonctions, **toutes deux ouvertes à `anon`, `authenticated`, `service_role`** :

- `ethics_scan(p_text text)` — rend les correspondances
- `ethics_blocks(p_text text)` — rend le verdict

Et **trois triggers d'écriture** : `site_specs_ethics_gate`,
`content_items_ethics_gate`, `directory_profiles_ethics_gate`. La garde est donc
**dans l'écriture**, pas devant elle — une caption qui passerait par un RPC neuf est
déjà couverte si elle atterrit dans `content_items`.

⚠ **Ce que ça vaut pour la PHASE 4.5** : un label de diagramme qui n'atterrit pas dans
une colonne de `content_items` **n'est couvert par rien**. C'est exactement le trou que
la PHASE 4.5 nomme, et il est réel.

### 3.3 `banned_phrases` — `20260901074638` §1

`service_role` seul : `revoke all … from anon, authenticated`, aucune policy. Index
unique sur `lower(phrase)`. 30 formulations à l'origine, **+2 au 2026-09-20**
(`20260920081641_two_craft_cliches_join_the_thirty`, cf. §0.1 — **pas dans cette
branche**).

L'oracle est `usp_banned_phrases_check(p_text text)`, `SECURITY DEFINER` — elle existe
précisément parce que la table ne peut pas être lue par un client sans fuiter la liste.

**C'est elle qu'il faut appeler**, jamais une copie TypeScript de la liste : la copie
aurait 30 entrées là où la production en a 32.

---

## 4. `comp_grants` — forme exacte et lecture

### 4.1 La table — `20260901182351`

```
id uuid pk default gen_random_uuid()
user_id uuid not null → auth.users(id) on delete cascade
reason text not null            -- btrim(reason) <> ''
granted_by text not null        -- btrim(granted_by) <> ''
generation_credits integer not null default 200   -- >= 0
created_at timestamptz not null default now()
expires_at timestamptz NOT NULL -- ⚠ not null pour qu'aucun octroi ne devienne immortel par un NULL
revoked_at timestamptz
```

`unique index … (user_id) where revoked_at is null` — un seul octroi actif à la fois,
l'historique reste.

RLS activée **et aucune policy** : sous RLS, l'absence de policy refuse déjà tout le
monde sauf le propriétaire et `service_role`. Plus un `revoke all … from anon,
authenticated` en seconde barrière, plus un garde-fou qui fait échouer la migration si
une policy apparaît un jour.

### 4.2 Comment elle est consultée — le prédicat est écrit UNE fois

```sql
revoked_at is null and expires_at > now()
```

Jamais `not (expires_at <= now())` : un NULL de part et d'autre rendrait la négation
vraie, et c'est exactement par là qu'un défaut permissif fuit.

Trois fonctions, `20260901182419` :

| fonction | droits | rôle |
|---|---|---|
| `comp_grant_credits(uuid)` | **interne** — `revoke … from public, anon, authenticated` | les crédits de l'octroi actif, ou NULL |
| `comp_grant_active(uuid)` | **interne**, idem | `comp_grant_credits(…) is not null` |
| `comp_access_active()` | `authenticated`, `service_role` ; `anon` révoqué | scopée `auth.uid()`, **n'accorde rien**, signal d'affichage |

Les deux premières prennent un `p_user_id` arbitraire : les ouvrir laisserait un client
sonder le statut comp d'autrui. Le garde-fou de fin de migration le vérifie par
`has_function_privilege`.

Deux consommateurs réels : `brand_kit_entitled` (une clause `or`) et
`consume_generation_credit` (`greatest(v_regen_limit, least(v_comp_regen, 32767))` —
**élargit, n'abaisse jamais**, et ne touche pas `directions_limit`).

**Conséquence pour la PHASE 1.1** : `check_monthly_presence_entitlement(p_user uuid)`
doit appeler `comp_grant_active(p_user)` depuis **l'intérieur d'un corps
`SECURITY DEFINER`** — c'est le seul chemin, puisque la fonction n'est grantée à
personne. Les privilèges du propriétaire s'appliquent pendant l'appel ; aucun GRANT
supplémentaire n'est nécessaire, et **aucun ne doit être ajouté**.

---

## 5. Migrations appliquées

- **production** : 148 versions, de `20260823000000_reference_schema_from_live` à
  `20260920081641_two_craft_cliches_join_the_thirty`
- **cette branche** : 133 fichiers `.sql` + `RECOVERED.manifest`, dernière
  `20260917101901_a_button_that_breaks_is_not_shown`
- **écart** : 14 versions, §0.1, toutes sur `origin/claude/stoic-ritchie-1liqrz`

### 5.1 Hygiène de migration en vigueur dans ce dépôt

Relevée dans les fichiers, et elle contraint tout ce qui suit :

1. **Aucun fichier appliqué n'est renommé ni édité.** `RECOVERED.manifest` compare les
   **flux de tokens** (`scripts/sql_tokens.py`, un vrai lexer PostgreSQL, commentaires
   jetés, littéraux verbatim) et non des md5 d'octets, précisément pour distinguer
   « un commentaire ajouté » de « une clause WHERE retirée ». Un seul écart est toléré
   et il est nommé : 5 tokens, un initialiseur mort.
   `verify-recovered-migrations.sh` refuse tout autre écart.
2. **Toute table neuve reçoit RLS et ses policies dans la même migration.**
   `20260901190000_codify_rls_auto_enable`.
3. **Toute fonction reçoit `REVOKE`/`GRANT` explicites.**
   `20260902090000_revoke_internal_function_surface`.
4. **Toute `SECURITY DEFINER` a `set search_path = ''`**, sans exception dans les 133.
5. **Tout validateur jsonb rend `true`/`false`, jamais NULL.** C'est le registre du
   §6 ci-dessous.
6. Chaque migration porte un bloc **`-- DOWN`** en commentaire.
7. Les migrations qui ajoutent une contrainte à une table peuplée **comptent d'abord**
   et **s'arrêtent** si des lignes existantes échoueraient, plutôt que de gater la
   contrainte (`20260901074933` §, `20260830061119` §).

### 5.2 Le registre de validateurs NULL-safe — `20260830061119`

L'en-tête énonce la règle : une contrainte CHECK **rejette sur FALSE seulement**, donc
un validateur qui rend NULL accepte silencieusement. Le bloc de garde final rejoue
chaque validateur sur `'{}'`, `'null'`, `'"x"'`, `'42'`, `'[]'` et exige `false`, puis
rejoue une entrée bien formée et exige `true`, puis retire chaque clef une à une.

**C'est le registre auquel la PHASE 1.2 doit ajouter ses validateurs**, et sa forme
est imposée : un `foreach … in array array[…]` de noms de fonctions, pas une liste de
cas écrits à la main.

---

## 6. Tests Vitest

```
npx vitest run --reporter=dot
 Test Files  149 passed (149)
      Tests  2923 passed (2923)
   Duration  13.14s
```

Zéro rouge, zéro `skip` signalé. `node_modules` était absent à l'ouverture de la
session ; `npm install` rend 0.

Côté base, `supabase/tests/` porte des sondes `.test.sql` — dont
`20260914084054_ethics_guard_bites.test.sql`, qui est l'ancienne sonde de migration
devenue test, « posée contre la base telle qu'elle est » plutôt que rejouée après coup.

---

## 7. Décisions qui bloquent l'écriture, et qui ne sont pas techniques

Trois, et je m'arrête dessus plutôt que de trancher seul.

### 7.1 L'axe de propriété : `brand_kit_id` ou `user_id` ?

§0.5. Les six tables existantes sont clefées kit ; le prompt écrit user. Trois sorties :

- **(a) tout en `brand_kit_id`** — cohérent avec l'existant, RLS par simple copie du
  motif, `next_topic_for_user` devient `next_topic_for_kit`. Conséquence : le
  « jamais deux fois le même sujet, à vie » est par kit, donc un compte à deux kits
  peut revoir un sujet sur l'autre kit.
- **(b) tout en `user_id`** — colle au prompt, mais ajoute un second axe de propriété
  à côté du premier et une seconde forme de policy à maintenir.
- **(c) `user_id` dénormalisé à côté de `brand_kit_id`**, tenu par trigger — le pire
  des deux : deux sources pour un même fait.

**Recommandation : (a)**, avec l'anti-collision inter-utilisateurs de la PHASE 2.2
résolue par jointure vers `projects.user_id` — ce qui donne la fenêtre de 90 jours par
(État, modalité) **au niveau personne**, qui est le niveau où elle a un sens, sans
introduire de seconde colonne de propriété.

### 7.2 Onze archétypes contre cinq : extension ou seconde famille ?

`content_items.archetype ∈ {statement, question, notes, signature, story}`, et le CHECK
est lu par `lib/kit/render/social-posts.ts` qui rend déjà les cinq. Les onze du prompt
(`single_statement`, `quadrant_model`, `cycle`, …) ne sont pas un sur-ensemble : ils
sont un **autre découpage**. `single_statement` et `statement` sont probablement la
même chose ; `carousel` n'est pas une mise en page, c'est un **nombre de cartes**.

Et le dépôt a déjà payé ce prix une fois : l'en-tête de `20260910083735` raconte que
`register` et `archetype` ont été rendus **disjoints par construction**, avec un
garde-fou qui fait échouer la migration s'ils se recouvrent, parce que « deux
vocabulaires qui ne s'accordent que parce que les deux sont permissifs » avaient déjà
produit un défaut avec `min_tier`.

Élargir le CHECK de cinq à onze ferait donc exactement ce que ce garde-fou refuse, sur
l'autre axe. **Recommandation : une table `content_archetypes`** (catalogue, comme
`content_registers`), une clef étrangère depuis `content_items.archetype`, et la
correspondance vers les clefs du catalogue d'assets en données. `carousel` sort de
l'axe et devient un compte de cartes.

### 7.3 `gpt-image-2` — modèle non vérifié

La PHASE 4.4 impose `gpt-image-2` et interdit `gpt-image-1` pour cause de dépréciation
au 23 octobre 2026. **Je n'ai pas vérifié l'existence de `gpt-image-2`** : aucune clef
OpenAI n'est configurée dans ce dépôt (`.env.example` n'en porte pas), et le seul SDK
de modèle présent est `@anthropic-ai/sdk`. Le chemin visuel custom est donc écrit avec
le nom de modèle **piloté par variable d'environnement**, comme le prompt le demande
lui-même, et avec un défaut qui échoue proprement plutôt que d'appeler un modèle dont
je n'ai pas confirmé le nom.

---

## 8. Ce sur quoi la suite du chantier s'appuiera

Acquis, mesurés, réutilisables tels quels :

- la discipline réserver-puis-régler, avec son invariant dans la ligne et pas seulement
  dans le RPC (`content_image_allowance`)
- l'idempotence par `(kit, mois)` (`content_months`)
- l'empreinte + chemin de stockage + état, avec l'invariant
  `settled ⇔ storage_path is not null` (`content_grounds`)
- la garde éthique **dans** l'écriture, par trigger (`content_items_ethics_gate`)
- l'oracle `banned_phrases` par RPC, sans fuite de liste
- le socle Satori/resvg et ses 17 modules de rendu
- le registre de validateurs NULL-safe et sa forme de garde-fou

Et un trou réel, confirmé : **un label de diagramme qui ne transite pas par une colonne
de `content_items` ne passe aujourd'hui sous aucune garde.**
