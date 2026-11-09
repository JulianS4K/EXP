-- ============================================================================
-- Buyer mistake simulations (claude/exos-sim-buyer). Drives the real RPCs the
-- way exos-checkout, stripe-webhook, exos-rsvp and the SPA call them, with a
-- buyer doing the wrong thing. Each block is one scenario:
--   OK    SIM-BUYER-n  the behaviour is right (or intended, with the reason)
--   KNOWN SIM-BUYER-n  a real gap left for a product decision (the report has
--                      the proposal); it does not fail the run
-- Fixes are in mig 20261104100000_exos_sim_buyer_fixes; the product decisions
-- on the KNOWN ones (8, 12, 13, 26, 31, 34) in mig 20261105100000. The
-- scenarios that exercise them are their regression tests.
-- Self-contained (be… ids), BEGIN / ROLLBACK. Runs after the full run_p0.sh
-- chain:  psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/sim_buyer.sql
-- Races (real parallel sessions) are in race_sim_buyer.sh.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('be000000-0000-0000-0000-0000000000a0','owner@sim-b.test',now()),
  ('be000000-0000-0000-0000-0000000000a9','other-owner@sim-b.test',now()),
  ('be000000-0000-0000-0000-0000000000b1','b1@sim-b.test',now()),
  ('be000000-0000-0000-0000-0000000000b2','b2@sim-b.test',now()),
  ('be000000-0000-0000-0000-0000000000b3','b3@sim-b.test',now()),
  ('be000000-0000-0000-0000-0000000000b4','b4@sim-b.test',now()),
  ('be000000-0000-0000-0000-0000000000b5','b5@sim-b.test',now()),
  ('be000000-0000-0000-0000-0000000000b6','typo-owner@sim-b.test',now()),
  ('be000000-0000-0000-0000-0000000000b7','unconfirmed@sim-b.test',NULL);
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('be000000-0000-0000-0000-000000000001','Sim Buyer Org','sim-b-org','be000000-0000-0000-0000-0000000000a0'),
  ('be000000-0000-0000-0000-000000000002','Sim Other Org','sim-b-other','be000000-0000-0000-0000-0000000000a9');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('be000000-0000-0000-0000-000000000001','be000000-0000-0000-0000-0000000000a0','owner'),
  ('be000000-0000-0000-0000-000000000002','be000000-0000-0000-0000-0000000000a9','owner');
-- e1 general · e2 one seat · e3 maxPerAccount 2 · e4 already happened ·
-- e5 phone RSVP (3 seats) · e6 doors open · e7 sold out (waitlist)
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,purchase_limits,created_by,refund_policy) VALUES
  ('be000000-0000-0000-0000-0000000000e1','be000000-0000-0000-0000-000000000001','Sim One','sim-b-one','published',now() + interval '10 days',0,0,NULL,'be000000-0000-0000-0000-0000000000a0','until_start'),
  ('be000000-0000-0000-0000-0000000000e2','be000000-0000-0000-0000-000000000001','Sim Last Seat','sim-b-last','published',now() + interval '10 days',0,0,NULL,'be000000-0000-0000-0000-0000000000a0','until_start'),
  ('be000000-0000-0000-0000-0000000000e3','be000000-0000-0000-0000-000000000001','Sim Capped','sim-b-capped','published',now() + interval '10 days',0,0,'{"maxPerAccount":2}','be000000-0000-0000-0000-0000000000a0','until_start'),
  ('be000000-0000-0000-0000-0000000000e4','be000000-0000-0000-0000-000000000001','Sim Over','sim-b-over','published',now() - interval '2 days',0,0,NULL,'be000000-0000-0000-0000-0000000000a0','until_start'),
  ('be000000-0000-0000-0000-0000000000e5','be000000-0000-0000-0000-000000000001','Sim RSVP','sim-b-rsvp','published',now() + interval '3 days',0,0,NULL,'be000000-0000-0000-0000-0000000000a0','until_start'),
  ('be000000-0000-0000-0000-0000000000e6','be000000-0000-0000-0000-000000000001','Sim Door','sim-b-door','published',now() - interval '1 hour',0,0,NULL,'be000000-0000-0000-0000-0000000000a0','until_start'),
  ('be000000-0000-0000-0000-0000000000e7','be000000-0000-0000-0000-000000000001','Sim Sold Out','sim-b-soldout','published',now() + interval '10 days',0,0,NULL,'be000000-0000-0000-0000-0000000000a0','until_start');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('be000000-0000-0000-0000-0000000000d1','be000000-0000-0000-0000-0000000000e1','GA',20,100,0,'public'),
  ('be000000-0000-0000-0000-0000000000d2','be000000-0000-0000-0000-0000000000e2','GA',20,1,0,'public'),
  ('be000000-0000-0000-0000-0000000000d3','be000000-0000-0000-0000-0000000000e3','GA',20,100,0,'public'),
  ('be000000-0000-0000-0000-0000000000d4','be000000-0000-0000-0000-0000000000e4','GA',20,100,0,'public'),
  ('be000000-0000-0000-0000-0000000000d5','be000000-0000-0000-0000-0000000000e5','RSVP',0,3,0,'public'),
  ('be000000-0000-0000-0000-0000000000d6','be000000-0000-0000-0000-0000000000e6','GA',20,100,0,'public'),
  ('be000000-0000-0000-0000-0000000000d7','be000000-0000-0000-0000-0000000000e7','GA',20,1,1,'public');

-- Helpers ---------------------------------------------------------------------
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('be000000-0000-0000-0000-' || p)::uuid $$;
-- Sign in as a buyer (app.uid / app.jwt are the test stubs of auth.uid() / auth.jwt()).
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true),
         set_config('app.jwt', coalesce((SELECT jsonb_build_object('email', email)::text FROM auth.users WHERE id::text = p_uid), ''), true);
$$;
-- The error text a statement raises, or NULL.
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN NULL; EXCEPTION WHEN others THEN RETURN SQLERRM; END $$;
-- What exos-checkout writes once the hold is in place: the pending session row,
-- then the hold linked to it.
CREATE FUNCTION pg_temp.sess(p_sid text, p_ev text, p_tier text, p_buyer text, p_email text, p_qty int, p_cents int, p_hold uuid)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,guest,quantity,amount_cents,currency,status)
  VALUES (p_sid, pg_temp.u(p_ev), pg_temp.u(p_tier), pg_temp.u('000000000001'), CASE WHEN p_buyer IS NULL THEN NULL ELSE pg_temp.u(p_buyer) END,
          p_email, p_buyer IS NULL, p_qty, p_cents, 'usd', 'pending');
  UPDATE public.exos_cart_holds SET checkout_session_id = p_sid WHERE id = p_hold;
$$;
-- stripe-webhook's checkout.session.completed (paid): fulfil, then the ledger.
CREATE FUNCTION pg_temp.paid(p_sid text) RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE v uuid[];
BEGIN
  v := public.exos_fulfill_checkout(p_sid);
  UPDATE public.exos_checkout_sessions SET payment_intent = 'pi_' || p_sid WHERE session_id = p_sid;
  PERFORM public.exos_record_payment(p_sid, 'pi_' || p_sid, (SELECT amount_cents FROM public.exos_checkout_sessions WHERE session_id = p_sid), 'succeeded');
  RETURN v;
END $$;
-- stripe-webhook's checkout.session.expired.
CREATE FUNCTION pg_temp.expired(p_sid text) RETURNS void LANGUAGE sql AS $$
  UPDATE public.exos_checkout_sessions SET status = 'expired' WHERE session_id = p_sid AND status = 'pending';
$$;
-- The app's rotating T- code at time p_at (the door's 30-second buckets).
CREATE FUNCTION pg_temp.t_code(p_ticket uuid, p_at timestamptz) RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' ||
         rtrim(translate(encode(extensions.hmac(t.id || ':' || t.owner_id || ':' || b, t.barcode_secret, 'sha256'),
                                'base64'), '+/', '-_'), '=')
    FROM public.exos_tickets t,
         LATERAL (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint::text AS b) x
   WHERE t.id = p_ticket;
$$;
CREATE FUNCTION pg_temp.h(p_token text) RETURNS text LANGUAGE sql AS $$
  SELECT encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;
CREATE TEMP TABLE simb (k text PRIMARY KEY, v text);
GRANT ALL ON simb TO anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-1 Double-clicks Buy: two checkouts at once (signed in).
-- ---------------------------------------------------------------------------
DO $$
DECLARE h1 uuid; h2 uuid; ids uuid[];
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b1')::text);
  h1 := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 2);
  PERFORM pg_temp.sess('cs_simb_1a', '0000000000e1', '0000000000d1', '0000000000b1', 'b1@sim-b.test', 2, 4000, h1);
  h2 := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 2);
  PERFORM pg_temp.sess('cs_simb_1b', '0000000000e1', '0000000000d1', '0000000000b1', 'b1@sim-b.test', 2, 4000, h2);
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = h1) = 'released', 'SIM-BUYER-1: the first cart is retired';
  ASSERT (SELECT count(*) FROM public.exos_cart_holds WHERE event_id = pg_temp.u('0000000000e1') AND status = 'active') = 1,
         'SIM-BUYER-1: one live hold, not two';
  ASSERT public.exos_effective_available(pg_temp.u('0000000000d1')) = 98, 'SIM-BUYER-1: only 2 seats reserved';
  -- They pay the second tab; Stripe expires the first.
  ids := pg_temp.paid('cs_simb_1b');
  PERFORM pg_temp.expired('cs_simb_1a');
  ASSERT cardinality(ids) = 2 AND (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1')) = 2,
         'SIM-BUYER-1: two tickets, sold 2';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_1a') = 'expired', 'SIM-BUYER-1: the abandoned tab expires';
  RAISE NOTICE 'OK SIM-BUYER-1 double-click Buy: the second click retires the first cart; one order';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-2 Double-click, then pays BOTH Stripe tabs, at a capped event.
-- The first tab lost its hold; fulfilment re-checks the per-account cap and
-- fails it (the webhook refunds), with the "didn't go through" mail.
-- FIXED: that mail said the show "sold out while you were paying"; it now
-- names the per-person cap (mig 20261104100000 section 4).
-- ---------------------------------------------------------------------------
DO $$
DECLARE h1 uuid; h2 uuid; a uuid[]; b uuid[];
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b1')::text);
  h1 := public.exos_create_hold(pg_temp.u('0000000000e3'), pg_temp.u('0000000000d3'), 2);
  PERFORM pg_temp.sess('cs_simb_2a', '0000000000e3', '0000000000d3', '0000000000b1', 'b1@sim-b.test', 2, 4000, h1);
  h2 := public.exos_create_hold(pg_temp.u('0000000000e3'), pg_temp.u('0000000000d3'), 2);
  PERFORM pg_temp.sess('cs_simb_2b', '0000000000e3', '0000000000d3', '0000000000b1', 'b1@sim-b.test', 2, 4000, h2);
  b := pg_temp.paid('cs_simb_2b');
  a := pg_temp.paid('cs_simb_2a');
  ASSERT cardinality(b) = 2 AND cardinality(a) = 0, 'SIM-BUYER-2: one order fulfilled, the other refused';
  ASSERT (SELECT status || ':' || failure_reason FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_2a')
         = 'failed:per-account purchase limit exceeded at fulfillment', 'SIM-BUYER-2: failed -> webhook auto-refund';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'order-failed' AND to_email = 'b1@sim-b.test'
                    AND html LIKE '%as many tickets as this event allows per person%' AND html LIKE '%refunded in full%'),
         'SIM-BUYER-2: the buyer is told why, and that it is refunded';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'order-failed' AND to_email = 'b1@sim-b.test'
                        AND html LIKE '%sold out while you were paying%'), 'SIM-BUYER-2: not "sold out"';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d3')) = 2, 'SIM-BUYER-2: sold 2, not 4';
  RAISE NOTICE 'FIXED SIM-BUYER-2 paying both tabs: the cap holds at fulfilment, the extra order is refunded';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-3 Guest double-click with a different case / spaces in the email.
