# GAP_PLAN.md — le chantier

Compagnon de `GAP_AUDIT.md`. Les constats sont là-bas ; ici, ce qu'il faut construire, dans quel
ordre, et ce qui casse si on saute un lot.

**Estimations en jours de travail d'une personne qui connaît ce dépôt.** Pas en points. Elles
incluent les tests et la migration, pas la relecture ni le déploiement.

---

## ⚠ La première page

**Deux choses avant le tableau.**

**1. La publication CMS est le chemin critique, et elle n'existe pas du tout.**
Aucun client HTTP vers un CMS, aucun stockage de secret par cliente, aucune file de travaux, aucune
notion de révocation — mesuré, pas supposé (`GAP_AUDIT.md` §D.1). `content_publications` est un
**journal déclaratif** : elle déclare avoir posté, Eklio n'a rien publié. The Foundation et The Fill
disent tous deux « publiées par Eklio ». **Ce verbe est toute la différence entre l'offre nouvelle
et le produit actuel**, qui fait déjà bien tout le reste. Il n'y a que deux sorties honnêtes :
construire le composant (lots 12 à 14, 16 à 21 jours), ou changer le verbe.

**2. Un point de l'offre est peut-être irréalisable en l'état : « publiée par Eklio sur
Squarespace ».**
Squarespace n'expose pas, à ma connaissance, d'API publique de création et de publication de pages
de contenu comparable à `POST /wp-json/wp/v2/pages` ; ses API développeur couvrent le commerce.
`INFERRED` — c'est **la seule affirmation de cet audit qui sort des dépôts et de la base**, donc
celle qu'il faut vérifier en premier. Si elle est confirmée, la qualification à l'inscription ne dit
plus « WordPress ou Squarespace » mais **« WordPress, ou une plateforme métier vérifiée »**, et
Squarespace bascule du côté « nous préparons tout, vous collez ». **C'est une décision commerciale,
et elle doit être prise avant d'écrire une ligne de publication** — elle change le prix de L14
de 6 jours à zéro.

Tout le reste du chantier est mesurable et sans surprise. Plusieurs lots sont petits, et c'est dit.

---

## Le tableau des lots

