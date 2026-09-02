-- ============================================================================
-- banned_phrases, usp_stopwords, app_settings — service_role only
-- ============================================================================
-- These three are NOT catalogs, on purpose, and must not follow the
-- read-to-authenticated pattern in `20260831100000_how_you_work_catalogs.sql`:
--
--   - `banned_phrases` is what the tone-card and USP generators are graded
--     against. If it were readable by `authenticated`, any client could read
--     the exact list a generation route checks against and shape a prompt to
--     slip past it.
--   - `usp_stopwords` and `app_settings` (the `usp_similarity_threshold`
--     tuning knob) are internal to the normalization/distinctness machinery;
--     nothing client-side needs them directly.
--
-- Same lockdown as `stripe_events` in `20260825160000_lot4_billing.sql`:
-- RLS enabled, zero policies, and privileges revoked from anon/authenticated
-- as a second, independent barrier against a policy added by inadvertence
-- later. `service_role` is not granted anything explicitly because it
-- bypasses RLS outright (no table here is under FORCE ROW LEVEL SECURITY);
-- the two security-definer functions in a later migration read these tables
-- on behalf of `authenticated` callers.

-- ============================================================================
-- 1. banned_phrases
-- ============================================================================

create table if not exists public.banned_phrases (
  id       uuid    primary key default gen_random_uuid(),
  phrase   text    not null,
  category text    not null,
  active   boolean not null default true
);

alter table public.banned_phrases
  drop constraint if exists banned_phrases_category_check;
alter table public.banned_phrases
  add constraint banned_phrases_category_check
  check (category in ('directory_cliche', 'outcome_promise', 'hype'));

create unique index if not exists banned_phrases_lower_phrase_key
  on public.banned_phrases (lower(phrase));

-- ============================================================================
-- 2. usp_stopwords
-- ============================================================================
-- Standard English stopwords, plus the domain words `usp_normalize` (next
-- migration) strips because they appear in nearly every statement a brief
-- could produce and would otherwise dominate trigram similarity: two
-- statements that share only "therapy" and "clients" are not the collision
-- this store exists to catch.

create table if not exists public.usp_stopwords (
  word text primary key
);

-- ============================================================================
-- 3. app_settings
-- ============================================================================
-- Plain key/value, `jsonb` value so a setting can be a scalar, array, or
-- object without a schema change. `usp_similarity_threshold` is read by
-- `usp_check_distinct` (later migration) so the threshold is tunable without
-- a migration, per the brief.

create table if not exists public.app_settings (
  key   text  primary key,
  value jsonb not null
);

-- ============================================================================
-- 4. Seed data
-- ============================================================================

-- >>> USP GUARDRAIL DATA (mirrored verbatim in supabase/seed.sql) >>>
insert into public.banned_phrases (phrase, category) values
  ('safe space', 'directory_cliche'),
  ('judgment-free', 'directory_cliche'),
  ('judgement-free', 'directory_cliche'),
  ('you deserve', 'directory_cliche'),
  ('your journey', 'directory_cliche'),
  ('take the first step', 'directory_cliche'),
  ('here to help', 'directory_cliche'),
  ('meet you where you are', 'directory_cliche'),
  ('holistic approach', 'directory_cliche'),
  ('whole person', 'directory_cliche'),
  ('authentic self', 'directory_cliche'),
  ('unlock your potential', 'directory_cliche'),
  ('live your best life', 'directory_cliche'),
  ('mind body and spirit', 'directory_cliche'),
  ('compassionate care', 'directory_cliche'),
  ('tailored to your needs', 'directory_cliche'),
  ('a place to heal', 'directory_cliche'),
  ('ready to take the next step', 'directory_cliche'),
  ('your path to healing', 'directory_cliche'),
  ('empower you to', 'directory_cliche'),
  ('guaranteed results', 'outcome_promise'),
  ('will heal', 'outcome_promise'),
  ('cure your', 'outcome_promise'),
  ('proven to eliminate', 'outcome_promise'),
  ('you will feel better', 'outcome_promise'),
  ('amazing', 'hype'),
  ('life-changing', 'hype'),
  ('transformational', 'hype'),
  ('revolutionary', 'hype'),
  ('game-changer', 'hype')
on conflict (lower(phrase)) do update set
  category = excluded.category,
  active   = true;

insert into public.usp_stopwords (word) values
  ('a'),('an'),('the'),('and'),('or'),('but'),('of'),('to'),('in'),('on'),
  ('at'),('for'),('with'),('is'),('are'),('was'),('were'),('be'),('been'),
  ('being'),('this'),('that'),('these'),('those'),('it'),('its'),('as'),
  ('by'),('from'),('into'),('about'),('than'),('then'),('so'),('such'),
  ('not'),('no'),('nor'),('if'),('because'),('while'),('who'),('whom'),
  ('whose'),('which'),('what'),('when'),('where'),('why'),('how'),('all'),
  ('each'),('few'),('more'),('most'),('other'),('some'),('any'),('both'),
  ('either'),('neither'),('one'),('two'),('i'),('you'),('he'),('she'),
  ('we'),('they'),('them'),('his'),('her'),('their'),('our'),('your'),
  ('my'),('me'),('him'),('us'),('do'),('does'),('did'),('have'),('has'),
  ('had'),('can'),('could'),('will'),('would'),('shall'),('should'),
  ('may'),('might'),('must'),('up'),('down'),('out'),('over'),('under'),
  ('again'),('further'),('once'),('here'),('there'),('very'),('just'),
  ('also'),
  ('therapy'),('therapist'),('counseling'),('counselor'),('practice'),
  ('clients'),('people')
on conflict (word) do nothing;

insert into public.app_settings (key, value) values
  ('usp_similarity_threshold', '0.55')
on conflict (key) do nothing;
-- <<< USP GUARDRAIL DATA <<<

-- ============================================================================
-- 5. RLS — enabled, no policies, privileges revoked
-- ============================================================================

alter table public.banned_phrases enable row level security;
alter table public.usp_stopwords  enable row level security;
alter table public.app_settings   enable row level security;

revoke all on table public.banned_phrases from anon, authenticated;
revoke all on table public.usp_stopwords  from anon, authenticated;
revoke all on table public.app_settings   from anon, authenticated;

-- ============================================================================
-- 6. Runtime guard
-- ============================================================================

do $$
declare
  t     text;
  n_pol int;
begin
  foreach t in array array['banned_phrases', 'usp_stopwords', 'app_settings']
  loop
    if not exists (
      select 1 from pg_tables
      where schemaname = 'public' and tablename = t and rowsecurity
    ) then
      raise exception 'usp_guardrail_tables: % does not have RLS enabled', t;
    end if;

    select count(*) into n_pol
    from pg_policies
    where schemaname = 'public' and tablename = t;

    if n_pol <> 0 then
      raise exception 'usp_guardrail_tables: % has % policies, expected 0 (service_role only)', t, n_pol;
    end if;

    if has_table_privilege('authenticated', 'public.' || t, 'select') then
      raise exception 'usp_guardrail_tables: authenticated can still select from %', t;
    end if;
  end loop;
end
$$;

-- DOWN
-- drop table if exists public.app_settings;
-- drop table if exists public.usp_stopwords;
-- drop table if exists public.banned_phrases;
