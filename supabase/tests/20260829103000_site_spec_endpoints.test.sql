-- ============================================================================
-- Tests — 20260829103000_site_spec_endpoints.sql
--         20260829106000_site_spec_actions.sql
-- ============================================================================
-- The editor's whole round trip: read, edit, refuse, version, go stale, come
-- back clean, reset, switch builder, fix a contrast pair. And, throughout,
-- that a second user gets `not_found` and never `forbidden`.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000002','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Elm & Ember');
insert into public.project_briefs
  (project_id, practice_name, license_type_id, city, state, specialty_ids, client_persona_ids,
   builder_target_id)
values
  ('bbbbbbbb-0000-0000-0000-000000000001','Elm & Ember Therapy','lcsw','Portland','OR',
   array['anxiety','burnout'], array['high_functioning'], 'lovable');

insert into public.brand_kits (id, project_id, directions, selected_direction_id) values (
  'cccccccc-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
  jsonb_build_array(
    jsonb_build_object('id','quiet_confidence','name','Quiet Confidence',
      'rationale','Restraint reads as experience. For clients who want steadiness more than warmth.',
      'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
      'typography', jsonb_build_object('heading_font','Cormorant Garamond','body_font','Source Sans 3',
        'google_fonts_url','https://fonts.googleapis.com/css2?family=Cormorant+Garamond&display=swap'),
      'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','Experienced care, without the noise.',
        'subhead','Therapy for high-performing adults.','cta_label','Book a consult'),
      'about_excerpt','I work mostly with professionals who look fine from outside.',
      'tone_keywords', jsonb_build_array('composed','credible','unhurried')),
    jsonb_build_object('id','warm_welcome','name','Warm Welcome','rationale', repeat('y', 70),
      'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
      'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=Fraunces&display=swap'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c')),
    jsonb_build_object('id','modern_calm','name','Modern Calm','rationale', repeat('z', 70),
      'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
      'typography', jsonb_build_object('heading_font','Newsreader','body_font','Work Sans','google_fonts_url','https://fonts.googleapis.com/css2?family=Newsreader&display=swap'),
      'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
      'about_excerpt','x','tone_keywords', jsonb_build_array('a','b','c'))),
  'quiet_confidence');

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';

-- ---------------------------------------------------------------------------
-- GET: the whole editor state in one round trip
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  e   jsonb := public.site_spec_get(kit);
begin
  assert e ?& array['spec','preview','contrast','output','diff','etag'],
         'the envelope is missing a documented key';

  -- ⚠ Every writable key is readable back under the same name. What she reads
  -- is what she can write.
  assert not exists (
    select 1 from unnest(public.site_spec_patchable_keys()) k(name)
     where not (e->'spec' ? k.name)),
         'a patchable key is not readable back under the same name';

  -- product-facing token names, never the column names
  assert e->'spec'->>'primary' = '#3B2C3A', 'the primary token';
  assert not (e->'spec' ? 'primary_hex'), 'the _hex suffix reached the client';
  assert not (e->'spec' ? 'change_marks'), 'the storage-side change marks reached the client';

  assert e->'preview'->'tokens'->>'primary' = '#3B2C3A', 'the preview carries the tokens';
  assert jsonb_array_length(e->'contrast'->'pairs') = 7, 'the contrast panel carries seven pairs';
  -- ⚠ the variants are rendered, never edited: in preview.tokens, not in spec
  assert e->'preview'->'tokens' ?& array['primary_text','secondary_text','accent_text','cta_ink'],
         'the mockup cannot paint text in a brand colour without the variants';
  assert not (e->'spec' ?| array['primary_text','secondary_text','accent_text','cta_ink']),
         'a derived variant leaked into the editable spec';
  assert not ('primary_text' = any (public.site_spec_patchable_keys())),
         'a derived variant became patchable';
  -- ⚠ paper is a token of its own again, and is not the band tint
  assert e->'spec'->>'paper' is not null, 'the envelope must carry the page background';
  assert e->'spec'->>'paper' <> e->'spec'->>'light_neutral',
         'paper and light_neutral must not collapse into one value';

  -- the brief's builder answer wins over the kit's own column
  assert e->'spec'->>'target' = 'lovable', 'the target must come from the brief';
  assert e->'output'->>'kind' = 'prompt',  'Lovable gets a prompt';

  assert (e->'diff'->>'stale')::boolean = false,
         'a spec that was never copied cannot be stale';
