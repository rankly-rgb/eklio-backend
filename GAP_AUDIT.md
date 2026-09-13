# GAP_AUDIT.md — l'écart entre ce qui existe et l'offre du 13 septembre 2026

**Audit de lecture seule. Aucune ligne de code applicatif, aucune migration, aucun test n'a été
écrit pendant cette session. Ce fichier et `GAP_PLAN.md` sont les deux seuls fichiers produits.**

---

## 0. Accès à la base, et ce que les étiquettes veulent dire

**La base a été atteinte.** Projet Supabase `fobgdsupyfslxbswfuay` (« eklio-backend-us »,
`us-east-1`, PostgreSQL 17.6.1.155, `ACTIVE_HEALTHY`). Tout ce qui est étiqueté `VERIFIED`
ci-dessous a été lu en interrogeant ce projet, pas les fichiers de migration. **Aucun volet
n'est marqué « non vérifié ».**

| étiquette | ce qu'elle garantit |
|---|---|
| `VERIFIED` | exécuté contre la base vivante ; `pg_proc`, `pg_policies`, `pg_constraint`, `information_schema`, ou une lecture de lignes |
| `READ` | lu dans le code d'un des deux dépôts, sans exécution |
| `INFERRED` | déduit ; la déduction est écrite à côté |

Chaque constat porte son dépôt : **(backend)** = `rankly-rgb/eklio-backend`,
**(frontend)** = `rankly-rgb/eklio-frontend`, **(db)** = la base elle-même, qui fait autorité.

**État général de la base** `VERIFIED` : 61 tables dans `public`, **RLS activée sur les 61**, et
**zéro table avec RLS activée et aucune policy**. C'est un point d'hygiène qui a été gagné et qui
n'est pas à refaire.

---

## A. Le moteur de génération

### A.1 Ce qui existe — les constructeurs de prompts

| module | dépôt | entrée | sortie |
|---|---|---|---|
| `lib/generation/pipeline.ts` (649 l.) | frontend `READ` | brief + catalogue | 3 directions, voice guide, 4 accroches sociales |
| `lib/generation/model.ts` (288 l.) | frontend `READ` | contexte assemblé | **un seul** appel outil `write_brand`, `max_tokens: 8000` |
| `lib/generation/select.ts` | frontend `READ` | `palette_family_ids`, `type_pairing_id` | palettes + typographies **déterministes**, hors modèle |
| `lib/generation/usp-options.ts` / `rephrase.ts` / `tone-cards.ts` | frontend `READ` | brief partiel | options de positionnement, reformulations, cartes de ton |
| `lib/check/rewrite.ts` | frontend `READ` | texte collé + constats | réécriture ciblée, re-scannée |
| `lib/content/generate/pipeline.ts` | frontend `READ` | mois + thèmes + registres | un mois de posts |
| `lib/images/prompt.ts` | frontend `READ` | direction + spécialités | prompt d'imagerie |

**Ce que le modèle N'écrit PAS** `READ` : palettes, typographies, overline, libellé de bouton. Ils
viennent du catalogue et du brief, parce que la base impose des hex valides, trois polices de titre
distinctes et une URL Google Fonts réelle, et qu'un modèle invente volontiers les trois.

**Ordre des gardes dans la pipeline** `READ` : (1) schéma zod, (2) contraintes de rendu de la base
avec une reprise par champ, (3) déontologie **en dernier**, parce qu'une reprise de longueur
réécrit du texte.

### A.2 Où sont les gabarits

**Pas dans le code.** `VERIFIED` : la table `site_output_templates` porte **~70 lignes** de
fragments (`prompt.role_line`, `sheet.step1_title`, `token.primary`, `constraint.no_invention`,
`voice.heading`…), assemblées en base par `site_output_fill`, `site_spec_output`,
`site_spec_output_prompt`, `site_spec_output_setup_sheet`. Les sections du site sont elles aussi des
données : `section_types`, **11 lignes** avec leurs champs, longueurs maximales et pages autorisées
`VERIFIED`.

C'est le meilleur actif du dépôt pour cette offre : **ajouter un type de sortie textuelle est en
grande partie une insertion de lignes, pas un déploiement.**

### A.3 Le brief en 7 étapes, champ par champ

`READ` (`frontend/lib/brief/flow.ts`) + `VERIFIED` (`project_briefs`, **33 colonnes**).

| # | étape | ce qu'elle écrit |
|---|---|---|
| 1 | `practice` | `practice_name`, `license_type_id`, `specialty_ids[]`, `city`, `state` |
| 2 | `positioning` | `problem_card_ids[]`, `gain_card_ids[]`, `data.problem_text`, `data.gain_text`, `positioning` |
| 3 | `client` | `client_persona_ids[]` (≤ 3) |
| 4 | `how_you_work` | `session_style_ids[]`, `not_a_fit_ids[]`, `not_a_fit_text`, `modality_ids[]`, `modality_prominence`, `referral_quote`, `prior_career`, `prior_career_public` |
| 5 | `voice` | `tone_card_id`, + `tone_cards` jsonb générées, `tone_cards_inputs_hash` |
| 6 | `look` | `palette_family_ids[]`, `type_pairing_id` |
| 7 | `website` (optionnelle) | `primary_action_id`, `site_goal_ids[]`, `builder_target_id` |
| — | écran positionnement | `usp_options` jsonb, `selected_usp_id`, `usp_statement` |

### A.4 ⚠ La question qui décide de la quantité de travail sur le brief

**« Collecte-t-il le problème du patient dans les mots du patient, ou la modalité et la
démographie ? »**

**Il collecte les trois, et le problème du patient passe en premier.** `READ` — l'étape 2 pose
littéralement : *« What are your clients carrying when they call? »*, avec pour aide *« Pick what
fits, or write it your way. This becomes the line under your headline. »* Les cartes viennent des
tables `problem_cards` et `gain_cards`, et un texte libre est accepté à partir de 40 caractères
(`POSITIONING_MIN_CHARS`). La démographie est à l'étape 3 (`client_persona_cards`), la modalité à
l'étape 4 — et l'étape 4 porte `modality_prominence`, c'est-à-dire une décision explicite sur la
place que la modalité doit prendre.

**Conséquence, et elle est bonne :** le brief n'a pas à être refait. Ce qu'il ne collecte pas :

1. **Les mots que la patiente taperait dans un moteur** — une carte de catalogue est une
   catégorie, pas une requête. `INFERRED` (déduit de ce que les tables `problem_cards`/`gain_cards`
   contiennent : des libellés courts choisis dans une liste).
2. **Le texte du profil Psychology Today existant.** Aucune colonne nulle part `VERIFIED`.
3. **Les chiffres Psychology Today.** Aucune colonne, aucune table `VERIFIED`.
4. **La plateforme du site, et son URL.** `builder_targets` existe (7 lignes `VERIFIED` : lovable,
   framer, v0, generic, squarespace, wix, webflow) mais c'est une **cible de sortie**, pas un site
   possédé : il n'y a ni URL, ni compte, ni vérification.

### A.5 Verdict A

| | |
|---|---|
| **Réutilisable tel quel** | les 7 étapes et leurs 33 colonnes ; `site_output_templates` ; `section_types` ; la séparation « le modèle écrit la copy, le catalogue écrit le reste » ; l'ordre des trois gardes |
| **Réutilisable moyennant adaptation** | `usp_options` → la phrase de positionnement de The Foundation est **déjà** ce que cet écran produit ; il faut cadrer le prompt sur « les mots de ses patients » plutôt que sur une USP de marque |
| **Entièrement à construire** | la collecte de la requête-patient ; la collecte du profil PT existant ; la collecte de la plateforme |
| **Mort** | rien dans ce domaine |

---

## B. Le chemin d'entrée

### B.1 Ce qui existe

**Le jeton et la session anonymes** `VERIFIED` + `READ` :

- cookie `eklio_brief`, 32 octets CSPRNG en base64url, **30 jours** (`ANON_TOKEN_DAYS`,
  frontend `lib/anon/token.ts` `READ`) ;
- la base ne stocke que le SHA-256 : `projects.anon_token_hash`, `projects.anon_expires_at`
  `VERIFIED` ;
- `public.anon_token_hash()` lit l'en-tête `x-anon-token` `VERIFIED` ;
- `public.owns_project(uuid)` `SECURITY DEFINER` porte les deux branches — utilisateur **ou** jeton
  non expiré — et c'est elle que lisent les policies de `project_briefs` et `brand_kits`
  `VERIFIED` ;
- `projects_select_own` / `projects_update_own` portent la même disjonction, et le `WITH CHECK` de
  l'UPDATE anonyme exige `user_id is null` — un porteur de jeton ne peut pas s'attribuer le brief
  d'une autre `VERIFIED` ;
