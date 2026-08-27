-- ============================================================================
-- Eklio — the brief: continuous partial autosave, and the live preview
-- ============================================================================
-- Follows `20260827100000_catalog_reference_data.sql`, which it depends on:
-- `brief_preview()` resolves palette, type-pairing, tone, license, action,
-- persona and specialty ids against those catalogs.
--
-- ⚠ THERE IS NO `briefs` TABLE, AND THIS MIGRATION DOES NOT CREATE ONE.
-- The brief already exists as `public.project_briefs` (one row per project,
-- primary key `project_id`, free-form `data` jsonb, `completed_steps`), created
-- by the reference schema. Creating a second `briefs` table would produce
-- exactly the parallel structure the reference migration was written to end.
-- Every column below is therefore an ALTER on `project_briefs`.
--
-- "brief id" and "project id" are the same value: `project_briefs.project_id`
-- is the primary key. `brief_preview(p_brief_id uuid)` takes that value.
--
-- ALREADY PRESENT, NOT RE-ADDED
-- -----------------------------
--   * `completed_steps` exists as `smallint[] not null default '{}'`. The spec
--     asked for `int[]`; the semantics are identical and `smallint[]` is what
--     is in the database and in the frontend's generated types. Rewriting the
--     column type to gain nothing would break both.
--   * `updated_at` exists and is already maintained by the trigger
--     `project_briefs_set_updated_at`.
--
-- ⚠ OVERLAP TO BE AWARE OF: `projects.current_step` (smallint, 1..8) already
-- tracks a wizard position. `progress_step` below is the BRIEF's own pointer,
-- constrained to its seven steps, and lives on the row that autosaves. They
-- are not automatically kept in sync, and they should not be read as one
-- value: treat `projects.current_step` as the project lifecycle pointer
-- (brief -> directions -> kit) and `project_briefs.progress_step` as the step
-- the brief resumes at. Flagged in the README as a reconciliation item.
--
-- AUTOSAVE SHAPE
-- --------------
-- The brief is answered one question per screen and saved on every change, so
-- every answer column is nullable with a usable default and can be updated on
-- its own. Nothing here is `not null`: a half-finished brief is the normal
-- state of this table, not an error.
-- ============================================================================


-- ============================================================================
-- 1. Answer columns
-- ============================================================================
-- ⚠ SIX COLUMNS BEYOND THE SPEC LIST, and they are not optional extras:
-- `practice_name`, `positioning`, `license_type_id`, `primary_action_id`,
-- `specialty_ids` and `site_goal_ids` are read by `brief_preview()` for the
-- headline overline, the subhead, the CTA and the specialty chips. The spec
-- describes those preview fields but assumed the answers were already stored.
-- They were not — they would have had to live as untyped keys inside the
-- existing `data` jsonb, where nothing constrains them and no foreign key
-- reaches them. They are columns for the same reason `brand_kits.tier` was
-- promoted out of `content` in lot 4.

alter table public.project_briefs
  add column if not exists progress_step      int    not null default 1,
  add column if not exists tone_card_id       text,
  add column if not exists client_persona_ids text[] not null default '{}',
  add column if not exists problem_card_ids   text[] not null default '{}',
  add column if not exists gain_card_ids      text[] not null default '{}',
  add column if not exists palette_family_ids text[] not null default '{}',
  add column if not exists type_pairing_id    text,
  add column if not exists city               text,
  add column if not exists state              text,
  add column if not exists practice_name      text,
  add column if not exists positioning        text,
  add column if not exists license_type_id    text,
  add column if not exists primary_action_id  text,
  add column if not exists specialty_ids      text[] not null default '{}',
  add column if not exists site_goal_ids      text[] not null default '{}';

comment on column public.project_briefs.palette_family_ids is
  'Chosen palette families, ORDER IS MEANINGFUL: element 1 is the leading palette that drives the live preview (Screen 1 labels the first pick LEADING). At most 3.';
comment on column public.project_briefs.progress_step is
  'Step the brief resumes at, 1..7. Distinct from projects.current_step, which is the project lifecycle pointer (1..8).';


