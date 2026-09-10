-- ============================================================================
-- Eklio — the month's counts stop counting what she has never seen
-- ============================================================================
-- `proposed` arrived in 20260910083735 and `get_content_month` was not taught
-- about it. Its `scheduled` count is `count(*) filter (where scheduled_for is
-- not null)`, which happily includes proposals — so the first generated month
-- would have reported "12 scheduled" for twelve captions she had not read.
--
-- ⚠ THE STANDING RULE IS "NEVER DISPLAY A NUMBER EKLIO CANNOT MEASURE", and
-- its sharper form is that the only honest count is one that comes from a row
-- SHE created. A proposal is a row EKLIO created. Counting it beside her own
-- work does not merely inflate a number: it tells her she has done something
-- she has not done.
--
-- Two changes, and the second is what keeps the first honest:
--
--   1. `scheduled`, `ready` and `posted` now all exclude `proposed`. `ready`
--      and `posted` already did by construction — a proposal cannot be `ready`
--      and has no publication row — but they are filtered explicitly anyway,
--      so the rule is visible in one place rather than resting on two
--      accidents.
--   2. A NEW `proposed` count, separate. The month plan needs to say "twelve
--      posts waiting for you", and that IS measurable and IS honest. Hiding
--      proposals entirely would be the opposite failure: a full month that
--      reports nothing.
--
-- `items` still INCLUDES proposals. They render, greyed, on their dates —
-- we stop counting her content, we never hide it.
-- ============================================================================

create or replace function public.get_content_month(p_brand_kit_id uuid, p_month date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_error text;
  v_start date := date_trunc('month', p_month)::date;
begin
  v_error := public.content_kit_access(p_brand_kit_id);
  if v_error is not null then
    return public.content_error(v_error);
  end if;

  return jsonb_build_object(
    'month', v_start,
    'items', coalesce((
      select jsonb_agg(public.content_item_json(ci.id) order by ci.scheduled_for, ci.created_at)
        from public.content_items ci
       where ci.brand_kit_id = p_brand_kit_id
         and ci.scheduled_for >= v_start
         and ci.scheduled_for < (v_start + interval '1 month')::date
         and ci.status <> 'archived'
    ), '[]'::jsonb),
    'unscheduled', coalesce((
      select jsonb_agg(public.content_item_json(ci.id) order by ci.created_at desc)
        from public.content_items ci
       where ci.brand_kit_id = p_brand_kit_id
         and ci.scheduled_for is null
         and ci.status <> 'archived'
    ), '[]'::jsonb),
    'counts', (
      select jsonb_build_object(
        -- Her work. A proposal is not hers until she has approved it.
        'scheduled', count(*) filter (
                       where ci.scheduled_for is not null
                         and ci.status <> 'proposed'),
        'ready',     count(*) filter (
                       where ci.status = 'ready'),
        'posted',    count(*) filter (
                       where ci.status <> 'proposed'
                         and public.content_item_json(ci.id) ->> 'posted' = 'true'),
        -- Eklio's work, waiting on her. Measurable, honest, and separate.
        'proposed',  count(*) filter (where ci.status = 'proposed')
      )
        from public.content_items ci
       where ci.brand_kit_id = p_brand_kit_id
         and ci.status <> 'archived'
         and (ci.scheduled_for is null
              or (ci.scheduled_for >= v_start
                  and ci.scheduled_for < (v_start + interval '1 month')::date))
    )
  );
end
$function$;

comment on function public.get_content_month(uuid, date) is
  'One month of content items plus counts. `scheduled`, `ready` and `posted` count only what SHE has seen -- proposals are excluded from all three and counted separately as `proposed`. `items` still includes proposals: they render greyed on their dates.';


-- ============================================================================
-- Guard rail
-- ============================================================================
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_content_month';

  if v_def not like '%''proposed''%' then
    raise exception 'month counts: the proposed count is missing';
  end if;

  if v_def like '%''scheduled'', count(*) filter (%where ci.scheduled_for is not null)%' then
    raise exception 'month counts: scheduled still counts proposals';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   Restore the body from 20260906155600_content_items.sql, which predates
--   `proposed` and therefore has nothing to exclude.
