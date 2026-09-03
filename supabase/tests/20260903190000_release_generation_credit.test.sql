-- ============================================================================
-- Tests — 20260903190000_release_generation_credit.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('a1111111-1111-1111-1111-111111111111', 'her@example.com'),
  ('a2222222-2222-2222-2222-222222222222', 'stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('a3333333-3333-3333-3333-333333333333', 'a1111111-1111-1111-1111-111111111111', 'Her Practice'),
  ('a4444444-4444-4444-4444-444444444444', 'a2222222-2222-2222-2222-222222222222', 'Someone Else');
insert into public.project_briefs (project_id, practice_name, license_type_id, city, state)
values
  ('a3333333-3333-3333-3333-333333333333', 'Her Practice', 'lcsw', 'Portland', 'OR'),
  ('a4444444-4444-4444-4444-444444444444', 'Someone Else', 'lcsw', 'Salem', 'OR');
insert into public.brand_kits (id, project_id) values
  ('a5555555-5555-5555-5555-555555555555', 'a3333333-3333-3333-3333-333333333333'),
  ('a6666666-6666-6666-6666-666666666666', 'a4444444-4444-4444-4444-444444444444');

-- ---------------------------------------------------------------------------
-- The bug, reproduced: a failed first attempt burns the WHOLE
-- directions_generated allowance, and the free tier's regenerations_limit
-- is 1 — a second failure locks her out entirely without a release.
-- ---------------------------------------------------------------------------
do $$
declare
  v_kit uuid := 'a5555555-5555-5555-5555-555555555555';
  v_consumed boolean;
  v_generated int;
  v_regen int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111"}';

  -- First attempt: fails (in reality, the pipeline throws after this call
  -- already ran — brand_kits.directions is never written).
  v_consumed := public.consume_generation_credit(v_kit);
  assert v_consumed is true, 'first consume should succeed';

  select directions_generated, regenerations_used into v_generated, v_regen
    from public.generation_credits where project_id = 'a3333333-3333-3333-3333-333333333333';
  assert v_generated = 3, format('expected directions_generated=3 after one consume, got %s', v_generated);
  assert v_regen = 0, format('expected regenerations_used=0 still, got %s', v_regen);

  -- Without a release, the free-tier retry is charged as a regeneration —
  -- this is the bug. With release_generation_credit called in between (as
  -- the route now does on a genuine pipeline failure), it isn't.
  perform public.release_generation_credit(v_kit);

  select directions_generated, regenerations_used into v_generated, v_regen
    from public.generation_credits where project_id = 'a3333333-3333-3333-3333-333333333333';
  assert v_generated = 0, format('expected directions_generated reset to 0, got %s', v_generated);
  assert v_regen = 0, format('expected regenerations_used reset to 0, got %s', v_regen);

  -- The retry now gets a genuine first attempt, not a regeneration.
  v_consumed := public.consume_generation_credit(v_kit);
  assert v_consumed is true, 'retry after release should consume as a fresh first attempt';
  select directions_generated, regenerations_used into v_generated, v_regen
    from public.generation_credits where project_id = 'a3333333-3333-3333-3333-333333333333';
  assert v_generated = 3, 'retry should have set directions_generated to 3 again, not touched regenerations_used';
  assert v_regen = 0, format('retry should not have touched regenerations_used, got %s', v_regen);

  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- Once directions exist, release refuses — a real deliverable is never
-- retroactively refunded.
-- ---------------------------------------------------------------------------
do $$
declare
  v_kit uuid := 'a5555555-5555-5555-5555-555555555555';
  v_released boolean;
  v_generated int;
begin
  -- Must be a real, valid 3-direction shape — brand_kits carries both a
  -- shape check AND a contrast check on the palette, so hand-picked colors
  -- risk failing one or the other. This is the exact fixture already proven
  -- valid in 20260829123000_entitlement_and_generation_credits.test.sql.
  update public.brand_kits set directions = jsonb_build_array(
    jsonb_build_object('id', 'warm_welcome', 'name', 'Warm Welcome',
      'rationale', 'Warmth without softness. It says the first call will be easier than they think.',
      'palette', jsonb_build_object('primary', '#B4674A', 'secondary', '#C08A3E', 'light', '#F4EEE3', 'dark', '#2B2A27', 'paper', '#FAF6EE'),
      'typography', jsonb_build_object('heading_font', 'Fraunces', 'body_font', 'Nunito Sans', 'google_fonts_url', 'u'),
      'hero', jsonb_build_object('overline', 'LCSW · PORTLAND, OR', 'headline', 'A calmer place to start.',
        'subhead', 'Therapy for adults who hold it together.', 'cta_label', 'Book a consult'),
      'about_excerpt', 'I work mostly with professionals who look fine from the outside.',
      'tone_keywords', jsonb_build_array('steady', 'plainspoken', 'warm')),
    jsonb_build_object('id', 'quiet_confidence', 'name', 'Quiet Confidence',
      'rationale', 'Restraint reads as experience. For clients who want steadiness more than warmth.',
      'palette', jsonb_build_object('primary', '#3B2C3A', 'secondary', '#4A5361', 'light', '#F3EDE4', 'dark', '#241B23', 'paper', '#FAF7F2'),
      'typography', jsonb_build_object('heading_font', 'Cormorant Garamond', 'body_font', 'Source Sans 3', 'google_fonts_url', 'u'),
      'hero', jsonb_build_object('overline', 'o', 'headline', 'h', 'subhead', 's', 'cta_label', 'c'),
      'about_excerpt', 'x', 'tone_keywords', jsonb_build_array('composed', 'credible', 'unhurried')),
    jsonb_build_object('id', 'modern_calm', 'name', 'Modern Calm',
      'rationale', 'Structure signals a plan. For the client who needs to see how the work goes.',
      'palette', jsonb_build_object('primary', '#22364F', 'secondary', '#7A8168', 'light', '#EDEAE5', 'dark', '#16202E', 'paper', '#F7F6F3'),
      'typography', jsonb_build_object('heading_font', 'Newsreader', 'body_font', 'Work Sans', 'google_fonts_url', 'u'),
      'hero', jsonb_build_object('overline', 'o', 'headline', 'h', 'subhead', 's', 'cta_label', 'c'),
      'about_excerpt', 'x', 'tone_keywords', jsonb_build_array('clear', 'structured', 'direct'))
  ) where id = v_kit;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111"}';

  v_released := public.release_generation_credit(v_kit);
  assert v_released is false, 'release should refuse once directions exist';

  select directions_generated into v_generated
    from public.generation_credits where project_id = 'a3333333-3333-3333-3333-333333333333';
  assert v_generated = 3, format('release should not have touched directions_generated, got %s', v_generated);

  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- Ownership and auth
-- ---------------------------------------------------------------------------
do $$
declare v_released boolean;
begin
  -- A stranger cannot release credit on a kit that is not theirs.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a2222222-2222-2222-2222-222222222222"}';
  v_released := public.release_generation_credit('a5555555-5555-5555-5555-555555555555'::uuid);
  assert v_released is false, 'a stranger should not be able to release another project''s credit';
  reset role;

  -- No caller at all.
  set local role authenticated;
  v_released := public.release_generation_credit('a6666666-6666-6666-6666-666666666666'::uuid);
  assert v_released is false, 'an unauthenticated call should refuse';
  reset role;
end
$$;

rollback;
