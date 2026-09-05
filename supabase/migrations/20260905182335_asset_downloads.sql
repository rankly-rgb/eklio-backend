-- ============================================================================
-- Eklio — asset download tracking (post-purchase-v2, Lot 4: asset library)
-- ============================================================================
-- The asset library needs three real numbers this schema cannot currently
-- produce: total downloads, downloads per asset, and a "Most downloaded"
-- sort. `brand_assets.download_count`, incremented by one new RPC,
-- `record_asset_download`, called once a signed URL has actually been
-- handed to her -- on a cache hit AND after a fresh render, both of which
-- mean she is about to receive the file. This is a DOWNLOAD count, never a
-- generation count: it never touches `consume_generation_credit`, and
-- incrementing it is not itself a render (no bytes are touched).
-- ============================================================================

alter table public.brand_assets
  add column if not exists download_count integer not null default 0;

comment on column public.brand_assets.download_count is
  'Incremented by record_asset_download every time a signed URL for this exact (brand_kit_id, key, fingerprint) row is issued -- cache hit or fresh render alike. Never touched by rendering itself.';

create or replace function public.record_asset_download(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return null;
  end if;

  update public.brand_assets
     set download_count = download_count + 1
   where brand_kit_id = p_brand_kit_id
     and key = p_key
     and fingerprint = p_fingerprint
  returning download_count into v_count;

  return v_count;
end;
$$;

revoke all on function public.record_asset_download(uuid, text, text) from public, anon;
grant execute on function public.record_asset_download(uuid, text, text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- get_brand_asset_manifest: surface download_count alongside the rest.
-- ----------------------------------------------------------------------------
create or replace function public.get_brand_asset_manifest(
  p_brand_kit_id uuid,
  p_current_fingerprint text
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
        'key', c.key,
        'group', c."group",
        'label', c.label,
        'description', c.description,
        'kind', c.kind,
        'width', c.width,
        'height', c.height,
        'min_tier', c.min_tier,
        'current', a.id is not null,
        'asset', case when a.id is null then null else
          jsonb_build_object(
            'storage_path', a.storage_path,
            'byte_size', a.byte_size,
            'created_at', a.created_at,
            'download_count', a.download_count
          )
        end
      )
      order by c.sort_order
    )
    from public.asset_catalog c
    left join public.brand_assets a
      on a.brand_kit_id = p_brand_kit_id
     and a.key = c.key
     and a.fingerprint = p_current_fingerprint
  ), '[]'::jsonb);
end;
$$;
