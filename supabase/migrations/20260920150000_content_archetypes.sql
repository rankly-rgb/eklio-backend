-- ============================================================================
-- Eklio — les onze archétypes, comme catalogue et non comme CHECK élargi
-- ============================================================================
-- ⚠ POURQUOI PAS `alter constraint content_items_archetype_check`.
--
-- `content_items.archetype` porte cinq valeurs (statement, question, notes,
-- signature, story) et c'est un axe de MISE EN PAGE. `content_items.register`
-- porte six valeurs et c'est un axe de SÛRETÉ ÉDITORIALE. L'en-tête de
-- `20260910083735` raconte pourquoi les deux ont été rendus DISJOINTS par
-- construction, avec un garde-fou qui fait échouer la migration s'ils se
-- recouvrent : « deux vocabulaires qui ne s'accordent que parce que les deux
-- sont actuellement permissifs » avaient déjà produit un défaut avec
-- `min_tier`.
--
-- Les onze du chantier Content ne sont pas un sur-ensemble des cinq : c'est un
-- autre découpage, plus fin, qui porte en plus la FORME DU CONTENU (combien
-- d'items, quelles clefs) et pas seulement la disposition. Élargir le CHECK de
-- cinq à onze referait exactement ce que ce garde-fou refuse, sur l'autre axe.
--
-- Un catalogue, donc, comme `content_registers` — et pour la même raison
-- qu'elle : les onze sont nécessaires à DEUX endroits (le validateur de
-- `content_topics.payload` et le moteur de rendu), et deux listes codées en
-- dur de onze chaînes sont la dérive que ce dépôt a déjà payée une fois.
--
-- ── `carousel` N'EST PAS UNE MISE EN PAGE, ET IL EST QUAND MÊME ICI ──────
--
-- C'est un NOMBRE DE CARTES : un carrousel de quatre cartes est quatre mises
-- en page à la suite. Il est dans le catalogue parce que la résolution de
-- dépassement (PHASE 3.2) y bascule — « réduire l'illustration → réduire les
-- mots → basculer en carrousel » — donc le pipeline doit pouvoir le nommer.
-- Il porte `is_multi_card` pour que rien ne le traite comme une carte simple,
-- et son payload est validé en récursant sur les archétypes de ses cartes.
-- ============================================================================


-- ============================================================================
-- 1. content_words — compter des mots, une seule fois
-- ============================================================================
-- Les budgets du chantier sont en MOTS, pas en caractères : « label de 1 à 3
-- mots », « gloss de 6 mots au plus ». Écrire ce compte à la main dans chaque
-- branche du validateur, c'est onze occasions de le faire différemment.
--
-- ⚠ NULL-SAFE PAR CONSTRUCTION. `array_length` sur un tableau vide rend NULL,
-- pas 0 — et un NULL rendu ici remonterait dans un CHECK qui accepterait
-- silencieusement. Le `coalesce` est le point de ce wrapper autant que le
-- découpage l'est.

create or replace function public.content_words(p text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    array_length(
      regexp_split_to_array(btrim(coalesce(p, '')), '\s+'),
      1
    ),
    0
  ) - case when btrim(coalesce(p, '')) = '' then 1 else 0 end
$$;

comment on function public.content_words(text) is
  'How many words in p. 0 for NULL and for an empty string -- array_length returns NULL on an empty array, and a NULL carried up into a CHECK would have made it accept. Immutable, so usable inside a constraint.';

revoke all on function public.content_words(text) from public;
grant execute on function public.content_words(text) to authenticated, service_role;


-- ============================================================================
-- 2. content_archetypes — les onze, avec ce que le moteur doit savoir
-- ============================================================================
create table if not exists public.content_archetypes (
  id              text     primary key,
  label           text     not null,
  -- La bande dans laquelle le dessin vit. `none` pour un archétype qui n'a
  -- aucune illustration (une déclaration nue), et c'est une valeur, pas une
  -- absence : « pas de dessin » est une décision de composition.
  illustration_zone text   not null,
  -- Combien d'éléments le payload porte. Bornes INCLUSIVES. Un archétype à
  -- élément unique porte 1..1 plutôt qu'un NULL : le validateur lit toujours
  -- deux nombres, jamais deux nombres ou rien.
  items_min       smallint not null,
  items_max       smallint not null,
  is_multi_card   boolean  not null default false,
  sort_order      smallint not null,
  active          boolean  not null default true,

  constraint content_archetypes_label_check check (char_length(label) between 1 and 48),
  constraint content_archetypes_zone_check
    check (illustration_zone in ('none', 'content', 'content_center')),
  constraint content_archetypes_items_check check (items_min >= 0 and items_max >= items_min)
);

