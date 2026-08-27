# eklio-backend

Source de vérité unique du **schéma de base de données** d'Eklio.

Le code applicatif Next.js vit dans un repo séparé, `eklio-frontend`. Ce repo-ci
ne contient que le schéma et sa configuration Supabase.

## Répartition des responsabilités

Ce repo possède : les tables, colonnes, contraintes, policies RLS, triggers,
fonctions SQL déterministes et données de référence.

**Le repo Next.js `eklio-frontend` possède, et ce repo ne doit pas les
construire : tout appel à l'API Anthropic, le code d'application de l'Ethics
Guard, les e-mails transactionnels, toute orchestration planifiée, et la
surface HTTP que l'application expose.** Le serveur applicatif détient
`ANTHROPIC_API_KEY` et `SUPABASE_SERVICE_ROLE_KEY` ; la génération y est
orchestrée et seul son résultat est écrit ici.

Le test pratique en cas de doute : si ça demande un appel LLM, une requête
HTTP, une horloge ou un runtime, ce n'est pas le travail de ce repo. Exposer
plutôt la donnée et le SQL déterministe dont ça a besoin.

Trois conséquences visibles dans le schéma :

- `brand_kits.ethics_check` stocke le verdict de l'Ethics Guard et un CHECK en
  valide la forme. Le contrôle lui-même n'est pas implémenté ici.
- `ensure_month_skeleton()` ne crée que la structure d'un mois. Les titres et
  les légendes sont écrits ensuite par le front, là où vit le LLM.
- **Ni `pg_cron` ni job planifié.** Le passage mensuel demande des appels LLM,
  il est orchestré par le front sur sa propre planification. Ce repo garantit
  seulement qu'appeler `ensure_month_skeleton` deux fois est sans effet.

## Projet Supabase

| Ref | Région | Rôle |
|---|---|---|
| `fobgdsupyfslxbswfuay` | `us-east-1` | **actif** — cible de toutes les migrations |
| `enolgemfqeajrwpftppm` | `eu-west-1` | ancien projet, données de test. Conservé intact comme filet de sécurité. **Ne jamais y pousser de migration.** |

## Migrations

Toutes les migrations vivent dans [`supabase/migrations/`](supabase/migrations/)
et sont appliquées **exclusivement** via le CLI Supabase :

```bash
supabase link --project-ref fobgdsupyfslxbswfuay
supabase db push
```

Aucune modification de schéma ne doit être faite à la main (éditeur SQL du
dashboard, API Management). C'est précisément ce qui a produit la dérive que
`20260823000000_reference_schema_from_live.sql` a dû rattraper : une base sans
table `supabase_migrations.schema_migrations`, donc sans historique, et trois
jeux de migrations concurrents dont aucun ne décrivait l'état réel.

### `20260823000000_reference_schema_from_live.sql`

La **migration de référence**. Elle reconstitue le schéma réel observé le
2026-08-23 sur `enolgemfqeajrwpftppm` (eu-west-1), sans aucune donnée, anomalies
héritées comprises — celles-ci sont balisées par des blocs `-- ⚠ ANOMALIE`.
Reproduire fidèlement l'existant était le but : la réparation vient après, et
séparément, pour que l'historique se lise « ce qui existait » → « ce qu'on a
réparé ».

Elle rend obsolètes les trois jeux antérieurs, dont les branches ont été
supprimées :

| Repo | Branche | Fichiers |
|---|---|---|
| eklio-backend | `claude/eklio-bootstrap-ukuxfu` *(supprimée)* | `20260808000000_init_schema.sql` |
| eklio-frontend | `claude/eklio-design-system-flow-zmf8rl`, `claude/eklio-reconcile-us-base` | `20260809000000_init_projects.sql`, `20260815090000_init_directions.sql`, `20260816090000_fix_directions_schema.sql` |
| eklio-frontend | `claude/eklio-fr-us-migration-53dnk1` | `20260816000000_init_schema.sql`, `20260816010000_brand_kits.sql`, `20260816020000_billing.sql` |

### `20260823150000_cleanup_inherited_anomalies.sql`

