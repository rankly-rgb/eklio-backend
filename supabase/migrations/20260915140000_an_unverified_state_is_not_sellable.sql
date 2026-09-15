-- ============================================================================
-- Un État dont les couples ne sont pas vérifiés n'est pas vendable
-- ============================================================================
-- `20260915114500` a posé `license_type_states` et le trigger qui refuse un
-- titre que l'État ne délivre pas. Elle a aussi écrit, en toutes lettres, que
-- SES 290 LIGNES NE SONT VÉRIFIÉES PAR PERSONNE : `verified_at` est NULL
-- partout, et la matrice est la meilleure connaissance disponible, pas une
-- source.
--
-- ⚠ CETTE PHRASE-LÀ ÉTAIT UN AVERTISSEMENT SANS CONSÉQUENCE, et c'est
-- exactement la forme que ce dépôt ne garde pas. Un commentaire qui dit « à
-- vérifier avant la mise en vente » ne vérifie rien et n'empêche rien : le
-- jour où quelqu'un vend, il ne relit pas le commentaire. La seule différence
-- entre une réserve et une garantie est une garde qui refuse.
--
-- Donc : la matrice est le SEUL objet dont dépend la légalité du titre
-- imprimé, et un État dont les couples ne sont pas vérifiés n'est pas
-- vendable.
--
-- ── CE QUI EST OUVERT, ET CE QUI NE L'EST PAS ───────────────────────────
--
--   LE BRIEF SE REMPLIT. Elle choisit son État, son titre, ses spécialités,
--   elle va jusqu'au bout des sept écrans. Rien ne la bloque et rien ne lui
--   ment : le couple titre/État est déjà validé par la migration précédente,
--   donc ce qu'elle saisit est cohérent.
--
--   LA PRODUCTION PAYANTE REFUSE, avec une phrase qui dit que cet État n'est
--   pas encore ouvert. Pas une panne, pas un 500, pas un écran de paiement
--   qui n'aiderait pas — payer ne rendrait pas la matrice vérifiée.
--
-- ⚠ POURQUOI LA FRONTIÈRE EST LÀ ET PAS PLUS TÔT. La bloquer à l'écran 1
-- coûterait tout le brief à quelqu'un dont l'État s'ouvrira peut-être la
-- semaine suivante, et nous priverait de savoir QUELS États sont demandés. La
-- bloquer plus tard — après la génération — voudrait dire qu'on a imprimé le
-- titre avant de savoir s'il était légal, ce qui est le défaut d'origine.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Le prédicat
-- ---------------------------------------------------------------------------
/*
 * ⚠ TROIS RÉPONSES POSSIBLES, ET AUCUNE N'EST NULL.
 *
 *   État vide    → VRAI. Aucune juridiction n'est revendiquée, donc il n'y a
 *                  aucun couple à vérifier. La prose ne nommera pas d'État,
 *                  et « je suis LPC » sans État n'affirme rien de faux.
 *                  ⚠ C'est une DÉCISION, pas un oubli : si un jour le produit
 *                  imprime un État déduit de la ville, cette ligne devient
 *                  fausse et doit tomber avec.
 *
 *   État inconnu → FAUX. Pas une seule ligne dans la matrice : on ne sait
 *                  rien de cette juridiction, ce qui est le contraire de
 *                  « tout y est permis ».
 *
 *   État connu   → VRAI seulement si TOUTES ses lignes portent `verified_at`.
 *                  Pas « la ligne du titre choisi » : une matrice à moitié
 *                  relue laisse le mauvais titre proposé à l'écran 1, et
 *                  c'est l'écran qui propose qui décide de ce qu'elle
 *                  choisit.
 */
