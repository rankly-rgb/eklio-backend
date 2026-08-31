-- ============================================================================
-- Tests — 20260831103000_brief_step_renumber.sql
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Single-value mapping matches the spec table exactly
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.brief_step_renumber_up(1::smallint) = 1;
  assert public.brief_step_renumber_up(2::smallint) = 2;
  assert public.brief_step_renumber_up(3::smallint) = 3;
  assert public.brief_step_renumber_up(4::smallint) = 5, 'old 4 -> new 5';
  assert public.brief_step_renumber_up(5::smallint) = 6, 'old 5 -> new 6';
  assert public.brief_step_renumber_up(6::smallint) = 6, 'old 6 -> new 6';
  assert public.brief_step_renumber_up(7::smallint) = 7;
end
$$;

-- ---------------------------------------------------------------------------
-- Dedup: completing both old 5 and old 6 collapses to a single 6
-- ---------------------------------------------------------------------------
do $$
declare v_result smallint[];
begin
  v_result := public.brief_completed_steps_renumber_up(array[1,2,3,5,6]::smallint[]);
  assert v_result = array[1,2,3,6]::smallint[], format('expected {1,2,3,6}, got %s', v_result);
end
$$;

-- ---------------------------------------------------------------------------
-- NULL-safety: NULL in, NULL out
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.brief_completed_steps_renumber_up(null) is null;
end
$$;

-- ---------------------------------------------------------------------------
-- Full fixture: old steps 1 through 7, including a brief that completed
-- both old step 5 and old step 6 (row 4), simulating the migration's UPDATE
-- against pre-existing rows (a fresh local database has none of its own, so
-- this reapplies the same mapping the migration's UPDATE uses, against rows
-- inserted here in the OLD shape).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000201', 'owner@example.com');
insert into public.projects (id, user_id, name) values
  ('10000000-0000-0000-0000-000000000201', 'aaaaaaaa-0000-0000-0000-000000000201', 'Fixture 1'),
  ('10000000-0000-0000-0000-000000000202', 'aaaaaaaa-0000-0000-0000-000000000201', 'Fixture 2'),
  ('10000000-0000-0000-0000-000000000203', 'aaaaaaaa-0000-0000-0000-000000000201', 'Fixture 3'),
  ('10000000-0000-0000-0000-000000000204', 'aaaaaaaa-0000-0000-0000-000000000201', 'Fixture 4'),
  ('10000000-0000-0000-0000-000000000205', 'aaaaaaaa-0000-0000-0000-000000000201', 'Fixture 5');

insert into public.project_briefs (project_id, progress_step, completed_steps) values
  ('10000000-0000-0000-0000-000000000201', 3, array[1,2]::smallint[]),
  ('10000000-0000-0000-0000-000000000202', 4, array[1,2,3]::smallint[]),
  ('10000000-0000-0000-0000-000000000203', 6, array[1,2,3,4]::smallint[]),
  ('10000000-0000-0000-0000-000000000204', 7, array[1,2,3,4,5,6]::smallint[]),  -- completed BOTH old 5 and old 6
  ('10000000-0000-0000-0000-000000000205', 7, array[1,2,3,4,5,6,7]::smallint[]);

update public.project_briefs
set
  completed_steps = public.brief_completed_steps_renumber_up(completed_steps),
  progress_step   = public.brief_progress_step_renumber_up(progress_step)
where project_id::text like '10000000%';

