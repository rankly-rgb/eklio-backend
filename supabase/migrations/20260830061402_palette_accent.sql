-- ============================================================================
-- Eklio — the accent becomes curated, and the derivation becomes the fallback
-- ============================================================================
-- Follows `20260829113000_site_spec_paper.sql`.
--
-- WHY THE DERIVATION WAS NOT ENOUGH
-- ---------------------------------
-- `site_spec_derive_accent` rotates the primary's hue to its split
-- complementary. It is deterministic, it is legible, and on this product's own
-- palettes it produced a deep teal for CLAY & SAND and a dark olive for
-- PLUM & BONE.
--
-- This repo's editorial rule, written into
-- `20260827100000_catalog_reference_data.sql`, is: **no pale sage, no dusty
-- blue** — the therapist-directory default this product exists to escape. A
-- hue rotation walks straight into greens and blues, so the derivation was
-- automating the injection of exactly what the catalog forbids, into palettes
-- that had been chosen by hand.
--
-- The premise of the product is that the taste is curated. The accent is now a
-- catalog column with six hand-picked values, and the derivation stays as the
-- fallback for a palette that has none.
--
-- THE RULE THE SIX FOLLOW
-- -----------------------
-- Each accent sits INSIDE its family's own register rather than opposite it: a
-- warmer or a deeper sibling, not a complementary contrast. All six are in the
-- red-orange-berry range (hue 340 to 29) — none is a green, none is a blue.
-- They are for small elements: links, checks, selected states, a rule under a
-- heading. Not for large fills, which is why every one of them is dark enough
-- to be read as text.
--
-- ⚠ TO CHANGE ONE, EDIT ITS HEX IN THE MARKED BLOCK BELOW AND REGENERATE THE
-- MIRROR. That is the whole edit — one line per family, no code change. The
-- guard rail re-checks distance and legibility on every apply, so a swap that
-- breaks either fails the migration rather than the site.
-- ============================================================================


-- ============================================================================
-- 1. The column
-- ============================================================================
-- Added nullable, filled by the marked block below, then made NOT NULL — the
-- rows already exist and cannot be created with a value.

-- ⚠ THE DEFAULT IS DEBUG MAGENTA, AND IT IS MEANT TO BE SEEN. The column is
-- NOT NULL, but `supabase/seed.sql` still carries the catalog upsert as it was
-- written before this column existed, and an `INSERT ... ON CONFLICT DO UPDATE`
-- validates NOT NULL on the proposed tuple before it detects the conflict — so
-- without a default, a local `db reset` would fail on a row whose real accent
-- is already correct and which the upsert was never going to change.
--
-- #FF00FF is a valid hex, so the format CHECK passes, and it is a colour no
-- therapist brand would ever contain. The guard rail at the end of this file
-- and the test file both refuse it: a family that reaches production carrying
-- the placeholder is a family whose accent was never chosen, and that fails
-- loudly instead of shipping a magenta link.
alter table public.palette_families
  add column if not exists accent_hex text not null default '#FF00FF';

comment on column public.palette_families.accent_hex is
  'The curated accent for this family: a warmer or deeper sibling of its own register, for small elements only. Never a complementary hue rotation — see the editorial rule about sage green and dusty blue. The #FF00FF default means "not chosen yet" and is refused by the guard rail.';


-- ============================================================================
-- 2. The six
-- ============================================================================
-- ⚠ EVERYTHING BETWEEN THE TWO MARKERS BELOW IS MIRRORED VERBATIM IN
-- `supabase/seed.sql`. Change one, change the other. Regenerate the mirror with:
--
--   awk '/^-- >>> PALETTE ACCENT DATA/,/^-- <<< PALETTE ACCENT DATA/' \
--     supabase/migrations/20260829114000_palette_accent.sql \
--     > /tmp/palette-accents.sql

-- >>> PALETTE ACCENT DATA (mirrored verbatim in supabase/seed.sql) >>>

