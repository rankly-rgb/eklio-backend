-- ============================================================================
-- Eklio — closing the NULL hole in every jsonb validator
-- ============================================================================
-- Follows `20260829111000_site_spec_suggest_hex_bounds.sql`.
--
-- THE PATTERN
-- -----------
-- A CHECK constraint accepts a row when its expression is TRUE **or NULL**. It
-- rejects only on FALSE. Every validator in this repo that tests a jsonb key
-- with an operator returning NULL for a missing key therefore had a hole:
--
--     p->>'light' ~ '^#[0-9A-Fa-f]{6}$'     -- missing key -> NULL
--     true and NULL                          -- -> NULL
--     CHECK (NULL)                           -- -> ACCEPTED
--
-- Found in `brand_kit_palette_valid` while tracing why a v5-shaped palette
-- reached the site-spec seeder. It was not an incident. Audited across every
-- function reachable from a CHECK, the same construction appears in five
-- functions and one inline constraint.
--
-- WHY SOME VALIDATORS WERE NEVER AFFECTED
-- ---------------------------------------
-- The ones that survived did so because they were written with NULL-safe
-- operators, and it is worth naming them so the next validator is written the
-- same way:
--
--   * `jsonb_typeof(x) IS DISTINCT FROM 'string'` — NULL-safe. `IS DISTINCT
--     FROM` is a three-valued-logic escape hatch: it returns TRUE, never NULL,
--     when one side is NULL. This is why `brand_kit_directions_shape_valid`
--     catches a direction missing `name` but not one missing `palette.light` —
--     the first is its own `IS DISTINCT FROM`, the second was delegated to the
--     holed `brand_kit_palette_valid`.
--   * `coalesce(char_length(x), 0) <= 34` — the coalesce absorbs the NULL.
--   * `x IS NULL` — the paywall constraint on `monthly_presence_content`, which
--     was checked first and is sound.
--
-- WHAT THIS MIGRATION DOES NOT DO
-- -------------------------------
-- It does not change a single accept/reject decision for well-formed input.
-- Every rewritten body keeps its original predicates verbatim; what is added is
-- an explicit key-presence test in front and a `coalesce(…, false)` around the
-- whole thing, so the only reachable answers are TRUE and FALSE. The existing
-- suite is the proof.
--
-- ⚠ THE VALIDATORS THAT RETURN TRUE FOR A WRONG-TYPED ARGUMENT ARE LEFT ALONE
-- AND ARE NOT HOLES. `site_spec_hero_lengths_valid`,
-- `site_spec_pages_lengths_valid`, `brand_kit_directions_rendering_valid` and
-- `brand_kit_social_templates_rendering_valid` answer TRUE — never NULL — for
-- input the shape check is responsible for rejecting. That is this repo's
-- documented "two constraints per column, one role each, so a rejected write
-- names the rule it broke". Making them reject would give one write two
-- different error messages depending on which CHECK fired first.
-- ============================================================================


-- ============================================================================
-- 1. brand_kit_palette_valid — HOLED
-- ============================================================================
-- Probed before the fix:
--     '{}'                                    -> NULL   (accepted by CHECK)
--     palette missing any one of the five keys -> NULL   (accepted by CHECK)
--     'null', a scalar, an array               -> false  (correctly rejected)
--
-- `?&` requires all five keys to be present before their format is tested, so a
-- missing key fails loudly on the presence test instead of being absorbed by
-- the regex returning NULL.

create or replace function public.brand_kit_palette_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    p is not null
    and jsonb_typeof(p) = 'object'
    and p ?& array['primary', 'secondary', 'light', 'dark', 'paper']
    and p->>'primary'   ~ '^#[0-9A-Fa-f]{6}$'
    and p->>'secondary' ~ '^#[0-9A-Fa-f]{6}$'
    and p->>'light'     ~ '^#[0-9A-Fa-f]{6}$'
    and p->>'dark'      ~ '^#[0-9A-Fa-f]{6}$'
    and p->>'paper'     ~ '^#[0-9A-Fa-f]{6}$',
  false)
$$;

comment on function public.brand_kit_palette_valid(jsonb) is
  'The five palette roles a direction must carry: primary, secondary, light, dark, paper. Key presence is tested before format, and the result is coalesced to false, so a missing key is rejected rather than returning NULL — which a CHECK constraint would have accepted.';


