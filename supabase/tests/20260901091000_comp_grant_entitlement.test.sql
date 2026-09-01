-- ============================================================================
-- Tests — 20260901091000_comp_grant_entitlement.sql
-- ============================================================================
-- What has to hold:
--
--   * An active comp grant entitles exactly like a paid purchase: kit access,
--     the PDF (same `brand_kit_entitled` the PDF route calls directly — see
--     eklio-frontend/app/api/brand-kits/[id]/pdf/route.ts), and every
--     site-editor RPC (via `site_spec_entitlement_error`).
--   * An expired grant does not entitle.
--   * A revoked grant does not entitle.
--   * A grant for user A does not entitle user B.
--   * Generation credits still decrement under a comp grant, and still block
--     at zero — the meter is widened, never skipped.
--   * The internal predicates (comp_grant_credits, comp_grant_active) stay
--     unreachable from anon/authenticated; comp_access_active is
--     authenticated-only.
--   * The existing route-enumeration guard test in
--     20260829123000_entitlement_and_generation_credits.test.sql is untouched
--     by this file and still passes on its own.
--
-- ⚠ Monthly Presence is deliberately NOT covered here: it is not centralised
-- in the database (see the migration's own header). A comp grant does not
-- currently unlock it; that is a reported gap, not an oversight.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('a0000001-0001-0001-0001-000000000001','comp-holder@example.internal'),
  ('a0000002-0002-0002-0002-000000000002','stranger@example.internal');

insert into public.projects (id, user_id, name) values
  ('b0000001-0001-0001-0001-000000000001','a0000001-0001-0001-0001-000000000001','Comp Project'),
  ('b0000002-0002-0002-0002-000000000002','a0000002-0002-0002-0002-000000000002','Stranger Project');

insert into public.brand_kits (id, project_id) values
  ('e0000001-0001-0001-0001-000000000001','b0000001-0001-0001-0001-000000000001'),
  ('e0000002-0002-0002-0002-000000000002','b0000002-0002-0002-0002-000000000002');

-- ---------------------------------------------------------------------------
-- No grant at all: the baseline stays unentitled
-- ---------------------------------------------------------------------------
do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a0000001-0001-0001-0001-000000000001"}';
  assert public.brand_kit_entitled('e0000001-0001-0001-0001-000000000001') is false,
         'a kit with no purchase and no grant was entitled';
  assert public.site_spec_entitlement_error('e0000001-0001-0001-0001-000000000001')->>'code'
         = 'payment_required', 'the site editor was open with no grant';
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Active grant => entitled to kit, PDF (same function), site editor
-- ---------------------------------------------------------------------------
do $$
begin
  reset role;
  insert into public.comp_grants (user_id, reason, granted_by, expires_at)
  values ('a0000001-0001-0001-0001-000000000001', 'internal testing', 'ops@example.internal',
          now() + interval '90 days');

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a0000001-0001-0001-0001-000000000001"}';

  assert public.brand_kit_entitled('e0000001-0001-0001-0001-000000000001') is true,
         'an active comp grant did not entitle the kit (and therefore the PDF route, which calls the same function)';
  assert public.site_spec_entitlement_error('e0000001-0001-0001-0001-000000000001') is null,
         'an active comp grant did not open the site editor';
  assert public.comp_access_active() is true,
         'comp_access_active did not report the active grant';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Expired grant => NOT entitled
-- ---------------------------------------------------------------------------
do $$
begin
  reset role;
  update public.comp_grants
     set expires_at = now() - interval '1 minute'
   where user_id = 'a0000001-0001-0001-0001-000000000001' and revoked_at is null;

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a0000001-0001-0001-0001-000000000001"}';
  assert public.brand_kit_entitled('e0000001-0001-0001-0001-000000000001') is false,
         'an expired comp grant still entitled';
  assert public.site_spec_entitlement_error('e0000001-0001-0001-0001-000000000001')->>'code'
         = 'payment_required', 'an expired comp grant still opened the site editor';
  assert public.comp_access_active() is false,
         'comp_access_active reported an expired grant as active';
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Revoked grant => NOT entitled
-- ---------------------------------------------------------------------------
do $$
begin
  reset role;
  update public.comp_grants
     set expires_at = now() + interval '90 days',
         revoked_at = now()
   where user_id = 'a0000001-0001-0001-0001-000000000001';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a0000001-0001-0001-0001-000000000001"}';
  assert public.brand_kit_entitled('e0000001-0001-0001-0001-000000000001') is false,
         'a revoked comp grant still entitled';
  assert public.comp_access_active() is false,
         'comp_access_active reported a revoked grant as active';

  -- re-activate it for the tests below
  reset role;
  update public.comp_grants
     set revoked_at = null
   where user_id = 'a0000001-0001-0001-0001-000000000001';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. A grant for user A does not entitle user B
-- ---------------------------------------------------------------------------
do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a0000002-0002-0002-0002-000000000002"}';
  assert public.brand_kit_entitled('e0000002-0002-0002-0002-000000000002') is false,
         'user A''s comp grant entitled user B''s own kit';
  assert public.comp_access_active() is false,
         'user A''s comp grant reported as active for user B';

  -- and B cannot use it to reach A's kit either (ownership is checked first)
  assert public.site_spec_entitlement_error('e0000001-0001-0001-0001-000000000001')->>'code'
         = 'not_found', 'user B reached user A''s kit through the comp grant';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. Credits decrement normally under a comp grant, and block at zero
-- ---------------------------------------------------------------------------
do $$
declare
  kit uuid := 'e0000001-0001-0001-0001-000000000001';
  prj uuid := 'b0000001-0001-0001-0001-000000000001';
  gc  public.generation_credits%rowtype;
  pl  public.plans%rowtype;
begin
  reset role;
  -- a small, exact comp allowance so the block-at-zero edge is reachable
  -- without 200 iterations
  update public.comp_grants set generation_credits = 2
   where user_id = 'a0000001-0001-0001-0001-000000000001' and revoked_at is null;

  select * into pl from public.plans where tier = 'free';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a0000001-0001-0001-0001-000000000001"}';

  -- first run: the free directions_limit (3), unaffected by the comp grant
  assert public.consume_generation_credit(kit) is true, 'the first run was refused under a comp grant';
  select * into gc from public.generation_credits where project_id = prj;
  assert gc.directions_generated = pl.directions_limit and gc.regenerations_used = 0,
    format('after one run the counters are %s/%s', gc.directions_generated, gc.regenerations_used);

  -- the free plan alone allows only 1 regeneration; the comp grant (2) must be
  -- what lets a second regeneration through
  assert public.consume_generation_credit(kit) is true, 'the 1st comp-widened regeneration was refused';
  assert public.consume_generation_credit(kit) is true, 'the 2nd comp-widened regeneration was refused';
  select * into gc from public.generation_credits where project_id = prj;
  assert gc.regenerations_used = 2,
    format('two comp-widened regenerations did not move the counter (got %s)', gc.regenerations_used);

  -- and it still blocks at zero: the comp grant is a wider cap, not no cap
  assert public.consume_generation_credit(kit) is false,
         'a run beyond the comp-widened allowance was permitted';
  select * into gc from public.generation_credits where project_id = prj;
  assert gc.regenerations_used = 2, 'a refused call still moved the counter';
end
$$;

-- ---------------------------------------------------------------------------
-- Internal predicates stay unreachable from clients
-- ---------------------------------------------------------------------------
do $$
declare fn text;
begin
  foreach fn in array array['comp_grant_credits(uuid)', 'comp_grant_active(uuid)'] loop
    assert not has_function_privilege('anon', ('public.' || fn)::regprocedure, 'EXECUTE'),
      format('anon can execute %s', fn);
    assert not has_function_privilege('authenticated', ('public.' || fn)::regprocedure, 'EXECUTE'),
      format('authenticated can execute %s directly', fn);
  end loop;

  assert not has_function_privilege('anon', 'public.comp_access_active()'::regprocedure, 'EXECUTE'),
    'anon can execute comp_access_active';
  assert has_function_privilege('authenticated', 'public.comp_access_active()'::regprocedure, 'EXECUTE'),
    'authenticated cannot execute comp_access_active';
end
$$;

rollback;
