-- ============================================================================
-- Eklio — user_uploads: the files SHE brings, and the portrait path
-- ============================================================================
-- ⚠ THE ONE RULE THIS TABLE EXISTS TO KEEP
--
-- A FILE SHE UPLOADED NEVER CARRIES A BRAND FINGERPRINT, AND IS NEVER
-- INVALIDATED BY A COLOUR CHANGE.
--
-- `brand_assets` rows are DERIVED: they are a rendering of her tokens, so when
-- the palette moves they go stale and are rebuilt. Her portrait is not derived
-- from anything. Changing an accent colour must not mark her own photograph
-- out of date, must not queue it for a rebuild, and must not delete it. There
-- is therefore no `fingerprint` column here, no `superseded_at`, and no
-- `current` flag — and a guard rail at the bottom fails this migration if one
-- ever appears.
--
-- ── QUOTAS LIVE IN THE RPC, NOT IN THE CLIENT ──────────────────────────────
--
-- A client-side size check is a courtesy; it is not a limit. Both the request
-- and the record path re-read the ceilings from `app_settings` and refuse over
-- them, and `record_user_upload` is the authoritative one because it is the
-- call that makes a row exist.
--
-- ── BYTES, NOT EXTENSIONS ──────────────────────────────────────────────────
--
-- The database cannot sniff a file, so it does the half it can: a mime
-- allowlist on the column AND on the bucket. The other half — reading the
-- magic bytes and refusing a .png that is actually an SVG — is done in
-- eklio-frontend before this RPC is ever called, in `lib/uploads/sniff.ts`.
-- Neither half is sufficient alone, and this comment exists so the next person
-- does not remove one believing the other covers it.
-- ============================================================================


-- ============================================================================
-- 1. One definition of "she owns this kit and has paid for it"
-- ============================================================================
-- `content_kit_access` (20260906155600) already encoded the ordering that
-- matters — not_found FIRST and alone, so a stranger's kit never answers
-- payment_required and thereby confirms it exists. Uploads need the same
-- ordering, so the body moves here and the content function delegates. Two
-- copies of an access decision is two chances to get the order wrong.

create or replace function public.kit_paid_access(p_brand_kit_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (
      select 1
        from public.brand_kits bk
        join public.projects pr on pr.id = bk.project_id
       where bk.id = p_brand_kit_id
         and pr.user_id = (select auth.uid())
    ) then 'not_found'
    when not public.brand_kit_entitled(p_brand_kit_id) then 'payment_required'
    else null
  end
$$;

comment on function public.kit_paid_access(uuid) is
  'NULL when the caller owns this kit and has paid for it; otherwise the error code every kit-scoped RPC returns. not_found is checked first and alone, so a kit that is not hers never answers payment_required.';

-- The content surface keeps its name and now delegates: one implementation.
create or replace function public.content_kit_access(p_brand_kit_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select public.kit_paid_access(p_brand_kit_id)
$$;


-- ============================================================================
-- 2. The ceilings, in app_settings so they move without a deploy
-- ============================================================================
insert into public.app_settings (key, value) values
  ('user_uploads_max_bytes',      '10485760'),
  ('user_uploads_kit_max_bytes',  '52428800'),
  ('user_uploads_kit_max_files',  '24')
on conflict (key) do nothing;


-- ============================================================================
-- 3. user_uploads
-- ============================================================================
create table if not exists public.user_uploads (
  id            uuid primary key default gen_random_uuid(),
  brand_kit_id  uuid not null,
  kind          text not null,
  storage_path  text not null,
  mime_type     text not null,
  byte_size     integer not null,
  original_name text,
  created_at    timestamptz not null default now(),

  constraint user_uploads_brand_kit_id_fkey foreign key (brand_kit_id)
    references public.brand_kits (id) on delete cascade,

  constraint user_uploads_kind_check check (kind in ('portrait','logo','photo','document')),

  -- The allowlist, as data. SVG is here because practices arrive with a logo
  -- in it; it is the reason `lib/uploads/svg.ts` exists.
  constraint user_uploads_mime_check check (mime_type in
    ('image/jpeg','image/png','image/webp','image/svg+xml','application/pdf')),

  constraint user_uploads_byte_size_check check (byte_size > 0),
  constraint user_uploads_path_unique unique (storage_path)
);

comment on table public.user_uploads is
  'Files the practitioner brought herself: her portrait, her existing logo, a document. NEVER fingerprinted and never invalidated by a palette change -- these are not derived from her tokens, unlike brand_assets.';

-- ONE portrait per kit. Replacing it is a delete-then-insert inside
-- record_user_upload, which returns the old path so the caller can remove the
-- object it pointed at.
create unique index if not exists user_uploads_one_portrait
  on public.user_uploads (brand_kit_id) where kind = 'portrait';

create index if not exists user_uploads_kit_idx
  on public.user_uploads (brand_kit_id, created_at desc);


-- ============================================================================
-- 4. The bucket
-- ============================================================================
-- SEPARATE from `brand-assets` on purpose. That bucket holds derived files
-- that a rebuild may legitimately overwrite or a purge remove; hers must not
-- share a lifecycle with them. `file_size_limit` mirrors
-- `user_uploads_max_bytes` as a second, independent floor.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'user-uploads', 'user-uploads', false, 10485760,
  array['image/jpeg','image/png','image/webp','image/svg+xml','application/pdf']
)
on conflict (id) do nothing;

-- Ownership reuses `brand_kit_asset_path_owner`: it parses the first path
-- segment as a kit id and asks `brand_kit_entitled`. Nothing about it is
-- specific to the other bucket, and a second copy would be a second place for
-- the rule to drift.
drop policy if exists "user_uploads_read_own"   on storage.objects;
drop policy if exists "user_uploads_write_own"  on storage.objects;
drop policy if exists "user_uploads_update_own" on storage.objects;
drop policy if exists "user_uploads_delete_own" on storage.objects;

create policy "user_uploads_read_own"
  on storage.objects for select to authenticated
  using (bucket_id = 'user-uploads' and public.brand_kit_asset_path_owner(name));

create policy "user_uploads_write_own"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'user-uploads' and public.brand_kit_asset_path_owner(name));

