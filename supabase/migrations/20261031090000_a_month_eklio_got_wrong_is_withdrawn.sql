-- ============================================================================
-- F81 — UN MOIS QU'EKLIO A MAL PRODUIT SE RETIRE, ET SES CRÉDITS LUI SONT RENDUS
-- ============================================================================
--
-- ⚠ TROUVÉ EN VOULANT RÉGÉNÉRER NOVEMBRE 2026 (kit 45de0dac).
--
-- Novembre est sorti à 24 posts au lieu de 30 : une mise en page nulle un post
-- sur deux (« educate » pris pour un registre), 28 écritures refusées par la
-- base. La décision est de le régénérer. Or rien ne le permettait :
--
--   * ses 24 réservations `post_generation` sont RÉGLÉES. `settle_credit` ne
--     libère qu'une réservation sans issue, et le livre est en ajout seul —
--     aucun mouvement ne rend un crédit réglé. Le quota de novembre ne garde
--     que 6 crédits sur 30 ; le préalable refuserait un mois de 30 ;
--   * le mois est `proposed` : servi, jamais resservi ;
--   * son run est `published` : il occupe l'unique run ouvert du mois.
--
-- ── CE QUI EST AJOUTÉ, ET RIEN D'AUTRE ─────────────────────────────────
--
-- 1. Un quatrième mouvement de livre, `refund` : l'AVOIR d'une réservation
--    réglée, quand le travail payé est retiré par Eklio. Une réservation, une
--    issue (règlement ou libération), et au plus un avoir. `credit_ledger_apply`
--    le traite déjà : tout mouvement qui n'est pas une réservation fait bouger
--    `consumed` de `-delta`, sans toucher au plafond.
--
-- 2. `withdraw_content_month(p_month_id, p_reason)`, service_role SEULEMENT.
--    Il refuse un mois qu'elle a touché — un post validé, modifié hors
--    `proposed`, publié, ou écrit par elle — et ne retire qu'un mois `proposed`
--    entièrement produit par Eklio. Il supprime ses posts, rend leurs sujets à
--    la banque, pose un avoir par post retiré, passe le mois en `failed` (le
--    cron le reprend : `failed` est dû) et abandonne son run (F71 : sa dépense
--    reste comptée par le plafond, il ne se reprend pas).
--
-- ⚠ CE N'EST PAS UN GESTE CLIENT. Aucun écran ne l'appelle, et `authenticated`
-- ne peut pas l'exécuter : retirer un mois et rendre des crédits est une
-- décision d'Eklio sur un travail d'Eklio.
-- ============================================================================

-- ── 1. le mouvement `refund` ────────────────────────────────────────────────
alter table public.credit_ledger drop constraint if exists credit_ledger_entry_type_check;
alter table public.credit_ledger add constraint credit_ledger_entry_type_check
  check (entry_type in ('reservation', 'settlement', 'release', 'refund'));

-- Un avoir rend exactement ce que la réservation a pris, ne porte pas de coût,
-- et nomme sa réservation.
alter table public.credit_ledger drop constraint if exists credit_ledger_refund_shape;
alter table public.credit_ledger add constraint credit_ledger_refund_shape
  check (entry_type <> 'refund'
         or (reservation_id is not null and delta > 0 and actual_cost_usd is null));

-- Au plus un avoir par réservation.
create unique index if not exists credit_ledger_one_refund_per_reservation
  on public.credit_ledger (reservation_id) where entry_type = 'refund';

comment on constraint credit_ledger_refund_shape on public.credit_ledger is
  'refund: the credit note of a SETTLED reservation whose work Eklio withdrew (withdraw_content_month). Gives back exactly what the reservation took; at most one per reservation.';

