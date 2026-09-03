-- ============================================================================
-- Eklio — lot B1: lock enforcement on inherited/imported site_specs fields
-- ============================================================================
-- Lot 1 placed field_sources without enforcement, on purpose ("lock
-- enforcement... is a later lot" — see the column comment). This is that lot.
--
-- BYPASS MECHANISM: a GUC (`eklio.bypass_field_locks`), set only from inside
-- apply_charter_to_project / import_brand_identity (both SECURITY DEFINER,
-- both below) before they write a locked field on purpose — re-applying a
-- charter or re-importing an identity must be able to overwrite what it
-- itself locked. No client-reachable RPC sets this GUC, so a client cannot
-- self-issue the bypass; `set_field_sources` never sets it, because it never
-- touches the six colour/typography columns, only field_sources itself.
--
-- ⚠ `set_config(name, value, true)`'s third argument means "reset at the end
-- of the TRANSACTION," not "reset when this function returns." Both
-- functions below turn it back 'off' immediately after their write,
-- in the same statement batch — found necessary by actually testing a
-- clinician's direct write in the same test transaction right after an
-- owner's apply_charter_to_project call: without the explicit reset, it
-- went through, because the flag was still 'on' from the earlier call.
-- ============================================================================

create or replace function public.enforce_site_spec_field_locks()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source text;
begin
  if current_setting('eklio.bypass_field_locks', true) = 'on' then
    return new;
  end if;

  -- Checked against OLD.field_sources, never NEW: a client cannot unlock a
  -- field and change it in the same statement. Changing the lock itself is
  -- set_field_sources's job, not this trigger's, and set_field_sources never
  -- touches these columns.
  v_source := old.field_sources->>'primary_hex';
  if v_source in ('imported', 'inherited') and new.primary_hex is distinct from old.primary_hex then
    raise exception 'enforce_site_spec_field_locks: primary_hex is locked (%)', v_source;
  end if;

  v_source := old.field_sources->>'secondary_hex';
  if v_source in ('imported', 'inherited') and new.secondary_hex is distinct from old.secondary_hex then
    raise exception 'enforce_site_spec_field_locks: secondary_hex is locked (%)', v_source;
  end if;

  v_source := old.field_sources->>'accent_hex';
  if v_source in ('imported', 'inherited') and new.accent_hex is distinct from old.accent_hex then
    raise exception 'enforce_site_spec_field_locks: accent_hex is locked (%)', v_source;
  end if;

  v_source := old.field_sources->>'light_neutral_hex';
  if v_source in ('imported', 'inherited') and new.light_neutral_hex is distinct from old.light_neutral_hex then
    raise exception 'enforce_site_spec_field_locks: light_neutral_hex is locked (%)', v_source;
  end if;

  v_source := old.field_sources->>'dark_neutral_hex';
  if v_source in ('imported', 'inherited') and new.dark_neutral_hex is distinct from old.dark_neutral_hex then
    raise exception 'enforce_site_spec_field_locks: dark_neutral_hex is locked (%)', v_source;
  end if;

  v_source := old.field_sources->>'paper_hex';
  if v_source in ('imported', 'inherited') and new.paper_hex is distinct from old.paper_hex then
    raise exception 'enforce_site_spec_field_locks: paper_hex is locked (%)', v_source;
  end if;

  v_source := old.field_sources->>'heading_font';
  if v_source in ('imported', 'inherited') and new.heading_font is distinct from old.heading_font then
    raise exception 'enforce_site_spec_field_locks: heading_font is locked (%)', v_source;
  end if;

  v_source := old.field_sources->>'body_font';
  if v_source in ('imported', 'inherited') and new.body_font is distinct from old.body_font then
    raise exception 'enforce_site_spec_field_locks: body_font is locked (%)', v_source;
  end if;

  -- `logo` governs all four Storage-path columns at once — one field_sources
  -- entry for one conceptual field, per the migration that defined it.
  v_source := old.field_sources->>'logo';
  if v_source in ('imported', 'inherited') and (
       new.logo_svg_path       is distinct from old.logo_svg_path
    or new.logo_png_light_path is distinct from old.logo_png_light_path
    or new.logo_png_dark_path  is distinct from old.logo_png_dark_path
    or new.monogram_svg_path   is distinct from old.monogram_svg_path
  ) then
    raise exception 'enforce_site_spec_field_locks: logo is locked (%)', v_source;
  end if;

  return new;
end;
$$;

comment on function public.enforce_site_spec_field_locks() is
  'Rejects any write to a site_specs field whose field_sources entry is imported or inherited, unless eklio.bypass_field_locks is set for this transaction (apply_charter_to_project, import_brand_identity). Checked against OLD.field_sources so a client cannot unlock-and-write in one statement.';

revoke execute on function public.enforce_site_spec_field_locks() from public, anon, authenticated;

create trigger enforce_site_spec_field_locks
  before update on public.site_specs
  for each row execute function public.enforce_site_spec_field_locks();


-- ============================================================================
-- set_field_sources — the only sanctioned way to change field_sources itself
-- ============================================================================

create or replace function public.set_field_sources(p_site_spec_id uuid, p_sources jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_brand_kit_id uuid;
  v_old_sources  jsonb;
  v_org_id       uuid;
  v_owner_only   boolean;
begin
  select brand_kit_id, coalesce(field_sources, '{}'::jsonb)
    into v_brand_kit_id, v_old_sources
    from public.site_specs
   where id = p_site_spec_id;

  if v_brand_kit_id is null then
    raise exception 'set_field_sources: no such site_spec %', p_site_spec_id;
  end if;

  if not public.can_access_brand_kit(v_brand_kit_id) then
    raise exception 'set_field_sources: % cannot access brand kit %', auth.uid(), v_brand_kit_id;
  end if;

  if not public.validate_field_sources(p_sources) then
    raise exception 'set_field_sources: invalid field_sources payload';
  end if;

  -- Owner-only whenever a field's source ACTUALLY CHANGES and either side of
  -- that change is "inherited" — becoming inherited, or an existing
  -- inherited lock being lifted or reassigned. A true no-op (new = old,
  -- "inherited" or otherwise) is not owner-only: found necessary by actually
  -- testing a same-payload call from a clinician, which an earlier version
  -- of this check refused even though nothing was being decided.
  select bool_or(
           coalesce(p_sources->>k, '') is distinct from coalesce(v_old_sources->>k, '')
           and (coalesce(p_sources->>k, '') = 'inherited' or coalesce(v_old_sources->>k, '') = 'inherited')
         )
    into v_owner_only
    from (
      select jsonb_object_keys(v_old_sources) as k
      union
      select jsonb_object_keys(p_sources)
    ) keys;

  if coalesce(v_owner_only, false) then
    select p.organization_id into v_org_id
      from public.site_specs s
      join public.brand_kits bk on bk.id = s.brand_kit_id
      join public.projects p on p.id = bk.project_id
     where s.id = p_site_spec_id;

    if not public.is_org_owner(v_org_id) then
      raise exception 'set_field_sources: only the active org owner may set or change an inherited field source';
    end if;
  end if;

  update public.site_specs set field_sources = p_sources where id = p_site_spec_id;
end;
$$;

comment on function public.set_field_sources(uuid, jsonb) is
  'Replaces field_sources wholesale. Never touches the described columns themselves — only enforce_site_spec_field_locks locks or unlocks them. Owner-only when the change sets, lifts, or reassigns an "inherited" entry.';

revoke execute on function public.set_field_sources(uuid, jsonb) from public, anon, authenticated;
grant  execute on function public.set_field_sources(uuid, jsonb) to authenticated;


-- ============================================================================
-- apply_charter_to_project — copies the charter kit's identity onto a
-- project's site_specs, marking every copied field inherited. Idempotent.
-- ============================================================================

create or replace function public.apply_charter_to_project(p_organization_id uuid, p_project_id uuid)
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

  select * into v_charter_spec from public.site_specs where brand_kit_id = v_charter_kit_id;
  if not found then
    raise exception 'apply_charter_to_project: the charter kit has no site_specs row yet';
  end if;

  select id into v_target_kit_id from public.brand_kits where project_id = p_project_id;
  if v_target_kit_id is null then
    raise exception 'apply_charter_to_project: project % has no brand kit yet', p_project_id;
  end if;

  select id, coalesce(field_sources, '{}'::jsonb)
    into v_target_spec_id, v_new_sources
    from public.site_specs where brand_kit_id = v_target_kit_id;
  if v_target_spec_id is null then
    raise exception 'apply_charter_to_project: project % has no site_specs row yet', p_project_id;
  end if;

  v_new_sources := v_new_sources || jsonb_build_object(
    'primary_hex', 'inherited', 'secondary_hex', 'inherited', 'accent_hex', 'inherited',
    'light_neutral_hex', 'inherited', 'dark_neutral_hex', 'inherited', 'paper_hex', 'inherited',
    'heading_font', 'inherited', 'body_font', 'inherited'
  );

  -- ⚠ `set_config(..., true)` is TRANSACTION-local, not call-local — it stays
  -- 'on' for whatever else runs in the same transaction after this function
  -- returns, not just for the statement below. Found by actually testing a
  -- clinician's direct write immediately after an owner's apply_charter_to_
  -- project call in the same test transaction: it went through. Turned back
  -- off in the same statement batch, before returning, so the window is only
  -- this one UPDATE.
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

comment on function public.apply_charter_to_project(uuid, uuid) is
  'Copies the six colour roles, the typography pair and font_display_fallback from the organization''s charter kit onto the target project''s site_specs, marking each copied field inherited. Idempotent: re-applying an unchanged charter writes the same values back. Raises if the org has no charter kit or the project is not in the org.';

revoke execute on function public.apply_charter_to_project(uuid, uuid) from public, anon, authenticated;
grant  execute on function public.apply_charter_to_project(uuid, uuid) to authenticated;
