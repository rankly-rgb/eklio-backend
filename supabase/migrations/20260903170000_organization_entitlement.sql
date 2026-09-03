-- ============================================================================
-- Eklio — lot H: seat counting and the practice-seat entitlement chokepoint
-- ============================================================================
-- No Stripe API call, no keys, no subscriptions.quantity write. The
-- decision — is this organization allowed one more seat — lives in SQL,
-- read from data this migration adds, exactly like plans/plan_grants
-- already keeps Monthly Presence's numbers in one place rather than a
-- branch in a route (20260830062321_plans_and_granted_allowance.sql's own
-- header makes the same argument this migration follows).
--
-- ⚠ 'practice' IS ALREADY TAKEN. plans.tier already has a 'practice' row —
-- the one-time SOLO KIT quality tier (starter/practice/signature), priced
-- once, unrelated to seats. Reusing that value for a per-seat B2B product
-- would either collide with the PRIMARY KEY or silently overwrite the
-- existing kit tier's price/allowance data. The new tier is
-- 'practice_seats' — a distinct value, never confused with the kit tier
-- of the same-sounding name.
--
-- plans' existing columns (directions_limit, regenerations_limit,
-- price_cents as a ONE-TIME price) cannot express "seats included, a
-- billing floor, and a per-seat monthly price" — those are recurring,
-- per-seat concepts a one-time-kit table was never shaped for. Per the
-- brief's own instruction ("add the narrowest possible column and say
-- so"): three new NULLABLE columns, populated only for this one row,
-- rather than a second table.
-- ============================================================================

alter table public.plans drop constraint plans_tier_check;
alter table public.plans add constraint plans_tier_check
  check (tier = any (array['free', 'starter', 'practice', 'signature', 'practice_seats']));

-- purchases.tier has the same 'practice' collision — organization_entitlement
-- reads purchases.tier = 'practice_seats' below, so a purchases row of
-- that tier must be insertable at all.
alter table public.purchases drop constraint purchases_tier_check;
alter table public.purchases add constraint purchases_tier_check
  check (tier = any (array['starter', 'practice', 'signature', 'practice_seats']));

alter table public.plans add column seat_allowance smallint;
alter table public.plans add column seat_floor smallint;
alter table public.plans add column price_per_seat_cents integer;

alter table public.plans add constraint plans_seat_allowance_check
  check (seat_allowance is null or seat_allowance >= 1);
alter table public.plans add constraint plans_seat_floor_check
  check (seat_floor is null or (seat_floor >= 1 and (seat_allowance is null or seat_floor <= seat_allowance)));
alter table public.plans add constraint plans_price_per_seat_check
  check (price_per_seat_cents is null or price_per_seat_cents >= 0);
alter table public.plans add constraint plans_seat_fields_only_for_seat_tier_check
  check ((tier = 'practice_seats') = (seat_allowance is not null and seat_floor is not null and price_per_seat_cents is not null));

comment on column public.plans.seat_allowance is
  'Seats included at this tier before organization_entitlement() blocks a new invite or provisioning call. NULL for every non-seat-based tier.';
comment on column public.plans.seat_floor is
  'Minimum seats billed, even if fewer are active — the number the per-seat price in the practice landing page''s calculator (lot I) starts from.';
comment on column public.plans.price_per_seat_cents is
  'Monthly price per seat. price_cents on this same row is informational only (seat_floor billed at price_per_seat_cents) — nothing charges from either column; Stripe stays the authority on what was actually paid, same as every other plans row.';

-- >>> PRACTICE_SEATS PLAN DATA (mirrored verbatim in supabase/seed.sql) >>>
insert into public.plans
  (tier, label, price_cents, directions_limit, regenerations_limit, sort_order,
   seat_allowance, seat_floor, price_per_seat_cents)
values
  ('practice_seats', 'Practice', 14700, 1, 0, 4, 10, 3, 4900)
on conflict (tier) do update set
  label = excluded.label,
  price_cents = excluded.price_cents,
  sort_order = excluded.sort_order,
  seat_allowance = excluded.seat_allowance,
  seat_floor = excluded.seat_floor,
  price_per_seat_cents = excluded.price_per_seat_cents;
-- <<< PRACTICE_SEATS PLAN DATA <<<
--
-- directions_limit/regenerations_limit are not applicable to this row —
-- this plan grants no kit-generation allowance of its own; set to the
-- narrowest CHECK-satisfying values (1, 0) rather than left NULL, since
-- every other plans row relies on them being NOT NULL and this migration
-- does not touch that for the other three tiers.


