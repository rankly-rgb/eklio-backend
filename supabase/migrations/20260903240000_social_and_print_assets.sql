-- ============================================================================
-- Eklio — asset_catalog: social posts, story, covers, business cards
-- (Lot 4.4, "Social" and "Print")
-- ============================================================================
-- post_statement_1080 / post_question_1080 / post_notes_1080 render from
-- `brand_kits.social_templates[0..2]` (the kit-level statement/question/
-- notes/signature 4-tuple the generation pipeline already writes). See
-- eklio-frontend's DECISIONS.md for why the fourth template entry
-- (`signature`, a `story`-typed template in that schema) backs BOTH
-- `post_signature_1080` (square) and `story_1080x1920` (portrait) — one
-- underlying content, two export shapes, not two content sources.
--
-- cover_linkedin_1584x396 / cover_facebook_1640x624 use the selected
-- direction's hero copy, same as og_image_1200x630.
--
-- business_card_front / business_card_back are print, 300dpi with 0.125in
-- bleed (1125x675px at that bleed+trim) — the brief's own caveat that this
-- ships RGB, not CMYK, without a colour-space conversion, is repeated in the
-- brand_kit_zip README rather than silently dropped.
-- ============================================================================

insert into public.asset_catalog (key, "group", label, description, kind, width, height, min_tier, sort_order)
values
  (
    'post_statement_1080',
    'social',
    'Social post: statement',
    'A square post carrying one of your statement lines, ready to post.',
    'png',
    1080,
    1080,
    'starter',
    22
  ),
  (
    'post_question_1080',
    'social',
    'Social post: question',
    'A square post carrying one of your question lines, ready to post.',
    'png',
    1080,
    1080,
    'starter',
    23
  ),
  (
    'post_notes_1080',
    'social',
    'Social post: notes',
    'A square post in your "notes" template, ready to post.',
    'png',
    1080,
    1080,
    'starter',
    24
  ),
  (
    'post_signature_1080',
    'social',
    'Social post: signature',
    'Your signature line, square, ready to post.',
    'png',
    1080,
    1080,
    'starter',
    25
  ),
  (
    'story_1080x1920',
    'social',
    'Story',
    'Your signature line, sized for an Instagram or Facebook story.',
    'png',
    1080,
    1920,
    'starter',
    26
  ),
  (
    'cover_linkedin_1584x396',
    'social',
    'LinkedIn cover',
    'Your practice name and tagline, sized for a LinkedIn profile cover.',
    'png',
    1584,
    396,
    'starter',
    27
  ),
  (
    'cover_facebook_1640x624',
    'social',
    'Facebook cover',
    'Your practice name and tagline, sized for a Facebook page cover.',
    'png',
    1640,
    624,
    'starter',
    28
  ),
  (
    'business_card_front',
    'print',
    'Business card (front)',
    'Your practice name and credential line, 3.5x2in at 300dpi with bleed and crop marks.',
    'png',
    1125,
    675,
    'starter',
    29
  ),
  (
    'business_card_back',
    'print',
    'Business card (back)',
    'Your monogram on your primary colour, 3.5x2in at 300dpi with bleed and crop marks.',
    'png',
    1125,
    675,
    'starter',
    30
  );
