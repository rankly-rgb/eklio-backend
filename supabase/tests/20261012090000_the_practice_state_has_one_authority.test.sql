-- F76 : l'État et la ville du cabinet ont une seule autorité, project_briefs.
begin;


-- ── 1. Les trois sens de la projection ──────────────────────────────────
do $$
declare
  v_user uuid := 'aaaaaaaa-f760-0000-0000-000000000001';
  v_project uuid;
  v_kit uuid;
  v_d jsonb;
begin
  insert into auth.users (id, email) values (v_user, 'f76-authority@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'f76') returning id into v_project;
  insert into public.project_briefs (project_id, state, city, license_type_id)
       values (v_project, 'OR', 'Portland', 'lmft');
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;

  -- a) une spec créée prend la valeur du brief, quoi qu'on lui donne
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex, light_neutral_hex,
     dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url, hero, pages, practice_details)
  values (v_kit, v_user, '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
          '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb,
          public.site_spec_default_pages(null, null), '{"state": null, "city": null}'::jsonb);
  select practice_details into v_d from public.site_specs where brand_kit_id = v_kit;
  assert v_d->>'state' = 'OR' and v_d->>'city' = 'Portland',
    format('une spec neuve ne porte pas l''État et la ville du brief : %s', v_d);

  -- b) le formulaire des réglages écrit DANS LE BRIEF — le défaut de F76
  update public.site_specs set practice_details = practice_details || '{"state":"CA","city":"Oakland"}'
   where brand_kit_id = v_kit;
  assert (select state from public.project_briefs where project_id = v_project) = 'CA',
    'un État saisi par la spec n''a pas atteint le brief';
  assert (select city from public.project_briefs where project_id = v_project) = 'Oakland',
    'une ville saisie par la spec n''a pas atteint le brief';

  -- c) une écriture directe du brief atteint la spec
  update public.project_briefs set state = 'NV', city = 'Reno' where project_id = v_project;
  select practice_details into v_d from public.site_specs where brand_kit_id = v_kit;
  assert v_d->>'state' = 'NV' and v_d->>'city' = 'Reno',
    format('le brief a changé et la spec porte encore l''ancien lieu : %s', v_d);

  -- d) une édition d'AUTRE chose ne réécrit pas le lieu
  update public.site_specs set practice_details = practice_details || '{"email":"a@b.c"}'
   where brand_kit_id = v_kit;
  assert (select state from public.project_briefs where project_id = v_project) = 'NV',
    'une édition de l''e-mail a touché l''État';

  -- e) la ville seule : l'État ne bouge pas
  update public.site_specs set practice_details = practice_details || '{"city":"Las Vegas"}'
   where brand_kit_id = v_kit;
  assert (select state || '/' || city from public.project_briefs where project_id = v_project) = 'NV/Las Vegas',
    'une édition de la ville a mal atteint le brief';

  -- f) effacer par l'éditeur efface l'autorité — le préalable le dira
  update public.site_specs set practice_details = practice_details || '{"city":""}'
   where brand_kit_id = v_kit;
  assert (select city from public.project_briefs where project_id = v_project) is null,
    'une ville vidée dans l''éditeur est restée au brief';
  assert (select practice_details->'city' from public.site_specs where brand_kit_id = v_kit) = 'null'::jsonb,
    'une spec garde une ville que le brief n''a plus';

  -- g) un État qui ne délivre pas le titre est refusé par le brief, même par la spec
  update public.project_briefs set license_type_id = 'lmhc', state = 'NY' where project_id = v_project;
  begin
    update public.site_specs set practice_details = practice_details || '{"state":"OR"}'
     where brand_kit_id = v_kit;
    assert false, 'un État qui ne délivre pas LMHC est passé par la spec';
  exception when check_violation then null; end;
  assert (select state from public.project_briefs where project_id = v_project) = 'NY',
    'le refus a laissé une trace dans le brief';

  -- h) la casse et les espaces ne font pas une édition qui réécrit
  update public.project_briefs set license_type_id = 'lmft', state = 'ca' where project_id = v_project;
  update public.site_specs set practice_details = practice_details where brand_kit_id = v_kit;
  assert (select state from public.project_briefs where project_id = v_project) = 'ca',
    'un alignement a réécrit le brief';
