-- ============================================================================
-- Eklio — une assignation qui n'a rien livré ne retient rien
-- ============================================================================
--
-- ⚠ NEUF CENT QUINZE SUJETS ÉTAIENT ASSIGNÉS À DES KITS SANS UN SEUL POST.
--
-- Mesuré le 2026-09-24 : vingt-quatre kits orphelins sur 2026-11 retenaient
-- 858 sujets, plus 57 sur 2026-10. Le résidu de toutes les exécutions
-- interrompues — un run tué, un lot en erreur, une session coupée — et la
-- fenêtre anti-collision les retirait à TOUT LE SEGMENT pendant quatre-vingt-
-- dix jours, pour des posts que personne n'a jamais écrits.
--
-- ⚠ ET ON S'APPRÊTAIT À RACHETER CE QU'ON POSSÉDAIT DÉJÀ. Le dimensionnement
-- de F13 compte ce qu'un essai CONSOMME et suppose que le reste revient. Ça ne
-- revient que si quelqu'un le rend. En production, le stock s'érode à chaque
-- incident et la facture de banque grossit sans qu'aucun sujet n'ait servi.
--
-- ── DEUX VERROUS, PARCE QU'UN SEUL NE SUFFIT PAS ────────────────────────
--
-- 1. LE TIRAGE CESSE DE LES VOIR. Une assignation sans `content_item` et plus
--    vieille que le délai de grâce ne bloque plus personne — même si
--    personne ne l'a effacée. C'est le verrou qui tient tout seul.
-- 2. UN BALAI LES EFFACE. `release_stale_topic_assignments()` les supprime, et
--    la génération l'appelle avant de tirer. C'est le verrou qui garde la
--    table propre et qui rend le nombre visible.
--
-- ⚠ LE DÉLAI DE GRÂCE DOIT ÊTRE PLUS LONG QU'UNE GÉNÉRATION. Un lot met
-- vingt-cinq à trente minutes ; le harnais abandonne à quatre-vingt-dix. Trois
-- heures laissent une génération légitime finir sans se faire voler ses
-- sujets, et rendent un incident au tour suivant plutôt qu'au trimestre
-- suivant.
-- ============================================================================

create or replace function public.topic_assignment_grace()
returns interval
language sql
immutable
set search_path to ''
as $$
  select interval '3 hours'
$$;

comment on function public.topic_assignment_grace() is
  'How long an assignment may hold a topic without a content_item behind it. It must exceed a whole generation -- a batch takes 25 to 30 minutes and the harness gives up at 90 -- so a legitimate run in flight is never robbed of the topics it is writing. Past it, the assignment delivered nothing and stops blocking the segment.';

/*
 * ⚠ CE QU'UNE ASSIGNATION RETIENT VRAIMENT.
 *
 * Elle retient si elle a produit un post, OU si elle est encore dans son délai
 * de grâce — c'est-à-dire si une génération est peut-être en train de l'écrire.
 * Tout le reste est un résidu.
 */
create or replace function public.topic_assignment_holds(
  p_brand_kit_id uuid,
  p_topic_id uuid,
  p_assigned_at timestamptz
)
returns boolean
language sql
stable
set search_path to ''
as $$
  select p_assigned_at > now() - public.topic_assignment_grace()
      or exists (
        select 1 from public.content_items ci
         where ci.topic_id = p_topic_id
           and ci.brand_kit_id = p_brand_kit_id
      )
$$;

/*
 * ⚠ LE BALAI. Il rend le nombre visible : sans lui, la banque « se répare »
 * en silence et personne n'apprend qu'un run a été tué.
 */
create or replace function public.release_stale_topic_assignments()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_released integer;
begin
  with gone as (
    delete from public.topic_assignments ta
     where not public.topic_assignment_holds(ta.brand_kit_id, ta.topic_id, ta.assigned_at)
    returning 1
  )
  select count(*) into v_released from gone;
  return v_released;
end;
$$;

