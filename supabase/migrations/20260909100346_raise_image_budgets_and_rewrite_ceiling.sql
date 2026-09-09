-- ============================================================================
-- Eklio — two ceilings raised, both for the same reason: what they bound changed
-- ============================================================================
--
-- 1. THE IMAGE BUDGETS WERE SIZED FOR REGENERATIONS ONLY.
--
-- `plans.image_budget_cents` was set on 6 September, when the initial seven
-- photographs "drew on nothing" and only a REGENERATION reserved. On 9
-- September every generation began reserving, so a full set now comes out of
-- the same purse — and at the current price table a full set is 59c (hero 25c
-- at `high`, two ambients 7c, four squares 5c).
--
-- That left Starter with 41c for the life of a kit: one hero regeneration.
-- The number had not changed; what it bounded had.
--
--   starter    100 → 200    (141c of headroom after a full set)
--   practice   250 → 400    (341c)
--   signature  500 → 600    (541c)
--
-- ⚠ THIS TABLE IS THE DECISION, and it stays that way. Changing what a tier
-- grants is an UPDATE here and nowhere else; it must never become a code edit.
--
--
-- 2. TWENTY REWRITES A DAY IS REACHABLE IN A FIRST HONEST SESSION.
--
-- A bio with six flagged sentences, worked through twice, is twelve. Add a
-- second piece of copy and she is at the ceiling — and the refusal lasts until
-- tomorrow, which is a terrible thing to hand someone who is doing exactly
-- what the feature is for. Fifty is still far short of a script, and the whole
-- point of putting the number in `app_settings` was that moving it costs
-- nothing.
--
--   check_rewrites_per_user_per_day    20 → 50
--
-- Neither change touches a function. Both are values.
-- ============================================================================

update public.plans set image_budget_cents = 200 where tier = 'starter';
update public.plans set image_budget_cents = 400 where tier = 'practice';
update public.plans set image_budget_cents = 600 where tier = 'signature';

comment on column public.plans.image_budget_cents is
  'What a project on this plan may spend on photographs, in cents -- the initial set AND every regeneration, since 9 September 2026. Deliberately a money budget, not a count: slots cost different amounts (hero 25c, ambient 7c, square 5c), so "three regenerations" means something different on the hero than on a texture. A full set of seven is 59c.';

-- ⚠ An explicit UPDATE, not another `on conflict do nothing`: the seeding
-- insert in `20260909094038_check_rewrite_daily_limit.sql` would leave an
-- existing row at 20 forever, which is exactly the row this migration exists
-- to change.
update public.app_settings
   set value = '50'
 where key = 'check_rewrites_per_user_per_day';

-- ============================================================================
-- Self-check — both raises landed, and the arithmetic they were chosen for
-- still holds.
-- ============================================================================
do $$
declare
  v_full_set constant integer := 59;  -- hero 25 + ambient 7*2 + square 5*4
  v_starter  integer;
  v_practice integer;
  v_signature integer;
  v_rewrites integer;
begin
  select image_budget_cents into v_starter   from public.plans where tier = 'starter';
  select image_budget_cents into v_practice  from public.plans where tier = 'practice';
  select image_budget_cents into v_signature from public.plans where tier = 'signature';

  if v_starter <> 200 or v_practice <> 400 or v_signature <> 600 then
    raise exception 'image budgets did not land: starter=%, practice=%, signature=%',
      v_starter, v_practice, v_signature;
  end if;

  -- Every tier must clear a full set with room for at least one more hero.
  if v_starter - v_full_set < 25 then
    raise exception 'starter has no room for a hero regeneration after a full set';
  end if;

  select (value #>> '{}')::integer into v_rewrites
    from public.app_settings where key = 'check_rewrites_per_user_per_day';
  if v_rewrites <> 50 then
    raise exception 'the rewrite ceiling did not land: %', v_rewrites;
  end if;
end $$;
