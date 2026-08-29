-- ============================================================================
-- Eklio — the two pure functions: what the mockup renders, and whether it reads
-- ============================================================================
-- Follows `20260829101000_site_spec_catalog.sql`.
--
-- Both functions here take the spec as jsonb — `to_jsonb(site_specs)` — and
-- return jsonb. They read no table, take no id, touch no clock, and are
-- `IMMUTABLE`. Two consequences worth having:
--
--   * they are testable against a literal. A snapshot test hands them an
--     object and compares the result; there is no fixture, no RLS, no row.
--   * they cannot leak. A function that takes a uuid and reads a row has to be
--     reasoned about for scoping; one that takes the caller's own data does not.
--
-- WHY THE FRONTEND MUST NOT RECOMPUTE ANY OF THIS
-- -----------------------------------------------
-- `site_spec_preview_model` returns exactly what the mockup draws: pages and
-- sections already filtered, already sorted, with each section's copy already
-- resolved to where it actually lives. Every one of those is a design decision.
-- Re-deriving them in the client means two implementations of the same rule,
-- and the moment they disagree the mockup stops being a reference for the
-- output the therapist is about to paste into her builder.
-- ============================================================================


-- ============================================================================
-- 1. Where a section's copy actually lives
-- ============================================================================
-- Nine of the eleven section types keep their copy in the section's own
-- `fields`. Two do not: the hero reads `site_specs.hero` and the intro reads
-- `site_specs.about_excerpt`, because those are columns with their own CHECK
-- constraints rather than free-form entries in a jsonb bag.
--
-- The catalog records the same fact in `section_types.source` — that is what
-- tells the editor which form to render. This function hardcodes it instead of
-- reading the catalog, deliberately: it is on the preview path, which the
-- product spec holds to 150 ms, and IMMUTABLE is worth more here than one less
-- literal. The guard rail at the end of this file asserts the two agree, so
-- they are one fact in practice.

create or replace function public.site_spec_section_fields(p_spec jsonb, p_section jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case p_section->>'type'
    when 'hero'  then coalesce(p_spec->'hero', '{}'::jsonb)
    when 'intro' then jsonb_build_object('body', coalesce(p_spec->>'about_excerpt', ''))
    else coalesce(p_section->'fields', '{}'::jsonb)
  end
$$;

comment on function public.site_spec_section_fields(jsonb, jsonb) is
  'The copy a section actually renders. hero reads site_specs.hero and intro reads site_specs.about_excerpt; every other type reads its own fields. Mirrors section_types.source, which the catalog migration asserts.';


-- ============================================================================
-- 2. site_spec_preview_model — what the frontend mockup draws
-- ============================================================================
-- Disabled pages and disabled sections are OMITTED, not flagged: the mockup is
-- a picture of the site as it would be built, and a section switched off is not
-- in it. The editor reads the raw spec for the toggles.
--
-- Sections come back sorted by `order`, with `key` as the tie-break so that two
-- sections sharing an order never swap between two identical reads.
--
-- The token names are the product's — `primary`, `light_neutral` — not the
-- column names. Nothing above the database sees the `_hex` suffix.

create or replace function public.site_spec_preview_model(p_spec jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when p_spec is null then null else jsonb_build_object(
    'practice_name', p_spec->'practice_details'->>'practice_name',

    'tokens', jsonb_build_object(
      'primary',          p_spec->>'primary_hex',
      'secondary',        p_spec->>'secondary_hex',
      'accent',           p_spec->>'accent_hex',
      'light_neutral',    p_spec->>'light_neutral_hex',
      'dark_neutral',     p_spec->>'dark_neutral_hex',
      'heading_font',     p_spec->>'heading_font',
      'body_font',        p_spec->>'body_font',
      'google_fonts_url', p_spec->>'google_fonts_url'),

    'pages', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'key',   pg.value->>'key',
                 'label', pg.value->>'label',
                 'sections', coalesce((
                   select jsonb_agg(
                            jsonb_build_object(
                              'key',    s.value->>'key',
                              'type',   s.value->>'type',
                              'order',  (s.value->>'order')::int,
                              'fields', public.site_spec_section_fields(p_spec, s.value))
                            order by (s.value->>'order')::int, s.value->>'key')
                     from jsonb_array_elements(pg.value->'sections') as s
                    where (s.value->>'enabled')::boolean), '[]'::jsonb))
               order by pg.ord)
        from jsonb_array_elements(p_spec->'pages') with ordinality as pg(value, ord)
       where (pg.value->>'enabled')::boolean), '[]'::jsonb)
  ) end
