-- ============================================================================
-- Tests — la garde déontologique MORD
-- ============================================================================
-- `20260914084054_the_guard_moves_into_the_write` installe le scan
-- déontologique en base et les trois triggers qui refusent une écriture. Elle a
-- été appliquée en production sous forme d'EXTRAIT : la prose avait été retirée
-- en chemin, et avec elle une sonde de 693 tokens — celle qui, à l'application,
-- aurait prouvé que la garde mord.
--
-- ⚠ ELLE A DONC ÉTÉ INSTALLÉE SANS AVOIR JAMAIS MORDU. Pendant trois jours,
-- « les promesses de résultat sont refusées à l'écriture » était une phrase
-- dans un fichier, pas un fait observé.
--
-- ── POURQUOI UN TEST ET PAS UNE MIGRATION ───────────────────────────────
--
-- Rendre sa sonde à la migration ne prouverait rien : une sonde de migration
-- s'exécute une fois, à l'application, et celle-là est passée. La rejouer
-- après coup dirait seulement qu'un rejeu local fonctionne — pas que la
-- production refuse.
--
-- Ici, elle est un test : elle s'exécute contre la base telle qu'elle est, à
-- chaque `local-verify`, et elle a été exécutée telle quelle contre la
-- PRODUCTION le 17 septembre, dans une transaction annulée qui n'a rien
-- laissé. Les six règles bloquent leur propre exemple, l'exception de
-- « that works » tient, l'extrait cite les mots fautifs — « Guaranteed » et
-- non « d », « Heal » avec sa majuscule — et les trois triggers refusent.
--
-- Le corps ci-dessous est celui de la sonde, repris de
-- `claude/foundation-lot3-wiring`, là où le fichier complet vivait.
-- ============================================================================
begin;

do $$
declare
  v_rule    record;
  v_user    uuid := gen_random_uuid();
  v_org     uuid;
  v_proj    uuid := gen_random_uuid();
  v_kit     uuid := gen_random_uuid();
  v_broke   boolean;
  v_rows    integer;
