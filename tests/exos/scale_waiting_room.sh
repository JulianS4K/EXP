#!/usr/bin/env bash
# Waiting room at scale (mig 20261118120000): every anonymous-path statement
# timed against a line of N places (default 200,000), under prod's
# statement_timeout (anon 3 s, authenticated 8 s). By hand, against a DB
# built by run_p0.sh (it adds one event and removes it after):
#   bash tests/exos/scale_waiting_room.sh exos_p0_test 200000
# Prints one line per call: what, ms, and OK / FAIL (FAIL = over 1 s for an
# anonymous call, or any error). docs/load-test.md "Scale check" has a run.
set -euo pipefail
DB="${1:-exos_p0_test}"
N="${2:-200000}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=e7f00000-0000-0000-0000-000000000001; A=e7f00000-0000-0000-0000-0000000000a1
EV=e7f00000-0000-0000-0000-0000000000e1; T=e7f00000-0000-0000-0000-0000000000c1
cleanup() {
  $P -c "DELETE FROM exos_wroom_entries WHERE event_id='$EV'; DELETE FROM exos_wroom_counts WHERE event_id='$EV';
         DELETE FROM exos_wroom_settings WHERE event_id='$EV'; DELETE FROM exos_cart_holds WHERE event_id='$EV';
         DELETE FROM exos_ticket_tiers WHERE event_id='$EV'; DELETE FROM exos_events WHERE id='$EV';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
trap cleanup EXIT
FRONT=$(printf 'f%.0s' $(seq 1 64)); BACK=$(printf 'e%.0s' $(seq 1 64)); IDLE=$(printf 'd%.0s' $(seq 1 64)); ADM=$(printf 'a%.0s' $(seq 1 64))
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@scale-wr.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Scale WR','scale-wr','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,created_by,link_out)
         VALUES ('$EV','$O','Scale WR','scale-wr','published',now() + interval '30 days','America/New_York',1000000,'$A',false);
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sales_start,visibility)
         VALUES ('$T','$EV','GA',20,1000000,now() - interval '1 minute','public');
       INSERT INTO exos_wroom_settings(event_id,org_id,enabled,window_minutes,admit_per_minute,admission_minutes,idle_close_minutes,
                                      max_entries,enabled_at,first_admit_at)
         VALUES ('$EV','$O',true,0,20000,10,30,1000000,now() - interval '10 minutes',now() - interval '5 minutes');" >/dev/null
echo "seeding $N places ..."
t0=$(date +%s)
$P -c "INSERT INTO exos_wroom_entries(org_id,event_id,run_id,token_hash,net_hash,net32_hash,order_key,state,last_seen_at,admitted_at,admit_expires_at)
       SELECT '$O','$EV',s.run_id, encode(sha256(convert_to('scale-' || g, 'UTF8')), 'hex'),
              encode(sha256(convert_to('n-' || (g % 50000), 'UTF8')), 'hex'), encode(sha256(convert_to('m-' || (g % 5000), 'UTF8')), 'hex'),
              CASE WHEN g % 2 = 0 THEN random() ELSE 1 + g END,
              CASE WHEN g % 20 = 0 THEN 'admitted' ELSE 'waiting' END,
              CASE WHEN g % 10 = 1 THEN now() - interval '40 minutes' WHEN g % 10 = 3 THEN now() - interval '5 minutes' ELSE now() END,
              CASE WHEN g % 20 = 0 THEN now() - interval '20 minutes' END,
              CASE WHEN g % 20 = 0 THEN now() - interval '10 minutes' END
         FROM exos_wroom_settings s, generate_series(1, $N) g WHERE s.event_id = '$EV';
       INSERT INTO exos_wroom_entries(org_id,event_id,run_id,token_hash,net_hash,net32_hash,order_key,last_seen_at)
       SELECT '$O','$EV',s.run_id, public._exos_wroom_hash('$EV', v.t), md5(v.t) || md5(v.t), md5(v.t) || md5(v.t), v.k, v.seen
         FROM exos_wroom_settings s,
              (VALUES ('$FRONT', 0.0::float8, now()), ('$BACK', 1e12::float8, now() - interval '30 seconds'),
                      ('$IDLE', 0.5::float8, now() - interval '5 minutes')) v(t, k, seen)
        WHERE s.event_id = '$EV';
       INSERT INTO exos_wroom_entries(org_id,event_id,run_id,token_hash,net_hash,net32_hash,order_key,state,admitted_at,admit_expires_at)
       SELECT '$O','$EV',s.run_id, public._exos_wroom_hash('$EV', '$ADM'), md5('a') || md5('a'), md5('a') || md5('a'), 0.0001,
              'admitted', now(), now() + interval '10 minutes'
         FROM exos_wroom_settings s WHERE s.event_id = '$EV';
       ANALYZE exos_wroom_entries;" >/dev/null
