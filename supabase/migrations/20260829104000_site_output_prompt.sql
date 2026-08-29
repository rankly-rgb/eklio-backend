-- ============================================================================
-- Eklio — the derived output, part one: builders that accept a prompt
-- ============================================================================
-- Follows `20260829103000_site_spec_endpoints.sql`.
--
-- ⚠ RULE 2 LIVES IN THIS FILE. The output is DERIVED from the spec by a pure
-- function. There is no LLM call, no template stored in a row, and no path that
-- reads text back into the spec. `site_spec_output(spec, target)` is a total
-- function of its two arguments: the same spec and the same target produce a
-- byte-identical block of text, today and in six months, which is what makes it
-- snapshot-testable at all. Editing the output is not a supported operation —
-- she edits the spec, and this runs again.
--
-- THE OUTPUT AND THE MOCKUP ARE THE SAME SITE, BY CONSTRUCTION
-- ------------------------------------------------------------
-- The renderer walks `site_spec_preview_model(spec)`, not the raw row. So the
-- pages it lists, the sections it lists, the order they are in and the copy
-- each one carries are literally the values the mockup drew. They cannot
-- describe two different sites, because there is only one function deciding.
--
-- WHY THE FIELD LABELS COME FROM THE CATALOG
-- ------------------------------------------
-- "Overline", "Supporting line", "Areas" are printed into the output, and they
-- are the same words the editor puts above the inputs she typed into. Read from
-- `section_types.fields[].label`, they are one string; written out here as
-- well, they would be two, and the therapist would eventually meet a form field
-- called one thing and an output line calling it another.
-- ============================================================================


-- ============================================================================
-- 1. One field, rendered
-- ============================================================================
-- Returns NULL for anything empty — an absent key, a JSON null, an empty
-- string, an empty list. A section she has not filled in contributes no copy
-- block at all, rather than a heading followed by blank labels. Eklio does not
-- write copy on her behalf, so an empty section is simply empty, and the
-- structure listing is where the builder learns it should exist.
--
-- ⚠ LONG COPY IS FENCED. §6.1 requires the copy to be delimited clearly enough
-- that the builder does not treat it as a brief to rewrite. A paragraph sitting
-- bare after a colon reads like an instruction; the same paragraph between two
-- `"""` lines reads like content.

