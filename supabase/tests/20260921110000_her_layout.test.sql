-- ============================================================================
-- Tests — la mise en page qu'elle garde
-- ============================================================================
-- Ce que la migration prouve en propriétaire : la colonne existe, la clef
-- étrangère mord, le jeu de clefs du json est complet.
--
-- Ce que SEUL ce fichier peut prouver : qu'elle peut la changer depuis son
-- propre rôle, qu'une mise en page inconnue lui revient comme un refus
-- lisible plutôt que comme une erreur 500, et qu'un swap la remet à zéro.
-- ============================================================================
begin;

create temporary table p (k text primary key, v uuid) on commit drop;

do $seed$
declare
  v_mod text; v_per text; v_spec text;
  v_u uuid := gen_random_uuid();
  v_pr uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_seg uuid; v_item uuid;
begin
  select id into v_mod  from public.modality_cards where active order by sort_order limit 1;
  select id into v_per  from public.client_persona_cards where active order by sort_order limit 1;
  select id into v_spec from public.specialties where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_u, 'her-layout@example.invalid');
  insert into public.projects (id, user_id, name) values (v_pr, v_u, 'L');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, specialty_ids, state)
  values (v_pr, array[v_mod], array[v_per], array[v_spec], 'CA');
  insert into public.brand_kits (id, project_id) values (v_k, v_pr);
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_u, 'her-layout test', 'supabase/tests', now() + interval '1 day');

  insert into public.content_segments (modality_id, persona_id) values (v_mod, v_per)
  returning id into v_seg;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'educate', 'A topic with a layout', 'A hook',
          '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
          'seed', 'Because {{specialty}} keeps coming up.', now());

  insert into public.content_items (brand_kit_id, archetype, status, title, alt_text)
  values (v_k, 'statement', 'draft', 'A post to lay out', 'Alt text that already exists')
  returning id into v_item;

  insert into p values ('u', v_u), ('k', v_k), ('item', v_item), ('seg', v_seg);
end
$seed$;


-- ---------------------------------------------------------------------------
-- 1. Les deux vocabulaires ne se recouvrent pas
-- ---------------------------------------------------------------------------
-- ⚠ C'EST LE PIÈGE QUI A ÉTÉ TROUVÉ PAR LE COMPILATEUR TYPESCRIPT, PAS PAR LA
-- RELECTURE. `content_items.archetype` est un FORMAT DE POST (statement,
-- question, notes…) ; `content_archetypes.id` est une MISE EN PAGE
-- (single_statement, cycle, quadrant_model…). Le jour où un mot appartient aux
-- deux, tout écran qui lit l'une ou l'autre a raison par accident.
do $t1$
declare
  v_overlap text;
  v_formats text[] := array['statement','question','notes','signature','story','google_post'];
begin
  select string_agg(ca.id, ', ') into v_overlap
    from public.content_archetypes ca
   where ca.id = any(v_formats);
  assert v_overlap is null,
    format('une mise en page porte le nom d''un format de post: %s', v_overlap);

  -- Et le contraire : aucune mise en page ne doit être acceptée comme format.
  begin
    update public.content_items set archetype = 'single_statement'
     where id = (select v from p where k = 'item');
    raise exception 'content_items.archetype a accepté une mise en page';
  exception when check_violation then null;
  end;
end
$t1$;


-- ---------------------------------------------------------------------------
-- 2. Elle change la mise en page, et l'écran la relit
-- ---------------------------------------------------------------------------
do $t2$
declare
  v_u uuid := (select v from p where k = 'u');
  v_item uuid := (select v from p where k = 'item');
  v_json jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  -- Au départ : rien, et rien veut dire « celle du sujet ».
  v_json := public.get_content_item(v_item);
  assert v_json ? 'compose_archetype',
    'get_content_item ne porte pas compose_archetype';
  assert v_json ->> 'compose_archetype' is null,
    format('une mise en page est posée d''office: %s', v_json ->> 'compose_archetype');

  v_json := public.update_content_item(v_item, '{"compose_archetype":"cycle"}'::jsonb);
  assert not (v_json ? 'error'), format('le changement a été refusé: %s', v_json);

  v_json := public.get_content_item(v_item);
  assert v_json ->> 'compose_archetype' = 'cycle',
    format('la mise en page n''a pas été relue: %s', v_json ->> 'compose_archetype');

  -- ⚠ LA CHAÎNE VIDE EFFACE, et effacer est un choix réel : c'est comme ça
  -- qu'elle revient à la mise en page d'origine du sujet.
  v_json := public.update_content_item(v_item, '{"compose_archetype":""}'::jsonb);
  assert not (v_json ? 'error'), format('l''effacement a été refusé: %s', v_json);
  v_json := public.get_content_item(v_item);
  assert v_json ->> 'compose_archetype' is null,
    format('la chaîne vide n''a pas effacé: %s', v_json ->> 'compose_archetype');

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t2$;


-- ---------------------------------------------------------------------------
-- 3. Une mise en page inconnue est un refus lisible, pas une 500
-- ---------------------------------------------------------------------------
do $t3$
declare
  v_u uuid := (select v from p where k = 'u');
  v_item uuid := (select v from p where k = 'item');
  v_json jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  v_json := public.update_content_item(v_item, '{"compose_archetype":"spiral_of_doom"}'::jsonb);
  assert (v_json #>> '{error,code}') = 'unknown_layout',
    format('une mise en page inventée a donné: %s', v_json);

  -- ⚠ ET LE REFUS N'A RIEN ÉCRIT. Un refus qui laisse la colonne à moitié
  -- posée serait pire que l'exception qu'il remplace.
  v_json := public.get_content_item(v_item);
  assert v_json ->> 'compose_archetype' is null,
    format('le refus a quand même écrit: %s', v_json ->> 'compose_archetype');

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t3$;


-- ---------------------------------------------------------------------------
-- 4. La clef étrangère reste la garantie
-- ---------------------------------------------------------------------------
-- Le refus lisible ci-dessus est un confort d'écran. Ce qui empêche VRAIMENT
-- une valeur inconnue d'entrer est la contrainte, et elle s'éprouve en
-- écrivant directement dans la table.
do $t4$
begin
  begin
    update public.content_items set compose_archetype = 'spiral_of_doom'
     where id = (select v from p where k = 'item');
    raise exception 'la table a accepté une mise en page qui n''existe pas';
  exception when foreign_key_violation then null;
  end;
end
$t4$;


-- ---------------------------------------------------------------------------
-- 5. Un swap remet la mise en page à zéro
-- ---------------------------------------------------------------------------
-- ⚠ PARCE QUE LE CONTENU CHANGE ENTIÈREMENT. Un cycle choisi pour un sujet à
-- trois étapes, appliqué au sujet suivant qui n'en a pas, produirait un refus
-- de composition qu'elle n'a pas causé.
do $t5$
declare
  v_u uuid := (select v from p where k = 'u');
  v_item uuid := (select v from p where k = 'item');
  v_json jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  v_json := public.update_content_item(v_item, '{"compose_archetype":"cycle"}'::jsonb);
  assert not (v_json ? 'error'), format('mise en place refusée: %s', v_json);

  v_json := public.swap_content_item(v_item);
  assert not (v_json ? 'error'), format('le swap a échoué: %s', v_json);
  assert v_json ->> 'compose_archetype' is null,
    format('le swap a gardé la mise en page de l''ancien contenu: %s',
           v_json ->> 'compose_archetype');

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t5$;

rollback;
