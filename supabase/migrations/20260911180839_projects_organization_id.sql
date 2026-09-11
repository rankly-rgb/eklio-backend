-- ============================================================================
-- projects.organization_id — nullable, derived, and impossible to half-write
-- ============================================================================
-- The 2 September spec said `not null`. It was written eight days before the
-- anonymous brief shipped, and an anonymous project has no user, therefore no
-- organization. The amendment agreed on 11 September:
--
--   organization_id nullable, with  organization_id is not null
--                                or anon_token_hash is not null
--
-- which is the same shape as `projects_owner_present_check` already in
-- production: a brief belongs to a token until it belongs to somebody.
--
-- ── AND THE CLAIM SETS user_id AND organization_id TOGETHER, OR NEITHER ─────
--
-- Not by asking two call sites to remember. Two mechanisms, each sufficient:
--
--   1. A BEFORE trigger DERIVES organization_id from user_id, in the same
--      statement, for every writer that exists and every writer written later.
--      `insert into projects (user_id, name)` — the shape both call sites use
--      today — keeps working untouched and comes out tenanted.
--   2. The CHECK refuses the half-written row anyway. Verified with the trigger
--      disabled: a claimed project forced to organization_id null raises
--      23514 and the whole UPDATE writes nothing.
--
-- Discipline at the call site is neither required nor trusted.
-- ============================================================================

alter table public.projects
  add column if not exists organization_id uuid
    /*
     * ⚠ RESTRICT, NOT SET NULL. `purchases_project_id_fkey` is ON DELETE SET
     * NULL, and that is how a paid purchase came to be silently detached from
     * its project and counted as paid for every other project the account
     * owned. The same shape here would detach a project from its practice and
     * leave it looking like a solo project. Deleting an organization that
     * still has projects should fail, loudly, in front of whoever asked.
     */
    references public.organizations(id) on delete restrict;

create index if not exists projects_organization_id_idx
    on public.projects (organization_id);

comment on column public.projects.organization_id is
  'The practice this project belongs to. Derived from user_id by projects_bind_organization; null only while the project is anonymous.';

-- ---------------------------------------------------------------------------
-- The derivation
-- ---------------------------------------------------------------------------
/*
 * ⚠ WHO CALLS THIS, AND WITH WHAT IDENTITY — the question, asked before the
 * predicate was chosen.
 *
 *   · `authenticated`, through `projects_insert_own` / `projects_update_own`:
 *     the browser. It has never named an organization and must not be allowed
 *     to, so whatever it sends is overwritten by the owner's own. That closes,
 *     at the moment the column appears, the hole of an authenticated caller
 *     writing a STRANGER'S organization_id onto their project and dragging it
 *     into someone else's practice — without touching any of the fourteen
 *     policies Session 4 owns.
 *   · `anon`, holding a token: user_id is null, so organization_id is forced
 *     null. An anonymous brief belongs to a token, never to a practice.
 *   · `service_role`: Eklio's own server. It MAY name an organization, and
 *     that is the seam Session 4's invitation needs — a clinician's project
 *     belongs to the practice, not to the clinician's personal organization.
 *     `auth.role()` is what distinguishes it, and it survives entry into a
 *     SECURITY DEFINER body where `current_user` has already become the owner.
 *
 * No owning organization for the user is not a fallback case, it is an
 * impossible one (`handle_new_user` and the backfill both create it). It
 * raises rather than writing null, because a project quietly missing its
 * practice is exactly the plausible value this codebase keeps failing with.
 */
create or replace function public.projects_bind_organization()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_org uuid;
begin
  -- An ordinary update — a step number, a status — touches neither column.
  -- Skipping it keeps the brief's autosave path free of an extra lookup, and
  -- keeps this trigger from re-deriving a value nobody asked about.
  if tg_op = 'UPDATE'
     and new.user_id is not distinct from old.user_id
     and new.organization_id is not distinct from old.organization_id then
    return new;
  end if;

  if new.user_id is null then
    new.organization_id := null;
    return new;
  end if;

  if new.organization_id is not null and auth.role() = 'service_role' then
    return new;
  end if;

  select m.organization_id into v_org
    from public.organization_members m
   where m.user_id = new.user_id
     and m.role = 'owner';

  if v_org is null then
    raise exception 'project % has an owner (%) with no owning organization', new.id, new.user_id
      using errcode = 'foreign_key_violation';
  end if;

  new.organization_id := v_org;
  return new;
end
$function$;

revoke execute on function public.projects_bind_organization() from public, anon, authenticated;

drop trigger if exists projects_bind_organization on public.projects;
create trigger projects_bind_organization
  before insert or update on public.projects
  for each row execute function public.projects_bind_organization();

-- ---------------------------------------------------------------------------
-- Backfill, then the constraint. In that order, in one transaction.
-- ---------------------------------------------------------------------------
update public.projects p
   set organization_id = m.organization_id
  from public.organization_members m
 where m.user_id = p.user_id
   and m.role = 'owner'
   and p.user_id is not null
   and p.organization_id is null;

alter table public.projects drop constraint if exists projects_tenant_present_check;
alter table public.projects
  add constraint projects_tenant_present_check
  check (organization_id is not null or anon_token_hash is not null);

comment on constraint projects_tenant_present_check on public.projects is
  'Mirrors projects_owner_present_check. A claimed project without a practice cannot be written, so the claim is together-or-neither by constraint rather than by discipline.';

-- ---------------------------------------------------------------------------
-- Guard rail
-- ---------------------------------------------------------------------------
do $$
declare
  v_untenanted integer;
  v_anon_tenanted integer;
begin
  select count(*) into v_untenanted
    from public.projects
   where user_id is not null and organization_id is null;
  assert v_untenanted = 0,
    format('%s owned projects have no organization after the backfill', v_untenanted);

  select count(*) into v_anon_tenanted
    from public.projects
   where user_id is null and organization_id is not null;
  assert v_anon_tenanted = 0,
    format('%s anonymous projects carry an organization', v_anon_tenanted);
end
$$;
