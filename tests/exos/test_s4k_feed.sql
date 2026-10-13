-- ============================================================================
-- S4K network feed (mig 20261014100000):
--   F1 switches: only the owner joins the network; an event goes to s4k only
--      from an opted-in org and with no direct marketplace listings; then it
--      gets no direct allocation (by hand or auto split)
--   F2 the token gate: an unknown or revoked token reads nothing
--   F3 call 1 lists only s4k events of opted-in orgs, published, before doors;
--      updatedSince returns only what moved
--   F4 call 2: one line per sellable ticket type (free, hidden, off-sale left
--      out), quantity = free − one pack, net after the Exos fee
--   F5 refresh moves updated_at only on a real change
--   F6 an order takes seats and mints tickets with claim links; the same
--      externalRef again returns the first order
--   F7 rejections, nothing taken: sold out (all or nothing), price below the
--      current one, over max per order, off the feed; each one logged; the
--      last pack (inside the buffer) can still be bought
--   F8 cancel before doors voids the tickets and returns the seats
--   F9 an event that drops off comes back once as withdrawn
--   F10 webhook: due rows coalesce changes since the cursor; ack advances it,
--       a failure backs off and keeps it
--   F11 grants
--   F12 a signed-in insert can't start an event on the S4K route
--   (F7 also: a rejection sends the organizer no alert or mail)
-- Self-contained (a6 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a6000000-0000-0000-0000-0000000000a0','a6-owner@x.com',now()),
  ('a6000000-0000-0000-0000-0000000000a1','a6-manager@x.com',now()),
  ('a6000000-0000-0000-0000-0000000000b0','a6-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a6000000-0000-0000-0000-000000000001','A6 Org','a6-org','a6000000-0000-0000-0000-0000000000a0'),
  ('a6000000-0000-0000-0000-000000000002','A6 Other','a6-other','a6000000-0000-0000-0000-0000000000b0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a6000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-0000000000a0','owner'),
  ('a6000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-0000000000a1','manager'),
  ('a6000000-0000-0000-0000-000000000002','a6000000-0000-0000-0000-0000000000b0','owner');
-- e1: the S4K show (max 4 per order: pack 4). e2: stays direct. e3: other org.
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,purchase_limits,timezone) VALUES
  ('a6000000-0000-0000-0000-0000000000e1','a6000000-0000-0000-0000-000000000001','Feed Show','published',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":4}','America/New_York'),
  ('a6000000-0000-0000-0000-0000000000e2','a6000000-0000-0000-0000-000000000001','Direct Show','published',now() + interval '20 days','Hall',0,0,'{}','America/New_York'),
  ('a6000000-0000-0000-0000-0000000000e3','a6000000-0000-0000-0000-000000000002','Other Show','published',now() + interval '20 days','Hall',0,0,'{}','America/New_York');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order,sales_start) VALUES
  ('a6000000-0000-0000-0000-0000000000d1','a6000000-0000-0000-0000-0000000000e1','GA',30,20,0,'public',1,NULL),
  ('a6000000-0000-0000-0000-0000000000d2','a6000000-0000-0000-0000-0000000000e1','Free RSVP',0,50,0,'public',2,NULL),
  ('a6000000-0000-0000-0000-0000000000d3','a6000000-0000-0000-0000-0000000000e1','Comps',30,10,0,'hidden',3,NULL),
  ('a6000000-0000-0000-0000-0000000000d4','a6000000-0000-0000-0000-0000000000e1','Late',40,10,0,'public',4,now() + interval '5 days'),
  ('a6000000-0000-0000-0000-0000000000d5','a6000000-0000-0000-0000-0000000000e2','GA',30,20,0,'public',1,NULL),
  ('a6000000-0000-0000-0000-0000000000d6','a6000000-0000-0000-0000-0000000000e3','GA',30,20,0,'public',1,NULL);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"a6@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.ev() RETURNS uuid LANGUAGE sql AS $$ SELECT 'a6000000-0000-0000-0000-0000000000e1'::uuid $$;
CREATE FUNCTION pg_temp.ga() RETURNS uuid LANGUAGE sql AS $$ SELECT 'a6000000-0000-0000-0000-0000000000d1'::uuid $$;
CREATE TEMP TABLE tok(name text PRIMARY KEY, token text, hash text, id uuid, secret text);

