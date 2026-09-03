-- ============================================================================
-- Eklio — asset_catalog: the remaining wordmark ink treatments (Lot 4.4)
-- ============================================================================
-- wordmark_svg_dark (Lot 4.1) and wordmark_png_dark (Lot 4.4 wave 1) already
-- exist. This adds the other three ink treatments named in the brief's Lot
-- 4.4 catalogue (POST_PURCHASE_BRIEF.md, "Identity, remaining" —
-- eklio-frontend):
--
--   wordmark_svg_light        — ink tokens.paper, for a dark background.
--   wordmark_svg_mono_black   — ink literal black, single-colour contexts.
--   wordmark_svg_mono_white   — ink literal white, single-colour contexts.
--   wordmark_png_light_1200   — the light PNG at 1200px wide.
--   wordmark_png_light_2400   — the light PNG at 2400px wide.
--
-- The brief names one item, "wordmark_png_light at 1200px and 2400px wide" —
-- split into two catalog keys here, one per pixel width, matching the
-- pattern already used for every other size-varying item in the catalogue
-- (favicon_16 vs favicon_32, business_card_front vs _back, …): a manifest
-- entry is one downloadable file, and two sizes are two files. Recorded in
-- eklio-frontend's DECISIONS.md.
--
-- Width/height: all five wordmark treatments trim to ink bounds (never a
-- fixed canvas — see 20260903160000_asset_catalog_trimmed_dims_null.sql for
-- why wordmark_png_dark already stores both as null). The two PNG sizes
-- fix WIDTH only (the pixel width they're rasterized at); height still
-- varies with the trimmed aspect ratio, so it stays null, same reasoning.
-- ============================================================================

insert into public.asset_catalog (key, "group", label, description, kind, width, height, min_tier, sort_order)
values
  (
    'wordmark_svg_light',
    'identity',
    'Wordmark (light)',
    'Your practice name, set in your heading font, in a light ink — for placing on a dark background.',
    'svg',
    null,
    null,
    'starter',
    2
  ),
  (
    'wordmark_svg_mono_black',
    'identity',
    'Wordmark (black, one colour)',
    'Your practice name in solid black — for engraving, stamping, or any single-colour print run.',
    'svg',
    null,
    null,
    'starter',
    5
  ),
  (
    'wordmark_svg_mono_white',
    'identity',
    'Wordmark (white, one colour)',
    'Your practice name in solid white — for a dark single-colour surface.',
    'svg',
    null,
    null,
    'starter',
    6
  ),
  (
    'wordmark_png_light_1200',
    'identity',
    'Wordmark (light), 1200px',
    'The light wordmark as a PNG, 1200px wide, transparent background.',
    'png',
    1200,
    null,
    'starter',
    7
  ),
  (
    'wordmark_png_light_2400',
    'identity',
    'Wordmark (light), 2400px',
    'The light wordmark as a PNG, 2400px wide, transparent background — for print or a large display.',
    'png',
    2400,
    null,
    'starter',
    8
  );
