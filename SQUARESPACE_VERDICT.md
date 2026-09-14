# SQUARESPACE_VERDICT.md — la question tranchée

**Date de l'enquête : 14 septembre 2026.** Toutes les consultations ci-dessous
sont de ce jour.

---

## La question, telle qu'elle était posée

> Existe-t-il une API publique de **création et de publication de pages de
> contenu**, comparable à `POST /wp-json/wp/v2/pages` ? **Les API commerce ne
> comptent pas.**

Elle est ouverte depuis `GAP_PLAN.md`. `site_platforms.status` porte trois
états au lieu de deux exactement pour qu'elle puisse rester ouverte sans
mentir, et pour que la réponse coûte un UPDATE.

## La réponse

**Non. `status = 'refused'`.**

Et il faut dire tout de suite ce qui affaiblit cette réponse : **je n'ai pas pu
lire la documentation développeur de mes propres yeux.** Ce que j'ai lu à la
place est décrit ci-dessous, ainsi que ce qui renverserait le verdict.

---

## 1. Ce que je n'ai pas pu atteindre, et pourquoi

Le mandataire sortant de cet environnement bloque **le domaine
`squarespace.com` entier**, au niveau du tunnel CONNECT.

| Hôte | Tentative | Résultat |
|---|---|---|
| `developers.squarespace.com` | WebFetch | `EGRESS_BLOCKED` |
| `developers-preview.squarespace.com` | curl | `CONNECT tunnel failed, response 403` |
| `api.squarespace.com` (`/1.0/site/pages`, `/1.0/commerce/orders`) | curl | `CONNECT tunnel failed, response 403` |
| `support.squarespace.com` | WebFetch / curl | `EGRESS_BLOCKED` / `http=000` |
| `forum.squarespace.com` | WebFetch / curl | `EGRESS_BLOCKED` / `http=000` |

Ce n'est pas une panne ni une erreur de configuration de ma part :
`$HTTPS_PROXY/__agentproxy/status` rend `selective: false`, et les mêmes
commandes vers d'autres hôtes passent dans la même session. C'est une **règle
de sortie**, et elle couvre aussi bien la documentation que l'API elle-même —
donc même un appel d'essai non authentifié, qui aurait répondu `401` sur un
chemin existant et `404` sur un chemin inexistant, était hors de portée.

**Je l'écris parce que c'est la faiblesse du verdict, pas une excuse.** Une
demi-journée sur un poste ordinaire tranche cela de façon directe.

## 2. Ce que j'ai pu atteindre — les sources primaires de côté

Deux artefacts **publiés par Squarespace elle-même** sont accessibles depuis
cet environnement. Ils ne sont pas la documentation, mais ils ne sont pas non
plus du commentaire de tiers.

### 2.1 L'organisation npm `@squarespace` (registry.npmjs.org, consulté le 14/09/2026)

Douze paquets publiés par Squarespace. Aucun n'est un client d'API. Tous
relèvent du développement de **gabarits** :

`@squarespace/template-engine` (2.10.10), `@squarespace/server` (1.10.3,
publié le **8 décembre 2025**), `@squarespace/toolbelt` (0.12.5),
`@squarespace/core` (1.2.2, « the frontend JS API for Squarespace templates »),
`@squarespace/polyfills`, `@squarespace/layout-base`,
`@squarespace/social-links`, `@squarespace/less-ts-cli`,
`@squarespace/video-background`, `@squarespace/squarespace-server`.

J'ai cherché `api.squarespace`, `/pages`, `publish` et `1.0/` dans les README
de `toolbelt`, `core` et `server`. **Aucune occurrence d'un point d'entrée
d'écriture.** Les seules occurrences de « page » sont
`--auto-reload … reloads page` et « page reloading » — le rechargement du
navigateur pendant le développement local.

Ce qui compte ici : `@squarespace/server` a été republié il y a neuf mois. La
Developer Platform est **vivante**, et elle est toujours une plateforme de
gabarits. Un produit qui exposerait une API de pages aurait, à ce degré
d'investissement en outillage, un client — ou au moins une mention.

Le seul paquet npm qui parle d'API Squarespace est `@corte-so/commerce-squarespace`,
d'un tiers, et son propre résumé se borne à « Squarespace **Commerce** API
provider (catalog-only) ».

### 2.2 L'arborescence de la documentation de Squarespace

Les URL de la documentation développeur, telles que l'index de recherche les
rend, sont **toutes** sous un seul segment :

- `https://developers.squarespace.com/commerce-apis/overview`
- `https://developers.squarespace.com/commerce-apis/transactions-overview`
- `https://developers.squarespace.com/commerce-apis/retrieve-basic-site-info`

Le chemin est `commerce-apis`. Y compris pour *retrieve basic site info*, qui
est une **lecture** d'information de site rangée sous le commerce. Il n'existe
pas, dans ce que l'index connaît de ce domaine, de segment `content-apis`,
`pages`, `cms` ou équivalent.

⚠ **C'est la pièce décisive, et elle est structurelle plutôt que déclarative.**
La question posée excluait les API commerce. La totalité de la surface
documentée par Squarespace *s'appelle* commerce. Le périmètre que l'énoncé
écartait est le périmètre entier.

## 3. Les sources secondaires

