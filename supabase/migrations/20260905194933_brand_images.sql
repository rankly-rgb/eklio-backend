-- ============================================================================
-- Eklio — brand_images: seven generated photographs per PAID kit
-- ============================================================================
-- Borrows the shape of `direction_assets` (20260901074421) — claim under a row
-- lock, an opaque claim token, reserve-at-claim / reconcile-at-settle against a
-- per-day row — and deliberately does NOT touch it. Two image systems now
-- exist: that one is free, pre-purchase, per direction, and dormant; this one
-- is paid, post-purchase, per slot, and live. Unifying them is a later
-- chantier's decision.
--
-- FOUR DELIBERATE DEPARTURES FROM WHAT WAS BORROWED
-- --------------------------------------------------
-- 1. REFUSAL IS RECORDED. `direction_assets` records nothing when the cap
--    refuses, so a gradient caused by the ceiling is indistinguishable from a
--    slot nothing ever ran. Here a cap refusal writes status='refused_cap'
--    with a failure_reason: a gradient is always explainable.
-- 2. MODERATION IS ITS OWN TERMINAL OUTCOME. A content-policy refusal is a
--    PROMPT defect, not a transient error. status='moderated' is never
--    reclaimed, never retried, and surfaces to an operator. 'failed' (a
--    timeout, a 5xx) stays retryable by a later call, which is the other half
--    of the same distinction.
-- 3. THE RESERVATION REMEMBERS ITS OWN DAY. `reserved_on` is stamped at claim
--    time and released against, instead of deriving the day from
--    `claimed_at::date`. A claim reclaimed across midnight released against
--    the wrong day's row in the borrowed design.
-- 4. THE CALLER IS `authenticated`, NOT `service_role`. `direction_assets` is
--    pipeline-internal, so trusting a caller-supplied cap was safe there. Here
--    the route handler runs as the therapist (this product forbids
--    service_role in a user-facing route), so a forged call could pass
--    cap=999999999, estimate=0 and mint images on our account. The cap and the
--    per-image floor therefore have HARD server-side bounds in app_settings
--    that the caller can only tighten, never loosen. The caller still supplies
--    the real numbers — OpenAI's price stays in one place, next to the key.
-- ============================================================================


-- ============================================================================
-- 1. Config — the kill switch and the two bounds a caller cannot loosen
-- ============================================================================
-- app_settings is revoked from anon/authenticated; only SECURITY DEFINER
-- functions read it. Flipping the kill switch is a row update, not a deploy,
-- and it is enforced in the database rather than in the frontend — a switch
-- that only the caller honours is not a switch.
insert into public.app_settings (key, value) values
  ('brand_images_enabled',             'true'),
  ('brand_images_daily_cap_cents',     '2000'),
  ('brand_images_min_estimate_cents',  '4')
on conflict (key) do nothing;

