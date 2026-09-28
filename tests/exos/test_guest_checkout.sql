-- ============================================================================
-- Guest checkout (mig 20260928050000). Runs in run_p0.sh after the platform
-- suites; fixtures use their own ids (9c…).
--   G1 a guest hold, one live cart per email per event
--   G2 bad email, guestCheckout=false, and non-service callers are refused
--   G3 five guest holds per network per 10 minutes
--   G4 live guest holds reserve at most a quarter of what's left (>= 10)
--   G5 maxPerAccount counts per email (bought with it + its account's tickets)
--   G6 no account: parked on the org owner, claim links mailed, add-ons follow the claim
--   G7 a confirmed account with that email gets the tickets directly
--   G8 an unconfirmed account with that email doesn't: parked
--   G9 a session without a buyer must be a guest session with an email
--   G10 the per-email limit is re-checked at fulfilment
--   G11 signed-in fulfilment is unchanged
--   G12 a signed-in stranger can't release a guest's hold
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('9c000000-0000-0000-0000-0000000000a0','9c-owner@x.com',now()),
  ('9c000000-0000-0000-0000-0000000000b1','9c-member@x.com',now()),
  ('9c000000-0000-0000-0000-0000000000b2','9c-unconfirmed@x.com',NULL),
  ('9c000000-0000-0000-0000-0000000000b3','9c-claimer@x.com',now()),
  ('9c000000-0000-0000-0000-0000000000b4','9c-signedin@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('9c000000-0000-0000-0000-000000000001','9C Org','9c-org','9c000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-0000000000a0','owner');
-- e1 open; e2 guest checkout off; e3 small (ceiling); e4 maxPerAccount 2
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold,purchase_limits) VALUES
  ('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-000000000001','9C <Show>','9c-show','published',0,0,NULL),
  ('9c000000-0000-0000-0000-0000000000e2','9c000000-0000-0000-0000-000000000001','9C Drop','9c-drop','published',0,0,'{"guestCheckout":false}'),
  ('9c000000-0000-0000-0000-0000000000e3','9c000000-0000-0000-0000-000000000001','9C Small','9c-small','published',0,0,NULL),
  ('9c000000-0000-0000-0000-0000000000e4','9c000000-0000-0000-0000-000000000001','9C Capped','9c-capped','published',0,0,'{"maxPerAccount":2}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('9c000000-0000-0000-0000-0000000000d1','9c000000-0000-0000-0000-0000000000e1','GA',20,500,0),
  ('9c000000-0000-0000-0000-0000000000d2','9c000000-0000-0000-0000-0000000000e2','GA',20,500,0),
  ('9c000000-0000-0000-0000-0000000000d3','9c000000-0000-0000-0000-0000000000e3','GA',20,20,0),
  ('9c000000-0000-0000-0000-0000000000d4','9c000000-0000-0000-0000-0000000000e4','GA',20,100,0);
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity,sold) VALUES
  ('9c000000-0000-0000-0000-0000000000a1','9c000000-0000-0000-0000-0000000000e1','Poster',10,0,0);

CREATE OR REPLACE FUNCTION pg_temp.hold_err(p_event uuid, p_tier uuid, p_qty int, p_email text, p_ip text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.exos_create_guest_hold(p_event, p_tier, p_qty, p_email, p_ip);
  RETURN NULL;
EXCEPTION WHEN others THEN RETURN SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.guest_session(p_id text, p_event uuid, p_tier uuid, p_qty int,
                                                 p_email text, p_addons jsonb) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,guest,
                                           quantity,amount_cents,status,addons)
  VALUES (p_id,p_event,p_tier,'9c000000-0000-0000-0000-000000000001',NULL,p_email,true,
          p_qty,2000*p_qty,'pending',p_addons);
$$;

-- G1 -------------------------------------------------------------------------
DO $$
DECLARE h1 uuid; h2 uuid; r record;
BEGIN
  h1 := public.exos_create_guest_hold('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',2,'  Fan@X.com ','ip-g1');
  SELECT * INTO r FROM public.exos_cart_holds WHERE id = h1;
  ASSERT r.buyer_uid IS NULL AND r.buyer_email = 'fan@x.com' AND r.ip_hash = 'ip-g1' AND r.status = 'active',
    'G1: guest hold is unowned, email normalised, network hash kept';
  ASSERT r.expires_at <= now() + interval '30 minutes', 'G1: 30-minute TTL';
  h2 := public.exos_create_guest_hold('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'fan@x.com','ip-g1b');
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = h1) = 'released', 'G1: a new cart replaces the old one';
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = h2) = 'active', 'G1: new cart is live';
  RAISE NOTICE 'OK  G1 guest hold; one live cart per email per event';
