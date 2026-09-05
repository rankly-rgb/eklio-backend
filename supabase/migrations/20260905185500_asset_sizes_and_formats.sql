-- ============================================================================
-- Eklio — sizes and formats on demand (post-purchase-v2, Lot 4)
-- ============================================================================
-- A rendition she asks for in another size or another format is STILL the
-- asset she already paid for. Nothing in this migration touches
-- `consume_generation_credit`, and nothing downstream of it may either:
-- re-rasterizing a vector she owns at 800px instead of 400px is not a
-- generation, it is the same file measured differently.
--
-- ── Where the variants come from ────────────────────────────────────────
-- Only the catalog rows whose SOURCE IS A VECTOR this repo can rebuild get
-- variants -- the monogram-icon family, the wordmark PNGs, the palette
-- sheet, the OG image. For those, a size is one more `svgToPngAtWidth`
-- pass over the same satori output, and `svg` is that output itself. Every
-- other row keeps empty arrays: no encoder in this repo produces webp or
-- jpeg, and offering a format we cannot make would be a menu entry that
-- fails on click.
--
-- ── Why the catalog validates the request, not the route ────────────────
-- `request_brand_asset_upload` refuses a size or format the catalog does
-- not list. That is the render-bomb guard: the route renders whatever it is
-- handed, so "40000" must be refused HERE, in the same place the paid check
-- already lives, not in a client that can be edited.
-- ============================================================================

alter table public.asset_catalog
  add column if not exists available_sizes   integer[] not null default '{}',
  add column if not exists available_formats text[]    not null default '{}';

comment on column public.asset_catalog.available_sizes is
  'Widths, in pixels, this asset can be re-rasterized to on demand. Empty means the one native rendition only. Every listed width must be reachable from a vector source the renderer can rebuild -- see lib/kit/render/variants.ts (eklio-frontend).';
comment on column public.asset_catalog.available_formats is
  'Formats this asset can be delivered in beyond its own `kind`. Empty means its kind only. Never lists a format this repo has no encoder for.';

-- ----------------------------------------------------------------------------
-- Which rows genuinely have variants, and why each list is what it is.
-- ----------------------------------------------------------------------------
update public.asset_catalog set available_sizes = '{16,32,48}',        available_formats = '{png,svg}' where key = 'favicon_16';
update public.asset_catalog set available_sizes = '{16,32,48}',        available_formats = '{png,svg}' where key = 'favicon_32';
update public.asset_catalog set available_sizes = '{120,152,167,180}', available_formats = '{png,svg}' where key = 'apple_touch_icon_180';
update public.asset_catalog set available_sizes = '{192,256,512,1024}',available_formats = '{png,svg}' where key = 'icon_512';
update public.asset_catalog set available_sizes = '{200,400,800,1000}',available_formats = '{png,svg}' where key = 'avatar_400';
update public.asset_catalog set available_sizes = '{600,1200,2400}',   available_formats = '{png,svg}' where key = 'wordmark_png_dark';
update public.asset_catalog set available_sizes = '{600,1200,2400}',   available_formats = '{png,svg}' where key = 'wordmark_png_light_1200';
update public.asset_catalog set available_sizes = '{600,1200,2400}',   available_formats = '{png,svg}' where key = 'wordmark_png_light_2400';
update public.asset_catalog set available_sizes = '{1200,2400}',       available_formats = '{png,svg}' where key = 'palette_sheet_png';
update public.asset_catalog set available_sizes = '{1200,2400}',       available_formats = '{png,svg}' where key = 'og_image_1200x630';

-- ----------------------------------------------------------------------------
-- brand_assets: one row per (kit, key, fingerprint, size, format).
--
-- 0 and '' are the NATIVE rendition -- the catalog row's own dimensions and
-- kind, the only thing that existed before this migration. Sentinels rather
-- than NULLs so the unique index and every ON CONFLICT below stay plain
-- column lists instead of coalesce() expressions.
-- ----------------------------------------------------------------------------
alter table public.brand_assets
  add column if not exists size   integer not null default 0,
  add column if not exists format text    not null default '';

comment on column public.brand_assets.size is
  '0 means the catalog row''s own native rendition. Any other value is a width this row was re-rasterized to on demand, under the SAME fingerprint as the native one.';
comment on column public.brand_assets.format is
  'Empty means the catalog row''s own `kind`. Any other value is an alternative format of the same rendition.';

-- `brand_assets_unique_render` is a unique CONSTRAINT, not a bare index
-- (20260903090000 declared it inline on the table), so it has to be dropped
-- as one -- `drop index` refuses, naming the constraint that owns it. It is
-- re-added as a constraint too, keeping the shape the table already had.
alter table public.brand_assets drop constraint if exists brand_assets_unique_render;
alter table public.brand_assets
  add constraint brand_assets_unique_render
  unique (brand_kit_id, key, fingerprint, size, format);

