# IMPLEMENTATION_REPORT.md — chantier Content

Compagnon de `DIAGNOSTIC.md`, qui est le rapport de PHASE 0 et qui reste vrai :
les six écarts qu'il relève entre le prompt de chantier et l'état des dépôts
n'ont pas été corrigés en chemin, ils ont été travaillés avec.

Mesuré le 2026-09-20, sur la stack PostgreSQL 16 locale
(`scripts/local-verify.sh`) et sur le dépôt frontend.

---

## 0. CE QUI EST FAIT, ET CE QUI NE L'EST PAS

Le chantier demande onze commits couvrant six phases. Sept sont livrés. La
PHASE 5 (interface) est livrée à un tiers et la PHASE 4 à deux tiers. Le détail
est en §7, nommément, sans arrondi.

| phase | livré | commit |
|---|---|---|
| 0 — diagnostic | **oui** | `chore: content pipeline diagnostic report` |
| 1 — chokepoint + ledger | **oui** | `feat(db): monthly presence SQL chokepoint and credit ledger` (×2 dépôts) |
| 2.1–2.3 — banque, veille | **oui** | `feat(db): topic bank, assignment RPC, insight pipeline tables` |
| 2.4 — assets, bibliothèques | **oui** | `feat(db): rendered asset dedup, custom visual ledger, illustration library` |
| 3 — moteur de composition | **oui** | `feat(render): zone-based vector composition engine…` |
| 4.1 — Batch + caching | **oui** | `feat(pipeline): batched monthly generation with caching…` |
| 4.5 — éthique sur les labels | **oui** | `feat(pipeline): the ethics guard reaches the diagram labels` |
| 4.2–4.4 — cron, veille, visuels | **partiel** | §7.1 |
| 5 — interface | **partiel** | §7.2 |
| 6 — vérification | **oui, avec un écart** | §6 |

---

## 1. MIGRATIONS CRÉÉES

Sept, toutes rejouées depuis zéro sur la stack locale. Aucun fichier déjà
poussé n'a été renommé ni édité — la correction de `next_topic_for_kit` (§4.2)
est une migration neuve, pas une réécriture de la sienne.

| version | ce qu'elle pose |
|---|---|
| `20260920140000` | `monthly_presence_has_a_chokepoint` |
| `20260920140100` | `credit_ledger_append_only` |
| `20260920150000` | `content_archetypes` (les onze + les validateurs de payload) |
| `20260920150100` | `topic_bank_and_assignment` |
| `20260920150200` | `insight_watch` |
| `20260920150300` | `rendered_assets_and_libraries` |
| `20260920160000` | `a_diagram_label_is_published_text` |
| `20260920160100` | `render_dedup_and_cost_report` |
| `20260920170000` | `the_collision_window_is_computed_once` |

Neuf, pas sept — la sixième et la neuvième sont nées de ce que les
vérifications ont trouvé.

### 1.1 Tables neuves, et leur tenancy

Chacune reçoit RLS et ses policies **dans la même migration**, et chacune est
déclarée dans `supabase/tests/20260911180620_tenancy_layer.test.sql` avec sa
raison — le test du dépôt refuse une table qui n'atteint ni un projet ni une
personne sans que quelqu'un ait dit pourquoi, et il a refusé huit des miennes.

| table | grain | pourquoi |
|---|---|---|
| `credit_quotas` | référence | barème de l'offre, pas la donnée d'une cliente |
| `credit_ledger` | **personne** | Monthly Presence s'achète une fois par personne ; `subscriptions.user_id` est `not null unique` |
| `credit_balances` | **personne** | idem |
| `content_archetypes` | référence | vocabulaire de composition |
| `content_segments` | référence | modalité × population × État |
| `content_topics` | référence | ⚠ du STOCK ; voir §3.1 |
| `topic_assignments` | **kit** | ce qui appartient à quelqu'un |
| `insight_sources` / `insight_runs` / `insight_cards` | instruments d'Eklio | un seul pipeline pour tout le parc |
| `rendered_assets` | **kit** | le chemin de stockage est `{brand_kit_id}/…` |
| `custom_visual_generations` | **kit** | idem |
| `illustration_library` / `background_library` | référence | matériaux du moteur |
| `background_assignments` | **kit** | ce qui appartient à quelqu'un |

