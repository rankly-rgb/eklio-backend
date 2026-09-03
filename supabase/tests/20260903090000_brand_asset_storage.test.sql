-- ============================================================================
-- Tests — 20260903090000_brand_asset_storage.sql
-- ============================================================================
-- The defining test of this lot, per the brief: a session that never calls
-- any RPC in this migration, and instead does the raw storage.objects
-- operation createSignedUploadUrl/createSignedUrl ultimately authorizes
-- (INSERT/SELECT under RLS as `authenticated`), is refused for a path under
-- another kit's brand_kit_id — and allowed only for her own, paid kit.
-- Everything else in this file is the same shape applied to brand_assets,
-- asset_catalog, and the three RPCs.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','paid@example.com'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','unpaid@example.com');

insert into public.projects (id, user_id, name) values
  ('a1111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Paid Practice'),
  ('b2222222-2222-2222-2222-222222222222','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','Unpaid Practice');

insert into public.project_briefs (project_id, practice_name, license_type_id, city, state)
values
  ('a1111111-1111-1111-1111-111111111111','Paid Practice','lcsw','Portland','OR'),
  ('b2222222-2222-2222-2222-222222222222','Unpaid Practice','lcsw','Salem','OR');

insert into public.brand_kits (id, project_id) values
  ('a3333333-3333-3333-3333-333333333333','a1111111-1111-1111-1111-111111111111'),
  ('b4444444-4444-4444-4444-444444444444','b2222222-2222-2222-2222-222222222222');

insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','a1111111-1111-1111-1111-111111111111',
   'starter','cs_paid',4900,'paid',now());
-- user_b owns a kit and has never paid for it — no purchases row at all.

-- ---------------------------------------------------------------------------
-- asset_catalog — reference data, readable by any authenticated caller
-- ---------------------------------------------------------------------------
do $$
declare v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}';
  select count(*) into v_count from public.asset_catalog where key = 'wordmark_svg_dark';
  reset role;
  assert v_count = 1, 'wordmark_svg_dark seed row is not visible to an authenticated caller';
end
$$;

-- ---------------------------------------------------------------------------
-- brand_assets RLS — no client INSERT, owner-only SELECT
-- ---------------------------------------------------------------------------
do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';
  begin
    insert into public.brand_assets
      (brand_kit_id, user_id, key, kind, byte_size, storage_path, fingerprint)
    values
      ('a3333333-3333-3333-3333-333333333333','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'wordmark_svg_dark','svg',100,
       'a3333333-3333-3333-3333-333333333333/deadbeefdeadbeef/wordmark_svg_dark.svg',
       'deadbeefdeadbeef');
    raise exception 'a direct client INSERT into brand_assets should have been refused by RLS';
  exception
    when insufficient_privilege then null;
  end;
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- request_brand_asset_upload / record_brand_asset — refusals
-- ---------------------------------------------------------------------------
do $$
declare v_result jsonb;
begin
  -- unpaid owner: payment_required, not a storage path
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}';
  v_result := public.request_brand_asset_upload('b4444444-4444-4444-4444-444444444444','wordmark_svg_dark','a'||repeat('b',30));
  assert v_result -> 'error' ->> 'code' = 'payment_required',
    format('unpaid owner should get payment_required, got %s', v_result);

  -- paid owner, unknown key: not_found
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';
  v_result := public.request_brand_asset_upload('a3333333-3333-3333-3333-333333333333','no_such_key','a'||repeat('b',30));
  assert v_result -> 'error' ->> 'code' = 'not_found',
    format('unknown key should get not_found, got %s', v_result);

  -- paid owner, malformed fingerprint: invalid_format
  v_result := public.request_brand_asset_upload('a3333333-3333-3333-3333-333333333333','wordmark_svg_dark','not-hex!!');
  assert v_result -> 'error' ->> 'code' = 'invalid_format',
    format('malformed fingerprint should get invalid_format, got %s', v_result);

  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- The happy path, end to end: request → the path it returns → record → the
-- manifest reflecting it → a second record call for the same fingerprint
-- (re-render) is idempotent, not a duplicate row.
-- ---------------------------------------------------------------------------
do $$
declare
  v_kit uuid := 'a3333333-3333-3333-3333-333333333333';
  v_fp text := 'deadbeefdeadbeef';
  v_request jsonb;
  v_path text;
  v_record jsonb;
  v_record2 jsonb;
  v_manifest jsonb;
  v_row_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';

  v_request := public.request_brand_asset_upload(v_kit, 'wordmark_svg_dark', v_fp);
  assert not (v_request ? 'error'), format('request_brand_asset_upload refused a valid call: %s', v_request);
  v_path := v_request ->> 'storage_path';
  assert v_path = v_kit::text || '/' || v_fp || '/wordmark_svg_dark.svg',
    format('unexpected storage_path shape: %s', v_path);
  assert v_request ->> 'bucket' = 'brand-assets', 'request_brand_asset_upload named the wrong bucket';

  -- record_brand_asset rejects a path that does not match what was issued
  v_record := public.record_brand_asset(v_kit, 'wordmark_svg_dark', v_fp, 'someone/else/path.svg', 200);
  assert v_record -> 'error' ->> 'code' = 'invalid_field',
    format('a mismatched storage_path should get invalid_field, got %s', v_record);

  v_record := public.record_brand_asset(v_kit, 'wordmark_svg_dark', v_fp, v_path, 200, 640, 160);
  assert not (v_record ? 'error'), format('record_brand_asset refused a valid call: %s', v_record);

  -- Re-render of the SAME fingerprint: idempotent, one row, updated size.
  v_record2 := public.record_brand_asset(v_kit, 'wordmark_svg_dark', v_fp, v_path, 250, 640, 160);
  assert (v_record2 ->> 'id') = (v_record ->> 'id'),
    'a second record for the same (kit,key,fingerprint) created a new row instead of updating it';

  select count(*) into v_row_count from public.brand_assets
    where brand_kit_id = v_kit and key = 'wordmark_svg_dark' and fingerprint = v_fp;
  assert v_row_count = 1, format('expected exactly one brand_assets row after a re-render, got %s', v_row_count);

  v_manifest := public.get_brand_asset_manifest(v_kit, v_fp);
  assert jsonb_array_length(v_manifest) = 1, 'manifest should list exactly the one seeded catalog entry';
  assert (v_manifest -> 0 ->> 'key') = 'wordmark_svg_dark', 'manifest entry has the wrong key';
  assert (v_manifest -> 0 ->> 'current')::boolean is true,
    'manifest should mark wordmark_svg_dark current once a matching-fingerprint row exists';
  assert (v_manifest -> 0 -> 'asset' ->> 'byte_size')::int = 250,
    'manifest should reflect the re-rendered byte_size';

  -- A DIFFERENT fingerprint is not current, even though a row exists at all.
  v_manifest := public.get_brand_asset_manifest(v_kit, 'ffffffffffffffff');
  assert (v_manifest -> 0 ->> 'current')::boolean is false,
    'manifest should not mark an asset current under a fingerprint it was not rendered for';

  -- She can read her own recorded row directly; the stranger below cannot.
  select count(*) into v_row_count from public.brand_assets where brand_kit_id = v_kit;
  assert v_row_count = 1, 'owner should see her own brand_assets row';

  reset role;