-- ---------------------------------------------------------------------------
DO $$
DECLARE h1 uuid; h2 uuid;
BEGIN
  PERFORM pg_temp.act(NULL);
  h1 := public.exos_create_guest_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 'guest3@sim-b.test', 'iphash-simb-3');
  h2 := public.exos_create_guest_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, '  Guest3@SIM-B.test ', 'iphash-simb-3');
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = h1) = 'released'
     AND (SELECT status FROM public.exos_cart_holds WHERE id = h2) = 'active', 'SIM-BUYER-3: one live guest cart per email';
  ASSERT (SELECT buyer_email FROM public.exos_cart_holds WHERE id = h2) = 'guest3@sim-b.test', 'SIM-BUYER-3: email normalized';
  UPDATE public.exos_cart_holds SET status = 'released' WHERE id = h2;
  RAISE NOTICE 'OK SIM-BUYER-3 guest double-click: one live cart per email (case and spaces ignored)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-4 Closes the tab mid-payment, then buys again. The abandoned
-- session's hold is retired by the new one, its late "expired" event never
-- touches the new order, and its seats come back.
-- ---------------------------------------------------------------------------
DO $$
DECLARE h1 uuid; h2 uuid; ids uuid[];
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b2')::text);
  h1 := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  PERFORM pg_temp.sess('cs_simb_4a', '0000000000e1', '0000000000d1', '0000000000b2', 'b2@sim-b.test', 1, 2000, h1);
  -- tab closed; ten minutes later they come back
  h2 := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  PERFORM pg_temp.sess('cs_simb_4b', '0000000000e1', '0000000000d1', '0000000000b2', 'b2@sim-b.test', 1, 2000, h2);
  ids := pg_temp.paid('cs_simb_4b');
  PERFORM pg_temp.expired('cs_simb_4a');
  PERFORM pg_temp.expired('cs_simb_4b');   -- a stray expired event for the paid one: no-op
  ASSERT cardinality(ids) = 1, 'SIM-BUYER-4: one ticket';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_4b') = 'fulfilled', 'SIM-BUYER-4: paid order untouched';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_4a') = 'expired', 'SIM-BUYER-4: abandoned one expired';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref IN ('cs_simb_4a', 'cs_simb_4b')) = 1, 'SIM-BUYER-4: no ticket for the abandoned one';
  -- a late completed event for the abandoned (unpaid, expired) session mints nothing
  ASSERT cardinality(public.exos_fulfill_checkout('cs_simb_4a')) = 0, 'SIM-BUYER-4: an expired session never mints';
  RAISE NOTICE 'OK SIM-BUYER-4 closed tab + buy again: one order, the abandoned session never mints';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-5 The Stripe webhook arrives twice (and a reconcile sweep a third
-- time): same tickets, sold counted once, one ledger row, one mail.
-- ---------------------------------------------------------------------------
DO $$
DECLARE a uuid[]; b uuid[]; c uuid[];
BEGIN
  a := pg_temp.paid('cs_simb_4b');
  b := pg_temp.paid('cs_simb_4b');
  c := public.exos_fulfill_checkout('cs_simb_4b');
  ASSERT a = b AND b = c AND cardinality(a) = 1, 'SIM-BUYER-5: replays return the same tickets';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_simb_4b') = 1, 'SIM-BUYER-5: one ticket';
  ASSERT (SELECT count(*) FROM public.exos_order_payments WHERE session_id = 'cs_simb_4b') = 1, 'SIM-BUYER-5: one payment row';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'ticket-issued' AND to_email = 'b2@sim-b.test') = 1, 'SIM-BUYER-5: one mail';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1')) = 3, 'SIM-BUYER-5: sold 3 (2 + 1)';
  RAISE NOTICE 'OK SIM-BUYER-5 duplicate webhooks are idempotent';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-6 Webhooks out of order: refund before completed, and expired
-- after a refund. A refunded order is never re-minted or revived.
-- ---------------------------------------------------------------------------
DO $$
DECLARE h uuid; ids uuid[];
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  PERFORM pg_temp.sess('cs_simb_6', '0000000000e1', '0000000000d1', '0000000000b3', 'b3@sim-b.test', 1, 2000, h);
  ids := pg_temp.paid('cs_simb_6');
  PERFORM public.exos_refund_checkout('cs_simb_6', 'stripe refund');
  ids := public.exos_fulfill_checkout('cs_simb_6');   -- a late completed redelivery
  PERFORM pg_temp.expired('cs_simb_6');
  ASSERT cardinality(ids) = 0, 'SIM-BUYER-6: no tickets handed back for a refunded order';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_6') = 'refunded', 'SIM-BUYER-6: stays refunded';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_simb_6' AND status <> 'voided') = 0, 'SIM-BUYER-6: no live ticket';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1')) = 3, 'SIM-BUYER-6: sold back to 3';
  RAISE NOTICE 'OK SIM-BUYER-6 out-of-order webhooks: refunded stays refunded';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-7 The webhook arrives after the 30-minute hold expired (Stripe
-- retrying), seats still free: the order is honoured.
-- ---------------------------------------------------------------------------
DO $$
DECLARE h uuid; ids uuid[];
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b4')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  PERFORM pg_temp.sess('cs_simb_7', '0000000000e1', '0000000000d1', '0000000000b4', 'b4@sim-b.test', 1, 2000, h);
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '5 minutes' WHERE id = h;
  PERFORM public.exos_expire_holds();
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = h) = 'expired', 'SIM-BUYER-7: hold swept';
  ids := pg_temp.paid('cs_simb_7');
  ASSERT cardinality(ids) = 1 AND (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_7') = 'fulfilled',
         'SIM-BUYER-7: paid after the hold lapsed, still issued';
  RAISE NOTICE 'OK SIM-BUYER-7 late webhook, seats free: issued';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-8 The webhook arrives late (Stripe retrying) for a buyer who paid
-- in time, and another buyer wants the same last seat. Was KNOWN (the late
-- payer took the seat from a live hold and the second buyer was refunded).
-- Decision (mig 20261105100000): a hold lasts until Stripe's Checkout Session
-- expires_at (exos-checkout sets it and records it as provider_expires_at)
-- + 10 minutes, so a seat paid for in time is never offered to the next
-- buyer; checkout.session.expired frees it at once.
-- ---------------------------------------------------------------------------
DO $$
DECLARE h1 uuid; h3 uuid; a uuid[]; e text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b1')::text);
  h1 := public.exos_create_hold(pg_temp.u('0000000000e2'), pg_temp.u('0000000000d2'), 1);
  -- Stripe's page closed 5 minutes ago; b1 paid just before it did.
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,created_at,provider_expires_at)
  VALUES ('cs_simb_8a', pg_temp.u('0000000000e2'), pg_temp.u('0000000000d2'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'),
          'b1@sim-b.test', 1, 2000, 'usd', 'pending', now() - interval '35 minutes', now() - interval '5 minutes');
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_simb_8a', expires_at = now() - interval '5 minutes' WHERE id = h1;
  ASSERT (SELECT expires_at FROM public.exos_cart_holds WHERE id = h1) >= now() + interval '5 minutes' - interval '1 second',
         'SIM-BUYER-8: the hold runs to Stripe''s expires_at + 10 minutes';
  PERFORM public.exos_expire_holds();
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = h1) = 'active', 'SIM-BUYER-8: the sweep leaves it (webhook grace)';
  -- b2 wants the seat meanwhile: refused before paying, not refunded after.
  PERFORM pg_temp.act(pg_temp.u('0000000000b2')::text);
  e := pg_temp.err($q$SELECT public.exos_create_hold(pg_temp.u('0000000000e2'), pg_temp.u('0000000000d2'), 1)$q$);
  ASSERT e LIKE '%not enough tickets available%', 'SIM-BUYER-8: the next buyer waits: ' || coalesce(e, 'none');
  a := pg_temp.paid('cs_simb_8a');   -- b1's delayed webhook
  ASSERT cardinality(a) = 1, 'SIM-BUYER-8: the in-time payer gets the seat';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d2')) = 1, 'SIM-BUYER-8: never oversold';
  -- A session without a recorded expires_at (an older checkout): Stripe's
  -- 30 minutes from creation, + 10.
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  h3 := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status)
  VALUES ('cs_simb_8c', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b3'),
          'b3@sim-b.test', 1, 2000, 'usd', 'pending');
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_simb_8c' WHERE id = h3;
  ASSERT (SELECT expires_at FROM public.exos_cart_holds WHERE id = h3) >= now() + interval '40 minutes' - interval '1 second',
         'SIM-BUYER-8: created_at + 30 + 10 without expires_at';
  -- Stripe says the page expired unpaid: the seat is free at once.
  PERFORM pg_temp.expired('cs_simb_8c');
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = h3) = 'released', 'SIM-BUYER-8: checkout.session.expired releases the hold';
  RAISE NOTICE 'OK SIM-BUYER-8 late webhook: the hold outlives Stripe''s session by 10 minutes, so the in-time payer keeps the seat and the next buyer waits';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-9 Two buyers go for the last ticket: the second hold is refused
-- before any money moves (parallel version: race_sim_buyer.sh race 1).
-- ---------------------------------------------------------------------------
DO $$
DECLARE e text;
BEGIN
  UPDATE public.exos_ticket_tiers SET capacity = 2 WHERE id = pg_temp.u('0000000000d2');  -- one seat left
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  PERFORM public.exos_create_hold(pg_temp.u('0000000000e2'), pg_temp.u('0000000000d2'), 1);
  PERFORM pg_temp.act(pg_temp.u('0000000000b4')::text);
  e := pg_temp.err($q$SELECT public.exos_create_hold(pg_temp.u('0000000000e2'), pg_temp.u('0000000000d2'), 1)$q$);
  ASSERT e LIKE '%not enough tickets available%', 'SIM-BUYER-9: second buyer refused: ' || coalesce(e, 'none');
  -- a guest trying too
  e := pg_temp.err($q$SELECT public.exos_create_guest_hold(pg_temp.u('0000000000e2'), pg_temp.u('0000000000d2'), 1, 'g9@sim-b.test', 'iphash-simb-9')$q$);
  ASSERT e LIKE '%not enough tickets available%', 'SIM-BUYER-9: guest refused: ' || coalesce(e, 'none');
  UPDATE public.exos_cart_holds SET status = 'released' WHERE event_id = pg_temp.u('0000000000e2') AND status = 'active';
  RAISE NOTICE 'OK SIM-BUYER-9 last ticket: the second hold is refused, nobody pays for nothing';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-10 Beats the per-buyer cap with two sessions / the guest path /
