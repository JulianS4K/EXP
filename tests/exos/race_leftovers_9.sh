#!/usr/bin/env bash
# Partner reservations with checkout answers (mig 20261110120000): real
# parallel sessions. Timing-based, so run by hand against a DB built by
# run_p0.sh:
#   bash tests/exos/race_leftovers_9.sh exos_p0_test
# Expect:
#   race 1 two partners reserve the last seat at once, both with answers: one
#          reservation, and only the winner's answers are stored (the loser's
#          roll back with its refused reserve)
#   race 2 a partner completes while the same reservation's answers arrive in
#          another session: the answers wait for the reservation's row lock,
#          then see it completed and store nothing (never an unattached set);
#          answers sent before a complete attach to the minted tickets
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=10900000-0000-4000-8000-000000000001; A=10900000-0000-4000-8000-0000000000a0
E=10900000-0000-4000-8000-0000000000e1; T=10900000-0000-4000-8000-0000000000d1
P1=10900000-0000-4000-8000-0000000000f1; P2=10900000-0000-4000-8000-0000000000f2
OUT=""
cleanup() {
  $P -c "DELETE FROM exos_question_answers WHERE event_id='$E';
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
         DELETE FROM auth.users WHERE id='$A';" >/dev/null
  if [ -n "$OUT" ]; then rm -rf "$OUT"; fi
}
cleanup; OUT="$(mktemp -d)"
trap cleanup EXIT
Q=$($P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-lo9.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race lo9','race-lo9','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-lo9','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
         ('$T','$E','GA',20,1,0,'public',1);
       INSERT INTO exos_tier_distribution(tier_id,event_id,org_id,enabled) VALUES ('$T','$E','$O',true);
       INSERT INTO exos_distribution_partners(id,org_id,label,partner_type,key_prefix,key_hash,scopes) VALUES
         ('$P1','$O','Race one','stubhub','dk_live_lo9race1',repeat('7a',32),ARRAY['inventory']),
         ('$P2','$O','Race two','vivid','dk_live_lo9race2',repeat('7b',32),ARRAY['inventory']);
       INSERT INTO exos_event_questions(org_id,event_id,label,kind,options,required,scope)
         VALUES ('$O','$E','Size','single_choice',ARRAY['S','M','L'],true,'ticket') RETURNING id;")
LINE="[{\"ticket_type_id\":\"$T\",\"quantity\":1}]"
ANS="{\"answers\":{\"tickets\":[{\"$Q\":\"L\"}]}}"
reserve() {
  echo "SELECT public._exos_partner_reserve('$O','$E','$1',NULL,'$LINE'::jsonb,'$2'::jsonb,false,false) ->> 'token';"
}

echo "race 1: two partners reserve the last seat at once, both with answers"
( $P -c "BEGIN; $(reserve $P1 "$ANS") SELECT pg_sleep(1.5); COMMIT;" >"$OUT/r1" 2>&1 || true ) &
sleep 0.3
( $P -c "BEGIN; $(reserve $P2 "$ANS") COMMIT;" >"$OUT/r2" 2>&1 || true ) &
wait
echo "  partner 1: $(tr '\n' ' ' <"$OUT/r1" | cut -c1-120)"
echo "  partner 2: $(tr '\n' ' ' <"$OUT/r2" | cut -c1-120)"
NRES=$($P -c "SELECT count(*) FROM exos_partner_reservations WHERE event_id='$E'")
NANS=$($P -c "SELECT count(*) FROM exos_question_answers WHERE event_id='$E'")
NREF=$($P -c "SELECT count(*) FROM exos_question_answers a JOIN exos_partner_reservations r ON a.order_ref = 'po:' || r.id WHERE r.event_id='$E'")
echo "  -> reservations=$NRES (expect 1), answers=$NANS (expect 1, the winner's: $NREF)"
[ "$NRES" = "1" ] && [ "$NANS" = "1" ] && [ "$NREF" = "1" ] || { echo "FAIL"; exit 1; }

echo "race 2: complete while the same reservation's answers arrive"
$P -c "DELETE FROM exos_question_answers WHERE event_id='$E'; DELETE FROM exos_question_answer_cursors WHERE event_id='$E';
       DELETE FROM exos_cart_holds WHERE event_id='$E'; DELETE FROM exos_partner_reservations WHERE event_id='$E';
       UPDATE exos_event_questions SET required = false WHERE event_id='$E';" >/dev/null
TOK=$($P -c "$(reserve $P1 '{}')")
( $P -c "BEGIN; SELECT public._exos_partner_reservation_complete('$O','$P1','$TOK',NULL,'https://exos.test') ->> 'status';
                SELECT pg_sleep(1.5); COMMIT;" >"$OUT/c" 2>&1 || true ) &
sleep 0.3
( $P -c "SELECT public._exos_partner_reservation_answers('$O','$P1','$TOK','{\"tickets\":[{\"$Q\":\"M\"}]}'::jsonb);" >"$OUT/a" 2>&1 || true ) &
wait
echo "  complete: $(tr '\n' ' ' <"$OUT/c" | cut -c1-120)"
echo "  answers:  $(tr '\n' ' ' <"$OUT/a" | cut -c1-120)"
LOOSE=$($P -c "SELECT count(*) FROM exos_question_answers WHERE event_id='$E' AND attached_at IS NULL")
DONE=$($P -c "SELECT status FROM exos_partner_reservations WHERE token='$TOK'")
echo "  -> reservation=$DONE (expect completed), stored=$(tr -d '\n' <"$OUT/a") (expect 0), unattached answers=$LOOSE (expect 0)"
[ "$DONE" = "completed" ] && [ "$(tr -d '\n' <"$OUT/a")" = "0" ] && [ "$LOOSE" = "0" ] || { echo "FAIL"; exit 1; }
echo "all races OK"
