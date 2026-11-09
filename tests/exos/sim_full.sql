-- ============================================================================
-- End-to-end simulation (claude/exos-e2e-sim, wave 10). One org, two events,
-- driven the way real users drive Exos across the features of waves 1-9,
-- through the public RPCs and the service-role functions the edge functions
-- call (exos-checkout, stripe-webhook, exos-refund, exos-pos, exos-rsvp,
-- exos-api, exos-instant-payouts), as the other sims do. After EVERY step
-- pg_temp.check_invariants() (tests/exos/e2e_helpers.sql) checks:
--   I1 the journal's trial balance is zero per org and currency (raw lines,
--      and exos_journal_trial_balance as the finance member through RLS)
--   I2 every journal entry balances (>= 2 lines, debits = credits = total;
--      the deferred constraint triggers fired)
--   I3 each tier's sold = its live tickets (active / used); each event's
--      tickets_sold = its tiers' sold; no shared pool's tickets + live carts
--      over its size
--   I4 no ticket without an order record: a checkout session (paid, or the
--      $0 order the journal migration records for free claims, comps and
--      RSVPs), a partner reservation (po:) or a POS order (pos:); the
--      exemptions are the journal migration's own: marketplace channels and
--      a phone-only RSVP ("nobody to record")
--   I5 per event, the journal's checkout figures = what src/lib/settlement.ts
--      computes from exos_order_money (gross + gift card part, refunded,
--      organizer net after refunds), and its promoter commissions =
--      settlement.ts's commissions.accruedCents
--   I6 the step's money and access actions each wrote exactly one
--      exos_org_audit row with the expected actor kind (the multiset of
--      action:actor_kind since the last step = the expected one; nothing
--      else either)
--   I7 no exos_org_audit row and no journal memo holds an email or a phone
--   I8 the other org's owner reads none of org A's rows through RLS beyond
--      what anon reads (the public catalog), nor its trial balance or audit
--   I9 gift cards outstanding in the journal = the cards' balances (+ holds)
--   I10 the sales tax report's net = the journal's sales tax payable, per org,
--       currency, period (all time and split at the median tax entry) and event
-- Steps E2E-0..33 run in order; each RAISEs 'OK  E2E-n ...'. A real bug the
-- simulation found is FIXED in mig 20261111100000 and its step is the
-- regression test (E2E-2, E2E-2b).
-- Self-contained (ids md5('e2e:' || x)), BEGIN / ROLLBACK. Runs at the end
-- of run_p0.sh. Races across these flows: tests/exos/race_full.sh (CI).
-- Users: oa owner A, ma manager A, fa finance A, sa scanner A, ob owner B,
--        b1..b8 buyers, h1 group host, f1 / f2 friends.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Helpers and the invariants: tests/exos/e2e_helpers.sql (shared with race_full.sh).
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT md5('e2e:' || p)::uuid $$;
\ir e2e_helpers.sql

-- Fixtures: the accounts and the orgs (before the first step) -------------------
INSERT INTO auth.users (id, email, email_confirmed_at)
SELECT pg_temp.u(x), 'e2e-' || x || '@x.com', now()
  FROM unnest(ARRAY['oa', 'ma', 'fa', 'sa', 'ob', 'b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8', 'h1', 'f1', 'f2', 'bb']) x;
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('A'), 'E2E Hall', 'e2e-hall', pg_temp.u('oa')),
  (pg_temp.u('B'), 'E2E Other', 'e2e-other', pg_temp.u('ob'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('A'), pg_temp.u('oa'), 'owner'), (pg_temp.u('A'), pg_temp.u('ma'), 'manager'),
  (pg_temp.u('A'), pg_temp.u('fa'), 'finance'), (pg_temp.u('A'), pg_temp.u('sa'), 'scanner'),
  (pg_temp.u('B'), pg_temp.u('ob'), 'owner');
-- Fees on (the free period is over); org A recovers lost disputes (server-written).
UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day' WHERE org_id IN (pg_temp.u('A'), pg_temp.u('B'));
UPDATE public.exos_org_billing SET recover_lost_disputes = true WHERE org_id = pg_temp.u('A');
-- The harness has no phase-1 exos_org_secrets (Stripe Connect): its prod shape, rolled back.
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.exos_org_secrets (org_id, payments) VALUES
  (pg_temp.u('A'), '{"connectedAccountId":"acct_e2eOrgA","chargesEnabled":true}')
ON CONFLICT (org_id) DO UPDATE SET payments = EXCLUDED.payments;
-- Org B: its own show and one sale (so the cross-org check has rows to hide).
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e9'), pg_temp.u('B'), 'E2E Elsewhere', 'e2e-elsewhere', 'published', now() + interval '5 days', 100, 0, 'usd', pg_temp.u('ob'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold) VALUES
  (pg_temp.u('t9'), pg_temp.u('e9'), 'B GA', 30, 100, 0);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents,
            currency, status, application_fee_cents, exos_fee_cents, card_fee_est_cents, processor)
VALUES ('cs_e2e_orgb', pg_temp.u('e9'), pg_temp.u('t9'), pg_temp.u('B'), pg_temp.u('bb'), 'e2e-bb@x.com', 1, 3000, 'usd', 'pending', 150, 60, 90, 'stripe');
SELECT cardinality(pg_temp.paid('cs_e2e_orgb')) AS org_b_tickets;
-- Org A's ticketing partner (distribution), as an org admin made it.
INSERT INTO public.exos_distribution_partners (id, org_id, label, partner_type, key_prefix, key_hash, scopes) VALUES
  (pg_temp.u('p1'), pg_temp.u('A'), 'E2E Partner', 'vivid', 'dk_live_e2eaaaa1', repeat('e2', 32), ARRAY['inventory']);
SELECT pg_temp.put('audit_mark', (SELECT coalesce(max(id), 0) FROM public.exos_org_audit)::text);
SELECT pg_temp.check_invariants('E2E-0 fixtures');

-- ============================================================================
-- 1. Organizer setup (the dashboard: the owner, under RLS)
-- ============================================================================
-- E2E-1 two events: e1 tonight (doors open), e2 in ten days; their types.
SELECT pg_temp.act('oa');
SET ROLE authenticated;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, ends_at, timezone, total_tickets, currency, created_by,
                                purchase_limits, refund_policy) VALUES
  (pg_temp.u('e1'), pg_temp.u('A'), 'E2E Night', 'e2e-night', 'published', now() + interval '2 hours', now() - interval '1 hour',
   now() + interval '8 hours', 'UTC', 400, 'usd', pg_temp.u('oa'), '{"maxPerOrder": 8}', 'until_start'),
  (pg_temp.u('e2'), pg_temp.u('A'), 'E2E Matinee', 'e2e-matinee', 'published', now() + interval '10 days', NULL,
   NULL, 'UTC', 100, 'usd', pg_temp.u('oa'), NULL, 'until_start');
-- GA (price steps + a door price, set next), VIP + Balcony (one shared pool),
-- Gallery (timed entry), Free (RSVPs and free claims); e2's GA.
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  (pg_temp.u('ga'), pg_temp.u('e1'), 'GA', 40, 100, 0, 'public', 1),
  (pg_temp.u('vip'), pg_temp.u('e1'), 'VIP', 80, 10, 0, 'public', 2),
  (pg_temp.u('bal'), pg_temp.u('e1'), 'Balcony', 60, 10, 0, 'public', 3),
  (pg_temp.u('gal'), pg_temp.u('e1'), 'Gallery', 25, 40, 0, 'public', 4),
  (pg_temp.u('fr'), pg_temp.u('e1'), 'Free', 0, 50, 0, 'public', 5),
  (pg_temp.u('g2'), pg_temp.u('e2'), 'Matinee GA', 50, 100, 0, 'public', 1);
