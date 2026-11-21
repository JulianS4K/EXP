#!/usr/bin/env bash
# Money journal races (mig 20261108100000): the same source posted from real
# parallel sessions. Timing-based, so run by hand against a DB built by
# run_p0.sh:
#   bash tests/exos/race_money_journal.sh exos_p0_test
# Expect:
#   race 1 eight sessions post the same paid order at once (each holds its
#          transaction open): exactly one 'sale' entry, balanced
#   race 2 six sessions post the same refund at once: exactly one 'refund'
#          entry
#   race 3 two different partial refunds of one order posted at once: one
#          entry each, and together they leave exactly the settlement's net
#          after refunds at Stripe (the cumulative split is serialized)
#   race 4 the order's own status change and a backfill at the same time:
#          still one 'sale' entry
#   race 5 (mig 20261110100000) eight sessions post the same POS card tender
#          at once, then six its card refund: one 'pos_card_sale', one
#          'pos_card_refund', and the two net to zero at Stripe
#   race 6 eight sessions post the same gift card redemption (a partner
#          reservation) at once: one 'gc_redeem'
#   race 7 two refunds back to the same gift card of one order, each posted
#          by three sessions at once: one 'gc_refund' each, and their tax
#          shares never add up to more than the order's tax
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=a7f20000-0000-0000-0000-000000000001; A=a7f20000-0000-0000-0000-0000000000a1
E=a7f20000-0000-0000-0000-0000000000e1; T=a7f20000-0000-0000-0000-0000000000d1
cleanup() {
  # The journal is append-only: the cleanup runs with triggers off (replica).
  $P -c "SET session_replication_role = replica;
         DELETE FROM exos_journal_lines WHERE org_id='$O'; DELETE FROM exos_journal_entries WHERE org_id='$O';" >/dev/null
  $P -c "SET session_replication_role = replica;
         DELETE FROM exos_pos_reversals WHERE org_id='$O'; DELETE FROM exos_pos_card_payments WHERE org_id='$O';
         DELETE FROM exos_pos_payments WHERE org_id='$O'; DELETE FROM exos_pos_orders WHERE org_id='$O';
         DELETE FROM exos_gift_card_redemptions WHERE org_id='$O'; DELETE FROM exos_gift_card_ledger WHERE org_id='$O';
         DELETE FROM exos_gift_cards WHERE org_id='$O'; DELETE FROM exos_partner_reservations WHERE org_id='$O';" >/dev/null
  $P -c "DELETE FROM exos_order_refunds WHERE org_id='$O'; DELETE FROM exos_checkout_sessions WHERE org_id='$O';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E'; DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-mj.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race MJ','race-mj','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner') ON CONFLICT DO NOTHING;
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,currency,created_by)
         VALUES ('$E','$O','Race MJ Night','race-mj-night','published',now()+interval '1 day',100,'usd','$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity) VALUES ('$T','$E','GA',40,100);" >/dev/null

# A paid order the triggers haven't posted (written with triggers off).
paid_order() {
  $P -c "SET session_replication_role = replica;
         INSERT INTO exos_checkout_sessions (session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,
                     tax_cents,application_fee_cents,exos_fee_cents,card_fee_est_cents,fulfilled_at)
         VALUES ('$1','$E','$T','$O','$A','owner@race-mj.test',2,10000,'usd','fulfilled',800,566,300,266,now());" >/dev/null
}
entries() { $P -c "SELECT count(*) FROM exos_journal_entries WHERE source_id='$1' AND (kind='$2' OR kind LIKE '$2:%')"; }
balanced() {
  $P -c "SELECT count(*) FROM (SELECT e.id FROM exos_journal_entries e JOIN exos_journal_lines l ON l.entry_id=e.id
          WHERE e.org_id='$O' GROUP BY e.id HAVING sum(l.debit_cents) <> sum(l.credit_cents)) x"
}
fail=0

