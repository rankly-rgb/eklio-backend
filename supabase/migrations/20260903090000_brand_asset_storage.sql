-- ============================================================================
-- Eklio — brand_assets, asset_catalog, and the two storage buckets that back
-- them (Lot 4.1–4.3 of the post-purchase chantier)
-- ============================================================================
-- Every rendered brand asset (a wordmark SVG, a social template PNG, …) is a
-- row in `brand_assets` plus one object in the private `brand-assets`
-- bucket. `asset_catalog` is the fixed, DB-authored list of what can exist —
-- this migration seeds exactly one row, `wordmark_svg_dark`; the rest of the
-- catalogue arrives in Lot 4.4/4.5, not here.
--
-- THE SECURITY BOUNDARY IS NOT WHERE THE BRIEF FIRST PUT IT
-- -----------------------------------------------------------
-- The brief specified `request_brand_asset_upload` as an RPC that returns a
-- signed Storage upload URL directly. That mechanism does not exist:
-- Supabase Storage's `createSignedUploadUrl` / `createSignedUrl` are calls
-- against the separate Storage HTTP service, and nothing in `storage.*` or
-- any installed extension can mint that signature from inside Postgres.
--
-- So the split actually used is:
--   - RLS policies on `storage.objects`, below, are the real security
--     boundary. They are what actually authorizes a read or a write, and
--     they hold even against a caller who never calls any RPC in this file
--     and drives `createSignedUploadUrl`/`createSignedUrl` directly — see
--     this migration's paired test.
--   - The three RPCs (§3) are validation and path-construction, not
--     authorization. They exist so eklio-frontend never hand-builds a
--     storage path or trusts an unchecked one, and so `brand_assets` (whose
--     own RLS has no client INSERT policy — see §1) gets a row at all. Each
--     one still checks `brand_kit_entitled` and returns the contract's
--     `payment_required` shape on refusal, because refusing early with a
--     clear reason is simply better behaviour than relying on the RLS
--     refusal downstream to do that job silently — but that check is a
--     courtesy, not the boundary. Removing it would not open anything the
--     storage policies don't already close.
--
-- FOUR THINGS THIS SCHEMA IS DELIBERATELY SHAPED AROUND
-- ---------------------------------------------------------
-- 1. A crafted object name can put anything in its first path segment. The
--    policy helper (§2) checks that segment against a UUID-shaped regex
--    BEFORE casting it to `uuid` — a bad cast inside a policy raises an
--    exception, which PostgREST/Storage surfaces as an error, not as a
--    quiet denial. Failing the regex returns `false` instead, which RLS
--    fails closed on exactly like any other unmatched row.
-- 2. Re-rendering the same fingerprint targets the same object path
--    (`{kit}/{fingerprint}/{key}.{ext}`). An insert-only policy would make
--    that opaque 409/403 the day the renderer needs to overwrite one — so
--    the storage policy below grants UPDATE on the same path condition too,
--    and the frontend's upload call is expected to pass `upsert: true`.
--    `record_brand_asset` (§3.3) does the matching `ON CONFLICT` on the
--    metadata row, so both halves of a re-render are idempotent.
-- 3. There is no DELETE policy on `storage.objects` for this bucket, on
--    purpose. Nothing a client session does may remove a rendered asset;
--    cleaning up superseded fingerprints is a `service_role` housekeeping
--    concern (bypasses RLS already), not something this migration builds.
-- 4. The policy helper authorizes by the PATH's `brand_kit_id` segment, not
--    by `storage.objects.owner`. A kit outlives the session that rendered
--    its first asset, and `owner` is set at upload time by whichever
--    session happened to be live then — trusting it would make a kit's own
--    assets unreadable to a later session that re-authenticates.
-- ============================================================================


-- ============================================================================
-- 1. asset_catalog — the fixed list of what can exist, DB-authored
-- ============================================================================
-- Created before brand_assets: brand_assets.key is a foreign key into it.
create table public.asset_catalog (
  key         text    not null,
  "group"     text    not null,
  label       text    not null,
  description text    not null,
  kind        text    not null,
  width       integer,
  height      integer,
  min_tier    text    not null default 'starter',
  sort_order  integer not null default 0,
  constraint asset_catalog_pkey primary key (key),
  constraint asset_catalog_kind_check check (kind in ('svg', 'png')),
  -- Mirrors KIT_TIERS in eklio-frontend's lib/kit/tiers.ts. When min_tier
  -- gating is actually enforced (Lot 4.4/4.5 — this lot's one seeded row is
  -- the lowest tier, so nothing gates yet), the comparison is against
  -- resolveEntitledTier() in eklio-frontend, never against brand_kits.tier:
  -- the former is the practitioner's current purchased entitlement, the
  -- latter a frozen snapshot of what a past purchase delivered.
  constraint asset_catalog_min_tier_check check (min_tier in ('starter', 'practice', 'signature'))
);

