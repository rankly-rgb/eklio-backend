-- ============================================================================
-- Tests — 20260829111000_site_spec_suggest_hex_bounds.sql
-- ============================================================================
-- THE CORRECTION, NOT THE MEASUREMENT. The contrast ratios are covered in
-- `20260829102000_site_spec_preview_and_contrast.test.sql`, against an
-- independent implementation of WCAG 2.1. This file covers the thing the Fix
-- button actually does.
--
-- The button has to be trustworthy in one click or it is worse than no button:
-- she presses it once, does not re-check the ratio, and moves on. So what is
-- asserted here is that the hex it returns reaches AA, that it is still
-- recognisably the colour she picked, that it never moves the page background,
-- and that when there is no honest answer it says so instead of returning
-- black.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. The correction reaches 4.5:1 — twelve hues around the circle
-- ---------------------------------------------------------------------------
do $$
declare
  deg   numeric;
  sat   numeric;
  lit   numeric;
  start text;
  fix   text;
  bg    text;
  n     int := 0;
begin
  -- every 30° of hue, at three saturations and two starting lightnesses, on
  -- both a light and a dark background: 144 corrections
  foreach deg in array array[0,30,60,90,120,150,180,210,240,270,300,330] loop
    foreach sat in array array[0.25, 0.55, 0.85] loop
      foreach lit in array array[0.62, 0.38] loop
        foreach bg in array array['#F3EDE4', '#241B23'] loop
          start := public.site_spec_hsl_to_hex(deg, sat, lit);
          fix   := public.site_spec_suggest_hex(start, bg);

          if fix is not null then
            assert public.site_spec_contrast_ratio(fix, bg) >= 4.5,
                   format('hue %s sat %s lit %s on %s: the correction %s reaches only %s:1',
                          deg, sat, lit, bg, fix,
                          public.site_spec_contrast_ratio(fix, bg));
            n := n + 1;
          end if;
        end loop;
      end loop;
    end loop;
  end loop;

  assert n >= 100,
         format('only %s of 144 corrections were offered; the walk has become too narrow', n);
end
$$;

-- ---------------------------------------------------------------------------
-- 2. ⚠ Hue is preserved — a terracotta must not come back a brown-grey
-- ---------------------------------------------------------------------------
do $$
declare
  deg  numeric;
  fix  text;
  got  numeric;
  diff numeric;
begin
  foreach deg in array array[0,30,60,90,120,150,180,210,240,270,300,330] loop
    -- start too light to read on the page background, so a correction is needed
    fix := public.site_spec_suggest_hex(public.site_spec_hsl_to_hex(deg, 0.55, 0.62), '#F3EDE4');
    assert fix is not null, format('hue %s got no correction', deg);

    got  := (public.site_spec_hex_to_hsl(fix))[1];
    -- shortest distance around the circle
    diff := abs(((got - deg + 540)::numeric % 360) - 180);
    assert diff <= 1,
           format('hue %s came back as %s, %s degrees away', deg, got, diff);
  end loop;

  -- and saturation survives too: only lightness is supposed to move
  fix := public.site_spec_suggest_hex('#B4674A', '#F3EDE4');   -- a real terracotta
  assert abs((public.site_spec_hex_to_hsl(fix))[2]
             - (public.site_spec_hex_to_hsl('#B4674A'))[2]) <= 0.02,
         'the correction changed the saturation, not just the lightness';
  assert abs(((public.site_spec_hex_to_hsl(fix))[1]
              - (public.site_spec_hex_to_hsl('#B4674A'))[1] + 540)::numeric % 360 - 180) <= 1,
         'the correction changed the hue of a terracotta';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. ⚠ Termination: bounded, and honest when there is no answer
-- ---------------------------------------------------------------------------
do $$
declare
  fix text;
  h   text;
