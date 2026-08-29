-- ============================================================================
-- Tests — 20260829101000_site_spec_catalog.sql
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- ⚠ The fork, asserted in both directions
-- ---------------------------------------------------------------------------
-- Squarespace, Wix and Webflow have no prompt input. Shipping them a prompt is
-- shipping them nothing, and it is the failure this whole feature exists to
-- fix — so it is checked here, not assumed.
do $$
begin
  assert (select count(*) from public.builder_targets) = 7, 'seven builder targets';

  assert (select array_agg(id order by sort_order) from public.builder_targets
           where accepts_prompt) = array['lovable','framer','v0','generic'],
         'the prompt-accepting builders drifted';
  assert (select array_agg(id order by sort_order) from public.builder_targets
           where not accepts_prompt) = array['squarespace','wix','webflow'],
         'the builders with no prompt input drifted';

  -- `accepts_prompt` is generated, so it cannot disagree with output_kind, and
  -- it cannot be written by hand either.
  assert (select attgenerated from pg_attribute
           where attrelid = 'public.builder_targets'::regclass and attname = 'accepts_prompt') = 's',
         'accepts_prompt is not a stored generated column; it can drift from output_kind';
  assert not exists (select 1 from public.builder_targets
                      where accepts_prompt <> (output_kind = 'prompt')),
         'accepts_prompt disagrees with output_kind';
end
$$;

do $$
declare
  ok boolean;
begin
  begin
    update public.builder_targets set accepts_prompt = true where id = 'squarespace';
    ok := false;
  exception when others then ok := true; end;
  assert ok, 'accepts_prompt was writable by hand';
end
$$;

-- ---------------------------------------------------------------------------
-- A setup sheet has to be able to name the panels
-- ---------------------------------------------------------------------------
do $$
declare
  ok boolean;
begin
  assert not exists (
    select 1 from public.builder_targets
     where output_kind = 'setup_sheet'
       and (color_panel is null or font_panel is null
            or section_panel is null or template_hint is null)),
         'a setup-sheet builder cannot name one of its panels';

  -- and the three name DIFFERENT panels, or the sheet is generic advice
  assert (select count(distinct color_panel) from public.builder_targets
           where output_kind = 'setup_sheet') = 3,
         'two setup-sheet builders share a color panel name';

  -- a prompt builder carries none of them: it has no panels
  assert not exists (
    select 1 from public.builder_targets
     where output_kind = 'prompt' and color_panel is not null),
         'a prompt builder carries panel names it has no use for';

  begin
    update public.builder_targets set color_panel = null where id = 'squarespace';
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'a setup-sheet builder was allowed to lose its color panel';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ The two lists that must not drift
-- ---------------------------------------------------------------------------
-- The section types live both in this catalog and in a CHECK constraint, since
-- no foreign key reaches inside a jsonb document. Two hand-maintained lists
-- drift, and the half that drifts is always the one nobody is looking at.
do $$
begin
  assert (select array_agg(id order by id) from public.section_types)
       = (select array_agg(t order by t) from unnest(public.site_spec_section_types()) t),
         'section_types and the site_spec_section_types() CHECK list disagree';

  assert (select count(*) from public.section_types) = 11, 'eleven section types';

  assert (select array_agg(bt.id order by bt.id) from public.builder_targets bt)
       = array['framer','generic','lovable','squarespace','v0','webflow','wix'],
         'a builder target is not accepted by site_specs_target_check';
end
$$;

-- ---------------------------------------------------------------------------
-- Field declarations promise a length the write path actually accepts
-- ---------------------------------------------------------------------------
do $$
declare
  ok boolean;