# race 1: eight posts of one order at once.
paid_order cs_race_mj_1
pids=()
for i in 1 2 3 4 5 6 7 8; do
  $P -c "BEGIN; SELECT public.exos_journal_post_order('cs_race_mj_1'); SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
n=$(entries cs_race_mj_1 sale)
if [[ "$n" == 1 && "$(balanced)" == 0 ]]; then
  echo "OK   race 1 eight parallel posts of one order: one sale entry, balanced"
else
  echo "FAIL race 1: $n sale entries, $(balanced) unbalanced"; fail=1
fi

# race 2: six posts of one refund at once.
R2=a7f20000-0000-0000-0000-00000000f002
$P -c "SET session_replication_role = replica;
       INSERT INTO exos_order_refunds (id,session_id,org_id,provider,refund_id,amount_cents,currency,status)
       VALUES ('$R2','cs_race_mj_1','$O','stripe','re_race_mj_2',2500,'usd','succeeded');" >/dev/null
pids=()
for i in 1 2 3 4 5 6; do
  $P -c "BEGIN; SELECT public.exos_journal_post_refund('$R2'); SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
n=$(entries "$R2" refund)
if [[ "$n" == 1 ]]; then
  echo "OK   race 2 six parallel posts of one refund: one refund entry"
else
  echo "FAIL race 2: $n refund entries"; fail=1
fi

# race 3: two different partial refunds of a fresh order at once.
paid_order cs_race_mj_3
$P -c "SELECT public.exos_journal_post_order('cs_race_mj_3');" >/dev/null
R3A=a7f20000-0000-0000-0000-00000000f03a; R3B=a7f20000-0000-0000-0000-00000000f03b
$P -c "SET session_replication_role = replica;
       INSERT INTO exos_order_refunds (id,session_id,org_id,provider,refund_id,amount_cents,currency,status) VALUES
         ('$R3A','cs_race_mj_3','$O','stripe','re_race_mj_3a',3333,'usd','succeeded'),
         ('$R3B','cs_race_mj_3','$O','stripe','re_race_mj_3b',3333,'usd','succeeded');" >/dev/null
$P -c "BEGIN; SELECT public.exos_journal_post_refund('$R3A'); SELECT pg_sleep(0.5); COMMIT;" >/dev/null 2>&1 &
pa=$!
$P -c "BEGIN; SELECT public.exos_journal_post_refund('$R3B'); SELECT pg_sleep(0.5); COMMIT;" >/dev/null 2>&1 &
pb=$!
wait "$pa" || true; wait "$pb" || true
# settlement.ts: net 9434 − round(9434 × 6666 / 10000) = 3145.
left=$($P -c "SELECT coalesce(sum(l.debit_cents - l.credit_cents),0) FROM exos_journal_lines l JOIN exos_journal_entries e ON e.id=l.entry_id
              WHERE e.org_id='$O' AND l.account='stripe_clearing' AND (e.source_id='cs_race_mj_3' OR e.session_id='cs_race_mj_3')")
want=$($P -c "SELECT 9434 - round(9434 * 6666 / 10000.0)::int")
if [[ "$(entries "$R3A" refund)" == 1 && "$(entries "$R3B" refund)" == 1 && "$left" == "$want" && "$(balanced)" == 0 ]]; then
  echo "OK   race 3 two partial refunds at once: one entry each, $left left at Stripe (= the settlement)"
else
  echo "FAIL race 3: entries $(entries "$R3A" refund)/$(entries "$R3B" refund), left $left (want $want)"; fail=1
fi

# race 4: the status change (trigger) and a backfill at the same time.
$P -c "INSERT INTO exos_checkout_sessions (session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,
                   application_fee_cents,exos_fee_cents,card_fee_est_cents)
       VALUES ('cs_race_mj_4','$E','$T','$O','$A','owner@race-mj.test',1,4000,'usd','pending',276,120,156);" >/dev/null
$P -c "BEGIN; UPDATE exos_checkout_sessions SET status='fulfilled', fulfilled_at=now() WHERE session_id='cs_race_mj_4';
       SELECT pg_sleep(0.5); COMMIT;" >/dev/null 2>&1 &