RESET ROLE;
SELECT pg_temp.check_invariants('E2E-1 setup: two events, six ticket types (dashboard)',
  ARRAY['event.create:user', 'event.create:user', 'tier.create:user', 'tier.create:user', 'tier.create:user',
        'tier.create:user', 'tier.create:user', 'tier.create:user']);

-- E2E-2 price steps on GA (Early $30 for the first 8, then $40), set on the
-- dashboard: ONE audit row, with the price written back ([40, 30]).
-- (FIXED, mig 20261111100000: it was three rows, the tier trigger logging
-- the RPC's own writes as tier.update.)
SELECT pg_temp.act('oa');
SET ROLE authenticated;
SELECT 1 FROM public.exos_set_price_steps(pg_temp.u('ga'),
  '[{"name":"Early","price_cents":3000,"ends_after_count":8},{"name":"Regular","price_cents":4000}]'::jsonb);
RESET ROLE;
DO $$
DECLARE c jsonb := public.exos_tier_current_price(pg_temp.u('ga'), now(), 'online');
BEGIN
  ASSERT (c ->> 'price_cents')::int = 3000 AND c ->> 'step_id' IS NOT NULL, 'E2E-2 the first step is on sale: ' || c::text;
  PERFORM pg_temp.put('step_early', c ->> 'step_id');
  PERFORM pg_temp.put('step_regular', (SELECT id::text FROM public.exos_price_steps WHERE tier_id = pg_temp.u('ga') AND price_cents = 4000));
  ASSERT (SELECT changes FROM public.exos_org_audit WHERE org_id = pg_temp.u('A') AND action = 'tier.price_steps' ORDER BY id DESC LIMIT 1)
         = '{"price": [40, 30], "price_steps": [null, 2]}'::jsonb,
    'E2E-2 the row: ' || (SELECT changes::text FROM public.exos_org_audit WHERE org_id = pg_temp.u('A') AND action = 'tier.price_steps' ORDER BY id DESC LIMIT 1);
END $$;
SELECT pg_temp.check_invariants('E2E-2 setup: price steps on GA (dashboard)', ARRAY['tier.price_steps:user']);

-- E2E-2b the box-office system sets GA's $45 door price through the API (PUT
-- /v1/events/:id/ticket-types/:id/price-steps, a key the manager made):
-- one row, the key as actor, [old, new].
DO $$
BEGIN
  PERFORM pg_temp.act('ma');
  PERFORM public.exos_create_api_key(pg_temp.u('A'), 'Box office sync', ARRAY['events:read', 'events:write']);
  PERFORM pg_temp.act(NULL);
  PERFORM public._exos_api_price_steps_set(pg_temp.u('A'), (SELECT id FROM public.exos_api_keys WHERE org_id = pg_temp.u('A') AND name = 'Box office sync'),
                                           pg_temp.u('e1'), pg_temp.u('ga'), '{"door_price_cents": 4500}');
  ASSERT (SELECT door_price_cents FROM public.exos_ticket_tiers WHERE id = pg_temp.u('ga')) = 4500, 'E2E-2b door price';
  ASSERT (SELECT changes FROM public.exos_org_audit WHERE org_id = pg_temp.u('A') AND action = 'tier.price_steps' ORDER BY id DESC LIMIT 1)
         = '{"door_price_cents": [null, 4500], "price_steps": [null, null]}'::jsonb,
    'E2E-2b the row: ' || (SELECT changes::text FROM public.exos_org_audit WHERE org_id = pg_temp.u('A') AND action = 'tier.price_steps' ORDER BY id DESC LIMIT 1);
END $$;
SELECT pg_temp.check_invariants('E2E-2b setup: the door price through the API', ARRAY['api_key.create:user', 'tier.price_steps:api_key']);

-- E2E-3 a shared capacity pool: VIP + Balcony, 6 places between them.
SELECT pg_temp.act('oa');
SET ROLE authenticated;
INSERT INTO public.exos_quotas (id, event_id, org_id, name, size) VALUES (pg_temp.u('q1'), pg_temp.u('e1'), pg_temp.u('A'), 'Floor', 6);
INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES (pg_temp.u('q1'), pg_temp.u('vip')), (pg_temp.u('q1'), pg_temp.u('bal'));
RESET ROLE;
DO $$
BEGIN
  ASSERT public.exos_effective_available(pg_temp.u('vip')) = 6 AND public.exos_effective_available(pg_temp.u('bal')) = 6,
    'E2E-3 the pool caps both types at 6';
END $$;
SELECT pg_temp.check_invariants('E2E-3 setup: a shared pool across VIP and Balcony',
  ARRAY['quota.create:user', 'quota.tier_add:user', 'quota.tier_add:user']);

-- E2E-4 checkout questions on GA (one conditional) and timed entry on Gallery.
SELECT pg_temp.act('oa');
SET ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_save_event_question(pg_temp.u('e1'), jsonb_build_object('label', 'Bringing a guest?', 'kind', 'single_choice',
         'options', jsonb_build_array('Yes', 'No'), 'required', true, 'scope', 'order', 'tier_ids', jsonb_build_array(pg_temp.u('ga'))));
  PERFORM pg_temp.put('q_guest', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), jsonb_build_object('label', 'Guest name', 'kind', 'text', 'required', true,
         'scope', 'order', 'tier_ids', jsonb_build_array(pg_temp.u('ga')),
         'parent_question_id', pg_temp.v('q_guest'), 'parent_values', jsonb_build_array('Yes')));
  PERFORM pg_temp.put('q_gname', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), jsonb_build_object('label', 'T-shirt size', 'kind', 'single_choice',
         'options', jsonb_build_array('S', 'M', 'L'), 'scope', 'ticket', 'tier_ids', jsonb_build_array(pg_temp.u('ga'))));
  PERFORM pg_temp.put('q_size', r ->> 'id');
  PERFORM public.exos_set_timed_entry(pg_temp.u('e1'), jsonb_build_object(
    'tierIds', jsonb_build_array(pg_temp.u('gal')), 'slotMinutes', 60, 'capacity', 10, 'entryWindowMinutes', 30, 'earlyEntryMinutes', 15,
    'hours', (SELECT jsonb_object_agg(g::text, jsonb_build_array(jsonb_build_object('open', '00:00', 'close', '23:00'))) FROM generate_series(0, 6) g),
    'startDate', (current_date)::text, 'endDate', (current_date + 3)::text));
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT public._exos_tier_is_timed(pg_temp.u('gal')), 'E2E-4 Gallery is timed';
  PERFORM pg_temp.put('slot', (SELECT slot_id FROM public.exos_public_event_slots(pg_temp.u('e1'), current_date + 1, current_date + 1)
                                WHERE slot_time = '10:00' AND remaining = 10 AND NOT closed));
  ASSERT pg_temp.v('slot') IS NOT NULL, 'E2E-4 a 10:00 slot tomorrow';
  ASSERT (SELECT count(*) FROM public.exos_event_questions WHERE event_id = pg_temp.u('e1')) = 3, 'E2E-4 three questions';
