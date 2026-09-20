-- ============================================================================
-- Eklio — la veille : UN pipeline hebdomadaire pour tout le parc
-- ============================================================================
-- ⚠ JAMAIS DE RECHERCHE WEB PAR UTILISATRICE, et c'est une décision de coût
-- autant que de produit.
--
-- Par utilisatrice, la veille coûte (nombre d'abonnées × nombre de recherches)
-- par semaine, pour produire à peu près les mêmes cartes chez tout le monde :
-- l'APA publie la même chose pour toutes. Une fois pour le parc, elle coûte un
-- run — et le plafond dur de 40 recherches vit dans le code du run, pas dans
-- une intention.
--
-- Les cartes ne sont pas du contenu. Elles alimentent `content_topics` avec
-- `timely = true`, et c'est le sujet qui est publié, après la garde
-- déontologique. Une carte de veille ne traverse jamais l'écran de personne.
-- ============================================================================


-- ============================================================================
-- 1. insight_sources — une liste CURÉE, et curée veut dire close
-- ============================================================================
create table if not exists public.insight_sources (
  id          text     primary key,
  label       text     not null,
  kind        text     not null,
  -- NULL pour une source qui n'est pas une URL (un calendrier de mois de
  -- sensibilisation tenu à la main).
  url         text,
  active      boolean  not null default true,
  sort_order  smallint not null,

  constraint insight_sources_label_check check (char_length(label) between 1 and 80),
  constraint insight_sources_kind_check
    check (kind in ('association', 'government', 'journal', 'feed', 'calendar', 'press')),
  -- Nullable, donc gardé par `is null or` : un `~` nu accepterait un NULL,
  -- puisqu'un CHECK ne rejette que sur FALSE.
  constraint insight_sources_url_check
    check (url is null or url ~ '^https://')
);

comment on table public.insight_sources is
  'The watch sources, curated by hand. Closed by construction: the weekly run reads ONLY these rows, so widening the watch is a migration with a diff rather than a prompt parameter.';

insert into public.insight_sources (id, label, kind, url, sort_order) values
  ('apa',              'American Psychological Association', 'association', 'https://www.apa.org/news',        1),
  ('aca',              'American Counseling Association',    'association', 'https://www.counseling.org',      2),
  ('nimh',             'National Institute of Mental Health','government',  'https://www.nimh.nih.gov/news',   3),
  ('psychology_today', 'Psychology Today',                   'press',       'https://www.psychologytoday.com', 4),
  ('pubmed',           'PubMed, requêtes suivies',           'feed',        'https://pubmed.ncbi.nlm.nih.gov', 5),
  ('awareness_months', 'US awareness months',                'calendar',    null,                              6)
on conflict (id) do update
  set label = excluded.label, kind = excluded.kind,
      url = excluded.url, sort_order = excluded.sort_order;

alter table public.insight_sources enable row level security;

drop policy if exists "insight_sources_select_all"    on public.insight_sources;
drop policy if exists "insight_sources_insert_denied" on public.insight_sources;
drop policy if exists "insight_sources_update_denied" on public.insight_sources;
drop policy if exists "insight_sources_delete_denied" on public.insight_sources;

create policy "insight_sources_select_all" on public.insight_sources
  for select to authenticated using (true);
create policy "insight_sources_insert_denied" on public.insight_sources
  for insert with check (false);
create policy "insight_sources_update_denied" on public.insight_sources
  for update using (false);
create policy "insight_sources_delete_denied" on public.insight_sources
  for delete using (false);


-- ============================================================================
-- 2. insight_runs — le plafond de recherches, en base
-- ============================================================================
-- ⚠ LE PLAFOND EST UN CHECK, PAS UNE CONSTANTE DANS LE CODE. « 40 recherches
-- par run maximum, plafond dur dans le code » — le code peut être contourné
-- par un second appelant ; une contrainte de ligne ne peut pas.

create table if not exists public.insight_runs (
  id            uuid     primary key default gen_random_uuid(),
  week          date     not null,
  searches_used integer  not null default 0,
  state         text     not null default 'running',
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,

  constraint insight_runs_week_key unique (week),
  -- Le lundi de la semaine. Un run par semaine pour tout le parc, et l'unicité
  -- le rend structurel plutôt que confié à un cron qui ne se déclenche qu'une
  -- fois si tout va bien.
  constraint insight_runs_week_check check (week = date_trunc('week', week)::date),
  constraint insight_runs_state_check check (state in ('running', 'done', 'failed')),
  constraint insight_runs_searches_check
    check (searches_used between 0 and 40),
  constraint insight_runs_finished_check
    check ((state = 'running') = (finished_at is null))
);

