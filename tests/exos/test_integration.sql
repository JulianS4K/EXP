-- ============================================================================
-- Build-phase integration (mig 20261101000000): paths that cross branches.
-- Self-contained (1e… ids), rolled back at the end.
--   I1 a paid order on a seated (#66) + timed (#68) ticket type: the hold
--      takes the slot and the seats, fulfillment gives each ticket both;
--      the seat is the event's (taken for every slot)
--   I2 a member presale (#70) paid partly with a gift card (#70): the member's
--      order is fulfilled and the card captured; a non-member's order in the
--      presale fails and the card's hold is given back
--   I3 a partner reservation (#74) and last call (#57): reserved before last
--      call completes, a new one during it is refused, an organizer (API key)
--      reservation still sells; seated / timed types are never offered or
--      reserved (section 5)
--   I4 a free-tier event (#57) selling a fixed block (#60): free tier, resale
--      locked, Exos sells and comps its block, last call keeps Exos selling,
--      after the release nothing mints
--   I5 the ticket-insert triggers agree on comps: a staff comp passes the
--      member presale, but seated and timed types refuse comps (both by
--      design), and a comp after a block's release is refused
--   I6 the merged where-to-buy (section 1) and scope list (sections 2, 3)
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_integration.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('1e000000-0000-0000-0000-0000000000a0', 'ix-owner@x.com', now()),
  ('1e000000-0000-0000-0000-0000000000a1', 'ix-manager@x.com', now()),
  ('1e000000-0000-0000-0000-0000000000b1', 'ix-buyer@x.com', now()),
  ('1e000000-0000-0000-0000-0000000000b2', 'ix-member@x.com', now()),
  ('1e000000-0000-0000-0000-0000000000b3', 'ix-nonmember@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('1e000000-0000-0000-0000-000000000001', 'IX Org', 'ix-org', '1e000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000a0', 'owner'),
  ('1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000a1', 'manager');
-- e1 seated + timed, e2 member presale, e3 partner sales, e4 free tier + block.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
  ('1e000000-0000-0000-0000-0000000000e1', '1e000000-0000-0000-0000-000000000001', 'IX Museum', 'ix-museum', 'published',
   now() + interval '9 days', 'America/New_York', 0, '1e000000-0000-0000-0000-0000000000a0'),
  ('1e000000-0000-0000-0000-0000000000e2', '1e000000-0000-0000-0000-000000000001', 'IX Members', 'ix-members', 'published',
   now() + interval '9 days', 'America/New_York', 0, '1e000000-0000-0000-0000-0000000000a0'),
  ('1e000000-0000-0000-0000-0000000000e3', '1e000000-0000-0000-0000-000000000001', 'IX Partners', 'ix-partners', 'published',
   now() + interval '9 days', 'America/New_York', 0, '1e000000-0000-0000-0000-0000000000a0'),
  ('1e000000-0000-0000-0000-0000000000e4', '1e000000-0000-0000-0000-000000000001', 'IX Block', 'ix-block', 'published',
   now() + interval '9 days', 'America/New_York', 0, '1e000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  ('1e000000-0000-0000-0000-0000000000d1', '1e000000-0000-0000-0000-0000000000e1', 'Seats', 50, 999, 0, 'public', 1),
  ('1e000000-0000-0000-0000-0000000000d2', '1e000000-0000-0000-0000-0000000000e2', 'VIP', 90, 100, 0, 'public', 1),
  ('1e000000-0000-0000-0000-0000000000d3', '1e000000-0000-0000-0000-0000000000e2', 'Comp crew', 0, 100, 0, 'hidden', 2),
  ('1e000000-0000-0000-0000-0000000000d4', '1e000000-0000-0000-0000-0000000000e3', 'GA', 25, 300, 0, 'public', 1),
  ('1e000000-0000-0000-0000-0000000000d5', '1e000000-0000-0000-0000-0000000000e3', 'Timed GA', 25, 300, 0, 'public', 2),
  ('1e000000-0000-0000-0000-0000000000d6', '1e000000-0000-0000-0000-0000000000e4', 'GA', 20, 0, 0, 'public', 1);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.slot(n int, hm text) RETURNS text LANGUAGE sql AS $$
  SELECT to_char(current_date + n, 'YYYYMMDD') || 'T' || replace(hm, ':', '') $$;
GRANT EXECUTE ON FUNCTION pg_temp.slot(int, text) TO anon, authenticated, service_role;
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
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated, service_role;
-- A ticket row as a box office / comp path writes it (the insert triggers decide).
CREATE FUNCTION pg_temp.mint(p_event text, p_tier text, p_ref text, p_channel text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_email, status, barcode_secret, price_paid,
                                   order_ref, channel_source)
  VALUES (('1e000000-0000-0000-0000-0000000000' || p_event)::uuid, '1e000000-0000-0000-0000-000000000001',
          ('1e000000-0000-0000-0000-0000000000' || p_tier)::uuid, 'IX', p_ref || '@x.com', 'active', p_ref, 0, p_ref, p_channel)
$$;
CREATE TEMP TABLE ix (k text PRIMARY KEY, v text);
GRANT ALL ON ix TO anon, authenticated, service_role;

-- I1 -------------------------------------------------------------------------
-- One section, row A, four seats; the ticket type is seated and timed.
SELECT pg_temp.act('1e000000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
DO $$
DECLARE cfg jsonb;
BEGIN
  INSERT INTO public.exos_seat_maps (id, org_id, name, map) VALUES ('1e000000-0000-0000-0000-00000000aa01',
    '1e000000-0000-0000-0000-000000000001', 'Gallery', jsonb_build_object(
      'width', 800, 'height', 400,
      'sections', jsonb_build_array(jsonb_build_object('id', 's1', 'name', 'Gallery', 'kind', 'seated', 'x', 100, 'y', 100,
        'rows', jsonb_build_array(jsonb_build_object('id', 'r1', 'label', 'A', 'seats', jsonb_build_array(
          jsonb_build_object('key', '1', 'label', '1', 'x', 0, 'y', 0),
          jsonb_build_object('key', '2', 'label', '2', 'x', 24, 'y', 0),
          jsonb_build_object('key', '3', 'label', '3', 'x', 48, 'y', 0),
          jsonb_build_object('key', '4', 'label', '4', 'x', 72, 'y', 0))))))));
  PERFORM public.exos_set_event_seating('1e000000-0000-0000-0000-0000000000e1', '1e000000-0000-0000-0000-00000000aa01',
    '{"s1":"1e000000-0000-0000-0000-0000000000d1"}');
  cfg := jsonb_build_object(
    'tierIds', jsonb_build_array('1e000000-0000-0000-0000-0000000000d1'),
    'slotMinutes', 60, 'capacity', 10, 'entryWindowMinutes', 30, 'earlyEntryMinutes', 15,
    'hours', (SELECT jsonb_object_agg(g::text, jsonb_build_array(jsonb_build_object('open', '10:00', 'close', '17:00')))
                FROM generate_series(0, 6) g),
    'startDate', (current_date)::text, 'endDate', (current_date + 30)::text);
  PERFORM public.exos_set_timed_entry('1e000000-0000-0000-0000-0000000000e1', cfg);
END $$;
RESET ROLE;
DO $$
DECLARE h uuid; ids uuid[]; t record; s11 text := pg_temp.slot(3, '11:00');
BEGIN
  ASSERT (SELECT seated AND capacity = 4 FROM public.exos_ticket_tiers WHERE id = '1e000000-0000-0000-0000-0000000000d1'),
    'I1: the tier is seated, its capacity the seat count';
  ASSERT public._exos_tier_is_timed('1e000000-0000-0000-0000-0000000000d1'), 'I1: and timed';
  -- As exos-checkout: the cart hold, then the slot, then the seats.
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000b1');
  h := public.exos_create_hold('1e000000-0000-0000-0000-0000000000e1', '1e000000-0000-0000-0000-0000000000d1', 2);
  ASSERT public.exos_attach_hold_slot(h, s11), 'I1: the hold takes the slot';
  PERFORM public.exos_hold_seats(h, ARRAY['s1-r1-1', 's1-r1-2']);
  PERFORM pg_temp.act(NULL);
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity,
                                             amount_cents, currency, status, slot_id)
  VALUES ('ix-s1', '1e000000-0000-0000-0000-0000000000e1', '1e000000-0000-0000-0000-0000000000d1',
          '1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000b1', 'ix-buyer@x.com', 2, 10000, 'usd',
          'pending', s11);
  UPDATE public.exos_cart_holds SET checkout_session_id = 'ix-s1' WHERE id = h;
  ids := public.exos_fulfill_checkout('ix-s1');
  ASSERT cardinality(ids) = 2, 'I1: two tickets, got ' || coalesce(cardinality(ids), 0)
    || ' (' || coalesce((SELECT failure_reason FROM public.exos_checkout_sessions WHERE session_id = 'ix-s1'), '-') || ')';
  FOR t IN SELECT * FROM public.exos_tickets WHERE id = ANY (ids) LOOP
    ASSERT t.seat_id IN ('s1-r1-1', 's1-r1-2') AND t.slot_id = s11 AND t.slot_starts_at IS NOT NULL,
      'I1: each ticket has its seat and its slot';
  END LOOP;
  ASSERT (SELECT count(DISTINCT seat_id) FROM public.exos_tickets WHERE id = ANY (ids)) = 2, 'I1: two different seats';
  ASSERT (SELECT sold FROM public.exos_event_slots WHERE event_id = '1e000000-0000-0000-0000-0000000000e1' AND slot_id = s11) = 2,
    'I1: the slot counts both';
  ASSERT (SELECT count(*) FROM public.exos_event_seat_claims WHERE ticket_id = ANY (ids) AND status = 'sold') = 2, 'I1: seats sold';
  ASSERT public.exos_fulfill_checkout('ix-s1') = ids, 'I1: a replay mints nothing more';
  -- The seat is the event's, not the slot's: another slot can't take A1.
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000b2');
  h := public.exos_create_hold('1e000000-0000-0000-0000-0000000000e1', '1e000000-0000-0000-0000-0000000000d1', 1);
  PERFORM public.exos_attach_hold_slot(h, pg_temp.slot(4, '11:00'));
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.refused(format('SELECT public.exos_hold_seats(%L, ARRAY[''s1-r1-1''])', h), 'taken'),
    'I1: a sold seat is sold for every slot';
  RAISE NOTICE 'OK  I1 seated + timed paid order';
END $$;

-- I2 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000a1');
  INSERT INTO public.exos_membership_products (id, org_id, name, price_cents, billing, discount_percent, presale,
                                               free_tickets_per_period, guest_allowance, household_seats)
  VALUES ('1e000000-0000-0000-0000-00000000c001', '1e000000-0000-0000-0000-000000000001', 'IX Member', 1000, 'month', 10, true, 0, 0, 0);
  PERFORM public.exos_set_member_presale('1e000000-0000-0000-0000-0000000000e2', NULL, now() + interval '1 day',
    ARRAY['1e000000-0000-0000-0000-0000000000d2', '1e000000-0000-0000-0000-0000000000d3']::uuid[], '{}');
END $$;
RESET ROLE;
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency, stripe_customer_id)
VALUES ('cs_ix_m1', '1e000000-0000-0000-0000-000000000001', 'membership', '1e000000-0000-0000-0000-00000000c001',
        '1e000000-0000-0000-0000-0000000000b2', 'ix-member@x.com', 1000, 'usd', 'cus_ixmember');
SET LOCAL ROLE service_role;
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT public.exos_commerce_fulfill('cs_ix_m1', NULL, 1000, 'sub_ixmember', now() + interval '1 month') = 'fulfilled', 'I2: member';
  r := public.exos_member_checkout('1e000000-0000-0000-0000-0000000000e2', '1e000000-0000-0000-0000-0000000000d2',
                                   '1e000000-0000-0000-0000-0000000000b2');
  ASSERT NOT (r->>'presale_blocked')::boolean AND (r->>'discount_percent')::numeric = 10, 'I2: member checkout ' || r::text;
  INSERT INTO ix VALUES ('membership', r->>'membership_id');
  r := public.exos_member_checkout('1e000000-0000-0000-0000-0000000000e2', '1e000000-0000-0000-0000-0000000000d2',
                                   '1e000000-0000-0000-0000-0000000000b3');
  ASSERT (r->>'presale_blocked')::boolean, 'I2: the presale blocks a non-member at checkout';
END $$;
RESET ROLE;
DO $$
DECLARE r jsonb;
BEGIN
  r := public._exos_gift_card_issue('1e000000-0000-0000-0000-000000000001', NULL, 5000, 'usd', 'dashboard', 'comp',
                                    NULL, NULL, NULL, NULL, NULL, NULL, NULL, false);
  INSERT INTO ix VALUES ('code1', r->>'code'), ('card1', r->>'card_id');
  r := public._exos_gift_card_issue('1e000000-0000-0000-0000-000000000001', NULL, 5000, 'usd', 'dashboard', 'comp',
                                    NULL, NULL, NULL, NULL, NULL, NULL, NULL, false);
  INSERT INTO ix VALUES ('code2', r->>'code'), ('card2', r->>'card_id');
  -- The member: VIP $90 less 10% = $81; the card pays $50, the card charge $31.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity,
                                             amount_cents, gift_card_cents, membership_id, member_discount_percent, currency, status)
  VALUES ('ix-s2', '1e000000-0000-0000-0000-0000000000e2', '1e000000-0000-0000-0000-0000000000d2',
          '1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000b2', 'ix-member@x.com', 1,
          3100, 5000, (SELECT v::uuid FROM ix WHERE k = 'membership'), 10, 'usd', 'pending');
  -- A non-member who got past the page during the presale, with card 2.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity,
                                             amount_cents, gift_card_cents, currency, status)
  VALUES ('ix-s3', '1e000000-0000-0000-0000-0000000000e2', '1e000000-0000-0000-0000-0000000000d2',
          '1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000b3', 'ix-nonmember@x.com', 1,
          4000, 5000, 'usd', 'pending');
END $$;
SET LOCAL ROLE service_role;
DO $$
BEGIN
  PERFORM public.exos_gift_card_hold((SELECT v FROM ix WHERE k = 'code1'), 'ix-s2', 5000, 'ix', '1e000000-0000-0000-0000-000000000001', 'usd');
  PERFORM public.exos_gift_card_hold((SELECT v FROM ix WHERE k = 'code2'), 'ix-s3', 5000, 'ix', '1e000000-0000-0000-0000-000000000001', 'usd');
END $$;
RESET ROLE;
DO $$
DECLARE ids uuid[];
BEGIN
  ids := public.exos_fulfill_checkout('ix-s2');
  ASSERT cardinality(ids) = 1, 'I2: the member''s order is fulfilled ('
    || coalesce((SELECT failure_reason FROM public.exos_checkout_sessions WHERE session_id = 'ix-s2'), '-') || ')';
  ASSERT (SELECT status FROM public.exos_gift_card_redemptions WHERE session_id = 'ix-s2') = 'captured', 'I2: card captured';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (SELECT v::uuid FROM ix WHERE k = 'card1')) = 0, 'I2: card spent';
  ASSERT (SELECT price_paid FROM public.exos_tickets WHERE id = ids[1]) = 81, 'I2: the ticket carries the order value (card + charge)';
  ids := public.exos_fulfill_checkout('ix-s3');
  ASSERT coalesce(cardinality(ids), 0) = 0
     AND (SELECT failure_reason FROM public.exos_checkout_sessions WHERE session_id = 'ix-s3') LIKE '%presale%',
    'I2: a non-member''s order fails in the presale';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'ix-s3'), 'I2: nothing minted';
  ASSERT (SELECT status FROM public.exos_gift_card_redemptions WHERE session_id = 'ix-s3') <> 'captured',
    'I2: the failed order captures nothing';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (SELECT v::uuid FROM ix WHERE k = 'card2')) = 5000,
    'I2: the failed order''s card is whole again';
  RAISE NOTICE 'OK  I2 member presale + gift card';
