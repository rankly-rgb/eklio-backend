-- ============================================================================
-- Eklio — lot C3: clinician_profile_completeness / organization_profile_health
-- ============================================================================
-- Field research fact: the failure mode of a practice page is staleness, not
-- absence — a profile that was complete eight months ago and has not been
-- touched since is exactly as much of a defect as one that was never filled
-- in. Both functions below say so explicitly (is_stale), not just a score.
--
-- Blocking vs non-blocking is a judgment call this migration documents
-- rather than hides: BLOCKING fields are the ones a bio page cannot do its
-- one job without (who she is, where she's licensed, how she works, who
-- with, in her own words, and — for a supervised_intern — who signs off).
-- NON-BLOCKING fields round the page out but its absence does not make the
-- page useless. See "Decisions I had to make" in the final report.
-- ============================================================================

create or replace function public.clinician_profile_completeness(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_profile          public.clinician_profiles;
  v_effective_sup    text;
  v_has_state        boolean;
  v_has_modality     boolean;
  v_has_population   boolean;
  v_blocking         text[] := '{}';
  v_non_blocking     text[] := '{}';
  v_blocking_total   int := 5;
  v_non_blocking_total int := 5;
  v_score            int;
begin
  select * into v_profile from public.clinician_profiles where id = p_profile_id;
  if not found then
    return jsonb_build_object(
      'score', 0,
      'blocking_missing', '[]'::jsonb,
      'non_blocking_missing', '[]'::jsonb,
      'is_stale', false
    );
  end if;

  select exists(select 1 from public.clinician_licensed_states s where s.profile_id = p_profile_id) into v_has_state;
  select exists(select 1 from public.clinician_modalities m where m.profile_id = p_profile_id) into v_has_modality;
  select exists(select 1 from public.clinician_populations p where p.profile_id = p_profile_id) into v_has_population;

  if v_profile.credentials is null or btrim(v_profile.credentials) = '' then
    v_blocking := array_append(v_blocking, 'credentials');
  end if;
  if not v_has_state then
    v_blocking := array_append(v_blocking, 'licensed_states');
  end if;
  if not v_has_modality then
    v_blocking := array_append(v_blocking, 'modalities');
  end if;
  if not v_has_population then
    v_blocking := array_append(v_blocking, 'populations');
  end if;
  if v_profile.philosophy_quote is null or btrim(v_profile.philosophy_quote) = '' then
    v_blocking := array_append(v_blocking, 'philosophy_quote');
  end if;

  -- A supervised_intern's effective supervisor is checked here too, even
  -- though enforce_clinician_supervisor_required() already blocks saving a
  -- profile with none: the org's default_supervisor_name can be cleared
  -- later, after the intern's own row was saved relying on it, and that
  -- write is not gated by the same trigger. This is exactly the staleness
  -- class of defect the completeness function exists to catch.
  if v_profile.status = 'supervised_intern' then
    v_blocking_total := v_blocking_total + 1;
    v_effective_sup := public.clinician_effective_supervisor(p_profile_id);
    if v_effective_sup is null or btrim(v_effective_sup) = '' then
      v_blocking := array_append(v_blocking, 'supervisor');
    end if;
  end if;

  if v_profile.outside_the_room is null or btrim(v_profile.outside_the_room) = '' then
    v_non_blocking := array_append(v_non_blocking, 'outside_the_room');
  end if;
  if v_profile.personality_note is null or btrim(v_profile.personality_note) = '' then
    v_non_blocking := array_append(v_non_blocking, 'personality_note');
  end if;
  if v_profile.session_rate_cents is null then
    v_non_blocking := array_append(v_non_blocking, 'session_rate');
  end if;
  if v_profile.booking_url is null or btrim(v_profile.booking_url) = '' then
    v_non_blocking := array_append(v_non_blocking, 'booking_url');
  end if;
  if not v_profile.photo_provided then
    v_non_blocking := array_append(v_non_blocking, 'photo');
  end if;

  v_score := round(
    100.0 * (
      (v_blocking_total - coalesce(array_length(v_blocking, 1), 0)) +
      (v_non_blocking_total - coalesce(array_length(v_non_blocking, 1), 0))
    ) / (v_blocking_total + v_non_blocking_total)
  );

  return jsonb_build_object(
    'score', v_score,
    'blocking_missing', to_jsonb(v_blocking),
    'non_blocking_missing', to_jsonb(v_non_blocking),
    'is_stale', (now() - v_profile.updated_at) > interval '180 days'
  );
end;
$$;

comment on function public.clinician_profile_completeness(uuid) is
  'Score (0-100), the blocking fields still missing, the non-blocking fields still missing, and whether the profile has gone 180 days without a write. SECURITY INVOKER: a caller who cannot read the profile via clinician_profiles RLS gets the not-found zero-state, not an error.';

revoke execute on function public.clinician_profile_completeness(uuid) from public, anon;
grant  execute on function public.clinician_profile_completeness(uuid) to authenticated;


create or replace function public.organization_profile_health(p_organization_id uuid)
returns table (
  profile_id        uuid,
  member_id         uuid,
  full_name         text,
  status            text,
  score             int,
  blocking_missing  jsonb,
  is_stale          boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    cp.id,
    cp.member_id,
    cp.full_name,
    cp.status,
    (c.result ->> 'score')::int,
    c.result -> 'blocking_missing',
    (c.result ->> 'is_stale')::boolean
  from public.clinician_profiles cp
  cross join lateral (select public.clinician_profile_completeness(cp.id) as result) c
  where cp.organization_id = p_organization_id
  order by
    jsonb_array_length(c.result -> 'blocking_missing') desc,
    (c.result ->> 'is_stale')::boolean desc,
    (c.result ->> 'score')::int asc;
$$;

comment on function public.organization_profile_health(uuid) is
  'One row per clinician_profiles row the caller can read in this organization (SECURITY INVOKER over clinician_profiles'' own RLS — an owner sees the whole practice, a clinician sees only her own row), ordered blocking-and-stale first for the practice dashboard.';

revoke execute on function public.organization_profile_health(uuid) from public, anon;
grant  execute on function public.organization_profile_health(uuid) to authenticated;
