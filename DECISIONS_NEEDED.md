# DECISIONS_NEEDED.md — ce qui a bloqué, et les options

Écrit pendant le lot 1 d'implémentation de l'offre du 13 septembre.
**Repris au lot 2** : les entrées traitées portent ✅ et disent ce qui les a tranchées ; les
nouvelles sont en fin de fichier. **Rien n'a été effacé** — une décision prise se lit mieux à
côté de la question qui l'a posée.

**Aucun lot n'a été sauté.** Les dix ont été livrés. Ce qui suit est ce sur quoi j'ai dû choisir
sans pouvoir demander : j'ai pris l'option la moins coûteuse à défaire, je l'ai écrite dans le
code, et je la pose ici pour qu'elle soit confirmée ou renversée.

Chaque entrée dit **ce qui est en place aujourd'hui**, pour qu'un « non » soit un changement
mesurable et pas une reprise à zéro.

---

## 1. ✅ TRANCHÉE AU LOT 2 — Squarespace ne publie pas de pages

**Réponse : `refused`.** L'enquête entière, avec ses sources, leurs dates, ce qui n'a pas pu être
atteint et ce qui renverserait le verdict, est dans **`SQUARESPACE_VERDICT.md`**.

En un paragraphe : toute la surface d'API documentée par Squarespace est rangée sous un seul
segment, `commerce-apis`, et les quatre permissions qu'une clé peut porter sont Orders, Forms,
Inventory, Transactions. Les douze paquets npm que Squarespace publie sont de l'outillage de
gabarits, sans client d'API. La question excluait les API commerce ; le périmètre écarté est le
périmètre entier.

⚠ **Le degré du verdict, reporté ici tel quel :** la documentation développeur elle-même n'a pas
pu être lue — cet environnement bloque le domaine `squarespace.com` entier au niveau du tunnel
CONNECT. Le verdict est établi par **convergence de cinq sources**, dont deux émanent de
Squarespace, **pas attesté à la source**. Une demi-journée sur un poste ordinaire le confirme ou
le renverse, et le renverser coûte **un UPDATE sur une ligne** — c'est ce pour quoi
`site_platforms` a trois états.

**Conséquence** : L16 (client Squarespace) tombe à zéro. La qualification ne dit plus « WordPress
ou Squarespace », elle dit WordPress.

<details><summary>La question telle qu'elle était posée au lot 1</summary>

### ⚠ Squarespace — la seule qui peut rendre un point de l'offre irréalisable

**Lot concerné** : L5, et à terme L16.
**Ce qui est en place** : `site_platforms.squarespace.status = 'conditional'`. L'inscription est
prise, et la cliente lit avant de payer : *« We are still confirming what we can publish to
Squarespace on your behalf. »*

**Pourquoi je n'ai pas tranché** : le cahier dit « tu ne l'implémentes pas, tu ne le refuses pas :
tu le rends configurable ». C'est fait. Mais la réponse est due.

**Les options, et ce que chacune coûte** :

| | |
|---|---|
| **Squarespace publie des pages par API** | `status = 'accepted'`, un UPDATE. L16 coûte ~6 jours. |
| **Il ne le fait pas** | `status = 'refused'` + un `notice` qui le dit, un UPDATE. L16 tombe à zéro, et la qualification ne dit plus « WordPress ou Squarespace » mais « WordPress, ou une plateforme métier vérifiée ». |
| **On ne veut pas trancher maintenant** | rien à faire. `conditional` est un état vrai, pas un provisoire honteux. Mais chaque inscription prise sous ce statut est une promesse à tenir ou à retirer. |

**Pour trancher** : une demi-journée sur la documentation développeur en vigueur et un compte
d'essai. `platform_refusal_counts()` dira au passage combien de clientes on refuse, et pour quelle
plateforme — c'est le chiffre qui décide si écrire un client vaut la peine.

</details>

---

## 2. ✅ TRANCHÉE AU LOT 2 — The Roster livre SIX pages

**Décision prise en amont du lot 2 : six.** Appliquée —
`KIT_TIER_RULES.roster = { maxPages: 6, includeSocialTemplates: false }`.

