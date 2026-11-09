-- ============================================================================
-- Group buy v2, "pay separately" (mig 20261108120000). Self-contained (c7e
-- prefix), rolled back. Races: race_group_pay.sh (by hand, real sessions).
--   G1  who may call what: anon reads a seat by its token only; the claim /
--       attach / unclaim / context calls are service role only; RLS
--   G2  start: N one-seat holds through exos_create_hold, ending at the
--       deadline; the type / event / size rules; one open group per event
--   G3  the holds: a checkout page's grace never takes them past the
--       deadline; nobody else's release (the host's new cart, a failed
--       checkout, an expired page) sends a seat back to sale early
--   G4  a friend pays their seat: claim, attach, fulfil; the ticket is the
--       friend's, its own order; the seat is paid
--   G5  the same seat twice: the second friend gets "seat already taken";
--       the same friend may start over (their old checkout can't be issued)
--   G6  a failed checkout gives the seat back to the group; a stale claim
--       (no checkout after 5 minutes, or a failed / expired one) stops counting
--   G7  cover the rest: every unpaid seat in one order, minted to the host; a
--       friend's earlier checkout on a covered seat fails (refunded)
--   G8  deadline: no claim, no fulfilment after it (late payment fails and is
--       refunded); the expiry sweep releases the seats; back on sale
--   G9  per-seat orders: refunding one order leaves the others alone
--   G10 cross-group and cross-org refusal (tokens, sessions, hosts)
--   G11 cancel: unpaid seats back on sale at once
--   G12 the public seat read leaks nothing about other friends
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c7e00000-0000-0000-0000-0000000000a0','c7-owner@x.com',now()),
  ('c7e00000-0000-0000-0000-0000000000a1','c7-finance@x.com',now()),
  ('c7e00000-0000-0000-0000-0000000000b0','c7-host@x.com',now()),
  ('c7e00000-0000-0000-0000-0000000000b1','c7-f1@x.com',now()),
  ('c7e00000-0000-0000-0000-0000000000b2','c7-f2@x.com',now()),
  ('c7e00000-0000-0000-0000-0000000000b3','c7-f3@x.com',now()),
  ('c7e00000-0000-0000-0000-0000000000b9','c7-unconfirmed@x.com',NULL),
  ('c7e00000-0000-0000-0000-0000000000c0','c7-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c7e00000-0000-0000-0000-000000000001','C7 Org','c7-org','c7e00000-0000-0000-0000-0000000000a0'),
  ('c7e00000-0000-0000-0000-000000000002','C7 Other','c7-other','c7e00000-0000-0000-0000-0000000000c0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('c7e00000-0000-0000-0000-000000000001','c7e00000-0000-0000-0000-0000000000a0','owner',false),
  ('c7e00000-0000-0000-0000-000000000001','c7e00000-0000-0000-0000-0000000000a1','finance',false),
  ('c7e00000-0000-0000-0000-000000000002','c7e00000-0000-0000-0000-0000000000c0','owner',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold,purchase_limits) VALUES
  ('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-000000000001','C7 Show','c7-show','published',now() + interval '10 days','Hall',0,0,'{"maxPerOrder": 6}'),
  ('c7e00000-0000-0000-0000-0000000000e2','c7e00000-0000-0000-0000-000000000001','C7 Draft','c7-draft','draft',now() + interval '10 days','Hall',0,0,NULL),
  ('c7e00000-0000-0000-0000-0000000000e3','c7e00000-0000-0000-0000-000000000002','C7 Other Show','c7-oshow','published',now() + interval '10 days','Hall',0,0,NULL);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('c7e00000-0000-0000-0000-0000000000d1','c7e00000-0000-0000-0000-0000000000e1','GA',25,20,0),
  ('c7e00000-0000-0000-0000-0000000000d2','c7e00000-0000-0000-0000-0000000000e1','Free',0,20,0),
  ('c7e00000-0000-0000-0000-0000000000d3','c7e00000-0000-0000-0000-0000000000e1','Tight',25,3,0),
  ('c7e00000-0000-0000-0000-0000000000d4','c7e00000-0000-0000-0000-0000000000e1','Seated',25,20,0),
  ('c7e00000-0000-0000-0000-0000000000d5','c7e00000-0000-0000-0000-0000000000e1','Hidden',25,20,0),
  ('c7e00000-0000-0000-0000-0000000000d6','c7e00000-0000-0000-0000-0000000000e2','Draft GA',25,20,0),
  ('c7e00000-0000-0000-0000-0000000000d9','c7e00000-0000-0000-0000-0000000000e3','Other GA',25,20,0);
SELECT set_config('exos.seating_write', 'on', true);
UPDATE public.exos_ticket_tiers SET seated = true WHERE id = 'c7e00000-0000-0000-0000-0000000000d4';
SELECT set_config('exos.seating_write', '', true);
UPDATE public.exos_ticket_tiers SET visibility = 'hidden' WHERE id = 'c7e00000-0000-0000-0000-0000000000d5';

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
-- A checkout session as exos-checkout records it (one 25.00 seat each).
CREATE OR REPLACE FUNCTION pg_temp.sess(p_id text, p_buyer uuid, p_email text, p_qty int,
                                        p_tier uuid DEFAULT 'c7e00000-0000-0000-0000-0000000000d1',
                                        p_event uuid DEFAULT 'c7e00000-0000-0000-0000-0000000000e1',
                                        p_org uuid DEFAULT 'c7e00000-0000-0000-0000-000000000001') RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,guest,quantity,amount_cents,currency,status)
  VALUES (p_id,p_event,p_tier,p_org,p_buyer,p_email,p_buyer IS NULL,p_qty,2500*p_qty,'usd','pending');
$$;
CREATE OR REPLACE FUNCTION pg_temp.tok(p_group uuid, p_no int) RETURNS text LANGUAGE sql AS $$
  SELECT token FROM public.exos_group_buy_seats WHERE group_id = p_group AND seat_no = p_no;
$$;
CREATE OR REPLACE FUNCTION pg_temp.state(p_group uuid, p_no int) RETURNS text LANGUAGE sql AS $$
  SELECT public._exos_group_seat_state(id) FROM public.exos_group_buy_seats WHERE group_id = p_group AND seat_no = p_no;
$$;
CREATE TEMP TABLE g(k text PRIMARY KEY, id uuid);
GRANT ALL ON g TO PUBLIC;

-- ---------------------------------------------------------------------------
-- G1 grants
-- ---------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['exos_group_buy_start(uuid,uuid,integer)','exos_group_buy_get(uuid)',
                           'exos_group_buy_mine(uuid)','exos_group_buy_cancel(uuid)'] LOOP
    ASSERT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'), 'G1 authenticated may call ' || f;
    ASSERT NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'), 'G1 anon may not call ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['exos_group_checkout_ctx(text,uuid,uuid)','exos_group_claim(text,uuid,uuid,text,uuid,uuid,integer)',
                           'exos_group_attach(text,text,uuid)','exos_group_unclaim(text,uuid,uuid,text)',
                           '_exos_group_seat_state(uuid)','_exos_group_buy_json(uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'), 'G1 authenticated may not call ' || f;
    ASSERT NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'), 'G1 anon may not call ' || f;
    ASSERT has_function_privilege('service_role', 'public.' || f, 'EXECUTE'), 'G1 service role calls ' || f;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_group_seat_view(text)', 'EXECUTE'), 'G1 anon reads a seat';
  ASSERT NOT has_table_privilege('anon', 'public.exos_group_buys', 'SELECT'), 'G1 anon reads no group';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_group_buy_seats', 'INSERT'), 'G1 no client writes';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_group_buys'::regclass)
     AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_group_buy_seats'::regclass), 'G1 RLS on';
  RAISE NOTICE 'OK  G1 grants: seat read by token for anon, claim / attach / unclaim service role only';
