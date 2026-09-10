-- ============================================================================
-- Tests — 20260910144421_content_months_theme_source.sql
-- ============================================================================
-- One question: can a month exist whose themes came from nowhere in particular?
-- If it can, a hand-typed test run is indistinguishable from a derived one, and
-- somebody eventually cites the first as evidence for the second.
-- ============================================================================
begin;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-0000000000d1','ts@example.com');
insert into public.projects (id, user_id, name) values
  ('bbbbbbbb-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-0000000000d1','P');
insert into public.brand_kits (id, project_id) values
  ('cccccccc-0000-0000-0000-0000000000d1','bbbbbbbb-0000-0000-0000-0000000000d1');

do $$
declare v_ok boolean;
begin
  -- 1. The purchase queue's row: no themes, no source. Legal, and it must be —
  --    `queueFirstContentMonth` writes it before anything has been derived.
  insert into public.content_months (brand_kit_id, month, themes, status)
  values ('cccccccc-0000-0000-0000-0000000000d1','2026-10-01', '{}', 'generating');

  -- 2. Themes with no source: refused.
  v_ok := false;
  begin
    insert into public.content_months (brand_kit_id, month, themes, status)
    values ('cccccccc-0000-0000-0000-0000000000d1','2026-11-01', array['a','b','c'], 'proposed');
  exception when check_violation then v_ok := true;
  end;
  assert v_ok, 'themes with no source were accepted';

  -- 3. An invented source: refused. The three values are a closed set.
  v_ok := false;
  begin
    insert into public.content_months (brand_kit_id, month, themes, status, theme_source)
    values ('cccccccc-0000-0000-0000-0000000000d1','2026-11-01', array['a','b','c'], 'proposed', 'vibes');
  exception when check_violation then v_ok := true;
  end;
  assert v_ok, 'an invented theme_source was accepted';

  -- 4. The three real ones, and the sentence kept VERBATIM. Reviewing a month
  --    means asking whether the themes follow from what she said, and that
  --    cannot be answered from the themes alone.
  insert into public.content_months (brand_kit_id, month, themes, status, theme_source, theme_source_text)
  values ('cccccccc-0000-0000-0000-0000000000d1','2026-11-01', array['a','b','c'], 'proposed',
          'derived_check_in', 'Burnout, mostly. A lot of people going back to work.');
  insert into public.content_months (brand_kit_id, month, themes, status, theme_source)
  values ('cccccccc-0000-0000-0000-0000000000d1','2026-12-01', array['a','b','c'], 'proposed', 'derived_brief');
  insert into public.content_months (brand_kit_id, month, themes, status, theme_source)
  values ('cccccccc-0000-0000-0000-0000000000d1','2027-01-01', array['a','b','c'], 'proposed', 'supplied');

  assert (select theme_source_text from public.content_months
           where brand_kit_id='cccccccc-0000-0000-0000-0000000000d1' and month='2026-11-01')
         = 'Burnout, mostly. A lot of people going back to work.',
         'the source sentence did not survive verbatim';

  -- 5. The queue's empty row can be filled in later, which is the whole flow:
  --    purchase writes it, the cron derives and completes it.
  update public.content_months
     set themes = array['x','y','z'], theme_source = 'derived_brief', status = 'proposed'
   where brand_kit_id='cccccccc-0000-0000-0000-0000000000d1' and month='2026-10-01';
end $$;

rollback;
