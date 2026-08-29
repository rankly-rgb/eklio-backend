-- ============================================================================
-- Tests — 20260829100000_site_spec.sql
-- ============================================================================
-- Seeding from the chosen direction, its idempotence, every length limit at its
-- exact boundary, and the ownership cloisonnement.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000002','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Elm & Ember');
insert into public.project_briefs
  (project_id, practice_name, license_type_id, city, state, specialty_ids, client_persona_ids)
values
  ('bbbbbbbb-0000-0000-0000-000000000001','Elm & Ember Therapy','lcsw','Portland','OR',
   array['anxiety','burnout'], array['high_functioning']);

-- Three directions, exactly as the reveal writes them. The first palette is
-- deliberately lowercase: it arrives from a generator, not from the catalog.
insert into public.brand_kits (id, project_id, directions, site_prompt_target) values (
  'cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
  jsonb_build_array(
    jsonb_build_object('id','quiet_confidence','name','Quiet Confidence',
      'rationale','Restraint reads as experience. For clients who want steadiness more than warmth.',
      'palette', jsonb_build_object('primary','#3b2c3a','secondary','#4a5361','light','#f3ede4','dark','#241b23','paper','#faf7f2'),
      'typography', jsonb_build_object('heading_font','Cormorant Garamond','body_font','Source Sans 3',
        'google_fonts_url','https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&family=Source+Sans+3:wght@400;600;700&display=swap'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Experienced care, without the noise.',
        'subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
      'about_excerpt','I work mostly with professionals who look fine from outside.',
      'tone_keywords', jsonb_build_array('composed','credible','unhurried')),
    jsonb_build_object('id','warm_welcome','name','Warm Welcome',
      'rationale','Warmth without softness. It says the first call will be easier than they think.',
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=Fraunces&display=swap'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','A calmer place to start.',
        'subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('steady','plainspoken','warm')),
    jsonb_build_object('id','modern_calm','name','Modern Calm',
      'rationale','Structure signals a plan. For the client who needs to see how the work goes.',
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','Work Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=Newsreader&display=swap'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Therapy with a plan you can actually see.',
        'subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('clear','structured','direct'))),
  'squarespace');

-- ---------------------------------------------------------------------------
-- No direction chosen, no spec. Eklio does not design a site nobody picked.
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select count(*) from public.site_specs) = 0,
         'a kit with no chosen direction must not have a spec';
  assert public.seed_site_spec('cccccccc-0000-0000-0000-000000000001') = 0,
         'seeding a kit with no chosen direction must insert nothing';
end
$$;

-- ---------------------------------------------------------------------------
-- Choosing a direction seeds the spec, through the existing trigger
-- ---------------------------------------------------------------------------
update public.brand_kits set selected_direction_id = 'quiet_confidence'
 where id = 'cccccccc-0000-0000-0000-000000000001';

do $$
declare
  s public.site_specs%rowtype;
begin
  select * into s from public.site_specs
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000001';

  assert s.id is not null, 'choosing a direction must seed the site spec';
  assert s.user_id = 'aaaaaaaa-0000-0000-0000-000000000001',
         'the seeder must resolve the owner through the project';

  -- Four of the five palette roles line up with a token.
  assert s.primary_hex       = '#3B2C3A', 'primary comes from the direction palette';
  assert s.secondary_hex     = '#4A5361', 'secondary comes from the direction palette';
  assert s.light_neutral_hex = '#F3EDE4', 'light neutral comes from the palette light role';
  assert s.dark_neutral_hex  = '#241B23', 'dark neutral comes from the palette dark role';

  -- ⚠ Hex arrives lowercase from the generator and is stored uppercase, so
  -- that one spec renders one byte-identical output every time.
  assert s.primary_hex = upper(s.primary_hex), 'hex values must be stored uppercase';

  -- The direction carries no accent. It starts as a copy of the secondary, so
  -- the very first render is a complete, legible site.
  assert s.accent_hex = s.secondary_hex,
         'the accent must start as a copy of the secondary, which the direction has';

  assert s.heading_font    = 'Cormorant Garamond', 'the heading font comes from the direction';
  assert s.type_pairing_id = 'cormorant_source',
         'a direction whose two faces are a catalog pairing must resolve to it';

  assert s.hero->>'headline' = 'Experienced care, without the noise.',
         'the hero comes from the direction';
  assert s.hero->'cta_target_url' = 'null'::jsonb,
         'the booking link is never guessed at seed time';

  assert s.about_excerpt = 'I work mostly with professionals who look fine from outside.',
         'the About text comes from the direction';

  assert s.practice_details->>'practice_name' = 'Elm & Ember Therapy', 'from the brief';
  assert s.practice_details->>'license_label' = 'LCSW',                'from the brief';
  assert s.practice_details->>'city'          = 'Portland',            'from the brief';
  assert s.practice_details->'license_number' = 'null'::jsonb,
         'Eklio must never invent a license number';

  assert s.target = 'squarespace', 'the target comes from the kit''s existing builder';
  assert s.spec_version = 1,             'a fresh spec is version 1';
  assert s.last_copied_spec_version is null, 'a fresh spec has never been copied';

  -- Home carries the six sections the product spec names, in order.
  assert (select array_agg(sc.value->>'type' order by (sc.value->>'order')::int)
            from jsonb_array_elements(s.pages) pg
            cross join lateral jsonb_array_elements(pg.value->'sections') sc
           where pg.value->>'key' = 'home')
         = array['hero','intro','specialties','who_i_work_with','contact','footer'],
         'the default home structure drifted from the product spec';
  assert (select count(*) from jsonb_array_elements(s.pages)) = 4,
         'about, services and contact must exist alongside home';

  -- The brief's answers are poured into the sections that render them.
  assert (select sc.value->'fields'->'items'
            from jsonb_array_elements(s.pages) pg
            cross join lateral jsonb_array_elements(pg.value->'sections') sc
           where pg.value->>'key' = 'home' and sc.value->>'type' = 'specialties')
         = '["Anxiety", "Burnout"]'::jsonb,
         'the specialty chips must come from the brief';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ Re-selecting a direction never silently overwrites her edits
-- ---------------------------------------------------------------------------
do $$
declare
  before_version int;
begin
  update public.site_specs set primary_hex = '#123456', about_excerpt = 'My own words.'
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000001';
  select spec_version into before_version from public.site_specs
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000001';

  assert public.seed_site_spec('cccccccc-0000-0000-0000-000000000001') = 0,
         're-seeding must insert nothing';
  assert public.seed_site_spec('cccccccc-0000-0000-0000-000000000001') = 0,
         're-seeding twice must still insert nothing';

  -- and neither must switching to another direction
  update public.brand_kits set selected_direction_id = 'warm_welcome'
   where id = 'cccccccc-0000-0000-0000-000000000001';

  assert (select primary_hex from public.site_specs
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000001') = '#123456',
         'choosing another direction silently overwrote an edit';
  assert (select about_excerpt from public.site_specs
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000001') = 'My own words.',
         'choosing another direction silently overwrote her copy';
  assert (select count(*) from public.site_specs
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000001') = 1,
         're-selection produced a second spec';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ Seeding must never be able to break direction selection
-- ---------------------------------------------------------------------------
-- The seeder runs in the AFTER trigger on `selected_direction_id`. A CHECK it
-- violates does not fail the seed, it rolls back the CHOICE. Nothing upstream
-- bounds a direction's overline or CTA label, so the clamping is what stands
-- between a legal direction and one the therapist simply cannot pick.
do $$
declare
  d jsonb;
begin
  insert into public.projects (id, user_id, name) values
    ('bbbbbbbb-0000-0000-0000-000000000009','aaaaaaaa-0000-0000-0000-000000000001','Extreme');

  d := jsonb_build_array(
    jsonb_build_object('id','a','name','Alpha One',
      'rationale', repeat('x', 70),
      'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
      -- fonts a generator may legally emit but the catalog does not carry,
      -- with no loadable stylesheet at all
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url',''),
      'hero', jsonb_build_object(
        'overline',  repeat('overline ', 40),   -- nothing upstream bounds this
        'headline',  'Short enough.',
        'subhead',   'Also short.',
        'cta_label', repeat('label ', 30)),     -- nor this
      'about_excerpt', repeat('long ', 400),    -- nor this
      'tone_keywords', jsonb_build_array('a','b','c')),
    jsonb_build_object('id','b','name','Beta Two','rationale', repeat('y', 70),
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
    jsonb_build_object('id','c','name','Gamma Three','rationale', repeat('z', 70),
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')));

  insert into public.brand_kits (id, project_id, directions) values
    ('cccccccc-0000-0000-0000-000000000009','bbbbbbbb-0000-0000-0000-000000000009', d);

  -- This is the assertion. If the clamping is removed, this UPDATE raises.
  update public.brand_kits set selected_direction_id = 'a'
   where id = 'cccccccc-0000-0000-0000-000000000009';

  assert (select count(*) from public.site_specs
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000009') = 1,
         'an extreme but legal direction must still seed a spec';
  assert (select char_length(hero->>'overline') from public.site_specs
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000009') <= 48,
         'the overline was not clamped';
  assert (select char_length(hero->>'cta_label') from public.site_specs
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000009') <= 28,
         'the CTA label was not clamped';
  assert (select char_length(about_excerpt) from public.site_specs
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000009') <= 600,
         'the About text was not clamped';
  assert (select google_fonts_url from public.site_specs
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000009')
         = (select google_fonts_url from public.type_pairings where id = 'fraunces_nunito'),
         'a direction with no stylesheet must fall back to the catalog''s';
end
$$;

-- ---------------------------------------------------------------------------
-- Every length limit, at its exact boundary
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  ok  boolean;
  cases text[][] := array[
    ['overline',  '48'], ['headline', '90'], ['subhead', '220'], ['cta_label', '28']
  ];
  i int;
  lim int;
begin
  for i in 1 .. array_length(cases, 1) loop
    lim := cases[i][2]::int;

    -- exactly at the limit passes
    update public.site_specs
       set hero = jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c')
                  || jsonb_build_object(cases[i][1], repeat('x', lim))
     where brand_kit_id = kit;

    -- one over is refused
    begin
      update public.site_specs
         set hero = jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c')
                    || jsonb_build_object(cases[i][1], repeat('x', lim + 1))
       where brand_kit_id = kit;
      ok := false;
    exception when check_violation then ok := true; end;
    assert ok, format('hero.%s accepted %s characters; the limit is %s',
                      cases[i][1], lim + 1, lim);
  end loop;

  update public.site_specs set about_excerpt = repeat('x', 600) where brand_kit_id = kit;
  begin
    update public.site_specs set about_excerpt = repeat('x', 601) where brand_kit_id = kit;
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'about_excerpt accepted 601 characters; the limit is 600';

  update public.site_specs set extra_instructions = repeat('x', 2000) where brand_kit_id = kit;
  begin
    update public.site_specs set extra_instructions = repeat('x', 2001) where brand_kit_id = kit;
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'extra_instructions accepted 2001 characters; the limit is 2000';
end
$$;

-- Any section text field, whether it is a plain field or an item of a list.
do $$
declare
  kit  uuid := 'cccccccc-0000-0000-0000-000000000001';
  base jsonb;
  ok   boolean;
begin
  base := public.site_spec_default_pages(array['Anxiety'], array['Adults']);

  update public.site_specs
     set pages = jsonb_set(base, '{1,sections,1,fields,body}', to_jsonb(repeat('x', 800)))
   where brand_kit_id = kit;

  begin
    update public.site_specs
       set pages = jsonb_set(base, '{1,sections,1,fields,body}', to_jsonb(repeat('x', 801)))
     where brand_kit_id = kit;
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'a section text field accepted 801 characters; the limit is 800';

  -- ⚠ and inside a list, which is where a per-field limit would have missed it
  begin
    update public.site_specs
       set pages = jsonb_set(base, '{0,sections,2,fields,items}',
                             jsonb_build_array('short', repeat('x', 801)))
     where brand_kit_id = kit;
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'a list item accepted 801 characters; the limit is 800';

  update public.site_specs set pages = base where brand_kit_id = kit;
end
$$;

-- ---------------------------------------------------------------------------
-- The call-to-action link is printed into a document meant to be pasted
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  ok  boolean;
  bad text;
begin
  foreach bad in array array['javascript:alert(1)', 'data:text/html,<script>',
                             'file:///etc/passwd', 'notaurl'] loop
    begin
      update public.site_specs
         set hero = hero || jsonb_build_object('cta_target_url', bad)
       where brand_kit_id = kit;
      ok := false;
    exception when check_violation then ok := true; end;
    assert ok, format('the call-to-action target accepted %s', bad);
  end loop;

  -- the four shapes a real booking link takes
  foreach bad in array array['https://example.simplepractice.com/book',
                             'http://calendly.com/nora',
                             'mailto:hello@elmandember.com',
                             'tel:+15035550123'] loop
    update public.site_specs
       set hero = hero || jsonb_build_object('cta_target_url', bad)
     where brand_kit_id = kit;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Structure: known keys, known types, unique section keys
-- ---------------------------------------------------------------------------
do $$
declare
  kit  uuid := 'cccccccc-0000-0000-0000-000000000001';
  base jsonb := public.site_spec_default_pages(null, null);
  ok   boolean;
begin
  begin
    update public.site_specs set pages = jsonb_set(base, '{0,key}', '"blog"'::jsonb)
     where brand_kit_id = kit;
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'an unknown page key was accepted';

  begin
    update public.site_specs set pages = jsonb_set(base, '{0,sections,0,type}', '"testimonials"'::jsonb)
     where brand_kit_id = kit;
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'an unknown section type was accepted';

  -- two sections sharing a key inside one page make an edit ambiguous
  begin
    update public.site_specs set pages = jsonb_set(base, '{0,sections,1,key}', '"hero"'::jsonb)
     where brand_kit_id = kit;
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'two sections with the same key in one page were accepted';

  update public.site_specs set pages = base where brand_kit_id = kit;
end
$$;

-- ---------------------------------------------------------------------------
-- Ownership: a second user gets zero rows, not a permission error
-- ---------------------------------------------------------------------------
do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002"}';

  assert (select count(*) from public.site_specs) = 0,
         'a stranger must see zero specs, not an error';

  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
  assert (select count(*) from public.site_specs) = 2,
         'the owner must see her own specs';
  reset role;
end
$$;

-- INSERT and DELETE are refused outright: a spec is created by the seeder and
-- dies with its kit. It is not a document the user makes or throws away.
do $$
declare
  ok boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';

  begin
    insert into public.site_specs
      (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
       light_neutral_hex, dark_neutral_hex, heading_font, body_font, google_fonts_url,
       hero, pages)
    values ('cccccccc-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
            '#000000','#000000','#000000','#FFFFFF','#000000','A','B','u',
            '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb,
            public.site_spec_default_pages(null, null));
    ok := false;
  exception when insufficient_privilege then ok := true;
            when unique_violation then ok := true; end;
  assert ok, 'a client was able to insert a site spec';

  begin
    delete from public.site_specs;
    ok := (select count(*) from public.site_specs) = 2;
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client was able to delete a site spec';

  -- ⚠ RLS says which rows; column privileges say which columns. A
  -- client-chosen spec_version would let a stale editor silently win.
  begin
    update public.site_specs set spec_version = 99;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client was able to write spec_version directly';

  begin
    update public.site_specs set brand_kit_id = 'cccccccc-0000-0000-0000-000000000009';
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client was able to move a spec to another brand kit';

  reset role;
end
$$;

rollback;