Le **nettoyage**, appliqué. Il répare les anomalies balisées par la référence :

- clé étrangère `brand_kits.direction_id → directions(id)` rétablie, en
  `ON DELETE NO ACTION` (+ index sur la colonne référençante) ;
- trigger `updated_at` en double supprimé sur `projects` ;
- policy `FOR ALL` redondante supprimée sur `projects` ;
- table `brief_answers` supprimée (doublon inutilisé de `project_briefs`) ;
- `INSERT` / `DELETE` explicitement refusés sur `profiles` — ce qui documente
  l'existant sans élargir aucun droit.

Une anomalie a été **volontairement conservée** : `projects.user_id` référence
`profiles(id)` et non `auth.users(id)`. Ce n'est pas un défaut d'intégrité
(`profiles.id` cascade lui-même depuis `auth.users`), et le chaînage garde
`profiles` comme seule table applicative couplée à `auth`. Son seul coût est une
course possible juste après signup, qui sera traitée côté applicatif.

## Schéma

Vingt-deux tables, RLS activée sur chacune, cloisonnement par propriétaire.

Les dix tables applicatives :

- `profiles` — miroir 1:1 de `auth.users`, alimenté par le trigger
  `handle_new_user` ; `INSERT` / `DELETE` non exposés aux clients
- `projects` — une identité de marque en cours de génération
- `project_briefs` — le brief guidé, une ligne par projet
- `directions` — les 3 propositions créatives d'un projet
- `brand_kits` — le kit de marque final
- `generation_credits` — quotas de génération IA
- `subscriptions` — abonnement Monthly Presence, une ligne par utilisateur
- `purchases` — achats de kit (paiement unique), un événement par paiement
- `stripe_events` — journal d'idempotence des webhooks Stripe, `service_role` seul
- `monthly_presence_content` — calendrier de contenu mensuel, **une ligne par
  item** depuis la migration de réconciliation (voir plus bas)
- `launch_checklist_items` — les six étapes de lancement, six lignes par kit

Et les onze catalogues de référence, en lecture seule :
`tone_cards`, `palette_families`, `type_pairings`, `client_persona_cards`,
`problem_cards`, `gain_cards`, `ethics_rules`, `license_types`, `specialties`,
`site_goals`, `primary_actions`.

Aucune table n'est en `FORCE ROW LEVEL SECURITY` : le `service_role`, utilisé
côté serveur, contourne les policies. C'est le mécanisme sur lequel repose le
Lot 4 : le webhook Stripe écrit sans qu'aucune policy ne lui soit accordée,
tandis que le navigateur ne lit que ses propres lignes.

### `20260825160000_lot4_billing.sql`

Le **schéma de facturation**, appliqué. Paiement unique (kits, trois tiers) et
abonnement Monthly Presence sont deux modèles distincts et le restent en base :
un achat est un événement daté, un abonnement est un état courant.

- `brand_kits.tier` promu depuis `content` JSONB, **avec backfill** ;
- `profiles.stripe_customer_id` (unique) — une seule correspondance
  utilisateur ↔ client Stripe, partagée par les deux flux ;
- `subscriptions`, `purchases`, `stripe_events`, `monthly_presence_content` ;
- sur chacune : lecture propriétaire, écriture cliente **explicitement
  refusée** (`using (false)`). L'event trigger `ensure_rls` active la RLS mais
  ne crée aucune policy — elles sont toutes écrites à la main ;
- `stripe_events` n'est exposée à personne : RLS, aucune policy, et privilèges
  `anon` / `authenticated` révoqués.

#### La branche Lot 3, abandonnée — ce qu'elle portait et pourquoi

`claude/backend-lot3-brand-kits` (commit `1dd8a5f`, migration
`20260825120000_lot3_brand_kits_us.sql`) a été **supprimée sans être
fusionnée**. Elle ne définissait que deux colonnes sur `brand_kits` :

