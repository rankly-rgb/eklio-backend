-- ============================================================================
-- Tests — 20260905175222_notifications_and_workspaces.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000051','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000052','stranger@example.com');
-- auth.users' handle_new_user trigger already inserted the mirror row; this
-- only needs to set full_name (owner named, stranger left at its email
-- fallback) rather than insert a fresh one.
update public.profiles set full_name = 'Nora Whitfield'
 where id = 'aaaaaaaa-0000-0000-0000-000000000051';
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000051','aaaaaaaa-0000-0000-0000-000000000051','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000051','bbbbbbbb-0000-0000-0000-000000000051');

-- ---------------------------------------------------------------------------
-- First-ever sync: arms the baseline, reports nothing, creates no rows --
-- same convention as home_recent_activity, so turning this on never floods
-- her bell with a kit's entire render history at once.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000051"}';

  result := public.sync_notifications('cccccccc-0000-0000-0000-000000000051');
  assert result = '[]'::jsonb, format('first sync must report nothing, got: %s', result);

  assert (select count(*) from public.notifications
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051') = 0,
         'first sync must not create any notification rows';

  assert (select notifications_synced_at from public.brand_kits
           where id = 'cccccccc-0000-0000-0000-000000000051') is not null,
         'the first sync must still set the marker for next time';
end
$$;

-- ---------------------------------------------------------------------------
-- Second sync: a new asset since the marker is turned into a notification row;
-- older, already-seen activity is not. (The content_ready kind was retired
-- with the dead table in 20260910082539.)
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
  v_marker_before timestamptz;
begin
  reset role;

  select notifications_synced_at into v_marker_before from public.brand_kits
   where id = 'cccccccc-0000-0000-0000-000000000051';

  -- Before the marker: already seen, must not generate a notification.
  insert into public.brand_assets
    (brand_kit_id, user_id, key, kind, byte_size, storage_path, fingerprint, created_at)
  values
    ('cccccccc-0000-0000-0000-000000000051','aaaaaaaa-0000-0000-0000-000000000051',
     'wordmark_svg_dark','svg',100,
     'cccccccc-0000-0000-0000-000000000051/old/wordmark_svg_dark.svg','old',
     v_marker_before - interval '1 hour');

  -- After the marker: a real rebuild since she last synced.
  insert into public.brand_assets
    (brand_kit_id, user_id, key, kind, byte_size, storage_path, fingerprint, created_at)
  values
    ('cccccccc-0000-0000-0000-000000000051','aaaaaaaa-0000-0000-0000-000000000051',
     'monogram_svg','svg',100,
     'cccccccc-0000-0000-0000-000000000051/new/monogram_svg.svg','new',
     now() + interval '1 second');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000051"}';

  result := public.sync_notifications('cccccccc-0000-0000-0000-000000000051');

  assert jsonb_array_length(result) = 1,
         format('expected exactly one asset_rendered notification, got: %s', result);

  assert (select count(*) from public.notifications
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051'
             and kind = 'asset_rendered'
             and payload ->> 'key' = 'monogram_svg') = 1,
         'the new asset must produce exactly one asset_rendered notification';

  assert (select count(*) from public.notifications
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051'
             and kind = 'asset_rendered'
             and payload ->> 'key' = 'wordmark_svg_dark') = 0,
         'the already-seen (pre-marker) asset must not produce a notification';

  /*
   * ⚠ L'INVERSE DE CE QU'ELLE AFFIRMAIT. Cette assertion exigeait UNE
   * notification `content_ready`. 20260910082539 a retiré le genre avec la
   * table morte : la contrainte CHECK ne l'admet plus, et `sync_notifications`
   * ne l'écrit plus. On vérifie donc qu'il n'en apparaît aucune.
   */
  assert (select count(*) from public.notifications
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051'
             and kind = 'content_ready') = 0,
         'the retired content_ready notification kind came back';

  -- Running sync again immediately must not duplicate: the same two events
  -- come back (they're still unread), but no new rows are created for them
  -- -- ON CONFLICT DO NOTHING against the per-kind dedup indexes is what
  -- guarantees this, not the timestamp comparison (Postgres fixes now() for
  -- the whole test transaction, so a rerun here would otherwise re-match the
  -- same "after the marker" window and duplicate).
  result := public.sync_notifications('cccccccc-0000-0000-0000-000000000051');
  assert jsonb_array_length(result) = 1,
         format('a sync with nothing new must still report the still-unread notification, got: %s', result);

  /*
   * ⚠ UN, PAS DEUX — ET C'EST LA MÊME RETRAITE QUE CI-DESSUS. L'assertion
   * disait 2 parce qu'il y avait deux genres : `asset_rendered` et
   * `content_ready`. 20260910082539 a retiré le second avec sa table morte,
   * et la session qui a corrigé l'assertion `content_ready = 0` juste
   * au-dessus a laissé ce total à 2. Le fixture ne produit qu'UN événement
   * notifiable (`monogram_svg`, après le marqueur) — ce que l'assertion
   * `jsonb_array_length(result) = 1` juste au-dessus affirme déjà.
   *
   * Ce que la ligne vérifie n'a pas changé : une seconde synchronisation ne
   * duplique pas. Seul le compte a été rattrapé.
   */
  assert (select count(*) from public.notifications
           where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051') = 1,
         'a second sync must not have created duplicate rows for the same events';
end
$$;

-- ---------------------------------------------------------------------------
-- Unread rows persist across syncs (the bell, not "since you were here" --
-- read state is independent of whether new events exist).
-- ---------------------------------------------------------------------------
do $$
declare
  unread_count int;
begin
  select count(*) into unread_count from public.notifications
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051' and read_at is null;
  -- UN, pas deux : même héritage de la retraite de `content_ready` que plus
  -- haut. Le fixture ne produit qu'un seul événement notifiable.
  assert unread_count = 1, format('expected the earlier notification to still be unread, got %s', unread_count);
end
$$;

-- ---------------------------------------------------------------------------
-- mark_notifications_read clears exactly this kit's unread rows for the
-- caller, and only the caller's own.
-- ---------------------------------------------------------------------------
do $$
declare
  marked boolean;
  unread_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000051"}';

  marked := public.mark_notifications_read('cccccccc-0000-0000-0000-000000000051');
  assert marked is true, 'mark_notifications_read should report success';

  select count(*) into unread_count from public.notifications
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051' and read_at is null;
  assert unread_count = 0, format('expected zero unread after marking read, got %s', unread_count);
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: a stranger reads zero rows, the owner reads their own.
-- ---------------------------------------------------------------------------
do $$
declare
  owned_count int;
  stranger_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000051"}';
  select count(*) into owned_count from public.notifications
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051';
  -- UN, pas deux : troisième et dernière occurrence du même total laissé par
  -- la retraite de `content_ready` (20260910082539). J'ai corrigé les deux
  -- premières une à une au lieu de les énumérer d'un coup — la leçon de la
  -- journée, apprise trois fois.
  assert owned_count = 1, format('the owner should read their own notification, got %s', owned_count);

  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000052"}';
  select count(*) into stranger_count from public.notifications
   where brand_kit_id = 'cccccccc-0000-0000-0000-000000000051';
  assert stranger_count = 0, format('a stranger must read zero of another user''s notifications, got %s', stranger_count);
end
$$;

-- ---------------------------------------------------------------------------
-- Direct client writes are refused -- only the RPCs can write.
-- ---------------------------------------------------------------------------
do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000051"}';

  begin
    insert into public.notifications (user_id, brand_kit_id, kind)
    values ('aaaaaaaa-0000-0000-0000-000000000051','cccccccc-0000-0000-0000-000000000051','asset_rendered');
    assert false, 'a direct client INSERT into notifications must be refused';
  exception
    when others then null;
  end;
end
$$;

-- ---------------------------------------------------------------------------
-- Not callable by anon.
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('anon', 'public.sync_notifications(uuid)', 'execute'),
         'sync_notifications must not be executable by anon';
  assert not has_function_privilege('anon', 'public.mark_notifications_read(uuid)', 'execute'),
         'mark_notifications_read must not be executable by anon';
end
$$;

-- ---------------------------------------------------------------------------
-- workspaces: exactly one row, her own, never a stranger's.
-- ---------------------------------------------------------------------------
do $$
declare
  v_row_count int;
  v_owner_name text;
begin
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000051"}';

  select count(*) into v_row_count from public.workspaces;
  assert v_row_count = 1, format('expected exactly one workspace row, got %s', v_row_count);

  select w.owner_name into v_owner_name from public.workspaces w limit 1;
  assert v_owner_name = 'Nora Whitfield', format('expected her own workspace row, got owner_name=%s', v_owner_name);

  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000052"}';
  select count(*) into v_row_count from public.workspaces;
  assert v_row_count = 1, 'a stranger should still see exactly one row -- their own, not the owner''s';
  select w.owner_name into v_owner_name from public.workspaces w limit 1;
  assert v_owner_name = 'stranger@example.com',
         format('a stranger must see their OWN workspace row (falling back to email, no full_name set), got %s', v_owner_name);
end
$$;

rollback;
