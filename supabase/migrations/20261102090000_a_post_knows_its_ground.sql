-- ============================================================================
-- UN POST SAIT SUR QUEL FOND IL EST POSÉ (2026-11-02)
-- ============================================================================
--
-- Spécification visuelle du 2 novembre 2026 : cinq familles de fond — crème,
-- photo noir et blanc, teinte secondaire pleine (« ocre »), teinte primaire
-- pleine (« terracotta »), fond profond. Le fond se décide À L'ÉCHELLE DU MOIS
-- (eklio-frontend `lib/content/month/grounds-plan.ts`) : le rythme clair /
-- sombre se lit sur la grille de neuf vignettes, pas sur une carte.
--
-- Il dépend donc du mois entier et ne se recalcule pas post par post à la
-- relecture : sans cette colonne, l'écran et le téléchargement recomposeraient
-- la carte sur un autre fond que celle qui a été gardée.
--
-- ⚠ NI `update_content_item` NI `content_item_json` NE LA TOUCHENT. Écrite à la
-- génération (service_role), lue par le serveur.
-- ============================================================================

alter table public.content_items
  add column if not exists card_ground text;

alter table public.content_items drop constraint if exists content_items_card_ground_known;
alter table public.content_items add constraint content_items_card_ground_known
  check (card_ground is null or card_ground in ('cream', 'photo', 'ochre', 'terra', 'deep'));

comment on column public.content_items.card_ground is
  'The background family the month plan gave this card (cream, photo, ochre, terra, deep), decided over the whole month at generation (eklio-frontend lib/content/month/grounds-plan.ts). NULL: written before the families.';

-- ============================================================================
-- Rollback
-- ============================================================================
--   alter table public.content_items drop constraint if exists content_items_card_ground_known;
--   alter table public.content_items drop column if exists card_ground;
