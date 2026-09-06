-- ============================================================================
-- Eklio — the photograph-regeneration budget
-- ============================================================================
-- The initial seven photographs are part of what she bought and draw on
-- nothing. Only a REGENERATION costs, and it costs against
-- `plans.image_budget_cents` — never against `consume_generation_credit`,
-- whose meter is the DIRECTIONS ladder and has nothing to do with pixels.
-- (FINDINGS.md carries the note about the two meters being conflated in the
-- earlier draft; this migration is what un-conflates them.)
--
-- A MONEY BUDGET, NOT A COUNT. The slots cost different amounts — a hero is
-- 25c and a texture 5c — so "three regenerations left" would mean something
-- different on two adjacent screens. The budget is cents; the UI divides by
-- the price of the slot she is actually looking at.
--
-- RESERVED BEFORE, RELEASED ON FAILURE. Same discipline as the daily image
-- ceiling: in-flight spend counts from the moment it starts, so two concurrent
-- regenerations cannot both pass an under-budget check. She is never charged
-- for a photograph she did not receive.
-- ============================================================================

alter table public.plans
  add column if not exists image_budget_cents integer not null default 0;

comment on column public.plans.image_budget_cents is
  'What a project on this plan may spend REGENERATING photographs, in cents. The initial seven are part of what she bought and draw on nothing. Deliberately a money budget, not a count: slots cost different amounts, so "three regenerations" means something different on the hero than on a texture.';

update public.plans set image_budget_cents = 100 where tier = 'starter';
update public.plans set image_budget_cents = 250 where tier = 'practice';
update public.plans set image_budget_cents = 500 where tier = 'signature';

alter table public.generation_credits
  add column if not exists image_cents_reserved integer not null default 0,
  add column if not exists image_cents_used     integer not null default 0,
  add constraint generation_credits_image_reserved_check check (image_cents_reserved >= 0),
  add constraint generation_credits_image_used_check     check (image_cents_used >= 0);

comment on column public.generation_credits.image_cents_reserved is
  'In-flight regeneration spend, booked BEFORE the model call and released on failure. Counts against the budget from the moment it starts, so two concurrent regenerations cannot both sail under the ceiling.';
comment on column public.generation_credits.image_cents_used is
  'Settled regeneration spend. Only ever grows, and only by what a real successful regeneration cost.';

create or replace function public.reserve_image_regeneration(
  p_brand_kit_id uuid,
  p_cost_cents integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_project uuid;
  v_budget  integer;
  v_ok      boolean;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('ok', false, 'reason', 'payment_required');
  end if;
  if p_cost_cents is null or p_cost_cents <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_field');
  end if;

  select bk.project_id into v_project
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
   where bk.id = p_brand_kit_id
     and pr.user_id = (select auth.uid());
  if v_project is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  insert into public.generation_credits (project_id) values (v_project)
  on conflict (project_id) do nothing;

  select pl.image_budget_cents into v_budget
    from public.generation_credits gc
    join public.plans pl on pl.tier = gc.plan_tier
   where gc.project_id = v_project;

  -- ⚠ ONE STATEMENT. Check and increment together, or two concurrent
  -- regenerations both read an under-budget total and both add to it.
  update public.generation_credits gc
     set image_cents_reserved = gc.image_cents_reserved + p_cost_cents
   where gc.project_id = v_project
     and gc.image_cents_reserved + gc.image_cents_used + p_cost_cents <= coalesce(v_budget, 0)
  returning true into v_ok;

  if coalesce(v_ok, false) is not true then
    return jsonb_build_object('ok', false, 'reason', 'budget_exhausted',
                              'budget_cents', coalesce(v_budget, 0));
  end if;

  return jsonb_build_object('ok', true, 'reason', 'reserved');
end;
$$;

revoke execute on function public.reserve_image_regeneration(uuid, integer) from public, anon;
grant execute on function public.reserve_image_regeneration(uuid, integer) to authenticated, service_role;

create or replace function public.settle_image_regeneration(
  p_brand_kit_id uuid,
  p_cost_cents integer,
  p_succeeded boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_project uuid;
begin
  select bk.project_id into v_project
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
   where bk.id = p_brand_kit_id
     and pr.user_id = (select auth.uid());
  if v_project is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- Released either way. On success the reservation becomes settled spend; on
  -- failure it simply goes back, because she is never charged for a
  -- photograph she did not receive.
  update public.generation_credits
     set image_cents_reserved = greatest(0, image_cents_reserved - p_cost_cents),
         image_cents_used     = image_cents_used + case when p_succeeded then p_cost_cents else 0 end
   where project_id = v_project;

  return jsonb_build_object('ok', true, 'reason', case when p_succeeded then 'settled' else 'released' end);
end;
$$;

revoke execute on function public.settle_image_regeneration(uuid, integer, boolean) from public, anon;
grant execute on function public.settle_image_regeneration(uuid, integer, boolean) to authenticated, service_role;

create or replace function public.get_image_regeneration_budget(p_brand_kit_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_project  uuid;
  v_budget   integer;
  v_reserved integer;
  v_used     integer;
begin
  if not public.brand_kit_entitled(p_brand_kit_id) then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'payment_required', 'message', 'This brand kit is not yet paid for.'));
  end if;

  select bk.project_id into v_project
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
   where bk.id = p_brand_kit_id
     and pr.user_id = (select auth.uid());
  if v_project is null then
    return jsonb_build_object('error', jsonb_build_object(
      'code', 'not_found', 'message', 'No such brand kit.'));
  end if;

  select pl.image_budget_cents, gc.image_cents_reserved, gc.image_cents_used
    into v_budget, v_reserved, v_used
    from public.generation_credits gc
    join public.plans pl on pl.tier = gc.plan_tier
   where gc.project_id = v_project;

  return jsonb_build_object(
    'budget_cents', coalesce(v_budget, 0),
    'reserved_cents', coalesce(v_reserved, 0),
    'used_cents', coalesce(v_used, 0),
    'remaining_cents', greatest(0, coalesce(v_budget, 0) - coalesce(v_reserved, 0) - coalesce(v_used, 0))
  );
end;
$$;

comment on function public.get_image_regeneration_budget(uuid) is
  'What is left of this project''s photograph-regeneration budget, in cents. The UI divides remaining_cents by the PRICE OF THE SLOT she is looking at, because a hero regeneration costs five times a texture and "3 left" would otherwise mean two different things on two screens.';

revoke execute on function public.get_image_regeneration_budget(uuid) from public, anon;
grant execute on function public.get_image_regeneration_budget(uuid) to authenticated, service_role;
