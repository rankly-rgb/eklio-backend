-- ============================================================================
-- Eklio — the Content system's write path
-- ============================================================================
-- ── WHO WRITES WHAT, AND WHY THE SPLIT IS NOT ARBITRARY ──────────────────
--
-- SHE writes preferences and the check-in. Those get SECURITY DEFINER RPCs,
-- like the eight `content_items` ones already do: the tables refuse every
-- client write by policy, and the RPC is the only door.
--
-- THE GENERATOR writes months and grounds. Those get no client RPC at all —
-- deliberately. She never authors a month; a month is produced for her by a
-- server job holding the service_role, exactly as `purchases` is written only
-- by the Stripe webhook. Adding a client door to `content_months` would be
-- adding a door nobody is meant to walk through.
--
-- The allowance is the third case: she may LOOK at it, and only the server may
-- SPEND it.
-- ============================================================================


-- ============================================================================
-- 1. The alt-text gate — the rule that did not exist
-- ============================================================================
-- ⚠ THIS IS NEW BEHAVIOUR, NOT A KEPT ONE. Until now the only constraint on
-- `alt_text` anywhere was `char_length <= 420`. `status` was a plain dropdown,
-- and the editor showed the field with the hint "Worth writing before you
-- post, not after." That is advice, not a rule, and everyone believed it was a
-- rule.
--
-- ── AND IT IS BUILT THE RIGHT WAY ROUND ──────────────────────────────────
--
-- The GENERATOR writes the alt text, because Eklio composed the image and
-- knows what is in it. It arrives pre-filled and editable. Making her describe
-- a picture we made would be handing her our work.
--
-- What is enforced here is only the floor: an item cannot reach `ready` with
-- an empty one. In the RPC rather than only in the editor, because the editor
-- is one caller and the rule is about what may be published.
--
-- Whitespace does not count. A space is not a description, and `char_length`
-- alone would have accepted one.