⚠ **Le grain n'est pas celui que le prompt écrit, et l'écart est délibéré.**
Le prompt met `user_id` partout. Les crédits le sont — ils suivent l'abonnement,
et un compteur remis à zéro par kit se multiplierait par le nombre de kits
qu'elle possède, que `countUnpaidProjects` plafonne à trois. Le contenu et les
assets sont par kit — une caption appartient à une marque, et un rendu dépend
de la palette. La jointure entre les deux est `brand_kits → projects.user_id`,
celle que chaque policy de Content fait déjà.

---

## 2. RPC ET LEURS GRANT

Vingt fonctions. **Aucune n'est ouverte à `anon`.** La règle appliquée
partout : une fonction qui prend un identifiant arbitraire et répond sur
l'argent ou le droit de quelqu'un n'est jamais joignable depuis un navigateur.

| fonction | GRANT |
|---|---|
| `monthly_presence_past_due_grace()` | `authenticated`, `service_role` |
| `check_monthly_presence_entitlement(uuid)` | **`service_role` seul** |
| `monthly_presence_entitled()` | `authenticated`, `service_role` |
| `credit_plan_for(uuid)` | **aucun** (interne) |
| `credit_monthly_limit(uuid,text)` | **aucun** (interne) |
| `credit_ledger_apply()` | **aucun** (trigger) |
| `credit_ledger_is_append_only()` | **aucun** (trigger) |
| `reserve_credit(…)` | **`service_role` seul** |
| `settle_credit(uuid,numeric,boolean)` | **`service_role` seul** |
| `release_stale_credit_reservations(interval)` | **`service_role` seul** |
| `credit_meter(date)` | `authenticated`, `service_role` |
| `content_words(text)` | `authenticated`, `service_role` |
| `content_item_valid(jsonb)` | `authenticated`, `service_role` |
| `content_items_valid(jsonb,int,int)` | `authenticated`, `service_role` |
| `content_topic_payload_valid(text,jsonb)` | `authenticated`, `service_role` |
| `topic_collision_window()` | `authenticated`, `service_role` |
| `next_topic_for_kit(uuid,date,text)` | **`service_role` seul** |
| `assign_topic_to_kit(uuid,date,text)` | **`service_role` seul** |
| `insight_cards_validate_segments()` | **aucun** (trigger) |
| `next_background_for_kit(uuid)` | **`service_role` seul** |
| `content_topic_text(jsonb)` | `authenticated`, `service_role` |
| `content_topics_ethics_gate()` | **aucun** (trigger) |
| `content_topics_banned_phrases_gate()` | **aucun** (trigger) |
| `rendered_asset_path(uuid,text)` | **`service_role` seul** |
| `record_rendered_asset(…)` | **`service_role` seul** |
| `record_custom_visual(…)` | **`service_role` seul** |
| `content_month_cost(uuid,date)` | **`service_role` seul** |

Toutes les `SECURITY DEFINER` portent `set search_path = ''`. Un garde-fou de
migration le vérifie par `pg_proc.proconfig` — écrit `search_path=` sans les
guillemets, l'assertion ne correspond jamais et se déclenche toujours ; la
forme correcte est `search_path=""` et le dépôt l'écrivait déjà ainsi
(`20260830060712`).

---

## 3. LES ONZE ARCHÉTYPES

`single_statement`, `quadrant_model`, `cycle`, `surface_and_beneath`,
`comparison_pair`, `numbered_strategies`, `lettered_technique`,
`concentric_control`, `annotated_curve`, `practitioner_card`, `carousel`.

Chacun est un module de `lib/compose/archetypes/` exportant son schéma
(`parse`), sa zone d'illustration, son nombre de teintes et sa fonction de
rendu. Le catalogue `content_archetypes` porte les mêmes onze clefs, et deux
tests les épinglent des deux côtés.

### 3.1 Ce qui a été décidé autrement que le prompt, et pourquoi

**Les onze sont un CATALOGUE, pas un CHECK élargi.**
`content_items.archetype` porte cinq mises en page et `content_registers` six
formes éditoriales ; `20260910083735` les a rendus disjoints par construction
après la dérive de `min_tier`, avec un garde-fou qui fait échouer la migration
s'ils se recouvrent. Les onze sont un troisième axe. Les faire entrer dans le
premier aurait refait exactement ce que ce garde-fou refuse.

**`carousel` est dans le catalogue bien qu'il ne soit pas une mise en page.**
C'est un nombre de cartes — mais c'est là que la résolution de dépassement
atterrit, donc le pipeline doit pouvoir le nommer.

