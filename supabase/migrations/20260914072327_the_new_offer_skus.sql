-- Les SKU de l'offre du 13 septembre. Fichier complet :
-- supabase/migrations/20260914100000_the_new_offer_skus.sql
alter table public.plans
  add column if not exists kind           text,
  add column if not exists billing_period text,
  add column if not exists per_seat       boolean,
  add column if not exists included_seats integer;

update public.plans
   set kind           = coalesce(kind, 'kit'),
       billing_period = coalesce(billing_period, 'once'),
       per_seat       = coalesce(per_seat, false);

alter table public.plans
  alter column kind           set default 'kit',
  alter column billing_period set default 'once',
  alter column per_seat       set default false;

alter table public.plans
  alter column kind           set not null,
  alter column billing_period set not null,
  alter column per_seat       set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'plans_kind_check') then
    alter table public.plans add constraint plans_kind_check
      check (kind = any (array['kit', 'addon', 'seat', 'subscription']));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_billing_period_check') then
    alter table public.plans add constraint plans_billing_period_check
      check (billing_period = any (array['once', 'month']));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_included_seats_check') then
    alter table public.plans add constraint plans_included_seats_check
      check (included_seats is null or included_seats between 1 and 500);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'plans_seats_only_where_they_mean_something') then
    alter table public.plans add constraint plans_seats_only_where_they_mean_something
      check (included_seats is null or kind = 'kit');
  end if;
end $$;

comment on column public.plans.kind is
  'What the row IS. kit: produces a brand_kits row. addon: an accessory attached to an existing kit. seat: one more clinician on a Roster. subscription: a monthly rent. Read to decide whether a row may be granted as a generation allowance at all - grant_plan_allowance must never be handed a subscription.';
comment on column public.plans.billing_period is
  'once or month. price_cents alone cannot say whether 5900 is a one-time charge or a rent, and every reader that guesses eventually guesses wrong.';
comment on column public.plans.per_seat is
  'true when price_cents multiplies by the number of clinicians. A CATALOGUE PROPERTY, not a calculation: the quantity actually billed lives in subscriptions and is not written here.';
comment on column public.plans.included_seats is
  'Seats included in the price. The Roster: 5. NULL everywhere else, solo tiers included - a solo plan does not have "1 seat included", it has no seats at all.';

alter table public.plans
  alter column directions_limit    drop not null,
  alter column regenerations_limit drop not null;

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'plans_directions_check') then
    alter table public.plans drop constraint plans_directions_check;
  end if;
  alter table public.plans add constraint plans_directions_check
    check (directions_limit is null or directions_limit between 1 and 12);

  if exists (select 1 from pg_constraint where conname = 'plans_regenerations_check') then
    alter table public.plans drop constraint plans_regenerations_check;
  end if;
  alter table public.plans add constraint plans_regenerations_check
    check (regenerations_limit is null or regenerations_limit >= 0);

  alter table public.plans drop constraint if exists plans_allowance_matches_kind;
  alter table public.plans add constraint plans_allowance_matches_kind
    check (
      case when kind = any (array['kit', 'addon'])
           then directions_limit is not null and regenerations_limit is not null
           else directions_limit is null     and regenerations_limit is null
      end
    );
end $$;

do $$
begin
  alter table public.plans drop constraint if exists plans_tier_check;
  alter table public.plans add constraint plans_tier_check
    check (tier = any (array[
      'free', 'starter', 'practice', 'signature',
      'foundation', 'roster', 'identity_addon', 'roster_seat',
      'fill_solo', 'fill_practice'
    ]));

  alter table public.purchases drop constraint if exists purchases_tier_check;
  alter table public.purchases add constraint purchases_tier_check
    check (tier = any (array[
      'starter', 'practice', 'signature',
      'foundation', 'roster', 'identity_addon', 'roster_seat'
    ]));

  alter table public.brand_kits drop constraint if exists brand_kits_tier_check;
  alter table public.brand_kits add constraint brand_kits_tier_check
    check (tier = any (array[
      'starter', 'practice', 'signature',
      'foundation', 'roster'
    ]));
end $$;

