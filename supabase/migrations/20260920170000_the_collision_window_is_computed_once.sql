-- ============================================================================
-- Eklio — la fenêtre anti-collision se calcule UNE fois, pas par sujet
-- ============================================================================
-- ⚠ UN DÉFAUT TROUVÉ PAR LA VÉRIFICATION 6.4, ET PAR RIEN D'AUTRE.
--
-- `next_topic_for_kit` (20260920150100) exprimait la fenêtre de 90 jours comme
-- un `not exists` CORRÉLÉ : pour chaque sujet candidat, une sous-requête qui
-- joint `topic_assignments`, `brand_kits`, `projects` et `project_briefs`.
--
-- C'est correct, et tous les garde-fous passaient : ils tournent sur deux ou
-- trois sujets. La simulation de la PHASE 6 tourne sur cent praticiennes,
-- douze mois, trente publications — 36 000 appels contre une banque de 7 500
-- sujets. À ce volume, la sous-requête corrélée s'exécute environ 270 millions
-- de fois, et la simulation ne termine pas.
--
-- ── CE QUE ÇA VEUT DIRE POUR LA PRODUCTION ──────────────────────────────
--
-- Le cron mensuel appelle ce RPC trente fois par abonnée, en série, dans les
-- 300 secondes que Vercel accorde. L'ancienne forme y tenait pour les
-- premières abonnées et cessait d'y tenir à mesure que la banque grandissait —
-- c'est-à-dire que le mois se serait mis à échouer un jour, sans qu'aucun
-- changement de code l'explique.
--
-- ── LA CORRECTION ───────────────────────────────────────────────────────
--
-- La fenêtre ne dépend pas du sujet candidat : c'est l'ensemble des sujets
-- servis récemment aux praticiennes du même (État, modalité). Calculé une fois
-- dans un CTE, il devient une anti-jointure au lieu d'une sous-requête par
-- ligne.
--
-- ⚠ LA SÉMANTIQUE EST INCHANGÉE, ET C'EST LA CONDITION. Le tri, les bornes,
-- l'exclusion à vie, la dégradation vers les voisins : identiques au token
-- près. Une optimisation qui change aussi le classement n'est pas une
-- optimisation, c'est un autre produit.
-- ============================================================================

