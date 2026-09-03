-- ============================================================================
-- Eklio — tenancy layer, E1/E2: provision_clinician_project, apply_charter_internal
-- ============================================================================
-- ⚠ TRACE, done before writing anything here (reproduced against the local
-- stack, not assumed): the reported defect ("an invited clinician's project
-- lands in the wrong organization") does NOT happen. `projects_insert_own`'s
-- WITH CHECK is `user_id = auth.uid()` only — it places no constraint on
-- organization_id, and `projects_set_default_organization` only fires when
-- the client leaves organization_id NULL. An explicit organization_id, as
-- the frontend always passed, is respected as given.
--
-- What actually happens is worse: the insert FAILS OUTRIGHT, for every
-- user, whenever it is done the way Postgrest (and this session's own
-- getOrCreateOwnProject) does it — `INSERT ... RETURNING`. Reproduced with
-- a minimal, tenancy-unrelated toy table: a SELECT policy enforced by a
-- SECURITY DEFINER function that looks the row up BY ID from the same
-- table raises "new row violates row-level security policy" on
-- INSERT...RETURNING, even though a plain SELECT run immediately
-- afterwards, in a separate statement, finds the row and returns true. The
-- WITH-CHECK-as-SELECT-policy evaluation for RETURNING happens within the
-- INSERT's own command, before the new row is visible to a fresh by-id
-- scan — `can_access_project`, used as `projects`' own SELECT policy
-- (`projects_select_org`, lot 1's org-scoped RLS rewrite), does exactly
-- that lookup on the exact table it is gating. Marking the function
-- VOLATILE instead of STABLE does not change this — it is not a caching
-- issue, it is snapshot visibility. A bare column-reference policy
-- (`user_id = auth.uid()`) has no such problem, because it needs no scan.
--
-- This has been true since the org-scoped RLS rewrite and was never
-- exercised by any existing test (24 of the pre-existing 41 test files
-- insert `projects` directly as postgres, bypassing RLS) or by any
-- existing frontend code path (nothing in the shipped app did an
-- authenticated-role `projects` insert with RETURNING before this
-- session's own getOrCreateOwnProject — which is exactly what this
-- migration replaces).
--
-- The fix direction asked for — a SECURITY DEFINER RPC doing the insert
-- internally — is the correct fix for BOTH the hypothesized problem (which
-- turned out not to exist) and the real one: a SECURITY DEFINER function's
-- own internal statements are not subject to RLS at all (their owning role
-- bypasses it), so the self-referential visibility problem never arises.
-- Confirmed with the same toy table before writing this migration.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- apply_charter_internal — the actual copy, extracted from
-- apply_charter_to_project (20260903120000_field_source_locks.sql). No
-- client grant at all: it trusts its caller to have already authorized the
-- write, exactly like every other *_internal helper in this lot
-- (random_token_hex, sha256_hex).
--
-- No charter kit, no site_specs on the charter kit, or no brand_kit/
-- site_specs on the target project: a silent no-op, not an error. A
-- practice may invite clinicians before setting a charter, and a freshly
-- provisioned project may not have finished being scaffolded by its
-- caller yet — this function does the copy if and only if there is
-- something to copy onto, and never raises about a precondition it did
-- not itself establish.
-- ---------------------------------------------------------------------------
create or replace function public.apply_charter_internal(p_organization_id uuid, p_project_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_charter_kit_id uuid;
  v_charter_spec   public.site_specs%rowtype;
  v_target_kit_id  uuid;
  v_target_spec_id uuid;
  v_new_sources    jsonb;
begin
  select brand_charter_kit_id into v_charter_kit_id
    from public.organizations where id = p_organization_id;

  if v_charter_kit_id is null then
    return;
  end if;

  select * into v_charter_spec from public.site_specs where brand_kit_id = v_charter_kit_id;
  if not found then
    return;
  end if;

  select id into v_target_kit_id from public.brand_kits where project_id = p_project_id;
  if v_target_kit_id is null then
    return;
  end if;

  select id, coalesce(field_sources, '{}'::jsonb)
    into v_target_spec_id, v_new_sources
    from public.site_specs where brand_kit_id = v_target_kit_id;
  if v_target_spec_id is null then
    return;
  end if;

  v_new_sources := v_new_sources || jsonb_build_object(
    'primary_hex', 'inherited', 'secondary_hex', 'inherited', 'accent_hex', 'inherited',
    'light_neutral_hex', 'inherited', 'dark_neutral_hex', 'inherited', 'paper_hex', 'inherited',
    'heading_font', 'inherited', 'body_font', 'inherited'
  );

  -- Same transaction-scoped GUC caveat as apply_charter_to_project's
  -- original body (see that migration's comment) — reset in the same
  -- statement batch, before returning, whether the write succeeds or not.
  perform set_config('eklio.bypass_field_locks', 'on', true);

  begin
    update public.site_specs
       set primary_hex           = v_charter_spec.primary_hex,
           secondary_hex         = v_charter_spec.secondary_hex,
           accent_hex            = v_charter_spec.accent_hex,
           light_neutral_hex     = v_charter_spec.light_neutral_hex,
           dark_neutral_hex      = v_charter_spec.dark_neutral_hex,
           paper_hex             = v_charter_spec.paper_hex,
           heading_font          = v_charter_spec.heading_font,
           body_font             = v_charter_spec.body_font,
           font_display_fallback = v_charter_spec.font_display_fallback,
           field_sources         = v_new_sources
     where id = v_target_spec_id;
  exception when others then
    perform set_config('eklio.bypass_field_locks', 'off', true);
    raise;
  end;

  perform set_config('eklio.bypass_field_locks', 'off', true);
end;
$$;

comment on function public.apply_charter_internal(uuid, uuid) is
  'The actual charter-copy — see apply_charter_to_project for the owner-gated public entry point, and provision_clinician_project for the self-service one. Every precondition failure is a silent no-op: this function never raises, so a caller who has not yet set up a charter, or a project not yet scaffolded, is simply left unchanged rather than blocking whatever called it.';

revoke execute on function public.apply_charter_internal(uuid, uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- apply_charter_to_project keeps its own owner gate and its own explicit
-- raises (an owner triggering this deliberately gets a reason when it does
-- nothing — unlike the two self-service callers below, this one is not
-- "best effort"). Behavior for an org owner is UNCHANGED from the original
-- migration; only the copy body moved.
-- ---------------------------------------------------------------------------
create or replace function public.apply_charter_to_project(p_organization_id uuid, p_project_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_charter_kit_id uuid;
begin
  if not public.is_org_owner(p_organization_id) then
    raise exception 'apply_charter_to_project: % is not an active owner of organization %', auth.uid(), p_organization_id;
  end if;

  select brand_charter_kit_id into v_charter_kit_id
    from public.organizations where id = p_organization_id;
  if v_charter_kit_id is null then
    raise exception 'apply_charter_to_project: organization % has no charter kit', p_organization_id;
  end if;

  if not exists (
    select 1 from public.projects where id = p_project_id and organization_id = p_organization_id
  ) then
    raise exception 'apply_charter_to_project: project % does not belong to organization %', p_project_id, p_organization_id;
  end if;

  if not exists (select 1 from public.site_specs where brand_kit_id = v_charter_kit_id) then
    raise exception 'apply_charter_to_project: the charter kit has no site_specs row yet';
  end if;

  if not exists (select 1 from public.brand_kits where project_id = p_project_id) then
    raise exception 'apply_charter_to_project: project % has no brand kit yet', p_project_id;
  end if;

  perform public.apply_charter_internal(p_organization_id, p_project_id);
end;
$$;

comment on function public.apply_charter_to_project(uuid, uuid) is
  'Owner-triggered charter application. Unlike apply_charter_internal, raises on every precondition it can name — the org has no charter kit, the project is not in the org, the charter kit or the target project has no site_specs/brand_kit yet — because an owner invoking this directly should learn why nothing happened. Delegates the actual copy to apply_charter_internal.';

revoke execute on function public.apply_charter_to_project(uuid, uuid) from public, anon, authenticated;
grant  execute on function public.apply_charter_to_project(uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- provision_clinician_project — the self-service path a clinician (or any
-- active member) uses instead of a plain `projects` insert, which lot D's
-- own frontend code was relying on and which the trace above shows cannot
-- work under RETURNING. Also scaffolds a minimal brand_kits/site_specs
-- pair — apply_charter_internal has nothing to write into otherwise, and
-- nothing else in the app creates one for a project outside the
-- brief -> directions -> kit flow this project never goes through.
-- ---------------------------------------------------------------------------
create or replace function public.provision_clinician_project(p_organization_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id  uuid;
  v_project_id uuid;
  v_kit_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'provision_clinician_project: no authenticated user';
  end if;

  select id, project_id into v_member_id, v_project_id
    from public.organization_members
   where organization_id = p_organization_id
     and user_id = auth.uid()
     and status = 'active'
   for update;

  if not found then
    raise exception 'provision_clinician_project: % is not an active member of organization %', auth.uid(), p_organization_id;
  end if;

  -- Idempotent: a member who already has a project in this organization
  -- gets it back unchanged, no second project, no re-application.
  if v_project_id is not null then
    return v_project_id;
  end if;

  insert into public.projects (user_id, organization_id, name)
  values (auth.uid(), p_organization_id, 'My profile')
  returning id into v_project_id;

  insert into public.brand_kits (project_id) values (v_project_id)
  returning id into v_kit_id;

  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, paper_hex,
     heading_font, body_font, google_fonts_url, hero, pages)
  values
    (v_kit_id, auth.uid(), '#26211C', '#26211C', '#B4653F',
     '#FDFCFA', '#26211C', '#FDFCFA',
     'Inter', 'Inter',
     'https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap',
     jsonb_build_object('overline', '', 'headline', '', 'subhead', '', 'cta_label', ''),
     public.site_spec_default_pages(null, null));

  update public.organization_members
     set project_id = v_project_id
   where id = v_member_id;

  perform public.apply_charter_internal(p_organization_id, v_project_id);

  return v_project_id;
end;
$$;

comment on function public.provision_clinician_project(uuid) is
  'Self-service project provisioning for an active org member — replaces a plain client-side `projects` insert, which cannot work under Postgrest''s INSERT...RETURNING against projects_select_org (see this migration''s header). Idempotent per (member, organization). Scaffolds a minimal brand_kits/site_specs pair and applies the org''s charter if one exists.';

revoke execute on function public.provision_clinician_project(uuid) from public, anon;
grant  execute on function public.provision_clinician_project(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Consistency triggers — making the incoherence the original report
-- worried about impossible, even though the trace found it wasn't
-- currently reachable. Both NULL-safe: organization_members.project_id
-- may be NULL (no check needed then); clinician_profiles.project_id is
-- NOT NULL already, but the subquery result is still compared with
-- IS DISTINCT FROM rather than `=`, so a project row that somehow
-- vanished reads as a mismatch, not as a silently-passing NULL = NULL.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_clinician_profile_organization_match()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project_org_id uuid;
begin
  select p.organization_id into v_project_org_id
    from public.projects p where p.id = new.project_id;

  if v_project_org_id is distinct from new.organization_id then
    raise exception 'clinician_profiles: organization_id % does not match project %''s organization (%)',
      new.organization_id, new.project_id, v_project_org_id;
  end if;

  return new;
end;
$$;

revoke execute on function public.enforce_clinician_profile_organization_match() from public, anon, authenticated;

create trigger enforce_clinician_profile_organization_match
  before insert or update of organization_id, project_id on public.clinician_profiles
  for each row execute function public.enforce_clinician_profile_organization_match();


create or replace function public.enforce_member_project_organization_match()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project_org_id uuid;
begin
  if new.project_id is null then
    return new;
  end if;

  select p.organization_id into v_project_org_id
    from public.projects p where p.id = new.project_id;

  if v_project_org_id is distinct from new.organization_id then
    raise exception 'organization_members: project % does not belong to organization % (it belongs to %)',
      new.project_id, new.organization_id, v_project_org_id;
  end if;

  return new;
end;
$$;

revoke execute on function public.enforce_member_project_organization_match() from public, anon, authenticated;

create trigger enforce_member_project_organization_match
  before insert or update of project_id on public.organization_members
  for each row execute function public.enforce_member_project_organization_match();