-- two emails (e3: maxPerAccount 2; b1 already holds 2).
-- ---------------------------------------------------------------------------
DO $$
DECLARE e text; h uuid; ids uuid[];
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b1')::text);
  e := pg_temp.err($q$SELECT public.exos_create_hold(pg_temp.u('0000000000e3'), pg_temp.u('0000000000d3'), 1)$q$);
  ASSERT e LIKE '%exceeds max per account%', 'SIM-BUYER-10: signed-in third ticket refused';
  -- signed out, same email, odd case: the account's tickets count
  e := pg_temp.err($q$SELECT public.exos_create_guest_hold(pg_temp.u('0000000000e3'), pg_temp.u('0000000000d3'), 1, ' B1@Sim-B.test', 'iphash-simb-10')$q$);
  ASSERT e LIKE '%exceeds max per account%', 'SIM-BUYER-10: guest path with the same email refused: ' || coalesce(e, 'none');
  -- a guest order slips under the hold check (two guest sessions at once):
  -- fulfilment counts the email again
  h := public.exos_create_guest_hold(pg_temp.u('0000000000e3'), pg_temp.u('0000000000d3'), 2, 'g10@sim-b.test', 'iphash-simb-10');
  PERFORM pg_temp.sess('cs_simb_10a', '0000000000e3', '0000000000d3', NULL, 'g10@sim-b.test', 2, 4000, h);
  PERFORM pg_temp.sess('cs_simb_10b', '0000000000e3', '0000000000d3', NULL, 'G10@sim-b.test', 1, 2000, NULL);
  ASSERT cardinality(pg_temp.paid('cs_simb_10a')) = 2, 'SIM-BUYER-10: first guest order';
  ids := pg_temp.paid('cs_simb_10b');
  ASSERT cardinality(ids) = 0
     AND (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_10b') = 'failed',
         'SIM-BUYER-10: the second guest order is refused at fulfilment (refunded)';
  -- Intended: a different email is a different buyer. Nothing links two
  -- inboxes; the guest IP limit (5 / 10 min) and guestCheckout=false are the
  -- organizer's tools for a hot drop.
  h := public.exos_create_guest_hold(pg_temp.u('0000000000e3'), pg_temp.u('0000000000d3'), 2, 'g10-alt@sim-b.test', 'iphash-simb-10');
  ASSERT h IS NOT NULL, 'SIM-BUYER-10: a second email is a second buyer (intended)';
  UPDATE public.exos_cart_holds SET status = 'released' WHERE id = h;
  RAISE NOTICE 'OK SIM-BUYER-10 per-buyer cap: two sessions / guest path / case caught; two emails = two buyers (intended)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-11 The organizer edits the tier mid-checkout.
-- ---------------------------------------------------------------------------
DO $$
DECLARE h uuid; ids uuid[];
BEGIN
  -- a) price raised: the buyer pays and gets what they were shown.
  PERFORM pg_temp.act(pg_temp.u('0000000000b5')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  PERFORM pg_temp.sess('cs_simb_11a', '0000000000e1', '0000000000d1', '0000000000b5', 'b5@sim-b.test', 1, 2000, h);
  UPDATE public.exos_ticket_tiers SET price = 35 WHERE id = pg_temp.u('0000000000d1');
  ids := pg_temp.paid('cs_simb_11a');
  ASSERT (SELECT price_paid FROM public.exos_tickets WHERE id = ids[1]) = 20, 'SIM-BUYER-11a: the price they paid';
  -- b) capacity cut below what is sold while they pay: refused at
  -- fulfilment, refunded, told it sold out.
  h := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  PERFORM pg_temp.sess('cs_simb_11b', '0000000000e1', '0000000000d1', '0000000000b5', 'b5@sim-b.test', 1, 2000, h);
  UPDATE public.exos_ticket_tiers SET capacity = sold WHERE id = pg_temp.u('0000000000d1');
  ids := pg_temp.paid('cs_simb_11b');
  ASSERT cardinality(ids) = 0 AND (SELECT failure_reason FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_11b') = 'tier sold out at fulfillment',
         'SIM-BUYER-11b: capacity cut -> failed (refund)';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'order-failed' AND to_email = 'b5@sim-b.test' AND html LIKE '%sold out while you were paying%'),
         'SIM-BUYER-11b: told why';
  UPDATE public.exos_ticket_tiers SET capacity = 100, price = 20 WHERE id = pg_temp.u('0000000000d1');
  RAISE NOTICE 'OK SIM-BUYER-11 organizer edits mid-checkout: old price honoured; a capacity cut refunds with a reason';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-12/13 Guest email typos. Was KNOWN (12: no way to recover but the
-- organizer's cancel + resend; 13: a typo that is someone's real account got
-- the tickets at once). Decision (mig 20261105100000): a guest (or an
-- unconfirmed account) proves the email (a code mailed to it) or a phone
-- (an SMS code) on the page they paid on before the tickets are released.
-- Until then the order is paid and the seats are kept, but the tickets are
-- parked on the organizer: they don't scan, can't be claimed and aren't
-- attached to any account. The organizer can send the order to a corrected
-- email (Orders page). The paying page holds a browser token (exos-checkout);
-- its SHA-256 is on the session.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.gsess(p_sid text, p_email text, p_buyer text DEFAULT NULL) RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE h uuid;
BEGIN
  IF p_buyer IS NULL THEN
    PERFORM pg_temp.act(NULL);
    h := public.exos_create_guest_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, p_email, 'iphash-' || p_sid);
  ELSE
    PERFORM pg_temp.act(pg_temp.u(p_buyer)::text);
    BEGIN
      h := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
    EXCEPTION WHEN others THEN
      h := NULL;  -- an unconfirmed account can't hold; a bypass code skips the hold
    END;
  END IF;
  PERFORM pg_temp.sess(p_sid, '0000000000e1', '0000000000d1', p_buyer, p_email, 1, 2000, h);
  UPDATE public.exos_checkout_sessions SET proof_token_hash = pg_temp.h('tok-' || p_sid || '-0123456789abcdef') WHERE session_id = p_sid;
  RETURN pg_temp.paid(p_sid);
END $$;
CREATE FUNCTION pg_temp.tok(p_sid text) RETURNS text LANGUAGE sql AS $$ SELECT 'tok-' || p_sid || '-0123456789abcdef' $$;
-- The code in the latest proof mail to an address.
CREATE FUNCTION pg_temp.mailed_code(p_email text) RETURNS text LANGUAGE sql AS $$
  SELECT substring(html from 'letter-spacing:6px"><strong>([0-9]{6})</strong>') FROM public.exos_mail
   WHERE to_email = lower(p_email) AND template = 'rsvp-code' ORDER BY created_at DESC, html DESC LIMIT 1;
$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO anon, authenticated, service_role;

DO $$
DECLARE ids uuid[]; tr uuid; k text; e text; j jsonb;
BEGIN
  -- SIM-BUYER-12 Mistypes their email ("b2@sim-b.tset"): paid, seat kept, parked.
  ids := pg_temp.gsess('cs_simb_12', 'b2@sim-b.tset');
  ASSERT cardinality(ids) = 1 AND (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_12') = 'fulfilled',
         'SIM-BUYER-12: paid and the seat is kept';
  ASSERT (SELECT status FROM public.exos_order_proofs WHERE session_id = 'cs_simb_12') = 'pending', 'SIM-BUYER-12: waits for proof';
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = pg_temp.u('0000000000a0'), 'SIM-BUYER-12: parked on the organizer';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'b2@sim-b.tset' AND template IN ('transfer-initiated', 'ticket-issued')),
         'SIM-BUYER-12: no claim links to the typo';
  -- it doesn't scan
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  j := public.exos_check_in_ticket(ids[1], 'camera', 'verified', pg_temp.t_code(ids[1], now()), pg_temp.u('0000000000e1'));
  ASSERT NOT (j->>'ok')::boolean, 'SIM-BUYER-12: a parked ticket doesn''t scan: ' || j::text;
  -- the organizer's old recovery (cancel the parked transfer) is refused: it
  -- would strand the tickets in the organizer's wallet
  SELECT id, claim_key INTO tr, k FROM public.exos_transfers WHERE ticket_id = ids[1] AND status = 'pending';
  e := pg_temp.err(format('SELECT public.exos_cancel_transfer(%L::uuid)', tr));
  ASSERT e LIKE '%Send to another email%', 'SIM-BUYER-12: cancel points to the resend: ' || coalesce(e, 'none');
  -- the real b2, signed in, can't claim (not with the link either)
  PERFORM pg_temp.act(pg_temp.u('0000000000b2')::text);
  e := pg_temp.err(format('SELECT public.exos_claim_transfer(%L::uuid, %L)', tr, k));
  ASSERT e LIKE '%waiting for the buyer to confirm%', 'SIM-BUYER-12: no claim before proof: ' || coalesce(e, 'none');
  -- the organizer sends the order to the corrected email (Orders page)
  PERFORM pg_temp.act(pg_temp.u('0000000000a9')::text);
  e := pg_temp.err($q$SELECT public.exos_order_proof_resend('cs_simb_12', 'b2@sim-b.test')$q$);
  ASSERT e LIKE '%order not found%', 'SIM-BUYER-12: another org can''t resend: ' || coalesce(e, 'none');
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  e := pg_temp.err($q$SELECT public.exos_order_proof_resend('cs_simb_12', 'not an email')$q$);
  ASSERT e LIKE '%valid email%', 'SIM-BUYER-12: a bad address is refused';
  j := public.exos_order_proof_resend('cs_simb_12', ' B2@Sim-B.test ');
  ASSERT (j->>'ok')::boolean AND (SELECT email || ':' || original_email || ':' || proven_via FROM public.exos_order_proofs WHERE session_id = 'cs_simb_12')
         = 'b2@sim-b.test:b2@sim-b.tset:organizer', 'SIM-BUYER-12: corrected (original kept): ' || j::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'b2@sim-b.test' AND template = 'transfer-initiated' AND html LIKE '%/claim/%'),
         'SIM-BUYER-12: claim links to the corrected email';
  -- the old link is dead; the new one works for b2
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  e := pg_temp.err(format('SELECT public.exos_claim_transfer(%L::uuid, %L)', tr, k));
  ASSERT e LIKE '%transfer is cancelled%', 'SIM-BUYER-12: the typo''s link is dead: ' || coalesce(e, 'none');
  SELECT id, claim_key INTO tr, k FROM public.exos_transfers WHERE ticket_id = ids[1] AND status = 'pending';
  PERFORM pg_temp.act(pg_temp.u('0000000000b2')::text);
  ASSERT public.exos_claim_transfer(tr, k) = ids[1], 'SIM-BUYER-12: b2 claims';
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = pg_temp.u('0000000000b2'), 'SIM-BUYER-12: b2 owns it';
  RAISE NOTICE 'OK SIM-BUYER-12 mistyped guest email: paid, seat kept, nothing released to the typo; the organizer resends to the right address';

  -- SIM-BUYER-13 The typo is someone else's real, confirmed account: they get nothing.
  ids := pg_temp.gsess('cs_simb_13', 'typo-owner@sim-b.test');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = pg_temp.u('0000000000a0'), 'SIM-BUYER-13: not in the stranger''s wallet';
  SELECT id, claim_key INTO tr, k FROM public.exos_transfers WHERE ticket_id = ids[1] AND status = 'pending';
  PERFORM pg_temp.act(pg_temp.u('0000000000b6')::text);
  e := pg_temp.err(format('SELECT public.exos_claim_transfer(%L::uuid)', tr));
  ASSERT e IS NOT NULL, 'SIM-BUYER-13: the stranger can''t claim by their email';
  -- the stranger has the code mail, but not the paying browser's token
  j := public.exos_order_proof_verify('cs_simb_13', 'tok-guess-0123456789abcdefghij', pg_temp.mailed_code('typo-owner@sim-b.test'));
  ASSERT j->>'error' = 'unknown', 'SIM-BUYER-13: the code alone does nothing: ' || j::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'typo-owner@sim-b.test' AND template IN ('transfer-initiated', 'ticket-issued')),
         'SIM-BUYER-13: no ticket mail to the stranger';
  -- the buyer, still on the paying page, sees "ty…@sim-b.test" and proves a phone instead
  PERFORM pg_temp.act(NULL);
  j := public.exos_order_proof_status('cs_simb_13', pg_temp.tok('cs_simb_13'));
  ASSERT j->>'status' = 'pending' AND j->>'email' = 'ty…@sim-b.test', 'SIM-BUYER-13: the page shows the masked email: ' || j::text;
  j := public.exos_order_proof_send('cs_simb_13', pg_temp.tok('cs_simb_13'), 'sms', '(212) 555-0190');
  ASSERT (j->>'ok')::boolean, 'SIM-BUYER-13: SMS code sent: ' || j::text;
  j := public.exos_order_proof_verify('cs_simb_13', pg_temp.tok('cs_simb_13'),
         (SELECT substring(body from '^([0-9]{6})') FROM public.exos_rsvp_sms_outbox WHERE phone = '+12125550190' ORDER BY created_at DESC LIMIT 1));
  ASSERT (j->>'ok')::boolean AND NOT (j->>'attached')::boolean AND jsonb_array_length(j->'tickets') = 1,
         'SIM-BUYER-13: proven by phone: the claim link is on the page: ' || j::text;
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = pg_temp.u('0000000000a0'), 'SIM-BUYER-13: still not the stranger''s';
  RAISE NOTICE 'OK SIM-BUYER-13 typo matches a real account: that account gets nothing; the buyer proves a phone and gets the claim link';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-12b..e Proof: the right email releases; five wrong codes; an
