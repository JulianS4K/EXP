#!/usr/bin/env bash
# Partner API leftovers (mig 20261111140000): real parallel sessions.
# Timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_api_leftovers.sh exos_p0_test
# Expect:
#   race 1 a holder fires 8 add-on wallet reissues at once over two passes:
#          exactly 5 go through (the per-holder lock serialises the count),
#          5 log rows, and the two epochs moved 5 steps in all
#   race 2 a partner completes while an update replacing the same
#          reservation's answers arrives: the update waits for the row lock,
#          then sees the reservation completed (409) and changes nothing; the
#          first set is attached, none left unattached
#   race 3 the other way round: an update replacing the answers holds the
#          lock while the complete arrives; the complete waits, then mints
#          with the replaced set attached
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=11400000-0000-4000-8000-000000000001; A=11400000-0000-4000-8000-0000000000a0
B=11400000-0000-4000-8000-0000000000b1
E=11400000-0000-4000-8000-0000000000e1; T=11400000-0000-4000-8000-0000000000d1
P1=11400000-0000-4000-8000-0000000000f1; AD=11400000-0000-4000-8000-0000000000ad
L1=11400000-0000-4000-8000-0000000000c1; K1=11400000-0000-4000-8000-0000000000c2
OUT=""
cleanup() {
  $P -c "DELETE FROM exos_addon_wallet_reissues WHERE event_id='$E';
         DELETE FROM exos_addon_passes WHERE event_id='$E';
         DELETE FROM exos_order_addons WHERE event_id='$E';
         DELETE FROM exos_event_addons WHERE event_id='$E';
         DELETE FROM exos_question_answers WHERE event_id='$E';
         DELETE FROM exos_question_answer_cursors WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_partner_reservations WHERE event_id='$E';
         DELETE FROM exos_event_questions WHERE event_id='$E';
         DELETE FROM exos_tier_distribution WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_distribution_partners WHERE org_id='$O';
         DELETE FROM exos_mail WHERE created_by='$A';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$B');" >/dev/null
  if [ -n "$OUT" ]; then rm -rf "$OUT"; fi
}
cleanup; OUT="$(mktemp -d)"
trap cleanup EXIT
Q=$($P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-al11.test',now()), ('$B','buyer@race-al11.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race al11','race-al11','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-al11','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
         ('$T','$E','GA',20,10,0,'public',1);
       INSERT INTO exos_tier_distribution(tier_id,event_id,org_id,enabled) VALUES ('$T','$E','$O',true);
       INSERT INTO exos_distribution_partners(id,org_id,label,partner_type,key_prefix,key_hash,scopes) VALUES
         ('$P1','$O','Race one','stubhub','dk_live_al11rce1',repeat('8a',32),ARRAY['inventory']);
       INSERT INTO exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode) VALUES
         ('$AD','$E','VIP lounge',30,100,true);
       INSERT INTO exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source)
         VALUES ('$K1','$E','$O','$T','GA','$B','$B','buyer@race-al11.test','active','sek-race-al11',20,'cs_race_al11','stripe');
       INSERT INTO exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source)
         VALUES ('$L1','$E','$O','$AD','VIP lounge','$B','$B',2,30,'cs_race_al11','stripe');
       UPDATE exos_addon_passes SET wallet_epoch = 1 WHERE order_addon_id = '$L1';
       INSERT INTO exos_event_questions(org_id,event_id,label,kind,options,required,scope)
         VALUES ('$O','$E','Size','single_choice',ARRAY['S','M','L'],true,'ticket') RETURNING id;")
PASSES=($($P -c "SELECT id FROM exos_addon_passes WHERE order_addon_id='$L1' ORDER BY unit_index"))
[ "${#PASSES[@]}" = "2" ] || { echo "FAIL: expected 2 add-on passes, got ${#PASSES[@]}"; exit 1; }

echo "race 1: 8 reissues by one holder at once (limit 5 a day)"
for i in 1 2 3 4 5 6 7 8; do
  PASS="${PASSES[$((i % 2))]}"
  ( $P -c "SELECT set_config('app.uid','$B',false); SELECT public.exos_wallet_addon_reissue('$PASS') ->> 'ok';" \
      >"$OUT/w$i" 2>&1 || true ) &
