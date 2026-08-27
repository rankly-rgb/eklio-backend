-- ============================================================================
-- Eklio — reference catalogs (the cards the brief is built from)
-- ============================================================================
-- Follows `20260825160000_lot4_billing.sql`.
--
-- WHAT THIS IS
-- ------------
-- Eleven small, read-only tables holding the fixed choices a therapist picks
-- from during the 7-step brief: tone cards, palette families, type pairings,
-- persona / problem / gain cards, the six ethics rules, plus the four lookup
-- lists the preview needs (license types, specialties, site goals, primary
-- actions).
--
-- These are NOT user data. They are product content, versioned in this repo,
-- identical on every environment. They ship inside a migration rather than in
-- `supabase/seed.sql` because seed.sql runs on `supabase db reset` ONLY and
-- never touches the hosted project — a catalog that lived only there would be
-- missing in production. `supabase/seed.sql` mirrors the same rows verbatim so
-- that a local reset produces a usable database. Both copies exist on purpose;
-- see README, section "Reference catalogs".
--
-- WHY IT COMES BEFORE THE BRIEF MIGRATION
-- ---------------------------------------
-- Delivery order asked for the brief first. It cannot be: `brief_preview()`
-- resolves `palette_family_ids[0]`, `type_pairing_id`, `tone_card_id` and the
-- persona / specialty ids against these tables, so they have to exist first.
-- The two migrations are otherwise independent.
--
-- CONVENTIONS
-- -----------
-- `id text primary key` — stable, human-readable slugs. They are written into
-- `project_briefs` and into `brand_kits.directions`, and they appear in the
-- frontend as literals, so a uuid would buy nothing and cost readability.
--
-- No `created_at` / `updated_at`: a catalog row's history is this repo's git
-- history. Timestamps would only record when a migration ran.
--
-- `active` marks a card as no longer offered. Rows are never deleted and the
-- read policy does NOT filter on it: a brief that referenced a retired card
-- must still resolve, or its preview would silently lose its palette. The
-- frontend filters `active = true` when it renders the picker.
--
-- LENGTH LIMITS ARE CONSTRAINTS, NOT GUIDANCE
-- -------------------------------------------
-- Every card renders in a fixed-size element in `design/reference/`. Labels
-- carry `white-space:nowrap`; cards have fixed heights. Content that overflows
-- does not degrade, it breaks the grid. The CHECKs below are those limits.
-- ============================================================================


-- ============================================================================
-- 1. tone_cards — Screen 2 renders each card AS its sample_hero
-- ============================================================================
-- `sample_hero` is not an example of the voice, it IS the card: the brief asks
-- "which of these sounds like you?" and prints six real headlines. The chosen
-- one becomes `brief_preview().hero.headline`, so it is also live preview copy.
--
-- `keywords` is the small-caps label under each card, rendered by joining the
-- three words with ' · '. Stored lowercase, uppercased by the UI — the same
-- string is also read back for `directions[].tone_keywords`, where uppercasing
-- in storage would leak a presentation choice into the data.

create table if not exists public.tone_cards (
  id          text    primary key,
  sort_order  int     not null,
  active      boolean not null default true,
  sample_hero text    not null,
  keywords    text[]  not null
);

alter table public.tone_cards drop constraint if exists tone_cards_keywords_check;
alter table public.tone_cards
  add constraint tone_cards_keywords_check check (
    array_length(keywords, 1) = 3
    -- single lowercase words: the label is joined with ' · ', a keyword
    -- containing a space would read as four terms
    and keywords[1] ~ '^[a-z]+$'
    and keywords[2] ~ '^[a-z]+$'
    and keywords[3] ~ '^[a-z]+$'
    -- the joined label sits on one line (white-space:nowrap)
    and char_length(array_to_string(keywords, ' · ')) <= 32
  );

alter table public.tone_cards drop constraint if exists tone_cards_sample_hero_check;
alter table public.tone_cards
  add constraint tone_cards_sample_hero_check check (
    char_length(sample_hero) between 1 and 60
  );

comment on table public.tone_cards is
  'Voice and tone cards for brief step 4. Screen 2 renders each card as its sample_hero; the chosen one becomes the preview headline.';