- la signature HMAC du cookie est **advisory** : sans `ANON_TOKEN_SECRET` la vérification est
  sautée et le jeton marche quand même (frontend `READ`). C'est documenté et assumé.

**Les plafonds de dépense anonyme** `VERIFIED` : `consume_anon_generation(p_ip_hash, p_kind)`,
`anon_generation_counters`, `anon_spend_today()` — les trois exécutables **par `service_role`
uniquement**. Réglages en base (`app_settings`) : `anon_generation_daily_per_ip` = 3,
`anon_generation_daily_global` = 150, `anon_assist_daily_per_ip` = 45,
`anon_assist_daily_global` = 750, et quatre coûts unitaires en USD. Le point d'appel unique est
`frontend/lib/anon/spend.ts` `READ`, avec deux genres (`reveal`, `assist`).

**L'autosave** : `20260827101000_brief_autosave_and_preview.sql` (backend `READ`),
`brief_preview(p_brief_id)` `VERIFIED`, `project_briefs.progress_step` (canonique) et
`completed_steps[]` `VERIFIED`.

**Le claim** : `frontend/lib/anon/claim.ts` `READ` — écrit avec la `service_role`, parce que les
policies refusent délibérément qu'un navigateur pose `user_id` sur une ligne détenue par un jeton.

**La purge** : cron `/api/cron/anon-briefs`, 30 jours, cascade `projects → project_briefs →
brand_kits` `READ` ; planifiée dans `vercel.json` à `0 5 * * *` `READ`.

### B.2 Ce qu'il faut pour un second mode d'entrée

**Rien de cette liste n'est couplé à la forme du brief.** Le jeton, la session, le claim, les
plafonds, l'autosave et la purge fonctionnent sur `projects` et `project_briefs` et ne savent rien
des sept étapes. `INFERRED`, et la déduction est solide : `owns_project` ne lit que
`projects`, et `consume_anon_generation` ne prend qu'un hash d'IP et un genre.

Ce qui manque :

1. **Un endroit où poser le texte collé.** `VERIFIED` : aucune colonne, dans aucune table, ne
   stocke un profil existant. Et le module `Check` **refuse délibérément** de stocker — l'en-tête
   de `frontend/lib/check/review.ts` le dit : *« HER TEXT IS NEVER STORED »* `READ`. C'est une
   décision, pas un oubli : la reprendre pour The First Line est un choix à faire en connaissance.
2. **Un second `progress_step`.** `STEP_COUNT = 7` est en dur (frontend `READ`), et
   `projects.current_step` porte un CHECK `>= 1 and <= 8` `VERIFIED`. Un parcours « coller un
   profil » ne rentre pas dans cette numérotation sans la salir.
3. **Un troisième genre de dépense.** `p_kind` accepte aujourd'hui `reveal` et `assist` `READ` ; un
   diagnostic de profil est un troisième coût avec son propre plafond.
4. **Un entonnoir qui le décrit.** `funnel_steps` porte **12 lignes en dur** `VERIFIED`, dont
   `brief_step_4` avec `match_prop = 'step'`, `match_value = '4'`. Le nouveau chemin d'entrée est
   invisible tant que ces lignes ne bougent pas — et ce sont des lignes, pas du code.

### B.3 Verdict B

| | |
|---|---|
| **Réutilisable tel quel** | jeton, hash, policies, `owns_project`, claim, purge, autosave, plafonds |
| **Réutilisable moyennant adaptation** | `p_kind` (ajouter un genre) ; `funnel_steps` (lignes) ; l'écran de reprise `app/brief/resume` |
| **Entièrement à construire** | le stockage du profil collé ; le second parcours et sa progression ; le rendu du diagnostic |
| **Mort** | rien — et surtout pas la session anonyme, qui est le seul actif d'acquisition du produit |

---

## C. Les sorties

### C.1 Inventaire de ce qui est produit aujourd'hui, et où c'est stocké

| sortie | stockage | forme | garde |
|---|---|---|---|
| 3 directions de marque | `brand_kits.directions` jsonb | 3 objets : nom, justification, hero, about, 3 mots de ton, personnalité de rendu | 4 CHECK : `shape`, `rendering`, `contrast`, `selection` `VERIFIED` |
| guide de voix | `brand_kits.voice_guide` jsonb | `sounds_like[3]`, `never_write[3]` | `brand_kit_voice_guide_valid` `VERIFIED` |
| 4 accroches sociales | `brand_kits.social_templates` jsonb | statement / question / notes headline + body | 2 CHECK `VERIFIED` |
| phrase praticienne | `brand_kits.practitioner_line` text | une ligne | — |
| verdict déontologique | `brand_kits.ethics_check` jsonb | `{passed, flagged[{field, excerpt, rule_id}], checked_at}` | `brand_kit_ethics_check_valid` `VERIFIED` |
| spécification de site | `site_specs`, **30 colonnes** `VERIFIED` | 6 hex + 3 « as text » + `cta_ink` + typos + `hero` jsonb + `pages` jsonb + `practice_details` jsonb + `change_marks` + `seed_clamped` | ~15 validateurs jsonb |
| prompt / feuille de montage | calculé à la volée par `site_output_get(kit, target, format)` `VERIFIED` | `prompt` (lovable, framer, v0, generic) ou `setup_sheet` (squarespace, wix, webflow) | `builder_targets.accepts_prompt` |
| **35 fichiers de marque** | `brand_assets` + `asset_catalog` (35 clés `VERIFIED`) | png, svg, css, json, ase, html, md, zip | `record_brand_asset`, empreintes |
| photos IA | `brand_images` (+ `brand_image_daily_spend`) | claim / ready / failed, coût en cents | plafond quotidien |
| posts mensuels | `content_items` (+ `content_months`, `content_grounds`) | archétype ∈ {statement, question, notes, signature, story}, registre ∈ 6, `on_image_text`, `caption`, `alt_text` `VERIFIED` | Ethics Guard **dans la pipeline**, pas dans la RPC |
| blocs à copier pour les démarches | calculés, non stockés (`frontend/lib/launch/material.ts` `READ`) | Statement, Bio, Signature, Booking link | assemblés de champs déjà scannés |
| champs structurés Psychology Today | calculés (`frontend/lib/launch/directory.ts` `READ`) | **des libellés de catalogue**, jamais une phrase | aucune — et il n'en faut pas |

### C.2 Les six nouvelles sorties, une par une

**1. Diagnostic de profil (The First Line, gratuit).**
Le plus proche : `frontend/lib/check/review.ts` `READ` — `reviewText(text, rules)` rend des constats
avec l'extrait fautif, la règle et son libellé, sans score, sans « conforme ». Déterministe, gratuit,
six expressions régulières. C'est **la moitié gauche du livrable**.
Ce qui manque : (a) il est **derrière le paywall** — `app/api/check/route.ts` appelle
`isBrandKitEntitled` et rend 402 sinon `READ`, et l'écran redirige vers le checkout ; (b) il exige un
`brand_kit` existant ; (c) **« ce que disent les profils concurrents de sa zone » n'a aucune source
de données dans les deux dépôts** `VERIFIED` (aucune intégration SERP, annuaire, ou scraping).
→ moitié réutilisable, moitié entièrement à construire.

**2. Le premier paragraphe réécrit.**
Le plus proche : `frontend/lib/check/rewrite.ts` `READ` — réécriture ciblée, **deux appels au
maximum**, et le résultat repasse par le même scanner. Plafond en base
(`app_settings.check_rewrites_per_user_per_day` = 50 `VERIFIED`, via
`consume_check_rewrite()`). Adaptation : le prompt actuel dit « change le moins possible » — pour
The First Line, il faut l'inverse (réécrire pour convertir), et une **longueur cible** qui
n'existe nulle part. → adaptation moyenne.

**3. Profil Psychology Today intégral.**
Existe en **deux moitiés disjointes** : les champs structurés (`directory.ts`, des libellés) et un
`personalStatement` (`lib/kit/launch-copy.ts`). Et `FINDINGS.md` (frontend `READ`) le dit
noir sur blanc : *« Two blocks the reference asks for do not exist and are not invented here:
Psychology Today's structured fields […] and a Google-specific short description. Both are copy
generation. »* → la rédaction du profil est **à construire**, mais sur des matériaux déjà rassemblés.

**4. Page de site en requête-patient.**
`site_specs.pages` et `section_types` (11 types, avec `allowed_pages`) existent.
**⚠ Mais `site_spec_page_keys()` rend un enum fermé : `{home, about, services, contact}`**
`VERIFIED`. The Foundation (accroche + 3 pages) rentre tout juste. **The Fill, qui ajoute une page
par mois, ne rentre pas du tout** : à la treizième page, l'enum et tous les validateurs qui le
lisent (`site_spec_pages_valid`, `site_spec_default_pages`, `section_types.allowed_pages`) doivent
devenir ouverts. C'est le changement le plus profond de tout le volet C.

