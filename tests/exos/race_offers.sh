#!/usr/bin/env bash
# Concurrency checks for offers, settlements and ticket counts (migs
# 20261031100000 / 20261031100500): real sessions racing. Not in CI
# (timing-based); run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_offers.sh exos_p0_test
# Expect: race 1 one answer recorded, the other refused (55000); race 2 one
# finalize, the other refused; race 3 the overlapping runs queue each mail
# once (2 mails, not 4).
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=ce000000-0000-0000-0000-000000000001; A=ce000000-0000-0000-0000-0000000000a0
E=ce000000-0000-0000-0000-0000000000e1
cleanup() {
  $P -c "DELETE FROM exos_mail WHERE to_email LIKE '%@race-offers.example';
         DELETE FROM exos_mail_dedupe WHERE dedupe_key LIKE 'tc:$E:%' OR dedupe_key LIKE 'settlement:$E:%';
         DELETE FROM exos_ticket_count_schedules WHERE event_id='$E'; DELETE FROM exos_settlements WHERE event_id='$E';
         DELETE FROM exos_event_contacts WHERE event_id='$E'; DELETE FROM exos_offers WHERE org_id='$O';
         DELETE FROM exos_budgets WHERE org_id='$O'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-offers.example',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race offers','race-offers','$A');
       INSERT INTO exos_events(id,org_id,name,status,starts_at,timezone) VALUES ('$E','$O','Race','published',now() + interval '10 days','UTC');
       INSERT INTO exos_event_contacts(event_id,org_id,role,name,email) VALUES
         ('$E','$O','agent','A','a@race-offers.example'), ('$E','$O','agent','B','b@race-offers.example');" >/dev/null
OFFER=$($P -c "SELECT public._exos_offer_save('$O','$A','api',NULL,NULL,'{\"artist_name\":\"Race act\",\"agent\":{\"email\":\"agent@race-offers.example\"}}')->>'id'")
TOKEN=$($P -c "SELECT substring(public._exos_offer_send('$O','$A','$OFFER',NULL)->>'link_path' FROM 't=([0-9a-f]{64})')")

echo "race 1: two answers on one link at once"
( $P -c "BEGIN; SELECT 'first: '||(public.exos_offer_respond('$OFFER','$TOKEN','accept','One')->>'status'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second: '||(public.exos_offer_respond('$OFFER','$TOKEN','decline','Two')->>'status');" 2>&1 | grep -o "second: [a-z]*\|can't be answered" | sed 's/^/  /' || true
wait
$P -c "SELECT '  -> status='||status||', answered by '||(response->>'name') FROM exos_offers WHERE id='$OFFER'"

echo "race 2: two finalizes at once"
$P -c "SELECT public._exos_settlement_get('$O','$E') IS NOT NULL" >/dev/null
( $P -c "BEGIN; SELECT 'first: '||(public._exos_settlement_finalize('$O','$A','$E')->>'status'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second: '||(public._exos_settlement_finalize('$O','$A','$E')->>'status');" 2>&1 | grep -o "second: [a-z]*\|already finalized" | sed 's/^/  /' || true
wait
$P -c "SELECT '  -> status='||status||', revision='||revision FROM exos_settlements WHERE event_id='$E'"

echo "race 3: two ticket-count runs at once"
$P -c "SELECT public._exos_tc_save('$O','$E','{\"enabled\":true}') IS NOT NULL;
       UPDATE exos_ticket_count_schedules SET next_run_at = now() - interval '1 minute' WHERE event_id='$E';" >/dev/null
( $P -c "BEGIN; SELECT 'first run: '||(public.exos_ticket_counts_run(25)->>'queued'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second run: '||(public.exos_ticket_counts_run(25)->>'queued')" | sed 's/^/  /'
wait
$P -c "SELECT '  -> mails queued: '||count(*) FROM exos_mail WHERE template='ticket-counts' AND to_email LIKE '%@race-offers.example'"
cleanup
