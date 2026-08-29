# eklio-backend

Source de vérité unique du **schéma de base de données** d'Eklio.

Le code applicatif Next.js vit dans un repo séparé, `eklio-frontend`. Ce repo-ci
ne contient que le schéma et sa configuration Supabase.

## ⚠ Discipline NULL — à lire avant d'écrire un validateur

Trois défauts, trois lots, **une seule cause**. Chacun a été trouvé par la
mesure, aucun n'aurait échappé à une règle. Voici la règle.

### Ce qui est sûr, et ce qui ne l'est pas

| construction | sur une clé absente / une colonne NULL |
|---|---|
| `x ~ 'regex'`, `x = 'v'`, `not (x = any(…))` | **NULL** — le piège |
| `'libellé: ' \|\| x` | **NULL** — toute la ligne disparaît |
| `array_to_string(array[…, NULL, …], …)` | **l'élément est écarté en silence** |
| `jsonb_typeof(x) is distinct from 'string'` | TRUE — sûr |
| `coalesce(char_length(x), 0) <= 34` | absorbé — sûr |
| `x is null` | TRUE / FALSE — sûr |

### Les trois règles

1. **Tout corps de validateur est enveloppé dans `coalesce(…, false)`**, et teste
   la présence des clés avec `?&` *avant* leur format. Les seules réponses
   atteignables doivent être TRUE et FALSE.
2. **Toute concaténation qui peut rencontrer une colonne nullable passe par un
   résolveur ou un `coalesce`.** Jamais `p_spec->>'une_colonne'` à nu dans un
   `||`.
3. **Tout tableau assemblé pour la sortie a ses éléments coalescés avant le
   join.** `array_to_string` n'est pas une erreur qui se voit.

### Les trois défauts, comme exemples

**Un CHECK qui accepte NULL.** `brand_kit_palette_valid`
(`20260827102000_brand_kit_deliverable.sql`) chaînait des `p->>'clé' ~ regex`
avec AND. Clé absente → NULL, `true and NULL` → NULL, et **une contrainte CHECK
accepte NULL** ; elle ne refuse que sur FALSE. Une palette à laquelle il manquait
un rôle passait donc à l'écriture, puis cassait le choix de direction plus bas
dans la pile. L'audit a trouvé la même construction dans quatre autres
validateurs et une contrainte inline. Corrigé par
`20260829112000_null_safe_jsonb_validators.sql`, dont le test est **paramétré sur
`pg_proc`** : un validateur ajouté plus tard sans cette couverture fait échouer
la suite au lieu de partir avec le même trou.

**Une ligne entière effacée par une concaténation.** `site_spec_token_lines`
(`20260829118000_text_safe_variants.sql`) lisait `p_spec->>'primary_text_hex'` à
nu. Sur un spec littéral sans les colonnes dérivées, `'libellé' || ': ' || NULL`
vaut NULL — et **trois lignes de jetons disparaissaient d'un livrable payant**
sans la moindre erreur. Trouvé en lisant la sortie rendue, pas en lisant le code.
Tous les moteurs passent désormais par `site_spec_variant_of`.

**Un tableau qui perd ses trous en silence.** C'est ce qui a rendu le défaut
précédent invisible : `array_to_string` **écarte les éléments NULL** au lieu de
produire une ligne vide. Trois NULL dans le tableau, trois lignes en moins, zéro
signal. Un `coalesce` par élément aurait produit `« Primary as text: »` — moche,
visible, corrigé le jour même.

> **La leçon commune :** une valeur qui disparaît sans erreur est pire qu'une
> valeur qui échoue. Quand un choix existe entre « refuser bruyamment » et
> « rendre quelque chose d'incomplet », prendre le refus.

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

Vingt-six tables, RLS activée sur chacune, cloisonnement par propriétaire.

Les onze tables applicatives :

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
- `site_specs` — le spec de site éditable, une ligne par kit (Lot 6)

Et les quatorze catalogues de référence, en lecture seule :
`tone_cards`, `palette_families`, `type_pairings`, `client_persona_cards`,
`problem_cards`, `gain_cards`, `ethics_rules`, `license_types`, `specialties`,
`site_goals`, `primary_actions`, `section_types`, `builder_targets`,
`site_output_templates`.

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

## Lot 6 — le spec de site éditable

Sept migrations, du 2026-08-29. Jusqu'ici le kit de marque s'arrêtait à
`brand_kits.site_prompt` : un bloc de texte figé, généré une fois, à prendre ou
à laisser. Ce lot livre ce dont ce texte était fait — couleurs, typographie,
structure de pages et de sections, copie — sous la forme d'une ligne qu'elle
peut modifier, et qui pilote (a) une maquette rendue dans l'app et (b) un
livrable dérivé pour le constructeur de site de son choix.

### Les deux règles qui ont dicté toutes les décisions

**1. Eklio n'héberge pas et ne construit pas.** Pas de page publique, pas de
publication, pas de déploiement. La maquette est une référence de design
affichée dans l'app authentifiée. Aucune route non authentifiée n'est ajoutée,
aucune policy `anon` n'existe sur `site_specs`, et un garde-fou fait échouer la
migration si une policy y devient inconditionnelle ou cesse de tester
`auth.uid()`. La question non tranchée de `share_slug` n'est pas rouverte.

**2. Le spec est la source de vérité, le livrable en est dérivé** par une
fonction pure, sans appel LLM, jamais reparsée. Aucune colonne ne stocke un
livrable édité à la main, parce qu'éditer le livrable n'est pas une opération
supportée : elle édite le spec, et le rendu recommence.
`brand_kits.site_prompt` devient un **cache** de ce rendu — la flèche ne va que
dans un sens, et c'est ce qui autorise cette colonne à rester lisible pour ses
consommateurs actuels.