-- L'audit du mois compte les avoirs à part : un crédit rendu ne se confond ni
-- avec une libération (pas d'issue) ni avec un règlement.
create or replace view public.credit_month_audit as
select user_id,
       month,
       kind,
       count(*) filter (where entry_type = 'reservation') as reservations,
       count(*) filter (where entry_type = 'settlement')  as settlements,
       count(*) filter (where entry_type = 'release')     as releases,
       sum(coalesce(actual_cost_usd, estimated_cost_usd, 0))::numeric(12,5) as cost_usd,
       count(*) filter (where entry_type = 'refund')      as refunds
  from public.credit_ledger l
 group by user_id, month, kind;

-- ── 2. withdraw_content_month ──────────────────────────────────────────────
create or replace function public.withdraw_content_month(
  p_month_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  m            public.content_months%rowtype;
  v_user       uuid;
  v_topics     uuid[];
  v_items      int;
  v_released   int;
  v_refunded   int := 0;
  v_abandoned  int;
  r            record;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'withdraw_content_month: a reason is required' using errcode = '22023';
  end if;

  select * into m from public.content_months where id = p_month_id for update;
  if not found then
    raise exception 'withdraw_content_month: no such month' using errcode = 'P0002';
  end if;
  if m.status <> 'proposed' then
    raise exception 'withdraw_content_month: month is %, only a proposed month is withdrawn', m.status
      using errcode = '55000';
  end if;

  -- ⚠ SON TRAVAIL N'EST JAMAIS RETIRÉ. Un post validé, publié, écrit par elle
  -- (sans sujet de banque) ou demandé à l'unité arrête tout.
  if exists (
    select 1 from public.content_items i
     where i.month_id = m.id
       and (i.status <> 'proposed' or i.topic_id is null)
  ) or exists (
    select 1 from public.content_publications p
      join public.content_items i on i.id = p.content_item_id
     where i.month_id = m.id
  ) or exists (
    select 1 from public.on_demand_writes w
      join public.content_items i on i.id = w.content_item_id
     where i.month_id = m.id
  ) then
    raise exception 'withdraw_content_month: the practitioner has acted on this month; nothing was withdrawn'
      using errcode = '55000';
  end if;

  select p.user_id into v_user
    from public.brand_kits k join public.projects p on p.id = k.project_id
   where k.id = m.brand_kit_id;

  select coalesce(array_agg(i.topic_id), '{}'), count(*)
    into v_topics, v_items
    from public.content_items i where i.month_id = m.id;

  delete from public.content_items where month_id = m.id;

  -- Les sujets reviennent à la banque : l'absence de ligne EST la disponibilité.
  delete from public.topic_assignments
   where brand_kit_id = m.brand_kit_id and topic_id = any (v_topics);
  get diagnostics v_released = row_count;

  -- Un avoir par post retiré, sur les réservations RÉGLÉES de ce mois prises par
  -- la génération (« month YYYY-MM-01: … »), les plus récentes d'abord.
  for r in
    select l.id, l.delta, l.kind, l.reason
      from public.credit_ledger l
     where l.user_id = v_user
       and l.kind = 'post_generation'
       and l.month = m.month
       and l.entry_type = 'reservation'
       and l.reason like 'month ' || to_char(m.month, 'YYYY-MM-DD') || ':%'
       and exists (select 1 from public.credit_ledger s
                    where s.reservation_id = l.id and s.entry_type = 'settlement')
       and not exists (select 1 from public.credit_ledger f
                        where f.reservation_id = l.id and f.entry_type = 'refund')
     order by l.created_at desc, l.id
     limit v_items
  loop
    insert into public.credit_ledger
      (user_id, kind, entry_type, delta, reason, reservation_id, month)
    values
      (v_user, r.kind, 'refund', -r.delta, 'refunded: ' || btrim(p_reason) || ' — ' || r.reason, r.id, m.month);
    v_refunded := v_refunded + 1;
  end loop;

  update public.content_months set status = 'failed', updated_at = now() where id = m.id;

  update public.content_generation_runs
     set state = 'abandoned', updated_at = now()
   where brand_kit_id = m.brand_kit_id and month = m.month and state <> 'abandoned';
  get diagnostics v_abandoned = row_count;

  return jsonb_build_object(
    'month_id', m.id,
    'withdrawn', v_items,
    'topics_released', v_released,
    'credits_refunded', v_refunded,
    'runs_abandoned', v_abandoned
  );
end
$$;

comment on function public.withdraw_content_month(uuid, text) is
  'Withdraws a proposed month Eklio produced badly: deletes its posts, returns their topics to the bank, refunds one settled post_generation credit per post, marks the month failed (the cron serves it again) and abandons its run. Refuses a month she acted on. service_role only.';

revoke all on function public.withdraw_content_month(uuid, text) from public, anon, authenticated;
grant execute on function public.withdraw_content_month(uuid, text) to service_role;

-- ============================================================================
-- Rollback
-- ============================================================================
--   drop function if exists public.withdraw_content_month(uuid, text);
--   (un avoir posé ne se retire pas : le livre est en ajout seul)
--   create or replace view public.credit_month_audit as … (sans `refunds`)
--   drop index if exists public.credit_ledger_one_refund_per_reservation;
--   alter table public.credit_ledger drop constraint credit_ledger_refund_shape;
--   alter table public.credit_ledger drop constraint credit_ledger_entry_type_check;
--   alter table public.credit_ledger add constraint credit_ledger_entry_type_check
--     check (entry_type in ('reservation', 'settlement', 'release'));
