-- ============================================================================
-- Historique des versions d'un asset
--
-- L'historique existe DÉJÀ : `brand_assets` est adressé par empreinte, et une
-- refonte n'écrase rien -- elle ajoute une ligne sous une nouvelle empreinte.
-- Ce lot ne crée donc pas un historique, il le rend lisible : quelle version
-- est la sienne aujourd'hui (`superseded_at is null`), et en une phrase ce qui
-- a changé pour produire chacune (`change_summary`).
--
-- ⚠ `fingerprint_inputs` N'ENTRE PAS DANS LE CALCUL DE L'EMPREINTE et ne le
-- fera jamais. `computeAssetFingerprint` (eklio-frontend,
-- lib/kit/asset-fingerprint.ts) reste la définition unique de ce hachage ; en
-- écrire une seconde ici, fût-ce pour « vérifier », créerait deux
-- implémentations qui divergent. Cette colonne ne fait que CONSERVER les
-- entrées telles quelles, pour que la refonte suivante puisse dire ce qui a
-- bougé.
-- ============================================================================

alter table public.brand_assets
  add column if not exists superseded_at      timestamptz,
  add column if not exists change_summary     text  not null default '',
  add column if not exists fingerprint_inputs jsonb not null default '{}'::jsonb;

comment on column public.brand_assets.superseded_at is
  'NULL means this fingerprint is the newest one rendered for this key -- the version she has now. Set the moment a row under a different fingerprint is recorded for the same key, and cleared again if that same fingerprint comes back (she reverted a colour). Never a retention clock on its own.';
comment on column public.brand_assets.change_summary is
  'One plain sentence naming what changed to cause THIS version, written by the rebuild path from the diff between the previous version''s fingerprint_inputs and the current ones. Empty on a first version -- there was nothing to change from.';
comment on column public.brand_assets.fingerprint_inputs is
  'The inputs the fingerprint was computed FROM, recorded verbatim so the next rebuild can say what moved. This does NOT participate in computing the fingerprint and never may -- computeAssetFingerprint (eklio-frontend, lib/kit/asset-fingerprint.ts) is the single definition of that hash, and a second one here would drift.';

create index if not exists brand_assets_version_history_idx
  on public.brand_assets (brand_kit_id, key, created_at desc);

-- ---------------------------------------------------------------------------
-- record_brand_asset : c'est l'enregistrement du fichier qui décide de la
-- version courante, jamais un drapeau passé par l'appelant.
-- ---------------------------------------------------------------------------
drop function if exists public.record_brand_asset(uuid, text, text, text, integer, integer, integer, integer, text);

create or replace function public.record_brand_asset(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text,
  p_storage_path text,
  p_byte_size integer,
  p_width integer default null,
  p_height integer default null,
  p_size integer default 0,
  p_format text default '',
  p_change_summary text default '',
  p_fingerprint_inputs jsonb default '{}'::jsonb
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
    size, format, change_summary, fingerprint_inputs
  )
  values (
    p_brand_kit_id, (select auth.uid()), p_key, v_kind, p_width, p_height, p_byte_size,
    p_storage_path, p_fingerprint, v_size, v_format,
    coalesce(p_change_summary, ''), coalesce(p_fingerprint_inputs, '{}'::jsonb)
  )
  on conflict (brand_kit_id, key, fingerprint, size, format)
  do update set
    storage_path = excluded.storage_path,
    width         = excluded.width,
    height        = excluded.height,
    byte_size     = excluded.byte_size
  returning id into v_id;

  -- The version this key is on is decided here, in the same statement pair
  -- that stores the file -- never by a caller passing a flag. Recording a
  -- fingerprint makes it the current one and every OTHER fingerprint for
  -- this key superseded; recording a fingerprint that was superseded before
  -- (she put a colour back) makes it current again.
  update public.brand_assets
     set superseded_at = null
   where brand_kit_id = p_brand_kit_id
     and key = p_key
     and fingerprint = p_fingerprint
     and superseded_at is not null;

  update public.brand_assets
     set superseded_at = now()
   where brand_kit_id = p_brand_kit_id
     and key = p_key
     and fingerprint <> p_fingerprint
     and superseded_at is null;

  return jsonb_build_object('id', v_id, 'storage_path', p_storage_path);
end;
$$;

revoke all on function public.record_brand_asset(uuid, text, text, text, integer, integer, integer, integer, text, text, jsonb) from public, anon;
grant execute on function public.record_brand_asset(uuid, text, text, text, integer, integer, integer, integer, text, text, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Lire l'historique, et servir une version ancienne.
-- ---------------------------------------------------------------------------
create or replace function public.get_brand_asset_versions(
  p_brand_kit_id uuid,
  p_key text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'fingerprint', a.fingerprint,
        'created_at', a.created_at,
        'superseded_at', a.superseded_at,
        'change_summary', a.change_summary,
        'byte_size', a.byte_size,
        'download_count', a.download_count,
        'current', a.superseded_at is null
      )
      order by a.created_at desc
    )
    from public.brand_assets a
    where a.brand_kit_id = p_brand_kit_id
      and a.key = p_key
      -- One entry per version, not one per width she happened to ask for:
      -- the variants of a version are the same rendering as its native row.
      and a.size = 0
      and a.format = ''
  ), '[]'::jsonb);
end;
$$;

comment on function public.get_brand_asset_versions(uuid, text) is
  'Every version of one asset, newest first, with the sentence that explains each. Older versions stay downloadable -- their bytes are still in storage, addressed by their own fingerprint.';

revoke all on function public.get_brand_asset_versions(uuid, text) from public, anon;
grant execute on function public.get_brand_asset_versions(uuid, text) to authenticated, service_role;

create or replace function public.get_brand_asset_version_path(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_path text;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  select storage_path into v_path
    from public.brand_assets
   where brand_kit_id = p_brand_kit_id
     and key = p_key
     and fingerprint = p_fingerprint
     and size = 0
     and format = '';

  -- An older version is served from what was stored, never re-rendered: the
  -- inputs that produced it are gone by definition. No row, no version.
  if v_path is null then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such version of this asset.'
    ));
  end if;

  return jsonb_build_object('storage_path', v_path);
end;
$$;

revoke all on function public.get_brand_asset_version_path(uuid, text, text) from public, anon;
grant execute on function public.get_brand_asset_version_path(uuid, text, text) to authenticated, service_role;

create or replace function public.get_brand_asset_previous_inputs(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_inputs jsonb;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  select fingerprint_inputs into v_inputs
    from public.brand_assets
   where brand_kit_id = p_brand_kit_id
     and key = p_key
     and fingerprint <> p_fingerprint
     and size = 0
     and format = ''
   order by created_at desc
   limit 1;

  return jsonb_build_object('inputs', coalesce(v_inputs, '{}'::jsonb));
end;
$$;

comment on function public.get_brand_asset_previous_inputs(uuid, text, text) is
  'The inputs behind the version this rebuild is about to replace, so the rebuild path can say in one sentence what moved. Empty object when there is no previous version -- a first render has nothing to diff against.';

revoke all on function public.get_brand_asset_previous_inputs(uuid, text, text) from public, anon;
grant execute on function public.get_brand_asset_previous_inputs(uuid, text, text) to authenticated, service_role;