create or replace function public.brand_images_setting_int(p_key text, p_fallback integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (value #>> '{}')::integer from public.app_settings where key = p_key), p_fallback)
$$;

comment on function public.brand_images_setting_int(text, integer) is
  'Reads one integer setting, falling back to a conservative literal if the row is missing. The fallback is deliberately restrictive: a deleted setting must tighten the budget, never remove it.';

create or replace function public.brand_images_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- Absent or unparseable reads as OFF. The permissive default is the one
  -- failure this switch exists to prevent.
  select coalesce((select value = 'true'::jsonb from public.app_settings where key = 'brand_images_enabled'), false)
$$;

comment on function public.brand_images_enabled() is
  'The kill switch. Off (or missing) means brand_images_claim refuses every claim and the product renders its gradient. Enforced here rather than in eklio-frontend so it cannot be bypassed by calling the RPC directly.';

grant execute on function public.brand_images_enabled() to authenticated, service_role;


-- ============================================================================
-- 2. brand_images — one row per (brand_kit, slot)
-- ============================================================================
create table public.brand_images (
  id                uuid        not null default gen_random_uuid(),
  brand_kit_id      uuid        not null,
  user_id           uuid,
  slot              text        not null,
  status            text        not null default 'pending',
  image_fingerprint text        not null,
  model             text        not null default '',
  quality           text        not null default '',
  size              text        not null default '',
  storage_path      text,
  byte_size         integer,
  cost_cents        integer,
  reserved_cents    integer,
  reserved_on       date,
  failure_reason    text        not null default '',
  attempts          integer     not null default 0,
  claimed_at        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint brand_images_pkey primary key (id),
  constraint brand_images_brand_kit_id_fkey foreign key (brand_kit_id)
    references public.brand_kits (id) on delete cascade,
  constraint brand_images_slot_check check (slot in
    ('hero','ambient_a','ambient_b','post_bg_1','post_bg_2','post_bg_3','texture')),
  constraint brand_images_status_check check (status in
    ('pending','claimed','ready','failed','moderated','refused_cap')),
  constraint brand_images_unique_slot unique (brand_kit_id, slot)
);

comment on table public.brand_images is
  'One generated photograph slot per (brand_kit_id, slot). Only status=''ready'' with an image_fingerprint matching the kit''s current one is ever exposed as an image; every other state is the gradient placeholder, and every other state says WHY it is one.';
comment on column public.brand_images.status is
  'pending (row exists, nothing run) | claimed (in flight) | ready | failed (transient, retryable by a later call) | moderated (content policy refused the prompt -- TERMINAL, never retried, an operator must see it) | refused_cap (the daily ceiling refused it -- retryable tomorrow).';
comment on column public.brand_images.failure_reason is
  'Why this slot is not an image, in words. Never empty for failed/moderated/refused_cap. This is the column direction_assets lacks, and lacking it is why a gradient there is unexplainable after the fact.';
comment on column public.brand_images.reserved_on is
  'The spend day this row''s reservation was booked against. Released against THIS date, never claimed_at::date -- a claim reclaimed across midnight would otherwise release against the wrong day.';
comment on column public.brand_images.image_fingerprint is
  'From computeImageFingerprint (eklio-frontend, lib/images/fingerprint.ts): direction, the six colour roles, specialty, city, state, IMAGE_PROMPT_VERSION. Deliberately NOT the asset fingerprint, which covers copy this prompt never reads.';

create index brand_images_brand_kit_id_idx on public.brand_images using btree (brand_kit_id);

alter table public.brand_images enable row level security;

-- Read-only, owner-scoped. Every write goes through the functions below, which
-- are SECURITY DEFINER and gate on brand_kit_entitled() -- there is no INSERT
-- or UPDATE policy for authenticated, on purpose.
create policy "brand_images_select_own"
  on public.brand_images
  for select
  to authenticated
  using (
    exists (
      select 1
        from public.brand_kits bk
        join public.projects pr on pr.id = bk.project_id
       where bk.id = brand_images.brand_kit_id
         and pr.user_id = (select auth.uid())
    )
  );


-- ============================================================================
-- 3. brand_image_daily_spend — the ceiling, one row per day
-- ============================================================================
create table public.brand_image_daily_spend (
  spend_date     date    not null default current_date,
  reserved_cents integer not null default 0,
  actual_cents   integer not null default 0,
  constraint brand_image_daily_spend_pkey primary key (spend_date),
  constraint brand_image_daily_spend_reserved_check check (reserved_cents >= 0),
  constraint brand_image_daily_spend_actual_check check (actual_cents >= 0)
);

comment on table public.brand_image_daily_spend is
  'One row per calendar day. reserved_cents bounds in-flight plus settled spend and is what the cap is checked against, so concurrent claims cannot all sail under the ceiling together; actual_cents is the real billed total.';

alter table public.brand_image_daily_spend enable row level security;
revoke all on table public.brand_image_daily_spend from anon, authenticated;


-- ============================================================================
-- 4. brand_images_path — the only place an image path is built
-- ============================================================================
-- First segment is the brand_kit_id, so the EXISTING brand-assets storage
-- policies (20260903090000 §3.3, via brand_kit_asset_path_owner) authorize
-- these objects unchanged: owned AND entitled. No new bucket, no new policy.
create or replace function public.brand_images_path(
  p_brand_kit_id uuid,
  p_image_fingerprint text,
  p_slot text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select format('%s/images/%s/%s.webp', p_brand_kit_id::text, p_image_fingerprint, p_slot)
$$;

comment on function public.brand_images_path(uuid, text, text) is
  'The storage path for one generated photograph. webp, not png: these are photographs, and the deterministic renders (wordmarks, monograms, favicons) keep their own SVG/PNG paths under the same bucket.';

grant execute on function public.brand_images_path(uuid, text, text) to authenticated, service_role;

-- The bucket predates photography and allowed only SVG and PNG.
update storage.buckets
   set allowed_mime_types = array['image/svg+xml', 'image/png', 'image/webp']
 where id = 'brand-assets';


-- ============================================================================
-- 5. brand_kit_has_generation_credit — the advisory pre-check
-- ============================================================================
-- Regeneration consumes a credit; an initial slot does not. The brief asks for
-- the credit to be "checked before the call and not charged on failure", and
-- there is no post-purchase refund primitive (release_generation_credit only
-- works while brand_kits.directions is still null). So: this read-only check
-- refuses BEFORE any money is spent, and the atomic consume_generation_credit
-- happens only once the image is recorded ready. This function is advisory --
-- two concurrent regenerations could both pass it -- and the atomic consume
-- plus the per-slot claim lock are what actually decide.
create or replace function public.brand_kit_has_generation_credit(p_brand_kit_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_project     uuid;
  v_regen_limit smallint;
  v_generated   integer;
  v_used        integer;
begin
  select bk.project_id into v_project
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
   where bk.id = p_brand_kit_id
     and pr.user_id = (select auth.uid());
  if v_project is null then
    return false;
  end if;

  select gc.directions_generated, gc.regenerations_used, pl.regenerations_limit
    into v_generated, v_used, v_regen_limit
    from public.generation_credits gc
    join public.plans pl on pl.tier = gc.plan_tier
   where gc.project_id = v_project;

  -- No row yet means nothing has ever been generated on this project, which
  -- consume_generation_credit treats as the free first run.
  if v_generated is null then
    return true;
  end if;

  return v_generated = 0 or v_used < v_regen_limit;
end;
$$;

comment on function public.brand_kit_has_generation_credit(uuid) is
  'Advisory: whether consume_generation_credit would currently succeed. For refusing a paid regeneration BEFORE spending money at OpenAI. Never a substitute for consume_generation_credit, which is the only correct way to actually spend one.';

revoke execute on function public.brand_kit_has_generation_credit(uuid) from public, anon;
grant execute on function public.brand_kit_has_generation_credit(uuid) to authenticated, service_role;


-- ============================================================================
-- 6. brand_images_claim — the one atomic decision point
-- ============================================================================
-- Returns jsonb: {"claimed": bool, "reason": text, "image_id": uuid|null,
--                 "claim_token": timestamptz|null}
--   'claimed'          - fresh reservation made, go generate
--   'reclaimed'        - a stale claim's reservation was reused, go generate
--   'already_ready'    - this exact fingerprint already has an image
--   'already_moderated'- this exact prompt was refused by content policy; TERMINAL
--   'busy'             - another invocation is actively working this slot
--   'budget_exceeded'  - the daily ceiling refused it; recorded on the row
--   'disabled'         - the kill switch is off
--   'payment_required' - not her kit, or not paid for
--
-- 'failed' and 'refused_cap' are deliberately NOT terminal: a timeout or a
-- ceiling reached yesterday must not permanently cost her a slot. Only
-- 'moderated' is, because only a moderation refusal means the PROMPT is wrong,
-- and retrying a wrong prompt just spends money to be refused again.
create or replace function public.brand_images_claim(
  p_brand_kit_id        uuid,
  p_slot                text,
  p_image_fingerprint   text,
  p_cost_estimate_cents integer,
  p_daily_cap_cents     integer,
  p_reclaim_after       interval default interval '10 minutes'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_row      public.brand_images%rowtype;
  v_reserved boolean;
  v_token    timestamptz;
  v_estimate integer;
  v_cap      integer;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('claimed', false, 'reason', 'payment_required',
                              'image_id', null, 'claim_token', null);
  end if;

  -- Checked BEFORE the upsert, so a switched-off product leaves no rows behind.
  if not public.brand_images_enabled() then
    return jsonb_build_object('claimed', false, 'reason', 'disabled',
                              'image_id', null, 'claim_token', null);
  end if;

  if p_image_fingerprint !~ '^[0-9a-f]{16,128}$' then
    return jsonb_build_object('claimed', false, 'reason', 'invalid_field',
                              'image_id', null, 'claim_token', null);
  end if;

  -- The caller may only TIGHTEN the bounds, never loosen them. See §4 of this
  -- migration's header: the caller here is the therapist's own session.
  v_cap      := least(coalesce(p_daily_cap_cents, 0),
                      public.brand_images_setting_int('brand_images_daily_cap_cents', 0));
  v_estimate := greatest(coalesce(p_cost_estimate_cents, 0),
                         public.brand_images_setting_int('brand_images_min_estimate_cents', 4));

  insert into public.brand_images (brand_kit_id, user_id, slot, status, image_fingerprint)
  values (p_brand_kit_id, (select auth.uid()), p_slot, 'pending', p_image_fingerprint)
  on conflict (brand_kit_id, slot) do nothing;

  select * into v_row
    from public.brand_images
   where brand_kit_id = p_brand_kit_id and slot = p_slot
   for update;

  if v_row.status = 'ready' and v_row.image_fingerprint = p_image_fingerprint then
    return jsonb_build_object('claimed', false, 'reason', 'already_ready',
                              'image_id', v_row.id, 'claim_token', null);
  end if;

  if v_row.status = 'moderated' and v_row.image_fingerprint = p_image_fingerprint then
    return jsonb_build_object('claimed', false, 'reason', 'already_moderated',
                              'image_id', v_row.id, 'claim_token', null);
  end if;

  if v_row.status = 'claimed' and v_row.claimed_at >= clock_timestamp() - p_reclaim_after then
    return jsonb_build_object('claimed', false, 'reason', 'busy',
                              'image_id', v_row.id, 'claim_token', null);
  end if;

  v_token := clock_timestamp();

  -- Budget-neutral reclaim: the dead invocation's reservation is inherited,
  -- along with the day it was booked against, rather than booked a second time.
  if v_row.status = 'claimed' then
    update public.brand_images
       set claimed_at = v_token, image_fingerprint = p_image_fingerprint,
           attempts = attempts + 1, updated_at = now()
     where id = v_row.id;
    return jsonb_build_object('claimed', true, 'reason', 'reclaimed',
                              'image_id', v_row.id, 'claim_token', v_token);
  end if;

  insert into public.brand_image_daily_spend (spend_date, reserved_cents, actual_cents)
  values (current_date, 0, 0)
  on conflict (spend_date) do nothing;

  -- ⚠ ONE STATEMENT. Check and increment together, or two concurrent claims
  -- both read an under-cap total and both add to it.
  update public.brand_image_daily_spend
     set reserved_cents = reserved_cents + v_estimate
   where spend_date = current_date
     and reserved_cents + v_estimate <= v_cap
  returning true into v_reserved;

  if coalesce(v_reserved, false) is not true then
    -- Recorded, not merely refused: this is the whole point of the departure.
    update public.brand_images
       set status = 'refused_cap',
           failure_reason = format('daily image budget reached (cap %s cents)', v_cap),
           image_fingerprint = p_image_fingerprint,
           updated_at = now()
     where id = v_row.id;
    return jsonb_build_object('claimed', false, 'reason', 'budget_exceeded',
                              'image_id', v_row.id, 'claim_token', null);
  end if;

  update public.brand_images
     set status = 'claimed', claimed_at = v_token, image_fingerprint = p_image_fingerprint,
         reserved_cents = v_estimate, reserved_on = current_date,
         failure_reason = '', attempts = attempts + 1, updated_at = now()
   where id = v_row.id;

  return jsonb_build_object('claimed', true, 'reason', 'claimed',
                            'image_id', v_row.id, 'claim_token', v_token);
end;
$$;

comment on function public.brand_images_claim(uuid, text, text, integer, integer, interval) is
  'Atomically claims one photograph slot, or refuses having reserved nothing. The caller supplies the cost estimate and the daily cap; both are clamped against app_settings bounds the caller cannot loosen, because unlike direction_assets_claim this one is reachable by the therapist''s own session.';

revoke execute on function public.brand_images_claim(uuid, text, text, integer, integer, interval) from public, anon;
grant execute on function public.brand_images_claim(uuid, text, text, integer, integer, interval) to authenticated, service_role;


-- ============================================================================
-- 7. brand_images_mark_ready / _mark_failed — settle a claim, once
-- ============================================================================
-- Both act only `where status = 'claimed' and claimed_at = p_claim_token`, so
-- an invocation that lost its claim to a reclaim and finishes late writes zero
-- rows and is told so. A stale writer is refused, never believed.
create or replace function public.brand_images_mark_ready(
  p_image_id     uuid,
  p_claim_token  timestamptz,
  p_storage_path text,
  p_byte_size    integer,
  p_cost_cents   integer,
  p_model        text,
  p_quality      text,
  p_size         text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_kit      uuid;
  v_expected text;
  v_slot     text;
  v_reserved integer;
  v_day      date;
begin
  select brand_kit_id, image_fingerprint, slot into v_kit, v_expected, v_slot
    from public.brand_images where id = p_image_id;
  if v_kit is null or not public.brand_kit_entitled(v_kit) then
    return jsonb_build_object('ok', false, 'reason', 'payment_required');
  end if;

  -- The path is recomputed, never trusted: the caller could otherwise record
  -- one kit's row pointing at another kit's object.
  if p_storage_path <> public.brand_images_path(v_kit, v_expected, v_slot) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_field');
  end if;

  if p_byte_size is null or p_byte_size <= 0 or p_cost_cents is null or p_cost_cents < 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_field');
  end if;

  update public.brand_images
     set status = 'ready', storage_path = p_storage_path, byte_size = p_byte_size,
         cost_cents = p_cost_cents, model = p_model, quality = p_quality, size = p_size,
         failure_reason = '', updated_at = now()
   where id = p_image_id
     and status = 'claimed'
     and claimed_at = p_claim_token
  returning reserved_cents, reserved_on into v_reserved, v_day;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'stale_claim');
  end if;

  update public.brand_image_daily_spend
     set reserved_cents = greatest(0, reserved_cents - coalesce(v_reserved, 0)),
         actual_cents   = actual_cents + p_cost_cents
   where spend_date = v_day;

  return jsonb_build_object('ok', true, 'reason', 'ready');
end;
$$;

comment on function public.brand_images_mark_ready(uuid, timestamptz, text, integer, integer, text, text, text) is
  'Settles a claim as ready, reconciling its reservation to the price the caller charged itself. Recomputes the storage path rather than trusting it, and releases against reserved_on -- the day the reservation was actually booked.';

revoke execute on function public.brand_images_mark_ready(uuid, timestamptz, text, integer, integer, text, text, text) from public, anon;
grant execute on function public.brand_images_mark_ready(uuid, timestamptz, text, integer, integer, text, text, text) to authenticated, service_role;

create or replace function public.brand_images_mark_failed(
  p_image_id       uuid,
  p_claim_token    timestamptz,
  p_status         text,
  p_failure_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_kit      uuid;
  v_reserved integer;
  v_day      date;
begin
  if p_status not in ('failed', 'moderated') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_field');
  end if;
  if coalesce(p_failure_reason, '') = '' then
    -- A failure without a reason is the defect this table exists to avoid.
    return jsonb_build_object('ok', false, 'reason', 'invalid_field');
  end if;

  select brand_kit_id into v_kit from public.brand_images where id = p_image_id;
  if v_kit is null or not public.brand_kit_entitled(v_kit) then
    return jsonb_build_object('ok', false, 'reason', 'payment_required');
  end if;

  update public.brand_images
     set status = p_status, failure_reason = left(p_failure_reason, 500), updated_at = now()
   where id = p_image_id
     and status = 'claimed'
     and claimed_at = p_claim_token
  returning reserved_cents, reserved_on into v_reserved, v_day;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'stale_claim');
  end if;

  -- Released against the day it was BOOKED on, not today.
  update public.brand_image_daily_spend
     set reserved_cents = greatest(0, reserved_cents - coalesce(v_reserved, 0))
   where spend_date = v_day;

  return jsonb_build_object('ok', true, 'reason', p_status);
end;
$$;

comment on function public.brand_images_mark_failed(uuid, timestamptz, text, text) is
  'Settles a claim as failed (transient -- a later call may try again) or moderated (terminal -- the prompt was refused and retrying it just spends money to be refused again). Refuses an empty reason: an unexplained gradient is the defect this table was shaped to prevent.';

revoke execute on function public.brand_images_mark_failed(uuid, timestamptz, text, text) from public, anon;
grant execute on function public.brand_images_mark_failed(uuid, timestamptz, text, text) to authenticated, service_role;


-- ============================================================================
-- 8. get_brand_images — the read path
-- ============================================================================
create or replace function public.get_brand_images(
  p_brand_kit_id uuid,
  p_image_fingerprint text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required', 'message', 'This brand kit is not yet paid for.'));
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'slot', i.slot,
      'status', i.status,
      'failure_reason', i.failure_reason,
      'storage_path', i.storage_path,
      'byte_size', i.byte_size,
      'cost_cents', i.cost_cents,
      'created_at', i.created_at,
      'updated_at', i.updated_at,
      -- The permissive default, refused: only ready AND current is an image.
      'current', (i.status = 'ready' and i.image_fingerprint = p_image_fingerprint)
    ) order by i.slot)
    from public.brand_images i
    where i.brand_kit_id = p_brand_kit_id
  ), '[]'::jsonb);
end;
$$;

comment on function public.get_brand_images(uuid, text) is
  'Every slot with its state and, for a ready image at the CURRENT fingerprint, its storage path. Anything else is the gradient -- and carries failure_reason so the gradient is explainable.';

revoke execute on function public.get_brand_images(uuid, text) from public, anon;
grant execute on function public.get_brand_images(uuid, text) to authenticated, service_role;
