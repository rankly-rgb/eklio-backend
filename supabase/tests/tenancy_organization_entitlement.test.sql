-- ============================================================================
-- Tests — lot H: organization_seat_count, organization_entitlement, the
-- seat_allowance_exceeded chokepoint
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('ea911111-1111-4111-8111-111111111111', 'h-free-owner@example.com'),
  ('ea822222-2222-4222-8222-222222222222', 'h-paid-owner@example.com');

-- ---------------------------------------------------------------------------
-- A free (no practice_seats purchase) organization is entitled to
-- exactly one seat — the owner herself already occupies it.
-- ---------------------------------------------------------------------------
do $$
declare
  org_free uuid;
  ent      jsonb;
  ok       boolean := false;
begin
  select id into org_free from public.organizations where owner_user_id = 'ea911111-1111-4111-8111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ea911111-1111-4111-8111-111111111111"}';

  ent := public.organization_entitlement(org_free);
  assert (ent->>'tier') = 'free', format('expected tier free, got %s', ent->>'tier');
  assert (ent->>'seat_count')::int = 1, format('expected seat_count 1 (the owner), got %s', ent->>'seat_count');
  assert (ent->>'seat_allowance')::int = 1, format('expected seat_allowance 1 for a free org, got %s', ent->>'seat_allowance');
  assert (ent->'capabilities'->>'grid')::boolean = false, 'grid should not be entitled for a free org';
  assert (ent->'capabilities'->>'setup_sheets')::boolean = false, 'setup_sheets should not be entitled for a free org';
  assert (ent->'capabilities'->>'clinician_profiles')::boolean = true, 'clinician_profiles should stay available to every org';

  -- At the allowance already (the owner is the one seat) — a first invite
  -- is over it, and raises the named error.
  begin
    perform public.create_org_invite(org_free, 'someone@example.com');
  exception when others then
    ok := sqlerrm like '%seat_allowance_exceeded%';
  end;
  reset role;
  assert ok, 'a free org''s first invite was not refused with seat_allowance_exceeded';
end
$$;

-- ---------------------------------------------------------------------------
-- A practice_seats org: entitled to the plan's allowance (10), invites
-- succeed up to it, the next one raises. The error text is readable
-- (names the counts), not a bare stack trace.
-- ---------------------------------------------------------------------------
do $$
declare
  org_paid uuid;
  ent      jsonb;
  ok       boolean := false;
  err_msg  text;
  i        int;
begin
  select id into org_paid from public.organizations where owner_user_id = 'ea822222-2222-4222-8222-222222222222';

  insert into public.purchases
    (user_id, organization_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
  values
    ('ea822222-2222-4222-8222-222222222222', org_paid, 'practice_seats', 'cs_test_h_fixture', 14700, 'paid', now());

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ea822222-2222-4222-8222-222222222222"}';

  ent := public.organization_entitlement(org_paid);
  assert (ent->>'tier') = 'practice_seats', format('expected tier practice_seats, got %s', ent->>'tier');
  assert (ent->>'seat_allowance')::int = 10, format('expected seat_allowance 10, got %s', ent->>'seat_allowance');
  assert (ent->'capabilities'->>'grid')::boolean = true, 'grid should be entitled for a practice_seats org';
  assert (ent->'capabilities'->>'setup_sheets')::boolean = true, 'setup_sheets should be entitled for a practice_seats org';

  -- The owner is seat 1; 9 more invites reach the allowance of 10 exactly.
  for i in 1..9 loop
    perform public.create_org_invite(org_paid, ('clinician' || i || '@example.com')::citext);
  end loop;

  assert public.organization_seat_count(org_paid) = 10, 'seat count did not reach the allowance after 9 invites plus the owner';

  -- The 10th invite (an 11th seat) is refused.
  begin
    perform public.create_org_invite(org_paid, 'one-too-many@example.com');
  exception when others then
    ok := true;
    get stacked diagnostics err_msg = message_text;
  end;
  reset role;

  assert ok, 'an invite past the allowance was not refused';
  assert err_msg like '%seat_allowance_exceeded%', format('error text was not the named error: %s', err_msg);
  assert err_msg like '%10%', format('error text did not name the counts (10 of 10): %s', err_msg);
end
$$;

-- ---------------------------------------------------------------------------
-- provision_clinician_project: an already-provisioned member re-calling
-- is never blocked by the chokepoint, however over-allowance the
-- organization has since become.
-- ---------------------------------------------------------------------------
do $$
declare
  org_free  uuid;
  member_id uuid;
  prj_id    uuid;
  prj_id2   uuid;
begin
  select id into org_free from public.organizations where owner_user_id = 'ea911111-1111-4111-8111-111111111111';

  -- The owner IS an active member of her own org, and IS entitled to her
  -- own first provisioning (seat 1 of 1) even with no purchase.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ea911111-1111-4111-8111-111111111111"}';
  select public.provision_clinician_project(org_free) into prj_id;
  reset role;
  assert prj_id is not null, 'the owner could not provision her own first project within her own allowance';

  -- Re-calling (idempotent) succeeds even though the org has no room for
  -- a NEW seat — she already holds this one.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ea911111-1111-4111-8111-111111111111"}';
  select public.provision_clinician_project(org_free) into prj_id2;
  reset role;
  assert prj_id2 = prj_id, 'idempotent re-provisioning was blocked by the seat chokepoint';
end
$$;

rollback;
