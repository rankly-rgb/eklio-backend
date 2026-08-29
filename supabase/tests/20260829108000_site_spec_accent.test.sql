-- ============================================================================
-- Tests — 20260829108000_site_spec_accent.sql
-- ============================================================================
-- Where the accent comes from, and that it is never a second copy of a swatch
-- the palette already has.
--
-- ΔE is CIE76 over CIELAB D65. The thresholds used below are the published
-- ones: ~2.3 is a just-noticeable difference, ~10 reads as a different color.
-- The floor this feature enforces is 15, which is below the ΔE 18.10 that
-- PLUM & BONE already ships between its own primary and secondary.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- CIELAB, against published reference values
-- ---------------------------------------------------------------------------
do $$
begin
  assert (public.site_spec_lab('#FFFFFF'))[1] = 100, 'white must be L*=100';
  assert (public.site_spec_lab('#000000'))[1] = 0,   'black must be L*=0';

  -- sRGB primaries in CIELAB D65, to two decimals
  assert round((public.site_spec_lab('#FF0000'))[1],2) = 53.23
     and round((public.site_spec_lab('#FF0000'))[2],2) = 80.11
     and round((public.site_spec_lab('#FF0000'))[3],2) = 67.22,
         'sRGB red does not land on its published Lab value';
  assert round((public.site_spec_lab('#00FF00'))[1],2) = 87.74,
         'sRGB green does not land on its published L*';
  assert round((public.site_spec_lab('#0000FF'))[1],2) = 32.30,
         'sRGB blue does not land on its published L*';

  assert public.site_spec_delta_e('#3B2C3A','#3B2C3A') = 0,
         'a color must be at distance 0 from itself';
  assert public.site_spec_delta_e('#000000','#FFFFFF') = 100,
         'black to white must be ΔE 100';
  -- symmetric
  assert public.site_spec_delta_e('#B4674A','#C08A3E') = public.site_spec_delta_e('#C08A3E','#B4674A'),
         'ΔE must be symmetric';

  -- ⚠ The calibration of the 15 floor. If this ever fails, the floor is above
  -- what the product itself treats as two distinguishable swatches.
  assert public.site_spec_delta_e('#3B2C3A','#4A5361') = 18.10,
         'PLUM & BONE primary/secondary is no longer ΔE 18.10; recheck the 15 floor';
  assert public.site_spec_delta_e('#B4674A','#C08A3E') = 25.37,
         'CLAY & SAND primary/secondary is no longer ΔE 25.37; recheck the 15 floor';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ The accent is a third color, on every palette this product ships
-- ---------------------------------------------------------------------------
-- Two identical swatches under two different labels reads as a bug in the
-- editor: she would move the accent and watch the secondary follow.
do $$
declare
  r   record;
  acc text;
begin
  for r in select id, primary_hex, secondary_hex, light_hex from public.palette_families loop
    acc := public.site_spec_derive_accent(r.primary_hex, r.secondary_hex, r.light_hex);

    assert acc is not null, format('%s derived no accent', r.id);
    assert acc ~ '^#[0-9A-F]{6}$', format('%s derived a malformed accent %s', r.id, acc);

    assert acc <> r.primary_hex,
           format('%s derived an accent identical to its primary', r.id);
    assert acc <> r.secondary_hex,
           format('%s derived an accent identical to its secondary', r.id);

    assert public.site_spec_delta_e(acc, r.primary_hex) >= 15,
           format('%s: accent is only ΔE %s from the primary',
                  r.id, public.site_spec_delta_e(acc, r.primary_hex));
    assert public.site_spec_delta_e(acc, r.secondary_hex) >= 15,
           format('%s: accent is only ΔE %s from the secondary',
                  r.id, public.site_spec_delta_e(acc, r.secondary_hex));

    -- it is painted on the page background, so it has to be readable there
    assert public.site_spec_contrast_ratio(acc, r.light_hex) >= 4.5,
           format('%s: accent is %s:1 on its own page background',
                  r.id, public.site_spec_contrast_ratio(acc, r.light_hex));
  end loop;
end
$$;

-- Deterministic, and total even on degenerate input.
do $$
declare
  h text;
