-- ============================================================================
-- Tests — 20260829102000_site_spec_preview_and_contrast.sql
-- ============================================================================
-- Both functions under test are pure and IMMUTABLE, so this file needs no
-- fixture, no user and no row: every assertion hands a literal in and compares
-- what comes out. That is the point of having taken the spec as jsonb.
--
-- The ratios below are computed by hand from WCAG 2.1 §1.4.3 and cross-checked
-- against an independent implementation of the same formula. They are the
-- reference; if this file fails, the SQL moved, not the standard.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Relative luminance: both branches of the sRGB linearisation
-- ---------------------------------------------------------------------------
do $$
begin
  -- The two ends of the scale are exact and pin the whole curve.
  assert public.site_spec_relative_luminance('#000000') = 0,
         'black must have relative luminance 0';
  assert public.site_spec_relative_luminance('#FFFFFF') = 1,
         'white must have relative luminance 1';

  -- The linear branch (c <= 0.04045). #0A0A0A is 10/255 = 0.0392, under the
  -- knee, so L = 0.0392 / 12.92 = 0.003035... for all three channels.
  assert round(public.site_spec_relative_luminance('#0A0A0A'), 6)
         = round((10::numeric / 255) / 12.92, 6),
         'the linear branch of the sRGB curve is wrong below 0.04045';

  -- The power branch. #808080 is 128/255; ((0.50196 + 0.055) / 1.055) ^ 2.4
  -- = 0.2158605...
  assert round(public.site_spec_relative_luminance('#808080'), 6) = 0.215861,
         'the power branch of the sRGB curve is wrong at mid grey';

  -- The channel weights are not equal, and pure green is the one that shows it.
  assert round(public.site_spec_relative_luminance('#00FF00'), 4) = 0.7152,
         'pure green must weigh 0.7152';
  assert round(public.site_spec_relative_luminance('#FF0000'), 4) = 0.2126,
         'pure red must weigh 0.2126';
  assert round(public.site_spec_relative_luminance('#0000FF'), 4) = 0.0722,
         'pure blue must weigh 0.0722';
end
$$;

-- ---------------------------------------------------------------------------
-- Contrast ratio, against hand-computed values
-- ---------------------------------------------------------------------------
do $$
begin
  -- (1.0 + 0.05) / (0.0 + 0.05) = 21 exactly. The maximum the formula reaches.
  assert public.site_spec_contrast_ratio('#000000', '#FFFFFF') = 21.00,
         'black on white must be 21:1';
  assert public.site_spec_contrast_ratio('#FFFFFF', '#FFFFFF') = 1.00,
         'a colour against itself must be 1:1';

  -- Symmetric: the pair list names a foreground and a background for the
  -- reader's benefit, not the arithmetic's.
  assert public.site_spec_contrast_ratio('#3B2C3A', '#F3EDE4')
       = public.site_spec_contrast_ratio('#F3EDE4', '#3B2C3A'),
         'the ratio must not depend on which side is named first';

  -- The canonical AA boundary for normal text: #767676 is the darkest grey
  -- that still reaches 4.5:1 on white, and the next step down does not.
  assert public.site_spec_contrast_ratio('#767676', '#FFFFFF') = 4.54,
         '#767676 on white must be 4.54:1';
  assert public.site_spec_contrast_ratio('#777777', '#FFFFFF') = 4.48,
         '#777777 on white must be 4.48:1';

  -- and the canonical AAA boundary
  assert public.site_spec_contrast_ratio('#595959', '#FFFFFF') = 7.00,
         '#595959 on white must be 7.00:1';

  -- Two pairs from palettes this product actually ships.
  assert public.site_spec_contrast_ratio('#3B2C3A', '#F3EDE4') = 11.23,
         'PLUM & BONE primary on light must be 11.23:1';
  assert public.site_spec_contrast_ratio('#7A8168', '#EDEAE5') = 3.39,
         'OLIVE & CHALK primary on light must be 3.39:1';
end
$$;

