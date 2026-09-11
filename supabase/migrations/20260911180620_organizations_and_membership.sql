-- ============================================================================
-- The tenancy layer — organizations, membership, and one predicate
-- ============================================================================
-- Session 3 of the tenancy chantier. This migration adds the layer and nothing
-- else: no policy anywhere in the product changes, no screen changes, and no
-- existing query returns a different row than it did yesterday. Session 4
-- migrates the fourteen policies onto it.
--
-- ⚠ INVISIBLE TO SOLO USERS, AND THAT IS A REQUIREMENT, NOT AN ACCIDENT. Every
-- profile gets exactly one organization in which it is `owner`, created at
-- signup and never mentioned. A therapist working alone must not learn the
-- word "organization" from this product. The layer exists so that the day a
-- practice has two clinicians, it is a row, not a migration of every table.
-- ============================================================================

create table if not exists public.organizations (
  id          uuid primary key default gen_random_uuid(),
  /*
   * ⚠ NULLABLE ON PURPOSE, AND NULL IS THE NORMAL CASE. A solo practitioner's
   * organization has never been seen by anybody, so it has no name — and a
   * fabricated one ("Sarah's practice", the email local part) would be a value
   * the product cannot justify if it ever surfaced. Null means "never named,
   * because nobody has looked at it". The invitation flow names it.
   */
  name        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.organizations is
  'A practice. One per profile by default, invisible until a second member exists.';
comment on column public.organizations.name is
  'Null until somebody names the practice. Not derived from the owner''s email.';

create table if not exists public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id)      on delete cascade,
  /*
   * Two roles, and the list is closed. `owner` pays and invites; `clinician`
   * works. A third role is a decision, not a string.
   */
  role            text not null check (role in ('owner', 'clinician')),
  created_at      timestamptz not null default now(),
  primary key (organization_id, user_id)
);

comment on table public.organization_members is
  'Who belongs to a practice, and in which of the two roles.';

/*
 * ⚠ ONE OWNING ORGANIZATION PER PERSON, ENFORCED BY AN INDEX RATHER THAN BY
 * CARE. The claim at signup has to answer "which organization?" in a single
 * statement; a scalar subquery that can return two rows raises 21000 at
 * runtime — which this repository has already been bitten by once, in
 * `orphaned_purchases`. An index makes the second row impossible instead of
 * making the query defensive.
 *
 * Reversible: `drop index` the day one person owns two practices. Nothing
 * depends on the uniqueness except the claim, and the claim would then need a
 * choice made explicitly — which is the correct consequence.
 */
create unique index if not exists organization_members_one_owned_org_per_user
    on public.organization_members (user_id)
 where role = 'owner';

create index if not exists organization_members_user_id_idx
    on public.organization_members (user_id);

alter table public.organizations        enable row level security;
alter table public.organization_members enable row level security;

drop trigger if exists set_organizations_updated_at on public.organizations;
create trigger set_organizations_updated_at
  before update on public.organizations
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- The predicate
-- ---------------------------------------------------------------------------
/*
 * ⚠ SECURITY DEFINER IS LOAD-BEARING HERE, TWICE OVER.
 *
 * First, recursion: the SELECT policy on `organization_members` calls this
 * function, and this function reads `organization_members`. Evaluated as the
 * caller that would be "infinite recursion detected in policy for relation".
 * Running as the owner, the read is not subject to the policy, and the cycle
 * does not exist.
 *
 * Second, and this is the rule from the near-miss: ASK WHO CALLS IT AND WITH
 * WHAT IDENTITY. The callers are RLS policies, evaluated under whoever is
 * querying — `authenticated` with a uid, or `anon` with none. It therefore
 * asserts its own caller through `auth.uid()` and returns false rather than
 * raising when there is no session, because an anonymous caller reaching a
 * project does so through the token branch of the policy, never through this
 * one. A null argument is false, never "any organization".
 */
create or replace function public.is_org_member(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select p_org_id is not null
     and exists (
       select 1
         from public.organization_members m
        where m.organization_id = p_org_id
          and m.user_id = (select auth.uid())
     );
$function$;

comment on function public.is_org_member(uuid) is
  'True when the current session belongs to that organization. Sibling of owns_project; false for anon, false for null.';

revoke execute on function public.is_org_member(uuid) from public;
grant execute on function public.is_org_member(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Policies on the layer itself
-- ---------------------------------------------------------------------------
/*
 * READ ONLY, FROM THE BROWSER. There is deliberately no insert, update or
 * delete policy on either table: organizations are created by
 * `handle_new_user` and (from Session 4) by the invitation RPC, both
 * SECURITY DEFINER, both server-side. A browser that could insert an
 * `organization_members` row could add itself to a stranger's practice, which
 * is the whole of this layer's attack surface in one statement.
 *
 * RLS with no policy for a command already denies it. The absence is named
 * here so that nobody reads it as an oversight and "fixes" it.
 */
drop policy if exists organizations_select_member on public.organizations;
create policy organizations_select_member on public.organizations
  for select to authenticated
  using (public.is_org_member(id));

drop policy if exists organization_members_select_member on public.organization_members;
create policy organization_members_select_member on public.organization_members
  for select to authenticated
  using (public.is_org_member(organization_id));

-- ---------------------------------------------------------------------------
-- Every new profile gets its organization, at signup, silently
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org_id uuid;
begin
  insert into public.profiles (id, email)
  values (new.id, new.email);

  /*
   * ⚠ IN THE SAME TRIGGER AS THE PROFILE, SO THE INVARIANT CANNOT BE HALF
   * TRUE. A profile with no owning organization is a person the claim cannot
   * attach a project to — and the claim would then fail the CHECK on
   * `projects` and write nothing. One statement each, one transaction, and the
   * enumeration test asserts the invariant on every push.
   */
  insert into public.organizations default values
  returning id into v_org_id;

  insert into public.organization_members (organization_id, user_id, role)
  values (v_org_id, new.id, 'owner');

  return new;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Backfill: one organization per existing profile, as its owner
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  v_org_id uuid;
begin
  for r in
    select p.id
      from public.profiles p
     where not exists (
       select 1 from public.organization_members m
        where m.user_id = p.id and m.role = 'owner')
  loop
    insert into public.organizations default values returning id into v_org_id;
    insert into public.organization_members (organization_id, user_id, role)
    values (v_org_id, r.id, 'owner');
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Guard rail — asserts the moment, not the state. The state is in CI.
-- ---------------------------------------------------------------------------
do $$
declare
  v_orphans integer;
  v_doubles integer;
begin
  select count(*) into v_orphans
    from public.profiles p
   where not exists (select 1 from public.organization_members m
                      where m.user_id = p.id and m.role = 'owner');
  assert v_orphans = 0,
    format('%s profiles have no owning organization after the backfill', v_orphans);

  select count(*) into v_doubles
    from (select user_id from public.organization_members
           where role = 'owner' group by user_id having count(*) > 1) s;
  assert v_doubles = 0, format('%s users own two organizations', v_doubles);
end
$$;
