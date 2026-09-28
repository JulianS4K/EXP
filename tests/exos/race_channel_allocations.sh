#!/usr/bin/env bash
# Concurrency check for channel seat allocations (mig 20260926193000): two
# real sessions race for the last seat. Not in CI (timing-based); run by hand
# against a DB built by run_p0.sh:   bash tests/exos/race_channel_allocations.sh exos_p0_test
# Expect: never more sold than capacity. Since scarcity mode (mig
# 20260928040000) a pool never takes Exos's last order's worth, so on these
# 1- and 2-seat tiers the allocation holds nothing: race 1 -> Exos gets the
# seat; race 2 -> Exos keeps it, allocation refused; race 3 -> Exos and the
# StubHub sale both sell from free seats, 2/2 sold.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
E=77000000-0000-0000-0000-0000000000e1; T=77000000-0000-0000-0000-0000000000d1
O=77000000-0000-0000-0000-000000000001; A=77000000-0000-0000-0000-0000000000a0
MINT="UPDATE exos_ticket_tiers SET sold = sold + 1 WHERE id='$T' AND sold + 1 <= capacity AND exos_seats_available('$T',1) RETURNING 'exos got a seat'"
cleanup() {
  $P -c "DELETE FROM exos_mail WHERE to_email='race@x.com'; DELETE FROM exos_transfers WHERE org_id='$O';
         DELETE FROM exos_tickets WHERE org_id='$O'; DELETE FROM exos_marketplace_orders WHERE org_id='$O';
         DELETE FROM exos_distribution_listings WHERE org_id='$O'; DELETE FROM exos_ticket_tiers WHERE id='$T';
         DELETE FROM exos_events WHERE id='$E'; DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';"
}
result() { $P -c "SELECT '  -> sold='||sold||'/'||capacity||' allocated='||exos_channel_allocated(id) FROM exos_ticket_tiers WHERE id='$T'"; }
cleanup
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','race-owner@x.com',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race','race-org','$A');
       INSERT INTO exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES ('$E','$O','Race','published','2027-01-01T00:00:00Z','Hall',1,0,ARRAY['stubhub']);
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$T','$E','GA',10,1,0);"

echo "race 1: StubHub allocation holds the last seat while an Exos mint tries it"
( $P -c "BEGIN; SELECT exos_set_channel_allocation('$E','stubhub','$T',1); SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5; $P -c "BEGIN; $MINT; COMMIT;" | sed 's/^/  /'; wait; result

echo "race 2: Exos mint holds the last seat while a StubHub allocation tries it"
$P -c "UPDATE exos_distribution_listings SET requested_qty=0 WHERE event_id='$E'; UPDATE exos_ticket_tiers SET sold=0 WHERE id='$T';"
( $P -c "BEGIN; $MINT; SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5; $P -c "SELECT exos_set_channel_allocation('$E','stubhub','$T',1);" 2>&1 | grep -o 'only [0-9]* more seat(s) free' | sed 's/^/  allocation refused: /' || true
wait; result

echo "race 3: an Exos checkout (1 free seat) and a StubHub sale (1 allocated seat) at once"
$P -c "UPDATE exos_ticket_tiers SET capacity=2, sold=0 WHERE id='$T'; UPDATE exos_events SET total_tickets=2, tickets_sold=0 WHERE id='$E';" >/dev/null
$P -c "SELECT exos_set_channel_allocation('$E','stubhub','$T',1);
       UPDATE exos_distribution_listings SET status='listed', external_listing_id='SH-RACE' WHERE event_id='$E' AND tier_id IS NOT NULL;
       SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"RACE-3\",\"external_listing_id\":\"SH-RACE\",\"quantity\":1,\"sale_status\":\"confirmed\",\"buyer_email\":\"race@x.com\"}');" >/dev/null
( $P -c "BEGIN; UPDATE exos_events SET tickets_sold = tickets_sold + 1 WHERE id='$E' AND tickets_sold + 1 <= total_tickets; $MINT; SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT '  stubhub sale: '||status FROM exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='RACE-3'))"
wait; result
cleanup