⚠ **Un écart à signaler, et il est réel.** La raison donnée était « un site de cabinet porte une
page équipe ». **Cette page n'existe pas dans le vocabulaire** : `PAGES_WANTED` porte huit clés
(`home`, `about`, `approach`, `specialties`, `fees`, `faq`, `contact`, `blog`) et aucune ne
s'appelle `team`. Six pages sont donc bien livrées, mais ce sont **les six premières de
`PAGE_PRIORITY`** — pas cinq plus une page équipe. Ajouter une clé de page touche le brief, le
plafonnement et le rendu ; aucun lot de cette session ne le porte, et c'est consigné dans
`OUT_OF_SCOPE.md`.

<details><summary>La question telle qu'elle était posée au lot 1</summary>

### The Roster n'a pas de nombre de pages dans l'offre

**Lot concerné** : L3.
**Ce qui était en place** : `KIT_TIER_RULES.roster = { maxPages: 4, includeSocialTemplates: false }`,
repris de The Foundation.

**Pourquoi** : l'offre dit, pour The Foundation, « l'accroche de son site + 3 pages » — quatre, et
le nombre est **lu**, pas choisi. Pour The Roster elle dit « site + fiche Google du cabinet », sans
compte. Quatre est un repli, pas une décision.

**Options** :
- **4** (en place) — un cabinet a le même site qu'un solo, plus des bios.
- **Un nombre plus grand** — un cabinet de cinq cliniciennes a plus à dire. Le prix (690 $ contre
  390 $) le suggère.
- **`null`** — toutes les pages demandées au brief. ⚠ Dangereux : c'est une promesse non bornée à
  690 $.

**Pour trancher** : une décision commerciale. L'écart est d'un UPDATE sur une constante.

</details>

---

## 3. ✅ CONFIRMÉE AU LOT 2 — trois directions, les fichiers en add-on

La décision prise en amont du lot 2 : **inchangé**. `plans.foundation.directions_limit = 3`,
`regenerations_limit = 6` ; elle choisit un look, le site le porte, et les 89 $ achètent le logo,
les exports et les fichiers de marque. Aucun code n'a bougé — l'option en place était la bonne.

<details><summary>La question telle qu'elle était posée au lot 1</summary>

### The Foundation inclut-elle le choix de direction visuelle ?

**Lot concerné** : L3.
**Ce qui est en place** : `plans.foundation.directions_limit = 3`, `regenerations_limit = 6`.

**La tension** : l'offre fait de l'identité visuelle un **add-on à 89 $**. Mais The Foundation
livre un site, et un site a des couleurs et des typographies — qui viennent aujourd'hui d'une
direction choisie parmi trois.

**Options** :
- **Trois directions, les FICHIERS en add-on** (en place) — elle choisit un look, le site le
  porte, et les 89 $ achètent le logo, les exports et les fichiers de marque.
- **Aucune direction sans l'add-on** — The Foundation utiliserait une palette par défaut.
  ⚠ Le produit n'a pas de palette par défaut : c'est un lot à part entière.

**Pour trancher** : une décision de produit. L'option en place est la moins coûteuse à défaire.

</details>

---

## 4. Une clinicienne supplémentaire ne déclenche rien

