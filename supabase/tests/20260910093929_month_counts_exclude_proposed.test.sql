-- ============================================================================
-- Tests — 20260910093929_month_counts_exclude_proposed.sql
-- ============================================================================
-- The point: a generated month must not report work she has never read as
-- work she has done. `items` still carries the proposals -- we stop counting
-- her content, we never hide it.
-- ============================================================================
begin;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-0000000000f1','o@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000f1','aaaaaaaa-0000-0000-0000-0000000000f1','P');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000f1','bbbbbbbb-0000-0000-0000-0000000000f1');
-- content_kit_access refuses an unpaid kit; a `paid` row must carry paid_at.
insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-0000000000f1','bbbbbbbb-0000-0000-0000-0000000000f1',
        'practice','cs_counts_f1', 14900, 'paid', now());

-- Eklio's work: three proposals, dated inside the month.
insert into public.content_items (brand_kit_id, archetype, status, register, scheduled_for, alt_text)
select 'cccccccc-0000-0000-0000-0000000000f1','statement','proposed','named_feeling',
       date '2026-10-06' + (n || ' days')::interval, 'A ceramic bowl.'
  from generate_series(0,2) as n;

-- Her work: one draft, one ready.
insert into public.content_items (brand_kit_id, archetype, status, scheduled_for, alt_text)
values ('cccccccc-0000-0000-0000-0000000000f1','notes','draft', date '2026-10-20', null),
       ('cccccccc-0000-0000-0000-0000000000f1','question','ready', date '2026-10-21', 'A window.');

do $$
declare r jsonb; c jsonb;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000f1"}';
  r := public.get_content_month('cccccccc-0000-0000-0000-0000000000f1','2026-10-01');
  c := r -> 'counts';

  assert (c ->> 'proposed')::int = 3, format('proposed should be 3: %s', c);
  -- ⚠ THE POINT.
  assert (c ->> 'scheduled')::int = 2, format('scheduled must exclude proposals: %s', c);
  assert (c ->> 'ready')::int = 1,     format('ready: %s', c);
  assert (c ->> 'posted')::int = 0,    format('posted: %s', c);
  -- All five still render.
  assert jsonb_array_length(r -> 'items') = 5,
         format('items should be 5, got %s', jsonb_array_length(r -> 'items'));
end $$;

rollback;
