#!/usr/bin/env bash
# scripts/local-verify.sh — full migration replay + SQL test suite, locally.
#
# Substitutes for `supabase db reset` + `supabase test db` in a sandbox that
# has a real local PostgreSQL server but no Docker (so `supabase start`
# can't run) and no network path to any Supabase-hosted endpoint. See
# DECISIONS.md in eklio-frontend, "Local verification, given no Docker and
# no Supabase REST access."
#
# Requires: a local `postgres` superuser role reachable via `sudo -u
# postgres psql` (adjust PSQL below if your setup differs), PostgreSQL
# server running.
#
# Usage: bash scripts/local-verify.sh

set -euo pipefail
cd "$(dirname "$0")/.."

DB=eklio_local_verify
PSQL="sudo -u postgres psql -v ON_ERROR_STOP=1"

echo "== Rebuilding $DB from scratch =="
sudo -u postgres dropdb --if-exists "$DB"
sudo -u postgres createdb "$DB"

echo "== Stub auth/storage schema =="
$PSQL -d "$DB" -f scripts/local-verify-stub-schema.sql

echo "== Replaying migrations =="
for f in supabase/migrations/*.sql; do
  echo "  $f"
  $PSQL -d "$DB" -f "$f"
done

echo "== Seed =="
$PSQL -d "$DB" -f supabase/seed.sql

echo "== Test suite =="
ran=0
failed=0
for f in supabase/tests/*.test.sql; do
  ran=$((ran + 1))
  echo "  $f"
  if ! $PSQL -d "$DB" -q -f "$f"; then
    failed=$((failed + 1))
    echo "  FAILED: $f"
  fi
done

echo ""
echo "== Seed mirrors =="
bash supabase/tests/helpers/check_seed_mirrors.sh

echo ""
echo "Migrations replayed clean. Tests: $ran run, $failed failed."
if [ "$failed" -ne 0 ]; then
  exit 1
fi
