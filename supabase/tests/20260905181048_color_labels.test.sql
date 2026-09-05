-- ============================================================================
-- Tests — 20260905181048_color_labels.sql
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- hex_rgb: exact byte decomposition.
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.hex_rgb('#B4674A') = array[180, 103, 74],
         format('expected [180,103,74], got %s', public.hex_rgb('#B4674A'));
  assert public.hex_rgb('#000000') = array[0, 0, 0], 'black should decode to zeros';
  assert public.hex_rgb('#FFFFFF') = array[255, 255, 255], 'white should decode to 255s';
end
$$;

-- ---------------------------------------------------------------------------
-- nearest_color_name: an exact match in the table returns itself; a near
-- miss returns something plausible, not null, not an error.
-- ---------------------------------------------------------------------------
do $$
declare
  v_name text;
begin
  -- Terracotta is seeded verbatim.
  v_name := public.nearest_color_name('#B4653F');
  assert v_name = 'Terracotta', format('expected an exact seed match to return itself, got %s', v_name);

  -- A colour one bit off Terracotta should still land on something close,
  -- not null.
  v_name := public.nearest_color_name('#B5653F');
  assert v_name is not null, 'a near-miss must still return a name';

  -- Pure black is closest to Onyx or Ink among the seeded set -- either is
  -- a defensible nearest match; the real assertion is that it's not null
  -- and not an arbitrary far-away hue.
  v_name := public.nearest_color_name('#000000');
  assert v_name in ('Onyx', 'Ink', 'Espresso', 'Charcoal'),
         format('expected black to match a dark neutral, got %s', v_name);
end
$$;

-- ---------------------------------------------------------------------------
-- The trigger: color_labels is computed on insert, and recomputed on an
-- update that changes a hex column -- proving the "never goes stale after
-- an edit" property the migration exists for.
-- ---------------------------------------------------------------------------
do $$
declare
  v_user uuid := 'aaaaaaaa-0000-0000-0000-000000000071';
  v_kit  uuid := 'cccccccc-0000-0000-0000-000000000071';
  v_labels jsonb;
begin
  insert into auth.users (id, email) values (v_user, 'owner71@example.com');
  insert into public.projects (id, user_id, name)
    values ('bbbbbbbb-0000-0000-0000-000000000071', v_user, 'Elm & Ember');
  insert into public.brand_kits (id, project_id) values (v_kit, 'bbbbbbbb-0000-0000-0000-000000000071');

  insert into public.site_specs (
    brand_kit_id, user_id,
    primary_hex, secondary_hex, accent_hex, light_neutral_hex, dark_neutral_hex, paper_hex,
    type_pairing_id, heading_font, body_font, google_fonts_url,
    hero, about_excerpt, pages, practice_details, target
  ) values (
    v_kit, v_user,
    '#B4653F', '#C08A3E', '#6E3320', '#F4EEE3', '#26211C', '#FAF6EE',
    'fraunces_nunito', 'Fraunces', 'Nunito Sans', 'https://fonts.googleapis.com/css2?family=Fraunces',
    '{"overline":"","headline":"","subhead":"","cta_label":"","cta_target_url":null}'::jsonb,
    '',
    '[{"key":"home","label":"Home","enabled":true,"sections":[
       {"key":"hero","type":"hero","order":1,"enabled":true,"fields":{}}
     ]}]'::jsonb,
    '{}'::jsonb, 'generic'
  );

  select color_labels into v_labels from public.site_specs where brand_kit_id = v_kit;
  assert v_labels ->> 'primary' = 'Terracotta',
         format('expected primary to be labeled Terracotta on insert, got %s', v_labels ->> 'primary');
  assert (v_labels ? 'secondary') and (v_labels ? 'accent') and (v_labels ? 'paper')
     and (v_labels ? 'light_neutral') and (v_labels ? 'dark_neutral'),
         format('expected all six keys present, got %s', v_labels);

  -- Edit primary directly (bypassing site_spec_patch, which isn't under
  -- test here) -- the trigger must still recompute, proving it's keyed off
  -- the row's own columns, not off which RPC wrote them.
  update public.site_specs set primary_hex = '#2E4E8A' where brand_kit_id = v_kit;

  select color_labels into v_labels from public.site_specs where brand_kit_id = v_kit;
  assert v_labels ->> 'primary' = 'Cobalt',
         format('expected primary to be relabeled Cobalt after the edit, got %s', v_labels ->> 'primary');
end
$$;

-- ---------------------------------------------------------------------------
-- site_spec_envelope surfaces color_labels alongside the hex values, never
-- instead of them.
-- ---------------------------------------------------------------------------
do $$
declare
  v_kit uuid := 'cccccccc-0000-0000-0000-000000000071';
  v_row jsonb;
  v_envelope jsonb;
begin
  select to_jsonb(s) into v_row from public.site_specs s where s.brand_kit_id = v_kit;
  v_envelope := public.site_spec_envelope(v_row);

  assert v_envelope -> 'spec' ->> 'primary' = '#2E4E8A',
         'the role''s hex value must still be present';
  assert v_envelope -> 'spec' -> 'color_labels' ->> 'primary' = 'Cobalt',
         format('expected color_labels.primary = Cobalt in the envelope, got %s',
                v_envelope -> 'spec' -> 'color_labels');
end
$$;

-- ---------------------------------------------------------------------------
-- color_names is readable by any signed-in user (it describes the naming
-- system, not anyone's data) but not writable by a client.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000071"}';
  select count(*) into v_count from public.color_names;
  assert v_count > 50, format('expected a real curated palette, got %s rows', v_count);

  begin
    insert into public.color_names (name, hex) values ('Fake', '#123456');
    assert false, 'a client insert into color_names must be refused';
  exception
    when others then null;
  end;
end
$$;

rollback;
