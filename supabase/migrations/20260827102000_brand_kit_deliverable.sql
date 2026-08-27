-- ============================================================================
-- Eklio — brand_kits: what the finished screens actually render
-- ============================================================================
-- Adds the deliverable itself to `brand_kits`: the three creative directions,
-- the voice guide, the four social templates, the ready-to-paste site prompt,
-- and the Ethics Guard verdict.
--
-- STRUCTURE HERE, RENDERING LIMITS NEXT DOOR
-- ------------------------------------------
-- This migration validates SHAPE: how many entries, which keys, which values
-- are legal. The next migration
-- (`20260827103000_rendering_constraints.sql`) validates LENGTH: what fits in
-- the fixed grid. Two constraints per column, each with one job, so a rejected
-- write says which rule it broke — "not 3 directions" and "rationale too long"
-- are different bugs in the generator and deserve different messages.
--
-- WHY jsonb AND NOT MORE TABLES
-- -----------------------------
-- A direction is read whole, written whole, and never queried across kits. The
-- repo already made this call for `brand_kits.content` and
-- `monthly_presence_content`. What jsonb costs is integrity, so every guarantee
-- that would have come free from a table is written below as a CHECK.
--
-- ⚠ THIS DOES NOT REPLACE THE `directions` TABLE, and the overlap is real. The
-- reference schema has a `directions` table (one row per proposal, French
-- column names) that the pre-existing flow writes. `brand_kits.directions` is
-- the shape the approved screens render and the one §4's constraints reach.
-- Both now exist. The `directions` table is not dropped here: `brand_kits`
-- carries a NOT NULL `direction_id` FK into it, six rows exist on the US
-- project, and dropping a populated table to tidy a naming overlap is not a
-- migration, it is a data loss. What this migration does is make the new flow
-- possible — see the NOT NULL removal in section 2 — and the README records
-- the table as superseded.
-- ============================================================================


-- ============================================================================
-- 1. Shape validators
-- ============================================================================
-- IMMUTABLE, because a CHECK constraint may only call immutable functions.
-- Each returns true for NULL: these columns are empty until generation
-- succeeds, and a kit row exists before the generator has filled it.
--
-- ⚠ A CHECK that calls a function is not re-evaluated when the function is
-- replaced. Changing a rule below means a new migration that re-validates the
-- existing rows, not a `create or replace` on its own.

-- Every colour in the kit is a role name the brand kit screen prints
-- literally: PRIMARY, SECONDARY, LIGHT, DARK, PAPER. Same five keys as
-- `palette_families.preview_tokens`, so nothing in the stack maps names.
create or replace function public.brand_kit_palette_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select p is not null
     and jsonb_typeof(p) = 'object'
     and p->>'primary'   ~ '^#[0-9A-Fa-f]{6}$'
     and p->>'secondary' ~ '^#[0-9A-Fa-f]{6}$'
     and p->>'light'     ~ '^#[0-9A-Fa-f]{6}$'
     and p->>'dark'      ~ '^#[0-9A-Fa-f]{6}$'
     and p->>'paper'     ~ '^#[0-9A-Fa-f]{6}$'
$$;

create or replace function public.brand_kit_hero_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select p is not null
     and jsonb_typeof(p) = 'object'
     and jsonb_typeof(p->'overline')  = 'string'
     and jsonb_typeof(p->'headline')  = 'string'
     and jsonb_typeof(p->'subhead')   = 'string'
     and jsonb_typeof(p->'cta_label') = 'string'
$$;

-- Exactly three directions, with distinct ids. The reveal is a three-column
-- grid: two directions leave a hole, four wrap onto a second row.
create or replace function public.brand_kit_directions_shape_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) <> 3 then false
    else
      not exists (
        select 1 from jsonb_array_elements(p) as d
        where jsonb_typeof(d.value) <> 'object'
           or jsonb_typeof(d.value->'id')            is distinct from 'string'
           or jsonb_typeof(d.value->'name')          is distinct from 'string'
           or jsonb_typeof(d.value->'rationale')     is distinct from 'string'
           or jsonb_typeof(d.value->'about_excerpt') is distinct from 'string'
           or not public.brand_kit_palette_valid(d.value->'palette')
           or not public.brand_kit_hero_valid(d.value->'hero')
           or jsonb_typeof(d.value->'typography') is distinct from 'object'
           or jsonb_typeof(d.value->'typography'->'heading_font')     is distinct from 'string'
           or jsonb_typeof(d.value->'typography'->'body_font')        is distinct from 'string'
           or jsonb_typeof(d.value->'typography'->'google_fonts_url') is distinct from 'string'
           or jsonb_typeof(d.value->'tone_keywords') is distinct from 'array'
           or jsonb_array_length(d.value->'tone_keywords') <> 3
      )
      and (select count(distinct d.value->>'id') from jsonb_array_elements(p) d) = 3
  end
