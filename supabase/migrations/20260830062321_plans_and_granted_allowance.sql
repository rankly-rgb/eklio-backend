-- ============================================================================
-- Eklio — one place an allowance is written
-- ============================================================================
-- Follows `20260829124000_entitlement_rpc_surface.sql`.
--
-- ⚠ NOTHING IN THE SCHEMA DISTINGUISHED THE THREE TIERS. Searched every column,
-- default, CHECK, index, function body, catalog row and seed block: `starter`,
-- `practice` and `signature` appear in exactly two CHECK constraints that list
-- them, one column default (`brand_kits.tier`), and a comment naming the prices.
-- No value anywhere depends on which one was bought. Three prices, one product.
--
-- ⚠ AND THE PAID ALLOWANCE WAS NEVER EXPRESSED AT ALL.
-- `generation_credits.directions_limit` defaulted to 3 for every project, set by
-- `handle_new_project` BEFORE any purchase exists and therefore before any tier
-- is known, and nothing ever wrote it again. `20260829123000` read it as "runs"
-- and handed an entitled owner three of them. That was reusing a number that was
-- never about tiers.
--
-- The columns meant: three directions in one run, one regeneration — a FREE cap,
-- in disguise as a default. This migration takes the disguise off. The free
-- allowance comes from a `free` row like every other, so there is one place to
-- read and no default quietly disagreeing with it.
-- ============================================================================


-- ============================================================================
-- 1. plans
-- ============================================================================

create table if not exists public.plans (
  tier                text        not null,
  label               text        not null,
  price_cents         integer     not null,
  -- ⚠ NAMED FOR WHAT THEY MEAN, which is not what the old columns implied.
  directions_limit    smallint    not null,
  regenerations_limit smallint    not null,
  sort_order          smallint    not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint plans_pkey primary key (tier),
  constraint plans_tier_check
    check (tier = any (array['free', 'starter', 'practice', 'signature'])),
  constraint plans_label_check       check (btrim(label) <> ''),
  constraint plans_price_check       check (price_cents >= 0),
  constraint plans_free_is_free_check
    check ((tier = 'free') = (price_cents = 0)),
  constraint plans_directions_check  check (directions_limit between 1 and 12),
  constraint plans_regenerations_check check (regenerations_limit >= 0)
);

comment on table public.plans is
  'THE ONLY PLACE AN ALLOWANCE IS WRITTEN. One row per tier including free. Changing what a tier grants is a data edit here and nowhere else — not a column default, not a branch in a function, not a constant in a route.';
comment on column public.plans.directions_limit is
  'Directions produced by ONE generation run. Not a number of runs — that was the misreading this table exists to end.';
comment on column public.plans.regenerations_limit is
  'Runs allowed BEYOND the first. Total runs for a project is 1 + this.';
comment on column public.plans.price_cents is
  'One-time price of the kit at this tier, so the row is readable next to the pricing page. Not charged from here; Stripe is the authority on what was actually paid.';

alter table public.plans enable row level security;

drop policy if exists plans_select_all on public.plans;
create policy plans_select_all on public.plans for select to authenticated using (true);
drop policy if exists plans_insert_denied on public.plans;
create policy plans_insert_denied on public.plans for insert with check (false);
drop policy if exists plans_update_denied on public.plans;
create policy plans_update_denied on public.plans for update using (false);
drop policy if exists plans_delete_denied on public.plans;
create policy plans_delete_denied on public.plans for delete using (false);

revoke insert, update, delete on public.plans from authenticated, anon;
grant select on public.plans to authenticated;

drop trigger if exists set_plans_updated_at on public.plans;
create trigger set_plans_updated_at before update on public.plans
  for each row execute function public.set_updated_at();

-- >>> PLAN DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ⚠ THESE NUMBERS ARE THE DECISION. Nothing in the schema had ever
-- distinguished the tiers — they differed only in price — so this table is where
-- the difference now lives. Changing what a tier grants is an UPDATE here and
-- nowhere else; it must never become a code edit.
insert into public.plans (tier, label, price_cents, directions_limit, regenerations_limit, sort_order) values
  ('free',      'Free',      0,     3, 1,  0),
  ('starter',   'Starter',   7900,  3, 3,  1),
  ('practice',  'Practice',  14900, 3, 6,  2),
  ('signature', 'Signature', 24900, 3, 12, 3)
on conflict (tier) do update set
  label = excluded.label, price_cents = excluded.price_cents,
  directions_limit = excluded.directions_limit,
  regenerations_limit = excluded.regenerations_limit,
  sort_order = excluded.sort_order;

-- <<< PLAN DATA <<<


-- ============================================================================
-- 2. generation_credits records the plan it was granted, not a default
-- ============================================================================
-- ⚠ AUDIT BEFORE DROPPING. The two limit columns are removed because they are
-- the free cap in disguise. That is only safe if nothing ever wrote them — if a
-- row carries anything other than the old defaults, someone was using them and
-- this migration would be throwing away a real allowance.
do $$
declare n_custom int;
begin
  select count(*) into n_custom from public.generation_credits
   where directions_limit is distinct from 3::smallint
      or regenerations_limit is distinct from 1::smallint;
  if n_custom > 0 then
    raise exception
      'generation_credits: % row(s) carry a hand-set limit. Migrate them into plans before dropping the columns.',
      n_custom;
  end if;
  raise notice 'generation_credits: 0 rows carry a hand-set limit; the columns held only their defaults.';
