-- ============================================================================
-- Tests — 20260829104000_site_output_prompt.sql
--         20260829105000_site_output_setup_sheet.sql
-- ============================================================================
-- ONE SPEC, EVERY TARGET, PINNED BYTE FOR BYTE.
--
-- The output is a pure function of (spec, target) with no LLM call in it, and
-- the whole product rests on that: the mockup she approves and the text she
-- pastes have to describe the same site, the cached copy in
-- `brand_kits.site_prompt` has to stay true, and a "copied" marker has to mean
-- something. So the digests below are snapshots — if one moves, the deliverable
-- moved, and somebody should look at it on purpose rather than find out from a
-- therapist.
--
-- REGENERATING THEM, when a change is intended:
--
--   psql "$DB_URL" -At -f supabase/tests/helpers/site_output_digests.sql
--
-- and paste the result into the `expected` array below. Read the diff first —
-- the point of the test is the moment of looking, not the digest.
-- ============================================================================
begin;

-- The fixture spec. A jsonb literal rather than a row: no ids, no clock,
-- nothing that could make one run differ from the next.
create temporary table snapshot_spec as
select jsonb_build_object(
  'primary_hex','#3B2C3A','secondary_hex','#4A5361','accent_hex','#C08A3E',
  'light_neutral_hex','#F3EDE4','dark_neutral_hex','#241B23','paper_hex','#FAF7F2',
  'type_pairing_id','cormorant_source',
  'heading_font','Cormorant Garamond','body_font','Source Sans 3',
  'google_fonts_url','https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&family=Source+Sans+3:wght@400;600;700&display=swap',
  'hero', jsonb_build_object(
    'overline','LCSW · PORTLAND, OR','headline','Experienced care, without the noise.',
    'subhead','Therapy for high-performing adults who cannot switch off.',
    'cta_label','Book a consult','cta_target_url','https://elmandember.clientsecure.me'),
  'about_excerpt','I work mostly with professionals who look fine from outside. Much of that work sits with anxiety and burnout.',
  'practice_details', jsonb_build_object(
    'practitioner_name','Nora Whitfield',
    'practice_name','Elm & Ember Therapy','license_label','LCSW','license_number','LC61234',
    'city','Portland','state','OR','email','hello@elmandember.com','phone','(503) 555-0123'),
  'voice_guide', jsonb_build_object(
    'sounds_like', jsonb_build_array(
      'Plain, unhurried sentences. No throat-clearing.',
      'Say the hard thing kindly rather than softening it away.',
      'Write to one person who is already tired, not to an audience.'),
    'never_write', jsonb_build_array(
      'Heal your anxiety in 12 weeks.',
      'My clients often tell me I changed their lives.',
      'Limited spots available - book now!')),
  'pages', public.site_spec_default_pages(
             array['Anxiety','Burnout'],
             array['Professionals who look fine from outside']),
  'extra_instructions','Please keep fees off the home page. Tuesday and Thursday are the only open hours right now.',
  'target','lovable') as s;

-- ---------------------------------------------------------------------------
-- The snapshots
-- ---------------------------------------------------------------------------
do $$
declare
  spec     jsonb := (select s from snapshot_spec);
  expected text[][] := array[
    ['lovable',     'bdcc34568f9730014dfb1bf5b1af1e4b'],
    ['framer',      'bdcc34568f9730014dfb1bf5b1af1e4b'],
    ['v0',          'bdcc34568f9730014dfb1bf5b1af1e4b'],
    ['generic',     'bdcc34568f9730014dfb1bf5b1af1e4b'],
    ['squarespace', '7d3af7dc30f1387c1dff527556716120'],
    ['wix',         '4e00ad1ff1a5d35e73aa3c038e7927e4'],
    ['webflow',     '9cea39a5ffb4a0496a69a72fbb08d474']
  ];
  i   int;
  got text;
begin
  -- every target the spec can hold is covered here, and none is missing
  assert (select count(*) from public.builder_targets) = array_length(expected, 1),
         'a builder target has no snapshot; add it to this test';

  for i in 1 .. array_length(expected, 1) loop
    got := md5(public.site_spec_output_render(
                 (select label from public.builder_targets where id = expected[i][1]),
                 public.site_spec_output(spec, expected[i][1]), true));
    assert got = expected[i][2],
      format('the %s output changed (%s, expected %s). Read the diff, then regenerate.',
             expected[i][1], got, expected[i][2]);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Determinism, which is what makes the digests above mean anything
