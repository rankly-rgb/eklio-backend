-- ============================================================================
-- Eklio — local seed
-- ============================================================================
-- Run by `supabase db reset` ONLY. It never reaches the hosted project.
--
-- WHY THIS FILE DUPLICATES A MIGRATION
-- -----------------------------------
-- The reference catalogs are production data: without them the brief has no
-- cards to offer and `brief_preview()` resolves nothing. They therefore ship
-- inside `20260827100000_catalog_reference_data.sql`, which is what reaches
-- `fobgdsupyfslxbswfuay`.
--
-- But `db push` does not run seed files and `db reset` does not replay data
-- into a hosted project — the two mechanisms reach different places, and
-- neither reaches both. A catalog that lived only in the migration would still
-- be present locally (the migration replays on reset), so strictly this file
-- is belt and braces; it exists so that a local database stays usable if the
-- catalog is ever moved out of the migration, and so that `db reset` is
-- self-describing.
--
-- ⚠ THE TWO BLOCKS BELOW ARE VERBATIM COPIES of the marked regions of two
-- migrations. Never edit them here. Edit the migration, then regenerate:
--
--   awk '/^-- >>> CATALOG DATA/,/^-- <<< CATALOG DATA/' \
--     supabase/migrations/20260827100000_catalog_reference_data.sql \
--     > /tmp/catalog.sql
--
--   awk '/^-- >>> SITE SPEC CATALOG DATA/,/^-- <<< SITE SPEC CATALOG DATA/' \
--     supabase/migrations/20260829101000_site_spec_catalog.sql \
--     > /tmp/site-spec-catalog.sql
--
-- and splice each in below this header, in that order. The upserts are
-- idempotent, so running them after the migrations have already inserted the
-- rows is a no-op.
-- ============================================================================

-- >>> CATALOG DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ---- tone_cards ------------------------------------------------------------
insert into public.tone_cards (id, sort_order, active, sample_hero, keywords) values
  ('grounded',         1, true, 'You don''t need to have it figured out before you call.', array['steady','plainspoken','warm']),
  ('clear',            2, true, 'Therapy with a plan you can actually see.',               array['clear','structured','direct']),
  ('gentle',           3, true, 'A slower place to work things through.',                  array['soft','patient','unhurried']),
  ('warm_practical',   4, true, 'Real conversations about what''s not working.',           array['warm','practical','honest']),
  ('quiet_confidence', 5, true, 'Experienced care, without the noise.',                    array['composed','credible','calm']),
  ('open',             6, true, 'We''ll figure out together what this work needs to be.',  array['open','curious','collaborative'])
on conflict (id) do update set
  sort_order  = excluded.sort_order,
  active      = excluded.active,
  sample_hero = excluded.sample_hero,
  keywords    = excluded.keywords;

-- ---- palette_families ------------------------------------------------------
insert into public.palette_families
  (id, sort_order, active, label, primary_hex, secondary_hex, light_hex, dark_hex, paper_hex, swatches, preview_tokens) values
  ('plum_bone',      1, true, 'PLUM & BONE',      '#3B2C3A', '#4A5361', '#F3EDE4', '#241B23', '#FAF7F2',
   array['#3B2C3A','#4A5361','#F3EDE4'],
   '{"primary":"#3B2C3A","secondary":"#4A5361","light":"#F3EDE4","dark":"#241B23","paper":"#FAF7F2"}'::jsonb),
  ('clay_sand',      2, true, 'CLAY & SAND',      '#B4674A', '#C08A3E', '#F4EEE3', '#2B2A27', '#FAF6EE',
   array['#B4674A','#C08A3E','#F4EEE3'],
   '{"primary":"#B4674A","secondary":"#C08A3E","light":"#F4EEE3","dark":"#2B2A27","paper":"#FAF6EE"}'::jsonb),
  ('ink_blue_chalk', 3, true, 'INK BLUE & CHALK', '#22364F', '#7A8168', '#EDEAE5', '#16202E', '#F7F6F3',
   array['#22364F','#7A8168','#EDEAE5'],
   '{"primary":"#22364F","secondary":"#7A8168","light":"#EDEAE5","dark":"#16202E","paper":"#F7F6F3"}'::jsonb),
  ('olive_chalk',    4, true, 'OLIVE & CHALK',    '#7A8168', '#3F4536', '#EDEAE5', '#262A20', '#F7F7F3',
   array['#7A8168','#3F4536','#EDEAE5'],
   '{"primary":"#7A8168","secondary":"#3F4536","light":"#EDEAE5","dark":"#262A20","paper":"#F7F7F3"}'::jsonb),
  ('ochre_paper',    5, true, 'OCHRE & PAPER',    '#C08A3E', '#6B4B1C', '#F6F2EA', '#2A2118', '#FBF8F1',
   array['#C08A3E','#6B4B1C','#F6F2EA'],
   '{"primary":"#C08A3E","secondary":"#6B4B1C","light":"#F6F2EA","dark":"#2A2118","paper":"#FBF8F1"}'::jsonb),
  ('slate_bone',     6, true, 'SLATE & BONE',     '#4A5361', '#2F3742', '#F3EDE4', '#1E242C', '#F9F7F3',
   array['#4A5361','#2F3742','#F3EDE4'],
   '{"primary":"#4A5361","secondary":"#2F3742","light":"#F3EDE4","dark":"#1E242C","paper":"#F9F7F3"}'::jsonb)
