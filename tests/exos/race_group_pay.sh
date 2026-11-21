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
# Group pay 2 (mig 20261110110000):
#   race 7 a friend's page is due at the deadline (exos_group_pages_to_expire)
#          when the payment lands: (a) the payment's fulfilment holds the order
#          when exos-reconcile-checkouts marks the page expired: the mark waits
#          and leaves the failed order alone (the refund sweep's); (b) the mark
#          commits first: the late webhook waits, then issues nothing
#   race 8 two friends pay at a price-step boundary at the same moment (the
#          group locked the step's last 2 places at $20; the public price is
#          already $30): both pay $20, both tickets on that step, the step
#          sells out exactly at its count
#   race 9 two hosts start a group of 2 at the same moment with 3 left at the
#          price: one locks the step, the other waits and is refused with
#          "only 1 left at this price"
#   race 10 two hosts start a group of 6 at the same moment on an event of 40:
#          live group seats may hold at most 10 (the per-event ceiling): one
#          group starts, the other waits and is refused
# A host starts at most 3 groups an hour (mig 20261110110000): age_groups
# moves earlier groups back 2 hours between races.
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
T2=c7f00000-0000-0000-0000-0000000000d2; HOST2=c7f00000-0000-0000-0000-0000000000b6
E2=c7f00000-0000-0000-0000-0000000000e2; T3=c7f00000-0000-0000-0000-0000000000d3
cleanup() {
  $P -c "DELETE FROM exos_tickets WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_mail WHERE to_email LIKE '%@race-gp.test';
         DELETE FROM exos_group_buys WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_cart_holds WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_price_steps WHERE event_id='$E';
         DELETE FROM exos_checkout_sessions WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id IN ('$E','$E2'); DELETE FROM exos_events WHERE id IN ('$E','$E2');
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE email LIKE '%@race-gp.test';" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-gp.test',now()),
         ('$HOST','host@race-gp.test',now()),('$F1','f1@race-gp.test',now()),('$F2','f2@race-gp.test',now()),
         ('$F3','f3@race-gp.test',now()),('$F4','f4@race-gp.test',now()),('$F5','f5@race-gp.test',now()),
         ('$HOST2','host2@race-gp.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race group pay','race-gp','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-gp','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES ('$T','$E','GA',25,50,0,'public');" >/dev/null
fail=0
ok() { echo "OK   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# A fresh group of $1 seats; prints its id. The previous one is closed first.
# Earlier groups closed and 2 hours old (the 3-an-hour cap), their unpaid holds over.
age_groups() {
  $P -c "UPDATE exos_cart_holds SET status='expired' WHERE event_id IN ('$E','$E2') AND group_seat_id IS NOT NULL AND status='active';
         UPDATE exos_group_buys SET status=CASE WHEN status='open' THEN 'closed' ELSE status END,
                created_at=now() - interval '2 hours', deadline=now() - interval '90 minutes' WHERE event_id IN ('$E','$E2');" >/dev/null
}
new_group() {
  age_groups
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

# race 7a: the payment lands at the deadline; its fulfilment holds the order
# when the reconcile marks the page expired (the update it runs after Stripe).
MARK="UPDATE exos_checkout_sessions SET status='expired', failure_reason='group seat no longer held (deadline): checkout page closed'"
G=$(new_group 2); T1=$(tok "$G" 1)
$P -c "$(claim "$T1" "$F5" f5@race-gp.test) $(sess cs_race_gp_f5 "$F5" f5@race-gp.test 1)
       SELECT public.exos_group_attach('cs_race_gp_f5','$T1',NULL);
       UPDATE exos_checkout_sessions SET created_at=now() - interval '3 minutes' WHERE session_id='cs_race_gp_f5';
       UPDATE exos_group_buys SET created_at=now() - interval '29 minutes', deadline=now() + interval '1 second' WHERE id='$G';
       UPDATE exos_cart_holds SET expires_at=now() + interval '1 second' WHERE group_seat_id IN (SELECT id FROM exos_group_buy_seats WHERE group_id='$G');" >/dev/null
sleep 1.5
due=$($P -c "SELECT string_agg(why, ',') FROM public.exos_group_pages_to_expire(200) WHERE session_id='cs_race_gp_f5'")
SOLD0=$($P -c "SELECT sold FROM exos_ticket_tiers WHERE id='$T'")
$P -c "BEGIN; SELECT public.exos_fulfill_checkout('cs_race_gp_f5'); SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "$MARK WHERE session_id='cs_race_gp_f5' AND status='pending' RETURNING session_id;" 2>&1 || true)
wait
st=$($P -c "SELECT status FROM exos_checkout_sessions WHERE session_id='cs_race_gp_f5'")
SOLD1=$($P -c "SELECT sold FROM exos_ticket_tiers WHERE id='$T'")
if [[ "$due" == deadline && -z "$out" && "$st" == failed && "$SOLD0" == "$SOLD1" ]]; then ok "race 7a page due at the deadline, payment in flight: the mark waits and leaves the failed order to the refund sweep"
else bad "race 7a: due '$due' / mark '$out' / order $st / sold $SOLD0 -> $SOLD1"; fi
invariant "$G"

# race 7b: the mark commits first (Stripe expired the page); a late webhook waits, then issues nothing.
$P -c "UPDATE exos_group_buys SET status='closed' WHERE id='$G';" >/dev/null
G=$(new_group 2); T1=$(tok "$G" 1)
$P -c "$(claim "$T1" "$F4" f4@race-gp.test) $(sess cs_race_gp_f4b "$F4" f4@race-gp.test 1)
       SELECT public.exos_group_attach('cs_race_gp_f4b','$T1',NULL);
       UPDATE exos_checkout_sessions SET created_at=now() - interval '3 minutes' WHERE session_id='cs_race_gp_f4b';
       UPDATE exos_group_buys SET created_at=now() - interval '30 minutes', deadline=now() - interval '1 second' WHERE id='$G';
       UPDATE exos_cart_holds SET expires_at=now() - interval '1 second' WHERE group_seat_id IN (SELECT id FROM exos_group_buy_seats WHERE group_id='$G');" >/dev/null
$P -c "BEGIN; $MARK WHERE session_id='cs_race_gp_f4b' AND status='pending'; SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "SELECT cardinality(public.exos_fulfill_checkout('cs_race_gp_f4b'));" 2>&1 || true)
wait
st=$($P -c "SELECT status FROM exos_checkout_sessions WHERE session_id='cs_race_gp_f4b'")
due=$($P -c "SELECT count(*) FROM public.exos_group_pages_to_expire(200) WHERE session_id='cs_race_gp_f4b'")
if [[ "$out" == 0 && "$st" == expired && "$due" == 0 ]]; then ok "race 7b the page was expired first: the late webhook waits, then issues nothing"
else bad "race 7b: issued $out / order $st / still due $due"; fi
invariant "$G"

# Price steps on a second type: Early 20.00 for N, then Regular 30.00.
steps() {
  $P -c "DELETE FROM exos_price_steps WHERE tier_id='$T2';
         INSERT INTO exos_price_steps (tier_id, sort_order, name, price_cents, ends_after_count)
         VALUES ('$T2',1,'Early',2000,$1),('$T2',2,'Regular',3000,NULL);" >/dev/null
}
$P -c "INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES ('$T2','$E','Stepped',20,50,0,'public');" >/dev/null
start_as() {  # host uid, host email, qty: the group id (or the error)
  $P -c "WITH me AS MATERIALIZED (SELECT set_config('app.uid','$1',false), set_config('app.jwt','{\"email\":\"$2\"}',false))
         SELECT public.exos_group_buy_start('$E','$T2',$3)->>'id' FROM me;" 2>&1 || true
}

# race 8: two friends pay at once at the step boundary.
steps 2
age_groups
G=$(start_as "$HOST" host@race-gp.test 2)
S1=$($P -c "SELECT id FROM exos_price_steps WHERE tier_id='$T2' AND sort_order=1")
pub=$($P -c "SELECT public.exos_tier_current_price('$T2')->>'price_cents'")
for n in 1 2; do
  tk=$(tok "$G" $n); f=$([[ $n == 1 ]] && echo "$F1" || echo "$F2")
  $P -c "SELECT public.exos_group_claim('$tk', NULL, '$f', 'f$n@race-gp.test', '$E', '$T2', 1);
         INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,price_step_id)
           VALUES ('cs_race_gp_step$n','$E','$T2','$O','$f','f$n@race-gp.test',1,2000,'usd','pending','$S1');
         SELECT public.exos_group_attach('cs_race_gp_step$n','$tk',NULL);" >/dev/null
done
TMPD=$(mktemp -d)
for n in 1 2; do
  ( r=$($P -c "BEGIN; SELECT cardinality(public.exos_fulfill_checkout('cs_race_gp_step$n')); SELECT pg_sleep(1); COMMIT;" 2>&1 || true); echo "$r" > "$TMPD/$n.out" ) &
done
wait
r1=$(head -n 1 "$TMPD/1.out"); r2=$(head -n 1 "$TMPD/2.out"); rm -rf "$TMPD"
tk=$($P -c "SELECT count(*) FROM exos_tickets WHERE tier_id='$T2' AND status='active' AND price_step_id='$S1' AND price_paid=20.00")
lat=$($P -c "SELECT sold_out_at IS NOT NULL FROM exos_price_steps WHERE id='$S1'")
now=$($P -c "SELECT public.exos_tier_current_price('$T2')->>'price_cents'")
if [[ "$pub" == 3000 && "$r1" == 1 && "$r2" == 1 && "$tk" == 2 && "$lat" == t && "$now" == 3000 ]]; then
  ok "race 8 two friends at a price-step boundary, at once: both pay the locked \$20 on that step; it sells out at its count"
else bad "race 8: public $pub / issued $r1 $r2 / tickets at the step $tk / latched $lat / now $now"; fi

# race 9: two hosts start a group of 2 at once with 3 left at the price.
$P -c "DELETE FROM exos_tickets WHERE tier_id='$T2'; UPDATE exos_ticket_tiers SET sold=0 WHERE id='$T2';
" >/dev/null
age_groups
steps 3
S1=$($P -c "SELECT id FROM exos_price_steps WHERE tier_id='$T2' AND sort_order=1")
TMPD=$(mktemp -d)
( r=$($P -c "WITH me AS MATERIALIZED (SELECT set_config('app.uid','$HOST',false), set_config('app.jwt','{\"email\":\"host@race-gp.test\"}',false))
              SELECT public.exos_group_buy_start('$E','$T2',2)->>'id', pg_sleep(1.5) FROM me;" 2>&1 || true); echo "$r" > "$TMPD/a.out" ) &
sleep 0.3
( r=$(start_as "$HOST2" host2@race-gp.test 2); echo "$r" > "$TMPD/b.out" ) &
wait
a=$(cat "$TMPD/a.out"); b=$(cat "$TMPD/b.out"); rm -rf "$TMPD"
locked=$($P -c "SELECT count(*) FROM exos_cart_holds WHERE tier_id='$T2' AND status='active' AND price_step_id='$S1' AND unit_price_cents=2000")
groups=$($P -c "SELECT count(*) FROM exos_group_buys WHERE tier_id='$T2' AND status='open'")
if [[ "$a" =~ ^[0-9a-f-]{36}\|$ && "$b" == *"only 1 left at this price"* && "$locked" == 2 && "$groups" == 1 ]]; then
  ok "race 9 two hosts at the step boundary at once: one group locks the step, the other is refused (1 left)"
else bad "race 9: host 1 '$a' / host 2 '$b' / locked holds $locked / open groups $groups"; fi

# race 10: two hosts at once against the per-event ceiling of group seats.
age_groups
$P -c "INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E2','$O','Race 2','race-gp-2','published',now() + interval '10 days',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES ('$T3','$E2','GA',25,40,0,'public');" >/dev/null
TMPD=$(mktemp -d)
( r=$($P -c "WITH me AS MATERIALIZED (SELECT set_config('app.uid','$HOST',false), set_config('app.jwt','{\"email\":\"host@race-gp.test\"}',false))
              SELECT public.exos_group_buy_start('$E2','$T3',6)->>'id', pg_sleep(1.5) FROM me;" 2>&1 || true); echo "$r" > "$TMPD/a.out" ) &
sleep 0.3
( r=$($P -c "WITH me AS MATERIALIZED (SELECT set_config('app.uid','$HOST2',false), set_config('app.jwt','{\"email\":\"host2@race-gp.test\"}',false))
              SELECT public.exos_group_buy_start('$E2','$T3',6)->>'id' FROM me;" 2>&1 || true); echo "$r" > "$TMPD/b.out" ) &
wait
a=$(cat "$TMPD/a.out"); b=$(cat "$TMPD/b.out"); rm -rf "$TMPD"
held=$($P -c "SELECT coalesce(sum(quantity),0) FROM exos_cart_holds WHERE event_id='$E2' AND group_seat_id IS NOT NULL AND status='active'")
avail=$($P -c "SELECT public.exos_tier_available('$T3')")
if [[ "$a" =~ ^[0-9a-f-]{36}\|$ && "$b" == *"lots of groups are holding seats"* && "$held" == 6 && "$avail" == 34 ]]; then
  ok "race 10 two hosts at once past the per-event group ceiling: one group of 6 starts, the other waits and is refused"
else bad "race 10: host 1 '$a' / host 2 '$b' / group seats held $held / available $avail"; fi
exit $fail
