-- ============================================================================
-- Attendance report (mig 20261113120000). Self-contained (a7e… ids), rolled
-- back.
--   AR0 shape: definer + search_path; the dashboard read is signed-in only,
--       the core / API / helpers service-role only; nothing for anon
--   AR1 postal rollup: areas with 5+ distinct buyers named (US ZIP+4 folded
--       to the ZIP, Canada to the FSA); fewer than 5 buyers folded into
--       "Other (fewer than 5)" and never named anywhere in the answer (even
--       with 5+ orders from 4 buyers); no postal code (card country only, $0
--       orders by their ticket_ids); live tickets only (a refunded order with
--       its ticket voided drops out); pending and the other org's not
--       counted; door tickets with no order counted apart; no email or city
--   AR2 pacing: per local day in the event's zone (a 22:00 sale in New York
--       is that day, not UTC's next), paid tickets + gross (card + gift card
--       part) with $0 orders' tickets apart and never in gross, refunded
--       sales counted as sold, pending not, after the event folded into day
--       0, running totals, on-sale from the tier's sales_start
--   AR3 alignment: a prior event of the org lines up by days before its own
--       event; the candidates are the org's earlier events only
--   AR4 roles and cross-org: owner / manager / finance (and as the
--       authenticated role) yes; scanner, outsider, the other org's owner,
--       an unknown event 42501; a comparison event of another org P0002 with
--       nothing about it echoed; the same event 22023
--   AR5 API core: an org key acts as its creator (owner / finance yes,
--       scanner-made, another org's, revoked 42501); personal / OAuth token
--       by the user's role now; an unknown kind 42501; another org's event
--       404 (P0002)
--   AR6 rate limits: 20 a minute per user (dashboard) and per credential
--       (API), then 54000, before any work
--   AR7 exports: exos_audit_export takes attendance / settlement /
--       sales_tax / journal (export.run, the event's org), refuses others,
--       and they count toward the 200-a-day cap; both markers in place
--   AR8 every live ticket is in one row: named areas + Other + No postal
--       code = the live tickets, with an area that has no country (folded
--       into Other) and orders with no account and no email (each its own
--       buyer, so two of them and three guests make an area of 5)
-- Users: oa owner A, ma manager A, fa finance A, sa scanner A, ob owner B,
--        x1 outsider, bz a ticket holder (the guests' tickets need an owner).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('a7e00000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO anon, authenticated;
-- One day's row of a pacing series.
CREATE FUNCTION pg_temp.day(p jsonb, p_days int) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT r FROM jsonb_array_elements(p->'rows') r WHERE (r->>'days_before')::int = p_days
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'a7e-oa@x.com', now()), (pg_temp.u('a2'), 'a7e-ma@x.com', now()),
  (pg_temp.u('a3'), 'a7e-fa@x.com', now()), (pg_temp.u('a4'), 'a7e-sa@x.com', now()),
  (pg_temp.u('a5'), 'a7e-ob@x.com', now()), (pg_temp.u('a6'), 'a7e-x1@x.com', now()),
  (pg_temp.u('b0'), 'a7e-bz@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'A7E Hall', 'a7e-hall', pg_temp.u('a1')),
  (pg_temp.u('2'), 'A7E Elsewhere', 'a7e-elsewhere', pg_temp.u('a5'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('a1'), 'owner'), (pg_temp.u('1'), pg_temp.u('a2'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('a3'), 'finance'), (pg_temp.u('1'), pg_temp.u('a4'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('a5'), 'owner');
-- Org A: e1 (the postal rollup), e2 (pacing), e0 (a year before e2, the
-- comparison), e3 (after e2: not a candidate). Org B: e9 (secret name).
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'A7E Rollup', 'a7e-rollup', 'published', '2026-12-27 20:00 America/New_York', 'America/New_York', 500, pg_temp.u('a1')),
  (pg_temp.u('e2'), pg_temp.u('1'), 'A7E Pacing', 'a7e-pacing', 'published', '2026-12-20 20:00 America/New_York', 'America/New_York', 500, pg_temp.u('a1')),
  (pg_temp.u('e0'), pg_temp.u('1'), 'A7E Last Year', 'a7e-last-year', 'published', '2025-12-19 20:00 America/New_York', 'America/New_York', 500, pg_temp.u('a1')),
  (pg_temp.u('e3'), pg_temp.u('1'), 'A7E Later', 'a7e-later', 'published', '2027-01-30 20:00 America/New_York', 'America/New_York', 500, pg_temp.u('a1')),
  (pg_temp.u('e9'), pg_temp.u('2'), 'A7E Secret Gala', 'a7e-secret', 'published', '2026-06-01 20:00 America/New_York', 'America/New_York', 500, pg_temp.u('a5'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sales_start) VALUES
  (pg_temp.u('c2'), pg_temp.u('e2'), 'GA', 20, 100, '2026-11-20 17:00Z'),
  (pg_temp.u('c0'), pg_temp.u('e0'), 'GA', 20, 100, '2025-11-21 17:00Z');

SET LOCAL session_replication_role = replica;
-- e1 orders (all fulfilled 2026-12-10 unless said), one live ticket per seat:
--   10001: g1..g5, one order each, 1 ticket; g5's ZIP is ZIP+4; g1 checked in.
--   11211: g6 (2 orders) g7 g8 g9: 5 orders, 4 buyers, 2 tickets each.
--   K1A (CA): c1..c5 across 'K1A 0B1' / 'K1A 9Z9', 1 ticket each.
--   94110: s1, 1 ticket.
--   no postal: n1 (card country only), z1 ($0 comp, 2 tickets by ticket_ids).
--   left out: r1 refunded with its ticket voided (10001), p1 pending (10001),
--   e9's order (org B, 10001); one door ticket with no order.
CREATE TEMP TABLE fx (sid text, buyer text, qty int, cents int, status text, country text, postal text, free_kind text);
INSERT INTO fx VALUES
  ('cs_a7e_g1', 'g1', 1, 2000, 'fulfilled', 'US', '10001', NULL),
  ('cs_a7e_g2', 'g2', 1, 2000, 'fulfilled', 'US', '10001', NULL),
  ('cs_a7e_g3', 'g3', 1, 2000, 'fulfilled', 'US', '10001', NULL),
  ('cs_a7e_g4', 'g4', 1, 2000, 'partially_refunded', 'US', '10001', NULL),
  ('cs_a7e_g5', 'g5', 1, 2000, 'fulfilled', 'US', '10001-1234', NULL),
  ('cs_a7e_g6', 'g6', 2, 4000, 'fulfilled', 'US', '11211', NULL),
  ('cs_a7e_g6b', 'g6', 2, 4000, 'fulfilled', 'US', '11211', NULL),
  ('cs_a7e_g7', 'g7', 2, 4000, 'fulfilled', 'US', '11211', NULL),
  ('cs_a7e_g8', 'g8', 2, 4000, 'fulfilled', 'US', '11211', NULL),
  ('cs_a7e_g9', 'g9', 2, 4000, 'fulfilled', 'US', '11211', NULL),
  ('cs_a7e_c1', 'c1', 1, 2000, 'fulfilled', 'CA', 'K1A 0B1', NULL),
  ('cs_a7e_c2', 'c2', 1, 2000, 'fulfilled', 'CA', 'K1A 0B1', NULL),
  ('cs_a7e_c3', 'c3', 1, 2000, 'fulfilled', 'CA', 'K1A 0B1', NULL),
  ('cs_a7e_c4', 'c4', 1, 2000, 'fulfilled', 'CA', 'K1A 9Z9', NULL),
  ('cs_a7e_c5', 'c5', 1, 2000, 'fulfilled', 'CA', 'K1A 9Z9', NULL),
  ('cs_a7e_s1', 's1', 1, 2000, 'fulfilled', 'US', '94110', NULL),
  ('cs_a7e_n1', 'n1', 1, 2000, 'fulfilled', 'US', NULL, NULL),
  ('zero_a7e_z1', 'z1', 2, 0, 'fulfilled', NULL, NULL, 'comp'),
  ('cs_a7e_r1', 'r1', 1, 2000, 'refunded', 'US', '10001', NULL),
  ('cs_a7e_p1', 'p1', 1, 2000, 'pending', 'US', '10001', NULL);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents,
                                           currency, status, fulfilled_at, free_kind, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents)
SELECT sid, pg_temp.u('e1'), pg_temp.u('1'), NULL, 'a7e-' || buyer || '@guest.test', true, qty, cents, 'usd', status,
       CASE WHEN status <> 'pending' THEN timestamptz '2026-12-10 15:00Z' END, free_kind,
       CASE WHEN free_kind IS NOT NULL THEN 0 END, CASE WHEN free_kind IS NOT NULL THEN 0 END,
       CASE WHEN free_kind IS NOT NULL THEN 0 END, CASE WHEN free_kind IS NOT NULL THEN 0 END
  FROM fx;
INSERT INTO public.exos_order_locations (session_id, org_id, event_id, country, postal_code, source)
SELECT sid, pg_temp.u('1'), pg_temp.u('e1'), country, postal, CASE WHEN postal IS NULL THEN 'stripe_card_country' ELSE 'stripe_billing' END
  FROM fx WHERE country IS NOT NULL;
-- Tickets: paid orders by order_ref; the $0 order by its ticket_ids (its
-- tickets keep their own 'free_…' refs, as the zero-order trigger leaves them).
INSERT INTO public.exos_tickets (id, event_id, org_id, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref)
SELECT gen_random_uuid(), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b0'), pg_temp.u('b0'),
       CASE WHEN fx.status = 'refunded' THEN 'voided' WHEN fx.sid = 'cs_a7e_g1' THEN 'used' ELSE 'active' END,
       'sec', 20, fx.sid
  FROM fx CROSS JOIN LATERAL generate_series(1, fx.qty) WHERE fx.free_kind IS NULL AND fx.status <> 'pending';
INSERT INTO public.exos_tickets (id, event_id, org_id, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref) VALUES
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b0'), pg_temp.u('b0'), 'active', 'sec', 0, 'free_a7e_1'),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b0'), pg_temp.u('b0'), 'used', 'sec', 0, 'free_a7e_2'),
  (pg_temp.u('d00'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b0'), pg_temp.u('b0'), 'active', 'sec', 20, 'pos_a7e_1');
UPDATE public.exos_checkout_sessions SET ticket_ids = ARRAY[pg_temp.u('f1'), pg_temp.u('f2')] WHERE session_id = 'zero_a7e_z1';
-- Org B's order in 10001 (never counted for A).
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_email, guest, quantity, amount_cents, currency, status, fulfilled_at)
VALUES ('cs_a7e_b1', pg_temp.u('e9'), pg_temp.u('2'), 'a7e-b1@guest.test', true, 1, 9900, 'usd', 'fulfilled', '2026-05-01 15:00Z');
INSERT INTO public.exos_order_locations (session_id, org_id, event_id, country, postal_code, source)
VALUES ('cs_a7e_b1', pg_temp.u('2'), pg_temp.u('e9'), 'US', '10001', 'stripe_billing');
INSERT INTO public.exos_tickets (id, event_id, org_id, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref)
VALUES (pg_temp.u('b1f'), pg_temp.u('e9'), pg_temp.u('2'), pg_temp.u('b0'), pg_temp.u('b0'), 'active', 'sec', 99, 'cs_a7e_b1');

-- e2 (New York, the event day 2026-12-20; tier on sale 2026-11-20 12:00 local):
--   q1 2 x paid 4000, 2026-12-11 03:00Z = Dec 10 22:00 local (10 days out)
--   q2 1 x 1000 card + 500 gift card, Dec 10 (10)
--   q3 $0 comp, 3 tickets, Dec 15 (5)
--   q4 1 x 2500, refunded later, Dec 15 (5): sold that day
--   q5 1 x 3000, Dec 22 (after the event: day 0)
--   q6 pending 5 x 10000: not a sale
-- e0 (2025-12-19): w1 4 x 8000 on Dec 9 (10), w2 1 x 2000 on Dec 18 (1).
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_email, guest, quantity, amount_cents, gift_card_cents,
                                           currency, status, fulfilled_at, free_kind, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents) VALUES
  ('cs_a7e_q1', pg_temp.u('e2'), pg_temp.u('1'), 'a7e-q1@guest.test', true, 2, 4000, 0, 'usd', 'fulfilled', '2026-12-11 03:00Z', NULL, NULL, NULL, NULL, NULL),
  ('cs_a7e_q2', pg_temp.u('e2'), pg_temp.u('1'), 'a7e-q2@guest.test', true, 1, 1000, 500, 'usd', 'fulfilled', '2026-12-10 15:00Z', NULL, NULL, NULL, NULL, NULL),
  ('zero_a7e_q3', pg_temp.u('e2'), pg_temp.u('1'), 'a7e-q3@guest.test', true, 3, 0, 0, 'usd', 'fulfilled', '2026-12-15 17:00Z', 'comp', 0, 0, 0, 0),
  ('cs_a7e_q4', pg_temp.u('e2'), pg_temp.u('1'), 'a7e-q4@guest.test', true, 1, 2500, 0, 'usd', 'refunded', '2026-12-15 18:00Z', NULL, NULL, NULL, NULL, NULL),
  ('cs_a7e_q5', pg_temp.u('e2'), pg_temp.u('1'), 'a7e-q5@guest.test', true, 1, 3000, 0, 'usd', 'fulfilled', '2026-12-22 15:00Z', NULL, NULL, NULL, NULL, NULL),
  ('cs_a7e_q6', pg_temp.u('e2'), pg_temp.u('1'), 'a7e-q6@guest.test', true, 5, 10000, 0, 'usd', 'pending', NULL, NULL, NULL, NULL, NULL, NULL),
  ('cs_a7e_w1', pg_temp.u('e0'), pg_temp.u('1'), 'a7e-w1@guest.test', true, 4, 8000, 0, 'usd', 'fulfilled', '2025-12-09 15:00Z', NULL, NULL, NULL, NULL, NULL),
  ('cs_a7e_w2', pg_temp.u('e0'), pg_temp.u('1'), 'a7e-w2@guest.test', true, 1, 2000, 0, 'usd', 'fulfilled', '2025-12-18 15:00Z', NULL, NULL, NULL, NULL, NULL);
SET LOCAL session_replication_role = origin;

INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by, revoked_at) VALUES
  (pg_temp.u('fa1'), pg_temp.u('1'), 'Owner key', 'sk_live_a7e1', 'a7ehash1', ARRAY['orders:read'], pg_temp.u('a1'), NULL),
  (pg_temp.u('fa2'), pg_temp.u('1'), 'Finance key', 'sk_live_a7e2', 'a7ehash2', ARRAY['orders:read'], pg_temp.u('a3'), NULL),
  (pg_temp.u('fa3'), pg_temp.u('1'), 'Scanner key', 'sk_live_a7e3', 'a7ehash3', ARRAY['orders:read'], pg_temp.u('a4'), NULL),
  (pg_temp.u('fa4'), pg_temp.u('1'), 'Revoked key', 'sk_live_a7e4', 'a7ehash4', ARRAY['orders:read'], pg_temp.u('a1'), now()),
  (pg_temp.u('fa9'), pg_temp.u('2'), 'B key', 'sk_live_a7e9', 'a7ehash9', ARRAY['orders:read'], pg_temp.u('a5'), NULL);

-- AR0 -------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public._exos_attendance_report(uuid,uuid,uuid)',
    'public._exos_attendance_pacing(uuid,uuid)',
    'public._exos_api_attendance(uuid,uuid,uuid,text,text,uuid)',
    'public._exos_postal_area(text,text)',
    'public._exos_attendance_tz(text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'AR0 anon runs ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'AR0 authenticated runs ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'AR0 service_role lost ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_attendance(uuid,uuid)', 'EXECUTE'), 'AR0 anon dashboard read';
  ASSERT has_function_privilege('authenticated', 'public.exos_event_attendance(uuid,uuid)', 'EXECUTE'), 'AR0 signed-in read';
  ASSERT (SELECT bool_and(p.prosecdef AND array_to_string(p.proconfig, ',') LIKE '%search_path=public, pg_temp%')
            FROM pg_proc p WHERE p.oid IN ('public._exos_attendance_report(uuid,uuid,uuid)'::regprocedure,
              'public._exos_attendance_pacing(uuid,uuid)'::regprocedure,
              'public._exos_api_attendance(uuid,uuid,uuid,text,text,uuid)'::regprocedure,
              'public.exos_event_attendance(uuid,uuid)'::regprocedure)), 'AR0 definer + search_path';
  ASSERT public._exos_postal_area('US', '10001-1234') = '10001' AND public._exos_postal_area('CA', 'K1A 0B1') = 'K1A'
     AND public._exos_postal_area('GB', 'SW1A 1AA') = 'SW1A' AND public._exos_postal_area('GB', 'SW1A1AA') = 'SW1A'
     AND public._exos_postal_area('DE', '10115') = '10115' AND public._exos_postal_area('US', NULL) IS NULL
     AND public._exos_postal_area('US', '  ') IS NULL, 'AR0 postal areas';
  ASSERT public._exos_attendance_tz('Not/AZone') = 'UTC' AND public._exos_attendance_tz(NULL) = 'UTC'
     AND public._exos_attendance_tz('America/New_York') = 'America/New_York', 'AR0 zones';
  RAISE NOTICE 'OK  AR0 shape and grants';
END $$;

-- AR1 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; a jsonb; p jsonb; t text;
BEGIN
  r := public._exos_attendance_report(pg_temp.u('1'), pg_temp.u('e1'), NULL);
  a := r->'attendance';
  ASSERT (r->>'min_buyers')::int = 5, 'AR1 threshold';
  ASSERT jsonb_array_length(a->'postal') = 2, 'AR1 two named areas: ' || (a->'postal')::text;
  SELECT x INTO p FROM jsonb_array_elements(a->'postal') x WHERE x->>'postal_code' = '10001';
  ASSERT p->>'country' = 'US' AND (p->>'buyers')::int = 5 AND (p->>'orders')::int = 5
     AND (p->>'tickets')::int = 5 AND (p->>'checked_in')::int = 1, 'AR1 10001 (ZIP+4 folded, refunded / pending / org B out): ' || p::text;
  SELECT x INTO p FROM jsonb_array_elements(a->'postal') x WHERE x->>'postal_code' = 'K1A';
  ASSERT p->>'country' = 'CA' AND (p->>'buyers')::int = 5 AND (p->>'tickets')::int = 5,
    'AR1 K1A: ' || p::text;
  -- 11211 (4 buyers, 5 orders, 10 tickets) + 94110 (1, 1, 1).
  ASSERT (a->'postal_other'->>'buyers')::int = 5 AND (a->'postal_other'->>'orders')::int = 6
     AND (a->'postal_other'->>'tickets')::int = 11 AND a->'postal_other'->>'label' = 'Other (fewer than 5)',
    'AR1 other: ' || (a->'postal_other')::text;
  -- n1 (card country) + z1 ($0, 2 tickets by ticket_ids, one used).
  ASSERT (a->'postal_unknown'->>'orders')::int = 2 AND (a->'postal_unknown'->>'tickets')::int = 3
     AND (a->'postal_unknown'->>'checked_in')::int = 1, 'AR1 no postal: ' || (a->'postal_unknown')::text;
  ASSERT (a->'totals'->>'orders')::int = 18 AND (a->'totals'->>'tickets')::int = 24 AND (a->'totals'->>'buyers')::int = 17
     AND (a->'totals'->>'located_orders')::int = 16 AND (a->'totals'->>'checked_in')::int = 2, 'AR1 totals: ' || (a->'totals')::text;
  ASSERT (a->>'other_tickets')::int = 1, 'AR1 the door ticket: ' || a::text;
  t := r::text;
  ASSERT position('11211' IN t) = 0 AND position('94110' IN t) = 0, 'AR1 a small area is never named';
  ASSERT position('@' IN t) = 0 AND position('guest.test' IN t) = 0 AND position('K1A 0B1' IN t) = 0
     AND position('cs_a7e' IN t) = 0, 'AR1 no buyer, full code or order id';
  RAISE NOTICE 'OK  AR1 postal rollup, suppression under 5 buyers';
END $$;

-- AR2 / AR3 -------------------------------------------------------------------
DO $$
DECLARE r jsonb; ev jsonb; cmp jsonb; d jsonb;
BEGIN
  r := public._exos_attendance_report(pg_temp.u('1'), pg_temp.u('e2'), pg_temp.u('e0'));
  ev := r->'pacing'->'event';
  ASSERT ev->>'event_day' = '2026-12-20' AND ev->>'timezone' = 'America/New_York' AND ev->>'currency' = 'USD', 'AR2 event: ' || ev::text;
  ASSERT ev->>'on_sale_day' = '2026-11-20' AND (ev->>'on_sale_days_before')::int = 30, 'AR2 on sale: ' || ev::text;
  ASSERT jsonb_array_length(ev->'rows') = 3, 'AR2 three sale days: ' || (ev->'rows')::text;
  d := pg_temp.day(ev, 10);
  ASSERT d->>'day' = '2026-12-10' AND (d->>'paid_orders')::int = 2 AND (d->>'paid_tickets')::int = 3
     AND (d->>'gross_cents')::bigint = 5500 AND (d->>'free_tickets')::int = 0 AND (d->>'cum_paid_tickets')::int = 3,
    'AR2 day 10 (local date, gift card in gross): ' || d::text;
  d := pg_temp.day(ev, 5);
  ASSERT (d->>'paid_orders')::int = 1 AND (d->>'paid_tickets')::int = 1 AND (d->>'gross_cents')::bigint = 2500
     AND (d->>'free_orders')::int = 1 AND (d->>'free_tickets')::int = 3 AND (d->>'cum_paid_tickets')::int = 4
     AND (d->>'cum_gross_cents')::bigint = 8000 AND (d->>'cum_free_tickets')::int = 3, 'AR2 day 5 ($0 apart, refunded sold): ' || d::text;
  d := pg_temp.day(ev, 0);
  ASSERT d->>'day' = '2026-12-20' AND (d->>'paid_tickets')::int = 1 AND (d->>'cum_paid_tickets')::int = 5
     AND (d->>'cum_gross_cents')::bigint = 11000, 'AR2 after the event folds into day 0: ' || d::text;
  ASSERT (ev->'totals'->>'paid_orders')::int = 4 AND (ev->'totals'->>'paid_tickets')::int = 5
     AND (ev->'totals'->>'gross_cents')::bigint = 11000 AND (ev->'totals'->>'free_orders')::int = 1
     AND (ev->'totals'->>'free_tickets')::int = 3, 'AR2 totals (pending out): ' || (ev->'totals')::text;
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ev->'rows') x WHERE (x->>'days_before')::int < 0), 'AR2 nothing below 0';
  RAISE NOTICE 'OK  AR2 pacing per local day, $0 tickets apart from gross';

  cmp := r->'pacing'->'comparison';
  ASSERT cmp->>'event_id' = pg_temp.u('e0')::text AND cmp->>'event_day' = '2025-12-19', 'AR3 comparison: ' || cmp::text;
  d := pg_temp.day(cmp, 10);
  ASSERT d->>'day' = '2025-12-09' AND (d->>'cum_paid_tickets')::int = 4 AND (d->>'gross_cents')::bigint = 8000,
    'AR3 aligned by days before (10): ' || d::text;
  ASSERT (pg_temp.day(cmp, 1)->>'cum_paid_tickets')::int = 5, 'AR3 day 1';
  ASSERT (pg_temp.day(ev, 10)->>'days_before') = (pg_temp.day(cmp, 10)->>'days_before'), 'AR3 same key';
  ASSERT (cmp->>'on_sale_days_before')::int = 28, 'AR3 comparison on sale (tier, local day): ' || cmp::text;
  ASSERT (SELECT array_agg(x->>'event_id') FROM jsonb_array_elements(r->'comparison_candidates') x)
       = ARRAY[pg_temp.u('e0')::text], 'AR3 candidates: earlier events of the org only: ' || (r->'comparison_candidates')::text;
  ASSERT r->'pacing'->'comparison' IS NOT NULL
     AND public._exos_attendance_report(pg_temp.u('1'), pg_temp.u('e2'), NULL)->'pacing'->'comparison' = 'null'::jsonb,
    'AR3 no comparison asked';
  RAISE NOTICE 'OK  AR3 a prior event aligns by days before the event';