begin
  -- The search is bounded by construction: generate_series over two integer
  -- literals, ninety-one candidates, no iteration and no recursion. This is the
  -- structural assertion that it stays that way.
  assert (select prosrc from pg_proc
           where oid = 'public.site_spec_suggest_hex(text, text, numeric)'::regprocedure)
         like '%generate_series(5, 95)%',
         'the correction no longer walks a fixed, bounded candidate list';
  assert (select prosrc from pg_proc
           where oid = 'public.site_spec_suggest_hex(text, text, numeric)'::regprocedure)
         not like '%loop%',
         'the correction has grown a loop; it was a bounded scan';

  -- ⚠ IT NEVER WALKS INTO THE BAND WHERE THE HUE IS GONE. At lightness 0 and 1
  -- site_spec_hsl_to_hex returns black and white for every hue, so a walk that
  -- reaches them has replaced her colour rather than corrected it.
  foreach h in array array['#808080','#7F7F7F','#6E6E6E','#949494','#A0A0A0',
                           '#C08A3E','#3B2C3A','#B4674A','#22364F'] loop
    fix := public.site_spec_suggest_hex(h, '#808080');
    assert fix is null or fix not in ('#000000', '#FFFFFF'),
           format('%s corrected to %s, which is not a colour she chose', h, fix);
    if fix is not null then
      assert (public.site_spec_hex_to_hsl(fix))[3] between 0.05 and 0.95,
             format('%s corrected outside the bounded lightness range', h);
    end if;
  end loop;

  -- ⚠ THE CASE THAT ACTUALLY CHANGED, measured against the unbounded walk: a
  -- hue-30 colour at 0.5 saturation tops out at 4.25:1 against #767676 inside
  -- the bounded range, so the old walk kept going and returned #040301 — black.
  -- NULL is the honest answer; a correction that does not work would leave the
  -- banner up after the click.
  assert public.site_spec_suggest_hex(public.site_spec_hsl_to_hex(30, 0.5, 0.5), '#767676') is null,
         'an unreachable pair returned a correction anyway';

  -- ⚠ AND THE CORRECTIONS THAT WERE ALREADY RIGHT ARE UNTOUCHED. Bounding the
  -- walk was supposed to remove only the degenerate tail, not move real answers.
  assert public.site_spec_suggest_hex('#C08A3E','#F6F2EA') = '#8F672E',
         'bounding the walk moved the ochre correction';
  assert public.site_spec_suggest_hex('#B4674A','#8A8A8A') = '#331D15',
         'bounding the walk moved the terracotta correction';
  assert public.site_spec_suggest_hex('#808080','#808080') = '#171717',
         'a grey source has no hue to lose; its correction must be unchanged';

  -- raising the target makes more of them unreachable, and that is fine
  assert public.site_spec_suggest_hex('#808080','#808080', 7.0) is null,
         'a 7:1 target on a mid grey must be reported unreachable';

  -- deterministic: the same input gives the same hex, which is what lets the
  -- Fix button be idempotent
  assert public.site_spec_suggest_hex('#C08A3E','#F6F2EA')
       = public.site_spec_suggest_hex('#C08A3E','#F6F2EA'),
         'the correction is not deterministic';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. ⚠ The token that moves is never the page background
-- ---------------------------------------------------------------------------
-- `light_neutral` is the surface five of the six reported pairs are measured
-- against. Darkening it to fix one pair silently changes the other four.
--
-- `dark_neutral` IS movable, and deliberately: for the two neutral-on-neutral
-- pairs there is no brand colour in the pair at all, and "body text on the page
-- background" is the single most important pair on the site. Refusing to fix it
-- would be the wrong kind of purity.
do $$
declare
  pal record;
  c   jsonb;