-- unconfirmed account; replays.
-- ---------------------------------------------------------------------------
DO $$
DECLARE ids uuid[]; ids2 uuid[]; j jsonb; c text; wrong text; i int; n int;
BEGIN
  -- 12b the right email, which has a confirmed account: proving it puts the
  -- tickets in that account (and only then)
  ids := pg_temp.gsess('cs_simb_12b', 'b4@sim-b.test');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = pg_temp.u('0000000000a0'), 'SIM-BUYER-12b: parked before proof';
  PERFORM pg_temp.act(NULL);
  j := public.exos_order_proof_verify('cs_simb_12b', pg_temp.tok('cs_simb_12b'), pg_temp.mailed_code('b4@sim-b.test'));
  ASSERT (j->>'ok')::boolean AND (j->>'attached')::boolean, 'SIM-BUYER-12b: proven: ' || j::text;
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = pg_temp.u('0000000000b4')
     AND (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = ids[1]) IS NULL, 'SIM-BUYER-12b: in b4''s wallet';
  -- replay (second tab / retry): same answer, nothing twice
  j := public.exos_order_proof_verify('cs_simb_12b', pg_temp.tok('cs_simb_12b'), '000000');
  ASSERT (j->>'ok')::boolean AND j->>'status' = 'proven', 'SIM-BUYER-12b: replay is idempotent: ' || j::text;
  ASSERT public.exos_fulfill_checkout('cs_simb_12b') = ids, 'SIM-BUYER-12b: re-fulfilment returns the same tickets';
  ASSERT (SELECT count(*) FROM public.exos_order_proofs WHERE session_id = 'cs_simb_12b') = 1,
         'SIM-BUYER-12b: re-fulfilment opens nothing new';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE to_email = 'b4@sim-b.test' AND template = 'ticket-issued' AND html LIKE '%Email confirmed%') = 1,
         'SIM-BUYER-12b: one wallet mail';
  RAISE NOTICE 'OK SIM-BUYER-12b the right email proven by code: the tickets go to that account, once';

  -- 12c five wrong codes lock the live code (even the right one); a new code
  -- (after the 60-second wait) works; a wrong token never counts
  ids := pg_temp.gsess('cs_simb_12c', 'g12c@sim-b.test');
  c := pg_temp.mailed_code('g12c@sim-b.test');
  wrong := CASE WHEN c = '000000' THEN '111111' ELSE '000000' END;
  j := public.exos_order_proof_verify('cs_simb_12c', 'tok-wrong-0123456789abcdef', wrong);
  ASSERT j->>'error' = 'unknown', 'SIM-BUYER-12c: a wrong token is no order';
  FOR i IN 1..4 LOOP
    j := public.exos_order_proof_verify('cs_simb_12c', pg_temp.tok('cs_simb_12c'), wrong);
    ASSERT j->>'error' = 'wrong_code' AND (j->>'attempts_left')::int = 5 - i, 'SIM-BUYER-12c: miss ' || i || ': ' || j::text;
  END LOOP;
  j := public.exos_order_proof_verify('cs_simb_12c', pg_temp.tok('cs_simb_12c'), wrong);
  ASSERT j->>'error' = 'locked', 'SIM-BUYER-12c: the fifth miss locks: ' || j::text;
  j := public.exos_order_proof_verify('cs_simb_12c', pg_temp.tok('cs_simb_12c'), c);
  ASSERT j->>'error' = 'locked', 'SIM-BUYER-12c: the right code after the lock is refused: ' || j::text;
  j := public.exos_order_proof_send('cs_simb_12c', pg_temp.tok('cs_simb_12c'), 'email');
  ASSERT j->>'error' = 'rate_limited', 'SIM-BUYER-12c: a new code waits 60 seconds: ' || j::text;
  UPDATE public.exos_order_proofs SET email_code_at = now() - interval '2 minutes' WHERE session_id = 'cs_simb_12c';
  DELETE FROM public.exos_mail WHERE to_email = 'g12c@sim-b.test' AND template = 'rsvp-code';  -- (same now(): keep the new one findable)
  j := public.exos_order_proof_send('cs_simb_12c', pg_temp.tok('cs_simb_12c'), 'email');
  ASSERT (j->>'ok')::boolean AND j->>'to' = 'g1…@sim-b.test', 'SIM-BUYER-12c: new code sent: ' || j::text;
  IF pg_temp.mailed_code('g12c@sim-b.test') <> c THEN
    j := public.exos_order_proof_verify('cs_simb_12c', pg_temp.tok('cs_simb_12c'), c);
    ASSERT j->>'error' = 'wrong_code', 'SIM-BUYER-12c: the old code is gone: ' || j::text;
  END IF;
  j := public.exos_order_proof_verify('cs_simb_12c', pg_temp.tok('cs_simb_12c'), pg_temp.mailed_code('g12c@sim-b.test'));
  ASSERT (j->>'ok')::boolean AND NOT (j->>'attached')::boolean, 'SIM-BUYER-12c: the new code proves it: ' || j::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'g12c@sim-b.test' AND template = 'transfer-initiated' AND html LIKE '%/claim/%'),
         'SIM-BUYER-12c: no account: the claim links are mailed once proven';
  -- send limits: 5 code mails per order
  ids := pg_temp.gsess('cs_simb_12d', 'g12d@sim-b.test');
  FOR i IN 2..5 LOOP
    UPDATE public.exos_order_proofs SET email_code_at = now() - interval '2 minutes' WHERE session_id = 'cs_simb_12d';
    ASSERT (public.exos_order_proof_send('cs_simb_12d', pg_temp.tok('cs_simb_12d'), 'email') ->> 'ok')::boolean, 'SIM-BUYER-12c: send ' || i;
  END LOOP;
  UPDATE public.exos_order_proofs SET email_code_at = now() - interval '2 minutes' WHERE session_id = 'cs_simb_12d';
  ASSERT public.exos_order_proof_send('cs_simb_12d', pg_temp.tok('cs_simb_12d'), 'email') ->> 'error' = 'rate_limited', 'SIM-BUYER-12c: the sixth mail is refused';
  RAISE NOTICE 'OK SIM-BUYER-12c five wrong codes lock it; a new code after 60 s works; 5 mails per order; a wrong token is no order';

  -- 12e a signed-in account whose email isn't confirmed can't take a hold
  -- (exos_create_hold refuses it), but an order can still reach fulfilment
  -- (a capacity-bypass code skips the hold): it proves the email too, and
  -- once proven the tickets go to that account (theirs, whichever channel)
  ids := pg_temp.gsess('cs_simb_12e', 'unconfirmed@sim-b.test', '0000000000b7');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = pg_temp.u('0000000000a0')
     AND (SELECT status FROM public.exos_order_proofs WHERE session_id = 'cs_simb_12e') = 'pending', 'SIM-BUYER-12e: unconfirmed: parked';
  j := public.exos_order_proof_verify('cs_simb_12e', pg_temp.tok('cs_simb_12e'), pg_temp.mailed_code('unconfirmed@sim-b.test'));
  ASSERT (j->>'attached')::boolean AND (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = pg_temp.u('0000000000b7'),
         'SIM-BUYER-12e: proven: in their own account: ' || j::text;
  -- a confirmed account skips proof
  ids2 := pg_temp.gsess('cs_simb_12f', 'b5@sim-b.test', '0000000000b5');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids2[1]) = pg_temp.u('0000000000b5')
     AND NOT EXISTS (SELECT 1 FROM public.exos_order_proofs WHERE session_id = 'cs_simb_12f'), 'SIM-BUYER-12e: confirmed: straight in';
  -- a refund closes the proof
  ids := pg_temp.gsess('cs_simb_12g', 'g12g@sim-b.test');
  UPDATE public.exos_checkout_sessions SET status = 'refunded' WHERE session_id = 'cs_simb_12g';
  ASSERT (SELECT status FROM public.exos_order_proofs WHERE session_id = 'cs_simb_12g') = 'cancelled'
     AND public.exos_order_proof_status('cs_simb_12g', pg_temp.tok('cs_simb_12g')) ->> 'status' = 'cancelled', 'SIM-BUYER-12e: refunded: closed';
  RAISE NOTICE 'OK SIM-BUYER-12e an unconfirmed account proves too (then its own wallet); a confirmed one skips proof; a refund closes it';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-14 Bad email shapes at guest checkout are refused up front.
-- ---------------------------------------------------------------------------
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$SELECT public.exos_create_guest_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 'b2@sim-b', 'iphash-simb-14')$q$);
  ASSERT e LIKE '%enter a valid email%', 'SIM-BUYER-14: no TLD';
  e := pg_temp.err($q$SELECT public.exos_create_guest_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 'b2 @sim-b.test', 'iphash-simb-14')$q$);
  ASSERT e LIKE '%enter a valid email%', 'SIM-BUYER-14: inner space';
  RAISE NOTICE 'OK SIM-BUYER-14 malformed guest email refused before payment';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-15..18 Gift cards: typo, imported short code, expired, another
