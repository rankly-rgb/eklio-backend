-- ============================================================================
-- Eklio — lot F: per-clinician setup sheet, and the stable slug it depends on
-- ============================================================================
-- Field research: a real practice runs on Squarespace + a SimplePractice
-- portal and will never migrate — Eklio hosts nothing, it delivers copy an
-- office manager pastes in. A sheet covering the whole practice at once is
-- unusable with a real seat count; this is deliberately PER CLINICIAN.
--
-- slugify_text/practice_page_title are the shared generator lot G's grid
-- proposals reuse — see 20260903160500_organization_seo_grid_proposals.sql.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. slugify_text — the slug core, generic, no clinician/organization
-- knowledge at all.
-- ---------------------------------------------------------------------------
create or replace function public.slugify_text(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    trim(both '-' from
      regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g')
    ),
    ''
  )
$$;

comment on function public.slugify_text(text) is
  'Lowercase, non-alphanumeric runs collapsed to a single hyphen, leading/trailing hyphens trimmed. NULL or an all-punctuation input yields NULL, never an empty string a caller might silently accept as a slug.';

revoke execute on function public.slugify_text(text) from public, anon;
grant  execute on function public.slugify_text(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. practice_page_title — joins labels into one title, practice name last.
-- Shared by a clinician's own page title (lot F) and a grid cell's proposed
-- title (lot G) — the same shape either way: "what the page is about | the
-- practice".
-- ---------------------------------------------------------------------------
create or replace function public.practice_page_title(p_parts text[], p_practice_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select array_to_string(
    array_remove(coalesce(p_parts, '{}'::text[]), null) || array[p_practice_name],
    ' | '
  )
$$;

revoke execute on function public.practice_page_title(text[], text) from public, anon;
grant  execute on function public.practice_page_title(text[], text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. clinician_profiles.slug — persisted once, never regenerated. A slug
-- that changed when a clinician later edited her name would silently
-- break every link and citation pointing at the old one — exactly the
-- "same clinician at two coexisting URLs" defect field research found.
-- ---------------------------------------------------------------------------
alter table public.clinician_profiles add column slug text;

alter table public.clinician_profiles
  add constraint clinician_profiles_slug_check
  check (slug is null or slug = public.slugify_text(slug));

create unique index clinician_profiles_org_slug_key
  on public.clinician_profiles (organization_id, slug)
  where slug is not null;

comment on column public.clinician_profiles.slug is
  'Set once by ensure_clinician_slug() and never regenerated, even if full_name later changes — a changed slug would silently orphan whatever URL a Squarespace page, a search index, or a citation already points at. Unique within the organization, not globally: two different practices may each have a "jane-doe".';


-- ---------------------------------------------------------------------------
-- 4. ensure_clinician_slug — lazy, idempotent, collision-safe within the
-- organization. SECURITY DEFINER: collision detection must see every
-- clinician's slug in the org, which a non-owner clinician's own RLS read
-- of clinician_profiles would not (she can only read her own row) — the
-- authorization check below is therefore explicit, not left to ambient
-- RLS.
-- ---------------------------------------------------------------------------
create or replace function public.ensure_clinician_slug(p_profile_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project_id uuid;
  v_org_id     uuid;
  v_full_name  text;
  v_existing   text;
  v_base       text;
  v_candidate  text;
  v_suffix     int := 1;
begin
  select project_id, organization_id, full_name, slug
    into v_project_id, v_org_id, v_full_name, v_existing
    from public.clinician_profiles
   where id = p_profile_id;

  if not found then
    raise exception 'ensure_clinician_slug: profile % does not exist', p_profile_id;
  end if;

  if not public.can_access_project(v_project_id) then
    raise exception 'ensure_clinician_slug: % may not act on profile %', auth.uid(), p_profile_id;
  end if;

  if v_existing is not null then
    return v_existing;
  end if;

  v_base := coalesce(public.slugify_text(v_full_name), 'clinician');
  v_candidate := v_base;

  while exists (
    select 1 from public.clinician_profiles
     where organization_id = v_org_id and slug = v_candidate and id <> p_profile_id
  ) loop
    v_suffix := v_suffix + 1;
    v_candidate := v_base || '-' || v_suffix;
  end loop;

  update public.clinician_profiles set slug = v_candidate where id = p_profile_id;

  return v_candidate;
end;
$$;

comment on function public.ensure_clinician_slug(uuid) is
  'Returns the profile''s slug, generating and persisting one on first call if it has none. Collision-safe within the organization (jane-doe, jane-doe-2, ...). Idempotent: a profile that already has a slug always gets that same value back.';

revoke execute on function public.ensure_clinician_slug(uuid) from public, anon;
grant  execute on function public.ensure_clinician_slug(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. clinician_setup_sheet — the actual sheet. SECURITY INVOKER: the
-- caller must already be able to read the profile (can_access_project via
-- clinician_profiles' own RLS — owner or the clinician herself), same
-- bound as every other clinician_profiles read in this lot.
--
-- No AI-generated copy anywhere in this function — the bio section is the
-- clinician's own philosophy_quote/outside_the_room/personality_note,
-- verbatim, the same "her own words" principle lot D5 was built on. No
-- brand/colour/font fields either: an office manager pasting into an
-- existing Squarespace theme needs copy, not hex codes.
-- ---------------------------------------------------------------------------
create or replace function public.clinician_setup_sheet(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_profile      public.clinician_profiles;
  v_org_name     text;
  v_slug         text;
  v_states       text;
  v_modalities   text;
  v_populations  text;
  v_completeness jsonb;
  v_blocking     jsonb;
  v_steps        jsonb := '[]'::jsonb;
  v_n            int := 0;
  v_title        text;
  v_description  text;
begin
  select * into v_profile from public.clinician_profiles where id = p_profile_id;
  if not found then
    raise exception 'clinician_setup_sheet: profile % not found or not accessible', p_profile_id;
  end if;

  select name into v_org_name from public.organizations where id = v_profile.organization_id;

  v_completeness := public.clinician_profile_completeness(p_profile_id);
  v_blocking := coalesce(v_completeness->'blocking_missing', '[]'::jsonb);

  v_slug := public.ensure_clinician_slug(p_profile_id);

  select string_agg(s.name, ', ' order by s.name)
    into v_states
    from public.clinician_licensed_states cls
    join public.us_states s on s.code = cls.state_code
   where cls.profile_id = p_profile_id;

  select string_agg(mc.label, ', ' order by mc.sort_order)
    into v_modalities
    from public.clinician_modalities cm
    join public.modality_cards mc on mc.id = cm.modality_id
   where cm.profile_id = p_profile_id;

  select string_agg(pc.label, ', ' order by pc.sort_order)
    into v_populations
    from public.clinician_populations cp
    join public.population_cards pc on pc.id = cp.population_id
   where cp.profile_id = p_profile_id;

  v_title := public.practice_page_title(
    array[nullif(trim(coalesce(v_profile.full_name, '') || case when v_profile.credentials is not null then ', ' || v_profile.credentials else '' end), '')],
    coalesce(v_org_name, 'the practice')
  );

  v_description := trim(both ' ' from concat_ws(' ',
    nullif(v_profile.full_name, ''),
    case when v_modalities is not null then 'offers ' || v_modalities else null end,
    case when v_populations is not null then 'for ' || v_populations else null end,
    case when v_states is not null then 'in ' || v_states || '.' else null end
  ));

  -- Every step below is included only when it has something to show — an
  -- incomplete profile produces a shorter sheet, not placeholder rows. The
  -- blocking list above is where "still needed" lives.

  v_n := v_n + 1;
  v_steps := v_steps || jsonb_build_array(jsonb_build_object(
    'number', v_n, 'title', 'Page title', 'value', v_title,
    'builder_hint', 'Page settings › SEO title'
  ));

  v_n := v_n + 1;
  v_steps := v_steps || jsonb_build_array(jsonb_build_object(
    'number', v_n, 'title', 'URL slug', 'value', v_slug,
    'warning', 'Use this exact slug for this clinician''s page. Creating a second page under a different URL for the same person splits her search visibility between two competing pages — Eklio has seen this happen at a real practice.',
    'builder_hint', 'Page settings › URL slug'
  ));

  v_n := v_n + 1;
  v_steps := v_steps || jsonb_build_array(jsonb_build_object(
    'number', v_n, 'title', 'Meta title', 'value', v_title,
    'builder_hint', 'Page settings › SEO › Meta title'
  ));

  if v_description <> '' then
    v_n := v_n + 1;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'number', v_n, 'title', 'Meta description', 'value', v_description,
      'builder_hint', 'Page settings › SEO › Meta description'
    ));
  end if;

  if v_profile.philosophy_quote is not null and btrim(v_profile.philosophy_quote) <> '' then
    v_n := v_n + 1;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'number', v_n, 'title', 'Bio copy',
      'value', trim(both E'\n' from concat_ws(E'\n\n',
        v_profile.philosophy_quote,
        nullif(btrim(coalesce(v_profile.outside_the_room, '')), ''),
        nullif(btrim(coalesce(v_profile.personality_note, '')), '')
      )),
      'builder_hint', 'Page body › About/Bio section'
    ));
  end if;

  if v_profile.credentials is not null and btrim(v_profile.credentials) <> '' then
    v_n := v_n + 1;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'number', v_n, 'title', 'Credentials', 'value', v_profile.credentials,
      'builder_hint', 'Page body › Credentials line'
    ));
  end if;

  if v_states is not null then
    v_n := v_n + 1;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'number', v_n, 'title', 'Licensed in', 'value', v_states,
      'builder_hint', 'Page body › Licensure line'
    ));
  end if;

  if v_modalities is not null then
    v_n := v_n + 1;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'number', v_n, 'title', 'Modalities', 'value', v_modalities,
      'builder_hint', 'Page body › How I work'
    ));
  end if;

  if v_populations is not null then
    v_n := v_n + 1;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'number', v_n, 'title', 'Who she works with', 'value', v_populations,
      'builder_hint', 'Page body › Who I work with'
    ));
  end if;

  if v_profile.rate_is_public and v_profile.session_rate_cents is not null then
    v_n := v_n + 1;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'number', v_n, 'title', 'Rate',
      'value', '$' || to_char(v_profile.session_rate_cents / 100.0, 'FM999999990.00') || ' / session',
      'builder_hint', 'Page body › Rate line'
    ));
  end if;

  if v_profile.booking_url is not null and btrim(v_profile.booking_url) <> '' then
    v_n := v_n + 1;
    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'number', v_n, 'title', 'Booking link', 'value', v_profile.booking_url,
      'builder_hint', 'Page body › Booking button URL'
    ));
  end if;

  v_n := v_n + 1;
  v_steps := v_steps || jsonb_build_array(jsonb_build_object(
    'number', v_n, 'title', 'Photo',
    'value', case when v_profile.photo_provided
                  then 'Required — a photo is on file with the practice.'
                  else 'Required — no photo on file yet. Get one before publishing.'
             end,
    'builder_hint', 'Page body › Headshot'
  ));

  return jsonb_build_object(
    'kind', 'clinician_setup_sheet',
    'profile_id', p_profile_id,
    'full_name', v_profile.full_name,
    'slug', v_slug,
    'blocking', v_blocking,
    'steps', v_steps
  );
