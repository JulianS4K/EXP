-- ============================================================================
-- Posh webhooks + the capped Posh tier (mig 20261029150000).
--   P1 the webhook: owner / manager create and rotate it; the token is shown
--      once and stored hashed; a rotated (or disabled) URL is refused;
--      finance sees the status without the token
--   P2 the cap: holds its unsold seats off Exos (tier + house); growing it
--      needs free seats; a scanner / outsider can't set it; table, uncapped
--      and shared-capacity ticket types refused
--   P3 a confirmed order takes its seats from the cap (Exos's free count
--      doesn't move) and lands on the door list with its codes, source Posh
--   P4 idempotent: the same body, the same Posh order id, the body hash when
--      there's no order id
--   P5 pending: recorded, no seat, no door entry; the Order Created for the
--      same id confirms it; a pending after that changes nothing
--   P6 oversell: past the cap is flagged on the order, the cap and the door
--      entry, takes a free Exos seat, and stays flagged until acknowledged;
--      uncovered when no seat is free
--   P7 mapping: unmatched orders count nothing; assigning one links its Posh
--      event; the next order from that event matches by itself; a cap set
--      later counts the orders already in
--   P8 cancel: seats back to the cap, door entries voided
--   P9 the cap can't go below what Posh sold inside it
--   P10 grants + RLS: tables service role only; helpers and the ingest are
--      service role only; every new definer function pins search_path
--   P11 the resale rule doesn't apply: a small event gets a Posh cap while a
--      marketplace allocation is refused; nothing goes to the resale table
--   P12 retention: deliveries past the window are deleted; header names only
--   P13 cross-org: an event of another org can't be linked or assigned
-- Self-contained (b5 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- The 250-capacity resale rule on (run_p0.sh turns it off for older fixtures).
INSERT INTO public.exos_platform_settings (key, value) VALUES ('resale_min_capacity', '250')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
-- Integration: since mig 20261029090000 the resale rule is the free tier
-- (<= 150 seats) plus the organizer's opt-in; run_p0.sh turns both off for older
-- fixtures, so put the defaults back for this file.
DELETE FROM public.exos_platform_settings WHERE key IN ('free_tier_max_capacity', 'resale_consent_required');

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('b5000000-0000-0000-0000-0000000000a1','b5own@x.com',now()),
  ('b5000000-0000-0000-0000-0000000000a2','b5mgr@x.com',now()),
  ('b5000000-0000-0000-0000-0000000000a3','b5scan@x.com',now()),
  ('b5000000-0000-0000-0000-0000000000a4','b5fin@x.com',now()),
  ('b5000000-0000-0000-0000-0000000000a6','b5out@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('b5000000-0000-0000-0000-000000000001','Posh Org','posh-org-b5','b5000000-0000-0000-0000-0000000000a1'),
  ('b5000000-0000-0000-0000-000000000002','Other Org','posh-other-b5','b5000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('b5000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-0000000000a1','owner'),
  ('b5000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-0000000000a2','manager'),
  ('b5000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-0000000000a3','scanner'),
  ('b5000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-0000000000a4','finance'),
  ('b5000000-0000-0000-0000-000000000002','b5000000-0000-0000-0000-0000000000a6','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,purchase_limits,created_by) VALUES
  ('b5000000-0000-0000-0000-0000000000e1','b5000000-0000-0000-0000-000000000001','Posh Party','posh-party-b5','published',
   now() + interval '10 days','America/New_York',0,0,'{"maxPerOrder":4}','b5000000-0000-0000-0000-0000000000a1'),
  ('b5000000-0000-0000-0000-0000000000e3','b5000000-0000-0000-0000-000000000001','Mystery Night','mystery-b5','published',
   now() + interval '12 days','America/New_York',3,0,'{}','b5000000-0000-0000-0000-0000000000a1'),
  ('b5000000-0000-0000-0000-0000000000e2','b5000000-0000-0000-0000-000000000002','Elsewhere','elsewhere-b5','published',
   now() + interval '10 days','America/New_York',0,0,'{}','b5000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order,kind,party_size) VALUES
  ('b5000000-0000-0000-0000-0000000000d1','b5000000-0000-0000-0000-0000000000e1','GA',25,100,0,1,'standard',NULL),
  ('b5000000-0000-0000-0000-0000000000d2','b5000000-0000-0000-0000-0000000000e1','Free RSVP',0,0,0,2,'standard',NULL),
  ('b5000000-0000-0000-0000-0000000000d4','b5000000-0000-0000-0000-0000000000e1','Booth',300,5,0,3,'table',4),
  ('b5000000-0000-0000-0000-0000000000d3','b5000000-0000-0000-0000-0000000000e3','GA',20,3,0,1,'standard',NULL);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('b5000000-0000-0000-0000-0000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated;
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
-- A delivery as the edge function makes it.
CREATE FUNCTION pg_temp.hook(p_body text, p_kind text, p_order jsonb, p_replay boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_posh_ingest(current_setting('b5.th'), pg_temp.h(p_body), p_kind, p_order,
                                 jsonb_build_object('body', p_body), ARRAY['Content-Type', 'User-Agent'], p_replay)
$$;
CREATE FUNCTION pg_temp.ord(p_id text) RETURNS public.exos_posh_orders LANGUAGE sql AS $$
  SELECT * FROM public.exos_posh_orders WHERE org_id = pg_temp.u('01') AND order_key = 'o:' || p_id
$$;
CREATE FUNCTION pg_temp.cap() RETURNS public.exos_posh_caps LANGUAGE sql AS $$
  SELECT * FROM public.exos_posh_caps WHERE event_id = pg_temp.u('e1')
$$;
CREATE FUNCTION pg_temp.sold(p text) RETURNS int LANGUAGE sql AS $$ SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u(p) $$;

-- P1 ------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b5000000-0000-0000-0000-0000000000a4');
SELECT set_config('b5.fin_conn', pg_temp.refused($$SELECT public.exos_posh_connect(pg_temp.u('01'))$$, 'owner or manager only')::text, true);
SELECT pg_temp.act('b5000000-0000-0000-0000-0000000000a3');
SELECT set_config('b5.scan_conn', pg_temp.refused($$SELECT public.exos_posh_connect(pg_temp.u('01'))$$, 'owner or manager only')::text, true);
SELECT set_config('b5.scan_st', pg_temp.refused($$SELECT public.exos_posh_status(pg_temp.u('01'))$$, 'not a member')::text, true);
SELECT pg_temp.act('b5000000-0000-0000-0000-0000000000a6');
SELECT set_config('b5.out_conn', pg_temp.refused($$SELECT public.exos_posh_connect(pg_temp.u('01'))$$, 'owner or manager only')::text, true);
SELECT pg_temp.act('b5000000-0000-0000-0000-0000000000a2');
SELECT set_config('b5.c1', public.exos_posh_connect(pg_temp.u('01'))::text, true);
SELECT set_config('b5.c2', public.exos_posh_connect(pg_temp.u('01'))::text, true);
SELECT pg_temp.act('b5000000-0000-0000-0000-0000000000a4');
SELECT set_config('b5.st_fin', public.exos_posh_status(pg_temp.u('01'))::text, true);
RESET ROLE;
SELECT set_config('b5.th', pg_temp.h(current_setting('b5.c2')::jsonb ->> 'token'), true);
DO $t$
DECLARE
  c1 jsonb := current_setting('b5.c1')::jsonb;
  c2 jsonb := current_setting('b5.c2')::jsonb;
  s  jsonb := current_setting('b5.st_fin')::jsonb;
  k  public.exos_posh_hooks%ROWTYPE;
BEGIN
  ASSERT current_setting('b5.fin_conn')::boolean AND current_setting('b5.scan_conn')::boolean
     AND current_setting('b5.out_conn')::boolean AND current_setting('b5.scan_st')::boolean, 'P1: refusals';
  ASSERT c1 ->> 'token' ~ '^[0-9a-f]{64}$' AND NOT (c1 ->> 'rotated')::boolean, 'P1: 32-byte token ' || c1::text;
  ASSERT (c2 ->> 'rotated')::boolean AND c2 ->> 'token' <> c1 ->> 'token', 'P1: rotated';
  SELECT * INTO k FROM public.exos_posh_hooks WHERE org_id = pg_temp.u('01');
  ASSERT k.token_hash = pg_temp.h(c2 ->> 'token') AND k.token_hint = right(c2 ->> 'token', 4)
     AND k.rotated_at IS NOT NULL, 'P1: stored as its hash';
  ASSERT position(c2 ->> 'token' in s::text) = 0 AND position(k.token_hash in s::text) = 0, 'P1: status never shows the token';
  ASSERT (s ->> 'connected')::boolean AND s ->> 'hint' = k.token_hint AND NOT (s ->> 'can_manage')::boolean, 'P1: finance status ' || s::text;
  ASSERT public.exos_posh_ingest(pg_temp.h(c1 ->> 'token'), pg_temp.h('x'), 'order_created', '{}') ->> 'outcome' = 'unknown_hook',
         'P1: the old URL is refused';
  ASSERT public.exos_posh_ingest('nothex', pg_temp.h('x'), 'order_created', '{}') ->> 'outcome' = 'unknown_hook', 'P1: junk token';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_posh_webhook_log WHERE org_id = pg_temp.u('01')), 'P1: a refused call logs nothing';
  RAISE NOTICE 'OK  P1 webhook create / rotate / hashed / refused';
END $t$;

-- P2 + P11 -------------------------------------------------------------------
DO $t$
BEGIN
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.refused($$SELECT public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d1'), 10)$$, 'owner or manager only'), 'P2: scanner';
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a6');
  ASSERT pg_temp.refused($$SELECT public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d1'), 10)$$, 'owner or manager only'), 'P2: outsider';
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.refused($$SELECT public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d2'), 10)$$, 'capacity first'), 'P2: uncapped';
  ASSERT pg_temp.refused($$SELECT public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d4'), 1)$$, 'table'), 'P2: table';
  ASSERT pg_temp.refused($$SELECT public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d3'), 1)$$, 'not found for this event'), 'P2: other event''s tier';
  ASSERT pg_temp.refused($$SELECT public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d1'), 101)$$, 'only 100 more'), 'P2: more than is free';
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 100, 'P2: before';
  PERFORM public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d1'), 10);
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 90 AND public.exos_effective_available(pg_temp.u('d1')) = 90,
         'P2: the cap is held off Exos: ' || public.exos_tier_available(pg_temp.u('d1'));
  ASSERT public.exos_channel_allocated(pg_temp.u('d1')) = 10, 'P2: via exos_channel_allocated';
  -- P11: a 100-seat event: resale is locked, Posh isn't.
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e1')), 'P11: under the resale minimum';
  ASSERT pg_temp.refused($$SELECT public.exos_set_channel_allocation(pg_temp.u('e1'), 'stubhub', pg_temp.u('d1'), 5)$$, 'resale marketplaces'),
         'P11: the marketplace allocation is refused';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1')), 'P11: nothing in the resale table';
  -- The house cap reads it too.
  UPDATE public.exos_events SET total_tickets = 100 WHERE id = pg_temp.u('e1');
  ASSERT public.exos_event_house_available(pg_temp.u('e1')) = 90, 'P2: house ' || public.exos_event_house_available(pg_temp.u('e1'));
  UPDATE public.exos_events SET total_tickets = 0 WHERE id = pg_temp.u('e1');
  -- Shrink and grow back.
  PERFORM public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d1'), 4);
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 96, 'P2: shrink gives seats back';
  PERFORM public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d1'), 10);
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 90, 'P2: grow';
  RAISE NOTICE 'OK  P2 cap held off Exos; P11 resale rule not applied';
END $t$;

-- P3 / P4 --------------------------------------------------------------------
DO $t$
DECLARE r jsonb; o public.exos_posh_orders%ROWTYPE; n int;
BEGIN
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a2');
  r := public.exos_posh_link_event(pg_temp.u('01'), 'https://posh.vip/e/posh-party?t=ig', pg_temp.u('e1'));
  ASSERT r ->> 'posh_ref' = 'posh-party', 'P3: a posh.vip link becomes the slug ' || r::text;
  PERFORM pg_temp.act(NULL);
  r := pg_temp.hook('body-o1', 'order_created', '{"order_id":"o1","event_slug":"posh-party","quantity":2,"codes":["ab 12","CD34"],
      "buyer_name":"Ada Lovelace","buyer_email":"ADA@x.com","ticket_label":"General","total":"50.00","currency":"USD"}');
  ASSERT r ->> 'outcome' = 'confirmed', 'P3: ' || r::text;
  o := pg_temp.ord('o1');
  ASSERT o.state = 'confirmed' AND o.event_id = pg_temp.u('e1') AND o.counted AND o.cap_qty = 2 AND o.over_qty = 0
     AND o.buyer_email = 'ada@x.com' AND o.currency = 'usd' AND o.total = 50, 'P3: order';
  ASSERT pg_temp.sold('d1') = 2 AND (SELECT tickets_sold FROM public.exos_events WHERE id = pg_temp.u('e1')) = 2, 'P3: in the Exos count';
  ASSERT (pg_temp.cap()).cap_used = 2 AND public.exos_tier_available(pg_temp.u('d1')) = 90, 'P3: from the cap; Exos free unchanged';
  SELECT count(*) INTO n FROM public.exos_guest_list_entries g JOIN public.exos_guest_lists l ON l.id = g.list_id
   WHERE g.event_id = pg_temp.u('e1') AND l.name = 'Posh' AND g.source = 'Posh' AND g.guest_name = 'Ada Lovelace'
     AND g.external_code IN ('AB12', 'CD34') AND g.plus_ones = 0 AND g.ticket_label = 'General' AND g.note IS NULL;
  ASSERT n = 2, 'P3: two door entries with codes, got ' || n;
  -- P4: the same body; the same order id in another body; no order id.
  ASSERT pg_temp.hook('body-o1', 'order_created', '{"order_id":"o1","quantity":2}') ->> 'outcome' = 'duplicate', 'P4: same body';
  ASSERT pg_temp.hook('body-o1-again', 'order_created', '{"order_id":"o1","event_slug":"posh-party","quantity":5}') ->> 'outcome' = 'duplicate', 'P4: same id';
  ASSERT pg_temp.sold('d1') = 2 AND (pg_temp.cap()).cap_used = 2
     AND (SELECT count(*) FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1')) = 2, 'P4: counted once';
  r := pg_temp.hook('body-noid', 'order_created', '{"event_slug":"posh-party","quantity":1}');
  ASSERT r ->> 'outcome' = 'confirmed', 'P4: no id ' || r::text;
  ASSERT (SELECT order_key FROM public.exos_posh_orders WHERE id = (r ->> 'order_id')::uuid) = 'h:' || pg_temp.h('body-noid'), 'P4: keyed by body hash';
  ASSERT pg_temp.hook('body-noid', 'order_created', '{"event_slug":"posh-party","quantity":1}', true) ->> 'outcome' = 'duplicate', 'P4: replayed no-id body';
  ASSERT pg_temp.sold('d1') = 3 AND (pg_temp.cap()).cap_used = 3, 'P4: no-id order once';
  ASSERT (SELECT plus_ones FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND guest_name = 'Posh buyer') = 0,
         'P4: nameless buyer still on the door';
  RAISE NOTICE 'OK  P3 confirmed order counted + door; P4 idempotent';
END $t$;

-- P5 ------------------------------------------------------------------------
DO $t$
DECLARE r jsonb; o public.exos_posh_orders%ROWTYPE;
BEGIN
  PERFORM pg_temp.act(NULL);
  r := pg_temp.hook('body-o2p', 'pending_order_created', '{"order_id":"o2","event_slug":"posh-party","quantity":3,"buyer_name":"Bo"}');
  ASSERT r ->> 'outcome' = 'pending', 'P5: ' || r::text;
  o := pg_temp.ord('o2');
  ASSERT o.state = 'pending' AND NOT o.counted AND pg_temp.sold('d1') = 3 AND (pg_temp.cap()).cap_used = 3, 'P5: no seat';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND guest_name = 'Bo'), 'P5: no door entry';
  r := pg_temp.hook('body-o2c', 'order_created', '{"order_id":"o2","event_slug":"posh-party","quantity":3,"buyer_name":"Bo","buyer_email":"bo@x.com"}');
  ASSERT r ->> 'outcome' = 'confirmed', 'P5: confirmed ' || r::text;
  o := pg_temp.ord('o2');
  ASSERT o.state = 'confirmed' AND o.counted AND o.cap_qty = 3 AND o.buyer_email = 'bo@x.com' AND o.confirmed_at IS NOT NULL, 'P5: order';
  ASSERT pg_temp.sold('d1') = 6 AND (pg_temp.cap()).cap_used = 6, 'P5: seats now';
  ASSERT (SELECT plus_ones FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND guest_name = 'Bo' AND external_code IS NULL) = 2,
         'P5: no codes: one entry with plus-ones';
  ASSERT pg_temp.hook('body-o2p2', 'pending_order_created', '{"order_id":"o2","quantity":3}') ->> 'outcome' = 'duplicate', 'P5: late pending';
  ASSERT (pg_temp.ord('o2')).state = 'confirmed' AND pg_temp.sold('d1') = 6, 'P5: still confirmed';
  -- A confirmation that leaves the quantity out keeps the pending order's.
  PERFORM pg_temp.hook('body-o9p', 'pending_order_created', '{"order_id":"o9","event_slug":"posh-party","quantity":2}');
  PERFORM pg_temp.hook('body-o9c', 'order_created', '{"order_id":"o9","event_slug":"posh-party"}');
  ASSERT (pg_temp.ord('o9')).quantity = 2 AND (pg_temp.ord('o9')).cap_qty = 2 AND pg_temp.sold('d1') = 8, 'P5: quantity kept';
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_posh_cancel_order((pg_temp.ord('o9')).id);
  ASSERT pg_temp.sold('d1') = 6 AND (pg_temp.cap()).cap_used = 6, 'P5: o9 cancelled again';
  RAISE NOTICE 'OK  P5 pending then confirmed';
END $t$;

-- P6 ------------------------------------------------------------------------
DO $t$
DECLARE r jsonb; o public.exos_posh_orders%ROWTYPE; s jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  -- 4 left in the cap; 7 sold on Posh.
  r := pg_temp.hook('body-o3', 'order_created', '{"order_id":"o3","event_slug":"posh-party","quantity":7,"buyer_name":"Cy"}');
  o := pg_temp.ord('o3');
  ASSERT o.cap_qty = 4 AND o.over_qty = 3 AND o.house_qty = 3 AND o.uncovered_qty = 0 AND o.attention LIKE 'oversold: 3%', 'P6: order ' || row_to_json(o)::text;
  ASSERT (pg_temp.cap()).cap_used = 10 AND (pg_temp.cap()).over_qty = 3, 'P6: cap';
  ASSERT pg_temp.sold('d1') = 13 AND public.exos_tier_available(pg_temp.u('d1')) = 87, 'P6: past the cap took free seats';
  ASSERT (SELECT note FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND guest_name = 'Cy') = 'Posh oversell: 3 of 7 past the Posh cap',
         'P6: the door sees it';
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a4');
  s := public.exos_posh_event_status(pg_temp.u('e1'));
  ASSERT (s -> 'cap' ->> 'oversold_unacked')::int = 3 AND (s -> 'cap' ->> 'remaining')::int = 0
     AND (s -> 'sales' ->> 'confirmed_tickets')::int = 13 AND NOT (s ->> 'can_manage')::boolean, 'P6: finance status ' || s::text;
  ASSERT pg_temp.refused($$SELECT public.exos_posh_ack_oversell(pg_temp.u('e1'))$$, 'owner or manager only'), 'P6: finance can''t ack';
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a1');
  ASSERT public.exos_posh_ack_oversell(pg_temp.u('e1')) = 3, 'P6: ack';
  ASSERT (public.exos_posh_event_status(pg_temp.u('e1')) -> 'cap' ->> 'oversold_unacked')::int = 0, 'P6: flag cleared';
  -- No free seat left at all: uncovered.
  UPDATE public.exos_ticket_tiers SET capacity = 13 WHERE id = pg_temp.u('d1');
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.hook('body-o5', 'order_created', '{"order_id":"o5","event_slug":"posh-party","quantity":2}');
  o := pg_temp.ord('o5');
  ASSERT o.cap_qty = 0 AND o.over_qty = 2 AND o.house_qty = 0 AND o.uncovered_qty = 2, 'P6: uncovered ' || row_to_json(o)::text;
  ASSERT pg_temp.sold('d1') = 13 AND (pg_temp.cap()).uncovered_qty = 2 AND (pg_temp.cap()).over_qty = 5, 'P6: never over the tier';
  UPDATE public.exos_ticket_tiers SET capacity = 100 WHERE id = pg_temp.u('d1');
  RAISE NOTICE 'OK  P6 oversell flagged, acked, uncovered';
END $t$;

-- P7 / P13 -------------------------------------------------------------------
DO $t$
DECLARE r jsonb; o public.exos_posh_orders%ROWTYPE; s jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  r := pg_temp.hook('body-o4', 'order_created', '{"order_id":"o4","event_id":"65f0aa","event_name":"Mystery Night","quantity":1,"codes":["M1"]}');
  ASSERT r ->> 'outcome' = 'unmatched', 'P7: ' || r::text;
  ASSERT (pg_temp.ord('o4')).event_id IS NULL AND NOT (pg_temp.ord('o4')).counted, 'P7: unmatched counts nothing';
  r := pg_temp.hook('body-o6p', 'pending_order_created', '{"order_id":"o6","event_name":"Mystery Night","quantity":1}');
  ASSERT r ->> 'outcome' = 'unmatched', 'P7: pending unmatched';
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a4');
  s := public.exos_posh_status(pg_temp.u('01'));
  ASSERT (s -> 'counts' ->> 'unmatched')::int = 2 AND jsonb_array_length(s -> 'unmatched') = 2
     AND s -> 'unmatched' -> 0 ->> 'posh_event_name' = 'Mystery Night', 'P7: listed ' || s::text;
  ASSERT position('@' in (s -> 'unmatched')::text) = 0, 'P7: no buyer email in the unmatched list';
  ASSERT pg_temp.refused($$SELECT public.exos_posh_assign_order((pg_temp.ord('o4')).id, pg_temp.u('e3'))$$, 'owner or manager only'), 'P7: finance';
  -- P13: another org's event, and another org's owner.
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a2');
  ASSERT pg_temp.refused($$SELECT public.exos_posh_assign_order((pg_temp.ord('o4')).id, pg_temp.u('e2'))$$, 'isn''t this organization''s'), 'P13: assign elsewhere';
  ASSERT pg_temp.refused($$SELECT public.exos_posh_link_event(pg_temp.u('01'), 'x', pg_temp.u('e2'))$$, 'isn''t this organization''s'), 'P13: link elsewhere';
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a6');
  ASSERT pg_temp.refused($$SELECT public.exos_posh_link_event(pg_temp.u('01'), 'x', pg_temp.u('e1'))$$, 'owner or manager only'), 'P13: outsider link';
  ASSERT pg_temp.refused($$SELECT public.exos_posh_link_event(pg_temp.u('02'), 'x', pg_temp.u('e1'))$$, 'isn''t this organization''s'), 'P13: own org, foreign event';
  ASSERT pg_temp.refused($$SELECT public.exos_posh_cancel_order((pg_temp.ord('o4')).id)$$, 'owner or manager only'), 'P13: outsider cancel';
  -- Assign: links the Posh event by its id; both orders follow.
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a2');
  r := public.exos_posh_assign_order((pg_temp.ord('o4')).id, pg_temp.u('e3'));
  ASSERT r ->> 'linked' = '65f0aa' AND (r ->> 'orders_matched')::int = 1, 'P7: assign ' || r::text;
  ASSERT (pg_temp.ord('o4')).event_id = pg_temp.u('e3') AND (pg_temp.ord('o6')).event_id IS NULL, 'P7: linked by id (o6 has only a name)';
  ASSERT (SELECT external_code FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e3') AND source = 'Posh') = 'M1', 'P7: door entry';
  -- No cap on e3 yet: not counted, said why.
  ASSERT NOT (pg_temp.ord('o4')).counted AND (pg_temp.ord('o4')).attention LIKE 'no Posh cap%' AND pg_temp.sold('d3') = 0, 'P7: waits for a cap';
  r := public.exos_posh_link_event(pg_temp.u('01'), '  MYSTERY   night ', pg_temp.u('e3'));
  ASSERT r ->> 'posh_ref' = 'mystery night' AND (r ->> 'orders_matched')::int = 1, 'P7: name link ' || r::text;
  ASSERT (pg_temp.ord('o6')).event_id = pg_temp.u('e3') AND (pg_temp.ord('o6')).state = 'pending', 'P7: pending follows, stays pending';
  -- The cap counts the order already in (house cap 3 on e3).
  r := public.exos_posh_set_cap(pg_temp.u('e3'), pg_temp.u('d3'), 2);
  ASSERT (r ->> 'orders_counted')::int = 1 AND (r ->> 'sold_in_cap')::int = 1, 'P7: counted on cap ' || r::text;
  ASSERT pg_temp.sold('d3') = 1 AND (pg_temp.ord('o4')).counted AND (pg_temp.ord('o4')).attention IS NULL, 'P7: counted';
  ASSERT public.exos_event_house_available(pg_temp.u('e3')) = 1, 'P7: house = 3 - 1 sold - 1 held';
  ASSERT pg_temp.refused($$SELECT public.exos_posh_set_cap(pg_temp.u('e3'), pg_temp.u('d3'), 4)$$, 'more ticket(s) free'), 'P7: house cap limits the cap';
  -- The next order from that Posh event matches by itself (name, any case).
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.hook('body-o7', 'order_created', '{"order_id":"o7","event_name":"mystery NIGHT","quantity":1}') ->> 'outcome' = 'confirmed', 'P7: auto-match';
  ASSERT (pg_temp.ord('o7')).event_id = pg_temp.u('e3') AND pg_temp.sold('d3') = 2, 'P7: auto-matched + counted';
  RAISE NOTICE 'OK  P7 mapping + unmatched; P13 cross-org refused';
END $t$;

-- P8 / P9 --------------------------------------------------------------------
DO $t$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.refused($$SELECT public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d1'), 9)$$, 'already sold 10'), 'P9: below sold';
  r := public.exos_posh_cancel_order((pg_temp.ord('o1')).id);
  ASSERT (r ->> 'door_entries_voided')::int = 2, 'P8: ' || r::text;
  ASSERT (pg_temp.ord('o1')).state = 'cancelled' AND pg_temp.sold('d1') = 11 AND (pg_temp.cap()).cap_used = 8, 'P8: seats back to the cap';
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 87, 'P8: back to Posh''s share, not Exos''s';
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND external_code IN ('AB12','CD34') AND voided_at IS NOT NULL) = 2, 'P8: voided';
  ASSERT (public.exos_posh_cancel_order((pg_temp.ord('o1')).id) ->> 'already')::boolean, 'P8: twice is a no-op';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.hook('body-o1-late', 'order_created', '{"order_id":"o1","event_slug":"posh-party","quantity":2}') ->> 'outcome' = 'duplicate', 'P8: a cancelled order stays cancelled';
  -- Cancelling the oversold order clears its share of the flag.
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_posh_cancel_order((pg_temp.ord('o3')).id);
  ASSERT (pg_temp.cap()).over_qty = 2 AND (pg_temp.cap()).cap_used = 4 AND pg_temp.sold('d1') = 4, 'P8: oversold order cancelled ' || row_to_json(pg_temp.cap())::text;
  RAISE NOTICE 'OK  P8 cancel; P9 cap floor';
END $t$;

-- P12 -----------------------------------------------------------------------
DO $t$
DECLARE l public.exos_posh_webhook_log%ROWTYPE;
BEGIN
  SELECT * INTO l FROM public.exos_posh_webhook_log WHERE org_id = pg_temp.u('01') AND body_hash = pg_temp.h('body-o3');
  ASSERT l.payload = '{"body":"body-o3"}' AND l.header_names = ARRAY['content-type', 'user-agent'] AND l.kind = 'order_created'
     AND l.outcome = 'confirmed', 'P12: logged';
  ASSERT (SELECT p.payload FROM public.exos_posh_log_payload(l.id) p) = l.payload, 'P12: replay source';
  UPDATE public.exos_posh_webhook_log SET received_at = now() - interval '31 days' WHERE id = l.id;
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.hook('body-o8', 'pending_order_created', '{"order_id":"o8","event_slug":"posh-party"}');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_posh_webhook_log WHERE id = l.id), 'P12: past the window, gone';
  ASSERT (pg_temp.ord('o3')).id IS NOT NULL, 'P12: the order stays';
  ASSERT (SELECT received_count FROM public.exos_posh_hooks WHERE org_id = pg_temp.u('01')) >= 10, 'P12: counted deliveries';
  RAISE NOTICE 'OK  P12 retention';
END $t$;

-- P12b: the daily purge covers every org; disconnect deletes the org's log.
DO $t$
DECLARE v_n int;
BEGIN
  UPDATE public.exos_posh_webhook_log SET received_at = now() - interval '91 days'
   WHERE id = (SELECT id FROM public.exos_posh_webhook_log WHERE org_id = pg_temp.u('01') ORDER BY id LIMIT 1);
  UPDATE public.exos_posh_hooks SET status = 'disabled' WHERE org_id = pg_temp.u('01');
  v_n := public.exos_posh_purge_logs();
  ASSERT v_n = 1, 'P12b: purge removed ' || v_n;
  UPDATE public.exos_posh_hooks SET status = 'active' WHERE org_id = pg_temp.u('01');
  ASSERT EXISTS (SELECT 1 FROM public.exos_posh_webhook_log WHERE org_id = pg_temp.u('01')), 'P12b: recent rows kept';
  PERFORM pg_temp.act('b5000000-0000-0000-0000-0000000000a1');
  ASSERT public.exos_posh_disconnect(pg_temp.u('01')), 'P12b: disconnect';
  PERFORM pg_temp.act(NULL);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_posh_webhook_log WHERE org_id = pg_temp.u('01')), 'P12b: disconnect deletes the log';
  ASSERT EXISTS (SELECT 1 FROM public.exos_posh_orders WHERE org_id = pg_temp.u('01')), 'P12b: orders stay';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_posh_purge_logs(integer)', 'EXECUTE'), 'P12b: purge is service only';
  UPDATE public.exos_posh_hooks SET status = 'active' WHERE org_id = pg_temp.u('01');
  RAISE NOTICE 'OK  P12b retention across orgs; disconnect clears the log';
END $t$;

-- P1 (disable) + P10 ---------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b5000000-0000-0000-0000-0000000000a1');
SELECT public.exos_posh_disconnect(pg_temp.u('01'));
SELECT set_config('b5.ev_auth', (public.exos_posh_event_status(pg_temp.u('e1')) ->> 'can_manage'), true);
SELECT set_config('b5.tbl', pg_temp.refused($$SELECT count(*) FROM public.exos_posh_orders$$, 'permission denied')::text, true);
SELECT set_config('b5.tbl2', pg_temp.refused($$SELECT count(*) FROM public.exos_posh_hooks$$, 'permission denied')::text, true);
SELECT set_config('b5.ing', pg_temp.refused($$SELECT public.exos_posh_ingest(current_setting('b5.th'), pg_temp.h('z'), 'order_created', '{}')$$, 'permission denied')::text, true);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('b5.anon', pg_temp.refused($$SELECT public.exos_posh_status(pg_temp.u('01'))$$, 'permission denied')::text, true);
RESET ROLE;
DO $t$
DECLARE f record; v_bad text := '';
BEGIN
  ASSERT public.exos_posh_ingest(current_setting('b5.th'), pg_temp.h('after-off'), 'order_created', '{}') ->> 'outcome' = 'unknown_hook', 'P1: disabled';
  ASSERT current_setting('b5.ev_auth')::boolean, 'P10: owner through the authenticated role';
  ASSERT current_setting('b5.tbl')::boolean AND current_setting('b5.tbl2')::boolean, 'P10: tables closed to clients';
  ASSERT current_setting('b5.ing')::boolean AND current_setting('b5.anon')::boolean, 'P10: ingest / anon refused';
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname, p.prosecdef, p.proconfig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND (p.proname LIKE 'exos_posh%' OR p.proname LIKE '_exos_posh%') LOOP
    IF f.prosecdef AND NOT coalesce(f.proconfig, '{}') @> ARRAY['search_path=public, pg_temp'] THEN
      v_bad := v_bad || ' search_path:' || f.sig;
    END IF;
    IF has_function_privilege('anon', f.sig, 'EXECUTE') THEN
      v_bad := v_bad || ' anon:' || f.sig;
    END IF;
    IF (f.proname LIKE '\_%' OR f.proname IN ('exos_posh_ingest', 'exos_posh_log_payload'))
       AND has_function_privilege('authenticated', f.sig, 'EXECUTE') THEN
      v_bad := v_bad || ' authenticated:' || f.sig;
    END IF;
    IF NOT has_function_privilege('service_role', f.sig, 'EXECUTE') THEN
      v_bad := v_bad || ' service_role:' || f.sig;
    END IF;
  END LOOP;
  ASSERT v_bad = '', 'P10: grants' || v_bad;
  ASSERT has_function_privilege('authenticated', 'public.exos_posh_set_cap(uuid, uuid, integer)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.exos_posh_status(uuid)', 'EXECUTE'), 'P10: organizer RPCs';
  ASSERT (SELECT bool_and(c.relrowsecurity) FROM pg_class c WHERE c.relname IN
          ('exos_posh_hooks', 'exos_posh_event_links', 'exos_posh_caps', 'exos_posh_orders', 'exos_posh_webhook_log')), 'P10: RLS on';
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants
                      WHERE table_name LIKE 'exos_posh%' AND grantee IN ('anon', 'authenticated', 'PUBLIC')), 'P10: no client table grants';
  RAISE NOTICE 'OK  P10 grants + RLS';
END $t$;

\echo 'test_posh_webhooks: all passed'
ROLLBACK;