-- ---------------------------------------------------------------------------
-- Levels, at the exact boundaries
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.site_spec_contrast_level(21.00) = 'AAA',    '21 must be AAA';
  assert public.site_spec_contrast_level(7.00)  = 'AAA',    '7.00 is AAA, not AA';
  assert public.site_spec_contrast_level(6.99)  = 'AA',     '6.99 is AA';
  assert public.site_spec_contrast_level(4.50)  = 'AA',     '4.50 is AA, not AA_large';
  assert public.site_spec_contrast_level(4.49)  = 'AA_large', '4.49 is AA_large';
  assert public.site_spec_contrast_level(3.00)  = 'AA_large', '3.00 is AA_large, not fail';
  assert public.site_spec_contrast_level(2.99)  = 'fail',   '2.99 fails';
  assert public.site_spec_contrast_level(1.00)  = 'fail',   '1.00 fails';

  -- The level is derived from the ROUNDED ratio, so what is displayed and what
  -- is judged can never disagree.
  assert public.site_spec_contrast_level(public.site_spec_contrast_ratio('#767676', '#FFFFFF')) = 'AA',
         '#767676 on white must be reported as AA';
  assert public.site_spec_contrast_level(public.site_spec_contrast_ratio('#777777', '#FFFFFF')) = 'AA_large',
         '#777777 on white must fall out of AA';
end
$$;

-- ---------------------------------------------------------------------------
-- HSL: hue and chroma survive, lightness is the only axis that moves
-- ---------------------------------------------------------------------------
do $$
declare
  h text;
begin
  assert public.site_spec_hsl_to_hex(0, 0, 0) = '#000000', 'HSL lightness 0 must be black';
  assert public.site_spec_hsl_to_hex(0, 0, 1) = '#FFFFFF', 'HSL lightness 1 must be white';

  -- Every hex in every shipped palette round-trips exactly. A colour that did
  -- not would come back subtly different from a one-click contrast fix.
  for h in
    select unnest(array[pf.primary_hex, pf.secondary_hex, pf.light_hex,
                        pf.dark_hex, pf.paper_hex])
      from public.palette_families pf
  loop
    assert public.site_spec_hsl_to_hex((public.site_spec_hex_to_hsl(h))[1],
                                       (public.site_spec_hex_to_hsl(h))[2],
                                       (public.site_spec_hex_to_hsl(h))[3]) = h,
           format('%s does not survive a hex -> HSL -> hex round trip', h);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- A known-failing pair, and a fix that actually passes
-- ---------------------------------------------------------------------------
-- OCHRE & PAPER is a palette this product ships, and its primary on its own
-- light neutral is 2.71:1. That is the case the therapist meets in real life,
-- so it is the case the fix is tested against.
do $$
declare
  fixed text;
begin
  assert public.site_spec_contrast_ratio('#C08A3E', '#F6F2EA') = 2.71,
         'the fixture pair must be 2.71:1';
  assert public.site_spec_contrast_level(2.71) = 'fail',
         'the fixture pair must be reported as failing';

  fixed := public.site_spec_suggest_hex('#C08A3E', '#F6F2EA');
  assert fixed is not null, 'a reachable fix was not offered';
  assert public.site_spec_contrast_ratio(fixed, '#F6F2EA') >= 4.5,
         format('the suggested fix %s does not reach 4.5:1', fixed);

  -- and it is still her colour: same hue, same saturation, darker only
  assert round((public.site_spec_hex_to_hsl(fixed))[1])
       = round((public.site_spec_hex_to_hsl('#C08A3E'))[1]),
         'the suggested fix changed the hue';
  assert (public.site_spec_hex_to_hsl(fixed))[3]
       < (public.site_spec_hex_to_hsl('#C08A3E'))[3],
         'the fix for a light colour on a light background must be darker';

  -- Deterministic: the same input gives the same hex every time, which is what
  -- lets the output be snapshot-tested at all.
  assert public.site_spec_suggest_hex('#C08A3E', '#F6F2EA') = fixed,
         'the suggestion is not deterministic';

  -- ⚠ NOT ALWAYS REACHABLE, AND THAT CHANGED DELIBERATELY. This file once
  -- asserted a fix always exists at 4.5:1, which was true only because the walk
  -- was allowed to run to lightness 0 and 1 — that is, to black and white,
  -- whatever the hue was. `20260829111000_site_spec_suggest_hex_bounds.sql`
  -- bounds it to 0.05-0.95, so a genuinely hard pair now returns NULL instead
  -- of a colour she did not choose. Full coverage of the correction lives in
  -- that migration's own test file.
  --
  -- A mid grey on itself is still reachable — at lightness 0.05 it clears
  -- 4.5:1 — and it must not come back as literal black.
  assert public.site_spec_suggest_hex('#808080', '#808080') is not null,
         'a mid grey on itself is still correctable inside the bounded range';
  assert public.site_spec_contrast_ratio(
           public.site_spec_suggest_hex('#808080', '#808080'), '#808080') >= 4.5,
         'the worst-case fix does not reach 4.5:1';
  assert public.site_spec_suggest_hex('#808080', '#808080') not in ('#000000', '#FFFFFF'),
         'the correction walked to an end of the range instead of stopping';

  -- Raising the target is where NULL becomes a real answer: nothing reaches
  -- 7:1 against a mid grey, and saying so beats returning a colour that fails.
  assert public.site_spec_suggest_hex('#808080', '#808080', 7.0) is null,
         'an unreachable target must be reported as null, not approximated';
