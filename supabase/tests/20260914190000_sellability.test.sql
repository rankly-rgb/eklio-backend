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

  assert v_blocked = array['fill_practice', 'fill_solo', 'roster_seat'],
    format(
      'Les lignes invendables sont %L. Trois sont attendues : roster_seat '
      '(un siège acheté ne livre rien avant L21), fill_solo et fill_practice '
      '(le cycle mensuel n''existe pas). Si l''une a été rouverte, le lot qui '
      'la rouvre doit venir le dire ICI — c''est le seul endroit où la '
      'décision se lit sans exécuter le produit.',
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

  foreach v_lot in array array['L18', 'L20', 'L21'] loop
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
  -- sur les deux contrôles ci-dessus. The Foundation et The Roster SONT le
  -- produit ; s'ils sont fermés, ce n'est pas une précaution, c'est une panne.
  assert (select bool_and(sellable) from public.plans
           where tier = any (array['foundation', 'roster', 'identity_addon'])),
    'The Foundation, The Roster ou l''add-on identité n''est plus vendable. '
    'Ces trois-là livrent ce qu''ils vendent : les fermer n''est pas une '
    'précaution, c''est une rupture de vente.';

  raise notice 'sellability: ok';
end $$;

rollback;
