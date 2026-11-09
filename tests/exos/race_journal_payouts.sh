#!/usr/bin/env bash
# Journal payouts + gift card fee races (mig 20261111130000): real parallel
# sessions against a DB built by run_p0.sh (CI runs it after run_p0):
#   bash tests/exos/race_journal_payouts.sh exos_p0_test
# Expect:
#   race 1 eight sessions record the same paid Stripe payout at once (each
#          holds its transaction open): one row, one 'stripe_payout' entry
#   race 2 four sessions record it failed while four replay it as paid: it
#          ends failed, with exactly one reversal (the bank nets to zero)
#   race 3 an instant payout Exos sent learns its Stripe id while
#          exos-reconcile-stripe records the same payout, in both orders:
#          the bank gets the amount once
#   race 4 three refunds back to the gift card of an order with an owed Exos
#          fee, each posted by three sessions at once: one 'gc_refund_fee'
#          per refund row, and together exactly the owed fee
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=a7f30000-0000-0000-0000-000000000001; A=a7f30000-0000-0000-0000-0000000000a1
E=a7f30000-0000-0000-0000-0000000000e1; T=a7f30000-0000-0000-0000-0000000000d1
GC=a7f30000-0000-0000-0000-00000000c001
ACCT=acct_raceJp1
# The harness has no phase-1 exos_org_secrets (prod has it): made here when
# missing, and dropped again at the end only if this script made it.
MADE_SECRETS=0
if [[ "$($P -c "SELECT to_regclass('public.exos_org_secrets') IS NULL")" == t ]]; then
  $P -c "CREATE TABLE public.exos_org_secrets (org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now())" >/dev/null
  MADE_SECRETS=1
fi
cleanup() {
  # The journal is append-only: the cleanup runs with triggers off (replica).
  $P -c "SET session_replication_role = replica;
         DELETE FROM exos_journal_lines WHERE org_id='$O'; DELETE FROM exos_journal_entries WHERE org_id='$O';
         DELETE FROM exos_stripe_org_payouts WHERE org_id='$O'; DELETE FROM exos_org_instant_payouts WHERE org_id='$O';
         DELETE FROM exos_gift_card_redemptions WHERE org_id='$O'; DELETE FROM exos_gift_card_ledger WHERE org_id='$O';
         DELETE FROM exos_gift_cards WHERE org_id='$O'; DELETE FROM exos_org_audit WHERE org_id='$O';" >/dev/null
  $P -c "DELETE FROM exos_checkout_sessions WHERE org_id='$O'; DELETE FROM exos_org_secrets WHERE org_id='$O';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
finish() {
  cleanup
  if [[ "$MADE_SECRETS" == 1 ]]; then $P -c "DROP TABLE IF EXISTS public.exos_org_secrets" >/dev/null; fi
}
cleanup
trap finish EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-jp.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race JP','race-jp','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner') ON CONFLICT DO NOTHING;
       INSERT INTO exos_org_secrets(org_id,payments) VALUES ('$O','{\"connectedAccountId\":\"$ACCT\"}');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,currency,created_by)
         VALUES ('$E','$O','Race JP Night','race-jp-night','published',now()+interval '1 day',100,'usd','$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity) VALUES ('$T','$E','GA',40,100);" >/dev/null

entries() { $P -c "SELECT count(*) FROM exos_journal_entries WHERE source_id='$1' AND (kind='$2' OR kind LIKE '$2:%')"; }
bank() { $P -c "SELECT coalesce(sum(l.debit_cents - l.credit_cents),0) FROM exos_journal_lines l WHERE l.org_id='$O' AND l.account='bank'"; }
balanced() {
  $P -c "SELECT count(*) FROM (SELECT e.id FROM exos_journal_entries e JOIN exos_journal_lines l ON l.entry_id=e.id
          WHERE e.org_id='$O' GROUP BY e.id HAVING sum(l.debit_cents) <> sum(l.credit_cents)) x"
}
payout() {   # id status amount method
  echo "[{\"id\":\"$1\",\"amount\":$3,\"currency\":\"usd\",\"status\":\"$2\",\"method\":\"$4\",\"created\":\"2026-11-01T00:00:00Z\"}]"
}
record() { echo "SELECT public.exos_stripe_org_payouts_record('$O','$ACCT','$(payout "$1" "$2" "$3" "${4:-standard}")'::jsonb);"; }
fail=0

# race 1: eight sessions record one paid payout at once.
pids=()
for i in 1 2 3 4 5 6 7 8; do
  $P -c "BEGIN; $(record po_raceJp1 paid 12000) SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
rows=$($P -c "SELECT count(*) FROM exos_stripe_org_payouts WHERE payout_id='po_raceJp1'")
if [[ "$rows" == 1 && "$(entries po_raceJp1 stripe_payout)" == 1 && "$(bank)" == 12000 && "$(balanced)" == 0 ]]; then
  echo "OK   race 1 eight parallel records of one paid payout: one row, one stripe_payout entry"
else
  echo "FAIL race 1: $rows rows, $(entries po_raceJp1 stripe_payout) entries, bank $(bank)"; fail=1
fi

# race 2: failed (4 sessions) against a stale paid (4 sessions), at once.
pids=()
for s in failed paid failed paid failed paid failed paid; do
  $P -c "BEGIN; $(record po_raceJp1 $s 12000) SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
