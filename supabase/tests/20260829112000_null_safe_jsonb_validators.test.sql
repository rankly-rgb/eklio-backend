-- ============================================================================
-- Tests — 20260829112000_null_safe_jsonb_validators.sql
-- ============================================================================
-- A CHECK constraint accepts a row when its expression is TRUE **or NULL**. Any
-- validator that can return NULL is therefore not a constraint, it is a
-- suggestion. This file asserts that none of them can.
--
-- ⚠ IT IS PARAMETERIZED ON THE CATALOG, NOT ON A HAND-WRITTEN LIST. The set of
-- validators is discovered from `pg_proc` — every boolean function in `public`
-- taking a single jsonb argument — so a validator added later without this
-- coverage fails here instead of shipping with the same hole. The two lists at
-- the bottom (`registry` and `permissive`) are the only place a new validator
-- has to be acknowledged, and forgetting is what this file catches.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. Discovery: no single-jsonb boolean validator may be unaccounted for
-- ---------------------------------------------------------------------------
create temporary table validator_registry (fn text primary key, wellformed jsonb);

-- Validators with a REQUIRED key set. For these, every degenerate input and
-- every single-key omission must be refused.
insert into validator_registry values
  ('brand_kit_palette_valid',
   '{"primary":"#3B2C3A","secondary":"#4A5361","light":"#F3EDE4","dark":"#241B23","paper":"#FAF7F2"}'),
  ('brand_kit_hero_valid',
   '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'),
  ('site_spec_hero_valid',
   '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'),
  ('brand_kit_voice_guide_valid',
   '{"sounds_like":["a","b","c"],"never_write":["d","e","f"]}'),
  ('brand_kit_ethics_check_valid',
   '{"passed":true,"flagged":[],"checked_at":"2026-08-29"}');

-- Validators that answer TRUE for input another constraint is responsible for
-- rejecting. That is this repo's "two constraints per column, one role each":
-- a length check does not re-litigate shape, so that a rejected write names the
-- rule it broke. They are still held to never returning NULL.
create temporary table permissive_validators (fn text primary key);
insert into permissive_validators values
  ('site_spec_hero_lengths_valid'),
  ('site_spec_pages_lengths_valid'),
  ('site_spec_cta_target_url_valid'),
  ('site_spec_practice_details_valid'),
  ('brand_kit_directions_rendering_valid'),
  ('brand_kit_social_templates_rendering_valid');

-- Validators whose argument is an array or which have their own coverage
-- elsewhere in the suite; still held to never returning NULL.
create temporary table array_validators (fn text primary key);
insert into array_validators values
  ('brand_kit_directions_shape_valid'),
  ('brand_kit_directions_contrasted'),
  ('brand_kit_social_templates_shape_valid'),
  ('section_type_fields_valid'),
  ('site_spec_pages_valid'),
  ('site_spec_seed_clamped_valid');

do $$
declare
  missing text;
begin
  -- ⚠ THE ASSERTION THAT KEEPS THIS FILE HONEST. Every boolean, single-jsonb
  -- function in public must appear in exactly one of the three lists above.
  select string_agg(p.proname, ', ') into missing
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and pg_get_function_result(p.oid) = 'boolean'
     and pg_get_function_arguments(p.oid) ~ '^p\w* jsonb$'
     and p.proname not in (select fn from validator_registry)
     and p.proname not in (select fn from permissive_validators)
     and p.proname not in (select fn from array_validators);

  assert missing is null,
    format('validator(s) with no NULL-safety coverage: %s. Add each to validator_registry (required keys), permissive_validators (delegates to another constraint) or array_validators, and make sure it cannot return NULL.', missing);
end
$$;

-- ---------------------------------------------------------------------------
-- 2. ⚠ NOT ONE of them may return NULL, for any degenerate input
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn text;
  bad  text;
  res  boolean;
begin
  for v_fn in select t.f from (
              select r.fn as f from validator_registry r
              union all select p.fn from permissive_validators p
              union all select a.fn from array_validators a) t
  loop
    foreach bad in array array['{}', 'null', '"x"', '42', 'true', '[]', '[1,2]'] loop
      execute format('select public.%I($1)', v_fn) into res using bad::jsonb;
      assert res is not null,
        format('%s(%s) returned NULL. A CHECK constraint ACCEPTS on NULL, so this validator is not enforcing anything.',
               v_fn, bad);
    end loop;
    -- and a SQL NULL argument, which is what an empty nullable column gives it
    execute format('select public.%I($1)', v_fn) into res using null::jsonb;
    assert res is not null or v_fn = any (array[
             -- these three document NULL-in/NULL-out for a nullable column, and
             -- a NULL column value never reaches a CHECK as a row rejection
             'brand_kit_directions_shape_valid','brand_kit_directions_contrasted',
             'brand_kit_social_templates_shape_valid']),
      format('%s(NULL) returned NULL unexpectedly', v_fn);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Required-key validators: every single omission is refused
-- ---------------------------------------------------------------------------
do $$
declare
  r   record;
  k   text;
  res boolean;
begin
  for r in select * from validator_registry loop
    -- well-formed still passes — no accept/reject decision moved
    execute format('select public.%I($1)', r.fn) into res using r.wellformed;
    assert res is true, format('%s now rejects well-formed input', r.fn);

    -- empty object
    execute format('select public.%I($1)', r.fn) into res using '{}'::jsonb;
    assert res is false, format('%s accepted an empty object', r.fn);

    -- jsonb null and scalars
    foreach k in array array['null', '"x"', '42', '[]'] loop
      execute format('select public.%I($1)', r.fn) into res using k::jsonb;
      assert res is false, format('%s accepted %s', r.fn, k);
    end loop;

    -- ⚠ each required key removed in turn
    for k in select jsonb_object_keys(r.wellformed) loop
      execute format('select public.%I($1)', r.fn) into res using (r.wellformed - k);
      assert res is false,
        format('%s accepted input missing the required key "%s" (returned %s)',
               r.fn, k, coalesce(res::text, 'NULL'));
    end loop;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 4. The propagation, closed at the leaves