end
$$;

-- ---------------------------------------------------------------------------
-- PATCH: what it accepts, and what it names when it refuses
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  e   jsonb;
begin
  -- hex is uppercased on the way in, so one spec renders one identical output
  e := public.site_spec_patch(kit, '{"primary":"#c08a3e"}');
  assert e->'spec'->>'primary' = '#C08A3E', 'a patched hex must be stored uppercase';
  assert (e->'spec'->>'spec_version')::int = 2, 'a real edit bumps the version';

  -- ⚠ A NO-OP MUST NOT BUMP. Autosave fires on the keystroke that types a
  -- character and on the one that deletes it again.
  e := public.site_spec_patch(kit, '{"primary":"#C08A3E"}');
  assert (e->'spec'->>'spec_version')::int = 2, 'a no-op patch bumped the version';
  e := public.site_spec_patch(kit, '{}');
  assert (e->'spec'->>'spec_version')::int = 2, 'an empty patch bumped the version';

  -- only the fields present are touched
  e := public.site_spec_patch(kit, '{"about_excerpt":"My own words."}');
  assert e->'spec'->>'primary' = '#C08A3E',       'a partial patch changed a field it was not given';
  assert e->'spec'->>'about_excerpt' = 'My own words.', 'the patched field did not take';

  -- the hero merges key by key: the editor saves one input at a time
  e := public.site_spec_patch(kit, '{"hero":{"headline":"A calmer place to start."}}');
  assert e->'spec'->'hero'->>'headline' = 'A calmer place to start.', 'the headline did not take';
  assert e->'spec'->'hero'->>'cta_label' = 'Book a consult',
         'a hero patch dropped the four fields she was not typing in';

  -- choosing a pairing adopts its faces, or the picker would be lying
  e := public.site_spec_patch(kit, '{"type_pairing_id":"lora_source3"}');
  assert e->'spec'->>'heading_font' = 'Lora',          'a pairing must adopt its heading face';
  assert e->'spec'->>'body_font'    = 'Source Sans 3', 'a pairing must adopt its body face';
  assert e->'spec'->>'google_fonts_url' like '%Lora%', 'a pairing must adopt its stylesheet';
end
$$;

-- Field errors name the field and the limit, so the message can sit under the
-- input she is typing in.
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  before int;
  e jsonb;
begin
  select spec_version into before from public.site_specs where brand_kit_id = kit;

  e := public.site_spec_patch(kit, jsonb_build_object('hero',
         jsonb_build_object('headline', repeat('x', 91))));
  assert e->'error'->>'code'  = 'too_long',      'a 91-character headline was accepted';
  assert e->'error'->>'field' = 'hero.headline', 'the error must name the field';
  assert e->'error'->>'message' = 'This is 91 characters. The limit is 90.',
         'the error must name the limit';

  -- exactly at the limit is fine
  assert public.site_spec_patch(kit, jsonb_build_object('hero',
           jsonb_build_object('headline', repeat('x', 90)))) ? 'spec',
         'a 90-character headline was refused';

  assert public.site_spec_patch(kit, jsonb_build_object('about_excerpt', repeat('x', 601)))
           ->'error'->>'code' = 'too_long', 'a 601-character About text was accepted';
  assert public.site_spec_patch(kit, jsonb_build_object('extra_instructions', repeat('x', 2001)))
           ->'error'->>'code' = 'too_long', 'a 2001-character note was accepted';

  assert public.site_spec_patch(kit, '{"primary":"3B2C3A"}')->'error'->>'code' = 'invalid_field',
         'a hex without its hash was accepted';
  assert public.site_spec_patch(kit, '{"colour":"#000000"}')->'error'->>'code' = 'unknown_field',
         'an unknown field was accepted';
  assert public.site_spec_patch(kit, '{"hero":{"tagline":"x"}}')->'error'->>'field' = 'hero.tagline',
         'an unknown hero field was accepted';
  assert public.site_spec_patch(kit, '{"target":"wordpress"}')->'error'->>'code' = 'invalid_field',
         'an unsupported builder was accepted';
  assert public.site_spec_patch(kit, '{"type_pairing_id":"comic_sans"}')->'error'->>'code' = 'invalid_field',
         'a type pairing outside the catalog was accepted';

  -- ⚠ printed verbatim into a document meant to be pasted into a builder
  assert public.site_spec_patch(kit, '{"hero":{"cta_target_url":"javascript:alert(1)"}}')
           ->'error'->>'field' = 'hero.cta_target_url',
         'a javascript: call-to-action target was accepted';

  -- a section is refused on a page its type does not allow
  assert public.site_spec_patch(kit, jsonb_build_object('pages', jsonb_build_array(
           jsonb_build_object('key','contact','label','Contact','enabled',true,
             'sections', jsonb_build_array(jsonb_build_object(
               'key','hero','type','hero','enabled',true,'order',1,'fields','{}'::jsonb))))))
           ->'error'->>'code' = 'invalid_field',
         'a hero was allowed onto the contact page';

  -- an over-long section field is named by its path
  assert public.site_spec_patch(kit, jsonb_build_object('pages',
           jsonb_set(public.site_spec_default_pages(null,null),
                     '{1,sections,1,fields,body}', to_jsonb(repeat('x', 801)))))
           ->'error'->>'field' = 'pages[1].sections[1].fields.body',
         'an over-long section field was not located for the editor';

  -- ⚠ AND NOTHING WAS WRITTEN BY ANY OF IT
  assert (select spec_version from public.site_specs where brand_kit_id = kit) = before + 1,
         'a refused patch wrote to the row (only the one accepted 90-char edit should count)';
