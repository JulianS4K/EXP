#!/usr/bin/env bash
# DICE import races (mig 20261106100000), in real parallel sessions.
# Timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_dice_import.sh exos_p0_test
# Expect:
#   race 1 two dry runs at once: the first holds the connection row's lock
#          (uncommitted) when the second starts; the second waits, then sees
#          the first's reserved row and is refused (a preview is already
#          running). Exactly one running dry run.
#   race 2 a dry run and a sync claim at once: whichever is second is refused
#          (a preview is running / a DICE sync is running).
#   race 3 eleven connect attempts at once for one org: exactly 10 recorded.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=d1ce0000-0000-0000-0000-00000000aa01; A=d1ce0000-0000-0000-0000-00000000aaa0
cleanup() {
  $P -c "DELETE FROM exos_dice_import_runs WHERE org_id='$O'; DELETE FROM exos_dice_connect_attempts WHERE org_id='$O';
         DELETE FROM exos_dice_connections WHERE org_id='$O'; DELETE FROM vault.secrets WHERE name='exos_dice:$O';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-dice.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race DICE','race-dice','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       SELECT public.exos_dice_connect('$O','$A','tok_dice_race_0123456789','viewer-race','Race');" >/dev/null
reset_runs() { $P -c "DELETE FROM exos_dice_import_runs WHERE org_id='$O'; UPDATE exos_dice_connections SET lease_id=NULL, lease_until=NULL, run_id=NULL, last_sync_at=NULL WHERE org_id='$O';" >/dev/null; }
running() { $P -c "SELECT count(*) FROM exos_dice_import_runs WHERE org_id='$O' AND status='running'"; }
fail=0

# race 1: two dry runs.
reset_runs
$P -c "BEGIN; SELECT run_id FROM public.exos_dice_dry_run_begin('$O','$A','dashboard'); SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "SELECT run_id FROM public.exos_dice_dry_run_begin('$O','$A','api')" 2>&1 || true)
wait
if [[ "$out" == *"a preview is already running"* && "$(running)" == 1 ]]; then
  echo "OK   race 1 two dry runs at once: one reserved, the other refused"
else
  echo "FAIL race 1: $out / running $(running)"; fail=1
fi

# race 2: a dry run in flight, then a sync claim.
reset_runs
$P -c "BEGIN; SELECT run_id FROM public.exos_dice_dry_run_begin('$O','$A','dashboard'); SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "SELECT lease_id FROM public.exos_dice_sync_claim('$O','$A','dashboard')" 2>&1 || true)
wait
if [[ "$out" == *"a preview is running"* && "$(running)" == 1 ]]; then
  echo "OK   race 2 a sync while a dry run reserves: refused"
else
  echo "FAIL race 2: $out / running $(running)"; fail=1
fi

# race 3: eleven connect attempts at once.
$P -c "DELETE FROM exos_dice_connect_attempts WHERE org_id='$O'" >/dev/null
for i in $(seq 1 11); do
  $P -c "SELECT public.exos_dice_connect_begin('$O','$A')" >/dev/null 2>&1 &
done
wait
n=$($P -c "SELECT count(*) FROM exos_dice_connect_attempts WHERE org_id='$O'")
if [[ "$n" == 10 ]]; then
  echo "OK   race 3 eleven connect attempts at once: exactly 10 allowed"
else
  echo "FAIL race 3: $n attempts recorded"; fail=1
fi
exit $fail
