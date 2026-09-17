-- ============================================================================
-- One line per schema object, in a form that can be compared between databases
-- ============================================================================
-- ⚠ THE QUESTION THIS ANSWERS IS "DOES THIS REPOSITORY DESCRIBE THE DATABASE?"
--
-- Everything written this month — the in-body authority checks, the function
-- surface enumeration, the tenancy enumeration — is a guarantee about a schema
-- built by replaying `supabase/migrations`. If production is not that schema,
-- they are guarantees about a different database.
--
-- `direction_asset_daily_spend` was the first divergence found (RLS on in
-- production, off in a replay). This file exists to answer whether it was the
-- only one, mechanically rather than by spot check.
--
-- Run it identically against both sides:
--
--   psql "$REPLAY_URL" -At -f supabase/tests/helpers/schema_fingerprint.sql
--
-- and diff. Output is `kind|identity|fingerprint`, sorted, with no timestamps,
-- no oids and no row counts — nothing that legitimately differs between two
-- correct copies of the same schema.
-- ============================================================================

with
rls as (
  select 'rls' as kind, c.relname::text as identity,
         case when c.relrowsecurity then 'on' else 'OFF' end
      || case when c.relforcerowsecurity then '+forced' else '' end as detail
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
),
policies as (
  select 'policy', p.tablename || '.' || p.policyname,
         md5(p.cmd || '|' || array_to_string(p.roles, ',') || '|' ||
             coalesce(p.qual, '-') || '|' || coalesce(p.with_check, '-') || '|' ||
             case when p.permissive = 'PERMISSIVE' then 'p' else 'r' end)
    from pg_policies p where p.schemaname = 'public'
),
constraints as (
  select 'constraint', c.conrelid::regclass::text || '.' || c.conname,
         md5(pg_get_constraintdef(c.oid))
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public'
),
indexes as (
  select 'index', i.tablename || '.' || i.indexname, md5(i.indexdef)
    from pg_indexes i where i.schemaname = 'public'
),
triggers as (
  -- `tgisinternal` triggers are the ones Postgres creates to enforce foreign
  -- keys; they are already covered by the constraint rows and would only add
  -- noise keyed on names that contain oids.
  select 'trigger', t.tgrelid::regclass::text || '.' || t.tgname,
         md5(pg_get_triggerdef(t.oid))
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not t.tgisinternal
),
functions as (
  select 'function', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         md5(pg_get_functiondef(p.oid))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
),
/*
 * ⚠ THE SAME FUNCTIONS AGAIN, WITH THE COMMENTARY TAKEN OUT.
 *
 * `pg_get_functiondef` returns the body exactly as it was stored, comments
 * included — so a migration file whose comments were edited AFTER it was
 * applied produces a body that differs from production in prose and not in
 * behaviour. That is a real divergence (the repository no longer says what
 * ran) but it is not a behavioural one, and conflating the two would either
 * cry wolf or hide a genuine difference inside a pile of noise.
 *
 * A function that differs in `function` but NOT in `function.body` differs
 * only in its comments or whitespace. One that differs in both differs in
 * what it does.
 *
 * ⚠ THE NORMALISATION IS APPROXIMATE, AND IN THE UNSAFE DIRECTION: it strips
 * `--` and block comments without knowing whether they sit inside a string
 * literal, so a function containing the literal text '--' would be normalised
 * wrongly and could be made to look equal when it is not. It is therefore only
 * ever used to EXPLAIN a difference the raw comparison already found, never to
 * dismiss one on its own.
 */
