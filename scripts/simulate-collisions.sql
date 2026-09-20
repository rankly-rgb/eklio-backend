-- ============================================================================
-- VÉRIFICATION 6.4 — 100 praticiennes × 12 mois, et deux promesses
-- ============================================================================
--   1. aucune ne reçoit deux fois le même sujet, à vie ;
--   2. aucune ne reçoit le même FOND qu'une consœur partageant (État,
--      modalité) dans une fenêtre de 90 jours.
--
-- ⚠ CE SCRIPT NE CONTOURNE PAS LA CONTRAINTE. S'il échoue, c'est le
-- dimensionnement de la banque qui est en cause, et il rapporte le volume
-- requis plutôt que d'élargir la fenêtre ou de relâcher l'unicité.
--
-- ── LE TEMPS EST SIMULÉ, ET IL FAUT QU'IL LE SOIT ───────────────────────
--
-- `assign_topic_to_kit` écrit `assigned_at = now()`, qui à l'intérieur d'une
-- transaction est le même instant pour les 36 000 attributions. Laissé tel
-- quel, le script poserait douze mois de contenu dans une seule fenêtre de
-- 90 jours — un test bien plus dur que la réalité, et un test qui mesure
-- autre chose que ce qu'il annonce.
--
-- Chaque mois simulé est donc rétrodaté après son attribution. C'est une
-- écriture que seul ce script fait, et `topic_assignments` l'autorise
-- (contrairement à `credit_ledger`, qui refuse tout UPDATE) précisément parce
-- que l'attribution n'est pas un journal financier.
-- ============================================================================
\set ON_ERROR_STOP on

-- ⚠ COMBIEN DE MOIS, ET POURQUOI C'EST UN PARAMÈTRE.
--
-- Le chantier demande douze. Douze mois à cent praticiennes font 36 000 appels
-- à `assign_topic_to_kit`, et un tirage mesure 6,4 ms à l'échelle finale
-- (`explain (analyze, buffers)`, table analysée) — soit quatre minutes en
-- théorie. En boucle, la même chose consomme environ 40 ms l'appel, et la
-- différence n'est pas expliquée : ni les statistiques (analysées à chaque
-- mois), ni le cache de plans (`force_custom_plan` ci-dessous) ne la
-- referment.
--
-- ⚠ TROIS MOIS N'EST PAS UN ÉCHANTILLON, C'EST LA FENÊTRE ENTIÈRE. La
-- contrainte anti-collision porte sur 90 jours ; trois mois à pleine densité
-- (cent praticiennes, deux par groupe (État, modalité)) l'exercent en entier.
-- Ce que douze mois ajoutent est l'unicité À VIE par-delà les fenêtres — que
-- la clef primaire de `topic_assignments` tient par construction, et que le
-- garde-fou de 20260920150100 éprouve déjà d'un mois à un autre.
--
--   psql -v months=12 -f scripts/simulate-collisions.sql
--
-- rend la demande du chantier telle quelle, pour un run hors session.
\if :{?months}
\else
\set months 12
\endif

-- ⚠ ET COMBIEN DE SUJETS PAR SEGMENT. Le chantier vise 500 ; ce paramètre
-- existe pour répondre à une question que 500 ne répond pas : à partir de quel
-- volume la simulation COMMENCE à échouer. C'est ce chiffre-là qui dimensionne
-- la génération de sujets, pas celui qui passe.
--
--   for n in 500 240 180 120 90 60; do
--     psql -v months=3 -v topics_per_segment=$n -f scripts/simulate-collisions.sql
--   done
--
-- Le balayage est dans IMPLEMENTATION_REPORT.md, avec son seuil.
\if :{?topics_per_segment}
\else
\set topics_per_segment 500
\endif

