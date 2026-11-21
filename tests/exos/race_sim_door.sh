#!/usr/bin/env bash
# Door races with real parallel sessions (tests/exos/sim_door.sql has the
# single-session scenarios). Not in CI (timing-based); run by hand against a
# DB built by run_p0.sh:
#   bash tests/exos/race_sim_door.sh exos_p0_test
# Expect:
#   race 1 two phones scan one ticket at once: one checked-in, one used
#   race 2 two offline phones upload one ticket at once: one checked-in, one used (conflict)
#   race 3 order check-out (#80) while the holder is scanned back in: both
#          land in order, the last direction is the one that committed last
#   race 4 two phones check in one guest-list guest at once: arrived 1
#   race 5 the box office double-taps a mint with one ref: one mint
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=d7e00000-0000-0000-0000-000000000001
OWN=d7e00000-0000-0000-0000-0000000000a1; MGR=d7e00000-0000-0000-0000-0000000000a2
SCAN=d7e00000-0000-0000-0000-0000000000a3; HOLD=d7e00000-0000-0000-0000-0000000000a5
E=d7e00000-0000-0000-0000-0000000000e1; TIER=d7e00000-0000-0000-0000-0000000000f1
LIST=d7e00000-0000-0000-0000-00000000aa03
T1=d7e00000-0000-0000-0000-0000000c0001; T2=d7e00000-0000-0000-0000-0000000c0002; T3=d7e00000-0000-0000-0000-0000000c0003
G1=d7e00000-0000-0000-0000-0000000000c1
AS="SET app.uid = '%s'; SET app.jwt = '{\"email\":\"door@x.com\"}';"
as() { printf "$AS" "$1"; }
# The holder's live T- code for a ticket (signed with the day key).
code() {
  $P -c "SELECT 'T-' || id || ':' || owner_id || ':' || b || ':' || public._exos_door_code_mac(id, owner_id, b, barcode_secret)
           FROM public.exos_tickets, (SELECT floor(extract(epoch FROM now()) * 1000 / 30000)::bigint AS b) x WHERE id = '$1'"
}
cleanup() {
  $P -c "DELETE FROM exos_scan_rejects WHERE event_id='$E'; DELETE FROM exos_checkin_client_refs WHERE event_id='$E';
         DELETE FROM exos_event_checkins WHERE event_id='$E'; DELETE FROM exos_guest_list_checkins WHERE event_id='$E';
         DELETE FROM exos_guest_list_entries WHERE event_id='$E'; DELETE FROM exos_guest_lists WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E'; DELETE FROM exos_checkout_sessions WHERE event_id='$E';
         DELETE FROM exos_checkin_lists WHERE event_id='$E'; DELETE FROM exos_ticket_tiers WHERE event_id='$E';
         DELETE FROM exos_events WHERE id='$E'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$OWN','$MGR','$SCAN','$HOLD');" >/dev/null
}
cleanup
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
         ('$OWN','own@race-door.example',now()), ('$MGR','mgr@race-door.example',now()),
         ('$SCAN','scan@race-door.example',now()), ('$HOLD','hold@race-door.example',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race door','race-door','$OWN');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES
         ('$O','$OWN','owner'), ('$O','$MGR','manager'), ('$O','$SCAN','scanner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
         ('$E','$O','Race door','race-door-e1','published',now() + interval '1 hour', now() - interval '1 hour', 0, '$OWN');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity) VALUES ('$TIER','$E','GA',50,100);
       INSERT INTO exos_checkin_lists(id,event_id,name,allow_reentry) VALUES ('$LIST','$E','Pass-out',true);
       INSERT INTO exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,quantity,amount_cents,status)
         VALUES ('cs_race_door','$E','$O','$HOLD',1,5000,'fulfilled');
       INSERT INTO exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
       VALUES ('$T1','$E','$O','$TIER','GA','$HOLD','$HOLD','active','rd-1',50,'web-rd-1'),
              ('$T2','$E','$O','$TIER','GA','$HOLD','$HOLD','active','rd-2',50,'web-rd-2'),
              ('$T3','$E','$O','$TIER','GA','$HOLD','$HOLD','active','rd-3',50,'cs_race_door');
       INSERT INTO exos_guest_lists(id,event_id,org_id,name) VALUES ('d7e00000-0000-0000-0000-0000000000b1','$E','$O','Friends');
       INSERT INTO exos_guest_list_entries(id,list_id,event_id,org_id,guest_name)
         VALUES ('$G1','d7e00000-0000-0000-0000-0000000000b1','$E','$O','Solo');" >/dev/null

