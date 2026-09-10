-- ============================================================================
-- Tests — 20260910102753_content_items_theme.sql
-- ============================================================================
-- The theme is the month's, and `category` is hers. The whole point of the
-- column is that those two cannot be confused, so that is what is tested:
-- a theme the month declares, one it does not, one with no month at all, an
-- item of hers with neither, and the editor's inability to re-theme anything.
-- ============================================================================
begin;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-0000000000c1','th@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-0000000000c1','P');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000c1','bbbbbbbb-0000-0000-0000-0000000000c1');
insert into public.purchases
  (user_id, project_id, tier, stripe_checkout_session_id, amount_cents, status, paid_at)
values ('aaaaaaaa-0000-0000-0000-0000000000c1','bbbbbbbb-0000-0000-0000-0000000000c1',
        'practice','cs_test_theme_c1', 24900, 'paid', now());
insert into public.content_months (id, brand_kit_id, month, themes, status)
values ('dddddddd-0000-0000-0000-0000000000c1','cccccccc-0000-0000-0000-0000000000c1',
        '2026-10-01', array['rest','returning to routine','asking for help'], 'proposed');

do $$
declare v_ok boolean;
begin
  -- 1. A theme the month declares is accepted, and reads back.
  insert into public.content_items (id, brand_kit_id, month_id, theme, archetype, status)
  values ('eeeeeeee-0000-0000-0000-0000000000c1','cccccccc-0000-0000-0000-0000000000c1',
          'dddddddd-0000-0000-0000-0000000000c1','rest','statement','proposed');
  assert public.content_item_json('eeeeeeee-0000-0000-0000-0000000000c1') ->> 'theme' = 'rest',
         'a valid theme did not survive the round trip';

  -- 2. One it does not declare is refused. Without this, the post renders in
  --    no group at all on the review screen -- silently.
  v_ok := false;
  begin
    insert into public.content_items (brand_kit_id, month_id, theme, archetype, status)
    values ('cccccccc-0000-0000-0000-0000000000c1','dddddddd-0000-0000-0000-0000000000c1',
            'invented','statement','proposed');
  exception when check_violation then v_ok := true;
  end;
  assert v_ok, 'a theme outside the month was accepted';

  -- 3. A theme with no month has nothing to be checked against.
  v_ok := false;
  begin
    insert into public.content_items (brand_kit_id, theme, archetype, status)
    values ('cccccccc-0000-0000-0000-0000000000c1','rest','statement','proposed');
  exception when check_violation then v_ok := true;
  end;
  assert v_ok, 'a theme with no month was accepted';

  -- 4. Her own items, with no theme at all, are unaffected -- which is every
  --    item in production today.
  insert into public.content_items (brand_kit_id, archetype, status, title)
  values ('cccccccc-0000-0000-0000-0000000000c1','notes','draft','Hers');

  -- 5. ⚠ THE EDITOR CANNOT RE-THEME A POST. A post re-themed after its ground
  --    exists would compose on a photograph about something else.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-0000000000c1"}';
  assert public.update_content_item('eeeeeeee-0000-0000-0000-0000000000c1',
           '{"theme":"asking for help"}'::jsonb) -> 'error' ->> 'code' = 'unknown_field',
         'the editor could re-theme a post';

  -- …and `category` stays hers, free text, editable, and unrelated.
  assert public.update_content_item('eeeeeeee-0000-0000-0000-0000000000c1',
           '{"category":"Anything she likes"}'::jsonb) ? 'saved_at',
         'category stopped being hers';
  reset role;
end $$;

rollback;
