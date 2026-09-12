-- ============================================================================
-- The charter rulings — the columns the decisions bought, and the guard
-- ============================================================================
-- Rulings of 2026-09-12 on the three questions raised by 20260912144121, plus
-- a fourth nobody had asked. Written up in frontend `TENANCY.md` §12.
--
-- ── DECISION 1, REFINED: THE VOICE GUIDE SPLITS, AND THE SEAM ALREADY EXISTS ─
--
-- The ruling: inherit the prohibitions, never the personality. If a whole voice
-- guide inherits, eight clinicians write identically — false, and bad product,
-- because in private practice the person is what a patient chooses.
--
-- ⚠ NO COLUMN IS SPLIT HERE, because `voice_guide` is ALREADY two things:
--
--   { sounds_like: [3 strings],  never_write: [3 strings] }
--
-- `never_write` is the claims discipline — what the practice will never say.
-- `sounds_like` is how she sounds. The inheritance boundary falls exactly on
-- the existing key boundary, so the rule is split across the column rather than
-- the column across two.
--
-- That seam is not invented to avoid a migration: `lib/generation/pipeline.ts`
-- already treats the two keys as different KINDS of thing for an unrelated
-- reason — `never_write` is deliberately exempt from the ethics check, because
-- those lines NAME the fault to avoid and checking them would fail the
-- generation on its own pedagogy, while `sounds_like` goes through it as
-- publishable prose. Two independent readings landing on the same seam is
-- evidence the seam is real.
--
-- ── DECISION 2: STORE THE ACCEPTED STATE, NOT A BOOLEAN ──────────────────────
--
-- "The charter moved" is the dot people learn to dismiss. She has to see WHAT
-- changed, which means the state she accepted must still be here to diff
-- against. Hence `charter_accepted_state`, not `charter_is_stale`.
--
-- ── DECISION 4: WHAT HAPPENS WHEN A CLINICIAN LEAVES ─────────────────────────
--
-- `organization_members.status = 'removed'` existed and meant nothing for her
-- kit. Ruling: ON REMOVAL THE DERIVED KIT DETACHES AND KEEPS ITS CURRENT
-- RENDERED STATE. She keeps what exists, the link breaks, nothing inherits
-- after.
--
-- The reasoning is the same standing law as Decision 2: Eklio never hosts,
-- publishes, deploys or shares. Her files are already downloaded and on her
-- site. Revoking them inside the app achieves nothing except pretending — and
-- Eklio has no standing to adjudicate who owns a practice's palette.
--
-- ⚠ THE COLUMNS ONLY. No departure flow, no trigger on membership status. The
-- behaviour is defined while it is still a column; the flow is not this commit.
--
-- ── AND THE GUARD, SHIPPED NOW RATHER THAN WITH THE PROPAGATION ─────────────
--
-- I proposed deferring it. That was overruled, correctly: an inert wrong value
-- becomes a live wrong value the moment something reads it, and nobody
-- re-derives the guard at that moment. It costs a line today and is forgotten
-- in November.
--
-- It does NOT concede to `caller_is_the_database()`. That concession is right
-- for an AUTHORITY gate — a migration outranks a policy. This is a DATA
-- INTEGRITY invariant, and a backfill that points a kit at another practice's
-- charter is exactly as wrong as a browser doing it.
-- ============================================================================

-- ── Decision 1: the ruling recorded where the column lives ──────────────────
comment on column public.brand_kits.voice_guide is
  'Two arrays of exactly three strings: `sounds_like` and `never_write` (`brand_kit_voice_guide_valid`). ⚠ THESE INHERIT DIFFERENTLY. `never_write` is the practice''s claims discipline and INHERITS from the charter; `sounds_like` is how this clinician sounds and NEVER inherits — eight clinicians who write identically is both false and bad product. Ruling of 2026-09-12, TENANCY.md §12.';

-- ── Decision 2: the accepted state, so a diff can be shown ──────────────────
alter table public.brand_kits
  add column if not exists charter_accepted_state jsonb,
  add column if not exists charter_accepted_at timestamptz;

comment on column public.brand_kits.charter_accepted_state is
  'The inherited slice of the charter AS THIS KIT LAST ACCEPTED IT, kept so that a later charter change can be shown as a difference rather than announced as a dot. Deliberately not a boolean: "the charter moved" is the notification people learn to dismiss, and "here is what changed" is a decision someone can make in ten seconds. NULL on a kit that has never accepted a charter state.';

