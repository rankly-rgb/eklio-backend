-- ============================================================================
-- Tests — E1/E2: provision_clinician_project, apply_charter_internal
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('ee111111-1111-4111-8111-111111111111', 'e1-owner@example.com'),
  ('ee222222-2222-4222-8222-222222222222', 'e1-clinician@example.com'),
  ('ee333333-3333-4333-8333-333333333333', 'e1-stranger@example.com');

do $$
declare
  org_owner uuid;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ee111111-1111-4111-8111-111111111111';

  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values (org_owner, 'ee222222-2222-4222-8222-222222222222', 'clinician', 'active', now());
end
$$;

-- ---------------------------------------------------------------------------
-- The defect this trace actually found (not the one hypothesized): a plain
-- client-side INSERT...RETURNING into `projects`, as the authenticated
-- clinician, still fails outright. Not wrong-org routing — total failure.
-- This is why provision_clinician_project exists; it is NOT patched at the
-- RLS-policy level here (out of scope — see this migration's own header),
-- so this demonstration keeps passing after the fix, on purpose.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  ok        boolean := false;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ee111111-1111-4111-8111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ee222222-2222-4222-8222-222222222222"}';

  begin
    insert into public.projects (user_id, organization_id, name)
    values ('ee222222-2222-4222-8222-222222222222', org_owner, 'My profile')
    returning id;
  exception when others then ok := true;
  end;

  reset role;
  assert ok, 'a plain client-side projects insert with RETURNING unexpectedly succeeded — the documented defect is no longer reproducible; re-check this migration''s header trace';
end
$$;

-- ---------------------------------------------------------------------------
-- provision_clinician_project: succeeds, lands in the PRACTICE org (not a
-- solo org), the owner can read it, member.project_id is set, idempotent.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner  uuid;
  prj_id     uuid;
  prj_id2    uuid;
  member_id  uuid;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ee111111-1111-4111-8111-111111111111';
  select id into member_id from public.organization_members
   where organization_id = org_owner and user_id = 'ee222222-2222-4222-8222-222222222222';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ee222222-2222-4222-8222-222222222222"}';

  select public.provision_clinician_project(org_owner) into prj_id;
  reset role;

  assert prj_id is not null, 'provision_clinician_project returned no project id';
  assert (select organization_id from public.projects where id = prj_id) = org_owner,
         'the provisioned project landed in the wrong organization';
  assert (select project_id from public.organization_members where id = member_id) = prj_id,
         'organization_members.project_id was not set';
  assert exists (select 1 from public.brand_kits where project_id = prj_id),
         'provision_clinician_project did not scaffold a brand_kits row';
  assert exists (select 1 from public.site_specs s join public.brand_kits bk on bk.id = s.brand_kit_id where bk.project_id = prj_id),
         'provision_clinician_project did not scaffold a site_specs row';

  -- The owner can read it (can_access_project — is_org_owner branch).
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ee111111-1111-4111-8111-111111111111"}';
  assert exists (select 1 from public.projects where id = prj_id),
         'the org owner could not read the clinician''s provisioned project';
  reset role;

  -- Idempotent: calling again returns the SAME project, no duplicate.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ee222222-2222-4222-8222-222222222222"}';
  select public.provision_clinician_project(org_owner) into prj_id2;
  reset role;
  assert prj_id2 = prj_id, 'a second call to provision_clinician_project returned a different project';
  assert (select count(*) from public.projects where organization_id = org_owner and user_id = 'ee222222-2222-4222-8222-222222222222') = 1,
         'a second call to provision_clinician_project created a duplicate project';
end
$$;

-- ---------------------------------------------------------------------------
-- A non-member is refused.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  ok        boolean := false;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ee111111-1111-4111-8111-111111111111';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ee333333-3333-4333-8333-333333333333"}';
  begin
    perform public.provision_clinician_project(org_owner);
  exception when others then ok := true;
  end;
  reset role;

  assert ok, 'a stranger (non-member) was able to provision a project in an organization she does not belong to';
end
$$;

-- ---------------------------------------------------------------------------
-- E2: the charter is applied without the clinician ever being an owner —
-- and a practice with NO charter kit yet does not block provisioning.
-- ---------------------------------------------------------------------------
do $$
declare
  org_owner uuid;
  kit_owner uuid := 'ef000001-0001-0001-0001-000000000001';
  prj_owner uuid := 'ef000002-0002-0002-0002-000000000002';
begin
  select id into org_owner from public.organizations where owner_user_id = 'ee111111-1111-4111-8111-111111111111';

  insert into public.projects (id, user_id, organization_id, name)
  values (prj_owner, 'ee111111-1111-4111-8111-111111111111', org_owner, 'Charter Project');
  insert into public.brand_kits (id, project_id) values (kit_owner, prj_owner);
  insert into public.site_specs
    (brand_kit_id, user_id, primary_hex, secondary_hex, accent_hex,
     light_neutral_hex, dark_neutral_hex, paper_hex, heading_font, body_font, google_fonts_url,
     hero, pages)
  values (kit_owner, 'ee111111-1111-4111-8111-111111111111', '#111111','#222222','#333333','#FFFFFF','#000000','#FAFAFA','Fraunces','Nunito Sans','u',
          '{"overline":"o","headline":"h","subhead":"s","cta_label":"c"}'::jsonb, public.site_spec_default_pages(null, null));

  update public.organizations set brand_charter_kit_id = kit_owner where id = org_owner;
end
$$;

do $$
declare
  org_owner uuid;
  prj_id    uuid;
  spec      record;
begin
  select id into org_owner from public.organizations where owner_user_id = 'ee111111-1111-4111-8111-111111111111';
  select project_id into prj_id from public.organization_members
   where organization_id = org_owner and user_id = 'ee222222-2222-4222-8222-222222222222';

  -- Re-provisioning (idempotent) after the org gained a charter kit does
  -- NOT retroactively apply it — apply_charter_internal only runs at
  -- provisioning time, matching apply_charter_to_project's own
  -- idempotent-but-not-automatic contract. Confirm that first...
  select s.* into spec
    from public.site_specs s join public.brand_kits bk on bk.id = s.brand_kit_id
   where bk.project_id = prj_id;
  assert spec.field_sources->>'primary_hex' is distinct from 'inherited',
         'a project provisioned before the org had a charter kit was retroactively charter-applied by mere re-provisioning';

  -- ...then provision a SECOND clinician, now that the org HAS a charter
  -- kit, and confirm the charter lands automatically, without her ever
  -- being an owner.
  insert into auth.users (id, email) values ('ee444444-4444-4444-8444-444444444444', 'e1-clinician-2@example.com');
  insert into public.organization_members (organization_id, user_id, role, status, activated_at)
  values (org_owner, 'ee444444-4444-4444-8444-444444444444', 'clinician', 'active', now());

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ee444444-4444-4444-8444-444444444444"}';
  select public.provision_clinician_project(org_owner) into prj_id;
  reset role;

  assert not public.is_org_owner(org_owner), 'test setup error: the clinician should never be the owner';

  select s.* into spec
    from public.site_specs s join public.brand_kits bk on bk.id = s.brand_kit_id
   where bk.project_id = prj_id;

  assert spec.primary_hex = '#111111', 'the charter''s primary_hex was not applied to the second clinician''s project';
  assert spec.field_sources->>'primary_hex' = 'inherited', 'primary_hex was not marked inherited';
  assert spec.field_sources->>'heading_font' = 'inherited', 'heading_font was not marked inherited';
end
$$;

-- ---------------------------------------------------------------------------
-- Consistency triggers reject a cross-org mismatch.
-- ---------------------------------------------------------------------------
do $$
declare
  org_a uuid;
  org_b uuid;
  prj_in_a uuid;
  ok    boolean := false;
begin
  select id into org_a from public.organizations where owner_user_id = 'ee111111-1111-4111-8111-111111111111';

  insert into auth.users (id, email) values ('ee555555-5555-4555-8555-555555555555', 'e1-other-owner@example.com');
  select id into org_b from public.organizations where owner_user_id = 'ee555555-5555-4555-8555-555555555555';

  select project_id into prj_in_a from public.organization_members
   where organization_id = org_a and user_id = 'ee222222-2222-4222-8222-222222222222';

  -- organization_members.project_id must point into the same org.
  begin
    insert into public.organization_members (organization_id, user_id, project_id, role, status, activated_at)
    values (org_b, 'ee333333-3333-4333-8333-333333333333', prj_in_a, 'clinician', 'active', now());
  exception when others then ok := true;
  end;
  assert ok, 'organization_members accepted a project_id belonging to a different organization';

  -- clinician_profiles.organization_id must match its project''s organization.
  ok := false;
  begin
    insert into public.clinician_profiles (organization_id, project_id, member_id, full_name, status)
    select org_b, prj_in_a, m.id, 'Mismatched', 'licensed'
      from public.organization_members m
     where m.organization_id = org_a and m.user_id = 'ee222222-2222-4222-8222-222222222222';
  exception when others then ok := true;
  end;
  assert ok, 'clinician_profiles accepted an organization_id that does not match its project''s organization';
end
$$;

rollback;