### Où vit la surface HTTP

Dans `eklio-frontend`, comme toujours, et elle est mince : le handler
authentifie, transmet le JWT de l'utilisatrice, appelle une fonction et renvoie
ce qu'il reçoit. Rien ici ne demande d'appel LLM, de requête HTTP, d'horloge ni
de runtime — par le test du README, tout tient donc dans ce repo.

> ⚠ **Appeler ces fonctions avec le JWT de l'utilisatrice, jamais en
> `service_role`.** C'est `auth.uid()` qui les cloisonne, et il vaut NULL sur une
> connexion `service_role` : un appel en service_role reçoit `unauthenticated`,
> pas le spec de quelqu'un. Même contrat que `brief_preview` et
> `calendar_summary`.

| Endpoint du produit | Fonction SQL |
|---|---|
| `GET /brand-kits/:id/site-spec` | `site_spec_get(uuid)` |
| `PATCH /brand-kits/:id/site-spec` | `site_spec_patch(uuid, jsonb)` |
| `POST /brand-kits/:id/site-spec/reset` | `site_spec_reset(uuid, text)` |
| `POST /brand-kits/:id/site-spec/target` | `site_spec_set_target(uuid, text)` |
| `GET /brand-kits/:id/site-output` | `site_output_get(uuid, text, text)` |
| `POST /brand-kits/:id/site-output/mark-copied` | `site_output_mark_copied(uuid)` |
| `POST /brand-kits/:id/site-spec/fix-contrast` | `site_spec_fix_contrast(uuid, text)` |
| les deux nouveaux blocs de `GET /catalog` | `site_catalog()` |

Toutes rendent du JSON. Les erreurs ont une seule forme,
`{ "error": { "code", "message", "field"? } }`, et sont **retournées, pas
levées** : un `raise` annulerait la transaction, ce qui convient à une violation
de contrainte et pas à « votre titre dépasse de quatre caractères », que le
front doit afficher sous le champ concerné. La validation précède toujours
l'écriture, donc une erreur retournée signifie que rien n'a été écrit.

**404 et jamais 403.** Le spec d'une autre utilisatrice n'est pas visible, donc
chaque fonction voit zéro ligne et répond `not_found` — la même réponse, au
caractère près, que pour un kit qui n'existe pas. Aucun chemin de code ne sait
qu'une ligne existe et refuse de la montrer, et c'est le seul genre qui puisse
divulguer son existence.

### `GET /brand-kits/:id/site-spec` → `site_spec_get(p_brand_kit_id)`

Tout l'état de l'éditeur en un aller-retour. `PATCH` rend **la même enveloppe**,
donc une frappe d'autosave coûte un appel et le client n'a jamais à re-fetcher
pour redessiner la maquette, le panneau de contraste et la bannière.

```json
{
  "spec": {
    "brand_kit_id": "cccccccc-…",
    "spec_version": 1,
    "last_copied_spec_version": null,
    "updated_at": "2026-08-29T07:44:44.277880+00:00",
    "primary": "#3B2C3A", "secondary": "#4A5361", "accent": "#6E2F44",
    "paper": "#FAF7F2", "light_neutral": "#F3EDE4", "dark_neutral": "#241B23",
    "type_pairing_id": "cormorant_source",
    "heading_font": "Cormorant Garamond", "body_font": "Source Sans 3",
    "google_fonts_url": "https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&…",
    "hero": {
      "overline": "LCSW · PORTLAND, OR",
      "headline": "Experienced care, without the noise.",
      "subhead": "Therapy for high-performing adults.",
      "cta_label": "Book a consult",
      "cta_target_url": null
    },
    "about_excerpt": "I work mostly with professionals who look fine from outside. …",
    "pages": [ { "key": "home", "label": "Home", "enabled": true, "sections": [
      { "key": "hero", "type": "hero", "enabled": true, "order": 1, "fields": {} }, … ] }, … ],
    "practice_details": {
      "practice_name": "Elm & Ember Therapy", "license_label": "LCSW",
      "license_number": null, "city": "Portland", "state": "OR",
      "email": null, "phone": null
    },
    "extra_instructions": null,
    "target": "squarespace",
    "seed_clamped": null
  },
  "preview":  { "practice_name": "Elm & Ember Therapy", "tokens": { … }, "pages": [ … ] },
  "contrast": { "pairs": [ … ], "worst_ratio": 5.66, "passes_aa": true },
  "output":   { "kind": "setup_sheet", "steps": [ … ], "copy_blocks": [ … ] },
  "diff":     { "stale": false, "changes": [] },
  "etag":     "f84ed47d93d724c9f033c4b410fbaa36"
}
```

`spec` ressort **avec les noms de clés que `PATCH` accepte** : ce qui se lit est
ce qui se réécrit, sans traduction dans un seul sens. Le suffixe `_hex` des
colonnes et la colonne de service `change_marks` ne quittent jamais la base.

`etag` est un md5 de `(brand_kit_id, spec_version, target)`. Tout ce dont le
livrable dépend est là, et ces trois valeurs ne bougent que par une écriture
réussie : le front peut le renvoyer tel quel en `If-None-Match`.

### `PATCH /brand-kits/:id/site-spec` → `site_spec_patch(p_brand_kit_id, p_patch)`

Partiel, pensé pour l'autosave, **sans aucun appel LLM ni externe** : une
recherche sur l'index unique `brand_kit_id`, de la manipulation jsonb en
mémoire, un UPDATE, une enveloppe. Rien n'y croît avec quoi que ce soit.

Clés acceptées (`site_spec_patchable_keys()`) : `primary`, `secondary`,
`accent`, `paper`, `light_neutral`, `dark_neutral`, `type_pairing_id`, `heading_font`,
`body_font`, `google_fonts_url`, `hero`, `about_excerpt`, `pages`,
`practice_details`, `extra_instructions`, `target`. Toute autre clé est refusée
en la nommant.

