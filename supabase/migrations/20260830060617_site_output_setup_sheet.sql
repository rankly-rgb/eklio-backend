-- ============================================================================
-- Eklio — the derived output, part two: builders with no prompt input
-- ============================================================================
-- Follows `20260829104000_site_output_prompt.sql`.
--
-- WHY THIS EXISTS AT ALL
-- ----------------------
-- Squarespace, Wix and Webflow have no box to paste a prompt into. Not a
-- hidden one, not a beta one — the interaction does not exist in those
-- products. Everything the previous migration built is useless to a therapist
-- on Squarespace, and shipping it to her anyway is shipping her nothing while
-- appearing to ship her something. That is the failure the single
-- `brand_kits.site_prompt` column has today.
--
-- So the same spec renders a second way: numbered steps she can follow with
-- the product open in the next tab, each one naming the panel that product
-- actually keeps the setting in, and every string she has to type broken out
-- into its own copyable block.
--
-- ⚠ THE PANEL NAMES ARE DATA, NOT BRANCHES. "Site Styles › Colors" lives in
-- `builder_targets.color_panel`. When Squarespace renames a panel — and it
-- will — the fix is an UPDATE in a data-only migration, not an edit inside a
-- function body where nobody thinks to look for product copy.
--
-- THIS MIGRATION ALSO CLOSES THE LOOP ON `brand_kits.site_prompt`
-- ---------------------------------------------------------------
-- With both renderers present, every write to a spec can refresh the cached
-- copy that existing consumers already read. §5 explains why that is a trigger
-- rather than a line in each endpoint.
-- ============================================================================


-- ============================================================================
-- 1. The structure listing, factored out
-- ============================================================================
-- The prompt already prints "the pages and sections, in order, each with its
-- purpose"; the setup sheet needs exactly the same listing as the body of its
-- build step. Extracted here and the prompt renderer replaced to call it, so
-- there is one listing rather than two that start identical and drift.

create or replace function public.site_spec_structure_lines(p_spec jsonb)
returns text
language sql
stable
set search_path = ''
as $$
  select string_agg(
           pg.ord || '. ' || (pg.value->>'label') ||
           coalesce(E'\n' || (
             select string_agg('   ' || s.ord || '. ' || st.label || ' — ' || st.description,
                               E'\n' order by s.ord)
               from jsonb_array_elements(pg.value->'sections') with ordinality as s(value, ord)
               join public.section_types st on st.id = s.value->>'type'), ''),
           E'\n' order by pg.ord)
    from jsonb_array_elements(public.site_spec_preview_model(p_spec)->'pages')
         with ordinality as pg(value, ord)
$$;

create or replace function public.site_spec_output_prompt(p_spec jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with pv as (select public.site_spec_preview_model(p_spec) as m),

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

      case when public.site_spec_structure_lines(p_spec) is not null
           then '## Pages and sections' || E'\n' || public.site_spec_structure_lines(p_spec) end,

      case when (select txt from copy) is not null
           then '## Copy' || E'\n'
                || 'Use every line below exactly as written. Text between """ lines is final copy, not a brief.'
                || E'\n\n' || (select txt from copy) end,

      '## Constraints' || E'\n' ||
        (select string_agg('- ' || c.line, E'\n' order by c.ord)
           from unnest(public.site_spec_constraint_lines(p_spec)) with ordinality as c(line, ord)),

      case when nullif(btrim(coalesce(p_spec->>'extra_instructions', '')), '') is not null
           then '## Additional instructions from the practice owner' || E'\n'
                || (p_spec->>'extra_instructions') end

    ], null), E'\n\n') as text) t
  ) end
$$;


-- ============================================================================
-- 2. Copy blocks — every string, individually copyable
-- ============================================================================
-- ⚠ ONE BLOCK PER ITEM, NOT ONE PER LIST. A list field holds several strings
-- and, in a builder with no prompt input, each one is typed into its own
-- element. A single block holding four newline-separated specialties would
-- have to be pulled apart by hand, which is precisely the work this sheet
-- exists to remove.

