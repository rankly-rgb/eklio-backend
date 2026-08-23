-- ============================================================================
-- Eklio — schéma de référence
-- ============================================================================
-- Source      : base réelle du projet Supabase `enolgemfqeajrwpftppm`
--               (org `eklio`, région eu-west-1), état observé le 2026-08-23.
-- Méthode     : introspection lecture seule du catalogue Postgres via l'API
--               Management (pg_dump indisponible dans l'environnement : ni
--               binaire client, ni mot de passe Postgres — et le récupérer
--               aurait impliqué de réinitialiser un secret).
-- Données     : AUCUNE. Schéma uniquement. Les données de eu-west-1 sont des
--               données de test, déclarées jetables ; elles ne sont ni dumpées
--               ni reproduites ici.
--
-- POURQUOI CE FICHIER
-- -------------------
-- La base eu-west-1 a été construite à la main (éditeur SQL / API), jamais via
-- `supabase db push` : elle n'a pas de table `supabase_migrations.schema_migrations`.
-- Trois jeux de migrations concurrents et mutuellement incompatibles existaient
-- en parallèle, aucun ne décrivant l'état réel :
--
--   1. eklio-backend,  branche `claude/eklio-bootstrap-ukuxfu`
--      -> 20260808000000_init_schema.sql
--   2. eklio-frontend, branches `claude/eklio-design-system-flow-zmf8rl`
--      et `claude/eklio-reconcile-us-base`
--      -> 20260809000000_init_projects.sql
--         20260815090000_init_directions.sql
--         20260816090000_fix_directions_schema.sql
--   3. eklio-frontend, branche `claude/eklio-fr-us-migration-53dnk1`
--      -> 20260816000000_init_schema.sql
--         20260816010000_brand_kits.sql
--         20260816020000_billing.sql
--
-- Ce fichier les remplace tous les trois. À partir d'ici, le repo eklio-backend
-- est la source de vérité unique du schéma.
--
-- Le schéma réel est un HYBRIDE des jeux 1 et 2, empilés l'un sur l'autre :
--   - `profiles`, `brief_answers`, `brand_kits`, `generation_credits` : jeu 1
--   - `project_briefs`, `directions`                                 : jeu 2
--   - `projects` : tronc du jeu 1 + colonnes `metier`/`current_step` et
--     contrainte `status` du jeu 2, greffées par ALTER
-- Le jeu 3 (enums `project_status`/`brief_step`, tables de facturation Stripe)
-- n'a JAMAIS été appliqué : il n'existe aucune trace en base.
--
-- Les anomalies héritées de cet empilement sont reproduites À L'IDENTIQUE et
-- signalées par des blocs `-- ⚠ ANOMALIE`. Elles ne sont volontairement pas
-- corrigées ici : ce fichier doit d'abord reproduire fidèlement l'existant.
-- Le nettoyage fera l'objet d'une migration suivante, explicite et revue.
--
-- Privilèges : aucun GRANT explicite n'existe en base. Les droits de `anon`,
-- `authenticated` et `service_role` proviennent des DEFAULT PRIVILEGES posés
-- par Supabase à la création du projet, donc automatiquement identiques sur
-- toute base Supabase neuve. Rien à reproduire ici.
-- Extensions : seules les extensions par défaut de Supabase sont installées
-- (pgcrypto, uuid-ossp, pg_stat_statements, supabase_vault). Aucune extension
-- applicative à créer.
-- Autres objets : aucune vue, aucune séquence, aucun type/enum applicatif,
-- aucun bucket Storage, aucune table publiée dans `supabase_realtime`.
-- ============================================================================


-- ============================================================================
-- 1. Fonction utilitaire — maintien de updated_at
-- ============================================================================
-- Déclarée avant les triggers qui la référencent.

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;


-- ============================================================================
-- 2. Tables
-- ============================================================================
-- Ordre imposé par les clés étrangères :
--   auth.users -> profiles -> projects -> {project_briefs, brief_answers,
--   directions, generation_credits} -> brand_kits (référence directions).

-- ----------------------------------------------------------------------------
-- profiles — miroir 1:1 de auth.users, alimenté par le trigger handle_new_user
-- ----------------------------------------------------------------------------
create table public.profiles (
  id         uuid        not null,
  email      text        not null,
  full_name  text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_pkey primary key (id),
  constraint profiles_id_fkey foreign key (id)
    references auth.users (id) on delete cascade
);

