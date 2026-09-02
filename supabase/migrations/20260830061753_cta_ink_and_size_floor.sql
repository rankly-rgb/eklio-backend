-- ============================================================================
-- Eklio — the button label is text on a fill, so it gets a variant too
-- ============================================================================
-- Follows `20260829118000_text_safe_variants.sql`.
--
-- THE RULE, APPLIED WHERE IT WAS MISSED
-- -------------------------------------
-- The previous migration gave `primary`, `secondary` and `accent` a text-safe
-- variant and left `cta_label_on_primary` failing on CLAY & SAND (4.22) and
-- OLIVE & CHALK (4.06). That was framed as needing a new palette colour. It
-- does not: the button's label is **text on a fill**, and text gets a legible
-- variant. Same rule, one pair later.
--
-- `cta_ink` is that variant:
--
--   1. white, when white already reaches 4.5:1 on the primary — four of the six
--      families, and nothing about them changes;
--   2. otherwise the dark neutral, its lightness walked until it reaches 4.5:1
--      on the primary, with the same hue and saturation guarantees as the other
--      three variants;
--   3. and if neither can, the migration STOPS and names the family. Pure black
--      is not substituted: at that point the primary itself is the thing to look
--      at, and that is not a decision a migration makes.
--
-- ⚠ `dark_neutral` ITSELF DOES NOT MOVE. It is body text, it reads at 13.31 on
-- paper, and `cta_ink` is a variant of it scoped to one surface — the primary
-- fill. Like the other three, it is derived, trigger-maintained, never editable,
-- never a `suggested_fix.token`, and never a swatch.
--
-- AND A SIZE FLOOR IN THE OUTPUT
-- ------------------------------
-- 4.5:1 is the threshold for normal-size text. The moment the deliverable tells
-- a builder to put a label on a button, it is making a claim about rendered
-- size that neither Eklio nor the builder can check. So both output shapes now
-- state the floor — 18px bold, or 24px regular — as catalog copy, in her
-- language rather than WCAG's.
-- ============================================================================


-- ============================================================================
-- 1. How much hue drift is real, and how much is the 8-bit grid
-- ============================================================================
-- One place, because two migrations now need the same answer and a rule stated
-- twice is a rule that will be stated two ways.
--
-- Measured, by stepping one 8-bit channel and reading the hue back:
--
--   #6D745D  s=0.107  one step on red   -> 2.61°     (OLIVE & CHALK's variant)
--   #10100F  s=0.032  one step on green -> 30.0°     (CLAY & SAND's cta ink)
--   #10100F  s=0.032  one step on blue  -> 60.0°
--
-- Below about 0.08 saturation the encoding cannot represent a hue at all: a
-- single step swings it by half the wheel. Asserting degrees there would be
-- asserting noise. Saturation stays within 0.02 throughout and is the
-- assertion that means something on a neutral.

