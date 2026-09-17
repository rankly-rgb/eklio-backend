# OUT_OF_SCOPE.md — ce que j'ai croisé et laissé

Écrit pendant le lot 1 d'implémentation de l'offre du 13 septembre.
**Complété au lot 2** — les entrées 23 à 26 sont nouvelles, et deux entrées anciennes ont reçu une
suite. **Complété au correctif du lot 2** — entrées 27 à 30. **Complété au lot 3** — entrées 31 à 35, et le recensement mesuré. **Rien n'a été réécrit.**

**Ce fichier est un livrable, pas une excuse pour intervenir.** Chaque ligne est quelque chose que
j'ai vu, vérifié assez pour l'écrire, et laissé en place — avec le lot à qui il appartient.

---

## Croisé et laissé, avec son lot propriétaire

| # | Ce que c'est | Où | Lot |
|---|---|---|---|
| 1 | `owns_project()` compare `p.user_id = auth.uid()` et n'appelle jamais `is_org_member` | backend, fonction `public.owns_project(uuid)` | **L19** |
| 2 | 33 policies nomment `auth.uid()`, 2 seulement appellent `is_org_member` — et ces deux gardent les tables du layer lui-même | backend, `pg_policies` | **L19** |
| 3 | Aucune RPC de retrait d'une clinicienne. Le statut `removed` est dans le CHECK de `organization_members.status` et rien ne sait le poser | backend | **L19** |
| 4 | Le chemin d'invitation n'a jamais été parcouru par une donnée réelle : 3 membres en base, tous `owner`, 0 `invited` | base vivante | **L19** |
| 5 | Le droit d'abonnement n'a aucune autorité SQL. La règle (statuts + grâce de 3 jours sur `past_due`) vit uniquement dans `isEntitledToMonthlyPresence` | frontend, `lib/billing/entitlements.ts:58` | **L20** |
| 6 | `subscriptions` est unique sur `user_id`, sans `organization_id` ni `quantity` | backend, `subscriptions_user_id_key` | **L20** |
| 7 | Le webhook ne lit qu'un `stripe_price_id` et jamais `items.data[0].quantity` | frontend, `lib/stripe/webhook.ts` | **L20** |
| 8 | `content_publications` est un journal déclaratif : `INSERT`/`UPDATE`/`DELETE` refusés par policy, écrit seulement par `mark_content_posted` | backend | **L14–L17** |
| 9 | Aucun client CMS, aucun coffre à secrets, aucune file de travaux durable | les deux dépôts | **L14–L17** |
| 10 | L'abonnement Monthly Presence est encore au catalogue et au checkout | frontend, `lib/billing/plans.ts` (`MONTHLY_PRESENCE`) | **L23** |
| 11 | 8 tables de contenu Instagram, ~17 RPC et ~25 modules frontend deviennent sans emploi | les deux dépôts | **L23 — et rien n'est supprimé en base** |
| 12 | `/api/cron/content-month` existe, n'est pas dans `vercel.json`, et est derrière `CONTENT_GENERATION_ARMED` | frontend | **L18** |
| 13 | Aucun stockage des chiffres Psychology Today saisis par la cliente | — | **L22** |
| 14 | Aucun second mode d'entrée par profil collé ; `lib/check/review.ts` porte « HER TEXT IS NEVER STORED » | frontend | **L6 — bloqué par une décision de la propriétaire** |
| 15 | Aucune source de données pour le comparatif de zone | — | **L7** |
| 16 | Aucune one-page prescripteurs | — | **L12** |

---

## Trouvé pendant le lot, et laissé — avec ce qu'il faut savoir

Ces entrées-ci ne figuraient pas dans `GAP_AUDIT.md`. Elles sont apparues en construisant.

### 17. ⚠ Deux implémentations de l'Ethics Guard coexistent maintenant

**Où** : `eklio-frontend/lib/ethics/rules.ts` (19 expressions régulières compilées) et
`public.ethics_patterns` (les mêmes, traduites en POSIX).
**Lot propriétaire** : aucun — **c'est une dette créée par L13 et il faut le dire.**

L13 exigeait un scan *à l'intérieur de l'écriture*. Une fonction SQL ne peut pas lire du
TypeScript, donc les motifs sont désormais écrits deux fois. C'est exactement la famille de
divergence que ce dépôt documente — et que L1 de cette même session a corrigée ailleurs.

