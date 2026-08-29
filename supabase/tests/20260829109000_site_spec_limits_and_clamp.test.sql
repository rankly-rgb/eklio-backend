-- ============================================================================
-- Tests — 20260829109000_site_spec_limits_and_clamp.sql
-- ============================================================================
-- The limits are published so the generator can respect them, and the clamp
-- stops being silent when it still fires.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- ⚠ Every published limit is the TRUE boundary of the constraint it came from
-- ---------------------------------------------------------------------------
-- The values are extracted by regex from `prosrc` and `pg_get_constraintdef`.
-- This is what makes that safe rather than a matter of trust: each number is
-- probed against the very validator it was read out of — n passes, n+1 does not.
do $$
declare
  lim jsonb := public.site_spec_limits();
  base jsonb := public.site_spec_default_pages(null, null);
  hero jsonb;
  k    text;
begin
  foreach k in array array['hero_overline','hero_headline','hero_subhead','hero_cta_label',
                           'about_excerpt','section_text','extra_instructions'] loop
    assert (lim->>k) is not null,
           format('%s was not extracted; the pattern no longer matches its constraint', k);
    assert (lim->>k)::int > 0, format('%s extracted as a non-positive number', k);
  end loop;

  -- hero: all four at their published value together
  assert public.site_spec_hero_lengths_valid(jsonb_build_object(
           'overline',  repeat('x', (lim->>'hero_overline')::int),
           'headline',  repeat('x', (lim->>'hero_headline')::int),
           'subhead',   repeat('x', (lim->>'hero_subhead')::int),
           'cta_label', repeat('x', (lim->>'hero_cta_label')::int))),
         'a hero at exactly the published limits was refused';

  -- and one over, field by field
  foreach k in array array['overline','headline','subhead','cta_label'] loop
    hero := jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c')
            || jsonb_build_object(k, repeat('x', (lim->>('hero_' || k))::int + 1));
    assert not public.site_spec_hero_lengths_valid(hero),
           format('hero_%s is published one character short of what is enforced', k);
  end loop;

  -- section text, probed through the walker that enforces it
  assert public.site_spec_pages_lengths_valid(jsonb_set(base, '{1,sections,1,fields,body}',
           to_jsonb(repeat('x', (lim->>'section_text')::int)))),
         'section_text is refused at its own published value';
  assert not public.site_spec_pages_lengths_valid(jsonb_set(base, '{1,sections,1,fields,body}',
           to_jsonb(repeat('x', (lim->>'section_text')::int + 1)))),
         'section_text is published one character short of what is enforced';
  -- and inside a list, where a per-field limit would have missed it
  assert not public.site_spec_pages_lengths_valid(jsonb_set(base, '{0,sections,2,fields,items}',
           jsonb_build_array('ok', repeat('x', (lim->>'section_text')::int + 1)))),
         'section_text is not enforced inside a list';
end
$$;

-- The two that come straight from a CHECK, probed against the table itself.
insert into auth.users (id,email) values ('aaaaaaaa-0000-0000-0000-000000000001','o@e.com');
insert into public.projects (id,user_id,name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','P');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000001');

-- ⚠ headline (46) and subhead (60) are ALREADY bounded upstream by
-- `brand_kit_directions_rendering_valid`, so they can never reach the seeder
-- over-long. The three that can are overline, cta_label and about_excerpt —
-- nothing in `brand_kits` bounds those.

-- ⚠ These tests exercise the PAID product. Since 20260829123000 the site spec
-- RPCs refuse an unentitled owner with `payment_required`, so the fixture has to
-- buy the kit like a real one does.
insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values
  ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','starter','cs_test_1',4900,'paid',now());

insert into public.brand_kits (id,project_id,directions,selected_direction_id) values (
 'cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
 jsonb_build_array(
  jsonb_build_object('id','a','name','Alpha One','rationale',repeat('x',70),
    'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object(
      'overline','LCSW, LICENSED CLINICAL SOCIAL WORKER · PORTLAND, OREGON · ACCEPTING NEW CLIENTS',
      'headline','A calmer place to start.',
      'subhead','Therapy for high-performing adults.',
      'cta_label','Book a first consultation with me today'),
    'about_excerpt', repeat('I work mostly with professionals who look fine from outside. ', 12),
    'tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','b','name','Beta Two','rationale',repeat('y',70),
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
    'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','Short enough to survive.','tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','c','name','Gamma Three','rationale',repeat('z',70),
    'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
    'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','Short enough to survive.','tone_keywords',jsonb_build_array('a','b','c'))),
 'a');