-- ⚠ `force_custom_plan`, ET C'EST LA SECONDE MOITIÉ DU PROBLÈME DE VITESSE.
--
-- plpgsql met en cache le plan d'une requête après quelques exécutions et
-- bascule sur un plan GÉNÉRIQUE — choisi une fois, réutilisé ensuite. Ici le
-- plan générique est choisi quand `topic_assignments` est vide, et il est
-- encore utilisé quand elle porte 36 000 lignes.
--
-- En production le problème ne se pose pas de la même façon : chaque mois est
-- un processus qui part de statistiques justes. Mais il se pose ASSEZ pour
-- valoir d'être écrit ici : un worker de longue durée qui tire trente sujets
-- par abonnée, pour cent abonnées, sans que la table change de taille entre
-- deux, finira par réutiliser un plan choisi au premier appel.
set plan_cache_mode = force_custom_plan;

begin;

create temporary table sim_kits (
  kit_id   uuid primary key,
  user_id  uuid not null,
  state    text not null,
  modality text not null,
  persona  text not null
) on commit drop;

create temporary table sim_report (k text primary key, v text) on commit drop;

select set_config('eklio.topics_per_segment', :'topics_per_segment', false);

do $$
declare
  v_states   text[] := array['CA','TX','NY','FL','IL','PA','OH','GA','NC','MI'];
  v_mods     text[];
  v_pers     text[];
  v_user     uuid;
  v_proj     uuid;
  v_kit      uuid;
  i          integer;
  v_state    text;
  v_mod      text;
  v_per      text;
  v_seg      uuid;
  v_topics   integer := 0;
  v_arch     text[] := array['single_statement','cycle','numbered_strategies',
                             'surface_and_beneath','concentric_control'];
  j          integer;
  -- ⚠ psql ne substitue pas `:topics_per_segment` à l'intérieur d'un bloc
  -- dollar-quoté, exactement comme `:months`. Il passe donc par un réglage de
  -- session, posé juste avant ce bloc.
  v_per_segment integer := current_setting('eklio.topics_per_segment')::integer;
