-- ============================================================================
-- Tests — 20260910083735_content_system_schema.sql
-- ============================================================================
-- What these fix, in order of what it costs to get wrong:
--
--   1. THE NON-OWNER. Five of the six new tables are per-kit and must return
--      NOTHING to anyone else. This repo's signature defect is a table whose
--      RLS is on and whose policies are missing: it returns zero rows to
--      clients, everything to service_role, and raises nothing.
--   2. THE TWO AXES STAY DISJOINT. A register is not an archetype and an
--      archetype is not a register. Tested in BOTH directions, because a
--      collision in either one lets a value be silently accepted by the wrong
--      column.
--   3. THE MONEY. reserved + used may never exceed the budget, and the CHECK
--      is on the ROW rather than only in an RPC.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-0000000000c1','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-0000000000c2','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-0000000000c1','Owner practice'),
  ('bbbbbbbb-0000-0000-0000-0000000000c2','aaaaaaaa-0000-0000-0000-0000000000c2','Stranger practice');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000c1','bbbbbbbb-0000-0000-0000-0000000000c1'),
  ('cccccccc-0000-0000-0000-0000000000c2','bbbbbbbb-0000-0000-0000-0000000000c2');

insert into public.content_preferences (brand_kit_id, cadence_per_week, accepted_registers, off_limits)
values ('cccccccc-0000-0000-0000-0000000000c1', 2,
        array['named_feeling','practical_note'], 'No politics.');
insert into public.content_checkins (brand_kit_id, month, sessions_theme, taking_clients)
values ('cccccccc-0000-0000-0000-0000000000c1', '2026-10-01', 'Burnout.', 'waitlist');
insert into public.content_months (id, brand_kit_id, month, themes, status)
values ('dddddddd-0000-0000-0000-0000000000c1','cccccccc-0000-0000-0000-0000000000c1',
        '2026-10-01', array['rest','returning'], 'proposed');
insert into public.content_grounds (month_id, theme, fingerprint, cost_cents, state)
values ('dddddddd-0000-0000-0000-0000000000c1','rest','fp_rest', 5, 'reserved');
insert into public.content_image_allowance (brand_kit_id, month, budget_cents, reserved_cents)
values ('cccccccc-0000-0000-0000-0000000000c1','2026-10-01', 100, 5);

-- ---------------------------------------------------------------------------
-- 1. A stranger sees nothing of hers -- and the catalogue is the one exception
-- ---------------------------------------------------------------------------
do $$
declare n int; t text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000c2"}';

  foreach t in array array['content_preferences','content_checkins','content_months',
                           'content_grounds','content_image_allowance']
  loop
    execute format('select count(*) from public.%I', t) into n;
    assert n = 0, format('a stranger can read %s (%s rows)', t, n);
  end loop;

  -- The register catalogue is deliberately world-readable to signed-in users:
  -- the preferences step lists the six for her to choose from.
  select count(*) into n from public.content_registers;
  assert n = 6, format('the register catalogue must be readable by any signed-in user, saw %s', n);
end $$;

-- ---------------------------------------------------------------------------
-- 2. The owner sees her own
-- ---------------------------------------------------------------------------
do $$
declare n int; t text;
begin
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000c1"}';

  foreach t in array array['content_preferences','content_checkins','content_months',
                           'content_grounds','content_image_allowance']
  loop
    execute format('select count(*) from public.%I', t) into n;
    assert n = 1, format('the owner cannot read her own %s (%s rows)', t, n);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. No client writes anything directly -- not even her own rows
-- ---------------------------------------------------------------------------
do $$
declare blocked boolean; t text;
begin
  reset role;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000c1"}';

  foreach t in array array['content_preferences','content_checkins','content_months',
                           'content_grounds','content_image_allowance','content_registers']
  loop
    begin
      execute format('update public.%I set updated_at = now()', t);
      -- An update denied by policy affects zero rows rather than raising.
      blocked := not found;
    exception when others then blocked := true; end;
    assert blocked, format('a client was able to update %s directly', t);
  end loop;
end $$;

rollback;


-- ============================================================================
-- The constraints, on a clean transaction
-- ============================================================================
begin;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-0000000000d1','o@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-0000000000d1','P');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000d1','bbbbbbbb-0000-0000-0000-0000000000d1');