-- F1. Switches.
DO $$
DECLARE ok boolean;
BEGIN
  PERFORM pg_temp.act('a6000000-0000-0000-0000-0000000000a1');
  BEGIN
    PERFORM public.exos_set_s4k_network('a6000000-0000-0000-0000-000000000001', true); ok := true;
  EXCEPTION WHEN insufficient_privilege THEN ok := false; END;
  ASSERT NOT ok, 'F1: a manager can''t join the network';
  BEGIN
    PERFORM public.exos_set_distribution_route(pg_temp.ev(), 's4k'); ok := true;
  EXCEPTION WHEN invalid_parameter_value THEN ok := false; END;
  ASSERT NOT ok, 'F1: s4k needs the org opted in';

  PERFORM pg_temp.act('a6000000-0000-0000-0000-0000000000a0');
  BEGIN
    UPDATE public.exos_orgs SET s4k_network = true WHERE id = 'a6000000-0000-0000-0000-000000000001'; ok := true;
  EXCEPTION WHEN insufficient_privilege THEN ok := false; END;
  ASSERT NOT ok, 'F1: no direct table update of the opt-in';
  PERFORM public.exos_set_s4k_network('a6000000-0000-0000-0000-000000000001', true);
  -- A direct listing blocks the switch.
  INSERT INTO public.exos_distribution_listings(event_id, org_id, tier_id, channel, status, requested_qty)
  VALUES (pg_temp.ev(), 'a6000000-0000-0000-0000-000000000001', pg_temp.ga(), 'stubhub', 'planned', 2);
  BEGIN
    PERFORM public.exos_set_distribution_route(pg_temp.ev(), 's4k'); ok := true;
  EXCEPTION WHEN invalid_parameter_value THEN ok := false; END;
  ASSERT NOT ok, 'F1: live direct listings block s4k';
  DELETE FROM public.exos_distribution_listings WHERE event_id = pg_temp.ev();
  PERFORM pg_temp.act('a6000000-0000-0000-0000-0000000000a1');
  ASSERT public.exos_set_distribution_route(pg_temp.ev(), 's4k') = 's4k', 'F1: manager sets the route';
  BEGIN
    UPDATE public.exos_events SET distribution_route = 'direct' WHERE id = pg_temp.ev(); ok := true;
  EXCEPTION WHEN insufficient_privilege THEN ok := false; END;
  ASSERT NOT ok, 'F1: no direct table update of the route';

  -- One route at a time: no direct allocation, no auto split plan.
  UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub'] WHERE id = pg_temp.ev();
  BEGIN
    PERFORM public.exos_set_channel_allocation(pg_temp.ev(), 'stubhub', pg_temp.ga(), 2); ok := true;
  EXCEPTION WHEN raise_exception THEN ok := false; END;
  ASSERT NOT ok, 'F1: no direct allocation on an s4k event';
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.ev())), 'F1: no auto split plan';
  -- The other org's event: route s4k forced (org not opted in) stays off the feed.
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_events SET distribution_route = 's4k' WHERE id = 'a6000000-0000-0000-0000-0000000000e3';
  RAISE NOTICE 'F1 ok';
END $$;

INSERT INTO tok SELECT 's4k', c.token, encode(extensions.digest(c.token, 'sha256'), 'hex'), c.consumer_id, c.webhook_secret
  FROM public.exos_feed_create_consumer('S4K', 'fulfil@s4k.example', 'https://hooks.s4k.example/exos') c;
INSERT INTO tok SELECT 'gone', c.token, encode(extensions.digest(c.token, 'sha256'), 'hex'), c.consumer_id, c.webhook_secret
  FROM public.exos_feed_create_consumer('Revoked') c;
UPDATE public.exos_feed_consumers SET revoked_at = now() WHERE name = 'Revoked';
CREATE FUNCTION pg_temp.h(p text DEFAULT 's4k') RETURNS text LANGUAGE sql AS $$ SELECT hash FROM tok WHERE name = p $$;

-- F2. Token gate.
DO $$
BEGIN
  ASSERT (SELECT token LIKE 'exf_%' AND length(token) = 64 FROM tok WHERE name = 's4k'), 'F2: token shape';
  ASSERT public.exos_feed_events_page(repeat('0', 64)) ->> 'error' = 'unauthorized', 'F2: unknown token';
  ASSERT public.exos_feed_events_page(pg_temp.h('gone')) ->> 'error' = 'unauthorized', 'F2: revoked token';
  ASSERT public.exos_feed_event_tickets(pg_temp.h('gone'), pg_temp.ev()) ->> 'error' = 'unauthorized', 'F2: revoked, call 2';
  ASSERT public.exos_feed_place_order(pg_temp.h('gone'), pg_temp.ev(), pg_temp.ga(), 1, 'x', NULL, 30) ->> 'result' = 'unauthorized', 'F2: revoked, order';
  RAISE NOTICE 'F2 ok';