create or replace function public.site_spec_copy_blocks(p_spec jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object('page', b.page, 'section', b.section,
                              'label', b.label, 'text', b.text)
           order by b.pord, b.sord, b.ford, b.iord), '[]'::jsonb)
    from (
      select pg.ord as pord, s.ord as sord, fd.ord as ford,
             coalesce(item.ord, 0) as iord,
             pg.value->>'label' as page,
             st.label           as section,
             case when fd.value->>'kind' = 'list'
                  then (fd.value->>'label') || ' ' || item.ord
                  else  fd.value->>'label' end as label,
             case when fd.value->>'kind' = 'list'
                  then item.value #>> '{}'
                  else s.value->'fields'->>(fd.value->>'key') end as text
        from jsonb_array_elements(public.site_spec_preview_model(p_spec)->'pages')
             with ordinality as pg(value, ord)
        cross join lateral jsonb_array_elements(pg.value->'sections')
             with ordinality as s(value, ord)
        join public.section_types st on st.id = s.value->>'type'
        cross join lateral jsonb_array_elements(st.fields) with ordinality as fd(value, ord)
        left join lateral jsonb_array_elements(
               case when fd.value->>'kind' = 'list'
                     and jsonb_typeof(s.value->'fields'->(fd.value->>'key')) = 'array'
                    then s.value->'fields'->(fd.value->>'key')
                    else '[]'::jsonb end) with ordinality as item(value, ord) on true
       where case when fd.value->>'kind' = 'list' then item.value is not null
                  else jsonb_typeof(s.value->'fields'->(fd.value->>'key')) = 'string' end
    ) b
   -- an empty string is not a block she has to copy
   where btrim(coalesce(b.text, '')) <> ''
$$;


-- ============================================================================
-- 3. site_spec_output_setup_sheet — numbered, executable steps
-- ============================================================================
-- Written to be followed with the builder open in the next tab: what to click,
-- what to type into it, and what to check before publishing.