end
$$;

do $$
declare v_row_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}';
  select count(*) into v_row_count from public.brand_assets where brand_kit_id = 'a3333333-3333-3333-3333-333333333333';
  reset role;
  assert v_row_count = 0, 'a stranger should see zero rows of another kit''s brand_assets';
end
$$;

-- ---------------------------------------------------------------------------
-- storage.objects — the actual security boundary, exercised directly and
-- WITHOUT calling any RPC above, exactly as createSignedUploadUrl /
-- createSignedUrl would authorize under the hood.
-- ---------------------------------------------------------------------------
do $$
declare
  v_own_path      text := 'a3333333-3333-3333-3333-333333333333/deadbeefdeadbeef/wordmark_svg_dark.svg';
  v_other_path    text := 'b4444444-4444-4444-4444-444444444444/deadbeefdeadbeef/wordmark_svg_dark.svg';
  v_malformed     text := 'not-a-uuid/deadbeefdeadbeef/wordmark_svg_dark.svg';
  v_count         int;
begin
  -- Paid owner: INSERT + SELECT succeed for her own kit's path. `owner` is
  -- deliberately left NULL here — point 4 of the migration's header: the
  -- path is the authority, not storage.objects.owner.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';
  insert into storage.objects (bucket_id, name) values ('brand-assets', v_own_path);
  select count(*) into v_count from storage.objects where bucket_id = 'brand-assets' and name = v_own_path;
  assert v_count = 1, 'paid owner could not read the object she just wrote under her own kit path';

  -- Overwrite (UPDATE) of the same path succeeds — the re-render case.
  update storage.objects set metadata = '{"re":"rendered"}'::jsonb
    where bucket_id = 'brand-assets' and name = v_own_path;
  reset role;

  -- Same paid owner: another kit's path (not hers) is refused, INSERT and
  -- SELECT alike, even though she is authenticated and even paid for a kit.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';
  begin
    insert into storage.objects (bucket_id, name) values ('brand-assets', v_other_path);
    raise exception 'insert under another kit''s path should have been refused';
  exception
    when insufficient_privilege then null;
  end;
  reset role;

  -- Owner of kit B, but never paid: her OWN kit's path is refused too.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}';
  begin
    insert into storage.objects (bucket_id, name) values ('brand-assets', v_other_path);
    raise exception 'an unpaid owner''s own kit path should still have been refused';
  exception
    when insufficient_privilege then null;
  end;
  select count(*) into v_count from storage.objects where bucket_id = 'brand-assets' and name = v_own_path;
  assert v_count = 0, 'unpaid stranger should not be able to read the paid owner''s object';
  reset role;

  -- anon: refused outright.
  set local role anon;
  begin
    insert into storage.objects (bucket_id, name) values ('brand-assets', v_own_path);
    raise exception 'anon should never be able to write to brand-assets';
  exception
    when insufficient_privilege then null;
  end;
  select count(*) into v_count from storage.objects where bucket_id = 'brand-assets' and name = v_own_path;
  assert v_count = 0, 'anon should not be able to read brand-assets objects either';
  reset role;

  -- Malformed first path segment: denied, not an error (the defensive-parse
  -- guarantee — a raised exception here would be a bug, not a refusal).
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';
  begin
    insert into storage.objects (bucket_id, name) values ('brand-assets', v_malformed);
    raise exception 'a non-UUID path segment should have been refused, not accepted';
  exception
    when insufficient_privilege then null;
  end;
  reset role;

  -- fonts bucket: zero policies means deny-all for every client role,
  -- service_role only.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}';
  begin
    insert into storage.objects (bucket_id, name) values ('fonts', 'inter/Inter-Regular.ttf');
    raise exception 'authenticated should never be able to write to the fonts bucket';
  exception
    when insufficient_privilege then null;
  end;
  reset role;

  set local role service_role;
  insert into storage.objects (bucket_id, name) values ('fonts', 'inter/Inter-Regular.ttf');
  select count(*) into v_count from storage.objects where bucket_id = 'fonts';
  assert v_count = 1, 'service_role should be able to write to the fonts bucket';
  reset role;
end
$$;

rollback;
