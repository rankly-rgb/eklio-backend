#!/usr/bin/env bash
# scripts/verify-recovered-migrations.sh
#
# Les onze migrations du 14 septembre ont été appliquées en production par
# `apply_migration` et jamais committées. Ce qui a tourné était un EXTRAIT : la
# prose avait été retirée en chemin. Les fichiers complets existaient sur
# `claude/foundation-lot3-wiring`, et c'est cette version-là que le dépôt porte.
#
# ⚠ CE SCRIPT PROUVE « MÊME SQL, COMMENTAIRES EN PLUS », PAS « SE RESSEMBLE ».
#
# Il compare des FLUX DE TOKENS produits par scripts/sql_tokens.py — un vrai
# lexer PostgreSQL — et non des octets. Un commentaire ajouté ne change pas le
# flux ; une clause WHERE retirée, si. Voir supabase/migrations/RECOVERED.manifest
# pour ce que chaque colonne veut dire et pour le seul écart toléré, qui est
# nommé, borné et daté.
#
# Usage : bash scripts/verify-recovered-migrations.sh
set -u
cd "$(dirname "$0")/.." || exit 1

python3 - "$@" <<'PY'
import sys, os, hashlib
sys.path.insert(0, 'scripts')
from sql_tokens import tokens

def deep(sql, d=0):
    """Le flux de tokens d'un FICHIER DE MIGRATION : comme tokens(), mais en
    ouvrant les dollar-quotes, parce qu'ici un `do $$ … $$` est du code et que
    les commentaires qui nous intéressent vivent dedans."""
    out = []
    for t in tokens(sql):
        if d < 4 and t.startswith('$') and len(t) > 2:
            e = t.find('$', 1)
            if e > 0:
                tag = t[:e + 1]
                if t.endswith(tag) and len(t) > 2 * len(tag):
                    out.append(tag)
                    out.extend(deep(t[len(tag):-len(tag)], d + 1))
                    continue
        out.append(t)
    return out

manifest = 'supabase/migrations/RECOVERED.manifest'
checked = fail = 0
for line in open(manifest):
    if line.startswith('#') or not line.strip():
        continue
    ran, want, ntok, raw, name = line.split()
    path = 'supabase/migrations/' + name
    checked += 1

    if not os.path.isfile(path):
        print(f'MANQUANT  {name}'); fail += 1; continue

    body = open(path).read()
    got = hashlib.md5('\x00'.join(deep(body)).encode()).hexdigest()
    if got != want:
        print(f'CHANGE    {name}')
        print(f'          le flux de tokens du fichier a bougé depuis le manifeste')
        print(f'          attendu {want}, obtenu {got}')
        fail += 1
        continue

    note = 'identique à ce qui a tourné' if ran == want else 'écart nommé au manifeste'
    print(f'ok        {name}  ({ntok} tokens, {note})')

# ⚠ ANTI-VACUITÉ. Un manifeste vide ou illisible n'imprimerait rien et
# sortirait en 0 — ce qui se lit exactement comme « les onze sont vérifiées ».
if checked < 11:
    print(f'REFUS : le manifeste ne liste que {checked} migration(s), 11 attendues.')
    sys.exit(2)

print()
if fail:
    print(f'{fail} des {checked} migrations récupérées N\'EXÉCUTENT PLUS ce que la production a exécuté.')
    sys.exit(1)
print(f'{checked} migrations récupérées exécutent ce que la production a exécuté.')
PY