function_bodies as (
  select 'function.body',
         p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         md5(btrim(regexp_replace(
           regexp_replace(
             regexp_replace(pg_get_functiondef(p.oid), '/\*.*?\*/', ' ', 'gs'),
             '--[^\n]*', ' ', 'g'),
           '\s+', ' ', 'g')))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
),
-- ⚠ GRANTS ARE NORMALISED, NOT DUMPED. `relacl` is an array whose ORDER is an
-- artefact of the order grants were issued, so two identical permission sets
-- compare unequal if dumped raw. aclexplode + sort is the comparable form.
-- The grantor is dropped: it is the owner on both sides and carries no meaning
-- here.
--
-- ⚠⚠ AND THEY ARE SPLIT IN TWO, WHICH IS THE POINT OF THIS SECTION.
--
-- Dumped whole, this row reported SIXTY-FIVE tables in disagreement between
-- production and a local replay — every table there is. None of the sixty-five
-- was real. Two causes, both environmental, both found on 17 September and
-- written down here so the next reader does not spend a morning on them:
--
--   1. `MAINTAIN` is a privilege that PostgreSQL 17 added and 16 does not
--      have. Production runs 17; the local replay ran 16.13. Every ACL in
--      production therefore carries one privilege the replay cannot express.
--
--   2. Supabase's own bootstrap runs `alter default privileges ... grant all
--      on tables to anon, authenticated, service_role`, and ALL includes
--      REFERENCES, TRIGGER and TRUNCATE. `scripts/local-verify-stub-schema.sql`
--      grants a narrower set, because those three decide nothing here.
--
-- Restricted to the four privileges that DECIDE something — who may read, add,
-- change or remove a row — the two sides were identical on all 62 shared
-- tables, same count, same hash. So `grant.table` now carries exactly those
-- four, and everything else moves to `grant.table.env`, which the drift report
-- prints and does not count.
--
-- This is not tidying. A report that cries wolf sixty-five times is a report
-- nobody reads a second time, and the three genuine differences this file was
-- built to surface were sitting underneath that pile.
table_grants as (
  select 'grant.table', c.relname::text,
         md5(coalesce((
           select string_agg(g.grantee_name || ':' || g.priv, ',' order by g.grantee_name, g.priv)
             from (select coalesce(r.rolname, 'PUBLIC') as grantee_name, a.privilege_type as priv
                     from aclexplode(c.relacl) a
                     left join pg_roles r on r.oid = a.grantee
                    where a.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')) g
         ), 'NO-ACL'))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
),
-- The rest of the table ACL: REFERENCES, TRIGGER, TRUNCATE, and MAINTAIN where
-- the server is new enough to have it. Kept rather than dropped — a privilege
-- silently discarded is a privilege nobody can audit — but reported apart.
table_grants_env as (
  select 'grant.table.env', c.relname::text,
         md5(coalesce((
           select string_agg(g.grantee_name || ':' || g.priv, ',' order by g.grantee_name, g.priv)
             from (select coalesce(r.rolname, 'PUBLIC') as grantee_name, a.privilege_type as priv
                     from aclexplode(c.relacl) a
                     left join pg_roles r on r.oid = a.grantee
                    where a.privilege_type not in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')) g
         ), 'NONE'))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
),
-- ⚠ SAME SPLIT, DIFFERENT AXIS. Function ACLs only ever carry EXECUTE, so
-- there is no privilege to filter; what differed was the GRANTEE. Production
-- grants EXECUTE to `supabase_admin` on the 31 functions that belong to
-- extensions (pg_trgm), and that role does not exist in a local replay at all.
-- Thirty-one more false differences, from a role no migration in this
-- repository ever mentions.
--
-- Grantees that exist only on the hosted platform are therefore reported in
-- `grant.function.env`. Everything a migration can actually grant — PUBLIC,
-- anon, authenticated, service_role, postgres — stays in `grant.function`,
-- where the README's "anon receives EXECUTE on every function created" is
-- still visible. With supabase_admin set aside, the two sides agreed on all
-- 211 functions neither the eleven recovered migrations nor this week touched.
function_grants as (
  select 'grant.function',
         p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         md5(coalesce((
           select string_agg(g.grantee_name || ':' || g.priv, ',' order by g.grantee_name, g.priv)
             from (select coalesce(r.rolname, 'PUBLIC') as grantee_name, a.privilege_type as priv
                     from aclexplode(p.proacl) a
                     left join pg_roles r on r.oid = a.grantee
                    where coalesce(r.rolname, 'PUBLIC') not in (
                      'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin',
                      'supabase_read_only_user', 'supabase_realtime_admin',
                      'dashboard_user', 'authenticator', 'pgbouncer')) g
         ),
         -- ⚠ A NULL proacl IS NOT "NO GRANTS". In PostgreSQL it means the
         -- default, and the default for a function is EXECUTE to PUBLIC. The
         -- two must not fingerprint the same, or the whole function-surface
         -- question becomes invisible to this file.
         'DEFAULT=EXECUTE-TO-PUBLIC'))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
),
function_grants_env as (
  select 'grant.function.env',
         p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         md5(coalesce((
           select string_agg(g.grantee_name || ':' || g.priv, ',' order by g.grantee_name, g.priv)
             from (select coalesce(r.rolname, 'PUBLIC') as grantee_name, a.privilege_type as priv
                     from aclexplode(p.proacl) a
                     left join pg_roles r on r.oid = a.grantee
                    where coalesce(r.rolname, 'PUBLIC') in (
                      'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin',
                      'supabase_read_only_user', 'supabase_realtime_admin',
                      'dashboard_user', 'authenticator', 'pgbouncer')) g
         ), 'NONE'))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
),
columns as (
  select 'column', c.table_name || '.' || c.column_name,
         md5(c.data_type || '|' || c.is_nullable || '|' ||
             coalesce(c.column_default, '-') || '|' ||
             coalesce(c.character_maximum_length::text, '-'))
    from information_schema.columns c
   where c.table_schema = 'public'
),
everything as (
  select * from rls
  union all select * from policies
  union all select * from constraints
  union all select * from indexes
  union all select * from triggers
  union all select * from functions
  union all select * from function_bodies
  union all select * from table_grants
  union all select * from table_grants_env
  union all select * from function_grants
  union all select * from function_grants_env
  union all select * from columns
)
select kind || '|' || identity || '|' || detail
  from everything
 order by kind, identity;
