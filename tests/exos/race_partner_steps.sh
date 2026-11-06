#!/usr/bin/env bash
# Partner reservations vs checkouts (mig 20261107120000): real parallel
# sessions. Timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_partner_steps.sh exos_p0_test
# Expect:
#   race 1 the last 2 early birds (4 at $20, 2 already locked by a checkout):
#          a) a partner reserves 2 while a buyer checks out 2: the partner
#             holds them at $20, the buyer is told the price changed
#          b) a buyer locks 2 while a partner reserves 2: the partner waits
#             and reserves at the next price ($30)
#          never more than 4 places at $20
#   race 2 a partner completes a two-type reservation (A in pool Q2, B in
#          pool Q1: line order is the reverse of the pool order) while a buyer
#          holds a type in both pools. A third session holds Q1 so the buyer
#          queues for it first, then the partner. Before the fix the partner
#          held Q2 and waited for Q1 while the buyer held Q1 and waited for
#          Q2: a deadlock. Now complete locks Q1 before Q2: both succeed.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=b58ace00-0000-0000-0000-000000000001; A=b58ace00-0000-0000-0000-0000000000a0
B1=b58ace00-0000-0000-0000-0000000000b1; B2=b58ace00-0000-0000-0000-0000000000b2; B3=b58ace00-0000-0000-0000-0000000000b3
E=b58ace00-0000-0000-0000-0000000000e1; T=b58ace00-0000-0000-0000-0000000000d1
TA=b58ace00-0000-0000-0000-0000000000d2; TB=b58ace00-0000-0000-0000-0000000000d3; TC=b58ace00-0000-0000-0000-0000000000d4
Q1=b58ace00-0000-0000-0000-0000000000c1; Q2=b58ace00-0000-0000-0000-0000000000c2
PT=b58ace00-0000-0000-0000-0000000000f1
OUT="$(mktemp -d)"
as() { echo "SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false);"; }
cleanup() {
  $P -c "DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_partner_reservations WHERE event_id='$E';
         DELETE FROM exos_quotas WHERE event_id='$E';
         DELETE FROM exos_price_steps WHERE event_id='$E';
         DELETE FROM exos_tier_distribution WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_distribution_partners WHERE org_id='$O';
         DELETE FROM exos_mail WHERE created_by='$A';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$B1','$B2','$B3');" >/dev/null
  rm -rf "$OUT"
}
cleanup; OUT="$(mktemp -d)"
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-pst.test',now()),
         ('$B1','b1@race-pst.test',now()),('$B2','b2@race-pst.test',now()),('$B3','b3@race-pst.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race partner steps','race-pst','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-pst','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
         ('$T','$E','GA',20,100,0,'public',1),('$TA','$E','A',30,50,0,'public',2),
         ('$TB','$E','B',40,50,0,'public',3),('$TC','$E','C',50,50,0,'public',4);
       INSERT INTO exos_tier_distribution(tier_id,event_id,org_id,enabled)
         SELECT id, event_id, '$O', true FROM exos_ticket_tiers WHERE event_id='$E';
       INSERT INTO exos_distribution_partners(id,org_id,label,partner_type,key_prefix,key_hash,scopes)
         VALUES ('$PT','$O','Race partner','stubhub','dk_live_b58race0',repeat('5e',32),ARRAY['inventory']);
       $(as $A owner@race-pst.test)
       SELECT public.exos_set_price_steps('$T', '[{\"name\":\"Early bird\",\"price_cents\":2000,\"ends_after_count\":4},
                                                  {\"name\":\"Final\",\"price_cents\":3000}]');" >/dev/null
# A buyer, as exos-checkout does it: read the price, hold, lock it on the hold.
buy() {
  echo "$(as $1 $2)
        CREATE TEMP TABLE IF NOT EXISTS cp AS SELECT public.exos_tier_current_price('$T') AS j;
        CREATE TEMP TABLE IF NOT EXISTS hh AS SELECT public.exos_create_hold('$E','$T',$3) AS id;
        SELECT public.exos_hold_lock_price((SELECT id FROM hh), ((SELECT j FROM cp)->>'step_id')::uuid, ((SELECT j FROM cp)->>'price_cents')::int) ->> 'price_cents';"
}
# A partner reservation (exos-api's public-create-reservation).
reserve() {
  echo "SELECT public._exos_partner_reserve('$O','$E','$PT',NULL,'$1'::jsonb,'{}'::jsonb,false,false) ->> 'token';"
}
# Places at the early-bird price: checkout holds locked at $20 + partner
# reservations quoted at $20 (active or completed).
at20() {
  $P -c "SELECT (SELECT coalesce(sum(quantity),0) FROM exos_cart_holds
                  WHERE tier_id='$T' AND status='active' AND expires_at > now() AND partner_reservation_id IS NULL
                    AND unit_price_cents=2000)
              + (SELECT coalesce(sum((l->>'quantity')::int),0) FROM exos_partner_reservations r, jsonb_array_elements(r.lines) l
                  WHERE r.event_id='$E' AND r.status IN ('active','completed') AND l->>'tier_id'='$T' AND (l->>'unit_cents')::int=2000)"
}
GA2="[{\"ticket_type_id\":\"$T\",\"quantity\":2}]"
reset1() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E'; DELETE FROM exos_partner_reservations WHERE event_id='$E';" >/dev/null
  # Two early birds already locked by someone else: 2 left at \$20.
  $P -c "BEGIN; $(buy $B3 b3@race-pst.test 2) COMMIT;" >/dev/null
}

echo "race 1a: a partner reserves the last 2 early birds while a buyer checks out 2"
reset1
( $P -c "BEGIN; $(reserve "$GA2") SELECT pg_sleep(2); COMMIT;" >"$OUT/p1" 2>&1 && echo "  partner: reserved" || echo "  partner: refused" ) &
sleep 0.5
R=$($P -c "BEGIN; $(buy $B1 b1@race-pst.test 2) COMMIT;" 2>&1 || true)
wait
case "$R" in *price_changed*) echo "  buyer: refused (price_changed)";; *) echo "  buyer: $R";; esac
N=$(at20)
echo "  -> places at \$20=$N (expect 4: 2 before + the partner's 2)"
[ "$N" = "4" ] || { echo "FAIL"; exit 1; }
case "$R" in *price_changed*) ;; *) echo "FAIL (the buyer should be told the price changed)"; exit 1;; esac

