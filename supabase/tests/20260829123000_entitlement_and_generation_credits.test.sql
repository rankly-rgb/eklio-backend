-- ============================================================================
-- Tests — 20260829123000_entitlement_and_generation_credits.sql
-- ============================================================================
-- There was no paywall. `paid` was a client-side branch, no route read
-- `purchases`, and a signed-in account got the whole deliverable for free while
-- Eklio paid $0.09–$1.80 a generation.
--
-- What has to hold now:
--
--   * The reveal is still free. Three directions are the sales pitch.
--   * Choosing one, and everything downstream, is not.
--   * "No such kit" and "you have not paid for this kit" are DIFFERENT answers,
--     because the UI apologises for one and opens checkout for the other.
--   * The allowance cannot be spent twice by two requests that raced, and it
--     cannot be reset by the person being metered.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','nora@elmandember.com'),
  ('99999999-9999-9999-9999-999999999999','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Elm & Ember'),
  ('88888888-8888-8888-8888-888888888888','99999999-9999-9999-9999-999999999999','Not Hers');
insert into public.project_briefs (project_id, practice_name, license_type_id, city, state)
values ('22222222-2222-2222-2222-222222222222','Elm & Ember Therapy','lcsw','Portland','OR'),
       ('88888888-8888-8888-8888-888888888888','Other Practice','lcsw','Salem','OR');

-- Two kits with directions generated and NOTHING bought. This is the state a
-- free account is in after the reveal.
insert into public.brand_kits (id, project_id, directions) values
 ('33333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222',
  jsonb_build_array(
   jsonb_build_object('id','warm_welcome','name','Warm Welcome',
     'rationale','Warmth without softness. It says the first call will be easier than they think.',
     'palette', jsonb_build_object('primary','#B4674A','secondary','#C08A3E','light','#F4EEE3','dark','#2B2A27','paper','#FAF6EE'),
     'typography', jsonb_build_object('heading_font','Fraunces','body_font','Nunito Sans','google_fonts_url','u'),
     'hero', jsonb_build_object('overline','LCSW · PORTLAND, OR','headline','A calmer place to start.',
       'subhead','Therapy for adults who hold it together.','cta_label','Book a consult'),
     'about_excerpt','I work mostly with professionals who look fine from the outside.',
     'tone_keywords', jsonb_build_array('steady','plainspoken','warm')),
   jsonb_build_object('id','quiet_confidence','name','Quiet Confidence',
     'rationale','Restraint reads as experience. For clients who want steadiness more than warmth.',
     'palette', jsonb_build_object('primary','#3B2C3A','secondary','#4A5361','light','#F3EDE4','dark','#241B23','paper','#FAF7F2'),
     'typography', jsonb_build_object('heading_font','Cormorant Garamond','body_font','Source Sans 3','google_fonts_url','u'),
     'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
     'about_excerpt','x','tone_keywords', jsonb_build_array('composed','credible','unhurried')),
   jsonb_build_object('id','modern_calm','name','Modern Calm',
     'rationale','Structure signals a plan. For the client who needs to see how the work goes.',
     'palette', jsonb_build_object('primary','#22364F','secondary','#7A8168','light','#EDEAE5','dark','#16202E','paper','#F7F6F3'),
     'typography', jsonb_build_object('heading_font','Newsreader','body_font','Work Sans','google_fonts_url','u'),
     'hero', jsonb_build_object('overline','o','headline','h','subhead','s','cta_label','c'),
     'about_excerpt','x','tone_keywords', jsonb_build_array('clear','structured','direct'))));

-- the stranger's kit: it only has to exist and not be hers
insert into public.brand_kits (id, project_id) values
 ('77777777-7777-7777-7777-777777777777','88888888-8888-8888-8888-888888888888');

-- the stranger DID pay, for her own kit. Nothing about that may reach Nora.
insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('99999999-9999-9999-9999-999999999999','88888888-8888-8888-8888-888888888888',
        'starter','cs_stranger',4900,'paid',now());

