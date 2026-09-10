-- ============================================================================
-- Tests — 20260910100415 + 20260910100758
-- ============================================================================
-- The on-image line is a SECOND text, not a slice of the caption. Four things,
-- in order of what it costs to get wrong:
--
--   1. THE CONTRADICTION. An item published and then unpublished must not
--      report `posted: false` beside a filled `posted_at`. This was live for
--      about three minutes; it is the reason 20260910100758 exists.
--   2. THE ROUND TRIP. She saves a line through the RPC and reads it back
--      through the json. A field the editor can write but not read is worse
--      than one it cannot write.
--   3. BLANK IS NULL. "No line" and "an empty line" are different states, and
--      only one of them is renderable.
--   4. THE CAP, and that `stable` survived.
-- ============================================================================
begin;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-0000000000f1','oit@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000f1','aaaaaaaa-0000-0000-0000-0000000000f1','P');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000f1','bbbbbbbb-0000-0000-0000-0000000000f1');

-- `content_kit_access` refuses an unpaid kit, and a `paid` purchase must carry
-- `paid_at`. Every content fixture is also a billing fixture.
insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-0000000000f1','bbbbbbbb-0000-0000-0000-0000000000f1',
        'practice','cs_test_on_image_f1', 24900, 'paid', now());

insert into public.content_items (id, brand_kit_id, archetype, status, caption)
values ('eeeeeeee-0000-0000-0000-0000000000f1','cccccccc-0000-0000-0000-0000000000f1',
        'statement','draft','A caption.');

-- ---------------------------------------------------------------------------
-- 1. Published, then unpublished
-- ---------------------------------------------------------------------------
-- ⚠ DISTINCT `occurred_at` ON PURPOSE. `now()` is transaction time, so two
--   rows inserted in one test share it exactly and the tiebreak falls to a
--   random uuid. In production these are two separate transactions. Written
--   this way so the test measures the gating, not the tiebreak -- see the note
--   at the bottom of this file.
insert into public.content_publications (content_item_id, action, channel, occurred_at)
values ('eeeeeeee-0000-0000-0000-0000000000f1','published','instagram', now() - interval '2 hours');
insert into public.content_publications (content_item_id, action, occurred_at)
values ('eeeeeeee-0000-0000-0000-0000000000f1','unpublished', now() - interval '1 hour');

do $$
declare j jsonb;
begin
  j := public.content_item_json('eeeeeeee-0000-0000-0000-0000000000f1');
  assert (j ->> 'posted') = 'false', format('posted should be false: %s', j);
  assert  j ->> 'posted_at' is null, format('a posted_at survived an unpublish: %s', j);
  assert  j ->> 'channel'   is null, format('a channel survived an unpublish: %s', j);
  assert  j ? 'on_image_text' and j ? 'register' and j ? 'month_id',
          format('a field the editor needs is missing from the json: %s', j);
end $$;

-- ---------------------------------------------------------------------------
-- 2 & 3. The round trip, and blank meaning null
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000f1"}';

  r := public.update_content_item('eeeeeeee-0000-0000-0000-0000000000f1',
        '{"on_image_text":"  Rest is not a reward for finishing.  "}'::jsonb);
  assert r ? 'saved_at', format('the line was refused: %s', r);

  reset role;
  assert public.content_item_json('eeeeeeee-0000-0000-0000-0000000000f1') ->> 'on_image_text'
         = 'Rest is not a reward for finishing.',
         'the line did not survive the round trip, or was not trimmed';

  set local role authenticated;
  r := public.update_content_item('eeeeeeee-0000-0000-0000-0000000000f1',
        '{"on_image_text":"   "}'::jsonb);
  assert r ? 'saved_at', format('a blanking patch was refused: %s', r);
  reset role;

  assert public.content_item_json('eeeeeeee-0000-0000-0000-0000000000f1') ->> 'on_image_text' is null,
         'a blanked line stored as an empty string rather than as no line';

  -- The caption is untouched by all of it. The two texts are independent, and
  -- a generator that writes one must not be able to disturb the other.
  assert (select caption from public.content_items
           where id='eeeeeeee-0000-0000-0000-0000000000f1') = 'A caption.',
         'writing the on-image line changed the caption';
end $$;

-- ---------------------------------------------------------------------------
-- 4. The cap, and `stable`
-- ---------------------------------------------------------------------------
do $$
declare v_ok boolean := false;
begin
  begin
    insert into public.content_items (brand_kit_id, archetype, status, on_image_text)
    values ('cccccccc-0000-0000-0000-0000000000f1','notes','draft', repeat('x', 481));
  exception when check_violation then
    v_ok := true;
  end;
  assert v_ok, 'a 481-character on-image line was accepted';

  -- 480 is the largest measured floor plus air; it must be reachable.
  insert into public.content_items (brand_kit_id, archetype, status, on_image_text)
  values ('cccccccc-0000-0000-0000-0000000000f1','notes','draft', repeat('x', 480));

  -- `stable` is not decoration: get_content_month is stable and calls this
  -- once per row in three places.
  assert (select p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname='public' and p.proname='content_item_json') = 's',
         'content_item_json is not stable';
end $$;

-- ---------------------------------------------------------------------------
-- KNOWN, NOT FIXED HERE: the publication log's tiebreak is a random uuid.
-- ---------------------------------------------------------------------------
-- `order by occurred_at desc, id desc` reads as if it disambiguates equal
-- timestamps. It does not: `id` is `gen_random_uuid()`. Two publications
-- sharing an `occurred_at` therefore resolve arbitrarily, and "an item is
-- posted iff its most recent row says published" is undefined for them.
--
-- It cannot happen through the product today: `mark_content_posted` refuses a
-- no-op, so the same item cannot log two rows in one transaction. Recorded
-- rather than fixed because a monotonic column on the log is a change to the
-- publishing model, which is not this migration's subject.
do $$
begin
  assert (select data_type from information_schema.columns
           where table_schema='public' and table_name='content_publications'
             and column_name='id') = 'uuid',
    'the log grew a monotonic id -- delete this note and the ordering caveat with it';
end $$;

rollback;
