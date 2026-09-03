-- ============================================================================
-- Eklio — asset_catalog.width/height: null for a trimmed asset, on purpose
-- ============================================================================
-- Every identity asset renders trimmed to its ink bounds with zero padding
-- (eklio-frontend, lib/kit/render/rasterize.ts's trim rule, decided this
-- lot) — the actual output size varies with the practice name and font, so
-- a fixed catalog-level width/height would describe a size the render never
-- produces. `wordmark_png_dark` was seeded with 960x240 (the untrimmed
-- satori canvas) before that decision; corrected to null here, matching
-- `wordmark_svg_dark`, which was already null for the same reason.
--
-- The real, per-render dimensions live where they belong: `brand_assets.
-- width`/`height`, written by `record_brand_asset` from what the renderer
-- actually produced. `asset_catalog.width`/`height` stay populated only for
-- an asset deliberately NOT trimmed — a mark inset in a fixed square
-- (avatar_400, the favicons) — where the catalog value is the true,
-- invariant output size.
-- ============================================================================

update public.asset_catalog
   set width = null, height = null
 where key = 'wordmark_png_dark';
