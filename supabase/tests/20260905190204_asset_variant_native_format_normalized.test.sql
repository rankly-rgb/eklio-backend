-- ============================================================================
-- Tests — 20260905190204_asset_variant_native_format_normalized.sql
--
-- Un objet en stockage, une ligne. Choisir « PNG » dans le menu d'un asset
-- dont le kind EST déjà png ne doit pas créer un doublon qui pointe sur le
-- même fichier que le natif.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000093','owner@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000093','aaaaaaaa-0000-0000-0000-000000000093','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000093','bbbbbbbb-0000-0000-0000-000000000093');
insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-000000000093','bbbbbbbb-0000-0000-0000-000000000093',
        'starter','cs_test_93',7900,'paid',now());

-- ---------------------------------------------------------------------------
-- Le format natif demandé par son nom revient au rendu natif -- même chemin,
-- même ligne, et la réponse le dit en clair (`format` vidé) pour que
-- l'appelant enregistre et compte la même chose.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_rows int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000093"}';

  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000093','favicon_32','0123456789abcdef', 0, 'png');
  assert v->>'storage_path' = 'cccccccc-0000-0000-0000-000000000093/0123456789abcdef/favicon_32.png',
    format('« png » sur un asset png doit rendre le chemin natif, reçu %s', v);
  assert v->>'format' = '',
    format('la réponse doit annoncer le format normalisé, reçu %s', v);
  assert (v->>'size')::int = 0,
    format('la réponse doit annoncer la taille retenue, reçu %s', v);

  -- Enregistré deux fois, une fois sans format et une fois en le nommant :
  -- une seule ligne doit exister au bout.
  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000093','favicon_32','0123456789abcdef',
    'cccccccc-0000-0000-0000-000000000093/0123456789abcdef/favicon_32.png', 900, 32, 32);
  assert v ? 'id', format('le natif aurait dû être enregistré, reçu %s', v);

  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000093','favicon_32','0123456789abcdef',
    'cccccccc-0000-0000-0000-000000000093/0123456789abcdef/favicon_32.png', 900, 32, 32, 0, 'png');
  assert v ? 'id', format('le même rendu, nommé « png », aurait dû être accepté, reçu %s', v);

  select count(*) into v_rows from public.brand_assets
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000093' and key = 'favicon_32';
  assert v_rows = 1,
    format('un objet en stockage, une ligne : %s ligne(s) pour le même fichier', v_rows);
end
$$;

-- ---------------------------------------------------------------------------
-- Et le compteur suit la même normalisation : téléchargé en nommant « png »,
-- c'est la ligne native qui s'incrémente, pas rien du tout.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000093"}';

  v_count := public.record_asset_download(
    'cccccccc-0000-0000-0000-000000000093','favicon_32','0123456789abcdef', 0, 'png');
  assert v_count = 1,
    format('« png » doit incrémenter la ligne native, reçu %s', v_count);
end
$$;

-- ---------------------------------------------------------------------------
-- La normalisation ne relâche pas le garde-fou : elle vient APRÈS lui. Un
-- asset qui n'offre aucun format n'accepte pas son propre kind par la bande,
-- et un format hors catalogue reste refusé.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000093"}';

  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000093','business_card_front','0123456789abcdef', 0, 'png');
  assert v->'error'->>'field' = 'format',
    format('un asset sans formats offerts ne doit pas accepter son propre kind, reçu %s', v);

  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000093','favicon_32','0123456789abcdef', 0, 'webp');
  assert v->'error'->>'field' = 'format',
    format('un format hors catalogue reste refusé, reçu %s', v);

  -- Un vrai format alternatif garde bien son chemin distinct.
  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000093','favicon_32','0123456789abcdef', 0, 'svg');
  assert v->>'storage_path' = 'cccccccc-0000-0000-0000-000000000093/0123456789abcdef/favicon_32.svg',
    format('svg doit rester un chemin distinct, reçu %s', v);
  assert v->>'format' = 'svg',
    format('svg ne doit pas être normalisé, reçu %s', v);
end
$$;

rollback;
