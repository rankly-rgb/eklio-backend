-- ============================================================================
-- Tests — 20260901074421_direction_assets.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('dddddddd-0000-0000-0000-000000000001','owner@example.com'),
  ('dddddddd-0000-0000-0000-000000000002','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('dddddddd-0000-0000-0000-000000000011','dddddddd-0000-0000-0000-000000000001','Elm & Ember');
insert into public.brand_kits (id, project_id) values
  ('dddddddd-0000-0000-0000-000000000021','dddddddd-0000-0000-0000-000000000011');

-- Estimate 40c/image, cap 100c through most of this file: room for two
-- images, not three.

-- ---------------------------------------------------------------------------
-- A fresh claim reserves against the daily cap and returns a usable token
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  spend record;
begin
  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 0, 'hash-a', 40, 100);
  assert (r->>'claimed')::boolean is true, 'a fresh claim on an empty slot was refused';
  assert r->>'reason' = 'claimed', 'a fresh claim reported the wrong reason: ' || (r->>'reason');
  assert r->>'claim_token' is not null, 'a successful claim returned no token';

  select * into spend from public.direction_asset_daily_spend where spend_date = current_date;
  assert spend.reserved_cents = 40, 'the estimate was not reserved: got ' || spend.reserved_cents;
  assert spend.actual_cents = 0, 'actual_cents moved before anything settled';

  assert (select status from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 'claimed',
         'the row was not left in claimed status';
end
$$;

-- ---------------------------------------------------------------------------
-- A second claim on the same slot, still within the window, is refused as busy
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  spend record;
begin
  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 0, 'hash-a', 40, 100);
  assert (r->>'claimed')::boolean is false, 'a live claim was taken by a second caller';
  assert r->>'reason' = 'busy', 'wrong refusal reason for a live claim: ' || (r->>'reason');

  select * into spend from public.direction_asset_daily_spend where spend_date = current_date;
  assert spend.reserved_cents = 40, 'a refused claim still reserved budget: ' || spend.reserved_cents;
end
$$;

-- ---------------------------------------------------------------------------
-- mark_ready settles the claim, reconciles the reservation, records real cost
-- ---------------------------------------------------------------------------
do $$
declare
  token timestamptz;
  r jsonb;
  spend record;
