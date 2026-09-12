-- ============================================================================
-- `not (x and NULL)` is NULL, and NULL does not pass a WHERE clause
-- ============================================================================
-- Correction to the `unwarned_trials()` shipped minutes earlier in the same
-- session. Its own header said a NULL `trial_notice_state` must count as
-- UNWARNED — a row stamped by the code that predates that migration recorded
-- an ATTEMPT, and giving it the benefit of the doubt is the exact defect the
-- whole guarantee exists to remove.
--
-- The SQL said the opposite of the comment:
--
--   and not (stamped_for = trial_end and state in ('accepted','delivered'))
--
-- With `state` NULL, `state in (...)` is NULL, `true and NULL` is NULL,
-- `not NULL` is NULL — and a NULL predicate does not pass a WHERE clause. The
-- row was therefore EXCLUDED from the report, i.e. silently treated as warned.
--
-- ⚠ THE FAILURE WAS IN THE DANGEROUS DIRECTION. Not "the glance is noisy" but
-- "the glance says zero while somebody is about to be charged unwarned", which
-- is the precise sentence this feature was built to make impossible.
--
-- Measured before the fix, in a rolled-back transaction: one trialing row,
-- stamped for its own trial_end, state NULL. `unwarned_trials(14)` returned
-- total 0. It must return 1. Pinned in the test file so it cannot come back.
--
-- Three-valued logic is not a footnote in a predicate that decides whether
-- somebody gets charged. `coalesce(..., false)` is the whole fix, and the
-- reason the check now reads as "prove it was warned" rather than "prove it
-- was not".
-- ============================================================================

create or replace function public.unwarned_trials(p_within_days integer default 14)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with due as (
    select s.user_id,
           s.stripe_subscription_id,
           s.trial_end,
           s.trial_notice_sent_for,
           s.trial_notice_state,
           s.trial_extensions,
           extract(epoch from (s.trial_end - now())) / 86400.0 as days_left
      from public.subscriptions s
     where s.status = 'trialing'
       and s.trial_end is not null
       and s.trial_end >= now()
       and s.trial_end <= now() + make_interval(days => greatest(p_within_days, 0))
       /*
        * ⚠ PROVE IT WAS WARNED. Anything unknown — a NULL state, a NULL stamp,
        * a stamp for a different date — is UNWARNED. `coalesce(..., false)` is
        * what makes the unknown fall on the safe side instead of vanishing
        * out of the WHERE clause.
        */
       and not coalesce(
             s.trial_notice_sent_for = s.trial_end
             and s.trial_notice_state in ('accepted', 'delivered'),
           false)
  )
  select jsonb_build_object(
    'total', (select count(*) from due),
    'soonest', (select min(trial_end) from due),
    'within_days', greatest(p_within_days, 0),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', d.user_id,
        'stripe_subscription_id', d.stripe_subscription_id,
        'trial_end', d.trial_end,
        'days_left', round(d.days_left::numeric, 1),
        'notice_state', coalesce(d.trial_notice_state, 'none'),
        'stamped_for', d.trial_notice_sent_for,
        'extensions', d.trial_extensions
      ) order by d.trial_end)
      from due d
    ), '[]'::jsonb)
  );
$function$;

revoke execute on function public.unwarned_trials(integer) from public, anon, authenticated;
