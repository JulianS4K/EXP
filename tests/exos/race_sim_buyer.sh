#!/usr/bin/env bash
# Buyer mistake races (claude/exos-sim-buyer): real parallel sessions doing
# what tests/exos/sim_buyer.sql does one step at a time. Timing-based, so run
# by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_sim_buyer.sh exos_p0_test
# Expect:
#   race 1 two buyers hold the last ticket at once: exactly one hold
#   race 2 the Stripe webhook twice at once: one set of tickets, sold 1
#   race 3 the same claim link on two devices at once: one claim wins, the
#          other is told "transfer is completed" (before mig 20261104100000
#          both were told they had it)
#   race 4 the sender cancels while the recipient claims: one of them wins and
#          the transfer row agrees with the ticket (before: "cancelled" row,
#          ticket moved anyway)
#   race 5 a refund lands while the recipient claims: the ticket stays voided
#          (before: the claim put it back to active)
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=be100000-0000-0000-0000-000000000001; A=be100000-0000-0000-0000-0000000000a0
B1=be100000-0000-0000-0000-0000000000b1; B2=be100000-0000-0000-0000-0000000000b2; B3=be100000-0000-0000-0000-0000000000b3
E=be100000-0000-0000-0000-0000000000e1; T=be100000-0000-0000-0000-0000000000d1; T2=be100000-0000-0000-0000-0000000000d2
as() { echo "SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false);"; }
cleanup() {
  $P -c "DELETE FROM exos_mail WHERE to_email LIKE '%@race-simb.test';
         DELETE FROM exos_order_payments WHERE session_id LIKE 'cs_rsb_%';
         UPDATE exos_tickets SET pending_transfer_id = NULL WHERE event_id='$E';
         DELETE FROM exos_transfers WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_checkout_sessions WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$B1','$B2','$B3');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
         ('$A','owner@race-simb.test',now()),('$B1','b1@race-simb.test',now()),
         ('$B2','b2@race-simb.test',now()),('$B3','b3@race-simb.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race buyer','race-simb','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-simb','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
         ('$T','$E','Last',20,1,0,'public'),('$T2','$E','GA',20,100,0,'public');" >/dev/null

echo "race 1: two buyers, the last ticket, at once"
( $P -c "$(as $B1 b1@race-simb.test) BEGIN; SELECT 'b1 hold '||public.exos_create_hold('$E','$T',1); SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -o "b1 hold [0-9a-f-]*\|not enough tickets available" | sed 's/^/  /' || true ) &
sleep 0.5
( $P -c "$(as $B2 b2@race-simb.test) SELECT 'b2 hold '||public.exos_create_hold('$E','$T',1);" 2>&1 | grep -o "b2 hold [0-9a-f-]*\|not enough tickets available" | sed 's/^/  /' || true )
wait
N=$($P -c "SELECT count(*) FROM exos_cart_holds WHERE tier_id='$T' AND status='active'")
echo "  -> active holds=$N (expect 1)"
[ "$N" = "1" ] || { echo "FAIL"; exit 1; }

echo "race 2: the same webhook twice, at once"
HOLD=$($P -c "SELECT id FROM exos_cart_holds WHERE tier_id='$T' AND status='active'")
BUYER=$($P -c "SELECT buyer_uid FROM exos_cart_holds WHERE id='$HOLD'")
$P -c "INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status)
         VALUES ('cs_rsb_2','$E','$T','$O','$BUYER','x@race-simb.test',1,2000,'usd','pending');
       UPDATE exos_cart_holds SET checkout_session_id='cs_rsb_2' WHERE id='$HOLD';" >/dev/null
( $P -c "BEGIN; SELECT 'first '||cardinality(public.exos_fulfill_checkout('cs_rsb_2')); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second '||cardinality(public.exos_fulfill_checkout('cs_rsb_2'))" | sed 's/^/  /'
wait
N=$($P -c "SELECT count(*) FROM exos_tickets WHERE order_ref='cs_rsb_2'")
S=$($P -c "SELECT sold FROM exos_ticket_tiers WHERE id='$T'")
echo "  -> tickets=$N sold=$S (expect 1 1)"
[ "$N" = "1" ] && [ "$S" = "1" ] || { echo "FAIL"; exit 1; }

# Three GA tickets for b1, each sent to b2.
TK=()
for i in 1 2 3; do
  TK+=("$($P -c "INSERT INTO exos_tickets(event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
                 VALUES ('$E','$O','$T2','GA','$B1','$B1','b1@race-simb.test','active',gen_random_uuid()::text,20,'cs_rsb_t$i','stripe') RETURNING id")")
  $P -c "INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,ticket_ids)
           VALUES ('cs_rsb_t$i','$E','$T2','$O','$B1','b1@race-simb.test',1,2000,'usd','fulfilled',ARRAY['${TK[$((i-1))]}']::uuid[])" >/dev/null
done
TR=()
for i in 0 1 2; do
  TR+=("$($P -c "$(as $B1 b1@race-simb.test) SELECT public.exos_create_transfer('${TK[$i]}','b2@race-simb.test')" | tail -1)")
done
KEY1=$($P -c "SELECT claim_key FROM exos_transfers WHERE id='${TR[0]}'")

echo "race 3: one claim link, two devices, at once"
( $P -c "$(as $B2 b2@race-simb.test) BEGIN; SELECT 'b2 claimed '||public.exos_claim_transfer('${TR[0]}','$KEY1'); SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -o "b2 claimed [0-9a-f-]*\|transfer is [a-z]*" | sed 's/^/  /' || true ) &
sleep 0.5
OUT3=$($P -c "$(as $B3 b3@race-simb.test) SELECT 'b3 claimed '||public.exos_claim_transfer('${TR[0]}','$KEY1');" 2>&1 | grep -o "b3 claimed [0-9a-f-]*\|transfer is [a-z]*" || true)
echo "  $OUT3"
wait
OWN=$($P -c "SELECT owner_id FROM exos_tickets WHERE id='${TK[0]}'")
echo "  -> owner=$OWN second device: '$OUT3' (expect b2 owns it; b3 told 'transfer is completed')"
[ "$OWN" = "$B2" ] && [ "$OUT3" = "transfer is completed" ] || { echo "FAIL"; exit 1; }

echo "race 4: the sender cancels while the recipient claims"
( $P -c "$(as $B2 b2@race-simb.test) BEGIN; SELECT 'b2 claimed '||public.exos_claim_transfer('${TR[1]}'); SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -o "b2 claimed [0-9a-f-]*\|transfer is [a-z]*" | sed 's/^/  /' || true ) &
sleep 0.5
OUT4=$($P -c "$(as $B1 b1@race-simb.test) SELECT public.exos_cancel_transfer('${TR[1]}'); SELECT 'cancelled';" 2>&1 | grep -o "^cancelled$\|transfer is [a-z]*" || true)
echo "  b1 cancel: $OUT4"
wait
ST=$($P -c "SELECT status FROM exos_transfers WHERE id='${TR[1]}'")
OWN=$($P -c "SELECT owner_id FROM exos_tickets WHERE id='${TK[1]}'")
echo "  -> transfer=$ST owner=$OWN (expect completed, b2, and the cancel told 'transfer is completed')"
[ "$ST" = "completed" ] && [ "$OWN" = "$B2" ] && [ "$OUT4" = "transfer is completed" ] || { echo "FAIL"; exit 1; }

echo "race 5: a refund lands while the recipient claims"
( $P -c "BEGIN; SELECT 'refund voided '||public.exos_refund_checkout('cs_rsb_t3','race refund'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
OUT5=$($P -c "$(as $B2 b2@race-simb.test) SELECT 'b2 claimed '||public.exos_claim_transfer('${TR[2]}');" 2>&1 | grep -o "b2 claimed [0-9a-f-]*\|ticket was refunded\|transfer is [a-z]*" || true)
echo "  $OUT5"
wait
ST=$($P -c "SELECT status FROM exos_tickets WHERE id='${TK[2]}'")
echo "  -> ticket=$ST (expect voided; the claim told 'ticket was refunded')"
[ "$ST" = "voided" ] && [ "$OUT5" = "ticket was refunded" ] || { echo "FAIL"; exit 1; }
echo "OK race_sim_buyer"
