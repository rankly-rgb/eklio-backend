-- ============================================================================
-- Eklio — two more reference catalogs: section types and builder targets
-- ============================================================================
-- Follows `20260829100000_site_spec.sql`. Same conventions as the eleven
-- catalogs in `20260827100000_catalog_reference_data.sql`: `id text` primary
-- key holding a stable slug, `sort_order`, `active`, no timestamps (a catalog
-- row's history is this repo's git history), one SELECT policy `to
-- authenticated`, no write policy at all.
--
-- WHY `builder_targets` IS THE INTERESTING HALF
-- --------------------------------------------
-- `accepts_prompt` is not a decoration. Lovable, Framer, v0 and a generic
-- target have a box you paste a prompt into. **Squarespace, Wix and Webflow do
-- not.** There is no prompt input anywhere in those three products. Handing
-- their users a prompt is handing them nothing at all — a wall of text with no
-- destination — and it is precisely the failure the current single
-- `site_prompt` column ships today. So the flag drives a real fork in
-- `site_spec_output()`: a prompt for the first group, a numbered setup sheet
-- naming each product's actual panels for the second.
--
-- ⚠ `accepts_prompt` IS A GENERATED COLUMN, for the reason
-- `subscriptions.active` is. Written by hand it would be a second copy of
-- `output_kind` maintained in the same INSERT, and the day the two disagree is
-- the day a Squarespace user is shipped a prompt.
--
-- THREE COLUMNS BEYOND THE PRODUCT SPEC'S FIVE, and they are not extras.
-- §6.2 requires the sheet to "name the actual panel for that builder"
-- (Squarespace → Site Styles › Colors). Those names are product copy that
-- changes when a builder redesigns its editor. In a CASE inside a function
-- body they would be product copy hidden in code, invisible to the catalog and
-- unchangeable without touching the renderer; here they are three columns and
-- a data-only migration.
-- ============================================================================


-- ============================================================================
-- 1. section_types
-- ============================================================================
-- The eleven kinds of block a page can hold. `fields` declares what the editor
-- renders for each: a key, a label, a kind, and the length the write path will
-- actually accept.
--
-- ⚠ `source` IS THE COLUMN THE PRODUCT SPEC DOES NOT LIST AND THE EDITOR
-- CANNOT DO WITHOUT. Two section types do not keep their copy in the section's
-- own `fields`: the hero reads `site_specs.hero` and the intro reads
-- `site_specs.about_excerpt`, because those two are columns in their own right
-- with their own CHECKs (§1.1 of the product spec puts them there). Without
-- this column the editor would render an editable empty `fields` object for
-- the hero and quietly drop every keystroke into a place nothing reads.

create table if not exists public.section_types (
  id              text    primary key,
  sort_order      int     not null,
  active          boolean not null default true,
  label           text    not null,
  description     text    not null,
  fields          jsonb   not null,
  default_enabled boolean not null,
  allowed_pages   text[]  not null,
  -- 'fields' | 'spec.hero' | 'spec.about_excerpt'
  source          text    not null default 'fields'
);

-- The description is the section's PURPOSE, printed into the builder output
-- under the structure listing (§6.1 step 4), so it is a sentence a builder can
-- act on rather than a label.
create or replace function public.section_type_fields_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then false
    when jsonb_typeof(p) <> 'array' then false
    else not exists (
      select 1 from jsonb_array_elements(p) as f
      where jsonb_typeof(f.value) <> 'object'
         or jsonb_typeof(f.value->'key')   is distinct from 'string'
         or jsonb_typeof(f.value->'label') is distinct from 'string'
         or not (f.value->>'kind' = any (array['text', 'longtext', 'list']))
         or jsonb_typeof(f.value->'max_length') is distinct from 'number'
         -- ⚠ 800 is §1.2's ceiling for any section text field, enforced by
         -- `site_spec_pages_lengths_valid`. A catalog advertising 900 would
         -- promise the editor a length the write path refuses.
         or (f.value->>'max_length')::numeric not between 1 and 800
    )
    and (select count(distinct f.value->>'key') from jsonb_array_elements(p) f)
        = jsonb_array_length(p)
  end
