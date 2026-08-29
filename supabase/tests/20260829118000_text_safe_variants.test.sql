-- ============================================================================
-- Tests — 20260829118000_text_safe_variants.sql
-- ============================================================================
-- 4.5:1 is a text legibility threshold. A brand colour that fails it as text is
-- not a wrong colour — one of its uses is wrong. So the brand colour is kept
-- byte-identical and gains a variant used only where it renders as text.
--
-- What has to hold: the curated hexes never move, a colour that already passes
-- is not touched, the variant is still recognisably the same colour, it is
-- derived and never editable, and it is never something she is asked to fix.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- ⚠ THE CURATED HEXES DID NOT MOVE
-- ---------------------------------------------------------------------------
-- The entire justification for the variant is that nothing a person chose
-- changes. If this fails, the exercise was pointless.
do $$
begin
  assert (select count(*) from public.palette_families pf
           where (pf.id, pf.primary_hex, pf.secondary_hex, pf.accent_hex) in (
             ('plum_bone',      '#3B2C3A', '#4A5361', '#6E2F44'),
             ('clay_sand',      '#B4674A', '#C08A3E', '#6E3320'),
             ('ink_blue_chalk', '#22364F', '#7A8168', '#8F5324'),
             ('olive_chalk',    '#7A8168', '#3F4536', '#8C5624'),
             ('ochre_paper',    '#C08A3E', '#6B4B1C', '#A34A2A'),
             ('slate_bone',     '#4A5361', '#2F3742', '#8E4A3C'))) = 6,
         'a curated brand hex moved; the variant exists precisely so that none does';
end
$$;

-- ---------------------------------------------------------------------------
-- Every family, every text-on-paper pair, ≥ 4.5
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  c jsonb;
  n int;
begin
  for r in select * from public.palette_families order by sort_order loop
    c := public.site_spec_contrast(jsonb_build_object(
      'primary_hex', r.primary_hex, 'secondary_hex', r.secondary_hex,
      'accent_hex', r.accent_hex, 'light_neutral_hex', r.light_hex,
      'dark_neutral_hex', r.dark_hex, 'paper_hex', r.paper_hex,
      'primary_text_hex', r.primary_text_hex,
      'secondary_text_hex', r.secondary_text_hex,
      'accent_text_hex', r.accent_text_hex));

    select count(*) into n from jsonb_array_elements(c->'pairs') p
     where p.value->>'pair_id' in ('primary_on_paper','secondary_on_paper','accent_on_paper')
       and (p.value->>'ratio')::numeric < 4.5;
    assert n = 0, format('%s: %s of the three text-on-paper pairs still below AA', r.id, n);

    -- and the three measure the VARIANT, not the brand colour
    assert (select p.value->>'fg' from jsonb_array_elements(c->'pairs') p
             where p.value->>'pair_id' = 'primary_on_paper') = r.primary_text_hex,
           format('%s: primary_on_paper is not measuring the text variant', r.id);
    assert (select p.value->>'fg' from jsonb_array_elements(c->'pairs') p
             where p.value->>'pair_id' = 'secondary_on_paper') = r.secondary_text_hex,
           format('%s: secondary_on_paper is not measuring the text variant', r.id);
    assert (select p.value->>'fg' from jsonb_array_elements(c->'pairs') p
             where p.value->>'pair_id' = 'accent_on_paper') = r.accent_text_hex,
           format('%s: accent_on_paper is not measuring the text variant', r.id);

    -- ⚠ cta_label_on_primary is UNCHANGED and must be: a label on a FILL, and
    -- the fill is the brand colour.
    assert (select p.value->>'bg' from jsonb_array_elements(c->'pairs') p
             where p.value->>'pair_id' = 'cta_label_on_primary') = r.primary_hex,
           format('%s: the button pair stopped measuring the brand fill', r.id);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ A colour that already passes is NOT moved
-- ---------------------------------------------------------------------------
-- Not a rounded near-miss of itself: the same string. Four of the eighteen
-- shipped brand colours need no variant and must come back untouched.
do $$
declare
  r record;
  untouched int := 0;