END $$;
SELECT pg_temp.check_invariants('E2E-4 setup: checkout questions (one conditional) and a timed-entry type');

-- E2E-5 add-ons: a VIP lounge pass with its own entry code (and its door
-- list) and a plain poster; the promoter with 10% commission.
SELECT pg_temp.act('oa');
SET ROLE authenticated;
INSERT INTO public.exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode) VALUES
  (pg_temp.u('ad1'), pg_temp.u('e1'), 'VIP lounge', 30, 50, true),
  (pg_temp.u('ad2'), pg_temp.u('e1'), 'Poster', 10, 50, false);
INSERT INTO public.exos_checkin_lists (id, event_id, org_id, name, admits, addon_ids, allow_reentry, sort_order) VALUES
  (pg_temp.u('ll'), pg_temp.u('e1'), pg_temp.u('A'), 'VIP lounge', 'addons', ARRAY[pg_temp.u('ad1')], false, 1);
SELECT pg_temp.put('promoter', public.exos_upsert_promoter(pg_temp.u('A'), 'e2e-promo', 'E2E Promo')::text);
RESET ROLE;
DO $$
BEGIN
  PERFORM pg_temp.act('oa');
  PERFORM public.exos_set_promoter_terms((SELECT id FROM public.exos_promoters WHERE org_id = pg_temp.u('A') AND code = 'e2e-promo'), 1000, 0);
  PERFORM pg_temp.act(NULL);
END $$;
SELECT pg_temp.check_invariants('E2E-5 setup: add-ons (one with its own entry code) and a promoter');

-- E2E-6 a gift card: b3 buys a $50 card online (exos-commerce, then the
-- webhook's fulfilment issues it).
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, amount_cents, currency, details, application_fee_cents, status)
  VALUES ('cs_e2e_gc1', pg_temp.u('A'), 'gift_card', 5000, 'usd', '{"amount_cents":5000}', 250, 'pending');
  r := public._exos_gift_card_issue(pg_temp.u('A'), NULL, 5000, 'usd', 'online', 'card', 'cs_e2e_gc1', NULL, pg_temp.u('b3'),
                                    'e2e-b3@x.com', NULL, NULL, NULL, false);
  UPDATE public.exos_commerce_orders SET status = 'fulfilled', result_id = (r ->> 'card_id')::uuid, fulfilled_at = now() WHERE session_id = 'cs_e2e_gc1';
  PERFORM pg_temp.put('gc', r ->> 'card_id');
  PERFORM pg_temp.put('gc_code', r ->> 'code');
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (r ->> 'card_id')::uuid) = 5000, 'E2E-6 $50 on the card';
END $$;
SELECT pg_temp.check_invariants('E2E-6 setup: a $50 gift card sold online');

-- E2E-7 an API key with finance scopes, for the books sync (owners and
-- managers make keys; the key acts with its creator's role).
SELECT pg_temp.act('oa');
SET ROLE authenticated;
SELECT pg_temp.put('api_secret', public.exos_create_api_key(pg_temp.u('A'), 'Books sync', ARRAY['finance:read', 'finance:write']));
RESET ROLE;
DO $$
BEGIN
  PERFORM pg_temp.put('api_key', (SELECT id::text FROM public.exos_api_keys WHERE org_id = pg_temp.u('A') AND name = 'Books sync'));
  -- exos-api authenticates by the secret's sha256.
  ASSERT (public.exos_api_key_auth(encode(extensions.digest(pg_temp.v('api_secret'), 'sha256'), 'hex')) ->> 'org_id')::uuid = pg_temp.u('A'),
    'E2E-7 the secret authenticates';
  ASSERT (SELECT scopes @> ARRAY['finance:write'] AND created_by = pg_temp.u('oa') FROM public.exos_api_keys WHERE id = pg_temp.v('api_key')::uuid),
    'E2E-7 the key: finance scopes, made by the owner';
END $$;
SELECT pg_temp.check_invariants('E2E-7 setup: an API key with finance scopes', ARRAY['api_key.create:user']);

-- ============================================================================
-- 2. Sales
-- ============================================================================
-- E2E-8 online checkout: b1, 2 × GA at the Early step + the VIP lounge pass,
-- through the promoter's link, answering the questions (the conditional one
-- shown); Stripe's webhook fulfils it.
DO $$
DECLARE cp jsonb; v_hold uuid; v_ids uuid[];
BEGIN
  cp := public.exos_tier_current_price(pg_temp.u('ga'), now(), 'online');
  PERFORM pg_temp.act('b1');
  v_hold := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('ga'), 2);
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_hold_lock_price(v_hold, (cp ->> 'step_id')::uuid, (cp ->> 'price_cents')::int);
  PERFORM pg_temp.sess('cs_e2e_b1', 'e1', 'ga', 'b1', 'e2e-b1@x.com', 2, 2 * 3000 + 3000, 405, 180,
                       jsonb_build_array(jsonb_build_object('addon_id', pg_temp.u('ad1'), 'quantity', 1, 'unit_price_cents', 3000, 'name', 'VIP lounge')),
                       'e2e-promo', (cp ->> 'step_id')::uuid);
  ASSERT public.exos_record_checkout_answers('cs_e2e_b1', jsonb_build_object(
           'order', jsonb_build_object(pg_temp.v('q_guest'), 'Yes', pg_temp.v('q_gname'), 'Sam'),
           'tickets', jsonb_build_array(jsonb_build_object(pg_temp.v('q_size'), 'M'), jsonb_build_object(pg_temp.v('q_size'), 'L')))) IS NOT NULL,
         'E2E-8 answers recorded';
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2e_b1' WHERE id = v_hold;
  v_ids := pg_temp.paid('cs_e2e_b1');
  ASSERT cardinality(v_ids) = 2, 'E2E-8 two tickets';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE id = ANY (v_ids) AND price_step_id = (cp ->> 'step_id')::uuid) = 2, 'E2E-8 on the Early step';
  ASSERT (SELECT count(*) FROM public.exos_addon_passes p JOIN public.exos_order_addons a ON a.id = p.order_addon_id
           WHERE a.order_ref = 'cs_e2e_b1') = 1, 'E2E-8 the lounge pass issued';
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'cs_e2e_b1') = 4, 'E2E-8 four answers kept';
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions WHERE session_id = 'cs_e2e_b1' AND status = 'accrued') > 0,
         'E2E-8 the promoter earns';
  PERFORM pg_temp.put('b1_tickets', array_to_string(v_ids, ','));
END $$;
SELECT pg_temp.check_invariants('E2E-8 sale: online checkout (price step, add-on, promoter, conditional answers)');

-- E2E-9 guest checkout: no account, VIP × 1 (the shared pool).
DO $$
DECLARE v_hold uuid; v_ids uuid[];
BEGIN
  PERFORM pg_temp.act(NULL);
  v_hold := public.exos_create_guest_hold(pg_temp.u('e1'), pg_temp.u('vip'), 1, 'e2e-guest@x.com', 'iphash-e2e-guest');
  PERFORM pg_temp.sess('cs_e2e_guest', 'e1', 'vip', NULL, 'e2e-guest@x.com', 1, 8000, 360, 120);
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2e_guest' WHERE id = v_hold;
  v_ids := pg_temp.paid('cs_e2e_guest');
  ASSERT cardinality(v_ids) = 1 AND (SELECT owner_id IS NULL OR buyer_email = 'e2e-guest@x.com' FROM public.exos_tickets WHERE id = v_ids[1]),
    'E2E-9 one guest ticket';
  ASSERT public.exos_effective_available(pg_temp.u('bal')) = 5, 'E2E-9 the pool has 5 left for Balcony too';
