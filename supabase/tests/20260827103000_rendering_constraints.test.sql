-- ============================================================================
-- Tests — 20260827103000_rendering_constraints.sql
-- ============================================================================
-- One assertion per limit in §4: the value at the limit is accepted, the value
-- one character past it is refused. A limit that only rejects "obviously huge"
-- values is not a limit, it is a suggestion.
-- ============================================================================
begin;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000001','owner@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');

-- The three directions exactly as Screen 4 renders them.
create temporary table t_reveal (d jsonb);
insert into t_reveal values (jsonb_build_array(
  jsonb_build_object('id','quiet_confidence','name','Quiet Confidence',
    'rationale','Restraint reads as experience. For clients who want steadiness more than warmth.',
    'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
    'typography', jsonb_build_object('heading_font','Cormorant Garamond','body_font','Source Sans 3','google_fonts_url','https://fonts.googleapis.com/css2?family=X&display=swap'),
    'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Experienced care, without the noise.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
    'about_excerpt','...', 'tone_keywords', jsonb_build_array('composed','credible','unhurried')),
  jsonb_build_object('id','warm_welcome','name','Warm Welcome',
    'rationale','Warmth without softness. It says the first call will be easier than they think.',
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=X&display=swap'),
    'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','A calmer place to start.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
    'about_excerpt','...', 'tone_keywords', jsonb_build_array('steady','plainspoken','warm')),
  jsonb_build_object('id','modern_calm','name','Modern Calm',
    'rationale','Structure signals a plan. For the client who needs to see how the work goes.',
    'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
    'typography', jsonb_build_object('heading_font','Newsreader','body_font','Work Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=X&display=swap'),
    'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Therapy with a plan you can actually see.','subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
    'about_excerpt','...', 'tone_keywords', jsonb_build_array('clear','structured','direct'))
));

-- The four social templates exactly as Screen 6 renders them.
create temporary table t_tiles (t jsonb);
insert into t_tiles values (jsonb_build_array(
  jsonb_build_object('id','1','type','post','layout','statement','headline','Rest is not a reward.','body',null,'palette_role','primary','typography_role','heading'),
  jsonb_build_object('id','2','type','post','layout','question','headline','What is your anxiety protecting?','body',null,'palette_role','light','typography_role','heading'),
  jsonb_build_object('id','3','type','post','layout','notes','headline','NOTES ON BURNOUT','body','Three lines of body copy.','palette_role','secondary','typography_role','body'),
  jsonb_build_object('id','4','type','story','layout','signature','headline','Elm & Ember','body',null,'palette_role','light','typography_role','heading')
));


-- ---------------------------------------------------------------------------
-- directions[].name  <=  20 characters, one or two words
-- ---------------------------------------------------------------------------
do $$
declare r jsonb := (select d from t_reveal);
begin
  assert public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,name}', to_jsonb(repeat('x',20)))), 'a 20-character name was refused';
  assert not public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,name}', to_jsonb(repeat('x',21)))), 'a 21-character name was accepted';
  assert public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,name}','"Two Words"'::jsonb)), 'a two-word name was refused';
  assert not public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,name}','"One Two Three"'::jsonb)), 'a three-word name was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- directions[].rationale  between 60 and 95 characters
-- ---------------------------------------------------------------------------
do $$
declare r jsonb := (select d from t_reveal);
begin
  assert public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,rationale}', to_jsonb(repeat('x',60)))), 'a 60-character rationale was refused';
  assert public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,rationale}', to_jsonb(repeat('x',95)))), 'a 95-character rationale was refused';
  assert not public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,rationale}', to_jsonb(repeat('x',96)))),
         'a 96-character rationale was accepted; it wraps to a third line and breaks column alignment';
  assert not public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,rationale}', to_jsonb(repeat('x',59)))), 'a 59-character rationale was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- directions[].hero.headline <= 46, hero.subhead <= 60
-- ---------------------------------------------------------------------------
do $$
declare r jsonb := (select d from t_reveal);
begin
  assert public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,hero,headline}', to_jsonb(repeat('x',46)))), 'a 46-character headline was refused';
  assert not public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,hero,headline}', to_jsonb(repeat('x',47)))), 'a 47-character headline was accepted';
  assert public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,hero,subhead}', to_jsonb(repeat('x',60)))), 'a 60-character subhead was refused';
  assert not public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,hero,subhead}', to_jsonb(repeat('x',61)))), 'a 61-character subhead was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- directions[].tone_keywords: exactly 3 single words, joined <= 32
