-- ============================================================================
-- Tests — 20260827105000_monthly_content_calendar.sql
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('dddddddd-0000-0000-0000-000000000001','sub@example.com'),
  ('dddddddd-0000-0000-0000-000000000002','free@example.com'),
  ('dddddddd-0000-0000-0000-000000000003','stranger@example.com');
insert into public.projects (id, user_id, name) values
  ('eeeeeeee-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001','Subscriber'),
  ('eeeeeeee-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000002','Free');
insert into public.brand_kits (id, project_id) values
  ('ffffffff-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001'),
  ('ffffffff-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002');

-- ---------------------------------------------------------------------------
-- Exactly one table holds monthly content
-- ---------------------------------------------------------------------------
do $$
begin
  assert to_regclass('public.monthly_presence_content') is not null,
         'monthly_presence_content is missing';
  assert to_regclass('public.content_calendar_items') is null,
         'content_calendar_items exists as well; there must be exactly one monthly content table';
  assert not exists (select 1 from information_schema.columns
                      where table_schema='public' and table_name='monthly_presence_content'
                        and column_name in ('project_id','content')),
         'the one-row-per-month columns survived the reshape';
end
$$;

-- ---------------------------------------------------------------------------
-- Non-subscriber: 16 items, 12 posts + 4 stories, exactly ONE ready
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.ensure_month_skeleton('dddddddd-0000-0000-0000-000000000002','2026-09-01') = 16,
         'a fresh month must create 16 slots';

  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002' and month='2026-09-01' and type='post') = 12,
         'a month must hold 12 posts';
  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002' and month='2026-09-01' and type='story') = 4,
         'a month must hold 4 stories';
  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002' and month='2026-09-01' and status='ready') = 1,
         'a non-subscriber must get exactly one unlocked item';
  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002' and month='2026-09-01' and status='locked') = 15,
         'a non-subscriber must get fifteen locked items';
end
$$;

-- ---------------------------------------------------------------------------
-- IDEMPOTENCE: two runs, no duplicates, no lost work
-- ---------------------------------------------------------------------------
do $$
begin
  update public.monthly_presence_content set title = 'Rest is not a reward.'
   where user_id='dddddddd-0000-0000-0000-000000000002' and month='2026-09-01' and status='ready';

  assert public.ensure_month_skeleton('dddddddd-0000-0000-0000-000000000002','2026-09-01') = 0,
         'a second run must insert nothing';
  assert public.ensure_month_skeleton('dddddddd-0000-0000-0000-000000000002','2026-09-01') = 0,
         'a third run must insert nothing';
  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002' and month='2026-09-01') = 16,
         'repeated runs produced duplicates';
  assert (select title from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002' and month='2026-09-01' and status='ready')
         = 'Rest is not a reward.',
         'a re-run overwrote content the frontend had already written';
end
$$;

-- ---------------------------------------------------------------------------
-- Subscriber: the whole month opens up
-- ---------------------------------------------------------------------------
do $$
begin
  insert into public.subscriptions (user_id, stripe_subscription_id, status)
  values ('dddddddd-0000-0000-0000-000000000001','sub_test_1','active');

  perform public.ensure_month_skeleton('dddddddd-0000-0000-0000-000000000001','2026-09-01');
  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000001' and month='2026-09-01' and status='draft') = 16,
         'a subscriber must get all sixteen items opened';
  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000001' and month='2026-09-01' and status='locked') = 0,
         'a subscriber must not get locked items';
end
$$;

-- ---------------------------------------------------------------------------
-- Every day used exists in February
-- ---------------------------------------------------------------------------
do $$
begin
  perform public.ensure_month_skeleton('dddddddd-0000-0000-0000-000000000002','2027-02-01');
  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002' and month='2027-02-01') = 16,
         'February must get the same sixteen items as any other month';
  assert (select max(day_of_month) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002') <= 28,
         'the skeleton used a day that does not exist in every month';
end
$$;

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
do $$
declare
  rejected boolean;
begin
  -- a month that is not a first of month
  begin
    perform public.ensure_month_skeleton('dddddddd-0000-0000-0000-000000000002','2026-09-15');
    rejected := false;
  exception when others then rejected := true; end;
  assert rejected, 'a mid-month date was accepted as a month';

  -- a user with no brand kit has no identity to decline into content
  begin
    perform public.ensure_month_skeleton('dddddddd-0000-0000-0000-000000000003','2026-09-01');
    rejected := false;
  exception when others then rejected := true; end;
  assert rejected, 'a month was seeded for a user with no brand kit';

  -- THE PAYWALL CONSTRAINT: a locked row must carry nothing that is withheld
  begin
    update public.monthly_presence_content set caption = 'the withheld copy'
     where user_id='dddddddd-0000-0000-0000-000000000002' and status='locked';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'a locked row was allowed to carry a caption; blur is not a paywall';

  begin
    update public.monthly_presence_content set visual_spec = '{"a":1}'::jsonb
     where user_id='dddddddd-0000-0000-0000-000000000002' and status='locked';
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'a locked row was allowed to carry a visual spec';

  -- published implies dated, and vice versa
  begin
    update public.monthly_presence_content set status = 'published'
     where user_id='dddddddd-0000-0000-0000-000000000001' and month='2026-09-01' and day_of_month=1;
    rejected := false;
  exception when check_violation then rejected := true; end;
  assert rejected, 'an item was published without a publication date';
end
$$;

-- ---------------------------------------------------------------------------
-- calendar_summary
-- ---------------------------------------------------------------------------
do $$
declare
  s jsonb := public.calendar_summary('dddddddd-0000-0000-0000-000000000002','2026-09-01');
begin
  assert s ?& array['items','ready_count','locked_count'], 'calendar_summary is missing a documented key';
  assert jsonb_array_length(s->'items') = 16, 'calendar_summary must return all sixteen items';
  assert (s->>'ready_count')::int = 1,        'calendar_summary ready_count is wrong';
  assert (s->>'locked_count')::int = 15,      'calendar_summary locked_count is wrong';
  assert s->'items'->0 ?& array['id','month','day_of_month','type','status','title','caption','visual_spec','published_at'],
         'a calendar item is missing a documented key';
  -- render order
  assert (s->'items'->0->>'day_of_month')::int <= (s->'items'->1->>'day_of_month')::int,
         'calendar_summary items are not in render order';
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: a second user sees nothing, and cannot manufacture a month
-- ---------------------------------------------------------------------------
do $$
declare
  blocked boolean;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"dddddddd-0000-0000-0000-000000000003"}';

  assert (select count(*) from public.monthly_presence_content
           where user_id='dddddddd-0000-0000-0000-000000000002') = 0,
         'a stranger could select another user''s monthly content';
  assert jsonb_array_length(
           public.calendar_summary('dddddddd-0000-0000-0000-000000000002','2026-09-01')->'items') = 0,
         'calendar_summary leaked another user''s month';

  -- and the free content cannot be self-served
  begin
    perform public.ensure_month_skeleton('dddddddd-0000-0000-0000-000000000003','2026-10-01');
    blocked := false;
  exception when others then blocked := true; end;
  assert blocked, 'an authenticated user seeded a month for themselves';
end
$$;

rollback;
