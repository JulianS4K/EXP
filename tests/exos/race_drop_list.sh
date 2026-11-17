#!/usr/bin/env bash
# Drop list blast races (mig 20261118100000): the on-sale blast claims each
# signup once, in real parallel sessions. Timing-based, so run by hand
# against a DB built by run_p0.sh:
#   bash tests/exos/race_drop_list.sh exos_p0_test
# Expect:
#   race 1 six sessions blast the same list at once, three times each: every
#          confirmed signup is mailed exactly once (one exos_mail row each, no
#          address twice), each number texted once (two signups share one
#          number: one text), one 'drop_list' campaign for the event
#   race 2 a blast is in flight (uncommitted) when a second starts: the second
#          waits on the event, then finds nothing left (0 mails)
#   race 3 the organizer sets a presale while a blast is in flight: it waits,
#          then is refused (the list has already been notified)
#   race 4 leave vs confirm, both orders: a leave in flight when the confirm
#          link is clicked (the confirm waits, then answers false), and a
#          confirm in flight when the leave comes (the leave waits, then
#          wins); either way the person ends off the list
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=d7a00000-0000-0000-0000-000000000001; A=d7a00000-0000-0000-0000-0000000000a1
E1=d7a00000-0000-0000-0000-0000000000e1; E2=d7a00000-0000-0000-0000-0000000000e2
T1=d7a00000-0000-0000-0000-0000000000c1; T2=d7a00000-0000-0000-0000-0000000000c2
T3=d7a00000-0000-0000-0000-0000000000c3
cleanup() {
  $P -c "DELETE FROM exos_mail_dedupe WHERE dedupe_key IN (SELECT 'drop-on-sale:' || id FROM exos_drop_signups WHERE org_id='$O');
         DELETE FROM exos_mail WHERE template = 'drop-on-sale' AND to_email LIKE '%@race-drop.test';
         DELETE FROM exos_sms_outbox WHERE org_id='$O'; DELETE FROM exos_sms_campaigns WHERE org_id='$O';
         DELETE FROM exos_org_integrations WHERE org_id='$O';
         DELETE FROM exos_drop_signups WHERE org_id='$O'; DELETE FROM exos_drop_settings WHERE org_id='$O';
         DELETE FROM exos_vouchers WHERE event_id IN ('$E1','$E2');
         DELETE FROM exos_ticket_tiers WHERE event_id IN (SELECT id FROM exos_events WHERE org_id='$O'); DELETE FROM exos_events WHERE org_id='$O';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-drop.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race Drop','race-drop','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_org_integrations(org_id,provider,status) VALUES ('$O','twilio','connected');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,created_by) VALUES
         ('$E1','$O','Race Drop One','race-drop-one','published',now() + interval '30 days','America/New_York',500,'$A'),
         ('$E2','$O','Race Drop Two','race-drop-two','published',now() + interval '30 days','America/New_York',500,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sales_start) VALUES
         ('$T1','$E1','GA',20,500,now() - interval '1 minute'),
         ('$T2','$E2','GA',20,500,now() - interval '1 minute'),
         ('$T3','$E2','Early',15,50,NULL);
       UPDATE exos_ticket_tiers SET visibility = 'hidden' WHERE id = '$T3';" >/dev/null
# 200 confirmed members on E1 (every 4th with a number; two share +12125559000), 50 on E2.
$P -c "INSERT INTO exos_drop_signups(org_id,event_id,email,email_consent_text,confirmed_at,sms_phone,sms_consent_text,sms_consented_at)
       SELECT '$O','$E1','fan' || g || '@race-drop.test', exos_drop_email_consent_text('Race Drop','Race Drop One'), now(),
              CASE WHEN g % 4 = 0 THEN '+1212555' || lpad((CASE WHEN g = 8 THEN 4 ELSE g END + 9000 - 4)::text, 4, '0') END,
              CASE WHEN g % 4 = 0 THEN exos_drop_sms_consent_text('Race Drop','Race Drop One') END,
              CASE WHEN g % 4 = 0 THEN now() END
         FROM generate_series(1, 200) g;
       INSERT INTO exos_drop_signups(org_id,event_id,email,email_consent_text,confirmed_at)
       SELECT '$O','$E2','two' || g || '@race-drop.test', exos_drop_email_consent_text('Race Drop','Race Drop Two'), now()
         FROM generate_series(1, 50) g;" >/dev/null
fail=0

# race 1: six sessions at once, three blasts of 40 each.
for i in 1 2 3 4 5 6; do
  $P -c "SELECT public.exos_drop_list_blast(40); SELECT public.exos_drop_list_blast(40); SELECT public.exos_drop_list_blast(40);" >/dev/null &