-- ---------------------------------------------------------------------------
-- organization_seat_count — active AND invited members both count. An
-- outstanding invite is a reserved seat: an owner who has invited five
-- people has committed five seats, whether or not all five have accepted
-- yet, and the chokepoint below must not let her invite a sixth by
-- undercounting the four still pending.
-- ---------------------------------------------------------------------------
create or replace function public.organization_seat_count(p_organization_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
    from public.organization_members
   where organization_id = p_organization_id
     and status in ('active', 'invited')
$$;

comment on function public.organization_seat_count(uuid) is
  'Active AND invited members — an outstanding invite reserves a seat. SECURITY DEFINER so the count is always the true one, not narrowed by the caller''s own organization_members RLS visibility.';

revoke execute on function public.organization_seat_count(uuid) from public, anon;
grant  execute on function public.organization_seat_count(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- organization_entitlement — the practice's tier, seat count, seat
-- allowance, and per-capability booleans. Reads purchases; never writes.
--
-- Judgment call, documented rather than left implicit: clinician_profiles
-- stays available to every organization (an owner filling in her own
-- single profile costs nothing and needs no purchase) — grid and
-- setup_sheets, the multi-clinician value-add features field research
-- named as what the practice tier is actually sold on, require an active
-- practice_seats purchase. charter is left available to every
-- organization too: nothing in this schema gates it on a purchase today,
-- and this lot does not add that gate on its own initiative.
-- ---------------------------------------------------------------------------
create or replace function public.organization_entitlement(p_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_seat_count int;
  v_purchased  boolean;
  v_plan       public.plans%rowtype;
begin
  v_seat_count := public.organization_seat_count(p_organization_id);

  select exists (
    select 1 from public.purchases pu
     where pu.organization_id = p_organization_id
       and pu.tier = 'practice_seats'
       and pu.status = any (public.brand_kit_entitling_statuses())
  ) into v_purchased;

  select * into v_plan from public.plans where tier = 'practice_seats';

  return jsonb_build_object(
    'tier', case when v_purchased then 'practice_seats' else 'free' end,
    'seat_count', v_seat_count,
    -- An organization with no practice_seats purchase is entitled to
    -- exactly the one seat its own owner already occupies.
    'seat_allowance', case when v_purchased then v_plan.seat_allowance else 1 end,
    'capabilities', jsonb_build_object(
      'charter', true,
      'clinician_profiles', true,
      'grid', v_purchased,
      'setup_sheets', v_purchased
    )
  );
end;
$$;

comment on function public.organization_entitlement(uuid) is
  'The one place a seat-allowance decision is read from. Reads purchases (a practice_seats row, entitling status) and plans; never writes. Used as the single chokepoint by create_org_invite and provision_clinician_project — no other route or component re-derives this.';

revoke execute on function public.organization_entitlement(uuid) from public, anon;
grant  execute on function public.organization_entitlement(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- The chokepoint itself: create_org_invite (lot 1,
-- 20260903102500_org_invite_rpcs.sql) and provision_clinician_project
-- (lot E1, 20260903150000_clinician_project_provisioning.sql) each gain
-- one check, right after their existing authorization checks and before
-- they commit to a new seat. Named, greppable error text
-- ('seat_allowance_exceeded') so the frontend can show a specific message
-- instead of a raw Postgres error — never a silent cap and never a
-- generic failure.
-- ---------------------------------------------------------------------------
-- CREATE OR REPLACE with the EXACT original signature — (uuid, citext,
-- uuid), not (uuid, text, uuid). Postgres overloads by parameter type;
-- getting this wrong would create a second, parallel function instead of
-- replacing the original, leaving the un-gated version still live. Every
-- line below except the new entitlement check is unchanged from
-- 20260903110000_pgcrypto_schema_resolution.sql's version.
create or replace function public.create_org_invite(
  p_org_id     uuid,
  p_email      citext,
  p_project_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email       text;
  v_raw_token   text;
  v_token_hash  text;
  v_entitlement jsonb;
begin
  if not public.is_org_owner(p_org_id) then
    raise exception 'create_org_invite: % is not an active owner of organization %', auth.uid(), p_org_id;
  end if;

  v_email := lower(btrim(p_email::text));

  if exists (
    select 1
      from public.organization_members m
      join public.profiles pr on pr.id = m.user_id
     where m.organization_id = p_org_id
       and m.status = 'active'
       and lower(pr.email) = v_email
  ) then
    raise exception 'create_org_invite: % is already an active member of this organization', v_email;
  end if;

  v_entitlement := public.organization_entitlement(p_org_id);
  if public.organization_seat_count(p_org_id) >= (v_entitlement->>'seat_allowance')::int then
    raise exception 'create_org_invite: seat_allowance_exceeded — % of % seats used for organization %',
      v_entitlement->>'seat_count', v_entitlement->>'seat_allowance', p_org_id;
  end if;

  v_raw_token  := public.random_token_hex(32);
  v_token_hash := public.sha256_hex(v_raw_token);

  insert into public.organization_members
    (organization_id, user_id, role, status, invited_email, invite_token_hash, project_id)
  values
    (p_org_id, null, 'clinician', 'invited', v_email, v_token_hash, p_project_id);

  return v_raw_token;
end;
$$;

comment on function public.create_org_invite(uuid, citext, uuid) is
  'Owner-only. Raises seat_allowance_exceeded (organization_entitlement, lot H) before creating an invite that would push the organization past its seat allowance — checked AFTER the duplicate-active-member check, so a refused duplicate never counts against the allowance. Returns the raw token once — see the original migration for why it is never stored beyond its sha256.';

revoke execute on function public.create_org_invite(uuid, citext, uuid) from public, anon, authenticated;
grant  execute on function public.create_org_invite(uuid, citext, uuid) to authenticated;


create or replace function public.provision_clinician_project(p_organization_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id   uuid;
  v_project_id  uuid;
  v_kit_id      uuid;
  v_entitlement jsonb;
begin
  if auth.uid() is null then
    raise exception 'provision_clinician_project: no authenticated user';
  end if;

  select id, project_id into v_member_id, v_project_id
    from public.organization_members
   where organization_id = p_organization_id
     and user_id = auth.uid()
     and status = 'active'
   for update;

  if not found then
    raise exception 'provision_clinician_project: % is not an active member of organization %', auth.uid(), p_organization_id;
  end if;

  if v_project_id is not null then
    return v_project_id;
  end if;

  -- The invite that brought this member in already counted toward the
  -- seat allowance (organization_seat_count counts 'invited' too) — this
  -- check exists for the member row created directly, bypassing
  -- create_org_invite entirely (an owner inserting a member by hand, as
  -- lot C's own tests do). A member who already holds an active seat
  -- provisioning her first project is not a NEW seat and is never
  -- blocked here, however tight the allowance.
  v_entitlement := public.organization_entitlement(p_organization_id);
  if public.organization_seat_count(p_organization_id) > (v_entitlement->>'seat_allowance')::int then
    raise exception 'provision_clinician_project: seat_allowance_exceeded — % of % seats used for organization %',
      v_entitlement->>'seat_count', v_entitlement->>'seat_allowance', p_organization_id;
  end if;

  insert into public.projects (user_id, organization_id, name)
  values (auth.uid(), p_organization_id, 'My profile')
  returning id into v_project_id;

  insert into public.brand_kits (project_id) values (v_project_id)
  returning id into v_kit_id;

  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, paper_hex,
     heading_font, body_font, google_fonts_url, hero, pages)
  values
    (v_kit_id, auth.uid(), '#26211C', '#26211C', '#B4653F',
     '#FDFCFA', '#26211C', '#FDFCFA',
     'Inter', 'Inter',
     'https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap',
     jsonb_build_object('overline', '', 'headline', '', 'subhead', '', 'cta_label', ''),
     public.site_spec_default_pages(null, null));

  update public.organization_members
     set project_id = v_project_id
   where id = v_member_id;

  perform public.apply_charter_internal(p_organization_id, v_project_id);

  return v_project_id;
end;
$$;

comment on function public.provision_clinician_project(uuid) is
  'Self-service project provisioning for an active org member. Blocks (seat_allowance_exceeded) only when the organization is ALREADY over its allowance — an already-seated member provisioning her own first project is never a new seat, however tight the allowance. Otherwise unchanged from the lot E1 version: idempotent, scaffolds brand_kits/site_specs, applies the charter.';

revoke execute on function public.provision_clinician_project(uuid) from public, anon;
grant  execute on function public.provision_clinician_project(uuid) to authenticated;
