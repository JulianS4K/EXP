#!/usr/bin/env bash
# Re-apply check (mig 20261121100000 review): apply one migration a SECOND
# time on a database it was already applied to, and prove it changes nothing.
#   bash tests/exos/reapply_check.sh <db> <migration name>
# Checks: every exos_patch_n call in the file reports "already patched"
# (its marker is in the body it wrote), and every function in public has the
# same md5 of its definition before and after. A marker that isn't a
# substring of its own new text re-applies the patch on every run (the
# new text still contains the search text) and fails both checks.
set -euo pipefail
DB="${1:?db}"; NAME="${2:?migration name}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="${REAPPLY_FILE:-$DIR/../../supabase/migrations/$NAME.sql}"
Q="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
snap() { $Q -c "SELECT p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid))
                  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.prokind = 'f' ORDER BY 1"; }
before=$(snap)
patches=$(grep -c "^SELECT pg_temp\.exos_patch_n(" "$FILE" || true)
notices=$(psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$FILE" 2>&1 >/dev/null | grep -c 'already patched' || true)
after=$(snap)
fail=0
if [ "$notices" -ne "$patches" ]; then echo "reapply_check $NAME: $notices of $patches patches report already patched"; fail=1; fi
changed=$(diff <(echo "$before") <(echo "$after") | grep '^>' | cut -c3- | cut -d' ' -f1 || true)
if [ -n "$changed" ]; then echo "reapply_check $NAME: changed on re-apply: $changed"; fail=1; fi
[ "$fail" -eq 0 ] && echo "reapply_check $NAME: $patches patches already patched, $(echo "$before" | wc -l) function bodies unchanged"
exit $fail