```json
// requête
{ "hero": { "headline": "A calmer place to start." } }
```

`hero` et `practice_details` sont **fusionnés clé par clé** : l'éditeur
enregistre un champ à la fois, et un remplacement d'objet perdrait les quatre
autres. `pages` est remplacé en bloc — une édition de structure est un
réordonnancement ou une bascule, et le client tient déjà tout le tableau.

Choisir `type_pairing_id` **adopte les deux fontes et la feuille de style** du
catalogue, sauf si le même patch nomme explicitement une fonte. Un id seul
laisserait à l'écran des polices que le sélecteur prétend avoir changées.

Les hexadécimales sont mises en majuscules à l'écriture : un sélecteur de
couleur envoie une casse arbitraire, et le livrable doit être identique octet
pour octet à chaque rendu du même spec.

```json
// refus : la limite est nommée, et le champ aussi
{ "error": { "code": "too_long", "field": "hero.headline",
             "message": "This is 91 characters. The limit is 90." } }
```

Codes : `unauthenticated`, `not_found`, `invalid_body`, `unknown_field`,
`invalid_field`, `too_long`.

> ⚠ **Un patch sans effet n'incrémente pas `spec_version`.** L'autosave se
> déclenche à chaque frappe, y compris celle qui tape un caractère et celle qui
> l'efface : bumper là lèverait la bannière « modifié depuis votre copie » sur
> une édition qui s'est annulée elle-même.

### `POST /brand-kits/:id/site-spec/reset` → `site_spec_reset(id, scope)`

`scope` ∈ `all | colors | typography | copy | structure`. Restaure cette portée
depuis la direction choisie.

> ⚠ **Réinitialiser une portée ne doit jamais en coûter une autre.** `copy`
> restaure le texte par défaut **dans la structure qu'elle a construite** — son
> réordonnancement et ses bascules survivent. `structure` restaure la
> disposition par défaut en **gardant la copie** de chaque section qui y a
> encore sa place.

Deux choses qu'aucune portée ne touche, `all` compris : la **cible de
constructeur**, qui vient du brief et non de la direction et qui a sa propre
bascule ; et **son lien de réservation**, qu'aucune direction n'a jamais produit,
donc qu'aucun reset ne peut restaurer ni ne doit effacer. `all` est la seule
portée qui efface ses notes libres, parce qu'`all` veut dire « le spec
qu'implique la direction », et ce spec n'en a pas.

### `POST /brand-kits/:id/site-spec/target` → `site_spec_set_target(id, target)`

Bascule le constructeur, régénère le livrable, ne touche à rien d'autre. C'est
une enveloppe mince autour du patch, et c'est le but : « ne touche à rien
d'autre » est déjà la garantie d'un patch partiel, donc la garantie a une seule
implémentation au lieu d'être promise deux fois.

### `GET /brand-kits/:id/site-output` → `site_output_get(id, target, format)`

`format` ∈ `json | md | txt` (défaut `json`). `target` optionnel : la cible du
spec par défaut. **Demander le livrable pour un autre constructeur ne bascule
pas le constructeur.**

```json
{ "target": "squarespace", "format": "md", "text": "# Squarespace\n\n## 1. Start from the right template\n…" }
```

`format=md` est le chemin PDF / impression.

### `POST /brand-kits/:id/site-output/mark-copied` → `site_output_mark_copied(id)`

Pose `last_copied_spec_version = spec_version` et rend l'enveloppe.

> ⚠ **La seule action qui ne doit pas incrémenter `spec_version`.** Enregistrer
> qu'elle a copié la version 7 en faisant discrètement passer le spec en 8
> laisserait la bannière levée juste après la copie censée l'éteindre.
> Idempotente : copier deux fois est normal.

### `POST /brand-kits/:id/site-spec/fix-contrast` → `site_spec_fix_contrast(id, pair_id)`

Applique l'hexadécimale corrigée que `site_spec_contrast` proposait pour cette
paire, et rend l'enveloppe complète. Elle **recalcule** la suggestion au lieu de
faire confiance à une valeur envoyée par le client : le spec a pu bouger depuis
que le panneau a été dessiné. Une paire déjà lisible rend `no_fix_needed`, pas
une seconde écriture.

### `GET /catalog` → `site_catalog()`

Deux blocs de plus, dans la forme exacte que fixe la commande — la clé est
`type`, pas `id` :

```json
{
  "section_types": [
    { "type": "hero", "label": "Hero",
      "description": "The first screen: a short overline, one headline, …",
      "fields": [ { "key": "headline", "label": "Headline", "kind": "text", "max_length": 90 }, … ],
      "default_enabled": true, "allowed_pages": ["home"],
      "source": "spec.hero", "active": true } , … ],
  "builder_targets": [
    { "id": "lovable",     "label": "Lovable",     "accepts_prompt": true,
      "output_kind": "prompt",      "docs_url": "https://docs.lovable.dev/", "active": true },
    { "id": "squarespace", "label": "Squarespace", "accepts_prompt": false,
      "output_kind": "setup_sheet", "docs_url": "https://support.squarespace.com/", "active": true }, … ]
}
```

`source` est la clé que la commande ne liste pas et dont l'éditeur ne peut pas
se passer : le héros range sa copie dans `site_specs.hero` et l'intro dans
`site_specs.about_excerpt`, pas dans les `fields` de la section. Sans elle,
l'éditeur afficherait un formulaire sur un objet que rien ne lit.

### `accepts_prompt` : le drapeau qui justifie tout le reste

