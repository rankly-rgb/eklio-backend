-- ============================================================================
-- Eklio — nettoyage des anomalies héritées
-- ============================================================================
-- Fait suite à `20260823000000_reference_schema_from_live.sql`, qui reproduit
-- fidèlement le schéma réel de la base eu-west-1, anomalies comprises. Cette
-- migration-ci répare les 6 anomalies qui y sont balisées `-- ⚠ ANOMALIE`.
--
-- Séparation volontaire : la référence dit « ce qui existait », ce fichier dit
-- « ce qu'on a réparé ». L'historique reste lisible.
--
-- Écrite pour être rejouable et défensive : chaque bloc tolère une base déjà
-- propre (`if exists` / `if not exists`) et une base peuplée (gestion des
-- lignes orphelines avant pose de contrainte). Sur le projet us-east-1, où
-- elle est appliquée sur un schéma neuf et vide, tous les blocs de données
-- sont des no-op.
--
-- NON TRAITÉ ICI : l'anomalie 5 (`projects.user_id` -> `profiles(id)` plutôt
-- que `auth.users(id)`). Elle demande un arbitrage produit ; voir le bloc en
-- fin de fichier.
-- ============================================================================


-- ============================================================================
-- 1. brand_kits.direction_id — rétablir la clé étrangère manquante
-- ============================================================================
-- La contrainte `brand_kits_direction_id_fkey` a été emportée par le
-- `drop table public.directions cascade` de `fix_directions_schema` et jamais
-- recréée. La colonne est restée NOT NULL, mais sans intégrité référentielle.
--
-- ON DELETE NO ACTION (choix explicite, voir la PR) :
--   * Un brand kit est le livrable final, dérivé de la direction choisie. Le
--     supprimer en silence parce qu'on supprime une direction serait une perte
--     de données non intentionnelle -> CASCADE écarté.
--   * NO ACTION plutôt que RESTRICT : les deux refusent la suppression d'une
--     direction encore référencée, mais NO ACTION est vérifié en fin d'ordre,
--     alors que RESTRICT est vérifié immédiatement. Or `directions` et
--     `brand_kits` cascadent toutes deux depuis `projects` : au DELETE d'un
--     projet, RESTRICT peut se déclencher sur la ligne `directions` avant que
--     la ligne `brand_kits` correspondante n'ait été supprimée, et faire
--     échouer la suppression du projet. NO ACTION laisse la cascade se
--     terminer puis vérifie — la suppression d'un projet reste possible.

-- Lignes orphelines : `direction_id` est NOT NULL, aucun cas NULL à traiter.
-- Sur une base peuplée, un brand kit dont la direction a disparu est déjà
-- irrécupérable (son contenu référence une direction inexistante).
-- ⚠ Ce bloc SUPPRIME ces lignes. Il est bruyant à dessein : la volumétrie
-- attendue est 0 partout, tout compte non nul doit être investigué.
do $$
declare
  orphelins bigint;
begin
  select count(*) into orphelins
  from public.brand_kits bk
  where not exists (
    select 1 from public.directions d where d.id = bk.direction_id
  );

  if orphelins > 0 then
    raise warning
      'cleanup_inherited_anomalies: % brand_kits orphelins (direction_id sans direction) vont etre supprimes', orphelins;
    delete from public.brand_kits bk
    where not exists (
      select 1 from public.directions d where d.id = bk.direction_id
    );
  end if;
end
$$;

alter table public.brand_kits
  drop constraint if exists brand_kits_direction_id_fkey;

alter table public.brand_kits
  add constraint brand_kits_direction_id_fkey
  foreign key (direction_id) references public.directions (id)
  on delete no action;

-- Postgres n'indexe pas automatiquement le côté référençant d'une FK ; sans
-- index, chaque DELETE sur `directions` fait un seq scan de `brand_kits`.
create index if not exists brand_kits_direction_id_idx
  on public.brand_kits using btree (direction_id);


-- ============================================================================
-- 2. projects — supprimer le trigger updated_at redondant
-- ============================================================================
-- `set_projects_updated_at` (jeu 1) et `projects_set_updated_at` (jeu 2)
-- appellent tous deux `public.set_updated_at()` à chaque UPDATE.
-- On garde `set_projects_updated_at`, conforme à la convention majoritaire du
-- schéma (`set_profiles_updated_at`, `set_generation_credits_updated_at`,
-- `set_brand_kits_updated_at`).

drop trigger if exists projects_set_updated_at on public.projects;


-- ============================================================================
-- 3. projects — consolider les 5 policies qui se recouvrent
-- ============================================================================
-- `projects_all_own` (FOR ALL, jeu 1) recouvre intégralement les quatre
-- policies par commande (jeu 2). Les policies permissives se combinent en OR :
-- le comportement effectif est déjà « propriétaire uniquement », mais chaque
-- requête évalue deux prédicats équivalents.
--
-- On garde le jeu par commande : il utilise la forme `(select auth.uid())`,
-- que Postgres évalue une seule fois par requête (InitPlan) au lieu d'une fois
-- par ligne — la forme recommandée par Supabase pour les policies RLS.
--
-- Comportement effectif inchangé : owner-only avant, owner-only après.

drop policy if exists "projects_all_own" on public.projects;