-- ----------------------------------------------------------------------------
-- projects — une identité de marque en cours de génération
-- ----------------------------------------------------------------------------
-- ⚠ ANOMALIE (héritée) : `projects.user_id` référence `public.profiles(id)`
-- (jeu 1) et non `auth.users(id)` (jeu 2). La cascade fonctionne quand même
-- (auth.users -> profiles -> projects), mais l'insertion d'un projet échoue
-- tant que le profil n'existe pas. C'est l'état réel de la base.
create table public.projects (
  id           uuid        not null default gen_random_uuid(),
  user_id      uuid        not null,
  name         text        not null default 'Mon projet'::text,
  status       text        not null default 'brief'::text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  metier       text,
  current_step smallint    not null default 1,
  constraint projects_pkey primary key (id),
  constraint projects_user_id_fkey foreign key (user_id)
    references public.profiles (id) on delete cascade,
  constraint projects_status_check check (
    status = any (array['brief'::text, 'brief_complete'::text, 'directions'::text, 'kit'::text])
  ),
  constraint projects_current_step_check check (
    current_step >= 1 and current_step <= 8
  )
);

-- ----------------------------------------------------------------------------
-- project_briefs — brief guidé, une ligne par projet (jeu 2)
-- ----------------------------------------------------------------------------
create table public.project_briefs (
  project_id      uuid        not null,
  data            jsonb       not null default '{}'::jsonb,
  completed_steps smallint[]  not null default '{}'::smallint[],
  updated_at      timestamptz not null default now(),
  constraint project_briefs_pkey primary key (project_id),
  constraint project_briefs_project_id_fkey foreign key (project_id)
    references public.projects (id) on delete cascade
);

-- ----------------------------------------------------------------------------
-- brief_answers — brief guidé, une ligne par étape (jeu 1)
-- ----------------------------------------------------------------------------
-- ⚠ ANOMALIE (héritée) : fait doublon fonctionnel avec `project_briefs`.
-- Les deux tables modélisent le même brief, selon deux conventions
-- différentes. La table est vide en base ; `project_briefs` est celle que le
-- code applicatif utilise. Candidate à suppression au nettoyage.
create table public.brief_answers (
  id         uuid        not null default gen_random_uuid(),
  project_id uuid        not null,
  step       text        not null,
  answer     jsonb       not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint brief_answers_pkey primary key (id),
  constraint brief_answers_project_id_step_key unique (project_id, step),
  constraint brief_answers_project_id_fkey foreign key (project_id)
    references public.projects (id) on delete cascade,
  constraint brief_answers_step_check check (
    step = any (array['brief'::text, 'positionnement'::text, 'audience'::text,
                      'ton'::text, 'palette'::text, 'typographies'::text, 'site'::text])
  )
);

-- ----------------------------------------------------------------------------
-- directions — les 3 propositions créatives générées pour un projet
-- ----------------------------------------------------------------------------
-- Version issue du jeu 2 : `20260816090000_fix_directions_schema.sql` a fait un
-- `drop table ... cascade` de la version du jeu 1 puis l'a recréée. C'est cette
-- version-ci qui est en base.
create table public.directions (
  id                uuid        not null default gen_random_uuid(),
  project_id        uuid        not null,
  "position"        smallint    not null,
  name              text        not null,
  description       text        not null,
  palette           jsonb       not null,
  typographie_titre text        not null,
  typographie_corps text        not null,
  is_selected       boolean     not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint directions_pkey primary key (id),
  constraint directions_project_id_position_key unique (project_id, "position"),
  constraint directions_project_id_fkey foreign key (project_id)
    references public.projects (id) on delete cascade,
  constraint directions_position_check check (
    "position" >= 1 and "position" <= 3
  )
);

-- ----------------------------------------------------------------------------
-- generation_credits — quotas de génération IA, par projet (jeu 1)
-- ----------------------------------------------------------------------------
create table public.generation_credits (
  id                   uuid        not null default gen_random_uuid(),
  project_id           uuid        not null,
  directions_generated smallint    not null default 0,
  directions_limit     smallint    not null default 3,
  regenerations_used   smallint    not null default 0,
  regenerations_limit  smallint    not null default 1,
  has_paid             boolean     not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint generation_credits_pkey primary key (id),
  constraint generation_credits_project_id_key unique (project_id),
  constraint generation_credits_project_id_fkey foreign key (project_id)
    references public.projects (id) on delete cascade
);

