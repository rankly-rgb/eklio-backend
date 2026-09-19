/*
 * ══════════════════════════════════════════════════════════════════════════
 * usp_banned_phrases_list — LA LISTE QUI SERT À ÉCRIRE LE PROMPT
 * ══════════════════════════════════════════════════════════════════════════
 *
 * La garde de sa migration prouve l'état au moment de l'application. Ce
 * fichier-ci le reprouve à CHAQUE vérification, parce que ce qui est en jeu
 * n'est pas une valeur mais une AUTORISATION : une migration ultérieure qui
 * accorderait `authenticated` par mégarde rendrait joignable, par PostgREST et
 * sans handler, l'oracle à phrases que FRONTEND_CONTRACT §9.11 refuse — on
 * essaie des formulations jusqu'à zéro touche et la garde 1 du pipeline USP
 * tombe avant que la garde 2 ne tourne.
 */
do $$
declare
  v_liste text[];
begin
  v_liste := public.usp_banned_phrases_list();

  /* ⚠ LE VERROU, ET C'EST LA RAISON D'ÊTRE DE CE FICHIER. */
  assert not has_function_privilege('authenticated', 'public.usp_banned_phrases_list()', 'execute'),
    'usp_banned_phrases_list est joignable par authenticated — c''est l''oracle à phrases de §9.11';
  assert not has_function_privilege('anon', 'public.usp_banned_phrases_list()', 'execute'),
    'usp_banned_phrases_list est joignable par anon';
  assert has_function_privilege('service_role', 'public.usp_banned_phrases_list()', 'execute'),
    'usp_banned_phrases_list n''est plus appelable par service_role — la génération ne peut plus écrire son prompt';

  /* ⚠ ET LA TABLE ELLE-MÊME RESTE ILLISIBLE (§9.8) : la fonction est le seul chemin. */
  assert not has_table_privilege('authenticated', 'public.banned_phrases', 'select'),
    'banned_phrases est redevenue lisible par authenticated';
  assert not has_table_privilege('anon', 'public.banned_phrases', 'select'),
    'banned_phrases est redevenue lisible par anon';

  /*
   * ⚠ UNE SEULE DÉFINITION DE « CLICHÉ ». Deux fonctions sur la même table
   * divergent le jour où l'une filtre `active` et l'autre non — et la
   * divergence irait dans le pire sens : le modèle ignorerait une phrase que
   * la base refuserait. On l'éprouve sur chaque ligne plutôt que de le croire.
   */
  assert coalesce(array_length(v_liste, 1), 0) =
         (select count(*) from public.banned_phrases where active),
    'la liste et la table ne comptent pas les mêmes lignes';
  assert not exists (
    select 1 from unnest(v_liste) as phrase
     where coalesce(array_length(public.usp_banned_phrases_check(phrase), 1), 0) = 0
  ), 'une phrase rendue par la liste n''est pas vue par la vérification';

  /*
   * ⚠ ET LA LISTE EST ORDONNÉE. Un prompt qui change d'ordre à chaque appel
   * casse la mise en cache du contexte sans rien apporter.
   */
  assert v_liste = (select array_agg(p order by p) from unnest(v_liste) as p),
    'la liste n''est plus ordonnée';

  /* Le cliché mesuré en production le 19 septembre, quatre fois de suite. */
  assert 'you deserve' = any (v_liste),
    'la phrase qui a produit ce correctif n''est plus dans la liste active';
end $$;