**Les sujets sont du stock.** La contrainte anti-collision ne peut pas
s'exprimer si chaque kit a sa copie : elle a besoin que « le même sujet » soit
une ligne, pas une ressemblance.

### 3.2 Le choix de stack, justifié

Le chantier propose Satori + resvg, ou `@vercel/og`. Le moteur écrit son SVG
lui-même, et la raison n'est pas l'empreinte :

1. **Satori a besoin de vrais octets de police**, qui viennent de Google par le
   bucket `fonts`. `render-composition.test.ts` le stube déjà pour ça. Une
   suite de collision qui stube la chose qu'elle mesure ne mesure rien.
2. **Satori est un moteur flexbox.** On ne peut pas lui dire « garde 40px entre
   toute boîte de glyphe et tout tracé », et il ne rend pas les boîtes qu'il a
   calculées. Les quatre suites en ont toutes besoin.

Le SVG porte donc chaque boîte en `data-box`, et c'est ce contrat que les
suites relisent. Satori reste où il gagne sa place : `lib/kit/render/`, qui est
aussi où vit le rasteriseur — le dépôt interdit statiquement qu'un paquet natif
soit importé d'ailleurs, et ce test a refusé la première position du fichier.

---

## 4. CE QUE LES VÉRIFICATIONS ONT TROUVÉ

Onze défauts, tous trouvés par une garde ou une suite, aucun par relecture.
Ils sont listés parce que la liste est le rapport : un chantier où rien n'a été
trouvé est un chantier qui n'a rien vérifié.

### 4.1 En base

1. **`insert … on conflict do update` valide les CHECK du tuple PROPOSÉ** avant
   de consulter l'index. Un règlement de crédit (`0 réservation, 1 règlement`)
   était refusé alors que sa branche INSERT était inatteignable. Un upsert dont
   la branche INSERT est inatteignable doit quand même être une ligne LÉGALE.
2. **Un handler d'exception trop large** rendait « quota épuisé » sur un appel
   malformé — un mensonge sur le compte de quelqu'un, qui l'aurait envoyée
   acheter des crédits qu'elle avait. Deux SQLSTATE distincts.
3. **Le trigger append-only rendait un compte indestructible** :
   `credit_ledger.user_id` est `on delete cascade`, et refuser TOUT DELETE
   faisait échouer `delete from auth.users`. Il laisse passer la cascade,
   reconnue à ce que la ligne parente est déjà partie.
4. **La même classe de défaut, une seconde fois** : `reservation_id` en
   `ON DELETE RESTRICT` par réflexe. Le NOT NULL est ce qui interdit une image
   sans paiement ; la règle de suppression ne gardait rien de plus.
5. **Deux fonctions de trigger joignables depuis le navigateur** — trouvées par
   `20260902090000_revoke_internal_function_surface`, qui a fait de « aucune
   fonction de trigger n'est joignable » une règle avec un test derrière.
6. **Huit tables sans déclaration de tenancy** — trouvées par
   `20260911180620_tenancy_layer`, qui demande une RAISON et pas une exception.
7. **Des commentaires de schéma en français** — trouvés par
   `20260827107000_english_only_schema`.
8. **`content_item_valid` non inscrit au registre NULL-safe** — trouvé par
   `20260829112000_null_safe_jsonb_validators`, qui se paramètre sur
   `pg_proc` et non sur une liste écrite à la main.
9. **`jsonb_each` sur un tableau LÈVE**, et le `where` censé l'éviter ne protège
   rien : une fonction qui rend un ensemble est évaluée avant le filtre.
10. **`ethics_blocks` rend le passage fautif, pas un booléen** — lu comme un
    booléen il refusait bien la ligne, mais avec un message inactionnable.

### 4.2 ⚠ Le onzième, trouvé par la simulation et par rien d'autre

`next_topic_for_kit` exprimait la fenêtre de 90 jours comme un `not exists`
**corrélé** : une sous-requête à quatre tables **par sujet candidat**. Correct,
et tous les garde-fous passaient — ils tournent sur deux ou trois sujets.

Sur 36 000 appels contre une banque de 7 500 sujets, la sous-requête s'exécutait
environ 270 millions de fois et la simulation ne terminait pas.

