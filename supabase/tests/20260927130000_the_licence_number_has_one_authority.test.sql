-- F64 : le numéro de licence a une seule autorité, project_briefs.license_number.
begin;

-- ── 1. La règle en mots s'accorde avec la contrainte, cas par cas ─────────
do $$
declare
  v_case text;
  v_says_ok boolean;
  v_db_ok boolean;
  v_project uuid;
  v_user uuid;
begin
  insert into auth.users (email) values ('f64-shape@eklio-test.invalid') returning id into v_user;
  insert into public.projects (user_id, name) values (v_user, 'f64 shape') returning id into v_project;
  insert into public.project_briefs (project_id) values (v_project);

  foreach v_case in array array['LMFT 12345', '12345', 'A1', 'ABCDE', ' 123', '123 ', 'PSY#12.3-4',
                                'a/123', '12345678901234567890', '123456789012345678901', '1-', '#12'] loop
    v_says_ok := public.licence_number_problem(v_case) is null;
    begin
      update public.project_briefs set license_number = v_case where project_id = v_project;
      v_db_ok := true;
    exception when check_violation then v_db_ok := false; end;
    assert v_says_ok = v_db_ok,
      format('« %s » : la règle en mots dit %s, la contrainte dit %s', v_case, v_says_ok, v_db_ok);
  end loop;
end $$;

-- ── 2. Les trois sens de la projection ──────────────────────────────────
do $$
declare
  v_user uuid := 'aaaaaaaa-f640-0000-0000-000000000001';
  v_project uuid;
  v_kit uuid;
  v_n text;
begin
  insert into auth.users (id, email) values (v_user, 'f64-authority@eklio-test.invalid');
  insert into public.projects (user_id, name) values (v_user, 'f64') returning id into v_project;
  insert into public.project_briefs (project_id, license_number) values (v_project, 'LMFT 111');
  insert into public.brand_kits (project_id) values (v_project) returning id into v_kit;

  -- a) une spec créée prend la valeur du brief, quoi qu'on lui donne
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex, light_neutral_hex,
     dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url, hero, pages, practice_details)
  values (v_kit, v_user, '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
          '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb,
          public.site_spec_default_pages(null, null), '{"license_number": null}'::jsonb);
  select practice_details->>'license_number' into v_n from public.site_specs where brand_kit_id = v_kit;
  assert v_n = 'LMFT 111', format('une spec neuve ne porte pas le numéro du brief : %s', v_n);

  -- b) l'éditeur de site écrit DANS LE BRIEF
  update public.site_specs set practice_details = practice_details || '{"license_number":"LMFT 222"}'
   where brand_kit_id = v_kit;
  select license_number into v_n from public.project_briefs where project_id = v_project;
  assert v_n = 'LMFT 222', format('une édition par la spec n''a pas atteint le brief : %s', v_n);

  -- c) une écriture directe du brief atteint la spec (un kit par projet : brand_kits_project_id_key)
  update public.project_briefs set license_number = 'LMFT 333' where project_id = v_project;
  assert (select practice_details->>'license_number' from public.site_specs where brand_kit_id = v_kit) = 'LMFT 333',
    'le brief a changé et la spec porte encore l''ancien numéro';

  -- d) une édition d'AUTRE chose ne réécrit pas le numéro
  update public.site_specs set practice_details = practice_details || '{"city":"Oakland"}'
   where brand_kit_id = v_kit;
  assert (select license_number from public.project_briefs where project_id = v_project) = 'LMFT 333',
    'une édition de la ville a touché le numéro';

  -- e) effacer par l'éditeur efface l'autorité — et le préalable le dira
  update public.site_specs set practice_details = practice_details || '{"license_number":""}'
   where brand_kit_id = v_kit;
  assert (select license_number from public.project_briefs where project_id = v_project) is null,
    'un champ vidé dans l''éditeur a laissé le numéro au brief';
  assert (select practice_details->'license_number' from public.site_specs where brand_kit_id = v_kit) = 'null'::jsonb,
    'une spec garde un numéro que le brief n''a plus';

  -- f) une forme refusée par le brief ne passe pas par la spec
  begin
    update public.site_specs set practice_details = practice_details || '{"license_number":"no digits"}'
     where brand_kit_id = v_kit;
    assert false, 'un numéro sans chiffre est passé par la spec';
  exception when check_violation then null; end;
end $$;

-- ── 3. site_spec_patch rend une erreur de CHAMP, en mots ──────────────────
do $$
declare
  v_user uuid := 'aaaaaaaa-f640-0000-0000-000000000001';
  v_kit uuid;
  v_project uuid;
  v_r jsonb;
