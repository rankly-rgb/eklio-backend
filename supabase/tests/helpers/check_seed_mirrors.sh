#!/usr/bin/env bash
# ============================================================================
# Every marked data block in a migration must be byte-identical in seed.sql
# ============================================================================
# The repo ships catalog data twice on purpose: inside a migration, which is
# what reaches the hosted project, and inside `supabase/seed.sql`, which is what
# a local `db reset` replays. The README calls editing one without the other
# "the trap".
#
# It is a real trap. `20260829113000_site_spec_paper.sql` relabelled
# `token.light_neutral`; seed.sql still carried the older wording from
# `20260829110000`, and a local reset silently relabelled it back — the rendered
# output then stopped matching its own snapshot digest. That is how it was
# found, which is one accident away from not being found.
#
# Not SQL, so not a .test.sql file. Run it alongside the suite:
#
#   bash supabase/tests/helpers/check_seed_mirrors.sh
#
# ⚠ ORDER MATTERS TOO. A later migration that edits a row an earlier block also
# writes must be mirrored AFTER that block in seed.sql, or the earlier copy wins
# on reset. That is checked as well.
set -u
cd "$(dirname "$0")/../../.." || exit 1

seed=supabase/seed.sql
fail=0
prev_pos=0

grep -h '^-- >>> ' supabase/migrations/*.sql \
  | sed -e 's/^-- >>> //' -e 's/ (mirrored.*$//' -e 's/ *>*$//' \
  | awk '!seen[$0]++' > /tmp/_markers.txt

while IFS= read -r marker; do
  [ -z "$marker" ] && continue
  mig=$(grep -l "^-- >>> $marker" supabase/migrations/*.sql | head -1)
  [ -z "$mig" ] && continue

  awk -v m="$marker" '$0 ~ "^-- >>> "m {p=1} p; $0 ~ "^-- <<< "m {p=0}' "$mig"   > /tmp/_mig.sql
  awk -v m="$marker" '$0 ~ "^-- >>> "m {p=1} p; $0 ~ "^-- <<< "m {p=0}' "$seed"  > /tmp/_seed.sql

  if [ ! -s /tmp/_seed.sql ]; then
    echo "MISSING  $marker  (in $(basename "$mig"), not in seed.sql)"; fail=1; continue
  fi
  if ! diff -q /tmp/_mig.sql /tmp/_seed.sql >/dev/null; then
    echo "DRIFT    $marker  ($(basename "$mig") vs seed.sql)"
    diff /tmp/_mig.sql /tmp/_seed.sql | head -12 | sed 's/^/         /'
    fail=1; continue
  fi

  pos=$(grep -n "^-- >>> $marker" "$seed" | head -1 | cut -d: -f1)
  if [ "$pos" -lt "$prev_pos" ]; then
    echo "ORDER    $marker is mirrored before a block from an earlier migration"; fail=1
  fi
  prev_pos=$pos
  echo "ok       $marker"
done < /tmp/_markers.txt

if [ "$fail" -eq 0 ]; then echo "all seed mirrors match"; else echo "SEED MIRRORS OUT OF SYNC"; fi
exit "$fail"