-- ---------------------------------------------------------------------------
do $$
declare
  spec jsonb := (select s from snapshot_spec);
  t    text;
begin
  for t in select id from public.builder_targets loop
    assert public.site_spec_output(spec, t) = public.site_spec_output(spec, t),
           format('two renders of the %s output differ', t);
  end loop;

  -- A prompt does not vary by which prompt-accepting builder asked for it, and
  -- that is deliberate: the spec is the whole instruction, and a per-builder
  -- dialect would be four things to keep true instead of one.
  assert public.site_spec_output(spec, 'lovable') = public.site_spec_output(spec, 'framer')
     and public.site_spec_output(spec, 'lovable') = public.site_spec_output(spec, 'v0')
     and public.site_spec_output(spec, 'lovable') = public.site_spec_output(spec, 'generic'),
         'the prompt differs between builders that all just take a prompt';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ The fork. This is the defect the whole feature exists to fix.
-- ---------------------------------------------------------------------------
do $$
declare
  spec jsonb := (select s from snapshot_spec);
  t    text;
begin
  for t in select id from public.builder_targets where not accepts_prompt loop
    assert public.site_spec_output(spec, t)->>'kind' = 'setup_sheet',
           format('%s has no prompt input and was handed a prompt', t);
  end loop;
  for t in select id from public.builder_targets where accepts_prompt loop
    assert public.site_spec_output(spec, t)->>'kind' = 'prompt',
           format('%s takes a prompt and did not get one', t);
  end loop;

  assert public.site_spec_output(spec, 'wordpress')->'error'->>'code' = 'invalid_target',
         'an unknown builder must be an error, not a silent default';
end
$$;

-- ---------------------------------------------------------------------------
-- The prompt: the seven parts, in the order the product spec fixes
-- ---------------------------------------------------------------------------
do $$
declare
  spec jsonb := (select s from snapshot_spec);
  o    jsonb := public.site_spec_output(spec, 'lovable');
  t    text  := o->>'text';
begin
  assert o->>'kind' = 'prompt', 'Lovable gets a prompt';
  assert (o->>'char_count')::int = char_length(t), 'char_count must match the text';

  assert t like 'Build a one-page (or multi-page) website for a therapy private practice. Follow this specification exactly.%',
         'the role line must come first, verbatim';
  assert position('## Practice' in t) < position('## Design tokens' in t)
     and position('## Design tokens' in t) < position('## Pages and sections' in t)
     and position('## Pages and sections' in t) < position('## Copy' in t)
     and position('## Copy' in t) < position('## Voice' in t)
     and position('## Voice' in t) < position('## Constraints' in t)
     and position('## Constraints' in t)
         < position('## Additional instructions from the practice owner' in t),
         'the eight parts are out of order';

  -- identity
  assert position('Name: Elm & Ember Therapy' in t) > 0, 'the practice name is missing';
  -- ⚠ 20260829120000: the person is named beside the licence. A board that
  -- requires the number in advertising requires the licensee's name with it.
  assert position('Licensed practitioner: Nora Whitfield, LCSW #LC61234' in t) > 0,
         'the credential line is missing or is not composed from the parts';
  assert position('Location: Portland, OR' in t) > 0,    'the location line is missing';

  -- tokens, each with the role it plays
  assert position('Primary — fills, buttons, bands and borders: #3B2C3A' in t) > 0,
         'a design token lost its role';
  -- ⚠ the page background must be stated, or the builder defaults it to white
  -- whatever the palette says
  assert position('Page background' in t) > 0 and position('#FAF7F2' in t) > 0,
         'the prompt does not state the page background';
  assert position('Section background' in t) > 0 and position('#F3EDE4' in t) > 0,
         'the prompt does not distinguish the tinted band from the page';
  assert position('Cormorant Garamond' in t) > 0, 'the heading font is missing';
  assert position('fonts.googleapis.com' in t) > 0, 'the Google Fonts stylesheet is missing';

  -- copy, verbatim and fenced
  assert position('Headline: Experienced care, without the noise.' in t) > 0,
         'the hero headline is missing from the copy block';
  assert position(E'"""\nI work mostly with professionals who look fine from outside.' in t) > 0,
         'long copy must be fenced so the builder does not treat it as a brief';
  assert position(E'- Anxiety\n- Burnout' in t) > 0, 'a list field did not render as a list';

  -- ⚠ all five constraints, every time
  assert position('Use the provided copy exactly as written.' in t) > 0, 'constraint 1 missing';
  assert position('Do not invent testimonials, client quotes, statistics, credentials or awards.' in t) > 0,
         'constraint 2 missing';
  assert position('No stock photos of people; leave labeled image placeholders.' in t) > 0,
         'constraint 3 missing';
  assert position('The call to action links to https://elmandember.clientsecure.me.' in t) > 0,
         'constraint 4 must name her actual booking link';
  assert position('contact form that collects health information' in t) > 0,
         'the health-information clause is missing';
  assert position('Maintain WCAG AA text contrast.' in t) > 0, 'constraint 6 missing';
  -- ⚠ the size floor: the deliverable makes a claim about rendered size the
  -- moment it tells a builder to put a label on a button, and nothing
  -- downstream can check it.
  assert position('Do not set the call-to-action label below 18px bold' in t) > 0,
         'the button size floor is missing from the prompt';

  -- her notes, verbatim and last
  assert right(t, 44) = 'Tuesday and Thursday are the only open hours right now.'
         or t like '%Tuesday and Thursday are the only open hours right now.',
         'extra_instructions must be printed verbatim';
  assert position('Please keep fees off the home page.' in t)
         > position('Maintain WCAG AA text contrast.' in t),
         'extra_instructions must come after the constraints, never before';
