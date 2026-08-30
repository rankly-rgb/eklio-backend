-- ============================================================================
-- Eklio — brand_kit_reveal_get carries practitioner_line
-- ============================================================================
-- Follows `20260830102000_reveal_specialties.sql`.
--
-- Act 2's cascade renders a business-card component (practice name,
-- practitioner line, thin primary rule) and the fourth social template is
-- the "signature story", which already takes a `practitionerLine` prop in
-- `<BrandPreview variant="social">` (used today only on the brand-kit page,
-- which reads `brand_kits.practitioner_line` directly). The reveal had no
-- way to reach that column at all. Kit-level, like `voice_guide` and
-- `social_templates` — not per-direction, and not composed here: the
-- contract is explicit that this string is written once
-- (`practitioner_line`, e.g. "Nora Whitfield, LCSW") and never re-assembled
-- from parts on the read side.
-- ============================================================================

create or replace function public.brand_kit_reveal_get(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
declare
  v_kit          public.brand_kits%rowtype;
  v_project_name text;
  v_brief        record;
  v_result       jsonb;
begin
  if (select auth.uid()) is null then
    return public.site_spec_error('unauthenticated', 'Sign in to see your directions.');
  end if;

  if not public.brand_kit_is_owned(p_brand_kit_id) then
    return public.site_spec_error('not_found', 'No brand kit here.');
  end if;

  select * into v_kit from public.brand_kits where id = p_brand_kit_id;

  if v_kit.directions is null then
    return public.site_spec_error('not_found', 'This brand kit has no directions yet.');
  end if;

  select pr.name into v_project_name
    from public.projects pr where pr.id = v_kit.project_id;

  select pb.practice_name, pb.city, pb.state, pb.specialty_ids into v_brief
    from public.project_briefs pb where pb.project_id = v_kit.project_id;

  select jsonb_build_object(
    'brand_kit_id', v_kit.id,
    'practice', jsonb_build_object(
      'name',  coalesce(v_brief.practice_name, v_project_name),
      'city',  v_brief.city,
      'state', v_brief.state,
      'specialties', coalesce((
        select jsonb_agg(s.label order by e.ord)
          from unnest(coalesce(v_brief.specialty_ids, array[]::text[]))
               with ordinality as e(id, ord)
          join public.specialties s on s.id = e.id
         where e.ord <= 3
      ), '[]'::jsonb)),
    'practitioner_line', v_kit.practitioner_line,
    'voice_guide',       v_kit.voice_guide,
    'social_templates',  v_kit.social_templates,
    'directions', (
      select jsonb_agg(
               d.value || jsonb_build_object(
                 'contrast', public.brand_kit_direction_contrast(d.value),
                 'ambiance_url', (
                   select da.url
                     from public.direction_assets da
                    where da.brand_kit_id = v_kit.id
                      and da.direction_index = d.ord - 1
                      and da.kind = 'ambiance'
                      and da.status = 'ready'
                      and da.palette_hash = public.brand_kit_direction_palette_hash(d.value->'palette')
                 ))
               order by d.ord)
        from jsonb_array_elements(v_kit.directions) with ordinality as d(value, ord)
    )
  ) into v_result;

  return v_result;
end
$$;

comment on function public.brand_kit_reveal_get(uuid) is
  'Everything the reveal renders, in one call: practice details (name/city/state/up to three specialty labels), practitioner_line and the kit-level voice guide and social templates, and all three directions with a real contrast summary and ambiance_url (null unless ready for the direction''s CURRENT palette). Free — no brand_kit_entitled gate. Ownership-scoped exactly like the gated RPCs: not_found for a kit that is not the caller''s or does not exist, before anything else is checked.';


-- ============================================================================
-- DOWN
-- ============================================================================
--   Restores the prior body (20260830102000_reveal_specialties.sql) without
--   the `practitioner_line` key. Re-run that migration's CREATE OR REPLACE
--   block to roll back.
