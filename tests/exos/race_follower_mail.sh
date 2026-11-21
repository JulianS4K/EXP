#!/usr/bin/env bash
# Follower "new event" mail races (migs 20261111110000, 20261112100000): a
# publish only records notices; the digest job (exos_send_follower_digests)
# builds and queues the mail. Whatever runs at once, a follower gets ONE mail
# per org per 24 hours (the slot), and every event exactly one notice. Real
# parallel sessions, timing-based, so run by hand against a DB built by
# run_p0.sh:
#   bash tests/exos/race_follower_mail.sh exos_p0_test
# Expect:
#   race 1 a digest held open (uncommitted) while a second digest runs: the
#          second waits on the notice rows, finds them queued; one mail
#   race 2 six publishes at the same moment, then six digests at once: six
#          pending notices, then one mail with all six, none lost or doubled
#   race 3 a digest held open while e2 publishes and a second digest runs:
#          the second waits on the slot, finds it used; one mail, e2 waits
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

digest() { $P -c "SELECT public.exos_send_follower_digests(500)" >/dev/null; }
held_digest() { $P -c "BEGIN; SELECT public.exos_send_follower_digests(500); SELECT pg_sleep(2); COMMIT;" >/dev/null; }

# race 1: a digest is held open; a second one runs meanwhile.
fresh
publish 1; publish 2
held_digest &
sleep 0.5
digest
wait
if [[ "$(mails)" == 1 && "$(notices)" == "2/0/2" ]]; then
  echo "OK   race 1 digest during an uncommitted digest: one mail with both events"
else
  echo "FAIL race 1: mails $(mails), queued/pending/all $(notices)"; fail=1
fi

# race 2: six publishes at once, then six digests at once.
fresh
for i in 1 2 3 4 5 6; do publish "$i" & done
wait
pre="$(mails) $(notices)"
for i in 1 2 3 4 5 6; do digest & done
wait
if [[ "$pre" == "0 0/6/6" && "$(mails)" == 1 && "$(notices)" == "6/0/6" ]]; then
  echo "OK   race 2 six publishes at once queue nothing; six digests at once: one mail with all six"
else
  echo "FAIL race 2: before the digests $pre; mails $(mails), queued/pending/all $(notices)"; fail=1
fi

# race 3: a digest holds e1's slot open; e2 publishes and a second digest runs.
fresh
publish 1
held_digest &
sleep 0.5
publish 2
digest
wait
if [[ "$(mails)" == 1 && "$(notices)" == "1/1/2" ]]; then
  echo "OK   race 3 publish + digest during an uncommitted digest: one mail, the other event waits"
else
  echo "FAIL race 3: mails $(mails), queued/pending/all $(notices)"; fail=1
fi
exit $fail
