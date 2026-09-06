-- ============================================================================
-- Tests — 20260906164920_user_uploads.sql
--
-- Par ordre d'importance :
--
--   1. UN FICHIER À ELLE NE PORTE PAS D'EMPREINTE. Aucune colonne d'invalidation
--      n'existe sur la table, et changer sa palette ne touche à rien.
--   2. LE QUOTA EST DANS LA RPC. Un client ne peut pas insérer directement, et
--      `record_user_upload` re-vérifie au moment où la ligne se crée.
--   3. L'ORDRE DES REFUS, hérité : le kit d'une inconnue répond `not_found`.
--   4. LE PORTRAIT SE REMPLACE, et l'ancien chemin revient pour que l'objet
--      parte avec la ligne.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-0000000000d1','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-0000000000d2','stranger@example.com');

insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-0000000000d1','Elm & Ember');

insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000d1','bbbbbbbb-0000-0000-0000-0000000000d1');

insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-0000000000d1','bbbbbbbb-0000-0000-0000-0000000000d1',
        'starter','cs_test_d1',7900,'paid',now());

create or replace function pg_temp.as_owner() returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  execute 'set local request.jwt.claims = ''{"sub":"aaaaaaaa-0000-0000-0000-0000000000d1"}''';
end $$;

-- ---------------------------------------------------------------------------
-- 1. Structurel : rien ici ne peut être invalidé par un changement de couleur.
-- ---------------------------------------------------------------------------
do $$
begin
  assert not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'user_uploads'
       and (column_name like '%fingerprint%'
         or column_name in ('superseded_at','current','stale','change_summary'))
  ), 'user_uploads a gagné une colonne d''invalidation';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. L'ordre des refus.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000d2"}';
  v := public.request_user_upload('cccccccc-0000-0000-0000-0000000000d1','portrait','image/jpeg', 1000);
  assert v #>> '{error,code}' = 'not_found', format('not_found attendu, reçu %s', v);
  v := public.list_user_uploads('cccccccc-0000-0000-0000-0000000000d1');
  assert v #>> '{error,code}' = 'not_found', format('lecture : not_found attendu, reçu %s', v);
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Le chemin est construit par la base, et il commence par l'id du kit —
--    c'est ce que la politique de stockage lit pour décider l'appartenance.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  perform pg_temp.as_owner();
  v := public.request_user_upload('cccccccc-0000-0000-0000-0000000000d1','portrait','image/jpeg', 120000);
  assert v->>'path' like 'cccccccc-0000-0000-0000-0000000000d1/uploads/%.jpg',
    format('chemin inattendu : %s', v);

  -- Un type non listé est refusé AVANT tout le reste.
  v := public.request_user_upload('cccccccc-0000-0000-0000-0000000000d1','portrait','image/gif', 1000);
  assert v #>> '{error,code}' = 'unsupported_type', format('gif accepté : %s', v);

  -- Un « kind » inventé aussi.
  v := public.request_user_upload('cccccccc-0000-0000-0000-0000000000d1','banner','image/png', 1000);
  assert v #>> '{error,code}' = 'unsupported_type', format('kind inventé accepté : %s', v);
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 4. Le quota est dans la RPC, et il refuse aux deux étapes.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_id uuid;
begin
  perform pg_temp.as_owner();

  -- Trop gros : refusé à la demande.
  v := public.request_user_upload('cccccccc-0000-0000-0000-0000000000d1','photo','image/png', 20000000);
  assert v #>> '{error,code}' = 'file_too_large', format('fichier géant accepté : %s', v);

  -- Et refusé AUSSI à l'enregistrement, même si l'appelant saute la demande.
  v := public.record_user_upload(
    'cccccccc-0000-0000-0000-0000000000d1', gen_random_uuid(), 'photo',
    'cccccccc-0000-0000-0000-0000000000d1/uploads/forged.png', 'image/png', 20000000, 'x.png');
  assert v #>> '{error,code}' = 'file_too_large',
    format('l''enregistrement n''a pas revérifié le quota : %s', v);

  -- Un chemin sous le kit de quelqu'un d'autre ne s'enregistre pas.
  v := public.record_user_upload(
    'cccccccc-0000-0000-0000-0000000000d1', gen_random_uuid(), 'photo',
    'dddddddd-0000-0000-0000-000000000099/uploads/x.png', 'image/png', 1000, 'x.png');
  assert v #>> '{error,code}' = 'not_found', format('chemin forgé accepté : %s', v);
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 5. Le portrait se remplace, et rend l'ancien chemin.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_first uuid; v_second uuid; v_path text; v_rows int;
begin
  perform pg_temp.as_owner();

  v := public.request_user_upload('cccccccc-0000-0000-0000-0000000000d1','portrait','image/jpeg', 100000);
  v_first := (v->>'id')::uuid;
  v_path := v->>'path';
  v := public.record_user_upload('cccccccc-0000-0000-0000-0000000000d1', v_first, 'portrait',
                                 v_path, 'image/jpeg', 100000, 'me.jpg');
  assert v->>'id' = v_first::text, format('premier portrait non enregistré : %s', v);
  assert v->>'replaced_path' is null, 'un premier portrait a remplacé quelque chose';

  v := public.request_user_upload('cccccccc-0000-0000-0000-0000000000d1','portrait','image/png', 90000);
  v_second := (v->>'id')::uuid;
  v := public.record_user_upload('cccccccc-0000-0000-0000-0000000000d1', v_second, 'portrait',
                                 v->>'path', 'image/png', 90000, 'me2.png');
  assert v->>'replaced_path' = v_path,
    format('le chemin remplacé n''est pas rendu : %s', v);

  reset role;
  select count(*) into v_rows from public.user_uploads
   where brand_kit_id = 'cccccccc-0000-0000-0000-0000000000d1' and kind = 'portrait';
  assert v_rows = 1, format('il devrait rester UN portrait, il y en a %s', v_rows);