-- ---------------------------------------------------------------------------
do $$
declare r jsonb := (select d from t_reveal);
begin
  -- 10 + 3 + 10 + 3 + 6 = 32
  assert public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,tone_keywords}','["aaaaaaaaaa","bbbbbbbbbb","cccccc"]'::jsonb)),
         'a keyword line joining to exactly 32 characters was refused';
  assert not public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,tone_keywords}','["aaaaaaaaaa","bbbbbbbbbb","ccccccc"]'::jsonb)),
         'a keyword line joining to 33 characters was accepted; the label is nowrap';
  assert not public.brand_kit_directions_rendering_valid(
           jsonb_set(r,'{0,tone_keywords}','["two words","b","c"]'::jsonb)),
         'a keyword containing a space was accepted';
  -- the count is the shape constraint''s job, and it must still hold
  assert not public.brand_kit_directions_shape_valid(
           jsonb_set(r,'{0,tone_keywords}','["a","b"]'::jsonb)),
         'two tone keywords were accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- The three directions must be genuinely contrasted
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb := (select d from t_reveal);
  rejected boolean;
begin
  assert public.brand_kit_directions_contrasted(r), 'the approved reveal was judged uncontrasted';
  assert not public.brand_kit_directions_contrasted(
           jsonb_set(r,'{2,typography,heading_font}','"Fraunces"'::jsonb)),
         'a reveal repeating a heading font was accepted';

  begin
    update public.brand_kits
       set directions = jsonb_set(r,'{0,typography,heading_font}','"Newsreader"'::jsonb)
     where id='cccccccc-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'the table accepted a reveal with a repeated heading font';
end
$$;

-- ---------------------------------------------------------------------------
-- social_templates: headline <= 34 for statement and question, <= 20 for notes
-- ---------------------------------------------------------------------------
do $$
declare t jsonb := (select t from t_tiles);
begin
  assert public.brand_kit_social_templates_rendering_valid(
           jsonb_set(t,'{0,headline}', to_jsonb(repeat('x',34)))), 'a 34-character statement headline was refused';
  assert not public.brand_kit_social_templates_rendering_valid(
           jsonb_set(t,'{0,headline}', to_jsonb(repeat('x',35)))), 'a 35-character statement headline was accepted';
  assert public.brand_kit_social_templates_rendering_valid(
           jsonb_set(t,'{1,headline}', to_jsonb(repeat('x',34)))), 'a 34-character question headline was refused';
  assert not public.brand_kit_social_templates_rendering_valid(
           jsonb_set(t,'{1,headline}', to_jsonb(repeat('x',35)))), 'a 35-character question headline was accepted';
  assert public.brand_kit_social_templates_rendering_valid(
           jsonb_set(t,'{2,headline}', to_jsonb(repeat('x',20)))), 'a 20-character notes label was refused';
  assert not public.brand_kit_social_templates_rendering_valid(
           jsonb_set(t,'{2,headline}', to_jsonb(repeat('x',21)))),
         'a 21-character notes label was accepted; it is small-caps at 0.14em tracking';
end
$$;

-- ---------------------------------------------------------------------------
-- The copy that ships in design/reference/ must satisfy its own limits
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.brand_kit_directions_shape_valid((select d from t_reveal))
     and public.brand_kit_directions_rendering_valid((select d from t_reveal))
     and public.brand_kit_directions_contrasted((select d from t_reveal)),
         'the approved Screen 4 copy fails its own constraints: the limits are wrong, not the design';
  assert public.brand_kit_social_templates_shape_valid((select t from t_tiles))
     and public.brand_kit_social_templates_rendering_valid((select t from t_tiles)),
         'the approved Screen 6 copy fails its own constraints';
end
$$;

-- ---------------------------------------------------------------------------
-- The calendar title limit from §4 lives on its own column
-- ---------------------------------------------------------------------------
do $$
declare
  rejected boolean;
begin
  insert into public.monthly_presence_content
    (user_id, brand_kit_id, month, day_of_month, type, status, title)
  values ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001',
          '2026-09-01', 1, 'post', 'locked', repeat('x',34));

  begin
    update public.monthly_presence_content set title = repeat('x',35)
     where brand_kit_id='cccccccc-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'a 35-character calendar title was accepted';
end
$$;

rollback;
