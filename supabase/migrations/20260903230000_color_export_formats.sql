-- ============================================================================
-- Eklio — asset_catalog: palette_ase, tokens_json, colors_css (Lot 4.4)
-- ============================================================================
-- The six colour roles plus the four derived contrast-safe variants, in
-- three formats a designer/developer would actually reach for. Pure data
-- transforms of the kit's own tokens — no satori/resvg involved, and no new
-- kind: `ase` and `json`/`css` were already added by
-- 20260903210000_asset_catalog_kind_expansion.sql.
-- ============================================================================

insert into public.asset_catalog (key, "group", label, description, kind, width, height, min_tier, sort_order)
values
  (
    'palette_ase',
    'color',
    'Palette (Adobe Swatch Exchange)',
    'Your colours as an .ase file — drop it into Illustrator, Photoshop, or InDesign''s swatch panel.',
    'ase',
    null,
    null,
    'starter',
    19
  ),
  (
    'tokens_json',
    'color',
    'Colour tokens (JSON)',
    'Your colours as a flat JSON file, for a design system or a build pipeline.',
    'json',
    null,
    null,
    'starter',
    20
  ),
  (
    'colors_css',
    'color',
    'Colour tokens (CSS)',
    'Your colours as CSS custom properties — drop this into any stylesheet.',
    'css',
    null,
    null,
    'starter',
    21
  );
