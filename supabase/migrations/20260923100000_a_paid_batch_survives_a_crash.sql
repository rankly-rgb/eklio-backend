-- ============================================================================
-- Eklio — un lot déjà payé survit à une panne
-- ============================================================================
--
-- ⚠ MESURÉ, PAS SUPPOSÉ : 0,81 $ D'APPELS DÉJÀ PAYÉS ONT ÉTÉ JETÉS.
--
-- Le 2026-09-23, un remplissage de banque accumulait 695 réponses en mémoire
-- et insérait à la fin. PostgreSQL est tombé au 280ᵉ appel. La banque n'a pas
-- gagné un sujet, et l'argent était dépensé.
--
-- Le même défaut existait dans la génération mensuelle, sous une forme plus
-- chère.
--
-- ── ⚠ UN LOT BATCH EST FACTURÉ À LA SOUMISSION ─────────────────────────
--
-- Entre `batches.create` et la première réponse il se passe vingt-cinq à
-- trente minutes. Dans cette fenêtre l'argent est dépensé et le résultat
-- n'existe nulle part chez nous — et l'identifiant du lot ne vivait que dans
-- une ligne de log. Un processus qui mourait là ne pouvait même pas aller
-- CHERCHER ce qu'il avait payé : il fallait re-soumettre, donc repayer.
--
-- Le harnais local résout ça avec un fichier (`.eklio-journal/`). Vercel n'a
-- pas de système de fichiers qui survive à l'invocation : il faut ces deux
-- tables. Tant qu'elles n'existent pas, **une génération mensuelle
-- interrompue en production est intégralement reperdue et repayée**.
--
-- ── CE QUE CES TABLES NE FONT PAS ───────────────────────────────────────
--
-- Elles ne publient rien. Un mois ne s'écrit dans `content_items` qu'une fois
-- ENTIER et CONTRÔLÉ — le contrôle de mélange ne peut pas juger un mois sur
-- vingt-neuf posts. Elles séparent donc deux choses qui étaient confondues :
-- le TRAVAIL PAYÉ, qui doit survivre à tout, et la PUBLICATION, qui doit
-- rester atomique.
-- ============================================================================


-- ============================================================================
-- Une ligne par (kit, mois) : le lot, son état, quand il a été soumis
-- ============================================================================

create table if not exists public.content_generation_runs (
  id            uuid primary key default gen_random_uuid(),
  brand_kit_id  uuid not null references public.brand_kits(id) on delete cascade,
  month         date not null,
  -- ⚠ L'IDENTIFIANT DU LOT, ÉCRIT AVANT L'ATTENTE. C'est la seule fenêtre où
  -- cette écriture change quelque chose : après, il est trop tard pour aller
  -- rechercher ce qui a été payé.
  batch_id      text,
  state         text not null default 'submitted',
  -- Ce que le mois a coûté jusqu'ici, pour qu'une reprise n'ait pas à le
  -- recalculer depuis des réponses qu'elle n'a plus.
  cost_usd      numeric(10, 5) not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  closed_at     timestamptz,

  constraint content_generation_runs_state_check
    check (state in ('submitted', 'collected', 'published', 'abandoned')),
  -- ⚠ LE PREMIER DU MOIS, COMME PARTOUT AILLEURS DANS CE SCHÉMA.
  constraint content_generation_runs_month_check
    check (month = date_trunc('month', month)::date),
  -- Un kit n'a qu'un mois en cours à la fois : deux lots ouverts sur le même
  -- mois, c'est le mois payé deux fois.
  constraint content_generation_runs_unique unique (brand_kit_id, month)
);

comment on table public.content_generation_runs is
  'One row per (kit, month) generation attempt. `batch_id` is written BEFORE waiting on the batch: a Batch job is billed at submission, and without its id a process that dies during the 25-minute wait cannot even fetch what it paid for. A resume reattaches to this batch; it never creates a second one.';

comment on column public.content_generation_runs.state is
  'submitted -> the batch exists and is billed. collected -> every result is in content_generation_results. published -> the month is in content_items. abandoned -> older than the 29 days Anthropic keeps a batch readable, so it can never be reattached.';

