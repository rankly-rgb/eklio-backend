-- ============================================================================
-- The caller I forgot to enumerate was the database itself
-- ============================================================================
-- ⚠ A CORRECTION TO 20260911170458, AND IT IS THE SAME BUG THAT MIGRATION
-- CONGRATULATES ITSELF FOR CATCHING.
--
-- That migration moved the authority check inside three function bodies and
-- gated each on `auth.role() = 'service_role' or <owns the row>`. It was
-- written after catching a near-miss where `brand_kit_is_owned` would have
-- returned 'generic' instead of a real builder target, and its own comment
-- says the lesson: ASK WHO CALLS IT AND WITH WHAT IDENTITY.
--
-- I asked, and I enumerated three callers: the server, the owner, the
-- anonymous token holder. There is a fourth, and it has no identity at all:
-- **a direct database connection** — a migration, a backfill, `psql`, a cron
-- job. For that caller `auth.role()` is null, `auth.uid()` is null, every
-- branch of the gate is false, and the function returns its FALLBACK. Not an
-- error. A plausible value.
--
-- Measured against production, before and after:
--
--   no jwt        site_spec_default_target = 'generic'      ← wrong
--   service_role  site_spec_default_target = 'squarespace'
--   owner         site_spec_default_target = 'squarespace'
--   stranger      site_spec_default_target = 'generic'      ← correct
--
-- No production path is currently affected: the browser always carries a JWT
-- and the server always uses the service role. What was affected is every
-- future data migration, every cron job, and — visibly — four test files,
-- which is how it surfaced at all. It surfaced only because the CI replay was
-- unblocked the same day; before that, nothing could have told anyone.
--
-- ── WHY WIDENING THIS GATE GIVES NOTHING AWAY ──────────────────────────────
--
-- Because anyone holding a direct connection already outranks these functions.
-- They can read the tables the functions read. The gate exists to constrain
-- PostgREST callers — people arriving over HTTP with a key — and a request
-- that set no JWT and no headers is not one of those: PostgREST sets both on
-- every request it serves, which is exactly how `anon_token_hash()` reads
-- `x-anon-token`. `anon_token_hash()` already reasons this way in its own
-- body ("No request context at all (psql, a migration, a cron): no token").
-- This names that condition instead of leaving each function to rediscover it.
-- ============================================================================

create or replace function public.caller_is_the_database()
returns boolean
language sql
stable
as $function$
  /*
   * BOTH, not either. PostgREST sets `request.jwt.claims` and
   * `request.headers` on every request it serves; a client cannot suppress
   * them, and a request with no key never reaches SQL at all. Requiring both
   * to be absent means a future change to how one of them is populated cannot
   * quietly turn a browser into "the database".
   */
  select nullif(current_setting('request.jwt.claims', true), '') is null
     and nullif(current_setting('request.headers', true), '')   is null;
$function$;

comment on function public.caller_is_the_database() is
  'True only when there is no PostgREST request context at all: a migration, a backfill, psql, a cron job. Such a caller already outranks any SECURITY DEFINER function, so treating it as trusted concedes nothing.';

revoke execute on function public.caller_is_the_database() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. purchase_status_before
-- ---------------------------------------------------------------------------
create or replace function public.purchase_status_before(
  p_purchase_id uuid,
  p_status      text
)
returns text
language sql
stable
security definer
set search_path = ''
as $function$
  select e.previous_status
    from public.purchase_status_events e
   where e.purchase_id = p_purchase_id
     and e.new_status = p_status
     /*
      * ⚠ STILL FOLDED INTO THE PREDICATE, NOT RAISED ABOVE IT. A raise would
      * tell a caller that the uuid exists, which is the one bit she did not
      * have. Null means "no such purchase" and "not yours" alike.
      */
     and (
       public.caller_is_the_database()
       or auth.role() = 'service_role'
       or exists (
         select 1 from public.purchases pu
          where pu.id = e.purchase_id
            and pu.user_id = (select auth.uid())
       )
     )
   order by e.occurred_at desc, e.created_at desc
   limit 1
$function$;

