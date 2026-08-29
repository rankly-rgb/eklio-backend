-- ============================================================================
-- Tests — 20260829107000_site_spec_hot_path.sql
-- ============================================================================
-- The product spec holds `PATCH /brand-kits/:id/site-spec` to 150 ms. Measured
-- before this migration it took 530 ms, and none of it was the SQL: the planner
-- costs these jsonb walks past `jit_above_cost` and Postgres spends three to
-- four hundred milliseconds compiling a query that touches sixty rows.
--
-- ⚠ THE SETTING IS THE TEST, THE CLOCK IS THE ALARM. The assertion that matters
-- is that every hot-path function still carries `set jit = off`, because a
-- later `create or replace` drops `proconfig` silently and the symptom is not
-- an error — it is an autosave that quietly goes back to half a second.
--
-- The timing check that follows is deliberately loose (a 150 ms budget checked
-- against a 400 ms ceiling) so that it fails on a regression of that magnitude
-- and not on a busy CI machine. A test that goes red because the runner was
-- loaded is a test people learn to ignore.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Every hot-path function still carries its settings
-- ---------------------------------------------------------------------------
do $$
declare
  f   text;
  fns text[] := array[
    'public.site_spec_get(uuid)',
    'public.site_spec_patch(uuid, jsonb)',
    'public.site_spec_reset(uuid, text)',
    'public.site_spec_set_target(uuid, text)',
    'public.site_spec_fix_contrast(uuid, text)',
    'public.site_output_mark_copied(uuid)',
    'public.site_output_get(uuid, text, text)',
    'public.site_catalog()',
    'public.refresh_brand_kit_site_prompt()',
    'public.site_spec_output(jsonb, text)',
    'public.site_spec_output_prompt(jsonb)',
    'public.site_spec_output_setup_sheet(jsonb, text)',
    'public.site_spec_copy_blocks(jsonb)',
    'public.site_spec_structure_lines(jsonb)',
    'public.site_spec_envelope(jsonb)',
    'public.site_spec_preview_model(jsonb)',
    'public.site_spec_contrast(jsonb)'
  ];
begin
  foreach f in array fns loop
    assert exists (select 1 from pg_proc p
                    where p.oid = f::regprocedure
                      and coalesce(p.proconfig, '{}') @> array['jit=off']),
           format('%s lost its `set jit = off`; the autosave is back to half a second', f);
    assert exists (select 1 from pg_proc p
                    where p.oid = f::regprocedure
                      and coalesce(p.proconfig, '{}') @> array['search_path=""']),
           format('%s lost its empty search_path', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- And the budget itself, on a real spec
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001','owner@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Elm & Ember');
insert into public.project_briefs
  (project_id, practice_name, license_type_id, city, state, specialty_ids, client_persona_ids)
values
  ('bbbbbbbb-0000-0000-0000-000000000001','Elm & Ember Therapy','lcsw','Portland','OR',
   array['anxiety','burnout'], array['high_functioning']);

insert into public.brand_kits (id, project_id, directions, selected_direction_id) values (
  'cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
  jsonb_build_array(
    jsonb_build_object('id','a','name','Alpha One','rationale', repeat('x', 70),
      'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
      'typography', jsonb_build_object('heading_font','Cormorant Garamond','body_font','Source Sans 3',
        'google_fonts_url','https://fonts.googleapis.com/css2?family=Cormorant+Garamond&display=swap'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Experienced care.',
        'subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
      'about_excerpt','I work mostly with professionals who look fine from outside.',
      'tone_keywords', jsonb_build_array('composed','credible','unhurried')),
    jsonb_build_object('id','b','name','Beta Two','rationale', repeat('y', 70),
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=Fraunces&display=swap'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
    jsonb_build_object('id','c','name','Gamma Three','rationale', repeat('z', 70),
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','Work Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=Newsreader&display=swap'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c'))),
  'a');

do $$
declare
  kit      uuid := 'cccccccc-0000-0000-0000-000000000001';
  t0       timestamptz;
  ms       numeric;
  ceiling  numeric := 400;   -- the budget is 150; this catches the 500 ms regression
  i        int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';

  -- warm the plan cache, the same way the second keystroke of an edit does
  perform public.site_spec_get(kit);

  t0 := clock_timestamp();
  for i in 1 .. 5 loop
    perform public.site_spec_get(kit);
  end loop;
  ms := extract(epoch from (clock_timestamp() - t0)) * 1000 / 5;
  assert ms < ceiling,
         format('site_spec_get averaged %s ms per call; the budget is 150 and the ceiling %s. Check that jit is still off.',
                round(ms), ceiling);

  t0 := clock_timestamp();
  for i in 1 .. 5 loop
    perform public.site_spec_patch(kit,
      jsonb_build_object('hero', jsonb_build_object('headline', 'Edit number ' || i)));
  end loop;
  ms := extract(epoch from (clock_timestamp() - t0)) * 1000 / 5;
  assert ms < ceiling,
         format('site_spec_patch averaged %s ms per call; the budget is 150 and the ceiling %s. Check that jit is still off.',
                round(ms), ceiling);

  reset role;
end
$$;

rollback;
