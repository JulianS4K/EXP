#!/usr/bin/env bash
# Partner races (claude/exos-small-ops): real parallel sessions against the
# per-partner caps of mig 20261104200000. Timing-based, so run by hand against
# a DB built by run_p0.sh:
#   bash tests/exos/race_sim_partner.sh exos_p0_test
# Expect:
#   race 1 one partner, a GA cap of 5, two reservations of 3 at once: one
#          reservation, the other refused EXCAP (partner_cap_reached)
#   race 2 an event cap of 5, two reservations of 3 at once on DIFFERENT ticket
#          types (no shared tier lock): still one, the other EXCAP; the cap's
#          advisory lock is what serializes them
#   race 3 two partners each capped at 5 on the same type, 3 each at once:
#          both reserve (one partner's cap never blocks another)
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=be500000-0000-0000-0000-000000000001; A=be500000-0000-0000-0000-0000000000a0
E=be500000-0000-0000-0000-0000000000e1; T1=be500000-0000-0000-0000-0000000000d1; T2=be500000-0000-0000-0000-0000000000d2
cleanup() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_partner_reservations WHERE event_id='$E';
         DELETE FROM exos_partner_caps WHERE event_id='$E';
         DELETE FROM exos_tier_distribution WHERE event_id='$E';
         DELETE FROM exos_distribution_partners WHERE org_id='$O';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-simp.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race partner','race-simp','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,currency,created_by)
         VALUES ('$E','$O','Race','race-simp','published',now() + interval '10 days',0,0,'usd','$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
         ('$T1','$E','GA',20,100,0,'public',1),('$T2','$E','VIP',40,100,0,'public',2);
       INSERT INTO exos_tier_distribution(tier_id,event_id,org_id,enabled) VALUES
         ('$T1','$E','$O',true),('$T2','$E','$O',true);" >/dev/null
PA=$($P -c "SELECT public._exos_dist_partner_create('$O','Race A','stubhub',ARRAY['inventory'],'$A',NULL)->>'id'")
PB=$($P -c "SELECT public._exos_dist_partner_create('$O','Race B','vivid',ARRAY['inventory'],'$A',NULL)->>'id'")
line() { echo "jsonb_build_array(jsonb_build_object('ticket_type_id','$1','quantity',$2))"; }
reserve() { echo "(public._exos_partner_reserve('$O','$E','$1',NULL,$(line "$2" "$3"),'{}')->>'status')"; }
caps() { $P -c "SELECT jsonb_array_length(public._exos_partner_caps_set('$O','$E','$1'::jsonb,NULL))" >/dev/null; }
held() { $P -c "SELECT coalesce(sum(h.quantity),0) FROM exos_cart_holds h JOIN exos_partner_reservations r ON r.id=h.partner_reservation_id
                 WHERE r.partner_id='$1' AND h.status='active'"; }
clear() { $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E'; DELETE FROM exos_partner_reservations WHERE event_id='$E';
                 DELETE FROM exos_partner_caps WHERE event_id='$E';" >/dev/null; }
two() {   # $1 / $2: the two reserve calls; the first holds its transaction 2 s
  ( $P -c "BEGIN; SELECT 'first '||$1; SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -o "first active\|partner_cap_reached" | sed 's/^/  /' || true ) &
  sleep 0.5
  ( $P -c "SELECT 'second '||$2" 2>&1 | grep -o "second active\|partner_cap_reached" | sed 's/^/  /' || true )
  wait
}

echo "race 1: one partner, GA cap 5, 3 + 3 at once"
caps "[{\"partner_id\":\"$PA\",\"tier_id\":\"$T1\",\"max_tickets\":5}]"
two "$(reserve "$PA" "$T1" 3)" "$(reserve "$PA" "$T1" 3)"
N=$(held "$PA"); echo "  -> held=$N (expect 3)"
[ "$N" = "3" ] || { echo "FAIL"; exit 1; }
clear

echo "race 2: one partner, event cap 5, 3 GA + 3 VIP at once"
caps "[{\"partner_id\":\"$PA\",\"max_tickets\":5}]"
two "$(reserve "$PA" "$T1" 3)" "$(reserve "$PA" "$T2" 3)"
N=$(held "$PA"); echo "  -> held=$N (expect 3)"
[ "$N" = "3" ] || { echo "FAIL"; exit 1; }
clear

echo "race 3: two partners, each GA cap 5, 3 each at once"
caps "[{\"partner_id\":\"$PA\",\"tier_id\":\"$T1\",\"max_tickets\":5},{\"partner_id\":\"$PB\",\"tier_id\":\"$T1\",\"max_tickets\":5}]"
two "$(reserve "$PA" "$T1" 3)" "$(reserve "$PB" "$T1" 3)"
NA=$(held "$PA"); NB=$(held "$PB"); echo "  -> held A=$NA B=$NB (expect 3 3)"
[ "$NA" = "3" ] && [ "$NB" = "3" ] || { echo "FAIL"; exit 1; }
echo "race_sim_partner: all passed"
