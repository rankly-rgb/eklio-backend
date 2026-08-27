-- ============================================================================
-- Eklio — Monthly Presence state, readable in one row
-- ============================================================================
-- WHAT LOT 4 ALREADY DELIVERED, verified against the live schema before
-- writing a line of this file rather than assumed:
--
--   status                  text        not null   ✓
--   current_period_end      timestamptz            ✓
--   cancel_at_period_end    boolean     not null   ✓
--   stripe_subscription_id  text        not null   ✓  UNIQUE ✓
--   user_id                                        ✓  UNIQUE ✓
--
-- The unique constraint §7 asks for — the one the webhook handler upserts on —
-- is `subscriptions_stripe_subscription_id_key`, and it has been there since
-- lot 4. Nothing about it is changed here. `subscriptions_user_id_key` is the
-- second one, and it is the key the handler should actually upsert on: Stripe
-- keeps the same `sub_…` across periods, and the offer is a single add-on, so
-- one row per user is the invariant.
--
-- WHAT WAS MISSING: `active`. One boolean, and it is the only field of the five
-- the frontend cannot read without deciding something.
-- ============================================================================


-- ============================================================================
-- 1. active — a generated column, not a stored flag
-- ============================================================================
-- GENERATED ALWAYS ... STORED rather than a plain column the webhook writes.
-- A plain column would be a second copy of `status`, updated by the same
-- handler, in the same statement — and the day the two disagree is the day a
-- cancelled subscriber keeps their content or a paying one loses it. A
-- generated column cannot disagree with `status`; it is `status`, read
-- differently.
--
-- ⚠ THIS IS NOT THE GATING RULE, and the distinction is the one lot 4 made when
-- it refused to put gating in a CHECK. `active` answers exactly one question:
-- does Stripe consider this subscription live right now? It is a pure function
-- of `status`, with no clock in it.
--
-- What it deliberately does NOT decide:
--   * `past_due` — Stripe is still retrying the card. Whether that user keeps
--     Monthly Presence for another five days is a commercial choice, it changes
--     without a migration, and it belongs to the frontend.
--   * `current_period_end` in the past — needs `now()`, which is a clock, and a
--     clock has no place in a stored generated column.
--
-- So `active` is the floor the frontend builds its gate on, never the gate.
--
-- Safe to add in place: the table holds no rows on the US project. On a
-- populated table this ALTER rewrites it.

alter table public.subscriptions
  drop column if exists active;

alter table public.subscriptions
  add column active boolean
  generated always as (status = any (array['active'::text, 'trialing'::text])) stored;

comment on column public.subscriptions.active is
  'Generated from status: true for active and trialing. Stripe''s liveness only — NOT the gating decision. Grace on past_due and any comparison of current_period_end with the clock stay in eklio-frontend.';

comment on table public.subscriptions is
  'Monthly Presence subscription ($39/month). One row per user, upserted by the Stripe webhook (service_role). The whole state the frontend needs is readable in this single row: active, status, current_period_end, cancel_at_period_end, stripe_subscription_id.';


-- ============================================================================
-- 2. Guard rails — assert what was already true
-- ============================================================================
-- §7 asked for fields that mostly existed. Asserting them is what makes "add
-- nothing and say so" a checkable claim rather than a note in a commit message.

do $$
declare
  c text;
begin
  foreach c in array array['status', 'current_period_end', 'cancel_at_period_end',
                           'stripe_subscription_id', 'active']
  loop
    if not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'subscriptions' and column_name = c
    ) then
      raise exception
        'subscription_state: subscriptions.% is missing; Monthly Presence state is not readable in one row.', c;
    end if;
  end loop;

  -- The webhook's idempotent upsert rests entirely on this.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.subscriptions'::regclass
       and contype = 'u'
       and pg_get_constraintdef(oid) = 'UNIQUE (stripe_subscription_id)'
  ) then
    raise exception
      'subscription_state: no unique constraint on subscriptions.stripe_subscription_id; a replayed webhook would create a second subscription row.';
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.subscriptions'::regclass
       and contype = 'u'
       and pg_get_constraintdef(oid) = 'UNIQUE (user_id)'
  ) then
    raise exception
      'subscription_state: no unique constraint on subscriptions.user_id; a user could hold two concurrent subscriptions.';
  end if;

  -- `active` must track `status` and nothing else.
  if not exists (
    select 1 from pg_attribute
     where attrelid = 'public.subscriptions'::regclass
       and attname = 'active'
       and attgenerated = 's'
  ) then
    raise exception
      'subscription_state: subscriptions.active is not a stored generated column; it can drift from status.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   alter table public.subscriptions drop column if exists active;
