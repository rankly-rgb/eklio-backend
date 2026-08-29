-- ============================================================================
-- Eklio — the ETag stops lying
-- ============================================================================
-- Follows `20260829115000_direction_limits.sql`.
--
-- WHAT WAS WRONG
-- --------------
-- The envelope's `etag` was `md5(brand_kit_id, spec_version, target)`, and the
-- contract claimed all three change on every successful write. They do not.
--
-- **`site_output_mark_copied` is a successful write that moves none of them.**
-- It writes `last_copied_spec_version`, which flips `diff.stale` from true to
-- false. Reproduced:
--
--     read            -> stale true,  etag 41e035ea852c151bae0b303ccc8cd898
--     mark_copied     -> stale false, etag 41e035ea852c151bae0b303ccc8cd898
--     read            -> stale false, etag 41e035ea852c151bae0b303ccc8cd898
--
-- A client holding that etag re-reads with `If-None-Match`, gets 304, keeps the
-- old body, and the "changed since you copied" banner stays on screen after the
-- copy that was supposed to clear it. The one action whose entire purpose is to
-- change the banner was invisible to the cache validator.
--
-- ⚠ A SECOND GAP, FOUND LOOKING FOR THE FIRST, AND IT IS THE SAME BUG. The
-- envelope's `output` is rendered from `site_output_templates`,
-- `section_types` and `builder_targets`. Those are catalogs, edited by
-- migration or `service_role` — and the whole point of moving the output copy
-- into a table was that it gets tuned weekly. A tuning changes the body and
-- moved nothing in the etag:
--
--     before tuning  -> etag 41e035ea…, output md5 067c150a0de6e1088d538aa0d8350ab9
--     after  tuning  -> etag 41e035ea…, output md5 a6ff4a60d7b46be69bae36a0439e1d2a
--
-- Both are fixed here. A cache validator that is known not to cover part of the
-- body is not a partial feature, it is a wrong answer.
--
-- WHAT THE ETAG NOW COVERS
-- ------------------------
--   brand_kit_id               which spec
--   spec_version               every write to the spec itself
--   last_copied_spec_version   mark-copied, and nothing else moves it
--   target                     redundant with spec_version, kept for readability
--   catalog fingerprint        the copy the output is rendered from
--
-- That is every input to every key of the envelope. `preview` and `contrast`
-- read the spec row only; `output` reads the spec row and the three catalogs;
-- `diff` reads the spec row. Nothing else is consulted.
-- ============================================================================


-- ============================================================================
-- 1. The catalog fingerprint
-- ============================================================================
-- Every column the renderer actually reads, and nothing else — adding
-- `sort_order` or a column no renderer touches would churn the etag for edits
-- that cannot change a byte of output.
--
-- Ordered by primary key so the digest is stable across plans.

create or replace function public.site_output_catalog_version()
returns text
language sql
stable
set search_path = ''
set jit = 'off'
as $$
  select md5(concat_ws('|',
    (select string_agg(t.id || t.key || t.body || coalesce(t.target, '') || t.active::text, '|'
                       order by t.id)
       from public.site_output_templates t where t.active),
    (select string_agg(s.id || s.label || s.description || s.fields::text || s.source, '|'
                       order by s.id)
       from public.section_types s),
    (select string_agg(b.id || b.label || b.output_kind
                       || coalesce(b.template_hint, '') || coalesce(b.color_panel, '')
                       || coalesce(b.font_panel, '')    || coalesce(b.section_panel, ''), '|'
                       order by b.id)
       from public.builder_targets b)
  ))
$$;

comment on function public.site_output_catalog_version() is
  'Fingerprint of every catalog column the derived output is rendered from. Part of the envelope etag: tuning the output copy changes the body, so it has to change the validator.';

grant execute on function public.site_output_catalog_version() to authenticated, service_role;


-- ============================================================================
-- 2. The envelope
-- ============================================================================
-- Identical to `20260829113000_site_spec_paper.sql` except for the etag.

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
    -- ⚠ `last_copied_spec_version` is here because mark-copied moves nothing
    -- else, and the catalog fingerprint because tuning the output copy moves
    -- nothing in the row. Both changed the body while leaving the old etag
    -- valid. See this file's header for the reproductions.
    'etag', md5(concat_ws(':', p_row->>'brand_kit_id',
                               p_row->>'spec_version',
                               p_row->>'target',
                               coalesce(p_row->>'last_copied_spec_version', '-'),
                               public.site_output_catalog_version()))
  ) end