END $$;

-- G2 -------------------------------------------------------------------------
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'not-an-email','ip-g2');
  ASSERT e LIKE '%valid email%', 'G2: bad email refused, got ' || coalesce(e, 'ok');
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e2','9c000000-0000-0000-0000-0000000000d2',1,'g2@x.com','ip-g2');
  ASSERT e LIKE '%sign in to buy%', 'G2: guestCheckout=false refused, got ' || coalesce(e, 'ok');
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.exos_create_guest_hold('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'g2@x.com','ip-g2');
    RAISE EXCEPTION 'G2: authenticated must not create guest holds';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  RESET ROLE;
  RAISE NOTICE 'OK  G2 bad email, organizer opt-out and non-service callers refused';
END $$;

-- G3 -------------------------------------------------------------------------
DO $$
DECLARE e text;
BEGIN
  FOR i IN 1..5 LOOP
    e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'g3-' || i || '@x.com','ip-g3');
    ASSERT e IS NULL, 'G3: hold ' || i || ' from one network is fine, got ' || coalesce(e, '');
  END LOOP;
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'g3-6@x.com','ip-g3');
  ASSERT e LIKE '%too many checkouts%', 'G3: sixth hold from one network refused, got ' || coalesce(e, 'ok');
  UPDATE public.exos_cart_holds SET created_at = now() - interval '11 minutes' WHERE ip_hash = 'ip-g3';
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'g3-6@x.com','ip-g3');
  ASSERT e IS NULL, 'G3: the window slides, got ' || coalesce(e, '');
  RAISE NOTICE 'OK  G3 five guest holds per network per 10 minutes';
END $$;

-- G4: 20 seats → ceiling max(10, 20/4) = 10 live guest seats ------------------
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e3','9c000000-0000-0000-0000-0000000000d3',6,'g4a@x.com','ip-g4a');
  ASSERT e IS NULL, 'G4: first 6 fine, got ' || coalesce(e, '');
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e3','9c000000-0000-0000-0000-0000000000d3',4,'g4b@x.com','ip-g4b');
  ASSERT e IS NULL, 'G4: up to 10 fine, got ' || coalesce(e, '');
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e3','9c000000-0000-0000-0000-0000000000d3',1,'g4c@x.com','ip-g4c');
  ASSERT e LIKE '%busy right now%', 'G4: 11th guest seat refused, got ' || coalesce(e, 'ok');
  -- The same buyer replacing their cart doesn't count against itself twice.
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e3','9c000000-0000-0000-0000-0000000000d3',6,'g4a@x.com','ip-g4d');
  ASSERT e IS NULL, 'G4: replacing a cart is fine, got ' || coalesce(e, '');
  RAISE NOTICE 'OK  G4 live guest holds capped at a quarter of what is left (>= 10)';
END $$;

-- G5 -------------------------------------------------------------------------
DO $$
DECLARE e text;
BEGIN
  -- One ticket bought with the email before, one owned by the member's account.
  INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
  VALUES ('9c000000-0000-0000-0000-0000000000e4','9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-0000000000d4',
          '9c000000-0000-0000-0000-0000000000a0','9c000000-0000-0000-0000-0000000000a0','g5@x.com','active','s1',20,'g5-prior','stripe'),
         ('9c000000-0000-0000-0000-0000000000e4','9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-0000000000d4',
          '9c000000-0000-0000-0000-0000000000b1','9c000000-0000-0000-0000-0000000000b1','other@x.com','active','s2',20,'g5-prior2','stripe');
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e4','9c000000-0000-0000-0000-0000000000d4',2,'G5@x.com','ip-g5');
  ASSERT e LIKE '%max per account%', 'G5: email already bought 1 of 2, got ' || coalesce(e, 'ok');
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e4','9c000000-0000-0000-0000-0000000000d4',1,'g5@x.com','ip-g5');
  ASSERT e IS NULL, 'G5: one more is fine, got ' || coalesce(e, '');
  e := pg_temp.hold_err('9c000000-0000-0000-0000-0000000000e4','9c000000-0000-0000-0000-0000000000d4',2,'9c-member@x.com','ip-g5b');
  ASSERT e LIKE '%max per account%', 'G5: the account''s own ticket counts, got ' || coalesce(e, 'ok');
  RAISE NOTICE 'OK  G5 maxPerAccount counts per email';
