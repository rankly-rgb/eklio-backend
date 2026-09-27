/*
 * ══════════════════════════════════════════════════════════════════════════
 * ON NE PEUT PAS REPROCHER AU MODÈLE UNE LISTE QU'ON NE LUI A JAMAIS DONNÉE
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Mesuré en production le 19 septembre, cinq générations de profil d'annuaire :
 *
 *   19:17:37  save_directory_profile  400   Directory cliche: you deserve
 *   19:18:57  save_directory_profile  400   Directory cliche: you deserve
 *   19:33:35  save_directory_profile  200   (celle-ci est passée)
 *   19:57:27  save_directory_profile  400   Directory cliche: you deserve
 *   19:57:58  save_directory_profile  400   Directory cliche: you deserve
 *
 * QUATRE FOIS LA MÊME PHRASE, y compris après que la praticienne a changé son
 * type de licence ET son domaine d'expertise. Ce n'est donc pas son brief qui
 * produit le cliché : c'est que le prompt système porte les règles
 * déontologiques et RIEN des trente phrases bannies. On demande au modèle
 * d'écrire un profil Psychology Today sans lui dire ce qui le fera rejeter,
 * puis on rejette.
 *
 * `usp_banned_phrases_check` ne sait que répondre oui/non sur un texte. Écrire
 * un prompt, c'est avoir la LISTE — d'où cette fonction, et rien de plus.
 *
 * ── POURQUOI CECI N'EST PAS L'ORACLE QUE §9.11 INTERDIT ─────────────────
 *
 * Le contrat refuse que `usp_banned_phrases_check` soit `authenticated` :
 * joignable par PostgREST, elle devient un oracle à phrases — on essaie des
 * formulations jusqu'à zéro touche et la garde 1 du pipeline USP tombe avant
 * que la garde 2 ne tourne.
 *
 * Cette fonction-ci porte EXACTEMENT le même verrou, et pour la même raison :
 * `service_role` seule, appelée depuis le handler, jamais avec le JWT de
 * l'appelante. `banned_phrases` reste sans politique et sans privilège pour
 * `anon` et `authenticated` (§9.8), et n'entre PAS dans `readCatalog`.
 *
 * ⚠ ET CE QUI CHANGE VRAIMENT EST DIT PLUTÔT QUE TU : les trente phrases
 * entreront désormais dans un prompt, donc dans un contexte que le modèle voit.
 * Ce n'est pas un secret qui fuit — ce sont des lieux communs d'annuaire, pas
 * des données de personne — et le risque nommé par §9.11 est celui d'une
 * CLIENTE qui itère contre la garde pour faire passer SA formulation. Ici ce
 * n'est pas elle qui écrit : c'est nous. Lui cacher la liste ne protège rien
 * et coûte deux appels modèle par tentative.
 */

create or replace function public.usp_banned_phrases_list()
returns text[]
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(array_agg(bp.phrase order by bp.phrase), array[]::text[])
    from public.banned_phrases bp
   where bp.active
$$;

comment on function public.usp_banned_phrases_list() is
  'The thirty directory cliches, for building a generation prompt. service_role only, exactly like usp_banned_phrases_check: reachable by authenticated it would be the phrase-testing oracle FRONTEND_CONTRACT §9.11 refuses. banned_phrases itself stays unreadable (§9.8).';

revoke all on function public.usp_banned_phrases_list() from public;
revoke all on function public.usp_banned_phrases_list() from anon;
revoke all on function public.usp_banned_phrases_list() from authenticated;
grant execute on function public.usp_banned_phrases_list() to service_role;

/*
 * ── LA GARDE, ET ELLE SE SABOTE ELLE-MÊME ───────────────────────────────
 */
do $$
declare
  v_liste text[];
begin
  -- 1. Elle rend quelque chose, et c'est la table qui le dit.
  v_liste := public.usp_banned_phrases_list();
  if coalesce(array_length(v_liste, 1), 0) <>
     (select count(*) from public.banned_phrases where active) then
    raise exception 'la liste ne compte pas les mêmes lignes que la table : % contre %',
      coalesce(array_length(v_liste, 1), 0),
      (select count(*) from public.banned_phrases where active);
  end if;

  /*
   * 2. ⚠ LA LISTE ET LA VÉRIFICATION DISENT LA MÊME CHOSE. Deux fonctions sur
   * la même table sont deux définitions de « cliché » le jour où l'une filtre
   * `active` et l'autre non. On le prouve sur chaque phrase plutôt que de le
   * supposer : chacune doit se déclencher contre son propre texte.
   */
  if exists (
    select 1 from unnest(v_liste) as phrase
     where coalesce(array_length(public.usp_banned_phrases_check(phrase), 1), 0) = 0
  ) then
    raise exception 'une phrase de la liste n''est pas vue par la vérification';
  end if;

  -- 3. ⚠ Et le verrou tient : joignable par `authenticated`, c'est l'oracle.
  if has_function_privilege('authenticated', 'public.usp_banned_phrases_list()', 'execute')
     or has_function_privilege('anon', 'public.usp_banned_phrases_list()', 'execute') then
    raise exception 'usp_banned_phrases_list est joignable sans service_role — c''est l''oracle de §9.11';
  end if;
  if not has_function_privilege('service_role', 'public.usp_banned_phrases_list()', 'execute') then
    raise exception 'usp_banned_phrases_list n''est pas appelable par service_role';
  end if;

  -- 4. Le cliché qui a produit ce correctif est bien dans la liste.
  if not ('you deserve' = any (v_liste)) then
    raise exception 'la phrase mesurée en production n''est pas dans la liste active';
  end if;
end $$;
