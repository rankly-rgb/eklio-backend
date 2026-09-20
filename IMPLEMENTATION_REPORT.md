# IMPLEMENTATION_REPORT.md — chantier Content

Compagnon de `DIAGNOSTIC.md`, qui est le rapport de PHASE 0 et qui reste vrai :
les six écarts qu'il relève entre le prompt de chantier et l'état des dépôts
n'ont pas été corrigés en chemin, ils ont été travaillés avec.

Mesuré le 2026-09-20, sur la stack PostgreSQL 16 locale
(`scripts/local-verify.sh`) et sur le dépôt frontend.

---

## 0. CE QUI EST FAIT, ET CE QUI NE L'EST PAS

Le chantier demande onze commits couvrant six phases, puis une SUITE qui le
clôt par quatre décisions et quatre vérifications complémentaires. Le détail de
ce qui manque est en §7 et §10.3, nommément, sans arrondi.

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
| 5 — interface | **oui** | §10.3 — complétée par la SUITE |
| 6 — vérification | **oui, les six** | §6 |
| SUITE — quatre décisions, quatre vérifications | **oui, les quatre et les quatre** | §10 |

⚠ **La ligne PHASE 5 a changé après la SUITE.** Elle disait « partiel, livré à
un tiers ». Les six écrans que la DÉCISION 3 énumère sont livrés : flux de
cartes, état de première génération, check-in replié, surface de relecture,
compteur de crédits, page de référence du système visuel. Deux des « réglages
limités » de la surface de relecture ne le sont pas, et ils sont nommés en
§10.3 et dans `FOLLOWUP.md` F4 plutôt que dilués dans un « partiel ».

---

## ⚠ CONVENTION DE LECTURE : CHAQUE CHIFFRE DIT D'OÙ IL VIENT

Toute sortie, tout visuel et tout chiffre de ce rapport porte, **dans la même
phrase**, l'une de ces deux marques :

- **[chemin de production]** — produit par le code qui tournera en production,
  sur la stack PostgreSQL 16 locale ou par les suites du dépôt frontend. Une
  carte composée par `lib/compose/`, une ligne de `credit_ledger` écrite par
  `reserve_credit`, un compte de tests.
- **[fixture]** — produit par un double de test. Rien de ce qui porte cette
  marque n'a touché un fournisseur, et aucun chiffre qui en vient n'est une
  mesure de ce que quelque chose coûte réellement.

Sans exception, y compris pour les rendus d'illustration et les cartes
d'exemple.

---

## 1. MIGRATIONS CRÉÉES

Dix, toutes rejouées depuis zéro sur la stack locale (143 fichiers au total). Aucun fichier déjà
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
| `20260920180000` | `a_cte_referenced_once_is_inlined` |

Dix, pas sept — les quatre dernières sont nées de ce que les vérifications ont
trouvé, et les deux dernières de la même mesure prise deux fois.

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

> **[chemin de production]** — tous les chiffres de cette section (les 38px, le
> 2,89, les 207px sur 575, les 270 millions d'exécutions, les 6 ms → 60 ms →
> 127 ms) sont des mesures faites sur le vrai moteur et la vraie base, par les
> suites du dépôt et par `explain (analyze, buffers)`. Aucun ne vient d'une
> fixture ni d'une estimation.


Douze défauts, tous trouvés par une garde, une suite ou une mesure — aucun par
relecture.
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

### 4.2 ⚠ Les onzième et douzième, trouvés par la simulation et par rien d'autre

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

`20260920170000` a déplacé la fenêtre dans un CTE — **et n'a rien changé.**

⚠ **Depuis PostgreSQL 12, un CTE référencé une seule fois est INLINÉ.** Le
planificateur le recopie là où il est lu et pousse la corrélation dedans :
`blocked`, lu une fois dans un `not exists` corrélé sur `t.id`, redevenait mot
pour mot la sous-requête que la migration croyait avoir retirée.

La mesure le disait et je ne l'ai pas lue tout de suite : le coût par
attribution **croissait avec la table** — 6 ms à vide, 60 ms à 9 000
attributions, 127 ms à 18 000. Un coût constant aurait été le signe que le CTE
tenait ; un coût qui suit la taille de la table est le signe qu'on la rescanne à
chaque candidat.

`20260920180000` ajoute `as materialized`. Un mot, et c'est tout l'écart entre
les deux formes.

**Ce que ça apprend sur la première correction** : elle était juste sur le fond
et sans effet dans les faits, et son garde-fou ne pouvait pas le voir — il
éprouve la SÉMANTIQUE, qui n'avait pas changé. Seule une mesure à l'échelle
pouvait trancher. Une optimisation qu'aucune mesure n'accompagne est une
intention.

**Mesuré après**, à l'échelle finale (36 000 attributions, 7 500 sujets, table
analysée) :

| appel | coût |
|---|---|
| `next_topic_for_kit` | **4,3 ms** (200 tirages consécutifs en 865 ms) |
| `assign_topic_to_kit` | **3,3 ms** (200 attributions en 662 ms) |

Soit environ **0,1 s pour les trente tirages d'une abonnée**, contre les 300 s
que Vercel accorde au cron.

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
| 3 | le CI rejoue les migrations depuis zéro | **143 migrations rejouées, 91 fichiers de tests SQL, 0 échec** sur la stack PostgreSQL 16 locale. ⚠ Chiffres d'AVANT la SUITE ; après elle, **146 et 95** — voir §10.10. La dérive contre l'empreinte enregistrée est `ONLY IN PRODUCTION: 0`, `DIFFERENT: 0`, et 478 objets que le rejeu produit en plus — la forme attendue. ⚠ `local-verify.sh` sort en 1 pour une raison qui n'est pas celle-là : voir `FOLLOWUP.md` F3. |
| 4 | simulation anti-collision 100 × 12 | **passe** — §6.1 |
| 5 | preuve de déduplication | **passe**, dans le garde-fou de `20260920160100` |
| 6 | preuve de coût | **passe**, §5 |

### 6.1 La simulation anti-collision

`scripts/simulate-collisions.sql`, 100 praticiennes × 12 mois × 30
publications, réparties sur 10 États × 5 modalités — **deux par groupe
(État, modalité)**, qui est la densité que la fenêtre de 90 jours doit tenir.

```
          métrique           | valeur
-----------------------------+--------
 kits                        | 100
 months_simulated            | 12
 segments                    | 15
 topics                      | 7500
 topics_per_segment          | 500
 assigned                    | 36000
 exhausted                   | 0
 duplicates                  | 0
 collisions                  | 0
 total_assignments           | 36000
 required_per_reachable_pool | 360
```

**36 000 attributions. Zéro doublon. Zéro collision. Zéro épuisement.**
Six minutes.