on conflict (id) do update set
  sort_order     = excluded.sort_order,
  active         = excluded.active,
  label          = excluded.label,
  primary_hex    = excluded.primary_hex,
  secondary_hex  = excluded.secondary_hex,
  light_hex      = excluded.light_hex,
  dark_hex       = excluded.dark_hex,
  paper_hex      = excluded.paper_hex,
  swatches       = excluded.swatches,
  preview_tokens = excluded.preview_tokens;

-- ---- type_pairings ---------------------------------------------------------
insert into public.type_pairings (id, sort_order, active, heading_font, body_font, google_fonts_url) values
  ('fraunces_nunito',   1, true, 'Fraunces',           'Nunito Sans',
   'https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Nunito+Sans:wght@400;600;700&display=swap'),
  ('cormorant_source',  2, true, 'Cormorant Garamond', 'Source Sans 3',
   'https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&family=Source+Sans+3:wght@400;600;700&display=swap'),
  ('newsreader_work',   3, true, 'Newsreader',         'Work Sans',
   'https://fonts.googleapis.com/css2?family=Newsreader:wght@500;600&family=Work+Sans:wght@400;600;700&display=swap'),
  ('lora_source3',      4, true, 'Lora',               'Source Sans 3',
   'https://fonts.googleapis.com/css2?family=Lora:wght@500;600&family=Source+Sans+3:wght@400;600;700&display=swap'),
  ('caslon_inter',      5, true, 'Libre Caslon Text',  'Inter',
   'https://fonts.googleapis.com/css2?family=Libre+Caslon+Text:wght@400;700&family=Inter:wght@400;600;700&display=swap'),
  ('sourceserif_inter', 6, true, 'Source Serif 4',     'Inter',
   'https://fonts.googleapis.com/css2?family=Source+Serif+4:wght@500;600&family=Inter:wght@400;600;700&display=swap')
on conflict (id) do update set
  sort_order       = excluded.sort_order,
  active           = excluded.active,
  heading_font     = excluded.heading_font,
  body_font        = excluded.body_font,
  google_fonts_url = excluded.google_fonts_url;

-- ---- client_persona_cards --------------------------------------------------
insert into public.client_persona_cards (id, sort_order, active, label, description) values
  ('couples_roommates',   1, true, 'Couples who feel more like roommates',
   'Partners in their thirties and forties who share a calendar but little else.'),
  ('carrying_old_thing',  2, true, 'Adults carrying something from years back',
   'Something that happened long ago still shapes how they sleep, work and trust.'),
  ('high_functioning',    3, true, 'Professionals who look fine from outside',
   'They hit every deadline and cannot remember the last time they felt rested.'),
  ('quiet_teenager',      4, true, 'Parents of a teenager who has gone quiet',
   'The door closes earlier every year and they no longer know what to ask.'),
  ('new_parents',         5, true, 'New parents who did not expect to feel this',
   'Love and dread arrived together, and neither of them says it out loud.'),
  ('crossroads',          6, true, 'Adults at a crossroads they did not choose',
   'A layoff, a diagnosis or a move ended the version of life they had planned.'),
  ('first_time_therapy',  7, true, 'First-timers who almost did not call',
   'They have talked themselves out of this appointment at least three times.'),
  ('quiet_loss',          8, true, 'People carrying a loss nobody mentions',
   'Months have passed and everyone around them has moved on to other things.'),
  ('family_expectations', 9, true, 'Adults renegotiating family expectations',
   'Who they are and who they were raised to be no longer fit in one room.'),
  ('caregivers',         10, true, 'Caregivers who never get to be the patient',
   'They hold a parent, a partner or a child together on whatever is left.')
