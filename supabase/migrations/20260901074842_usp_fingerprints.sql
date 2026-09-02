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
--
-- ⚠ AT MOST ONE ROW PER BRIEF. `brief_id` is UNIQUE. Without this, a
-- direct RPC call (the frontend rate limit does not protect this path --
-- see the grant note on `usp_fingerprint_confirm` below) lets an
-- authenticated caller invoke `usp_fingerprint_confirm` repeatedly on her
-- OWN brief and flood her specialty:state bucket with hundreds of
-- legitimate-looking, correctly-owned rows, making collision detection
-- useless for everyone else sharing that bucket -- a volume attack, not a
-- content-spoofing one, so the scope_key-derivation fix above does not
-- touch it. `usp_fingerprint_confirm` is an UPSERT on this key: confirming
-- an edited statement REPLACES her one row rather than adding another.

create table if not exists public.usp_fingerprints (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references auth.users (id) on delete cascade,
  brief_id   uuid        not null references public.project_briefs (project_id) on delete cascade,
  scope_key  text        not null,
  statement  text        not null,
  normalized text        not null,
  created_at timestamptz not null default now()
);

alter table public.usp_fingerprints drop constraint if exists usp_fingerprints_brief_id_key;
alter table public.usp_fingerprints add constraint usp_fingerprints_brief_id_key unique (brief_id);

create index if not exists usp_fingerprints_user_id_idx  on public.usp_fingerprints (user_id);
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
-- the brief's own specialty selections (by catalog `sort_order`, not array
-- position — see the function's own header) and `state` — never from a
-- caller-supplied value. `usp_fingerprint_confirm` is `service_role` only
-- (not `authenticated`) — see its own header for why.
--
-- No direct UPDATE/DELETE policy either — a client can never modify a row
-- in place through PostgREST. Re-confirming DOES change the row, but only
-- through `usp_fingerprint_confirm`'s own UPSERT (also SECURITY DEFINER,
-- so it bypasses these policies as its owner, same as the INSERT path
-- does): at most one row per brief, so editing a confirmed USP replaces
-- that one row rather than either leaving stale history or letting the
-- old and new statements collide as two separate fingerprints.

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
-- ⚠ THE PRIMARY SPECIALTY IS THE LOWEST `sort_order` IN THE `specialties`
-- CATALOG AMONG THOSE SELECTED — NOT `specialty_ids[1]`. `project_briefs`
-- has no dedicated `primary_specialty_id` column, and `specialty_ids` has
-- NO GUARANTEED ORDER: it is `text[] not null default '{}'`, written
-- verbatim by frontend autosave, with nothing in the schema constraining
-- insertion order or re-sorting it on write. An earlier version of this
-- function used `specialty_ids[1]`, reasoning from `palette_family_ids`
-- (index 0 IS documented as "leading" there) — but `palette_family_ids`
-- and `specialty_ids` are not the same kind of array, and nothing
-- documents `specialty_ids` as order-meaningful. Deriving scope from
-- array position would mean reordering her own selections (deselecting
-- and reselecting a specialty checkbox, or any future UI change to how
-- the array is written) silently moves her USP into a different bucket
-- and dodges collision detection entirely, undetectably. Deterministic
-- against the CATALOG's own `sort_order` instead: the array's order
-- cannot affect the result, only its membership can.
--
-- ⚠ `service_role` ONLY — NOT `authenticated`. An earlier version granted
-- `authenticated` and checked ownership internally against `auth.uid()`.
-- That grant had no remaining use once FRONTEND_CONTRACT.md's Phase 2 note
-- settled on calling all three USP RPCs (this one included) from the route
-- handler with the service-role key: a client-callable write path that
-- nothing in the intended architecture actually calls is pure attack
-- surface, kept alive for no reason. Revoked. Ownership is now the route
-- handler's job ENTIRELY — it must verify from the user's own JWT that she
-- owns `p_brief_id` BEFORE calling this with the service-role key (see
-- FRONTEND_CONTRACT.md §9.6). This function trusts its caller completely,
-- the same as `seed_site_spec` (`20260829100000_site_spec.sql`) trusts
-- its: it resolves the brief's actual owner from the FK chain rather than
-- taking one as an argument, so there is no id through which a foreign
-- owner could be smuggled in, but it does NOT itself re-verify that the
-- call is legitimate — the grant (`service_role` only, never reaching the
-- browser) is what makes that safe, not an internal check.

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
  select p.user_id, pb.state
  into v_user_id, v_state
  from public.project_briefs pb
  join public.projects p on p.id = pb.project_id
  where pb.project_id = p_brief_id;

  if v_user_id is null then
    raise exception 'usp_fingerprint_confirm: brief % does not exist', p_brief_id;
  end if;

  select s.id into v_specialty
  from public.project_briefs pb
  join public.specialties s on s.id = any(pb.specialty_ids)
  where pb.project_id = p_brief_id
  order by s.sort_order
  limit 1;

  if v_specialty is null then
    raise exception 'usp_fingerprint_confirm: brief % has no primary specialty to scope against', p_brief_id;
  end if;

  v_scope_key := lower(v_specialty) || ':' || lower(coalesce(v_state, 'us'));

  insert into public.usp_fingerprints (user_id, brief_id, scope_key, statement, normalized, created_at)
  values (v_user_id, p_brief_id, v_scope_key, p_statement, public.usp_normalize(p_statement), now())
  on conflict (brief_id) do update set
    user_id    = excluded.user_id,
    scope_key  = excluded.scope_key,
    statement  = excluded.statement,
    normalized = excluded.normalized,
    created_at = excluded.created_at
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.usp_fingerprint_confirm(uuid, text) from public, anon, authenticated;
grant execute on function public.usp_fingerprint_confirm(uuid, text) to service_role;

-- DOWN
-- revoke all on function public.usp_fingerprint_confirm(uuid, text) from service_role;
-- drop function if exists public.usp_fingerprint_confirm(uuid, text);
-- drop table if exists public.usp_fingerprints;
-- drop function if exists public.usp_normalize(text);
-- drop extension if exists pg_trgm;