END $$;
SELECT pg_temp.check_invariants('E2E-9 sale: guest checkout on a pooled type');

-- E2E-10 a gift card redemption: b3, Balcony × 1 ($60): $20 from the card, $40 by card,
-- $4.80 sales tax inside it (E2E-22 hands its shares back: I10).
DO $$
DECLARE v_hold uuid; v_ids uuid[]; q jsonb;
BEGIN
  q := public.exos_gift_card_quote(pg_temp.v('gc_code'), 'e2e-b3', pg_temp.u('A'), 'usd', 2000);
  PERFORM pg_temp.act('b3');
  v_hold := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('bal'), 1);
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.sess('cs_e2e_gift', 'e1', 'bal', 'b3', 'e2e-b3@x.com', 1, 4000, 300, 120, NULL, NULL, NULL, NULL, 2000, 480);
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2e_gift' WHERE id = v_hold;
  PERFORM public.exos_gift_card_hold(pg_temp.v('gc_code'), 'cs_e2e_gift', 2000, 'e2e-b3', pg_temp.u('A'), 'usd');
  v_ids := pg_temp.paid('cs_e2e_gift');
  ASSERT cardinality(v_ids) = 1, 'E2E-10 one ticket';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = pg_temp.v('gc')::uuid) = 3000, 'E2E-10 $30 left on the card';
  ASSERT (SELECT status FROM public.exos_gift_card_redemptions WHERE session_id = 'cs_e2e_gift') = 'captured', 'E2E-10 captured at fulfilment';
END $$;
SELECT pg_temp.check_invariants('E2E-10 sale: part gift card, part card');

-- E2E-11 timed entry: b5, Gallery × 1 in tomorrow's 10:00 slot.
DO $$
DECLARE v_hold uuid; v_ids uuid[];
BEGIN
  PERFORM pg_temp.act('b5');
  v_hold := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('gal'), 1);
  PERFORM pg_temp.act(NULL);
  ASSERT public.exos_attach_hold_slot(v_hold, pg_temp.v('slot')), 'E2E-11 the hold takes the slot';
  PERFORM pg_temp.sess('cs_e2e_timed', 'e1', 'gal', 'b5', 'e2e-b5@x.com', 1, 2500, 175, 75, NULL, NULL, NULL, pg_temp.v('slot'));
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2e_timed' WHERE id = v_hold;
  v_ids := pg_temp.paid('cs_e2e_timed');
  ASSERT cardinality(v_ids) = 1 AND (SELECT slot_id FROM public.exos_tickets WHERE id = v_ids[1]) = pg_temp.v('slot'), 'E2E-11 the ticket is for the slot';
END $$;
SELECT pg_temp.check_invariants('E2E-11 sale: a timed-entry slot');

-- E2E-12 e2's sales (cancelled later): b2 × 2 through the promoter, b8 × 1.
DO $$
DECLARE v_hold uuid;
BEGIN
  PERFORM pg_temp.act('b2');
  v_hold := public.exos_create_hold(pg_temp.u('e2'), pg_temp.u('g2'), 2);
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.sess('cs_e2e_m1', 'e2', 'g2', 'b2', 'e2e-b2@x.com', 2, 10000, 450, 200, NULL, 'e2e-promo');
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2e_m1' WHERE id = v_hold;
  ASSERT cardinality(pg_temp.paid('cs_e2e_m1')) = 2, 'E2E-12 b2';
  PERFORM pg_temp.act('b8');
  v_hold := public.exos_create_hold(pg_temp.u('e2'), pg_temp.u('g2'), 1);
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.sess('cs_e2e_m2', 'e2', 'g2', 'b8', 'e2e-b8@x.com', 1, 5000, 225, 100);
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2e_m2' WHERE id = v_hold;
  ASSERT cardinality(pg_temp.paid('cs_e2e_m2')) = 1, 'E2E-12 b8';
END $$;
SELECT pg_temp.check_invariants('E2E-12 sale: two orders for the matinee');

-- E2E-13 group pay: h1 holds 3 GA seats for friends; f1 and f2 pay their
-- own seat, the host covers the last one. The group locks the Early price.
-- Group pay v2 is paused (operator 2026-11-09, mig 20261111120000): the step
-- turns the switch on for itself and off after it (the audit row it writes is
-- the platform's, nil org, outside I6's two orgs).
SELECT public.exos_set_group_pay_enabled(true, 'sim_full.sql: E2E-13');
DO $$
DECLARE r jsonb; v_g uuid; v_ctx jsonb; v_hold uuid; v_ans jsonb;
BEGIN
  PERFORM pg_temp.act('h1');
  r := public.exos_group_buy_start(pg_temp.u('e1'), pg_temp.u('ga'), 3);
  v_g := (r ->> 'id')::uuid;
  PERFORM pg_temp.put('group', v_g::text);
  PERFORM pg_temp.act(NULL);
  v_ans := jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_guest'), 'No'));
  -- Each friend: exos-checkout's seat context, claim, session, attach, answers; then the webhook.
  FOR i IN 1..2 LOOP
    v_ctx := public.exos_group_checkout_ctx((SELECT token FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = i), NULL,
                                            pg_temp.u('f' || i));
    ASSERT (v_ctx ->> 'quantity')::int = 1, 'E2E-13 one seat per link';
    v_hold := public.exos_group_claim((SELECT token FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = i), NULL,
                                      pg_temp.u('f' || i), 'e2e-f' || i || '@x.com', pg_temp.u('e1'), pg_temp.u('ga'), 1);
    PERFORM pg_temp.sess('cs_e2e_f' || i, 'e1', 'ga', 'f' || i, 'e2e-f' || i || '@x.com', 1, 3000, 165, 75, NULL, NULL,
                         (SELECT price_step_id FROM public.exos_cart_holds WHERE id = v_hold));
    PERFORM public.exos_group_attach('cs_e2e_f' || i, (SELECT token FROM public.exos_group_buy_seats WHERE group_id = v_g AND seat_no = i), NULL);
    PERFORM public.exos_record_checkout_answers('cs_e2e_f' || i, v_ans);
    ASSERT cardinality(pg_temp.paid('cs_e2e_f' || i)) = 1, 'E2E-13 friend ' || i || ' paid their seat';
  END LOOP;
  -- The host covers the rest (one seat).
  v_ctx := public.exos_group_checkout_ctx(NULL, v_g, pg_temp.u('h1'));
  ASSERT (v_ctx ->> 'quantity')::int = 1, 'E2E-13 one seat left to cover: ' || v_ctx::text;
  v_hold := public.exos_group_claim(NULL, v_g, pg_temp.u('h1'), 'e2e-h1@x.com', pg_temp.u('e1'), pg_temp.u('ga'), 1);
  PERFORM pg_temp.sess('cs_e2e_cover', 'e1', 'ga', 'h1', 'e2e-h1@x.com', 1, 3000, 165, 75, NULL, NULL,
                       (SELECT price_step_id FROM public.exos_cart_holds WHERE id = v_hold));
  PERFORM public.exos_group_attach('cs_e2e_cover', NULL, v_g);
  PERFORM public.exos_record_checkout_answers('cs_e2e_cover', v_ans);
  ASSERT cardinality(pg_temp.paid('cs_e2e_cover')) = 1, 'E2E-13 the host''s cover';
  ASSERT (SELECT status FROM public.exos_group_buys WHERE id = v_g) = 'closed', 'E2E-13 every seat paid: closed';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref IN ('cs_e2e_f1', 'cs_e2e_f2', 'cs_e2e_cover') AND status = 'active'
             AND price_step_id = pg_temp.v('step_early')::uuid) = 3, 'E2E-13 three seats on the Early step';