END $$;

-- I3 -------------------------------------------------------------------------
-- run_p0.sh leaves the free tier and the opt-in off, so this event resells.
DO $$
DECLARE v jsonb; r jsonb; c jsonb; o jsonb;
BEGIN
  v := public._exos_dist_partner_create('1e000000-0000-0000-0000-000000000001', 'StubHub', 'stubhub', NULL,
                                        '1e000000-0000-0000-0000-0000000000a0', NULL);
  INSERT INTO ix VALUES ('partner', v->>'id');
  INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
    ('1e000000-0000-0000-0000-0000000000f1', '1e000000-0000-0000-0000-000000000001', 'Box office', 'sk_live_1e1e1e1e',
     repeat('1e', 32), ARRAY['tickets:write'], '1e000000-0000-0000-0000-0000000000a0');
  INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled) VALUES
    ('1e000000-0000-0000-0000-0000000000d4', '1e000000-0000-0000-0000-0000000000e3', '1e000000-0000-0000-0000-000000000001', true),
    ('1e000000-0000-0000-0000-0000000000d5', '1e000000-0000-0000-0000-0000000000e3', '1e000000-0000-0000-0000-000000000001', true),
    ('1e000000-0000-0000-0000-0000000000d1', '1e000000-0000-0000-0000-0000000000e1', '1e000000-0000-0000-0000-000000000001', true);
  ASSERT public.exos_resale_unlocked('1e000000-0000-0000-0000-0000000000e3'), 'I3: the event resells';
  ASSERT public._exos_partner_may_sell('1e000000-0000-0000-0000-0000000000d4', (v->>'id')::uuid), 'I3: GA is offered';
  -- Before last call.
  r := public._exos_partner_reserve('1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000e3',
         (v->>'id')::uuid, NULL, '[{"ticket_type_id":"1e000000-0000-0000-0000-0000000000d4","quantity":2}]', '{}');
  INSERT INTO ix VALUES ('rsv1', r->>'token');
  -- Last call: what is left (two types of 300) is under a threshold of 1000.
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_last_call_threshold('1e000000-0000-0000-0000-0000000000e3', 1000);
  PERFORM pg_temp.act(NULL);
  ASSERT public.exos_event_last_call('1e000000-0000-0000-0000-0000000000e3'), 'I3: last call';
  ASSERT public._exos_partner_ticket_types('1e000000-0000-0000-0000-000000000001', (v->>'id')::uuid,
           '1e000000-0000-0000-0000-0000000000e3') = '[]'::jsonb, 'I3: nothing offered to partners in last call';
  BEGIN
    PERFORM public._exos_partner_reserve('1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000e3',
      (v->>'id')::uuid, NULL, '[{"ticket_type_id":"1e000000-0000-0000-0000-0000000000d4","quantity":1}]', '{}');
    RAISE EXCEPTION 'I3: a partner reserved in last call';
  EXCEPTION WHEN SQLSTATE 'EX422' THEN NULL;
  END;
  -- The reservation made before it still completes (the partner already sold it).
  c := public._exos_partner_reservation_complete('1e000000-0000-0000-0000-000000000001', (v->>'id')::uuid,
         (SELECT ix.v FROM ix WHERE ix.k = 'rsv1'), NULL, NULL);
  ASSERT c->>'status' = 'completed', 'I3: the earlier reservation completes ' || c::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE event_id = '1e000000-0000-0000-0000-0000000000e3'
            AND channel_source LIKE 'partner:%') = 2, 'I3: two partner tickets';
  -- The organizer's own box office (an API key) still sells in last call.
  o := public._exos_partner_reserve('1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000e3',
         NULL, '1e000000-0000-0000-0000-0000000000f1', '[{"ticket_type_id":"1e000000-0000-0000-0000-0000000000d4","quantity":1}]', '{}');
  c := public._exos_partner_reservation_complete('1e000000-0000-0000-0000-000000000001', NULL, o->>'token', NULL, NULL);
  ASSERT c->>'status' = 'completed', 'I3: the box office sells in last call';
  RAISE NOTICE 'OK  I3 partner reservation and last call';