**5. Texte de fiche Google Business.**
Aujourd'hui, la démarche Google reçoit **exactement le même bloc** que Psychology Today
(`stepTextBlocks` : `case "update_directory": case "google_profile":` tombent sur le même
`push("Statement", …)` `READ`). Une description propre à Google est nommée comme absente dans
`FINDINGS.md`. → à construire, petit.

**6. Post de fiche Google.**
Le plus proche est `content_items`, mais il est calibré Instagram : archétypes
`statement/question/notes/signature/story`, `on_image_text` mesuré pour du 1080×1080, un fond
d'image obligatoire (`content_grounds`) `VERIFIED`. Un post Google Business est du texte court avec
un bouton, sans image imposée. → la table peut servir moyennant un archétype de plus et un
`channel` ; la pipeline de composition d'image ne sert pas.

**7. One-page prescripteurs (médecins, psychiatres).**
**Rien.** `VERIFIED` : aucun gabarit, aucun archétype, aucune clé de `asset_catalog`, aucune section.
C'est aussi la seule sortie de la liste dont le **lecteur n'est pas une patiente** — le registre, le
vocabulaire clinique et la déontologie n'y sont pas les mêmes. → entièrement à construire.

### C.3 Verdict C

| | |
|---|---|
| **Réutilisable tel quel** | `site_output_templates` comme mécanisme ; `section_types` ; `brand_assets`/`asset_catalog` ; le scanner déterministe |
| **Réutilisable moyennant adaptation** | `check/review` + `check/rewrite` (paywall à retirer, longueur cible à ajouter) ; `directory.ts` + `launch-copy.ts` comme matière première du profil PT ; `content_items` pour les posts Google |
| **Entièrement à construire** | le comparatif concurrentiel ; la rédaction du profil PT ; **l'ouverture de l'enum de pages** ; la description Google ; la one-page prescripteurs |
| **Mort** | les 4 posts sociaux 1080, la story, les deux couvertures — voir §J |

---

## D. ⚠ La publication — traitée en priorité, et c'est le risque principal

### D.1 Ce qui existe : rien, et c'est mesuré

**Recherche exhaustive sur les deux dépôts** `VERIFIED` (comptage de motifs, hors `node_modules`) :

| motif | frontend | backend |
|---|---|---|
| `wp-json` | **0** | **0** |
| `wordpress` | **0** | 6 (commentaires de migration) |
| `squarespace` | 20 | 107 |
| `oauth` | **0** | **0** |

Les 127 occurrences de « squarespace » sont **une ligne de `builder_targets`** et ses gabarits de
feuille de montage : `output_kind = 'setup_sheet'`, `accepts_prompt = false`,
`color_panel = 'Site Styles › Colors'` `VERIFIED`. C'est une **notice de montage manuel**, pas une
intégration.

**Il n'y a, dans les deux dépôts et dans la base :**

- aucun client HTTP vers un CMS ;
- **aucun stockage de secret par cliente.** `app_settings` est en clair et ne porte que des
  plafonds `VERIFIED` ; il n'existe ni table de connexions, ni colonne chiffrée, ni extension
  `pgsodium`/`vault` utilisée ;
- aucune file de travaux. Le seul « job » du produit est un objet jsonb dans
  `brand_kits.content` (`frontend/lib/generation/job.ts` `READ`) — pas de table, pas de reprise,
  pas de lettre morte ;
- aucune notion de révocation d'accès tiers.

### D.2 Le faux ami : `content_publications`

**C'est un journal déclaratif, pas une publication.** `VERIFIED` :

- 5 colonnes : `content_item_id`, `action`, `channel`, `occurred_at` ;
- policies : `SELECT` pour la propriétaire, **`INSERT`, `UPDATE` et `DELETE` explicitement à
  `false`** ;
- seul écrivain : `mark_content_posted(p_id, p_posted, p_channel)` `SECURITY DEFINER` — c'est-à-dire
  **elle** qui déclare avoir posté ;
- **0 ligne en base aujourd'hui.**

Et `frontend/lib/launch/places.ts` le dit explicitement `READ` : *« Eklio does not hold her
Psychology Today id, her Google listing id or her Instagram handle »*, et les sept étapes portent
`declared: true`, c'est-à-dire *« Eklio ne peut pas observer que l'étape a eu lieu »*.

### D.3 Ce que le composant représente réellement

| pièce | ce que c'est |
|---|---|
| **Connexions par cliente** | table `site_connections` (plateforme, URL de base, identifiant, secret, portée, état, `revoked_at`), **chiffrée au repos** avec une clé qui ne vit pas dans `app_settings`. Il n'y a aucun précédent dans ce dépôt : c'est le premier secret par utilisateur du produit. |
| **WordPress** | REST API `/wp-json/wp/v2/pages`, authentification par mot de passe d'application. Techniquement le plus simple : un POST authentifié, un `id` retourné, une mise à jour idempotente sur cet `id`. |
| **Squarespace** | ⚠ voir §D.5. |
| **File d'attente** | table de travaux durable : `kind`, `subject_id`, `period`, `state`, `attempts`, `next_attempt_at`, `last_error`, unique sur `(kind, subject_id, period)`. |
| **Idempotence** | deux niveaux : (a) **par période**, le motif existe déjà — `content_months_kit_month_key` unique sur `(brand_kit_id, month)` `VERIFIED` ; (b) **par objet distant**, il faut stocker le `remote_post_id` renvoyé et re-viser cet id plutôt que d'en créer un second. |
| **Reprise sur échec** | rejeu borné + état terminal + une ligne visible par la cliente. Aucun précédent : le produit n'a **aucune primitive de remboursement ni de reprise**, plusieurs commentaires du dépôt le rappellent `READ`. |
| **Révocation** | une cliente qui part, un mot de passe d'application supprimé de son côté, un compte suspendu. Trois chemins, trois états, et un message qui ne l'accuse de rien. |

### D.4 ⚠ Peut-on vendre le produit sans ce composant ?

**Non, pas l'offre telle qu'elle est écrite.**

The Foundation dit *« l'accroche de son site + 3 pages, **publiées par Eklio sur son CMS** »*. The
Fill dit *« 1 page de site par mois, en requête-patient, **publiée par Eklio** »*. Ce verbe est la
différence entre l'offre nouvelle et le produit actuel — qui fait déjà, aujourd'hui et bien, tout le
reste : écrire la copy, la contraindre, l'assembler en prompt ou en feuille de montage, et la lui
donner à coller.

**Donc : la publication CMS est le chemin critique de tout le chantier.** Il y a exactement deux
sorties honnêtes, et elles ne sont pas équivalentes :

1. **Construire le composant.** Le prix est en §D.3 et le plan le chiffre. C'est le seul chemin qui
   sert l'offre figée.
2. **Changer le verbe.** « Publiées » devient « prêtes à publier, en un collage » — ce que le produit
   livre déjà. C'est un produit plus faible et un prix différent, mais c'est vendable **lundi**.

Ce qui n'est pas une sortie : vendre « publié par Eklio » et le faire à la main. À une cliente, c'est
du service ; à cinquante, c'est une promesse intenable, et elle tombe pendant le mois où elles sont
cinquante.

### D.5 ⚠ Et un point où l'offre pourrait être irréalisable en l'état

**Squarespace.** `INFERRED` — **et c'est la seule affirmation de cet audit qui repose sur une
connaissance extérieure aux deux dépôts et à la base, donc celle qu'il faut vérifier avant de
planifier autour.**

Squarespace publie des API développeur pour le commerce (produits, inventaire, commandes,
formulaires, profils). **Je n'ai pas connaissance d'une API publique généralement disponible qui
crée et publie une page de contenu** sur un site Squarespace, à la manière de
`POST /wp-json/wp/v2/pages`. Si c'est exact, « publiée par Eklio sur Squarespace » **n'est pas
réalisable par API** et il ne reste que des moyens qu'il ne faut pas prendre : pilotage de
navigateur contre l'interface d'administration avec les identifiants de la cliente — fragile,
probablement contraire aux conditions d'utilisation, et un secret de plus à détenir.

**Ce que ça changerait si c'est confirmé :** la qualification à l'inscription ne dit plus
« WordPress ou Squarespace » mais **« WordPress, ou une plateforme métier vérifiée compatible »**,
et Squarespace bascule du côté « nous vous préparons tout, vous collez ». C'est une décision
commerciale, pas technique, et elle doit être prise **avant** d'écrire une ligne de publication.