-- ============================================================================
-- 2. Constraints
-- ============================================================================

alter table public.project_briefs drop constraint if exists project_briefs_progress_step_check;
alter table public.project_briefs
  add constraint project_briefs_progress_step_check check (
    progress_step between 1 and 7
  );

-- Screen 1 lets a therapist shortlist palettes and marks the first as LEADING.
-- More than three is not a UI state that exists.
alter table public.project_briefs drop constraint if exists project_briefs_palette_family_ids_check;
alter table public.project_briefs
  add constraint project_briefs_palette_family_ids_check check (
    coalesce(array_length(palette_family_ids, 1), 0) <= 3
  );

-- Two-letter USPS code: the overline renders `· PORTLAND, OR`, uppercased at
-- read time. Stored as typed, so that a brief keeps what the therapist wrote.
alter table public.project_briefs drop constraint if exists project_briefs_state_check;
alter table public.project_briefs
  add constraint project_briefs_state_check check (
    state is null or state ~ '^[A-Za-z]{2}$'
  );

-- Scalar catalog references get real foreign keys. ON DELETE RESTRICT rather
-- than the NO ACTION used for `brand_kits.direction_id`: that one is deferred
-- because `directions` and `brand_kits` both cascade from `projects` and the
-- order matters. Catalogs cascade from nothing, so the immediate check is
-- simply the earlier error message. Catalog rows are retired with
-- `active = false` and never deleted, so this should never fire.
alter table public.project_briefs drop constraint if exists project_briefs_tone_card_id_fkey;
alter table public.project_briefs
  add constraint project_briefs_tone_card_id_fkey
  foreign key (tone_card_id) references public.tone_cards (id) on delete restrict;

alter table public.project_briefs drop constraint if exists project_briefs_type_pairing_id_fkey;
alter table public.project_briefs
  add constraint project_briefs_type_pairing_id_fkey
  foreign key (type_pairing_id) references public.type_pairings (id) on delete restrict;

alter table public.project_briefs drop constraint if exists project_briefs_license_type_id_fkey;
alter table public.project_briefs
  add constraint project_briefs_license_type_id_fkey
  foreign key (license_type_id) references public.license_types (id) on delete restrict;

alter table public.project_briefs drop constraint if exists project_briefs_primary_action_id_fkey;
alter table public.project_briefs
  add constraint project_briefs_primary_action_id_fkey
  foreign key (primary_action_id) references public.primary_actions (id) on delete restrict;

-- Index the referencing side of each new FK: without one, deleting a catalog
-- row seq-scans project_briefs. Same reasoning as brand_kits_direction_id_idx.
create index if not exists project_briefs_tone_card_id_idx      on public.project_briefs (tone_card_id);
create index if not exists project_briefs_type_pairing_id_idx   on public.project_briefs (type_pairing_id);
create index if not exists project_briefs_license_type_id_idx   on public.project_briefs (license_type_id);
create index if not exists project_briefs_primary_action_id_idx on public.project_briefs (primary_action_id);

-- ⚠ THE ARRAY COLUMNS ARE NOT FOREIGN-KEY CHECKED. Postgres 17 has no foreign
-- key on array elements, and a constraint trigger validating five arrays on
-- every autosave would put a catalog lookup on the keystroke path. The cost of
-- an id that does not resolve is bounded and defined: `brief_preview()` falls
-- back to its documented default for that field. Postgres 18 adds element
-- foreign keys; this is the place to revisit when the project moves.


-- ============================================================================
-- 3. truncate_on_word_boundary — deterministic, so it lives here
-- ============================================================================
-- The subhead is cut at 60 characters without splitting a word. Doing it in
-- SQL keeps the preview a single query and keeps the rule in one place; doing
-- it in the frontend would mean the rule is re-implemented for the PDF, the
-- share page and the site prompt, and the three would drift.
--
-- Cuts at the last whitespace inside the first (n + 1) characters. If the
-- first n + 1 characters contain no whitespace at all — one very long word —
-- there is no boundary to cut on and it falls back to a hard cut at n.
-- No ellipsis is appended: the caller decides how a truncation is signalled.