END $$;

-- F3 / F4. Calls 1 and 2.
DO $$
DECLARE p jsonb; t jsonb; l jsonb;
BEGIN
  p := public.exos_feed_events_page(pg_temp.h());
  ASSERT (p ->> 'total')::int = 1, 'F3: only the s4k event of the opted-in org: ' || p::text;
  ASSERT p #>> '{events,0,event_id}' = pg_temp.ev()::text AND p #>> '{events,0,status}' = 'active', 'F3: the row';
  -- GA 20 − pack 4 = 16 (free, hidden and off-sale tiers out).
  ASSERT (p #>> '{events,0,available}')::int = 16 AND (p #>> '{events,0,total_capacity}')::int = 20, 'F3: counts ' || p::text;

  t := public.exos_feed_event_tickets(pg_temp.h(), pg_temp.ev());
  ASSERT jsonb_array_length(t -> 'tickets') = 1, 'F4: one sellable line: ' || t::text;
  l := t -> 'tickets' -> 0;
  ASSERT l ->> 'tier_id' = pg_temp.ga()::text AND (l ->> 'quantity')::int = 16 AND (l ->> 'max_per_order')::int = 4
     AND (l ->> 'price')::numeric = 30 AND l ->> 'split' = 'any', 'F4: line ' || l::text;
  ASSERT (l ->> 'net')::numeric = round(30 - round(30 * public.exos_org_fee_bps('a6000000-0000-0000-0000-000000000001', now()) / 10000.0, 2), 2), 'F4: net ' || l::text;
  ASSERT public.exos_feed_event_tickets(pg_temp.h(), 'a6000000-0000-0000-0000-0000000000e2') IS NULL, 'F4: direct event: not found';
  ASSERT public.exos_feed_event_tickets(pg_temp.h(), 'a6000000-0000-0000-0000-0000000000e3') IS NULL, 'F4: other org: not found';
  RAISE NOTICE 'F3/F4 ok';
END $$;

-- F5. updated_at moves only on a real change.
DO $$
DECLARE u1 timestamptz; p jsonb;
BEGIN
  UPDATE public.exos_feed_events SET updated_at = now() - interval '1 hour' WHERE event_id = pg_temp.ev();
  SELECT updated_at INTO u1 FROM public.exos_feed_events WHERE event_id = pg_temp.ev();
  PERFORM public.exos_feed_refresh(NULL);
  ASSERT (SELECT updated_at FROM public.exos_feed_events WHERE event_id = pg_temp.ev()) = u1, 'F5: no change, no move';
  p := public.exos_feed_events_page(pg_temp.h(), now() - interval '1 minute');
  ASSERT (p ->> 'total')::int = 0, 'F5: updatedSince: nothing moved ' || p::text;
  UPDATE public.exos_ticket_tiers SET price = 35 WHERE id = pg_temp.ga();
  PERFORM public.exos_feed_refresh(pg_temp.ev());
  ASSERT (SELECT updated_at FROM public.exos_feed_events WHERE event_id = pg_temp.ev()) > u1, 'F5: a price change moves it';
  p := public.exos_feed_events_page(pg_temp.h(), now() - interval '1 minute');
  ASSERT (p ->> 'total')::int = 1, 'F5: updatedSince now returns it';
  UPDATE public.exos_ticket_tiers SET price = 30 WHERE id = pg_temp.ga();
  RAISE NOTICE 'F5 ok';
END $$;

-- F6. An order.
DO $$
DECLARE r jsonb; r2 jsonb; v_order uuid; n int;
BEGIN
  r := public.exos_feed_place_order(pg_temp.h(), pg_temp.ev(), pg_temp.ga(), 3, 'AQ-1001', 'StubHub', 30, NULL, 'https://exos.example/bridge');
  ASSERT r ->> 'result' = 'created' AND jsonb_array_length(r -> 'transfer_ids') = 3, 'F6: created ' || r::text;
  v_order := (r ->> 'order_id')::uuid;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.ga()) = 3, 'F6: seats taken';
  ASSERT (SELECT channel = 's4k' AND buyer_email = 'fulfil@s4k.example' AND proceeds = 90 AND raw ->> 'marketplace' = 'stubhub'
            AND status = 'fulfilled' FROM public.exos_marketplace_orders WHERE id = v_order), 'F6: the order row';
  SELECT count(*) INTO n FROM public.exos_feed_order_tickets(pg_temp.h(), v_order) WHERE claim_key IS NOT NULL AND internal_seat IS NOT NULL;
  ASSERT n = 3, 'F6: three claim links with seats';
  ASSERT (SELECT count(*) FROM public.exos_feed_order_tickets(pg_temp.h('gone'), v_order)) = 0, 'F6: another token sees nothing';
  ASSERT public.exos_feed_order_status(pg_temp.h(), v_order) ->> 'status' = 'fulfilled', 'F6: order status';
  ASSERT public.exos_feed_order_status(pg_temp.h('gone'), v_order) ->> 'result' = 'unauthorized', 'F6: status, revoked';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'fulfil@s4k.example' AND subject LIKE 'Your S4K tickets%'), 'F6: claim mail to the delivery inbox';
  r2 := public.exos_feed_place_order(pg_temp.h(), pg_temp.ev(), pg_temp.ga(), 3, 'AQ-1001', 'StubHub', 30);
  ASSERT r2 ->> 'result' = 'existing' AND r2 ->> 'order_id' = v_order::text, 'F6: idempotent ' || r2::text;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.ga()) = 3, 'F6: no second take';
  ASSERT (SELECT available FROM public.exos_feed_events WHERE event_id = pg_temp.ev()) = 13, 'F6: feed refreshed (17 − 4)';
  RAISE NOTICE 'F6 ok';
