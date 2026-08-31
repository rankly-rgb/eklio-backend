-- ============================================================================
-- Step renumbering — insert "How you work" as step 4
-- ============================================================================
-- New order: 1 practice, 2 positioning, 3 ideal client, 4 HOW YOU WORK (new),
-- 5 voice & tone (was 4), 6 look — palette + typography merged (was 5 and 6),
-- 7 website (unchanged).
--
-- The mapping is factored into small IMMUTABLE functions rather than written
-- inline in the UPDATE below, for one reason: it makes the dedup/collapse
-- behavior independently testable (see the .test.sql for this migration)
-- without needing pre-existing rows in the table at migration-application
-- time — a fresh project has none, so an inline UPDATE alone would be
-- untestable here.
--
-- Every existing row gets touched exactly once, when this migration is
-- first applied to a database with data (this repo's usual deployment path
-- via `supabase db push`, tracked in `supabase_migrations.schema_migrations`
-- so a migration file only ever runs once against a given database). The
-- mapping below is NOT idempotent by design — re-running it against
-- already-migrated rows would remap them a second time and corrupt
-- `completed_steps` — matching every other data-shape migration in this
-- repo, none of which are written to tolerate double-application either.

-- ============================================================================
-- 1. brief_step_renumber_up — single value, old step number -> new
-- ============================================================================

create or replace function public.brief_step_renumber_up(p_step smallint)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select case p_step
    when 4 then 5::smallint
    when 5 then 6::smallint
    when 6 then 6::smallint
    when 7 then 7::smallint
    else p_step
  end
$$;

-- ============================================================================
-- 2. brief_completed_steps_renumber_up — remap every element, then DEDUPLICATE
-- ============================================================================
-- A brief that completed both old step 5 (palette) and old step 6
-- (typography) must end with a SINGLE `6` in `completed_steps`, not two —
-- both collapse onto the merged "Look" step. Step 4 never appears here for
-- an existing brief: no OLD value maps to 4, so the new "How you work" step
-- starts unanswered for everyone, exactly as intended. NULL in, NULL out —
-- `completed_steps` is `not null default '{}'` on this table so this branch
-- is defensive, not reachable today.

create or replace function public.brief_completed_steps_renumber_up(p_steps smallint[])
returns smallint[]
language sql
immutable
set search_path = ''
as $$
  select case
    when p_steps is null then null
    else coalesce(
      (
        select array_agg(distinct public.brief_step_renumber_up(s) order by public.brief_step_renumber_up(s))
        from unnest(p_steps) as s
      ),
      '{}'::smallint[]
    )
  end
$$;

-- ============================================================================
-- 3. brief_progress_step_renumber_up — remap, then clamp to <= 7
-- ============================================================================
-- The clamp is a documented invariant, not a live correction: every mapped
-- value already lands in 1..7 (see the CASE above), so `least(..., 7)` never
-- actually changes anything today. It stays because the brief calls for it
-- explicitly, and because it is the cheapest possible guard against a future
-- edit to the CASE producing an out-of-range value that would otherwise
-- violate `project_briefs_progress_step_check` at UPDATE time instead of
-- being caught here.

create or replace function public.brief_progress_step_renumber_up(p_progress int)
returns int
language sql
immutable
set search_path = ''
as $$
  select least(public.brief_step_renumber_up(p_progress::smallint)::int, 7)
$$;

-- ============================================================================
-- 4. The one-time data migration
-- ============================================================================

update public.project_briefs
set
  completed_steps = public.brief_completed_steps_renumber_up(completed_steps),
  progress_step   = public.brief_progress_step_renumber_up(progress_step);

-- DOWN
-- -- LOSSY in one direction, documented: the up-mapping collapses old steps 5
-- -- and 6 onto a single new step 6, so a brief with new completed_steps
-- -- containing 6 cannot be told apart from "completed old 5", "completed old
-- -- 6", or "completed both" once downgraded. This picks old step 5
-- -- arbitrarily (not old 6) on the down-map -- a real rollback would need to
-- -- accept losing that distinction, which is exactly what "lossy" means here.
-- --
-- -- create or replace function public.brief_step_renumber_down(p_step smallint)
-- -- returns smallint
-- -- language sql
-- -- immutable
-- -- set search_path = ''
-- -- as $$
-- --   select case p_step
-- --     when 5 then 4::smallint
-- --     when 6 then 5::smallint  -- lossy: could have been old 5, old 6, or both
-- --     when 7 then 7::smallint
-- --     else p_step
-- --   end
-- -- $$;
-- --
-- -- create or replace function public.brief_completed_steps_renumber_down(p_steps smallint[])
-- -- returns smallint[]
-- -- language sql
-- -- immutable
-- -- set search_path = ''
-- -- as $$
-- --   select case
-- --     when p_steps is null then null
-- --     else coalesce(
-- --       (
-- --         select array_agg(distinct public.brief_step_renumber_down(s) order by public.brief_step_renumber_down(s))
-- --         from unnest(p_steps) as s
-- --         where s <> 4  -- the new "How you work" step has no old-step equivalent
-- --       ),
-- --       '{}'::smallint[]
-- --     )
-- --   end
-- -- $$;
-- --
-- -- update public.project_briefs
-- -- set
-- --   completed_steps = public.brief_completed_steps_renumber_down(completed_steps),
-- --   progress_step   = least(public.brief_step_renumber_down(progress_step::smallint)::int, 7);
-- --
-- -- drop function if exists public.brief_completed_steps_renumber_down(smallint[]);
-- -- drop function if exists public.brief_step_renumber_down(smallint);
-- drop function if exists public.brief_progress_step_renumber_up(int);
-- drop function if exists public.brief_completed_steps_renumber_up(smallint[]);
-- drop function if exists public.brief_step_renumber_up(smallint);