-- ============================================================================
-- 2. palette_families — Screen 1, and the source of every direction palette
-- ============================================================================
-- Five roles, named exactly as the brand kit screen prints them (PRIMARY,
-- SECONDARY, LIGHT, DARK, PAPER). `preview_tokens` repeats them as jsonb in
-- the shape `brief_preview()` and `brand_kits.directions[].palette` return, so
-- the frontend needs no mapping layer anywhere in the stack.
--
-- `swatches` is the three dots printed under each card on Screen 1 — primary,
-- secondary, light, in that order.
--
-- Both derived columns are held to the five hex columns by CHECK rather than
-- being generated: a generated column would need an immutable expression built
-- by string concatenation, which is harder to read than the equality it is
-- meant to guarantee.
--
-- ⚠ EDITORIAL RULE, not enforceable in SQL: this set contains no pale sage and
-- no dusty blue. That pairing is the therapist-directory default this product
-- exists to escape — a brand that lands on it has failed at the one job it
-- was hired for. Any family added later must respect that.

create table if not exists public.palette_families (
  id             text    primary key,
  sort_order     int     not null,
  active         boolean not null default true,
  label          text    not null,
  primary_hex    text    not null,
  secondary_hex  text    not null,
  light_hex      text    not null,
  dark_hex       text    not null,
  paper_hex      text    not null,
  swatches       text[]  not null,
  preview_tokens jsonb   not null
);

alter table public.palette_families drop constraint if exists palette_families_hex_check;
alter table public.palette_families
  add constraint palette_families_hex_check check (
    primary_hex   ~ '^#[0-9A-F]{6}$'
    and secondary_hex ~ '^#[0-9A-F]{6}$'
    and light_hex     ~ '^#[0-9A-F]{6}$'
    and dark_hex      ~ '^#[0-9A-F]{6}$'
    and paper_hex     ~ '^#[0-9A-F]{6}$'
  );

-- Label renders uppercase on the card, so it is stored uppercase: lowercasing
-- it here would mean every consumer has to remember to upper() it.
alter table public.palette_families drop constraint if exists palette_families_label_check;
alter table public.palette_families
  add constraint palette_families_label_check check (
    label = upper(label) and char_length(label) <= 24
  );

alter table public.palette_families drop constraint if exists palette_families_swatches_check;
alter table public.palette_families
  add constraint palette_families_swatches_check check (
    swatches = array[primary_hex, secondary_hex, light_hex]
  );

alter table public.palette_families drop constraint if exists palette_families_preview_tokens_check;
alter table public.palette_families
  add constraint palette_families_preview_tokens_check check (
    preview_tokens->>'primary'   = primary_hex
    and preview_tokens->>'secondary' = secondary_hex
    and preview_tokens->>'light'     = light_hex
    and preview_tokens->>'dark'      = dark_hex
    and preview_tokens->>'paper'     = paper_hex
  );

comment on table public.palette_families is
  'Palette families for brief step 5. Role names match the labels printed on the brand kit screen; preview_tokens is the exact jsonb shape brief_preview and brand_kits.directions return.';


-- ============================================================================
-- 3. type_pairings — heading + body, with a loadable Google Fonts URL
-- ============================================================================
-- `google_fonts_url` requests only the weights the UI actually uses: heading
-- 500 and 600, body 400, 600 and 700, always with `display=swap`. Requesting
-- the full family would pull megabytes of unused weights onto a page whose
-- whole promise is that it loads fast.
--
-- ⚠ ONE DELIBERATE EXCEPTION: Libre Caslon Text ships only 400 and 700 on
-- Google Fonts — 500 and 600 do not exist for it, and requesting them returns
-- HTTP 400 and no stylesheet at all. Its URL therefore asks for 400 and 700,
-- the weights that family actually renders at. The rule is "the weights the UI
-- uses"; for this family those are the ones it can use.

create table if not exists public.type_pairings (
  id               text    primary key,
  sort_order       int     not null,
  active           boolean not null default true,
  heading_font     text    not null,
  body_font        text    not null,
  google_fonts_url text    not null
);