begin
  for pal in select * from public.palette_families loop
    c := public.site_spec_contrast(jsonb_build_object(
           'primary_hex', pal.primary_hex, 'secondary_hex', pal.secondary_hex,
           'accent_hex', pal.secondary_hex,
           'light_neutral_hex', pal.light_hex, 'dark_neutral_hex', pal.dark_hex,
           'paper_hex', pal.paper_hex));

    -- ⚠ neither surface: `paper` carries five of the seven pairs, the tinted
    -- band one. Correcting either to fix one pair changes every pair on it.
    assert not exists (
      select 1 from jsonb_array_elements(c->'pairs') p
       where p.value->'suggested_fix'->>'token' in ('paper', 'light_neutral')),
      format('%s: a correction moves a surface', pal.id);

    -- every token a correction names is one the spec actually has
    assert not exists (
      select 1 from jsonb_array_elements(c->'pairs') p
       where p.value->'suggested_fix' <> 'null'::jsonb
         and p.value->'suggested_fix'->>'token'
             not in ('primary','secondary','accent','dark_neutral')),
      format('%s: a correction names a token that is not a colour of the spec', pal.id);

    -- and every correction offered actually reaches AA against the other side
    assert not exists (
      select 1 from jsonb_array_elements(c->'pairs') p
       where p.value->'suggested_fix' <> 'null'::jsonb
         and public.site_spec_contrast_ratio(
               p.value->'suggested_fix'->>'hex',
               case when p.value->>'pair_id'
                         in ('cta_label_on_primary','paper_on_dark_neutral')
                    then p.value->>'fg' else p.value->>'bg' end) < 4.5),
      format('%s: a correction does not reach 4.5:1', pal.id);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 5. One click, end to end: the pair passes afterwards
-- ---------------------------------------------------------------------------
insert into auth.users (id,email) values ('aaaaaaaa-0000-0000-0000-000000000001','o@e.com');
insert into public.projects (id,user_id,name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','P');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000001');
insert into public.brand_kits (id,project_id,directions,selected_direction_id) values (
 'cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
 jsonb_build_array(
  jsonb_build_object('id','a','name','Alpha One','rationale',repeat('x',70),
    'palette', jsonb_build_object('primary','#C08A3E','secondary','#6B4B1C','light','#F6F2EA','dark','#2A2118','paper','#FBF8F1'),
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
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c'))),
 'a');

do $$
declare
  kit  uuid := 'cccccccc-0000-0000-0000-000000000001';
  e    jsonb;
  pair jsonb;
  id   text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';

  -- OCHRE & PAPER: its primary on its own page background is 2.71:1
  e := public.site_spec_get(kit);
  select p.value into pair from jsonb_array_elements(e->'contrast'->'pairs') p
   where p.value->>'pair_id' = 'primary_on_paper';
  assert (pair->>'ratio')::numeric = 2.85, 'the fixture pair must fail at 2.85:1';

  -- ⚠ ONE CLICK. Every failing pair the panel shows, fixed in turn, must end AA.
  for id in select p.value->>'pair_id' from jsonb_array_elements(e->'contrast'->'pairs') p
             where p.value->'suggested_fix' <> 'null'::jsonb loop
    e := public.site_spec_fix_contrast(kit, id);
    assert e ? 'spec', format('fixing %s returned an error', id);

    select p.value into pair from jsonb_array_elements(e->'contrast'->'pairs') p
     where p.value->>'pair_id' = id;
    assert (pair->>'ratio')::numeric >= 4.5,
           format('after one click, %s is still %s:1', id, pair->>'ratio');
    assert pair->'suggested_fix' = 'null'::jsonb,
           format('after one click, %s is still offering a fix', id);
  end loop;

  -- the page background was never touched by any of them
  assert e->'spec'->>'paper' = '#FBF8F1',
         'a one-click fix moved the page background';
  assert e->'spec'->>'light_neutral' = '#F6F2EA',
         'a one-click fix moved the section background';

  -- and clicking again is a no-op with a reason, not a second edit
  assert public.site_spec_fix_contrast(kit, 'primary_on_paper')->'error'->>'code'
         = 'no_fix_needed',
         'fixing an already-readable pair was treated as work';

  reset role;
end
$$;

rollback;