**Ce qui les tient ensemble en attendant** : un corpus partagé, vérifié des deux côtés sur les
mêmes phrases —
`eklio-backend/supabase/tests/20260914170000_the_guard_in_the_write.test.sql` et
`eklio-frontend/lib/ethics/__tests__/shared-corpus.test.ts`.

**Ce qui reste à faire** : que le scanner TypeScript LISE `ethics_patterns`, comme
`usp-guardrails.ts` lit déjà `usp_stopwords` et `usp_similarity_threshold`. L'obstacle est que
`checkEthics` est synchrone et importé par une page (`lib/check/review.ts` doit rester sans I/O
et sans chemin vers le SDK). Ce n'est pas insurmontable, c'est un lot.

### 18. ⚠ Deux vocabulaires de « page » coexistent, et ils ne se recouvrent pas

**Où** : `site_pages` (`home`, `about`, `services`, `contact`) et
`eklio-frontend/lib/kit/tiers.ts` `PAGES_WANTED` (`home`, `about`, `approach`, `specialties`,
`fees`, `faq`, `contact`, `blog`).
**Lot propriétaire** : non attribué. Le plus proche est **L10**, dont le périmètre nommait
`site_spec_page_keys()`, `section_types.allowed_pages` et les validateurs jsonb — pas `PAGES_WANTED`.

`PAGES_WANTED` est ce que le brief COCHE et ce que `resolveKitScope` plafonne par palier.
`site_pages` est ce qu'une spec de site peut PORTER. Les deux s'appellent « pages » et n'ont que
`home`, `about` et `contact` en commun. Rien ne casse aujourd'hui parce que rien ne les compare.

### 19. La garde anti-liste-en-dur de L10 cherche des littéraux, et un littéral ne porte pas ce qu'il désigne

**Où** : `20260914150000_pages_are_data.sql` et son test.

`site_spec_section_types()` a dû y être inscrite : deux de ses onze types de section s'appellent
`contact` et `services`, comme deux clés de page, parce qu'une page Contact contient une section
Contact. Elle ne nomme aucune page. La limite est écrite dans le registre plutôt que masquée ;
l'affiner (analyser le contexte d'appel) la rendrait fragile pour un gain nul.

### 20. `asset_catalog.min_tier` ne connaît pas les nouveaux paliers

**Où** : `asset_catalog_min_tier_check` accepte `starter`, `practice`, `signature`.
**Lot propriétaire** : **L4 / L23** (la distribution des surfaces sur la nouvelle offre).

L3 a étendu les trois CHECK que le cahier nommait. Celui-ci est un quatrième porteur de palier,
non nommé, et il gate des fichiers par palier. Une acheteuse Foundation voit tout, puisque
`foundation` est en fin de `KIT_TIERS` — donc rien ne casse, et rien n'est réservé non plus.

### 21. `countUnpaidProjects` compte un projet adossé à un add-on comme payé

**Où** : `eklio-frontend/lib/billing/entitlements.ts`.
**Lot propriétaire** : non attribué.

Depuis L4, `purchases` porte trois formes. Ce plafond anti-abus compte les projets NON ADOSSÉS À
UN ACHAT, quelle qu'en soit la forme — donc un projet dont le seul achat est l'add-on à 89 $
compte comme payé. C'est la sémantique existante (« non adossés à un achat »), et la resserrer
est une décision de produit, pas une correction. Le plafond est *fail-open* et anti-abus, pas une
garde de sécurité.

### 22. `PLANNABLE_ARCHETYPES` est passé de tous les archétypes aux archétypes d'image

**Où** : `eklio-frontend/lib/content/generate/plan.ts`.
**Fait dans L11, signalé ici** parce que ça change le planificateur mensuel, qui appartient à L18.

`google_post` ne porte pas d'image ; le laisser dans la liste du planificateur l'aurait fait
écrire une ligne au plancher d'une image inexistante. Le planificateur ne plannifie donc que les
cinq archétypes Instagram — ce qu'il faisait déjà en pratique. L18, qui réécrit ce cycle, devra
décider si un post Google entre dans un mois.

---

## La dérive entre les fichiers de migration et la base

**Hors chantier : je documente, je ne réconcilie pas.**

Rien de nouveau n'a été trouvé. Ce que ce lot a fait, dans l'autre sens : **les sept migrations
écrites ici ont été appliquées au projet vivant puis revérifiées contre lui**, pas contre le
fichier — donc elles ne créent pas de dérive.

