-- ============================================================================
-- Eklio — a text-safe variant per brand color, instead of correcting the brand
-- ============================================================================
-- Follows `20260829117000_step_title_counts.sql`.
--
-- THE DECISION THIS IMPLEMENTS
-- ---------------------------
-- The audit found seven pairs below AA across the six shipped families, two of
-- them badly: `#C08A3E` at 2.80 as CLAY & SAND's secondary and 2.85 as
-- OCHRE & PAPER's primary. Correcting the brand colour would have moved it
-- ΔE 17 — ochre to a duller olive-gold, on palettes a person chose by hand.
--
-- **4.5:1 is a text legibility threshold.** `#C08A3E` fails it as text. As a
-- fill — a band, a button with dark text on it, a swatch, a rule — it was never
-- a problem. The colour is not wrong; one of its uses is.
--
-- So every curated hex stays byte-identical, and each of `primary`, `secondary`
-- and `accent` gains a text-safe variant: the same hue and chroma, lightness
-- lowered only as far as 4.5:1 against that family's own `paper` requires.
-- A brand colour plus a legible variant of it — what a design system does.
--
-- ⚠ WHERE THE BRAND COLOUR ALREADY PASSES, THE VARIANT IS THE BRAND COLOUR.
-- Not a rounded near-miss of it: the same string. A colour that does not need
-- moving is not moved, and the guard rail asserts it for all six families.
--
-- ⚠ THE VARIANT IS DERIVED, NEVER SET. It is maintained by a trigger on
-- `site_specs`, it is absent from `spec` in the envelope, it is not patchable,
-- and it can never be a `suggested_fix.token`. She has no control that
-- corresponds to it, so nothing may ask her to think about one.
-- ============================================================================


-- ============================================================================
-- 1. The variant
-- ============================================================================
-- `site_spec_suggest_hex` already does exactly this walk and already keeps hue
-- within 1° and saturation within 0.02. The only thing added here is the
-- "already passes" short circuit and totality.

create or replace function public.site_spec_text_variant(p_brand_hex text, p_paper_hex text)
returns text
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  select case
    -- already legible as text: do not move a colour that does not need moving
    when public.site_spec_contrast_ratio(p_brand_hex, p_paper_hex) >= 4.5
      then p_brand_hex
    -- otherwise the closest lightness of the same hue that reads, or — if no
    -- lightness of that hue reads on this page at all — the brand colour back
    -- again, because a variant that is not the colour is worse than a warning
    else coalesce(public.site_spec_suggest_hex(p_brand_hex, p_paper_hex, 4.5), p_brand_hex)
  end
$$;

comment on function public.site_spec_text_variant(text, text) is
  'The text-safe variant of a brand color on a given page background: same hue and chroma, lightness lowered only as far as 4.5:1 requires. Returns the brand color unchanged when it already passes, and when no lightness of that hue can pass.';

grant execute on function public.site_spec_text_variant(text, text) to authenticated, service_role;

-- The variant of one role on a given spec: the stored column when the spec is a
-- row, computed when it is a literal that carries only the brand colours. Every
-- renderer goes through this rather than reading the column, so a spec without
-- the derived columns produces the same output instead of quietly losing lines.
create or replace function public.site_spec_variant_of(p_spec jsonb, p_role text)
returns text
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  select coalesce(
    p_spec->>(p_role || '_text_hex'),
    public.site_spec_text_variant(
      p_spec->>(p_role || '_hex'),
      coalesce(p_spec->>'paper_hex', p_spec->>'light_neutral_hex')))
$$;

grant execute on function public.site_spec_variant_of(jsonb, text) to authenticated, service_role;


-- ============================================================================
-- 2. The catalog columns
-- ============================================================================
-- Added with the debug-magenta default for the reason `accent_hex` has one —
-- `supabase/seed.sql` replays a catalog upsert written before these columns
-- existed, and `ON CONFLICT DO UPDATE` validates NOT NULL on the proposed tuple
-- before it detects the conflict. The guard rail refuses any family still
-- carrying it.

