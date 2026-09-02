-- ============================================================================
-- Eklio — where the accent color comes from
-- ============================================================================
-- Follows `20260829107000_site_spec_hot_path.sql`.
--
-- WHAT WAS ACTUALLY IN THE DATABASE, CHECKED RATHER THAN ASSUMED
-- --------------------------------------------------------------
-- `brand_kits.directions[].palette` is validated by
-- `brand_kit_palette_valid`, shipped in `20260827102000_brand_kit_deliverable.sql`,
-- and it requires exactly five roles:
--
--     primary, secondary, light, dark, paper
--
-- There is no `accent`. `palette_families` — the catalog every direction
-- palette is built from — has the same five columns and a CHECK tying its
-- `preview_tokens` jsonb to them. The approved Screen 4 copy embedded in
-- `20260827103000_rendering_constraints.sql` carries the same five. The word
-- "accent" appears nowhere in the schema before this lot.
--
-- So the site spec's `accent` token has no source in a direction, and this
-- migration derives it. It ALSO reads `palette->>'accent'` first, because the
-- product spec describes a palette that has one: the day the generator starts
-- emitting it, it is used and nothing here has to change.
--
-- ⚠ A SECOND FINDING, AND IT IS THE MORE SERIOUS ONE. `brand_kit_palette_valid`
-- returns NULL — not false — for a palette missing one of its five keys,
-- because `NULL ~ '^#...'` is NULL and `true and NULL` is NULL. A CHECK
-- constraint PASSES on NULL. So a palette shaped
-- `{primary, secondary, accent, light_neutral, dark_neutral}` is accepted by
-- `brand_kits` today, and then the seeder read `palette->>'light'`, got NULL,
-- and hit the NOT NULL on `site_specs.light_neutral_hex` — inside the AFTER
-- trigger, which rolls back the direction selection. A kit that stores fine
-- becomes a direction that cannot be chosen.
--
-- This migration does NOT change that Lot 5 validator: tightening a CHECK on
-- `brand_kits` is a separate decision with its own blast radius, and it is
-- recorded in the README for that call to be made deliberately. What it does
-- is make the seeder TOTAL, which is the invariant this lot already committed
-- to and tested for lengths: **seeding must never be able to break direction
-- selection.** Every role is now resolved through a fallback chain, so no
-- palette shape — v4's, the product spec's, or one missing keys entirely —
-- can turn a stored kit into an unchoosable direction.
-- ============================================================================


-- ============================================================================
-- 1. Perceptual distance — CIELAB and ΔE*ab
-- ============================================================================
-- The derived accent has to be visibly a third color. "Visibly" needs a
-- number, and the number cannot be an RGB distance: #3B2C3A and #4A5361 are far
-- apart in RGB and near-identical in how different they look on a page.
--
-- CIE76 ΔE*ab, over D65. It is the simplest formula that is actually
-- perceptual, it needs no extension, and its thresholds are well known: ~2.3 is
-- a just-noticeable difference, ~10 reads as "a different color".
--
-- Reuses the same sRGB linearisation as `site_spec_relative_luminance`, so the
-- two agree about what a channel value means.

