-- ============================================================================
-- Transfers and claim links expire when the event ends (mig 20261002101500).
--   X1 status takes 'expired', not anything else
--   X2 a pending link on an event that is over can't be claimed; nothing moves
--   X3 the same on a live event still claims (control)
--   X4 a holder can't start a transfer once the event is over; can before
--   X5 "over" = ends_at, else starts_at + 12 h; no start time never ends
--   X6 a service-role insert (webhook fulfilment) on an ended event is allowed
--   X7 the claim preview says 'expired' before the sweep runs
--   X8 the sweep expires due links, gives the ticket back to the sender,
--      leaves live ones, and is idempotent
--   X9 a rescheduled event moves the expiry with it
--   X10 grants: the sweep and the helper aren't callable by clients
-- Self-contained (c9 prefix), rolled back at the end.
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_transfer_expiry.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c9000000-0000-0000-0000-0000000000a1','c9own@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a5','c9hold@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000b1','c9friend@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c9000000-0000-0000-0000-000000000001','Expiry Org','expiry-org-stub','c9000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a1','owner');
-- e1 ended an hour ago (ends_at); e2 is live (ends tomorrow);
-- e3 has no end, started 13 h ago (over); e4 no end, started 11 h ago (not over);
-- e5 has no start time at all (never over).
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,ends_at,total_tickets,created_by) VALUES
  ('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-000000000001','Ended','c9-ended','published',
   now() - interval '5 hours', now() - interval '1 hour', 0, 'c9000000-0000-0000-0000-0000000000a1'),
  ('c9000000-0000-0000-0000-0000000000e2','c9000000-0000-0000-0000-000000000001','Live','c9-live','published',
   now() - interval '1 hour', now() + interval '1 day', 0, 'c9000000-0000-0000-0000-0000000000a1'),
  ('c9000000-0000-0000-0000-0000000000e3','c9000000-0000-0000-0000-000000000001','No end, old','c9-noend-old','published',
   now() - interval '13 hours', NULL, 0, 'c9000000-0000-0000-0000-0000000000a1'),
  ('c9000000-0000-0000-0000-0000000000e4','c9000000-0000-0000-0000-000000000001','No end, recent','c9-noend-new','published',
   now() - interval '11 hours', NULL, 0, 'c9000000-0000-0000-0000-0000000000a1'),
  ('c9000000-0000-0000-0000-0000000000e5','c9000000-0000-0000-0000-000000000001','No date','c9-nodate','published',
   NULL, NULL, 0, 'c9000000-0000-0000-0000-0000000000a1');

-- One active ticket per event for the holder, plus a second on e1 and e2.
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,tier_name)
SELECT ('c9000000-0000-0000-0000-00000000c' || lpad(n::text, 3, '0'))::uuid,
       ('c9000000-0000-0000-0000-0000000000e' || ev)::uuid,
       'c9000000-0000-0000-0000-000000000001',
       'c9000000-0000-0000-0000-0000000000a5','c9000000-0000-0000-0000-0000000000a5','c9hold@x.com',
       'active','c9-sek-' || n, 40, 'c9-web-' || n, 'GA'
  FROM (VALUES (1,1),(2,2),(3,3),(4,4),(5,5),(6,1),(7,2)) v(n, ev);

-- Pending transfers made before the event ended (inserted as the service
-- role would: no auth.uid()), each linked to its ticket.
INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,sender_email,receiver_email,status,event_id,created_at,updated_at)
SELECT ('c9000000-0000-0000-0000-0000000007' || lpad(n::text, 2, '0'))::uuid,
       ('c9000000-0000-0000-0000-00000000c' || lpad(n::text, 3, '0'))::uuid,
       'c9000000-0000-0000-0000-000000000001',
       'c9000000-0000-0000-0000-0000000000a5','c9hold@x.com','c9friend@x.com','pending',
       ('c9000000-0000-0000-0000-0000000000e' || ev)::uuid, now() - interval '2 days', now() - interval '2 days'
  FROM (VALUES (1,1),(2,2),(3,3),(4,4),(5,5)) v(n, ev);
UPDATE public.exos_tickets t SET pending_transfer_id = tr.id
  FROM public.exos_transfers tr WHERE tr.ticket_id = t.id AND tr.id::text LIKE 'c9000000-%';

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.claim_error(p_tr uuid) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.exos_test_claim(p_tr);
  RETURN NULL;
EXCEPTION WHEN raise_exception OR insufficient_privilege OR invalid_parameter_value THEN RETURN SQLERRM;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.create_error(p_ticket uuid) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.exos_create_transfer(p_ticket, 'c9friend@x.com');
  RETURN NULL;
EXCEPTION WHEN raise_exception OR insufficient_privilege OR invalid_parameter_value THEN RETURN SQLERRM;
END $$;

