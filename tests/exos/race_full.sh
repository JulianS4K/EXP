#!/usr/bin/env bash
# End-to-end races (wave 10, next to tests/exos/sim_full.sql): flows of
# different waves in real parallel sessions, then the simulation's invariants
# (tests/exos/e2e_helpers.sql: journal balanced, sold = live tickets, pools
# within size, an order record for every ticket, journal = settlement,
# exactly the expected audit rows, no PII, cross-org RLS). Each race holds
# one side's transaction open (pg_sleep) so the other side starts while it is
# uncommitted: deterministic enough for CI.
#   bash tests/exos/race_full.sh exos_p0_test
# Expect:
#   race 1 online checkouts against group-pay seats: GA has 5 places, a host
#          holds 3 for a group. (a) buyer X's cart for the other 2 is in
#          flight when buyer Y asks for 2: Y waits, then is refused (not
#          enough tickets); (b) at the same time friend 1 pays seat 1: it
#          goes through; (c) X pays, the host covers seats 2 and 3: GA sold
#          5 of 5, each seat sold once, nothing held
#   race 2 a walk-up at the door on the last place of a shared pool:
#          (a) the door sale is in flight when an online buyer asks for the
#          pool's other type: the cart waits, then is refused; (b) the
#          reverse, on a second pool: the online cart is in flight, the door
#          sale waits, then is refused (sold out); neither pool over its size
#   race 3 an organizer refund at the same time as the promoter payout run:
#          (a) the refund (finalize, which reverses the order's accrued
#          commission) is in flight when the payout settles that commission:
#          the payout waits, then is refused (nothing paid for a refunded
#          order); (b) the payout is in flight when the refund lands: the
#          refund waits, then reverses the now-paid commission and books the
#          clawback; the journal's commissions = settlement's either way
# Then check_invariants over everything the races did.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
# Every statement below starts with these: the id namespace (e2r) and the shared helpers.
PRE="CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS \$\$ SELECT md5('e2r:' || p)::uuid \$\$;
\\i $DIR/e2e_helpers.sql"
# run SQL: one psql session with the helpers loaded; prints the last result row(s).
run() { printf '%s\n%s\n' "$PRE" "$1" | $P -f - 2>&1; }
id() { $P -c "SELECT md5('e2r:$1')::uuid"; }
A=$(id A); B=$(id B); E1=$(id e1); E2=$(id e2); E9=$(id e9)

cleanup() {
  # The journal and the audit log are append-only: the cleanup runs with
  # triggers off (replica), table by table, every row of the two orgs.
  $P -c "SET session_replication_role = replica;
    DO \$\$
    DECLARE t text;
    BEGIN
      -- Rows that name only a ticket type or a group of these events.
      FOR t IN SELECT c.table_name FROM information_schema.columns c JOIN information_schema.tables x
                 ON x.table_schema = c.table_schema AND x.table_name = c.table_name AND x.table_type = 'BASE TABLE'
                WHERE c.table_schema = 'public' AND c.column_name = 'tier_id' AND c.table_name LIKE 'exos\\_%' LOOP
        EXECUTE format('DELETE FROM public.%I WHERE tier_id IN (SELECT id FROM public.exos_ticket_tiers WHERE event_id IN (%L, %L, %L))',
                       t, '$E1', '$E2', '$E9');
      END LOOP;
      DELETE FROM public.exos_group_buy_seats WHERE group_id IN (SELECT id FROM public.exos_group_buys WHERE event_id IN ('$E1', '$E2', '$E9'));
      DELETE FROM public.exos_refund_request_items WHERE request_id IN (SELECT id FROM public.exos_refund_requests WHERE org_id IN ('$A', '$B'));
      DELETE FROM public.exos_mail_dedupe WHERE mail_id IN (SELECT id FROM public.exos_mail WHERE to_email LIKE 'e2r-%');
      FOR t IN SELECT c.table_name FROM information_schema.columns c JOIN information_schema.tables x
                 ON x.table_schema = c.table_schema AND x.table_name = c.table_name AND x.table_type = 'BASE TABLE'
                WHERE c.table_schema = 'public' AND c.column_name = 'org_id' AND c.table_name LIKE 'exos\\_%' LOOP
        EXECUTE format('DELETE FROM public.%I WHERE org_id IN (%L, %L)', t, '$A', '$B');
      END LOOP;
      FOR t IN SELECT c.table_name FROM information_schema.columns c JOIN information_schema.tables x
                 ON x.table_schema = c.table_schema AND x.table_name = c.table_name AND x.table_type = 'BASE TABLE'
                WHERE c.table_schema = 'public' AND c.column_name = 'event_id' AND c.table_name LIKE 'exos\\_%' LOOP
        EXECUTE format('DELETE FROM public.%I WHERE event_id IN (%L, %L, %L)', t, '$E1', '$E2', '$E9');
      END LOOP;
      FOR t IN SELECT c.table_name FROM information_schema.columns c JOIN information_schema.tables x
                 ON x.table_schema = c.table_schema AND x.table_name = c.table_name AND x.table_type = 'BASE TABLE'
                WHERE c.table_schema = 'public' AND c.column_name = 'session_id' AND c.table_name LIKE 'exos\\_%' LOOP
        EXECUTE format('DELETE FROM public.%I WHERE session_id::text LIKE %L', t, 'cs\\_e2r\\_%');
      END LOOP;
      DELETE FROM public.exos_ticket_tiers WHERE event_id IN ('$E1', '$E2', '$E9');
      DELETE FROM public.exos_events WHERE id IN ('$E1', '$E2', '$E9');
      DELETE FROM public.exos_orgs WHERE id IN ('$A', '$B');
      DELETE FROM public.exos_mail WHERE to_email LIKE 'e2r-%';
      DELETE FROM auth.users WHERE email LIKE 'e2r-%@x.com';
    END \$\$;" >/dev/null
}
cleanup
trap 'cleanup; rm -rf "${TMP:-/nonexistent}"' EXIT
TMP=$(mktemp -d)
fail=0
ok() { echo "OK   $1"; }
bad() { echo "FAIL $1"; fail=1; }
q() { $P -c "$1"; }