END $$;
-- Seated and timed types aren't offered or reserved (mig 20261101000000 section 5).
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_set_timed_entry('1e000000-0000-0000-0000-0000000000e3', jsonb_build_object(
    'tierIds', jsonb_build_array('1e000000-0000-0000-0000-0000000000d5'),
    'slotMinutes', 60, 'capacity', 10, 'entryWindowMinutes', 30, 'earlyEntryMinutes', 15,
    'hours', (SELECT jsonb_object_agg(g::text, jsonb_build_array(jsonb_build_object('open', '10:00', 'close', '17:00')))
                FROM generate_series(0, 6) g),
    'startDate', (current_date)::text, 'endDate', (current_date + 30)::text));
END $$;
RESET ROLE;
DO $$
DECLARE p uuid := (SELECT v::uuid FROM ix WHERE k = 'partner');
BEGIN
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_last_call_threshold('1e000000-0000-0000-0000-0000000000e3', NULL);
  PERFORM pg_temp.act(NULL);
  ASSERT NOT public.exos_event_last_call('1e000000-0000-0000-0000-0000000000e3'), 'I3: last call off again';
  ASSERT NOT public._exos_partner_may_sell('1e000000-0000-0000-0000-0000000000d5', p), 'I3: a timed type isn''t offered';
  ASSERT NOT public._exos_partner_may_sell('1e000000-0000-0000-0000-0000000000d1', p), 'I3: a seated type isn''t offered';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(public._exos_partner_ticket_types('1e000000-0000-0000-0000-000000000001', p,
            '1e000000-0000-0000-0000-0000000000e3')) x WHERE x->>'id' = '1e000000-0000-0000-0000-0000000000d5') = 0,
    'I3: the timed type isn''t listed';
  ASSERT pg_temp.refused($q$SELECT public._exos_partner_reserve('1e000000-0000-0000-0000-000000000001',
      '1e000000-0000-0000-0000-0000000000e3', NULL, '1e000000-0000-0000-0000-0000000000f1',
      '[{"ticket_type_id":"1e000000-0000-0000-0000-0000000000d5","quantity":1}]', '{}')$q$, 'seats or time slots'),
    'I3: the box office can''t reserve a timed type either';
  ASSERT pg_temp.refused($q$SELECT public._exos_partner_reserve('1e000000-0000-0000-0000-000000000001',
      '1e000000-0000-0000-0000-0000000000e1', NULL, '1e000000-0000-0000-0000-0000000000f1',
      '[{"ticket_type_id":"1e000000-0000-0000-0000-0000000000d1","quantity":1}]', '{}')$q$, 'seats or time slots'),
    'I3: nor a seated one';
  RAISE NOTICE 'OK  I3 seated / timed types stay off reservations';