end $$;

-- ── 2. site_spec_patch : le scénario du compte de contrôle, et l'erreur en mots ─
do $$
declare
  v_user uuid := 'aaaaaaaa-f760-0000-0000-000000000002';
  v_project uuid;
  v_kit uuid;
  v_r jsonb;
begin
  insert into auth.users (id, email) values (v_user, 'f76-patch@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'f76 patch') returning id into v_project;
  insert into public.project_briefs (project_id, state, city, license_type_id)
       values (v_project, 'OR', 'Portland', 'lmft');
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex, light_neutral_hex,
     dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url, hero, pages, practice_details)
  values (v_kit, v_user, '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
          '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb,
          public.site_spec_default_pages(null, null), '{}'::jsonb);
  insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
       values (v_user, v_project, 'starter', 'cs_f76_patch', 7900, 'paid', now());
  perform set_config('request.jwt.claims', json_build_object('sub', v_user)::text, true);
  set local role authenticated;

  -- ce que Réglages → Practice details envoie, en une fois
  v_r := public.site_spec_patch(v_kit,
    '{"practice_details":{"license_number":"123456","state":"CA","city":"Oakland"}}');
  assert v_r->'error' is null, format('le formulaire est refusé : %s', v_r);
  reset role;
  assert (select license_number || '|' || state || '|' || city
            from public.project_briefs where project_id = v_project) = '123456|CA|Oakland',
    format('le brief ne porte pas ce que le formulaire a enregistré : %s',
           (select row(license_number, state, city) from public.project_briefs where project_id = v_project));

  -- un État qui ne délivre pas le titre : une erreur de CHAMP, en mots
  update public.project_briefs set license_type_id = 'lmhc', state = 'NY' where project_id = v_project;
  set local role authenticated;
  v_r := public.site_spec_patch(v_kit, '{"practice_details":{"state":"OR"}}');
  assert v_r->'error'->>'code' = 'invalid_field', format('attendu invalid_field, reçu %s', v_r);
  assert v_r->'error'->>'field' = 'practice_details.state', format('l''erreur ne nomme pas le champ : %s', v_r);
  assert v_r->'error'->>'message' like 'OR does not issue%', format('l''erreur ne dit pas quoi corriger : %s', v_r);
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

-- ── 3. La reprise : elle complète, elle s'arrête, elle applique une décision ─
do $$
declare
  v_user uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid;
  v_k1 uuid; v_k2 uuid; v_k3 uuid; v_k4 uuid;
  v_r jsonb;
  v_msg text;