-- ============================================================================
-- 2. brand_kit_hero_valid — HOLED
-- ============================================================================
-- Probed before the fix: '{}' and every single-key omission returned NULL.
-- This is the one that let a direction carry an empty hero into the reveal.

create or replace function public.brand_kit_hero_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    p is not null
    and jsonb_typeof(p) = 'object'
    and p ?& array['overline', 'headline', 'subhead', 'cta_label']
    and jsonb_typeof(p->'overline')  = 'string'
    and jsonb_typeof(p->'headline')  = 'string'
    and jsonb_typeof(p->'subhead')   = 'string'
    and jsonb_typeof(p->'cta_label') = 'string',
  false)
$$;


-- ============================================================================
-- 3. site_spec_hero_valid — HOLED, and shipped by this lot
-- ============================================================================
-- ⚠ Written in `20260829100000_site_spec.sql`, in this lot, in the same house
-- style as the validator whose hole it was written next to. `hero = '{}'` was
-- accepted by `site_specs_hero_shape_check` and rendered as an empty hero
-- section in the mockup. Recording it here rather than quietly correcting it in
-- the original file: the original migration is what was reviewed.
--
-- `cta_target_url` stays optional — absent, JSON null or a string — which is
-- its documented contract, so it is deliberately not in the `?&` list.

create or replace function public.site_spec_hero_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    p is not null
    and jsonb_typeof(p) = 'object'
    and p ?& array['overline', 'headline', 'subhead', 'cta_label']
    and jsonb_typeof(p->'overline')  = 'string'
    and jsonb_typeof(p->'headline')  = 'string'
    and jsonb_typeof(p->'subhead')   = 'string'
    and jsonb_typeof(p->'cta_label') = 'string'
    -- absent, JSON null or a string; never a number or an object. It is the
    -- therapist's own booking link and she may not have one yet.
    and (jsonb_typeof(p->'cta_target_url') is null
         or jsonb_typeof(p->'cta_target_url') in ('string', 'null')),
  false)
$$;


-- ============================================================================
-- 4. section_type_fields_valid — HOLED in one predicate out of five
-- ============================================================================
-- A useful illustration of how narrow this is. Four of its five per-field tests
-- use `IS DISTINCT FROM` or a cast that raises, and are sound. The fifth —
--
--     not (f.value->>'kind' = any (array['text','longtext','list']))
--
-- — returns NULL for a field with no `kind`, so that field is not selected by
-- the `where`, so `not exists` is true, so the row is accepted. Probed:
-- a field missing `max_length` was correctly refused; the same field missing
-- `kind` was accepted.

create or replace function public.section_type_fields_valid(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    case
      when p is null then false
      when jsonb_typeof(p) <> 'array' then false
      else not exists (
        select 1 from jsonb_array_elements(p) as f
        where jsonb_typeof(f.value) <> 'object'
           or not (f.value ?& array['key', 'label', 'kind', 'max_length'])
           or jsonb_typeof(f.value->'key')   is distinct from 'string'
           or jsonb_typeof(f.value->'label') is distinct from 'string'
           -- NULL-safe form of `not (kind = any (...))`: a JSON null or an
           -- absent key becomes '' and fails every comparison, selecting the
           -- row instead of vanishing from the result.
           or coalesce(f.value->>'kind', '') <> all (array['text', 'longtext', 'list'])
           or jsonb_typeof(f.value->'max_length') is distinct from 'number'
           -- ⚠ 800 is §1.2's ceiling for any section text field, enforced by
           -- `site_spec_pages_lengths_valid`. A catalog advertising 900 would
           -- promise the editor a length the write path refuses.
           or (f.value->>'max_length')::numeric not between 1 and 800
      )
      and (select count(distinct f.value->>'key') from jsonb_array_elements(p) f)
          = jsonb_array_length(p)
    end,
  false)
$$;


-- ============================================================================
-- 5. palette_families_preview_tokens_check — HOLED, inline
-- ============================================================================
-- Not a function: a bare CHECK comparing five jsonb keys to five columns.
-- `preview_tokens->>'light' = light_hex` is NULL when the key is absent, so
-- `preview_tokens = '{}'` was accepted and the catalog could publish a family
-- whose `preview_tokens` — the exact shape `brief_preview()` returns — was
-- empty. Lower blast radius than the others, since only a migration or
-- `service_role` writes this table, but it is the same defect and it is the
-- table every direction palette is built from.

