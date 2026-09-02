-- ============================================================================
-- Eklio — publishing the length limits, and making the clamp visible
-- ============================================================================
-- Follows `20260829108000_site_spec_accent.sql`.
--
-- THE PRODUCT PROBLEM THIS FIXES
-- ------------------------------
-- The seeder clamps the hero on word boundaries, because nothing upstream
-- bounds a direction's overline or CTA label and an over-long value inside the
-- AFTER trigger rolls back the direction selection. That is right at the schema
-- level and wrong at the product level: **the reveal screen renders the
-- direction's full headline and the editor renders the clamped one.** She picks
-- a direction on one sentence and lands on a shorter one, with nothing on
-- screen explaining the difference.
--
-- Two changes, and they attack it from both ends:
--
--   1. `site_spec_limits()` publishes the limits into `GET /catalog`, so the
--      generator in `eklio-frontend` can bound what it writes and nothing ever
--      needs clamping in the first place. This is the real fix.
--   2. `site_specs.seed_clamped` records what the seeder shortened, so that
--      when it does happen the editor can say so. The clamp stays as the safety
--      net; it stops being silent.
--
-- ⚠ ONE THING THE FRONTEND MUST KNOW BEFORE BUILDING THE NOTE. "Restore the
-- full text" is not possible for a field that was clamped because it exceeded
-- the limit: the limit is a CHECK, and writing the original back would be
-- refused. The original is readable — it is still in
-- `brand_kits.directions[selected].hero` — so the note can SHOW her what was
-- cut and let her rewrite it to fit. It cannot save it unchanged. That is
-- exactly why change 1 matters more than change 2.
-- ============================================================================


-- ============================================================================
-- 1. site_spec_limits — read out of the constraints, not restated
-- ============================================================================
-- ⚠ THE NUMBERS ARE NOT WRITTEN HERE. Every value is extracted from the thing
-- that actually enforces it: two from `pg_get_constraintdef`, five from the
-- `prosrc` of the validators the CHECKs call. Restating them would create the
-- second copy this repo's catalog rules exist to prevent, and the copy that
-- drifts would be the one the generator trusts — so the generator would produce
-- copy that the write path then silently shortens, which is the exact bug being
-- fixed.
--
-- The guard rail at the end of this file PROBES the validators to prove each
-- extracted number is the true boundary: n passes and n+1 is refused. Extraction
-- is cheap at runtime; the proof runs at migration time and in the test suite.

create or replace function public.site_spec_limits()
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select jsonb_build_object(
    'hero_overline',  (select (substring(p.prosrc from '''overline''[^<]*<=\s*(\d+)'))::int
                         from pg_catalog.pg_proc p
                        where p.oid = 'public.site_spec_hero_lengths_valid(jsonb)'::regprocedure),
    'hero_headline',  (select (substring(p.prosrc from '''headline''[^<]*<=\s*(\d+)'))::int
                         from pg_catalog.pg_proc p
                        where p.oid = 'public.site_spec_hero_lengths_valid(jsonb)'::regprocedure),
    'hero_subhead',   (select (substring(p.prosrc from '''subhead''[^<]*<=\s*(\d+)'))::int
                         from pg_catalog.pg_proc p
                        where p.oid = 'public.site_spec_hero_lengths_valid(jsonb)'::regprocedure),
    'hero_cta_label', (select (substring(p.prosrc from '''cta_label''[^<]*<=\s*(\d+)'))::int
                         from pg_catalog.pg_proc p
                        where p.oid = 'public.site_spec_hero_lengths_valid(jsonb)'::regprocedure),

    'about_excerpt',  (select (substring(pg_catalog.pg_get_constraintdef(c.oid)
                                         from 'char_length\(about_excerpt\) <= (\d+)'))::int
                         from pg_catalog.pg_constraint c
                        where c.conrelid = 'public.site_specs'::regclass
                          and c.conname = 'site_specs_about_excerpt_check'),

    'section_text',   (select (substring(p.prosrc from 'char_length\(vals\.v #>> ''\{\}''\) > (\d+)'))::int
                         from pg_catalog.pg_proc p
                        where p.oid = 'public.site_spec_pages_lengths_valid(jsonb)'::regprocedure),

    'extra_instructions',
                      (select (substring(pg_catalog.pg_get_constraintdef(c.oid)
                                         from 'char_length\(extra_instructions\) <= (\d+)'))::int
                         from pg_catalog.pg_constraint c
                        where c.conrelid = 'public.site_specs'::regclass
                          and c.conname = 'site_specs_extra_instructions_check')
  )
$$;

comment on function public.site_spec_limits() is
  'The site spec length limits, extracted from the constraints that enforce them rather than restated. Published in GET /catalog so the generator in eklio-frontend can bound what it writes and nothing needs clamping.';


-- ============================================================================
-- 2. The catalog gains the limits
-- ============================================================================
-- Replaces the body from `20260829101000_site_spec_catalog.sql` with one key
-- added. `set jit = 'off'` is repeated deliberately: a `create or replace`
-- discards `proconfig`, and the hot-path migration's guard rail asserts it is
-- still there.

create or replace function public.site_catalog()
returns jsonb
language sql
stable
security invoker
set search_path = ''
set jit = 'off'
as $$
  select jsonb_build_object(
    'section_types', coalesce((
      select jsonb_agg(jsonb_build_object(
               'type',            st.id,
               'label',           st.label,
               'description',     st.description,
               'fields',          st.fields,
               'default_enabled', st.default_enabled,
               'allowed_pages',   to_jsonb(st.allowed_pages),
               'source',          st.source,
               'active',          st.active)
             order by st.sort_order)
        from public.section_types st), '[]'::jsonb),
    'builder_targets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',             bt.id,
               'label',          bt.label,
               'accepts_prompt', bt.accepts_prompt,
               'output_kind',    bt.output_kind,
               'docs_url',       bt.docs_url,
               'active',         bt.active)
             order by bt.sort_order)
        from public.builder_targets bt), '[]'::jsonb),
    'site_spec_limits', public.site_spec_limits()
  )