begin
  insert into auth.users (id, email) values (gen_random_uuid(), 'f76-reprise@eklio-test.invalid') returning id into v_user;
  insert into public.projects (user_id, name) values (v_user, 'r1') returning id into v_p1;
  insert into public.projects (user_id, name) values (v_user, 'r2') returning id into v_p2;
  insert into public.projects (user_id, name) values (v_user, 'r3') returning id into v_p3;
  insert into public.projects (user_id, name) values (v_user, 'r4') returning id into v_p4;
  insert into public.project_briefs (project_id) values (v_p1);                                  -- brief vide
  insert into public.project_briefs (project_id, state, city) values (v_p2, 'OR', 'Portland');   -- désaccord
  insert into public.project_briefs (project_id, state, city) values (v_p3, 'ca', 'oakland');    -- casse seule
  insert into public.project_briefs (project_id, state, city) values (v_p4, 'WA', 'Seattle');    -- désaccord
  insert into public.brand_kits (project_id) values (v_p1) returning id into v_k1;
  insert into public.brand_kits (project_id) values (v_p2) returning id into v_k2;
  insert into public.brand_kits (project_id) values (v_p3) returning id into v_k3;
  insert into public.brand_kits (project_id) values (v_p4) returning id into v_k4;

  -- l'état d'AVANT la migration : des lieux saisis dans les specs seulement
  alter table public.site_specs disable trigger site_specs_place_from_brief;
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex, light_neutral_hex,
     dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url, hero, pages, practice_details)
  select k, v_user, '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
         '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb,
         public.site_spec_default_pages(null, null), jsonb_build_object('state', st, 'city', ci)
    from (values (v_k1, 'CA', 'Oakland'), (v_k2, 'CA', 'Oakland'),
                 (v_k3, 'CA', 'Oakland'), (v_k4, 'OR', 'Bend')) v(k, st, ci);
  alter table public.site_specs enable trigger site_specs_place_from_brief;

  -- a) un désaccord non tranché ARRÊTE, et se nomme — les deux
  begin
    perform public.practice_place_reprise('{}'::jsonb);
    assert false, 'la reprise a tranché seule un désaccord';
  exception when raise_exception then v_msg := sqlerrm; end;
  assert v_msg like '%' || v_k2 || '%' and v_msg like '%' || v_k4 || '%',
    format('la reprise ne nomme pas les deux désaccords : %s', v_msg);
  assert v_msg not like '%' || v_k3 || '%', 'une différence de casse est comptée comme un désaccord';
  assert (select state from public.project_briefs where project_id = v_p1) is null,
    'une reprise arrêtée a écrit quand même';

  -- b) une décision pour un kit qui n'est pas en désaccord ARRÊTE aussi
  begin
    perform public.practice_place_reprise(jsonb_build_object(v_k2::text, 'spec', v_k4::text, 'brief', v_k3::text, 'spec'));
    assert false, 'une décision sans objet a été acceptée';
  exception when raise_exception then v_msg := sqlerrm; end;
  assert v_msg like '%' || v_k3 || '%', format('la décision sans objet n''est pas nommée : %s', v_msg);

  -- c) tranchés : la spec pour l'un, le brief pour l'autre
  v_r := public.practice_place_reprise(jsonb_build_object(v_k2::text, 'spec', v_k4::text, 'brief'));
  assert (v_r->>'decided')::int = 2 and (v_r->>'taken')::int = 1, format('comptes faux : %s', v_r);
  assert (select state || '/' || city from public.project_briefs where project_id = v_p1) = 'CA/Oakland',
    'la reprise n''a pas porté le lieu de la spec dans un brief vide';
  assert (select state || '/' || city from public.project_briefs where project_id = v_p2) = 'CA/Oakland',
    'la décision « spec » n''a pas atteint le brief';
  assert (select state || '/' || city from public.project_briefs where project_id = v_p4) = 'WA/Seattle',
    'la décision « brief » a laissé la spec écrire le brief';

  -- d) puis l'alignement : chaque spec dit ce que dit son brief
  update public.site_specs set practice_details = practice_details where brand_kit_id in (v_k1, v_k2, v_k3, v_k4);
  assert (select practice_details->>'state' || '/' || (practice_details->>'city')
            from public.site_specs where brand_kit_id = v_k4) = 'WA/Seattle',
    'l''alignement a laissé une spec en désaccord avec son brief';
  assert (select practice_details->>'state' from public.site_specs where brand_kit_id = v_k3) = 'ca',
    'l''alignement n''a pas porté la valeur du brief telle qu''elle est';
end $$;

-- ── 4. Un post sait pour quel État il a été signé ─────────────────────────
do $$
declare
  v_user  uuid := 'aaaaaaaa-f760-0000-0000-000000000004';
  v_other uuid := 'aaaaaaaa-f760-0000-0000-000000000005';
  v_project uuid;
  v_kit uuid;
  v_mod text;
  v_per text;
  v_seg_ca uuid;
  v_seg_or uuid;
  v_topic_or uuid;
  v_item uuid;
  v_r jsonb;
  v_refused boolean;