echo "seeded in $(( $(date +%s) - t0 )) s; $($P -c "SELECT count(*) FROM exos_wroom_entries WHERE event_id='$EV'") rows"
fail=0
# run <label> <role> <timeout> <expr>: one call in its own transaction, as
# PostgREST would (role, headers, statement_timeout), timed in the server.
run() {
  local out ms
  out=$($P -c "BEGIN; SELECT set_config('request.headers','{\"cf-connecting-ip\":\"203.0.113.$((RANDOM % 250))\"}',true),
                     set_config('app.uid', CASE WHEN '$2' = 'authenticated' THEN '$A' ELSE '' END, true);
              SET LOCAL statement_timeout = '$3'; SET LOCAL ROLE $2;
              DO \$d\$ DECLARE t0 timestamptz := clock_timestamp(); BEGIN PERFORM $4;
                RAISE NOTICE 'ms=%', round(extract(epoch FROM clock_timestamp() - t0) * 1000); END \$d\$;
              COMMIT;" 2>&1) || true
  ms=$(grep -o 'ms=[0-9]*' <<<"$out" | cut -d= -f2 || true)
  if [[ -n "$ms" ]]; then
    if [[ "$2" != "authenticated" && "$ms" -gt 1000 ]]; then echo "FAIL $1: $ms ms"; fail=1; else echo "OK   $1: $ms ms"; fi
  else
    echo "FAIL $1: $(tail -1 <<<"$out")"; fail=1
  fi
}
reset_round() { $P -c "UPDATE exos_wroom_settings SET advanced_at = now() - interval '6 seconds', admit_clock = now() - interval '60 seconds',
                         counted_at = now() - interval '6 seconds' WHERE event_id='$EV'" >/dev/null; }
reset_round
run "join: a new place (+ an admission round of 2,000)" anon 3s "public.exos_wroom_join('$EV')"
reset_round
run "status: the back of the line (10,000+ count)" anon 3s "public.exos_wroom_status('$EV', '$BACK')"
run "status: the front" anon 3s "public.exos_wroom_status('$EV', '$FRONT')"
run "status: within 5 s (cached)" anon 3s "public.exos_wroom_status('$EV', '$BACK')"
run "join: an existing place (its token; cached like a poll)" anon 3s "public.exos_wroom_join('$EV', '$BACK')"
run "status: an idle place coming back (shares + cap)" anon 3s "public.exos_wroom_status('$EV', '$IDLE')"
reset_round
run "recount: abandon batch (500) + live count (runs inside anon calls)" postgres 3s "public._exos_wroom_recount('$EV')"
reset_round
run "admission round alone, 2,000 (runs inside anon calls)" postgres 3s "public._exos_wroom_advance('$EV')"
run "join: a new place (no round due)" anon 3s "public.exos_wroom_join('$EV')"
run "checkout check (require, service role)" service_role 3s "public.exos_wroom_require('$EV','$T','$ADM',NULL,'a@x.com')"
run "organizer summary (authenticated, 8 s)" authenticated 8s "public.exos_wroom_summary('$EV')"
exit $fail
