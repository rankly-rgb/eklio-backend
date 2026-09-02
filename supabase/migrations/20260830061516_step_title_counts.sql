-- ============================================================================
-- Eklio — a step title that counts must count correctly
-- ============================================================================
-- Follows `20260829116000_etag_completeness.sql`.
--
-- WHAT WAS WRONG
-- --------------
-- Step 2 of the setup sheet was titled **"Set your five colors"** and carried
-- six values: primary, secondary, accent, page background, section background,
-- dark neutral. The title was written when the spec had five colour tokens;
-- `20260829113000_site_spec_paper.sql` restored `paper` and made it six, and
-- nothing compared the title to the list underneath it.
--
-- Step 3 had the same shape of problem for a different reason: **"Set your two
-- fonts"** over three values — heading font, body font, and the Google Fonts
-- stylesheet. Two of those are fonts and one is a URL, so the sentence was
-- defensible and the number still disagreed with the list.
--
-- THE FIX, AND THE GUARD RAIL
-- ---------------------------
-- Step 2 becomes "Set your six colors" — the count is genuinely useful there,
-- it tells her how many swatches to expect before she starts. Step 3 becomes
-- "Set your fonts", because no count is true of a list that mixes two faces and
-- a stylesheet.
--
-- ⚠ AND A COUNT IN A STEP TITLE IS NOW CHECKED. `site_output_step_title_count`
-- reads the number out of a title, in digits or in words, and the guard rail
-- below compares it to the length of that step's own `values` array — for every
-- builder, on a real spec. Add a seventh token and this migration's descendants
-- fail; the alternative is a therapist counting five and finding six.
--
-- Only TITLES are checked, deliberately. Bodies legitimately contain numbers
-- that count nothing in `values` — "one block per field", "One destination, on
-- every page" — and a rule that flagged those would be turned off within a
-- month.
-- ============================================================================


-- ============================================================================
-- 1. The two fragments
-- ============================================================================
-- ⚠ MIRRORED IN `supabase/seed.sql`, AFTER the block from
-- `20260829110000_site_output_templates.sql` that carries their old wording.
-- Order matters: mirrored before it, a local `db reset` would silently put
-- "five" back.
--
--   awk '/^-- >>> STEP TITLE DATA/,/^-- <<< STEP TITLE DATA/' \
--     supabase/migrations/20260829117000_step_title_counts.sql \
--     > /tmp/step-titles.sql

-- >>> STEP TITLE DATA (mirrored verbatim in supabase/seed.sql) >>>

update public.site_output_templates
   set body = 'Set your six colors'   where id = 'all.sheet.step2_title';
update public.site_output_templates
   set body = 'Set your fonts'        where id = 'all.sheet.step3_title';

-- <<< STEP TITLE DATA <<<


-- ============================================================================
-- 2. Reading a count out of a title
-- ============================================================================
-- Returns NULL when the title states no count, which is the normal case and is
-- not a failure. Words up to twelve plus bare digits: a step title that needs
-- "thirteen" has other problems.

create or replace function public.site_output_step_title_count(p_title text)
returns int
language sql
immutable
set search_path = ''
as $$
  select case lower(coalesce(substring(p_title from '\m(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\M'), ''))
    when ''       then null
    when 'one'    then 1  when 'two'    then 2  when 'three'  then 3
    when 'four'   then 4  when 'five'   then 5  when 'six'    then 6
    when 'seven'  then 7  when 'eight'  then 8  when 'nine'   then 9
    when 'ten'    then 10 when 'eleven' then 11 when 'twelve' then 12
    else (substring(p_title from '\m(\d+)\M'))::int
  end
$$;

comment on function public.site_output_step_title_count(text) is
  'The count a setup-sheet step title states, in digits or words, or NULL when it states none. Used by the guard rail that keeps a title from disagreeing with its own values list.';

grant execute on function public.site_output_step_title_count(text) to authenticated, service_role;