-- ---------------------------------------------------------------------------
-- The clamp is recorded, field by field
-- ---------------------------------------------------------------------------
do $$
declare
  s   public.site_specs%rowtype;
  lim jsonb := public.site_spec_limits();
begin
  select * into s from public.site_specs where brand_kit_id='cccccccc-0000-0000-0000-000000000001';

  assert s.seed_clamped is not null, 'the seeder shortened three fields and reported none';

  -- exactly the three that are not bounded upstream
  assert s.seed_clamped ? 'hero.overline',  'the clamped overline was not reported';
  assert s.seed_clamped ? 'hero.cta_label', 'the clamped CTA label was not reported';
  assert s.seed_clamped ? 'about_excerpt',  'the clamped About text was not reported';
  assert not (s.seed_clamped ? 'hero.headline'),
         'the headline is bounded upstream at 46 and cannot have been clamped';
  assert not (s.seed_clamped ? 'hero.subhead'),
         'the subhead is bounded upstream at 60 and cannot have been clamped';

  -- the numbers describe the actual cut
  assert (s.seed_clamped->'hero.overline'->>'original_length')::int = 80,
         'the reported original length is wrong';
  assert (s.seed_clamped->'hero.overline'->>'clamped_length')::int = char_length(s.hero->>'overline'),
         'the reported clamped length does not match the stored value';
  assert (s.seed_clamped->'hero.overline'->>'clamped_length')::int
         <= (lim->>'hero_overline')::int,
         'the clamped value is still over the published limit';
  assert (s.seed_clamped->'about_excerpt'->>'clamped_length')::int = char_length(s.about_excerpt),
         'the reported About length does not match the stored value';

  -- and every clamp genuinely shortened something
  assert not exists (
    select 1 from jsonb_each(s.seed_clamped) e
     where (e.value->>'clamped_length')::int >= (e.value->>'original_length')::int),
         'a "clamp" that did not shorten anything was reported';
end
$$;