update public.palette_families set accent_hex = '#6E2F44' where id = 'plum_bone';      -- deep berry: the plum, taken redder
update public.palette_families set accent_hex = '#6E3320' where id = 'clay_sand';      -- deep brick: the terracotta, taken much deeper
update public.palette_families set accent_hex = '#8F5324' where id = 'ink_blue_chalk'; -- copper: warmth against the ink
update public.palette_families set accent_hex = '#8C5624' where id = 'olive_chalk';    -- ochre: the olive, taken warmer and deeper
update public.palette_families set accent_hex = '#A34A2A' where id = 'ochre_paper';    -- burnt orange: the ochre, taken redder
update public.palette_families set accent_hex = '#8E4A3C' where id = 'slate_bone';     -- brick: warmth against the slate

-- <<< PALETTE ACCENT DATA <<<

-- The same hex rule the other five carry. Uppercase, because this table stores
-- its colours uppercase and `palette_families_hex_check` already says so.
alter table public.palette_families drop constraint if exists palette_families_hex_check;
alter table public.palette_families
  add constraint palette_families_hex_check check (
    primary_hex   ~ '^#[0-9A-F]{6}$'
    and secondary_hex ~ '^#[0-9A-F]{6}$'
    and light_hex     ~ '^#[0-9A-F]{6}$'
    and dark_hex      ~ '^#[0-9A-F]{6}$'
    and paper_hex     ~ '^#[0-9A-F]{6}$'
    and accent_hex    ~ '^#[0-9A-F]{6}$'
  );

-- ⚠ `preview_tokens` IS DELIBERATELY LEFT AT ITS FIVE ROLES. It is upserted by
-- the catalog block that `supabase/seed.sql` mirrors verbatim from
-- `20260827100000_catalog_reference_data.sql`, and that block predates this
-- column. Adding `accent` to the CHECK would fail a local `db reset`; adding it
-- to the value would have it stripped again by the next upsert. Either way the
-- two copies would drift, which is the one thing the mirror convention exists
-- to prevent.
--
-- Nothing needs it there. The accent is a column of its own, and everything
-- that resolves one goes through `site_spec_curated_accent()` or reads
-- `palette_families.accent_hex` directly.


-- ============================================================================
-- 3. Resolving a curated accent for a direction that does not carry one
-- ============================================================================
-- The generator builds a direction palette from a family, so the family can be
-- recovered by matching the five hexes it copied. When it matches, the curated
-- accent is used; when it does not — a palette the generator invented, or one
-- edited by hand — there is nothing curated to use and the derivation answers.

create or replace function public.site_spec_curated_accent(p_palette jsonb)
returns text
language sql
stable
set search_path = ''
as $$
  select pf.accent_hex
    from public.palette_families pf
   where pf.primary_hex   = public.site_spec_palette_role(p_palette, 'primary')
     and pf.secondary_hex = public.site_spec_palette_role(p_palette, 'secondary')
     and pf.light_hex     = public.site_spec_palette_role(p_palette, 'light_neutral')
     and pf.dark_hex      = public.site_spec_palette_role(p_palette, 'dark_neutral')
     and pf.paper_hex     = public.site_spec_palette_role(p_palette, 'paper')
   order by pf.sort_order
   limit 1
$$;

comment on function public.site_spec_curated_accent(jsonb) is
  'The curated accent of the palette family a direction palette was built from, recovered by matching its five hexes. NULL when the palette is not one of ours, which is when the derivation takes over.';

grant execute on function public.site_spec_curated_accent(jsonb) to authenticated, service_role;