-- ============================================================================
-- 3. Guard rails
-- ============================================================================
do $$
declare
  spec  jsonb;
  t     text;
  s     record;
  n     int;
  bad   int := 0;
begin
  -- the reader itself
  if public.site_output_step_title_count('Set your six colors') <> 6 then
    raise exception 'step_title_counts: the word "six" was not read.';
  end if;
  if public.site_output_step_title_count('Set your 6 colors') <> 6 then
    raise exception 'step_title_counts: the digit 6 was not read.';
  end if;
  if public.site_output_step_title_count('Set your fonts') is not null then
    raise exception 'step_title_counts: a title with no count returned one.';
  end if;
  -- ⚠ a word that merely contains a number word must not match
  if public.site_output_step_title_count('Before you publish') is not null then
    raise exception 'step_title_counts: "Before" was read as a count.';
  end if;
  if public.site_output_step_title_count('Point the button at your booking link') is not null then
    raise exception 'step_title_counts: a plain title was read as a count.';
  end if;

  spec := jsonb_build_object(
    'primary_hex','#B4674A','secondary_hex','#C08A3E','accent_hex','#6E3320',
    'light_neutral_hex','#F4EEE3','dark_neutral_hex','#2B2A27','paper_hex','#FAF6EE',
    'heading_font','Fraunces','body_font','Nunito Sans',
    'google_fonts_url','https://fonts.googleapis.com/css2?family=Fraunces&display=swap',
    'about_excerpt','x','practice_details','{}'::jsonb,
    'hero', jsonb_build_object('overline','o','headline','h','subhead','s',
                               'cta_label','c','cta_target_url','https://x.example/book'),
    'pages', public.site_spec_default_pages(array['Anxiety'], array['Adults']),
    'extra_instructions','A note.');

  -- ⚠ THE ASSERTION. Every step of every setup-sheet builder: a title that
  -- states a number must state its own values length.
  foreach t in array array['squarespace', 'wix', 'webflow'] loop
    for s in
      select (v.value->>'n')::int          as n,
             v.value->>'title'             as title,
             jsonb_array_length(v.value->'values') as values_len
        from jsonb_array_elements(public.site_spec_output(spec, t)->'steps') as v
    loop
      n := public.site_output_step_title_count(s.title);
      if n is not null and n <> s.values_len then
        raise warning '%: step % titled "%" states % but carries % value(s).',
          t, s.n, s.title, n, s.values_len;
        bad := bad + 1;
      end if;
    end loop;
  end loop;

  if bad > 0 then
    raise exception
      'step_title_counts: % step title(s) state a count that disagrees with their own values list. Either correct the title or stop counting in it.', bad;
  end if;

  -- and the two that were wrong are now right, explicitly
  if (select v.value->>'title' from jsonb_array_elements(
        public.site_spec_output(spec, 'squarespace')->'steps') v
       where (v.value->>'n')::int = 2) <> 'Set your six colors' then
    raise exception 'step_title_counts: step 2 was not corrected.';
  end if;
  if (select jsonb_array_length(v.value->'values') from jsonb_array_elements(
        public.site_spec_output(spec, 'squarespace')->'steps') v
       where (v.value->>'n')::int = 2) <> 6 then
    raise exception 'step_title_counts: step 2 no longer carries six values.';
  end if;
  if (select v.value->>'title' from jsonb_array_elements(
        public.site_spec_output(spec, 'squarespace')->'steps') v
       where (v.value->>'n')::int = 3) <> 'Set your fonts' then
    raise exception 'step_title_counts: step 3 was not corrected.';
  end if;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   drop function if exists public.site_output_step_title_count(text);
--   update public.site_output_templates
--      set body = 'Set your five colors' where id = 'all.sheet.step2_title';
--   update public.site_output_templates
--      set body = 'Set your two fonts'   where id = 'all.sheet.step3_title';