-- org's, applied twice. (exos-checkout quotes with exos_gift_card_quote and
-- holds with exos_gift_card_hold, both service role.)
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  r := public.exos_gift_card_issue(pg_temp.u('000000000001'), 5000, 'comp');
  INSERT INTO simb VALUES ('gc1', r->>'code'), ('gc1id', r->>'card_id');
  r := public.exos_gift_card_issue(pg_temp.u('000000000001'), 5000, 'comp');
  INSERT INTO simb VALUES ('gc_exp', r->>'code'), ('gc_expid', r->>'card_id');
  r := public.exos_gift_card_import(pg_temp.u('000000000001'), 'gift_up', '[{"code":"SIMB-77","balance_cents":2500}]'::jsonb);
  PERFORM pg_temp.act(pg_temp.u('0000000000a9')::text);
  r := public.exos_gift_card_issue(pg_temp.u('000000000002'), 5000, 'comp');
  INSERT INTO simb VALUES ('gc_other', r->>'code');
  UPDATE public.exos_gift_cards SET expires_at = now() - interval '1 day' WHERE id = (SELECT v::uuid FROM simb WHERE k = 'gc_expid');
END $$;
SET ROLE service_role;
DO $$
DECLARE c text := public.exos_gift_card_normalize((SELECT v FROM simb WHERE k = 'gc1')); typo text; q jsonb; i int; a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
BEGIN
  -- SIM-BUYER-15: one wrong character (any position) is caught by the check
  -- character; dashes, spaces and lower case are ignored.
  typo := substr(c, 1, 4) || CASE WHEN substr(c, 5, 1) = 'A' THEN 'B' ELSE 'A' END || substr(c, 6);
  q := public.exos_gift_card_quote(typo, 'simb-15a', pg_temp.u('000000000001'), 'usd', 2000);
  ASSERT q->>'error' = 'that gift card code isn''t valid (check for a typo)', 'SIM-BUYER-15: typo: ' || q::text;
  q := public.exos_gift_card_quote(lower(substr(c,1,4) || ' ' || substr(c,5,4) || '-' || substr(c,9)), 'simb-15b', pg_temp.u('000000000001'), 'usd', 2000);
  ASSERT q->>'error' IS NULL AND (q->>'applicable_cents')::int = 2000, 'SIM-BUYER-15: spaced lower-case code works: ' || q::text;
  -- an imported short code, typed in lower case with a space
  q := public.exos_gift_card_quote('simb 77', 'simb-15c', pg_temp.u('000000000001'), 'usd', 2000);
  ASSERT q->>'error' IS NULL AND (q->>'applicable_cents')::int = 2000, 'SIM-BUYER-15: imported code: ' || q::text;
  q := public.exos_gift_card_quote('SIMB-78', 'simb-15d', pg_temp.u('000000000001'), 'usd', 2000);
  ASSERT q->>'error' = 'gift card not found', 'SIM-BUYER-15: mistyped imported code: ' || q::text;
  RAISE NOTICE 'OK SIM-BUYER-15 gift card typos: check character catches Exos codes; imported codes say "not found"';

  -- SIM-BUYER-16 expired / another org's card
  q := public.exos_gift_card_quote((SELECT v FROM simb WHERE k = 'gc_exp'), 'simb-16a', pg_temp.u('000000000001'), 'usd', 2000);
  ASSERT q->>'error' = 'this gift card expired', 'SIM-BUYER-16: expired: ' || q::text;
  q := public.exos_gift_card_quote((SELECT v FROM simb WHERE k = 'gc_other'), 'simb-16b', pg_temp.u('000000000001'), 'usd', 2000);
  ASSERT q->>'error' = 'this gift card is for another organizer', 'SIM-BUYER-16: other org: ' || q::text;
  RAISE NOTICE 'OK SIM-BUYER-16 expired / other-org gift card: clear errors, nothing held';

  -- SIM-BUYER-17 applied twice: the same order twice is one hold; a second
  -- order can't spend what the first holds.
  PERFORM public.exos_gift_card_hold(c, 'cs_simb_17a', 4000, 'simb-17', pg_temp.u('000000000001'), 'usd');
  q := public.exos_gift_card_hold(c, 'cs_simb_17a', 4000, 'simb-17', pg_temp.u('000000000001'), 'usd');
  ASSERT NOT (q->>'fresh')::boolean AND (q->>'balance_cents')::int = 1000, 'SIM-BUYER-17: replay is the same hold: ' || q::text;
  BEGIN
    PERFORM public.exos_gift_card_hold(c, 'cs_simb_17b', 4000, 'simb-17', pg_temp.u('000000000001'), 'usd');
    RAISE EXCEPTION 'SIM-BUYER-17: overdrawn';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM = 'the gift card balance changed, please try again', 'SIM-BUYER-17: ' || SQLERRM;
  END;
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (SELECT v::uuid FROM simb WHERE k = 'gc1id')) = 1000, 'SIM-BUYER-17: balance 10.00';
  RAISE NOTICE 'OK SIM-BUYER-17 gift card applied twice: one hold, never overdrawn';

  -- SIM-BUYER-18 guessing codes: the 11th miss in a minute is refused even
  -- for a real card, with a message that says to wait (not "typo").
  FOR i IN 1..10 LOOP
    PERFORM public.exos_gift_card_quote('ABCD-EFGH-JKLM-NPQ' || substr(a, i, 1), 'simb-18', NULL, NULL, 100);
  END LOOP;
  q := public.exos_gift_card_quote(c, 'simb-18', pg_temp.u('000000000001'), 'usd', 100);
  ASSERT q->>'error' = 'too many gift card attempts, try again in a minute', 'SIM-BUYER-18: ' || q::text;
  RAISE NOTICE 'OK SIM-BUYER-18 gift card guessing throttled with a clear "try again in a minute"';
END $$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-19 Promo codes: wrong, expired, used up, wrong case / spaces,
-- then the throttle. (exos-checkout trims the code; the SQL trims again.)
-- The SPA's copy for 'too many attempts' was the generic "check the spelling"
-- line, so a buyer who then typed the RIGHT code was told to check the
-- spelling. FIXED in src/components/VoucherField.tsx (tested in
-- src/lib/sim/buyer.test.ts).
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_vouchers(event_id, code, max_uses, used_count, valid_until, discount_percent) VALUES
  ('be000000-0000-0000-0000-0000000000e1', 'SAVE10', 5, 0, NULL, 10),
  ('be000000-0000-0000-0000-0000000000e1', 'OLDIE5', 5, 0, now() - interval '1 hour', 10),
  ('be000000-0000-0000-0000-0000000000e1', 'GONE22', 2, 2, NULL, 10);
DO $$
DECLARE r record; i int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b4')::text);
  SELECT * INTO r FROM public.exos_check_voucher(pg_temp.u('0000000000e1'), 'SAVE1O');
  ASSERT NOT r.is_valid AND r.reason = 'invalid code', 'SIM-BUYER-19: O for 0';
  SELECT * INTO r FROM public.exos_check_voucher(pg_temp.u('0000000000e1'), '  save10 ');
  ASSERT r.is_valid, 'SIM-BUYER-19: case and spaces ignored';
  SELECT * INTO r FROM public.exos_check_voucher(pg_temp.u('0000000000e1'), 'oldie5');
  ASSERT NOT r.is_valid AND r.reason = 'expired', 'SIM-BUYER-19: expired';
  SELECT * INTO r FROM public.exos_check_voucher(pg_temp.u('0000000000e1'), 'GONE22');
  ASSERT NOT r.is_valid AND r.reason = 'already used', 'SIM-BUYER-19: used up';
  SELECT * INTO r FROM public.exos_check_voucher(pg_temp.u('0000000000e2'), 'SAVE10');
  ASSERT NOT r.is_valid AND r.reason = 'invalid code', 'SIM-BUYER-19: another event''s code';
  -- 10 misses in the window (two above + eight more), then the right code
  FOR i IN 1..8 LOOP PERFORM public.exos_check_voucher(pg_temp.u('0000000000e1'), 'NOPE' || i); END LOOP;
  SELECT * INTO r FROM public.exos_check_voucher(pg_temp.u('0000000000e1'), 'SAVE10');
  ASSERT NOT r.is_valid AND r.reason = 'too many attempts', 'SIM-BUYER-19: throttled: ' || coalesce(r.reason, 'valid');
  -- another buyer is not affected
  PERFORM pg_temp.act(pg_temp.u('0000000000b5')::text);
  SELECT * INTO r FROM public.exos_check_voucher(pg_temp.u('0000000000e1'), 'SAVE10');
  ASSERT r.is_valid, 'SIM-BUYER-19: the throttle is per account';
  RAISE NOTICE 'OK SIM-BUYER-19 promo codes: wrong / expired / used up / case + spaces / per-account throttle';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-20 Asks for a refund twice, then after the event.
