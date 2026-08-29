-- ============================================================================
-- Eklio — the editable site spec
-- ============================================================================
-- Until now the brand kit ended at `brand_kits.site_prompt`: one frozen block
-- of text, generated once, take it or leave it. This migration gives the
-- therapist the thing that text was made of — colours, typography, page and
-- section structure, copy — as a row she can edit.
--
-- TWO RULES SHAPE EVERY DECISION BELOW, AND NEITHER IS NEGOTIABLE
-- ---------------------------------------------------------------
-- 1. **Eklio never hosts and never builds the site.** There is no public page,
--    no publishing, no deployment, and this migration adds no policy readable
--    by `anon`. The mockup the frontend renders from `site_spec_preview_model`
--    is a design reference shown inside the authenticated app. That is also
--    why `share_slug` stays exactly as unresolved as the README leaves it: this
--    feature does not need it and does not open it.
-- 2. **The spec is the source of truth.** The builder output is DERIVED from
--    this row by a pure function, with no LLM call, and it is never parsed
--    back. There is no column here that holds edited output text, because
--    editing the output is not a supported operation.
--
-- WHAT THIS REPO DOES AND DOES NOT DELIVER HERE
-- ---------------------------------------------
-- The README's test applies unchanged: an LLM call, an HTTP request, a clock
-- or a runtime is `eklio-frontend`'s job. Everything the site spec needs is on
-- the other side of that line — it is deterministic SQL over one row and two
-- catalogs — so the whole feature lands here, and the frontend's HTTP surface
-- is a thin mapping onto the functions delivered across this lot. The endpoint
-- named in the product spec and the function that answers it are listed in the
-- README, section "Site spec".
--
-- WHY ONE ROW PER KIT AND NOT jsonb ON `brand_kits`
-- -------------------------------------------------
-- `brand_kits.directions` is jsonb because it is written whole by the
-- generator and read whole by the reveal. This is the opposite: it is written
-- one field at a time by a human typing, on an autosave path that must answer
-- in under 150 ms. That wants real columns, real CHECKs that name the field
-- they refused, and a primary key to update by — not a read-modify-write of a
-- document on every keystroke.
--
-- ⚠ NO REVISION TABLE, ON PURPOSE. Undo and redo are client-side. What this
-- table keeps is not history but a single high-water mark per area of the spec
-- (`change_marks`, §5), which is all the "changed since you copied" banner
-- needs and costs one jsonb object rather than a row per edit.
-- ============================================================================


-- ============================================================================
-- 1. Shape and length validators
-- ============================================================================
-- Same division of labour as `20260827102000_brand_kit_deliverable.sql` and
-- the rendering-constraints migration that follows it: one validator per rule,
-- so a rejected write names the rule it broke. "hero is not an object" and
-- "the headline is 94 characters" are different bugs and deserve different
-- messages.
--
-- IMMUTABLE, because a CHECK may only call immutable functions. Each returns
-- true for NULL where the column is nullable.
--
-- ⚠ A CHECK that calls a function is not re-evaluated when the function is
-- replaced. Changing a rule below means a new migration that re-validates the
-- rows, not a bare `create or replace`.

-- The eleven section types. Written out here rather than resolved against the
-- catalog for the reason the brief migration gives for its array columns:
-- Postgres 17 has no foreign key reaching inside a jsonb document, and a
-- constraint trigger reading a catalog on every autosave would put a table
-- lookup on the keystroke path. The catalog migration that follows carries a
-- guard rail asserting that its rows and this list are the same eleven values.
create or replace function public.site_spec_section_types()
returns text[] language sql immutable set search_path = '' as $$
  select array['hero', 'intro', 'specialties', 'who_i_work_with', 'approach',
               'services', 'fees', 'faq', 'credentials', 'contact', 'footer']
$$;

create or replace function public.site_spec_page_keys()
returns text[] language sql immutable set search_path = '' as $$
  select array['home', 'about', 'services', 'contact']
$$;

-- The hero is the one block of copy with its own column rather than living in
-- a section's `fields`: it is the only section every page structure must carry,
-- the reveal already produced it, and §1.2's four separate length limits read
-- better as four probes into one known shape than as four special cases inside
-- the generic section walker.
create or replace function public.site_spec_hero_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select p is not null
     and jsonb_typeof(p) = 'object'
     and jsonb_typeof(p->'overline')  = 'string'
     and jsonb_typeof(p->'headline')  = 'string'
     and jsonb_typeof(p->'subhead')   = 'string'
     and jsonb_typeof(p->'cta_label') = 'string'
     -- absent, JSON null or a string; never a number or an object. It is the
     -- therapist's own booking link and she may not have one yet.
     and (jsonb_typeof(p->'cta_target_url') is null
          or jsonb_typeof(p->'cta_target_url') in ('string', 'null'))
$$;

create or replace function public.site_spec_hero_lengths_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'object' then true  -- the shape check's job
    else coalesce(char_length(p->>'overline'),  0) <= 48
     and coalesce(char_length(p->>'headline'),  0) <= 90
     and coalesce(char_length(p->>'subhead'),   0) <= 220
     and coalesce(char_length(p->>'cta_label'), 0) <= 28
  end
$$;

