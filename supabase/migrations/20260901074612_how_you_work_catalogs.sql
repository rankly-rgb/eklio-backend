-- ============================================================================
-- "How you work" catalogs — session style, not-a-fit, modality, prominence
-- ============================================================================
-- Four new read-only catalogs backing the new brief step "How you work"
-- (step 4, see the step-renumbering migration). Same shape and same RLS
-- pattern as the eleven catalogs in `20260827100000_catalog_reference_data.sql`
-- and `20260829101000_site_spec_catalog.sql`: `id text primary key` (a stable
-- slug written into `project_briefs`), no `created_at`/`updated_at` (a catalog
-- row's history is this repo's git history), `active boolean not null default
-- true`, never deleted, RLS does not filter on `active` (a brief referencing a
-- retired card must still resolve; the frontend filters when rendering
-- pickers).
--
-- These are exposed the SAME way the other eleven are: plain `select`
-- through PostgREST, gated by RLS. There is no wrapping catalog RPC in this
-- repo for brief-building catalogs — `site_catalog()` is a different function
-- scoped to the site-spec editor only. So there is no "existing catalog
-- endpoint" to extend here; the frontend reads these four tables exactly like
-- it already reads `tone_cards`, `palette_families`, `client_persona_cards`,
-- etc.

-- ============================================================================
-- 1. session_style_cards
-- ============================================================================
-- `voice_hints` feeds the tone-card generator (frontend, step 5): selecting a
-- card adds its hints to the "We're hearing: …" chip row, and the generation
-- route weights them when writing sample heroes.

create table if not exists public.session_style_cards (
  id          text    primary key,
  sort_order  int     not null,
  active      boolean not null default true,
  label       text    not null,
  description text    not null,
  voice_hints text[]  not null
);

alter table public.session_style_cards
  drop constraint if exists session_style_cards_label_check;
alter table public.session_style_cards
  add constraint session_style_cards_label_check check (char_length(label) <= 48);

alter table public.session_style_cards
  drop constraint if exists session_style_cards_description_check;
alter table public.session_style_cards
  add constraint session_style_cards_description_check check (char_length(description) <= 140);

-- At least one hint (the chip row would be empty otherwise), a small upper
-- bound so the chip row stays one line.
alter table public.session_style_cards
  drop constraint if exists session_style_cards_voice_hints_check;
alter table public.session_style_cards
  add constraint session_style_cards_voice_hints_check check (
    coalesce(array_length(voice_hints, 1), 0) between 1 and 5
  );

-- ============================================================================
-- 2. not_a_fit_cards
-- ============================================================================
-- Every row reads as a scope-of-practice or fit statement, never a judgment
-- about a prospective client — enforced by review, not by a constraint, same
-- as the six `ethics_rules` rows.
--
-- No separate `description` column: unlike `session_style_cards`, the task
-- gave one sentence per row (the `label` below), not a label/description
-- pair. `referral_note` carries the second sentence — what she'd do instead
-- — shown as helper text when the card is selected.

create table if not exists public.not_a_fit_cards (
  id            text    primary key,
  sort_order    int     not null,
  active        boolean not null default true,
  label         text    not null,
  referral_note text    not null
);

alter table public.not_a_fit_cards
  drop constraint if exists not_a_fit_cards_label_check;
alter table public.not_a_fit_cards
  add constraint not_a_fit_cards_label_check check (char_length(label) <= 72);

alter table public.not_a_fit_cards
  drop constraint if exists not_a_fit_cards_referral_note_check;
alter table public.not_a_fit_cards
  add constraint not_a_fit_cards_referral_note_check check (char_length(referral_note) <= 140);

-- ============================================================================
-- 3. modality_cards
-- ============================================================================

create table if not exists public.modality_cards (
  id         text    primary key,
  sort_order int     not null,
  active     boolean not null default true,
  label      text    not null,
  full_name  text    not null
);

alter table public.modality_cards
  drop constraint if exists modality_cards_label_check;
alter table public.modality_cards
  add constraint modality_cards_label_check check (char_length(label) <= 24);

alter table public.modality_cards
  drop constraint if exists modality_cards_full_name_check;
