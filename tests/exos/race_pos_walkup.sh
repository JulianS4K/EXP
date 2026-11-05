#!/usr/bin/env bash
# Walk-up sale races (mig 20261107100000): real parallel sessions. Timing-based,
# so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_pos_walkup.sh exos_p0_test
# Expect:
#   race 1 two door devices sell the last ticket at once: one sale, one
#          "sold out"; the type never goes over capacity
#   race 2 a walk-up and an online checkout race for the last place of a
#          shared limit (two ticket types, one pool): exactly one gets it,
#          whichever side locks the pool first (the same lock order: pools
#          by quota_id, then the type)
#   race 3 the same, the other way round (the walk-up locks first)
#   race 4 a double tap from two sessions with the same order key: one sale
#   race 5 a void and a paid-out race on the same drawer: both land, the
#          drawer's cash never goes below zero
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=b0c7ace0-0000-0000-0000-000000000001; A=b0c7ace0-0000-0000-0000-0000000000a1; S=b0c7ace0-0000-0000-0000-0000000000a3
B=b0c7ace0-0000-0000-0000-0000000000b1
E=b0c7ace0-0000-0000-0000-0000000000e1; T1=b0c7ace0-0000-0000-0000-0000000000d1
TA=b0c7ace0-0000-0000-0000-0000000000d2; TB=b0c7ace0-0000-0000-0000-0000000000d3
Q=b0c7ace0-0000-0000-0000-0000000000f1; DR=b0c7ace0-0000-0000-0000-0000000000c1
as() { echo "SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false);"; }
cleanup() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_pos_paid_outs WHERE event_id='$E'; DELETE FROM exos_pos_reversals WHERE event_id='$E';
         DELETE FROM exos_question_answer_cursors WHERE event_id='$E';
         DELETE FROM exos_pos_orders WHERE event_id='$E'; DELETE FROM exos_pos_items WHERE event_id='$E';
         DELETE FROM exos_pos_drawer_sessions WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_quota_tiers WHERE quota_id='$Q'; DELETE FROM exos_quotas WHERE id='$Q';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM exos_rate_windows WHERE bucket LIKE 'pos:%$S%' OR bucket LIKE 'pos:%$A%';
         DELETE FROM auth.users WHERE id IN ('$A','$S','$B');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-pw.test',now()),
         ('$S','scanner@race-pw.test',now()),('$B','buyer@race-pw.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race walkup','race-pw','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner'),('$O','$S','scanner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-pw','published',now() + interval '1 hour',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
         ('$T1','$E','Last one',20,1,0,'public'),('$TA','$E','Pool A',20,10,0,'public'),('$TB','$E','Pool B',20,10,0,'public');
       INSERT INTO exos_quotas(id,event_id,org_id,name,size) VALUES ('$Q','$E','$O','Room',1);
       INSERT INTO exos_quota_tiers(quota_id,tier_id) VALUES ('$Q','$TA'),('$Q','$TB');
       $(as $S scanner@race-pw.test)
       INSERT INTO exos_pos_drawer_sessions(id,event_id,open_float_cents) VALUES ('$DR','$E',1000);" >/dev/null
# One walk-up sale as the scanner (cash into the drawer), then hold the
# transaction open for $3 seconds so the other side has to wait or lose.
sell() {
  echo "$(as $S scanner@race-pw.test)
        SELECT public.exos_pos_walkup_sell('$E','$1',1,'$2'::uuid,0,'cash',NULL,'$DR') ->> 'id';
        SELECT pg_sleep($3);"
}
online() {
  echo "$(as $B buyer@race-pw.test)
        SELECT public.exos_create_hold('$E','$1',1);
        SELECT pg_sleep($2);"
}
ok_or_no() { if "$@" >/dev/null 2>&1; then echo ok; else echo refused; fi; }

echo "race 1: two devices sell the last ticket"
( R=$(ok_or_no $P -c "BEGIN; $(sell $T1 b0c7ace0-0000-0000-0000-00000000aa01 2) COMMIT;"); echo "  device 1: $R" ) &
sleep 0.5
R=$(ok_or_no $P -c "BEGIN; $(sell $T1 b0c7ace0-0000-0000-0000-00000000aa02 0) COMMIT;"); echo "  device 2: $R"
wait
N=$($P -c "SELECT sold FROM exos_ticket_tiers WHERE id='$T1'")
M=$($P -c "SELECT count(*) FROM exos_tickets WHERE tier_id='$T1' AND status='active'")
echo "  -> sold=$N tickets=$M (expect 1 and 1)"
[ "$N" = "1" ] && [ "$M" = "1" ] || { echo "FAIL"; exit 1; }

echo "race 2: an online checkout holds the pool's last place while the door sells"
( R=$(ok_or_no $P -c "BEGIN; $(online $TA 2) COMMIT;"); echo "  online: $R" ) &
sleep 0.5
R=$(ok_or_no $P -c "BEGIN; $(sell $TB b0c7ace0-0000-0000-0000-00000000aa03 0) COMMIT;"); echo "  door:   $R"
wait
H2=$($P -c "SELECT count(*) FROM exos_cart_holds WHERE event_id='$E' AND status='active' AND pos_order_id IS NULL")
W2=$($P -c "SELECT count(*) FROM exos_tickets WHERE tier_id IN ('$TA','$TB') AND status='active'")
echo "  -> online holds=$H2 door tickets=$W2 (expect 1 and 0)"
[ "$H2" = "1" ] && [ "$W2" = "0" ] || { echo "FAIL"; exit 1; }
$P -c "UPDATE exos_cart_holds SET status='released', released_at=now() WHERE event_id='$E' AND status='active';" >/dev/null

echo "race 3: the door sells the pool's last place while an online checkout tries"
( R=$(ok_or_no $P -c "BEGIN; $(sell $TB b0c7ace0-0000-0000-0000-00000000aa04 2) COMMIT;"); echo "  door:   $R" ) &
sleep 0.5
R=$(ok_or_no $P -c "BEGIN; $(online $TA 0) COMMIT;"); echo "  online: $R"
wait
H3=$($P -c "SELECT count(*) FROM exos_cart_holds WHERE event_id='$E' AND status='active'")
W3=$($P -c "SELECT count(*) FROM exos_tickets WHERE tier_id IN ('$TA','$TB') AND status='active'")
echo "  -> holds=$H3 door tickets=$W3 (expect 0 and 1)"
[ "$H3" = "0" ] && [ "$W3" = "1" ] || { echo "FAIL"; exit 1; }

echo "race 4: a double tap from two sessions (same order key)"
$P -c "UPDATE exos_ticket_tiers SET capacity = 10 WHERE id='$T1';" >/dev/null
K=b0c7ace0-0000-0000-0000-00000000aa05
( $P -c "BEGIN; $(sell $T1 $K 2) COMMIT;" >/dev/null 2>&1; echo "  tap 1 done" ) &
sleep 0.5
$P -c "BEGIN; $(sell $T1 $K 0) COMMIT;" >/dev/null 2>&1; echo "  tap 2 done"
wait
N4=$($P -c "SELECT count(*) FROM exos_pos_orders WHERE client_ref='$K'")
T4=$($P -c "SELECT count(*) FROM exos_tickets t JOIN exos_pos_orders o ON t.order_ref = 'pos:' || o.id WHERE o.client_ref='$K'")
echo "  -> orders=$N4 tickets=$T4 (expect 1 and 1)"
[ "$N4" = "1" ] && [ "$T4" = "1" ] || { echo "FAIL"; exit 1; }

echo "race 5: a void and a paid-out on the same drawer at once"
OID=$($P -c "SELECT id FROM exos_pos_orders WHERE client_ref='$K'")
CASH=$($P -c "SELECT public._exos_pos_drawer_cash('$DR')")
# Pay out everything but the voided sale's cash, while the void returns that cash.
PO=$((CASH - 2000))
( $P -c "BEGIN; $(as $S scanner@race-pw.test) SELECT public.exos_pos_void_order('$OID','race void'); SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1; echo "  void done" ) &
sleep 0.5
R=$(ok_or_no $P -c "BEGIN; $(as $S scanner@race-pw.test) SELECT public.exos_pos_paid_out('$DR', $PO, 'race paid-out'); COMMIT;"); echo "  paid-out: $R"
wait
LEFT=$($P -c "SELECT public._exos_pos_drawer_cash('$DR')")
V=$($P -c "SELECT status FROM exos_pos_orders WHERE id='$OID'")
echo "  -> order=$V drawer cash=$LEFT (expect void and >= 0)"
[ "$V" = "void" ] && [ "$LEFT" -ge 0 ] || { echo "FAIL"; exit 1; }
echo "all races OK"