alter table public.type_pairings drop constraint if exists type_pairings_google_fonts_url_check;
alter table public.type_pairings
  add constraint type_pairings_google_fonts_url_check check (
    google_fonts_url like 'https://fonts.googleapis.com/css2?family=%'
    and google_fonts_url like '%display=swap'
  );

comment on table public.type_pairings is
  'Heading/body font pairings for brief step 6. google_fonts_url is loadable as-is and requests only the weights the UI renders.';


-- ============================================================================
-- 4. client_persona_cards / problem_cards / gain_cards
-- ============================================================================
-- Three multi-select card decks: who they work with, what those people arrive
-- carrying, what those people are after.
--
-- ⚠ REGISTER, and it is a product rule rather than a style preference: every
-- card is written as a LIVED SITUATION, never as a diagnostic label aimed at
-- the reader. "Adults carrying something from years back", not "PTSD sufferers".
-- The same rule is `ethics_rules.diagnosis` below, and a therapist's licensing
-- board applies it to their website copy. Seeding the decks with diagnostic
-- labels would mean the product hands them a violation on step 3.
--
-- `label` <= 48 and `description` <= 90: fixed-width cards, three to a row.

create table if not exists public.client_persona_cards (
  id          text    primary key,
  sort_order  int     not null,
  active      boolean not null default true,
  label       text    not null,
  description text    not null
);

create table if not exists public.problem_cards (
  id          text    primary key,
  sort_order  int     not null,
  active      boolean not null default true,
  label       text    not null,
  description text    not null
);

create table if not exists public.gain_cards (
  id          text    primary key,
  sort_order  int     not null,
  active      boolean not null default true,
  label       text    not null,
  description text    not null
);

do $$
declare
  t text;
begin
  foreach t in array array['client_persona_cards', 'problem_cards', 'gain_cards']
  loop
    execute format(
      'alter table public.%I drop constraint if exists %I', t, t || '_label_check');
    execute format(
      'alter table public.%I add constraint %I check (char_length(label) <= 48)',
      t, t || '_label_check');
    execute format(
      'alter table public.%I drop constraint if exists %I', t, t || '_description_check');
    execute format(
      'alter table public.%I add constraint %I check (char_length(description) <= 90)',
      t, t || '_description_check');
  end loop;
end
$$;

comment on table public.client_persona_cards is
  'Who the practice works with. Written as lived situations, never as diagnostic labels aimed at the reader.';
comment on table public.problem_cards is
  'What clients arrive carrying. Same register rule as client_persona_cards.';
comment on table public.gain_cards is
  'What clients are after. Same register rule as client_persona_cards.';


-- ============================================================================
-- 5. ethics_rules — the six rules, as data
-- ============================================================================
-- The Ethics Guard that enforces these lives in `eklio-frontend`: it needs an
-- LLM call and a runtime, so it is not this repo's job. What IS this repo's
-- job is making sure the enforcement code and the `BOARD-SAFE COPY` tooltip
-- read the SAME six rules. Two hand-maintained lists drift, and the half that
-- drifts is always the one nobody is looking at.
--
-- `example_forbidden` for `timeframe`, `client_voice` and `scarcity` are the
-- three strings printed struck-through in the "Never write this" column on
-- Screen 6. They are rendered verbatim — do not reword them.

create table if not exists public.ethics_rules (
  id                text    primary key,
  sort_order        int     not null,
  active            boolean not null default true,
  short_label       text    not null,
  description       text    not null,
  example_forbidden text    not null
);

comment on table public.ethics_rules is
  'The six advertising rules the Ethics Guard enforces. Stored here so the enforcement code (eklio-frontend) and the BOARD-SAFE COPY tooltip read one list. Enforcement itself is NOT implemented in this repo.';


-- ============================================================================
-- 6. license_types / specialties / site_goals / primary_actions
-- ============================================================================
-- Four lookup lists the preview reads directly. None existed anywhere in the
-- schema, so they are created here on the same pattern as the card decks.
--
--   * license_types.label is the credential printed in the preview overline
--     (`LCSW · PORTLAND, OR`) — the abbreviation, not the expanded name.
--   * specialties.label is a chip under the hero; the preview renders exactly
--     two of them, so the label has to be short.
--   * primary_actions.label is the CTA on every button in the mockups.
--   * site_goals is the only one the preview does not render; it steers
--     generation, which happens in the frontend.

