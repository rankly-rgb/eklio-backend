-- ============================================================================
-- Tests — tenancy layer: pgcrypto schema resolution (lot A1)
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- The helpers work and produce the expected shape
-- ---------------------------------------------------------------------------
do $$
declare
  token text;
  hash1 text;
  hash2 text;
begin
  token := public.random_token_hex(32);
  assert token is not null and length(token) = 64,
         'random_token_hex(32) did not return 64 hex characters';
  assert token ~ '^[0-9a-f]{64}$', 'random_token_hex output is not lowercase hex';

  hash1 := public.sha256_hex(token);
  hash2 := public.sha256_hex(token);
  assert hash1 = hash2, 'sha256_hex is not deterministic for the same input';
  assert hash1 ~ '^[0-9a-f]{64}$', 'sha256_hex output is not lowercase hex';

  assert public.sha256_hex('a') <> public.sha256_hex('b'),
         'sha256_hex collided on two different inputs';
end
$$;

-- ---------------------------------------------------------------------------
-- Token round-trip: what create_org_invite stores is sha256_hex(raw token)
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  raw_token text;
begin
  insert into auth.users (id, email)
  values ('fc111111-1111-4111-8111-111111111111', 'pgcrypto-owner@example.com');
  select id into org_owner
    from public.organizations
   where owner_user_id = 'fc111111-1111-4111-8111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"fc111111-1111-4111-8111-111111111111"}';
  raw_token := public.create_org_invite(org_owner, 'candidate@example.com');
  reset role;

  assert (select invite_token_hash from public.organization_members
           where organization_id = org_owner and invited_email = 'candidate@example.com'::citext)
         = public.sha256_hex(raw_token),
         'the stored invite_token_hash does not match sha256_hex(raw_token)';

  -- and the token still round-trips through preview_org_invite as anon
  set local role anon;
  assert (select count(*) from public.preview_org_invite(raw_token)) = 1,
         'preview_org_invite did not recognize a token minted via the new helpers';
  reset role;
end
$$;

-- ---------------------------------------------------------------------------
-- No client role can call the helpers directly
-- ---------------------------------------------------------------------------
do $$
begin
  assert not has_function_privilege('anon', 'public.random_token_hex(int)'::regprocedure, 'EXECUTE'),
    'anon can execute random_token_hex';
  assert not has_function_privilege('authenticated', 'public.random_token_hex(int)'::regprocedure, 'EXECUTE'),
    'authenticated can execute random_token_hex';
  assert not has_function_privilege('anon', 'public.sha256_hex(text)'::regprocedure, 'EXECUTE'),
    'anon can execute sha256_hex';
  assert not has_function_privilege('authenticated', 'public.sha256_hex(text)'::regprocedure, 'EXECUTE'),
    'authenticated can execute sha256_hex';
end
$$;

rollback;