$$;

-- Screen 6 renders exactly three lines per column. Not "up to three".
create or replace function public.brand_kit_voice_guide_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'object' then false
    when jsonb_typeof(p->'sounds_like') is distinct from 'array' then false
    when jsonb_typeof(p->'never_write') is distinct from 'array' then false
    when jsonb_array_length(p->'sounds_like') <> 3 then false
    when jsonb_array_length(p->'never_write') <> 3 then false
    else not exists (
      select 1 from (
        select jsonb_array_elements(p->'sounds_like') as v
        union all
        select jsonb_array_elements(p->'never_write')
      ) as l
      where jsonb_typeof(l.v) <> 'string'
    )
  end
$$;

-- Four templates, in the order Screen 6 lays them out: a statement post on
-- primary, a question post on light, a notes post on secondary, a signature
-- story on light. The ORDER is enforced, not just the set — the frontend
-- renders the array as it comes, so a shuffled array is a shuffled screen.
create or replace function public.brand_kit_social_templates_shape_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) <> 4 then false
    when (p->0->>'type', p->0->>'layout') is distinct from ('post',  'statement') then false
    when (p->1->>'type', p->1->>'layout') is distinct from ('post',  'question')  then false
    when (p->2->>'type', p->2->>'layout') is distinct from ('post',  'notes')     then false
    when (p->3->>'type', p->3->>'layout') is distinct from ('story', 'signature') then false
    else not exists (
      select 1 from jsonb_array_elements(p) as t
      where jsonb_typeof(t.value) <> 'object'
         or jsonb_typeof(t.value->'id')       is distinct from 'string'
         or jsonb_typeof(t.value->'headline') is distinct from 'string'
         -- body is nullable by contract: the statement and signature cards
         -- carry a headline only. Absent, JSON null, or a string; never a
         -- number or an object.
         or (jsonb_typeof(t.value->'body') is not null
             and jsonb_typeof(t.value->'body') not in ('string', 'null'))
         -- the five palette role names, again identical to the ones printed
         or (t.value->>'palette_role') is null
         or (t.value->>'palette_role') not in ('primary','secondary','light','dark','paper')
         -- a pairing has exactly two roles, so a template can only use one
         or (t.value->>'typography_role') is null
         or (t.value->>'typography_role') not in ('heading','body')
    )
  end
$$;

-- Written by the frontend's Ethics Guard after it has read the copy. This repo
-- validates the SHAPE of the verdict and stores it; it does not and must not
-- implement the checking, which needs an LLM call.
create or replace function public.brand_kit_ethics_check_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'object' then false
    when jsonb_typeof(p->'passed')     is distinct from 'boolean' then false
    when jsonb_typeof(p->'flagged')    is distinct from 'array'   then false
    when jsonb_typeof(p->'checked_at') is distinct from 'string'  then false
    else not exists (
      select 1 from jsonb_array_elements(p->'flagged') as f
      where jsonb_typeof(f.value) <> 'object'
         or jsonb_typeof(f.value->'field')   is distinct from 'string'
         or jsonb_typeof(f.value->'excerpt') is distinct from 'string'
         or jsonb_typeof(f.value->'rule_id') is distinct from 'string'
    )
  end
$$;

-- `selected_direction_id` must name a direction that is actually in the array.
-- This is the one referential guarantee jsonb took away and the only one worth
-- buying back: a kit pointing at a direction it does not contain renders a
-- blank brand kit screen.
create or replace function public.brand_kit_selection_valid(p_directions jsonb, p_selected text)
returns boolean language sql immutable set search_path = '' as $$
  select p_selected is null
      or (p_directions is not null
          and exists (
            select 1 from jsonb_array_elements(p_directions) d
             where d.value->>'id' = p_selected))
$$;


-- ============================================================================
-- 2. Columns
-- ============================================================================

alter table public.brand_kits
  add column if not exists directions            jsonb,
  add column if not exists selected_direction_id text,
  add column if not exists voice_guide           jsonb,
  add column if not exists social_templates      jsonb,
  add column if not exists site_prompt           text,
  add column if not exists site_prompt_target    text,
  add column if not exists ethics_check          jsonb,
  add column if not exists practitioner_line     text;

-- ⚠ REQUIRED FOR THE NEW FLOW TO EXIST AT ALL. `direction_id` is a NOT NULL FK
-- into the legacy `directions` table. A kit produced by the flow these screens
-- describe has no row there — its three proposals live in the `directions`
-- jsonb above and the chosen one in `selected_direction_id`. Left NOT NULL,
-- every new kit would have to fabricate a legacy row to satisfy a column
-- nothing reads. The FK and its ON DELETE NO ACTION are untouched: kits that
-- already carry a `direction_id` keep their integrity guarantee.
alter table public.brand_kits alter column direction_id drop not null;

