# LOT1_REPORT.md — rendre The Foundation produisible

Lot 1 d'implémentation de l'offre du 13 septembre. Branche `claude/foundation-lot1` dans les deux
dépôts, un commit par lot.

---

## ⚠ LE CHIFFRE DE L2, EN TÊTE

C'est le seul chiffre qui dit si les semaines suivantes ont un filet.

| | |
|---|---|
| **Mesuré au début de L2** | **78 fichiers rejoués, UN rouge**, plus le contrôle des miroirs de seed en échec |
| **Le relevé qui circulait** | douze rouges, daté du 11 septembre |
| **À la fin de la session** | **81 fichiers, 0 rouge**, miroirs alignés |

**Douze était un chiffre de mardi, pas un état.** Les commits des 12 et 13 septembre l'avaient
largement rattrapé sans que personne recompte. Le cahier demandait de mesurer avant de réparer ;
c'est ce qui a fait apparaître l'écart.

**Et les deux échecs restants ne disaient rien sur le produit** — voir L2 ci-dessous.

Côté frontend : **2480 tests verts au départ, 2626 à l’arrivée**, jamais rouges entre deux lots.

---

## Ce qui a été livré

Dix lots. ⚠ Le cahier annonce « neuf lots » et en liste dix (L1, L2, L3, L4, L5, L8, L9, L10, L11,
L13) — les dix ont été faits ; le décompte est signalé dans `DECISIONS_NEEDED.md` §8.

| Lot | Livré | Acceptation |
|---|---|---|
| L1 | Le droit remis à une seule source | ✅ |
| L2 | Suite au vert | ✅ |
| L3 | Les six SKU | ✅ |
| L4 | L'achat qui n'est pas un palier | ✅ |
| L5 | Qualification de plateforme | ✅ |
| L8 | La phrase de positionnement | ✅ *(voir la réserve)* |
| L9 | Le profil Psychology Today | ✅ |
| L10 | L'enum de pages ouvert | ✅ |
| L11 | Fiche Google : texte et posts | ✅ |
| L13 | L'Ethics Guard dans l'écriture | ✅ |

**Sept migrations**, toutes **appliquées au projet vivant puis revérifiées contre lui**, jamais
contre le fichier.

---

## L1 — Remettre le droit à une seule source

**Fait.** `resolveEntitledTier` et `countUnpaidProjects` lisent `ENTITLING_STATUSES`, qui transcrit
`brand_kit_entitling_statuses()`. La constante a **remonté** au-dessus de ses lecteurs : elle était
déclarée sous eux, et une constante déclarée loin de ses lecteurs est une constante qu'on réécrira
à la main — ce qui s'était produit.

**Ce que le défaut faisait** : une acheteuse partiellement remboursée avait son kit **ouvert** (la
base le disait) et se voyait refuser en 402 toutes les surfaces au-dessus de `starter`, sur un
écran lui proposant d'acheter ce qu'elle avait déjà.

**Vérifié comment** :
- `lib/billing/__tests__/entitlements-single-source.test.ts` — un faux client **enregistre**
  l'argument réellement passé à `.in("status", …)` et **lève** si une lecture revient à
  `.eq("status", …)`. Une constante juste que personne ne lit était le défaut ; un test qui n'aurait
  lu que la constante l'aurait laissé passer.
- `supabase/tests/20260914090000_entitling_statuses_single_source.test.sql` — écrit la valeur en
  clair, puis **parcourt le chemin** : un achat `partially_refunded` est écrit et c'est
  `brand_kit_entitled` qui répond. **Vérifié en négatif** : l'achat passé à `refunded` fait tomber
  l'assertion.

**Acceptation** : ✅ une commande partiellement remboursée ouvre le même palier des deux côtés.

**Ouvert** : `countUnpaidProjects` compte un projet adossé à un add-on comme payé — sémantique
existante, signalée dans `OUT_OF_SCOPE.md` §21.

---

## L2 — Remettre la suite au vert

**Mesuré d'abord**, comme demandé. Les deux échecs :

**1. Le rouge était dans le HARNAIS, pas dans le produit.** `auth.uid()` du stub local
(`scripts/local-verify-stub-schema.sql`) était une paraphrase de la vraie : elle gardait le `sub`
*extrait*, la vraie garde le *réglage*. Un GUC personnalisé qui a été `set local` une fois revient,
au rollback, à la chaîne vide — `''::jsonb` lève, **à l'intérieur de la policy qui posait la
question**. Live, le `nullif` l'absorbe. D'où un test rouge en local et vert en production.
Les deux fonctions sont désormais **copiées verbatim** depuis le projet vivant.

**2. Le miroir était un vrai défaut du dépôt.** Le bloc `CHECK REWRITE LIMIT` de
`20260909094038` porte la balise « mirrored verbatim in supabase/seed.sql » et **n'y était pas**.
C'est le piège que `check_seed_mirrors.sh` a été écrit pour attraper. Il l'a attrapé.

