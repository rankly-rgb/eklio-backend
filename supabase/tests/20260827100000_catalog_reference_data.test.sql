-- ============================================================================
-- Tests — 20260827100000_catalog_reference_data.sql
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Row counts the product spec fixes exactly
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select count(*) from public.tone_cards)           = 6,  'tone_cards must hold exactly 6 rows';
  assert (select count(*) from public.palette_families)     = 6,  'palette_families must hold exactly 6 rows';
  assert (select count(*) from public.type_pairings)        = 6,  'type_pairings must hold exactly 6 rows';
  assert (select count(*) from public.client_persona_cards) = 10, 'client_persona_cards must hold exactly 10 rows';
  assert (select count(*) from public.problem_cards)        = 8,  'problem_cards must hold exactly 8 rows';
  assert (select count(*) from public.gain_cards)           = 8,  'gain_cards must hold exactly 8 rows';
  assert (select count(*) from public.ethics_rules)         = 6,  'ethics_rules must hold exactly 6 rows';
end
$$;

-- ---------------------------------------------------------------------------
-- The six tone card sample_hero strings, verbatim. Screen 2 renders each card
-- AS this string, so a reworded one is a reworded screen.
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select sample_hero from public.tone_cards where id='grounded')
       = 'You don''t need to have it figured out before you call.', 'grounded sample_hero drifted';
  assert (select sample_hero from public.tone_cards where id='clear')
       = 'Therapy with a plan you can actually see.', 'clear sample_hero drifted';
  assert (select sample_hero from public.tone_cards where id='gentle')
       = 'A slower place to work things through.', 'gentle sample_hero drifted';
  assert (select sample_hero from public.tone_cards where id='warm_practical')
       = 'Real conversations about what''s not working.', 'warm_practical sample_hero drifted';
  assert (select sample_hero from public.tone_cards where id='quiet_confidence')
       = 'Experienced care, without the noise.', 'quiet_confidence sample_hero drifted';
  assert (select sample_hero from public.tone_cards where id='open')
       = 'We''ll figure out together what this work needs to be.', 'open sample_hero drifted';

  assert (select keywords from public.tone_cards where id='grounded')
       = array['steady','plainspoken','warm'], 'grounded keywords drifted';
end
$$;

-- ---------------------------------------------------------------------------
-- The six palettes, hex for hex
-- ---------------------------------------------------------------------------
do $$
declare
  expected text[][] := array[
    ['plum_bone',      'PLUM & BONE',      '#3B2C3A','#4A5361','#F3EDE4','#241B23','#FAF7F2'],
    ['clay_sand',      'CLAY & SAND',      '#B4674A','#C08A3E','#F4EEE3','#2B2A27','#FAF6EE'],
    ['ink_blue_chalk', 'INK BLUE & CHALK', '#22364F','#7A8168','#EDEAE5','#16202E','#F7F6F3'],
    ['olive_chalk',    'OLIVE & CHALK',    '#7A8168','#3F4536','#EDEAE5','#262A20','#F7F7F3'],
    ['ochre_paper',    'OCHRE & PAPER',    '#C08A3E','#6B4B1C','#F6F2EA','#2A2118','#FBF8F1'],
    ['slate_bone',     'SLATE & BONE',     '#4A5361','#2F3742','#F3EDE4','#1E242C','#F9F7F3']
  ];
  i int;
  r record;
begin
  for i in 1 .. array_length(expected, 1) loop
    select * into r from public.palette_families where id = expected[i][1];
    assert r.id is not null,                    format('palette %s is missing', expected[i][1]);
    assert r.label         = expected[i][2],    format('palette %s label drifted', expected[i][1]);
    assert r.primary_hex   = expected[i][3],    format('palette %s primary drifted', expected[i][1]);
    assert r.secondary_hex = expected[i][4],    format('palette %s secondary drifted', expected[i][1]);
    assert r.light_hex     = expected[i][5],    format('palette %s light drifted', expected[i][1]);
    assert r.dark_hex      = expected[i][6],    format('palette %s dark drifted', expected[i][1]);
    assert r.paper_hex     = expected[i][7],    format('palette %s paper drifted', expected[i][1]);
    -- the three dots under the card, and the token object the frontend reads
    assert r.swatches = array[r.primary_hex, r.secondary_hex, r.light_hex],
           format('palette %s swatches disagree with its roles', expected[i][1]);
    assert r.preview_tokens->>'primary' = r.primary_hex
       and r.preview_tokens->>'paper'   = r.paper_hex,
           format('palette %s preview_tokens disagree with its roles', expected[i][1]);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- The six type pairings, font name for font name, and loadable URLs
-- ---------------------------------------------------------------------------
do $$
declare
  expected text[][] := array[
    ['fraunces_nunito',   'Fraunces',           'Nunito Sans'],
    ['cormorant_source',  'Cormorant Garamond', 'Source Sans 3'],
    ['newsreader_work',   'Newsreader',         'Work Sans'],
    ['lora_source3',      'Lora',               'Source Sans 3'],
    ['caslon_inter',      'Libre Caslon Text',  'Inter'],
    ['sourceserif_inter', 'Source Serif 4',     'Inter']
  ];
  i int;
  r record;