-- ---------------------------------------------------------------------------
DO $$
DECLARE h uuid; ids uuid[]; j1 jsonb; j2 jsonb; j3 jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b5')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  PERFORM pg_temp.sess('cs_simb_20', '0000000000e1', '0000000000d1', '0000000000b5', 'b5@sim-b.test', 1, 2000, h);
  ids := pg_temp.paid('cs_simb_20');
  j1 := public.exos_ask_refund(ids, 'cannot make it');
  j2 := public.exos_ask_refund(ids || ids, 'cannot make it!!');
  ASSERT (j1->0->>'ok')::boolean AND (j2->0->>'existing')::boolean AND j2->0->>'ask_id' = j1->0->>'ask_id'
     AND jsonb_array_length(j2) = 1, 'SIM-BUYER-20: asking twice is the same ask: ' || j2::text;
  -- After the event (e4 started two days ago): too late.
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,created_at)
  VALUES ('cs_simb_20b', pg_temp.u('0000000000e4'), pg_temp.u('0000000000d4'), pg_temp.u('000000000001'), pg_temp.u('0000000000b5'), 'b5@sim-b.test', 1, 2000, 'usd', 'fulfilled', now() - interval '5 days');
  PERFORM public.exos_record_payment('cs_simb_20b', 'pi_cs_simb_20b', 2000, 'succeeded');
  INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
  VALUES (pg_temp.u('000000000c20'), pg_temp.u('0000000000e4'), pg_temp.u('000000000001'), pg_temp.u('0000000000d4'), 'GA',
          pg_temp.u('0000000000b5'), pg_temp.u('0000000000b5'), 'b5@sim-b.test', 'active', 'k20', 20, 'cs_simb_20b', 'stripe');
  j3 := public.exos_ask_refund(ARRAY[pg_temp.u('000000000c20')]);
  ASSERT j3->0->>'reason' = 'too-late', 'SIM-BUYER-20: after the event: ' || j3::text;
  RAISE NOTICE 'OK SIM-BUYER-20 refund asked twice = one ask; after the event = too-late';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-21 The refund lands twice (organizer refund + Stripe's
-- charge.refunded): tickets voided once, seats back once, ledger once.
-- FIXED: a refund that didn't come through the organizer's refund-request
-- flow left the buyer's ask 'open' (mig 20261104100000 section 3).
-- ---------------------------------------------------------------------------
DO $$
DECLARE sold0 int := (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1')); n1 int; n2 int;
BEGIN
  PERFORM public.exos_record_refund('cs_simb_20', 're_simb_20', 2000, 'succeeded', 'pi_cs_simb_20');
  PERFORM public.exos_record_refund('cs_simb_20', 're_simb_20', 2000, 'succeeded', 'pi_cs_simb_20');
  n1 := public.exos_refund_checkout('cs_simb_20', 'stripe refund');
  n2 := public.exos_refund_checkout('cs_simb_20', 'stripe refund');
  ASSERT n1 = 1 AND n2 = 0, 'SIM-BUYER-21: voided once';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1')) = sold0 - 1, 'SIM-BUYER-21: seat back once';
  ASSERT (SELECT count(*) FROM public.exos_order_refunds WHERE session_id = 'cs_simb_20') = 1, 'SIM-BUYER-21: one refund row';
  ASSERT (SELECT status FROM public.exos_refund_asks WHERE session_id = 'cs_simb_20') <> 'open', 'SIM-BUYER-21: the ask closes';
  RAISE NOTICE 'FIXED SIM-BUYER-21 a refund delivered twice is applied once and closes the ask';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-22 Transfers to the wrong email, cancels, the recipient claims
-- anyway, then the sender scans (doors open on e6).
-- ---------------------------------------------------------------------------
DO $$
DECLARE h uuid; ids uuid[]; tr uuid; k text; e text; r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e6'), pg_temp.u('0000000000d6'), 1);
  PERFORM pg_temp.sess('cs_simb_22', '0000000000e6', '0000000000d6', '0000000000b3', 'b3@sim-b.test', 1, 2000, h);
  ids := pg_temp.paid('cs_simb_22');
  INSERT INTO simb VALUES ('t22', ids[1]::text);
  tr := public.exos_create_transfer(ids[1], 'b4@sim-b.tset');      -- the typo
  SELECT claim_key INTO k FROM public.exos_transfers WHERE id = tr;
  -- while pending, the sender's QR is refused at the door: "in transfer"
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified', pg_temp.t_code(ids[1], now()), pg_temp.u('0000000000e6'));
  ASSERT r->>'reason' = 'in-transfer', 'SIM-BUYER-22: pending transfer blocks the scan: ' || r::text;
  -- the sender notices and cancels; the forwarded link is now dead
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  PERFORM public.exos_cancel_transfer(tr);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'transfer-initiated' AND status = 'pending' AND to_email = 'b4@sim-b.tset'),
         'SIM-BUYER-22: the unsent claim mail is withdrawn';
  PERFORM pg_temp.act(pg_temp.u('0000000000b4')::text);
  e := pg_temp.err(format('SELECT public.exos_claim_transfer(%L::uuid, %L)', tr, k));
  ASSERT e LIKE '%transfer is cancelled%', 'SIM-BUYER-22: claim after cancel refused: ' || coalesce(e, 'none');
  -- the sender cancels twice (double tap): a clear "transfer is cancelled"
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  e := pg_temp.err(format('SELECT public.exos_cancel_transfer(%L::uuid)', tr));
  ASSERT e LIKE '%transfer is cancelled%', 'SIM-BUYER-22: double cancel';
  -- and scans fine
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified', pg_temp.t_code(ids[1], now()), pg_temp.u('0000000000e6'));
  ASSERT (r->>'ok')::boolean AND r->>'reason' = 'checked-in', 'SIM-BUYER-22: sender admitted: ' || r::text;
  -- a transfer of a used ticket is refused
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  e := pg_temp.err(format('SELECT public.exos_create_transfer(%L::uuid, %L)', ids[1], 'b4@sim-b.test'));
  ASSERT e LIKE '%only active is transferable%', 'SIM-BUYER-22: used ticket not transferable';
  RAISE NOTICE 'OK SIM-BUYER-22 wrong-email transfer: blocked at the door while pending, cancel kills the link, sender admitted';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-23 Transfer claimed: the sender's old QR (a screenshot) and the
-- old code are dead; the recipient's code works; a second claim of the same
-- link is refused. Then the claim racing a refund (sequential form; the
-- parallel form is race_sim_buyer.sh race 3).
-- ---------------------------------------------------------------------------
DO $$
DECLARE h uuid; ids uuid[]; tr uuid; k text; e text; r jsonb; old_code text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e6'), pg_temp.u('0000000000d6'), 2);
  PERFORM pg_temp.sess('cs_simb_23', '0000000000e6', '0000000000d6', '0000000000b3', 'b3@sim-b.test', 2, 4000, h);
  ids := pg_temp.paid('cs_simb_23');
  old_code := pg_temp.t_code(ids[1], now());          -- the sender screenshots it
  tr := public.exos_create_transfer(ids[1], 'b4@sim-b.test');
  SELECT claim_key INTO k FROM public.exos_transfers WHERE id = tr;
  PERFORM pg_temp.act(pg_temp.u('0000000000b4')::text);
  ASSERT public.exos_claim_transfer(tr, k) = ids[1], 'SIM-BUYER-23: claimed';
  PERFORM pg_temp.act(pg_temp.u('0000000000b5')::text);  -- the link was forwarded on
  e := pg_temp.err(format('SELECT public.exos_claim_transfer(%L::uuid, %L)', tr, k));
  ASSERT e LIKE '%transfer is completed%', 'SIM-BUYER-23: second claim refused: ' || coalesce(e, 'none');
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified', old_code, pg_temp.u('0000000000e6'));
  ASSERT r->>'reason' = 'barcode-rejected', 'SIM-BUYER-23: sender''s screenshot refused: ' || r::text;
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified', pg_temp.t_code(ids[1], now()), pg_temp.u('0000000000e6'));
  ASSERT (r->>'ok')::boolean, 'SIM-BUYER-23: recipient admitted: ' || r::text;
  -- ticket 2: refunded while its transfer is pending; the claim then fails
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  tr := public.exos_create_transfer(ids[2], 'b4@sim-b.test');
  PERFORM public.exos_refund_checkout('cs_simb_23', 'refunded');
  PERFORM pg_temp.act(pg_temp.u('0000000000b4')::text);
  e := pg_temp.err(format('SELECT public.exos_claim_transfer(%L::uuid)', tr));
  ASSERT e LIKE '%ticket was refunded%', 'SIM-BUYER-23: claim of a refunded ticket refused: ' || coalesce(e, 'none');
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = ids[2]) = 'voided', 'SIM-BUYER-23: stays voided';
  RAISE NOTICE 'OK SIM-BUYER-23 claimed transfer: old screenshot dead, recipient admitted, one claim per link, refunded stays void';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-24 Shares a screenshot of the rotating QR: a code from more than
-- ~90 s ago is refused as expired; the live one scans once, then "used".
-- ---------------------------------------------------------------------------
DO $$
DECLARE h uuid; ids uuid[]; r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b5')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e6'), pg_temp.u('0000000000d6'), 1);
  PERFORM pg_temp.sess('cs_simb_24', '0000000000e6', '0000000000d6', '0000000000b5', 'b5@sim-b.test', 1, 2000, h);
  ids := pg_temp.paid('cs_simb_24');
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified', pg_temp.t_code(ids[1], now() - interval '3 minutes'), pg_temp.u('0000000000e6'));
  ASSERT r->>'reason' = 'barcode-expired', 'SIM-BUYER-24: old screenshot: ' || r::text;
  -- a hand-edited code (bucket bumped, MAC kept) is rejected, not "expired"
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified',
         regexp_replace(pg_temp.t_code(ids[1], now()), ':([0-9]+):', ':' || (floor(extract(epoch FROM now()) * 1000 / 30000)::bigint + 1) || ':'),
         pg_temp.u('0000000000e6'));
  ASSERT r->>'reason' = 'barcode-rejected', 'SIM-BUYER-24: forged bucket: ' || r::text;
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified', pg_temp.t_code(ids[1], now()), pg_temp.u('0000000000e6'));
  ASSERT (r->>'ok')::boolean, 'SIM-BUYER-24: live code admits';
  -- the friend with a fresh screenshot, a minute later
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified', pg_temp.t_code(ids[1], now()), pg_temp.u('0000000000e6'));
  ASSERT NOT (r->>'ok')::boolean AND r->>'reason' IN ('already-used', 'used'), 'SIM-BUYER-24: second entry refused: ' || r::text;
  RAISE NOTICE 'OK SIM-BUYER-24 rotating QR screenshots: stale = expired, forged = rejected, a fresh copy gets in once';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-25 Scans an old Apple Wallet pass after transferring the ticket.
