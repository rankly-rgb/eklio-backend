-- ============================================================================
-- Eklio — the brief runs without an account
-- ============================================================================
-- Four chantiers said "do not touch anything before the payment". That guard
-- has expired: cold email to US therapists starts in October, and the
-- acquisition walk found that the first click demands an email address and a
-- password before a stranger has received anything at all.
--
-- So a brief can now belong to a TOKEN instead of a user. The account is
-- created at the moment she wants to keep what she is already looking at, and
-- signing up CLAIMS the anonymous brief rather than starting a new one.
--
-- ⚠ THE POLICIES ARE IN THIS MIGRATION, NOT THE NEXT ONE. In this repo a table
-- without policies returns zero rows and raises nothing: the feature would
-- look broken rather than open, which is the failure that takes longest to
-- diagnose and, in the other direction, the one that leaks. Nothing here ships
-- half-guarded.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. The owner becomes optional, and something must still own the row
-- ---------------------------------------------------------------------------
alter table public.projects
  alter column user_id drop not null;

-- The SHA-256 of the token, hex. NEVER the token itself: this column is read
-- by every policy below and appears in any dump; a stolen dump must not hand
-- anyone a working session. The cookie carries the only copy of the plaintext.
alter table public.projects
  add column if not exists anon_token_hash text;

/*
 * When an unclaimed brief stops existing.
 *
 * ⚠ THIRTY DAYS, AND THE NUMBER IS A DECISION. Every bounced cold-email click
 * leaves an ownerless row here, and a table nobody planned to grow is exactly
 * the shape of the dead table this project spent two sessions killing.
 *
 * Thirty because it is already the answer to "how long does Eklio keep
 * something nobody claimed" — `purge-deleted-kits` uses the same window for
 * soft-deleted kits. One number is easier to reason about, easier to state in
 * a privacy notice, and harder to get wrong than two. It is also longer than
 * the cookie that points at the row (30 days), so the row never outlives the
 * only thing that can reach it by more than a rounding error.
 */
alter table public.projects
  add column if not exists anon_expires_at timestamptz;

alter table public.projects
  drop constraint if exists projects_owner_present_check;
alter table public.projects
  add constraint projects_owner_present_check
  check (user_id is not null or anon_token_hash is not null);

-- An anonymous row must carry its own expiry, or the purge cannot see it and
-- it becomes the row that lives forever.
alter table public.projects
  drop constraint if exists projects_anon_expiry_check;
alter table public.projects
  add constraint projects_anon_expiry_check
  check (anon_token_hash is null or anon_expires_at is not null);

-- Unique: a token addresses exactly one brief. Partial, because claimed rows
-- all have a null hash and null is not unique.
create unique index if not exists projects_anon_token_hash_key
  on public.projects (anon_token_hash) where anon_token_hash is not null;

-- The purge reads this, and only this.
create index if not exists projects_anon_expires_idx
  on public.projects (anon_expires_at) where user_id is null;

comment on column public.projects.anon_token_hash is
  'SHA-256 (hex) of the anonymous session token. Never the token. Null once the brief has been claimed by an account.';
comment on column public.projects.anon_expires_at is
  'When an unclaimed anonymous brief is purged -- 30 days, the same window purge-deleted-kits uses. Null once claimed.';


-- ---------------------------------------------------------------------------
-- 2. How a policy learns the token
-- ---------------------------------------------------------------------------
/*
 * The browser sends the plaintext token in `x-anon-token`; PostgREST exposes
 * the request headers as a GUC. This hashes it once so every policy compares
 * hashes and no policy ever handles the plaintext.
 *
 * ⚠ `stable`, NOT `immutable`: it reads a setting, which is constant within a
 * statement and not across them. Marked immutable it could be folded away and
 * a policy would compare against a stale value.
 *
 * ⚠ Returns null when the header is absent or empty, and null never equals
 * anything -- so a request with no token matches no row, rather than matching
 * every row whose hash is also null. That distinction is the whole security of
 * this design, and it is why the claimed rows carry NULL rather than ''.
 */
create or replace function public.anon_token_hash()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_raw text;
begin
  begin
    v_raw := nullif(
      current_setting('request.headers', true)::json ->> 'x-anon-token', '');
  exception when others then
    -- No request context at all (psql, a migration, a cron): no token.
    return null;
  end;

  if v_raw is null then
    return null;
  end if;

  -- A token is 43 base64url characters (32 random bytes). Anything else is
  -- not one of ours, and is refused before it reaches an index.
  if length(v_raw) < 20 or length(v_raw) > 200 then
    return null;
  end if;

  return encode(extensions.digest(v_raw, 'sha256'), 'hex');
end
$function$;

revoke execute on function public.anon_token_hash() from public;
grant execute on function public.anon_token_hash() to anon, authenticated, service_role;

comment on function public.anon_token_hash() is
  'SHA-256 of the x-anon-token request header, or null when absent/implausible. Null matches no row -- that is the security of the anonymous policies.';


