-- ============================================================================
-- Tests — tenancy layer: backfill / signup-time organization creation
-- ============================================================================
-- The migrations' own DO block backfills whatever existed at push time; there
-- is nothing left to "backfill" inside a fresh test transaction. What this
-- file tests instead is the SHARED mechanism the backfill and every future
-- signup both go through — create_default_organization_for_user, called from
-- handle_new_user — which is the same code path, so proving it here proves
-- the backfill's own logic.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('a1111111-1111-1111-1111-111111111111', 'owner-one@example.com'),
  ('a2222222-2222-2222-2222-222222222222', 'owner-two@example.com');

-- ---------------------------------------------------------------------------
-- Signup created exactly one organization of one, per user
-- ---------------------------------------------------------------------------
do $$
declare
  n_org1   int;
  n_owner1 int;
  org1     uuid;
begin
  assert (select count(*) from public.profiles where id = 'a1111111-1111-1111-1111-111111111111') = 1,
         'signup did not create a profile';

  select count(*) into n_org1 from public.organizations where owner_user_id = 'a1111111-1111-1111-1111-111111111111';
  assert n_org1 = 1, format('owner-one has %s organizations, expected 1', n_org1);

  select o.id into org1 from public.organizations o where o.owner_user_id = 'a1111111-1111-1111-1111-111111111111';

  select count(*) into n_owner1
    from public.organization_members m
   where m.organization_id = org1 and m.role = 'owner' and m.status = 'active';
  assert n_owner1 = 1, format('organization %s has %s active owners, expected 1', org1, n_owner1);

  assert (select activated_at from public.organization_members
           where organization_id = org1 and user_id = 'a1111111-1111-1111-1111-111111111111') is not null,
         'the owner membership has no activated_at';

  assert (select slug from public.organizations where id = org1) ~ '^org-a1111111',
         'the slug was not derived from the user id';
end
$$;

-- ---------------------------------------------------------------------------
-- projects_set_default_organization: fills organization_id from the caller's
-- owned organization when the client omits it; never silently picks when
-- ambiguous or absent.
-- ---------------------------------------------------------------------------
do $$
declare
  org1 uuid;
  prj  uuid;
begin
  select id into org1 from public.organizations where owner_user_id = 'a1111111-1111-1111-1111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a1111111-1111-1111-1111-111111111111"}';

  insert into public.projects (id, user_id, name)
  values ('b1111111-1111-1111-1111-111111111111', 'a1111111-1111-1111-1111-111111111111', 'Backfill Test Project');

  assert (select organization_id from public.projects where id = 'b1111111-1111-1111-1111-111111111111') = org1,
         'projects_set_default_organization did not fill the owner''s organization';
end
$$;

-- ⚠ the trigger resolves via NEW.user_id, not auth.uid() (see the migration
-- comment: 24 of the 41 pre-existing test files insert public.projects as
-- postgres, with an explicit user_id and no request.jwt.claims set at all —
-- auth.uid() is NULL there by construction). This block proves the
-- service-role-style path (no claims, explicit user_id) works, and that a
-- user who owns no organization still gets a raise, never a silent pick.
do $$
declare ok boolean := false;
begin
  -- service-role-style insert, no claims at all: succeeds, because
  -- owner-one still owns exactly one organization.
  reset role;
  set local request.jwt.claims = '{}';
  insert into public.projects (id, user_id, name)
  values ('b2222222-2222-2222-2222-222222222222', 'a1111111-1111-1111-1111-111111111111', 'No Claims');
  assert (select organization_id from public.projects where id = 'b2222222-2222-2222-2222-222222222222') is not null,
         'a service-role-style insert with no claims did not resolve an organization';

  -- a user who owns no organization at all: raise, never silently pick
  update public.organization_members set status = 'removed', removed_at = now()
   where user_id = 'a2222222-2222-2222-2222-222222222222' and role = 'owner' and status = 'active';
  begin
    insert into public.projects (id, user_id, name)
    values ('b4444444-4444-4444-4444-444444444444', 'a2222222-2222-2222-2222-222222222222', 'Ownerless');
  exception when others then ok := true;
  end;
  assert ok, 'a project insert for a user who owns no organization did not raise';
end
$$;

-- ⚠ ambiguous ownership (two owned organizations): raise rather than pick one
do $$
declare
  org_extra uuid;
  ok        boolean := false;
begin
  reset role;
  insert into public.organizations (name, slug, owner_user_id)
  values ('A Second Practice', 'org-a1111111-extra', 'a1111111-1111-1111-1111-111111111111')
  returning id into org_extra;
  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values (org_extra, 'a1111111-1111-1111-1111-111111111111', 'owner', 'active', now());

  begin
    insert into public.projects (id, user_id, name)
    values ('b3333333-3333-3333-3333-333333333333', 'a1111111-1111-1111-1111-111111111111', 'Ambiguous');
  exception when others then ok := true;
  end;
  assert ok, 'a project insert for a user owning two organizations did not raise';
end
$$;

rollback;
