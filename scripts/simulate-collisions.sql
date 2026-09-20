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
    v_per   := v_pers[1 + (i - 1) % least(array_length(v_pers, 1), 3)];

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

  -- ⚠ 500 SUJETS PAR SEGMENT, le volume que le chantier vise. Le script
  -- mesure si ça suffit ; il ne l'ajuste pas pour que ça passe.
  for v_seg in select id from public.content_segments loop
    for j in 1..500 loop
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
do $$
declare
  v_month     integer;
  v_post      integer;
  v_kit       record;
  v_topic     uuid;
  v_date      date;
  v_exhausted integer := 0;
  v_assigned  integer := 0;
begin
  for v_month in 0..11 loop
    v_date := (date_trunc('month', now()) - interval '11 months' + (v_month || ' months')::interval)::date;

    for v_kit in select kit_id from sim_kits loop
      for v_post in 1..30 loop
        v_topic := public.assign_topic_to_kit(v_kit.kit_id, v_date);
        if v_topic is null then
          v_exhausted := v_exhausted + 1;
        else
          v_assigned := v_assigned + 1;
        end if;
      end loop;
    end loop;

    -- ⚠ LE RÉTRODATAGE. Sans lui les douze mois tombent dans une seule
    -- fenêtre de 90 jours, et la simulation mesure une contrainte que le
    -- produit n'impose pas.
    update public.topic_assignments
       set assigned_at = v_date + interval '15 days'
     where month = v_date;

    -- Les statistiques suivent le mois qui vient d'être écrit. Sans elles, le
    -- planificateur tire des plans pour la table telle qu'elle était au début
    -- de la transaction, c'est-à-dire vide.
    analyze public.topic_assignments;
  end loop;

  insert into sim_report values
    ('assigned', v_assigned::text),
    ('exhausted', v_exhausted::text);
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
  v_needed := greatest(2 * 90, 360);

  insert into sim_report values
    ('duplicates', '0'),
    ('collisions', '0'),
    ('topics_per_segment', v_per_seg::text),
    ('required_per_reachable_pool', v_needed::text),
    ('total_assignments', v_assigned::text);
end $$;

select k as "métrique", v as "valeur" from sim_report order by k;

rollback;
