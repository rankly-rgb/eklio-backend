-- ============================================================================
-- Eklio — approving the month, in one gesture
-- ============================================================================
-- The month arrives as a batch of `proposed` items she has not read. Approving
-- moves the whole batch to `draft` — hers to edit, hers to schedule, counted
-- from that moment.
--
-- ⚠ ONE STATEMENT, NOT A LOOP. Twelve separate updates can half-succeed: a
-- timeout at item seven leaves five proposals and seven drafts, and there is
-- no state in the product that describes "half a month". One UPDATE over the
-- batch either moves all of them or none.
--
-- ⚠ SCOPED TO THE MONTH ROW, NOT TO A DATE RANGE. `month_id` is provenance:
-- if she dragged a proposed post into November before approving, it is still
-- part of October's plan and must move with it. Selecting by `scheduled_for`
-- would leave that one behind, `proposed` forever, greyed on a date in a month
-- whose plan she already accepted.
--
-- Approval is IDEMPOTENT. A double click, a retried request, or a second tab
-- moves zero further items and still reports success: the month is approved
-- either way, and that is the answer the caller needs.
-- ============================================================================

create or replace function public.approve_content_month(p_month_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_kit    uuid;
  v_error  text;
  v_status text;
  v_moved  integer;
begin
  select cm.brand_kit_id, cm.status into v_kit, v_status
    from public.content_months cm
   where cm.id = p_month_id;

  if v_kit is null then
    return public.content_error('not_found');
  end if;

  -- 404 before payment_required, everywhere: a 402 to a stranger would
  -- confirm that this month exists.
  v_error := public.content_kit_access(v_kit);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  -- A month still generating has nothing settled to approve, and a failed one
  -- has nothing at all. Only `proposed` and the already-`approved` (idempotent
  -- replay) get through.
  if v_status not in ('proposed', 'approved') then
    return public.content_error('month_not_ready');
  end if;

  update public.content_items ci
     set status = 'draft', updated_at = now()
   where ci.month_id = p_month_id
     and ci.status = 'proposed';

  get diagnostics v_moved = row_count;

  update public.content_months cm
     set status = 'approved', updated_at = now()
   where cm.id = p_month_id;

  return jsonb_build_object(
    'month_id', p_month_id,
    'approved_at', now(),
    -- What actually moved. On a replay this is 0, and that is the truth rather
    -- than a number repeated to look busy.
    'moved', v_moved
  );
end
$function$;

comment on function public.approve_content_month(uuid) is
  'Moves a month''s proposed items to draft in ONE statement and marks the month approved. Scoped by month_id rather than by date, so a proposal she dragged into the next month still moves with its own plan. Idempotent: a replay moves 0 and still succeeds.';

revoke execute on function public.approve_content_month(uuid) from public, anon;
grant execute on function public.approve_content_month(uuid) to authenticated, service_role;


-- ============================================================================
-- Guard rail
-- ============================================================================
do $$
begin
  if has_function_privilege('anon', 'public.approve_content_month(uuid)', 'execute') then
    raise exception 'approve: anon can approve a month';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.approve_content_month(uuid);