- **`tier`** — repris tel quel par le Lot 4, à la définition près identique,
  et **avec le backfill qui lui manquait**. Le Lot 3 avait été écrit en
  supposant `brand_kits` vide ; la table portait un kit dont le tier
  `signature` vivait dans `content`. Appliqué seul, il l'aurait déclassé en
  `starter`. Rien n'est perdu, le défaut est corrigé.
- **`status`** (`pending` / `generating` / `complete` / `failed`) —
  **délibérément abandonnée**, et c'est la seule décision de fond de cette
  suppression. La génération du kit est un appel unique tout-ou-rien : les
  trois gardes du front (structure, périmètre, déontologie) lèvent *avant*
  la moindre écriture, et la ligne n'est insérée qu'une fois le livrable
  complet et validé. Un `status` n'y aurait donc qu'une seule valeur
  atteignable — et son défaut `'pending'` aurait estampillé « en attente »
  des kits terminés, tant que le front ne l'écrit pas. L'avancement du
  projet est déjà porté par `projects.status`, que le front passe à `kit`
  juste après l'enregistrement.

  Si la génération devient un jour incrémentale ou reprenable — ligne créée
  avant que le contenu ne soit complet — la colonne redevient justifiée et
  sera reposée dans une migration **postérieure** au Lot 4, avec un défaut
  accordé à ce flux-là. C'est exactement le raisonnement qui a fait garder
  `status` sur `monthly_presence_content`, produit lui par un job planifié
  et rejouable.

La branche portait aussi une observation qui n'était pas du DDL, et qui reste
vraie : **`share_slug` est unique mais aucune policy ne permet à un visiteur
non authentifié de lire un kit partagé** (`brand_kits_all_own` exige
`projects.user_id = auth.uid()`, et pour `anon` `auth.uid()` vaut NULL). La
page de partage ne fonctionnera donc pas tant qu'une policy publique en
lecture n'aura pas été ajoutée, ou tant que la lecture ne passera pas par le
`service_role`. Ce n'est volontairement toujours pas tranché : ouvrir
`brand_kits` à `anon` exposerait le contenu intégral d'un livrable payant à
quiconque devine ou collecte un slug. Arbitrage produit et sécurité — entropie
du slug, révocabilité, exposition partielle — à traiter quand la page de
partage sera au programme.

---

## Lot 5 — le brief, le kit, le calendrier

Huit migrations, du 2026-08-27. Elles portent ce que les huit écrans validés de
[`design/reference/`](design/reference/) rendent réellement.

### Ordre d'application, et pourquoi il n'est pas celui de la commande

`20260827100000_catalog_reference_data.sql` passe **avant** la migration du
brief, alors que la commande listait le brief en premier. `brief_preview()`
résout les ids de palette, de typographie, de ton, de licence, d'action et de
spécialité contre les catalogues : ils doivent exister d'abord. Les deux
migrations sont indépendantes pour tout le reste.

### `20260827100000_catalog_reference_data.sql`

Les onze catalogues de référence. Chacun : `id text` en clé primaire,
`sort_order`, `active`. Pas de `created_at` / `updated_at` — l'historique d'une
ligne de catalogue, c'est l'historique git de ce repo.

`active` marque une carte qui n'est plus proposée. **Les lignes ne sont jamais
supprimées et la policy de lecture ne filtre pas dessus** : un brief qui a
choisi une carte depuis retirée doit continuer à la résoudre, sinon sa preview
perd sa palette en silence. C'est le front qui filtre `active = true` quand il
affiche le sélecteur.

RLS : **une seule policy par table, SELECT, `to authenticated`**. Aucune policy
d'écriture — sous RLS, l'absence de policy vaut refus, et un catalogue se
modifie en livrant une migration, pas depuis un client. `service_role`
contourne la RLS, c'est par là que passent les upserts.

Ces policies portent `to authenticated` alors qu'aucune policy existante du
schéma n'a de clause `TO`. L'écart est volontaire et c'est le seul endroit où
il compte : les policies existantes sont toutes des prédicats de propriété sur
`auth.uid()`, qui vaut NULL pour `anon` et se referment donc toutes seules.
`using (true)` n'a pas cette propriété — sans `to authenticated`, elle
publierait le catalogue produit à des visiteurs non authentifiés.