$$;

comment on function public.site_spec_preview_model(jsonb) is
  'Exactly what the in-app mockup renders, so the client never recomputes a design decision. Disabled pages and sections are omitted; sections come back sorted. Pure and IMMUTABLE: takes to_jsonb(site_specs), reads no table.';


-- ============================================================================
-- 3. Colour arithmetic — WCAG 2.1, in numeric
-- ============================================================================
-- `numeric` rather than `double precision`. The ratios are rounded to two
-- decimals and compared against 4.5, so a pair sitting on the boundary decides
-- between "fix this" and "this is fine" on the last bit of the computation.
-- numeric is exact and platform-independent; float is neither, and six pairs of
-- arithmetic is not a cost worth trading it for.

create or replace function public.site_spec_relative_luminance(p_hex text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  -- WCAG 2.1: linearise each sRGB channel, then weight.
  select sum(ch.w * case when ch.v <= 0.04045 then ch.v / 12.92
                         else power((ch.v + 0.055) / 1.055, 2.4) end)
    from (values
      (0.2126::numeric, ('x' || substr(p_hex, 2, 2))::bit(8)::int::numeric / 255),
      (0.7152::numeric, ('x' || substr(p_hex, 4, 2))::bit(8)::int::numeric / 255),
      (0.0722::numeric, ('x' || substr(p_hex, 6, 2))::bit(8)::int::numeric / 255)
    ) as ch(w, v)
$$;

-- Rounded to two decimals HERE, once, so that the ratio the therapist is shown
-- and the level she is given can never disagree. A raw 4.4996 displayed as
-- "4.50" next to the word "fail" is a bug report waiting to be filed.
create or replace function public.site_spec_contrast_ratio(p_fg text, p_bg text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round(
    (greatest(public.site_spec_relative_luminance(p_fg),
              public.site_spec_relative_luminance(p_bg)) + 0.05)
    / (least(public.site_spec_relative_luminance(p_fg),
             public.site_spec_relative_luminance(p_bg)) + 0.05), 2)
$$;

create or replace function public.site_spec_contrast_level(p_ratio numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_ratio >= 7   then 'AAA'
    when p_ratio >= 4.5 then 'AA'
    when p_ratio >= 3   then 'AA_large'
    else 'fail'
  end
$$;


-- ============================================================================
-- 4. Suggesting a corrected hex — same hue, same chroma, different lightness
-- ============================================================================
-- The product spec asks for OKLCH if a colour library is available. There is
-- none: Postgres has no colour type, and adding an extension to a hosted
-- project to move one axis of one colour is not a trade worth making. HSL is
-- the documented fallback and it holds the property that matters — hue and
-- saturation are untouched, so the corrected colour is recognisably the one
-- she picked, only lighter or darker.
--
-- The walk tries all 101 lightness values and returns the one CLOSEST TO HERS
-- that reaches the target, rather than the first found walking in a guessed
-- direction. Two reasons: it needs no heuristic about which way to go, and it
-- moves her colour the least distance that solves the problem.

create or replace function public.site_spec_hex_to_hsl(p_hex text)
returns numeric[]
language sql
immutable
set search_path = ''
as $$
  select case
    when c.mx = c.mn then array[0::numeric, 0::numeric, (c.mx + c.mn) / 2]
    else array[
      round(case
        when c.mx = c.r then (60 * ((c.g - c.b) / (c.mx - c.mn)) + 360)
        when c.mx = c.g then  60 * ((c.b - c.r) / (c.mx - c.mn)) + 120
        else                  60 * ((c.r - c.g) / (c.mx - c.mn)) + 240
      end::numeric % 360, 6),
      round((c.mx - c.mn)
            / (1 - abs(c.mx + c.mn - 1)), 6),
      (c.mx + c.mn) / 2
    ]
  end
  from (
    select r, g, b, greatest(r, g, b) as mx, least(r, g, b) as mn
      from (select ('x' || substr(p_hex, 2, 2))::bit(8)::int::numeric / 255 as r,
                   ('x' || substr(p_hex, 4, 2))::bit(8)::int::numeric / 255 as g,
                   ('x' || substr(p_hex, 6, 2))::bit(8)::int::numeric / 255 as b) as x
  ) as c
$$;

create or replace function public.site_spec_hsl_to_hex(p_h numeric, p_s numeric, p_l numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  -- The standard piecewise conversion, one row per channel:
  --   a    = s * min(l, 1 - l)
  --   k(n) = (n + h / 30) mod 12
  --   f(n) = l - a * max(-1, min(k - 3, 9 - k, 1))
  -- with the channel offsets 0, 8 and 4 twelfths of the wheel for R, G and B.
  select '#' || string_agg(
           lpad(upper(to_hex(round(least(greatest(ch.v, 0), 1) * 255)::int)), 2, '0'),
           '' order by ch.ord)
    from (
      select n.ord,
             p_l - (p_s * least(p_l, 1 - p_l))
                   * greatest(-1, least(k.k - 3, 9 - k.k, 1)) as v
        from (values (1, 0::numeric), (2, 8::numeric), (3, 4::numeric)) as n(ord, hoff)
        cross join lateral (select ((n.hoff + p_h / 30) % 12) as k) as k
    ) as ch(ord, v)
$$;

comment on function public.site_spec_hsl_to_hex(numeric, numeric, numeric) is
  'HSL to #RRGGBB, using the standard k = (n + h/30) mod 12 formulation. Inverse of site_spec_hex_to_hsl within rounding.';

-- Returns the hex closest to `p_move_hex` in lightness that reaches `p_target`
-- against `p_fixed_hex`, or NULL when no lightness does.
--
-- At the default target of 4.5 it never actually returns NULL, and that is
-- provable rather than lucky: lightness 0 and 1 are always candidates and
-- always come out black and white whatever the hue, black clears 4.5:1
-- whenever the fixed colour's luminance is at least 0.175 and white clears it
-- whenever that luminance is at most 0.183. The two ranges overlap, so every
-- possible fixed colour is covered by one end or the other. The NULL branch is
-- kept because a caller may raise the target — at 7:1 for AAA there are
-- genuinely unreachable colours, and saying so is better than returning
-- something that does not work.
create or replace function public.site_spec_suggest_hex(
  p_move_hex  text,
  p_fixed_hex text,
  p_target    numeric default 4.5
)
returns text
language sql
immutable
set search_path = ''
as $$
  with base as (select public.site_spec_hex_to_hsl(p_move_hex) as hsl),
  candidates as (
    select public.site_spec_hsl_to_hex((select hsl[1] from base),
                                       (select hsl[2] from base),
                                       g.i::numeric / 100) as hex,
           abs(g.i::numeric / 100 - (select hsl[3] from base)) as distance,
           g.i as steps
      from generate_series(0, 100) as g(i)
  )
  select c.hex
    from candidates c
   where public.site_spec_contrast_ratio(c.hex, p_fixed_hex) >= p_target
   -- closest to her colour first; on a tie the darker one, so the answer is
   -- the same on every call
   order by c.distance, c.steps
   limit 1
$$;


-- ============================================================================
-- 5. site_spec_contrast — the six pairs the mockup actually draws
-- ============================================================================
-- ONLY the pairs that are rendered. A full cross product of five tokens would
-- report twenty combinations, most of which appear nowhere on the page, and
-- every false alarm in it teaches the therapist to ignore the real one.
--
-- `cta_label_on_primary` is the one pair whose foreground is not a token: the
-- button's label is white or the dark neutral, and the mockup uses WHICHEVER
-- READS BETTER on the primary. That rule is applied here rather than in the
-- client for the same reason the sort order is: it is a design decision, and it
-- has to be the same decision in the mockup, in the reported ratio and in the
-- output.
--
-- ⚠ WHICH TOKEN MOVES. The suggestion always adjusts a brand colour, never the
-- page background: light_neutral is the surface every other pair is measured
-- against, so darkening it to fix one pair silently changes five. For the two
-- neutral-on-neutral pairs the moving token is `dark_neutral`, the one that
-- carries ink.
--
-- ⚠ AND IT IS NEVER A REFUSAL. This function reports; it does not validate.
-- Nothing in the write path calls it, there is no CHECK on a ratio, and a spec
-- with a failing pair saves normally. A therapist who has already paid for a
-- generation and is then refused a save because two of her colours land at
-- 4.3:1 has been handed a broken product.

create or replace function public.site_spec_contrast(p_spec jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with tok as (
    select p_spec->>'primary_hex'       as primary_hex,
           p_spec->>'secondary_hex'     as secondary_hex,
           p_spec->>'accent_hex'        as accent_hex,
           p_spec->>'light_neutral_hex' as light_neutral_hex,
           p_spec->>'dark_neutral_hex'  as dark_neutral_hex
  ),
  -- The button label the mockup uses: white, unless the dark neutral reads
  -- better on this primary.
  cta as (
    select case
      when public.site_spec_contrast_ratio('#FFFFFF', t.primary_hex)
           >= public.site_spec_contrast_ratio(t.dark_neutral_hex, t.primary_hex)
      then '#FFFFFF' else t.dark_neutral_hex
    end as fg
    from tok t
  ),
  defs as (
    select * from (values
      ('cta_label_on_primary',          'Button label on your primary color',   1),
      ('primary_on_light_neutral',      'Primary color on the page background', 2),
      ('secondary_on_light_neutral',    'Secondary color on the page background', 3),
      ('dark_neutral_on_light_neutral', 'Body text on the page background',     4),
      ('light_neutral_on_dark_neutral', 'Light text on a dark section',         5),
      ('accent_on_light_neutral',       'Accent color on the page background',  6)
    ) as d(pair_id, label, ord)
  ),
  pairs as (
    select d.pair_id, d.label, d.ord,
      case d.pair_id
        when 'cta_label_on_primary'          then (select fg from cta)
        when 'primary_on_light_neutral'      then t.primary_hex
        when 'secondary_on_light_neutral'    then t.secondary_hex
        when 'dark_neutral_on_light_neutral' then t.dark_neutral_hex
        when 'light_neutral_on_dark_neutral' then t.light_neutral_hex
        when 'accent_on_light_neutral'       then t.accent_hex
      end as fg,
      case d.pair_id
        when 'cta_label_on_primary'          then t.primary_hex
        when 'light_neutral_on_dark_neutral' then t.dark_neutral_hex
        else t.light_neutral_hex
      end as bg,
      -- the token the suggestion moves, and its product-facing name
      case d.pair_id
        when 'cta_label_on_primary'          then 'primary'
        when 'primary_on_light_neutral'      then 'primary'
        when 'secondary_on_light_neutral'    then 'secondary'
        when 'dark_neutral_on_light_neutral' then 'dark_neutral'
        when 'light_neutral_on_dark_neutral' then 'dark_neutral'
        when 'accent_on_light_neutral'       then 'accent'
      end as move_token
      from defs d cross join tok t
  ),
  scored as (
    select p.*,
           public.site_spec_contrast_ratio(p.fg, p.bg) as ratio,
           -- Which side of the pair the moving token is on. It is the
           -- BACKGROUND for exactly two pairs — the button (the label is fixed
           -- text, the primary is the surface behind it) and light-on-dark
           -- (the ink that moves is the dark neutral behind the light text) —
           -- and the foreground for the other four.
           case when p.pair_id in ('cta_label_on_primary', 'light_neutral_on_dark_neutral')
                then p.bg else p.fg end as move_hex,
           case when p.pair_id in ('cta_label_on_primary', 'light_neutral_on_dark_neutral')
                then p.fg else p.bg end as fixed_hex
      from pairs p
  )
  select jsonb_build_object(
    'pairs', (
      select jsonb_agg(
               jsonb_build_object(
                 'pair_id', s.pair_id,
                 'label',   s.label,
                 'fg',      s.fg,
                 'bg',      s.bg,
                 'ratio',   s.ratio,
                 'level',   public.site_spec_contrast_level(s.ratio),
                 'suggested_fix',
                   case when s.ratio >= 4.5 then null
                   else (
                     select case when x.hex is null then null
                            else jsonb_build_object('token', s.move_token, 'hex', x.hex) end
                       from (select public.site_spec_suggest_hex(s.move_hex, s.fixed_hex, 4.5) as hex) x
                   ) end)
               order by s.ord)
        from scored s),
    'worst_ratio', (select min(s.ratio) from scored s),
    'passes_aa',   (select bool_and(s.ratio >= 4.5) from scored s)
  )
  where p_spec is not null
$$;

comment on function public.site_spec_contrast(jsonb) is
  'WCAG 2.1 contrast for the six pairs the mockup actually draws, with a corrected hex for each pair below 4.5:1. Reports only — nothing in the write path calls it and there is no CHECK on a ratio. Pure and IMMUTABLE.';

grant execute on function public.site_spec_section_fields(jsonb, jsonb)             to authenticated, service_role;
grant execute on function public.site_spec_preview_model(jsonb)                     to authenticated, service_role;
grant execute on function public.site_spec_relative_luminance(text)                 to authenticated, service_role;
grant execute on function public.site_spec_contrast_ratio(text, text)               to authenticated, service_role;
grant execute on function public.site_spec_contrast_level(numeric)                  to authenticated, service_role;
grant execute on function public.site_spec_hex_to_hsl(text)                         to authenticated, service_role;
grant execute on function public.site_spec_hsl_to_hex(numeric, numeric, numeric)    to authenticated, service_role;
grant execute on function public.site_spec_suggest_hex(text, text, numeric)         to authenticated, service_role;
grant execute on function public.site_spec_contrast(jsonb)                          to authenticated, service_role;


-- ============================================================================
-- 6. Guard rails
-- ============================================================================
do $$
declare
  v_spec jsonb;
  v_hex  text;
  v_c    jsonb;
  n      int;
begin
  -- ---- the arithmetic, against values computable by hand ------------------
  -- Black and white are the two ends of the scale and pin both branches of the
  -- linearisation: 0 and 1 exactly, giving 1.05 / 0.05 = 21.
  if public.site_spec_relative_luminance('#000000') <> 0 then
    raise exception 'site_spec_contrast: black is not luminance 0.';
  end if;
  if public.site_spec_relative_luminance('#FFFFFF') <> 1 then
    raise exception 'site_spec_contrast: white is not luminance 1.';
  end if;
  if public.site_spec_contrast_ratio('#000000', '#FFFFFF') <> 21.00 then
    raise exception 'site_spec_contrast: black on white is not 21:1.';
  end if;
  if public.site_spec_contrast_ratio('#FFFFFF', '#FFFFFF') <> 1.00 then
    raise exception 'site_spec_contrast: white on white is not 1:1.';
  end if;
  -- #767676 on white is the canonical 4.5:1 boundary in the WCAG literature.
  if public.site_spec_contrast_ratio('#767676', '#FFFFFF') < 4.5 then
    raise exception 'site_spec_contrast: #767676 on white must reach AA.';
  end if;
  if public.site_spec_contrast_ratio('#777777', '#FFFFFF') >= 4.5 then
    raise exception 'site_spec_contrast: #777777 on white must fall short of AA.';
  end if;
  -- symmetric, or the pair list would have to care which side it named first
  if public.site_spec_contrast_ratio('#3B2C3A', '#F3EDE4')
     <> public.site_spec_contrast_ratio('#F3EDE4', '#3B2C3A') then
    raise exception 'site_spec_contrast: the ratio is not symmetric.';
  end if;

  -- ---- HSL round trip ------------------------------------------------------
  if public.site_spec_hsl_to_hex(0, 0, 0) <> '#000000'
     or public.site_spec_hsl_to_hex(0, 0, 1) <> '#FFFFFF' then
    raise exception 'site_spec_contrast: HSL does not round trip through black and white.';
  end if;
  -- Every hex the shipped palettes actually contain has to survive the trip,
  -- or a one-click fix would shift a colour the therapist never touched.
  for v_hex in
    select unnest(array[pf.primary_hex, pf.secondary_hex, pf.light_hex,
                        pf.dark_hex, pf.paper_hex])
      from public.palette_families pf
  loop
    if public.site_spec_hsl_to_hex((public.site_spec_hex_to_hsl(v_hex))[1],
                                   (public.site_spec_hex_to_hsl(v_hex))[2],
                                   (public.site_spec_hex_to_hsl(v_hex))[3]) <> v_hex then
      raise exception 'site_spec_contrast: % does not survive a hex -> HSL -> hex round trip.', v_hex;
    end if;
  end loop;

  -- ---- a known-failing pair, and a fix that actually passes ---------------
  -- #C08A3E (the ochre in the catalog) on #F6F2EA is about 2.4:1 — a real
  -- failure a real palette produces, not a contrived one.
  if public.site_spec_contrast_ratio('#C08A3E', '#F6F2EA') >= 4.5 then
    raise exception 'site_spec_contrast: the fixture pair was expected to fail AA.';
  end if;
  if public.site_spec_contrast_ratio(
       public.site_spec_suggest_hex('#C08A3E', '#F6F2EA'), '#F6F2EA') < 4.5 then
    raise exception 'site_spec_contrast: the suggested fix does not reach 4.5:1.';
  end if;
  -- and it is still the same colour, not a different one
  if round((public.site_spec_hex_to_hsl(public.site_spec_suggest_hex('#C08A3E', '#F6F2EA')))[1])
     <> round((public.site_spec_hex_to_hsl('#C08A3E'))[1]) then
    raise exception 'site_spec_contrast: the suggested fix changed the hue.';
  end if;

  -- ---- the envelope --------------------------------------------------------
  v_spec := jsonb_build_object(
    'primary_hex', '#C08A3E', 'secondary_hex', '#6B4B1C', 'accent_hex', '#C08A3E',
    'light_neutral_hex', '#F6F2EA', 'dark_neutral_hex', '#2A2118',
    'heading_font', 'Fraunces', 'body_font', 'Nunito Sans',
    'google_fonts_url', 'https://fonts.googleapis.com/css2?family=Fraunces&display=swap',
    'about_excerpt', 'An excerpt.',
    'practice_details', jsonb_build_object('practice_name', 'Elm & Ember'),
    'hero', jsonb_build_object('overline','O','headline','H','subhead','S','cta_label','C'),
    'pages', public.site_spec_default_pages(array['Anxiety'], array['Adults']));

  v_c := public.site_spec_contrast(v_spec);

  if jsonb_array_length(v_c->'pairs') <> 6 then
    raise exception 'site_spec_contrast: % pairs, expected the 6 the mockup draws.',
      jsonb_array_length(v_c->'pairs');
  end if;
  if (v_c->>'passes_aa')::boolean then
    raise exception 'site_spec_contrast: a palette with a 2.4:1 pair was reported as passing AA.';
  end if;
  -- ⚠ THE ASSERTION THAT MATTERS: a suggestion that does not actually reach
  -- 4.5:1 is worse than none, because the one-click fix would leave the banner
  -- up and the therapist unable to tell what she did wrong.
  if exists (
    select 1 from jsonb_array_elements(v_c->'pairs') p
     where p.value->'suggested_fix' <> 'null'::jsonb
       and public.site_spec_contrast_ratio(
             p.value->'suggested_fix'->>'hex',
             case when p.value->>'pair_id'
                       in ('cta_label_on_primary', 'light_neutral_on_dark_neutral')
                  then p.value->>'fg' else p.value->>'bg' end) < 4.5
  ) then
    raise exception 'site_spec_contrast: a suggested fix does not reach 4.5:1.';
  end if;
  -- at least one is offered for this deliberately failing palette
  if not exists (
    select 1 from jsonb_array_elements(v_c->'pairs') p
     where p.value->'suggested_fix' <> 'null'::jsonb
  ) then
    raise exception 'site_spec_contrast: a palette with a 2.4:1 pair was offered no fix at all.';
  end if;
  -- and the suggestion never moves a neutral surface
  if exists (
    select 1 from jsonb_array_elements(v_c->'pairs') p
     where p.value->'suggested_fix'->>'token' = 'light_neutral'
  ) then
    raise exception
      'site_spec_contrast: a suggestion moves light_neutral, the surface every other pair is measured against.';
  end if;

  -- ---- the preview model ---------------------------------------------------
  if (public.site_spec_preview_model(v_spec)->'tokens'->>'primary') <> '#C08A3E' then
    raise exception 'site_spec_preview_model: the primary token did not survive.';
  end if;
  -- the hero section renders site_specs.hero, not its own empty fields
  if (public.site_spec_preview_model(v_spec)->'pages'->0->'sections'->0->'fields'->>'headline')
     is distinct from 'H' then
    raise exception 'site_spec_preview_model: the hero section does not resolve to site_specs.hero.';
  end if;
  -- and the intro section renders site_specs.about_excerpt
  if (public.site_spec_preview_model(v_spec)->'pages'->0->'sections'->1->'fields'->>'body')
     is distinct from 'An excerpt.' then
    raise exception
      'site_spec_preview_model: the intro section does not resolve to site_specs.about_excerpt.';
  end if;

  -- disabled sections are omitted: the services page seeds `faq` disabled
  select count(*) into n
    from jsonb_array_elements(public.site_spec_preview_model(v_spec)->'pages') pg
    cross join lateral jsonb_array_elements(pg.value->'sections') s
   where s.value->>'type' = 'faq';
  if n <> 0 then
    raise exception 'site_spec_preview_model: a disabled section reached the mockup.';
  end if;

  -- disabled pages are omitted too
  v_spec := jsonb_set(v_spec, '{pages,1,enabled}', 'false'::jsonb);
  if exists (
    select 1 from jsonb_array_elements(public.site_spec_preview_model(v_spec)->'pages') pg
     where pg.value->>'key' = 'about'
  ) then
    raise exception 'site_spec_preview_model: a disabled page reached the mockup.';
  end if;

  -- ---- the hardcoded source mapping agrees with the catalog ---------------
  select count(*) into n
    from public.section_types st
   where (st.id = 'hero'  and st.source <> 'spec.hero')
      or (st.id = 'intro' and st.source <> 'spec.about_excerpt')
      or (st.id not in ('hero', 'intro') and st.source <> 'fields');
  if n > 0 then
    raise exception
      'site_spec_preview_model: section_types.source disagrees with site_spec_section_fields on % type(s).', n;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.site_spec_contrast(jsonb);
--   drop function if exists public.site_spec_suggest_hex(text, text, numeric);
--   drop function if exists public.site_spec_hsl_to_hex(numeric, numeric, numeric);
--   drop function if exists public.site_spec_hex_to_hsl(text);
--   drop function if exists public.site_spec_contrast_level(numeric);
--   drop function if exists public.site_spec_contrast_ratio(text, text);
--   drop function if exists public.site_spec_relative_luminance(text);
--   drop function if exists public.site_spec_preview_model(jsonb);
--   drop function if exists public.site_spec_section_fields(jsonb, jsonb);
