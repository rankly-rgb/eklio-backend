-- F71 : un run abandonné ne bloque pas le mois, et une reprise ne reprend que ce qu'elle détient.
begin;

do $$
declare
  v_user    uuid := gen_random_uuid();
  v_project uuid;
  v_kit     uuid;
  v_other   uuid;
  v_t1      uuid;
  v_t2      uuid;
  v_t3      uuid;
  v_held    uuid[];
  v_before  timestamptz;
  v_after   timestamptz;
  v_month   date := '2027-03-01';
  v_runs    int;
  v_seg     uuid;
  v_mod     text;
  v_per     text;
begin
  insert into auth.users (id, email) values (v_user, 'f71@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'F71') returning id into v_project;
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;
  insert into public.projects (user_id, name) values (v_user, 'F71 bis') returning id into v_project;
  insert into public.brand_kits (project_id) values (v_project) returning id into v_other;

  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;
  insert into public.content_segments (modality_id, persona_id, state_code)
       values (v_mod, v_per, 'XX') returning id into v_seg;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed, rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'normalise', 'One', 'A hook',
          '{"statement":"A first statement held by the kit for this test"}'::jsonb, 'seed', 'Because.', now())
  returning id into v_t1;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed, rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'normalise', 'Two', 'A hook',
          '{"statement":"A second statement that lapsed without delivering"}'::jsonb, 'seed', 'Because.', now())
  returning id into v_t2;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed, rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'normalise', 'Three', 'A hook',
          '{"statement":"A third statement that belongs to another kit here"}'::jsonb, 'seed', 'Because.', now())
  returning id into v_t3;

  -- 1. Un run abandonné ne bloque plus un nouveau run pour le même mois.
  insert into public.content_generation_runs (brand_kit_id, month, state, cost_usd)
       values (v_kit, v_month, 'abandoned', 0.4);
  insert into public.content_generation_runs (brand_kit_id, month, state) values (v_kit, v_month, 'submitted');
  select count(*) into v_runs from public.content_generation_runs where brand_kit_id = v_kit and month = v_month;
  assert v_runs = 2, 'un run abandonné empêche encore d''ouvrir le mois';

  -- 2. Mais deux runs OUVERTS sur le même mois restent refusés.
  begin
    insert into public.content_generation_runs (brand_kit_id, month, state) values (v_kit, v_month, 'collected');
    raise exception 'deux runs ouverts ont été acceptés pour le même mois';
  exception when unique_violation then null;
  end;

  -- 3. La réaffirmation rend ce que le kit détient, et seulement ça.
  insert into public.topic_assignments (brand_kit_id, topic_id, month, assigned_at)
       values (v_kit, v_t1, v_month, now() - interval '2 hours'),           -- détenu, dans le délai
              (v_kit, v_t2, v_month, now() - interval '4 hours'),           -- hors délai, rien livré
              (v_other, v_t3, v_month, now());                              -- à une autre
  select assigned_at into v_before from public.topic_assignments where brand_kit_id = v_kit and topic_id = v_t1;
  v_held := public.reassert_topic_assignments(v_kit, array[v_t1, v_t2, v_t3]);
  assert v_held = array[v_t1], format('réaffirmé : %s', v_held);
  select assigned_at into v_after from public.topic_assignments where brand_kit_id = v_kit and topic_id = v_t1;
  assert v_after > v_before, 'l''assignation détenue n''a pas été rafraîchie';
  assert not exists (select 1 from public.topic_assignments where brand_kit_id = v_kit and topic_id = v_t3),
    'un sujet d''une autre a été pris';

  -- 4. Un sujet rendu (ligne supprimée) n'est pas repris.
  delete from public.topic_assignments where brand_kit_id = v_kit and topic_id = v_t1;
  v_held := public.reassert_topic_assignments(v_kit, array[v_t1]);
  assert v_held = '{}'::uuid[], 'un sujet rendu a été repris';

  -- 5. Le droit : service_role seulement.
  assert not has_function_privilege('anon', 'public.reassert_topic_assignments(uuid, uuid[])', 'execute'),
    'anon peut réaffirmer des sujets';
  assert not has_function_privilege('authenticated', 'public.reassert_topic_assignments(uuid, uuid[])', 'execute'),
    'authenticated peut réaffirmer des sujets';
  assert has_function_privilege('service_role', 'public.reassert_topic_assignments(uuid, uuid[])', 'execute'),
    'service_role ne peut pas réaffirmer';
end
$$;

rollback;