end
$$;

-- ---------------------------------------------------------------------------
-- The contrast envelope: seven pairs, worst ratio, AA verdict
-- ---------------------------------------------------------------------------
do $$
declare
  spec jsonb := jsonb_build_object(
    'primary_hex', '#C08A3E', 'secondary_hex', '#6B4B1C', 'accent_hex', '#7A8168',
    'light_neutral_hex', '#F6F2EA', 'dark_neutral_hex', '#2A2118',
    -- ⚠ OCHRE & PAPER's real page background. Until 20260829113000 the spec
    -- dropped `paper` and every pair was measured against `light`, a surface
    -- the visitor only sees in bands.
    'paper_hex', '#FBF8F1');
  c jsonb := public.site_spec_contrast(spec);
  ids text[];
begin
  assert jsonb_array_length(c->'pairs') = 7,
         'exactly the seven pairs the mockup draws, no cross product';

  select array_agg(p.value->>'pair_id' order by p.ord)
    into ids
    from jsonb_array_elements(c->'pairs') with ordinality as p(value, ord);
  assert ids = array['cta_label_on_primary', 'dark_neutral_on_paper', 'primary_on_paper',
                     'secondary_on_paper', 'accent_on_paper',
                     'dark_neutral_on_light_neutral', 'paper_on_dark_neutral'],
         'the pair list or its order drifted';

  -- the body text pair is measured against the page, not the band tint
  assert (select p.value->>'bg' from jsonb_array_elements(c->'pairs') p
           where p.value->>'pair_id' = 'dark_neutral_on_paper') = '#FBF8F1',
         'body text must be measured against the page background';

  assert (c->>'worst_ratio')::numeric = 2.85, 'worst_ratio must be the minimum of the seven';
  assert (c->>'passes_aa')::boolean = false,  'a palette with a 2.71:1 pair does not pass AA';

  -- The button label is white or the dark neutral, whichever reads better on
  -- the primary. On this ochre the dark neutral wins.
  assert (c->'pairs'->0->>'fg') = '#2A2118',
         'the button label must be the more readable of white and the dark neutral';
  assert (c->'pairs'->0->>'bg') = '#C08A3E', 'the button sits on the primary';

  -- ⚠ Every offered fix must actually reach 4.5:1. A one-click fix that leaves
  -- the banner up is worse than no fix at all.
  assert not exists (
    select 1 from jsonb_array_elements(c->'pairs') p
     where p.value->'suggested_fix' <> 'null'::jsonb
       and public.site_spec_contrast_ratio(
             p.value->'suggested_fix'->>'hex',
             case when p.value->>'pair_id'
                       in ('cta_label_on_primary', 'paper_on_dark_neutral')
                  then p.value->>'fg' else p.value->>'bg' end) < 4.5),
         'a suggested fix does not reach 4.5:1';

  -- A pair that already passes is not "fixed".
  assert not exists (
    select 1 from jsonb_array_elements(c->'pairs') p
     where (p.value->>'ratio')::numeric >= 4.5
       and p.value->'suggested_fix' <> 'null'::jsonb),
         'a passing pair was offered a fix';

  -- ⚠ The suggestion moves a brand colour or the ink, never a SURFACE. `paper`
  -- carries five of the seven pairs and `light_neutral` one; correcting either
  -- to fix a single pair silently changes every other pair drawn on it.
  assert not exists (
    select 1 from jsonb_array_elements(c->'pairs') p
     where p.value->'suggested_fix'->>'token' in ('paper', 'light_neutral')),
         'a suggestion moves a surface';

  -- A palette where everything passes reports so, and offers nothing.
  c := public.site_spec_contrast(jsonb_build_object(
         'primary_hex', '#3B2C3A', 'secondary_hex', '#241B23', 'accent_hex', '#241B23',
         'light_neutral_hex', '#F3EDE4', 'dark_neutral_hex', '#241B23',
         'paper_hex', '#FAF7F2'));
  assert (c->>'passes_aa')::boolean = true, 'PLUM & BONE must pass AA on every drawn pair';
  assert not exists (
    select 1 from jsonb_array_elements(c->'pairs') p
     where p.value->'suggested_fix' <> 'null'::jsonb),
         'a passing palette must be offered no fixes';