-- ---------------------------------------------------------------------------
-- brand_kit_entitled — the only place the sentence is written
-- ---------------------------------------------------------------------------
do $$
declare
  kit    uuid := '33333333-3333-3333-3333-333333333333';
  theirs uuid := '77777777-7777-7777-7777-777777777777';
  st     text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  assert public.brand_kit_is_owned(kit) is true,  'she does own her kit';
  assert public.brand_kit_entitled(kit) is false, 'an unbought kit is entitled';

  -- ⚠ someone else's PAID kit is neither owned nor entitled for her. If
  -- entitlement were answered before ownership, this is where it would leak.
  assert public.brand_kit_is_owned(theirs) is false, 'she owns a stranger''s kit';
  assert public.brand_kit_entitled(theirs) is false, 'a stranger''s purchase entitled her';

  reset role;
  insert into public.purchases
    (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
  values ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
          'starter','cs_nora',4900,'paid',now());
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  assert public.brand_kit_entitled(kit) is true, 'a paid purchase did not entitle';

  -- every status, and what it means
  foreach st in array array['pending','failed','refunded','disputed'] loop
    reset role;
    update public.purchases set status = st,
           paid_at = case when st in ('pending','failed') then null else now() end
     where stripe_checkout_session_id = 'cs_nora';
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
    assert public.brand_kit_entitled(kit) is false,
      format('status %s must not entitle', st);
  end loop;

  -- ⚠ a partial refund is a discount after the fact, not a withdrawal of the
  -- thing she bought. She keeps the kit.
  reset role;
  update public.purchases set status = 'partially_refunded', paid_at = now()
   where stripe_checkout_session_id = 'cs_nora';
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  assert public.brand_kit_entitled(kit) is true, 'a partial refund revoked the kit';

  reset role;
  update public.purchases set status = 'paid' where stripe_checkout_session_id = 'cs_nora';
end
$$;

-- ⚠ The RPC surface: signed-in callers only, and anon cannot dial any of it.
do $$
declare fn text;
begin
  foreach fn in array array[
    'brand_kit_entitled(uuid)', 'brand_kit_is_owned(uuid)',
    'brand_kit_select_direction(uuid,text)', 'consume_generation_credit(uuid)',
    'site_spec_entitlement_error(uuid)'
  ] loop
    assert not has_function_privilege('anon', ('public.' || fn)::regprocedure, 'EXECUTE'),
      format('anon can execute %s', fn);
    assert has_function_privilege('authenticated', ('public.' || fn)::regprocedure, 'EXECUTE'),
      format('a signed-in caller cannot execute %s', fn);
  end loop;
end
$$;

-- ⚠ never NULL. A NULL reads as "not entitled" to an `if not` and as "entitled"
-- to a CHECK, which is exactly how a paywall ends up open on one path.
do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  assert public.brand_kit_entitled(null) is false, 'null kit id was not false';
  assert public.brand_kit_entitled('00000000-0000-0000-0000-000000000000') is false,
         'a kit that does not exist was not false';
  -- ⚠ no caller. `reset role` does NOT do this: request.jwt.claims is a GUC and
  -- survives a role change, which is worth knowing before writing a test that
  -- believes it proved something.
  set local request.jwt.claims = '{}';
  assert public.brand_kit_entitled('33333333-3333-3333-3333-333333333333') is false,
         'entitlement answered true with no caller';
  assert public.brand_kit_is_owned('33333333-3333-3333-3333-333333333333') is false,
         'ownership answered true with no caller';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ The three answers are three different sentences
-- ---------------------------------------------------------------------------
do $$
declare
  kit    uuid := '33333333-3333-3333-3333-333333333333';
  theirs uuid := '77777777-7777-7777-7777-777777777777';
  fn     text;
  r      jsonb;
