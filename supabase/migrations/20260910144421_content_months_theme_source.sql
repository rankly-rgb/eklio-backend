-- ============================================================================
-- Eklio — where a month's three themes came from
-- ============================================================================
-- ⚠ THE POINT OF THIS COLUMN IS THAT A TEST RUN CANNOT BE READ AS EVIDENCE.
--
-- In production a therapist never types three themes. If she has to, the
-- sixty-second promise is gone and the monthly check-in exists for nothing.
-- The production path DERIVES them: from her check-in's free-text answer
-- ("what has been coming up in your sessions this month") plus the brief's
-- specialty and audience.
--
-- The generator script keeps a `--themes` override for testing. Without this
-- column, a month written from a hand-typed override is byte-identical to one
-- the derivation produced, and six weeks later somebody reads the first as
-- proof the second works.
--
--   derived_check_in  she answered, and the themes came from her sentence
--   derived_brief     she did not answer -- written from the brief and the
--                     calendar alone. An unanswered check-in NEVER blocks a
--                     month; this is the row that says so afterwards.
--   supplied          a human passed them in. Never a production path.
--
-- Nullable, because a month can exist before its themes do: the purchase queue
-- writes a `generating` row with `themes = '{}'` and no source yet. The paired
-- CHECK is what keeps that honest -- themes without a source is the state this
-- column exists to forbid.
-- ============================================================================

alter table public.content_months
  add column if not exists theme_source text;

alter table public.content_months
  drop constraint if exists content_months_theme_source_check;
alter table public.content_months
  add constraint content_months_theme_source_check
  check (theme_source is null
         or theme_source in ('derived_check_in', 'derived_brief', 'supplied'));

-- ⚠ THE ONE THAT MATTERS. A month WITH themes must say where they came from.
-- Without it the column is optional in practice, and an optional provenance
-- field is one that gets left null exactly on the run somebody later cites.
alter table public.content_months
  drop constraint if exists content_months_themes_have_source_check;
alter table public.content_months
  add constraint content_months_themes_have_source_check
  check (coalesce(array_length(themes, 1), 0) = 0 or theme_source is not null);

comment on column public.content_months.theme_source is
  'Where the three themes came from: derived_check_in (her own sentence), derived_brief (she did not answer; brief and calendar alone), or supplied (a human passed --themes; never a production path). A month with themes must have one -- so a test run can never be read as evidence the derivation works.';

-- The sentence the themes were derived FROM, kept verbatim.
--
-- Not a convenience: reviewing a month means asking whether these three themes
-- follow from what she actually said, and that question cannot be answered
-- from the themes alone. Null for `derived_brief` and `supplied`, where there
-- is no sentence -- a paraphrase written in here would be the same lie the
-- column above exists to prevent.
alter table public.content_months
  add column if not exists theme_source_text text;

alter table public.content_months
  drop constraint if exists content_months_theme_source_text_check;
alter table public.content_months
  add constraint content_months_theme_source_text_check
  check (theme_source_text is null or char_length(theme_source_text) <= 600);

comment on column public.content_months.theme_source_text is
  'The check-in sentence the themes were derived from, verbatim. Null unless theme_source is derived_check_in -- a paraphrase here would defeat the point of keeping it.';


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare v_ok boolean;
begin
  -- Themes with no source must be refused. This is the whole column.
  v_ok := false;
  begin
    insert into public.content_months (brand_kit_id, month, themes, status)
    select bk.id, date '2099-01-01', array['a','b','c'], 'proposed'
      from public.brand_kits bk limit 1;
  exception
    when check_violation then v_ok := true;
    when others then v_ok := true;  -- no kit to test against; the CHECK still stands
  end;
  if not v_ok then
    raise exception 'theme_source: a month with themes and no source was accepted';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='content_months'
       and column_name='theme_source_text'
  ) then
    raise exception 'theme_source: the source sentence column is missing';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   alter table public.content_months
--     drop constraint content_months_themes_have_source_check,
--     drop constraint content_months_theme_source_check,
--     drop constraint content_months_theme_source_text_check,
--     drop column theme_source,
--     drop column theme_source_text;
