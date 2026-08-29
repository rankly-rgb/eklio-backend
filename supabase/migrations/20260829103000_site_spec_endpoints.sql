-- ============================================================================
-- Eklio — reading and editing the site spec
-- ============================================================================
-- Follows `20260829102000_site_spec_preview_and_contrast.sql`.
--
-- WHERE THE HTTP SURFACE IS
-- -------------------------
-- In `eklio-frontend`, as the README requires, and it is thin on purpose. This
-- file delivers the two calls the product spec names as `GET` and `PATCH
-- /brand-kits/:id/site-spec`; the route handler authenticates, forwards the
-- user's JWT, calls one function and returns what it gets. Nothing in here
-- needs a runtime, a clock, an HTTP client or an LLM, so by the README's own
-- test none of it belongs on the other side of the line.
--
-- ⚠ CALL THESE WITH THE USER'S JWT, NEVER WITH `service_role`. `auth.uid()` is
-- what scopes them, and it is NULL for a service-role connection — a
-- service-role call gets `unauthenticated`, not somebody's spec. That is the
-- same contract `brief_preview` and `calendar_summary` already have.
--
-- ONE ROUND TRIP PER EDIT
-- -----------------------
-- `PATCH` returns the same envelope as `GET`, so an autosave keystroke costs
-- exactly one call and the editor never has to re-fetch to redraw the mockup,
-- the contrast panel or the staleness banner. That is also why the envelope is
-- assembled in SQL: four separate round trips would each pay the RLS
-- evaluation again, and there would be moments where the mockup and the
-- contrast report described different specs.
--
-- ⚠ `output` IS NOT IN THE ENVELOPE YET. `site_spec_output()` is delivered in
-- the next migration, which replaces `site_spec_envelope()` to add it — the
-- delivery order puts the endpoints before the renderer. The key is absent
-- rather than null in this migration so that nothing reads it and gets a lie.
-- ============================================================================


-- ============================================================================
-- 1. Errors
-- ============================================================================
-- `{ error: { code, message, field? } }`, returned as a value rather than
-- raised. A raise would roll back the transaction, which is right for a
-- constraint violation and wrong for "your headline is four characters too
-- long" — the frontend needs to put that message next to the field, and a
-- 500-shaped failure gives it nothing to put there.
--
-- Every write path below validates BEFORE it writes, so returning an error
-- always means nothing was written. The CHECK constraints stay as the backstop
-- for anything that reaches the table another way.

create or replace function public.site_spec_error(
  p_code text, p_message text, p_field text default null
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('error',
    jsonb_strip_nulls(jsonb_build_object(
      'code', p_code, 'message', p_message, 'field', p_field)))
$$;


-- ============================================================================
-- 2. The staleness diff
-- ============================================================================
-- ⚠ `stale` IS DECIDED BY THE VERSION, NOT BY THE LABEL LIST. Any successful
-- write bumps `spec_version`; if one of them ever changes something no label
-- describes, the banner must still come up. Deriving `stale` from a non-empty
-- `changes` array would make the correctness of the banner depend on the
-- completeness of the labelling, which is exactly the kind of coupling that
-- fails quietly.
--
-- `changes` is the human-readable half: "Primary color changed", "About text
-- edited". Cheap and readable, deliberately not a field-level patch — the
-- therapist is being told whether it is worth re-copying, not shown a diff.

create or replace function public.site_spec_diff(p_spec jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'stale',
      coalesce((p_spec->>'last_copied_spec_version')::int < (p_spec->>'spec_version')::int, false),
    'changes', coalesce((
      select jsonb_agg(jsonb_build_object('area', m.area, 'label', m.label)
                       order by m.area, m.label)
        from jsonb_each(coalesce(p_spec->'change_marks', '{}'::jsonb)) as e(k, v)
        cross join lateral (
          -- marks are stored as "<area>|<label>" -> version
          select split_part(e.k, '|', 1) as area, split_part(e.k, '|', 2) as label
        ) m
       where (p_spec->>'last_copied_spec_version') is not null
         and (e.v #>> '{}')::int > (p_spec->>'last_copied_spec_version')::int
    ), '[]'::jsonb))
$$;

comment on function public.site_spec_diff(jsonb) is
  'The "changed since you copied" banner: { stale, changes }. stale comes from the version comparison so it cannot be wrong; changes is the readable explanation and may be empty.';


-- ============================================================================
-- 3. The envelope
-- ============================================================================
-- `spec` is emitted with the SAME key names `site_spec_patch` accepts, so what
-- the editor reads is exactly what it can write back. The `_hex` column suffix
-- and the storage-side `change_marks` never leave the database.

create or replace function public.site_spec_envelope(p_row jsonb)
returns jsonb
language sql
stable
set search_path = ''
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
      'target',                   p_row->>'target'),
    'preview',  public.site_spec_preview_model(p_row),
    'contrast', public.site_spec_contrast(p_row),
    'diff',     public.site_spec_diff(p_row),
    -- Everything the output depends on is `spec_version` and `target`, both of
    -- which change only through a successful write, so this is a complete and
    -- cheap validator for the frontend to hand back as `If-None-Match`.
    'etag', md5(concat_ws(':', p_row->>'brand_kit_id',
                               p_row->>'spec_version',
                               p_row->>'target'))
  ) end