END $$;

-- AR4 -------------------------------------------------------------------------
DO $$
DECLARE s text; r jsonb;
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'attendance%';
  FOREACH s IN ARRAY ARRAY['a1', 'a2', 'a3'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    r := public.exos_event_attendance(pg_temp.u('e2'), pg_temp.u('e0'));
    ASSERT (r->'pacing'->'event'->'totals'->>'paid_tickets')::int = 5, 'AR4 role ' || s;
  END LOOP;
  FOREACH s IN ARRAY ARRAY['a4', 'a5', 'a6'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    ASSERT pg_temp.st(format('SELECT public.exos_event_attendance(%L)', pg_temp.u('e2'))) LIKE '42501%', 'AR4 refused ' || s;
  END LOOP;
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_event_attendance(%L)', pg_temp.u('e2'))) LIKE '42501%', 'AR4 signed out';
  PERFORM pg_temp.act(pg_temp.u('a1'));
  -- An unknown event reads like another org's: no existence oracle.
  ASSERT pg_temp.st(format('SELECT public.exos_event_attendance(%L)', pg_temp.u('ee'))) LIKE '42501%', 'AR4 unknown event';
  s := pg_temp.st(format('SELECT public.exos_event_attendance(%L, %L)', pg_temp.u('e2'), pg_temp.u('e9')));
  ASSERT s LIKE 'P0002%comparison event not found%' AND position('Secret' IN s) = 0, 'AR4 cross-org comparison: ' || s;
  ASSERT pg_temp.st(format('SELECT public.exos_event_attendance(%L, %L)', pg_temp.u('e2'), pg_temp.u('e2'))) LIKE '22023%', 'AR4 same event';
  -- Org B's owner can't read A's event, nor compare B's against A's.
  PERFORM pg_temp.act(pg_temp.u('a5'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_attendance(%L, %L)', pg_temp.u('e9'), pg_temp.u('e2'))) LIKE 'P0002%', 'AR4 B compares A';
  ASSERT pg_temp.st(format('SELECT public._exos_attendance_report(%L, %L, NULL)', pg_temp.u('1'), pg_temp.u('e9'))) LIKE 'P0002%',
    'AR4 core: another org''s event';
  PERFORM pg_temp.act(NULL);
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'attendance%';
END $$;
-- As the client role.
DO $$ BEGIN PERFORM pg_temp.act(pg_temp.u('a3')); END $$;
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (public.exos_event_attendance(pg_temp.u('e1'))->'attendance'->'totals'->>'orders')::int = 18, 'AR4 finance as authenticated';
  ASSERT pg_temp.st(format('SELECT public._exos_attendance_report(%L, %L, NULL)', pg_temp.u('1'), pg_temp.u('e1'))) LIKE '42501%',
    'AR4 the core is not client-callable';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.st(format('SELECT public.exos_event_attendance(%L)', pg_temp.u('e1'))) LIKE '42501%', 'AR4 anon no grant';
END $$;
RESET ROLE;
DO $$ BEGIN PERFORM pg_temp.act(NULL); END $$;
DO $$ BEGIN RAISE NOTICE 'OK  AR4 roles and cross-org'; END $$;

-- AR5 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'attendance%';
  r := public._exos_api_attendance(pg_temp.u('1'), pg_temp.u('e1'), NULL, 'api_key', pg_temp.u('fa1')::text, NULL);
  ASSERT (r->'attendance'->'totals'->>'orders')::int = 18, 'AR5 owner key';
  r := public._exos_api_attendance(pg_temp.u('1'), pg_temp.u('e2'), pg_temp.u('e0'), 'api_key', pg_temp.u('fa2')::text, NULL);
  ASSERT (r->'pacing'->'comparison'->'totals'->>'paid_tickets')::int = 5, 'AR5 finance key + comparison';
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, NULL)', pg_temp.u('1'), pg_temp.u('e1'), 'api_key', pg_temp.u('fa3')))
    LIKE '42501%', 'AR5 a scanner''s key';
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, NULL)', pg_temp.u('1'), pg_temp.u('e1'), 'api_key', pg_temp.u('fa4')))
    LIKE '42501%', 'AR5 revoked key';
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, NULL)', pg_temp.u('1'), pg_temp.u('e1'), 'api_key', pg_temp.u('fa9')))
    LIKE '42501%', 'AR5 another org''s key';
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, NULL)', pg_temp.u('1'), pg_temp.u('e1'), 'api_key', 'not-a-uuid'))
    LIKE '42501%', 'AR5 a bad key id';
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, NULL)', pg_temp.u('1'), pg_temp.u('e9'), 'api_key', pg_temp.u('fa1')))
    LIKE 'P0002%', 'AR5 another org''s event: 404';
  -- Personal / OAuth tokens: the user's role now.
  r := public._exos_api_attendance(pg_temp.u('1'), pg_temp.u('e1'), NULL, 'pat', 'pat-a7e-1', pg_temp.u('a2'));
  ASSERT (r->'attendance'->'totals'->>'tickets')::int = 24, 'AR5 manager PAT';
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, %L)', pg_temp.u('1'), pg_temp.u('e1'), 'oauth', 'oa-a7e-1', pg_temp.u('a4')))
    LIKE '42501%', 'AR5 scanner OAuth token';
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, %L)', pg_temp.u('1'), pg_temp.u('e1'), 'pat', 'pat-a7e-2', pg_temp.u('a5')))
    LIKE '42501%', 'AR5 another org''s owner';
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, %L)', pg_temp.u('1'), pg_temp.u('e1'), 'mystery', 'x', pg_temp.u('a1')))
    LIKE '42501%', 'AR5 unknown credential kind';
  RAISE NOTICE 'OK  AR5 API: key creator''s or token user''s role, org-scoped';
