-- ============================================================================
-- Tests — 20260901074458_brand_kit_reveal.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('eeeeeeee-0000-0000-0000-000000000001','owner@example.com'),
  ('eeeeeeee-0000-0000-0000-000000000002','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('eeeeeeee-0000-0000-0000-000000000011','eeeeeeee-0000-0000-0000-000000000001','Elm & Ember Therapy');
insert into public.project_briefs (project_id, practice_name, city, state) values
  ('eeeeeeee-0000-0000-0000-000000000011','Elm & Ember Therapy','Portland','OR');
insert into public.brand_kits (id, project_id) values
  ('eeeeeeee-0000-0000-0000-000000000021','eeeeeeee-0000-0000-0000-000000000011');

-- Three directions: #0 carries a curated accent, #1 and #2 do not.
create temporary table t_reveal (d jsonb);
insert into t_reveal values (jsonb_build_array(
  jsonb_build_object('id','warm_welcome','name','Warm Welcome',
    'rationale','Warmth without softness. It says the first call will be easier than they think.',
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE','accent','#6E3320'),
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

update public.brand_kits set
  directions  = (select d from t_reveal),
  voice_guide = jsonb_build_object(
    'sounds_like', jsonb_build_array('Direct without being blunt.','Plain words for clinical ideas.','Calm, never performative.'),
    'never_write', jsonb_build_array('Heal your anxiety in 12 weeks.','Clients often tell me...','Limited spots available.')),
  social_templates = jsonb_build_array(
    jsonb_build_object('id','1','type','post','layout','statement','headline','Rest is not a reward.','body',null,'palette_role','primary','typography_role','heading'),
    jsonb_build_object('id','2','type','post','layout','question','headline','What is your anxiety protecting?','body',null,'palette_role','light','typography_role','heading'),
    jsonb_build_object('id','3','type','post','layout','notes','headline','NOTES ON BURNOUT','body','Three lines of body copy.','palette_role','secondary','typography_role','body'),
    jsonb_build_object('id','4','type','story','layout','signature','headline','Elm & Ember','body',null,'palette_role','light','typography_role','heading'))
where id = 'eeeeeeee-0000-0000-0000-000000000021';

-- ---------------------------------------------------------------------------
-- unauthenticated / not_found disclosure order
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000021');
  assert r->'error'->>'code' = 'unauthenticated',
         'an unauthenticated caller got: ' || (r->'error'->>'code');
end
$$;

do $$
declare r jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000002"}';
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000021');
  assert r->'error'->>'code' = 'not_found',
         'a stranger reading another owner''s kit got: ' || (r->'error'->>'code');
  reset role;
end
$$;

do $$
declare r jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000002"}';
  r := public.brand_kit_reveal_get('00000000-0000-0000-0000-000000000000');
  assert r->'error'->>'code' = 'not_found',
         'a nonexistent kit id got: ' || (r->'error'->>'code');
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- The reveal is FREE: an unentitled owner still gets the full envelope
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000001"}';
  -- no row in `purchases` exists for this project at all
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000021');
  assert r->'error' is null, 'the reveal was gated on payment: ' || (r->'error'->>'code');
  assert jsonb_array_length(r->'directions') = 3, 'the envelope did not carry all three directions';
  assert r->'practice'->>'name' = 'Elm & Ember Therapy', 'practice_name from project_briefs was not used';
  assert r->'practice'->>'city' = 'Portland', 'city from project_briefs was not carried';
  assert r->'practice'->>'state' = 'OR', 'state from project_briefs was not carried';
  assert (r->'voice_guide'->'never_write') is not null, 'voice_guide.never_write was dropped';
  assert jsonb_array_length(r->'social_templates') = 4, 'social_templates was dropped';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- practice.name falls back to the project name with no project_briefs row
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  insert into public.projects (id, user_id, name) values
    ('eeeeeeee-0000-0000-0000-000000000012','eeeeeeee-0000-0000-0000-000000000001','Fallback Project');
  insert into public.brand_kits (id, project_id, directions) values
    ('eeeeeeee-0000-0000-0000-000000000022','eeeeeeee-0000-0000-0000-000000000012',(select d from t_reveal));

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000001"}';
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000022');
  assert r->'practice'->>'name' = 'Fallback Project',
         'practice.name did not fall back to the project name: ' || (r->'practice'->>'name');
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- A kit with no directions yet (generation not finished) is not_found
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  insert into public.projects (id, user_id, name) values
    ('eeeeeeee-0000-0000-0000-000000000013','eeeeeeee-0000-0000-0000-000000000001','Still Generating');
  insert into public.brand_kits (id, project_id) values
    ('eeeeeeee-0000-0000-0000-000000000023','eeeeeeee-0000-0000-0000-000000000013');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000001"}';
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000023');
  assert r->'error'->>'code' = 'not_found',
         'a kit with no directions yet got: ' || (r->'error'->>'code');
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- Contrast: real numbers, checked against the same primitives, not a snapshot
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  d0 jsonb;
  pairs jsonb;
  expected_ratio numeric;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000001"}';
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000021');
  d0 := r->'directions'->0;
  pairs := d0->'contrast'->'pairs';

  -- direction #0 has a curated accent: seven pairs, not six
  assert jsonb_array_length(pairs) = 7,
         'direction with an accent did not report seven pairs: got ' || jsonb_array_length(pairs);
  assert exists (select 1 from jsonb_array_elements(pairs) p where p->>'pair_id' = 'accent_on_paper'),
         'accent_on_paper missing for a direction that has a curated accent';

  -- one pair, hand-checked against the underlying primitive directly
  select (p->>'ratio')::numeric into expected_ratio
    from jsonb_array_elements(pairs) p where p->>'pair_id' = 'dark_neutral_on_paper';
  assert expected_ratio = public.site_spec_contrast_ratio('#2B2A27', '#FAF6EE'),
         'dark_neutral_on_paper ratio does not match site_spec_contrast_ratio directly';

  assert (d0->'contrast'->>'worst_ratio')::numeric = (select min((p->>'ratio')::numeric) from jsonb_array_elements(pairs) p),
         'worst_ratio is not actually the minimum of the reported pairs';
  assert (d0->'contrast'->>'passes_aa')::boolean =
         (select bool_and((p->>'ratio')::numeric >= 4.5) from jsonb_array_elements(pairs) p),
         'passes_aa disagrees with the pairs it is supposed to summarise';

  -- direction #1 has no curated accent: six pairs, no accent_on_paper
  assert jsonb_array_length(r->'directions'->1->'contrast'->'pairs') = 6,
         'a direction with no accent still reported a 7th pair';
  assert not exists (
    select 1 from jsonb_array_elements(r->'directions'->1->'contrast'->'pairs') p
     where p->>'pair_id' = 'accent_on_paper'),
    'accent_on_paper appeared for a direction with no curated accent';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- ambiance_url: absent row -> null
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000001"}';
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000021');
  assert r->'directions'->0->'ambiance_url' = 'null'::jsonb,
         'ambiance_url was not null with no direction_assets row at all';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- ambiance_url: ready + matching hash -> the URL; PALETTE MISMATCH -> null
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  current_hash text;
  d0_palette jsonb;
begin
  d0_palette := (select d from t_reveal)->0->'palette';
  current_hash := public.brand_kit_direction_palette_hash(d0_palette);

  -- as postgres: seed the ready row
  insert into public.direction_assets (brand_kit_id, direction_index, kind, status, palette_hash, url)
  values ('eeeeeeee-0000-0000-0000-000000000021', 0, 'ambiance', 'ready', current_hash, 'https://cdn.example/warm.png');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000001"}';
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000021');
  assert r->'directions'->0->>'ambiance_url' = 'https://cdn.example/warm.png',
         'a ready row with a matching palette_hash did not surface its URL';
  reset role;

  -- as postgres: simulate a regeneration — the stored asset was made for a
  -- hash that no longer matches direction #0's current palette.
  update public.direction_assets
     set palette_hash = 'stale-hash-from-a-previous-palette'
   where brand_kit_id = 'eeeeeeee-0000-0000-0000-000000000021' and direction_index = 0;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"eeeeeeee-0000-0000-0000-000000000001"}';
  r := public.brand_kit_reveal_get('eeeeeeee-0000-0000-0000-000000000021');
  assert r->'directions'->0->'ambiance_url' = 'null'::jsonb,
         'a stale-palette ready row was still exposed as the ambiance_url';
  reset role;

  -- as postgres (direction_assets_claim is service_role-only; postgres, a
  -- superuser, bypasses the grant check the way service_role's own call
  -- would satisfy it): the write side agrees — a claim for the CURRENT hash
  -- is a fresh, billable job, not blocked by the stale row being "ready".
  assert (public.direction_assets_claim(
            'eeeeeeee-0000-0000-0000-000000000021'::uuid, 0, current_hash, 40, 100
          )->>'claimed')::boolean is true,
         'a claim for the current palette was refused because of a stale ready row';
end
$$;

rollback;
