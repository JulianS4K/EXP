-- ============================================================================
-- Mail templates + follow-ups (mig 20260929071000). Self-contained: every row
-- uses the 7f… uuid prefix and the whole file rolls back.
--   M1  allowlist keeps every old value and adds the new ones
--   M2  exos_mail_enqueue: validation, dedupe, marketing opt-out + unsubscribe
--   M3  exos_mail_claim_batch hands payload rows only to a rendering drain
--   M4  event-published trigger: owner + managers, once, not series clones
--   M5  receipt html: line items (escaped), all-in note, tickets link
--   M6  reminder: tickets link, parked tickets don't mail the org owner
--   M7  event-updated via exos_notify_event_holders (staff only)
--   M8  scheduled follow-ups: post-event, onboarding, fee-free, inventory,
--       daily digest, weekly summary; opt-out; second run queues nothing
--   M9  refund-issued: once per refund, only when it succeeds
--   M10 event-cancelled trigger: every holder, refund status each, parked
--       tickets go to the claimant, SPA call afterwards is a no-op
--   M11 payout mails
--   M12 no buyer PII in organizer mails; grants
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Isolate the queue from rows other suites left behind.
UPDATE public.exos_mail SET status = 'sent' WHERE status IN ('pending', 'sending');
-- Prod has these (phase-1); the scratch chain doesn't.
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS cancel_reason text;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('7f000000-0000-0000-0000-0000000000a0', 'owner-7f@x.com',   now()),
  ('7f000000-0000-0000-0000-0000000000a1', 'manager-7f@x.com', now()),
  ('7f000000-0000-0000-0000-0000000000a2', 'finance-7f@x.com', now()),
  ('7f000000-0000-0000-0000-0000000000a3', 'scanner-7f@x.com', now()),
  ('7f000000-0000-0000-0000-0000000000b1', 'fan1-7f@x.com',    now()),
  ('7f000000-0000-0000-0000-0000000000b2', 'fan2-7f@x.com',    now()),
  ('7f000000-0000-0000-0000-0000000000b3', 'comp-7f@x.com',    now()),
  ('7f000000-0000-0000-0000-0000000000b4', 'fan4-7f@x.com',    now()),
  ('7f000000-0000-0000-0000-0000000000b5', 'voided-7f@x.com',  now()),
  ('7f000000-0000-0000-0000-0000000000c0', 'owner2-7f@x.com',  now());

INSERT INTO public.exos_orgs (id, name, slug, owner_uid, created_at) VALUES
  ('7f000000-0000-0000-0000-000000000001', 'Org <7f> & Co', '7f-org-1', '7f000000-0000-0000-0000-0000000000a0', now() - interval '1 day'),
  ('7f000000-0000-0000-0000-000000000002', 'Org 7f two',    '7f-org-2', '7f000000-0000-0000-0000-0000000000c0', now() - interval '4 days'),
  ('7f000000-0000-0000-0000-000000000003', 'Org 7f three',  '7f-org-3', '7f000000-0000-0000-0000-0000000000c0', now() - interval '8 days'),
  ('7f000000-0000-0000-0000-000000000004', 'Org 7f four',   '7f-org-4', '7f000000-0000-0000-0000-0000000000c0', now() - interval '5 days');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a0', 'owner'),
  ('7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a1', 'manager'),
  ('7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a2', 'finance'),
  ('7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a3', 'scanner');

-- E1 upcoming, E2 ended ~1.8 days ago, E3 draft, E4 upcoming (cancelled
-- later), E5 draft series clone, E6 org 4's draft.
INSERT INTO public.exos_events (id, org_id, name, status, starts_at, ends_at, doors_at, timezone, venue_name, total_tickets, tickets_sold) VALUES
  ('7f000000-0000-0000-0000-0000000000e1', '7f000000-0000-0000-0000-000000000001', 'Show <One>', 'published', now() + interval '5 days', NULL, NULL, 'America/New_York', 'Hall & Annex', 110, 3),
  ('7f000000-0000-0000-0000-0000000000e2', '7f000000-0000-0000-0000-000000000001', 'Past Show',  'published', now() - interval '2 days', now() - interval '44 hours', NULL, 'America/New_York', 'Club', 0, 0),
  ('7f000000-0000-0000-0000-0000000000e3', '7f000000-0000-0000-0000-000000000001', 'New Show',   'draft',     now() + interval '20 days', NULL, NULL, 'UTC', NULL, 0, 0),
  ('7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-000000000001', 'Doomed "Show"', 'published', now() + interval '10 days', NULL, now() + interval '10 days' - interval '1 hour', 'America/Chicago', 'Arena', 0, 0),
  ('7f000000-0000-0000-0000-0000000000e6', '7f000000-0000-0000-0000-000000000004', 'Org4 draft', 'draft',     now() + interval '30 days', NULL, NULL, 'UTC', NULL, 0, 0);
