-- ============================================================================
-- Tests — 20260829110000_site_output_templates.sql
-- ============================================================================
-- The output copy lives in a table, so a wording change is an UPDATE rather
-- than a migration. What has to hold is that the renderers still find every
-- fragment they ask for, that a per-builder row overrides only that builder,
-- and that the placeholders survive rewording.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- ⚠ Every fragment the renderers reach for exists
-- ---------------------------------------------------------------------------
-- A missing row does not raise. It renders as an empty string — a deliverable
-- with a hole in it that nobody notices until a therapist pastes it into her
-- builder.
do $$
declare
  f   jsonb := public.site_output_fragments(null);
  k   text;
  req text[] := array[
    'prompt.role_line','prompt.heading_practice','prompt.heading_tokens',
    'prompt.heading_structure','prompt.heading_copy','prompt.copy_preamble',
    'prompt.heading_constraints','prompt.heading_extra','prompt.copy_section_heading',
    'prompt.structure_section_line',
    'identity.label_name','identity.label_license','identity.label_location',
    'identity.label_email','identity.label_phone',
    'token.primary','token.secondary','token.accent','token.light_neutral',
    'token.dark_neutral','token.heading_font','token.body_font','token.google_fonts_url',
    'token.paper','token.primary_text','token.secondary_text','token.accent_text',
    'token.text_variant_note','sheet.step_text_title','sheet.step_text_body',
    'constraint.copy_exact','constraint.no_invention','constraint.no_stock_photos',
    'constraint.cta_linked','constraint.cta_unlinked','constraint.contrast',
    'sheet.step1_title','sheet.step1_body','sheet.step2_title','sheet.step2_body',
    'sheet.step3_title','sheet.step3_body','sheet.step4_title','sheet.step4_body',
    'sheet.step5_title','sheet.step5_body','sheet.step6_title',
    'sheet.step6_body_linked','sheet.step6_body_unlinked',
    'sheet.step7_title','sheet.step8_title','sheet.label_cta_label','sheet.label_cta_target',
    'render.where_md','render.where_txt','render.copy_blocks_md','render.copy_blocks_txt',
    'render.copy_block_heading','render.value_line'
  ];
begin
  foreach k in array req loop
    assert (f->>k) is not null,
           format('the fragment %s is missing; it would render as an empty string', k);
    assert btrim(f->>k) <> '',
           format('the fragment %s is blank', k);
  end loop;

  -- and every stored row is reachable under a key the id agrees with
  assert not exists (
    select 1 from public.site_output_templates
     where id <> coalesce(target, 'all') || '.' || key),
         'a row is filed under a name that disagrees with what it overrides';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ Placeholders must survive rewording
-- ---------------------------------------------------------------------------
-- `constraint.cta_linked` is the line that carries her booking link into the
-- output. Reworded without its placeholder, the link silently disappears from
-- every prompt.
do $$
begin
  assert (public.site_output_fragments(null)->>'constraint.cta_linked') like '%{cta_target_url}%',
         'constraint.cta_linked lost its {cta_target_url} placeholder';
  assert (public.site_output_fragments(null)->>'prompt.copy_section_heading') like '%{page}%'
     and (public.site_output_fragments(null)->>'prompt.copy_section_heading') like '%{section}%',
         'the copy section heading lost a placeholder';
  assert (public.site_output_fragments(null)->>'render.value_line') like '%{label}%'
     and (public.site_output_fragments(null)->>'render.value_line') like '%{value}%',
         'the value line lost a placeholder';
  assert (public.site_output_fragments(null)->>'prompt.structure_section_line') like '%{label}%'
     and (public.site_output_fragments(null)->>'prompt.structure_section_line') like '%{description}%',
         'the structure line lost a placeholder';

  -- the substituter itself
  assert public.site_output_fill('a {x} b', '{"x":"Z"}'::jsonb) = 'a Z b', 'basic substitution';
  assert public.site_output_fill('{x} {x}', '{"x":"Z"}'::jsonb) = 'Z Z', 'repeated placeholder';
  assert public.site_output_fill('no placeholder', '{"x":"Z"}'::jsonb) = 'no placeholder',
         'a template with no placeholder must be returned unchanged';
  assert public.site_output_fill('{missing}', '{}'::jsonb) = '{missing}',
         'an unfilled placeholder must be left visible, not blanked';
  assert public.site_output_fill(null, '{"x":"Z"}'::jsonb) is null, 'null template';
end
$$;

