-- ============================================================================
-- Eklio — the practitioner's name, and her voice guide, in the output
-- ============================================================================
-- Follows `20260829119000_cta_ink_and_size_floor.sql`.
--
-- TWO THINGS THE OLD PROMPT BUILDER CARRIED AND THIS ONE DID NOT
-- ---------------------------------------------------------------
--
-- **1. Nobody's name.** `practice_details` held the practice name, the licence
-- label and number, the city, the state, the email and the phone — and not the
-- name of the person. The derived output could produce a therapist's website
-- that never names the therapist. It is also a compliance gap: a board that
-- requires a licence number in advertising requires the licensee's name beside
-- it.
--
-- ⚠ `project_briefs` HAS NO SUCH ANSWER TODAY. Checked before writing: its
-- columns are practice_name, positioning, license_type_id, primary_action_id,
-- specialty_ids, site_goal_ids, city, state and the card ids. So
-- `practitioner_name` is seeded EMPTY, prints nothing when empty rather than a
-- dangling comma, and the brief needs a question before it carries anything.
--
-- ⚠ AND THE SETUP SHEET NEVER STATED THE PRACTICE IDENTITY AT ALL. Measured:
-- the licence number appears in no step of the Squarespace sheet. `practice_details`
-- reached the prompt's `## Practice` block and nothing else, so a therapist on
-- Squarespace was never told to put her licence on her own site. A details step
-- is added here — it is where the composed line belongs, and it was missing
-- outright.
--
-- **2. Her voice guide.** The old builder sent SOUNDS LIKE and NEVER WRITE. The
-- constraints block tells a builder not to rewrite her copy, but the builder
-- still writes navigation labels, button microcopy, alt text, form labels and a
-- 404 page — and without the guide all of it comes out in the model's default
-- voice. NEVER WRITE is the Ethics Guard's own counter-examples, which is the
-- single most useful thing to put in front of a model that might improvise a
-- promise of results.
-- ============================================================================


-- ============================================================================
-- 1. practitioner_name
-- ============================================================================
-- The allowed key list moves into a function so that the next detail added does
-- not require replacing `site_spec_patch` again. It was inline in two places
-- and had to be edited in both.

create or replace function public.site_spec_practice_detail_keys()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['practitioner_name', 'practice_name', 'license_label', 'license_number',
               'city', 'state', 'email', 'phone']
$$;

grant execute on function public.site_spec_practice_detail_keys() to authenticated, service_role;

create or replace function public.site_spec_practice_details_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    case
      when p is null then false
      when jsonb_typeof(p) <> 'object' then false
      else not exists (
        select 1 from unnest(public.site_spec_practice_detail_keys()) as k(name)
         where jsonb_typeof(p -> k.name) is not null
           and jsonb_typeof(p -> k.name) not in ('string', 'null')
      )
      and (nullif(btrim(coalesce(p->>'state', '')), '') is null
           or btrim(p->>'state') ~ '^[A-Za-z]{2}$')
    end,
  false)
$$;


-- ============================================================================
-- 2. The voice guide, reachable from a spec
-- ============================================================================
-- Read from `brand_kits.voice_guide` rather than copied into `site_specs`: a
-- copy is a second value that drifts from the one the Ethics Guard wrote.
--
-- Accepts an inline `voice_guide` key too, so a spec literal — a snapshot
-- fixture, a report — renders the same section as a real row instead of
-- silently losing it. Same reasoning as `site_spec_variant_of`.

create or replace function public.site_spec_voice_guide(p_spec jsonb)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select v.g
    from (
      select coalesce(
        p_spec->'voice_guide',
        (select bk.voice_guide from public.brand_kits bk
          where bk.id = nullif(p_spec->>'brand_kit_id', '')::uuid)) as g
    ) v
   -- ⚠ an empty or malformed guide is NOT a guide. Returning it would print a
   -- heading with nothing under it, which is the failure this repo keeps
   -- finding: a hole that raises nothing.
   where jsonb_typeof(v.g) = 'object'
     and jsonb_typeof(v.g->'sounds_like') = 'array'
     and jsonb_typeof(v.g->'never_write') = 'array'
     and jsonb_array_length(v.g->'sounds_like') > 0
     and jsonb_array_length(v.g->'never_write') > 0
$$;

