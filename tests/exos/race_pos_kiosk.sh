#!/usr/bin/env bash
# Kiosk mode races (mig 20261113100000): real parallel sessions.
# Timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_pos_kiosk.sh exos_p0_test
# Expect:
#   race 1 two kiosks begin a sale for the last ticket at once: one pending
#          sale holds it, the other is told it's sold out
#   race 2 a kiosk sale and a door cash sale for the last ticket: one wins
#          (a pending kiosk hold or a paid door sale), never both
#   race 3 a double tap on one kiosk (the same order key from two sessions):
#          one pending sale, the second is a replay of it
#   race 4 ten wrong PINs at once on one kiosk: at most 4 'wrong-pin', the
#          rest 'locked' or 'rate'; the kiosk is locked, still in kiosk mode
#   race 5 two begins with different keys on one kiosk session at once: one
#          open sale, the other is refused ('kiosk-busy')
#   race 6 five charges of one sale at once, 8 minutes after its begin: the
#          hold never ends later than 10 minutes after the begin
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=c0b1ace0-0000-0000-0000-000000000001; A=c0b1ace0-0000-0000-0000-0000000000a1
E=c0b1ace0-0000-0000-0000-0000000000e1; T=c0b1ace0-0000-0000-0000-0000000000d1
K1=c0b1ace0-0000-0000-0000-0000000000c1; K2=c0b1ace0-0000-0000-0000-0000000000c2; RD=c0b1ace0-0000-0000-0000-0000000000c9
MADE_SECRETS=$($P -c "SELECT to_regclass('public.exos_org_secrets') IS NULL")
cleanup() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_pos_card_payments WHERE event_id='$E';
         DELETE FROM exos_pos_payments WHERE event_id='$E';
         DELETE FROM exos_question_answer_cursors WHERE event_id='$E';
         DELETE FROM exos_pos_orders WHERE event_id='$E'; DELETE FROM exos_pos_items WHERE event_id='$E';
         DELETE FROM exos_pos_drawer_sessions WHERE event_id='$E';
         DELETE FROM exos_pos_kiosk_sessions WHERE org_id='$O'; DELETE FROM exos_pos_kiosks WHERE org_id='$O';
         DELETE FROM exos_pos_terminal_readers WHERE org_id='$O'; DELETE FROM exos_pos_terminal_locations WHERE org_id='$O';
         DELETE FROM exos_pos_devices WHERE org_id='$O';
         DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM exos_rate_windows WHERE bucket LIKE 'pos:%';
         DELETE FROM auth.users WHERE id='$A';" >/dev/null
  if [ "$MADE_SECRETS" = "t" ]; then $P -c "DROP TABLE IF EXISTS public.exos_org_secrets;" >/dev/null
  else $P -c "DELETE FROM public.exos_org_secrets WHERE org_id='$O';" >/dev/null; fi
}
$P -c "CREATE TABLE IF NOT EXISTS public.exos_org_secrets (org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());" >/dev/null
cleanup
$P -c "CREATE TABLE IF NOT EXISTS public.exos_org_secrets (org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());" >/dev/null
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-kiosk.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race kiosk','race-kiosk','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_org_secrets(org_id,payments) VALUES ('$O','{\"connectedAccountId\":\"acct_raceKiosk\",\"chargesEnabled\":true}');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race fair','race-kiosk','published',now() + interval '1 hour',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,door_price_cents) VALUES
         ('$T','$E','Gate',15,1,0,'public',1500);
       INSERT INTO exos_pos_devices(id,org_id,name,kind,status) VALUES
         ('$K1','$O','Kiosk 1','register','active'),('$K2','$O','Kiosk 2','register','active');
       SELECT public._exos_pos_terminal_save_location('$A','$O',false,'tml_RaceKiosk','Gate','{\"line1\":\"1 Fair Rd\"}');" >/dev/null
