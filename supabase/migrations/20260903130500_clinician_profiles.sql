-- ============================================================================
-- Eklio — lot C2: clinician_profiles, one row per seat
-- ============================================================================

-- ---------------------------------------------------------------------------
-- organizations.default_supervisor_name — the practice-level fact a
-- supervised_intern's row refers to rather than copies (lot C4).
-- ---------------------------------------------------------------------------
alter table public.organizations add column default_supervisor_name text;

comment on column public.organizations.default_supervisor_name is
  'The practice-wide default supervisor of record for supervised interns who do not name their own. Read through clinician_effective_supervisor(), never copied onto a clinician_profiles row — changing this one value must change every intern who relies on it, in one statement.';


-- ---------------------------------------------------------------------------
-- clinician_profiles
-- ---------------------------------------------------------------------------
create table public.clinician_profiles (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations (id) on delete cascade,
  project_id          uuid not null references public.projects (id) on delete cascade,
  member_id           uuid not null references public.organization_members (id) on delete cascade,
  full_name           text not null,
  credentials         text,
  status              text not null,
  supervisor_name     text,
  philosophy_quote    text,
  outside_the_room    text,
  personality_note    text,
  session_rate_cents  integer,
  rate_is_public      boolean not null default false,
  accepting_clients   boolean not null default true,
  photo_provided      boolean not null default false,
  booking_url         text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint clinician_profiles_project_id_key unique (project_id),
  constraint clinician_profiles_member_id_key unique (member_id),
  constraint clinician_profiles_status_check
    check (status in ('licensed', 'associate', 'supervised_intern')),
  constraint clinician_profiles_rate_check
    check (session_rate_cents is null or session_rate_cents > 0),
  -- A public rate without a rate is a lie the page would tell; the reverse
  -- (a private rate on file) is just not shown. No CHECK for "at least one
  -- licensed state" or similar completeness rules — an in-progress profile
  -- must be saveable. That belongs in clinician_profile_completeness().
  constraint clinician_profiles_rate_public_check
    check (rate_is_public = false or session_rate_cents is not null)
);

comment on table public.clinician_profiles is
  'One row per seat — the clinician-authored half of what a bio page needs. Completeness and staleness are read through clinician_profile_completeness() / organization_profile_health(), not enforced here as CHECKs, so a partial profile always saves.';
comment on column public.clinician_profiles.credentials is
  'Displayed verbatim — "LPC-MHSP", "LMFT". Not validated against any licensing board registry.';
comment on column public.clinician_profiles.supervisor_name is
  'NULL means: use the practice default (organizations.default_supervisor_name), read through clinician_effective_supervisor(). Never populated by copying the org default in — that is exactly the staleness defect this schema exists to prevent.';
comment on column public.clinician_profiles.photo_provided is
  'A checklist flag, not a photo. Eklio hosts nothing — the practice''s own site or the practice management system holds the actual file.';

create index clinician_profiles_organization_id_idx on public.clinician_profiles (organization_id);

create trigger set_clinician_profiles_updated_at
  before update on public.clinician_profiles
  for each row execute function public.set_updated_at();


-- ---------------------------------------------------------------------------
-- clinician_effective_supervisor — the ONE place the supervisor is read
-- ---------------------------------------------------------------------------
create or replace function public.clinician_effective_supervisor(p_profile_id uuid)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(cp.supervisor_name, o.default_supervisor_name)
    from public.clinician_profiles cp
    join public.organizations o on o.id = cp.organization_id
   where cp.id = p_profile_id;
$$;

comment on function public.clinician_effective_supervisor(uuid) is
  'The supervisor of record for a profile: its own supervisor_name if set, else the organization''s default_supervisor_name. SECURITY INVOKER — a caller who cannot read the profile via RLS gets NULL, not an error. Every place that displays or checks a supervisor reads through this, never supervisor_name directly.';