END $$;
SELECT pg_temp.check_invariants('E2E-13 sale: group pay, two friends and the host''s cover', ARRAY['order.group_cover:user']);
SELECT public.exos_set_group_pay_enabled(false, 'sim_full.sql: E2E-13 done');

-- E2E-14 a partner reservation with answers (exos-api /v1/partner), completed.
INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled) VALUES (pg_temp.u('ga'), pg_temp.u('e1'), pg_temp.u('A'), true);
DO $$
DECLARE r jsonb; c jsonb;
BEGIN
  r := public._exos_partner_reserve(pg_temp.u('A'), pg_temp.u('e1'), pg_temp.u('p1'), NULL,
         jsonb_build_array(jsonb_build_object('ticket_type_id', pg_temp.u('ga'), 'quantity', 2)),
         jsonb_build_object('answers', jsonb_build_object(
           'order', jsonb_build_object(pg_temp.v('q_guest'), 'No'),
           'tickets', jsonb_build_array(jsonb_build_object(pg_temp.v('q_size'), 'S'), '{}'::jsonb))), false, false);
  ASSERT r ->> 'token' IS NOT NULL, 'E2E-14 reserved: ' || r::text;
  c := public._exos_partner_reservation_complete(pg_temp.u('A'), pg_temp.u('p1'), r ->> 'token', NULL, 'https://exos.test');
  ASSERT jsonb_array_length(c -> 'order' -> 'tickets') = 2 AND c ->> 'status' = 'completed', 'E2E-14 two tickets: ' || c::text;
  ASSERT (c -> 'order' -> 'order_items' -> 0 ->> 'price')::numeric = 30, 'E2E-14 at the Early price';
  PERFORM pg_temp.put('res', (SELECT id::text FROM public.exos_partner_reservations WHERE token = r ->> 'token'));
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'po:' || pg_temp.v('res') AND attached_at IS NOT NULL) = 2,
    'E2E-14 the answers kept and attached';
END $$;
SELECT pg_temp.check_invariants('E2E-14 sale: a partner reservation with answers');

-- E2E-15 the door: the scanner opens a drawer ($100 float) and sells a GA
-- for cash at the door price; the manager comps one; a rushed sale skips
-- the questions (logged).
SELECT pg_temp.act('sa');
SET ROLE authenticated;
INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('dr'), pg_temp.u('e1'), 10000);
RESET ROLE;
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('sa');
  r := public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('ga'), 1, pg_temp.u('k-cash'), 0, 'cash', NULL, pg_temp.u('dr'),
                                   'Walk Up', NULL, jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_guest'), 'No')), NULL, false);
  ASSERT r ->> 'status' = 'paid' AND (r ->> 'total_cents')::int = 4500, 'E2E-15 cash sale at the door price: ' || r::text;
  PERFORM pg_temp.put('pos_cash', r ->> 'id');
  PERFORM pg_temp.act('ma');
  r := public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('ga'), 1, pg_temp.u('k-comp'), 1, 'cash', NULL, NULL,
                                   'Band guest', NULL, jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_guest'), 'No')), 'band guest', false);
  ASSERT r ->> 'payment_method' = 'comp' AND (r -> 'tenders' ->> 'cash')::int = 0 AND (r -> 'tenders' ->> 'comp')::int = 4500,
    'E2E-15 a comp at the door: ' || r::text;
  PERFORM pg_temp.put('pos_comp', r ->> 'id');
  PERFORM pg_temp.act('sa');
  r := public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('ga'), 2, pg_temp.u('k-skip'), 0, 'cash', NULL, pg_temp.u('dr'),
                                   'In a hurry', NULL, NULL, NULL, true);
  ASSERT r ->> 'status' = 'paid' AND (r ->> 'questions_skipped')::boolean, 'E2E-15 sold with the questions skipped: ' || r::text;
  PERFORM pg_temp.put('pos_skip', r ->> 'id');
  ASSERT (SELECT skipped_by FROM public.exos_pos_question_skips WHERE pos_order_id = (r ->> 'id')::uuid) = pg_temp.u('sa'), 'E2E-15 who skipped';
  PERFORM pg_temp.act(NULL);
END $$;
SELECT pg_temp.check_invariants('E2E-15 sale: the door (cash, a comp, skipped questions)');

-- E2E-16 a card sale at the door through Stripe Terminal: the reader, the
-- PaymentIntent, the capture, and the webhook's completion (2 × VIP).
DO $$
DECLARE r jsonb; v_o uuid; v_dev uuid; v_plan jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  PERFORM public._exos_pos_terminal_save_location(pg_temp.u('oa'), pg_temp.u('A'), false, 'tml_e2eOrgA', 'E2E box office', '{"line1":"1 Main St"}');
  r := public._exos_pos_terminal_save_reader(pg_temp.u('oa'), pg_temp.u('A'), false, 'tmr_e2eDoor', 'Door 1', 'stripe_s700', NULL);
  v_dev := (r ->> 'device_id')::uuid;
  r := public._exos_pos_walkup_begin_card(pg_temp.u('sa'), pg_temp.u('e1'), pg_temp.u('vip'), 2, pg_temp.u('k-card'),
                                          NULL, 'Card Buyer', NULL, NULL, false);
  v_o := (r ->> 'id')::uuid;
  v_plan := public._exos_pos_card_begin(pg_temp.u('sa'), v_o, 'reader', v_dev, false);
  PERFORM public._exos_pos_card_attach(v_o, 'pi_e2eCard1', (v_plan ->> 'amount_cents')::int, v_plan ->> 'currency', 480, 200, 280, 300);
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_e2eCard1') ->> 'action' = 'capture', 'E2E-16 capture';
  r := public._exos_pos_card_complete(v_o, 'pi_e2eCard1', (v_plan ->> 'amount_cents')::int, 'webhook', 'evt_e2eCard1');
  ASSERT r ->> 'status' = 'paid', 'E2E-16 paid by card: ' || r::text;
  -- Stripe redelivers the event: the same sale.
  r := public._exos_pos_card_complete(v_o, 'pi_e2eCard1', (v_plan ->> 'amount_cents')::int, 'webhook', 'evt_e2eCard1');
  ASSERT (r ->> 'replay')::boolean, 'E2E-16 the replay is a no-op';
  PERFORM pg_temp.put('pos_card', v_o::text);
  ASSERT public.exos_effective_available(pg_temp.u('bal')) = 2, 'E2E-16 the pool: 4 of 6 used';
END $$;
SELECT pg_temp.check_invariants('E2E-16 sale: card at the door (Stripe Terminal, webhook replayed)');

