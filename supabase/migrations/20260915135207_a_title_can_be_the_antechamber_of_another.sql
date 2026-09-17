-- ============================================================================
-- Un titre peut être l'antichambre d'un autre
-- ============================================================================
-- AMFT, ASW, APCC (CA), LPC Associate, LMFT Associate (TX), limited permits
-- (NY), registered interns (FL), LAPC, LAMFT (PA) : des titres délivrés par le
-- board, portés par des gens qui exercent SOUS SUPERVISION et qui ne peuvent
-- pas se dire « licensed ». C'est une grande partie de la cible.
--
-- ── POURQUOI DES LIGNES DISTINCTES, ET PAS UN STATUT ────────────────────
--
-- Un statut sur `lmft` aurait paru économe. Il aurait été un DÉFAUT PERMISSIF,
-- et c'est la seule des trois raisons qui compte :
--
--   avec un statut, une AMFT porterait quand même `license_type_id = 'lmft'`,
--   donc `allowedClaimsFrom` mettrait « Licensed Marriage and Family
--   Therapist » dans `licenseNames`, et `checkUnbackedClaims` AUTORISERAIT le
--   mot « licensed ». Il faudrait s'en souvenir à chaque appelant.
--
--   avec une ligne propre (`amft` / « Associate Marriage and Family
--   Therapist »), la garde refuse « licensed » SANS QU'ON LA PRÉVIENNE : ce
--   mot n'est pas dans le brief, point final.
--
-- Une garde qui marche sans qu'on la prévienne vaut mieux qu'une règle à
-- retenir. C'est la leçon de la semaine, appliquée avant le défaut.
--
-- Les deux autres raisons tiennent aussi, plus modestement : le board délivre
-- un titre au nom PROPRE (pas une LMFT diminuée), et `license_type_states`
-- porte DÉJÀ « quel État délivre quoi » — AMFT existe en Californie, pas au
-- Texas. Un statut aurait demandé la matrice une seconde fois.
--
-- ── CE QUE CETTE MIGRATION POSE, ET CE QU'ELLE NE POSE PAS ──────────────
--
-- Elle pose la STRUCTURE : la colonne, ses contraintes, et l'invariant de
-- matrice. Elle ne pose AUCUNE ligne de titre pré-licence : le relevé des cinq
-- États arrive, avec pour chacun le titre plein correspondant et l'obligation
-- de nommer le superviseur. Inventer « AMFT existe en Californie » de mémoire
-- serait refaire exactement l'erreur que toute cette série répare.
--
-- Les règles `claims.ts` (« licensed », « private practice », le titre plein)
-- attendent une décision produit distincte et ne sont pas ici non plus.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. La colonne
-- ---------------------------------------------------------------------------
alter table public.license_types
  add column if not exists supervised_track_of text;

alter table public.license_types drop constraint if exists license_types_supervised_track_fkey;
alter table public.license_types
  add constraint license_types_supervised_track_fkey
  foreign key (supervised_track_of) references public.license_types (id) on delete restrict;

/*
 * ⚠ PAS D'AUTORÉFÉRENCE, ET PAS DE CHAÎNE. Un titre n'est pas sa propre
 * antichambre, et « l'antichambre d'une antichambre » n'existe pas : le board
 * délivre le titre associé, puis le titre plein, en deux temps et pas en
 * trois. Sans ces deux règles, une boucle ou une chaîne rendrait « quel est le
 * titre plein ? » indécidable — et la garde déontologique a besoin d'une
 * réponse, pas d'un parcours.
 */
alter table public.license_types drop constraint if exists license_types_supervised_track_self_check;
alter table public.license_types
  add constraint license_types_supervised_track_self_check check (
    supervised_track_of is null or supervised_track_of <> id
  );

create or replace function public.license_types_track_depth_gate()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.supervised_track_of is not null
     and exists (
       select 1 from public.license_types lt
        where lt.id = new.supervised_track_of
          and lt.supervised_track_of is not null
     ) then
    raise exception
      'supervised_track: % pointe vers %, qui est déjà une antichambre. Un titre associé mène à un titre PLEIN, jamais à un autre titre associé.',
      new.id, new.supervised_track_of
      using errcode = '23514';
  end if;
  return new;
end
$function$;

revoke execute on function public.license_types_track_depth_gate()
  from public, anon, authenticated;

drop trigger if exists license_types_track_depth_gate on public.license_types;
create trigger license_types_track_depth_gate
  before insert or update of supervised_track_of on public.license_types
  for each row execute function public.license_types_track_depth_gate();

comment on column public.license_types.supervised_track_of is
  'The FULLY LICENSED title this one is the antechamber of, or NULL when the title stands on its own. AMFT -> LMFT, ASW -> LCSW, LPC Associate -> LPC. Its holder practises under supervision and cannot call herself "licensed" -- which the ethics guard refuses on its own, because the word is simply not in her brief. Never chains: a track points at a full title, never at another track.';


-- ---------------------------------------------------------------------------
-- 2. L'invariant de matrice
-- ---------------------------------------------------------------------------
/*
 * ⚠ UNE ANTICHAMBRE SANS SA PORTE N'EXISTE PAS. `(amft, CA)` n'a de sens que
 * si `(lmft, CA)` existe : la Californie ne délivre pas un titre associé vers
 * un titre plein qu'elle ne délivre pas. Sans cette garde, une ligne saisie
 * de travers proposerait à l'écran 1 un titre qui ne mène nulle part.
 *
 * Posé comme trigger, pas comme CHECK : un CHECK ne lit pas une autre ligne.
 */