-- ---------------------------------------------------------------------------
-- Per-builder overrides reach one builder and no other
-- ---------------------------------------------------------------------------
-- This is the whole point of the target column: what Squarespace honors and
-- what Lovable honors will diverge, and tuning one must not move the other.
do $$
begin
  insert into public.site_output_templates (id, target, key, body)
  values ('squarespace.constraint.contrast', 'squarespace', 'constraint.contrast',
          'Maintain WCAG AA text contrast in Site Styles.');

  assert (public.site_output_fragments('squarespace')->>'constraint.contrast')
         = 'Maintain WCAG AA text contrast in Site Styles.',
         'a per-builder override was not applied';
  assert (public.site_output_fragments('lovable')->>'constraint.contrast')
         = 'Maintain WCAG AA text contrast.',
         'a per-builder override leaked to another builder';
  assert (public.site_output_fragments(null)->>'constraint.contrast')
         = 'Maintain WCAG AA text contrast.',
         'a per-builder override changed the shared row';

  -- and it actually reaches the rendered sheet
  assert (select s.value->>'body'
            from jsonb_array_elements(
                   public.site_spec_output(
                     jsonb_build_object(
                       'primary_hex','#3B2C3A','secondary_hex','#4A5361','accent_hex','#C08A3E',
                       'light_neutral_hex','#F3EDE4','dark_neutral_hex','#241B23',
                       'heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','u',
                       'about_excerpt','x','practice_details','{}'::jsonb,
                       'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
                       'pages', public.site_spec_default_pages(null,null)),
                     'squarespace')->'steps') s
           where (s.value->>'n')::int = 8) like '%Site Styles.%',
         'the override did not reach the rendered checklist';

  delete from public.site_output_templates where id = 'squarespace.constraint.contrast';
end
$$;

-- Deactivating a row falls back to the shared one rather than to nothing.
do $$
begin
  insert into public.site_output_templates (id, target, key, body, active)
  values ('wix.prompt.role_line', 'wix', 'prompt.role_line', 'OVERRIDDEN', false);
  assert (public.site_output_fragments('wix')->>'prompt.role_line') <> 'OVERRIDDEN',
         'an inactive override was applied';
  assert (public.site_output_fragments('wix')->>'prompt.role_line') is not null,
         'an inactive override left the fragment missing instead of falling back';
  delete from public.site_output_templates where id = 'wix.prompt.role_line';
end
$$;

-- ---------------------------------------------------------------------------
-- The five constraints are rows, but the fact that there are five is not
-- ---------------------------------------------------------------------------
-- Four of them are the difference between a website a licensing board is fine
-- with and one it is not. Tuning the wording is expected; losing a line is not.
do $$
declare
  spec jsonb := jsonb_build_object(
    'primary_hex','#3B2C3A','secondary_hex','#4A5361','accent_hex','#C08A3E',
    'light_neutral_hex','#F3EDE4','dark_neutral_hex','#241B23',
    'heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','u',
    'about_excerpt','x','practice_details','{}'::jsonb,
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s',
                               'cta_label','c','cta_target_url','https://example.com/book'),
    'pages', public.site_spec_default_pages(null,null));
  f jsonb := public.site_output_fragments(null);
begin
  assert array_length(public.site_spec_constraint_lines(spec, f), 1) = 5,
         'the constraints block no longer emits five lines';
  -- and the booking link was interpolated, not left as a placeholder
  assert (public.site_spec_constraint_lines(spec, f))[4] like '%https://example.com/book%',
         'the booking link was not interpolated into the constraints';
  assert (public.site_spec_constraint_lines(spec, f))[4] not like '%{cta_target_url}%',
         'the placeholder was left unfilled in the constraints';
  -- the no-link variant when she has not set one
  assert (public.site_spec_constraint_lines(
            jsonb_set(spec, '{hero,cta_target_url}', 'null'::jsonb), f))[4]
         like '%no link yet%',
         'a spec with no booking link did not switch to the unlinked constraint';
end
$$;

-- ---------------------------------------------------------------------------
-- Readable by any authenticated user, writable by none
-- ---------------------------------------------------------------------------
do $$
declare ok boolean;
begin
  assert (select relrowsecurity from pg_class
           where oid='public.site_output_templates'::regclass), 'RLS is off';
  assert (select count(*) from pg_policies
           where schemaname='public' and tablename='site_output_templates') = 1,
         'expected exactly one policy (select-only)';
  assert exists (select 1 from pg_policies
                  where schemaname='public' and tablename='site_output_templates'
                    and cmd='SELECT' and roles='{authenticated}'),
         'the policy is not a SELECT restricted to authenticated';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
  assert (select count(*) from public.site_output_templates) > 40,
         'an authenticated user must be able to read the output templates';
  begin
    update public.site_output_templates set body = 'Hijacked' where id='all.constraint.contrast';
    ok := (select count(*) from public.site_output_templates where body='Hijacked') = 0;
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client was able to rewrite the output copy';
  reset role;
end
$$;

rollback;