end
$$;

alter table public.generation_credits
  add column if not exists plan_tier text not null default 'free';

alter table public.generation_credits
  drop constraint if exists generation_credits_plan_tier_fkey;
alter table public.generation_credits
  add constraint generation_credits_plan_tier_fkey
  foreign key (plan_tier) references public.plans (tier);

comment on column public.generation_credits.plan_tier is
  'The plan this project''s allowance was granted from. Written only by grant_plan_allowance. Defaults to free, which is a real row in plans rather than a pair of column defaults pretending to be one.';

alter table public.generation_credits drop column if exists directions_limit;
alter table public.generation_credits drop column if exists regenerations_limit;

comment on column public.generation_credits.directions_generated is
  'Directions produced so far. One run produces plans.directions_limit of them, so this is 0 before the first run and directions_limit after it.';


-- ============================================================================
-- 3. Granting an allowance
-- ============================================================================
-- ⚠ A GRANT IS RECORDED, NOT INFERRED. `plan_grants` exists so a webhook replay
-- cannot double an allowance: the Stripe event id (or the checkout session, or
-- any stable key) is unique, and a second call with the same key does nothing
-- and says so.
--
-- It matters more than usual here because granting RESETS the counters — she
-- bought a fresh allowance. Without a key, a retried webhook would hand her the
-- whole thing again.

create table if not exists public.plan_grants (
  id          uuid        not null default gen_random_uuid(),
  project_id  uuid        not null,
  tier        text        not null,
  grant_key   text        not null,
  granted_at  timestamptz not null default now(),
  constraint plan_grants_pkey primary key (id),
  constraint plan_grants_grant_key_key unique (grant_key),
  constraint plan_grants_project_id_fkey foreign key (project_id)
    references public.projects (id) on delete cascade,
  constraint plan_grants_tier_fkey foreign key (tier) references public.plans (tier),
  constraint plan_grants_grant_key_check check (btrim(grant_key) <> '')
);

comment on table public.plan_grants is
  'Every allowance ever granted to a project, keyed by the Stripe event or checkout session that caused it. Idempotency lives here: a replayed webhook finds its key already present and grants nothing.';

create index if not exists plan_grants_project_id_granted_at_idx
  on public.plan_grants (project_id, granted_at);

alter table public.plan_grants enable row level security;

drop policy if exists plan_grants_select_own on public.plan_grants;
create policy plan_grants_select_own on public.plan_grants for select
  using (exists (select 1 from public.projects p
                  where p.id = plan_grants.project_id
                    and p.user_id = (select auth.uid())));
drop policy if exists plan_grants_insert_denied on public.plan_grants;
create policy plan_grants_insert_denied on public.plan_grants for insert with check (false);
drop policy if exists plan_grants_update_denied on public.plan_grants;
create policy plan_grants_update_denied on public.plan_grants for update using (false);
drop policy if exists plan_grants_delete_denied on public.plan_grants;
create policy plan_grants_delete_denied on public.plan_grants for delete using (false);

revoke insert, update, delete on public.plan_grants from authenticated, anon;
grant select on public.plan_grants to authenticated;

create or replace function public.grant_plan_allowance(
  p_project_id uuid,
  p_tier       text,
  p_grant_key  text default null)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key uuid;
  v_k   text;
begin
  if p_project_id is null or p_tier is null then
    return false;
  end if;
  if not exists (select 1 from public.plans where tier = p_tier) then
    raise exception 'grant_plan_allowance: "%" is not a plan.', p_tier;
  end if;

  -- ⚠ "idempotent on the purchase or the Stripe event id". Given a key, that is
  -- the key. Given none, fall back to the checkout session of the purchase this
  -- grant is for — unique per purchase, so a REPLAY grants nothing while a
  -- genuine re-purchase, which has its own session, grants again.
  v_k := coalesce(nullif(btrim(p_grant_key), ''), (
    select pu.stripe_checkout_session_id
      from public.purchases pu
     where pu.project_id = p_project_id
       and pu.tier = p_tier
     order by pu.created_at desc
     limit 1));
  if v_k is null then
    raise exception
      'grant_plan_allowance: no grant key given and no % purchase on this project to take one from.', p_tier;
  end if;

  insert into public.plan_grants (project_id, tier, grant_key)
  values (p_project_id, p_tier, v_k)
  on conflict (grant_key) do nothing
  returning id into v_key;

  if v_key is null then
    return false;               -- a replay. Nothing granted, nothing reset.
  end if;

  insert into public.generation_credits (project_id) values (p_project_id)
  on conflict (project_id) do nothing;

  update public.generation_credits
     set plan_tier            = p_tier,
         directions_generated = 0,
         regenerations_used   = 0
   where project_id = p_project_id;

  return true;
end
$$;