create or replace function public.truncate_on_word_boundary(p_text text, p_max int)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_text is null then null
    when char_length(p_text) <= p_max then p_text
    when char_length(regexp_replace(left(p_text, p_max + 1), '\s+\S*$', '')) between 1 and p_max
      then regexp_replace(left(p_text, p_max + 1), '\s+\S*$', '')
    else left(p_text, p_max)
  end
$$;

comment on function public.truncate_on_word_boundary(text, int) is
  'Truncate to at most p_max characters without splitting a word. Falls back to a hard cut when the first p_max+1 characters contain no whitespace.';


-- ============================================================================
-- 4. brief_preview — the model the preview rail renders
-- ============================================================================
-- Returns the whole preview in ONE round trip, as jsonb:
--
--   { practice_name,
--     tokens: { primary, secondary, light, dark, paper,
--               heading_font, body_font, google_fonts_url },
--     hero:   { overline, headline, subhead, cta_label },
--     about_excerpt,
--     specialties: text[] }
--
-- Pure SQL, no external call, no clock: it reads six small catalog tables by
-- primary key and one brief row. Single-digit milliseconds, and it can be
-- called on every autosave without thinking about it.
--
-- SECURITY INVOKER, deliberately. The function reads `project_briefs`, which
-- is behind RLS; running as invoker means a caller asking for someone else's
-- brief gets zero rows and therefore NULL — not a permission error, and not
-- another user's preview. Making it SECURITY DEFINER would turn it into a
-- read-anything oracle keyed by uuid.
--
-- FALLBACKS ARE THE FIRST-RENDER STATE, NOT ERROR HANDLING. Screen 1's rail is
-- already showing a complete site before the therapist has chosen anything:
-- CLAY & SAND, Fraunces / Nunito Sans, `A calmer place to start.` Each fallback
-- below is what that screen renders.