create or replace function public.license_type_states_track_gate()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare v_full text;
begin
  select lt.supervised_track_of into v_full
    from public.license_types lt where lt.id = new.license_type_id;

  if v_full is not null
     and not exists (
       select 1 from public.license_type_states s
        where s.license_type_id = v_full
          and s.state_code = new.state_code
     ) then
    raise exception
      'supervised_track: % est l''antichambre de %, que % ne délivre pas. Une antichambre sans sa porte ne mène nulle part.',
      new.license_type_id, v_full, new.state_code
      using errcode = '23514';
  end if;
  return new;
end
$function$;

revoke execute on function public.license_type_states_track_gate()
  from public, anon, authenticated;

drop trigger if exists license_type_states_track_gate on public.license_type_states;
create trigger license_type_states_track_gate
  before insert or update of license_type_id, state_code on public.license_type_states
  for each row execute function public.license_type_states_track_gate();

/*
 * ⚠ ET LA PORTE NE SE RETIRE PAS EN LAISSANT L'ANTICHAMBRE. Supprimer
 * `(lmft, CA)` alors que `(amft, CA)` existe laisserait exactement l'état que
 * le trigger ci-dessus refuse à l'écriture — un invariant qui ne tient que
 * dans un sens n'est pas un invariant.
 */
create or replace function public.license_type_states_track_delete_gate()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if exists (
    select 1
      from public.license_types lt
      join public.license_type_states s
        on s.license_type_id = lt.id and s.state_code = old.state_code
     where lt.supervised_track_of = old.license_type_id
  ) then
    raise exception
      'supervised_track: % en % est la porte d''une antichambre encore ouverte. Retirer l''antichambre d''abord.',
      old.license_type_id, old.state_code
      using errcode = '23514';
  end if;
  return old;
end
$function$;

revoke execute on function public.license_type_states_track_delete_gate()
  from public, anon, authenticated;

drop trigger if exists license_type_states_track_delete_gate on public.license_type_states;
create trigger license_type_states_track_delete_gate
  before delete on public.license_type_states
  for each row execute function public.license_type_states_track_delete_gate();


-- ---------------------------------------------------------------------------
-- 3. Garde-fous — les deux sens, sur une ligne jetable
-- ---------------------------------------------------------------------------
do $$
declare v_refused boolean;
begin
  -- Aucun titre n'est encore une antichambre : le relevé n'est pas arrivé.
  if exists (select 1 from public.license_types where supervised_track_of is not null) then
    raise exception
      'supervised_track: des antichambres existent déjà alors que le relevé n''est pas arrivé. Migration abandonnée.';
  end if;

  -- Une antichambre s'écrit…
  insert into public.license_types (id, label, description, sort_order, active, supervised_track_of)
  values ('__probe_amft', 'PROBE', 'Probe Associate Therapist', 999, false, 'lmft');

  -- …et elle ne peut pas être sa propre antichambre.
  v_refused := false;
  begin
    update public.license_types set supervised_track_of = '__probe_amft'
     where id = '__probe_amft';
  exception when check_violation then v_refused := true;
  end;
  if not v_refused then
    raise exception 'supervised_track: un titre est sa propre antichambre. Migration abandonnée.';
  end if;

  -- …ni l'antichambre d'une antichambre.
  v_refused := false;
  begin
    insert into public.license_types (id, label, description, sort_order, active, supervised_track_of)
    values ('__probe_chain', 'PROBE2', 'Probe Chain', 998, false, '__probe_amft');
  exception when others then v_refused := true;
  end;
  if not v_refused then
    raise exception 'supervised_track: une chaîne de deux antichambres a été acceptée. Migration abandonnée.';
  end if;

  -- ⚠ L'INVARIANT DE MATRICE, DANS LES DEUX SENS.
  -- L'Oregon délivre un LMFT : l'antichambre y est donc recevable.
  insert into public.license_type_states (license_type_id, state_code)
  values ('__probe_amft', 'OR');

  -- La Californie aussi. Mais un État qui ne délivrerait pas LMFT, non — on
  -- en fabrique le cas en retirant la porte d'abord.
  v_refused := false;
  begin
    delete from public.license_type_states
     where license_type_id = 'lmft' and state_code = 'OR';
  exception when others then v_refused := true;
  end;
  if not v_refused then
    raise exception
      'supervised_track: la porte a été retirée en laissant l''antichambre. Migration abandonnée.';
  end if;

  -- Et l'antichambre est refusée là où la porte n'existe pas.
  delete from public.license_type_states
   where license_type_id = '__probe_amft' and state_code = 'OR';

  v_refused := false;
  begin
    insert into public.license_type_states (license_type_id, state_code)
    values ('__probe_amft', 'ZZ');
  exception when others then v_refused := true;
  end;
  if not v_refused then
    raise exception
      'supervised_track: une antichambre a été posée dans un État sans sa porte. Migration abandonnée.';
  end if;

  -- La sonde ne laisse rien.
  delete from public.license_type_states where license_type_id like '__probe%';
  delete from public.license_types       where id like '__probe%';

  if exists (select 1 from public.license_types where id like '__probe%') then
    raise exception 'supervised_track: la sonde a laissé des lignes. Migration abandonnée.';
  end if;

  -- Et le couple du rapport reste refusé.
  if public.license_state_allowed('lmhc', 'OR') then
    raise exception 'supervised_track: lmhc + OR est redevenu acceptable. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop trigger if exists license_type_states_track_delete_gate on public.license_type_states;
--   drop trigger if exists license_type_states_track_gate on public.license_type_states;
--   drop trigger if exists license_types_track_depth_gate on public.license_types;
--   drop function if exists public.license_type_states_track_delete_gate();
--   drop function if exists public.license_type_states_track_gate();
--   drop function if exists public.license_types_track_depth_gate();
--   alter table public.license_types drop column if exists supervised_track_of;
