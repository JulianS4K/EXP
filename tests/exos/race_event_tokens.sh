#!/usr/bin/env bash
# Event token races (mig 20261114110000): real parallel sessions spending one
# code. Run against a DB built by run_p0.sh (CI runs it after run_p0.sh):
#   bash tests/exos/race_event_tokens.sh exos_p0_test
# Expect:
#   race 1 a spend of 2 is held open (uncommitted) on a code with 5 credits
#          while six sessions spend 1 each: exactly 3 of the six get one, the
#          rest are refused 'insufficient'; the balance ends at 0, never below
#   race 2 the same spend (one client ref) sent by four sessions at once:
#          one ledger row, one deduction
#   race 3 a void of the sale is held open while three sessions spend the
#          code: either the void wins (no spend) or a spend wins (the void is
#          refused): never both, and the balance is never negative
#   race 4 offline replays of two devices (6 + 6 from a balance of 9) at the
#          same time: 9 taken, 3 recorded as one 'overspent' exception
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=e7ace000-0000-0000-0000-000000000001; A=e7ace000-0000-0000-0000-0000000000a1
S=e7ace000-0000-0000-0000-0000000000a3; E=e7ace000-0000-0000-0000-0000000000e1
D=e7ace000-0000-0000-0000-000000000081
cleanup() {
  # The journal and the token ledger are append-only: triggers off (replica).
  $P -c "SET session_replication_role = replica;
         DELETE FROM exos_journal_lines WHERE org_id='$O'; DELETE FROM exos_journal_entries WHERE org_id='$O';
         DELETE FROM exos_event_token_exceptions WHERE org_id='$O'; DELETE FROM exos_event_token_ledger WHERE org_id='$O';
         DELETE FROM exos_event_token_lots WHERE org_id='$O'; DELETE FROM exos_event_token_cards WHERE org_id='$O';
         DELETE FROM exos_pos_paid_outs WHERE org_id='$O'; DELETE FROM exos_pos_reversals WHERE org_id='$O';
         DELETE FROM exos_pos_payments WHERE org_id='$O'; DELETE FROM exos_pos_order_lines WHERE org_id='$O';
         DELETE FROM exos_pos_orders WHERE org_id='$O'; DELETE FROM exos_pos_items WHERE org_id='$O';
         DELETE FROM exos_pos_drawer_sessions WHERE org_id='$O'; DELETE FROM exos_event_addons WHERE event_id='$E';
         DELETE FROM exos_event_token_products WHERE org_id='$O'; DELETE FROM exos_org_audit WHERE org_id='$O';" >/dev/null
  $P -c "DELETE FROM exos_events WHERE id='$E'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id IN ('$A','$S');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-tok.test',now()), ('$S','scanner@race-tok.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race Tokens','race-tok','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner'), ('$O','$S','scanner') ON CONFLICT DO NOTHING;
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,ends_at,total_tickets,currency,created_by)
         VALUES ('$E','$O','Race Token Night','race-tok-night','published',now()+interval '1 hour',now()+interval '6 hours',100,'usd','$A');" >/dev/null
PROD=$($P -c "SELECT set_config('app.uid','$A',false);
              SELECT public.exos_event_token_product_save('$E', '{\"name\":\"Drink token\",\"price_cents\":500,\"max_per_order\":50}') ->> 'id';" | tail -1)
$P -c "SELECT set_config('app.uid','$S',false);
       INSERT INTO exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES ('$D','$E',10000);" >/dev/null
# A new code with n credits, sold for cash by the scanner. Prints "code order".
sell() {
  $P -c "SELECT set_config('app.uid','$S',false);
         SELECT (r ->> 'code') || ' ' || (r ->> 'order_id')
           FROM (SELECT public.exos_event_token_pos_sell('$E','$PROD',1,$1,'cash',gen_random_uuid()) AS r) x;" | tail -1
}
SPEND="SELECT set_config('app.uid','$S',false);"
balance() {
  $P -c "SELECT public._exos_event_token_balance(c.id, '$PROD') FROM exos_event_token_cards c
          WHERE c.code_hash = public._exos_event_token_hash(public._exos_event_token_code('$1'))"
}
negative() { $P -c "SELECT count(*) FROM exos_event_token_lots WHERE org_id='$O' AND credits_left < 0"; }
fail=0

# race 1: a spend of 2 held open; six spends of 1 meanwhile.
read -r CODE ORDER <<<"$(sell 5)"
$P -c "BEGIN; $SPEND SELECT public.exos_event_token_spend('$E','$CODE','$PROD',2,gen_random_uuid()); SELECT pg_sleep(2); COMMIT;" >/dev/null &

sleep 0.5
outs=()
for i in 1 2 3 4 5 6; do
  out=$(mktemp); outs+=("$out")
  $P -c "$SPEND SELECT public.exos_event_token_spend('$E','$CODE','$PROD',1,gen_random_uuid()) ->> 'reason';" >"$out" 2>&1 &
done
wait
ok=0; refused=0
for out in "${outs[@]}"; do
  r=$(tail -1 "$out"); rm -f "$out"
  case "$r" in spent) ok=$((ok + 1));; insufficient) refused=$((refused + 1));; esac