#### Pourquoi les données sont à DEUX endroits

Les lignes de catalogue sont des **données de production** : sans elles le brief
n'a aucune carte à proposer. Elles voyagent donc **dans la migration**, en
upserts idempotents (`insert … on conflict (id) do update`), parce que c'est ce
qui atteint `fobgdsupyfslxbswfuay`.

`supabase/seed.sql` **ne tourne qu'au `db reset` local et n'atteint jamais le
projet hébergé**. Il porte une copie **verbatim** des mêmes upserts, entre deux
marqueurs, pour qu'une base locale reste lisible et utilisable.

> **Les deux copies existent exprès. Modifier l'une sans l'autre est le piège.**
> Éditer la migration, puis régénérer le miroir :
>
> ```bash
> awk '/^-- >>> CATALOG DATA/,/^-- <<< CATALOG DATA/' \
>   supabase/migrations/20260827100000_catalog_reference_data.sql \
>   > /tmp/catalog.sql
> ```
>
> et recoller `/tmp/catalog.sql` sous l'en-tête de `supabase/seed.sql`.
> `db.seed` est câblé dans `config.toml`.

Les limites de rendu des maquettes sont des CHECK : mots-clés de ton joints
≤ 32 caractères (le label est en `white-space:nowrap`), label de carte ≤ 48,
description ≤ 90, overline de licence ≤ 12.

Une règle éditoriale que le SQL ne peut pas tenir, et qui est donc écrite en
commentaire dans la migration : **aucune palette vert sauge pâle, aucun bleu
poussiéreux**. C'est le défaut des annuaires de thérapeutes, celui auquel ce
produit existe pour échapper. Toute famille ajoutée ensuite doit le respecter.

### `20260827101000_brief_autosave_and_preview.sql`

**Il n'existe pas de table `briefs` et cette migration n'en crée pas.** Le
brief, c'est `project_briefs` (une ligne par projet, PK `project_id`), posée par
le schéma de référence. En créer une seconde produirait exactement la structure
parallèle que la migration de référence a servi à supprimer.

Toutes les colonnes de réponse sont nullables avec un défaut utilisable : un
brief à moitié rempli est l'état **normal** de cette table, pas une erreur.

`palette_family_ids` est **ordonné** — l'élément 1 est la palette « LEADING »
qui pilote la preview — et plafonné à 3.

Six colonnes vont au-delà de la liste demandée (`practice_name`, `positioning`,
`license_type_id`, `primary_action_id`, `specialty_ids`, `site_goal_ids`) :
`brief_preview()` les lit pour l'overline, le subhead, le CTA et les chips. La
spec décrivait ces champs de preview mais supposait les réponses déjà stockées ;
elles ne l'étaient nulle part.

> ⚠ **Recouvrement à connaître.** `projects.current_step` (smallint, 1..8) et
> `project_briefs.progress_step` (int, 1..7) suivent tous deux une position
> d'assistant et **ne sont pas synchronisés**. À lire comme deux choses
> distinctes : `projects.current_step` est le pointeur de cycle de vie du projet
> (brief → directions → kit), `progress_step` est l'étape à laquelle le brief
> reprend. À trancher si le front n'a besoin que d'un des deux.

Les références scalaires de catalogue ont de vraies clés étrangères
(`on delete restrict`) et leur index. **Les colonnes tableau n'en ont pas** :
Postgres 17 n'a pas de clé étrangère sur élément de tableau, et valider cinq
tableaux à chaque autosave mettrait une lecture de catalogue sur le chemin de la
frappe. Le coût d'un id qui ne résout pas est borné et documenté :
`brief_preview()` retombe sur son défaut pour ce champ. Postgres 18 ajoute les
FK sur éléments — c'est là qu'il faudra y revenir.

#### `brief_preview(brief_id uuid) → jsonb`

Toute la preview en **un aller-retour**. SQL pur, aucun appel externe, aucune
horloge : six petites tables de catalogue lues par clé primaire, plus la ligne
de brief.

