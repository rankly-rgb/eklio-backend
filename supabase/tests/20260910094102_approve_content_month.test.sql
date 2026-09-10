-- ============================================================================
-- Tests — 20260910094102_approve_content_month.sql
-- ============================================================================
-- The case that matters most is the fourth item: a proposal she dragged into
-- NOVEMBER before approving October. It belongs to October's plan and must
-- move with it. Selecting by date would strand it, `proposed` forever.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000ab01','o@example.com'),
  ('aaaaaaaa-0000-0000-0000-00000000ab02','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-00000000ab01','aaaaaaaa-0000-0000-0000-00000000ab01','P');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-00000000ab01','bbbbbbbb-0000-0000-0000-00000000ab01');
insert into public.purchases (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-00000000ab01','bbbbbbbb-0000-0000-0000-00000000ab01',
        'practice','cs_ab01',14900,'paid',now());
insert into public.content_months (id, brand_kit_id, month, themes, status)
values ('dddddddd-0000-0000-0000-00000000ab01','cccccccc-0000-0000-0000-00000000ab01',
        '2026-10-01',array['a','b','c'],'proposed');

-- Three proposals inside the month, plus ONE dragged into November.
insert into public.content_items (brand_kit_id, month_id, archetype, status, register, scheduled_for, alt_text)
values ('cccccccc-0000-0000-0000-00000000ab01','dddddddd-0000-0000-0000-00000000ab01','statement','proposed','named_feeling','2026-10-06','A bowl.'),
       ('cccccccc-0000-0000-0000-00000000ab01','dddddddd-0000-0000-0000-00000000ab01','notes','proposed','practical_note','2026-10-13','A door.'),
       ('cccccccc-0000-0000-0000-00000000ab01','dddddddd-0000-0000-0000-00000000ab01','question','proposed','reflective_question','2026-10-20','A chair.'),
       ('cccccccc-0000-0000-0000-00000000ab01','dddddddd-0000-0000-0000-00000000ab01','statement','proposed','permission','2026-11-03','A wall.');
-- One of HER drafts, which approval must not touch.
insert into public.content_items (brand_kit_id, archetype, status, scheduled_for)
values ('cccccccc-0000-0000-0000-00000000ab01','notes','draft','2026-10-27');

do $$
declare r jsonb;
begin
  set local role authenticated;

  -- A stranger gets not_found, never a hint that this month exists.
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-00000000ab02"}';
  r := public.approve_content_month('dddddddd-0000-0000-0000-00000000ab01');
  assert r -> 'error' ->> 'code' = 'not_found', format('a stranger got past: %s', r);

  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-00000000ab01"}';
  r := public.approve_content_month('dddddddd-0000-0000-0000-00000000ab01');
  -- ⚠ FOUR, including the one dragged into November.
  assert (r ->> 'moved')::int = 4, format('expected 4 moved incl. the dragged one: %s', r);

  assert (select count(*) from public.content_items
           where month_id='dddddddd-0000-0000-0000-00000000ab01' and status='proposed') = 0;
  assert (select count(*) from public.content_items
           where month_id='dddddddd-0000-0000-0000-00000000ab01' and status='draft') = 4;
  assert (select status from public.content_months
           where id='dddddddd-0000-0000-0000-00000000ab01') = 'approved';

  -- Her own draft, which belongs to no plan, is untouched.
  assert (select count(*) from public.content_items
           where brand_kit_id='cccccccc-0000-0000-0000-00000000ab01'
             and month_id is null and status='draft') = 1;

  -- Idempotent: a replay moves nothing and still succeeds.
  r := public.approve_content_month('dddddddd-0000-0000-0000-00000000ab01');
  assert (r ->> 'moved')::int = 0, format('replay should move 0: %s', r);
  assert r ? 'approved_at', format('replay should still succeed: %s', r);
end $$;

rollback;
