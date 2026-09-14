# OUT_OF_SCOPE.md — ce que j'ai croisé et laissé

Écrit pendant le lot 1 d'implémentation de l'offre du 13 septembre.

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

## Trois interdits généraux : tenus

- **Aucune suppression en base.** Aucune table, aucune colonne, aucune ligne, aucune policy
  retirée. Les seuls `drop` sont des `drop constraint` / `drop policy` / `drop trigger`
  immédiatement suivis de leur `create` — remplacement, jamais retrait. Les quatre paliers de
  l'offre précédente et leurs prix sont intacts.
- **Aucun refactor d'opportunité.** Les fichiers laids mais corrects et hors lot n'ont pas été
  touchés.
- **Aucune dépendance nouvelle.** `package.json` est inchangé.