alter table public.palette_families
  add column if not exists primary_text_hex   text not null default '#FF00FF',
  add column if not exists secondary_text_hex text not null default '#FF00FF',
  add column if not exists accent_text_hex    text not null default '#FF00FF';

comment on column public.palette_families.primary_text_hex is
  'The primary, darkened only as far as 4.5:1 against this family''s paper requires. Equal to primary_hex when that already passes. Derived, never chosen.';

-- ⚠ MIRRORED IN `supabase/seed.sql`, after every earlier block.
--
--   awk '/^-- >>> PALETTE TEXT VARIANT DATA/,/^-- <<< PALETTE TEXT VARIANT DATA/' \
--     supabase/migrations/20260829118000_text_safe_variants.sql \
--     > /tmp/palette-text-variants.sql
--
-- Computed rather than typed: these are derived values, and hand-writing them
-- would be six more numbers to keep in step with six colours and six papers.

-- >>> PALETTE TEXT VARIANT DATA (mirrored verbatim in supabase/seed.sql) >>>

update public.palette_families
   set primary_text_hex   = public.site_spec_text_variant(primary_hex,   paper_hex),
       secondary_text_hex = public.site_spec_text_variant(secondary_hex, paper_hex),
       accent_text_hex    = public.site_spec_text_variant(accent_hex,    paper_hex);

-- <<< PALETTE TEXT VARIANT DATA <<<

alter table public.palette_families drop constraint if exists palette_families_text_hex_check;
alter table public.palette_families
  add constraint palette_families_text_hex_check check (
    primary_text_hex   ~ '^#[0-9A-F]{6}$'
    and secondary_text_hex ~ '^#[0-9A-F]{6}$'
    and accent_text_hex    ~ '^#[0-9A-F]{6}$'
  );


-- ============================================================================
-- 3. The spec columns, maintained by trigger
-- ============================================================================
-- ⚠ A TRIGGER, NOT A PATCH BRANCH, for the reason the site_prompt cache is one:
-- it then covers every write path — the seeder, the patch, the reset, the
-- target switch, the contrast fix, and a correction made by hand with
-- `service_role`. A derived value maintained by whichever callers remembered is
-- a derived value that drifts.
--
-- It recomputes unconditionally. Three calls to a walk that costs a tenth of a
-- millisecond warm is cheaper than the branching needed to skip them, and it
-- cannot be wrong.
--
-- BEFORE, so the values are in place when the NOT NULL and the CHECK are
-- evaluated, and so `returning *` hands the caller the row that was stored.

alter table public.site_specs
  add column if not exists primary_text_hex   text,
  add column if not exists secondary_text_hex text,
  add column if not exists accent_text_hex    text;

update public.site_specs
   set primary_text_hex   = public.site_spec_text_variant(primary_hex,   paper_hex),
       secondary_text_hex = public.site_spec_text_variant(secondary_hex, paper_hex),
       accent_text_hex    = public.site_spec_text_variant(accent_hex,    paper_hex)
 where primary_text_hex is null;

alter table public.site_specs
  alter column primary_text_hex   set not null,
  alter column secondary_text_hex set not null,
  alter column accent_text_hex    set not null;

alter table public.site_specs drop constraint if exists site_specs_text_hex_check;
alter table public.site_specs
  add constraint site_specs_text_hex_check check (
    primary_text_hex   ~ '^#[0-9A-Fa-f]{6}$'
    and secondary_text_hex ~ '^#[0-9A-Fa-f]{6}$'
    and accent_text_hex    ~ '^#[0-9A-Fa-f]{6}$'
  );

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
  return new;
end
$$;

-- ⚠ Ordered before `set_site_specs_updated_at` and
-- `retire_site_spec_clamp_notes` by name, which is how Postgres breaks ties
-- among BEFORE triggers. None of the three reads what another writes, so the
-- order is not load-bearing — but it is deterministic, which is worth having.
drop trigger if exists maintain_site_spec_text_variants on public.site_specs;
create trigger maintain_site_spec_text_variants
  before insert or update on public.site_specs
  for each row execute function public.maintain_site_spec_text_variants();

-- ⚠ NOT GRANTED TO CLIENTS. `revoke update` from the site-spec migration
-- already withheld every column not explicitly granted, and these three are
-- deliberately never added to that grant: she has no control for them.