pa=$!
sleep 0.1
$P -c "SELECT public._exos_journal_backfill('$O');" >/dev/null 2>&1 &
pb=$!
wait "$pa" || true; wait "$pb" || true
$P -c "SELECT public._exos_journal_backfill('$O');" >/dev/null
n=$(entries cs_race_mj_4 sale)
if [[ "$n" == 1 && "$(balanced)" == 0 ]]; then
  echo "OK   race 4 the order's own trigger and a backfill at once: one sale entry"
else
  echo "FAIL race 4: $n sale entries"; fail=1
fi

# race 5: a POS card tender, then its card refund, each posted by many sessions at once.
PO=a7f20000-0000-0000-0000-00000000c005; PP=a7f20000-0000-0000-0000-00000000c105; PR=a7f20000-0000-0000-0000-00000000c205
$P -c "SET session_replication_role = replica;
       INSERT INTO exos_pos_orders (id,org_id,event_id,status,subtotal_cents,tax_cents,total_cents,currency,paid_at)
         VALUES ('$PO','$O','$E','paid',4000,355,4355,'usd',now());
       INSERT INTO exos_pos_card_payments (org_id,event_id,order_id,payment_intent_id,amount_cents,currency,
                                           application_fee_cents,exos_fee_cents,card_fee_est_cents,status)
         VALUES ('$O','$E','$PO','pi_raceMj5',4355,'usd',300,120,180,'succeeded');
       INSERT INTO exos_pos_payments (id,order_id,org_id,event_id,method,amount_cents,terminal_ref)
         VALUES ('$PP','$PO','$O','$E','card',4355,'pi_raceMj5');" >/dev/null
pids=()
for i in 1 2 3 4 5 6 7 8; do
  $P -c "BEGIN; SELECT public.exos_journal_post_pos_payment('$PP'); SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
$P -c "SET session_replication_role = replica;
       INSERT INTO exos_pos_reversals (id,org_id,event_id,order_id,kind,total_cents,card_cents,reason,card_payment_intent,
                                       card_refund_ref,card_refund_status)
         VALUES ('$PR','$O','$E','$PO','refund',4355,4355,'race refund','pi_raceMj5','re_raceMj5','succeeded');" >/dev/null
pids=()
for i in 1 2 3 4 5 6; do
  $P -c "BEGIN; SELECT public.exos_journal_post_pos_reversal('$PR'); SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