-- ----------------------------------------------------------------------------
-- brand_kits — le kit de marque final (jeu 1)
-- ----------------------------------------------------------------------------
-- ⚠ ANOMALIE (héritée) : `brand_kits_direction_id_fkey` N'EXISTE PAS en base.
-- La colonne `direction_id` est bien présente et NOT NULL, mais la contrainte
-- de clé étrangère vers `directions(id)` a disparu — emportée par le
-- `drop table public.directions cascade` de `fix_directions_schema`, qui ne
-- l'a jamais recréée. L'intégrité référentielle n'est donc plus garantie sur
-- cette colonne. Reproduit tel quel ; à rétablir au nettoyage.
create table public.brand_kits (
  id                   uuid        not null default gen_random_uuid(),
  project_id           uuid        not null,
  direction_id         uuid        not null,
  content              jsonb       not null default '{}'::jsonb,
  multi_builder_prompt text,
  pdf_url              text,
  share_slug           text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint brand_kits_pkey primary key (id),
  constraint brand_kits_project_id_key unique (project_id),
  constraint brand_kits_share_slug_key unique (share_slug),
  constraint brand_kits_project_id_fkey foreign key (project_id)
    references public.projects (id) on delete cascade
);


-- ============================================================================
-- 3. Index (hors ceux créés implicitement par PRIMARY KEY / UNIQUE)
-- ============================================================================

create index projects_user_id_idx
  on public.projects using btree (user_id);

create index projects_user_id_updated_at_idx
  on public.projects using btree (user_id, updated_at desc);

create index brief_answers_project_id_idx
  on public.brief_answers using btree (project_id);

create index directions_project_id_idx
  on public.directions using btree (project_id);


-- ============================================================================
-- 4. Row Level Security
-- ============================================================================
-- RLS activée sur les 7 tables. Aucune n'est en FORCE ROW LEVEL SECURITY :
-- le `service_role` (utilisé côté serveur) contourne donc les policies.

alter table public.profiles           enable row level security;
alter table public.projects           enable row level security;
alter table public.project_briefs     enable row level security;
alter table public.brief_answers      enable row level security;
alter table public.directions         enable row level security;
alter table public.generation_credits enable row level security;
alter table public.brand_kits         enable row level security;


-- ============================================================================
-- 5. Policies
-- ============================================================================
-- Toutes PERMISSIVE et accordées au rôle `public` (pas de clause TO), donc
-- évaluées pour `anon` comme pour `authenticated`. Pour `anon`, `auth.uid()`
-- vaut NULL : toutes les comparaisons échouent et rien n'est visible.

-- ---- profiles --------------------------------------------------------------
-- ⚠ ANOMALIE (héritée) : aucune policy INSERT ni DELETE sur `profiles`.
-- L'insertion passe exclusivement par le trigger `handle_new_user`
-- (SECURITY DEFINER) et la suppression par la cascade depuis `auth.users`.
-- C'est fonctionnel, mais implicite.
create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

create policy "profiles_update_own"
  on public.profiles for update
  using (auth.uid() = id);

-- ---- projects --------------------------------------------------------------
-- ⚠ ANOMALIE (héritée) : cinq policies se recouvrent sur cette table —
-- `projects_all_own` (FOR ALL, jeu 1) et les quatre policies par commande
-- (jeu 2). Les policies permissives se combinent en OR : le résultat reste
-- strictement « propriétaire uniquement », donc pas de faille, mais chaque
-- requête évalue deux prédicats équivalents. Doublon à supprimer au nettoyage.
create policy "projects_all_own"
  on public.projects for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "projects_select_own"
  on public.projects for select
  using (user_id = (select auth.uid()));

create policy "projects_insert_own"
  on public.projects for insert
  with check (user_id = (select auth.uid()));

create policy "projects_update_own"
  on public.projects for update
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "projects_delete_own"
  on public.projects for delete
  using (user_id = (select auth.uid()));

-- ---- project_briefs --------------------------------------------------------
create policy "project_briefs_select_own"
  on public.project_briefs for select
  using (exists (
    select 1 from public.projects p
    where p.id = project_briefs.project_id and p.user_id = (select auth.uid())
  ));

create policy "project_briefs_insert_own"
  on public.project_briefs for insert
  with check (exists (
    select 1 from public.projects p
    where p.id = project_briefs.project_id and p.user_id = (select auth.uid())
  ));