$$;

alter table public.section_types drop constraint if exists section_types_fields_check;
alter table public.section_types
  add constraint section_types_fields_check check (public.section_type_fields_valid(fields));

alter table public.section_types drop constraint if exists section_types_allowed_pages_check;
alter table public.section_types
  add constraint section_types_allowed_pages_check check (
    coalesce(array_length(allowed_pages, 1), 0) > 0
    and allowed_pages <@ public.site_spec_page_keys()
  );

alter table public.section_types drop constraint if exists section_types_source_check;
alter table public.section_types
  add constraint section_types_source_check check (
    source = any (array['fields'::text, 'spec.hero'::text, 'spec.about_excerpt'::text])
  );

alter table public.section_types drop constraint if exists section_types_label_check;
alter table public.section_types
  add constraint section_types_label_check check (
    char_length(label) <= 32 and char_length(description) <= 160
  );

comment on table public.section_types is
  'The eleven kinds of block a site spec page can hold. `description` is the section''s purpose and is printed verbatim into the builder output''s structure listing. `source` says where the copy lives: the section''s own fields, or site_specs.hero / site_specs.about_excerpt.';


-- ============================================================================
-- 2. builder_targets
-- ============================================================================

create table if not exists public.builder_targets (
  id             text    primary key,
  sort_order     int     not null,
  active         boolean not null default true,
  label          text    not null,
  output_kind    text    not null,
  -- The whole point of this table, and it cannot drift from output_kind.
  accepts_prompt boolean generated always as (output_kind = 'prompt') stored,
  docs_url       text,

  -- Setup-sheet material. Null for prompt targets, which have no panels.
  template_hint  text,
  color_panel    text,
  font_panel     text,
  section_panel  text
);

alter table public.builder_targets drop constraint if exists builder_targets_output_kind_check;
alter table public.builder_targets
  add constraint builder_targets_output_kind_check check (
    output_kind = any (array['prompt'::text, 'setup_sheet'::text])
  );

-- A setup sheet that cannot name the panel to type a hex into is a sheet that
-- says "set your colours somewhere". The four columns are the sheet.
alter table public.builder_targets drop constraint if exists builder_targets_panels_check;
alter table public.builder_targets
  add constraint builder_targets_panels_check check (
    case output_kind
      when 'setup_sheet' then
        template_hint is not null and color_panel is not null
        and font_panel is not null and section_panel is not null
      else
        template_hint is null and color_panel is null
        and font_panel is null and section_panel is null
    end
  );

alter table public.builder_targets drop constraint if exists builder_targets_docs_url_check;
alter table public.builder_targets
  add constraint builder_targets_docs_url_check check (
    docs_url is null or docs_url like 'https://%'
  );

comment on table public.builder_targets is
  'The seven website builders a site spec can be exported for. accepts_prompt is generated from output_kind and is the fork in site_spec_output(): Squarespace, Wix and Webflow have no prompt input, so they get a numbered setup sheet naming their own panels.';
comment on column public.builder_targets.accepts_prompt is
  'Generated from output_kind. Never written by hand: a stored copy could disagree with output_kind, and the day it does a Squarespace user is shipped a prompt for a product with no prompt input.';


-- ============================================================================
-- 3. RLS — readable by any authenticated user, writable by no one
-- ============================================================================
-- `to authenticated` for the reason the eleven existing catalogs carry it:
-- `using (true)` has none of the self-closing property an `auth.uid()`
-- predicate has, and without the clause it would publish product content to
-- unauthenticated visitors.

alter table public.section_types   enable row level security;
alter table public.builder_targets enable row level security;

drop policy if exists "section_types_select_all"   on public.section_types;
drop policy if exists "builder_targets_select_all" on public.builder_targets;

