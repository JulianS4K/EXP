#!/usr/bin/env bash
# The shared audience cap under real parallel sessions (mig 20261121190500,
# review of #138 S5): exos_ads_audience_source and exos_org_audience_export
# count their pulls in exos_audience_exports, 20 a day per org, under one
# per-org advisory lock held to commit. Run against a DB built by run_p0.sh:
#   bash tests/exos/race_audience_cap.sh exos_p0_test
# The org has 19 pulls today. One ads pull holds its transaction open (its
# log row uncommitted) while 9 more ads pulls and 4 exports start.
# Expect: exactly 1 pull succeeds and the log holds exactly 20 (before the
# lock, each later caller counted 19 and passed: 21+). The rest are refused
# by the daily cap or by the shared 3 a minute (a refused call rolls back
# its own minute hit, so here they all meet the daily cap).
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
# Fresh ids each run: the org audit log is append-only, so the org and its
# owner stay behind (the run_p0 DB is scratch); everything else is cleaned.
O=$($P -c "SELECT gen_random_uuid()"); A=$($P -c "SELECT gen_random_uuid()")
OUT="$(mktemp -d)"
cleanup() {
  $P -c "DELETE FROM exos_audience_exports WHERE org_id='$O'; DELETE FROM exos_rate_windows WHERE bucket='audience:$O';" >/dev/null
}
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','race-aud-'||left('$A',8)||'@x.com',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race Aud','race-aud-'||left('$O',8),'$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_audience_exports (org_id, row_count) SELECT '$O', 0 FROM generate_series(1, 19);" >/dev/null

ADS="SET LOCAL ROLE service_role; SELECT 'ok' FROM exos_ads_audience_source('$O', NULL, NULL);"
EXP="SELECT set_config('app.uid','$A',true); SET LOCAL ROLE authenticated; SELECT 'ok' FROM exos_org_audience_export('$O', NULL);"
run() { $P -c "BEGIN; $1 $2 COMMIT;" 2>&1 | grep -oE "^ok$|daily (audience|export) limit|too many [a-z ]+" | head -1 || true; }

( run "$ADS" "SELECT pg_sleep(2);" > "$OUT/holder" ) &
sleep 0.5
for i in $(seq 1 9); do ( run "$ADS" "" > "$OUT/ads$i" ) & done
for i in $(seq 1 4); do ( run "$EXP" "" > "$OUT/exp$i" ) & done
wait
OK=$(cat "$OUT"/* | grep -c '^ok$' || true)
DAILY=$(cat "$OUT"/* | grep -c 'daily' || true)
MINUTE=$(cat "$OUT"/* | grep -c 'too many' || true)
LOGGED=$($P -c "SELECT count(*) FROM exos_audience_exports WHERE org_id='$O'")
echo "  ok=$OK daily-cap=$DAILY minute-cap=$MINUTE logged=$LOGGED (holder: $(cat "$OUT/holder"))"
cleanup; rm -rf "$OUT"
if [ "$OK" = "1" ] && [ "$LOGGED" = "20" ] && [ $((OK + DAILY + MINUTE)) = "14" ]; then
  echo "OK  race: the shared 20 a day holds under parallel pulls (exactly 20 logged)"
else
  echo "FAIL race: expected 1 ok and 20 logged"; exit 1
fi
