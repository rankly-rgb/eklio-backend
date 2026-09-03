-- ============================================================================
-- Tests — 20260827104000_launch_checklist_items.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000002','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Elm & Ember');

-- ---------------------------------------------------------------------------
-- The trigger seeds exactly eight items at kit creation
-- ---------------------------------------------------------------------------
-- Updated by 20260903260000_launch_checklist_first_week.sql: the checklist
-- grew from six items to eight (choose_direction plus the seven "Your first
-- week" steps) and four labels were reworded. See that migration's header
-- for why this is an in-place evolution, not a parallel table.
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');

do $$
begin
  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000001') = 8,
         'kit creation must seed exactly eight checklist items';

  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000001'
             and user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 8,
         'the trigger must resolve the owner through the project';

  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000001'
             and done_at is not null) = 0,
         'a fresh checklist must start with nothing done';
end
$$;

-- ---------------------------------------------------------------------------
-- The eight labels, verbatim. Screen 7 renders them as written.
-- ---------------------------------------------------------------------------
do $$
declare
  expected text[][] := array[
    ['0','choose_direction',  'Choose your creative direction'],
    ['1','site_setup',        'Put your brand on your site'],
    ['2','update_directory',  'Update your Psychology Today profile'],
    ['3','google_profile',    'Claim or update your Google Business Profile'],
    ['4','social_setup',      'Set up Instagram and Facebook'],
    ['5','email_signature',   'Install your email signature'],
    ['6','booking_link',      'Put your booking link everywhere'],
    ['7','first_post',        'Publish your first post']
  ];
  i int;
  r record;
begin
  for i in 1 .. array_length(expected, 1) loop
    select * into r from public.launch_checklist_items
     where brand_kit_id='cccccccc-0000-0000-0000-000000000001'
       and key = expected[i][2];
    assert r.key is not null,                        format('checklist item %s is missing', expected[i][2]);
    assert r.label      = expected[i][3],            format('checklist label %s drifted from Screen 7', expected[i][2]);
    assert r.sort_order = expected[i][1]::int,       format('checklist item %s is in the wrong position', expected[i][2]);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Idempotence: re-seeding never duplicates, and never resets progress
-- ---------------------------------------------------------------------------
do $$
declare
  first_done timestamptz;
begin
  update public.launch_checklist_items set done_at = now()
   where brand_kit_id='cccccccc-0000-0000-0000-000000000001' and key='first_post';
  select done_at into first_done from public.launch_checklist_items
   where brand_kit_id='cccccccc-0000-0000-0000-000000000001' and key='first_post';

  assert public.seed_launch_checklist('cccccccc-0000-0000-0000-000000000001') = 0,
         're-seeding must insert nothing';
  assert public.seed_launch_checklist('cccccccc-0000-0000-0000-000000000001') = 0,
         're-seeding twice must still insert nothing';
  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000001') = 8,
         're-seeding produced duplicates';
  assert (select done_at from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000001' and key='first_post') = first_done,
         're-seeding wiped progress the user had already made';
end
$$;

-- A second kit gets its own eight, and the unique key is per kit, not global.
do $$
begin
  insert into public.projects (id, user_id, name) values
    ('bbbbbbbb-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','Second practice');
  insert into public.brand_kits (id, project_id) values
    ('cccccccc-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002');
  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id in ('cccccccc-0000-0000-0000-000000000001',
                                  'cccccccc-0000-0000-0000-000000000002')) = 16,
         'a second kit must get its own eight items';
end
$$;

-- ---------------------------------------------------------------------------
-- choose_direction completes itself, and its timestamp never moves
-- ---------------------------------------------------------------------------
do $$
declare
  reveal jsonb := jsonb_build_array(
    jsonb_build_object('id','a','name','Alpha One',
      'rationale', repeat('x',70),
      'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
    jsonb_build_object('id','b','name','Beta Two',
      'rationale', repeat('y',70),
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
    jsonb_build_object('id','c','name','Gamma Three',
      'rationale', repeat('z',70),
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Lora','body_font','B','google_fonts_url','u'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')));
  t1 timestamptz;
begin
  update public.brand_kits set directions = reveal
   where id='cccccccc-0000-0000-0000-000000000001';

  assert (select done_at from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000001' and key='choose_direction') is null,
         'choose_direction was ticked before a direction was chosen';

  update public.brand_kits set selected_direction_id = 'b'
   where id='cccccccc-0000-0000-0000-000000000001';

  select done_at into t1 from public.launch_checklist_items
   where brand_kit_id='cccccccc-0000-0000-0000-000000000001' and key='choose_direction';
  assert t1 is not null, 'choosing a direction must tick choose_direction';

  -- changing one''s mind is not a new completion
  update public.brand_kits set selected_direction_id = 'c'
   where id='cccccccc-0000-0000-0000-000000000001';
  assert (select done_at from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000001' and key='choose_direction') = t1,
         're-selecting a direction moved a timestamp that was already earned';

  -- and only that one item is affected
  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id='cccccccc-0000-0000-0000-000000000001' and done_at is not null) = 2,
         'selecting a direction ticked items it should not have';
end
$$;

-- ---------------------------------------------------------------------------
-- RLS and column privileges
-- ---------------------------------------------------------------------------
do $$
declare
  blocked boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002"}';

  -- zero rows, not a permission error
  assert (select count(*) from public.launch_checklist_items
           where brand_kit_id in ('cccccccc-0000-0000-0000-000000000001',
                                  'cccccccc-0000-0000-0000-000000000002')) = 0,
         'a stranger could select another user''s checklist items';

  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
  assert (select count(*) from public.launch_checklist_items
           where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 16,
         'the owner must see their own checklist items';

  -- ticking an item is allowed
  update public.launch_checklist_items set done_at = now()
   where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and key = 'email_signature';

  -- rewriting the product copy is not
  begin
    update public.launch_checklist_items set label = 'whatever'
     where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and key = 'email_signature';
    blocked := false;
  exception when insufficient_privilege then blocked := true; end;
  assert blocked, 'an authenticated user was able to rewrite a checklist label';

  -- neither is adding or removing items
  begin
    insert into public.launch_checklist_items (user_id, brand_kit_id, key, label, sort_order)
    values ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001',
            'first_post','Invented', 7);
    blocked := false;
  exception when insufficient_privilege then blocked := true;
            when unique_violation      then blocked := true;
  end;
  assert blocked, 'an authenticated user was able to insert a checklist item';

  begin
    delete from public.launch_checklist_items
     where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and key = 'google_profile';
    blocked := (select count(*) from public.launch_checklist_items
                 where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and key='google_profile') = 2;
  exception when insufficient_privilege then blocked := true; end;
  assert blocked, 'an authenticated user was able to delete a checklist item';
end
$$;

rollback;
