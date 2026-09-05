-- ============================================================================
-- Tests — 20260905182335_asset_downloads.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000081','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000082','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000081','aaaaaaaa-0000-0000-0000-000000000081','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000081','bbbbbbbb-0000-0000-0000-000000000081');
insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-000000000081','bbbbbbbb-0000-0000-0000-000000000081',
        'starter','cs_test_81',7900,'paid',now());
insert into public.brand_assets
  (brand_kit_id, user_id, key, kind, byte_size, storage_path, fingerprint, download_count)
values
  ('cccccccc-0000-0000-0000-000000000081','aaaaaaaa-0000-0000-0000-000000000081',
   'wordmark_svg_dark','svg',100,
   'cccccccc-0000-0000-0000-000000000081/fp1/wordmark_svg_dark.svg','fp1', 3);

-- ---------------------------------------------------------------------------
-- record_asset_download increments exactly the matching (kit, key,
-- fingerprint) row and returns the new count.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count int;
  v_stored int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000081"}';

  v_count := public.record_asset_download(
    'cccccccc-0000-0000-0000-000000000081', 'wordmark_svg_dark', 'fp1');
  assert v_count = 4, format('expected download_count to become 4, got %s', v_count);

  select download_count into v_stored from public.brand_assets
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000081' and key = 'wordmark_svg_dark';
  assert v_stored = 4, format('expected the stored row to reflect 4, got %s', v_stored);
end
$$;

-- ---------------------------------------------------------------------------
-- A fingerprint mismatch (an old, superseded row) is not incremented --
-- only the exact version she actually received counts.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000081"}';

  v_count := public.record_asset_download(
    'cccccccc-0000-0000-0000-000000000081', 'wordmark_svg_dark', 'not-the-real-fingerprint');
  assert v_count is null, format('a fingerprint mismatch must not increment anything, got %s', v_count);
end
$$;

-- ---------------------------------------------------------------------------
-- Ownership: a stranger cannot increment another kit's download count.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count int;
  v_stored int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000082"}';

  v_count := public.record_asset_download(
    'cccccccc-0000-0000-0000-000000000081', 'wordmark_svg_dark', 'fp1');
  assert v_count is null, format('a stranger must not be able to record a download, got %s', v_count);

  reset role;
  select download_count into v_stored from public.brand_assets
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000081' and key = 'wordmark_svg_dark';
  assert v_stored = 4, format('the stranger''s call must not have moved the count, got %s', v_stored);
end
$$;

-- ---------------------------------------------------------------------------
-- get_brand_asset_manifest surfaces download_count.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
  entry jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000081"}';

  result := public.get_brand_asset_manifest('cccccccc-0000-0000-0000-000000000081', 'fp1');
  select value into entry from jsonb_array_elements(result) where value ->> 'key' = 'wordmark_svg_dark';

  assert (entry -> 'asset' ->> 'download_count')::int = 4,
         format('expected the manifest entry to report download_count=4, got %s', entry -> 'asset');
end
$$;

-- ---------------------------------------------------------------------------
-- Not callable by anon.
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('anon', 'public.record_asset_download(uuid, text, text)', 'execute'),
         'record_asset_download must not be executable by anon';
end
$$;

rollback;