done
wait
NOK=0
for i in 1 2 3 4 5 6 7 8; do
  if grep -qx "true" "$OUT/w$i"; then NOK=$((NOK + 1)); fi
done
NLOG=$($P -c "SELECT count(*) FROM exos_addon_wallet_reissues WHERE holder_id='$B'")
STEPS=$($P -c "SELECT sum(wallet_epoch - 1) FROM exos_addon_passes WHERE order_addon_id='$L1'")
echo "  -> ok=$NOK (expect 5), logged=$NLOG (expect 5), epoch steps=$STEPS (expect 5)"
[ "$NOK" = "5" ] && [ "$NLOG" = "5" ] && [ "$STEPS" = "5" ] || { echo "FAIL"; for i in 1 2 3 4 5 6 7 8; do tr '\n' ' ' <"$OUT/w$i"; echo; done; exit 1; }

LINE="[{\"ticket_type_id\":\"$T\",\"quantity\":1}]"
reserve() {
  echo "SELECT public._exos_partner_reserve('$O','$E','$P1',NULL,'$LINE'::jsonb,'{\"answers\":{\"tickets\":[{\"$Q\":\"$1\"}]}}'::jsonb,false,false) ->> 'token';"
}
complete() {
  echo "SELECT public._exos_partner_reservation_complete('$O','$P1','$1',NULL,'https://exos.test') ->> 'status';"
}
update() {
  echo "SELECT public._exos_partner_reservation_update('$O','$P1','$1','{\"answers\":{\"tickets\":[{\"$Q\":\"$2\"}]}}'::jsonb) ->> 'status';"
}
answer_of() {
  $P -c "SELECT string_agg(a.display || ':' || (a.attached_at IS NOT NULL), ',') FROM exos_question_answers a
          JOIN exos_partner_reservations r ON a.order_ref = 'po:' || r.id WHERE r.token = '$1'"
}

echo "race 2: complete holds the lock; an update replacing the answers arrives"
TOK=$($P -c "$(reserve S)")
( $P -c "BEGIN; $(complete "$TOK") SELECT pg_sleep(1.5); COMMIT;" >"$OUT/c2" 2>&1 || true ) &
sleep 0.3
( $P -c "$(update "$TOK" L)" >"$OUT/u2" 2>&1 || true ) &
wait
echo "  complete: $(tr '\n' ' ' <"$OUT/c2" | cut -c1-100)"
echo "  update:   $(tr '\n' ' ' <"$OUT/u2" | cut -c1-100)"
ANS=$(answer_of "$TOK")
echo "  -> answers=$ANS (expect S:true), update refused: $(grep -c 'completed' "$OUT/u2" || true) (expect 1)"
[ "$ANS" = "S:true" ] && grep -q "this reservation is completed" "$OUT/u2" || { echo "FAIL"; exit 1; }

echo "race 3: an update replacing the answers holds the lock; complete arrives"
TOK=$($P -c "$(reserve S)")
( $P -c "BEGIN; $(update "$TOK" M) SELECT pg_sleep(1.5); COMMIT;" >"$OUT/u3" 2>&1 || true ) &
sleep 0.3
( $P -c "$(complete "$TOK")" >"$OUT/c3" 2>&1 || true ) &
wait
echo "  update:   $(tr '\n' ' ' <"$OUT/u3" | cut -c1-100)"
echo "  complete: $(tr '\n' ' ' <"$OUT/c3" | cut -c1-100)"
ANS=$(answer_of "$TOK")
LOOSE=$($P -c "SELECT count(*) FROM exos_question_answers WHERE event_id='$E' AND attached_at IS NULL")
echo "  -> answers=$ANS (expect M:true), unattached=$LOOSE (expect 0)"
[ "$ANS" = "M:true" ] && [ "$LOOSE" = "0" ] && grep -qx "completed" "$OUT/c3" || { echo "FAIL"; exit 1; }
echo "all races OK"
