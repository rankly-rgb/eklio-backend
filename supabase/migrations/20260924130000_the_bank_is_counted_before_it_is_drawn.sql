-- ============================================================================
-- Eklio — compter la banque avec la requête qui la tire
-- ============================================================================
--
-- ⚠ LE QUATRIÈME ESSAI DU 2026-09-23 N'A TIRÉ QUE 18 CANDIDATS SUR 54.
--
-- La banque portait 88 sujets libres — assez, en apparence. Mais `cycle` et
-- `numbered_strategies` n'en avaient que cinq chacun, et un mois ne se compose
-- pas avec ça. Le total mentait, et il a menti au moment exact où il fallait
-- décider de remplir.
--
-- ── ⚠ ET LA SURVEILLANCE NE POSAIT PAS LA MÊME QUESTION QUE LE TIRAGE ────
--
-- La requête de surveillance de F13 compte les sujets « non assignés ». Le
-- tirage, lui, écarte en plus : ce que CE kit a déjà pris, ce qu'une consœur
-- du même État et de la même modalité a pris dans les 90 jours, les sujets
-- non relus sur le plan éthique, les expirés, et ceux dont le segment ne
-- correspond ni à la modalité ni au persona de la praticienne.
--
-- Deux questions différentes, dont une seule décide si le mois sort. La
-- surveillance rassurait donc sur un stock que le tirage ne voyait pas.
--
-- ⚠ UNE SEULE DÉFINITION, PAS DEUX. `next_topic_for_kit` devient un `limit 1`
-- posé sur la liste, et le compteur groupe la MÊME liste par archétype. Deux
-- requêtes tenues à la main auraient divergé au premier filtre ajouté — et
-- c'est la divergence qui a coûté l'essai.
-- ============================================================================

create or replace function public.drawable_topics_for_kit(
  p_brand_kit_id uuid,
  p_archetype text default null
)
returns table (topic_id uuid, archetype_key text)
language sql
stable
security definer
set search_path to ''
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
   * ⚠ `as materialized`, ET C'EST LE MOT QUI FAIT TOUT. Sans lui, PostgreSQL
   * inline le CTE et repousse la corrélation sur `t.id` à l'intérieur, ce qui
   * restaure la sous-requête par sujet candidat que cette forme supprime.
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
  select t.id, t.archetype_key
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
$$;

comment on function public.drawable_topics_for_kit(uuid, text) is
  'Every topic this kit could draw right now, in the order the draw would take them. next_topic_for_kit is a limit 1 over this list, and the per-archetype count that decides whether to refill is a group by over the same list -- so the monitoring query and the draw can never answer differently, which is exactly what cost the fourth attempt of 2026-09-23: 88 free topics in total, five in the two archetypes that mattered.';

/*
 * ⚠ LE TIRAGE DEVIENT UN `limit 1` SUR LA LISTE. Il garde le même contrat —
 * un uuid ou null — et perd sa copie des filtres.
 */
create or replace function public.next_topic_for_kit(
  p_brand_kit_id uuid,
  p_month date,
  p_archetype text default null
)
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select d.topic_id
    from public.drawable_topics_for_kit(p_brand_kit_id, p_archetype) d
   limit 1
$$;

/*
 * Le compteur par archétype : la même liste, groupée.
 *
 * ⚠ IL REND AUSSI LES ARCHÉTYPES À ZÉRO. Un archétype absent du résultat se
 * lit « pas de ligne », et une ligne manquante ne se compare à aucun seuil —
 * c'est le cas qui fait sortir un mois court.
 */
create or replace function public.drawable_count_for_kit(p_brand_kit_id uuid)
returns table (archetype_key text, drawable bigint)
language sql
stable
security definer
set search_path to ''
as $$
  select k.archetype_key,
         count(d.topic_id) as drawable
    from (select distinct archetype_key from public.content_topics) k
    left join public.drawable_topics_for_kit(p_brand_kit_id) d
           on d.archetype_key = k.archetype_key
   group by k.archetype_key
   order by drawable asc, k.archetype_key
$$;

revoke all on function public.drawable_topics_for_kit(uuid, text) from public;
revoke all on function public.drawable_count_for_kit(uuid) from public;
grant execute on function public.drawable_topics_for_kit(uuid, text) to authenticated, service_role;
grant execute on function public.drawable_count_for_kit(uuid) to authenticated, service_role;

/*
 * ── ⚠ LA PREUVE QUE LES DEUX RÉPONSES SONT LA MÊME ──────────────────────
 *
 * Sans elle, ce fichier n'aurait affirmé la non-divergence que par sa mise en
 * page. Sur chaque kit qui porte un brief, le tirage doit rendre exactement la
 * tête de la liste, et le compteur exactement sa longueur.
 */
do $$
declare
  v_kit uuid;
  v_next uuid;
  v_head uuid;
  v_counted bigint;
  v_listed bigint;
begin
  for v_kit in
    select bk.id from public.brand_kits bk
      join public.projects pr on pr.id = bk.project_id
      join public.project_briefs pb on pb.project_id = pr.id
     limit 25
  loop
    select public.next_topic_for_kit(v_kit, date_trunc('month', now())::date) into v_next;
    select d.topic_id into v_head
      from public.drawable_topics_for_kit(v_kit) d limit 1;
    if v_next is distinct from v_head then
      raise exception 'le tirage et la liste divergent sur le kit %: % vs %', v_kit, v_next, v_head;
    end if;

    select coalesce(sum(drawable), 0) into v_counted
      from public.drawable_count_for_kit(v_kit);
    select count(*) into v_listed from public.drawable_topics_for_kit(v_kit);
    if v_counted <> v_listed then
      raise exception 'le compteur et la liste divergent sur le kit %: % vs %', v_kit, v_counted, v_listed;
    end if;
  end loop;
end $$;