END $$;

-- I4 -------------------------------------------------------------------------
-- The real free-tier and resale rules (run_p0.sh turns them off), and a block
-- of 40 on a platform Exos can't sync.
DELETE FROM public.exos_platform_settings WHERE key IN ('free_tier_max_capacity', 'resale_consent_required', 'last_call_threshold');
DO $$
DECLARE s jsonb;
BEGIN
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000a1');
  s := public.exos_set_fixed_block('1e000000-0000-0000-0000-0000000000e4', true, 'DICE', 'https://dice.fm/event/ix-block',
         jsonb_build_object('1e000000-0000-0000-0000-0000000000d6', 40), now() + interval '2 days');
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT capacity FROM public.exos_ticket_tiers WHERE id = '1e000000-0000-0000-0000-0000000000d6') = 40, 'I4: the block is the capacity';
  ASSERT public.exos_event_is_free_tier('1e000000-0000-0000-0000-0000000000e4'), 'I4: a block of 40 is the free tier';
  ASSERT NOT public.exos_resale_unlocked('1e000000-0000-0000-0000-0000000000e4'), 'I4: never resold';
  ASSERT (public.exos_event_fee_terms('1e000000-0000-0000-0000-0000000000e4', NULL, 1)->>'free_tier')::boolean,
    'I4: free-tier fee terms';
  -- Exos sells and comps its block.
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_issue_ticket_to_email('1e000000-0000-0000-0000-0000000000e4', '1e000000-0000-0000-0000-0000000000d6',
                                            'door@x.com', 2, 'ix-bo-1');
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'ix-bo-1') = 2, 'I4: box office mints from the block';
  -- Last call near the end of the block keeps Exos (the block's seller) selling.
  PERFORM public.exos_set_last_call_threshold('1e000000-0000-0000-0000-0000000000e4', 50);
  PERFORM pg_temp.act(NULL);
  ASSERT public.exos_event_last_call('1e000000-0000-0000-0000-0000000000e4'), 'I4: last call';
  ASSERT NOT public.exos_last_call_closes('1e000000-0000-0000-0000-0000000000e4', 'exos'), 'I4: Exos isn''t closed';
  ASSERT (SELECT sells_on FROM public.exos_public_event_sales WHERE event_id = '1e000000-0000-0000-0000-0000000000e4') = 'exos',
    'I4: the storefront still sells on Exos (section 1)';
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_issue_ticket_to_email('1e000000-0000-0000-0000-0000000000e4', '1e000000-0000-0000-0000-0000000000d6',
                                            'door2@x.com', 1, 'ix-bo-2');
  -- Released: nothing more mints, comps included.
  PERFORM public.exos_release_fixed_block_now('1e000000-0000-0000-0000-0000000000e4');
  -- (the release also closes the tier, so the box office says sold out; the
  -- ticket trigger refuses any other mint path by the release itself)
  ASSERT pg_temp.refused($q$SELECT public.exos_issue_ticket_to_email('1e000000-0000-0000-0000-0000000000e4',
      '1e000000-0000-0000-0000-0000000000d6', 'late@x.com', 1, 'ix-bo-3')$q$, 'sold out'),
    'I4: no box-office sale after the release';
  ASSERT pg_temp.refused($q$SELECT pg_temp.mint('e4', 'd6', 'ix-late-1', 'box_office')$q$, 'was released'),
    'I4: the ticket trigger refuses a mint after the release';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  I4 free tier + fixed block';
END $$;

-- I5 -------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.act('1e000000-0000-0000-0000-0000000000a0');
  -- Member presale: a staff comp on a presale type passes (owner override).
  PERFORM public.exos_mint_tickets('1e000000-0000-0000-0000-0000000000e2', '1e000000-0000-0000-0000-0000000000d3', 1);
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE tier_id = '1e000000-0000-0000-0000-0000000000d3') = 1,
    'I5: a staff comp passes the member presale';
  -- Seated and timed types take no comps (seats and slots are picked in checkout).
  ASSERT pg_temp.refused($q$SELECT public.exos_mint_tickets('1e000000-0000-0000-0000-0000000000e1',
      '1e000000-0000-0000-0000-0000000000d1', 1)$q$, 'seat picker'), 'I5: no comp on a seated (+ timed) type';
  ASSERT pg_temp.refused($q$SELECT public.exos_mint_tickets('1e000000-0000-0000-0000-0000000000e3',
      '1e000000-0000-0000-0000-0000000000d5', 1)$q$, 'time slot'), 'I5: no comp on a timed type';
  -- After the block's release: no comps either.
  ASSERT pg_temp.refused($q$SELECT pg_temp.mint('e4', 'd6', 'ix-comp-1', 'comp')$q$, 'was released'),
    'I5: no comp after the release';
  -- The same comp row on the presale type passes every trigger.
  PERFORM pg_temp.mint('e2', 'd3', 'ix-comp-2', 'comp');
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  I5 ticket-insert triggers agree on comps';
END $$;