-- ----------------------------------------------------------------------------
-- asset_variant_path -- one definition of where a rendition lives, used by
-- both RPCs below so the "requested" path and the "recorded" path cannot
-- drift apart.
-- ----------------------------------------------------------------------------
create or replace function public.asset_variant_path(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text,
  p_kind text,
  p_size integer,
  p_format text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select format('%s/%s/%s%s.%s',
    p_brand_kit_id::text,
    p_fingerprint,
    p_key,
    case when coalesce(p_size, 0) = 0 then '' else '@' || p_size::text end,
    coalesce(nullif(p_format, ''), p_kind))
$$;

comment on function public.asset_variant_path(uuid, text, text, text, integer, text) is
  'The native rendition (size 0, format '''') resolves to exactly the path shape that existed before variants -- {kit}/{fingerprint}/{key}.{kind} -- so every already-stored object stays reachable.';

-- ----------------------------------------------------------------------------
-- request_brand_asset_upload -- now variant-aware.
--
-- Dropped and recreated rather than overloaded: an added parameter makes a
-- NEW function in Postgres, and two overloads of a PostgREST-exposed name
-- is an ambiguity waiting to be resolved wrongly. The defaults keep every
-- existing three-argument caller working unchanged.
-- ----------------------------------------------------------------------------
drop function if exists public.request_brand_asset_upload(uuid, text, text);

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

  -- Structural, not cryptographic: this only guards the fingerprint's use as
  -- a path segment (no '/', no traversal). It is not a check that the value
  -- is "the true current one" -- see the comment on get_brand_asset_manifest.
  if p_fingerprint !~ '^[0-9a-f]{16,128}$' then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_format',
      'message', 'Fingerprint must be a lowercase hex string.',
      'field', 'fingerprint'
    ));
  end if;

  -- THE RENDER-BOMB GUARD. The route renders whatever it is handed; only
  -- widths and formats the catalog itself offers may be asked for.
  if coalesce(p_size, 0) <> 0 and not (p_size = any (v_sizes)) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'That size is not offered for this asset.',
      'field', 'size'
    ));
  end if;

  if coalesce(p_format, '') <> '' and not (p_format = any (v_formats)) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'That format is not offered for this asset.',
      'field', 'format'
    ));
  end if;

  return jsonb_build_object(
    'bucket', 'brand-assets',
    'storage_path', public.asset_variant_path(
      p_brand_kit_id, p_key, p_fingerprint, v_kind, coalesce(p_size, 0), coalesce(p_format, ''))
  );
end;
$$;

revoke all on function public.request_brand_asset_upload(uuid, text, text, integer, text) from public, anon;
grant execute on function public.request_brand_asset_upload(uuid, text, text, integer, text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- record_brand_asset -- same widening, same path definition.
-- ----------------------------------------------------------------------------
drop function if exists public.record_brand_asset(uuid, text, text, text, integer, integer, integer);

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

  if coalesce(p_size, 0) <> 0 and not (p_size = any (v_sizes)) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'That size is not offered for this asset.',
      'field', 'size'
    ));
  end if;

  if coalesce(p_format, '') <> '' and not (p_format = any (v_formats)) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'That format is not offered for this asset.',
      'field', 'format'
    ));
  end if;

  v_expected_path := public.asset_variant_path(
    p_brand_kit_id, p_key, p_fingerprint, v_kind, coalesce(p_size, 0), coalesce(p_format, ''));

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
    p_storage_path, p_fingerprint, coalesce(p_size, 0), coalesce(p_format, '')
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

-- ----------------------------------------------------------------------------
-- get_brand_asset_manifest -- one row per catalog key, still. The join now
-- pins the NATIVE rendition (size 0, format '') so a kit with three cached
-- widths of its avatar doesn't report the avatar three times; the two new
-- catalog arrays ride along so the client can build the split button's menu
-- without a second round trip.
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
        'available_sizes', to_jsonb(c.available_sizes),
        'available_formats', to_jsonb(c.available_formats),
        'current', a.id is not null,
        'asset', case when a.id is null then null else
          jsonb_build_object(
            'storage_path', a.storage_path,
            'byte_size', a.byte_size,
            'created_at', a.created_at,
            -- The SUM across every cached rendition of this key, not this
            -- one row's column: downloading the 800px avatar is downloading
            -- the avatar. Counting only the native row would silently lose
            -- every variant download; counting per-row without summing here
            -- would report a number smaller than the truth.
            'download_count', coalesce((
              select sum(v.download_count)
                from public.brand_assets v
               where v.brand_kit_id = p_brand_kit_id
                 and v.key = c.key
                 and v.fingerprint = p_current_fingerprint
            ), 0)
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
     and a.size = 0
     and a.format = ''
  ), '[]'::jsonb);
end;
$$;

-- ----------------------------------------------------------------------------
-- record_asset_download -- counts the rendition actually handed over.
--
-- Two ways to get this wrong, both avoided here. Without the size/format
-- predicates the UPDATE would increment EVERY cached width at once the
-- moment variants started existing -- a number that looks measured and
-- isn't. Pinning it to the native row instead would drop every variant
-- download on the floor, and would count nothing at all for a kit whose
-- 800px avatar was rendered before its 400px one ever was. So each row
-- counts its own, and `get_brand_asset_manifest` sums them per key.
-- ----------------------------------------------------------------------------
drop function if exists public.record_asset_download(uuid, text, text);

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
     and size = coalesce(p_size, 0)
     and format = coalesce(p_format, '')
  returning download_count into v_count;

  return v_count;
end;
$$;

revoke all on function public.record_asset_download(uuid, text, text, integer, text) from public, anon;
grant execute on function public.record_asset_download(uuid, text, text, integer, text) to authenticated, service_role;
