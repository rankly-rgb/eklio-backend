-- ============================================================================
-- Eklio — lot B2: brand import intake
-- ============================================================================
-- The majority case is partial: a real practice typically has a logo and two
-- colours, no declared typography, no documented tone. A payload of two
-- fields must work exactly as well as a payload of ten — every field PRESENT
-- is written and marked imported; every field ABSENT is left untouched and
-- keeps whatever source it already had.
--
-- ⚠ `tone` IS NOT HANDLED. The brief that requested this function listed
-- `tone` among the accepted payload keys, but site_specs has no `tone`
-- column and never has — the same fact that made lot 1 exclude `tone` from
-- field_sources' own allowed-key list, for the same reason (there is nothing
-- on this table to source-track). Adding a column for it would be schema
-- scope this lot was not asked for. A `tone` key in the payload is simply
-- never read here; the Zod schema on the frontend does not accept it either.
-- ============================================================================

create or replace function public.import_brand_identity(p_project_id uuid, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id       uuid;
  v_owns_project boolean;
  v_kit_id       uuid;
  v_spec_id      uuid;
  v_sources      jsonb;
  v_touched      text[] := '{}';
  v_key          text;
  v_all_imported boolean;
begin
  select p.organization_id, (p.user_id = auth.uid())
    into v_org_id, v_owns_project
    from public.projects p
   where p.id = p_project_id;

  if v_org_id is null then
    raise exception 'import_brand_identity: no such project %', p_project_id;
  end if;

  if not (coalesce(v_owns_project, false) or public.is_org_owner(v_org_id)) then
    raise exception 'import_brand_identity: % may not import a brand identity into project %', auth.uid(), p_project_id;
  end if;

  select id into v_kit_id from public.brand_kits where project_id = p_project_id;
  if v_kit_id is null then
    raise exception 'import_brand_identity: project % has no brand kit yet', p_project_id;
  end if;

  select id, coalesce(field_sources, '{}'::jsonb)
    into v_spec_id, v_sources
    from public.site_specs where brand_kit_id = v_kit_id;
  if v_spec_id is null then
    raise exception 'import_brand_identity: project % has no site_specs row yet', p_project_id;
  end if;

  -- Strict hex, checked per key present — a payload of two fields never
  -- touches the other four.
  foreach v_key in array array[
    'primary_hex', 'secondary_hex', 'accent_hex',
    'light_neutral_hex', 'dark_neutral_hex', 'paper_hex'
  ] loop
    if p_payload ? v_key and not (p_payload->>v_key ~ '^#[0-9A-Fa-f]{6}$') then
      raise exception 'import_brand_identity: % is not a #RRGGBB hex', v_key;
    end if;
    if p_payload ? v_key then
      v_touched := v_touched || v_key;
    end if;
  end loop;

  -- Logo Storage paths — same shape check as the brand-logos bucket policies.
  foreach v_key in array array[
    'logo_svg_path', 'logo_png_light_path', 'logo_png_dark_path', 'monogram_svg_path'
  ] loop
    if p_payload ? v_key and p_payload->>v_key is not null and not (p_payload->>v_key like 'org/%') then
      raise exception 'import_brand_identity: % must start with org/', v_key;
    end if;
  end loop;
  -- array_append, not `||`: `text[] || 'logo'` (a bare untyped string
  -- literal) resolves to Postgres's array||array overload and tries to parse
  -- 'logo' as `{...}` array syntax, raising "malformed array literal" —
  -- found by actually running this function. `v_touched || v_key` above is
  -- fine because v_key is a typed text variable, not a literal.
  if p_payload ? 'logo_svg_path' or p_payload ? 'logo_png_light_path'
     or p_payload ? 'logo_png_dark_path' or p_payload ? 'monogram_svg_path' then
    v_touched := array_append(v_touched, 'logo');
  end if;

  if p_payload ? 'heading_font' then v_touched := array_append(v_touched, 'heading_font'); end if;
  if p_payload ? 'body_font'    then v_touched := array_append(v_touched, 'body_font');    end if;

  foreach v_key in array v_touched loop
    v_sources := jsonb_set(v_sources, array[v_key], '"imported"');
  end loop;

  if not public.validate_field_sources(v_sources) then
    raise exception 'import_brand_identity: the resulting field_sources payload is invalid';
  end if;

  -- ⚠ set_config(name, value, true) resets at end of TRANSACTION, not when
  -- this function returns — turned back 'off' immediately after the write,
  -- in the same statement batch. See 20260903120000_field_source_locks.sql's
  -- header for how this was found (a clinician's direct write went through
  -- later in the same test transaction, without the explicit reset).
  perform set_config('eklio.bypass_field_locks', 'on', true);

  -- Every field present is written unmodified; every field absent keeps its
  -- current column value. maintain_site_spec_text_variants (site_specs'
  -- existing BEFORE trigger, unconditional on every INSERT/UPDATE) derives
  -- the AA-contrast text variants automatically from whatever colours land
  -- here — nothing in this function computes them.
  begin
    update public.site_specs s set
      primary_hex            = coalesce(p_payload->>'primary_hex', s.primary_hex),
      secondary_hex          = coalesce(p_payload->>'secondary_hex', s.secondary_hex),
      accent_hex             = coalesce(p_payload->>'accent_hex', s.accent_hex),
      light_neutral_hex      = coalesce(p_payload->>'light_neutral_hex', s.light_neutral_hex),
      dark_neutral_hex       = coalesce(p_payload->>'dark_neutral_hex', s.dark_neutral_hex),
      paper_hex              = coalesce(p_payload->>'paper_hex', s.paper_hex),
      heading_font           = coalesce(p_payload->>'heading_font', s.heading_font),
      body_font              = coalesce(p_payload->>'body_font', s.body_font),
      font_display_fallback  = coalesce(p_payload->>'font_display_fallback', s.font_display_fallback),
      logo_svg_path          = coalesce(p_payload->>'logo_svg_path', s.logo_svg_path),
      logo_png_light_path    = coalesce(p_payload->>'logo_png_light_path', s.logo_png_light_path),
      logo_png_dark_path     = coalesce(p_payload->>'logo_png_dark_path', s.logo_png_dark_path),
      monogram_svg_path      = coalesce(p_payload->>'monogram_svg_path', s.monogram_svg_path),
      field_sources          = v_sources
    where s.id = v_spec_id;
  exception when others then
    perform set_config('eklio.bypass_field_locks', 'off', true);
    raise;
  end;

  perform set_config('eklio.bypass_field_locks', 'off', true);

  v_all_imported := (
    select bool_and(coalesce(v_sources->>k, 'generated') = 'imported')
      from unnest(array[
        'primary_hex', 'secondary_hex', 'accent_hex', 'light_neutral_hex',
        'dark_neutral_hex', 'paper_hex', 'heading_font', 'body_font', 'logo'
      ]) as k
  );

  update public.brand_kits
     set origin = case when v_all_imported then 'imported' else 'mixed' end
   where id = v_kit_id;
end;
$$;

comment on function public.import_brand_identity(uuid, jsonb) is
  'Writes any subset of the six colour hexes, heading_font, body_font, font_display_fallback, and the four logo Storage paths onto a project''s site_specs, marking each present field imported. Absent fields are untouched. Sets brand_kits.origin to imported once every tracked field is imported, else mixed. Never accepts or stores tone (no such column). Consumes no generation credit.';

revoke execute on function public.import_brand_identity(uuid, jsonb) from public, anon, authenticated;
grant  execute on function public.import_brand_identity(uuid, jsonb) to authenticated;