create or replace function public.site_spec_render_field(p_field jsonb, p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then null

    when p_field->>'kind' = 'list' then
      case when jsonb_typeof(p_value) <> 'array' or jsonb_array_length(p_value) = 0 then null
      else (p_field->>'label') || ':' || E'\n' ||
           (select string_agg('- ' || (e.value #>> '{}'), E'\n' order by e.ord)
              from jsonb_array_elements(p_value) with ordinality as e(value, ord)
             where btrim(e.value #>> '{}') <> '')
      end

    when jsonb_typeof(p_value) <> 'string' or btrim(p_value #>> '{}') = '' then null

    when p_field->>'kind' = 'longtext' then
      (p_field->>'label') || ':' || E'\n"""\n' || (p_value #>> '{}') || E'\n"""'

    else (p_field->>'label') || ': ' || (p_value #>> '{}')
  end
$$;

-- A list whose every item is blank renders as a label with nothing under it.
-- Fold that back to NULL so it is dropped like any other empty field.
create or replace function public.site_spec_render_field_or_null(p_field jsonb, p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(coalesce(public.site_spec_render_field(p_field, p_value), '')), '')
$$;


-- ============================================================================
-- 2. The blocks that both output kinds share
-- ============================================================================
-- The setup sheet in the next migration renders the same practice identity, the
-- same tokens and the same constraints, in a different container. They are
-- written once here.

create or replace function public.site_spec_identity_lines(p_spec jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(array_to_string(array_remove(array[
    case when nullif(btrim(d.v->>'practice_name'), '') is not null
         then 'Name: ' || btrim(d.v->>'practice_name') end,
    -- The licence number is appended only when she has entered one. Eklio never
    -- invents it and never checks it against a board.
    case when nullif(btrim(d.v->>'license_label'), '') is not null
         then 'License: ' || btrim(d.v->>'license_label')
              || coalesce(' #' || nullif(btrim(d.v->>'license_number'), ''), '') end,
    case when nullif(btrim(d.v->>'city'), '') is not null
          and nullif(btrim(d.v->>'state'), '') is not null
         then 'Location: ' || btrim(d.v->>'city') || ', ' || upper(btrim(d.v->>'state')) end,
    case when nullif(btrim(d.v->>'email'), '') is not null
         then 'Email: ' || btrim(d.v->>'email') end,
    case when nullif(btrim(d.v->>'phone'), '') is not null
         then 'Phone: ' || btrim(d.v->>'phone') end
  ], null), E'\n'), '')
  from (select coalesce(p_spec->'practice_details', '{}'::jsonb) as v) d
$$;

-- Each hex with the role it plays, because a builder handed five colours and no
-- roles will use them in the order it feels like.
create or replace function public.site_spec_token_lines(p_spec jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select array_to_string(array[
    'Primary — buttons, links and active states: '   || (p_spec->>'primary_hex'),
    'Secondary — supporting headings and surfaces: ' || (p_spec->>'secondary_hex'),
    'Accent — small highlights only, never body text: ' || (p_spec->>'accent_hex'),
    'Light neutral — page background: '              || (p_spec->>'light_neutral_hex'),
    'Dark neutral — body text: '                     || (p_spec->>'dark_neutral_hex'),
    'Heading font: '            || (p_spec->>'heading_font'),
    'Body font: '               || (p_spec->>'body_font'),
    'Google Fonts stylesheet: ' || (p_spec->>'google_fonts_url')
  ], E'\n')
$$;

-- ⚠ ALWAYS INCLUDED, in both output kinds, whatever else the spec contains.
-- Four of these five are the difference between a website a licensing board is
-- fine with and one it is not, and the fifth keeps the page readable. They are
-- not advice the generator may drop when the prompt gets long.
--
-- American English throughout, like every other user-facing string in this
-- product: "labeled", not "labelled".
create or replace function public.site_spec_constraint_lines(p_spec jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'Use the provided copy exactly as written. Do not rewrite, expand or add copy.',
    'Do not invent testimonials, client quotes, statistics, credentials or awards.',
    'No stock photos of people; leave labeled image placeholders.',
    case when nullif(btrim(coalesce(p_spec->'hero'->>'cta_target_url', '')), '') is not null
      then 'The call to action links to ' || btrim(p_spec->'hero'->>'cta_target_url')
           || '. Do not add a contact form that collects health information — a mailto link, a phone number or a booking link only.'
      -- She has not given a booking link yet. Saying so is better than leaving
      -- the builder to invent a destination, which in practice means a form.
      else 'The call to action has no link yet: leave the button in place and unlinked. Do not add a contact form that collects health information — a mailto link, a phone number or a booking link only.'
    end,
    'Maintain WCAG AA text contrast.'
  ]
$$;


-- ============================================================================
-- 3. site_spec_output_prompt — one block of plain text, in the fixed order
-- ============================================================================
-- The seven parts, in the order §6.1 fixes: role line, practice identity,
-- design tokens, structure, copy, constraints, and her own notes last.

create or replace function public.site_spec_output_prompt(p_spec jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with pv as (select public.site_spec_preview_model(p_spec) as m),

  -- Pages and sections, numbered, each with the purpose the catalog gives it.
  structure as (
    select string_agg(
             pg.ord || '. ' || (pg.value->>'label') ||
             coalesce(E'\n' || (
               select string_agg('   ' || s.ord || '. ' || st.label || ' — ' || st.description,
                                 E'\n' order by s.ord)
                 from jsonb_array_elements(pg.value->'sections') with ordinality as s(value, ord)
                 join public.section_types st on st.id = s.value->>'type'), ''),
             E'\n' order by pg.ord) as txt
      from jsonb_array_elements((select m->'pages' from pv)) with ordinality as pg(value, ord)
  ),

  -- Every string the site carries, section by section, under its own heading.
  copy as (
    select string_agg(b.txt, E'\n\n' order by b.pord, b.sord) as txt
      from (
        select pg.ord as pord, s.ord as sord,
               '### ' || (pg.value->>'label') || ' — ' || st.label || E'\n' || f.body as txt
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
          ) f
         -- a section she has not filled in contributes no block
         where f.body is not null
      ) b
  )

  select case when p_spec is null then null else (
    select jsonb_build_object(
      'kind', 'prompt',
      'text', t.text,
      'char_count', char_length(t.text))
    from (select array_to_string(array_remove(array[

      'Build a one-page (or multi-page) website for a therapy private practice. Follow this specification exactly.',

      case when public.site_spec_identity_lines(p_spec) is not null
           then '## Practice' || E'\n' || public.site_spec_identity_lines(p_spec) end,

      '## Design tokens' || E'\n' || public.site_spec_token_lines(p_spec),

      case when (select txt from structure) is not null
           then '## Pages and sections' || E'\n' || (select txt from structure) end,

      case when (select txt from copy) is not null
           then '## Copy' || E'\n'
                || 'Use every line below exactly as written. Text between """ lines is final copy, not a brief.'
                || E'\n\n' || (select txt from copy) end,

      '## Constraints' || E'\n' ||
        (select string_agg('- ' || c.line, E'\n' order by c.ord)
           from unnest(public.site_spec_constraint_lines(p_spec)) with ordinality as c(line, ord)),

      -- ⚠ VERBATIM, LAST, AND UNDER ITS OWN HEADING. Never parsed, never
      -- inspected, never allowed to influence anything above it.
      case when nullif(btrim(coalesce(p_spec->>'extra_instructions', '')), '') is not null
           then '## Additional instructions from the practice owner' || E'\n'
                || (p_spec->>'extra_instructions') end

    ], null), E'\n\n') as text) t
  ) end
$$;

comment on function public.site_spec_output_prompt(jsonb) is
  'The derived prompt for a builder that has a prompt input: one deterministic block of plain text in the order the product spec fixes. Pure function of the spec — no LLM call, and never parsed back.';


-- ============================================================================
-- 4. site_spec_output — the dispatcher
-- ============================================================================
-- Dispatches on `builder_targets.output_kind`, which is where the fork
-- belongs: adding a builder is a row, not a branch.
--
-- ⚠ THE `setup_sheet` BRANCH LANDS IN THE NEXT MIGRATION, and until it does
-- this returns an explicit error rather than quietly falling back to the
-- prompt. Handing a Squarespace user a prompt is the exact failure this whole
-- feature exists to fix; doing it as a stopgap would be worse than an error
-- that names itself. The guard rail in the next migration asserts it is gone.

create or replace function public.site_spec_output(p_spec jsonb, p_target text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case
    when p_spec is null then null
    when bt.id is null then
      public.site_spec_error('invalid_target',
        format('"%s" is not a website builder we support.',
               coalesce(p_target, p_spec->>'target')), 'target')
    when bt.output_kind = 'prompt' then public.site_spec_output_prompt(p_spec)
    else public.site_spec_error('not_implemented',
      format('The setup sheet for %s is not available yet.', bt.label))
  end
  from (select coalesce(p_target, p_spec->>'target') as t) req
  left join public.builder_targets bt on bt.id = req.t
$$;

comment on function public.site_spec_output(jsonb, text) is
  'The derived builder output, dispatched on builder_targets.output_kind. Pure function of (spec, target): no LLM call, no external call, byte-identical on every render.';


-- ============================================================================
-- 5. The envelope gains its `output` key
-- ============================================================================
-- Replaced rather than extended: this is the same function the previous
-- migration delivered, with one key added. `GET` and `PATCH` both return it, so
-- both gain the output without either being touched.

create or replace function public.site_spec_envelope(p_row jsonb)
returns jsonb
language sql
stable
set search_path = ''
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
      'target',                   p_row->>'target'),
    'preview',  public.site_spec_preview_model(p_row),
    'contrast', public.site_spec_contrast(p_row),
    'output',   public.site_spec_output(p_row, p_row->>'target'),
    'diff',     public.site_spec_diff(p_row),
    'etag', md5(concat_ws(':', p_row->>'brand_kit_id',
                               p_row->>'spec_version',
                               p_row->>'target'))
  ) end
$$;

grant execute on function public.site_spec_render_field(jsonb, jsonb)         to authenticated, service_role;
grant execute on function public.site_spec_render_field_or_null(jsonb, jsonb) to authenticated, service_role;
grant execute on function public.site_spec_identity_lines(jsonb)              to authenticated, service_role;
grant execute on function public.site_spec_token_lines(jsonb)                 to authenticated, service_role;
grant execute on function public.site_spec_constraint_lines(jsonb)            to authenticated, service_role;
grant execute on function public.site_spec_output_prompt(jsonb)               to authenticated, service_role;
grant execute on function public.site_spec_output(jsonb, text)                to authenticated, service_role;


-- ============================================================================
-- 6. Guard rails
-- ============================================================================
do $$
declare
  spec jsonb;
  out1 jsonb;
  out2 jsonb;
  t    text;
begin
  spec := jsonb_build_object(
    'primary_hex', '#3B2C3A', 'secondary_hex', '#4A5361', 'accent_hex', '#C08A3E',
    'light_neutral_hex', '#F3EDE4', 'dark_neutral_hex', '#241B23',
    'heading_font', 'Cormorant Garamond', 'body_font', 'Source Sans 3',
    'google_fonts_url', 'https://fonts.googleapis.com/css2?family=Cormorant+Garamond&display=swap',
    'about_excerpt', 'I work mostly with professionals who look fine from outside.',
    'extra_instructions', 'Please keep the fee off the home page.',
    'practice_details', jsonb_build_object(
      'practice_name', 'Elm & Ember', 'license_label', 'LCSW',
      'license_number', '12345', 'city', 'Portland', 'state', 'or'),
    'hero', jsonb_build_object('overline', 'LCSW · PORTLAND, OR',
                               'headline', 'A calmer place to start.',
                               'subhead', 'Therapy for high-performing adults.',
                               'cta_label', 'Book a consult',
                               'cta_target_url', 'https://elmandember.clientsecure.me'),
    'pages', public.site_spec_default_pages(array['Anxiety','Burnout'], array['Caregivers']),
    'target', 'lovable');

  out1 := public.site_spec_output(spec, 'lovable');
  t := out1->>'text';

  if out1->>'kind' <> 'prompt' then
    raise exception 'site_output_prompt: Lovable did not produce a prompt.';
  end if;

  -- ⚠ DETERMINISM IS THE WHOLE CONTRACT. If this ever stops holding, the
  -- snapshot tests are worthless and so is the cached copy in brand_kits.
  out2 := public.site_spec_output(spec, 'lovable');
  if out1 is distinct from out2 then
    raise exception 'site_output_prompt: two renders of one spec differ.';
  end if;
  if (out1->>'char_count')::int <> char_length(t) then
    raise exception 'site_output_prompt: char_count does not match the text.';
  end if;

  -- The seven parts, in the order §6.1 fixes.
  if t not like 'Build a one-page (or multi-page) website for a therapy private practice. Follow this specification exactly.%' then
    raise exception 'site_output_prompt: the role line is not first.';
  end if;
  if position('## Practice' in t) = 0
     or position('## Design tokens' in t) <= position('## Practice' in t)
     or position('## Pages and sections' in t) <= position('## Design tokens' in t)
     or position('## Copy' in t) <= position('## Pages and sections' in t)
     or position('## Constraints' in t) <= position('## Copy' in t)
     or position('## Additional instructions from the practice owner' in t)
        <= position('## Constraints' in t) then
    raise exception 'site_output_prompt: the sections are not in the order the product spec fixes.';
  end if;

  -- Identity, tokens and copy actually reached the text.
  if position('License: LCSW #12345' in t) = 0 then
    raise exception 'site_output_prompt: the license line is missing.';
  end if;
  if position('Location: Portland, OR' in t) = 0 then
    raise exception 'site_output_prompt: the location line is missing or not uppercased.';
  end if;
  if position('#3B2C3A' in t) = 0 or position('#241B23' in t) = 0 then
    raise exception 'site_output_prompt: a design token is missing.';
  end if;
  if position('A calmer place to start.' in t) = 0 then
    raise exception 'site_output_prompt: the hero headline is missing from the copy block.';
  end if;
  if position('I work mostly with professionals who look fine from outside.' in t) = 0 then
    raise exception 'site_output_prompt: the About text is missing from the copy block.';
  end if;
  if position('- Anxiety' in t) = 0 then
    raise exception 'site_output_prompt: a list field did not render as a list.';
  end if;

  -- All five constraints, every time.
  if position('Do not invent testimonials' in t) = 0
     or position('leave labeled image placeholders' in t) = 0
     or position('Maintain WCAG AA text contrast.' in t) = 0
     or position('https://elmandember.clientsecure.me' in t) = 0
     or position('contact form that collects health information' in t) = 0 then
    raise exception 'site_output_prompt: a constraint is missing from the output.';
  end if;

  -- Her notes, verbatim and last.
  if right(t, char_length('Please keep the fee off the home page.'))
     <> 'Please keep the fee off the home page.' then
    raise exception 'site_output_prompt: extra_instructions is not the last thing in the output.';
  end if;
  -- and absent entirely when she has written none
  if position('## Additional instructions'
              in (public.site_spec_output(spec - 'extra_instructions', 'lovable')->>'text')) > 0 then
    raise exception 'site_output_prompt: an empty notes heading was printed.';
  end if;

  -- A section she has not filled in prints no empty copy block. `approach` is
  -- seeded with a heading and an empty body.
  if position('How I work' || E'\n"""' in t) > 0 then
    raise exception 'site_output_prompt: an empty section field was printed.';
  end if;

  -- ⚠ THE FORK. The three builders with no prompt input must not be handed a
  -- prompt, now or after the next migration.
  foreach t in array array['squarespace', 'wix', 'webflow'] loop
    if public.site_spec_output(spec, t)->>'kind' = 'prompt' then
      raise exception
        'site_output_prompt: % was handed a prompt, and it has no prompt input.', t;
    end if;
  end loop;
  foreach t in array array['lovable', 'framer', 'v0', 'generic'] loop
    if public.site_spec_output(spec, t)->>'kind' <> 'prompt' then
      raise exception 'site_output_prompt: % accepts a prompt but did not get one.', t;
    end if;
  end loop;

  -- An unknown target is an error, not a silent default.
  if public.site_spec_output(spec, 'wordpress')->'error'->>'code' is distinct from 'invalid_target' then
    raise exception 'site_output_prompt: an unknown target did not return invalid_target.';
  end if;

  -- The envelope now carries the output.
  if not (public.site_spec_envelope(spec || jsonb_build_object(
            'brand_kit_id', '00000000-0000-0000-0000-000000000000',
            'spec_version', 1, 'change_marks', '{}'::jsonb)) ? 'output') then
    raise exception 'site_output_prompt: the envelope has no output key.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Restores the envelope to its five-key form (see the previous migration's
-- body, minus the `output` key), then drops the renderer.
--
--   drop function if exists public.site_spec_output(jsonb, text);
--   drop function if exists public.site_spec_output_prompt(jsonb);
--   drop function if exists public.site_spec_constraint_lines(jsonb);
--   drop function if exists public.site_spec_token_lines(jsonb);
--   drop function if exists public.site_spec_identity_lines(jsonb);
--   drop function if exists public.site_spec_render_field_or_null(jsonb, jsonb);
--   drop function if exists public.site_spec_render_field(jsonb, jsonb);
--   -- then re-create site_spec_envelope() from 20260829103000, which has no
--   -- `output` key and therefore no dependency on the functions above.
