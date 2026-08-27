-- ============================================================================
-- Eklio — American English throughout the database
-- ============================================================================
-- Eklio serves therapists in private practice in the United States. Every
-- string this schema stores or exposes is read, sooner or later, by an American
-- user or by the American-English generation prompt that consumes it. A column
-- called `metier` beside one called `heading_font` is not merely untidy — it is
-- a term the generator has to be told to ignore and the frontend has to spell
-- correctly from memory.
--
-- WHAT THIS MIGRATION COVERS: the DATABASE. Column names, defaults, stored
-- values and `COMMENT ON` strings — everything an introspection of
-- `fobgdsupyfslxbswfuay` returns, and everything `types/supabase.ts` is
-- generated from.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH: the SQL comments inside the three
-- earlier migration files. Those are the applied history of this schema and the
-- record of why it looks the way it does; rewriting a migration that has
-- already run on the hosted project is the practice this repo exists to end
-- (see the header of the reference schema). New SQL written from this point on
-- is English, which is the rule going forward rather than retroactively.
--
-- ⚠⚠ THIS IS A BREAKING CHANGE FOR eklio-frontend. Three columns are renamed.
-- Any query naming `metier`, `typographie_titre` or `typographie_corps` breaks
-- the moment this is applied, and `types/supabase.ts` must be regenerated
-- against the US project before the frontend is touched again. That is not a
-- side effect to discover later; it is the point of the hand-off note.
-- ============================================================================


-- ============================================================================
-- 1. Column renames
-- ============================================================================
-- `rename column` preserves the data, the type, every constraint and every
-- index — nothing is copied and nothing can be lost. Guarded so the migration
-- stays replayable on a database where it has already run.
--
-- The two `directions` columns take the names the rest of the schema already
-- uses for the same two things: `type_pairings.heading_font` / `body_font`, and
-- `brand_kits.directions[].typography.heading_font` / `body_font`. Three names
-- for one concept was the actual cost of the French, not the language.

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='projects' and column_name='metier') then
    alter table public.projects rename column metier to profession;
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='directions' and column_name='typographie_titre') then
    alter table public.directions rename column typographie_titre to heading_font;
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='directions' and column_name='typographie_corps') then
    alter table public.directions rename column typographie_corps to body_font;
  end if;
end
$$;


-- ============================================================================
-- 2. The default that writes French into every new row
-- ============================================================================
-- `projects.name default 'Mon projet'` is the one piece of French this schema
-- was still actively producing: every project created since the reference
-- migration got it. The backfill touches ONLY rows still carrying that exact
-- default — a project the user has actually named is their text, not ours, and
-- is left alone whatever language it is in.

alter table public.projects alter column name set default 'My project';

update public.projects
   set name = 'My project'
 where name = 'Mon projet';


-- ============================================================================
-- 3. Comments
-- ============================================================================
-- Re-stated in English, with the same content. These are stored in the
-- database, surface in every introspection tool, and are the first thing a new
-- reader of this schema meets.

comment on table public.profiles is
  'One-to-one mirror of auth.users. Populated by the handle_new_user trigger (SECURITY DEFINER) and removed by cascade from auth.users. The profiles_insert_denied / profiles_delete_denied policies document that neither command is exposed to clients.';

comment on column public.profiles.stripe_customer_id is
  'Stripe customer identifier (cus_...), unique. The canonical user-to-Stripe mapping, shared by the one-time kit purchase and the Monthly Presence subscription.';

comment on column public.brand_kits.tier is
  'Scope delivered by THIS kit (starter/practice/signature). A snapshot taken at generation time, not the current entitlement: that lives in purchases.';

comment on table public.purchases is
  'Kit purchases (one-time payment, three tiers). One EVENT per payment: an upgrade adds a row rather than replacing one. Written by the Stripe webhook (service_role).';

comment on table public.stripe_events is
  'Stripe webhook idempotency log. Written and read by service_role ONLY: RLS enabled, no policy, anon/authenticated privileges revoked.';

comment on column public.projects.profession is
  'The practitioner''s profession, as entered during the brief. Renamed from metier.';

comment on column public.directions.heading_font is
  'Heading typeface of this legacy direction row. Renamed from typographie_titre; same concept as type_pairings.heading_font.';

comment on column public.directions.body_font is
  'Body typeface of this legacy direction row. Renamed from typographie_corps; same concept as type_pairings.body_font.';


-- ============================================================================
-- 4. Guard rail — the claim is "zero French in the database", so check it
-- ============================================================================
-- A checklist item that is only ever verified by reading is verified once. This
-- runs on every apply.

do $$
declare
  offenders text;
begin
  -- Column names.
  select string_agg(table_name || '.' || column_name, ', ')
    into offenders
    from information_schema.columns
   where table_schema = 'public'
     and column_name ~* '(metier|typographie|libelle|categorie|prenom|adresse|nom_|_nom)';
  if offenders is not null then
    raise exception 'english_only_schema: French column names remain: %', offenders;
  end if;

  -- Defaults.
  select string_agg(table_name || '.' || column_name, ', ')
    into offenders
    from information_schema.columns
   where table_schema = 'public'
     and column_default ~* '(Mon projet|Nouveau|Sans titre)';
  if offenders is not null then
    raise exception 'english_only_schema: French column defaults remain: %', offenders;
  end if;

  -- CHECK constraint values.
  select string_agg(conrelid::regclass || '.' || conname, ', ')
    into offenders
    from pg_constraint
   where connamespace = 'public'::regnamespace
     and contype = 'c'
     and pg_get_constraintdef(oid) ~* '''(positionnement|ton|audience|typographies|metier)''';
  if offenders is not null then
    raise exception 'english_only_schema: French values remain in CHECK constraints: %', offenders;
  end if;

  -- Comments. Accented characters are the reliable tell; the bare-word list
  -- catches unaccented French that would otherwise slip through.
  select string_agg(what, ', ') into offenders from (
    select 'table ' || c.relname as what
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and obj_description(c.oid, 'pg_class') ~ '[éèêàçùôûîï]|\y(les|des|une|pour|qui|sont|aucune|uniquement|par le|de la)\y'
    union all
    select 'column ' || c.relname || '.' || a.attname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attnum > 0
     where n.nspname = 'public' and c.relkind = 'r'
       and col_description(c.oid, a.attnum) ~ '[éèêàçùôûîï]|\y(les|des|une|pour|qui|sont|aucune|uniquement|par le|de la)\y'
  ) s;
  if offenders is not null then
    raise exception 'english_only_schema: French comments remain on: %', offenders;
  end if;

  -- The renames actually landed.
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='projects' and column_name='profession') then
    raise exception 'english_only_schema: projects.profession is missing.';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='directions' and column_name='heading_font') then
    raise exception 'english_only_schema: directions.heading_font is missing.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
-- Restores the French names. Only worth running to unbreak a frontend that has
-- not been regenerated yet; the right fix is to regenerate types/supabase.ts.
--
--   alter table public.projects   rename column profession   to metier;
--   alter table public.directions rename column heading_font to typographie_titre;
--   alter table public.directions rename column body_font    to typographie_corps;
--   alter table public.projects alter column name set default 'Mon projet';
