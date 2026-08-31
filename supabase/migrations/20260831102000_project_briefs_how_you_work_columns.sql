-- ============================================================================
-- project_briefs — "How you work" columns, generated tone cards, USP options
-- ============================================================================
-- All nullable, added to the existing `project_briefs` table (there is no
-- `briefs` table — see the header of `20260827101000_brief_autosave_and_preview.sql`).
--
-- Empty array vs NULL is kept distinguishable on purpose: these columns
-- default to NULL, not `'{}'`, unlike the five pre-existing array columns on
-- this table. "Unanswered" and "answered with nothing selected" are different
-- states for an optional multi-select.

alter table public.project_briefs
  add column if not exists session_style_ids      text[],
  add column if not exists not_a_fit_ids           text[],
  add column if not exists not_a_fit_text          text,
  add column if not exists modality_ids            text[],
  add column if not exists modality_prominence     text,
  add column if not exists referral_quote          text,
  add column if not exists prior_career            text,
  add column if not exists prior_career_public     boolean not null default false,
  add column if not exists usp_options             jsonb,
  add column if not exists selected_usp_id         text,
  add column if not exists usp_statement            text,
  add column if not exists tone_cards               jsonb,
  add column if not exists tone_cards_inputs_hash    text;

-- ============================================================================
-- 1. Simple scalar bounds
-- ============================================================================

alter table public.project_briefs drop constraint if exists project_briefs_not_a_fit_text_check;
alter table public.project_briefs add constraint project_briefs_not_a_fit_text_check
  check (coalesce(char_length(not_a_fit_text), 0) <= 400);

alter table public.project_briefs drop constraint if exists project_briefs_referral_quote_check;
alter table public.project_briefs add constraint project_briefs_referral_quote_check
  check (coalesce(char_length(referral_quote), 0) <= 400);

alter table public.project_briefs drop constraint if exists project_briefs_prior_career_check;
alter table public.project_briefs add constraint project_briefs_prior_career_check
  check (coalesce(char_length(prior_career), 0) <= 200);

alter table public.project_briefs drop constraint if exists project_briefs_usp_statement_check;
alter table public.project_briefs add constraint project_briefs_usp_statement_check
  check (coalesce(char_length(usp_statement), 0) <= 200);

alter table public.project_briefs drop constraint if exists project_briefs_modality_prominence_fkey;
alter table public.project_briefs add constraint project_briefs_modality_prominence_fkey
  foreign key (modality_prominence) references public.modality_prominence_options (id) on delete restrict;

create index if not exists project_briefs_modality_prominence_idx
  on public.project_briefs (modality_prominence);

-- ============================================================================
-- 2. Array length bounds
-- ============================================================================
-- Same idiom as the existing `project_briefs_palette_family_ids_check`:
-- `coalesce(array_length(x, 1), 0) <= n`, which is NULL-safe (a NULL array
-- has `array_length` NULL, `coalesce`s to 0, passes) and true-on-empty-array.

alter table public.project_briefs drop constraint if exists project_briefs_session_style_ids_check;
alter table public.project_briefs add constraint project_briefs_session_style_ids_check
  check (coalesce(array_length(session_style_ids, 1), 0) <= 4);

alter table public.project_briefs drop constraint if exists project_briefs_not_a_fit_ids_check;
alter table public.project_briefs add constraint project_briefs_not_a_fit_ids_check
  check (coalesce(array_length(not_a_fit_ids, 1), 0) <= 3);

alter table public.project_briefs drop constraint if exists project_briefs_modality_ids_check;
alter table public.project_briefs add constraint project_briefs_modality_ids_check
  check (coalesce(array_length(modality_ids, 1), 0) <= 5);

-- ============================================================================
-- 3. Referential validation of the three new *_ids arrays
-- ============================================================================
-- Postgres has no foreign key on array elements. `client_persona_ids`,
-- `problem_card_ids`, `gain_card_ids`, `specialty_ids` and `site_goal_ids`
-- were deliberately left unchecked for exactly this reason (see
-- `20260827101000_brief_autosave_and_preview.sql`) — a constraint trigger
-- validating five arrays on every autosave keystroke was judged not worth
-- the cost for fields with a documented preview fallback.
--
-- These three are different: an unknown id here would either violate the
-- CHECKs on `tone_cards`/`usp_options` two migrations from now (silently, at
-- generation time, far from the mistake) or point the array-FK triggers
-- at nothing. So they get the referential check the others don't — but only
-- when the column actually changed, not on every unrelated-field autosave,
-- to keep the keystroke path cheap.

