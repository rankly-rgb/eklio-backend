-- ============================================================================
-- Eklio — asset_catalog: palette_sheet_png, og_image_1200x630 (Lot 4.4)
-- ============================================================================
-- Two more identity/web assets, both with a FIXED real output size (unlike
-- the wordmarks): neither is trimmed to ink bounds.
--
--   * palette_sheet_png — the six colour swatches, edge-to-edge on a
--     1200x600 canvas with no designed-in margin. Trimming to ink bounds
--     would be a no-op here in practice (the fill already touches every
--     edge), so eklio-frontend's renderer skips the bbox computation
--     rather than pretend there's a meaningful crop to make.
--   * og_image_1200x630 — deliberately, permanently untrimmed. Platforms
--     that read the `og:image` meta tag display this at exactly this size;
--     a cropped file would be re-cropped unpredictably by whichever
--     platform renders it. See eklio-frontend's DECISIONS.md,
--     "og_image_1200x630 is not trimmed to ink bounds."
--
-- Both groups (`color`, `web`) are new — the two seeded so far were both
-- `identity`.
-- ============================================================================

insert into public.asset_catalog (key, "group", label, description, kind, width, height, min_tier, sort_order)
values
  (
    'palette_sheet_png',
    'color',
    'Palette sheet',
    'Your six colours, swatched and labelled with their hex values — a quick reference for anyone building something in your brand.',
    'png',
    1200,
    600,
    'starter',
    3
  ),
  (
    'og_image_1200x630',
    'web',
    'Social share image',
    'What your site looks like when someone shares it — the image platforms like LinkedIn and Slack pull in automatically.',
    'png',
    1200,
    630,
    'starter',
    4
  );