create index if not exists content_generation_runs_open_idx
  on public.content_generation_runs (state, created_at)
  where state in ('submitted', 'collected');


-- ============================================================================
-- Une ligne par sujet : la sortie du modèle, son usage, et si le crédit est soldé
-- ============================================================================

create table if not exists public.content_generation_results (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null references public.content_generation_runs(id) on delete cascade,
  topic_id      uuid not null references public.content_topics(id) on delete cascade,
  -- La sortie du modèle, telle qu'elle a été validée. Null quand la réponse
  -- est arrivée mais n'a pas passé la validation : la ligne existe quand même,
  -- parce que l'appel a été payé et qu'une reprise ne doit pas le refaire.
  result        jsonb,
  usage         jsonb not null default '{}'::jsonb,
  /*
   * ⚠ SANS CE DRAPEAU, UNE REPRISE FACTURE DEUX FOIS. Le premier passage a
   * réservé puis soldé un crédit pour ce sujet ; le second, reprenant le même
   * résultat, en consommerait un autre pour un post déjà payé.
   */
  settled       boolean not null default false,
  created_at    timestamptz not null default now(),

  constraint content_generation_results_unique unique (run_id, topic_id)
);

comment on table public.content_generation_results is
  'One row per topic, written AS EACH RESULT ARRIVES -- never after the whole stream is in memory. A crash then costs at most the response in flight. `settled` says the credit has already been charged for this topic, so a resume does not charge a second one.';

create index if not exists content_generation_results_run_idx
  on public.content_generation_results (run_id);


-- ============================================================================
-- Ni l'une ni l'autre ne se lit depuis un navigateur
-- ============================================================================
-- ⚠ AUCUNE POLICY OUVERTE, ET LE GRANT RÉVOQUÉ EN PLUS. Ces deux tables
-- portent des réponses de modèle non encore contrôlées et l'état d'un crédit.
-- Une cliente qui pourrait y écrire pourrait marquer `settled` sur un sujet
-- qu'elle n'a pas payé.
--
-- Le dépôt révoque explicitement sur ses tables internes — `stripe_events`,
-- `banned_phrases`, `comp_grants`, `on_demand_writes` — parce que
-- `enable row level security` plus une policy qui refuse laisse le GRANT de
-- table en place : `has_table_privilege` répondrait encore vrai, et seul le
-- second verrou se lit dans un audit de privilèges.

alter table public.content_generation_runs enable row level security;
drop policy if exists content_generation_runs_no_browser on public.content_generation_runs;
create policy content_generation_runs_no_browser on public.content_generation_runs
  for all to authenticated, anon using (false) with check (false);
revoke all on table public.content_generation_runs from anon, authenticated;

alter table public.content_generation_results enable row level security;
drop policy if exists content_generation_results_no_browser on public.content_generation_results;
create policy content_generation_results_no_browser on public.content_generation_results
  for all to authenticated, anon using (false) with check (false);
revoke all on table public.content_generation_results from anon, authenticated;


-- ============================================================================
-- Un lot plus vieux que ce qu'Anthropic garde n'est plus rattachable
-- ============================================================================
-- ⚠ VINGT-NEUF JOURS, ET C'EST UNE CONTRAINTE EXTERNE. Passé ce délai, les
-- résultats d'un lot ne sont plus lisibles : une ligne `submitted` plus
-- ancienne ne peut plus être reprise, et la laisser ouverte ferait croire à
-- une reprise possible. Elle est close explicitement, jamais supprimée — ce
-- qu'elle a coûté reste lisible.

create or replace function public.abandon_stale_generation_runs()
returns integer
language sql
security definer
set search_path to ''
as $$
  with closed as (
    update public.content_generation_runs
       set state = 'abandoned',
           closed_at = now(),
           updated_at = now()
     where state in ('submitted', 'collected')
       and created_at < now() - interval '29 days'
    returning 1
  )
  select count(*)::integer from closed;
$$;

comment on function public.abandon_stale_generation_runs() is
  'Closes runs whose batch Anthropic no longer keeps readable (29 days). They are marked abandoned, never deleted: what they cost stays legible.';

revoke all on function public.abandon_stale_generation_runs() from public, anon;
grant execute on function public.abandon_stale_generation_runs() to service_role;