create table if not exists public.license_types (
  id          text    primary key,
  sort_order  int     not null,
  active      boolean not null default true,
  label       text    not null,
  description text    not null
);

create table if not exists public.specialties (
  id         text    primary key,
  sort_order int     not null,
  active     boolean not null default true,
  label      text    not null
);

create table if not exists public.site_goals (
  id          text    primary key,
  sort_order  int     not null,
  active      boolean not null default true,
  label       text    not null,
  description text    not null
);

create table if not exists public.primary_actions (
  id         text    primary key,
  sort_order int     not null,
  active     boolean not null default true,
  label      text    not null
);

-- Overline is one nowrap line: credential, then ' · CITY, ST'.
alter table public.license_types drop constraint if exists license_types_label_check;
alter table public.license_types
  add constraint license_types_label_check check (char_length(label) <= 12);

-- Two chips side by side under a 250px-wide hero.
alter table public.specialties drop constraint if exists specialties_label_check;
alter table public.specialties
  add constraint specialties_label_check check (char_length(label) <= 24);

-- Button pill, nowrap, next to a nav row.
alter table public.primary_actions drop constraint if exists primary_actions_label_check;
alter table public.primary_actions
  add constraint primary_actions_label_check check (char_length(label) <= 24);

alter table public.site_goals drop constraint if exists site_goals_label_check;
alter table public.site_goals
  add constraint site_goals_label_check check (char_length(label) <= 48);


-- ============================================================================
-- 7. RLS — readable by any authenticated user, writable by no one
-- ============================================================================
-- The platform event trigger `ensure_rls` turns RLS on for every new table in
-- `public` without creating a policy, so each of these starts life locked. We
-- enable it explicitly anyway: this schema has to stay replayable on a database
-- that does not carry that event trigger.
--
-- ONE policy per table, SELECT only. There is deliberately no insert, update or
-- delete policy: under RLS, no policy means refused, and a catalog is changed
-- by shipping a migration, not by a client. `service_role` bypasses RLS (no
-- table is in FORCE ROW LEVEL SECURITY, see README), which is how the upserts
-- below and any future correction get in.
--
-- ⚠ These policies carry `to authenticated`, unlike every existing policy in
-- this schema, which omits the clause and lands on `public`. The difference is
-- intentional and it is the one place it matters: the existing policies are all
-- ownership predicates on `auth.uid()`, which is NULL for `anon` and therefore
-- self-closing. `using (true)` has no such property — without `to authenticated`
-- it would publish the entire product catalog to unauthenticated visitors.
--
-- The predicate is `true`, NOT `active`: a brief that picked a card since
-- retired must still resolve it, or its preview silently loses its palette.

