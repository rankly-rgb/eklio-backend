-- ============================================================================
-- Tests — 20260905185500_asset_sizes_and_formats.sql
--
-- Une taille qu'elle a déjà payée, rendue à une autre largeur, n'est pas une
-- nouvelle génération : c'est le même rendu, sous la même empreinte. Ces
-- tests fixent les deux choses qui rendent cela sûr côté base :
--   1. le chemin natif reste EXACTEMENT ce qu'il était avant les variantes,
--      donc rien de déjà stocké ne devient injoignable ;
--   2. une taille ou un format non listés au catalogue sont refusés dans les
--      RPC elles-mêmes -- pas dans une route que l'on peut réécrire.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000091','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000092','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000091','aaaaaaaa-0000-0000-0000-000000000091','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000091','bbbbbbbb-0000-0000-0000-000000000091');
insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-000000000091','bbbbbbbb-0000-0000-0000-000000000091',
        'starter','cs_test_91',7900,'paid',now());

-- ---------------------------------------------------------------------------
-- Le catalogue n'offre une taille que là où ce dépôt sait la reconstruire.
-- `business_card_front` ne rend qu'un Buffer, sans source vectorielle
-- ré-rasterisable : ses tableaux restent vides, et c'est délibéré.
-- ---------------------------------------------------------------------------
do $$
declare
  v_sizes   integer[];
  v_formats text[];
begin
  select available_sizes, available_formats into v_sizes, v_formats
    from public.asset_catalog where key = 'favicon_32';
  assert v_sizes = '{16,32,48}'::integer[],
    format('favicon_32 devrait offrir 16/32/48, trouvé %s', v_sizes);
  assert v_formats = '{png,svg}'::text[],
    format('favicon_32 devrait offrir png et svg, trouvé %s', v_formats);

  select available_sizes, available_formats into v_sizes, v_formats
    from public.asset_catalog where key = 'business_card_front';
  assert cardinality(v_sizes) = 0 and cardinality(v_formats) = 0,
    'business_card_front n''a pas de source vectorielle : il ne doit rien offrir';

  -- Aucune ligne ne doit annoncer un format sans encodeur dans ce dépôt.
  assert not exists (
    select 1 from public.asset_catalog, unnest(available_formats) f
     where f not in ('png','svg')
  ), 'un format annoncé sans encodeur serait une entrée de menu qui échoue au clic';
end
$$;

-- ---------------------------------------------------------------------------
-- Le chemin natif (size 0, format '') est identique au chemin d'avant les
-- variantes. C'est la garantie que rien de déjà stocké ne devient orphelin.
-- ---------------------------------------------------------------------------
do $$
declare
  v_native  text;
  v_variant text;
  v_svg     text;
begin
  v_native := public.asset_variant_path(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef','png', 0, '');
  assert v_native = 'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32.png',
    format('le chemin natif a changé de forme : %s', v_native);

  v_variant := public.asset_variant_path(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef','png', 48, '');
  assert v_variant = 'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32@48.png',
    format('chemin de variante inattendu : %s', v_variant);

  v_svg := public.asset_variant_path(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef','png', 0, 'svg');
  assert v_svg = 'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32.svg',
    format('chemin de format alternatif inattendu : %s', v_svg);

  -- Une variante ne doit jamais pouvoir écraser le natif.
  assert v_native <> v_variant and v_native <> v_svg,
    'une variante partage le chemin du natif : elle l''écraserait au stockage';
end
$$;

-- ---------------------------------------------------------------------------
-- request_brand_asset_upload : le garde-fou anti-bombe-de-rendu. Une taille
-- ou un format hors catalogue sont refusés ICI, là où vit déjà le contrôle
-- de paiement -- pas dans un client que l'on peut éditer.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000091"}';

  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef');
  assert v->>'storage_path' = 'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32.png',
    format('l''appel à trois arguments doit rester le natif, reçu %s', v);

  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef', 48, '');
  assert v->>'storage_path' = 'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32@48.png',
    format('une taille offerte doit être acceptée, reçu %s', v);

  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef', 9999, '');
  assert v->'error'->>'code' = 'invalid_field' and v->'error'->>'field' = 'size',
    format('une taille hors catalogue doit être refusée, reçu %s', v);

  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef', 0, 'webp');
  assert v->'error'->>'code' = 'invalid_field' and v->'error'->>'field' = 'format',
    format('un format sans encodeur doit être refusé, reçu %s', v);

  -- Une clé dont le catalogue n'offre rien ne peut recevoir aucune variante.
  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000091','business_card_front','0123456789abcdef', 600, '');
  assert v->'error'->>'code' = 'invalid_field',
    format('une clé sans source vectorielle ne doit offrir aucune taille, reçu %s', v);
end
$$;

-- ---------------------------------------------------------------------------
-- record_brand_asset : natif et variante coexistent sous LA MÊME empreinte.
-- C'est tout l'objet du lot : une largeur de plus n'est pas une refonte.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_rows int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000091"}';

  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef',
    'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32.png', 900, 32, 32);
  assert v ? 'id', format('le natif aurait dû être enregistré, reçu %s', v);

  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef',
    'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32@48.png', 1400, 48, 48, 48, '');
  assert v ? 'id', format('la variante aurait dû être enregistrée, reçu %s', v);

  select count(*) into v_rows from public.brand_assets
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000091'
     and key = 'favicon_32' and fingerprint = '0123456789abcdef';
  assert v_rows = 2,
    format('natif et variante doivent coexister sous la même empreinte, %s ligne(s)', v_rows);

  -- Un chemin qui ne correspond pas à la taille demandée est refusé : sans
  -- cela, une variante pourrait être écrite à la place du natif.
  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef',
    'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32.png', 1400, 48, 48, 48, '');
  assert v->'error'->>'field' = 'storage_path',
    format('un chemin incohérent avec la taille doit être refusé, reçu %s', v);

  -- Et le garde-fou du catalogue vaut aussi à l'enregistrement, pas seulement
  -- à la demande d'URL signée.
  v := public.record_brand_asset(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef',
    'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32@9999.png', 1400, 9999, 9999, 9999, '');
  assert v->'error'->>'field' = 'size',
    format('une taille hors catalogue doit être refusée à l''enregistrement, reçu %s', v);