done
wait
# Whatever the 720 claims didn't reach (none expected), one more pass.
$P -c "SELECT public.exos_drop_list_blast(500)" >/dev/null
r=$($P -c "SELECT (SELECT count(*) FROM exos_drop_signups WHERE event_id='$E1' AND blasted_at IS NOT NULL) || ' ' ||
                  (SELECT count(*) FROM exos_mail WHERE template='drop-on-sale' AND payload->'event'->>'id'='$E1') || ' ' ||
                  (SELECT count(DISTINCT to_email) FROM exos_mail WHERE template='drop-on-sale' AND payload->'event'->>'id'='$E1') || ' ' ||
                  (SELECT count(*) FROM exos_sms_outbox o JOIN exos_sms_campaigns c ON c.id = o.campaign_id WHERE c.event_id='$E1') || ' ' ||
                  (SELECT count(DISTINCT o.phone) FROM exos_sms_outbox o JOIN exos_sms_campaigns c ON c.id = o.campaign_id WHERE c.event_id='$E1') || ' ' ||
                  (SELECT count(*) FROM exos_sms_campaigns WHERE event_id='$E1' AND audience='drop_list') || ' ' ||
                  (SELECT count(*) FROM exos_drop_signups WHERE event_id='$E1' AND sms_status='duplicate')")
if [[ "$r" == "200 200 200 49 49 1 1" ]]; then
  echo "OK   race 1 six parallel blasts: 200 members, 200 mails, 49 numbers texted once, one campaign"
else
  echo "FAIL race 1: blasted / mails / addresses / texts / numbers / campaigns / duplicates = $r"; fail=1
fi

# race 2 + 3: a blast of E2 held open; a second blast and a presale change start meanwhile.
$P -c "BEGIN; SELECT public.exos_drop_list_blast(500); SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
$P -c "SELECT public.exos_drop_list_blast(500)" >/dev/null 2>&1 &
presale=$($P -c "SELECT set_config('app.uid','$A',false); SELECT public.exos_drop_list_set_presale('$E2', 60, '$T3');" 2>&1 || true)
wait
second=$($P -c "SELECT count(*) FROM exos_mail WHERE template='drop-on-sale' AND payload->'event'->>'id'='$E2'")
dups=$($P -c "SELECT count(*) - count(DISTINCT to_email) FROM exos_mail WHERE template='drop-on-sale' AND payload->'event'->>'id'='$E2'")
if [[ "$second" == 50 && "$dups" == 0 ]]; then
  echo "OK   race 2 a blast during an uncommitted blast: waits, sends nothing twice (50 mails)"
else
  echo "FAIL race 2: mails $second, duplicates $dups"; fail=1
fi
if [[ "$presale" == *"already been notified"* && "$($P -c "SELECT count(*) FROM exos_vouchers WHERE event_id='$E2'")" == 0 ]]; then
  echo "OK   race 3 a presale set during an uncommitted blast: waits, then refused; no code minted"
else
  echo "FAIL race 3: $presale"; fail=1
fi
# race 4: leave vs confirm on one pending signup, both orders.
TOK=$(printf 'a%.0s' $(seq 64)); LV=$(printf 'b%.0s' $(seq 64))
E3=d7a00000-0000-0000-0000-0000000000e3; T4=d7a00000-0000-0000-0000-0000000000c4
SID=d7a00000-0000-0000-0000-00000000d001; CID=d7a00000-0000-0000-0000-00000000d002
$P -c "INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,created_by) VALUES
         ('$E3','$O','Race Drop Three','race-drop-three','published',now() + interval '30 days','America/New_York',500,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sales_start) VALUES ('$T4','$E3','GA',20,500,now() + interval '2 days');" >/dev/null
fresh_pending() {
  $P -c "DELETE FROM exos_drop_signups WHERE id='$SID';
         INSERT INTO exos_drop_signups(id,org_id,event_id,email,email_consent_text)
           VALUES ('$SID','$O','$E3','race4@race-drop.test', exos_drop_email_consent_text('Race Drop','Race Drop Three'));
         INSERT INTO exos_drop_confirms(id,signup_id,org_id,token_hash,code_hash,browser_token_hash,leave_hash)
           VALUES ('$CID','$SID','$O',_exos_drop_hash('$TOK'),repeat('0',64),repeat('0',64),_exos_drop_hash('$LV'));" >/dev/null
}
state() { $P -c "SELECT (left_at IS NOT NULL)::text || ' ' || (confirmed_at IS NOT NULL AND left_at IS NULL)::text FROM exos_drop_signups WHERE id='$SID'"; }
fresh_pending
$P -c "BEGIN; SELECT exos_drop_leave('$LV'); SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "SELECT exos_drop_confirm('$TOK')" 2>&1 || true)
wait
if [[ "$out" == '{"ok": false}' && "$(state)" == "true false" ]]; then
  echo "OK   race 4a a confirm during an uncommitted leave: waits, answers false, stays off"
else
  echo "FAIL race 4a: confirm $out / left, on = $(state)"; fail=1
fi
fresh_pending
$P -c "BEGIN; SELECT exos_drop_confirm('$TOK'); SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
$P -c "SELECT exos_drop_leave('$LV')" >/dev/null
wait
if [[ "$(state)" == "true false" && "$($P -c "SELECT count(*) FROM exos_drop_confirms WHERE signup_id='$SID' AND used_at IS NULL")" == 0 ]]; then
  echo "OK   race 4b a leave during an uncommitted confirm: waits, then wins; nothing left open"
else
  echo "FAIL race 4b: left, on = $(state)"; fail=1
fi
exit $fail