create policy "section_types_select_all"
  on public.section_types for select to authenticated using (true);
create policy "builder_targets_select_all"
  on public.builder_targets for select to authenticated using (true);


-- ============================================================================
-- 4. `project_briefs.builder_target_id` — where the default target comes from
-- ============================================================================
-- The brief asks which builder she uses; nothing stored the answer. It lands
-- here rather than in the previous migration because a real foreign key needs
-- `builder_targets` to exist, and the scalar catalog references on this table
-- all have one (`tone_card_id`, `type_pairing_id`, `license_type_id`,
-- `primary_action_id`), with their index on the referencing side.

alter table public.project_briefs
  add column if not exists builder_target_id text;

alter table public.project_briefs drop constraint if exists project_briefs_builder_target_id_fkey;
alter table public.project_briefs
  add constraint project_briefs_builder_target_id_fkey
  foreign key (builder_target_id) references public.builder_targets (id) on delete restrict;

create index if not exists project_briefs_builder_target_id_idx
  on public.project_briefs (builder_target_id);

comment on column public.project_briefs.builder_target_id is
  'Which website builder the therapist uses. Seeds site_specs.target; she can switch afterwards without re-answering the brief.';

-- The brief's answer wins over `brand_kits.site_prompt_target`: the kit column
-- records what the generator happened to render for, the brief records what
-- she said she uses, and when they differ she is right.
create or replace function public.site_spec_default_target(p_brand_kit_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select pb.builder_target_id
       from public.brand_kits bk
       join public.project_briefs pb on pb.project_id = bk.project_id
      where bk.id = p_brand_kit_id),
    (select bk.site_prompt_target from public.brand_kits bk where bk.id = p_brand_kit_id),
    'generic')
$$;


-- ============================================================================
-- 5. Catalog data — idempotent upserts
-- ============================================================================
-- ⚠ EVERYTHING BETWEEN THE TWO MARKERS BELOW IS MIRRORED VERBATIM IN
-- `supabase/seed.sql`, exactly like the eleven catalogs before it. Change one,
-- change the other. Regenerate the mirror with:
--
--   awk '/^-- >>> SITE SPEC CATALOG DATA/,/^-- <<< SITE SPEC CATALOG DATA/' \
--     supabase/migrations/20260829101000_site_spec_catalog.sql \
--     > /tmp/site-spec-catalog.sql
--
-- and splice it in under the first block in seed.sql.