end
$$;

-- ---------------------------------------------------------------------------
-- 6. Aucune écriture cliente directe : le quota serait sans effet.
-- ---------------------------------------------------------------------------
do $$
declare v_id uuid; v_denied boolean;
begin
  select id into v_id from public.user_uploads limit 1;
  perform pg_temp.as_owner();

  v_denied := false;
  begin
    insert into public.user_uploads (brand_kit_id, kind, storage_path, mime_type, byte_size)
    values ('cccccccc-0000-0000-0000-0000000000d1','photo','x/y.png','image/png', 10);
  exception when insufficient_privilege then v_denied := true;
  end;
  assert v_denied, 'un client a pu insérer un upload directement';

  v_denied := false;
  begin
    delete from public.user_uploads where id = v_id;
    v_denied := not found;
  exception when insufficient_privilege then v_denied := true;
  end;
  assert v_denied, 'un client a pu supprimer un upload directement';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 7. La suppression rend le chemin, pour que l'objet parte avec la ligne.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_id uuid; v_path text;
begin
  perform pg_temp.as_owner();
  select id, storage_path into v_id, v_path from public.user_uploads limit 1;
  v := public.delete_user_upload(v_id);
  assert (v->>'deleted')::boolean, format('suppression refusée : %s', v);
  assert v->>'path' = v_path, format('le chemin n''est pas rendu : %s', v);

  -- Une seconde suppression n'invente pas un succès.
  v := public.delete_user_upload(v_id);
  assert v #>> '{error,code}' = 'not_found', format('double suppression : %s', v);
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- 8. Une seule définition de l'accès : `content_kit_access` délègue.
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'content_kit_access')
         like '%kit_paid_access%',
    'content_kit_access ne délègue plus : deux copies de l''ordre des refus';
end
$$;

rollback;