begin
  reset role;
  update public.purchases set status = 'pending', paid_at = null
   where stripe_checkout_session_id = 'cs_nora';

  -- not signed in
  set local role authenticated;
  set local request.jwt.claims = '{}';
  assert public.site_spec_get(kit)->'error'->>'code' = 'unauthenticated',
         'a signed-out read was not unauthenticated';

  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  -- someone else's kit is NOT FOUND, never payment_required: the second answer
  -- would confirm the id exists
  assert public.site_spec_get(theirs)->'error'->>'code' = 'not_found',
         'a stranger''s kit answered something other than not_found';
  assert public.site_spec_get('00000000-0000-0000-0000-000000000000')->'error'->>'code'
         = 'not_found', 'a missing kit answered something other than not_found';

  -- her own, unpaid: payment_required on every gated entry point
  assert public.site_spec_get(kit)->'error'->>'code' = 'payment_required',
         'site_spec_get did not refuse';
  assert public.site_output_get(kit)->'error'->>'code' = 'payment_required',
         'site_output_get did not refuse';
  assert public.site_spec_patch(kit, '{"about_excerpt":"x"}')->'error'->>'code'
         = 'payment_required', 'site_spec_patch did not refuse';
  assert public.site_spec_reset(kit, 'all')->'error'->>'code'
         = 'payment_required', 'site_spec_reset did not refuse';
  assert public.site_spec_set_target(kit, 'lovable')->'error'->>'code'
         = 'payment_required', 'site_spec_set_target did not refuse';
  assert public.site_spec_fix_contrast(kit, 'primary_on_paper')->'error'->>'code'
         = 'payment_required', 'site_spec_fix_contrast did not refuse';
  assert public.site_output_mark_copied(kit)->'error'->>'code'
         = 'payment_required', 'site_output_mark_copied did not refuse';
  assert public.brand_kit_select_direction(kit, 'warm_welcome')->'error'->>'code'
         = 'payment_required', 'brand_kit_select_direction did not refuse';

  -- ⚠ and the refusal must not be mistakable for a missing row. She HAS a kit.
  assert public.site_spec_get(kit)->'error'->>'message' <> 'No site spec for this brand kit.',
         'the paywall message reads like a missing row';

  -- the format complaint still comes first: it is about the request
  assert public.site_output_get(kit, null, 'pdf')->'error'->>'code' = 'invalid_format',
         'a bad format was masked by the paywall';

  -- ⚠ THE REVEAL STAYS FREE. The catalog describes the thing she is being asked
  -- to buy; refusing it would be refusing the sales pitch.
  assert public.site_catalog() ? 'section_types', 'the catalog was gated';
  assert jsonb_array_length(public.site_catalog()->'builder_targets') = 7,
         'the catalog lost content behind the paywall';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ Choosing a direction is the line, and the trigger is what holds it
-- ---------------------------------------------------------------------------
-- The RPC gives the frontend an envelope it can act on. The trigger is the part
-- that does not depend on the caller choosing the polite door.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  ok  boolean := false;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  begin
    update public.brand_kits set selected_direction_id = 'warm_welcome' where id = kit;
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'an unentitled client set selected_direction_id by writing the table directly';
  assert (select selected_direction_id from public.brand_kits where id = kit) is null,
         'the direction was selected anyway';

  -- pay, and the same write goes through
  reset role;
  update public.purchases set status = 'paid', paid_at = now()
   where stripe_checkout_session_id = 'cs_nora';
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  -- ⚠ paid, but nothing chosen yet: there genuinely is no spec, so this is
  -- not_found again. Step 4 of the ladder, and the state she is in for the few
  -- seconds between checkout and choosing.
  assert public.site_spec_get(kit)->'error'->>'code' = 'not_found',
         'a paid kit with no direction chosen did not answer not_found';

  assert public.brand_kit_select_direction(kit, 'not_a_direction')->'error'->>'code'
         = 'invalid_field', 'an unknown direction id was accepted';

  assert public.brand_kit_select_direction(kit, 'warm_welcome')->'spec' is not null,
         'selecting a direction after paying did not return the spec';
  assert (select selected_direction_id from public.brand_kits where id = kit) = 'warm_welcome',
         'the selection was not stored';
  assert exists (select 1 from public.site_specs where brand_kit_id = kit),
         'selecting a direction did not seed the site spec';
end
$$;

-- ---------------------------------------------------------------------------
-- Once she has paid, everything works exactly as before
-- ---------------------------------------------------------------------------
do $$
declare kit uuid := '33333333-3333-3333-3333-333333333333';
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  assert public.site_spec_get(kit)->'error' is null, 'a paid read was refused';
  assert public.site_spec_patch(kit,'{"about_excerpt":"Paid for."}')->'error' is null,
         'a paid patch was refused';
  assert public.site_spec_set_target(kit,'squarespace')->'error' is null,
         'a paid target switch was refused';
  assert public.site_output_mark_copied(kit)->'error' is null,
         'a paid mark-copied was refused';
  assert public.site_output_get(kit, null, 'md')->>'text' is not null,
         'a paid output read was refused';
  assert public.site_spec_reset(kit,'colors')->'error' is null,
         'a paid reset was refused';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ The meter cannot be reset by the party being metered
-- ---------------------------------------------------------------------------
-- The policy was `for all` with ownership on both sides, so a signed-in owner
-- could zero her own counters and mint an unlimited allowance.
do $$
declare
  ok boolean := false;
  n  int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  assert (select count(*) from public.generation_credits) >= 1,
         'she must still be able to READ her allowance';

  begin
    update public.generation_credits set regenerations_used = 0, directions_generated = 0;
    get diagnostics n = row_count;
    ok := (n = 0);
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'a client rewrote her own generation allowance';

  begin
    ok := false;
    delete from public.generation_credits;
    get diagnostics n = row_count;
    ok := (n = 0);
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'a client deleted her own allowance row';
end
$$;