END $$;

-- AR6 -------------------------------------------------------------------------
DO $$
DECLARE i int;
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'attendance%';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  FOR i IN 1..20 LOOP PERFORM public.exos_event_attendance(pg_temp.u('e1')); END LOOP;
  ASSERT pg_temp.st(format('SELECT public.exos_event_attendance(%L)', pg_temp.u('e1'))) LIKE '54000%', 'AR6 dashboard: the 21st';
  -- A refused caller never reaches the bucket (role first).
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_attendance(%L)', pg_temp.u('e1'))) LIKE '42501%', 'AR6 role before rate';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_rate_windows WHERE bucket = 'attendance:' || pg_temp.u('a4')::text), 'AR6 no bucket for a refusal';
  PERFORM pg_temp.act(pg_temp.u('a1'));
  ASSERT public.exos_event_attendance(pg_temp.u('e1')) IS NOT NULL, 'AR6 per user';
  PERFORM pg_temp.act(NULL);
  FOR i IN 1..20 LOOP
    PERFORM public._exos_api_attendance(pg_temp.u('1'), pg_temp.u('e1'), NULL, 'api_key', pg_temp.u('fa2')::text, NULL);
  END LOOP;
  ASSERT pg_temp.st(format('SELECT public._exos_api_attendance(%L, %L, NULL, %L, %L, NULL)', pg_temp.u('1'), pg_temp.u('e1'), 'api_key', pg_temp.u('fa2')))
    LIKE '54000%', 'AR6 API: the 21st';
  ASSERT public._exos_api_attendance(pg_temp.u('1'), pg_temp.u('e1'), NULL, 'api_key', pg_temp.u('fa1')::text, NULL) IS NOT NULL, 'AR6 per key';
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'attendance%';
  RAISE NOTICE 'OK  AR6 rate limits';