end
$$;

-- ---------------------------------------------------------------------------
-- Versions, staleness, and mark-copied
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  e   jsonb;
  v   int;
begin
  e := public.site_output_mark_copied(kit);
  assert (e->'diff'->>'stale')::boolean = false, 'marking copied must clear the banner';
  assert jsonb_array_length(e->'diff'->'changes') = 0, 'a freshly copied spec has no changes';
  assert (e->'spec'->>'last_copied_spec_version')::int = (e->'spec'->>'spec_version')::int,
         'mark-copied must record the current version';
  v := (e->'spec'->>'spec_version')::int;

  -- ⚠ and it must NOT advance the spec, or the banner would come back up the
  -- instant it was cleared
  assert (public.site_output_mark_copied(kit)->'spec'->>'spec_version')::int = v,
         'mark-copied bumped the version';

  -- an edit goes stale, with a readable reason
  e := public.site_spec_patch(kit, '{"primary":"#22364F"}');
  assert (e->'diff'->>'stale')::boolean = true, 'an edit after a copy must go stale';
  assert e->'diff'->'changes' = '[{"area": "colors", "label": "Primary color changed"}]'::jsonb,
         'the diff must say what changed, in words';
  assert (e->'spec'->>'spec_version')::int = v + 1, 'the edit must bump the version';

  -- copying again clears it
  assert (public.site_output_mark_copied(kit)->'diff'->>'stale')::boolean = false,
         'copying again must clear the banner';

  -- structure and copy are different news, and both come from `pages`
  e := public.site_spec_patch(kit, jsonb_build_object('pages',
         jsonb_set((public.site_spec_get(kit)->'spec'->'pages'), '{1,enabled}', 'false'::jsonb)));
  assert e->'diff'->'changes' @> '[{"area":"structure","label":"Page structure changed"}]'::jsonb,
         'toggling a page off is a structure change';
  assert not (e->'diff'->'changes' @> '[{"area":"copy","label":"Section copy edited"}]'::jsonb),
         'toggling a page off is not a copy edit';

  perform public.site_output_mark_copied(kit);
  e := public.site_spec_patch(kit, jsonb_build_object('pages',
         jsonb_set((public.site_spec_get(kit)->'spec'->'pages'),
                   '{0,sections,4,fields,body}', '"Call or email, whichever is easier."'::jsonb)));
  assert e->'diff'->'changes' @> '[{"area":"copy","label":"Section copy edited"}]'::jsonb,
         'rewording a section is a copy edit';
  assert not (e->'diff'->'changes' @> '[{"area":"structure","label":"Page structure changed"}]'::jsonb),
         'rewording a section is not a structure change';
end
$$;