on conflict (id) do update set
  sort_order  = excluded.sort_order,
  active      = excluded.active,
  label       = excluded.label,
  description = excluded.description;

-- ---- problem_cards ---------------------------------------------------------
insert into public.problem_cards (id, sort_order, active, label, description) values
  ('cant_switch_off',   1, true, 'Cannot switch off, even on a good day',
   'Work ends and the mind keeps going, all evening and into the night.'),
  ('worry_in_the_body', 2, true, 'Worry that shows up in the body first',
   'A tight chest and a short fuse arrive before the thought does.'),
  ('running_on_empty',  3, true, 'Running on empty and calling it normal',
   'The work still gets done, but none of it feels like it used to.'),
  ('same_argument',     4, true, 'The same argument on repeat',
   'Two people who love each other keep landing in the same twenty minutes.'),
  ('past_still_here',   5, true, 'Something old that still shows up',
   'It surfaces in reactions far larger than the moment seems to deserve.'),
  ('unsettled_loss',    6, true, 'A loss that has not settled',
   'The world moved on at a pace that never once matched theirs.'),
  ('harsh_inner_voice', 7, true, 'An inner voice that never lets up',
   'Nothing is ever quite enough, and the bar moves every time they reach it.'),
  ('fast_transition',   8, true, 'A transition that arrived too fast',
   'A move, a role or a diagnosis rearranged the plan without asking.')
on conflict (id) do update set
  sort_order  = excluded.sort_order,
  active      = excluded.active,
  label       = excluded.label,
  description = excluded.description;

-- ---- gain_cards ------------------------------------------------------------
insert into public.gain_cards (id, sort_order, active, label, description) values
  ('rest_without_guilt', 1, true, 'Rest that does not need to be earned',
   'An evening off that is not paid for with a worse morning after.'),
  ('steadier_reactions', 2, true, 'A steadier reaction to hard moments',
   'The same difficult day, met with something other than a clenched jaw.'),
  ('real_conversations', 3, true, 'Conversations that go somewhere',
   'Saying the true thing without it turning into the same argument.'),
  ('a_name_for_it',      4, true, 'An explanation that finally fits',
   'Language for a pattern they have carried for years without a name.'),
  ('boundaries_hold',    5, true, 'Boundaries that hold without a fight',
   'A no that stays no, and a week with some room left in it.'),
  ('feeling_close',      6, true, 'Feeling close to someone again',
   'Two people in the same room who are actually in the same room.'),
  ('room_to_grieve',     7, true, 'Room to grieve at their own pace',
   'A place where the loss is still allowed to be recent.'),
  ('a_step_of_their_own', 8, true, 'A next step that is theirs to choose',
   'A direction that came from them and not from the circumstances.')
on conflict (id) do update set
  sort_order  = excluded.sort_order,
  active      = excluded.active,
  label       = excluded.label,
  description = excluded.description;

-- ---- ethics_rules ----------------------------------------------------------
-- The example_forbidden values for timeframe, client_voice and scarcity are
-- rendered verbatim in the "Never write this" column on Screen 6.
insert into public.ethics_rules (id, sort_order, active, short_label, description, example_forbidden) values
  ('timeframe',    1, true, 'No timeframes',
   'No timeframe or session count attached to relief or results.',
   'Heal your anxiety in 12 weeks.'),
  ('proven',       2, true, 'No proven claims',
   'No modality described as clinically proven, guaranteed, curing or resolving.',
   'A clinically proven method that resolves trauma for good.'),
  ('client_voice', 3, true, 'No client voice',
   'No client quotes, paraphrased client statements, or "clients often say".',
   'Clients often tell me...'),
  ('credential',   4, true, 'No inflated credentials',
   'No training, workshop or CE course presented as a certification.',
   'Certified in EMDR after a weekend intensive.'),
  ('scarcity',     5, true, 'No scarcity',
   'No scarcity or ranking language.',
   'Limited spots available.'),
  ('diagnosis',    6, true, 'No diagnosis of the reader',
   'No diagnostic label applied to the reader; "if you have PTSD" becomes "if something from the past still shows up".',
   'If you have PTSD, this page is for you.')
