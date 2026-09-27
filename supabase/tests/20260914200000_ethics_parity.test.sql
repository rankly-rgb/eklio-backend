-- ============================================================================
-- La parité des deux gardes déontologiques — la moitié SQL
-- ============================================================================
-- Depuis L13, la garde a deux implémentations :
--
--   ici        `public.ethics_patterns`, en POSIX
--   frontend   `FORBIDDEN_PATTERNS` (lib/ethics/rules.ts), en JavaScript
--
-- ⚠ CE FICHIER NE LES FUSIONNE PAS et ne prépare pas la fusion. Elle reste un
-- lot à part entière, consigné dans OUT_OF_SCOPE.md §17. Les motifs restent
-- écrits deux fois, en deux dialectes d'expression régulière — ce qui est
-- partagé est le NOM d'un motif, pas le motif.
--
-- ── CE QUE LE CORPUS PARTAGÉ NE VOIT PAS ────────────────────────────────────
--
-- `20260914170000_the_guard_in_the_write.test.sql` et son jumeau TypeScript
-- tiennent déjà les deux côtés sur le COMPORTEMENT : les mêmes phrases
-- bloquées, les mêmes reformulations laissées passer. Un corpus ne voit que
-- les phrases qu'il contient. Un motif AJOUTÉ d'un seul côté attrape du texte
-- que l'autre laisse passer, et le produit se comporte alors différemment
-- selon le chemin d'écriture : une génération passée par l'application, ou un
-- texte écrit directement par une RPC. Aucun test de phrase ne le remarque
-- tant que personne n'écrit la phrase.
--
-- Ce fichier vérifie donc le RECENSEMENT : même nombre, mêmes noms, même
-- règle derrière chaque nom.
--
-- Son jumeau, qui écrit la MÊME liste en toutes lettres :
--   eklio-frontend/lib/ethics/__tests__/parity.test.ts
--
-- ⚠ LA LISTE CI-DESSOUS EST RECOPIÉE, ET C'EST VOULU. Elle ne peut pas être
-- lue depuis l'autre dépôt, et une liste qui se lit elle-même ne contrôle
-- rien. C'est la forme qu'a prise `entitling_statuses_single_source` au lot 1.
-- Ce n'est PAS une quatrième liste d'autorité : rien ne la lit à l'exécution,
-- seul ce test la compare.
-- ============================================================================

begin;

do $$
declare
  v_here      text[];
  v_expected  text[];
  v_count     int;
  v_rec       record;
