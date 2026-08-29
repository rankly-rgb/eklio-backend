-- ============================================================================
-- Tests — 20260827102000_brand_kit_deliverable.sql
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
-- The approved screens' own payloads must be accepted
-- ---------------------------------------------------------------------------
do $$
begin
  update public.brand_kits set
    directions       = (select d from t_reveal),
    social_templates = (select t from t_tiles),
    voice_guide      = jsonb_build_object(
      'sounds_like', jsonb_build_array('Direct without being blunt.','Plain words for clinical ideas.','Calm, never performative.'),
      'never_write', jsonb_build_array('Heal your anxiety in 12 weeks.','Clients often tell me...','Limited spots available.')),
    ethics_check     = '{"passed":true,"flagged":[],"checked_at":"2026-08-27T09:00:00Z"}'::jsonb,
    site_prompt_target = 'squarespace',
    practitioner_line  = 'Nora Whitfield, LCSW'
  where id = 'cccccccc-0000-0000-0000-000000000001';

  assert (select jsonb_array_length(directions) from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000001') = 3,
         'the approved Screen 4 reveal was not stored';
end
$$;

-- ---------------------------------------------------------------------------
-- directions: exactly 3, distinct ids, required keys
-- ---------------------------------------------------------------------------
do $$
declare
  reveal jsonb := (select d from t_reveal);
  rejected boolean;
begin
  assert not public.brand_kit_directions_shape_valid(jsonb_build_array(reveal->0, reveal->1)),
         'two directions were accepted';
  assert not public.brand_kit_directions_shape_valid(reveal || jsonb_build_array(reveal->0)),
         'four directions were accepted';
  assert not public.brand_kit_directions_shape_valid(
           jsonb_build_array(reveal->0, reveal->1, jsonb_set(reveal->2,'{id}','"warm_welcome"'::jsonb))),
         'two directions sharing an id were accepted';
  assert not public.brand_kit_directions_shape_valid(jsonb_set(reveal,'{0,palette,primary}','"not-a-hex"'::jsonb)),
         'a direction with a malformed palette colour was accepted';
  assert not public.brand_kit_directions_shape_valid(reveal #- '{0,rationale}'),
         'a direction missing its rationale was accepted';
  assert not public.brand_kit_directions_shape_valid(reveal #- '{0,typography,google_fonts_url}'),
         'a direction missing its fonts URL was accepted';
  assert public.brand_kit_directions_shape_valid(null),
         'NULL directions must be allowed: a kit row exists before generation fills it';

  -- and the constraint is really on the table, not only in the function
  begin
    update public.brand_kits set directions = jsonb_build_array(reveal->0)
     where id='cccccccc-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'the table accepted a single direction';
end
$$;

-- ---------------------------------------------------------------------------
-- selected_direction_id must name a direction that is present
-- ---------------------------------------------------------------------------
do $$
declare
  rejected boolean;
begin
  begin
    update public.brand_kits set selected_direction_id = 'not_in_the_array'
     where id='cccccccc-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'a selection naming an absent direction was accepted';

  update public.brand_kits set selected_direction_id = 'modern_calm'
   where id='cccccccc-0000-0000-0000-000000000001';
  assert (select selected_direction_id from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000001') = 'modern_calm',
         'a valid selection was refused';
end
$$;

-- ---------------------------------------------------------------------------
-- voice_guide: exactly three lines per column
-- ---------------------------------------------------------------------------
do $$
begin
  assert not public.brand_kit_voice_guide_valid('{"sounds_like":["a","b"],"never_write":["a","b","c"]}'::jsonb),
         'two sounds_like lines were accepted';
  assert not public.brand_kit_voice_guide_valid('{"sounds_like":["a","b","c"],"never_write":["a","b","c","d"]}'::jsonb),
         'four never_write lines were accepted';
  assert not public.brand_kit_voice_guide_valid('{"sounds_like":["a","b",3],"never_write":["a","b","c"]}'::jsonb),
         'a non-string voice guide line was accepted';
  assert public.brand_kit_voice_guide_valid('{"sounds_like":["a","b","c"],"never_write":["a","b","c"]}'::jsonb),
         'a well-formed voice guide was refused';
end
$$;

-- ---------------------------------------------------------------------------
-- social_templates: exactly 4, in Screen 6's order, with legal roles
-- ---------------------------------------------------------------------------
do $$
declare
  tiles jsonb := (select t from t_tiles);
begin
  assert not public.brand_kit_social_templates_shape_valid(tiles - 3),
         'three templates were accepted';
  assert not public.brand_kit_social_templates_shape_valid(
           jsonb_build_array(tiles->1, tiles->0, tiles->2, tiles->3)),
         'templates out of render order were accepted';
  assert not public.brand_kit_social_templates_shape_valid(
           jsonb_set(tiles,'{0,palette_role}','"turquoise"'::jsonb)),
         'a palette role outside the five printed names was accepted';
  assert not public.brand_kit_social_templates_shape_valid(
           jsonb_set(tiles,'{0,typography_role}','"caption"'::jsonb)),
         'a typography role a pairing cannot supply was accepted';
  assert not public.brand_kit_social_templates_shape_valid(
           jsonb_set(tiles,'{0,body}','42'::jsonb)),
         'a numeric body was accepted';
  assert public.brand_kit_social_templates_shape_valid(jsonb_set(tiles,'{0,body}','null'::jsonb)),
         'a null body must be allowed: the statement tile carries a headline only';
end
$$;

-- ---------------------------------------------------------------------------
-- ethics_check: shape only, validated here, produced in eklio-frontend
-- ---------------------------------------------------------------------------
do $$
begin
  assert not public.brand_kit_ethics_check_valid('{"passed":"yes","flagged":[],"checked_at":"x"}'::jsonb),
         'a non-boolean passed was accepted';
  assert not public.brand_kit_ethics_check_valid('{"passed":true,"checked_at":"x"}'::jsonb),
         'a verdict with no flagged array was accepted';
  assert not public.brand_kit_ethics_check_valid(
           '{"passed":false,"flagged":[{"field":"hero","excerpt":"x"}],"checked_at":"t"}'::jsonb),
         'a flag missing its rule_id was accepted';
  assert public.brand_kit_ethics_check_valid(
           '{"passed":false,"flagged":[{"field":"hero.headline","excerpt":"Heal your anxiety in 12 weeks.","rule_id":"timeframe"}],"checked_at":"2026-08-27T09:00:00Z"}'::jsonb),
         'a well-formed failing verdict was refused';
end
$$;

-- ---------------------------------------------------------------------------
-- site_prompt_target
-- ---------------------------------------------------------------------------
do $$
declare
  rejected boolean;
  target text;
begin
  -- ⚠ WIDENED BY `20260829100000_site_spec.sql`, DELIBERATELY. This migration
  -- shipped four targets and this test asserted `wix` was refused. The site
  -- spec adds v0, Wix and a generic target — Wix and Squarespace and Webflow
  -- being exactly the builders that have no prompt input and need a setup
  -- sheet instead — and `brand_kits.site_prompt` became the cache of whichever
  -- output the spec's target produces. Left as it was, this assertion would
  -- have pinned the schema to the gap the site spec exists to close.
  foreach target in array array['squarespace','lovable','framer','webflow',
                                'v0','wix','generic'] loop
    update public.brand_kits set site_prompt_target = target
     where id='cccccccc-0000-0000-0000-000000000001';
  end loop;

  -- The CHECK still has to be a closed list, or it would be decoration.
  begin
    update public.brand_kits set site_prompt_target = 'wordpress'
     where id='cccccccc-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'an unsupported builder target was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- direction_id had to lose NOT NULL for the current flow to write a row at all
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select is_nullable from information_schema.columns
           where table_schema='public' and table_name='brand_kits' and column_name='direction_id') = 'YES',
         'brand_kits.direction_id is still NOT NULL; the current flow cannot insert a kit';
end
$$;

rollback;