`SECURITY INVOKER`, délibérément : demander le brief d'un autre rend **NULL**,
pas une erreur de permission, et jamais la preview de quelqu'un d'autre. En
`SECURITY DEFINER`, la fonction serait un oracle de lecture indexé par uuid.

Les fallbacks ne sont pas de la gestion d'erreur, c'est **l'état du premier
rendu** : l'écran 1 affiche déjà un site complet avant le moindre choix.
CLAY & SAND, Fraunces / Nunito Sans, `A calmer place to start.`,
`Book a consult`, et le subhead par défaut.

`truncate_on_word_boundary(text, int)` coupe le subhead à 60 sans casser un
mot. En SQL parce que la même règle vaudra pour le PDF, la page de partage et
le prompt de site : implémentée côté front, elle serait réécrite trois fois et
les trois divergeraient.

### `20260827102000_brand_kit_deliverable.sql`

Le livrable sur `brand_kits` : `directions` (exactement 3), `voice_guide`,
`social_templates` (exactement 4, dans l'ordre de rendu de l'écran 6),
`site_prompt` + `site_prompt_target`, `ethics_check`, `practitioner_line`.

Cette migration valide la **forme**. La suivante valide la **longueur**. Deux
contraintes par colonne, un seul rôle chacune, pour qu'une écriture refusée
nomme la règle tombée.

`selected_direction_id` est contraint à nommer une direction réellement présente
dans le tableau — la seule garantie référentielle que le jsonb enlevait et qui
valait d'être rachetée.

`site_prompt_target` est `text` + CHECK et non un enum Postgres : le schéma n'en
contient aucun (`projects.status`, `brand_kits.tier`, `purchases.status`…), un
CHECK s'amende par migration là où `ALTER TYPE` ne sait toujours pas retirer une
valeur.

> ⚠ **`brand_kits.direction_id` perd son `NOT NULL`.** C'était une FK vers la
> table `directions` héritée ; un kit produit par le flux de ces écrans n'y a
> pas de ligne. Sans ce changement, le nouveau flux ne peut pas écrire une seule
> ligne. La FK et son `ON DELETE NO ACTION` sont intacts pour les kits qui en
> portent déjà une.

> ⚠ **La table `directions` est supersédée, pas supprimée.** Elle porte
> six lignes sur le projet US et `brand_kits.direction_id` la référence.
> Supprimer une table peuplée pour ranger un doublon de nommage n'est pas une
> migration, c'est une perte de données. Le flux courant écrit
> `brand_kits.directions` et `selected_direction_id`.

### `20260827103000_rendering_constraints.sql`

Les huit écrans validés ne sont pas une charte, ce sont des limites dures.
Une copie qui déborde ne se dégrade pas, elle casse la grille — et ça arrive
**après** la génération, quand l'appel LLM est déjà payé. D'où des CHECK : une
génération trop longue est refusée à l'écriture, avec une violation que le front
rattrape et rejoue avant qu'un utilisateur voie quoi que ce soit.

| Champ | Limite | Ce qui casse sinon |
|---|---|---|
| `directions[].name` | ≤ 20, un ou deux mots | le titre passe sous le padding de la carte |
| `directions[].rationale` | 60–95 | 96 passe à une troisième ligne, les trois cartes cessent d'être alignées |
| `directions[].hero.headline` | ≤ 46 | débordement de la maquette de 250px |
| `directions[].hero.subhead` | ≤ 60 | idem |
| `directions[].tone_keywords` | 3 mots simples, joints ≤ 32 | le label est en `nowrap`, il élargit la carte |
| `social_templates[0..1].headline` | ≤ 34 | quatrième ligne dans la tuile carrée |
| `social_templates[2].headline` | ≤ 20 | label petites capitales à 0.14em de tracking |
| `monthly_presence_content.title` | ≤ 34 | légende de tuile sur une ligne |
| `directions[].typography.heading_font` | **3 valeurs distinctes** | trois cartes dans la même police se lisent comme une seule direction montrée trois fois |

La limite du calendrier est posée en §6, sur la colonne elle-même : sa table
n'existe pas encore à ce stade.

