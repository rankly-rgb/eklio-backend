-- ============================================================================
-- The brief holds her name. The spec wrote NULL over it.
-- ============================================================================
-- `site_spec_seed_values` built `practice_details` with
--
--   'practitioner_name', null,
--
-- as a literal, while `project_briefs.data->>'practitioner_name'` held
-- "Nora Whitfield" — typed by her, in step 1, before anything else existed.
--
-- The cost was not cosmetic. `practitioner_name` feeds the site's footer, the
-- contact block and the JSON-LD `founder`, and the launch step's builder prompt
-- emits `[PRACTITIONER_NAME]` when it is missing — so the product asked her to
-- supply, by hand, in a prompt, a value it had been storing all along. One of
-- four placeholders on a real kit, for a column that was never read.
--
-- ⚠ WHY THE SEED WAS NOT SIMPLY WRONG. `practice_details.practitioner_name`
-- arrived AFTER the rest of the object (the frontend still renders it under
-- condition of key presence, see `lib/site/details.ts`). The seed was written
-- when there was nothing to read, and nothing came back to connect it when the
-- brief gained the field. That is the join-that-was-never-made shape, again.
--
-- Two changes, and the second is why this file is not one line:
--
--   1. the seed reads the brief;
--   2. every spec ALREADY SEEDED keeps its NULL for ever otherwise — the seed
--      runs once, at creation. So existing rows are backfilled, and ONLY where
--      the field is still empty: a name she has since typed into Settings or
--      the site editor is hers and is never overwritten.
-- ============================================================================