end
$$;

-- No booking link yet: the prompt says so rather than leaving the builder to
-- invent a destination, which in practice means a form.
do $$
declare
  spec jsonb := jsonb_set((select s from snapshot_spec), '{hero,cta_target_url}', 'null'::jsonb);
  t    text  := public.site_spec_output(spec, 'lovable')->>'text';
begin
  assert position('The call to action has no link yet' in t) > 0,
         'a spec with no booking link must say so in the constraints';
  assert position('contact form that collects health information' in t) > 0,
         'the health-information clause must survive the no-link branch';
end
$$;

-- An empty notes field prints no heading at all.
do $$
declare
  t text := public.site_spec_output((select s from snapshot_spec) - 'extra_instructions',
                                    'lovable')->>'text';
begin
  assert position('## Additional instructions' in t) = 0,
         'an empty notes heading was printed';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ extra_instructions: in the output, under its own heading, and NOWHERE ELSE
-- ---------------------------------------------------------------------------
-- Rule 2 in one assertion. The notes field is appended verbatim to the
-- deliverable and is never parsed, never interpreted, and never reaches the
-- mockup — because reaching the mockup would mean interpreting it, and
-- interpreting free text back into the spec is the round trip the whole design
-- forbids.
do $$
declare
  spec   jsonb;
  marker text := 'ZZQX-SENTINEL-9137';
  t      text;
  sheet  jsonb;
