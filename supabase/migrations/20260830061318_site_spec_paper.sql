-- ============================================================================
-- Eklio — `paper` comes back, and the contrast pairs follow it
-- ============================================================================
-- Follows `20260829112000_null_safe_jsonb_validators.sql`.
--
-- THE REGRESSION
-- --------------
-- A direction palette carries five roles. The site spec carried five. They were
-- not the same five: an accent arrived and `paper` was silently dropped.
--
--     primary    -> primary
--     secondary  -> secondary
--     light      -> light_neutral
--     dark       -> dark_neutral
--     paper      -> (nothing)
--     (nothing)  -> accent
--
-- `paper` is the page background. On CLAY & SAND it is #FAF6EE and `light` is
-- #F4EEE3 — the first is the paper the whole site is printed on, the second is
-- the tint of a band or a card. Dropping the first meant three things, and all
-- three were wrong:
--
--   1. the editor had no control for the largest surface on the site;
--   2. every contrast pair was measured against `light_neutral`, a surface the
--      visitor sees in bands, rather than against the one the body text
--      actually sits on;
--   3. the derived output never stated the page background, so a builder given
--      the prompt would default it to white whatever the palette said.
--
-- After this migration the spec carries SIX tokens and no source role is
-- dropped. `light_neutral` keeps its meaning — the tinted band — and `paper`
-- takes back the page.
-- ============================================================================


-- ============================================================================
-- 1. The column
-- ============================================================================
-- Added nullable, backfilled, then made NOT NULL: an existing spec has no paper
-- and has to be given one before the constraint can hold. The backfill prefers
-- the chosen direction's own `paper`, and falls back to the spec's
-- `light_neutral` — which is what the mockup was painting the page with until
-- now, so no existing site changes appearance on the way through.

alter table public.site_specs add column if not exists paper_hex text;

update public.site_specs s
   set paper_hex = coalesce(
         (select public.site_spec_palette_role(d.value->'palette', 'paper')
            from public.brand_kits bk
            cross join lateral jsonb_array_elements(bk.directions) as d
           where bk.id = s.brand_kit_id
             and d.value->>'id' = bk.selected_direction_id),
         s.light_neutral_hex)
 where paper_hex is null;

alter table public.site_specs alter column paper_hex set not null;

comment on column public.site_specs.paper_hex is
  'The page background — the largest surface on the site. Distinct from light_neutral, which is the tint of a band or a card. Every contrast pair the mockup draws on the page is measured against this.';

alter table public.site_specs drop constraint if exists site_specs_hex_check;
alter table public.site_specs
  add constraint site_specs_hex_check check (
    primary_hex       ~ '^#[0-9A-Fa-f]{6}$'
    and secondary_hex     ~ '^#[0-9A-Fa-f]{6}$'
    and accent_hex        ~ '^#[0-9A-Fa-f]{6}$'
    and light_neutral_hex ~ '^#[0-9A-Fa-f]{6}$'
    and dark_neutral_hex  ~ '^#[0-9A-Fa-f]{6}$'
    and paper_hex         ~ '^#[0-9A-Fa-f]{6}$'
  );

-- The editor may write it, like the other five.
grant update (paper_hex) on table public.site_specs to authenticated;


-- ============================================================================
-- 2. `site_spec_palette_role` learns the sixth role
-- ============================================================================
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
        when 'paper'         then p_palette->>'paper'
      end as hex
    ) v
   where v.hex ~ '^#[0-9A-Fa-f]{6}$'
$$;


