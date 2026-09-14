# DECISIONS_NEEDED.md — ce qui a bloqué, et les options

Écrit pendant le lot 1 d'implémentation de l'offre du 13 septembre.

**Aucun lot n'a été sauté.** Les dix ont été livrés. Ce qui suit est ce sur quoi j'ai dû choisir
sans pouvoir demander : j'ai pris l'option la moins coûteuse à défaire, je l'ai écrite dans le
code, et je la pose ici pour qu'elle soit confirmée ou renversée.

Chaque entrée dit **ce qui est en place aujourd'hui**, pour qu'un « non » soit un changement
mesurable et pas une reprise à zéro.

---

## 1. ⚠ Squarespace — la seule qui peut rendre un point de l'offre irréalisable

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

---

## 2. The Roster n'a pas de nombre de pages dans l'offre

**Lot concerné** : L3.
**Ce qui est en place** : `KIT_TIER_RULES.roster = { maxPages: 4, includeSocialTemplates: false }`,
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

---

## 3. The Foundation inclut-elle le choix de direction visuelle ?

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

---

## 4. Une clinicienne supplémentaire ne déclenche rien

**Lot concerné** : L4 (la forme d'achat existe), L21 (le déclenchement).
**Ce qui est en place** : `plans.roster_seat` porte **`directions_limit = null`**, donc
`consume_generation_credit` échoue fermé : un siège acheté ne produit rien.

**Pourquoi** : ce qu'une clinicienne de plus reçoit — son pack complet — est déclenché par son
arrivée dans le cabinet, pas par une ligne de catalogue. Tant que ce déclenchement n'est pas écrit,
l'absence d'allocation refuse plutôt qu'elle n'ouvre une génération que personne n'a branchée.

**⚠ La conséquence à connaître** : un siège se vend et ne livre rien. **Il ne faut pas le mettre en
vente avant L21.** Rien dans le code ne l'empêche aujourd'hui — c'est une décision de mise en
vente, pas une garde technique.

**Ce qu'il faut décider** : est-ce l'INVITATION qui déclenche le pack, ou son ACCEPTATION ?
L'invitation est ce que le cabinet paie ; l'acceptation peut ne jamais venir.

---

## 5. Stocke-t-on le texte que la cliente colle ?

**Lot concerné** : L6, hors périmètre de cette session.
**Ce qui est en place** : rien, et `lib/check/review.ts` porte toujours *« HER TEXT IS NEVER
STORED »* — respecté, comme le cahier l'exigeait.

**Pourquoi ça revient ici** : The First Line suppose que oui. Sans stockage, il n'y a ni diagnostic
à relire, ni base pour le profil complet. C'est une décision de produit et de confidentialité, elle
change la politique de confidentialité, et elle bloque L6 entièrement.

---

## 6. Que devient une clinicienne retirée ?

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

⚠ **Créer ces deux prix chez Stripe est donc préparatoire. Rien ne doit être mis en vente avec eux
avant L20.** C'est écrit aussi dans `ENV_REQUIRED.md`.

---

## 8. Le lot 1 en comptait dix, pas neuf

**Constat, pas décision.** Le cahier annonce « neuf lots » et en liste dix : L1, L2, L3, L4, L5,
L8, L9, L10, L11, L13. Les dix ont été livrés ; le compte est signalé au cas où le neuvième aurait
dû être retiré.
