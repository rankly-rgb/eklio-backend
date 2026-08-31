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
-- 3. RLS — a user reads her OWN rows only. INSERT IS NOT GRANTED DIRECTLY.
-- ============================================================================
-- ⚠ `scope_key` is what every OTHER user's collision check is measured
-- against. If a direct client INSERT were allowed (even scoped to
-- `user_id = auth.uid()`, which only constrains WHOSE row it is, not what
-- the row SAYS), any authenticated caller could write an arbitrary
-- `scope_key` — a text column with no FK, no CHECK, nothing tying it to her
-- own brief — and poison collision detection for every other practitioner
-- in that specialty:state bucket with garbage or hostile statements. This
-- is a real hole, not a theoretical one: RLS's `WITH CHECK` only ever
-- proves row OWNERSHIP, never row CONTENT correctness.
--
-- So `INSERT` is denied outright (policy + revoked privilege, matching the
-- `stripe_events` "RLS + no policy + revoked privileges" belt-and-suspenders
-- pattern), and the only sanctioned write path is
-- `usp_fingerprint_confirm()` below, which DERIVES `scope_key` itself from
-- the brief's own stored `specialty_ids[1]` / `state` — never from a
-- caller-supplied value — after confirming the caller owns that brief.
--
-- No update/delete policy either: a confirmed fingerprint is immutable
-- history (editing a USP after confirming writes a NEW row via a fresh
-- confirm call), same convention as `stripe_events` never being updated in
-- place.

alter table public.usp_fingerprints enable row level security;

drop policy if exists "usp_fingerprints_select_own" on public.usp_fingerprints;
create policy "usp_fingerprints_select_own"
  on public.usp_fingerprints for select
  using (user_id = (select auth.uid()));

drop policy if exists "usp_fingerprints_insert_own" on public.usp_fingerprints;
drop policy if exists "usp_fingerprints_insert_denied" on public.usp_fingerprints;
create policy "usp_fingerprints_insert_denied"
  on public.usp_fingerprints for insert with check (false);

drop policy if exists "usp_fingerprints_update_denied" on public.usp_fingerprints;
create policy "usp_fingerprints_update_denied"
  on public.usp_fingerprints for update using (false);

drop policy if exists "usp_fingerprints_delete_denied" on public.usp_fingerprints;
create policy "usp_fingerprints_delete_denied"
  on public.usp_fingerprints for delete using (false);

-- Second, independent barrier: even if a policy were added by inadvertence
-- later, a direct INSERT still needs table-level privilege, which ordinary
-- clients do not have. `usp_fingerprint_confirm` below is SECURITY DEFINER,
-- so it writes as its owner regardless of this revoke.
revoke insert on table public.usp_fingerprints from authenticated;

-- ============================================================================
-- 4. usp_fingerprint_confirm — the ONLY sanctioned write path
-- ============================================================================
-- SECURITY DEFINER for two reasons, both load-bearing: it writes to a table
-- `authenticated` has no INSERT privilege on at all (see above), and it
-- must resolve the brief's specialty/state through project_briefs on the
-- caller's behalf to derive `scope_key` itself — a value the caller never
-- gets to supply. `p_scope_key` is deliberately NOT a parameter.
--
-- `specialty_ids[1]` is this brief's PRIMARY specialty: `project_briefs`
-- has no dedicated `primary_specialty_id` column (specialties are a plain
-- array), and the existing convention for "which array element leads" is
-- `palette_family_ids` index 0 = leading (`20260827101000_...`) — here,
-- Postgres arrays are 1-indexed, so `specialty_ids[1]` is that same
-- convention applied to this array.
--
-- Ownership is checked explicitly rather than left to RLS, because this
-- function runs as its owner (bypassing RLS by construction as SECURITY
-- DEFINER) — the ownership check here IS the access control, not a
-- redundant belt-and-suspenders on top of a policy.

create or replace function public.usp_fingerprint_confirm(
  p_brief_id  uuid,
  p_statement text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id    uuid;
  v_specialty  text;
  v_state      text;
  v_scope_key  text;
  v_id         uuid;
begin
  select p.user_id, pb.specialty_ids[1], pb.state
  into v_user_id, v_specialty, v_state
  from public.project_briefs pb
  join public.projects p on p.id = pb.project_id
  where pb.project_id = p_brief_id;

  -- `IS DISTINCT FROM`, not `<>`: for an unauthenticated (`anon`) caller,
  -- `auth.uid()` is NULL, and `v_user_id <> NULL` evaluates to NULL, which
  -- `IF NULL THEN raise exception` treats as FALSE -- silently skipping the
  -- ownership check and letting the row be written anyway. `IS DISTINCT
  -- FROM` is NULL-safe: NULL is treated as a real, distinct value, so a
  -- NULL `auth.uid()` correctly fails this check instead of bypassing it.
  if v_user_id is null or v_user_id is distinct from (select auth.uid()) then
    raise exception 'usp_fingerprint_confirm: brief % is not owned by the caller', p_brief_id;
  end if;

  if v_specialty is null then
    raise exception 'usp_fingerprint_confirm: brief % has no primary specialty to scope against', p_brief_id;
  end if;

  v_scope_key := lower(v_specialty) || ':' || lower(coalesce(v_state, 'us'));

  insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized)
  values (v_user_id, p_brief_id, v_scope_key, p_statement, public.usp_normalize(p_statement))
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.usp_fingerprint_confirm(uuid, text) from public, anon;
grant execute on function public.usp_fingerprint_confirm(uuid, text) to authenticated, service_role;

-- DOWN
-- revoke all on function public.usp_fingerprint_confirm(uuid, text) from authenticated, service_role;
-- drop function if exists public.usp_fingerprint_confirm(uuid, text);
-- drop table if exists public.usp_fingerprints;
-- drop function if exists public.usp_normalize(text);
-- drop extension if exists pg_trgm;