create or replace function public.brief_preview(p_brief_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with b as (
    select pb.*, p.name as project_name
      from public.project_briefs pb
      join public.projects p on p.id = pb.project_id
     where pb.project_id = p_brief_id
  ),
  -- Leading palette = element 1 of the ordered array. Falls back to CLAY & SAND,
  -- the family Screen 1's rail renders before any choice is made.
  pal as (
    select pf.*
      from public.palette_families pf
     where pf.id = coalesce((select palette_family_ids[1] from b), 'clay_sand')
     union all
    select pf.* from public.palette_families pf
     where pf.id = 'clay_sand'
       and not exists (
         select 1 from public.palette_families x
          where x.id = coalesce((select palette_family_ids[1] from b), 'clay_sand'))
     limit 1
  ),
  typ as (
    select tp.*
      from public.type_pairings tp
     where tp.id = coalesce((select type_pairing_id from b), 'fraunces_nunito')
     union all
    select tp.* from public.type_pairings tp
     where tp.id = 'fraunces_nunito'
       and not exists (
         select 1 from public.type_pairings x
          where x.id = coalesce((select type_pairing_id from b), 'fraunces_nunito'))
     limit 1
  ),
  -- Specialties keep the order the therapist picked them in; the rail renders
  -- exactly two chips, so anything past the second is not a rendering decision
  -- the frontend gets to make.
  spec as (
    select array_agg(s.label order by e.ord) as labels,
           array_agg(
             case when s.label = upper(s.label) then s.label else lower(s.label) end
             order by e.ord
           ) as phrases
      from b
      cross join lateral unnest(b.specialty_ids) with ordinality as e(id, ord)
      join public.specialties s on s.id = e.id
     where e.ord <= 2
  ),
  persona as (
    select p.label
      from b
      cross join lateral unnest(b.client_persona_ids) with ordinality as e(id, ord)
      join public.client_persona_cards p on p.id = e.id
     order by e.ord
     limit 1
  )
  select jsonb_build_object(
    'practice_name',
      coalesce(nullif(btrim(b.practice_name), ''), nullif(btrim(b.project_name), '')),

    'tokens', jsonb_build_object(
      'primary',          pal.primary_hex,
      'secondary',        pal.secondary_hex,
      'light',            pal.light_hex,
      'dark',             pal.dark_hex,
      'paper',            pal.paper_hex,
      'heading_font',     typ.heading_font,
      'body_font',        typ.body_font,
      'google_fonts_url', typ.google_fonts_url
    ),

    'hero', jsonb_build_object(
      -- License label, then ' · CITY, ST' when BOTH parts are known. Built by
      -- joining the present parts, so a brief with a city but no license reads
      -- `PORTLAND, OR` rather than ` · PORTLAND, OR`.
      'overline',
        nullif(
          array_to_string(
            array_remove(array[
              (select lt.label from public.license_types lt where lt.id = b.license_type_id),
              case
                when nullif(btrim(b.city), '') is not null
                 and nullif(btrim(b.state), '') is not null
                then upper(btrim(b.city)) || ', ' || upper(btrim(b.state))
              end
            ], null),
            ' · '
          ), ''),

      'headline',
        coalesce(
          (select tc.sample_hero from public.tone_cards tc where tc.id = b.tone_card_id),
          'A calmer place to start.'),

      'subhead',
        coalesce(
          public.truncate_on_word_boundary(nullif(btrim(b.positioning), ''), 60),
          'Therapy for high-performing adults who can''t switch off.'),

      'cta_label',
        coalesce(
          (select pa.label from public.primary_actions pa where pa.id = b.primary_action_id),
          'Book a consult')
    ),

    -- Two sentences, filled from the first persona card and the specialties.
    -- Both halves have a fallback because the About block renders from the
    -- first screen onwards, before either answer has been given. Acronyms keep
    -- their case (ADHD), everything else is lowercased into the sentence.
    'about_excerpt',
      'I work mostly with '
      || coalesce(
           (select lower(left(persona.label, 1)) || substr(persona.label, 2) from persona),
           'adults who are carrying more than they let on')
      || '. Much of that work sits with '
      || coalesce(
           (select array_to_string(spec.phrases, ' and ') from spec),
           'anxiety and burnout')
      || '.',

    'specialties',
      coalesce((select to_jsonb(spec.labels) from spec), '[]'::jsonb)
  )
  from b
  cross join pal
  cross join typ
$$;

comment on function public.brief_preview(uuid) is
  'Deterministic model for the live preview rail: practice_name, tokens, hero, about_excerpt, specialties. SECURITY INVOKER, so RLS decides whose brief is readable. Returns NULL for an unknown or unreadable brief id.';

grant execute on function public.brief_preview(uuid) to authenticated, service_role;
grant execute on function public.truncate_on_word_boundary(text, int) to authenticated, service_role;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Reverse script; the Supabase CLI has no down runner (see README).
--
--   drop function if exists public.brief_preview(uuid);
--   drop function if exists public.truncate_on_word_boundary(text, int);
--   drop index if exists public.project_briefs_primary_action_id_idx;
--   drop index if exists public.project_briefs_license_type_id_idx;
--   drop index if exists public.project_briefs_type_pairing_id_idx;
--   drop index if exists public.project_briefs_tone_card_id_idx;
--   alter table public.project_briefs
--     drop constraint if exists project_briefs_primary_action_id_fkey,
--     drop constraint if exists project_briefs_license_type_id_fkey,
--     drop constraint if exists project_briefs_type_pairing_id_fkey,
--     drop constraint if exists project_briefs_tone_card_id_fkey,
--     drop constraint if exists project_briefs_state_check,
--     drop constraint if exists project_briefs_palette_family_ids_check,
--     drop constraint if exists project_briefs_progress_step_check;
--   alter table public.project_briefs
--     drop column if exists site_goal_ids,
--     drop column if exists specialty_ids,
--     drop column if exists primary_action_id,
--     drop column if exists license_type_id,
--     drop column if exists positioning,
--     drop column if exists practice_name,
--     drop column if exists state,
--     drop column if exists city,
--     drop column if exists type_pairing_id,
--     drop column if exists palette_family_ids,
--     drop column if exists gain_card_ids,
--     drop column if exists problem_card_ids,
--     drop column if exists client_persona_ids,
--     drop column if exists tone_card_id,
--     drop column if exists progress_step;
