-- ============================================================================
-- Tests — 20260827107000_english_only_schema.sql
-- ============================================================================
-- "Zero French in the database" is a claim about every object at once, so it is
-- tested by sweeping the catalog rather than by naming the objects that were
-- fixed. A new French column added tomorrow fails this file.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Column names
-- ---------------------------------------------------------------------------
do $$
declare
  offenders text;
begin
  select string_agg(table_name || '.' || column_name, ', ')
    into offenders
    from information_schema.columns
   where table_schema = 'public'
     and column_name ~* '(metier|typographie|libelle|categorie|prenom|adresse|couleur|nom_|_nom)';
  assert offenders is null, coalesce('French column names remain: ' || offenders, '');

  assert exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='projects' and column_name='profession'),
         'projects.profession is missing; the rename did not happen';
  assert exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='directions' and column_name='heading_font'),
         'directions.heading_font is missing; the rename did not happen';
  assert exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='directions' and column_name='body_font'),
         'directions.body_font is missing; the rename did not happen';
end
$$;

-- ---------------------------------------------------------------------------
-- Defaults, and the value they write into every new row
-- ---------------------------------------------------------------------------
do $$
declare
  offenders text;
begin
  select string_agg(table_name || '.' || column_name, ', ')
    into offenders
    from information_schema.columns
   where table_schema='public' and column_default ~* '(Mon projet|Nouveau|Sans titre|Aucun)';
  assert offenders is null, coalesce('French column defaults remain: ' || offenders, '');

  assert (select column_default from information_schema.columns
           where table_name='projects' and column_name='name') = '''My project''::text',
         'the projects.name default is not the English one';

  assert not exists (select 1 from public.projects where name = 'Mon projet'),
         'rows still carry the old French default name';
end
$$;

-- ---------------------------------------------------------------------------
-- Stored values in CHECK constraints
-- ---------------------------------------------------------------------------
do $$
declare
  offenders text;
begin
  select string_agg(conrelid::regclass || '.' || conname, ', ')
    into offenders
    from pg_constraint
   where connamespace = 'public'::regnamespace and contype = 'c'
     and pg_get_constraintdef(oid) ~* '''(positionnement|ton|audience|typographies|metier|brouillon|termine)''';
  assert offenders is null, coalesce('French values remain in CHECK constraints: ' || offenders, '');
end
$$;

-- ---------------------------------------------------------------------------
-- Comments stored on tables and columns
-- ---------------------------------------------------------------------------
do $$
declare
  offenders text;
begin
  select string_agg(what, ', ') into offenders from (
    select 'table ' || c.relname as what
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and obj_description(c.oid,'pg_class') ~ '[éèêàçùôûîï]|\y(les|des|une|pour|qui|sont|aucune|uniquement)\y'
    union all
    select 'column ' || c.relname || '.' || a.attname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attnum > 0
     where n.nspname = 'public' and c.relkind = 'r'
       and col_description(c.oid, a.attnum) ~ '[éèêàçùôûîï]|\y(les|des|une|pour|qui|sont|aucune|uniquement)\y'
  ) s;
  assert offenders is null, coalesce('French comments remain on: ' || offenders, '');
end
$$;

-- ---------------------------------------------------------------------------
-- Seeded catalog data
-- ---------------------------------------------------------------------------
do $$
declare
  offenders text;
begin
  select string_agg(t, ', ') into offenders from (
    select 'tone_cards'           as t from public.tone_cards           where sample_hero ~ '[éèêàçùôûîï]'
    union all
    select 'client_persona_cards'      from public.client_persona_cards where label ~ '[éèêàçùôûîï]' or description ~ '[éèêàçùôûîï]'
    union all
    select 'problem_cards'             from public.problem_cards        where label ~ '[éèêàçùôûîï]' or description ~ '[éèêàçùôûîï]'
    union all
    select 'gain_cards'                from public.gain_cards           where label ~ '[éèêàçùôûîï]' or description ~ '[éèêàçùôûîï]'
    union all
    select 'ethics_rules'              from public.ethics_rules         where description ~ '[éèêàçùôûîï]' or example_forbidden ~ '[éèêàçùôûîï]'
    union all
    select 'license_types'             from public.license_types        where label ~ '[éèêàçùôûîï]' or description ~ '[éèêàçùôûîï]'
    union all
    select 'specialties'               from public.specialties          where label ~ '[éèêàçùôûîï]'
    union all
    select 'site_goals'                from public.site_goals           where label ~ '[éèêàçùôûîï]' or description ~ '[éèêàçùôûîï]'
    union all
    select 'primary_actions'           from public.primary_actions      where label ~ '[éèêàçùôûîï]'
  ) s;
  assert offenders is null, coalesce('accented (French) strings remain in seed data: ' || offenders, '');
end
$$;

rollback;
