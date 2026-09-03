-- ============================================================================
-- scripts/local-verify-stub-schema.sql
-- ============================================================================
-- NOT a migration, and not run against any Supabase-hosted database. This
-- exists for exactly one situation: a sandbox that can run a real local
-- PostgreSQL server but cannot run Docker (so `supabase start` is
-- unavailable) and cannot reach any Supabase-hosted endpoint over the
-- network (so there is no remote database to point at either). See
-- DECISIONS.md in eklio-frontend, "Local verification, given no Docker and
-- no Supabase REST access."
--
-- It hand-builds the minimum `auth` and `storage` surface this repo's own
-- migrations and tests actually reference — not a claim of parity with
-- Supabase's real schemas, which are much larger and not fully documented.
-- Every piece here was added because a real migration or test in this repo
-- needed it, traced by running the replay and reading the actual error, not
-- guessed in advance. If a future migration needs something not stubbed
-- here, the fix is to add exactly that, the same way.
--
-- Usage:
--   createdb eklio_local_verify
--   psql eklio_local_verify -v ON_ERROR_STOP=1 -f scripts/local-verify-stub-schema.sql
--   for f in supabase/migrations/*.sql; do
--     psql eklio_local_verify -v ON_ERROR_STOP=1 -f "$f" || break
--   done
--   for f in supabase/tests/*.test.sql; do
--     psql eklio_local_verify -v ON_ERROR_STOP=1 -f "$f" || break
--   done
-- ============================================================================

\set ON_ERROR_STOP on

-- ── Roles ───────────────────────────────────────────────────────────────
-- Matches Supabase's own three: anon/authenticated are ordinary roles RLS
-- policies target; service_role bypasses RLS (BYPASSRLS), same as the real
-- one. The connecting superuser (this session, `postgres` locally) already
-- bypasses RLS on its own, same as in a real Supabase project.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

grant all on schema public to anon, authenticated, service_role;

-- Matches Supabase's own project-level defaults (this repo's README and
-- 20260902090000_revoke_internal_function_surface.sql both document that
-- default: "toute fonction naît avec EXECUTE accordé à PUBLIC", and the
-- equivalent applies to tables). Set as the default for every table/
-- function/sequence a later migration creates in `public`, run as the same
-- role (postgres, this session) migrations replay as — ALTER DEFAULT
-- PRIVILEGES only affects objects the SAME role creates afterward. The
-- grant on auth/storage's OWN tables (already created below) is separate,
-- at the end of this file, once those schemas exist.
alter default privileges in schema public
  grant select, insert, update, delete on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant execute on functions to anon, authenticated, service_role;
alter default privileges in schema public
  grant usage, select on sequences to anon, authenticated, service_role;

-- ── auth schema ─────────────────────────────────────────────────────────
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

-- Only the columns this repo's migrations/tests actually reference.
create table if not exists auth.users (
  id         uuid primary key default gen_random_uuid(),
  email      text,
  created_at timestamptz not null default now()
);
grant select on auth.users to anon, authenticated, service_role;

-- The real Supabase implementation: reads the `sub` claim PostgREST sets
-- from the caller's JWT via `request.jwt.claims`. Tests simulate a caller
-- with `set local role authenticated; set local request.jwt.claims =
-- '{"sub":"<uuid>"}';` — this function is what makes that simulation mean
-- anything.
create or replace function auth.uid()
returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid
$$;

create or replace function auth.role()
returns text
language sql stable
as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '')::text
$$;

-- ── storage schema ──────────────────────────────────────────────────────
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
grant select on storage.buckets to anon, authenticated, service_role;

-- Column list matches the live project exactly (queried directly against
-- fobgdsupyfslxbswfuay via information_schema, 2026-09-03), not guessed.
create table if not exists storage.objects (
  id                uuid primary key default gen_random_uuid(),
  bucket_id         text references storage.buckets (id),
  name              text,
  owner             uuid,
  created_at        timestamptz default now(),
  updated_at        timestamptz default now(),
  last_accessed_at  timestamptz default now(),
  metadata          jsonb,
  path_tokens       text[] generated always as (string_to_array(name, '/')) stored,
  version           text,
  owner_id          text,
  user_metadata     jsonb,
  archived_at       timestamptz,
  is_delete_marker  boolean default false,
  is_versioned      boolean default false
);
alter table storage.objects enable row level security;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;

-- The real Supabase storage helper: every path segment except the last
-- (the filename). Used by this repo's storage RLS policies to read the
-- brand_kit_id out of an object path's first segment.
create or replace function storage.foldername(name text)
returns text[]
language plpgsql
as $$
declare
  _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1 : greatest(array_length(_parts, 1) - 1, 0)];
end;
$$;

grant select on all tables in schema auth, storage to anon, authenticated, service_role;

-- ── Extensions this repo's migrations assume are already enabled ─────────
-- (Supabase's own Postgres image pre-enables these; a stock apt install
-- does not.) gen_random_uuid() is core since PG13, needs nothing.
create extension if not exists pg_trgm;
