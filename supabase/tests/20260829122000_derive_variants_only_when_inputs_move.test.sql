-- ============================================================================
-- Tests — 20260829122000_derive_variants_only_when_inputs_move.sql
-- ============================================================================
-- The trigger stopped doing work. It must not have stopped doing its job.
--
-- Two things have to hold, and they pull in opposite directions:
--
--   1. A write that cannot have changed a derived colour must not recompute it
--      — that is the whole point, and it is worth ~120 ms per PATCH.
--   2. A write that CAN have changed one must still recompute it, and a client
--      must still never be able to set one by hand.
--
-- The dangerous failure is silent: a stale variant is a valid hex, so nothing
-- raises. It just quietly stops matching the colour it is supposed to track.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','nora@elmandember.com');
insert into public.projects (id, user_id, name) values
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Elm & Ember');
insert into public.project_briefs (project_id, practice_name, license_type_id, city, state)
values ('22222222-2222-2222-2222-222222222222','Elm & Ember Therapy','lcsw','Portland','OR');

-- CLAY & SAND: the case that pays. Its primary and secondary both need a text
-- variant, and white does not read on its primary, so three of the four
-- derivations run a lightness walk on every write.

-- ⚠ These tests exercise the PAID product. Since 20260829123000 the site spec
-- RPCs refuse an unentitled owner with `payment_required`, so the fixture has to
-- buy the kit like a real one does.
insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values
  ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222','starter','cs_test_1',4900,'paid',now());

insert into public.brand_kits (id, project_id, directions, selected_direction_id) values (
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
 'warm_welcome');

-- ---------------------------------------------------------------------------
-- ⚠ The values did not change — only the work did
-- ---------------------------------------------------------------------------
-- The seed goes through the INSERT branch, where there is no OLD row to carry
-- anything forward from, so all four must be derived from scratch.
do $$
declare s public.site_specs%rowtype;
begin
  select * into s from public.site_specs
   where brand_kit_id = '33333333-3333-3333-3333-333333333333';

  assert s.primary_text_hex   = public.site_spec_text_variant(s.primary_hex,   s.paper_hex)
     and s.secondary_text_hex = public.site_spec_text_variant(s.secondary_hex, s.paper_hex)
     and s.accent_text_hex    = public.site_spec_text_variant(s.accent_hex,    s.paper_hex)
     and s.cta_ink_hex        = public.site_spec_cta_ink(s.primary_hex, s.dark_neutral_hex),
         'a seeded spec does not agree with a full recompute';

  -- and this fixture must actually be the expensive case, or the file proves
  -- nothing. Primary and secondary both need a walk to read on this paper, and
  -- white does not read on this primary so the CTA ink walks too.
  assert s.primary_text_hex   <> s.primary_hex,   'the fixture primary needs no variant';
  assert s.secondary_text_hex <> s.secondary_hex, 'the fixture secondary needs no variant';
  assert s.cta_ink_hex        <> '#FFFFFF',       'the fixture CTA ink did not need a walk';
  -- ⚠ the accent is deliberately NOT in that list. The curated accents were
  -- picked to read on paper — clay_sand's is 9.03:1 — so its variant is the
  -- colour itself and no walk runs. That is the cheap path, and it is correct.
  assert s.accent_text_hex = s.accent_hex,
         'the curated accent stopped reading on paper as itself';
end
$$;

