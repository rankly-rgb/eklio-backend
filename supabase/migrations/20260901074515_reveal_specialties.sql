-- ============================================================================
-- Eklio — brand_kit_reveal_get carries her specialties too
-- ============================================================================
-- Follows `20260830101000_brand_kit_reveal.sql`.
--
-- The reveal's homepage mockup renders a real three-column "what I work with"
-- section — Act 2 of the ceremony, one column per specialty. `brief_preview()`
-- already resolves `project_briefs.specialty_ids` into labels for the brief's
-- own live rail, capped at two because that rail renders exactly two chips.
-- The reveal's mockup has room for three, so this is not a re-use of that
-- function, but the same resolution: labels, in the order she picked them,
-- nothing invented.
--
-- ⚠ LABELS, NOT ONE-LINE DESCRIPTIONS. `specialties.label` is capped at 24
-- characters for a chip — there is no per-specialty sentence anywhere in the
-- schema before a site spec exists (that copy is generated INTO the site
-- spec's `specialties` section only after a direction is bought). Rendering
-- a fabricated one-liner here would violate the same rule that keeps ethics
-- copy honest: nothing appears that was not actually produced. A short,
-- real label plus a designed colour treatment is the honest version of this
-- section before purchase.
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
      -- Kept in the order she picked them, capped at three: the mockup's
      -- section is a fixed three-column band, not "up to three".
      'specialties', coalesce((
        select jsonb_agg(s.label order by e.ord)
          from unnest(coalesce(v_brief.specialty_ids, array[]::text[]))
               with ordinality as e(id, ord)
          join public.specialties s on s.id = e.id
         where e.ord <= 3
      ), '[]'::jsonb)),
    'voice_guide',      v_kit.voice_guide,
    'social_templates', v_kit.social_templates,
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
  'Everything the reveal renders, in one call: practice details (now including up to three real specialty labels, in her order), the kit-level voice guide and social templates, and all three directions with a real contrast summary and ambiance_url (null unless ready for the direction''s CURRENT palette). Free — no brand_kit_entitled gate. Ownership-scoped exactly like the gated RPCs: not_found for a kit that is not the caller''s or does not exist, before anything else is checked.';


-- ============================================================================
-- DOWN
-- ============================================================================
--   Restores the prior body (20260830101000_brand_kit_reveal.sql) without the
--   `specialties` key in `practice`. Re-run that migration's CREATE OR REPLACE
--   block to roll back.