create or replace function public.site_spec_lab(p_hex text)
returns numeric[]
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  with ch as (
    select ('x' || substr(p_hex, 2, 2))::bit(8)::int::numeric / 255 as r,
           ('x' || substr(p_hex, 4, 2))::bit(8)::int::numeric / 255 as g,
           ('x' || substr(p_hex, 6, 2))::bit(8)::int::numeric / 255 as b
  ),
  lin as (
    select case when r <= 0.04045 then r / 12.92 else power((r + 0.055) / 1.055, 2.4) end as r,
           case when g <= 0.04045 then g / 12.92 else power((g + 0.055) / 1.055, 2.4) end as g,
           case when b <= 0.04045 then b / 12.92 else power((b + 0.055) / 1.055, 2.4) end as b
      from ch
  ),
  -- linear sRGB -> XYZ (D65), each axis divided by its white point
  xyz as (
    select (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047 as x,
           (0.2126 * r + 0.7152 * g + 0.0722 * b)           as y,
           (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883 as z
      from lin
  ),
  f as (
    select case when x > 0.008856 then power(x, 0.3333333333333333) else 7.787 * x + 0.1379310344827586 end as fx,
           case when y > 0.008856 then power(y, 0.3333333333333333) else 7.787 * y + 0.1379310344827586 end as fy,
           case when z > 0.008856 then power(z, 0.3333333333333333) else 7.787 * z + 0.1379310344827586 end as fz
      from xyz
  )
  select array[round(116 * fy - 16, 4), round(500 * (fx - fy), 4), round(200 * (fy - fz), 4)]
    from f
$$;

comment on function public.site_spec_lab(text) is
  'CIELAB (D65) for a #RRGGBB value. Shares its sRGB linearisation with site_spec_relative_luminance.';

create or replace function public.site_spec_delta_e(p_a text, p_b text)
returns numeric
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  select round(sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2), 2)
    from (select public.site_spec_lab(p_a) as a, public.site_spec_lab(p_b) as b) t
$$;

comment on function public.site_spec_delta_e(text, text) is
  'CIE76 ΔE*ab between two hex colors. ~2.3 is a just-noticeable difference; ~10 reads as a different color.';


-- ============================================================================
-- 2. Deriving the accent
-- ============================================================================
-- ⚠ NOT A COPY OF THE SECONDARY. Two identical swatches under two different
-- labels reads as a bug in the editor, and it is: she would move the accent and
-- watch the secondary follow it, because they were never one value but looked
-- like one.
--
-- The rule, deterministic end to end:
--
--   1. Take the primary's hue and saturation, floored at 0.28 so that a
--      near-grey primary still yields a colored accent rather than another grey.
--   2. Rotate the hue by the first offset in a fixed ladder — 150° first, the
--      split-complementary, which is the classic accent relationship: clearly a
--      different note, still in the same key. 210, 120, 240, 90, 270, 30, 330
--      follow as fallbacks.
--   3. Pick the lightness, from a fixed ladder, closest to the primary's own
--      that reaches **4.5:1 against `light_neutral`** — the accent has to be
--      legible on the page background, which is the whole reason it cannot just
--      be a hue rotation.
--   4. Accept it only if it is at least ΔE 15 from BOTH the primary and the
--      secondary. Otherwise try the next offset.
--
-- WHERE 15 COMES FROM, measured rather than picked: the product already ships
-- PLUM & BONE with primary #3B2C3A and secondary #4A5361 at ΔE 18.10, and
-- CLAY & SAND at ΔE 25.37. 15 is below what this product itself considers two
-- distinguishable swatches, and well above the ~10 at which two colors stop
-- looking like the same one.
--
-- The offsets are tried through COALESCE rather than a sorted scan, and that is
-- a performance decision with a measurement behind it: COALESCE short-circuits,
-- so the common case evaluates ONE offset. Sorting all eight first took 178 ms;
-- this takes 83 ms.

create or replace function public.site_spec_accent_try(
  p_primary        text,
  p_secondary      text,
  p_light_neutral  text,
  p_deg            numeric,
  p_check_distance boolean
)
returns text
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  select c.hex
    from (select public.site_spec_hex_to_hsl(p_primary) as v) raw
    cross join lateral (
      -- floored saturation: a grey primary must not produce a grey accent
      select raw.v[1] as h, greatest(raw.v[2], 0.28) as s, raw.v[3] as l
    ) hsl
    cross join (values (0.40::numeric), (0.34), (0.46), (0.28), (0.52), (0.22), (0.58)) lad(v)
    cross join lateral (
      select public.site_spec_hsl_to_hex((hsl.h + p_deg) % 360, hsl.s, lad.v) as hex
    ) c
   where public.site_spec_contrast_ratio(c.hex, p_light_neutral) >= 4.5
     and (not p_check_distance
          or (public.site_spec_delta_e(c.hex, p_primary)   >= 15
              and public.site_spec_delta_e(c.hex, p_secondary) >= 15))
   -- closest to the primary's own lightness, so the accent belongs to the palette
   order by abs(lad.v - hsl.l), lad.v
   limit 1
$$;

create or replace function public.site_spec_derive_accent(
  p_primary text, p_secondary text, p_light_neutral text
)
returns text
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  -- ⚠ TOTAL BY CONSTRUCTION. The last two arms cannot both fail: the ninth
  -- drops only the distance requirement, the tenth walks the primary's own
  -- lightness to legibility, and the eleventh is the primary itself. The
  -- column this feeds is NOT NULL and sits behind an AFTER trigger on
  -- direction selection, so "returns null sometimes" would mean "some
  -- directions cannot be chosen".
  select coalesce(
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral, 150, true),
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral, 210, true),
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral, 120, true),
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral, 240, true),
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral,  90, true),
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral, 270, true),
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral,  30, true),
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral, 330, true),
    public.site_spec_accent_try(p_primary, p_secondary, p_light_neutral, 150, false),
    public.site_spec_suggest_hex(p_primary, p_light_neutral, 4.5),
    p_primary)