begin
  /*
   * ⚠ RECOPIÉ DE `lib/ethics/rules.ts`, LE 14 SEPTEMBRE 2026, PUIS LE 20 : les
   * VINGT
   * entrées de `FORBIDDEN_PATTERNS`, chacune avec son `id` et son `ruleId`.
   */
  create temporary table what_the_frontend_carries (id text, rule_id text)
    on commit drop;
  insert into what_the_frontend_carries values
    ('resolution_verb',       'proven'),
    ('free_you_from',         'proven'),
    ('is_gone',               'proven'),
    ('dated_promise',         'timeframe'),
    ('guarantee',             'proven'),
    ('clinically_proven',     'proven'),
    ('success_rate',          'proven'),
    ('lasting_relief',        'proven'),
    ('therapy_that_works',    'proven'),
    ('testimonial_word',      'client_voice'),
    ('clients_say',           'client_voice'),
    -- Sorti du chemin réel : deux profils sur trois portaient « A colleague
    -- once described me as… ». Un témoignage anonymisé reste un témoignage.
    ('third_party_says',      'client_voice'),
    ('client_reviews',        'client_voice'),
    ('star_rating',           'client_voice'),
    ('success_story',         'client_voice'),
    ('best_therapist',        'scarcity'),
    ('award_winning',         'credential'),
    ('weekend_certification', 'credential'),
    ('you_have_condition',    'diagnosis'),
    ('scarcity_urgency',      'scarcity');

  -- ── Garde anti-vacuité, AVANT toute comparaison ───────────────────────
  --
  -- ⚠ Deux ensembles vides sont égaux. Sans cette ligne, un `delete from
  -- ethics_patterns` doublé d'un bloc recopié vide rendrait ce fichier vert
  -- au moment précis où il n'y a plus de garde du tout.
  select count(*) into v_count from what_the_frontend_carries;
  assert v_count = 20,
    format('Le recensement recopié porte %s entrées au lieu de 20.', v_count);

  -- ── 1. Même nombre ────────────────────────────────────────────────────
  select count(*) into v_count from public.ethics_patterns;
  assert v_count = 20,
    format(
      'ethics_patterns porte %s motifs, FORBIDDEN_PATTERNS en porte 20. Celui '
      'qui en a un de plus attrape du texte que l''autre laisse passer : la '
      'même phrase serait bloquée ou non selon qu''elle est écrite par '
      'l''application ou par une RPC. Un motif ajouté d''un seul côté doit '
      'être ajouté des DEUX, et ce test dit lequel manque.',
      v_count);

  -- ── 2. Mêmes identifiants ─────────────────────────────────────────────
  select array_agg(id order by id) into v_here     from public.ethics_patterns;
  select array_agg(id order by id) into v_expected from what_the_frontend_carries;

  assert v_here = v_expected,
    format(
      'Les identifiants divergent.%s  en base seulement : %L%s  dans le '
      'frontend seulement : %L',
      chr(10),
      (select coalesce(array_agg(id order by id), array[]::text[])
         from public.ethics_patterns
        where id not in (select id from what_the_frontend_carries)),
      chr(10),
      (select coalesce(array_agg(id order by id), array[]::text[])
         from what_the_frontend_carries
        where id not in (select id from public.ethics_patterns)));

  -- ── 3. Même règle derrière chaque nom ─────────────────────────────────
  --
  -- Un identifiant partagé qui pointe vers deux règles différentes serait pire
  -- qu'une divergence de nombre : les deux côtés sembleraient recenser la même
  -- chose, et une même violation serait rapportée sous deux motifs.
  for v_rec in
    select f.id, f.rule_id as expected, e.rule_id as actual
      from what_the_frontend_carries f
      join public.ethics_patterns e using (id)
     where f.rule_id is distinct from e.rule_id
  loop
    -- ⚠ `format()`, PAS `%L` DANS LE `raise`. `raise` ne connaît que `%` :
    -- un `%L` y consomme l'argument et laisse un « L » collé à la valeur. Le
    -- premier jet de ce fichier disait « le motif guaranteeL », et c'est un
    -- sondage qui l'a montré — pas une relecture.
    raise exception '%', format(
      'Le motif %L fait respecter %L en base et %L dans le frontend.',
      v_rec.id, v_rec.actual, v_rec.expected);
  end loop;

  -- ── 4. Ce qui garantit qu'une règle nommée existe ─────────────────────
  --
  -- ⚠ CE CONTRÔLE A ÉTÉ RÉÉCRIT APRÈS L'AVOIR SONDÉ. Le premier jet parcourait
  -- `ethics_patterns` en cherchant un `rule_id` absent de `ethics_rules` — un
  -- refus déclenché sans règle à MONTRER à la praticienne. Le sondage a rendu
  -- « violates foreign key constraint ethics_patterns_rule_fkey » : la
  -- contrainte existe déjà, et cette boucle-là ne pouvait donc jamais lever.
  --
  -- Un contrôle qui ne peut pas échouer occupe la place d'un contrôle. On
  -- vérifie donc ce qui porte réellement la garantie : la clé étrangère.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.ethics_patterns'::regclass
       and contype = 'f'
       and confrelid = 'public.ethics_rules'::regclass
  ) then
    raise exception
      'ethics_patterns n''a plus de clé étrangère vers ethics_rules : un motif '
      'peut désormais nommer une règle qui n''existe pas, et le produit '
      'refuserait un texte sans avoir de règle à montrer.';
  end if;

  raise notice 'ethics parity: 20 motifs, mêmes identifiants, mêmes règles';
end $$;

rollback;