| Source | URL | Ce qu'elle dit |
|---|---|---|
| Squarespace Help Center — *Squarespace API keys* | `https://support.squarespace.com/hc/en-us/articles/236297987-Squarespace-API-keys` | Les permissions qu'une clé peut porter sont **Orders, Forms, Inventory, Transactions**. Quatre. Aucune ne touche au contenu. |
| Squarespace Developer Platform — *Commerce APIs overview* | `https://developers.squarespace.com/commerce-apis/overview` | Les API offertes sont Inventory, Orders, Transactions, Forms. |
| Forum Squarespace — *Programmatically create new pages* | `https://forum.squarespace.com/topic/323740-programmatically-create-new-pages/` | Question identique à la nôtre. |
| Forum Squarespace — *Does the Squarespace API allow for the creation of pages?* | `https://forum.squarespace.com/topic/332561-does-the-squarespace-api-allow-for-the-creation-of-pages-im-using-makecom/` | « only API calls available for store functions, with no endpoints for pages ». |
| Forum Squarespace — *How to programmatically publish new posts on a Squarespace blog?* | `https://forum.squarespace.com/topic/290491-how-to-programatically-publish-new-posts-on-square-space-blog-any-restful-api-for-blog-creation/` | Même question pour le blog, même réponse. |
| Forum Squarespace — *API Page Creation* | `https://forum.squarespace.com/topic/151424-api-page-creation/` | La plus ancienne. La question a donc des années. |
| Rollout — *Squarespace API Essentials* | `https://rollout.com/integration-guides/squarespace/api-essentials` | Base `https://api.squarespace.com`, Bearer + User-Agent, surface commerce. |
| Pipedream — *Squarespace integrations* | `https://pipedream.com/apps/squarespace` | Déclencheurs et actions de commerce et de formulaires. |
| Stitchflow — *Squarespace User Management API Guide* | `https://www.stitchflow.com/user-management/squarespace/api` | « no public REST API … the Commerce API covers orders, products, and inventory only ». |

**Une source dit le contraire, et je la nomme plutôt que de la taire.** Un
agrégateur commercial (ApiX-Drive,
`https://apix-drive.com/en/blog/other/squarespace-api-integration`) décrit une
API permettant « creating, updating, and deleting posts and pages ». Je l'écarte
pour trois raisons : elle ne cite aucun point d'entrée, aucun verbe HTTP et
aucun chemin ; elle contredit la liste des permissions publiée par Squarespace
elle-même ; et c'est une page de démarchage pour un service d'intégration, pas
une documentation. Une page marchande qui promet plus que l'éditeur n'annonce
n'est pas une source.

## 4. Ce qui reste vrai malgré tout, et qui ne suffit pas

Les **Static Pages** du mode développeur existent : ce sont des fichiers
`.page` déposés par Git ou SFTP dans un gabarit. Elles ne répondent pas à la
question pour deux raisons indépendantes. Elles exigent d'une praticienne
qu'elle bascule son site en mode développeur — un aller sans retour vers
l'éditeur visuel. Et le contenu ainsi déposé, d'après la documentation même du
mode développeur, **ne peut plus être modifié depuis l'interface Squarespace par
la cliente**. Eklio vend des pages *qu'elle possède ensuite*. Une page qu'elle
ne peut pas rouvrir n'est pas cette promesse.

## 5. Le verdict, et son degré

**Faisceau convergent : la Developer Platform n'expose pas d'API de création de
pages de contenu.** Cinq sources indépendantes concordent ; deux d'entre elles
proviennent de Squarespace (les paquets npm, l'arborescence de la
documentation) ; la seule qui diverge est une page de démarchage sans point
d'entrée.

**Ce que je n'affirme pas :** avoir lu `developers.squarespace.com`. Le verdict
est **établi par convergence, pas attesté à la source**.

**Pourquoi trancher `refused` plutôt que laisser `conditional`.** `conditional`
n'est pas gratuit : chaque inscription prise sous ce statut est une promesse à
tenir ou à retirer, et le `notice` actuel dit à la cliente qu'on est *en train
de vérifier*. Nous avons vérifié. Continuer à afficher qu'on vérifie serait
désormais faux. Et les deux erreurs ne coûtent pas la même chose : refuser à
tort renvoie une cliente qu'on aurait pu servir — et
`platform_refusal_counts()` compte exactement ces cliente-là, donc l'erreur se
voit et se chiffre ; accepter à tort encaisse un paiement pour une publication
impossible. **Le sens du doute va vers le refus.**

### Ce qui renverserait ce verdict

Un seul fait suffit, et il est bon marché à établir :

- une page sous `developers.squarespace.com` documentant un point d'entrée
  d'**écriture** de page ou de billet — ou n'importe quel segment de
  documentation qui ne s'appelle pas `commerce-apis` ;
- ou un `POST` d'essai sur `api.squarespace.com` répondant autre chose qu'un
  `404` sur un chemin de pages.

Ce jour-là, la réponse coûte **un UPDATE sur une ligne** — c'est précisément
ce que `site_platforms` a été construite pour rendre possible.

## 6. Ce que ce verdict change, et ce qu'il ne change pas

- `site_platforms.squarespace` passe de `conditional` à `refused`, avec un
  `notice` qui dit la chose exacte : nous ne publions pas sur Squarespace.
- **Rien n'est implémenté et rien n'est retiré.** Le cahier disait « tu ne
  l'implémentes pas ». Aucune ligne n'est supprimée ; `squarespace` reste au
  catalogue, visible, refusée et expliquée — comme Wix et Webflow.
- **L16 (le client Squarespace) tombe à zéro.** Il n'y a pas de client à écrire
  contre une API qui n'existe pas.
- La qualification ne peut plus dire « WordPress ou Squarespace ». Elle dit
  WordPress.
- `DECISIONS_NEEDED.md` §1 est traitée, avec le degré du verdict reporté tel
  quel : renversable par une lecture directe.
