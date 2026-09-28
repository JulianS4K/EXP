#!/usr/bin/env bash
# Scarcity-mode dry run: every scenario in scenarios.json through the real
# database functions, each in a transaction that is rolled back.
#   bash scripts/scarcity-sim/run.sh <db built by tests/exos/run_p0.sh> [report.md]
set -euo pipefail
cd "$(dirname "$0")"
DB="${1:-exos_p0_test}"; OUT="${2:-}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
SQL=$(mktemp); trap 'rm -f "$SQL"' EXIT
{
  echo '\set ON_ERROR_STOP on'
  echo '\pset tuples_only on'
  echo '\pset format unaligned'
  echo "SET client_min_messages = warning;"
  echo '\i engine.sql'
  python3 - <<'PY'
import json
for s in json.load(open("scenarios.json")):
    body = json.dumps(s).replace("'", "''")
    print("BEGIN;")
    print(f"SELECT '   ' || '{s['desc'].replace(chr(39), chr(39)*2)}';")
    print(f"SELECT * FROM pg_temp.sim('{body}'::jsonb);")
    print("ROLLBACK;")
    print("SELECT '';")
PY
} > "$SQL"
if [ -n "$OUT" ]; then
  psql -h "$H" -p "$PORT" -U "$U" -d "$DB" -q -f "$SQL" | tee "$OUT"
else
  psql -h "$H" -p "$PORT" -U "$U" -d "$DB" -q -f "$SQL"
fi
