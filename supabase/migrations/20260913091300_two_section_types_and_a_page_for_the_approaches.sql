-- ============================================================================
-- Two section types the product has been describing and could not store
-- ============================================================================
-- The target home page is: hero, introduction, what I work with, who I work
-- with, HOW A FIRST SESSION WORKS, the approaches, common questions, WRITING,
-- contact. Of those, `faq` already existed, the approaches teaser fits
-- `services` (allowed on home, heading + body + items), and two had no type at
-- all — so the product could describe them and had nowhere to put them.
--
--   `first_session` — three short steps. `items`, not `body`: a visitor
--                     scanning "what happens if I email you" reads three
--                     stops, and a paragraph pretending to be a list is the
--                     thing this type exists to stop being written.
--   `writing`       — the blog teaser. Heading, one short lead, and that is
--                     all: the posts come from the blog itself, so a longer
--                     field here would only invite duplicating them.
--
-- And a page kind. Each approach she works in gets its own page, and pages are
-- a closed set (`site_spec_page_keys`), so `approaches` is added to it with a
-- section type sized to one approach's body.
--
-- ⚠ THE APPROACHES PAGE IS SEEDED DISABLED AND EMPTY. One section per modality
-- means knowing her modalities, and that is a join this file does not make and
-- a body this chantier does not write. An empty page that is switched off adds
-- no heading to anything: `enabled: false` drops it from `preview`, from the
-- output, and from the builder prompt. The page kind exists so that the lot
-- which fills it does not also have to invent a schema.
--
-- ⚠ AND NOTHING HERE EMITS A HEADING OVER NOTHING. Every one of these is
-- omittable exactly as the existing types are: empty `items`, an empty `body`,
-- or `enabled: false`, and the assembled builder prompt leaves the section out
-- rather than printing its heading. That is the standing rule for a new slot.
--
-- Maxima follow the same arithmetic as the caps migration (6.1 characters per
-- word, rounded up with room for one long sentence), and every one of them
-- sits under the 2000 backstop that migration set:
--
--   first_session.items    70 w → 427  →  600, each step
--   writing.body                       →  600
--   approach_page.body    260 w → 1586 → 1800
-- ============================================================================

insert into public.section_types (id, label, description, allowed_pages, sort_order, fields)
values
  ('first_session',
   'How a first session works',
   'The first few steps, in order, so a visitor knows what happens if they write. Three short steps, each one thing that happens.',
   array['home', 'about', 'services'],
   12,
   '[{"key":"heading","kind":"text","label":"Heading","max_length":80},
     {"key":"items","kind":"list","label":"Steps","max_length":600}]'::jsonb),

  ('writing',
   'Writing',
   'A short lead pointing at the blog. The posts live on the blog; this says why they are there.',
   array['home', 'about'],
   13,
   '[{"key":"heading","kind":"text","label":"Heading","max_length":80},
     {"key":"body","kind":"longtext","label":"Lead","max_length":600}]'::jsonb),

  ('approach_page',
   'One approach',
   'What one approach looks like in this practice. Factual: what the work involves, never what it is good for.',
   array['approaches'],
   14,
   '[{"key":"heading","kind":"text","label":"Approach","max_length":80},
     {"key":"body","kind":"longtext","label":"Body","max_length":1800}]'::jsonb)
on conflict (id) do nothing;

-- ── The two closed sets the validators read ────────────────────────────────
-- `site_spec_pages_valid` checks a section's type against `section_types` (the
-- table) and a page's key against this array, so the array is the half that
-- does not follow the insert above on its own.
create or replace function public.site_spec_page_keys()
returns text[]
language sql
immutable
set search_path to ''
as $function$
  select array['home', 'about', 'services', 'contact', 'approaches']
$function$;

create or replace function public.site_spec_section_types()
returns text[]
language sql
immutable
set search_path to ''
as $function$
  select array['hero', 'intro', 'specialties', 'who_i_work_with', 'approach',
               'services', 'fees', 'faq', 'credentials', 'contact', 'footer',
               'first_session', 'writing', 'approach_page']
$function$;
