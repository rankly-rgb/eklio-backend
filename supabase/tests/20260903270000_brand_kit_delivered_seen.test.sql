-- ============================================================================
-- Tests — 20260903270000_brand_kit_delivered_seen.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000021','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000022','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000021','aaaaaaaa-0000-0000-0000-000000000021','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-000000000021','bbbbbbbb-0000-0000-0000-000000000021');

-- ---------------------------------------------------------------------------
-- A fresh kit starts undelivered.
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select delivered_seen_at from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000021') is null,
         'a fresh kit must not already be marked delivered';
end
$$;

-- ---------------------------------------------------------------------------
-- First call sets it and reports first_view: true; every call after that
-- reports false and never moves the timestamp.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
  t1 timestamptz;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000021"}';

  result := public.mark_brand_kit_delivered('cccccccc-0000-0000-0000-000000000021');
  assert (result ->> 'first_view')::boolean = true,
         'the first call must report first_view: true';

  select delivered_seen_at into t1 from public.brand_kits
   where id='cccccccc-0000-0000-0000-000000000021';
  assert t1 is not null, 'the first call must set delivered_seen_at';

  perform pg_sleep(0.01);

  result := public.mark_brand_kit_delivered('cccccccc-0000-0000-0000-000000000021');
  assert (result ->> 'first_view')::boolean = false,
         'a second call must report first_view: false';
  assert (select delivered_seen_at from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000021') = t1,
         'a second call moved a timestamp that was already set — no replay means no replay';

  result := public.mark_brand_kit_delivered('cccccccc-0000-0000-0000-000000000021');
  assert (result ->> 'first_view')::boolean = false,
         'a third call must still report first_view: false';
end
$$;

-- ---------------------------------------------------------------------------
-- Ownership: a stranger gets a clean not_found, and cannot touch the kit.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  reset role;
  insert into public.projects (id, user_id, name) values
    ('bbbbbbbb-0000-0000-0000-000000000022','aaaaaaaa-0000-0000-0000-000000000022','Second practice');
  insert into public.brand_kits (id, project_id) values
    ('cccccccc-0000-0000-0000-000000000022','bbbbbbbb-0000-0000-0000-000000000022');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000021"}';

  result := public.mark_brand_kit_delivered('cccccccc-0000-0000-0000-000000000022');
  assert result -> 'error' ->> 'code' = 'not_found',
         'a stranger was able to mark another user''s kit delivered';
  assert (select delivered_seen_at from public.brand_kits
           where id='cccccccc-0000-0000-0000-000000000022') is null,
         'a stranger''s call must not have written anything';
end
$$;

-- ---------------------------------------------------------------------------
-- A nonexistent kit gets the same clean not_found, not an exception.
-- ---------------------------------------------------------------------------
do $$
declare
  result jsonb;
begin
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000021"}';
  result := public.mark_brand_kit_delivered('00000000-0000-0000-0000-000000000000');
  assert result -> 'error' ->> 'code' = 'not_found',
         'a nonexistent kit id must return not_found, not raise';
end
$$;

-- ---------------------------------------------------------------------------
-- Not callable by anon.
-- ---------------------------------------------------------------------------
do $$
begin
  reset role;
  assert not has_function_privilege('anon', 'public.mark_brand_kit_delivered(uuid)', 'execute'),
         'mark_brand_kit_delivered must not be executable by anon';
  assert has_function_privilege('authenticated', 'public.mark_brand_kit_delivered(uuid)', 'execute'),
         'mark_brand_kit_delivered must be executable by authenticated';
end
$$;

rollback;
