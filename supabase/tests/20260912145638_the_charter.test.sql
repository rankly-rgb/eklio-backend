-- ============================================================================
-- Tests — the charter, what derives from it, and the guard that keeps a
-- practice's brand inside that practice
-- ============================================================================
-- The columns arrived in `20260912144121` and the rulings in `20260912145638`.
-- Nothing in the product reads them yet: the propagation is deliberately not
-- built. THAT IS PRECISELY WHY THIS FILE EXISTS.
--
-- An invariant with no reader is an invariant nobody notices breaking. The
-- cross-practice guard was originally proposed for "later, with the
-- propagation", and the ruling overturned that for the right reason: an inert
-- wrong value becomes a live wrong value the moment something reads it, and
-- nobody re-derives the guard at that moment. The same argument applies to the
-- test. It costs a file today and is unwritable in November, when the first
-- practice already has rows.
--
-- Wrapped in begin/rollback like the tenancy file: these fixtures are a
-- practice, its clinician and a rival practice, and none of them should outlive
-- the test. A guard rail in this chantier has already left an orphaned
-- organization in production by cleaning up less than it created.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. ANTI-VACUITY. Everything below passes trivially if the columns are absent.
-- ---------------------------------------------------------------------------
-- Derived from the catalogue, not asserted one name at a time by hand.
do $$
declare
  v_missing text;
begin
  select string_agg(want.name, ', ' order by want.name)
    into v_missing
    from (values
           ('organizations', 'brand_charter_kit_id'),
           ('brand_kits',    'derived_from_charter_kit_id'),
           ('brand_kits',    'charter_accepted_state'),
           ('brand_kits',    'charter_accepted_at'),
           ('brand_kits',    'detached_from_charter_kit_id'),
           ('brand_kits',    'detached_at')
         ) as want(tbl, name)
   where not exists (
     select 1 from information_schema.columns c
      where c.table_schema = 'public'
        and c.table_name = want.tbl
        and c.column_name = want.name);

  assert v_missing is null,
    format('charter columns missing, every test below would pass vacuously: %s', v_missing);
end
$$;

-- The guard is a trigger, and a trigger that is not attached guards nothing.
do $$
declare v_def text;
begin
  select pg_get_triggerdef(t.oid) into v_def
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'brand_kits'
     and t.tgname = 'brand_kits_charter_is_own_practice';

  assert v_def is not null, 'the charter guard trigger is not attached to brand_kits';
  assert v_def ilike '%before insert or update%',
    format('the guard must fire BEFORE the write, got: %s', v_def);
  assert v_def ilike '%derived_from_charter_kit_id%' and v_def ilike '%project_id%',
    format('the guard must also fire when a kit CHANGES PROJECT, got: %s', v_def);
end
$$;

-- A trigger function reachable from the browser is in the anonymous OpenAPI
-- document even though calling it fails. Same rule as the function surface.
do $$
begin
  assert not has_function_privilege('anon', 'public.brand_kit_charter_is_own_practice()', 'execute')
     and not has_function_privilege('authenticated', 'public.brand_kit_charter_is_own_practice()', 'execute'),
    'brand_kit_charter_is_own_practice() is reachable from the browser; revoke it';
end
$$;

-- ---------------------------------------------------------------------------
-- 1. THE GUARD, WALKED: a practice, its clinician, and a rival practice
-- ---------------------------------------------------------------------------
do $$
declare
  v_uid uuid := gen_random_uuid();
  v_org_a uuid; v_org_b uuid;
  v_proj_a uuid; v_proj_b uuid; v_proj_clinician uuid;
  v_charter_a uuid; v_charter_b uuid; v_kit uuid;
  v_refused boolean;
