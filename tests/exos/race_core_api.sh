#!/usr/bin/env bash
# Concurrency check for the partner API's Idempotency-Key (mig 20261031110000):
# two real sessions send the same write with the same key at once. Not in CI
# (timing-based); run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_core_api.sh exos_p0_test
# Expect: race 1 -> one comp batch (2 tickets), the twin replays it;
#         race 2 -> one refund request, the twin gets the same request back.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=7c000000-0000-0000-0000-000000000001; A=7c000000-0000-0000-0000-0000000000a1
E=7c000000-0000-0000-0000-0000000000e1; T=7c000000-0000-0000-0000-0000000000d1
K=7c000000-0000-0000-0000-0000000000f1; B=7c000000-0000-0000-0000-0000000000b1
cleanup() {
  $P -c "DELETE FROM exos_api_writes WHERE org_id='$O'; DELETE FROM exos_refund_requests WHERE org_id='$O';
         DELETE FROM exos_order_payments WHERE session_id='cs_race7c'; DELETE FROM exos_mail WHERE to_email LIKE 'race7c%';
         DELETE FROM exos_tickets WHERE org_id='$O'; DELETE FROM exos_checkout_sessions WHERE org_id='$O';
         DELETE FROM exos_api_keys WHERE org_id='$O'; DELETE FROM exos_ticket_tiers WHERE id='$T';
         DELETE FROM exos_events WHERE id='$E'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id IN ('$A','$B');" >/dev/null
}
cleanup
trap cleanup EXIT
# auth.uid() / auth.jwt() as Supabase defines them (the request's JWT claims,
# which exos_api_write sets), still honouring the harness's app.uid / app.jwt.
$P -c "CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS \$\$
         SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                         nullif(current_setting('request.jwt.claim.sub', true), ''),
                         nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid \$\$;
       CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS \$\$
         SELECT coalesce(nullif(current_setting('app.jwt', true), ''),
                         nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb \$\$;" >/dev/null
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','race7c-owner@x.com',now()), ('$B','race7c-buyer@x.com',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race 7c','race-7c','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_api_keys(id,org_id,name,key_prefix,key_hash,scopes,created_by)
         VALUES ('$K','$O','race','sk_live_race7c','race7chash',ARRAY['tickets:write','refunds:write'],'$A');
       INSERT INTO exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold)
         VALUES ('$E','$O','Race','published',now() + interval '3 days','Hall',100,1);
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$T','$E','GA',10,100,1);
       INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent)
         VALUES ('cs_race7c','$E','$T','$O','$B','race7c-buyer@x.com',1,1000,'fulfilled','pi_race7c');
       SELECT exos_record_payment('cs_race7c','pi_race7c',1000,'succeeded');" >/dev/null

COMP="SELECT exos_api_write('$K','comp.issue','$E','{\"tier_id\":\"$T\",\"emails\":[\"race7c-a@x.com\",\"race7c-b@x.com\"]}','race-comp-0001')"
echo "race 1: the same comp batch twice with one Idempotency-Key"
( $P -c "BEGIN; $COMP; SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5; $P -c "$COMP" | grep -o '"idempotent_replay": true' | sed 's/^/  twin: /'; wait
n=$($P -c "SELECT count(*) FROM exos_tickets WHERE event_id='$E'")
echo "  -> comp tickets: $n (want 2)"; [ "$n" = "2" ]

REFUND="SELECT exos_api_write('$K','refund.claim','cs_race7c','{\"whole_order\":true}','race-refund-0001') ->> 'request_id'"
echo "race 2: the same refund twice with one Idempotency-Key"
( $P -c "BEGIN; $REFUND; SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
sleep 0.5; $P -c "$REFUND" | sed 's/^/  twin got request /'; wait
n=$($P -c "SELECT count(*) FROM exos_refund_requests WHERE session_id='cs_race7c'")
echo "  -> refund requests: $n (want 1)"; [ "$n" = "1" ]
echo "race_core_api: ok"
