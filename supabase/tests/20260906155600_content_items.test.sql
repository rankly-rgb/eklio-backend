-- ============================================================================
-- Tests — 20260906155600_content_items.sql
--
-- Ce que ces tests fixent, dans l'ordre d'importance :
--
--   1. L'ORDRE DES REFUS. Le kit d'une inconnue répond `not_found`, jamais
--      `payment_required` — sinon le code de refus confirme l'existence du kit.
--   2. LE JOURNAL EST L'ÉTAT DE PUBLICATION. Il n'y a pas de `published_at`
--      sur l'item : rien ne peut diverger de rien.
--   3. LE PATCH DIT LA DIFFÉRENCE entre « ne touche pas » (clé absente) et
--      « efface » (clé présente, valeur nulle). Neuf arguments nullables ne le
--      peuvent pas, et c'est la raison pour laquelle la signature est un jsonb.
--   4. AUCUNE ÉCRITURE CLIENTE. Les deux tables refusent INSERT/UPDATE/DELETE
--      à `authenticated`, journal compris : un journal réinscriptible n'est
--      pas un journal.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-0000000000c1','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-0000000000c2','stranger@example.com'),
  ('aaaaaaaa-0000-0000-0000-0000000000c3','unpaid@example.com');

insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-0000000000c1','Elm & Ember'),
  ('bbbbbbbb-0000-0000-0000-0000000000c3','aaaaaaaa-0000-0000-0000-0000000000c3','Unpaid Practice');

insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000c1','bbbbbbbb-0000-0000-0000-0000000000c1'),
  ('cccccccc-0000-0000-0000-0000000000c3','bbbbbbbb-0000-0000-0000-0000000000c3');

insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-0000000000c1','bbbbbbbb-0000-0000-0000-0000000000c1',
        'starter','cs_test_c1',7900,'paid',now());

create or replace function pg_temp.as_owner() returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  execute 'set local request.jwt.claims = ''{"sub":"aaaaaaaa-0000-0000-0000-0000000000c1"}''';
end $$;

-- ---------------------------------------------------------------------------
-- 1. L'ordre des refus : inconnue -> not_found, propriétaire impayée ->
--    payment_required. Jamais l'inverse.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000c2"}';
  v := public.create_content_item('cccccccc-0000-0000-0000-0000000000c1','statement');
  assert v #>> '{error,code}' = 'not_found',
    format('le kit d''une inconnue doit répondre not_found, reçu %s', v);
  v := public.get_content_month('cccccccc-0000-0000-0000-0000000000c1', current_date);
  assert v #>> '{error,code}' = 'not_found', format('lecture : not_found attendu, reçu %s', v);
  v := public.get_publishing_log('cccccccc-0000-0000-0000-0000000000c1');
  assert v #>> '{error,code}' = 'not_found', format('journal : not_found attendu, reçu %s', v);

  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000c3"}';
  v := public.create_content_item('cccccccc-0000-0000-0000-0000000000c3','statement');
  assert v #>> '{error,code}' = 'payment_required',
    format('son propre kit impayé doit répondre payment_required, reçu %s', v);
  reset role;

  assert (select count(*) from public.content_items) = 0,
    'un refus a laissé une ligne derrière lui';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Le patch : clé absente = ne touche pas, clé présente à null = efface.