begin
  select ss.brand_kit_id, bk.project_id into v_kit, v_project
    from public.site_specs ss join public.brand_kits bk on bk.id = ss.brand_kit_id
   where ss.user_id = v_user limit 1;
  -- le droit au kit : un achat payé, comme le webhook l'écrit
  insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
       values (v_user, v_project, 'starter', 'cs_f64_patch', 7900, 'paid', now());
  perform set_config('request.jwt.claims', json_build_object('sub', v_user)::text, true);
  set local role authenticated;

  v_r := public.site_spec_patch(v_kit, '{"practice_details":{"license_number":"no digits"}}');
  assert v_r->'error'->>'code' = 'invalid_field', format('attendu invalid_field, reçu %s', v_r);
  assert v_r->'error'->>'field' = 'practice_details.license_number', format('l''erreur ne nomme pas le champ : %s', v_r);
  assert v_r->'error'->>'message' like '%digit%', format('l''erreur ne dit pas quoi corriger : %s', v_r);

  v_r := public.site_spec_patch(v_kit, '{"practice_details":{"license_number":"LMFT 777"}}');
  assert v_r->'error' is null, format('un numéro valide est refusé : %s', v_r);
  reset role;
  assert (select license_number from public.project_briefs where project_id = v_project) = 'LMFT 777',
    'le patch de l''éditeur n''a pas écrit le brief';
  perform set_config('request.jwt.claims', null, true);
end $$;

-- ── 4. La reprise : les trois cas ─────────────────────────────────────────
do $$
declare
  v_user uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid;
  v_k1 uuid; v_k2 uuid; v_k3 uuid;
  v_r jsonb;
  v_stopped boolean := false;
begin
  insert into auth.users (email) values ('f64-reprise@eklio-test.invalid') returning id into v_user;
  insert into public.projects (user_id, name) values (v_user, 'r1') returning id into v_p1;
  insert into public.projects (user_id, name) values (v_user, 'r2') returning id into v_p2;
  insert into public.projects (user_id, name) values (v_user, 'r3') returning id into v_p3;
  insert into public.project_briefs (project_id) values (v_p1);
  insert into public.project_briefs (project_id, license_number) values (v_p2, 'LCSW 900');
  insert into public.project_briefs (project_id) values (v_p3);
  insert into public.brand_kits (project_id) values (v_p1) returning id into v_k1;
  insert into public.brand_kits (project_id) values (v_p2) returning id into v_k2;
  insert into public.brand_kits (project_id) values (v_p3) returning id into v_k3;

  -- l'état d'AVANT la migration : des numéros tapés dans les specs seulement
  alter table public.site_specs disable trigger site_specs_licence_number_from_brief;
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex, light_neutral_hex,
     dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url, hero, pages, practice_details)
  select k, v_user, '#000000','#000000','#000000','#FFFFFF','#000000','#FFFFFF','A','B','u',
         '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb,
         public.site_spec_default_pages(null, null), jsonb_build_object('license_number', n)
    from (values (v_k1, 'LMFT 555'), (v_k2, 'LCSW 111'), (v_k3, 'no digits')) v(k, n);
  alter table public.site_specs enable trigger site_specs_licence_number_from_brief;

  -- une forme invalide ARRÊTE
  begin
    perform public.licence_number_reprise();
  exception when others then v_stopped := sqlerrm like '%no digits%'; end;
  assert v_stopped, 'la reprise a accepté un numéro que la contrainte refuse, ou ne l''a pas nommé';

  alter table public.site_specs disable trigger site_specs_licence_number_from_brief;
  update public.site_specs set practice_details = '{"license_number": null}' where brand_kit_id = v_k3;
  alter table public.site_specs enable trigger site_specs_licence_number_from_brief;

  v_r := public.licence_number_reprise();
  assert (select license_number from public.project_briefs where project_id = v_p1) = 'LMFT 555',
    'la reprise n''a pas porté le numéro de la spec dans un brief vide';
  assert (select license_number from public.project_briefs where project_id = v_p2) = 'LCSW 900',
    'la reprise a laissé la spec l''emporter sur le brief';
  assert (v_r->>'brief_won')::int >= 1, format('le désaccord n''est pas compté : %s', v_r);

  -- puis l'alignement : la spec en désaccord prend la valeur du brief
  update public.site_specs set practice_details = practice_details where brand_kit_id = v_k2;
  -- ⚠ la ligne ci-dessus est vue comme une ÉDITION si la spec diffère d'elle-même : elle ne l'est pas,
  -- donc c'est le brief qui gagne.
  assert (select practice_details->>'license_number' from public.site_specs where brand_kit_id = v_k2) = 'LCSW 900',
    'l''alignement a laissé la spec en désaccord avec le brief';
end $$;

-- ── 5. Fermées aux clients ────────────────────────────────────────────────
do $$
begin
  assert not has_function_privilege('anon', 'public.licence_number_reprise()', 'execute'), 'reprise ouverte à anon';
  assert not has_function_privilege('authenticated', 'public.licence_number_reprise()', 'execute'), 'reprise ouverte aux clients';
  assert not has_function_privilege('anon', 'public.site_specs_licence_number_from_brief()', 'execute'), 'trigger ouvert à anon';
  assert not has_function_privilege('anon', 'public.project_briefs_licence_number_to_specs()', 'execute'), 'trigger ouvert à anon';
end $$;

rollback;