-- ============================================================================
-- 4. brief_answers — supprimer la table doublon inutilisée
-- ============================================================================
-- Doublon fonctionnel de `project_briefs` : les deux modélisent le même brief
-- guidé selon deux conventions différentes (une ligne par étape vs une ligne
-- par projet). Le code applicatif utilise `project_briefs` ; `brief_answers`
-- est vide en base.
--
-- Garde-fou : refuse de supprimer si une clé étrangère pointe vers la table,
-- ou si elle contient des lignes. Un `drop ... cascade` aveugle ici pourrait
-- emporter des objets qu'on n'a pas inventoriés.
do $$
declare
  dependances text;
  lignes      bigint;
begin
  if to_regclass('public.brief_answers') is null then
    return;
  end if;

  select string_agg(format('%s.%s', c.conrelid::regclass, c.conname), ', ')
    into dependances
  from pg_constraint c
  where c.contype = 'f'
    and c.confrelid = 'public.brief_answers'::regclass;

  if dependances is not null then
    raise exception
      'cleanup_inherited_anomalies: brief_answers est encore referencee par : %. Suppression annulee.', dependances;
  end if;

  execute 'select count(*) from public.brief_answers' into lignes;
  if lignes > 0 then
    raise exception
      'cleanup_inherited_anomalies: brief_answers contient % ligne(s). Suppression annulee, migrer les donnees vers project_briefs d''abord.', lignes;
  end if;
end
$$;

-- Emporte au passage l'index `brief_answers_project_id_idx`, le trigger
-- `set_brief_answers_updated_at`, la policy `brief_answers_all_own` et les
-- contraintes de la table. Aucun objet externe n'en dépend (vérifié ci-dessus).
drop table if exists public.brief_answers;


-- ============================================================================
-- 5. profiles — rendre INSERT et DELETE explicites
-- ============================================================================
-- Aujourd'hui `profiles` n'a ni policy INSERT ni policy DELETE. RLS étant
-- activée, l'absence de policy vaut refus : aucun client `anon` /
-- `authenticated` ne peut insérer ni supprimer un profil. Ce qui fonctionne
-- passe à côté de RLS :
--   * INSERT  : trigger `handle_new_user`, SECURITY DEFINER, exécuté avec les
--               droits du propriétaire.
--   * DELETE  : cascade depuis `auth.users` — les actions référentielles ne
--               sont pas soumises à RLS.
--
-- ⚠ On rend donc explicite un REFUS, pas une permission. Ajouter ici des
-- policies `..._own` (auth.uid() = id) ne documenterait pas l'existant : ce
-- serait un élargissement de droits. En particulier un DELETE self-service
-- cascaderait `profiles -> projects -> tout le reste` en laissant la ligne
-- `auth.users` derrière — un compte vivant sans aucune donnée. Ce n'est pas
-- le comportement actuel et ce n'est pas souhaitable.
--
-- Comportement effectif inchangé ; seul l'audit y gagne (`pg_policies` liste
-- désormais les 4 commandes pour `profiles`, sans trou à interpréter).

drop policy if exists "profiles_insert_denied" on public.profiles;
create policy "profiles_insert_denied"
  on public.profiles for insert
  with check (false);

drop policy if exists "profiles_delete_denied" on public.profiles;
create policy "profiles_delete_denied"
  on public.profiles for delete
  using (false);

comment on table public.profiles is
  'Miroir 1:1 de auth.users. Alimente par le trigger handle_new_user (SECURITY DEFINER) ; supprime par cascade depuis auth.users. Les policies profiles_insert_denied / profiles_delete_denied documentent que ces deux commandes ne sont pas exposees aux clients.';


-- ============================================================================
-- 6. NON TRAITÉ — projects.user_id -> profiles(id) vs auth.users(id)
-- ============================================================================
-- ANOMALIE 5 de la référence. `projects_user_id_fkey` pointe sur
-- `public.profiles(id)` (jeu 1) et non sur `auth.users(id)` (jeu 2).
--
-- Ce n'est pas un défaut d'intégrité : `profiles.id` est lui-même une FK
-- CASCADE vers `auth.users(id)`, donc la suppression d'un compte propage bien
-- jusqu'aux projets. Les deux modèles se défendent :
--
--   * Garder profiles(id) — chaînage actuel. `profiles` devient la seule
--     table à connaître `auth`, le schéma applicatif reste autonome. Coût :
--     l'insertion d'un projet échoue tant que `handle_new_user` n'a pas créé
--     le profil (course possible juste après signup).
--   * Repointer vers auth.users(id) — un projet ne dépend plus de l'existence
--     du profil. Coût : deux tables applicatives couplées à `auth`, et la
--     jointure `projects -> profiles` (email, full_name) n'est plus garantie
--     par une contrainte.
--
-- Arbitrage produit, laissé au porteur de projet. Aucune modification n'est
-- appliquée ici. Si le choix se porte sur `auth.users(id)`, décommenter :
--
--   alter table public.projects
--     drop constraint projects_user_id_fkey;
--   alter table public.projects
--     add constraint projects_user_id_fkey
--     foreign key (user_id) references auth.users (id) on delete cascade;
--
-- (sur une base peuplée, vérifier d'abord que tout `projects.user_id` existe
-- bien dans `auth.users` — c'est garanti par le chaînage actuel, mais la
-- vérification coûte une requête.)