begin
  insert into auth.users (id, email) values (v_user, 'f76-items@eklio-test.invalid'), (v_other, 'f76-other@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'f76 items') returning id into v_project;
  insert into public.project_briefs (project_id, state, license_type_id) values (v_project, 'ca', 'lmft');
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;

  select id into v_mod from public.modality_cards limit 1;
  select id into v_per from public.client_persona_cards limit 1;
  insert into public.content_segments (modality_id, persona_id, state_code) values (v_mod, v_per, 'CA') returning id into v_seg_ca;
  insert into public.content_segments (modality_id, persona_id, state_code) values (v_mod, v_per, 'OR') returning id into v_seg_or;
  insert into public.content_topics (segment_id, archetype_key, intent, title, hook, payload, caption_seed, rationale_template, ethics_reviewed_at)
       values (v_seg_or, 'single_statement', 'normalise', 'OR topic', 'A hook',
               '{"statement":"A statement written for one state only"}'::jsonb, 'seed', 'why', now())
    returning id into v_topic_or;

  -- a) un écrivain qui ne dit rien reçoit l'autorité, en majuscules
  insert into public.content_items (brand_kit_id, archetype) values (v_kit, 'statement') returning id into v_item;
  assert (select licence_state_code from public.content_items where id = v_item) = 'CA',
    'un post écrit sans État n''a pas reçu l''État qui fait autorité';

  -- b) un écrivain qui dit un autre État est refusé
  v_refused := false;
  begin
    insert into public.content_items (brand_kit_id, archetype, licence_state_code) values (v_kit, 'statement', 'OR');
  exception when check_violation then v_refused := sqlerrm like 'licence_state_mismatch%'; end;
  assert v_refused, 'un post signé pour l''Oregon a été écrit pour un cabinet californien';

  -- c) un sujet rédigé pour un autre État est refusé
  v_refused := false;
  begin
    insert into public.content_items (brand_kit_id, archetype, topic_id) values (v_kit, 'statement', v_topic_or);
  exception when check_violation then v_refused := sqlerrm like 'licence_state_mismatch%'; end;
  assert v_refused, 'un sujet de l''Oregon a fait un post californien';

  -- d) le cachet ne se réécrit pas
  v_refused := false;
  begin
    update public.content_items set licence_state_code = 'OR' where id = v_item;
  exception when check_violation then v_refused := true; end;
  assert v_refused, 'le cachet d''un post a été réécrit';

  -- e) l'État change : le post ne passe plus « ready », et la route le refuse
  update public.project_briefs set state = 'OR' where project_id = v_project;
  v_refused := false;
  begin
    update public.content_items set status = 'ready' where id = v_item;
  exception when check_violation then v_refused := sqlerrm like 'licence_state_mismatch%'; end;
  assert v_refused, 'un post signé pour la Californie est passé « ready » sous l''Oregon';

  perform set_config('request.jwt.claims', json_build_object('sub', v_user)::text, true);
  set local role authenticated;
  v_r := public.content_item_licence_state_problem(v_item);
  assert v_r->>'code' = 'licence_state_mismatch' and v_r->>'item_state' = 'CA' and v_r->>'practice_state' = 'OR',
    format('la route ne refuserait pas : %s', v_r);
  reset role;

  -- f) d'accord à nouveau : il passe
  update public.project_briefs set state = 'CA' where project_id = v_project;
  set local role authenticated;
  v_r := public.content_item_licence_state_problem(v_item);
  assert (v_r->>'ok')::boolean, format('un post d''accord est refusé : %s', v_r);
  reset role;
  update public.content_items set status = 'ready' where id = v_item;

  -- g) ce n'est pas à une autre de le demander
  perform set_config('request.jwt.claims', json_build_object('sub', v_other)::text, true);
  set local role authenticated;
  v_r := public.content_item_licence_state_problem(v_item);
  assert v_r->>'code' = 'not_found', format('une autre lit l''État du post : %s', v_r);
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

