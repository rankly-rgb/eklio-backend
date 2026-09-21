-- ============================================================================
-- Tests — un post demandé, depuis un vrai rôle
-- ============================================================================
-- Ce que les sondes de migration ne peuvent pas prouver : les trois RPC sont
-- scopées `auth.uid()`, donc un bloc DO sans appelant mesure l'absence
-- d'appelant, pas la fonction.
-- ============================================================================
begin;

create temporary table p (k text primary key, v uuid) on commit drop;

do $seed$
declare
  v_mod text; v_per text; v_spec text;
  v_u uuid := gen_random_uuid(); v_pr uuid := gen_random_uuid(); v_k uuid := gen_random_uuid();
  v_u2 uuid := gen_random_uuid(); v_pr2 uuid := gen_random_uuid(); v_k2 uuid := gen_random_uuid();
  v_seg uuid; v_item uuid; v_other uuid; i integer;
begin
  select id into v_mod  from public.modality_cards where active order by sort_order limit 1;
  select id into v_per  from public.client_persona_cards where active order by sort_order limit 1;
  select id into v_spec from public.specialties where active order by sort_order limit 1;

  insert into auth.users (id,email) values (v_u,'ondemand@example.invalid'),
                                           (v_u2,'stranger@example.invalid');
  insert into public.projects (id,user_id,name) values (v_pr,v_u,'D'), (v_pr2,v_u2,'S');
  insert into public.project_briefs (project_id,modality_ids,client_persona_ids,specialty_ids,state)
  values (v_pr,array[v_mod],array[v_per],array[v_spec],'CA'),
         (v_pr2,array[v_mod],array[v_per],array[v_spec],'CA');
  insert into public.brand_kits (id,project_id) values (v_k,v_pr), (v_k2,v_pr2);

  -- ⚠ SEULE LA PREMIÈRE EST PAYÉE. La seconde éprouve le refus.
  insert into public.comp_grants (user_id,reason,granted_by,expires_at)
  values (v_u,'on-demand test','supabase/tests', now()+interval '1 day');

  insert into public.content_segments (modality_id,persona_id) values (v_mod,v_per)
  returning id into v_seg;
  for i in 1..5 loop
    insert into public.content_topics
      (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
       rationale_template, ethics_reviewed_at)
    values (v_seg,'single_statement','normalise','Topic ' || i,'A hook for ' || i,
            jsonb_build_object('statement','Rest is not a reward you earn number ' || i || ' here'),
            'seed','Because {{specialty}} keeps coming up.', now());
  end loop;

  insert into public.content_items (brand_kit_id,archetype,status,title)
  values (v_k,'statement','draft',null) returning id into v_item;
  insert into public.content_items (brand_kit_id,archetype,status,title)
  values (v_k2,'statement','draft',null) returning id into v_other;

  insert into p values ('u',v_u),('k',v_k),('item',v_item),
                       ('u2',v_u2),('k2',v_k2),('other',v_other);
end
$seed$;


-- ---------------------------------------------------------------------------
-- 1. Les suggestions sont gratuites et n'assignent RIEN
-- ---------------------------------------------------------------------------
do $t1$
declare
  v_u uuid := (select v from p where k='u');
  v_k uuid := (select v from p where k='k');
  v_out jsonb; v_n integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',v_u)::text, true);

  v_out := public.suggest_topics_for_kit(v_k, null, 3, '{}');
  assert jsonb_typeof(v_out) = 'array', format('pas un tableau: %s', v_out);
  assert jsonb_array_length(v_out) = 3, format('%s suggestions au lieu de 3', jsonb_array_length(v_out));
  assert v_out #>> '{0,angle_label}' is not null, 'le libellé d''angle manque';
  assert v_out #>> '{0,rationale}' is not null, 'la justification manque';

  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- ⚠ RIEN N'A ÉTÉ BRÛLÉ. C'est toute la différence avec `assign_topic_to_kit`.
  select count(*) into v_n from public.topic_assignments where brand_kit_id = v_k;
  assert v_n = 0, format('%s sujet(s) assigné(s) par une simple suggestion', v_n);