**Comment la trancher :** une demi-journée sur la documentation développeur Squarespace en vigueur,
et un compte d'essai. Rien d'autre.

### D.6 Verdict D

| | |
|---|---|
| **Réutilisable tel quel** | `content_months_kit_month_key` **comme motif** d'idempotence par période ; `authorizeCron` ; la discipline « réserver avant, solder après » de `reserve_content_image`/`settle_content_image` |
| **Réutilisable moyennant adaptation** | `content_publications` peut devenir le journal des publications **réelles** en gagnant `remote_id`, `state`, `attempt` — son `INSERT` refusé et son écrivain unique sont déjà la bonne forme |
| **Entièrement à construire** | connexions + secrets + chiffrement ; client WordPress ; client Squarespace (**si possible**) ; file durable ; reprise ; révocation ; qualification de plateforme |
| **Mort** | rien |

---

## E. Le cycle récurrent

### E.1 Ce qui existe

**Six tâches planifiées, dans `vercel.json`** `READ` :

| chemin | horaire | ce qu'elle fait |
|---|---|---|
| `/api/cron/anon-briefs` | `0 5 * * *` | purge les briefs anonymes > 30 j |
| `/api/cron/purge-events` | `0 4 * * *` | purge `funnel_events` au-delà de la rétention |
| `/api/cron/purge-deleted-kits` | `0 6 * * *` | purge les kits supprimés > 30 j |
| `/api/cron/nudges` | `0 14 * * *` | deux relances e-mail, bornées à 200 |
| `/api/cron/trial-ending` | `0 15 * * *` | préavis légal avant prélèvement (7 j) |
| `/api/cron/trial-guard` | `0 17 * * *` | **un essai dont le préavis n'a pas été délivré ne convertit pas** |

**Une septième existe en code et ne tourne pas** : `/api/cron/content-month`, **absente de
`vercel.json`** `VERIFIED` et derrière `CONTENT_GENERATION_ARMED`, non positionnée `READ`. Elle
répond 503 en nommant la variable. C'est la maquette de production mensuelle du produit, écrite et
désarmée.

**Autorisation** : `authorizeCron` / `CRON_SECRET`, un seul point `READ`.
**Durée** : `maxDuration = 300` sur tous les balayages `READ` — la limite Vercel.

### E.2 Idempotence par période — le motif est déjà là

**`content_months_kit_month_key` est unique sur `(brand_kit_id, month)`** `VERIFIED`. Et le
commentaire de `frontend/lib/content/generate/queue.ts` dit exactement la bonne phrase `READ` :
*« a double fire cannot produce two months — the second insert is refused by the database rather
than by a flag someone remembered to check »*.

**C'est la réponse à « comment garantir qu'une abonnée reçoit sa page du mois une fois et une seule
fois ».** Une contrainte d'unicité sur `(sujet, période, genre)`, et l'insertion qui échoue est la
garantie. Ce motif est à reprendre tel quel pour la page mensuelle, les posts Google, et le
rafraîchissement saisonnier.

**La file, elle, n'existe pas.** `VERIFIED` : la « file » actuelle est une ligne `content_months` en
état `generating`. Pas de `attempts`, pas de `next_attempt_at`, pas de `last_error`, pas d'état
terminal d'échec. Un mois qui échoue reste `generating` pour toujours — et l'en-tête du module le
reconnaît à demi-mot en refusant d'écrire la ligne tant que le générateur est désarmé.

### E.3 Ce qui manque pour le cycle de The Fill

1. **Un sujet qui n'est plus le kit.** The Fill solo est par kit ; The Fill cabinet est
   **par clinicienne**. `content_months.brand_kit_id` n'a pas de variante « membre ».
2. **Un balayage qui tient dans 300 secondes.** Une page de site rédigée + scannée + publiée, par
   abonnée, ne tient pas pour N abonnées dans un seul run. Il faut un curseur, un lot borné, et un
   run qui reprend là où il s'est arrêté — les balayages existants bornent déjà à 200/500 `READ`,
   mais ils **abandonnent** le reste jusqu'au lendemain, ce qui est acceptable pour une purge et ne
   l'est pas pour un livrable dû.
3. **Une distinction entre « dû » et « produit ».** Aujourd'hui la ligne `content_months` est les
   deux à la fois. Un mois dû et non produit doit être visible et réessayable.
4. **Le rafraîchissement saisonnier du profil PT** : une quatrième périodicité (trimestrielle), sans
   forme aujourd'hui.

### E.4 Verdict E

| | |
|---|---|
| **Réutilisable tel quel** | `authorizeCron` ; le motif d'unicité `(sujet, période)` ; la discipline des balayages bornés ; la mécanique de préavis et de garde d'essai, qui est la partie la plus mûre du produit |
| **Réutilisable moyennant adaptation** | `/api/cron/content-month` comme squelette ; `content_months` comme table de périodes, moyennant un sujet et des colonnes d'échec |
| **Entièrement à construire** | la file durable ; le curseur de lot ; la séparation dû/produit ; la périodicité trimestrielle |
| **Mort** | rien — mais §J signale que le **contenu** produit par ce cycle change entièrement |

---

## F. Les entitlements et la facturation

### F.1 Le point d'étranglement, lu dans la base

`VERIFIED`, corps des fonctions lus :

```
kit_paid_access(uuid) → text
  'not_found'         si le kit n'appartient pas à auth.uid() via projects
  'payment_required'  si not brand_kit_entitled(kit)
  null                sinon

brand_kit_entitled(uuid) → boolean
  la projet est à auth.uid()
  ET (  il existe une purchases sur CE projet, à CETTE user, dont le status
        ∈ brand_kit_entitling_statuses()
     OU comp_grant_active(auth.uid()) )

brand_kit_entitling_statuses() → text[]   -- IMMUTABLE
  {'paid', 'partially_refunded'}

content_kit_access(uuid) → kit_paid_access(uuid)   -- un simple alias
```

**C'est bien un point d'étranglement unique, et il est correct.** Une vingtaine de RPC le
franchissent (`get_content_month`, `get_publishing_log`, `approve_content_month`,
`site_spec_*`, `get_brand_asset_*`…).

### F.2 ⚠ Les lecteurs applicatifs qui réinterprètent le droit

**Trois, et deux sont des divergences actives.**

**1. `resolveEntitledTier` — divergence VERIFIED.**
`frontend/lib/billing/entitlements.ts` `READ` :

```ts
.from("purchases").select("tier, project_id")
.eq("status", "paid")            // ⚠
.eq("project_id", projectId);
```

La base dit que `partially_refunded` **donne droit** (`brand_kit_entitling_statuses()`
`VERIFIED`). Ce lecteur dit qu'il ne donne rien. **Conséquence mesurable** : une acheteuse
partiellement remboursée a son kit **ouvert** (la base le dit) et se voit refuser **toutes les
surfaces au-dessus de `starter`** en 402 par `surfaceRefusal`, avec un message qui lui propose
d'acheter ce qu'elle a déjà. Le même fichier exporte pourtant
`ENTITLING_STATUSES = ["paid", "partially_refunded"]` avec un commentaire qui dit précisément
*« CETTE LISTE DOIT DIRE LA MÊME CHOSE QUE brand_kit_entitled »* — **la constante est juste et la
requête ne la lit pas.**

**2. `countUnpaidProjects` — même filtre `.eq("status","paid")`** `READ`. Moins grave : le plafond
est anti-abus et *fail-open*, donc une partiellement remboursée compte pour non payée et consomme un
des trois briefs gratuits. C'est un inconfort, pas un droit perdu.

**3. `isEntitledToMonthlyPresence` — ⚠ aucun point d'étranglement SQL n'existe.**
`frontend/lib/billing/entitlements.ts` `READ` :

```
entitled = status ∈ {active, trialing}
        || (status = 'past_due' ET current_period_end + 3 jours > maintenant)
```

**La base ne connaît pas cette règle.** `subscriptions.active` est une colonne générée, miroir du
statut Stripe, et le commentaire du module dit lui-même que ce **n'est pas** la règle d'accès parce
que *« la base ne tient délibérément aucune horloge »* `READ`. L'abonnement est donc le contraire
exact du kit : **le droit est décidé en TypeScript, dans un seul fichier, sans autorité en base.**
Ce qui a sauvé le kit d'une divergence — une fonction SQL à laquelle tout le monde doit demander —
n'existe pas pour l'abonnement. Et c'est **l'abonnement que la nouvelle offre multiplie** (The Fill
solo, The Fill cabinet, par clinicienne).

**4. `lib/billing/surfaces.ts`** : `SURFACE_MIN_TIER`, 19 surfaces, entièrement en TypeScript
`READ`. Pas une divergence — c'est une politique commerciale, honnêtement documentée comme
« le fichier EST la politique » — mais c'est une seconde source qui devra grossir avec les SKU.