END $$;

-- F7. Rejections.
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_feed_place_order(pg_temp.h(), pg_temp.ev(), pg_temp.ga(), 2, 'AQ-2001', 'seatgeek', 29.50);
  ASSERT r ->> 'result' = 'rejected' AND r ->> 'reason' = 'price_changed', 'F7: under price ' || r::text;
  r := public.exos_feed_place_order(pg_temp.h(), pg_temp.ev(), pg_temp.ga(), 5, 'AQ-2002', 'seatgeek', 30);
  ASSERT r ->> 'reason' = 'over_max_per_order', 'F7: over max ' || r::text;
  r := public.exos_feed_place_order(pg_temp.h(), 'a6000000-0000-0000-0000-0000000000e2', 'a6000000-0000-0000-0000-0000000000d5', 1, 'AQ-2003', NULL, 30);
  ASSERT r ->> 'reason' = 'not_on_feed', 'F7: direct event ' || r::text;
  r := public.exos_feed_place_order(pg_temp.h(), pg_temp.ev(), 'a6000000-0000-0000-0000-0000000000d2', 1, 'AQ-2004', NULL, 0);
  ASSERT r ->> 'reason' = 'ticket_not_on_feed', 'F7: free tier ' || r::text;

  -- Exos sells all but 3 elsewhere; S4K asks for 4: all or nothing.
  UPDATE public.exos_ticket_tiers SET sold = 17 WHERE id = pg_temp.ga();
  r := public.exos_feed_place_order(pg_temp.h(), pg_temp.ev(), pg_temp.ga(), 4, 'AQ-2005', 'vivid', 30);
  ASSERT r ->> 'result' = 'rejected' AND r ->> 'reason' = 'sold_out' AND (r ->> 'available')::int = 3, 'F7: sold out ' || r::text;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.ga()) = 17, 'F7: nothing taken';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketplace_orders WHERE external_order_id = 'AQ-2005'), 'F7: no order left behind';
  -- The buffer is not a reserve: the last 3 can be bought (the feed showed 0).
  ASSERT (SELECT available FROM public.exos_feed_events WHERE event_id = pg_temp.ev()) = 0, 'F7: feed shows 0 inside the buffer';
  r := public.exos_feed_place_order(pg_temp.h(), pg_temp.ev(), pg_temp.ga(), 3, 'AQ-2005', 'vivid', 30);
  ASSERT r ->> 'result' = 'created', 'F7: the same ref retried, now fillable ' || r::text;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.ga()) = 20, 'F7: sold out exactly';

  ASSERT (SELECT count(*) FROM public.exos_feed_rejections WHERE consumer_id = (SELECT id FROM tok WHERE name = 's4k')) = 5, 'F7: five logged';
  -- A rejection leaves no trace for the organizer: no alert, no "action needed" mail.
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'marketplace-attention'), 'F7: no attention mail';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketplace_attention_alerts), 'F7: no attention alert';
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id = pg_temp.ev()) = 6, 'F7: house counter: the two filled orders only';
  ASSERT EXISTS (SELECT 1 FROM public.exos_feed_rejections WHERE reason = 'sold_out' AND marketplace = 'vivid' AND available = 3 AND quantity = 4), 'F7: the sold-out row';
  RAISE NOTICE 'F7 ok';