begin
  assert public.site_spec_derive_accent('#3B2C3A','#4A5361','#F3EDE4')
       = public.site_spec_derive_accent('#3B2C3A','#4A5361','#F3EDE4'),
         'the derivation is not deterministic';

  -- ⚠ TOTAL. The column it feeds is NOT NULL and sits behind the AFTER trigger
  -- on direction selection: a NULL here is a direction that cannot be chosen.
  foreach h in array array['#000000','#FFFFFF','#808080','#010203','#FEFEFE'] loop
    assert public.site_spec_derive_accent(h, h, '#F3EDE4') is not null,
           format('no accent derived for the degenerate primary %s', h);
    assert public.site_spec_derive_accent(h, h, '#F3EDE4') ~ '^#[0-9A-F]{6}$',
           format('malformed accent for the degenerate primary %s', h);
  end loop;

  -- a grey primary must not yield a grey accent: the saturation floor exists
  -- for exactly this
  assert (public.site_spec_hex_to_hsl(public.site_spec_derive_accent('#808080','#606060','#F3EDE4')))[2] > 0.1,
         'a grey primary produced a grey accent';
end
$$;

-- ---------------------------------------------------------------------------
-- Reading a role out of either palette shape
-- ---------------------------------------------------------------------------
do $$
declare
  v5   jsonb := '{"primary":"#3B2C3A","secondary":"#4A5361","accent":"#C08A3E",
                  "light_neutral":"#F3EDE4","dark_neutral":"#241B23"}'::jsonb;
  repo jsonb := '{"primary":"#3B2C3A","secondary":"#4A5361","light":"#F3EDE4",
                  "dark":"#241B23","paper":"#FAF7F2"}'::jsonb;
begin
  -- the product spec's shape
  assert public.site_spec_palette_role(v5, 'accent')        = '#C08A3E', 'v5 accent';
  assert public.site_spec_palette_role(v5, 'light_neutral') = '#F3EDE4', 'v5 light_neutral';
  assert public.site_spec_palette_role(v5, 'dark_neutral')  = '#241B23', 'v5 dark_neutral';

  -- this repo's shape, which the Lot 5 CHECK actually requires
  assert public.site_spec_palette_role(repo, 'light_neutral') = '#F3EDE4', 'repo light';
  assert public.site_spec_palette_role(repo, 'dark_neutral')  = '#241B23', 'repo dark';
  assert public.site_spec_palette_role(repo, 'accent') is null,
         'this repo''s palette shape has no accent and must say so';

  -- absent or malformed resolves to NULL so the caller can fall back
  assert public.site_spec_palette_role('{}'::jsonb, 'primary') is null, 'absent role';
  assert public.site_spec_palette_role('{"accent":"not a hex"}'::jsonb, 'accent') is null,
         'malformed role';
  -- normalised to uppercase like every other hex on the write path
  assert public.site_spec_palette_role('{"accent":"#c08a3e"}'::jsonb, 'accent') = '#C08A3E',
         'a lowercase role must be uppercased';
end
$$;

-- ---------------------------------------------------------------------------
-- End to end: what the seeder actually writes, for both palette shapes
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000001','o@e.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Repo shape'),
  ('bbbbbbbb-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','Spec shape');
insert into public.project_briefs (project_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001'), ('bbbbbbbb-0000-0000-0000-000000000002');

-- A direction carrying this repo's five roles: no accent to read.
insert into public.brand_kits (id, project_id, directions, selected_direction_id) values (
 'cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
 jsonb_build_array(
  jsonb_build_object('id','a','name','Alpha One','rationale',repeat('x',70),
    'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361',
                                  'light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','b','name','Beta Two','rationale',repeat('y',70),
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E',
                                  'light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
    'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','c','name','Gamma Three','rationale',repeat('z',70),
    'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168',
                                  'light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
    'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c'))),
 'a');

do $$
declare
  s public.site_specs%rowtype;
begin
  select * into s from public.site_specs where brand_kit_id='cccccccc-0000-0000-0000-000000000001';

  assert s.accent_hex is not null, 'the seeded spec has no accent';
  -- ⚠ THE REGRESSION THIS FILE EXISTS FOR
  assert s.accent_hex <> s.secondary_hex,
         'the accent is a copy of the secondary; two identical swatches under two labels is a bug in the editor';
  assert s.accent_hex <> s.primary_hex, 'the accent is a copy of the primary';
  assert public.site_spec_delta_e(s.accent_hex, s.primary_hex)   >= 15, 'accent too close to primary';
  assert public.site_spec_delta_e(s.accent_hex, s.secondary_hex) >= 15, 'accent too close to secondary';
  assert public.site_spec_contrast_ratio(s.accent_hex, s.light_neutral_hex) >= 4.5,
         'the seeded accent is not legible on the page background';

  -- the four roles that do line up came through untouched
  assert s.primary_hex       = '#3B2C3A', 'primary';
  assert s.secondary_hex     = '#4A5361', 'secondary';
  assert s.light_neutral_hex = '#F3EDE4', 'light neutral from the palette light role';
  assert s.dark_neutral_hex  = '#241B23', 'dark neutral from the palette dark role';
