#!/usr/bin/env bash
# Waiting room races (mig 20261118120000): admission rounds and holds in real
# parallel sessions. Timing-based, so run by hand against a DB built by
# run_p0.sh:
#   bash tests/exos/race_waiting_room.sh exos_p0_test
# Expect:
#   race 1 20 pollers hit the same due round at once (each holds its
#          transaction open): exactly one round runs, so exactly the round's
#          budget (60) is admitted, the front of the line, and the clock moves
#          once
#   race 2 a second due round, 20 pollers again: exactly 60 more, never an
#          entry admitted twice (admitted_at unchanged for the first 60)
#   race 3 50 admitted buyers and 10 still waiting each try one ticket of a
#          30-ticket type at once: 30 holds, never more; every waiting one
#          refused (XWR01); an admission is marked used only when its hold
#          committed
#   race 4 one admitted token, 10 different buyers at once (each keeps its
#          transaction open): exactly one hold; the others refused (XWR02 while
#          the first is open, XWR01 once the turn is bound); the turn bound to
#          that one buyer
#   race 5 the same buyer twice at once on one token: one hold, the other
#          XWR02 (one checkout per turn at a time)
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=e7e00000-0000-0000-0000-000000000001; A=e7e00000-0000-0000-0000-0000000000a1
EV=e7e00000-0000-0000-0000-0000000000e1; T=e7e00000-0000-0000-0000-0000000000c1
OUT=$(mktemp -d)
cleanup() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$EV'; DELETE FROM exos_wroom_entries WHERE event_id='$EV';
         DELETE FROM exos_wroom_settings WHERE event_id='$EV'; DELETE FROM exos_ticket_tiers WHERE event_id='$EV';
         DELETE FROM exos_events WHERE id='$EV'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id='$A' OR email LIKE 'fan%@race-wr.test';" >/dev/null
  rm -rf "$OUT"
}
cleanup
OUT=$(mktemp -d)
trap cleanup EXIT
# Token n: 64 hex, known to the script. Users fan1..fan60.
tok() { echo -n "$(echo -n "wr$1" | md5sum | cut -c1-32)$(echo -n "wr$1x" | md5sum | cut -c1-32)"; }
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-wr.test',now());
       INSERT INTO auth.users(id,email,email_confirmed_at)
         SELECT ('e7e00000-0000-0000-0000-' || lpad(to_hex(1000 + g), 12, '0'))::uuid, 'fan' || g || '@race-wr.test', now()
           FROM generate_series(1, 60) g;
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race WR','race-wr','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,created_by,link_out)
         VALUES ('$EV','$O','Race WR Drop','race-wr-drop','published',now() + interval '30 days','America/New_York',30,'$A',false);
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sales_start,visibility)
         VALUES ('$T','$EV','GA',20,30,now() - interval '1 minute','public');
       INSERT INTO exos_wroom_settings(event_id,org_id,enabled,window_minutes,admit_per_minute,admission_minutes,idle_close_minutes,enabled_at)
         VALUES ('$EV','$O',true,0,120,10,30,now() - interval '2 minutes');" >/dev/null
# 300 people in line (random places, all seen just now).
VALUES=""
for n in $(seq 1 300); do VALUES+="('$(tok $n)'),"; done
$P -c "INSERT INTO exos_wroom_entries(org_id,event_id,run_id,token_hash,net_hash,arrived_at,order_key)
         SELECT '$O','$EV',(SELECT run_id FROM exos_wroom_settings WHERE event_id='$EV'),
                public._exos_wroom_hash('$EV', v.t), md5(v.t) || md5(v.t), now() - interval '3 minutes', public._exos_wroom_rand()
           FROM (VALUES ${VALUES%,}) v(t);
       UPDATE exos_wroom_settings SET on_sale_at = now() - interval '1 minute', drawn_at = now() - interval '1 minute'
        WHERE event_id='$EV';" >/dev/null
fail=0
admitted() { $P -c "SELECT count(*) FROM exos_wroom_entries WHERE event_id='$EV' AND state='admitted'"; }
due_round() {  # the next round is due, with 30 s of credit at 120 a minute = 60
  $P -c "UPDATE exos_wroom_settings SET advanced_at = now() - interval '6 seconds', admit_clock = now() - interval '30 seconds'
          WHERE event_id='$EV'" >/dev/null
}
POLL="SELECT set_config('request.headers','{\"cf-connecting-ip\":\"198.51.100.7\"}',true);
      SET LOCAL ROLE anon;"