$$;


-- ============================================================================
-- 4. GET — read the whole editor state in one call
-- ============================================================================
-- SECURITY INVOKER, like `brief_preview` and for the same reason: it only
-- reads, so RLS is already the right scoping mechanism, and asking for someone
-- else's kit returns `not_found` rather than a permission error. There is no
-- code path here that knows a row exists and declines to show it, which is the
-- only kind that can leak whether it does.

create or replace function public.site_spec_get(p_brand_kit_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
    (select public.site_spec_envelope(to_jsonb(s))
       from public.site_specs s where s.brand_kit_id = p_brand_kit_id),
    public.site_spec_error('not_found', 'No site spec for this brand kit.'))
$$;

comment on function public.site_spec_get(uuid) is
  'The whole site spec editor state in one round trip: spec, preview, contrast, output, diff, etag. SECURITY INVOKER, so RLS decides whose spec is readable and another user''s kit is simply not found.';


-- ============================================================================
-- 5. PATCH — partial, autosave-friendly, no LLM, no external call
-- ============================================================================
-- ⚠ SECURITY DEFINER, and the reason is narrow enough to state exactly. Every
-- read in this feature is INVOKER; this one is not, because it writes
-- `spec_version` and `change_marks`, two columns the previous migration
-- deliberately withheld from clients (a client-chosen version lets a stale
-- editor win silently). A DEFINER function is only safe if it re-implements
-- the scoping RLS was doing for it, so it does, explicitly and first:
-- `user_id = auth.uid()`, with a NULL uid refused outright. Without those two
-- lines this would be a read-write oracle keyed by uuid.
--
-- WHAT MAKES IT FAST ENOUGH FOR AUTOSAVE
-- --------------------------------------
-- One index lookup on the unique `brand_kit_id`, jsonb manipulation in memory,
-- one UPDATE, one envelope. No LLM call, no HTTP, no catalog join except the
-- single optional type-pairing lookup. Nothing here scales with anything.

create or replace function public.site_spec_patchable_keys()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['primary', 'secondary', 'accent', 'light_neutral', 'dark_neutral',
               'type_pairing_id', 'heading_font', 'body_font', 'google_fonts_url',
               'hero', 'about_excerpt', 'pages', 'practice_details',
               'extra_instructions', 'target']
$$;

-- The structure of the pages document with all copy removed. Comparing two of
-- these is what separates "she moved a section" from "she rewrote a paragraph"
-- without diffing field by field.
create or replace function public.site_spec_pages_skeleton(p_pages jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'key', pg.value->>'key',
               'label', pg.value->>'label',
               'enabled', pg.value->'enabled',
               'sections', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'key', s.value->>'key', 'type', s.value->>'type',
                          'enabled', s.value->'enabled', 'order', s.value->'order')
                        order by s.ord)
                   from jsonb_array_elements(pg.value->'sections') with ordinality as s(value, ord)),
                 '[]'::jsonb))
             order by pg.ord)
      from jsonb_array_elements(p_pages) with ordinality as pg(value, ord)), '[]'::jsonb)
$$;

