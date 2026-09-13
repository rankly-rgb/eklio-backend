-- ============================================================================
-- The home page the product describes, as slots. Still empty.
-- ============================================================================
-- `site_spec_default_pages` seeded six sections on Home. The target is nine:
-- hero, introduction, what I work with, who I work with, how a first session
-- works, the approaches, common questions, writing, contact — and a footer.
--
-- This file creates the SLOTS and fills none of them. Every added section
-- arrives with an empty `body` or an empty `items`, which is exactly what the
-- existing types do, and the assembled builder prompt omits a section with no
-- content rather than emitting its heading. An empty site gains no headings
-- from this migration; it gains places to put words when there are words.
--
-- ⚠ `faq` WAS ALREADY ALLOWED ON HOME AND SEEDED OFF ON SERVICES. Turning it
-- on is data, not code, so it is turned on — on Services where it already sits,
-- and added to Home where the target names it.
--
-- ⚠ THE APPROACHES TEASER RIDES `services`, WHICH ALREADY EXISTS and is
-- already allowed on Home. A new "approaches teaser" type would have been a
-- fourth type doing what the third does, and the standing rule is to prefer
-- enabling an existing type over adding one.
--
-- ── Existing specs ────────────────────────────────────────────────────────
-- The seed runs once, so a practitioner who already has a spec would never see
-- any of this. Existing rows are therefore given the same slots, and the
-- update is written so that:
--
--   1. a section she already has is left exactly as it is — matched by `key`,
--      never replaced, so her copy and her `enabled` choice survive;
--   2. new sections are appended, so her own ordering is not renumbered;
--   3. a page she switched off stays off.
--
-- `spec_version` is deliberately NOT bumped: she did not edit anything, and a
-- version bump would tell her editor that her draft is stale.
-- ============================================================================

create or replace function public.site_spec_default_pages(p_specialties text[], p_personas text[])
returns jsonb
language sql
immutable
set search_path to ''
as $function$
  -- Section `key` equals section `type` for every seeded section. They diverge
  -- only when the user adds a second section of the same type to one page,
  -- which is exactly what the separate `key` exists to make possible.
  select jsonb_build_array(
    jsonb_build_object(
      'key', 'home', 'label', 'Home', 'enabled', true,
      'sections', jsonb_build_array(
        jsonb_build_object('key','hero','type','hero','enabled',true,'order',1,
                           'fields', '{}'::jsonb),
        jsonb_build_object('key','intro','type','intro','enabled',true,'order',2,
                           'fields', '{}'::jsonb),
        jsonb_build_object('key','specialties','type','specialties','enabled',true,'order',3,
                           'fields', jsonb_build_object(
                             'heading', 'What I work with',
                             'items', to_jsonb(coalesce(p_specialties, array[]::text[])))),
        jsonb_build_object('key','who_i_work_with','type','who_i_work_with','enabled',true,'order',4,
                           'fields', jsonb_build_object(
                             'heading', 'Who I work with',
                             'items', to_jsonb(coalesce(p_personas, array[]::text[])))),
        jsonb_build_object('key','first_session','type','first_session','enabled',true,'order',5,
                           'fields', jsonb_build_object('heading', 'How a first session works',
                                                        'items', '[]'::jsonb)),
        jsonb_build_object('key','services','type','services','enabled',true,'order',6,
                           'fields', jsonb_build_object('heading', 'How I work',
                                                        'body', '', 'items', '[]'::jsonb)),
        jsonb_build_object('key','faq','type','faq','enabled',true,'order',7,
                           'fields', jsonb_build_object('heading', 'Common questions',
                                                        'items', '[]'::jsonb)),
        jsonb_build_object('key','writing','type','writing','enabled',true,'order',8,
                           'fields', jsonb_build_object('heading', 'Writing', 'body', '')),
        jsonb_build_object('key','contact','type','contact','enabled',true,'order',9,
                           'fields', jsonb_build_object('heading', 'Get in touch', 'body', '')),
        jsonb_build_object('key','footer','type','footer','enabled',true,'order',10,
                           'fields', jsonb_build_object('body', '')))),
    jsonb_build_object(
      'key', 'about', 'label', 'About', 'enabled', true,
      'sections', jsonb_build_array(
        jsonb_build_object('key','intro','type','intro','enabled',true,'order',1,
                           'fields', '{}'::jsonb),
        jsonb_build_object('key','approach','type','approach','enabled',true,'order',2,
                           'fields', jsonb_build_object('heading', 'How I work', 'body', '')),
        jsonb_build_object('key','credentials','type','credentials','enabled',true,'order',3,
                           'fields', jsonb_build_object('heading', 'Training and licensure',
                                                        'items', '[]'::jsonb)),
        jsonb_build_object('key','footer','type','footer','enabled',true,'order',4,
                           'fields', jsonb_build_object('body', '')))),
    jsonb_build_object(
      'key', 'services', 'label', 'Services', 'enabled', true,
      'sections', jsonb_build_array(
        jsonb_build_object('key','services','type','services','enabled',true,'order',1,
                           'fields', jsonb_build_object('heading', 'Services',
                                                        'body', '', 'items', '[]'::jsonb)),
        jsonb_build_object('key','fees','type','fees','enabled',true,'order',2,
                           'fields', jsonb_build_object('heading', 'Fees',
                                                        'body', '', 'items', '[]'::jsonb)),
        jsonb_build_object('key','faq','type','faq','enabled',true,'order',3,
                           'fields', jsonb_build_object('heading', 'Common questions',
                                                        'items', '[]'::jsonb)),
        jsonb_build_object('key','footer','type','footer','enabled',true,'order',4,
                           'fields', jsonb_build_object('body', '')))),
    jsonb_build_object(
      'key', 'contact', 'label', 'Contact', 'enabled', true,
      'sections', jsonb_build_array(
        jsonb_build_object('key','contact','type','contact','enabled',true,'order',1,
                           'fields', jsonb_build_object('heading', 'Get in touch', 'body', '')),
        jsonb_build_object('key','footer','type','footer','enabled',true,'order',2,
                           'fields', jsonb_build_object('body', '')))),
    -- ⚠ OFF AND EMPTY. One section per approach needs her modalities joined and
    -- a body written; neither belongs to this file. Disabled, it is absent from
    -- `preview`, from the output and from the builder prompt.
    jsonb_build_object(
      'key', 'approaches', 'label', 'Approaches', 'enabled', false,
      'sections', '[]'::jsonb)
  )
