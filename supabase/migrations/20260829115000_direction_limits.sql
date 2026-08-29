-- ============================================================================
-- Eklio — two limit sets, because two different things are being bounded
-- ============================================================================
-- Follows `20260829114000_palette_accent.sql`.
--
-- THE TRAP IN PUBLISHING ONE BLOCK
-- --------------------------------
-- `site_spec_limits` says `hero_headline: 90` and `hero_subhead: 220`. Those
-- are true — of the SITE SPEC, which is what the therapist types into after the
-- kit exists.
--
-- They are not true of a DIRECTION. `brand_kit_directions_rendering_valid`
-- bounds a direction's headline at 46 and its subhead at 60, because the reveal
-- renders three of them side by side in a fixed 250px mockup and 47 characters
-- breaks the grid. The frontend owns the LLM call that produces directions and
-- reads the catalog to bound generation — and the natural reading of a single
-- block called "the site spec limits" is that 90 is allowed. Every direction
-- generated at 80 characters would then be refused by the upstream CHECK, after
-- the generation was paid for.
--
-- So there are two blocks, and each says who reads it:
--
--   direction_limits  — what the GENERATOR must respect when producing
--                       `brand_kits.directions`. Enforced by
--                       `brand_kit_directions_rendering_valid` and by the
--                       tone-keyword rules beside it.
--   site_spec_limits  — what the EDITOR must respect when the therapist types.
--                       Enforced by the CHECKs on `site_specs`.
--
-- ⚠ THE DIRECTION LIMITS ARE THE TIGHTER PAIR, and that is not a mistake to be
-- reconciled. A direction is copy shown three-up on a reveal screen; a site
-- spec is copy shown once on a page. The site spec is seeded from the direction
-- and then clamped upward-compatible — 46 fits inside 90 — so nothing is lost
-- going one way, and the generator simply has less room than the editor does.
--
-- Same extraction discipline as `site_spec_limits`: every number is read out of
-- the validator that enforces it, and the guard rail PROBES that validator to
-- prove the published number is the true boundary.
-- ============================================================================


-- ============================================================================
-- 1. direction_limits
-- ============================================================================
-- All five come from `brand_kit_directions_rendering_valid`'s own source. The
-- rationale bound is a range, so both ends are published: a rationale under 60
-- characters reads as a label and leaves the card looking empty, which is an
-- editorial rule the CHECK actually enforces.

create or replace function public.direction_limits()
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select jsonb_build_object(
    'name',            (select (substring(p.prosrc from 'char_length\(d\.value->>''name''\) > (\d+)'))::int
                          from pg_catalog.pg_proc p
                         where p.oid = 'public.brand_kit_directions_rendering_valid(jsonb)'::regprocedure),
    'name_words_max',  (select (substring(p.prosrc from 'not between 1 and (\d+)'))::int
                          from pg_catalog.pg_proc p
                         where p.oid = 'public.brand_kit_directions_rendering_valid(jsonb)'::regprocedure),
    'rationale_min',   (select (substring(p.prosrc from 'char_length\(d\.value->>''rationale''\) not between (\d+) and \d+'))::int
                          from pg_catalog.pg_proc p
                         where p.oid = 'public.brand_kit_directions_rendering_valid(jsonb)'::regprocedure),
    'rationale_max',   (select (substring(p.prosrc from 'char_length\(d\.value->>''rationale''\) not between \d+ and (\d+)'))::int
                          from pg_catalog.pg_proc p
                         where p.oid = 'public.brand_kit_directions_rendering_valid(jsonb)'::regprocedure),
    'hero_headline',   (select (substring(p.prosrc from 'char_length\(d\.value->''hero''->>''headline''\) > (\d+)'))::int
                          from pg_catalog.pg_proc p
                         where p.oid = 'public.brand_kit_directions_rendering_valid(jsonb)'::regprocedure),
    'hero_subhead',    (select (substring(p.prosrc from 'char_length\(d\.value->''hero''->>''subhead''\)  > (\d+)'))::int
                          from pg_catalog.pg_proc p
                         where p.oid = 'public.brand_kit_directions_rendering_valid(jsonb)'::regprocedure),
    'tone_keywords_joined',
                       -- anchored on the closing parens of the string_agg
                       -- subquery: the text between them contains `->`, so a
                       -- [^>]* span cannot reach across it
                       (select (substring(p.prosrc from 'as k\)\s*\)\s*> (\d+)'))::int
                          from pg_catalog.pg_proc p
                         where p.oid = 'public.brand_kit_directions_rendering_valid(jsonb)'::regprocedure),
    'tone_keywords_count', 3,
    'directions_count',    3
  )
$$;

comment on function public.direction_limits() is
  'What the generator in eklio-frontend must respect when producing brand_kits.directions, extracted from brand_kit_directions_rendering_valid rather than restated. TIGHTER than site_spec_limits: a direction is rendered three-up on the reveal.';


-- ============================================================================
-- 2. Both blocks in the catalog, each labelled with its consumer
-- ============================================================================
create or replace function public.site_catalog()
returns jsonb
language sql
stable
security invoker
set search_path = ''
set jit = 'off'
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
        from public.builder_targets bt), '[]'::jsonb),
    -- what the generator must respect when it writes brand_kits.directions
    'direction_limits', public.direction_limits(),
    -- what the editor must respect when the therapist types
    'site_spec_limits', public.site_spec_limits()
  )
