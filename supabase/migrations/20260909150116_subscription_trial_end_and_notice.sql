-- ============================================================================
-- Eklio — the trial, on the subscription row that already tells the truth
-- ============================================================================
-- Practice Suite now includes three months of Monthly Presence, and it is
-- implemented as the SUBSCRIPTION: Stripe creates a real subscription with a
-- 90-day trial, `status` is `trialing`, and `active` (generated, added in
-- 20260827106000) is ALREADY true for `trialing`. Nothing about entitlement
-- changes here, and that is the point — there is no second way to be entitled,
-- no included_months counter, no boolean, no date the app compares itself.
--
-- ⚠ NEITHER COLUMN BELOW IS AN ENTITLEMENT INPUT. `active` still reads
-- `status` and only `status`; `isEntitledToMonthlyPresence` in the frontend
-- still reads `status` (+ the past_due grace). Both columns added here exist
-- so we can WRITE TO HER before we charge her, and they are never consulted to
-- decide whether she may open anything.
-- ============================================================================


-- ============================================================================
-- 1. trial_end — Stripe's own field, mirrored like status and period end
-- ============================================================================
-- WHY NOT DERIVE IT FROM `current_period_end`. During a trial the two coincide
-- in Stripe today: the current period runs to the trial end. But that is
-- Stripe's behaviour, not our invariant, and the notice built on it is a legal
-- artifact that must name the right date (see §2). Copying Stripe's own
-- `trial_end` is one fact copied once — exactly what `status` and
-- `current_period_end` already are on this row — rather than a second fact
-- inferred from a first.
--
-- Null for every subscription that is not and has never been on a trial, which
-- is every row in production today.

alter table public.subscriptions
  add column if not exists trial_end timestamptz;

comment on column public.subscriptions.trial_end is
  'Mirror of Stripe subscription.trial_end. NOT an entitlement input: `active` and the frontend gate read `status`. Exists so the pre-charge notice can name the exact date, and so the sweep can find trials about to convert.';


-- ============================================================================
-- 2. trial_notice_sent_for — WHICH trial end we warned about, not whether
-- ============================================================================
-- California's Automatic Renewal Law (Bus. & Prof. Code § 17602, as amended
-- 1 July 2025) requires, for a free trial longer than 31 days, a notice
-- between 3 and 21 days before it converts, naming the renewal terms, the
-- amount, the frequency, and how to cancel. Ninety days is longer than 31, so
-- the notice is not a courtesy — and this product has no post-purchase refund
-- primitive, so it is the only mitigation there is.
--
-- ⚠ A TIMESTAMP, NOT A BOOLEAN, and the difference is the whole reliability
-- argument:
--
--   * a replayed sweep does not write twice — it compares this to `trial_end`
--     and finds them equal;
--   * a trial that gets EXTENDED (she buys Practice Suite again, or support
--     moves the date) gets a NEW notice, because the value no longer matches.
--     A boolean would have silently swallowed the second warning, and the
--     charge she was warned about would not be the charge she got.
--
-- Nulled by the same rule when a fresh trial starts: the writer sets it only
-- after a send, and a new `trial_end` makes any old value non-matching.

alter table public.subscriptions
  add column if not exists trial_notice_sent_for timestamptz;

comment on column public.subscriptions.trial_notice_sent_for is
  'The trial_end value we have already sent the pre-charge notice for. Compared against trial_end: equal means sent, different (or null) means owed. A timestamp rather than a boolean so an EXTENDED trial earns a fresh notice.';


-- ============================================================================
-- 3. The sweep's index
-- ============================================================================
-- The daily sweep asks one question: which trialing subscriptions end inside
-- the notice window? Partial on `status = 'trialing'`, because every other row
-- is permanently irrelevant to it and there is no reason to carry them.

create index if not exists subscriptions_trialing_ending_idx
  on public.subscriptions (trial_end)
  where status = 'trialing';


-- ============================================================================
-- 4. Guard rails — assert what this migration claims
-- ============================================================================
do $$
declare
  c text;
begin
  foreach c in array array['trial_end', 'trial_notice_sent_for']
  loop
    if not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'subscriptions' and column_name = c
    ) then
      raise exception 'subscription_trial: subscriptions.% is missing.', c;
    end if;
  end loop;

  -- ⚠ THE ONE THAT MATTERS. If `active` ever learns to read `trial_end`, there
  -- are two ways to be entitled and they will disagree. Pin the definition.
  if not exists (
    select 1 from pg_attrdef d
      join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
     where d.adrelid = 'public.subscriptions'::regclass
       and a.attname = 'active'
       and pg_get_expr(d.adbin, d.adrelid) like '%trialing%'
       and pg_get_expr(d.adbin, d.adrelid) not like '%trial_end%'
  ) then
    raise exception
      'subscription_trial: subscriptions.active no longer reads status alone — a second way to be entitled has appeared.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop index if exists public.subscriptions_trialing_ending_idx;
--   alter table public.subscriptions drop column if exists trial_notice_sent_for;
--   alter table public.subscriptions drop column if exists trial_end;
