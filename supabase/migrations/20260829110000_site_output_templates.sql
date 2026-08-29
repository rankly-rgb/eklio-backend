-- ============================================================================
-- Eklio — the output copy moves into a catalog
-- ============================================================================
-- Follows `20260829109000_site_spec_limits_and_clamp.sql`.
--
-- WHERE THIS COPY WAS, AND WHY IT MOVES
-- -------------------------------------
-- Half of it was already data: the builder panel names ("Site Styles › Colors")
-- have lived in `builder_targets.color_panel` since the catalog migration,
-- precisely because they are product copy that changes when a builder redesigns
-- its editor.
--
-- The other half was not. Step titles, step bodies, the constraints block, the
-- prompt's section headings and every field label sat as string literals inside
-- six function bodies — around two hundred of them. That copy is what will be
-- tuned week by week as we learn what each builder actually honors, and a
-- wording change should not be a migration. This repo already made that call
-- for the eleven brief catalogs; this is the same call for the same reason.
--
-- ⚠ THIS MIGRATION CHANGES NO WORDING. Every fragment is moved verbatim, and
-- the guard rail at the end asserts the rendered output is byte-identical to
-- what the snapshot digests in
-- `supabase/tests/20260829104000_site_output.test.sql` already pin. A refactor
-- that also edits the copy is a refactor nobody can review.
--
-- WHAT STAYS IN THE FUNCTIONS
-- ---------------------------
-- Markup, not copy: the `"""` and ``` fences, the `- ` bullet, the newlines
-- between blocks. Those are the shape of the document rather than its words,
-- they are not what gets tuned, and putting them in rows would make the
-- renderer unreadable without making anything editable that anyone wants to
-- edit.
-- ============================================================================


-- ============================================================================
-- 1. site_output_templates
-- ============================================================================
-- `target IS NULL` means "every builder". A row with a target overrides the
-- shared one for that builder and no other — which is the whole point, since
-- what Squarespace honors and what Lovable honors will diverge.
--
-- Same conventions as the thirteen catalogs before it: `id text` primary key
-- holding a readable slug, `sort_order`, `active`, no timestamps, one SELECT
-- policy `to authenticated`, no write policy at all.

create table if not exists public.site_output_templates (
  id         text    primary key,
  target     text    references public.builder_targets (id) on delete restrict,
  key        text    not null,
  body       text    not null,
  sort_order int     not null default 0,
  active     boolean not null default true,
  -- ⚠ NULLS NOT DISTINCT, so the shared row for a key can only exist once.
  -- Under the default NULLS DISTINCT two "every builder" rows for one key would
  -- both be legal and the resolver would pick between them arbitrarily.
  constraint site_output_templates_target_key_key unique nulls not distinct (target, key)
);

-- The id is the readable handle; (target, key) is what the resolver looks up.
-- Tying them together means a row cannot be filed under a name that disagrees
-- with what it actually overrides.
alter table public.site_output_templates drop constraint if exists site_output_templates_id_check;
alter table public.site_output_templates
  add constraint site_output_templates_id_check check (
    id = coalesce(target, 'all') || '.' || key
  );

alter table public.site_output_templates drop constraint if exists site_output_templates_key_check;
alter table public.site_output_templates
  add constraint site_output_templates_key_check check (
    key ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'
  );

create index if not exists site_output_templates_key_idx
  on public.site_output_templates (key);

comment on table public.site_output_templates is
  'Every tunable string of the derived builder output, keyed by fragment and optionally by builder. A row with a target overrides the shared row for that builder only. Wording changes here, not in a function body.';
comment on column public.site_output_templates.target is
  'NULL means every builder. A non-null target overrides the shared row for that builder and no other.';

alter table public.site_output_templates enable row level security;
drop policy if exists "site_output_templates_select_all" on public.site_output_templates;
create policy "site_output_templates_select_all"
  on public.site_output_templates for select to authenticated using (true);


-- ============================================================================
-- 2. Resolution
-- ============================================================================
-- One query per render, not one per fragment. `site_spec_output_prompt` reaches
-- for about twenty fragments and the setup sheet for about thirty; forty index
-- lookups on a table of a hundred rows is forty times the planning for the same
-- answer.

create or replace function public.site_output_fragments(p_target text)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select coalesce(jsonb_object_agg(t.key, t.body), '{}'::jsonb)
    from (
      select distinct on (key) key, body
        from public.site_output_templates
       where active
         and (target is null or target = p_target)
       -- the builder's own row wins over the shared one
       order by key, target nulls last
    ) t
$$;

comment on function public.site_output_fragments(text) is
  'Every output fragment for one builder, as { key: body }, with per-builder rows overriding the shared ones. One query per render.';

-- `{name}` substitution. Deliberately not a template language: the only thing
-- these fragments ever interpolate is a handful of known values, and anything
-- with control flow in it would be copy that needs testing rather than copy
-- that needs proofreading.
create or replace function public.site_output_fill(p_template text, p_vars jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  out_text text := p_template;
  k        text;
begin
  if p_template is null then
    return null;
  end if;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    out_text := replace(out_text, '{' || k || '}', coalesce(p_vars->>k, ''));
  end loop;
  return out_text;
end
$$;


-- ============================================================================
-- 3. The fragments
-- ============================================================================
-- ⚠ EVERYTHING BETWEEN THE TWO MARKERS BELOW IS MIRRORED VERBATIM IN
-- `supabase/seed.sql`, like the two catalog blocks before it. Change one,
-- change the other. Regenerate the mirror with:
--
--   awk '/^-- >>> SITE OUTPUT TEMPLATE DATA/,/^-- <<< SITE OUTPUT TEMPLATE DATA/' \
--     supabase/migrations/20260829110000_site_output_templates.sql \
--     > /tmp/site-output-templates.sql

-- >>> SITE OUTPUT TEMPLATE DATA (mirrored verbatim in supabase/seed.sql) >>>

insert into public.site_output_templates (id, target, key, body, sort_order) values

  -- ---- the prompt's skeleton ----------------------------------------------
  ('all.prompt.role_line', null, 'prompt.role_line',
   'Build a one-page (or multi-page) website for a therapy private practice. Follow this specification exactly.', 10),
  ('all.prompt.heading_practice',    null, 'prompt.heading_practice',    '## Practice', 11),
  ('all.prompt.heading_tokens',      null, 'prompt.heading_tokens',      '## Design tokens', 12),
  ('all.prompt.heading_structure',   null, 'prompt.heading_structure',   '## Pages and sections', 13),
  ('all.prompt.heading_copy',        null, 'prompt.heading_copy',        '## Copy', 14),
  ('all.prompt.copy_preamble',       null, 'prompt.copy_preamble',
   'Use every line below exactly as written. Text between """ lines is final copy, not a brief.', 15),
  ('all.prompt.heading_constraints', null, 'prompt.heading_constraints', '## Constraints', 16),
  ('all.prompt.heading_extra',       null, 'prompt.heading_extra',
   '## Additional instructions from the practice owner', 17),
  ('all.prompt.copy_section_heading', null, 'prompt.copy_section_heading', '### {page} — {section}', 18),
  ('all.prompt.structure_section_line', null, 'prompt.structure_section_line', '{label} — {description}', 19),

  -- ---- practice identity ---------------------------------------------------
  ('all.identity.label_name',     null, 'identity.label_name',     'Name', 20),
  ('all.identity.label_license',  null, 'identity.label_license',  'License', 21),
  ('all.identity.label_location', null, 'identity.label_location', 'Location', 22),
  ('all.identity.label_email',    null, 'identity.label_email',    'Email', 23),
  ('all.identity.label_phone',    null, 'identity.label_phone',    'Phone', 24),

  -- ---- design tokens, each with the role it plays --------------------------
  ('all.token.primary',   null, 'token.primary',   'Primary — buttons, links and active states', 30),
  ('all.token.secondary', null, 'token.secondary', 'Secondary — supporting headings and surfaces', 31),
  ('all.token.accent',    null, 'token.accent',    'Accent — small highlights only, never body text', 32),
  ('all.token.light_neutral', null, 'token.light_neutral', 'Light neutral — page background', 33),
  ('all.token.dark_neutral',  null, 'token.dark_neutral',  'Dark neutral — body text', 34),
  ('all.token.heading_font',  null, 'token.heading_font',  'Heading font', 35),
  ('all.token.body_font',     null, 'token.body_font',     'Body font', 36),
  ('all.token.google_fonts_url', null, 'token.google_fonts_url', 'Google Fonts stylesheet', 37),

  -- ---- the constraints -----------------------------------------------------
  -- ⚠ Four of these five are the difference between a website a licensing
  -- board is fine with and one it is not. Tune the wording; do not drop a row.
  ('all.constraint.copy_exact', null, 'constraint.copy_exact',
   'Use the provided copy exactly as written. Do not rewrite, expand or add copy.', 40),
  ('all.constraint.no_invention', null, 'constraint.no_invention',
   'Do not invent testimonials, client quotes, statistics, credentials or awards.', 41),
  ('all.constraint.no_stock_photos', null, 'constraint.no_stock_photos',
   'No stock photos of people; leave labeled image placeholders.', 42),
  ('all.constraint.cta_linked', null, 'constraint.cta_linked',
   'The call to action links to {cta_target_url}. Do not add a contact form that collects health information — a mailto link, a phone number or a booking link only.', 43),
  ('all.constraint.cta_unlinked', null, 'constraint.cta_unlinked',
   'The call to action has no link yet: leave the button in place and unlinked. Do not add a contact form that collects health information — a mailto link, a phone number or a booking link only.', 44),
  ('all.constraint.contrast', null, 'constraint.contrast',
   'Maintain WCAG AA text contrast.', 45),

  -- ---- the setup sheet -----------------------------------------------------
  ('all.sheet.step1_title', null, 'sheet.step1_title', 'Start from the right template', 50),
  ('all.sheet.step1_body',  null, 'sheet.step1_body',
   'Pick a template that is already close to the structure below. You will delete more than you add.', 51),
  ('all.sheet.step2_title', null, 'sheet.step2_title', 'Set your five colors', 52),
  ('all.sheet.step2_body',  null, 'sheet.step2_body',
   'Enter each hex exactly as written and give it the role named next to it. Do not let the template keep its own palette alongside yours.', 53),
  ('all.sheet.step3_title', null, 'sheet.step3_title', 'Set your two fonts', 54),
  ('all.sheet.step3_body',  null, 'sheet.step3_body',
   'Both faces are on Google Fonts. Assign the heading face to every heading level and the body face to body text, buttons and navigation.', 55),
  ('all.sheet.step4_title', null, 'sheet.step4_title', 'Build the pages and sections in this order', 56),
  ('all.sheet.step4_body',  null, 'sheet.step4_body',
   'Add each page, then each section inside it, top to bottom. The line after each section says what it is for.', 57),
  ('all.sheet.step5_title', null, 'sheet.step5_title', 'Paste your copy', 58),
  ('all.sheet.step5_body',  null, 'sheet.step5_body',
   'Every string your site needs is listed below this sheet, one block per field, in the order the sections appear. Paste them as they are.', 59),
  ('all.sheet.step6_title', null, 'sheet.step6_title', 'Point the button at your booking link', 60),
  ('all.sheet.step6_body_linked', null, 'sheet.step6_body_linked',
   'Set every call-to-action button to this link. One destination, on every page.', 61),
  ('all.sheet.step6_body_unlinked', null, 'sheet.step6_body_unlinked',
   'You have not set a booking link yet. Leave the button in place and unlinked, and come back to this step — do not replace it with a contact form.', 62),
  ('all.sheet.step7_title', null, 'sheet.step7_title', 'Before you publish', 63),
  ('all.sheet.step8_title', null, 'sheet.step8_title', 'Your own notes', 64),
  ('all.sheet.label_cta_label',  null, 'sheet.label_cta_label',  'Button label', 65),
  ('all.sheet.label_cta_target', null, 'sheet.label_cta_target', 'Button links to', 66),

  -- ---- the md / txt renderer ----------------------------------------------
  ('all.render.where_md',  null, 'render.where_md',  '> Where: ', 70),
  ('all.render.where_txt', null, 'render.where_txt', 'Where: ', 71),
  ('all.render.copy_blocks_md',  null, 'render.copy_blocks_md',  '## Copy blocks', 72),
  ('all.render.copy_blocks_txt', null, 'render.copy_blocks_txt', 'COPY BLOCKS', 73),
  ('all.render.copy_block_heading', null, 'render.copy_block_heading',
   '{page} — {section} — {label}', 74),
  ('all.render.value_line', null, 'render.value_line', '- {label}: {value}', 75)

on conflict (id) do update set
  target     = excluded.target,
  key        = excluded.key,
  body       = excluded.body,
  sort_order = excluded.sort_order,
  active     = excluded.active;

-- <<< SITE OUTPUT TEMPLATE DATA <<<


-- ============================================================================
-- 4. The renderers, assembling from the catalog
-- ============================================================================
-- The three line builders gain a target, because a fragment may be overridden
-- per builder and they cannot resolve one without knowing which. Their previous
-- one-argument forms are dropped: leaving both would leave a version that
-- silently ignores overrides.

drop function if exists public.site_spec_identity_lines(jsonb);
drop function if exists public.site_spec_token_lines(jsonb);
drop function if exists public.site_spec_constraint_lines(jsonb);
-- and the two whose signatures gained the fragment map / the target
drop function if exists public.site_spec_structure_lines(jsonb);
drop function if exists public.site_spec_output_prompt(jsonb);

create or replace function public.site_spec_identity_lines(p_spec jsonb, p_frag jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(array_to_string(array_remove(array[
    case when nullif(btrim(d.v->>'practice_name'), '') is not null
         then (p_frag->>'identity.label_name') || ': ' || btrim(d.v->>'practice_name') end,
    -- The licence number is appended only when she has entered one. Eklio never
    -- invents it and never checks it against a board.
    case when nullif(btrim(d.v->>'license_label'), '') is not null
         then (p_frag->>'identity.label_license') || ': ' || btrim(d.v->>'license_label')
              || coalesce(' #' || nullif(btrim(d.v->>'license_number'), ''), '') end,
    case when nullif(btrim(d.v->>'city'), '') is not null
          and nullif(btrim(d.v->>'state'), '') is not null
         then (p_frag->>'identity.label_location') || ': '
              || btrim(d.v->>'city') || ', ' || upper(btrim(d.v->>'state')) end,
    case when nullif(btrim(d.v->>'email'), '') is not null
         then (p_frag->>'identity.label_email') || ': ' || btrim(d.v->>'email') end,
    case when nullif(btrim(d.v->>'phone'), '') is not null
         then (p_frag->>'identity.label_phone') || ': ' || btrim(d.v->>'phone') end
  ], null), E'\n'), '')
  from (select coalesce(p_spec->'practice_details', '{}'::jsonb) as v) d
$$;

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
    (p_frag->>'token.light_neutral') || ': ' || (p_spec->>'light_neutral_hex'),
    (p_frag->>'token.dark_neutral')  || ': ' || (p_spec->>'dark_neutral_hex'),
    (p_frag->>'token.heading_font')     || ': ' || (p_spec->>'heading_font'),
    (p_frag->>'token.body_font')        || ': ' || (p_spec->>'body_font'),
    (p_frag->>'token.google_fonts_url') || ': ' || (p_spec->>'google_fonts_url')
  ], E'\n')
$$;

-- ⚠ ALWAYS ALL FIVE, in both output kinds, whatever else the spec contains.
-- The rows are tunable; the fact that five of them are emitted is not.
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
    p_frag->>'constraint.contrast'
  ]
$$;

create or replace function public.site_spec_structure_lines(p_spec jsonb, p_frag jsonb)
returns text
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select string_agg(
           pg.ord || '. ' || (pg.value->>'label') ||
           coalesce(E'\n' || (
             select string_agg('   ' || s.ord || '. ' ||
                      public.site_output_fill(p_frag->>'prompt.structure_section_line',
                        jsonb_build_object('label', st.label, 'description', st.description)),
                    E'\n' order by s.ord)
               from jsonb_array_elements(pg.value->'sections') with ordinality as s(value, ord)
               join public.section_types st on st.id = s.value->>'type'), ''),
           E'\n' order by pg.ord)
    from jsonb_array_elements(public.site_spec_preview_model(p_spec)->'pages')
         with ordinality as pg(value, ord)
$$;

create or replace function public.site_spec_output_prompt(p_spec jsonb, p_target text)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  with frag as (select public.site_output_fragments(p_target) as f),
  pv as (select public.site_spec_preview_model(p_spec) as m),
  copy as (
    select string_agg(b.txt, E'\n\n' order by b.pord, b.sord) as txt
      from (
        select pg.ord as pord, s.ord as sord,
               public.site_output_fill((select f->>'prompt.copy_section_heading' from frag),
                 jsonb_build_object('page', pg.value->>'label', 'section', st.label))
               || E'\n' || fl.body as txt
          from jsonb_array_elements((select m->'pages' from pv)) with ordinality as pg(value, ord)
          cross join lateral jsonb_array_elements(pg.value->'sections') with ordinality as s(value, ord)
          join public.section_types st on st.id = s.value->>'type'
          cross join lateral (
            select string_agg(line.txt, E'\n' order by fd.ord) as body
              from jsonb_array_elements(st.fields) with ordinality as fd(value, ord)
              cross join lateral (
                select public.site_spec_render_field_or_null(
                         fd.value, s.value->'fields'->(fd.value->>'key')) as txt
              ) line
             where line.txt is not null
          ) fl
         where fl.body is not null
      ) b
  )
  select case when p_spec is null then null else (
    select jsonb_build_object(
      'kind', 'prompt',
      'text', t.text,
      'char_count', char_length(t.text))
    from (select array_to_string(array_remove(array[

      (select f->>'prompt.role_line' from frag),

      case when public.site_spec_identity_lines(p_spec, (select f from frag)) is not null
           then (select f->>'prompt.heading_practice' from frag) || E'\n'
                || public.site_spec_identity_lines(p_spec, (select f from frag)) end,

      (select f->>'prompt.heading_tokens' from frag) || E'\n'
        || public.site_spec_token_lines(p_spec, (select f from frag)),

      case when public.site_spec_structure_lines(p_spec, (select f from frag)) is not null
           then (select f->>'prompt.heading_structure' from frag) || E'\n'
                || public.site_spec_structure_lines(p_spec, (select f from frag)) end,

      case when (select txt from copy) is not null
           then (select f->>'prompt.heading_copy' from frag) || E'\n'
                || (select f->>'prompt.copy_preamble' from frag)
                || E'\n\n' || (select txt from copy) end,

      (select f->>'prompt.heading_constraints' from frag) || E'\n' ||
        (select string_agg('- ' || c.line, E'\n' order by c.ord)
           from unnest(public.site_spec_constraint_lines(p_spec, (select f from frag)))
                with ordinality as c(line, ord)),

      -- ⚠ VERBATIM, LAST, AND UNDER ITS OWN HEADING. Never parsed, never
      -- inspected, never allowed to influence anything above it.
      case when nullif(btrim(coalesce(p_spec->>'extra_instructions', '')), '') is not null
           then (select f->>'prompt.heading_extra' from frag) || E'\n'
                || (p_spec->>'extra_instructions') end

    ], null), E'\n\n') as text) t
  ) end
$$;

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

create or replace function public.site_spec_output(p_spec jsonb, p_target text default null)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select case
    when p_spec is null then null
    when bt.id is null then
      public.site_spec_error('invalid_target',
        format('"%s" is not a website builder we support.',
               coalesce(p_target, p_spec->>'target')), 'target')
    when bt.output_kind = 'prompt' then public.site_spec_output_prompt(p_spec, bt.id)
    else public.site_spec_output_setup_sheet(p_spec, bt.id)
  end
  from (select coalesce(p_target, p_spec->>'target') as t) req
  left join public.builder_targets bt on bt.id = req.t
$$;

create or replace function public.site_spec_output_render(
  p_spec text, p_output jsonb, p_markdown boolean
)
returns text
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  with frag as (select public.site_output_fragments(null) as f)
  select case
    when p_output is null or p_output ? 'error' then null
    when p_output->>'kind' = 'prompt' then
      case when p_markdown then p_output->>'text'
           else regexp_replace(p_output->>'text', '(^|\n)#{2,3} ', '\1', 'g') end
    else
      array_to_string(array_remove(array[
        case when p_markdown then '# ' || p_spec else upper(p_spec) end,
        (select string_agg(
                  case when p_markdown then '## ' || (s.value->>'n') || '. ' || (s.value->>'title')
                       else (s.value->>'n') || '. ' || (s.value->>'title') end
                  || coalesce(E'\n\n' || nullif(s.value->>'body', ''), '')
                  || coalesce(E'\n\n' || (
                       select string_agg(
                                public.site_output_fill((select f->>'render.value_line' from frag),
                                  jsonb_build_object('label', v.value->>'label',
                                                     'value', v.value->>'value')),
                                E'\n' order by v.ord)
                         from jsonb_array_elements(s.value->'values') with ordinality as v(value, ord)
                        where jsonb_array_length(s.value->'values') > 0), '')
                  || coalesce(E'\n\n'
                              || (select case when p_markdown then f->>'render.where_md'
                                               else f->>'render.where_txt' end from frag)
                              || nullif(s.value->>'builder_hint', ''), ''),
                  E'\n\n' order by (s.value->>'n')::int)
           from jsonb_array_elements(p_output->'steps') as s),
        case when jsonb_array_length(p_output->'copy_blocks') > 0
             then (select case when p_markdown then f->>'render.copy_blocks_md'
                                else f->>'render.copy_blocks_txt' end from frag)
                  || E'\n\n' || (
               select string_agg(
                        (case when p_markdown then '### ' else '' end)
                        || public.site_output_fill((select f->>'render.copy_block_heading' from frag),
                             jsonb_build_object('page', b.value->>'page',
                                                'section', b.value->>'section',
                                                'label', b.value->>'label'))
                        || E'\n'
                        || (case when p_markdown then E'```\n' else E'"""\n' end)
                        || (b.value->>'text')
                        || (case when p_markdown then E'\n```' else E'\n"""' end),
                        E'\n\n' order by b.ord)
                 from jsonb_array_elements(p_output->'copy_blocks') with ordinality as b(value, ord))
        end
      ], null), E'\n\n')
  end
