-- ============================================================================
-- `plans.requires_publishable_platform` — l'éligibilité n'est pas un refus
-- ============================================================================
-- La correction d'une erreur de spec : la qualification de plateforme avait
-- été écrite pour REFUSER à l'inscription. L'ancienne offre n'étant pas
-- retirée de la vente, un refus renvoyait une cliente encore servable.
--
-- Son jumeau, qui tente l'achat :
--   eklio-frontend/lib/stripe/__tests__/platform-eligibility.test.ts
--
-- ⚠ CE FICHIER GARDE UNE CHOSE QUE LA MIGRATION NE PEUT PAS GARDER : que
-- l'ANCIENNE offre reste inconditionnelle. C'est le sens même de la
-- correction, et c'est ce qui se perdrait en premier — il suffirait d'un
-- `update plans set requires_publishable_platform = true` jugé prudent.
-- ============================================================================

begin;

do $$
declare
  v_gated    text[];
  v_accepted text[];
begin
  -- ── 1. Exactement les quatre SKU qui promettent une publication ───────
  select coalesce(array_agg(tier order by tier), array[]::text[])
    into v_gated
    from public.plans where requires_publishable_platform;

  assert v_gated = array['fill_practice', 'fill_solo', 'foundation', 'roster'],
    format(
      'Les SKU conditionnés à la plateforme sont %L. Quatre sont attendus : '
      'ceux qui promettent qu''Eklio PUBLIE. Un de plus refuserait une vente '
      'qu''on sait honorer ; un de moins promettrait une publication sur une '
      'plateforme qu''on n''atteint pas.',
      v_gated);

  -- ── 2. ⚠ L'ancienne offre reste inconditionnelle ──────────────────────
  --
  -- Elle ne promet aucune publication : des fichiers, et un texte à coller.
  -- La conditionner reviendrait à refuser à nouveau des clientes servables,
  -- par la porte même que cette correction a ouverte.
  assert not exists (
    select 1 from public.plans
     where tier = any (array['free', 'starter', 'practice', 'signature', 'identity_addon'])
       and requires_publishable_platform
  ),
    'Une ligne de l''ancienne offre (ou l''add-on identité) est conditionnée à '
    'la plateforme. Aucune ne promet de publication : les conditionner refuse '
    'des clientes qu''on sait servir, ce qui est l''erreur corrigée ici.';

  -- ── 3. La condition doit être satisfaisable ───────────────────────────
  --
  -- ⚠ Conditionner quatre SKU à un ensemble vide, c'est les rendre
  -- invendables à tout le monde — un refus déguisé en éligibilité.
  select coalesce(array_agg(id order by id), array[]::text[])
    into v_accepted
    from public.site_platforms where status = 'accepted';

  assert array_length(v_accepted, 1) >= 1,
    'Aucune plateforme n''est acceptée dans site_platforms : les quatre SKU '
    'conditionnés ne seraient vendables à personne.';

  -- ── 4. Les deux colonnes sont indépendantes ───────────────────────────
  --
  -- `sellable` dit « à personne », `requires_publishable_platform` dit « pas à
  -- elle ». Elles se lisent à la même porte et ne disent pas la même chose :
  -- fill_solo porte les deux, foundation la seconde seulement. Si une colonne
  -- devenait le miroir de l'autre, l'une des deux ne servirait plus à rien.
  --
  -- ⚠ CETTE LIGNE DISAIT « il existe un SKU conditionné ET vendable », et elle
  -- a mordu le 17 septembre quand `a_button_that_breaks_is_not_shown` a fermé
  -- The Foundation et The Roster (ni prix Stripe, ni État vérifié). Elle avait
  -- raison de mordre — quelque chose avait changé — mais pas sur la bonne
  -- question : elle demandait s'il RESTE une ligne aux deux propriétés, alors
  -- que ce qu'elle veut savoir est si les deux colonnes DISENT ENCORE DEUX
  -- CHOSES. Une offre entièrement fermée ne fait pas d'une colonne le miroir
  -- de l'autre.
  --
  -- On compare donc les deux ENSEMBLES. Aujourd'hui : conditionnés =
  -- {foundation, roster, fill_solo, fill_practice} ; fermés = ces quatre plus
  -- roster_seat, qui n'est conditionné à aucune plateforme et est fermé pour
  -- une raison à lui. Les deux diffèrent, donc les deux colonnes servent.
  assert (select array_agg(tier order by tier) from public.plans where requires_publishable_platform)
      is distinct from
         (select array_agg(tier order by tier) from public.plans where not sellable),
    format('« conditionné à une plateforme » et « invendable » désignent '
           'exactement les mêmes lignes (%s) : une des deux colonnes ne sert '
           'plus à rien.',
           (select string_agg(tier, ', ' order by tier) from public.plans
             where requires_publishable_platform));

  -- Et aucune des deux n'est vide : deux ensembles vides sont « distincts » de
  -- rien du tout, et passeraient la ligne ci-dessus sans rien vérifier.
  assert (select count(*) from public.plans where requires_publishable_platform) > 0
     and (select count(*) from public.plans where not sellable) > 0,
    'une des deux colonnes ne marque plus aucune ligne : la comparaison '
    'ci-dessus ne vérifie plus rien.';

  raise notice 'eligibility: 4 SKU conditionnés, ancienne offre libre, % plateforme(s) acceptée(s)',
    array_length(v_accepted, 1);
end $$;

rollback;