INSERT INTO public.exos_events (id, org_id, name, status, starts_at, timezone, series_index) VALUES
  ('7f000000-0000-0000-0000-0000000000e5', '7f000000-0000-0000-0000-000000000001', 'Series date 2', 'draft', now() + interval '21 days', 'UTC', 1);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, sort_order) VALUES
  ('7f000000-0000-0000-0000-0000000000d1', '7f000000-0000-0000-0000-0000000000e1', 'GA', 25, 10, 0, 1),
  ('7f000000-0000-0000-0000-0000000000d2', '7f000000-0000-0000-0000-0000000000e1', 'VIP', 80, 100, 1, 2);

-- Orders. S1/S2/S4/S5 on E4 (a month old), S6 yesterday and S7 last week on E1.
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, tax_cents, currency, status, fulfilled_at, guest) VALUES
  ('7f-s1', '7f000000-0000-0000-0000-0000000000e4', NULL, '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b1', 'fan1-7f@x.com', 2, 5000, 400, 'usd', 'fulfilled', now() - interval '30 days', false),
  ('7f-s2', '7f000000-0000-0000-0000-0000000000e4', NULL, '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b2', 'fan2-7f@x.com', 1, 3000, 0,   'usd', 'fulfilled', now() - interval '30 days', false),
  ('7f-s4', '7f000000-0000-0000-0000-0000000000e4', NULL, '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b4', 'fan4-7f@x.com', 1, 2000, 0,   'usd', 'fulfilled', now() - interval '30 days', false),
  ('7f-s5', '7f000000-0000-0000-0000-0000000000e4', NULL, '7f000000-0000-0000-0000-000000000001', NULL, 'guest-7f@x.com', 1, 4000, 0, 'usd', 'fulfilled', now() - interval '30 days', true),
  ('7f-s6', '7f000000-0000-0000-0000-0000000000e1', '7f000000-0000-0000-0000-0000000000d2', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b1', 'fan1-7f@x.com', 2, 16000, 0, 'usd', 'fulfilled',
     (date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') - interval '12 hours', false),
  ('7f-s7', '7f000000-0000-0000-0000-0000000000e1', '7f000000-0000-0000-0000-0000000000d2', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b2', 'fan2-7f@x.com', 1, 8000, 0, 'usd', 'fulfilled',
     (date_trunc('week', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') - interval '3 days', false);

INSERT INTO public.exos_price_disclosures (session_id, event_id, org_id, currency, total_shown_cents) VALUES
  ('7f-s1', '7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-000000000001', 'usd', 5000);
INSERT INTO public.exos_price_disclosure_lines (session_id, line_no, kind, item_name, quantity, face_unit_cents, tax_cents, tax_included, fee_cents, unit_all_in_cents, line_total_cents) VALUES
  ('7f-s1', 1, 'ticket', 'GA <VIP>', 2, 2300, 200, false, 0, 2500, 5000);

-- Tickets. E4: fan1, fan2, comp, fan4, guest parked on the owner, voided.
-- E1: fan1, fan2, voided. E2 (past): fan1, fan2 (opts out), comp (used),
-- the manager, and a ticket parked on the owner.
INSERT INTO public.exos_tickets (id, event_id, org_id, owner_id, buyer_id, buyer_email, status, price_paid, order_ref) VALUES
  ('7f000000-0000-0000-0000-000000000401', '7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b1', '7f000000-0000-0000-0000-0000000000b1', 'fan1-7f@x.com', 'active', 25, '7f-s1'),
  ('7f000000-0000-0000-0000-000000000402', '7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b2', '7f000000-0000-0000-0000-0000000000b2', 'fan2-7f@x.com', 'active', 30, '7f-s2'),
  ('7f000000-0000-0000-0000-000000000403', '7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b3', '7f000000-0000-0000-0000-0000000000b3', 'comp-7f@x.com', 'active', 0,  'comp:7f'),
  ('7f000000-0000-0000-0000-000000000404', '7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b4', '7f000000-0000-0000-0000-0000000000b4', 'fan4-7f@x.com', 'active', 20, '7f-s4'),
  ('7f000000-0000-0000-0000-000000000405', '7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a0', '7f000000-0000-0000-0000-0000000000a0', 'guest-7f@x.com', 'active', 40, '7f-s5'),
  ('7f000000-0000-0000-0000-000000000406', '7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b5', '7f000000-0000-0000-0000-0000000000b5', 'voided-7f@x.com', 'voided', 0, 'comp:7f-v'),
  ('7f000000-0000-0000-0000-000000000101', '7f000000-0000-0000-0000-0000000000e1', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b1', '7f000000-0000-0000-0000-0000000000b1', 'fan1-7f@x.com', 'active', 80, '7f-s6'),
  ('7f000000-0000-0000-0000-000000000102', '7f000000-0000-0000-0000-0000000000e1', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b2', '7f000000-0000-0000-0000-0000000000b2', 'fan2-7f@x.com', 'active', 80, '7f-s7'),
  ('7f000000-0000-0000-0000-000000000103', '7f000000-0000-0000-0000-0000000000e1', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b5', '7f000000-0000-0000-0000-0000000000b5', 'voided-7f@x.com', 'voided', 0, 'comp:7f-v2'),
  ('7f000000-0000-0000-0000-000000000201', '7f000000-0000-0000-0000-0000000000e2', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b1', '7f000000-0000-0000-0000-0000000000b1', 'fan1-7f@x.com', 'active', 10, 'x'),
  ('7f000000-0000-0000-0000-000000000202', '7f000000-0000-0000-0000-0000000000e2', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b2', '7f000000-0000-0000-0000-0000000000b2', 'fan2-7f@x.com', 'active', 10, 'x'),
  ('7f000000-0000-0000-0000-000000000203', '7f000000-0000-0000-0000-0000000000e2', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b3', '7f000000-0000-0000-0000-0000000000b3', 'comp-7f@x.com', 'used', 0, 'x'),
  ('7f000000-0000-0000-0000-000000000204', '7f000000-0000-0000-0000-0000000000e2', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a1', '7f000000-0000-0000-0000-0000000000a1', 'manager-7f@x.com', 'active', 0, 'x'),
  ('7f000000-0000-0000-0000-000000000205', '7f000000-0000-0000-0000-0000000000e2', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a0', '7f000000-0000-0000-0000-0000000000a0', 'g2-7f@x.com', 'active', 0, 'x');
INSERT INTO public.exos_transfers (id, ticket_id, org_id, sender_id, receiver_email, status) VALUES
  ('7f000000-0000-0000-0000-0000000007a5', '7f000000-0000-0000-0000-000000000405', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a0', 'guest-7f@x.com', 'pending'),
  ('7f000000-0000-0000-0000-0000000007b5', '7f000000-0000-0000-0000-000000000205', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000a0', 'g2-7f@x.com', 'pending');
UPDATE public.exos_tickets SET pending_transfer_id = '7f000000-0000-0000-0000-0000000007a5' WHERE id = '7f000000-0000-0000-0000-000000000405';
UPDATE public.exos_tickets SET pending_transfer_id = '7f000000-0000-0000-0000-0000000007b5' WHERE id = '7f000000-0000-0000-0000-000000000205';

-- M1 -------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled','event-reminder',
      'order-failed','checkout-abandoned','marketplace-attention','transfer-sent','invite-accepted',
      'event-published','inventory-low','inventory-sold-out','payout-sent','payout-pending','fee-free-ending',
      'org-welcome','org-first-event','org-connect-stripe','org-sales-digest','org-weekly-summary',
      'refund-issued','post-event'] LOOP
    INSERT INTO public.exos_mail (template, to_email, subject, html, status) VALUES (t, 'm1-7f@x.com', 's', 'h', 'sent');
  END LOOP;
  BEGIN
    INSERT INTO public.exos_mail (template, to_email, subject, html) VALUES ('zz-nope', 'm1-7f@x.com', 's', 'h');
    RAISE EXCEPTION 'M1 FAIL: unknown template accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  DELETE FROM public.exos_mail WHERE to_email = 'm1-7f@x.com';
  RAISE NOTICE 'PASS M1 allowlist keeps the old templates and adds the new ones';
END $$;

-- M2 -------------------------------------------------------------------------
DO $$
DECLARE id1 uuid; id2 uuid; m public.exos_mail%ROWTYPE;
BEGIN
  ASSERT public.exos_mail_enqueue('org-welcome', 'not-an-email', '{}') IS NULL, 'M2: bad address';
  id1 := public.exos_mail_enqueue('org-welcome', ' M2-7F@X.com ', '{"a":1}', 'm2:once');
  ASSERT id1 IS NOT NULL, 'M2: queued';
  SELECT * INTO m FROM public.exos_mail WHERE id = id1;
  ASSERT m.to_email = 'm2-7f@x.com' AND m.html = '' AND m.subject = '[org-welcome]' AND m.status = 'pending', 'M2: row shape';
  ASSERT m.payload = '{"a":1,"marketing":false}'::jsonb AND m.list_unsubscribe IS NULL, 'M2: transactional payload, got ' || m.payload::text;
  ASSERT public.exos_mail_enqueue('org-welcome', 'm2-7f@x.com', '{}', 'm2:once') IS NULL, 'M2: dedupe key used once';
  ASSERT (SELECT mail_id FROM public.exos_mail_dedupe WHERE dedupe_key = 'm2:once') = id1, 'M2: ledger points at the mail';
  ASSERT public.exos_mail_enqueue('post-event', 'm2-7f@x.com', '{}', 'm2:mk', NULL, true) IS NULL, 'M2: marketing needs an account';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail_dedupe WHERE dedupe_key = 'm2:mk'), 'M2: skipped mail leaves the key free';
  id2 := public.exos_mail_enqueue('post-event', 'fan1-7f@x.com', '{}', 'm2:mk2', '7f000000-0000-0000-0000-0000000000b1', true);
  SELECT * INTO m FROM public.exos_mail WHERE id = id2;
  ASSERT m.list_unsubscribe ~ '^\{\{app_url\}\}/unsubscribe\?t=[0-9a-f]{64}$', 'M2: List-Unsubscribe target';
  ASSERT m.payload->>'unsubscribe_token' = (SELECT unsubscribe_token FROM public.exos_mail_prefs WHERE user_id = '7f000000-0000-0000-0000-0000000000b1')
     AND (m.payload->>'marketing')::boolean, 'M2: token in payload';
  -- fan2 and the manager opt out of marketing.
  INSERT INTO public.exos_mail_prefs (user_id, marketing_opt_out) VALUES
    ('7f000000-0000-0000-0000-0000000000b2', true), ('7f000000-0000-0000-0000-0000000000a1', true);
  ASSERT public.exos_mail_enqueue('post-event', 'fan2-7f@x.com', '{}', 'm2:mk3', '7f000000-0000-0000-0000-0000000000b2', true) IS NULL, 'M2: opted out';
  ASSERT public.exos_mail_enqueue('refund-issued', 'fan2-7f@x.com', '{}', 'm2:tx', '7f000000-0000-0000-0000-0000000000b2', false) IS NOT NULL, 'M2: transactional ignores the opt-out';
  RAISE NOTICE 'PASS M2 enqueue: validation, once-only keys, marketing opt-out + unsubscribe';
END $$;
DELETE FROM public.exos_mail WHERE to_email IN ('m2-7f@x.com') OR (to_email IN ('fan1-7f@x.com','fan2-7f@x.com') AND template IN ('post-event','refund-issued'));
DELETE FROM public.exos_mail_dedupe WHERE dedupe_key LIKE 'm2:%';

-- M3 -------------------------------------------------------------------------
DO $$
DECLARE n int; np int; r record;
BEGIN
  UPDATE public.exos_mail SET status = 'sent' WHERE status = 'pending';  -- the fixtures' publish mails
  INSERT INTO public.exos_mail (template, to_email, subject, html) VALUES ('ticket-issued', 'm3-7f@x.com', 'Legacy', '<p>x</p>');
  PERFORM public.exos_mail_enqueue('org-welcome', 'm3-7f@x.com', '{"org":{"id":"x","name":"y"}}');
  SELECT count(*), count(*) FILTER (WHERE payload IS NOT NULL) INTO n, np FROM public.exos_mail_claim_batch(50, 5, 10);
  ASSERT n = 1 AND np = 0, 'M3: an old drain gets the html row only, got ' || n || '/' || np;
  SELECT * INTO r FROM public.exos_mail_claim_batch(50, 5, 10, true);
  ASSERT r.template = 'org-welcome' AND r.payload->'org'->>'name' = 'y' AND r.attempts = 1, 'M3: the new drain gets template + payload';
  ASSERT (SELECT status FROM public.exos_mail WHERE to_email = 'm3-7f@x.com' AND template = 'org-welcome') = 'sending', 'M3: claimed';
  DELETE FROM public.exos_mail WHERE to_email = 'm3-7f@x.com';
  RAISE NOTICE 'PASS M3 claim batch: payload rows only for a drain that renders them';
END $$;

-- M4 -------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  -- The fixtures inserted E1/E2/E4 as published: those mailed too. Count E3.
  UPDATE public.exos_events SET status = 'published' WHERE id = '7f000000-0000-0000-0000-0000000000e3';
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'event-published' AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e3';
  ASSERT n = 2, 'M4: owner + manager, got ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'event-published'
                      AND to_email IN ('finance-7f@x.com', 'scanner-7f@x.com')), 'M4: not finance / scanner';
  UPDATE public.exos_events SET status = 'draft' WHERE id = '7f000000-0000-0000-0000-0000000000e3';
  UPDATE public.exos_events SET status = 'published' WHERE id = '7f000000-0000-0000-0000-0000000000e3';
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'event-published' AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e3';
  ASSERT n = 2, 'M4: re-publishing mails nobody again';
  UPDATE public.exos_events SET status = 'published' WHERE id = '7f000000-0000-0000-0000-0000000000e5';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'event-published'
                      AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e5'), 'M4: series clones stay quiet';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'event-published' AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e1') = 2,
    'M4: inserted as published mails too';
  ASSERT (SELECT payload->'event'->>'name' FROM public.exos_mail WHERE template = 'event-published' AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e1' LIMIT 1) = 'Show <One>',
    'M4: payload keeps the raw name (the renderer escapes)';
  RAISE NOTICE 'PASS M4 event-published: owner + managers, once, series clones skipped';
END $$;

-- M5 -------------------------------------------------------------------------
DO $$
DECLARE h text;
BEGIN
  h := public.exos_receipt_html('7f-s1');
  ASSERT h LIKE '%Paid: <strong>50.00 USD</strong> (including 4.00 tax)%', 'M5: first sentence unchanged: ' || h;
  ASSERT h LIKE '%2 &times; GA &lt;VIP&gt;%' AND h LIKE '%50.00</td>%', 'M5: escaped line item';
  ASSERT h LIKE '%All-in price: no fees were added at checkout and tax is included.%', 'M5: all-in note';
  ASSERT h LIKE '%<a href="{{app_url}}/my-tickets">View your tickets</a>%', 'M5: tickets link';
  h := public.exos_receipt_html('7f-s5');
  ASSERT h LIKE '%Paid: <strong>40.00 USD</strong>%' AND h NOT LIKE '%my-tickets%', 'M5: a parked order has claim links instead';
  ASSERT public.exos_receipt_html('7f-nope') = '', 'M5: unknown session';
  RAISE NOTICE 'PASS M5 receipt: line items, all-in note, tickets link';
END $$;

-- M6 -------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  n := public.exos_queue_event_reminder('7f000000-0000-0000-0000-0000000000e4', NULL);
  ASSERT n = 4, 'M6: fan1, fan2, comp, fan4 (not voided, not the owner of a parked ticket), got ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'event-reminder' AND to_email = 'owner-7f@x.com'), 'M6: owner not reminded';
  ASSERT (SELECT html FROM public.exos_mail WHERE template = 'event-reminder' AND to_email = 'fan1-7f@x.com')
         LIKE '%Doomed &quot;Show&quot;%{{app_url}}/my-tickets%', 'M6: escaped name + tickets link';
  DELETE FROM public.exos_mail WHERE template = 'event-reminder' AND to_email LIKE '%-7f@x.com';
  RAISE NOTICE 'PASS M6 reminder: tickets link, parked tickets skip the owner';
END $$;

-- M7 -------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  PERFORM set_config('app.uid', '7f000000-0000-0000-0000-0000000000b1', true);
  BEGIN
    PERFORM public.exos_notify_event_holders('7f000000-0000-0000-0000-0000000000e1', 'event-updated');
    RAISE EXCEPTION 'M7 FAIL: a fan notified holders';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', '7f000000-0000-0000-0000-0000000000a1', true);
  n := public.exos_notify_event_holders('7f000000-0000-0000-0000-0000000000e1', 'event-updated');
  ASSERT n = 2, 'M7: two live holders, got ' || n;
  ASSERT (SELECT created_by FROM public.exos_mail WHERE template = 'event-updated' AND to_email = 'fan1-7f@x.com') = '7f000000-0000-0000-0000-0000000000a1', 'M7: actor recorded';
  ASSERT (SELECT payload->'event'->>'venue_name' FROM public.exos_mail WHERE template = 'event-updated' AND to_email = 'fan2-7f@x.com') = 'Hall & Annex', 'M7: event facts';
  BEGIN
    PERFORM public.exos_notify_event_holders('7f000000-0000-0000-0000-0000000000e1', 'post-event');
    RAISE EXCEPTION 'M7 FAIL: other template accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'M7 FAIL%' THEN RAISE; END IF;
  END;
  PERFORM set_config('app.uid', '', true);
  RAISE NOTICE 'PASS M7 event-updated: staff only, one per live holder';
END $$;

-- M8 -------------------------------------------------------------------------
UPDATE public.exos_org_billing SET fee_free_until = now() + interval '10 days' WHERE org_id = '7f000000-0000-0000-0000-000000000001';
UPDATE public.exos_ticket_tiers SET sold = 9 WHERE id = '7f000000-0000-0000-0000-0000000000d1';
UPDATE public.exos_orgs SET post_event_emails_enabled = true WHERE id = '7f000000-0000-0000-0000-000000000001';
DO $$
DECLARE n int; m public.exos_mail%ROWTYPE; r record; before int;
BEGIN
  PERFORM public.exos_send_mail_followups();

  -- post-event: fan1 and the comp holder. Not fan2 (opted out), not the
  -- manager (staff), not the owner's parked ticket.
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'post-event' AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e2';
  ASSERT n = 2, 'M8 post-event: 2 recipients, got ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'post-event'
                      AND to_email IN ('fan2-7f@x.com', 'manager-7f@x.com', 'owner-7f@x.com', 'g2-7f@x.com')), 'M8 post-event: exclusions';
  SELECT * INTO m FROM public.exos_mail WHERE template = 'post-event' AND to_email = 'fan1-7f@x.com';
  ASSERT m.payload->'org'->>'name' = 'Org <7f> & Co' AND (m.payload->>'marketing')::boolean
     AND m.payload ? 'unsubscribe_token' AND m.list_unsubscribe LIKE '{{app_url}}/unsubscribe?t=%', 'M8 post-event: marketing shape';
  ASSERT m.payload->'next_events' @> '[{"id":"7f000000-0000-0000-0000-0000000000e1"}]'::jsonb
     AND NOT m.payload->'next_events' @> '[{"id":"7f000000-0000-0000-0000-0000000000e2"}]'::jsonb, 'M8 post-event: next events';

  -- onboarding: welcome (org 1), first event (org 2), connect Stripe (org 3),
  -- nothing for org 4 (it already has an event).
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'org-welcome' AND payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000001' AND to_email = 'owner-7f@x.com') = 1, 'M8 welcome';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'org-first-event' AND payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000002') = 1, 'M8 first event';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'org-connect-stripe' AND payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000003') = 1, 'M8 connect stripe';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000004'), 'M8 org 4 is done: no nudge';

  -- fee-free months: 14-day notice to owner, manager, finance.
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'fee-free-ending' AND payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000001' AND payload->>'stage' = '14d';
  ASSERT n = 3, 'M8 fee-free 14d: 3, got ' || n;
  ASSERT (SELECT (payload->>'days_left')::int FROM public.exos_mail WHERE template = 'fee-free-ending' AND to_email = 'owner-7f@x.com') = 10, 'M8 days left';

  -- inventory: GA at 9/10 is low; owner + manager (opted out of marketing,
  -- but this is transactional).
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'inventory-low' AND payload->'tier'->>'id' = '7f000000-0000-0000-0000-0000000000d1';
  ASSERT n = 2, 'M8 inventory-low: 2, got ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template LIKE 'inventory-%' AND payload->'tier'->>'id' = '7f000000-0000-0000-0000-0000000000d2'), 'M8 VIP has plenty';

  -- daily digest: yesterday's S6. The manager opted out; the owner gets it.
  SELECT * INTO m FROM public.exos_mail WHERE template = 'org-sales-digest' AND payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000001';
  ASSERT m.to_email = 'owner-7f@x.com', 'M8 digest to the owner';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'org-sales-digest' AND payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000001') = 1, 'M8 digest once, manager opted out';
  ASSERT m.payload->'totals' = '[{"currency":"usd","orders":1,"tickets":2,"gross_cents":16000}]'::jsonb, 'M8 digest totals: ' || (m.payload->'totals')::text;

  -- weekly summary: S7 (and S6 when yesterday was last week), upcoming E1.
  SELECT * INTO m FROM public.exos_mail WHERE template = 'org-weekly-summary' AND payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000001';
  ASSERT m.to_email = 'owner-7f@x.com', 'M8 weekly to the owner';
  ASSERT (m.payload->'totals'->0->>'tickets')::int >= 1 AND m.payload->'upcoming' @> '[{"id":"7f000000-0000-0000-0000-0000000000e1"}]'::jsonb
     AND m.payload ? 'checkins', 'M8 weekly content';

  -- A second run queues nothing new.
  SELECT count(*) INTO before FROM public.exos_mail WHERE to_email LIKE '%-7f@x.com';
  PERFORM public.exos_send_mail_followups();
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE to_email LIKE '%-7f@x.com') = before, 'M8 second run is a no-op';

  -- Sold out, then 1 day before the free months end: new mails, once.
  UPDATE public.exos_ticket_tiers SET sold = 10 WHERE id = '7f000000-0000-0000-0000-0000000000d1';
  UPDATE public.exos_org_billing SET fee_free_until = now() + interval '6 hours' WHERE org_id = '7f000000-0000-0000-0000-000000000001';
  PERFORM public.exos_send_mail_followups();
  PERFORM public.exos_send_mail_followups();
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'inventory-sold-out' AND payload->'tier'->>'id' = '7f000000-0000-0000-0000-0000000000d1') = 2, 'M8 sold out once';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'fee-free-ending' AND payload->>'stage' = '1d' AND payload->'org'->>'id' = '7f000000-0000-0000-0000-000000000001') = 3, 'M8 fee-free 1d';
  -- More capacity that sells out again alerts again.
  UPDATE public.exos_ticket_tiers SET capacity = 20, sold = 20 WHERE id = '7f000000-0000-0000-0000-0000000000d1';
  PERFORM public.exos_send_mail_followups();
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'inventory-sold-out' AND payload->'tier'->>'id' = '7f000000-0000-0000-0000-0000000000d1') = 4, 'M8 re-armed by capacity';

  -- Org turns the after-show mail off: a new past event mails nobody.
  UPDATE public.exos_orgs SET post_event_emails_enabled = false WHERE id = '7f000000-0000-0000-0000-000000000001';
  UPDATE public.exos_events SET starts_at = now() - interval '30 hours', ends_at = now() - interval '26 hours', status = 'published'
   WHERE id = '7f000000-0000-0000-0000-0000000000e3';
  INSERT INTO public.exos_tickets (event_id, org_id, owner_id, buyer_id, status, order_ref)
  VALUES ('7f000000-0000-0000-0000-0000000000e3', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000b4', '7f000000-0000-0000-0000-0000000000b4', 'active', 'x');
  PERFORM public.exos_send_mail_followups();
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'post-event' AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e3'), 'M8 org toggle off';

  -- Only the service role runs it.
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_send_mail_followups(int)', 'EXECUTE'), 'M8 grants';
  RAISE NOTICE 'PASS M8 follow-ups: post-event, onboarding, fee-free, inventory, digest, weekly; once each; opt-outs honoured';
END $$;

-- M9 -------------------------------------------------------------------------
DO $$
DECLARE n int; m public.exos_mail%ROWTYPE;
BEGIN
  INSERT INTO public.exos_order_refunds (session_id, org_id, provider, refund_id, amount_cents, currency, status)
  VALUES ('7f-s2', '7f000000-0000-0000-0000-000000000001', 'stripe', 're_7f_pending', 1000, 'usd', 'pending');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'refund-issued' AND to_email = 'fan2-7f@x.com'), 'M9: pending refund mails nothing';
  UPDATE public.exos_order_refunds SET status = 'succeeded' WHERE refund_id = 're_7f_pending';
  UPDATE public.exos_order_refunds SET status = 'succeeded', reason = 'again' WHERE refund_id = 're_7f_pending';
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'refund-issued' AND to_email = 'fan2-7f@x.com';
  ASSERT n = 1, 'M9: once per refund, got ' || n;
  SELECT * INTO m FROM public.exos_mail WHERE template = 'refund-issued' AND to_email = 'fan2-7f@x.com';
  ASSERT (m.payload->>'amount_cents')::int = 1000 AND (m.payload->>'partial')::boolean
     AND m.payload->>'order_ref' = '7f-s2' AND m.payload->'event'->>'name' = 'Doomed "Show"', 'M9: payload ' || m.payload::text;
  -- fan1 gets a full refund: the cancel mail below says so.
  INSERT INTO public.exos_order_refunds (session_id, org_id, provider, refund_id, amount_cents, currency, status)
  VALUES ('7f-s1', '7f000000-0000-0000-0000-000000000001', 'stripe', 're_7f_full', 5000, 'usd', 'succeeded');
  ASSERT (SELECT NOT (payload->>'partial')::boolean FROM public.exos_mail WHERE template = 'refund-issued' AND to_email = 'fan1-7f@x.com'), 'M9: full refund';
  RAISE NOTICE 'PASS M9 refund-issued: once per succeeded refund';
END $$;

-- M10 ------------------------------------------------------------------------
DO $$
DECLARE n int; st jsonb;
BEGIN
  INSERT INTO public.exos_refund_requests (session_id, org_id, event_id, requested_by, scope, amount_cents, currency, nonce, status)
  VALUES ('7f-s4', '7f000000-0000-0000-0000-000000000001', '7f000000-0000-0000-0000-0000000000e4', '7f000000-0000-0000-0000-0000000000a0', 'order', 2000, 'usd', 'nonce-7f-0001', 'pending');
  PERFORM set_config('app.uid', '7f000000-0000-0000-0000-0000000000a0', true);
  UPDATE public.exos_events SET status = 'cancelled', cancel_reason = 'Artist <ill>' WHERE id = '7f000000-0000-0000-0000-0000000000e4';
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'event-cancelled' AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e4';
  ASSERT n = 6, 'M10: fan1, fan2, comp, fan4, guest, voided holder, got ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'event-cancelled' AND to_email = 'owner-7f@x.com'), 'M10: not the owner of the parked ticket';
  SELECT jsonb_object_agg(to_email, payload->'refund'->>'status') INTO st
    FROM public.exos_mail WHERE template = 'event-cancelled' AND payload->'event'->>'id' = '7f000000-0000-0000-0000-0000000000e4';
  ASSERT st = '{"fan1-7f@x.com":"refunded","fan2-7f@x.com":"partial","comp-7f@x.com":"none","fan4-7f@x.com":"processing","guest-7f@x.com":"pending","voided-7f@x.com":"none"}'::jsonb,
    'M10: refund status per holder: ' || st::text;
  ASSERT (SELECT payload->>'reason' FROM public.exos_mail WHERE template = 'event-cancelled' AND to_email = 'guest-7f@x.com') = 'Artist <ill>', 'M10: raw reason';
  ASSERT (SELECT (payload->'refund'->>'paid_cents')::int = 3000 AND (payload->'refund'->>'refunded_cents')::int = 1000
            FROM public.exos_mail WHERE template = 'event-cancelled' AND to_email = 'fan2-7f@x.com'), 'M10: amounts';
  -- The SPA's own call right after is a no-op.
  n := public.exos_notify_event_holders('7f000000-0000-0000-0000-0000000000e4', 'event-cancelled');
  ASSERT n = 0, 'M10: already told, got ' || n;
  PERFORM set_config('app.uid', '', true);
  RAISE NOTICE 'PASS M10 event-cancelled: every holder, refund status each, once';
END $$;

-- M11 ------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  n := public.exos_queue_payout_mail('7f000000-0000-0000-0000-000000000001', 123456, 'USD', 'Sep 1-15, 2026', 'sent', 'po_7f_1');
  ASSERT n = 3, 'M11: owner, manager, finance, got ' || n;
  ASSERT public.exos_queue_payout_mail('7f000000-0000-0000-0000-000000000001', 123456, 'usd', 'Sep 1-15, 2026', 'sent', 'po_7f_1') = 0, 'M11: once per reference';
  ASSERT public.exos_queue_payout_mail('7f000000-0000-0000-0000-000000000001', 50000, 'usd', 'Sep 16-30, 2026', 'pending') = 3, 'M11: pending, keyed by period';
  ASSERT public.exos_queue_payout_mail('7f000000-0000-0000-0000-000000000001', 50000, 'usd', 'Sep 16-30, 2026', 'pending') = 0, 'M11: period once';
  ASSERT (SELECT payload->>'currency' = 'usd' AND (payload->>'amount_cents')::bigint = 123456 AND payload->>'reference' = 'po_7f_1'
            FROM public.exos_mail WHERE template = 'payout-sent' AND to_email = 'finance-7f@x.com'), 'M11: payload';
  BEGIN
    PERFORM public.exos_queue_payout_mail('7f000000-0000-0000-0000-000000000001', 1, 'dollars', 'x');
    RAISE EXCEPTION 'M11 FAIL: bad currency accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'M11 FAIL%' THEN RAISE; END IF;
  END;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_queue_payout_mail(uuid,bigint,text,text,text,text)', 'EXECUTE'), 'M11: grants';
  RAISE NOTICE 'PASS M11 payout-sent / payout-pending';
END $$;

-- M12 ------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT EXISTS (
    SELECT 1 FROM public.exos_mail
     WHERE template IN ('event-published','inventory-low','inventory-sold-out','payout-sent','payout-pending',
                        'fee-free-ending','org-welcome','org-first-event','org-connect-stripe',
                        'org-sales-digest','org-weekly-summary')
       AND (payload::text ~ '(fan[0-9]|comp|guest|voided|g2)-7f@x\.com' OR payload::text LIKE '%7f-s%')),
    'M12: organizer mails carry no buyer emails or order refs';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_mail_enqueue(text,text,jsonb,text,uuid,boolean,uuid)', 'EXECUTE'), 'M12: enqueue is internal';
  ASSERT NOT has_function_privilege('anon', 'public.exos_mail_claim_batch(int,int,int,boolean)', 'EXECUTE'), 'M12: claim is service-only';
  ASSERT has_function_privilege('authenticated', 'public.exos_notify_event_holders(uuid,text)', 'EXECUTE'), 'M12: SPA can still notify';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_mail_dedupe', 'SELECT'), 'M12: ledger is private';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE payload IS NOT NULL AND html <> ''), 'M12: payload rows carry no html';
  RAISE NOTICE 'PASS M12 no buyer PII in organizer mails; grants';
END $$;

ROLLBACK;
