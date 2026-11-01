-- Un post sait quel dessin il porte : la colonne existe, sa forme est tenue.
begin;

do $$
declare
  v_user    uuid := gen_random_uuid();
  v_project uuid;
  v_kit     uuid;
  v_month   uuid;
  v_item    uuid;
begin
  insert into auth.users (id, email) values (v_user, 'drawing@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'Drawing') returning id into v_project;
  insert into public.project_briefs (project_id, state, city, license_type_id) values (v_project, 'CA', 'Oakland', 'lmft');
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;
  insert into public.content_months (brand_kit_id, month, themes, status)
       values (v_kit, '2027-08-01', '{}', 'proposed') returning id into v_month;

  -- 1. Un identifiant de la bibliothèque est accepté.
  insert into public.content_items (brand_kit_id, month_id, archetype, status, title, illustration_key)
       values (v_kit, v_month, 'notes', 'proposed', 'A post', 'grief-two-paths') returning id into v_item;
  assert (select illustration_key from public.content_items where id = v_item) = 'grief-two-paths';

  -- 2. NULL reste permis : un post écrit avant la bibliothèque, ou à la main.
  insert into public.content_items (brand_kit_id, month_id, archetype, status, title)
       values (v_kit, v_month, 'notes', 'proposed', 'Hers');

  -- 3. Une forme qui n'est pas un identifiant est refusée.
  begin
    insert into public.content_items (brand_kit_id, month_id, archetype, status, title, illustration_key)
         values (v_kit, v_month, 'notes', 'proposed', 'Bad', '../etc/passwd');
    raise exception 'un identifiant de dessin malformé a été accepté';
  exception when check_violation then null;
  end;
end;
$$;

rollback;