| # | lot | ce qu'il livre | dépend de | jours | risque | ce qui casse si on le saute |
|---|---|---|---|---|---|---|
| **L0** | **Trancher Squarespace** | une réponse écrite : API de publication, oui ou non | — | **0,5** | **nul** — c'est de la lecture de documentation | On planifie 6 jours contre une API qui n'existe pas, ou on refuse à l'inscription une moitié du marché sans raison. |
| **L1** | **Remettre le droit à une seule source** | `resolveEntitledTier` et `countUnpaidProjects` lisent `brand_kit_entitling_statuses()` ; un test épingle la liste des deux côtés | — | **1** | **faible** — mais c'est un **défaut actif**, pas une prévention | Une acheteuse partiellement remboursée a son kit ouvert en base et se voit refuser en 402 tout ce qui est au-dessus de `starter`, avec un message qui lui propose d'acheter ce qu'elle a déjà. Et la divergence sera **multipliée par le nombre de SKU** du lot suivant. |
| **L2** | **Remettre la suite de tests au vert** | 12 fichiers rouges diagnostiqués et fermés ; la CI redevient un signal | — | **3** | **faible** en technique, **élevé** en tentation de reporter | Douze rouges masquent le treizième. Tout ce qui suit s'écrit sans filet — et ce chantier touche les policies, l'argent et les secrets. |
| **L3** | **Les nouveaux SKU** | `plans`, les trois CHECK de `tier`, `KIT_PLANS`, `SOLD_TIER_NAME`, les identifiants de prix Stripe : Foundation 390 $, Roster 690 $, add-on 89 $, The Fill 59 $ et 69 $ | L1 | **3** | **moyen** — on touche la contrainte qui garde l'argent | Rien ne peut être vendu. C'est le premier lot dont le résultat est encaissable. |
| **L4** | **L'achat qui n'est pas un palier** | `purchases.kind ∈ {tier, addon, seat}` ; l'add-on identité et le siège supplémentaire s'expriment ; `highestTier` cesse d'être la seule règle | L3 | **2** | **moyen** — `highestTier` est lu partout | L'add-on 89 $ et le +120 $ par clinicienne n'ont aucune forme en base. Un siège vendu n'est mesurable nulle part. |
| **L5** | **Qualification de plateforme** | une étape de brief : WordPress / Squarespace / autre (refus) ; URL du site ; stockage ; refus à l'inscription | L0 | **1** | **faible** | On encaisse 390 $ auprès d'une cliente dont le site est sur Wix, et on lui doit une publication qu'on ne peut pas faire. |
| **L6** | **The First Line — l'entrée par le profil collé** | second mode d'entrée : elle colle son profil, il est stocké, le diagnostic s'affiche, le premier paragraphe est réécrit ; jeton anonyme, plafond de dépense, purge | L1 | **4** | **moyen** — la décision « on stocke son texte » inverse une décision explicite du produit | Aucun haut d'entonnoir pour la nouvelle offre. C'est la seule chose gratuite qu'on offre, et donc la seule porte. |
| **L7** | **Le comparatif de zone** | « ce que disent les profils concurrents de sa zone » | L6 | **5** | **⚠ élevé** — **aucune source de données n'existe dans les deux dépôts** ; il faut en choisir une, la payer, et tenir ses conditions d'utilisation | Le diagnostic perd son argument le plus fort et redevient le scan gratuit qui existe déjà. **Candidat n°1 à la coupe pour une v1.** |
| **L8** | **La phrase de positionnement** | l'écran USP recadré sur « les mots de ses patients » | L1 | **1** | **faible** — **le lot est petit** : l'écran, les gardes, le contrôle d'unicité et les 30 clichés d'annuaire existent déjà | Le premier livrable de The Foundation manque, alors qu'il est à 90 % écrit. |
| **L9** | **Le profil Psychology Today rédigé** | un gabarit complet : champs structurés (existants) + prose rédigée et scannée | L1, L8 | **3** | **moyen** — ⚠ **c'est là que le défaut `\|\|` frappe** : un assemblage de champs souvent absents | Le deuxième livrable de The Foundation manque. |
| **L10** | **Ouvrir l'enum de pages** | `site_spec_page_keys()` cesse d'être `{home, about, services, contact}` ; les validateurs, `section_types.allowed_pages` et `site_spec_default_pages` suivent | L2 | **3** | **⚠ élevé** — ~15 validateurs jsonb lisent cet enum, et ils ont déjà été troués une fois | The Foundation tient tout juste (accroche + 3 pages). **The Fill ne tient pas du tout** : à la treizième page mensuelle, le produit refuse d'écrire. |
| **L11** | **Fiche Google : texte et posts** | une description propre à Google (aujourd'hui c'est le bloc de Psychology Today qui sert deux fois) ; un archétype de post Google sans image imposée | L1 | **3** | **faible** | Le quatrième livrable de The Foundation et un des quatre de The Fill manquent. |
| **L12** | **One-page prescripteurs** | un gabarit, un registre déontologique propre, un rendu | L1, L13 | **2** | **moyen** — ⚠ **le lecteur n'est pas une patiente** : les six règles ont été écrites pour l'autre lecteur, et la tentation d'une allégation clinique est plus forte | Un des cinq livrables de The Fill manque. |
| **L13** | **L'Ethics Guard sur les nouveaux types** | `enforceEthics` couvre page de site, post Google, profil PT, one-page ; un scan **dans** `site_spec_patch` et `update_content_item` ; `usp_banned_phrases_check` appelée sur toutes les sorties d'annuaire ; `anon` révoqué sur les RPC d'écriture, avec un test d'énumération | L2 | **3** | **moyen** | ⚠ **Une page de site écrite par un modèle et posée via `site_spec_patch` saute la garde entièrement.** Un board d'État lit une promesse de résultat publiée par Eklio sur le site d'une licenciée. C'est le risque qui coûte une licence, pas un client. |
| **L14** | **Les connexions CMS** | table `site_connections`, secrets chiffrés au repos, états, **révocation**, écran de connexion, le premier secret par utilisateur du produit | L5 | **5** | **⚠ élevé** — aucun précédent : `app_settings` est en clair, aucun coffre n'est utilisé | Rien ne peut être publié. **Bloque L15, L16 et tout The Fill.** |
| **L15** | **Publication WordPress** | `POST /wp-json/wp/v2/pages`, `remote_id` stocké, mise à jour idempotente sur cet id, erreurs lisibles | L14, L17 | **5** | **moyen** — l'API est stable et documentée ; le risque est la diversité des installations (permaliens, plugins de sécurité, REST désactivée) | « Publiées par Eklio » est faux. L'offre figée n'est pas tenue. |
| **L16** | **Publication Squarespace** | idem, **si L0 dit que c'est possible** | L0, L14, L17 | **6 ou 0** | **⚠ le plus élevé du chantier** — voir la première page | Soit une moitié du marché est refusée à l'inscription, soit on a promis ce qu'on ne peut pas faire. |
| **L17** | **La file de travaux durable** | table de travaux (`kind`, `subject`, `period`, `state`, `attempts`, `next_attempt_at`, `last_error`), **unique `(kind, subject, period)`**, rejeu borné, état terminal, lettre morte, curseur de lot | L2 | **5** | **moyen** | Sans elle, une publication qui échoue reste en cours pour toujours — ce que fait déjà `content_months` en état `generating`. Et le balayage mensuel ne tient pas dans les 300 s de Vercel dès la dixième abonnée. |
| **L18** | **Le cycle mensuel de The Fill** | le cron armé et planifié ; une page par mois par abonnée, une fois et une seule ; le rafraîchissement trimestriel du profil PT ; la distinction dû / produit | L10, L13, L15, L17 | **4** | **moyen** | The Fill ne livre rien. C'est le revenu récurrent de toute l'offre. |
| **L19** | **Brancher la tenancy sur les policies** | `owns_project` appelle `is_org_member` ; les 19 policies « shape A » à une feuille près ; les 14 « shape B » cessent de comparer un `user_id` dénormalisé ; une RPC de retrait de clinicienne | L2 | **5** | **⚠ élevé** — 33 policies, de l'isolation de données, et **le chemin d'invitation n'a jamais été parcouru par une donnée réelle** (3 membres, tous `owner`, 0 invitation) | The Roster ne peut pas exister : une clinicienne activée ne voit le kit de personne, et personne ne voit le sien. |
| **L20** | **L'abonnement facturé au siège** | `subscriptions` gagne `organization_id` et `quantity`, l'unicité se déplace, le webhook lit `items.data[0].quantity`, la proration s'appuie sur la quantité | L3, L4, L19 | **4** | **⚠ élevé** — ⚠ **le droit d'abonnement n'a aujourd'hui aucune autorité SQL** : la règle (statuts + grâce de 3 jours sur `past_due`) vit uniquement en TypeScript. Ce lot la multiplie par le nombre de sièges. **Descendre la règle en base fait partie du lot.** | The Fill cabinet ne peut pas être facturé. |
| **L21** | **Le pack à l'embauche** | l'invitation incrémente la quantité ; l'acceptation déclenche la production du pack complet ; l'ajout et le retrait bougent la facture | L19, L20 | **2** | **moyen** — deux moments distincts, et le second peut ne jamais venir (une invitation non acceptée) | La promesse « pack complet inclus à chaque nouvelle embauche » est tenue à la main, ou pas tenue. |
| **L22** | **Les chiffres PT et le rapport en delta** | table `directory_metrics` (unique `(sujet, plateforme, période)`), RLS propriétaire, RPC de delta, écran de saisie, rappel mensuel, **état « mois non relevé »** | L19 (pour le sujet clinicienne) | **3** | **faible** — ⚠ **ne pas mettre ça dans `funnel_events`** : rétention 180 j, purgée tous les jours, illisible par la cliente, aucune unicité par période | Le cinquième livrable de The Fill manque — et c'est **celui qui justifie le renouvellement chaque mois**. |
| **L23** | **Retirer l'offre morte de la vente** | l'abonnement Instagram sort du catalogue ; l'identité devient l'add-on 89 $ ; les surfaces se re-câblent. **Rien n'est supprimé en base.** | L3, L4 | **2** | **faible** — ⚠ **ne pas jeter avec** : `subscriptions` + l'essai de 90 jours + le préavis + la garde d'essai (The Fill s'y rebranche) ; le motif d'unicité `(kit, mois)` ; l'imagerie, qui sert l'add-on | On vend encore quelque chose qu'on ne produit plus, ou on supprime la mécanique d'essai la plus mûre du produit. |