-- ---------------------------------------------------------------------------
-- The output on its own, and its formats
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  o   jsonb;
begin
  o := public.site_output_get(kit);
  assert o->>'format' = 'json' and o->'output'->>'kind' = 'prompt', 'json is the default format';

  o := public.site_output_get(kit, 'squarespace', 'md');
  assert o->>'target' = 'squarespace', 'the requested target must be honored';
  assert o->>'text' like '# Squarespace%', 'md is the print path';

  assert public.site_output_get(kit, null, 'txt') ? 'text', 'txt must render';
  assert public.site_output_get(kit, null, 'pdf')->'error'->>'code' = 'invalid_format',
         'an unsupported format must be refused';
  assert public.site_output_get(kit, 'wordpress', 'json')->'error'->>'code' = 'invalid_target',
         'an unknown builder must be refused';

  -- asking for another target does not change the spec
  assert (public.site_spec_get(kit)->'spec'->>'target') = 'lovable',
         'reading the output for another builder must not switch the builder';
end
$$;

-- `brand_kits.site_prompt` keeps working for whatever already reads it.
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
begin
  assert (select site_prompt from public.brand_kits where id = kit) is not null,
         'the cached site_prompt was not refreshed';
  assert (select site_prompt_target from public.brand_kits where id = kit) = 'lovable',
         'the cached target was not refreshed';

  perform public.site_spec_patch(kit, '{"hero":{"headline":"Cached copy check."}}');
  assert (select site_prompt from public.brand_kits where id = kit)
         like '%Cached copy check.%',
         'an edit did not reach the cached copy';
end
$$;

-- ---------------------------------------------------------------------------
-- Reset
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  e   jsonb;
begin
  perform public.site_spec_patch(kit, '{"primary":"#FF0000","about_excerpt":"My own words."}');

  -- ⚠ resetting one scope must not cost her another
  e := public.site_spec_reset(kit, 'colors');
  assert e->'spec'->>'primary' = '#3B2C3A',            'reset colors did not restore the direction';
  assert e->'spec'->>'about_excerpt' = 'My own words.', 'reset colors destroyed her copy';

  -- resetting copy keeps the structure she built
  e := public.site_spec_patch(kit, jsonb_build_object('pages',
         jsonb_set((public.site_spec_get(kit)->'spec'->'pages'), '{2,enabled}', 'false'::jsonb)));
  e := public.site_spec_reset(kit, 'copy');
  assert (e->'spec'->'pages'->2->>'enabled')::boolean = false,
         'reset copy undid a structure change she made';
  assert e->'spec'->>'about_excerpt' = 'I work mostly with professionals who look fine from outside.',
         'reset copy did not restore the direction''s text';

  -- resetting structure keeps the copy of every section it still has room for
  e := public.site_spec_patch(kit, jsonb_build_object('pages',
         jsonb_set((public.site_spec_get(kit)->'spec'->'pages'),
                   '{0,sections,4,fields,body}', '"Kept across a structure reset."'::jsonb)));
  e := public.site_spec_reset(kit, 'structure');
  assert (e->'spec'->'pages'->2->>'enabled')::boolean = true,
         'reset structure did not restore the default layout';
  assert e->'spec'->'pages'->0->'sections'->4->'fields'->>'body'
         = 'Kept across a structure reset.',
         'reset structure threw away copy the default layout still had room for';

  -- ⚠ no scope touches the builder or her booking link
  perform public.site_spec_patch(kit, '{"target":"webflow"}');
  perform public.site_spec_patch(kit, '{"hero":{"cta_target_url":"https://calendly.com/nora"}}');
  e := public.site_spec_reset(kit, 'all');
  assert e->'spec'->>'target' = 'webflow',
         'reset all sent her back to a different website builder';
  assert e->'spec'->'hero'->>'cta_target_url' = 'https://calendly.com/nora',
         'reset all erased her booking link, which no direction ever produced';
  assert e->'spec'->>'primary' = '#3B2C3A', 'reset all did not restore the colors';

  assert public.site_spec_reset(kit, 'everything')->'error'->>'code' = 'invalid_scope',
         'an unknown scope was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- Switching builder regenerates the output and touches nothing else
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
  before jsonb;
  e jsonb;
begin
  before := public.site_spec_get(kit)->'spec';
  e := public.site_spec_set_target(kit, 'wix');

  assert e->'spec'->>'target' = 'wix',              'the builder did not switch';
  assert e->'output'->>'kind' = 'setup_sheet',      'Wix has no prompt input and must get a sheet';
  assert ((e->'spec') - 'target' - 'spec_version' - 'updated_at')
       = (before      - 'target' - 'spec_version' - 'updated_at'),
         'switching builder changed something else in the spec';
  assert (select site_prompt_target from public.brand_kits where id = kit) = 'wix',
         'the cached target did not follow';

  assert public.site_spec_set_target(kit, 'wordpress')->'error'->>'code' = 'invalid_field',
         'an unsupported builder was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- Fix contrast, in one click