create or replace function public.project_briefs_validate_how_you_work_refs()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_id text;
begin
  if (tg_op = 'INSERT' or new.session_style_ids is distinct from old.session_style_ids)
     and new.session_style_ids is not null then
    foreach v_id in array new.session_style_ids loop
      if not exists (select 1 from public.session_style_cards where id = v_id) then
        raise exception 'project_briefs.session_style_ids: unknown id %', v_id;
      end if;
    end loop;
  end if;

  if (tg_op = 'INSERT' or new.not_a_fit_ids is distinct from old.not_a_fit_ids)
     and new.not_a_fit_ids is not null then
    foreach v_id in array new.not_a_fit_ids loop
      if not exists (select 1 from public.not_a_fit_cards where id = v_id) then
        raise exception 'project_briefs.not_a_fit_ids: unknown id %', v_id;
      end if;
    end loop;
  end if;

  if (tg_op = 'INSERT' or new.modality_ids is distinct from old.modality_ids)
     and new.modality_ids is not null then
    foreach v_id in array new.modality_ids loop
      if not exists (select 1 from public.modality_cards where id = v_id) then
        raise exception 'project_briefs.modality_ids: unknown id %', v_id;
      end if;
    end loop;
  end if;

  return new;
end;
$function$;

drop trigger if exists project_briefs_validate_how_you_work_refs on public.project_briefs;
create trigger project_briefs_validate_how_you_work_refs
  before insert or update on public.project_briefs
  for each row execute function public.project_briefs_validate_how_you_work_refs();

-- ============================================================================
-- 4. tone_cards shape — exactly 6, every key present, sample_hero <= 46
-- ============================================================================
-- 46, not the `site_specs` 90-char headline bound: this matches the existing
-- `brand_kit_directions_rendering_valid` headline bound because a tone card's
-- `sample_hero` is rendered in the same slot a direction's headline is (see
-- `<BrandPreview />`, frontend). The two limits differ on purpose — see
-- FRONTEND_CONTRACT.md.
--
-- Null-safe by construction: `?&` key-presence is checked before any value
-- is read off an element, so an element missing a key fails the `?&` branch
-- and short-circuits before the (otherwise NULL-on-missing-key) value checks
-- would run. This is the pattern `20260829112000_null_safe_jsonb_validators.sql`
-- introduced to fix exactly the `true and null = null` bug on this schema.

create or replace function public.project_briefs_tone_cards_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) <> 6 then false
    else
      not exists (
        select 1
        from jsonb_array_elements(p) as c(value)
        where jsonb_typeof(c.value) <> 'object'
           or not (c.value ?& array['id', 'label', 'keywords', 'sample_hero', 'generated'])
           or jsonb_typeof(c.value -> 'id') is distinct from 'string'
           or jsonb_typeof(c.value -> 'label') is distinct from 'string'
           or jsonb_typeof(c.value -> 'sample_hero') is distinct from 'string'
           or jsonb_typeof(c.value -> 'generated') is distinct from 'boolean'
           or jsonb_typeof(c.value -> 'keywords') is distinct from 'array'
           or jsonb_array_length(c.value -> 'keywords') <> 3
           or exists (
                select 1 from jsonb_array_elements(c.value -> 'keywords') as k(value)
                where jsonb_typeof(k.value) is distinct from 'string'
              )
           or char_length(c.value ->> 'sample_hero') > 46
      )
      and (select count(distinct c.value ->> 'id') from jsonb_array_elements(p) c) = 6
  end
$$;

alter table public.project_briefs drop constraint if exists project_briefs_tone_cards_check;
alter table public.project_briefs add constraint project_briefs_tone_cards_check
  check (public.project_briefs_tone_cards_valid(tone_cards));

-- ============================================================================
-- 5. usp_options shape — exactly 3, every key present, three distinct angles
-- ============================================================================