END $$;

-- G6 -------------------------------------------------------------------------
DO $$
DECLARE ids uuid[]; t record; n int; m record; tr uuid;
BEGIN
  PERFORM pg_temp.guest_session('9c-g6','9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',2,'newfan@x.com',
    '[{"addon_id":"9c000000-0000-0000-0000-0000000000a1","quantity":1,"unit_price_cents":1000,"name":"Poster"}]');
  ids := public.exos_fulfill_checkout('9c-g6');
  ASSERT array_length(ids,1) = 2, 'G6: two tickets minted';
  SELECT count(*) INTO n FROM public.exos_tickets
   WHERE id = ANY(ids) AND owner_id = '9c000000-0000-0000-0000-0000000000a0' AND buyer_email = 'newfan@x.com'
     AND pending_transfer_id IS NOT NULL;
  ASSERT n = 2, 'G6: parked on the org owner with a pending transfer each';
  SELECT count(*) INTO n FROM public.exos_transfers
   WHERE ticket_id = ANY(ids) AND status = 'pending' AND receiver_email = 'newfan@x.com';
  ASSERT n = 2, 'G6: one pending transfer per ticket to the guest email';
  SELECT * INTO m FROM public.exos_mail WHERE to_email = 'newfan@x.com' ORDER BY created_at DESC LIMIT 1;
  ASSERT m.template = 'transfer-initiated', 'G6: claim mail, got ' || coalesce(m.template, 'none');
  ASSERT m.html LIKE '%{{app_url}}/claim/%' AND m.html LIKE '%Claim ticket 2%', 'G6: a claim link per ticket';
  ASSERT m.html LIKE '%9C &lt;Show&gt;%', 'G6: event name escaped';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'newfan@x.com' AND template = 'ticket-issued'),
    'G6: no "in your wallet" mail for a parked order';
  ASSERT (SELECT owner_id FROM public.exos_order_addons WHERE order_ref = '9c-g6') IS NULL, 'G6: add-on unowned until claimed';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = '9c-g6') = 'fulfilled', 'G6: session fulfilled';

  -- Claim one ticket into a fresh account: the add-on follows it.
  SELECT pending_transfer_id INTO tr FROM public.exos_tickets WHERE id = ids[1];
  PERFORM set_config('app.uid', '9c000000-0000-0000-0000-0000000000b3', true);
  PERFORM set_config('app.jwt', '{"email":"9c-claimer@x.com"}', true);
  PERFORM public.exos_test_claim(tr);
  PERFORM set_config('app.uid', '', true);
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = '9c000000-0000-0000-0000-0000000000b3', 'G6: claimed';
  ASSERT (SELECT owner_id FROM public.exos_order_addons WHERE order_ref = '9c-g6') = '9c000000-0000-0000-0000-0000000000b3',
    'G6: add-on follows the first claimed ticket';
  ASSERT public.exos_fulfill_checkout('9c-g6') = ids, 'G6: re-fulfilment is idempotent';
  RAISE NOTICE 'OK  G6 guest without an account: parked, claim links mailed, add-ons follow';
END $$;