begin
  for i in 1 .. array_length(expected, 1) loop
    select * into r from public.type_pairings where id = expected[i][1];
    assert r.id is not null,                 format('type pairing %s is missing', expected[i][1]);
    assert r.heading_font = expected[i][2],  format('type pairing %s heading font drifted', expected[i][1]);
    assert r.body_font    = expected[i][3],  format('type pairing %s body font drifted', expected[i][1]);
    assert r.google_fonts_url like 'https://fonts.googleapis.com/css2?family=%',
           format('type pairing %s URL is not a css2 request', expected[i][1]);
    assert r.google_fonts_url like '%display=swap',
           format('type pairing %s URL does not ask for display=swap', expected[i][1]);
    -- both families must appear in the URL, spaces encoded as '+'
    assert position(replace(expected[i][2], ' ', '+') in r.google_fonts_url) > 0,
           format('type pairing %s URL does not request its heading font', expected[i][1]);
    assert position(replace(expected[i][3], ' ', '+') in r.google_fonts_url) > 0,
           format('type pairing %s URL does not request its body font', expected[i][1]);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- The three ethics examples printed on Screen 6, verbatim
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select example_forbidden from public.ethics_rules where id='timeframe')
       = 'Heal your anxiety in 12 weeks.', 'timeframe example drifted from Screen 6';
  assert (select example_forbidden from public.ethics_rules where id='client_voice')
       = 'Clients often tell me...', 'client_voice example drifted from Screen 6';
  assert (select example_forbidden from public.ethics_rules where id='scarcity')
       = 'Limited spots available.', 'scarcity example drifted from Screen 6';
end
$$;

-- ---------------------------------------------------------------------------
-- Rendering limits actually bite
-- ---------------------------------------------------------------------------
do $$
declare
  rejected boolean;
begin
  -- a keyword label that would wrap the nowrap line
  begin
    insert into public.tone_cards (id, sort_order, sample_hero, keywords)
    values ('too_long', 99, 'x', array['aaaaaaaaaaa','bbbbbbbbbbb','ccccccccccc']);
    rejected := false;
  exception when check_violation then rejected := true;
  end;
  assert rejected, 'a tone card whose joined keywords exceed 32 characters was accepted';

  -- a keyword that is two words
  begin
    insert into public.tone_cards (id, sort_order, sample_hero, keywords)
    values ('two_words', 98, 'x', array['two words','b','c']);
    rejected := false;
  exception when check_violation then rejected := true;
  end;
  assert rejected, 'a tone card keyword containing a space was accepted';

  -- a persona label past the fixed card width
  begin
    insert into public.client_persona_cards (id, sort_order, label, description)
    values ('too_long', 99, repeat('x', 49), 'ok');
    rejected := false;
  exception when check_violation then rejected := true;
  end;
  assert rejected, 'a 49-character persona label was accepted';

  -- a palette with a malformed hex
  begin
    insert into public.palette_families
      (id, sort_order, label, primary_hex, secondary_hex, light_hex, dark_hex, paper_hex, swatches, preview_tokens)
    values ('bad_hex', 99, 'BAD', 'red', '#C08A3E', '#F4EEE3', '#2B2A27', '#FAF6EE',
            array['red','#C08A3E','#F4EEE3'],
            '{"primary":"red","secondary":"#C08A3E","light":"#F4EEE3","dark":"#2B2A27","paper":"#FAF6EE"}'::jsonb);
    rejected := false;
  exception when check_violation then rejected := true;
  end;
  assert rejected, 'a palette with a non-hex colour was accepted';

  -- swatches that disagree with the roles they are meant to mirror
  begin
    insert into public.palette_families
      (id, sort_order, label, primary_hex, secondary_hex, light_hex, dark_hex, paper_hex, swatches, preview_tokens)
    values ('bad_swatch', 99, 'BAD', '#B4674A', '#C08A3E', '#F4EEE3', '#2B2A27', '#FAF6EE',
            array['#000000','#C08A3E','#F4EEE3'],
            '{"primary":"#B4674A","secondary":"#C08A3E","light":"#F4EEE3","dark":"#2B2A27","paper":"#FAF6EE"}'::jsonb);
    rejected := false;
  exception when check_violation then rejected := true;
  end;
  assert rejected, 'a palette whose swatches disagree with its roles was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- Catalogs are readable by an authenticated user and writable by nobody
-- ---------------------------------------------------------------------------
do $$
declare
  n int;
begin
  assert (select count(*) from pg_policies
           where schemaname='public' and tablename='tone_cards') = 1,
         'tone_cards must carry exactly one policy';
  assert (select cmd from pg_policies
           where schemaname='public' and tablename='tone_cards') = 'SELECT',
         'the single tone_cards policy must be a SELECT policy';
  -- no write policy anywhere in the catalog
  assert not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename in ('tone_cards','palette_families','type_pairings','client_persona_cards',
                         'problem_cards','gain_cards','ethics_rules','license_types',
                         'specialties','site_goals','primary_actions')
       and cmd <> 'SELECT'),
    'a catalog table carries a write policy';
end
$$;

do $$
declare
  rejected boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  assert (select count(*) from public.tone_cards) = 6,
         'an authenticated user must be able to read the tone cards';

  begin
    insert into public.tone_cards (id, sort_order, sample_hero, keywords)
    values ('injected', 97, 'x', array['a','b','c']);
    rejected := false;
  exception when insufficient_privilege then rejected := true;
  end;
  assert rejected, 'an authenticated user was able to insert a catalog row';
end
$$;

rollback;