alter table public.modality_cards
  add constraint modality_cards_full_name_check check (char_length(full_name) <= 64);

-- ============================================================================
-- 4. modality_prominence_options
-- ============================================================================
-- Backs `project_briefs.modality_prominence` (FK, see the columns migration).
-- Three fixed values, but a catalog table rather than a bare CHECK so the
-- frontend's segmented-control copy comes from the same read path as every
-- other catalog, and so the copy can change without a migration.

create table if not exists public.modality_prominence_options (
  id         text    primary key,
  sort_order int     not null,
  active     boolean not null default true,
  label      text    not null
);

alter table public.modality_prominence_options
  drop constraint if exists modality_prominence_options_label_check;
alter table public.modality_prominence_options
  add constraint modality_prominence_options_label_check check (char_length(label) <= 32);

-- ============================================================================
-- 5. Seed data
-- ============================================================================

-- >>> HOW YOU WORK CATALOG DATA (mirrored verbatim in supabase/seed.sql) >>>
insert into public.session_style_cards (id, sort_order, active, label, description, voice_hints) values
  ('asks_questions', 1, true, 'I ask a lot of questions', 'You''ll do more answering than listening, and the questions get more specific over time.', array['curious','precise','engaged']),
  ('mostly_listens', 2, true, 'I mostly listen, and I don''t rush you', 'Long silences are allowed. You set the pace of what gets said.', array['patient','unhurried','spacious']),
  ('direct', 3, true, 'I''m direct — I''ll say the thing', 'If I notice a pattern, you''ll hear about it that session, not three months later.', array['direct','candid','plainspoken']),
  ('structured', 4, true, 'We work from a plan you can see', 'Sessions have a shape, and you''ll know what we''re working toward and why.', array['clear','structured','methodical']),
  ('follows', 5, true, 'I follow where you go', 'No fixed agenda. What you bring in on the day is what we work with.', array['responsive','open','adaptive']),
  ('homework', 6, true, 'There''s work between sessions', 'What happens in the room is a fraction of it. You''ll leave with something to try.', array['practical','applied','active']),
  ('humor', 7, true, 'Humor has a place in the room', 'Hard things get talked about, and sometimes we laugh while doing it.', array['warm','human','light-footed']),
  ('body', 8, true, 'We pay attention to what the body is doing', 'What shows up physically is data, not a distraction.', array['grounded','embodied','attentive'])
on conflict (id) do update set
  sort_order  = excluded.sort_order,
  active      = excluded.active,
  label       = excluded.label,
  description = excluded.description,
  voice_hints = excluded.voice_hints;

insert into public.not_a_fit_cards (id, sort_order, active, label, referral_note) values
  ('wants_advice', 1, true, 'Someone looking for advice rather than exploration', 'I''ll point you toward resources built for direct advice.'),
  ('quick_fix', 2, true, 'Someone who wants this resolved in three sessions', 'I''ll be upfront about the pace this kind of work actually takes.'),
  ('court_ordered', 3, true, 'Court-ordered work and formal evaluations', 'I''ll refer you to a practice set up for court-ordered work.'),
  ('higher_level_care', 4, true, 'Anyone in active crisis who needs a higher level of care', 'I''ll help you find the right level of care before we start.'),
  ('med_management', 5, true, 'Someone whose primary need is medication management', 'I''ll refer you to a prescriber and can work alongside them.'),
  ('reluctant_partner', 6, true, 'Couples work where one partner is there under pressure', 'I''ll help you find a starting point that doesn''t depend on both people being ready.'),
  ('not_ready_for_past', 7, true, 'Someone who''d rather not look at the past right now', 'I''ll point you toward a present-focused approach instead.'),
  ('wants_silent_therapist', 8, true, 'Someone who wants a therapist who mostly stays quiet', 'I''ll be upfront that you''ll hear from me during sessions.')
on conflict (id) do update set
  sort_order    = excluded.sort_order,
  active        = excluded.active,
  label         = excluded.label,
  referral_note = excluded.referral_note;