begin
  spec := jsonb_set((select s from snapshot_spec), '{extra_instructions}', to_jsonb(marker));

  -- 1. it IS in the prompt, exactly once, and under its own heading
  t := public.site_spec_output(spec, 'lovable')->>'text';
  assert position(marker in t) > 0, 'extra_instructions is missing from the prompt';
  assert (select count(*) from regexp_matches(t, marker, 'g')) = 1,
         'extra_instructions appears more than once in the prompt';
  assert position(marker in t) > position('## Additional instructions from the practice owner' in t),
         'extra_instructions is printed somewhere other than under its own heading';
  -- and nothing follows it: it is the last thing in the document
  assert right(t, char_length(marker)) = marker,
         'something was printed after extra_instructions';

  -- 2. it IS in the setup sheet, exactly once, as the last step
  sheet := public.site_spec_output(spec, 'squarespace');
  -- ⚠ pinned to "the last step" rather than to a number: steps are added and
  -- omitted, and a hard number turns "it moved" into "the test needs editing".
  assert (select s.value->>'body' from jsonb_array_elements(sheet->'steps') s
           where (s.value->>'n')::int
                 = (select max((x.value->>'n')::int)
                      from jsonb_array_elements(sheet->'steps') x)) = marker,
         'extra_instructions is not the setup sheet''s last step, verbatim';
  assert (select count(*) from jsonb_array_elements(sheet->'steps') s
           where position(marker in coalesce(s.value->>'body','')) > 0) = 1,
         'extra_instructions appears in more than one step';
  assert not exists (select 1 from jsonb_array_elements(sheet->'copy_blocks') b
                      where position(marker in coalesce(b.value->>'text','')) > 0),
         'extra_instructions leaked into the copy blocks, where it would be pasted as site copy';

  -- 3. ⚠ IT IS NOT IN THE MOCKUP. Not in the tokens, not in a section's
  -- fields, not anywhere in the preview model.
  assert position(marker in public.site_spec_preview_model(spec)::text) = 0,
         'extra_instructions reached buildPreviewModel; the mockup must never render it';

  -- 4. nor in the contrast panel or the diff
  assert position(marker in public.site_spec_contrast(spec)::text) = 0,
         'extra_instructions reached the contrast report';

  -- 5. and in the full envelope it appears only in `spec` (where she edits it)
  --    and in `output` (where it is delivered) — never in `preview`
  assert position(marker in (public.site_spec_envelope(
           spec || jsonb_build_object('brand_kit_id','00000000-0000-0000-0000-000000000000',
                                      'spec_version',1,'change_marks','{}'::jsonb))
           ->'preview')::text) = 0,
         'extra_instructions reached the preview half of the envelope';
end
$$;

-- ---------------------------------------------------------------------------
-- The setup sheet: steps that name the product's own panels
-- ---------------------------------------------------------------------------
do $$
declare
  spec  jsonb := (select s from snapshot_spec);
  sheet jsonb := public.site_spec_output(spec, 'squarespace');
  step  jsonb;
begin
  assert sheet->>'kind' = 'setup_sheet', 'Squarespace gets a setup sheet';
  -- ⚠ ELEVEN STEPS SINCE 20260829120000: the text variants got a step of their
  -- own (118000), then the practice details and the voice guide got theirs.
  -- The details step was not a refinement — the sheet had never once told her
  -- to put her name or her license anywhere on her own site.
  assert jsonb_array_length(sheet->'steps') = 11, 'the sheet must have its eleven steps';
  assert (select array_agg((s.value->>'n')::int order by (s.value->>'n')::int)
            from jsonb_array_elements(sheet->'steps') s) = array[1,2,3,4,5,6,7,8,9,10,11],
         'the steps she reads are not numbered 1..n without a gap';

  -- ⚠ The panel names are the difference between a sheet she can follow and a
  -- sheet she has to decode.
  select s.value into step from jsonb_array_elements(sheet->'steps') s
   where (s.value->>'n')::int = 2;
  assert step->>'builder_hint' = 'Site Styles › Colors',
         'step 2 must name Squarespace''s own color panel';
  assert jsonb_array_length(step->'values') = 6, 'six hexes, each with its role';
  assert exists (select 1 from jsonb_array_elements(step->'values') v
                  where v.value->>'label' like 'Page background%'),
         'the colour step does not name the page background';
  assert exists (select 1 from jsonb_array_elements(step->'values') v
                  where v.value->>'value' = '#3B2C3A' and v.value->>'kind' = 'hex'),
         'the primary hex is missing from the color step';

  -- and each product gets its own, not one generic instruction
  assert (select s.value->>'builder_hint' from jsonb_array_elements(
            public.site_spec_output(spec, 'wix')->'steps') s where (s.value->>'n')::int = 2)
         = 'Site Design › Color Palette', 'Wix must be told about its own panel';
  -- the text-variant step points at the same panel: they are colours too
  assert (select s.value->>'builder_hint' from jsonb_array_elements(
            public.site_spec_output(spec, 'wix')->'steps') s where (s.value->>'n')::int = 3)
         = 'Site Design › Color Palette', 'the text-variant step must name the colour panel';
  assert (select s.value->>'builder_hint' from jsonb_array_elements(
            public.site_spec_output(spec, 'webflow')->'steps') s where (s.value->>'n')::int = 2)
         = 'Style Manager › Variables › Colors', 'Webflow must be told about its own panel';

  -- ⚠ the same five constraints as the prompt, as a checklist. A Squarespace
  -- user is under exactly the same advertising rules as everyone else.
  -- looked up by title, not by number: steps get inserted ahead of it
  select s.value into step from jsonb_array_elements(sheet->'steps') s
   where s.value->>'title' = 'Before you publish';
  assert step is not null, 'the checklist step is missing';
  assert (select count(*) from regexp_matches(step->>'body', '\[ \] ', 'g')) = 6,
         'the checklist must carry all six constraints';
  assert position('18px bold' in step->>'body') > 0,
         'the checklist does not carry the button size floor';
  assert position('Do not invent testimonials' in step->>'body') > 0,
         'a constraint was dropped from the checklist';

  -- her notes, last, verbatim
  select s.value into step from jsonb_array_elements(sheet->'steps') s
   where s.value->>'title' = 'Your own notes';
  assert step is not null, 'the notes step is missing';
  assert step->>'body' = spec->>'extra_instructions',
         'extra_instructions must be reproduced verbatim, never reworded';

  -- and no notes step when she has written none
  assert not exists (
    select 1 from jsonb_array_elements(
             public.site_spec_output(spec - 'extra_instructions', 'squarespace')->'steps') s
     where s.value->>'title' = 'Your own notes'),
         'an empty notes step was emitted';