comment on table public.content_archetypes is
  'The eleven composition archetypes, as data. SEPARATE from content_items.archetype (five layouts) and content_registers (six editorial shapes): three vocabularies describing three axes, and conflating them is the defect 20260910083735 already defused once between the first two.';
comment on column public.content_archetypes.illustration_zone is
  'Where the drawing lives. `none` = no illustration at all, a decision rather than an absence. `content_center` = an object drawn inside a shape whose labels sit outside it -- the ONLY exception to "a band carries text OR drawing, never both".';
comment on column public.content_archetypes.is_multi_card is
  'True for carousel only. A carousel is not a layout, it is a card count; this flag exists so that nothing treats it as a single card.';

insert into public.content_archetypes
  (id, label, illustration_zone, items_min, items_max, is_multi_card, sort_order) values
  ('single_statement',    'A single statement',      'none',           1, 1, false,  1),
  ('quadrant_model',      'A quadrant model',        'content',        4, 4, false,  2),
  ('cycle',               'A cycle',                 'content',        3, 6, false,  3),
  ('surface_and_beneath', 'Surface and beneath',     'content',        2, 2, false,  4),
  ('comparison_pair',     'A comparison',            'content',        2, 2, false,  5),
  ('numbered_strategies', 'Numbered strategies',     'content',        3, 5, false,  6),
  ('lettered_technique',  'A lettered technique',    'content',        3, 5, false,  7),
  ('concentric_control',  'Concentric control',      'content_center', 2, 4, false,  8),
  ('annotated_curve',     'An annotated curve',      'content',        2, 4, false,  9),
  ('practitioner_card',   'A practitioner card',     'none',           2, 4, false, 10),
  ('carousel',            'A carousel',              'none',           3, 8, true,  11)
on conflict (id) do update
  set label             = excluded.label,
      illustration_zone = excluded.illustration_zone,
      items_min         = excluded.items_min,
      items_max         = excluded.items_max,
      is_multi_card     = excluded.is_multi_card,
      sort_order        = excluded.sort_order;

alter table public.content_archetypes enable row level security;

drop policy if exists "content_archetypes_select_all"    on public.content_archetypes;
drop policy if exists "content_archetypes_insert_denied" on public.content_archetypes;
drop policy if exists "content_archetypes_update_denied" on public.content_archetypes;
drop policy if exists "content_archetypes_delete_denied" on public.content_archetypes;

create policy "content_archetypes_select_all" on public.content_archetypes
  for select to authenticated using (true);
create policy "content_archetypes_insert_denied" on public.content_archetypes
  for insert with check (false);
create policy "content_archetypes_update_denied" on public.content_archetypes
  for update using (false);
create policy "content_archetypes_delete_denied" on public.content_archetypes
  for delete using (false);


-- ============================================================================
-- 3. Les briques du payload — un item, une paire
-- ============================================================================
-- ⚠ CHAQUE VALIDATEUR REND true OU false, JAMAIS NULL. C'est la règle du
-- registre de `20260830061119`, et elle vaut ici plus qu'ailleurs : un CHECK
-- ne rejette que sur FALSE, donc un validateur qui rend NULL sur un payload
-- vide ACCEPTE ce payload. Le garde-fou de fin de fichier rejoue chacun sur
-- `null`, `'{}'`, `'[]'`, `'"x"'` et `42` et exige false.

/**
 * Un item de diagramme : { label (1..3 mots), gloss (≤ 6 mots) }.
 *
 * Les bornes ne sont pas décoratives. Un label de quatre mots ne tient pas
 * dans un quadrant à 1080px sans descendre sous le plancher de 30px que la
 * PHASE 3.2 refuse de franchir ; le refuser ICI est ce qui fait que le moteur
 * n'a jamais à choisir entre une collision et un texte illisible.
 */
create or replace function public.content_item_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is not null
     and jsonb_typeof(p) = 'object'
     and p ?& array['label', 'gloss']
     and jsonb_typeof(p -> 'label') = 'string'
     and jsonb_typeof(p -> 'gloss') = 'string'
     and public.content_words(p ->> 'label') between 1 and 3
     and public.content_words(p ->> 'gloss') between 1 and 6
