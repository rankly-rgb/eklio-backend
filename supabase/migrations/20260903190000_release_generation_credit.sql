-- ============================================================================
-- Eklio — release_generation_credit: a failed pipeline run refunds its spend
-- ============================================================================
-- REAL BUG, FOUND BY TRACING `consume_generation_credit` WHILE FIXING THE
-- usp-options 500 (WORKLOG.md, eklio-frontend, 2026-09-03).
--
-- `consume_generation_credit` (20260830062321_plans_and_granted_allowance.sql)
-- is called BEFORE the model runs, atomically, unconditionally — correct for
-- race-safety, but it does not know yet whether the run will succeed. Its
-- own counter logic:
--
--   directions_generated = 0  -> set straight to directions_limit (3)
--   directions_generated > 0  -> regenerations_used += 1, capped by
--                                 regenerations_limit
--
-- A FIRST attempt that fails outright (the exact scenario the usp-options
-- fix addresses — a missing ANTHROPIC_API_KEY, a model call error) still
-- sets directions_generated straight to 3, having produced zero directions.
-- Every subsequent attempt — including her very first legitimate RETRY —
-- is now charged against the much smaller regenerations_used budget instead
-- of ever getting its own real first attempt. A sustained failure (the
-- config-missing case, which fails identically every time) can lock her out
-- of the free tier entirely without her ever having seen one direction.
--
-- `direction_assets_claim` (20260901074421_direction_assets.sql) already
-- solved the same shape of problem for a different feature — "a fresh claim
-- may retake the same reservation rather than booking a second one" — this
-- migration is the same idea applied here: release the reservation a failed
-- run made, so a retry gets a genuine first try, not a regeneration.
-- ============================================================================

create or replace function public.release_generation_credit(p_brand_kit_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_project    uuid;
  v_directions jsonb;
begin
  if (select auth.uid()) is null then
    return false;
  end if;

  select bk.project_id, bk.directions into v_project, v_directions
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
   where bk.id = p_brand_kit_id
     and pr.user_id = (select auth.uid());
  if v_project is null then
    return false;
  end if;

  -- Directions exist: a run has already delivered a real result. Whatever
  -- credit history led there is done, correct, and never refunded — this
  -- only undoes spend from a streak of runs that produced NOTHING, ever,
  -- for this project. The database decides via `directions`, not a flag
  -- passed in by the caller (same philosophy as `lib/generation/job.ts`'s
  -- own "done comes from directions in the database, never the job alone").
  if v_directions is not null then
    return false;
  end if;

  update public.generation_credits gc
     set directions_generated = 0,
         regenerations_used = 0
   where gc.project_id = v_project
     and gc.directions_generated > 0;

  return found;
end
$$;

comment on function public.release_generation_credit(uuid) is
  'Refunds every generation credit spent on this project back to zero, but ONLY while brand_kits.directions is still null — a full reset is safe exactly because nothing has ever been delivered to refund away from. Called from the pipeline''s own failure handler (app/api/briefs/[id]/generate/route.ts) so a retry after an infrastructure failure gets a genuine first attempt, not a regeneration charged against a much smaller budget.';

revoke execute on function public.release_generation_credit(uuid) from public, anon;
grant execute on function public.release_generation_credit(uuid) to authenticated, service_role;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.release_generation_credit(uuid);
-- ============================================================================
