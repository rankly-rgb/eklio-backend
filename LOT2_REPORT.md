# LOT2_REPORT.md — ce qui a été produit, et ce qui ne l'a pas été

Lot 2, 14 septembre 2026. Branche `claude/foundation-lot2`, dans les deux dépôts.

---

# ⚠ PHASE A : ELLE N'A PAS PU TOURNER

**Aucune Foundation n'a été produite. Aucun appel de modèle n'a eu lieu. Rien n'a été simulé.**

Le lot 2 partait d'une phrase : *« The Foundation est déclarée produisible. Elle n'a jamais été
produite. »* **Elle est toujours vraie ce soir**, et ce rapport ne prétend pas le contraire.

## Ce qui a été constaté, et comment

Pas déduit de l'absence d'une variable d'environnement — **exécuté**. Un appel réel, à travers le
client du produit lui-même (`lib/generation/…`, le même chemin qu'une génération de cliente), dans
un script jetable supprimé après usage :

```
GENERATION_MODEL:            claude-opus-5
ANTHROPIC_API_KEY present:   false
ANTHROPIC_BASE_URL present:  true
CALL FAILED: AnthropicNotConfiguredError | ANTHROPIC_API_KEY is not set.
```

C'est la garde du produit lui-même qui refuse. Le diagnostic ne repose sur aucune lecture de
configuration : il repose sur un refus observé.

## Ce que je n'ai pas fait, et pourquoi ça compte

`ANTHROPIC_BASE_URL` est renseignée dans cet environnement, et ce harnais dispose d'un accès
modèle pour son propre compte. **Il n'a pas été détourné pour fabriquer une Foundation.** Trois
briefs passés à travers un accès de session, présentés comme une sortie du produit, auraient donné
un rapport avec des extraits, des verdicts, et quatre lignes de mesures — toutes fausses, parce que
le chemin mesuré n'aurait pas été celui d'une cliente.

Le cahier le disait : *« Sans clé Anthropic, tu ne simules rien. »* C'est tenu, à la lettre.

## Les quatre mesures attendues, et leur état

| Ce que la phase A devait mesurer | État |
|---|---|
| Le critère d'acceptation de L8, mot pour mot : « sur trois briefs d'essai, la sortie nomme un problème tel qu'un patient le décrirait » | **NON MESURÉ** |
| Les gardes se déclenchent-elles sur du texte de modèle, ou seulement sur les cas construits ? Une modalité **paraphrasée** passe-t-elle ? | **NON MESURÉ** |
| L'Ethics Guard attrape-t-il quelque chose sur une sortie réelle, ou n'a-t-il jamais vu que ses propres exemples ? | **NON MESURÉ** |
| Le profil Psychology Today tient-il sur un brief réellement **incomplet** ? | **NON MESURÉ** |

Les trois briefs — thérapeute couples/LGBTQ+, spécialiste du trauma en paiement direct,
généraliste quittant un panel d'assurance — n'ont pas été écrits, puisqu'il n'y avait rien à leur
faire traverser.

⚠ **Ce n'est pas « les sorties ne sont pas bonnes ».** Ce résultat-là aurait été recevable et
aurait arrêté la phase C de la même façon. Celui-ci est différent et il faut le nommer : **on ne
sait toujours rien.** Les gardes écrites au lot 1 — le registre d'USP, le scan déontologique, les
validateurs de profil — n'ont jamais vu que du texte écrit par moi, pour les tester.

## Ce que la phase A étant bloquée entraîne

**LA PHASE C N'A PAS ÉTÉ CONSTRUITE.** Pas de `site_connections`, pas de client WordPress, pas de
`POST /wp-json/wp/v2/pages`, aucun secret par cliente, aucune variable d'environnement déclarée
pour eux.

> *« Construire la publication d'un contenu qu'on n'a jamais vu sortir serait exactement l'erreur
> que ce lot existe pour éviter. »*

C'est la règle du cahier, et c'est aussi la bonne décision indépendamment : `site_connections`
serait **le premier secret par cliente de ce produit**. Sa forme mérite d'être décidée à froid.

**Ce qu'il faut pour lever ce blocage : une clé, et une demi-journée.** Rien d'autre.

---
---

# PHASE B — faite en entier

Indépendante de la phase A, et livrée : trois sous-lots, trois commits par côté concerné, suite
complète verte après chacun.

## B1 — Squarespace : tranché

**Réponse : `refused`.** L'enquête complète est dans **`SQUARESPACE_VERDICT.md`** : la question
telle qu'elle était posée, les sources avec leurs URL et leur date, ce qui n'a pas pu être atteint,
et ce qui renverserait le verdict.

En bref : toute la surface d'API documentée par Squarespace est sous un seul segment,
`commerce-apis` ; les quatre permissions qu'une clé peut porter sont Orders, Forms, Inventory,
Transactions ; les douze paquets npm publiés par Squarespace sont de l'outillage de **gabarits**,
sans client d'API ni point d'entrée d'écriture. La question excluait les API commerce — le
périmètre écarté est le périmètre entier.

⚠ **Le degré du verdict, dit franchement.** La documentation développeur n'a **pas pu être lue** :
cet environnement bloque le domaine `squarespace.com` entier au niveau du tunnel CONNECT —
`developers.squarespace.com`, `support.`, `forum.`, `developers-preview.` et **`api.squarespace.com`
lui-même**, tous en `403` sur le CONNECT. Même un appel d'essai non authentifié, qui aurait répondu
`401` sur un chemin existant et `404` sur un chemin absent, était hors de portée. Le verdict est
**établi par convergence de cinq sources indépendantes, pas attesté à la source.**

**Pourquoi trancher quand même plutôt que laisser `conditional`** : le `notice` en place disait à
la cliente *« we are still confirming »*. Nous avons vérifié. Continuer à l'afficher serait
désormais faux. Et les deux erreurs ne coûtent pas la même chose — refuser à tort renvoie une
cliente qu'on aurait pu servir, **et `platform_refusal_counts()` la compte**, donc l'erreur se voit
et se chiffre ; accepter à tort encaisse un paiement pour une publication impossible.

**Ce qui a bougé** : une ligne. `site_platforms.squarespace.status` → `refused`, avec un `notice`
qui dit pourquoi. Appliqué au projet vivant puis revérifié contre lui. **Rien n'est supprimé** : la
ligne reste au catalogue, refusée et expliquée, comme Wix et Webflow. **Rien n'est implémenté**,
comme le cahier l'exigeait dans les deux sens.

**Conséquence** : L16 tombe à zéro.

## B2 — la vente des SKU non livrables est techniquement refusée

`DECISIONS_NEEDED.md` §4 et §7, écrits au lot 1, disaient la même chose et finissaient tous les
deux mal :

> « Il ne faut pas le mettre en vente avant L21. **Rien dans le code ne l'empêche aujourd'hui** —
> c'est une décision de mise en vente, pas une garde technique. »

**`plans.sellable`**, `false` sur `roster_seat`, `fill_solo`, `fill_practice`. Le commentaire de
colonne nomme le lot qui rouvre chacune : **L21** pour le siège, **L18** pour The Fill solo,
**L18 et L20** pour The Fill cabinet.

**Lu par le chemin de checkout, pas par l'affichage** : `createCheckoutSession` l'interroge avant
le projet, avant le customer Stripe, avant la session.

⚠ **Cette garde échoue FERMÉ, à l'inverse de sa voisine.** Dix lignes plus bas, `alreadyPaidFor`
rend `null` quand sa lecture échoue, avec une raison écrite au lot précédent. Les deux coexistent
parce que les questions ne sont pas de même nature : *« cette cliente-ci a-t-elle déjà payé ce
projet-là »* change d'une minute à l'autre et exige une lecture vivante ; *« cette ligne est-elle
en vente »* est un fait de catalogue, le même pour tout le monde. Une absence de réponse sur un
fait quasi statique n'ouvre pas une caisse. Un SKU **absent** du catalogue est refusé lui aussi,
sans quoi la garde ne garderait que les noms qu'on a pensé à écrire.

⚠ **Ce n'est pas un CHECK sur `purchases`.** Cette table est écrite par le webhook, **après** que
l'argent a bougé : un refus à cet endroit ne refuserait pas la vente, il refuserait la **trace** de
la vente. On encaisserait 120 $ sans plus rien qui dise pour quoi. C'est le raisonnement que
`lib/stripe/checkout.ts` avait déjà écrit à propos du double paiement, et il vaut ici aussi.

**Le test tente l'achat** (`lib/stripe/__tests__/unsellable.test.ts`) : il appelle réellement
`createCheckoutSession` avec chacun des trois SKU et exige un refus — et surtout que **rien
n'atteigne Stripe**, le mock levant si `sessions.create` ou `customers.create` est appelé. Un test
qui n'attendrait qu'une exception passerait aussi si la session Stripe avait été créée d'abord,
c'est-à-dire après que la cliente a vu une page de paiement. Une **garde anti-zèle** vérifie que
`foundation`, `roster` et `identity_addon` passent : une garde qui refuse tout serait verte sur le
reste du fichier et coûterait le chiffre d'affaires entier.

## B3 — les deux Ethics Guard se comptent, sans fusionner

⚠ **Rien n'a été fusionné**, et ce lot ne prépare pas la fusion : elle reste le lot décrit dans
`OUT_OF_SCOPE.md` §17. Les motifs restent écrits deux fois, en deux dialectes d'expression
régulière. **Ce qui est désormais partagé est le NOM d'un motif, pas le motif.**

Le corpus partagé du lot 1 tient les deux côtés sur le **comportement** : mêmes phrases bloquées,
mêmes reformulations laissées passer. Il ne voit pas un motif **ajouté d'un seul côté** — et ce
motif attrape du texte que l'autre laisse passer, donc le produit se comporte différemment selon
que le texte vient de l'application ou d'une RPC. Aucun test de phrase ne le remarque tant que
personne n'écrit la phrase.

`FORBIDDEN_PATTERNS` n'avait pas d'identifiant par motif — seulement un `ruleId` partagé par
plusieurs. Les dix-neuf `id` posés reprennent à l'identique ceux de `ethics_patterns`. Ils ne
servent à rien d'autre : `checkEthics` ne les lit pas, ils ne remontent dans aucune violation,
personne ne les voit. **Ils existent pour être comptés.**

Deux tests jumeaux, chacun écrivant la liste attendue **en toutes lettres** — une liste qui se lit
elle-même ne contrôle rien, et le fichier à contrôler est dans l'autre dépôt. Même forme
qu'`entitling_statuses_single_source` au lot 1.

---
---

# Ce que j'ai cassé en l'écrivant, et qui l'a attrapé

Trois défauts, **tous les trois de mon fait**, tous trouvés en **exécutant** plutôt qu'en relisant.

### 1. `%L` n'existe pas dans `raise`

Le message d'erreur du test de parité disait *« Le motif **guaranteeL** fait respecter
**diagnosisL** »*. `raise` ne connaît que `%` : un `%L` y consomme l'argument et laisse un « L »
collé à la valeur. Seul `format()` interprète `%L`.

C'est exactement la famille que le lot 1 avait nommée — **une valeur qui sort abîmée sans que rien
ne lève**. Un test dont le message est faux reste vert et ment le jour où il devient rouge.

**Trouvé par un sondage**, pas par une relecture : j'ai inséré un 20ᵉ motif en base et regardé ce
que le test disait.

### 2. Un contrôle qui ne pouvait pas échouer

Le premier jet du test de parité cherchait un `rule_id` absent de `ethics_rules` — « un refus
déclenché sans règle à montrer à la praticienne ». Le sondage a rendu *« violates foreign key
constraint `ethics_patterns_rule_fkey` »* : **la contrainte existait déjà**, et cette boucle ne
pouvait donc jamais lever.

Un contrôle qui ne peut pas échouer occupe la place d'un contrôle. Réécrit pour vérifier **la clé
étrangère elle-même**, puis sondé en la retirant.

### 3. Un faux client de test trop strict

Le premier `fakeSupabase` de `unsellable.test.ts` levait sur toute table autre que `plans`, pour
prouver que `plans` était lue en premier. Résultat : les trois cas **positifs** — vérifier que la
garde laisse passer ce qui se vend — échouaient sans que la garde soit en cause. Remplacé par un
faux client qui **enregistre l'ordre des lectures**, ce qui prouve la même chose sans casser le
chemin.

## Les sondages, un par contrôle

Aucun de ces tests n'a été déclaré bon parce qu'il était vert. Chacun a été rendu **rouge
exprès** :

| Sondage | Résultat |
|---|---|
| Un 20ᵉ motif en base seulement | rouge — « ethics_patterns porte 20 motifs, FORBIDDEN_PATTERNS en porte 19 » |
| Un identifiant renommé (`guarantee` → `guarantees`) | rouge — « les identifiants divergent », des deux côtés |
| Un `rule_id` divergent | rouge, avec le nom du motif et les deux règles |
| La clé étrangère `ethics_patterns_rule_fkey` retirée | rouge |
| Les deux recensements vidés ensemble | rouge — la garde anti-vacuité tient |
| Un motif retiré côté TypeScript (19 → 18) | rouge |
| L'achat des trois SKU invendables | refusé, et **Stripe jamais appelé** |
| Un SKU absent du catalogue | refusé |
| La lecture de `plans` en échec | refusé |

---

# La discipline du cahier, point par point

| Exigence | Tenue |
|---|---|
| Branche `claude/foundation-lot2` depuis `claude/foundation-lot1` | oui, dans les deux dépôts |
| Un commit par phase et par sous-lot | oui — 3 côté backend, 2 côté frontend (B1 n'a pas de moitié frontend) |
| Suite complète après chaque lot | oui — **83 fichiers SQL / 0 rouge**, **134 fichiers TS / 2642 tests / 0 rouge** |
| Jamais avancer sur un rouge de mon fait | oui — les trois défauts ci-dessus ont été corrigés avant le commit qui les portait |
| Chaque migration appliquée au projet vivant puis revérifiée **contre lui** | oui, les deux : `site_platforms` relu ligne par ligne, `plans.sellable` relu sur les dix lignes |
| Ne jamais s'arrêter pour demander | oui — quatre entrées nouvelles dans `DECISIONS_NEEDED.md`, aucune question posée |
| Aucune suppression en base | oui — un `update` et un `add column`. Aucune table, colonne, ligne ni policy retirée |
| Aucun refactor d'opportunité | oui |
| Aucune dépendance nouvelle | oui — `package.json` inchangé |

## Les leçons du lot 1, restées actives

- **Une sonde tente l'écriture, elle ne relit pas la définition.** Les neuf sondages ci-dessus ont
  tous modifié un état réel et regardé ce qui cassait.
- **Une valeur qui disparaît sans erreur est le défaut de la maison.** Deux occurrences neuves
  cette fois : `%L` dans un `raise`, et un `update` qui ne touche aucune ligne — d'où
  l'auto-contrôle dans la migration `sellable`, qui compte son propre effet.
- **Pas de quatrième liste.** Les listes recopiées dans les tests de parité ne sont lues par
  personne à l'exécution : ce sont des **contrôles**, pas des autorités. L'autorité reste
  `ethics_patterns` en base et `FORBIDDEN_PATTERNS` dans le code.
- **La surface de fonctions reste énumérée.** Aucune fonction ajoutée ce lot-ci — rien à y
  inscrire, et le test est resté vert.

---

# Une dérive trouvée et fermée

`types/supabase.ts`, régénéré au lot 1, **précédait ses propres migrations L9, L10 et L13** :
`directory_profiles`, `site_pages`, `ethics_patterns` et leurs cinq fonctions n'y figuraient pas.
Régénéré depuis le projet vivant : **124 lignes ajoutées, zéro retirée**, en-tête et addendum
manuel réappliqués.

Rien ne cassait — parce que rien n'appelait encore ces surfaces depuis le TypeScript. C'est
précisément pourquoi ça pouvait durer. ⚠ **Régénérer les types au BOUT d'un lot, pas au milieu.**

---

# Ce qui attend une décision

Quatre entrées neuves dans `DECISIONS_NEEDED.md` (§9 à §12). Une seule bloque :

**§9 — on n'a jamais vu sortir une Foundation.** Une clé, une demi-journée, et les quatre mesures
de la phase A deviennent possibles. Tant qu'elle n'est pas levée, la phase C ne doit pas être
construite, et tout lot qui bâtit par-dessus la génération bâtit sur du non-mesuré.

Les trois autres — la page « équipe » qui n'existe pas dans le vocabulaire, le prompt Squarespace
que le brief propose encore, la forme du premier secret par cliente — attendent sans rien bloquer.

---

# Les livrables

| Fichier | État |
|---|---|
| `LOT2_REPORT.md` | ce fichier |
| `SQUARESPACE_VERDICT.md` | neuf — sources, dates, ce qui est bloqué, ce qui renverserait le verdict |
| `OUT_OF_SCOPE.md` | **complété** — entrées 23 à 26, et une suite donnée à §17 et §18 |
| `DECISIONS_NEEDED.md` | **complété** — §1 à §7 reprises et marquées, §9 à §12 ajoutées, rien effacé |
| `ENV_REQUIRED.md` | **complété** — ce que `sellable` change, et pourquoi aucune variable de phase C n'est déclarée |
| Les trois Foundations en texte brut | **absentes, et c'est le résultat du lot** — voir la phase A |