### F.3 L'état actuel, en objets

`VERIFIED` :

- `plans` : **4 lignes** — `free` (0), `starter` (7 900), `practice` (14 900), `signature` (24 900),
  chacune avec `directions_limit`, `regenerations_limit`, `image_budget_cents`.
- `purchases` : 12 colonnes, CHECK `tier ∈ {starter, practice, signature}`, CHECK
  `status ∈ {pending, paid, partially_refunded, refunded, disputed, failed}`, unique sur
  `stripe_checkout_session_id`, **FK `project_id` ON DELETE SET NULL** (l'entrée à orphelins,
  déjà documentée), **pas de colonne `quantity`**.
- `plan_grants` : idempotence par `grant_key` unique, FK `tier → plans.tier`.
- `grant_plan_allowance(project, tier, grant_key)` : `service_role` seulement, lève si le tier
  n'est pas un plan, rend `false` sur un projet nul.
- `subscriptions` : 17 colonnes, **unique sur `user_id`** — *une ligne par utilisateur*, pas
  d'`organization_id`, pas de `quantity`, pas de siège.
- `purchase_status_events` : journal en écriture seule (`append_only` + `advance` + `apply`), la
  bonne forme.
- Les prix vivent **deux fois** : `plans.price_cents` (db) et `KIT_PLANS[t].amountCents` (frontend
  `READ`). Identiques aujourd'hui `VERIFIED` — rien ne les tient ensemble.

### F.4 Ce qu'exige chaque nouveauté

| nouveauté | ce qu'elle coûte |
|---|---|
| **Nouveaux SKU** (Foundation 390 $, Roster 690 $, add-on 89 $) | 3 CHECK à étendre (`purchases.tier`, `brand_kits.tier`, et `plans` via la FK), + lignes `plans`, + `KIT_PLANS`, + `SOLD_TIER_NAME`, + une variable d'env par identifiant de prix Stripe. **Mécanique, mais touche la contrainte qui garde l'argent.** |
| **+120 $ par clinicienne au-delà de 5** | `purchases` n'a **pas de `quantity`** `VERIFIED`. Soit une colonne, soit une ligne par siège. La seconde est plus proche de la forme actuelle (journal d'événements, `highestTier` prend le plus généreux) mais casse `highestTier`, qui ne sait pas additionner. |
| **Abonnement facturé au siège avec proration** | le changement le plus profond de ce volet. `subscriptions` est unique par `user_id` : il faut `organization_id`, `quantity`, déplacer l'unicité, et faire lire `items.data[0].quantity` au webhook — qui ne lit aujourd'hui qu'un `stripe_price_id` `READ`. La proration est côté Stripe et ne coûte rien **si** la quantité est le seul levier. |
| **Add-on** | un achat qui n'est pas un palier. `highestTier` ne sait rien faire d'un achat orthogonal ; il faut une seconde notion (`purchases.kind ∈ {tier, addon}`) ou une surface gardée par la présence d'un achat plutôt que par un palier. |
| **Changement de palier** | pour un achat unique, `highestTier` suffit — c'est ce qui marche aujourd'hui. **Pour un abonnement, rien** : pas de descente de palier, pas de date d'effet, pas de traitement du crédit. |
| **Pack déclenché par l'embauche** | `invite_clinician` existe et **n'a aucun effet de facturation** `VERIFIED` (corps lu). Aucun hook vers Stripe nulle part. Il faut : l'invitation incrémente la quantité de l'abonnement du cabinet, et l'acceptation déclenche la production du pack. Deux moments distincts, et le second peut ne jamais venir. |

### F.5 Verdict F

| | |
|---|---|
| **Réutilisable tel quel** | `brand_kit_entitled` / `kit_paid_access` **comme motif et comme autorité** ; `plan_grants` et son idempotence ; `purchase_status_events` ; le webhook, qui couvre déjà 11 types d'événements dont les remboursements, les litiges et le paiement différé — c'est un actif sérieux |
| **Réutilisable moyennant adaptation** | `plans` (des lignes) ; `subscriptions` (colonnes + unicité) ; `KIT_PLANS`/`SURFACE_MIN_TIER` (des tables TS qui grossissent) |
| **Entièrement à construire** | la quantité de sièges ; l'achat add-on ; la descente de palier d'abonnement ; **une autorité SQL pour le droit d'abonnement** |
| **⚠ À corriger avant tout le reste** | `resolveEntitledTier` ne lit pas `brand_kit_entitling_statuses()`. C'est la divergence que la nouvelle offre va multiplier par le nombre de SKU. |

---

## G. La tenancy multi-cliniciennes

### G.1 Ce qui est réellement posé, lu dans la base

`VERIFIED` :

- **`organizations`** : `id`, `name`, `created_at`, `updated_at`, `brand_charter_kit_id`.
  **Pas de `slug`, pas de `owner_user_id`** — le spec du 2 septembre les demandait
  (`frontend/TENANCY_DECISION_2026-09-02.md` `READ`) ; la propriété passe par un rôle sur
  `organization_members`.
- **`organization_members`**, 11 colonnes : `organization_id`, `user_id` (nullable),
  `role ∈ {owner, clinician}`, `status ∈ {invited, active, removed}`, `invited_email`,
  `invite_token_hash`, `invite_expires_at`, `activated_at`, `project_id`.
  Deux CHECK de forme sérieux : une ligne `active` **doit** avoir `user_id` et `activated_at` ; une
  ligne `invited` **doit** avoir `user_id` nul, un e-mail, un hash et une expiration.
- **`projects.organization_id`** + FK `ON DELETE RESTRICT` + CHECK
  `projects_tenant_present_check` : `organization_id is not null OR anon_token_hash is not null`.
  **Un projet possédé a donc forcément une organisation** — et le trigger
  `projects_bind_organization` lève si l'owner n'en a pas.
- **`is_org_member(uuid)`** `SECURITY DEFINER`, écrite.
- **L'invitation, complète** : `invite_clinician` (32 octets, base64url, 14 jours, refus
  indistinguable, ré-invitation qui remplace au lieu d'accumuler), `organization_invitation_preview`,
  `accept_organization_invitation` (refus unique `not_open` pour expirée / dépensée / inexistante /
  déjà membre).
- **La charte, en colonnes** : `organizations.brand_charter_kit_id` ;
  `brand_kits.derived_from_charter_kit_id`, `charter_accepted_state`, `charter_accepted_at`,
  `detached_from_charter_kit_id`, `detached_at` ; **cinq CHECK** (`_pair`, `_is_not_itself`,
  `_is_object`, `_not_detached_from_current_charter`, `_detached_pair`) et le trigger
  `brand_kit_charter_is_own_practice`, qui refuse de dériver d'une charte qui n'est pas celle de son
  propre cabinet.

### G.2 ⚠ Ce qui est à moitié fait : le layer n'est pas branché

**Le chiffre qui résume tout** `VERIFIED` :

> **33 policies nomment encore `auth.uid()`. 2 policies utilisent `is_org_member`.**
> Et ces deux-là sont `organizations_select_member` et `organization_members_select_member` —
> **c'est-à-dire les deux tables du layer lui-même.**
> **Aucune table métier n'est scopée à l'organisation.**

Conséquences, toutes `VERIFIED` :

- **`owns_project()`** — la fonction que lisent `project_briefs`, `brand_kits` et toute leur
  descendance — compare toujours `p.user_id = auth.uid()`. `is_org_member` **n'y est pas appelée**.
  `TENANCY.md` §10.8 (frontend `READ`) dit que c'est exactement ce que la session suivante devait
  faire : *« owns_project should end up calling is_org_member rather than the two coexisting »*.
- **Neuf tables comparent un `user_id` dénormalisé** porté sur la ligne elle-même :
  `brand_assets`, `check_rewrite_usage`, `launch_checklist_items`, `notifications`, `projects`,
  `purchases`, `site_specs`, `subscriptions`, `usp_fingerprints`. Ce sont les « shape B » de
  `TENANCY.md` §4, **inchangées**.
- **`organizations` et `organization_members` n'ont QUE des policies `SELECT`.** Aucune écriture
  cliente n'est possible : toute mutation passe par les trois RPC `SECURITY DEFINER`.
  **Et il n'existe aucune RPC `remove_clinician`** — l'énumération complète de `pg_proc` ne
  la contient pas. Le statut `removed` est dans le CHECK, et rien ne sait le poser.

### G.3 L'état des données

`VERIFIED`, lignes comptées le 13 septembre : **3 organisations, 3 membres — tous `owner` —
0 invitation en cours, 0 organisation portant une charte, 3 projets tous rattachés, 1 kit,
4 achats, 1 abonnement.**

