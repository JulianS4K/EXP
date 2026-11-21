#!/usr/bin/env bash
# Own-account marketplace allocations (mig 20261121214500) racing sales, in
# real parallel sessions. Run against a DB built by run_p0.sh (CI runs it):
#   bash tests/exos/race_byo_allocations.sh exos_p0_test
# Expect:
#   race 1 a StubHub sale of 2 is being fulfilled (its transaction holds the
#          allocation row) while the organizer shrinks StubHub to 0.5% (1 of
#          200): the shrink waits for the sale, then sees 2 sold and is
#          refused (never an allocation below what sold); the cap stays 20
#   race 2 two shrinks / grows of the same marketplace at once: they run one
#          after the other (the route lock), the cap ends at the one that
#          committed last, and both are audited
#   race 3 the organizer grows StubHub while an Exos checkout takes the free
#          seats: never more allocated + sold than the ticket type holds
#   race 4 SeatGeek ticked under Distribution at the same moment the organizer
#          sets an own SeatGeek share, both orders (review of #143, R1 race):
#          the second waits on the event row and is refused, never ticked
#          and own at once
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
# Fresh ids each run: the org audit log is append-only, so its rows stay.
R=$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')
O=$R-b4ac-0000-0000-000000000001; A=$R-b4ac-0000-0000-0000000000a0
E=$R-b4ac-0000-0000-0000000000e1; T=$R-b4ac-0000-0000-0000000000d1
E4=$R-b4ac-0000-0000-0000000000e4; T4=$R-b4ac-0000-0000-0000000000d4
AS_OWNER="SELECT set_config('app.uid','$A',false), set_config('request.jwt.claims','{\"role\":\"authenticated\"}',false);"
fail=0
check() { if [ "$1" = "$2" ]; then echo "  ok: $3"; else echo "  FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }
cleanup() {
  $P -c "DELETE FROM exos_mail WHERE to_email LIKE 'b4race%';
         DELETE FROM exos_transfers WHERE org_id='$O'; DELETE FROM exos_tickets WHERE org_id='$O';
         DELETE FROM exos_journal_lines WHERE entry_id IN (SELECT id FROM exos_journal_entries WHERE org_id='$O');
         DELETE FROM exos_journal_entries WHERE org_id='$O';
         DELETE FROM exos_marketplace_orders WHERE org_id='$O' OR external_order_id LIKE 'b4race-%';
         DELETE FROM exos_distribution_listings WHERE org_id='$O'; DELETE FROM exos_byo_allocations WHERE org_id='$O';
         DELETE FROM exos_ticket_tiers WHERE event_id IN ('$E','$E4'); DELETE FROM exos_events WHERE id IN ('$E','$E4');
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id='$A';" >/dev/null 2>&1 || true
}
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','b4race-owner-$R@x.com',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','B4 Race','b4-race-$R','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner') ON CONFLICT DO NOTHING;
       INSERT INTO exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks)
         VALUES ('$E','$O','B4 Race','published',now() + interval '60 days','Hall',200,0,'{}');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$T','$E','GA',40,200,0);" >/dev/null
$P -c "$AS_OWNER SELECT exos_byo_set_allocation('$E','stubhub',10);" >/dev/null
LST=$($P -c "SELECT id FROM exos_distribution_listings WHERE event_id='$E' AND channel='stubhub' AND tier_id='$T'")
$P -c "SELECT exos_record_marketplace_order(jsonb_build_object('channel','stubhub','external_order_id','b4race-$R',
         'external_listing_id','$LST','quantity',2,'sale_status','confirmed','proceeds','80.00','currency','USD',
         'buyer_email','b4race-buyer@x.com'));" >/dev/null
ORD=$($P -c "SELECT id FROM exos_marketplace_orders WHERE external_order_id='b4race-$R'")

echo "race 1: a StubHub sale is fulfilled while the organizer shrinks StubHub below it"
( $P -c "BEGIN; SELECT status FROM exos_fulfil_marketplace_order('$ORD'); SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
out=$($P -c "$AS_OWNER SELECT exos_byo_set_allocation('$E','stubhub',0.5);" 2>&1 || true)
wait
case "$out" in *"sold 2 of GA already"*) r1=refused ;; *) r1="$out" ;; esac
check "$r1" "refused" "the shrink waited for the sale and was refused below 2 sold"
check "$($P -c "SELECT sell_cap||'/'||sold_qty FROM exos_distribution_listings WHERE id='$LST'")" "20/2" "cap 20, 2 sold"
check "$($P -c "SELECT count(*) FROM exos_tickets WHERE order_ref='stubhub:b4race-$R' AND code_mode='static'")" "2" "the sale's 2 tickets are static"