-- ---------------------------------------------------------------------------
-- A write that cannot have moved them must leave them alone
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  b   public.site_specs%rowtype;
  a   public.site_specs%rowtype;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  select * into b from public.site_specs where brand_kit_id = kit;
  perform public.site_spec_patch(kit, '{"about_excerpt":"Edited, and no colour was touched."}');
  select * into a from public.site_specs where brand_kit_id = kit;

  assert a.spec_version = b.spec_version + 1, 'the fixture patch did not actually write';
  assert (a.primary_text_hex, a.secondary_text_hex, a.accent_text_hex, a.cta_ink_hex)
       = (b.primary_text_hex, b.secondary_text_hex, b.accent_text_hex, b.cta_ink_hex),
         'a copy edit changed a derived colour';

  -- the same for every other write that touches no colour input
  perform public.site_spec_patch(kit, '{"heading_font":"Newsreader"}');
  perform public.site_spec_patch(kit, '{"extra_instructions":"Tuesdays only."}');
  perform public.site_spec_set_target(kit, 'squarespace');
  select * into a from public.site_specs where brand_kit_id = kit;
  assert (a.primary_text_hex, a.secondary_text_hex, a.accent_text_hex, a.cta_ink_hex)
       = (b.primary_text_hex, b.secondary_text_hex, b.accent_text_hex, b.cta_ink_hex),
         'a non-colour write changed a derived colour';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ A write that CAN move them still does, input by input
-- ---------------------------------------------------------------------------
-- This is the half that a "skip the work" change gets wrong. Each derived
-- colour has its own inputs, and each must react to exactly those.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  b   public.site_specs%rowtype;
  a   public.site_specs%rowtype;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  -- primary moves primary_text AND cta_ink, and nothing else
  select * into b from public.site_specs where brand_kit_id = kit;
  perform public.site_spec_patch(kit, '{"primary":"#7A3E2A"}');
  select * into a from public.site_specs where brand_kit_id = kit;
  assert a.primary_text_hex = public.site_spec_text_variant('#7A3E2A', a.paper_hex),
         'moving the primary did not re-derive its text variant';
  assert a.cta_ink_hex = public.site_spec_cta_ink('#7A3E2A', a.dark_neutral_hex),
         'moving the primary did not re-derive the CTA ink';
  assert a.secondary_text_hex = b.secondary_text_hex
     and a.accent_text_hex    = b.accent_text_hex,
         'moving the primary disturbed a variant it does not feed';

  -- secondary moves only its own
  select * into b from public.site_specs where brand_kit_id = kit;
  perform public.site_spec_patch(kit, '{"secondary":"#8A6224"}');
  select * into a from public.site_specs where brand_kit_id = kit;
  assert a.secondary_text_hex = public.site_spec_text_variant('#8A6224', a.paper_hex),
         'moving the secondary did not re-derive its text variant';
  assert a.primary_text_hex = b.primary_text_hex and a.accent_text_hex = b.accent_text_hex
     and a.cta_ink_hex = b.cta_ink_hex,
         'moving the secondary disturbed something it does not feed';

  -- accent moves only its own
  select * into b from public.site_specs where brand_kit_id = kit;
  perform public.site_spec_patch(kit, '{"accent":"#4E2216"}');
  select * into a from public.site_specs where brand_kit_id = kit;
  assert a.accent_text_hex = public.site_spec_text_variant('#4E2216', a.paper_hex),
         'moving the accent did not re-derive its text variant';
  assert a.primary_text_hex = b.primary_text_hex and a.secondary_text_hex = b.secondary_text_hex
     and a.cta_ink_hex = b.cta_ink_hex,
         'moving the accent disturbed something it does not feed';

  -- ⚠ paper feeds ALL THREE text variants. It is the shared input, and the one
  -- a per-colour skip is most likely to forget.
  select * into b from public.site_specs where brand_kit_id = kit;
  perform public.site_spec_patch(kit, '{"paper":"#2A2622"}');
  select * into a from public.site_specs where brand_kit_id = kit;
  assert a.primary_text_hex   = public.site_spec_text_variant(a.primary_hex,   '#2A2622')
     and a.secondary_text_hex = public.site_spec_text_variant(a.secondary_hex, '#2A2622')
     and a.accent_text_hex    = public.site_spec_text_variant(a.accent_hex,    '#2A2622'),
         'changing the page background did not re-derive all three text variants';
  assert a.primary_text_hex is distinct from b.primary_text_hex,
         'a page background dark enough to change the answer did not change it';
  assert a.cta_ink_hex = b.cta_ink_hex,
         'the page background moved the CTA ink, which is measured on the fill';

  -- dark_neutral feeds only the CTA ink
  perform public.site_spec_patch(kit, '{"paper":"#FAF6EE"}');
  select * into b from public.site_specs where brand_kit_id = kit;
  perform public.site_spec_patch(kit, '{"dark_neutral":"#101010"}');
  select * into a from public.site_specs where brand_kit_id = kit;
  assert a.cta_ink_hex = public.site_spec_cta_ink(a.primary_hex, '#101010'),
         'moving the body text colour did not re-derive the CTA ink';
  assert (a.primary_text_hex, a.secondary_text_hex, a.accent_text_hex)
       = (b.primary_text_hex, b.secondary_text_hex, b.accent_text_hex),
         'moving the body text colour disturbed a text variant';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ The skip path assigns OLD, it does not leave NEW alone