comment on column public.brand_kits.charter_accepted_at is
  'When `charter_accepted_state` was accepted. Set and cleared with it.';

alter table public.brand_kits
  drop constraint if exists brand_kits_charter_accepted_is_object;
alter table public.brand_kits
  add constraint brand_kits_charter_accepted_is_object
  check (charter_accepted_state is null
         or jsonb_typeof(charter_accepted_state) = 'object');

alter table public.brand_kits
  drop constraint if exists brand_kits_charter_accepted_pair;
alter table public.brand_kits
  add constraint brand_kits_charter_accepted_pair
  check ((charter_accepted_state is null) = (charter_accepted_at is null));

-- ── Decision 4: departure, as columns and nothing more ──────────────────────
alter table public.brand_kits
  add column if not exists detached_from_charter_kit_id uuid
    references public.brand_kits(id) on delete set null,
  add column if not exists detached_at timestamptz;

comment on column public.brand_kits.detached_from_charter_kit_id is
  'The charter this kit was detached from when its clinician left the practice. The link breaks and nothing inherits after; she keeps the rendered state she had, because her files are already on her own site and revoking them in the app would only pretend. Kept as history rather than erased, so "this kit once belonged to that practice" remains answerable. NULL on a kit that never left one.';

comment on column public.brand_kits.detached_at is
  'When this kit detached from a charter. Set and cleared with `detached_from_charter_kit_id`.';

alter table public.brand_kits
  drop constraint if exists brand_kits_detached_pair;
alter table public.brand_kits
  add constraint brand_kits_detached_pair
  check ((detached_from_charter_kit_id is null) = (detached_at is null));

-- A kit cannot be detached from the charter it currently derives from: those
-- two statements contradict each other, and the contradiction is silent.
alter table public.brand_kits
  drop constraint if exists brand_kits_not_detached_from_current_charter;
alter table public.brand_kits
  add constraint brand_kits_not_detached_from_current_charter
  check (derived_from_charter_kit_id is null
         or detached_from_charter_kit_id is null
         or detached_from_charter_kit_id <> derived_from_charter_kit_id);

create index if not exists brand_kits_detached_from_charter_kit_id_idx
  on public.brand_kits (detached_from_charter_kit_id)
  where detached_from_charter_kit_id is not null;

-- ── The guard ──────────────────────────────────────────────────────────────
-- A kit may only derive from the charter of its OWN practice, reached the only
-- way it can be reached: brand_kits -> projects -> organizations.
--
-- SECURITY DEFINER so the verdict does not depend on which rows the writer can
-- see. Under RLS an invisible organization row would make the lookup return
-- NULL, and this fails closed on NULL — so the effect without DEFINER would be
-- to reject legitimate writes, not to admit illegitimate ones. DEFINER makes it
-- deterministic instead of merely safe-by-accident.
--
-- A charter kit can never itself derive: its own practice's charter is itself,
-- and `brand_kits_charter_is_not_itself` already refuses that.
create or replace function public.brand_kit_charter_is_own_practice()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_org_charter uuid;
begin
  if new.derived_from_charter_kit_id is null then
    return new;
  end if;

  select o.brand_charter_kit_id
    into v_org_charter
    from public.projects p
    join public.organizations o on o.id = p.organization_id
   where p.id = new.project_id;

  if v_org_charter is null
     or v_org_charter <> new.derived_from_charter_kit_id then
    raise exception
      'brand_kits.derived_from_charter_kit_id must be this practice''s own charter (kit %, project %, given %, practice charter %)',
      new.id, new.project_id, new.derived_from_charter_kit_id, v_org_charter
      using errcode = 'check_violation';
  end if;

  return new;
end;
$function$;

revoke execute on function public.brand_kit_charter_is_own_practice()
  from public, anon, authenticated;

drop trigger if exists brand_kits_charter_is_own_practice on public.brand_kits;
create trigger brand_kits_charter_is_own_practice
  before insert or update of derived_from_charter_kit_id, project_id
  on public.brand_kits
  for each row
  execute function public.brand_kit_charter_is_own_practice();
