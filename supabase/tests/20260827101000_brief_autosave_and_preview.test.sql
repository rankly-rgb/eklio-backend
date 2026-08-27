-- ============================================================================
-- Tests — 20260827101000_brief_autosave_and_preview.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001','owner@example.com'),
  ('aaaaaaaa-0000-0000-0000-000000000002','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Elm & Ember Counseling');
insert into public.project_briefs (project_id) values ('bbbbbbbb-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------
-- The documented shape, key for key
-- ---------------------------------------------------------------------------
do $$
declare
  p jsonb := public.brief_preview('bbbbbbbb-0000-0000-0000-000000000001');
begin
  assert p is not null, 'brief_preview returned NULL for an existing readable brief';

  assert p ? 'practice_name', 'brief_preview is missing practice_name';
  assert p ? 'tokens',        'brief_preview is missing tokens';
  assert p ? 'hero',          'brief_preview is missing hero';
  assert p ? 'about_excerpt', 'brief_preview is missing about_excerpt';
  assert p ? 'specialties',   'brief_preview is missing specialties';

  assert p->'tokens' ?& array['primary','secondary','light','dark','paper',
                              'heading_font','body_font','google_fonts_url'],
         'tokens is missing one of its eight documented keys';
  assert p->'hero' ?& array['overline','headline','subhead','cta_label'],
         'hero is missing one of its four documented keys';
  assert jsonb_typeof(p->'specialties') = 'array', 'specialties must be an array';
end
$$;

-- ---------------------------------------------------------------------------
-- The fallbacks: this is the state Screen 1's rail renders before any answer
-- ---------------------------------------------------------------------------
do $$
declare
  p jsonb := public.brief_preview('bbbbbbbb-0000-0000-0000-000000000001');
begin
  assert p->'tokens'->>'primary'      = '#B4674A',    'empty brief must fall back to CLAY & SAND primary';
  assert p->'tokens'->>'secondary'    = '#C08A3E',    'empty brief must fall back to CLAY & SAND secondary';
  assert p->'tokens'->>'heading_font' = 'Fraunces',   'empty brief must fall back to Fraunces';
  assert p->'tokens'->>'body_font'    = 'Nunito Sans','empty brief must fall back to Nunito Sans';
  assert p->'hero'->>'headline'  = 'A calmer place to start.', 'headline fallback drifted';
  assert p->'hero'->>'subhead'
       = 'Therapy for high-performing adults who can''t switch off.', 'subhead fallback drifted';
  assert p->'hero'->>'cta_label' = 'Book a consult', 'cta_label fallback drifted';
  assert p->'specialties' = '[]'::jsonb, 'specialties must be empty when none are chosen';
  assert p->>'about_excerpt' like 'I work mostly with %', 'about_excerpt fallback drifted';
end
$$;

-- ---------------------------------------------------------------------------
-- A filled brief
-- ---------------------------------------------------------------------------
update public.project_briefs set
  palette_family_ids = array['ink_blue_chalk','clay_sand'],
  type_pairing_id    = 'newsreader_work',
  tone_card_id       = 'clear',
  license_type_id    = 'lmft',
  primary_action_id  = 'free_call',
  city = 'portland', state = 'or',
  positioning = 'Therapy for high-performing adults who cannot switch off, in Portland and across Oregon',
  client_persona_ids = array['high_functioning'],
  specialty_ids      = array['anxiety','burnout','adhd'],
  practice_name      = 'Elm & Ember'
where project_id = 'bbbbbbbb-0000-0000-0000-000000000001';

do $$
declare
  p jsonb := public.brief_preview('bbbbbbbb-0000-0000-0000-000000000001');
begin
  -- leading palette is element 1, not any other element
  assert p->'tokens'->>'primary' = '#22364F', 'the leading palette must drive the preview';
  assert p->'tokens'->>'heading_font' = 'Newsreader', 'the chosen type pairing must drive the preview';
  assert p->'hero'->>'headline' = 'Therapy with a plan you can actually see.',
         'the chosen tone card sample_hero must become the headline';
  assert p->'hero'->>'overline' = 'LMFT · PORTLAND, OR',
         'overline must be the licence label then the uppercased city and state';
  assert p->'hero'->>'cta_label' = 'Schedule a free call', 'the chosen primary action must become the CTA';
  assert p->>'practice_name' = 'Elm & Ember', 'practice_name must win over the project name';

  -- the rail renders exactly two chips
  assert jsonb_array_length(p->'specialties') = 2,
         'specialties must be capped at 2 however many are chosen';
  assert p->'specialties'->>0 = 'Anxiety' and p->'specialties'->>1 = 'Burnout',
         'specialties must keep the order they were chosen in';

  -- subhead truncated on a word boundary, never mid-word
  assert char_length(p->'hero'->>'subhead') <= 60, 'subhead exceeds 60 characters';
  assert right(p->'hero'->>'subhead', 1) <> ' ',  'subhead ends on a stray space';
  assert position(p->'hero'->>'subhead' in
                  'Therapy for high-performing adults who cannot switch off, in Portland and across Oregon') = 1,
         'subhead is not a prefix of the positioning line';
end
$$;

-- overline with a city but no licence must not start with a separator
do $$
declare
  p jsonb;
begin
  update public.project_briefs set license_type_id = null
   where project_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  p := public.brief_preview('bbbbbbbb-0000-0000-0000-000000000001');
  assert p->'hero'->>'overline' = 'PORTLAND, OR',
         'overline must not carry a leading separator when the licence is unset';

  update public.project_briefs set city = null, state = null
   where project_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  p := public.brief_preview('bbbbbbbb-0000-0000-0000-000000000001');
  assert p->'hero'->>'overline' is null,
         'overline must be null when neither licence nor location is known';

  update public.project_briefs
     set license_type_id = 'lmft', city = 'portland', state = 'or'
   where project_id = 'bbbbbbbb-0000-0000-0000-000000000001';
end
$$;

-- ---------------------------------------------------------------------------
-- Autosave: every answer column is independently updatable and nullable
-- ---------------------------------------------------------------------------
do $$
begin
  update public.project_briefs set tone_card_id = 'gentle'
   where project_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  update public.project_briefs set city = 'eugene'
   where project_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  update public.project_briefs set tone_card_id = null
   where project_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  assert (select tone_card_id from public.project_briefs
           where project_id='bbbbbbbb-0000-0000-0000-000000000001') is null,
         'an answer column must be independently clearable';
end
$$;

-- ---------------------------------------------------------------------------
-- Constraints
-- ---------------------------------------------------------------------------
do $$
declare
  rejected boolean;
begin
  begin
    update public.project_briefs set progress_step = 8
     where project_id='bbbbbbbb-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'progress_step 8 was accepted; the brief has 7 steps';

  begin
    update public.project_briefs set palette_family_ids = array['a','b','c','d']
     where project_id='bbbbbbbb-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'a fourth palette family was accepted';

  begin
    update public.project_briefs set state = 'Oregon'
     where project_id='bbbbbbbb-0000-0000-0000-000000000001';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'a non two-letter state code was accepted';

  begin
    update public.project_briefs set tone_card_id = 'no_such_card'
     where project_id='bbbbbbbb-0000-0000-0000-000000000001';
    rejected := false;
  exception when foreign_key_violation then rejected := true; end;
  assert rejected, 'a tone_card_id absent from the catalog was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- truncate_on_word_boundary
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.truncate_on_word_boundary('short', 60) = 'short',
         'a string under the limit must come back untouched';
  assert public.truncate_on_word_boundary(null, 60) is null,
         'NULL in, NULL out';
  assert public.truncate_on_word_boundary('aaa bbb ccc ddd', 7) = 'aaa bbb',
         'must cut on the last whitespace inside the limit';
  assert char_length(public.truncate_on_word_boundary(repeat('x', 100), 60)) = 60,
         'a single unbroken word must fall back to a hard cut';
  assert public.truncate_on_word_boundary('aaaa bbbb', 4) = 'aaaa',
         'a cut landing exactly on a space must not leave the space';
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: a second user cannot read the first user's brief, and gets zero rows
--      rather than a permission error
-- ---------------------------------------------------------------------------
do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002"}';

  assert (select count(*) from public.project_briefs
           where project_id='bbbbbbbb-0000-0000-0000-000000000001') = 0,
         'a stranger could select another user''s brief row';

  assert public.brief_preview('bbbbbbbb-0000-0000-0000-000000000001') is null,
         'brief_preview leaked another user''s preview';
end
$$;

do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
  assert (select count(*) from public.project_briefs
           where project_id='bbbbbbbb-0000-0000-0000-000000000001') = 1,
         'the owner must still be able to read their own brief';
  assert public.brief_preview('bbbbbbbb-0000-0000-0000-000000000001') is not null,
         'the owner must still get their own preview';
end
$$;

rollback;