create policy "user_uploads_update_own"
  on storage.objects for update to authenticated
  using (bucket_id = 'user-uploads' and public.brand_kit_asset_path_owner(name))
  with check (bucket_id = 'user-uploads' and public.brand_kit_asset_path_owner(name));

create policy "user_uploads_delete_own"
  on storage.objects for delete to authenticated
  using (bucket_id = 'user-uploads' and public.brand_kit_asset_path_owner(name));


-- ============================================================================
-- 5. RLS on the table
-- ============================================================================
alter table public.user_uploads enable row level security;

drop policy if exists "user_uploads_select_own"    on public.user_uploads;
drop policy if exists "user_uploads_insert_denied" on public.user_uploads;
drop policy if exists "user_uploads_update_denied" on public.user_uploads;
drop policy if exists "user_uploads_delete_denied" on public.user_uploads;

create policy "user_uploads_select_own"
  on public.user_uploads for select to authenticated
  using (
    exists (
      select 1
        from public.brand_kits bk
        join public.projects pr on pr.id = bk.project_id
       where bk.id = user_uploads.brand_kit_id
         and pr.user_id = (select auth.uid())
    )
  );

-- Writes go through the RPCs, which is where the quota lives. A client INSERT
-- would be a quota with no enforcement.
create policy "user_uploads_insert_denied"
  on public.user_uploads for insert to authenticated with check (false);
create policy "user_uploads_update_denied"
  on public.user_uploads for update to authenticated using (false);
create policy "user_uploads_delete_denied"
  on public.user_uploads for delete to authenticated using (false);