begin
  for r in select * from public.palette_families loop
    if public.site_spec_contrast_ratio(r.primary_hex, r.paper_hex) >= 4.5 then
      assert r.primary_text_hex = r.primary_hex,
             format('%s: the primary already passed and was moved anyway', r.id);
      untouched := untouched + 1;
    end if;
    if public.site_spec_contrast_ratio(r.secondary_hex, r.paper_hex) >= 4.5 then
      assert r.secondary_text_hex = r.secondary_hex,
             format('%s: the secondary already passed and was moved anyway', r.id);
      untouched := untouched + 1;
    end if;
    if public.site_spec_contrast_ratio(r.accent_hex, r.paper_hex) >= 4.5 then
      assert r.accent_text_hex = r.accent_hex,
             format('%s: the accent already passed and was moved anyway', r.id);
      untouched := untouched + 1;
    end if;
  end loop;
  assert untouched >= 10,
         format('only %s of 18 brand colours needed no variant; expected most of them', untouched);

  -- the function itself, on a colour that plainly passes
  assert public.site_spec_text_variant('#000000', '#FFFFFF') = '#000000',
         'black on white was moved';
  -- and one that plainly does not
  assert public.site_spec_text_variant('#FFFF00', '#FFFFFF') <> '#FFFF00',
         'yellow on white was left illegible';
end
$$;

-- ---------------------------------------------------------------------------
-- The variant is still the same colour
-- ---------------------------------------------------------------------------
-- Saturation within 0.02 everywhere. Hue within 1° where 1° is representable,
-- and within 3° below 0.20 saturation where it is not: at OLIVE & CHALK's
-- chroma one 8-bit step on a channel moves the hue by up to 2.61°, so a tighter
-- promise there would be a promise sRGB cannot keep.
do $$
declare
  r   record;
  col text; hb text; ht text;
  sat numeric; ds numeric; dh numeric; tol numeric;
