#!/usr/bin/env bash
# Static door codes (claude/exos-static-tickets, mig 20261121153000): the same
# S- code scanned at two doors at once, in real parallel sessions. The first
# holds its transaction open (pg_sleep) so the second starts while it is
# uncommitted. Run against a DB built by run_p0.sh (CI does):
#   bash tests/exos/race_static_codes.sh exos_p0_test
# Expect, for each of ROUNDS tickets: one 'checked-in', the other 'used' (the
# atomic status flip), one admission. Exits 1 otherwise. The tickets are
# issued static explicitly, so the free-tier setting run_p0.sh leaves off
# doesn't matter here.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
ROUNDS="${ROUNDS:-5}"
O=5c500000-0000-0000-0000-000000000001; A=5c500000-0000-0000-0000-0000000000a0; HOLDER=5c500000-0000-0000-0000-0000000000c1
E=5c500000-0000-0000-0000-0000000000e1; T=5c500000-0000-0000-0000-0000000000d1
tk() { printf '5c500000-0000-0000-0000-0000000c%04d' "$1"; }
cleanup() {
  $P -c "DELETE FROM exos_scan_rejects WHERE event_id='$E'; DELETE FROM exos_event_checkins WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E'; DELETE FROM exos_ticket_tiers WHERE event_id='$E';
         DELETE FROM exos_events WHERE id='$E'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id IN ('$A','$HOLDER');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-static.test',now()),('$HOLDER','fan@race-static.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race static','race-static','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,currency,created_by)
         VALUES ('$E','$O','Race','race-static','published',now() - interval '1 hour',100,0,'usd','$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES ('$T','$E','GA',20,100,0,'public',1);
       INSERT INTO exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source,code_mode)
       SELECT ('5c500000-0000-0000-0000-0000000c' || lpad(n::text, 4, '0'))::uuid,'$E','$O','$T','GA','$HOLDER','$HOLDER','fan@race-static.test',
              'active','sek-static-'||n,20,'race-static-'||n,'stripe','static'
         FROM generate_series(1, $ROUNDS) n;" >/dev/null
AS="SELECT set_config('app.uid','$A',false);"
scan() { echo "public.exos_check_in_ticket('$1','camera','verified','$2','$E',NULL,NULL,'$3',NULL,'entry')->>'reason'"; }
fail=0
for i in $(seq 1 "$ROUNDS"); do
  t=$(tk "$i")
  code=$($P -c "SELECT public._exos_static_code(id, owner_id, barcode_secret) FROM exos_tickets WHERE id='$t'")
  out="$(mktemp)"
  ( $P -c "$AS BEGIN; SELECT 'first '||($(scan "$t" "$code" door-1)); SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -o "first [a-z-]*\|ERROR: .*" >>"$out" || true ) &
  sleep 0.5
  ( $P -c "$AS SELECT 'second '||($(scan "$t" "$code" door-2));" 2>&1 | grep -o "second [a-z-]*\|ERROR: .*" >>"$out" || true )
  wait
  n=$($P -c "SELECT count(*) FROM exos_event_checkins WHERE ticket_id='$t' AND direction='entry'")
  answers=$(sort "$out" | tr '\n' ' ')
  rm -f "$out"
  echo "round $i: $answers-> admissions=$n"
  if [ "$n" != 1 ] || ! grep -q "first checked-in" <<<"$answers" || ! grep -q "second used" <<<"$answers"; then
    echo "::error::race_static_codes round $i: expected one checked-in, one used, one admission" >&2
    fail=1
  fi
done
exit "$fail"
