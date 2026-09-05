-- ============================================================================
-- Tests — 20260905191203_asset_version_history.sql
--
-- L'invariant qui compte : il y a toujours EXACTEMENT une version courante
-- par clé, y compris quand elle remet une couleur d'avant, et une version
-- ancienne reste servie depuis ce qui a été stocké -- jamais re-rendue,
-- puisque les entrées qui l'ont produite n'existent plus.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000094','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000095','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000094','aaaaaaaa-0000-0000-0000-000000000094','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000094','bbbbbbbb-0000-0000-0000-000000000094');
insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-000000000094','bbbbbbbb-0000-0000-0000-000000000094',
        'starter','cs_test_94',7900,'paid',now());

-- ---------------------------------------------------------------------------
-- Une première version n'a rien à comparer : pas de phrase, rien de dépassé.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_versions jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000094"}';

  v := public.get_brand_asset_previous_inputs(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000001');
  assert v->'inputs' = '{}'::jsonb,
    format('un premier rendu n''a rien à quoi se comparer, reçu %s', v);

  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000001',
    'cccccccc-0000-0000-0000-000000000094/aaaa000000000001/favicon_32.png', 900, 32, 32,
    0, '', '', '{"tokens":{"primary":"#B4653F"}}'::jsonb);
  assert v ? 'id', format('la première version aurait dû être enregistrée, reçu %s', v);

  v_versions := public.get_brand_asset_versions('cccccccc-0000-0000-0000-000000000094','favicon_32');
  assert jsonb_array_length(v_versions) = 1, format('une seule version attendue, reçu %s', v_versions);
  assert (v_versions->0->>'current')::boolean, format('elle doit être courante, reçu %s', v_versions);
  assert v_versions->0->>'change_summary' = '',
    format('une première version n''explique aucun changement, reçu %s', v_versions);
end
$$;

-- ---------------------------------------------------------------------------
-- Une refonte : la nouvelle empreinte devient courante, l'ancienne est
-- marquée dépassée, et la phrase voyage avec la NOUVELLE version -- c'est
-- elle que le changement a produite.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_versions jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000094"}';

  v := public.get_brand_asset_previous_inputs(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000002');
  assert v->'inputs'->'tokens'->>'primary' = '#B4653F',
    format('la refonte doit pouvoir lire les entrées d''avant, reçu %s', v);

  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000002',
    'cccccccc-0000-0000-0000-000000000094/aaaa000000000002/favicon_32.png', 950, 32, 32,
    0, '', 'Your primary color changed.', '{"tokens":{"primary":"#2E4E8A"}}'::jsonb);
  assert v ? 'id', format('la seconde version aurait dû être enregistrée, reçu %s', v);

  v_versions := public.get_brand_asset_versions('cccccccc-0000-0000-0000-000000000094','favicon_32');
  assert jsonb_array_length(v_versions) = 2, format('deux versions attendues, reçu %s', v_versions);
  assert v_versions->0->>'fingerprint' = 'aaaa000000000002',
    format('la plus récente vient en tête, reçu %s', v_versions);
  assert (v_versions->0->>'current')::boolean, format('la nouvelle est courante, reçu %s', v_versions);
  assert v_versions->0->>'change_summary' = 'Your primary color changed.',
    format('la phrase appartient à la version qu''elle a produite, reçu %s', v_versions);
  assert not (v_versions->1->>'current')::boolean,
    format('l''ancienne n''est plus courante, reçu %s', v_versions);
  assert v_versions->1->>'superseded_at' is not null,
    format('l''ancienne doit porter sa date de dépassement, reçu %s', v_versions);
end
$$;

-- ---------------------------------------------------------------------------
-- L'ancienne version reste téléchargeable : ses octets sont toujours là,
-- adressés par sa propre empreinte, et son compteur suit.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000094"}';

  v := public.get_brand_asset_version_path(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000001');
  assert v->>'storage_path' = 'cccccccc-0000-0000-0000-000000000094/aaaa000000000001/favicon_32.png',
    format('une version dépassée reste servie depuis ce qui a été stocké, reçu %s', v);

  v_count := public.record_asset_download(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000001');
  assert v_count = 1, format('le compteur suit la version reprise, reçu %s', v_count);

  v := public.get_brand_asset_version_path(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000009');
  assert v->'error'->>'code' = 'not_found',
    format('pas de ligne, pas de version -- rien n''est re-rendu, reçu %s', v);
end
$$;

-- ---------------------------------------------------------------------------
-- Elle remet la couleur d'avant : cette empreinte redevient la courante, et
-- il n'y a toujours qu'UNE version courante. C'est l'invariant que le
-- marquage en place pourrait le plus facilement casser.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_versions jsonb; v_current int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000094"}';

  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000001',
    'cccccccc-0000-0000-0000-000000000094/aaaa000000000001/favicon_32.png', 900, 32, 32,
    0, '', '', '{"tokens":{"primary":"#B4653F"}}'::jsonb);
  assert v ? 'id', format('le retour en arrière aurait dû être enregistré, reçu %s', v);

  v_versions := public.get_brand_asset_versions('cccccccc-0000-0000-0000-000000000094','favicon_32');
  assert jsonb_array_length(v_versions) = 2,
    format('revenir en arrière ne crée pas une troisième version, reçu %s', v_versions);
  select count(*) into v_current from jsonb_array_elements(v_versions) e
   where (e->>'current')::boolean;
  assert v_current = 1, format('%s version(s) courante(s) : %s', v_current, v_versions);
  assert (select e->>'fingerprint' from jsonb_array_elements(v_versions) e
           where (e->>'current')::boolean) = 'aaaa000000000001',
    format('c''est l''empreinte remise qui redevient courante, reçu %s', v_versions);
end
$$;

-- ---------------------------------------------------------------------------
-- Une largeur de plus n'est pas une version de plus.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb; v_versions jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000094"}';

  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000001',
    'cccccccc-0000-0000-0000-000000000094/aaaa000000000001/favicon_32@48.png', 1400, 48, 48,
    48, '', '', '{}'::jsonb);
  assert v ? 'id', format('la variante aurait dû être enregistrée, reçu %s', v);

  v_versions := public.get_brand_asset_versions('cccccccc-0000-0000-0000-000000000094','favicon_32');
  assert jsonb_array_length(v_versions) = 2,
    format('une largeur de plus n''est pas une version de plus : %s', v_versions);
end
$$;

-- ---------------------------------------------------------------------------
-- Rien de tout cela ne s'ouvre à une autre.
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000095"}';

  v := public.get_brand_asset_versions('cccccccc-0000-0000-0000-000000000094','favicon_32');
  assert v->'error'->>'code' = 'payment_required', format('versions : %s', v);
  v := public.get_brand_asset_version_path(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000001');
  assert v->'error'->>'code' = 'payment_required', format('chemin de version : %s', v);
  v := public.get_brand_asset_previous_inputs(
    'cccccccc-0000-0000-0000-000000000094','favicon_32','aaaa000000000002');
  assert v->'error'->>'code' = 'payment_required', format('entrées précédentes : %s', v);
end
$$;

rollback;