-- ---------------------------------------------------------------------------
-- 3. The policies
-- ---------------------------------------------------------------------------
/*
 * ⚠ EACH ONE IS "MINE, OR MINE BY TOKEN" — never a second permissive policy
 * added beside the old one. Two permissive policies OR together, and a future
 * reader auditing one of them would be reading half the rule.
 *
 * An expired row stops being readable the moment it expires, before the purge
 * runs. The purge is housekeeping; the deadline is enforced here, so a cron
 * that fails to run cannot quietly extend anyone's access.
 */
create or replace function public.owns_project(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from public.projects p
     where p.id = p_project_id
       and (
         (p.user_id is not null and p.user_id = (select auth.uid()))
         or (p.anon_token_hash is not null
             and p.anon_token_hash = public.anon_token_hash()
             and p.anon_expires_at > now())
       )
  );
$function$;

revoke execute on function public.owns_project(uuid) from public;
grant execute on function public.owns_project(uuid) to anon, authenticated, service_role;

drop policy if exists "projects_select_own" on public.projects;
drop policy if exists "projects_insert_own" on public.projects;
drop policy if exists "projects_update_own" on public.projects;
drop policy if exists "projects_delete_own" on public.projects;

create policy "projects_select_own" on public.projects
  for select using (
    (user_id is not null and user_id = (select auth.uid()))
    or (anon_token_hash is not null
        and anon_token_hash = public.anon_token_hash()
        and anon_expires_at > now())
  );

/*
 * ⚠ AN ANONYMOUS ROW IS INSERTED BY THE SERVER, NEVER BY THE BROWSER.
 *
 * The browser cannot mint one: it would have to choose its own token hash, and
 * a client that chooses a hash can choose one it has already seen. Anonymous
 * briefs are created by the route handler with the service role, which is also
 * where the per-IP and global caps are checked. This policy therefore keeps
 * the ORIGINAL rule and nothing more.
 */
create policy "projects_insert_own" on public.projects
  for insert with check (user_id is not null and user_id = (select auth.uid()));

create policy "projects_update_own" on public.projects
  for update using (
    (user_id is not null and user_id = (select auth.uid()))
    or (anon_token_hash is not null
        and anon_token_hash = public.anon_token_hash()
        and anon_expires_at > now())
  )
  with check (
    /*
     * ⚠ SHE CANNOT CLAIM HER OWN BRIEF FROM THE BROWSER, and she cannot hand
     * it to anyone else. Claiming sets `user_id` and clears the hash, and it
     * happens server-side at signup. Letting a token holder write `user_id`
     * would let anyone with a token attach a stranger's brief to their own
     * account -- or worse, attach theirs to a stranger's.
     */
    (user_id is not null and user_id = (select auth.uid()))
    or (anon_token_hash is not null
        and anon_token_hash = public.anon_token_hash()
        and anon_expires_at > now()
        and user_id is null)
  );

create policy "projects_delete_own" on public.projects
  for delete using (user_id is not null and user_id = (select auth.uid()));

/* The child tables resolve through `owns_project`, so the rule lives once. */
drop policy if exists "project_briefs_select_own" on public.project_briefs;
drop policy if exists "project_briefs_insert_own" on public.project_briefs;
drop policy if exists "project_briefs_update_own" on public.project_briefs;
drop policy if exists "project_briefs_delete_own" on public.project_briefs;

create policy "project_briefs_select_own" on public.project_briefs
  for select using (public.owns_project(project_id));
create policy "project_briefs_insert_own" on public.project_briefs
  for insert with check (public.owns_project(project_id));
create policy "project_briefs_update_own" on public.project_briefs
  for update using (public.owns_project(project_id))
  with check (public.owns_project(project_id));
create policy "project_briefs_delete_own" on public.project_briefs
  for delete using (public.owns_project(project_id));

drop policy if exists "brand_kits_all_own" on public.brand_kits;
create policy "brand_kits_all_own" on public.brand_kits
  for all using (public.owns_project(project_id))
  with check (public.owns_project(project_id));


-- ---------------------------------------------------------------------------
-- 4. The spend caps, in app_settings so they move without a deploy
-- ---------------------------------------------------------------------------
insert into public.app_settings (key, value) values
  ('anon_generation_enabled',          'true'::jsonb),
  ('anon_generation_daily_per_ip',     '3'::jsonb),
  ('anon_generation_daily_global',     '150'::jsonb)
on conflict (key) do nothing;

/*
 * One row per (day, bucket). `bucket` is either a hashed IP or the literal
 * '@global' -- one table, one statement, and the global ceiling cannot drift
 * out of step with the per-IP one because they are counted the same way.
 *
 * ⚠ THE IP IS HASHED, WITH A DAILY SALT. A raw IP is personal data under GDPR
 * and this audience is reached from France; a hash salted with the date is
 * enough to count a repeat visitor within a day and useless for anything else
 * the day after.
 */
create table if not exists public.anon_generation_counters (
  day       date not null default (now() at time zone 'utc')::date,
  bucket    text not null,
  used      integer not null default 0,
  constraint anon_generation_counters_pkey primary key (day, bucket),
  constraint anon_generation_counters_used_check check (used >= 0)
);