-- E2E-17 RSVPs on the Free type (exos-rsvp, service role): a phone-only one
-- and one with an email and a plus-one.
DO $$
BEGIN
  PERFORM pg_temp.act('oa');
  PERFORM public.exos_set_phone_rsvp(pg_temp.u('e1'), true, pg_temp.u('fr'), 1);
  PERFORM pg_temp.act(NULL);
END $$;
SET ROLE service_role;
DO $$
DECLARE r jsonb; v jsonb;
BEGIN
  r := public.exos_phone_rsvp_start(pg_temp.u('e1'), 'Ana', '(212) 555-0176', NULL, 0, NULL, true);
  v := public.exos_phone_rsvp_verify((r ->> 'rsvp_id')::uuid, r ->> 'code', 'https://exos.test');
  ASSERT (v ->> 'ok')::boolean AND jsonb_array_length(v -> 'tickets') = 1, 'E2E-17 phone-only RSVP: ' || v::text;
  r := public.exos_phone_rsvp_start(pg_temp.u('e1'), 'Ben', '(212) 555-0177', 'e2e-ben@x.com', 1, NULL, true);
  v := public.exos_phone_rsvp_verify((r ->> 'rsvp_id')::uuid, r ->> 'code', 'https://exos.test');
  ASSERT (v ->> 'ok')::boolean AND jsonb_array_length(v -> 'tickets') = 2, 'E2E-17 RSVP with email +1: ' || v::text;
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT quantity FROM public.exos_checkout_sessions WHERE event_id = pg_temp.u('e1') AND free_kind = 'rsvp') = 2,
    'E2E-17 the emailed RSVP is one $0 order of 2';
END $$;
SELECT pg_temp.check_invariants('E2E-17 sale: RSVPs (phone-only, and email with a plus-one)');

-- E2E-18 a free claim: b4 claims 2 × Free.
DO $$
BEGIN
  PERFORM pg_temp.act('b4');
  ASSERT cardinality(public.exos_claim_free_tickets(pg_temp.u('e1'), pg_temp.u('fr'), 2)) = 2, 'E2E-18 two free tickets';
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT quantity FROM public.exos_checkout_sessions WHERE event_id = pg_temp.u('e1') AND free_kind = 'free_claim' AND buyer_uid = pg_temp.u('b4')) = 2,
    'E2E-18 one $0 order';
END $$;
SELECT pg_temp.check_invariants('E2E-18 sale: a free claim');

-- E2E-19 a comp batch: the owner comps two GA to two emails (one has an account).
DO $$
BEGIN
  PERFORM pg_temp.act('oa');
  PERFORM public.exos_issue_comp_batch(pg_temp.u('e1'), pg_temp.u('ga'), ARRAY['e2e-b7@x.com', 'e2e-press@x.com'], 1, NULL);
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT count(*) FROM public.exos_checkout_sessions WHERE event_id = pg_temp.u('e1') AND free_kind = 'comp') = 2,
    'E2E-19 two $0 comp orders';
END $$;
SELECT pg_temp.check_invariants('E2E-19 sale: a comp batch', ARRAY['comp.issue_batch:user']);

-- ============================================================================
-- 3. After the sale
-- ============================================================================
-- E2E-20 a transfer and its claim: b1 sends a GA ticket to b6, who claims it
-- (exos_claim_transfer, the body the claim alias fix repaired).
DO $$
DECLARE v_t uuid := split_part(pg_temp.v('b1_tickets'), ',', 1)::uuid; v_tr uuid; v_new uuid;
BEGIN
  PERFORM pg_temp.act('b1');
  v_tr := public.exos_create_transfer(v_t, 'e2e-b6@x.com', 'Friend');
  PERFORM pg_temp.act('b6');
  v_new := public.exos_test_claim(v_tr);
  PERFORM pg_temp.act(NULL);
  ASSERT v_new IS NOT NULL, 'E2E-20 claimed';
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = v_new) = pg_temp.u('b6')
     AND (SELECT status FROM public.exos_tickets WHERE id = v_new) = 'active', 'E2E-20 the ticket is b6''s';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = v_tr) = 'completed', 'E2E-20 transfer completed';
  PERFORM pg_temp.put('b6_ticket', v_new::text);
END $$;
SELECT pg_temp.check_invariants('E2E-20 after: a transfer and its claim');

-- E2E-21 a partial refund: the owner refunds $10 of b1's order (exos-refund:
-- claim, Stripe, finalize).
DO $$
DECLARE c jsonb; f jsonb;
BEGIN
  c := public.exos_refund_claim(pg_temp.u('oa'), 'cs_e2e_b1', 'e2e-partial-0001', NULL, 1000, false, 'goodwill: late doors', NULL);
  PERFORM public.exos_refund_charge_prepare((c ->> 'request_id')::uuid);
  f := public.exos_refund_finalize((c ->> 'request_id')::uuid, 're_e2e_partial', 'succeeded');
  ASSERT (f ->> 'status') = 'succeeded' AND (f ->> 'voided')::int = 0, 'E2E-21 refunded, no ticket voided: ' || f::text;
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_e2e_b1') = 'partially_refunded', 'E2E-21 partially refunded';
  ASSERT (SELECT sum(amount_cents) FROM public.exos_order_refunds WHERE session_id = 'cs_e2e_b1' AND status = 'succeeded') = 1000, 'E2E-21 $10';
END $$;
SELECT pg_temp.check_invariants('E2E-21 after: a partial refund', ARRAY['refund.issue:user']);

-- E2E-21b a friend's group seat refunded in full before the Early step sold
-- out: the ticket is void and its Early place is free again.
DO $$
DECLARE c jsonb; f jsonb;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE price_step_id = pg_temp.v('step_early')::uuid AND status = 'active') = 7, 'E2E-21b 7 Early sold';
  c := public.exos_refund_claim(pg_temp.u('oa'), 'cs_e2e_f2', 'e2e-f2-0001', NULL, NULL, true, 'friend can''t come', NULL);
  PERFORM public.exos_refund_charge_prepare((c ->> 'request_id')::uuid);
  f := public.exos_refund_finalize((c ->> 'request_id')::uuid, 're_e2eF2', 'succeeded');
  ASSERT (f ->> 'voided')::int = 1, 'E2E-21b the seat''s ticket voided: ' || f::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE price_step_id = pg_temp.v('step_early')::uuid AND status = 'active') = 6, 'E2E-21b 6 Early sold';
  ASSERT (public.exos_tier_current_price(pg_temp.u('ga'), now(), 'online') ->> 'price_cents')::int = 3000, 'E2E-21b still Early';
  ASSERT (SELECT status FROM public.exos_group_buys WHERE id = pg_temp.v('group')::uuid) = 'closed', 'E2E-21b the group stays closed';
END $$;
SELECT pg_temp.check_invariants('E2E-21b after: a group seat refunded, its price-step place freed', ARRAY['refund.issue:user']);

-- E2E-22 a refund back to a gift card: the owner refunds b3's whole order;
-- the card part goes back on the card.
DO $$
DECLARE c jsonb; f jsonb;
BEGIN
  c := public.exos_refund_claim(pg_temp.u('oa'), 'cs_e2e_gift', 'e2e-gift-0001', NULL, NULL, true, 'can''t make it', NULL);
  PERFORM public.exos_refund_charge_prepare((c ->> 'request_id')::uuid);
  f := public.exos_refund_finalize((c ->> 'request_id')::uuid, 're_e2e_gift', 'succeeded');
  ASSERT (f ->> 'voided')::int = 1, 'E2E-22 the ticket voided: ' || f::text;
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_e2e_gift') = 'refunded', 'E2E-22 refunded';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = pg_temp.v('gc')::uuid) = 5000, 'E2E-22 the $20 is back on the card';
END $$;
SELECT pg_temp.check_invariants('E2E-22 after: a whole refund, the gift card part back on the card', ARRAY['refund.issue:user']);