-- ============================================================================
-- 4. The seeder prefers curation, then the direction, then the derivation
-- ============================================================================
-- Only the accent block changes; everything else is carried through from
-- `20260829113000_site_spec_paper.sql` unaltered.

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
  v_lim     jsonb;
  v_clamped jsonb := '{}'::jsonb;
  v_primary       text;
  v_secondary     text;
  v_accent        text;
  v_light_neutral text;
  v_dark_neutral  text;
  v_paper         text;
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

  v_pal := v_dir->'palette';
  select pf.primary_hex, pf.secondary_hex, pf.light_hex, pf.dark_hex, pf.paper_hex, pf.accent_hex
    into v_fb
    from public.palette_families pf where pf.id = 'clay_sand';

  v_primary       := coalesce(public.site_spec_palette_role(v_pal, 'primary'),       v_fb.primary_hex);
  v_secondary     := coalesce(public.site_spec_palette_role(v_pal, 'secondary'),     v_fb.secondary_hex);
  v_light_neutral := coalesce(public.site_spec_palette_role(v_pal, 'light_neutral'), v_fb.light_hex);
  v_dark_neutral  := coalesce(public.site_spec_palette_role(v_pal, 'dark_neutral'),  v_fb.dark_hex);
  v_paper         := coalesce(public.site_spec_palette_role(v_pal, 'paper'),         v_fb.paper_hex);

  -- ⚠ CURATION FIRST. The generator's own accent if it sent one, then the
  -- hand-picked accent of the family this palette came from, and only then the
  -- derivation — which is sound arithmetic and has no taste.
  v_accent := coalesce(
    public.site_spec_palette_role(v_pal, 'accent'),
    public.site_spec_curated_accent(v_pal),
    public.site_spec_derive_accent(v_primary, v_secondary, v_paper));

  v_lim := public.site_spec_limits();

  v_clamped := v_clamped
    || public.site_spec_clamp_note('hero.overline',  v_dir->'hero'->>'overline',  (v_lim->>'hero_overline')::int)
    || public.site_spec_clamp_note('hero.headline',  v_dir->'hero'->>'headline',  (v_lim->>'hero_headline')::int)
    || public.site_spec_clamp_note('hero.subhead',   v_dir->'hero'->>'subhead',   (v_lim->>'hero_subhead')::int)
    || public.site_spec_clamp_note('hero.cta_label', v_dir->'hero'->>'cta_label', (v_lim->>'hero_cta_label')::int)
    || public.site_spec_clamp_note('about_excerpt',  v_dir->>'about_excerpt',     (v_lim->>'about_excerpt')::int);

  return jsonb_build_object(
    'primary',       v_primary,
    'secondary',     v_secondary,
    'accent',        v_accent,
    'light_neutral', v_light_neutral,
    'dark_neutral',  v_dark_neutral,
    'paper',         v_paper,

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
      'overline',       public.truncate_on_word_boundary(v_dir->'hero'->>'overline',  (v_lim->>'hero_overline')::int),
      'headline',       public.truncate_on_word_boundary(v_dir->'hero'->>'headline',  (v_lim->>'hero_headline')::int),
      'subhead',        public.truncate_on_word_boundary(v_dir->'hero'->>'subhead',   (v_lim->>'hero_subhead')::int),
      'cta_label',      public.truncate_on_word_boundary(v_dir->'hero'->>'cta_label', (v_lim->>'hero_cta_label')::int),
      'cta_target_url', null),

    'about_excerpt',
      coalesce(public.truncate_on_word_boundary(v_dir->>'about_excerpt', (v_lim->>'about_excerpt')::int), ''),

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

    'target', public.site_spec_default_target(p_brand_kit_id),
    'seed_clamped', nullif(v_clamped, '{}'::jsonb));
end
$$;

revoke execute on function public.site_spec_seed_values(uuid) from public, anon, authenticated;
grant  execute on function public.site_spec_seed_values(uuid) to service_role;


-- ============================================================================
-- 5. Guard rails — and the review table, printed on every apply
-- ============================================================================
do $$
declare
  r record;