end
$$;

-- ⚠ BOTH THE BRAND COLOUR AND ITS TEXT VARIANT, with distinct roles, in every
-- builder. The whole decision rests on a builder not collapsing them.
do $$
declare
  spec jsonb := jsonb_set((select s from snapshot_spec), '{accent_hex}', '"#C08A3E"'::jsonb);
  t    text;
  txt  text;
  brand text := '#C08A3E';
  variant text;
begin
  variant := public.site_spec_variant_of(spec, 'accent');
  assert variant <> brand, 'the fixture accent must need a variant for this test to mean anything';

  -- the four prompt builders
  foreach t in array array['lovable','framer','v0','generic'] loop
    txt := public.site_spec_output(spec, t)->>'text';
    assert position(brand in txt) > 0,   format('%s: the brand accent is missing', t);
    assert position(variant in txt) > 0, format('%s: the accent text variant is missing', t);
    assert position('as text' in txt) > 0,
           format('%s: nothing distinguishes the variant from the brand colour', t);
    assert position('Do not substitute one for the other' in txt) > 0,
           format('%s: the usage rule is missing', t);
  end loop;

  -- the three setup-sheet builders: a step of its own, three values
  foreach t in array array['squarespace','wix','webflow'] loop
    assert (select jsonb_array_length(v.value->'values')
              from jsonb_array_elements(public.site_spec_output(spec, t)->'steps') v
             where (v.value->>'n')::int = 3) = 3,
           format('%s: step 3 does not carry the three text variants', t);
    assert exists (
      select 1 from jsonb_array_elements(public.site_spec_output(spec, t)->'steps') v
      cross join lateral jsonb_array_elements(v.value->'values') x
       where x.value->>'value' = variant and x.value->>'label' like '%as text%'),
           format('%s: the variant is not labelled as a text value', t);
    assert exists (
      select 1 from jsonb_array_elements(public.site_spec_output(spec, t)->'steps') v
      cross join lateral jsonb_array_elements(v.value->'values') x
       where x.value->>'value' = brand and x.value->>'label' not like '%as text%'),
           format('%s: the brand colour is not listed as a fill value', t);
  end loop;
end
$$;

-- ⚠ A step title that states a count must state its own values length.
-- Step 2 was "Set your five colors" over six values for as long as it took
-- `paper` to come back and nobody to notice.
do $$
declare
  spec jsonb := (select s from snapshot_spec);
  t    text;
  r    record;
  n    int;
