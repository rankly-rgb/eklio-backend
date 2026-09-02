-- ============================================================================
-- Eklio — direction_assets: one ambiance image per direction, billed once
-- ============================================================================
-- Backs Part A2 of the reveal ceremony: each of a brief's three directions
-- gets one photoreal "ambiance" image (gpt-image-1), generated once, shown in
-- place of the current CSS-gradient block once ready.
--
-- WHERE THE OPENAI CALL LIVES, AND WHY IT IS NOT HERE
-- ----------------------------------------------------
-- This repo's own README draws the line: eklio-frontend owns every external
-- API call, every LLM call, and "toute orchestration planifiée" — it holds
-- OPENAI_API_KEY and SUPABASE_SERVICE_ROLE_KEY, and this repo writes only the
-- result. So nothing here calls OpenAI. What lives here is the part that has
-- to be correct under concurrency and crashes, which SQL is good at and a
-- serverless function is not: claiming a slot exactly once, bounding total
-- spend across every concurrent invocation, and making a half-finished
-- attempt safe to retake.
--
-- THE THREE FAILURE MODES THIS SCHEMA IS SHAPED AROUND
-- ------------------------------------------------------
-- 1. Two concurrent pipeline runs for the same brief must not generate (and
--    bill) the same slot twice. Solved by claiming under a row lock, the same
--    single-UPDATE-with-WHERE technique `consume_generation_credit` uses.
-- 2. A serverless invocation can die mid-call (function timeout, cold start
--    eviction, a deploy) holding a claim forever. Solved by `claimed_at` plus
--    a reclaim window passed in by the caller: past the window, a fresh claim
--    may retake the SAME reservation rather than booking a second one — see
--    the "budget-neutral reclaim" branch in `direction_assets_claim` below.
-- 3. The invocation that lost its claim to a reclaim can still be running,
--    and must not be able to overwrite the winner's result when it finally
--    finishes. Solved by returning `claimed_at` as an opaque claim token:
--    `direction_assets_mark_ready`/`_mark_failed` only act
--    `WHERE claimed_at = p_claim_token`, so a stale caller's write is a
--    no-op, never a clobber.
--
-- REGENERATION AND THE PALETTE HASH
-- ----------------------------------
-- A direction's palette can change on regeneration (same brand_kit_id, same
-- direction_index, new colours). An ambiance image tinted for the old
-- palette is a visible defect once that happens — worse than the gradient it
-- would otherwise replace. So `palette_hash` records which palette the
-- stored asset was generated for; `brand_kit_reveal_get` (next migration)
-- exposes `ambiance_url` only when the stored hash matches the direction's
-- current palette, and the claim function treats a hash mismatch on a
-- ready/failed row as a brand-new job — reserved against the cap like any
-- other — rather than as "done" or "permanently failed". The stale image
-- object itself is left in storage; deleting it is a cleanup concern, not a
-- correctness one.
--
-- THE PERMISSIVE-DEFAULT DISCIPLINE, APPLIED HERE
-- --------------------------------------------------
-- Per this repo's own README: an absent row or a NULL status must never be
-- readable as "ready". `status` is `not null default 'pending'`, there is no
-- path that creates a row without a status, and `brand_kit_reveal_get` will
-- require `status = 'ready'` (never `status is distinct from 'failed'` or
-- any other permissive shape) before it exposes a URL.
-- ============================================================================


-- ============================================================================
-- 1. direction_assets — one row per (brand_kit, direction slot, kind)
-- ============================================================================
create table public.direction_assets (
  id              uuid        not null default gen_random_uuid(),
  brand_kit_id    uuid        not null,
  direction_index smallint    not null,
  kind            text        not null default 'ambiance',
  status          text        not null default 'pending',
  palette_hash    text,
  storage_path    text,
  url             text,
  cost_cents      integer,
  reserved_cents  integer,
  claimed_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint direction_assets_pkey primary key (id),
  constraint direction_assets_brand_kit_id_fkey foreign key (brand_kit_id)
    references public.brand_kits (id) on delete cascade,
  constraint direction_assets_direction_index_check
    check (direction_index between 0 and 2),
  constraint direction_assets_kind_check
    check (kind = 'ambiance'),
  constraint direction_assets_status_check
    check (status in ('pending', 'claimed', 'ready', 'failed')),
  constraint direction_assets_unique_slot
    unique (brand_kit_id, direction_index, kind)
);

comment on table public.direction_assets is
  'One ambiance image slot per (brand_kit_id, direction_index). status=''ready'' with a palette_hash matching the direction''s current palette is the only state brand_kit_reveal_get exposes as a URL; everything else — pending, claimed, failed, or a stale hash — is silently a gradient.';
comment on column public.direction_assets.palette_hash is
  'Deterministic hash of the palette (primary/secondary/light/dark/paper + accent if present) the stored asset was generated for. A regenerated direction with a different hash is treated as a fresh, unbilled slot, not as already done or already failed.';