create or replace function public.state_is_sellable(p_state text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $function$
  select case
    when nullif(btrim(coalesce(p_state, '')), '') is null then true
    else exists (
           select 1 from public.license_type_states s
            where s.state_code = upper(btrim(p_state))
         )
         and not exists (
           select 1 from public.license_type_states s
            where s.state_code = upper(btrim(p_state))
              and s.verified_at is null
         )
  end
$function$;

revoke execute on function public.state_is_sellable(text) from public;
grant execute on function public.state_is_sellable(text)
  to anon, authenticated, service_role;

comment on function public.state_is_sellable(text) is
  'False until every license_type_states row for this state carries verified_at. The brief fills in regardless; paid production refuses, because the matrix is the only object the printed title''s legality rests on. A blank state is sellable: no jurisdiction is claimed.';

/*
 * La même question posée à un PROJET, pour que l'appelant n'ait pas à savoir
 * où vit l'État d'un brief. Un projet sans brief n'est pas vendable : il n'y a
 * rien à produire, et rendre vrai serait répondre oui à une question qu'on n'a
 * pas pu lire.
 */
create or replace function public.project_state_is_sellable(p_project_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $function$
  select coalesce(
    (select public.state_is_sellable(b.state)
       from public.project_briefs b
      where b.project_id = p_project_id),
    false
  )
$function$;

revoke execute on function public.project_state_is_sellable(uuid) from public;
grant execute on function public.project_state_is_sellable(uuid)
  to anon, authenticated, service_role;

comment on function public.project_state_is_sellable(uuid) is
  'state_is_sellable for the state on this project''s brief. False when there is no brief: nothing to produce, and answering yes to a question we could not read is how the LMHC-in-Oregon line shipped.';


-- ---------------------------------------------------------------------------
-- 2. La liste des États ouverts, lisible par l'écran
-- ---------------------------------------------------------------------------
/*
 * Une vue plutôt qu'une requête recopiée dans le front : « ouvert » a une
 * définition, et elle vit là où vivent les lignes qu'elle compte. Recopier le
 * `not exists` dans TypeScript serait une copie à côté de la source — la
 * famille de défauts de la semaine.
 */
create or replace view public.sellable_states as
  select s.state_code,
         count(*) as pairs,
         count(*) filter (where s.verified_at is not null) as verified_pairs,
         bool_and(s.verified_at is not null) as sellable
    from public.license_type_states s
   group by s.state_code;

comment on view public.sellable_states is
  'One row per jurisdiction: how many title pairs it has, how many are verified, and whether it is open for sale. Read by the app so the definition of "open" lives beside the rows it counts, not recopied in TypeScript.';

grant select on public.sellable_states to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 3. Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  -- ⚠ AUJOURD'HUI, AUCUN ÉTAT N'EST VENDABLE, et c'est le fait à établir :
  -- zéro ligne vérifiée, donc zéro juridiction ouverte.
  select count(*) into v_n from public.sellable_states where sellable;
  if v_n <> 0 then
    raise exception
      'state_sellable: % État(s) sont déclarés vendables alors qu''aucune ligne n''est vérifiée. Migration abandonnée.', v_n;
  end if;

  if public.state_is_sellable('OR') then
    raise exception 'state_sellable: OR est vendable sans vérification. Migration abandonnée.';
  end if;

  -- Un État inconnu n'est pas ouvert non plus : ne rien savoir n'est pas
  -- « tout est permis ».
  if public.state_is_sellable('ZZ') then
    raise exception 'state_sellable: un État inconnu est vendable. Migration abandonnée.';
  end if;

  -- Un État vide ne revendique aucune juridiction.
  if not public.state_is_sellable(null) then
    raise exception 'state_sellable: un brief sans État est déclaré invendable. Migration abandonnée.';
  end if;
  if not public.state_is_sellable('  ') then
    raise exception 'state_sellable: un État blanc est traité comme un État. Migration abandonnée.';
  end if;

  -- ⚠ ET LA GARDE MORD DANS L'AUTRE SENS. Sans cette preuve, une fonction qui
  -- rendrait toujours faux passerait tout ce qui précède. On vérifie une
  -- juridiction pour de faux, on regarde, on annule.
  create temp table _probe on commit drop as
    select * from public.license_type_states where state_code = 'WY';

  update public.license_type_states
     set verified_at = now(), verified_by = 'migration probe'
   where state_code = 'WY';

  if not public.state_is_sellable('WY') then
    raise exception 'state_sellable: un État entièrement vérifié reste invendable. Migration abandonnée.';
  end if;

  select count(*) into v_n from public.sellable_states where sellable;
  if v_n <> 1 then
    raise exception 'state_sellable: la vue compte % États ouverts, attendu 1. Migration abandonnée.', v_n;
  end if;

  -- Une seule ligne non vérifiée referme l'État : « presque vérifié » n'ouvre
  -- rien.
  update public.license_type_states
     set verified_at = null, verified_by = null
   where state_code = 'WY'
     and license_type_id = (
       select min(license_type_id) from public.license_type_states where state_code = 'WY'
     );

  if public.state_is_sellable('WY') then
    raise exception 'state_sellable: un État à qui il manque UNE ligne reste vendable. Migration abandonnée.';
  end if;

  -- On remet la matrice telle qu'elle était : la sonde ne vérifie rien.
  update public.license_type_states
     set verified_at = null, verified_by = null
   where state_code = 'WY';

  select count(*) into v_n
    from public.license_type_states where verified_at is not null;
  if v_n <> 0 then
    raise exception
      'state_sellable: la sonde a laissé % ligne(s) marquées vérifiées. Migration abandonnée.', v_n;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop view if exists public.sellable_states;
--   drop function if exists public.project_state_is_sellable(uuid);
--   drop function if exists public.state_is_sellable(text);