-- ============================================================================
-- 4. The mockup gets both
-- ============================================================================
-- Six brand tokens and three text variants. Which one a given element uses is a
-- rendering rule the contract states; the model's job is to make both available
-- and to leave no doubt which is which.

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
      -- the same three, for when the colour is text on the page
      'primary_text',     public.site_spec_variant_of(p_spec, 'primary'),
      'secondary_text',   public.site_spec_variant_of(p_spec, 'secondary'),
      'accent_text',      public.site_spec_variant_of(p_spec, 'accent'),
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
-- 5. Contrast measures what is actually painted
-- ============================================================================
-- ⚠ THREE PAIRS CHANGE MEANING. `primary_on_paper`, `secondary_on_paper` and
-- `accent_on_paper` measure a brand colour AS TEXT, so they now measure the
-- **variant** against paper. That is the value the mockup paints for a heading
-- or a link, and measuring the brand colour there was measuring a use that does
-- not exist.
--
-- `cta_label_on_primary` is unchanged and must be: it is a label on a FILL, and
-- the fill is the brand colour.
--
-- ⚠ A FIX STILL MOVES THE BRAND COLOUR. If one of the three fails — which now
-- means no lightness of that hue reads on this page at all — the token to move
-- is `primary`, `secondary` or `accent`, never the variant, because the variant
-- is recomputed from whatever the brand becomes. `suggested_fix.token` can
-- never name a variant.

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
           -- fall back to computing them, so the function stays pure and can be
           -- called on a spec literal that carries only the brand colours
           public.site_spec_variant_of(p_spec, 'primary')   as primary_text_hex,
           public.site_spec_variant_of(p_spec, 'secondary') as secondary_text_hex,
           public.site_spec_variant_of(p_spec, 'accent')    as accent_text_hex
  ),
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
        when 'cta_label_on_primary'          then (select fg from cta)
        when 'dark_neutral_on_paper'         then t.dark_neutral_hex
        -- the three that measure a brand colour AS TEXT
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
      -- ⚠ the hex a fix walks is always the BRAND colour, never the variant
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
-- 6. The output states both, with their roles
-- ============================================================================
-- ⚠ THE DISTINCTION HAS TO SURVIVE BEING PASTED. The reader is a therapist with
-- Squarespace open, or a builder that will happily use one hex everywhere. So
-- the labels say what each value is FOR, and a rule line says not to swap them.
--
-- The existing brand labels change too: "Primary — buttons, links and active
-- states" named links, and links are text. That label was describing the wrong
-- use the moment the variant existed.

-- >>> TEXT VARIANT TEMPLATE DATA (mirrored verbatim in supabase/seed.sql) >>>

insert into public.site_output_templates (id, target, key, body, sort_order) values
  ('all.token.primary_text',   null, 'token.primary_text',
   'Primary as text — headings and links on the page', 30),
  ('all.token.secondary_text', null, 'token.secondary_text',
   'Secondary as text — supporting headings on the page', 31),
  ('all.token.accent_text',    null, 'token.accent_text',
   'Accent as text — small highlighted words', 32),
  ('all.token.text_variant_note', null, 'token.text_variant_note',
   'The three "as text" values are the same brand colors, darkened only as far as legibility requires. Use an "as text" value wherever the color is text. Use the brand color for fills, bands, buttons and borders. Do not substitute one for the other, and do not add either to the palette twice.', 38),
  ('all.sheet.step_text_title', null, 'sheet.step_text_title',
   'Add the text versions of those three colors', 53),
  ('all.sheet.step_text_body', null, 'sheet.step_text_body',
   'These are the same three brand colors, darkened just enough to be readable as text on your page background. Add them alongside the others. Use them for headings and links; keep the brighter originals for fills, bands and buttons.', 54)
on conflict (id) do update set
  body = excluded.body, sort_order = excluded.sort_order;

update public.site_output_templates set body =
  'Primary — fills, buttons, bands and borders'      where id = 'all.token.primary';
update public.site_output_templates set body =
  'Secondary — supporting surfaces and fills'        where id = 'all.token.secondary';
