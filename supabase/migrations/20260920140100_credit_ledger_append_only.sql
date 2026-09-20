-- ============================================================================
-- Eklio — the credit ledger: append-only, and the only door to a paid call
-- ============================================================================
-- Sibling of `content_image_allowance` (`20260910083735` §6), and deliberately
-- NOT a replacement for it. That meter answers "how many cents of photographs
-- has this KIT spent this month"; this ledger answers "how many acts of each
-- KIND has this USER spent this month, and what did they actually cost". Two
-- different grains, two different questions, and merging them would put a
-- per-kit cents budget in charge of a per-user act quota.
--
-- ── ⚠ THE GRAIN, AND WHY IT IS THE USER HERE AND THE KIT THERE ───────────
--
-- Every other Content table is keyed on `brand_kit_id`, and `DIAGNOSTIC.md`
-- §0.5 flagged that the chantier brief wrote `user_id` throughout. The split
-- is not a compromise, it follows the money:
--
--   * Monthly Presence is bought ONCE PER USER. `subscriptions.user_id` is
--     `not null unique` — one subscription per person, never per kit. A
--     regeneration allowance that reset per kit would multiply by the number
--     of kits she owns, and `countUnpaidProjects` lets her have three.
--   * Content is written PER KIT, because a caption belongs to a brand.
--
-- So credits are per user; topics, assets and posts stay per kit. The join
-- between them is `brand_kits → projects.user_id`, which is the same join
-- every Content policy already makes.
--
-- ── ⚠ APPEND-ONLY MEANS SETTLEMENT IS A ROW, NOT AN UPDATE ───────────────
--
-- The brief asks for both "no UPDATE, no DELETE" and "settle_credit writes
-- actual_cost_usd after the call". Those are only compatible one way: an
-- outcome is a NEW ENTRY that names the reservation it closes.
--
--   reservation   delta = -1   estimated_cost_usd set, actual_cost_usd null
--   settlement    delta =  0   actual_cost_usd set, reservation_id set
--   release       delta = +1   the credit comes back, reservation_id set
--
-- The balance is `-sum(delta)` and it is therefore a fact about rows that can
-- never be edited. A reservation that was never settled is visible as a row
-- with no outcome, which is what lets the 15-minute sweeper find it — a state
-- an UPDATE-in-place ledger cannot express at all, because a stuck row and a
-- settled row look the same.
--
-- ⚠ `swap` IS RECORDED WITH `delta = 0`. It is free and unlimited: it only
-- draws from the topic bank and calls no model. It is written down anyway,
-- because "she swapped eleven times this month" is the signal that the bank's
-- scoring is wrong, and a free act that leaves no trace cannot be measured.
--
-- ── NULL-SAFETY ──────────────────────────────────────────────────────────
-- Every CHECK below is written so that NULL fails it, not passes it: a CHECK
-- rejects only on FALSE, so `x > 0` on a NULL x ACCEPTS. Nullable columns are
-- therefore always guarded as `col is null or <predicate>`, and never as a
-- bare predicate. The validators are added to the registry of
-- `20260830061119_null_safe_jsonb_validators` at the bottom of this file.
-- ============================================================================


-- ============================================================================
-- 1. credit_quotas — the defaults, as data rather than as literals
-- ============================================================================
-- "Modifiable SQL constants" as a catalogue table, for the same reason
-- `content_registers` is one: the numbers are needed in TWO places — the
-- trigger that enforces them and the meter the UI draws (PHASE 5.5) — and two
-- hard-coded lists holding the same four numbers is exactly the drift this
-- repo already paid for once with `min_tier`.
--
-- `monthly_limit IS NULL` means UNLIMITED. Not `-1`, not a large number: an
-- unlimited swap is the absence of a ceiling, and writing it as 2147483647
-- would make "unlimited" a number someone could reach.

create table if not exists public.credit_quotas (
  plan          text     not null,
  kind          text     not null,
  monthly_limit integer,
  constraint credit_quotas_pkey primary key (plan, kind),
  constraint credit_quotas_plan_check check (plan in ('standard', 'trial')),
  constraint credit_quotas_kind_check check
    (kind in ('post_generation', 'swap', 'regeneration', 'custom_visual')),
  -- NULL is unlimited and legal; a number must be a count, so zero or more.
  constraint credit_quotas_limit_check check (monthly_limit is null or monthly_limit >= 0)
);

comment on table public.credit_quotas is
  'How many acts of each kind a plan may spend per calendar month. monthly_limit NULL means unlimited -- never a sentinel number, because an unlimited swap is the absence of a ceiling, not a ceiling nobody reaches. Read by the enforcing trigger AND by the credits meter, which is why it is a table and not two copies of four literals.';
comment on column public.credit_quotas.plan is
  'standard for a paid or comped subscriber; trial for one still inside the Stripe trial. Derived by credit_plan_for(uuid), never stored on the user.';

insert into public.credit_quotas (plan, kind, monthly_limit) values
  -- The month itself: thirty posts. This is the count the generation cron
  -- reserves against, one per post, so a rerun of a finished month refuses.
  ('standard', 'post_generation',  30),
  -- ⚠ UNLIMITED, AND THE PRODUCT DEPENDS ON IT. Swap is the one action that
  -- must never make her hesitate: it draws a different topic from the bank
  -- and calls nothing. Metering it would turn "this one isn't me" into a
  -- budget decision.
  ('standard', 'swap',            null),
  ('standard', 'regeneration',     10),
  ('standard', 'custom_visual',     4),
  -- Trial credits are SEPARATE and smaller, and carry NO custom visual: the
  -- paid image path is the only one that spends real money per call, and a
  -- trial that has not charged a card yet does not open it. Zero rather than
  -- an absent row, so the refusal is a quota answer and not a lookup miss.
  ('trial',    'post_generation',   8),
  ('trial',    'swap',             null),
  ('trial',    'regeneration',      3),
  ('trial',    'custom_visual',     0)
on conflict (plan, kind) do update
  set monthly_limit = excluded.monthly_limit;

alter table public.credit_quotas enable row level security;

drop policy if exists "credit_quotas_select_all"    on public.credit_quotas;
drop policy if exists "credit_quotas_insert_denied" on public.credit_quotas;
drop policy if exists "credit_quotas_update_denied" on public.credit_quotas;
drop policy if exists "credit_quotas_delete_denied" on public.credit_quotas;

