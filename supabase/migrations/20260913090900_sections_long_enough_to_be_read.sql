-- ============================================================================
-- 800 characters was restraint. 139 words is not.
-- ============================================================================
-- Measured on a published site built from kit 45de0dac: home 139 words, About
-- 90, each approach page 35. A therapist site that a reader takes seriously
-- runs into the thousands. The copy does not exist in the product — but even
-- once it does, it could not be stored: every section field is capped at 800
-- characters and `about_excerpt` at 600.
--
-- ⚠ WHAT ACTUALLY ENFORCES A LENGTH, AND WHAT ONLY DISPLAYS ONE.
--
--   `site_spec_pages_lengths_valid`  — the CHECK. One global number, 800.
--   `site_spec_first_overlong_field` — the same number again, to name the
--                                      field in a `too_long` refusal.
--   `section_types.fields[].max_length` — read by NOTHING in the database.
--                                      It drives the editor's counters and
--                                      the per-field limits the UI shows.
--
-- So the database has one ceiling and the product has per-field maxima, and
-- they were never the same mechanism. That split is kept deliberately, because
-- it is the right one: the CHECK is a backstop that must be IMMUTABLE (a CHECK
-- cannot read a table), and the per-type maxima are product judgement that
-- should be editable without a constraint rebuild.
--
-- Hence: per-type maxima rise in `section_types`, and THE GLOBAL CEILING
-- BECOMES THE HIGHEST OF THEM — 2000, the new `approach.body`. Not one number
-- loosened for everything; the backstop simply stops being lower than the
-- values it is meant to back.
--
-- ── The bands, and the arithmetic ─────────────────────────────────────────
-- English prose runs about 6.1 characters per word including the space. Each
-- maximum is the top of its band times 6.1, rounded up with room for one long
-- sentence, so hitting the maximum is a writing decision and never a surprise.
--
--   intro.body            180 w → 1098 →  1400   home introduction 120–180 w
--   approach.body         (pairs with intro for About's 300–450 w) → 2000
--   services.body         150 w →  915 →  1200   home body section 90–150 w
--   contact.body          150 w →  915 →  1200
--   faq.items             120 w answer + its question → 1000, each
--   specialties.items                            →  120
--   who_i_work_with.items                        →  200
--   credentials.items                            →  200
--   footer.body                                     300, unchanged
--
-- `about_excerpt` rises to 1400 with `intro`, because the intro sections READ
-- that column — leaving them apart would cap the field at the smaller of two
-- numbers and make the editor's counter a lie.
--
-- ⚠ `fees` AND `hero` ARE NOT TOUCHED. Fees is out of scope by standing rule
-- and stays omitted entirely; the hero's four limits are typographic, not
-- editorial — a headline is short because it is a headline.
--
-- ⚠ THE CONSTRAINT IS REPLACED, NOT LEFT BESIDE A NEW ONE. Two CHECKs on
-- `about_excerpt` would be two truths, and the smaller would silently win.
--
-- `site_spec_limits()` is not edited: it SCRAPES these numbers out of the
-- function source and the constraint definition, so it follows on its own.
-- That is also why the two rewritten functions below keep their exact textual
-- shape — the scrape's regexes match on it.
-- ============================================================================

-- ── The backstop, raised to the highest per-type maximum ───────────────────
create or replace function public.site_spec_pages_lengths_valid(p jsonb)
returns boolean
language sql
immutable
set search_path to ''
as $function$
  select case
    when p is null then true
    when jsonb_typeof(p) <> 'array' then true  -- the shape check's job
    else not exists (
      select 1
        from jsonb_array_elements(p) as pg
        cross join lateral jsonb_array_elements(pg.value->'sections') as s
        cross join lateral jsonb_each(s.value->'fields') as f
        cross join lateral (
          select f.value as v where jsonb_typeof(f.value) = 'string'
          union all
          select e.value from jsonb_array_elements(f.value) as e
           where jsonb_typeof(f.value) = 'array'
        ) as vals(v)
       where jsonb_typeof(vals.v) = 'string'
         and char_length(vals.v #>> '{}') > 2000
    )
  end
$function$;

create or replace function public.site_spec_first_overlong_field(p_pages jsonb)
returns text
language sql
immutable
set search_path to ''
as $function$
  select format('pages[%s].sections[%s].fields.%s', pg.ord - 1, s.ord - 1, f.key)
    from jsonb_array_elements(p_pages) with ordinality as pg(value, ord)
    cross join lateral jsonb_array_elements(pg.value->'sections') with ordinality as s(value, ord)
    cross join lateral jsonb_each(s.value->'fields') as f(key, value)
    cross join lateral (
      select f.value as v where jsonb_typeof(f.value) = 'string'
      union all
      select e.value from jsonb_array_elements(f.value) as e where jsonb_typeof(f.value) = 'array'
    ) as vals(v)
   where jsonb_typeof(vals.v) = 'string' and char_length(vals.v #>> '{}') > 2000
   order by pg.ord, s.ord, f.key
   limit 1
$function$;

-- ── `about_excerpt`, which the intro sections read ─────────────────────────
alter table public.site_specs drop constraint site_specs_about_excerpt_check;
alter table public.site_specs
  add constraint site_specs_about_excerpt_check check (char_length(about_excerpt) <= 1400);

-- ── The per-type maxima the product shows and writes against ───────────────
-- Each field is rewritten in place by key, so a field this migration does not
-- name keeps exactly what it had.
update public.section_types t
   set fields = (
     select jsonb_agg(
       case
         when f.value->>'key' = m.field_key
           then jsonb_set(f.value, '{max_length}', to_jsonb(m.max_length))
         else f.value
       end
       order by f.ord)
       from jsonb_array_elements(t.fields) with ordinality as f(value, ord)
   )
  from (values
    ('intro',           'body',  1400),
    ('approach',        'body',  2000),
    ('services',        'body',  1200),
    ('contact',         'body',  1200),
    ('faq',             'items', 1000),
    ('specialties',     'items',  120),
    ('who_i_work_with', 'items',  200),
    ('credentials',     'items',  200)
  ) as m(type_id, field_key, max_length)
 where t.id = m.type_id;
