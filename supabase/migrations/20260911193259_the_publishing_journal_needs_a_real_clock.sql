-- ============================================================================
-- A journal whose entries all happened at the same instant cannot be ordered
-- ============================================================================
-- `content_publications.occurred_at` defaulted to `now()`, which in PostgreSQL
-- is the START OF THE TRANSACTION and does not advance inside it. Publish and
-- unpublish in one transaction therefore carry the SAME timestamp.
--
-- Both readers order by `cp.occurred_at desc, cp.id desc` — a tiebreaker that
-- looks careful and is not: `id` is `gen_random_uuid()`, so on a tie the
-- "latest" entry is chosen by a coin flip. Measured: two rows, ONE distinct
-- `occurred_at`.
--
-- ⚠ THIS IS THE THIRD INSTANCE OF THE SAME DEFECT IN ONE DAY, and the first
-- one that is actually non-deterministic rather than merely undefined — the
-- content_items test passed one CI run and failed the next with no change
-- between them. A flaky test is worse than a failing one: it teaches people
-- to re-run instead of to read.
--
-- What it costs when it lands:
--
--   · `content_item_json` derives `posted` from the newest entry, so an item
--     she unpublished can read as published.
--   · `mark_content_posted` reads the newest entry to decide whether anything
--     changed, so an unpublish can be silently discarded as "no change", or a
--     genuine double click can write a duplicate into the log.
--
-- In production each action is its own request in its own transaction, so
-- `now()` differs and the tie does not arise. It arises in tests, in backfills
-- and in any batch that touches one item twice.
--
-- ⚠ THE FIX IS NOT A BETTER TIEBREAKER, IT IS A REAL CLOCK. `clock_timestamp()`
-- is the actual instant rather than the transaction's, and it is monotonic
-- within a transaction — which is what a JOURNAL means. `id desc` stays as a
-- final total order so that two entries written inside the same microsecond
-- still come back in a stable order.
--
-- Existing rows are untouched: this changes a default, not data.
-- ============================================================================

alter table public.content_publications
  alter column occurred_at set default clock_timestamp();

comment on column public.content_publications.occurred_at is
  'When the action actually happened. clock_timestamp(), not now(): two entries written in one transaction must be orderable, and now() is frozen for the whole transaction.';

-- ---------------------------------------------------------------------------
-- Guard rail — publish then unpublish, in ONE transaction, which is the case
-- ---------------------------------------------------------------------------
do $$
declare
  v_user uuid := gen_random_uuid();
  v_proj uuid := gen_random_uuid();
  v_kit  uuid := gen_random_uuid();
  v_item uuid := gen_random_uuid();
  v_org  uuid;
  v_n    integer;
  v_last text;
begin
  insert into auth.users (id, email) values (v_user, 'journal-guard-' || v_user || '@example.invalid');
  select m.organization_id into v_org
    from public.organization_members m where m.user_id = v_user and m.role = 'owner';
  insert into public.projects (id, user_id, name) values (v_proj, v_user, 'journal guard rail');
  insert into public.brand_kits (id, project_id) values (v_kit, v_proj);
  insert into public.content_items (id, brand_kit_id, archetype, scheduled_for)
  values (v_item, v_kit, 'signature', '2099-01-01');

  insert into public.content_publications (content_item_id, action, channel)
  values (v_item, 'published', 'instagram');
  insert into public.content_publications (content_item_id, action)
  values (v_item, 'unpublished');

  select count(distinct occurred_at) into v_n
    from public.content_publications where content_item_id = v_item;
  assert v_n = 2,
    format('two journal entries in one transaction share a timestamp (%s distinct) — the order is a coin flip', v_n);

  select cp.action into v_last
    from public.content_publications cp
   where cp.content_item_id = v_item
   order by cp.occurred_at desc, cp.id desc
   limit 1;
  assert v_last = 'unpublished',
    format('the newest journal entry reads as %L, so an unpublished item reads as published', v_last);

  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;
  assert not exists (select 1 from public.content_items where id = v_item),
    'the guard rail left its fixture behind';
end
$$;
