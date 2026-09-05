-- ============================================================================
-- Eklio — named colours (post-purchase-v2, Lot 3: kit header + hierarchy)
-- ============================================================================
-- `color_labels jsonb` on `site_specs`: six keys, one human name per role
-- ("Ember" next to `primary`, not instead of it). The role stays the
-- mechanism everywhere else in the product; this is only ever an additional
-- alias shown alongside it.
--
-- DETERMINISTIC, per the brief's own boundary rule ("colour tokens" carry
-- identity, so a model never names them): nearest-match against a curated
-- table of named colours, `color_names`, using the "redmean" weighted RGB
-- distance (a well-known cheap approximation of perceptual distance --
-- plain Euclidean RGB visibly favours blue too little and red too much;
-- full CIE Lab is more accurate but needs a colour-space conversion this
-- migration has no reason to carry for a cosmetic label).
--
-- SEEDED, AND KEPT IN SYNC, VIA TRIGGER, NOT VIA seed_site_spec/
-- site_spec_patch/site_spec_reset directly: all six of `primary`/`secondary`/
-- `accent`/`paper`/`light_neutral`/`dark_neutral` are in
-- `site_spec_patchable_keys()` -- she can edit any of them from the site
-- editor. A label computed once at seed time would silently go stale the
-- first time she changes a colour. A BEFORE INSERT OR UPDATE trigger
-- recomputes all six labels from whatever the row's current hex values are,
-- on every write, regardless of which function performed it -- this is
-- exactly `set_updated_at`'s own shape, applied to a different column, and
-- it means seed_site_spec, site_spec_patch and site_spec_reset need no
-- changes at all to stay correct.
-- ============================================================================

alter table public.site_specs
  add column if not exists color_labels jsonb not null default '{}'::jsonb;

comment on column public.site_specs.color_labels is
  'Six keys (primary/secondary/accent/paper/light_neutral/dark_neutral), one human colour name per role -- e.g. {"primary":"Ember"}. Computed deterministically by the site_specs_set_color_labels trigger from the row''s own hex columns; never patched directly (not in site_spec_patchable_keys()).';

-- ----------------------------------------------------------------------------
-- color_names -- the curated reference palette nearest-match runs against.
-- ----------------------------------------------------------------------------
create table public.color_names (
  name text not null,
  hex  text not null check (hex ~ '^#[0-9A-Fa-f]{6}$'),
  constraint color_names_pkey primary key (name)
);

alter table public.color_names enable row level security;

create policy "color_names_select_all"
  on public.color_names for select
  to authenticated
  using (true);

insert into public.color_names (name, hex) values
  -- Warm neutrals / earth
  ('Cream', '#F3EDE3'), ('Sand', '#E4D5BC'), ('Linen', '#EFE7DA'), ('Parchment', '#F1E7D0'),
  ('Fawn', '#D8B589'), ('Camel', '#C19A6B'), ('Latte', '#B49072'), ('Cocoa', '#7B5A44'),
  ('Espresso', '#4B3A2E'), ('Walnut', '#5C4433'), ('Umber', '#6B4A2E'), ('Bark', '#4A3B2A'),
  ('Ink', '#26211C'), ('Charcoal', '#33302C'), ('Graphite', '#4A4743'), ('Stone', '#8C8579'),
  ('Pebble', '#A79E93'), ('Ash', '#B7B0A6'), ('Fog', '#DCD7CE'), ('Chalk', '#EDEAE3'),
  -- Reds / terracottas
  ('Terracotta', '#B4653F'), ('Clay', '#B4674A'), ('Ember', '#A35D43'), ('Rust', '#8C4A2F'),
  ('Brick', '#9E4A3A'), ('Sienna', '#8F4A32'), ('Cinnamon', '#9C5B3C'), ('Paprika', '#A8482E'),
  ('Crimson', '#8C2F2F'), ('Garnet', '#6E2B2B'), ('Rosewood', '#6B3A3A'), ('Merlot', '#5C2A34'),
  ('Blush', '#D9A9A0'), ('Rose', '#C98F86'), ('Dusty Rose', '#B98077'), ('Coral', '#C97256'),
  -- Oranges / ochres
  ('Ochre', '#C08A3E'), ('Mustard', '#B8862F'), ('Amber', '#8A5A12'), ('Marigold', '#D19A3C'),
  ('Apricot', '#D89A66'), ('Tangerine', '#C97A3A'), ('Copper', '#A9683C'), ('Bronze', '#7E5A34'),
  ('Honey', '#C99A4A'), ('Caramel', '#A97438'), ('Toffee', '#8C6339'), ('Butterscotch', '#B87F3A'),
  -- Yellows
  ('Gold', '#B8963E'), ('Wheat', '#D6BC7E'), ('Straw', '#C9AF6A'), ('Butter', '#DFC888'),
  ('Saffron', '#C68A2E'), ('Citrine', '#A68A2E'),
  -- Greens
  ('Sage', '#8A9678'), ('Olive', '#6E6B3A'), ('Moss', '#5E6B44'), ('Fern', '#4F6B47'),
  ('Forest', '#385239'), ('Pine', '#2F4A3A'), ('Juniper', '#4A6357'), ('Eucalyptus', '#6E9083'),
  ('Basil', '#4A5F3A'), ('Laurel', '#3E5A3F'), ('Seafoam', '#9CC4B4'), ('Mint', '#A9D3BE'),
  ('Celadon', '#A3B69A'), ('Pistachio', '#B7C79A'), ('Willow', '#8C9B7A'),
  -- Teals / blues
  ('Teal', '#3E6E6B'), ('Deep Teal', '#2A4E4C'), ('Slate', '#4C5A63'), ('Steel', '#5C6B75'),
  ('Denim', '#3E5A73'), ('Ocean', '#2E4E63'), ('Navy', '#233A52'), ('Marine', '#2A4658'),
  ('Cerulean', '#3E7EA6'), ('Sky', '#7FA8C9'), ('Powder Blue', '#AEC9DB'), ('Mist', '#C3D3DB'),
  ('Cobalt', '#2E4E8A'), ('Indigo', '#3A3A6B'), ('Periwinkle', '#8A8ACB'),
  -- Purples
  ('Plum', '#5A3A5C'), ('Aubergine', '#3E2A3E'), ('Mauve', '#8C6B7E'), ('Heather', '#9A7E9C'),
  ('Lilac', '#B79ACB'), ('Lavender', '#C4B3D9'), ('Violet', '#6B3E7E'), ('Wine', '#5C2E42'),
  -- Pinks
  ('Peony', '#C97E8A'), ('Berry', '#8C3E5C'), ('Raspberry', '#8C2E4A'), ('Petal', '#E3C3C9'),
  -- Grays / whites
  ('Warm White', '#FAF6EE'), ('Paper', '#FBF8F3'), ('Alabaster', '#F4F1EA'), ('Mushroom', '#C9C0B4'),
  ('Taupe', '#9C8F7E'), ('Greige', '#B3A896'), ('Pewter', '#7E7A73'), ('Onyx', '#1F1D1B')
