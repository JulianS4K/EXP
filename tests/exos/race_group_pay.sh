#!/usr/bin/env bash
# Group buy v2 races (mig 20261108120000): real parallel sessions.
# Timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_group_pay.sh exos_p0_test
# exos-checkout's calls (exos_group_claim / exos_group_attach) and the
# webhook's exos_fulfill_checkout run as the service role (postgres here).
# Expect:
#   race 1 two friends open the same seat link, the first one's claim still
#          uncommitted: the second waits on the seat's hold, then gets "seat
#          already taken"
#   race 2 five friends claim one seat at the same moment: exactly one wins
#   race 3 a friend's payment is being fulfilled when the host covers the
#          rest: the cover waits, sees the seat paid and is refused ("the group
#          just changed"); the host covers the other seats; each seat sold once
#   race 4 the host's cover is being fulfilled when a friend's payment for a
#          covered seat lands: the friend's order waits, then fails (refunded);
#          each seat sold once
#   race 5 the expiry sweep is running at the deadline when a payment lands:
#          the payment waits on the hold, sees it expired and fails (refunded);
#          the seat is released, nothing sold
#   race 6 a payment is being fulfilled just before the deadline when the
#          sweep runs: the sweep waits, then skips the consumed hold; the seat
#          is paid once
# Every race ends with the invariant: tier sold = paid seats, each seat paid
# by exactly one order or released, never oversold.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=c7f00000-0000-0000-0000-000000000001; A=c7f00000-0000-0000-0000-0000000000a0
HOST=c7f00000-0000-0000-0000-0000000000b0
F1=c7f00000-0000-0000-0000-0000000000b1; F2=c7f00000-0000-0000-0000-0000000000b2
F3=c7f00000-0000-0000-0000-0000000000b3; F4=c7f00000-0000-0000-0000-0000000000b4; F5=c7f00000-0000-0000-0000-0000000000b5
E=c7f00000-0000-0000-0000-0000000000e1; T=c7f00000-0000-0000-0000-0000000000d1
cleanup() {
  $P -c "DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_mail WHERE to_email LIKE '%@race-gp.test';
         DELETE FROM exos_group_buys WHERE event_id='$E';
         DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_checkout_sessions WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE email LIKE '%@race-gp.test';" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-gp.test',now()),
         ('$HOST','host@race-gp.test',now()),('$F1','f1@race-gp.test',now()),('$F2','f2@race-gp.test',now()),
         ('$F3','f3@race-gp.test',now()),('$F4','f4@race-gp.test',now()),('$F5','f5@race-gp.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race group pay','race-gp','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-gp','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES ('$T','$E','GA',25,50,0,'public');" >/dev/null
fail=0
ok() { echo "OK   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# A fresh group of $1 seats; prints its id. The previous one is closed first.
new_group() {
  $P -c "UPDATE exos_group_buys SET status='closed' WHERE event_id='$E' AND status='open';" >/dev/null
  $P -c "WITH me AS MATERIALIZED (SELECT set_config('app.uid','$HOST',false), set_config('app.jwt','{\"email\":\"host@race-gp.test\"}',false))
         SELECT public.exos_group_buy_start('$E','$T',$1)->>'id' FROM me;"
}
tok() { $P -c "SELECT token FROM exos_group_buy_seats WHERE group_id='$1' AND seat_no=$2"; }
claim() { echo "SELECT public.exos_group_claim('$1', NULL, '$2', '$3', '$E', '$T', 1);"; }
sess() { echo "INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status)
               VALUES ('$1','$E','$T','$O','$2','$3',$4,2500*$4,'usd','pending');"; }
# Each seat paid by exactly one order or released, and sold = paid seats.
invariant() {
  local g=$1 sold paid tickets
  sold=$($P -c "SELECT sold FROM exos_ticket_tiers WHERE id='$T'")
  paid=$($P -c "SELECT count(*) FROM exos_group_buy_seats s JOIN exos_group_buys g ON g.id=s.group_id WHERE g.event_id='$E' AND s.status='paid'")
  tickets=$($P -c "SELECT count(*) FROM exos_tickets WHERE event_id='$E' AND status='active'")
  if [[ "$sold" == "$paid" && "$tickets" == "$paid" ]]; then ok "  invariant: sold $sold = paid seats $paid = tickets $tickets"
  else bad "  invariant: sold $sold, paid seats $paid, tickets $tickets"; fi
}

# race 1: the first claim is uncommitted when the second friend opens the link.
G=$(new_group 3); T1=$(tok "$G" 1)
$P -c "BEGIN; $(claim "$T1" "$F1" f1@race-gp.test) SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "$(claim "$T1" "$F2" f2@race-gp.test)" 2>&1 || true)
wait
who=$($P -c "SELECT claim_uid FROM exos_group_buy_seats WHERE token='$T1'")
if [[ "$out" == *"seat already taken"* && "$who" == "$F1" ]]; then ok "race 1 same seat link, first claim in flight: second friend gets 'seat already taken'"
else bad "race 1: $out / claimant $who"; fi

# race 2: five friends at the same moment.
T2=$(tok "$G" 2)
TMPD=$(mktemp -d)
for f in "$F1:f1" "$F2:f2" "$F3:f3" "$F4:f4" "$F5:f5"; do
  uid=${f%%:*}; nm=${f##*:}
  ( r=$($P -c "$(claim "$T2" "$uid" "$nm@race-gp.test")" 2>&1 || true); echo "$r" > "$TMPD/$nm.out" ) &
done
wait
won=0; taken=0
for nm in f1 f2 f3 f4 f5; do
  r=$(cat "$TMPD/$nm.out")
  if [[ "$r" =~ ^[0-9a-f-]{36}$ ]]; then won=$((won + 1)); elif [[ "$r" == *"seat already taken"* ]]; then taken=$((taken + 1)); fi
done
rm -rf "$TMPD"
if [[ "$won" == 1 && "$taken" == 4 ]]; then ok "race 2 five friends, one seat, at once: one claim, four 'seat already taken'"
else bad "race 2: $won won, $taken refused"; fi

# race 3: friend 1 pays seat 1 (fulfilment in flight) while the host covers the rest.
$P -c "$(sess cs_race_gp_f1 "$F1" f1@race-gp.test 1) SELECT public.exos_group_attach('cs_race_gp_f1','$T1',NULL);" >/dev/null
$P -c "UPDATE exos_group_buy_seats SET status='waiting', claim_uid=NULL, claim_email=NULL, claimed_at=NULL WHERE token='$T2';" >/dev/null
N=$($P -c "SELECT public.exos_group_checkout_ctx(NULL,'$G','$HOST')->>'quantity'")
$P -c "BEGIN; SELECT public.exos_fulfill_checkout('cs_race_gp_f1'); SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "SELECT public.exos_group_claim(NULL,'$G','$HOST','host@race-gp.test','$E','$T',$N);" 2>&1 || true)
wait
if [[ "$N" == 3 && "$out" == *"the group just changed"* ]]; then ok "race 3 cover during a friend's fulfilment: waits, sees the seat paid, refused"
else bad "race 3: quantity $N / $out"; fi
N=$($P -c "SELECT public.exos_group_checkout_ctx(NULL,'$G','$HOST')->>'quantity'")
out=$($P -c "SELECT public.exos_group_claim(NULL,'$G','$HOST','host@race-gp.test','$E','$T',$N);" \
          -c "$(sess cs_race_gp_cover "$HOST" host@race-gp.test "$N")" \
          -c "SELECT public.exos_group_attach('cs_race_gp_cover',NULL,'$G');" \
          -c "SELECT cardinality(public.exos_fulfill_checkout('cs_race_gp_cover'));" 2>&1 | tail -n 1 || true)
st=$($P -c "SELECT status FROM exos_checkout_sessions WHERE session_id='cs_race_gp_f1'")
if [[ "$N" == 2 && "$out" == 2 && "$st" == fulfilled ]]; then ok "race 3 the host then covers the other 2 seats; friend 1 keeps seat 1"
else bad "race 3 retry: quantity $N / issued $out / friend $st"; fi
invariant "$G"

# race 4: the host's cover is being fulfilled when friend 2's payment for a covered seat lands.
G=$(new_group 2); T1=$(tok "$G" 1)
$P -c "$(claim "$T1" "$F2" f2@race-gp.test) $(sess cs_race_gp_f2 "$F2" f2@race-gp.test 1)
       SELECT public.exos_group_attach('cs_race_gp_f2','$T1',NULL);
       SELECT public.exos_group_claim(NULL,'$G','$HOST','host@race-gp.test','$E','$T',2);
       $(sess cs_race_gp_cover2 "$HOST" host@race-gp.test 2)" >/dev/null
$P -c "BEGIN; SELECT public.exos_group_attach('cs_race_gp_cover2',NULL,'$G'); SELECT public.exos_fulfill_checkout('cs_race_gp_cover2');
       SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "SELECT cardinality(public.exos_fulfill_checkout('cs_race_gp_f2'));" 2>&1 || true)
wait
st=$($P -c "SELECT status||' '||coalesce(failure_reason,'') FROM exos_checkout_sessions WHERE session_id='cs_race_gp_f2'")
cv=$($P -c "SELECT count(*) FROM exos_group_buy_seats WHERE group_id='$G' AND status='paid' AND covered")
if [[ "$out" == 0 && "$st" == "failed group seat no longer held"* && "$cv" == 2 ]]; then ok "race 4 friend's payment during the cover: waits, fails (refunded); both seats covered once"
else bad "race 4: issued $out / $st / covered $cv"; fi
invariant "$G"

# race 5: the sweep is running at the deadline when a payment lands.
G=$(new_group 2); T1=$(tok "$G" 1)
$P -c "$(claim "$T1" "$F3" f3@race-gp.test) $(sess cs_race_gp_f3 "$F3" f3@race-gp.test 1)
       SELECT public.exos_group_attach('cs_race_gp_f3','$T1',NULL);
       UPDATE exos_group_buys SET created_at=now() - interval '29 minutes', deadline=now() + interval '1 second' WHERE id='$G';
       UPDATE exos_cart_holds SET expires_at=now() + interval '1 second' WHERE group_seat_id IN (SELECT id FROM exos_group_buy_seats WHERE group_id='$G');" >/dev/null
sleep 1.5
SOLD0=$($P -c "SELECT sold FROM exos_ticket_tiers WHERE id='$T'")
$P -c "BEGIN; SELECT public.exos_expire_holds(); SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "SELECT cardinality(public.exos_fulfill_checkout('cs_race_gp_f3'));" 2>&1 || true)
wait
st=$($P -c "SELECT status FROM exos_checkout_sessions WHERE session_id='cs_race_gp_f3'")
rl=$($P -c "SELECT count(*) FROM exos_group_buy_seats WHERE group_id='$G' AND status='released'")
SOLD1=$($P -c "SELECT sold FROM exos_ticket_tiers WHERE id='$T'")
if [[ "$out" == 0 && "$st" == failed && "$rl" == 2 && "$SOLD0" == "$SOLD1" ]]; then ok "race 5 payment during the deadline sweep: fails (refunded), seats released, nothing sold"
else bad "race 5: issued $out / $st / released $rl / sold $SOLD0 -> $SOLD1"; fi
invariant "$G"

# race 6: a payment is being fulfilled just before the deadline when the sweep runs.
G=$(new_group 2); T1=$(tok "$G" 1)
$P -c "$(claim "$T1" "$F4" f4@race-gp.test) $(sess cs_race_gp_f4 "$F4" f4@race-gp.test 1)
       SELECT public.exos_group_attach('cs_race_gp_f4','$T1',NULL);
       UPDATE exos_group_buys SET created_at=now() - interval '29 minutes', deadline=now() + interval '1 second' WHERE id='$G';
       UPDATE exos_cart_holds SET expires_at=now() + interval '1 second' WHERE group_seat_id IN (SELECT id FROM exos_group_buy_seats WHERE group_id='$G');" >/dev/null
$P -c "BEGIN; SELECT public.exos_fulfill_checkout('cs_race_gp_f4'); SELECT pg_sleep(2.5); COMMIT;" >/dev/null &
sleep 1.5
out=$($P -c "SELECT public.exos_expire_holds();" 2>&1 || true)
wait
st=$($P -c "SELECT status FROM exos_checkout_sessions WHERE session_id='cs_race_gp_f4'")
s1=$($P -c "SELECT status FROM exos_group_buy_seats WHERE token='$T1'")
s2=$($P -c "SELECT status FROM exos_group_buy_seats WHERE group_id='$G' AND seat_no=2")
if [[ "$st" == fulfilled && "$s1" == paid && "$s2" == released ]]; then ok "race 6 sweep during a payment just before the deadline: waits, the seat stays paid once"
else bad "race 6: sweep $out / order $st / seat 1 $s1 / seat 2 $s2"; fi
invariant "$G"
exit $fail