# Fixtures (committed): org A (owner, manager, finance, scanner), org B and
# its one order; e1 with GA (5 places), a pool of 2 (VIP + Balcony), a pool
# of 1 (Box + Pit), Gen (10, the promoter's); e2 (for the RLS check); the
# promoter (10%); the scanner's drawer.
out=$(run "BEGIN;
INSERT INTO auth.users (id, email, email_confirmed_at)
SELECT pg_temp.u(x), 'e2r-' || x || '@x.com', now()
  FROM unnest(ARRAY['oa', 'ma', 'fa', 'sa', 'ob', 'bb', 'h1', 'f1', 'x1', 'x2', 'x3', 'x4', 'x5']) x;
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('A'), 'E2R Hall', 'e2r-hall', pg_temp.u('oa')), (pg_temp.u('B'), 'E2R Other', 'e2r-other', pg_temp.u('ob'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('A'), pg_temp.u('oa'), 'owner'), (pg_temp.u('A'), pg_temp.u('ma'), 'manager'),
  (pg_temp.u('A'), pg_temp.u('fa'), 'finance'), (pg_temp.u('A'), pg_temp.u('sa'), 'scanner'),
  (pg_temp.u('B'), pg_temp.u('ob'), 'owner');
UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day' WHERE org_id IN (pg_temp.u('A'), pg_temp.u('B'));
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, total_tickets, tickets_sold, currency, created_by, purchase_limits) VALUES
  (pg_temp.u('e1'), pg_temp.u('A'), 'E2R Night', 'e2r-night', 'published', now() + interval '2 hours', now() - interval '1 hour', 100, 0, 'usd', pg_temp.u('oa'), '{\"maxPerOrder\": 8}'),
  (pg_temp.u('e2'), pg_temp.u('A'), 'E2R Matinee', 'e2r-matinee', 'published', now() + interval '10 days', NULL, 100, 0, 'usd', pg_temp.u('oa'), NULL),
  (pg_temp.u('e9'), pg_temp.u('B'), 'E2R Elsewhere', 'e2r-elsewhere', 'published', now() + interval '5 days', NULL, 100, 0, 'usd', pg_temp.u('ob'), NULL);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, door_price_cents) VALUES
  (pg_temp.u('ga'), pg_temp.u('e1'), 'GA', 30, 5, 0, 'public', NULL),
  (pg_temp.u('vip'), pg_temp.u('e1'), 'VIP', 80, 10, 0, 'public', 8000),
  (pg_temp.u('bal'), pg_temp.u('e1'), 'Balcony', 60, 10, 0, 'public', 6000),
  (pg_temp.u('box'), pg_temp.u('e1'), 'Box', 90, 10, 0, 'public', 9000),
  (pg_temp.u('pit'), pg_temp.u('e1'), 'Pit', 50, 10, 0, 'public', 5000),
  (pg_temp.u('gen'), pg_temp.u('e1'), 'Gen', 20, 10, 0, 'public', NULL),
  (pg_temp.u('g2'), pg_temp.u('e2'), 'Matinee GA', 50, 100, 0, 'public', NULL),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'B GA', 30, 100, 0, 'public', NULL);