**Lot concerné** : L4 (la forme d'achat existe), L21 (le déclenchement).
**Ce qui est en place** : `plans.roster_seat` porte **`directions_limit = null`**, donc
`consume_generation_credit` échoue fermé : un siège acheté ne produit rien.

**Pourquoi** : ce qu'une clinicienne de plus reçoit — son pack complet — est déclenché par son
arrivée dans le cabinet, pas par une ligne de catalogue. Tant que ce déclenchement n'est pas écrit,
l'absence d'allocation refuse plutôt qu'elle n'ouvre une génération que personne n'a branchée.

**⚠ La conséquence à connaître** : un siège se vend et ne livre rien.

> **Lot 1** : « Il ne faut pas le mettre en vente avant L21. Rien dans le code ne l'empêche
> aujourd'hui — c'est une décision de mise en vente, pas une garde technique. »

### ✅ La moitié TECHNIQUE est faite au lot 2

`plans.sellable = false` sur `roster_seat`, **lu par le chemin de checkout avant tout appel à
Stripe**. Un test tente l'achat et exige que rien n'atteigne Stripe. Ce n'est plus une décision de
mise en vente : la vente est refusée par le code, et le commentaire de colonne nomme **L21** comme
le lot qui la rouvre.

Ce n'est **pas** un CHECK sur `purchases` : cette table est écrite par le webhook, après que
l'argent a bougé — un refus à cet endroit ne refuserait pas la vente, il refuserait la trace de la
vente.

### ⚠ Ce qu'il reste à décider, et qui n'a pas bougé

Est-ce l'**INVITATION** qui déclenche le pack, ou son **ACCEPTATION** ? L'invitation est ce que le
cabinet paie ; l'acceptation peut ne jamais venir. **C'est une décision de produit, elle reste
ouverte, et elle appartient à L21** — le lot 2 ne l'a ni prise ni contournée.

---

## 5. 🔒 FERMÉE — le texte collé n'est pas stocké, et la question n'est pas rouverte

**Décision posée en amont du lot 2 : toujours hors périmètre.** *« HER TEXT IS NEVER STORED »*
tient, et `lib/check/review.ts` la porte toujours. **Le lot 2 ne l'a pas rouverte**, y compris là
où elle était tentante : The First Line reste bloqué par elle, et c'est un fait, pas un argument.

<details><summary>La question telle qu'elle était posée au lot 1</summary>

### Stocke-t-on le texte que la cliente colle ?

**Lot concerné** : L6, hors périmètre de cette session.
**Ce qui est en place** : rien, et `lib/check/review.ts` porte toujours *« HER TEXT IS NEVER
STORED »* — respecté, comme le cahier l'exigeait.

**Pourquoi ça revient ici** : The First Line suppose que oui. Sans stockage, il n'y a ni diagnostic
à relire, ni base pour le profil complet. C'est une décision de produit et de confidentialité, elle
change la politique de confidentialité, et elle bloque L6 entièrement.

</details>

---

## 6. ⏸ HORS PÉRIMÈTRE, CONFIRMÉ — que devient une clinicienne retirée ?

Rangée en L19 par décision prise en amont du lot 2. Rien n'a bougé, et rien ne devait bouger.
La question ci-dessous reste entière.

### Que devient une clinicienne retirée ?

**Lot concerné** : L19.
**Ce qui est en place** : rien. Le statut `removed` est dans le CHECK de
`organization_members.status`, et aucune fonction ne sait le poser.

Son kit, son profil Psychology Today publié, les pages qu'Eklio a posées sur le site du cabinet :
`TENANCY.md` §12 porte trois décisions de charte en prose, et **aucune** ne traite du retrait.

**Pour trancher** : une décision de la propriétaire, pas une mesure.

---

## 7. Les deux prix par siège ne sont pas facturables

**Lot concerné** : L3 (ils existent), L20 (ils deviennent facturables).
**Ce qui est en place** : `fill_practice` (69 $/clinicienne/mois) et `roster_seat`
(120 $/clinicienne) portent `per_seat = true` — une **propriété du catalogue**, pas un calcul.

Chez Stripe, la multiplication est la `quantity` de la ligne d'abonnement, et **rien dans ce dépôt
ne l'écrit** : `subscriptions` n'a ni `quantity` ni `organization_id`, et le webhook ne lit qu'un
`stripe_price_id`.

> **Lot 1** : « ⚠ Créer ces deux prix chez Stripe est donc préparatoire. Rien ne doit être mis en
> vente avec eux avant L20. »

### ✅ La moitié TECHNIQUE est faite au lot 2

`plans.sellable = false` sur `fill_solo` et `fill_practice` également, pour une raison qui n'est
pas seulement la facturation : **le cycle mensuel qu'ils vendent n'existe pas** (L18). Le
commentaire de colonne nomme L18 pour `fill_solo`, et **L18 et L20** pour `fill_practice`, qui a
besoin des deux.

⚠ **Les variables d'environnement restent à créer et à renseigner.** Le refus porte sur la VENTE,
pas sur la configuration — voir `ENV_REQUIRED.md`.

### ⚠ Ce qu'il reste à décider

Rien, pour l'instant : ce n'est pas une décision mais un travail, et il appartient à L20
(`subscriptions.quantity`, `organization_id`, la lecture de `items.data[0].quantity` dans le
webhook).

---

## 8. Le lot 1 en comptait dix, pas neuf

**Constat, pas décision.** Le cahier annonce « neuf lots » et en liste dix : L1, L2, L3, L4, L5,
L8, L9, L10, L11, L13. Les dix ont été livrés ; le compte est signalé au cas où le neuvième aurait
dû être retiré.

---
---

# Ce que le LOT 2 a ouvert

Quatre entrées. La première est la seule qui bloque quelque chose.

---

## 9. ⚠⚠ On n'a jamais vu sortir une Foundation, et on ne peut pas la voir d'ici

**Lot concerné** : tous ceux qui construisent par-dessus la génération.
**Ce qui est en place** : rien de neuf. La phase A n'a pas tourné.

Le lot 2 partait d'une phrase : *« The Foundation est déclarée produisible. Elle n'a jamais été
produite. »* Elle est toujours vraie ce soir.

**Constaté par exécution, pas déduit d'une variable** : un appel réel, par le client du produit
lui-même, rend `AnthropicNotConfiguredError: ANTHROPIC_API_KEY is not set`. Aucun modèle n'est
joignable depuis cet environnement pour le compte du produit.

**Ce qui reste donc non mesuré** — et la liste est exactement celle que la phase A devait cocher :

| Question | État |
|---|---|
| Sur trois briefs, la sortie nomme-t-elle un problème tel qu'une patiente le décrirait ? (critère d'acceptation de L8, mot pour mot) | **non mesurée** |
| Les gardes se déclenchent-elles sur du texte de modèle, ou seulement sur les cas construits ? Une modalité paraphrasée passe-t-elle ? | **non mesurée** |
| L'Ethics Guard attrape-t-il quelque chose sur une sortie réelle, ou n'a-t-il jamais vu que ses propres exemples ? | **non mesurée** |
| Le profil Psychology Today tient-il sur un brief réellement incomplet ? | **non mesurée** |