create or replace function public.site_spec_seed_values(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
set jit to 'off'
as $function$
declare
  v_project uuid;
  v_dir     jsonb;
  v_brief   record;
  v_specs   text[];
  v_persona text[];
  v_pal     jsonb;
  v_fb      record;
  v_lim     jsonb;
  v_clamped jsonb := '{}'::jsonb;
  v_primary       text;
  v_secondary     text;
  v_accent        text;
  v_light_neutral text;
  v_dark_neutral  text;
  v_paper         text;
begin
  select p.id into v_project
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;
  if v_project is null then
    return null;
  end if;

  select d.value into v_dir
    from public.brand_kits bk
    cross join lateral jsonb_array_elements(bk.directions) as d
   where bk.id = p_brand_kit_id
     and bk.selected_direction_id is not null
     and d.value->>'id' = bk.selected_direction_id;
  if v_dir is null then
    return null;
  end if;

  select * into v_brief from public.project_briefs pb where pb.project_id = v_project;

  select array_agg(s.label order by e.ord) into v_specs
    from unnest(coalesce(v_brief.specialty_ids, array[]::text[])) with ordinality as e(id, ord)
    join public.specialties s on s.id = e.id;

  select array_agg(c.label order by e.ord) into v_persona
    from unnest(coalesce(v_brief.client_persona_ids, array[]::text[])) with ordinality as e(id, ord)
    join public.client_persona_cards c on c.id = e.id;

  v_pal := v_dir->'palette';
  select pf.primary_hex, pf.secondary_hex, pf.light_hex, pf.dark_hex, pf.paper_hex, pf.accent_hex
    into v_fb
    from public.palette_families pf where pf.id = 'clay_sand';

  v_primary       := coalesce(public.site_spec_palette_role(v_pal, 'primary'),       v_fb.primary_hex);
  v_secondary     := coalesce(public.site_spec_palette_role(v_pal, 'secondary'),     v_fb.secondary_hex);
  v_light_neutral := coalesce(public.site_spec_palette_role(v_pal, 'light_neutral'), v_fb.light_hex);
  v_dark_neutral  := coalesce(public.site_spec_palette_role(v_pal, 'dark_neutral'),  v_fb.dark_hex);
  v_paper         := coalesce(public.site_spec_palette_role(v_pal, 'paper'),         v_fb.paper_hex);
  v_accent := coalesce(
    public.site_spec_palette_role(v_pal, 'accent'),
    public.site_spec_curated_accent(v_pal),
    public.site_spec_derive_accent(v_primary, v_secondary, v_paper));

  v_lim := public.site_spec_limits();

  v_clamped := v_clamped
    || public.site_spec_clamp_note('hero.overline',  v_dir->'hero'->>'overline',  (v_lim->>'hero_overline')::int)
    || public.site_spec_clamp_note('hero.headline',  v_dir->'hero'->>'headline',  (v_lim->>'hero_headline')::int)
    || public.site_spec_clamp_note('hero.subhead',   v_dir->'hero'->>'subhead',   (v_lim->>'hero_subhead')::int)
    || public.site_spec_clamp_note('hero.cta_label', v_dir->'hero'->>'cta_label', (v_lim->>'hero_cta_label')::int)
    || public.site_spec_clamp_note('about_excerpt',  v_dir->>'about_excerpt',     (v_lim->>'about_excerpt')::int);

  return jsonb_build_object(
    'primary',       v_primary,
    'secondary',     v_secondary,
    'accent',        v_accent,
    'light_neutral', v_light_neutral,
    'dark_neutral',  v_dark_neutral,
    'paper',         v_paper,

    'type_pairing_id',
      (select tp.id from public.type_pairings tp
        where tp.heading_font = v_dir->'typography'->>'heading_font'
          and tp.body_font    = v_dir->'typography'->>'body_font'
        order by tp.sort_order limit 1),
    'heading_font',
      coalesce(nullif(btrim(v_dir->'typography'->>'heading_font'), ''), 'Fraunces'),
    'body_font',
      coalesce(nullif(btrim(v_dir->'typography'->>'body_font'), ''), 'Nunito Sans'),
    'google_fonts_url',
      coalesce(nullif(btrim(v_dir->'typography'->>'google_fonts_url'), ''),
               (select tp.google_fonts_url from public.type_pairings tp
                 where tp.id = 'fraunces_nunito')),

    'hero', jsonb_build_object(
      'overline',       public.truncate_on_word_boundary(v_dir->'hero'->>'overline',  (v_lim->>'hero_overline')::int),
      'headline',       public.truncate_on_word_boundary(v_dir->'hero'->>'headline',  (v_lim->>'hero_headline')::int),
      'subhead',        public.truncate_on_word_boundary(v_dir->'hero'->>'subhead',   (v_lim->>'hero_subhead')::int),
      'cta_label',      public.truncate_on_word_boundary(v_dir->'hero'->>'cta_label', (v_lim->>'hero_cta_label')::int),
      'cta_target_url', null),

    'about_excerpt',
      coalesce(public.truncate_on_word_boundary(v_dir->>'about_excerpt', (v_lim->>'about_excerpt')::int), ''),

    'pages', public.site_spec_default_pages(v_specs, v_persona),

    'practice_details', jsonb_build_object(
      -- ⚠ THE ONE CHANGE. She typed this in step 1 of the brief; it lived in
      -- `project_briefs.data` and the seed wrote a literal null over it.
      'practitioner_name', nullif(btrim(v_brief.data->>'practitioner_name'), ''),
      'practice_name',  coalesce(nullif(btrim(v_brief.practice_name), ''),
                                 (select nullif(btrim(p.name), '') from public.projects p
                                   where p.id = v_project)),
      'license_label',  (select lt.label from public.license_types lt
                          where lt.id = v_brief.license_type_id),
      'license_number', null,
      'city',           nullif(btrim(v_brief.city), ''),
      'state',          nullif(btrim(v_brief.state), ''),
      'email',          null,
      'phone',          null),

    'target', public.site_spec_default_target(p_brand_kit_id),
    'seed_clamped', nullif(v_clamped, '{}'::jsonb));
end
$function$;

-- ── The rows already seeded ────────────────────────────────────────────────
-- The seed runs once, at creation, so fixing it fixes nobody who already has a
-- spec. ⚠ ONLY WHERE IT IS STILL EMPTY: a name she has since typed into
-- Settings or the site editor is hers, and this must never overwrite it.
update public.site_specs s
   set practice_details = s.practice_details
                          || jsonb_build_object('practitioner_name',
                                                nullif(btrim(b.data->>'practitioner_name'), '')),
       updated_at = now()
  from public.brand_kits bk
  join public.project_briefs b on b.project_id = bk.project_id
 where bk.id = s.brand_kit_id
   and nullif(btrim(s.practice_details->>'practitioner_name'), '') is null
   and nullif(btrim(b.data->>'practitioner_name'), '') is not null;