END $$;

-- AR7 -------------------------------------------------------------------------
DO $$
DECLARE i int; k text; v_def text;
BEGIN
  v_def := pg_get_functiondef('public.exos_audit_export(uuid,text,integer,uuid)'::regprocedure);
  ASSERT position('/* exos: attendance export kinds */' IN v_def) > 0 AND position('/* exos: attendance export cap */' IN v_def) > 0
     AND position('/* exos: export daily cap */' IN v_def) > 0, 'AR7 markers (and the earlier cap)';
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audit-export:%';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  FOREACH k IN ARRAY ARRAY['attendance', 'settlement', 'sales_tax', 'journal'] LOOP
    ASSERT public.exos_audit_export(NULL, k, 7, pg_temp.u('e1')), 'AR7 ' || k;
  END LOOP;
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'export.run'
           AND entity_id IN ('attendance', 'settlement', 'sales_tax', 'journal') AND event_id = pg_temp.u('e1')) = 4, 'AR7 logged';
  ASSERT pg_temp.st(format('SELECT public.exos_audit_export(%L, %L, 1)', pg_temp.u('1'), 'xlsx')) LIKE '22023%', 'AR7 unknown kind';
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_audit_export(%L, %L, 1)', pg_temp.u('1'), 'attendance')) LIKE '42501%', 'AR7 scanner';
  -- The new kinds count toward the 200 a day (4 above + 196 here).
  PERFORM pg_temp.act(pg_temp.u('a1'));
  FOR i IN 1..196 LOOP
    DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audit-export:%';
    PERFORM public.exos_audit_export(pg_temp.u('1'), (ARRAY['attendance', 'settlement', 'sales_tax', 'journal'])[1 + i % 4], i);
  END LOOP;
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audit-export:%';
  ASSERT pg_temp.st(format('SELECT public.exos_audit_export(%L, %L, 1)', pg_temp.u('1'), 'audit')) LIKE '54000%', 'AR7 the cap counts them';
  PERFORM pg_temp.act(NULL);
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audit-export:%';
  RAISE NOTICE 'OK  AR7 XLSX exports log export.run';
