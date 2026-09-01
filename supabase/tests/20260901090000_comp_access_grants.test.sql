-- ============================================================================
-- Tests — 20260901090000_comp_access_grants.sql
-- ============================================================================
-- comp_grants is service_role only: RLS enabled, no policy, and the default
-- privileges Supabase would otherwise hand anon/authenticated are revoked.
-- What has to hold:
--
--   * anon and authenticated cannot select, insert, or update a single row.
--   * expires_at cannot be NULL — the column constraint, not a convention.
--   * one ACTIVE (non-revoked) grant per user, enforced by the partial index.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('c0000001-0001-0001-0001-000000000001','comp-target@example.internal');

insert into public.comp_grants (user_id, reason, granted_by, expires_at)
values ('c0000001-0001-0001-0001-000000000001', 'internal testing', 'ops@example.internal',
        now() + interval '90 days');

-- ---------------------------------------------------------------------------
-- anon and authenticated: no read, no write, full stop
-- ---------------------------------------------------------------------------
do $$
declare ok boolean; n int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"c0000001-0001-0001-0001-000000000001"}';

  assert (select count(*) from public.comp_grants) = 0,
         'authenticated could read comp_grants, even her own row';

  ok := false;
  begin
    insert into public.comp_grants (user_id, reason, granted_by, expires_at)
    values ('c0000001-0001-0001-0001-000000000001', 'self-grant', 'me', now() + interval '1 day');
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'authenticated inserted a comp grant';

  ok := false; n := -1;
  begin
    update public.comp_grants set generation_credits = 999999;
    get diagnostics n = row_count; ok := (n = 0);
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'authenticated updated a comp grant';

  reset role;
  set local role anon;

  assert (select count(*) from public.comp_grants) = 0, 'anon could read comp_grants';

  ok := false;
  begin
    insert into public.comp_grants (user_id, reason, granted_by, expires_at)
    values ('c0000001-0001-0001-0001-000000000001', 'anon-grant', 'me', now() + interval '1 day');
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'anon inserted a comp grant';

  reset role;
  assert (select count(*) from public.comp_grants) = 1,
         'the fixture row did not survive the write attempts (it should: they all failed)';
end
$$;

-- ---------------------------------------------------------------------------
-- expires_at cannot be NULL
-- ---------------------------------------------------------------------------
do $$
declare ok boolean := false;
begin
  begin
    insert into public.comp_grants (user_id, reason, granted_by, expires_at)
    values ('c0000001-0001-0001-0001-000000000001', 'no expiry', 'ops', null);
  exception when not_null_violation then ok := true; end;
  assert ok, 'a NULL expires_at was accepted';
end
$$;

-- ---------------------------------------------------------------------------
-- only one ACTIVE grant per user; a revoked one does not block a new one
-- ---------------------------------------------------------------------------
do $$
declare ok boolean := false;
begin
  begin
    insert into public.comp_grants (user_id, reason, granted_by, expires_at)
    values ('c0000001-0001-0001-0001-000000000001', 'second active grant', 'ops',
            now() + interval '30 days');
  exception when unique_violation then ok := true; end;
  assert ok, 'a second active grant for the same user was accepted';

  update public.comp_grants set revoked_at = now()
   where user_id = 'c0000001-0001-0001-0001-000000000001' and revoked_at is null;

  -- revoking the first frees the slot for a new one
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values ('c0000001-0001-0001-0001-000000000001', 're-granted after revoke', 'ops',
          now() + interval '30 days');

  assert (select count(*) from public.comp_grants
           where user_id = 'c0000001-0001-0001-0001-000000000001' and revoked_at is null) = 1,
         'revoking and re-granting did not leave exactly one active row';
  assert (select count(*) from public.comp_grants
           where user_id = 'c0000001-0001-0001-0001-000000000001') = 2,
         'the revoked grant did not stay in the table as history';
end
$$;

rollback;