on conflict (id) do update set
  sort_order        = excluded.sort_order,
  active            = excluded.active,
  short_label       = excluded.short_label,
  description       = excluded.description,
  example_forbidden = excluded.example_forbidden;

-- ---- license_types ---------------------------------------------------------
insert into public.license_types (id, sort_order, active, label, description) values
  ('lcsw',  1, true, 'LCSW',  'Licensed Clinical Social Worker'),
  ('lmft',  2, true, 'LMFT',  'Licensed Marriage and Family Therapist'),
  ('lpc',   3, true, 'LPC',   'Licensed Professional Counselor'),
  ('lpcc',  4, true, 'LPCC',  'Licensed Professional Clinical Counselor'),
  ('lmhc',  5, true, 'LMHC',  'Licensed Mental Health Counselor'),
  ('lcpc',  6, true, 'LCPC',  'Licensed Clinical Professional Counselor'),
  ('licsw', 7, true, 'LICSW', 'Licensed Independent Clinical Social Worker'),
  ('lmsw',  8, true, 'LMSW',  'Licensed Master Social Worker'),
  ('psyd',  9, true, 'PsyD',  'Doctor of Psychology'),
  ('phd',  10, true, 'PhD',   'Doctor of Philosophy in Psychology')
on conflict (id) do update set
  sort_order  = excluded.sort_order,
  active      = excluded.active,
  label       = excluded.label,
  description = excluded.description;

-- ---- specialties -----------------------------------------------------------
insert into public.specialties (id, sort_order, active, label) values
  ('anxiety',          1, true, 'Anxiety'),
  ('burnout',          2, true, 'Burnout'),
  ('trauma',           3, true, 'Trauma'),
  ('couples',          4, true, 'Couples'),
  ('grief',            5, true, 'Grief'),
  ('depression',       6, true, 'Depression'),
  ('life_transitions', 7, true, 'Life transitions'),
  ('relationships',    8, true, 'Relationships'),
  ('parenting',        9, true, 'Parenting'),
  ('self_esteem',     10, true, 'Self-esteem'),
  ('identity',        11, true, 'Identity'),
  ('adhd',            12, true, 'ADHD')
on conflict (id) do update set
  sort_order = excluded.sort_order,
  active     = excluded.active,
  label      = excluded.label;

-- ---- site_goals ------------------------------------------------------------
insert into public.site_goals (id, sort_order, active, label, description) values
  ('book_consults',     1, true, 'Book more consults',
   'The site exists to turn a visitor into a first phone call.'),
  ('explain_approach',  2, true, 'Explain how I work',
   'Show what a session is actually like before anyone has to ask.'),
  ('attract_better_fit', 3, true, 'Attract better-fit clients',
   'Fewer enquiries, more of them from the people this practice serves.'),
  ('clear_about_fees',  4, true, 'Be clear about fees',
   'Say the number, so the first call is not about the number.'),
  ('serve_referrers',   5, true, 'Give referrers something to send',
   'A page a colleague can forward without adding an explanation.'),
  ('leave_directories', 6, true, 'Stop relying on directories',
   'Own the first impression instead of renting it from a listing site.')
on conflict (id) do update set
  sort_order  = excluded.sort_order,
  active      = excluded.active,
  label       = excluded.label,
  description = excluded.description;

-- ---- primary_actions -------------------------------------------------------
insert into public.primary_actions (id, sort_order, active, label) values
  ('book_consult',        1, true, 'Book a consult'),
  ('free_call',           2, true, 'Schedule a free call'),
  ('check_availability',  3, true, 'Check availability'),
  ('request_appointment', 4, true, 'Request a session'),
  ('ask_question',        5, true, 'Ask a question'),
  ('join_waitlist',       6, true, 'Join the waitlist')
on conflict (id) do update set
  sort_order = excluded.sort_order,
  active     = excluded.active,
  label      = excluded.label;

-- <<< CATALOG DATA <<<