-- ⚠ SECURITY, not tidiness. `cta_target_url` is printed verbatim into a text
-- block whose entire purpose is to be pasted into a website builder, some of
-- which will happily turn it into a live href. A `javascript:` or `data:` URL
-- reaching that output is a stored payload with a delivery mechanism attached.
-- Four schemes are what the product actually needs: a booking page, a mailto
-- or a phone number.
--
-- Eklio stores this link and prints it. It never fetches it, never proxies it
-- and never checks that it resolves — that would be an HTTP request, which is
-- not this repo's job and not this product's promise.
create or replace function public.site_spec_cta_target_url_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null or jsonb_typeof(p) <> 'object' then true
    when p->>'cta_target_url' is null then true
    when btrim(p->>'cta_target_url') = '' then true
    else btrim(p->>'cta_target_url') ~* '^(https?://|mailto:|tel:)\S'
     and char_length(p->>'cta_target_url') <= 400
  end
$$;

-- The seven fields the output prints in its footer and contact block.
--
-- ⚠ NEVER VALIDATED AGAINST ANY BOARD REGISTRY, and the omission is the
-- product decision, not an oversight. Eklio has no way to know whether a
-- licence number is real, and a product that implied it had checked would be
-- making a claim about a therapist's credentials on her behalf. The shape is
-- checked; the truth of it is hers.
create or replace function public.site_spec_practice_details_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then false
    when jsonb_typeof(p) <> 'object' then false
    else not exists (
      select 1 from unnest(array['practice_name', 'license_label', 'license_number',
                                 'city', 'state', 'email', 'phone']) as k(name)
       where jsonb_typeof(p -> k.name) is not null
         and jsonb_typeof(p -> k.name) not in ('string', 'null')
    )
    -- Two-letter USPS code, the same rule `project_briefs.state` already
    -- carries, so the two cannot disagree about what a state is.
    and (nullif(btrim(coalesce(p->>'state', '')), '') is null
         or btrim(p->>'state') ~ '^[A-Za-z]{2}$')
  end
$$;

-- Ordered pages, each with ordered sections. `enabled` is a flag rather than a
-- deletion: turning a page off and back on must give back the copy that was in
-- it, and a structure the user can empty is a structure she can lose.
create or replace function public.site_spec_pages_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then false
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) = 0 then false
    else
      not exists (
        select 1 from jsonb_array_elements(p) as pg
        where jsonb_typeof(pg.value) <> 'object'
           or not (pg.value->>'key' = any (public.site_spec_page_keys()))
           or jsonb_typeof(pg.value->'label')    is distinct from 'string'
           or jsonb_typeof(pg.value->'enabled')  is distinct from 'boolean'
           or jsonb_typeof(pg.value->'sections') is distinct from 'array'
           or exists (
             select 1 from jsonb_array_elements(pg.value->'sections') as s
             where jsonb_typeof(s.value) <> 'object'
                or jsonb_typeof(s.value->'key')  is distinct from 'string'
                or btrim(coalesce(s.value->>'key', '')) = ''
                or not (s.value->>'type' = any (public.site_spec_section_types()))
                or jsonb_typeof(s.value->'enabled') is distinct from 'boolean'
                or jsonb_typeof(s.value->'order')   is distinct from 'number'
                or (s.value->>'order')::numeric <> trunc((s.value->>'order')::numeric)
                or jsonb_typeof(s.value->'fields')  is distinct from 'object'
           )
           -- A section key is the handle the frontend edits by. Two sections
           -- sharing one inside a page make an edit ambiguous.
           or (select count(distinct s.value->>'key')
                 from jsonb_array_elements(pg.value->'sections') s)
              <> jsonb_array_length(pg.value->'sections')
      )
      -- and one page per key, for the same reason
      and (select count(distinct pg.value->>'key') from jsonb_array_elements(p) pg)
          = jsonb_array_length(p)
  end
$$;