comment on table public.insight_runs is
  'One watch run per week, for the WHOLE estate. Uniqueness on the week makes "only once" structural rather than entrusted to a cron. searches_used is bounded to 40 BY THE ROW: a ceiling held only in code is a ceiling a second caller ignores.';

alter table public.insight_runs enable row level security;
revoke all on table public.insight_runs from anon, authenticated;

-- ⚠ LE REFUS EST ÉCRIT, PAS DÉDUIT. Sous RLS, l'absence de policy refuse déjà
-- tout le monde sauf le propriétaire et service_role — mais elle se lit
-- exactement comme une policy oubliée, et `20260911180620_tenancy_layer` fait
-- échouer la suite sur ce silence. L'effet est le même ; ce qui change est
-- qu'une lectrice sait que c'est voulu.
drop policy if exists "insight_runs_denied" on public.insight_runs;
create policy "insight_runs_denied" on public.insight_runs
  for all using (false) with check (false);


-- ============================================================================
-- 3. insight_cards — ce que le run produit
-- ============================================================================
create table if not exists public.insight_cards (
  id           uuid     primary key default gen_random_uuid(),
  source_id    text     not null references public.insight_sources (id),
  run_id       uuid     not null references public.insight_runs (id) on delete cascade,
  summary      text     not null,
  -- Les segments que cette carte concerne. Un tableau d'uuid plutôt qu'une
  -- table de liaison : une carte en nomme cinq ou six et n'est jamais jointe
  -- en volume — c'est `content_topics` qui l'est.
  segments     uuid[]   not null default '{}',
  published_at timestamptz,
  -- ⚠ NOT NULL. Une carte de veille SANS péremption est une actualité qui
  -- devient un mensonge : « ce mois-ci » lu en juin. La table refuse d'en
  -- porter une, plutôt que de compter sur le run pour toujours en poser une.
  expires_at   timestamptz not null,
  created_at   timestamptz not null default now(),

  constraint insight_cards_summary_check check (char_length(summary) between 1 and 600),
  constraint insight_cards_segments_check
    check (coalesce(array_length(segments, 1), 0) between 0 and 24)
);

comment on table public.insight_cards is
  'What one watch run found. expires_at is NOT NULL: a piece of news with no expiry becomes a lie ("this month", read in June), and the table refuses to carry one rather than trusting the run to always set it. Cards are not content -- they feed content_topics with timely = true, and it is the topic that goes through the ethics guard.';

create index if not exists insight_cards_run_idx    on public.insight_cards (run_id);
create index if not exists insight_cards_expiry_idx on public.insight_cards (expires_at);
create index if not exists insight_cards_segments_idx
  on public.insight_cards using gin (segments);

alter table public.insight_cards enable row level security;
revoke all on table public.insight_cards from anon, authenticated;

drop policy if exists "insight_cards_denied" on public.insight_cards;
create policy "insight_cards_denied" on public.insight_cards
  for all using (false) with check (false);


-- ============================================================================
-- 4. Le trigger qui valide les segments d'une carte
-- ============================================================================
-- ⚠ UN TABLEAU NE PORTE PAS DE CLEF ÉTRANGÈRE. Sans ce trigger,
-- `insight_cards.segments` serait un sac d'uuid qui RESSEMBLE à une référence,
-- et un uuid mort y rétrécirait la portée d'une carte en silence au lieu
-- d'échouer. C'est exactement le motif que `content_preferences` a déjà posé
-- pour `accepted_registers`.

create or replace function public.insight_cards_validate_segments()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unknown uuid;
begin
  select s into v_unknown
    from unnest(new.segments) as s
   where s not in (select id from public.content_segments)
   limit 1;

  if v_unknown is not null then
    raise exception 'insight_cards: % n''est pas un segment connu', v_unknown
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

comment on function public.insight_cards_validate_segments() is
  'Validates insight_cards.segments against content_segments -- an array carries no foreign key, and a dead uuid in it would silently narrow a card''s reach instead of failing.';

revoke all on function public.insight_cards_validate_segments() from public, anon, authenticated;

drop trigger if exists insight_cards_validate_segments on public.insight_cards;
create trigger insight_cards_validate_segments
  before insert or update on public.insight_cards
  for each row execute function public.insight_cards_validate_segments();


-- ============================================================================
-- 5. Le lien vers la banque : d'où vient un sujet daté
-- ============================================================================
alter table public.content_topics
  add column if not exists insight_card_id uuid references public.insight_cards (id) on delete set null;

comment on column public.content_topics.insight_card_id is
  'The watch card this topic was born from, when it came from one. ON DELETE SET NULL: purging expired cards must not take with them the topics they produced, which have been reviewed and may already be assigned.';

