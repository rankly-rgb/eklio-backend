-- ============================================================================
-- Eklio — the authority check moves inside the function body
-- ============================================================================
-- On 2 September, 20260902090000 revoked EXECUTE on eighteen functions and
-- carried a guard rail that raises if `anon` still holds it. It applied. The
-- guard passed. Today seventeen of the eighteen have their grants back,
-- PUBLIC included, and none of them was recreated by a later migration.
--
-- ── WHAT WAS TESTED, AND WHAT IS STILL UNKNOWN ─────────────────────────────
--
-- Two mechanisms were proposed and BOTH ARE DISPROVED:
--
--   * "a blanket platform re-grant" — a blanket grant would have re-opened the
--     revokes written on 3, 5, 6, 9, 10 and 11 September too. Those all hold.
--     Measured, function by function.
--   * "the migration tooling re-grants after applying" — see
--     20260911170021, which revoked one function and read the ACL back on a
--     later connection. The revoke was intact.
--
-- Nothing is re-granting continuously. What remains is a discrete past event
-- around 2-3 September that restored ACL state to a point before that
-- migration ran, while the migration ledger moved forward. Consistent with
-- every observation -- functions created AFTER it keep their revokes, and the
-- single function of the eighteen that a LATER migration re-revoked
-- (seed_launch_checklist, on 3 September) is the single one still closed --
-- but it cannot be proved from inside the database, and this file does not
-- pretend to have proved it.
--
-- ⚠ THE CONCLUSION DOES NOT DEPEND ON NAMING THE CAUSE. A REVOKE is a fact
-- about a moment. An authority check inside the body is a fact about the
-- function. Only the second survives an event nobody can reproduce, so the
-- second is what this migration installs. The REVOKEs below are a second lock,
-- not the lock.
-- ============================================================================


-- ============================================================================
-- 1. `purchase_status_before` — a read of anyone's purchase history
-- ============================================================================
-- Returns the status a purchase held before it entered a given status. The
-- Stripe webhook calls it to resolve a won dispute; it has NO other caller, in
-- the database or the application. Until now any browser holding the anon key
-- could read any purchase's history given its uuid.
--
-- The rule, and it is the shape every check below uses: THE SERVER IS THE
-- SERVER, AND EVERYONE ELSE MUST OWN THE ROW. `auth.role()` is the JWT's role
-- claim and survives entry into a SECURITY DEFINER body, where `current_user`
-- has already become the owner and is useless for this.
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
      * ⚠ FOLDED INTO THE PREDICATE, NOT RAISED ABOVE IT. A raise would tell a
      * caller that the uuid exists, which is the one bit she did not have.
      * This returns null for "no such purchase" and for "not yours" alike.
      */
     and (
       auth.role() = 'service_role'
       or exists (
         select 1 from public.purchases pu
          where pu.id = e.purchase_id
            and pu.user_id = (select auth.uid())
       )
     )
   order by e.occurred_at desc, e.created_at desc
   limit 1
$function$;


-- ============================================================================
-- 2. `site_spec_default_target` — a read of any kit's builder target
-- ============================================================================
-- ⚠ `owns_project`, NOT `brand_kit_is_owned`, AND THE DIFFERENCE IS A BUG THIS
-- FILE ALMOST SHIPPED. The first honours the anonymous token; the second is
-- `auth.uid()`-only. This function is reached through
-- handle_new_brand_kit → seed_site_spec → site_spec_seed_values on EVERY
-- anonymous generation, so the auth.uid()-only predicate would have returned
-- 'generic' instead of her real builder target -- silently, with a plausible
-- value, on the one path this product spent a week opening. Caught before the
-- commit by asking who calls it, not by a test.
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
        and (auth.role() = 'service_role' or public.owns_project(bk.project_id))),
    (select bk.site_prompt_target
       from public.brand_kits bk
      where bk.id = p_brand_kit_id
        and (auth.role() = 'service_role' or public.owns_project(bk.project_id))),
    'generic'
  )
$function$;


-- ============================================================================
-- 3. `brand_images_setting_int` — a read of ANY app_settings key
-- ============================================================================
-- `app_settings` is a table with RLS on and no policy: server-only in effect.
-- This function read any key out of it as an integer, for anyone. The spend
-- ceilings live in that table.
--
-- ⚠ A DISALLOWED KEY RETURNS THE FALLBACK RATHER THAN RAISING. Its only caller
-- is `brand_images_claim`, which is gated and reads `brand_images_*` keys; a
-- key outside the prefix now behaves exactly as a key that does not exist,
-- which is a shape every caller already handles. A raise would have been a new
-- failure mode introduced by a security fix.
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
    (select (value #>> '{}')::integer
       from public.app_settings
      where key = p_key
        and (auth.role() = 'service_role' or p_key like 'brand\_images\_%')),
    p_fallback)
$function$;