$function$;

-- ── The specs that already exist ───────────────────────────────────────────
-- Append only what a page is missing, matched by `key`, after that page's
-- highest existing `order`. Anything she already has is untouched.
with defaults as (
  select pg.value->>'key' as page_key, pg.value as page
    from jsonb_array_elements(public.site_spec_default_pages(null, null)) as pg
),
rebuilt as (
  select s.brand_kit_id,
         jsonb_agg(
           case
             when d.page is null then p.value
             else jsonb_set(
               p.value, '{sections}',
               coalesce(p.value->'sections', '[]'::jsonb) || coalesce((
                 select jsonb_agg(
                          jsonb_set(ds.value, '{order}',
                                    to_jsonb(coalesce((
                                      select max((es.value->>'order')::int)
                                        from jsonb_array_elements(p.value->'sections') as es
                                    ), 0) + ds.ord)))
                   from jsonb_array_elements(d.page->'sections') with ordinality as ds(value, ord)
                  where not exists (
                    select 1 from jsonb_array_elements(p.value->'sections') as es
                     where es.value->>'key' = ds.value->>'key')
               ), '[]'::jsonb))
           end
           order by p.ord) as pages
    from public.site_specs s
    cross join lateral jsonb_array_elements(s.pages) with ordinality as p(value, ord)
    left join defaults d on d.page_key = p.value->>'key'
   group by s.brand_kit_id
)
update public.site_specs s
   set pages = r.pages, updated_at = now()
  from rebuilt r
 where r.brand_kit_id = s.brand_kit_id
   and r.pages is distinct from s.pages;

-- The `approaches` page is new, so no existing row has it to append into. It is
-- added whole, off and empty, to any spec that does not carry it yet.
update public.site_specs s
   set pages = s.pages || jsonb_build_array(
         jsonb_build_object('key','approaches','label','Approaches',
                            'enabled', false, 'sections', '[]'::jsonb)),
       updated_at = now()
 where not exists (
   select 1 from jsonb_array_elements(s.pages) as p where p.value->>'key' = 'approaches');