echo "race 2: two changes to StubHub at once"
( $P -c "BEGIN; $AS_OWNER SELECT exos_byo_set_allocation('$E','stubhub',5); SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
$P -c "$AS_OWNER SELECT exos_byo_set_allocation('$E','stubhub',3);" >/dev/null
wait
check "$($P -c "SELECT sell_cap FROM exos_distribution_listings WHERE id='$LST'")" "6" "the later change (3% of 200) wins"
check "$($P -c "SELECT pct FROM exos_byo_allocations WHERE event_id='$E' AND channel='stubhub'")" "3.00" "the % matches"
check "$($P -c "SELECT count(*) FROM exos_org_audit WHERE org_id='$O' AND action='event.byo_allocation'")" "3" "every change audited (10, 5, 3)"

echo "race 3: the organizer grows StubHub while an Exos checkout takes the free seats"
MINT="UPDATE exos_ticket_tiers SET sold = sold + 190 WHERE id='$T' AND sold + 190 <= capacity AND exos_seats_available('$T',190) RETURNING 'exos sold 190'"
( $P -c "BEGIN; UPDATE exos_events SET tickets_sold = tickets_sold + 190 WHERE id='$E'; $MINT; SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 || true ) &
sleep 0.5
$P -c "$AS_OWNER SELECT exos_byo_set_allocation('$E','stubhub',50);" >/dev/null 2>&1 || true
wait
over=$($P -c "SELECT (SELECT sold FROM exos_ticket_tiers WHERE id='$T') + (SELECT greatest(coalesce(requested_qty,0),0) FROM exos_distribution_listings WHERE id='$LST') > 200")
check "$over" "f" "never more sold + held than 200"

echo "race 4: a Distribution tick and an own share of the same marketplace at once"
# Its own event: race 3 sold most of the first one.
$P -c "INSERT INTO exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks)
         VALUES ('$E4','$O','B4 Race 4','published',now() + interval '60 days','Hall',200,0,'{}');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$T4','$E4','GA',40,200,0);" >/dev/null
bad() { echo "SELECT ('$1' = ANY (distribution_networks)) AND EXISTS (SELECT 1 FROM exos_byo_allocations WHERE event_id='$E4' AND channel='$1' AND pct > 0) FROM exos_events WHERE id='$E4'"; }
# (a) the tick first, held open; the own share waits for it, then sees it.
( $P -c "BEGIN; UPDATE exos_events SET distribution_networks = array_append(distribution_networks, 'seatgeek') WHERE id='$E4'; SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
out=$($P -c "$AS_OWNER SELECT exos_byo_set_allocation('$E4','seatgeek',10);" 2>&1 || true)
wait
case "$out" in *"ticked under Distribution"*) r4a=refused ;; *) r4a="$out" ;; esac
check "$r4a" "refused" "tick first: the own share waited and was refused"
check "$($P -c "$(bad seatgeek)")" "f" "tick first: never ticked and own at once"
# (b) the own share first, held open; the tick waits for it, then sees it.
# Vivid: (a) left SeatGeek network rows, and an own switch is refused while
# network rows exist (R4), so a fresh marketplace keeps (b) a pure race.
( $P -c "BEGIN; $AS_OWNER SELECT exos_byo_set_allocation('$E4','vivid',10); SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
out=$($P -c "UPDATE exos_events SET distribution_networks = array_append(distribution_networks, 'vivid') WHERE id='$E4';" 2>&1 || true)
wait
case "$out" in *"sold with your own seller account"*) r4b=refused ;; *) r4b="$out" ;; esac
check "$r4b" "refused" "own share first: the tick waited and was refused"
check "$($P -c "SELECT count(*) FROM exos_byo_allocations WHERE event_id='$E4' AND channel='vivid' AND pct > 0")" "1" "own share first: the own share stands"
check "$($P -c "$(bad vivid)")" "f" "own share first: never ticked and own at once"

[ "$fail" -eq 0 ] && echo "race_byo_allocations: all passed"
exit $fail