Une chose mérite d'être notée : `20260909094038_check_rewrite_daily_limit.sql` portait la balise
« mirrored verbatim in supabase/seed.sql » et **le bloc n'y était pas**. Ce n'est pas de la dérive
base/dépôt, c'est de la dérive migration/seed — et `check_seed_mirrors.sh` a été écrit pour
l'attraper. Il l'a attrapée. Corrigé dans L2, parce que la suite ne pouvait pas être verte sans.

---

## Croisé pendant le LOT 2, et laissé

### 23. ⚠ L'étape 7 du brief propose un prompt Squarespace que la qualification refuse

**Où** : `eklio-frontend/components/brief/step-bodies.tsx`, constante `BUILDER_TARGETS`
(`squarespace`, `lovable`, `framer`, `webflow`), en dur.
**Lot propriétaire** : **L23**.

C'est une surface de l'offre PRÉCÉDENTE : elle choisit pour quel constructeur écrire un **prompt à
coller**, livrable que The Foundation ne vend pas. Elle n'a rien à voir avec `site_platforms`, qui
décide où Eklio PUBLIE.

⚠ Depuis le verdict Squarespace de ce lot, les deux se contredisent en façade : la qualification
dit « nous ne publions pas sur Squarespace », l'étape 7 propose toujours un prompt Squarespace.
Les deux phrases sont vraies séparément ; personne ne lit un produit en les séparant. Consigné
aussi dans `DECISIONS_NEEDED.md` §12.

### 24. `createMonthlyPresenceCheckout` ne passe par aucune garde de vendabilité

**Où** : `eklio-frontend/lib/stripe/checkout.ts`.
**Lot propriétaire** : **L23**.

`plans.sellable` est lu par `createCheckoutSession`. L'autre checkout — celui de l'abonnement
Monthly Presence seul — ne l'interroge pas, et **ne le peut pas** : `monthly_presence` n'a pas de
ligne dans `plans` (`ENV_REQUIRED.md` le disait déjà). Ce n'est pas un trou : cet abonnement est
livré, il fonctionne, et il n'y a rien à refuser. Mais il échappe structurellement au mécanisme,
et le jour où L23 le retire de la vente, ce n'est pas `sellable` qui l'arrêtera.

**Je n'ai pas créé la ligne `plans` manquante** : ce serait ranger l'offre précédente dans un
catalogue que le lot 1 a construit pour la nouvelle, et personne n'a décidé ça.

### 25. Un commentaire orphelin au-dessus de `AlreadyPurchasedError`

**Où** : `eklio-frontend/lib/stripe/checkout.ts`, le bloc « Crée la session et rend l'URL hébergée
par Stripe » qui ne surplombe plus `createCheckoutSession`.
**Lot propriétaire** : aucun.

Préexistant au lot 2 — il était déjà détaché avant que quoi que ce soit ne bouge. Laissé tel quel :
le déplacer est un refactor d'opportunité, et ils sont interdits. Noté pour qu'on sache que c'est
vu et non subi.

### 26. `types/supabase.ts` avait dérivé — et la dérive est fermée

**Où** : les deux dépôts.
**Statut** : **corrigé**, pas laissé. Inscrit ici parce que c'est un constat sur la méthode.

La copie régénérée au lot 1 précédait **ses propres migrations L9, L10 et L13** :
`directory_profiles`, `site_pages`, `ethics_patterns` et leurs fonctions (`ethics_scan`,
`ethics_blocks`, `save_directory_profile`, `get_directory_profile`, `directory_structured_valid`)
n'y figuraient pas. Régénéré depuis le projet vivant au lot 2 : **124 lignes ajoutées, zéro
retirée.** Rien ne cassait, parce que rien n'appelait encore ces surfaces depuis le TypeScript —
c'est exactement pourquoi ça pouvait passer inaperçu.

⚠ **La leçon, pour les lots suivants** : régénérer les types AU BOUT du lot, pas au milieu.

---

## Deux entrées du lot 1 qui ont reçu une suite

### §17 — les deux Ethics Guard : **toujours deux, et maintenant comptées**

La fusion n'a pas eu lieu et n'était pas au programme. Ce qui a changé : chaque motif porte
désormais un **nom identique des deux côtés** (`ethics_patterns.id` ↔ `FORBIDDEN_PATTERNS[].id`),
et deux tests jumeaux exigent le même recensement — même nombre, mêmes identifiants, même règle
derrière chaque identifiant.

Ce que ça ferme : un motif ajouté d'un seul côté. Ce que ça **ne ferme pas** : deux motifs de même
nom qui n'attrapent pas le même texte. Les dialectes restent deux, et la fusion reste le lot
décrit ici au lot 1.

