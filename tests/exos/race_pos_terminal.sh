#!/usr/bin/env bash
# Card at the door races (mig 20261107130000): real parallel sessions.
# Timing-based, so run by hand against a DB built by run_p0.sh:
#   bash tests/exos/race_pos_terminal.sh exos_p0_test
# Expect:
#   race 1 the door's completion and the webhook's completion of the same
#          card sale run at once: one set of tickets, one card tender, the
#          other side is a replay (whichever takes the order lock first)
#   race 2 the same, the webhook first
#   race 3 a cancel at the door races a completion: exactly one wins; either
#          the sale is paid (the cancel is ignored) or it is cancelled and the
#          capture comes back refund_needed (never tickets AND a cancel, never
#          money kept without tickets)
#   race 4 a double tap from two sessions with the same order key: one
#          pending card sale
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=c0a7ace0-0000-0000-0000-000000000001; A=c0a7ace0-0000-0000-0000-0000000000a1; S=c0a7ace0-0000-0000-0000-0000000000a3
E=c0a7ace0-0000-0000-0000-0000000000e1; T=c0a7ace0-0000-0000-0000-0000000000d1
MADE_SECRETS=$($P -c "SELECT to_regclass('public.exos_org_secrets') IS NULL")
cleanup() {
  $P -c "DELETE FROM exos_cart_holds WHERE event_id='$E';
         DELETE FROM exos_pos_card_payments WHERE event_id='$E';
         DELETE FROM exos_pos_reversals WHERE event_id='$E';
         DELETE FROM exos_question_answer_cursors WHERE event_id='$E';
         DELETE FROM exos_pos_orders WHERE event_id='$E'; DELETE FROM exos_pos_items WHERE event_id='$E';
         DELETE FROM exos_tickets WHERE event_id='$E';
         DELETE FROM exos_ticket_tiers WHERE event_id='$E'; DELETE FROM exos_events WHERE id='$E';
         DELETE FROM exos_org_memberships WHERE org_id='$O'; DELETE FROM exos_orgs WHERE id='$O';
         DELETE FROM exos_rate_windows WHERE bucket LIKE 'pos:%$S%' OR bucket LIKE 'pos:%$A%';
         DELETE FROM auth.users WHERE id IN ('$A','$S');" >/dev/null
  if [ "$MADE_SECRETS" = "t" ]; then $P -c "DROP TABLE IF EXISTS public.exos_org_secrets;" >/dev/null
  else $P -c "DELETE FROM public.exos_org_secrets WHERE org_id='$O';" >/dev/null; fi
}
$P -c "CREATE TABLE IF NOT EXISTS public.exos_org_secrets (org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());" >/dev/null
cleanup
$P -c "CREATE TABLE IF NOT EXISTS public.exos_org_secrets (org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());" >/dev/null
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-pt.test',now()),('$S','scanner@race-pt.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race terminal','race-pt','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner'),('$O','$S','scanner');
       INSERT INTO exos_org_secrets(org_id,payments) VALUES ('$O','{\"connectedAccountId\":\"acct_racePt\",\"chargesEnabled\":true}');
       INSERT INTO exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by)
         VALUES ('$E','$O','Race','race-pt','published',now() + interval '1 hour',0,0,'$A');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,door_price_cents) VALUES
         ('$T','$E','Door',20,50,0,'public',2500);" >/dev/null

# A pending card sale with an attached PaymentIntent, authorized (capture prepared).
pending() {
  local key=$1 pi=$2
  $P -c "SELECT set_config('app.uid','',false);
         SELECT public._exos_pos_walkup_begin_card('$S','$E','$T',2,'$key'::uuid,NULL,NULL,NULL,NULL,false) ->> 'id';" | tail -1 | {
    read -r ORDER
    $P -c "SELECT public._exos_pos_card_attach('$ORDER','$pi',5000,'usd',0,0,0,300);
           SELECT public._exos_pos_card_capture_prepare('$ORDER','$pi');" >/dev/null
    echo "$ORDER"
  }
}
complete() {  # order pi via sleep
  echo "SELECT public._exos_pos_card_complete('$1','$2',5000,'$3',NULL) ->> 'replay'; SELECT pg_sleep($4);"
}
check_one() {  # order
  local n m
  n=$($P -c "SELECT count(*) FROM exos_tickets WHERE order_ref='pos:$1'")
  m=$($P -c "SELECT count(*) FROM exos_pos_payments WHERE order_id='$1' AND method='card'")
  echo "  -> tickets=$n card tenders=$m (expect 2 and 1)"
  [ "$n" = "2" ] && [ "$m" = "1" ] || { echo "FAIL"; exit 1; }
}