-- G7 -------------------------------------------------------------------------
DO $$
DECLARE ids uuid[]; n int;
BEGIN
  PERFORM pg_temp.guest_session('9c-g7','9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'9C-Member@x.com',NULL);
  ids := public.exos_fulfill_checkout('9c-g7');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = '9c000000-0000-0000-0000-0000000000b1', 'G7: into the account';
  ASSERT (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = ids[1]) IS NULL, 'G7: no transfer';
  SELECT count(*) INTO n FROM public.exos_mail WHERE to_email = '9c-member@x.com' AND template = 'ticket-issued'
     AND html LIKE '%Sign in to Exos with this email%';
  ASSERT n = 1, 'G7: wallet mail tells a guest to sign in with the email';
  RAISE NOTICE 'OK  G7 confirmed account with that email gets the tickets directly';
END $$;

-- G8 -------------------------------------------------------------------------
DO $$
DECLARE ids uuid[];
BEGIN
  PERFORM pg_temp.guest_session('9c-g8','9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'9c-unconfirmed@x.com',NULL);
  ids := public.exos_fulfill_checkout('9c-g8');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = '9c000000-0000-0000-0000-0000000000a0',
    'G8: an unconfirmed account with the email does not get the ticket';
  ASSERT (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = ids[1]) IS NOT NULL, 'G8: parked with a claim';
  RAISE NOTICE 'OK  G8 unconfirmed account with that email: parked';
END $$;

-- G9 -------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status)
    VALUES ('9c-g9','9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',
            '9c000000-0000-0000-0000-000000000001',NULL,'g9@x.com',1,2000,'pending');
    RAISE EXCEPTION 'G9: a buyerless non-guest session must be refused';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM pg_temp.guest_session('9c-g9b','9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'',NULL);
    RAISE EXCEPTION 'G9: a guest session needs an email';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  G9 buyerless sessions must be guest sessions with an email';
END $$;

-- G10: two paid guest orders race past the hold; fulfilment re-checks --------
DO $$
DECLARE a uuid[]; b uuid[]; why text;
BEGIN
  PERFORM pg_temp.guest_session('9c-g10a','9c000000-0000-0000-0000-0000000000e4','9c000000-0000-0000-0000-0000000000d4',1,'g10@x.com',NULL);
  PERFORM pg_temp.guest_session('9c-g10b','9c000000-0000-0000-0000-0000000000e4','9c000000-0000-0000-0000-0000000000d4',2,'g10@x.com',NULL);
  a := public.exos_fulfill_checkout('9c-g10a');
  b := public.exos_fulfill_checkout('9c-g10b');
  SELECT failure_reason INTO why FROM public.exos_checkout_sessions WHERE session_id = '9c-g10b';
  ASSERT array_length(a,1) = 1 AND coalesce(array_length(b,1),0) = 0, 'G10: the second order must not fulfill';
  ASSERT why LIKE '%purchase limit%', 'G10: failed on the limit, got ' || coalesce(why, 'null');
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'g10@x.com' AND template = 'order-failed'), 'G10: refund mail';
  RAISE NOTICE 'OK  G10 the per-email limit is re-checked at fulfilment';
END $$;

-- G11 ------------------------------------------------------------------------
DO $$
DECLARE ids uuid[];
BEGIN
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status)
  VALUES ('9c-g11','9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',
          '9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-0000000000b4','9c-signedin@x.com',1,2000,'pending');
  ids := public.exos_fulfill_checkout('9c-g11');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = '9c000000-0000-0000-0000-0000000000b4', 'G11: owner is the buyer';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = '9c-signedin@x.com' AND template = 'ticket-issued'
                   AND html LIKE '%Open the app to show your QR%'), 'G11: signed-in wallet mail unchanged';
  ASSERT NOT (SELECT guest FROM public.exos_checkout_sessions WHERE session_id = '9c-g11'), 'G11: guest defaults false';
  RAISE NOTICE 'OK  G11 signed-in fulfilment unchanged';
END $$;

-- G12 ------------------------------------------------------------------------
DO $$
DECLARE h uuid; refused boolean := false;
BEGIN
  h := public.exos_create_guest_hold('9c000000-0000-0000-0000-0000000000e1','9c000000-0000-0000-0000-0000000000d1',1,'g12@x.com','ip-g12');
  PERFORM set_config('app.uid', '9c000000-0000-0000-0000-0000000000b4', true);
  PERFORM set_config('app.jwt', '{"email":"9c-signedin@x.com"}', true);
  BEGIN
    PERFORM public.exos_release_hold(h);
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'G12: a stranger must not release a guest hold';
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = h) = 'active', 'G12: hold still live';
  PERFORM set_config('app.uid', '9c000000-0000-0000-0000-0000000000a0', true);
  PERFORM set_config('app.jwt', '{"email":"9c-owner@x.com"}', true);
  ASSERT public.exos_release_hold(h), 'G12: the org owner can';
  PERFORM set_config('app.uid', '', true);
  RAISE NOTICE 'OK  G12 a signed-in stranger cannot release a guest hold';
END $$;
