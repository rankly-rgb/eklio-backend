-- ============================================================================
-- Tests — tenancy layer, lot C1: us_states / population_cards
-- ============================================================================
begin;

do $$
declare n int;
begin
  select count(*) into n from public.us_states;
  assert n = 51, format('us_states has %s rows, expected 51 (50 states + DC)', n);

  select count(*) into n from public.population_cards where active;
  assert n = 16, format('population_cards has %s active rows, expected 16', n);

  assert not exists (select 1 from public.population_cards where char_length(label) > 24),
         'a population_cards label exceeds 24 characters';
end
$$;

-- ---------------------------------------------------------------------------
-- Populations and modalities are two distinct lists, on purpose: no id
-- collides, and population_cards is not modality_cards under a new name.
-- ---------------------------------------------------------------------------
do $$
begin
  assert not exists (
    select id from public.population_cards
    intersect
    select id from public.modality_cards
  ), 'a population_cards id collides with a modality_cards id — the two lists must stay separate';
end
$$;

-- ---------------------------------------------------------------------------
-- Readable by an authenticated user, closed to anon
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_table_privilege('anon', 'public.us_states', 'SELECT'),
         'anon can select us_states';
  assert not has_table_privilege('anon', 'public.population_cards', 'SELECT'),
         'anon can select population_cards';
  assert has_table_privilege('authenticated', 'public.us_states', 'SELECT'),
         'authenticated cannot select us_states';
  assert has_table_privilege('authenticated', 'public.population_cards', 'SELECT'),
         'authenticated cannot select population_cards';
end
$$;

do $$
declare n int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
  select count(*) into n from public.us_states;
  assert n = 51, 'an authenticated user could not read the full us_states table';
  select count(*) into n from public.population_cards;
  assert n = 16, 'an authenticated user could not read the full population_cards table';
  reset role;
end
$$;

rollback;