create or replace function public.site_spec_output_setup_sheet(p_spec jsonb, p_target text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with bt as (select * from public.builder_targets where id = p_target),
  steps as (
    select 1 as n,
           'Start from the right template' as title,
           'Pick a template that is already close to the structure below. You will delete more than you add.' as body,
           '[]'::jsonb as values,
           (select template_hint from bt) as builder_hint
    union all
    select 2,
           'Set your five colors',
           'Enter each hex exactly as written and give it the role named next to it. Do not let the template keep its own palette alongside yours.',
           jsonb_build_array(
             jsonb_build_object('label', 'Primary — buttons, links and active states',
                                'value', p_spec->>'primary_hex',       'kind', 'hex'),
             jsonb_build_object('label', 'Secondary — supporting headings and surfaces',
                                'value', p_spec->>'secondary_hex',     'kind', 'hex'),
             jsonb_build_object('label', 'Accent — small highlights only, never body text',
                                'value', p_spec->>'accent_hex',        'kind', 'hex'),
             jsonb_build_object('label', 'Light neutral — page background',
                                'value', p_spec->>'light_neutral_hex', 'kind', 'hex'),
             jsonb_build_object('label', 'Dark neutral — body text',
                                'value', p_spec->>'dark_neutral_hex',  'kind', 'hex')),
           (select color_panel from bt)
    union all
    select 3,
           'Set your two fonts',
           'Both faces are on Google Fonts. Assign the heading face to every heading level and the body face to body text, buttons and navigation.',
           jsonb_build_array(
             jsonb_build_object('label', 'Heading font', 'value', p_spec->>'heading_font', 'kind', 'font'),
             jsonb_build_object('label', 'Body font',    'value', p_spec->>'body_font',    'kind', 'font'),
             jsonb_build_object('label', 'Google Fonts stylesheet',
                                'value', p_spec->>'google_fonts_url', 'kind', 'url')),
           (select font_panel from bt)
    union all
    select 4,
           'Build the pages and sections in this order',
           'Add each page, then each section inside it, top to bottom. The line after each section says what it is for.'
             || E'\n\n' || coalesce(public.site_spec_structure_lines(p_spec), ''),
           '[]'::jsonb,
           (select section_panel from bt)
    union all
    select 5,
           'Paste your copy',
           'Every string your site needs is listed below this sheet, one block per field, in the order the sections appear. Paste them as they are.',
           '[]'::jsonb,
           null
    union all
    select 6,
           'Point the button at your booking link',
           case when nullif(btrim(coalesce(p_spec->'hero'->>'cta_target_url', '')), '') is not null
                then 'Set every call-to-action button to this link. One destination, on every page.'
                -- She has not given one yet. The sheet says so rather than
                -- leaving her to improvise, which in practice means a form.
                else 'You have not set a booking link yet. Leave the button in place and unlinked, and come back to this step — do not replace it with a contact form.'
           end,
           jsonb_build_array(
             jsonb_build_object('label', 'Button label',
                                'value', p_spec->'hero'->>'cta_label', 'kind', 'text'))
           || case when nullif(btrim(coalesce(p_spec->'hero'->>'cta_target_url', '')), '') is not null
                   then jsonb_build_array(jsonb_build_object(
                          'label', 'Button links to',
                          'value', p_spec->'hero'->>'cta_target_url', 'kind', 'url'))
                   else '[]'::jsonb end,
           null
    union all
    -- ⚠ THE SAME FIVE CONSTRAINTS AS THE PROMPT, from the same function. A
    -- Squarespace user is under exactly the advertising rules a Lovable user
    -- is, and a checklist that quietly dropped one would be the more dangerous
    -- of the two outputs.
    select 7,
           'Before you publish',
           (select string_agg('[ ] ' || c.line, E'\n' order by c.ord)
              from unnest(public.site_spec_constraint_lines(p_spec))
                   with ordinality as c(line, ord)),
           '[]'::jsonb,
           null
    union all
    -- Verbatim, last, under its own step. Never parsed.
    select 8,
           'Your own notes',
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

comment on function public.site_spec_output_setup_sheet(jsonb, text) is
  'The derived setup sheet for a builder with no prompt input: numbered steps naming that product''s own panels, and every string broken out as an individually copyable block. Pure function of (spec, target).';


-- ============================================================================
-- 4. The dispatcher, completed
-- ============================================================================
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
    else public.site_spec_output_setup_sheet(p_spec, bt.id)
  end
  from (select coalesce(p_target, p_spec->>'target') as t) req
  left join public.builder_targets bt on bt.id = req.t
$$;


-- ============================================================================
-- 5. Rendering it as text — `format=md` and `format=txt`
-- ============================================================================
-- One generator, a flag for the markers. Two generators would be two documents
-- that start identical and drift, and the print path would be the one nobody
-- notices has drifted.
--
-- A prompt is already plain text with `##` headings, so `md` is the text as it
-- stands and `txt` is the same with the markers taken off. The setup sheet is
-- assembled here in both flavours.

create or replace function public.site_spec_output_render(
  p_spec text, p_output jsonb, p_markdown boolean
)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_output is null or p_output ? 'error' then null
    when p_output->>'kind' = 'prompt' then
      case when p_markdown then p_output->>'text'
           -- strip the heading markers only; the `"""` fences are content
           else regexp_replace(p_output->>'text', '(^|\n)#{2,3} ', '\1', 'g') end
    else
      array_to_string(array_remove(array[
        case when p_markdown then '# ' || p_spec else upper(p_spec) end,
        (select string_agg(
                  case when p_markdown then '## ' || (s.value->>'n') || '. ' || (s.value->>'title')
                       else (s.value->>'n') || '. ' || (s.value->>'title') end
                  || coalesce(E'\n\n' || nullif(s.value->>'body', ''), '')
                  || coalesce(E'\n\n' || (
                       select string_agg('- ' || (v.value->>'label') || ': ' || (v.value->>'value'),
                                         E'\n' order by v.ord)
                         from jsonb_array_elements(s.value->'values') with ordinality as v(value, ord)
                        where jsonb_array_length(s.value->'values') > 0), '')
                  || coalesce(E'\n\n' || case when p_markdown then '> Where: ' else 'Where: ' end
                              || nullif(s.value->>'builder_hint', ''), ''),
                  E'\n\n' order by (s.value->>'n')::int)
           from jsonb_array_elements(p_output->'steps') as s),
        case when jsonb_array_length(p_output->'copy_blocks') > 0
             then (case when p_markdown then '## Copy blocks' else 'COPY BLOCKS' end)
                  || E'\n\n' || (
               select string_agg(
                        (case when p_markdown then '### ' else '' end)
                        || (b.value->>'page') || ' — ' || (b.value->>'section')
                        || ' — ' || (b.value->>'label') || E'\n'
                        || (case when p_markdown then E'```\n' else E'"""\n' end)
                        || (b.value->>'text')
                        || (case when p_markdown then E'\n```' else E'\n"""' end),
                        E'\n\n' order by b.ord)
                 from jsonb_array_elements(p_output->'copy_blocks') with ordinality as b(value, ord))
        end
      ], null), E'\n\n')
  end
$$;


-- ============================================================================
-- 6. The `site-output` endpoint
-- ============================================================================
-- The output on its own, for the copy button and the print path. SECURITY
-- INVOKER: it only reads, so RLS scopes it and another user's kit is not found.

create or replace function public.site_output_get(
  p_brand_kit_id uuid,
  p_target       text default null,
  p_format       text default 'json'
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when not (coalesce(p_format, 'json') = any (array['json', 'md', 'txt'])) then
      public.site_spec_error('invalid_format',
        'Ask for json, md or txt.', 'format')
    else coalesce((
      select case
        when o.out ? 'error' then o.out
        when coalesce(p_format, 'json') = 'json' then
          jsonb_build_object('target', o.target, 'format', 'json', 'output', o.out)
        else
          jsonb_build_object('target', o.target, 'format', coalesce(p_format, 'json'),
            'text', public.site_spec_output_render(
                      bt.label, o.out, coalesce(p_format, 'json') = 'md'))
      end
      from public.site_specs s
      cross join lateral (
        select coalesce(p_target, s.target) as target,
               public.site_spec_output(to_jsonb(s), coalesce(p_target, s.target)) as out
      ) o
      left join public.builder_targets bt on bt.id = o.target
      where s.brand_kit_id = p_brand_kit_id),
      public.site_spec_error('not_found', 'No site spec for this brand kit.'))
  end
$$;

comment on function public.site_output_get(uuid, text, text) is
  'The derived builder output on its own, for a target and a format (json, md, txt). format=md is the print path. SECURITY INVOKER, so RLS decides whose output is readable.';


-- ============================================================================
-- 7. Caching into `brand_kits.site_prompt`
-- ============================================================================
-- ⚠ BACKWARD COMPATIBILITY, AND NOTHING MORE. `brand_kits.site_prompt` is read
-- today by the launch checklist's second step and by whatever else in the
-- frontend already points at it. Those consumers keep working because this
-- trigger keeps the column filled with the current derived output — the
-- markdown rendering, which is human-readable for both output kinds.
--
-- It is a TRIGGER and not a line inside `site_spec_patch` for one reason: it
-- then covers every write path, including the reset, the target switch, the
-- contrast fix, the seeder, and a correction applied by hand with
-- `service_role`. A cache refreshed by whichever callers remembered to refresh
-- it is a cache that is stale exactly where nobody looked.
--
-- ⚠ THE ARROW ONLY POINTS ONE WAY. This writes the spec's output into
-- `site_prompt`. Nothing ever reads `site_prompt` back into a spec — that is
-- rule 2, and it is why the column can be a cache at all.
--
-- No recursion: `on_brand_kit_direction_selected` fires only when
-- `selected_direction_id` actually changes, and this touches neither.

create or replace function public.refresh_brand_kit_site_prompt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  v_out := public.site_spec_output(to_jsonb(new), new.target);

  update public.brand_kits
     set site_prompt = public.site_spec_output_render(
           (select bt.label from public.builder_targets bt where bt.id = new.target),
           v_out, true),
         site_prompt_target = new.target
   where id = new.brand_kit_id;

  return null;
end
$$;

drop trigger if exists on_site_spec_written on public.site_specs;
create trigger on_site_spec_written
  after insert or update on public.site_specs
  for each row execute function public.refresh_brand_kit_site_prompt();

-- Specs that already exist got theirs before the trigger did.
update public.site_specs set updated_at = updated_at where true;

grant execute on function public.site_spec_structure_lines(jsonb)                 to authenticated, service_role;
grant execute on function public.site_spec_copy_blocks(jsonb)                     to authenticated, service_role;
grant execute on function public.site_spec_output_setup_sheet(jsonb, text)        to authenticated, service_role;
grant execute on function public.site_spec_output_render(text, jsonb, boolean)    to authenticated, service_role;
grant execute on function public.site_output_get(uuid, text, text)                to authenticated, service_role;


-- ============================================================================
-- 8. Guard rails
-- ============================================================================
do $$
declare
  spec  jsonb;
  sheet jsonb;
  t     text;
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
    'target', 'squarespace');

  -- ⚠ THE FORK, NOW COMPLETE. No prompt-free builder may receive a prompt, and
  -- none may receive an error either.
  foreach t in array array['squarespace', 'wix', 'webflow'] loop
    sheet := public.site_spec_output(spec, t);
    if sheet->>'kind' <> 'setup_sheet' then
      raise exception 'site_output_setup_sheet: % did not get a setup sheet.', t;
    end if;
    if sheet ? 'error' then
      raise exception 'site_output_setup_sheet: % still returns an error.', t;
    end if;
    -- The sheet has to name that product's own panels, or it is a sheet that
    -- says "set your colors somewhere".
    if not exists (
      select 1 from jsonb_array_elements(sheet->'steps') s
       where s.value->>'builder_hint' is not null
    ) then
      raise exception 'site_output_setup_sheet: the % sheet names no panel at all.', t;
    end if;
  end loop;
  foreach t in array array['lovable', 'framer', 'v0', 'generic'] loop
    if public.site_spec_output(spec, t)->>'kind' <> 'prompt' then
      raise exception 'site_output_setup_sheet: % lost its prompt.', t;
    end if;
  end loop;

  sheet := public.site_spec_output(spec, 'squarespace');

  -- Squarespace's real panel, not a generic instruction.
  if (select s.value->>'builder_hint' from jsonb_array_elements(sheet->'steps') s
       where (s.value->>'n')::int = 2) <> 'Site Styles › Colors' then
    raise exception 'site_output_setup_sheet: step 2 does not name Squarespace''s color panel.';
  end if;
  if (select s.value->>'builder_hint' from jsonb_array_elements(sheet->'steps') s
       where (s.value->>'n')::int = 2)
     = (select s.value->>'builder_hint' from jsonb_array_elements(
          public.site_spec_output(spec, 'webflow')->'steps') s
         where (s.value->>'n')::int = 2) then
    raise exception
      'site_output_setup_sheet: Squarespace and Webflow are told to use the same panel.';
  end if;

  -- Five hexes, each with its role, in the colour step.
  if jsonb_array_length((select s.value->'values' from jsonb_array_elements(sheet->'steps') s
                          where (s.value->>'n')::int = 2)) <> 5 then
    raise exception 'site_output_setup_sheet: the color step does not carry five values.';
  end if;

  -- The constraints survive into the checklist. A Squarespace user is under
  -- the same advertising rules as everyone else.
  if (select s.value->>'body' from jsonb_array_elements(sheet->'steps') s
       where (s.value->>'n')::int = 7) not like '%Do not invent testimonials%' then
    raise exception 'site_output_setup_sheet: a constraint is missing from the checklist.';
  end if;

  -- Her notes are the last step, verbatim, and absent when she has written none.
  if (select s.value->>'body' from jsonb_array_elements(sheet->'steps') s
       where (s.value->>'n')::int = 8) <> 'Please keep the fee off the home page.' then
    raise exception 'site_output_setup_sheet: extra_instructions is not the last step, verbatim.';
  end if;
  if exists (select 1 from jsonb_array_elements(
               public.site_spec_output(spec - 'extra_instructions', 'squarespace')->'steps') s
              where (s.value->>'n')::int = 8) then
    raise exception 'site_output_setup_sheet: an empty notes step was emitted.';
  end if;

  -- Copy blocks: one per string, and a list item is its own block.
  if jsonb_array_length(sheet->'copy_blocks') < 8 then
    raise exception 'site_output_setup_sheet: % copy blocks, expected one per string.',
      jsonb_array_length(sheet->'copy_blocks');
  end if;
  if not exists (
    select 1 from jsonb_array_elements(sheet->'copy_blocks') b
     where b.value->>'text' = 'Anxiety' and b.value->>'label' like 'Areas %'
  ) then
    raise exception
      'site_output_setup_sheet: a list item did not become its own copyable block.';
  end if;
  if exists (select 1 from jsonb_array_elements(sheet->'copy_blocks') b
              where btrim(coalesce(b.value->>'text', '')) = '') then
    raise exception 'site_output_setup_sheet: an empty copy block was emitted.';
  end if;

  -- Determinism, for both kinds.
  if public.site_spec_output(spec, 'squarespace')
     is distinct from public.site_spec_output(spec, 'squarespace') then
    raise exception 'site_output_setup_sheet: two renders of one sheet differ.';
  end if;

  -- The markdown and plain renderings both produce something, and differ.
  if public.site_spec_output_render('Squarespace', sheet, true) is null
     or public.site_spec_output_render('Squarespace', sheet, false) is null then
    raise exception 'site_output_setup_sheet: a rendering came back empty.';
  end if;
  if public.site_spec_output_render('Squarespace', sheet, true) not like '%## 2. Set your five colors%' then
    raise exception 'site_output_setup_sheet: the markdown rendering has no step headings.';
  end if;
  if public.site_spec_output_render('Squarespace', sheet, false) like '%## %' then
    raise exception 'site_output_setup_sheet: the plain rendering kept its markdown markers.';
  end if;
  if public.site_spec_output_render('Lovable', public.site_spec_output(spec, 'lovable'), false)
     like '%## Constraints%' then
    raise exception 'site_output_setup_sheet: the plain prompt kept its markdown headings.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop trigger if exists on_site_spec_written on public.site_specs;
--   drop function if exists public.refresh_brand_kit_site_prompt();
--   drop function if exists public.site_output_get(uuid, text, text);
--   drop function if exists public.site_spec_output_render(text, jsonb, boolean);
--   drop function if exists public.site_spec_output_setup_sheet(jsonb, text);
--   drop function if exists public.site_spec_copy_blocks(jsonb);
--   -- then re-create site_spec_output() and site_spec_output_prompt() from
--   -- 20260829104000, which do not call site_spec_structure_lines():
--   drop function if exists public.site_spec_structure_lines(jsonb);