begin
  select claimed_at into token from public.direction_assets
   where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0;

  r := public.direction_assets_mark_ready(
         (select id from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0),
         token, 'https://cdn.example/a.png', 'kits/.../a.png', 37);
  assert (r->>'ok')::boolean is true, 'a valid mark_ready was refused';

  assert (select status from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 'ready',
         'status did not move to ready';
  assert (select cost_cents from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 37,
         'the real cost was not recorded';

  select * into spend from public.direction_asset_daily_spend where spend_date = current_date;
  assert spend.reserved_cents = 0, 'the reservation was not released on settle: ' || spend.reserved_cents;
  assert spend.actual_cents = 37, 'actual_cents does not reflect the real cost: ' || spend.actual_cents;
end
$$;

-- ---------------------------------------------------------------------------
-- Re-claiming the SAME palette after ready is a no-op: no image, no billing
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  spend record;
begin
  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 0, 'hash-a', 40, 100);
  assert (r->>'claimed')::boolean is false, 'an already-ready palette was reclaimed';
  assert r->>'reason' = 'already_ready', 'wrong reason for a settled, matching palette: ' || (r->>'reason');

  select * into spend from public.direction_asset_daily_spend where spend_date = current_date;
  assert spend.reserved_cents = 0, 'an already_ready refusal still reserved budget';
end
$$;

-- ---------------------------------------------------------------------------
-- PALETTE MISMATCH: a regenerated direction is a fresh, billable job
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  spend record;
begin
  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 0, 'hash-b', 40, 100);
  assert (r->>'claimed')::boolean is true, 'a regenerated direction (new palette hash) could not be claimed';
  assert r->>'reason' = 'claimed', 'a new-palette claim on a ready slot reported: ' || (r->>'reason');

  select * into spend from public.direction_asset_daily_spend where spend_date = current_date;
  assert spend.reserved_cents = 40, 'the new-palette claim did not reserve against the cap';

  assert (select status from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 'claimed',
         'the mismatched-palette row was not moved to claimed';
  assert (select palette_hash from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 'hash-b',
         'palette_hash was not updated to the new hash on claim';

  -- settle it so later tests start clean
  perform public.direction_assets_mark_ready(
    (select id from public.direction_assets
      where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0),
    (select claimed_at from public.direction_assets
      where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0),
    'https://cdn.example/a2.png', 'kits/.../a2.png', 40);
end
$$;

-- ---------------------------------------------------------------------------
-- mark_failed: released reservation, terminal for that palette, fresh for a new one
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  token timestamptz;
  spend_before record;
  spend_after record;
begin
  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 1, 'hash-a', 40, 100);
  assert (r->>'claimed')::boolean is true, 'could not claim a fresh slot for the failure test';
  token := (r->>'claim_token')::timestamptz;

  select * into spend_before from public.direction_asset_daily_spend where spend_date = current_date;

  r := public.direction_assets_mark_failed(
         (select id from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 1),
         token);
  assert (r->>'ok')::boolean is true, 'a valid mark_failed was refused';

  select * into spend_after from public.direction_asset_daily_spend where spend_date = current_date;
  assert spend_after.reserved_cents = spend_before.reserved_cents - 40,
         'mark_failed did not release its reservation';

  -- same palette: permanently failed, never retried automatically
  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 1, 'hash-a', 40, 100);
  assert (r->>'claimed')::boolean is false, 'a permanently-failed palette was reclaimed';
  assert r->>'reason' = 'already_failed', 'wrong reason for a failed, matching palette: ' || (r->>'reason');

  -- a new palette on that same slot is a fresh, billable job
  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 1, 'hash-b', 40, 100);
  assert (r->>'claimed')::boolean is true, 'a regenerated direction could not retry after a prior failure';
  assert r->>'reason' = 'claimed', 'wrong reason for a new-palette claim after failure: ' || (r->>'reason');

  perform public.direction_assets_mark_failed(
    (select id from public.direction_assets
      where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 1),
    (select claimed_at from public.direction_assets
      where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 1));
end
$$;

-- ---------------------------------------------------------------------------
-- STALE RECLAIM: past the window, the reservation is reused, never doubled
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  first_token timestamptz;
  second_token timestamptz;
  spend_before record;
  spend_after record;
begin
  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 2, 'hash-a', 40, 100);
  assert (r->>'claimed')::boolean is true, 'could not claim a fresh slot for the reclaim test';
  first_token := (r->>'claim_token')::timestamptz;

  -- simulate a dead invocation: back-date the claim past the reclaim window
  update public.direction_assets
     set claimed_at = now() - interval '11 minutes'
   where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 2;

  select * into spend_before from public.direction_asset_daily_spend where spend_date = current_date;

  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 2, 'hash-a', 40, 100,
         interval '10 minutes');
  assert (r->>'claimed')::boolean is true, 'a stale claim past its window was not reclaimable';
  assert r->>'reason' = 'reclaimed', 'wrong reason for a stale reclaim: ' || (r->>'reason');
  second_token := (r->>'claim_token')::timestamptz;
  assert second_token <> first_token, 'reclaiming did not issue a fresh claim token';

  select * into spend_after from public.direction_asset_daily_spend where spend_date = current_date;
  assert spend_after.reserved_cents = spend_before.reserved_cents,
         'a reclaim booked a SECOND reservation: budget leak';

  -- STALE-MARK GUARD: the dead invocation's late write must be a no-op
  r := public.direction_assets_mark_ready(
         (select id from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 2),
         first_token, 'https://cdn.example/stale.png', 'kits/.../stale.png', 999);
  assert (r->>'ok')::boolean is false, 'a stale claim token was allowed to settle the slot';
  assert r->>'reason' = 'stale_claim', 'wrong refusal reason for a stale token: ' || (r->>'reason');
  assert (select status from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 2) = 'claimed',
         'a stale write changed the winner''s status';
  assert (select cost_cents from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 2) is null,
         'a stale write recorded a cost nobody incurred';

  -- the winning invocation's write, with the correct token, succeeds
  r := public.direction_assets_mark_ready(
         (select id from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 2),
         second_token, 'https://cdn.example/winner.png', 'kits/.../winner.png', 40);
  assert (r->>'ok')::boolean is true, 'the winning claim token could not settle the slot';
