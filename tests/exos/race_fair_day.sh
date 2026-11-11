#!/usr/bin/env bash
# Fair-day races (mig 20261113110000), in real parallel sessions. Timing-based,
# so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_fair_day.sh exos_p0_test
# Expect:
#   race 1 two gates of the same fair day (no re-entry) scan one 3-day pass
#          at once: one admits, the other answers 'used'; one entry row
#   race 2 two gates scan one any-day pass on two different days at once
#          (offline replays): one admits, the other answers 'day-limit'
#   race 3 two tabs run the fair setup for one event at once: one sets it up,
#          the other is refused (23505); one set of lists
#   race 4 a 3-day pass used on day 1 is refunded (voided) while a day 3 gate
#          scans it: the scan read 'used' before the refund committed, waits
#          on the ticket's lock, re-reads it and answers 'voided'; no entry
#   race 5 the same with a transfer started mid-scan: 'in-transfer'; no entry
#   race 6 two re-entry gates of one fair day scan one 3-day pass at once:
#          one admits, the other answers 'already-inside'; one entry
# The audit log is append-only, so each run uses fresh ids (its rows stay;
# the fixtures are removed).
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
RUN=$($P -c "SELECT substr(md5(random()::text || clock_timestamp()::text), 1, 8)")
id() { $P -c "SELECT md5('race-fd:$RUN:$1')::uuid"; }
O=$(id org); A=$(id owner); S=$(id scanner); B=$(id buyer); E=$(id event); E2=$(id event2)
K1=$(id multi); K2=$(id any); K3=$(id refunded); K4=$(id transferred); TR=$(id transfer); K5=$(id twogates)
cleanup() {
  $P -c "DELETE FROM exos_scan_rejects WHERE event_id IN ('$E','$E2');
         UPDATE exos_tickets SET pending_transfer_id = NULL WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_transfers WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_checkin_client_refs WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_event_checkins WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_tickets WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_checkin_lists WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_ticket_tiers WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_event_addons WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_events WHERE id IN ('$E','$E2');
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id IN ('$A','$S','$B');" >/dev/null 2>&1 || true
}
trap cleanup EXIT
# The plan: three whole UTC days (the events have no time zone): two days
# ago, yesterday, today; a 3-day pass, an any-day pass, no re-entry; day 3
# has a second gate and two re-entry gates added below.
D="((now() AT TIME ZONE 'UTC')::date)"
DAY="(((now() AT TIME ZONE 'UTC')::date - %s) + time '%s') AT TIME ZONE 'UTC'"
day() { printf "$DAY" "$1" "$2"; }
PLAN="jsonb_build_object(
  'tiers', jsonb_build_array(
    jsonb_build_object('key','multi','name','3-day pass','price_cents',3500,'capacity',100),
    jsonb_build_object('key','any','name','Any-day pass','price_cents',1800,'capacity',100,'max_entry_days',1)),
  'lists', jsonb_build_array(
    jsonb_build_object('name','Day 1','tier_keys',jsonb_build_array('multi','any'),'allow_reentry',false,
      'valid_from',$(day 2 00:00),'valid_until',$(day 2 23:59:59),'entry_day',$D - 2),
    jsonb_build_object('name','Day 2','tier_keys',jsonb_build_array('multi','any'),'allow_reentry',false,
      'valid_from',$(day 1 00:00),'valid_until',$(day 1 23:59:59),'entry_day',$D - 1),
    jsonb_build_object('name','Day 3','tier_keys',jsonb_build_array('multi','any'),'allow_reentry',false,
      'valid_from',$(day 0 00:00),'valid_until',$(day 0 23:59:59),'entry_day',$D)))"
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner-$RUN@race-fd.test',now()),
         ('$S','scan-$RUN@race-fd.test',now()),('$B','buyer-$RUN@race-fd.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race FD','race-fd-$RUN','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner'),('$O','$S','scanner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
         ('$E','$O','Race fair','race-fd-e-$RUN','published',now() - interval '50 hours',now() - interval '60 hours',500,'$A'),
         ('$E2','$O','Race fair 2','race-fd-e2-$RUN','published',now() - interval '50 hours',now() - interval '60 hours',500,'$A');
       SELECT set_config('app.uid','$A',false);
       SELECT public.exos_fair_setup('$E', $PLAN);
       INSERT INTO exos_checkin_lists(event_id,name,tier_ids,allow_reentry,valid_from,valid_until,entry_day)
         SELECT event_id,'Day 3 north',tier_ids,false,valid_from,valid_until,entry_day FROM exos_checkin_lists
          WHERE event_id='$E' AND name='Day 3';
       INSERT INTO exos_checkin_lists(event_id,name,tier_ids,allow_reentry,valid_from,valid_until,entry_day)
         SELECT event_id,n,tier_ids,true,valid_from,valid_until,entry_day FROM exos_checkin_lists,
                (VALUES ('Day 3 east'), ('Day 3 west')) v(n)
          WHERE event_id='$E' AND name='Day 3';
       INSERT INTO exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
         SELECT k, '$E', '$O', (SELECT id FROM exos_ticket_tiers WHERE event_id='$E' AND name=n), n, '$B', '$B', 'b@race-fd.test',
                'active', 'sek-' || k, 35, 'cs_race_fd_$RUN', 'stripe'
           FROM (VALUES ('$K1'::uuid, '3-day pass'), ('$K2'::uuid, 'Any-day pass'), ('$K3'::uuid, '3-day pass'),
                        ('$K4'::uuid, '3-day pass'), ('$K5'::uuid, '3-day pass')) v(k, n);
       INSERT INTO exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status,event_id,created_at,updated_at)
         VALUES ('$TR','$K4','$O','$B','friend@race-fd.test','pending','$E',now(),now());" >/dev/null