--    Et une clé inconnue est refusée plutôt qu'ignorée en silence.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_id uuid; v_item jsonb;
begin
  perform pg_temp.as_owner();
  v := public.create_content_item('cccccccc-0000-0000-0000-0000000000c1','notes','2026-09-10');
  v_id := (v->>'id')::uuid;
  assert v_id is not null, format('création attendue, reçu %s', v);

  v := public.update_content_item(v_id, jsonb_build_object('title','Between sessions','caption','A caption.'));
  assert v ? 'saved_at', format('sauvegarde attendue, reçu %s', v);

  -- Clé absente : le titre survit à un patch qui ne parle que de la légende.
  v := public.update_content_item(v_id, jsonb_build_object('caption','A second caption.'));
  v_item := public.get_content_item(v_id);
  assert v_item->>'title' = 'Between sessions',
    format('une clé absente a effacé le titre : %s', v_item);
  assert v_item->>'caption' = 'A second caption.', format('légende non écrite : %s', v_item);

  -- Clé présente à null : efface, et c'est une demande différente.
  v := public.update_content_item(v_id, jsonb_build_object('title', null));
  v_item := public.get_content_item(v_id);
  assert v_item->>'title' is null, format('un null explicite n''a pas effacé : %s', v_item);

  -- Une clé inconnue est un bug d'appelant, pas une clé à ignorer.
  v := public.update_content_item(v_id, jsonb_build_object('titel','typo'));
  assert v #>> '{error,code}' = 'unknown_field', format('clé inconnue acceptée : %s', v);
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Les étiquettes sont normalisées : espaces, casse, doublons, tri.
-- ---------------------------------------------------------------------------
do $$
declare v_id uuid; v_item jsonb;
begin
  perform pg_temp.as_owner();
  v_id := (public.create_content_item('cccccccc-0000-0000-0000-0000000000c1','question')->>'id')::uuid;
  perform public.update_content_item(v_id, jsonb_build_object(
    'tags', jsonb_build_array('  Anxiety ', 'anxiety', 'SLEEP', '', 'boundaries')));
  v_item := public.get_content_item(v_id);
  assert v_item->'tags' = '["anxiety","boundaries","sleep"]'::jsonb,
    format('étiquettes non normalisées : %s', v_item->'tags');
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 4. Le journal EST l'état de publication.
--    Marquer deux fois n'écrit qu'une ligne ; dépublier en écrit une seconde.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_id uuid; v_item jsonb; v_rows int;
begin
  perform pg_temp.as_owner();
  v_id := (public.create_content_item('cccccccc-0000-0000-0000-0000000000c1','signature','2026-09-12')->>'id')::uuid;

  v_item := public.get_content_item(v_id);
  assert (v_item->>'posted')::boolean = false, format('un item neuf est publié : %s', v_item);
  assert v_item->>'posted_at' is null, 'posted_at renseigné sans publication';

  v := public.mark_content_posted(v_id, true, 'instagram');
  assert (v->>'changed')::boolean, format('publication attendue, reçu %s', v);
  v_item := public.get_content_item(v_id);
  assert (v_item->>'posted')::boolean, format('état non dérivé du journal : %s', v_item);
  assert v_item->>'channel' = 'instagram', format('canal perdu : %s', v_item);
  assert v_item->>'posted_at' is not null, 'posted_at vide après publication';

  -- Idempotence : un double clic n'invente pas une seconde publication.
  v := public.mark_content_posted(v_id, true, 'instagram');
  assert (v->>'changed')::boolean = false, format('doublon écrit : %s', v);

  v := public.mark_content_posted(v_id, false);
  assert (v->>'changed')::boolean, format('dépublication attendue, reçu %s', v);
  v_item := public.get_content_item(v_id);
  assert (v_item->>'posted')::boolean = false, format('encore publié après dépublication : %s', v_item);

  reset role;
  select count(*) into v_rows from public.content_publications where content_item_id = v_id;
  assert v_rows = 2, format('le journal devrait porter 2 lignes, il en porte %s', v_rows);
end
$$;

-- ---------------------------------------------------------------------------
-- 5. Aucune écriture cliente, sur AUCUNE des deux tables.
-- ---------------------------------------------------------------------------
do $$
declare v_id uuid; v_denied boolean;
begin
  select id into v_id from public.content_items limit 1;

  perform pg_temp.as_owner();

  v_denied := false;
  begin
    insert into public.content_items (brand_kit_id, archetype)
    values ('cccccccc-0000-0000-0000-0000000000c1','statement');
  exception when insufficient_privilege then v_denied := true;
  end;
  assert v_denied, 'un client a pu insérer un content_item directement';

  v_denied := false;
  begin
    update public.content_items set title = 'forced' where id = v_id;
    -- Une UPDATE refusée par RLS ne lève pas : elle ne touche aucune ligne.
    v_denied := not found;
  exception when insufficient_privilege then v_denied := true;
  end;
  assert v_denied, 'un client a pu modifier un content_item directement';

  v_denied := false;
  begin
    insert into public.content_publications (content_item_id, action) values (v_id, 'published');
  exception when insufficient_privilege then v_denied := true;
  end;
  assert v_denied, 'un client a pu écrire dans le journal';

  v_denied := false;
  begin
    delete from public.content_publications where content_item_id = v_id;
    v_denied := not found;
  exception when insufficient_privilege then v_denied := true;
  end;
  assert v_denied, 'un client a pu effacer une ligne de journal';

  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 6. L'auxiliaire partagé n'est pas une surface : `content_item_json` ne fait
