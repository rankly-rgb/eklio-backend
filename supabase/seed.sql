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
-- ⚠ THE BLOCK BELOW IS A VERBATIM COPY of the marked region of
-- `supabase/migrations/20260827100000_catalog_reference_data.sql`.
-- Never edit it here. Edit the migration, then regenerate:
--
--   awk '/^-- >>> CATALOG DATA/,/^-- <<< CATALOG DATA/' \
--     supabase/migrations/20260827100000_catalog_reference_data.sql \
--     > /tmp/catalog.sql
--
-- and splice /tmp/catalog.sql in below this header. The upserts are idempotent,
-- so running them after the migration has already inserted the rows is a no-op.
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