pollers() {  # $1 = label: 20 pollers at once, each holding its transaction open
  for i in $(seq 1 20); do
    $P -c "BEGIN; $POLL SELECT public.exos_wroom_status('$EV', '$(tok $i)')->>'state'; SELECT pg_sleep(0.5); COMMIT;" \
      > "$OUT/$1.$i" 2>&1 &
  done
  wait
}

# race 1 ---------------------------------------------------------------------
due_round
pollers r1
n1=$(admitted)
front=$($P -c "SELECT count(*) FROM (SELECT state FROM exos_wroom_entries WHERE event_id='$EV' ORDER BY order_key, id LIMIT 60) x
               WHERE state = 'admitted'")
errs=$(cat "$OUT"/r1.* | grep -c ERROR || true)
if [[ "$n1" == 60 && "$front" == 60 && "$errs" == 0 ]]; then
  echo "OK   race 1 20 parallel pollers, one round: exactly 60 admitted, the front of the line"
else
  echo "FAIL race 1: admitted $n1, front $front, errors $errs"; cat "$OUT"/r1.* | grep ERROR | head -3; fail=1
fi

# race 2 ---------------------------------------------------------------------
ids=$($P -c "SELECT string_agg(quote_literal(id::text), ',') FROM exos_wroom_entries WHERE event_id='$EV' AND state='admitted'")
first=$($P -c "SELECT string_agg(id::text || admitted_at::text, ',' ORDER BY id) FROM exos_wroom_entries WHERE id::text IN ($ids)")
due_round
pollers r2
n2=$(admitted)
again=$($P -c "SELECT string_agg(id::text || admitted_at::text, ',' ORDER BY id) FROM exos_wroom_entries
               WHERE id::text IN ($ids) AND state = 'admitted'")
front=$($P -c "SELECT count(*) FROM (SELECT state FROM exos_wroom_entries WHERE event_id='$EV' ORDER BY order_key, id LIMIT 120) x
               WHERE state = 'admitted'")
if [[ "$n2" == 120 && "$front" == 120 && "$again" == "$first" ]]; then
  echo "OK   race 2 a second round under 20 pollers: exactly 60 more, nobody admitted twice"
else
  echo "FAIL race 2: admitted $n2, front $front, first round unchanged: $([[ "$again" == "$first" ]] && echo yes || echo no)"; fail=1
fi

# race 3 ---------------------------------------------------------------------
# Buyers 1..50: admitted tokens (the front 120 are admitted; re-admit 1..50 to be sure).
$P -c "UPDATE exos_wroom_entries SET state='admitted', admitted_at=now(), admit_expires_at=now() + interval '10 minutes', used_at=NULL
        WHERE event_id='$EV' AND token_hash IN (SELECT public._exos_wroom_hash('$EV', t) FROM unnest(ARRAY[$(for n in $(seq 1 50); do echo -n "'$(tok $n)',"; done | sed 's/,$//')]) t);
       UPDATE exos_wroom_entries SET state='waiting', admitted_at=NULL, admit_expires_at=NULL
        WHERE event_id='$EV' AND token_hash IN (SELECT public._exos_wroom_hash('$EV', t) FROM unnest(ARRAY[$(for n in $(seq 251 260); do echo -n "'$(tok $n)',"; done | sed 's/,$//')]) t);
       UPDATE exos_wroom_settings SET advanced_at = now() + interval '1 hour' WHERE event_id='$EV';" >/dev/null
hold() {  # $1 = buyer (fan n), $2 = token n, $3 = seconds to keep the transaction open
  local uid; uid="e7e00000-0000-0000-0000-$(printf '%012x' $((1000 + $1)))"
  $P -c "BEGIN;
         SELECT set_config('app.uid','$uid',true);
         SELECT set_config('app.jwt','{\"email\":\"fan$1@race-wr.test\"}',true);
         SELECT set_config('request.headers','{\"cf-connecting-ip\":\"198.51.100.8\",\"x-exos-queue\":\"$(tok $2)\"}',true);
         SET LOCAL ROLE authenticated;
         SELECT public.exos_create_hold('$EV','$T',1,600,NULL) IS NOT NULL;
         SELECT count(*) FROM pg_sleep(${3:-0});
         COMMIT;" 2>&1 || true
}
for n in $(seq 1 50); do hold "$n" "$n" > "$OUT/h.$n" & done
for n in $(seq 251 260); do hold $((n - 200)) "$n" > "$OUT/w.$n" & done
wait
holds=$($P -c "SELECT count(*) FROM exos_cart_holds WHERE event_id='$EV' AND status='active'")
qty=$($P -c "SELECT coalesce(sum(quantity),0) FROM exos_cart_holds WHERE event_id='$EV' AND status='active'")
ok=$(cat "$OUT"/h.* | grep -c '^t$' || true)
queued=$(cat "$OUT"/w.* | grep -c 'wait for your turn' || true)
used=$($P -c "SELECT count(*) FROM exos_wroom_entries WHERE event_id='$EV' AND used_at IS NOT NULL")
if [[ "$holds" == 30 && "$qty" == 30 && "$ok" == 30 && "$queued" == 10 && "$used" == 30 ]]; then
  echo "OK   race 3 50 admitted + 10 waiting buyers at once on 30 tickets: 30 holds, 10 refused (XWR01), 30 admissions used"
else
  echo "FAIL race 3: holds $holds (qty $qty), ok $ok, queued $queued, used $used"; cat "$OUT"/h.* "$OUT"/w.* | grep -v '^t$' | sort | uniq -c | head -5; fail=1
fi

# race 4 ---------------------------------------------------------------------
# Token 270: admitted, unused. Buyers 41..50 had holds released for room.
$P -c "UPDATE exos_cart_holds SET status='released', released_at=now() WHERE event_id='$EV';
       UPDATE exos_wroom_entries SET state='admitted', admitted_at=now(), admit_expires_at=now() + interval '10 minutes',
              used_at=NULL, redeemer_hash=NULL
        WHERE event_id='$EV' AND token_hash IN (public._exos_wroom_hash('$EV','$(tok 270)'), public._exos_wroom_hash('$EV','$(tok 271)'));" >/dev/null
for n in $(seq 41 50); do hold "$n" 270 0.5 > "$OUT/r4.$n" & done
wait
ok4=$(cat "$OUT"/r4.* | grep -c '^t$' || true)
busy4=$(cat "$OUT"/r4.* | grep -c 'already checking out' || true)
wait4=$(cat "$OUT"/r4.* | grep -c 'wait for your turn' || true)
held4=$($P -c "SELECT count(*) FROM exos_cart_holds WHERE event_id='$EV' AND status='active'")
bound=$($P -c "SELECT count(*) FROM exos_wroom_entries WHERE token_hash=public._exos_wroom_hash('$EV','$(tok 270)') AND redeemer_hash IS NOT NULL")
if [[ "$ok4" == 1 && $((busy4 + wait4)) == 9 && "$held4" == 1 && "$bound" == 1 ]]; then
  echo "OK   race 4 one token, 10 buyers at once: 1 hold, 9 refused ($busy4 busy, $wait4 not theirs), bound to one buyer"
else
  echo "FAIL race 4: ok $ok4, busy $busy4, wait $wait4, active holds $held4, bound $bound"; cat "$OUT"/r4.* | grep -v '^t$' | sort | uniq -c | head -5; fail=1
fi

# race 5 ---------------------------------------------------------------------
hold 45 271 0.5 > "$OUT/r5.a" &
hold 45 271 0.5 > "$OUT/r5.b" &
wait
ok5=$(cat "$OUT"/r5.* | grep -c '^t$' || true)
busy5=$(cat "$OUT"/r5.* | grep -c 'already checking out' || true)
if [[ "$ok5" == 1 && "$busy5" == 1 ]]; then
  echo "OK   race 5 the same buyer twice at once on one turn: one hold, the other refused (XWR02)"
else
  echo "FAIL race 5: ok $ok5, busy $busy5"; cat "$OUT"/r5.*; fail=1
fi
exit $fail
