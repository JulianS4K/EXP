#!/usr/bin/env bash
# DICE gaps 6 races (mig 20261107110000): real parallel sessions. Timing-based,
# so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_dice_gaps_6.sh exos_p0_test
# Expect:
#   race 1 two refunds of one order recorded at once (half each): the fee log
#          ends at exactly the order's buyer fees (-300), never twice, never
#          short (exos_record_refund holds the order row)
#   race 2 the same manual adjustment twice at once (one idempotency key): one
#          row, the second answers duplicate
#   race 3 two manual adjustments at once, each taking all of the fees left:
#          one goes through, the other is refused (never below zero)
#   race 4 two scanners scan one add-on code at the lounge at once: one
#          checked-in, the other 'used'; one check-in row
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=d6ace000-0000-0000-0000-000000000001; A=d6ace000-0000-0000-0000-0000000000a0
F=d6ace000-0000-0000-0000-0000000000a1; S1=d6ace000-0000-0000-0000-0000000000a2; S2=d6ace000-0000-0000-0000-0000000000a3
B=d6ace000-0000-0000-0000-0000000000b1; E=d6ace000-0000-0000-0000-0000000000e1; AD=d6ace000-0000-0000-0000-0000000000ad
LN=d6ace000-0000-0000-0000-0000000000c1; L=d6ace000-0000-0000-0000-0000000000f1
as() { echo "SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false);"; }
cleanup() {
  # Deleting the order cascades to its fee log (the log itself refuses a plain delete).
  $P -c "DELETE FROM exos_checkout_sessions WHERE session_id IN ('cs_race_d61', 'cs_race_d62');
         DELETE FROM exos_addon_pass_checkins WHERE event_id='$E'; DELETE FROM exos_addon_passes WHERE event_id='$E';
         DELETE FROM exos_order_addons WHERE event_id='$E'; DELETE FROM exos_checkin_lists WHERE event_id='$E';
         DELETE FROM exos_event_addons WHERE event_id='$E';
         DELETE FROM exos_checkin_client_refs WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$F','$S1','$S2','$B');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-d6.test',now()),
         ('$F','fin@race-d6.test',now()),('$S1','s1@race-d6.test',now()),('$S2','s2@race-d6.test',now()),('$B','b@race-d6.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race d6','race-d6','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner'),('$O','$F','finance'),
         ('$O','$S1','scanner'),('$O','$S2','scanner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by)
         VALUES ('$E','$O','Race','race-d6','published',now() + interval '1 hour',now() - interval '1 hour',100,'$A');
       INSERT INTO exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents, currency, status)
         VALUES ('cs_race_d61','$E','$O','$B','b@race-d6.test',false,2,10000,'usd','fulfilled'),
                ('cs_race_d62','$E','$O','$B','b@race-d6.test',false,2,10000,'usd','fulfilled');
       INSERT INTO exos_order_fees (session_id, org_id, event_id, rule_name, kind, calc, per, item_kind, unit_cents, quantity, amount_cents)
         VALUES ('cs_race_d61','$O','$E','Service','passed_on','fixed','ticket','ticket',150,2,300),
                ('cs_race_d62','$O','$E','Service','passed_on','fixed','ticket','ticket',150,2,300);
       INSERT INTO exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode) VALUES ('$AD','$E','Lounge',30,100,true);
       INSERT INTO exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source)
         VALUES ('$LN','$E','$O','$AD','Lounge','$B','$B',1,30,'cs_race_d61','stripe');
       INSERT INTO exos_checkin_lists (id, event_id, org_id, name, admits) VALUES ('$L','$E',NULL,'Lounge','addons');" >/dev/null

echo "race 1: two refunds of one order at once"
( $P -c "BEGIN; SELECT public.exos_record_refund('cs_race_d61','re_race_d6_1',5000,'succeeded'); SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
$P -c "SELECT public.exos_record_refund('cs_race_d61','re_race_d6_2',5000,'succeeded');" >/dev/null
wait
R=$($P -c "SELECT count(*) || ' ' || sum(fees_change_cents) FROM exos_fee_adjustments WHERE session_id='cs_race_d61'")
echo "  -> rows / sum = $R (expect 2 -300)"
[ "$R" = "2 -300" ] || { echo "FAIL"; exit 1; }

echo "race 2: one manual adjustment sent twice at once"
( $P -c "BEGIN; $(as $F fin@race-d6.test)
         SELECT public.exos_fee_adjustment_record('cs_race_d62', -100, 'Goodwill', NULL, 'race-d6-key-1'); SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
D=$($P -c "BEGIN; $(as $F fin@race-d6.test)
           SELECT public.exos_fee_adjustment_record('cs_race_d62', -100, 'Goodwill', NULL, 'race-d6-key-1') ->> 'duplicate'; COMMIT;" | tail -1)
wait
N=$($P -c "SELECT count(*) FROM exos_fee_adjustments WHERE session_id='cs_race_d62'")
echo "  -> rows=$N, second answered duplicate=$D (expect 1, true)"
[ "$N" = "1" ] && [ "$D" = "true" ] || { echo "FAIL"; exit 1; }

echo "race 3: two adjustments at once, each taking all the fees left (200)"
( $P -c "BEGIN; $(as $F fin@race-d6.test)
         SELECT public.exos_fee_adjustment_record('cs_race_d62', -200, 'Waive A'); SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 \
  && echo "  first: recorded" || echo "  first: refused" ) &
sleep 0.5
$P -c "BEGIN; $(as $A owner@race-d6.test) SELECT public.exos_fee_adjustment_record('cs_race_d62', -200, 'Waive B'); COMMIT;" >/dev/null 2>&1 \
  && echo "  second: recorded" || echo "  second: refused"
wait
R=$($P -c "SELECT count(*) || ' ' || sum(fees_change_cents) FROM exos_fee_adjustments WHERE session_id='cs_race_d62'")
echo "  -> rows / sum = $R (expect 2 -300: never below zero)"
[ "$R" = "2 -300" ] || { echo "FAIL"; exit 1; }

echo "race 4: two scanners, one add-on code, at once"
CODE="(SELECT 'A-' || p.id || ':' || p.owner_id || ':' || b || ':' || public._exos_door_code_mac(p.id, p.owner_id, b, p.barcode_secret)
          FROM exos_addon_passes p, (SELECT floor(extract(epoch FROM now()) * 1000 / 30000)::bigint AS b) x WHERE p.order_addon_id = '$LN')"
PASS="(SELECT id FROM exos_addon_passes WHERE order_addon_id = '$LN')"
scan() {
  echo "$(as $1 $2) SELECT public.exos_check_in_ticket($PASS, 'camera', 'verified', $CODE, '$E', NULL, NULL, 'race', '$L', 'entry') ->> 'reason';"
}
( $P -c "BEGIN; $(scan $S1 s1@race-d6.test) SELECT pg_sleep(2); COMMIT;" | grep -v '^$' | tail -1 | sed 's/^/  scanner 1: /' ) &
sleep 0.5
$P -c "BEGIN; $(scan $S2 s2@race-d6.test) COMMIT;" | grep -v '^$' | tail -1 | sed 's/^/  scanner 2: /'
wait
N=$($P -c "SELECT count(*) FROM exos_addon_pass_checkins WHERE event_id='$E'")
echo "  -> check-in rows=$N (expect 1)"
[ "$N" = "1" ] || { echo "FAIL"; exit 1; }
echo "all races OK"