**Total, publication comprise et Squarespace inclus : ≈ 76 jours.**
Sans Squarespace (L16 à zéro) : ≈ 70 jours.
Sans publication du tout (L14, L15, L16 retirés, verbe changé) : ≈ 54 jours.

---

## Le chemin critique — vendre The Foundation à une première cliente solo

**La séquence minimale, et rien de plus.** Pas de cabinet, pas de The Fill, pas de comparatif de
zone, pas d'add-on.

| ordre | lot | pourquoi il est dans le minimum |
|---|---|---|
| 1 | **L0** — trancher Squarespace | décide qui on accepte à l'inscription. Une demi-journée qui change le reste. |
| 2 | **L1** — le droit à une seule source | un défaut **actif** sur l'argent, et le lot suivant le multiplie |
| 3 | **L3** — le SKU Foundation 390 $ | sans lui, rien n'est encaissable |
| 4 | **L5** — qualification de plateforme | sans elle, on encaisse une promesse qu'on ne peut pas tenir |
| 5 | **L8** — la phrase de positionnement | livrable 1. **Petit** : l'écran existe. |
| 6 | **L9** — le profil PT rédigé | livrable 2 |
| 7 | **L10** — ouvrir l'enum de pages | livrable 3 (accroche + 3 pages) tient tout juste sans, mais la treizième page de The Fill ne tient pas — et le faire deux fois coûte plus cher |
| 8 | **L11** — le texte de fiche Google | livrable 4 |
| 9 | **L13** — l'Ethics Guard sur les nouveaux types | la seule garde qui protège une licence |
| 10 | **L14** — les connexions CMS | « publiées par Eklio » |
| 11 | **L15** — publication WordPress | idem |

