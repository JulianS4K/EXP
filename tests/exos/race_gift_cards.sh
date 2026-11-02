#!/usr/bin/env bash
# Concurrency checks for gift cards on reservations and the gift card import
# (mig 20261102110000): real sessions racing. Timing-based, so run by hand
# against a DB built by run_p0.sh (test_giving_writes.sql covers the same rules
# sequentially in CI):
#   bash tests/exos/race_gift_cards.sh exos_p0_test
# Expect: race 1 the two reservations together take exactly the card's 50.00
# (40.00 + 10.00), balance 0, never below; race 2 an apply racing the expiry
# sweep leaves the card whole (the hold is given back, or never taken); race 3
# two imports of the same file make one card.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=9c000000-0000-0000-0000-000000000001; A=9c000000-0000-0000-0000-0000000000a0
E=9c000000-0000-0000-0000-0000000000e1; T=9c000000-0000-0000-0000-0000000000d1; K=9c000000-0000-0000-0000-0000000000f1
LINES='[{"ticket_type_id":"'$T'","quantity":1}]'
cleanup() {
  $P -c "DELETE FROM exos_gift_card_redemptions WHERE org_id='$O';
         DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_partner_reservations WHERE org_id='$O';
         DELETE FROM exos_gift_card_imports WHERE org_id='$O';
         DELETE FROM exos_gift_cards WHERE org_id='$O';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_api_keys WHERE id='$K'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-gc.example',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race gift cards','race-gc','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,currency)
         VALUES ('$E','$O','Race','race-gc','published',now() + interval '10 days',0,0,'usd');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES ('$T','$E','GA',40,100,0,'public',1);
       INSERT INTO exos_api_keys(id,org_id,name,key_prefix,key_hash,scopes,created_by)
         VALUES ('$K','$O','Box','sk_live_9c9c9c9c',repeat('9c',32),ARRAY['tickets:write'],'$A');" >/dev/null
# A 50.00 imported card (code RACECARD01) and two 40.00 reservations.
CARD=$($P -c "SELECT (public._exos_gift_card_import('$O',NULL,'gift_up','[{\"code\":\"RACECARD01\",\"balance_cents\":5000}]',NULL)->'rows'->0->>'card_id')")
R1=$($P -c "SELECT public._exos_partner_reserve('$O','$E',NULL,'$K','$LINES','{}')->>'token'")
R2=$($P -c "SELECT public._exos_partner_reserve('$O','$E',NULL,'$K','$LINES','{}')->>'token'")

echo "race 1: one card, two reservations at once"
( $P -c "BEGIN; SELECT 'first took '||(public._exos_reservation_gift_card_apply('$O',NULL,'$R1','RACECARD01',NULL,'race-a')->>'amount_cents'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second took '||coalesce(x->>'amount_cents', x->>'error') FROM (SELECT public._exos_reservation_gift_card_apply('$O',NULL,'$R2','RACECARD01',NULL,'race-b') x) s" | sed 's/^/  /'
wait
BAL=$($P -c "SELECT balance_cents FROM exos_gift_cards WHERE id='$CARD'")
HELD=$($P -c "SELECT coalesce(sum(amount_cents),0) FROM exos_gift_card_redemptions WHERE card_id='$CARD' AND status='held'")
echo "  -> balance=$BAL held=$HELD (expect 0 and 5000)"
[ "$BAL" = "0" ] && [ "$HELD" = "5000" ]

echo "race 2: an apply racing the expiry sweep"
$P -c "SELECT public._exos_partner_reservation_cancel('$O',NULL,'$R1'); SELECT public._exos_partner_reservation_cancel('$O',NULL,'$R2');" >/dev/null
R3=$($P -c "SELECT public._exos_partner_reserve('$O','$E',NULL,'$K','$LINES','{}')->>'token'")
$P -c "UPDATE exos_partner_reservations SET expires_at = now() + interval '1 second' WHERE token='$R3'" >/dev/null
( $P -c "BEGIN; SELECT 'apply: '||coalesce((public._exos_reservation_gift_card_apply('$O',NULL,'$R3','RACECARD01',NULL,'race-c')->>'amount_cents'),'error'); SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -o "apply: [0-9a-z]*\|expired" | sed 's/^/  /' || true ) &
sleep 1.2
$P -c "SELECT '  sweep expired '||public.exos_partner_reservations_sweep(50)"
wait
$P -c "SELECT public.exos_partner_reservations_sweep(50)" >/dev/null
BAL=$($P -c "SELECT balance_cents FROM exos_gift_cards WHERE id='$CARD'")
echo "  -> balance=$BAL (expect 5000)"
[ "$BAL" = "5000" ]

echo "race 3: the same file imported twice at once"
FILE='[{"code":"RACEDUPE01","balance_cents":700}]'
( $P -c "BEGIN; SELECT 'first created '||(public._exos_gift_card_import('$O',NULL,'gift_up','$FILE','k1')->>'created'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second created '||(public._exos_gift_card_import('$O',NULL,'gift_up','$FILE','k2')->>'created')" | sed 's/^/  /'
wait
N=$($P -c "SELECT count(*) FROM exos_gift_cards WHERE org_id='$O' AND last4='PE01'")
echo "  -> cards=$N (expect 1)"
[ "$N" = "1" ]
LEDGER=$($P -c "SELECT count(*) FROM exos_gift_cards c WHERE org_id='$O' AND balance_cents <> (SELECT coalesce(sum(amount_cents),0) FROM exos_gift_card_ledger l WHERE l.card_id=c.id)")
echo "  ledger mismatches: $LEDGER (expect 0)"
[ "$LEDGER" = "0" ]
echo "OK race_gift_cards"