Lovable, Framer, v0 et une cible générique ont un champ où coller un prompt.
**Squarespace, Wix et Webflow n'en ont aucun.** Pas un champ caché, pas un champ
en bêta : l'interaction n'existe pas dans ces produits. Leur servir un prompt,
c'est ne rien livrer en ayant l'air de livrer quelque chose — et c'est le défaut
que l'unique colonne `site_prompt` porte aujourd'hui.

`accepts_prompt` est donc une colonne **générée** depuis `output_kind`, pour la
raison de `subscriptions.active` : écrite à la main, elle serait une seconde
copie tenue par le même INSERT, et le jour où les deux divergent est celui où
une utilisatrice Squarespace reçoit un prompt.

Les trois qui n'en ont pas reçoivent une **fiche de mise en route** : des étapes
numérotées nommant le panneau réel de leur produit — Squarespace `Site Styles ›
Colors`, Wix `Site Design › Color Palette`, Webflow `Style Manager › Variables ›
Colors` — et chaque chaîne à saisir isolée dans son propre bloc copiable, un par
item de liste. Ces noms de panneaux sont des **colonnes de catalogue**, pas un
CASE au fond d'une fonction : quand un constructeur renommera un panneau, la
correction sera une migration de données.

### Le péage, dans le seul endroit par où tout passe déjà

Il n'y avait pas de paywall. `paid` était une branche côté client, aucune route
ne lisait `purchases`, et tout l'aval pendait à `selected_direction_id`. Un
compte connecté obtenait le kit, le PDF et l'éditeur de site gratuitement,
pendant qu'Eklio payait 0,09 à 1,80 $ la génération.

**La révélation reste gratuite** — voir trois directions, c'est l'argumentaire.
Tout ce qui suit le choix d'une direction est payant.

La barrière est ici et pas dans les routes Next parce qu'il y a sept routes
aujourd'hui, davantage demain, et qu'**une seule qui oublie annule toutes les
autres**. Ces RPC sont déjà cadrées par `auth.uid()` ; le droit d'accès a sa
place à côté.

⚠ **La phrase est écrite une fois.** `brand_kit_entitled` est la seule définition
de « elle a payé ce kit ». Tout le reste l'appelle. Une seconde copie dans une
route, ou dans une policy, est une copie qui dérive — et un péage qui dérive est
un péage ouvert sur un chemin.

`generation_credits.has_paid` était précisément cette seconde copie, en attente :
une colonne qui dit « payé » et que rien n'écrit. Elle est marquée morte.

**Trois réponses, pas deux.** L'ordre est une décision de divulgation :

| état | réponse |
|---|---|
| pas de `auth.uid()` | `unauthenticated` |
| le kit n'est pas le sien, ou n'existe pas | `not_found` |
| il est à elle et non payé | `payment_required` |
| à elle, payé, mais pas de spec | `not_found` |

La propriété est testée **avant** le droit d'accès, sinon `payment_required`
confirmerait qu'un identifiant appartenant à quelqu'un d'autre existe. Et « elle
a un kit qu'elle n'a pas payé » n'est pas « il n'y a rien ici » : l'interface
ouvre le paiement sur l'une et s'excuse sur l'autre.

Le choix d'une direction est refusé **deux fois** : par la RPC, qui rend la même
enveloppe JSON que le reste pour que le front puisse ouvrir le paiement, et par
un trigger sur `brand_kits`, parce que la barrière ne doit pas dépendre du fait
que l'appelant choisisse la porte polie.

> ⚠ Le trigger ne s'applique qu'à un appelant **porteur d'un JWT**. Une
> migration, le webhook Stripe en `service_role`, une cascade : aucun n'a
> d'`auth.uid()`, et aucun ne doit s'entendre dire qu'il n'a pas payé. Un
> navigateur ne peut jamais arriver ici sans JWT.

#### Le compteur que la partie mesurée pouvait remettre à zéro

`generation_credits` existait depuis l'import du schéma et rien ne l'écrivait.
⚠ Et la policy était `for all` avec la propriété des deux côtés : une
propriétaire connectée pouvait faire `update generation_credits set
regenerations_used = 0`. Un compteur que la partie mesurée peut remettre à zéro
n'est pas un compteur. La policy devient lecture seule, les privilèges suivent.

`consume_generation_credit` décrémente en **une seule instruction**. C'est le
point : l'UPDATE prend le verrou de ligne, et en READ COMMITTED un appelant
concurrent qui attendait réévalue le WHERE contre la ligne telle que le gagnant
l'a laissée. Deux POST simultanés ne peuvent pas passer tous les deux. Lire les
compteurs puis décider — en SQL ou dans une route — est exactement la course que
cette fonction remplace.

Elle échoue **fermée** : allocation épuisée, pas connectée, pas son kit, c'est
`false` dans tous les cas. Il n'y a qu'une question posée.

#### Un litige n'est pas un remboursement

`pending|paid|refunded|failed` ne sait pas dire « contesté », un remboursement
partiel n'est ni l'un ni l'autre, et `dispute.closed: won` doit **restaurer ce
qu'il y avait avant** — ce qu'une colonne mutable seule ne peut pas faire,
puisqu'elle ne se souvient pas.

`purchase_status_events` est ajout seul : identifiant d'événement Stripe unique
(idempotence, Stripe rejoue), statut précédent **enregistré et jamais accepté de
l'appelant**, statut nouveau, montant, horodatage, type d'événement brut.
`purchase_status_before(id, 'disputed')` rend ce que la transaction était
réellement avant le litige — qui peut être `partially_refunded`, pas `paid`.

⚠ L'ajout seul est un **trigger**, pas une policy : le propriétaire de la table
et toute fonction `SECURITY DEFINER` passent au-dessus d'une policy. Seul un
trigger refuse tout le monde.

### Le chemin chaud, et les 500 ms qui n'étaient pas du SQL