$$;

comment on function public.content_item_valid(jsonb) is
  'One diagram item: a label of 1 to 3 words, a gloss of at most 6. The bounds are the typographic budget of the composition engine, stated upstream -- refusing here is what spares the engine ever having to choose between a collision and text below the legibility floor. Never NULL.';

/**
 * Un tableau de n items, borné par les deux bornes de l'archétype.
 *
 * ⚠ `jsonb_array_length` SUR AUTRE CHOSE QU'UN TABLEAU LÈVE. L'ordre des
 * conjonctions n'est donc pas libre : le type se teste avant la longueur, et
 * SQL ne garantit pas l'évaluation paresseuse d'un `and` — d'où le `case`.
 */
create or replace function public.content_items_valid(p jsonb, p_min integer, p_max integer)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p is null then false
    when jsonb_typeof(p) <> 'array' then false
    when jsonb_array_length(p) < p_min then false
    when jsonb_array_length(p) > p_max then false
    else not exists (
      select 1 from jsonb_array_elements(p) e(value)
       where not public.content_item_valid(e.value)
    )
  end
$$;

comment on function public.content_items_valid(jsonb, integer, integer) is
  'An array of content_item_valid, p_min to p_max inclusive. The `case` is not style: jsonb_array_length raises on a non-array, and SQL makes no promise to evaluate an `and` lazily.';

revoke all on function public.content_item_valid(jsonb) from public;
revoke all on function public.content_items_valid(jsonb, integer, integer) from public;
grant execute on function public.content_item_valid(jsonb) to authenticated, service_role;
grant execute on function public.content_items_valid(jsonb, integer, integer) to authenticated, service_role;


-- ============================================================================
-- 4. content_topic_payload_valid — le dispatch, par archétype
-- ============================================================================
-- Un seul point d'entrée, onze branches. C'est lui que le CHECK de
-- `content_topics` appelle, et c'est lui que le pipeline de rédaction appelle
-- avant d'écrire : une sortie de modèle non conforme est rejetée, jamais
-- dégradée en silence.
--
-- ⚠ LE CARROUSEL RÉCURSE, ET IL NE PEUT PAS S'IMBRIQUER. Ses cartes sont des
-- archétypes à part entière, donc la validation d'une carte est cette même
-- fonction — mais `carousel` est exclu des archétypes de carte. Sans cette
-- exclusion la récursion n'aurait pas de fond, et `carousel` n'a de toute
-- façon aucun sens comme carte d'un carrousel.