-- I6 -------------------------------------------------------------------------
DO $$
DECLARE s text;
BEGIN
  ASSERT cardinality(public.exos_api_scope_names()) = 18
     AND 'refunds:write' = ANY (public.exos_api_scope_names()) AND 'fans:read' = ANY (public.exos_api_scope_names()),
    'I6: the scope list is the union';
  ASSERT public.exos_role_token_scopes('owner') = public.exos_api_scope_names(), 'I6: an owner''s token may hold every scope';
  ASSERT NOT ('fans:read' = ANY (public.exos_role_token_scopes('manager'))), 'I6: other roles unchanged';
  ASSERT public._exos_api_key_creator_is_owner('1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000f1')
       = public._exos_api_key_owner_ok('1e000000-0000-0000-0000-000000000001', '1e000000-0000-0000-0000-0000000000f1'),
    'I6: one key-owner rule';
  SELECT prosrc INTO s FROM pg_proc WHERE proname = '_exos_api_key_creator_is_owner';
  ASSERT s LIKE '%_exos_api_key_owner_ok%', 'I6: the partner name delegates';
  ASSERT NOT has_function_privilege('anon', 'public._exos_tier_needs_picker(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_tier_needs_picker(uuid)', 'EXECUTE'),
    'I6: the new helper is service-role only';
  RAISE NOTICE 'OK  I6 merged definitions';
END $$;

SELECT '*** INTEGRATION PASSED ***' AS result;
ROLLBACK;