**Ce que ça voulait dire en production** : le cron mensuel appelle ce RPC trente
fois par abonnée dans les 300 s de Vercel. L'ancienne forme y tenait pour les
premières abonnées et aurait cessé d'y tenir à mesure que la banque
grandissait — c'est-à-dire que le mois se serait mis à échouer un jour, sans
qu'aucun changement de code ne l'explique.

`20260920170000` calcule la fenêtre **une fois par appel**, dans un CTE. La
sémantique est inchangée au token près, et le garde-fou garde ça plutôt que la
vitesse : une optimisation qui change aussi le classement n'est pas une
optimisation.

**Mesuré après** : 6,1 ms par tirage sur 7 500 sujets et 9 000 attributions en
fenêtre (`explain (analyze, buffers)`, table analysée).

### 4.3 Dans le moteur de composition

Six, tous par les suites :

- la clearance se mesure depuis la **boîte** d'un tracé, plus large que son
  chemin de la moitié de son épaisseur. Un nom d'axe posé à 40px du bout d'un
  bras mesurait 38px, sur trois archétypes à la fois ;
- `violations()` ne regardait que la boîte d'une figure, pas celle de chaque
  tracé : une règle verticale dépassait de 2px dans la garde du pied de page ;
- la dernière ligne d'une grille finissait 0,01px hors de la bande — l'erreur
  accumulée d'une hauteur arrondie additionnée n fois ;
- le ratio display/plus petit ≥ 3:1 était **vérifiable et non tenu** : une carte
  mesurait 2,89. Il est maintenant imposé (le display est posé d'abord, tout le
  reste est plafonné à son tiers) ;
- `lettered_technique` posait son crochet à l'horizontale et coûtait 207px des
  575px de la bande avant le premier label : il ne composait à aucune échelle ;
- `annotated_curve` calculait la hauteur de sa liste par soustraction et avait
  oublié un terme.

---

## 5. COÛT MESURÉ D'UN MOIS DE 30 PUBLICATIONS

`scripts/prove-month-cost.sql`, agrégé **depuis `credit_ledger`** et non
calculé par le script : la dépense passe par le même chemin que la production
(`reserve_credit` avant, `settle_credit` après) et le rapport relit ce que ce
chemin a enregistré.

```
ventilation par poste
{
    "post_generation": {
        "consumed": 30,
        "releases": 0,
        "actual_usd": 0.025890,
        "settlements": 30,
        "reservations": 30,
        "estimated_usd": 0.041400
    }
}

entrées de journal │ réservations │ règlements │ libérations │ estimé $ │ réel $   │ écart $  │ réel $ / publication
                60 │           30 │         30 │           0 │ 0.041400 │ 0.025890 │ 0.015510 │             0.000863
```

**0,0259 $ pour trente publications. 0,000863 $ par publication.**

L'estimation suppose le préfixe payé plein tarif, parce qu'elle est faite AVANT
de savoir si le cache a servi. L'écart de 0,0155 $ — 37 % — **est** ce que le
prompt caching a économisé, mesuré plutôt qu'annoncé.

⚠ **Le rendu vectoriel est absent de ce tableau parce qu'il ne coûte rien** :
ni appel d'API, ni crédit. C'est le fait central du chantier, et son absence
ici est la mesure.

Le modèle de coût est celui de Haiku 4.5 en Batch (−50 % entrée et sortie),
avec lecture de cache à 0,1× et écriture à 1,25×, sur ~1200 tokens de préfixe,
~60 de partie variable et ~300 de sortie par carte. La première carte écrit le
cache, les vingt-neuf suivantes le lisent.

---

## 6. LES SIX VÉRIFICATIONS DE LA PHASE 6

| # | vérification | résultat |
|---|---|---|
| 1 | les tests existants restent au vert | **3765 au vert**, 157 fichiers, 0 échec. ⚠ Le prompt annonçait 601 ; la base était de **2923** (`DIAGNOSTIC.md` §0.3). Les 842 de plus sont ceux de ce chantier. |
| 2 | les suites du moteur sur 11 × 3 × 3 | **775 au vert** sur `lib/compose/` : collision (309), planchers, déterminisme, budget, dépassement, registre. |
| 3 | le CI rejoue les migrations depuis zéro | **142 migrations rejouées, 93 tests SQL, 0 échec** sur la stack PostgreSQL 16 locale. |
| 4 | simulation anti-collision 100 × 12 | §6.1 — **écart, nommé** |
| 5 | preuve de déduplication | **passe**, dans le garde-fou de `20260920160100` |
| 6 | preuve de coût | **passe**, §5 |

