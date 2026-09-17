-- ============================================================================
-- Un achat qui n'est pas un palier
-- ============================================================================
-- `purchases` a toujours décrit une seule forme d'achat : on monte d'un
-- palier. `highestTier` en découle — le droit courant est le PLUS GÉNÉREUX des
-- achats payés, parce qu'un upgrade ajoute une ligne sans en remplacer aucune.
--
-- L'offre du 13 septembre en ajoute deux formes qui ne montent aucun palier :
--
--   addon   l'identité visuelle à 89 $, accessoire d'un kit existant
--   seat    une clinicienne de plus sur un Roster, à 120 $
--
-- ⚠ SANS DISTINCTION, `highestTier` LES RANGERAIT SUR L'ÉCHELLE. Et l'échelle
-- est `KIT_TIERS`, dont l'ordre décide aussi ce qu'une cliente peut ouvrir
-- (`lib/billing/surface-access.ts`). Un accessoire à 89 $ déciderait alors
-- l'accès à des surfaces vendues 249 $. Le sens de l'erreur compte : elle
-- OUVRE.
--
-- ── CE QUE CETTE MIGRATION NE FAIT PAS ──────────────────────────────────────
--
-- Elle ne facture rien et ne déclenche rien. Un `seat` acheté ici ne produit
-- aucun pack et n'incrémente aucune quantité d'abonnement : ce déclenchement
-- appartient au lot de l'embauche, et l'écrire à moitié maintenant donnerait
-- une clinicienne facturée sans livrable, ou l'inverse.
-- ============================================================================

alter table public.purchases
  add column if not exists kind text;

-- ⚠ AVANT LE NOT NULL. Tout ce qui existe est un palier : quatre lignes au
-- moment où ceci est écrit, toutes `starter`/`practice`/`signature`.
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

-- ── La cohérence avec le catalogue, LUE et non recopiée ─────────────────────
--
-- ⚠ POURQUOI UN TRIGGER ET PAS UN CHECK. Un CHECK ne peut pas interroger une
-- autre table, donc dire « `identity_addon` est un `addon` » dans un CHECK
-- voudrait dire réécrire la colonne `plans.kind` sous forme de liste, ici.
-- Ce serait une QUATRIÈME liste à tenir en phase avec les trois autres, et ce
-- dépôt vient de payer ce qu'une liste recopiée qui dérive coûte
-- (`resolveEntitledTier` filtrant 'paid' pendant que la base disait autre
-- chose). Le trigger LIT `plans`, qui fait autorité, et ne peut donc pas
-- diverger d'elle.
--
-- La correspondance n'est pas l'identité : `plans.kind` a quatre valeurs et
-- `purchases.kind` en a trois. `subscription` n'a pas d'équivalent ici, et
-- c'est voulu — un loyer mensuel n'est pas un achat, il vit dans
-- `subscriptions`.

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
  select p.kind into v_plan_kind
    from public.plans p
   where p.tier = new.tier;

  if v_plan_kind is null then
    -- ⚠ ON REFUSE, ON NE LAISSE PAS PASSER. Un palier encaissé sans ligne de
    -- catalogue ferait lever `grant_plan_allowance` APRÈS le paiement, et le
    -- CHECK de `purchases.tier` ne suffit pas : il autorise une valeur, il ne
    -- garantit pas qu'on sache ce qu'elle vaut.
    raise exception
      'purchases.tier = % n''a pas de ligne dans plans : rien ne sait ce que cet achat vend',
      new.tier
      using errcode = 'foreign_key_violation';
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
      new.tier
      using errcode = 'check_violation';
  end if;

  if new.kind is distinct from v_expected then
    raise exception
      'purchases.kind = % pour %, alors que plans dit que c''est un %',
      new.kind, new.tier, v_expected
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

comment on function public.purchases_kind_matches_plan() is
  'Keeps purchases.kind in step with plans.kind by READING plans rather than repeating it. A CHECK cannot query another table, and a fourth hand-copied list of tiers is exactly the shape of drift this schema has already paid for.';

-- ⚠ RÉVOQUÉE, ET L'ÉNUMÉRATION L'A EXIGÉ AVANT MOI. Toute fonction naît avec
-- EXECUTE accordé à PUBLIC — le quatrième défaut permissif du README — donc
-- celle-ci est arrivée dans la surface OpenAPI anonyme sans que rien ne le
-- demande. `20260911170458_function_surface.test.sql` a rougi à la première
-- exécution : « Trigger functions reachable from the browser ». Une fonction
-- de trigger est appelée par la base, jamais par un client.
revoke all on function public.purchases_kind_matches_plan() from public, anon, authenticated;

drop trigger if exists purchases_kind_matches_plan on public.purchases;
create trigger purchases_kind_matches_plan
  before insert or update of tier, kind on public.purchases
  for each row execute function public.purchases_kind_matches_plan();

-- ── L'index qui sert la question qu'on pose vraiment ────────────────────────
-- « A-t-elle acheté l'add-on sur CE projet » et « quel palier a-t-elle payé »
-- sont deux lectures par (project_id, kind), et elles sont sur le chemin de
-- chaque écran payant.
create index if not exists purchases_project_kind_idx
  on public.purchases (project_id, kind)
  where project_id is not null;