create or replace function public.site_spec_hue_tolerance(p_saturation numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when p_saturation >= 0.20 then 1.0    -- hue is precise here
    when p_saturation >= 0.08 then 3.0    -- one 8-bit step is up to 2.61°
    else 360.0                            -- a neutral: hue is not a property
  end
$$;

comment on function public.site_spec_hue_tolerance(numeric) is
  'How far a hue may legitimately drift at a given saturation, given 8-bit sRGB. 1 degree above 0.20 saturation, 3 below it, unconstrained below 0.08 where one channel step swings the hue by 30 to 60 degrees.';

grant execute on function public.site_spec_hue_tolerance(numeric) to authenticated, service_role;


-- ============================================================================
-- 2. cta_ink
-- ============================================================================

create or replace function public.site_spec_cta_ink(p_primary_hex text, p_dark_neutral_hex text)
returns text
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  select case
    -- white reads on this primary: use it, and change nothing
    when public.site_spec_contrast_ratio('#FFFFFF', p_primary_hex) >= 4.5 then '#FFFFFF'
    else coalesce(
      -- the dark neutral, walked until it reads on the fill
      public.site_spec_suggest_hex(p_dark_neutral_hex, p_primary_hex, 4.5),
      -- neither works. Return the better of the two rather than inventing a
      -- colour: the pair then reports its real ratio and offers to move the
      -- primary, which is the honest outcome. The guard rail below refuses to
      -- let a SHIPPED family reach this branch.
      case when public.site_spec_contrast_ratio('#FFFFFF', p_primary_hex)
                >= public.site_spec_contrast_ratio(p_dark_neutral_hex, p_primary_hex)
           then '#FFFFFF' else p_dark_neutral_hex end)
  end
$$;

comment on function public.site_spec_cta_ink(text, text) is
  'The color the call-to-action label is set in: white when white reads on the primary, otherwise the dark neutral walked down until it does. A variant of dark_neutral scoped to the primary fill; dark_neutral itself never moves.';

grant execute on function public.site_spec_cta_ink(text, text) to authenticated, service_role;


-- ============================================================================
-- 3. The columns
-- ============================================================================

alter table public.palette_families
  add column if not exists cta_ink_hex text not null default '#FF00FF';

comment on column public.palette_families.cta_ink_hex is
  'The color a call-to-action label is set in on this family''s primary. White where white reads; otherwise the dark neutral darkened until it does. Derived, never chosen.';

-- ⚠ MIRRORED IN `supabase/seed.sql`, after every earlier block.
--
--   awk '/^-- >>> PALETTE CTA INK DATA/,/^-- <<< PALETTE CTA INK DATA/' \
--     supabase/migrations/20260829119000_cta_ink_and_size_floor.sql \
--     > /tmp/palette-cta-ink.sql

-- >>> PALETTE CTA INK DATA (mirrored verbatim in supabase/seed.sql) >>>

update public.palette_families
   set cta_ink_hex = public.site_spec_cta_ink(primary_hex, dark_hex);

-- <<< PALETTE CTA INK DATA <<<

alter table public.palette_families drop constraint if exists palette_families_cta_ink_check;
alter table public.palette_families
  add constraint palette_families_cta_ink_check check (cta_ink_hex ~ '^#[0-9A-F]{6}$');

alter table public.site_specs add column if not exists cta_ink_hex text;

update public.site_specs
   set cta_ink_hex = public.site_spec_cta_ink(primary_hex, dark_neutral_hex)
 where cta_ink_hex is null;

alter table public.site_specs alter column cta_ink_hex set not null;

alter table public.site_specs drop constraint if exists site_specs_cta_ink_check;
alter table public.site_specs
  add constraint site_specs_cta_ink_check check (cta_ink_hex ~ '^#[0-9A-Fa-f]{6}$');

-- The same trigger owns it: four derived colours, one place that maintains them.
create or replace function public.maintain_site_spec_text_variants()
returns trigger
language plpgsql
set search_path = ''
set jit = 'off'
as $$
begin
  new.primary_text_hex   := public.site_spec_text_variant(new.primary_hex,   new.paper_hex);
  new.secondary_text_hex := public.site_spec_text_variant(new.secondary_hex, new.paper_hex);
  new.accent_text_hex    := public.site_spec_text_variant(new.accent_hex,    new.paper_hex);
  -- measured against the primary fill, not the page: this one is a label
  new.cta_ink_hex        := public.site_spec_cta_ink(new.primary_hex, new.dark_neutral_hex);
  return new;
end
$$;

-- The resolver gains it too, so a spec literal without the derived column
-- renders identically instead of quietly losing a line.
create or replace function public.site_spec_variant_of(p_spec jsonb, p_role text)
returns text
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  select case
    when p_role = 'cta_ink' then coalesce(
      p_spec->>'cta_ink_hex',
      public.site_spec_cta_ink(p_spec->>'primary_hex', p_spec->>'dark_neutral_hex'))
    else coalesce(
      p_spec->>(p_role || '_text_hex'),
      public.site_spec_text_variant(
        p_spec->>(p_role || '_hex'),
        coalesce(p_spec->>'paper_hex', p_spec->>'light_neutral_hex')))
  end
$$;


-- ============================================================================
-- 4. The mockup, and the pair that changes meaning
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
      'primary_text',     public.site_spec_variant_of(p_spec, 'primary'),
      'secondary_text',   public.site_spec_variant_of(p_spec, 'secondary'),
      'accent_text',      public.site_spec_variant_of(p_spec, 'accent'),
      -- the label on the primary fill
      'cta_ink',          public.site_spec_variant_of(p_spec, 'cta_ink'),
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

-- ⚠ `cta_label_on_primary`'s `fg` stops being "white or the dark neutral,
-- whichever reads better" and becomes `cta_ink`. The frontend was already told
-- to render whatever `fg` it receives, so nothing changes on that side.
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
           coalesce(p_spec->>'paper_hex', p_spec->>'light_neutral_hex') as paper_hex,
           public.site_spec_variant_of(p_spec, 'primary')   as primary_text_hex,
           public.site_spec_variant_of(p_spec, 'secondary') as secondary_text_hex,
           public.site_spec_variant_of(p_spec, 'accent')    as accent_text_hex,
           public.site_spec_variant_of(p_spec, 'cta_ink')   as cta_ink_hex
  ),
  defs as (
    select * from (values
      ('cta_label_on_primary',          'Button label on your primary color',   1),
      ('dark_neutral_on_paper',         'Body text on the page',                2),
      ('primary_on_paper',              'Primary color as text on the page',    3),
      ('secondary_on_paper',            'Secondary color as text on the page',  4),
      ('accent_on_paper',               'Accent color as text on the page',     5),
      ('dark_neutral_on_light_neutral', 'Body text on a tinted section',        6),
      ('paper_on_dark_neutral',         'Light text on a dark section',         7)
    ) as d(pair_id, label, ord)
  ),
  pairs as (
    select d.pair_id, d.label, d.ord,
      case d.pair_id
        when 'cta_label_on_primary'          then t.cta_ink_hex
        when 'dark_neutral_on_paper'         then t.dark_neutral_hex
        when 'primary_on_paper'              then t.primary_text_hex
        when 'secondary_on_paper'            then t.secondary_text_hex
        when 'accent_on_paper'               then t.accent_text_hex
        when 'dark_neutral_on_light_neutral' then t.dark_neutral_hex
        when 'paper_on_dark_neutral'         then t.paper_hex
      end as fg,
      case d.pair_id
        when 'cta_label_on_primary'          then t.primary_hex
        when 'dark_neutral_on_light_neutral' then t.light_neutral_hex
        when 'paper_on_dark_neutral'         then t.dark_neutral_hex
        else t.paper_hex
      end as bg,
      case d.pair_id
        when 'cta_label_on_primary'          then 'primary'
        when 'dark_neutral_on_paper'         then 'dark_neutral'
        when 'primary_on_paper'              then 'primary'
        when 'secondary_on_paper'            then 'secondary'
        when 'accent_on_paper'               then 'accent'
        when 'dark_neutral_on_light_neutral' then 'dark_neutral'
        when 'paper_on_dark_neutral'         then 'dark_neutral'
      end as move_token,
      case d.pair_id
        when 'cta_label_on_primary'          then t.primary_hex
        when 'dark_neutral_on_paper'         then t.dark_neutral_hex
        when 'primary_on_paper'              then t.primary_hex
        when 'secondary_on_paper'            then t.secondary_hex
        when 'accent_on_paper'               then t.accent_hex
        when 'dark_neutral_on_light_neutral' then t.dark_neutral_hex
        when 'paper_on_dark_neutral'         then t.dark_neutral_hex
      end as move_hex
      from defs d cross join tok t
  ),
  scored as (
    select p.*,
           public.site_spec_contrast_ratio(p.fg, p.bg) as ratio,
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
-- 5. The output states the ink and the size floor
-- ============================================================================

-- >>> CTA INK TEMPLATE DATA (mirrored verbatim in supabase/seed.sql) >>>

insert into public.site_output_templates (id, target, key, body, sort_order) values
  ('all.token.cta_ink', null, 'token.cta_ink',
   'Button label ink — the color the label is set in, on the primary fill', 33),
  ('all.constraint.cta_min_size', null, 'constraint.cta_min_size',
   'Do not set the call-to-action label below 18px bold, or 24px if it is not bold. The button''s two colors were checked for text at that size; below it the same pair stops being legible enough.', 44),
  ('all.sheet.label_cta_ink', null, 'sheet.label_cta_ink', 'Button label color', 67),
  ('all.sheet.label_cta_min_size', null, 'sheet.label_cta_min_size',
   'Smallest the label may be set', 68),
  ('all.sheet.value_cta_min_size', null, 'sheet.value_cta_min_size',
   '18px bold, or 24px if it is not bold', 69)
on conflict (id) do update set body = excluded.body, sort_order = excluded.sort_order;

-- <<< CTA INK TEMPLATE DATA <<<

create or replace function public.site_spec_token_lines(p_spec jsonb, p_frag jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select array_to_string(array[
    (p_frag->>'token.primary')        || ': ' || (p_spec->>'primary_hex'),
    (p_frag->>'token.primary_text')   || ': ' || public.site_spec_variant_of(p_spec, 'primary'),
    (p_frag->>'token.secondary')      || ': ' || (p_spec->>'secondary_hex'),
    (p_frag->>'token.secondary_text') || ': ' || public.site_spec_variant_of(p_spec, 'secondary'),
    (p_frag->>'token.accent')         || ': ' || (p_spec->>'accent_hex'),
    (p_frag->>'token.accent_text')    || ': ' || public.site_spec_variant_of(p_spec, 'accent'),
    (p_frag->>'token.cta_ink')        || ': ' || public.site_spec_variant_of(p_spec, 'cta_ink'),
    (p_frag->>'token.paper')          || ': ' || (p_spec->>'paper_hex'),
    (p_frag->>'token.light_neutral')  || ': ' || (p_spec->>'light_neutral_hex'),
    (p_frag->>'token.dark_neutral')   || ': ' || (p_spec->>'dark_neutral_hex'),
    '',
    p_frag->>'token.text_variant_note',
    '',
    (p_frag->>'token.heading_font')     || ': ' || (p_spec->>'heading_font'),
    (p_frag->>'token.body_font')        || ': ' || (p_spec->>'body_font'),
    (p_frag->>'token.google_fonts_url') || ': ' || (p_spec->>'google_fonts_url')
  ], E'\n')
$$;

-- ⚠ SIX CONSTRAINT LINES NOW, not five. The size floor is a constraint because
-- it is a claim the deliverable makes and the builder cannot check.
create or replace function public.site_spec_constraint_lines(p_spec jsonb, p_frag jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    p_frag->>'constraint.copy_exact',
    p_frag->>'constraint.no_invention',
    p_frag->>'constraint.no_stock_photos',
    case when nullif(btrim(coalesce(p_spec->'hero'->>'cta_target_url', '')), '') is not null
      then public.site_output_fill(p_frag->>'constraint.cta_linked',
             jsonb_build_object('cta_target_url', btrim(p_spec->'hero'->>'cta_target_url')))
      else p_frag->>'constraint.cta_unlinked'
    end,
    p_frag->>'constraint.cta_min_size',
    p_frag->>'constraint.contrast'
  ]
$$;

-- The setup sheet's button step gains the ink and the size floor. They belong
-- there rather than with the palette: she is setting up the button.
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
           (select f->>'sheet.step_text_title' from frag),
           (select f->>'sheet.step_text_body' from frag),
           jsonb_build_array(
             jsonb_build_object('label', (select f->>'token.primary_text' from frag),
                                'value', public.site_spec_variant_of(p_spec, 'primary'), 'kind', 'hex'),
             jsonb_build_object('label', (select f->>'token.secondary_text' from frag),
                                'value', public.site_spec_variant_of(p_spec, 'secondary'), 'kind', 'hex'),
             jsonb_build_object('label', (select f->>'token.accent_text' from frag),
                                'value', public.site_spec_variant_of(p_spec, 'accent'), 'kind', 'hex')),
           (select color_panel from bt)
    union all
    select 4,
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
    select 5,
           (select f->>'sheet.step4_title' from frag),
           (select f->>'sheet.step4_body' from frag)
             || E'\n\n' || coalesce(public.site_spec_structure_lines(p_spec, (select f from frag)), ''),
           '[]'::jsonb,
           (select section_panel from bt)
    union all
    select 6,
           (select f->>'sheet.step5_title' from frag),
           (select f->>'sheet.step5_body' from frag),
           '[]'::jsonb,
           null
    union all
    select 7,
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
                   else '[]'::jsonb end
           || jsonb_build_array(
                jsonb_build_object('label', (select f->>'sheet.label_cta_ink' from frag),
                                   'value', public.site_spec_variant_of(p_spec, 'cta_ink'), 'kind', 'hex'),
                jsonb_build_object('label', (select f->>'sheet.label_cta_min_size' from frag),
                                   'value', (select f->>'sheet.value_cta_min_size' from frag), 'kind', 'text')),
           null
    union all
    select 8,
           (select f->>'sheet.step7_title' from frag),
           (select string_agg('[ ] ' || c.line, E'\n' order by c.ord)
              from unnest(public.site_spec_constraint_lines(p_spec, (select f from frag)))
                   with ordinality as c(line, ord)),
           '[]'::jsonb,
           null
    union all
    select 9,
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
-- 6. Guard rails
-- ============================================================================
do $$
declare
  r      record;
  n      int;
  spec   jsonb;
  best   numeric;
  sat    numeric; ds numeric; dh numeric;
begin
  if exists (select 1 from public.palette_families where cta_ink_hex = '#FF00FF') then
    raise exception 'cta_ink: a family still carries the #FF00FF placeholder.';
  end if;

  for r in select * from public.palette_families order by sort_order loop
    -- ⚠ IF NEITHER WHITE NOR THE WALKED DARK NEUTRAL REACHES 4.5, STOP AND SAY SO.
    if public.site_spec_contrast_ratio(r.cta_ink_hex, r.primary_hex) < 4.5 then
      best := greatest(public.site_spec_contrast_ratio('#FFFFFF', r.primary_hex),
                       public.site_spec_contrast_ratio(r.dark_hex, r.primary_hex));
      raise exception
        'cta_ink: % cannot get a legible button label on primary %. Best achievable is %:1 (white %:1, dark neutral %:1). Pure black is not substituted — look at the primary.',
        r.id, r.primary_hex, best,
        public.site_spec_contrast_ratio('#FFFFFF', r.primary_hex),
        public.site_spec_contrast_ratio(r.dark_hex, r.primary_hex);
    end if;

    -- white where white reads, and nothing else touched
    if public.site_spec_contrast_ratio('#FFFFFF', r.primary_hex) >= 4.5
       and r.cta_ink_hex <> '#FFFFFF' then
      raise exception 'cta_ink: white reads on %''s primary and was not used.', r.id;
    end if;

    -- when it is a walked dark neutral, it is still that colour
    if r.cta_ink_hex <> '#FFFFFF' then
      sat := (public.site_spec_hex_to_hsl(r.dark_hex))[2];
      ds  := abs((public.site_spec_hex_to_hsl(r.cta_ink_hex))[2] - sat);
      dh  := abs((((public.site_spec_hex_to_hsl(r.cta_ink_hex))[1]
                   - (public.site_spec_hex_to_hsl(r.dark_hex))[1] + 540)::numeric % 360) - 180);
      if ds > 0.02 then
        raise exception 'cta_ink: %''s ink moved the dark neutral''s saturation by %.', r.id, ds;
      end if;
      if dh > public.site_spec_hue_tolerance(sat) then
        raise exception 'cta_ink: %''s ink moved the hue by %° at saturation % (limit %°).',
          r.id, dh, round(sat,3), public.site_spec_hue_tolerance(sat);
      end if;
    end if;

    -- ⚠ dark_neutral ITSELF did not move
    if public.site_spec_contrast_ratio(r.dark_hex, r.paper_hex) < 4.5 then
      raise exception 'cta_ink: %''s dark neutral stopped reading as body text.', r.id;
    end if;
  end loop;

  -- ---- ⚠ 42 OF 42 ---------------------------------------------------------
  select count(*) into n
    from public.palette_families pf
    cross join lateral jsonb_array_elements(public.site_spec_contrast(jsonb_build_object(
      'primary_hex', pf.primary_hex, 'secondary_hex', pf.secondary_hex,
      'accent_hex', pf.accent_hex, 'light_neutral_hex', pf.light_hex,
      'dark_neutral_hex', pf.dark_hex, 'paper_hex', pf.paper_hex,
      'primary_text_hex', pf.primary_text_hex, 'secondary_text_hex', pf.secondary_text_hex,
      'accent_text_hex', pf.accent_text_hex, 'cta_ink_hex', pf.cta_ink_hex))->'pairs') p
   where (p.value->>'ratio')::numeric < 4.5;
  if n > 0 then
    raise exception 'cta_ink: % of 42 pairs still below AA across the shipped families.', n;
  end if;
  raise notice 'shipped palettes: 42 of 42 pairs at AA or better.';

  -- ---- the size floor is stated in both shapes ----------------------------
  spec := jsonb_build_object(
    'primary_hex','#B4674A','secondary_hex','#C08A3E','accent_hex','#6E3320',
    'light_neutral_hex','#F4EEE3','dark_neutral_hex','#2B2A27','paper_hex','#FAF6EE',
    'heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','u',
    'about_excerpt','x','practice_details','{}'::jsonb,
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s',
                               'cta_label','c','cta_target_url','https://x.example/b'),
    'pages', public.site_spec_default_pages(null,null), 'target','lovable');

  if array_length(public.site_spec_constraint_lines(spec, public.site_output_fragments(null)), 1) <> 6 then
    raise exception 'cta_ink: the constraints block does not emit six lines.';
  end if;
  if (public.site_spec_output(spec, 'lovable')->>'text') not like '%18px bold%' then
    raise exception 'cta_ink: the prompt does not state the button size floor.';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(public.site_spec_output(spec,'squarespace')->'steps') s
    cross join lateral jsonb_array_elements(s.value->'values') v
     where (s.value->>'n')::int = 7 and v.value->>'value' like '%18px bold%'
  ) then
    raise exception 'cta_ink: the setup sheet''s button step does not state the size floor.';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(public.site_spec_output(spec,'squarespace')->'steps') s
    cross join lateral jsonb_array_elements(s.value->'values') v
     where (s.value->>'n')::int = 7 and v.value->>'label' = 'Button label color'
  ) then
    raise exception 'cta_ink: the setup sheet''s button step does not state the label colour.';
  end if;

  -- ---- never a fix token --------------------------------------------------
  if exists (
    select 1 from public.palette_families pf
    cross join lateral jsonb_array_elements(public.site_spec_contrast(jsonb_build_object(
      'primary_hex', pf.primary_hex, 'secondary_hex', pf.secondary_hex,
      'accent_hex', pf.accent_hex, 'light_neutral_hex', pf.light_hex,
      'dark_neutral_hex', pf.dark_hex, 'paper_hex', pf.paper_hex))->'pairs') p
     where p.value->'suggested_fix'->>'token' in ('cta_ink', 'primary_text', 'secondary_text', 'accent_text')
  ) then
    raise exception 'cta_ink: a derived colour was offered as a suggested_fix token.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_spec_contrast, site_spec_preview_model, site_spec_token_lines,
--   -- site_spec_constraint_lines, site_spec_output_setup_sheet,
--   -- site_spec_variant_of and maintain_site_spec_text_variants from
--   -- 20260829118000, each WITH its `set jit = 'off'` clause, then:
--   delete from public.site_output_templates
--    where key in ('token.cta_ink','constraint.cta_min_size','sheet.label_cta_ink',
--                  'sheet.label_cta_min_size','sheet.value_cta_min_size');
--   alter table public.site_specs drop constraint if exists site_specs_cta_ink_check;
--   alter table public.site_specs drop column if exists cta_ink_hex;
--   alter table public.palette_families drop constraint if exists palette_families_cta_ink_check;
--   alter table public.palette_families drop column if exists cta_ink_hex;
--   drop function if exists public.site_spec_cta_ink(text, text);
--   drop function if exists public.site_spec_hue_tolerance(numeric);