-- >>> SITE SPEC CATALOG DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ---- section_types ---------------------------------------------------------
-- `description` is printed into the builder output as the section's purpose,
-- so it is written as an instruction to whoever builds the page.
insert into public.section_types
  (id, sort_order, active, label, description, fields, default_enabled, allowed_pages, source) values

  ('hero', 1, true, 'Hero',
   'The first screen: a short overline, one headline, one supporting line, and a single call to action.',
   '[{"key":"overline","label":"Overline","kind":"text","max_length":48},
     {"key":"headline","label":"Headline","kind":"text","max_length":90},
     {"key":"subhead","label":"Supporting line","kind":"longtext","max_length":220},
     {"key":"cta_label","label":"Button label","kind":"text","max_length":28},
     {"key":"cta_target_url","label":"Button links to","kind":"text","max_length":400}]'::jsonb,
   true, array['home'], 'spec.hero'),

  ('intro', 2, true, 'Introduction',
   'One paragraph in the practitioner''s own voice, placed directly under the hero.',
   '[{"key":"body","label":"Paragraph","kind":"longtext","max_length":600}]'::jsonb,
   true, array['home','about'], 'spec.about_excerpt'),

  ('specialties', 3, true, 'What I work with',
   'A short list of the areas the practice works in. Plain labels, not diagnoses aimed at the reader.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"items","label":"Areas","kind":"list","max_length":80}]'::jsonb,
   true, array['home','services'], 'fields'),

  ('who_i_work_with', 4, true, 'Who I work with',
   'Who the practice serves, written as lived situations rather than diagnostic labels.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"items","label":"Descriptions","kind":"list","max_length":120}]'::jsonb,
   true, array['home','about'], 'fields'),

  ('approach', 5, true, 'How I work',
   'What a session is actually like, so a visitor knows before they have to ask.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"body","label":"Paragraph","kind":"longtext","max_length":800}]'::jsonb,
   false, array['home','about','services'], 'fields'),

  ('services', 6, true, 'Services',
   'What the practice offers: individual work, couples work, consultation.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"body","label":"Introduction","kind":"longtext","max_length":800},
     {"key":"items","label":"Services","kind":"list","max_length":120}]'::jsonb,
   false, array['home','services'], 'fields'),

  ('fees', 7, true, 'Fees',
   'Session fee, sliding scale and insurance, stated plainly so the first call is not about the number.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"body","label":"Introduction","kind":"longtext","max_length":800},
     {"key":"items","label":"Lines","kind":"list","max_length":120}]'::jsonb,
   false, array['services','contact'], 'fields'),

  ('faq', 8, true, 'Common questions',
   'A handful of questions and answers, each written as one line of question and one of answer.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"items","label":"Questions and answers","kind":"list","max_length":300}]'::jsonb,
   false, array['home','services','contact'], 'fields'),

  ('credentials', 9, true, 'Training and licensure',
   'Licence, degrees and completed training. Facts only, in the order the practitioner lists them.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"items","label":"Credentials","kind":"list","max_length":120}]'::jsonb,
   false, array['about'], 'fields'),

  ('contact', 10, true, 'Contact',
   'How to get in touch, ending in the call to action. No form that collects health information.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"body","label":"Paragraph","kind":"longtext","max_length":800}]'::jsonb,
   true, array['home','about','services','contact'], 'fields'),

  ('footer', 11, true, 'Footer',
   'Practice name, licence and location, and nothing that needs to be read twice.',
   '[{"key":"body","label":"Footer note","kind":"longtext","max_length":300}]'::jsonb,
   true, array['home','about','services','contact'], 'fields')

on conflict (id) do update set
  sort_order      = excluded.sort_order,
  active          = excluded.active,
  label           = excluded.label,
  description     = excluded.description,
  fields          = excluded.fields,
  default_enabled = excluded.default_enabled,
  allowed_pages   = excluded.allowed_pages,
  source          = excluded.source;

-- ---- builder_targets -------------------------------------------------------
-- The panel names are where each product actually keeps the setting, named as
-- that product names it. They are the difference between a sheet a therapist
-- can follow and a sheet she has to decode.
insert into public.builder_targets
  (id, sort_order, active, label, output_kind, docs_url,
   template_hint, color_panel, font_panel, section_panel) values

  ('lovable',     1, true, 'Lovable',     'prompt', 'https://docs.lovable.dev/',
   null, null, null, null),
  ('framer',      2, true, 'Framer',      'prompt', 'https://www.framer.com/help/',
   null, null, null, null),
  ('v0',          3, true, 'v0',          'prompt', 'https://v0.app/docs',
   null, null, null, null),
  ('generic',     4, true, 'Another builder', 'prompt', null,
   null, null, null, null),

  ('squarespace', 5, true, 'Squarespace', 'setup_sheet', 'https://support.squarespace.com/',
   'Start from a one-page portfolio or personal template, then delete the sections you do not need.',
   'Site Styles › Colors',
   'Site Styles › Fonts',
   'Pages › Edit › Add Section'),
  ('wix',         6, true, 'Wix',         'setup_sheet', 'https://support.wix.com/',
   'Start from a Health & Wellness template and remove the booking widgets you will not use.',
   'Site Design › Color Palette',
   'Site Design › Text Themes',
   'Add Elements › Section'),
  ('webflow',     7, true, 'Webflow',     'setup_sheet', 'https://help.webflow.com/',
   'Start from a blank site rather than a template: the structure below is faster to build than to unpick.',
   'Style Manager › Variables › Colors',
   'Style Manager › Typography',
   'Navigator › Sections')