**≈ 32 jours** avec la publication automatique sur WordPress.
**≈ 22 jours** si la première cliente est publiée à la main et qu'on l'assume **comme une exception
nommée**, pas comme le produit.

**Ce qui n'est PAS dans le chemin critique, et qui peut attendre :** L2 (mais on le paiera),
L4, L6, L7, L12, L16 à L23.

⚠ **L2 mérite une phrase.** La suite de tests au vert n'est pas dans le chemin critique parce
qu'elle ne livre rien à la cliente. Elle y est dans les faits parce que les onze lots ci-dessus
touchent des policies, des contraintes de tier et de l'argent, et qu'une suite qui est déjà rouge ne
dira rien quand l'un d'eux la casse. **Trois jours pour retrouver un signal, ou aucun signal pendant
trente-deux jours.**

---

## Ce que je ne sais pas

**1. Squarespace publie-t-il une API de création de pages ?** `INFERRED` que non. C'est la seule
inconnue qui peut rendre un point de l'offre irréalisable. **Pour trancher :** une demi-journée sur
la documentation développeur en vigueur et un compte d'essai. Rien d'autre.

**2. La suite de tests backend est-elle toujours à douze rouges ?** Le relevé date du 11 septembre
(`TENANCY.md` §10.7) ; cette session est en lecture seule et n'a rien exécuté. **Pour trancher :**
un `supabase db reset` + la suite, une heure. Le chiffre décide si L2 coûte 3 jours ou 1.

**3. Stocke-t-on le texte que la cliente colle ?** The First Line suppose que oui — sinon il n'y a
ni diagnostic à relire, ni base pour le profil complet. Mais `lib/check/review.ts` porte une
décision explicite et motivée : *« HER TEXT IS NEVER STORED »*, ni en table, ni en log, ni en
propriété analytique. **C'est une décision de produit et de confidentialité, pas une inconnue
technique**, et elle doit être prise par la propriétaire avant L6. Elle change la rédaction de la
politique de confidentialité.

