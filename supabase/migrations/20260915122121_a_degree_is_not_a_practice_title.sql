-- ============================================================================
-- Un diplôme n'est pas un titre d'exercice
-- ============================================================================
-- `license_types` portait `psyd` (« Doctor of Psychology ») et `phd` (« Doctor
-- of Philosophy in Psychology ») à côté de LCSW, LMFT et des quatre noms du
-- conseil. C'est une erreur de catégorie, et elle est du même genre que celle
-- qui a produit « LMHC in Portland, Oregon » :
--
--   UN DIPLÔME dit où elle a étudié. Une université le délivre, il ne se
--   périme pas, aucun board ne l'accorde ni ne le retire, et il n'autorise
--   à exercer nulle part.
--
--   UN TITRE D'EXERCICE dit ce qu'elle a le droit de faire, et QUI le lui a
--   accordé. Un board d'État le délivre, il se renouvelle, il se suspend.
--
-- ⚠ ET LE TITRE D'EXERCICE DES PSYCHOLOGUES N'ÉTAIT PAS AU CATALOGUE. Il
-- s'appelle « Licensed Psychologist », il est protégé dans les cinquante
-- États, et le produit ne l'a jamais proposé — il proposait deux diplômes à
-- sa place. Une praticienne qui choisissait `psyd` ne déclarait donc AUCUNE
-- licence, et le texte pouvait dire « psychologist » sur la foi d'un diplôme.
--
-- ── CE QUE CETTE MIGRATION FAIT ─────────────────────────────────────────
--
-- 1. `degrees` — un catalogue de diplômes, à part.
-- 2. `project_briefs.degree_id` — FACULTATIF. Un diplôme est une information
--    de plus, jamais une condition : l'étape 1 ne doit pas se durcir pour
--    quelqu'un qui n'a pas envie de le donner.
-- 3. `psyd` et `phd` QUITTENT `license_types`, et `licensed_psychologist` y
--    entre, dans les 51 juridictions.
--
-- ⚠ LA SÉPARATION N'EST PAS COSMÉTIQUE : c'est elle qui permet à la garde
-- déontologique de dire « PsyD oui, psychologist non » sur le même brief. Tant
-- que les deux vivaient dans la même colonne, la question ne pouvait même pas
-- se poser.
--
-- ⚠ AUCUN BRIEF NE PORTE `psyd` NI `phd` (compté avant d'écrire : 0 et 0), donc
-- la sortie ne casse aucune ligne existante. La section 4 le revérifie plutôt
-- que de s'y fier.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Le catalogue des diplômes
-- ---------------------------------------------------------------------------
create table if not exists public.degrees (
  id         text primary key,
  label      text not null,
  /* L'intitulé complet, pour que la prose puisse l'écrire en toutes lettres
     sans le déduire — « Master of Social Work », jamais « MSW, i.e. … ». */
  full_name  text not null,
  sort_order integer not null,
  active     boolean not null default true
);

alter table public.degrees drop constraint if exists degrees_label_check;
alter table public.degrees
  add constraint degrees_label_check check (char_length(label) <= 12);

comment on table public.degrees is
  'Academic degrees, which a university grants and no board can withdraw. Deliberately NOT license_types: a degree authorises nothing, and the ethics guard has to be able to allow "PsyD" while refusing "psychologist" on the same brief.';

alter table public.degrees enable row level security;
drop policy if exists degrees_select_all on public.degrees;
create policy degrees_select_all on public.degrees
  for select to anon, authenticated
  using ((select current_user) = 'authenticated'
         or (select public.holds_anon_brief()));


-- ---------------------------------------------------------------------------
-- 2. La colonne, facultative
-- ---------------------------------------------------------------------------
alter table public.project_briefs
  add column if not exists degree_id text;

alter table public.project_briefs drop constraint if exists project_briefs_degree_id_fkey;
alter table public.project_briefs
  add constraint project_briefs_degree_id_fkey
  foreign key (degree_id) references public.degrees (id) on delete restrict;

comment on column public.project_briefs.degree_id is
  'Optional. Her degree, which is not her licence: carrying PsyD here does NOT let the copy call her a psychologist -- that needs license_type_id = licensed_psychologist. checkUnbackedClaims enforces the difference.';


-- ---------------------------------------------------------------------------
-- 3. Le titre d'exercice des psychologues entre, les deux diplômes sortent
-- ---------------------------------------------------------------------------
/*
 * ⚠ LE LIBELLÉ « LP » N'EST PAS VÉRIFIÉ, et il est exactement le cas que la
 * prochaine passe doit trancher. `license_types.label` est NATIONAL, et la
 * remarque qui accompagne ce lot est que cette abstraction est fausse : LPC,
 * LPCC, LCPC et LMHC sont déjà quatre noms d'États pour une même licence, et
 * « Licensed Psychologist » s'abrège différemment selon les boards. La
 * contrainte `char_length(label) <= 12` interdit d'y mettre l'intitulé entier.
 *
 * « LP » est donc un PLACEHOLDER assumé, et `description` porte le nom que les
 * cinquante boards emploient. La prose écrit l'intitulé, pas le sigle.
 */
-- >>> DEGREE AND PRACTICE TITLE DATA (mirrored verbatim in supabase/seed.sql) >>>

-- ⚠ CE BLOC CORRIGE `CATALOG DATA`, ET DOIT DONC ÊTRE REJOUÉ APRÈS LUI.
-- `CATALOG DATA` (20260827100000) insère encore `psyd` et `phd` comme titres
-- d'exercice — c'est son histoire, on ne la réécrit pas. Ce bloc-ci est la
-- correction, et `check_seed_mirrors.sh` vérifie qu'il est mirroré APRÈS dans
-- seed.sql : mirroré avant, l'ancienne copie gagnerait à chaque `db reset` et
-- les deux diplômes redeviendraient des licences en silence.

insert into public.degrees (id, label, full_name, sort_order) values
  ('ma',    'MA',    'Master of Arts',            1),
  ('ms',    'MS',    'Master of Science',         2),
  ('msw',   'MSW',   'Master of Social Work',     3),
  ('psyd',  'PsyD',  'Doctor of Psychology',      4),
  ('phd',   'PhD',   'Doctor of Philosophy',      5),
  ('edd',   'EdD',   'Doctor of Education',       6),
  ('md',    'MD',    'Doctor of Medicine',        7)
on conflict (id) do update
  set label = excluded.label,
      full_name = excluded.full_name,
      sort_order = excluded.sort_order;

insert into public.license_types (id, label, description, sort_order, active) values
  ('licensed_psychologist', 'LP', 'Licensed Psychologist', 9, true)
on conflict (id) do update
  set label = excluded.label,
      description = excluded.description;

insert into public.license_type_states (license_type_id, state_code)
select 'licensed_psychologist', st
  from (values
    ('AL'),('AK'),('AZ'),('AR'),('CA'),('CO'),('CT'),('DE'),('DC'),('FL'),
    ('GA'),('HI'),('ID'),('IL'),('IN'),('IA'),('KS'),('KY'),('LA'),('ME'),
    ('MD'),('MA'),('MI'),('MN'),('MS'),('MO'),('MT'),('NE'),('NV'),('NH'),
    ('NJ'),('NM'),('NY'),('NC'),('ND'),('OH'),('OK'),('OR'),('PA'),('RI'),
    ('SC'),('SD'),('TN'),('TX'),('UT'),('VT'),('VA'),('WA'),('WV'),('WI'),('WY')
  ) as s(st)
on conflict do nothing;

delete from public.license_type_states where license_type_id in ('psyd', 'phd');
delete from public.license_types       where id in ('psyd', 'phd');

-- <<< DEGREE AND PRACTICE TITLE DATA <<<


-- ---------------------------------------------------------------------------
-- 4. Garde-fous
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  -- Les deux diplômes ont quitté les licences…
  if exists (select 1 from public.license_types where id in ('psyd','phd')) then
    raise exception 'degrees: psyd/phd sont encore des titres d''exercice. Migration abandonnée.';
  end if;
  -- …et se retrouvent bien dans les diplômes.
  select count(*) into v_n from public.degrees where id in ('psyd','phd');
  if v_n <> 2 then
    raise exception 'degrees: psyd/phd ne sont pas au catalogue des diplômes. Migration abandonnée.';
  end if;

  -- ⚠ ET LE TITRE D'EXERCICE EXISTE ENFIN. Sortir les diplômes sans entrer le
  -- titre laisserait les psychologues sans aucune licence à choisir — une
  -- réparation qui casse un métier entier.
  if not exists (
    select 1 from public.license_types where id = 'licensed_psychologist'
  ) then
    raise exception 'degrees: licensed_psychologist manque. Migration abandonnée.';
  end if;

  select count(*) into v_n
    from public.license_type_states where license_type_id = 'licensed_psychologist';
  if v_n <> 51 then
    raise exception
      'degrees: licensed_psychologist couvre % juridictions, attendu 51. Migration abandonnée.', v_n;
  end if;

  -- Aucun brief n'a été cassé par la suppression.
  select count(*) into v_n
    from public.project_briefs where license_type_id in ('psyd','phd');
  if v_n <> 0 then
    raise exception 'degrees: % brief(s) référencent encore un diplôme comme licence.', v_n;
  end if;

  -- La matrice n'a pas changé de forme : toujours 51 juridictions connues,
  -- et toujours aucune vérifiée.
  select count(*) into v_n from public.sellable_states;
  if v_n <> 51 then
    raise exception 'degrees: la matrice couvre % juridictions, attendu 51.', v_n;
  end if;
  select count(*) into v_n from public.license_type_states where verified_at is not null;
  if v_n <> 0 then
    raise exception 'degrees: % ligne(s) sont marquées vérifiées sans que personne ne l''ait fait.', v_n;
  end if;

  -- ⚠ ET LE COUPLE DU RAPPORT RESTE REFUSÉ. Un lot qui répare une catégorie
  -- ne doit pas rouvrir la porte précédente.
  if public.license_state_allowed('lmhc', 'OR') then
    raise exception 'degrees: lmhc + OR est redevenu acceptable. Migration abandonnée.';
  end if;
  if not public.license_state_allowed('licensed_psychologist', 'OR') then
    raise exception 'degrees: un psychologue ne peut pas exercer en Oregon. Migration abandonnée.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   alter table public.project_briefs drop column if exists degree_id;
--   drop table if exists public.degrees;
--   delete from public.license_type_states where license_type_id = 'licensed_psychologist';
--   delete from public.license_types where id = 'licensed_psychologist';
--   -- et réinsérer psyd/phd dans license_types, ce qui referait l'erreur de
--   -- catégorie : ne revenir en arrière que pour restaurer un état, jamais
--   -- comme correction.