INSERT INTO public.exos_quotas (id, event_id, org_id, name, size) VALUES
  (pg_temp.u('q1'), pg_temp.u('e1'), pg_temp.u('A'), 'Floor', 2), (pg_temp.u('q2'), pg_temp.u('e1'), pg_temp.u('A'), 'Boxes', 1);
INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES
  (pg_temp.u('q1'), pg_temp.u('vip')), (pg_temp.u('q1'), pg_temp.u('bal')), (pg_temp.u('q2'), pg_temp.u('box')), (pg_temp.u('q2'), pg_temp.u('pit'));
INSERT INTO public.exos_promoters (id, org_id, code, name, commission_bps) VALUES (pg_temp.u('pr'), pg_temp.u('A'), 'e2r-promo', 'E2R Promo', 1000);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents,
            currency, status, application_fee_cents, exos_fee_cents, card_fee_est_cents, processor)
VALUES ('cs_e2r_orgb', pg_temp.u('e9'), pg_temp.u('t9'), pg_temp.u('B'), pg_temp.u('bb'), 'e2r-bb@x.com', 1, 3000, 'usd', 'pending', 150, 60, 90, 'stripe');
SELECT cardinality(pg_temp.paid('cs_e2r_orgb'));
SELECT pg_temp.act('sa');
INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('dr'), pg_temp.u('e1'), 5000);
-- The pool of 2 starts with one place sold online (x5, VIP).
SELECT pg_temp.act('x5');
SELECT public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('vip'), 1) AS h \\gset
SELECT pg_temp.act(NULL);
SELECT pg_temp.sess('cs_e2r_x5', 'e1', 'vip', 'x5', 'e2r-x5@x.com', 1, 8000, 360, 120);
UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2r_x5' WHERE id = :'h';
SELECT cardinality(pg_temp.paid('cs_e2r_x5'));
-- The promoter's two orders on Gen (x3, x4: 2 tickets each).
SELECT pg_temp.sess('cs_e2r_x3', 'e1', 'gen', 'x3', 'e2r-x3@x.com', 2, 4000, 220, 100, NULL, 'e2r-promo');
SELECT cardinality(pg_temp.paid('cs_e2r_x3'));
SELECT pg_temp.sess('cs_e2r_x4', 'e1', 'gen', 'x4', 'e2r-x4@x.com', 2, 4000, 220, 100, NULL, 'e2r-promo');
SELECT cardinality(pg_temp.paid('cs_e2r_x4'));
-- The host's group of 3 on GA.
SELECT pg_temp.act('h1');
SELECT public.exos_group_buy_start(pg_temp.u('e1'), pg_temp.u('ga'), 3) ->> 'id';
COMMIT;
SELECT 'fixtures ok';
" || true)
[[ "$out" == *"fixtures ok"* ]] || { echo "FAIL fixtures: $out"; exit 1; }
GROUP=$(q "SELECT id FROM exos_group_buys WHERE event_id='$E1' AND status='open'")
MARK=$(q "SELECT coalesce(max(id), 0) FROM exos_org_audit")
tok() { q "SELECT token FROM exos_group_buy_seats WHERE group_id='$GROUP' AND seat_no=$1"; }

# ── race 1: online checkouts against group-pay seats ────────────────────────
run "BEGIN;
     SELECT pg_temp.act('x1');
     SELECT public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('ga'), 2) AS h \\gset
     SELECT pg_temp.act(NULL);
     SELECT pg_temp.sess('cs_e2r_x1', 'e1', 'ga', 'x1', 'e2r-x1@x.com', 2, 6000, 270, 120);
     UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2r_x1' WHERE id = :'h';
     SELECT pg_sleep(2);
     COMMIT;" >/dev/null &
p1=$!
sleep 0.5
T1=$(tok 1)
run "BEGIN;
     SELECT public.exos_group_claim('$T1', NULL, pg_temp.u('f1'), 'e2r-f1@x.com', pg_temp.u('e1'), pg_temp.u('ga'), 1);
     SELECT pg_temp.sess('cs_e2r_f1', 'e1', 'ga', 'f1', 'e2r-f1@x.com', 1, 3000, 165, 75);
     SELECT public.exos_group_attach('cs_e2r_f1', '$T1', NULL);
     SELECT cardinality(pg_temp.paid('cs_e2r_f1'));
     COMMIT;" >"$TMP/r1_f1" &