comment on function public.release_stale_topic_assignments() is
  'Deletes every assignment that delivered no content_item and is past the grace period, and returns how many. Generation calls it before drawing. 915 topics were held this way on 2026-09-24 by twenty-six kits with no posts at all -- the residue of killed runs and errored batches -- and the collision window withheld them from the whole segment for ninety days.';

revoke all on function public.release_stale_topic_assignments() from public;
grant execute on function public.release_stale_topic_assignments() to authenticated, service_role;

/*
 * ── ⚠ ET LE TIRAGE CESSE DE LES VOIR, BALAI OU PAS ──────────────────────
 *
 * `drawable_topics_for_kit` est la source unique : `next_topic_for_kit` en est
 * un `limit 1`, `drawable_count_for_kit` un `group by`. Le filtre posé ici
 * vaut donc pour les trois d'un coup.
 */
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
   * inline le CTE et repousse la corrélation sur `t.id` à l'intérieur.
   */
  blocked as materialized (
    select distinct ta.topic_id
      from public.topic_assignments ta
      join public.brand_kits   obk on obk.id = ta.brand_kit_id
      join public.projects     opr on opr.id = obk.project_id
      left join public.project_briefs opb on opb.project_id = opr.id
     cross join kit k
     where ta.assigned_at > now() - public.topic_collision_window()
       -- ⚠ Une consœur qui n'a rien livré ne vous retire rien.
       and public.topic_assignment_holds(ta.brand_kit_id, ta.topic_id, ta.assigned_at)
       and opr.user_id is distinct from k.user_id
       and k.state_code is not null
       and upper(nullif(btrim(coalesce(opb.state, '')), '')) = k.state_code
       and coalesce(opb.modality_ids, '{}') && k.modalities
  ),
  mine as materialized (
    select ta.topic_id from public.topic_assignments ta
     where ta.brand_kit_id = p_brand_kit_id
       -- ⚠ Et un essai tué ne se prive pas lui-même de ses propres sujets.
       and public.topic_assignment_holds(ta.brand_kit_id, ta.topic_id, ta.assigned_at)
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

/*
 * ── ⚠ LA PREUVE, SUR DES DONNÉES FABRIQUÉES ET DÉFAITES ────────────────
 *
 * Sans elle, ce fichier n'affirmerait la libération que par sa mise en page.
 */
do $$
declare
  v_kit uuid;
  v_topic uuid;
  v_before bigint;
  v_after bigint;
  v_released integer;
begin
  select bk.id into v_kit
    from public.brand_kits bk
    join public.projects pr on pr.id = bk.project_id
    join public.project_briefs pb on pb.project_id = pr.id
   limit 1;
  if v_kit is null then return; end if;

  select d.topic_id into v_topic from public.drawable_topics_for_kit(v_kit) d limit 1;
  if v_topic is null then return; end if;

  select count(*) into v_before from public.drawable_topics_for_kit(v_kit);

  -- Une assignation fraîche retient : une génération en vol garde ses sujets.
  insert into public.topic_assignments (brand_kit_id, topic_id, month, assigned_at)
  values (v_kit, v_topic, date_trunc('month', now())::date, now());
  select count(*) into v_after from public.drawable_topics_for_kit(v_kit);
  if v_after <> v_before - 1 then
    raise exception 'une assignation fraîche devrait retenir: % puis %', v_before, v_after;
  end if;

  -- La même, vieillie et sans post, ne retient plus rien.
  update public.topic_assignments
     set assigned_at = now() - public.topic_assignment_grace() - interval '1 minute'
   where brand_kit_id = v_kit and topic_id = v_topic;
  select count(*) into v_after from public.drawable_topics_for_kit(v_kit);
  if v_after <> v_before then
    raise exception 'une assignation périmée et vide devrait libérer: % puis %', v_before, v_after;
  end if;

  -- Et le balai l'efface.
  select public.release_stale_topic_assignments() into v_released;
  if v_released < 1 then
    raise exception 'le balai n''a rien libéré alors qu''une assignation périmée existait';
  end if;
  if exists (select 1 from public.topic_assignments where brand_kit_id = v_kit and topic_id = v_topic) then
    raise exception 'le balai a laissé l''assignation périmée en place';
  end if;
end $$;