END $$;

-- ---------------------------------------------------------------------------
-- G2 start
-- ---------------------------------------------------------------------------
SELECT pg_temp.as_user('c7e00000-0000-0000-0000-0000000000b0', 'c7-host@x.com');
DO $$
DECLARE r jsonb; v_g uuid; v_dead timestamptz;
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d1',1)$q$) LIKE '22023%2 to 10%', 'G2 one seat is no group';
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d1',7)$q$) LIKE '%at most 6%', 'G2 capped at maxPerOrder';
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d2',2)$q$) LIKE '%free tickets%', 'G2 free type refused';
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d4',2)$q$) LIKE '%isn''t available for this ticket type%', 'G2 seated type refused';
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d5',2)$q$) LIKE '%not available%', 'G2 hidden type refused';
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e2','c7e00000-0000-0000-0000-0000000000d6',2)$q$) LIKE '%not on sale%', 'G2 draft event refused';
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d3',4)$q$) LIKE '%not enough tickets%', 'G2 the normal hold''s capacity check';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_group_buys), 'G2 a refused start leaves nothing';

  r := public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d1',4);
  v_g := (r->>'id')::uuid;
  INSERT INTO g VALUES ('main', v_g);
  SELECT deadline INTO v_dead FROM public.exos_group_buys WHERE id = v_g;
  ASSERT v_dead BETWEEN now() + interval '29 minutes' AND now() + interval '30 minutes', 'G2 a 30-minute window';
  ASSERT jsonb_array_length(r->'seats') = 4 AND (r->'counts'->>'waiting')::int = 4, 'G2 four waiting seats';
  ASSERT (SELECT count(*) FROM public.exos_cart_holds h JOIN public.exos_group_buy_seats s ON s.hold_id = h.id
           WHERE s.group_id = v_g AND h.quantity = 1 AND h.status = 'active' AND h.group_seat_id = s.id
             AND h.expires_at = v_dead AND h.tier_id = 'c7e00000-0000-0000-0000-0000000000d1') = 4, 'G2 four one-seat holds ending at the deadline';
  ASSERT public.exos_tier_available('c7e00000-0000-0000-0000-0000000000d1') = 16, 'G2 the seats are off sale';
  ASSERT (SELECT bool_and(x->>'path' ~ '^/group-pay/seat/[0-9a-f]{32}$') FROM jsonb_array_elements(r->'seats') x), 'G2 one link per seat';
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d1',2)$q$) LIKE '23505%already have an open group%', 'G2 one open group per event';
  RAISE NOTICE 'OK  G2 start: N one-seat holds via exos_create_hold, 30-minute deadline, size / type / event rules';