on conflict (id) do update set
  sort_order    = excluded.sort_order,
  active        = excluded.active,
  label         = excluded.label,
  output_kind   = excluded.output_kind,
  docs_url      = excluded.docs_url,
  template_hint = excluded.template_hint,
  color_panel   = excluded.color_panel,
  font_panel    = excluded.font_panel,
  section_panel = excluded.section_panel;

-- <<< SITE SPEC CATALOG DATA <<<


-- ============================================================================
-- 6. `site_catalog()` — the two new blocks of GET /catalog, in one round trip
-- ============================================================================
-- The eleven existing catalogs are read as plain tables and the frontend
-- assembles `/catalog` from them. These two are not shaped like the others:
-- the product spec fixes the exact key names of the payload (`type`, not
-- `id`), and section `fields` is a nested document. A function returning the
-- payload verbatim means the contract is testable in this repo rather than
-- restated in the frontend and drifting from it.
--
-- STABLE and SECURITY INVOKER: it reads two RLS-protected catalogs, so an
-- unauthenticated caller gets empty arrays rather than product content.
--
-- `active` is NOT filtered, for the reason the catalog migration gives: a spec
-- that uses a since-retired section type must still resolve it, or the output
-- would silently lose a section. The frontend filters `active` when it renders
-- the picker.

create or replace function public.site_catalog()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'section_types', coalesce((
      select jsonb_agg(jsonb_build_object(
               'type',            st.id,
               'label',           st.label,
               'description',     st.description,
               'fields',          st.fields,
               'default_enabled', st.default_enabled,
               'allowed_pages',   to_jsonb(st.allowed_pages),
               'source',          st.source,
               'active',          st.active)
             order by st.sort_order)
        from public.section_types st), '[]'::jsonb),
    'builder_targets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',             bt.id,
               'label',          bt.label,
               'accepts_prompt', bt.accepts_prompt,
               'output_kind',    bt.output_kind,
               'docs_url',       bt.docs_url,
               'active',         bt.active)
             order by bt.sort_order)
        from public.builder_targets bt), '[]'::jsonb)
  )
$$;

comment on function public.site_catalog() is
  'The section_types and builder_targets blocks of GET /catalog, in the exact shape the product spec fixes. SECURITY INVOKER, so an unauthenticated caller gets empty arrays.';

grant execute on function public.site_catalog()                    to authenticated, service_role;
grant execute on function public.section_type_fields_valid(jsonb)  to authenticated, service_role;


-- ============================================================================
-- 7. Guard rails
-- ============================================================================
do $$
declare
  n int;
  t text;