La commande tient `PATCH` à 150 ms. Mesuré sur un spec amorcé, il en prenait
**530**, et `GET` 265. Rien de tout cela n'était le SQL :

| | mesuré |
|---|---|
| `site_spec_preview_model` | 0,8 ms |
| `site_spec_contrast` | 6,4 ms |
| `site_spec_diff` | 0,6 ms |
| `site_spec_copy_blocks` | **253 ms** — 1,4 ms avec `jit = off` |

`EXPLAIN ANALYZE` situait les 300 ms dans le *démarrage* d'un seul
`Function Scan` sur dix-huit lignes : c'était la **compilation JIT**. Ces
requêtes parcourent du jsonb — `jsonb_array_elements` imbriqué trois fois, un
lateral par section, un `CASE` par champ — et le planificateur en chiffre le
coût en comptant les nœuds d'expression, ce qui dépasse largement
`jit_above_cost`. Postgres compile alors l'arbre avec LLVM pendant trois à
quatre cents millisecondes, puis exécute soixante lignes.

Le modèle de coût n'a pas tort sur la *forme* de la requête ; il a tort sur le
nombre de lignes que cette forme verra un jour, et ici ce nombre est fixé par le
produit : quatre pages, une vingtaine de sections. `20260829107000_site_spec_hot_path.sql`
pose donc `set jit = 'off'` **fonction par fonction**, jamais au niveau de la
base — `jit` est un réglage de cluster sur un projet hébergé que ce repo ne
possède pas, et le couper partout serait laisser cette fonctionnalité décider
pour toutes les autres requêtes. Après : `GET` 9 ms, `PATCH` 14 ms.

> ⚠ Ces réglages vivent dans `pg_proc.proconfig`, qu'un
> `create or replace function` **efface en silence** s'il ne répète pas la clause
> `SET`. Toute migration qui remplace une de ces fonctions doit reporter
> `set jit = 'off'`, et un garde-fou plus un test le vérifient — parce que le
> symptôme n'est pas une erreur, c'est un autosave qui revient discrètement à
> une demi-seconde.

### Le second coût fixe : quatre couleurs redérivées à chaque écriture

Le JIT réglé, `PATCH` est resté autour de 140 ms sur un spec réel — et **le
chiffre ne bougeait pas quand le spec grossissait**. Un spec délibérément lourd
(quatre pages, les 26 sections autorisées, chaque champ texte à sa limite de 800
caractères, enveloppe de 129 Ko) se corrigeait dans le même temps qu'un spec de
quatre sections. Un coût qui ignore la taille de l'entrée n'est pas un coût de
données : c'est du travail fait quoi qu'il arrive.

`auto_explain` avec `log_nested_statements` l'a situé : trois exécutions de ~39 ms
de la marche à 91 candidats de `site_spec_suggest_hex`, **à l'intérieur d'un
PATCH qui ne changeait que `about_excerpt`**.

⚠ `maintain_site_spec_text_variants` recalculait les quatre couleurs dérivées à
**chaque** UPDATE, quoi qu'il ait changé. Corriger un titre relançait quatre
recherches de couleur dont aucune entrée n'avait bougé. Sur une famille dont les
couleurs de marque demandent toutes une variante — quatre des six livrées — cela
faisait ~120 des 140 ms.

Chaque variante n'est désormais recalculée que si **ses** entrées ont bougé.
Mesuré dans une seule session, sur le spec lourd :

| | `GET` | `PATCH` copie | `PATCH` primaire | `PATCH` papier |
|---|---|---|---|---|
| avant | 28 ms | **164–179 ms** | 143–151 ms | 171–207 ms |
| après | 28 ms | **47–51 ms** | 105–111 ms | 130–145 ms |

L'autosave — le chemin fréquent — passe sous le tiers de son coût. Les écritures
de couleur restent chères parce qu'elles paient la marche qu'elles demandent :
une pour la primaire, trois pour le papier qui nourrit les trois variantes.

> ⚠ La branche qui saute le calcul assigne **`old.<colonne>`**, elle ne laisse
> pas `new.<colonne>` tel quel. La différence est tout le sujet : un trigger qui
> se contentait de sortir tôt laisserait une cliente écrire une variante à la
> main, alors que ces colonnes existent précisément pour qu'elle ne le puisse
> jamais. Le test le vérifie dans les deux sens.

C'est la même forme que la section de voix rendue deux fois par enveloppe : du
travail dérivé répété parce que rien ne disait quand le sauter. **Quand une
mesure ne varie pas avec la taille de l'entrée, chercher le travail
inconditionnel avant de chercher une requête lente.**

### Les fonctions pures

| Fonction | Volatilité | Ce qu'elle rend |
|---|---|---|
| `site_spec_preview_model(spec)` | `IMMUTABLE` | ce que la maquette dessine |
| `site_spec_contrast(spec)` | `IMMUTABLE` | les six paires WCAG, avec correctif |
| `site_spec_output(spec, target)` | `STABLE` | le livrable, selon `output_kind` |
| `site_spec_diff(spec)` | `IMMUTABLE` | `{ stale, changes }` |

Elles prennent le spec **en jsonb** (`to_jsonb(site_specs)`), pas un uuid. Deux
conséquences qui valaient d'être achetées : elles se testent contre un littéral,
sans fixture ni RLS ni ligne ; et elles ne peuvent rien divulguer, là où une
fonction qui prend un uuid et lit une ligne demande qu'on raisonne sur son
cloisonnement.

`site_spec_output` parcourt `site_spec_preview_model`, pas la ligne brute. Le
livrable et la maquette **décrivent donc le même site par construction** : une
seule fonction décide des pages listées, de leur ordre et de la copie de chaque
section.

### D'où vient l'accent