create or replace function public.content_topic_payload_valid(p_archetype text, p jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case
    when p_archetype is null or p is null then false
    when jsonb_typeof(p) <> 'object' then false

    -- Une déclaration nue. Le budget de 24 mots est celui qui tient en display
    -- 64-110px sur 1080 de large sans passer en carrousel.
    when p_archetype = 'single_statement' then
      p ? 'statement'
      and jsonb_typeof(p -> 'statement') = 'string'
      and public.content_words(p ->> 'statement') between 3 and 24

    -- Exactement quatre, et les deux axes nommés. Un quadrant à trois cases
    -- n'est pas un quadrant ; à cinq, il n'y a plus de quadrant du tout.
    when p_archetype = 'quadrant_model' then
      p ?& array['axis_x', 'axis_y', 'items']
      and jsonb_typeof(p -> 'axis_x') = 'string'
      and jsonb_typeof(p -> 'axis_y') = 'string'
      and public.content_words(p ->> 'axis_x') between 1 and 3
      and public.content_words(p ->> 'axis_y') between 1 and 3
      and public.content_items_valid(p -> 'items', 4, 4)

    -- Trois nœuds au moins : à deux, c'est un aller-retour, pas un cycle.
    when p_archetype = 'cycle' then
      p ? 'nodes' and public.content_items_valid(p -> 'nodes', 3, 6)

    when p_archetype = 'surface_and_beneath' then
      p ?& array['surface', 'beneath']
      and public.content_item_valid(p -> 'surface')
      and public.content_item_valid(p -> 'beneath')

    -- Deux colonnes, chacune avec son en-tête et ses lignes. Les deux colonnes
    -- portent le MÊME nombre de lignes : une comparaison dont un côté a une
    -- ligne de plus se lit comme un déséquilibre plutôt que comme un contraste.
    when p_archetype = 'comparison_pair' then
      p ?& array['left', 'right']
      and public.content_items_valid(p -> 'left', 2, 4)
      and public.content_items_valid(p -> 'right', 2, 4)
      and jsonb_array_length(p -> 'left') = jsonb_array_length(p -> 'right')

    when p_archetype = 'numbered_strategies' then
      p ? 'items' and public.content_items_valid(p -> 'items', 3, 5)

    -- L'acronyme et ses lettres doivent s'accorder, ET DANS L'ORDRE. Un
    -- « RAIN » dont les items commencent par R, I, A, N est un gabarit qui
    -- ment, et personne ne le verra avant la publication.
    when p_archetype = 'lettered_technique' then
      p ?& array['acronym', 'items']
      and jsonb_typeof(p -> 'acronym') = 'string'
      and char_length(p ->> 'acronym') between 3 and 5
      and public.content_items_valid(p -> 'items', 3, 5)
      and jsonb_array_length(p -> 'items') = char_length(p ->> 'acronym')
      and not exists (
        select 1
          from jsonb_array_elements(p -> 'items') with ordinality as e(value, n)
         where upper(left(e.value ->> 'label', 1))
               <> upper(substr(p ->> 'acronym', e.n::integer, 1))
      )

    -- Du plus extérieur au plus intérieur. L'ordre du tableau EST le dessin.
    when p_archetype = 'concentric_control' then
      p ? 'rings' and public.content_items_valid(p -> 'rings', 2, 4)

    when p_archetype = 'annotated_curve' then
      p ?& array['axis_x', 'axis_y', 'points']
      and jsonb_typeof(p -> 'axis_x') = 'string'
      and jsonb_typeof(p -> 'axis_y') = 'string'
      and public.content_words(p ->> 'axis_x') between 1 and 3
      and public.content_words(p ->> 'axis_y') between 1 and 3
      and public.content_items_valid(p -> 'points', 2, 4)

    -- ⚠ AUCUN TITRE DE PRATIQUE ICI. La carte porte des LIGNES libres et pas
    -- un `credential` : quel titre une praticienne peut imprimer est décidé
    -- par `license_type_states`, État par État, et une seconde source dans un
    -- payload de sujet serait la façon exacte dont « psychologist » finit sur
    -- la carte de quelqu'un qui n'a pas le droit de l'écrire.
    when p_archetype = 'practitioner_card' then
      p ? 'lines'
      and jsonb_typeof(p -> 'lines') = 'array'
      and jsonb_array_length(p -> 'lines') between 2 and 4
      and not exists (
        select 1 from jsonb_array_elements(p -> 'lines') e(value)
         where jsonb_typeof(e.value) <> 'string'
            or public.content_words(e.value #>> '{}') not between 1 and 8
      )

    when p_archetype = 'carousel' then
      p ? 'cards'
      and jsonb_typeof(p -> 'cards') = 'array'
      and jsonb_array_length(p -> 'cards') between 3 and 8
      and not exists (
        select 1 from jsonb_array_elements(p -> 'cards') e(value)
         where jsonb_typeof(e.value) <> 'object'
            or not (e.value ?& array['archetype_key', 'payload'])
            or jsonb_typeof(e.value -> 'archetype_key') <> 'string'
            -- ⚠ LE FOND DE LA RÉCURSION.
            or (e.value ->> 'archetype_key') = 'carousel'
            or not exists (
                 select 1 from public.content_archetypes a
                  where a.id = (e.value ->> 'archetype_key') and a.active
               )
            or not public.content_topic_payload_valid(
                 e.value ->> 'archetype_key', e.value -> 'payload')
      )

    -- ⚠ UN ARCHÉTYPE INCONNU EST UN REFUS, jamais un laissez-passer. Écrit
    -- comme un `else true` ce validateur aurait accepté n'importe quel payload
    -- sous n'importe quelle clef mal orthographiée.
    else false
  end
$$;

comment on function public.content_topic_payload_valid(text, jsonb) is
  'The payload shape, per archetype. ONE entry point, eleven branches, and an unknown archetype REFUSES -- written as `else true` it would have accepted any payload under a misspelled key. `stable` rather than `immutable`: the carousel branch reads content_archetypes. Never NULL.';

revoke all on function public.content_topic_payload_valid(text, jsonb) from public, anon;
grant execute on function public.content_topic_payload_valid(text, jsonb) to authenticated, service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  -- ⚠ `v_arch`, PAS `a`. Les blocs ci-dessous aliasent `content_archetypes a`,
  -- et plpgsql résout `a.id` vers la VARIABLE avant la table : un `record`
  -- nommé `a` fait échouer chaque `exists` avec « tuple structure is
  -- indeterminate », loin de la ligne qui a choisi le nom.
  v_arch record;
  v_n    integer;
  junk   text;
begin
  -- ---- onze archétypes, et le catalogue est bien peuplé ------------------
  select count(*) into v_n from public.content_archetypes;
  if v_n <> 11 then
    raise exception 'content_archetypes: % lignes, attendu 11', v_n;
  end if;
  if (select count(*) from public.content_archetypes where is_multi_card) <> 1 then
    raise exception 'content_archetypes: is_multi_card doit être vrai pour carousel seul.';
  end if;

  -- ---- ⚠ LES TROIS VOCABULAIRES NE SE RECOUVRENT PAS ---------------------
  -- Le même garde-fou que 20260910083735 pose entre archetype et register, et
  -- pour la même raison : le jour où une valeur appartient à deux axes, c'est
  -- l'axe le plus permissif qui gagne. `question` est déjà nommé
  -- `reflective_question` côté register pour éviter la collision évidente ; il
  -- n'y en a aucune autre, et ce bloc refuse la prochaine.
  if exists (
    select 1 from public.content_archetypes a
     where a.id in (select id from public.content_registers)
  ) then
    raise exception 'un archétype de composition porte le nom d''un registre éditorial.';
  end if;
  if exists (
    select 1 from public.content_archetypes a
     where a.id in ('statement', 'question', 'notes', 'signature', 'story')
  ) then
    raise exception 'un archétype de composition porte le nom d''une mise en page content_items.';
  end if;

  -- ---- content_words compte, et ne rend jamais NULL ----------------------
  if public.content_words(null) <> 0 then
    raise exception 'content_words(null) ne rend pas 0.';
  end if;
  if public.content_words('') <> 0 then
    raise exception 'content_words('''') ne rend pas 0.';
  end if;
  if public.content_words('   ') <> 0 then
    raise exception 'content_words(espaces) ne rend pas 0.';
  end if;
  if public.content_words('one') <> 1 then
    raise exception 'content_words(un mot) ne rend pas 1.';
  end if;
  if public.content_words('  three  little   words ') <> 3 then
    raise exception 'content_words: les espaces multiples ne sont pas repliés.';
  end if;

  -- ---- les briques rejettent ce qui n'est pas un item --------------------
  foreach junk in array array['null', '{}', '[]', '"x"', '42', 'true'] loop
    if public.content_item_valid(junk::jsonb) is not false then
      raise exception 'content_item_valid(%) n''a pas rendu false.', junk;
    end if;
    if public.content_items_valid(junk::jsonb, 1, 4) is not false then
      raise exception 'content_items_valid(%) n''a pas rendu false.', junk;
    end if;
  end loop;
  if public.content_item_valid(null) is not false then
    raise exception 'content_item_valid(NULL) n''a pas rendu false.';
  end if;

  -- ---- les budgets de mots mordent --------------------------------------
  if public.content_item_valid('{"label":"a b c d","gloss":"short"}'::jsonb) then
    raise exception 'un label de quatre mots a été accepté.';
  end if;
  if public.content_item_valid('{"label":"","gloss":"short"}'::jsonb) then
    raise exception 'un label vide a été accepté.';
  end if;
  if public.content_item_valid('{"label":"one two","gloss":"a b c d e f g"}'::jsonb) then
    raise exception 'un gloss de sept mots a été accepté.';
  end if;
  if not public.content_item_valid('{"label":"one two","gloss":"a b c d e f"}'::jsonb) then
    raise exception 'un item bien formé a été rejeté.';
  end if;

  -- ---- ⚠ ONZE BRANCHES, ONZE REFUS SUR LE VIDE --------------------------
  -- Anti-vacuité de tout ce qui suit : si une branche rendait NULL, le CHECK
  -- de content_topics accepterait ce payload-là en silence.
  for v_arch in select id from public.content_archetypes loop
    foreach junk in array array['null', '[]', '"x"', '42', '{}'] loop
      if public.content_topic_payload_valid(v_arch.id, junk::jsonb) is not false then
        raise exception 'content_topic_payload_valid(%, %) n''a pas rendu false.', v_arch.id, junk;
      end if;
    end loop;
  end loop;
  if public.content_topic_payload_valid('pas_un_archetype',
       '{"statement":"une phrase parfaitement valide ailleurs"}'::jsonb) is not false then
    raise exception 'un archétype inconnu a laissé passer un payload.';
  end if;
  if public.content_topic_payload_valid(null, '{}'::jsonb) is not false then
    raise exception 'content_topic_payload_valid(NULL, …) n''a pas rendu false.';
  end if;

  -- ---- et chaque branche ACCEPTE sa forme -------------------------------
  if not public.content_topic_payload_valid('single_statement',
       '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb) then
    raise exception 'single_statement: une déclaration bien formée a été rejetée.';
  end if;
  if public.content_topic_payload_valid('single_statement', '{"statement":"Too short"}'::jsonb) then
    raise exception 'single_statement: deux mots ont été acceptés.';
  end if;

  if not public.content_topic_payload_valid('quadrant_model', $j$
    {"axis_x":"Effort","axis_y":"Relief","items":[
      {"label":"Push through","gloss":"costly and familiar"},
      {"label":"Step back","gloss":"quiet and unpractised"},
      {"label":"Ask for help","gloss":"hardest of the four"},
      {"label":"Wait it out","gloss":"sometimes the answer"}]}$j$::jsonb) then
    raise exception 'quadrant_model: un quadrant bien formé a été rejeté.';
  end if;
  if public.content_topic_payload_valid('quadrant_model', $j$
    {"axis_x":"Effort","axis_y":"Relief","items":[
      {"label":"One","gloss":"a"},{"label":"Two","gloss":"b"},{"label":"Three","gloss":"c"}]}$j$::jsonb) then
    raise exception 'quadrant_model: trois cases ont été acceptées comme un quadrant.';
  end if;

  if not public.content_topic_payload_valid('cycle', $j$
    {"nodes":[{"label":"Notice","gloss":"the first flicker"},
              {"label":"Name it","gloss":"out loud if possible"},
              {"label":"Let it pass","gloss":"without arguing"}]}$j$::jsonb) then
    raise exception 'cycle: trois nœuds bien formés ont été rejetés.';
  end if;
  if public.content_topic_payload_valid('cycle', $j$
    {"nodes":[{"label":"There","gloss":"and back"},{"label":"Back","gloss":"and there"}]}$j$::jsonb) then
    raise exception 'cycle: deux nœuds ont été acceptés comme un cycle.';
  end if;

  if not public.content_topic_payload_valid('surface_and_beneath', $j$
    {"surface":{"label":"Im fine","gloss":"said quickly"},
     "beneath":{"label":"Im tired","gloss":"said to no one"}}$j$::jsonb) then
    raise exception 'surface_and_beneath: une paire bien formée a été rejetée.';
  end if;

  if not public.content_topic_payload_valid('comparison_pair', $j$
    {"left":[{"label":"Advice","gloss":"tells you what"},{"label":"Fixing","gloss":"ends the feeling"}],
     "right":[{"label":"Witness","gloss":"stays with you"},{"label":"Holding","gloss":"lets it move"}]}$j$::jsonb) then
    raise exception 'comparison_pair: une comparaison équilibrée a été rejetée.';
  end if;
  if public.content_topic_payload_valid('comparison_pair', $j$
    {"left":[{"label":"Advice","gloss":"tells you what"},{"label":"Fixing","gloss":"ends the feeling"}],
     "right":[{"label":"Witness","gloss":"stays with you"}]}$j$::jsonb) then
    raise exception 'comparison_pair: deux colonnes inégales ont été acceptées.';
  end if;

  if not public.content_topic_payload_valid('numbered_strategies', $j$
    {"items":[{"label":"Name it","gloss":"before it grows"},
              {"label":"Slow down","gloss":"one breath longer"},
              {"label":"Ask once","gloss":"then let go"}]}$j$::jsonb) then
    raise exception 'numbered_strategies: trois stratégies ont été rejetées.';
  end if;

  -- ⚠ L'ACRONYME S'ACCORDE, ET DANS L'ORDRE.
  if not public.content_topic_payload_valid('lettered_technique', $j$
    {"acronym":"RAIN","items":[
      {"label":"Recognise","gloss":"what is here"},
      {"label":"Allow","gloss":"it to be here"},
      {"label":"Investigate","gloss":"with kindness"},
      {"label":"Nurture","gloss":"what needs it"}]}$j$::jsonb) then
    raise exception 'lettered_technique: RAIN bien formé a été rejeté.';
  end if;
  if public.content_topic_payload_valid('lettered_technique', $j$
    {"acronym":"RAIN","items":[
      {"label":"Recognise","gloss":"what is here"},
      {"label":"Investigate","gloss":"with kindness"},
      {"label":"Allow","gloss":"it to be here"},
      {"label":"Nurture","gloss":"what needs it"}]}$j$::jsonb) then
    raise exception 'lettered_technique: un RAIN dans le désordre (R,I,A,N) a été accepté.';
  end if;
  if public.content_topic_payload_valid('lettered_technique', $j$
    {"acronym":"RAIN","items":[
      {"label":"Recognise","gloss":"what is here"},
      {"label":"Allow","gloss":"it to be here"},
      {"label":"Investigate","gloss":"with kindness"}]}$j$::jsonb) then
    raise exception 'lettered_technique: trois items pour quatre lettres ont été acceptés.';
  end if;

  if not public.content_topic_payload_valid('concentric_control', $j$
    {"rings":[{"label":"Out there","gloss":"none of it yours"},
              {"label":"Right here","gloss":"some of it yours"}]}$j$::jsonb) then
    raise exception 'concentric_control: deux anneaux ont été rejetés.';
  end if;

  if not public.content_topic_payload_valid('annotated_curve', $j$
    {"axis_x":"Weeks","axis_y":"Steadiness","points":[
      {"label":"Start","gloss":"everything at once"},
      {"label":"Dip","gloss":"the honest middle"},
      {"label":"Steady","gloss":"not the same as fixed"}]}$j$::jsonb) then
    raise exception 'annotated_curve: une courbe bien formée a été rejetée.';
  end if;

  if not public.content_topic_payload_valid('practitioner_card', $j$
    {"lines":["Evenings and early mornings","Telehealth across two states"]}$j$::jsonb) then
    raise exception 'practitioner_card: deux lignes ont été rejetées.';
  end if;
  if public.content_topic_payload_valid('practitioner_card', $j$
    {"lines":["A line that runs on and on and on and on and on and on","Second"]}$j$::jsonb) then
    raise exception 'practitioner_card: une ligne de plus de huit mots a été acceptée.';
  end if;

  -- ---- le carrousel récurse, et ne s'imbrique pas -----------------------
  if not public.content_topic_payload_valid('carousel', $j$
    {"cards":[
      {"archetype_key":"single_statement","payload":{"statement":"The first card says one thing only"}},
      {"archetype_key":"cycle","payload":{"nodes":[
        {"label":"Notice","gloss":"the first flicker"},
        {"label":"Name it","gloss":"out loud if possible"},
        {"label":"Let it pass","gloss":"without arguing"}]}},
      {"archetype_key":"single_statement","payload":{"statement":"And the last one closes the door"}}]}$j$::jsonb) then
    raise exception 'carousel: un carrousel bien formé a été rejeté.';
  end if;
  if public.content_topic_payload_valid('carousel', $j$
    {"cards":[
      {"archetype_key":"single_statement","payload":{"statement":"A card that is perfectly fine"}},
      {"archetype_key":"single_statement","payload":{"statement":"Another card that is fine too"}},
      {"archetype_key":"single_statement","payload":{"statement":"x"}}]}$j$::jsonb) then
    raise exception 'carousel: une carte au payload invalide est passée -- la récursion ne mord pas.';
  end if;
  if public.content_topic_payload_valid('carousel', $j$
    {"cards":[
      {"archetype_key":"single_statement","payload":{"statement":"A card that is perfectly fine"}},
      {"archetype_key":"single_statement","payload":{"statement":"Another card that is fine too"}},
      {"archetype_key":"carousel","payload":{"cards":[]}}]}$j$::jsonb) then
    raise exception 'carousel: un carrousel imbriqué a été accepté.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.content_topic_payload_valid(text, jsonb);
--   drop function if exists public.content_items_valid(jsonb, integer, integer);
--   drop function if exists public.content_item_valid(jsonb);
--   drop function if exists public.content_words(text);
--   drop table    if exists public.content_archetypes;