on conflict (name) do nothing;

-- ----------------------------------------------------------------------------
-- hex_rgb(hex) -- '#RRGGBB' to {r,g,b}, each 0-255. Small enough to be its
-- own function rather than inlined twice below.
-- ----------------------------------------------------------------------------
create or replace function public.hex_rgb(p_hex text)
returns int[]
language sql
immutable
set search_path = ''
as $$
  select array[
    ('x' || substr(p_hex, 2, 2))::bit(8)::int,
    ('x' || substr(p_hex, 4, 2))::bit(8)::int,
    ('x' || substr(p_hex, 6, 2))::bit(8)::int
  ]
$$;

-- ----------------------------------------------------------------------------
-- nearest_color_name(hex) -- redmean-weighted nearest match.
-- ----------------------------------------------------------------------------
create or replace function public.nearest_color_name(p_hex text)
returns text
language sql
stable
set search_path = ''
as $$
  select c.name
    from public.color_names c
   where p_hex ~ '^#[0-9A-Fa-f]{6}$'
   order by (
     select
       (2 + raw_rmean / 256) * power((public.hex_rgb(p_hex))[1] - (public.hex_rgb(c.hex))[1], 2)
       + 4 * power((public.hex_rgb(p_hex))[2] - (public.hex_rgb(c.hex))[2], 2)
       + (2 + (255 - raw_rmean) / 256) * power((public.hex_rgb(p_hex))[3] - (public.hex_rgb(c.hex))[3], 2)
     from (
       -- Unnormalized, 0-255: the two weight terms above divide by 256
       -- themselves. Do not normalize here too -- that was the original
       -- bug (black matched "Amber": the blue-channel weight silently
       -- exploded to ~257 instead of staying in the intended ~2-3 range).
       select (((public.hex_rgb(p_hex))[1] + (public.hex_rgb(c.hex))[1]) / 2.0) as raw_rmean
     ) r
   ) asc
   limit 1
$$;

-- ----------------------------------------------------------------------------
-- Trigger: keep color_labels in sync with the row's own hex columns.
-- ----------------------------------------------------------------------------
create or replace function public.site_specs_set_color_labels()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.color_labels := jsonb_build_object(
    'primary',       public.nearest_color_name(new.primary_hex),
    'secondary',     public.nearest_color_name(new.secondary_hex),
    'accent',        public.nearest_color_name(new.accent_hex),
    'paper',         public.nearest_color_name(new.paper_hex),
    'light_neutral', public.nearest_color_name(new.light_neutral_hex),
    'dark_neutral',  public.nearest_color_name(new.dark_neutral_hex)
  );
  return new;
end;
$$;

drop trigger if exists site_specs_color_labels on public.site_specs;
create trigger site_specs_color_labels
  before insert or update on public.site_specs
  for each row execute function public.site_specs_set_color_labels();

-- Backfill every existing row (there may be some from earlier real usage) --
-- the trigger only fires on future writes.
update public.site_specs set updated_at = updated_at;

-- ----------------------------------------------------------------------------
-- site_spec_envelope: add color_labels to the returned spec.
-- ----------------------------------------------------------------------------
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
      'paper',                    p_row->>'paper_hex',
      'light_neutral',            p_row->>'light_neutral_hex',
      'dark_neutral',             p_row->>'dark_neutral_hex',
      'color_labels',             coalesce(p_row->'color_labels', '{}'::jsonb),
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
      'seed_clamped',             p_row->'seed_clamped'),
    'preview',  public.site_spec_preview_model(p_row),
    'contrast', public.site_spec_contrast(p_row),
    'output',   public.site_spec_output(p_row, p_row->>'target'),
    'diff',     public.site_spec_diff(p_row),
    'etag', md5(concat_ws(':', p_row->>'brand_kit_id',
                               p_row->>'spec_version',
                               p_row->>'target',
                               coalesce(p_row->>'last_copied_spec_version', '-'),
                               public.site_output_catalog_version(),
                               coalesce(public.site_spec_voice_guide(p_row)::text, '-')))
  ) end
$$;