END $$;

-- AR8 -------------------------------------------------------------------------
-- Rows today's constraints refuse (a location without a country, an order with
-- neither account nor email); the report must not depend on them. Rolled back.
ALTER TABLE public.exos_order_locations ALTER COLUMN country DROP NOT NULL;
ALTER TABLE public.exos_checkout_sessions DROP CONSTRAINT exos_checkout_sessions_buyer_chk;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
  (pg_temp.u('e4'), pg_temp.u('1'), 'A7E Sums', 'a7e-sums', 'published', '2027-02-01 20:00 America/New_York', 'America/New_York', 500, pg_temp.u('a1'));
SET LOCAL session_replication_role = replica;
CREATE TEMP TABLE fx4 (sid text, email text, qty int, cents int, country text, postal text, free_kind text);
INSERT INTO fx4 VALUES
  ('cs_a7e4_h1', 'a7e-h1@guest.test', 1, 2000, 'US', '60601', NULL),
  ('cs_a7e4_h2', 'a7e-h2@guest.test', 1, 2000, 'US', '60601', NULL),
  ('cs_a7e4_h3', 'a7e-h3@guest.test', 2, 4000, 'US', '60601', NULL),
  ('cs_a7e4_m1', NULL, 1, 2000, 'US', '60601', NULL),
  ('cs_a7e4_m2', '  ', 1, 2000, 'US', '60601', NULL),
  ('cs_a7e4_nc', 'a7e-nc@guest.test', 3, 6000, NULL, '12345', NULL),
  ('cs_a7e4_k1', 'a7e-k1@guest.test', 1, 2000, 'US', '73301', NULL),
  ('cs_a7e4_u1', 'a7e-u1@guest.test', 2, 4000, NULL, NULL, NULL),
  ('zero_a7e4_z', 'a7e-z4@guest.test', 1, 0, NULL, NULL, 'comp');
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents,
                                           currency, status, fulfilled_at, free_kind, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents)
