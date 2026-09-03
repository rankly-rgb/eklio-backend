-- ============================================================================
-- Eklio — asset_catalog: monogram family, favicons, icon_512, avatar_400,
-- manifest_values_json (Lot 4.4)
-- ============================================================================
-- All nine share one geometry rule from POST_PURCHASE_BRIEF.md:
--   * monogram_svg / monogram_png_512_* — the standalone mark, one or two
--     letters from the practice name, three PNG treatments (on primary, on
--     paper, transparent) plus one trimmed vector.
--   * favicon_16 / favicon_32 / apple_touch_icon_180 / icon_512 / avatar_400
--     — "monogram on primary, inset inside a 78% inscribed circle so a
--     circular crop never clips it." 16 and 32 use the first letter only;
--     180 and up use the full monogram.
--   * manifest_values_json — the web app manifest's icon/theme references,
--     `kind=json`, needs 20260903210000's widened CHECK constraint.
-- One item named as a single catalogue entry in the brief
-- ("monogram_png_512 ... in three treatments") is three keys here, same
-- reasoning as `wordmark_png_light`'s two-key split
-- (20260903200000_wordmark_ink_treatments.sql) — one manifest row is one
-- file.
-- ============================================================================

insert into public.asset_catalog (key, "group", label, description, kind, width, height, min_tier, sort_order)
values
  (
    'monogram_svg',
    'identity',
    'Monogram',
    'Your initials as a standalone mark, in your primary colour, as a vector file.',
    'svg',
    null,
    null,
    'starter',
    9
  ),
  (
    'monogram_png_512_primary',
    'identity',
    'Monogram, on primary',
    'Your monogram on a solid primary-colour background, 512x512.',
    'png',
    512,
    512,
    'starter',
    10
  ),
  (
    'monogram_png_512_paper',
    'identity',
    'Monogram, on paper',
    'Your monogram in your primary colour on a paper background, 512x512.',
    'png',
    512,
    512,
    'starter',
    11
  ),
  (
    'monogram_png_512_transparent',
    'identity',
    'Monogram, transparent',
    'Your monogram in your primary colour with a transparent background, 512x512.',
    'png',
    512,
    512,
    'starter',
    12
  ),
  (
    'favicon_16',
    'web',
    'Favicon (16px)',
    'Your monogram''s first letter, sized for a browser tab.',
    'png',
    16,
    16,
    'starter',
    13
  ),
  (
    'favicon_32',
    'web',
    'Favicon (32px)',
    'Your monogram''s first letter, sized for a browser tab at higher resolution.',
    'png',
    32,
    32,
    'starter',
    14
  ),
  (
    'apple_touch_icon_180',
    'web',
    'Apple touch icon',
    'Your monogram, sized for an iPhone or iPad home screen icon.',
    'png',
    180,
    180,
    'starter',
    15
  ),
  (
    'icon_512',
    'web',
    'App icon (512px)',
    'Your monogram, sized for a home-screen or app-store icon.',
    'png',
    512,
    512,
    'starter',
    16
  ),
  (
    'manifest_values_json',
    'web',
    'Web app manifest values',
    'The name, colours, and icon references your site''s manifest.json needs.',
    'json',
    null,
    null,
    'starter',
    17
  ),
  (
    'avatar_400',
    'social',
    'Profile photo / avatar',
    'Your monogram, sized for Instagram, Facebook, LinkedIn, and Google Business Profile.',
    'png',
    400,
    400,
    'starter',
    18
  );