create policy "project_briefs_update_own"
  on public.project_briefs for update
  using (exists (
    select 1 from public.projects p
    where p.id = project_briefs.project_id and p.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.projects p
    where p.id = project_briefs.project_id and p.user_id = (select auth.uid())
  ));

create policy "project_briefs_delete_own"
  on public.project_briefs for delete
  using (exists (
    select 1 from public.projects p
    where p.id = project_briefs.project_id and p.user_id = (select auth.uid())
  ));

-- ---- brief_answers ---------------------------------------------------------
create policy "brief_answers_all_own"
  on public.brief_answers for all
  using (exists (
    select 1 from public.projects
    where projects.id = brief_answers.project_id and projects.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.projects
    where projects.id = brief_answers.project_id and projects.user_id = auth.uid()
  ));

-- ---- directions ------------------------------------------------------------
create policy "directions_select_own"
  on public.directions for select
  using (exists (
    select 1 from public.projects p
    where p.id = directions.project_id and p.user_id = (select auth.uid())
  ));

create policy "directions_insert_own"
  on public.directions for insert
  with check (exists (
    select 1 from public.projects p
    where p.id = directions.project_id and p.user_id = (select auth.uid())
  ));

create policy "directions_update_own"
  on public.directions for update
  using (exists (
    select 1 from public.projects p
    where p.id = directions.project_id and p.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.projects p
    where p.id = directions.project_id and p.user_id = (select auth.uid())
  ));

create policy "directions_delete_own"
  on public.directions for delete
  using (exists (
    select 1 from public.projects p
    where p.id = directions.project_id and p.user_id = (select auth.uid())
  ));

-- ---- generation_credits ----------------------------------------------------
create policy "generation_credits_all_own"
  on public.generation_credits for all
  using (exists (
    select 1 from public.projects
    where projects.id = generation_credits.project_id and projects.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.projects
    where projects.id = generation_credits.project_id and projects.user_id = auth.uid()
  ));

-- ---- brand_kits ------------------------------------------------------------
-- TODO(share) : la page de kit partageable via `share_slug` nécessitera une
-- policy publique en lecture seule. Elle n'existe pas en base à ce jour.
create policy "brand_kits_all_own"
  on public.brand_kits for all
  using (exists (
    select 1 from public.projects
    where projects.id = brand_kits.project_id and projects.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.projects
    where projects.id = brand_kits.project_id and projects.user_id = auth.uid()
  ));


-- ============================================================================
-- 6. Fonctions applicatives
-- ============================================================================
-- Déclarées après les tables qu'elles écrivent.

-- Crée automatiquement un profil à la création d'un compte Supabase Auth.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email);
  return new;
end;
$function$;

-- Initialise la ligne de crédits à la création d'un projet.
create or replace function public.handle_new_project()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.generation_credits (project_id) values (new.id);
  return new;
end;
$function$;


-- ============================================================================
-- 7. Triggers
-- ============================================================================

-- ⚠ ANOMALIE (héritée) : `projects` porte DEUX triggers updated_at identiques,
-- `set_projects_updated_at` (jeu 1) et `projects_set_updated_at` (jeu 2). Ils
-- appellent la même fonction et s'exécutent tous les deux à chaque UPDATE.
-- Sans effet fonctionnel, mais redondant. Doublon à supprimer au nettoyage.
create trigger set_projects_updated_at
  before update on public.projects
  for each row execute function public.set_updated_at();

create trigger projects_set_updated_at
  before update on public.projects
  for each row execute function public.set_updated_at();

create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger project_briefs_set_updated_at
  before update on public.project_briefs
  for each row execute function public.set_updated_at();

create trigger set_brief_answers_updated_at
  before update on public.brief_answers
  for each row execute function public.set_updated_at();

create trigger directions_set_updated_at
  before update on public.directions
  for each row execute function public.set_updated_at();

create trigger set_generation_credits_updated_at
  before update on public.generation_credits
  for each row execute function public.set_updated_at();

create trigger set_brand_kits_updated_at
  before update on public.brand_kits
  for each row execute function public.set_updated_at();

-- Trigger sur le schéma `auth`. Nécessite les droits du rôle `postgres`,
-- dont dispose `supabase db push`.
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create trigger on_project_created
  after insert on public.projects
  for each row execute function public.handle_new_project();