comment on column public.direction_assets.reserved_cents is
  'The daily-budget reservation this row is currently holding, set when claimed. Released back to direction_asset_daily_spend by whichever of mark_ready/mark_failed next succeeds against this row''s claim token — exactly once, never on a stale reclaim.';

create index direction_assets_brand_kit_id_idx
  on public.direction_assets using btree (brand_kit_id);

alter table public.direction_assets enable row level security;

-- Defense in depth only: the real read path is brand_kit_reveal_get()
-- (SECURITY DEFINER, next migration), which does not depend on this policy.
-- No INSERT/UPDATE policy exists for anon/authenticated on purpose — every
-- write goes through the claim/mark functions below, service_role only.
create policy "direction_assets_select_own"
  on public.direction_assets
  for select
  to authenticated
  using (
    exists (
      select 1
        from public.brand_kits bk
        join public.projects pr on pr.id = bk.project_id
       where bk.id = direction_assets.brand_kit_id
         and pr.user_id = (select auth.uid())
    )
  );


-- ============================================================================
-- 2. direction_asset_daily_spend — the global cost cap, one row per day
-- ============================================================================
-- `reserved_cents` is booked at claim time (an estimate, passed in by the
-- caller since only eklio-frontend knows OpenAI's current price) and
-- reconciled down as each claim resolves; `actual_cents` only ever grows, and
-- only by what a real, successful generation cost. The cap is enforced
-- against `reserved_cents` — in-flight spend counts against the budget the
-- moment it starts, not only once it is known to have succeeded, which is
-- what keeps concurrent claims from all sailing under the cap together.
create table public.direction_asset_daily_spend (
  spend_date     date    not null default current_date,
  reserved_cents integer not null default 0,
  actual_cents   integer not null default 0,
  constraint direction_asset_daily_spend_pkey primary key (spend_date),
  constraint direction_asset_daily_spend_reserved_check check (reserved_cents >= 0),
  constraint direction_asset_daily_spend_actual_check check (actual_cents >= 0)
);

comment on table public.direction_asset_daily_spend is
  'One row per calendar day. reserved_cents bounds in-flight + completed spend against the caller-supplied daily cap; actual_cents is the real, billed total. Past the cap, direction_assets_claim refuses to claim and the caller renders a gradient.';


-- ============================================================================
-- 3. direction_assets_claim — the one atomic decision point
-- ============================================================================
-- Returns jsonb: {"claimed": boolean, "reason": text, "asset_id": uuid,
-- "claim_token": timestamptz|null}. `reason` is one of:
--   'claimed'         - fresh reservation made, go generate
--   'reclaimed'       - a stale claim's reservation was reused, go generate
--   'already_ready'   - this exact palette already has a ready image
--   'already_failed'  - this exact palette already failed once and for all
--   'busy'            - another invocation is actively working this slot
--   'budget_exceeded' - the daily cap would be breached; render a gradient
--
-- p_cost_estimate_cents and p_daily_cap_cents are supplied by the caller
-- (eklio-frontend), which is where OpenAI's current price and the configured
-- cap actually live — this function enforces a budget, it does not know one.
create or replace function public.direction_assets_claim(
  p_brand_kit_id         uuid,
  p_direction_index      integer,
  p_palette_hash         text,
  p_cost_estimate_cents  integer,
  p_daily_cap_cents      integer,
  p_reclaim_after        interval default interval '10 minutes'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_row      public.direction_assets%rowtype;
  v_reserved boolean;
  v_token    timestamptz;
begin
  insert into public.direction_assets (brand_kit_id, direction_index, kind, status, palette_hash)
  values (p_brand_kit_id, p_direction_index, 'ambiance', 'pending', p_palette_hash)
  on conflict (brand_kit_id, direction_index, kind) do nothing;

  select * into v_row
    from public.direction_assets
   where brand_kit_id = p_brand_kit_id
     and direction_index = p_direction_index
     and kind = 'ambiance'
     for update;

  if v_row.status = 'ready' and v_row.palette_hash is not distinct from p_palette_hash then
    return jsonb_build_object('claimed', false, 'reason', 'already_ready',
                               'asset_id', v_row.id, 'claim_token', null);
  end if;
  if v_row.status = 'failed' and v_row.palette_hash is not distinct from p_palette_hash then
    return jsonb_build_object('claimed', false, 'reason', 'already_failed',
                               'asset_id', v_row.id, 'claim_token', null);
  end if;

  if v_row.status = 'claimed' and v_row.claimed_at >= clock_timestamp() - p_reclaim_after then
    return jsonb_build_object('claimed', false, 'reason', 'busy',
                               'asset_id', v_row.id, 'claim_token', null);
  end if;

  v_token := clock_timestamp();

  if v_row.status = 'claimed' then
    update public.direction_assets
       set status = 'claimed', claimed_at = v_token,
           palette_hash = p_palette_hash, updated_at = now()
     where id = v_row.id;

    return jsonb_build_object('claimed', true, 'reason', 'reclaimed',
                               'asset_id', v_row.id, 'claim_token', v_token);
  end if;

  insert into public.direction_asset_daily_spend (spend_date, reserved_cents, actual_cents)
  values (current_date, 0, 0)
  on conflict (spend_date) do nothing;

  update public.direction_asset_daily_spend
     set reserved_cents = reserved_cents + p_cost_estimate_cents
   where spend_date = current_date
     and reserved_cents + p_cost_estimate_cents <= p_daily_cap_cents
  returning true into v_reserved;

  if coalesce(v_reserved, false) is not true then
    return jsonb_build_object('claimed', false, 'reason', 'budget_exceeded',
                               'asset_id', v_row.id, 'claim_token', null);
  end if;

  update public.direction_assets
     set status = 'claimed', claimed_at = v_token, palette_hash = p_palette_hash,
         reserved_cents = p_cost_estimate_cents, updated_at = now()
   where id = v_row.id;

  return jsonb_build_object('claimed', true, 'reason', 'claimed',
                             'asset_id', v_row.id, 'claim_token', v_token);
end
$$;

comment on function public.direction_assets_claim(uuid, integer, text, integer, integer, interval) is
  'Atomically claims one ambiance-image slot, or refuses having reserved nothing. A stale claim (past p_reclaim_after) is retaken without a second reservation. Pipeline-internal: no auth.uid() involved, service_role only.';

revoke execute on function public.direction_assets_claim(uuid, integer, text, integer, integer, interval)
  from public, anon, authenticated;
grant execute on function public.direction_assets_claim(uuid, integer, text, integer, integer, interval)
  to service_role;


-- ============================================================================
-- 4. direction_assets_mark_ready / _mark_failed — settle a claim, once
-- ============================================================================
-- Both are conditioned on `status = 'claimed' and claimed_at = p_claim_token`
-- so a caller that lost its claim to a reclaim can never overwrite the
-- winner's outcome — its write matches zero rows and comes back
-- {"ok": false, "reason": "stale_claim"} rather than an error, per the same
-- "the default must not be permissive" discipline as everything else here:
-- a stale writer must be refused, not silently believed.

create or replace function public.direction_assets_mark_ready(
  p_asset_id     uuid,
  p_claim_token  timestamptz,
  p_url          text,
  p_storage_path text,
  p_cost_cents   integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_reserved integer;
  v_date     date;
begin
  update public.direction_assets
     set status = 'ready', url = p_url, storage_path = p_storage_path,
         cost_cents = p_cost_cents, updated_at = now()
   where id = p_asset_id
     and status = 'claimed'
     and claimed_at = p_claim_token
  returning reserved_cents, claimed_at::date into v_reserved, v_date;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'stale_claim');
  end if;

  update public.direction_asset_daily_spend
     set reserved_cents = greatest(0, reserved_cents - coalesce(v_reserved, 0)),
         actual_cents   = actual_cents + p_cost_cents
   where spend_date = v_date;

  return jsonb_build_object('ok', true, 'reason', 'ready');
end
$$;

comment on function public.direction_assets_mark_ready(uuid, timestamptz, text, text, integer) is
  'Settles a claim as ready, reconciling its reservation to the real cost. A no-op (ok:false) for any caller whose claim token no longer matches — reclaimed, already settled, or never claimed.';

revoke execute on function public.direction_assets_mark_ready(uuid, timestamptz, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.direction_assets_mark_ready(uuid, timestamptz, text, text, integer)
  to service_role;

create or replace function public.direction_assets_mark_failed(
  p_asset_id    uuid,
  p_claim_token timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_reserved integer;
  v_date     date;
begin
  update public.direction_assets
     set status = 'failed', updated_at = now()
   where id = p_asset_id
     and status = 'claimed'
     and claimed_at = p_claim_token
  returning reserved_cents, claimed_at::date into v_reserved, v_date;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'stale_claim');
  end if;

  update public.direction_asset_daily_spend
     set reserved_cents = greatest(0, reserved_cents - coalesce(v_reserved, 0))
   where spend_date = v_date;

  return jsonb_build_object('ok', true, 'reason', 'failed');
end
$$;

comment on function public.direction_assets_mark_failed(uuid, timestamptz) is
  'Settles a claim as permanently failed for its palette and releases its reservation. Retrying belongs to the caller (one retry on a transient error, before ever calling this) — this function only records the terminal outcome. A no-op (ok:false) for a stale claim token, same as mark_ready.';

revoke execute on function public.direction_assets_mark_failed(uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function public.direction_assets_mark_failed(uuid, timestamptz)
  to service_role;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.direction_assets_mark_failed(uuid, timestamptz);
--   drop function if exists public.direction_assets_mark_ready(uuid, timestamptz, text, text, integer);
--   drop function if exists public.direction_assets_claim(uuid, integer, text, integer, integer, interval);
--   drop policy if exists "direction_assets_select_own" on public.direction_assets;
--   drop table if exists public.direction_asset_daily_spend;
--   drop table if exists public.direction_assets;