-- >>> SITE SPEC CATALOG DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ---- section_types ---------------------------------------------------------
-- `description` is printed into the builder output as the section's purpose,
-- so it is written as an instruction to whoever builds the page.
insert into public.section_types
  (id, sort_order, active, label, description, fields, default_enabled, allowed_pages, source) values

  ('hero', 1, true, 'Hero',
   'The first screen: a short overline, one headline, one supporting line, and a single call to action.',
   '[{"key":"overline","label":"Overline","kind":"text","max_length":48},
     {"key":"headline","label":"Headline","kind":"text","max_length":90},
     {"key":"subhead","label":"Supporting line","kind":"longtext","max_length":220},
     {"key":"cta_label","label":"Button label","kind":"text","max_length":28},
     {"key":"cta_target_url","label":"Button links to","kind":"text","max_length":400}]'::jsonb,
   true, array['home'], 'spec.hero'),

  ('intro', 2, true, 'Introduction',
   'One paragraph in the practitioner''s own voice, placed directly under the hero.',
   '[{"key":"body","label":"Paragraph","kind":"longtext","max_length":600}]'::jsonb,
   true, array['home','about'], 'spec.about_excerpt'),

  ('specialties', 3, true, 'What I work with',
   'A short list of the areas the practice works in. Plain labels, not diagnoses aimed at the reader.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"items","label":"Areas","kind":"list","max_length":80}]'::jsonb,
   true, array['home','services'], 'fields'),

  ('who_i_work_with', 4, true, 'Who I work with',
   'Who the practice serves, written as lived situations rather than diagnostic labels.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"items","label":"Descriptions","kind":"list","max_length":120}]'::jsonb,
   true, array['home','about'], 'fields'),

  ('approach', 5, true, 'How I work',
   'What a session is actually like, so a visitor knows before they have to ask.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"body","label":"Paragraph","kind":"longtext","max_length":800}]'::jsonb,
   false, array['home','about','services'], 'fields'),

  ('services', 6, true, 'Services',
   'What the practice offers: individual work, couples work, consultation.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"body","label":"Introduction","kind":"longtext","max_length":800},
     {"key":"items","label":"Services","kind":"list","max_length":120}]'::jsonb,
   false, array['home','services'], 'fields'),

  ('fees', 7, true, 'Fees',
   'Session fee, sliding scale and insurance, stated plainly so the first call is not about the number.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"body","label":"Introduction","kind":"longtext","max_length":800},
     {"key":"items","label":"Lines","kind":"list","max_length":120}]'::jsonb,
   false, array['services','contact'], 'fields'),

  ('faq', 8, true, 'Common questions',
   'A handful of questions and answers, each written as one line of question and one of answer.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"items","label":"Questions and answers","kind":"list","max_length":300}]'::jsonb,
   false, array['home','services','contact'], 'fields'),

  ('credentials', 9, true, 'Training and licensure',
   'License, degrees and completed training. Facts only, in the order the practitioner lists them.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"items","label":"Credentials","kind":"list","max_length":120}]'::jsonb,
   false, array['about'], 'fields'),

  ('contact', 10, true, 'Contact',
   'How to get in touch, ending in the call to action. No form that collects health information.',
   '[{"key":"heading","label":"Heading","kind":"text","max_length":80},
     {"key":"body","label":"Paragraph","kind":"longtext","max_length":800}]'::jsonb,
   true, array['home','about','services','contact'], 'fields'),

  ('footer', 11, true, 'Footer',
   'Practice name, license and location, and nothing that needs to be read twice.',
   '[{"key":"body","label":"Footer note","kind":"longtext","max_length":300}]'::jsonb,
   true, array['home','about','services','contact'], 'fields')

on conflict (id) do update set
  sort_order      = excluded.sort_order,
  active          = excluded.active,
  label           = excluded.label,
  description     = excluded.description,
  fields          = excluded.fields,
  default_enabled = excluded.default_enabled,
  allowed_pages   = excluded.allowed_pages,
  source          = excluded.source;

