-- ============================================================================
-- La fiche Google — deux lecteurs, deux textes
-- ============================================================================
-- Aujourd'hui la démarche Google reçoit EXACTEMENT le même bloc que Psychology
-- Today : dans `lib/launch/material.ts`, `case "update_directory": case
-- "google_profile":` tombent sur le même `push("Statement", …)`.
--
-- Ce sont deux lecteurs différents. Un profil Psychology Today est lu par
-- quelqu'un qui cherche déjà une thérapeute et compare des profils. Une fiche
-- Google est lue par quelqu'un qui cherche « therapist near me » et ne sait pas
-- encore s'il veut appeler. Le même paragraphe ne fait pas les deux.
--
-- ── CE QUE CETTE MIGRATION AJOUTE ───────────────────────────────────────────
--
--   1. `google_post` comme archétype de contenu — SANS IMAGE IMPOSÉE
--   2. la borne de la description Google, qui n'est pas celle de PT
--
-- `directory_profiles.platform` acceptait déjà `google_business` : la table a
-- été écrite pour ça au lot précédent, et la description Google s'y range sans
-- rien ajouter.
-- ============================================================================

-- ── 1. Un post de fiche Google ──────────────────────────────────────────────
--
-- ⚠ SANS IMAGE IMPOSÉE, ET C'EST UNE CONTRAINTE, PAS UNE CONVENTION. Les cinq
-- archétypes existants sont des posts Instagram : un fond, un texte posé
-- DESSUS (`on_image_text`), une légende. Un post de fiche Google est du texte
-- court et un bouton — l'image y est facultative, et la « photo » qu'un
-- générateur y collerait serait une dépense pour rien.
--
-- Rien n'obligeait une image au niveau du schéma (`image_slot` est déjà
-- nullable) : l'obligation vivait dans la PIPELINE, qui tire un fond pour
-- chaque post. Une convention tenue par du code est une convention qu'un
-- deuxième appelant ignore. Celle-ci est désormais tenue par la base.

alter table public.content_items drop constraint if exists content_items_archetype_check;
alter table public.content_items add constraint content_items_archetype_check
  check (archetype = any (array[
    -- Les cinq de l'offre précédente : des posts Instagram.
    'statement', 'question', 'notes', 'signature', 'story',
    -- L'offre du 13 septembre.
    'google_post'
  ]));

alter table public.content_items drop constraint if exists content_items_google_post_has_no_image;
alter table public.content_items add constraint content_items_google_post_has_no_image
  check (
    -- ⚠ `<>` SEUL RENDRAIT NULL SUR UN `archetype` NUL et le CHECK
    -- l'accepterait. `archetype` est NOT NULL aujourd'hui, ce qui rend la
    -- précaution inutile aujourd'hui — et c'est exactement la forme de défaut
    -- que ce dépôt a payée cinq fois : une contrainte juste tant que la
    -- colonne d'à côté ne bouge pas.
    archetype is distinct from 'google_post'
    or (image_slot is null and on_image_text is null)
  );

comment on constraint content_items_google_post_has_no_image on public.content_items is
  'A Google listing post is short text and a button. The five older archetypes are Instagram posts - a ground, text laid ON it, a caption - and nothing at the schema level ever required that image: the requirement lived in the pipeline, which draws a ground for every post. A convention held by code is a convention a second caller ignores.';

-- ── 2. La description de fiche Google ───────────────────────────────────────
--
-- ⚠ 750 CARACTÈRES, ET CE N'EST PAS LA BORNE DE PSYCHOLOGY TODAY. Google
-- tronque la description d'un établissement ; Psychology Today tronque
-- ailleurs. Une seule borne pour les deux voudrait dire qu'un des deux textes
-- est coupé sur la page publique de quelqu'un.
--
-- La borne vit sur `directory_profiles`, par plateforme, plutôt que dans une
-- constante applicative : c'est la table qui refuse, donc c'est elle qui doit
-- savoir.

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

-- ── Auto-contrôle ──────────────────────────────────────────────────────────

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

  -- Un post Google sans image passe.
  insert into public.content_items (brand_kit_id, archetype, caption)
  values (v_kit, 'google_post', 'Now taking new clients on Tuesday mornings.');

  -- Un post Google AVEC une image est refusé : l'archétype n'en veut pas.
  begin
    insert into public.content_items (brand_kit_id, archetype, caption, image_slot)
    values (v_kit, 'google_post', 'x', 'post_bg_1');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un post de fiche Google a pu porter une image';
  end if;

  begin
    insert into public.content_items (brand_kit_id, archetype, caption, on_image_text)
    values (v_kit, 'google_post', 'x', 'Words on a picture');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un post de fiche Google a pu porter du texte sur image';
  end if;

  -- Les cinq archétypes précédents gardent le droit d'en porter une.
  insert into public.content_items (brand_kit_id, archetype, caption, image_slot)
  values (v_kit, 'statement', 'x', 'post_bg_1');

  -- ── Les deux bornes de description, et elles diffèrent ─────────────────
  -- 800 caractères : trop pour Google, assez pour Psychology Today.
  perform public.save_directory_profile(
    v_kit, 'psychology_today', repeat('a', 800), 'body', '{}'::jsonb, null);

  begin
    perform public.save_directory_profile(
      v_kit, 'google_business', repeat('a', 800), 'body', '{}'::jsonb, null);
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception
      'une description de 800 caractères est passée pour Google : la borne est celle de Psychology Today';
  end if;

  -- Et une description qui tient dans Google passe.
  perform public.save_directory_profile(
    v_kit, 'google_business', repeat('a', 700), 'body', '{}'::jsonb, null);

  -- ⚠ ET LES DEUX COEXISTENT. `directory_profiles_one_per_platform` est unique
  -- sur (kit, plateforme), pas sur le kit : un profil PT et une description
  -- Google sont deux lignes, produites séparément, pour deux lecteurs.
  if (select count(*) from public.directory_profiles where brand_kit_id = v_kit) <> 2 then
    raise exception 'le profil PT et la description Google ne coexistent pas';
  end if;

  delete from public.projects where id = v_proj;
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;
end $$;
