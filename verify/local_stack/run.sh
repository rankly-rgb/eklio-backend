#!/usr/bin/env bash
# ============================================================================
# Local verification stack — apply every migration, run every test, against
# a throwaway local Postgres. See README.md in this directory.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ADMIN_URL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
DB_NAME="${EKLIO_VERIFY_DB:-eklio_verify}"
DB_URL="${ADMIN_URL%/*}/${DB_NAME}"

echo "== dropping/recreating ${DB_NAME} =="
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q -c "drop database if exists ${DB_NAME};"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q -c "create database ${DB_NAME};"

echo "== loading schema stubs =="
psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$SCRIPT_DIR/schema_stubs.sql"

MIG_PASS=0
echo "== applying migrations =="
for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
  fname="$(basename "$f")"
  if out=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); then
    echo "PASS  migration  ${fname}"
    MIG_PASS=$((MIG_PASS + 1))
  else
    echo "FAIL  migration  ${fname}"
    echo "$out"
    echo ""
    echo "Migrations applied before failure: ${MIG_PASS}"
    exit 1
  fi
done

TEST_PASS=0
TEST_FAIL=0
echo "== running tests =="
for f in "$REPO_ROOT"/supabase/tests/*.test.sql; do
  fname="$(basename "$f")"
  if out=$(psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); then
    echo "PASS  test  ${fname}"
    TEST_PASS=$((TEST_PASS + 1))
  else
    echo "FAIL  test  ${fname}"
    echo "$out"
    echo ""
    echo "Migrations applied: ${MIG_PASS}"
    echo "Tests: ${TEST_PASS} passed, 1 failed (stopped at first failure)"
    exit 1
  fi
done

echo ""
echo "Migrations applied: ${MIG_PASS}"
echo "Tests: ${TEST_PASS} passed, ${TEST_FAIL} failed"
