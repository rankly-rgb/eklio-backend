-- Un achat qui n'est pas un palier. Fichier complet :
-- supabase/migrations/20260914110000_a_purchase_that_is_not_a_tier.sql
alter table public.purchases add column if not exists kind text;
update public.purchases set kind = coalesce(kind, 'tier');
alter table public.purchases
  alter column kind set default 'tier',
  alter column kind set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'purchases_kind_check') then
    alter table public.purchases add constraint purchases_kind_check
      check (kind = any (array['tier', 'addon', 'seat']));
  end if;
end $$;

comment on column public.purchases.kind is
  'What this purchase BUYS. tier: a kit tier, and it climbs the ladder that highestTier reads. addon: an accessory to a kit that already exists - it climbs nothing. seat: one more clinician on a Roster - it climbs nothing either. Kept in step with plans.kind by the purchases_kind_matches_plan trigger, which reads that table rather than repeating its contents here.';

create or replace function public.purchases_kind_matches_plan()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_plan_kind text;
  v_expected  text;
begin
  select p.kind into v_plan_kind from public.plans p where p.tier = new.tier;

  if v_plan_kind is null then
    raise exception
      'purchases.tier = % n''a pas de ligne dans plans : rien ne sait ce que cet achat vend',
      new.tier using errcode = 'foreign_key_violation';
  end if;

  v_expected := case v_plan_kind
                  when 'kit'          then 'tier'
                  when 'addon'        then 'addon'
                  when 'seat'         then 'seat'
                  when 'subscription' then null
                end;

  if v_expected is null then
    raise exception
      'purchases ne peut pas porter % : c''est un abonnement, il vit dans subscriptions et se renouvelle',
      new.tier using errcode = 'check_violation';
  end if;

  if new.kind is distinct from v_expected then
    raise exception
      'purchases.kind = % pour %, alors que plans dit que c''est un %',
      new.kind, new.tier, v_expected using errcode = 'check_violation';
  end if;

  return new;
end
$$;

comment on function public.purchases_kind_matches_plan() is
  'Keeps purchases.kind in step with plans.kind by READING plans rather than repeating it. A CHECK cannot query another table, and a fourth hand-copied list of tiers is exactly the shape of drift this schema has already paid for.';

revoke all on function public.purchases_kind_matches_plan() from public, anon, authenticated;

drop trigger if exists purchases_kind_matches_plan on public.purchases;
create trigger purchases_kind_matches_plan
  before insert or update of tier, kind on public.purchases
  for each row execute function public.purchases_kind_matches_plan();

create index if not exists purchases_project_kind_idx
  on public.purchases (project_id, kind)
  where project_id is not null;

do $$
declare
  v_user  uuid := gen_random_uuid();
  v_org   uuid;
  v_proj  uuid := gen_random_uuid();
  v_broke boolean;
begin
  if exists (select 1 from public.purchases where kind is distinct from 'tier') then
    raise exception 'une ligne de purchases antérieure à ce lot n''est pas un palier';
  end if;

  insert into auth.users (id, email) values (v_user, 'kindcheck@example.invalid');

  select m.organization_id into v_org
    from public.organization_members m
   where m.user_id = v_user and m.role = 'owner';
  if v_org is null then
    raise exception 'handle_new_user n''a pas doté la sonde d''une organisation';
  end if;

  insert into public.projects (id, user_id, organization_id, name)
  values (v_proj, v_user, v_org, 'Kind check');

  begin
    insert into public.purchases
      (user_id, project_id, tier, kind, stripe_checkout_session_id, amount_cents, status)
    values (v_user, v_proj, 'identity_addon', 'tier', 'cs_probe_addon_as_tier', 8900, 'pending');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then raise exception 'un add-on a pu s''écrire comme un palier'; end if;

  begin
    insert into public.purchases
      (user_id, project_id, tier, kind, stripe_checkout_session_id, amount_cents, status)
    values (v_user, v_proj, 'foundation', 'addon', 'cs_probe_tier_as_addon', 39000, 'pending');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then raise exception 'un palier a pu s''écrire comme un add-on'; end if;

  begin
    insert into public.purchases
      (user_id, project_id, tier, kind, stripe_checkout_session_id, amount_cents, status)
    values (v_user, v_proj, 'fill_solo', 'tier', 'cs_probe_subscription', 5900, 'pending');
    v_broke := true;
  exception when others then v_broke := false; end;
  if v_broke then raise exception 'un abonnement mensuel a pu s''écrire dans purchases'; end if;

  insert into public.purchases
    (user_id, project_id, tier, kind, stripe_checkout_session_id, amount_cents, status)
  values
    (v_user, v_proj, 'foundation',     'tier',  'cs_probe_ok_tier',  39000, 'pending'),
    (v_user, v_proj, 'identity_addon', 'addon', 'cs_probe_ok_addon',  8900, 'pending'),
    (v_user, v_proj, 'roster_seat',    'seat',  'cs_probe_ok_seat',  12000, 'pending');

  if (select count(*) from public.purchases where project_id = v_proj) <> 3 then
    raise exception 'les trois formes d''achat n''ont pas toutes été acceptées';
  end if;

  begin
    insert into public.purchases
      (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status)
    values (v_user, v_proj, 'identity_addon', 'cs_probe_default_kind', 8900, 'pending');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un add-on écrit sans kind a pris "tier" par défaut sans être refusé';
  end if;

  delete from public.purchases where project_id = v_proj;
  delete from public.projects where id = v_proj;
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;
end $$;