net=$($P -c "SELECT coalesce(sum(l.debit_cents - l.credit_cents),0) FROM exos_journal_lines l JOIN exos_journal_entries e ON e.id=l.entry_id
             WHERE e.org_id='$O' AND l.account='stripe_clearing' AND e.source_id IN ('$PP','$PR')")
if [[ "$(entries "$PP" pos_card_sale)" == 1 && "$(entries "$PR" pos_card_refund)" == 1 && "$net" == 0 && "$(balanced)" == 0 ]]; then
  echo "OK   race 5 parallel posts of one card tender and of its refund: one entry each, net zero at Stripe"
else
  echo "FAIL race 5: sale $(entries "$PP" pos_card_sale), refund $(entries "$PR" pos_card_refund), net $net"; fail=1
fi

# race 6: one gift card redemption on a completed partner reservation, posted by eight sessions.
GC=a7f20000-0000-0000-0000-00000000c006; RS=a7f20000-0000-0000-0000-00000000c106
$P -c "SET session_replication_role = replica;
       INSERT INTO exos_gift_cards (id,org_id,code_hash,last4,currency,initial_cents,balance_cents,source,payment_method)
         VALUES ('$GC','$O',repeat('c6',32),'RC06','usd',5000,3000,'box_office','cash');
       INSERT INTO exos_partner_reservations (id,token,org_id,event_id,channel,channel_source,status,expires_at,lines,quantity,completed_at)
         VALUES ('$RS','rsv_'||rpad('racemj6',43,'x'),'$O','$E','partner','partner:race','completed',now()+interval '1 hour','[]',1,now());
       INSERT INTO exos_gift_card_redemptions (session_id,card_id,org_id,amount_cents,status,partner_reservation_id)
         VALUES ('res_race_mj_6','$GC','$O',2000,'captured','$RS');" >/dev/null
pids=()
for i in 1 2 3 4 5 6 7 8; do
  $P -c "BEGIN; SELECT public.exos_journal_post_gift_card_redemption('res_race_mj_6'); SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
if [[ "$(entries res_race_mj_6 gc_redeem)" == 1 && "$(balanced)" == 0 ]]; then
  echo "OK   race 6 eight parallel posts of one gift card redemption: one gc_redeem entry"
else
  echo "FAIL race 6: $(entries res_race_mj_6 gc_redeem) gc_redeem entries"; fail=1
fi

# race 7: two refunds back to the card of one order ($30.00 card + $20.00 gift card,
# $4.00 tax), each posted by three sessions at once.
$P -c "SET session_replication_role = replica;
       INSERT INTO exos_checkout_sessions (session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,
                   tax_cents,application_fee_cents,exos_fee_cents,card_fee_est_cents,gift_card_cents,fulfilled_at)
         VALUES ('cs_race_mj_7','$E','$T','$O','$A','owner@race-mj.test',1,3000,'usd','fulfilled',400,210,90,120,2000,now());
       INSERT INTO exos_gift_card_redemptions (session_id,card_id,org_id,amount_cents,refunded_cents,status)
         VALUES ('cs_race_mj_7','$GC','$O',2000,2000,'captured');
       INSERT INTO exos_gift_card_ledger (card_id,org_id,kind,amount_cents,balance_after,session_id,key) VALUES
         ('$GC','$O','refund',1000,4000,'cs_race_mj_7','cs_race_mj_7:a'),
         ('$GC','$O','refund',1000,5000,'cs_race_mj_7','cs_race_mj_7:b');" >/dev/null
$P -c "SELECT public.exos_journal_post_order('cs_race_mj_7');" >/dev/null
L7A=$($P -c "SELECT id FROM exos_gift_card_ledger WHERE key='cs_race_mj_7:a'")
L7B=$($P -c "SELECT id FROM exos_gift_card_ledger WHERE key='cs_race_mj_7:b'")
pids=()
for L in "$L7A" "$L7B" "$L7A" "$L7B" "$L7A" "$L7B"; do
  $P -c "BEGIN; SELECT public.exos_journal_post_gift_card($L); SELECT pg_sleep(0.3); COMMIT;" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
tax=$($P -c "SELECT coalesce(sum(l.debit_cents - l.credit_cents),0) FROM exos_journal_lines l JOIN exos_journal_entries e ON e.id=l.entry_id
             WHERE e.org_id='$O' AND l.account='sales_tax_payable' AND e.session_id='cs_race_mj_7' AND e.source_table='exos_gift_card_ledger'")
gcb=$($P -c "SELECT coalesce(sum(l.debit_cents - l.credit_cents),0) FROM exos_journal_lines l JOIN exos_journal_entries e ON e.id=l.entry_id
             WHERE e.org_id='$O' AND l.account='gift_cards_outstanding' AND e.session_id='cs_race_mj_7'")
# 400 x 1000 / 5000 = 80 each; the order's gift card part is all back on the card (2000 - 2000 = 0).
if [[ "$(entries "$L7A" gc_refund)" == 1 && "$(entries "$L7B" gc_refund)" == 1 && "$tax" == 160 && "$gcb" == 0 && "$(balanced)" == 0 ]]; then
  echo "OK   race 7 two refunds to one gift card, posted in parallel: one entry each, tax back $tax (<= 400), the card part restored"
else
  echo "FAIL race 7: entries $(entries "$L7A" gc_refund)/$(entries "$L7B" gc_refund), tax $tax, gift card part $gcb"; fail=1
fi
exit $fail