--    aucun contrôle d'accès, donc `authenticated` ne doit pas pouvoir l'appeler.
-- ---------------------------------------------------------------------------
do $$
declare v_id uuid; v_denied boolean := false;
begin
  select id into v_id from public.content_items limit 1;
  perform pg_temp.as_owner();
  begin
    perform public.content_item_json(v_id);
  exception when insufficient_privilege then v_denied := true;
  end;
  assert v_denied, 'content_item_json est appelable par authenticated';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 7. Le mois : ce qui est planifié dedans, ce qui ne l'est pas, ce qui est
--    archivé — et les compteurs qui vont avec.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_id uuid;
begin
  perform pg_temp.as_owner();

  -- Un item hors du mois demandé, un archivé, un sans date.
  perform public.create_content_item('cccccccc-0000-0000-0000-0000000000c1','statement','2026-10-04');
  v_id := (public.create_content_item('cccccccc-0000-0000-0000-0000000000c1','story','2026-09-20')->>'id')::uuid;
  perform public.update_content_item(v_id, jsonb_build_object('status','archived'));
  perform public.create_content_item('cccccccc-0000-0000-0000-0000000000c1','notes');

  v := public.get_content_month('cccccccc-0000-0000-0000-0000000000c1','2026-09-01');

  assert not exists (
    select 1 from jsonb_array_elements(v->'items') as i
     where (i->>'scheduled_for')::date >= '2026-10-01'
  ), format('un item d''octobre est apparu dans septembre : %s', v->'items');

  assert not exists (
    select 1 from jsonb_array_elements(v->'items') as i where i->>'status' = 'archived'
  ), 'un item archivé est rendu dans le mois';

  assert jsonb_array_length(v->'unscheduled') >= 1, format('les sans-date manquent : %s', v);
  assert not exists (
    select 1 from jsonb_array_elements(v->'unscheduled') as i where i->>'scheduled_for' is not null
  ), 'un item daté est rangé dans les sans-date';

  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 8. Le journal se lit du plus récent au plus ancien, et il porte le titre.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_first jsonb;
begin
  perform pg_temp.as_owner();
  v := public.get_publishing_log('cccccccc-0000-0000-0000-0000000000c1');
  assert jsonb_array_length(v->'entries') = 2,
    format('deux lignes attendues au journal, reçu %s', v->'entries');
  v_first := (v->'entries')->0;
  assert v_first->>'action' = 'unpublished',
    format('la ligne la plus récente devrait être la dépublication : %s', v_first);
  assert v_first ? 'archetype', format('le journal ne porte pas l''archétype : %s', v_first);
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 9. Structurel : l'état de publication n'a qu'un seul domicile, et rien ici
--    ne touche à la table morte.
-- ---------------------------------------------------------------------------
do $$
begin
  assert not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'content_items'
       and column_name in ('published_at','posted_at','published')
  ), 'content_items a repris une colonne de publication';

  /*
   * ⚠ ASSERTION INVERSÉE, PAS SUPPRIMÉE. Ces deux lignes vérifiaient que la
   * table morte gardait zéro ligne et ses quatre policies — c'est-à-dire que
   * cette migration-ci ne l'avait pas touchée. 20260910082539 l'a RETIRÉE.
   * L'affirmation devient donc plus forte : elle n'existe plus du tout.
   */
  assert not exists (
    select 1 from information_schema.tables
     where table_schema = 'public' and table_name = 'monthly' || '_presence_' || 'content'
  ), 'la table morte est revenue';
end
$$;

rollback;
