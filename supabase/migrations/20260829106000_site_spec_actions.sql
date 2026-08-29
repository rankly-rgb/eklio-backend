-- ============================================================================
-- Eklio — the four actions: reset, switch builder, mark copied, fix contrast
-- ============================================================================
-- Follows `20260829105000_site_output_setup_sheet.sql`.
--
-- ⚠ THREE OF THE FOUR WRITE THROUGH `site_spec_patch`, ON PURPOSE. Reset,
-- switch-builder and fix-contrast all end in "change these fields of the
-- spec", which is exactly what the patch function already does — with its
-- validation, its version bump, its change marks and its 404-not-403 scoping.
-- A second write path would be a second place for all four of those to be got
-- wrong, and the one that drifts is always the one used less often.
--
-- `mark-copied` is the exception, and for a reason worth stating: it is the
-- only action that must NOT bump `spec_version`. Recording that she copied
-- version 7 while quietly making the spec version 8 would leave the banner up
-- immediately after the copy that was supposed to clear it.
-- ============================================================================


-- ============================================================================
-- 1. The seed values, extracted
-- ============================================================================
-- `seed_site_spec` computed the mapping from a chosen direction to a spec
-- inline. Reset needs the same mapping — that is what "restores from the
-- selected direction's defaults" means — so it is pulled out into one function
-- both call. Two copies of this mapping would drift, and the reset is the copy
-- nobody exercises until a therapist has already made a mess she wants undone.
--
-- Returns the product-facing key names, so the result plugs straight into
-- `site_spec_patch` without translation.
--
-- SECURITY DEFINER, like the seeder it was taken from: it reads the brief and
-- the project through the FK chain from a brand kit id. Its callers do the
-- ownership check; it is not granted to `authenticated`.