SELECT sid, pg_temp.u('e4'), pg_temp.u('1'), NULL, email, true, qty, cents, 'usd', 'fulfilled', timestamptz '2027-01-20 15:00Z', free_kind,
       CASE WHEN free_kind IS NOT NULL THEN 0 END, CASE WHEN free_kind IS NOT NULL THEN 0 END,
       CASE WHEN free_kind IS NOT NULL THEN 0 END, CASE WHEN free_kind IS NOT NULL THEN 0 END
  FROM fx4;
INSERT INTO public.exos_order_locations (session_id, org_id, event_id, country, postal_code, source)
SELECT sid, pg_temp.u('1'), pg_temp.u('e4'), country, postal, 'stripe_billing' FROM fx4 WHERE postal IS NOT NULL;
INSERT INTO public.exos_tickets (id, event_id, org_id, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref)
SELECT gen_random_uuid(), pg_temp.u('e4'), pg_temp.u('1'), pg_temp.u('b0'), pg_temp.u('b0'), 'active', 'sec', 20, fx4.sid
  FROM fx4 CROSS JOIN LATERAL generate_series(1, fx4.qty) WHERE fx4.free_kind IS NULL;
INSERT INTO public.exos_tickets (id, event_id, org_id, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref) VALUES
  (pg_temp.u('f4'), pg_temp.u('e4'), pg_temp.u('1'), pg_temp.u('b0'), pg_temp.u('b0'), 'used', 'sec', 0, 'free_a7e4_1');
