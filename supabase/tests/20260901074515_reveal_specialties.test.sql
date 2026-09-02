-- ============================================================================
-- Tests — 20260901074515_reveal_specialties.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('ffffffff-0000-0000-0000-000000000001','owner@example.com');
insert into public.projects (id, user_id, name) values
  ('ffffffff-0000-0000-0000-000000000011','ffffffff-0000-0000-0000-000000000001','Elm & Ember Therapy');

create temporary table t_reveal (d jsonb);
insert into t_reveal values (jsonb_build_array(
  jsonb_build_object('id','warm_welcome','name','Warm Welcome',
    'rationale','Warmth without softness. It says the first call will be easier than they think.',
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=X&display=swap'),
    'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','A calmer place to start.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
    'about_excerpt','...', 'tone_keywords', jsonb_build_array('steady','plainspoken','warm')),
  jsonb_build_object('id','quiet_confidence','name','Quiet Confidence',
    'rationale','Restraint reads as experience. For clients who want steadiness more than warmth.',
    'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
    'typography', jsonb_build_object('heading_font','Cormorant Garamond','body_font','Source Sans 3','google_fonts_url','https://fonts.googleapis.com/css2?family=X&display=swap'),
    'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Experienced care, without the noise.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
    'about_excerpt','...', 'tone_keywords', jsonb_build_array('composed','credible','unhurried')),
  jsonb_build_object('id','modern_calm','name','Modern Calm',
    'rationale','Structure signals a plan. For the client who needs to see how the work goes.',
    'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
    'typography', jsonb_build_object('heading_font','Newsreader','body_font','Work Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=X&display=swap'),
    'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Therapy with a plan you can actually see.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
    'about_excerpt','...', 'tone_keywords', jsonb_build_array('clear','structured','direct'))
));

-- ---------------------------------------------------------------------------
-- Specialties: real labels, her order, capped at three
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  insert into public.project_briefs (project_id, specialty_ids) values
    ('ffffffff-0000-0000-0000-000000000011',
     array['life_transitions','anxiety','burnout','grief']);
  insert into public.brand_kits (id, project_id, directions) values
    ('ffffffff-0000-0000-0000-000000000021','ffffffff-0000-0000-0000-000000000011',
     (select d from t_reveal));

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ffffffff-0000-0000-0000-000000000001"}';
  r := public.brand_kit_reveal_get('ffffffff-0000-0000-0000-000000000021');
  reset role;

  assert r->'error' is null, 'the reveal errored: ' || (r->'error'->>'code');
  assert jsonb_array_length(r->'practice'->'specialties') = 3,
         'a fourth specialty leaked past the three-column cap: got ' ||
         jsonb_array_length(r->'practice'->'specialties');
  assert r->'practice'->'specialties' = '["Life transitions","Anxiety","Burnout"]'::jsonb,
         'specialties were not in the order she picked them: got ' || (r->'practice'->'specialties')::text;
end
$$;

-- ---------------------------------------------------------------------------
-- No specialties picked: an empty array, never null, never an error
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  insert into public.projects (id, user_id, name) values
    ('ffffffff-0000-0000-0000-000000000012','ffffffff-0000-0000-0000-000000000001','No Specialties');
  insert into public.project_briefs (project_id) values
    ('ffffffff-0000-0000-0000-000000000012');
  insert into public.brand_kits (id, project_id, directions) values
    ('ffffffff-0000-0000-0000-000000000022','ffffffff-0000-0000-0000-000000000012',
     (select d from t_reveal));

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ffffffff-0000-0000-0000-000000000001"}';
  r := public.brand_kit_reveal_get('ffffffff-0000-0000-0000-000000000022');
  reset role;

  assert r->'error' is null, 'the reveal errored: ' || (r->'error'->>'code');
  assert r->'practice'->'specialties' = '[]'::jsonb,
         'no specialties picked produced something other than an empty array: got ' ||
         (r->'practice'->'specialties')::text;
end
$$;

rollback;
