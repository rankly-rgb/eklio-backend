# eklio-backend

Source de vérité unique du **schéma de base de données** d'Eklio.

Le code applicatif Next.js vit dans un repo séparé, `eklio-frontend`. Ce repo-ci
ne contient que le schéma et sa configuration Supabase.

## Projet Supabase

| Ref | Région | Rôle |
|---|---|---|
| `fobgdsupyfslxbswfuay` | `us-east-1` | **actif** — cible de toutes les migrations |
| `enolgemfqeajrwpftppm` | `eu-west-1` | ancien projet, données de test. Conservé intact comme filet de sécurité. **Ne jamais y pousser de migration.** |

## Migrations

Toutes les migrations vivent dans [`supabase/migrations/`](supabase/migrations/)
et sont appliquées **exclusivement** via le CLI Supabase :

```bash
supabase link --project-ref fobgdsupyfslxbswfuay
supabase db push
```

Aucune modification de schéma ne doit être faite à la main (éditeur SQL du
dashboard, API Management). C'est précisément ce qui a produit la dérive que
`20260823000000_reference_schema_from_live.sql` a dû rattraper : une base sans
table `supabase_migrations.schema_migrations`, donc sans historique, et trois
jeux de migrations concurrents dont aucun ne décrivait l'état réel.

### `20260823000000_reference_schema_from_live.sql`

La **migration de référence**. Elle reconstitue le schéma réel observé le
2026-08-23 sur `enolgemfqeajrwpftppm` (eu-west-1), sans aucune donnée, anomalies
héritées comprises — celles-ci sont balisées par des blocs `-- ⚠ ANOMALIE`.
Reproduire fidèlement l'existant était le but : la réparation vient après, et
séparément, pour que l'historique se lise « ce qui existait » → « ce qu'on a
réparé ».

Elle rend obsolètes les trois jeux antérieurs, dont les branches ont été
supprimées :

| Repo | Branche | Fichiers |
|---|---|---|
| eklio-backend | `claude/eklio-bootstrap-ukuxfu` *(supprimée)* | `20260808000000_init_schema.sql` |
| eklio-frontend | `claude/eklio-design-system-flow-zmf8rl`, `claude/eklio-reconcile-us-base` | `20260809000000_init_projects.sql`, `20260815090000_init_directions.sql`, `20260816090000_fix_directions_schema.sql` |
| eklio-frontend | `claude/eklio-fr-us-migration-53dnk1` | `20260816000000_init_schema.sql`, `20260816010000_brand_kits.sql`, `20260816020000_billing.sql` |

### `20260823150000_cleanup_inherited_anomalies.sql`

Le **nettoyage**, appliqué. Il répare les anomalies balisées par la référence :

- clé étrangère `brand_kits.direction_id → directions(id)` rétablie, en
  `ON DELETE NO ACTION` (+ index sur la colonne référençante) ;
- trigger `updated_at` en double supprimé sur `projects` ;
- policy `FOR ALL` redondante supprimée sur `projects` ;
- table `brief_answers` supprimée (doublon inutilisé de `project_briefs`) ;
- `INSERT` / `DELETE` explicitement refusés sur `profiles` — ce qui documente
  l'existant sans élargir aucun droit.

Une anomalie a été **volontairement conservée** : `projects.user_id` référence
`profiles(id)` et non `auth.users(id)`. Ce n'est pas un défaut d'intégrité
(`profiles.id` cascade lui-même depuis `auth.users`), et le chaînage garde
`profiles` comme seule table applicative couplée à `auth`. Son seul coût est une
course possible juste après signup, qui sera traitée côté applicatif.

## Schéma

Six tables, RLS activée sur chacune, cloisonnement par propriétaire :

- `profiles` — miroir 1:1 de `auth.users`, alimenté par le trigger
  `handle_new_user` ; `INSERT` / `DELETE` non exposés aux clients
- `projects` — une identité de marque en cours de génération
- `project_briefs` — le brief guidé, une ligne par projet
- `directions` — les 3 propositions créatives d'un projet
- `brand_kits` — le kit de marque final
- `generation_credits` — quotas de génération IA

Aucune table n'est en `FORCE ROW LEVEL SECURITY` : le `service_role`, utilisé
côté serveur, contourne les policies.