-- ============================================================================
-- 4. The second lock: revoke what the browser has no business calling
-- ============================================================================
-- Knowing it can drift again, and that the checks above are what actually
-- hold. `authenticated` keeps EXECUTE where the application calls the function
-- with a session client -- revoking those would break the product, and a
-- security change that breaks the product gets reverted, which secures
-- nothing.
--
-- ⚠ ENUMERATED, NOT LISTED. The 2 September migration named its eighteen by
-- hand, and the first attempt at this file did the same and missed five
-- (`maintain_site_spec_text_variants`, `retire_seed_clamp_notes`,
-- `purchase_status_events_append_only`,
-- `enforce_direction_selection_entitlement`, `site_specs_set_color_labels`) --
-- its own guard rail caught them. A hand-kept list of what to close is a list
-- that goes stale; the loop cannot.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end
$$;

revoke execute on function public.purchase_status_before(uuid, text)   from public, anon, authenticated;
revoke execute on function public.site_spec_default_target(uuid)       from public, anon, authenticated;
revoke execute on function public.brand_images_setting_int(text, int)  from public, anon, authenticated;
revoke execute on function public.brand_images_enabled()               from public, anon, authenticated;
revoke execute on function public.complete_choose_direction(uuid)      from public, anon, authenticated;
revoke execute on function public.seed_site_spec(uuid)                 from public, anon, authenticated;

grant execute on function public.purchase_status_before(uuid, text)  to service_role;
grant execute on function public.site_spec_default_target(uuid)      to service_role;
grant execute on function public.brand_images_setting_int(text, int) to service_role;
grant execute on function public.brand_images_enabled()              to service_role;

-- ⚠ `anon_token_hash()` IS DELIBERATELY LEFT CALLABLE BY `anon`, and this is
-- the one exception in the file. The RLS policies on `projects` call it, and a
-- policy executes as the CALLER's role -- revoking it would lock every
-- anonymous visitor out of her own brief. It reads a request header and
-- returns a hash; it grants nothing and reveals nothing.


-- ============================================================================
-- 5. Stop new functions being born public
-- ============================================================================
-- ⚠ HALF THE FIX, DELIBERATELY. This removes the PUBLIC grant that PostgreSQL
-- gives every new function. It does NOT touch Supabase's explicit grants to
-- `anon` and `authenticated`: revoking those by default would make the next
-- RPC someone writes fail with "permission denied" at runtime instead of
-- failing in CI, and a defence that teaches people to add blanket grants is
-- worse than no defence. The CI check
-- (supabase/tests/20260911170458_function_surface.test.sql) catches the other
-- half, before deploy rather than after.
alter default privileges in schema public revoke execute on functions from public;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare v_n integer; v_leaked text;
begin
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname in ('purchase_status_before','site_spec_default_target','brand_images_setting_int');
  if v_n <> 3 then
    raise exception 'authority: % of 3 rewritten functions present', v_n;
  end if;

  -- ⚠ EACH ONE NOW NAMES auth.role(). Without this the migration could have
  -- replaced a body with one that compiles and checks nothing.
  select string_agg(p.proname, ', ') into v_leaked
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname in ('purchase_status_before','site_spec_default_target','brand_images_setting_int')
     and pg_get_functiondef(p.oid) not like '%auth.role()%';
  if v_leaked is not null then
    raise exception 'authority: % has no in-body check', v_leaked;
  end if;

  -- The one that honours the anonymous token must keep honouring it.
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='site_spec_default_target') not like '%owns_project%' then
    raise exception 'authority: site_spec_default_target must resolve through owns_project, which honours the anonymous token';
  end if;

  -- The settings reader refuses a key outside its prefix, proven not asserted.
  if public.brand_images_setting_int('anon_generation_daily_global', -1) <> -1 then
    raise exception 'authority: brand_images_setting_int still reads a foreign key';
  end if;
  if public.brand_images_setting_int('brand_images_daily_cap_cents', -1) = -1 then
    raise exception 'authority: brand_images_setting_int stopped reading its own keys';
  end if;

  -- No trigger function is reachable from the anonymous surface any more.
  select string_agg(p.proname, ', ') into v_leaked
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
     and has_function_privilege('anon', p.oid, 'execute');
  if v_leaked is not null then
    raise exception 'authority: trigger functions still callable by anon: %', v_leaked;
  end if;

  -- And the one deliberate exception is still there, because locking it would
  -- lock every anonymous visitor out of her own brief.
  if not has_function_privilege('anon', 'public.anon_token_hash()'::regprocedure, 'execute') then
    raise exception 'authority: anon_token_hash was revoked -- the RLS policies on projects call it as anon';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   Restore the three function bodies from their previous migrations
--   (20260830060424 for purchase_status_before, 20260830060712 for
--   site_spec_default_target, 20260905194933 for brand_images_setting_int),
--   re-grant EXECUTE where it was, and
--   alter default privileges in schema public grant execute on functions to public;
