-- F81 : un mois qu'Eklio a mal produit se retire, ses sujets reviennent à la banque,
-- ses crédits réglés lui sont rendus par avoir — et son travail à elle n'est jamais touché.
begin;

do $$
declare
  v_user     uuid := gen_random_uuid();
  v_project  uuid;
  v_kit      uuid;
  v_month    date := '2027-05-01';
  v_mid      uuid;
  v_seg      uuid;
  v_mod      text;
  v_per      text;
  v_topics   uuid[] := '{}';
  v_t        uuid;
  v_res      uuid;
  v_out      jsonb;
  v_consumed int;
  v_n        int;
  i          int;
begin
  insert into auth.users (id, email) values (v_user, 'f81@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'F81') returning id into v_project;
  insert into public.project_briefs (project_id, state, city, license_type_id)
       values (v_project, 'CA', 'Oakland', 'lmft');
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;
  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;
  insert into public.content_segments (modality_id, persona_id, state_code)
       values (v_mod, v_per, 'CA') returning id into v_seg;

  insert into public.content_months (brand_kit_id, month, themes, status)
       values (v_kit, v_month, '{}', 'proposed') returning id into v_mid;
  insert into public.content_generation_runs (brand_kit_id, month, state, cost_usd)
       values (v_kit, v_month, 'published', 0.63);

  -- Trois posts produits par Eklio, chacun réservé puis réglé — comme novembre.
  for i in 1..3 loop
    insert into public.content_topics
      (segment_id, archetype_key, intent, title, hook, payload, caption_seed, rationale_template, ethics_reviewed_at)
    values (v_seg, 'single_statement', 'normalise', 'Topic ' || i, 'A hook ' || i,
            jsonb_build_object('statement', 'A statement that is long enough number ' || i),
            'seed', 'Because.', now())
    returning id into v_t;
    v_topics := v_topics || v_t;
    insert into public.topic_assignments (brand_kit_id, topic_id, month, assigned_at)
         values (v_kit, v_t, v_month, now());
    insert into public.content_items (brand_kit_id, month_id, topic_id, archetype, status, title, licence_state_code)
         values (v_kit, v_mid, v_t, 'notes', 'proposed', 'Post ' || i, 'CA');
    insert into public.credit_ledger (user_id, kind, entry_type, delta, reason, month)
         values (v_user, 'post_generation', 'reservation', -1,
                 'month 2027-05-01: Topic ' || i, v_month)
      returning id into v_res;
    insert into public.credit_ledger (user_id, kind, entry_type, delta, reason, reservation_id, month, actual_cost_usd)
         values (v_user, 'post_generation', 'settlement', 0, 'settled: month 2027-05-01: Topic ' || i, v_res, v_month, 0.02);
  end loop;

  select consumed into v_consumed from public.credit_balances
   where user_id = v_user and kind = 'post_generation' and month = v_month;
  assert v_consumed = 3, format('avant : %s crédits consommés', v_consumed);

  -- 1. Le retrait : posts supprimés, sujets rendus, crédits rendus, mois dû, run abandonné.
  v_out := public.withdraw_content_month(v_mid, 'test: badly produced month');
  assert (v_out->>'withdrawn')::int = 3, format('retirés : %s', v_out);
  assert (v_out->>'topics_released')::int = 3, format('rendus : %s', v_out);
  assert (v_out->>'credits_refunded')::int = 3, format('avoirs : %s', v_out);
  assert (v_out->>'runs_abandoned')::int = 1, format('runs : %s', v_out);

  assert not exists (select 1 from public.content_items where month_id = v_mid), 'des posts restent';
  assert not exists (select 1 from public.topic_assignments where brand_kit_id = v_kit and topic_id = any (v_topics)),
    'des sujets restent assignés';
  assert (select status from public.content_months where id = v_mid) = 'failed', 'le mois n''est pas dû';
  assert not exists (select 1 from public.content_generation_runs
                      where brand_kit_id = v_kit and month = v_month and state <> 'abandoned'),
    'un run reste ouvert : le cron ne pourrait pas en ouvrir un neuf';

  select consumed into v_consumed from public.credit_balances
   where user_id = v_user and kind = 'post_generation' and month = v_month;
  assert v_consumed = 0, format('après : %s crédits encore consommés', v_consumed);
  select refunds into v_n from public.credit_month_audit
   where user_id = v_user and kind = 'post_generation' and month = v_month;
  assert v_n = 3, format('l''audit compte %s avoirs', v_n);

  -- 2. Un nouveau run s'ouvre pour le même mois.
  insert into public.content_generation_runs (brand_kit_id, month, state) values (v_kit, v_month, 'submitted');

  -- 3. Le mois n'est plus `proposed` : un second retrait est refusé.
  begin
    perform public.withdraw_content_month(v_mid, 'again');
    raise exception 'un mois déjà retiré a été retiré une seconde fois';
  exception when sqlstate '55000' then null;
  end;

  -- 4. Un avoir ne se pose qu'une fois par réservation, et rend exactement ce qui a été pris.
  select id into v_res from public.credit_ledger
   where user_id = v_user and entry_type = 'reservation' order by created_at limit 1;
  begin
    insert into public.credit_ledger (user_id, kind, entry_type, delta, reason, reservation_id, month)
         values (v_user, 'post_generation', 'refund', 1, 'twice', v_res, v_month);
    raise exception 'deux avoirs sur une même réservation';
  exception when unique_violation then null;
  end;
  begin
    insert into public.credit_ledger (user_id, kind, entry_type, delta, reason, month)
         values (v_user, 'post_generation', 'refund', 1, 'no reservation', v_month);
    raise exception 'un avoir sans réservation a été accepté';
  exception when check_violation then null;
  end;
end;
$$;

-- 5. Son travail n'est jamais retiré : un post validé arrête tout, et rien ne bouge.
do $$
declare
  v_user    uuid := gen_random_uuid();
  v_project uuid;
  v_kit     uuid;
  v_mid     uuid;
  v_month   date := '2027-06-01';
begin
  insert into auth.users (id, email) values (v_user, 'f81b@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'F81b') returning id into v_project;
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;
  insert into public.content_months (brand_kit_id, month, themes, status)
       values (v_kit, v_month, '{}', 'proposed') returning id into v_mid;
  insert into public.content_items (brand_kit_id, month_id, archetype, status, title)
       values (v_kit, v_mid, 'notes', 'ready', 'Hers');
  begin
    perform public.withdraw_content_month(v_mid, 'test');
    raise exception 'un mois qu''elle a touché a été retiré';
  exception when sqlstate '55000' then null;
  end;
  assert exists (select 1 from public.content_items where month_id = v_mid), 'son post a disparu';
  assert (select status from public.content_months where id = v_mid) = 'proposed', 'son mois a changé d''état';
end;
$$;

-- 6. Le droit : service_role seulement, et jamais la cliente.
do $$
begin
  assert not has_function_privilege('anon', 'public.withdraw_content_month(uuid, text)', 'execute'),
    'anon peut retirer un mois';
  assert not has_function_privilege('authenticated', 'public.withdraw_content_month(uuid, text)', 'execute'),
    'authenticated peut retirer un mois';
  assert has_function_privilege('service_role', 'public.withdraw_content_month(uuid, text)', 'execute'),
    'service_role ne peut pas retirer un mois';
end;
$$;

rollback;