end
$t1$;


-- ---------------------------------------------------------------------------
-- 2. « Show three others » en rend d'autres
-- ---------------------------------------------------------------------------
do $t2$
declare
  v_u uuid := (select v from p where k='u');
  v_k uuid := (select v from p where k='k');
  v_first jsonb; v_second jsonb; v_exclude uuid[];
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',v_u)::text, true);

  v_first := public.suggest_topics_for_kit(v_k, null, 3, '{}');
  select array_agg((e ->> 'id')::uuid) into v_exclude
    from jsonb_array_elements(v_first) e;

  v_second := public.suggest_topics_for_kit(v_k, null, 3, v_exclude);
  -- La banque de ce test en porte 5 : il en reste 2 après les 3 premiers.
  assert jsonb_array_length(v_second) = 2,
    format('%s autres suggestions, attendu 2', jsonb_array_length(v_second));
  assert not ((v_second #>> '{0,id}')::uuid = any(v_exclude)),
    'une suggestion déjà vue est revenue';

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t2$;


-- ---------------------------------------------------------------------------
-- 3. ⚠ UN KIT SANS DROIT NE REÇOIT PAS LA BANQUE
-- ---------------------------------------------------------------------------
-- Gratuites ne veut pas dire publiques : la banque est le stock du produit.
do $t3$
declare
  v_u2 uuid := (select v from p where k='u2');
  v_k2 uuid := (select v from p where k='k2');
  v_u  uuid := (select v from p where k='u');
  v_k  uuid := (select v from p where k='k');
  v_out jsonb;
begin
  set local role authenticated;

  -- Son propre kit, mais impayé.
  perform set_config('request.jwt.claims', json_build_object('sub',v_u2)::text, true);
  v_out := public.suggest_topics_for_kit(v_k2, null, 3, '{}');
  assert v_out ? 'error',
    format('un kit impayé a reçu des suggestions: %s', v_out);
  assert (v_out #>> '{error,code}') = 'payment_required',
    format('code inattendu: %s', v_out #>> '{error,code}');

  -- ⚠ ET LE KIT D'UNE AUTRE EST `not_found`, JAMAIS `payment_required` :
  -- un 402 confirmerait que ce kit existe.
  v_out := public.suggest_topics_for_kit(v_k, null, 3, '{}');
  assert (v_out #>> '{error,code}') = 'not_found',
    format('le kit d''une autre a répondu: %s', v_out #>> '{error,code}');

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t3$;


-- ---------------------------------------------------------------------------
-- 4. ⚠ UN DOUBLE CLIC NE DÉBITE QU'UN CRÉDIT
-- ---------------------------------------------------------------------------
do $t4$
declare
  v_u uuid := (select v from p where k='u');
  v_item uuid := (select v from p where k='item');
  v_a jsonb; v_b jsonb; v_consumed integer; v_rows integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',v_u)::text, true);

  v_a := public.begin_on_demand_write(v_item, 'idem-key-aaaaaaaa');
  assert (v_a ->> 'ok')::boolean, format('première réservation refusée: %s', v_a);
  assert v_a ->> 'reason' = 'reserved', format('inattendu: %s', v_a ->> 'reason');

  -- Le second clic, même clef.
  v_b := public.begin_on_demand_write(v_item, 'idem-key-aaaaaaaa');
  assert v_b ->> 'reason' = 'already_started', format('le doublon a réservé: %s', v_b);
  assert v_b ->> 'write_id' = v_a ->> 'write_id', 'deux écritures pour une intention';

  reset role;
  perform set_config('request.jwt.claims', null, true);

  select consumed into v_consumed from public.credit_balances
   where user_id = v_u and kind = 'regeneration'
     and month = date_trunc('month', now())::date;
  assert v_consumed = 1, format('%s crédit(s) pour un double clic', v_consumed);

  select count(*) into v_rows from public.on_demand_writes where content_item_id = v_item;
  assert v_rows = 1, format('%s lignes d''écriture pour une intention', v_rows);
end
$t4$;


-- ---------------------------------------------------------------------------
-- 5. L'écriture applique le résultat et règle le crédit, une seule fois
-- ---------------------------------------------------------------------------
do $t5$
declare
  v_u uuid := (select v from p where k='u');
  v_item uuid := (select v from p where k='item');
  v_write uuid;
  v_out jsonb; v_again jsonb; v_consumed integer;
begin
  select id into v_write from public.on_demand_writes where content_item_id = v_item;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',v_u)::text, true);

  v_out := public.apply_on_demand_write(
    v_write, 'A written title', 'A caption from the model.', 'A line on the card',
    'Alt text for the card', 'single_statement',
    '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
    'Because burnout keeps coming up.', null, 0.0004
  );
  assert v_out ->> 'reason' = 'written', format('écriture refusée: %s', v_out);

  -- ⚠ REJOUÉE, ELLE NE RÉÉCRIT PAS ET NE REFACTURE PAS.
  v_again := public.apply_on_demand_write(
    v_write, 'Another title', 'Another caption.', null, null, 'single_statement',
    '{"statement":"Something entirely different that should not land"}'::jsonb,
    null, null, 0.0004
  );
  assert v_again ->> 'reason' = 'already_written',
    format('une écriture rejouée a réécrit: %s', v_again);

  reset role;
  perform set_config('request.jwt.claims', null, true);

  assert (select title from public.content_items where id = v_item) = 'A written title',
    'le titre a été réécrit par la relecture';

  select consumed into v_consumed from public.credit_balances
   where user_id = v_u and kind = 'regeneration'
     and month = date_trunc('month', now())::date;
  assert v_consumed = 1, format('%s crédit(s) après écriture et rejeu', v_consumed);
end
$t5$;


-- ---------------------------------------------------------------------------
-- 6. ⚠ UN PAYLOAD QUI ENFREINT LA DÉONTOLOGIE N'ATTEINT JAMAIS LE POST
-- ---------------------------------------------------------------------------
-- La garde tourne sur le payload À L'ÉCRITURE : un modèle qui rendrait une
-- promesse de résultat bien formée serait refusé ici, après le validateur de
-- forme et avant l'écran.
do $t6$
declare
  v_u uuid := (select v from p where k='u');
  v_k uuid := (select v from p where k='k');
  v_item2 uuid;
begin
  insert into public.content_items (brand_kit_id, archetype, status)
  values (v_k, 'statement', 'draft') returning id into v_item2;

  begin
    update public.content_items
       set compose_archetype = 'single_statement',
           payload = '{"statement":"This therapy is clinically proven to cure your anxiety"}'::jsonb
     where id = v_item2;
    raise exception 'un payload avec une promesse de résultat a été écrit';
  exception when check_violation then null;
  end;

  -- Et un payload honnête passe.
  update public.content_items
     set compose_archetype = 'single_statement',
         payload = '{"statement":"Rest is not a reward you earn after everything else"}'::jsonb
   where id = v_item2;
  assert (select payload is not null from public.content_items where id = v_item2),
    'un payload conforme a été refusé';
end
$t6$;


-- ---------------------------------------------------------------------------
-- 7. Un payload sans mise en page est refusé
-- ---------------------------------------------------------------------------
do $t7$
declare
  v_k uuid := (select v from p where k='k');
  v_item3 uuid;
begin
  insert into public.content_items (brand_kit_id, archetype, status)
  values (v_k, 'statement', 'draft') returning id into v_item3;

  begin
    update public.content_items
       set payload = '{"statement":"A statement with no archetype to validate it"}'::jsonb
     where id = v_item3;
    raise exception 'un payload sans compose_archetype a été accepté';
  exception when check_violation then null;
  end;
end
$t7$;

rollback;
