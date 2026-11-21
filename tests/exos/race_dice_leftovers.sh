#!/usr/bin/env bash
# DICE leftovers races (mig 20261108110000): real parallel sessions. Timing-
# based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_dice_leftovers.sh exos_p0_test
# Expect:
#   race 1 the same API fee adjustment twice at once (one idempotency key):
#          one row, the second answers duplicate
#   race 2 two API fee adjustments at once, each taking all the fees left:
#          one goes through, the other is refused (never below zero)
#   race 3 a manager and the scanner undo one add-on scan at once: one undo,
#          the other 'not-checked-in'; one undo row, the pass active
#   race 4 one walk-up sale with skipped questions sent twice at once (one
#          order key): one sale, one skip row
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=d1ace000-0000-0000-0000-000000000001; A=d1ace000-0000-0000-0000-0000000000a0
F=d1ace000-0000-0000-0000-0000000000a1; S=d1ace000-0000-0000-0000-0000000000a2; M=d1ace000-0000-0000-0000-0000000000a3
B=d1ace000-0000-0000-0000-0000000000b1; E=d1ace000-0000-0000-0000-0000000000e1; AD=d1ace000-0000-0000-0000-0000000000ad
LN=d1ace000-0000-0000-0000-0000000000c1; L=d1ace000-0000-0000-0000-0000000000f1; K=d1ace000-0000-0000-0000-0000000000f2
T=d1ace000-0000-0000-0000-0000000000f3; DR=d1ace000-0000-0000-0000-0000000000f4; OK1=d1ace000-0000-0000-0000-0000000000f5
as() { echo "SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false);"; }
cleanup() {
  $P -c "DELETE FROM exos_checkout_sessions WHERE session_id IN ('cs_race_dl1');
         DELETE FROM exos_pos_question_skips WHERE event_id='$E';
         DELETE FROM exos_question_answers WHERE event_id='$E'; DELETE FROM exos_question_answer_cursors WHERE event_id='$E';
         DELETE FROM exos_event_questions WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_pos_payments WHERE event_id='$E'; DELETE FROM exos_pos_order_lines WHERE event_id='$E';
         DELETE FROM exos_pos_orders WHERE event_id='$E'; DELETE FROM exos_pos_items WHERE event_id='$E';
         DELETE FROM exos_pos_drawer_sessions WHERE event_id='$E';
         DELETE FROM exos_addon_pass_undos WHERE event_id='$E';
         DELETE FROM exos_addon_pass_checkins WHERE event_id='$E'; DELETE FROM exos_addon_passes WHERE event_id='$E';
         DELETE FROM exos_order_addons WHERE event_id='$E'; DELETE FROM exos_checkin_lists WHERE event_id='$E';
         DELETE FROM exos_event_addons WHERE event_id='$E'; DELETE FROM exos_ticket_tiers WHERE event_id='$E';
         DELETE FROM exos_checkin_client_refs WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_api_keys WHERE org_id='$O';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$F','$S','$M','$B');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-dl.test',now()),
         ('$F','fin@race-dl.test',now()),('$S','s@race-dl.test',now()),('$M','m@race-dl.test',now()),('$B','b@race-dl.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race dl','race-dl','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner'),('$O','$F','finance'),
         ('$O','$S','scanner'),('$O','$M','manager');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,currency,created_by)
         VALUES ('$E','$O','Race','race-dl','published',now() + interval '1 hour',now() - interval '1 hour',100,'usd','$A');
       INSERT INTO exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order, door_price_cents)
         VALUES ('$T','$E','GA',20,100,0,'public',1,2500);
       INSERT INTO exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents, currency, status)
         VALUES ('cs_race_dl1','$E','$O','$B','b@race-dl.test',false,2,10000,'usd','fulfilled');
       INSERT INTO exos_order_fees (session_id, org_id, event_id, rule_name, kind, calc, per, item_kind, unit_cents, quantity, amount_cents)
         VALUES ('cs_race_dl1','$O','$E','Service','passed_on','fixed','ticket','ticket',150,2,300);
       INSERT INTO exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by)
         VALUES ('$K','$O','race key','sk_live_racedl','racedlhash',ARRAY['finance:write'],'$F');
       INSERT INTO exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode) VALUES ('$AD','$E','Lounge',30,100,true);
       INSERT INTO exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source)
         VALUES ('$LN','$E','$O','$AD','Lounge','$B','$B',1,30,'cs_race_dl1','stripe');
       INSERT INTO exos_checkin_lists (id, event_id, org_id, name, admits) VALUES ('$L','$E',NULL,'Lounge','addons');
       INSERT INTO exos_event_questions (org_id, event_id, label, kind, required, scope) VALUES ('$O','$E','Company','text',true,'order');" >/dev/null
