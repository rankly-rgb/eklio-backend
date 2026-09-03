-- ============================================================================
-- Eklio — tenancy layer, lot 1: organizations and organization_members
-- ============================================================================
-- An organization owns projects; a user is a member of an organization with a
-- role. Every existing/new user becomes the owner of an organization of one —
-- see the next migration for the backfill and the signup hook. This lot is
-- invisible to solo users: nothing here changes what a solo user can do.
--
-- ORDERING CHOICE, as flagged in the Step 0 inventory: `is_org_member` and
-- `is_org_owner` need `organization_members` to exist, and this migration's
-- own RLS policies on `organizations`/`organization_members` need those two
-- functions to exist. Combined into ONE migration — tables, then functions,
-- then policies, in that order in this file — rather than splitting across
-- two files with a lower/higher timestamp. `can_access_project` and
-- `can_access_brand_kit` (which need `projects.organization_id`, added in the
-- next migration) live in their own later migration.
-- ============================================================================

-- `citext` is not enabled anywhere in this repo today (no prior `create
-- extension citext` statement; the reference migration's header lists only
-- Supabase's defaults — pgcrypto, uuid-ossp, pg_stat_statements,
-- supabase_vault). First migration to add it, for `invited_email`.
create extension if not exists citext;


-- ============================================================================
-- 1. organizations
-- ============================================================================