$$;

grant execute on function public.direction_limits() to authenticated, service_role;


-- ============================================================================
-- 3. Guard rails
-- ============================================================================
do $$
declare
  lim  jsonb := public.direction_limits();
  spec jsonb := public.site_spec_limits();
  ok   jsonb;
  k    text;
begin
  -- ---- everything was extracted -------------------------------------------
  foreach k in array array['name','name_words_max','rationale_min','rationale_max',
                           'hero_headline','hero_subhead','tone_keywords_joined'] loop
    if (lim->>k) is null then
      raise exception
        'direction_limits: % was not extracted; the pattern no longer matches brand_kit_directions_rendering_valid. Got %', k, lim;
    end if;
  end loop;

  -- a well-formed three-direction array, used as the probe base
  ok := jsonb_build_array(
    jsonb_build_object('id','a','name','Alpha One','rationale', repeat('x', (lim->>'rationale_max')::int),
      'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o',
        'headline', repeat('x', (lim->>'hero_headline')::int),
        'subhead',  repeat('x', (lim->>'hero_subhead')::int), 'cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('aa','bb','cc')),
    jsonb_build_object('id','b','name','Beta Two','rationale', repeat('y', (lim->>'rationale_max')::int),
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('aa','bb','cc')),
    jsonb_build_object('id','c','name','Gamma Three','rationale', repeat('z', (lim->>'rationale_max')::int),
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('aa','bb','cc')));

  -- ---- ⚠ each published number PROBED against its own validator -----------
  if not public.brand_kit_directions_rendering_valid(ok) then
    raise exception 'direction_limits: a direction at exactly the published limits was refused.';
  end if;

  if public.brand_kit_directions_rendering_valid(
       jsonb_set(ok, '{0,hero,headline}', to_jsonb(repeat('x', (lim->>'hero_headline')::int + 1)))) then
    raise exception 'direction_limits: hero_headline is published one character short of the truth.';
  end if;
  if public.brand_kit_directions_rendering_valid(
       jsonb_set(ok, '{0,hero,subhead}', to_jsonb(repeat('x', (lim->>'hero_subhead')::int + 1)))) then
    raise exception 'direction_limits: hero_subhead is published one character short of the truth.';
  end if;
  if public.brand_kit_directions_rendering_valid(
       jsonb_set(ok, '{0,rationale}', to_jsonb(repeat('x', (lim->>'rationale_max')::int + 1)))) then
    raise exception 'direction_limits: rationale_max is published one character short of the truth.';
  end if;
  if public.brand_kit_directions_rendering_valid(
       jsonb_set(ok, '{0,rationale}', to_jsonb(repeat('x', (lim->>'rationale_min')::int - 1)))) then
    raise exception 'direction_limits: rationale_min is published one character above the truth.';
  end if;
  if public.brand_kit_directions_rendering_valid(
       jsonb_set(ok, '{0,name}', to_jsonb(repeat('x', (lim->>'name')::int + 1)))) then
    raise exception 'direction_limits: name is published one character short of the truth.';
  end if;
  -- the joined tone-keyword label
  if public.brand_kit_directions_rendering_valid(
       jsonb_set(ok, '{0,tone_keywords}',
                 jsonb_build_array(repeat('a', (lim->>'tone_keywords_joined')::int), 'b', 'c'))) then
    raise exception 'direction_limits: tone_keywords_joined is published above the truth.';
  end if;

  -- ---- ⚠ THE WHOLE POINT: the two blocks disagree, and must ---------------
  if (lim->>'hero_headline')::int >= (spec->>'hero_headline')::int then
    raise exception
      'direction_limits: the direction headline bound (%) is no longer tighter than the site spec bound (%). If they have converged, one of the two enforcers moved and the split needs revisiting.',
      lim->>'hero_headline', spec->>'hero_headline';
  end if;
  if (lim->>'hero_subhead')::int >= (spec->>'hero_subhead')::int then
    raise exception
      'direction_limits: the direction subhead bound (%) is no longer tighter than the site spec bound (%).',
      lim->>'hero_subhead', spec->>'hero_subhead';
  end if;

  -- ---- both blocks reach the catalog, and neither replaced the other ------
  if not (public.site_catalog() ?& array['section_types','builder_targets',
                                         'direction_limits','site_spec_limits']) then
    raise exception 'direction_limits: GET /catalog is missing a documented block.';
  end if;
  if public.site_catalog()->'direction_limits' <> lim
     or public.site_catalog()->'site_spec_limits' <> spec then
    raise exception 'direction_limits: the catalog and the extractors disagree.';
  end if;

  raise notice 'direction limits: headline %, subhead %, name %, rationale %-%, tone keywords joined %',
    lim->>'hero_headline', lim->>'hero_subhead', lim->>'name',
    lim->>'rationale_min', lim->>'rationale_max', lim->>'tone_keywords_joined';
  raise notice 'site spec limits: headline %, subhead %, overline %, cta %, about %, section %, notes %',
    spec->>'hero_headline', spec->>'hero_subhead', spec->>'hero_overline',
    spec->>'hero_cta_label', spec->>'about_excerpt', spec->>'section_text',
    spec->>'extra_instructions';
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_catalog() from 20260829109000 (site_spec_limits only),
--   -- WITH its `set jit = 'off'` clause, then:
--   drop function if exists public.direction_limits();
