#!/usr/bin/env bash
# Every recent Exos migration must be exercised by the P0 SQL harness.
#
# tests/exos/run_p0.sh applies the migrations in order, runs the tests, then
# applies every pending migration AGAIN (the "Replay" loop) to prove it is
# re-run safe. A migration missing from either loop is never tested on CI.
# This checks each supabase/migrations/*exos*.sql from 20260926000000 on is
# named in both: the apply loops (before "# Replay") and the replay loop
# (after it).
#   bash scripts/check-migrations.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/tests/exos/run_p0.sh"
SINCE="${SINCE:-20260926000000}"

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
  [ "$ts" -ge "$SINCE" ] || continue
  if ! grep -qw -- "$name" <<<"$apply"; then
    echo "::error::$name is not applied by tests/exos/run_p0.sh (add it to the apply loop)" >&2
    missing=1
  fi
  if ! grep -qw -- "$name" <<<"$replay"; then
    echo "::error::$name is not in the replay loop of tests/exos/run_p0.sh (add it after '# Replay')" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then exit 1; fi
echo "check-migrations: every *exos* migration since $SINCE is applied and replayed by run_p0.sh"