alter table public.palette_families drop constraint if exists palette_families_preview_tokens_check;
alter table public.palette_families
  add constraint palette_families_preview_tokens_check check (
    preview_tokens ?& array['primary', 'secondary', 'light', 'dark', 'paper']
    and preview_tokens->>'primary'   = primary_hex
    and preview_tokens->>'secondary' = secondary_hex
    and preview_tokens->>'light'     = light_hex
    and preview_tokens->>'dark'      = dark_hex
    and preview_tokens->>'paper'     = paper_hex
  );


-- ============================================================================
-- 6. Re-validating the rows that were written while the hole was open
-- ============================================================================
-- ⚠ `create or replace function` DOES NOT re-check existing rows. The five
-- fixes above close the hole for every future write and leave anything already
-- stored exactly as it is. That is the whole reason this section exists: a row
-- written under the old validator is still there, and it is now the only way a
-- malformed palette can reach the seeder.
--
-- So the constraint is dropped and re-added, which forces a full validation
-- pass over `brand_kits`. Before that, the rows are counted and grouped by why
-- they would fail — because a migration that dies on `ALTER TABLE` tells you
-- that something is wrong and nothing about what.
--
-- If anything would fail, this migration STOPS with the counts and changes
-- nothing. Backfilling somebody's stored brand kit is a product decision, not
-- a schema decision, and it is not one a migration should make silently.

do $$
declare
  r          record;
  n_bad      int;
  n_kits     int;
  detail     text := '';
begin
  select count(*) into n_kits from public.brand_kits where directions is not null;

  -- Every direction of every kit, with the first reason it would now fail.
  create temporary table _palette_audit on commit drop as
  select bk.id as brand_kit_id,
         d.value->>'id' as direction_id,
         case
           when d.value->'palette' is null                    then 'palette key absent'
           when jsonb_typeof(d.value->'palette') <> 'object'  then 'palette is not an object'
           when not (d.value->'palette' ?& array['primary','secondary','light','dark','paper'])
             then 'missing role(s): ' || array_to_string(array(
                    select k from unnest(array['primary','secondary','light','dark','paper']) k
                     where not (d.value->'palette' ? k)), ', ')
           else 'a role is not a #RRGGBB hex'
         end as reason
    from public.brand_kits bk
    cross join lateral jsonb_array_elements(bk.directions) as d
   where bk.directions is not null
     and not public.brand_kit_palette_valid(d.value->'palette');

  select count(*) into n_bad from _palette_audit;

  raise notice 'palette audit: % brand_kits row(s) carry directions; % direction(s) would fail the tightened check.',
    n_kits, n_bad;

  if n_bad > 0 then
    for r in select reason, count(*) as n,
                    count(distinct brand_kit_id) as kits
               from _palette_audit group by reason order by 2 desc
    loop
      detail := detail || format(E'\n    %s direction(s) across %s kit(s): %s', r.n, r.kits, r.reason);
      raise notice '  % direction(s) across % kit(s): %', r.n, r.kits, r.reason;
    end loop;

    raise exception
      E'null_safe_validators: STOPPING. % direction(s) already stored would fail the tightened palette check:%\n\n  Nothing has been changed. Decide whether to backfill these rows or to gate the constraint, then re-run.',
      n_bad, detail;
  end if;

  -- Zero. Re-add the constraint so it validates what is already there, and so
  -- the catalog says the rule is enforced rather than merely declared.
  alter table public.brand_kits drop constraint if exists brand_kits_directions_shape_check;
  alter table public.brand_kits
    add constraint brand_kits_directions_shape_check
    check (public.brand_kit_directions_shape_valid(directions));

  raise notice 'palette audit: 0 rows affected; brand_kits_directions_shape_check re-validated.';
end
$$;


-- ============================================================================
-- 7. Guard rails — the hole is closed, and nothing well-formed moved
-- ============================================================================
do $$
declare
  wf   jsonb;
  fn   text;
  k    text;
  res  boolean;