st=$($P -c "SELECT status FROM exos_stripe_org_payouts WHERE payout_id='po_raceJp1'")
if [[ "$st" == failed && "$(entries po_raceJp1 stripe_payout_reversal)" == 1 && "$(bank)" == 0 && "$(balanced)" == 0 ]]; then
  echo "OK   race 2 failed vs stale paid in parallel: failed, one reversal, the bank nets to zero"
else
  echo "FAIL race 2: status $st, $(entries po_raceJp1 stripe_payout_reversal) reversals, bank $(bank)"; fail=1
fi

# race 3: the instant payout learns its Stripe id while the same payout is recorded (both orders).
n=0
for order in instant_first stripe_first; do
  n=$((n + 1))
  IP=a7f30000-0000-0000-0000-00000000f00$n; PO=po_raceJpInst$n
  $P -c "INSERT INTO exos_org_instant_payouts (id,org_id,currency,amount_cents,fee_estimate_cents,idempotency_key,requested_by)
         VALUES ('$IP','$O','usd',3000,45,'race-jp-instant-000$n','$A');" >/dev/null
  before=$(bank)
  upd="BEGIN; UPDATE exos_org_instant_payouts SET status='sent', stripe_payout_id='$PO' WHERE id='$IP'; SELECT pg_sleep(0.4); COMMIT;"
  rec="BEGIN; $(record "$PO" paid 3000 instant) SELECT pg_sleep(0.4); COMMIT;"
  if [[ "$order" == instant_first ]]; then first=$upd; second=$rec; else first=$rec; second=$upd; fi
  $P -c "$first" >/dev/null 2>&1 &
  p1=$!
  sleep 0.1
  $P -c "$second" >/dev/null 2>&1 &
  p2=$!
  wait "$p1" || true; wait "$p2" || true
  got=$(( $(bank) - before ))
  if [[ "$got" == 3000 && "$(balanced)" == 0 ]]; then
    echo "OK   race 3 ($order) an instant payout and Stripe's row of it at once: 3000 in the bank, once"
  else
    echo "FAIL race 3 ($order): the bank moved $got (instant $(entries "$IP" stripe_payout), stripe $(entries "$PO" stripe_payout))"; fail=1
  fi
done

# race 4: three refunds back to the card of one order ($20.00 card part, $0.61 owed), each posted by three sessions.
$P -c "SET session_replication_role = replica;
       INSERT INTO exos_gift_cards (id,org_id,code_hash,last4,currency,initial_cents,balance_cents,source,payment_method)
         VALUES ('$GC','$O',repeat('d4',32),'RJ04','usd',5000,5000,'box_office','cash');
       INSERT INTO exos_checkout_sessions (session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,
                   tax_cents,application_fee_cents,exos_fee_cents,card_fee_est_cents,gift_card_cents,exos_fee_owed_cents,fulfilled_at)
         VALUES ('cs_race_jp_4','$E','$T','$O','$A','owner@race-jp.test',1,3000,'usd','fulfilled',400,210,90,120,2000,61,now());
       INSERT INTO exos_gift_card_redemptions (session_id,card_id,org_id,amount_cents,refunded_cents,status)
         VALUES ('cs_race_jp_4','$GC','$O',2000,2000,'captured');
       INSERT INTO exos_gift_card_ledger (card_id,org_id,kind,amount_cents,balance_after,session_id,key) VALUES
         ('$GC','$O','refund',700,3700,'cs_race_jp_4','cs_race_jp_4:a'),
         ('$GC','$O','refund',700,4400,'cs_race_jp_4','cs_race_jp_4:b'),
         ('$GC','$O','refund',600,5000,'cs_race_jp_4','cs_race_jp_4:c');" >/dev/null
$P -c "SELECT public.exos_journal_post_order('cs_race_jp_4');" >/dev/null
LA=$($P -c "SELECT id FROM exos_gift_card_ledger WHERE key='cs_race_jp_4:a'")
LB=$($P -c "SELECT id FROM exos_gift_card_ledger WHERE key='cs_race_jp_4:b'")
LC=$($P -c "SELECT id FROM exos_gift_card_ledger WHERE key='cs_race_jp_4:c'")
pids=()
for L in "$LC" "$LA" "$LB" "$LB" "$LC" "$LA" "$LA" "$LB" "$LC"; do
  $P -c "BEGIN; SELECT public.exos_journal_post_gift_card($L); SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
fee=$($P -c "SELECT coalesce(sum(l.debit_cents - l.credit_cents),0) FROM exos_journal_lines l JOIN exos_journal_entries e ON e.id=l.entry_id
             WHERE e.org_id='$O' AND l.account='organizer_payable' AND e.session_id='cs_race_jp_4'")
each="$(entries "$LA" gc_refund_fee)/$(entries "$LB" gc_refund_fee)/$(entries "$LC" gc_refund_fee)"
# The sale owes 61 (Cr payable); the three shares hand back 21 + 22 + 18 = 61: the payable nets to zero.
if [[ "$each" == 1/1/1 && "$fee" == 0 && "$(balanced)" == 0 ]]; then
  echo "OK   race 4 three refunds to one gift card posted in parallel: one fee share each, together the whole owed fee"
else
  echo "FAIL race 4: fee entries $each, payable left $fee"; fail=1
fi
exit $fail
