#!/usr/bin/env bash
# Concurrency check for guest promo codes (mig 20261121143700, review of #132
# S4): exos_check_voucher_guest reserves each attempt in one statement per
# bucket before the lookup, so concurrent misses can't overshoot a cap. Under
# the old read-then-record order, 64 parallel misses spent 91 of an event's 30.
# Run against a DB built by run_p0.sh (CI does):
#   bash tests/exos/race_guest_codes.sh exos_p0_test
# Expect: (1) 64 misses from 64 networks on one event at the same instant:
# exactly 30 answer 'invalid code', the rest 'too many attempts', and the
# event's bucket holds 30; (2) 40 misses from ONE network: exactly 10 answer
# 'invalid code' and the network's bucket holds 10; (3) a usable code tried
# 40 times at once from one network gives every attempt back (bucket 0).
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=6b000000-0000-0000-0000-000000000001; A=6b000000-0000-0000-0000-0000000000a1
E1=6b000000-0000-0000-0000-0000000000e1; E2=6b000000-0000-0000-0000-0000000000e2; E3=6b000000-0000-0000-0000-0000000000e3
OUT=""
cleanup() {
  $P -c "DELETE FROM exos_voucher_attempts WHERE bucket LIKE 'ge:6b000000-%' OR bucket LIKE 'g:%' AND bucket IN
           (SELECT 'g:' || encode(sha256(('race-guest-' || n)::bytea), 'hex') FROM generate_series(1, 200) n);
         DELETE FROM exos_vouchers WHERE event_id IN ('$E1','$E2','$E3');
         DELETE FROM exos_ticket_tiers WHERE event_id IN ('$E1','$E2','$E3');
         DELETE FROM exos_events WHERE org_id='$O'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';" >/dev/null
  [ -n "$OUT" ] && rm -rf "$OUT"
  return 0
}
cleanup || true
OUT="$(mktemp -d)"
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','race-guest@x.com',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race guest','race-guest','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
         ('$E1','$O','Race 1','race-guest-1','published',now() + interval '10 days','Hall',0,0),
         ('$E2','$O','Race 2','race-guest-2','published',now() + interval '10 days','Hall',0,0),
         ('$E3','$O','Race 3','race-guest-3','published',now() + interval '10 days','Hall',0,0);
       INSERT INTO exos_vouchers(event_id,code,max_uses,bypass_capacity) VALUES ('$E3','RACEOK',1000,false);" >/dev/null

# One guest check: name, event, code, network number, all starting at START.
one() {
  local name="$1" ev="$2" code="$3" net="$4"
  $P -c "SELECT set_config('request.jwt.claims', '{\"role\":\"service_role\"}', false)" \
     -c "SELECT pg_sleep_until('$START')" \
     -c "SELECT reason FROM exos_check_voucher_guest('$ev', '$code', encode(sha256('race-guest-$net'::bytea), 'hex'))" \
     2>&1 | tail -1 > "$OUT/$name" || echo FAILED > "$OUT/$name"
}
spent() { $P -c "SELECT coalesce(sum(failures), 0) FROM exos_voucher_attempts WHERE bucket = '$1'"; }
count() { grep -lx -- "$2" "$OUT"/"$1"-* 2>/dev/null | wc -l | tr -d ' '; }
fail=0

# (1) 64 networks, one event.
START=$($P -c "SELECT (clock_timestamp() + interval '2 seconds')::text")
for i in $(seq 1 64); do one "ev-$i" "$E1" "MISS$i" "$i" & done; wait
ok=$(count ev 'invalid code'); refused=$(count ev 'too many attempts'); b=$(spent "ge:$E1")
echo "per event: $ok invalid, $refused refused, bucket $b"
if [ "$ok" != 30 ] || [ "$refused" != 34 ] || [ "$b" != 30 ]; then echo "FAIL: per-event cap overshot or undershot"; fail=1; fi

# (2) one network, 40 tries at once (another event, so (1) doesn't interfere).
START=$($P -c "SELECT (clock_timestamp() + interval '2 seconds')::text")
for i in $(seq 1 40); do one "net-$i" "$E2" "MISS$i" 150 & done; wait
ok=$(count net 'invalid code'); b=$(spent "g:$($P -c "SELECT encode(sha256('race-guest-150'::bytea), 'hex')")")
echo "per network: $ok invalid, bucket $b"
if [ "$ok" != 10 ] || [ "$b" != 10 ]; then echo "FAIL: per-network cap overshot or undershot"; fail=1; fi

# (3) a usable code, 40 at once from one network: nothing stays spent.
START=$($P -c "SELECT (clock_timestamp() + interval '2 seconds')::text")
for i in $(seq 1 40); do one "hit-$i" "$E3" "RACEOK" 151 & done; wait
b=$(spent "g:$($P -c "SELECT encode(sha256('race-guest-151'::bytea), 'hex')")"); e=$(spent "ge:$E3")
bad=$(cat "$OUT"/hit-* | grep -c . || true)
echo "usable code: network bucket $b, event bucket $e, non-empty answers $bad"
if [ "$b" != 0 ] || [ "$e" != 0 ] || [ "$bad" != 0 ]; then echo "FAIL: a usable code kept an attempt"; fail=1; fi

[ "$fail" -eq 0 ] && echo "race_guest_codes: ok"
exit "$fail"