### §18 — les deux vocabulaires de « page » : **l'écart est maintenant chiffré**

`KIT_TIER_RULES.roster.maxPages` est passé de 4 à 6 (décision §2). La raison donnée — « un cabinet
porte une page équipe » — bute sur ce même écart : `PAGES_WANTED` n'a pas de clé `team`, et
`site_pages` en base porte un troisième découpage encore. Voir `DECISIONS_NEEDED.md` §11.

---

## Trouvé en PARCOURANT le produit, et corrigé (lot 2-fix)

### 27. ⚠⚠ Le défaut que ce correctif existe pour réparer, et sa vraie gravité

**Où** : `lib/brief/platform.ts`, `lib/brief/flow.ts:200`, `components/brief/step-bodies.tsx`.
**Statut** : **corrigé**, pas laissé. Consigné parce que la MÉTHODE qui l'a laissé passer est ce
qui compte.

`lib/brief/platform.ts` a été écrit au lot 1, couvert par deux fichiers de test, et importé par
**aucun** fichier de `app/` ni de `components/`.

⚠ **Et ce n'était pas du code mort inoffensif.** `stepIssue("practice")` EXIGEAIT
`site_platform_id` depuis le même lot — *« Tell us where your website lives »* — pendant qu'aucun
écran n'offrait le champ pour répondre. **Un brief neuf se bloquait à l'étape 1, sur une question
que personne ne posait.** Le projet de test existant ne le montrait pas : il porte
`completed_steps = [1..7]` et `site_platform_id = null`, ayant été rempli avant que l'exigence
n'existe.

**Pourquoi toute la suite était verte** : chaque module était juste. Ce qui manquait était
*entre* eux, et rien ne regardait là. Deux tests l'attrapent désormais, et les deux ont été
sondés en remettant le produit dans son état défectueux (entrée 28).

### 28. La qualification refusait, alors que l'ancienne offre est toujours vendue

**Où** : `20260914120000_platform_qualification.sql`, en tête de fichier.
**Statut** : **corrigé** — erreur de spec, pas de code.

Le fichier disait : « Les autres sont refusées à l'inscription ». Mais `starter`, `practice` et
`signature` sont toujours au catalogue, toujours sur `/pricing`, et **ne promettent aucune
publication** : elles livrent des fichiers et un texte à coller. Refuser à l'inscription une
praticienne sur Wix revenait à lui refuser une vente qu'on sait honorer, pour un service qu'elle
ne demandait pas.

`plans.requires_publishable_platform` remplace le refus par une éligibilité, **à la même porte que
`plans.sellable`** plutôt que par un second mécanisme — un second point de passage serait un
second endroit où oublier de brancher une règle, ce qui est exactement l'entrée 27.

### 29. `BUILDER_TARGETS` a quitté l'écran ; la donnée est intacte