alter table public.tone_cards           enable row level security;
alter table public.palette_families     enable row level security;
alter table public.type_pairings        enable row level security;
alter table public.client_persona_cards enable row level security;
alter table public.problem_cards        enable row level security;
alter table public.gain_cards           enable row level security;
alter table public.ethics_rules         enable row level security;
alter table public.license_types        enable row level security;
alter table public.specialties          enable row level security;
alter table public.site_goals           enable row level security;
alter table public.primary_actions      enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array[
    'tone_cards', 'palette_families', 'type_pairings', 'client_persona_cards',
    'problem_cards', 'gain_cards', 'ethics_rules', 'license_types',
    'specialties', 'site_goals', 'primary_actions'
  ]
  loop
    execute format('drop policy if exists %I on public.%I', t || '_select_all', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_select_all', t);
  end loop;
end
$$;


-- ============================================================================
-- 8. Catalog data — idempotent upserts
-- ============================================================================
-- `on conflict (id) do update` rather than plain insert: this migration must be
-- replayable, and a corrected label has to reach an environment where the row
-- already exists. Rows are never deleted here — retiring a card is
-- `active = false`, so that briefs referencing it keep resolving.
--
-- ⚠ EVERYTHING BETWEEN THE TWO MARKERS BELOW IS MIRRORED VERBATIM IN
-- `supabase/seed.sql`. Change one, change the other. Regenerate the mirror with:
--
--   awk '/^-- >>> CATALOG DATA/,/^-- <<< CATALOG DATA/' \
--     supabase/migrations/20260827100000_catalog_reference_data.sql \
--     > /tmp/catalog.sql
--
-- and splice it under the header in seed.sql. Both copies exist because a
-- migration reaches the hosted project and seed.sql reaches a local reset, and
-- neither reaches the other. See README, "Reference catalogs".

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


-- ============================================================================
-- 9. Guard rails — verified, not assumed
-- ============================================================================
-- A catalog that is readable by the wrong audience, or writable by anyone, is
-- worse than one that is missing: the failure is silent.

do $$
declare
  t text;
  n int;
begin
  foreach t in array array[
    'tone_cards', 'palette_families', 'type_pairings', 'client_persona_cards',
    'problem_cards', 'gain_cards', 'ethics_rules', 'license_types',
    'specialties', 'site_goals', 'primary_actions'
  ]
  loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'catalog_reference_data: RLS is off on %. Migration aborted.', t;
    end if;

    -- Exactly one policy, and it must be a SELECT policy. An INSERT/UPDATE/
    -- DELETE policy on a catalog would let a client rewrite product content.
    select count(*) into n from pg_policies where schemaname = 'public' and tablename = t;
    if n <> 1 then
      raise exception
        'catalog_reference_data: % has % policies, expected exactly 1 (select-only). Migration aborted.', t, n;
    end if;

    if not exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t and cmd = 'SELECT'
    ) then
      raise exception
        'catalog_reference_data: the single policy on % is not a SELECT policy. Migration aborted.', t;
    end if;
  end loop;

  -- Row counts the product spec fixes exactly. A missing tone card means a
  -- blank slot on Screen 2; a seventh means a broken two-column grid.
  select count(*) into n from public.tone_cards;
  if n <> 6 then raise exception 'catalog_reference_data: % tone_cards, expected 6.', n; end if;

  select count(*) into n from public.palette_families;
  if n <> 6 then raise exception 'catalog_reference_data: % palette_families, expected 6.', n; end if;

  select count(*) into n from public.type_pairings;
  if n <> 6 then raise exception 'catalog_reference_data: % type_pairings, expected 6.', n; end if;

  select count(*) into n from public.client_persona_cards;
  if n <> 10 then raise exception 'catalog_reference_data: % client_persona_cards, expected 10.', n; end if;

  select count(*) into n from public.problem_cards;
  if n <> 8 then raise exception 'catalog_reference_data: % problem_cards, expected 8.', n; end if;

  select count(*) into n from public.gain_cards;
  if n <> 8 then raise exception 'catalog_reference_data: % gain_cards, expected 8.', n; end if;

  select count(*) into n from public.ethics_rules;
  if n <> 6 then raise exception 'catalog_reference_data: % ethics_rules, expected 6.', n; end if;

  -- The three directions on the reveal must be able to differ typographically
  -- (see the distinct-heading-font constraint in the rendering-constraints
  -- migration). Fewer than three pairings would make that unsatisfiable.
  select count(*) into n from public.type_pairings where active;
  if n < 3 then
    raise exception
      'catalog_reference_data: only % active type_pairings; a brand kit needs 3 distinct heading fonts.', n;
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
-- The Supabase CLI has no down runner: `db push` only rolls forward. The
-- reverse script is kept here so that reverting is a copy-paste rather than an
-- archaeology exercise. Dropping the catalogs breaks `brief_preview()`, so run
-- the down script of the brief migration first.
--
--   drop table if exists public.primary_actions;
--   drop table if exists public.site_goals;
--   drop table if exists public.specialties;
--   drop table if exists public.license_types;
--   drop table if exists public.ethics_rules;
--   drop table if exists public.gain_cards;
--   drop table if exists public.problem_cards;
--   drop table if exists public.client_persona_cards;
--   drop table if exists public.type_pairings;
--   drop table if exists public.palette_families;
--   drop table if exists public.tone_cards;