p2=$!
y=$(run "BEGIN; SELECT pg_temp.act('x2'); SELECT public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('ga'), 2); COMMIT;" || true)
wait $p1; wait $p2 || true
f1=$(cat "$TMP/r1_f1")
if [[ "$y" == *"not enough"* || "$y" == *"sold out"* || "$y" == *"available"* ]] && [[ "$f1" != *ERROR* ]]; then
  ok "race 1a Y's cart for the last 2 places while X's is in flight: refused ($(echo "$y" | grep -o 'ERROR.*' | head -1 | cut -c1-70))"
  ok "race 1b friend 1 pays their group seat at the same time"
else
  bad "race 1a/b: Y $y / friend 1 $f1"
fi
# X pays; the host covers the other two seats.
out=$(run "BEGIN;
     SELECT cardinality(pg_temp.paid('cs_e2r_x1'));
     SELECT public.exos_group_claim(NULL, '$GROUP', pg_temp.u('h1'), 'e2r-h1@x.com', pg_temp.u('e1'), pg_temp.u('ga'), 2);
     SELECT pg_temp.sess('cs_e2r_cover', 'e1', 'ga', 'h1', 'e2r-h1@x.com', 2, 6000, 270, 120);
     SELECT public.exos_group_attach('cs_e2r_cover', NULL, '$GROUP');
     SELECT 'paid ' || cardinality(pg_temp.paid('cs_e2r_cover'));
     COMMIT;")
sold=$(q "SELECT sold FROM exos_ticket_tiers WHERE id = md5('e2r:ga')::uuid")
live=$(q "SELECT count(*) FROM exos_tickets WHERE tier_id = md5('e2r:ga')::uuid AND status = 'active'")
held=$(q "SELECT count(*) FROM exos_cart_holds WHERE tier_id = md5('e2r:ga')::uuid AND status = 'active'")
if [[ "$out" == *"paid 2"* && "$sold" == 5 && "$live" == 5 && "$held" == 0 ]]; then
  ok "race 1c X pays, the host covers 2: GA 5 of 5 sold, 5 live tickets, nothing held"
else
  bad "race 1c: $out / sold $sold live $live held $held"
fi

# ── race 2: a walk-up on the last place of a shared pool ────────────────────
# (a) the door sale (VIP, the pool of 2's last place) is in flight; an online cart for Balcony.
run "BEGIN;
     SELECT pg_temp.act('sa');
     SELECT public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('vip'), 1, pg_temp.u('k-r2a'), 0, 'cash', NULL, pg_temp.u('dr'),
                                        'Walk Up', NULL, NULL, NULL, false) ->> 'status';
     SELECT pg_sleep(2);
     COMMIT;" >"$TMP/r2a" &
p1=$!
sleep 0.5
y=$(run "BEGIN; SELECT pg_temp.act('x2'); SELECT public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('bal'), 1); COMMIT;" || true)
wait $p1 || true
door=$(cat "$TMP/r2a")
used=$(q "SELECT public._exos_quota_used(md5('e2r:q1')::uuid)")
if [[ "$door" == *paid* && "$y" == *"not enough"* && "$used" == 2 ]]; then
  ok "race 2a the door takes the pool's last place; the online cart waits, then is refused; pool 2 of 2"
else
  bad "race 2a: door $door / online $y / used $used"
fi
# (b) the online cart (Box, the pool of 1) is in flight; the door sells Pit.
run "BEGIN;
     SELECT pg_temp.act('x2');
     SELECT public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('box'), 1);
     SELECT pg_sleep(2);
     COMMIT;" >/dev/null &
p1=$!
sleep 0.5
door=$(run "BEGIN; SELECT pg_temp.act('sa');
            SELECT public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('pit'), 1, pg_temp.u('k-r2b'), 0, 'cash', NULL, pg_temp.u('dr'),
                                               'Walk Up', NULL, NULL, NULL, false) ->> 'status'; COMMIT;" || true)
wait $p1
used=$(q "SELECT coalesce(sum(quantity), 0) FROM exos_cart_holds WHERE tier_id = md5('e2r:box')::uuid AND status = 'active'")
pit=$(q "SELECT sold FROM exos_ticket_tiers WHERE id = md5('e2r:pit')::uuid")
if [[ "$door" == *"sold out"* && "$used" == 1 && "$pit" == 0 ]]; then
  ok "race 2b the online cart holds the pool's last place; the door sale waits, then is refused; pool 1 of 1"
