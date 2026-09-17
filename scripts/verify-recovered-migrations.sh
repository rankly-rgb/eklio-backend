#!/usr/bin/env bash
# scripts/verify-recovered-migrations.sh
#
# The eleven migrations of 14 September were applied to production through
# `apply_migration` and never committed. They were recovered on 17 September
# from `supabase_migrations.schema_migrations.statements`, which stores the text
# that actually ran.
#
# ⚠ THIS SCRIPT IS WHY "EXACTLY WHAT RAN" IS A FACT AND NOT A MEMORY.
#
# Their headers say "Fichier complet : supabase/migrations/<other name>.sql" —
# a path that has never existed in this repository, under yet another timestamp.
# Whatever fuller file the previous session wrote, only this excerpt reached the
# database, and only this excerpt describes it. Reformat one of these eleven and
# the repository stops describing production again; this refuses.
#
# Usage: bash scripts/verify-recovered-migrations.sh
set -u
cd "$(dirname "$0")/.." || exit 1

manifest=supabase/migrations/RECOVERED.md5
fail=0
checked=0

while read -r want bytes chars name; do
  case "$want" in '#'*|'') continue;; esac
  path="supabase/migrations/$name"
  checked=$((checked + 1))

  if [ ! -f "$path" ]; then
    echo "MISSING  $name"
    fail=$((fail + 1))
    continue
  fi

  # The stored statement has no trailing newline; the file does. Compare the
  # file with its last newline removed, and only when the sizes agree on that.
  # `bytes` is what the shell can measure; `chars` is what Postgres reported and
  # is recorded beside it so the two are never confused again.
  size=$(wc -c < "$path" | tr -d ' ')
  if [ "$size" -ne "$((bytes + 1))" ]; then
    echo "SIZE     $name  ($size bytes, expected $((bytes + 1)))"
    fail=$((fail + 1))
    continue
  fi

  got=$(head -c "$bytes" "$path" | md5sum | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    echo "CHANGED  $name  (md5 $got, production recorded $want)"
    fail=$((fail + 1))
  else
    echo "ok       $name"
  fi
done < "$manifest"

# ⚠ ANTI-VACUOUS. An empty or unreadable manifest would print nothing and exit
# 0, which reads exactly like "all eleven verified".
if [ "$checked" -lt 11 ]; then
  echo "REFUSING: the manifest listed only $checked migration(s), expected 11."
  exit 2
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo "$fail of $checked recovered migration(s) NO LONGER MATCH what production ran."
  exit 1
fi
echo "$checked recovered migrations are byte-identical to what production ran."