alter table public.anon_generation_counters enable row level security;
-- Nobody but the server. There is nothing here for a browser to read.
drop policy if exists "anon_counters_denied" on public.anon_generation_counters;
create policy "anon_counters_denied" on public.anon_generation_counters
  for all using (false) with check (false);

comment on table public.anon_generation_counters is
  'Daily generation counts for anonymous briefs, per hashed IP and one @global row. Server-only; the browser has no policy here.';

/*
 * ── VERIFY THEN CONSUME, IN ONE STATEMENT ───────────────────────────────
 *
 * Both ceilings and the kill switch, checked and incremented together. Two
 * statements would let two concurrent requests both read "149 of 150" and both
 * proceed -- and a generation, once started, is money already spent.
 *
 * Returns the reason on refusal so the caller can say something true.
 */
create or replace function public.consume_anon_generation(p_ip_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_enabled  boolean;
  v_per_ip   integer;
  v_global   integer;
  v_day      date := (now() at time zone 'utc')::date;
  v_ok       boolean;
begin
  select (value #>> '{}')::boolean into v_enabled
    from public.app_settings where key = 'anon_generation_enabled';
  select (value #>> '{}')::integer into v_per_ip
    from public.app_settings where key = 'anon_generation_daily_per_ip';
  select (value #>> '{}')::integer into v_global
    from public.app_settings where key = 'anon_generation_daily_global';

  /*
   * ⚠ A MISSING OR UNREADABLE SETTING IS "NO", NEVER "UNLIMITED". Fail closed
   * is the standing rule everywhere money is involved, and a typo in a row
   * someone edits at seven in the morning must not open the tap.
   */
  if v_enabled is not true or v_per_ip is null or v_global is null then
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  -- The global ceiling first: it is the one that bounds the bill.
  insert into public.anon_generation_counters (day, bucket, used)
  values (v_day, '@global', 1)
  on conflict (day, bucket) do update
    set used = public.anon_generation_counters.used + 1
    where public.anon_generation_counters.used < v_global
  returning true into v_ok;

  if not coalesce(v_ok, false) then
    return jsonb_build_object('ok', false, 'reason', 'global_cap');
  end if;

  insert into public.anon_generation_counters (day, bucket, used)
  values (v_day, p_ip_hash, 1)
  on conflict (day, bucket) do update
    set used = public.anon_generation_counters.used + 1
    where public.anon_generation_counters.used < v_per_ip
  returning true into v_ok;

  if not coalesce(v_ok, false) then
    /*
     * ⚠ GIVE THE GLOBAL COUNT BACK. It was taken a moment ago for a generation
     * that is not going to happen, and leaving it spent would let one visitor
     * refreshing a page eat the day's ceiling for everyone else.
     */
    update public.anon_generation_counters
       set used = greatest(0, used - 1)
     where day = v_day and bucket = '@global';
    return jsonb_build_object('ok', false, 'reason', 'ip_cap');
  end if;

  return jsonb_build_object('ok', true);
end
$function$;

revoke execute on function public.consume_anon_generation(text) from public, anon, authenticated;
grant  execute on function public.consume_anon_generation(text) to service_role;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare v_n integer;
begin
  -- Every policy that guards a brief must know about the token, or the
  -- feature is open on one table and shut on another.
  select count(*) into v_n from pg_policies
   where schemaname='public' and tablename in ('project_briefs','brand_kits')
     and coalesce(qual,'') || coalesce(with_check,'') not like '%owns_project%';
  if v_n > 0 then
    raise exception 'anonymous briefs: % child policies do not resolve through owns_project', v_n;
  end if;

  -- The insert policy must NOT admit an anonymous row: a browser that picks
  -- its own token hash can pick one it has seen before.
  select count(*) into v_n from pg_policies
   where schemaname='public' and tablename='projects' and cmd='INSERT'
     and coalesce(with_check,'') like '%anon_token_hash%';
  if v_n > 0 then
    raise exception 'anonymous briefs: the browser can mint an anonymous project';
  end if;

  -- Fail closed: the three settings exist.
  select count(*) into v_n from public.app_settings
   where key in ('anon_generation_enabled','anon_generation_daily_per_ip','anon_generation_daily_global');
  if v_n <> 3 then
    raise exception 'anonymous briefs: % of 3 spend settings present', v_n;
  end if;

  -- An anonymous row without an expiry is the row that lives forever.
  if not exists (select 1 from pg_constraint where conname='projects_anon_expiry_check') then
    raise exception 'anonymous briefs: an anonymous project could have no expiry';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   Restore the four `*_own` policies from their original migrations,
--   drop public.owns_project, public.anon_token_hash,
--   public.consume_anon_generation, public.anon_generation_counters,
--   delete the three app_settings rows, drop the two indexes and the two
--   CHECKs, then: alter table public.projects
--     drop column anon_expires_at, drop column anon_token_hash,
--     alter column user_id set not null;