Et la réplication mourait avant tout ça : le stub n'avait pas de schéma `extensions`, que
`20260911195907` appelle par son nom qualifié.

**Acceptation** : ✅ 81 fichiers, 0 rouge. **Aucun comportement produit n'a changé dans ce lot.**

**⚠ Réserve honnête** : le harnais local n'est pas la CI. `db-tests.yml` tourne contre un vrai
stack Supabase via Docker, indisponible ici. Les correctifs du stub ne changent donc rien à la CI ;
le correctif du miroir, si.

---

## L3 — Les nouveaux SKU

**Six SKU en base et dans les constantes**, aux prix arrêtés. `plans` gagne quatre colonnes, parce
que `price_cents` seul mentait sur quatre des six : `kind`, `billing_period`, `per_seat`,
`included_seats`.

**Les allocations n'existent que là où elles veulent dire quelque chose.** `directions_limit` et
`regenerations_limit` deviennent nullables : sur un abonnement elles n'ont aucun sens, et
`consume_generation_credit` **échoue fermé** sur leur absence par le `if v_per_run is null then
return false` qui existait déjà — aucune branche nouvelle.

**⚠ La sonde a trouvé ma propre contrainte fausse, à la première exécution.** Écrite en
équivalence, elle laissait passer un abonnement à qui on posait **une seule** des deux allocations
(`false = false`). Remplacée par un `case`, et la sonde couvre maintenant les deux cas. C'est
exactement pourquoi l'auto-contrôle **tente l'écriture** au lieu de relire la définition.

Côté application, **trois listes qui disent trois choses**, chacune miroir d'un CHECK :
`KIT_TIERS` ≡ `brand_kits.tier`, `PURCHASABLE_SKUS` ≡ `purchases.tier`, `OFFER_SKUS` ≡ `plans.tier`.

**Acceptation** : ✅ les six existent des deux côtés ; `offer-catalogue.test.ts` vérifie que chaque
SKU a une variable d'environnement déclarée, qu'aucune n'est partagée, et qu'aucune ne l'est entre
l'offre précédente et la nouvelle.

**Ouvert** : `ORDERED_PLANS` reste sur les trois paliers vendus — itérer `KIT_TIERS` aurait ajouté
deux colonnes à la page de tarifs à mi-chantier. Le basculement appartient à L23.

---

## L4 — L'achat qui n'est pas un palier

`purchases.kind ∈ {tier, addon, seat}`. `resolveEntitledTier` filtre `kind = 'tier'` ;
`hasPurchasedAddon` répond à l'autre question.

**Un trigger, pas un CHECK**, et c'est le cœur du lot : un CHECK ne peut pas interroger une autre
table, donc dire « `identity_addon` est un `addon` » dans un CHECK voudrait dire recopier
`plans.kind` en **quatrième liste**. Le trigger lit `plans`, qui fait autorité.

**⚠ `parseKitTier` écartait déjà l'add-on** — accident heureux, pas règle. Le jour où un SKU est
nommé comme un palier, la protection disparaîtrait sans qu'un test bouge. D'où le filtre explicite,
et un test qui vérifie **que le filtre part vers la base** au lieu de constater le résultat.

**Vérifié comment** : la sonde écrit une ligne sans `kind` (qui prend `tier` par défaut) et exige
qu'elle soit refusée. Deux choses trouvées en exécutant : poser l'organisation de la sonde à la
main violait `organization_members_one_owned_org_per_user`, et **l'énumération de la surface de
fonctions a rougi** — ma fonction de trigger était atteignable depuis le navigateur.

**Acceptation** : ✅ l'add-on ne change aucun palier et l'achat est mesurable en base.

---

## L5 — Qualification de plateforme

**Trois états, pas deux** : `accepted` / `conditional` / `refused`. Deux auraient forcé à ranger
Squarespace du côté d'une réponse qu'on n'a pas.

`lib/brief/platform.ts` **ne contient aucun nom de plateforme**, et un test lit le fichier source
pour s'en assurer — un `if (id === "squarespace")` glissé plus tard donnerait le même comportement
jusqu'au jour où la base change d'avis.

**La question est à l'étape 1, pas à la 7.** L'étape 7 était le lieu naturel mais elle est
facultative : la question s'y serait sautée, et refuser quelqu'un après cinq écrans de travail est
la forme même de ce que ce dépôt refuse ailleurs.

Un refus se **compte**, dans une table dédiée et pas dans `funnel_events` — purgée à 180 jours et
illisible hors `service_role`, alors que la question (« combien refusons-nous, pour quelle
plateforme ») se pose sur des trimestres.