begin
  for r in select * from public.palette_families order by sort_order loop
    foreach col in array array['primary','secondary','accent'] loop
      case col
        when 'primary'   then hb := r.primary_hex;   ht := r.primary_text_hex;
        when 'secondary' then hb := r.secondary_hex; ht := r.secondary_text_hex;
        else                  hb := r.accent_hex;    ht := r.accent_text_hex;
      end case;
      sat := (public.site_spec_hex_to_hsl(hb))[2];
      ds  := abs((public.site_spec_hex_to_hsl(ht))[2] - sat);
      dh  := abs((((public.site_spec_hex_to_hsl(ht))[1]
                   - (public.site_spec_hex_to_hsl(hb))[1] + 540)::numeric % 360) - 180);
      tol := case when sat >= 0.20 then 1.0 else 3.0 end;

      assert ds <= 0.02,
             format('%s %s: saturation moved by %s (limit 0.02)', r.id, col, ds);
      assert dh <= tol,
             format('%s %s: hue moved by %s° at saturation %s (limit %s°)',
                    r.id, col, dh, round(sat,3), tol);
      -- and it is never lighter: a text variant only ever darkens on a light page
      assert (public.site_spec_hex_to_hsl(ht))[3] <= (public.site_spec_hex_to_hsl(hb))[3],
             format('%s %s: the text variant is lighter than the brand colour', r.id, col);
    end loop;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Derived, never set: the spec side
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111','n@e.com');
insert into public.projects (id, user_id, name) values
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Elm & Ember');
insert into public.project_briefs (project_id) values ('22222222-2222-2222-2222-222222222222');
insert into public.brand_kits (id, project_id, directions, selected_direction_id) values (
 '33333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222',
 jsonb_build_array(
  jsonb_build_object('id','a','name','Alpha One','rationale',repeat('x',70),
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E',
                                  'light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'about_excerpt','x','tone_keywords',jsonb_build_array('a','b','c')),
  jsonb_build_object('id','b','name','Beta Two','rationale',repeat('y',70),
    'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361',
                                  'light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
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
  select * into s from public.site_specs where brand_kit_id='33333333-3333-3333-3333-333333333333';
  -- seeded from the family, without anyone asking
  assert s.secondary_hex = '#C08A3E', 'the fixture secondary';
  assert s.secondary_text_hex = public.site_spec_text_variant('#C08A3E', s.paper_hex),
         'the seeded variant does not match the rule';
  assert s.secondary_text_hex <> s.secondary_hex,
         'this fixture secondary should have needed a variant';
  assert s.primary_text_hex is not null and s.accent_text_hex is not null,
         'a variant was left null at seed';
end
$$;

-- ⚠ CHANGING A BRAND COLOUR RECOMPUTES ITS VARIANT ON THE SAME WRITE
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  e   jsonb;
  s   public.site_specs%rowtype;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  e := public.site_spec_patch(kit, '{"primary":"#C08A3E"}');
  assert e ? 'spec', 'the patch was refused';
  -- the envelope returned by that same call already carries the new variant
  assert e->'preview'->'tokens'->>'primary' = '#C08A3E', 'the brand colour did not take';
  assert e->'preview'->'tokens'->>'primary_text'
         = public.site_spec_text_variant('#C08A3E', e->'preview'->'tokens'->>'paper'),
         'the variant was not recomputed in the same envelope';
  assert e->'preview'->'tokens'->>'primary_text' <> '#C08A3E',
         'this brand colour needs a variant and did not get one';

  -- and it is stored, not just rendered
  select * into s from public.site_specs where brand_kit_id = kit;
  assert s.primary_text_hex = e->'preview'->'tokens'->>'primary_text',
         'the stored variant disagrees with the returned one';

  -- ⚠ changing the PAGE recomputes all three, because the surface moved
  e := public.site_spec_patch(kit, '{"paper":"#2B2A27"}');
  select * into s from public.site_specs where brand_kit_id = kit;
  assert s.primary_text_hex   = public.site_spec_text_variant(s.primary_hex,   '#2B2A27')
     and s.secondary_text_hex = public.site_spec_text_variant(s.secondary_hex, '#2B2A27')
     and s.accent_text_hex    = public.site_spec_text_variant(s.accent_hex,    '#2B2A27'),
         'moving the page background did not recompute the variants against it';

  perform public.site_spec_reset(kit, 'colors');
  select * into s from public.site_specs where brand_kit_id = kit;
  assert s.primary_text_hex = public.site_spec_text_variant(s.primary_hex, s.paper_hex),
         'a reset left a stale variant';
end
$$;

-- ⚠ Never editable, never a fix target
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  e   jsonb;
  ok  boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  e := public.site_spec_get(kit);

  -- rendered, so the mockup can paint text in a brand colour
  assert e->'preview'->'tokens' ?& array['primary_text','secondary_text','accent_text'],
         'the mockup has no variant to paint text with';
  -- but not editable, and not shown as a swatch she owns
  assert not (e->'spec' ?| array['primary_text','secondary_text','accent_text',
                                 'primary_text_hex','secondary_text_hex','accent_text_hex']),
         'a derived variant leaked into the editable spec';
  assert not (public.site_spec_patchable_keys() && array['primary_text','secondary_text','accent_text']),
         'a derived variant became patchable';

  assert public.site_spec_patch(kit, '{"primary_text":"#000000"}')->'error'->>'code'
         = 'unknown_field', 'a variant was accepted as a patch field';

  -- and no contrast pair may ever ask her to move one
  assert not exists (
    select 1 from jsonb_array_elements(e->'contrast'->'pairs') p
     where p.value->'suggested_fix'->>'token' like '%_text'),
         'a variant was offered as a suggested_fix token';

  -- a direct write is refused too: the column was never granted
  begin
    update public.site_specs set primary_text_hex = '#000000' where brand_kit_id = kit;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client was able to write a derived variant directly';

  reset role;
end
$$;

-- Even a service-role write cannot leave a stale variant: the trigger owns it.
do $$
declare s public.site_specs%rowtype;
begin
  update public.site_specs set primary_text_hex = '#000000'
   where brand_kit_id = '33333333-3333-3333-3333-333333333333';
  select * into s from public.site_specs where brand_kit_id='33333333-3333-3333-3333-333333333333';
  assert s.primary_text_hex <> '#000000',
         'a direct write left a hand-set variant in place; the trigger must own the value';
  assert s.primary_text_hex = public.site_spec_text_variant(s.primary_hex, s.paper_hex),
         'the trigger did not restore the derived value';
end
$$;

rollback;