$$;

grant execute on function public.site_output_fragments(text)                     to authenticated, service_role;
grant execute on function public.site_output_fill(text, jsonb)                   to authenticated, service_role;
grant execute on function public.site_spec_identity_lines(jsonb, jsonb)          to authenticated, service_role;
grant execute on function public.site_spec_token_lines(jsonb, jsonb)             to authenticated, service_role;
grant execute on function public.site_spec_constraint_lines(jsonb, jsonb)        to authenticated, service_role;
grant execute on function public.site_spec_structure_lines(jsonb, jsonb)         to authenticated, service_role;
grant execute on function public.site_spec_output_prompt(jsonb, text)            to authenticated, service_role;
grant execute on function public.site_spec_output_setup_sheet(jsonb, text)       to authenticated, service_role;


-- ============================================================================
-- 5. Guard rails
-- ============================================================================
do $$
declare
  spec jsonb;
  n    int;
  t    text;
begin
  if not (select relrowsecurity from pg_class where oid = 'public.site_output_templates'::regclass) then
    raise exception 'site_output_templates: RLS is off.';
  end if;
  select count(*) into n from pg_policies
   where schemaname='public' and tablename='site_output_templates';
  if n <> 1 then
    raise exception 'site_output_templates: % policies, expected exactly 1 (select-only).', n;
  end if;

  -- ⚠ EVERY FRAGMENT THE RENDERERS ASK FOR MUST EXIST. A missing row does not
  -- raise; it renders as an empty string, which is a deliverable with a hole in
  -- it that nobody notices until a therapist pastes it.
  foreach t in array array[
    'prompt.role_line','prompt.heading_practice','prompt.heading_tokens',
    'prompt.heading_structure','prompt.heading_copy','prompt.copy_preamble',
    'prompt.heading_constraints','prompt.heading_extra','prompt.copy_section_heading',
    'prompt.structure_section_line',
    'identity.label_name','identity.label_license','identity.label_location',
    'identity.label_email','identity.label_phone',
    'token.primary','token.secondary','token.accent','token.light_neutral',
    'token.dark_neutral','token.heading_font','token.body_font','token.google_fonts_url',
    'constraint.copy_exact','constraint.no_invention','constraint.no_stock_photos',
    'constraint.cta_linked','constraint.cta_unlinked','constraint.contrast',
    'sheet.step1_title','sheet.step1_body','sheet.step2_title','sheet.step2_body',
    'sheet.step3_title','sheet.step3_body','sheet.step4_title','sheet.step4_body',
    'sheet.step5_title','sheet.step5_body','sheet.step6_title',
    'sheet.step6_body_linked','sheet.step6_body_unlinked',
    'sheet.step7_title','sheet.step8_title','sheet.label_cta_label','sheet.label_cta_target',
    'render.where_md','render.where_txt','render.copy_blocks_md','render.copy_blocks_txt',
    'render.copy_block_heading','render.value_line'
  ] loop
    if (public.site_output_fragments(null)->>t) is null then
      raise exception 'site_output_templates: the fragment %s is missing; it would render as an empty string.', t;
    end if;
  end loop;

  -- the placeholder the constraints line depends on must survive any rewording
  if (public.site_output_fragments(null)->>'constraint.cta_linked') not like '%{cta_target_url}%' then
    raise exception
      'site_output_templates: constraint.cta_linked lost its {cta_target_url} placeholder; the booking link would vanish from the output.';
  end if;

  -- per-builder override resolution
  insert into public.site_output_templates (id, target, key, body)
  values ('lovable.prompt.role_line', 'lovable', 'prompt.role_line', 'OVERRIDDEN');
  if (public.site_output_fragments('lovable')->>'prompt.role_line') <> 'OVERRIDDEN' then
    raise exception 'site_output_templates: a per-builder override was not applied.';
  end if;
  if (public.site_output_fragments('framer')->>'prompt.role_line') = 'OVERRIDDEN' then
    raise exception 'site_output_templates: a per-builder override leaked to another builder.';
  end if;
  delete from public.site_output_templates where id = 'lovable.prompt.role_line';

  -- ---- ⚠ THE REFACTOR CHANGED NO WORDING ----------------------------------
  -- These are the digests the snapshot test already pins. If this block fails,
  -- moving the copy into a table also edited it, which is a refactor nobody can
  -- review.
  spec := jsonb_build_object(
    'primary_hex','#3B2C3A','secondary_hex','#4A5361','accent_hex','#C08A3E',
    'light_neutral_hex','#F3EDE4','dark_neutral_hex','#241B23',
    'type_pairing_id','cormorant_source',
    'heading_font','Cormorant Garamond','body_font','Source Sans 3',
    'google_fonts_url','https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&family=Source+Sans+3:wght@400;600;700&display=swap',
    'hero', jsonb_build_object(
      'overline','LCSW · PORTLAND, OR','headline','Experienced care, without the noise.',
      'subhead','Therapy for high-performing adults who cannot switch off.',
      'cta_label','Book a consult','cta_target_url','https://elmandember.clientsecure.me'),
    'about_excerpt','I work mostly with professionals who look fine from outside. Much of that work sits with anxiety and burnout.',
    'practice_details', jsonb_build_object(
      'practice_name','Elm & Ember Therapy','license_label','LCSW','license_number','LC61234',
      'city','Portland','state','OR','email','hello@elmandember.com','phone','(503) 555-0123'),
    'pages', public.site_spec_default_pages(
               array['Anxiety','Burnout'],
               array['Professionals who look fine from outside']),
    'extra_instructions','Please keep fees off the home page. Tuesday and Thursday are the only open hours right now.',
    'target','lovable');

  if md5(public.site_spec_output_render('Lovable', public.site_spec_output(spec,'lovable'), true))
     <> '22930239c58ee7b443e1b6fb6b173c89' then
    raise exception 'site_output_templates: the Lovable prompt changed while its copy was being moved into a table.';
  end if;
  if md5(public.site_spec_output_render('Squarespace', public.site_spec_output(spec,'squarespace'), true))
     <> '82c053ac1ea541421486675b8ee24431' then
    raise exception 'site_output_templates: the Squarespace sheet changed while its copy was being moved into a table.';
  end if;
  if md5(public.site_spec_output_render('Wix', public.site_spec_output(spec,'wix'), true))
     <> '2c7dd72e1c069e9cab093f9912353bd2' then
    raise exception 'site_output_templates: the Wix sheet changed while its copy was being moved into a table.';
  end if;
  if md5(public.site_spec_output_render('Webflow', public.site_spec_output(spec,'webflow'), true))
     <> '75ca997178753e150eb1a1c47bcff07f' then
    raise exception 'site_output_templates: the Webflow sheet changed while its copy was being moved into a table.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_spec_output_render, site_spec_output, site_spec_output_prompt,
--   -- site_spec_output_setup_sheet and site_spec_structure_lines from
--   -- 20260829105000, and the one-argument site_spec_identity_lines /
--   -- site_spec_token_lines / site_spec_constraint_lines from 20260829104000,
--   -- each WITH its `set jit = 'off'` clause, then:
--   drop function if exists public.site_spec_output_setup_sheet(jsonb, text);
--   drop function if exists public.site_spec_output_prompt(jsonb, text);
--   drop function if exists public.site_spec_structure_lines(jsonb, jsonb);
--   drop function if exists public.site_spec_constraint_lines(jsonb, jsonb);
--   drop function if exists public.site_spec_token_lines(jsonb, jsonb);
--   drop function if exists public.site_spec_identity_lines(jsonb, jsonb);
--   drop function if exists public.site_output_fill(text, jsonb);
--   drop function if exists public.site_output_fragments(text);
--   drop table if exists public.site_output_templates;