create table public.organizations (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  slug                  text not null,
  -- References `profiles`, not `auth.users` directly — matching the repo's
  -- kept convention (`projects.user_id -> profiles(id)`, see the reference
  -- migration's anomaly note): `profiles` stays the one table coupled to
  -- `auth`. No `on delete` clause, same as the spec: deleting a profile that
  -- still owns an organization is refused (NO ACTION), not cascaded away.
  owner_user_id         uuid not null references public.profiles (id),
  brand_charter_kit_id  uuid references public.brand_kits (id) on delete set null,
  created_at            timestamptz not null default now(),
  constraint organizations_name_check check (length(btrim(name)) between 1 and 120),
  constraint organizations_slug_check check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint organizations_slug_key unique (slug)
);

comment on table public.organizations is
  'A practice: owns projects, has members. Every user gets one of these at signup (organization of one); the practice offer adds more members to it. brand_charter_kit_id points at the brand_kit whose site_specs field_sources are the source of truth clinicians inherit from — null until a charter is chosen.';


-- ============================================================================
-- 2. organization_members
-- ============================================================================

create table public.organization_members (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references public.organizations (id) on delete cascade,
  user_id            uuid references public.profiles (id) on delete cascade,
  role               text not null,
  status             text not null,
  invited_email      citext,
  invite_token_hash  text,
  project_id         uuid references public.projects (id) on delete set null,
  created_at         timestamptz not null default now(),
  activated_at       timestamptz,
  removed_at         timestamptz,

  constraint organization_members_role_check   check (role   in ('owner', 'clinician')),
  constraint organization_members_status_check check (status in ('invited', 'active', 'removed')),

  -- An active row always has a user. An invited row never does, and always
  -- carries the email and token hash it was invited with. A removed row
  -- always carries when it was removed.
  constraint organization_members_active_has_user_check
    check (status <> 'active' or user_id is not null),
  constraint organization_members_invited_shape_check
    check (status <> 'invited'
           or (invited_email is not null and invite_token_hash is not null and user_id is null)),
  constraint organization_members_removed_has_timestamp_check
    check (status <> 'removed' or removed_at is not null),

  -- NOT `(status = 'active') = (activated_at is not null)`: a removed member
  -- keeps the `activated_at` she earned while active (status flips to
  -- 'removed', not back to null), so that biconditional would reject every
  -- removed-after-active row. This says the weaker, still-meaningful thing:
  -- only 'invited' may lack an activation timestamp; 'active' and 'removed'
  -- both require one, because both mean "was activated at some point."
  constraint organization_members_activated_at_check
    check (status = 'invited' or activated_at is not null),

  -- Unique where not null is what a plain UNIQUE constraint already gives in
  -- Postgres (each NULL is distinct from every other NULL).
  constraint organization_members_invite_token_hash_key unique (invite_token_hash)
);

comment on table public.organization_members is
  'One row per (organization, person or pending invite). role is owner/clinician only. status invited -> active -> removed; an invited row has no user_id yet (it is looked up by invite_token_hash), an active row has exactly one user_id, a removed row is kept for history. project_id is the clinician''s own project once she has one — set by the app flow, not by accept_org_invite.';
comment on column public.organization_members.invite_token_hash is
  'sha256(raw token), hex. The raw token is returned once by create_org_invite and never stored — only its hash lives here, so a leaked row never leaks a usable token.';
comment on column public.organization_members.project_id is
  'The member''s own project, once she has exactly one. Nullable and set-null on project delete: an org can have members before any of them has a project.';

-- Exactly one active owner per organization.
create unique index organization_members_one_active_owner_idx
  on public.organization_members (organization_id)
  where role = 'owner' and status = 'active';

-- A user is an active member of a given organization at most once.
create unique index organization_members_one_active_membership_idx
  on public.organization_members (organization_id, user_id)
  where user_id is not null and status = 'active';

create index organization_members_organization_id_idx
  on public.organization_members (organization_id);
create index organization_members_user_id_idx
  on public.organization_members (user_id)
  where user_id is not null;

alter table public.organizations        enable row level security;
alter table public.organization_members enable row level security;


-- ============================================================================
-- 3. is_org_member / is_org_owner
-- ============================================================================
-- Both explicitly return false on `auth.uid() is null`, first line — anon
-- gets false, never an error, matching every other predicate in this schema.

create or replace function public.is_org_member(p_org_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return false;
  end if;

  return exists (
    select 1
      from public.organization_members m
     where m.organization_id = p_org_id
       and m.user_id = auth.uid()
       and m.status = 'active'
  );
end;
$$;

comment on function public.is_org_member(uuid) is
  'True iff the calling user is an active member (owner or clinician) of p_org_id. False for anon and for a non-existent org — never an error.';

create or replace function public.is_org_owner(p_org_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return false;
  end if;

  return exists (
    select 1
      from public.organization_members m
     where m.organization_id = p_org_id
       and m.user_id = auth.uid()
       and m.role = 'owner'
       and m.status = 'active'
  );
end;
$$;

comment on function public.is_org_owner(uuid) is
  'True iff the calling user is the active owner of p_org_id. False for anon and for a non-existent org — never an error.';

revoke execute on function public.is_org_member(uuid) from public, anon, authenticated;
grant  execute on function public.is_org_member(uuid) to authenticated;
revoke execute on function public.is_org_owner(uuid)  from public, anon, authenticated;
grant  execute on function public.is_org_owner(uuid)  to authenticated;


-- ============================================================================
-- 4. Policies
-- ============================================================================

-- ---- organizations ----------------------------------------------------------
create policy "organizations_select_member"
  on public.organizations for select
  using (public.is_org_member(id));

create policy "organizations_update_owner"
  on public.organizations for update
  using (public.is_org_owner(id))
  with check (public.is_org_owner(id));

-- Only the signup path inserts an organization (via create_default_organization_for_user,
-- SECURITY DEFINER, called from handle_new_user) or a later, still-out-of-scope
-- "create additional organization" flow. This policy just says who the row
-- must claim as owner if a client-context insert ever happens.
create policy "organizations_insert_self_owned"
  on public.organizations for insert
  with check (owner_user_id = (select auth.uid()));

-- No DELETE policy: an organization is never deleted by a client.

-- ---- organization_members ----------------------------------------------------
create policy "organization_members_select_member"
  on public.organization_members for select
  using (public.is_org_member(organization_id));

create policy "organization_members_insert_owner"
  on public.organization_members for insert
  with check (public.is_org_owner(organization_id));

create policy "organization_members_update_owner"
  on public.organization_members for update
  using (public.is_org_owner(organization_id))
  with check (public.is_org_owner(organization_id));

-- No DELETE policy: removal is a status change (remove_org_member), never a
-- client DELETE.

revoke all on public.organizations, public.organization_members from anon;
revoke delete on public.organizations, public.organization_members from authenticated;
grant select, insert, update on public.organizations, public.organization_members to authenticated;