$$;


-- ============================================================================
-- 3. seed_clamped — what the seeder shortened, and by how much
-- ============================================================================
-- NULL when nothing was clamped, which is the case this feature is trying to
-- make universal. An object otherwise, keyed by the SAME field paths
-- `site_spec_patch` accepts, so the editor can put the note next to the input
-- without a mapping table.

alter table public.site_specs
  add column if not exists seed_clamped jsonb;

comment on column public.site_specs.seed_clamped is
  'What the seeder shortened to fit the length limits, as { "hero.headline": { original_length, clamped_length } }. NULL when nothing was clamped. Cleared per field as soon as she edits that field.';

create or replace function public.site_spec_seed_clamped_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'object' then false
    when p = '{}'::jsonb then false   -- "nothing was clamped" is NULL, not {}
    else not exists (
      select 1 from jsonb_each(p) as e(k, v)
      where jsonb_typeof(e.v) <> 'object'
         or jsonb_typeof(e.v->'original_length') is distinct from 'number'
         or jsonb_typeof(e.v->'clamped_length')  is distinct from 'number'
         -- a "clamp" that made the text longer, or did nothing, is a bug in the
         -- reporter rather than a note worth showing her
         or (e.v->>'clamped_length')::numeric >= (e.v->>'original_length')::numeric
    )
  end
$$;

alter table public.site_specs drop constraint if exists site_specs_seed_clamped_check;
alter table public.site_specs
  add constraint site_specs_seed_clamped_check
  check (public.site_spec_seed_clamped_valid(seed_clamped));