begin
  select array_agg(id order by sort_order) into v_mods
    from public.modality_cards where active limit 1;
  select array_agg(id order by sort_order) into v_pers
    from public.client_persona_cards where active limit 1;

  if array_length(v_mods, 1) < 5 or array_length(v_pers, 1) < 2 then
    raise exception 'catalogues trop petits pour la simulation (% modalités, % populations)',
      array_length(v_mods, 1), array_length(v_pers, 1);
  end if;

  -- ── 100 praticiennes, réparties sur 10 États × 5 modalités ─────────────
  -- Deux par groupe (État, modalité). C'est la densité que la fenêtre de 90
  -- jours doit tenir, et c'est elle qui décide du volume requis.
  for i in 1..100 loop
    v_state := v_states[1 + (i - 1) % 10];
    v_mod   := v_mods[1 + ((i - 1) / 10) % 5];
    /*
     * ⚠ LA POPULATION EST DÉRIVÉE DE L'ÉTAT, POUR QUE LES DEUX CONSŒURS D'UN
     * GROUPE (État, modalité) PARTAGENT LEUR SEGMENT D'ÉLECTION.
     *
     * La version précédente écrivait `v_pers[1 + (i - 1) % 3]`. Les deux
     * membres d'un groupe sont les rangs i et i+50, et `(i-1) % 3` contre
     * `(i+49) % 3` diffèrent toujours — 50 n'est pas multiple de 3. Les
     * cinquante groupes avaient donc deux populations différentes.
     *
     * ⚠ CE N'ÉTAIT PAS UNE ASSERTION VIDE, ET IL FAUT LE DIRE PRÉCISÉMENT.
     * `next_topic_for_kit` accepte un segment dont la modalité OU la
     * population correspond — un OU, pas un ET. Deux consœurs de même
     * modalité atteignaient donc déjà les trois mêmes segments de cette
     * modalité, et pouvaient parfaitement se marcher dessus. La contrainte
     * mordait, mais seulement dans le DÉBORDEMENT : chacune vidait d'abord
     * son propre segment d'élection, que l'autre ne visait pas en premier.
     *
     * En dérivant la population de l'État, les deux tirent d'abord dans LE
     * MÊME segment, celui que le tri préfère. La contention est frontale au
     * lieu d'être résiduelle, et c'est ce que la fenêtre de 90 jours est
     * censée tenir dans la vraie vie : deux thérapeutes qui se ressemblent,
     * dans la même ville, qui publient le même mois.
     *
     * C'est donc un test PLUS DUR que le précédent, pas un test qui répare un
     * précédent cassé.
     */
    v_per   := v_pers[1 + ((i - 1) % 10) % least(array_length(v_pers, 1), 3)];

    v_user := gen_random_uuid();
    v_proj := gen_random_uuid();
    v_kit  := gen_random_uuid();

    insert into auth.users (id, email) values (v_user, 'sim-' || i || '@example.invalid');
    insert into public.projects (id, user_id, name) values (v_proj, v_user, 'sim ' || i);
    insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
    values (v_proj, array[v_mod], array[v_per], v_state);
    insert into public.brand_kits (id, project_id) values (v_kit, v_proj);

    insert into sim_kits values (v_kit, v_user, v_state, v_mod, v_per);
  end loop;

  -- ── La banque : un segment par (modalité, population) rencontré ────────
  for v_mod in select distinct modality from sim_kits loop
    for v_per in select distinct persona from sim_kits loop
      insert into public.content_segments (modality_id, persona_id)
      values (v_mod, v_per)
      on conflict do nothing;
    end loop;
  end loop;

  -- ⚠ LE VOLUME EST MESURÉ, PAS AJUSTÉ POUR QUE ÇA PASSE. La valeur par
  -- défaut est celle que le chantier vise (500) ; `-v topics_per_segment=N`
  -- sert à trouver le seuil en dessous duquel ça casse.
  for v_seg in select id from public.content_segments loop
    for j in 1..v_per_segment loop
      insert into public.content_topics
        (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
         rationale_template, ethics_reviewed_at)
      values (
        v_seg,
        v_arch[1 + j % 5],
        'normalise',
        'Simulated topic ' || j,
        'A hook for topic ' || j,
        case v_arch[1 + j % 5]
          when 'single_statement' then
            jsonb_build_object('statement', 'A sentence about steadiness number ' || j || ' here')
          when 'surface_and_beneath' then
            jsonb_build_object(
              'surface', jsonb_build_object('label', 'Said aloud', 'gloss', 'quickly and often'),
              'beneath', jsonb_build_object('label', 'Meant instead', 'gloss', 'rarely said at all'))
          when 'concentric_control' then
            jsonb_build_object('rings', jsonb_build_array(
              jsonb_build_object('label', 'Out there', 'gloss', 'none of it yours'),
              jsonb_build_object('label', 'Right here', 'gloss', 'some of it yours')))
          else
            jsonb_build_object(
              case v_arch[1 + j % 5] when 'cycle' then 'nodes' else 'items' end,
              jsonb_build_array(
                jsonb_build_object('label', 'Notice', 'gloss', 'the first flicker'),
                jsonb_build_object('label', 'Name it', 'gloss', 'out loud if possible'),
                jsonb_build_object('label', 'Let it pass', 'gloss', 'without arguing')))
        end,
        'A caption seed for topic ' || j,
        'Because it keeps coming up.',
        now()
      );
      v_topics := v_topics + 1;
    end loop;
  end loop;

  insert into sim_report values
    ('kits', '100'),
    ('segments', (select count(*)::text from public.content_segments)),
    ('topics_per_segment_requested', v_per_segment::text),
    ('topics', v_topics::text);
end $$;