begin
  insert into auth.users (id, email) values (v_uid, 'charter-proof@example.test');

  insert into public.organizations (name) values ('Proof Practice A') returning id into v_org_a;
  insert into public.organizations (name) values ('Proof Practice B') returning id into v_org_b;

  insert into public.projects (user_id, name, organization_id)
       values (v_uid, 'A charter', v_org_a) returning id into v_proj_a;
  insert into public.projects (user_id, name, organization_id)
       values (v_uid, 'B charter', v_org_b) returning id into v_proj_b;
  insert into public.projects (user_id, name, organization_id)
       values (v_uid, 'A clinician', v_org_a) returning id into v_proj_clinician;

  insert into public.brand_kits (project_id) values (v_proj_a) returning id into v_charter_a;
  insert into public.brand_kits (project_id) values (v_proj_b) returning id into v_charter_b;
  insert into public.brand_kits (project_id) values (v_proj_clinician) returning id into v_kit;

  update public.organizations set brand_charter_kit_id = v_charter_a where id = v_org_a;
  update public.organizations set brand_charter_kit_id = v_charter_b where id = v_org_b;

  -- ⚠ THE ONE THAT MATTERS: another practice's charter is a cross-tenant read
  -- of somebody else's brand the day anything reads this column.
  v_refused := false;
  begin
    update public.brand_kits set derived_from_charter_kit_id = v_charter_b where id = v_kit;
  exception when others then v_refused := true;
  end;
  assert v_refused, 'a kit was allowed to derive from ANOTHER practice''s charter';

  -- And the guard must not be a wall: its own practice's charter is legitimate.
  update public.brand_kits set derived_from_charter_kit_id = v_charter_a where id = v_kit;
  assert (select derived_from_charter_kit_id from public.brand_kits where id = v_kit) = v_charter_a,
    'a kit was refused its OWN practice''s charter — the guard rejects everything';

  -- Moving the kit to the rival practice must be caught too: the guard fires on
  -- `project_id` as well, or the invariant is escapable by moving the kit
  -- rather than by changing the pointer.
  v_refused := false;
  begin
    update public.projects set organization_id = v_org_b where id = v_proj_clinician;
    update public.brand_kits set project_id = v_proj_b where id = v_kit;
  exception when others then v_refused := true;
  end;
  assert v_refused, 'a kit carried its old charter into another practice by changing project';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. THE PAIRED COLUMNS MOVE TOGETHER
-- ---------------------------------------------------------------------------
-- Half-set state is the failure these constraints exist for: an accepted state
-- with no date cannot be diffed against anything, and a detachment with no date
-- is a link that broke at no particular time.
do $$
declare
  v_uid uuid := gen_random_uuid();
  v_org uuid; v_proj uuid; v_kit uuid;
  v_refused boolean;
begin
  insert into auth.users (id, email) values (v_uid, 'charter-pairs@example.test');
  insert into public.organizations (name) values ('Proof Pairs') returning id into v_org;
  insert into public.projects (user_id, name, organization_id)
       values (v_uid, 'pairs', v_org) returning id into v_proj;
  insert into public.brand_kits (project_id) values (v_proj) returning id into v_kit;

  v_refused := false;
  begin
    update public.brand_kits set charter_accepted_state = '{"palette":[]}'::jsonb where id = v_kit;
  exception when others then v_refused := true;
  end;
  assert v_refused, 'charter_accepted_state was accepted without charter_accepted_at';

  v_refused := false;
  begin
    update public.brand_kits set detached_at = now() where id = v_kit;
  exception when others then v_refused := true;
  end;
  assert v_refused, 'detached_at was accepted without detached_from_charter_kit_id';

  -- The accepted state is an object, not an array and not a scalar: it is
  -- diffed key by key, and `[1,2,3]` would make that quietly meaningless.
  v_refused := false;
  begin
    update public.brand_kits
       set charter_accepted_state = '[1,2,3]'::jsonb, charter_accepted_at = now()
     where id = v_kit;
  exception when others then v_refused := true;
  end;
  assert v_refused, 'charter_accepted_state accepted a non-object';

  -- Set together, it is fine.
  update public.brand_kits
     set charter_accepted_state = '{"never_write":["a","b","c"]}'::jsonb,
         charter_accepted_at = now()
   where id = v_kit;
  assert (select charter_accepted_state is not null and charter_accepted_at is not null
            from public.brand_kits where id = v_kit),
    'the accepted pair was refused when set together';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. THE RULING ON THE VOICE GUIDE IS WRITTEN WHERE THE COLUMN LIVES
-- ---------------------------------------------------------------------------
-- Decision 1 split the inheritance rule across `voice_guide`'s two existing
-- keys rather than splitting the column. Nothing enforces that yet because
-- nothing inherits yet — so the only thing that can carry the ruling to the
-- next reader is the column comment, and a comment nobody tests is a comment
-- that gets dropped by the next `comment on`.
do $$
declare v_comment text;
begin
  select col_description('public.brand_kits'::regclass, a.attnum) into v_comment
    from pg_attribute a
   where a.attrelid = 'public.brand_kits'::regclass and a.attname = 'voice_guide';

  assert v_comment is not null, 'brand_kits.voice_guide lost its comment, and with it the ruling';
  assert v_comment like '%never_write%' and v_comment like '%sounds_like%',
    'the voice_guide comment no longer names both keys';
  assert v_comment ilike '%inherit%',
    'the voice_guide comment no longer records which half inherits';
end
$$;

rollback;
