-- La fiche Google. Fichier complet :
-- supabase/migrations/20260914160000_the_google_listing.sql
alter table public.content_items drop constraint if exists content_items_archetype_check;
alter table public.content_items add constraint content_items_archetype_check
  check (archetype = any (array[
    'statement', 'question', 'notes', 'signature', 'story',
    'google_post'
  ]));

alter table public.content_items drop constraint if exists content_items_google_post_has_no_image;
alter table public.content_items add constraint content_items_google_post_has_no_image
  check (
    archetype is distinct from 'google_post'
    or (image_slot is null and on_image_text is null)
  );

comment on constraint content_items_google_post_has_no_image on public.content_items is
  'A Google listing post is short text and a button. The five older archetypes are Instagram posts - a ground, text laid ON it, a caption - and nothing at the schema level ever required that image: the requirement lived in the pipeline, which draws a ground for every post. A convention held by code is a convention a second caller ignores.';

alter table public.directory_profiles
  drop constraint if exists directory_profiles_first_paragraph_check;
alter table public.directory_profiles
  add constraint directory_profiles_first_paragraph_check
  check (
    btrim(first_paragraph) <> ''
    and char_length(first_paragraph) <= case platform
                                          when 'google_business' then 750
                                          else 1200
                                        end
  );

comment on constraint directory_profiles_first_paragraph_check on public.directory_profiles is
  'Non-empty, and within the bound of THE PLATFORM IT IS FOR. Google truncates a business description at a different point than Psychology Today truncates a profile; one bound for both means one of the two texts is cut off on somebody''s public page.';

do $$
declare
  v_user uuid := gen_random_uuid();
  v_org  uuid;
  v_proj uuid := gen_random_uuid();
  v_kit  uuid := gen_random_uuid();
  v_broke boolean;
begin
  insert into auth.users (id, email) values (v_user, 'google@example.invalid');
  select m.organization_id into v_org from public.organization_members m
   where m.user_id = v_user and m.role = 'owner';
  insert into public.projects (id, user_id, organization_id, name)
  values (v_proj, v_user, v_org, 'Google');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);

  insert into public.content_items (brand_kit_id, archetype, caption)
  values (v_kit, 'google_post', 'Now taking new clients on Tuesday mornings.');

  begin
    insert into public.content_items (brand_kit_id, archetype, caption, image_slot)
    values (v_kit, 'google_post', 'x', 'post_bg_1');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then raise exception 'un post de fiche Google a pu porter une image'; end if;

  begin
    insert into public.content_items (brand_kit_id, archetype, caption, on_image_text)
    values (v_kit, 'google_post', 'x', 'Words on a picture');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then raise exception 'un post de fiche Google a pu porter du texte sur image'; end if;

  insert into public.content_items (brand_kit_id, archetype, caption, image_slot)
  values (v_kit, 'statement', 'x', 'post_bg_1');

  perform public.save_directory_profile(
    v_kit, 'psychology_today', repeat('a', 800), 'body', '{}'::jsonb, null);

  begin
    perform public.save_directory_profile(
      v_kit, 'google_business', repeat('a', 800), 'body', '{}'::jsonb, null);
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'une description de 800 caractères est passée pour Google : la borne est celle de Psychology Today';
  end if;

  perform public.save_directory_profile(
    v_kit, 'google_business', repeat('a', 700), 'body', '{}'::jsonb, null);

  if (select count(*) from public.directory_profiles where brand_kit_id = v_kit) <> 2 then
    raise exception 'le profil PT et la description Google ne coexistent pas';
  end if;

  delete from public.projects where id = v_proj;
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;
end $$;