begin
  -- ⚠ LE CORPUS PARTAGÉ. Chacune des six règles porte, dans `ethics_rules`,
  -- l'exemple de ce qu'elle interdit. Le scanner SQL doit bloquer les six —
  -- et le scanner TypeScript aussi, ce que `lib/ethics/__tests__/` épingle
  -- sur les mêmes phrases. C'est ce qui tient les deux implémentations
  -- ensemble tant qu'elles n'ont pas fusionné.
  for v_rule in select id, example_forbidden from public.ethics_rules where active loop
    if public.ethics_blocks(v_rule.example_forbidden) is null then
      raise exception
        'le scan SQL ne bloque pas l''exemple de la règle "%": %',
        v_rule.id, v_rule.example_forbidden;
    end if;
  end loop;

  -- L'exception de `therapy_that_works` est parcourue dans les deux sens.
  if public.ethics_blocks('A method that works, every time.') is null then
    raise exception 'le motif "that works" ne bloque plus rien';
  end if;
  if public.ethics_blocks('We will find an approach that works best for you.') is not null then
    raise exception
      'l''exception de "that works" est perdue : une phrase correcte est refusée';
  end if;

  -- Une phrase ordinaire passe. Sans ça, la garde prouverait un refus universel.
  if public.ethics_blocks(
       'A space to look at the patterns that keep repeating, at your own pace.') is not null then
    raise exception 'une phrase correcte est bloquée';
  end if;
  if public.ethics_blocks(null) is not null then
    raise exception 'un texte nul est traité comme une violation';
  end if;

  -- ── LE CRITÈRE D'ACCEPTATION, PARCOURU ────────────────────────────────
  insert into auth.users (id, email) values (v_user, 'guard@example.invalid');
  select m.organization_id into v_org from public.organization_members m
   where m.user_id = v_user and m.role = 'owner';
  insert into public.projects (id, user_id, organization_id, name)
  values (v_proj, v_user, v_org, 'Guard');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);

  /*
   * ⚠ LA SPEC EST ÉCRITE À LA MAIN, PAS SEMÉE. La première version de cette
   * sonde appelait `seed_site_spec(v_kit)` — qui rend 0 sur un kit sans
   * direction choisie. L'UPDATE qui suivait touchait alors ZÉRO ligne, aucun
   * trigger ne se déclenchait, et la sonde concluait « la promesse est
   * passée » sur une écriture qui n'avait jamais eu lieu.
   *
   * C'est mot pour mot le défaut de `20260910144421` que ce chantier cite
   * depuis le premier lot : un garde-fou qui dépend de données de seed asserte
   * le seed, pas la contrainte. Il m'a eu aussi, et c'est la sonde elle-même
   * qui l'a montré — en échouant d'abord.
   */
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, heading_font, body_font,
     google_fonts_url, hero, pages, paper_hex, primary_text_hex,
     secondary_text_hex, accent_text_hex, cta_ink_hex)
  values
    (v_kit, v_user, '#3B2C3A', '#4A5361', '#7A6A55', '#F3EDE4', '#241B23',
     'Cormorant Garamond', 'Source Sans 3',
     'https://fonts.googleapis.com/css2?family=Cormorant+Garamond&display=swap',
     jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
     public.site_spec_default_pages(array[]::text[], array[]::text[]),
     '#FAF7F2', '#3B2C3A', '#4A5361', '#7A6A55', '#FFFFFF');

  begin
    update public.site_specs
       set about_excerpt = 'A clinically proven method that resolves trauma for good.'
     where brand_kit_id = v_kit;
    -- ⚠ ET ON EXIGE QUE L'ÉCRITURE AIT EU LIEU. Sans cette ligne, zéro ligne
    -- touchée se lit comme un succès, ce qui est exactement le piège du
    -- dessus.
    get diagnostics v_rows = row_count;
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception
      'une promesse de résultat a pu être écrite dans une spec de site (% ligne(s) touchée(s))',
      v_rows;
  end if;

  -- Et la même écriture, correcte, passe — et touche bien une ligne.
  update public.site_specs
     set about_excerpt = 'A space to look at what keeps repeating, at your own pace.'
   where brand_kit_id = v_kit;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'la sonde n''a pas de spec à écrire : elle ne prouve rien';
  end if;

  -- Un item de contenu, même chose.
  begin
    insert into public.content_items (brand_kit_id, archetype, caption)
    values (v_kit, 'google_post', 'Guaranteed relief in 6 weeks.');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'une garantie a pu être écrite dans une légende';
  end if;

  -- Un profil d'annuaire : la déontologie ET les clichés.
  begin
    perform public.save_directory_profile(
      v_kit, 'psychology_today', 'A safe space where you can be yourself.', 'body',
      '{}'::jsonb, null);
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un cliché d''annuaire a pu entrer dans un profil rédigé';
  end if;

  perform public.save_directory_profile(
    v_kit, 'psychology_today',
    'For people whose bodies keep score long after the thing itself is over.',
    'The rest of it, written plainly.', '{}'::jsonb, null);

  -- Et `anon` n'écrit plus.
  if has_function_privilege('anon', 'public.site_spec_patch(uuid, jsonb)', 'EXECUTE')
  or has_function_privilege('anon', 'public.update_content_item(uuid, jsonb)', 'EXECUTE')
  or has_function_privilege('anon', 'public.create_content_item(uuid, text, date)', 'EXECUTE')
  or has_function_privilege('anon', 'public.delete_content_item(uuid)', 'EXECUTE')
  or has_function_privilege('anon', 'public.get_publishing_log(uuid, integer)', 'EXECUTE') then
    raise exception 'une RPC d''écriture est encore atteignable par anon';
  end if;

  -- ⚠ ET LES APPELANTES LÉGITIMES ONT GARDÉ LE LEUR. Révoquer sur PUBLIC
  -- retire à tout le monde ; sans ce contrôle, on fermerait la porte à
  -- l'utilisatrice connectée en croyant ne la fermer qu'à l'anonyme, et le
  -- produit tomberait pour tout le monde sauf pour celles qu'on visait.
  if not has_function_privilege('authenticated', 'public.site_spec_patch(uuid, jsonb)', 'EXECUTE')
  or not has_function_privilege('authenticated', 'public.update_content_item(uuid, jsonb)', 'EXECUTE')
  or not has_function_privilege('authenticated', 'public.create_content_item(uuid, text, date)', 'EXECUTE')
  or not has_function_privilege('authenticated', 'public.delete_content_item(uuid)', 'EXECUTE')
  or not has_function_privilege('authenticated', 'public.get_publishing_log(uuid, integer)', 'EXECUTE') then
    raise exception
      'la révocation sur PUBLIC a emporté le droit de l''utilisatrice connectée';
  end if;

  delete from public.projects where id = v_proj;
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;
end $$;

rollback;