RD=$($P -c "SELECT public._exos_pos_terminal_save_reader('$A','$O',false,'tmr_RaceKiosk','Gate reader',NULL,NULL) ->> 'device_id'" | tail -1)
tok() {  # device -> a fresh kiosk credential
  $P -c "SELECT set_config('app.uid','$A',false);
         SELECT public.exos_pos_kiosk_configure('$1','$E','$RD','482913',false);
         SELECT public.exos_pos_kiosk_enter('$1') ->> 'token';" | tail -1
}
TOK1=$(tok "$K1"); TOK2=$(tok "$K2")
begin_sql() {  # token key sleep
  echo "SELECT set_config('app.uid','',false);
        SELECT public._exos_pos_kiosk_begin('$1','$T',1,'$2'::uuid,NULL,false) ->> 'id'; SELECT pg_sleep($3);"
}
reset_tier() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E'; DELETE FROM exos_pos_card_payments WHERE event_id='$E';
         DELETE FROM exos_pos_payments WHERE event_id='$E'; DELETE FROM exos_pos_orders WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E'; UPDATE exos_ticket_tiers SET sold=0 WHERE id='$T';
         UPDATE exos_events SET tickets_sold=0 WHERE id='$E'; DELETE FROM exos_rate_windows WHERE bucket LIKE 'pos:%';" >/dev/null
}
fail=0
held() { $P -c "SELECT coalesce(sum(quantity),0) FROM exos_cart_holds WHERE event_id='$E' AND status='active' AND expires_at > now()"; }

echo "race 1: two kiosks begin a sale for the last ticket at once"
reset_tier
{ $P -c "BEGIN; $(begin_sql "$TOK1" c0b1ace0-0000-0000-0000-00000000aa01 2) COMMIT;" >/dev/null 2>&1 || true; } &
sleep 0.5
out2=$($P -c "BEGIN; $(begin_sql "$TOK2" c0b1ace0-0000-0000-0000-00000000aa02 0) COMMIT;" 2>&1 || true)
wait
orders=$($P -c "SELECT count(*) FROM exos_pos_orders WHERE event_id='$E' AND status='open' AND channel='kiosk'")
if [[ "$orders" == 1 && "$(held)" == 1 && "$out2" == *"sold out"* ]]; then
  echo "OK   race 1 one pending kiosk sale holds the last ticket; the other kiosk: sold out"
else
  echo "FAIL race 1: open kiosk orders $orders, held $(held), second: $out2"; fail=1
fi

echo "race 2: a kiosk sale and a door cash sale for the last ticket"
reset_tier
DR=$($P -c "SELECT set_config('app.uid','$A',false);
            INSERT INTO exos_pos_drawer_sessions(event_id, open_float_cents) VALUES ('$E',0) RETURNING id" | tail -1)
{ $P -c "BEGIN; $(begin_sql "$TOK1" c0b1ace0-0000-0000-0000-00000000aa03 2) COMMIT;" >/dev/null 2>&1 || true; } &
sleep 0.5
door=$($P -c "SELECT set_config('app.uid','$A',false);
              SELECT public.exos_pos_walkup_sell('$E','$T',1,'c0b1ace0-0000-0000-0000-00000000aa04'::uuid,0,'cash',NULL,'$DR',NULL,NULL,NULL,NULL) ->> 'status';" 2>&1 || true)
wait
kiosk=$($P -c "SELECT count(*) FROM exos_pos_orders WHERE event_id='$E' AND channel='kiosk' AND status='open'")
paid=$($P -c "SELECT count(*) FROM exos_pos_orders WHERE event_id='$E' AND channel='door' AND status='paid'")
if [[ $((kiosk + paid)) == 1 && "$(held)" -le 1 ]] && [[ "$door" == *"sold out"* || "$paid" == 1 ]]; then
  echo "OK   race 2 one of the two got the last ticket (kiosk pending $kiosk, door paid $paid)"
else
  echo "FAIL race 2: kiosk pending $kiosk, door paid $paid, door said: $door"; fail=1
fi

echo "race 3: a double tap on one kiosk (the same key from two sessions)"
reset_tier
KEY=c0b1ace0-0000-0000-0000-00000000aa05
{ $P -c "BEGIN; $(begin_sql "$TOK1" $KEY 2) COMMIT;" >/dev/null 2>&1 || true; } &
sleep 0.5
second=$($P -c "SELECT set_config('app.uid','',false);
                SELECT public._exos_pos_kiosk_begin('$TOK1','$T',1,'$KEY'::uuid,NULL,false) ->> 'replay';" 2>&1 | tail -1 || true)
wait
n=$($P -c "SELECT count(*) FROM exos_pos_orders WHERE client_ref='$KEY'")
if [[ "$n" == 1 && "$second" == "true" && "$(held)" == 1 ]]; then
  echo "OK   race 3 one pending sale; the second tap is its replay"
else
  echo "FAIL race 3: orders $n, second replay=$second, held $(held)"; fail=1
fi

echo "race 4: ten wrong PINs at once"
reset_tier
TMP=$(mktemp -d)
for i in $(seq 1 10); do
  ( $P -c "SELECT public._exos_pos_kiosk_exit('$TOK2','00000$i') ->> 'error'" > "$TMP/$i" 2>&1 || true ) &
done
wait
wrong=0; other=0
for i in $(seq 1 10); do
  r=$(cat "$TMP/$i")
  case "$r" in wrong-pin) wrong=$((wrong + 1)) ;; locked|rate) other=$((other + 1)) ;; *) echo "  unexpected: $r" ;; esac
