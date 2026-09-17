-- ============================================================================
-- La réponse sur Squarespace
-- ============================================================================
-- `20260914120000_platform_qualification.sql` a écrit, en tête de fichier :
--
--   « La question "Squarespace expose-t-il une API de création de pages" n'est
--     PAS TRANCHÉE. Elle le sera par une demi-journée de lecture de
--     documentation, et ce jour-là la réponse doit coûter un UPDATE. »
--
-- Voici le UPDATE. La question a été instruite le 14 septembre 2026, et
-- l'enquête entière — sources, dates, ce qui a échoué, et ce qui renverserait
-- le verdict — est dans `SQUARESPACE_VERDICT.md` à la racine.
--
-- ── LA RÉPONSE ──────────────────────────────────────────────────────────────
--
-- Non. La Developer Platform de Squarespace n'expose pas d'API de création de
-- pages de contenu. Toute sa surface documentée est rangée sous un seul
-- segment — `commerce-apis` — et les permissions qu'une clé peut porter sont
-- Orders, Forms, Inventory, Transactions. Aucune ne touche au contenu. Les
-- douze paquets npm que Squarespace publie sous `@squarespace` sont de
-- l'outillage de GABARITS, sans client d'API ni point d'entrée d'écriture.
--
-- ⚠ CE QUI AFFAIBLIT LE VERDICT, ET QUI DOIT ÊTRE ÉCRIT ICI AUSSI. La
-- documentation développeur elle-même n'a pas pu être lue : cet environnement
-- bloque le domaine `squarespace.com` entier au niveau du tunnel CONNECT. Le
-- verdict est établi par CONVERGENCE de cinq sources indépendantes, dont deux
-- émanent de Squarespace — il n'est pas ATTESTÉ à la source.
--
-- Pourquoi trancher quand même, plutôt que laisser `conditional` : le `notice`
-- en place dit à la cliente qu'on est *en train de vérifier*. On a vérifié.
-- Continuer à l'afficher serait désormais faux. Et les deux erreurs ne coûtent
-- pas la même chose — refuser à tort renvoie une cliente qu'on aurait pu
-- servir, et `platform_refusal_counts()` la COMPTE, donc l'erreur se voit et se
-- chiffre ; accepter à tort encaisse un paiement pour une publication
-- impossible. Le sens du doute va vers le refus.
--
-- ── CE QUE CETTE MIGRATION NE FAIT PAS ──────────────────────────────────────
--
-- Elle ne supprime rien. La ligne `squarespace` reste au catalogue, visible et
-- expliquée, comme Wix et Webflow : une praticienne dont la plateforme est
-- NOMMÉE comprend qu'on l'a envisagée. Le jour où la réponse change, c'est de
-- nouveau un UPDATE sur cette même ligne.
-- ============================================================================

-- >>> SQUARESPACE VERDICT (mirrored verbatim in supabase/seed.sql) >>>

-- ⚠ UN UPDATE, PAS UN INSERT ... ON CONFLICT. La ligne existe depuis
-- `20260914120000` et ce bloc ne fait que changer d'avis sur elle. Réécrire la
-- ligne entière ici en ferait une seconde source pour son `label` et son
-- `sort_order` — exactement la divergence que ce dépôt paie déjà ailleurs.
--
-- Le `notice` est la phrase que la visiteuse LIT. Elle est calquée sur celles
-- de Wix et de Webflow, à un mot près : le nôtre ne dit pas « yet ». « Pas
-- encore » serait une promesse implicite, et il n'y a rien à attendre — il n'y
-- a pas d'API à laquelle se brancher.
update public.site_platforms
   set status = 'refused',
       notice = 'We do not publish to Squarespace. Its API covers store orders and forms, not website pages, so there is no way for us to put anything on your site for you. Everything we write for you would still be yours to paste, but putting it in place is the part we could not do.'
 where id = 'squarespace';

-- <<< SQUARESPACE VERDICT <<<