UPDATE public.exos_checkout_sessions SET ticket_ids = ARRAY[pg_temp.u('f4')] WHERE session_id = 'zero_a7e4_z';
SET LOCAL session_replication_role = origin;
DO $$
DECLARE a jsonb; p jsonb; v_rows int; v_live int;
BEGIN
  a := public._exos_attendance_report(pg_temp.u('1'), pg_temp.u('e4'), NULL)->'attendance';
  -- 60601: three guests + two orders with no email = 5 buyers, so it's named.
  SELECT x INTO p FROM jsonb_array_elements(a->'postal') x WHERE x->>'postal_code' = '60601';
  ASSERT p IS NOT NULL AND (p->>'buyers')::int = 5 AND (p->>'orders')::int = 5 AND (p->>'tickets')::int = 6,
    'AR8 orders with no email are distinct buyers: ' || a::text;
  -- The no-country area (3 tickets) and 73301 (1) are Other.
  ASSERT (a->'postal_other'->>'tickets')::int = 4 AND (a->'postal_other'->>'orders')::int = 2,
    'AR8 a no-country area folds into Other: ' || (a->'postal_other')::text;
  ASSERT position('12345' IN a::text) = 0, 'AR8 the no-country area is not named';
  ASSERT (a->'postal_unknown'->>'tickets')::int = 3, 'AR8 no postal code: ' || (a->'postal_unknown')::text;
  SELECT coalesce(sum((x->>'tickets')::int), 0) INTO v_rows FROM jsonb_array_elements(a->'postal') x;
  v_rows := v_rows + (a->'postal_other'->>'tickets')::int + (a->'postal_unknown'->>'tickets')::int;
  SELECT count(*) INTO v_live FROM public.exos_tickets t
   WHERE t.event_id = pg_temp.u('e4') AND t.status IN ('active', 'used');
  ASSERT v_rows = v_live AND v_rows = (a->'totals'->>'tickets')::int AND v_live = 13,
    format('AR8 rows %s = live %s = totals %s', v_rows, v_live, a->'totals'->>'tickets');
  -- The same sum holds for e1.
  a := public._exos_attendance_report(pg_temp.u('1'), pg_temp.u('e1'), NULL)->'attendance';
  SELECT coalesce(sum((x->>'tickets')::int), 0) INTO v_rows FROM jsonb_array_elements(a->'postal') x;
  ASSERT v_rows + (a->'postal_other'->>'tickets')::int + (a->'postal_unknown'->>'tickets')::int = (a->'totals'->>'tickets')::int,
    'AR8 e1 rows add up';
  RAISE NOTICE 'OK  AR8 the rollup adds up to the live tickets';
END $$;

ROLLBACK;