$$;


-- ============================================================================
-- 3. Guard rails
-- ============================================================================
do $$
declare
  row1 jsonb;
  row2 jsonb;
  e1   text;
  e2   text;
  v    text;
begin
  row1 := jsonb_build_object(
    'brand_kit_id','33333333-3333-3333-3333-333333333333','spec_version', 5,
    'last_copied_spec_version', 3, 'target','squarespace',
    'primary_hex','#B4674A','secondary_hex','#C08A3E','accent_hex','#6E3320',
    'light_neutral_hex','#F4EEE3','dark_neutral_hex','#2B2A27','paper_hex','#FAF6EE',
    'heading_font','Fraunces','body_font','Nunito Sans',
    'google_fonts_url','https://fonts.googleapis.com/css2?family=Fraunces&display=swap',
    'about_excerpt','x','practice_details','{}'::jsonb,
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
    'pages', public.site_spec_default_pages(null,null), 'change_marks','{}'::jsonb);

  e1 := public.site_spec_envelope(row1)->>'etag';

  -- ⚠ THE BUG. Only last_copied_spec_version moves; the etag must move with it.
  row2 := jsonb_set(row1, '{last_copied_spec_version}', '5'::jsonb);
  e2 := public.site_spec_envelope(row2)->>'etag';
  if e1 = e2 then
    raise exception
      'etag_completeness: mark-copied changes diff.stale and the etag did not move. A client would keep the stale banner after the copy that clears it.';
  end if;

  -- never copied, and copied at version 5, must also differ
  if public.site_spec_envelope(row1 - 'last_copied_spec_version')->>'etag'
     = public.site_spec_envelope(row2)->>'etag' then
    raise exception 'etag_completeness: never-copied and copied collide.';
  end if;

  -- the inputs that already worked still do
  if public.site_spec_envelope(jsonb_set(row1, '{spec_version}', '6'::jsonb))->>'etag' = e1 then
    raise exception 'etag_completeness: a spec_version bump no longer moves the etag.';
  end if;
  if public.site_spec_envelope(jsonb_set(row1, '{target}', '"lovable"'::jsonb))->>'etag' = e1 then
    raise exception 'etag_completeness: a target switch no longer moves the etag.';
  end if;

  -- ---- stable when nothing changes ----------------------------------------
  if public.site_spec_envelope(row1)->>'etag' <> e1 then
    raise exception 'etag_completeness: the etag is not stable across two identical reads.';
  end if;

  -- ---- the catalog fingerprint --------------------------------------------
  v := public.site_output_catalog_version();
  if v is null or length(v) <> 32 then
    raise exception 'etag_completeness: the catalog fingerprint is not an md5.';
  end if;
  if public.site_output_catalog_version() <> v then
    raise exception 'etag_completeness: the catalog fingerprint is not stable.';
  end if;
end
$$;

-- The catalog half, in its own transaction so the edit can be rolled back.
do $$
declare
  before_v text;
  after_v  text;
begin
  before_v := public.site_output_catalog_version();

  update public.site_output_templates set body = body || ' ' where id = 'all.sheet.step2_title';
  after_v := public.site_output_catalog_version();
  if before_v = after_v then
    raise exception
      'etag_completeness: tuning the output copy did not move the catalog fingerprint; the etag would go on validating a body that changed.';
  end if;
  update public.site_output_templates set body = rtrim(body) where id = 'all.sheet.step2_title';

  update public.section_types set description = description || ' ' where id = 'hero';
  if before_v = public.site_output_catalog_version() then
    raise exception 'etag_completeness: a section_types edit did not move the fingerprint.';
  end if;
  update public.section_types set description = rtrim(description) where id = 'hero';

  update public.builder_targets set color_panel = color_panel || ' ' where id = 'squarespace';
  if before_v = public.site_output_catalog_version() then
    raise exception 'etag_completeness: a builder_targets edit did not move the fingerprint.';
  end if;
  update public.builder_targets set color_panel = rtrim(color_panel) where id = 'squarespace';

  if public.site_output_catalog_version() <> before_v then
    raise exception 'etag_completeness: the fingerprint did not return to its value after the probes were undone.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   -- restore site_spec_envelope from 20260829113000 (three-input etag),
--   -- WITH its `set jit = 'off'` clause, then:
--   drop function if exists public.site_output_catalog_version();
