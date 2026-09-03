-- ============================================================================
-- Tests — tenancy layer: invitation RPCs
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('fb111111-1111-1111-1111-111111111111', 'invite-owner@example.com');

-- lot H's chokepoint means this org needs real seat allowance to run
-- these fixtures at all — a paid practice_seats purchase.
do $$
declare org_owner uuid;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fb111111-1111-1111-1111-111111111111';
  insert into public.purchases
    (user_id, organization_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
  values
    ('fb111111-1111-1111-1111-111111111111', org_owner, 'practice_seats', 'cs_test_invites_fixture', 14700, 'paid', now());
end
$$;

-- ---------------------------------------------------------------------------
-- create_org_invite — owner only, and returns a usable token
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  raw_token text;
  ok        boolean := false;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fb111111-1111-1111-1111-111111111111';

  -- not the owner: raises
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000099"}';
  begin
    perform public.create_org_invite(org_owner, 'clinician@example.com');
  exception when others then ok := true;
  end;
  assert ok, 'a non-owner created an invite';

  set local request.jwt.claims = '{"sub":"fb111111-1111-1111-1111-111111111111"}';
  raw_token := public.create_org_invite(org_owner, 'clinician@example.com');
  assert raw_token is not null and length(raw_token) > 0, 'create_org_invite returned no token';

  reset role;
  assert (select count(*) from public.organization_members
           where organization_id = org_owner and invited_email = 'clinician@example.com'::citext
             and status = 'invited' and user_id is null) = 1,
         'the invite row was not created in the expected shape';
  assert (select invite_token_hash from public.organization_members
           where organization_id = org_owner and invited_email = 'clinician@example.com'::citext) is not null,
         'the token hash was not stored';
end
$$;

-- inviting the same email twice while active is refused — reuse a fresh org
-- to avoid depending on state from the block above
do $$
declare
  org_owner uuid;
  ok boolean := false;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fb111111-1111-1111-1111-111111111111';
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fb111111-1111-1111-1111-111111111111"}';
  begin
    -- the owner herself is already an active member with her own email
    perform public.create_org_invite(org_owner, 'invite-owner@example.com');
  exception when others then ok := true;
  end;
  assert ok, 'inviting an already-active member''s email was allowed';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- preview_org_invite — anon-callable, never raises
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  raw_token text;
  r         record;
  n         int;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fb111111-1111-1111-1111-111111111111';
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fb111111-1111-1111-1111-111111111111"}';
  raw_token := public.create_org_invite(org_owner, 'preview-target@example.com');
  reset role;

  set local role anon;
  select * into r from public.preview_org_invite(raw_token);
  assert r.invited_email = 'preview-target@example.com'::citext, 'preview did not return the invited email';
  assert r.organization_name is not null, 'preview did not return the organization name';

  select count(*) into n from public.preview_org_invite('not-a-real-token');
  assert n = 0, 'preview raised or returned a row for a bogus token';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- accept_org_invite — email match required, single use, unauthenticated raises
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner  uuid;
  raw_token  text;
  ok         boolean := false;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fb111111-1111-1111-1111-111111111111';
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fb111111-1111-1111-1111-111111111111"}';
  raw_token := public.create_org_invite(org_owner, 'clinician-accept@example.com');
  reset role;

  -- unauthenticated: raises
  set local role authenticated;
  set local request.jwt.claims = '{}';
  begin
    perform public.accept_org_invite(raw_token);
  exception when others then ok := true;
  end;
  assert ok, 'accept_org_invite succeeded with no authenticated caller';

  -- signed in as someone whose email does not match: raises
  reset role;
  insert into auth.users (id, email) values ('fb222222-2222-2222-2222-222222222222', 'wrong-email@example.com');
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fb222222-2222-2222-2222-222222222222"}';
  ok := false;
  begin
    perform public.accept_org_invite(raw_token);
  exception when others then ok := true;
  end;
  assert ok, 'accept_org_invite succeeded with a mismatched email';

  -- signed in with the matching email: succeeds
  reset role;
  insert into auth.users (id, email) values ('fb333333-3333-3333-3333-333333333333', 'clinician-accept@example.com');
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fb333333-3333-3333-3333-333333333333"}';
  assert public.accept_org_invite(raw_token) = org_owner, 'accept_org_invite did not return the organization id';

  reset role;
  assert (select status from public.organization_members
           where organization_id = org_owner and user_id = 'fb333333-3333-3333-3333-333333333333') = 'active',
         'the membership was not activated';
  assert (select invite_token_hash from public.organization_members
           where organization_id = org_owner and user_id = 'fb333333-3333-3333-3333-333333333333') is null,
         'the token hash survived acceptance';

  -- a second accept of the same raw token: raises
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fb333333-3333-3333-3333-333333333333"}';
  ok := false;
  begin
    perform public.accept_org_invite(raw_token);
  exception when others then ok := true;
  end;
  assert ok, 'the same invite token was accepted twice';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- remove_org_member — owner only, and refuses to remove an owner
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner   uuid;
  member_id   uuid;
  owner_member_id uuid;
  ok boolean := false;
begin
  select id into org_owner from public.organizations where owner_user_id = 'fb111111-1111-1111-1111-111111111111';
  select id into member_id from public.organization_members
   where organization_id = org_owner and user_id = 'fb333333-3333-3333-3333-333333333333';
  select id into owner_member_id from public.organization_members
   where organization_id = org_owner and role = 'owner' and status = 'active';

  -- the clinician herself is not an owner: refused
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fb333333-3333-3333-3333-333333333333"}';
  begin
    perform public.remove_org_member(member_id);
  exception when others then ok := true;
  end;
  assert ok, 'a non-owner removed a member';

  -- the owner removes the clinician: succeeds
  set local request.jwt.claims = '{"sub":"fb111111-1111-1111-1111-111111111111"}';
  perform public.remove_org_member(member_id);
  reset role;
  assert (select status from public.organization_members where id = member_id) = 'removed',
         'remove_org_member did not set status=removed';
  assert (select removed_at from public.organization_members where id = member_id) is not null,
         'remove_org_member did not set removed_at';

  -- the owner cannot remove herself as owner
  ok := false;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fb111111-1111-1111-1111-111111111111"}';
  begin
    perform public.remove_org_member(owner_member_id);
  exception when others then ok := true;
  end;
  assert ok, 'an owner was removed';
  reset role;
end
$$;

rollback;
