-- ============================================================================
-- Eklio — `as materialized`, ou l'optimisation qui n'en était pas une
-- ============================================================================
-- ⚠ `20260920170000` A DÉPLACÉ LA FENÊTRE DANS UN CTE ET N'A RIEN CHANGÉ.
--
-- Depuis PostgreSQL 12, un CTE référencé UNE SEULE FOIS est INLINÉ : le
-- planificateur le recopie à l'endroit où il est lu et pousse la corrélation
-- dedans. `blocked` est lu une fois, dans un `not exists` corrélé sur
-- `t.id` — il redevenait donc mot pour mot la sous-requête corrélée que la
-- migration précédente croyait avoir retirée.
--
-- La mesure le disait et je ne l'ai pas lue tout de suite : le coût par
-- attribution CROISSAIT avec la table (6 ms à vide, 60 ms à 9 000
-- attributions, 127 ms à 18 000). Un coût constant par appel aurait été le
-- signe que le CTE tenait ; un coût qui suit la taille de la table est le
-- signe qu'on la rescanne à chaque candidat.
--
-- `as materialized` est la barrière d'optimisation qui dit au planificateur de
-- calculer l'ensemble une fois. C'est un mot, et c'est tout l'écart entre les
-- deux formes.
--
-- ── CE QUE ÇA APPREND SUR LA PREMIÈRE CORRECTION ────────────────────────
--
-- Elle était juste sur le fond et sans effet dans les faits, et le garde-fou
-- ne pouvait pas le voir : il éprouve la SÉMANTIQUE, qui n'avait pas changé.
-- Seule une mesure à l'échelle pouvait trancher, et c'est exactement ce que la
-- vérification 6.4 est. Une optimisation qu'aucune mesure n'accompagne est une
-- intention.
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
  with kit as materialized (
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
   * ⚠ `as materialized`, ET C'EST LE MOT QUI FAIT TOUT.
   *
   * Sans lui, PostgreSQL inline ce CTE (il n'est lu qu'une fois) et repousse
   * la corrélation sur `t.id` à l'intérieur — ce qui restaure exactement la
   * sous-requête par sujet candidat que cette forme existe pour supprimer.
   *
   * L'ensemble ne dépend que de la praticienne et de l'horloge. Une fois.
   */
  blocked as materialized (
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
  mine as materialized (
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
  'The next topic for this kit, or NULL when the bank has nothing eligible left. A QUERY: no model call, therefore free and instant -- this is what Swap runs on. The window and the lifetime set are MATERIALIZED CTEs: without that keyword PostgreSQL inlines a once-referenced CTE and pushes the correlation back inside, which is the per-candidate subquery this shape exists to remove. Degradation towards neighbouring segments is a single ranking rather than a ladder of fallbacks, and the sort ends on t.id so that two calls against the same bank state return the same topic.';

revoke all on function public.next_topic_for_kit(uuid, date, text) from public, anon, authenticated;
grant execute on function public.next_topic_for_kit(uuid, date, text) to service_role;


-- ============================================================================
-- Guard rails — la sémantique, encore, et toujours pas la vitesse
-- ============================================================================
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
    (v_u1, 'mat-1@example.invalid'), (v_u2, 'mat-2@example.invalid');
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

  if public.next_topic_for_kit(v_k1, v_month) is distinct from v_t then
    raise exception 'la forme matérialisée ne trouve plus le seul sujet éligible.';
  end if;
  if public.next_topic_for_kit(v_k1, v_month)
     is distinct from public.next_topic_for_kit(v_k1, v_month) then
    raise exception 'la forme matérialisée n''est plus déterministe.';
  end if;

  perform public.assign_topic_to_kit(v_k1, v_month);

  if public.next_topic_for_kit(v_k1, v_month) is not null then
    raise exception 'la forme matérialisée reproposerait un sujet déjà attribué.';
  end if;
  if public.next_topic_for_kit(v_k1, (v_month + interval '5 months')::date) is not null then
    raise exception 'la forme matérialisée reproposerait un sujet dans un autre mois.';
  end if;
  if public.next_topic_for_kit(v_k2, v_month) is not null then
    raise exception 'la forme matérialisée a perdu la fenêtre de 90 jours.';
  end if;

  update public.project_briefs set state = 'FL' where project_id = v_p2;
  if public.next_topic_for_kit(v_k2, v_month) is distinct from v_t then
    raise exception 'la forme matérialisée bloque une praticienne d''un autre État.';
  end if;
  update public.project_briefs set state = 'CA', modality_ids = array[v_mod2]
   where project_id = v_p2;
  if public.next_topic_for_kit(v_k2, v_month) is distinct from v_t then
    raise exception 'la forme matérialisée bloque une praticienne d''une autre modalité.';
  end if;

  delete from public.content_segments where id = v_seg;
  delete from auth.users where id in (v_u1, v_u2);
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore next_topic_for_kit from 20260920170000 (the inlined CTE form,
--   -- which is semantically identical and asymptotically worse).