create or replace function public.project_briefs_usp_options_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) <> 3 then false
    else
      not exists (
        select 1
        from jsonb_array_elements(p) as c(value)
        where jsonb_typeof(c.value) <> 'object'
           or not (c.value ?& array['id', 'angle', 'statement', 'rationale', 'evidence'])
           or jsonb_typeof(c.value -> 'id') is distinct from 'string'
           or jsonb_typeof(c.value -> 'angle') is distinct from 'string'
           or (c.value ->> 'angle') <> all (array['population', 'method', 'lived_experience'])
           or jsonb_typeof(c.value -> 'statement') is distinct from 'string'
           or jsonb_typeof(c.value -> 'rationale') is distinct from 'string'
           or jsonb_typeof(c.value -> 'evidence') is distinct from 'array'
           or char_length(c.value ->> 'statement') > 200
           or char_length(c.value ->> 'rationale') > 240
           or exists (
                select 1 from jsonb_array_elements(c.value -> 'evidence') as e(value)
                where jsonb_typeof(e.value) is distinct from 'string'
              )
      )
      and (select count(distinct c.value ->> 'id') from jsonb_array_elements(p) c) = 3
      and (select count(distinct c.value ->> 'angle') from jsonb_array_elements(p) c) = 3
  end
$$;

alter table public.project_briefs drop constraint if exists project_briefs_usp_options_check;
alter table public.project_briefs add constraint project_briefs_usp_options_check
  check (public.project_briefs_usp_options_valid(usp_options));

-- ============================================================================
-- 6. selected_usp_id — must match an id present in usp_options, via TRIGGER
-- ============================================================================
-- A trigger, not a CHECK, per the brief: a CHECK on this column alone cannot
-- see `usp_options` unless written as a same-row multi-column CHECK, which
-- Postgres allows but which reads badly next to the shape CHECK above and
-- would duplicate `jsonb_array_elements` traversal on every write regardless
-- of whether `selected_usp_id` changed. The trigger only runs the lookup when
-- `selected_usp_id` is being set to a non-null value.

create or replace function public.project_briefs_validate_selected_usp_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.selected_usp_id is not null then
    if new.usp_options is null or jsonb_typeof(new.usp_options) <> 'array' then
      raise exception 'project_briefs.selected_usp_id: usp_options is empty, cannot select %', new.selected_usp_id;
    end if;

    if not exists (
      select 1 from jsonb_array_elements(new.usp_options) as c(value)
      where c.value ->> 'id' = new.selected_usp_id
    ) then
      raise exception 'project_briefs.selected_usp_id: % is not an id present in usp_options', new.selected_usp_id;
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists project_briefs_validate_selected_usp_id on public.project_briefs;
create trigger project_briefs_validate_selected_usp_id
  before insert or update on public.project_briefs
  for each row execute function public.project_briefs_validate_selected_usp_id();

-- DOWN
-- drop trigger if exists project_briefs_validate_selected_usp_id on public.project_briefs;
-- drop function if exists public.project_briefs_validate_selected_usp_id();
-- drop trigger if exists project_briefs_validate_how_you_work_refs on public.project_briefs;
-- drop function if exists public.project_briefs_validate_how_you_work_refs();
-- alter table public.project_briefs drop constraint if exists project_briefs_usp_options_check;
-- drop function if exists public.project_briefs_usp_options_valid(jsonb);
-- alter table public.project_briefs drop constraint if exists project_briefs_tone_cards_check;
-- drop function if exists public.project_briefs_tone_cards_valid(jsonb);
-- alter table public.project_briefs drop constraint if exists project_briefs_modality_ids_check;
-- alter table public.project_briefs drop constraint if exists project_briefs_not_a_fit_ids_check;
-- alter table public.project_briefs drop constraint if exists project_briefs_session_style_ids_check;
-- alter table public.project_briefs drop constraint if exists project_briefs_modality_prominence_fkey;
-- alter table public.project_briefs drop constraint if exists project_briefs_usp_statement_check;
-- alter table public.project_briefs drop constraint if exists project_briefs_prior_career_check;
-- alter table public.project_briefs drop constraint if exists project_briefs_referral_quote_check;
-- alter table public.project_briefs drop constraint if exists project_briefs_not_a_fit_text_check;
-- alter table public.project_briefs
--   drop column if exists tone_cards_inputs_hash,
--   drop column if exists tone_cards,
--   drop column if exists usp_statement,
--   drop column if exists selected_usp_id,
--   drop column if exists usp_options,
--   drop column if exists prior_career_public,
--   drop column if exists prior_career,
--   drop column if exists referral_quote,
--   drop column if exists modality_prominence,
--   drop column if exists modality_ids,
--   drop column if exists not_a_fit_text,
--   drop column if exists not_a_fit_ids,
--   drop column if exists session_style_ids;