**Deux gardes ont rougi et les deux avaient raison** : `record_platform_refusal` était SECURITY
DEFINER anon-appelable sans contrôle dans le corps (elle a maintenant `owns_project`, qui empêche
d'agrafer un refus au projet d'une autre), et `site_platforms` a dû être inscrite au registre de
tenancy **avec sa raison**.

**Acceptation** : ✅ changer la liste est un UPDATE ; un refus est enregistré et compté.

---

## L8 — La phrase de positionnement

**Deux des trois angles étaient exactement ce que l'offre interdit** : `population` était la
démographie, `method` était la modalité. Les renommer n'aurait rien changé — c'est ce qu'ils
demandaient au modèle d'écrire qui était devenu faux.

Trois angles recadrés (`presenting_problem`, `the_moment`, `what_keeps_returning`), **et une
cinquième gate**, parce que le prompt ne suffit pas : un modèle à qui on interdit « EMDR » écrit
« une approche fondée sur le retraitement des souvenirs ». C'est la leçon déjà écrite dans
`lib/check/rewrite.ts` sur les garanties.

**Aucune liste universelle de modalités** : la gate compare la phrase à ce qu'**elle** a coché, et
dérive l'acronyme du libellé long. Un test lit le fichier source pour vérifier qu'aucune thérapie
n'y est nommée.

La gate passe **avant** la spécificité : celle-ci récompense un candidat qui reprend un élément du
brief, et le moyen le plus facile d'y arriver est de citer une modalité qu'elle a cochée.

**Les anciens angles restent lisibles** — des briefs les portent, et les refuser ferait échouer la
prochaine écriture sur une colonne que personne n'a touchée.

**Acceptation** : ⚠ **partielle, et il faut le dire.** Le recadrage est en place et le contrôle
d'unicité tourne (inchangé). Mais « sur trois briefs d'essai, la sortie nomme un problème tel qu'un
patient le décrirait » **n'a pas été mesuré** : il faut une clé Anthropic et trois briefs réels, et
cette session n'a jamais appelé de modèle. Ce qui est vérifié est déterministe : les angles, le
prompt, et la gate qui refuse une modalité ou un segment.

---

## L9 — Le profil Psychology Today

**Les champs structurés d'un côté, la prose de l'autre**, et le premier paragraphe est une
**colonne** — pas « le texte jusqu'au premier saut de ligne ». C'est lui qu'on réécrira seul dans
The First Line et qu'on rafraîchira à la saison ; le découper à la lecture, c'est le redécouper
différemment à chaque lecteur.

**⚠ Aucune concaténation SQL de champs optionnels.** La table ne compose rien ; la composition vit
dans `lib/directory/profile.ts`, et **le test qui la garde lit le fichier source** — il refuse
`.join(`, un littéral de gabarit et une concaténation de littéraux. Un test de comportement
n'attraperait une composition fautive qu'avec la combinaison précise de champs absents qui la
déclenche : c'est-à-dire peut-être jamais, ce qui est exactement comment trois lignes ont disparu
d'un livrable payant.

Le validateur refuse une **chaîne vide dans une liste** — la forme que prend un champ optionnel
tombé sans que personne ne l'ait traité. Une clé absente, elle, est permise.

**Acceptation** : ✅ le cas « tous les champs optionnels vides » produit un profil valide, sans
perte silencieuse ; le premier paragraphe est récupérable seul, vérifié par `get_directory_profile`.

---

## L10 — Ouvrir l'enum de pages

**Le recensement d'abord**, interrogé sur `pg_proc` et pas deviné : quatre fonctions nomment une
clé de page ou lisent la source, plus une donnée (`section_types.allowed_pages`).

`site_spec_page_keys()` lit désormais `site_pages`. **IMMUTABLE → STABLE** pour elle et pour
`site_spec_pages_valid` : une fonction qui lit une table en se déclarant IMMUTABLE ment au
planificateur, qui la croit et met son résultat en cache — la page ajoutée resterait refusée, sans
erreur.

**La preuve d'ouverture est faite en ajoutant une page et en écrivant**, pas en relisant la
définition. Le test va jusqu'à **treize pages**, qui est le cas de The Fill après un an, et porte
un **canari** : une règle qui a cessé de correspondre à quoi que ce soit ressemble exactement à une
règle satisfaite.

`site_spec_default_pages` garde sa liste — c'est un **semeur**, et « quelles pages peuvent
exister » n'est pas « par quelles pages on commence ». Ce qu'on exige d'elle est que les pages
qu'elle sème existent, et c'est vérifié.

**Acceptation** : ✅ ajouter une clé est une insertion ; aucun validateur ne détient de liste en
dur ; la suite est verte.

**⚠ La limite du recensement est dite** : il cherche des littéraux, et deux types de section
s'appellent `contact` et `services` comme deux clés de page (`OUT_OF_SCOPE.md` §19).

---

## L11 — Fiche Google : texte et posts