La migration **contient son propre garde-fou** : elle échoue si la copie livrée
dans `design/reference/` ne passe pas ses propres limites. Si l'un tombe, ce
sont les limites qui sont fausses, pas le design.

### `20260827104000_launch_checklist_items.sql`

Six lignes par kit, semées par trigger à la création, rendues en `3 OF 6`.
**Les six labels sont de la copie produit, rendus verbatim.**

`user_id` est dénormalisé alors qu'il est joignable par
`brand_kit → project → user` : c'est la seule table lue à chaque visite de
l'accueil, et la seule où l'`EXISTS` à deux jointures des autres policies coûte
plus que la duplication.

Idempotence : `unique (brand_kit_id, key)` + `on conflict do nothing`. Un kit
régénéré garde ses items **et** les `done_at` déjà gagnés.

**RLS dit quelles lignes, les privilèges de colonne disent quelles colonnes.**
`revoke update … from authenticated` puis `grant update (done_at)` : cocher un
item, c'est `done_at` ; `label` et `key` sont de la copie produit qui se trouve
habiter une ligne possédée par l'utilisateur. Seul le second mécanisme empêche
un client de réécrire sa propre checklist, et il laisse `service_role` intact.

`choose_direction` se coche seul quand `selected_direction_id` est posé, avec
`done_at is null` dans le WHERE : changer d'avis ne déplace pas un horodatage
déjà acquis.

### `20260827105000_monthly_content_calendar.sql`

> **Décision de réconciliation demandée par la commande :
> `monthly_presence_content` est REMODELÉE SUR PLACE. Aucune table
> `content_calendar_items` n'est créée. Il reste exactement une table de contenu
> mensuel.**

**Pourquoi remodeler plutôt qu'étendre.** Le Lot 4 avait posé la table à la
mauvaise *granularité*, pas avec les mauvaises colonnes : une ligne **par
mois**, `unique (project_id, month)`, tout le mois dans un blob `content`. Ce
que l'accueil rend est une grille de tuiles datées, verrouillées et floutées
individuellement — une ligne **par item**, seize par mois. Étendre l'une vers
l'autre aurait laissé un blob que personne ne lit à côté des seize lignes qui
comptent.

**Pourquoi c'est sûr sur place.** La table porte 0 ligne sur
`fobgdsupyfslxbswfuay` — vérifié contre le projet réel avant écriture, pas
supposé. Le garde-fou refuse de tourner si ça cesse d'être vrai : un changement
de granularité ne peut pas être une migration de données silencieuse, une
ancienne ligne en vaut seize et seul le front sait découper son blob.

`project_id` et `content` sont **supprimées**. La propriété passe par `user_id`
directement, plus `brand_kit_id`.

> ⚠ **La contrainte qui compte pour la sécurité :** une ligne `locked` ne peut
> porter ni `caption` ni `visual_spec`. L'accueil floute la tuile **en CSS** —
> donc tout ce que la ligne porte a déjà traversé le réseau. Sans cette
> contrainte, `filter: blur(9px)` **est** le paywall.

`ensure_month_skeleton(p_user_id, p_month)` — 16 créneaux (12 posts, 4 stories),
idempotente, rend le nombre de lignes réellement insérées, 0 au rejeu. Elle ne
crée que de la **structure** ; titres et légendes sont écrits ensuite par le
front. Les jours utilisés s'arrêtent au **28** : tous doivent exister en février
aussi, sinon « 16 items » serait faux onze mois sur douze. Statut initial selon
l'abonnement : abonné → 16 `draft` ; non-abonné → 1 `ready`, 15 `locked`.

`SECURITY INVOKER`, donc **appelable au `service_role` seulement**. En
`SECURITY DEFINER` elle offrirait à tout compte connecté un mois de contenu
gratuit sur n'importe quel uuid.

> ⚠ **Un seul kit par utilisateur**, résolu comme le plus récent. La signature
> imposée est `(user_id, month)` sans kit, et un utilisateur à deux projets a
> deux kits. Si Monthly Presence devient multi-projets, c'est cette signature
> qu'il faudra changer.

