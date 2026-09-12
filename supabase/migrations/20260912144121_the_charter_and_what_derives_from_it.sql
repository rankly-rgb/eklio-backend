-- ============================================================================
-- brand_charter_kit_id — the practice's brand, and the kits that derive from it
-- ============================================================================
-- COLUMNS ONLY, DELIBERATELY. What a clinician inherits, what happens to a
-- derived kit when the charter changes, and whether she may override an
-- inherited value are PRODUCT DECISIONS that have been proposed and not yet
-- ruled. Building the propagation before the ruling would make the ruling
-- cosmetic — the shape would already be decided by the code.
--
-- ── CORRECTION TO 20260911195907_the_invitation.sql ──────────────────────────
--
-- That migration's header states: "Session 3 was built from the brief and the
-- brief quoted the schema without the invitation columns."
--
-- ⚠ THAT IS FALSE, verified against the transcript on 2026-09-12. The brief of
-- 2026-09-11 13:55:02Z carried the block in full, `user_id (nullable until they
-- sign up)`, `status`, `invite_token`, `invited_email` and `activated_at`
-- included. What Session 3 actually read was a compaction summary timestamped
-- 17:58:32Z, which had replaced the whole block with a placeholder. A READING
-- failure, not a gap in the brief.
--
-- The migration itself is not edited: corrections are new migrations, and its
-- SQL was right regardless of why it was written. See CHANTIER_LOG, "A summary
-- is not the source".
--
-- ── WHY THIS COLUMN IS THE B2B PRODUCT ──────────────────────────────────────
--
-- Without it, a practice is N unrelated kits sharing a login, which is not the
-- product. The practice has a brand; each clinician's kit derives from it.
-- `organizations` is merely the account — `brand_charter_kit_id` is what makes
-- it a practice. It is built now, while no cabinet exists and the change is
-- free: schema now, interface later.
--
-- ── WHAT IS DELIBERATELY ABSENT ─────────────────────────────────────────────
--
-- No `charter_revision`, no `charter_synced_at`, no `charter_drift` flag, no
-- per-field override marker. EACH OF THOSE ENCODES ONE OF THE THREE OPEN
-- DECISIONS. A `charter_synced_at` presumes the answer to "nothing, a flag, or
-- a rebuild" is a flag; an override marker presumes overrides exist. The wrong
-- column is harder to remove than the right one is to add, and both would
-- pre-empt a ruling that has been asked for. They arrive with it.
--
-- ⚠ AND NO SEAT COUNT. Still derived, never stored (20260911195907).
-- ============================================================================

alter table public.organizations
  add column if not exists brand_charter_kit_id uuid
    references public.brand_kits(id) on delete set null;

comment on column public.organizations.brand_charter_kit_id is
  'The practice brand charter: the kit that every clinician kit in this organization derives from. NULL until a practice has one, and a solo account never has one — which is what keeps the whole B2B layer invisible to solo users. ON DELETE SET NULL because losing the charter kit must never destroy the practice or its members.';

alter table public.brand_kits
  add column if not exists derived_from_charter_kit_id uuid
    references public.brand_kits(id) on delete set null;

comment on column public.brand_kits.derived_from_charter_kit_id is
  'The charter this kit derives from, or NULL for a kit that answers to no charter — which is every kit today. Set on a clinician kit; never set on a charter kit itself. Nothing reads it yet: the propagation waits on a product ruling.';

-- A charter cannot be its own parent. Cheap, decision-independent, and the one
-- cycle a single row can create on its own.
alter table public.brand_kits
  drop constraint if exists brand_kits_charter_is_not_itself;
alter table public.brand_kits
  add constraint brand_kits_charter_is_not_itself
  check (derived_from_charter_kit_id is null
         or derived_from_charter_kit_id <> id);

-- "Which kits derive from this charter" is the question every one of the three
-- candidate rulings has to answer, so the index earns its place under all of
-- them. Partial: the column is null for every kit that exists today.
create index if not exists brand_kits_derived_from_charter_kit_id_idx
  on public.brand_kits (derived_from_charter_kit_id)
  where derived_from_charter_kit_id is not null;

create index if not exists organizations_brand_charter_kit_id_idx
  on public.organizations (brand_charter_kit_id)
  where brand_charter_kit_id is not null;
