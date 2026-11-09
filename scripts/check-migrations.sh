#!/usr/bin/env bash
# Every recent Exos migration must be exercised by the P0 SQL harness.
#
# tests/exos/run_p0.sh applies the migrations in order, runs the tests, then
# applies every pending migration AGAIN (the "Replay" loop) to prove it is
# re-run safe. A migration missing from either loop is never tested on CI.
# This checks that EVERY supabase/migrations/*exos*.sql is named in the apply
# loop (before "# Replay"): the harness builds the database the way prod was
# built (supabase/README.md migration rule 4). Each one from 20260924215000
# on, the first written to be re-run safe, must also be in the replay loop
# (after it); the older ones are applied-once history (see run_p0.sh).
#   bash scripts/check-migrations.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/tests/exos/run_p0.sh"
SINCE="${SINCE:-20260924215000}"   # replay required from here

marker=$(grep -n '^# Replay' "$RUN" | head -1 | cut -d: -f1 || true)
if [ -z "$marker" ]; then
  echo "::error::$RUN has no '# Replay' section" >&2
  exit 1
fi
apply=$(head -n "$((marker - 1))" "$RUN")
replay=$(tail -n "+$marker" "$RUN")

missing=0
for f in "$ROOT"/supabase/migrations/*exos*.sql; do
  name=$(basename "$f" .sql)
  ts=${name%%_*}
  [[ "$ts" =~ ^[0-9]{14}$ ]] || { echo "::error::$name: no 14-digit timestamp prefix" >&2; missing=1; continue; }
  if ! grep -qw -- "$name" <<<"$apply"; then
    echo "::error::$name is not applied by tests/exos/run_p0.sh (add it to the apply loop)" >&2
    missing=1
  fi
  [ "$ts" -ge "$SINCE" ] || continue
  if ! grep -qw -- "$name" <<<"$replay"; then
    echo "::error::$name is not in the replay loop of tests/exos/run_p0.sh (add it after '# Replay')" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then exit 1; fi
echo "check-migrations: every *exos* migration is applied by run_p0.sh, and each since $SINCE replayed"