⚠ **Vérifié plutôt que supposé.** `brand_kit_palette_valid`, livré au lot 5,
exige exactement cinq rôles — `primary, secondary, light, dark, paper`. Il n'y a
pas d'`accent`. `palette_families` a les mêmes cinq colonnes, la copie approuvée
de l'écran 4 les mêmes cinq, et le mot « accent » n'apparaissait nulle part dans
le schéma avant le lot 6.

L'accent n'est jamais une copie du secondaire : deux pastilles identiques sous
deux libellés différents se lisent comme un bug de l'éditeur, et se comportent
comme tel dès qu'elle déplace l'une des deux.

Il est **curaté**, pas dérivé. `palette_families.accent_hex` porte six valeurs
choisies à la main, dans le registre de leur propre famille — un frère plus
chaud ou plus profond, jamais un contraste complémentaire. La dérivation
existait d'abord et produisait un bleu-vert pour CLAY & SAND, un vert olive pour
PLUM & BONE : une rotation de teinte marche droit dans le **vert sauge et le
bleu poussiéreux** que la règle éditoriale de ce repo interdit, et automatisait
donc leur injection dans des palettes choisies à la main.

Ordre de résolution : l'accent envoyé par le générateur, puis celui curaté de la
famille (retrouvée en appariant les cinq hexadécimales), puis la dérivation.

Celle-ci reste le repli pour une palette qui n'est pas des nôtres, inchangée :
teinte du primaire tournée à sa complémentaire fendue (150°, puis sept décalages
de repli), saturation plancher à 0,28 pour qu'un primaire quasi gris ne rende
pas un accent gris, clarté prise sur une échelle fixe au plus près de celle du
primaire tout en atteignant **4,5:1 sur le papier**, et distance perceptuelle
d'au moins **ΔE 15** du primaire *et* du secondaire.