-- ── 5. Pas de troisième source — dérivé du catalogue, pas d'une liste écrite ─
do $$
declare
  v_found text;
begin
  -- a) la colonne retirée l'est, et aucune fonction ne la nomme
  assert not exists (select 1 from information_schema.columns
                      where table_schema = 'public' and column_name = 'license_state_code'),
    'license_state_code existe encore';
  select string_agg(proname, ', ') into v_found
    from pg_proc where pronamespace = 'public'::regnamespace and prosrc ~ 'license_state_code';
  assert v_found is null, format('des fonctions lisent encore license_state_code : %s', v_found);

  -- b) aucune fonction de la chaîne du contenu ne lit l'État de la spec
  select string_agg(proname, ', ') into v_found
    from pg_proc
   where pronamespace = 'public'::regnamespace
     and prosrc ~ 'practice_details'
     and prosrc ~ '(content_segments|content_topics|content_items|license_type_states|state_code)';
  assert v_found is null, format('des fonctions du contenu lisent la spec du site : %s', v_found);

  -- c) toute colonne de lieu est classée ; une nouvelle fait échouer ce test
  select string_agg(table_name || '.' || column_name, ', ' order by table_name, column_name) into v_found
    from information_schema.columns c
    join information_schema.tables t using (table_schema, table_name)
   where c.table_schema = 'public' and t.table_type = 'BASE TABLE'
     and (c.column_name ~ '(^|_)state(_code)?$' or c.column_name ~ '(^|_)city$' or c.column_name ~ 'states')
     and (table_name || '.' || column_name) not in (
       'project_briefs.state',                 -- l'autorité
       'project_briefs.city',                  -- l'autorité
       'content_items.licence_state_code',     -- un cachet, comparé à l'autorité
       'content_segments.state_code',          -- la banque : créé depuis le brief, comparé à lui
       'license_type_states.state_code',       -- la matrice F12 : une référence, pas un lieu
       'sellability_decisions.states_sellable',-- le catalogue de vente : une référence
       -- des machines à états, pas des lieux :
       'content_generation_runs.state', 'content_grounds.state', 'insight_runs.state',
       'on_demand_writes.state', 'subscriptions.trial_notice_state', 'brand_kits.charter_accepted_state');
  assert v_found is null, format('colonne(s) de lieu non classée(s) — une troisième source ? %s', v_found);
end $$;

-- ── 6. Fermées aux clients ────────────────────────────────────────────────
do $$
begin
  assert not has_function_privilege('authenticated', 'public.practice_place_reprise(jsonb)', 'execute'), 'reprise ouverte aux clients';
  assert not has_function_privilege('anon', 'public.practice_place_reprise(jsonb)', 'execute'), 'reprise ouverte à anon';
  assert not has_function_privilege('authenticated', 'public.practice_state_of_kit(uuid)', 'execute'), 'autorité ouverte aux clients';
  assert not has_function_privilege('anon', 'public.site_specs_place_from_brief()', 'execute'), 'trigger ouvert à anon';
  assert not has_function_privilege('anon', 'public.project_briefs_place_to_specs()', 'execute'), 'trigger ouvert à anon';
  assert not has_function_privilege('anon', 'public.content_items_licence_state()', 'execute'), 'trigger ouvert à anon';
  assert not has_function_privilege('anon', 'public.content_item_licence_state_problem(uuid)', 'execute'), 'contrôle ouvert à anon';
  assert has_function_privilege('authenticated', 'public.content_item_licence_state_problem(uuid)', 'execute'), 'la route ne peut pas demander';
end $$;

rollback;
