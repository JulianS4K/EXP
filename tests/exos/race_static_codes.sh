#!/usr/bin/env bash
# Static door codes (claude/exos-static-tickets, mig 20261121153000), real
# parallel sessions; the first holds its transaction open (pg_sleep) so the
# second starts while it is uncommitted. Run against a DB built by run_p0.sh
# (CI does):
#   bash tests/exos/race_static_codes.sh exos_p0_test
# Expect:
#   race 1 (ROUNDS tickets) the same S- code at two doors at once: one
#          'checked-in', the other 'used' (the atomic status flip), one
#          admission. Issued static on the static-code path
#          (exos.static_code_ok), so the free-tier setting doesn't matter.
#   race 2 (ROUNDS events) the last static place: an event at the cutoff with
#          cutoff - 1 tickets, two tickets issued at once (the counters not
#          bumped, as a path that counts after inserting): exactly one static
#          (_exos_ticket_code_mode's per-event lock). The cutoff is the
#          shipped default (the setting is lifted for the race, then put back).
# Exits 1 otherwise.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
ROUNDS="${ROUNDS:-5}"
O=5c500000-0000-0000-0000-000000000001; A=5c500000-0000-0000-0000-0000000000a0; HOLDER=5c500000-0000-0000-0000-0000000000c1
E=5c500000-0000-0000-0000-0000000000e1; T=5c500000-0000-0000-0000-0000000000d1
tk() { printf '5c500000-0000-0000-0000-0000000c%04d' "$1"; }
# The free-tier setting as found (run_p0.sh turns it off), put back on exit.
SAVED=$($P -c "SELECT value::text FROM exos_platform_settings WHERE key='free_tier_max_capacity'")
cleanup() {
  $P -c "DELETE FROM exos_scan_rejects WHERE org_id='$O'; DELETE FROM exos_event_checkins WHERE org_id='$O';
         DELETE FROM exos_tickets WHERE org_id='$O'; DELETE FROM exos_ticket_tiers WHERE event_id IN (SELECT id FROM exos_events WHERE org_id='$O');
         DELETE FROM exos_events WHERE org_id='$O'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id IN ('$A','$HOLDER');" >/dev/null
  if [ -n "$SAVED" ]; then
    $P -c "INSERT INTO exos_platform_settings (key, value) VALUES ('free_tier_max_capacity', '$SAVED'::jsonb)
           ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value" >/dev/null
  else
    $P -c "DELETE FROM exos_platform_settings WHERE key='free_tier_max_capacity'" >/dev/null
  fi
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-static.test',now()),('$HOLDER','fan@race-static.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race static','race-static','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,currency,created_by)
         VALUES ('$E','$O','Race','race-static','published',now() - interval '1 hour',100,0,'usd','$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES ('$T','$E','GA',20,100,0,'public',1);
       SELECT set_config('exos.static_code_ok', 'on', true);
       INSERT INTO exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source,code_mode)
       SELECT ('5c500000-0000-0000-0000-0000000c' || lpad(n::text, 4, '0'))::uuid,'$E','$O','$T','GA','$HOLDER','$HOLDER','fan@race-static.test',
              'active','sek-static-'||n,20,'race-static-'||n,'stripe','static'
         FROM generate_series(1, $ROUNDS) n;" >/dev/null
AS="SELECT set_config('app.uid','$A',false);"
scan() { echo "public.exos_check_in_ticket('$1','camera','verified','$2','$E',NULL,NULL,'$3',NULL,'entry')->>'reason'"; }
fail=0
echo "race 1: one static code at two doors at once"
for i in $(seq 1 "$ROUNDS"); do
  t=$(tk "$i")
  code=$($P -c "SELECT public._exos_static_code(id, owner_id, barcode_secret) FROM exos_tickets WHERE id='$t'")
  out="$(mktemp)"
  ( $P -c "$AS BEGIN; SELECT 'first '||($(scan "$t" "$code" door-1)); SELECT pg_sleep(2); COMMIT;" 2>&1 | grep -o "first [a-z-]*\|ERROR: .*" >>"$out" || true ) &
  sleep 0.5
  ( $P -c "$AS SELECT 'second '||($(scan "$t" "$code" door-2));" 2>&1 | grep -o "second [a-z-]*\|ERROR: .*" >>"$out" || true )
  wait
  n=$($P -c "SELECT count(*) FROM exos_event_checkins WHERE ticket_id='$t' AND direction='entry'")
  answers=$(sort "$out" | tr '\n' ' ')
  rm -f "$out"
  echo "round $i: $answers-> admissions=$n"
  if [ "$n" != 1 ] || ! grep -q "first checked-in" <<<"$answers" || ! grep -q "second used" <<<"$answers"; then
    echo "::error::race_static_codes round $i: expected one checked-in, one used, one admission" >&2
    fail=1
  fi
done

echo "race 2: two tickets for the last static place at once"
$P -c "DELETE FROM exos_platform_settings WHERE key='free_tier_max_capacity'" >/dev/null
CUT=$($P -c "SELECT public.exos_free_tier_max_capacity()")
issue() { echo "INSERT INTO exos_tickets(event_id,org_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
               VALUES ('$1','$O','GA','$HOLDER','$HOLDER','fan@race-static.test','active','sek-'||gen_random_uuid(),20,'race-cut','stripe')"; }
for i in $(seq 1 "$ROUNDS"); do
  ev=$(printf '5c500000-0000-0000-0000-00000000f%03d' "$i")
  $P -c "INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,currency,created_by)
           VALUES ('$ev','$O','Race cut $i','race-static-cut-$i','published',now() + interval '1 day',$CUT,0,'usd','$A');
         INSERT INTO exos_ticket_tiers(event_id,name,price,capacity,sold,visibility,sort_order) VALUES ('$ev','GA',20,$CUT,0,'public',1);
         INSERT INTO exos_tickets(event_id,org_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
         SELECT '$ev','$O','GA','$HOLDER','$HOLDER','fan@race-static.test','active','sek-'||gen_random_uuid(),20,'race-cut','stripe'
           FROM generate_series(1, $CUT - 1);" >/dev/null
  ( $P -c "BEGIN; $(issue "$ev"); SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 || echo "  first failed" ) &
  sleep 0.5
  ( $P -c "$(issue "$ev");" >/dev/null 2>&1 || echo "  second failed" )
  wait
  read -r st rot <<<"$($P -F ' ' -c "SELECT count(*) FILTER (WHERE code_mode='static'), count(*) FILTER (WHERE code_mode='rotating') FROM exos_tickets WHERE event_id='$ev'")"
  echo "round $i: cutoff=$CUT static=$st rotating=$rot (expect $CUT / 1)"
  if [ "$st" != "$CUT" ] || [ "$rot" != 1 ]; then
    echo "::error::race_static_codes race 2 round $i: $st static tickets for a cutoff of $CUT" >&2
    fail=1
  fi
done
exit "$fail"
