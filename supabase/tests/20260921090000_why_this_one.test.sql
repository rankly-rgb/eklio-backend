-- ============================================================================
-- Tests — l'angle et la justification, vus DEPUIS L'ÉCRAN
-- ============================================================================
-- `20260921090000` prouve, en propriétaire, que `content_item_json` porte
-- `topic.angle_label` et `rationale`. Ce qu'une sonde de migration ne peut pas
-- prouver, c'est ce que `get_content_month` rend — elle passe par
-- `content_kit_access`, scopée `auth.uid()`, et dans un bloc de migration il
-- n'y a pas d'appelant.
--
-- C'est pourtant la seule forme qui compte : les deux écrans lisent ce
-- RPC-là, jamais la table.
-- ============================================================================
begin;

create temporary table p (k text primary key, v uuid) on commit drop;

do $probe$
declare
  v_mod text; v_per text;
  v_u uuid := gen_random_uuid();
  v_pr uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_seg uuid; v_topic uuid; v_item uuid; v_mine uuid;
begin
  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_u, 'why-screen@example.invalid');
  insert into public.projects (id, user_id, name) values (v_pr, v_u, 'W');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
  values (v_pr, array[v_mod], array[v_per], 'CA');
  insert into public.brand_kits (id, project_id) values (v_k, v_pr);
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_u, 'why-this-one test', 'supabase/tests', now() + interval '1 day');

  insert into public.content_segments (modality_id, persona_id) values (v_mod, v_per)
  returning id into v_seg;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'behind_the_practice', 'A topic', 'A hook',
          '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
          'seed', 'Because {{specialty}} keeps coming up.', now())
  returning id into v_topic;
  insert into public.topic_assignments (brand_kit_id, topic_id, month)
  values (v_k, v_topic, date_trunc('month', now())::date);

  -- Un post qui vient d'un sujet…
  insert into public.content_items (brand_kit_id, archetype, status, title, scheduled_for)
  values (v_k, 'statement', 'draft', 'From a topic', date_trunc('month', now())::date)
  returning id into v_item;
  perform public.set_content_item_topic(v_item, v_topic, 'Because burnout keeps coming up.');

  -- …et un post qu'elle a écrit elle-même.
  insert into public.content_items (brand_kit_id, archetype, status, title, scheduled_for)
  values (v_k, 'notes', 'draft', 'Hers alone', (date_trunc('month', now()) + interval '1 day')::date)
  returning id into v_mine;

  insert into p values ('user', v_u), ('kit', v_k), ('seg', v_seg),
                       ('item', v_item), ('mine', v_mine);
end
$probe$;


-- ---------------------------------------------------------------------------
-- 1. Le flux porte l'angle, son libellé, et la justification
-- ---------------------------------------------------------------------------
do $t1$
declare
  v_u uuid := (select v from p where k = 'user');
  v_k uuid := (select v from p where k = 'kit');
  v_month jsonb;
  v_from_topic jsonb;
  v_hers jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  v_month := public.get_content_month(v_k, date_trunc('month', now())::date);
  assert not (v_month ? 'error'),
    format('get_content_month a refusé un kit comp: %s', v_month);

  select value into v_from_topic
    from jsonb_array_elements(v_month -> 'items')
   where value ->> 'title' = 'From a topic';
  select value into v_hers
    from jsonb_array_elements(v_month -> 'items')
   where value ->> 'title' = 'Hers alone';

  assert v_from_topic is not null, 'le post issu d''un sujet n''est pas dans le mois';

  assert v_from_topic #>> '{topic,angle}' = 'behind_the_practice',
    format('angle inattendu: %s', v_from_topic #>> '{topic,angle}');

  -- ⚠ LE LIBELLÉ VIENT DE LA BASE, PAS D'UNE TRADUCTION CÔTÉ CLIENT. C'est
  -- toute la raison d'être de `content_intents` : une sixième intention
  -- générée un jour arriverait sinon à l'écran sans mots.
  assert v_from_topic #>> '{topic,angle_label}' = 'Behind the practice',
    format('libellé inattendu: %s', v_from_topic #>> '{topic,angle_label}');

  assert v_from_topic ->> 'rationale' = 'Because burnout keeps coming up.',
    format('justification inattendue: %s', v_from_topic ->> 'rationale');

  -- ⚠ ET UN POST QU'ELLE A ÉCRIT N'INVENTE PAS D'ANGLE. L'écran n'affiche
  -- alors pas de libellé — il n'écrit pas « Uncategorised ».
  assert v_hers is not null, 'son propre post n''est pas dans le mois';
  assert v_hers -> 'topic' = 'null'::jsonb,
    format('un post sans sujet porte un topic: %s', v_hers -> 'topic');
  assert v_hers ->> 'rationale' is null,
    'un post sans sujet porte une justification';

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t1$;


-- ---------------------------------------------------------------------------
-- 2. Le catalogue d'angles est lisible et figé
-- ---------------------------------------------------------------------------
do $t2$
declare
  v_u uuid := (select v from p where k = 'user');
  v_n integer; v_rows integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  select count(*) into v_n from public.content_intents;
  assert v_n = 5, format('le catalogue d''angles montre %s lignes, attendu 5', v_n);

  update public.content_intents set label = 'Something else';
  get diagnostics v_rows = row_count;
  assert v_rows = 0, format('une cliente a réécrit %s libellé(s) d''angle', v_rows);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t2$;


-- ---------------------------------------------------------------------------
-- 3. Elle ne peut pas s'épingler le sujet d'une autre
-- ---------------------------------------------------------------------------
do $t3$
declare
  v_u uuid := (select v from p where k = 'user');
  v_item uuid := (select v from p where k = 'item');
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  begin
    perform public.set_content_item_topic(v_item, null, 'anything');
    reset role;
    raise exception 'une cliente a pu appeler set_content_item_topic.';
  exception when insufficient_privilege then null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t3$;

rollback;
