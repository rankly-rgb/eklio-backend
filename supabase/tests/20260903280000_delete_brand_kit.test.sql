-- ============================================================================
-- Tests — 20260903280000_delete_brand_kit.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000031','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000032','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000031','aaaaaaaa-0000-0000-0000-000000000031','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000031','bbbbbbbb-0000-0000-0000-000000000031');
insert into public.project_briefs (project_id, practice_name) values
  ('bbbbbbbb-0000-0000-0000-000000000031','Elm & Ember Therapy');

-- ---------------------------------------------------------------------------
-- delete_brand_kit: sets deleted_at, idempotent, ownership-scoped.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
  t1 timestamptz;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000031"}';

  result := public.delete_brand_kit('cccccccc-0000-0000-0000-000000000031');
  assert (result ->> 'ok')::boolean, format('delete_brand_kit failed: %s', result);
  assert result ->> 'deleted_at' is not null, 'delete_brand_kit must return the deleted_at it set';

  select deleted_at into t1 from public.brand_kits
   where id='cccccccc-0000-0000-0000-000000000031';
  assert t1 is not null, 'delete_brand_kit must set deleted_at';

  perform pg_sleep(0.01);
  result := public.delete_brand_kit('cccccccc-0000-0000-0000-000000000031');
  assert (result ->> 'deleted_at')::timestamptz = t1,
         're-deleting an already-deleted kit moved its deleted_at';

  reset role;
  insert into public.projects (id, user_id, name) values
    ('bbbbbbbb-0000-0000-0000-000000000032','aaaaaaaa-0000-0000-0000-000000000032','Second practice');
  insert into public.brand_kits (id, project_id) values
    ('cccccccc-0000-0000-0000-000000000032','bbbbbbbb-0000-0000-0000-000000000032');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000031"}';
  result := public.delete_brand_kit('cccccccc-0000-0000-0000-000000000032');
  assert result -> 'error' ->> 'code' = 'not_found',
         'a stranger was able to delete another user''s kit';
  assert (select deleted_at from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000032') is null,
         'a stranger''s delete call must not have written anything';
end
$$;

-- ---------------------------------------------------------------------------
-- restore_brand_kit: clears deleted_at, refuses a kit that isn't deleted.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000031"}';

  result := public.restore_brand_kit('cccccccc-0000-0000-0000-000000000031');
  assert (result ->> 'ok')::boolean, format('restore_brand_kit failed: %s', result);
  assert (select deleted_at from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000031') is null,
         'restore_brand_kit must clear deleted_at';

  -- restoring an already-active kit is refused, not a silent success
  result := public.restore_brand_kit('cccccccc-0000-0000-0000-000000000031');
  assert result -> 'error' ->> 'code' = 'not_found',
         'restoring a kit that is not deleted must be refused';

  -- a stranger cannot restore someone else''s deleted kit
  perform public.delete_brand_kit('cccccccc-0000-0000-0000-000000000031');
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000032"}';
  result := public.restore_brand_kit('cccccccc-0000-0000-0000-000000000031');
  assert result -> 'error' ->> 'code' = 'not_found',
         'a stranger was able to restore another user''s deleted kit';
end
$$;

-- ---------------------------------------------------------------------------
-- list_deleted_brand_kits: the window, the name fallback, ownership.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  reset role;
  -- A second, older deletion outside the 30-day window -- a kit with no
  -- project_briefs row at all, to exercise the practice_name fallback.
  insert into public.projects (id, user_id, name) values
    ('bbbbbbbb-0000-0000-0000-000000000033','aaaaaaaa-0000-0000-0000-000000000031','Unnamed practice');
  insert into public.brand_kits (id, project_id, deleted_at) values
    ('cccccccc-0000-0000-0000-000000000033','bbbbbbbb-0000-0000-0000-000000000033', now() - interval '40 days');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000031"}';

  result := public.list_deleted_brand_kits();
  assert jsonb_array_length(result) = 1,
         format('list_deleted_brand_kits must only show kits inside the 30-day window, got: %s', result);
  assert (result -> 0 ->> 'brand_kit_id') = 'cccccccc-0000-0000-0000-000000000031',
         'list_deleted_brand_kits returned the wrong kit';
  assert (result -> 0 ->> 'practice_name') = 'Elm & Ember Therapy',
         'list_deleted_brand_kits must use the real practice_name when one exists';
  assert (result -> 0 ->> 'purge_at')::timestamptz = (result -> 0 ->> 'deleted_at')::timestamptz + interval '30 days',
         'purge_at must be exactly 30 days after deleted_at';

  -- a stranger''s list is empty, not an error and not someone else''s kits
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000032"}';
  result := public.list_deleted_brand_kits();
  assert result = '[]'::jsonb, 'a stranger must see an empty Recently deleted list';
end
$$;

-- ---------------------------------------------------------------------------
-- Not callable by anon.
-- ---------------------------------------------------------------------------
do $$
begin
  reset role;
  assert not has_function_privilege('anon', 'public.delete_brand_kit(uuid)', 'execute'),
         'delete_brand_kit must not be executable by anon';
  assert not has_function_privilege('anon', 'public.restore_brand_kit(uuid)', 'execute'),
         'restore_brand_kit must not be executable by anon';
  assert not has_function_privilege('anon', 'public.list_deleted_brand_kits()', 'execute'),
         'list_deleted_brand_kits must not be executable by anon';
end
$$;

rollback;