create or replace function pg_temp.tier_enum(p_conname text)
returns text[]
language sql
stable
as $fn$
  select coalesce(array_agg(m[1] order by m[1]), array[]::text[])
    from pg_constraint c,
         lateral regexp_matches(pg_get_constraintdef(c.oid),
                                '''([a-z_]+)''::text', 'g') as m
   where c.connamespace = 'public'::regnamespace
     and c.conname = p_conname;
$fn$;

do $$
declare
  v_orphan text;
begin
  select string_agg(t, ', ' order by t) into v_orphan
    from (select unnest(pg_temp.tier_enum('purchases_tier_check')) as t
          except
          select unnest(pg_temp.tier_enum('plans_tier_check'))) missing;
  if v_orphan is not null then
    raise exception
      'purchases.tier accepte des paliers absents de plans.tier (%) — un achat encaissé sans ligne de catalogue lève à grant_plan_allowance, après le paiement',
      v_orphan;
  end if;

  select string_agg(t, ', ' order by t) into v_orphan
    from (select unnest(pg_temp.tier_enum('brand_kits_tier_check')) as t
          except
          select unnest(pg_temp.tier_enum('plans_tier_check'))) missing;
  if v_orphan is not null then
    raise exception 'brand_kits.tier accepte des paliers absents de plans.tier (%)', v_orphan;
  end if;

  if coalesce(array_length(pg_temp.tier_enum('plans_tier_check'), 1), 0) = 0
  or coalesce(array_length(pg_temp.tier_enum('purchases_tier_check'), 1), 0) = 0 then
    raise exception 'la garde des paliers n''a lu aucun littéral : elle ne vérifie plus rien';
  end if;
end $$;

-- >>> OFFER SKU DATA (mirrored verbatim in supabase/seed.sql) >>>
insert into public.plans
  (tier, label, price_cents, kind, billing_period, per_seat, included_seats,
   directions_limit, regenerations_limit, image_budget_cents, sort_order)
values
  ('foundation', 'The Foundation', 39000, 'kit', 'once', false, null,
   3, 6, 400, 10),
  ('roster', 'The Roster', 69000, 'kit', 'once', false, 5,
   3, 12, 600, 11),
  ('identity_addon', 'Visual identity', 8900, 'addon', 'once', false, null,
   3, 3, 200, 12),
  ('roster_seat', 'Additional clinician', 12000, 'seat', 'once', true, null,
   null, null, 0, 13),
  ('fill_solo', 'The Fill', 5900, 'subscription', 'month', false, null,
   null, null, 0, 14),
  ('fill_practice', 'The Fill (practice)', 6900, 'subscription', 'month', true, null,
   null, null, 0, 15)
on conflict (tier) do update set
  label               = excluded.label,
  price_cents         = excluded.price_cents,
  kind                = excluded.kind,
  billing_period      = excluded.billing_period,
  per_seat            = excluded.per_seat,
  included_seats      = excluded.included_seats,
  directions_limit    = excluded.directions_limit,
  regenerations_limit = excluded.regenerations_limit,
  image_budget_cents  = excluded.image_budget_cents,
  sort_order          = excluded.sort_order;
-- <<< OFFER SKU DATA <<<

do $$
declare
  v_count  integer;
  v_broke  boolean;
begin
  select count(*) into v_count from public.plans
   where tier in ('foundation','roster','identity_addon','roster_seat','fill_solo','fill_practice');
  if v_count <> 6 then
    raise exception 'les six SKU de l''offre ne sont pas tous en base : % trouvés', v_count;
  end if;

  if (select price_cents from public.plans where tier = 'foundation')     <> 39000
  or (select price_cents from public.plans where tier = 'roster')         <> 69000
  or (select price_cents from public.plans where tier = 'identity_addon') <>  8900
  or (select price_cents from public.plans where tier = 'roster_seat')    <> 12000
  or (select price_cents from public.plans where tier = 'fill_solo')      <>  5900
  or (select price_cents from public.plans where tier = 'fill_practice')  <>  6900 then
    raise exception 'un prix de l''offre ne correspond pas à la décision du 13 septembre';
  end if;

  if (select included_seats from public.plans where tier = 'roster') <> 5 then
    raise exception 'The Roster ne comprend pas cinq cliniciennes';
  end if;
  if exists (select 1 from public.plans where included_seats is not null and tier <> 'roster') then
    raise exception 'un palier autre que The Roster porte des sièges compris';
  end if;

  if (select array_agg(tier order by tier) from public.plans where per_seat)
     is distinct from array['fill_practice','roster_seat'] then
    raise exception 'la liste des prix par siège n''est pas celle de l''offre';
  end if;

  begin
    update public.plans
       set directions_limit = 3, regenerations_limit = 3
     where tier = 'fill_solo';
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un abonnement a pu recevoir une allocation de génération';
  end if;

  begin
    update public.plans set directions_limit = 3 where tier = 'fill_solo';
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un abonnement a pu recevoir une demi-allocation de génération';
  end if;

  begin
    update public.plans set directions_limit = null where tier = 'foundation';
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'The Foundation a pu perdre son allocation de génération';
  end if;

  begin
    insert into public.plans (tier, label, price_cents, kind, billing_period, per_seat,
                              directions_limit, regenerations_limit, sort_order)
    values ('not_an_offer', 'X', 100, 'kit', 'once', false, 3, 3, 99);
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    delete from public.plans where tier = 'not_an_offer';
    raise exception 'plans.tier accepte un palier qui n''est pas dans l''offre';
  end if;
end $$;
