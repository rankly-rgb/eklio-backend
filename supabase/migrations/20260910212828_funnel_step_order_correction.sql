-- ============================================================================
-- Eklio — "Chose a direction" happens AFTER the money, not before it
-- ============================================================================
-- The funnel seeded in 20260910212308 put `chose` at position 8, between the
-- reveal and the signup. That was an assumption, and reading
-- `lib/reveal/use-select-direction.ts` disproves it:
--
--     if (!paid) { router.push(checkoutHref); return; }
--
-- An unpaid visitor pressing a direction is sent to checkout and never
-- reaches `POST /api/brand-kits/[id]/direction` at all. Choosing is how she
-- TAKES DELIVERY of something she has already bought, so it is the last step
-- of the funnel, not the eighth.
--
-- Left where it was, the report would have shown a cliff between "saw three
-- directions" and "chose a direction" and invited someone to go fix a step
-- that is working exactly as designed -- while hiding the two steps that
-- actually stand between her and paying.
--
-- Positions are bumped out of the way first: `funnel_steps_step_no_key` is a
-- plain unique constraint, and a single UPDATE that permutes values through it
-- can collide mid-statement.
-- ============================================================================

update public.funnel_steps set step_no = step_no + 100 where step_no >= 8;

update public.funnel_steps set step_no =  8 where step_key = 'signup';
update public.funnel_steps set step_no =  9 where step_key = 'account';
update public.funnel_steps set step_no = 10 where step_key = 'checkout';
update public.funnel_steps set step_no = 11 where step_key = 'paid';
update public.funnel_steps set step_no = 12 where step_key = 'chose';

-- "Started an account" read like opening the form. It is the SUBMIT: `/signup`
-- is a static page and there is no server render to measure the open without
-- making a cold-campaign landing surface dynamic. The label now says what the
-- number is.
update public.funnel_steps
   set label = 'Submitted the signup form'
 where step_key = 'signup';

update public.funnel_steps
   set label = 'Chose a direction', phase = 'paid'
 where step_key = 'chose';

do $$
declare v_n integer; v_wrong text;
begin
  select count(*) into v_n from public.funnel_steps where step_no between 1 and 12;
  if v_n <> 12 then
    raise exception 'funnel order: step numbers are not 1..12 (% in range)', v_n;
  end if;

  -- The order must actually be the one this migration exists to install.
  select string_agg(step_key, ',' order by step_no) into v_wrong
    from public.funnel_steps;
  if v_wrong <> 'landed,pricing,brief_started,brief_step_4,brief_review,generate,directions,signup,account,checkout,paid,chose' then
    raise exception 'funnel order: got %', v_wrong;
  end if;

  -- Nothing may still be parked in the bump range.
  select count(*) into v_n from public.funnel_steps where step_no > 12;
  if v_n <> 0 then
    raise exception 'funnel order: % steps left above 12', v_n;
  end if;
end
$$;

-- ============================================================================
-- DOWN
-- ============================================================================
--   Restore the positions seeded in 20260910212308_funnel_events.sql
--   (chose = 8, signup = 9, account = 10, checkout = 11, paid = 12) and the
--   label 'Started an account'. Same bump-then-set shape.