END $$;

-- F8. Cancel before doors.
DO $$
DECLARE v_order uuid; r jsonb;
BEGIN
  SELECT id INTO v_order FROM public.exos_marketplace_orders WHERE external_order_id = 'AQ-1001';
  r := public.exos_feed_cancel_order(pg_temp.h('gone'), v_order);
  ASSERT r ->> 'result' = 'unauthorized', 'F8: revoked token';
  r := public.exos_feed_cancel_order(pg_temp.h(), v_order);
  ASSERT r ->> 'result' = 'cancelled' AND (r ->> 'released')::int = 3, 'F8: cancelled ' || r::text;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.ga()) = 17, 'F8: seats back';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 's4k:AQ-1001' AND status = 'voided') = 3, 'F8: tickets voided';
  ASSERT public.exos_feed_cancel_order(pg_temp.h(), v_order) ->> 'result' = 'cancelled', 'F8: again is a no-op';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.ga()) = 17, 'F8: not released twice';
  -- A scanned ticket blocks it.
  SELECT id INTO v_order FROM public.exos_marketplace_orders WHERE external_order_id = 'AQ-2005';
  UPDATE public.exos_tickets SET status = 'used' WHERE id = (SELECT ticket_ids[1] FROM public.exos_marketplace_orders WHERE id = v_order);
  r := public.exos_feed_cancel_order(pg_temp.h(), v_order);
  ASSERT r ->> 'result' = 'refused' AND r ->> 'reason' = 'ticket_scanned', 'F8: scanned ' || r::text;
  RAISE NOTICE 'F8 ok';
END $$;

-- F9. Withdrawn once.
DO $$
DECLARE p jsonb;
BEGIN
  UPDATE public.exos_feed_events SET updated_at = now() - interval '1 hour' WHERE event_id = pg_temp.ev();
  UPDATE public.exos_events SET status = 'cancelled' WHERE id = pg_temp.ev();
  PERFORM public.exos_feed_refresh(NULL);
  p := public.exos_feed_events_page(pg_temp.h(), now() - interval '1 minute');
  ASSERT (p ->> 'total')::int = 1 AND p #>> '{events,0,status}' = 'withdrawn' AND (p #>> '{events,0,available}')::int = 0, 'F9: withdrawn ' || p::text;
  ASSERT (public.exos_feed_events_page(pg_temp.h()) ->> 'total')::int = 0, 'F9: not in the full slate';
  UPDATE public.exos_feed_events SET updated_at = now() - interval '1 hour' WHERE event_id = pg_temp.ev();
  PERFORM public.exos_feed_refresh(NULL);
  ASSERT (public.exos_feed_events_page(pg_temp.h(), now() - interval '1 minute') ->> 'total')::int = 0, 'F9: only once';
  RAISE NOTICE 'F9 ok';
END $$;