-- E2E-23 a voided door sale: the manager voids the cash sale (cash back out of the drawer).
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('ma');
  r := public.exos_pos_void_order(pg_temp.v('pos_cash')::uuid, 'rang the wrong type', pg_temp.u('dr'));
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT status FROM public.exos_tickets WHERE order_ref = 'pos:' || pg_temp.v('pos_cash')) = 'voided', 'E2E-23 the ticket is void: ' || r::text;
END $$;
SELECT pg_temp.check_invariants('E2E-23 after: a voided door sale', ARRAY['pos.void:user']);

-- E2E-24 a cash paid-out from the drawer.
DO $$
BEGIN
  PERFORM pg_temp.act('sa');
  PERFORM public.exos_pos_paid_out(pg_temp.u('dr'), 1000, 'ice for the bar', pg_temp.u('k-paid-out'));
  PERFORM pg_temp.act(NULL);
END $$;
SELECT pg_temp.check_invariants('E2E-24 after: a cash paid-out', ARRAY['pos.paid_out:user']);

-- E2E-25 the drawer closed $2.00 short.
DO $$
DECLARE v_exp int := public._exos_pos_drawer_cash(pg_temp.u('dr')); r jsonb;
BEGIN
  -- $100 float + $45 + 2 × $45 cash sales − the $45 voided − $10 paid out = $180 expected; $178 counted.
  ASSERT v_exp = 18000, 'E2E-25 the drawer expects $180: ' || v_exp;
  PERFORM pg_temp.act('sa');
  r := public.exos_pos_close_drawer(pg_temp.u('dr'), v_exp - 200, NULL, 'end of night');
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT closed_at IS NOT NULL FROM public.exos_pos_drawer_sessions WHERE id = pg_temp.u('dr')), 'E2E-25 closed: ' || r::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
                  WHERE e.org_id = pg_temp.u('A') AND l.account = 'cash_over_short' AND l.debit_cents = 200), 'E2E-25 $2 short in the journal';
END $$;
SELECT pg_temp.check_invariants('E2E-25 after: the drawer closed short', ARRAY['pos.drawer_close:user']);

-- E2E-26 a fee adjustment through the API (POST /v1/orders/:id/fee-adjustments,
-- the books key): a missed $0.75 fee added to b1's order.
DO $$
DECLARE r jsonb; r2 jsonb;
BEGIN
  r := public._exos_api_fee_adjustment(pg_temp.u('A'), pg_temp.v('api_key')::uuid, 'cs_e2e_b1', 75, 'Missed service fee', NULL, 'e2e-fee-0001');
  r2 := public._exos_api_fee_adjustment(pg_temp.u('A'), pg_temp.v('api_key')::uuid, 'cs_e2e_b1', 75, 'Missed service fee', NULL, 'e2e-fee-0001');
  ASSERT r ->> 'id' = r2 ->> 'id', 'E2E-26 the resend is the same adjustment: ' || r::text || ' / ' || r2::text;
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments WHERE session_id = 'cs_e2e_b1' AND reason = 'manual' AND api_key_id = pg_temp.v('api_key')::uuid) = 1, 'E2E-26 one row, the key on it';
END $$;
SELECT pg_temp.check_invariants('E2E-26 after: a fee adjustment through the API', ARRAY['fee.adjust:api_key']);

-- E2E-27 the lounge pass scanned at its list, then the scan undone (wrong guest).
DO $$
DECLARE v_pass uuid; r jsonb;
BEGIN
  SELECT p.id INTO v_pass FROM public.exos_addon_passes p JOIN public.exos_order_addons a ON a.id = p.order_addon_id WHERE a.order_ref = 'cs_e2e_b1';
  PERFORM pg_temp.act('sa');
  r := public.exos_check_in_ticket(v_pass, 'camera', 'verified', pg_temp.acode(v_pass), pg_temp.u('e1'), NULL, NULL, 'Door 1', pg_temp.u('ll'), 'entry');
  ASSERT (r ->> 'ok')::boolean, 'E2E-27 the pass scans at the lounge: ' || r::text;
  r := public.exos_undo_addon_check_in(v_pass, pg_temp.u('e1'), 'wrong guest', NULL, NULL, 'Door 1');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'status' = 'active', 'E2E-27 undone: ' || r::text;
  PERFORM pg_temp.act(NULL);
END $$;
SELECT pg_temp.check_invariants('E2E-27 after: an add-on scan and its undo');

-- E2E-28 a dispute on the guest's order: opened, then lost; org A recovers
-- lost disputes (amount + fee owed to Exos). The webhook voids the order.
DO $$
DECLARE v text;
BEGIN
  v := public.exos_record_dispute_event(p_session_id => 'cs_e2e_guest', p_dispute_id => 'du_e2eOne', p_status => 'needs_response',
         p_reason => 'fraudulent', p_amount_cents => 8000, p_provider_event_id => 'evt_e2eD1', p_charge_id => pg_temp.sid('ch', 'cs_e2e_guest'),
         p_payment_intent => pg_temp.sid('pi', 'cs_e2e_guest'), p_fee_cents => 1500, p_currency => 'usd');
  v := public.exos_record_dispute_event(p_session_id => 'cs_e2e_guest', p_dispute_id => 'du_e2eOne', p_status => 'lost',
         p_amount_cents => 8000, p_provider_event_id => 'evt_e2eD2', p_fee_cents => 1500, p_currency => 'usd');
  ASSERT v = 'lost', 'E2E-28 lost';
  PERFORM public.exos_refund_checkout('cs_e2e_guest', 'chargeback lost (fraudulent)');
  ASSERT (SELECT recovery_status FROM public.exos_disputes WHERE dispute_id = 'du_e2eOne') = 'recovery_pending', 'E2E-28 recovery pending';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_e2e_guest' AND status = 'active') = 0, 'E2E-28 the ticket is void';
  ASSERT EXISTS (SELECT 1 FROM public.exos_journal_entries WHERE source_table = 'exos_disputes' AND org_id = pg_temp.u('A')), 'E2E-28 journaled';
END $$;
SELECT pg_temp.check_invariants('E2E-28 after: a dispute lost, recovery on');

-- E2E-29 the promoter's commission settled (Venmo, by the owner).
DO $$
DECLARE v_p uuid := (SELECT id FROM public.exos_promoters WHERE org_id = pg_temp.u('A') AND code = 'e2e-promo'); ids uuid[]; v_sum int; r jsonb;
BEGIN
  SELECT array_agg(id ORDER BY id), sum(commission_cents) INTO ids, v_sum FROM public.exos_promoter_commissions WHERE promoter_id = v_p AND status = 'accrued';
  ASSERT cardinality(ids) > 0, 'E2E-29 commissions to settle';
  PERFORM pg_temp.act('oa');
  r := public.exos_settle_promoter(v_p, ids, v_sum, 'Venmo', 'e2e-settle-0001');
  PERFORM pg_temp.act(NULL);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_promoter_commissions WHERE id = ANY (ids) AND status <> 'paid'), 'E2E-29 paid: ' || r::text;