list() { $P -c "SELECT id FROM exos_checkin_lists WHERE event_id='$E' AND name='$1'"; }
L3=$(list 'Day 3'); L3N=$(list 'Day 3 north'); L1=$(list 'Day 1'); L2=$(list 'Day 2')
# One scan as the scanner, held open for $5 seconds before committing.
# Args: ticket, list, scan time SQL (or NULL for live), hold seconds.
scan_sql() {
  local at="$3"
  local code_at="coalesce($at, clock_timestamp())"
  echo "BEGIN; SET app.uid TO '$S';
        SELECT public.exos_check_in_ticket('$1','camera','verified',
          (SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' || public._exos_door_code_mac(t.id, t.owner_id, b, t.barcode_secret)
             FROM exos_tickets t, (SELECT floor(extract(epoch FROM $code_at) * 1000 / 30000)::bigint AS b) x WHERE t.id='$1'),
          '$E', NULL, $at, 'race', '$2', 'entry') ->> 'reason';
        SELECT pg_sleep($4); COMMIT;"
}
fail=0

# race 1: same day, two gates, one 3-day pass.
OUT1=$(mktemp); OUT2=$(mktemp)
$P -c "$(scan_sql "$K1" "$L3" NULL 2)" >"$OUT1" 2>&1 &
sleep 0.5
$P -c "$(scan_sql "$K1" "$L3N" NULL 0)" >"$OUT2" 2>&1
wait
r1=$(cat "$OUT1"); r2=$(cat "$OUT2")
n=$($P -c "SELECT count(*) FROM exos_event_checkins WHERE ticket_id='$K1' AND direction='entry'")
if [[ "$r1" == *checked-in* && "$r2" == *used* && "$n" == 1 ]]; then
  echo "OK   race 1 two gates of one day: one admits, the other 'used', one entry row"
else
  echo "FAIL race 1: [$r1] [$r2] entries $n"; fail=1
fi

