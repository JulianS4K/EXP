#!/usr/bin/env bash
# Races for the mistake-sim decisions (mig 20261105100000): real parallel
# sessions. Timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_sim_decisions.sh exos_p0_test
# Expect:
#   race 1 the same comp batch twice at once, no request key: one batch issued,
#          the second returns the first's result (the advisory lock + 10-minute window)
#   race 2 the same request key twice at once: one batch
#   race 3 the right proof code from two tabs at once: released once (one wallet
#          mail, the tickets moved once)
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=bd100000-0000-0000-0000-000000000001; A=bd100000-0000-0000-0000-0000000000a0; B=bd100000-0000-0000-0000-0000000000b1
E=bd100000-0000-0000-0000-0000000000e1; T=bd100000-0000-0000-0000-0000000000d1
as() { echo "SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false);"; }
cleanup() {
  $P -c "DELETE FROM exos_mail WHERE to_email LIKE '%@race-dec.test';
         DELETE FROM exos_comp_batch_requests WHERE event_id='$E';
         DELETE FROM exos_order_proofs WHERE event_id='$E';
         UPDATE exos_tickets SET pending_transfer_id = NULL WHERE event_id='$E';
         DELETE FROM exos_transfers WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_checkout_sessions WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$B');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-dec.test',now()),('$B','buyer@race-dec.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race decisions','race-dec','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-dec','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES ('$T','$E','GA',20,100,0,'public');" >/dev/null

batch() { echo "SELECT count(*) FROM public.exos_issue_comp_batch('$E','$T',ARRAY['c1@race-dec.test','c2@race-dec.test'],1,NULL$1);"; }

echo "race 1: the same comp batch twice at once (no request key)"
( $P -c "$(as $A owner@race-dec.test) BEGIN; $(batch '') SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
$P -c "$(as $A owner@race-dec.test) $(batch '')" >/dev/null
wait
N=$($P -c "SELECT count(*) FROM exos_tickets WHERE event_id='$E'")
echo "  -> tickets=$N (expect 2)"
[ "$N" = "2" ] || { echo "FAIL"; exit 1; }

echo "race 2: the same request key twice at once"
( $P -c "$(as $A owner@race-dec.test) BEGIN; $(batch ",'race-key-0001'" | sed 's/c1@/k1@/; s/c2@/k2@/') SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5
$P -c "$(as $A owner@race-dec.test) $(batch ",'race-key-0001'" | sed 's/c1@/k1@/; s/c2@/k2@/')" >/dev/null
wait
N=$($P -c "SELECT count(*) FROM exos_tickets WHERE event_id='$E'")
echo "  -> tickets=$N (expect 4)"
[ "$N" = "4" ] || { echo "FAIL"; exit 1; }

echo "race 3: the right proof code from two tabs at once"
$P -c "INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,guest,quantity,amount_cents,currency,status,proof_token_hash)
         VALUES ('cs_rdec_3','$E','$T','$O',NULL,'buyer@race-dec.test',true,2,4000,'usd','pending',
                 encode(extensions.digest('tok-rdec-3-0123456789abcdef','sha256'),'hex'));
       SELECT public.exos_fulfill_checkout('cs_rdec_3');" >/dev/null
CODE=$($P -c "SELECT substring(html from 'letter-spacing:6px\"><strong>([0-9]{6})</strong>') FROM exos_mail WHERE to_email='buyer@race-dec.test' AND template='rsvp-code' LIMIT 1")
V="SELECT public.exos_order_proof_verify('cs_rdec_3','tok-rdec-3-0123456789abcdef','$CODE') ->> 'ok'"
( $P -c "BEGIN; $V; SELECT pg_sleep(2); COMMIT;" | sed 's/^/  tab 1 ok=/' | head -1 ) &
sleep 0.5
$P -c "$V" | sed 's/^/  tab 2 ok=/'
wait
OWN=$($P -c "SELECT count(*) FROM exos_tickets WHERE order_ref='cs_rdec_3' AND owner_id='$B'")
M=$($P -c "SELECT count(*) FROM exos_mail WHERE to_email='buyer@race-dec.test' AND template='ticket-issued'")
echo "  -> tickets in the buyer's wallet=$OWN wallet mails=$M (expect 2 1)"
[ "$OWN" = "2" ] && [ "$M" = "1" ] || { echo "FAIL"; exit 1; }
echo "all races OK"
