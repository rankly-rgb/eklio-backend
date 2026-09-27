-- ============================================================================
-- `plans.sellable` — la consigne remplacée par une colonne
-- ============================================================================
-- `DECISIONS_NEEDED.md` §4 se terminait par : « Rien dans le code ne l'empêche
-- aujourd'hui — c'est une décision de mise en vente, pas une garde technique. »
-- Ce fichier est la moitié SQL de la garde technique qui l'a remplacée.
--
-- Son jumeau, celui qui TENTE l'achat :
--   eklio-frontend/lib/stripe/__tests__/unsellable.test.ts
--
-- ⚠ CE QU'ON VÉRIFIE ICI N'EST PAS « la colonne existe ». La migration se
-- vérifie déjà elle-même sur ce point. Ce fichier garde trois choses qu'une
-- migration ne peut pas garder, parce qu'elles portent sur l'AVENIR :
--
--   1. l'ensemble bloqué est EXACTEMENT ces trois-là, nommées ici aussi, donc
--      en rouvrir une oblige à venir le dire dans un test plutôt qu'à le
--      glisser dans un `update` ;
--   2. le commentaire de colonne nomme les lots propriétaires, donc il ne peut
--      pas pourrir en « TODO » ;
--   3. les deux produits de tête restent en vente, donc un `update plans set
--      sellable = false` en masse ne passe pas pour une précaution.
-- ============================================================================

begin;

do $$
declare
  v_blocked  text[];
  v_comment  text;
  v_lot      text;
  v_n        int;