-- ---- builder_targets -------------------------------------------------------
-- The panel names are where each product actually keeps the setting, named as
-- that product names it. They are the difference between a sheet a therapist
-- can follow and a sheet she has to decode.
insert into public.builder_targets
  (id, sort_order, active, label, output_kind, docs_url,
   template_hint, color_panel, font_panel, section_panel) values

  ('lovable',     1, true, 'Lovable',     'prompt', 'https://docs.lovable.dev/',
   null, null, null, null),
  ('framer',      2, true, 'Framer',      'prompt', 'https://www.framer.com/help/',
   null, null, null, null),
  ('v0',          3, true, 'v0',          'prompt', 'https://v0.app/docs',
   null, null, null, null),
  ('generic',     4, true, 'Another builder', 'prompt', null,
   null, null, null, null),

  ('squarespace', 5, true, 'Squarespace', 'setup_sheet', 'https://support.squarespace.com/',
   'Start from a one-page portfolio or personal template, then delete the sections you do not need.',
   'Site Styles › Colors',
   'Site Styles › Fonts',
   'Pages › Edit › Add Section'),
  ('wix',         6, true, 'Wix',         'setup_sheet', 'https://support.wix.com/',
   'Start from a Health & Wellness template and remove the booking widgets you will not use.',
   'Site Design › Color Palette',
   'Site Design › Text Themes',
   'Add Elements › Section'),
  ('webflow',     7, true, 'Webflow',     'setup_sheet', 'https://help.webflow.com/',
   'Start from a blank site rather than a template: the structure below is faster to build than to unpick.',
   'Style Manager › Variables › Colors',
   'Style Manager › Typography',
   'Navigator › Sections')

on conflict (id) do update set
  sort_order    = excluded.sort_order,
  active        = excluded.active,
  label         = excluded.label,
  output_kind   = excluded.output_kind,
  docs_url      = excluded.docs_url,
  template_hint = excluded.template_hint,
  color_panel   = excluded.color_panel,
  font_panel    = excluded.font_panel,
  section_panel = excluded.section_panel;

-- <<< SITE SPEC CATALOG DATA <<<



-- >>> SITE OUTPUT TEMPLATE DATA (mirrored verbatim in supabase/seed.sql) >>>