-- ============================================================================
-- 3. The preview model carries it, so the mockup can paint the page
-- ============================================================================
create or replace function public.site_spec_preview_model(p_spec jsonb)
returns jsonb
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  select case when p_spec is null then null else jsonb_build_object(
    'practice_name', p_spec->'practice_details'->>'practice_name',

    'tokens', jsonb_build_object(
      'primary',          p_spec->>'primary_hex',
      'secondary',        p_spec->>'secondary_hex',
      'accent',           p_spec->>'accent_hex',
      -- the page, and the tint of a band on it
      'paper',            p_spec->>'paper_hex',
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


-- ============================================================================
-- 4. The contrast pairs, measured against what is actually painted
-- ============================================================================
-- ⚠ SEVEN PAIRS, AND THE SURFACE CHANGED. Six of the seven used to be measured
-- against `light_neutral`; the page is `paper`, so that is where the body text,
-- the links and the accent marks actually sit. `light_neutral` keeps one pair —
-- body text inside a tinted band — because that band is real and its text has
-- to read too.
--
--   cta_label_on_primary            the button label on the button
--   dark_neutral_on_paper           BODY TEXT ON THE PAGE — the pair that matters most
--   primary_on_paper                links and headings on the page
--   secondary_on_paper              supporting headings on the page
--   accent_on_paper                 accent marks on the page
--   dark_neutral_on_light_neutral   body text inside a tinted band
--   paper_on_dark_neutral           inverted text in a dark section
--
-- ⚠ NEITHER SURFACE EVER MOVES. `paper` and `light_neutral` are both surfaces:
-- correcting one to fix a single pair silently changes every other pair drawn
-- on it. The moving token is always the ink or the brand colour — `primary`,
-- `secondary`, `accent`, or `dark_neutral` for the two pairs where the ink is
-- the only thing in the pair that is not a surface.

create or replace function public.site_spec_contrast(p_spec jsonb)
returns jsonb
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  with tok as (
    select p_spec->>'primary_hex'       as primary_hex,
           p_spec->>'secondary_hex'     as secondary_hex,
           p_spec->>'accent_hex'        as accent_hex,
           p_spec->>'light_neutral_hex' as light_neutral_hex,
           p_spec->>'dark_neutral_hex'  as dark_neutral_hex,
           coalesce(p_spec->>'paper_hex', p_spec->>'light_neutral_hex') as paper_hex
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
      ('cta_label_on_primary',          'Button label on your primary color',        1),
      ('dark_neutral_on_paper',         'Body text on the page',                     2),
      ('primary_on_paper',              'Primary color on the page',                 3),
      ('secondary_on_paper',            'Secondary color on the page',               4),
      ('accent_on_paper',               'Accent color on the page',                  5),
      ('dark_neutral_on_light_neutral', 'Body text on a tinted section',             6),
      ('paper_on_dark_neutral',         'Light text on a dark section',              7)
    ) as d(pair_id, label, ord)
  ),
  pairs as (
    select d.pair_id, d.label, d.ord,
      case d.pair_id
        when 'cta_label_on_primary'          then (select fg from cta)
        when 'dark_neutral_on_paper'         then t.dark_neutral_hex
        when 'primary_on_paper'              then t.primary_hex
        when 'secondary_on_paper'            then t.secondary_hex
        when 'accent_on_paper'               then t.accent_hex
        when 'dark_neutral_on_light_neutral' then t.dark_neutral_hex
        when 'paper_on_dark_neutral'         then t.paper_hex
      end as fg,
      case d.pair_id
        when 'cta_label_on_primary'          then t.primary_hex
        when 'dark_neutral_on_light_neutral' then t.light_neutral_hex
        when 'paper_on_dark_neutral'         then t.dark_neutral_hex
        else t.paper_hex
      end as bg,
      -- the token the suggestion moves, and its product-facing name. Never a
      -- surface: never `paper`, never `light_neutral`.
      case d.pair_id
        when 'cta_label_on_primary'          then 'primary'
        when 'dark_neutral_on_paper'         then 'dark_neutral'
        when 'primary_on_paper'              then 'primary'
        when 'secondary_on_paper'            then 'secondary'
        when 'accent_on_paper'               then 'accent'
        when 'dark_neutral_on_light_neutral' then 'dark_neutral'
        when 'paper_on_dark_neutral'         then 'dark_neutral'
      end as move_token
      from defs d cross join tok t
  ),
  scored as (
    select p.*,
           public.site_spec_contrast_ratio(p.fg, p.bg) as ratio,
           -- Which side the moving token is on. It is the BACKGROUND for the
           -- button (the label is fixed text on the primary surface) and for
           -- light-on-dark (the ink that moves is the dark neutral behind the
           -- page white).
           case when p.pair_id in ('cta_label_on_primary', 'paper_on_dark_neutral')
                then p.bg else p.fg end as move_hex,
           case when p.pair_id in ('cta_label_on_primary', 'paper_on_dark_neutral')
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


-- ============================================================================
-- 5. The output states the page background
-- ============================================================================
-- A prompt that does not name the page background gets a white site whatever
-- the palette says. The fragment is a catalog row like every other token label.

-- ⚠ MIRRORED IN `supabase/seed.sql`, AND THE ORDER MATTERS. seed.sql replays
-- the block from `20260829110000_site_output_templates.sql`, which still
-- carries the pre-`paper` wording for `token.light_neutral`. This block has to
-- be mirrored AFTER it, or a local `db reset` silently relabels the page
-- background back and the rendered output stops matching its own snapshot —
-- which is exactly how this was caught.
--
--   awk '/^-- >>> PAPER TEMPLATE DATA/,/^-- <<< PAPER TEMPLATE DATA/' \
--     supabase/migrations/20260829113000_site_spec_paper.sql \
--     > /tmp/paper-templates.sql

-- >>> PAPER TEMPLATE DATA (mirrored verbatim in supabase/seed.sql) >>>

insert into public.site_output_templates (id, target, key, body, sort_order) values
  ('all.token.paper', null, 'token.paper', 'Page background — the whole page sits on this', 33)
on conflict (id) do update set body = excluded.body, sort_order = excluded.sort_order;

update public.site_output_templates
   set body = 'Section background — tinted bands and cards only'
 where id = 'all.token.light_neutral';

-- <<< PAPER TEMPLATE DATA <<<

create or replace function public.site_spec_token_lines(p_spec jsonb, p_frag jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select array_to_string(array[
    (p_frag->>'token.primary')       || ': ' || (p_spec->>'primary_hex'),
    (p_frag->>'token.secondary')     || ': ' || (p_spec->>'secondary_hex'),
    (p_frag->>'token.accent')        || ': ' || (p_spec->>'accent_hex'),
    (p_frag->>'token.paper')         || ': ' || (p_spec->>'paper_hex'),
    (p_frag->>'token.light_neutral') || ': ' || (p_spec->>'light_neutral_hex'),
    (p_frag->>'token.dark_neutral')  || ': ' || (p_spec->>'dark_neutral_hex'),
    (p_frag->>'token.heading_font')     || ': ' || (p_spec->>'heading_font'),
    (p_frag->>'token.body_font')        || ': ' || (p_spec->>'body_font'),
    (p_frag->>'token.google_fonts_url') || ': ' || (p_spec->>'google_fonts_url')
  ], E'\n')
$$;

-- and the setup sheet's colour step gains its sixth swatch
create or replace function public.site_spec_output_setup_sheet(p_spec jsonb, p_target text)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  with bt as (select * from public.builder_targets where id = p_target),
  frag as (select public.site_output_fragments(p_target) as f),
  steps as (
    select 1 as n,
           (select f->>'sheet.step1_title' from frag) as title,
           (select f->>'sheet.step1_body' from frag) as body,
           '[]'::jsonb as values,
           (select template_hint from bt) as builder_hint
    union all
    select 2,
           (select f->>'sheet.step2_title' from frag),
           (select f->>'sheet.step2_body' from frag),
           jsonb_build_array(
             jsonb_build_object('label', (select f->>'token.primary' from frag),
                                'value', p_spec->>'primary_hex',       'kind', 'hex'),
             jsonb_build_object('label', (select f->>'token.secondary' from frag),
                                'value', p_spec->>'secondary_hex',     'kind', 'hex'),
             jsonb_build_object('label', (select f->>'token.accent' from frag),
                                'value', p_spec->>'accent_hex',        'kind', 'hex'),
             jsonb_build_object('label', (select f->>'token.paper' from frag),
                                'value', p_spec->>'paper_hex',         'kind', 'hex'),
             jsonb_build_object('label', (select f->>'token.light_neutral' from frag),
                                'value', p_spec->>'light_neutral_hex', 'kind', 'hex'),
             jsonb_build_object('label', (select f->>'token.dark_neutral' from frag),
                                'value', p_spec->>'dark_neutral_hex',  'kind', 'hex')),
           (select color_panel from bt)
    union all
    select 3,
           (select f->>'sheet.step3_title' from frag),
           (select f->>'sheet.step3_body' from frag),
           jsonb_build_array(
             jsonb_build_object('label', (select f->>'token.heading_font' from frag),
                                'value', p_spec->>'heading_font', 'kind', 'font'),
             jsonb_build_object('label', (select f->>'token.body_font' from frag),
                                'value', p_spec->>'body_font',    'kind', 'font'),
             jsonb_build_object('label', (select f->>'token.google_fonts_url' from frag),
                                'value', p_spec->>'google_fonts_url', 'kind', 'url')),
           (select font_panel from bt)
    union all
    select 4,
           (select f->>'sheet.step4_title' from frag),
           (select f->>'sheet.step4_body' from frag)
             || E'\n\n' || coalesce(public.site_spec_structure_lines(p_spec, (select f from frag)), ''),
           '[]'::jsonb,
           (select section_panel from bt)
    union all
    select 5,
           (select f->>'sheet.step5_title' from frag),
           (select f->>'sheet.step5_body' from frag),
           '[]'::jsonb,
           null
    union all
    select 6,
           (select f->>'sheet.step6_title' from frag),
           case when nullif(btrim(coalesce(p_spec->'hero'->>'cta_target_url', '')), '') is not null
                then (select f->>'sheet.step6_body_linked' from frag)
                else (select f->>'sheet.step6_body_unlinked' from frag)
           end,
           jsonb_build_array(
             jsonb_build_object('label', (select f->>'sheet.label_cta_label' from frag),
                                'value', p_spec->'hero'->>'cta_label', 'kind', 'text'))
           || case when nullif(btrim(coalesce(p_spec->'hero'->>'cta_target_url', '')), '') is not null
                   then jsonb_build_array(jsonb_build_object(
                          'label', (select f->>'sheet.label_cta_target' from frag),
                          'value', p_spec->'hero'->>'cta_target_url', 'kind', 'url'))
                   else '[]'::jsonb end,
           null
    union all
    select 7,
           (select f->>'sheet.step7_title' from frag),
           (select string_agg('[ ] ' || c.line, E'\n' order by c.ord)
              from unnest(public.site_spec_constraint_lines(p_spec, (select f from frag)))
                   with ordinality as c(line, ord)),
           '[]'::jsonb,
           null
    union all
    select 8,
           (select f->>'sheet.step8_title' from frag),
           p_spec->>'extra_instructions',
           '[]'::jsonb,
           null
     where nullif(btrim(coalesce(p_spec->>'extra_instructions', '')), '') is not null
  )
  select case when p_spec is null then null else jsonb_build_object(
    'kind', 'setup_sheet',
    'steps', (select jsonb_agg(jsonb_build_object(
                       'n', st.n, 'title', st.title, 'body', st.body,
                       'values', st.values, 'builder_hint', st.builder_hint)
                     order by st.n)
                from steps st),
    'copy_blocks', public.site_spec_copy_blocks(p_spec)
  ) end
$$;


-- ============================================================================
-- 6. Seeding, patching, the envelope
-- ============================================================================
-- The accent is now derived for legibility on `paper`, not on `light_neutral`:
-- the accent is painted on the page.

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
  select pf.primary_hex, pf.secondary_hex, pf.light_hex, pf.dark_hex, pf.paper_hex
    into v_fb
    from public.palette_families pf where pf.id = 'clay_sand';

  v_primary       := coalesce(public.site_spec_palette_role(v_pal, 'primary'),       v_fb.primary_hex);
  v_secondary     := coalesce(public.site_spec_palette_role(v_pal, 'secondary'),     v_fb.secondary_hex);
  v_light_neutral := coalesce(public.site_spec_palette_role(v_pal, 'light_neutral'), v_fb.light_hex);
  v_dark_neutral  := coalesce(public.site_spec_palette_role(v_pal, 'dark_neutral'),  v_fb.dark_hex);
  -- ⚠ no source role is dropped any more
  v_paper         := coalesce(public.site_spec_palette_role(v_pal, 'paper'),         v_fb.paper_hex);

  -- The accent is painted on the page, so it is made legible against the page.
  v_accent := coalesce(
    public.site_spec_palette_role(v_pal, 'accent'),
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

create or replace function public.seed_site_spec(p_brand_kit_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_user_id uuid;
  v_vals    jsonb;
  v_count   int;
begin
  select p.user_id into v_user_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null then
    raise exception
      'seed_site_spec: brand kit % does not exist, or its project has no owner.', p_brand_kit_id;
  end if;

  v_vals := public.site_spec_seed_values(p_brand_kit_id);
  if v_vals is null then
    return 0;
  end if;

  insert into public.site_specs (
    brand_kit_id, user_id,
    primary_hex, secondary_hex, accent_hex, light_neutral_hex, dark_neutral_hex, paper_hex,
    type_pairing_id, heading_font, body_font, google_fonts_url,
    hero, about_excerpt, pages, practice_details, target, seed_clamped
  )
  values (
    p_brand_kit_id, v_user_id,
    v_vals->>'primary',       v_vals->>'secondary', v_vals->>'accent',
    v_vals->>'light_neutral', v_vals->>'dark_neutral', v_vals->>'paper',
    v_vals->>'type_pairing_id', v_vals->>'heading_font',
    v_vals->>'body_font',       v_vals->>'google_fonts_url',
    v_vals->'hero', v_vals->>'about_excerpt',
    v_vals->'pages', v_vals->'practice_details',
    v_vals->>'target',
    case when jsonb_typeof(v_vals->'seed_clamped') = 'object'
         then v_vals->'seed_clamped' end
  )
  on conflict (brand_kit_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

grant execute on function public.seed_site_spec(uuid) to service_role;

create or replace function public.site_spec_patchable_keys()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['primary', 'secondary', 'accent', 'light_neutral', 'dark_neutral', 'paper',
               'type_pairing_id', 'heading_font', 'body_font', 'google_fonts_url',
               'hero', 'about_excerpt', 'pages', 'practice_details',
               'extra_instructions', 'target']
$$;

create or replace function public.site_spec_envelope(p_row jsonb)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select case when p_row is null then null else jsonb_build_object(
    'spec', jsonb_build_object(
      'brand_kit_id',             p_row->>'brand_kit_id',
      'spec_version',             (p_row->>'spec_version')::int,
      'last_copied_spec_version', (p_row->>'last_copied_spec_version')::int,
      'updated_at',               p_row->>'updated_at',
      'primary',                  p_row->>'primary_hex',
      'secondary',                p_row->>'secondary_hex',
      'accent',                   p_row->>'accent_hex',
      'paper',                    p_row->>'paper_hex',
      'light_neutral',            p_row->>'light_neutral_hex',
      'dark_neutral',             p_row->>'dark_neutral_hex',
      'type_pairing_id',          p_row->>'type_pairing_id',
      'heading_font',             p_row->>'heading_font',
      'body_font',                p_row->>'body_font',
      'google_fonts_url',         p_row->>'google_fonts_url',
      'hero',                     p_row->'hero',
      'about_excerpt',            p_row->>'about_excerpt',
      'pages',                    p_row->'pages',
      'practice_details',         p_row->'practice_details',
      'extra_instructions',       p_row->>'extra_instructions',
      'target',                   p_row->>'target',
      'seed_clamped',             p_row->'seed_clamped'),
    'preview',  public.site_spec_preview_model(p_row),
    'contrast', public.site_spec_contrast(p_row),
    'output',   public.site_spec_output(p_row, p_row->>'target'),
    'diff',     public.site_spec_diff(p_row),
    'etag', md5(concat_ws(':', p_row->>'brand_kit_id',
                               p_row->>'spec_version',
                               p_row->>'target'))
  ) end
$$;


-- ============================================================================
-- 7. The patch path accepts it
-- ============================================================================
-- ⚠ Two change-mark labels move with the meaning. `light_neutral` was labelled
-- "Page background changed" because it was painting the page; it is now the
-- tinted band, and `paper` is the page.

create or replace function public.site_spec_patch(p_brand_kit_id uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  s        public.site_specs%rowtype;
  n        public.site_specs%rowtype;
  k        text;
  v_marks  jsonb := '{}'::jsonb;
  v_hero   jsonb;
  v_det    jsonb;
  v_len    int;
  v_path   text;
  v_next   int;
begin
  if (select auth.uid()) is null then
    return public.site_spec_error('unauthenticated', 'Sign in to edit your site spec.');
  end if;

  select * into s
    from public.site_specs
   where brand_kit_id = p_brand_kit_id
     and user_id = (select auth.uid());
  if not found then
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return public.site_spec_error('invalid_body', 'The update must be a JSON object.');
  end if;

  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (public.site_spec_patchable_keys())) then
      return public.site_spec_error('unknown_field',
        format('"%s" is not a field of the site spec.', k), k);
    end if;
  end loop;

  n := s;

  for k in select unnest(array['primary', 'secondary', 'accent',
                               'light_neutral', 'dark_neutral', 'paper']) loop
    if p_patch ? k then
      if jsonb_typeof(p_patch->k) <> 'string'
         or (p_patch->>k) !~ '^#[0-9A-Fa-f]{6}$' then
        return public.site_spec_error('invalid_field',
          'A color must be a hex value like #3B2C3A.', k);
      end if;
      case k
        when 'primary'       then n.primary_hex       := upper(p_patch->>k);
        when 'secondary'     then n.secondary_hex     := upper(p_patch->>k);
        when 'accent'        then n.accent_hex        := upper(p_patch->>k);
        when 'light_neutral' then n.light_neutral_hex := upper(p_patch->>k);
        when 'dark_neutral'  then n.dark_neutral_hex  := upper(p_patch->>k);
        when 'paper'         then n.paper_hex         := upper(p_patch->>k);
      end case;
    end if;
  end loop;

  if p_patch ? 'type_pairing_id' then
    if jsonb_typeof(p_patch->'type_pairing_id') = 'null' then
      n.type_pairing_id := null;
    elsif jsonb_typeof(p_patch->'type_pairing_id') <> 'string' then
      return public.site_spec_error('invalid_field',
        'The type pairing must be a catalog id.', 'type_pairing_id');
    else
      if not exists (select 1 from public.type_pairings tp
                      where tp.id = p_patch->>'type_pairing_id') then
        return public.site_spec_error('invalid_field',
          format('"%s" is not a type pairing we carry.', p_patch->>'type_pairing_id'),
          'type_pairing_id');
      end if;
      n.type_pairing_id := p_patch->>'type_pairing_id';
      select tp.heading_font, tp.body_font, tp.google_fonts_url
        into n.heading_font, n.body_font, n.google_fonts_url
        from public.type_pairings tp where tp.id = n.type_pairing_id;
    end if;
  end if;

  for k in select unnest(array['heading_font', 'body_font', 'google_fonts_url']) loop
    if p_patch ? k then
      if jsonb_typeof(p_patch->k) <> 'string' or btrim(p_patch->>k) = '' then
        return public.site_spec_error('invalid_field',
          'This must be a font name we can render.', k);
      end if;
      case k
        when 'heading_font'     then n.heading_font     := btrim(p_patch->>k);
        when 'body_font'        then n.body_font        := btrim(p_patch->>k);
        when 'google_fonts_url' then n.google_fonts_url := btrim(p_patch->>k);
      end case;
    end if;
  end loop;

  if p_patch ? 'hero' then
    if jsonb_typeof(p_patch->'hero') <> 'object' then
      return public.site_spec_error('invalid_field', 'The hero must be an object.', 'hero');
    end if;
    v_hero := n.hero;
    for k in select jsonb_object_keys(p_patch->'hero') loop
      if not (k = any (array['overline', 'headline', 'subhead',
                             'cta_label', 'cta_target_url'])) then
        return public.site_spec_error('unknown_field',
          format('"%s" is not a field of the hero.', k), 'hero.' || k);
      end if;
      v_hero := jsonb_set(v_hero, array[k], p_patch->'hero'->k);
    end loop;

    if not public.site_spec_hero_valid(v_hero) then
      return public.site_spec_error('invalid_field',
        'Every hero field must be text.', 'hero');
    end if;
    if not public.site_spec_hero_lengths_valid(v_hero) then
      for k, v_len in select * from (values ('overline', 48), ('headline', 90),
                                            ('subhead', 220), ('cta_label', 28)) x(a, b) loop
        if coalesce(char_length(v_hero->>k), 0) > v_len then
          return public.site_spec_error('too_long',
            format('This is %s characters. The limit is %s.',
                   char_length(v_hero->>k), v_len), 'hero.' || k);
        end if;
      end loop;
    end if;
    if not public.site_spec_cta_target_url_valid(v_hero) then
      return public.site_spec_error('invalid_field',
        'The button link must start with https://, http://, mailto: or tel:.',
        'hero.cta_target_url');
    end if;
    n.hero := v_hero;
  end if;

  if p_patch ? 'about_excerpt' then
    if jsonb_typeof(p_patch->'about_excerpt') <> 'string' then
      return public.site_spec_error('invalid_field',
        'The About text must be text.', 'about_excerpt');
    end if;
    if char_length(p_patch->>'about_excerpt') > 600 then
      return public.site_spec_error('too_long',
        format('This is %s characters. The limit is 600.',
               char_length(p_patch->>'about_excerpt')), 'about_excerpt');
    end if;
    n.about_excerpt := p_patch->>'about_excerpt';
  end if;

  if p_patch ? 'extra_instructions' then
    if jsonb_typeof(p_patch->'extra_instructions') = 'null' then
      n.extra_instructions := null;
    elsif jsonb_typeof(p_patch->'extra_instructions') <> 'string' then
      return public.site_spec_error('invalid_field',
        'Your notes must be text.', 'extra_instructions');
    elsif char_length(p_patch->>'extra_instructions') > 2000 then
      return public.site_spec_error('too_long',
        format('This is %s characters. The limit is 2000.',
               char_length(p_patch->>'extra_instructions')), 'extra_instructions');
    else
      n.extra_instructions := p_patch->>'extra_instructions';
    end if;
  end if;

  if p_patch ? 'pages' then
    if not public.site_spec_pages_valid(p_patch->'pages') then
      return public.site_spec_error('invalid_field',
        'Each page needs a known key, a label, an enabled flag and a list of sections with unique keys.',
        'pages');
    end if;
    if not public.site_spec_pages_lengths_valid(p_patch->'pages') then
      v_path := public.site_spec_first_overlong_field(p_patch->'pages');
      return public.site_spec_error('too_long',
        'This is over 800 characters, which is the limit for a section field.',
        coalesce(v_path, 'pages'));
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_patch->'pages') pg
      cross join lateral jsonb_array_elements(pg.value->'sections') sc
      join public.section_types st on st.id = sc.value->>'type'
       where not (pg.value->>'key' = any (st.allowed_pages))
    ) then
      return public.site_spec_error('invalid_field',
        'One of these sections is not allowed on the page it was put on.', 'pages');
    end if;
    n.pages := p_patch->'pages';
  end if;

  if p_patch ? 'practice_details' then
    if jsonb_typeof(p_patch->'practice_details') <> 'object' then
      return public.site_spec_error('invalid_field',
        'The practice details must be an object.', 'practice_details');
    end if;
    v_det := n.practice_details;
    for k in select jsonb_object_keys(p_patch->'practice_details') loop
      if not (k = any (array['practice_name', 'license_label', 'license_number',
                             'city', 'state', 'email', 'phone'])) then
        return public.site_spec_error('unknown_field',
          format('"%s" is not a practice detail.', k), 'practice_details.' || k);
      end if;
      v_det := jsonb_set(v_det, array[k], p_patch->'practice_details'->k);
    end loop;
    if not public.site_spec_practice_details_valid(v_det) then
      return public.site_spec_error('invalid_field',
        'The state must be a two-letter code, and every other detail must be text.',
        'practice_details');
    end if;
    n.practice_details := v_det;
  end if;

  if p_patch ? 'target' then
    if jsonb_typeof(p_patch->'target') <> 'string'
       or not exists (select 1 from public.builder_targets bt
                       where bt.id = p_patch->>'target') then
      return public.site_spec_error('invalid_field',
        'Pick one of the website builders we support.', 'target');
    end if;
    n.target := p_patch->>'target';
  end if;

  v_next := s.spec_version + 1;

  if n.primary_hex is distinct from s.primary_hex then
    v_marks := v_marks || jsonb_build_object('colors|Primary color changed', v_next); end if;
  if n.secondary_hex is distinct from s.secondary_hex then
    v_marks := v_marks || jsonb_build_object('colors|Secondary color changed', v_next); end if;
  if n.accent_hex is distinct from s.accent_hex then
    v_marks := v_marks || jsonb_build_object('colors|Accent color changed', v_next); end if;
  if n.paper_hex is distinct from s.paper_hex then
    v_marks := v_marks || jsonb_build_object('colors|Page background changed', v_next); end if;
  if n.light_neutral_hex is distinct from s.light_neutral_hex then
    v_marks := v_marks || jsonb_build_object('colors|Section background changed', v_next); end if;
  if n.dark_neutral_hex is distinct from s.dark_neutral_hex then
    v_marks := v_marks || jsonb_build_object('colors|Body text color changed', v_next); end if;

  if n.heading_font is distinct from s.heading_font then
    v_marks := v_marks || jsonb_build_object('typography|Heading font changed', v_next); end if;
  if n.body_font is distinct from s.body_font then
    v_marks := v_marks || jsonb_build_object('typography|Body font changed', v_next); end if;
  if n.google_fonts_url is distinct from s.google_fonts_url then
    v_marks := v_marks || jsonb_build_object('typography|Font stylesheet changed', v_next); end if;

  if n.hero is distinct from s.hero then
    v_marks := v_marks || jsonb_build_object('copy|Hero copy edited', v_next); end if;
  if n.about_excerpt is distinct from s.about_excerpt then
    v_marks := v_marks || jsonb_build_object('copy|About text edited', v_next); end if;
  if n.practice_details is distinct from s.practice_details then
    v_marks := v_marks || jsonb_build_object('copy|Practice details edited', v_next); end if;

  if n.pages is distinct from s.pages then
    if public.site_spec_pages_skeleton(n.pages)
       is distinct from public.site_spec_pages_skeleton(s.pages) then
      v_marks := v_marks || jsonb_build_object('structure|Page structure changed', v_next);
    end if;
    if public.site_spec_pages_copy(n.pages)
       is distinct from public.site_spec_pages_copy(s.pages) then
      v_marks := v_marks || jsonb_build_object('copy|Section copy edited', v_next);
    end if;
  end if;

  if n.extra_instructions is distinct from s.extra_instructions then
    v_marks := v_marks || jsonb_build_object('instructions|Your own notes edited', v_next); end if;

  if n.target is distinct from s.target then
    v_marks := v_marks || jsonb_build_object('structure|Website builder changed', v_next); end if;

  if v_marks = '{}'::jsonb then
    return public.site_spec_envelope(to_jsonb(s));
  end if;

  update public.site_specs
     set primary_hex        = n.primary_hex,
         secondary_hex      = n.secondary_hex,
         accent_hex         = n.accent_hex,
         light_neutral_hex  = n.light_neutral_hex,
         dark_neutral_hex   = n.dark_neutral_hex,
         paper_hex          = n.paper_hex,
         type_pairing_id    = n.type_pairing_id,
         heading_font       = n.heading_font,
         body_font          = n.body_font,
         google_fonts_url   = n.google_fonts_url,
         hero               = n.hero,
         about_excerpt      = n.about_excerpt,
         pages              = n.pages,
         practice_details   = n.practice_details,
         extra_instructions = n.extra_instructions,
         target             = n.target,
         spec_version       = v_next,
         change_marks       = coalesce(change_marks, '{}'::jsonb) || v_marks
   where id = s.id
   returning * into n;

  return public.site_spec_envelope(to_jsonb(n));
end
$$;

grant execute on function public.site_spec_patch(uuid, jsonb) to authenticated;


-- ============================================================================
-- 8. Reset restores it too
-- ============================================================================
create or replace function public.site_spec_reset(p_brand_kit_id uuid, p_scope text default 'all')
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  s      public.site_specs%rowtype;
  v      jsonb;
  patch  jsonb := '{}'::jsonb;
  pages  jsonb;
begin
  if (select auth.uid()) is null then
    return public.site_spec_error('unauthenticated', 'Sign in to edit your site spec.');
  end if;
  if not (coalesce(p_scope, '') = any (array['all', 'colors', 'typography',
                                             'copy', 'structure'])) then
    return public.site_spec_error('invalid_scope',
      'Reset all, colors, typography, copy or structure.', 'scope');
  end if;

  select * into s from public.site_specs
   where brand_kit_id = p_brand_kit_id and user_id = (select auth.uid());
  if not found then
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  v := public.site_spec_seed_values(p_brand_kit_id);
  if v is null then
    return public.site_spec_error('no_direction',
      'This brand kit has no chosen direction to reset to.');
  end if;

  if p_scope in ('all', 'colors') then
    patch := patch || jsonb_build_object(
      'primary',       v->>'primary',
      'secondary',     v->>'secondary',
      'accent',        v->>'accent',
      'light_neutral', v->>'light_neutral',
      'dark_neutral',  v->>'dark_neutral',
      'paper',         v->>'paper');
  end if;

  if p_scope in ('all', 'typography') then
    patch := patch || jsonb_build_object(
      'type_pairing_id',  v->'type_pairing_id',
      'heading_font',     v->>'heading_font',
      'body_font',        v->>'body_font',
      'google_fonts_url', v->>'google_fonts_url');
  end if;

  if p_scope in ('all', 'copy') then
    patch := patch || jsonb_build_object(
      'hero', jsonb_set(v->'hero', '{cta_target_url}',
                        coalesce(s.hero->'cta_target_url', 'null'::jsonb)),
      'about_excerpt',    v->>'about_excerpt',
      'practice_details', v->'practice_details');

    select jsonb_agg(
             pg.value || jsonb_build_object('sections', coalesce((
               select jsonb_agg(sc.value || jsonb_build_object(
                        'fields', coalesce(d.fields, '{}'::jsonb)) order by sc.ord)
                 from jsonb_array_elements(pg.value->'sections') with ordinality as sc(value, ord)
                 left join lateral (
                   select ds.value->'fields' as fields
                     from jsonb_array_elements(v->'pages') as dp
                     cross join lateral jsonb_array_elements(dp.value->'sections') as ds
                    where dp.value->>'key' = pg.value->>'key'
                      and ds.value->>'key' = sc.value->>'key'
                    limit 1) d on true), '[]'::jsonb))
             order by pg.ord)
      into pages
      from jsonb_array_elements(s.pages) with ordinality as pg(value, ord);
    patch := patch || jsonb_build_object('pages', pages);
  end if;

  if p_scope in ('all', 'structure') then
    select jsonb_agg(
             dp.value || jsonb_build_object('sections', coalesce((
               select jsonb_agg(ds.value || jsonb_build_object(
                        'fields', case when p_scope = 'all' then ds.value->'fields'
                                       else coalesce(m.fields, ds.value->'fields') end)
                      order by ds.ord)
                 from jsonb_array_elements(dp.value->'sections') with ordinality as ds(value, ord)
                 left join lateral (
                   select cs.value->'fields' as fields
                     from jsonb_array_elements(s.pages) as cp
                     cross join lateral jsonb_array_elements(cp.value->'sections') as cs
                    where cp.value->>'key' = dp.value->>'key'
                      and cs.value->>'key' = ds.value->>'key'
                    limit 1) m on true), '[]'::jsonb))
             order by dp.ord)
      into pages
      from jsonb_array_elements(v->'pages') with ordinality as dp(value, ord);
    patch := patch || jsonb_build_object('pages', pages);
  end if;

  if p_scope = 'all' then
    patch := patch || jsonb_build_object('extra_instructions', null);
  end if;

  return public.site_spec_patch(p_brand_kit_id, patch);
end
$$;

grant execute on function public.site_spec_reset(uuid, text) to authenticated;


-- ============================================================================
-- 9. Guard rails
-- ============================================================================
do $$
declare
  spec jsonb;
  c    jsonb;
  ids  text[];
begin
  spec := jsonb_build_object(
    'primary_hex','#B4674A','secondary_hex','#C08A3E','accent_hex','#6B4B1C',
    'light_neutral_hex','#F4EEE3','dark_neutral_hex','#2B2A27','paper_hex','#FAF6EE',
    'heading_font','Fraunces','body_font','Nunito Sans',
    'google_fonts_url','https://fonts.googleapis.com/css2?family=Fraunces&display=swap',
    'about_excerpt','x','practice_details','{}'::jsonb,
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'pages', public.site_spec_default_pages(null,null), 'target','lovable');

  -- ---- no source role is dropped any more ---------------------------------
  if (public.site_spec_preview_model(spec)->'tokens'->>'paper') is null then
    raise exception 'site_spec_paper: the mockup still cannot paint the page.';
  end if;
  if (public.site_spec_preview_model(spec)->'tokens'->>'paper') =
     (public.site_spec_preview_model(spec)->'tokens'->>'light_neutral') then
    raise exception 'site_spec_paper: paper and light_neutral collapsed into one token.';
  end if;

  -- ---- the pairs measure the page -----------------------------------------
  c := public.site_spec_contrast(spec);
  select array_agg(p.value->>'pair_id' order by p.ord)
    into ids from jsonb_array_elements(c->'pairs') with ordinality as p(value, ord);
  if ids <> array['cta_label_on_primary','dark_neutral_on_paper','primary_on_paper',
                  'secondary_on_paper','accent_on_paper',
                  'dark_neutral_on_light_neutral','paper_on_dark_neutral'] then
    raise exception 'site_spec_paper: the pair list is %', ids;
  end if;

  -- body text on the page is measured against paper, not the band tint
  if (select p.value->>'bg' from jsonb_array_elements(c->'pairs') p
       where p.value->>'pair_id' = 'dark_neutral_on_paper') <> '#FAF6EE' then
    raise exception 'site_spec_paper: body text is still measured against the wrong surface.';
  end if;

  -- ⚠ neither surface may ever be the token a fix moves
  if exists (select 1 from jsonb_array_elements(c->'pairs') p
              where p.value->'suggested_fix'->>'token' in ('paper','light_neutral')) then
    raise exception 'site_spec_paper: a correction moves a surface.';
  end if;

  -- ---- the output states the page background ------------------------------
  if position('#FAF6EE' in (public.site_spec_output(spec, 'lovable')->>'text')) = 0 then
    raise exception 'site_spec_paper: the prompt does not state the page background.';
  end if;
  if (public.site_spec_output(spec,'lovable')->>'text') not like '%Page background — the whole page sits on this: #FAF6EE%' then
    raise exception 'site_spec_paper: the page background has no role label in the prompt.';
  end if;
  if jsonb_array_length((select s.value->'values'
                           from jsonb_array_elements(public.site_spec_output(spec,'squarespace')->'steps') s
                          where (s.value->>'n')::int = 2)) <> 6 then
    raise exception 'site_spec_paper: the setup sheet colour step does not carry six swatches.';
  end if;

  -- ---- and the editor can write it ----------------------------------------
  if not ('paper' = any (public.site_spec_patchable_keys())) then
    raise exception 'site_spec_paper: paper is not patchable.';
  end if;
  if not (public.site_spec_envelope(spec || jsonb_build_object(
            'brand_kit_id','00000000-0000-0000-0000-000000000000','spec_version',1,
            'change_marks','{}'::jsonb))->'spec' ? 'paper') then
    raise exception 'site_spec_paper: paper is not readable back from the envelope.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_spec_contrast, site_spec_preview_model, site_spec_token_lines,
--   -- site_spec_output_setup_sheet, site_spec_seed_values, seed_site_spec,
--   -- site_spec_patchable_keys, site_spec_envelope, site_spec_patch and
--   -- site_spec_reset from 20260829112000 and earlier, each WITH its
--   -- `set jit = 'off'` clause, then:
--   delete from public.site_output_templates where id = 'all.token.paper';
--   update public.site_output_templates set body = 'Light neutral — page background'
--    where id = 'all.token.light_neutral';
--   alter table public.site_specs drop constraint if exists site_specs_hex_check;
--   alter table public.site_specs
--     add constraint site_specs_hex_check check (
--       primary_hex ~ '^#[0-9A-Fa-f]{6}$' and secondary_hex ~ '^#[0-9A-Fa-f]{6}$'
--       and accent_hex ~ '^#[0-9A-Fa-f]{6}$' and light_neutral_hex ~ '^#[0-9A-Fa-f]{6}$'
--       and dark_neutral_hex ~ '^#[0-9A-Fa-f]{6}$');
--   alter table public.site_specs drop column if exists paper_hex;