**Où** : `components/brief/step-bodies.tsx` (l'entrée 23 du lot 2 signalait la contradiction).
**Statut** : la QUESTION est retirée, **rien n'est supprimé en base**.

`data.builder_target` reste dans le jsonb des briefs qui le portent, `builder_target_id` reste une
colonne de `project_briefs`, et `lib/kit/site-prompt.ts` continue de les lire pour les kits déjà
vendus. La constante de rendu part avec le contrôle qu'elle alimentait — c'était du code mort créé
par ce correctif même, pas un refactor d'opportunité.

⚠ **L'entrée 23 n'est donc PLUS la contradiction qu'elle décrivait**, mais son lot propriétaire ne
change pas : retirer l'offre précédente de la vente reste **L23**.

### 30. `plans.requires_publishable_platform` n'a aucun écran qui le LIT pour afficher un prix

**Où** : `lib/billing/plans.ts` — `ORDERED_PLANS = LEGACY_KIT_TIERS.map(...)`.
**Lot propriétaire** : **L23**.

Le cahier de ce correctif demandait que « les paliers de la nouvelle offre soient présentés comme
indisponibles avec la raison ». ⚠ **Ils ne sont présentés nulle part** : `/pricing` et
`/app/checkout` n'itèrent que les trois paliers de l'offre précédente. `foundation` et `roster`
existent dans `KIT_PLANS` et ne sont offerts par aucun écran.

Ce qui EST fait : la règle d'éligibilité tient à la porte du paiement (donc un
`?plan=foundation` forgé à la main est gouverné dès aujourd'hui), et la conséquence de sa réponse
lui est dite **à l'étape 1**, le seul écran qui existe pour la porter. Mettre la nouvelle offre en
vitrine est un autre travail, et c'est L23.

---

## Le recensement du lot 1, mesuré (lot 3)

**Méthode** : graphe d'imports complet sur la plage `56c8e40..49cd654`, racines = `app/` seul.
Les chaînes comptent (`launch-copy` ← `material` ← `components/launch/`), et `components/` n'est
PAS une racine : un composant qu'aucune page ne rend est aussi mort que ce qu'il importe. Ce point
a été trouvé en sondant le garde-fou, pas en le relisant.

**28 fichiers touchés par les lots 1 et 2** : 6 sont des écrans, **16 atteints**, **2 atteints par
`app/dev/` seulement**, **4 non atteints**. Au niveau des EXPORTS, le compte est plus dur : cinq
fonctions livrées n'avaient aucun appelant hors de leur propre module.

### 31. ⚠⚠ `lib/directory/profile.ts` — corrigé dans ce lot

Le livrable CENTRAL de The Foundation, importé par son seul test. Troisième occurrence du défaut.
Corrigé : section `directory` du kit, surface `kit_directory` réservée à `foundation`, premier
paragraphe adressable seul (`#directory-first-paragraph`).

⚠ **Ce que ça n'ouvre pas** : rien n'appelle `save_directory_profile` — la prose n'est produite par
personne. L'écran le DIT plutôt que d'afficher un vide qu'on prendrait pour une panne, et rend les
champs structurés, qui eux sont dérivables du brief sans modèle. Produire la prose appartient à la
génération, et reste dû.

### 32. `lib/billing/offer.ts` — dette nommée, pas corrigée

Le miroir applicatif des six SKU, qu'aucun écran ne lit : **la nouvelle offre n'est en vitrine
nulle part** (§30). Le brancher, c'est la mettre en vente — **L23**. Inscrit dans `KNOWN_DEBT`,
avec son lot, une liste épinglée à l'unité et un contrôle que le module existe encore : une dette
effacée n'est pas une dette payée.

### 33. `lib/content/generate/plan.ts` et `pipeline.ts` — non atteints, et c'est attendu

Le cycle mensuel de contenu. `/api/cron/content-month` existe, n'importe ni l'un ni l'autre, et
est derrière `CONTENT_GENERATION_ARMED` (§12). Non couverts par le garde-fou : `lib/content/` ne
décrit pas un livrable vendu aujourd'hui — The Fill n'est pas vendable (`plans.sellable = false`).
Propriétaire : **L18**.

### 34. Cinq exports livrés sans aucun appelant

Mesuré hors tests et hors leur propre module :

| Export | Lot | Appelants |
|---|---|---|
| `offerSku`, `offerPrice`, `PURCHASABLE_SKUS` | L3 | 0 — cf. §32 |
| `buildDirectoryProfile` | L9 | 0 — l'écran appelle `buildStructuredFields` et `checkProse` directement |
| `carriesImage` | L11 | 0 |
| `hasPurchasedAddon` | L4 | 0 hors `entitlements.ts` — l'add-on à 89 $ n'est proposé nulle part |

Aucun n'est faux. Tous décrivent une chose que le produit ne fait pas encore.

### 35. `lib/brief/fixtures/catalog.ts` et `lib/content/generate/capacity.ts` — `app/dev/` seulement

Atteints par des pages de démonstration, pas par le produit. Normal pour une fixture ; noté pour
`capacity.ts`, qui est de la logique et dont le seul chemin réel passe par L18.

---

## Trois interdits généraux : tenus

- **Aucune suppression en base.** Aucune table, aucune colonne, aucune ligne, aucune policy
  retirée. Les seuls `drop` sont des `drop constraint` / `drop policy` / `drop trigger`
  immédiatement suivis de leur `create` — remplacement, jamais retrait. Les quatre paliers de
  l'offre précédente et leurs prix sont intacts.
- **Aucun refactor d'opportunité.** Les fichiers laids mais corrects et hors lot n'ont pas été
  touchés.
- **Aucune dépendance nouvelle.** `package.json` est inchangé.

**Au lot 2, les trois tiennent encore.** Les deux migrations ajoutées ne retirent rien : un
`update` sur `site_platforms` (la ligne Squarespace reste au catalogue, refusée et expliquée) et
un `add column` sur `plans` (aucune ligne, aucun prix, aucun palier retiré). Aucun refactor
d'opportunité — l'`id` posé sur chaque motif déontologique est ce que le sous-lot B3 exigeait, pas
un rangement. `package.json` est toujours inchangé.