insert into public.site_output_templates (id, target, key, body, sort_order) values

  -- ---- the prompt's skeleton ----------------------------------------------
  ('all.prompt.role_line', null, 'prompt.role_line',
   'Build a one-page (or multi-page) website for a therapy private practice. Follow this specification exactly.', 10),
  ('all.prompt.heading_practice',    null, 'prompt.heading_practice',    '## Practice', 11),
  ('all.prompt.heading_tokens',      null, 'prompt.heading_tokens',      '## Design tokens', 12),
  ('all.prompt.heading_structure',   null, 'prompt.heading_structure',   '## Pages and sections', 13),
  ('all.prompt.heading_copy',        null, 'prompt.heading_copy',        '## Copy', 14),
  ('all.prompt.copy_preamble',       null, 'prompt.copy_preamble',
   'Use every line below exactly as written. Text between """ lines is final copy, not a brief.', 15),
  ('all.prompt.heading_constraints', null, 'prompt.heading_constraints', '## Constraints', 16),
  ('all.prompt.heading_extra',       null, 'prompt.heading_extra',
   '## Additional instructions from the practice owner', 17),
  ('all.prompt.copy_section_heading', null, 'prompt.copy_section_heading', '### {page} — {section}', 18),
  ('all.prompt.structure_section_line', null, 'prompt.structure_section_line', '{label} — {description}', 19),

  -- ---- practice identity ---------------------------------------------------
  ('all.identity.label_name',     null, 'identity.label_name',     'Name', 20),
  ('all.identity.label_license',  null, 'identity.label_license',  'License', 21),
  ('all.identity.label_location', null, 'identity.label_location', 'Location', 22),
  ('all.identity.label_email',    null, 'identity.label_email',    'Email', 23),
  ('all.identity.label_phone',    null, 'identity.label_phone',    'Phone', 24),

  -- ---- design tokens, each with the role it plays --------------------------
  ('all.token.primary',   null, 'token.primary',   'Primary — buttons, links and active states', 30),
  ('all.token.secondary', null, 'token.secondary', 'Secondary — supporting headings and surfaces', 31),
  ('all.token.accent',    null, 'token.accent',    'Accent — small highlights only, never body text', 32),
  ('all.token.light_neutral', null, 'token.light_neutral', 'Light neutral — page background', 33),
  ('all.token.dark_neutral',  null, 'token.dark_neutral',  'Dark neutral — body text', 34),
  ('all.token.heading_font',  null, 'token.heading_font',  'Heading font', 35),
  ('all.token.body_font',     null, 'token.body_font',     'Body font', 36),
  ('all.token.google_fonts_url', null, 'token.google_fonts_url', 'Google Fonts stylesheet', 37),

  -- ---- the constraints -----------------------------------------------------
  -- ⚠ Four of these five are the difference between a website a licensing
  -- board is fine with and one it is not. Tune the wording; do not drop a row.
  ('all.constraint.copy_exact', null, 'constraint.copy_exact',
   'Use the provided copy exactly as written. Do not rewrite, expand or add copy.', 40),
  ('all.constraint.no_invention', null, 'constraint.no_invention',
   'Do not invent testimonials, client quotes, statistics, credentials or awards.', 41),
  ('all.constraint.no_stock_photos', null, 'constraint.no_stock_photos',
   'No stock photos of people; leave labeled image placeholders.', 42),
  ('all.constraint.cta_linked', null, 'constraint.cta_linked',
   'The call to action links to {cta_target_url}. Do not add a contact form that collects health information — a mailto link, a phone number or a booking link only.', 43),
  ('all.constraint.cta_unlinked', null, 'constraint.cta_unlinked',
   'The call to action has no link yet: leave the button in place and unlinked. Do not add a contact form that collects health information — a mailto link, a phone number or a booking link only.', 44),
  ('all.constraint.contrast', null, 'constraint.contrast',
   'Maintain WCAG AA text contrast.', 45),

  -- ---- the setup sheet -----------------------------------------------------
  ('all.sheet.step1_title', null, 'sheet.step1_title', 'Start from the right template', 50),
  ('all.sheet.step1_body',  null, 'sheet.step1_body',
   'Pick a template that is already close to the structure below. You will delete more than you add.', 51),
  ('all.sheet.step2_title', null, 'sheet.step2_title', 'Set your five colors', 52),
  ('all.sheet.step2_body',  null, 'sheet.step2_body',
   'Enter each hex exactly as written and give it the role named next to it. Do not let the template keep its own palette alongside yours.', 53),
  ('all.sheet.step3_title', null, 'sheet.step3_title', 'Set your two fonts', 54),
  ('all.sheet.step3_body',  null, 'sheet.step3_body',
   'Both faces are on Google Fonts. Assign the heading face to every heading level and the body face to body text, buttons and navigation.', 55),
  ('all.sheet.step4_title', null, 'sheet.step4_title', 'Build the pages and sections in this order', 56),
  ('all.sheet.step4_body',  null, 'sheet.step4_body',
   'Add each page, then each section inside it, top to bottom. The line after each section says what it is for.', 57),
  ('all.sheet.step5_title', null, 'sheet.step5_title', 'Paste your copy', 58),
  ('all.sheet.step5_body',  null, 'sheet.step5_body',
   'Every string your site needs is listed below this sheet, one block per field, in the order the sections appear. Paste them as they are.', 59),
  ('all.sheet.step6_title', null, 'sheet.step6_title', 'Point the button at your booking link', 60),
  ('all.sheet.step6_body_linked', null, 'sheet.step6_body_linked',
   'Set every call-to-action button to this link. One destination, on every page.', 61),
  ('all.sheet.step6_body_unlinked', null, 'sheet.step6_body_unlinked',
   'You have not set a booking link yet. Leave the button in place and unlinked, and come back to this step — do not replace it with a contact form.', 62),
  ('all.sheet.step7_title', null, 'sheet.step7_title', 'Before you publish', 63),
  ('all.sheet.step8_title', null, 'sheet.step8_title', 'Your own notes', 64),
  ('all.sheet.label_cta_label',  null, 'sheet.label_cta_label',  'Button label', 65),
  ('all.sheet.label_cta_target', null, 'sheet.label_cta_target', 'Button links to', 66),

  -- ---- the md / txt renderer ----------------------------------------------
  ('all.render.where_md',  null, 'render.where_md',  '> Where: ', 70),
  ('all.render.where_txt', null, 'render.where_txt', 'Where: ', 71),
  ('all.render.copy_blocks_md',  null, 'render.copy_blocks_md',  '## Copy blocks', 72),
  ('all.render.copy_blocks_txt', null, 'render.copy_blocks_txt', 'COPY BLOCKS', 73),
  ('all.render.copy_block_heading', null, 'render.copy_block_heading',
   '{page} — {section} — {label}', 74),
  ('all.render.value_line', null, 'render.value_line', '- {label}: {value}', 75)