**Autrement dit : une clinicienne n'a jamais été invitée, jamais activée, et le chemin n'a jamais
été parcouru de bout en bout par une donnée réelle.** Ce n'est pas un reproche — la table est
neuve de deux jours. C'est un fait à connaître avant de bâtir The Roster dessus.

### G.4 Ce qui manque pour l'offre cabinet

| besoin de l'offre | état |
|---|---|
| N cliniciennes sous un compte | **tables prêtes, accès non branché.** Une clinicienne activée ne verrait le kit de personne, et son propre kit ne serait visible par personne d'autre qu'elle. |
| Ajout d'une clinicienne | invitation **complète et soignée** ; **aucun effet de facturation**, aucune production de pack |
| Retrait d'une clinicienne | **rien.** Pas de RPC, pas de décision sur ce qui lui reste, pas de décrément de siège |
| Isolation | **à faire** : 19 policies « shape A » à une feuille près (`pr.user_id = auth.uid()` → `is_org_member(pr.organization_id)`), 14 policies « shape B » où il faut retirer la colonne dénormalisée de la policy |
| Facturation au siège | voir §F.4 |
| Cohérence de marque entre cliniciennes | **colonnes et CHECK posés, règles non écrites.** `TENANCY.md` §12 porte trois décisions (ce qui s'hérite, ce qui se passe quand la charte bouge, ce qu'une clinicienne peut redéfinir) **en prose**. Aucune ligne de code ne les applique. |

### G.5 Verdict G

| | |
|---|---|
| **Réutilisable tel quel** | l'invitation entière ; les CHECK de forme de `organization_members` ; le CHECK de locataire présent sur `projects` ; `projects_bind_organization` et sa couture `service_role` ; `is_org_member` |
| **Réutilisable moyennant adaptation** | les 19 policies shape A — une feuille chacune, et **elles échouent fermées pendant qu'elles sont fausses**, ce qui est visible et signalé |
| **Entièrement à construire** | `owns_project` appelant `is_org_member` ; les 14 policies shape B ; le retrait d'une clinicienne ; la facturation au siège ; l'application des trois décisions de charte |
| **Mort** | rien |

---

## H. L'Ethics Guard

### H.1 Les deux systèmes, et ce que chacun couvre

Ils sont bien **deux, distincts, et ils ne couvrent pas la même chose.**

**Système 1 — les principes compilés, côté Node (jamais en base).**
`frontend/lib/ethics/rules.ts` `READ` :
- `ETHICS_SYSTEM_RULES` — **niveau 1**, le bloc de six règles injecté dans chaque prompt ;
- `FORBIDDEN_PATTERNS` — **niveau 2**, des expressions régulières compilées, chacune portant l'`id`
  de la règle de la table `ethics_rules` qu'elle fait respecter, chacune avec sa base déontologique
  (ACA C.3.a, APA 5.01(b)…) et une sévérité `block` / `warn` ;
- `lib/ethics/guard.ts` — `enforceEthics(fields, rules, rewrite)` : passe déterministe, puis
  **réécriture du seul champ fautif**, deux reprises au maximum, puis on lève ;
- `lib/ethics/disclaimer.ts` — **niveau 3**, ce que la praticienne lit ;
- le verdict est persisté dans `brand_kits.ethics_check`, contraint par
  `brand_kit_ethics_check_valid` `VERIFIED`.

Le **texte** des six règles vit en base : `ethics_rules`, **6 lignes actives** `VERIFIED`
(`timeframe`, `proven`, `client_voice`, `credential`, `scarcity`, `diagnosis`), avec
`short_label`, `description`, `example_forbidden`. Corriger une règle en base corrige à la fois ce
que le modèle reçoit et ce que la praticienne lit, **sans déploiement**. C'est bien fait.

**Système 2 — la correspondance littérale, côté PostgREST.**
`usp_banned_phrases_check(p_text)` `VERIFIED`, corps lu : une correspondance sur limite de mot
(`\y … \y`), phrase par phrase, contre `banned_phrases` — **30 lignes actives**, trois catégories
`VERIFIED` : `directory_cliche` (« safe space », « judgment-free », « your journey »,
« meet you where you are »…), `outcome_promise` (« guaranteed results », « cure your »…),
`hype` (« amazing », « life-changing »…). `SECURITY DEFINER`, **EXECUTE accordé à `service_role`
seulement** `VERIFIED`.

**Qui couvre quoi :**

| sortie | couverte par |
|---|---|
| directions, guide de voix, accroches sociales | système 1, dans `runGenerationPipeline` |
| phrase de positionnement (USP) | système 2 (`usp_banned_phrases_check`) **+** système 1 en amont |
| posts mensuels (`on_image_text`, `caption`) | système 1, dans `lib/content/generate/pipeline.ts` — *« BOTH scanned before EITHER is stored »* `READ` |
| texte collé dans Check | système 1 (`reviewText`), avant **et après** la réécriture |
| blocs de démarches (`launch/material.ts`) | **par transitivité** : assemblés de champs déjà scannés |
| champs structurés PT (`launch/directory.ts`) | **aucun** — et il n'en faut pas : ce sont des libellés de catalogue |

### H.2 ⚠ Par où ça court-circuite déjà la garde

**Trois chemins, tous `VERIFIED` ou `READ`.**

1. **`site_spec_patch`** — la praticienne édite elle-même la copy de son site. **Aucun scan
   déontologique dans la RPC** `VERIFIED` (corps de la fonction : validation de forme, de longueur,
   de contraste ; rien de déontologique). `FINDINGS.md` (frontend) le nomme :
   *« ⚠ The Lovable re-scan does NOT cover her copy »* `READ`.
2. **`create_content_item` / `update_content_item`** — le scan vit dans la **pipeline**, pas dans la
   RPC. Un item créé ou modifié par la RPC ne repasse par rien `VERIFIED`.
3. **⚠ Et ces trois-là sont exécutables par le rôle `anon`.** `VERIFIED`, énumération des droits
   `EXECUTE` :

   | fonction | rôles |
   |---|---|
   | `create_content_item` | `authenticated`, **`anon`**, `service_role` |
   | `update_content_item` | `authenticated`, **`anon`**, `service_role` |
   | `site_spec_patch` | `authenticated`, **`anon`**, `service_role` |
   | `get_publishing_log` | `authenticated`, **`anon`**, `service_role` |

   C'est exactement le quatrième défaut permissif du `README.md` du backend (*« `anon` reçoit
   EXECUTE sur toute fonction créée »*) `READ` : `20260902090000_revoke_internal_function_surface.sql`
   existe mais **ne couvre pas ces quatre-là**. Les fonctions vérifient l'accès dans leur corps, donc
   l'effet est probablement nul aujourd'hui `INFERRED` — mais **des RPC d'écriture sont dans la
   surface OpenAPI anonyme**, et c'est le motif qui a déjà mordu ce dépôt une fois.

### H.3 Par où passent les nouvelles sorties — et ce qui les ferait court-circuiter

| nouvelle sortie | chemin naturel | risque |
|---|---|---|
| diagnostic de profil | `reviewText` | **aucun** — c'est le scanner lui-même |
| premier paragraphe réécrit | `check/rewrite` | **aucun** — re-scanné par construction |
| profil PT intégral | à écrire | **doit** passer par `enforceEthics`, pas par un nouvel assemblage |
| **page de site mensuelle** | si elle atterrit via `site_spec_patch`, **elle saute la garde** | ⚠ **le risque n°1 de ce volet** |
| texte de fiche Google | à écrire | même exigence que le profil PT |
| post Google | si écrit via `create_content_item`, **il saute la garde** | ⚠ |
| **one-page prescripteurs** | à écrire | ⚠ **et le registre n'est pas le même** : le lecteur est un médecin, la tentation d'une allégation clinique est plus forte, et les six règles ont été écrites pour une lectrice patiente |

### H.4 Un défaut du scanner, déjà documenté et non corrigé

`FINDINGS.md` (frontend) `READ` : *« `checkEthics`'s prohibitive-context test is too narrow »* —
le test de contexte prohibitif rate deux formes **que le produit écrit lui-même**, et la conséquence
est des **faux positifs**. C'est la bonne direction d'erreur (refuser à tort plutôt que laisser
passer), mais ça veut dire que chaque nouveau type de sortie augmente le nombre de réécritures
inutiles, et que les deux reprises de `enforceEthics` peuvent s'épuiser sur rien.

### H.5 Verdict H