END $$;
-- An unconfirmed account can't hold seats (exos_create_hold's own rule).
SELECT pg_temp.as_user('c7e00000-0000-0000-0000-0000000000b9', 'c7-unconfirmed@x.com');
DO $$ BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d1',2)$q$) LIKE '%confirm your email%', 'G2 confirmed email';
  RAISE NOTICE 'OK  G2 an unconfirmed account can''t start a group';
END $$;

-- ---------------------------------------------------------------------------
-- G3 the holds
-- ---------------------------------------------------------------------------
SELECT pg_temp.as_user('c7e00000-0000-0000-0000-0000000000b0', 'c7-host@x.com');
DO $$
DECLARE v_g uuid := (SELECT id FROM g WHERE k = 'main'); v_h uuid; v_dead timestamptz;
BEGIN
  SELECT deadline INTO v_dead FROM public.exos_group_buys WHERE id = v_g;
  -- The host opens a normal cart for the event: their earlier cart is retired,
  -- the group's seats are not.
  v_h := public.exos_create_hold('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d1',1);
  ASSERT (SELECT count(*) FROM public.exos_cart_holds h JOIN public.exos_group_buy_seats s ON s.hold_id = h.id
           WHERE s.group_id = v_g AND h.status = 'active') = 4, 'G3 the host''s new cart keeps the group''s holds';
  UPDATE public.exos_cart_holds SET status = 'released', released_at = now() WHERE id = v_h;
  -- Anyone else's release of a group hold (exos-checkout's failure path, an
  -- expired page) is a no-op before the deadline.
  UPDATE public.exos_cart_holds SET status = 'released', released_at = now()
   WHERE id = (SELECT hold_id FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = 4);
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id = (SELECT hold_id FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = 4)) = 'active',
    'G3 a stray release keeps the seat with the group';
  ASSERT pg_temp.state(v_g, 4) = 'waiting', 'G3 still waiting';
  -- A Stripe page (cs_, 30 min + 10 grace) never pushes the hold past the deadline.
  PERFORM pg_temp.sess('cs_test_c7_grace', 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com', 1);
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_test_c7_grace'
   WHERE id = (SELECT hold_id FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = 4);
  ASSERT (SELECT expires_at FROM public.exos_cart_holds WHERE id = (SELECT hold_id FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = 4)) = v_dead,
    'G3 the checkout grace is clamped to the deadline';
  UPDATE public.exos_cart_holds SET checkout_session_id = NULL
   WHERE id = (SELECT hold_id FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = 4);
  UPDATE public.exos_checkout_sessions SET status = 'expired' WHERE session_id = 'cs_test_c7_grace';
  RAISE NOTICE 'OK  G3 holds end at the deadline; stray releases (new cart, failed checkout) keep the seat with the group';
END $$;

-- ---------------------------------------------------------------------------
-- G4 / G5 / G6 friends pay (exos-checkout's calls, as service role = postgres here)
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_g uuid := (SELECT id FROM g WHERE k = 'main'); v_ctx jsonb; v_hold uuid; v_ids uuid[]; v_sold int;
BEGIN
  PERFORM pg_temp.as_user('', '');
  v_ctx := public.exos_group_checkout_ctx(pg_temp.tok(v_g, 1), NULL, 'c7e00000-0000-0000-0000-0000000000b1');
  ASSERT v_ctx->>'event_id' = 'c7e00000-0000-0000-0000-0000000000e1' AND (v_ctx->>'quantity')::int = 1, 'G4 a seat link is one ticket of the group''s type';
  v_hold := public.exos_group_claim(pg_temp.tok(v_g, 1), NULL, 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com',
            'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1);
  ASSERT v_hold = (SELECT hold_id FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = 1), 'G4 the checkout carries the seat''s hold';
  ASSERT pg_temp.state(v_g, 1) = 'paying', 'G4 paying';
  -- G5: friend 2 opens the same link.
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_claim(%L, NULL, 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com',
           'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1)$q$, pg_temp.tok(v_g, 1))) LIKE 'XG409 seat already taken%',
    'G5 the second friend: seat already taken';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_checkout_ctx(%L, NULL, NULL)$q$, pg_temp.tok(v_g, 1))) IS NULL, 'G5 the link still reads';
  PERFORM pg_temp.sess('cs_test_c7_f1a', 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com', 1);
  ASSERT public.exos_group_attach('cs_test_c7_f1a', pg_temp.tok(v_g, 1), NULL) = 1, 'G4 attached';
  -- Friend 1 starts over (back button): same claimant, a new checkout; the old one can't be issued.
  v_hold := public.exos_group_claim(pg_temp.tok(v_g, 1), NULL, 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com',
            'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1);
  PERFORM pg_temp.sess('cs_test_c7_f1b', 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com', 1);
  PERFORM public.exos_group_attach('cs_test_c7_f1b', pg_temp.tok(v_g, 1), NULL);
  ASSERT (SELECT group_buy_id FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_c7_f1b') = v_g, 'G4 the order is a group order';
  SELECT sold INTO v_sold FROM public.exos_ticket_tiers WHERE id = 'c7e00000-0000-0000-0000-0000000000d1';
  v_ids := public.exos_fulfill_checkout('cs_test_c7_f1a');
  ASSERT cardinality(v_ids) = 0 AND (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_c7_f1a') = 'failed'
     AND (SELECT failure_reason FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_c7_f1a') LIKE 'group seat no longer held%',
    'G5 the abandoned first checkout fails if paid (auto-refund)';
  ASSERT (SELECT html FROM public.exos_mail WHERE to_email = 'c7-f1@x.com' AND template = 'order-failed' ORDER BY created_at DESC LIMIT 1) LIKE '%group''s time ran out%',
    'G5 the failure mail says why';
  ASSERT pg_temp.state(v_g, 1) = 'paying', 'G5 the seat is still friend 1''s';
  v_ids := public.exos_fulfill_checkout('cs_test_c7_f1b');
  ASSERT cardinality(v_ids) = 1, 'G4 one ticket';
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = v_ids[1]) = 'c7e00000-0000-0000-0000-0000000000b1'
     AND (SELECT order_ref FROM public.exos_tickets WHERE id = v_ids[1]) = 'cs_test_c7_f1b', 'G4 minted to the friend, on their own order';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = 'c7e00000-0000-0000-0000-0000000000d1') = v_sold + 1, 'G4 sold once';
  ASSERT pg_temp.state(v_g, 1) = 'paid' AND (SELECT paid_session_id FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = 1) = 'cs_test_c7_f1b',
    'G4 the seat is paid by that order';
  ASSERT public.exos_tier_available('c7e00000-0000-0000-0000-0000000000d1') = 16, 'G4 consumed, not double-counted';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_claim(%L, NULL, 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com',
           'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1)$q$, pg_temp.tok(v_g, 1))) LIKE 'XG411%',
    'G4 a paid seat can''t be claimed';
  RAISE NOTICE 'OK  G4 a friend pays their seat: claimed, attached, fulfilled to the friend as its own order';
  RAISE NOTICE 'OK  G5 the same seat twice: second friend refused; a restart leaves the old checkout unissuable';

  -- G6: friend 2 claims seat 2, the checkout fails before payment -> back to the group.
  PERFORM public.exos_group_claim(pg_temp.tok(v_g, 2), NULL, 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com',
          'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1);
  ASSERT public.exos_group_unclaim(pg_temp.tok(v_g, 2), NULL, 'c7e00000-0000-0000-0000-0000000000b3', 'c7-f3@x.com') = 0, 'G6 someone else can''t unclaim it';
  ASSERT public.exos_group_unclaim(pg_temp.tok(v_g, 2), NULL, 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com') = 1, 'G6 unclaimed';
  ASSERT pg_temp.state(v_g, 2) = 'waiting', 'G6 back to waiting';
  -- A guest claims it; the checkout is never attached: after 5 minutes it stops counting.
  PERFORM public.exos_group_claim(pg_temp.tok(v_g, 2), NULL, NULL, 'Guest@Y.com',
          'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1);
  ASSERT pg_temp.state(v_g, 2) = 'paying', 'G6 a guest''s claim';
  UPDATE public.exos_group_buy_seats SET claimed_at = now() - interval '6 minutes' WHERE group_id = v_g AND seat_no = 2;
  ASSERT pg_temp.state(v_g, 2) = 'waiting', 'G6 a stale claim stops counting';
  -- Friend 3 claims and attaches; their page expires: the seat is free again, still held.
  PERFORM public.exos_group_claim(pg_temp.tok(v_g, 2), NULL, 'c7e00000-0000-0000-0000-0000000000b3', 'c7-f3@x.com',
          'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1);
  PERFORM pg_temp.sess('cs_test_c7_f3', 'c7e00000-0000-0000-0000-0000000000b3', 'c7-f3@x.com', 1);
  PERFORM public.exos_group_attach('cs_test_c7_f3', pg_temp.tok(v_g, 2), NULL);
  ASSERT pg_temp.state(v_g, 2) = 'paying', 'G6 friend 3 paying';
  UPDATE public.exos_checkout_sessions SET status = 'expired' WHERE session_id = 'cs_test_c7_f3';
  ASSERT pg_temp.state(v_g, 2) = 'waiting'
     AND (SELECT h.status FROM public.exos_cart_holds h JOIN public.exos_group_buy_seats s ON s.hold_id = h.id WHERE s.group_id = v_g AND s.seat_no = 2) = 'active',
    'G6 an expired page frees the seat, the hold stays with the group';
  RAISE NOTICE 'OK  G6 failed / stale / expired checkouts give the seat back to the group, not to sale';
END $$;

-- ---------------------------------------------------------------------------
-- G7 cover the rest
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_g uuid := (SELECT id FROM g WHERE k = 'main'); v_ctx jsonb; v_ids uuid[];
BEGIN
  -- Friend 2 is on a checkout page for seat 3 when the host covers the rest.
  PERFORM public.exos_group_claim(pg_temp.tok(v_g, 3), NULL, 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com',
          'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1);
  PERFORM pg_temp.sess('cs_test_c7_f2', 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com', 1);
  PERFORM public.exos_group_attach('cs_test_c7_f2', pg_temp.tok(v_g, 3), NULL);

  ASSERT pg_temp.err(format($q$SELECT public.exos_group_checkout_ctx(NULL, %L, 'c7e00000-0000-0000-0000-0000000000b1')$q$, v_g)) LIKE 'XG403%', 'G7 only the host covers';
  v_ctx := public.exos_group_checkout_ctx(NULL, v_g, 'c7e00000-0000-0000-0000-0000000000b0');
  ASSERT (v_ctx->>'quantity')::int = 3, 'G7 three unpaid seats';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_claim(NULL, %L, 'c7e00000-0000-0000-0000-0000000000b0', 'c7-host@x.com',
           'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 2)$q$, v_g)) LIKE 'XG412%', 'G7 a stale count is refused';
  PERFORM public.exos_group_claim(NULL, v_g, 'c7e00000-0000-0000-0000-0000000000b0', 'c7-host@x.com',
          'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 3);
  ASSERT pg_temp.state(v_g, 2) = 'covering' AND pg_temp.state(v_g, 4) = 'covering', 'G7 covering';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_claim(%L, NULL, 'c7e00000-0000-0000-0000-0000000000b3', 'c7-f3@x.com',
           'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1)$q$, pg_temp.tok(v_g, 4))) LIKE 'XG409%host is paying%',
    'G7 a friend can''t take a seat the host is covering';
  PERFORM pg_temp.sess('cs_test_c7_cover', 'c7e00000-0000-0000-0000-0000000000b0', 'c7-host@x.com', 3);
  ASSERT pg_temp.err($q$SELECT public.exos_group_attach('cs_test_c7_f2', NULL, (SELECT id FROM g WHERE k = 'main'))$q$) LIKE 'XG403%', 'G7 a friend''s order can''t attach the cover';
  ASSERT public.exos_group_attach('cs_test_c7_cover', NULL, v_g) = 3, 'G7 the cover attaches three seats';
  v_ids := public.exos_fulfill_checkout('cs_test_c7_cover');
  ASSERT cardinality(v_ids) = 3 AND (SELECT count(*) FROM public.exos_tickets WHERE id = ANY (v_ids) AND owner_id = 'c7e00000-0000-0000-0000-0000000000b0') = 3,
    'G7 three tickets minted to the host';
  ASSERT pg_temp.state(v_g, 2) = 'covered' AND pg_temp.state(v_g, 3) = 'covered' AND pg_temp.state(v_g, 4) = 'covered', 'G7 covered';
  ASSERT (SELECT status FROM public.exos_group_buys WHERE id = v_g) = 'closed', 'G7 every seat paid: the group closes';
  -- Friend 2 pays the page they had open: no seat, refunded.
  v_ids := public.exos_fulfill_checkout('cs_test_c7_f2');
  ASSERT cardinality(v_ids) = 0 AND (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_c7_f2') = 'failed',
    'G7 a late friend payment on a covered seat fails (auto-refund)';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref IN ('cs_test_c7_f1b', 'cs_test_c7_cover') AND status = 'active') = 4
     AND (SELECT sold FROM public.exos_ticket_tiers WHERE id = 'c7e00000-0000-0000-0000-0000000000d1') = 4, 'G7 four seats sold, exactly once each';
  RAISE NOTICE 'OK  G7 cover the rest: one order to the host; a friend''s open checkout on a covered seat fails';
END $$;

-- ---------------------------------------------------------------------------
-- G8 deadline
-- ---------------------------------------------------------------------------
SELECT pg_temp.as_user('c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com');
DO $$
DECLARE r jsonb; v_g uuid; v_ids uuid[]; v_n int;
BEGIN
  r := public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e1','c7e00000-0000-0000-0000-0000000000d1',3);
  v_g := (r->>'id')::uuid;
  INSERT INTO g VALUES ('late', v_g);
  PERFORM pg_temp.as_user('', '');
  PERFORM public.exos_group_claim(pg_temp.tok(v_g, 1), NULL, 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com',
          'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1);
  PERFORM pg_temp.sess('cs_test_c7_late', 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com', 1);
  PERFORM public.exos_group_attach('cs_test_c7_late', pg_temp.tok(v_g, 1), NULL);
  ASSERT public.exos_tier_available('c7e00000-0000-0000-0000-0000000000d1') = 13, 'G8 three held';
  -- The window closes (as if 31 minutes passed).
  UPDATE public.exos_group_buys SET created_at = now() - interval '31 minutes', deadline = now() - interval '1 minute' WHERE id = v_g;
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 minute'
   WHERE id IN (SELECT hold_id FROM public.exos_group_buy_seats WHERE group_id = v_g);
  ASSERT public.exos_tier_available('c7e00000-0000-0000-0000-0000000000d1') = 16, 'G8 back on sale by the clock';
  ASSERT pg_temp.state(v_g, 2) = 'released', 'G8 released by the clock';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_claim(%L, NULL, 'c7e00000-0000-0000-0000-0000000000b3', 'c7-f3@x.com',
           'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1)$q$, pg_temp.tok(v_g, 2))) LIKE 'XG410%', 'G8 no claim after the deadline';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_checkout_ctx(NULL, %L, 'c7e00000-0000-0000-0000-0000000000b1')$q$, v_g)) LIKE 'XG410%', 'G8 no cover after the deadline';
  -- The payment lands late: not issued, refunded.
  v_ids := public.exos_fulfill_checkout('cs_test_c7_late');
  ASSERT cardinality(v_ids) = 0 AND (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_c7_late') = 'failed', 'G8 a late payment fails (auto-refund)';
  -- The existing sweep releases the seats.
  v_n := public.exos_expire_holds();
  ASSERT (SELECT count(*) FROM public.exos_group_buy_seats WHERE group_id = v_g AND status = 'released') = 3, 'G8 the sweep releases every seat';
  ASSERT (SELECT status FROM public.exos_group_buys WHERE id = v_g) = 'closed', 'G8 the group closes';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = 'c7e00000-0000-0000-0000-0000000000d1') = 4, 'G8 nothing sold';
  RAISE NOTICE 'OK  G8 deadline: no claim or cover after it, a late payment fails, the sweep releases the seats';
END $$;

-- ---------------------------------------------------------------------------
-- G9 per-seat orders: refunds stay per order
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_g uuid := (SELECT id FROM g WHERE k = 'main'); r jsonb;
BEGIN
  PERFORM public.exos_refund_checkout('cs_test_c7_f1b', 'friend refunded');
  ASSERT (SELECT status FROM public.exos_tickets WHERE order_ref = 'cs_test_c7_f1b') <> 'active', 'G9 the friend''s ticket is voided';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_test_c7_cover' AND status = 'active') = 3, 'G9 the host''s order is untouched';
  PERFORM pg_temp.as_user('c7e00000-0000-0000-0000-0000000000b0', 'c7-host@x.com');
  r := public.exos_group_buy_get(v_g);
  ASSERT (SELECT x->>'order_status' FROM jsonb_array_elements(r->'seats') x WHERE (x->>'seat_no')::int = 1) = 'refunded', 'G9 the host sees seat 1''s order refunded';
  RAISE NOTICE 'OK  G9 each seat is its own order: one refund, one order';
END $$;

-- ---------------------------------------------------------------------------
-- G10 cross-group / cross-org
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_g uuid; r jsonb;
BEGIN
  PERFORM pg_temp.as_user('c7e00000-0000-0000-0000-0000000000c0', 'c7-other@x.com');
  r := public.exos_group_buy_start('c7e00000-0000-0000-0000-0000000000e3','c7e00000-0000-0000-0000-0000000000d9',2);
  v_g := (r->>'id')::uuid;
  INSERT INTO g VALUES ('other', v_g);
  -- Another host can't read, cancel or cover it; the org's staff don't see seats.
  PERFORM pg_temp.as_user('c7e00000-0000-0000-0000-0000000000b0', 'c7-host@x.com');
  ASSERT pg_temp.err(format('SELECT public.exos_group_buy_get(%L)', v_g)) LIKE '42501%', 'G10 another host can''t read it';
  ASSERT pg_temp.err(format('SELECT public.exos_group_buy_cancel(%L)', v_g)) LIKE '42501%', 'G10 another host can''t cancel it';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(public.exos_group_buy_mine(NULL)) x WHERE x->>'id' = v_g::text) = 0, 'G10 not in another host''s list';
  PERFORM pg_temp.as_user('', '');
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_checkout_ctx(NULL, %L, 'c7e00000-0000-0000-0000-0000000000b0')$q$, v_g)) LIKE 'XG403%', 'G10 not their cover';
  -- A seat token of org 2's group with org 1's event / type: refused.
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_claim(%L, NULL, 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com',
           'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1)$q$, pg_temp.tok(v_g, 1))) LIKE 'XG400%',
    'G10 a token for another group''s ticket is refused';
  -- An org 1 order can't attach org 2's seat.
  PERFORM public.exos_group_claim(pg_temp.tok(v_g, 1), NULL, 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com',
          'c7e00000-0000-0000-0000-0000000000e3', 'c7e00000-0000-0000-0000-0000000000d9', 1);
  PERFORM pg_temp.sess('cs_test_c7_x', 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com', 1);
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_attach('cs_test_c7_x', %L, NULL)$q$, pg_temp.tok(v_g, 1))) LIKE 'XG400%', 'G10 cross-org attach refused';
  -- Another buyer's order can't attach a seat claimed by friend 1.
  PERFORM pg_temp.sess('cs_test_c7_y', 'c7e00000-0000-0000-0000-0000000000b2', 'c7-f2@x.com', 1,
                       'c7e00000-0000-0000-0000-0000000000d9', 'c7e00000-0000-0000-0000-0000000000e3', 'c7e00000-0000-0000-0000-000000000002');
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_attach('cs_test_c7_y', %L, NULL)$q$, pg_temp.tok(v_g, 1))) LIKE 'XG409%', 'G10 a claim is the claimant''s';
  -- A main-group seat token in the other group's attach: another group's ticket.
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_attach('cs_test_c7_y', %L, NULL)$q$, pg_temp.tok((SELECT id FROM g WHERE k = 'late'), 2))) LIKE 'XG4%', 'G10 cross-group attach refused';
  -- The normal hold's buyer checks: a confirmed account; guests only where the event allows them.
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_claim(%L, NULL, 'c7e00000-0000-0000-0000-0000000000b9', 'c7-unconfirmed@x.com',
           'c7e00000-0000-0000-0000-0000000000e3', 'c7e00000-0000-0000-0000-0000000000d9', 1)$q$, pg_temp.tok(v_g, 2))) LIKE '42501%confirm your email%', 'G10 unconfirmed account refused';
  UPDATE public.exos_events SET purchase_limits = '{"guestCheckout": false}' WHERE id = 'c7e00000-0000-0000-0000-0000000000e3';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_claim(%L, NULL, NULL, 'guest@y.com',
           'c7e00000-0000-0000-0000-0000000000e3', 'c7e00000-0000-0000-0000-0000000000d9', 1)$q$, pg_temp.tok(v_g, 2))) LIKE '42501%sign in%', 'G10 no guests where the event says so';
  UPDATE public.exos_events SET purchase_limits = NULL WHERE id = 'c7e00000-0000-0000-0000-0000000000e3';
  ASSERT pg_temp.err($q$SELECT public.exos_group_claim('not-a-token', NULL, 'c7e00000-0000-0000-0000-0000000000b1', 'x@y.com',
           'c7e00000-0000-0000-0000-0000000000e1', 'c7e00000-0000-0000-0000-0000000000d1', 1)$q$) LIKE 'XG404%', 'G10 a bad token';
  -- RLS: the org's finance reads its own groups, not org 2's; nobody but admins reads seat rows.
  PERFORM pg_temp.as_user('c7e00000-0000-0000-0000-0000000000a1', 'c7-finance@x.com');
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_group_buys) = 2, 'G10 finance reads its org''s groups';
  ASSERT (SELECT count(*) FROM public.exos_group_buy_seats) = 0, 'G10 staff read no seat rows (tokens, claimant emails)';
  RESET ROLE;
  PERFORM pg_temp.as_user('c7e00000-0000-0000-0000-0000000000c0', 'c7-other@x.com');
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_group_buys) = 1, 'G10 the other host reads only theirs';
  ASSERT (SELECT count(*) FROM public.exos_group_buy_seats) = 0, 'G10 hosts read seats through the RPC only';
  ASSERT pg_temp.err($q$SELECT public.exos_group_claim(NULL, (SELECT id FROM g WHERE k = 'other'), 'c7e00000-0000-0000-0000-0000000000c0', 'c7-other@x.com',
           'c7e00000-0000-0000-0000-0000000000e3', 'c7e00000-0000-0000-0000-0000000000d9', 2)$q$) LIKE '42501%', 'G10 a client can''t claim directly';
  RESET ROLE;
  RAISE NOTICE 'OK  G10 cross-group and cross-org: tokens, orders and hosts stay in their own group';
END $$;

-- ---------------------------------------------------------------------------
-- G11 cancel
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_g uuid := (SELECT id FROM g WHERE k = 'other'); r jsonb; v_ids uuid[];
BEGIN
  ASSERT public.exos_tier_available('c7e00000-0000-0000-0000-0000000000d9') = 18, 'G11 two held';
  PERFORM pg_temp.as_user('c7e00000-0000-0000-0000-0000000000c0', 'c7-other@x.com');
  r := public.exos_group_buy_cancel(v_g);
  ASSERT r->>'status' = 'cancelled' AND (r->'counts'->>'released')::int = 2, 'G11 cancelled, both seats released';
  ASSERT public.exos_tier_available('c7e00000-0000-0000-0000-0000000000d9') = 20, 'G11 back on sale at once';
  -- Friend 1's open checkout on seat 1 (claimed in G10) can't be issued now.
  PERFORM pg_temp.as_user('', '');
  PERFORM pg_temp.sess('cs_test_c7_z', 'c7e00000-0000-0000-0000-0000000000b1', 'c7-f1@x.com', 1,
                       'c7e00000-0000-0000-0000-0000000000d9', 'c7e00000-0000-0000-0000-0000000000e3', 'c7e00000-0000-0000-0000-000000000002');
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_attach('cs_test_c7_z', %L, NULL)$q$, pg_temp.tok(v_g, 1))) LIKE 'XG409%', 'G11 nothing to attach after a cancel';
  RAISE NOTICE 'OK  G11 cancel sends the unpaid seats back on sale at once';
END $$;

-- ---------------------------------------------------------------------------
-- G12 the public seat read
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_g uuid := (SELECT id FROM g WHERE k = 'main'); r jsonb; v_t text;
BEGIN
  PERFORM pg_temp.as_user('', '');
  SET LOCAL ROLE anon;
  ASSERT public.exos_group_seat_view('0123456789abcdef0123456789abcdef') IS NULL, 'G12 unknown token: nothing';
  ASSERT public.exos_group_seat_view('nope') IS NULL, 'G12 a malformed token: nothing';
  RESET ROLE;
  v_t := pg_temp.tok(v_g, 2);
  SET LOCAL ROLE anon;
  r := public.exos_group_seat_view(v_t);
  RESET ROLE;
  ASSERT r->>'state' = 'covered' AND (r->>'seats')::int = 4 AND (r->>'paid')::int = 4 AND (r->>'open')::int = 0, 'G12 this seat and the counts';
  ASSERT r->'event'->>'name' = 'C7 Show' AND r->>'tier_id' = 'c7e00000-0000-0000-0000-0000000000d1', 'G12 the event and the type';
  ASSERT r->>'group_id' IS NULL AND NOT (r->>'is_host')::boolean, 'G12 the group id only for its host';
  ASSERT r::text !~ '@' AND r::text !~ 'c7e00000-0000-0000-0000-0000000000b' AND position(v_t IN r::text) = 0
     AND r::text !~ '[0-9a-f]{32}', 'G12 no emails, no people, no links';
  PERFORM pg_temp.as_user('c7e00000-0000-0000-0000-0000000000b0', 'c7-host@x.com');
  ASSERT (public.exos_group_seat_view(v_t)->>'group_id')::uuid = v_g, 'G12 the host gets the way back to their group';
  RAISE NOTICE 'OK  G12 the seat page reads one seat by its token and counts, nothing about other friends';
END $$;

ROLLBACK;
