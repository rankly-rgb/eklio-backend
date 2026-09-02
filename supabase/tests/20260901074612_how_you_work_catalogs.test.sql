-- ============================================================================
-- Tests — 20260901074612_how_you_work_catalogs.sql
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Row counts
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select count(*) from public.session_style_cards)       = 8, 'session_style_cards must hold exactly 8 rows';
  assert (select count(*) from public.not_a_fit_cards)           = 8, 'not_a_fit_cards must hold exactly 8 rows';
  assert (select count(*) from public.modality_cards)            = 14, 'modality_cards must hold exactly 14 rows';
  assert (select count(*) from public.modality_prominence_options) = 3, 'modality_prominence_options must hold exactly 3 rows';
end
$$;

-- ---------------------------------------------------------------------------
-- voice_hints, verbatim for a couple of cards the frontend chip row depends on
-- ---------------------------------------------------------------------------
do $$
begin
  assert (select voice_hints from public.session_style_cards where id = 'direct')
       = array['direct','candid','plainspoken'], 'direct voice_hints drifted';
  assert (select voice_hints from public.session_style_cards where id = 'body')
       = array['grounded','embodied','attentive'], 'body voice_hints drifted';
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: readable by authenticated, and does not filter on active
-- ---------------------------------------------------------------------------
do $$
begin
  update public.session_style_cards set active = false where id = 'humor';
end
$$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare n int;
begin
  select count(*) into n from public.session_style_cards;
  assert n = 8, 'authenticated must see all 8 rows regardless of active';

  select count(*) into n from public.not_a_fit_cards;
  assert n = 8, 'authenticated must see all 8 not_a_fit_cards rows';

  select count(*) into n from public.modality_cards;
  assert n = 14, 'authenticated must see all 14 modality_cards rows';

  select count(*) into n from public.modality_prominence_options;
  assert n = 3, 'authenticated must see all 3 modality_prominence_options rows';
end
$$;

reset role;
rollback;