create index if not exists content_topics_insight_idx
  on public.content_topics (insight_card_id)
  where insight_card_id is not null;


-- ============================================================================
-- Guard rails
-- ============================================================================
do $$
declare
  v_run  uuid;
  v_seg  uuid;
  v_card uuid;
  v_mod  text;
  v_per  text;
  v_n    integer;
  t      text;
begin
  select count(*) into v_n from public.insight_sources;
  if v_n <> 6 then
    raise exception 'insight_sources: % lignes, attendu 6', v_n;
  end if;

  foreach t in array array['insight_runs', 'insight_cards'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'veille: RLS absente sur %', t;
    end if;
    -- Ces deux-là sont des instruments d'Eklio, pas des données de cliente.
    -- Le refus est ÉCRIT (`for all using (false)`), pas déduit de l'absence de
    -- policy : les deux ont le même effet, et seul le premier se distingue
    -- d'un oubli. Le REVOKE reste la seconde barrière.
    if not exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t
         and qual = 'false' and with_check = 'false'
    ) then
      raise exception 'veille: % n''écrit pas son refus; RLS sans policy se lit comme un oubli.', t;
    end if;
    if has_table_privilege('authenticated', 'public.' || t, 'SELECT') then
      raise exception 'authenticated peut lire %', t;
    end if;
  end loop;

  -- ---- le plafond de 40 est tenu par la ligne ----------------------------
  insert into public.insight_runs (week) values (date_trunc('week', now())::date)
  returning id into v_run;

  begin
    update public.insight_runs set searches_used = 41 where id = v_run;
    raise exception 'un run a pu enregistrer 41 recherches; le plafond dur ne mord pas.';
  exception when check_violation then null;
  end;

  update public.insight_runs set searches_used = 40 where id = v_run;

  -- ---- un run par semaine ------------------------------------------------
  begin
    insert into public.insight_runs (week) values (date_trunc('week', now())::date);
    raise exception 'deux runs de veille ont été acceptés pour la même semaine.';
  exception when unique_violation then null;
  end;

  -- ---- une carte sans péremption est refusée -----------------------------
  begin
    insert into public.insight_cards (source_id, run_id, summary, expires_at)
    values ('apa', v_run, 'Une carte qui ne périme jamais', null);
    raise exception 'une carte de veille sans expires_at a été acceptée.';
  exception when not_null_violation then null;
  end;

  -- ---- les segments sont validés contre le catalogue ---------------------
  begin
    insert into public.insight_cards (source_id, run_id, summary, segments, expires_at)
    values ('apa', v_run, 'Une carte qui nomme un segment mort',
            array[gen_random_uuid()], now() + interval '60 days');
    raise exception 'un uuid de segment inconnu a été accepté dans une carte.';
  exception when check_violation then null;
  end;

  select id into v_mod from public.modality_cards where active order by sort_order limit 1;
  select id into v_per from public.client_persona_cards where active order by sort_order limit 1;
  insert into public.content_segments (modality_id, persona_id, state_code)
  values (v_mod, v_per, 'NV') returning id into v_seg;

  insert into public.insight_cards (source_id, run_id, summary, segments, expires_at)
  values ('apa', v_run, 'Une carte bien formée', array[v_seg], now() + interval '60 days')
  returning id into v_card;

  -- ---- ⚠ PURGER UNE CARTE N'EMPORTE PAS LE SUJET QU'ELLE A PRODUIT -------
  insert into public.content_topics
    (segment_id, archetype_key, intent, title, hook, payload, caption_seed,
     rationale_template, ethics_reviewed_at, timely, expires_at, insight_card_id)
  values (v_seg, 'single_statement', 'educate', 'Un sujet daté', 'Un hook',
          '{"statement":"A timely statement born out of a watch card this week"}'::jsonb,
          'seed', 'Because.', now(), true, now() + interval '30 days', v_card);

  delete from public.insight_cards where id = v_card;

  select count(*) into v_n from public.content_topics
   where segment_id = v_seg and insight_card_id is null;
  if v_n <> 1 then
    raise exception 'supprimer la carte a emporté le sujet qu''elle avait produit.';
  end if;

  -- ---- teardown ----------------------------------------------------------
  delete from public.content_segments where id = v_seg;
  delete from public.insight_runs where id = v_run;
end
$$;


-- ============================================================================
-- DOWN
-- ============================================================================
--   alter table public.content_topics drop column if exists insight_card_id;
--   drop trigger  if exists insight_cards_validate_segments on public.insight_cards;
--   drop function if exists public.insight_cards_validate_segments();
--   drop table    if exists public.insight_cards;
--   drop table    if exists public.insight_runs;
--   drop table    if exists public.insight_sources;
