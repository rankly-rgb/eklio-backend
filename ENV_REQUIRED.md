# ENV_REQUIRED.md — les variables d'environnement, et le SKU que chacune porte

Écrit pendant le lot 1 d'implémentation de l'offre du 13 septembre.
**Complété au lot 2** — les compléments sont signalés « *(lot 2)* ».

**Ce fichier ne crée rien dans Stripe.** Les identifiants de prix (`price_…`) sont créés à la main
dans le tableau de bord Stripe, une fois en mode test et une fois en mode live, puis collés dans
l'environnement de déploiement. Le code ne fait que **nommer la variable à lire** — il ne connaît
aucun `price_…` et ne doit jamais en connaître : ils diffèrent entre les deux modes, et un
identifiant en dur ferait facturer en test depuis la production, ou l'inverse.

---

## ⚠ Pourquoi ce fichier existe

Un SKU sans identifiant de prix **ne lève pas à l'écriture.** Il lève au **checkout**, sur une
cliente qui vient de cliquer « payer », et **seulement en production** — puisque la variable
manquante est celle du mode live. Le défaut est invisible partout où on le chercherait.

C'est pourquoi `eklio-frontend/lib/billing/__tests__/offer-catalogue.test.ts` refuse un SKU sans
variable déclarée, refuse deux SKU sur la même variable, et refuse qu'une variable soit partagée
entre l'offre précédente et la nouvelle.

Ce que ce test **ne peut pas** faire : vérifier que la variable est **renseignée** dans un
environnement donné, ni qu'elle pointe vers le bon prix chez Stripe. Les deux se vérifient au
déploiement, avec la liste ci-dessous.

---

## L'offre du 13 septembre

| Variable | SKU (`plans.tier`) | Ce qu'elle porte | Montant | Facturation |
|---|---|---|---|---|
| `STRIPE_PRICE_FOUNDATION` | `foundation` | The Foundation | 390 $ | une fois |
| `STRIPE_PRICE_ROSTER` | `roster` | The Roster, jusqu'à 5 cliniciennes | 690 $ | une fois |
| `STRIPE_PRICE_IDENTITY_ADDON` | `identity_addon` | Identité visuelle (add-on) | 89 $ | une fois |
| `STRIPE_PRICE_ROSTER_SEAT` | `roster_seat` | Clinicienne supplémentaire | 120 $ | une fois, **par clinicienne** |
| `STRIPE_PRICE_FILL_SOLO` | `fill_solo` | The Fill (solo) | 59 $ | **par mois** |
| `STRIPE_PRICE_FILL_PRACTICE` | `fill_practice` | The Fill (cabinet) | 69 $ | **par mois et par clinicienne** |

⚠ **Les deux dernières doivent être créées chez Stripe comme des prix RÉCURRENTS mensuels**, pas
comme des paiements uniques. Un prix unique posé sur un abonnement encaisse une fois et ne
renouvelle jamais : la cliente paie un mois et reçoit douze.

⚠ **`STRIPE_PRICE_FILL_PRACTICE` et `STRIPE_PRICE_ROSTER_SEAT` se multiplient par un nombre de
cliniciennes.** Chez Stripe, c'est la `quantity` de la ligne d'abonnement qui porte cette
multiplication — **et rien dans ce dépôt ne l'écrit encore.** `subscriptions` n'a aujourd'hui ni
`quantity` ni `organization_id`, et le webhook ne lit qu'un `stripe_price_id`. Créer ces deux prix
est donc préparatoire : ils ne seront réellement facturables qu'une fois le lot d'abonnement au
siège livré. Rien ne doit être mis en vente entre-temps avec ces deux-là.

### *(lot 2)* « Rien ne doit être mis en vente » n'est plus une consigne

Le paragraphe ci-dessus se terminait par une phrase que rien n'appliquait. Trois SKU de ce tableau
portent désormais **`plans.sellable = false`**, et le chemin de checkout la lit **avant tout appel
à Stripe** :

| SKU | Pourquoi il ne se vend pas | Qui le rouvre |
|---|---|---|
| `roster_seat` | un siège acheté ne produit rien : `directions_limit` est NULL, et ce que reçoit une clinicienne de plus est déclenché par son arrivée, pas par une ligne de catalogue | **L21** |
| `fill_solo` | le cycle mensuel de contenu qu'il vend n'existe pas | **L18** |
| `fill_practice` | ce cycle, **et** la multiplication par siège, qui ne s'écrit nulle part | **L18 et L20** |