end
$$;

-- ---------------------------------------------------------------------------
-- record_asset_download incrémente EXACTEMENT le rendu remis, pas toutes les
-- largeurs en cache d'un coup.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count  int;
  v_native int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000091"}';

  v_count := public.record_asset_download(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef', 48, '');
  assert v_count = 1, format('la variante 48 devrait être à 1, trouvé %s', v_count);

  select download_count into v_native from public.brand_assets
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000091'
     and key = 'favicon_32' and fingerprint = '0123456789abcdef' and size = 0 and format = '';
  assert v_native = 0,
    format('le natif ne devait pas bouger quand c''est la variante qu''elle a prise, trouvé %s', v_native);
end
$$;

-- ---------------------------------------------------------------------------
-- Le manifeste reste UNE ligne par clé -- il se joint au natif seul -- mais
-- son compteur de téléchargements additionne toutes les largeurs, sinon un
-- fichier repris trois fois en 48 px se lirait « jamais téléchargé ».
-- ---------------------------------------------------------------------------
do $$
declare
  v_manifest jsonb;
  v_entry    jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000091"}';

  v_manifest := public.get_brand_asset_manifest('cccccccc-0000-0000-0000-000000000091','0123456789abcdef');

  assert (select count(*) from jsonb_array_elements(v_manifest) e
           where e->>'key' = 'favicon_32') = 1,
    'le manifeste doit rester à une ligne par clé, quelles que soient les variantes en cache';

  select e into v_entry from jsonb_array_elements(v_manifest) e where e->>'key' = 'favicon_32';

  assert (v_entry->>'current')::boolean,
    format('favicon_32 devrait être marqué courant, reçu %s', v_entry);
  assert v_entry->'available_sizes' = '[16,32,48]'::jsonb,
    format('le manifeste doit porter les tailles offertes, reçu %s', v_entry->'available_sizes');
  assert v_entry->'available_formats' = '["png","svg"]'::jsonb,
    format('le manifeste doit porter les formats offerts, reçu %s', v_entry->'available_formats');
  assert (v_entry->'asset'->>'download_count')::int = 1,
    format('le compteur doit additionner les rendus, reçu %s', v_entry->'asset'->>'download_count');
  assert v_entry->'asset'->>'storage_path' = 'cccccccc-0000-0000-0000-000000000091/0123456789abcdef/favicon_32.png',
    format('le manifeste doit pointer le natif, pas une variante, reçu %s', v_entry->'asset');
end
$$;

-- ---------------------------------------------------------------------------
-- Rien de tout cela n'ouvre le kit d'une autre : les variantes n'ajoutent
-- aucun chemin qui contourne `brand_kit_entitled`.
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000092"}';

  v := public.request_brand_asset_upload(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef', 48, '');
  assert v->'error'->>'code' = 'payment_required',
    format('une inconnue ne doit pas obtenir de chemin d''écriture, reçu %s', v);

  v_count := public.record_asset_download(
    'cccccccc-0000-0000-0000-000000000091','favicon_32','0123456789abcdef', 48, '');
  assert v_count is null,
    format('une inconnue ne doit rien pouvoir incrémenter, reçu %s', v_count);

  assert (select count(*) from public.brand_assets
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000091') = 0,
    'RLS : les rendus d''une autre thérapeute ne sont pas lisibles';
end
$$;

rollback;
