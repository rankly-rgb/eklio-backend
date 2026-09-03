-- ============================================================================
-- Eklio — lot C1: clinician reference data (licensed states, populations)
-- ============================================================================
-- Modalities and their prominence already exist (modality_cards,
-- modality_prominence_options), as do session_style_cards and
-- not_a_fit_cards — reused as-is, nothing new created for them.
--
-- ⚠ POPULATIONS AND MODALITIES ARE TWO DISTINCT LISTS, ON PURPOSE. A
-- modality is HOW a clinician works (CBT, EMDR, psychodynamic); a population
-- is WHO she works with (adolescents, veterans, couples). Field research on
-- a real practice found the grid that actually draws organic traffic is
-- modality × licensed state × population, as three SEPARATE axes — merging
-- populations into the modality list would collapse that grid into two axes
-- and make every bio page read as generated rather than written. This
-- migration never merges them, and neither should anything downstream.
-- ============================================================================

create table public.us_states (
  code char(2) primary key,
  name text not null
);

alter table public.us_states enable row level security;
create policy "us_states_select_all"
  on public.us_states for select to authenticated using (true);
-- No write policy: a client never adds a state to the union.
-- Nothing in the public D-lot routes needs this table (the invite landing
-- page reads no reference data), so anon's default schema-wide grant is
-- revoked outright rather than left in place behind the authenticated-only
-- policy — closes the surface instead of growing anon_surface_baseline.
revoke all on public.us_states from anon;

insert into public.us_states (code, name) values
  ('AL','Alabama'), ('AK','Alaska'), ('AZ','Arizona'), ('AR','Arkansas'),
  ('CA','California'), ('CO','Colorado'), ('CT','Connecticut'), ('DE','Delaware'),
  ('DC','District of Columbia'), ('FL','Florida'), ('GA','Georgia'), ('HI','Hawaii'),
  ('ID','Idaho'), ('IL','Illinois'), ('IN','Indiana'), ('IA','Iowa'),
  ('KS','Kansas'), ('KY','Kentucky'), ('LA','Louisiana'), ('ME','Maine'),
  ('MD','Maryland'), ('MA','Massachusetts'), ('MI','Michigan'), ('MN','Minnesota'),
  ('MS','Mississippi'), ('MO','Missouri'), ('MT','Montana'), ('NE','Nebraska'),
  ('NV','Nevada'), ('NH','New Hampshire'), ('NJ','New Jersey'), ('NM','New Mexico'),
  ('NY','New York'), ('NC','North Carolina'), ('ND','North Dakota'), ('OH','Ohio'),
  ('OK','Oklahoma'), ('OR','Oregon'), ('PA','Pennsylvania'), ('RI','Rhode Island'),
  ('SC','South Carolina'), ('SD','South Dakota'), ('TN','Tennessee'), ('TX','Texas'),
  ('UT','Utah'), ('VT','Vermont'), ('VA','Virginia'), ('WA','Washington'),
  ('WV','West Virginia'), ('WI','Wisconsin'), ('WY','Wyoming')
on conflict (code) do update set name = excluded.name;


create table public.population_cards (
  id         text    primary key,
  sort_order int     not null,
  active     boolean not null default true,
  label      text    not null,
  full_name  text    not null
);

alter table public.population_cards
  add constraint population_cards_label_check check (char_length(label) <= 24);

alter table public.population_cards enable row level security;
create policy "population_cards_select_all"
  on public.population_cards for select to authenticated using (true);
revoke all on public.population_cards from anon;

insert into public.population_cards (id, sort_order, active, label, full_name) values
  ('adolescents',       1,  true, 'Adolescents',       'Adolescents and teens'),
  ('children',          2,  true, 'Children',          'Children'),
  ('couples',           3,  true, 'Couples',           'Couples'),
  ('families',          4,  true, 'Families',          'Families'),
  ('individuals',       5,  true, 'Individuals',       'Individual adults'),
  ('veterans',          6,  true, 'Veterans',          'Veterans and service members'),
  ('first_responders',  7,  true, 'First responders',  'First responders'),
  ('healthcare_workers',8,  true, 'Healthcare workers','Healthcare workers'),
  ('perinatal',         9,  true, 'Perinatal',         'Perinatal and postpartum clients'),
  ('lgbtq',             10, true, 'LGBTQ+ clients',    'LGBTQ+ clients'),
  ('college_students',  11, true, 'College students',  'College and graduate students'),
  ('seniors',           12, true, 'Older adults',      'Older adults and seniors'),
  ('trauma_survivors',  13, true, 'Trauma survivors',  'Trauma and abuse survivors'),
  ('grief_and_loss',    14, true, 'Grief and loss',    'Clients navigating grief and loss'),
  ('chronic_illness',   15, true, 'Chronic illness',   'Clients living with chronic illness or pain'),
  ('athletes',          16, true, 'Athletes',          'Athletes and performers')
on conflict (id) do update set
  sort_order = excluded.sort_order,
  label      = excluded.label,
  full_name  = excluded.full_name;
