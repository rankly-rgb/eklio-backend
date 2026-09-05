-- ============================================================================
-- Le format natif, demandé par son nom, reste le rendu natif
--
-- `available_formats` liste ce que le menu propose, et pour chacune des dix
-- lignes semées ce menu commence naturellement par le `kind` de l'asset
-- lui-même (« PNG / SVG »). Tel quel, demander le format 'png' d'un asset
-- de kind 'png' résolvait vers le chemin natif tout en enregistrant une
-- SECONDE ligne clée ('', 'png') : deux lignes, un seul objet en stockage.
--
-- Normaliser le kind vers '' à l'entrée fait du rendu natif la ligne unique
-- qu'il a toujours été, qu'elle soit arrivée par le bouton simple ou en
-- choisissant « PNG » dans le menu. Le garde-fou du catalogue reste devant :
-- un format non listé est toujours refusé, et il est refusé AVANT cette
-- normalisation, pour qu'un asset qui n'offre rien n'accepte pas son propre
-- kind par la bande.
-- ============================================================================

create or replace function public.request_brand_asset_upload(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text,
  p_size integer default 0,
  p_format text default ''
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_kind    text;
  v_sizes   integer[];
  v_formats text[];
  v_size    integer := coalesce(p_size, 0);
  v_format  text    := coalesce(p_format, '');
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  select kind, available_sizes, available_formats
    into v_kind, v_sizes, v_formats
    from public.asset_catalog where key = p_key;
  if v_kind is null then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such asset key in the catalog.'
    ));
  end if;

  if p_fingerprint !~ '^[0-9a-f]{16,128}$' then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_format',
      'message', 'Fingerprint must be a lowercase hex string.',
      'field', 'fingerprint'
    ));
  end if;

  if v_size <> 0 and not (v_size = any (v_sizes)) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'That size is not offered for this asset.',
      'field', 'size'
    ));
  end if;

  if v_format <> '' and not (v_format = any (v_formats)) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'That format is not offered for this asset.',
      'field', 'format'
    ));
  end if;

  if v_format = v_kind then
    v_format := '';
  end if;

  return jsonb_build_object(
    'bucket', 'brand-assets',
    'size', v_size,
    'format', v_format,
    'storage_path', public.asset_variant_path(
      p_brand_kit_id, p_key, p_fingerprint, v_kind, v_size, v_format)
  );
end;
$$;

revoke all on function public.request_brand_asset_upload(uuid, text, text, integer, text) from public, anon;
grant execute on function public.request_brand_asset_upload(uuid, text, text, integer, text) to authenticated, service_role;

create or replace function public.record_brand_asset(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text,
  p_storage_path text,
  p_byte_size integer,
  p_width integer default null,
  p_height integer default null,
  p_size integer default 0,
  p_format text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind          text;
  v_sizes         integer[];
  v_formats       text[];
  v_size          integer := coalesce(p_size, 0);
  v_format        text    := coalesce(p_format, '');
  v_expected_path text;
  v_id            uuid;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  select kind, available_sizes, available_formats
    into v_kind, v_sizes, v_formats
    from public.asset_catalog where key = p_key;
  if v_kind is null then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such asset key in the catalog.'
    ));
  end if;

  if p_fingerprint !~ '^[0-9a-f]{16,128}$' then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_format',
      'message', 'Fingerprint must be a lowercase hex string.',
      'field', 'fingerprint'
    ));
  end if;

  if v_size <> 0 and not (v_size = any (v_sizes)) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'That size is not offered for this asset.',
      'field', 'size'
    ));
  end if;

  if v_format <> '' and not (v_format = any (v_formats)) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'That format is not offered for this asset.',
      'field', 'format'
    ));
  end if;

  if v_format = v_kind then
    v_format := '';
  end if;

  v_expected_path := public.asset_variant_path(
    p_brand_kit_id, p_key, p_fingerprint, v_kind, v_size, v_format);

  if p_storage_path <> v_expected_path then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'Storage path does not match this kit, fingerprint, key, size, and format.',
      'field', 'storage_path'
    ));
  end if;

  if p_byte_size is null or p_byte_size <= 0 then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'byte_size must be a positive integer.',
      'field', 'byte_size'
    ));
  end if;

  insert into public.brand_assets (
    brand_kit_id, user_id, key, kind, width, height, byte_size, storage_path, fingerprint,
    size, format
  )
  values (
    p_brand_kit_id, (select auth.uid()), p_key, v_kind, p_width, p_height, p_byte_size,
    p_storage_path, p_fingerprint, v_size, v_format
  )
  on conflict (brand_kit_id, key, fingerprint, size, format)
  do update set
    storage_path = excluded.storage_path,
    width         = excluded.width,
    height        = excluded.height,
    byte_size     = excluded.byte_size
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'storage_path', p_storage_path);
end;
$$;

revoke all on function public.record_brand_asset(uuid, text, text, text, integer, integer, integer, integer, text) from public, anon;
grant execute on function public.record_brand_asset(uuid, text, text, text, integer, integer, integer, integer, text) to authenticated, service_role;

create or replace function public.record_asset_download(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text,
  p_size integer default 0,
  p_format text default ''
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind   text;
  v_size   integer := coalesce(p_size, 0);
  v_format text    := coalesce(p_format, '');
  v_count  integer;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return null;
  end if;

  select kind into v_kind from public.asset_catalog where key = p_key;
  if v_format = v_kind then
    v_format := '';
  end if;

  update public.brand_assets
     set download_count = download_count + 1
   where brand_kit_id = p_brand_kit_id
     and key = p_key
     and fingerprint = p_fingerprint
     and size = v_size
     and format = v_format
  returning download_count into v_count;

  return v_count;
end;
$$;

revoke all on function public.record_asset_download(uuid, text, text, integer, text) from public, anon;
grant execute on function public.record_asset_download(uuid, text, text, integer, text) to authenticated, service_role;