on conflict (id) do update set
  target     = excluded.target,
  key        = excluded.key,
  body       = excluded.body,
  sort_order = excluded.sort_order,
  active     = excluded.active;

-- <<< SITE OUTPUT TEMPLATE DATA <<<


-- >>> PAPER TEMPLATE DATA (mirrored verbatim in supabase/seed.sql) >>>

insert into public.site_output_templates (id, target, key, body, sort_order) values
  ('all.token.paper', null, 'token.paper', 'Page background — the whole page sits on this', 33)
on conflict (id) do update set body = excluded.body, sort_order = excluded.sort_order;

update public.site_output_templates
   set body = 'Section background — tinted bands and cards only'
 where id = 'all.token.light_neutral';

-- <<< PAPER TEMPLATE DATA <<<


-- >>> PALETTE ACCENT DATA (mirrored verbatim in supabase/seed.sql) >>>

update public.palette_families set accent_hex = '#6E2F44' where id = 'plum_bone';      -- deep berry: the plum, taken redder
update public.palette_families set accent_hex = '#6E3320' where id = 'clay_sand';      -- deep brick: the terracotta, taken much deeper
update public.palette_families set accent_hex = '#8F5324' where id = 'ink_blue_chalk'; -- copper: warmth against the ink
update public.palette_families set accent_hex = '#8C5624' where id = 'olive_chalk';    -- ochre: the olive, taken warmer and deeper
update public.palette_families set accent_hex = '#A34A2A' where id = 'ochre_paper';    -- burnt orange: the ochre, taken redder
update public.palette_families set accent_hex = '#8E4A3C' where id = 'slate_bone';     -- brick: warmth against the slate

-- <<< PALETTE ACCENT DATA <<<


-- >>> STEP TITLE DATA (mirrored verbatim in supabase/seed.sql) >>>

update public.site_output_templates
   set body = 'Set your six colors'   where id = 'all.sheet.step2_title';
update public.site_output_templates
   set body = 'Set your fonts'        where id = 'all.sheet.step3_title';

-- <<< STEP TITLE DATA <<<

-- >>> PALETTE TEXT VARIANT DATA (mirrored verbatim in supabase/seed.sql) >>>

update public.palette_families
   set primary_text_hex   = public.site_spec_text_variant(primary_hex,   paper_hex),
       secondary_text_hex = public.site_spec_text_variant(secondary_hex, paper_hex),
       accent_text_hex    = public.site_spec_text_variant(accent_hex,    paper_hex);

-- <<< PALETTE TEXT VARIANT DATA <<<


-- >>> TEXT VARIANT TEMPLATE DATA (mirrored verbatim in supabase/seed.sql) >>>

insert into public.site_output_templates (id, target, key, body, sort_order) values
  ('all.token.primary_text',   null, 'token.primary_text',
   'Primary as text — headings and links on the page', 30),
  ('all.token.secondary_text', null, 'token.secondary_text',
   'Secondary as text — supporting headings on the page', 31),
  ('all.token.accent_text',    null, 'token.accent_text',
   'Accent as text — small highlighted words', 32),
  ('all.token.text_variant_note', null, 'token.text_variant_note',
   'The three "as text" values are the same brand colors, darkened only as far as legibility requires. Use an "as text" value wherever the color is text. Use the brand color for fills, bands, buttons and borders. Do not substitute one for the other, and do not add either to the palette twice.', 38),
  ('all.sheet.step_text_title', null, 'sheet.step_text_title',
   'Add the text versions of those three colors', 53),
  ('all.sheet.step_text_body', null, 'sheet.step_text_body',
   'These are the same three brand colors, darkened just enough to be readable as text on your page background. Add them alongside the others. Use them for headings and links; keep the brighter originals for fills, bands and buttons.', 54)
on conflict (id) do update set
  body = excluded.body, sort_order = excluded.sort_order;

update public.site_output_templates set body =
  'Primary — fills, buttons, bands and borders'      where id = 'all.token.primary';
update public.site_output_templates set body =
  'Secondary — supporting surfaces and fills'        where id = 'all.token.secondary';
update public.site_output_templates set body =
  'Accent — small marks, rules and selected states'  where id = 'all.token.accent';

-- <<< TEXT VARIANT TEMPLATE DATA <<<