`stepTextBlocks` faisait tomber `update_directory` et `google_profile` sur le même `push` : la
fiche Google recevait **mot pour mot** le bloc de Psychology Today. Séparés, et un test compare les
deux sorties plutôt que de croire le commentaire.

**L'archétype Google n'a pas d'image, et c'est une contrainte.** Rien ne l'obligeait au niveau du
schéma ; l'obligation vivait dans la pipeline. Une convention tenue par du code est une convention
qu'un deuxième appelant ignore.

**La borne de description est celle de la plateforme** : 750 pour Google, 1200 pour Psychology
Today, dans le même CHECK. Une seule borne pour les deux voudrait dire qu'un des deux textes est
coupé sur une page publique.

**⚠ Le typage a fait le recensement.** Refuser un plancher d'image à `google_post` a listé les
quatre endroits qui supposaient que tout archétype en porte un. Ils sont narrowés au type qui dit
vrai.

**Acceptation** : ✅ les deux textes sont produits séparément et diffèrent.

---

## L13 — L'Ethics Guard dans l'écriture

**⚠ Le seul lot dont l'absence coûte une licence professionnelle à une cliente.**

Les dix-neuf motifs deviennent une **donnée**, à côté de `ethics_rules` et `banned_phrases`.
Un **trigger**, pas une ligne dans la RPC : `site_spec_patch` n'est pas le seul écrivain possible
de `site_specs`, et un garde qu'il faut penser à appeler est un garde qu'on oubliera.

### ⚠ Ce lot a trouvé un défaut du produit, et pas dans ce que j'ai écrit

`ethics_rules.scarcity.example_forbidden` vaut **« Limited spots available. »** — la phrase que le
produit **montre** à la praticienne pour lui dire ce qui est interdit. **Ni le motif TypeScript ni
sa traduction ne l'attrapaient** : les deux exigeaient « only N spots left » ou « limited-TIME
offer ». Le produit affichait une règle qu'il ne faisait pas respecter, et **aucun test ne posait
la question**. Corrigé des deux côtés, ensemble.

### Et trois défauts dans ce que j'ai écrit, tous trouvés en exécutant

1. `substring(… from …)` est **sensible à la casse** là où `~*` ne l'est pas. « Heal your
   anxiety » était détecté et son extrait valait NULL — et `ethics_blocks` lisait cette nullité
   comme « pas de violation ». **La garde laissait passer une promesse de résultat.** C'est
   littéralement « une valeur qui disparaît sans erreur », écrite par moi, dans le lot dont c'est
   le sujet.
2. `substring` rend le **premier groupe de capture**. L'extrait montré à la praticienne pour
   `\yguarantee(s|d|ing)?\y` était « d ».
3. **`revoke … from anon` seul ne fait rien** : toute fonction naît avec EXECUTE accordé à PUBLIC
   et `anon` en est membre. Cinq REVOKE ont réussi sans rien changer.

L'énumération a aussi exigé que `ethics_scan` **cesse d'être SECURITY DEFINER**. La bonne réponse
n'était pas d'ajouter un contrôle d'autorité mais de retirer l'élévation.

**Acceptation** : ✅ une page de site posée avec une promesse de résultat est refusée, et le test le
prouve — dans `about_excerpt` **et** dans un champ de section, qui est le chemin de
`site_spec_patch`. Vérifié en live : 19 motifs, 0 exemple non bloqué, `anon` fermé sur les cinq
RPC, `authenticated` intact.

**⚠ Reste ouvert** : **deux implémentations de la même garde coexistent maintenant.** C'est une
dette créée par ce lot, tenue en attendant par un corpus partagé vérifié des deux côtés.
`OUT_OF_SCOPE.md` §17.

---

## L'état à la fin

| | |
|---|---|
| **Backend** | 81 fichiers de test, 0 rouge, miroirs de seed alignés, réplication propre depuis zéro |
| **Frontend** | 132 fichiers, 2626 tests, 0 rouge ; `eslint` propre ; `tsc` sans erreur nouvelle |
| **Base vivante** | 7 migrations appliquées et revérifiées contre elle |
| **Supprimé en base** | rien |
| **Dépendances ajoutées** | aucune |

**Ce qui reste ouvert est dans les trois autres fichiers** : `OUT_OF_SCOPE.md` (22 entrées, chacune
avec son lot propriétaire), `DECISIONS_NEEDED.md` (8 décisions, chacune avec ce qui est en place
aujourd'hui) et `ENV_REQUIRED.md` (10 variables, chacune avec le SKU qu'elle porte).

⚠ **Deux choses ne doivent pas être mises en vente avant leur lot** : la clinicienne
supplémentaire à 120 $ ne déclenche aucun pack (L21), et les deux prix par siège ne sont pas
facturables tant que `subscriptions` n'a pas de `quantity` (L20).