-- §1.2's catch-all: no string anywhere in a section's fields may exceed 800
-- characters, whether it is a `text`, a `longtext` or an item of a `list`.
-- Walking the document is what makes the limit hold for section types added
-- later without another migration teaching this function their field names.
create or replace function public.site_spec_pages_lengths_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then true  -- the shape check's job
    else not exists (
      select 1
        from jsonb_array_elements(p) as pg
        cross join lateral jsonb_array_elements(pg.value->'sections') as s
        cross join lateral jsonb_each(s.value->'fields') as f
        cross join lateral (
          select f.value as v where jsonb_typeof(f.value) = 'string'
          union all
          select e.value from jsonb_array_elements(f.value) as e
           where jsonb_typeof(f.value) = 'array'
        ) as vals(v)
       where jsonb_typeof(vals.v) = 'string'
         and char_length(vals.v #>> '{}') > 800
    )
  end
$$;


-- ============================================================================
-- 2. The table
-- ============================================================================
-- `user_id` is denormalised, exactly as it is on `launch_checklist_items` and
-- for the same measured reason: this row is read on every keystroke of the
-- editor, and the two-join EXISTS the other policies use would run on each one.
-- The FK keeps it honest and the seeder is the only thing that writes it.
--
-- ⚠ THE COLOUR COLUMNS ARE `*_hex`, NOT `primary` / `secondary`. `primary` is a
-- reserved word in Postgres and would need quoting at every mention for the
-- rest of this repo's life; `palette_families` already names its columns
-- `primary_hex`, `secondary_hex`, `light_hex`. The role names the product spec
-- uses — `primary`, `secondary`, `accent`, `light_neutral`, `dark_neutral` —
-- are what `site_spec_preview_model()` and the builder output emit, so nothing
-- above the database ever sees the suffix.

create table if not exists public.site_specs (
  id           uuid primary key default gen_random_uuid(),
  -- One spec per kit. The UNIQUE is the whole cardinality guarantee: the seeder
  -- upserts on it, and it is what makes re-selecting a direction idempotent.
  brand_kit_id uuid not null unique references public.brand_kits (id) on delete cascade,
  user_id      uuid not null        references public.profiles  (id) on delete cascade,

  -- Colour tokens, five roles, `#RRGGBB`.
  primary_hex        text not null,
  secondary_hex      text not null,
  accent_hex         text not null,
  light_neutral_hex  text not null,
  dark_neutral_hex   text not null,

  -- Typography. `type_pairing_id` is nullable: a direction's fonts do not have
  -- to come from the catalog (the generator may pair two faces the catalog
  -- does not carry), and losing the pairing must not lose the fonts. The three
  -- font columns are what everything downstream reads; the id is a convenience
  -- for the editor's picker.
  type_pairing_id  text references public.type_pairings (id) on delete restrict,
  heading_font     text not null,
  body_font        text not null,
  google_fonts_url text not null,

  hero              jsonb not null,
  about_excerpt     text  not null default '',
  pages             jsonb not null,
  practice_details  jsonb not null default '{}'::jsonb,

  -- ⚠ APPENDED VERBATIM, PARSED NEVER. This is the escape hatch for everything
  -- the structured spec does not model. It is printed at the end of the builder
  -- output under its own heading and it does not reach the mockup, because
  -- reading it into the mockup would mean interpreting it, and interpreting it
  -- is the free-text round trip rule 2 exists to forbid.
  extra_instructions text,

  target text not null default 'generic',

  -- Bumped on every successful write. The editor's optimistic concurrency and
  -- the "changed since you copied" banner both read it.
  spec_version             int not null default 1,
  last_copied_spec_version int,

  -- ⚠ NOT A REVISION LOG. One entry per human-readable change label, holding
  -- the `spec_version` at which that label last became true. `site_spec_diff`
  -- returns the entries newer than `last_copied_spec_version`. Bounded by the
  -- number of labels the writer can emit, not by the number of edits.
  change_marks jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.site_specs is
  'The editable specification of a therapist''s website: one row per brand kit. Source of truth for the in-app mockup and for the derived builder output. Eklio does not host, build, publish or deploy the site.';
comment on column public.site_specs.extra_instructions is
  'Free text appended verbatim to the end of the derived output under its own heading. Never parsed, never reaches the mockup.';
comment on column public.site_specs.change_marks is
  'Human-readable change label -> spec_version at which it last changed. Feeds the "changed since you copied" banner. Not a revision history; undo/redo is client-side.';
comment on column public.site_specs.practice_details is
  'practice_name, license_label, license_number, city, state, email, phone. Printed in the output footer and contact block. NEVER validated against any licensing board registry.';
comment on column public.site_specs.hero is
  'overline, headline, subhead, cta_label, cta_target_url. cta_target_url is the practice''s own booking link; Eklio stores it and prints it, and never proxies or fetches it.';


-- ============================================================================
-- 3. Constraints
-- ============================================================================

-- ---- colours ---------------------------------------------------------------
-- Case-insensitive, like `brand_kit_palette_valid`, because these arrive from
-- a colour picker and not from the catalog. `site_spec_patch` uppercases on
-- write so that the derived output for one spec is byte-identical every time.
alter table public.site_specs drop constraint if exists site_specs_hex_check;
alter table public.site_specs
  add constraint site_specs_hex_check check (
    primary_hex       ~ '^#[0-9A-Fa-f]{6}$'
    and secondary_hex     ~ '^#[0-9A-Fa-f]{6}$'
    and accent_hex        ~ '^#[0-9A-Fa-f]{6}$'
    and light_neutral_hex ~ '^#[0-9A-Fa-f]{6}$'
    and dark_neutral_hex  ~ '^#[0-9A-Fa-f]{6}$'
  );

-- ⚠ THERE IS DELIBERATELY NO CONTRAST CONSTRAINT HERE, and there must not be
-- one. `site_spec_contrast()` reports every failing pair and offers a corrected
-- hex, and the fix-contrast call applies it. It is a warning with a button, not
-- a wall. A therapist who has paid for a kit and is refused a save because two
-- of her colours are at 4.3:1 has been handed a broken product; a therapist
-- told "this pair is hard to read, fix it" has been handed advice.

-- ---- typography ------------------------------------------------------------
alter table public.site_specs drop constraint if exists site_specs_fonts_check;
alter table public.site_specs
  add constraint site_specs_fonts_check check (
    btrim(heading_font) <> ''
    and btrim(body_font) <> ''
    and google_fonts_url like 'https://fonts.googleapis.com/css2?family=%'
  );

-- ---- hero: shape, then length, then link safety ----------------------------
alter table public.site_specs drop constraint if exists site_specs_hero_shape_check;
alter table public.site_specs
  add constraint site_specs_hero_shape_check check (public.site_spec_hero_valid(hero));

alter table public.site_specs drop constraint if exists site_specs_hero_lengths_check;
alter table public.site_specs
  add constraint site_specs_hero_lengths_check check (public.site_spec_hero_lengths_valid(hero));

alter table public.site_specs drop constraint if exists site_specs_hero_cta_target_url_check;
alter table public.site_specs
  add constraint site_specs_hero_cta_target_url_check
  check (public.site_spec_cta_target_url_valid(hero));

-- ---- copy lengths ----------------------------------------------------------
alter table public.site_specs drop constraint if exists site_specs_about_excerpt_check;
alter table public.site_specs
  add constraint site_specs_about_excerpt_check check (char_length(about_excerpt) <= 600);

alter table public.site_specs drop constraint if exists site_specs_extra_instructions_check;
alter table public.site_specs
  add constraint site_specs_extra_instructions_check check (
    extra_instructions is null or char_length(extra_instructions) <= 2000
  );

-- ---- structure: shape, then length -----------------------------------------
alter table public.site_specs drop constraint if exists site_specs_pages_shape_check;
alter table public.site_specs
  add constraint site_specs_pages_shape_check check (public.site_spec_pages_valid(pages));

alter table public.site_specs drop constraint if exists site_specs_pages_lengths_check;
alter table public.site_specs
  add constraint site_specs_pages_lengths_check check (public.site_spec_pages_lengths_valid(pages));

alter table public.site_specs drop constraint if exists site_specs_practice_details_check;
alter table public.site_specs
  add constraint site_specs_practice_details_check
  check (public.site_spec_practice_details_valid(practice_details));

-- ---- target ----------------------------------------------------------------
-- text + CHECK, not a Postgres enum, for the reason the brand-kit migration
-- spells out: this schema contains no enum type, and a CHECK is amended by a
-- migration where `ALTER TYPE` still cannot drop a value. The catalog migration
-- that follows asserts these seven and its rows are the same seven.
alter table public.site_specs drop constraint if exists site_specs_target_check;
alter table public.site_specs
  add constraint site_specs_target_check check (
    target = any (array['lovable'::text, 'framer'::text, 'v0'::text,
                        'squarespace'::text, 'wix'::text, 'webflow'::text,
                        'generic'::text])
  );

-- ---- versions --------------------------------------------------------------
alter table public.site_specs drop constraint if exists site_specs_spec_version_check;
alter table public.site_specs
  add constraint site_specs_spec_version_check check (spec_version >= 1);

-- A copy marker ahead of the version it marks would make the banner claim the
-- spec is clean when it is not.
alter table public.site_specs drop constraint if exists site_specs_last_copied_check;
alter table public.site_specs
  add constraint site_specs_last_copied_check check (
    last_copied_spec_version is null
    or (last_copied_spec_version >= 1 and last_copied_spec_version <= spec_version)
  );

alter table public.site_specs drop constraint if exists site_specs_change_marks_check;
alter table public.site_specs
  add constraint site_specs_change_marks_check check (
    jsonb_typeof(change_marks) = 'object'
  );


-- ============================================================================
-- 4. Indexes and the updated_at trigger
-- ============================================================================
-- `brand_kit_id` is already indexed by its UNIQUE constraint, which is the only
-- lookup the hot path performs: every endpoint in this feature reaches the row
-- by kit id. `user_id` is indexed for the policy scan and for the cascade.

create index if not exists site_specs_user_id_idx on public.site_specs (user_id);

drop trigger if exists set_site_specs_updated_at on public.site_specs;
create trigger set_site_specs_updated_at
  before update on public.site_specs
  for each row execute function public.set_updated_at();


-- ============================================================================
-- 5. RLS — owner-scoped, and nothing else
-- ============================================================================
-- ⚠ RULE 1 IS ENFORCED HERE OR NOWHERE. There is no `anon` policy on this
-- table and there must never be one: the mockup is a design reference inside
-- the authenticated app, not a published page. The unresolved `share_slug`
-- question on `brand_kits` is not reopened by this feature.
--
-- SELECT and UPDATE are owner-scoped; INSERT and DELETE are refused outright.
-- A spec is created by the seeder and dies with its kit — it is not a document
-- the user creates or throws away, and letting a client INSERT would let it
-- choose its own `user_id`. The refusals are written rather than left implicit,
-- the convention `launch_checklist_items` and every billing table follow.
--
-- 404 AND NOT 403 falls out of this rather than being implemented: another
-- user's spec is not visible, so every function below sees zero rows and
-- returns `not_found`. There is no code path that knows the row exists and
-- declines to show it, which is the only kind that can leak its existence.

alter table public.site_specs enable row level security;

drop policy if exists "site_specs_select_own"    on public.site_specs;
drop policy if exists "site_specs_update_own"    on public.site_specs;
drop policy if exists "site_specs_insert_denied" on public.site_specs;
drop policy if exists "site_specs_delete_denied" on public.site_specs;

create policy "site_specs_select_own"
  on public.site_specs for select
  using (user_id = (select auth.uid()));

create policy "site_specs_update_own"
  on public.site_specs for update
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "site_specs_insert_denied"
  on public.site_specs for insert with check (false);

create policy "site_specs_delete_denied"
  on public.site_specs for delete using (false);

-- RLS says which rows, column privileges say which columns. `user_id`,
-- `brand_kit_id`, `spec_version` and `change_marks` sit in a row the user owns
-- but are not hers to write: re-pointing `brand_kit_id` would move the spec to
-- another kit, and a client-chosen `spec_version` would let a stale editor
-- silently win. Every write goes through the patch function, which runs the
-- update itself; direct UPDATE is left available for the columns where a
-- client-side write is merely redundant, not dangerous.
revoke update on table public.site_specs from anon, authenticated;
grant  update (primary_hex, secondary_hex, accent_hex, light_neutral_hex,
               dark_neutral_hex, type_pairing_id, heading_font, body_font,
               google_fonts_url, hero, about_excerpt, pages, practice_details,
               extra_instructions, target)
  on table public.site_specs to authenticated;


-- ============================================================================
-- 6. `brand_kits.site_prompt_target` — three more builders
-- ============================================================================
-- The existing CHECK allows squarespace, lovable, framer and webflow. The site
-- spec adds v0, wix and generic, and `brand_kits.site_prompt` is about to
-- become a cached copy of the derived output for whichever target the spec
-- names — so a spec targeting v0 could not cache, and the write would fail at
-- the moment the user switched builder.
--
-- Widening a CHECK cannot invalidate a stored row: every value previously legal
-- still is. Backward compatible by construction.
alter table public.brand_kits drop constraint if exists brand_kits_site_prompt_target_check;
alter table public.brand_kits
  add constraint brand_kits_site_prompt_target_check check (
    site_prompt_target is null
    or site_prompt_target = any (array['lovable'::text, 'framer'::text, 'v0'::text,
                                       'squarespace'::text, 'wix'::text, 'webflow'::text,
                                       'generic'::text])
  );

comment on column public.brand_kits.site_prompt is
  'Cached copy of the derived builder output for site_specs.target, refreshed on every successful spec write. Kept so existing consumers keep working; the site spec is the source of truth and this text is never parsed back.';


-- ============================================================================
-- 7. Where the default target comes from
-- ============================================================================
-- Its own function because it grows a second source in the very next
-- migration: `project_briefs.builder_target_id` cannot carry a foreign key
-- until `builder_targets` exists, and the catalog is delivered after this file.
-- Isolating the resolution means that migration replaces four lines rather than
-- the whole seeder.
create or replace function public.site_spec_default_target(p_brand_kit_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select bk.site_prompt_target from public.brand_kits bk where bk.id = p_brand_kit_id),
    'generic')
$$;


-- ============================================================================
-- 8. Seeding, from the chosen direction
-- ============================================================================
-- ⚠ IDEMPOTENT, AND THAT IS THE WHOLE POINT. Choosing a direction a second
-- time must never silently overwrite the edits made after the first choice.
-- `on conflict do nothing` is the guarantee; `site_spec_reset` (delivered with
-- the other actions) is the deliberate, asked-for way to go back to the
-- direction's defaults.
--
-- SECURITY DEFINER for the reason `seed_launch_checklist` is: it inserts into a
-- table whose INSERT is refused to every client. It takes only a brand kit id
-- and resolves the owner through the FK chain, so there is no argument through
-- which a foreign id could be smuggled in.
--
-- WHAT MAPS ONTO WHAT
-- -------------------
-- The direction carries five palette roles (PRIMARY, SECONDARY, LIGHT, DARK,
-- PAPER); the site spec needs five different ones. Four line up. The fifth,
-- `accent`, has no source in the direction — so it starts as a copy of the
-- secondary. That is not a placeholder to be cleaned up later: it is the same
-- reasoning `brief_preview`'s fallbacks follow, which is that the first render
-- has to be a complete, legible site before the therapist has changed
-- anything. An accent equal to the secondary renders correctly and reports an
-- honest contrast ratio; the editor is where it becomes its own colour.

create or replace function public.site_spec_default_pages(
  p_specialties text[],
  p_personas    text[]
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Home carries the six sections the product spec names, in render order.
  -- About, Services and Contact are enabled with the sections that belong to
  -- them, because a nav pointing at three empty pages is worse than a nav
  -- pointing at three pages with a heading and a purpose.
  --
  -- Section `key` equals section `type` for every seeded section. They diverge
  -- only when the user adds a second section of the same type to one page,
  -- which is exactly what the separate `key` exists to make possible.
  select jsonb_build_array(
    jsonb_build_object(
      'key', 'home', 'label', 'Home', 'enabled', true,
      'sections', jsonb_build_array(
        jsonb_build_object('key','hero','type','hero','enabled',true,'order',1,
                           'fields', '{}'::jsonb),
        jsonb_build_object('key','intro','type','intro','enabled',true,'order',2,
                           'fields', '{}'::jsonb),
        jsonb_build_object('key','specialties','type','specialties','enabled',true,'order',3,
                           'fields', jsonb_build_object(
                             'heading', 'What I work with',
                             'items', to_jsonb(coalesce(p_specialties, array[]::text[])))),
        jsonb_build_object('key','who_i_work_with','type','who_i_work_with','enabled',true,'order',4,
                           'fields', jsonb_build_object(
                             'heading', 'Who I work with',
                             'items', to_jsonb(coalesce(p_personas, array[]::text[])))),
        jsonb_build_object('key','contact','type','contact','enabled',true,'order',5,
                           'fields', jsonb_build_object('heading', 'Get in touch', 'body', '')),
        jsonb_build_object('key','footer','type','footer','enabled',true,'order',6,
                           'fields', jsonb_build_object('body', '')))),
    jsonb_build_object(
      'key', 'about', 'label', 'About', 'enabled', true,
      'sections', jsonb_build_array(
        jsonb_build_object('key','intro','type','intro','enabled',true,'order',1,
                           'fields', '{}'::jsonb),
        jsonb_build_object('key','approach','type','approach','enabled',true,'order',2,
                           'fields', jsonb_build_object('heading', 'How I work', 'body', '')),
        jsonb_build_object('key','credentials','type','credentials','enabled',true,'order',3,
                           'fields', jsonb_build_object('heading', 'Training and licensure',
                                                        'items', '[]'::jsonb)),
        jsonb_build_object('key','footer','type','footer','enabled',true,'order',4,
                           'fields', jsonb_build_object('body', '')))),
    jsonb_build_object(
      'key', 'services', 'label', 'Services', 'enabled', true,
      'sections', jsonb_build_array(
        jsonb_build_object('key','services','type','services','enabled',true,'order',1,
                           'fields', jsonb_build_object('heading', 'Services',
                                                        'body', '', 'items', '[]'::jsonb)),
        jsonb_build_object('key','fees','type','fees','enabled',true,'order',2,
                           'fields', jsonb_build_object('heading', 'Fees',
                                                        'body', '', 'items', '[]'::jsonb)),
        jsonb_build_object('key','faq','type','faq','enabled',false,'order',3,
                           'fields', jsonb_build_object('heading', 'Common questions',
                                                        'items', '[]'::jsonb)),
        jsonb_build_object('key','footer','type','footer','enabled',true,'order',4,
                           'fields', jsonb_build_object('body', '')))),
    jsonb_build_object(
      'key', 'contact', 'label', 'Contact', 'enabled', true,
      'sections', jsonb_build_array(
        jsonb_build_object('key','contact','type','contact','enabled',true,'order',1,
                           'fields', jsonb_build_object('heading', 'Get in touch', 'body', '')),
        jsonb_build_object('key','footer','type','footer','enabled',true,'order',2,
                           'fields', jsonb_build_object('body', ''))))
  )
$$;

comment on function public.site_spec_default_pages(text[], text[]) is
  'The default four-page structure a new site spec starts from. Pure: the two arrays are the specialty and persona labels the brief already resolved.';

create or replace function public.seed_site_spec(p_brand_kit_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id  uuid;
  v_project  uuid;
  v_dir      jsonb;
  v_brief    record;
  v_specs    text[];
  v_persona  text[];
  v_count    int;
begin
  select p.user_id, p.id into v_user_id, v_project
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null then
    raise exception
      'seed_site_spec: brand kit % does not exist, or its project has no owner.', p_brand_kit_id;
  end if;

  -- The chosen direction, or nothing to seed from. A kit whose direction has
  -- not been picked yet has no colours and no hero, and inventing them would
  -- put a site in front of the therapist that no one designed.
  select d.value into v_dir
    from public.brand_kits bk
    cross join lateral jsonb_array_elements(bk.directions) as d
   where bk.id = p_brand_kit_id
     and bk.selected_direction_id is not null
     and d.value->>'id' = bk.selected_direction_id;

  if v_dir is null then
    return 0;
  end if;

  select * into v_brief from public.project_briefs pb where pb.project_id = v_project;

  select array_agg(s.label order by e.ord)
    into v_specs
    from unnest(coalesce(v_brief.specialty_ids, array[]::text[])) with ordinality as e(id, ord)
    join public.specialties s on s.id = e.id;

  select array_agg(c.label order by e.ord)
    into v_persona
    from unnest(coalesce(v_brief.client_persona_ids, array[]::text[])) with ordinality as e(id, ord)
    join public.client_persona_cards c on c.id = e.id;

  insert into public.site_specs (
    brand_kit_id, user_id,
    primary_hex, secondary_hex, accent_hex, light_neutral_hex, dark_neutral_hex,
    type_pairing_id, heading_font, body_font, google_fonts_url,
    hero, about_excerpt, pages, practice_details, target
  )
  values (
    p_brand_kit_id,
    v_user_id,

    upper(v_dir->'palette'->>'primary'),
    upper(v_dir->'palette'->>'secondary'),
    upper(v_dir->'palette'->>'secondary'),   -- see the header: the direction has no accent
    upper(v_dir->'palette'->>'light'),
    upper(v_dir->'palette'->>'dark'),

    -- The pairing id when the direction's two faces are a catalog pairing, and
    -- null when they are not. The fonts themselves are copied either way.
    (select tp.id from public.type_pairings tp
      where tp.heading_font = v_dir->'typography'->>'heading_font'
        and tp.body_font    = v_dir->'typography'->>'body_font'
      order by tp.sort_order limit 1),
    v_dir->'typography'->>'heading_font',
    v_dir->'typography'->>'body_font',
    v_dir->'typography'->>'google_fonts_url',

    jsonb_build_object(
      'overline',       v_dir->'hero'->>'overline',
      'headline',       v_dir->'hero'->>'headline',
      'subhead',        v_dir->'hero'->>'subhead',
      'cta_label',      v_dir->'hero'->>'cta_label',
      -- Not known at seed time and never guessed: it is the therapist's own
      -- booking page, and Eklio has no way to find it.
      'cta_target_url', null),

    -- Cut on a word boundary rather than at 600 exactly: the direction's
    -- excerpt has no upstream length limit, and a half-word is a visible
    -- defect where a slightly shorter paragraph is not.
    coalesce(public.truncate_on_word_boundary(v_dir->>'about_excerpt', 600), ''),

    public.site_spec_default_pages(v_specs, v_persona),

    jsonb_build_object(
      'practice_name',  coalesce(nullif(btrim(v_brief.practice_name), ''),
                                 (select nullif(btrim(p.name), '') from public.projects p
                                   where p.id = v_project)),
      'license_label',  (select lt.label from public.license_types lt
                          where lt.id = v_brief.license_type_id),
      -- The brief never asks for it, and Eklio must not invent a licence
      -- number. She types it in the editor or the output prints the label alone.
      'license_number', null,
      'city',           nullif(btrim(v_brief.city), ''),
      'state',          nullif(btrim(v_brief.state), ''),
      -- Deliberately not seeded from the account email: the address she signed
      -- up with is not necessarily the one she publishes.
      'email',          null,
      'phone',          null),

    public.site_spec_default_target(p_brand_kit_id)
  )
  on conflict (brand_kit_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

comment on function public.seed_site_spec(uuid) is
  'Create the site spec for a brand kit from its selected direction, if absent. Idempotent: returns rows actually inserted, 0 when a spec already exists or no direction is chosen. Never overwrites user edits — that is site_spec_reset.';


-- ============================================================================
-- 9. Hooking it onto direction selection
-- ============================================================================
-- Selecting a direction IS writing `brand_kits.selected_direction_id`; the
-- launch-checklist migration already treats it that way and ticks the first
-- item from a trigger on that column. The site spec is seeded from the same
-- event, so the frontend's select-direction handler gains the behaviour without
-- gaining a call — and a direction selected by any other path (a correction
-- from `service_role`, a kit imported with a choice already made) seeds too.
--
-- Both trigger functions are replaced rather than extended with a second
-- trigger: two AFTER triggers on one event have no defined order between them,
-- and the checklist tick and the spec seeding both want to run after the row is
-- final. Their previous bodies are preserved exactly.

create or replace function public.handle_new_brand_kit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.seed_launch_checklist(new.id);
  -- A kit created with a direction already chosen (regeneration, import) must
  -- not land with an unticked first item that is in fact done.
  if new.selected_direction_id is not null then
    perform public.complete_choose_direction(new.id);
    perform public.seed_site_spec(new.id);
  end if;
  return new;
end
$$;

create or replace function public.handle_brand_kit_direction_selected()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.complete_choose_direction(new.id);
  perform public.seed_site_spec(new.id);
  return new;
end
$$;


-- ============================================================================
-- 10. Backfill — kits that already chose a direction
-- ============================================================================
-- The triggers only fire from here on. A kit that picked its direction last
-- week would otherwise reach the editor with nothing in it.

do $$
declare
  k record;
begin
  for k in select id from public.brand_kits where selected_direction_id is not null loop
    perform public.seed_site_spec(k.id);
  end loop;
end
$$;


-- ============================================================================
-- 11. Guard rails
-- ============================================================================
do $$
declare
  n int;
begin
  if not (select relrowsecurity from pg_class where oid = 'public.site_specs'::regclass) then
    raise exception 'site_spec: RLS is off on site_specs. Migration aborted.';
  end if;

  -- ⚠ RULE 1, and this is the assertion that carries it. The policies above
  -- omit `TO` and therefore land on `public`, which includes `anon` — the
  -- convention every ownership policy in this schema follows, and it is safe
  -- for exactly one reason: the predicate is `auth.uid()`, which is NULL for an
  -- unauthenticated visitor, so the policy closes itself. That property is what
  -- has to hold, not the role list. So: no policy on this table may be
  -- unconditional, and every policy that is not an outright refusal must test
  -- `auth.uid()`. A `using (true)` slipped in here would publish the site.
  select count(*) into n
    from pg_policies
   where schemaname = 'public' and tablename = 'site_specs'
     and (coalesce(qual, 'false') = 'true' or coalesce(with_check, 'false') = 'true');
  if n > 0 then
    raise exception
      'site_spec: % unconditional policy/policies on site_specs. Eklio never publishes a site.', n;
  end if;

  select count(*) into n
    from pg_policies
   where schemaname = 'public' and tablename = 'site_specs'
     and coalesce(qual, '') || coalesce(with_check, '') not like '%auth.uid()%'
     and coalesce(qual, 'false') <> 'false'
     and coalesce(with_check, 'false') <> 'false';
  if n > 0 then
    raise exception
      'site_spec: % policy/policies on site_specs neither refuse nor test auth.uid().', n;
  end if;

  if not exists (select 1 from pg_policies where schemaname='public'
                  and tablename='site_specs' and cmd='INSERT' and with_check = 'false') then
    raise exception 'site_spec: the INSERT refusal is missing on site_specs.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public'
                  and tablename='site_specs' and cmd='DELETE' and qual = 'false') then
    raise exception 'site_spec: the DELETE refusal is missing on site_specs.';
  end if;

  -- One spec per kit, and the seeder upserts on it.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.site_specs'::regclass
       and contype = 'u'
       and pg_get_constraintdef(oid) = 'UNIQUE (brand_kit_id)'
  ) then
    raise exception
      'site_spec: no unique constraint on site_specs.brand_kit_id; seeding would not be idempotent.';
  end if;

  -- No contrast constraint may ever be added to this table.
  select count(*) into n
    from pg_constraint
   where conrelid = 'public.site_specs'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%contrast%';
  if n > 0 then
    raise exception
      'site_spec: a contrast CHECK exists on site_specs. Contrast is reported and fixable, never a wall.';
  end if;

  -- The length limits have to actually bite, at the exact boundary §1.2 names.
  if not public.site_spec_hero_lengths_valid(
       jsonb_build_object('overline', repeat('x', 48), 'headline', repeat('x', 90),
                          'subhead', repeat('x', 220), 'cta_label', repeat('x', 28))) then
    raise exception 'site_spec: a hero at exactly the documented limits was refused.';
  end if;
  if public.site_spec_hero_lengths_valid(
       jsonb_build_object('overline', repeat('x', 49), 'headline', 'h',
                          'subhead', 's', 'cta_label', 'c')) then
    raise exception 'site_spec: a 49-character hero overline was accepted.';
  end if;
  if public.site_spec_cta_target_url_valid(
       jsonb_build_object('cta_target_url', 'javascript:alert(1)')) then
    raise exception 'site_spec: a javascript: call-to-action target was accepted.';
  end if;
  if not public.site_spec_cta_target_url_valid(
       jsonb_build_object('cta_target_url', 'https://example.simplepractice.com/book')) then
    raise exception 'site_spec: a booking link was refused.';
  end if;

  -- The default structure has to satisfy the constraints it will be written
  -- under. If it does not, seeding fails on the first real kit and not here.
  if not public.site_spec_pages_valid(public.site_spec_default_pages(null, null)) then
    raise exception 'site_spec: the default page structure fails its own shape constraint.';
  end if;
  if not public.site_spec_pages_lengths_valid(public.site_spec_default_pages(null, null)) then
    raise exception 'site_spec: the default page structure fails its own length constraint.';
  end if;
  select count(*) into n
    from jsonb_array_elements(public.site_spec_default_pages(null, null)) pg
    cross join lateral jsonb_array_elements(pg.value->'sections') s
   where pg.value->>'key' = 'home';
  if n <> 6 then
    raise exception
      'site_spec: home has % default sections, expected the 6 the product spec names.', n;
  end if;
end
$$;

grant execute on function public.site_spec_default_pages(text[], text[]) to authenticated, service_role;
grant execute on function public.site_spec_default_target(uuid)          to authenticated, service_role;
grant execute on function public.seed_site_spec(uuid)                    to service_role;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Reverse script; the Supabase CLI has no down runner (see README).
--
--   create or replace function public.handle_brand_kit_direction_selected()
--   returns trigger language plpgsql security definer set search_path = '' as $fn$
--   begin perform public.complete_choose_direction(new.id); return new; end $fn$;
--   create or replace function public.handle_new_brand_kit()
--   returns trigger language plpgsql security definer set search_path = '' as $fn$
--   begin
--     perform public.seed_launch_checklist(new.id);
--     if new.selected_direction_id is not null then
--       perform public.complete_choose_direction(new.id);
--     end if;
--     return new;
--   end $fn$;
--   drop function if exists public.seed_site_spec(uuid);
--   drop function if exists public.site_spec_default_target(uuid);
--   drop function if exists public.site_spec_default_pages(text[], text[]);
--   drop table if exists public.site_specs;
--   drop function if exists public.site_spec_pages_lengths_valid(jsonb);
--   drop function if exists public.site_spec_pages_valid(jsonb);
--   drop function if exists public.site_spec_practice_details_valid(jsonb);
--   drop function if exists public.site_spec_cta_target_url_valid(jsonb);
--   drop function if exists public.site_spec_hero_lengths_valid(jsonb);
--   drop function if exists public.site_spec_hero_valid(jsonb);
--   drop function if exists public.site_spec_page_keys();
--   drop function if exists public.site_spec_section_types();
--   alter table public.brand_kits drop constraint if exists brand_kits_site_prompt_target_check;
--   alter table public.brand_kits
--     add constraint brand_kits_site_prompt_target_check check (
--       site_prompt_target is null
--       or site_prompt_target = any (array['squarespace'::text, 'lovable'::text,
--                                          'framer'::text, 'webflow'::text]));