`calendar_summary(p_user_id, p_month)` rend `{ items, ready_count,
locked_count }` en une requête, pour que l'accueil n'en fasse pas trois.

### `20260827106000_subscription_state.sql`

**Le Lot 4 livrait déjà quatre des cinq champs demandés** — `status`,
`current_period_end`, `cancel_at_period_end`, `stripe_subscription_id` — **et
l'unicité sur laquelle le webhook fait son upsert idempotent existait déjà**
(`subscriptions_stripe_subscription_id_key`). Rien de tout cela n'est touché.

Manquait `active`. Colonne **générée** (`generated always as … stored`) et non
colonne écrite par le webhook : une colonne écrite serait une seconde copie de
`status`, posée par le même handler, et le jour où les deux divergent est le
jour où un abonné résilié garde son contenu ou un payant perd le sien.

> ⚠ **`active` n'est pas la règle de gating**, et c'est exactement la
> distinction que le Lot 4 faisait en refusant de mettre le gating dans un
> CHECK. `active` répond à une seule question : Stripe considère-t-il cet
> abonnement vivant (`active` ou `trialing`). Pure fonction de `status`, sans
> horloge. **La grâce sur `past_due` et toute comparaison de
> `current_period_end` à `now()` restent au front.**

### `20260827107000_english_only_schema.sql`

Toute la base en anglais américain : noms de colonnes, défauts, valeurs
stockées, `COMMENT ON`.

- `projects.metier` → `projects.profession`
- `directions.typographie_titre` → `directions.heading_font`
- `directions.typographie_corps` → `directions.body_font`
- défaut `projects.name` : `'Mon projet'` → `'My project'`, avec backfill des
  seules lignes portant encore exactement cette valeur
- les cinq `COMMENT ON` francophones restants, réécrits

Trois noms pour un seul concept, c'était ça le vrai coût du français :
`heading_font` / `body_font` sont déjà le vocabulaire de `type_pairings` et de
`brand_kits.directions[].typography`.

**Ce que la migration ne touche pas** : les commentaires SQL des trois
migrations antérieures. C'est l'historique appliqué du schéma ; réécrire une
migration déjà passée sur le projet hébergé est précisément la pratique que ce
repo existe pour arrêter. La règle vaut pour ce qui s'écrit à partir d'ici.

> ⚠⚠ **Cassant pour `eklio-frontend`.** Toute requête nommant `metier`,
> `typographie_titre` ou `typographie_corps` casse à l'application.
> **`types/supabase.ts` doit être régénéré contre le projet US avant tout
> travail sur le front.**

---

## Chemins de retour arrière

Le CLI Supabase n'a **pas de runner de down** : `db push` ne fait qu'avancer.
Chaque migration porte donc son script inverse en commentaire, dans un bloc
`-- DOWN` en fin de fichier — revenir en arrière est un copier-coller, pas une
fouille archéologique. Les dépendances entre migrations imposent l'ordre
inverse (le down des catalogues casse `brief_preview()` : passer celui du brief
d'abord).

## Tests

[`supabase/tests/`](supabase/tests/) — un fichier d'assertions SQL par
migration, sans runner JavaScript : en ajouter un contredirait la raison d'être
de ce repo. Voir [`supabase/tests/README.md`](supabase/tests/README.md) pour la
boucle de lancement et pourquoi ce n'est pas pgTAP (l'extension n'est pas
activée dans `config.toml`).

Chaque fichier est autonome, encadré par `begin; … rollback;`, donc rejouable
dans n'importe quel ordre sans `db reset` entre deux.

Couverture : la forme et les six fallbacks de `brief_preview` ; chaque limite du
tableau de rendu, à la borne exacte (95 passe, 96 refusé) ; les six labels de
checklist et les six `sample_hero` verbatim ; les six palettes hexadécimale par
hexadécimale ; l'idempotence de `seed_launch_checklist` et de
`ensure_month_skeleton` sur deux et trois passages ; la contrainte de paywall
sur les lignes `locked` ; et, sur chaque table possédée, **qu'un second
utilisateur obtient zéro ligne et non une erreur de permission**.
