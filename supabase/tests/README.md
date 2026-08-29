# `supabase/tests/`

Scripts d'assertion en SQL nu, un fichier par migration. Aucun runner
JavaScript : en ajouter un contredirait la raison d'être de ce repo, qui ne
contient pas de code applicatif.

## Lancer la suite

Contre une base locale fraîchement réinitialisée :

```bash
supabase db reset                     # rejoue les migrations + seed.sql
supabase test new --help >/dev/null   # (pgTAP n'est pas activé, cf. plus bas)

DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
for f in supabase/tests/*.test.sql; do
  echo "== $f"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$f" || exit 1
done
echo "OK"
```

Un fichier qui passe n'affiche rien d'autre que ses `NOTICE`. Un `assert` qui
échoue lève, `ON_ERROR_STOP=1` interrompt la boucle, et le message dit quelle
règle est tombée.

## Pourquoi pas pgTAP

`supabase test db` exige l'extension `pgtap`, qui n'est pas activée dans
`config.toml`. La consigne était de ne l'utiliser que si elle l'était déjà.
Les blocs `do $$ begin assert …; end $$;` de plpgsql font le même travail sans
extension : `plpgsql.check_asserts` est à `on` par défaut, un `assert` faux
lève une `assert_failure`, et psql s'arrête dessus.

## Forme de chaque fichier

Chaque fichier est autonome et **ne laisse aucune trace** :

```sql
begin;
  -- fixtures locales
  -- do $$ begin assert …; end $$;
rollback;
```

Le `rollback` final est ce qui permet de lancer les fichiers dans n'importe
quel ordre, plusieurs fois de suite, sans `db reset` entre deux.

## `helpers/`

Des scripts qui ne sont **pas** des tests et que la boucle ci-dessus ne ramasse
pas : leur nom ne finit pas par `.test.sql`. On les lance à la main, quand on
veut régénérer une valeur attendue.

- [`site_output_digests.sql`](helpers/site_output_digests.sql) — recalcule les
  empreintes de snapshot du livrable de site, une par cible de constructeur.
  À relancer quand un changement du rendu ou de la copie du catalogue est
  **voulu**, et après avoir lu ce qui a bougé.
- [`check_seed_mirrors.sh`](helpers/check_seed_mirrors.sh) — vérifie que chaque
  bloc de données balisé d'une migration est **identique octet pour octet** dans
  `seed.sql`, et qu'il y apparaît dans l'ordre des migrations. À lancer avec la
  suite :

  ```bash
  bash supabase/tests/helpers/check_seed_mirrors.sh
  ```

  Ce n'est pas du SQL, donc ce n'est pas un `.test.sql`. Il existe parce que le
  piège s'est refermé une fois : `20260829113000` a renommé
  `token.light_neutral`, `seed.sql` portait encore la formulation de
  `20260829110000`, et un `db reset` local la remettait en silence — le livrable
  cessait alors de correspondre à sa propre empreinte. C'est ainsi que ça a été
  trouvé, ce qui est à un hasard près de ne pas l'avoir été.

## Tester la RLS

`postgres` est superutilisateur et **contourne la RLS** — un test qui lit une
table sans changer de rôle ne teste rien. D'où, dans chaque test de
cloisonnement :

```sql
set local role authenticated;
set local request.jwt.claims = '{"sub":"<uuid>"}';
```

C'est ce que fait PostgREST pour une requête navigateur, et `auth.uid()` lit
exactement cette variable.