update public.site_output_templates set body =
  'Accent — small marks, rules and selected states'  where id = 'all.token.accent';

-- <<< TEXT VARIANT TEMPLATE DATA <<<

create or replace function public.site_spec_token_lines(p_spec jsonb, p_frag jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select array_to_string(array[
    -- ⚠ COALESCED, NOT READ BLIND. `'label' || ': ' || NULL` is NULL, and
    -- `array_to_string` drops NULLs silently — a spec literal without the
    -- derived columns would lose three lines from the deliverable and nothing
    -- would say so. Same fallback `site_spec_contrast` uses.
    (p_frag->>'token.primary')        || ': ' || (p_spec->>'primary_hex'),
    (p_frag->>'token.primary_text')   || ': ' || public.site_spec_variant_of(p_spec, 'primary'),
    (p_frag->>'token.secondary')      || ': ' || (p_spec->>'secondary_hex'),
    (p_frag->>'token.secondary_text') || ': ' || public.site_spec_variant_of(p_spec, 'secondary'),
    (p_frag->>'token.accent')         || ': ' || (p_spec->>'accent_hex'),
    (p_frag->>'token.accent_text')    || ': ' || public.site_spec_variant_of(p_spec, 'accent'),
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

-- The setup sheet gains a step of its own for the variants, rather than nine
-- flat swatches under one heading: a therapist entering colours into a palette
-- panel needs to know which three are alternates of which.
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
    -- ⚠ its own step: three alternates, named as alternates
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
                   else '[]'::jsonb end,
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
-- 7. Guard rails
-- ============================================================================
do $$
declare
  r    record;
  n    int;
  spec jsonb;
  col  text;
  hb   text;
  ht   text;
  sat  numeric;
  ds   numeric;
  dh   numeric;
  tol  numeric;
begin
  -- ---- the six curated hexes did NOT move ---------------------------------
  -- That is the entire point of this migration, so it is asserted rather than
  -- trusted.
  if (select count(*) from public.palette_families pf
       where (pf.id, pf.primary_hex, pf.secondary_hex, pf.accent_hex) in (
         ('plum_bone',      '#3B2C3A', '#4A5361', '#6E2F44'),
         ('clay_sand',      '#B4674A', '#C08A3E', '#6E3320'),
         ('ink_blue_chalk', '#22364F', '#7A8168', '#8F5324'),
         ('olive_chalk',    '#7A8168', '#3F4536', '#8C5624'),
         ('ochre_paper',    '#C08A3E', '#6B4B1C', '#A34A2A'),
         ('slate_bone',     '#4A5361', '#2F3742', '#8E4A3C'))) <> 6 then
    raise exception
      'text_safe_variants: a curated brand hex moved. The whole point of the variant is that none of them does.';
  end if;

  if exists (select 1 from public.palette_families
              where '#FF00FF' in (primary_text_hex, secondary_text_hex, accent_text_hex)) then
    raise exception 'text_safe_variants: a family still carries the #FF00FF placeholder.';
  end if;

  for r in select * from public.palette_families order by sort_order loop
    -- ⚠ a colour that already passes is NOT moved
    if public.site_spec_contrast_ratio(r.primary_hex, r.paper_hex) >= 4.5
       and r.primary_text_hex <> r.primary_hex then
      raise exception 'text_safe_variants: %''s primary already passed and was moved anyway.', r.id;
    end if;
    if public.site_spec_contrast_ratio(r.secondary_hex, r.paper_hex) >= 4.5
       and r.secondary_text_hex <> r.secondary_hex then
      raise exception 'text_safe_variants: %''s secondary already passed and was moved anyway.', r.id;
    end if;
    if public.site_spec_contrast_ratio(r.accent_hex, r.paper_hex) >= 4.5
       and r.accent_text_hex <> r.accent_hex then
      raise exception 'text_safe_variants: %''s accent already passed and was moved anyway.', r.id;
    end if;

    -- every variant reads as text on its own page
    if public.site_spec_contrast_ratio(r.primary_text_hex, r.paper_hex) < 4.5
       or public.site_spec_contrast_ratio(r.secondary_text_hex, r.paper_hex) < 4.5
       or public.site_spec_contrast_ratio(r.accent_text_hex, r.paper_hex) < 4.5 then
      raise exception 'text_safe_variants: a variant of % is not legible on its own paper.', r.id;
    end if;

    -- ⚠ AND IS STILL THE SAME COLOUR. Saturation within 0.02 everywhere — the
    -- worst observed across the six families is 0.0028.
    --
    -- Hue within 1° where 1° means anything, and within 3° below 0.20
    -- saturation where it does not. That second bound is the 8-bit grid, not
    -- slack in the walk: at OLIVE & CHALK's chroma (s = 0.107) a single step on
    -- one channel moves the hue by up to 2.61°, measured —
    --
    --     #6D745D -> #6C745D   hue 78.26 -> 80.87   (one step on red)
    --
    -- so a 1° promise there is a promise sRGB cannot keep. The observed drift
    -- is 1.46°, smaller than one step on two of the three channels.
    foreach col in array array['primary', 'secondary', 'accent'] loop
      case col
        when 'primary'   then hb := r.primary_hex;   ht := r.primary_text_hex;
        when 'secondary' then hb := r.secondary_hex; ht := r.secondary_text_hex;
        else                  hb := r.accent_hex;    ht := r.accent_text_hex;
      end case;

      sat := (public.site_spec_hex_to_hsl(hb))[2];
      ds  := abs((public.site_spec_hex_to_hsl(ht))[2] - sat);
      dh  := abs((((public.site_spec_hex_to_hsl(ht))[1]
                   - (public.site_spec_hex_to_hsl(hb))[1] + 540)::numeric % 360) - 180);
      tol := case when sat >= 0.20 then 1.0 else 3.0 end;

      if ds > 0.02 then
        raise exception 'text_safe_variants: %''s % variant moved saturation by % (limit 0.02).',
          r.id, col, ds;
      end if;
      if dh > tol then
        raise exception 'text_safe_variants: %''s % variant moved hue by %° at saturation % (limit %°).',
          r.id, col, dh, round(sat, 3), tol;
      end if;
    end loop;
  end loop;

  -- ---- ⚠ WHAT THE VARIANT GUARANTEES: the three text-on-paper pairs -------
  -- 18 of 18 across the six families. This is the assertion, because this is
  -- what a text-safe variant is for.
  select count(*) into n
    from public.palette_families pf
    cross join lateral jsonb_array_elements(public.site_spec_contrast(jsonb_build_object(
      'primary_hex', pf.primary_hex, 'secondary_hex', pf.secondary_hex,
      'accent_hex', pf.accent_hex, 'light_neutral_hex', pf.light_hex,
      'dark_neutral_hex', pf.dark_hex, 'paper_hex', pf.paper_hex,
      'primary_text_hex', pf.primary_text_hex,
      'secondary_text_hex', pf.secondary_text_hex,
      'accent_text_hex', pf.accent_text_hex))->'pairs') p
   where p.value->>'pair_id' in ('primary_on_paper','secondary_on_paper','accent_on_paper')
     and (p.value->>'ratio')::numeric < 4.5;
  if n > 0 then
    raise exception
      'text_safe_variants: % of 18 text-on-paper pairs still below AA. The variant did not do its job.', n;
  end if;

  -- ---- ⚠ AND WHAT IT DOES NOT: 40 of 42, reported, not forced -------------
  -- The two that remain are both `cta_label_on_primary` on CLAY & SAND (4.22)
  -- and OLIVE & CHALK (4.06). That pair is a label on a FILL, which is exactly
  -- the use a text variant must not touch — and the shortfall is not the
  -- primary, it is the label palette. Measured, on those two primaries:
  --
  --                white   dark_neutral   black
  --   #B4674A       4.22       3.40        4.98
  --   #7A8168       4.06       3.60        5.17
  --
  -- The mockup chooses between white and the dark neutral, and on a mid-
  -- lightness primary neither reads. Black would, on both — but black is not in
  -- the palette, and putting it there is a design decision, not a migration.
  -- Both pairs are AA_large, which a call-to-action button at 18px bold or more
  -- already satisfies. Left as a reported warning, deliberately.
  select count(*) into n
    from public.palette_families pf
    cross join lateral jsonb_array_elements(public.site_spec_contrast(jsonb_build_object(
      'primary_hex', pf.primary_hex, 'secondary_hex', pf.secondary_hex,
      'accent_hex', pf.accent_hex, 'light_neutral_hex', pf.light_hex,
      'dark_neutral_hex', pf.dark_hex, 'paper_hex', pf.paper_hex,
      'primary_text_hex', pf.primary_text_hex,
      'secondary_text_hex', pf.secondary_text_hex,
      'accent_text_hex', pf.accent_text_hex))->'pairs') p
   where (p.value->>'ratio')::numeric < 4.5;
  raise notice 'shipped palettes: % of 42 pairs below AA (both are cta_label_on_primary, a label on a fill).', n;
  if n > 2 then
    raise exception
      'text_safe_variants: % of 42 pairs below AA, more than the two known cta_label_on_primary cases.', n;
  end if;

  -- ---- a variant is never offered as a fix --------------------------------
  if exists (
    select 1 from public.palette_families pf
    cross join lateral jsonb_array_elements(public.site_spec_contrast(jsonb_build_object(
      'primary_hex', pf.primary_hex, 'secondary_hex', pf.secondary_hex,
      'accent_hex', pf.accent_hex, 'light_neutral_hex', pf.light_hex,
      'dark_neutral_hex', pf.dark_hex, 'paper_hex', pf.paper_hex))->'pairs') p
     where p.value->'suggested_fix'->>'token' like '%_text'
  ) then
    raise exception 'text_safe_variants: a variant was offered as a suggested_fix token.';
  end if;

  -- ---- the output states both ---------------------------------------------
  spec := jsonb_build_object(
    'primary_hex','#B4674A','secondary_hex','#C08A3E','accent_hex','#6E3320',
    'primary_text_hex','#A35D43','secondary_text_hex','#92692F','accent_text_hex','#6E3320',
    'light_neutral_hex','#F4EEE3','dark_neutral_hex','#2B2A27','paper_hex','#FAF6EE',
    'heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','u',
    'about_excerpt','x','practice_details','{}'::jsonb,
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'pages', public.site_spec_default_pages(null,null), 'target','lovable');

  if position('#B4674A' in (public.site_spec_output(spec,'lovable')->>'text')) = 0
     or position('#A35D43' in (public.site_spec_output(spec,'lovable')->>'text')) = 0 then
    raise exception 'text_safe_variants: the prompt does not state both the brand colour and its variant.';
  end if;
  if (public.site_spec_output(spec,'lovable')->>'text') not like '%Do not substitute one for the other%' then
    raise exception 'text_safe_variants: the prompt does not carry the usage rule.';
  end if;
  if jsonb_array_length((select s.value->'values' from jsonb_array_elements(
       public.site_spec_output(spec,'squarespace')->'steps') s where (s.value->>'n')::int = 3)) <> 3 then
    raise exception 'text_safe_variants: the setup sheet has no three-value text-variant step.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_spec_contrast, site_spec_preview_model, site_spec_token_lines
--   -- and site_spec_output_setup_sheet from 20260829113000 / 20260829110000,
--   -- each WITH its `set jit = 'off'` clause, then:
--   drop trigger if exists maintain_site_spec_text_variants on public.site_specs;
--   drop function if exists public.maintain_site_spec_text_variants();
--   alter table public.site_specs drop constraint if exists site_specs_text_hex_check;
--   alter table public.site_specs
--     drop column if exists accent_text_hex,
--     drop column if exists secondary_text_hex,
--     drop column if exists primary_text_hex;
--   delete from public.site_output_templates
--    where key in ('token.primary_text','token.secondary_text','token.accent_text',
--                  'token.text_variant_note','sheet.step_text_title','sheet.step_text_body');
--   alter table public.palette_families drop constraint if exists palette_families_text_hex_check;
--   alter table public.palette_families
--     drop column if exists accent_text_hex,
--     drop column if exists secondary_text_hex,
--     drop column if exists primary_text_hex;
--   drop function if exists public.site_spec_text_variant(text, text);
