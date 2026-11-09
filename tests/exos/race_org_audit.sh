#!/usr/bin/env bash
# Org audit log races (mig 20261109100000): concurrent actions in real
# parallel sessions each produce exactly one audit row. Timing-based, so run
# by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_org_audit.sh exos_p0_test
# Expect:
#   race 1 eight sessions decline the same refund ask: one wins, one
#          refund_ask.decline row
#   race 2 eight sessions add the same fee adjustment (one idempotency key):
#          one adjustment, one fee.adjust row
#   race 3 eight sessions claim the same refund (one nonce): one request, one
#          refund.issue row
#   race 4 eight sessions each change the same tier's price: eight
#          tier.update rows, one per new price, each [old, new] chaining on
#          the one before (the row lock orders them)
# The audit log is append-only, so each run uses fresh ids (its rows stay;
# the fixtures are removed).
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
RUN=$($P -c "SELECT substr(md5(random()::text || clock_timestamp()::text), 1, 8)")
id() { $P -c "SELECT md5('race-oa:$RUN:$1')::uuid"; }
O=$(id org); A=$(id owner); F=$(id fin); B=$(id buyer); E=$(id event); T=$(id tier); K=$(id ticket); ASK=$(id ask)
S="cs_race_oa_$RUN"
cleanup() {
  $P -c "DELETE FROM exos_refund_request_items WHERE request_id IN (SELECT id FROM exos_refund_requests WHERE session_id='$S');
         DELETE FROM exos_refund_requests WHERE session_id='$S';
         DELETE FROM exos_refund_asks WHERE id='$ASK';
         DELETE FROM exos_fee_adjustments WHERE session_id='$S';
         DELETE FROM exos_tickets WHERE id='$K';
         DELETE FROM exos_checkout_sessions WHERE session_id='$S';
         DELETE FROM exos_ticket_tiers WHERE id='$T'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$F','$B');" >/dev/null 2>&1 || true
}
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner-$RUN@race-oa.test',now()),('$F','fin-$RUN@race-oa.test',now()),('$B','buyer-$RUN@race-oa.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race OA','race-oa-$RUN','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner'),('$O','$F','finance');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,currency,created_by)
         VALUES ('$E','$O','Race OA','race-oa-$RUN','published',now()+interval '3 days',100,'usd','$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$T','$E','GA',40,100,0);
       INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,payment_intent,fulfilled_at)
         VALUES ('$S','$E','$T','$O','$B','buyer-$RUN@race-oa.test',2,8000,'usd','fulfilled','pi_race_oa_$RUN',now());
       INSERT INTO exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref)
         VALUES ('$K','$E','$O','$T','GA','$B','$B','buyer-$RUN@race-oa.test','active','race-oa-secret-$RUN',40,'$S');
       INSERT INTO exos_refund_asks(id,ticket_id,event_id,org_id,session_id,asked_by,reason,amount_cents,currency,status)
         VALUES ('$ASK','$K','$E','$O','$S','$B','Sick',4000,'usd','open');" >/dev/null
rows() { $P -c "SELECT count(*) FROM exos_org_audit WHERE org_id='$O' AND action='$1'"; }
fail=0
# Start N sessions together: each waits on the same advisory lock the parent
# holds, then runs its statement the moment the parent lets go.
parallel() {
  local sql="$1" n=8 pids=() i
  local holder
  $P -c "SELECT pg_advisory_lock(hashtext('race-oa-$RUN')); SELECT pg_sleep(1.5); SELECT pg_advisory_unlock(hashtext('race-oa-$RUN'));" >/dev/null &
  holder=$!
  sleep 0.3
  for i in $(seq 1 $n); do
    ( out=$($P -c "SELECT pg_advisory_lock_shared(hashtext('race-oa-$RUN')); SELECT pg_advisory_unlock_shared(hashtext('race-oa-$RUN')); ${sql//@I@/$i}" 2>&1 || true); : "$out" ) &
    pids+=($!)
  done
  wait "$holder"
  for p in "${pids[@]}"; do wait "$p" || true; done
}

# race 1: the same refund ask, declined eight times at once.
parallel "SELECT set_config('app.uid','$F',false); SELECT public.exos_decline_refund_ask('$ASK','race @I@');"
n=$(rows refund_ask.decline); st=$($P -c "SELECT status FROM exos_refund_asks WHERE id='$ASK'")
if [[ "$n" == 1 && "$st" == declined ]]; then echo "OK   race 1 eight declines: one row"; else echo "FAIL race 1: $n rows, status $st"; fail=1; fi

# race 2: one fee adjustment, sent eight times with one idempotency key.
parallel "SELECT public._exos_fee_adjustment_add('$O','$S',NULL,150,'Race waiver','$F',NULL,'race-oa-fee-$RUN');"
n=$(rows fee.adjust); adj=$($P -c "SELECT count(*) FROM exos_fee_adjustments WHERE session_id='$S'")
if [[ "$n" == 1 && "$adj" == 1 ]]; then echo "OK   race 2 eight resends of one adjustment: one adjustment, one row"; else echo "FAIL race 2: $n rows, $adj adjustments"; fail=1; fi

# race 3: one refund claim (one nonce), eight times.
parallel "SELECT public.exos_refund_claim('$F','$S','race-oa-nonce-$RUN',NULL,1000,false,'race',NULL);"
n=$(rows refund.issue); req=$($P -c "SELECT count(*) FROM exos_refund_requests WHERE session_id='$S'")
if [[ "$n" == 1 && "$req" == 1 ]]; then echo "OK   race 3 eight claims of one nonce: one request, one row"; else echo "FAIL race 3: $n rows, $req requests"; fail=1; fi

# race 4: eight price changes of one tier at once.
parallel "SELECT set_config('app.uid','$A',false); UPDATE exos_ticket_tiers SET price = 40 + @I@ WHERE id='$T';"
n=$(rows tier.update)
distinct=$($P -c "SELECT count(DISTINCT changes->'price'->>1) FROM exos_org_audit WHERE org_id='$O' AND action='tier.update'")
# Each row's old price is the previous row's new one (the first starts at 40).
chained=$($P -c "SELECT bool_and(old = coalesce(prev, '40')) FROM (
                   SELECT changes->'price'->>0 AS old, lag(changes->'price'->>1) OVER (ORDER BY id) AS prev
                     FROM exos_org_audit WHERE org_id='$O' AND action='tier.update') x")
if [[ "$n" == 8 && "$distinct" == 8 && "$chained" == t ]]; then echo "OK   race 4 eight concurrent price changes: eight rows, chained [old, new]"
else echo "FAIL race 4: $n rows, $distinct prices, chained $chained"; fail=1; fi
exit $fail
