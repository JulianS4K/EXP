#!/usr/bin/env bash
# Print-code and box-office races (claude/exos-na-build, mig 20261105120000):
# real parallel sessions. Timing-based, so run by hand against a DB built by
# run_p0.sh:
#   bash tests/exos/race_print_codes.sh exos_p0_test
# Expect:
#   race 1 the same paper at two doors at once: one checked-in, the other
#          print-code-used (or used): one admission
#   race 2 the same paper at two re-entry lists at once (the ticket flip alone
#          would let both in): one checked-in, the other print-code-used
#   race 3 a reprint while the old paper is being scanned: the scan wins and
#          the reprint is refused (used), or the reprint wins and the scan is
#          refused; never both
#   race 4 a membership with one place left, two reservations at once: one
#          reserved, the other sold out
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=bf500000-0000-0000-0000-000000000001; A=bf500000-0000-0000-0000-0000000000a0; HOLDER=bf500000-0000-0000-0000-0000000000c1
E=bf500000-0000-0000-0000-0000000000e1; T=bf500000-0000-0000-0000-0000000000d1
L1=bf500000-0000-0000-0000-00000000aa01; L2=bf500000-0000-0000-0000-00000000aa02
M=bf500000-0000-0000-0000-00000000b0a1
tk() { echo "bf500000-0000-0000-0000-0000000c00$1"; }
cleanup() {
  $P -c "DELETE FROM exos_membership_reservations WHERE org_id='$O'; DELETE FROM exos_membership_products WHERE org_id='$O';
         DELETE FROM exos_event_checkins WHERE event_id='$E'; DELETE FROM exos_ticket_print_codes WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E'; DELETE FROM exos_checkin_lists WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$HOLDER');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-print.test',now()),('$HOLDER','fan@race-print.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race print','race-print','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,currency,created_by)
         VALUES ('$E','$O','Race','race-print','published',now() - interval '1 hour',0,0,'usd','$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES ('$T','$E','GA',20,100,0,'public',1);
       INSERT INTO exos_checkin_lists(id,event_id,name,allow_reentry,sort_order) VALUES
         ('$L1','$E','Front',true,0),('$L2','$E','Side',true,1);
       INSERT INTO exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
       SELECT ('bf500000-0000-0000-0000-0000000c00'||n)::uuid,'$E','$O','$T','GA','$HOLDER','$HOLDER','fan@race-print.test','active','sek-'||n,20,'race-'||n,'stripe'
         FROM unnest(ARRAY['01','02','03']) n;
       INSERT INTO exos_membership_products(id,org_id,name,price_cents,billing,capacity) VALUES ('$M','$O','Race members',1000,'year',1);" >/dev/null
AS="SELECT set_config('app.uid','$A',false);"
print() { $P -c "$AS SELECT public.exos_ticket_print(ARRAY['$1'::uuid]) #>> '{tickets,0,print_code}'" | tail -1; }
scan() { echo "public.exos_check_in_ticket('$1','camera','verified','$2','$E',NULL,NULL,NULL,$3,'entry')->>'reason'"; }
two() {   # $1 / $2: two SELECTs; the first holds its transaction 2 s
  ( $P -c "$AS BEGIN; SELECT 'first '||($1); SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -o "first [a-z-]*\|ERROR: .*" | sed 's/^/  /' || true ) &
  sleep 0.5
  ( $P -c "$AS SELECT 'second '||($2);" 2>&1 | grep -o "second [a-z-]*\|ERROR: .*" | sed 's/^/  /' || true )
  wait
}
admissions() { $P -c "SELECT count(*) FROM exos_event_checkins WHERE ticket_id='$1' AND direction='entry'"; }

echo "race 1: the same paper at two doors at once"
C=$(print "$(tk 01)")
two "$(scan "$(tk 01)" "$C" NULL)" "$(scan "$(tk 01)" "$C" NULL)"
echo "  -> admissions=$(admissions "$(tk 01)") (expect 1)"

echo "race 2: the same paper at two re-entry lists at once"
C=$(print "$(tk 02)")
two "$(scan "$(tk 02)" "$C" "'$L1'::uuid")" "$(scan "$(tk 02)" "$C" "'$L2'::uuid")"
echo "  -> admissions=$(admissions "$(tk 02)") (expect 1)"

echo "race 3: a reprint while the paper is scanned"
C=$(print "$(tk 03)")
two "$(scan "$(tk 03)" "$C" NULL)" "(public.exos_ticket_print(ARRAY['$(tk 03)'::uuid]) #>> '{tickets,0,ticket_id}')"
echo "  -> admissions=$(admissions "$(tk 03)") live=$($P -c "SELECT count(*) FROM exos_ticket_print_codes WHERE ticket_id='$(tk 03)' AND status='active'") (expect 1 / 0)"

echo "race 4: one membership place, two reservations at once"
R="(public.exos_membership_reserve('$M', jsonb_build_object('email', 'r'||floor(random()*1e9)||'@race.test'))->>'state')"
two "$R" "$R"
echo "  -> open=$($P -c "SELECT count(*) FROM exos_membership_reservations WHERE product_id='$M' AND status='reserved'") (expect 1)"