-- ---------------------------------------------------------------------------
do $$
declare
  kit  uuid := 'cccccccc-0000-0000-0000-000000000001';
  e    jsonb;
  pair jsonb;
begin
  -- ⚠ Four derived colours now cover every brand-colour-as-text pair and the
  -- button label, so the pairs that can still fail are the neutral ones: they
  -- have no variant, because `dark_neutral` IS the ink. A mid-grey body text on
  -- a light page is the case a therapist actually creates.
  e := public.site_spec_patch(kit, '{"primary":"#B4674A","paper":"#FAF6EE","light_neutral":"#F4EEE3","dark_neutral":"#8A8A8A"}');
  select p.value into pair from jsonb_array_elements(e->'contrast'->'pairs') p
   where p.value->>'pair_id' = 'dark_neutral_on_light_neutral';
  assert (pair->>'ratio')::numeric = 2.99,            'the fixture pair must fail';
  assert pair->'suggested_fix'->>'token' = 'dark_neutral', 'the fix must move the ink';

  -- ⚠ the spec saved anyway. Contrast is reported and fixable, never a wall.
  assert e ? 'spec', 'a failing contrast pair blocked a write';

  e := public.site_spec_fix_contrast(kit, 'dark_neutral_on_light_neutral');
  select p.value into pair from jsonb_array_elements(e->'contrast'->'pairs') p
   where p.value->>'pair_id' = 'dark_neutral_on_light_neutral';
  assert (pair->>'ratio')::numeric >= 4.5,   'the one-click fix did not reach AA';
  assert pair->'suggested_fix' = 'null'::jsonb, 'a fixed pair is still offering a fix';
  assert e->'spec'->>'dark_neutral' <> '#8A8A8A', 'the fix was not applied to the spec';
  assert e->'spec'->>'paper' = '#FAF6EE',
         'the fix moved the page background, which five other pairs are measured against';

  -- applying it again is a no-op with a reason, not a second edit
  assert public.site_spec_fix_contrast(kit, 'dark_neutral_on_light_neutral')->'error'->>'code'
         = 'no_fix_needed', 'fixing an already-readable pair was treated as work';

  -- ⚠ a text variant is never a token she can be asked to fix
  assert not exists (
    select 1 from jsonb_array_elements(
             public.site_spec_get(kit)->'contrast'->'pairs') p
     where p.value->'suggested_fix'->>'token' in ('primary_text','secondary_text',
                                                   'accent_text','cta_ink')),
         'a derived colour was offered as a suggested_fix token';
  assert public.site_spec_fix_contrast(kit, 'nope')->'error'->>'code' = 'invalid_field',
         'an unknown pair id was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ 404, never 403. No code path knows a row exists and declines to show it.
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'cccccccc-0000-0000-0000-000000000001';
begin
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002"}';

  assert public.site_spec_get(kit)->'error'->>'code' = 'not_found',
         'a stranger reading must get not_found';
  assert public.site_spec_patch(kit, '{"primary":"#000000"}')->'error'->>'code' = 'not_found',
         'a stranger writing must get not_found';
  assert public.site_spec_reset(kit, 'all')->'error'->>'code' = 'not_found',
         'a stranger resetting must get not_found';
  assert public.site_spec_set_target(kit, 'wix')->'error'->>'code' = 'not_found',
         'a stranger switching builder must get not_found';
  assert public.site_output_mark_copied(kit)->'error'->>'code' = 'not_found',
         'a stranger marking copied must get not_found';
  assert public.site_spec_fix_contrast(kit, 'primary_on_paper')->'error'->>'code' = 'not_found',
         'a stranger fixing contrast must get not_found';
  assert public.site_output_get(kit)->'error'->>'code' = 'not_found',
         'a stranger reading the output must get not_found';

  -- and the answer for a kit that does not exist is identical, so the error
  -- cannot be used to discover which kits are real
  assert public.site_spec_get('00000000-0000-0000-0000-000000000000')->'error'
       = public.site_spec_get(kit)->'error',
         'a stranger''s kit is distinguishable from a nonexistent one';

  assert (select count(*) from public.site_specs) = 0,
         'a stranger must see zero rows, not an error';
end
$$;

rollback;