begin
  -- ---- every validator now answers true or false, never NULL ---------------
  for fn, wf in
    select * from (values
      ('brand_kit_palette_valid',
       '{"primary":"#3B2C3A","secondary":"#4A5361","light":"#F3EDE4","dark":"#241B23","paper":"#FAF7F2"}'::jsonb),
      ('brand_kit_hero_valid',
       '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb),
      ('site_spec_hero_valid',
       '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb)
    ) t(a, b)
  loop
    -- well-formed still passes: no accept/reject decision changed
    execute format('select public.%I($1)', fn) into res using wf;
    if res is not true then
      raise exception 'null_safe_validators: % now rejects well-formed input.', fn;
    end if;

    -- and every degenerate input is now a hard false
    foreach k in array array['{}', 'null', '"x"', '42', '[]'] loop
      execute format('select public.%I($1)', fn) into res using k::jsonb;
      if res is distinct from false then
        raise exception 'null_safe_validators: %(%) returned %, expected false.',
          fn, k, coalesce(res::text, 'NULL');
      end if;
    end loop;

    for k in select jsonb_object_keys(wf) loop
      execute format('select public.%I($1)', fn) into res using (wf - k);
      if res is distinct from false then
        raise exception
          'null_safe_validators: % accepted input missing the key "%" (returned %).',
          fn, k, coalesce(res::text, 'NULL');
      end if;
    end loop;
  end loop;

  -- ---- section_type_fields_valid: the one predicate that leaked ------------
  if public.section_type_fields_valid('[{"key":"a","label":"A","max_length":10}]') is not false then
    raise exception 'null_safe_validators: a section field with no "kind" is still accepted.';
  end if;
  if public.section_type_fields_valid('[{"key":"a","label":"A","kind":"text","max_length":10}]') is not true then
    raise exception 'null_safe_validators: a well-formed section field is now rejected.';
  end if;
  -- and the catalog it guards still passes
  if exists (select 1 from public.section_types
              where not public.section_type_fields_valid(fields)) then
    raise exception 'null_safe_validators: a shipped section_types row no longer validates.';
  end if;

  -- ---- the propagation is closed too --------------------------------------
  -- A direction whose palette or hero is missing a key was accepted by
  -- `brand_kit_directions_shape_valid`, because `not NULL` is NULL and the
  -- offending element was never selected. Fixing the two leaf validators closes
  -- it without touching the caller.
  if public.brand_kit_directions_shape_valid(jsonb_build_array(
       jsonb_build_object('id','a','name','A','rationale','r',
         'palette','{}'::jsonb,
         'typography', jsonb_build_object('heading_font','F','body_font','B','google_fonts_url','u'),
         'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
         'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
       jsonb_build_object('id','b','name','B','rationale','r',
         'palette', jsonb_build_object('primary','#000000','secondary','#000000','light','#FFFFFF','dark','#000000','paper','#FFFFFF'),
         'typography', jsonb_build_object('heading_font','G','body_font','B','google_fonts_url','u'),
         'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
         'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
       jsonb_build_object('id','c','name','C','rationale','r',
         'palette', jsonb_build_object('primary','#000000','secondary','#000000','light','#FFFFFF','dark','#000000','paper','#FFFFFF'),
         'typography', jsonb_build_object('heading_font','H','body_font','B','google_fonts_url','u'),
         'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
         'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')))) is not false then
    raise exception
      'null_safe_validators: a direction with an empty palette is still accepted by the shape check.';
  end if;

  -- ---- and the shipped catalog still validates ----------------------------
  if exists (select 1 from public.palette_families
              where not public.brand_kit_palette_valid(preview_tokens)) then
    raise exception 'null_safe_validators: a shipped palette_families row no longer validates.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Reverting re-opens the hole. The bodies below are the originals.
--
--   create or replace function public.brand_kit_palette_valid(p jsonb)
--   returns boolean language sql immutable set search_path = '' as $fn$
--     select p is not null and jsonb_typeof(p) = 'object'
--        and p->>'primary' ~ '^#[0-9A-Fa-f]{6}$' and p->>'secondary' ~ '^#[0-9A-Fa-f]{6}$'
--        and p->>'light' ~ '^#[0-9A-Fa-f]{6}$'   and p->>'dark' ~ '^#[0-9A-Fa-f]{6}$'
--        and p->>'paper' ~ '^#[0-9A-Fa-f]{6}$'
--   $fn$;
--   -- (brand_kit_hero_valid, site_spec_hero_valid and section_type_fields_valid
--   --  likewise, from 20260827102000, 20260829100000 and 20260829101000)
--   alter table public.palette_families drop constraint if exists palette_families_preview_tokens_check;
--   alter table public.palette_families
--     add constraint palette_families_preview_tokens_check check (
--       preview_tokens->>'primary' = primary_hex and preview_tokens->>'secondary' = secondary_hex
--       and preview_tokens->>'light' = light_hex and preview_tokens->>'dark' = dark_hex
--       and preview_tokens->>'paper' = paper_hex);