create or replace function public.site_spec_seed_values(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_dir     jsonb;
  v_brief   record;
  v_specs   text[];
  v_persona text[];
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

  return jsonb_build_object(
    -- Four of the five palette roles line up. `accent` has no source in a
    -- direction and starts as a copy of the secondary — see the seeder's
    -- header for why that is a first-render state and not a placeholder.
    'primary',       upper(v_dir->'palette'->>'primary'),
    'secondary',     upper(v_dir->'palette'->>'secondary'),
    'accent',        upper(v_dir->'palette'->>'secondary'),
    'light_neutral', upper(v_dir->'palette'->>'light'),
    'dark_neutral',  upper(v_dir->'palette'->>'dark'),

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

    -- Clamped for the reason the seeder's header gives: nothing upstream bounds
    -- a direction's overline or CTA label, and a value that fails this table's
    -- CHECK inside the AFTER trigger would roll back the direction choice.
    'hero', jsonb_build_object(
      'overline',       public.truncate_on_word_boundary(v_dir->'hero'->>'overline',  48),
      'headline',       public.truncate_on_word_boundary(v_dir->'hero'->>'headline',  90),
      'subhead',        public.truncate_on_word_boundary(v_dir->'hero'->>'subhead',   220),
      'cta_label',      public.truncate_on_word_boundary(v_dir->'hero'->>'cta_label', 28),
      'cta_target_url', null),

    'about_excerpt',
      coalesce(public.truncate_on_word_boundary(v_dir->>'about_excerpt', 600), ''),

    'pages', public.site_spec_default_pages(v_specs, v_persona),

    'practice_details', jsonb_build_object(
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

    'target', public.site_spec_default_target(p_brand_kit_id));
end
$$;

comment on function public.site_spec_seed_values(uuid) is
  'The spec a brand kit''s selected direction implies, keyed by the names site_spec_patch accepts. One source of truth for both seeding and reset.';

-- The seeder, now reading its values from that one function rather than
-- computing them a second time. Behaviour is unchanged.
create or replace function public.seed_site_spec(p_brand_kit_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_vals    jsonb;
  v_count   int;
begin
  select p.user_id into v_user_id
    from public.brand_kits bk
    join public.projects p on p.id = bk.project_id
   where bk.id = p_brand_kit_id;

  if v_user_id is null then
    raise exception
      'seed_site_spec: brand kit % does not exist, or its project has no owner.', p_brand_kit_id;
  end if;

  v_vals := public.site_spec_seed_values(p_brand_kit_id);

  -- No direction chosen yet: there are no colours and no hero, and inventing
  -- them would put a site in front of the therapist that no one designed.
  if v_vals is null then
    return 0;
  end if;

  insert into public.site_specs (
    brand_kit_id, user_id,
    primary_hex, secondary_hex, accent_hex, light_neutral_hex, dark_neutral_hex,
    type_pairing_id, heading_font, body_font, google_fonts_url,
    hero, about_excerpt, pages, practice_details, target
  )
  values (
    p_brand_kit_id, v_user_id,
    v_vals->>'primary',       v_vals->>'secondary', v_vals->>'accent',
    v_vals->>'light_neutral', v_vals->>'dark_neutral',
    v_vals->>'type_pairing_id', v_vals->>'heading_font',
    v_vals->>'body_font',       v_vals->>'google_fonts_url',
    v_vals->'hero', v_vals->>'about_excerpt',
    v_vals->'pages', v_vals->'practice_details',
    v_vals->>'target'
  )
  on conflict (brand_kit_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;


-- ============================================================================
-- 2. Reset
-- ============================================================================
-- ⚠ RESETTING ONE SCOPE MUST NOT COST HER ANOTHER. The two structural scopes
-- are deliberately not "replace the whole pages document":
--
--   * `copy` restores the default text INSIDE the structure she has built. Her
--     reordering and her enabled/disabled toggles survive.
--   * `structure` restores the default page and section layout but KEEPS the
--     copy of every section that still exists in it. Only sections the default
--     does not have lose their text, and only because there is nowhere to put
--     it.
--
-- Two things no scope touches, including `all`:
--
--   * `target`. The builder came from her brief, not from the direction, and
--     it has its own switch. Sending her back to a different product because
--     she wanted her colours back would be a surprise with a real cost.
--   * `hero.cta_target_url`. Her booking link is hers; no direction ever
--     produced it, so no reset can restore it and none should erase it.
--     `all` is the exception it has to be — see below.

create or replace function public.site_spec_reset(p_brand_kit_id uuid, p_scope text default 'all')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s      public.site_specs%rowtype;
  v      jsonb;
  patch  jsonb := '{}'::jsonb;
  pages  jsonb;
begin
  if (select auth.uid()) is null then
    return public.site_spec_error('unauthenticated', 'Sign in to edit your site spec.');
  end if;
  if not (coalesce(p_scope, '') = any (array['all', 'colors', 'typography',
                                             'copy', 'structure'])) then
    return public.site_spec_error('invalid_scope',
      'Reset all, colors, typography, copy or structure.', 'scope');
  end if;

  select * into s from public.site_specs
   where brand_kit_id = p_brand_kit_id and user_id = (select auth.uid());
  if not found then
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  v := public.site_spec_seed_values(p_brand_kit_id);
  if v is null then
    return public.site_spec_error('no_direction',
      'This brand kit has no chosen direction to reset to.');
  end if;

  if p_scope in ('all', 'colors') then
    patch := patch || jsonb_build_object(
      'primary',       v->>'primary',
      'secondary',     v->>'secondary',
      'accent',        v->>'accent',
      'light_neutral', v->>'light_neutral',
      'dark_neutral',  v->>'dark_neutral');
  end if;

  if p_scope in ('all', 'typography') then
    patch := patch || jsonb_build_object(
      'type_pairing_id',  v->'type_pairing_id',
      'heading_font',     v->>'heading_font',
      'body_font',        v->>'body_font',
      'google_fonts_url', v->>'google_fonts_url');
  end if;

  if p_scope in ('all', 'copy') then
    patch := patch || jsonb_build_object(
      -- her booking link survives; the direction never had one to restore
      'hero', jsonb_set(v->'hero', '{cta_target_url}',
                        coalesce(s.hero->'cta_target_url', 'null'::jsonb)),
      'about_excerpt',    v->>'about_excerpt',
      'practice_details', v->'practice_details');

    -- Default copy, poured back into the structure she has.
    select jsonb_agg(
             pg.value || jsonb_build_object('sections', coalesce((
               select jsonb_agg(sc.value || jsonb_build_object(
                        'fields', coalesce(d.fields, '{}'::jsonb)) order by sc.ord)
                 from jsonb_array_elements(pg.value->'sections') with ordinality as sc(value, ord)
                 left join lateral (
                   select ds.value->'fields' as fields
                     from jsonb_array_elements(v->'pages') as dp
                     cross join lateral jsonb_array_elements(dp.value->'sections') as ds
                    where dp.value->>'key' = pg.value->>'key'
                      and ds.value->>'key' = sc.value->>'key'
                    limit 1) d on true), '[]'::jsonb))
             order by pg.ord)
      into pages
      from jsonb_array_elements(s.pages) with ordinality as pg(value, ord);
    patch := patch || jsonb_build_object('pages', pages);
  end if;

  if p_scope in ('all', 'structure') then
    -- Default structure, keeping the copy of every section it still has room
    -- for. On `all` this runs after the copy branch and wins, which is correct:
    -- `all` means the default layout carrying the default copy.
    select jsonb_agg(
             dp.value || jsonb_build_object('sections', coalesce((
               select jsonb_agg(ds.value || jsonb_build_object(
                        'fields', case when p_scope = 'all' then ds.value->'fields'
                                       else coalesce(m.fields, ds.value->'fields') end)
                      order by ds.ord)
                 from jsonb_array_elements(dp.value->'sections') with ordinality as ds(value, ord)
                 left join lateral (
                   select cs.value->'fields' as fields
                     from jsonb_array_elements(s.pages) as cp
                     cross join lateral jsonb_array_elements(cp.value->'sections') as cs
                    where cp.value->>'key' = dp.value->>'key'
                      and cs.value->>'key' = ds.value->>'key'
                    limit 1) m on true), '[]'::jsonb))
             order by dp.ord)
      into pages
      from jsonb_array_elements(v->'pages') with ordinality as dp(value, ord);
    patch := patch || jsonb_build_object('pages', pages);
  end if;

  if p_scope = 'all' then
    -- `all` is the one scope that clears her free-text notes, because `all`
    -- means the spec the direction implies and that spec has none.
    patch := patch || jsonb_build_object('extra_instructions', null);
  end if;

  return public.site_spec_patch(p_brand_kit_id, patch);
end
$$;

comment on function public.site_spec_reset(uuid, text) is
  'Restore one scope of the spec from the selected direction: all, colors, typography, copy or structure. Resetting copy keeps her structure and resetting structure keeps her copy. Never touches the builder target.';


-- ============================================================================
-- 3. Switching builder
-- ============================================================================
-- A thin wrapper over the patch, which is the point: "never touches the rest
-- of the spec" is what a partial patch already guarantees, so the guarantee is
-- one implementation rather than a promise made twice. The output regenerates
-- because the envelope renders it from the row that was just written, and
-- `brand_kits.site_prompt` is refreshed by the trigger on the same write.

create or replace function public.site_spec_set_target(p_brand_kit_id uuid, p_target text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.site_spec_patch(p_brand_kit_id, jsonb_build_object('target', p_target))
$$;

comment on function public.site_spec_set_target(uuid, text) is
  'Switch the website builder the output is rendered for. Regenerates the output and touches nothing else in the spec.';


-- ============================================================================
-- 4. Mark copied
-- ============================================================================
-- ⚠ THE ONE ACTION THAT MUST NOT BUMP THE VERSION. It records that she has the
-- current output in her clipboard or her downloads folder; if it also advanced
-- the spec, the banner would come back up the instant it was cleared.
--
-- Deliberately idempotent and deliberately silent about whether it changed
-- anything: copying twice is a normal thing to do.

create or replace function public.site_output_mark_copied(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.site_specs%rowtype;
begin
  if (select auth.uid()) is null then
    return public.site_spec_error('unauthenticated', 'Sign in to edit your site spec.');
  end if;

  update public.site_specs
     set last_copied_spec_version = spec_version
   where brand_kit_id = p_brand_kit_id
     and user_id = (select auth.uid())
     and last_copied_spec_version is distinct from spec_version
   returning * into s;

  if not found then
    -- Either it is already marked at this version, or it is not hers. The
    -- second case has to answer exactly like a kit that does not exist.
    select * into s from public.site_specs
     where brand_kit_id = p_brand_kit_id and user_id = (select auth.uid());
    if not found then
      return public.site_spec_error('not_found', 'No site spec for this brand kit.');
    end if;
  end if;

  return public.site_spec_envelope(to_jsonb(s));
end
$$;

comment on function public.site_output_mark_copied(uuid) is
  'Record that the current output has been copied or downloaded: last_copied_spec_version = spec_version. Never bumps spec_version, and is idempotent.';


-- ============================================================================
-- 5. Fix contrast
-- ============================================================================
-- Takes the pair the therapist clicked and applies the hex
-- `site_spec_contrast` already offered for it. It recomputes rather than
-- trusting a value sent by the client: the spec may have moved since the panel
-- was drawn, and the corrected colour is a function of the current one.
--
-- The token it moves is the one the contrast function chose — a brand colour,
-- never the page background. See that function for why.

create or replace function public.site_spec_fix_contrast(p_brand_kit_id uuid, p_pair_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s    public.site_specs%rowtype;
  pair jsonb;
begin
  if (select auth.uid()) is null then
    return public.site_spec_error('unauthenticated', 'Sign in to edit your site spec.');
  end if;

  select * into s from public.site_specs
   where brand_kit_id = p_brand_kit_id and user_id = (select auth.uid());
  if not found then
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  select p.value into pair
    from jsonb_array_elements(public.site_spec_contrast(to_jsonb(s))->'pairs') as p
   where p.value->>'pair_id' = p_pair_id;

  if pair is null then
    return public.site_spec_error('invalid_field',
      format('"%s" is not a contrast pair we report.', p_pair_id), 'pair_id');
  end if;

  if pair->'suggested_fix' = 'null'::jsonb or pair->'suggested_fix' is null then
    -- Already readable, so there is nothing to apply. Not an error the user
    -- caused, and the envelope she gets back proves the pair passes.
    return public.site_spec_error('no_fix_needed',
      format('%s already reaches AA contrast.', pair->>'label'), 'pair_id');
  end if;

  return public.site_spec_patch(
    p_brand_kit_id,
    jsonb_build_object(pair->'suggested_fix'->>'token', pair->'suggested_fix'->>'hex'));
end
$$;

comment on function public.site_spec_fix_contrast(uuid, text) is
  'Apply the corrected hex site_spec_contrast offers for one pair. Recomputes the suggestion rather than trusting the client, and moves a brand color, never the page background.';

revoke execute on function public.site_spec_seed_values(uuid) from public, anon, authenticated;
grant  execute on function public.site_spec_seed_values(uuid)          to service_role;
grant  execute on function public.site_spec_reset(uuid, text)          to authenticated;
grant  execute on function public.site_spec_set_target(uuid, text)     to authenticated;
grant  execute on function public.site_output_mark_copied(uuid)        to authenticated;
grant  execute on function public.site_spec_fix_contrast(uuid, text)   to authenticated;


-- ============================================================================
-- 6. Guard rails
-- ============================================================================
do $$
begin
  -- Every action must refuse a caller with no identity, exactly as the patch
  -- does. As `postgres` here, `auth.uid()` is NULL — the service-role case.
  if public.site_spec_reset('00000000-0000-0000-0000-000000000000', 'all')
       ->'error'->>'code' is distinct from 'unauthenticated' then
    raise exception 'site_spec_actions: reset does not refuse a caller with no auth.uid().';
  end if;
  if public.site_output_mark_copied('00000000-0000-0000-0000-000000000000')
       ->'error'->>'code' is distinct from 'unauthenticated' then
    raise exception 'site_spec_actions: mark_copied does not refuse a caller with no auth.uid().';
  end if;
  if public.site_spec_fix_contrast('00000000-0000-0000-0000-000000000000', 'primary_on_light_neutral')
       ->'error'->>'code' is distinct from 'unauthenticated' then
    raise exception 'site_spec_actions: fix_contrast does not refuse a caller with no auth.uid().';
  end if;
  if public.site_spec_set_target('00000000-0000-0000-0000-000000000000', 'wix')
       ->'error'->>'code' is distinct from 'unauthenticated' then
    raise exception 'site_spec_actions: set_target does not refuse a caller with no auth.uid().';
  end if;

  -- An unknown scope is refused before anything is read or written.
  if public.site_spec_reset('00000000-0000-0000-0000-000000000000', 'everything')
       ->'error'->>'code' is distinct from 'unauthenticated' then
    raise exception 'site_spec_actions: the identity check must come before the scope check.';
  end if;

  -- ⚠ `site_spec_seed_values` reads a brief and a project by kit id under
  -- DEFINER rights with no ownership check of its own. It must not be callable
  -- by a client, or it is an oracle.
  if has_function_privilege('authenticated', 'public.site_spec_seed_values(uuid)', 'execute') then
    raise exception
      'site_spec_actions: site_spec_seed_values is executable by authenticated; it is an unscoped DEFINER read.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.site_spec_fix_contrast(uuid, text);
--   drop function if exists public.site_output_mark_copied(uuid);
--   drop function if exists public.site_spec_set_target(uuid, text);
--   drop function if exists public.site_spec_reset(uuid, text);
--   -- then re-create seed_site_spec() from 20260829100000, which computes its
--   -- values inline and does not call site_spec_seed_values():
--   drop function if exists public.site_spec_seed_values(uuid);
