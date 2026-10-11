-- ============================================================================
-- F71 — UN MOIS REFUSÉ NE SE REPREND PAS, ET UNE REPRISE RÉAFFIRME SES SUJETS
-- ============================================================================
--
-- Trouvé le 2026-10-04 sur le mois de novembre local. Sur un refus (plafond,
-- composition, assemblage), l'orchestrateur rendait les sujets tirés et fermait
-- la ligne du mois en `failed`, mais le run restait `collected` : reprenable. Une
-- reprise relisait ses sujets au journal et PUBLIAIT des posts dont les sujets ne
-- lui étaient plus assignés. L'exclusivité de 90 jours ne tient que par
-- `topic_assignments` : ces sujets redevenaient tirables par une collègue du même
-- segment, et par ce kit le mois suivant.
--
-- ⚠ LA MÊME PORTE S'OUVRE SANS REFUS. `release_stale_topic_assignments()` rend,
-- au bout de trois heures, les assignations qui n'ont rien livré : un mois tué
-- puis repris le lendemain avait le même défaut.
--
-- Tranché : un mois refusé n'est PAS reprenable (son run passe `abandoned` au
-- moment où ses sujets sont rendus), et une reprise ne repart qu'avec des sujets
-- qu'elle détient encore, réaffirmés. Sinon elle abandonne le run et le mois
-- repart d'un tirage neuf. Ce qui a été payé reste compté par le plafond.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Un seul run OUVERT par kit et par mois, et plus « un seul run à vie »
-- ---------------------------------------------------------------------------
/*
 * ⚠ L'ANCIENNE UNICITÉ BLOQUAIT LE MOIS APRÈS UN ABANDON. `(brand_kit_id,
 * month)` sans condition faisait qu'un run `abandoned` — refusé, ou périmé par
 * `abandon_stale_generation_runs()` — interdisait tout nouveau run pour ce mois :
 * `openRun` relisait la ligne abandonnée et le mois repartait dessus. Les runs
 * abandonnés restent en base : leur `cost_usd` est la trace de ce qui a été payé.
 */
alter table public.content_generation_runs
  drop constraint if exists content_generation_runs_unique;

create unique index if not exists content_generation_runs_open_unique
  on public.content_generation_runs (brand_kit_id, month)
  where state <> 'abandoned';

comment on index public.content_generation_runs_open_unique is
  'At most one run per (kit, month) that is not abandoned. Abandoned runs stay as the record of what was spent; a new attempt opens a fresh run. (20261011090000, F71)';

-- ---------------------------------------------------------------------------
-- 2. Réaffirmer les sujets d'une reprise
-- ---------------------------------------------------------------------------
/*
 * Rend les sujets de la liste que CE kit détient encore, et repousse leur
 * `assigned_at` à maintenant : une reprise qui dure ne se fait pas retirer ses
 * sujets par le balai des trois heures pendant qu'elle rédige.
 *
 * ⚠ ELLE NE RÉASSIGNE RIEN. Un sujet rendu (ligne supprimée par le refus ou par
 * le balai) ou tenu hors délai sans rien livrer n'est pas rendu : il a pu être
 * tiré par une collègue entre-temps, et l'exclusivité ne se reprend pas.
 */
create or replace function public.reassert_topic_assignments(
  p_brand_kit_id uuid,
  p_topic_ids uuid[]
)
returns uuid[]
language sql
volatile
security definer
set search_path to ''
as $$
  with held as (
    update public.topic_assignments ta
       set assigned_at = now()
     where ta.brand_kit_id = p_brand_kit_id
       and ta.topic_id = any (p_topic_ids)
       and public.topic_assignment_holds(ta.brand_kit_id, ta.topic_id, ta.assigned_at)
    returning ta.topic_id
  )
  select coalesce(array_agg(topic_id), '{}'::uuid[]) from held
$$;

comment on function public.reassert_topic_assignments(uuid, uuid[]) is
  'Returns the topics of the list this kit still holds, and refreshes their assigned_at so a long resume is not swept. A released or lapsed topic is NOT re-taken. (20261011090000, F71)';

revoke all on function public.reassert_topic_assignments(uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.reassert_topic_assignments(uuid, uuid[]) to service_role;