end
$$;

-- ---------------------------------------------------------------------------
-- The preview model
-- ---------------------------------------------------------------------------
do $$
declare
  spec jsonb := jsonb_build_object(
    'primary_hex', '#3B2C3A', 'secondary_hex', '#4A5361', 'accent_hex', '#C08A3E',
    'light_neutral_hex', '#F3EDE4', 'dark_neutral_hex', '#241B23',
    'heading_font', 'Fraunces', 'body_font', 'Nunito Sans',
    'google_fonts_url', 'https://fonts.googleapis.com/css2?family=Fraunces&display=swap',
    'about_excerpt', 'I work mostly with adults who are carrying more than they let on.',
    'practice_details', jsonb_build_object('practice_name', 'Elm & Ember'),
    'hero', jsonb_build_object('overline', 'LCSW · PORTLAND, OR',
                               'headline', 'A calmer place to start.',
                               'subhead',  'Therapy for high-performing adults.',
                               'cta_label','Book a consult',
                               'cta_target_url', 'https://example.com/book'),
    'pages', public.site_spec_default_pages(array['Anxiety','Burnout'], array['Caregivers']));
  m jsonb;
begin
  m := public.site_spec_preview_model(spec);

  assert m->>'practice_name' = 'Elm & Ember', 'the practice name comes from practice_details';

  -- The token names the client reads are the product's, never the columns'.
  assert m->'tokens'->>'primary'       = '#3B2C3A', 'primary token';
  assert m->'tokens'->>'light_neutral' = '#F3EDE4', 'light_neutral token';
  assert m->'tokens'->>'heading_font'  = 'Fraunces', 'heading font';
  assert not (m->'tokens' ? 'primary_hex'), 'the _hex column suffix must not reach the client';

  -- The hero section renders site_specs.hero, and the intro renders
  -- site_specs.about_excerpt — neither keeps its copy in its own fields.
  assert m->'pages'->0->'sections'->0->>'type'             = 'hero',  'home starts with the hero';
  assert m->'pages'->0->'sections'->0->'fields'->>'headline'
         = 'A calmer place to start.', 'the hero section must resolve to site_specs.hero';
  assert m->'pages'->0->'sections'->1->'fields'->>'body'
         = 'I work mostly with adults who are carrying more than they let on.',
         'the intro section must resolve to site_specs.about_excerpt';

  -- Sections come back already sorted, so the client never orders them.
  assert (select array_agg((s.value->>'order')::int order by s.ord)
            from jsonb_array_elements(m->'pages'->0->'sections') with ordinality as s(value, ord))
         = array[1, 2, 3, 4, 5, 6],
         'home sections must come back in order';

  -- Disabled sections are omitted: `faq` is seeded disabled on the services page.
  assert not exists (
    select 1 from jsonb_array_elements(m->'pages') pg
    cross join lateral jsonb_array_elements(pg.value->'sections') s
     where s.value->>'type' = 'faq'),
         'a disabled section reached the mockup';

  -- Disabled pages are omitted whole.
  m := public.site_spec_preview_model(jsonb_set(spec, '{pages,1,enabled}', 'false'::jsonb));
  assert not exists (
    select 1 from jsonb_array_elements(m->'pages') pg where pg.value->>'key' = 'about'),
         'a disabled page reached the mockup';
  assert jsonb_array_length(m->'pages') = 3, 'the other three pages must survive';

  -- Reordering the stored array does not reorder the render: `order` decides.
  m := public.site_spec_preview_model(
         jsonb_set(spec, '{pages,0,sections,0,order}', '99'::jsonb));
  assert m->'pages'->0->'sections'->5->>'type' = 'hero',
         'a re-ordered section must move in the preview';

  assert public.site_spec_preview_model(null) is null,
         'no spec, no preview';
end
$$;

rollback;
