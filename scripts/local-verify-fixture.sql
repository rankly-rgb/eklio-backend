-- ============================================================================
-- scripts/local-verify-fixture.sql
-- ============================================================================
-- One account, one completed brief, one brand kit with three directions and
-- one selected, comp access granted — the starting point for every
-- subsequent lot's local verification, so it doesn't have to be rebuilt by
-- hand each time.
--
-- Run against the database scripts/local-verify.sh builds, AFTER it (that
-- script rebuilds the DB from zero every run, so this is a separate step,
-- not folded into it):
--
--   sudo -u postgres psql -v ON_ERROR_STOP=1 -d eklio_local_verify \
--     -f scripts/local-verify-fixture.sql
--
-- Entirely synthetic, entirely local — this is NOT the real
-- nainarahal@gmail.com test account on the deployed preview, and never
-- touches it. No secret of any kind is needed or used here; the fixture
-- user's id/email are fixed, ordinary values, safe to commit, because this
-- database only ever exists on this machine for the length of one
-- verification run.
--
-- What it uses, and why: `brand_kits.directions`/`selected_direction_id` are
-- set together in a single INSERT — the direction-selected-at-creation
-- branch of `handle_brand_kit_created()`'s trigger fires exactly the same
-- seeding (`seed_launch_checklist`, `complete_choose_direction`,
-- `seed_site_spec`) that a real POST to `selectDirection` would, no need to
-- fake a two-step insert-then-update. The three-direction jsonb shape below
-- is not invented for this file — it's the same shape already proven valid
-- against `brand_kit_directions_shape_valid` in
-- supabase/tests/20260829123000_entitlement_and_generation_credits.test.sql.
--
-- Does NOT commit/rollback — this is fixture data meant to persist in the
-- local verify database for the rest of the session, unlike the *.test.sql
-- files (which always roll back). Re-running this script against a database
-- that already has the fixture will fail on the primary key / unique
-- constraints; rebuild with scripts/local-verify.sh first if you need a
-- clean slate.
-- ============================================================================

\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('f1111111-1111-1111-1111-111111111111', 'fixture@eklio.local');

insert into public.projects (id, user_id, name) values
  ('f2222222-2222-2222-2222-222222222222', 'f1111111-1111-1111-1111-111111111111', 'Fixture Practice');

insert into public.project_briefs (
  project_id, practice_name, license_type_id, city, state, specialty_ids
) values (
  'f2222222-2222-2222-2222-222222222222',
  'Elm & Ember Therapy',
  'lcsw',
  'Portland',
  'OR',
  array['anxiety']
);

insert into public.brand_kits (id, project_id, directions, selected_direction_id) values (
  'f3333333-3333-3333-3333-333333333333',
  'f2222222-2222-2222-2222-222222222222',
  jsonb_build_array(
    jsonb_build_object(
      'id', 'warm_welcome', 'name', 'Warm Welcome',
      'rationale', 'Warmth without softness. It says the first call will be easier than they think.',
      'palette', jsonb_build_object(
        'primary', '#B4674A', 'secondary', '#C08A3E',
        'light', '#F4EEE3', 'dark', '#2B2A27', 'paper', '#FAF6EE'
      ),
      'typography', jsonb_build_object(
        'heading_font', 'Fraunces', 'body_font', 'Nunito Sans',
        'google_fonts_url', 'https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Nunito+Sans:wght@400;600;700&display=swap'
      ),
      'hero', jsonb_build_object(
        'overline', 'LCSW · PORTLAND, OR', 'headline', 'A calmer place to start.',
        'subhead', 'Therapy for adults who hold it together.', 'cta_label', 'Book a consult'
      ),
      'about_excerpt', 'I work mostly with professionals who look fine from the outside.',
      'tone_keywords', jsonb_build_array('steady', 'plainspoken', 'warm')
    ),
    jsonb_build_object(
      'id', 'quiet_confidence', 'name', 'Quiet Confidence',
      'rationale', 'Restraint reads as experience. For clients who want steadiness more than warmth.',
      'palette', jsonb_build_object(
        'primary', '#3B2C3A', 'secondary', '#4A5361',
        'light', '#F3EDE4', 'dark', '#241B23', 'paper', '#FAF7F2'
      ),
      'typography', jsonb_build_object(
        'heading_font', 'Cormorant Garamond', 'body_font', 'Source Sans 3',
        'google_fonts_url', 'https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&family=Source+Sans+3:wght@400;600;700&display=swap'
      ),
      'hero', jsonb_build_object('overline', 'o', 'headline', 'h', 'subhead', 's', 'cta_label', 'c'),
      'about_excerpt', 'x',
      'tone_keywords', jsonb_build_array('composed', 'credible', 'unhurried')
    ),
    jsonb_build_object(
      'id', 'modern_calm', 'name', 'Modern Calm',
      'rationale', 'Structure signals a plan. For the client who needs to see how the work goes.',
      'palette', jsonb_build_object(
        'primary', '#22364F', 'secondary', '#7A8168',
        'light', '#EDEAE5', 'dark', '#16202E', 'paper', '#F7F6F3'
      ),
      'typography', jsonb_build_object(
        'heading_font', 'Newsreader', 'body_font', 'Work Sans',
        'google_fonts_url', 'https://fonts.googleapis.com/css2?family=Newsreader:wght@500;600&family=Work+Sans:wght@400;600;700&display=swap'
      ),
      'hero', jsonb_build_object('overline', 'o', 'headline', 'h', 'subhead', 's', 'cta_label', 'c'),
      'about_excerpt', 'x',
      'tone_keywords', jsonb_build_array('clear', 'structured', 'direct')
    )
  ),
  'warm_welcome'
);

-- Comp access, not a purchase — same mechanism as scripts/comp_grant.sql,
-- fixed to this fixture user rather than parameterized, since this is
-- synthetic local data, not a real account.
insert into public.comp_grants (user_id, reason, granted_by, expires_at)
values (
  'f1111111-1111-1111-1111-111111111111',
  'local verification fixture',
  'local-verify-fixture.sql',
  now() + interval '90 days'
);

do $$
declare
  v_specs int;
  v_checklist int;
begin
  select count(*) into v_specs from public.site_specs
    where brand_kit_id = 'f3333333-3333-3333-3333-333333333333';
  assert v_specs = 1,
    format('expected the direction-selected creation trigger to seed exactly one site_specs row, got %s', v_specs);

  select count(*) into v_checklist from public.launch_checklist_items
    where brand_kit_id = 'f3333333-3333-3333-3333-333333333333' and done_at is not null;
  assert v_checklist >= 1,
    'expected at least the "Choose your creative direction" checklist item to be completed by the trigger';

  raise notice 'Fixture ready: kit f3333333-3333-3333-3333-333333333333, direction warm_welcome selected, site_specs seeded, comp access active.';
end
$$;