end
$$;

-- ---------------------------------------------------------------------------
-- DAILY CAP: past the budget, a new slot is refused and stays a gradient
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
begin
  -- fresh brand kit, fresh day-independent budget check: cap exactly at what's
  -- already reserved this test run, so one more 40c estimate cannot fit.
  update public.direction_asset_daily_spend
     set reserved_cents = 40
   where spend_date = current_date;

  r := public.direction_assets_claim(
         'dddddddd-0000-0000-0000-000000000021'::uuid, 0, 'hash-c', 40, 40);
  -- index 0 already holds a ready row for hash-b; hash-c is a new palette,
  -- so this must attempt a fresh reservation and find no room.
  assert (r->>'claimed')::boolean is false, 'a claim over the daily cap was accepted';
  assert r->>'reason' = 'budget_exceeded', 'wrong refusal reason over budget: ' || (r->>'reason');

  -- A refused claim mutates nothing: no second row for the new hash gets
  -- created (there is exactly one row per slot, ever), and the existing one
  -- keeps the OLD hash/status/cost untouched — a real, unrelated palette
  -- mismatch (checked at read time, next migration) rather than anything
  -- this function invented.
  assert (select count(*) from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 1,
         'a refused claim created a second row for the same slot';
  assert (select status from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 'ready'
     and (select palette_hash from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 'hash-b'
     and (select cost_cents from public.direction_assets
           where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021' and direction_index = 0) = 40,
         'a refused claim mutated the existing ready row';
end
$$;

-- ---------------------------------------------------------------------------
-- NULL/absent safety: no row is ever left with a NULL status, and a slot
-- nobody has ever claimed simply does not exist as a row (absence, not NULL)
-- ---------------------------------------------------------------------------
do $$
declare
  rejected boolean;
begin
  assert not exists (
    select 1 from public.direction_assets
     where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021'
       and status is null),
    'a row exists with a NULL status';

  begin
    insert into public.direction_assets (brand_kit_id, direction_index, kind, status)
    values ('dddddddd-0000-0000-0000-000000000021', 0, 'ambiance', null);
    rejected := false;
  exception when not_null_violation then rejected := true;
  end;
  assert rejected, 'the table accepted a NULL status';

  -- a kit with no ambiance activity at all has no rows — brand_kit_reveal_get
  -- (next migration) must treat this the same as a stale-hash or failed row:
  -- a silent gradient, never an error or a ready state.
  insert into public.projects (id, user_id, name) values
    ('dddddddd-0000-0000-0000-000000000012','dddddddd-0000-0000-0000-000000000001','Second Kit');
  insert into public.brand_kits (id, project_id) values
    ('dddddddd-0000-0000-0000-000000000031','dddddddd-0000-0000-0000-000000000012');
  assert not exists (
    select 1 from public.direction_assets
     where brand_kit_id = 'dddddddd-0000-0000-0000-000000000031'),
    'a brand-new kit already has a direction_assets row before any claim';
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: an owner reads their own kit's assets; a stranger reads nothing
-- ---------------------------------------------------------------------------
do $$
declare
  n int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000001"}';
  select count(*) into n from public.direction_assets
   where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021';
  assert n > 0, 'the owner could not read their own kit''s direction_assets';
end
$$;

do $$
declare
  n int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000002"}';
  select count(*) into n from public.direction_assets
   where brand_kit_id = 'dddddddd-0000-0000-0000-000000000021';
  assert n = 0, 'a stranger could read another owner''s direction_assets';
end
$$;

-- ---------------------------------------------------------------------------
-- The claim/mark functions are pipeline-internal: not reachable as the user
-- ---------------------------------------------------------------------------
do $$
declare
  refused boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000001"}';

  begin
    perform public.direction_assets_claim(
      'dddddddd-0000-0000-0000-000000000021'::uuid, 0, 'hash-z', 40, 100);
    refused := false;
  exception when insufficient_privilege then refused := true;
  end;
  assert refused, 'an authenticated caller could execute direction_assets_claim directly';
end
$$;

rollback;
