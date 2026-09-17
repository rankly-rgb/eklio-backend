-- ============================================================================
-- L'Ethics Guard est dans l'écriture, et il mord
-- ============================================================================
-- ⚠ C'est le seul garde de ce chantier dont l'absence coûte une licence
-- professionnelle à une cliente, pas un client à Eklio.
--
-- La garde vivait entièrement dans l'application. Elle couvrait la pipeline de
-- génération et PAS ce qui entre par une RPC — `site_spec_patch`,
-- `update_content_item` — c'est-à-dire précisément le texte qu'elle écrit
-- elle-même et qui sera publié sous sa licence.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. LE CORPUS PARTAGÉ — les six exemples que le produit lui montre
-- ---------------------------------------------------------------------------
-- `ethics_rules.example_forbidden` est ce que la praticienne LIT quand elle
-- demande à voir la règle. Un exemple que le scanner ne bloque pas est une
-- règle affichée et non appliquée.
--
-- ⚠ Le scanner TypeScript est tenu au MÊME corpus, dans
-- eklio-frontend/lib/ethics/__tests__/shared-corpus.test.ts. Les deux
-- implémentations ne sont pas fusionnées ; c'est ce corpus qui les tient
-- ensemble en attendant.
do $$
declare r record; v_missed text := '';
begin
  for r in select id, example_forbidden from public.ethics_rules where active loop
    if public.ethics_blocks(r.example_forbidden) is null then
      v_missed := v_missed || r.id || ' (' || r.example_forbidden || '); ';
    end if;
  end loop;

  assert v_missed = '', coalesce(
    'le scan ne bloque pas l''exemple affiché de ces règles : ' || v_missed, '');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Ce qui doit PASSER passe
-- ---------------------------------------------------------------------------
-- Une garde qui refuse tout est verte sur la section 1 et inutilisable. Les
-- phrases ci-dessous viennent de `ETHICS_SYSTEM_RULES`, où elles sont données
-- comme les reformulations CORRECTES.
do $$
declare v_text text; v_blocked text := '';
begin
  foreach v_text in array array[
    'understand what your anxiety is protecting you from',
    'a space to look at the patterns that keep repeating',
    'learn how your nervous system responds to stress',
    'We will find an approach that works best for you.',
    'People navigating anxiety are welcome here.',
    'A first session is fifty minutes, and mostly you talk.'
  ]
  loop
    if public.ethics_blocks(v_text) is not null then
      v_blocked := v_blocked || v_text || ' -> ' || public.ethics_blocks(v_text) || '; ';
    end if;
  end loop;

  assert v_blocked = '', coalesce(
    'des formulations données comme CORRECTES par le socle sont refusées : '
    || v_blocked, '');

  -- Un texte nul n'est pas une violation.
  assert public.ethics_blocks(null) is null, 'un texte nul est traité comme une violation';
  assert public.ethics_blocks('') is null, 'un texte vide est traité comme une violation';
end $$;

-- ---------------------------------------------------------------------------
-- 3. ⚠ L'EXTRAIT NE DÉCIDE PAS — la sévérité décide
-- ---------------------------------------------------------------------------
-- La première version de `ethics_blocks` rendait `v ->> 'excerpt'` tel quel, et
-- `substring(… from …)` est SENSIBLE à la casse là où `~*` ne l'est pas. Sur
-- « Heal your anxiety in 12 weeks », la violation était trouvée et son extrait
-- valait NULL — donc le trigger laissait passer.
do $$
declare v_scan jsonb;
begin
  v_scan := public.ethics_scan('Heal your anxiety in 12 weeks.');
  assert jsonb_array_length(v_scan) > 0, 'la majuscule fait disparaître la violation';
  assert public.ethics_blocks('Heal your anxiety in 12 weeks.') is not null,
    'une violation sans extrait citable se lit comme un texte propre';

  -- Et l'extrait, quand il existe, cite bien les mots fautifs.
  assert public.ethics_blocks('guaranteed relief') ilike '%guarantee%',
    'l''extrait ne cite pas les mots qui ont déclenché la règle';
end $$;

-- ---------------------------------------------------------------------------
-- 4. L'exception que Postgres ne sait pas écrire en ligne
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.ethics_blocks('A method that works, every time.') is not null,
    'le motif "that works" ne bloque plus rien';
  assert public.ethics_blocks('We will find an approach that works best for you.') is null,
    'l''exception de "that works" est perdue : une phrase correcte est refusée';
end $$;

-- ---------------------------------------------------------------------------
-- 5. ⚠ LE CRITÈRE D'ACCEPTATION — une page de site avec une promesse est refusée
-- ---------------------------------------------------------------------------
do $$
declare
  v_user  uuid := gen_random_uuid();
  v_org   uuid;
  v_proj  uuid := gen_random_uuid();
  v_kit   uuid := gen_random_uuid();
  v_broke boolean;
  v_rows  integer;
  v_pages jsonb;
