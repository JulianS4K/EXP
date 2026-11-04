#!/usr/bin/env bash
# Concurrency checks for brackets, imports and backfills (mig 20261102120000):
# real sessions racing. Not in CI (timing-based); run by hand against a DB
# built by run_p0.sh:
#   bash tests/exos/race_finance_extras.sh exos_p0_test
# Expect: race 1 one bracket basis wins, the other is refused; race 2 the
# same line imported twice at once is created once and `exists` once; race 3
# two backfills at once: the second waits and creates nothing.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=fd000000-0000-0000-0000-000000000001; A=fd000000-0000-0000-0000-0000000000a0
E=fd000000-0000-0000-0000-0000000000e1
cleanup() {
  $P -c "DELETE FROM exos_reporting_rows WHERE org_id='$O'; DELETE FROM exos_imported_ledger_entries WHERE org_id='$O';
         DELETE FROM exos_deal_brackets WHERE org_id='$O'; DELETE FROM exos_offers WHERE org_id='$O';
         DELETE FROM exos_budgets WHERE org_id='$O'; DELETE FROM exos_checkout_sessions WHERE org_id='$O';
         DELETE FROM exos_events WHERE id='$E'; DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-fin.example',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race finance','race-finance','$A');
       INSERT INTO exos_events(id,org_id,name,status,starts_at,timezone,currency) VALUES ('$E','$O','Race','published',now() + interval '10 days','UTC','USD');
       INSERT INTO exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status)
       VALUES ('cs_race_fin','$E','$O','$A','a@race-fin.example',1,5000,'usd','fulfilled');" >/dev/null
OFFER=$($P -c "SELECT public._exos_offer_save('$O','$A','api',NULL,NULL,'{\"artist_name\":\"Race act\"}')->>'id'")

echo "race 1: two brackets with different bases at once"
( $P -c "BEGIN; INSERT INTO exos_deal_brackets(offer_id,basis,threshold,percentage) VALUES ('$OFFER','amount',100,90); SELECT '  first: amount'; SELECT pg_sleep(2); COMMIT;" ) &
sleep 0.5
$P -c "INSERT INTO exos_deal_brackets(offer_id,basis,threshold,percentage) VALUES ('$OFFER','tickets',10,95); SELECT '  second: tickets';" 2>&1 \
  | grep -o "second: tickets\|same basis" | sed 's/^/  /' || true
wait
$P -c "SELECT '  -> bases: '||string_agg(DISTINCT basis, ',') FROM exos_deal_brackets WHERE offer_id='$OFFER'"

echo "race 2: the same line imported twice at once"
ROW='[{"source":"bar","amount_cents":100,"posted_at":"2026-11-01","source_system":"race","source_line_id":"r1"}]'
( $P -c "BEGIN; SELECT '  first: '||(public._exos_ledger_import('$O',NULL,'api',NULL,'$ROW')->'results'->0->>'status'); SELECT pg_sleep(2); COMMIT;" ) &
sleep 0.5
$P -c "SELECT '  second: '||(public._exos_ledger_import('$O',NULL,'api',NULL,'$ROW')->'results'->0->>'status')"
wait
$P -c "SELECT '  -> entries: '||count(*) FROM exos_imported_ledger_entries WHERE org_id='$O'"

echo "race 3: two backfills at once"
( $P -c "BEGIN; SELECT '  first: created '||(public._exos_gl_backfill('$O','$E')->>'created'); SELECT pg_sleep(2); COMMIT;" ) &
sleep 0.5
$P -c "SELECT '  second: created '||(public._exos_gl_backfill('$O','$E')->>'created')"
wait
$P -c "SELECT '  -> rows: '||count(*) FROM exos_reporting_rows WHERE event_id='$E' AND source_type <> 'imported'"
cleanup
