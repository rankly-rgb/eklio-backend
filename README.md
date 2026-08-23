# eklio-backend

Source de vérité unique du **schéma de base de données** d'Eklio.

Le code applicatif Next.js vit dans un repo séparé, `eklio-frontend`. Ce repo-ci
ne contient que le schéma et sa configuration Supabase.

## Migrations

Toutes les migrations vivent dans [`supabase/migrations/`](supabase/migrations/)
et sont appliquées **exclusivement** via le CLI Supabase :

```bash
supabase link --project-ref <ref>
supabase db push
```

Aucune modification de schéma ne doit être faite à la main (éditeur SQL du
dashboard, API Management). C'est précisément ce qui a produit la dérive que
`20260823000000_reference_schema_from_live.sql` a dû rattraper : une base sans
table `supabase_migrations.schema_migrations`, donc sans historique, et trois
jeux de migrations concurrents dont aucun ne décrivait l'état réel.

`20260823000000_reference_schema_from_live.sql` est la **migration de
référence** : elle reconstitue le schéma réel observé le 2026-08-23 sur le
projet `enolgemfqeajrwpftppm` (eu-west-1), sans aucune donnée. Elle rend
obsolètes les trois jeux antérieurs :

| Repo | Branche | Fichiers |
|---|---|---|
| eklio-backend | `claude/eklio-bootstrap-ukuxfu` | `20260808000000_init_schema.sql` |
| eklio-frontend | `claude/eklio-design-system-flow-zmf8rl`, `claude/eklio-reconcile-us-base` | `20260809000000_init_projects.sql`, `20260815090000_init_directions.sql`, `20260816090000_fix_directions_schema.sql` |
| eklio-frontend | `claude/eklio-fr-us-migration-53dnk1` | `20260816000000_init_schema.sql`, `20260816010000_brand_kits.sql`, `20260816020000_billing.sql` |

## Schéma

Sept tables, RLS activée sur chacune, cloisonnement par propriétaire :

- `profiles` — miroir 1:1 de `auth.users`
- `projects` — une identité de marque en cours de génération
- `project_briefs` — le brief guidé, une ligne par projet
- `brief_answers` — le brief guidé, une ligne par étape *(doublon hérité, vide)*
- `directions` — les 3 propositions créatives d'un projet
- `brand_kits` — le kit de marque final
- `generation_credits` — quotas de génération IA

La migration de référence signale par des blocs `-- ⚠ ANOMALIE` les défauts
hérités de l'empilement des anciens jeux (doublons de triggers et de policies,
clé étrangère manquante sur `brand_kits.direction_id`). Ils sont reproduits tels
quels et seront corrigés par une migration de nettoyage dédiée.