else
  bad "race 2b: door $door / used $used / pit sold $pit"
fi
# The cart lapses (nobody paid): the pool is free again, nothing sold.
q "UPDATE exos_cart_holds SET status = 'released', released_at = now() WHERE tier_id = md5('e2r:box')::uuid AND status = 'active'" >/dev/null

# ── race 3: an organizer refund at the same time as the promoter payout run ─
# (a) x3's refund (whole order) is being finalized; the payout run settles x3's commissions.
C3=$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM exos_promoter_commissions WHERE session_id = 'cs_e2r_x3' AND status = 'accrued'")
run "BEGIN;
     SELECT public.exos_refund_claim(pg_temp.u('oa'), 'cs_e2r_x3', 'e2r-r3a-0001', NULL, NULL, true, 'refund', NULL) ->> 'request_id' AS r \\gset
     SELECT public.exos_refund_charge_prepare(:'r');
     SELECT public.exos_refund_finalize(:'r', 're_e2rX3', 'succeeded');
     SELECT pg_sleep(2);
     COMMIT;" >/dev/null &
p1=$!
sleep 0.5
pay=$(run "BEGIN; SELECT pg_temp.act('oa');
           SELECT public.exos_settle_promoter(pg_temp.u('pr'), string_to_array('$C3', ',')::uuid[], 400, 'Venmo', 'e2r-settle-r3a'); COMMIT;" || true)
wait $p1
st=$(q "SELECT string_agg(DISTINCT status, ',') FROM exos_promoter_commissions WHERE session_id = 'cs_e2r_x3'")
if [[ "$pay" == *ERROR* && "$st" == reversed ]]; then
  ok "race 3a the payout waits for the refund, then pays nothing for the refunded order ($(echo "$pay" | grep -o 'ERROR.*' | head -1 | cut -c1-60))"
else
  bad "race 3a: payout $pay / commissions $st"
fi
# (b) the payout of x4's commissions is in flight; x4's refund lands.
C4=$(q "SELECT string_agg(id::text, ',' ORDER BY id) FROM exos_promoter_commissions WHERE session_id = 'cs_e2r_x4' AND status = 'accrued'")
run "BEGIN;
     SELECT pg_temp.act('oa');
     SELECT public.exos_settle_promoter(pg_temp.u('pr'), string_to_array('$C4', ',')::uuid[], 400, 'Venmo', 'e2r-settle-r3b');
     SELECT pg_sleep(2);
     COMMIT;" >/dev/null &
p1=$!
sleep 0.5
ref=$(run "BEGIN;
           SELECT public.exos_refund_claim(pg_temp.u('oa'), 'cs_e2r_x4', 'e2r-r3b-0001', NULL, NULL, true, 'refund', NULL) ->> 'request_id' AS r \\gset
           SELECT public.exos_refund_charge_prepare(:'r');
           SELECT public.exos_refund_finalize(:'r', 're_e2rX4', 'succeeded') ->> 'status';
           COMMIT;" || true)
wait $p1
st=$(q "SELECT string_agg(DISTINCT status, ',') FROM exos_promoter_commissions WHERE session_id = 'cs_e2r_x4'")
claw=$(q "SELECT coalesce(-sum(amount_cents), 0) FROM exos_commission_netting WHERE session_id = 'cs_e2r_x4' AND kind = 'clawback'")
if [[ "$ref" == *succeeded* && "$st" == reversed && "$claw" == 400 ]]; then
  ok "race 3b the refund waits for the payout, then reverses the paid commission with a 400 clawback"
else
  bad "race 3b: refund $ref / commissions $st / clawback $claw"
fi

# ── the invariants over all of it ───────────────────────────────────────────
out=$(run "BEGIN;
  SELECT pg_temp.put('audit_mark', '$MARK');
  SELECT pg_temp.check_invariants('race_full end',
    ARRAY['order.group_cover:user', 'refund.issue:user', 'refund.issue:user', 'promoter.settle:user']);
  SELECT 'invariants ok';
  ROLLBACK;")
if [[ "$out" == *"invariants ok"* ]]; then
  ok "check_invariants after the races: $(echo "$out" | grep -o 'OK  race_full end.*' | cut -c1-90)"
else
  bad "check_invariants: $(echo "$out" | grep -E 'ERROR' | head -3)"
fi
exit $fail
