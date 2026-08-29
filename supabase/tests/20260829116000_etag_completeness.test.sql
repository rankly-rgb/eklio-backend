-- ============================================================================
-- Tests — 20260829116000_etag_completeness.sql
-- ============================================================================
-- An ETag is a promise: same value, same body. It has to move on every write
-- that changes the body, and hold still on everything that does not.
--
-- It was broken in the one place that mattered most. `site_output_mark_copied`
-- flips `diff.stale` from true to false and moves neither `spec_version` nor
-- `target` — so a client re-reading with `If-None-Match` got a 304 and kept the
-- stale banner on screen after the copy that was supposed to clear it.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','nora@elmandember.com');
insert into public.projects (id, user_id, name) values
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Elm & Ember');
insert into public.project_briefs (project_id, practice_name, license_type_id, city, state)
values ('22222222-2222-2222-2222-222222222222','Elm & Ember Therapy','lcsw','Portland','OR');

insert into public.brand_kits (id, project_id, directions, selected_direction_id) values (
 '33333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222',
 jsonb_build_array(
  jsonb_build_object('id','warm_welcome','name','Warm Welcome',
    'rationale','Warmth without softness. It says the first call will be easier than they think.',
    'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
    'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=Fraunces&display=swap'),
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
-- ⚠ THE BUG: mark-copied changes the body and must move the validator
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  e0 text; e1 text; e2 text; e3 text; e4 text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  -- copy once so there is a marker, then edit so the spec goes stale
  perform public.site_output_mark_copied(kit);
  perform public.site_spec_patch(kit, '{"about_excerpt":"Edited, so the banner is up."}');

  e0 := public.site_spec_get(kit)->>'etag';
  assert (public.site_spec_get(kit)->'diff'->>'stale')::boolean is true,
         'the fixture must start stale';

  -- an identical re-read must NOT move it
  e1 := public.site_spec_get(kit)->>'etag';
  assert e1 = e0, 'the etag moved across two identical reads';

  -- mark-copied flips stale, and must move the etag with it
  e2 := public.site_output_mark_copied(kit)->>'etag';
  assert (public.site_spec_get(kit)->'diff'->>'stale')::boolean is false,
         'mark-copied did not clear the banner';
  assert e2 <> e0,
         'mark-copied changed diff.stale without moving the etag; a client would 304 and keep the stale banner after the copy that clears it';

  -- and the new value is itself stable
  e3 := public.site_spec_get(kit)->>'etag';
  assert e3 = e2, 'the etag is not stable after mark-copied';

  -- mark-copied is idempotent: a second call must not move it again
  e4 := public.site_output_mark_copied(kit)->>'etag';
  assert e4 = e2, 'a redundant mark-copied moved the etag';
end
$$;

-- ---------------------------------------------------------------------------
-- Everything else that must, and must not, move it
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  e0 text; e text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  e0 := public.site_spec_get(kit)->>'etag';

  -- a no-op patch writes nothing, so it must not move
  e := public.site_spec_patch(kit, '{}')->>'etag';
  assert e = e0, 'an empty patch moved the etag';
  e := public.site_spec_patch(kit, jsonb_build_object(
         'primary', public.site_spec_get(kit)->'spec'->>'primary'))->>'etag';
  assert e = e0, 'a patch that sets a field to its current value moved the etag';

  -- a refused patch writes nothing either
  e := public.site_spec_get(kit)->>'etag';
  perform public.site_spec_patch(kit, '{"primary":"nothex"}');
  assert public.site_spec_get(kit)->>'etag' = e, 'a refused patch moved the etag';

  -- a real edit must move it
  e := public.site_spec_patch(kit, '{"primary":"#A35D43"}')->>'etag';
  assert e <> e0, 'a colour edit did not move the etag';
  e0 := e;

  -- a target switch must move it
  e := public.site_spec_set_target(kit, 'lovable')->>'etag';
  assert e <> e0, 'a target switch did not move the etag';
  e0 := e;

  -- a contrast fix is a write, so it must move it
  e := public.site_spec_fix_contrast(kit, 'secondary_on_paper')->>'etag';
  assert e <> e0, 'a contrast fix did not move the etag';
  e0 := e;

  -- a reset is a write, so it must move it
  e := public.site_spec_reset(kit, 'colors')->>'etag';
  assert e <> e0, 'a reset did not move the etag';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ THE SECOND GAP: the output is rendered from catalogs, and they get tuned
-- ---------------------------------------------------------------------------
-- Moving the output copy into a table was done so it could be tuned weekly.
-- A tuning changes the body, so it has to change the validator.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  e0 text; out0 text;
begin
  -- the previous block left the target on Lovable, whose output is a prompt and
  -- does not read the setup-sheet fragments. Put it back on a sheet builder so
  -- the edit below can actually reach the body.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  perform public.site_spec_set_target(kit, 'squarespace');

  reset role;   -- catalogs are writable by migration / service_role only
  e0   := public.site_spec_get(kit)->>'etag';
  out0 := md5((public.site_spec_get(kit)->'output')::text);

  update public.site_output_templates set body = 'Set your colours'
   where id = 'all.sheet.step2_title';
  assert md5((public.site_spec_get(kit)->'output')::text) <> out0,
         'the fixture edit did not actually change the output';
  assert public.site_spec_get(kit)->>'etag' <> e0,
         'tuning the output copy changed the body without moving the etag';

  update public.site_output_templates set body = 'Set your six colors'
   where id = 'all.sheet.step2_title';

  -- section_types feeds the structure listing and the copy headings
  e0 := public.site_spec_get(kit)->>'etag';
  update public.section_types set description = 'Reworded purpose.' where id = 'hero';
  assert public.site_spec_get(kit)->>'etag' <> e0,
         'a section_types edit changed the output without moving the etag';

  -- builder_targets feeds the setup sheet's panel names
  e0 := public.site_spec_get(kit)->>'etag';
  update public.builder_targets set color_panel = 'Site Styles › Colours'
   where id = 'squarespace';
  assert public.site_spec_get(kit)->>'etag' <> e0,
         'a builder_targets edit changed the output without moving the etag';
end
$$;

-- The fingerprint itself: stable, and sensitive to every column the renderer
-- reads. A column no renderer touches must NOT churn it.
do $$
declare v text;
begin
  reset role;
  v := public.site_output_catalog_version();
  assert public.site_output_catalog_version() = v, 'the fingerprint is not stable';
  assert length(v) = 32, 'the fingerprint is not an md5';

  -- sort_order changes the order things are listed in the catalog picker, not
  -- a byte of rendered output, so it must not invalidate every cached envelope
  update public.site_output_templates set sort_order = sort_order + 100;
  assert public.site_output_catalog_version() = v,
         'a sort_order change churns the etag for every user without changing any output';
end
$$;

rollback;