⚠ **Les trois variables restent à créer et à renseigner.** Le refus porte sur la VENTE, pas sur la
configuration : un prix Stripe absent lèverait au checkout, sur une cliente, et seulement en
production — c'est précisément le défaut que ce fichier existe pour prévenir. Créer les prix
maintenant et vendre plus tard est le bon ordre ; l'inverse ne l'est pas.

Le jour où un lot rouvre la vente, il repasse la ligne à `true` dans **sa propre migration**, et
`supabase/tests/20260914190000_sellability.test.sql` l'oblige à venir le dire.

---

## L'offre précédente — encore vendue

Elle n'est pas retirée de la vente dans ce lot. Ces variables restent nécessaires.

| Variable | SKU | Ce qu'elle porte | Montant | Facturation |
|---|---|---|---|---|
| `STRIPE_PRICE_STARTER` | `starter` | Brand Kit | 79 $ | une fois |
| `STRIPE_PRICE_PRACTICE` | `practice` | Brand Kit Plus | 149 $ | une fois |
| `STRIPE_PRICE_SIGNATURE` | `signature` | Practice Suite | 249 $ | une fois |
| `STRIPE_PRICE_MONTHLY_PRESENCE` | — | Monthly Presence | 39 $ | par mois |

`STRIPE_PRICE_MONTHLY_PRESENCE` n'a pas de ligne dans `plans` : l'abonnement précédent est porté
par `subscriptions` seul. Il reste en place tant que le lot de retrait n'a pas eu lieu — et la
mécanique d'essai de 90 jours qui s'appuie dessus (préavis légal, garde d'essai) est **celle sur
laquelle The Fill se rebranchera**, donc elle ne se supprime pas.

---

## Où chaque variable est nommée dans le code

| Variable | Nommée par |
|---|---|
| Les six de l'offre | `eklio-frontend/lib/billing/offer.ts`, champ `priceEnvVar` |
| `foundation`, `roster` | aussi `eklio-frontend/lib/billing/plans.ts` (`KIT_PLANS`) |
| Les trois paliers précédents | `eklio-frontend/lib/billing/plans.ts` (`KIT_PLANS`) |
| `STRIPE_PRICE_MONTHLY_PRESENCE` | `eklio-frontend/lib/billing/plans.ts` (`MONTHLY_PRESENCE`) |

Aucun identifiant de prix n'est écrit dans une migration, ni dans `plans` : la base porte les
**montants** (`plans.price_cents`), qui sont la décision commerciale, et jamais les identifiants,
qui sont de la configuration d'environnement.

---

## Ce que ce lot n'a pas déclaré

- **Aucune variable pour un CMS.** Pas de jeton WordPress, pas de clé Squarespace, pas de secret de
  chiffrement pour des identifiants par cliente. Le composant de publication n'existe pas, et
  déclarer ses variables avant lui laisserait croire le contraire.
- **Aucune variable pour la qualification de plateforme.** La liste des plateformes acceptées est
  une donnée de configuration en base, pas une variable d'environnement, précisément pour qu'un
  changement d'avis sur Squarespace ne coûte pas un déploiement.

### *(lot 2)* Et ce que le lot 2 n'a pas déclaré non plus

- **Aucune variable de publication WordPress.** La phase C — `site_connections`, les identifiants
  chiffrés au repos, `POST /wp-json/wp/v2/pages` — **n'a pas eu lieu**, parce que la phase A n'a
  pas pu tourner et que construire la publication d'un contenu qu'on n'a jamais vu sortir était
  précisément l'erreur que ce lot existait pour éviter. Les variables qu'elle aurait déclarées
  (jeton d'application WordPress, clé de chiffrement des secrets par cliente) ne le sont donc pas.
- **Plus de variable de clé Squarespace à prévoir.** La question est tranchée : `SQUARESPACE_VERDICT.md`.
  Il n'y a pas d'API de pages, donc il n'y aura pas de client, donc pas de secret à loger.
- **`ANTHROPIC_API_KEY` n'est pas une nouveauté, et c'est ce qui a arrêté la phase A.** Elle est
  déjà nécessaire au produit ; elle est absente de CET environnement. Le constat est mesuré, pas
  supposé : un appel réel par le client du produit rend `AnthropicNotConfiguredError:
  ANTHROPIC_API_KEY is not set`. Aucune Foundation n'a donc été produite.