comment on table public.asset_catalog is
  'The fixed catalogue of renderable brand assets. Reference data: written only by migrations, read by every authenticated caller (min_tier gating, when it exists, happens in eklio-frontend against the caller''s current entitled tier, not here). Lot 4.1–4.3 seeds only wordmark_svg_dark; the rest of the catalogue is Lot 4.4/4.5.';

alter table public.asset_catalog enable row level security;

-- No INSERT/UPDATE/DELETE policy for anyone but the table owner (migrations)
-- on purpose — this is reference data, not user data.
create policy "asset_catalog_select_all"
  on public.asset_catalog
  for select
  to authenticated
  using (true);

insert into public.asset_catalog (key, "group", label, description, kind, width, height, min_tier, sort_order)
values (
  'wordmark_svg_dark',
  'identity',
  'Wordmark (dark)',
  'Your practice name, set in your heading font, ink-dark, as a vector file — the one to hand to a printer.',
  'svg',
  null,
  null,
  'starter',
  1
);


-- ============================================================================
-- 2. brand_assets — one row per rendered (brand_kit, key, fingerprint)
-- ============================================================================
create table public.brand_assets (
  id             uuid        not null default gen_random_uuid(),
  brand_kit_id   uuid        not null,
  user_id        uuid        not null,
  key            text        not null,
  kind           text        not null,
  width          integer,
  height         integer,
  byte_size      integer     not null,
  storage_path   text        not null,
  fingerprint    text        not null,
  created_at     timestamptz not null default now(),
  constraint brand_assets_pkey primary key (id),
  constraint brand_assets_brand_kit_id_fkey foreign key (brand_kit_id)
    references public.brand_kits (id) on delete cascade,
  constraint brand_assets_user_id_fkey foreign key (user_id)
    references auth.users (id) on delete cascade,
  constraint brand_assets_key_fkey foreign key (key)
    references public.asset_catalog (key),
  constraint brand_assets_kind_check check (kind in ('svg', 'png')),
  constraint brand_assets_unique_render unique (brand_kit_id, key, fingerprint)
);

comment on table public.brand_assets is
  'One row per rendered brand asset. `fingerprint` is a single hash covering everything that could change any asset''s pixels (colours, fonts, copy, RENDERER_VERSION — computed by eklio-frontend, not recomputed here); the same fingerprint value is reused across every key for a kit at a point in time. A re-render under an unchanged fingerprint is a no-op key lookup; a re-render under a changed one is a new row, the old one left in place (storage cleanup is a service_role concern, not modeled here).';
comment on column public.brand_assets.user_id is
  'Denormalised from brand_kits→projects at write time, so the owner-read RLS policy below is a single-column check rather than a join. Never the authority for who owns the kit — brand_kit_entitled() is, and record_brand_asset() (§3.3) is what writes this column, always from auth.uid().';
comment on column public.brand_assets.storage_path is
  'Path under the brand-assets bucket: {brand_kit_id}/{fingerprint}/{key}.{ext}. Always the value request_brand_asset_upload (§3.2) returned and record_brand_asset (§3.3) re-validated — never hand-built by a caller.';

create index brand_assets_kit_fingerprint_idx
  on public.brand_assets using btree (brand_kit_id, fingerprint);

alter table public.brand_assets enable row level security;

-- No INSERT/UPDATE/DELETE policy for authenticated on purpose: every write
-- goes through record_brand_asset (§3.3), SECURITY DEFINER, which is what
-- actually authorizes the write via brand_kit_entitled() and bypasses RLS to
-- perform it. A client session that tries to INSERT this table directly gets
-- the ordinary RLS refusal, not a bespoke error.
create policy "brand_assets_select_own"
  on public.brand_assets
  for select
  to authenticated
  using (user_id = (select auth.uid()));


-- ============================================================================
-- 3. Storage: two private buckets, and the RLS that actually gates them
-- ============================================================================

