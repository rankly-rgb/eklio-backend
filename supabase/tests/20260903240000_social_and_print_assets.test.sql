-- ============================================================================
-- Tests — 20260903240000_social_and_print_assets.sql
-- ============================================================================
begin;

do $$
declare
  v_kind text;
  v_width int;
  v_height int;
  v_group text;
begin
  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'post_statement_1080';
  assert v_kind = 'png' and v_width = 1080 and v_height = 1080 and v_group = 'social',
    'post_statement_1080: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'post_question_1080';
  assert v_kind = 'png' and v_width = 1080 and v_height = 1080 and v_group = 'social',
    'post_question_1080: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'post_notes_1080';
  assert v_kind = 'png' and v_width = 1080 and v_height = 1080 and v_group = 'social',
    'post_notes_1080: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'post_signature_1080';
  assert v_kind = 'png' and v_width = 1080 and v_height = 1080 and v_group = 'social',
    'post_signature_1080: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'story_1080x1920';
  assert v_kind = 'png' and v_width = 1080 and v_height = 1920 and v_group = 'social',
    'story_1080x1920: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'cover_linkedin_1584x396';
  assert v_kind = 'png' and v_width = 1584 and v_height = 396 and v_group = 'social',
    'cover_linkedin_1584x396: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'cover_facebook_1640x624';
  assert v_kind = 'png' and v_width = 1640 and v_height = 624 and v_group = 'social',
    'cover_facebook_1640x624: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'business_card_front';
  assert v_kind = 'png' and v_width = 1125 and v_height = 675 and v_group = 'print',
    'business_card_front: unexpected shape';

  select kind, width, height, "group" into v_kind, v_width, v_height, v_group
    from public.asset_catalog where key = 'business_card_back';
  assert v_kind = 'png' and v_width = 1125 and v_height = 675 and v_group = 'print',
    'business_card_back: unexpected shape';
end
$$;

do $$
declare v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
  select count(*) into v_count from public.asset_catalog
    where key in (
      'post_statement_1080', 'post_question_1080', 'post_notes_1080',
      'post_signature_1080', 'story_1080x1920', 'cover_linkedin_1584x396',
      'cover_facebook_1640x624', 'business_card_front', 'business_card_back'
    );
  reset role;
  assert v_count = 9, format('expected all nine new keys visible to an authenticated caller, got %s', v_count);
end
$$;

rollback;