comment on function public.site_spec_voice_guide(jsonb) is
  'The brand kit''s voice guide for a site spec, or NULL when there is none. Read from brand_kits rather than copied, and NULL for an empty or malformed guide so the output omits the section entirely.';

grant execute on function public.site_spec_voice_guide(jsonb) to authenticated, service_role;


-- ============================================================================
-- 3. Fragments
-- ============================================================================

-- >>> PRACTITIONER AND VOICE TEMPLATE DATA (mirrored verbatim in supabase/seed.sql) >>>

insert into public.site_output_templates (id, target, key, body, sort_order) values
  ('all.identity.label_practitioner', null, 'identity.label_practitioner',
   'Licensed practitioner', 21),

  ('all.voice.heading', null, 'voice.heading', '## Voice', 46),
  ('all.voice.intro', null, 'voice.intro',
   'Anything you write that is not in the copy above — navigation labels, button microcopy, alt text, form labels, error messages, a 404 page — must sound like the first list and must never sound like the second.', 47),
  ('all.voice.sounds_like_label', null, 'voice.sounds_like_label', 'Sounds like', 48),
  ('all.voice.never_write_label', null, 'voice.never_write_label', 'Never write', 49),

  ('all.sheet.step_details_title', null, 'sheet.step_details_title',
   'Fill in your practice details', 55),
  ('all.sheet.step_details_body', null, 'sheet.step_details_body',
   'These go in your footer and on your contact page. Your name and license belong together wherever either appears — most boards require it.', 56),

  ('all.sheet.step_voice_title', null, 'sheet.step_voice_title',
   'Keep these in view when you write anything else', 71),
  ('all.sheet.step_voice_body', null, 'sheet.step_voice_body',
   'A template will ask you for words this sheet does not cover: a menu label, a button, a caption under a photo, the page someone lands on when a link breaks. Write those in your own voice, and check them against the second list before you publish.', 72)
on conflict (id) do update set body = excluded.body, sort_order = excluded.sort_order;

-- <<< PRACTITIONER AND VOICE TEMPLATE DATA <<<


-- ============================================================================
-- 4. The composed credential line
-- ============================================================================
-- `{practitioner_name}, {license_label} #{license_number}`, composed from the
-- parts. There is deliberately no free-text field holding the composed string:
-- `brand_kits.practitioner_line` already is one, and having two would mean two
-- ways for the name to be wrong.
--
-- ⚠ EVERY PART IS OPTIONAL AND NOTHING DANGLES. Name alone prints the name.
-- Licence alone prints what it printed before. Neither prints no line at all —
-- not a label with an empty value, and never a leading comma.