-- A catalogue: any signed-in caller may read it (the meter lists it), nobody
-- but a migration may write it.
create policy "credit_quotas_select_all" on public.credit_quotas
  for select to authenticated using (true);
create policy "credit_quotas_insert_denied" on public.credit_quotas
  for insert with check (false);
create policy "credit_quotas_update_denied" on public.credit_quotas
  for update using (false);
create policy "credit_quotas_delete_denied" on public.credit_quotas
  for delete using (false);


-- ============================================================================
-- 2. credit_ledger — append-only
-- ============================================================================

create table if not exists public.credit_ledger (
  id                 uuid        not null default gen_random_uuid(),
  user_id            uuid        not null references auth.users (id) on delete cascade,
  kind               text        not null,
  entry_type         text        not null,
  -- Credits taken are NEGATIVE, credits returned POSITIVE, and an entry that
  -- moves nothing is 0. The balance is -sum(delta) over a month.
  delta              integer     not null,
  reason             text        not null,
  ref_type           text,
  ref_id             uuid,
  -- The reservation this entry closes. NULL on a reservation itself.
  reservation_id     uuid        references public.credit_ledger (id) on delete restrict,
  -- ⚠ THE MONTH IS STORED, NOT DERIVED FROM created_at. A reservation taken at
  -- 23:59 on the 31st and settled at 00:01 belongs to the reservation's month,
  -- or the settlement would land in a month that never reserved anything.
  month              date        not null,
  estimated_cost_usd numeric(12, 6),
  actual_cost_usd    numeric(12, 6),
  provider           text,
  model              text,
  created_at         timestamptz not null default now(),

  constraint credit_ledger_pkey primary key (id),
  constraint credit_ledger_kind_check check
    (kind in ('post_generation', 'swap', 'regeneration', 'custom_visual')),
  constraint credit_ledger_entry_type_check check
    (entry_type in ('reservation', 'settlement', 'release')),
  constraint credit_ledger_month_check check (month = date_trunc('month', month)::date),
  constraint credit_ledger_reason_check check (btrim(reason) <> ''),
  -- Nullable, so guarded as `is null or` — a bare `>= 0` would ACCEPT a NULL,
  -- since a CHECK rejects only on FALSE.
  constraint credit_ledger_estimated_check check
    (estimated_cost_usd is null or estimated_cost_usd >= 0),
  constraint credit_ledger_actual_check check
    (actual_cost_usd is null or actual_cost_usd >= 0),
  constraint credit_ledger_provider_check check
    (provider is null or btrim(provider) <> ''),
  constraint credit_ledger_model_check check
    (model is null or btrim(model) <> ''),
  constraint credit_ledger_ref_check check
    ((ref_type is null) = (ref_id is null)),

  -- ── the shape of each entry type, spelled out ──────────────────────────
  -- A reservation opens; it names no reservation and knows no actual cost.
  constraint credit_ledger_reservation_shape_check check (
    entry_type <> 'reservation'
    or (reservation_id is null and actual_cost_usd is null and delta <= 0)
  ),
  -- A settlement closes one and carries the real cost. It moves no credit:
  -- the reservation already took it.
  constraint credit_ledger_settlement_shape_check check (
    entry_type <> 'settlement'
    or (reservation_id is not null and delta = 0)
  ),
  -- A release closes one and gives the credit back. It never has a cost:
  -- nothing was spent.
  constraint credit_ledger_release_shape_check check (
    entry_type <> 'release'
    or (reservation_id is not null and delta >= 0 and actual_cost_usd is null)
  ),
  -- ⚠ A swap moves nothing, whatever the entry type. This is the constraint
  -- that makes "free and unlimited" structural rather than a promise the RPC
  -- keeps: a future writer that tries to charge for a swap is refused by the
  -- row, not by the function it forgot to call.
  constraint credit_ledger_swap_is_free_check check (kind <> 'swap' or delta = 0)
);

comment on table public.credit_ledger is
  'Every act that could cost money, as an append-only journal. UPDATE and DELETE are refused by policy AND by trigger. An outcome is a NEW ROW naming its reservation (settlement or release), never an edit -- which is also what makes a stuck reservation visible to the 15-minute sweeper, since an edited-in-place ledger cannot tell a stuck row from a settled one.';
comment on column public.credit_ledger.delta is
  'Credits taken are negative, returned positive, and 0 moves nothing. A swap is always 0: it draws a different topic from the bank and calls no model.';
comment on column public.credit_ledger.month is
  'The calendar month this entry is counted in. STORED, not derived from created_at: a settlement at 00:01 on the 1st closes a reservation taken at 23:59 on the 31st, and both belong to the reservation''s month.';
comment on column public.credit_ledger.actual_cost_usd is
  'What the call really cost, written by settle_credit ON A NEW ROW. NULL on a reservation (not yet known) and on a release (nothing was spent).';

-- ⚠ ONE OUTCOME PER RESERVATION, EVER. Without this, a retried settle_credit
-- writes a second settlement, and a reservation that was released and then
-- settled would return a credit AND spend it.
create unique index if not exists credit_ledger_one_outcome_per_reservation
  on public.credit_ledger (reservation_id)
  where entry_type in ('settlement', 'release');

create index if not exists credit_ledger_user_month_idx
  on public.credit_ledger (user_id, month desc, kind);

-- The sweeper's index: open reservations, oldest first. Partial, because a
-- settled reservation is never swept and there are far more of those.
create index if not exists credit_ledger_open_reservations_idx
  on public.credit_ledger (created_at)
  where entry_type = 'reservation';


-- ============================================================================
-- 3. credit_balances — derived, and written ONLY by the trigger in §5
-- ============================================================================
-- A TABLE, not a materialized view. A materialized view is refreshed by
-- `REFRESH MATERIALIZED VIEW`, which takes a lock over the whole relation and
-- cannot run inside a row trigger without serialising every reservation in the
-- product behind one another.