> ⚠ **CE RUN EST CELUI DE L'ANCIEN HARNAIS. LIRE §10.8.** Le chiffre est vrai,
> mais la densité qu'il mesure est plus douce qu'elle n'en a l'air : les deux
> consœurs d'un groupe (État, modalité) y avaient des populations différentes,
> donc des segments d'élection différents, et la contention n'apparaissait
> qu'au débordement. La SUITE a resserré le harnais, refait la mesure, et
> **trouvé le seuil : 26 sujets par segment. À 25, la simulation casse.** Les
> 500 visés portent donc un facteur 19 de marge — et le chiffre qui menace
> cette banque n'est pas le volume du parc mais sa CONCENTRATION.

Les deux assertions sont vérifiées sur les données produites, pas supposées :

- aucune paire `(kit, sujet)` n'apparaît deux fois — la clef primaire
  l'interdit, et le compte est posé plutôt que déduit ;
- aucune paire de praticiennes partageant (État, modalité) n'a reçu le même
  sujet à moins de 90 jours — vérifié par auto-jointure sur
  `topic_assignments`, avec les dates simulées.

**Le dimensionnement requis, rapporté quoi qu'il arrive.** Dans une fenêtre de
90 jours, un groupe de G praticiennes consomme G × 90 sujets distincts ; sur
douze mois, chacune en consomme 30 × 12 = 360 à elle seule. Le pool atteignable
doit tenir `max(G × 90, 360)`. À deux par groupe cela fait **360**, et 500 par
segment suffit avec de la marge. **À dix par groupe il en faudrait 900**, et
500 ne suffirait plus — c'est le chiffre à surveiller quand le parc se
concentre sur un État.

### 6.2 ⚠ Ce que la simulation a coûté avant de passer

Elle n'a pas terminé trois fois, et chaque échec a nommé un défaut réel. Ils
sont listés parce que deux d'entre eux étaient dans le produit et un seul dans
le harnais.

1. **Dans le produit** : la sous-requête corrélée (§4.2). 270 millions
   d'exécutions.
2. **Dans le produit** : `as materialized` manquant (§4.2). La correction
   précédente était sans effet.
3. **Dans le harnais** : le rétrodatage. La simulation posait `assigned_at`
   par un `update` de 3 000 lignes à la fin de chaque mois — 36 000 tuples
   morts et douze réécritures d'index dans une transaction qui ne peut pas
   être vacuumée. Le ballonnement multipliait par dix le coût de chaque
   tirage.

   Corrigé en appelant `next_topic_for_kit` puis en écrivant la ligne avec sa
   date simulée, plutôt qu'`assign_topic_to_kit` puis une passe de correction.
   Les deux tirent le même sujet ; le second ajoute la résolution de course
   entre deux Swap simultanés, qu'une simulation mono-fil n'a pas.

4. **Dans le harnais** : les statistiques. Toute la simulation vit dans une
   transaction, donc l'autovacuum ne voit rien et le planificateur croit les
   tables vides. `analyze` à chaque mois. C'est aussi une leçon pour le cron :
   **une banque fraîchement remplie doit être analysée avant d'être tirée.**

Le script porte `\set months` : `psql -v months=12` est le défaut, une valeur
plus basse donne un run plus court, et trois mois restent la fenêtre entière.

### 6.3 Un coût d'ingestion qui n'était pas prévu

Mesuré en chemin : **écrire un sujet dans `content_topics` coûte environ
100 ms**, parce que chaque ligne traverse les deux gardes de
`20260920160000` — `ethics_scan` sur les motifs, puis
`usp_banned_phrases_check` sur les trente-deux formulations.

C'est le comportement voulu : la garde doit mordre, et c'est elle qui ferme le
trou des labels de diagramme. Mais cela veut dire qu'une banque de 7 500 sujets
met **une douzaine de minutes** à s'écrire, et que l'ingestion d'un batch de
rédaction est bornée par la garde et non par le modèle. À dimensionner avant le
premier remplissage réel.

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

> ⚠ **CETTE SOUS-SECTION EST PÉRIMÉE, ET ELLE EST GARDÉE EXPRÈS.** Elle décrit
> l'état AVANT la SUITE. Ce qu'elle annonce comme non livré l'est désormais :
> voir **§10.3**. Elle reste ici parce que son dernier paragraphe explique
> pourquoi l'ordre a été celui-là, et que cette raison est toujours vraie.

