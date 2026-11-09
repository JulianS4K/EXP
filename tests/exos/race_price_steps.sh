#!/usr/bin/env bash
# Price step races (mig 20261106130000): real parallel sessions. Timing-based,
# so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_price_steps.sh exos_p0_test
# Expect:
#   race 1 the last 2 early-bird tickets, two buyers of 2 at once (each read
#          $20, each holds 2, each locks): one hold carries the early-bird
#          price, the other is refused (price_changed or price_step_remaining)
#          and pays the next step; never 4 tickets at $20
#   race 2 an organizer re-saves the steps while a buyer locks: one waits for
#          the other (same lock), the buyer's price is the step in force
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=b57ace00-0000-0000-0000-000000000001; A=b57ace00-0000-0000-0000-0000000000a0
B1=b57ace00-0000-0000-0000-0000000000b1; B2=b57ace00-0000-0000-0000-0000000000b2; B3=b57ace00-0000-0000-0000-0000000000b3
E=b57ace00-0000-0000-0000-0000000000e1; T=b57ace00-0000-0000-0000-0000000000d1
as() { echo "SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false);"; }
cleanup() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_price_steps WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$B1','$B2','$B3');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-ps.test',now()),
         ('$B1','b1@race-ps.test',now()),('$B2','b2@race-ps.test',now()),('$B3','b3@race-ps.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race steps','race-ps','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-ps','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES ('$T','$E','GA',20,100,0,'public');
       $(as $A owner@race-ps.test)
       SELECT public.exos_set_price_steps('$T', '[{\"name\":\"Early bird\",\"price_cents\":2000,\"ends_after_count\":4},
                                                  {\"name\":\"Final\",\"price_cents\":3000}]');" >/dev/null
# Each buyer: read the price, hold 2, (pause), lock. As exos-checkout does it.
buy() {
  echo "$(as $1 $2)
        CREATE TEMP TABLE IF NOT EXISTS cp AS SELECT public.exos_tier_current_price('$T') AS j;
        CREATE TEMP TABLE IF NOT EXISTS hh AS SELECT public.exos_create_hold('$E','$T',2) AS id;
        SELECT pg_sleep($3);
        SELECT public.exos_hold_lock_price((SELECT id FROM hh), ((SELECT j FROM cp)->>'step_id')::uuid, ((SELECT j FROM cp)->>'price_cents')::int) ->> 'price_cents';"
}
# Two early birds already held (and locked) by someone else: 2 left.
$P -c "BEGIN; $(buy $B3 b3@race-ps.test 0) COMMIT;" >/dev/null

echo "race 1: the last 2 early birds, two buyers of 2 at once"
( $P -c "BEGIN; $(buy $B1 b1@race-ps.test 0) SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 && echo "  buyer 1: locked \$20" || echo "  buyer 1: refused" ) &
sleep 0.5
$P -c "BEGIN; $(buy $B2 b2@race-ps.test 0) COMMIT;" >/dev/null 2>&1 && echo "  buyer 2: locked \$20" || echo "  buyer 2: refused"
wait
N=$($P -c "SELECT coalesce(sum(quantity),0) FROM exos_cart_holds WHERE event_id='$E' AND status='active' AND unit_price_cents=2000")
echo "  -> early-bird places locked=$N (expect 4: 2 before + one buyer's 2)"
[ "$N" = "4" ] || { echo "FAIL"; exit 1; }
NOW=$($P -c "SELECT public.exos_tier_current_price('$T') ->> 'price_cents'")
echo "  -> price now=$NOW (expect 3000)"
[ "$NOW" = "3000" ] || { echo "FAIL"; exit 1; }

echo "race 2: the organizer re-saves the steps while a buyer locks"
$P -c "DELETE FROM exos_cart_holds WHERE event_id='$E';" >/dev/null
( $P -c "BEGIN; $(as $A owner@race-ps.test)
         SELECT public.exos_set_price_steps('$T', '[{\"name\":\"Early bird\",\"price_cents\":2200,\"ends_after_count\":4},{\"name\":\"Final\",\"price_cents\":3000}]');
         SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
R=$($P -c "BEGIN; $(buy $B1 b1@race-ps.test 0) COMMIT;" 2>&1 | grep -o 'price_changed: the price is now [0-9]*' || true)
wait
echo "  buyer: $R (expect a refusal naming 2200: the price moved under the lock)"
case "$R" in *2200*) ;; *) echo "FAIL"; exit 1;; esac
echo "all races OK"
