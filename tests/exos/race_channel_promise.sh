#!/usr/bin/env bash
# One promise across platforms (mig 20261121100000): Eventbrite's and Luma's
# inventory applies of the same event run one at a time. Timing-based, run
# against a DB built by run_p0.sh:
#   bash tests/exos/race_channel_promise.sh exos_p0_test
# In CI (exos-sql job, about 5 s). Expect:
#   race 1 an Eventbrite apply holds its transaction open 1.5 s; a Luma apply
#          of the same event started meanwhile waits for it (>= 1 s), then
#          sees Eventbrite's new target: together they never offer more than
#          the shared pool
#   race 2 a Luma apply of ANOTHER event doesn't wait (the lock is per event)
#   race 3 two owners link the same event to two different Eventbrite events
#          at once (exos_channel_set): one wins, the other is refused (the
#          per-event channel lock), never silently ignored
# Its fixtures are removed afterwards.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
RUN=$($P -c "SELECT substr(md5(random()::text || clock_timestamp()::text), 1, 8)")
id() { $P -c "SELECT md5('race-cp:$RUN:$1')::uuid"; }
O=$(id org); A=$(id owner); E=$(id event); T=$(id tier); E2=$(id event2); T2=$(id tier2)
EB=$($P -c "SELECT (abs(hashtext('$RUN')) % 900000 + 100000)::text")
cleanup() {
  $P -c "DELETE FROM exos_luma_ticket_links WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_channel_mirrors WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_eventbrite_ticket_links WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_eventbrite_links WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_guest_lists WHERE event_id IN ('$E','$E2');
         DELETE FROM exos_eventbrite_accounts WHERE org_id='$O';
         DELETE FROM exos_ticket_tiers WHERE id IN ('$T','$T2'); DELETE FROM exos_events WHERE id IN ('$E','$E2');
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id='$A';" >/dev/null 2>&1 || true
}
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner-$RUN@race-cp.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race CP','race-cp-$RUN','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,purchase_limits,created_by) VALUES
         ('$E','$O','Race CP','race-cp-$RUN','published',now()+interval '3 days',0,'{\"maxPerOrder\":4}','$A'),
         ('$E2','$O','Race CP 2','race-cp2-$RUN','published',now()+interval '3 days',0,'{\"maxPerOrder\":4}','$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$T','$E','GA',40,100,0),('$T2','$E2','GA',40,100,0);
       INSERT INTO exos_channel_mirrors (event_id, provider, org_id, mode, external_id, status) VALUES
         ('$E','luma','$O','link','evt-racecp$RUN','synced'),('$E2','luma','$O','link','evt-racecq$RUN','synced');
       INSERT INTO exos_luma_ticket_links (event_id, luma_event_id, luma_ticket_type_id, luma_ticket_name, tier_id) VALUES
         ('$E','evt-racecp$RUN','lt-$RUN','GA','$T'),('$E2','evt-racecq$RUN','lu-$RUN','GA','$T2');" >/dev/null
$P -c "SELECT public.exos_eventbrite_connect('$O', '$A', 'TOKENRACECP$RUN', 'Race CP');
       SELECT public.exos_eventbrite_link('$E', '$A', '$EB', 'Race CP on Eventbrite');
       SELECT public.exos_eventbrite_map_ticket('$E', '$A', '9$EB', 'GA', '$T');" >/dev/null
fail=0
luma_apply() { $P -c "SELECT x.target_capacity FROM public.exos_luma_inventory_apply('$1', '[{\"id\":\"$2\",\"sold\":0}]', clock_timestamp()) x"; }

# race 1: the same event.
$P -c "BEGIN; SELECT count(*) FROM public.exos_eventbrite_inventory_apply('$E', '[{\"id\":\"9$EB\",\"capacity\":96,\"quantity_sold\":0}]', clock_timestamp());
       SELECT pg_sleep(1.5); COMMIT;" >/dev/null &
holder=$!
sleep 0.3
t0=$(date +%s%N)
lu=$(luma_apply "$E" "lt-$RUN")
t1=$(date +%s%N)
wait $holder
waited=$(( (t1 - t0) / 1000000 ))
promised=$($P -c "SELECT coalesce(sum(outstanding),0) FROM public._exos_channel_outstanding('$E')")
pool=$($P -c "SELECT greatest(public.exos_effective_available('$T') - 4, 0)")
eb=$($P -c "SELECT target_capacity FROM exos_eventbrite_ticket_links WHERE event_id='$E'")
if [ "$waited" -ge 1000 ] && [ "$promised" -le "$pool" ]; then
  echo "race 1 ok: Luma waited ${waited} ms; Eventbrite target $eb, Luma $lu, promised $promised of $pool"
else
  echo "race 1 FAILED: waited ${waited} ms; Eventbrite $eb, Luma $lu, promised $promised of $pool"; fail=1
fi

# race 2: another event isn't held up.
$P -c "BEGIN; SELECT count(*) FROM public.exos_eventbrite_inventory_apply('$E', '[{\"id\":\"9$EB\",\"capacity\":96,\"quantity_sold\":0}]', clock_timestamp());
       SELECT pg_sleep(1.5); COMMIT;" >/dev/null &
holder=$!
sleep 0.3
t0=$(date +%s%N)
luma_apply "$E2" "lu-$RUN" >/dev/null
t1=$(date +%s%N)
wait $holder
waited=$(( (t1 - t0) / 1000000 ))
if [ "$waited" -lt 1000 ]; then echo "race 2 ok: another event ran in ${waited} ms"; else echo "race 2 FAILED: waited ${waited} ms"; fail=1; fi

# race 3: two links of one event to two Eventbrite events at once.
setlink() {
  $P -c "SET ROLE authenticated; SELECT set_config('app.uid', '$A', false), set_config('app.jwt', '', false);
         SELECT public.exos_channel_set('$E2', 'eventbrite', 'link', '$1');" >/dev/null 2>&1 && echo ok || echo refused
}
$P -c "SELECT pg_advisory_lock(hashtextextended('exos_channel_set:' || '$E2', 0)); SELECT pg_sleep(1.0);
       SELECT pg_advisory_unlock(hashtextextended('exos_channel_set:' || '$E2', 0));" >/dev/null &
holder=$!
sleep 0.3
o1=$(mktemp); o2=$(mktemp)
setlink "7${EB}1" >"$o1" & p1=$!
setlink "7${EB}2" >"$o2" & p2=$!
wait $p1 $p2 $holder
wins=$(cat "$o1" "$o2" | grep -c '^ok$' || true)
kept=$($P -c "SELECT external_id FROM exos_channel_mirrors WHERE event_id='$E2' AND provider='eventbrite'")
rm -f "$o1" "$o2"
if [ "$wins" -eq 1 ] && [ -n "$kept" ]; then echo "race 3 ok: one link won ($kept), the other refused"; else echo "race 3 FAILED: $wins won, kept $kept"; fail=1; fi
exit $fail