begin
  -- ── 1. Exactement ces trois-là ────────────────────────────────────────
  select coalesce(array_agg(tier order by tier), array[]::text[])
    into v_blocked
    from public.plans where not sellable;

  assert v_blocked = array['fill_practice', 'fill_solo', 'foundation',
                           'roster', 'roster_seat'],
    format(
      'Les lignes invendables sont %L. Cinq sont attendues : roster_seat '
      '(un siège acheté ne livre rien avant L21), fill_solo et fill_practice '
      '(le cycle mensuel n''existe pas), foundation et roster (ni prix Stripe '
      'configuré, ni État vérifié — voir a_button_that_breaks_is_not_shown). '
      'Si l''une a été rouverte OU fermée, le lot qui le fait doit venir le '
      'dire ICI — c''est le seul endroit où la décision se lit sans exécuter '
      'le produit.',
      v_blocked);

  -- ── 2. Le commentaire nomme les lots, et ne peut pas pourrir ──────────
  --
  -- ⚠ `col_description` rend NULL s'il n'y a pas de commentaire, et un NULL
  -- comparé à quoi que ce soit rend NULL — donc `assert v_comment like '%L21%'`
  -- SEUL passerait sur une colonne sans commentaire. Deuxième des quatre
  -- défauts permissifs du README, et il fallait l'écrire avant de s'y appuyer.
  select col_description('public.plans'::regclass, a.attnum)
    into v_comment
    from pg_attribute a
   where a.attrelid = 'public.plans'::regclass and a.attname = 'sellable';

  assert v_comment is not null and btrim(v_comment) <> '',
    'plans.sellable n''a pas de commentaire. La colonne dit QUE la vente est '
    'refusée ; le commentaire est le seul endroit qui dit QUI la rouvre.';

  /*
   * ⚠ ET LES DEUX NOUVELLES FERMETURES ONT AUSSI UN PROPRIÉTAIRE. Le contrôle
   * ci-dessus a été étendu à cinq lignes le 17 septembre ; sans cette
   * extension-ci, `foundation` et `roster` seraient les deux seules lignes
   * fermées dont le commentaire de la colonne ne dit pas qui les rouvre — ce
   * que le message juste au-dessus appelle un TODO.
   */
  foreach v_lot in array array['L18', 'L20', 'L21', 'foundation', 'roster'] loop
    assert v_comment like '%' || v_lot || '%',
      format(
        'Le commentaire de plans.sellable ne nomme pas %s. Les trois lots '
        'propriétaires sont L21 (roster_seat), L18 (fill_solo) et L18+L20 '
        '(fill_practice) : un commentaire qui n''en nomme aucun est un TODO, '
        'et un TODO ne rouvre rien. Commentaire actuel : %L',
        v_lot, v_comment);
  end loop;

  -- ── 3. L'offre de tête reste en vente ─────────────────────────────────
  --
  -- ⚠ GARDE ANTI-ZÈLE. Une colonne qui refuse des ventes est une colonne
  -- qu'on peut mettre à `false` partout « en attendant », et ce serait vert
  -- sur les deux contrôles ci-dessus.
  --
  -- ⚠ ET ELLE A MORDU LE 17 SEPTEMBRE, SUR MOI. Cette ligne exigeait que
  -- `foundation` et `roster` soient vendables, en disant « les fermer n'est pas
  -- une précaution, c'est une rupture de vente ». C'était vrai sous sa
  -- prémisse : qu'ils soient livrables. Ils ne le sont pas —
  --
  --   · ni prix Stripe : `lib/billing/plans.ts` les déclare sous
  --     STRIPE_PRICE_FOUNDATION et STRIPE_PRICE_ROSTER, absentes de
  --     l'environnement. La session de checkout échoue APRÈS le clic.
  --   · ni État vendable : `license_type_states` portait zéro `verified_at`,
  --     donc la génération qui suit le paiement rendait 409.
  --
  -- ⚠ LA SECONDE RAISON EST TOMBÉE LE 17 SEPTEMBRE — la Californie est
  -- vérifiée, cinq couples, LEP compris. La fermeture tient désormais sur la
  -- PREMIÈRE seule, plus « les textes ne sont pas jugés ». C'est exactement ce
  -- que `sellability_decisions` enregistre, et pourquoi l'alarme ci-dessous ne
  -- compare plus à un zéro : la cause a bougé une fois, elle rebougera.
  --
  -- Encaisser puis refuser est pire que ne pas vendre. Le lot qui les ferme
  -- est `a_button_that_breaks_is_not_shown`, et il vient le dire ICI, comme le
  -- message du contrôle 1 l'exige de quiconque touche à cette colonne.
  --
  -- ⚠ LA GARDE ANTI-ZÈLE NE DISPARAÎT PAS, ELLE CHANGE D'ANCRE.
  --
  -- `identity_addon` livre des fichiers : il n'a ni prix manquant ni promesse
  -- de publication, donc rien ne justifie de le fermer, et le fermer resterait
  -- du zèle. Il reste exigé vendable.
  assert (select sellable from public.plans where tier = 'identity_addon'),
    'L''add-on identité n''est plus vendable. Il livre des fichiers, son prix '
    'Stripe existe et il ne promet aucune publication : le fermer est du zèle, '
    'pas une précaution.';

  /*
   * ⚠ ET LA FERMETURE S'EXPIRE TOUTE SEULE. Une fermeture « en attendant » qui
   * ne dit pas ce qu'elle attend devient permanente par oubli.
   *
   * ⚠ LA PREMIÈRE VERSION DE CETTE ALARME A MORDU — PUIS EST RESTÉE ROUGE.
   * Elle exigeait « si foundation et roster sont fermés, alors zéro État
   * vendable ». La Californie s'est ouverte le 17 septembre, l'alarme a sonné,
   * la décision a été reprise : ils RESTENT fermés, parce que les prix Stripe
   * LIVE manquent et que les textes n'ont pas été jugés. Mais le zéro, lui,
   * était figé : l'alarme ne pouvait plus repasser au vert sans qu'on supprime
   * sa condition. Une alarme qui reste rouge n'est plus une alarme — on
   * apprend à l'ignorer, et le jour où elle dit autre chose, personne ne
   * regarde.
   *
   * Elle compare donc désormais le monde à la PHOTO prise au moment de la
   * décision (`sellability_decisions`), et non plus à une constante. Verte
   * tant que rien n'a bougé, rouge au prochain CHANGEMENT DE CAUSE. Elle se
   * réarme toute seule, ce que le zéro ne savait pas faire.
   */
  assert (select count(*) from public.sellability_decisions
           where tier = any (array['foundation', 'roster'])) = 2,
    'foundation et roster sont fermés sans décision enregistrée. Une fermeture '
    'sans propriétaire ni date est un « en attendant » que l''oubli rend '
    'permanent : voir public.sellability_decisions.';

  -- La décision dit la même chose que la colonne.
  for v_lot, v_n in
    select d.tier, 1 from public.sellability_decisions d
      join public.plans p on p.tier = d.tier
     where p.sellable is distinct from d.sellable
  loop
    assert false, format(
      'plans.sellable pour %s contredit la décision enregistrée. Quelqu''un a '
      'basculé la colonne sans repasser par sellability_decisions — ou '
      'l''inverse.', v_lot);
  end loop;

  /*
   * ⚠ LE CŒUR : LA CAUSE A-T-ELLE CHANGÉ DEPUIS LA DÉCISION ? Deux causes se
   * lisent en SQL. Les deux autres — un prix Stripe LIVE, quelqu'un qui a lu
   * les textes — n'existent dans aucune table, et `conditions_to_revisit` les
   * porte en toutes lettres plutôt que de faire semblant de les mesurer.
   */
  for v_lot, v_n in
    select d.tier, 1 from public.sellability_decisions d
     where d.states_sellable
             is distinct from (select count(*) from public.sellable_states where sellable)
        or d.accepted_platforms
             is distinct from (select count(*) from public.site_platforms
                                where status = 'accepted')
  loop
    assert false, format(
      'La cause de la décision sur %s a changé : elle a été prise avec %s '
      'État(s) ouvert(s) et %s plateforme(s) acceptée(s) ; il y en a %s et %s '
      'aujourd''hui. Reprenez la décision, puis mettez sa ligne à jour dans une '
      'migration neuve — ne corrigez pas la photo toute seule, c''est ce qui '
      'ferait taire l''alarme.',
      v_lot,
      (select states_sellable from public.sellability_decisions where tier = v_lot),
      (select accepted_platforms from public.sellability_decisions where tier = v_lot),
      (select count(*) from public.sellable_states where sellable),
      (select count(*) from public.site_platforms where status = 'accepted'));
  end loop;

  /*
   * ⚠ ET LES FERMETURES QUI N'ONT PAS ENCORE DE DÉCISION SONT DÉCLARÉES, PAS
   * DÉDUITES. Trois lignes restent fermées sans ligne dans la table : leurs
   * raisons vivent dans le commentaire de `plans.sellable` (contrôle 2
   * ci-dessus), pas encore sous forme de décision datée. Une QUATRIÈME
   * fermeture sans décision fait échouer ce test — ce qui est le seul moment
   * où quelqu'un se demandera qui la rouvre.
   */
  assert (
    select coalesce(array_agg(p.tier order by p.tier), array[]::text[])
      from public.plans p
     where not p.sellable
       and not exists (select 1 from public.sellability_decisions d where d.tier = p.tier)
  ) = array['fill_practice', 'fill_solo', 'roster_seat'],
    format('La liste des fermetures sans décision enregistrée a changé : %s. '
           'Une fermeture neuve doit venir avec sa décision, sa date et la '
           'photo de ses causes.',
           (select array_agg(p.tier order by p.tier) from public.plans p
             where not p.sellable
               and not exists (select 1 from public.sellability_decisions d
                                where d.tier = p.tier)));

  raise notice 'sellability: ok';
end $$;

rollback;