-- ---------------------------------------------------------------------------
-- consume_generation_credit — the allowance comes from the granted plan
-- ---------------------------------------------------------------------------
-- ⚠ There is no entitled/not branch any more. An ungranted project is on the
-- `free` PLAN ROW — not on a pair of column defaults pretending to be one.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  gc  public.generation_credits%rowtype;
  pl  public.plans%rowtype;
begin
  reset role;
  update public.purchases set status = 'pending', paid_at = null
   where stripe_checkout_session_id = 'cs_nora';
  update public.generation_credits set directions_generated = 0, regenerations_used = 0
   where project_id = '22222222-2222-2222-2222-222222222222';

  select * into gc from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222';
  assert gc.plan_tier = 'free', 'a project starts on something other than the free plan';
  select * into pl from public.plans where tier = 'free';
  assert (pl.directions_limit, pl.regenerations_limit) = (3::smallint, 1::smallint),
         'the free row is not one run of three plus one regeneration';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  assert public.consume_generation_credit(kit) is true, 'the free run was refused';
  select * into gc from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222';
  -- ⚠ the counter moves by the DIRECTIONS a run produces, because that is what
  -- `directions_limit` means now. This is the assertion that would have caught
  -- the original misreading.
  assert gc.directions_generated = pl.directions_limit and gc.regenerations_used = 0,
    format('after one run the counters are %s/%s', gc.directions_generated, gc.regenerations_used);

  assert public.consume_generation_credit(kit) is true, 'the free regeneration was refused';
  select * into gc from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222';
  assert gc.directions_generated = pl.directions_limit and gc.regenerations_used = 1,
         'the second run did not draw on the regeneration allowance';

  assert public.consume_generation_credit(kit) is false, 'a third free run was allowed';
  select * into gc from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222';
  assert gc.directions_generated = pl.directions_limit and gc.regenerations_used = 1,
         'a refused call still moved a counter';
end
$$;

-- ---------------------------------------------------------------------------
-- ⚠ Granting is idempotent, because granting RESETS the meter
-- ---------------------------------------------------------------------------
-- A retried webhook that re-granted would hand her the whole allowance again.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  prj uuid := '22222222-2222-2222-2222-222222222222';
  gc  public.generation_credits%rowtype;
  pl  public.plans%rowtype;
  i   int; n int := 0;
begin
  reset role;
  update public.purchases set status = 'paid', paid_at = now()
   where stripe_checkout_session_id = 'cs_nora';

  assert public.grant_plan_allowance(prj, 'starter', 'evt_grant_1') is true,
         'the first grant did nothing';
  select * into gc from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222';
  assert gc.plan_tier = 'starter', 'the grant did not record the plan';
  assert gc.directions_generated = 0 and gc.regenerations_used = 0,
         'the grant did not reset the meter';

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  assert public.consume_generation_credit(kit) is true, 'the granted run was refused';
  reset role;

  assert public.grant_plan_allowance(prj, 'starter', 'evt_grant_1') is false,
         'a replayed grant was applied';
  select * into gc from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222';
  assert gc.directions_generated > 0,
         'a replayed grant reset the meter and handed the allowance back';
  assert (select count(*) from public.plan_grants where project_id = prj) = 1,
         'a replayed grant wrote a second row';

  update public.generation_credits set directions_generated = 0, regenerations_used = 0
   where project_id = '22222222-2222-2222-2222-222222222222';
  select * into pl from public.plans where tier = 'starter';
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  for i in 1 .. (pl.regenerations_limit + 3) loop
    if public.consume_generation_credit(kit) then n := n + 1; end if;
  end loop;
  assert n = 1 + pl.regenerations_limit,
    format('starter gave %s runs, the plan says 1 + %s', n, pl.regenerations_limit);
end
$$;

-- ⚠ A refund flips entitlement. It does NOT run the meter backwards.
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  prj uuid := '22222222-2222-2222-2222-222222222222';
  before_dirs  smallint;
  before_regen smallint;
