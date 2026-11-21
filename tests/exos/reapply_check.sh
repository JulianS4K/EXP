#!/usr/bin/env bash
# Re-apply check (mig 20261121100000 review): apply one migration a SECOND
# time on a database it was already applied to, and prove it changes nothing.
#   bash tests/exos/reapply_check.sh <db> <migration name> [later migration ...]
# Later migrations that replace a function this one also writes in full
# (CREATE OR REPLACE) are re-applied after it, in order, in the same check:
# re-applying the earlier one alone would roll those functions back to its
# version and read as a change.
# Checks: every exos_patch_n call in the file reports "already patched"
# (its marker is in the body it wrote), and every function in public has the
# same md5 of its definition before and after. A marker that isn't a
# substring of its own new text re-applies the patch on every run (the
# new text still contains the search text) and fails both checks.
set -euo pipefail
DB="${1:?db}"; NAME="${2:?migration name}"; shift 2
LATER=("$@")
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="${REAPPLY_FILE:-$DIR/../../supabase/migrations/$NAME.sql}"
Q="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
snap() { $Q -c "SELECT p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid))
                  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.prokind = 'f' ORDER BY 1"; }
before=$(snap)
FILES=("$FILE")
for l in "${LATER[@]}"; do FILES+=("$DIR/../../supabase/migrations/$l.sql"); done
patches=0; notices=0
for f in "${FILES[@]}"; do
  n=$(grep -c "^SELECT pg_temp\.exos_patch_n(" "$f" || true)
  m=$(psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1 >/dev/null | grep -c 'already patched' || true)
  patches=$((patches + n)); notices=$((notices + m))
done
[ "${#LATER[@]}" -gt 0 ] && NAME="$NAME (then ${LATER[*]})"
after=$(snap)
fail=0
if [ "$notices" -ne "$patches" ]; then echo "reapply_check $NAME: $notices of $patches patches report already patched"; fail=1; fi
changed=$(diff <(echo "$before") <(echo "$after") | grep '^>' | cut -c3- | cut -d' ' -f1 || true)
if [ -n "$changed" ]; then echo "reapply_check $NAME: changed on re-apply: $changed"; fail=1; fi
[ "$fail" -eq 0 ] && echo "reapply_check $NAME: $patches patches already patched, $(echo "$before" | wc -l) function bodies unchanged"
exit $fail
