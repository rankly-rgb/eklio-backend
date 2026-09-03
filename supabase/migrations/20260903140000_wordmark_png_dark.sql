-- ============================================================================
-- Eklio — asset_catalog: wordmark_png_dark (Lot 4.4, first asset)
-- ============================================================================
-- The PNG-first choice for Lot 4.4: this is the one asset that exercises
-- @resvg/resvg-js (a native binary) for the first time — deliberately built
-- and verified on a deployed preview before the rest of the identity/web/
-- color catalogue, per the same reasoning that already caught the
-- harfbuzzjs/satori bundling issue in Lot 4.1–4.3: a native-binary failure
-- is a five-minute finding on one asset and a rewritten lot on twenty-five.
--
-- Same dark wordmark as wordmark_svg_dark, rasterized — reuses
-- eklio-frontend's existing satori render, piped through resvg. 960×240 to
-- match the SVG's own dimensions (lib/kit/render/wordmark.ts) — no upscaling
-- decision made yet, on purpose: that is a design choice for whoever adds
-- the rest of the catalogue, not implied by shipping the first PNG.
-- ============================================================================

insert into public.asset_catalog (key, "group", label, description, kind, width, height, min_tier, sort_order)
values (
  'wordmark_png_dark',
  'identity',
  'Wordmark (dark, PNG)',
  'The same dark wordmark as the vector file, rasterized — for anywhere a printer or a platform will not take an SVG.',
  'png',
  960,
  240,
  'starter',
  2
);