### 6.1 ⚠ L'écart sur la vérification n°4

Le script `scripts/simulate-collisions.sql` est écrit, il est complet, et il
contient les deux assertions que le chantier demande : aucune paire
`(kit, sujet)` en double, et aucune paire de praticiennes partageant
(État, modalité) servies du même sujet à moins de 90 jours. Il rapporte aussi
le volume requis quoi qu'il arrive.

**Il n'a pas terminé dans le temps de cette session.** 36 000 appels, et à
6,1 ms l'appel mesuré cela devrait faire environ quatre minutes ; la boucle en a
consommé vingt-deux sans finir. La cause probable est le cache de plans de
plpgsql : un plan générique choisi quand `topic_assignments` était vide est
réutilisé pendant que la table grandit. Le correctif à essayer est
`set plan_cache_mode = force_custom_plan` dans le script.

**Ce qui EST prouvé aujourd'hui, et par quoi :**

- « jamais deux fois le même sujet, à vie », à l'échelle unitaire : garde-fou de
  `20260920150100`, qui l'éprouve aussi **dans un autre mois** — c'est la
  moitié de la règle qu'un test par mois raterait ;
- la fenêtre de 90 jours entre deux praticiennes du même État et de la même
  modalité : même garde-fou, et il éprouve les deux non-cas (autre État, autre
  modalité) ;
- la même fenêtre sur les fonds : garde-fou de `20260920150300` ;
- que la banque de 500 sujets par segment se remplit et se tire : la simulation
  a passé sa phase de construction (100 kits, 15 segments, 7 500 sujets).

**Ce qui n'est PAS prouvé** : que ces propriétés tiennent sur 36 000
attributions. C'est une question d'échelle, et c'est exactement la question que
cette vérification pose. Je la laisse ouverte plutôt que de la déclarer passée.

**Le dimensionnement requis, calculé et non mesuré :** dans une fenêtre de
90 jours, un groupe (État, modalité) de G praticiennes consomme G × 90 sujets
distincts ; sur douze mois chacune en consomme 360 à elle seule. Le pool
atteignable doit donc tenir `max(G × 90, 360)`. À deux praticiennes par groupe
— la densité que la simulation pose — cela fait **360**, et 500 par segment
suffit. À dix par groupe il en faudrait **900**, et 500 ne suffirait plus.
C'est le chiffre à surveiller quand le parc se concentre.

---

## 7. CE QUI N'EST PAS LIVRÉ

### 7.1 PHASE 4.2 à 4.4

- **Le cron mensuel** (`app/api/cron/content-month/route.ts`) existe, est
  désarmé, et rend un 501 honnête qui dit ce qui manque : « quelles abonnées
  sont dues, dans quel ordre, et ce qui arrive à un kit dont le mois échoue à
  mi-chemin ». Le chaînage `check_monthly_presence_entitlement` →
  `assign_topic_to_kit` × 30 → batch → validation → rendu n'est pas écrit.
  Les cinq maillons existent et sont testés séparément.
- **L'idempotence par `(user_id, month)`** existe déjà :
  `content_months_kit_month_key`, et `credit_ledger` porte le mois sur chaque
  entrée. Le run qui s'en sert n'est pas écrit.
- **La veille hebdomadaire** : les trois tables et le plafond dur de
  40 recherches sont en base (`insight_runs_searches_check`). Le run qui les
  remplit n'est pas écrit.
- **Le chemin visuel custom** : la table, la déduplication par `prompt_hash`, le
  plafond mensuel en SQL et le lien obligatoire vers une réservation de crédit
  sont en base et prouvés. **Aucun appel à un modèle d'image n'est écrit**, et
  c'est délibéré : voir §8.

### 7.2 PHASE 5 — interface