create or replace function public.update_content_item(p_id uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_kit        uuid;
  v_error      text;
  v_bad        text;
  v_next_state text;
  v_next_alt   text;
begin
  select ci.brand_kit_id into v_kit
    from public.content_items ci
   where ci.id = p_id;

  if v_kit is null then
    return public.content_error('not_found');
  end if;

  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  -- An unknown key is a caller bug, and silently dropping it would let a
  -- renamed field autosave into nothing for a release before anyone noticed.
  select string_agg(key, ', ') into v_bad
    from jsonb_object_keys(p_patch) as key
   where key not in ('archetype','status','title','caption','alt_text',
                     'tags','category','image_slot','scheduled_for');
  if v_bad is not null then
    return public.content_error('unknown_field');
  end if;

  /*
   * The gate. Resolved against the state the row will be IN after this patch,
   * not the state it is in now: a single patch can set both `status` and
   * `alt_text`, and checking the stored value would refuse a save that fills
   * them together.
   */
  select case when p_patch ? 'status'   then p_patch ->> 'status'   else ci.status end,
         case when p_patch ? 'alt_text' then p_patch ->> 'alt_text' else ci.alt_text end
    into v_next_state, v_next_alt
    from public.content_items ci
   where ci.id = p_id;

  if v_next_state = 'ready' and coalesce(btrim(v_next_alt), '') = '' then
    return public.content_error('alt_text_required');
  end if;

  update public.content_items ci set
    archetype     = case when p_patch ? 'archetype'  then p_patch ->> 'archetype'  else ci.archetype end,
    status        = case when p_patch ? 'status'     then p_patch ->> 'status'     else ci.status end,
    title         = case when p_patch ? 'title'      then p_patch ->> 'title'      else ci.title end,
    caption       = case when p_patch ? 'caption'    then p_patch ->> 'caption'    else ci.caption end,
    alt_text      = case when p_patch ? 'alt_text'   then p_patch ->> 'alt_text'   else ci.alt_text end,
    category      = case when p_patch ? 'category'   then p_patch ->> 'category'   else ci.category end,
    image_slot    = case when p_patch ? 'image_slot' then p_patch ->> 'image_slot' else ci.image_slot end,
    scheduled_for = case when p_patch ? 'scheduled_for'
                         then nullif(p_patch ->> 'scheduled_for', '')::date else ci.scheduled_for end,
    tags          = case when p_patch ? 'tags'
                         then public.content_normalize_tags(
                                array(select jsonb_array_elements_text(p_patch -> 'tags')))
                         else ci.tags end,
    updated_at    = now()
  where ci.id = p_id;

  return jsonb_build_object('id', p_id, 'saved_at', now());
end
$function$;

comment on function public.update_content_item(uuid, jsonb) is
  'Patches one content item. Refuses alt_text_required when the patch would leave the item `ready` with blank alt text -- the generator pre-fills alt text because Eklio composed the image; this is only the floor that stops an empty one being published.';


-- ============================================================================
-- 2. set_content_preferences — asked once, editable from Settings
-- ============================================================================
create or replace function public.set_content_preferences(
  p_brand_kit_id uuid,
  p_cadence_per_week smallint,
  p_accepted_registers text[],
  p_off_limits text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_error text;
begin
  v_error := public.content_kit_access(p_brand_kit_id);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  /*
   * The CHECK constraints and the register trigger do the validating; this
   * function does not repeat them. A second copy of "cadence must be 1, 2 or
   * 3" here would be one more place to forget when a fourth cadence is sold.
   * A violation surfaces as a refusal rather than a 500.
   */
  begin
    insert into public.content_preferences
      (brand_kit_id, cadence_per_week, accepted_registers, off_limits)
    values (p_brand_kit_id, p_cadence_per_week, p_accepted_registers,
            nullif(btrim(coalesce(p_off_limits, '')), ''))
    on conflict (brand_kit_id) do update
      set cadence_per_week   = excluded.cadence_per_week,
          accepted_registers = excluded.accepted_registers,
          off_limits         = excluded.off_limits,
          updated_at         = now();
  exception when check_violation or not_null_violation then
    return public.content_error('invalid_preferences');
  end;

  return jsonb_build_object('brand_kit_id', p_brand_kit_id, 'saved_at', now());
end
$function$;

revoke execute on function public.set_content_preferences(uuid, smallint, text[], text) from public, anon;
grant execute on function public.set_content_preferences(uuid, smallint, text[], text)
  to authenticated, service_role;


-- ============================================================================
-- 3. set_content_checkin — the sixty seconds
-- ============================================================================
-- All three answers stay NULLABLE and no answer is required. An unanswered
-- check-in means "generate from the brief alone and leave it open at the top
-- of the calendar" — it must never be a gate on her month.

create or replace function public.set_content_checkin(
  p_brand_kit_id uuid,
  p_month date,
  p_sessions_theme text default null,
  p_taking_clients text default null,
  p_happening text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_error text;
  v_month date := date_trunc('month', p_month)::date;
begin
  v_error := public.content_kit_access(p_brand_kit_id);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  begin
    insert into public.content_checkins
      (brand_kit_id, month, sessions_theme, taking_clients, happening)
    values (p_brand_kit_id, v_month,
            nullif(btrim(coalesce(p_sessions_theme, '')), ''),
            nullif(btrim(coalesce(p_taking_clients, '')), ''),
            nullif(btrim(coalesce(p_happening, '')), ''))
    on conflict (brand_kit_id, month) do update
      set sessions_theme = excluded.sessions_theme,
          taking_clients = excluded.taking_clients,
          happening      = excluded.happening,
          updated_at     = now();
  exception when check_violation then
    return public.content_error('invalid_checkin');
  end;

  return jsonb_build_object('brand_kit_id', p_brand_kit_id, 'month', v_month, 'saved_at', now());
end
$function$;

revoke execute on function public.set_content_checkin(uuid, date, text, text, text) from public, anon;
grant execute on function public.set_content_checkin(uuid, date, text, text, text)
  to authenticated, service_role;


-- ============================================================================
-- 4. The monthly image meter — reserve, settle, read
-- ============================================================================
-- ⚠ VERIFY-THEN-CONSUME IN ONE STATEMENT. There is still no post-purchase
-- refund primitive in this product, so a reservation that checks and then
-- increments in two statements can be raced into an overspend that nothing can
-- undo. The `on conflict ... do update ... where` below is the check and the
-- increment as one atomic act: when the WHERE fails, no row is written and
-- nothing was reserved.
--
-- The row's own CHECK (`reserved + used <= budget`) is the second belt: even a
-- future writer that bypasses this function cannot push her past the ceiling.

create or replace function public.reserve_content_image(
  p_brand_kit_id uuid,
  p_month date,
  p_cost_cents integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_month   date := date_trunc('month', p_month)::date;
  v_ceiling integer;
  v_ok      boolean := false;
begin
  if p_cost_cents is null or p_cost_cents < 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_cost');
  end if;

  select (value #>> '{}')::integer into v_ceiling
    from public.app_settings where key = 'content_image_budget_cents_per_month';

  if v_ceiling is null then
    -- Fail CLOSED. An unreadable ceiling is "we could not tell", never "spend
    -- freely" -- the same rule the tier guard follows.
    return jsonb_build_object('ok', false, 'reason', 'no_ceiling_configured');
  end if;

  if p_cost_cents > v_ceiling then
    return jsonb_build_object('ok', false, 'reason', 'cost_exceeds_budget');
  end if;

  insert into public.content_image_allowance
    (brand_kit_id, month, budget_cents, reserved_cents, used_cents)
  values (p_brand_kit_id, v_month, v_ceiling, p_cost_cents, 0)
  on conflict (brand_kit_id, month) do update
    set reserved_cents = public.content_image_allowance.reserved_cents + p_cost_cents,
        updated_at     = now()
    where public.content_image_allowance.reserved_cents
        + public.content_image_allowance.used_cents
        + p_cost_cents <= public.content_image_allowance.budget_cents;

  get diagnostics v_ok = row_count;

  if not v_ok then
    return jsonb_build_object('ok', false, 'reason', 'budget_exhausted');
  end if;

  return jsonb_build_object('ok', true, 'reason', 'reserved');
end
$function$;


-- Settle: the reservation becomes spend, or it is released. Never both, never
-- neither. `greatest(0, ...)` because a double-settle must not drive the
-- counter negative and strand her allowance below zero forever.
create or replace function public.settle_content_image(
  p_brand_kit_id uuid,
  p_month date,
  p_cost_cents integer,
  p_succeeded boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_rows  integer;
begin
  update public.content_image_allowance a set
    reserved_cents = greatest(0, a.reserved_cents - p_cost_cents),
    used_cents     = case when p_succeeded then a.used_cents + p_cost_cents else a.used_cents end,
    updated_at     = now()
  where a.brand_kit_id = p_brand_kit_id and a.month = v_month;

  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_allowance_row');
  end if;

  return jsonb_build_object('ok', true,
    'reason', case when p_succeeded then 'settled' else 'released' end);
end
$function$;


create or replace function public.get_content_image_allowance(
  p_brand_kit_id uuid,
  p_month date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_error   text;
  v_month   date := date_trunc('month', p_month)::date;
  v_ceiling integer;
  v_row     public.content_image_allowance;
begin
  v_error := public.content_kit_access(p_brand_kit_id);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  select (value #>> '{}')::integer into v_ceiling
    from public.app_settings where key = 'content_image_budget_cents_per_month';

  select * into v_row from public.content_image_allowance a
   where a.brand_kit_id = p_brand_kit_id and a.month = v_month;

  -- No row means a month nothing has been spent in yet — which is the FULL
  -- allowance, not a missing one. The reset is structural: a new month simply
  -- has no row.
  if not found then
    return jsonb_build_object(
      'budget_cents', coalesce(v_ceiling, 0),
      'reserved_cents', 0, 'used_cents', 0,
      'remaining_cents', coalesce(v_ceiling, 0));
  end if;

  return jsonb_build_object(
    'budget_cents', v_row.budget_cents,
    'reserved_cents', v_row.reserved_cents,
    'used_cents', v_row.used_cents,
    'remaining_cents', v_row.budget_cents - v_row.reserved_cents - v_row.used_cents);
end
$function$;

/*
 * ⚠ SPENDING IS SERVER-ONLY. `reserve` and `settle` are revoked from
 * `authenticated` entirely: she never spends her own meter from a browser, and
 * a route handler that wants to must hold the service_role. Reading it is
 * hers, so `get_` is granted to her.
 */
revoke execute on function public.reserve_content_image(uuid, date, integer) from public, anon, authenticated;
grant  execute on function public.reserve_content_image(uuid, date, integer) to service_role;

revoke execute on function public.settle_content_image(uuid, date, integer, boolean) from public, anon, authenticated;
grant  execute on function public.settle_content_image(uuid, date, integer, boolean) to service_role;

revoke execute on function public.get_content_image_allowance(uuid, date) from public, anon;
grant  execute on function public.get_content_image_allowance(uuid, date) to authenticated, service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
begin
  if has_function_privilege('authenticated', 'public.reserve_content_image(uuid, date, integer)', 'execute')
  then
    raise exception 'content rpcs: a browser session can reserve image spend';
  end if;

  if has_function_privilege('authenticated', 'public.settle_content_image(uuid, date, integer, boolean)', 'execute')
  then
    raise exception 'content rpcs: a browser session can settle image spend';
  end if;

  if has_function_privilege('anon', 'public.set_content_preferences(uuid, smallint, text[], text)', 'execute')
  then
    raise exception 'content rpcs: anon can write preferences';
  end if;

  -- ⚠ The generator's tables have NO client door, and that is the design.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('set_content_month', 'create_content_month', 'set_content_ground')
  ) then
    raise exception 'content rpcs: a client write path appeared for months or grounds';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.get_content_image_allowance(uuid, date);
--   drop function if exists public.settle_content_image(uuid, date, integer, boolean);
--   drop function if exists public.reserve_content_image(uuid, date, integer);
--   drop function if exists public.set_content_checkin(uuid, date, text, text, text);
--   drop function if exists public.set_content_preferences(uuid, smallint, text[], text);
--   -- update_content_item: restore the pre-gate body from 20260906155600.