**Ce qui a été décidé, et qui n'est pas une option prise à la légère** : ne rien simuler. Les
identifiants de session de ce harnais n'ont pas été détournés pour fabriquer une sortie qui aurait
ressemblé à une Foundation. Une sortie simulée aurait rendu les quatre lignes du tableau
« mesurées » et fausses, ce qui est pire que vide.

**Pour trancher** : une clé, et une demi-journée. Rien d'autre ne débloque ces quatre lignes.

---

## 10. La phase C n'a pas eu lieu, et c'est une conséquence, pas un retard

**Lot concerné** : L14–L17.
**Ce qui est en place** : rien. Pas de `site_connections`, pas de client WordPress, aucun secret
par cliente, aucune variable d'environnement déclarée pour eux.

Le cahier du lot 2 le posait comme une condition : la phase C ne se fait que si la phase A a
tourné **et** si ses sorties sont jugées livrables. La phase A n'a pas tourné.

> *« Construire la publication d'un contenu qu'on n'a jamais vu sortir serait exactement l'erreur
> que ce lot existe pour éviter. »*

⚠ **Ce que ça laisse ouvert** : `site_connections` est **le premier secret par cliente du
produit** — un mot de passe d'application WordPress, chiffré au repos, révocable. Sa forme est une
décision de sécurité qui mérite d'être prise à froid, pas dans la foulée d'un lot. Le fait qu'elle
soit reportée n'est pas une perte.

**Pour trancher** : rien à trancher aujourd'hui. Reprendre quand §9 est levée.

---

## 11. Une page « équipe » est promise par le raisonnement et absente du vocabulaire

**Lot concerné** : non attribué. Le plus proche est L10.
**Ce qui est en place** : `KIT_TIER_RULES.roster.maxPages = 6`, et les six pages livrées sont les
six premières de `PAGE_PRIORITY`.

La décision « six pages pour The Roster » est appliquée. Sa **raison** — « un site de cabinet porte
une page équipe » — ne l'est pas, parce que `PAGES_WANTED` n'a pas de clé `team`. Le cabinet reçoit
donc six pages parmi `home`, `about`, `approach`, `specialties`, `fees`, `faq`, `contact`, `blog`.

**Options** :
- **Laisser ainsi** (en place) — six pages, pas de page équipe. Les bios des cliniciennes ont
  aujourd'hui pour seul foyer possible la page `about`.
- **Ajouter une clé `team`** — touche `PAGES_WANTED`, l'étape 7 du brief, `PAGE_PRIORITY`, le
  plafonnement et le rendu. Et ⚠ `site_pages`, en base, porte un **autre** vocabulaire de page
  (`home`, `about`, `services`, `contact`) : les deux ne se recouvrent déjà pas
  (`OUT_OF_SCOPE.md` §18), et en ajouter une d'un seul côté creuserait l'écart.

**Pour trancher** : une décision de produit, puis un lot. Pas un UPDATE.

---

## 12. Le brief propose encore un prompt Squarespace que la qualification refuse