**4. Que devient une clinicienne retirée ?** Son kit, son profil PT publié, les pages qu'Eklio a
posées sur le site du cabinet. `TENANCY.md` §12 porte trois décisions de charte en prose, et
**aucune** ne traite du retrait. Le statut `removed` est dans le CHECK et rien ne sait le poser.
**Pour trancher :** une décision de la propriétaire, pas une mesure.

**5. Quel volume par mois ?** Le dimensionnement de L17 et L18 — taille de lot, cadence, budget de
modèle — dépend du nombre d'abonnées visé à 6 et 12 mois. `maxDuration = 300` est la contrainte dure.
**Pour trancher :** un objectif commercial.

**6. Combien de pages The Fill produit-il en douze mois, et sur quelles requêtes ?** Douze pages par
an et par cliente, écrites sur des requêtes-patients d'une même zone, finiront par se marcher
dessus. Le dépôt a **déjà l'outil** (`usp_check_distinct`, `usp_fingerprints`,
`app_settings.usp_similarity_threshold` = 0,55) mais il ne porte aujourd'hui que sur la phrase de
positionnement. **Pour trancher :** une mesure, une fois qu'il existe une douzaine de pages réelles.

**7. Le comparatif de zone est-il tenable ?** L7 suppose une source de données sur les profils
Psychology Today d'une zone. Il n'y en a aucune dans les deux dépôts. Coût, fraîcheur, et conditions
d'utilisation de la source sont **tous inconnus**, et c'est pourquoi L7 est à 5 jours avec un risque
élevé plutôt qu'à 2. **Pour trancher :** choisir la source d'abord.

---

## Ce que je ferais en premier si je n'avais qu'une semaine

**Cinq jours, dans cet ordre. Le but de la semaine n'est pas de livrer l'offre : c'est de rendre les
huit semaines suivantes possibles et d'en retirer les deux inconnues qui peuvent tout changer.**

**Jour 1, matin — L0.** Trancher Squarespace. C'est la seule question dont la réponse peut
supprimer six jours de plan ou faire changer une phrase de l'offre. Une demi-journée de lecture.

**Jour 1, après-midi — L1.** `resolveEntitledTier` et `countUnpaidProjects` lisent
`brand_kit_entitling_statuses()`, avec un test qui épingle la liste des deux côtés. C'est un défaut
**actif** sur de l'argent, il tient dans un après-midi, et il ne fera que grossir quand L3 ajoutera
quatre SKU.

**Jours 2 et 3 — L2.** La suite de tests. Douze fichiers rouges, diagnostiqués un par un. Ce n'est
pas le lot qu'on a envie de faire en premier et c'est celui qui décide si les huit semaines
suivantes ont un filet. Le dépôt a déjà appris cette leçon une fois : une énumération de la surface
de fonctions écrite avec soin n'avait **jamais tourné en CI**, et personne ne le savait.

**Jour 4 — L8, entièrement.** La phrase de positionnement. **C'est un petit lot** : l'écran, les
gardes, le contrôle d'unicité et les trente clichés d'annuaire existent déjà ; il faut recadrer le
prompt sur les mots des patients plutôt que sur une USP de marque. Un livrable complet de The
Foundation en une journée, et la preuve que le moteur tient la nouvelle offre.

**Jour 5 — le début de L9, et une décision.** Ouvrir le gabarit du profil Psychology Today
**en refusant la concaténation SQL dès la première ligne** — c'est exactement l'assemblage de champs
souvent absents qui a déjà fait disparaître trois lignes d'un livrable payant, en silence. Et poser
à la propriétaire les deux questions qui bloquent la suite : **stocke-t-on le texte collé** (§3
ci-dessus), et **que devient une clinicienne retirée** (§4). Toutes deux sont des décisions, pas des
mesures, et toutes deux bloquent un lot chacune.

**Ce que je ne ferais pas cette semaine :** toucher à la publication. L14 est à cinq jours et
dépend de L0 et de L5 ; commencer par elle veut dire écrire un coffre à secrets avant de savoir pour
quelles plateformes.