end;
$$;

comment on function public.clinician_setup_sheet(uuid) is
  'One clinician''s Squarespace/SimplePractice-ready setup sheet: numbered steps, each present only when it has data. blocking (from clinician_profile_completeness) lists what is still missing, at the top, rather than the sheet silently omitting those sections with no explanation.';

revoke execute on function public.clinician_setup_sheet(uuid) from public, anon;
grant  execute on function public.clinician_setup_sheet(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. organization_setup_sheet_rows — the practice-level CSV source. Same
-- SECURITY INVOKER scoping as organization_profile_health: an owner sees
-- every clinician, a clinician sees only her own row.
-- ---------------------------------------------------------------------------
create or replace function public.organization_setup_sheet_rows(p_organization_id uuid)
returns table (
  profile_id    uuid,
  full_name     text,
  slug          text,
  credentials   text,
  status        text,
  states        text,
  modalities    text,
  populations   text,
  rate_public   text,
  booking_url   text,
  photo_ready   boolean,
  blocking      jsonb
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  return query
  select
    cp.id,
    cp.full_name,
    public.ensure_clinician_slug(cp.id),
    cp.credentials,
    cp.status,
    (select string_agg(s.name, ', ' order by s.name)
       from public.clinician_licensed_states cls
       join public.us_states s on s.code = cls.state_code
      where cls.profile_id = cp.id),
    (select string_agg(mc.label, ', ' order by mc.sort_order)
       from public.clinician_modalities cm
       join public.modality_cards mc on mc.id = cm.modality_id
      where cm.profile_id = cp.id),
    (select string_agg(pc.label, ', ' order by pc.sort_order)
       from public.clinician_populations cpop
       join public.population_cards pc on pc.id = cpop.population_id
      where cpop.profile_id = cp.id),
    case when cp.rate_is_public and cp.session_rate_cents is not null
         then '$' || to_char(cp.session_rate_cents / 100.0, 'FM999999990.00')
         else null end,
    cp.booking_url,
    cp.photo_provided,
    coalesce((public.clinician_profile_completeness(cp.id))->'blocking_missing', '[]'::jsonb)
  from public.clinician_profiles cp
  where cp.organization_id = p_organization_id
  order by cp.full_name;
end;
$$;

comment on function public.organization_setup_sheet_rows(uuid) is
  'One row per clinician_profiles row the caller can read in this organization — the source for the practice-level CSV an office manager works through in a batch. Same visibility rule as organization_profile_health.';

revoke execute on function public.organization_setup_sheet_rows(uuid) from public, anon;
grant  execute on function public.organization_setup_sheet_rows(uuid) to authenticated;