create or replace function public.next_topic_for_kit(
  p_brand_kit_id uuid,
  p_month        date,
  p_archetype    text default null
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with kit as (
    select coalesce(pb.modality_ids, '{}')       as modalities,
           coalesce(pb.client_persona_ids, '{}') as personas,
           upper(nullif(btrim(coalesce(pb.state, '')), '')) as state_code,
           pr.user_id                            as user_id
      from public.brand_kits bk
      join public.projects      pr on pr.id = bk.project_id
      left join public.project_briefs pb on pb.project_id = pr.id
     where bk.id = p_brand_kit_id
  ),
  /*
   * ⚠ LES SUJETS BLOQUÉS PAR LA FENÊTRE, CALCULÉS UNE SEULE FOIS.
   *
   * Cet ensemble ne dépend pas du sujet candidat — il dépend de la praticienne
   * et de l'horloge. Écrit comme un `not exists` corrélé il était recalculé
   * pour chacun des 7 500 sujets de la banque, à chacun des 30 appels du mois,
   * pour chacune des abonnées.
   */
  blocked as (
    select distinct ta.topic_id
      from public.topic_assignments ta
      join public.brand_kits   obk on obk.id = ta.brand_kit_id
      join public.projects     opr on opr.id = obk.project_id
      left join public.project_briefs opb on opb.project_id = opr.id
     cross join kit k
     where ta.assigned_at > now() - public.topic_collision_window()
       and opr.user_id is distinct from k.user_id
       and k.state_code is not null
       and upper(nullif(btrim(coalesce(opb.state, '')), '')) = k.state_code
       and coalesce(opb.modality_ids, '{}') && k.modalities
  ),
  mine as (
    select ta.topic_id from public.topic_assignments ta
     where ta.brand_kit_id = p_brand_kit_id
  )
  select t.id
    from public.content_topics t
    join public.content_segments s on s.id = t.segment_id
   cross join kit k
   where t.ethics_reviewed_at is not null
     and (t.expires_at is null or t.expires_at > now())
     and (p_archetype is null or t.archetype_key = p_archetype)
     and not exists (select 1 from mine m where m.topic_id = t.id)
     and not exists (select 1 from blocked b where b.topic_id = t.id)
     and (s.modality_id = any (k.modalities) or s.persona_id = any (k.personas))
     and (s.state_code is null or s.state_code = k.state_code)
   order by
     (case when s.modality_id = any (k.modalities) then 2 else 0 end)
     + (case when s.persona_id = any (k.personas) then 2 else 0 end)
     + (case when s.state_code is not null then 1 else 0 end)
     + (case when t.timely then 3 else 0 end)
     desc,
     t.created_at desc,
     t.id
   limit 1
$$;

comment on function public.next_topic_for_kit(uuid, date, text) is
  'The next topic for this kit, or NULL when the bank has nothing eligible left. A QUERY: no model call, therefore free and instant -- this is what Swap runs on. The 90-day window is computed ONCE per call rather than per candidate topic; as a correlated subquery it ran ~270 million times in the phase 6 simulation and never finished. Degradation towards neighbouring segments is a single ranking rather than a ladder of fallbacks, and the sort ends on t.id so that two calls against the same bank state return the same topic.';

revoke all on function public.next_topic_for_kit(uuid, date, text) from public, anon, authenticated;
grant execute on function public.next_topic_for_kit(uuid, date, text) to service_role;


-- ============================================================================
-- Les index que cette forme veut
-- ============================================================================
-- ⚠ `assigned_at` SEUL, ET PAS `(topic_id, assigned_at)`. Le CTE `blocked`
-- part de la FENÊTRE — les attributions des 90 derniers jours, tous sujets
-- confondus — et remonte vers les praticiennes. L'index existant
-- `topic_assignments_topic_idx (topic_id, assigned_at desc)` servait la forme
-- corrélée, qui partait d'un sujet ; il ne sert plus le chemin qu'on prend.
create index if not exists topic_assignments_assigned_at_idx
  on public.topic_assignments (assigned_at desc);

-- L'anti-jointure « déjà servi à CE kit » part du kit.
create index if not exists topic_assignments_kit_topic_idx
  on public.topic_assignments (brand_kit_id, topic_id);


-- ============================================================================
-- Guard rails
-- ============================================================================
-- ⚠ LA SÉMANTIQUE, PAS LA VITESSE. Une optimisation se garde par ce qu'elle
-- n'a PAS changé ; la vitesse est mesurée par la simulation de la phase 6, qui
-- est le seul endroit où elle est mesurable.
do $$
declare
  v_mod  text; v_mod2 text; v_per text;
  v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_p1 uuid := gen_random_uuid(); v_p2 uuid := gen_random_uuid();
  v_k1 uuid := gen_random_uuid(); v_k2 uuid := gen_random_uuid();
  v_seg uuid; v_t uuid;
  v_month date := date_trunc('month', now())::date;
begin
  select id into v_mod  from public.modality_cards where active order by sort_order limit 1;
  select id into v_mod2 from public.modality_cards where active and id <> v_mod
   order by sort_order limit 1;
  select id into v_per  from public.client_persona_cards where active order by sort_order limit 1;

  insert into auth.users (id, email) values
    (v_u1, 'reopt-1@example.invalid'), (v_u2, 'reopt-2@example.invalid');
  insert into public.projects (id, user_id, name) values (v_p1, v_u1, 'A'), (v_p2, v_u2, 'B');
  insert into public.project_briefs (project_id, modality_ids, client_persona_ids, state)
  values (v_p1, array[v_mod], array[v_per], 'CA'),
         (v_p2, array[v_mod], array[v_per], 'CA');
  insert into public.brand_kits (id, project_id) values (v_k1, v_p1), (v_k2, v_p2);

  insert into public.content_segments (modality_id, persona_id) values (v_mod, v_per)
  returning id into v_seg;
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at)
  values (v_seg, 'single_statement', 'normalise', 'A topic', 'A hook',
          '{"statement":"Rest is not a reward you earn after everything else is done"}'::jsonb,
          'seed', 'Because.', now())
  returning id into v_t;

  -- Trouvé
  if public.next_topic_for_kit(v_k1, v_month) is distinct from v_t then
    raise exception 'la forme optimisée ne trouve plus le seul sujet éligible.';
  end if;

  -- Déterministe
  if public.next_topic_for_kit(v_k1, v_month)
     is distinct from public.next_topic_for_kit(v_k1, v_month) then
    raise exception 'la forme optimisée n''est plus déterministe.';
  end if;

  perform public.assign_topic_to_kit(v_k1, v_month);

  -- À vie
  if public.next_topic_for_kit(v_k1, v_month) is not null then
    raise exception 'la forme optimisée reproposerait un sujet déjà attribué.';
  end if;
  if public.next_topic_for_kit(v_k1, (v_month + interval '5 months')::date) is not null then
    raise exception 'la forme optimisée reproposerait un sujet dans un autre mois.';
  end if;

  -- La fenêtre inter-praticiennes
  if public.next_topic_for_kit(v_k2, v_month) is not null then
    raise exception 'la forme optimisée a perdu la fenêtre de 90 jours.';
  end if;

  -- Et elle ne bloque ni un autre État ni une autre modalité
  update public.project_briefs set state = 'FL' where project_id = v_p2;
  if public.next_topic_for_kit(v_k2, v_month) is distinct from v_t then
    raise exception 'la forme optimisée bloque une praticienne d''un autre État.';
  end if;
  update public.project_briefs set state = 'CA', modality_ids = array[v_mod2]
   where project_id = v_p2;
  if public.next_topic_for_kit(v_k2, v_month) is distinct from v_t then
    raise exception 'la forme optimisée bloque une praticienne d''une autre modalité.';
  end if;

  delete from public.content_segments where id = v_seg;
  delete from auth.users where id in (v_u1, v_u2);
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop index if exists public.topic_assignments_kit_topic_idx;
--   drop index if exists public.topic_assignments_assigned_at_idx;
--   -- restore next_topic_for_kit from 20260920150100 (the correlated form).