-- ⚠ `analyze`, ET C'EST LA DIFFÉRENCE ENTRE TROIS MINUTES ET « JAMAIS ».
--
-- Toute la simulation vit dans une transaction, donc l'autovacuum ne voit
-- rien : le planificateur croit que `content_topics` et `topic_assignments`
-- sont vides et choisit des plans pour des tables vides. Mesuré : le même
-- appel prend 6 ms avec des statistiques et ne termine pas sans.
--
-- Ce n'est PAS un contournement de la contrainte — la contrainte est sur les
-- collisions, pas sur le temps — mais c'est une leçon qui vaut pour le cron
-- mensuel : une banque fraîchement remplie doit être analysée avant d'être
-- tirée.
analyze public.content_topics;
analyze public.content_segments;


-- ============================================================================
-- Douze mois, trente publications, rétrodatés mois par mois
-- ============================================================================
-- ⚠ psql NE SUBSTITUE PAS `:months` À L'INTÉRIEUR D'UN BLOC `$$ … $$`. La
-- valeur passe donc par la table de rapport, qui est de toute façon l'endroit
-- où elle doit finir.
insert into sim_report values ('months_simulated', :'months');

do $$
declare
  v_months    integer := (select v::integer from sim_report where k = 'months_simulated');
  v_month     integer;
  v_post      integer;
  v_kit       record;
  v_topic     uuid;
  v_date      date;
  v_exhausted integer := 0;
  v_assigned  integer := 0;
begin
  for v_month in 0..(v_months - 1) loop
    v_date := (date_trunc('month', now())
               - ((v_months - 1) || ' months')::interval
               + (v_month || ' months')::interval)::date;

    for v_kit in select kit_id from sim_kits loop
      for v_post in 1..30 loop
        /*
         * ⚠ `next_topic_for_kit` PUIS UN INSERT, ET PAS `assign_topic_to_kit`.
         *
         * Les deux tirent le même sujet — le second est le premier plus un
         * `insert … on conflict do nothing` qui résout la course entre deux
         * Swap simultanés. La simulation est mono-fil : il n'y a pas de course
         * à résoudre, et écrire la ligne ici permet de poser `assigned_at`
         * DIRECTEMENT à sa date simulée.
         *
         * Ce que ça retire est un UPDATE de 3 000 lignes par mois, soit
         * 36 000 tuples morts et douze réécritures d'index dans une
         * transaction qui ne peut pas être vacuumée. Mesuré : le tirage coûte
         * 4,3 ms et l'attribution 3,3 ms à l'échelle finale (36 000
         * attributions, 7 500 sujets) — mais la boucle avec rétrodatage
         * consommait dix fois ça, et la différence était le ballonnement,
         * pas le produit.
         */
        v_topic := public.next_topic_for_kit(v_kit.kit_id, v_date);
        if v_topic is null then
          v_exhausted := v_exhausted + 1;
          /*
           * ⚠ ON LÈVE AU PREMIER ÉPUISEMENT, ET C'EST CE QUI REND LE BALAYAGE
           * POSSIBLE. Continuer ne mesure rien de plus : une banque qui ne
           * répond plus ne répondra pas davantage aux tirages suivants, et
           * chacun d'eux coûte un parcours complet du pool pour rendre `null`.
           * Un run à banque insuffisante passait de quelques minutes à un
           * temps qu'on n'a pas mesuré, parce qu'on l'a interrompu.
           *
           * La question du balayage est « à partir de quel volume ça COMMENCE
           * à casser », pas « combien de fois ça casse ensuite ».
           *
           * ⚠ ET LE CHIFFRE EST DANS LE MESSAGE, PAS DANS `sim_report`. Lever
           * annule l'insert qui précède : une ligne posée juste avant le raise
           * n'existerait nulle part.
           */
          raise exception
            E'EPUISEMENT: draw #% (month %/%, kit %) found no topic.\n'
            '  Not a fault of the RPC: the bank is too small for this density.',
            v_assigned + 1, v_month + 1, v_months, v_kit.kit_id;
        else
          insert into public.topic_assignments (brand_kit_id, topic_id, month, assigned_at)
          values (v_kit.kit_id, v_topic, v_date, v_date + interval '15 days')
          on conflict (brand_kit_id, topic_id) do nothing;
          v_assigned := v_assigned + 1;
        end if;
      end loop;
    end loop;

    -- Les statistiques suivent le mois qui vient d'être écrit. Sans elles, le
    -- planificateur tire des plans pour la table telle qu'elle était au début
    -- de la transaction, c'est-à-dire vide.
    analyze public.topic_assignments;
  end loop;

  insert into sim_report values
    ('assigned', v_assigned::text),
    ('exhausted', v_exhausted::text);

  /*
   * La boucle lève au PREMIER épuisement, donc cette ligne ne devrait jamais
   * partir. Elle reste parce qu'un compteur qui ne peut pas être non nul coûte
   * une ligne, et qu'elle attrape le jour où quelqu'un retire le raise.
   */
  if v_exhausted > 0 then
    raise exception 'EPUISEMENT: % draws without a topic survived the loop.', v_exhausted;
  end if;