-- Nothing clamped means NULL, not an empty object: the editor tests one thing.
do $$
begin
  insert into public.projects (id,user_id,name) values
    ('bbbbbbbb-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','Fits');
  insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000002');
  insert into public.purchases
    (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
  values ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002',
          'starter','cs_test_2',4900,'paid',now());
  insert into public.brand_kits (id,project_id,directions,selected_direction_id) values (
   'cccccccc-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002',
   jsonb_build_array(
    jsonb_build_object('id','a','name','Alpha One','rationale',repeat('x',70),
      'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','A calmer place to start.',
                                 'subhead','Therapy for adults.','cta_label','Book a consult'),
      'about_excerpt','Short.','tone_keywords',jsonb_build_array('a','b','c')),
    jsonb_build_object('id','b','name','Beta Two','rationale',repeat('y',70),
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
    jsonb_build_object('id','c','name','Gamma Three','rationale',repeat('z',70),
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c'))),
   'a');

  assert (select seed_clamped from public.site_specs
           where brand_kit_id='cccccccc-0000-0000-0000-000000000002') is null,
         'a direction that fits must report NULL, not an empty object';
end
$$;

-- An empty object is not a legal stored value.
do $$
declare ok boolean;
begin
  begin
    update public.site_specs set seed_clamped = '{}'::jsonb
     where brand_kit_id='cccccccc-0000-0000-0000-000000000002';
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'an empty clamp report was accepted; "nothing was clamped" must be NULL';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ The note is self-dismissing, per field
-- ---------------------------------------------------------------------------
-- "We shortened this when we set it up" stops being true the moment she
-- rewrites the field. Left standing it would be a permanent banner about a
-- decision she has already overridden.
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  e   jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';

  -- the envelope carries it
  e := public.site_spec_get(kit);
  assert e->'spec' ? 'seed_clamped', 'the envelope does not carry seed_clamped';
  assert e->'spec'->'seed_clamped' ? 'hero.cta_label', 'the note is missing from the envelope';

  -- editing the CTA label retires only that note
  e := public.site_spec_patch(kit, '{"hero":{"cta_label":"Book a consult"}}');
  assert not (e->'spec'->'seed_clamped' ? 'hero.cta_label'),
         'rewriting the CTA label did not retire its note';
  assert e->'spec'->'seed_clamped' ? 'hero.overline',
         'rewriting the CTA label retired the overline''s note as well';
  assert e->'spec'->'seed_clamped' ? 'about_excerpt',
         'rewriting the CTA label retired the About note as well';

  -- editing a colour retires nothing
  e := public.site_spec_patch(kit, '{"primary":"#22364F"}');
  assert e->'spec'->'seed_clamped' ? 'hero.overline',
         'a colour edit retired a copy note';

  -- ⚠ a reset of copy re-applies the SAME clamped text, so the note is still
  -- true and must survive
  e := public.site_spec_reset(kit, 'copy');
  assert e->'spec'->'seed_clamped' ? 'hero.overline',
         'resetting copy retired a note that is still true';

  -- clearing the last of them leaves NULL, not {}
  e := public.site_spec_patch(kit, jsonb_build_object(
         'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','cta_label','Book a consult'),
         'about_excerpt','My own words.'));
  assert e->'spec'->'seed_clamped' = 'null'::jsonb,
         'the last retired note left an empty object instead of NULL';

  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- The catalog publishes the limits
-- ---------------------------------------------------------------------------
do $$
declare
  c jsonb := public.site_catalog();
begin
  assert c ? 'site_spec_limits', 'GET /catalog does not carry site_spec_limits';
  assert c->'site_spec_limits' = public.site_spec_limits(),
         'the catalog and the extractor disagree';
  assert c->'site_spec_limits' ?& array['hero_overline','hero_headline','hero_subhead',
                                        'hero_cta_label','about_excerpt','section_text',
                                        'extra_instructions'],
         'a documented limit key is missing from the catalog payload';
  -- the two blocks delivered earlier are still there
  assert c ?& array['section_types','builder_targets'],
         'adding the limits dropped a catalog block';

  -- ⚠ TWO LIMIT SETS, AND THEY ARE NOT THE SAME NUMBERS. The generator that
  -- writes brand_kits.directions is bound by direction_limits; the editor the
  -- therapist types into is bound by site_spec_limits. Publishing only the
  -- second would tell the generator it has 90 characters of headline when the
  -- upstream CHECK allows 46 — and the refusal lands after the generation is
  -- paid for.
  assert c ? 'direction_limits', 'GET /catalog does not carry direction_limits';
  assert c->'direction_limits' = public.direction_limits(),
         'the catalog and the direction extractor disagree';
  assert (c->'direction_limits'->>'hero_headline')::int
       < (c->'site_spec_limits'->>'hero_headline')::int,
         'the direction headline bound is no longer tighter than the site spec one';
  assert (c->'direction_limits'->>'hero_subhead')::int
       < (c->'site_spec_limits'->>'hero_subhead')::int,
         'the direction subhead bound is no longer tighter than the site spec one';
  assert c->'direction_limits' ?& array['name','name_words_max','rationale_min',
                                        'rationale_max','hero_headline','hero_subhead',
                                        'tone_keywords_joined','tone_keywords_count',
                                        'directions_count'],
         'a documented direction limit key is missing from the catalog payload';

  -- and each direction bound is the real boundary of its own enforcer
  assert public.brand_kit_directions_rendering_valid(jsonb_build_array(
           jsonb_build_object('id','a','name','A','rationale', repeat('x', 70),
             'hero', jsonb_build_object('headline',
                       repeat('x', (c->'direction_limits'->>'hero_headline')::int),
                       'subhead', repeat('x', (c->'direction_limits'->>'hero_subhead')::int)),
             'tone_keywords', jsonb_build_array('a','b','c')))),
         'a direction at exactly the published limits was refused';
  assert not public.brand_kit_directions_rendering_valid(jsonb_build_array(
           jsonb_build_object('id','a','name','A','rationale', repeat('x', 70),
             'hero', jsonb_build_object('headline',
                       repeat('x', (c->'direction_limits'->>'hero_headline')::int + 1),
                       'subhead', 's'),
             'tone_keywords', jsonb_build_array('a','b','c')))),
         'the published direction headline bound is one character short of the truth';
end
$$;

rollback;
