-- ============================================================================
-- Eklio — Lot 3 : kit de marque US
-- ============================================================================
-- Fait suite à `20260823150000_cleanup_inherited_anomalies.sql`.
--
-- CE QUE CE FICHIER NE FAIT PAS
-- -----------------------------
-- Il n'ajoute AUCUNE colonne pour le contenu du kit lui-même. `brand_kits`
-- porte déjà `content jsonb not null default '{}'`, et l'essentiel du livrable
-- y tient sans changement de schéma :
--   * positionnement & récit de marque
--   * guide de voix & ton
--   * textes de site par page — forme VARIABLE : le brief stocke
--     `pages_souhaitees` comme tableau JSON (observé : accueil, a_propos,
--     offres, tarifs, blog), et le nombre de pages change d'un projet à
--     l'autre. Une colonne par page serait ingérable ; c'est exactement le cas
--     d'usage du JSONB.
--   * specs de gabarits sociaux — même raisonnement, forme variable
--   * snapshot palette / typo figé depuis la direction choisie
--
-- Le prompt multi-plateformes a déjà sa colonne dédiée
-- (`multi_builder_prompt text`), le partage la sienne (`share_slug`, unique),
-- l'export la sienne (`pdf_url`). Rien à ajouter de ce côté.
--
-- CE QUI MANQUE RÉELLEMENT, ET POURQUOI EN COLONNE
-- -----------------------------------------------
-- Deux champs seulement, tous deux requêtables et contraints — donc mal placés
-- dans du JSONB libre.
-- ============================================================================


-- ============================================================================
-- 1. brand_kits.tier — périmètre du livrable
-- ============================================================================
-- Le scope du kit varie selon l'offre souscrite (Starter / Practice /
-- Signature). Aujourd'hui le seul signal de monétisation en base est
-- `generation_credits.has_paid`, un BOOLÉEN : il ne peut pas exprimer trois
-- niveaux. Le tier n'a donc littéralement aucun endroit où vivre.
--
-- ⚠ SÉMANTIQUE, à ne pas confondre au Lot 4 : cette colonne décrit CE QUE
-- CONTIENT CE KIT, pas ce à quoi l'utilisateur a droit. C'est un instantané du
-- périmètre au moment de la génération. Le droit courant (abonnement actif,
-- upgrade, expiration) appartiendra aux tables de facturation du Lot 4, qui ne
-- doivent pas redéfinir ce champ. Si un utilisateur passe à un tier supérieur,
-- on régénère ou complète le kit PUIS on met cette colonne à jour — elle suit
-- le livrable, pas l'abonnement.
--
-- Convention : `text` + CHECK, comme `projects.status`. Le schéma n'utilise
-- aucun enum Postgres (les enums du jeu 3 n'ont jamais été appliqués, cf. la
-- migration de référence) ; on reste cohérent, et un CHECK se fait évoluer
-- sans ALTER TYPE.
--
-- Défaut `'starter'` = le périmètre le plus restreint. Choisi comme mode de
-- défaillance sûr : si le code applicatif oublie de renseigner le tier, on
-- sous-livre (rattrapable) plutôt que de livrer du contenu payant gratuitement
-- (non rattrapable). La table contient 0 ligne à ce jour, donc le défaut ne
-- requalifie aucune donnée existante.

alter table public.brand_kits
  add column if not exists tier text not null default 'starter';

alter table public.brand_kits
  drop constraint if exists brand_kits_tier_check;

alter table public.brand_kits
  add constraint brand_kits_tier_check check (
    tier = any (array['starter'::text, 'practice'::text, 'signature'::text])
  );


-- ============================================================================
-- 2. brand_kits.status — état de complétion de la génération
-- ============================================================================
-- Le kit est produit en plusieurs sections. Sans colonne d'état, un kit
-- interrompu en cours de route est indiscernable d'un kit complet : il faudrait
-- inspecter les clés de `content` pour deviner, ce qui fait dépendre l'UI de la
-- forme interne du JSON.
--
-- Une colonne d'état rend la question requêtable et permet de reprendre une
-- génération échouée. Même convention `text` + CHECK.
--
-- Défaut `'pending'` : la ligne existe avant que la génération n'aboutisse.

alter table public.brand_kits
  add column if not exists status text not null default 'pending';

alter table public.brand_kits
  drop constraint if exists brand_kits_status_check;

alter table public.brand_kits
  add constraint brand_kits_status_check check (
    status = any (array['pending'::text, 'generating'::text,
                        'complete'::text, 'failed'::text])
  );


-- ============================================================================
-- 3. RLS — rien à faire, et c'est vérifié, pas supposé
-- ============================================================================
-- Les policies RLS de Postgres sont par LIGNE, pas par COLONNE : il n'existe
-- pas de policy qui couvrirait certaines colonnes et pas d'autres (le
-- cloisonnement par colonne relève des GRANT, pas des policies). La policy
-- `brand_kits_all_own` est `FOR ALL` avec USING et WITH CHECK sur la propriété
-- du projet : elle couvre donc automatiquement `tier` et `status`, comme toute
-- colonne future.
--
-- L'event trigger plateforme `ensure_rls` ne joue aucun rôle ici : il se
-- déclenche sur CREATE TABLE, pas sur ALTER TABLE ADD COLUMN. RLS était déjà
-- activée sur `brand_kits`, elle le reste.
--
-- Aucune policy n'est donc créée, modifiée ni supprimée par cette migration.

-- Garde-fou : si le cloisonnement propriétaire venait à disparaître, cette
-- migration doit échouer plutôt que laisser croire que le kit est protégé.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'brand_kits'
      and cmd        = 'ALL'
      and qual       is not null
  ) then
    raise exception
      'lot3_brand_kits_us: la policy owner-only attendue sur brand_kits est absente. Les colonnes tier/status seraient exposees. Migration interrompue.';
  end if;

  if not (select relrowsecurity from pg_class where oid = 'public.brand_kits'::regclass) then
    raise exception
      'lot3_brand_kits_us: RLS desactivee sur brand_kits. Migration interrompue.';
  end if;
end
$$;


-- ============================================================================
-- 4. NON TRAITÉ ICI — lecture publique via `share_slug`
-- ============================================================================
-- `share_slug` existe et est unique, mais AUCUNE policy ne permet à un visiteur
-- non authentifié de lire un kit partagé : `brand_kits_all_own` exige
-- `projects.user_id = auth.uid()`, et pour `anon` `auth.uid()` vaut NULL. La
-- page de partage ne fonctionnera donc pas tant qu'une policy publique en
-- lecture n'aura pas été ajoutée (ou tant que la lecture ne passera pas par le
-- `service_role` côté serveur, qui contourne RLS).
--
-- Ce n'est volontairement PAS fait ici : ouvrir `brand_kits` en lecture à
-- `anon` expose le contenu intégral du livrable payant à quiconque devine ou
-- collecte un slug. C'est un arbitrage produit et sécurité (slug suffisamment
-- entropique ? partage révocable ? exposition partielle ?), pas une décision
-- de migration. À traiter quand la page de partage sera au programme.
