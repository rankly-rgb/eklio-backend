-- ============================================================================
-- scripts/comp_grant.sql — grant database-level comp access, by email
-- ============================================================================
-- NOT a migration: run by hand, against a Supabase DEV BRANCH, by someone
-- with direct database access. The email is a psql variable supplied on the
-- command line — it is never written into this file, into a migration, or
-- into any committed source.
--
--   psql "$DEV_DB_URL" \
--     -v comp_email="'someone@example.com'" \
--     -v comp_reason="'internal testing, finishing development'" \
--     -v comp_granted_by="'you@example.com'" \
--     -f scripts/comp_grant.sql
--
-- Fails loudly — raises, inserts nothing — if that email has no account in
-- auth.users. generation_credits is left at its column default (200);
-- expires_at is always now() + 90 days, so a forgotten grant does not become
-- permanent. Only one ACTIVE grant per user can exist at a time
-- (comp_grants_user_id_active_key) — granting an already-comp'd account
-- raises a unique-violation rather than silently doing nothing.
--
-- To flip the account back to the locked state and test the paywall, use the
-- REVOKE block at the bottom of this file — separately, on purpose (see its
-- own header). This top block only ever grants.
-- ============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_email      text := :'comp_email';
  v_reason     text := :'comp_reason';
  v_granted_by text := :'comp_granted_by';
  v_user_id    uuid;
begin
  select id into v_user_id from auth.users where email = v_email;
  if v_user_id is null then
    raise exception 'comp_grant: no account with email % — nothing granted.', v_email;
  end if;

  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values (v_user_id, v_reason, v_granted_by, now() + interval '90 days');

  raise notice 'comp_grant: granted % (user_id %), expiring %.',
    v_email, v_user_id, now() + interval '90 days';
end
$$;


-- ============================================================================
-- REVOKE — a separate, clearly-labelled snippet. NOT run by the block above.
-- ============================================================================
-- Flips the account back to the locked state, so the paywall can be tested
-- against it. Same invocation shape, only comp_email is needed:
--
--   psql "$DEV_DB_URL" -v comp_email="'someone@example.com'" -f scripts/comp_grant.sql
--
-- but this file's GRANT block runs first and would grant again — so to
-- revoke, copy the block below into its own file (or `psql -c`) rather than
-- running this whole file. It stays commented out here so sourcing this file
-- top to bottom can never revoke by accident.
--
-- do $$
-- declare
--   v_email   text := :'comp_email';
--   v_user_id uuid;
-- begin
--   select id into v_user_id from auth.users where email = v_email;
--   if v_user_id is null then
--     raise exception 'comp_grant revoke: no account with email %.', v_email;
--   end if;
--
--   update public.comp_grants
--      set revoked_at = now()
--    where user_id = v_user_id
--      and revoked_at is null;
--
--   raise notice 'comp_grant: revoked any active grant for %.', v_email;
-- end
-- $$;