# race 2: the any-day pass at day 1 and day 2 at once (offline replays).
$P -c "$(scan_sql "$K2" "$L1" "($(day 2 12:00))" 2)" >"$OUT1" 2>&1 &
sleep 0.5
$P -c "$(scan_sql "$K2" "$L2" "($(day 1 12:00))" 0)" >"$OUT2" 2>&1
wait
r1=$(cat "$OUT1"); r2=$(cat "$OUT2")
n=$($P -c "SELECT count(*) FROM exos_event_checkins WHERE ticket_id='$K2' AND direction='entry'")
if [[ "$r1" == *checked-in* && "$r2" == *day-limit* && "$n" == 1 ]]; then
  echo "OK   race 2 an any-day pass on two days at once: one admits, the other 'day-limit'"
else
  echo "FAIL race 2: [$r1] [$r2] entries $n"; fail=1
fi

# race 3: two tabs set up the same fair.
SETUP="BEGIN; SET app.uid TO '$A'; SELECT public.exos_fair_setup('$E2', $PLAN) ->> 'ok';"
$P -c "$SETUP SELECT pg_sleep(2); COMMIT;" >"$OUT1" 2>&1 &
sleep 0.5
$P -c "$SETUP COMMIT;" >"$OUT2" 2>&1 || true
wait
r1=$(cat "$OUT1"); r2=$(cat "$OUT2")
n=$($P -c "SELECT count(*) FROM exos_checkin_lists WHERE event_id='$E2'")
if [[ "$r1" == true && "$r2" == *"already has fair-day lists"* && "$n" == 3 ]]; then
  echo "OK   race 3 two fair setups at once: one sets it up, the other is refused; 3 lists"
else
  echo "FAIL race 3: [$r1] [$r2] lists $n"; fail=1
fi
# races 4-5: used on day 1 first, then the state changes while a day 3 gate scans.
for k in "$K3" "$K4"; do
  $P -c "$(scan_sql "$k" "$L1" "($(day 2 12:00))" 0)" >/dev/null
done
race_state() {  # $1 ticket, $2 the UPDATE's SET clause, $3 expected reason, $4 label
  $P -c "BEGIN; UPDATE exos_tickets SET $2 WHERE id='$1'; SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 &
  sleep 0.5
  $P -c "$(scan_sql "$1" "$L3" NULL 0)" >"$OUT2" 2>&1
  wait
  local r n
  r=$(cat "$OUT2")
  n=$($P -c "SELECT count(*) FROM exos_event_checkins WHERE ticket_id='$1' AND list_id='$L3'")
  if [[ "$r" == *"$3"* && "$n" == 0 ]]; then
    echo "OK   $4: '$3', no entry"
  else
    echo "FAIL $4: [$r] day 3 entries $n"; fail=1
  fi
}
race_state "$K3" "status='voided', voided_at=now()" voided "race 4 refunded while a day gate scans it"
race_state "$K4" "pending_transfer_id='$TR'" in-transfer "race 5 transfer started while a day gate scans it"
# race 6: two re-entry gates of one day at once.
L3E=$(list 'Day 3 east'); L3W=$(list 'Day 3 west')
$P -c "$(scan_sql "$K5" "$L3E" NULL 2)" >"$OUT1" 2>&1 &
sleep 0.5
$P -c "$(scan_sql "$K5" "$L3W" NULL 0)" >"$OUT2" 2>&1
wait
r1=$(cat "$OUT1"); r2=$(cat "$OUT2")
n=$($P -c "SELECT count(*) FROM exos_event_checkins WHERE ticket_id='$K5' AND direction='entry'")
if [[ "$r1" == *checked-in* && "$r2" == *already-inside* && "$n" == 1 ]]; then
  echo "OK   race 6 two re-entry gates of one day at once: one admits, the other 'already-inside'"
else
  echo "FAIL race 6: [$r1] [$r2] entries $n"; fail=1
fi
rm -f "$OUT1" "$OUT2"
exit $fail