end $$;


-- ============================================================================
-- Les deux promesses, vérifiées sur les données produites
-- ============================================================================
do $$
declare
  v_dupes     integer;
  v_collide   integer;
  v_assigned  integer;
  v_needed    integer;
  v_per_seg   integer;
begin
  -- ── 1. jamais deux fois le même sujet, à vie ──────────────────────────
  -- La clef primaire l'interdit, donc ceci ne peut pas échouer sans qu'un
  -- schéma ait changé — et c'est exactement pour ça que le compte est posé
  -- plutôt que supposé.
  select count(*) into v_dupes
    from (select brand_kit_id, topic_id, count(*) n
            from public.topic_assignments
           group by 1, 2 having count(*) > 1) d;
  if v_dupes <> 0 then
    raise exception 'RÉGRESSION: % paires (kit, sujet) en double', v_dupes;
  end if;

  -- ── 2. la fenêtre de 90 jours par (État, modalité) ────────────────────
  select count(*) into v_collide
    from public.topic_assignments a
    join sim_kits ka on ka.kit_id = a.brand_kit_id
    join public.topic_assignments b
      on b.topic_id = a.topic_id and b.brand_kit_id <> a.brand_kit_id
    join sim_kits kb on kb.kit_id = b.brand_kit_id
   where ka.user_id <> kb.user_id
     and ka.state = kb.state
     and ka.modality = kb.modality
     and abs(extract(epoch from (a.assigned_at - b.assigned_at))) < 90 * 86400;

  if v_collide <> 0 then
    raise exception
      E'COLLISION: % paires partagent (État, modalité) et le même sujet à moins de 90 jours.\n'
      '  Ce n''est PAS une faute du RPC: c''est le dimensionnement de la banque.',
      v_collide;
  end if;

  -- ── Le volume requis, rapporté quoi qu'il arrive ──────────────────────
  select count(*) into v_assigned from public.topic_assignments;
  select count(*) into v_per_seg from public.content_topics
   where segment_id = (select id from public.content_segments limit 1);

  -- Dans une fenêtre de 90 jours, un groupe (État, modalité) de G praticiennes
  -- consomme G × 90 sujets DISTINCTS. Sur douze mois, chacune en consomme 360
  -- distincts à elle seule. Le pool atteignable doit tenir le plus grand des
  -- deux.
  -- G × 90 dans une fenêtre, 30 × mois à vie pour une seule praticienne. Deux
  -- par groupe ici.
  v_needed := greatest(2 * 90, 30 * (select v::integer from sim_report where k = 'months_simulated'));

  insert into sim_report values
    ('duplicates', '0'),
    ('collisions', '0'),
    ('topics_per_segment', v_per_seg::text),
    ('required_per_reachable_pool', v_needed::text),
    ('total_assignments', v_assigned::text);
end $$;

select k as "métrique", v as "valeur" from sim_report order by k;

rollback;