create or replace function public.site_spec_credential_line(p_details jsonb, p_frag jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when v.value is null then null
              else v.label || ': ' || v.value end
    from (
      select
        -- "Licensed practitioner" once a person is named, "License" otherwise
        case when nullif(btrim(coalesce(p_details->>'practitioner_name', '')), '') is not null
             then p_frag->>'identity.label_practitioner'
             else p_frag->>'identity.label_license' end as label,
        nullif(array_to_string(array_remove(array[
          nullif(btrim(coalesce(p_details->>'practitioner_name', '')), ''),
          case when nullif(btrim(coalesce(p_details->>'license_label', '')), '') is not null
               then btrim(p_details->>'license_label')
                    || coalesce(' #' || nullif(btrim(coalesce(p_details->>'license_number','')), ''), '')
          end
        ], null), ', '), '') as value
    ) v
$$;

comment on function public.site_spec_credential_line(jsonb, jsonb) is
  'The "Nora Whitfield, LCSW #LC61234" line, composed from practitioner_name, license_label and license_number. NULL when none of them is set; never a dangling comma.';

grant execute on function public.site_spec_credential_line(jsonb, jsonb) to authenticated, service_role;

create or replace function public.site_spec_identity_lines(p_spec jsonb, p_frag jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(array_to_string(array_remove(array[
    case when nullif(btrim(coalesce(d.v->>'practice_name', '')), '') is not null
         then (p_frag->>'identity.label_name') || ': ' || btrim(d.v->>'practice_name') end,
    -- name and credential together, or whichever of them exists
    public.site_spec_credential_line(d.v, p_frag),
    case when nullif(btrim(coalesce(d.v->>'city', '')), '') is not null
          and nullif(btrim(coalesce(d.v->>'state', '')), '') is not null
         then (p_frag->>'identity.label_location') || ': '
              || btrim(d.v->>'city') || ', ' || upper(btrim(d.v->>'state')) end,
    case when nullif(btrim(coalesce(d.v->>'email', '')), '') is not null
         then (p_frag->>'identity.label_email') || ': ' || btrim(d.v->>'email') end,
    case when nullif(btrim(coalesce(d.v->>'phone', '')), '') is not null
         then (p_frag->>'identity.label_phone') || ': ' || btrim(d.v->>'phone') end
  ], null), E'\n'), '')
  from (select coalesce(p_spec->'practice_details', '{}'::jsonb) as v) d
$$;


-- ============================================================================
-- 5. The voice section, rendered
-- ============================================================================

create or replace function public.site_spec_voice_lines(p_spec jsonb, p_frag jsonb)
returns text
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select case when g.v is null then null else
    (p_frag->>'voice.intro') || E'\n\n'
    || (p_frag->>'voice.sounds_like_label') || ':' || E'\n'
    || coalesce((select string_agg('- ' || (e.value #>> '{}'), E'\n' order by e.ord)
                   from jsonb_array_elements(g.v->'sounds_like') with ordinality as e(value, ord)
                  where btrim(e.value #>> '{}') <> ''), '')
    || E'\n\n'
    || (p_frag->>'voice.never_write_label') || ':' || E'\n'
    || coalesce((select string_agg('- ' || (e.value #>> '{}'), E'\n' order by e.ord)
                   from jsonb_array_elements(g.v->'never_write') with ordinality as e(value, ord)
                  where btrim(e.value #>> '{}') <> ''), '')
  end
  from (select public.site_spec_voice_guide(p_spec) as v) g
$$;

grant execute on function public.site_spec_voice_lines(jsonb, jsonb) to authenticated, service_role;

-- ⚠ The voice section sits IMMEDIATELY BEFORE the constraints, and omits itself
-- entirely when there is no guide — no heading with nothing under it.
create or replace function public.site_spec_output_prompt(p_spec jsonb, p_target text)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  with frag as (select public.site_output_fragments(p_target) as f),
  pv as (select public.site_spec_preview_model(p_spec) as m),
  -- ⚠ once. `site_spec_voice_lines` reads `brand_kits`; calling it in both the
  -- guard and the body doubles that lookup on every render of every envelope.
  voice as (select public.site_spec_voice_lines(p_spec, (select f from frag)) as v),
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

      -- her voice, immediately before the constraints: the two belong together
      case when (select v from voice) is not null
           then (select f->>'voice.heading' from frag) || E'\n' || (select v from voice) end,

      (select f->>'prompt.heading_constraints' from frag) || E'\n' ||
        (select string_agg('- ' || c.line, E'\n' order by c.ord)
           from unnest(public.site_spec_constraint_lines(p_spec, (select f from frag)))
                with ordinality as c(line, ord)),

      case when nullif(btrim(coalesce(p_spec->>'extra_instructions', '')), '') is not null
           then (select f->>'prompt.heading_extra' from frag) || E'\n'
                || (p_spec->>'extra_instructions') end

    ], null), E'\n\n') as text) t
  ) end
$$;


-- ⚠ AND THE ETAG HAS TO COVER IT.
-- `voice_guide` is the first envelope input that lives OUTSIDE `site_specs`:
-- the Ethics Guard rewrites it on `brand_kits`, the deliverable changes, and
-- not one etag input moves. That is the same shape as the mark-copied bug
-- 20260829116000 fixed — a client re-reading with If-None-Match gets a 304 and
-- keeps a prompt whose NEVER WRITE list is out of date.
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
    -- ⚠ `last_copied_spec_version` is here because mark-copied moves nothing
    -- else, the catalog fingerprint because tuning the output copy moves
    -- nothing in the row, and the voice guide because it is not in the row at
    -- all. Each of the three changed the body while leaving the old etag valid.
    'etag', md5(concat_ws(':', p_row->>'brand_kit_id',
                               p_row->>'spec_version',
                               p_row->>'target',
                               coalesce(p_row->>'last_copied_spec_version', '-'),
                               public.site_output_catalog_version(),
                               coalesce(public.site_spec_voice_guide(p_row)::text, '-')))
  ) end
$$;

grant execute on function public.site_spec_envelope(jsonb) to authenticated, service_role;


-- ============================================================================
-- 6. The setup sheet gains a details step and a voice step
-- ============================================================================
-- Eleven steps. The details step is where the composed credential line belongs
-- and it was missing outright; the voice step sits near the end, framed for a
-- person rather than a model.

create or replace function public.site_spec_output_setup_sheet(p_spec jsonb, p_target text)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  with bt as (select * from public.builder_targets where id = p_target),
  frag as (select public.site_output_fragments(p_target) as f),
  det as (select coalesce(p_spec->'practice_details', '{}'::jsonb) as d),
  voice as (select public.site_spec_voice_lines(p_spec, (select f from frag)) as v),
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
    -- ⚠ NEW, AND IT WAS MISSING ENTIRELY. The sheet never told her to put her
    -- practice name or her licence anywhere on her own site.
    select 6,
           (select f->>'sheet.step_details_title' from frag),
           (select f->>'sheet.step_details_body' from frag),
           coalesce((
             select jsonb_agg(x.v order by x.ord) from (
               select 1 as ord, jsonb_build_object(
                 'label', (select f->>'identity.label_name' from frag),
                 'value', btrim(det.d->>'practice_name'), 'kind', 'text') as v
                 from det where nullif(btrim(coalesce(det.d->>'practice_name','')),'') is not null
               union all
               select 2, jsonb_build_object(
                 'label', split_part(cred.line, ': ', 1),
                 'value', substr(cred.line, position(': ' in cred.line) + 2), 'kind', 'text')
                 from det, lateral (select public.site_spec_credential_line(
                                             det.d, (select f from frag)) as line) cred
                where cred.line is not null
               union all
               select 3, jsonb_build_object(
                 'label', (select f->>'identity.label_location' from frag),
                 'value', btrim(det.d->>'city') || ', ' || upper(btrim(det.d->>'state')), 'kind', 'text')
                 from det where nullif(btrim(coalesce(det.d->>'city','')),'') is not null
                           and nullif(btrim(coalesce(det.d->>'state','')),'') is not null
               union all
               select 4, jsonb_build_object(
                 'label', (select f->>'identity.label_email' from frag),
                 'value', btrim(det.d->>'email'), 'kind', 'text')
                 from det where nullif(btrim(coalesce(det.d->>'email','')),'') is not null
               union all
               select 5, jsonb_build_object(
                 'label', (select f->>'identity.label_phone' from frag),
                 'value', btrim(det.d->>'phone'), 'kind', 'text')
                 from det where nullif(btrim(coalesce(det.d->>'phone','')),'') is not null
             ) x), '[]'::jsonb),
           null
    union all
    select 7,
           (select f->>'sheet.step5_title' from frag),
           (select f->>'sheet.step5_body' from frag),
           '[]'::jsonb,
           null
    union all
    select 8,
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
    -- ⚠ NEW: her voice, near the end, framed for a person rather than a model.
    -- Omitted entirely when the kit carries no guide.
    select 9,
           (select f->>'sheet.step_voice_title' from frag),
           (select f->>'sheet.step_voice_body' from frag) || E'\n\n' || (select v from voice),
           '[]'::jsonb,
           null
     where (select v from voice) is not null
    union all
    select 10,
           (select f->>'sheet.step7_title' from frag),
           (select string_agg('[ ] ' || c.line, E'\n' order by c.ord)
              from unnest(public.site_spec_constraint_lines(p_spec, (select f from frag)))
                   with ordinality as c(line, ord)),
           '[]'::jsonb,
           null
    union all
    select 11,
           (select f->>'sheet.step8_title' from frag),
           p_spec->>'extra_instructions',
           '[]'::jsonb,
           null
     where nullif(btrim(coalesce(p_spec->>'extra_instructions', '')), '') is not null
  ),
  -- renumbered so the steps she reads are 1..n with no gap where an omitted
  -- step used to be
  numbered as (
    select row_number() over (order by st.n) as n, st.title, st.body, st.values, st.builder_hint
      from steps st
  )
  select case when p_spec is null then null else jsonb_build_object(
    'kind', 'setup_sheet',
    'steps', (select jsonb_agg(jsonb_build_object(
                       'n', nb.n, 'title', nb.title, 'body', nb.body,
                       'values', nb.values, 'builder_hint', nb.builder_hint)
                     order by nb.n)
                from numbered nb),
    'copy_blocks', public.site_spec_copy_blocks(p_spec)
  ) end
$$;


-- ============================================================================
-- 7. Seeding, and the patch path
-- ============================================================================

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
      -- ⚠ EMPTY. `project_briefs` has no question that answers this today; the
      -- brief needs one before it can carry anything. Empty prints nothing.
      'practitioner_name', null,
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

-- The patch's practice-details whitelist now reads the catalog function, so the
-- next detail added does not require replacing this function again.
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
      if not (k = any (public.site_spec_practice_detail_keys())) then
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

-- Existing specs get the key, empty, so the editor has a field to bind to.
update public.site_specs
   set practice_details = jsonb_build_object('practitioner_name', null) || practice_details
 where not (practice_details ? 'practitioner_name');


-- ============================================================================
-- 8. Guard rails
-- ============================================================================
do $$
declare
  f    jsonb := public.site_output_fragments(null);
  det  jsonb;
  spec jsonb;
  t    text;
  vg   jsonb := jsonb_build_object(
          'sounds_like', jsonb_build_array('Plain, unhurried sentences.',
                                           'Say the difficult thing kindly.',
                                           'Write to one person, not an audience.'),
          'never_write', jsonb_build_array('Heal your anxiety in 12 weeks.',
                                           'Clients often tell me...',
                                           'Limited spots available.'));
begin
  -- ---- the composed credential line, every combination ---------------------
  det := jsonb_build_object('practitioner_name','Nora Whitfield',
                            'license_label','LCSW','license_number','LC61234');
  if public.site_spec_credential_line(det, f) <> 'Licensed practitioner: Nora Whitfield, LCSW #LC61234' then
    raise exception 'practitioner_name: the composed line is "%"',
      public.site_spec_credential_line(det, f);
  end if;

  -- ⚠ NOTHING DANGLES. Every part is optional.
  if public.site_spec_credential_line(
       jsonb_build_object('license_label','LCSW','license_number','LC61234'), f)
     <> 'License: LCSW #LC61234' then
    raise exception 'practitioner_name: without a name the line changed shape.';
  end if;
  if public.site_spec_credential_line(jsonb_build_object('practitioner_name','Nora Whitfield'), f)
     <> 'Licensed practitioner: Nora Whitfield' then
    raise exception 'practitioner_name: a name with no licence did not print alone.';
  end if;
  if public.site_spec_credential_line(
       jsonb_build_object('practitioner_name','Nora Whitfield','license_label','LCSW'), f)
     <> 'Licensed practitioner: Nora Whitfield, LCSW' then
    raise exception 'practitioner_name: a licence with no number printed a stray hash.';
  end if;
  if public.site_spec_credential_line('{}'::jsonb, f) is not null then
    raise exception 'practitioner_name: an empty detail set printed a line.';
  end if;
  if public.site_spec_credential_line(
       jsonb_build_object('practitioner_name','','license_label',''), f) is not null then
    raise exception 'practitioner_name: blank strings printed a line.';
  end if;

  -- patchable, and validated
  if not ('practitioner_name' = any (public.site_spec_practice_detail_keys())) then
    raise exception 'practitioner_name: it is not an accepted practice detail.';
  end if;
  if not public.site_spec_practice_details_valid(
       jsonb_build_object('practitioner_name','Nora Whitfield')) then
    raise exception 'practitioner_name: a valid detail set was refused.';
  end if;
  if public.site_spec_practice_details_valid(
       jsonb_build_object('practitioner_name', 42)) then
    raise exception 'practitioner_name: a non-string name was accepted.';
  end if;

  -- ---- the voice guide -----------------------------------------------------
  spec := jsonb_build_object(
    'primary_hex','#B4674A','secondary_hex','#C08A3E','accent_hex','#6E3320',
    'light_neutral_hex','#F4EEE3','dark_neutral_hex','#2B2A27','paper_hex','#FAF6EE',
    'heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','u',
    'about_excerpt','x',
    'practice_details', jsonb_build_object('practitioner_name','Nora Whitfield',
      'practice_name','Elm & Ember Therapy','license_label','LCSW','license_number','LC61234',
      'city','Portland','state','OR','email','n@e.com','phone','(503) 555-0123'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s',
                               'cta_label','c','cta_target_url','https://x.example/b'),
    'pages', public.site_spec_default_pages(null,null), 'target','lovable');

  -- ⚠ NO GUIDE, NO SECTION. Not a heading with nothing under it.
  if public.site_spec_voice_guide(spec) is not null then
    raise exception 'voice_guide: a spec with no guide resolved one.';
  end if;
  if public.site_spec_voice_lines(spec, f) is not null then
    raise exception 'voice_guide: a spec with no guide rendered lines.';
  end if;
  t := public.site_spec_output(spec, 'lovable')->>'text';
  if position('## Voice' in t) > 0 then
    raise exception 'voice_guide: an empty guide still printed its heading.';
  end if;
  foreach t in array array['{}', 'null', '{"sounds_like":[],"never_write":[]}',
                           '{"sounds_like":["a"]}', '"scalar"'] loop
    if public.site_spec_voice_guide(spec || jsonb_build_object('voice_guide', t::jsonb)) is not null then
      raise exception 'voice_guide: the malformed guide %s resolved.', t;
    end if;
  end loop;

  -- with a guide, it renders and sits immediately before the constraints
  spec := spec || jsonb_build_object('voice_guide', vg);
  t := public.site_spec_output(spec, 'lovable')->>'text';
  if position('## Voice' in t) = 0 then
    raise exception 'voice_guide: the section is missing from the prompt.';
  end if;
  if position('## Voice' in t) > position('## Constraints' in t) then
    raise exception 'voice_guide: the section is not before the constraints.';
  end if;
  if position('## Copy' in t) > position('## Voice' in t) then
    raise exception 'voice_guide: the section is before the copy.';
  end if;
  if position('Plain, unhurried sentences.' in t) = 0
     or position('Limited spots available.' in t) = 0 then
    raise exception 'voice_guide: a line did not reach the prompt.';
  end if;
  if position('Sounds like:' in t) = 0 or position('Never write:' in t) = 0 then
    raise exception 'voice_guide: a list label is missing.';
  end if;

  -- ---- the sheet: a details step, and a voice step near the end ------------
  if not exists (
    select 1 from jsonb_array_elements(public.site_spec_output(spec,'squarespace')->'steps') s
    cross join lateral jsonb_array_elements(s.value->'values') v
     where v.value->>'value' = 'Nora Whitfield, LCSW #LC61234'
  ) then
    raise exception 'practitioner_name: the setup sheet does not state the credential line.';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(public.site_spec_output(spec,'squarespace')->'steps') s
     where s.value->>'title' = 'Keep these in view when you write anything else'
       and position('Limited spots available.' in s.value->>'body') > 0
  ) then
    raise exception 'voice_guide: the setup sheet has no voice step.';
  end if;
  -- and no voice step when there is no guide
  if exists (
    select 1 from jsonb_array_elements(
             public.site_spec_output(spec - 'voice_guide','squarespace')->'steps') s
     where s.value->>'title' = 'Keep these in view when you write anything else'
  ) then
    raise exception 'voice_guide: a voice step was emitted with no guide.';
  end if;

  -- ⚠ the steps are renumbered so there is no gap where an omitted step was
  if (select array_agg((s.value->>'n')::int order by (s.value->>'n')::int)
        from jsonb_array_elements(public.site_spec_output(spec - 'voice_guide' - 'extra_instructions',
                                                          'squarespace')->'steps') s)
     <> array[1,2,3,4,5,6,7,8,9] then
    raise exception 'voice_guide: omitting a step left a gap in the numbering.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_spec_output_prompt, site_spec_output_setup_sheet,
--   -- site_spec_identity_lines, site_spec_seed_values, site_spec_patch and
--   -- site_spec_practice_details_valid from 20260829119000 and earlier, each
--   -- WITH its `set jit = 'off'` clause where it had one, then:
--   delete from public.site_output_templates
--    where key in ('identity.label_practitioner','voice.heading','voice.intro',
--                  'voice.sounds_like_label','voice.never_write_label',
--                  'sheet.step_details_title','sheet.step_details_body',
--                  'sheet.step_voice_title','sheet.step_voice_body');
--   -- and site_spec_envelope, WITHOUT the voice guide in the etag
--   drop function if exists public.site_spec_voice_lines(jsonb, jsonb);
--   drop function if exists public.site_spec_voice_guide(jsonb);
--   drop function if exists public.site_spec_credential_line(jsonb, jsonb);
--   drop function if exists public.site_spec_practice_detail_keys();
--   update public.site_specs set practice_details = practice_details - 'practitioner_name';