-- X1 -------------------------------------------------------------------------
DO $$
DECLARE ok boolean;
BEGIN
  BEGIN
    UPDATE public.exos_transfers SET status = 'bogus' WHERE id = 'c9000000-0000-0000-0000-000000000705';
    ok := false;
  EXCEPTION WHEN check_violation THEN ok := true;
  END;
  IF NOT ok THEN RAISE EXCEPTION 'X1 FAIL: status took a junk value'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_transfers_status_check'
                    AND pg_get_constraintdef(oid) LIKE '%expired%') THEN
    RAISE EXCEPTION 'X1 FAIL: status CHECK lacks expired';
  END IF;
  RAISE NOTICE 'X1 ok: status takes expired, not junk';
END $$;

-- X2 / X3 --------------------------------------------------------------------
DO $$
DECLARE err text; t record;
BEGIN
  PERFORM pg_temp.as_user('c9000000-0000-0000-0000-0000000000b1', 'c9friend@x.com');
  err := pg_temp.claim_error('c9000000-0000-0000-0000-000000000701');
  IF err IS NULL OR err NOT LIKE '%expired when the event ended%' THEN
    RAISE EXCEPTION 'X2 FAIL: ended claim gave %', coalesce(err, 'success');
  END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = 'c9000000-0000-0000-0000-00000000c001';
  IF t.owner_id <> 'c9000000-0000-0000-0000-0000000000a5' OR t.barcode_secret <> 'c9-sek-1'
     OR t.pending_transfer_id <> 'c9000000-0000-0000-0000-000000000701' THEN
    RAISE EXCEPTION 'X2 FAIL: ticket moved %', row_to_json(t);
  END IF;
  IF (SELECT status FROM public.exos_transfers WHERE id = 'c9000000-0000-0000-0000-000000000701') <> 'pending' THEN
    RAISE EXCEPTION 'X2 FAIL: transfer changed';
  END IF;
  RAISE NOTICE 'X2 ok: an ended link is refused and nothing moves';

  err := pg_temp.claim_error('c9000000-0000-0000-0000-000000000702');
  IF err IS NOT NULL THEN RAISE EXCEPTION 'X3 FAIL: live claim refused: %', err; END IF;
  IF (SELECT owner_id FROM public.exos_tickets WHERE id = 'c9000000-0000-0000-0000-00000000c002')
       <> 'c9000000-0000-0000-0000-0000000000b1' THEN
    RAISE EXCEPTION 'X3 FAIL: live claim did not move the ticket';
  END IF;
  RAISE NOTICE 'X3 ok: a live link still claims';
  PERFORM pg_temp.as_user(NULL, NULL);
END $$;

-- X4 / X5 --------------------------------------------------------------------
DO $$
DECLARE err text;
BEGIN
  PERFORM pg_temp.as_user('c9000000-0000-0000-0000-0000000000a5', 'c9hold@x.com');
  err := pg_temp.create_error('c9000000-0000-0000-0000-00000000c006');      -- e1, ended
  IF err IS NULL OR err NOT LIKE '%event has ended%' THEN
    RAISE EXCEPTION 'X4 FAIL: transfer on an ended event gave %', coalesce(err, 'success');
  END IF;
  IF (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = 'c9000000-0000-0000-0000-00000000c006') IS NOT NULL THEN
    RAISE EXCEPTION 'X4 FAIL: ticket locked by a refused transfer';
  END IF;
  err := pg_temp.create_error('c9000000-0000-0000-0000-00000000c007');      -- e2, live
  IF err IS NOT NULL THEN RAISE EXCEPTION 'X4 FAIL: live transfer refused: %', err; END IF;
  RAISE NOTICE 'X4 ok: no new transfer once the event is over';
  PERFORM pg_temp.as_user(NULL, NULL);

  IF NOT public._exos_event_over('c9000000-0000-0000-0000-0000000000e3')
     OR public._exos_event_over('c9000000-0000-0000-0000-0000000000e4')
     OR public._exos_event_over('c9000000-0000-0000-0000-0000000000e5')
     OR public._exos_event_over('c9000000-0000-0000-0000-0000000000e2')
     OR NOT public._exos_event_over('c9000000-0000-0000-0000-0000000000e1')
     OR public._exos_event_over(NULL) THEN
    RAISE EXCEPTION 'X5 FAIL: event-over rule';
  END IF;
  RAISE NOTICE 'X5 ok: ends_at, else start + 12 h; no start never ends';
END $$;

-- X6 -------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.as_user(NULL, NULL);
  INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status,event_id)
  VALUES ('c9000000-0000-0000-0000-000000000766','c9000000-0000-0000-0000-00000000c006',
          'c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a5',
          'late@x.com','pending','c9000000-0000-0000-0000-0000000000e1');
  UPDATE public.exos_tickets SET pending_transfer_id = 'c9000000-0000-0000-0000-000000000766'
   WHERE id = 'c9000000-0000-0000-0000-00000000c006';
  RAISE NOTICE 'X6 ok: a service-role insert on an ended event is allowed';
END $$;