echo "race 1: two phones scan one ticket at the same moment"
C1=$(code "$T1")
SCAN_SQL="SELECT public.exos_check_in_ticket('$T1','camera','verified','$C1','$E',NULL,NULL,'%s',NULL,'entry')->>'reason'"
( $P -c "$(as $SCAN) BEGIN; $(printf "$SCAN_SQL" 'Door A'); SELECT pg_sleep(2); COMMIT;" | grep -v '^$' | sed 's/^/  Door A: /' ) &
sleep 0.5
$P -c "$(as $SCAN) $(printf "$SCAN_SQL" 'Door B')" | grep -v '^$' | sed 's/^/  Door B: /'
wait
$P -c "SELECT '  -> entries: ' || count(*) FROM exos_event_checkins WHERE ticket_id='$T1'"

echo "race 2: two offline phones upload the same ticket at once"
AT=$($P -c "SELECT now() - interval '10 minutes'")
C2=$($P -c "SELECT 'T-' || id || ':' || owner_id || ':' || b || ':' || public._exos_door_code_mac(id, owner_id, b, barcode_secret)
              FROM exos_tickets, (SELECT floor(extract(epoch FROM '$AT'::timestamptz) * 1000 / 30000)::bigint AS b) x WHERE id='$T2'")
UP_SQL="SELECT (r->>'reason') || coalesce(' conflict=' || (r->>'conflict'), '') FROM (SELECT public.exos_check_in_offline('%s','$T2','$E','$AT','$C2','camera',NULL,'%s',NULL,'entry') r) x"
( $P -c "$(as $SCAN) BEGIN; $(printf "$UP_SQL" d7e00000-0000-0000-0000-00000000f001 'Door A'); SELECT pg_sleep(2); COMMIT;" | grep -v '^$' | sed 's/^/  Door A: /' ) &
sleep 0.5
$P -c "$(as $SCAN) $(printf "$UP_SQL" d7e00000-0000-0000-0000-00000000f002 'Door B')" | grep -v '^$' | sed 's/^/  Door B: /'
wait
$P -c "SELECT '  -> entries: ' || (SELECT count(*) FROM exos_event_checkins WHERE ticket_id='$T2')
          || ', rejects: ' || (SELECT count(*) FROM exos_scan_rejects WHERE ticket_id_attempted='$T2')"

echo "race 3: order check-out while the holder is scanned back in"
C3=$(code "$T3")
$P -c "$(as $SCAN) SELECT public.exos_check_in_ticket('$T3','camera','verified','$C3','$E',NULL,NULL,'Door A','$LIST','entry')" >/dev/null
$P -c "$(as $SCAN) SELECT public.exos_check_in_ticket('$T3','camera','verified','$C3','$E',NULL,NULL,'Door A','$LIST','exit')" >/dev/null
$P -c "$(as $SCAN) SELECT public.exos_check_in_ticket('$T3','camera','verified','$C3','$E',NULL,NULL,'Door A','$LIST','entry')" >/dev/null
# Inside now. The manager checks the order out (holding the lock) while the
# door scans the same ticket in again.
( $P -c "$(as $MGR) BEGIN; SELECT 'checked out: ' || (public.exos_order_check_out('cs_race_door')->>'checked_out'); SELECT pg_sleep(2); COMMIT;" | grep -v '^$' | sed 's/^/  manager: /' ) &
sleep 0.5
$P -c "$(as $SCAN) SELECT public.exos_check_in_ticket('$T3','camera','verified','$C3','$E',NULL,NULL,'Door B','$LIST','entry')->>'reason'" | grep -v '^$' | sed 's/^/  Door B: /'
wait
$P -c "SELECT '  -> last on the list: ' || direction || ' (' || device || ')' FROM exos_event_checkins
        WHERE ticket_id='$T3' ORDER BY scanned_at DESC LIMIT 1"

echo "race 4: two phones check in one guest at once"
G_SQL="SELECT public.exos_guest_check_in('$G1',1,'$E','%s')->>'reason'"
( $P -c "$(as $SCAN) BEGIN; $(printf "$G_SQL" d7e00000-0000-0000-0000-00000000f011); SELECT pg_sleep(2); COMMIT;" | grep -v '^$' | sed 's/^/  phone A: /' ) &
sleep 0.5
$P -c "$(as $SCAN) $(printf "$G_SQL" d7e00000-0000-0000-0000-00000000f012)" | grep -v '^$' | sed 's/^/  phone B: /'
wait
$P -c "SELECT '  -> arrived: ' || arrived FROM exos_guest_list_entries WHERE id='$G1'"

echo "race 5: the box office double-taps a mint with one ref"
M_SQL="SELECT array_length(public.exos_mint_tickets('$E','$TIER',1,'race-door-mint',0),1)"
( $P -c "$(as $MGR) BEGIN; $M_SQL; SELECT pg_sleep(2); COMMIT;" | grep -v '^$' | sed 's/^/  tap 1 minted: /' ) &
sleep 0.5
$P -c "$(as $MGR) $M_SQL" | grep -v '^$' | sed 's/^/  tap 2 returned: /'
wait
$P -c "SELECT '  -> tickets with the ref: ' || count(*) FROM exos_tickets WHERE order_ref='race-door-mint'"
cleanup
