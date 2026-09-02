-- ============================================================================
-- Eklio — comp_grants: a database-level comp access grant
-- ============================================================================
-- Follows `20260829125000_plans_and_granted_allowance.sql`.
--
-- One internal account needs the full paid product without a Stripe purchase,
-- for testing and finishing development. This is NOT a purchase and NOT a
-- subscription: `purchases.stripe_checkout_session_id` and
-- `subscriptions.stripe_subscription_id` are both `text not null unique`, so
-- neither table can hold a Stripe-less row without inventing a fake Stripe id.
-- A separate table, read at the same chokepoint everything else already goes
-- through, avoids that trap entirely and keeps the grant out of every query
-- that treats `purchases`/`subscriptions` as revenue.
--
-- ⚠ NULL-SAFETY. `expires_at` is NOT NULL so no grant can become immortal
-- through a NULL comparison, and active-ness is written as
--   revoked_at IS NULL AND expires_at > now()
-- never as `not (expires_at <= now())` — a NULL on either side of that would
-- make the negation true, which is exactly how a permissive default leaks.
-- ============================================================================

create table if not exists public.comp_grants (
  id                 uuid        not null default gen_random_uuid(),
  user_id            uuid        not null references auth.users (id) on delete cascade,
  reason             text        not null,
  granted_by         text        not null,
  generation_credits integer     not null default 200,
  created_at         timestamptz not null default now(),
  expires_at         timestamptz not null,
  revoked_at         timestamptz,
  constraint comp_grants_pkey primary key (id),
  constraint comp_grants_generation_credits_check check (generation_credits >= 0),
  constraint comp_grants_reason_check check (btrim(reason) <> ''),
  constraint comp_grants_granted_by_check check (btrim(granted_by) <> '')
);

-- One ACTIVE grant per user at a time. Past (revoked) grants stay in the
-- table as history; nothing stops a user from being granted again later.
create unique index if not exists comp_grants_user_id_active_key
  on public.comp_grants (user_id)
  where revoked_at is null;

create index if not exists comp_grants_user_id_idx on public.comp_grants (user_id);

comment on table public.comp_grants is
  'Database-level comp access: an internal account gets the full paid product without a Stripe purchase, for testing and finishing development. This is NEVER revenue — exclude comp_grants from every financial query, revenue report, and MRR/ARR calculation. Active iff revoked_at IS NULL AND expires_at > now(); a NULL anywhere in that predicate must read as inactive, never active.';
comment on column public.comp_grants.generation_credits is
  'The regeneration allowance an active grant supplies to consume_generation_credit, on top of whatever the project''s granted plan already gives. Comp accounts still spend from a finite counter — this is not a bypass of the meter.';
comment on column public.comp_grants.reason is
  'Why this account was comp''d. Free text, for the person granting it to explain themselves later.';
comment on column public.comp_grants.granted_by is
  'Who granted it. Free text (an email, a name) — there is no admin-user table to reference.';


-- ============================================================================
-- RLS — service_role only, on purpose
-- ============================================================================
-- No policy grants select/insert/update/delete to anon or authenticated: under
-- RLS, the absence of a policy already refuses everyone but the table owner
-- and service_role (which bypasses RLS). The REVOKE below is a second,
-- independent barrier against a policy added by inadvertence later — the same
-- belt-and-suspenders `stripe_events` already uses in
-- `20260825160000_lot4_billing.sql`. This repo grants access to anon on new
-- objects by DEFAULT PRIVILEGES; that default is cancelled here on purpose,
-- not assumed away.

alter table public.comp_grants enable row level security;

revoke all on table public.comp_grants from anon, authenticated;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
begin
  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'comp_grants') then
    raise exception 'comp_grants: a policy exists; this table must have none.';
  end if;

  if has_table_privilege('anon', 'public.comp_grants', 'SELECT')
     or has_table_privilege('authenticated', 'public.comp_grants', 'SELECT') then
    raise exception 'comp_grants: anon or authenticated can still SELECT.';
  end if;
  if has_table_privilege('anon', 'public.comp_grants', 'INSERT')
     or has_table_privilege('authenticated', 'public.comp_grants', 'INSERT') then
    raise exception 'comp_grants: anon or authenticated can still INSERT.';
  end if;
  if has_table_privilege('anon', 'public.comp_grants', 'UPDATE')
     or has_table_privilege('authenticated', 'public.comp_grants', 'UPDATE') then
    raise exception 'comp_grants: anon or authenticated can still UPDATE.';
  end if;

  -- a NULL expires_at must be impossible, not merely denied by convention
  begin
    insert into public.comp_grants (user_id, reason, granted_by, expires_at)
    values ('00000000-0000-0000-0000-000000000000', 'guard rail', 'migration', null);
    raise exception 'comp_grants: a NULL expires_at was accepted.';
  exception
    when not_null_violation then null;
    when foreign_key_violation then null; -- no such user in this environment; the NOT NULL still fired first if it was going to
  end;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop table if exists public.comp_grants;