create table if not exists public.credit_balances (
  user_id            uuid        not null references auth.users (id) on delete cascade,
  kind               text        not null,
  month              date        not null,
  -- -sum(delta): how many credits of this kind this month has actually taken.
  consumed           integer     not null default 0,
  reservations       integer     not null default 0,
  settlements        integer     not null default 0,
  releases           integer     not null default 0,
  estimated_cost_usd numeric(14, 6) not null default 0,
  actual_cost_usd    numeric(14, 6) not null default 0,
  updated_at         timestamptz not null default now(),

  constraint credit_balances_pkey primary key (user_id, kind, month),
  constraint credit_balances_kind_check check
    (kind in ('post_generation', 'swap', 'regeneration', 'custom_visual')),
  constraint credit_balances_month_check check (month = date_trunc('month', month)::date),
  constraint credit_balances_consumed_check     check (consumed >= 0),
  constraint credit_balances_reservations_check check (reservations >= 0),
  constraint credit_balances_settlements_check  check (settlements >= 0),
  constraint credit_balances_releases_check     check (releases >= 0),
  constraint credit_balances_estimated_check    check (estimated_cost_usd >= 0),
  constraint credit_balances_actual_check       check (actual_cost_usd >= 0),
  -- A reservation is closed at most once (§2's unique index), so outcomes can
  -- never outnumber reservations. This is the row-level echo of that index.
  constraint credit_balances_outcomes_check
    check (settlements + releases <= reservations)
);

comment on table public.credit_balances is
  'The running total of credit_ledger, per (user, kind, month). Written ONLY by credit_ledger_apply() -- never by hand, never by an RPC. A table rather than a materialized view because REFRESH takes a relation-wide lock and would serialise every reservation in the product.';
comment on column public.credit_balances.consumed is
  'Credits actually taken this month: -sum(delta). A reservation raises it, a release lowers it again, a settlement leaves it alone.';

create index if not exists credit_balances_user_month_idx
  on public.credit_balances (user_id, month desc);


-- ============================================================================
-- 4. The plan a user is on, and the ceiling that follows
-- ============================================================================
-- ⚠ DERIVED, NEVER STORED. A `plan` column on the user would be a second
-- source for a fact Stripe already owns, and the two would disagree the first
-- time a trial converted without the column being written.

create or replace function public.credit_plan_for(p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    -- A comp grant is the full paid product, so it is never on trial credits.
    when public.comp_grant_active(p_user) then 'standard'
    when exists (
      select 1 from public.subscriptions s
       where s.user_id = p_user and s.status = 'trialing'
    ) then 'trial'
    else 'standard'
  end
$$;

comment on function public.credit_plan_for(uuid) is
  'Which row of credit_quotas applies to this user: trial while the Stripe subscription is trialing, standard otherwise -- and standard for a comp grant, which is the full paid product. Derived, never stored: a plan column would be a second source for a fact Stripe owns. INTERNAL ONLY.';

revoke all on function public.credit_plan_for(uuid) from public, anon, authenticated;

create or replace function public.credit_monthly_limit(p_user uuid, p_kind text)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select q.monthly_limit
    from public.credit_quotas q
   where q.plan = public.credit_plan_for(p_user)
     and q.kind = p_kind
$$;

comment on function public.credit_monthly_limit(uuid, text) is
  'This user''s monthly ceiling for this kind, or NULL for unlimited. ⚠ NULL IS AMBIGUOUS HERE ON PURPOSE AND THE CALLER MUST NOT GUESS: it also comes back when the (plan, kind) pair has no row at all. credit_ledger_apply() treats an absent pair as a REFUSAL by checking the row''s existence separately -- fail closed, never "no row means no ceiling". INTERNAL ONLY.';

revoke all on function public.credit_monthly_limit(uuid, text) from public, anon, authenticated;


-- ============================================================================
-- 5. credit_ledger_apply — the balance, and the ceiling, in one atomic act
-- ============================================================================
-- ⚠ VERIFY-THEN-CONSUME IN ONE STATEMENT, the same rule `reserve_content_image`
-- follows and for the same reason: there is still no post-purchase refund
-- primitive in this product, so a check followed by an increment can be raced
-- into an overspend that nothing can undo.
--
-- The UPDATE below is the check and the increment as a single act. It takes
-- the row lock, so a concurrent caller that was waiting re-evaluates the WHERE
-- against the row as the winner left it; when the WHERE fails, no row is
-- written, `row_count` is 0, and the exception rolls the ledger insert back
-- with it. Two simultaneous reservations cannot both pass the ceiling.
--
-- ── ⚠ WHY THIS IS NOT `insert … on conflict do update`, WHICH IT WAS ─────
--
-- Because PostgreSQL evaluates the proposed INSERT tuple's CHECK constraints
-- BEFORE it consults the arbiter index. The first draft here upserted, and the
-- guard rail below caught it on the very first settlement: the proposed tuple
-- for a settlement is `(reservations 0, settlements 1)`, which
-- `credit_balances_outcomes_check` refuses — and it was refused even though
-- that tuple was never going to be inserted, the row already existing.
--
-- The lesson is worth keeping: an upsert whose INSERT branch is unreachable
-- still has to be a LEGAL row. Rather than weaken the invariant to make an
-- impossible tuple legal, the row is created empty first and the deltas are
-- applied by the UPDATE — which is the only statement that ever moves a
-- number, and therefore the only one the ceiling has to guard.
--
-- The loop handles the one race that leaves: two transactions both finding no
-- row. One wins the primary key, the other catches `unique_violation`, loops,
-- and takes the UPDATE path — where the WHERE guards it like everyone else.

create or replace function public.credit_ledger_apply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit    integer;
  v_has_row  boolean;
  v_take     integer := -new.delta;   -- credits this entry takes (negative = gives back)
  v_written  boolean := false;
begin
  if new.entry_type = 'reservation' then
    select true, q.monthly_limit
      into v_has_row, v_limit
      from public.credit_quotas q
     where q.plan = public.credit_plan_for(new.user_id)
       and q.kind = new.kind;

    -- ⚠ FAIL CLOSED ON A MISSING PAIR. `credit_monthly_limit` returns NULL
    -- both for "unlimited" and for "no such row", and reading the second as
    -- the first would make a typo'd kind free and infinite.
    if not coalesce(v_has_row, false) then
      -- ⚠ EK011, NOT `check_violation`. See the header on the two codes.
      raise exception 'credit_ledger: no quota row for kind % on this user''s plan', new.kind
        using errcode = 'EK011';
    end if;
  end if;

  loop
    update public.credit_balances b
       set consumed           = b.consumed + v_take,
           reservations       = b.reservations
                                + case when new.entry_type = 'reservation' then 1 else 0 end,
           settlements        = b.settlements
                                + case when new.entry_type = 'settlement'  then 1 else 0 end,
           releases           = b.releases
                                + case when new.entry_type = 'release'     then 1 else 0 end,
           estimated_cost_usd = b.estimated_cost_usd + coalesce(new.estimated_cost_usd, 0),
           actual_cost_usd    = b.actual_cost_usd    + coalesce(new.actual_cost_usd, 0),
           updated_at         = now()
     where b.user_id = new.user_id
       and b.kind    = new.kind
       and b.month   = new.month
       -- THE CEILING, in the same statement that moves the number.
       and (v_limit is null
            or new.entry_type <> 'reservation'
            or b.consumed + v_take <= v_limit);

    get diagnostics v_written = row_count;
    exit when v_written;

    -- Nothing moved. Either the row exists and the ceiling refused it, or this
    -- is the month's first entry and there is no row yet. Those are different
    -- answers and only one of them is a refusal.
    if exists (
      select 1 from public.credit_balances b
       where b.user_id = new.user_id and b.kind = new.kind and b.month = new.month
    ) then
      raise exception 'credit_ledger: the monthly limit of % for % is exhausted',
        v_limit, new.kind
        using errcode = 'EK010';
    end if;

    begin
      insert into public.credit_balances (user_id, kind, month)
      values (new.user_id, new.kind, new.month);
    exception when unique_violation then
      -- Another transaction created it between our UPDATE and our INSERT.
      -- Loop: the UPDATE path guards it exactly as it guards everyone else.
      null;
    end;
  end loop;

  return null;   -- AFTER trigger; the return value is ignored
end
$$;

comment on function public.credit_ledger_apply() is
  'Maintains credit_balances from credit_ledger, and enforces the monthly ceiling in the SAME statement that increments the total. THE only writer of credit_balances. Refuses on a missing quota row rather than treating it as unlimited.';

-- ⚠ REVOKE, LIKE EVERY OTHER TRIGGER FUNCTION IN THIS SCHEMA. A function is
-- created with EXECUTE granted to `public` by default, and this repo also
-- grants to `anon` by DEFAULT PRIVILEGES. Left alone, a trigger function is
-- callable straight from the browser — and this one takes a trigger record, so
-- the call would merely fail, but `20260902090000_revoke_internal_function_surface`
-- made "no trigger function is reachable from a client" a rule with a test
-- behind it rather than a case-by-case judgement. That test is what caught
-- this file's first draft.
revoke all on function public.credit_ledger_apply() from public, anon, authenticated;

drop trigger if exists credit_ledger_apply on public.credit_ledger;
create trigger credit_ledger_apply
  after insert on public.credit_ledger
  for each row execute function public.credit_ledger_apply();


-- ============================================================================
-- 6. Append-only, enforced twice
-- ============================================================================
-- The policies below already refuse UPDATE and DELETE to every client. The
-- trigger refuses them to EVERYONE, service_role included — and service_role
-- bypasses RLS entirely, so without it the one role the pipeline actually runs
-- as would be the one role that could rewrite the journal.

-- ⚠ AND IT MUST STILL LET THE USER BE DELETED. The first version of this
-- trigger refused every DELETE, full stop — and the guard rail below caught
-- what that meant: `credit_ledger.user_id` is `on delete cascade`, so refusing
-- every DELETE made `delete from auth.users` FAIL. An append-only journal that
-- makes an account undeletable is not a journal, it is a hostage.
--
-- An `ON DELETE CASCADE` runs as an AFTER trigger on the PARENT, so by the
-- time the child row is being deleted the user row is already gone. That is
-- the difference, and it is checkable: the user still exists → somebody is
-- editing history; the user is gone → this is the cascade, let it through.
create or replace function public.credit_ledger_is_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE'
     and not exists (select 1 from auth.users u where u.id = old.user_id) then
    return old;
  end if;

  raise exception 'credit_ledger is append-only: % is refused. Correct an entry by appending another.',
    tg_op
    using errcode = 'restrict_violation';
end
$$;

comment on function public.credit_ledger_is_append_only() is
  'Refuses UPDATE and DELETE on credit_ledger for EVERY role, service_role included -- the policies alone would not, since service_role bypasses RLS and is the role the pipeline runs as. The ONE delete it allows is the FK cascade from a deleted auth.users row, told apart by the parent already being gone; without that exception an account could never be deleted.';

revoke all on function public.credit_ledger_is_append_only() from public, anon, authenticated;

drop trigger if exists credit_ledger_no_update on public.credit_ledger;
create trigger credit_ledger_no_update
  before update on public.credit_ledger
  for each row execute function public.credit_ledger_is_append_only();

drop trigger if exists credit_ledger_no_delete on public.credit_ledger;
create trigger credit_ledger_no_delete
  before delete on public.credit_ledger
  for each row execute function public.credit_ledger_is_append_only();


-- ============================================================================
-- 7. RLS
-- ============================================================================
alter table public.credit_ledger   enable row level security;
alter table public.credit_balances enable row level security;

drop policy if exists "credit_ledger_select_own"    on public.credit_ledger;
drop policy if exists "credit_ledger_insert_denied" on public.credit_ledger;
drop policy if exists "credit_ledger_update_denied" on public.credit_ledger;
drop policy if exists "credit_ledger_delete_denied" on public.credit_ledger;

-- ⚠ `user_id = (select auth.uid())` AND NEVER `<>` ANYWHERE. With no caller,
-- auth.uid() is NULL, the comparison is NULL, and a policy that is not TRUE
-- refuses. Written as a negation it would have been TRUE and shown the journal
-- to an anonymous reader.
create policy "credit_ledger_select_own" on public.credit_ledger
  for select using (user_id = (select auth.uid()));
create policy "credit_ledger_insert_denied" on public.credit_ledger
  for insert with check (false);
create policy "credit_ledger_update_denied" on public.credit_ledger
  for update using (false);
create policy "credit_ledger_delete_denied" on public.credit_ledger
  for delete using (false);

drop policy if exists "credit_balances_select_own"    on public.credit_balances;
drop policy if exists "credit_balances_insert_denied" on public.credit_balances;
drop policy if exists "credit_balances_update_denied" on public.credit_balances;
drop policy if exists "credit_balances_delete_denied" on public.credit_balances;

create policy "credit_balances_select_own" on public.credit_balances
  for select using (user_id = (select auth.uid()));
create policy "credit_balances_insert_denied" on public.credit_balances
  for insert with check (false);
create policy "credit_balances_update_denied" on public.credit_balances
  for update using (false);
create policy "credit_balances_delete_denied" on public.credit_balances
  for delete using (false);


-- ============================================================================
-- 8. reserve_credit — the ONLY door, and it is the entitlement chokepoint
-- ============================================================================
-- ⚠ NOTHING IN THIS PRODUCT MAY CALL A PAID API WITHOUT PASSING HERE FIRST.
-- The entitlement test is the first statement in the body, not a precondition
-- the caller is trusted to have checked, because a caller that forgets a
-- precondition gets a free call and nothing notices.

create or replace function public.reserve_credit(
  p_user               uuid,
  p_kind               text,
  p_reason             text,
  p_ref_type           text    default null,
  p_ref_id             uuid    default null,
  p_estimated_cost_usd numeric default null,
  p_provider           text    default null,
  p_model              text    default null,
  p_month              date    default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, now()))::date;
  v_id    uuid;
  v_delta integer;
begin
  if p_user is null then
    return jsonb_build_object('ok', false, 'reason', 'no_user');
  end if;

  if p_kind is null
     or p_kind not in ('post_generation', 'swap', 'regeneration', 'custom_visual') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_kind');
  end if;

  -- ⚠ THE CHOKEPOINT. Comp grants are already inside it.
  if not public.check_monthly_presence_entitlement(p_user) then
    return jsonb_build_object('ok', false, 'reason', 'not_entitled');
  end if;

  if p_estimated_cost_usd is not null and p_estimated_cost_usd < 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_cost');
  end if;

  -- A swap takes nothing; everything else takes one credit.
  v_delta := case when p_kind = 'swap' then 0 else -1 end;

  begin
    insert into public.credit_ledger
      (user_id, kind, entry_type, delta, reason, ref_type, ref_id, month,
       estimated_cost_usd, provider, model)
    values
      (p_user, p_kind, 'reservation', v_delta, coalesce(nullif(btrim(p_reason), ''), p_kind),
       p_ref_type, p_ref_id, v_month,
       case when p_kind = 'swap' then null else p_estimated_cost_usd end,
       p_provider, p_model)
    returning id into v_id;
  exception
    -- ⚠ ONLY THE TWO CODES credit_ledger_apply() RAISES, NEVER
    -- `check_violation` WHOLESALE. The first version caught check_violation,
    -- and the guard rail below caught it doing so: a malformed call (a
    -- ref_type with no ref_id, which the row's own CHECK refuses) came back to
    -- the caller as `quota_exhausted`. That is a lie about her account, and it
    -- would have sent someone to a checkout page to buy credits she already
    -- had. A shape violation is a programming error and must keep crossing
    -- the boundary as one.
    when sqlstate 'EK010' then
      return jsonb_build_object('ok', false, 'reason', 'quota_exhausted',
                                'kind', p_kind, 'month', v_month);
    when sqlstate 'EK011' then
      return jsonb_build_object('ok', false, 'reason', 'no_quota_configured',
                                'kind', p_kind);
  end;

  return jsonb_build_object('ok', true, 'reason', 'reserved',
                            'reservation_id', v_id, 'month', v_month);
end
$$;

comment on function public.reserve_credit(uuid, text, text, text, uuid, numeric, text, text, date) is
  'Reserves one credit BEFORE a paid call, or refuses having spent nothing. THE chokepoint: it calls check_monthly_presence_entitlement itself rather than trusting the caller to have done it. Returns {ok, reason, reservation_id, month}. A swap reserves with delta 0 -- recorded, free, and never counted against a ceiling.';

revoke all on function public.reserve_credit(uuid, text, text, text, uuid, numeric, text, text, date)
  from public, anon, authenticated;
grant execute on function public.reserve_credit(uuid, text, text, text, uuid, numeric, text, text, date)
  to service_role;


-- ============================================================================
-- 9. settle_credit — the outcome, as a new row
-- ============================================================================
-- Called AFTER the API call, with what it really cost. On failure it releases
-- instead: the credit comes back, and no cost is recorded, because nothing was
-- spent.

create or replace function public.settle_credit(
  p_reservation_id  uuid,
  p_actual_cost_usd numeric default null,
  p_succeeded       boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r           public.credit_ledger%rowtype;
  v_succeeded boolean := coalesce(p_succeeded, false);
  v_id        uuid;
begin
  if p_reservation_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_reservation');
  end if;

  -- ⚠ `for update` ON THE RESERVATION, not on the balance. Two concurrent
  -- settlements of the same reservation serialise here; the second then sees
  -- the outcome the first wrote and returns `already_settled` rather than
  -- colliding on the unique index and raising.
  select * into r
    from public.credit_ledger
   where id = p_reservation_id and entry_type = 'reservation'
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_such_reservation');
  end if;

  if exists (
    select 1 from public.credit_ledger o
     where o.reservation_id = r.id
       and o.entry_type in ('settlement', 'release')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'already_settled');
  end if;

  if p_actual_cost_usd is not null and p_actual_cost_usd < 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_cost');
  end if;

  insert into public.credit_ledger
    (user_id, kind, entry_type, delta, reason, ref_type, ref_id, reservation_id,
     month, actual_cost_usd, provider, model)
  values (
    r.user_id, r.kind,
    case when v_succeeded then 'settlement' else 'release' end,
    -- A settlement moves nothing: the reservation already took the credit.
    -- A release gives back exactly what it took.
    case when v_succeeded then 0 else -r.delta end,
    case when v_succeeded then 'settled: ' else 'released: ' end || r.reason,
    r.ref_type, r.ref_id, r.id,
    -- ⚠ THE RESERVATION'S MONTH, not today's. See the column comment.
    r.month,
    case when v_succeeded then p_actual_cost_usd else null end,
    r.provider, r.model
  )
  returning id into v_id;

  return jsonb_build_object('ok', true,
                            'reason', case when v_succeeded then 'settled' else 'released' end,
                            'entry_id', v_id);
end
$$;

comment on function public.settle_credit(uuid, numeric, boolean) is
  'Closes a reservation by APPENDING its outcome: a settlement carrying the real cost, or a release giving the credit back. Never an UPDATE -- the ledger refuses those. Idempotent by refusal: a second call answers already_settled rather than writing a second outcome.';

revoke all on function public.settle_credit(uuid, numeric, boolean) from public, anon, authenticated;
grant execute on function public.settle_credit(uuid, numeric, boolean) to service_role;


-- ============================================================================
-- 10. release_stale_credit_reservations — the fifteen-minute sweeper
-- ============================================================================
-- A reservation whose call never came back holds a credit forever. Fifteen
-- minutes is longer than any call this product makes, including a Batch poll.
--
-- ⚠ IT RELEASES, IT NEVER DELETES. The stuck reservation stays in the journal,
-- and the release names it. "This one hung" is a fact worth keeping.

create or replace function public.release_stale_credit_reservations(
  p_older_than interval default interval '15 minutes'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_count integer := 0;
begin
  for r in
    select l.*
      from public.credit_ledger l
     where l.entry_type = 'reservation'
       -- ⚠ ONLY RESERVATIONS THAT HOLD A CREDIT. A swap reserves with delta 0
       -- and has nothing to give back; sweeping it would write a release per
       -- swap per user per month -- fifty rows of noise saying nothing moved.
       -- "Open" is only a meaningful state for an entry that took something.
       and l.delta < 0
       and l.created_at < now() - coalesce(p_older_than, interval '15 minutes')
       and not exists (
         select 1 from public.credit_ledger o
          where o.reservation_id = l.id
            and o.entry_type in ('settlement', 'release')
       )
     order by l.created_at
     for update of l skip locked
  loop
    insert into public.credit_ledger
      (user_id, kind, entry_type, delta, reason, ref_type, ref_id, reservation_id, month,
       provider, model)
    values
      (r.user_id, r.kind, 'release', -r.delta,
       'released after ' || coalesce(p_older_than, interval '15 minutes')::text || ': ' || r.reason,
       r.ref_type, r.ref_id, r.id, r.month, r.provider, r.model);
    v_count := v_count + 1;
  end loop;

  return v_count;
end
$$;

comment on function public.release_stale_credit_reservations(interval) is
  'Gives back every credit held by a reservation older than p_older_than (default 15 minutes) with no outcome. Only entries with delta < 0 -- a swap holds nothing and has nothing to release. Appends a release naming the stuck reservation; never deletes it. `skip locked` so a sweep and a late settle_credit cannot fight over the same row. Compares against now(), the transaction clock, so rows written during a pass are never its own candidates.';

revoke all on function public.release_stale_credit_reservations(interval)
  from public, anon, authenticated;
grant execute on function public.release_stale_credit_reservations(interval) to service_role;


-- ============================================================================
-- 11. credit_meter — what the UI may read about ITSELF
-- ============================================================================
-- auth.uid()-scoped, and it is the only credit function a signed-in client may
-- call. PHASE 5.5 draws it: swaps unlimited, regenerations and custom visuals
-- finite. `limit` NULL means unlimited and the UI must print a word, not a
-- number.

create or replace function public.credit_meter(p_month date default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_object_agg(
      q.kind,
      jsonb_build_object(
        'limit',    q.monthly_limit,
        'consumed', coalesce(b.consumed, 0),
        'remaining', case
                       when q.monthly_limit is null then null
                       else greatest(q.monthly_limit - coalesce(b.consumed, 0), 0)
                     end
      )
    ),
    '{}'::jsonb
  )
    from public.credit_quotas q
    left join public.credit_balances b
      on b.user_id = (select auth.uid())
     and b.kind    = q.kind
     and b.month   = date_trunc('month', coalesce(p_month, now()))::date
   where (select auth.uid()) is not null
     and q.plan = public.credit_plan_for((select auth.uid()))
$$;

comment on function public.credit_meter(date) is
  'The calling user''s credits for a month, as {kind: {limit, consumed, remaining}}. A NULL limit means unlimited and remaining is NULL with it -- the UI prints a word there, never a number. auth.uid()-scoped; answers {} with no caller.';

revoke all on function public.credit_meter(date) from public, anon;
grant execute on function public.credit_meter(date) to authenticated, service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_user uuid;
  v_res  jsonb;
  v_res2 jsonb;
  v_id   uuid;
  v_n    integer;
  t      text;
  fn     text;
begin
  -- ---- RLS is on, and nothing is client-writable -------------------------
  foreach t in array array['credit_ledger', 'credit_balances', 'credit_quotas'] loop
    if not (select relrowsecurity from pg_class
             where oid = ('public.' || t)::regclass) then
      raise exception 'credit ledger: RLS is not enabled on %', t;
    end if;
    if exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t
         and cmd in ('INSERT', 'UPDATE', 'DELETE')
         and coalesce(qual, with_check) is distinct from 'false'
    ) then
      raise exception 'credit ledger: % has a write policy that is not `false`', t;
    end if;
  end loop;

  -- ---- the spending functions are service_role only ----------------------
  foreach fn in array array[
    'reserve_credit(uuid,text,text,text,uuid,numeric,text,text,date)',
    'settle_credit(uuid,numeric,boolean)',
    'release_stale_credit_reservations(interval)',
    'credit_plan_for(uuid)',
    'credit_monthly_limit(uuid,text)'
  ] loop
    if has_function_privilege('anon', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'anon can execute %', fn;
    end if;
    if has_function_privilege('authenticated', ('public.' || fn)::regprocedure, 'EXECUTE') then
      raise exception 'authenticated can execute %, which spends or probes another user''s credits', fn;
    end if;
  end loop;

  -- ---- no trigger function is reachable from a client --------------------
  foreach fn in array array['credit_ledger_apply()', 'credit_ledger_is_append_only()'] loop
    foreach t in array array['anon', 'authenticated'] loop
      if has_function_privilege(t, ('public.' || fn)::regprocedure, 'EXECUTE') then
        raise exception '% can execute the trigger function %', t, fn;
      end if;
    end loop;
  end loop;

  -- ---- the meter is the one door a client has ----------------------------
  if has_function_privilege('anon', 'public.credit_meter(date)'::regprocedure, 'EXECUTE') then
    raise exception 'anon can execute credit_meter';
  end if;
  if not has_function_privilege('authenticated', 'public.credit_meter(date)'::regprocedure, 'EXECUTE') then
    raise exception 'authenticated cannot execute credit_meter';
  end if;

  -- ---- every SECURITY DEFINER here has an empty search_path --------------
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and p.proname in ('credit_ledger_apply', 'credit_plan_for', 'credit_monthly_limit',
                         'reserve_credit', 'settle_credit',
                         'release_stale_credit_reservations', 'credit_meter')
       -- ⚠ THE LITERAL IS `search_path=""`, WITH THE QUOTES. That is how
       -- Postgres stores `set search_path = ''` in proconfig, and the repo
       -- already writes it this way in 20260830060712. Written as
       -- `search_path=` the assertion never matches and always fires.
       and not coalesce(p.proconfig, '{}') @> array['search_path=""']
  ) then
    raise exception 'credit ledger: a SECURITY DEFINER function has no `set search_path = ''''`';
  end if;

  -- ======================================================================
  -- Behaviour, against real rows
  -- ======================================================================
  v_user := gen_random_uuid();
  insert into auth.users (id, email) values (v_user, 'ledger-probe@example.invalid');

  -- ---- no entitlement, no credit -----------------------------------------
  v_res := public.reserve_credit(v_user, 'regeneration', 'probe');
  if v_res ->> 'reason' <> 'not_entitled' then
    raise exception 'reserve_credit: an unentitled user was served (%)', v_res;
  end if;
  if exists (select 1 from public.credit_ledger where user_id = v_user) then
    raise exception 'reserve_credit: a refusal still wrote a ledger entry.';
  end if;

  -- ---- entitle her, by comp grant (no fabricated Stripe row) -------------
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_user, 'ledger guard rail', 'migration 20260920140100', now() + interval '1 day');

  -- ---- a reservation takes exactly one ------------------------------------
  -- ⚠ ref_type AND ref_id TOGETHER. `credit_ledger_ref_check` refuses one
  -- without the other, and an earlier draft of this probe passed the type with
  -- a null id -- which is how the over-broad exception handler in §8 was found.
  v_res := public.reserve_credit(v_user, 'regeneration', 'probe',
                                 'content_item', gen_random_uuid(),
                                 0.004, 'anthropic', 'claude-haiku-4-5-20251001');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'reserve_credit: an entitled user was refused (%)', v_res;
  end if;
  v_id := (v_res ->> 'reservation_id')::uuid;

  select consumed into v_n from public.credit_balances
   where user_id = v_user and kind = 'regeneration'
     and month = date_trunc('month', now())::date;
  if v_n <> 1 then
    raise exception 'credit_balances: consumed is % after one reservation, expected 1', v_n;
  end if;

  -- ---- settling writes a ROW and leaves consumed alone --------------------
  v_res := public.settle_credit(v_id, 0.0031, true);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'settle_credit refused a live reservation (%)', v_res;
  end if;

  select consumed into v_n from public.credit_balances
   where user_id = v_user and kind = 'regeneration'
     and month = date_trunc('month', now())::date;
  if v_n <> 1 then
    raise exception 'credit_balances: settling changed consumed to %, expected 1', v_n;
  end if;
  if (select actual_cost_usd from public.credit_balances
       where user_id = v_user and kind = 'regeneration'
         and month = date_trunc('month', now())::date) <> 0.0031 then
    raise exception 'credit_balances: the real cost was not carried onto the balance.';
  end if;

  -- ---- settling twice is refused, not doubled -----------------------------
  v_res := public.settle_credit(v_id, 9.99, true);
  if (v_res ->> 'reason') <> 'already_settled' then
    raise exception 'settle_credit: a second settlement was accepted (%)', v_res;
  end if;

  -- ---- a release gives the credit back -------------------------------------
  v_res := public.reserve_credit(v_user, 'regeneration', 'probe that fails');
  v_res := public.settle_credit((v_res ->> 'reservation_id')::uuid, null, false);
  if (v_res ->> 'reason') <> 'released' then
    raise exception 'settle_credit(succeeded=false) did not release (%)', v_res;
  end if;
  select consumed into v_n from public.credit_balances
   where user_id = v_user and kind = 'regeneration'
     and month = date_trunc('month', now())::date;
  if v_n <> 1 then
    raise exception 'a release did not give the credit back: consumed is %, expected 1', v_n;
  end if;

  -- ---- the ceiling actually bites -----------------------------------------
  -- 10 regenerations a month on standard; one is already consumed.
  for v_n in 1..9 loop
    v_res := public.reserve_credit(v_user, 'regeneration', 'filling the month');
    if not (v_res ->> 'ok')::boolean then
      raise exception 'reserve_credit refused regeneration #% of 10 (%)', v_n + 1, v_res;
    end if;
  end loop;
  v_res := public.reserve_credit(v_user, 'regeneration', 'the eleventh');
  if (v_res ->> 'reason') <> 'quota_exhausted' then
    raise exception 'reserve_credit: the 11th regeneration of the month was served (%)', v_res;
  end if;
  select consumed into v_n from public.credit_balances
   where user_id = v_user and kind = 'regeneration'
     and month = date_trunc('month', now())::date;
  if v_n <> 10 then
    raise exception 'the refused 11th still moved the balance: consumed is %', v_n;
  end if;

  -- ---- next month starts fresh, structurally ------------------------------
  v_res := public.reserve_credit(v_user, 'regeneration', 'next month',
                                 null, null, null, null, null,
                                 (date_trunc('month', now()) + interval '1 month')::date);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'a new month did not start with a full allowance (%)', v_res;
  end if;

  -- ---- swaps are free and unlimited ---------------------------------------
  for v_n in 1..50 loop
    v_res := public.reserve_credit(v_user, 'swap', 'swapping');
    if not (v_res ->> 'ok')::boolean then
      raise exception 'swap #% was refused (%) -- swaps must be unlimited', v_n, v_res;
    end if;
  end loop;
  select consumed into v_n from public.credit_balances
   where user_id = v_user and kind = 'swap'
     and month = date_trunc('month', now())::date;
  if v_n <> 0 then
    raise exception 'fifty swaps consumed %, expected 0', v_n;
  end if;

  -- ---- a swap that tries to cost money is refused BY THE ROW --------------
  begin
    insert into public.credit_ledger
      (user_id, kind, entry_type, delta, reason, month)
    values (v_user, 'swap', 'reservation', -1, 'a swap that charges',
            date_trunc('month', now())::date);
    raise exception 'a swap with delta -1 was accepted; credit_ledger_swap_is_free_check does not bite.';
  exception when check_violation then null;
  end;

  -- ---- append-only, against service_role's own hand -----------------------
  begin
    update public.credit_ledger set reason = 'rewritten' where user_id = v_user;
    raise exception 'credit_ledger accepted an UPDATE.';
  exception when restrict_violation then null;
  end;
  begin
    delete from public.credit_ledger where user_id = v_user;
    raise exception 'credit_ledger accepted a DELETE.';
  exception when restrict_violation then null;
  end;

  -- ---- the sweeper releases what hung, and nothing else -------------------
  v_res  := public.reserve_credit(v_user, 'custom_visual', 'a call that hangs');
  v_id   := (v_res ->> 'reservation_id')::uuid;
  v_res2 := public.reserve_credit(v_user, 'custom_visual', 'a call that returns');
  v_res2 := public.settle_credit((v_res2 ->> 'reservation_id')::uuid, 0.02, true);

  if public.release_stale_credit_reservations(interval '15 minutes') <> 0 then
    raise exception 'the sweeper released a reservation younger than its window.';
  end if;

  -- ⚠ A NEGATIVE WINDOW, AND `interval '0'` WOULD NOT HAVE WORKED. The sweeper
  -- compares against `now()`, which inside a transaction is the transaction's
  -- start time — the same instant `created_at` defaulted to. So `created_at <
  -- now() - interval '0'` is FALSE for every row written in this block, and a
  -- zero window sweeps nothing. The rows cannot be backdated either: the
  -- ledger refuses UPDATE. So the window is pushed one second into the future
  -- instead, which is the same test from the other side.
  --
  -- `now()` is the right clock for the sweeper itself: a job that swept by
  -- `clock_timestamp()` would treat rows written during its own pass as
  -- candidates.
  v_n := public.release_stale_credit_reservations(interval '-1 second');

  -- The one that hung got its release, and it names the reservation.
  if not exists (
    select 1 from public.credit_ledger
     where reservation_id = v_id and entry_type = 'release'
  ) then
    raise exception 'the sweeper left the hung reservation open.';
  end if;

  -- The one that returned was NOT touched: its settlement still stands alone.
  if (select count(*) from public.credit_ledger
       where user_id = v_user and kind = 'custom_visual' and entry_type = 'release') <> 1 then
    raise exception 'the sweeper released a custom_visual that had already settled.';
  end if;

  select consumed into v_n from public.credit_balances
   where user_id = v_user and kind = 'custom_visual'
     and month = date_trunc('month', now())::date;
  if v_n <> 1 then
    raise exception 'after the sweep custom_visual consumed is %, expected 1 (the settled one only)', v_n;
  end if;

  -- ⚠ AND IT NEVER TOUCHED THE FIFTY SWAPS. They reserve with delta 0, so
  -- they hold nothing and have nothing to release.
  if exists (
    select 1 from public.credit_ledger
     where user_id = v_user and kind = 'swap' and entry_type = 'release'
  ) then
    raise exception 'the sweeper wrote a release for a swap, which holds no credit.';
  end if;

  -- ---- the trial plan carries no custom visual ----------------------------
  update public.comp_grants set revoked_at = now() where user_id = v_user;
  insert into public.subscriptions (user_id, stripe_subscription_id, status, current_period_end)
  values (v_user, 'sub_ledger_probe', 'trialing', now() + interval '14 days');

  if public.credit_plan_for(v_user) <> 'trial' then
    raise exception 'credit_plan_for: a trialing subscription is not on trial credits.';
  end if;
  v_res := public.reserve_credit(v_user, 'custom_visual', 'a trial asking for a paid image');
  if (v_res ->> 'reason') <> 'quota_exhausted' then
    raise exception 'a trial was served a custom visual (%)', v_res;
  end if;

  -- ---- a malformed call is a 500, NOT a fake quota refusal ---------------
  -- The regression this file was written twice for.
  begin
    v_res := public.reserve_credit(v_user, 'regeneration', 'probe', 'content_item', null);
    raise exception 'reserve_credit swallowed a shape violation and answered %', v_res;
  exception when check_violation then null;
  end;

  -- ---- an unknown kind is refused, never treated as unlimited -------------
  v_res := public.reserve_credit(v_user, 'not_a_kind', 'probe');
  if (v_res ->> 'reason') <> 'unknown_kind' then
    raise exception 'reserve_credit accepted an unknown kind (%)', v_res;
  end if;

  -- ---- NULLs answer, they do not crash and they do not grant --------------
  if (public.reserve_credit(null, 'regeneration', 'probe') ->> 'reason') <> 'no_user' then
    raise exception 'reserve_credit(null user) did not refuse.';
  end if;
  if (public.settle_credit(null) ->> 'reason') <> 'no_reservation' then
    raise exception 'settle_credit(null) did not refuse.';
  end if;
  if (public.settle_credit(gen_random_uuid()) ->> 'reason') <> 'no_such_reservation' then
    raise exception 'settle_credit(unknown) did not refuse.';
  end if;

  -- ---- teardown. The ledger refuses DELETE, so the cascade does it. -------
  delete from auth.users where id = v_user;
  if exists (select 1 from public.credit_ledger where user_id = v_user) then
    raise exception 'deleting the user left ledger rows behind.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.credit_meter(date);
--   drop function if exists public.release_stale_credit_reservations(interval);
--   drop function if exists public.settle_credit(uuid, numeric, boolean);
--   drop function if exists public.reserve_credit(uuid,text,text,text,uuid,numeric,text,text,date);
--   drop function if exists public.credit_monthly_limit(uuid, text);
--   drop function if exists public.credit_plan_for(uuid);
--   drop trigger  if exists credit_ledger_no_delete on public.credit_ledger;
--   drop trigger  if exists credit_ledger_no_update on public.credit_ledger;
--   drop function if exists public.credit_ledger_is_append_only();
--   drop trigger  if exists credit_ledger_apply on public.credit_ledger;
--   drop function if exists public.credit_ledger_apply();
--   drop table    if exists public.credit_balances;
--   drop table    if exists public.credit_ledger;
--   drop table    if exists public.credit_quotas;
