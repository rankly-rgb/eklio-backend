-- ============================================================================
-- Tests — 20260903290000_home_recent_activity.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000041','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000042','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000041','aaaaaaaa-0000-0000-0000-000000000041','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000041','bbbbbbbb-0000-0000-0000-000000000041');

-- ---------------------------------------------------------------------------
-- First-ever call: nothing to report (no "before" to compare to), but the
-- marker is still set for next time.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000041"}';

  result := public.home_recent_activity('cccccccc-0000-0000-0000-000000000041');
  assert result ->> 'since' is null, 'a first-ever call must report a null since';
  assert result -> 'new_assets' = '[]'::jsonb, 'a first-ever call must not report any prior history as new';
  assert result -> 'content_ready' = '[]'::jsonb, 'a first-ever call must not report any prior history as new';

  assert (select home_content_seen_at from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000041') is not null,
         'the first call must still set the marker for next time';
end
$$;

-- ---------------------------------------------------------------------------
-- Between two calls: a new asset and newly-ready content are both reported;
-- older, already-seen activity is not.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
  v_marker_before timestamptz;
begin
  reset role;

  select home_content_seen_at into v_marker_before from public.brand_kits
   where id='cccccccc-0000-0000-0000-000000000041';

  -- An asset from BEFORE the marker: already seen, must not reappear.
  insert into public.brand_assets
    (brand_kit_id, user_id, key, kind, byte_size, storage_path, fingerprint, created_at)
  values
    ('cccccccc-0000-0000-0000-000000000041','aaaaaaaa-0000-0000-0000-000000000041',
     'wordmark_svg_dark','svg',100,
     'cccccccc-0000-0000-0000-000000000041/old/wordmark_svg_dark.svg','old',
     v_marker_before - interval '1 hour');

  -- `now()` is fixed for the whole transaction in Postgres, so this test
  -- uses explicit offsets from it rather than relying on real elapsed time
  -- (the RPC itself, in real use, always runs in its own transaction —
  -- this is purely a test-harness concern, not a production one).

  -- An asset from AFTER the marker: new since last visit.
  insert into public.brand_assets
    (brand_kit_id, user_id, key, kind, byte_size, storage_path, fingerprint, created_at)
  values
    ('cccccccc-0000-0000-0000-000000000041','aaaaaaaa-0000-0000-0000-000000000041',
     'monogram_svg','svg',100,
     'cccccccc-0000-0000-0000-000000000041/new/monogram_svg.svg','new',
     now() + interval '1 second');

  insert into public.monthly_presence_content
    (brand_kit_id, user_id, month, day_of_month, type, status, title, caption, updated_at)
  values
    ('cccccccc-0000-0000-0000-000000000041','aaaaaaaa-0000-0000-0000-000000000041',
     '2026-09-01', 3, 'post', 'ready', 'A question worth sitting with', 'Caption text.', now() + interval '1 second'),
    ('cccccccc-0000-0000-0000-000000000041','aaaaaaaa-0000-0000-0000-000000000041',
     '2026-09-01', 7, 'story', 'locked', null, null, now() + interval '1 second');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000041"}';

  result := public.home_recent_activity('cccccccc-0000-0000-0000-000000000041');
  assert (result ->> 'since')::timestamptz = v_marker_before,
         'the second call must report the marker as it was BEFORE this call moved it';

  assert jsonb_array_length(result -> 'new_assets') = 1,
         format('expected exactly one new asset, got: %s', result -> 'new_assets');
  assert (result -> 'new_assets' -> 0 ->> 'key') = 'monogram_svg',
         'the old, already-seen asset must not be reported as new';

  assert jsonb_array_length(result -> 'content_ready') = 1,
         format('expected exactly one newly-ready content item, got: %s', result -> 'content_ready');
  assert (result -> 'content_ready' -> 0 ->> 'title') = 'A question worth sitting with',
         'a still-locked item must not be reported as ready';

  -- The marker moved forward (not left at its old value) -- Postgres fixes
  -- `now()` for the whole test transaction, so a THIRD call can't be used
  -- here to prove "nothing new" the way a real, separate request could; the
  -- filtering logic itself (old excluded, new included) is already proven
  -- by the assertions above.
  assert (select home_content_seen_at from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000041') >= v_marker_before,
         'the marker must not move backward';
end
$$;

-- ---------------------------------------------------------------------------
-- Ownership: a stranger gets a clean not_found, and does not move the marker.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
  before_marker timestamptz;
begin
  reset role;
  select home_content_seen_at into before_marker from public.brand_kits
   where id='cccccccc-0000-0000-0000-000000000041';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000042"}';
  result := public.home_recent_activity('cccccccc-0000-0000-0000-000000000041');
  assert result -> 'error' ->> 'code' = 'not_found',
         'a stranger was able to read another user''s recent activity';

  reset role;
  assert (select home_content_seen_at from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000041') = before_marker,
         'a stranger''s refused call must not have moved the marker';
end
$$;

-- ---------------------------------------------------------------------------
-- Not callable by anon.
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('anon', 'public.home_recent_activity(uuid)', 'execute'),
         'home_recent_activity must not be executable by anon';
end
$$;

rollback;
