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
  --   · ni État vendable : `license_type_states` porte zéro `verified_at`,
  --     donc la génération qui suit le paiement rend 409.
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
   * ne dit pas ce qu'elle attend devient permanente par oubli. Celle-ci est
   * attachée à sa cause : le jour où un État devient vendable, la moitié
   * mesurable de la raison tombe, ce test vire au rouge, et quelqu'un doit
   * reprendre la décision au lieu de la laisser dormir.
   *
   * L'autre moitié — les deux prix Stripe — ne se lit pas depuis SQL. Elle est
   * écrite en toutes lettres dans l'en-tête de la migration qui ferme.
   */
  if not (select bool_and(sellable) from public.plans
           where tier = any (array['foundation', 'roster'])) then
    assert (select count(*) from public.sellable_states where sellable) = 0,
      format('The Foundation et The Roster sont fermés, mais %s État(s) sont '
             'désormais vendables. La raison de la fermeture a changé : '
             'reprenez la décision (prix Stripe, puis un UPDATE dans une '
             'migration neuve qui revérifie les trois conditions).',
             (select count(*) from public.sellable_states where sellable));
  end if;

  raise notice 'sellability: ok';
end $$;

rollback;