-- ---------------------------------------------------------------------------
-- `brand_kit_directions_shape_valid` delegates palette and hero to the two
-- validators that were holed. `not NULL` is NULL, so the offending element was
-- never selected by the `where`, so `not exists` was true, so the whole array
-- was accepted. Fixing the leaves closes the caller without touching it.
do $$
declare
  ok jsonb := jsonb_build_object(
    'primary','#000000','secondary','#000000','light','#FFFFFF','dark','#000000','paper','#FFFFFF');
  function_of_three jsonb;
begin
  function_of_three := jsonb_build_array(
    jsonb_build_object('id','a','name','A','rationale','r','palette',ok,
      'typography', jsonb_build_object('heading_font','F','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
    jsonb_build_object('id','b','name','B','rationale','r','palette',ok,
      'typography', jsonb_build_object('heading_font','G','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
    jsonb_build_object('id','c','name','C','rationale','r','palette',ok,
      'typography', jsonb_build_object('heading_font','H','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')));

  assert public.brand_kit_directions_shape_valid(function_of_three) is true,
         'the well-formed three-direction array is now rejected';

  -- every palette role, removed from the first direction in turn
  foreach function_of_three in array array[function_of_three] loop null; end loop;
  for ok in select jsonb_build_object('k', k) from unnest(array['primary','secondary','light','dark','paper']) k loop
    assert public.brand_kit_directions_shape_valid(
             jsonb_set(function_of_three, '{0,palette}',
                       (function_of_three->0->'palette') - (ok->>'k'))) is false,
      format('a direction whose palette is missing "%s" is still accepted', ok->>'k');
  end loop;

  -- and every hero key
  for ok in select jsonb_build_object('k', k) from unnest(array['overline','headline','subhead','cta_label']) k loop
    assert public.brand_kit_directions_shape_valid(
             jsonb_set(function_of_three, '{0,hero}',
                       (function_of_three->0->'hero') - (ok->>'k'))) is false,
      format('a direction whose hero is missing "%s" is still accepted', ok->>'k');
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 5. section_type_fields_valid: the one predicate out of five that leaked
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.section_type_fields_valid(
           '[{"key":"a","label":"A","kind":"text","max_length":10}]') is true,
         'a well-formed field declaration is now rejected';
  -- `not (kind = any(...))` was NULL for a missing kind, so the field vanished
  -- from the `where` and the row was accepted
  assert public.section_type_fields_valid(
           '[{"key":"a","label":"A","max_length":10}]') is false,
         'a field with no "kind" is still accepted';
  assert public.section_type_fields_valid(
           '[{"key":"a","label":"A","kind":null,"max_length":10}]') is false,
         'a field whose "kind" is JSON null is still accepted';
  -- the four predicates that were already NULL-safe still behave
  assert public.section_type_fields_valid(
           '[{"key":"a","label":"A","kind":"text"}]') is false,
         'a field with no max_length must stay refused';
  assert public.section_type_fields_valid(
           '[{"key":"a","label":"A","kind":"text","max_length":900}]') is false,
         'a field advertising more than the write path accepts must stay refused';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. The inline catalog constraint, and the tables themselves
-- ---------------------------------------------------------------------------
do $$
declare ok boolean;
begin
  -- palette_families.preview_tokens = '{}' was accepted: five NULL comparisons
  begin
    update public.palette_families set preview_tokens = '{}'::jsonb where id = 'clay_sand';
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'palette_families.preview_tokens = {} is still accepted';

  begin
    update public.palette_families
       set preview_tokens = preview_tokens - 'light' where id = 'clay_sand';
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'palette_families.preview_tokens missing a role is still accepted';

  -- and every shipped row still validates
  assert not exists (select 1 from public.palette_families
                      where not public.brand_kit_palette_valid(preview_tokens)),
         'a shipped palette_families row no longer validates';
  assert not exists (select 1 from public.section_types
                      where not public.section_type_fields_valid(fields)),
         'a shipped section_types row no longer validates';
end
$$;

-- End to end on the two tables the holes actually reached.
insert into auth.users (id,email) values ('aaaaaaaa-0000-0000-0000-000000000001','o@e.com');
insert into public.projects (id,user_id,name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','P');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000001');

do $$
declare
  ok  boolean;
  d3  jsonb;
begin
  d3 := jsonb_build_array(
    jsonb_build_object('id','a','name','Alpha One','rationale',repeat('x',70),
      'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
    jsonb_build_object('id','b','name','Beta Two','rationale',repeat('y',70),
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
    jsonb_build_object('id','c','name','Gamma Three','rationale',repeat('z',70),
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')));

  -- the well-formed kit still writes
  insert into public.brand_kits (id, project_id, directions, selected_direction_id)
  values ('cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001', d3, 'a');

  -- ⚠ site_specs.hero = '{}' was accepted and rendered an empty hero
  begin
    update public.site_specs set hero = '{}'::jsonb
     where brand_kit_id = 'cccccccc-0000-0000-0000-000000000001';
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'site_specs.hero = {} is still accepted; the mockup would render an empty hero';

  begin
    update public.site_specs set hero = hero - 'headline'
     where brand_kit_id = 'cccccccc-0000-0000-0000-000000000001';
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'site_specs.hero missing a key is still accepted';
end
$$;

rollback;
