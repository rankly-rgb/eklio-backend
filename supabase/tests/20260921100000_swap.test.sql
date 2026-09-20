-- ============================================================================
-- Tests — « pas celui-là », DEPUIS UN VRAI RÔLE
-- ============================================================================
-- Le garde-fou de la migration `20260921100000` pose lui-même un claim JWT
-- dans un bloc DO : c'est la seule façon d'exercer une fonction dont la portée
-- EST l'appelant, mais ça ne prouve pas la portée. Ce fichier le fait — role
-- `authenticated`, RLS active, et une SECONDE utilisatrice dont l'item doit
-- rester invisible.
-- ============================================================================
begin;

create temporary table p (k text primary key, v uuid) on commit drop;

do $seed$
declare
  v_mod text; v_per text; v_spec text;
  v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_p1 uuid := gen_random_uuid(); v_p2 uuid := gen_random_uuid();
  v_k1 uuid := gen_random_uuid(); v_k2 uuid := gen_random_uuid();
  v_seg uuid; v_item1 uuid; v_item2 uuid;
begin
  select id into v_mod  from public.modality_cards where active order by sort_order limit 1;
  select id into v_per  from public.client_persona_cards where active order by sort_order limit 1;
  select id into v_spec from public.specialties where active order by sort_order limit 1;

  insert into auth.users (id, email) values (v_u1, 'swap-one@example.invalid'),
                                           (v_u2, 'swap-two@example.invalid');
  insert into public.projects (id, user_id, name) values (v_p1, v_u1, 'One'), (v_p2, v_u2, 'Two');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, specialty_ids, state)
  values (v_p1, array[v_mod], array[v_per], array[v_spec], 'CA'),
         (v_p2, array[v_mod], array[v_per], array[v_spec], 'CA');
  insert into public.brand_kits (id, project_id) values (v_k1, v_p1), (v_k2, v_p2);
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_u1, 'swap test', 'supabase/tests', now() + interval '1 day'),
         (v_u2, 'swap test', 'supabase/tests', now() + interval '1 day');

  -- ⚠ DEUX SUJETS, PAS UN. Avec un seul, « la banque est vide » et « le sujet
  -- a déjà servi » sont le même état, et un test qui ne les distingue pas
  -- passerait sur une fonction qui ne tire jamais rien.
  insert into public.content_segments (modality_id, persona_id) values (v_mod, v_per)
  returning id into v_seg;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values
    (v_seg, 'single_statement', 'invite', 'The first draw', 'A hook for the first',
     '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
     'The caption the bank wrote first.', 'Because {{specialty}} keeps coming up.', now()),
    (v_seg, 'single_statement', 'normalise', 'The second draw', 'A hook for the second',
     '{"statement":"Most people put this off for years and then apologise for waiting"}'::jsonb,
     'The caption the bank wrote second.', 'Because {{modality}} is how you work.', now());

  insert into public.content_items (brand_kit_id, archetype, status, title)
  values (v_k1, 'statement', 'proposed', 'Hers, before the swap')
  returning id into v_item1;
  insert into public.content_items (brand_kit_id, archetype, status, title)
  values (v_k2, 'statement', 'proposed', 'Somebody else''s')
  returning id into v_item2;

  insert into p values ('u1', v_u1), ('u2', v_u2), ('k1', v_k1),
                       ('item1', v_item1), ('item2', v_item2), ('seg', v_seg);
end
$seed$;


-- ---------------------------------------------------------------------------
-- 1. Le swap recopie, et il ne fabrique rien
-- ---------------------------------------------------------------------------
do $t1$
declare
  v_u uuid := (select v from p where k = 'u1');
  v_item uuid := (select v from p where k = 'item1');
  v_json jsonb;
  v_before text;
begin
  select title into v_before from public.content_items where id = v_item;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  v_json := public.swap_content_item(v_item);
  assert not (v_json ? 'error'), format('le swap a refusé: %s', v_json);

  assert v_json ->> 'title' <> v_before,
    'le swap a rendu le même titre: rien n''a été tiré';
  assert v_json ->> 'caption' like 'The caption the bank wrote %',
    format('la caption ne vient pas de la banque: %s', v_json ->> 'caption');
  assert v_json ->> 'on_image_text' like 'A hook for the %',
    format('la ligne d''image ne vient pas de la banque: %s', v_json ->> 'on_image_text');
  assert v_json #>> '{topic,id}' is not null,
    'le post ne pointe sur aucun sujet après un swap';
  assert v_json #>> '{topic,angle_label}' is not null,
    'le libellé d''angle est absent après un swap';
  assert v_json ->> 'rationale' is not null,
    'la justification est absente après un swap';

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$t1$;


-- ---------------------------------------------------------------------------
-- 2. Il est gratuit, et il laisse quand même une trace
-- ---------------------------------------------------------------------------
do $t2$
declare
  v_u uuid := (select v from p where k = 'u1');
  v_consumed integer;
  v_rows integer;
begin
  select consumed into v_consumed
    from public.credit_balances
   where user_id = v_u and kind = 'swap' and month = date_trunc('month', now())::date;
  assert coalesce(v_consumed, -1) = 0,
    format('un swap a consommé %s crédit(s)', v_consumed);

  select count(*) into v_rows from public.credit_ledger
   where user_id = v_u and kind = 'swap';
  assert v_rows >= 1, 'un swap n''a laissé aucune ligne de journal';
end
$t2$;


-- ---------------------------------------------------------------------------
-- 3. L'item d'une autre est un `not_found`, jamais un `payment_required`
-- ---------------------------------------------------------------------------
-- ⚠ LA DISTINCTION EST LE TEST. `payment_required` dirait à une inconnue que
-- cet identifiant existe et n'est pas payé, ce qui est déjà deux faits de trop.
do $t3$
declare
  v_u uuid := (select v from p where k = 'u1');
  v_other uuid := (select v from p where k = 'item2');
  v_json jsonb;
  v_title text;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  v_json := public.swap_content_item(v_other);
  assert (v_json #>> '{error,code}') = 'not_found',
    format('swap sur l''item d''une autre a répondu: %s', v_json);

  reset role;
  perform set_config('request.jwt.claims', null, true);

  select title into v_title from public.content_items where id = v_other;
  assert v_title = 'Somebody else''s',
    format('l''item d''une autre a bougé: %s', v_title);
end
$t3$;


-- ---------------------------------------------------------------------------
-- 4. La banque épuisée se dit une fois et ne boucle pas
-- ---------------------------------------------------------------------------
do $t4$
declare
  v_u uuid := (select v from p where k = 'u1');
  v_item uuid := (select v from p where k = 'item1');
  v_json jsonb;
  v_drawn integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u)::text, true);

  -- Le second sujet du segment. Il reste un tirage, donc celui-ci passe.
  v_json := public.swap_content_item(v_item);
  assert not (v_json ? 'error'), format('le second tirage a échoué: %s', v_json);

  -- Le troisième n'a plus rien.
  v_json := public.swap_content_item(v_item);
  assert (v_json #>> '{error,code}') = 'bank_exhausted',
    format('un tirage sur une banque vidée a répondu: %s', v_json);

  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- ⚠ ET L'ÉCHEC N'A RIEN ASSIGNÉ. Une assignation posée puis abandonnée
  -- brûlerait un sujet que personne n'a jamais vu.
  select count(*) into v_drawn from public.topic_assignments
   where brand_kit_id = (select v from p where k = 'k1');
  assert v_drawn = 2,
    format('%s assignation(s) pour deux tirages réussis', v_drawn);
end
$t4$;

rollback;