done
rm -rf "$TMP"
locked=$($P -c "SELECT pin_locked_until > now() FROM exos_pos_kiosks WHERE device_id='$K2'")
live=$($P -c "SELECT count(*) FROM exos_pos_kiosk_sessions WHERE device_id='$K2' AND ended_at IS NULL")
if [[ "$wrong" -le 4 && $((wrong + other)) == 10 && "$locked" == "t" && "$live" == 1 ]]; then
  echo "OK   race 4 $wrong wrong-pin answers, $other locked / rate; the kiosk is locked and still in kiosk mode"
else
  echo "FAIL race 4: wrong $wrong, other $other, locked $locked, live sessions $live"; fail=1
fi

echo "race 5: two begins with different keys on one kiosk session"
reset_tier
$P -c "UPDATE exos_ticket_tiers SET capacity=10 WHERE id='$T'" >/dev/null
{ $P -c "BEGIN; $(begin_sql "$TOK1" c0b1ace0-0000-0000-0000-00000000aa06 2) COMMIT;" >/dev/null 2>&1 || true; } &
sleep 0.5
out2=$($P -c "BEGIN; $(begin_sql "$TOK1" c0b1ace0-0000-0000-0000-00000000aa07 0) COMMIT;" 2>&1 || true)
wait
open=$($P -c "SELECT count(*) FROM exos_pos_orders WHERE event_id='$E' AND channel='kiosk' AND status='open'")
if [[ "$open" == 1 && "$out2" == *"still open"* ]]; then
  echo "OK   race 5 one open sale on the session; the other begin: kiosk busy"
else
  echo "FAIL race 5: open kiosk sales $open, second: $out2"; fail=1
fi

echo "race 6: five charges at once, 8 minutes after the begin"
ORDER=$($P -c "SELECT id FROM exos_pos_orders WHERE event_id='$E' AND channel='kiosk' AND status='open'")
$P -c "UPDATE exos_pos_orders SET created_at = now() - interval '8 minutes' WHERE id='$ORDER'" >/dev/null
TMP=$(mktemp -d)
for i in $(seq 1 5); do
  ( $P -c "SELECT public._exos_pos_kiosk_charge('$TOK1','$ORDER',false) ->> 'order_id'" > "$TMP/$i" 2>&1 || true ) &
done
wait
ok=0; for i in $(seq 1 5); do [[ "$(cat "$TMP/$i")" == "$ORDER" ]] && ok=$((ok + 1)); done
rm -rf "$TMP"
late=$($P -c "SELECT count(*) FROM exos_cart_holds h JOIN exos_pos_orders o ON o.id = h.pos_order_id
              WHERE o.id='$ORDER' AND h.status='active' AND h.expires_at > o.created_at + interval '10 minutes'")
if [[ "$ok" == 5 && "$late" == 0 ]]; then
  echo "OK   race 6 five charges, the hold still ends within 10 minutes of the begin"
else
  echo "FAIL race 6: charges ok $ok, holds past the cap $late"; fail=1
fi
exit $fail
