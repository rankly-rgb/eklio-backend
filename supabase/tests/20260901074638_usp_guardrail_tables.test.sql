-- ============================================================================
-- Tests — 20260901074638_usp_guardrail_tables.sql
-- ============================================================================
begin;

do $$
begin
  assert (select count(*) from public.banned_phrases) = 30, 'banned_phrases must hold exactly 30 seeded rows';
  assert (select count(*) from public.usp_stopwords) >= 100, 'usp_stopwords must hold the English list plus 7 domain words';
  assert (select value from public.app_settings where key = 'usp_similarity_threshold') = '0.55'::jsonb,
    'usp_similarity_threshold must default to 0.55';
end
$$;

-- ---------------------------------------------------------------------------
-- unique index on lower(phrase) -- a duplicate under different casing is
-- rejected, not silently duplicated.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    insert into public.banned_phrases (phrase, category) values ('SAFE SPACE', 'directory_cliche');
    raise exception 'FAIL: a case-different duplicate phrase was accepted';
  exception when unique_violation then
    raise notice 'OK: lower(phrase) uniqueness rejects a case-different duplicate';
  end;
end
$$;

-- ---------------------------------------------------------------------------
-- category CHECK
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    insert into public.banned_phrases (phrase, category) values ('made up phrase', 'not_a_real_category');
    raise exception 'FAIL: an unknown category was accepted';
  exception when check_violation then
    raise notice 'OK: banned_phrases_category_check rejects an unknown category';
  end;
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: none of the three are readable by authenticated (RLS lockdown +
-- privileges revoked, matching the stripe_events pattern).
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
begin
  begin
    perform 1 from public.banned_phrases limit 1;
    raise exception 'FAIL: authenticated could select from banned_phrases';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated blocked from banned_phrases';
  end;

  begin
    perform 1 from public.usp_stopwords limit 1;
    raise exception 'FAIL: authenticated could select from usp_stopwords';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated blocked from usp_stopwords';
  end;

  begin
    perform 1 from public.app_settings limit 1;
    raise exception 'FAIL: authenticated could select from app_settings';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated blocked from app_settings';
  end;
end
$$;

reset role;
rollback;