begin
  -- 800 is the ceiling any section text field is held to. A catalog advertising
  -- 900 would promise the editor a length the CHECK refuses.
  assert not exists (
    select 1 from public.section_types st
    cross join lateral jsonb_array_elements(st.fields) f
     where (f.value->>'max_length')::int > 800),
         'a section type advertises a field longer than the write path accepts';

  assert not exists (
    select 1 from public.section_types st
    cross join lateral jsonb_array_elements(st.fields) f
     where f.value->>'kind' not in ('text','longtext','list')),
         'a section type declares a field kind the editor cannot render';

  begin
    update public.section_types
       set fields = '[{"key":"body","label":"Body","kind":"longtext","max_length":900}]'::jsonb
     where id = 'approach';
    ok := false;
  exception when check_violation then ok := true; end;
  assert ok, 'a 900-character field declaration was accepted';

  -- The hero and the intro keep their copy in their own columns; the editor
  -- cannot know that without `source`.
  assert (select source from public.section_types where id = 'hero')  = 'spec.hero';
  assert (select source from public.section_types where id = 'intro') = 'spec.about_excerpt';
  assert (select count(*) from public.section_types where source = 'fields') = 9,
         'the other nine section types keep their copy in their own fields';
end
$$;

-- Every section type is allowed somewhere, and only on pages that exist.
do $$
begin
  assert not exists (
    select 1 from public.section_types st
     where coalesce(array_length(st.allowed_pages, 1), 0) = 0
        or not (st.allowed_pages <@ public.site_spec_page_keys())),
         'a section type is allowed nowhere, or on a page that does not exist';

  -- and the default structure only puts sections where they are allowed
  assert not exists (
    select 1 from jsonb_array_elements(public.site_spec_default_pages(null, null)) pg
    cross join lateral jsonb_array_elements(pg.value->'sections') s
    join public.section_types st on st.id = s.value->>'type'
     where not (pg.value->>'key' = any (st.allowed_pages))),
         'the default structure seeds a section onto a page its type disallows';
end
$$;

-- ---------------------------------------------------------------------------
-- site_catalog() returns the exact shape the product spec fixes
-- ---------------------------------------------------------------------------
do $$
declare
  c jsonb := public.site_catalog();
begin
  assert jsonb_array_length(c->'section_types')   = 11, 'eleven section types in the payload';
  assert jsonb_array_length(c->'builder_targets') = 7,  'seven builder targets in the payload';

  -- ⚠ the key is `type`, not `id`. The spec fixes it, and the frontend reads it.
  assert c->'section_types'->0 ?& array['type','label','description','fields',
                                        'default_enabled','allowed_pages'],
         'a section_types entry is missing a documented key';
  assert c->'section_types'->0->>'type' = 'hero', 'the catalog is not in sort order';

  assert c->'builder_targets'->0 ?& array['id','label','accepts_prompt','output_kind','docs_url'],
         'a builder_targets entry is missing a documented key';

  assert (select count(*) from jsonb_array_elements(c->'builder_targets') b
           where (b.value->>'accepts_prompt')::boolean) = 4,
         'the payload disagrees with the table about who takes a prompt';
end
$$;

-- ---------------------------------------------------------------------------
-- Readable by any authenticated user, writable by none
-- ---------------------------------------------------------------------------
do $$
declare
  t  text;
  n  int;
  ok boolean;
begin
  foreach t in array array['section_types','builder_targets'] loop
    assert (select relrowsecurity from pg_class where oid = ('public.'||t)::regclass),
           format('RLS is off on %s', t);
    select count(*) into n from pg_policies where schemaname='public' and tablename=t;
    assert n = 1, format('%s has %s policies, expected exactly 1 (select-only)', t, n);
    assert exists (select 1 from pg_policies
                    where schemaname='public' and tablename=t and cmd='SELECT'),
           format('the single policy on %s is not a SELECT policy', t);
    -- ⚠ `using (true)` has none of the self-closing property an auth.uid()
    -- predicate has: without `to authenticated` it publishes product content
    -- to unauthenticated visitors.
    assert exists (select 1 from pg_policies
                    where schemaname='public' and tablename=t
                      and roles = '{authenticated}'),
           format('the policy on %s is not restricted to authenticated', t);
  end loop;
end
$$;

do $$
declare
  ok boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';

  assert (select count(*) from public.section_types) = 11,
         'an authenticated user must be able to read the catalog';

  begin
    update public.section_types set label = 'Hijacked' where id = 'hero';
    ok := (select count(*) from public.section_types where label = 'Hijacked') = 0;
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client was able to rewrite the catalog';

  reset role;
end
$$;

rollback;
