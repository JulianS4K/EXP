#!/usr/bin/env bash
# Organizer mistake races (tests/exos/sim_organizer.sql, mig 20261104110000):
# real sessions racing. Not in CI (timing-based); run by hand against a DB
# built by run_p0.sh:
#   bash tests/exos/race_sim_organizer.sh exos_p0_test
# Expect: race 1 the dashboard and the API refund the same order at once
# (different keys): one claim wins, the other is told nothing is left, one
# request on the order; race 2 the org's two owners demote each other at
# once: one wins, the other is refused (the last owner), one owner left.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=5b000000-0000-0000-0000-000000000001; A=5b000000-0000-0000-0000-0000000000a1; B=5b000000-0000-0000-0000-0000000000a2
F=5b000000-0000-0000-0000-0000000000a3; E=5b000000-0000-0000-0000-0000000000e1
cleanup() {
  $P -c "DELETE FROM exos_order_refunds WHERE org_id='$O'; DELETE FROM exos_refund_request_items WHERE request_id IN (SELECT id FROM exos_refund_requests WHERE org_id='$O');
         DELETE FROM exos_refund_requests WHERE org_id='$O'; DELETE FROM exos_order_payments WHERE session_id='cs_race_sim';
         DELETE FROM exos_tickets WHERE org_id='$O'; DELETE FROM exos_checkout_sessions WHERE org_id='$O';
         DELETE FROM exos_events WHERE id='$E'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id IN ('$A','$B','$F');
         REVOKE SELECT, UPDATE ON exos_org_memberships FROM authenticated;" >/dev/null
}
cleanup
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','a@race-sim.example',now()),('$B','b@race-sim.example',now()),('$F','f@race-sim.example',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race sim','race-sim-org','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner'),('$O','$B','owner'),('$O','$F','finance');
       INSERT INTO exos_events(id,org_id,name,status,starts_at,timezone) VALUES ('$E','$O','Race','published',now() + interval '10 days','UTC');
       INSERT INTO exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent)
       VALUES ('cs_race_sim','$E','$O','$A','a@race-sim.example',1,5000,'fulfilled','pi_race_sim');
       SELECT public.exos_record_payment('cs_race_sim','pi_race_sim',5000,'succeeded');
       GRANT SELECT, UPDATE ON exos_org_memberships TO authenticated;" >/dev/null

echo "race 1: the dashboard and the API refund the same order at once"
( $P -c "BEGIN; SELECT '  dashboard: '||(public.exos_refund_claim('$F','cs_race_sim','race-sim-dashboard',NULL,NULL,true,'dash')->>'amount_cents'); SELECT pg_sleep(2); COMMIT;" ) &
sleep 0.5
$P -c "SELECT '  api: '||(public.exos_refund_claim('$B','cs_race_sim','race-sim-api-key',NULL,NULL,true,'api')->>'amount_cents')" 2>&1 \
  | grep -o "api: [0-9]*\|nothing left to refund" | sed 's/^/  /' || true
wait
$P -c "SELECT '  -> requests: '||count(*)||', reserved: '||public.exos_refund_order_reserved('cs_race_sim') FROM exos_refund_requests WHERE session_id='cs_race_sim'"

echo "race 2: two owners demote each other at once"
( $P -c "BEGIN; SET LOCAL ROLE authenticated; SET LOCAL app.uid TO '$A';
         UPDATE exos_org_memberships SET role='manager' WHERE org_id='$O' AND user_id='$B'; SELECT '  A demoted B'; SELECT pg_sleep(2); COMMIT;" ) &
sleep 0.5
$P -c "BEGIN; SET LOCAL ROLE authenticated; SET LOCAL app.uid TO '$B';
       UPDATE exos_org_memberships SET role='manager' WHERE org_id='$O' AND user_id='$A'; SELECT '  B demoted A'; COMMIT;" 2>&1 \
  | grep -o "B demoted A\|last owner" | sed 's/^/  /' || true
wait
$P -c "SELECT '  -> active owners: '||count(*) FROM exos_org_memberships WHERE org_id='$O' AND role='owner' AND disabled IS NOT TRUE"
cleanup
