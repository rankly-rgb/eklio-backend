-- ============================================================================
-- A trial whose notice was not delivered does not convert
-- ============================================================================
-- ⚠ WHAT THIS REPLACES, AND WHY THE OLD GUARD WAS NEVER THE GUARANTEE.
--
-- `RESEND_API_KEY` sat in the refuse-to-boot register of the frontend's
-- `lib/env/required.ts`, and on 2026-09-12 that register took the whole site
-- down over an unrelated variable. But the deeper problem is that the boot
-- guard NEVER PROTECTED WHAT IT APPEARED TO PROTECT. It fires only when the
-- key is missing AT DEPLOY TIME. It does nothing when:
--
--   - the key is revoked after a deploy;
--   - the Resend account is suspended or out of quota;
--   - Resend's API is down for a week;
--   - the message is accepted and then bounces.
--
-- In every one of those the app boots, keeps serving, and the notice still
-- never reaches her — which is the whole § 17602 exposure, untouched. The boot
-- refusal guarded one narrow deploy-time case, left the general case open, and
-- installed a total-outage switch to do it.
--
-- ── THE GUARANTEE THAT ACTUALLY HOLDS ───────────────────────────────────────
--
--   A TRIAL WHOSE NOTICE WAS NOT DELIVERED DOES NOT CONVERT.
--
-- If we could not warn her, we do not charge her. Not "we stamped the row",
-- not "we tried" — the trial extends, and failing that it cancels, rather than
-- converting unwarned. That holds against EVERY failure mode above, because it
-- is checked at the moment that matters rather than at boot.
--
-- ── ⚠ THE LIMIT OF THE WORD "DELIVERED", STATED HERE RATHER THAN IMPLIED ────
--
-- Resend's POST /emails returns 2xx and an id. THAT IS ACCEPTANCE, NOT
-- DELIVERY: it means Resend took custody of the message, not that a mail
-- server accepted it, not that it escaped a spam folder, and certainly not
-- that she read it. Real delivery evidence arrives later, on Resend's
-- webhooks (`email.delivered`, `email.bounced`, `email.complained`), which
-- this product does not consume yet.
--
-- So `trial_notice_state` is a VOCABULARY, not a boolean, and today only
-- 'accepted' is reachable. The column exists in its full shape now so that
-- wiring the webhook later is an INSERT of meaning rather than a migration of
-- structure — and so that nobody reads 'accepted' as 'delivered' because the
-- schema offered them no way to tell the difference.
--
-- The guarantee therefore reads, precisely: a trial that we cannot show was
-- ACCEPTED FOR DELIVERY does not convert. That is weaker than the sentence
-- above, it is the strongest thing this product can currently prove, and
-- saying so is the point.
-- ============================================================================

alter table public.subscriptions
  add column if not exists trial_notice_state text,
  add column if not exists trial_notice_provider_id text,
  add column if not exists trial_notice_accepted_at timestamptz,
  add column if not exists trial_extensions integer not null default 0,
  add column if not exists trial_guard_acted_at timestamptz;

comment on column public.subscriptions.trial_notice_state is
  'What is actually known about the pre-charge notice covering `trial_notice_sent_for`. ⚠ ''accepted'' means Resend took custody of the message (2xx + id) — NOT that it reached an inbox. ''delivered''/''bounced''/''complained'' require Resend webhooks, which are not wired yet and are the only way this column can ever say more than ''accepted''. NULL when no notice has been sent for the current trial end.';

comment on column public.subscriptions.trial_notice_provider_id is
  'Resend''s message id for that notice. Stored so a later webhook can upgrade `trial_notice_state` from ''accepted'' to what actually happened, and so a disputed charge has something to point at other than a boolean.';

comment on column public.subscriptions.trial_extensions is
  'How many times the trial guard pushed `trial_end` out because the notice could not be shown accepted. Not cosmetic: it is the counter that decides when extending stops and cancelling starts, so a trial cannot be extended forever by a permanently broken mailer.';

comment on column public.subscriptions.trial_guard_acted_at is
  'When the trial guard last extended or cancelled this subscription.';

alter table public.subscriptions
  drop constraint if exists subscriptions_trial_notice_state_check;
alter table public.subscriptions
  add constraint subscriptions_trial_notice_state_check
  check (trial_notice_state is null
         or trial_notice_state in ('accepted', 'delivered', 'bounced', 'complained', 'failed'));

-- A state is a statement ABOUT a notice, so it cannot exist without the date
-- that notice covered. The reverse is allowed: rows stamped before this
-- migration carry a date and no state, and they are treated as UNPROVEN.
alter table public.subscriptions
  drop constraint if exists subscriptions_trial_notice_state_needs_a_date;
alter table public.subscriptions
  add constraint subscriptions_trial_notice_state_needs_a_date
  check (trial_notice_state is null or trial_notice_sent_for is not null);

alter table public.subscriptions
  drop constraint if exists subscriptions_trial_extensions_sane;
alter table public.subscriptions
  add constraint subscriptions_trial_extensions_sane
  check (trial_extensions >= 0 and trial_extensions <= 12);

-- ---------------------------------------------------------------------------
-- What the morning glance reads
-- ---------------------------------------------------------------------------
-- ⚠ ZERO IS THE EXPECTED ANSWER, and that is why this is a function and not a
-- dashboard: it goes next to `orphaned_purchases()` in `npm run funnel`, where
-- a non-zero is meant to change what happens that day.
--
-- "Unwarned" is deliberately strict, and every clause is the strictness:
--
--   - the notice must be stamped FOR THIS EXACT trial_end. An extended trial
--     has a new date, so an older notice announced a charge that is no longer
--     the one coming.
--   - the state must be 'accepted' or 'delivered'. A NULL state is a row
--     stamped by code that predates this migration, and it is counted as
--     unwarned rather than given the benefit of the doubt — the whole defect
--     being fixed here is a stamp that recorded an attempt.
--   - 'bounced', 'complained' and 'failed' are NOT warned. A bounce is the
--     clearest possible evidence she was not told.
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
       and not (
         s.trial_notice_sent_for = s.trial_end
         and s.trial_notice_state in ('accepted', 'delivered')
       )
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

-- Eklio's own instrument, read by `npm run funnel` as service_role. A
-- therapist has no business calling it, and it names other people's accounts.
revoke execute on function public.unwarned_trials(integer) from public, anon, authenticated;