-- ============================================================================
-- 6. The quota, in one place
-- ============================================================================
create or replace function public.user_uploads_setting_int(p_key text, p_fallback integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (value #>> '{}')::integer from public.app_settings where key = p_key), p_fallback)
$$;

/*
 * Returns NULL when a file of this size may be added, else the refusal code.
 * `p_replacing` is the row a portrait replaces, whose bytes do not count
 * against the total twice.
 */
create or replace function public.user_uploads_quota_error(
  p_brand_kit_id uuid,
  p_byte_size    integer,
  p_replacing    uuid default null
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_files int;
  v_bytes bigint;
begin
  if p_byte_size is null or p_byte_size <= 0 then
    return 'empty_file';
  end if;

  if p_byte_size > public.user_uploads_setting_int('user_uploads_max_bytes', 10485760) then
    return 'file_too_large';
  end if;

  select count(*), coalesce(sum(byte_size), 0)
    into v_files, v_bytes
    from public.user_uploads
   where brand_kit_id = p_brand_kit_id
     and (p_replacing is null or id <> p_replacing);

  if v_files + 1 > public.user_uploads_setting_int('user_uploads_kit_max_files', 24) then
    return 'too_many_files';
  end if;

  if v_bytes + p_byte_size > public.user_uploads_setting_int('user_uploads_kit_max_bytes', 52428800) then
    return 'kit_quota_exceeded';
  end if;

  return null;
end
$$;

create or replace function public.user_uploads_error(p_code text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('error', jsonb_build_object(
    'code', p_code,
    'message', case p_code
      when 'not_found'          then 'No such file.'
      when 'payment_required'   then 'This brand kit is not yet paid for.'
      when 'empty_file'         then 'That file is empty.'
      when 'file_too_large'     then 'That file is larger than 10 MB.'
      when 'too_many_files'     then 'You have reached the file limit for this brand.'
      when 'kit_quota_exceeded' then 'That would go over the storage for this brand.'
      when 'unsupported_type'   then 'That kind of file cannot be uploaded here.'
      else p_code
    end
  ))
$$;


-- ============================================================================
-- 7. The write surface
-- ============================================================================

-- 7.1 request_user_upload — the path, and an early refusal
create or replace function public.request_user_upload(
  p_brand_kit_id uuid,
  p_kind         text,
  p_mime_type    text,
  p_byte_size    integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_error   text;
  v_id      uuid := gen_random_uuid();
  v_ext     text;
  v_replace uuid;
begin
  v_error := public.kit_paid_access(p_brand_kit_id);
  if v_error is not null then
    return public.user_uploads_error(v_error);
  end if;

  if p_kind not in ('portrait','logo','photo','document') then
    return public.user_uploads_error('unsupported_type');
  end if;

  v_ext := case p_mime_type
    when 'image/jpeg'      then 'jpg'
    when 'image/png'       then 'png'
    when 'image/webp'      then 'webp'
    when 'image/svg+xml'   then 'svg'
    when 'application/pdf' then 'pdf'
    else null
  end;
  if v_ext is null then
    return public.user_uploads_error('unsupported_type');
  end if;

  if p_kind = 'portrait' then
    select id into v_replace from public.user_uploads
     where brand_kit_id = p_brand_kit_id and kind = 'portrait';
  end if;

  v_error := public.user_uploads_quota_error(p_brand_kit_id, p_byte_size, v_replace);
  if v_error is not null then
    return public.user_uploads_error(v_error);
  end if;

  -- The path is BUILT here and nowhere else. The first segment is the kit id,
  -- which is what the storage policy reads to decide ownership.
  return jsonb_build_object(
    'id',   v_id,
    'path', p_brand_kit_id::text || '/uploads/' || v_id::text || '.' || v_ext
  );
end
$$;

-- 7.2 record_user_upload — the authoritative gate
create or replace function public.record_user_upload(
  p_brand_kit_id  uuid,
  p_id            uuid,
  p_kind          text,
  p_storage_path  text,
  p_mime_type     text,
  p_byte_size     integer,
  p_original_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_error    text;
  v_replace  uuid;
  v_old_path text;
begin
  v_error := public.kit_paid_access(p_brand_kit_id);
  if v_error is not null then
    return public.user_uploads_error(v_error);
  end if;

  -- The path must be the one this kit was given. A caller that invents a path
  -- under someone else's kit id gets nothing, even though the storage policy
  -- would already have refused the object write.
  if p_storage_path is null
     or p_storage_path not like (p_brand_kit_id::text || '/uploads/%') then
    return public.user_uploads_error('not_found');
  end if;

  if p_kind = 'portrait' then
    select id, storage_path into v_replace, v_old_path
      from public.user_uploads
     where brand_kit_id = p_brand_kit_id and kind = 'portrait';
  end if;

  -- Re-checked at the moment the row is made, not only when it was requested:
  -- a request and its record are two calls, and the quota can have moved.
  v_error := public.user_uploads_quota_error(p_brand_kit_id, p_byte_size, v_replace);
  if v_error is not null then
    return public.user_uploads_error(v_error);
  end if;

  if v_replace is not null then
    delete from public.user_uploads where id = v_replace;
  end if;

  insert into public.user_uploads
    (id, brand_kit_id, kind, storage_path, mime_type, byte_size, original_name)
  values
    (p_id, p_brand_kit_id, p_kind, p_storage_path, p_mime_type, p_byte_size,
     left(nullif(btrim(coalesce(p_original_name, '')), ''), 120));

  return jsonb_build_object('id', p_id, 'replaced_path', v_old_path);
end
$$;

-- 7.3 delete_user_upload — returns the path so the object goes too
create or replace function public.delete_user_upload(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kit   uuid;
  v_path  text;
  v_error text;
begin
  select brand_kit_id, storage_path into v_kit, v_path
    from public.user_uploads where id = p_id;

  if v_kit is null then
    return public.user_uploads_error('not_found');
  end if;

  v_error := public.kit_paid_access(v_kit);
  if v_error is not null then
    return public.user_uploads_error(v_error);
  end if;

  delete from public.user_uploads where id = p_id;
  return jsonb_build_object('deleted', true, 'path', v_path);
end
$$;


-- ============================================================================
-- 8. The read surface
-- ============================================================================
create or replace function public.list_user_uploads(p_brand_kit_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_error text;
begin
  v_error := public.kit_paid_access(p_brand_kit_id);
  if v_error is not null then
    return public.user_uploads_error(v_error);
  end if;

  return jsonb_build_object(
    'files', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',            u.id,
               'kind',          u.kind,
               'storage_path',  u.storage_path,
               'mime_type',     u.mime_type,
               'byte_size',     u.byte_size,
               'original_name', u.original_name,
               'created_at',    u.created_at)
             order by u.created_at desc)
        from public.user_uploads u
       where u.brand_kit_id = p_brand_kit_id
    ), '[]'::jsonb),
    'quota', jsonb_build_object(
      'files',         (select count(*) from public.user_uploads where brand_kit_id = p_brand_kit_id),
      'max_files',     public.user_uploads_setting_int('user_uploads_kit_max_files', 24),
      'bytes',         (select coalesce(sum(byte_size), 0) from public.user_uploads where brand_kit_id = p_brand_kit_id),
      'max_bytes',     public.user_uploads_setting_int('user_uploads_kit_max_bytes', 52428800),
      'max_file_bytes',public.user_uploads_setting_int('user_uploads_max_bytes', 10485760)
    )
  );
end
$$;


-- ============================================================================
-- 9. Grants
-- ============================================================================
revoke execute on function public.kit_paid_access(uuid)                       from public, anon, authenticated;
revoke execute on function public.user_uploads_error(text)                    from public, anon, authenticated;
revoke execute on function public.user_uploads_setting_int(text, integer)     from public, anon, authenticated;
revoke execute on function public.user_uploads_quota_error(uuid, integer, uuid) from public, anon, authenticated;

grant execute on function public.request_user_upload(uuid, text, text, integer) to authenticated;
grant execute on function public.record_user_upload(uuid, uuid, text, text, text, integer, text) to authenticated;
grant execute on function public.delete_user_upload(uuid)                       to authenticated;
grant execute on function public.list_user_uploads(uuid)                        to authenticated;


-- ============================================================================
-- 10. Guard rails
-- ============================================================================
do $$
declare
  v_bad text;
begin
  -- ⚠ THE RULE THIS TABLE EXISTS TO KEEP. Her files are not derived from her
  -- palette, so nothing here may carry the machinery that makes a derived file
  -- go stale.
  select string_agg(column_name, ', ') into v_bad
    from information_schema.columns
   where table_schema = 'public' and table_name = 'user_uploads'
     and (column_name like '%fingerprint%'
       or column_name in ('superseded_at', 'current', 'stale', 'change_summary'));
  if v_bad is not null then
    raise exception
      'user_uploads: % would make her own files invalidatable by a colour change. They are not derived from her tokens.', v_bad;
  end if;

  -- No function in this file may reach the asset fingerprint machinery either.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('request_user_upload','record_user_upload','delete_user_upload',
                       'list_user_uploads','user_uploads_quota_error')
     and (p.prosrc like '%fingerprint%' or p.prosrc like '%brand_assets%');
  if v_bad is not null then
    raise exception 'user_uploads: % reference the derived-asset machinery.', v_bad;
  end if;

  -- The two access functions must agree, because one now delegates to the other.
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'content_kit_access')
     not like '%kit_paid_access%' then
    raise exception 'user_uploads: content_kit_access no longer delegates; two copies of the access ordering exist.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.list_user_uploads(uuid);
--   drop function if exists public.delete_user_upload(uuid);
--   drop function if exists public.record_user_upload(uuid, uuid, text, text, text, integer, text);
--   drop function if exists public.request_user_upload(uuid, text, text, integer);
--   drop function if exists public.user_uploads_quota_error(uuid, integer, uuid);
--   drop function if exists public.user_uploads_setting_int(text, integer);
--   drop function if exists public.user_uploads_error(text);
--   drop table if exists public.user_uploads;
--   -- content_kit_access keeps its 20260906155600 body; kit_paid_access then drops.