| | |
|---|---|
| **Réutilisable tel quel** | `enforceEthics` et sa forme (scan → réécriture ciblée → re-scan → on lève) ; `ethics_rules` en base ; `banned_phrases` en base ; le verdict persisté et contraint |
| **Réutilisable moyennant adaptation** | `usp_banned_phrases_check` mérite d'être appelée sur **toutes** les sorties d'annuaire, pas seulement sur l'USP — les 20 clichés d'annuaire sont écrits **pour Psychology Today** |
| **Entièrement à construire** | un registre déontologique pour la one-page prescripteurs ; un scan **dans** `site_spec_patch` et dans `update_content_item`, ou un chemin qui les contourne |
| **Mort** | rien |

---

## I. La mesure

### I.1 Ce qui existe

**`funnel_events`**, 9 colonnes `VERIFIED` : `id bigint`, `occurred_at`, `event`, `visitor_day`,
`project_id`, `brand_kit_id`, `user_id`, `anonymous`, `props jsonb`.

Trois gardes, toutes `VERIFIED` :
- `funnel_events_event_check` : `^[a-z][a-z0-9_]{2,48}$` ;
- `funnel_events_visitor_day_check` : 32 hex ou nul ;
- **`funnel_props_are_safe(props)`** : objet, **≤ 12 clés**, **aucun objet ni tableau imbriqué**,
  **chaîne ≤ 64 caractères**, clé ≤ 40 caractères — le commentaire du corps dit *« a long one is
  prose, and prose is the thing this table must never hold »*.

Accès : **policy `funnel_events_denied` ALL `false`** `VERIFIED`. Écriture par
`record_funnel_events(jsonb)` et lecture par `funnel_report(from, to)` — **les deux `service_role`
seulement** `VERIFIED`. Rétention 180 jours (`app_settings.funnel_retention_days`), purge
quotidienne `fail-open`. `funnel_steps` : 12 lignes `VERIFIED`. 28 lignes d'événements en base.

### I.2 ⚠ Peut-elle accueillir les chiffres Psychology Today ? Non.

Un entier passerait `funnel_props_are_safe` sans problème. **Trois raisons de ne pas le faire, et la
troisième suffit :**

1. **C'est un journal d'événements à rétention automatique de 180 jours.** Un relevé mensuel doit
   survivre au moins 13 mois pour qu'un delta annuel existe. La purge tourne tous les jours à 4 h.
2. **Rien n'est lisible par la cliente.** RLS deny-all, lecture `service_role` uniquement. **Le
   rapport mensuel est à elle** ; le servir voudrait dire soit ouvrir cette table, soit la lire
   côté serveur avec la clé de service pour la lui rendre. La première est un recul de sécurité,
   la seconde est une rustine.
3. **Pas d'unicité par (sujet, période).** Une double saisie fait deux lignes, et le delta devient
   faux sans qu'aucune erreur ne se voie — **exactement la famille de défaut que le `README.md` du
   backend appelle « une valeur qui disparaît sans erreur »**.

### I.3 Ce qu'il faut à la place, et ce que ça coûte

**Un stockage distinct, petit.** `INFERRED`, dimensionné à partir des tables existantes :

- une table `directory_metrics` : `subject_id` (kit **ou** membre — voir §G), `platform`,
  `period date`, `views int`, `contacts int`, `entered_at`, `entered_by`,
  **unique `(subject_id, platform, period)`** ;
- RLS propriétaire par le même chemin que `content_items` (kit → projet → organisation, une fois
  §G fait) ;
- une RPC `get_directory_report(subject, months)` qui rend la série **et les deltas** — le delta se
  calcule en SQL par `lag()`, il ne mérite pas de code applicatif ;
- un écran de saisie et un rappel mensuel.

**Le coût réel n'est pas le calcul, c'est la saisie.** Les chiffres sont saisis **par la cliente**,
donc le rapport n'existe que si elle les entre, tous les mois. Et la chaîne qui la rappelle existe
déjà et est mûre : `lib/email/templates.ts`, `transport.ts`, `state.ts` (déduplication + plafond de
72 h), `notifications` + `sync_notifications`, et le cron `nudges` avec son balayage borné `READ`.
**Un rappel de plus est une entrée dans un balayage existant, pas un système.**

⚠ **Et un mois sans saisie doit se dire.** Un rapport qui montre un delta calculé sur une période
manquante est faux et personne ne le verra. La table doit pouvoir porter « pas de relevé » comme
un état, pas comme une absence de ligne.

### I.4 Verdict I

| | |
|---|---|
| **Réutilisable tel quel** | toute la chaîne e-mail et notification ; le motif d'unicité par période ; la discipline de rétention |
| **Réutilisable moyennant adaptation** | `funnel_events` reste **pour ce qu'elle fait** — mesurer l'entonnoir. Elle ne doit **pas** accueillir les chiffres PT |
| **Entièrement à construire** | `directory_metrics`, sa RLS, sa RPC de delta, l'écran de saisie, le rappel, et l'état « mois non relevé » |
| **Mort** | rien |

---

## J. Ce qui devient mort — signalé, **rien n'est supprimé**

### J.1 L'identité visuelle passe en add-on à 89 $ — **ce qui reste nécessaire**

**Presque tout.** L'add-on livre toujours logo, couleurs et typographie, donc restent
**indispensables** :

- `frontend/lib/kit/render/` : `wordmark.ts`, `monogram.ts`, `monogram-icon.ts`,
  `business-card.ts`, `palette-sheet.ts`, `og-image.ts`, `email-signature.ts`,
  `color-exports.ts`, `composition.ts`, `luminance.ts`, `rasterize.ts`, `font-cache.ts`,
  `variants.ts`, `registry.ts`, `zip.ts` `READ` ;
- en base : `brand_assets`, `asset_catalog` (la majorité des 35 clés), `record_brand_asset`,
  `get_brand_asset_manifest`, `asset_variant_path`, les versions, les téléchargements `VERIFIED` ;
- **`directions` / `direction_assets` restent** : les trois directions sont la façon dont
  l'identité se choisit, et c'est aussi la révélation qui fait l'acquisition ;
- `site_specs` (couleurs, typos, contraste) reste **doublement nécessaire** : à l'add-on **et** au
  site de The Foundation.

### J.2 Ce qui devient sans emploi si l'abonnement Instagram disparaît

**En base** `VERIFIED` — 8 tables :
`content_items`, `content_months`, `content_grounds`, `content_checkins`, `content_preferences`,
`content_registers`, `content_image_allowance`, `content_publications`.

**RPC** `VERIFIED` — 13 :
`create_content_item`, `update_content_item`, `delete_content_item`, `get_content_item`,
`content_item_json`, `get_content_month`, `approve_content_month`, `set_content_checkin`,
`set_content_preferences`, `get_content_image_allowance`, `reserve_content_image`,
`settle_content_image`, `mark_content_posted`, `get_publishing_log`, `content_kit_access`,
`content_error`, `content_normalize_tags`.

**Frontend** `READ` :
`app/app/content/` (3 écrans), `app/api/content-items/*`, `app/api/content-months/*`,
`app/api/brand-kits/[id]/content`, `/check-in`, `/content-preferences`, `/publishing-log`,
`app/api/cron/content-month`, `app/api/monthly-presence/checkout`, `app/dev/content-plan`,
`lib/content/**` (≈ 20 modules), `components/content/*`, `components/presence/*`.

**Fichiers de marque** `VERIFIED` — 7 des 35 clés de `asset_catalog` :
`post_statement_1080`, `post_question_1080`, `post_notes_1080`, `post_signature_1080`,
`story_1080x1920`, `cover_facebook_1640x624`, `cover_linkedin_1584x396` — plus
`brand_kits.social_templates` et ses deux CHECK, et `lib/kit/render/social-posts.ts` /
`covers.ts`.

**Checklist** : les étapes `social_setup` et `first_post` dans `launch_checklist_items`,
`STEP_PLACES` et `STEP_ASSET_KEYS` `READ`.

### J.3 ⚠ Trois choses à ne surtout pas jeter avec le reste

1. **`subscriptions` et toute la mécanique d'essai.** `isEntitledToMonthlyPresence`, les 90 jours
   d'essai, `/api/cron/trial-ending` (préavis à 7 jours, motivé par le Bus. & Prof. Code § 17602
   californien) et `/api/cron/trial-guard` (*un essai dont le préavis n'a pas été délivré ne
   convertit pas*). **The Fill est un abonnement mensuel** : cette mécanique se re-pointe, elle ne
   meurt pas. C'est la partie la plus mûre et la plus chèrement acquise du produit.
2. **`content_months` et son unicité `(brand_kit_id, month)`.** Le **contenu** change entièrement ;
   **le motif d'idempotence par période est la réponse à la question centrale de The Fill** (§E.2).
   Ne pas supprimer la table avant d'avoir repris le motif ailleurs.
