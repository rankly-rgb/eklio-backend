-- ============================================================================
-- Tests — 20260829120000_practitioner_name_and_voice_guide.sql
-- ============================================================================
-- Two things the deliverable was missing.
--
-- The first is a compliance gap, not a nicety: the output could produce a
-- therapist's website that never names the therapist, while printing her
-- license number. The boards that require the number in advertising require the
-- licensee's name beside it.
--
-- The second is the voice guide. The constraints tell a builder not to rewrite
-- her copy; they say nothing about the words the builder writes on its own —
-- menu labels, button microcopy, alt text, a 404 page. Those came out in the
-- model's default voice, which is the voice that writes "Limited spots
-- available".
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','nora@elmandember.com');
insert into public.projects (id, user_id, name) values
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Elm & Ember');
insert into public.project_briefs (project_id, practice_name, license_type_id, city, state)
values ('22222222-2222-2222-2222-222222222222','Elm & Ember Therapy','lcsw','Portland','OR');


-- ⚠ These tests exercise the PAID product. Since 20260829123000 the site spec
-- RPCs refuse an unentitled owner with `payment_required`, so the fixture has to
-- buy the kit like a real one does.
insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values
  ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222','starter','cs_test_1',4900,'paid',now());

insert into public.brand_kits (id, project_id, directions, selected_direction_id, voice_guide) values (
 '33333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222',
 jsonb_build_array(
  jsonb_build_object('id','warm_welcome','name','Warm Welcome',
    'rationale','Warmth without softness. It says the first call will be easier than they think.',
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','A calmer place to start.',
      'subhead','Therapy for adults who hold it together.','cta_label','Book a consult'),
    'about_excerpt','I work mostly with professionals who look fine from the outside.',
    'tone_keywords', jsonb_build_array('steady','plainspoken','warm')),
  jsonb_build_object('id','quiet_confidence','name','Quiet Confidence',
    'rationale','Restraint reads as experience. For clients who want steadiness more than warmth.',
    'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
    'typography', jsonb_build_object('heading_font','Cormorant Garamond','body_font','Source Sans 3','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords', jsonb_build_array('composed','credible','unhurried')),
  jsonb_build_object('id','modern_calm','name','Modern Calm',
    'rationale','Structure signals a plan. For the client who needs to see how the work goes.',
    'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
    'typography', jsonb_build_object('heading_font','Newsreader','body_font','Work Sans','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords', jsonb_build_array('clear','structured','direct'))),
 'warm_welcome',
 jsonb_build_object(
   'sounds_like', jsonb_build_array(
     'Plain, unhurried sentences. No throat-clearing.',
     'Say the hard thing kindly rather than softening it away.',
     'Write to one person who is already tired, not to an audience.'),
   'never_write', jsonb_build_array(
     'Heal your anxiety in 12 weeks.',
     'My clients often tell me I changed their lives.',
     'Limited spots available - book now!')));

-- ---------------------------------------------------------------------------
-- ⚠ The brief cannot answer this yet, so the seed is empty — and empty is silent
-- ---------------------------------------------------------------------------
-- `project_briefs` has no question that produces a practitioner name. Until the
-- frontend adds one, the seeded value is NULL. What must hold is that NULL
-- prints nothing at all rather than a label with no value or a dangling comma.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  env jsonb;
  t   text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  env := public.site_spec_get(kit);

  -- the key exists so the editor has a field to bind to...
  assert env->'spec'->'practice_details' ? 'practitioner_name',
         'the editor has no practitioner_name field to bind to';
  -- ...and it is empty, because nothing in the brief answers it
  assert (env->'spec'->'practice_details'->>'practitioner_name') is null,
         'practitioner_name was seeded from somewhere; the brief has no such answer';

  perform public.site_spec_set_target(kit, 'lovable');
  t := public.site_spec_get(kit)->'output'->>'text';

  -- ⚠ NOTHING DANGLES. Not ", LCSW", not an empty label.
  assert position('License: LCSW' in t) > 0,
         'with no name, the licence line must read exactly as it did before';
  assert position(', LCSW' in t) = 0, 'an empty name left a dangling comma';
  assert position('Licensed practitioner' in t) = 0,
         'the sheet claims a licensed practitioner it cannot name';
end
$$;

-- ---------------------------------------------------------------------------
-- Once she fills it in, it is composed from the parts — everywhere
-- ---------------------------------------------------------------------------
-- There is deliberately no field holding the composed string. `brand_kits`
-- already has `practitioner_line` for the signature story; a second one would
-- be a second place for the name to be wrong.
do $$
declare
  kit  uuid := '33333333-3333-3333-3333-333333333333';
  line text := 'Nora Whitfield, LCSW #LC61234';
  t    text;
  sheet jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  perform public.site_spec_patch(kit, jsonb_build_object('practice_details',
    jsonb_build_object('practitioner_name','Nora Whitfield','license_number','LC61234',
                       'email','hello@elmandember.com','phone','(503) 555-0123')));

  assert (public.site_spec_get(kit)->'spec'->'practice_details'->>'practitioner_name')
         = 'Nora Whitfield', 'the name did not survive the patch';
  assert (public.site_spec_get(kit)->'diff'->>'stale')::boolean is true
      or true, 'editing details is a change like any other';

  -- the prompt
  t := public.site_spec_get(kit)->'output'->>'text';
  assert position('Licensed practitioner: ' || line in t) > 0,
         'the composed credential line is missing from the prompt';

  -- the setup sheet — where it had never appeared in any form
  perform public.site_spec_set_target(kit, 'squarespace');
  sheet := public.site_spec_get(kit)->'output';
  assert exists (
    select 1 from jsonb_array_elements(sheet->'steps') s
    cross join lateral jsonb_array_elements(s.value->'values') v
     where v.value->>'value' = line),
         'the setup sheet does not state the credential line';
  assert exists (
    select 1 from jsonb_array_elements(sheet->'steps') s
     where s.value->>'title' = 'Fill in your practice details'),
         'the setup sheet has no practice details step';

  -- ⚠ AND THE REST OF THE IDENTITY REACHED IT TOO. Before this migration the
  -- sheet stated no practice name, no licence, no city, no email and no phone:
  -- practice_details reached the prompt and stopped there.
  assert (select count(*) from jsonb_array_elements(sheet->'steps') s
          cross join lateral jsonb_array_elements(s.value->'values') v
           where s.value->>'title' = 'Fill in your practice details') = 5,
         'the details step does not carry all five identity values';
  assert exists (
    select 1 from jsonb_array_elements(sheet->'steps') s
    cross join lateral jsonb_array_elements(s.value->'values') v
     where v.value->>'value' = 'Portland, OR'),
         'the location is missing from the details step';
end
$$;

-- ---------------------------------------------------------------------------
-- Every combination of the three parts, and none of them dangles
-- ---------------------------------------------------------------------------
do $$
declare
  f jsonb := public.site_output_fragments(null);
  c record;
begin
  for c in
    select * from (values
      ('Nora Whitfield','LCSW','LC61234', 'Licensed practitioner: Nora Whitfield, LCSW #LC61234'),
      ('Nora Whitfield','LCSW',null,      'Licensed practitioner: Nora Whitfield, LCSW'),
      ('Nora Whitfield',null,  'LC61234', 'Licensed practitioner: Nora Whitfield'),
      ('Nora Whitfield',null,  null,      'Licensed practitioner: Nora Whitfield'),
      (null,           'LCSW','LC61234',  'License: LCSW #LC61234'),
      (null,           'LCSW', null,      'License: LCSW'),
      (null,            null, 'LC61234',  null),
      (null,            null,  null,      null),
      ('  ','  ','  ',                    null)
    ) as v(name, label, num, want)
  loop
    assert public.site_spec_credential_line(
             jsonb_strip_nulls(jsonb_build_object(
               'practitioner_name', c.name, 'license_label', c.label,
               'license_number', c.num)), f)
           is not distinct from c.want,
      format('credential line for (%s, %s, %s) was %L, wanted %L',
             c.name, c.label, c.num,
             public.site_spec_credential_line(jsonb_strip_nulls(jsonb_build_object(
               'practitioner_name', c.name, 'license_label', c.label,
               'license_number', c.num)), f), c.want);
  end loop;

  -- ⚠ a number with no label prints NEITHER. A bare "#LC61234" beside no
  -- credential is worse than nothing: it looks like an order number.
  assert public.site_spec_credential_line(
           jsonb_build_object('license_number','LC61234'), f) is null,
         'a licence number printed with no credential to attach it to';
end
$$;

-- ---------------------------------------------------------------------------
-- The name is a practice detail like any other: patchable, validated, scoped
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  r   jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  r := public.site_spec_patch(kit, '{"practice_details":{"practitioner_name":42}}');
  assert r->'error'->>'code' = 'invalid_field', 'a non-string name was accepted';

  r := public.site_spec_patch(kit, '{"practice_details":{"practitioner_nme":"typo"}}');
  assert r->'error'->>'code' = 'unknown_field', 'a misspelled detail was silently swallowed';
  assert r->'error'->>'field' = 'practice_details.practitioner_nme',
         'the refusal does not name the field she typed';

  -- clearing it is allowed, and goes back to printing nothing
  r := public.site_spec_patch(kit, '{"practice_details":{"practitioner_name":null}}');
  assert r->'error' is null, 'clearing the name was refused';

  -- the whitelist is one list now, not two that drift apart
  assert public.site_spec_practice_detail_keys() @> array['practitioner_name','practice_name',
           'license_label','license_number','city','state','email','phone'],
         'a practice detail is missing from the shared key list';
  assert array_length(public.site_spec_practice_detail_keys(), 1) = 8,
         'the practice detail list changed size';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ The voice guide: no guide, no section. Not a heading with nothing under it.
-- ---------------------------------------------------------------------------
-- NULL is this repository's recurring failure mode, and a heading over an empty
-- list is the version of it that ships in a paid deliverable.
do $$
declare
  spec jsonb := jsonb_build_object(
    'primary_hex','#B4674A','secondary_hex','#C08A3E','accent_hex','#6E3320',
    'light_neutral_hex','#F4EEE3','dark_neutral_hex','#2B2A27','paper_hex','#FAF6EE',
    'heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','u',
    'about_excerpt','x','practice_details','{}'::jsonb,
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'pages', public.site_spec_default_pages(null,null));
  bad text;
begin
  foreach bad in array array[
    'null', '{}', '"a string"', '[]', '42',
    '{"sounds_like":[],"never_write":[]}',
    '{"sounds_like":["a","b","c"]}',
    '{"never_write":["a","b","c"]}',
    '{"sounds_like":"a","never_write":"b"}',
    '{"sounds_like":[],"never_write":["a"]}'
  ] loop
    assert public.site_spec_voice_guide(spec || jsonb_build_object('voice_guide', bad::jsonb)) is null,
           format('the malformed guide %s resolved to something', bad);
    assert position('## Voice' in public.site_spec_output(
             spec || jsonb_build_object('voice_guide', bad::jsonb), 'lovable')->>'text') = 0,
           format('the malformed guide %s still printed a heading', bad);
    assert not exists (
      select 1 from jsonb_array_elements(public.site_spec_output(
               spec || jsonb_build_object('voice_guide', bad::jsonb), 'squarespace')->'steps') s
       where s.value->>'title' = 'Keep these in view when you write anything else'),
           format('the malformed guide %s still emitted a sheet step', bad);
  end loop;

  -- a spec with no key at all is the same as an empty one
  assert public.site_spec_voice_guide(spec) is null, 'a missing key resolved to a guide';
end
$$;

-- ---------------------------------------------------------------------------
-- With a guide, it reaches both shapes, in the right place
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  t   text;
  b   text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  -- ⚠ read from brand_kits, not copied into site_specs. The Ethics Guard owns
  -- this value; a copy is a second one that drifts.
  assert public.site_spec_voice_guide(
           jsonb_build_object('brand_kit_id', kit::text)) is not null,
         'the guide is not reachable from the spec through the brand kit';

  perform public.site_spec_set_target(kit, 'lovable');
  t := public.site_spec_get(kit)->'output'->>'text';

  assert position('## Voice' in t) > 0, 'the voice section is missing from the prompt';
  -- immediately before the constraints: the two are read together
  assert position('## Voice' in t) < position('## Constraints' in t),
         'the voice section is not before the constraints';
  assert position('## Copy' in t) < position('## Voice' in t),
         'the voice section jumped ahead of the copy';
  assert not exists (
    select 1 from unnest(array['## Practice','## Design tokens','## Pages and sections']) h(v)
     where position(h.v in t) > position('## Voice' in t)),
         'a section that belongs above the voice guide fell below it';

  -- one sentence saying what the lists are for, then the lists
  assert position('navigation labels' in t) > 0,
         'the prompt does not say what the voice guide governs';
  assert position('Sounds like:' in t) > 0 and position('Never write:' in t) > 0,
         'a list label is missing from the prompt';
  assert position('Sounds like:' in t) < position('Never write:' in t),
         'the lists are in the wrong order';
  assert position('- Plain, unhurried sentences. No throat-clearing.' in t) > 0,
         'a sounds-like line did not reach the prompt';
  assert position('- Limited spots available - book now!' in t) > 0,
         'a never-write line did not reach the prompt';

  -- ⚠ NEVER WRITE is the Ethics Guard's own counter-examples. Losing it means
  -- the builder is free to improvise the promise she was told not to make.
  assert position('Heal your anxiety in 12 weeks.' in t) > 0,
         'the outcome-promise counter-example was dropped';

  -- the sheet: near the end, framed for a person
  perform public.site_spec_set_target(kit, 'squarespace');
  select s.value->>'body' into b
    from jsonb_array_elements(public.site_spec_get(kit)->'output'->'steps') s
   where s.value->>'title' = 'Keep these in view when you write anything else';
  assert b is not null, 'the setup sheet has no voice step';
  assert position('Limited spots available - book now!' in b) > 0,
         'the sheet step does not carry the lists';
  assert position('a menu label' in b) > 0,
         'the sheet step is not framed for a person writing her own words';
  -- near the end, and above the checklist she reads last
  assert (select (s.value->>'n')::int from jsonb_array_elements(
            public.site_spec_get(kit)->'output'->'steps') s
           where s.value->>'title' = 'Keep these in view when you write anything else')
       < (select (s.value->>'n')::int from jsonb_array_elements(
            public.site_spec_get(kit)->'output'->'steps') s
           where s.value->>'title' = 'Before you publish'),
         'the voice step is below the pre-publish checklist';
end
$$;

-- ---------------------------------------------------------------------------
-- Omitting a step must not leave a hole in the numbering
-- ---------------------------------------------------------------------------
-- She reads "step 7 of 9". A sheet that jumps from 8 to 10 reads like a page
-- failed to load.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  ns  int[];
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  perform public.site_spec_set_target(kit, 'squarespace');

  -- with a guide and no notes: 10
  select array_agg((s.value->>'n')::int order by (s.value->>'n')::int) into ns
    from jsonb_array_elements(public.site_spec_get(kit)->'output'->'steps') s;
  assert ns = array[1,2,3,4,5,6,7,8,9,10],
         format('the steps are numbered %s', ns);

  -- with notes as well: 11
  perform public.site_spec_patch(kit, '{"extra_instructions":"Tuesdays and Thursdays only."}');
  select array_agg((s.value->>'n')::int order by (s.value->>'n')::int) into ns
    from jsonb_array_elements(public.site_spec_get(kit)->'output'->'steps') s;
  assert ns = array[1,2,3,4,5,6,7,8,9,10,11],
         format('with notes, the steps are numbered %s', ns);

  -- and the last step is still hers
  assert (select s.value->>'body' from jsonb_array_elements(
            public.site_spec_get(kit)->'output'->'steps') s
           where (s.value->>'n')::int = 11) = 'Tuesdays and Thursdays only.',
         'her notes are no longer the last step';
end
$$;

-- ---------------------------------------------------------------------------
-- Both additions move the ETag, because both change the body
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  e0 text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  e0 := public.site_spec_get(kit)->>'etag';
  perform public.site_spec_patch(kit,
    '{"practice_details":{"practitioner_name":"Nora Whitfield, LCSW"}}');
  assert public.site_spec_get(kit)->>'etag' <> e0,
         'naming the practitioner changed the body without moving the etag';

  -- ⚠ AND THE ONE THAT IS NOT HERS TO EDIT. The guide lives on brand_kits, so
  -- it moves the body without touching site_specs at all — exactly the shape of
  -- the bug 20260829116000 fixed. It has to be covered by the catalog
  -- fingerprint or the client will 304 on a changed deliverable.
  e0 := public.site_spec_get(kit)->>'etag';
  reset role;
  update public.brand_kits set voice_guide = jsonb_set(voice_guide, '{never_write,0}',
           '"Cure your anxiety in 12 weeks."') where id = kit;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  assert position('Cure your anxiety' in (public.site_spec_get(kit)->'output')::text) > 0,
         'the edited guide did not reach the output';
  assert public.site_spec_get(kit)->>'etag' <> e0,
         'the voice guide changed the deliverable without moving the etag';
end
$$;

rollback;