-- X7 -------------------------------------------------------------------------
DO $$
BEGIN
  IF (SELECT status FROM public.exos_transfer_claim_preview('c9000000-0000-0000-0000-000000000701')) <> 'expired'
     OR (SELECT status FROM public.exos_transfer_claim_preview('c9000000-0000-0000-0000-000000000703')) <> 'expired'
     OR (SELECT status FROM public.exos_transfer_claim_preview('c9000000-0000-0000-0000-000000000704')) <> 'pending'
     OR (SELECT status FROM public.exos_transfer_claim_preview('c9000000-0000-0000-0000-000000000705')) <> 'pending'
     OR (SELECT status FROM public.exos_transfer_claim_preview('c9000000-0000-0000-0000-000000000702')) <> 'completed' THEN
    RAISE EXCEPTION 'X7 FAIL: preview statuses';
  END IF;
  -- Stored row is untouched until the sweep.
  IF (SELECT status FROM public.exos_transfers WHERE id = 'c9000000-0000-0000-0000-000000000701') <> 'pending' THEN
    RAISE EXCEPTION 'X7 FAIL: preview wrote the row';
  END IF;
  RAISE NOTICE 'X7 ok: preview says expired before the sweep';
END $$;

-- X8 -------------------------------------------------------------------------
DO $$
DECLARE n int; n2 int;
BEGIN
  n := public.exos_expire_transfers();
  -- 701 (e1), 703 (e3), 766 (e1, late) expire; 704 (e4), 705 (e5) and the new
  -- live one on e2 don't.
  IF (SELECT count(*) FROM public.exos_transfers
       WHERE id::text LIKE 'c9000000-%' AND status = 'expired') <> 3 OR n < 3 THEN
    RAISE EXCEPTION 'X8 FAIL: expired % (run returned %)',
      (SELECT array_agg(id) FROM public.exos_transfers WHERE id::text LIKE 'c9000000-%' AND status = 'expired'), n;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_transfers WHERE status = 'expired' AND id::text LIKE 'c9000000-%' AND expired_at IS NULL) THEN
    RAISE EXCEPTION 'X8 FAIL: expired_at not set';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_tickets
              WHERE id IN ('c9000000-0000-0000-0000-00000000c001','c9000000-0000-0000-0000-00000000c003',
                           'c9000000-0000-0000-0000-00000000c006')
                AND (pending_transfer_id IS NOT NULL OR owner_id <> 'c9000000-0000-0000-0000-0000000000a5'
                     OR status <> 'active')) THEN
    RAISE EXCEPTION 'X8 FAIL: tickets not back with the sender';
  END IF;
  IF (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = 'c9000000-0000-0000-0000-00000000c004')
       <> 'c9000000-0000-0000-0000-000000000704' THEN
    RAISE EXCEPTION 'X8 FAIL: a live link was touched';
  END IF;
  n2 := public.exos_expire_transfers();
  IF n2 <> 0 THEN RAISE EXCEPTION 'X8 FAIL: second run expired % more', n2; END IF;
  -- An expired link stays refused.
  PERFORM pg_temp.as_user('c9000000-0000-0000-0000-0000000000b1', 'c9friend@x.com');
  IF pg_temp.claim_error('c9000000-0000-0000-0000-000000000701') IS NULL THEN
    RAISE EXCEPTION 'X8 FAIL: an expired link claimed';
  END IF;
  PERFORM pg_temp.as_user(NULL, NULL);
  RAISE NOTICE 'X8 ok: sweep expires due links, returns tickets, idempotent';
END $$;

-- X9 -------------------------------------------------------------------------
DO $$
DECLARE err text;
BEGIN
  -- e4 (no end, started 11 h ago) gets an end time in the past, then moves out.
  UPDATE public.exos_events SET ends_at = now() - interval '1 minute' WHERE id = 'c9000000-0000-0000-0000-0000000000e4';
  IF (SELECT status FROM public.exos_transfer_claim_preview('c9000000-0000-0000-0000-000000000704')) <> 'expired' THEN
    RAISE EXCEPTION 'X9 FAIL: moved-in end not seen';
  END IF;
  UPDATE public.exos_events SET ends_at = now() + interval '3 hours' WHERE id = 'c9000000-0000-0000-0000-0000000000e4';
  PERFORM pg_temp.as_user('c9000000-0000-0000-0000-0000000000b1', 'c9friend@x.com');
  err := pg_temp.claim_error('c9000000-0000-0000-0000-000000000704');
  IF err IS NOT NULL THEN RAISE EXCEPTION 'X9 FAIL: rescheduled link refused: %', err; END IF;
  PERFORM pg_temp.as_user(NULL, NULL);
  RAISE NOTICE 'X9 ok: the expiry follows a reschedule';
END $$;

-- X10 ------------------------------------------------------------------------
DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.exos_expire_transfers(int)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.exos_expire_transfers(int)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._exos_event_over(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._exos_event_over(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.exos_tg_transfer_expiry()', 'EXECUTE') THEN
    RAISE EXCEPTION 'X10 FAIL: client grants';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.exos_expire_transfers(int)', 'EXECUTE') THEN
    RAISE EXCEPTION 'X10 FAIL: service role cannot sweep';
  END IF;
  RAISE NOTICE 'X10 ok: sweep and helper are not client-callable';
END $$;

ROLLBACK;