insert into public.modality_cards (id, sort_order, active, label, full_name) values
  ('emdr', 1, true, 'EMDR', 'Eye Movement Desensitization and Reprocessing'),
  ('ifs', 2, true, 'IFS', 'Internal Family Systems'),
  ('somatic_experiencing', 3, true, 'Somatic Experiencing', 'Somatic Experiencing'),
  ('dbt', 4, true, 'DBT', 'Dialectical Behavior Therapy'),
  ('act', 5, true, 'ACT', 'Acceptance and Commitment Therapy'),
  ('cbt', 6, true, 'CBT', 'Cognitive Behavioral Therapy'),
  ('gottman', 7, true, 'Gottman Method', 'Gottman Method'),
  ('eft', 8, true, 'EFT', 'Emotionally Focused Therapy'),
  ('psychodynamic', 9, true, 'Psychodynamic', 'Psychodynamic Therapy'),
  ('play_therapy', 10, true, 'Play Therapy', 'Play Therapy'),
  ('narrative_therapy', 11, true, 'Narrative Therapy', 'Narrative Therapy'),
  ('motivational_interviewing', 12, true, 'MI', 'Motivational Interviewing'),
  ('art', 13, true, 'ART', 'Accelerated Resolution Therapy'),
  ('brainspotting', 14, true, 'Brainspotting', 'Brainspotting')
on conflict (id) do update set
  sort_order = excluded.sort_order,
  active     = excluded.active,
  label      = excluded.label,
  full_name  = excluded.full_name;

insert into public.modality_prominence_options (id, sort_order, active, label) values
  ('lead_with_it', 1, true, 'Lead with it'),
  ('mention_it', 2, true, 'Mention it'),
  ('keep_it_back', 3, true, 'Keep it in the background')
on conflict (id) do update set
  sort_order = excluded.sort_order,
  active     = excluded.active,
  label      = excluded.label;
-- <<< HOW YOU WORK CATALOG DATA <<<

-- ============================================================================
-- 6. RLS — read-only to authenticated, same pattern as the existing catalogs
-- ============================================================================

do $$
declare
  t text;
begin
  foreach t in array array[
    'session_style_cards',
    'not_a_fit_cards',
    'modality_cards',
    'modality_prominence_options'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select_all', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_select_all', t
    );
  end loop;
end
$$;

-- ============================================================================
-- 7. Runtime guard — RLS shape and expected row counts
-- ============================================================================

do $$
declare
  t      text;
  n_pol  int;
  n_rows int;
begin
  foreach t in array array[
    'session_style_cards',
    'not_a_fit_cards',
    'modality_cards',
    'modality_prominence_options'
  ]
  loop
    if not exists (
      select 1 from pg_tables
      where schemaname = 'public' and tablename = t and rowsecurity
    ) then
      raise exception 'how_you_work_catalogs: % does not have RLS enabled', t;
    end if;

    select count(*) into n_pol
    from pg_policies
    where schemaname = 'public' and tablename = t;

    if n_pol <> 1 then
      raise exception 'how_you_work_catalogs: % has % policies, expected exactly 1', t, n_pol;
    end if;
  end loop;

  select count(*) into n_rows from public.session_style_cards;
  if n_rows <> 8 then
    raise exception 'how_you_work_catalogs: session_style_cards has % rows, expected 8', n_rows;
  end if;

  select count(*) into n_rows from public.not_a_fit_cards;
  if n_rows <> 8 then
    raise exception 'how_you_work_catalogs: not_a_fit_cards has % rows, expected 8', n_rows;
  end if;

  select count(*) into n_rows from public.modality_cards;
  if n_rows <> 14 then
    raise exception 'how_you_work_catalogs: modality_cards has % rows, expected 14', n_rows;
  end if;

  select count(*) into n_rows from public.modality_prominence_options;
  if n_rows <> 3 then
    raise exception 'how_you_work_catalogs: modality_prominence_options has % rows, expected 3', n_rows;
  end if;
end
$$;

-- DOWN
-- drop table if exists public.modality_prominence_options;
-- drop table if exists public.modality_cards;
-- drop table if exists public.not_a_fit_cards;
-- drop table if exists public.session_style_cards;
