-- ============================================================================
-- usp_fingerprints — the collision-detection store
-- ============================================================================
-- `pg_trgm` is not enabled anywhere in this repo today (confirmed: no
-- `create extension` statement exists in any prior migration, and the base
-- reference migration's header states only Supabase's own defaults —
-- pgcrypto, uuid-ossp, pg_stat_statements, supabase_vault — are installed).
-- This is the first migration in the repo to add an application extension.

create extension if not exists pg_trgm;

-- ============================================================================
-- 1. usp_normalize — stable, immutable text normalization for comparison
-- ============================================================================
-- Lowercase, strip punctuation and digits, collapse whitespace, drop
-- stopwords (English + the therapy-domain words in `usp_stopwords`), and
-- return what's left SPACE-JOINED IN ORIGINAL ORDER. Order is kept on
-- purpose — the brief is explicit that the same words in a different
-- structure are a different statement, so this is not a bag-of-words
-- normalizer.
--
-- Modeled on `truncate_on_word_boundary` (`20260827101000_...`), the only
-- prior art in this repo for a small, single-purpose, IMMUTABLE text
-- function with a locked search_path.

create or replace function public.usp_normalize(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    (
      select string_agg(tok.word, ' ' order by tok.ord)
      from (
        select
          row_number() over () as ord,
          w as word
        from regexp_split_to_table(
               trim(regexp_replace(
                 regexp_replace(lower(p_text), '[^a-z\s]', ' ', 'g'),
                 '\s+', ' ', 'g'
               )),
               ' '
             ) as w
        where w <> ''
      ) as tok
      where not exists (
        select 1 from public.usp_stopwords sw where sw.word = tok.word
      )
    ),
    ''
  )
$$;

-- ============================================================================
-- 2. usp_fingerprints
-- ============================================================================
-- A row is written ONLY when a USP is confirmed (`usp-confirm`, Phase 2) —
-- never for a discarded candidate. `scope_key` is
-- `lower(specialty_id) || ':' || lower(coalesce(state, 'us'))`: a brief with
-- no state falls into the national `:us` bucket, the strictest scope (most
-- rows to collide against), not the loosest.

create table if not exists public.usp_fingerprints (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references auth.users (id) on delete cascade,
  brief_id   uuid        not null references public.project_briefs (project_id) on delete cascade,
  scope_key  text        not null,
  statement  text        not null,
  normalized text        not null,
  created_at timestamptz not null default now()
);

create index if not exists usp_fingerprints_user_id_idx  on public.usp_fingerprints (user_id);
create index if not exists usp_fingerprints_brief_id_idx on public.usp_fingerprints (brief_id);
create index if not exists usp_fingerprints_scope_key_idx on public.usp_fingerprints (scope_key);
create index if not exists usp_fingerprints_normalized_trgm_idx
  on public.usp_fingerprints using gin (normalized gin_trgm_ops);

-- ============================================================================
-- 3. RLS — a user reads and inserts her OWN rows only
-- ============================================================================
-- No update/delete policy: a confirmed fingerprint is immutable history, not
-- an editable record (editing a USP after confirming writes a NEW row via a
-- fresh usp-confirm call, same convention as `stripe_events` never being
-- updated in place).

alter table public.usp_fingerprints enable row level security;

drop policy if exists "usp_fingerprints_select_own" on public.usp_fingerprints;
create policy "usp_fingerprints_select_own"
  on public.usp_fingerprints for select
  using (user_id = (select auth.uid()));

drop policy if exists "usp_fingerprints_insert_own" on public.usp_fingerprints;
create policy "usp_fingerprints_insert_own"
  on public.usp_fingerprints for insert
  with check (user_id = (select auth.uid()));

drop policy if exists "usp_fingerprints_update_denied" on public.usp_fingerprints;
create policy "usp_fingerprints_update_denied"
  on public.usp_fingerprints for update using (false);

drop policy if exists "usp_fingerprints_delete_denied" on public.usp_fingerprints;
create policy "usp_fingerprints_delete_denied"
  on public.usp_fingerprints for delete using (false);

-- DOWN
-- drop table if exists public.usp_fingerprints;
-- drop function if exists public.usp_normalize(text);
-- drop extension if exists pg_trgm;
