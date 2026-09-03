-- ============================================================================
-- Minimal Supabase-like stubs for local migration/test verification
-- ============================================================================
-- NOT a real Supabase environment: no PostgREST, no realtime, no vault, no
-- pg_net. Just enough of `auth` and `storage` for supabase/migrations/*.sql
-- and supabase/tests/*.sql to apply and run against a plain local Postgres.
-- Built by grepping every migration for auth./storage. references and
-- stubbing exactly those — nothing more. See run.sh and README.md in this
-- directory. NEVER applied to a Supabase project.
-- ============================================================================

create schema if not exists auth;
create schema if not exists extensions;
create schema if not exists storage;

-- Real Supabase projects install default extensions (pgcrypto included) into
-- `extensions`, not `public` — matching that here so the org-invite RPCs,
-- which schema-qualify as `extensions.digest` etc. on that assumption, can
-- actually run. This is an assumption about the real project this stack
-- cannot verify — see 20260903102500_org_invite_rpcs.sql's own comment.
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext;
create extension if not exists pg_trgm;

-- Roles PostgREST would otherwise provide.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

grant usage on schema public, auth, storage, extensions to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- auth.users + auth.uid(): auth.uid() reads the request.jwt.claims GUC,
-- exactly what PostgREST sets per-request and what supabase/tests/README.md
-- ("Tester la RLS") already documents as the way this repo's own tests fake
-- a caller. auth.jwt() is NOT stubbed: no migration in this repo calls it —
-- confirmed by grep — so it would be more stub than these files need.
create table auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb
);

create or replace function auth.uid()
returns uuid
language sql stable
as $$
  select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid;
$$;

-- storage.buckets / storage.objects / storage.foldername: trimmed to what
-- 20260903102000_brand_field_sources.sql's brand-logos bucket policies use.
create table storage.buckets (
  id         text primary key,
  name       text not null,
  public     boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text references storage.buckets (id),
  name       text,
  owner      uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table storage.objects enable row level security;

create or replace function storage.foldername(name text)
returns text[]
language sql immutable
as $$
  select case when position('/' in name) = 0 then array[]::text[]
              else string_to_array(regexp_replace(name, '/[^/]*$', ''), '/')
         end;
$$;

grant select, insert, update, delete on storage.buckets, storage.objects to anon, authenticated, service_role;
