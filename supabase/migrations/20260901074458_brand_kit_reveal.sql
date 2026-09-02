-- ============================================================================
-- Eklio — brand_kit_reveal_get: everything the reveal needs, in one call
-- ============================================================================
-- Follows `20260830100000_direction_assets.sql`.
--
-- Today the reveal reads `brand_kits` directly through PostgREST (RLS-scoped,
-- like the PDF route and the brand-kit page), plus a second query to
-- `project_briefs` for the practice name — and has no way to learn a
-- direction's contrast summary or ambiance image at all. This migration adds
-- a twelfth free-tier entry point, alongside `site_catalog`,
-- `brand_kit_entitled` and `consume_generation_credit`: one RPC, no
-- entitlement gate (the reveal stays free), that returns the practice
-- details, the kit-level voice guide and social templates, and all three
-- directions — each augmented with a real WCAG contrast summary and an
-- ambiance image URL, or null.
--
-- `loadBrandKit()` (eklio-frontend, `lib/data/brand-kit.ts`) is untouched: the
-- brand-kit page, the site page and everything else that reads a kit keep
-- reading it exactly as before. Only the reveal route's data loading is
-- meant to move onto this RPC.
-- ============================================================================


-- ============================================================================
-- 1. brand_kit_direction_palette_hash — the one hashing function, shared
-- ============================================================================
-- Called from BOTH sides of the ambiance pipeline: eklio-frontend computes
-- this before calling direction_assets_claim (so the stored palette_hash
-- means the same thing there), and brand_kit_reveal_get below computes it
-- again from the direction's CURRENT palette to decide whether a stored
-- image is still current. One function, so the two sides can never drift
-- into using different hashes for the same palette.
create or replace function public.brand_kit_direction_palette_hash(p_palette jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  -- Each key coalesced before concatenation on purpose: a bare `->>` on a
  -- missing key inside `||` returns NULL for the WHOLE string, which would
  -- hash every palette missing a role to the same value.
  select md5(
    coalesce(p_palette->>'primary',   '') || '|' ||
    coalesce(p_palette->>'secondary', '') || '|' ||
    coalesce(p_palette->>'light',     '') || '|' ||
    coalesce(p_palette->>'dark',      '') || '|' ||
    coalesce(p_palette->>'paper',     '') || '|' ||
    coalesce(p_palette->>'accent',    '')
  )
$$;

comment on function public.brand_kit_direction_palette_hash(jsonb) is
  'Deterministic hash of a direction''s palette (primary/secondary/light/dark/paper/accent). The one function both eklio-frontend (before claiming an ambiance job) and brand_kit_reveal_get (deciding whether a stored image is stale) must call — never re-derive this independently on either side.';

grant execute on function public.brand_kit_direction_palette_hash(jsonb) to authenticated, service_role;


-- ============================================================================
-- 2. brand_kit_direction_contrast — the six/seven pairs, for a direction
-- ============================================================================
-- `site_spec_contrast` does the same job for a full, paid site_spec row,
-- which carries pre-derived *_text_hex columns a direction does not have.
-- Reuses the same primitives (site_spec_text_variant, site_spec_cta_ink,
-- site_spec_contrast_ratio, site_spec_contrast_level) against the
-- direction's five-role palette instead of reimplementing any of the WCAG
-- math. No `suggested_fix`: there is no fix-contrast action for an
-- unpurchased direction, only the free site_spec has one.
create or replace function public.brand_kit_direction_contrast(p_direction jsonb)
returns jsonb
language sql
immutable
set search_path = ''
set jit = 'off'
as $$
  with tok as (
    select p_direction->'palette'->>'primary'   as primary_hex,
           p_direction->'palette'->>'secondary' as secondary_hex,
           p_direction->'palette'->>'light'     as light_hex,
           p_direction->'palette'->>'dark'      as dark_hex,
           p_direction->'palette'->>'paper'     as paper_hex,
           p_direction->'palette'->>'accent'    as accent_hex
  ),
  variants as (
    select t.*,
           public.site_spec_text_variant(t.primary_hex, t.paper_hex)   as primary_text_hex,
           public.site_spec_text_variant(t.secondary_hex, t.paper_hex) as secondary_text_hex,
           case when t.accent_hex is not null
                then public.site_spec_text_variant(t.accent_hex, t.paper_hex)
           end as accent_text_hex,
           public.site_spec_cta_ink(t.primary_hex, t.dark_hex) as cta_ink_hex
      from tok t
  ),
  defs as (
    select * from (values
      ('cta_label_on_primary',          'Button label on your primary color',   1),
      ('dark_neutral_on_paper',         'Body text on the page',                2),
      ('primary_on_paper',              'Primary color as text on the page',    3),
      ('secondary_on_paper',            'Secondary color as text on the page',  4),
      ('accent_on_paper',               'Accent color as text on the page',     5),
      ('dark_neutral_on_light_neutral', 'Body text on a tinted section',        6),
      ('paper_on_dark_neutral',         'Light text on a dark section',         7)
    ) as d(pair_id, label, ord)
  ),
  pairs as (
    select d.pair_id, d.label, d.ord,
      case d.pair_id
        when 'cta_label_on_primary'          then v.cta_ink_hex
        when 'dark_neutral_on_paper'         then v.dark_hex
        when 'primary_on_paper'              then v.primary_text_hex
        when 'secondary_on_paper'            then v.secondary_text_hex
        when 'accent_on_paper'               then v.accent_text_hex
        when 'dark_neutral_on_light_neutral' then v.dark_hex
        when 'paper_on_dark_neutral'         then v.paper_hex
      end as fg,
      case d.pair_id
        when 'cta_label_on_primary'          then v.primary_hex
        when 'dark_neutral_on_light_neutral' then v.light_hex
        when 'paper_on_dark_neutral'         then v.dark_hex
        else v.paper_hex
      end as bg
    from defs d cross join variants v
    -- Only when the direction actually carries a curated accent — A1's
    -- "+curated accent where present" is not always true.
    where d.pair_id <> 'accent_on_paper' or v.accent_hex is not null
  ),
  scored as (
    select p.*, public.site_spec_contrast_ratio(p.fg, p.bg) as ratio
      from pairs p
  )
  select jsonb_build_object(
    'pairs', (
      select coalesce(jsonb_agg(
               jsonb_build_object(
                 'pair_id', s.pair_id, 'label', s.label,
                 'fg', s.fg, 'bg', s.bg, 'ratio', s.ratio,
                 'level', public.site_spec_contrast_level(s.ratio))
               order by s.ord), '[]'::jsonb)
        from scored s),
    'worst_ratio', (select min(s.ratio) from scored s),
    'passes_aa',   (select coalesce(bool_and(s.ratio >= 4.5), false) from scored s)
  )
  where p_direction is not null
$$;

comment on function public.brand_kit_direction_contrast(jsonb) is
  'The same rendered pairs as site_spec_contrast, computed for a pre-purchase direction''s raw palette instead of a site_spec''s derived columns. Real numbers only — the frontend must never hardcode a ratio or a level.';

grant execute on function public.brand_kit_direction_contrast(jsonb) to authenticated, service_role;


-- ============================================================================
-- 3. brand_kit_reveal_get — the twelfth free-tier entry point
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

  -- Ownership before existence of anything else, same disclosure order as
  -- every gated RPC: a kit that is not hers must answer exactly like a kit
  -- that does not exist.
  if not public.brand_kit_is_owned(p_brand_kit_id) then
    return public.site_spec_error('not_found', 'No brand kit here.');
  end if;

  select * into v_kit from public.brand_kits where id = p_brand_kit_id;

  if v_kit.directions is null then
    return public.site_spec_error('not_found', 'This brand kit has no directions yet.');
  end if;

  select pr.name into v_project_name
    from public.projects pr where pr.id = v_kit.project_id;

  select pb.practice_name, pb.city, pb.state into v_brief
    from public.project_briefs pb where pb.project_id = v_kit.project_id;

  select jsonb_build_object(
    'brand_kit_id', v_kit.id,
    'practice', jsonb_build_object(
      'name',  coalesce(v_brief.practice_name, v_project_name),
      'city',  v_brief.city,
      'state', v_brief.state),
    'voice_guide',      v_kit.voice_guide,
    'social_templates', v_kit.social_templates,
    'directions', (
      select jsonb_agg(
               d.value || jsonb_build_object(
                 'contrast', public.brand_kit_direction_contrast(d.value),
                 -- NULL unless a row is ready AND was generated for THIS
                 -- exact palette. A stale hash (regenerated direction) and a
                 -- pending/claimed/failed/absent row all collapse to the
                 -- same NULL here — never distinguished, never a special
                 -- case for the frontend to get wrong.
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
  'Everything the reveal renders, in one call: practice details, the kit-level voice guide and social templates, and all three directions with a real contrast summary and ambiance_url (null unless ready for the direction''s CURRENT palette). Free — no brand_kit_entitled gate. Ownership-scoped exactly like the gated RPCs: not_found for a kit that is not the caller''s or does not exist, before anything else is checked.';

revoke execute on function public.brand_kit_reveal_get(uuid) from public, anon;
grant execute on function public.brand_kit_reveal_get(uuid) to authenticated, service_role;


-- ============================================================================
-- Guard rail — anon really cannot dial this, authenticated still can
-- ============================================================================
do $$
begin
  if has_function_privilege('anon', 'public.brand_kit_reveal_get(uuid)', 'EXECUTE') then
    raise exception 'anon can still execute brand_kit_reveal_get';
  end if;
  if not has_function_privilege('authenticated', 'public.brand_kit_reveal_get(uuid)', 'EXECUTE') then
    raise exception 'authenticated can no longer execute brand_kit_reveal_get';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   grant execute on function public.brand_kit_reveal_get(uuid) to anon;
--   drop function if exists public.brand_kit_reveal_get(uuid);
--   drop function if exists public.brand_kit_direction_contrast(jsonb);
--   drop function if exists public.brand_kit_direction_palette_hash(jsonb);