-- ---------------------------------------------------------------------------
DO $$
DECLARE h uuid; ids uuid[]; tr uuid; s text; old_code text; r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b2')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e6'), pg_temp.u('0000000000d6'), 1);
  PERFORM pg_temp.sess('cs_simb_25', '0000000000e6', '0000000000d6', '0000000000b2', 'b2@sim-b.test', 1, 2000, h);
  ids := pg_temp.paid('cs_simb_25');
  s := public.exos_wallet_issue_pass(ids[1], 'apple', pg_temp.h('tok-simb-25-000000000001'), 'pass.com.exos.test') ->> 'serial';
  old_code := public.exos_wallet_pass_payload(s) ->> 'apple_code';
  tr := public.exos_create_transfer(ids[1], 'b1@sim-b.test');
  PERFORM pg_temp.act(pg_temp.u('0000000000b1')::text);
  PERFORM public.exos_claim_transfer(tr);
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  r := public.exos_check_in_ticket(ids[1], 'camera', 'verified', old_code, pg_temp.u('0000000000e6'));
  ASSERT NOT (r->>'ok')::boolean AND r->>'reason' = 'barcode-rejected', 'SIM-BUYER-25: old wallet pass refused: ' || r::text;
  ASSERT (SELECT status FROM public.exos_wallet_passes WHERE serial_number = s) = 'voided', 'SIM-BUYER-25: pass voided (push queued)';
  RAISE NOTICE 'OK SIM-BUYER-25 old Apple Wallet pass after a transfer: voided and refused at the door';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-26 Joins the waitlist twice; buys while also on it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE w1 uuid; w2 uuid; n int; h uuid; ids uuid[];
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000b1')::text);
  SELECT waitlist_id INTO w1 FROM public.exos_join_waitlist(pg_temp.u('0000000000e7'), NULL, NULL, 'B One', 1, NULL);
  SELECT waitlist_id INTO w2 FROM public.exos_join_waitlist(pg_temp.u('0000000000e7'), 'someone-else@x.com', NULL, 'B One', 2, NULL);
  ASSERT w1 = w2 AND (SELECT count(*) FROM public.exos_waitlist WHERE event_id = pg_temp.u('0000000000e7')) = 1
     AND (SELECT quantity || ':' || email FROM public.exos_waitlist WHERE id = w1) = '2:b1@sim-b.test',
         'SIM-BUYER-26: one row, the session''s own email, latest quantity';
  PERFORM pg_temp.act(pg_temp.u('0000000000b2')::text);
  PERFORM public.exos_join_waitlist(pg_temp.u('0000000000e7'), NULL, NULL, 'B Two', 1, NULL);
  -- a seat frees up and b1 buys it at the box office / normal checkout
  UPDATE public.exos_ticket_tiers SET capacity = 2 WHERE id = pg_temp.u('0000000000d7');
  PERFORM pg_temp.act(pg_temp.u('0000000000b1')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e7'), pg_temp.u('0000000000d7'), 1);
  PERFORM pg_temp.sess('cs_simb_26', '0000000000e7', '0000000000d7', '0000000000b1', 'b1@sim-b.test', 1, 2000, h);
  ids := pg_temp.paid('cs_simb_26');
  ASSERT cardinality(ids) = 1, 'SIM-BUYER-26: bought while waitlisted';
  ASSERT (SELECT status FROM public.exos_waitlist WHERE id = w1) = 'converted', 'SIM-BUYER-26: the buyer is marked converted';
  -- later a refund frees a seat: the offer skips b1 and goes to b2
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  UPDATE public.exos_ticket_tiers SET capacity = 3 WHERE id = pg_temp.u('0000000000d7');
  n := public.exos_waitlist_offer_next(pg_temp.u('0000000000e7'), 1, 48, NULL);
  ASSERT (SELECT status FROM public.exos_waitlist WHERE id = w1) = 'converted'
     AND (SELECT status FROM public.exos_waitlist WHERE event_id = pg_temp.u('0000000000e7') AND email = 'b2@sim-b.test') = 'offered',
         'SIM-BUYER-26: the offer goes to the next in line';
  -- another seat opens (nobody waiting, so no offer), b3 joins, and b2 buys
  -- that seat through normal checkout without the offer code: b2 is
  -- converted and the unused offer passes to b3
  UPDATE public.exos_ticket_tiers SET capacity = 4 WHERE id = pg_temp.u('0000000000d7');  -- another seat (b2's offer still holds one)
  PERFORM pg_temp.act(pg_temp.u('0000000000b3')::text);
  PERFORM public.exos_join_waitlist(pg_temp.u('0000000000e7'), NULL, NULL, 'B Three', 1, NULL);
  PERFORM pg_temp.act(pg_temp.u('0000000000b2')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e7'), pg_temp.u('0000000000d7'), 1);
  PERFORM pg_temp.sess('cs_simb_26b', '0000000000e7', '0000000000d7', '0000000000b2', 'b2@sim-b.test', 1, 2000, h);
  ASSERT cardinality(pg_temp.paid('cs_simb_26b')) = 1, 'SIM-BUYER-26: b2 bought';
  ASSERT (SELECT status FROM public.exos_waitlist WHERE event_id = pg_temp.u('0000000000e7') AND email = 'b2@sim-b.test') = 'converted',
         'SIM-BUYER-26: b2 converted';
  ASSERT (SELECT v.valid_until <= now() FROM public.exos_waitlist w JOIN public.exos_vouchers v ON v.id = w.voucher_id
           WHERE w.event_id = pg_temp.u('0000000000e7') AND w.email = 'b2@sim-b.test'), 'SIM-BUYER-26: b2''s unused offer is retired';
  ASSERT (SELECT status FROM public.exos_waitlist WHERE event_id = pg_temp.u('0000000000e7') AND email = 'b3@sim-b.test') = 'offered',
         'SIM-BUYER-26: and passed to b3';
  RAISE NOTICE 'OK SIM-BUYER-26 waitlist: one row per buyer; buying marks them converted and passes their open offer to the next in line';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-27..32 Phone RSVP (e5: free tier, 3 seats, up to 1 plus-one).
-- exos-rsvp calls these as the service role; the code goes by SMS (returned
-- here so the test can read it) or by email.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  PERFORM public.exos_set_phone_rsvp(pg_temp.u('0000000000e5'), true, pg_temp.u('0000000000d5'), 1);
END $$;
SET ROLE service_role;
DO $$
DECLARE r jsonb; v jsonb; i int; code text; wrong text;
BEGIN
  -- SIM-BUYER-27 wrong / malformed phone number
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Ana', '555-01', NULL, 0, NULL, true);
  ASSERT r->>'error' = 'bad_phone', 'SIM-BUYER-27: short number: ' || r::text;
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Ana', '(212) 555-0177', NULL, 0, NULL, true);   -- a stranger's
  ASSERT (r->>'ok')::boolean, 'SIM-BUYER-27: a valid but wrong number gets a code (to the stranger)';
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Ana', '(212) 555-0176', NULL, 0, NULL, true);   -- the right one
  ASSERT (r->>'ok')::boolean, 'SIM-BUYER-27: retry with the right number';
  INSERT INTO simb VALUES ('rsvp27', r->>'rsvp_id'), ('code27', r->>'code');
  -- SIM-ORG-14 (mig 20261105100000): an email typed as the name is refused
  v := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'ana@sim-b.test', '(212) 555-0176', NULL, 0, NULL, true);
  ASSERT v->>'error' = 'name_is_email', 'SIM-BUYER-27: name is an email: ' || v::text;
  RAISE NOTICE 'OK SIM-BUYER-27 phone RSVP wrong number: malformed refused; a wrong real number just gets a code the guest never sees; an email as the name is refused';

  -- SIM-BUYER-28 five wrong codes, then the right one
  code := r->>'code';
  wrong := CASE WHEN code = '000000' THEN '111111' ELSE '000000' END;
  FOR i IN 1..4 LOOP
    v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, wrong, 'https://exos.test');
    ASSERT v->>'error' = 'wrong_code' AND (v->>'attempts_left')::int = 5 - i, 'SIM-BUYER-28: wrong ' || i || ': ' || v::text;
  END LOOP;
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, wrong, 'https://exos.test');
  ASSERT v->>'error' = 'locked', 'SIM-BUYER-28: fifth miss locks: ' || v::text;
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, code, 'https://exos.test');
  ASSERT v->>'error' = 'locked', 'SIM-BUYER-28: the right code after the lock is refused: ' || v::text;
  -- a new code works
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Ana', '(212) 555-0176', NULL, 1, NULL, true);
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, ' ' || (r->>'code') || ' ', 'https://exos.test');
  ASSERT (v->>'ok')::boolean AND jsonb_array_length(v->'tickets') = 2, 'SIM-BUYER-28: new code (with spaces) confirms Ana +1: ' || v::text;
  INSERT INTO simb VALUES ('rsvp_ticket', v->'tickets'->0->>'id'), ('rsvp_url', v->'tickets'->0->>'url');
  RAISE NOTICE 'OK SIM-BUYER-28 five wrong OTPs lock that code (even the right one); a fresh code works';

  -- SIM-BUYER-29 the code expired
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Bo', '(212) 555-0175', NULL, 0, NULL, true);
  UPDATE public.exos_phone_rsvps SET code_expires_at = now() - interval '1 second' WHERE id = (r->>'rsvp_id')::uuid;
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, r->>'code', 'https://exos.test');
  ASSERT v->>'error' = 'expired', 'SIM-BUYER-29: expired: ' || v::text;
  RAISE NOTICE 'OK SIM-BUYER-29 expired OTP: "expired", ask for a new one';

  -- SIM-BUYER-30 too many plus-ones
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Cy', '(212) 555-0174', NULL, 3, NULL, true);
  ASSERT r->>'error' = 'too_many_guests' AND (r->>'max_plus_ones')::int = 1, 'SIM-BUYER-30: ' || r::text;
  RAISE NOTICE 'OK SIM-BUYER-30 plus-ones over the limit: refused with the limit';

  -- SIM-BUYER-31 at capacity: 1 seat left (Ana +1 took 2 of 3)
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Di', '(212) 555-0173', NULL, 1, NULL, true);
  -- Was KNOWN ("sold_out" when Di could come alone): now says how many are left.
  ASSERT r->>'error' = 'not_enough_seats' AND (r->>'seats_left')::int = 1, 'SIM-BUYER-31: ' || r::text;
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Di', '(212) 555-0173', NULL, 0, NULL, true);
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, r->>'code', 'https://exos.test');
  ASSERT (v->>'ok')::boolean, 'SIM-BUYER-31: alone fits';
  r := public.exos_phone_rsvp_start(pg_temp.u('0000000000e5'), 'Ed', '(212) 555-0172', NULL, 0, NULL, true);
  ASSERT r->>'error' = 'sold_out', 'SIM-BUYER-31: full: ' || r::text;
  RAISE NOTICE 'OK SIM-BUYER-31 RSVP plus-one at the last seat: not_enough_seats with seats_left 1; alone fits; then sold_out, never over capacity';
END $$;
RESET ROLE;
DO $$
DECLARE t uuid := (SELECT v::uuid FROM simb WHERE k = 'rsvp_ticket'); url text := (SELECT v FROM simb WHERE k = 'rsvp_url'); key text; j jsonb;
BEGIN
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id = pg_temp.u('0000000000e5')) = 3
     AND (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d5')) = 3, 'SIM-BUYER-31: exactly 3';
  -- SIM-BUYER-32 claims the RSVP ticket into an account with a different email
  key := substring(url from '[?&#]k=([A-Za-z0-9_-]{43})');
  IF key IS NULL THEN key := substring(url from '([A-Za-z0-9_-]{43})$'); END IF;
  ASSERT key IS NOT NULL, 'SIM-BUYER-32: link key in ' || coalesce(url, 'null');
  PERFORM pg_temp.act(pg_temp.u('0000000000b7')::text);    -- unconfirmed account
  BEGIN
    PERFORM public.exos_phone_rsvp_claim(t, key);
    RAISE EXCEPTION 'SIM-BUYER-32: unconfirmed claimed';
  EXCEPTION WHEN insufficient_privilege THEN
    ASSERT SQLERRM LIKE 'Confirm your email first%', 'SIM-BUYER-32: ' || SQLERRM;
  END;
  PERFORM pg_temp.act(pg_temp.u('0000000000b4')::text);
  j := public.exos_phone_rsvp_claim(t, key);
  ASSERT (j->>'ok')::boolean AND (SELECT owner_id || ':' || buyer_email FROM public.exos_tickets WHERE id = t) = pg_temp.u('0000000000b4') || ':b4@sim-b.test',
         'SIM-BUYER-32: claimed into b4: ' || j::text;
  PERFORM pg_temp.act(pg_temp.u('0000000000b5')::text);
  j := public.exos_phone_rsvp_claim(t, key);
  ASSERT j->>'error' = 'not_found', 'SIM-BUYER-32: the link is spent after the claim (secret rotated): ' || j::text;
  RAISE NOTICE 'OK SIM-BUYER-32 RSVP ticket claimed into a different-email account (intended: links are bearer); the link then dies';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-33 Buys a membership, gets it refunded, then tries the member
-- presale; and a member whose membership is refunded mid-checkout.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_membership_products (id, org_id, name, price_cents, billing, discount_percent, presale)
VALUES ('be000000-0000-0000-0000-00000000aa01', 'be000000-0000-0000-0000-000000000001', 'Sim Member', 1000, 'once', 10, true);
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency) VALUES
  ('cs_simb_33m', 'be000000-0000-0000-0000-000000000001', 'membership', 'be000000-0000-0000-0000-00000000aa01',
   'be000000-0000-0000-0000-0000000000b4', 'b4@sim-b.test', 1000, 'usd'),
  ('cs_simb_33n', 'be000000-0000-0000-0000-000000000001', 'membership', 'be000000-0000-0000-0000-00000000aa01',
   'be000000-0000-0000-0000-0000000000b5', 'b5@sim-b.test', 1000, 'usd');