-- The complement: all the copy, with the structure removed. Keyed by page and
-- section so that a section moving up the page does not read as a reworded
-- paragraph.
--
-- ⚠ IT MUST IGNORE `enabled` AND `order`. Comparing the rendered preview
-- instead would call switching a page off a copy edit, because the preview
-- omits what is switched off — which is exactly what the skeleton comparison
-- is already reporting, and reporting it twice under two different words is
-- worse than not reporting it at all.
create or replace function public.site_spec_pages_copy(p_pages jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((
    select jsonb_object_agg((pg.value->>'key') || '|' || (s.value->>'key'),
                            coalesce(s.value->'fields', '{}'::jsonb))
      from jsonb_array_elements(p_pages) as pg
      cross join lateral jsonb_array_elements(pg.value->'sections') as s), '{}'::jsonb)
$$;

-- The first section text field that exceeds 800 characters, as a readable
-- path. Only called on the failure branch, so its cost never lands on a
-- successful autosave.
create or replace function public.site_spec_first_overlong_field(p_pages jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select format('pages[%s].sections[%s].fields.%s', pg.ord - 1, s.ord - 1, f.key)
    from jsonb_array_elements(p_pages) with ordinality as pg(value, ord)
    cross join lateral jsonb_array_elements(pg.value->'sections') with ordinality as s(value, ord)
    cross join lateral jsonb_each(s.value->'fields') as f(key, value)
    cross join lateral (
      select f.value as v where jsonb_typeof(f.value) = 'string'
      union all
      select e.value from jsonb_array_elements(f.value) as e where jsonb_typeof(f.value) = 'array'
    ) as vals(v)
   where jsonb_typeof(vals.v) = 'string' and char_length(vals.v #>> '{}') > 800
   order by pg.ord, s.ord, f.key
   limit 1
$$;

create or replace function public.site_spec_patch(p_brand_kit_id uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s        public.site_specs%rowtype;
  n        public.site_specs%rowtype;
  k        text;
  v_marks  jsonb := '{}'::jsonb;
  v_hero   jsonb;
  v_det    jsonb;
  v_len    int;
  v_path   text;
  v_next   int;
begin
  -- ---- scoping, before anything else --------------------------------------
  if (select auth.uid()) is null then
    return public.site_spec_error('unauthenticated',
      'Sign in to edit your site spec.');
  end if;

  select * into s
    from public.site_specs
   where brand_kit_id = p_brand_kit_id
     and user_id = (select auth.uid());
  if not found then
    -- Deliberately the same answer as a kit that does not exist. Another
    -- user's spec is not found, not forbidden.
    return public.site_spec_error('not_found', 'No site spec for this brand kit.');
  end if;

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return public.site_spec_error('invalid_body', 'The update must be a JSON object.');
  end if;

  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (public.site_spec_patchable_keys())) then
      return public.site_spec_error('unknown_field',
        format('"%s" is not a field of the site spec.', k), k);
    end if;
  end loop;

  n := s;

  -- ---- colours -------------------------------------------------------------
  -- Uppercased on the way in. The hex a colour picker sends is arbitrarily
  -- cased, and the derived output is meant to be byte-identical for one spec
  -- on every render, which it would not be if `#c08a3e` and `#C08A3E` could
  -- both be stored.
  for k in select unnest(array['primary', 'secondary', 'accent',
                               'light_neutral', 'dark_neutral']) loop
    if p_patch ? k then
      if jsonb_typeof(p_patch->k) <> 'string'
         or (p_patch->>k) !~ '^#[0-9A-Fa-f]{6}$' then
        return public.site_spec_error('invalid_field',
          'A color must be a hex value like #3B2C3A.', k);
      end if;
      case k
        when 'primary'       then n.primary_hex       := upper(p_patch->>k);
        when 'secondary'     then n.secondary_hex     := upper(p_patch->>k);
        when 'accent'        then n.accent_hex        := upper(p_patch->>k);
        when 'light_neutral' then n.light_neutral_hex := upper(p_patch->>k);
        when 'dark_neutral'  then n.dark_neutral_hex  := upper(p_patch->>k);
      end case;
    end if;
  end loop;

  -- ---- typography ----------------------------------------------------------
  -- Choosing a pairing adopts its two faces and its stylesheet, unless the
  -- same patch also names a font explicitly (which is how the editor lets her
  -- start from a pairing and then swap one face). A pairing that only set an
  -- id would leave the fonts on screen unchanged and the picker lying.
  if p_patch ? 'type_pairing_id' then
    if jsonb_typeof(p_patch->'type_pairing_id') = 'null' then
      n.type_pairing_id := null;
    elsif jsonb_typeof(p_patch->'type_pairing_id') <> 'string' then
      return public.site_spec_error('invalid_field',
        'The type pairing must be a catalog id.', 'type_pairing_id');
    else
      if not exists (select 1 from public.type_pairings tp
                      where tp.id = p_patch->>'type_pairing_id') then
        return public.site_spec_error('invalid_field',
          format('"%s" is not a type pairing we carry.', p_patch->>'type_pairing_id'),
          'type_pairing_id');
      end if;
      n.type_pairing_id := p_patch->>'type_pairing_id';
      select tp.heading_font, tp.body_font, tp.google_fonts_url
        into n.heading_font, n.body_font, n.google_fonts_url
        from public.type_pairings tp where tp.id = n.type_pairing_id;
    end if;
  end if;

  for k in select unnest(array['heading_font', 'body_font', 'google_fonts_url']) loop
    if p_patch ? k then
      if jsonb_typeof(p_patch->k) <> 'string' or btrim(p_patch->>k) = '' then
        return public.site_spec_error('invalid_field',
          'This must be a font name we can render.', k);
      end if;
      case k
        when 'heading_font'     then n.heading_font     := btrim(p_patch->>k);
        when 'body_font'        then n.body_font        := btrim(p_patch->>k);
        when 'google_fonts_url' then n.google_fonts_url := btrim(p_patch->>k);
      end case;
    end if;
  end loop;

  -- ---- hero ----------------------------------------------------------------
  -- Merged key by key, not replaced: the editor autosaves one field at a time
  -- and a whole-object replace would drop the four she is not typing in.
  if p_patch ? 'hero' then
    if jsonb_typeof(p_patch->'hero') <> 'object' then
      return public.site_spec_error('invalid_field', 'The hero must be an object.', 'hero');
    end if;
    v_hero := n.hero;
    for k in select jsonb_object_keys(p_patch->'hero') loop
      if not (k = any (array['overline', 'headline', 'subhead',
                             'cta_label', 'cta_target_url'])) then
        return public.site_spec_error('unknown_field',
          format('"%s" is not a field of the hero.', k), 'hero.' || k);
      end if;
      v_hero := jsonb_set(v_hero, array[k], p_patch->'hero'->k);
    end loop;

    if not public.site_spec_hero_valid(v_hero) then
      return public.site_spec_error('invalid_field',
        'Every hero field must be text.', 'hero');
    end if;
    if not public.site_spec_hero_lengths_valid(v_hero) then
      -- name the field and its limit, so the editor can put the message under
      -- the input the therapist is actually typing in
      for k, v_len in select * from (values ('overline', 48), ('headline', 90),
                                            ('subhead', 220), ('cta_label', 28)) x(a, b) loop
        if coalesce(char_length(v_hero->>k), 0) > v_len then
          return public.site_spec_error('too_long',
            format('This is %s characters. The limit is %s.',
                   char_length(v_hero->>k), v_len), 'hero.' || k);
        end if;
      end loop;
    end if;
    if not public.site_spec_cta_target_url_valid(v_hero) then
      return public.site_spec_error('invalid_field',
        'The button link must start with https://, http://, mailto: or tel:.',
        'hero.cta_target_url');
    end if;
    n.hero := v_hero;
  end if;

  -- ---- about excerpt -------------------------------------------------------
  if p_patch ? 'about_excerpt' then
    if jsonb_typeof(p_patch->'about_excerpt') <> 'string' then
      return public.site_spec_error('invalid_field',
        'The About text must be text.', 'about_excerpt');
    end if;
    if char_length(p_patch->>'about_excerpt') > 600 then
      return public.site_spec_error('too_long',
        format('This is %s characters. The limit is 600.',
               char_length(p_patch->>'about_excerpt')), 'about_excerpt');
    end if;
    n.about_excerpt := p_patch->>'about_excerpt';
  end if;

  -- ---- extra instructions --------------------------------------------------
  -- Stored exactly as typed, and never read by anything but the renderer that
  -- appends it verbatim under its own heading.
  if p_patch ? 'extra_instructions' then
    if jsonb_typeof(p_patch->'extra_instructions') = 'null' then
      n.extra_instructions := null;
    elsif jsonb_typeof(p_patch->'extra_instructions') <> 'string' then
      return public.site_spec_error('invalid_field',
        'Your notes must be text.', 'extra_instructions');
    elsif char_length(p_patch->>'extra_instructions') > 2000 then
      return public.site_spec_error('too_long',
        format('This is %s characters. The limit is 2000.',
               char_length(p_patch->>'extra_instructions')), 'extra_instructions');
    else
      n.extra_instructions := p_patch->>'extra_instructions';
    end if;
  end if;

  -- ---- pages ---------------------------------------------------------------
  -- Replaced whole. Unlike the hero, a structure edit is a reorder or a toggle
  -- and the editor already holds the entire array to render the outline.
  if p_patch ? 'pages' then
    if not public.site_spec_pages_valid(p_patch->'pages') then
      return public.site_spec_error('invalid_field',
        'Each page needs a known key, a label, an enabled flag and a list of sections with unique keys.',
        'pages');
    end if;
    if not public.site_spec_pages_lengths_valid(p_patch->'pages') then
      v_path := public.site_spec_first_overlong_field(p_patch->'pages');
      return public.site_spec_error('too_long',
        'This is over 800 characters, which is the limit for a section field.',
        coalesce(v_path, 'pages'));
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_patch->'pages') pg
      cross join lateral jsonb_array_elements(pg.value->'sections') sc
      join public.section_types st on st.id = sc.value->>'type'
       where not (pg.value->>'key' = any (st.allowed_pages))
    ) then
      return public.site_spec_error('invalid_field',
        'One of these sections is not allowed on the page it was put on.', 'pages');
    end if;
    n.pages := p_patch->'pages';
  end if;

  -- ---- practice details ----------------------------------------------------
  if p_patch ? 'practice_details' then
    if jsonb_typeof(p_patch->'practice_details') <> 'object' then
      return public.site_spec_error('invalid_field',
        'The practice details must be an object.', 'practice_details');
    end if;
    v_det := n.practice_details;
    for k in select jsonb_object_keys(p_patch->'practice_details') loop
      if not (k = any (array['practice_name', 'license_label', 'license_number',
                             'city', 'state', 'email', 'phone'])) then
        return public.site_spec_error('unknown_field',
          format('"%s" is not a practice detail.', k), 'practice_details.' || k);
      end if;
      v_det := jsonb_set(v_det, array[k], p_patch->'practice_details'->k);
    end loop;
    if not public.site_spec_practice_details_valid(v_det) then
      return public.site_spec_error('invalid_field',
        'The state must be a two-letter code, and every other detail must be text.',
        'practice_details');
    end if;
    n.practice_details := v_det;
  end if;

  -- ---- target --------------------------------------------------------------
  -- Accepted here as well as through the dedicated switch call: a partial
  -- patch already touches nothing it was not given, which is the whole
  -- guarantee the separate endpoint was asked to make.
  if p_patch ? 'target' then
    if jsonb_typeof(p_patch->'target') <> 'string'
       or not exists (select 1 from public.builder_targets bt
                       where bt.id = p_patch->>'target') then
      return public.site_spec_error('invalid_field',
        'Pick one of the website builders we support.', 'target');
    end if;
    n.target := p_patch->>'target';
  end if;

  -- ---- what actually changed ----------------------------------------------
  -- ⚠ A NO-OP PATCH MUST NOT BUMP THE VERSION. Autosave fires on every
  -- keystroke, including the one that types a character and the one that
  -- deletes it again; bumping there would raise the "changed since you copied"
  -- banner over an edit that undid itself.
  v_next := s.spec_version + 1;

  if n.primary_hex is distinct from s.primary_hex then
    v_marks := v_marks || jsonb_build_object('colors|Primary color changed', v_next); end if;
  if n.secondary_hex is distinct from s.secondary_hex then
    v_marks := v_marks || jsonb_build_object('colors|Secondary color changed', v_next); end if;
  if n.accent_hex is distinct from s.accent_hex then
    v_marks := v_marks || jsonb_build_object('colors|Accent color changed', v_next); end if;
  if n.light_neutral_hex is distinct from s.light_neutral_hex then
    v_marks := v_marks || jsonb_build_object('colors|Page background changed', v_next); end if;
  if n.dark_neutral_hex is distinct from s.dark_neutral_hex then
    v_marks := v_marks || jsonb_build_object('colors|Body text color changed', v_next); end if;

  if n.heading_font is distinct from s.heading_font then
    v_marks := v_marks || jsonb_build_object('typography|Heading font changed', v_next); end if;
  if n.body_font is distinct from s.body_font then
    v_marks := v_marks || jsonb_build_object('typography|Body font changed', v_next); end if;
  if n.google_fonts_url is distinct from s.google_fonts_url then
    v_marks := v_marks || jsonb_build_object('typography|Font stylesheet changed', v_next); end if;

  if n.hero is distinct from s.hero then
    v_marks := v_marks || jsonb_build_object('copy|Hero copy edited', v_next); end if;
  if n.about_excerpt is distinct from s.about_excerpt then
    v_marks := v_marks || jsonb_build_object('copy|About text edited', v_next); end if;
  if n.practice_details is distinct from s.practice_details then
    v_marks := v_marks || jsonb_build_object('copy|Practice details edited', v_next); end if;

  -- Structure and copy both live in `pages`, and they are different news: one
  -- means the site is laid out differently, the other means a paragraph was
  -- reworded. Comparing the copy-free skeleton separates them without diffing
  -- field by field.
  if n.pages is distinct from s.pages then
    if public.site_spec_pages_skeleton(n.pages)
       is distinct from public.site_spec_pages_skeleton(s.pages) then
      v_marks := v_marks || jsonb_build_object('structure|Page structure changed', v_next);
    end if;
    if public.site_spec_pages_copy(n.pages)
       is distinct from public.site_spec_pages_copy(s.pages) then
      v_marks := v_marks || jsonb_build_object('copy|Section copy edited', v_next);
    end if;
  end if;

  if n.extra_instructions is distinct from s.extra_instructions then
    v_marks := v_marks || jsonb_build_object('instructions|Your own notes edited', v_next); end if;

  -- The product spec's five areas do not name the builder. `structure` is the
  -- closest of them — what gets built — and the label says plainly what
  -- happened, which beats inventing a sixth area the frontend is not expecting.
  if n.target is distinct from s.target then
    v_marks := v_marks || jsonb_build_object('structure|Website builder changed', v_next); end if;

  if v_marks = '{}'::jsonb then
    -- Nothing moved. Return the current state, unversioned and unmarked.
    return public.site_spec_envelope(to_jsonb(s));
  end if;

  update public.site_specs
     set primary_hex        = n.primary_hex,
         secondary_hex      = n.secondary_hex,
         accent_hex         = n.accent_hex,
         light_neutral_hex  = n.light_neutral_hex,
         dark_neutral_hex   = n.dark_neutral_hex,
         type_pairing_id    = n.type_pairing_id,
         heading_font       = n.heading_font,
         body_font          = n.body_font,
         google_fonts_url   = n.google_fonts_url,
         hero               = n.hero,
         about_excerpt      = n.about_excerpt,
         pages              = n.pages,
         practice_details   = n.practice_details,
         extra_instructions = n.extra_instructions,
         target             = n.target,
         spec_version       = v_next,
         change_marks       = coalesce(change_marks, '{}'::jsonb) || v_marks
   where id = s.id
   returning * into n;

  return public.site_spec_envelope(to_jsonb(n));
end
$$;

comment on function public.site_spec_patch(uuid, jsonb) is
  'Partial, autosave-friendly update of the site spec. Validates only the fields present, writes nothing when it returns an error, and returns the same envelope as site_spec_get so an edit costs one round trip. No LLM call and no external call. SECURITY DEFINER, scoped explicitly on auth.uid().';

grant execute on function public.site_spec_error(text, text, text)      to authenticated, service_role;
grant execute on function public.site_spec_diff(jsonb)                  to authenticated, service_role;
grant execute on function public.site_spec_envelope(jsonb)              to authenticated, service_role;
grant execute on function public.site_spec_get(uuid)                    to authenticated, service_role;
grant execute on function public.site_spec_patchable_keys()             to authenticated, service_role;
grant execute on function public.site_spec_pages_skeleton(jsonb)        to authenticated, service_role;
grant execute on function public.site_spec_pages_copy(jsonb)            to authenticated, service_role;
grant execute on function public.site_spec_first_overlong_field(jsonb)  to authenticated, service_role;
grant execute on function public.site_spec_patch(uuid, jsonb)           to authenticated;


-- ============================================================================
-- 6. Guard rails
-- ============================================================================
do $$
declare
  v_row jsonb;
begin
  -- An unknown kit is not found, not an error and not somebody else's spec.
  if public.site_spec_get('00000000-0000-0000-0000-000000000000')->'error'->>'code'
     is distinct from 'not_found' then
    raise exception 'site_spec_endpoints: an unknown brand kit did not return not_found.';
  end if;

  -- ⚠ The patch path must be unable to run without a caller identity. As
  -- `postgres` here, auth.uid() is NULL, which is exactly the service-role
  -- case, and it must refuse rather than fall through to a row.
  if public.site_spec_patch('00000000-0000-0000-0000-000000000000', '{}'::jsonb)
       ->'error'->>'code' is distinct from 'unauthenticated' then
    raise exception
      'site_spec_endpoints: site_spec_patch does not refuse a caller with no auth.uid().';
  end if;

  -- The envelope's keys are the contract the frontend reads.
  v_row := jsonb_build_object(
    'brand_kit_id', '00000000-0000-0000-0000-000000000000',
    'spec_version', 3, 'last_copied_spec_version', 2, 'target', 'lovable',
    'primary_hex', '#3B2C3A', 'secondary_hex', '#4A5361', 'accent_hex', '#C08A3E',
    'light_neutral_hex', '#F3EDE4', 'dark_neutral_hex', '#241B23',
    'heading_font', 'Fraunces', 'body_font', 'Nunito Sans',
    'google_fonts_url', 'https://fonts.googleapis.com/css2?family=Fraunces&display=swap',
    'about_excerpt', 'x', 'practice_details', '{}'::jsonb,
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'pages', public.site_spec_default_pages(null, null),
    'change_marks', jsonb_build_object('colors|Primary color changed', 3,
                                       'copy|About text edited', 1));

  if not (public.site_spec_envelope(v_row) ?& array['spec', 'preview', 'contrast', 'diff', 'etag']) then
    raise exception 'site_spec_endpoints: the envelope is missing a documented key.';
  end if;

  -- Every writable key must be readable back under the same name, or the
  -- editor would have to translate in one direction only.
  if exists (
    select 1 from unnest(public.site_spec_patchable_keys()) as k(name)
     where not (public.site_spec_envelope(v_row)->'spec' ? k.name)
  ) then
    raise exception
      'site_spec_endpoints: a patchable key is not readable back under the same name.';
  end if;

  -- The diff: one mark newer than the copy marker, one older.
  if (public.site_spec_diff(v_row)->>'stale')::boolean is not true then
    raise exception 'site_spec_endpoints: version 3 against a copy of version 2 is not stale.';
  end if;
  if jsonb_array_length(public.site_spec_diff(v_row)->'changes') <> 1 then
    raise exception
      'site_spec_endpoints: the diff reports % changes, expected only the one newer than the copy.',
      jsonb_array_length(public.site_spec_diff(v_row)->'changes');
  end if;
  if public.site_spec_diff(v_row)->'changes'->0->>'label' <> 'Primary color changed' then
    raise exception 'site_spec_endpoints: the diff named the wrong change.';
  end if;

  -- Never copied is not stale: there is nothing for it to be stale against.
  if (public.site_spec_diff(v_row - 'last_copied_spec_version')->>'stale')::boolean then
    raise exception 'site_spec_endpoints: a spec that was never copied is reported stale.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.site_spec_patch(uuid, jsonb);
--   drop function if exists public.site_spec_first_overlong_field(jsonb);
--   drop function if exists public.site_spec_pages_copy(jsonb);
--   drop function if exists public.site_spec_pages_skeleton(jsonb);
--   drop function if exists public.site_spec_patchable_keys();
--   drop function if exists public.site_spec_get(uuid);
--   drop function if exists public.site_spec_envelope(jsonb);
--   drop function if exists public.site_spec_diff(jsonb);
--   drop function if exists public.site_spec_error(text, text, text);