-- 3.1 Buckets
-- brand-assets: per-kit rendered files. fonts: the shared TTF/OTF cache,
-- server-side only — no policy below references it, so no client role can
-- read or write it; only service_role (bypasses RLS) touches it.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand-assets', 'brand-assets', false, 5242880, array['image/svg+xml', 'image/png'])
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'fonts', 'fonts', false, 10485760,
  array['font/ttf', 'font/otf', 'font/woff', 'font/woff2', 'application/font-sfnt']
)
on conflict (id) do nothing;

-- 3.2 The policy helper
--
-- `(storage.foldername(name))[1]` is caller-controlled text, not a UUID.
-- The regex check happens BEFORE the cast: a malformed segment returns
-- `false` (RLS fails closed on that, same as any other unmatched row) rather
-- than raising, which would surface as an error instead of a plain refusal.
create or replace function public.brand_kit_asset_path_owner(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_kit_id_text text;
begin
  v_kit_id_text := (storage.foldername(p_name))[1];

  if v_kit_id_text is null
     or v_kit_id_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  then
    return false;
  end if;

  -- brand_kit_entitled() is auth.uid()-scoped and already false for a kit
  -- that is not the caller's or not paid for — reused whole, not re-stated.
  return public.brand_kit_entitled(v_kit_id_text::uuid);
end;
$$;

comment on function public.brand_kit_asset_path_owner(text) is
  'Whether the caller may read/write a storage.objects row whose name starts with {brand_kit_id}/… under the brand-assets bucket: owned AND entitled, via brand_kit_entitled() — never storage.objects.owner, which does not survive a kit outliving the session that first wrote to it. Defensive against a non-UUID first path segment: returns false rather than raising.';

revoke execute on function public.brand_kit_asset_path_owner(text) from public, anon;
grant execute on function public.brand_kit_asset_path_owner(text) to authenticated;

-- 3.3 The policies — SELECT and INSERT/UPDATE (never DELETE), scoped to the
-- brand-assets bucket only. The fonts bucket gets no policy at all: zero
-- policies on RLS-enabled storage.objects is deny-all for anon/authenticated
-- (the same behaviour codified for public tables in
-- 20260901190000_codify_rls_auto_enable.sql), which is exactly "server-side
-- only" for a bucket with no owner-scoping concept.
create policy "brand_assets_storage_select_own_paid"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'brand-assets'
    and public.brand_kit_asset_path_owner(name)
  );

create policy "brand_assets_storage_insert_own_paid"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'brand-assets'
    and public.brand_kit_asset_path_owner(name)
  );

-- Grants UPDATE on the same condition as INSERT — see point 2 in this
-- migration's header: a re-render of an unchanged fingerprint targets an
-- existing object, and the upload call is expected to pass `upsert: true`.
create policy "brand_assets_storage_update_own_paid"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'brand-assets'
    and public.brand_kit_asset_path_owner(name)
  )
  with check (
    bucket_id = 'brand-assets'
    and public.brand_kit_asset_path_owner(name)
  );


-- ============================================================================
-- 4. Three RPCs — validation and path construction, not the security
--    boundary (see this migration's header). All auth.uid()-scoped, all
--    refusing an unpaid kit with the contract's payment_required shape.
-- ============================================================================

-- 4.1 get_brand_asset_manifest — the catalogue, joined against what already
-- exists for the kit's current fingerprint (passed in — never recomputed
-- here; see the header for why fingerprinting is not duplicated in SQL).
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
            'created_at', a.created_at
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

comment on function public.get_brand_asset_manifest(uuid, text) is
  'The full asset_catalog for this kit, each entry marked current=true iff a brand_assets row exists at (kit, key, p_current_fingerprint). p_current_fingerprint is caller-computed (eklio-frontend) and trusted as "what current means for this request" — this function does not independently verify it against a recomputed hash.';

revoke execute on function public.get_brand_asset_manifest(uuid, text) from public, anon;
grant execute on function public.get_brand_asset_manifest(uuid, text) to authenticated, service_role;