-- ── Auto-contrôle ──────────────────────────────────────────────────────────
--
-- ⚠ IL N'INSÈRE PAS « la première ligne existante ». Tout ce qu'il probe est
-- fabriqué sur place, donc il vérifie autant sur une base vide qu'en
-- production — le garde-fou de `20260910144421` ne le faisait pas, et n'avait
-- par conséquent jamais rien vérifié en CI.

do $$
declare
  v_user  uuid := gen_random_uuid();
  v_org   uuid := gen_random_uuid();
  v_proj  uuid := gen_random_uuid();
  v_broke boolean;
begin
  -- Les lignes déjà là sont toutes des paliers.
  if exists (select 1 from public.purchases where kind is distinct from 'tier') then
    raise exception 'une ligne de purchases antérieure à ce lot n''est pas un palier';
  end if;

  -- ⚠ L'ORGANISATION EST CRÉÉE PAR `handle_new_user`, PAS ICI. La poser à la
  -- main violait `organization_members_one_owned_org_per_user` : le trigger
  -- sur `auth.users` en avait déjà fait une. Trouvé en exécutant, pas en
  -- relisant — et c'est la raison pour laquelle cette sonde écrit vraiment au
  -- lieu d'inspecter des définitions.
  insert into auth.users (id, email) values (v_user, 'kindcheck@example.invalid');

  select m.organization_id into v_org
    from public.organization_members m
   where m.user_id = v_user and m.role = 'owner';
  if v_org is null then
    raise exception 'handle_new_user n''a pas doté la sonde d''une organisation';
  end if;

  insert into public.projects (id, user_id, organization_id, name)
  values (v_proj, v_user, v_org, 'Kind check');

  -- Un add-on déclaré comme palier est refusé : c'est le cas qui, sans garde,
  -- ouvrirait des surfaces à 89 $.
  begin
    insert into public.purchases
      (user_id, project_id, tier, kind, stripe_checkout_session_id, amount_cents, status)
    values (v_user, v_proj, 'identity_addon', 'tier', 'cs_probe_addon_as_tier', 8900, 'pending');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un add-on a pu s''écrire comme un palier';
  end if;

  -- Un palier déclaré comme add-on l'est aussi : la garde va dans les deux sens.
  begin
    insert into public.purchases
      (user_id, project_id, tier, kind, stripe_checkout_session_id, amount_cents, status)
    values (v_user, v_proj, 'foundation', 'addon', 'cs_probe_tier_as_addon', 39000, 'pending');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un palier a pu s''écrire comme un add-on';
  end if;

  -- Un abonnement ne s'encaisse pas. Il est déjà hors du CHECK de `tier` ;
  -- on vérifie que le refus arrive bien, quel que soit celui des deux qui le
  -- produit.
  begin
    insert into public.purchases
      (user_id, project_id, tier, kind, stripe_checkout_session_id, amount_cents, status)
    values (v_user, v_proj, 'fill_solo', 'tier', 'cs_probe_subscription', 5900, 'pending');
    v_broke := true;
  exception when others then v_broke := false; end;
  if v_broke then
    raise exception 'un abonnement mensuel a pu s''écrire dans purchases';
  end if;

  -- Et ce qui est juste passe, sans quoi la garde ne prouverait qu'un refus
  -- universel. Trois lignes, une par forme.
  insert into public.purchases
    (user_id, project_id, tier, kind, stripe_checkout_session_id, amount_cents, status)
  values
    (v_user, v_proj, 'foundation',     'tier',  'cs_probe_ok_tier',  39000, 'pending'),
    (v_user, v_proj, 'identity_addon', 'addon', 'cs_probe_ok_addon',  8900, 'pending'),
    (v_user, v_proj, 'roster_seat',    'seat',  'cs_probe_ok_seat',  12000, 'pending');

  if (select count(*) from public.purchases where project_id = v_proj) <> 3 then
    raise exception 'les trois formes d''achat n''ont pas toutes été acceptées';
  end if;

  -- ⚠ LE DÉFAUT PAR DÉFAUT. Une ligne écrite sans nommer `kind` prend 'tier' :
  -- c'est ce qui garde le webhook existant fonctionnel, et c'est aussi ce qui
  -- ferait passer un add-on pour un palier si le trigger n'était pas là. Le
  -- trigger l'attrape — vérifié ici plutôt que supposé.
  begin
    insert into public.purchases
      (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status)
    values (v_user, v_proj, 'identity_addon', 'cs_probe_default_kind', 8900, 'pending');
    v_broke := true;
  exception when check_violation then v_broke := false; end;
  if v_broke then
    raise exception 'un add-on écrit sans kind a pris "tier" par défaut sans être refusé';
  end if;

  -- Rien ne reste : ces lignes ne sont pas de l'argent, ce sont des sondes.
  delete from public.purchases where project_id = v_proj;
  delete from public.projects where id = v_proj;
  -- La suppression de l'utilisatrice emporte son appartenance (FK ON DELETE
  -- CASCADE vers `profiles`) ; l'organisation que le trigger a créée pour elle
  -- part ensuite, une fois qu'elle n'a plus de membre ni de projet.
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;
end $$;