do $$
declare rejected boolean;
begin
  -- An unknown register is refused by the trigger, not silently stored.
  begin
    insert into public.content_preferences (brand_kit_id, cadence_per_week, accepted_registers)
    values ('cccccccc-0000-0000-0000-0000000000d1', 2, array['named_feeling','not_a_register']);
    rejected := false;
  exception when others then rejected := true; end;
  assert rejected, 'an unknown register was accepted';

  -- ⚠ AN ARCHETYPE VALUE IS NOT A REGISTER. This is the collision the whole
  --   two-column design exists to prevent, tested from the outside.
  begin
    insert into public.content_preferences (brand_kit_id, cadence_per_week, accepted_registers)
    values ('cccccccc-0000-0000-0000-0000000000d1', 2, array['question']);
    rejected := false;
  exception when others then rejected := true; end;
  assert rejected, 'the archetype value "question" was accepted as a register';

  -- Duplicates would weigh one register twice in the generator's draw.
  begin
    insert into public.content_preferences (brand_kit_id, cadence_per_week, accepted_registers)
    values ('cccccccc-0000-0000-0000-0000000000d1', 2, array['permission','permission']);
    rejected := false;
  exception when others then rejected := true; end;
  assert rejected, 'duplicate registers were accepted';

  -- Cadence is closed: the generation plan is a table indexed by it.
  begin
    insert into public.content_preferences (brand_kit_id, cadence_per_week, accepted_registers)
    values ('cccccccc-0000-0000-0000-0000000000d1', 7, array['permission']);
    rejected := false;
  exception when others then rejected := true; end;
  assert rejected, 'a cadence of 7 was accepted';

  -- And the real thing goes in.
  insert into public.content_preferences (brand_kit_id, cadence_per_week, accepted_registers)
  values ('cccccccc-0000-0000-0000-0000000000d1', 3,
          array['named_feeling','reflective_question','permission']);
end $$;

do $$
declare rejected boolean;
begin
  -- ⚠ THE MONEY INVARIANT. reserved + used may never exceed the budget,
  --   enforced in the ROW so a future writer that forgets cannot overspend her.
  insert into public.content_image_allowance
    (brand_kit_id, month, budget_cents, reserved_cents, used_cents)
  values ('cccccccc-0000-0000-0000-0000000000d1','2026-10-01', 100, 60, 40);

  begin
    update public.content_image_allowance set reserved_cents = 61
     where brand_kit_id = 'cccccccc-0000-0000-0000-0000000000d1';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'the allowance was allowed to exceed its budget';
end $$;

do $$
declare rejected boolean;
begin
  insert into public.content_months (id, brand_kit_id, month, themes, status)
  values ('dddddddd-0000-0000-0000-0000000000d1','cccccccc-0000-0000-0000-0000000000d1',
          '2026-10-01', array['rest'], 'generating');

  -- A ground that claims to be settled must have bytes behind it.
  begin
    insert into public.content_grounds (month_id, theme, fingerprint, cost_cents, state, storage_path)
    values ('dddddddd-0000-0000-0000-0000000000d1','rest','fp',5,'settled', null);
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'a settled ground with no storage_path was accepted';

  -- One ground per theme, per month.
  insert into public.content_grounds (month_id, theme, fingerprint, cost_cents, state)
  values ('dddddddd-0000-0000-0000-0000000000d1','rest','fp',5,'reserved');
  begin
    insert into public.content_grounds (month_id, theme, fingerprint, cost_cents, state)
    values ('dddddddd-0000-0000-0000-0000000000d1','rest','fp2',5,'reserved');
    rejected := false;
  exception when unique_violation then rejected := true; end;
  assert rejected, 'two grounds for one theme in one month were accepted';
end $$;

do $$
declare rejected boolean;
begin
  -- `proposed` is now a legal status.
  insert into public.content_items (brand_kit_id, archetype, status, register)
  values ('cccccccc-0000-0000-0000-0000000000d1','statement','proposed','named_feeling');

  -- `published` still is not: publication state is derived from the log.
  begin
    insert into public.content_items (brand_kit_id, archetype, status)
    values ('cccccccc-0000-0000-0000-0000000000d1','statement','published');
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'published came back as an item status';

  -- ⚠ AND A REGISTER VALUE IS NOT AN ARCHETYPE -- the mirror of the test above.
  begin
    insert into public.content_items (brand_kit_id, archetype, status)
    values ('cccccccc-0000-0000-0000-0000000000d1','named_feeling','draft');
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'the register "named_feeling" was accepted as an archetype';
end $$;

rollback;