done
if [[ "$ok" == 3 && "$refused" == 3 && "$(balance "$CODE")" == 0 && "$(negative)" == 0 ]]; then
  echo "OK   race 1 six spends while a spend of 2 is uncommitted (5 credits): 3 spent, 3 refused, balance 0"
else
  echo "FAIL race 1: $ok spent, $refused refused, balance $(balance "$CODE"), negative lots $(negative)"; fail=1
fi

# race 2: one client ref from four sessions at once.
read -r CODE ORDER <<<"$(sell 5)"
REF=$($P -c "SELECT gen_random_uuid()")
for i in 1 2 3 4; do
  $P -c "BEGIN; $SPEND SELECT public.exos_event_token_spend('$E','$CODE','$PROD',2,'$REF'); SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
done
wait
rows=$($P -c "SELECT count(*) FROM exos_event_token_ledger WHERE client_ref='$REF'")
if [[ "$rows" == 1 && "$(balance "$CODE")" == 3 ]]; then
  echo "OK   race 2 one client ref from four sessions: one ledger row, balance 3"
else
  echo "FAIL race 2: $rows rows, balance $(balance "$CODE")"; fail=1
fi

# race 3: the sale's void held open while three sessions spend.
read -r CODE ORDER <<<"$(sell 3)"
vout=$(mktemp)
$P -c "BEGIN; SELECT set_config('app.uid','$S',false); SELECT public.exos_pos_void_order('$ORDER','race void') ->> 'status';
       SELECT pg_sleep(1.5); COMMIT;" >"$vout" 2>&1 &
vpid=$!
sleep 0.4
souts=()
for i in 1 2 3; do
  out=$(mktemp); souts+=("$out")
  $P -c "$SPEND SELECT public.exos_event_token_spend('$E','$CODE','$PROD',1,gen_random_uuid()) ->> 'reason';" >"$out" 2>&1 &
done
wait
spent=0
for out in "${souts[@]}"; do
  [[ "$(tail -1 "$out")" == spent ]] && spent=$((spent + 1)); rm -f "$out"
done
vres=$(cat "$vout"); rm -f "$vout"
status=$($P -c "SELECT status FROM exos_pos_orders WHERE id='$ORDER'")
if { [[ "$status" == void && "$spent" == 0 && "$(balance "$CODE")" == 0 ]] \
     || [[ "$status" == paid && "$spent" -ge 1 && "$vres" == *tokens* ]]; } && [[ "$(negative)" == 0 ]]; then
  echo "OK   race 3 a void and three spends at once: status $status, $spent spent, never both"
else
  echo "FAIL race 3: status $status, $spent spent, void said: $vres"; fail=1
fi

# race 4: two devices' offline replays at once (6 + 6 from 9).
read -r CODE ORDER <<<"$(sell 9)"
AT=$($P -c "SELECT (clock_timestamp() - interval '5 minutes')::text")
for dev in bar-1 bar-2; do
  $P -c "BEGIN; $SPEND SELECT public.exos_event_token_spend('$E','$CODE','$PROD',6,gen_random_uuid(),'$AT','$dev');
         SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
done
wait
taken=$($P -c "SELECT -sum(credits) FROM exos_event_token_ledger g JOIN exos_event_token_cards c ON c.id = g.card_id
                WHERE g.kind='spend' AND c.code_hash = public._exos_event_token_hash(public._exos_event_token_code('$CODE'))")
short=$($P -c "SELECT coalesce(sum(credits_short), 0) || '/' || count(*) FROM exos_event_token_exceptions x JOIN exos_event_token_cards c ON c.id = x.card_id
                WHERE c.code_hash = public._exos_event_token_hash(public._exos_event_token_code('$CODE'))")
if [[ "$taken" == 9 && "$short" == "3/1" && "$(balance "$CODE")" == 0 && "$(negative)" == 0 ]]; then
  echo "OK   race 4 two offline replays at once: 9 taken, one overspent exception of 3, balance 0"
else
  echo "FAIL race 4: taken $taken, short $short, balance $(balance "$CODE")"; fail=1
fi
exit $fail
