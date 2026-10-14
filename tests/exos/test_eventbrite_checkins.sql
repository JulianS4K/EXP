-- ============================================================================
-- Eventbrite check-ins at the Exos door + one status vocabulary
-- (mig 20261014120000):
--   K1 apply stores Eventbrite's state (checked_in, status word, refunded)
--      and every barcode with Eventbrite's status, apart from the guest's
--      Exos arrivals (arrived stays 0)
--   K2 the door refuses a guest Eventbrite checked in ('checked-in-elsewhere',
--      where / at / method); the download and the status say so
--   K3 a check-out on Eventbrite lets them in; checked in on both reads
--      'used' at the door and 'both' in the lookup
--   K4 a used barcode alone counts as checked in; bad times never error
--   K5 two barcode stores: Eventbrite's codes are in exos_eventbrite_barcodes
--      (normalized), never in exos_tickets
--   K6 the status words
--   K7 lookup: Exos tickets and every guest in Eventbrite's words, counts,
--      filter, search; owner / manager only
--   K8 grants
-- Self-contained (BEGIN / ROLLBACK). Org e6…01 owned by …a1; manager …a2,
-- scanner …a3, outsider …a6.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('e6000000-0000-0000-0000-0000000000a1','e6own@x.com',now()),
  ('e6000000-0000-0000-0000-0000000000a2','e6mgr@x.com',now()),
  ('e6000000-0000-0000-0000-0000000000a3','e6scan@x.com',now()),
  ('e6000000-0000-0000-0000-0000000000a6','e6out@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('e6000000-0000-0000-0000-000000000001','EB Door Org','eb-door-org-stub','e6000000-0000-0000-0000-0000000000a1'),
  ('e6000000-0000-0000-0000-000000000002','EB Door Other','eb-door-other-stub','e6000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('e6000000-0000-0000-0000-000000000001','e6000000-0000-0000-0000-0000000000a1','owner'),
  ('e6000000-0000-0000-0000-000000000001','e6000000-0000-0000-0000-0000000000a2','manager'),
  ('e6000000-0000-0000-0000-000000000001','e6000000-0000-0000-0000-0000000000a3','scanner'),
  ('e6000000-0000-0000-0000-000000000002','e6000000-0000-0000-0000-0000000000a6','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('e6000000-0000-0000-0000-0000000000e1','e6000000-0000-0000-0000-000000000001','EB Door Night','eb-door-night-stub','draft',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'e6000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  ('e6000000-0000-0000-0000-0000000000f1','e6000000-0000-0000-0000-0000000000e1','GA',30,100);
-- Exos tickets: one active, one checked in, one refunded, one transferred.
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,check_in_at,voided_reason)
SELECT ('e6000000-0000-0000-0000-0000000000' || k)::uuid, 'e6000000-0000-0000-0000-0000000000e1',
       'e6000000-0000-0000-0000-000000000001', 'e6000000-0000-0000-0000-0000000000f1', 'GA',
       'e6000000-0000-0000-0000-0000000000a1', 'e6000000-0000-0000-0000-0000000000a1', em, st,
       gen_random_uuid()::text, 30, 'ord-' || k, CASE WHEN st = 'used' THEN now() END, vr
  FROM (VALUES ('c1', 'tess@x.com', 'active', NULL), ('c2', 'uma@x.com', 'used', NULL),
               ('c3', 'vic@x.com', 'voided', 'refunded'), ('c4', 'wes@x.com', 'transferred', NULL)) v(k, em, st, vr);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('e6000000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.ap(p_rows jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_eventbrite_apply(pg_temp.u('e1'),
           (SELECT lease_id FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')), p_rows, 'more')
$$;
CREATE FUNCTION pg_temp.entry(p_ref text) RETURNS public.exos_guest_list_entries LANGUAGE sql AS $$
  SELECT * FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND external_ref = 'eb:' || p_ref
$$;
CREATE FUNCTION pg_temp.att(p_ref text) RETURNS public.exos_eventbrite_attendees LANGUAGE sql AS $$
  SELECT * FROM public.exos_eventbrite_attendees WHERE event_id = pg_temp.u('e1') AND eb_attendee_id = p_ref
$$;
CREATE FUNCTION pg_temp.door(p_ref text, p_n int DEFAULT 1) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_guest_check_in((pg_temp.entry(p_ref)).id, p_n, pg_temp.u('e1'), gen_random_uuid(), 'online')
$$;

-- Connect, link, claim (service role).
DO $$
BEGIN
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_eventbrite_connect('e6000000-0000-0000-0000-000000000001', pg_temp.u('a1'), 'TOKENDOOR1111', 'Door Room');
  PERFORM public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a1'), '611', 'EB Door Night on Eventbrite');
  PERFORM count(*) FROM public.exos_eventbrite_sync_claim();
  ASSERT (SELECT lease_id IS NOT NULL FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')), 'setup: claimed';
END $$;

-- K1. Apply stores Eventbrite's state apart from the Exos arrivals.
DO $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.ap(jsonb_build_array(
    jsonb_build_object('ref', '7101', 'code', '6100 0001', 'name', 'Kim Scan', 'ticket', 'GA', 'void', false,
                       'status', 'Checked In', 'checked_in', true, 'changed', '2026-10-14T21:05:00Z',
                       'barcodes', jsonb_build_array(jsonb_build_object('code', '6100 0001', 'status', 'used',
                                                                        'checkin_type', 1, 'changed', '2026-10-14T21:04:30Z'))),
    jsonb_build_object('ref', '7102', 'code', '61000002', 'name', 'Lee Waiting', 'email', 'lee@x.com', 'void', false,
                       'status', 'Attending', 'checked_in', false,
                       'barcodes', jsonb_build_array(jsonb_build_object('code', '61000002', 'status', 'unused', 'checkin_type', 0))),
    jsonb_build_object('ref', '7103', 'code', '61000003', 'name', 'Mo Refund', 'void', false,
                       'status', 'Attending', 'checked_in', false,
                       'barcodes', jsonb_build_array(jsonb_build_object('code', '61000003', 'status', 'unused')))));
  ASSERT r->>'added' = '3' AND r->>'errors' = '0', 'K1: ' || r::text;
  ASSERT (pg_temp.att('7101')).checked_in AND (pg_temp.att('7101')).eb_status = 'Checked In'
         AND (pg_temp.att('7101')).checkin_method = 'scan'
         AND (pg_temp.att('7101')).checked_in_at = '2026-10-14T21:04:30Z'::timestamptz, 'K1: checked-in attendee';
  ASSERT (pg_temp.att('7101')).entry_id = (pg_temp.entry('7101')).id, 'K1: tied to the guest';
  ASSERT (pg_temp.entry('7101')).arrived = 0, 'K1: Exos arrivals untouched';
  ASSERT NOT (pg_temp.att('7102')).checked_in AND (pg_temp.att('7102')).checked_in_at IS NULL, 'K1: not in';
  ASSERT (SELECT status FROM public.exos_eventbrite_barcodes WHERE event_id = pg_temp.u('e1') AND barcode = '61000001') = 'used',
         'K1: barcode with Eventbrite''s status';
  -- Mo is refunded on Eventbrite later: voided, refunded flag kept.
  r := pg_temp.ap(jsonb_build_array(
    jsonb_build_object('ref', '7103', 'code', '61000003', 'name', 'Mo Refund', 'void', true, 'reason', 'refunded',
                       'status', 'Not Attending', 'refunded', true, 'checked_in', false,
                       'barcodes', jsonb_build_array(jsonb_build_object('code', '61000003', 'status', 'refunded')))));
  ASSERT (pg_temp.att('7103')).refunded AND (pg_temp.att('7103')).eb_status = 'Not Attending', 'K1: refund stored';
  ASSERT (pg_temp.entry('7103')).voided_at IS NOT NULL, 'K1: voided as before';
END $$;

-- K2. The door counts Eventbrite's check-in.
DO $$
DECLARE r jsonb; x jsonb; g jsonb;
BEGIN
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a3');
  r := pg_temp.door('7101');
  ASSERT r->>'ok' = 'false' AND r->>'reason' = 'checked-in-elsewhere', 'K2: ' || r::text;
  ASSERT r->'elsewhere'->>'where' = 'Eventbrite' AND r->'elsewhere'->>'method' = 'scan'
         AND (r->'elsewhere'->>'at')::timestamptz = '2026-10-14T21:04:30Z'::timestamptz, 'K2: where / when ' || r::text;
  ASSERT (pg_temp.entry('7101')).arrived = 0, 'K2: nothing recorded';
  r := pg_temp.door('7102');
  ASSERT r->>'ok' = 'true' AND r->>'reason' = 'checked-in', 'K2: not checked in elsewhere ' || r::text;
  x := public.exos_event_door_extras(pg_temp.u('e1'));
  SELECT value INTO g FROM jsonb_array_elements(x->'guests') WHERE value->>'guest_name' = 'Kim Scan';
  ASSERT g->'elsewhere'->>'where' = 'Eventbrite' AND g->>'eb_status' = 'Checked In', 'K2: download ' || g::text;
  SELECT value INTO g FROM jsonb_array_elements(x->'guests') WHERE value->>'guest_name' = 'Lee Waiting';
  ASSERT g->'elsewhere' = 'null'::jsonb AND g->>'eb_status' = 'Attending', 'K2: download, not in ' || g::text;
  ASSERT public.exos_eventbrite_status(pg_temp.u('e1'))->'link'->>'checked_in_on_eventbrite' = '1', 'K2: status count';
END $$;

-- K3. Check-out on Eventbrite, then both.
DO $$
DECLARE r jsonb; l jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  r := pg_temp.ap(jsonb_build_array(
    jsonb_build_object('ref', '7101', 'code', '61000001', 'name', 'Kim Scan', 'void', false,
                       'status', 'Attending', 'checked_in', false,
                       'barcodes', jsonb_build_array(jsonb_build_object('code', '61000001', 'status', 'unused', 'checkin_type', 0)))));
  ASSERT NOT (pg_temp.att('7101')).checked_in AND (pg_temp.att('7101')).checkin_method IS NULL, 'K3: checked out';
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a3');
  r := pg_temp.door('7101');
  ASSERT r->>'ok' = 'true', 'K3: admitted after check-out ' || r::text;
  -- Lee is scanned at Exos, then on Eventbrite's app too.
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.ap(jsonb_build_array(
    jsonb_build_object('ref', '7102', 'code', '61000002', 'name', 'Lee Waiting', 'void', false,
                       'status', 'Checked In', 'checked_in', true,
                       'barcodes', jsonb_build_array(jsonb_build_object('code', '61000002', 'status', 'used', 'checkin_type', 2)))));
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a3');
  r := pg_temp.door('7102');
  ASSERT r->>'ok' = 'false' AND r->>'reason' = 'used', 'K3: in on both reads used ' || r::text;
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a1');
  l := public.exos_attendee_lookup(pg_temp.u('e1'), 'lee@x.com');
  ASSERT jsonb_array_length(l->'rows') = 1 AND l->'rows'->0->>'checked_in_on' = 'both'
         AND l->'rows'->0->>'status' = 'Checked In' AND l->'rows'->0->>'code_status' = 'used', 'K3: lookup ' || l::text;
END $$;

-- K4. A used barcode alone counts; bad times are ignored.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  r := pg_temp.ap(jsonb_build_array(
    jsonb_build_object('ref', '7104', 'code', '61000004', 'name', 'Nia Barcode', 'void', false,
                       'status', 'Attending', 'changed', 'yesterday',
                       'barcodes', jsonb_build_array(jsonb_build_object('code', '61000004', 'status', 'used', 'changed', '14/10/2026')))));
  ASSERT r->>'errors' = '0', 'K4: ' || r::text;
  ASSERT public._exos_eb_ts('2026-02-30T10:00:00Z') IS NULL AND public._exos_eb_ts('2026-13-01T10:00:00Z') IS NULL
     AND public._exos_eb_ts('2026-10-14T21:04:30Z') = '2026-10-14T21:04:30Z'::timestamptz, 'K4: impossible dates are NULL';
  ASSERT (pg_temp.att('7104')).checked_in AND (pg_temp.att('7104')).eb_changed_at IS NULL
         AND (pg_temp.att('7104')).checked_in_at IS NOT NULL, 'K4: barcode used = in';
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.door('7104')->>'reason' = 'checked-in-elsewhere', 'K4: door';
END $$;

-- K5. Two barcode stores.
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_eventbrite_barcodes WHERE event_id = pg_temp.u('e1')) = 4, 'K5: four Eventbrite codes';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets t JOIN public.exos_eventbrite_barcodes b ON b.barcode = upper(t.barcode_secret)),
         'K5: never in exos_tickets';
  ASSERT (pg_temp.entry('7101')).external_code = '61000001', 'K5: the door code is the normalized barcode';
END $$;

-- K6. The words.
DO $$
BEGIN
  ASSERT public.exos_eb_status_word('ticket', 'active') = 'Attending'
     AND public.exos_eb_status_word('ticket', 'used') = 'Checked In'
     AND public.exos_eb_status_word('ticket', 'transferred') = 'Transferred'
     AND public.exos_eb_status_word('ticket', 'voided') = 'Not Attending'
     AND public.exos_eb_status_word('guest', 'expected') = 'Attending'
     AND public.exos_eb_status_word('guest', 'in') = 'Checked In'
     AND public.exos_eb_status_word('guest', 'voided') = 'Not Attending'
     AND public.exos_eb_status_word('ticket', 'nope') IS NULL, 'K6: words';
END $$;

-- K7. Lookup.
DO $$
DECLARE l jsonb;
BEGIN
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a2');
  l := public.exos_attendee_lookup(pg_temp.u('e1'));
  -- Exos: tess Attending, uma Checked In, vic Not Attending, wes Transferred.
  -- Guests: Kim Checked In (Exos), Lee Checked In (both), Mo Not Attending, Nia Checked In (Eventbrite).
  ASSERT (l->'counts'->>'Attending')::int = 1 AND (l->'counts'->>'Checked In')::int = 4
         AND (l->'counts'->>'Not Attending')::int = 2 AND (l->'counts'->>'Transferred')::int = 1, 'K7: counts ' || (l->'counts')::text;
  ASSERT jsonb_array_length(l->'rows') = 8, 'K7: all rows';
  l := public.exos_attendee_lookup(pg_temp.u('e1'), NULL, 'Not Attending');
  ASSERT jsonb_array_length(l->'rows') = 2
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(l->'rows') z WHERE z->>'email' = 'vic@x.com' AND (z->>'refunded')::boolean AND z->>'source' = 'Exos')
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(l->'rows') z WHERE z->>'name' = 'Mo Refund' AND (z->>'refunded')::boolean
                  AND z->>'detail' = 'Not Attending' AND z->>'channel' = 'eventbrite' AND z->>'code_status' = 'refunded'),
         'K7: filter ' || l::text;
  l := public.exos_attendee_lookup(pg_temp.u('e1'), '6100 0004');
  ASSERT jsonb_array_length(l->'rows') = 1 AND l->'rows'->0->>'checked_in_on' = 'eventbrite', 'K7: by code ' || l::text;
  l := public.exos_attendee_lookup(pg_temp.u('e1'), 'ord-c2');
  ASSERT l->'rows'->0->>'status' = 'Checked In' AND l->'rows'->0->>'checked_in_on' = 'exos', 'K7: by order ref';
  BEGIN
    PERFORM public.exos_attendee_lookup(pg_temp.u('e1'), NULL, 'Refunded');
    RAISE EXCEPTION 'K7: an unknown word was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a3');
  BEGIN
    PERFORM public.exos_attendee_lookup(pg_temp.u('e1'));
    RAISE EXCEPTION 'K7: a scanner looked up attendees';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a6');
  BEGIN
    PERFORM public.exos_attendee_lookup(pg_temp.u('e1'));
    RAISE EXCEPTION 'K7: an outsider looked up attendees';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- K8. Grants.
DO $$
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_eventbrite_attendees', 'SELECT'), 'K8: attendees';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_eventbrite_barcodes', 'SELECT'), 'K8: barcodes';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_eb_attendee_upsert(uuid, uuid, jsonb)', 'EXECUTE'), 'K8: upsert';
  ASSERT NOT has_function_privilege('anon', 'public.exos_attendee_lookup(uuid, text, text, integer)', 'EXECUTE'), 'K8: lookup anon';
  ASSERT has_function_privilege('authenticated', 'public.exos_attendee_lookup(uuid, text, text, integer)', 'EXECUTE'), 'K8: lookup';
END $$;

\echo 'eventbrite checkins: all assertions passed'
ROLLBACK;
