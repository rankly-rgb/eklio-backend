-- ============================================================================
-- UN POST SAIT QUEL DESSIN IL PORTE (2026-11-01)
-- ============================================================================
--
-- La bibliothèque de visuels (eklio-frontend, `assets/visual-library/`) entre
-- dans le moteur : le dessin d'une carte est choisi PAR LE SENS du post
-- (`lib/visual-library/match.ts`), pour tout le mois d'un coup, et jamais le
-- même à moins de dix posts d'écart. Ce choix dépend du mois entier — il ne se
-- recalcule pas post par post à la relecture.
--
-- Il faut donc l'écrire. Sans cette colonne, l'écran de relecture et la route de
-- téléchargement recomposeraient la carte avec le dessin fait main de
-- l'archétype : la praticienne verrait une carte, en téléchargerait une autre.
--
-- ── CE QUI EST AJOUTÉ, ET RIEN D'AUTRE ─────────────────────────────────
--
-- `content_items.illustration_key` — l'identifiant d'un dessin de la
-- bibliothèque, ou NULL (un post écrit avant elle, ou écrit à la main : l'écran
-- garde alors le dessin de l'archétype).
--
-- ⚠ PAS DE CLÉ ÉTRANGÈRE. La bibliothèque vit dans le dépôt du frontend (un
-- inventaire généré à partir des fichiers), pas en base. La forme est vérifiée ;
-- l'existence l'est par le moteur, qui refuse un identifiant inconnu.
--
-- ⚠ NI `update_content_item` NI `content_item_json` NE LA TOUCHENT. Elle est
-- écrite à la génération (service_role) et lue par le serveur ; la cliente ne
-- choisit pas son dessin dans cette version.
-- ============================================================================

alter table public.content_items
  add column if not exists illustration_key text;

alter table public.content_items drop constraint if exists content_items_illustration_key_shape;
alter table public.content_items add constraint content_items_illustration_key_shape
  check (illustration_key is null or illustration_key ~ '^[a-z0-9]+(-[a-z0-9]+)*$');

comment on column public.content_items.illustration_key is
  'The visual-library drawing this card carries, chosen by meaning for the whole month at generation (eklio-frontend lib/visual-library). NULL: written before the library, or by hand — the screen keeps the archetype''s hand-drawn figure.';

-- ============================================================================
-- Rollback
-- ============================================================================
--   alter table public.content_items drop constraint if exists content_items_illustration_key_shape;
--   alter table public.content_items drop column if exists illustration_key;