**Lot concerné** : **L23** (le retrait de l'offre précédente).
**Ce qui est en place** : `components/brief/step-bodies.tsx` porte `BUILDER_TARGETS`, une liste en
dur — `squarespace`, `lovable`, `framer`, `webflow` — qui appartient à l'offre PRÉCÉDENTE : elle
choisit pour quel constructeur on écrit un **prompt à coller**, un livrable que The Foundation ne
vend pas.

⚠ **Depuis le verdict de ce lot, les deux surfaces se contredisent en façade.** La qualification
dit à une praticienne sur Squarespace « nous ne publions pas là-dessus » ; l'étape 7 du brief lui
propose toujours un prompt Squarespace. Les deux sont vraies séparément — l'une parle de
publication, l'autre d'un texte à coller soi-même — et personne ne lit un produit en séparant ces
deux choses.

**Je n'y ai pas touché** : c'est la surface de l'offre précédente, elle est encore vendue, et la
retirer est L23. Le signaler est ce que je peux faire sans déborder.

**Pour trancher** : soit L23 arrive et la question disparaît, soit il faut une phrase à l'étape 7
qui distingue « publié par nous » de « à coller vous-même ». La seconde est un petit travail
d'interface, pas une décision de schéma.

---
---

# Ce que le CORRECTIF DU LOT 2 a ouvert

## 13. ✅ TRANCHÉE — la plateforme n'est plus un refus

Rappel de ce qui a changé, pour que §1 se relise correctement : `site_platforms.squarespace` reste
`refused`, et **ce statut ne refuse plus une cliente**. Il ferme les quatre SKU qui promettent
qu'Eklio publie (`foundation`, `roster`, `fill_solo`, `fill_practice`) et laisse tout le reste
ouvert. Une praticienne sur Squarespace ou sur Wix achète l'offre précédente sans obstacle.

## 14. ⚠ Un achat parti de `/pricing` ne peut pas acheter la nouvelle offre

**Lot concerné** : non attribué. Le plus proche est **L23**.
**Ce qui est en place** : `createCheckoutSession` refuse un SKU conditionné quand `projectId` est
nul, avec la phrase *« Tell us where your website lives first »*.

**Pourquoi ce choix** : la plateforme est une réponse du BRIEF. Un checkout parti de `/pricing`
n'en a pas, et deviner reviendrait à encaisser 390 $ en promettant de publier sur une plateforme
dont on ne sait rien. C'est le même sens de repli que `loadSitePlatforms`, qui rend une liste vide
sur une lecture ratée.

**Ce qu'il faut décider** : est-ce que `/pricing` doit pouvoir vendre The Foundation directement ?
Si oui, il faut soit poser la question de plateforme sur `/pricing`, soit rattacher l'achat à un
brief après coup. Les deux sont du travail, aucun n'est ce correctif.

**Aujourd'hui la question est théorique** : aucun écran ne propose `foundation` ni `roster` à la
vente (`OUT_OF_SCOPE.md` §30). Elle deviendra réelle le jour où L23 met la nouvelle offre en
vitrine — et il vaut mieux l'avoir tranchée avant.

## 15. La nouvelle offre n'est en vitrine nulle part

**Lot concerné** : **L23**.

Le cahier demandait que les paliers de la nouvelle offre soient « présentés comme indisponibles
avec la raison ». Ils ne sont **présentés du tout** : `ORDERED_PLANS` n'itère que
`LEGACY_KIT_TIERS`. La règle d'éligibilité est en place et gouverne le paiement ; la vitrine reste
à faire, et elle appartient au lot qui retire l'offre précédente. Détail dans
`OUT_OF_SCOPE.md` §30.

## 16. Le garde-fou ne couvre que `lib/brief/`

**Lot concerné** : aucun. C'est une limite assumée, écrite pour ne pas être prise pour un oubli.

`lib/brief/__tests__/wired-to-a-screen.test.ts` échoue si un module de `lib/brief/` n'est importé
par aucun fichier de `app/` ni de `components/`. Il s'arrête là volontairement : ce dossier décrit
un **parcours**, donc un module que l'interface n'atteint pas est une étape qui n'existe pas pour
la cliente. L'étendre à `lib/` entier en ferait une règle générale fausse — un module de
génération n'a aucune raison d'être importé par un écran.

⚠ **La famille de défaut n'est donc pas fermée ailleurs.** Si un autre dossier devait recevoir la
même garde, `lib/billing/` serait le premier candidat : il décide ce qui est vendable, et une
règle qu'aucun écran ne lit y aurait les mêmes conséquences qu'ici.