$P -c "$(as $S s@race-dl.test) INSERT INTO exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES ('$DR','$E',10000);" >/dev/null

echo "race 1: one API fee adjustment sent twice at once"
ADJ="SELECT public._exos_api_fee_adjustment('$O','$K','cs_race_dl1',-100,'Goodwill',NULL,'race-dl-key-1')"
( $P -c "BEGIN; $ADJ; SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
D=$($P -c "BEGIN; SELECT ($ADJ) ->> 'duplicate'; COMMIT;" | grep -v '^$' | tail -1)
wait
N=$($P -c "SELECT count(*) FROM exos_fee_adjustments WHERE session_id='cs_race_dl1'")
echo "  -> rows=$N, second answered duplicate=$D (expect 1, true)"
[ "$N" = "1" ] && [ "$D" = "true" ] || { echo "FAIL"; exit 1; }

echo "race 2: two API adjustments at once, each taking all the fees left (200)"
( $P -c "BEGIN; SELECT public._exos_api_fee_adjustment('$O','$K','cs_race_dl1',-200,'Waive A',NULL,'race-dl-key-2'); SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 \
  && echo "  first: recorded" || echo "  first: refused" ) &
sleep 0.5
$P -c "SELECT public._exos_api_fee_adjustment('$O','$K','cs_race_dl1',-200,'Waive B',NULL,'race-dl-key-3');" >/dev/null 2>&1 \
  && echo "  second: recorded" || echo "  second: refused"
wait
R=$($P -c "SELECT count(*) || ' ' || sum(fees_change_cents) FROM exos_fee_adjustments WHERE session_id='cs_race_dl1'")
echo "  -> rows / sum = $R (expect 2 -300: never below zero)"
[ "$R" = "2 -300" ] || { echo "FAIL"; exit 1; }

echo "race 3: a manager and the scanner undo one add-on scan at once"
PASS="(SELECT id FROM exos_addon_passes WHERE order_addon_id = '$LN')"
CODE="(SELECT 'A-' || p.id || ':' || p.owner_id || ':' || b || ':' || public._exos_door_code_mac(p.id, p.owner_id, b, p.barcode_secret)
          FROM exos_addon_passes p, (SELECT floor(extract(epoch FROM now()) * 1000 / 30000)::bigint AS b) x WHERE p.order_addon_id = '$LN')"
$P -c "$(as $S s@race-dl.test) SELECT public.exos_check_in_ticket($PASS, 'camera', 'verified', $CODE, '$E', NULL, NULL, 'race', '$L', 'entry') ->> 'reason';" \
  | grep -v '^$' | tail -1 | sed 's/^/  scanned: /'
undo() { echo "$(as $1 $2) SELECT public.exos_undo_addon_check_in($PASS, '$E', 'race undo', NULL, NULL, 'race') ->> 'reason';"; }
( $P -c "BEGIN; $(undo $M m@race-dl.test) SELECT pg_sleep(2); COMMIT;" | grep -v '^$' | tail -1 | sed 's/^/  manager: /' ) &
sleep 0.5
$P -c "BEGIN; $(undo $S s@race-dl.test) COMMIT;" | grep -v '^$' | tail -1 | sed 's/^/  scanner: /'
wait
R=$($P -c "SELECT (SELECT count(*) FROM exos_addon_pass_undos WHERE event_id='$E') || ' ' || (SELECT status FROM exos_addon_passes WHERE order_addon_id='$LN')")
echo "  -> undo rows / pass status = $R (expect 1 active)"
[ "$R" = "1 active" ] || { echo "FAIL"; exit 1; }

echo "race 4: one walk-up sale with skipped questions sent twice at once"
SELL="SELECT public.exos_pos_walkup_sell('$E','$T',1,'$OK1',0,'cash',NULL,'$DR','Walk Up',NULL,NULL,NULL,true)"
( $P -c "BEGIN; $(as $S s@race-dl.test) $SELL; SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
RP=$($P -c "BEGIN; $(as $S s@race-dl.test) SELECT ($SELL) ->> 'replay'; COMMIT;" | grep -v '^$' | tail -1)
wait
R=$($P -c "SELECT (SELECT count(*) FROM exos_pos_orders WHERE client_ref='$OK1') || ' ' || (SELECT count(*) FROM exos_pos_question_skips WHERE event_id='$E')")
echo "  -> orders / skip rows = $R, second replay=$RP (expect 1 1, true)"
[ "$R" = "1 1" ] && [ "$RP" = "true" ] || { echo "FAIL"; exit 1; }
echo "all races OK"