Changer un accent curaté est **une ligne** dans le bloc balisé de
`20260829114000_palette_accent.sql`. Le garde-fou revérifie distance,
lisibilité et la règle éditoriale (teinte hors de l'arc vert/bleu 75-260) à
chaque application, et imprime le tableau de revue.

Le seuil est mesuré, pas choisi : le produit livre déjà PLUM & BONE à ΔE 18,10
entre son primaire et son secondaire, et CLAY & SAND à 25,37. ΔE est du CIE76
sur CIELAB D65, dont la linéarisation sRGB est partagée avec
`site_spec_relative_luminance`.

`site_specs.accent_hex` lit tout de même `palette.accent` **en premier** : le
jour où le générateur émet la palette à cinq rôles que décrit la spec produit,
il est utilisé tel quel, sans rien changer ici.

> ⚠ **Un défaut du lot 5, signalé et non corrigé ici.**
> `brand_kit_palette_valid` rend `NULL` — pas `false` — pour une palette à
> laquelle il manque une de ses cinq clés, parce que `NULL ~ '^#…'` vaut NULL et
> que `true and NULL` vaut NULL. **Une contrainte CHECK passe sur NULL.** Une
> palette de forme `{primary, secondary, accent, light_neutral, dark_neutral}`
> est donc acceptée par `brand_kits` aujourd'hui. Resserrer ce CHECK est une
> décision séparée, avec son propre rayon d'action, et elle reste à prendre.
> Ce que le lot 6 fait à la place, c'est rendre l'amorçage **total** :
> `site_spec_palette_role()` résout les deux nommages et retombe sur CLAY & SAND
> pour un rôle absent, donc aucune forme de palette ne peut transformer un kit
> enregistré en direction inchoisissable.

### Les limites sont publiées, et le rognage n'est plus muet

`GET /catalog` porte `site_spec_limits` — `hero_overline`, `hero_headline`,
`hero_subhead`, `hero_cta_label`, `about_excerpt`, `section_text`,
`extra_instructions` — pour que le générateur borne ce qu'il écrit. Les nombres
sont **extraits des contraintes elles-mêmes** (`pg_get_constraintdef` pour deux,
`prosrc` des validateurs pour cinq) et non réécrits ; un garde-fou **sonde**
chaque validateur pour prouver que la valeur publiée est la vraie borne, n
passant et n+1 refusé.

`site_specs.seed_clamped` enregistre ce que l'amorçage a raccourci, et NULL —
pas `{}` — quand rien ne l'a été. La note se retire d'elle-même, champ par
champ, dès qu'elle réécrit le champ concerné ; un reset de la copie réapplique
le même texte rogné, donc la note y survit.

Mesuré : `headline` (46) et `subhead` (60) sont **déjà** bornés en amont par
`brand_kit_directions_rendering_valid` et ne peuvent jamais arriver trop longs.
Les trois réellement rognables sont `overline`, `cta_label` et `about_excerpt`.

> ⚠ « Restaurer le texte complet » est impossible pour un champ rogné parce
> qu'il dépassait la limite : la limite est un CHECK. L'original reste lisible
> dans `brand_kits.directions[selected].hero`, donc la note peut le montrer et
> la laisser réécrire à la bonne longueur — pas l'enregistrer tel quel.

### Six jetons, et le contraste mesuré sur ce qui est peint

Une palette de direction porte cinq rôles ; le spec en portait cinq — mais pas
les mêmes. Un accent est arrivé et **`paper` avait disparu**. Le mappage est
maintenant complet et ne perd aucun rôle source :

| source (`directions[].palette`) | spec (`site_specs`) |
|---|---|
| `primary` | `primary` |
| `secondary` | `secondary` |
| `light` | `light_neutral` — teinte d'un bandeau ou d'une carte |
| `dark` | `dark_neutral` |
| `paper` | `paper` — **le fond de page**, la plus grande surface du site |
| *(aucun)* | `accent` — curaté au catalogue, dérivé en repli |

`site_spec_palette_role()` accepte aussi les noms `light_neutral` /
`dark_neutral` : une ligne écrite pendant que le trou NULL était ouvert reste
lisible.

Les paires de contraste passent de six à **sept**, et la surface change. Elles
étaient toutes mesurées contre `light_neutral` ; le texte repose sur `paper`.

| paire | ce qu'elle mesure |
|---|---|
| `cta_label_on_primary` | le libellé sur le bouton |
| `dark_neutral_on_paper` | **texte courant sur la page** — celle qui compte le plus |
| `primary_on_paper` | liens et titres sur la page |
| `secondary_on_paper` | titres secondaires sur la page |
| `accent_on_paper` | marques d'accent sur la page |
| `dark_neutral_on_light_neutral` | texte courant dans un bandeau teinté |
| `paper_on_dark_neutral` | texte inversé dans une section sombre |

> ⚠ **Aucune des deux surfaces ne bouge jamais.** `paper` porte cinq des sept
> paires et le bandeau une : corriger l'une pour réparer une paire changerait
> toutes les autres dessinées dessus. Le jeton déplacé est toujours l'encre ou
> une couleur de marque.

Le livrable **déclare le fond de page explicitement**. Sans ça, un constructeur
met le site en blanc quoi qu'en dise la palette.

### Deux jeux de limites, et qui lit lequel

`GET /catalog` porte deux blocs, parce que deux choses différentes sont bornées :

- **`direction_limits`** — ce que le **générateur** doit respecter en produisant
  `brand_kits.directions`. Titre ≤ 46, sous-titre ≤ 60, nom ≤ 20 (un ou deux
  mots), justification 60–95, mots-clés de ton joints ≤ 32. Appliqué par
  `brand_kit_directions_rendering_valid`.
- **`site_spec_limits`** — ce que l'**éditeur** doit respecter quand la
  thérapeute tape. Titre ≤ 90, sous-titre ≤ 220, overline ≤ 48, CTA ≤ 28,
  « à propos » ≤ 600, champ de section ≤ 800, notes ≤ 2000. Appliqué par les
  CHECK de `site_specs`.

> ⚠ **Les limites de direction sont les plus serrées, et ce n'est pas une
> incohérence à réconcilier.** Une direction est rendue trois de front sur
> l'écran de révélation, dans une maquette de 250px ; un spec de site est rendu
> une fois sur une page. Publier un seul bloc dirait au générateur qu'il a 90
> caractères de titre là où le CHECK amont en accepte 46 — et le refus tombe
> après que la génération a été payée. Un garde-fou échoue si les deux jeux
> cessent d'être ordonnés ainsi.

Les deux sont extraits de leurs propres validateurs et **sondés** : n passe,
n+1 est refusé.

### La copie du livrable est un catalogue

`site_output_templates`, clé de fragment et cible optionnelle. `target IS NULL`
vaut « tous les constructeurs » ; une ligne avec cible ne prime que pour
celui-là. Une modification de formulation est un `UPDATE`, pas une migration —
même principe que les onze catalogues du brief.

Les noms de panneaux étaient déjà de la donnée (`builder_targets.color_panel`
et consorts). Ce qui a bougé, ce sont les titres et corps d'étapes, le bloc de
contraintes, les en-têtes du prompt et tous les libellés de champs : environ
deux cents littéraux répartis dans six corps de fonctions.

Ce qui reste dans les fonctions est du **balisage** et non de la copie : les
délimiteurs `"""` et ```, la puce, les sauts de ligne.

Un garde-fou vérifie que chaque fragment demandé par les moteurs existe — une
ligne manquante ne lève pas, elle rend une chaîne vide — et que les marqueurs
`{cta_target_url}`, `{page}`, `{section}`, `{label}`, `{value}` survivent à une
réécriture.

### Le contraste se rapporte, il ne bloque pas

`site_spec_contrast` calcule les six paires que la maquette dessine réellement,
et pas le produit croisé des cinq jetons : sur vingt combinaisons la plupart
n'apparaissent nulle part sur la page, et chaque fausse alerte apprend à ignorer
la vraie.

Arithmétique en `numeric` et non en flottant — le ratio est arrondi à deux
décimales puis comparé à 4,5, donc une paire sur la frontière se joue au dernier
bit. Le niveau est dérivé du ratio **arrondi**, pour qu'un « 4.50 » ne puisse
jamais s'afficher à côté du mot `fail`.

Le correctif garde teinte et saturation et ne déplace que la clarté (HSL, faute
de bibliothèque OKLCH dans Postgres), en cherchant la valeur **la plus proche de
la sienne** qui atteint 4,5 — pas la première d'une direction devinée. Il
déplace toujours une couleur de marque, **jamais le fond de page** : cinq des
six paires se mesurent contre lui. `dark_neutral` reste déplaçable, lui, et
délibérément : sur les deux paires neutre-sur-neutre il n'y a aucune couleur de
marque dans la paire, et « texte courant sur fond de page » est la paire la plus
importante du site.

⚠ **La marche est bornée à une clarté de 0,05 à 0,95.** À 0 et 1,
`site_spec_hsl_to_hex` rend du noir et du blanc quelle que soit la teinte : la
marche non bornée rendait `#040301` pour une teinte 30 contre un fond `#767676`,
ce qui passe 4,5:1 et n'est pas sa couleur. `null` est donc une réponse
atteignable à 4,5:1, et c'est l'honnête. Les corrections déjà justes sont
inchangées, vérifié contre la marche non bornée.

> ⚠ **Aucune contrainte de contraste n'existe, et un garde-fou refuse la
> migration si on en ajoute une.** Une thérapeute qui a déjà payé une génération
> et à qui l'on refuse un enregistrement parce que deux de ses couleurs sont à
> 4,3:1 a reçu un produit cassé ; celle à qui l'on dit « cette paire est
> difficile à lire, voici le bouton » a reçu un conseil.

### `extra_instructions`

Ajouté **verbatim** à la fin du livrable, sous son propre titre
(`## Additional instructions from the practice owner`, ou une dernière étape
« Your own notes » dans la fiche). Jamais analysé, jamais inspecté, et il
n'atteint pas la maquette — l'y lire voudrait dire l'interpréter, et
l'interpréter est précisément l'aller-retour par le texte libre que la règle 2
interdit.

### Ce qui n'est pas construit, et pourquoi

- **Aucune table de révisions.** Annuler / refaire est côté client. Ce que la
  table garde n'est pas un historique mais une marque haute par libellé de
  changement (`change_marks`), ce dont la bannière a besoin et rien de plus.
- **`stale` se décide sur la version, pas sur la liste de libellés.** Toute
  écriture réussie incrémente `spec_version` ; si l'une d'elles change un jour
  quelque chose qu'aucun libellé ne décrit, la bannière doit quand même se
  lever.
- **Aucune validation auprès d'un ordre professionnel.** `practice_details`
  porte un numéro de licence dont Eklio n'a aucun moyen de vérifier la réalité,
  et un produit qui laisserait croire qu'il l'a vérifié ferait une affirmation
  sur les diplômes d'une thérapeute à sa place.

### ⚠ Le trou NULL dans les validateurs jsonb

La règle générale est en tête de ce README, section **Discipline NULL** — elle
vaut pour tout le dépôt et pas seulement pour ce lot. Ce qui suit est ce que
l'audit a trouvé ici.

Cinq fonctions et une contrainte inline étaient touchées ;
`20260829112000_null_safe_jsonb_validators.sql` les corrige, et son test est
paramétré sur `pg_proc` pour qu'un validateur ajouté plus tard sans cette
couverture fasse échouer la suite.

Deux points de portée :

- **Rien de pire n'a été trouvé.** La contrainte critique pour la sécurité —
  `monthly_presence_content_locked_is_empty_check`, le paywall — est écrite sur
  `IS NULL` et est saine. `site_spec_cta_target_url_valid` aussi.
- **`create or replace function` ne revérifie pas les lignes existantes.** La
  migration audite donc `brand_kits` avant de resserrer, groupe les directions
  fautives par raison, et **s'arrête** si le compte n'est pas zéro.

⚠ Conséquence pour le front : une palette de forme
`{primary, secondary, accent, light_neutral, dark_neutral}` est désormais
**refusée à l'écriture** par `brand_kits`. Le générateur doit émettre
`{primary, secondary, light, dark, paper}`, plus `accent` s'il en a un.

### Deux points de sécurité qui ne sont pas de la cosmétique

**`cta_target_url` est restreint à `https://`, `http://`, `mailto:` et `tel:`.**
Ce lien est imprimé verbatim dans un document dont toute la raison d'être est
d'être collé dans un constructeur de site, dont certains en feront un `href`
vivant. Un `javascript:` ou un `data:` qui atteindrait cette sortie serait une
charge utile avec son vecteur de livraison attaché.

**`site_spec_patch` est la seule fonction `SECURITY DEFINER` du lot à être
exposée aux clients, et elle refait explicitement le cloisonnement que la RLS
faisait pour elle.** Elle écrit `spec_version` et `change_marks`, deux colonnes
délibérément retirées aux clients par privilège de colonne — une version choisie
par le client laisserait un éditeur périmé gagner en silence. Sans son
`user_id = auth.uid()` en première ligne, ce serait un oracle de lecture-écriture
indexé par uuid. `site_spec_seed_values`, qui lit un brief par id de kit sans
contrôle de propriété, est pour la même raison **retirée à `authenticated`** et
un garde-fou le vérifie.

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

Pour le Lot 6, dans l'ordre d'importance que la commande fixe :

- **des tests de snapshot sur `site_spec_output`, un spec × les sept cibles.**
  Le livrable est une fonction pure de `(spec, target)` et tout le produit
  repose là-dessus : la maquette qu'elle valide et le texte qu'elle colle
  doivent décrire le même site, le cache dans `brand_kits.site_prompt` doit
  rester vrai, et un marqueur « copié » doit vouloir dire quelque chose. Si une
  empreinte bouge, le livrable a bougé, et quelqu'un doit le regarder exprès
  plutôt que de l'apprendre d'une utilisatrice. Régénérer avec
  [`supabase/tests/helpers/site_output_digests.sql`](supabase/tests/helpers/site_output_digests.sql) —
  **après avoir lu la différence** ; l'empreinte n'est pas l'objet du test, le
  moment où l'on regarde l'est.
- des tests unitaires sur `site_spec_contrast` contre des ratios calculés à la
  main et recoupés avec une implémentation indépendante, dont la borne
  canonique AA (`#767676` passe à 4.54, `#777777` échoue à 4.48), une paire
  d'une palette réellement livrée qui échoue (2.71:1), et **la vérification que
  le correctif proposé atteint bien 4,5**, sans quoi un correctif en un clic
  laisserait la bannière levée ;
- chaque limite de longueur à sa borne exacte, y compris **à l'intérieur d'une
  liste**, là où une limite par champ serait passée à côté ;
- `spec_version` qui n'avance pas sur un patch sans effet, la bannière qui se
  lève puis retombe après `mark-copied`, et `mark-copied` qui n'avance pas la
  version ;
- l'idempotence de l'amorçage quand on re-choisit une direction, **et qu'une
  direction extrême mais légale ne peut pas rendre ce choix impossible** ;
- et, sur chacune des sept fonctions exposées, qu'une seconde utilisatrice
  reçoit `not_found` — la même réponse, au caractère près, que pour un kit
  inexistant.