-- ---------------------------------------------------------------------------
-- 2. site_spec_default_target
-- ---------------------------------------------------------------------------
-- Reached through handle_new_brand_kit → seed_site_spec → site_spec_seed_values
-- on every generation. `owns_project` (not `brand_kit_is_owned`) because it
-- honours the anonymous token; `caller_is_the_database()` because the trigger
-- chain also runs with no request context at all during a replay or a backfill.
create or replace function public.site_spec_default_target(p_brand_kit_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    (select pb.builder_target_id
       from public.brand_kits bk
       join public.project_briefs pb on pb.project_id = bk.project_id
      where bk.id = p_brand_kit_id
        and (public.caller_is_the_database()
             or auth.role() = 'service_role'
             or public.owns_project(bk.project_id))),
    (select bk.site_prompt_target from public.brand_kits bk
      where bk.id = p_brand_kit_id
        and (public.caller_is_the_database()
             or auth.role() = 'service_role'
             or public.owns_project(bk.project_id))),
    'generic')
$function$;

-- ---------------------------------------------------------------------------
-- 3. brand_images_setting_int
-- ---------------------------------------------------------------------------
create or replace function public.brand_images_setting_int(
  p_key      text,
  p_fallback integer
)
returns integer
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    (select (s.value)::integer
       from public.app_settings s
      where s.key = p_key
        and (public.caller_is_the_database()
             or auth.role() = 'service_role'
             or p_key like 'brand\_images\_%')),
    p_fallback)
$function$;

-- ============================================================================
-- Guard rails — the four callers, named, each asserted
-- ============================================================================
do $$
declare
  v_kit     uuid := gen_random_uuid();
  v_project uuid := gen_random_uuid();
  v_user    uuid := gen_random_uuid();
  v_org     uuid;
  v_target  text;
begin
  -- A caller with no request context is the database, and is trusted.
  assert public.caller_is_the_database(),
    'this migration runs with no request context, so caller_is_the_database() must be true here';

  insert into auth.users (id, email) values (v_user, 'guard-rail-' || v_user || '@example.invalid');
  select m.organization_id into v_org
    from public.organization_members m where m.user_id = v_user and m.role = 'owner';
  insert into public.projects (id, user_id, name) values (v_project, v_user, 'authority guard rail');
  insert into public.project_briefs (project_id, builder_target_id) values (v_project, 'squarespace');
  insert into public.brand_kits (id, project_id) values (v_kit, v_project);

  -- 1. No identity at all — the case this migration exists for.
  v_target := public.site_spec_default_target(v_kit);
  assert v_target = 'squarespace',
    format('a caller with no request context got %L instead of the real builder target', v_target);

  -- 2. A stranger must still be refused. Widening the gate must not open it.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', gen_random_uuid())::text, true);
  perform set_config('request.headers', '{}', true);
  v_target := public.site_spec_default_target(v_kit);
  assert not public.caller_is_the_database(),
    'a request that carries jwt claims is not the database';
  assert v_target = 'generic',
    format('⚠ A STRANGER READ THE BUILDER TARGET: got %L', v_target);

  -- 3. An anonymous caller holding no token must also be refused.
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  v_target := public.site_spec_default_target(v_kit);
  assert v_target = 'generic',
    format('⚠ AN ANONYMOUS CALLER WITH NO TOKEN READ THE BUILDER TARGET: got %L', v_target);

  -- 4. The server.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  v_target := public.site_spec_default_target(v_kit);
  assert v_target = 'squarespace',
    format('the service role got %L instead of the real builder target', v_target);

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);

  /*
   * ⚠ CLEAN UP, AND MIND THE ORGANIZATION. Deleting the auth user cascades to
   * profiles, projects, brand kits and the membership row — but NOT to the
   * organization itself, which nothing points at any more. The first run of
   * this guard rail against production left exactly one such orphan behind,
   * and it had to be swept by hand. Delete it here.
   *
   * That an organization survives its last member is a real gap, recorded
   * rather than fixed in this migration: whether a practice should disappear
   * with its owner is a decision, not a cascade rule to add in passing.
   */
  delete from auth.users where id = v_user;
  delete from public.organizations where id = v_org;

  assert not exists (select 1 from public.projects where id = v_project),
    'the guard rail left its fixture project behind';
  assert not exists (select 1 from public.organizations where id = v_org),
    'the guard rail left its fixture organization behind';
end
$$;