echo "race 1: the door and the webhook complete the same sale (door first)"
ORDER=$(pending c0a7ace0-0000-0000-0000-00000000aa01 pi_RacePtOne)
( R=$($P -c "BEGIN; $(complete $ORDER pi_RacePtOne door 2) COMMIT;" | head -1); echo "  door replay=$R" ) &
sleep 0.5
R=$($P -c "BEGIN; $(complete $ORDER pi_RacePtOne webhook 0) COMMIT;" | head -1); echo "  webhook replay=$R"
wait
check_one "$ORDER"

echo "race 2: the same, the webhook first"
ORDER=$(pending c0a7ace0-0000-0000-0000-00000000aa02 pi_RacePtTwo)
( R=$($P -c "BEGIN; $(complete $ORDER pi_RacePtTwo webhook 2) COMMIT;" | head -1); echo "  webhook replay=$R" ) &
sleep 0.5
R=$($P -c "BEGIN; $(complete $ORDER pi_RacePtTwo door 0) COMMIT;" | head -1); echo "  door replay=$R"
wait
check_one "$ORDER"

echo "race 3: a cancel at the door races a completion"
ORDER=$(pending c0a7ace0-0000-0000-0000-00000000aa03 pi_RacePtThree)
( $P -c "BEGIN; SELECT public._exos_pos_card_fail('$ORDER','pi_RacePtThree','canceled',NULL,'door','cancel race') ->> 'ignored'; SELECT pg_sleep(2); COMMIT;" \
    | head -1 | sed 's/^/  cancel ignored=/' ) &
sleep 0.5
R=$($P -c "BEGIN; SELECT public._exos_pos_card_complete('$ORDER','pi_RacePtThree',5000,'webhook',NULL) ->> 'refund_needed'; COMMIT;" | head -1)
echo "  completion refund_needed=$R"
wait
ST=$($P -c "SELECT status FROM exos_pos_orders WHERE id='$ORDER'")
N=$($P -c "SELECT count(*) FROM exos_tickets WHERE order_ref='pos:$ORDER'")
C=$($P -c "SELECT status FROM exos_pos_card_payments WHERE order_id='$ORDER'")
echo "  -> order=$ST tickets=$N card=$C (expect void, 0, refund_pending: the cancel locked first)"
[ "$ST" = "void" ] && [ "$N" = "0" ] && [ "$C" = "refund_pending" ] || { echo "FAIL"; exit 1; }

echo "race 4: a double tap from two sessions with one order key"
K=c0a7ace0-0000-0000-0000-00000000aa04
( $P -c "BEGIN; SELECT set_config('app.uid','',true);
         SELECT public._exos_pos_walkup_begin_card('$S','$E','$T',1,'$K'::uuid,NULL,NULL,NULL,NULL,false) ->> 'replay';
         SELECT pg_sleep(1.5); COMMIT;" | grep -E '^(true|false)$' | sed 's/^/  tap 1 replay=/' ) &
sleep 0.5
$P -c "BEGIN; SELECT set_config('app.uid','',true);
       SELECT public._exos_pos_walkup_begin_card('$S','$E','$T',1,'$K'::uuid,NULL,NULL,NULL,NULL,false) ->> 'replay'; COMMIT;" \
  | grep -E '^(true|false)$' | sed 's/^/  tap 2 replay=/'
wait
N=$($P -c "SELECT count(*) FROM exos_pos_orders WHERE client_ref='$K'")
M=$($P -c "SELECT count(*) FROM exos_pos_card_payments c JOIN exos_pos_orders o ON o.id=c.order_id WHERE o.client_ref='$K'")
echo "  -> orders=$N card rows=$M (expect 1 and 1)"
[ "$N" = "1" ] && [ "$M" = "1" ] || { echo "FAIL"; exit 1; }
echo "race_pos_terminal: all races OK"
