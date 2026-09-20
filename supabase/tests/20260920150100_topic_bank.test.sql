-- ============================================================================
-- Tests — la banque de sujets, vue DEPUIS UN CLIENT
-- ============================================================================
-- Les garde-fous des trois migrations du 20 septembre prouvent le TIRAGE : la
-- règle « jamais deux fois », la fenêtre de 90 jours, les onze validateurs de
-- payload. Ils tournent en propriétaire, donc ils ne peuvent rien prouver sur
-- la RLS.
--
-- Ce fichier pose la seule question qui reste, et c'est une question de
-- produit autant que de sécurité : ⚠ UNE PRATICIENNE NE VOIT PAS LA BANQUE.
-- Elle voit les sujets qui lui ont été ATTRIBUÉS, et rien d'autre. La banque
-- entière lisible, c'est le plan de contenu de la consœur d'à côté — et c'est
-- aussi la fin de « celui-ci a été choisi pour vous », qui est ce que le
-- produit vend.
-- ============================================================================
begin;

create temporary table _p (k text primary key, v uuid) on commit drop;

do $$
declare
  v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_p1 uuid := gen_random_uuid(); v_p2 uuid := gen_random_uuid();
  v_k1 uuid := gen_random_uuid(); v_k2 uuid := gen_random_uuid();
  v_seg uuid; v_mine uuid; v_hers uuid;
  v_mod text; v_per text;
begin
  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;

  insert into auth.users (id, email) values
    (v_u1, 'bank-1@example.invalid'), (v_u2, 'bank-2@example.invalid');
  insert into public.projects (id, user_id, name) values (v_p1, v_u1, 'A'), (v_p2, v_u2, 'B');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
  values (v_p1, array[v_mod], array[v_per], 'CA'),
         (v_p2, array[v_mod], array[v_per], 'TX');
  insert into public.brand_kits (id, project_id) values (v_k1, v_p1), (v_k2, v_p2);

  insert into public.content_segments (modality_id, persona_id, state_code)
  values (v_mod, v_per, 'XX') returning id into v_seg;

  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'normalise', 'Hers', 'A hook',
          '{"statement":"A statement that belongs to the other practitioner here"}'::jsonb,
          'seed', 'Because.', now())
  returning id into v_hers;

  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'normalise', 'Mine', 'A hook',
          '{"statement":"A statement that will be assigned to the first kit"}'::jsonb,
          'seed', 'Because.', now())
  returning id into v_mine;

  insert into public.topic_assignments (brand_kit_id, topic_id, month)
  values (v_k1, v_mine, date_trunc('month', now())::date),
         (v_k2, v_hers, date_trunc('month', now())::date);

  insert into _p values ('u1', v_u1), ('u2', v_u2),
                        ('mine', v_mine), ('hers', v_hers), ('seg', v_seg);
end $$;


-- ---------------------------------------------------------------------------
-- 1. Elle voit le sien, et seulement le sien
-- ---------------------------------------------------------------------------
do $$
declare
  v_u1 uuid := (select v from _p where k = 'u1');
  v_hers uuid := (select v from _p where k = 'hers');
  v_n integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u1)::text, true);

  select count(*) into v_n from public.content_topics;
  assert v_n = 1, format('elle voit %s sujets, un seul lui a été attribué', v_n);

  -- ⚠ LA QUESTION REPOSÉE SUR L'IDENTIFIANT DE L'AUTRE. « Elle n'en voit
  -- qu'un » pourrait être vrai parce qu'il n'y en a qu'un ; ceci porte sur la
  -- policy et pas sur le volume de données.
  select count(*) into v_n from public.content_topics where id = v_hers;
  assert v_n = 0, 'elle voit le sujet attribué à une autre praticienne';

  select count(*) into v_n from public.topic_assignments;
  assert v_n = 1, format('elle voit %s attributions, elle en a 1', v_n);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;


-- ---------------------------------------------------------------------------
-- 2. Les segments et les archétypes sont du vocabulaire : lisibles, figés
-- ---------------------------------------------------------------------------
do $$
declare
  v_u1 uuid := (select v from _p where k = 'u1');
  v_n integer; v_rows integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u1)::text, true);

  select count(*) into v_n from public.content_archetypes;
  assert v_n = 11, format('le catalogue d''archétypes montre %s lignes, attendu 11', v_n);

  -- Le segment est lisible même si aucun de ses sujets ne l'est : c'est du
  -- vocabulaire, et le moteur de rendu en a besoin pour se décrire.
  select count(*) into v_n from public.content_segments;
  assert v_n > 0, 'les segments ne sont pas lisibles';

  update public.content_archetypes set items_max = 99;
  get diagnostics v_rows = row_count;
  assert v_rows = 0, format('une cliente a modifié %s archétype(s)', v_rows);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;


-- ---------------------------------------------------------------------------
-- 3. Elle ne peut pas s'attribuer un sujet
-- ---------------------------------------------------------------------------
-- Le chemin évident si la policy d'écriture manquait : s'écrire une ligne dans
-- `topic_assignments` rendrait le sujet visible par la policy du §1.
do $$
declare
  v_u1 uuid := (select v from _p where k = 'u1');
  v_hers uuid := (select v from _p where k = 'hers');
  v_k1 uuid;
  v_rows integer;
begin
  select bk.id into v_k1 from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id where pr.user_id = v_u1;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u1)::text, true);

  begin
    insert into public.topic_assignments (brand_kit_id, topic_id, month)
    values (v_k1, v_hers, date_trunc('month', now())::date);
    reset role;
    raise exception 'une cliente s''est attribué le sujet d''une autre.';
  exception when insufficient_privilege then null;
  end;

  -- Et elle ne peut pas non plus effacer une attribution pour « libérer » un
  -- sujet qu'elle a déjà eu -- ce qui contournerait « jamais deux fois ».
  delete from public.topic_assignments;
  get diagnostics v_rows = row_count;
  assert v_rows = 0, format('une cliente a effacé %s attribution(s)', v_rows);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;


-- ---------------------------------------------------------------------------
-- 4. Le tirage n'est pas joignable depuis le navigateur
-- ---------------------------------------------------------------------------
do $$
declare
  v_u1 uuid := (select v from _p where k = 'u1');
  v_k1 uuid;
begin
  select bk.id into v_k1 from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id where pr.user_id = v_u1;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u1)::text, true);

  begin
    perform public.assign_topic_to_kit(v_k1, date_trunc('month', now())::date);
    reset role;
    raise exception 'une cliente a pu s''attribuer un sujet par le RPC.';
  exception when insufficient_privilege then null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

rollback;