comment on function public.grant_plan_allowance(uuid, text, text) is
  'Grants a project the allowance of a plan and resets its meter, once per grant key. Returns false on a replay, having changed nothing. service_role only: this is the checkout handler''s to call, never a client''s.';

revoke execute on function public.grant_plan_allowance(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.grant_plan_allowance(uuid, text, text) to service_role;


-- ============================================================================
-- 4. One question, one source
-- ============================================================================
-- ⚠ NO MORE entitled/not BRANCH. The allowance is whatever plan the project was
-- granted, and an ungranted project is on `free` — which is a row, not a
-- default. Entitlement decides whether she may open the deliverable; the plan
-- decides how many runs she may spend. They are different questions and this
-- function only asks the second one.

create or replace function public.consume_generation_credit(p_brand_kit_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_project     uuid;
  v_per_run     smallint;
  v_regen_limit smallint;
  v_consumed    boolean;
begin
  if (select auth.uid()) is null then
    return false;
  end if;

  select bk.project_id into v_project
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
   where bk.id = p_brand_kit_id
     and pr.user_id = (select auth.uid());
  if v_project is null then
    return false;
  end if;

  insert into public.generation_credits (project_id) values (v_project)
  on conflict (project_id) do nothing;

  select pl.directions_limit, pl.regenerations_limit
    into v_per_run, v_regen_limit
    from public.generation_credits gc
    join public.plans pl on pl.tier = gc.plan_tier
   where gc.project_id = v_project;
  if v_per_run is null then
    return false;
  end if;

  -- ⚠ ONE STATEMENT. The UPDATE takes the row lock, and under READ COMMITTED a
  -- concurrent caller that was waiting re-evaluates this WHERE against the row
  -- as the winner left it. Two simultaneous POSTs cannot both pass.
  --
  -- The first run produces `directions_limit` directions; every later run is a
  -- regeneration. So the counter is 0 before the first run and non-zero after,
  -- which is the whole ladder.
  update public.generation_credits gc
     set directions_generated =
           gc.directions_generated
           + case when gc.directions_generated = 0 then v_per_run else 0 end,
         regenerations_used =
           gc.regenerations_used
           + case when gc.directions_generated = 0 then 0 else 1 end
   where gc.project_id = v_project
     and (gc.directions_generated = 0 or gc.regenerations_used < v_regen_limit)
  returning true into v_consumed;

  return coalesce(v_consumed, false);
end
$$;

comment on function public.consume_generation_credit(uuid) is
  'Atomically spends one generation run, or returns false having spent nothing. The allowance comes from the project''s granted plan; there is no entitled/not branch. Calling this is the ONLY correct way to check: reading the counters and deciding is a race two concurrent requests both win.';

revoke execute on function public.consume_generation_credit(uuid) from public, anon;
grant execute on function public.consume_generation_credit(uuid) to authenticated, service_role;


-- ============================================================================
-- 5. Guard rails
-- ============================================================================
do $$
declare r record;
begin
  if (select count(*) from public.plans) <> 4 then
    raise exception 'plans: expected four rows including free.';
  end if;
  if (select price_cents from public.plans where tier = 'free') <> 0 then
    raise exception 'plans: the free row is not free.';
  end if;

  -- ⚠ the free row IS the free cap now. If it ever stops saying "one run of
  -- three, plus one regeneration", that is a product decision and not a drift.
  if (select (directions_limit, regenerations_limit) from public.plans where tier = 'free')
     is distinct from (3::smallint, 1::smallint) then
    raise exception 'plans: the free allowance is no longer one run of three plus one regeneration.';
  end if;

  -- no default may disagree with the table any more, because there is no default
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'generation_credits'
       and column_name in ('directions_limit', 'regenerations_limit')) then
    raise exception 'generation_credits still carries a limit column.';
  end if;

  -- and nobody but the webhook may grant
  if has_function_privilege('authenticated',
       'public.grant_plan_allowance(uuid,text,text)'::regprocedure, 'EXECUTE') then
    raise exception 'grant_plan_allowance is callable by authenticated.';
  end if;

  raise notice ' ';
  raise notice 'plans — the allowance of every tier, and the only place it is written:';
  raise notice '  tier        label       price   directions/run  regenerations  total runs';
  for r in select * from public.plans order by sort_order loop
    raise notice '  %  %  %  %  %  %',
      rpad(r.tier, 11), rpad(r.label, 10),
      lpad('$' || (r.price_cents / 100)::text, 6),
      lpad(r.directions_limit::text, 14),
      lpad(r.regenerations_limit::text, 13),
      lpad((1 + r.regenerations_limit)::text, 10);
  end loop;
  raise notice ' ';
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore consume_generation_credit from 20260829123000 (WITH set jit='off')
--   drop function if exists public.grant_plan_allowance(uuid, text, text);
--   drop table if exists public.plan_grants;
--   alter table public.generation_credits
--     add column directions_limit    smallint not null default 3,
--     add column regenerations_limit smallint not null default 1;
--   alter table public.generation_credits drop constraint generation_credits_plan_tier_fkey;
--   alter table public.generation_credits drop column plan_tier;
--   drop table if exists public.plans;