begin
  raise notice '';
  raise notice 'curated accents — family, primary, secondary, accent, ΔE prim, ΔE sec, on paper, on light:';
  for r in
    select pf.id, pf.primary_hex, pf.secondary_hex, pf.accent_hex,
           public.site_spec_delta_e(pf.accent_hex, pf.primary_hex)      as de_prim,
           public.site_spec_delta_e(pf.accent_hex, pf.secondary_hex)    as de_sec,
           public.site_spec_contrast_ratio(pf.accent_hex, pf.paper_hex) as on_paper,
           public.site_spec_contrast_ratio(pf.accent_hex, pf.light_hex) as on_light,
           round((public.site_spec_hex_to_hsl(pf.accent_hex))[1])       as hue
      from public.palette_families pf order by pf.sort_order
  loop
    raise notice '  %  %  %  %   ΔE %/%   %:1 paper   %:1 light   hue %',
      rpad(r.id, 15), r.primary_hex, r.secondary_hex, r.accent_hex,
      r.de_prim, r.de_sec, r.on_paper, r.on_light, r.hue;

    -- ⚠ A swapped hex must still be a third colour, not a near-copy.
    if r.de_prim < 15 or r.de_sec < 15 then
      raise exception
        'palette_accent: %''s accent is ΔE %/% from its primary/secondary; the floor is 15. Pick another hex.',
        r.id, r.de_prim, r.de_sec;
    end if;
    -- and readable where it is painted. It is for links and small marks, which
    -- are text, so it is held to the text threshold on both surfaces.
    if r.on_paper < 4.5 then
      raise exception
        'palette_accent: %''s accent is only %:1 on its own page background. Darken it.',
        r.id, r.on_paper;
    end if;
    if r.on_light < 4.5 then
      raise exception
        'palette_accent: %''s accent is only %:1 on its own tinted band. Darken it.',
        r.id, r.on_light;
    end if;

    -- ⚠ THE EDITORIAL RULE, as far as SQL can hold it. Hue 75-260 is the green
    -- and blue arc; the whole point of curating these is to stay out of it.
    if r.hue between 75 and 260 then
      raise exception
        'palette_accent: %''s accent is at hue %, inside the green/blue arc this product exists to avoid.',
        r.id, r.hue;
    end if;
  end loop;
  raise notice '';

  -- ⚠ every family has one that was actually CHOSEN
  if exists (select 1 from public.palette_families where accent_hex = '#FF00FF') then
    raise exception
      'palette_accent: a family still carries the #FF00FF placeholder; its accent was never chosen.';
  end if;

  -- the lookup recovers it from a direction palette built out of a family
  if public.site_spec_curated_accent(
       (select preview_tokens from public.palette_families where id = 'clay_sand'))
     <> (select accent_hex from public.palette_families where id = 'clay_sand') then
    raise exception 'palette_accent: the curated accent is not recovered from its own palette.';
  end if;
  -- and answers NULL for a palette that is not one of ours, so the derivation runs
  if public.site_spec_curated_accent(
       '{"primary":"#123456","secondary":"#654321","light":"#FFFFFF","dark":"#000000","paper":"#FEFEFE"}'::jsonb)
     is not null then
    raise exception 'palette_accent: an unknown palette matched a curated accent.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_spec_seed_values from 20260829113000 (no curated lookup),
--   -- WITH its `set jit = 'off'` clause, then:
--   drop function if exists public.site_spec_curated_accent(jsonb);
--   alter table public.palette_families drop constraint if exists palette_families_hex_check;
--   alter table public.palette_families
--     add constraint palette_families_hex_check check (
--       primary_hex ~ '^#[0-9A-F]{6}$' and secondary_hex ~ '^#[0-9A-F]{6}$'
--       and light_hex ~ '^#[0-9A-F]{6}$' and dark_hex ~ '^#[0-9A-F]{6}$'
--       and paper_hex ~ '^#[0-9A-F]{6}$');
--   alter table public.palette_families drop column if exists accent_hex;