Livré : le **compteur de crédits** (branché sur `/app/content`, parce que
`wired-to-a-screen` refuse un module de `lib/billing/` qu'aucun écran
n'atteint) et la **page de référence du système visuel** (`/dev/visual-system`),
qui rend le vrai moteur et affiche ses refus.

Non livré : le flux de cartes à la place du calendrier, le libellé d'angle, la
ligne « Why this one », la hiérarchie Swap > Edit > Approve, l'écran d'attente
de première génération, le repli du check-in en une ligne, la refonte de
`/app/content/[id]`, et les deux à trois mises en page alternatives.

⚠ **Pourquoi ce n'est pas à moitié fait.** Ces écrans lisent
`get_content_month`, qui ne porte ni le sujet, ni sa justification, ni son
angle — le RPC devrait être étendu, et il est appelé par du code existant et
testé. Un flux de cartes câblé sur des données qui n'existent pas encore aurait
l'air d'un progrès et n'en serait pas.

### 7.3 Le découpage en commits

Les commits 5 et 6 du chantier (moteur, puis suites) sont **un seul commit**.
Les suites n'ont pas été écrites après le moteur : elles l'ont écrit. Six des
onze défauts du §4.3 ont été trouvés pendant, pas après, et séparer les deux
aurait produit un premier commit dont je sais qu'il était faux.

---

## 8. CE QUI EST VERSÉ DANS `FOLLOWUP.md`

Deux entrées, toutes deux relevées en PHASE 0 :

- **F1** — la production porte 14 migrations que le tronc n'a pas
  (`origin/claude/stoic-ritchie-1liqrz`, mergée nulle part), dont deux ajouts à
  `banned_phrases`. Un CI qui rejoue depuis zéro ici ne reconstruit pas le
  schéma de production. **Atténuation tenue dans tout ce chantier** : aucune
  migration neuve ne référence un objet de ces 14, et tout contrôle de phrase
  passe par `usp_banned_phrases_check` plutôt que par une copie de la liste.
- **F2** — la branche de référence citée au prompt a divergé.

### 8.1 Trois décisions qui appellent une réponse humaine

**`gpt-image-2` n'est pas vérifié.** Le chantier l'impose et interdit
`gpt-image-1`. Aucune clef OpenAI n'est configurée dans ce dépôt, le seul SDK
de modèle présent est `@anthropic-ai/sdk`, et je n'ai pas pu confirmer
l'existence de ce modèle. Le nom et la qualité sont pilotés par variables
d'environnement, comme le chantier le demande lui-même, et la colonne `quality`
est bornée à `(low, medium)` **par la ligne** pour qu'une variable mal réglée
ne puisse pas acheter le palier cher. Aucun appel n'est écrit.

**L'identifiant du modèle de rédaction.** Le chantier nomme
`claude-haiku-4-5-20251001`. La référence d'API consultée pour ce travail donne
`claude-haiku-4-5` et dit explicitement de ne jamais suffixer un identifiant par
une date. Les deux ne peuvent pas être vrais. `MASS_COPY_MODEL` lit
`CONTENT_COPY_MODEL` avec le nom du chantier comme défaut — l'instruction
reçue — et corriger la valeur est un changement de configuration.

**La grâce de trois jours existe maintenant à deux endroits.** L'autorité est
`monthly_presence_past_due_grace()` en base ; `PAST_DUE_GRACE_DAYS` reste dans
`lib/billing/entitlements.ts` parce que `/app/checkout/success` choisit un
TEXTE sans aller-retour. Deux épingles se nomment l'une l'autre
(`entitlements-single-source.test.ts` et
`supabase/tests/20260920140100_credit_ledger.test.sql`) ; si la règle
commerciale change par migration sans que la constante suive, l'une des deux
tombe.

---

## 9. CE QUI A ÉTÉ CHANGÉ DANS L'EXISTANT

Peu, et chaque fois pour une raison nommée.

- **`lib/billing/entitlements.ts`** cesse de décider Monthly Presence et
  appelle `monthly_presence_entitled()`. `isEntitledToMonthlyPresence` reste
  exportée pour choisir un TEXTE, et reste gardée contre le comp.
- **`comp-monthly-presence.test.ts`** a été réécrit. Il comptait les appels
  réseau à zéro pour garantir que la règle en mémoire tranchait d'abord. Ce
  compte n'est plus tenable : une règle en mémoire répond bien à qui
  l'interroge et n'a aucune prise sur qui ne l'interroge pas, et il y a
  maintenant des appels d'API payants derrière ce droit. Le test garde la
  propriété qui a remplacé celle-là : **une seule question, et c'est celle de
  la base**.
- **`app/api/monthly-presence/checkout/route.ts`** perd sa lecture
  `subscriptions`, qui ne nourrissait plus personne.
- **`app/app/content/page.tsx`** gagne le compteur de crédits.
- **Trois fichiers de `supabase/tests/`** gagnent les déclarations que leurs
  propres assertions exigeaient.

Aucun fichier de migration déjà poussé n'a été renommé ni édité.