DO $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  PERFORM public.exos_set_member_presale(pg_temp.u('0000000000e1'), NULL, now() + interval '1 day', '{}'::uuid[], '{}'::uuid[]);
END $$;
SET ROLE service_role;
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT public.exos_commerce_fulfill('cs_simb_33m', 'pi_simb_33m', 1000) = 'fulfilled', 'SIM-BUYER-33: b4 member';
  ASSERT public.exos_commerce_fulfill('cs_simb_33n', 'pi_simb_33n', 1000) = 'fulfilled', 'SIM-BUYER-33: b5 member';
  r := public.exos_member_checkout(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b4'));
  ASSERT NOT (r->>'presale_blocked')::boolean, 'SIM-BUYER-33: member in';
  ASSERT public.exos_commerce_refund('cs_simb_33m', 'buyer asked') = 'refunded', 'SIM-BUYER-33: refunded';
  r := public.exos_member_checkout(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b4'));
  ASSERT (r->>'presale_blocked')::boolean, 'SIM-BUYER-33: refunded member is out of the presale: ' || r::text;
  -- a late "subscription updated / invoice paid" can't bring it back
  PERFORM public.exos_membership_sync('sub_none', 'invoice_paid', 'active', now() + interval '1 month');
  r := public.exos_member_checkout(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b4'));
  ASSERT (r->>'presale_blocked')::boolean, 'SIM-BUYER-33: still out';
END $$;
RESET ROLE;
DO $$
DECLARE h uuid; ids uuid[];
BEGIN
  -- b5 starts checkout as a member; the membership is refunded before the
  -- payment webhook lands: the order fails (refund) and the mail says why.
  PERFORM pg_temp.act(pg_temp.u('0000000000b5')::text);
  h := public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1);
  PERFORM pg_temp.sess('cs_simb_33p', '0000000000e1', '0000000000d1', '0000000000b5', 'b5@sim-b.test', 1, 1800, h);
  PERFORM public.exos_commerce_refund('cs_simb_33n', 'chargeback');
  ids := pg_temp.paid('cs_simb_33p');
  ASSERT cardinality(ids) = 0 AND (SELECT failure_reason FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_33p') LIKE '%presale%',
         'SIM-BUYER-33: fails at fulfilment';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'order-failed' AND to_email = 'b5@sim-b.test' AND html LIKE '%members-only presale%'),
         'SIM-BUYER-33: told it is the presale, not a sell-out';
  DELETE FROM public.exos_member_presales WHERE event_id = pg_temp.u('0000000000e1');
  RAISE NOTICE 'FIXED SIM-BUYER-33 refunded membership: out of the presale; a lapsed member''s paid order is refunded with the right reason';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-34 Starts a monthly donation, then the card fails (twice for the
-- same invoice: Stripe retries), then succeeds.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_giving_campaigns (id, org_id, name, slug, currency, active)
VALUES ('be000000-0000-0000-0000-00000000cc01', 'be000000-0000-0000-0000-000000000001', 'Sim Fund', 'sim-b-fund', 'usd', true);
INSERT INTO public.exos_recurring_donations (id, org_id, campaign_id, amount_cents, cover_fees_cents, currency, donor_uid, donor_email, donor_name)
VALUES ('be000000-0000-0000-0000-00000000cd01', 'be000000-0000-0000-0000-000000000001', 'be000000-0000-0000-0000-00000000cc01',
        1500, 0, 'usd', 'be000000-0000-0000-0000-0000000000b2', 'b2@sim-b.test', 'Bee');
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency, details, stripe_customer_id)
VALUES ('cs_simb_34', 'be000000-0000-0000-0000-000000000001', 'recurring_donation', 'be000000-0000-0000-0000-00000000cc01',
        'be000000-0000-0000-0000-0000000000b2', 'b2@sim-b.test', 1500, 'usd',
        '{"recurring_id": "be000000-0000-0000-0000-00000000cd01"}', 'cus_simb');
SET ROLE service_role;
DO $$
DECLARE s text; rid uuid := 'be000000-0000-0000-0000-00000000cd01';
BEGIN
  ASSERT public.exos_commerce_fulfill('cs_simb_34', 'pi_simb_34a', 1500, 'sub_simb', now() + interval '1 month') = 'fulfilled', 'SIM-BUYER-34: started';
  s := public.exos_recurring_donation_invoice(rid, 'sub_simb', 'cus_simb', 'in_simb_1', 'pi_simb_34a', 1500, 'usd', now() + interval '1 month', 'paid');
  ASSERT (SELECT count(*) FROM public.exos_donations WHERE recurring_id = rid) = 1, 'SIM-BUYER-34: first gift recorded';
  s := public.exos_recurring_donation_invoice(NULL, 'sub_simb', NULL, 'in_simb_2', NULL, 1500, 'usd', NULL, 'failed', 'evt_simb_f1', 'card_declined');
  s := public.exos_recurring_donation_invoice(NULL, 'sub_simb', NULL, 'in_simb_2', NULL, 1500, 'usd', NULL, 'failed', 'evt_simb_f1', 'card_declined');
  ASSERT (SELECT status || ':' || failed_payments FROM public.exos_recurring_donations WHERE id = rid) = 'past_due:1', 'SIM-BUYER-34: past due, counted once';
  ASSERT (SELECT count(*) FROM public.exos_donations WHERE recurring_id = rid) = 1, 'SIM-BUYER-34: no gift recorded for a failed charge';
  s := public.exos_recurring_donation_invoice(NULL, 'sub_simb', NULL, 'in_simb_2', 'pi_simb_34b', 1500, 'usd', now() + interval '2 months', 'paid');
  ASSERT (SELECT status || ':' || failed_payments FROM public.exos_recurring_donations WHERE id = rid) = 'active:0', 'SIM-BUYER-34: card fixed -> active';
  ASSERT (SELECT count(*) FROM public.exos_donations WHERE recurring_id = rid) = 2, 'SIM-BUYER-34: second gift';
END $$;
RESET ROLE;
DO $$
BEGIN
  -- Was KNOWN (Exos never told the donor). Now one "update your card" mail
  -- per failure streak: the retried failure above counted once, so one mail.
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE to_email = 'b2@sim-b.test' AND html LIKE '%update your card%') = 1,
         'SIM-BUYER-34: one mail for the first streak';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'b2@sim-b.test' AND html LIKE '%update_card=be000000-0000-0000-0000-00000000cd01%'),
         'SIM-BUYER-34: the mail links to the card update';
END $$;
SET ROLE service_role;
DO $$
DECLARE s text; rid uuid := 'be000000-0000-0000-0000-00000000cd01';
BEGIN
  -- a new streak: fails, fails again (Stripe's next retry), then paid
  s := public.exos_recurring_donation_invoice(NULL, 'sub_simb', NULL, 'in_simb_3', NULL, 1500, 'usd', NULL, 'failed', 'evt_simb_f2', 'card_declined');
  s := public.exos_recurring_donation_invoice(NULL, 'sub_simb', NULL, 'in_simb_3', NULL, 1500, 'usd', NULL, 'failed', 'evt_simb_f3', 'card_declined');
  ASSERT (SELECT failed_payments FROM public.exos_recurring_donations WHERE id = rid) = 2, 'SIM-BUYER-34: two failures in the streak';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE to_email = 'b2@sim-b.test' AND html LIKE '%update your card%') = 2,
         'SIM-BUYER-34: one more mail for the second streak, not one per failure';
  RAISE NOTICE 'OK SIM-BUYER-34 monthly donation card fails: past_due, ledger right, one "update your card" mail per failure streak';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-BUYER-13b The typo-owner's confirmed account (typo-owner@, b6) and the
-- guest order's paper trail (mig 20261105100000). An order's email makes its
-- owner the payer only once that email is proven: before, b6 sees no
-- receipt, can't ask for a refund and gets no reschedule offer for the
-- stranger's order (cs_simb_13, proven by phone, so the email never was);
-- for an order proven to b6's email (cs_simb_13b) b6 sees all three.
-- ---------------------------------------------------------------------------
DO $$
DECLARE ids uuid[]; t13 uuid; t13b uuid; j jsonb; inv13 uuid; inv13b uuid;
BEGIN
  t13 := (SELECT ticket_ids[1] FROM public.exos_checkout_sessions WHERE session_id = 'cs_simb_13');
  ids := pg_temp.gsess('cs_simb_13b', 'typo-owner@sim-b.test');   -- a second guest order with that email, still unproven
  t13b := ids[1];
  SELECT id INTO inv13 FROM public.exos_invoices WHERE session_id = 'cs_simb_13';
  SELECT id INTO inv13b FROM public.exos_invoices WHERE session_id = 'cs_simb_13b';
  ASSERT inv13 IS NOT NULL AND inv13b IS NOT NULL, 'SIM-BUYER-13b: both orders have a receipt';
  PERFORM pg_temp.act(pg_temp.u('0000000000a0')::text);
  PERFORM public.exos_reschedule_event(pg_temp.u('0000000000e1'), now() + interval '20 days', p_offer_refunds => true);

  -- Unproven (13b pending, 13 proven by phone only): nothing for b6.
  PERFORM pg_temp.act(pg_temp.u('0000000000b6')::text);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_my_invoices() x WHERE x.session_id IN ('cs_simb_13', 'cs_simb_13b')), 'SIM-BUYER-13b: no receipt in the list';
  ASSERT pg_temp.err(format('SELECT public.exos_invoice_document(%L::uuid)', inv13b)) LIKE '%not found%', 'SIM-BUYER-13b: the receipt itself is not found';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_my_refund_asks(pg_temp.u('0000000000e1')) x WHERE x.ticket_id IN (t13, t13b)),
         'SIM-BUYER-13b: no refund ask listed';
  j := public.exos_ask_refund(ARRAY[t13b]);
  ASSERT j->0->>'reason' = 'not-buyer', 'SIM-BUYER-13b: a refund ask is refused: ' || j::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_refund_asks WHERE session_id IN ('cs_simb_13', 'cs_simb_13b')), 'SIM-BUYER-13b: no ask recorded';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_my_reschedule_offers() x WHERE x.ticket_id IN (t13, t13b)), 'SIM-BUYER-13b: no reschedule offer';

  -- 13b proven to b6's email (it was theirs after all): all three appear.
  PERFORM pg_temp.act(NULL);
  ASSERT (public.exos_order_proof_verify('cs_simb_13b', pg_temp.tok('cs_simb_13b'), (SELECT substring(html from 'letter-spacing:6px"><strong>([0-9]{6})</strong>') FROM public.exos_mail
             WHERE template = 'rsvp-code' AND html LIKE '%confirm=cs_simb_13b&amp;%' LIMIT 1)) ->> 'ok')::boolean,
         'SIM-BUYER-13b: proven by the mailed code (that order''s mail)';
  PERFORM pg_temp.act(pg_temp.u('0000000000b6')::text);
  ASSERT EXISTS (SELECT 1 FROM public.exos_my_invoices() x WHERE x.session_id = 'cs_simb_13b')
     AND NOT EXISTS (SELECT 1 FROM public.exos_my_invoices() x WHERE x.session_id = 'cs_simb_13'), 'SIM-BUYER-13b: the proven order''s receipt, only';
  ASSERT public.exos_invoice_document(inv13b) IS NOT NULL, 'SIM-BUYER-13b: the receipt opens';
  ASSERT (SELECT x.reason FROM public.exos_my_refund_asks(pg_temp.u('0000000000e1')) x WHERE x.ticket_id = t13b) IS DISTINCT FROM 'not-buyer'
     AND EXISTS (SELECT 1 FROM public.exos_my_refund_asks(pg_temp.u('0000000000e1')) x WHERE x.ticket_id = t13b), 'SIM-BUYER-13b: the refund ask is theirs';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_my_refund_asks(pg_temp.u('0000000000e1')) x WHERE x.ticket_id = t13), 'SIM-BUYER-13b: not the phone-proven one';
  ASSERT EXISTS (SELECT 1 FROM public.exos_my_reschedule_offers() x WHERE x.ticket_id = t13b AND x.reason IS DISTINCT FROM 'not-buyer'),
         'SIM-BUYER-13b: the reschedule offer is theirs';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_my_reschedule_offers() x WHERE x.ticket_id = t13), 'SIM-BUYER-13b: not for the phone-proven one';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SIM-BUYER-13b a typo-owner''s account gets no receipt, refund ask or reschedule offer for an unproven guest order; once proven to their email, all three';
END $$;

ROLLBACK;
