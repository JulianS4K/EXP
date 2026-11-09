#!/usr/bin/env bash
# Follower "new event" mail races (mig 20261111110000): two events of one org
# going live at once must queue ONE mail to a follower (the 24-hour slot),
# with the other event left waiting for the next window. Real parallel
# sessions, timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_follower_mail.sh exos_p0_test
# Expect:
#   race 1 publish e1 held open (uncommitted) while e2 publishes: e2 waits on
#          the slot row, then finds it used and stays pending; one mail
#   race 2 six events published at the same moment in six sessions: one
#          mail, five notices pending, none lost or doubled
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=f0a10000-0000-0000-0000-000000000001; OW=f0a10000-0000-0000-0000-0000000000a1
F=f0a10000-0000-0000-0000-0000000000f1
ev() { printf 'f0a10000-0000-0000-0000-0000000000e%s' "$1"; }
cleanup() {
  $P -c "DELETE FROM exos_mail WHERE to_email='race-follower@race-fm.test';
         DELETE FROM exos_mail_dedupe WHERE dedupe_key LIKE 'follower-new-event:%:$F';
         DELETE FROM exos_events WHERE org_id='$O';
         DELETE FROM exos_org_follows WHERE org_id='$O'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id IN ('$OW','$F');" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$OW','owner@race-fm.test',now()), ('$F','race-follower@race-fm.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race FM','race-fm','$OW');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$OW','owner');
       INSERT INTO exos_org_follows(follower_uid,org_id) VALUES ('$F','$O');" >/dev/null
fresh() {
  $P -c "DELETE FROM exos_mail WHERE to_email='race-follower@race-fm.test';
         DELETE FROM exos_mail_dedupe WHERE dedupe_key LIKE 'follower-new-event:%:$F';
         DELETE FROM exos_follower_mail_slots WHERE org_id='$O';
         DELETE FROM exos_events WHERE org_id='$O';" >/dev/null
  for i in 1 2 3 4 5 6; do
    $P -c "INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,currency,created_by)
           VALUES ('$(ev $i)','$O','Race FM $i','race-fm-$i','draft',now() + interval '5 days','America/New_York',0,0,'usd','$OW');" >/dev/null
  done
}
publish() { $P -c "UPDATE exos_events SET status='published' WHERE id='$(ev "$1")'" >/dev/null; }
mails() { $P -c "SELECT count(*) FROM exos_mail WHERE to_email='race-follower@race-fm.test' AND template='follower-new-event'"; }
notices() { $P -c "SELECT count(*) FILTER (WHERE status='queued') || '/' || count(*) FILTER (WHERE status='pending') || '/' || count(*)
                   FROM exos_follower_notices WHERE org_id='$O'"; }
fail=0

# race 1: e1's publish is held open; e2 publishes meanwhile.
fresh
$P -c "BEGIN; UPDATE exos_events SET status='published' WHERE id='$(ev 1)'; SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
publish 2
wait
if [[ "$(mails)" == 1 && "$(notices)" == "1/1/2" ]]; then
  echo "OK   race 1 publish during an uncommitted publish: one mail, the other event waits"
else
  echo "FAIL race 1: mails $(mails), queued/pending/all $(notices)"; fail=1
fi

# race 2: six publishes at once.
fresh
for i in 1 2 3 4 5 6; do publish "$i" & done
wait
if [[ "$(mails)" == 1 && "$(notices)" == "1/5/6" ]]; then
  echo "OK   race 2 six publishes at once: one mail, five waiting"
else
  echo "FAIL race 2: mails $(mails), queued/pending/all $(notices)"; fail=1
fi
exit $fail
