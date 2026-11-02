-- Un post sait sur quel fond il est posé : la colonne existe, ses valeurs sont tenues.
begin;

do $$
declare
  v_user    uuid := gen_random_uuid();
  v_project uuid;
  v_kit     uuid;
  v_month   uuid;
  v_item    uuid;
begin
  insert into auth.users (id, email) values (v_user, 'ground@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'Ground') returning id into v_project;
  insert into public.project_briefs (project_id, state, city, license_type_id) values (v_project, 'CA', 'Oakland', 'lmft');
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;
  insert into public.content_months (brand_kit_id, month, themes, status)
       values (v_kit, '2027-09-01', '{}', 'proposed') returning id into v_month;

  -- 1. Chacune des cinq familles est acceptée.
  insert into public.content_items (brand_kit_id, month_id, archetype, status, title, card_ground)
       values (v_kit, v_month, 'notes', 'proposed', 'A post', 'deep') returning id into v_item;
  assert (select card_ground from public.content_items where id = v_item) = 'deep';

  -- 2. NULL reste permis : un post écrit avant les familles.
  insert into public.content_items (brand_kit_id, month_id, archetype, status, title)
       values (v_kit, v_month, 'notes', 'proposed', 'Hers');

  -- 3. Une famille inconnue est refusée.
  begin
    insert into public.content_items (brand_kit_id, month_id, archetype, status, title, card_ground)
         values (v_kit, v_month, 'notes', 'proposed', 'Bad', 'neon');
    raise exception 'une famille de fond inconnue a été acceptée';
  exception when check_violation then null;
  end;
end;
$$;

rollback;