-- F10. Webhook.
DO $$
DECLARE w record; n int;
BEGIN
  -- Readers stay 15 s behind the clock: a fresh change isn't due yet.
  UPDATE public.exos_feed_events SET updated_at = clock_timestamp() WHERE event_id = pg_temp.ev();
  ASSERT (SELECT count(*) FROM public.exos_feed_webhook_due()) = 0, 'F10: fresh change waits 15 s';
  -- Two events moved at the same instant; batches of one still deliver both (keyset).
  UPDATE public.exos_feed_events SET updated_at = now() - interval '1 minute' WHERE event_id = pg_temp.ev();
  INSERT INTO public.exos_feed_events(event_id, org_id, status, available, total_capacity, content_hash, updated_at)
  VALUES ('a6000000-0000-0000-0000-0000000000e2', 'a6000000-0000-0000-0000-000000000001', 'withdrawn', 0, 0, 'x', now() - interval '1 minute');
  SELECT count(*) INTO n FROM public.exos_feed_webhook_due(1);
  ASSERT n = 1, 'F10: one consumer with a URL is due';
  SELECT * INTO w FROM public.exos_feed_webhook_due(1);
  ASSERT w.url = 'https://hooks.s4k.example/exos' AND w.secret = (SELECT secret FROM tok WHERE name = 's4k')
     AND jsonb_array_length(w.events) = 1, 'F10: payload ' || row_to_json(w)::text;
  PERFORM public.exos_feed_webhook_ack(w.consumer_id, w.cursor_to, w.cursor_id, false, 'HTTP 500');
  ASSERT (SELECT webhook_cursor IS NULL AND webhook_failures = 1 AND webhook_next_at > now()
            FROM public.exos_feed_consumers WHERE id = w.consumer_id), 'F10: failure backs off, cursor kept';
  ASSERT (SELECT count(*) FROM public.exos_feed_webhook_due()) = 0, 'F10: not due while backing off';
  UPDATE public.exos_feed_consumers SET webhook_next_at = now() - interval '1 second' WHERE id = w.consumer_id;
  SELECT * INTO w FROM public.exos_feed_webhook_due(1);
  PERFORM public.exos_feed_webhook_ack(w.consumer_id, w.cursor_to, w.cursor_id, true);
  ASSERT (SELECT webhook_cursor = w.cursor_to AND webhook_cursor_id = w.cursor_id AND webhook_failures = 0
            FROM public.exos_feed_consumers WHERE id = w.consumer_id), 'F10: ack advances';
  SELECT * INTO w FROM public.exos_feed_webhook_due(1);
  ASSERT w.events -> 0 ->> 'event_id' IS DISTINCT FROM (SELECT webhook_cursor_id::text FROM public.exos_feed_consumers WHERE id = w.consumer_id)
     AND jsonb_array_length(w.events) = 1, 'F10: the same-instant second event comes next';
  PERFORM public.exos_feed_webhook_ack(w.consumer_id, w.cursor_to, w.cursor_id, true);
  ASSERT (SELECT count(*) FROM public.exos_feed_webhook_due()) = 0, 'F10: nothing new, nothing due';
  -- A late ack of an older batch doesn't rewind the cursor.
  PERFORM public.exos_feed_webhook_ack(w.consumer_id, now() - interval '1 day', w.cursor_id, true);
  ASSERT (SELECT webhook_cursor = w.cursor_to FROM public.exos_feed_consumers WHERE id = w.consumer_id), 'F10: no rewind';
  DELETE FROM public.exos_feed_events WHERE event_id = 'a6000000-0000-0000-0000-0000000000e2';
  RAISE NOTICE 'F10 ok';
END $$;

-- F12. A signed-in insert starts off the network.
DO $$
BEGIN
  PERFORM pg_temp.act('a6000000-0000-0000-0000-0000000000a0');
  INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_route)
  VALUES ('a6000000-0000-0000-0000-0000000000e4','a6000000-0000-0000-0000-000000000001','Sneaky','draft',now() + interval '9 days','Hall',0,0,'s4k');
  ASSERT (SELECT distribution_route FROM public.exos_events WHERE id = 'a6000000-0000-0000-0000-0000000000e4') = 'direct', 'F12: forced direct';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'F12 ok';
END $$;

-- F11. Grants.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_feed_events_page(text,timestamptz,integer,integer)',
                           'public.exos_feed_event_tickets(text,uuid)',
                           'public.exos_feed_place_order(text,uuid,uuid,integer,text,text,numeric,text,text)',
                           'public.exos_feed_cancel_order(text,uuid)', 'public.exos_feed_order_tickets(text,uuid)', 'public.exos_feed_order_status(text,uuid)',
                           'public.exos_feed_refresh(uuid)', 'public.exos_feed_create_consumer(text,text,text)',
                           'public.exos_feed_webhook_due(integer)', 'public.exos_feed_webhook_ack(uuid,timestamptz,uuid,boolean,text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'F11: ' || f;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_set_s4k_network(uuid,boolean)', 'EXECUTE'), 'F11: switch';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_feed_consumers', 'SELECT'), 'F11: consumers hidden';
  RAISE NOTICE 'F11 ok';
END $$;

\echo 'test_s4k_feed: all passed'
ROLLBACK;