begin
  reset role;
  select directions_generated, regenerations_used into before_dirs, before_regen
    from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222';
  assert before_dirs > 0, 'the fixture must have spent something first';

  perform public.record_purchase_status_event(
    (select id from public.purchases where stripe_checkout_session_id='cs_nora'),
    'evt_refund_meter','refunded','charge.refunded',7900);

  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  assert public.brand_kit_entitled(kit) is false, 'a refund did not remove entitlement';
  assert public.site_spec_get(kit)->'error'->>'code' = 'payment_required',
         'a refund did not close the deliverable';

  reset role;
  assert (select directions_generated from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222') = before_dirs
     and (select regenerations_used from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222') = before_regen,
         'a refund ran the meter backwards';
  assert (select plan_tier from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222') = 'starter',
         'a refund silently moved the project off its granted plan';

  -- ⚠ and a RE-PURCHASE grants again, because it is a different key
  insert into public.purchases
    (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
  values ('11111111-1111-1111-1111-111111111111', prj, 'starter','cs_nora_again',7900,'paid',now());
  assert public.grant_plan_allowance(prj, 'starter', 'evt_grant_2') is true,
         'a re-purchase did not grant again';
  assert (select directions_generated from public.generation_credits where project_id = '22222222-2222-2222-2222-222222222222') = 0,
         'the re-purchase did not reset the meter';
end
$$;

-- Granting is the webhook's, never the client's
do $$
declare ok boolean := false;
begin
  assert not has_function_privilege('authenticated',
    'public.grant_plan_allowance(uuid,text,text)'::regprocedure, 'EXECUTE'),
    'a signed-in client can grant herself an allowance';
  assert not has_function_privilege('anon',
    'public.grant_plan_allowance(uuid,text,text)'::regprocedure, 'EXECUTE'),
    'an anonymous caller can grant an allowance';

  reset role;
  begin
    perform public.grant_plan_allowance('22222222-2222-2222-2222-222222222222','platinum','k');
  exception when others then ok := true; end;
  assert ok, 'a tier that is not a plan was granted';
end
$$;

-- The plans table is readable, and writable by nobody
do $$
declare ok boolean := false; n int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  -- 5, not 4, since lot H added the practice_seats row
  -- (20260903170000_organization_entitlement.sql).
  assert (select count(*) from public.plans) = 5, 'she cannot read the plans';
  begin
    update public.plans set regenerations_limit = 999;
    get diagnostics n = row_count; ok := (n = 0);
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client rewrote the allowance table';
end
$$;

-- ⚠ Fails closed. Every reason to refuse is the same answer to the only
-- question being asked: may I spend a model call?
do $$
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  assert public.consume_generation_credit(null) is false, 'a null kit id consumed';
  assert public.consume_generation_credit('77777777-7777-7777-7777-777777777777') is false,
         'a stranger''s kit consumed from her allowance';
  set local request.jwt.claims = '{}';
  assert public.consume_generation_credit('33333333-3333-3333-3333-333333333333') is false,
         'a signed-out caller consumed';
end
$$;

-- ⚠ The decision and the write are ONE statement. Two concurrent callers cannot
-- both pass, because the second re-evaluates the WHERE against the row the
-- winner left behind. A `select` then an `if` then an `update` is the race this
-- replaces, so the shape is asserted, not just the outcome.
do $$
declare src text;
begin
  select p.prosrc into src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'consume_generation_credit';
  assert (select count(*) from regexp_matches(src, 'update public\.generation_credits', 'g')) = 1,
         'the allowance is written by more than one statement';
  assert src like '%returning true into v_consumed%',
         'the decision is no longer taken from the UPDATE itself';
end
$$;

-- ---------------------------------------------------------------------------
-- purchase_status_events — history, idempotency, and a won dispute
-- ---------------------------------------------------------------------------
do $$
declare
  pid uuid;
  applied boolean;
begin
  reset role;
  select id into pid from public.purchases where stripe_checkout_session_id = 'cs_nora';
  update public.purchases set status = 'paid', paid_at = now() where id = pid;

  -- a partial refund, then a dispute
  assert public.record_purchase_status_event(pid,'evt_1','partially_refunded','charge.refunded',1500)
         is true, 'the first event was not applied';
  assert (select status from public.purchases where id = pid) = 'partially_refunded',
         'the event did not advance the status';
  assert (select previous_status from public.purchase_status_events where stripe_event_id='evt_1')
         = 'paid', 'previous_status was not captured from the row';

  -- ⚠ IDEMPOTENT. Stripe retries; a retry must write nothing and move nothing.
  applied := public.record_purchase_status_event(pid,'evt_1','refunded','charge.refunded',4900);
  assert applied is false, 'a retried event was applied twice';
  assert (select status from public.purchases where id = pid) = 'partially_refunded',
         'a retried event moved the status';
  -- ⚠ scoped to the key under test: earlier blocks in this file have already
  -- written history for this purchase, and idempotency is a claim about the KEY.
  assert (select count(*) from public.purchase_status_events
           where purchase_id = pid and stripe_event_id = 'evt_1') = 1,
         'a retried event wrote a second row';

  perform public.record_purchase_status_event(pid,'evt_2','disputed','charge.dispute.created',4900);
  assert (select status from public.purchases where id = pid) = 'disputed',
         'the dispute did not take';

  -- ⚠ THE WHOLE POINT. A won dispute restores what was actually there before —
  -- which here is `partially_refunded`, NOT `paid`. One mutable column could not
  -- have answered this.
  assert public.purchase_status_before(pid, 'disputed') = 'partially_refunded',
         'the pre-dispute status was not recoverable from history';
  perform public.record_purchase_status_event(pid,'evt_3',
            public.purchase_status_before(pid,'disputed'), 'charge.dispute.closed', 4900);
  assert (select status from public.purchases where id = pid) = 'partially_refunded',
         'a won dispute did not restore the previous status';

  -- and the audit trail is all of it, in order
  assert (select array_agg(new_status order by occurred_at, created_at)
            from public.purchase_status_events
           where purchase_id = pid and stripe_event_id in ('evt_1','evt_2','evt_3'))
         = array['partially_refunded','disputed','partially_refunded'],
         'the history is not the sequence that happened';
end
$$;

-- Entitlement follows the history, transition by transition
do $$
declare
  kit uuid := '33333333-3333-3333-3333-333333333333';
  pid uuid;
  c   record;
  n   int := 0;
begin
  reset role;
  select id into pid from public.purchases where stripe_checkout_session_id = 'cs_nora';

  -- ⚠ ANY entitling purchase entitles. The re-purchase from the refund block is
  -- still paid, so the kit is open even while `cs_nora` is refunded — assert
  -- that, then take it out of the way so the sequence below tests one purchase.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  assert public.brand_kit_entitled(kit) is true,
         'a later paid purchase did not keep the kit open';
  reset role;
  update public.purchases set status = 'failed', paid_at = null
   where stripe_checkout_session_id = 'cs_nora_again';

  for c in select * from (values
      ('paid',               true),
      ('partially_refunded', true),
      ('disputed',           false),
      ('refunded',           false),
      ('paid',               true),
      ('failed',             false)) as v(st, want)
  loop
    n := n + 1;
    reset role;
    perform public.record_purchase_status_event(pid, 'evt_seq_' || n, c.st, 'test.event', 4900);
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
    assert public.brand_kit_entitled(kit) is not distinct from c.want,
      format('after %s the kit was %s', c.st,
             case when public.brand_kit_entitled(kit) then 'entitled' else 'not entitled' end);
  end loop;
end
$$;

-- ⚠ Append-only means a client cannot rewrite the audit trail
do $$
declare ok boolean := false; n int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

  assert (select count(*) from public.purchase_status_events) > 0,
         'she must be able to read her own history';
  assert (select count(*) from public.purchase_status_events e
            join public.purchases p on p.id = e.purchase_id
           where p.user_id <> '11111111-1111-1111-1111-111111111111') = 0,
         'a stranger''s purchase history was readable';

  begin
    update public.purchase_status_events set new_status = 'paid';
    get diagnostics n = row_count; ok := (n = 0);
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client rewrote the audit trail';

  begin
    ok := false;
    delete from public.purchase_status_events;
    get diagnostics n = row_count; ok := (n = 0);
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a client deleted the audit trail';
end
$$;

-- paid_at survives the statuses that imply money was captured, and only those
do $$
declare pid uuid;
begin
  reset role;
  select id into pid from public.purchases where stripe_checkout_session_id = 'cs_nora';
  perform public.record_purchase_status_event(pid,'evt_pa1','paid','x',4900);
  assert (select paid_at from public.purchases where id = pid) is not null, 'paid lost paid_at';
  perform public.record_purchase_status_event(pid,'evt_pa2','refunded','x',4900);
  assert (select paid_at from public.purchases where id = pid) is not null,
         'a refund erased the record that money was ever taken';
  perform public.record_purchase_status_event(pid,'evt_pa3','pending','x',null);
  assert (select paid_at from public.purchases where id = pid) is null,
         'a pending purchase kept a payment timestamp';
end
$$;

rollback;
