-- ============================================================================
-- Tests — 20260910084320_content_system_rpcs.sql
-- ============================================================================
-- Three things, in order of what it costs to get wrong:
--
--   1. THE ALT-TEXT GATE. New behaviour, not a kept one. An item cannot reach
--      `ready` with blank alt text -- and a patch that sets status AND alt text
--      together must still succeed, because that is what the editor sends.
--   2. THE METER. reserve/settle against a MONTHLY allowance that is separate
--      from the kit's lifetime pot, with the reset proven structural: a
--      different month starts full.
--   3. THE DOORS. She writes preferences and the check-in; only the server
--      spends.
-- ============================================================================
begin;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-0000000000e1','o@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-0000000000e1','P');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000e1','bbbbbbbb-0000-0000-0000-0000000000e1');

-- `content_kit_access` refuses an unpaid kit, and a `paid` purchase must carry
-- `paid_at` (purchases_paid_at_check). The fixture has to be a real sale.
insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-0000000000e1','bbbbbbbb-0000-0000-0000-0000000000e1',
        'practice','cs_test_content_e1', 14900, 'paid', now());

insert into public.content_items (id, brand_kit_id, archetype, status, caption)
values ('eeeeeeee-0000-0000-0000-0000000000e1','cccccccc-0000-0000-0000-0000000000e1',
        'statement','draft','A caption.');

-- ---------------------------------------------------------------------------
-- 1. The alt-text gate, and her two write doors
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000e1"}';

  r := public.update_content_item('eeeeeeee-0000-0000-0000-0000000000e1', '{"status":"ready"}'::jsonb);
  assert r -> 'error' ->> 'code' = 'alt_text_required', format('expected alt_text_required, got %s', r);

  -- A space is not a description. char_length alone would have accepted one.
  r := public.update_content_item('eeeeeeee-0000-0000-0000-0000000000e1',
        '{"status":"ready","alt_text":"   "}'::jsonb);
  assert r -> 'error' ->> 'code' = 'alt_text_required', format('whitespace alt text accepted: %s', r);

  -- ⚠ status AND alt_text in ONE patch must succeed. Checking the STORED value
  --   rather than the resulting one would refuse the save that fills them
  --   together -- which is exactly what the editor sends.
  r := public.update_content_item('eeeeeeee-0000-0000-0000-0000000000e1',
        '{"status":"ready","alt_text":"A ceramic bowl on a pale windowsill."}'::jsonb);
  assert r ? 'saved_at', format('a combined patch was refused: %s', r);
  assert (select status from public.content_items
           where id='eeeeeeee-0000-0000-0000-0000000000e1') = 'ready';

  -- The gate is on `ready` only: drafting and proposing are unaffected.
  r := public.update_content_item('eeeeeeee-0000-0000-0000-0000000000e1',
        '{"status":"draft","alt_text":""}'::jsonb);
  assert r ? 'saved_at', format('draft was blocked by the alt gate: %s', r);
  r := public.update_content_item('eeeeeeee-0000-0000-0000-0000000000e1', '{"status":"proposed"}'::jsonb);
  assert r ? 'saved_at', format('proposed was blocked by the alt gate: %s', r);

  -- Preferences: saved, trimmed, and refusing an archetype passed as a register.
  r := public.set_content_preferences('cccccccc-0000-0000-0000-0000000000e1', 3::smallint,
        array['named_feeling','permission'], '  No politics.  ');
  assert r ? 'saved_at', format('preferences refused: %s', r);
  assert (select off_limits from public.content_preferences
           where brand_kit_id='cccccccc-0000-0000-0000-0000000000e1') = 'No politics.';

  r := public.set_content_preferences('cccccccc-0000-0000-0000-0000000000e1', 3::smallint,
        array['question']);
  assert r -> 'error' ->> 'code' is not null, format('an archetype passed as a register: %s', r);

  -- The check-in normalises to the first of the month, whatever day she answers.
  r := public.set_content_checkin('cccccccc-0000-0000-0000-0000000000e1','2026-10-14',
        'Burnout.','waitlist', null);
  assert r ? 'saved_at', format('check-in refused: %s', r);
  assert (select month from public.content_checkins
           where brand_kit_id='cccccccc-0000-0000-0000-0000000000e1') = date '2026-10-01';
end $$;

-- ---------------------------------------------------------------------------
-- 2. The meter
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  reset role;

  r := public.reserve_content_image('cccccccc-0000-0000-0000-0000000000e1','2026-10-01', 60);
  assert (r ->> 'ok')::boolean, format('first reserve failed: %s', r);
  r := public.reserve_content_image('cccccccc-0000-0000-0000-0000000000e1','2026-10-01', 40);
  assert (r ->> 'ok')::boolean, format('second reserve failed: %s', r);

  -- 100 of 100 reserved. One more cent is refused, atomically -- there is no
  -- post-purchase refund primitive, so an overspend cannot be undone.
  r := public.reserve_content_image('cccccccc-0000-0000-0000-0000000000e1','2026-10-01', 1);
  assert not (r ->> 'ok')::boolean and r ->> 'reason' = 'budget_exhausted',
    format('the meter overspent: %s', r);

  r := public.settle_content_image('cccccccc-0000-0000-0000-0000000000e1','2026-10-01', 60, true);
  assert (r ->> 'ok')::boolean and r ->> 'reason' = 'settled', format('%s', r);
  r := public.settle_content_image('cccccccc-0000-0000-0000-0000000000e1','2026-10-01', 40, false);
  assert (r ->> 'ok')::boolean and r ->> 'reason' = 'released', format('%s', r);

  assert (select reserved_cents from public.content_image_allowance
           where brand_kit_id='cccccccc-0000-0000-0000-0000000000e1') = 0,
         'a settled and a released reservation did not both clear';
  assert (select used_cents from public.content_image_allowance
           where brand_kit_id='cccccccc-0000-0000-0000-0000000000e1') = 60,
         'only the successful call should have become spend';

  -- ⚠ A DIFFERENT MONTH HAS ITS OWN FULL ALLOWANCE. The reset is structural:
  --   November has no row, so October's spend cannot reach it. This is what
  --   keeps a recurring allowance from behaving like the kit's lifetime pot.
  r := public.get_content_image_allowance('cccccccc-0000-0000-0000-0000000000e1','2026-11-01');
  assert (r ->> 'remaining_cents')::int = 100, format('November did not start full: %s', r);
  r := public.get_content_image_allowance('cccccccc-0000-0000-0000-0000000000e1','2026-10-01');
  assert (r ->> 'remaining_cents')::int = 40, format('October remaining is wrong: %s', r);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Spending is server-only
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('authenticated',
    'public.reserve_content_image(uuid, date, integer)', 'execute'),
    'a browser session can reserve image spend';
  assert not has_function_privilege('authenticated',
    'public.settle_content_image(uuid, date, integer, boolean)', 'execute'),
    'a browser session can settle image spend';
  assert has_function_privilege('authenticated',
    'public.get_content_image_allowance(uuid, date)', 'execute'),
    'she cannot read her own allowance';
  assert not has_function_privilege('anon',
    'public.set_content_preferences(uuid, smallint, text[], text)', 'execute'),
    'anon can write preferences';
end $$;

rollback;
