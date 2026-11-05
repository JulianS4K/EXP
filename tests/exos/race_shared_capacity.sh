#!/usr/bin/env bash
# Shared capacity races (mig 20261106120000): real parallel sessions.
# Timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_shared_capacity.sh exos_p0_test
# Expect:
#   race 1 the last place of a pool, two buyers, two DIFFERENT ticket types
#          (GA and VIP share a room of 3, 2 already held): one hold, the other
#          refused; the room never goes past 3
#   race 2 two buyers of two types that share TWO pools (A in Room+Bar, B in
#          Bar+Room): the pools are locked by id, so no deadlock, one wins
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=5c5ace00-0000-0000-0000-000000000001; A=5c5ace00-0000-0000-0000-0000000000a0
B1=5c5ace00-0000-0000-0000-0000000000b1; B2=5c5ace00-0000-0000-0000-0000000000b2; B3=5c5ace00-0000-0000-0000-0000000000b3
E=5c5ace00-0000-0000-0000-0000000000e1; GA=5c5ace00-0000-0000-0000-0000000000d1; VIP=5c5ace00-0000-0000-0000-0000000000d2
Q1=5c5ace00-0000-0000-0000-0000000000c1; Q2=5c5ace00-0000-0000-0000-0000000000c2
as() { echo "SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false);"; }
cleanup() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_quotas WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$B1','$B2','$B3');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-sc.test',now()),
         ('$B1','b1@race-sc.test',now()),('$B2','b2@race-sc.test',now()),('$B3','b3@race-sc.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race pools','race-sc','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-sc','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
         ('$GA','$E','GA',20,10,0,'public'),('$VIP','$E','VIP',50,10,0,'public');
       INSERT INTO exos_quotas(id,event_id,org_id,name,size) VALUES ('$Q1','$E','$O','Room',3);
       INSERT INTO exos_quota_tiers(quota_id,tier_id) VALUES ('$Q1','$GA'),('$Q1','$VIP');" >/dev/null
hold() { echo "$(as $1 $2) SELECT public.exos_create_hold('$E','$3',$4);"; }

echo "race 1: the last place in a room, GA and VIP buyers at once"
$P -c "$(hold $B3 b3@race-sc.test $GA 2)" >/dev/null
( $P -c "BEGIN; $(hold $B1 b1@race-sc.test $GA 1) SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 && echo "  GA buyer: held" || echo "  GA buyer: refused" ) &
sleep 0.5
$P -c "$(hold $B2 b2@race-sc.test $VIP 1)" >/dev/null 2>&1 && echo "  VIP buyer: held" || echo "  VIP buyer: refused"
wait
N=$($P -c "SELECT coalesce(sum(quantity),0) FROM exos_cart_holds WHERE event_id='$E' AND status='active'")
echo "  -> held in the room=$N (expect 3)"
[ "$N" = "3" ] || { echo "FAIL"; exit 1; }

echo "race 2: two types in two shared pools, locked in one order"
$P -c "UPDATE exos_cart_holds SET status='released', released_at=now() WHERE event_id='$E';
       UPDATE exos_quotas SET size=1 WHERE id='$Q1';
       INSERT INTO exos_quotas(id,event_id,org_id,name,size) VALUES ('$Q2','$E','$O','Bar',1);
       INSERT INTO exos_quota_tiers(quota_id,tier_id) VALUES ('$Q2','$GA'),('$Q2','$VIP');" >/dev/null
( $P -c "BEGIN; $(hold $B1 b1@race-sc.test $GA 1) SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -i deadlock && echo "  DEADLOCK" ) &
sleep 0.5
$P -c "$(hold $B2 b2@race-sc.test $VIP 1)" 2>&1 | grep -i deadlock && echo "  DEADLOCK" || true
wait
N=$($P -c "SELECT coalesce(sum(quantity),0) FROM exos_cart_holds WHERE event_id='$E' AND status='active'")
echo "  -> held=$N (expect 1, no deadlock)"
[ "$N" = "1" ] || { echo "FAIL"; exit 1; }
echo "all races OK"