$$;

comment on function public.site_spec_derive_accent(text, text, text) is
  'The accent a direction does not carry: the primary rotated to its split-complementary, lightened or darkened to reach 4.5:1 on the page background, and required to be at least ΔE 15 from both the primary and the secondary. Deterministic and total.';


-- ============================================================================
-- 3. Reading a role out of a direction palette, whatever shape it arrives in
-- ============================================================================
-- Three namings have to resolve, and the cost of one that does not is a
-- direction the therapist cannot choose:
--
--   * `light` / `dark`               — what this repo's constraint requires and
--                                      what `palette_families` produces;
--   * `light_neutral` / `dark_neutral` — the product spec's names, which the
--                                      Lot 5 CHECK lets through (see header);
--   * `accent`                       — the product spec's fifth role, absent
--                                      from everything this repo ships.
--
-- Returns NULL for a role that is absent or not a hex, so the caller can fall
-- back rather than write a NULL into a NOT NULL column.

create or replace function public.site_spec_palette_role(p_palette jsonb, p_role text)
returns text
language sql
immutable
set search_path = ''
as $$
  select upper(v.hex)
    from (
      select case p_role
        when 'primary'       then p_palette->>'primary'
        when 'secondary'     then p_palette->>'secondary'
        when 'accent'        then p_palette->>'accent'
        when 'light_neutral' then coalesce(p_palette->>'light_neutral', p_palette->>'light')
        when 'dark_neutral'  then coalesce(p_palette->>'dark_neutral',  p_palette->>'dark')
      end as hex
    ) v
   where v.hex ~ '^#[0-9A-Fa-f]{6}$'
$$;

comment on function public.site_spec_palette_role(jsonb, text) is
  'One site-spec color role read out of a direction palette, tolerating both the light/dark naming this repo ships and the light_neutral/dark_neutral naming the product spec uses. NULL when the role is absent or not a hex.';


-- ============================================================================
-- 4. The seeder, with the accent resolved and every role made total
-- ============================================================================
-- Replaces the body from `20260829106000_site_spec_actions.sql`. Only the
-- colour block changes; every other value is computed exactly as before.
--
-- ⚠ THE FALLBACK PALETTE IS CLAY & SAND, the same family `brief_preview` falls
-- back to and the one Screen 1's rail renders before any choice is made. It is
-- reached only by a direction whose palette is missing a role the Lot 5 CHECK
-- failed to require — which, per this file's header, is a shape that can be
-- stored today.