comment on column public.brand_kits.direction_id is
  'Legacy FK into the directions table, kept for kits produced by the pre-existing flow. Nullable since the brand-kit migration: the current flow stores its three proposals in brand_kits.directions and the chosen one in selected_direction_id.';


-- ============================================================================
-- 3. Shape constraints
-- ============================================================================

alter table public.brand_kits drop constraint if exists brand_kits_directions_shape_check;
alter table public.brand_kits
  add constraint brand_kits_directions_shape_check
  check (public.brand_kit_directions_shape_valid(directions));

alter table public.brand_kits drop constraint if exists brand_kits_voice_guide_check;
alter table public.brand_kits
  add constraint brand_kits_voice_guide_check
  check (public.brand_kit_voice_guide_valid(voice_guide));

alter table public.brand_kits drop constraint if exists brand_kits_social_templates_shape_check;
alter table public.brand_kits
  add constraint brand_kits_social_templates_shape_check
  check (public.brand_kit_social_templates_shape_valid(social_templates));

alter table public.brand_kits drop constraint if exists brand_kits_ethics_check_shape_check;
alter table public.brand_kits
  add constraint brand_kits_ethics_check_shape_check
  check (public.brand_kit_ethics_check_valid(ethics_check));

alter table public.brand_kits drop constraint if exists brand_kits_selected_direction_id_check;
alter table public.brand_kits
  add constraint brand_kits_selected_direction_id_check
  check (public.brand_kit_selection_valid(directions, selected_direction_id));

-- The spec called this an enum. It is `text` + CHECK, which is the convention
-- this schema already uses for `projects.status`, `brand_kits.tier`,
-- `purchases.status` and `subscriptions.status` — there is not one Postgres
-- enum type in the database. A CHECK is amended by a migration; an enum needs
-- ALTER TYPE, which until recently could not run inside a transaction and
-- still cannot drop a value.
alter table public.brand_kits drop constraint if exists brand_kits_site_prompt_target_check;
alter table public.brand_kits
  add constraint brand_kits_site_prompt_target_check check (
    site_prompt_target is null
    or site_prompt_target = any (array['squarespace'::text, 'lovable'::text,
                                       'framer'::text, 'webflow'::text])
  );

comment on column public.brand_kits.directions is
  'The three creative directions the reveal renders. Exactly 3, distinct ids, palette role names identical to the labels printed on screen.';
comment on column public.brand_kits.ethics_check is
  'Verdict written by the Ethics Guard in eklio-frontend, stored so the BOARD-SAFE COPY badge has a source of truth. This repo validates its shape only; the checking itself needs an LLM call and is NOT implemented here.';
comment on column public.brand_kits.social_templates is
  'Exactly 4 templates in render order: statement post on primary, question post on light, notes post on secondary, signature story on light.';
comment on column public.brand_kits.practitioner_line is
  'Name and credential rendered on the signature story, e.g. "Nora Whitfield, LCSW".';


-- ============================================================================
-- DOWN
-- ============================================================================
--   alter table public.brand_kits
--     drop constraint if exists brand_kits_site_prompt_target_check,
--     drop constraint if exists brand_kits_selected_direction_id_check,
--     drop constraint if exists brand_kits_ethics_check_shape_check,
--     drop constraint if exists brand_kits_social_templates_shape_check,
--     drop constraint if exists brand_kits_voice_guide_check,
--     drop constraint if exists brand_kits_directions_shape_check;
--   alter table public.brand_kits
--     drop column if exists practitioner_line,
--     drop column if exists ethics_check,
--     drop column if exists site_prompt_target,
--     drop column if exists site_prompt,
--     drop column if exists social_templates,
--     drop column if exists voice_guide,
--     drop column if exists selected_direction_id,
--     drop column if exists directions;
--   -- only if every row has a direction_id again:
--   alter table public.brand_kits alter column direction_id set not null;
--   drop function if exists public.brand_kit_selection_valid(jsonb, text);
--   drop function if exists public.brand_kit_ethics_check_valid(jsonb);
--   drop function if exists public.brand_kit_social_templates_shape_valid(jsonb);
--   drop function if exists public.brand_kit_voice_guide_valid(jsonb);
--   drop function if exists public.brand_kit_directions_shape_valid(jsonb);
--   drop function if exists public.brand_kit_hero_valid(jsonb);
--   drop function if exists public.brand_kit_palette_valid(jsonb);