-- One entry, or nothing. Kept as its own function so the seeder reads as a list
-- of fields rather than a list of length arithmetic.
create or replace function public.site_spec_clamp_note(
  p_key text, p_original text, p_max int
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_original is null or char_length(p_original) <= p_max then '{}'::jsonb
    else jsonb_build_object(p_key, jsonb_build_object(
           'original_length', char_length(p_original),
           'clamped_length',
             char_length(public.truncate_on_word_boundary(p_original, p_max))))
  end
$$;


-- ============================================================================
-- 4. The seeder reports what it cut
-- ============================================================================
-- Replaces the body from `20260829108000_site_spec_accent.sql`. Only the hero
-- and about-excerpt block changes; the colour resolution delivered there is
-- carried through unchanged.

create or replace function public.site_spec_seed_values(p_brand_kit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set jit = 'off'
as $$
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

  -- ---- colours (unchanged from the accent migration) ----------------------
  v_pal := v_dir->'palette';
  select pf.primary_hex, pf.secondary_hex, pf.light_hex, pf.dark_hex
    into v_fb
    from public.palette_families pf where pf.id = 'clay_sand';

  v_primary       := coalesce(public.site_spec_palette_role(v_pal, 'primary'),       v_fb.primary_hex);
  v_secondary     := coalesce(public.site_spec_palette_role(v_pal, 'secondary'),     v_fb.secondary_hex);
  v_light_neutral := coalesce(public.site_spec_palette_role(v_pal, 'light_neutral'), v_fb.light_hex);
  v_dark_neutral  := coalesce(public.site_spec_palette_role(v_pal, 'dark_neutral'),  v_fb.dark_hex);
  v_accent := coalesce(
    public.site_spec_palette_role(v_pal, 'accent'),
    public.site_spec_derive_accent(v_primary, v_secondary, v_light_neutral));

  -- ---- copy, clamped and reported -----------------------------------------
  -- The limits come from `site_spec_limits()`, which reads them out of the
  -- constraints. The seeder cannot clamp to a number the write path disagrees
  -- with, because there is only one number.
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

    -- NULL, not {}, when nothing was cut: the editor tests one thing.
    'seed_clamped', nullif(v_clamped, '{}'::jsonb));
end
$$;

revoke execute on function public.site_spec_seed_values(uuid) from public, anon, authenticated;
grant  execute on function public.site_spec_seed_values(uuid) to service_role;

create or replace function public.seed_site_spec(p_brand_kit_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
set jit = 'off'
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

  if v_vals is null then
    return 0;
  end if;

  insert into public.site_specs (
    brand_kit_id, user_id,
    primary_hex, secondary_hex, accent_hex, light_neutral_hex, dark_neutral_hex,
    type_pairing_id, heading_font, body_font, google_fonts_url,
    hero, about_excerpt, pages, practice_details, target, seed_clamped
  )
  values (
    p_brand_kit_id, v_user_id,
    v_vals->>'primary',       v_vals->>'secondary', v_vals->>'accent',
    v_vals->>'light_neutral', v_vals->>'dark_neutral',
    v_vals->>'type_pairing_id', v_vals->>'heading_font',
    v_vals->>'body_font',       v_vals->>'google_fonts_url',
    v_vals->'hero', v_vals->>'about_excerpt',
    v_vals->'pages', v_vals->'practice_details',
    v_vals->>'target',
    case when jsonb_typeof(v_vals->'seed_clamped') = 'object'
         then v_vals->'seed_clamped' end
  )
  on conflict (brand_kit_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end
$$;

grant execute on function public.seed_site_spec(uuid) to service_role;


-- ============================================================================
-- 5. The envelope carries it, and editing a field retires its note
-- ============================================================================
-- ⚠ THE NOTE HAS TO BE SELF-DISMISSING. "We shortened this when we set it up"
-- stops being true the moment she rewrites the field herself; left standing it
-- would be a permanent banner about a decision she has already overridden. So
-- writing `hero.headline` drops the `hero.headline` entry, and only that one.

create or replace function public.site_spec_envelope(p_row jsonb)
returns jsonb
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select case when p_row is null then null else jsonb_build_object(
    'spec', jsonb_build_object(
      'brand_kit_id',             p_row->>'brand_kit_id',
      'spec_version',             (p_row->>'spec_version')::int,
      'last_copied_spec_version', (p_row->>'last_copied_spec_version')::int,
      'updated_at',               p_row->>'updated_at',
      'primary',                  p_row->>'primary_hex',
      'secondary',                p_row->>'secondary_hex',
      'accent',                   p_row->>'accent_hex',
      'light_neutral',            p_row->>'light_neutral_hex',
      'dark_neutral',             p_row->>'dark_neutral_hex',
      'type_pairing_id',          p_row->>'type_pairing_id',
      'heading_font',             p_row->>'heading_font',
      'body_font',                p_row->>'body_font',
      'google_fonts_url',         p_row->>'google_fonts_url',
      'hero',                     p_row->'hero',
      'about_excerpt',            p_row->>'about_excerpt',
      'pages',                    p_row->'pages',
      'practice_details',         p_row->'practice_details',
      'extra_instructions',       p_row->>'extra_instructions',
      'target',                   p_row->>'target',
      -- absent from the patchable key list on purpose: it is a report about
      -- what seeding did, not a field she sets
      'seed_clamped',             p_row->'seed_clamped'),
    'preview',  public.site_spec_preview_model(p_row),
    'contrast', public.site_spec_contrast(p_row),
    'output',   public.site_spec_output(p_row, p_row->>'target'),
    'diff',     public.site_spec_diff(p_row),
    'etag', md5(concat_ws(':', p_row->>'brand_kit_id',
                               p_row->>'spec_version',
                               p_row->>'target'))
  ) end
$$;

-- Which seed_clamped keys a given patch retires.
create or replace function public.site_spec_retired_clamp_keys(p_patch jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(k), array[]::text[])
    from (
      select 'hero.' || h.key as k
        from jsonb_object_keys(coalesce(p_patch->'hero', '{}'::jsonb)) as h(key)
      union all
      select 'about_excerpt' where p_patch ? 'about_excerpt'
    ) t
$$;

-- The trigger that applies it. A trigger rather than a branch inside
-- `site_spec_patch` for the same reason the site_prompt cache is one: it then
-- covers every write path — the patch, the reset, the target switch, the
-- contrast fix, and a correction made by hand with `service_role` — instead of
-- the ones whoever added it remembered.
--
-- Note that `site_spec_reset('copy')` re-applies the SAME clamped hero, so the
-- hero does not change and the note correctly survives: the text is still the
-- shortened one.

create or replace function public.retire_seed_clamp_notes()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_keys text[] := array[]::text[];
  k      text;
begin
  if new.seed_clamped is null then
    return new;
  end if;

  foreach k in array array['overline', 'headline', 'subhead', 'cta_label'] loop
    if (new.hero->>k) is distinct from (old.hero->>k) then
      v_keys := v_keys || ('hero.' || k);
    end if;
  end loop;

  if new.about_excerpt is distinct from old.about_excerpt then
    v_keys := v_keys || 'about_excerpt'::text;
  end if;

  if array_length(v_keys, 1) > 0 then
    new.seed_clamped := nullif(new.seed_clamped - v_keys, '{}'::jsonb);
  end if;

  return new;
end
$$;

drop trigger if exists retire_site_spec_clamp_notes on public.site_specs;
create trigger retire_site_spec_clamp_notes
  before update on public.site_specs
  for each row execute function public.retire_seed_clamp_notes();


grant execute on function public.site_spec_limits()                  to authenticated, service_role;
grant execute on function public.site_spec_clamp_note(text, text, int) to authenticated, service_role;
grant execute on function public.site_spec_seed_clamped_valid(jsonb) to authenticated, service_role;
grant execute on function public.site_spec_retired_clamp_keys(jsonb) to authenticated, service_role;


-- ============================================================================
-- 6. Guard rails
-- ============================================================================
do $$
declare
  lim jsonb := public.site_spec_limits();
  n   int;
begin
  -- ---- every limit was actually extracted ---------------------------------
  if exists (
    select 1 from unnest(array['hero_overline','hero_headline','hero_subhead','hero_cta_label',
                               'about_excerpt','section_text','extra_instructions']) as k(name)
     where (lim->>k.name) is null
  ) then
    raise exception
      'site_spec_limits: a limit could not be extracted from its constraint. The pattern no longer matches the source: %', lim;
  end if;

  -- ---- ⚠ AND EACH ONE IS THE TRUE BOUNDARY, PROVED BY PROBING -------------
  -- Extraction is a regex over source text. This is what stops that being a
  -- matter of trust: n must pass and n+1 must be refused, by the very validator
  -- the number was read out of.
  if not public.site_spec_hero_lengths_valid(jsonb_build_object(
       'overline', repeat('x', (lim->>'hero_overline')::int),
       'headline', repeat('x', (lim->>'hero_headline')::int),
       'subhead',  repeat('x', (lim->>'hero_subhead')::int),
       'cta_label',repeat('x', (lim->>'hero_cta_label')::int))) then
    raise exception 'site_spec_limits: a published hero limit is refused at its own value.';
  end if;

  if public.site_spec_hero_lengths_valid(jsonb_build_object(
       'overline', repeat('x', (lim->>'hero_overline')::int + 1),
       'headline','h','subhead','s','cta_label','c')) then
    raise exception 'site_spec_limits: hero_overline is published one character short of the truth.';
  end if;
  if public.site_spec_hero_lengths_valid(jsonb_build_object(
       'overline','o','headline', repeat('x', (lim->>'hero_headline')::int + 1),
       'subhead','s','cta_label','c')) then
    raise exception 'site_spec_limits: hero_headline is published one character short of the truth.';
  end if;
  if public.site_spec_hero_lengths_valid(jsonb_build_object(
       'overline','o','headline','h','subhead', repeat('x', (lim->>'hero_subhead')::int + 1),
       'cta_label','c')) then
    raise exception 'site_spec_limits: hero_subhead is published one character short of the truth.';
  end if;
  if public.site_spec_hero_lengths_valid(jsonb_build_object(
       'overline','o','headline','h','subhead','s',
       'cta_label', repeat('x', (lim->>'hero_cta_label')::int + 1))) then
    raise exception 'site_spec_limits: hero_cta_label is published one character short of the truth.';
  end if;

  -- the section-text limit, probed through the walker that enforces it
  if not public.site_spec_pages_lengths_valid(jsonb_set(
       public.site_spec_default_pages(null, null), '{1,sections,1,fields,body}',
       to_jsonb(repeat('x', (lim->>'section_text')::int)))) then
    raise exception 'site_spec_limits: section_text is refused at its own value.';
  end if;
  if public.site_spec_pages_lengths_valid(jsonb_set(
       public.site_spec_default_pages(null, null), '{1,sections,1,fields,body}',
       to_jsonb(repeat('x', (lim->>'section_text')::int + 1)))) then
    raise exception 'site_spec_limits: section_text is published one character short of the truth.';
  end if;

  -- and the two that come straight from a CHECK
  if (lim->>'about_excerpt')::int <> 600 or (lim->>'extra_instructions')::int <> 2000 then
    raise exception
      'site_spec_limits: about_excerpt/extra_instructions extracted as %/%, which no longer matches the shipped CHECKs.',
      lim->>'about_excerpt', lim->>'extra_instructions';
  end if;

  -- ---- the catalog publishes them -----------------------------------------
  if not (public.site_catalog() ? 'site_spec_limits') then
    raise exception 'site_spec_limits: GET /catalog does not carry site_spec_limits.';
  end if;
  if public.site_catalog()->'site_spec_limits' <> lim then
    raise exception 'site_spec_limits: the catalog and the extractor disagree.';
  end if;

  -- ---- the clamp reporter --------------------------------------------------
  if public.site_spec_clamp_note('hero.headline', 'short', 90) <> '{}'::jsonb then
    raise exception 'site_spec_limits: a field that fits was reported as clamped.';
  end if;
  if public.site_spec_clamp_note('hero.headline', null, 90) <> '{}'::jsonb then
    raise exception 'site_spec_limits: a missing field was reported as clamped.';
  end if;
  if (public.site_spec_clamp_note('hero.overline', repeat('overline ', 40), 48)
        ->'hero.overline'->>'original_length')::int <> 360 then
    raise exception 'site_spec_limits: the clamp note reports the wrong original length.';
  end if;
  if (public.site_spec_clamp_note('hero.overline', repeat('overline ', 40), 48)
        ->'hero.overline'->>'clamped_length')::int > 48 then
    raise exception 'site_spec_limits: the clamp note reports a clamped length over the limit.';
  end if;

  -- {} is not a legal stored value: "nothing was clamped" is NULL
  if public.site_spec_seed_clamped_valid('{}'::jsonb) then
    raise exception 'site_spec_limits: an empty clamp report was accepted; it must be NULL.';
  end if;
  if not public.site_spec_seed_clamped_valid(null) then
    raise exception 'site_spec_limits: NULL was refused as a clamp report.';
  end if;

  -- ---- the envelope --------------------------------------------------------
  if not (public.site_spec_envelope(jsonb_build_object(
            'brand_kit_id','00000000-0000-0000-0000-000000000000','spec_version',1,
            'target','lovable','primary_hex','#3B2C3A','secondary_hex','#4A5361',
            'accent_hex','#C08A3E','light_neutral_hex','#F3EDE4','dark_neutral_hex','#241B23',
            'heading_font','Fraunces','body_font','Nunito Sans',
            'google_fonts_url','https://fonts.googleapis.com/css2?family=Fraunces&display=swap',
            'about_excerpt','x','practice_details','{}'::jsonb,
            'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
            'pages', public.site_spec_default_pages(null,null),
            'change_marks','{}'::jsonb))->'spec' ? 'seed_clamped') then
    raise exception 'site_spec_limits: the envelope does not carry seed_clamped.';
  end if;

  -- ---- which keys a patch retires -----------------------------------------
  if public.site_spec_retired_clamp_keys('{"hero":{"headline":"x"}}'::jsonb)
     <> array['hero.headline'] then
    raise exception 'site_spec_limits: a hero patch does not retire its own clamp note.';
  end if;
  if public.site_spec_retired_clamp_keys('{"primary":"#000000"}'::jsonb) <> array[]::text[] then
    raise exception 'site_spec_limits: a colour patch retires a copy clamp note.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_catalog(), site_spec_envelope(), site_spec_seed_values()
--   -- and seed_site_spec() from 20260829108000 / 20260829105000 / 20260829101000,
--   -- each WITH its `set jit = 'off'` clause, then:
--   drop trigger if exists retire_site_spec_clamp_notes on public.site_specs;
--   drop function if exists public.retire_seed_clamp_notes();
--   drop function if exists public.site_spec_retired_clamp_keys(jsonb);
--   drop function if exists public.site_spec_clamp_note(text, text, int);
--   alter table public.site_specs drop constraint if exists site_specs_seed_clamped_check;
--   drop function if exists public.site_spec_seed_clamped_valid(jsonb);
--   alter table public.site_specs drop column if exists seed_clamped;
--   drop function if exists public.site_spec_limits();
