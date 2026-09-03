-- ============================================================================
-- Eklio — tenancy layer, lot 1: projects.organization_id + backfill
-- ============================================================================

alter table public.projects
  add column organization_id uuid references public.organizations (id);

comment on column public.projects.organization_id is
  'The organization that owns this project. Every project has exactly one, set at insert (by the app, or by projects_set_default_organization for a bare insert) and never reassigned by a client.';


-- ============================================================================
-- 1. Backfill — one organization of one per existing profile
-- ============================================================================
-- Idempotent: skips any profile that already has an active-owner organization,
-- so a re-run (or a partial run interrupted mid-loop) does not double-create.

do $$
declare
  v_profile       record;
  v_org_id        uuid;
  v_slug          text;
  v_suffix        int;
  v_project_id    uuid;
  v_project_count int;
begin
  for v_profile in
    select p.id, p.full_name
      from public.profiles p
     where not exists (
       select 1
         from public.organization_members m
        where m.user_id = p.id and m.role = 'owner' and m.status = 'active'
     )
     order by p.id
  loop
    v_slug   := 'org-' || left(v_profile.id::text, 8);
    v_suffix := 1;
    while exists (select 1 from public.organizations o where o.slug = v_slug) loop
      v_suffix := v_suffix + 1;
      v_slug   := 'org-' || left(v_profile.id::text, 8) || '-' || v_suffix;
    end loop;

    insert into public.organizations (name, slug, owner_user_id)
    values (
      coalesce(nullif(btrim(v_profile.full_name), ''), 'My practice'),
      v_slug,
      v_profile.id
    )
    returning id into v_org_id;

    select count(*) into v_project_count
      from public.projects pr
     where pr.user_id = v_profile.id;

    v_project_id := null;
    if v_project_count = 1 then
      select pr.id into v_project_id
        from public.projects pr
       where pr.user_id = v_profile.id;
    end if;

    insert into public.organization_members
      (organization_id, user_id, role, status, project_id, activated_at)
    values
      (v_org_id, v_profile.id, 'owner', 'active', v_project_id, now());

    update public.projects
       set organization_id = v_org_id
     where user_id = v_profile.id;
  end loop;
end;
$$;

-- expect: with today's data (2 profiles, each the sole user of exactly one
-- project), this produces 2 organizations, 2 active-owner organization_members
-- rows, and updates 2 projects. Verified by supabase/tests/tenancy_backfill.test.sql
-- and verify/lot1_backfill_counts.sql after this migration is applied — not by
-- this migration itself, which has no read access to confirm its own effect
-- beyond what it just wrote.

alter table public.projects
  alter column organization_id set not null;

create index projects_organization_id_idx on public.projects (organization_id);


-- ============================================================================
-- 2. projects_default_organization — the insert-time fallback
-- ============================================================================
-- Only runs when a client insert omits organization_id (the WHEN clause below
-- skips the function call entirely otherwise). Never silently picks: zero
-- matching owned organizations raises, and — because a user is only ever
-- supposed to own one organization in this lot — more than one also raises,
-- rather than picking arbitrarily.
--
-- ⚠ Resolves via NEW.user_id, NOT auth.uid() — a deliberate departure from
-- the brief's literal wording, found and fixed by actually running this
-- migration's effect against the existing test suite (see the checkpoint
-- report): for an `authenticated` client insert these are EQUIVALENT, because
-- projects_insert_own already requires `user_id = auth.uid()` for that same
-- row before this trigger fires — RLS and the trigger cannot disagree about
-- whose row it is. But 24 of the 41 pre-existing test files (and, most
-- likely, any service_role-context project creation in the application code)
-- insert `public.projects` directly with an explicit user_id and no
-- request.jwt.claims set at all — auth.uid() is NULL there by construction,
-- not by omission. Keying on auth.uid() breaks every one of them; keying on
-- NEW.user_id does not, and gives up nothing a client-facing insert relied on.
create or replace function public.projects_default_organization()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_count  int;
begin
  if new.user_id is null then
    raise exception 'projects_default_organization: user_id is null, cannot resolve an organization';
  end if;

  -- No min(uuid) in Postgres — confirmed by actually running this query;
  -- uuid has no default min/max aggregate. array_agg + array_length instead.
  select count(*), (array_agg(m.organization_id))[1]
    into v_count, v_org_id
    from public.organization_members m
   where m.user_id = new.user_id
     and m.role = 'owner'
     and m.status = 'active';

  if v_count = 0 then
    raise exception 'projects_default_organization: % owns no organization', new.user_id;
  elsif v_count > 1 then
    raise exception 'projects_default_organization: % owns % organizations, refusing to pick one', new.user_id, v_count;
  end if;

  new.organization_id := v_org_id;
  return new;
end;
$$;

revoke execute on function public.projects_default_organization() from public, anon, authenticated;

create trigger projects_set_default_organization
  before insert on public.projects
  for each row
  when (new.organization_id is null)
  execute function public.projects_default_organization();


-- ============================================================================
-- 3. create_default_organization_for_user — the signup-time path
-- ============================================================================
-- Same shape as the backfill loop above, for exactly one user. Called from
-- inside handle_new_user, below, after the profiles insert — so the
-- owner_user_id -> profiles(id) FK is always satisfiable.

create or replace function public.create_default_organization_for_user(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_full_name text;
  v_slug      text;
  v_suffix    int;
  v_org_id    uuid;
begin
  select p.full_name into v_full_name
    from public.profiles p
   where p.id = p_user_id;

  v_slug   := 'org-' || left(p_user_id::text, 8);
  v_suffix := 1;
  while exists (select 1 from public.organizations o where o.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug   := 'org-' || left(p_user_id::text, 8) || '-' || v_suffix;
  end loop;

  insert into public.organizations (name, slug, owner_user_id)
  values (coalesce(nullif(btrim(v_full_name), ''), 'My practice'), v_slug, p_user_id)
  returning id into v_org_id;

  insert into public.organization_members
    (organization_id, user_id, role, status, activated_at)
  values
    (v_org_id, p_user_id, 'owner', 'active', now());

  return v_org_id;
end;
$$;

comment on function public.create_default_organization_for_user(uuid) is
  'Creates the organization-of-one every user gets at signup. Called from handle_new_user only — not a client entry point.';

revoke execute on function public.create_default_organization_for_user(uuid) from public, anon, authenticated;


-- ============================================================================
-- 4. Extend handle_new_user — same trigger, same function, one more insert
-- ============================================================================
-- ⚠ search_path is `'public'`, NOT `''`, deliberately unchanged from the
-- existing function (see the Phase 1 checkpoint report, "Observed, not
-- touched" — the inconsistency with this lot's own `search_path = ''`
-- functions is noted there, not fixed here). This migration only adds the
-- one `perform` line; everything else about the function is untouched.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email);

  perform public.create_default_organization_for_user(new.id);

  return new;
end;
$function$;

-- The trigger `on_auth_user_created` already points at this function by name
-- (CREATE OR REPLACE FUNCTION does not need the trigger recreated) — no
-- second signup trigger is created here.