begin
  foreach t in array array['squarespace','wix','webflow'] loop
    for r in select v.value->>'n' as n, v.value->>'title' as title,
                    jsonb_array_length(v.value->'values') as len
               from jsonb_array_elements(public.site_spec_output(spec, t)->'steps') v
    loop
      n := public.site_output_step_title_count(r.title);
      assert n is null or n = r.len,
        format('%s step %s titled "%s" states %s but carries %s value(s)',
               t, r.n, r.title, n, r.len);
    end loop;
  end loop;

  -- the two that were wrong, named explicitly
  assert (select v.value->>'title' from jsonb_array_elements(
            public.site_spec_output(spec,'squarespace')->'steps') v
           where (v.value->>'n')::int = 2) = 'Set your six colors',
         'step 2 no longer names its six colours';
  -- the fonts step moved to 4 when the text variants took a step of their own
  assert (select v.value->>'title' from jsonb_array_elements(
            public.site_spec_output(spec,'squarespace')->'steps') v
           where (v.value->>'n')::int = 4) = 'Set your fonts',
         'the fonts step states a count again over a mixed list';
  -- and the new step 3 states three, and carries three
  assert (select v.value->>'title' from jsonb_array_elements(
            public.site_spec_output(spec,'squarespace')->'steps') v
           where (v.value->>'n')::int = 3) like '%three%',
         'the text-variant step should say how many there are';
end
$$;

-- Copy blocks: every string, individually copyable, one per list item.
do $$
declare
  sheet jsonb := public.site_spec_output((select s from snapshot_spec), 'squarespace');
begin
  assert jsonb_array_length(sheet->'copy_blocks') >= 10,
         'the sheet must break every string out into its own block';

  assert exists (select 1 from jsonb_array_elements(sheet->'copy_blocks') b
                  where b.value->>'page' = 'Home' and b.value->>'section' = 'Hero'
                    and b.value->>'label' = 'Headline'
                    and b.value->>'text' = 'Experienced care, without the noise.'),
         'the hero headline is not an individually copyable block';

  -- ⚠ ONE BLOCK PER ITEM. In a builder with no prompt input each item is typed
  -- into its own element; a single block of newline-separated specialties would
  -- have to be pulled apart by hand.
  assert exists (select 1 from jsonb_array_elements(sheet->'copy_blocks') b
                  where b.value->>'text' = 'Anxiety' and b.value->>'label' = 'Areas 1');
  assert exists (select 1 from jsonb_array_elements(sheet->'copy_blocks') b
                  where b.value->>'text' = 'Burnout' and b.value->>'label' = 'Areas 2'),
         'list items must each become their own block';

  -- the intro reads site_specs.about_excerpt, not its own empty fields
  assert exists (select 1 from jsonb_array_elements(sheet->'copy_blocks') b
                  where b.value->>'section' = 'Introduction'
                    and b.value->>'text' like 'I work mostly with professionals%'),
         'the intro block must carry the About text';

  assert not exists (select 1 from jsonb_array_elements(sheet->'copy_blocks') b
                      where btrim(coalesce(b.value->>'text', '')) = ''),
         'an empty copy block is a block she would copy for nothing';
end
$$;

-- ---------------------------------------------------------------------------
-- The md and txt renderings
-- ---------------------------------------------------------------------------
do $$
declare
  spec jsonb := (select s from snapshot_spec);
  md   text;
  txt  text;
begin
  md  := public.site_spec_output_render('Squarespace', public.site_spec_output(spec, 'squarespace'), true);
  txt := public.site_spec_output_render('Squarespace', public.site_spec_output(spec, 'squarespace'), false);

  assert md like '# Squarespace%',            'the markdown sheet is titled with the builder';
  assert md like '%## 2. Set your six colors%', 'the markdown sheet has step headings';
  assert md like '%> Where: Site Styles › Colors%', 'the panel is quoted in the markdown sheet';
  assert txt not like '%## %',                 'the plain rendering kept its markdown markers';
  assert txt like '%SQUARESPACE%',             'the plain rendering has a title';
  assert md <> txt,                            'md and txt must differ';

  -- A prompt is already plain text with headings, so md is it as it stands and
  -- txt is the same with the markers taken off.
  md  := public.site_spec_output_render('Lovable', public.site_spec_output(spec, 'lovable'), true);
  txt := public.site_spec_output_render('Lovable', public.site_spec_output(spec, 'lovable'), false);
  assert md = public.site_spec_output(spec, 'lovable')->>'text',
         'the markdown prompt must be the prompt itself';
  assert txt not like '%## Constraints%' and txt like '%Constraints%',
         'the plain prompt must lose its markers and keep its headings';
  -- the fences are content, not markup, and must survive
  assert position('"""' in txt) > 0, 'the plain prompt lost its copy fences';
end
$$;

rollback;