do $$
begin
  assert (select progress_step from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000201') = 3;
  assert (select completed_steps from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000201') = array[1,2]::smallint[];

  assert (select progress_step from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000202') = 5;
  assert (select completed_steps from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000202') = array[1,2,3]::smallint[];

  assert (select progress_step from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000203') = 6;
  assert (select completed_steps from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000203') = array[1,2,3,5]::smallint[];

  assert (select progress_step from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000204') = 7;
  assert (select completed_steps from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000204') = array[1,2,3,5,6]::smallint[],
    'a brief that completed both old 5 and old 6 must end with a SINGLE 6, not two';

  assert (select progress_step from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000205') = 7;
  assert (select completed_steps from public.project_briefs where project_id = '10000000-0000-0000-0000-000000000205') = array[1,2,3,5,6,7]::smallint[];

  -- Step 4 (the new "How you work" step) never appears for an existing
  -- brief: no OLD value maps to 4.
  assert not exists (
    select 1 from public.project_briefs
    where project_id::text like '10000000%' and completed_steps @> array[4]::smallint[]
  );
end
$$;

-- ---------------------------------------------------------------------------
-- DOWN round-trip on the same fixture, per migration header: lossy in the
-- documented direction only. Recreates the (commented-out, copy-paste) DOWN
-- functions locally to test the round trip without touching the real schema.
-- ---------------------------------------------------------------------------
create or replace function pg_temp.brief_step_renumber_down(p_step smallint)
returns smallint
language sql
immutable
as $$
  select case p_step
    when 4 then 4::smallint  -- no old equivalent; falls through unchanged
    when 5 then 4::smallint
    when 6 then 5::smallint  -- lossy: could have been old 5, old 6, or both
    when 7 then 7::smallint
    else p_step
  end
$$;

create or replace function pg_temp.brief_completed_steps_renumber_down(p_steps smallint[])
returns smallint[]
language sql
immutable
as $$
  select case
    when p_steps is null then null
    else coalesce(
      (
        select array_agg(distinct pg_temp.brief_step_renumber_down(s) order by pg_temp.brief_step_renumber_down(s))
        from unnest(p_steps) as s
        where s <> 4
      ),
      '{}'::smallint[]
    )
  end
$$;

do $$
begin
  -- Steps 1, 2, 3, 4, 7 round-trip cleanly.
  assert pg_temp.brief_step_renumber_down(public.brief_step_renumber_up(1::smallint)) = 1;
  assert pg_temp.brief_step_renumber_down(public.brief_step_renumber_up(2::smallint)) = 2;
  assert pg_temp.brief_step_renumber_down(public.brief_step_renumber_up(3::smallint)) = 3;
  assert pg_temp.brief_step_renumber_down(public.brief_step_renumber_up(4::smallint)) = 4;
  assert pg_temp.brief_step_renumber_down(public.brief_step_renumber_up(7::smallint)) = 7;

  -- Old step 6, alone, does NOT round-trip to itself: this is the
  -- documented lossy point (up(6)=6, down(6)=5, not 6).
  assert pg_temp.brief_step_renumber_down(public.brief_step_renumber_up(6::smallint)) = 5,
    'old step 6 must NOT round-trip to itself -- this is the documented lossy collapse';
end
$$;

do $$
declare
  v_up   smallint[];
  v_down smallint[];
begin
  -- Row 4's fixture: completed both old 5 and old 6.
  v_up := public.brief_completed_steps_renumber_up(array[1,2,3,5,6]::smallint[]);
  assert v_up = array[1,2,3,6]::smallint[];

  v_down := pg_temp.brief_completed_steps_renumber_down(v_up);
  assert v_down <> array[1,2,3,5,6]::smallint[],
    'up-then-down of a completed-both-5-and-6 brief must NOT recover the original set -- the collapse is genuinely lossy';
  assert v_down = array[1,2,3,5]::smallint[], format('expected the documented arbitrary down-choice {1,2,3,5}, got %s', v_down);
end
$$;

-- ---------------------------------------------------------------------------
-- The REALISTIC rollback scenario: a rollback happening AFTER users have
-- answered the NEW step 4 ("How you work"), which does not exist pre-
-- migration. progress_step = 4, completed_steps containing a literal 4.
-- ---------------------------------------------------------------------------
do $$
declare
  v_progress_down  int;
  v_completed_down smallint[];
begin
  -- She finished 1, 2, 3 and just finished "How you work" too, now sitting
  -- on (not yet completed) new step 5.
  v_progress_down  := least(pg_temp.brief_step_renumber_down(4::smallint)::int, 7);
  v_completed_down := pg_temp.brief_completed_steps_renumber_down(array[1,2,3,4]::smallint[]);

  -- No duplicates: the literal 4 is DROPPED before remapping, so it can
  -- never collide with a value something else maps to.
  assert v_completed_down = array[1,2,3]::smallint[],
    format('completed_steps={1,2,3,4} must down-map to {1,2,3} (4 dropped, no duplicates), got %s', v_completed_down);
  assert array_length(v_completed_down, 1) = (select count(distinct x) from unnest(v_completed_down) x),
    'down-mapped completed_steps must never contain a duplicate';

  -- progress_step passes through unchanged -- documented as coincidence,
  -- not recovered data: old step 4 is a DIFFERENT question (voice & tone).
  assert v_progress_down = 4,
    format('progress_step=4 must down-map to 4 (falls through, lands at OLD step 4 / voice & tone -- documented, not a bug), got %s', v_progress_down);
end
$$;

rollback;