begin
  foreach t in array array['section_types', 'builder_targets'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'site_spec_catalog: RLS is off on %. Migration aborted.', t;
    end if;
    select count(*) into n from pg_policies where schemaname = 'public' and tablename = t;
    if n <> 1 then
      raise exception
        'site_spec_catalog: % has % policies, expected exactly 1 (select-only).', t, n;
    end if;
    if not exists (select 1 from pg_policies
                    where schemaname='public' and tablename=t and cmd='SELECT') then
      raise exception 'site_spec_catalog: the single policy on % is not a SELECT policy.', t;
    end if;
  end loop;

  -- ⚠ THE TWO LISTS THAT MUST NOT DRIFT. The previous migration writes the
  -- eleven section types and the seven targets into CHECK constraints, because
  -- no foreign key reaches inside a jsonb document and none reaches a `text`
  -- column's CHECK either. Two hand-maintained lists drift, and the half that
  -- drifts is always the one nobody is looking at. This is the assertion that
  -- makes them one list in practice.
  if exists (
    select 1 from public.section_types st
     where not (st.id = any (public.site_spec_section_types()))
    union all
    select 1 from unnest(public.site_spec_section_types()) as k(id)
     where not exists (select 1 from public.section_types st where st.id = k.id)
  ) then
    raise exception
      'site_spec_catalog: section_types and the site_spec_section_types() CHECK list disagree.';
  end if;

  select count(*) into n from public.section_types;
  if n <> 11 then raise exception 'site_spec_catalog: % section_types, expected 11.', n; end if;

  select count(*) into n from public.builder_targets;
  if n <> 7 then raise exception 'site_spec_catalog: % builder_targets, expected 7.', n; end if;

  -- A target the site spec cannot store, or a stored target with no catalog
  -- row, would make `site_spec_output` dispatch on nothing.
  if exists (
    select 1 from public.builder_targets bt
     where not (bt.id = any (array['lovable','framer','v0','squarespace','wix','webflow','generic']))
  ) then
    raise exception
      'site_spec_catalog: a builder_targets row is not accepted by site_specs_target_check.';
  end if;

  -- The fork itself. Getting this wrong is the bug this whole feature exists
  -- to fix, so it is asserted rather than trusted.
  select count(*) into n from public.builder_targets
   where accepts_prompt and id = any (array['squarespace', 'wix', 'webflow']);
  if n > 0 then
    raise exception
      'site_spec_catalog: % of Squarespace/Wix/Webflow are marked accepts_prompt. None of them has a prompt input.', n;
  end if;
  select count(*) into n from public.builder_targets
   where not accepts_prompt and id = any (array['lovable', 'framer', 'v0', 'generic']);
  if n > 0 then
    raise exception
      'site_spec_catalog: % prompt-accepting builders are marked otherwise.', n;
  end if;

  -- Every section type the default page structure uses must exist, or a
  -- freshly seeded spec would reference a block the editor cannot render.
  if exists (
    select 1
      from jsonb_array_elements(public.site_spec_default_pages(null, null)) pg
      cross join lateral jsonb_array_elements(pg.value->'sections') s
     where not exists (select 1 from public.section_types st where st.id = s.value->>'type')
  ) then
    raise exception 'site_spec_catalog: the default page structure uses an unknown section type.';
  end if;

  -- and must be allowed on the page it was seeded onto
  if exists (
    select 1
      from jsonb_array_elements(public.site_spec_default_pages(null, null)) pg
      cross join lateral jsonb_array_elements(pg.value->'sections') s
      join public.section_types st on st.id = s.value->>'type'
     where not (pg.value->>'key' = any (st.allowed_pages))
  ) then
    raise exception
      'site_spec_catalog: the default page structure seeds a section onto a page its type does not allow.';
  end if;

  -- The payload shape the frontend reads is fixed by the product spec.
  if (public.site_catalog()->'section_types'->0->>'type') is null then
    raise exception 'site_spec_catalog: site_catalog() section_types entries have no `type` key.';
  end if;
  if (public.site_catalog()->'builder_targets'->0->'accepts_prompt') is null then
    raise exception 'site_spec_catalog: site_catalog() builder_targets entries have no `accepts_prompt` key.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Run the down script of `20260829100000_site_spec.sql` first if that is also
-- being reverted: `site_spec_default_target` below is restored to its earlier
-- body, which that script then drops.
--
--   drop function if exists public.site_catalog();
--   create or replace function public.site_spec_default_target(p_brand_kit_id uuid)
--   returns text language sql stable security definer set search_path = '' as $fn$
--     select coalesce(
--       (select bk.site_prompt_target from public.brand_kits bk where bk.id = p_brand_kit_id),
--       'generic')
--   $fn$;
--   drop index if exists public.project_briefs_builder_target_id_idx;
--   alter table public.project_briefs
--     drop constraint if exists project_briefs_builder_target_id_fkey,
--     drop column if exists builder_target_id;
--   drop table if exists public.builder_targets;
--   drop table if exists public.section_types;
--   drop function if exists public.section_type_fields_valid(jsonb);