-- 4.2 request_brand_asset_upload — validates key + fingerprint shape,
-- returns the path the frontend must upload to. Returns a PATH, not a URL:
-- signing that path into an actual upload URL is a Storage-API call
-- (createSignedUploadUrl), made by eklio-frontend with the caller's own
-- session — Postgres cannot mint that signature (see this migration's
-- header).
create or replace function public.request_brand_asset_upload(
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
  v_kind text;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  select kind into v_kind from public.asset_catalog where key = p_key;
  if v_kind is null then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found',
      'message', 'No such asset key in the catalog.'
    ));
  end if;

  -- Structural, not cryptographic: this only guards the fingerprint's use as
  -- a path segment (no '/', no traversal). It is not a check that the value
  -- is "the true current one" — see the comment on get_brand_asset_manifest.
  if p_fingerprint !~ '^[0-9a-f]{16,128}$' then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_format',
      'message', 'Fingerprint must be a lowercase hex string.',
      'field', 'fingerprint'
    ));
  end if;

  return jsonb_build_object(
    'bucket', 'brand-assets',
    'storage_path', format('%s/%s/%s.%s', p_brand_kit_id::text, p_fingerprint, p_key, v_kind)
  );
end;
$$;

comment on function public.request_brand_asset_upload(uuid, text, text) is
  'Validates p_key against asset_catalog and p_fingerprint''s shape, returns the storage_path eklio-frontend must pass to createSignedUploadUrl (bucket brand-assets, upsert: true). This is correctness, not authorization — the storage.objects RLS policies (§3.3) are what actually allow or refuse that upload, and refuse it identically for a caller who skips this RPC entirely.';

revoke execute on function public.request_brand_asset_upload(uuid, text, text) from public, anon;
grant execute on function public.request_brand_asset_upload(uuid, text, text) to authenticated, service_role;

-- 4.3 record_brand_asset — the only way a brand_assets row is written.
-- Re-validates and recomputes the expected storage_path rather than trusting
-- the caller's; ON CONFLICT makes a same-fingerprint re-render idempotent on
-- the metadata row, matching the storage-object UPDATE policy in §3.3.
create or replace function public.record_brand_asset(
  p_brand_kit_id uuid,
  p_key text,
  p_fingerprint text,
  p_storage_path text,
  p_byte_size integer,
  p_width integer default null,
  p_height integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text;
  v_expected_path text;
  v_id uuid;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required',
      'message', 'This brand kit is not yet paid for.'
    ));
  end if;

  select kind into v_kind from public.asset_catalog where key = p_key;
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

  v_expected_path := format('%s/%s/%s.%s', p_brand_kit_id::text, p_fingerprint, p_key, v_kind);
  if p_storage_path <> v_expected_path then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'invalid_field',
      'message', 'Storage path does not match this kit, fingerprint, and key.',
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
    brand_kit_id, user_id, key, kind, width, height, byte_size, storage_path, fingerprint
  )
  values (
    p_brand_kit_id, (select auth.uid()), p_key, v_kind, p_width, p_height, p_byte_size, p_storage_path, p_fingerprint
  )
  on conflict (brand_kit_id, key, fingerprint)
  do update set
    storage_path = excluded.storage_path,
    width         = excluded.width,
    height        = excluded.height,
    byte_size     = excluded.byte_size
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'storage_path', p_storage_path);
end;
$$;

comment on function public.record_brand_asset(uuid, text, text, text, integer, integer, integer) is
  'The only writer of brand_assets — SECURITY DEFINER, since brand_assets has no client INSERT policy (§1). Recomputes and compares the expected storage_path rather than trusting the caller''s. ON CONFLICT (brand_kit_id, key, fingerprint) makes a repeated call for the same render idempotent, matching the storage.objects UPDATE policy (§3.3): a re-render after upload retry or a crashed first attempt is a normal path, not an error.';

revoke execute on function public.record_brand_asset(uuid, text, text, text, integer, integer, integer) from public, anon;
grant execute on function public.record_brand_asset(uuid, text, text, text, integer, integer, integer) to authenticated, service_role;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop policy "brand_assets_storage_update_own_paid" on storage.objects;
--   drop policy "brand_assets_storage_insert_own_paid" on storage.objects;
--   drop policy "brand_assets_storage_select_own_paid" on storage.objects;
--   drop function if exists public.record_brand_asset(uuid, text, text, text, integer, integer, integer);
--   drop function if exists public.request_brand_asset_upload(uuid, text, text);
--   drop function if exists public.get_brand_asset_manifest(uuid, text);
--   drop function if exists public.brand_kit_asset_path_owner(text);
--   delete from storage.buckets where id in ('brand-assets', 'fonts');
--   drop table if exists public.brand_assets;
--   drop table if exists public.asset_catalog;
-- ============================================================================