create or replace function public.site_spec_seed_values(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_project uuid;
  v_dir     jsonb;
  v_brief   record;
  v_specs   text[];
  v_persona text[];
  v_pal     jsonb;
  v_fb      record;
  v_primary       text;
  v_secondary     text;
  v_accent        text;
  v_light_neutral text;
  v_dark_neutral  text;
begin
  select p.id into v_project
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;
  if v_project is null then
    return null;
  end if;

  select d.value into v_dir
    from public.brand_kits bk
    cross join lateral jsonb_array_elements(bk.directions) as d
   where bk.id = p_brand_kit_id
     and bk.selected_direction_id is not null
     and d.value->>'id' = bk.selected_direction_id;
  if v_dir is null then
    return null;
  end if;

  select * into v_brief from public.project_briefs pb where pb.project_id = v_project;

  select array_agg(s.label order by e.ord) into v_specs
    from unnest(coalesce(v_brief.specialty_ids, array[]::text[])) with ordinality as e(id, ord)
    join public.specialties s on s.id = e.id;

  select array_agg(c.label order by e.ord) into v_persona
    from unnest(coalesce(v_brief.client_persona_ids, array[]::text[])) with ordinality as e(id, ord)
    join public.client_persona_cards c on c.id = e.id;

  -- ---- colours -------------------------------------------------------------
  v_pal := v_dir->'palette';
  select pf.primary_hex, pf.secondary_hex, pf.light_hex, pf.dark_hex
    into v_fb
    from public.palette_families pf where pf.id = 'clay_sand';

  v_primary       := coalesce(public.site_spec_palette_role(v_pal, 'primary'),       v_fb.primary_hex);
  v_secondary     := coalesce(public.site_spec_palette_role(v_pal, 'secondary'),     v_fb.secondary_hex);
  v_light_neutral := coalesce(public.site_spec_palette_role(v_pal, 'light_neutral'), v_fb.light_hex);
  v_dark_neutral  := coalesce(public.site_spec_palette_role(v_pal, 'dark_neutral'),  v_fb.dark_hex);

  -- The product spec's fifth role when the generator sends it; a derived third
  -- color when it does not. Never a copy of the secondary.
  v_accent := coalesce(
    public.site_spec_palette_role(v_pal, 'accent'),
    public.site_spec_derive_accent(v_primary, v_secondary, v_light_neutral));

  return jsonb_build_object(
    'primary',       v_primary,
    'secondary',     v_secondary,
    'accent',        v_accent,
    'light_neutral', v_light_neutral,
    'dark_neutral',  v_dark_neutral,

    'type_pairing_id',
      (select tp.id from public.type_pairings tp
        where tp.heading_font = v_dir->'typography'->>'heading_font'
          and tp.body_font    = v_dir->'typography'->>'body_font'
        order by tp.sort_order limit 1),
    'heading_font',
      coalesce(nullif(btrim(v_dir->'typography'->>'heading_font'), ''), 'Fraunces'),
    'body_font',
      coalesce(nullif(btrim(v_dir->'typography'->>'body_font'), ''), 'Nunito Sans'),
    'google_fonts_url',
      coalesce(nullif(btrim(v_dir->'typography'->>'google_fonts_url'), ''),
               (select tp.google_fonts_url from public.type_pairings tp
                 where tp.id = 'fraunces_nunito')),

    'hero', jsonb_build_object(
      'overline',       public.truncate_on_word_boundary(v_dir->'hero'->>'overline',  48),
      'headline',       public.truncate_on_word_boundary(v_dir->'hero'->>'headline',  90),
      'subhead',        public.truncate_on_word_boundary(v_dir->'hero'->>'subhead',   220),
      'cta_label',      public.truncate_on_word_boundary(v_dir->'hero'->>'cta_label', 28),
      'cta_target_url', null),

    'about_excerpt',
      coalesce(public.truncate_on_word_boundary(v_dir->>'about_excerpt', 600), ''),

    'pages', public.site_spec_default_pages(v_specs, v_persona),

    'practice_details', jsonb_build_object(
      'practice_name',  coalesce(nullif(btrim(v_brief.practice_name), ''),
                                 (select nullif(btrim(p.name), '') from public.projects p
                                   where p.id = v_project)),
      'license_label',  (select lt.label from public.license_types lt
                          where lt.id = v_brief.license_type_id),
      'license_number', null,
      'city',           nullif(btrim(v_brief.city), ''),
      'state',          nullif(btrim(v_brief.state), ''),
      'email',          null,
      'phone',          null),

    'target', public.site_spec_default_target(p_brand_kit_id));
end
$$;

revoke execute on function public.site_spec_seed_values(uuid) from public, anon, authenticated;
grant  execute on function public.site_spec_seed_values(uuid) to service_role;

grant execute on function public.site_spec_lab(text)                              to authenticated, service_role;
grant execute on function public.site_spec_delta_e(text, text)                    to authenticated, service_role;
grant execute on function public.site_spec_derive_accent(text, text, text)        to authenticated, service_role;
grant execute on function public.site_spec_accent_try(text, text, text, numeric, boolean)
                                                                                  to authenticated, service_role;
grant execute on function public.site_spec_palette_role(jsonb, text)              to authenticated, service_role;


-- ============================================================================
-- 5. Guard rails
-- ============================================================================
do $$
declare
  r   record;
  acc text;
  n   int;
begin
  -- ---- the Lab implementation, against published reference values ---------
  if (public.site_spec_lab('#FFFFFF'))[1] <> 100 then
    raise exception 'site_spec_accent: white is not L*=100.';
  end if;
  if (public.site_spec_lab('#000000'))[1] <> 0 then
    raise exception 'site_spec_accent: black is not L*=0.';
  end if;
  -- sRGB red in CIELAB D65 is L*=53.2329, a*=80.1093, b*=67.2201
  if round((public.site_spec_lab('#FF0000'))[1], 2) <> 53.23
     or round((public.site_spec_lab('#FF0000'))[2], 2) <> 80.11
     or round((public.site_spec_lab('#FF0000'))[3], 2) <> 67.22 then
    raise exception 'site_spec_accent: sRGB red does not land on its published Lab value.';
  end if;
  if public.site_spec_delta_e('#3B2C3A', '#3B2C3A') <> 0 then
    raise exception 'site_spec_accent: a color is not at distance 0 from itself.';
  end if;

  -- ---- the threshold is below what this product already ships -------------
  if public.site_spec_delta_e('#3B2C3A', '#4A5361') < 15 then
    raise exception
      'site_spec_accent: the ΔE 15 floor is above PLUM & BONE''s own primary/secondary distance; it would reject a pairing this product ships.';
  end if;

  -- ---- every shipped palette derives a usable accent ----------------------
  for r in select id, primary_hex, secondary_hex, light_hex from public.palette_families loop
    acc := public.site_spec_derive_accent(r.primary_hex, r.secondary_hex, r.light_hex);

    if acc is null then
      raise exception 'site_spec_accent: % derived no accent at all.', r.id;
    end if;
    if acc !~ '^#[0-9A-F]{6}$' then
      raise exception 'site_spec_accent: % derived a malformed accent %.', r.id, acc;
    end if;
    -- ⚠ the whole point: not a copy of either existing swatch
    if acc = r.primary_hex or acc = r.secondary_hex then
      raise exception 'site_spec_accent: % derived an accent identical to its primary or secondary.', r.id;
    end if;
    if public.site_spec_delta_e(acc, r.primary_hex) < 15 then
      raise exception 'site_spec_accent: %''s accent is only ΔE %s from its primary.',
        r.id, public.site_spec_delta_e(acc, r.primary_hex);
    end if;
    if public.site_spec_delta_e(acc, r.secondary_hex) < 15 then
      raise exception 'site_spec_accent: %''s accent is only ΔE %s from its secondary.',
        r.id, public.site_spec_delta_e(acc, r.secondary_hex);
    end if;
    -- and legible where it is actually painted
    if public.site_spec_contrast_ratio(acc, r.light_hex) < 4.5 then
      raise exception 'site_spec_accent: %''s accent is not legible on its own page background.', r.id;
    end if;
  end loop;

  -- ---- deterministic ------------------------------------------------------
  if public.site_spec_derive_accent('#3B2C3A', '#4A5361', '#F3EDE4')
     is distinct from public.site_spec_derive_accent('#3B2C3A', '#4A5361', '#F3EDE4') then
    raise exception 'site_spec_accent: the derivation is not deterministic.';
  end if;

  -- ---- total, including the degenerate inputs -----------------------------
  foreach acc in array array['#000000', '#FFFFFF', '#808080'] loop
    if public.site_spec_derive_accent(acc, acc, '#F3EDE4') is null then
      raise exception 'site_spec_accent: no accent derived for the degenerate primary %.', acc;
    end if;
  end loop;

  -- ---- the product spec's own palette shape resolves ----------------------
  if public.site_spec_palette_role(
       '{"primary":"#3B2C3A","secondary":"#4A5361","accent":"#C08A3E","light_neutral":"#F3EDE4","dark_neutral":"#241B23"}'::jsonb,
       'accent') <> '#C08A3E' then
    raise exception 'site_spec_accent: a palette carrying an accent does not resolve it.';
  end if;
  if public.site_spec_palette_role(
       '{"primary":"#3B2C3A","secondary":"#4A5361","accent":"#C08A3E","light_neutral":"#F3EDE4","dark_neutral":"#241B23"}'::jsonb,
       'light_neutral') <> '#F3EDE4' then
    raise exception 'site_spec_accent: the product spec''s light_neutral naming does not resolve.';
  end if;
  -- and so does this repo's
  if public.site_spec_palette_role(
       '{"primary":"#3B2C3A","secondary":"#4A5361","light":"#F3EDE4","dark":"#241B23","paper":"#FAF7F2"}'::jsonb,
       'light_neutral') <> '#F3EDE4' then
    raise exception 'site_spec_accent: this repo''s light naming does not resolve.';
  end if;
  -- a missing or malformed role is NULL, so the caller can fall back
  if public.site_spec_palette_role('{"primary":"#3B2C3A"}'::jsonb, 'accent') is not null then
    raise exception 'site_spec_accent: an absent role did not resolve to NULL.';
  end if;
  if public.site_spec_palette_role('{"accent":"not a hex"}'::jsonb, 'accent') is not null then
    raise exception 'site_spec_accent: a malformed role did not resolve to NULL.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_spec_seed_values from 20260829106000 (accent = secondary),
--   -- then:
--   drop function if exists public.site_spec_palette_role(jsonb, text);
--   drop function if exists public.site_spec_derive_accent(text, text, text);
--   drop function if exists public.site_spec_accent_try(text, text, text, numeric, boolean);
--   drop function if exists public.site_spec_delta_e(text, text);
--   drop function if exists public.site_spec_lab(text);