revoke execute on function public.clinician_effective_supervisor(uuid) from public, anon;
grant  execute on function public.clinician_effective_supervisor(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- A supervised_intern needs an effective supervisor. Cross-table (the org's
-- default), so this is a trigger, not a CHECK — CHECK constraints cannot
-- reference another table. Fires only on the columns it cares about.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_clinician_supervisor_required()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_effective text;
begin
  if new.status = 'supervised_intern' then
    v_effective := coalesce(
      new.supervisor_name,
      (select o.default_supervisor_name from public.organizations o where o.id = new.organization_id)
    );
    if v_effective is null then
      raise exception 'clinician_profiles: a supervised_intern needs supervisor_name or an organization default_supervisor_name';
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.enforce_clinician_supervisor_required() from public, anon, authenticated;

create trigger enforce_clinician_supervisor_required
  before insert or update of status, supervisor_name, organization_id
  on public.clinician_profiles
  for each row execute function public.enforce_clinician_supervisor_required();


-- ---------------------------------------------------------------------------
-- RLS — clinician_profiles
-- ---------------------------------------------------------------------------
alter table public.clinician_profiles enable row level security;
-- Same reasoning as us_states/population_cards: nothing public reads this
-- table, so anon's default grant is revoked rather than left in place.
revoke all on public.clinician_profiles from anon;

create policy "clinician_profiles_select_org"
  on public.clinician_profiles for select
  using (public.can_access_project(project_id));

-- ⚠ DELIBERATE EXCEPTION to lot 1's "read = owner or self, write = self"
-- rule: an office manager filling in profiles on behalf of clinicians is
-- the real workflow this table exists for, not an edge case. UPDATE (and
-- INSERT, for the same reason — seat-add pre-fills a profile the owner, not
-- the clinician, creates) is by the profile's own member OR the active org
-- owner, never member-only.
create policy "clinician_profiles_insert_own_or_owner"
  on public.clinician_profiles for insert
  with check (
    exists (select 1 from public.organization_members m
             where m.id = member_id and m.user_id = (select auth.uid()))
    or public.is_org_owner(organization_id)
  );

create policy "clinician_profiles_update_own_or_owner"
  on public.clinician_profiles for update
  using (
    exists (select 1 from public.organization_members m
             where m.id = member_id and m.user_id = (select auth.uid()))
    or public.is_org_owner(organization_id)
  )
  with check (
    exists (select 1 from public.organization_members m
             where m.id = member_id and m.user_id = (select auth.uid()))
    or public.is_org_owner(organization_id)
  );
-- No DELETE policy: a seat's profile goes away by cascade (member or
-- project removal), never by a direct client delete.


-- ---------------------------------------------------------------------------
-- Join tables — composite PK, RLS scoped through the parent profile
-- ---------------------------------------------------------------------------
create table public.clinician_licensed_states (
  profile_id uuid not null references public.clinician_profiles (id) on delete cascade,
  state_code char(2) not null references public.us_states (code),
  constraint clinician_licensed_states_pkey primary key (profile_id, state_code)
);

create table public.clinician_modalities (
  profile_id  uuid not null references public.clinician_profiles (id) on delete cascade,
  modality_id text not null references public.modality_cards (id),
  prominence  text references public.modality_prominence_options (id),
  constraint clinician_modalities_pkey primary key (profile_id, modality_id)
);

create table public.clinician_populations (
  profile_id    uuid not null references public.clinician_profiles (id) on delete cascade,
  population_id text not null references public.population_cards (id),
  constraint clinician_populations_pkey primary key (profile_id, population_id)
);

do $$
declare
  t text;
begin
  foreach t in array array[
    'clinician_licensed_states', 'clinician_modalities', 'clinician_populations'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);

    execute format(
      'create policy %I on public.%I for select using (exists (
         select 1 from public.clinician_profiles cp
          where cp.id = %I.profile_id and public.can_access_project(cp.project_id)
       ))',
      t || '_select_org', t, t
    );

    execute format(
      'create policy %I on public.%I for insert with check (exists (
         select 1 from public.clinician_profiles cp
           join public.organization_members m on m.id = cp.member_id
          where cp.id = %I.profile_id
            and (m.user_id = (select auth.uid()) or public.is_org_owner(cp.organization_id))
       ))',
      t || '_insert_own_or_owner', t, t
    );

    execute format(
      'create policy %I on public.%I for delete using (exists (
         select 1 from public.clinician_profiles cp
           join public.organization_members m on m.id = cp.member_id
          where cp.id = %I.profile_id
            and (m.user_id = (select auth.uid()) or public.is_org_owner(cp.organization_id))
       ))',
      t || '_delete_own_or_owner', t, t
    );
  end loop;
end
$$;