end
$$;

-- ⚠ A direction carrying the PRODUCT SPEC's palette shape. Before this
-- migration the Lot 5 CHECK accepted the row (its validator returns NULL, and
-- a CHECK passes on NULL) and then direction selection died on the NOT NULL of
-- site_specs.light_neutral_hex — a kit that stores fine becoming a direction
-- that cannot be chosen.
insert into public.brand_kits (id, project_id, directions) values (
 'cccccccc-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002',
 jsonb_build_array(
  jsonb_build_object('id','a','name','Alpha One','rationale',repeat('x',70),
    'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','accent','#C08A3E',
                                  'light_neutral','#F3EDE4','dark_neutral','#241B23'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','b','name','Beta Two','rationale',repeat('y',70),
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','accent','#6B4B1C',
                                  'light_neutral','#F4EEE3','dark_neutral','#2B2A27'),
    'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','c','name','Gamma Three','rationale',repeat('z',70),
    'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','accent','#C08A3E',
                                  'light_neutral','#EDEAE5','dark_neutral','#16202E'),
    'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c'))));

do $$
begin
  -- this is the line that used to raise
  update public.brand_kits set selected_direction_id = 'a'
   where id = 'cccccccc-0000-0000-0000-000000000002';

  assert (select count(*) from public.site_specs
           where brand_kit_id='cccccccc-0000-0000-0000-000000000002') = 1,
         'a direction carrying the product spec''s palette shape could not be chosen';

  -- and its accent is taken verbatim, not derived
  assert (select accent_hex from public.site_specs
           where brand_kit_id='cccccccc-0000-0000-0000-000000000002') = '#C08A3E',
         'a palette that carries an accent must have it used, not overwritten by a derivation';
  assert (select light_neutral_hex from public.site_specs
           where brand_kit_id='cccccccc-0000-0000-0000-000000000002') = '#F3EDE4',
         'the light_neutral naming did not resolve';
  assert (select dark_neutral_hex from public.site_specs
           where brand_kit_id='cccccccc-0000-0000-0000-000000000002') = '#241B23',
         'the dark_neutral naming did not resolve';
end
$$;

-- ⚠ And a palette missing roles entirely, which the Lot 5 CHECK also accepts.
-- Seeding must still not be able to make a direction unchoosable.
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','Broken shape');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000003');
insert into public.brand_kits (id, project_id, directions) values (
 'cccccccc-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000003',
 jsonb_build_array(
  jsonb_build_object('id','a','name','Alpha One','rationale',repeat('x',70),
    'palette', jsonb_build_object('primary','#3B2C3A'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','b','name','Beta Two','rationale',repeat('y',70),
    'palette', '{}'::jsonb,
    'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','c','name','Gamma Three','rationale',repeat('z',70),
    'palette', '{}'::jsonb,
    'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c'))));

do $$
declare
  s public.site_specs%rowtype;
begin
  update public.brand_kits set selected_direction_id = 'b'   -- the empty palette
   where id = 'cccccccc-0000-0000-0000-000000000003';

  select * into s from public.site_specs where brand_kit_id='cccccccc-0000-0000-0000-000000000003';
  assert s.id is not null,
         'a direction with an empty palette could not be chosen; seeding broke selection';
  -- every role fell back to CLAY & SAND, the family brief_preview also falls back to
  assert s.primary_hex   = (select primary_hex   from public.palette_families where id='clay_sand'),
         'the primary did not fall back to CLAY & SAND';
  assert s.light_neutral_hex = (select light_hex from public.palette_families where id='clay_sand'),
         'the light neutral did not fall back to CLAY & SAND';
  assert s.accent_hex <> s.secondary_hex, 'even the fallback palette must get a distinct accent';
end
$$;

rollback;