echo "race 1b: a buyer locks the last 2 early birds while a partner reserves 2"
reset1
( $P -c "BEGIN; $(buy $B1 b1@race-pst.test 2) SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 && echo "  buyer: locked \$20" || echo "  buyer: refused" ) &
sleep 0.5
$P -c "BEGIN; $(reserve "$GA2") COMMIT;" >/dev/null 2>&1 && echo "  partner: reserved" || echo "  partner: refused"
wait
N=$(at20)
PR=$($P -c "SELECT string_agg((l->>'unit_cents'), ',') FROM exos_partner_reservations r, jsonb_array_elements(r.lines) l WHERE r.event_id='$E'")
echo "  -> places at \$20=$N (expect 4), partner price=$PR (expect 3000)"
[ "$N" = "4" ] && [ "$PR" = "3000" ] || { echo "FAIL"; exit 1; }
NOW=$($P -c "SELECT public.exos_tier_current_price('$T') ->> 'price_cents'")
[ "$NOW" = "3000" ] || { echo "FAIL (price now $NOW)"; exit 1; }

echo "race 2: a two-type partner reservation completes while a buyer holds a type in both pools"
$P -c "DELETE FROM exos_cart_holds WHERE event_id='$E'; DELETE FROM exos_partner_reservations WHERE event_id='$E';
       INSERT INTO exos_quotas(id,event_id,org_id,name,size) VALUES ('$Q1','$E','$O','Room',20),('$Q2','$E','$O','Bar',20);
       INSERT INTO exos_quota_tiers(quota_id,tier_id) VALUES ('$Q2','$TA'),('$Q1','$TB'),('$Q1','$TC'),('$Q2','$TC');" >/dev/null
TOK=$($P -c "$(reserve "[{\"ticket_type_id\":\"$TA\",\"quantity\":1},{\"ticket_type_id\":\"$TB\",\"quantity\":1}]")")
# The blocker holds Q1 for 3 s: the buyer queues for Q1 first, the partner second.
( $P -c "BEGIN; SELECT 1 FROM exos_quotas WHERE id='$Q1' FOR UPDATE; SELECT pg_sleep(3); COMMIT;" >/dev/null ) &
sleep 0.5
( $P -c "$(as $B2 b2@race-pst.test) SELECT public.exos_create_hold('$E','$TC',1);" >"$OUT/buyer" 2>&1 || true ) &
sleep 0.5
( $P -c "SELECT public._exos_partner_reservation_complete('$O','$PT','$TOK',NULL,'https://exos.test') ->> 'status';" >"$OUT/partner" 2>&1 || true ) &
wait
echo "  buyer:   $(tr '\n' ' ' <"$OUT/buyer" | cut -c1-160)"
echo "  partner: $(tr '\n' ' ' <"$OUT/partner" | cut -c1-160)"
if grep -qi deadlock "$OUT/buyer" "$OUT/partner"; then echo "  DEADLOCK"; echo "FAIL"; exit 1; fi
HELD=$($P -c "SELECT count(*) FROM exos_cart_holds WHERE tier_id='$TC' AND status='active'")
DONE=$($P -c "SELECT status FROM exos_partner_reservations WHERE token='$TOK'")
echo "  -> buyer holds=$HELD (expect 1), reservation=$DONE (expect completed), no deadlock"
[ "$HELD" = "1" ] && [ "$DONE" = "completed" ] || { echo "FAIL"; exit 1; }
echo "all races OK"