-- ---------------------------------------------------------------------------
-- The difference matters. If the trigger simply returned early on a non-colour
-- write, a caller who submitted a variant would have it stored — and these
-- columns exist precisely because she never sets one by hand.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  b   public.site_specs%rowtype;
  a   public.site_specs%rowtype;
begin
  reset role;   -- as privileged a writer as exists; the trigger still wins
  select * into b from public.site_specs where brand_kit_id = kit;

  -- a write that changes no colour input, but submits all four variants
  update public.site_specs
     set about_excerpt     = 'unrelated',
         primary_text_hex  = '#FF00FF',
         secondary_text_hex= '#FF00FF',
         accent_text_hex   = '#FF00FF',
         cta_ink_hex       = '#FF00FF'
   where brand_kit_id = kit;
  select * into a from public.site_specs where brand_kit_id = kit;
  assert (a.primary_text_hex, a.secondary_text_hex, a.accent_text_hex, a.cta_ink_hex)
       = (b.primary_text_hex, b.secondary_text_hex, b.accent_text_hex, b.cta_ink_hex),
         'a submitted variant was stored on a write that skipped the derivation';

  -- and on a write that DOES change an input, the submitted value loses to the
  -- derivation rather than to the old value
  update public.site_specs
     set primary_hex = '#B4674A', primary_text_hex = '#FF00FF'
   where brand_kit_id = kit;
  select * into a from public.site_specs where brand_kit_id = kit;
  assert a.primary_text_hex = public.site_spec_text_variant('#B4674A', a.paper_hex),
         'a submitted variant survived a write that re-derives it';
end
$$;

-- ---------------------------------------------------------------------------
-- Every shipped family, both paths, same answer
-- ---------------------------------------------------------------------------
-- The cheapest proof that skipping did not change any value: derive each family
-- from scratch, then walk it through a write that skips, and compare.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  f   record;
  a   public.site_specs%rowtype;
begin
  reset role;
  for f in select * from public.palette_families order by id loop
    update public.site_specs
       set primary_hex = f.primary_hex, secondary_hex = f.secondary_hex,
           accent_hex = f.accent_hex, light_neutral_hex = f.light_hex,
           dark_neutral_hex = f.dark_hex, paper_hex = f.paper_hex
     where brand_kit_id = kit;
    -- a write that skips every derivation
    update public.site_specs set about_excerpt = 'skip ' || f.id where brand_kit_id = kit;

    select * into a from public.site_specs where brand_kit_id = kit;
    assert a.primary_text_hex   = f.primary_text_hex
       and a.secondary_text_hex = f.secondary_text_hex
       and a.accent_text_hex    = f.accent_text_hex
       and a.cta_ink_hex        = f.cta_ink_hex,
      format('%s: the carried-forward variants disagree with the curated ones (%s/%s/%s/%s vs %s/%s/%s/%s)',
             f.id, a.primary_text_hex, a.secondary_text_hex, a.accent_text_hex, a.cta_ink_hex,
             f.primary_text_hex, f.secondary_text_hex, f.accent_text_hex, f.cta_ink_hex);
  end loop;
end
$$;

rollback;