begin
  insert into auth.users (id, email) values (v_user, 'guardtest@example.invalid');
  select m.organization_id into v_org from public.organization_members m
   where m.user_id = v_user and m.role = 'owner';
  insert into public.projects (id, user_id, organization_id, name)
  values (v_proj, v_user, v_org, 'Guard');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);

  -- ⚠ LA SPEC EST ÉCRITE, PAS SEMÉE. `seed_site_spec` rend 0 sur un kit sans
  -- direction : l'UPDATE qui suivrait toucherait zéro ligne, aucun trigger ne
  -- se déclencherait, et le test conclurait au succès sur une écriture qui n'a
  -- pas eu lieu. C'est le défaut de `20260910144421`, et il a eu cette sonde
  -- aussi, à sa première exécution.
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

  -- (a) dans `about_excerpt`
  begin
    update public.site_specs
       set about_excerpt = 'A clinically proven method that resolves trauma for good.'
     where brand_kit_id = v_kit;
    get diagnostics v_rows = row_count;
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  assert not v_broke,
    format('une promesse de résultat est passée dans about_excerpt (%s ligne(s))', v_rows);

  -- (b) ⚠ DANS UN CHAMP DE SECTION — c'est le chemin de `site_spec_patch`, et
  -- c'est le critère d'acceptation littéral du lot.
  select public.site_spec_default_pages(array[]::text[], array[]::text[]) into v_pages;
  v_pages := jsonb_set(
    v_pages, '{0,sections,1,fields,body}',
    to_jsonb('Six weeks and your anxiety is gone.'::text));

  begin
    update public.site_specs set pages = v_pages where brand_kit_id = v_kit;
    get diagnostics v_rows = row_count;
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  assert not v_broke,
    format('une promesse de résultat est passée dans une page de site (%s ligne(s))', v_rows);

  -- (c) et la même page, écrite correctement, passe ET touche une ligne.
  v_pages := jsonb_set(
    public.site_spec_default_pages(array[]::text[], array[]::text[]),
    '{0,sections,1,fields,body}',
    to_jsonb('A space to look at what keeps repeating, at your own pace.'::text));
  update public.site_specs set pages = v_pages where brand_kit_id = v_kit;
  get diagnostics v_rows = row_count;
  assert v_rows = 1, 'la sonde n''a pas de spec à écrire : elle ne prouve rien';

  -- (d) une légende de contenu
  begin
    insert into public.content_items (brand_kit_id, archetype, caption)
    values (v_kit, 'google_post', 'Guaranteed relief in 6 weeks.');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  assert not v_broke, 'une garantie est passée dans une légende';

  -- (e) un profil d'annuaire : la déontologie ET les trente clichés
  begin
    perform public.save_directory_profile(
      v_kit, 'psychology_today', 'A safe space where you can be yourself.',
      'body', '{}'::jsonb, null);
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  assert not v_broke,
    'un cliché d''annuaire est passé dans un profil rédigé — banned_phrases a été écrite POUR ce texte-là';

  perform public.save_directory_profile(
    v_kit, 'psychology_today',
    'For people whose bodies keep score long after the thing itself is over.',
    'The rest of it, written plainly.', '{}'::jsonb, null);
end $$;

-- ---------------------------------------------------------------------------
-- 6. `anon` n'écrit pas — et l'utilisatrice connectée écrit toujours
-- ---------------------------------------------------------------------------
-- ⚠ `revoke … from anon` SEUL NE FAIT RIEN : toute fonction naît avec EXECUTE
-- accordé à PUBLIC, et `anon` est membre de PUBLIC. La révocation réussit, ne
-- change rien, et on croit avoir fermé la porte.
do $$
declare v_open text := '';
declare v_shut text := '';
declare v_fn   text;
begin
  foreach v_fn in array array[
    'public.create_content_item(uuid, text, date)',
    'public.update_content_item(uuid, jsonb)',
    'public.delete_content_item(uuid)',
    'public.site_spec_patch(uuid, jsonb)',
    'public.get_publishing_log(uuid, integer)'
  ]
  loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      v_open := v_open || v_fn || '; ';
    end if;
    -- Révoquer sur PUBLIC retire à TOUT LE MONDE. Sans ce second contrôle, on
    -- fermerait la porte à l'utilisatrice connectée en croyant ne la fermer
    -- qu'à l'anonyme.
    if not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      v_shut := v_shut || v_fn || '; ';
    end if;
  end loop;

  assert v_open = '', coalesce('atteignables par anon : ' || v_open, '');
  assert v_shut = '', coalesce(
    'la révocation sur PUBLIC a emporté le droit de l''utilisatrice connectée : '
    || v_shut, '');
end $$;

rollback;