END $$;
SELECT pg_temp.check_invariants('E2E-29 after: the promoter''s commission settled', ARRAY['promoter.settle:user']);

-- E2E-30 an instant payout (exos-instant-payouts: begin, Stripe, mark sent).
DO $$
DECLARE a jsonb;
BEGIN
  a := public.exos_instant_payout_begin(pg_temp.u('A'), pg_temp.u('oa'), 3000, 'usd', 45, 'e2e-inst-0001');
  ASSERT (a ->> 'ok')::boolean, 'E2E-30 begun: ' || a::text;
  ASSERT public.exos_instant_payout_mark((a ->> 'id')::uuid, 'sent', 'po_e2e1'), 'E2E-30 sent';
END $$;
SELECT pg_temp.check_invariants('E2E-30 after: an instant payout', ARRAY['payout.instant:user']);

-- E2E-31 the price step advances: b7 takes the last two Early tickets (8 of
-- 8, the one the refund freed included), then b8 pays the Regular price.
DO $$
DECLARE cp jsonb; v_hold uuid;
BEGIN
  cp := public.exos_tier_current_price(pg_temp.u('ga'), now(), 'online');
  ASSERT (cp ->> 'price_cents')::int = 3000, 'E2E-31 still Early: ' || cp::text;
  PERFORM pg_temp.act('b7');
  v_hold := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('ga'), 2);
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_hold_lock_price(v_hold, (cp ->> 'step_id')::uuid, 3000);
  PERFORM pg_temp.sess('cs_e2e_b7', 'e1', 'ga', 'b7', 'e2e-b7@x.com', 2, 6000, 270, 120, NULL, NULL, (cp ->> 'step_id')::uuid);
  PERFORM public.exos_record_checkout_answers('cs_e2e_b7', jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_guest'), 'No')));
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2e_b7' WHERE id = v_hold;
  ASSERT cardinality(pg_temp.paid('cs_e2e_b7')) = 2, 'E2E-31 b7';
  ASSERT (SELECT sold_out_at IS NOT NULL FROM public.exos_price_steps WHERE id = pg_temp.v('step_early')::uuid), 'E2E-31 Early latched';
  cp := public.exos_tier_current_price(pg_temp.u('ga'), now(), 'online');
  ASSERT (cp ->> 'price_cents')::int = 4000 AND cp ->> 'step_id' = pg_temp.v('step_regular'), 'E2E-31 Regular now: ' || cp::text;
  PERFORM pg_temp.act('b8');
  v_hold := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('ga'), 1);
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_hold_lock_price(v_hold, (cp ->> 'step_id')::uuid, 4000);
  PERFORM pg_temp.sess('cs_e2e_b8', 'e1', 'ga', 'b8', 'e2e-b8@x.com', 1, 4000, 190, 80, NULL, NULL, (cp ->> 'step_id')::uuid);
  PERFORM public.exos_record_checkout_answers('cs_e2e_b8', jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_guest'), 'No')));
  UPDATE public.exos_cart_holds SET checkout_session_id = 'cs_e2e_b8' WHERE id = v_hold;
  ASSERT cardinality(pg_temp.paid('cs_e2e_b8')) = 1, 'E2E-31 b8 at Regular';
END $$;
SELECT pg_temp.check_invariants('E2E-31 after: the price step advances');

-- E2E-32 the matinee is cancelled: the owner cancels it on the dashboard,
-- then exos-refund's cancel_event refunds every order.
SELECT pg_temp.act('oa');
SET ROLE authenticated;
UPDATE public.exos_events SET status = 'cancelled', cancel_reason = 'artist ill' WHERE id = pg_temp.u('e2');
RESET ROLE;
DO $$
DECLARE r record; c jsonb; n int := 0;
BEGIN
  FOR r IN SELECT * FROM public.exos_refund_event_orders_svc(pg_temp.u('oa'), pg_temp.u('e2'), NULL, 25) LOOP
    c := public.exos_refund_claim(pg_temp.u('oa'), r.session_id, 'evc:e2e-cancel-0001:' || r.session_id, NULL, NULL, true, 'event cancelled', 'event_cancel');
    PERFORM public.exos_refund_charge_prepare((c ->> 'request_id')::uuid);
    PERFORM public.exos_refund_finalize((c ->> 'request_id')::uuid, 're_e2e_' || r.session_id, 'succeeded');
    n := n + 1;
  END LOOP;
  ASSERT n = 2, 'E2E-32 two orders refunded: ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE event_id = pg_temp.u('e2') AND status IN ('active', 'used')), 'E2E-32 no live ticket';
  ASSERT (SELECT bool_and(status = 'refunded') FROM public.exos_checkout_sessions WHERE event_id = pg_temp.u('e2')), 'E2E-32 every order refunded';
  ASSERT (SELECT bool_and(status = 'reversed') FROM public.exos_promoter_commissions WHERE session_id = 'cs_e2e_m1'),
    'E2E-32 the promoter''s (already paid) commission on the refunded order is reversed';
  ASSERT (SELECT sum(amount_cents) FROM public.exos_commission_netting WHERE session_id = 'cs_e2e_m1' AND kind = 'clawback') = -1000,
    'E2E-32 and owed back (a clawback for the next payout)';
  PERFORM pg_temp.act('b1');
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1)', pg_temp.u('e2'), pg_temp.u('g2'))) <> 'ok', 'E2E-32 no new sale';
  PERFORM pg_temp.act(NULL);
END $$;
SELECT pg_temp.check_invariants('E2E-32 after: the matinee cancelled, every order refunded',
  ARRAY['event.cancel:user', 'refund.issue:user', 'refund.issue:user']);

-- E2E-33 last, b1's order refunded in full: the rest of it after the $10
-- partial refund, the ticket b6 now holds, the lounge pass (scanned and
-- undone earlier), the API's fee adjustment and the promoter's paid
-- commission all on it.
DO $$
DECLARE c jsonb; f jsonb;
BEGIN
  c := public.exos_refund_claim(pg_temp.u('oa'), 'cs_e2e_b1', 'e2e-b1-full-0001', NULL, NULL, true, 'show moved', NULL);
  ASSERT (c ->> 'amount_cents')::int = 8000, 'E2E-33 the rest: $80 of $90: ' || c::text;
  PERFORM public.exos_refund_charge_prepare((c ->> 'request_id')::uuid);
  f := public.exos_refund_finalize((c ->> 'request_id')::uuid, 're_e2eB1Full', 'succeeded');
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_e2e_b1') = 'refunded', 'E2E-33 refunded';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.v('b6_ticket')::uuid) = 'voided', 'E2E-33 b6''s ticket is void too';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'cs_e2e_b1' AND status IN ('active', 'used')), 'E2E-33 no live ticket';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_addon_passes p JOIN public.exos_order_addons a ON a.id = p.order_addon_id
                      WHERE a.order_ref = 'cs_e2e_b1' AND p.status = 'active'), 'E2E-33 the lounge pass is void';
  ASSERT (SELECT bool_and(status = 'reversed') FROM public.exos_promoter_commissions WHERE session_id = 'cs_e2e_b1'),
    'E2E-33 the paid commission reversed';
END $$;
SELECT pg_temp.check_invariants('E2E-33 after: b1''s order refunded in full (transferred ticket, add-on, fee change, paid commission)',
  ARRAY['refund.issue:user']);

ROLLBACK;