3. **L'imagerie.** `brand_images`, `brand_image_daily_spend`, `lib/images/**`,
   `reserve_image_regeneration` / `settle_image_regeneration` servent **aussi** les photographies du
   kit, donc l'add-on. Seul `content_grounds` — les fonds des posts mensuels — meurt sûrement.

### J.4 Verdict J

| | |
|---|---|
| **Devient mort** | 8 tables de contenu, ~17 RPC, ~25 modules frontend, 7 clés de fichiers, 2 étapes de checklist, `social_templates` |
| **Reste nécessaire à l'add-on 89 $** | tout `lib/kit/render/` sauf `social-posts.ts` et `covers.ts` ; `brand_assets` ; `asset_catalog` (28 clés sur 35) ; `directions` ; `site_specs` (couleurs et typos) |
| **⚠ Ne pas supprimer** | `subscriptions` + essai + préavis + garde ; le motif d'unicité par période ; l'imagerie |
| **Action de cette session** | **aucune.** Signalé, rien supprimé. |

---

## K. Les défauts connus du dépôt, appliqués aux objets nouveaux

Le `README.md` du backend ouvre sur *« Discipline NULL — à lire avant d'écrire un validateur »*
`READ`, et nomme **quatre défauts permissifs par défaut** qui ne lèvent jamais rien. Voici lesquels
menacent quoi.

### K.1 « NULL passe un CHECK »

Un CHECK ne refuse que sur FALSE ; il **accepte** NULL. Cinq validateurs jsonb ont été troués ainsi
au lot 6, et une palette incomplète passait à l'écriture pour casser plus bas.

**Ce que ça menace :** `directory_metrics` (les chiffres PT), `site_connections` (les credentials
CMS), `charter_accepted_state`, et tout validateur du profil PT ou de la one-page prescripteurs.
Le garde-fou existe — le test de `20260829112000_null_safe_jsonb_validators.sql` est **paramétré sur
`pg_proc`** et fait échouer la suite si un validateur arrive sans couverture — **mais seulement s'il
est reconnu comme validateur.** Une fonction nommée hors convention y échappe.

### K.2 « `||` rend NULL sur un opérande NULL »

**Trois lignes de jetons ont disparu d'un livrable payant** sans la moindre erreur, parce qu'un
`'libellé: ' || p_spec->>'colonne'` valait NULL.

**Ce que ça menace, directement :** le profil PT intégral et la one-page prescripteurs sont, par
nature, des **assemblages de champs souvent absents** — un numéro de licence, un état, un tarif, une
modalité. Si l'un d'eux est écrit en SQL par concaténation, une section entière disparaît en silence
d'un livrable à 390 $. **C'est le défaut le plus probable de tout ce chantier.**

### K.3 « `array_to_string` écarte les trous »

C'est ce qui a rendu le précédent invisible.

**Ce que ça menace :** toute liste dans un profil PT — spécialités, modalités, populations —
assemblée depuis des tableaux d'identifiants dont un libellé de catalogue peut manquer (un `id`
retiré, désactivé, renommé). `frontend/lib/launch/directory.ts` fait déjà **la bonne chose** côté
TypeScript : un `id` dont la ligne de catalogue a disparu **ne rend aucun champ** plutôt qu'un `id`
brut `READ`. La même discipline n'est écrite nulle part côté SQL.

### K.4 « `anon` reçoit EXECUTE sur toute fonction créée » — ⚠ **encore vrai aujourd'hui**

`VERIFIED`, §H.2 : `create_content_item`, `update_content_item`, `site_spec_patch` et
`get_publishing_log` — **quatre RPC dont trois en écriture** — sont exécutables par `anon`.

**Ce que ça menace :** **toute** nouvelle RPC de ce chantier. `publier_page`,
`enregistrer_metriques`, `ajouter_clinicienne`, `retirer_clinicienne`, `connecter_cms` hériteront du
même défaut, et trois d'entre elles touchent de l'argent ou des secrets. La révocation doit être
**explicite et testée par énumération**, pas espérée.

### K.5 « Une comparaison contre un `auth.uid()` nul »

Le dépôt a traité le cas : `caller_is_the_database()` et
`20260911190810_the_caller_with_no_identity_is_the_database.sql` `VERIFIED`.

Et les 9 tables shape B comparent `user_id = auth.uid()` : avec un `auth.uid()` nul, `user_id = NULL`
vaut NULL, la policy refuse — **fail-closed, correct.** `VERIFIED` (lecture des `qual`).

**Le risque est l'inverse, et il arrive avec §G** : une policy qui écrirait
`organization_id = (select org_de(auth.uid()))` sur une organisation nulle se comporte de la même
façon et refuse — sauf si quelqu'un ajoute un `coalesce` « pour que ça marche ». `is_org_member`
protège déjà contre ça (`p_org_id is not null and exists(...)` `VERIFIED`) : **il faut que les 33
policies passent par elle plutôt que d'écrire la comparaison à la main.**

### K.6 « Des vérifications qui décrivent l'intention plutôt que le comportement »

`TENANCY.md` §10.7 (frontend `READ`) raconte le cas exact, et c'est le plus instructif du dépôt :

> Un garde-fou de migration probait son propre CHECK avec
> `insert … select … from brand_kits limit 1`, enveloppé d'un `exception when others`. Sur une base
> fraîche il n'y a aucun `brand_kits` : le SELECT ne rend rien, l'INSERT n'écrit rien, **rien ne
> lève**, le garde reste faux et la migration s'interrompt. **Conséquence : l'énumération de la
> surface de fonctions n'avait jamais tourné en CI.**
> *« A guard that depends on seed data asserts the seed, not the constraint. »*

**Ce que ça menace :** chaque garde-fou qu'on écrira pour les nouvelles tables (connexions CMS,
métriques, sièges). La règle qui en sort — **proher avec un `gen_random_uuid()` plutôt qu'avec une
ligne existante**, parce qu'un CHECK est vérifié pendant l'insertion tandis qu'une clé étrangère est
un trigger AFTER, donc le CHECK lève en premier — est écrite et éprouvée. Il faut l'appliquer.

Un **sibling non corrigé** est nommé dans le même passage : `20260911133504` est **sauté entièrement
sur une base vide** (`if v_user is not null`) — vide en CI plutôt qu'en échec. Même famille.

### K.7 « Des tests qui prouvent la règle sans jamais parcourir le chemin »

`TENANCY.md` §10.7 `READ` : la suite backend compte **75 fichiers**, et au dernier relevé **13
échouaient, ramenés à 12** — *« stale expectations after deliberate changes … and four not yet
diagnosed »*. Dont celui-ci, cité par son auteur : *« `consume_anon_generation` gained a `p_kind`
argument … and its test still calls the one-argument form. I changed a signature four sessions ago
and the suite could not tell me. »*

Je n'ai pas exécuté la suite (session en lecture seule) : l'état **aujourd'hui** est `INFERRED` à
partir de ce relevé du 11 septembre, et il peut avoir bougé.

**Ce que ça menace, et c'est le plus grave de la section :** **douze rouges masquent le
treizième.** Un chantier de cette taille — nouveaux SKU, nouvelles policies, nouvelles tables — a
besoin d'une suite qui dise quelque chose. Aujourd'hui, « la suite est rouge » n'apprend rien.

### K.8 Et un défaut spécifique à ce chantier, trouvé pendant cet audit

**`resolveEntitledTier` ne lit pas `brand_kit_entitling_statuses()`** — §F.2. `VERIFIED` des deux
côtés : la base dit `{paid, partially_refunded}`, le lecteur TypeScript filtre `status = 'paid'`.
C'est **littéralement** le motif annoncé dans le brief de cette session (*« les lecteurs TypeScript
ont déjà divergé de l'autorité par le passé »*), et il est **actif maintenant**, avant que le moindre
SKU nouveau soit ajouté.

### K.9 Verdict K

| défaut | menace la plus proche | gravité |
|---|---|---|
| `\|\|` rend NULL | **profil PT et one-page prescripteurs assemblés en SQL** | ⚠⚠ la plus probable |
| `anon` a EXECUTE | **les 5 nouvelles RPC d'écriture** (argent, secrets) | ⚠⚠ |
| lecteur TS qui réinterprète le droit | **actif aujourd'hui** sur `resolveEntitledTier` | ⚠⚠ |
| garde-fou qui asserte le seed | tout garde-fou des nouvelles tables | ⚠ |
| suite rouge | **tout le chantier**, qui n'aura pas de filet | ⚠⚠ |
| NULL passe un CHECK | nouveaux validateurs jsonb | ⚠ |
| `array_to_string` | listes du profil PT | ⚠ |
| `auth.uid()` nul | fail-closed aujourd'hui ; à surveiller en §G | faible |