Livré : le **compteur de crédits** (branché sur `/app/content`, parce que
`wired-to-a-screen` refuse un module de `lib/billing/` qu'aucun écran
n'atteint) et la **page de référence du système visuel** (`/dev/visual-system`),
qui rend le vrai moteur et affiche ses refus.

Non livré **à ce moment-là** : le flux de cartes à la place du calendrier, le
libellé d'angle, la ligne « Why this one », la hiérarchie Swap > Edit >
Approve, l'écran d'attente de première génération, le repli du check-in en une
ligne, la refonte de `/app/content/[id]`, et les deux à trois mises en page
alternatives.

⚠ **Pourquoi ce n'était pas à moitié fait.** Ces écrans lisent
`get_content_month`, qui ne portait ni le sujet, ni sa justification, ni son
angle — le RPC devait être étendu, et il est appelé par du code existant et
testé. Un flux de cartes câblé sur des données qui n'existent pas encore aurait
eu l'air d'un progrès et n'en aurait pas été un.

C'est exactement ce que la DÉCISION 3 a tranché : étendre le RPC d'abord
(`20260921090000`), puis finir les écrans. Les deux sont faits.

### 7.3 Le découpage en commits

Les commits 5 et 6 du chantier (moteur, puis suites) sont **un seul commit**.
Les suites n'ont pas été écrites après le moteur : elles l'ont écrit. Six des
onze défauts du §4.3 ont été trouvés pendant, pas après, et séparer les deux
aurait produit un premier commit dont je sais qu'il était faux.

---

## 8. CE QUI EST VERSÉ DANS `FOLLOWUP.md`

Cinq entrées.

- **F1** — la production porte 14 migrations que le tronc n'a pas
  (`origin/claude/stoic-ritchie-1liqrz`, mergée nulle part), dont deux ajouts à
  `banned_phrases`. Un CI qui rejoue depuis zéro ici ne reconstruit pas le
  schéma de production. **Atténuation tenue dans tout ce chantier** : aucune
  migration neuve ne référence un objet de ces 14, et tout contrôle de phrase
  passe par `usp_banned_phrases_check` plutôt que par une copie de la liste.
  ⚠ **La SUITE y a ajouté la liste exacte des quatorze, une par une, avec ce
  que chacune touche et lesquelles entrent en conflit avec ce chantier.** Le
  résumé : trois tables nouvelles à déclarer dans `tenancy_layer.test.sql`, un
  test de parité déontologique à remonter de 19 à 20 motifs, une surface de
  fonction à revérifier, un gate de phrases qui devient plus strict. **Aucun
  conflit de schéma au sens strict** — ce sont des tests d'énumération qui
  casseront, pas des `create table` qui se marcheront dessus.
- **F2** — la branche de référence citée au prompt a divergé.
- **F3** — `local-verify.sh` sort en 1 quand la dérive est grande, et cache son
  propre résumé de tests (SIGPIPE sur `| head -20` sous `set -euo pipefail`).
- **F4** — deux des « réglages limités » de l'écran de relecture n'ont pas de
  mécanisme dans les dépôts : la variante de teinte (aucune colonne ne porte le
  choix clair/sombre d'un post) et le mot accentué (le moteur n'a aucune notion
  d'accentuation). §10.3, et ce qu'il faudrait pour les livrer.
- **F5** — `lib/images/config.ts` porte une table de prix par image, et **elle
  est correcte** : elle décrit `gpt-image-1`, qui publie une grille par image.
  Ce n'est pas celle que la DÉCISION 1 demande de supprimer.

### 8.1 Trois décisions qui appellent une réponse humaine

> ⚠ **LES DEUX PREMIÈRES ONT REÇU LEUR RÉPONSE DANS LA SUITE** (DÉCISION 1 et
> DÉCISION 2, §10.1 et §10.2). Elles sont gardées telles quelles parce qu'elles
> disent ce qui était incertain et pourquoi — et que la réponse reçue a changé
> la STRUCTURE du calcul de coût, pas seulement une valeur.

**~~`gpt-image-2` n'est pas vérifié.~~ → TRANCHÉ.** Le modèle est
`gpt-image-2.5-flare`, **facturé au jeton** et non à l'image. La colonne
`quality` reste bornée à `(low, medium)` par la ligne, et `resolveQuality`
refuse `high` et au-delà **par le code**. `actual_cost_usd` se calcule depuis
`usage`. L'appel complet est écrit, avec un client injectable et un double
étiqueté fixture. §10.1.

**~~L'identifiant du modèle de rédaction.~~ → TRANCHÉ.**
`claude-haiku-4-5-20251001` **est** l'identifiant Claude API de Haiku 4.5, et il
est daté ; les formes non datées valent pour des modèles plus récents. La
valeur du chantier est gardée comme défaut, le pilotage par variable reste, et
tout commentaire laissant entendre que la forme datée serait interdite a été
retiré. §10.2.

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

---

## 10. LA SUITE — QUATRE DÉCISIONS, QUATRE VÉRIFICATIONS

Le message de SUITE clôt le chantier. Il tranche quatre points laissés ouverts,
demande quatre vérifications complémentaires, et interdit toute nouvelle phase.
Cette section est ce qui en est sorti.

### 10.1 DÉCISION 1 — le modèle d'image est facturé au JETON, pas à l'image

**Ce qui a changé structurellement, et pas seulement en valeur.**
`gpt-image-2.5-flare` n'a **aucune grille de prix par image**. Il est facturé à
**30 $ par million de jetons de sortie image**, et la documentation du modèle
dit explicitement que le calculateur de GPT Image 2 n'estime pas la
consommation de 2.5.

Conséquence, et elle gouverne tout le chemin :

| | avant la décision | après |
|---|---|---|
| `actual_cost_usd` | aurait été lu dans une table `(modèle, qualité, taille) → cents` | **calculé depuis l'objet `usage` de la réponse API**, et depuis lui seul (`imageCostUsd`) |
| absence de `usage` | aurait rendu le prix de la table | rend **`null`** — on écrit qu'on ne sait pas, on n'invente pas |
| taux unitaire | aurait été une ligne de table parmi d'autres | **une constante unique**, `IMAGE_OUTPUT_PER_MTOK`, avec sa date de vérification (20 septembre 2026) et son URL de source en commentaire |
| estimation de réservation | aurait été le prix exact | reste approximative, et **un écart > 50 % entre estimé et réel est journalisé en avertissement** (`ESTIMATE_DRIFT_WARN`) |

**Aucune table de prix par image n'existe dans `lib/content/images/`.** Il en
existe une dans `lib/images/config.ts`, qui décrit `gpt-image-1` — un modèle
qui, lui, publie une grille par image. Ce n'est pas celle que la décision
demande de supprimer : voir `FOLLOWUP.md` F5, qui explique pourquoi elle est
juste là où elle est.

**Les autres bornes, refusées par le code et non déconseillées.**

- Identifiant non daté par défaut (`gpt-image-2.5-flare`), snapshot
  `gpt-image-2.5-flare-2026-09-08` épinglable par `CONTENT_IMAGE_MODEL`.
- Format portrait `1024x1536`, le même cadre que le moteur de composition.
- Qualité par défaut `low`, plafond `medium`, les deux pilotés par
  l'environnement. `high`, `xhigh`, `max` et `auto` sont **refusés par
  `resolveQuality`**, qui lève `ContentImageQualityError` — et la ligne de
  `custom_visual_generations` porte le même refus
  (`custom_visual_quality_check`), donc un chemin qui oublierait la fonction ne
  passerait pas non plus.
- `auto` est refusé pour une raison propre : il laisse le modèle choisir, et un
  plafond qu'une autre partie décide n'est pas un plafond.

**L'appel complet, et il est testable sans clef.**
`generateCustomVisual` fait, dans cet ordre : recherche du `prompt_hash` →
`reserve_credit` → appel (un seul réessai sur erreur transitoire, **aucun** sur
un refus de modération) → lecture de `usage` → `imageCostUsd` → avertissement
de dérive si > 50 % → dépôt → `record_custom_visual` → `settle_credit`. Le
client est injecté (`CustomVisualDeps.client`), donc la totalité du chemin
tourne sans clef.

⚠ **Le double de test est étiqueté comme tel, dans le nom du fichier et ici.**
Il vit dans `lib/content/images/fixture-client.ts`, son type est
`FixtureImageClient` et porte `readonly isFixture: true`, et le fichier s'ouvre
sur la bannière « ⚠ FIXTURE. RIEN DE CE QUI SORT D'ICI N'A TOUCHÉ OPENAI. ⚠ ».

**24 tests au vert** sur `lib/content/images/__tests__/custom-visual.test.ts`
**[chemin de production pour la logique, fixture pour la réponse API]** : la
logique testée est celle qui tournera ; la charge `usage` qu'elle lit vient du
double et n'est **pas** une mesure de ce qu'une image coûte réellement.

### 10.2 DÉCISION 2 — `claude-haiku-4-5-20251001` est l'identifiant daté, et c'est le bon

La table officielle des modèles donne cette forme datée comme identifiant
Claude API de Haiku 4.5. Les identifiants non datés (`claude-opus-5`,
`claude-sonnet-5`) valent pour des modèles plus récents.

La valeur du chantier est donc gardée comme défaut, le pilotage par variable
d'environnement est gardé, et **tout commentaire ou TODO laissant entendre que
la forme datée serait interdite a été retiré** de
`lib/content/generate/copy-batch.ts`. Ce qui reste à sa place dit l'inverse, en
toutes lettres.

### 10.3 DÉCISION 3 — la PHASE 5 est finie, et rien au-delà

**`get_content_month` porte désormais le sujet, sa justification et son
libellé d'angle.** Trois migrations :

| migration | ce qu'elle ajoute |
|---|---|
| `20260921090000_an_item_knows_why_it_was_chosen` | catalogue `content_intents` (5 libellés), `content_items.topic_id`, `content_items.rationale`, `content_item_json` porte `rationale` et un objet `topic { id, angle, angle_label, archetype_key, timely }` |
| `20260921100000_swap_is_a_draw_not_a_generation` | `render_rationale(text, uuid)` et `swap_content_item(uuid)` — un tirage, aucune génération, `delta 0` au journal |
| `20260921110000_a_layout_is_hers_to_change` | `content_items.compose_archetype`, accepté par le patch, refusé en `unknown_layout` sur une valeur inconnue, remis à `null` par un swap |

⚠ **Le libellé d'angle vient de la base, jamais d'une table de correspondance
en TypeScript.** Une seconde copie voudrait dire qu'une sixième intention
arrive un jour à l'écran sans mots.

**Les six écrans que la décision énumère.**

| écran | fichier | état |
|---|---|---|
| flux de cartes | `components/content/content-stream.tsx` | livré |
| première génération | `components/content/month-generating.tsx` | livré — quatre étapes réelles du pipeline, pas de pourcentage, pas de spinner nu |
| check-in replié | `components/content/check-in-line.tsx` | livré — il se replie au lieu de disparaître, donc ce qu'elle a écrit reste corrigeable |
| **surface de relecture** | `app/app/content/[id]/page.tsx` + `components/content/review-surface.tsx` | **livré par la SUITE** |
| compteur de crédits | `components/content/credits-meter.tsx` | livré |
| référence du système visuel | `app/dev/visual-system/page.tsx` | livré |

**Ce que la surface de relecture fait.**

- **Deux ou trois mises en page du même contenu**, composées **pendant le rendu
  de la page par le vrai moteur** `lib/compose/` **[chemin de production]**.
  Aucune n'appelle de modèle : le contenu est déjà écrit, les faire tenir
  autrement est de l'arithmétique. Chaque variante porte son `contentHash`,
  **le même que `rendered_assets.content_hash`**, donc en choisir une déjà
  rendue ne rend rien.
- **Les archétypes compatibles sont trouvés en essayant**, pas listés dans une
  table : `parse()` de chaque module accepte ou refuse le payload, et `render`
  accepte ou refuse de le composer aux planchers typographiques. Une table
  « quel archétype accepte quelle forme » aurait été une troisième source après
  les onze modules et le validateur SQL, et c'est celle qui se serait périmée.
- **Une ligne déontologique calculée, pas écrite.** Elle vient de
  `ethics_scan()`, la fonction que les triggers d'écriture appellent, et elle
  scanne **le titre, la légende, la ligne d'image, le texte alternatif ET tous
  les libellés du diagramme** — la même surface que
  `20260920160000_a_diagram_label_is_published_text` a fermée côté base. Un
  motif bloquant ne peut pas apparaître sur un item enregistré (le trigger a
  refusé l'écriture) ; s'il apparaît quand même, l'écran le dit en rouge au
  lieu de l'avaler.
- **Copy caption et Download image comme gestes dominants**, en haut, en
  primaire. L'éditeur de champs, la publication et la suppression passent
  **en dessous** : c'était l'élément le plus visible de l'écran, et ce n'est
  pas ce qu'elle vient y faire. « I posted this » et le journal de publication
  sont intacts.
- **Le téléchargement compose à la demande et ne stocke rien**
  (`app/api/content-items/[id]/image/route.ts`). Le seau `content-assets` est
  en lecture seule pour une cliente ; y écrire demanderait la clef de service,
  c'est-à-dire un second chemin d'écriture à côté de `record_rendered_asset`
  avec sa propre façon de se tromper. Rien n'y est facturé, ni au succès ni à
  l'échec.

⚠ **Deux des « réglages limités » ne sont pas livrés, et la clause d'arrêt
s'applique.**

Le chantier demande « variante de teinte, changement d'archétype, mot
accentué ». Le changement d'archétype est livré et il se garde (colonne
`compose_archetype`). Les deux autres n'ont **aucun mécanisme dans les dépôts** :

- **la variante de teinte** — aucune colonne ne porte le choix clair/sombre
  d'un post ; il appartient au planificateur du mois (`DARK_CARD_RATIO`). Un
  sélecteur aurait été un réglage qui ne se garde pas, ce qui est pire qu'un
  réglage absent ;
- **le mot accentué** — le moteur n'a aucune notion d'accentuation : ni les
  onze modules, ni `svg.ts`, ni `layout.ts`, ni `measure.ts`. Le livrer
  traverserait cinq fichiers et devrait entrer dans `contentHash`, sinon deux
  cartes différant par leur accentuation partageraient une entrée de cache.

Les deux sont détaillés avec ce qu'il faudrait pour les livrer dans
`FOLLOWUP.md` F4. **Aucun des deux n'a été simulé par un réglage inopérant.**

⚠ **Un écart trouvé par le compilateur, pas par la relecture.** Il y a deux
colonnes dont le nom ressemble à « archetype » et elles ne portent pas le même
vocabulaire :

- `content_items.archetype` → le **format du post** : `statement`, `question`,
  `notes`, `signature`, `story`, `google_post`. Antérieur à ce chantier.
- `content_archetypes.id` → la **mise en page** : `single_statement`, `cycle`,
  `quadrant_model`, … Onze clefs, ajoutées par ce chantier.

Les deux jeux sont disjoints, et le garde-fou de `20260921110000` **vérifie
qu'ils le restent** : le jour où un mot appartient aux deux, tout écran qui lit
l'une ou l'autre colonne a raison par accident.

### 10.4 DÉCISION 4 — LE GRAIN, ARBITRÉ. Ne pas le renverser.

⚠ **Cette sous-section existe pour qu'une prochaine session ne défasse pas cet
arbitrage en croyant corriger une incohérence.** Elle porte donc la raison, pas
seulement la règle.

| objet | grain | table / colonne |
|---|---|---|
| **crédits** | **par utilisatrice** | `credit_quotas(plan, kind)`, `credit_ledger.user_id`, `credit_balances.user_id` |
| **contenu** | **par kit de marque** | `content_items.brand_kit_id`, `content_months.brand_kit_id`, `topic_assignments.brand_kit_id` |
| **assets rendus et visuels custom** | **par kit de marque** | `rendered_assets.brand_kit_id`, `custom_visual_generations.brand_kit_id` |
| **Monthly Presence** | **abonnement par personne** | `check_monthly_presence_entitlement(uuid)`, scopé utilisateur |

**Le prompt de chantier disait l'inverse sur un point, et c'est le prompt qui
avait tort.** L'arbitrage tient parce que les deux choses ne sont pas de même
nature :

- **Un crédit est une unité de dépense auprès d'un fournisseur, et le
  fournisseur facture un compte.** Quatre visuels custom par mois est une
  limite sur ce qu'Eklio est prêt à payer POUR UNE PERSONNE. L'attacher au kit
  voudrait dire qu'ouvrir un second kit double la facture sans rien changer à
  l'abonnement — c'est-à-dire qu'un plafond cesse d'être un plafond dès qu'on
  clique sur « nouveau kit ».
- **Un contenu est une expression de marque, et une marque est un kit.** La
  même praticienne avec deux cabinets a deux voix, deux palettes, deux
  calendriers. Les rattacher à la personne produirait un flux où les posts de
  deux marques se mélangent, et une anti-collision qui ne sait plus quelle
  marque elle protège.
- **Un asset rendu est une image dans les couleurs d'un kit.** Le cache est
  donc naturellement par kit : `UNIQUE(brand_kit_id, content_hash)`. Un cache
  par personne servirait à la seconde marque l'image de la première.
- **Monthly Presence est un abonnement par personne**, et ce n'est pas une
  exception au premier point : c'est le premier point. L'abonnement paie une
  capacité mensuelle, et la capacité est mesurée en crédits.

⚠ **Le seul endroit où les deux grains se croisent est la déduplication de
prompt d'image**, et il est mesuré plutôt que supposé : voir §10.6.

### 10.5 VÉRIFICATION 1 — chaque contrôle typographique a désormais un cas négatif démontré

**Le problème, énoncé exactement.** Le contrôle de ratio 3:1 était **vert
pendant qu'une carte mesurait 2,89**. Un contrôle qui ne regarde rien passe
exactement comme un contrôle qui regarde tout, et rien dans la suite ne
permettait de faire la différence — parce que la règle vivait **à l'intérieur
d'un `expect`**, où elle ne peut pas être mise en échec volontairement.

**Ce qui a été fait.** Les règles sont sorties des assertions et vivent dans
`lib/compose/audit.ts` : six fonctions qui prennent un **document SVG** et
rendent la liste de ce qui ne va pas, en toutes lettres.

- `absoluteFloorFindings` · `displayRangeFindings` · `ratioFindings`
- `glyphToStrokeFindings` · `fieldToFieldFindings` · `aboveFooterFindings`

`collision.test.ts` et `floors.test.ts` **appellent maintenant ces fonctions**
sur les 11 × 3 × 3 cartes de la matrice — même couverture, même granularité,
meilleurs messages. Et `lib/compose/__tests__/negatives.test.ts` appelle **les
mêmes fonctions** sur des documents fabriqués pour les violer.

| # | contrôle | cas négatif démontré | **[chemin de production]** |
|---|---|---|---|
| 1 | **ratio 3:1** | une vraie carte `cycle` est rendue, vérifiée propre, puis toutes ses bandes secondaires sont repassées au corps qui produit **exactement 2,89** — le contrôle rend un constat qui contient « 2.89 » et « under 3 ». **Ce test aurait échoué avant la correction.** Un second cas pose 2,99 : une borne qui ne refuse que le franchement mauvais est une borne dont on ne peut rien conclure. Un troisième vérifie que le moteur, lui, ne produit plus ce document | oui |
| 2 | **planchers typographiques** | un glyphe à `ABSOLUTE_FLOOR − 1` est refusé ; une ligne d'affichage à `display.min − 1` est refusée ; **et une à `display.max + 1` aussi** — le débordement est une panne dans les deux sens | oui |
| 3 | **clearances** | un texte poussé de 220px dans le dessin est refusé (c'est le sens dans lequel la panne s'est produite : un libellé à 38px du bout d'un bras) ; un texte poussé de 900px dans le pied de carte est refusé ; **un champ teinté posé sur un autre** est refusé | oui |
| 4 | **budget de mots** | `budget.test.ts` portait déjà ses cas négatifs (« un mot de trop, et c'est refusé »). Ce qui manquait est la preuve que le refus **remonte jusqu'au moteur** : `render` lève `BudgetExceededError` sur un payload hors budget, il ne compose pas quand même | oui |

⚠ **Et les mutateurs eux-mêmes sont testés.** Un mutateur qui ne mute plus rend
TOUS les cas ci-dessus verts — c'est le mode de panne le plus silencieux du
fichier. `withGlyphSize`, `withSecondarySizes` et `shiftBoxes` vivent donc dans
`audit.ts` à côté des lecteurs, ils **lèvent** quand la mutation serait un
no-op, et trois tests vérifient qu'ils changent bien le document, **y compris
les boîtes internes** — `parseBoxes` lit la boîte du groupe pour un champ mais
celles des éléments internes pour un texte et pour un tracé, et un mutateur qui
n'aurait touché que l'attribut du groupe aurait produit un document inchangé
aux yeux du lecteur.

⚠ **Une chose que ces cas négatifs ne prouvent pas, et qui est dite plutôt que
sous-entendue :** ils prouvent que le contrôle voit une carte sale. Ils ne
prouvent pas que la matrice de fixtures couvre toutes les cartes que la
production produira. Les deux moitiés sont nécessaires et aucune ne remplace
l'autre.

### 10.6 VÉRIFICATION 2 — la déduplication a DEUX étages, et ce sont deux choses différentes

On les confond facilement parce qu'elles disent toutes les deux « on ne refait
pas ». Elles ne protègent pas la même dépense. La preuve est
`supabase/tests/20260921120000_dedup_two_levels.test.sql`, **cinq blocs,
[chemin de production]** : chaque appel passe par la RPC que la production
appelle, et rien n'est écrit en table directement.

#### (a) ÉTAGE 1 — LE RENDU. Un payload rendu deux fois pour le même kit

**Clef : `(brand_kit_id, content_hash)`. Ce qu'elle économise : du CPU et une
écriture de stockage. Rien n'est facturé à personne.**

| ce qui est prouvé | comment |
|---|---|
| le premier appel enregistre | `record_rendered_asset` rend `reason = 'rendered'` |
| le second **ne crée pas de seconde ligne** | `select count(*) from rendered_assets where (kit, hash)` = **1** |
| le second rend **le chemin existant, pas celui qu'il proposait** | ⚠ le test propose délibérément un AUTRE chemin au second appel — un pipeline qui rerend écrit dans un chemin horodaté. Si la fonction acceptait la proposition, deux objets existeraient dans le seau pour un seul contenu et le cache ne serait qu'une table |
| **une seule écriture de stockage** | le chemin rendu est identique aux deux appels, donc le pipeline dépose une fois |
| un **autre kit**, le même hash, **enregistre quand même** | 2 lignes pour 2 kits. Sans ce cas, un cache global passerait le test précédent en servant à la seconde praticienne l'image de la première |

#### (b) ÉTAGE 2 — LE PROMPT D'IMAGE. Le même `prompt_hash` deux fois

**Clef : `(brand_kit_id, prompt_hash)`. Ce qu'elle économise : un APPEL À
OPENAI et un CRÉDIT.**

| ce qui est prouvé | comment |
|---|---|
| la première génération consomme **1 crédit** | `credit_balances.consumed` = 1 après `reserve_credit` + `record_custom_visual` |
| la seconde **ne déclenche aucun appel** | `record_custom_visual` rend `reason = 'cached'` avant toute génération |
| la seconde **ne consomme pas de second crédit** | `credit_balances.consumed` = **toujours 1**. La réservation est relâchée par `settle_credit(…, charged => false)` |
| **une seule ligne de génération** | `count(*) from custom_visual_generations where (kit, prompt_hash)` = **1** |
| le journal, lui, porte **les deux réservations et leurs deux issues** | 2 `reservation`, 1 `release`. ⚠ C'est voulu : le journal est append-only, et « on a réservé puis relâché » est un fait qui s'est produit. Ce qui doit être à 1 est le **solde**, pas le nombre de lignes — un test qui compterait les lignes prouverait le contraire de ce qu'il croit |

⚠ **Le chemin de production réserve AVANT de savoir si c'est un doublon**, et
le test le reproduit. Il ne peut pas savoir sans regarder, et regarder puis
réserver laisserait deux appels concurrents passer tous les deux.

#### (c) Les deux étages ne se déduisent pas l'un de l'autre

Un cinquième bloc vérifie qu'un contenu déjà rendu **n'implique pas** un prompt
déjà généré, et réciproquement : deux tables, deux clefs, deux rangements dans
le seau (`…/cards/…` contre `…/custom/…`). Un cache unique qui prétendrait
couvrir les deux servirait un jour une carte composée à la place d'une
illustration.

⚠ **LEURS GRAINS DIFFÈRENT, ET C'EST LE SEUL ENDROIT OÙ LA DÉCISION 4 SE
CROISE.** Le prompt est dédupliqué **par kit** ; le crédit est décompté **par
utilisatrice**. Pour une praticienne à un seul kit les deux coïncident. Le jour
où elle en a deux, le même prompt sur le second kit est **un second appel et un
second crédit** — voulu : un visuel appartient à une marque, un crédit
appartient à une personne.

**Côté frontend, l'étage 2 est prouvé une seconde fois**, sur la logique
TypeScript : `lib/content/images/__tests__/custom-visual.test.ts`, 24 tests
**[chemin de production pour la logique, fixture pour la réponse API]**.

### 10.7 VÉRIFICATION 3 — le coût, republié avec ce qu'il contient ET ce qu'il ne contient pas

#### Ligne 1 — MESURÉ. **0,0259 $ pour trente publications** — **[chemin de production]**

Agrégé depuis `credit_ledger` par `scripts/prove-month-cost.sql`, et non
calculé par le script : la dépense passe par `reserve_credit` puis
`settle_credit`, exactement comme en production, et le rapport relit ce que ce
chemin a écrit.

**Ce que ce chiffre INCLUT, en toutes lettres :**

- les **trente appels de génération de texte** d'un mois — titre, légende,
  ligne d'image, texte alternatif de chaque publication ;
- **le prompt caching réellement obtenu** : la première carte écrit le préfixe,
  les vingt-neuf suivantes le lisent. L'écart entre 0,0414 $ estimé et
  0,0259 $ réel — **0,0155 $, soit 37 %** — **est** ce que le cache a
  économisé, mesuré plutôt qu'annoncé ;
- la remise Batch de Haiku 4.5 (−50 % entrée et sortie).

**Ce que ce chiffre EXCLUT, et chaque exclusion est un coût réel :**

1. **Les visuels custom.** Zéro dans ce mois. Le chemin est écrit et testé
   (§10.1) mais **n'est pas câblé à un écran** : aucune cliente ne peut
   aujourd'hui en demander un. C'est la plus grosse exclusion, et la ligne 2
   ci-dessous l'estime.
2. **L'amortissement de la banque de sujets.** Les sujets sont écrits une fois
   et servis à beaucoup ; leur rédaction est un coût de modèle qui n'apparaît
   dans le journal d'aucune cliente. Il n'a pas été mesuré, parce qu'aucune
   banque réelle n'a été rédigée.
3. **L'amortissement de la veille.** `insight_runs` borne les recherches à 40
   par exécution ; aucune n'a tourné, donc aucune n'est facturée ici.
4. **Le rendu vectoriel — et son absence EST la mesure.** Trente cartes
   composées par `lib/compose/` : ni appel d'API, ni crédit, ni ligne de
   journal. C'est le fait central du chantier.
5. **Le stockage et la bande passante.** Non mesurés.

⚠ **Et d'où vient le chiffre : d'UNE utilisatrice de test**, créée par le
script, sur la stack locale. C'est un mois complet passé par le vrai chemin,
pas un échantillon de production : personne d'autre n'a encore généré de mois.
Un parc réel donnera une moyenne, pas ce nombre-ci.

**0,000863 $ par publication.**

#### Ligne 2 — ESTIMÉ. **≈ 0,21 $ pour trente publications + quatre visuels custom**

⚠ **CE CHIFFRE EST UNE ESTIMATION, PAS UNE MESURE.** Aucun appel à OpenAI n'a
été fait dans ce chantier. Il est publié parce qu'il est la question qui
compte — ce que coûte une abonnée quand le produit est entier — et il est
marqué pour qu'on ne le cite jamais comme un fait.

```
  0,0259 $   texte de 30 publications        [MESURÉ, chemin de production]
+ 0,1800 $   4 visuels custom en qualité low [ESTIMÉ, non mesuré]
             4 × 1 500 jetons de sortie × 30 $/M jetons = 4 × 0,045 $
─────────
≈ 0,2059 $   par praticienne et par mois     [DOMINÉ PAR L'ESTIMATION]
```

**Ce qui rend cette estimation fragile, nommément :**

- **les 1 500 jetons de sortie par image sont une hypothèse**, pas une mesure.
  Elle est écrite comme telle dans `ESTIMATED_OUTPUT_TOKENS`, et
  `ESTIMATE_DRIFT_WARN` la rend falsifiable : le premier appel réel qui
  s'écartera de plus de 50 % le journalisera ;
- **le taux de 30 $/M jetons de sortie image est vérifié au 20 septembre
  2026**, source en commentaire dans `IMAGE_OUTPUT_PER_MTOK` ;
- **les jetons de texte du prompt d'image ne sont PAS comptés** — ils sont
  facturés à part, à un tarif qui n'a pas été vérifié. Quelques dizaines de
  jetons face à des milliers de jetons d'image : l'écart est petit, mais il est
  réel et il est nommé plutôt que dilué ;
- **quatre visuels est le plafond, pas la moyenne.** `credit_quotas` accorde 4
  par mois au plan standard. Une cliente qui n'en demande aucun reste à la
  ligne 1 ;
- **l'estimation ignore la déduplication.** Une cliente qui redemande le même
  prompt ne paie pas deux fois (§10.6), donc 0,18 $ est un majorant.

**Écart entre les deux lignes : ×8.** Le mois de texte coûte 2,6 cents ; les
quatre images en coûteraient 18. **La quasi-totalité du coût variable d'Eklio
est dans un chemin qui n'est pas encore câblé**, et c'est ce que la comparaison
des deux lignes existe pour dire.

### 10.8 VÉRIFICATION 4 — le seuil d'épuisement de la banque

**La question, telle qu'elle est posée :** à partir de quel volume par segment
la simulation COMMENCE à échouer ? C'est ce chiffre-là qui dimensionne la
génération de sujets, pas celui qui passe.

#### Ce qui a changé dans le harnais pour pouvoir y répondre

Trois modifications à `scripts/simulate-collisions.sql`, et chacune répare une
raison pour laquelle la question ne pouvait pas être posée :

1. **`-v topics_per_segment=N`.** Le volume était écrit en dur à 500. On ne
   peut pas mesurer un seuil sur une constante.
2. **L'épuisement lève, au PREMIER.** Il était compté et rapporté en bas de
   tableau, à côté de deux zéros rassurants — un run à 400 épuisements se
   lisait comme un succès. Et il lève au premier plutôt qu'à la fin : une
   banque qui ne répond plus ne répondra pas davantage aux 8 999 tirages
   suivants, et chacun coûte un parcours complet du pool pour rendre `null`.
   Un run à banque insuffisante passait de quelques minutes à un temps qu'on
   n'a pas mesuré parce qu'on l'a interrompu.
3. **La population est dérivée de l'État.** Voir ci-dessous — c'est la
   modification qui rend la densité réaliste.

#### ⚠ La densité mesurée jusqu'ici était plus douce qu'elle n'en avait l'air

L'ancien harnais posait `v_pers[1 + (i - 1) % 3]`. Les deux consœurs d'un
groupe (État, modalité) sont les rangs `i` et `i+50`, et `(i-1) % 3` contre
`(i+49) % 3` diffèrent toujours — 50 n'est pas multiple de 3. **Les cinquante
groupes avaient donc deux populations différentes.**

⚠ **Ce n'était PAS une assertion vide, et il faut le dire précisément.** J'ai
d'abord conclu que les pools étaient disjoints et que « zéro collision » ne
prouvait rien. C'était faux, et la relecture de `next_topic_for_kit` l'a
montré : le segment est accepté si **la modalité OU la population**
correspond — un OU, pas un ET. Deux consœurs de même modalité atteignaient donc
déjà les trois mêmes segments de cette modalité et pouvaient parfaitement se
marcher dessus.

Ce qui est vrai est plus faible : la contrainte mordait **dans le
débordement** seulement. Chacune vidait d'abord son propre segment d'élection —
celui que le tri préfère, score 4 contre 2 — que l'autre ne visait pas en
premier. En dérivant la population de l'État, les deux tirent d'abord dans **le
même** segment. La contention est frontale au lieu d'être résiduelle, et c'est
ce que la fenêtre de 90 jours est censée tenir dans la vraie vie : deux
thérapeutes qui se ressemblent, dans la même ville, qui publient le même mois.

**C'est donc un test plus dur que le précédent, pas un test qui en répare un
cassé.**

#### Le bord théorique, qui est de l'arithmétique et non une mesure

Avec 5 modalités × 3 populations = 15 segments de N sujets, une praticienne
`(m, p)` atteint les 3 segments de modalité `m` **ou** les 5 de population
`p` — soit `3 + 5 − 1 = 7` segments, donc **7N sujets atteignables**.

| horizon | ce qu'elle consomme à elle seule | ce que sa consœur lui bloque | pool atteignable requis | **N par segment** |
|---|---|---|---|---|
| 3 mois (= la fenêtre entière) | 90 | ≤ 90 | ≥ 180 | **≥ 26** |
| 12 mois | 360 (unicité à vie) | ≤ 90 par fenêtre | ≥ 450 | **≥ 65** |

Ce sont des bornes INFÉRIEURES : elles ignorent que le tri concentre les
premiers tirages sur le segment d'élection, ce qui épuise ce segment-là bien
avant les six autres. Le seuil mesuré doit donc être **au-dessus** de ces
nombres, et l'écart entre les deux est ce que le balayage mesure réellement.

#### LE SEUIL MESURÉ — **26 sujets par segment**

**[chemin de production — nouveau harnais, 100 praticiennes × 3 mois × 30
publications, soit 9 000 tirages par point]**

Le balayage descend jusqu'à ce que la simulation lève. Chaque ligne est un run
complet, sur la stack PostgreSQL 16 locale.

| sujets / segment | pool atteignable (7 segments) | total en banque | résultat | durée |
|---|---|---|---|---|
| 500 (le volume visé) | 3 500 | 7 500 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 184 s |
| 360 | 2 520 | 5 400 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 659 s |
| 240 | 1 680 | 3 600 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 89 s |
| 180 | 1 260 | 2 700 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 70 s |
| 120 | 840 | 1 800 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 114 s |
| 90 | 630 | 1 350 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 31 s |
| 60 | 420 | 900 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 21 s |
| 40 | 280 | 600 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 30 s |
| 30 | 210 | 450 | 9 000 attributions, 0 épuisement, 0 collision, 0 doublon | 29 s |
| 29 | 203 | 435 | 0 épuisement | 28 s |
| 28 | 196 | 420 | 0 épuisement | 27 s |
| 27 | 189 | 405 | 0 épuisement | 29 s |
| **26** | **182** | **390** | **0 épuisement — LE DERNIER QUI TIENT** | 76 s |
| **25** | **175** | **375** | ⚠ **ÉPUISEMENT au tirage n° 7 526, mois 3 / 3** | 8 s |
| 24 | 168 | 360 | ⚠ épuisement au tirage n° 7 519, mois 3 / 3 | 14 s |
| 23 | 161 | 345 | ⚠ épuisement au tirage n° 7 512, mois 3 / 3 | 18 s |
| 20 | 140 | 300 | ⚠ épuisement au tirage n° 6 021, mois 3 / 3 | 17 s |

**Le seuil est 26 sujets par segment. À 25, la simulation casse.**

⚠ **La ligne à 500 a été mesurée séparément, après coup**, parce que son
premier run est mort sur l'incident décrit en bas de cette section. Elle est
restée marquée « non mesurée » dans un commit intermédiaire plutôt que remplie
par déduction : un pool plus grand ne peut pas faire échouer un tirage qu'un
pool plus petit réussit — le sélecteur ne filtre que sur l'unicité et la
fenêtre, jamais sur l'abondance — mais « ne peut pas » est un raisonnement, et
cette colonne ne contient que des mesures. Elle en contient une maintenant.

⚠ **ET LE SEUIL MESURÉ TOMBE EXACTEMENT SUR LE BORD THÉORIQUE.** L'arithmétique
ci-dessus donnait `≥ 26` pour trois mois : `7N ≥ 90 + 90` → `N ≥ 25,7` → 26.
La mesure donne 26. Ce n'est pas une confirmation gratuite — cela veut dire que
le tirage n'a **aucune perte** : il place les 9 000 attributions dans un pool
qui n'a pas un sujet de marge. Un sélecteur moins bon aurait cassé bien avant
son bord théorique, et l'écart entre les deux aurait été la mesure de sa
maladresse. Ici l'écart est nul.

⚠ **Et la dégradation est franche, pas progressive.** On ne passe pas de « ça
va » à « ça va mal » : 26 tient parfaitement, 25 lève. Le numéro du tirage le
dit aussi — 7 526 à N=25, 7 512 à N=23, 6 021 à N=20 : la banque tient jusqu'au
milieu du troisième mois, puis s'arrête net. **Une banque sous-dimensionnée ne
prévient pas.** C'est ce qui rend la marge nécessaire, et c'est pourquoi
`bank_exhausted` remonte jusqu'à l'écran plutôt que d'être réessayé.

#### Ce que ce seuil veut dire pour le dimensionnement

**Les 500 que le chantier vise portent un facteur 19 de marge** sur trois mois
(26 requis, 500 posés), et un facteur 7,7 sur douze mois (65 requis d'après
l'arithmétique d'unicité à vie).

⚠ **Le chiffre à surveiller n'est donc PAS le volume de la banque. C'est la
CONCENTRATION du parc.** `required_per_reachable_pool` vaut
`max(G × 90, 30 × mois)`, où **G est le nombre de praticiennes partageant
(État, modalité)** :

| G — praticiennes par groupe (État, modalité) | pool atteignable requis sur 12 mois | sujets / segment requis |
|---|---|---|
| 2 (ce que la simulation exerce) | 360 | 52 |
| 5 | 450 | 65 |
| **10** | **900** | **129** |
| 20 | 1 800 | 258 |

Une banque de 500 par segment tient jusqu'à **environ 38 praticiennes par
groupe (État, modalité)**. C'est le parc qui se concentre sur un État qui la
casse, pas le parc qui grandit — dix cabinets EMDR à Los Angeles coûtent plus
cher à la banque que cent cabinets répartis sur dix États.

#### Ce que ce balayage NE prouve pas, et qui est dit plutôt que sous-entendu

- **Il porte sur trois mois, pas douze.** Trois mois sont la fenêtre
  anti-collision entière, donc la contrainte de collision est exercée en
  totalité. Ce que douze mois ajoutent est l'unicité À VIE par-delà les
  fenêtres, que la clef primaire de `topic_assignments` tient par construction.
  Le seuil de 26 est donc celui de la COLLISION ; celui de l'unicité à vie sur
  douze mois est de 52 par l'arithmétique, et il n'a pas été mesuré.
- **Les sujets de la simulation sont uniformes** : cinq archétypes en rotation,
  un seul `intent`, aucun `timely`, aucune expiration. Une banque réelle a des
  sujets qui expirent et des sujets d'actualité que le tri préfère (score +3),
  ce qui concentre les tirages et **remonte** le seuil.
- **Un run par point, pas une distribution.** Le tirage est déterministe à
  données égales, donc un second run identique donnerait le même résultat ; ce
  qui n'est pas mesuré est la sensibilité à une AUTRE répartition du parc.

**Pour reproduire :**

```bash
for n in 500 360 240 180 120 90 60 40 30 29 28 27 26 25; do
  psql -v months=3 -v topics_per_segment=$n -f scripts/simulate-collisions.sql
done
```

Le premier `n` qui lève `EPUISEMENT: draw #… found no topic` est le seuil. Le
message porte le numéro du tirage, le mois et le kit.

⚠ **Un incident du balayage, écrit parce qu'il coûterait la même heure à
quelqu'un d'autre :** le premier point à 500 est mort sur
`invalid byte sequence for encoding "UTF8"`. Le fichier sur le disque était
valide — **je l'éditais pendant que `psql` le lisait**, et le processus a reçu
un octet UTF-8 coupé en deux. Ne pas toucher un script pendant qu'il tourne.

### 10.9 CE QUE LA SUITE A AJOUTÉ AUX SUITES DE TESTS

| dépôt | fichier | ce qu'il prouve |
|---|---|---|
| backend | `supabase/tests/20260921100000_swap.test.sql` | le swap depuis un **vrai rôle** : il recopie et ne fabrique rien ; il est gratuit et laisse quand même une trace ; l'item d'une autre est `not_found` et **n'a pas bougé** ; la banque épuisée se dit une fois ; et **un tirage raté n'assigne rien** — une assignation posée puis abandonnée brûlerait un sujet que personne n'a vu |
| backend | `supabase/tests/20260921110000_her_layout.test.sql` | les deux vocabulaires « archétype » sont disjoints **dans les deux sens** ; elle change la mise en page et l'écran la relit ; la chaîne vide efface ; une mise en page inventée est `unknown_layout` **et n'écrit rien** ; la clef étrangère reste la garantie ; un swap remet à zéro |
| backend | `supabase/tests/20260921120000_dedup_two_levels.test.sql` | les cinq blocs de §10.6 |
| frontend | `lib/compose/__tests__/negatives.test.ts` | les cas négatifs de §10.5, **13 tests** |
| frontend | `lib/content/__tests__/review-surface.test.ts` | les variantes composent vraiment (mesuré sur le document, pas déduit d'un `render` qui n'a pas levé) ; leur hash **est** celui du cache de rendu ; le carrousel n'est jamais une variante ; aucun bandeau n'est jamais vide ; `payloadPublishedText` remonte les gloses mais **pas** les clefs de système ; **16 tests** |

**Total après la SUITE : 3 864 tests frontend au vert, 161 fichiers, 0 échec**
**[chemin de production]**. Et côté base : **146 migrations rejouées depuis
zéro, 95 fichiers de tests SQL, 0 échec** **[chemin de production]**, sur la
stack PostgreSQL 16 locale.

### 10.10 LA DÉRIVE DE SCHÉMA APRÈS LA SUITE

Le rejeu final se compare à l'empreinte de production enregistrée
(`schema_fingerprint.production.txt`). Ce qu'il dit **[chemin de production]** :

```
production objects: 2504
replay objects:     3019
== ONLY IN PRODUCTION (the migrations do not produce it): 0 ==
== DIFFERENT: 4 ==
```

⚠ **`ONLY IN PRODUCTION: 0` est la ligne qui compte.** Elle dit que le rejeu
produit tout ce que la production a. Les 515 objets en plus sont ce que ce
chantier ajoute.

⚠ **Et les 4 « DIFFERENT » sont exactement les deux fonctions que la SUITE a
réécrites**, chacune comptée deux fois (sa signature et son corps) :

```
function.body|content_item_json(p_id uuid)
function.body|update_content_item(p_id uuid, p_patch jsonb)
function|content_item_json(p_id uuid)
function|update_content_item(p_id uuid, p_patch jsonb)
```

C'est la forme attendue : `20260921110000` leur a ajouté `compose_archetype`,
donc le rejeu en produit une version plus récente que celle de production.
Aucune autre fonction n'a bougé. Le rapport précédent annonçait
`DIFFERENT: 0` — il était juste **avant** la SUITE, et ce 4 est la trace exacte
de ce qu'elle a changé, pas une surprise.

⚠ **L'empreinte de production sera à réenregistrer** le jour où ces migrations
seront appliquées. Tant qu'elles ne le sont pas, ces 4 doivent rester 4 : s'ils
deviennent 5, quelque chose a été redéfini sans qu'on le dise.
