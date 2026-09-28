-- ============================================================================
-- Door hardening (migs 20260929040000 + 20260929041000):
--   D1 offline replay verifies the scanned code at the scan time, idempotent
--   D2 a code signed before a transfer is a conflict, not an admission
--   D3 the offline window is bounded (24h back, nothing in the future)
--   D4 typed override: owner / manager with a reason; scanners need a manager
--   D5 "already used" says when and on which device
--   D6 undo a check-in (manager, reason, audited; a replayed ref stays done)
--   D7 scanners limited to events (tickets + guest lists)
--   D8 server clock
-- Self-contained (BEGIN / ROLLBACK). Org d0…01; owner …a1, manager …a2,
-- scanner …a3 (org-wide), scanner …a4 (limited later), holder …a5, new
-- holder …a6. Events …e1 and …e2 (doors open), …e9 in another org.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d0000000-0000-0000-0000-0000000000a1','d0own@x.com',now()),
  ('d0000000-0000-0000-0000-0000000000a2','d0mgr@x.com',now()),
  ('d0000000-0000-0000-0000-0000000000a3','d0scan@x.com',now()),
  ('d0000000-0000-0000-0000-0000000000a4','d0scan2@x.com',now()),
  ('d0000000-0000-0000-0000-0000000000a5','d0hold@x.com',now()),
  ('d0000000-0000-0000-0000-0000000000a6','d0new@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d0000000-0000-0000-0000-000000000001','Door Org','door-org-stub','d0000000-0000-0000-0000-0000000000a1'),
  ('d0000000-0000-0000-0000-000000000002','Other Org','door-other-stub','d0000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-0000000000a1','owner'),
  ('d0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-0000000000a2','manager'),
  ('d0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-0000000000a3','scanner'),
  ('d0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-0000000000a4','scanner'),
  ('d0000000-0000-0000-0000-000000000002','d0000000-0000-0000-0000-0000000000a6','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('d0000000-0000-0000-0000-0000000000e1','d0000000-0000-0000-0000-000000000001','Door One','door-one-stub','published',
   now() + interval '1 hour', now() - interval '26 hours', 0, 'd0000000-0000-0000-0000-0000000000a1'),
  ('d0000000-0000-0000-0000-0000000000e2','d0000000-0000-0000-0000-000000000001','Door Two','door-two-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'd0000000-0000-0000-0000-0000000000a1'),
  ('d0000000-0000-0000-0000-0000000000e9','d0000000-0000-0000-0000-000000000002','Elsewhere','door-else-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'd0000000-0000-0000-0000-0000000000a6');
-- c1..c8 on e1, c9 on e2; holder a5, secret 'sek-<n>'.
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
SELECT ('d0000000-0000-0000-0000-00000000c00' || n)::uuid,
       CASE WHEN n = 9 THEN 'd0000000-0000-0000-0000-0000000000e2'::uuid ELSE 'd0000000-0000-0000-0000-0000000000e1'::uuid END,
       'd0000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-0000000000a5','d0000000-0000-0000-0000-0000000000a5',
       'active','sek-' || n, 20, 'door-seed-' || n
  FROM generate_series(1, 9) n;

-- A signed barcode for a ticket, as its holder's phone shows it at time p_at.
CREATE FUNCTION pg_temp.door_code(p_ticket uuid, p_at timestamptz) RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' ||
         rtrim(translate(encode(extensions.hmac(t.id || ':' || t.owner_id || ':' || b, t.barcode_secret, 'sha256'),
                                'base64'), '+/', '-_'), '=')
    FROM public.exos_tickets t,
         LATERAL (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint::text AS b) x
   WHERE t.id = p_ticket;
$$;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;

-- D1. Offline replay: verified at the scan time; the same ref twice counts once.
DO $$
DECLARE
  e1 uuid := 'd0000000-0000-0000-0000-0000000000e1';
  c1 uuid := 'd0000000-0000-0000-0000-00000000c001';
  ref uuid := 'd0000000-0000-0000-0000-0000000000f1';
  at timestamptz := now() - interval '20 minutes';
  code text := pg_temp.door_code(c1, now() - interval '20 minutes');
  r jsonb;
BEGIN
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a3');
  -- Online, that 20-minute-old code is long expired.
  ASSERT public.exos_check_in_ticket(c1, 'camera', 'verified', code, e1) ->> 'reason' = 'barcode-expired',
         'D1: an old code is expired on the live path';
  r := public.exos_check_in_offline(ref, c1, e1, at, code, 'camera', NULL, 'Door A');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in', 'D1: offline replay admits, got ' || r;
  ASSERT (SELECT check_in_at FROM public.exos_tickets WHERE id = c1) = at, 'D1: check_in_at is the scan time';
  ASSERT (SELECT verification || '/' || source || '/' || device || '/' || (offline_scanned_at = at)
            FROM public.exos_event_checkins WHERE ticket_id = c1) = 'verified/camera/Door A/true',
         'D1: logged as a verified offline camera scan';
  r := public.exos_check_in_offline(ref, c1, e1, at, code, 'camera', NULL, 'Door A');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'duplicate')::boolean, 'D1: same ref again is a duplicate, got ' || r;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = c1) = 1, 'D1: counted once';
  ASSERT public.exos_check_in_offline(ref, 'd0000000-0000-0000-0000-00000000c002', e1, at, code) ->> 'reason' = 'bad-client-ref',
         'D1: a ref is bound to its ticket';
  RAISE NOTICE 'OK  D1 offline replay verified + idempotent';
END $$;

-- D2. Transferred after the roster sync: the old holder's code is a conflict.
DO $$
DECLARE
  e1 uuid := 'd0000000-0000-0000-0000-0000000000e1';
  c2 uuid := 'd0000000-0000-0000-0000-00000000c002';
  at timestamptz := now() - interval '5 minutes';
  old_code text := pg_temp.door_code('d0000000-0000-0000-0000-00000000c002', now() - interval '5 minutes');
  r jsonb;
BEGIN
  -- The claim moves the ticket to a6 and rotates the secret.
  UPDATE public.exos_tickets SET owner_id = 'd0000000-0000-0000-0000-0000000000a6', buyer_id = 'd0000000-0000-0000-0000-0000000000a6',
         barcode_secret = 'rotated-2' WHERE id = c2;
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a3');
  r := public.exos_check_in_offline('d0000000-0000-0000-0000-0000000000f2', c2, e1, at, old_code, 'camera');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'barcode-rejected' AND (r ->> 'conflict')::boolean,
         'D2: pre-transfer code refused as a conflict, got ' || r;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c2) = 'active', 'D2: ticket not consumed';
  ASSERT (SELECT reason || '/' || reason_detail FROM public.exos_scan_rejects WHERE ticket_id_attempted = c2::text)
         = 'invalid-barcode/offline-replay:barcode-rejected', 'D2: conflict logged for the scan report';
  -- The new holder's code, scanned offline, is fine.
  r := public.exos_check_in_offline('d0000000-0000-0000-0000-0000000000f3', c2, e1, now() - interval '1 minute',
                                    pg_temp.door_code(c2, now() - interval '1 minute'), 'camera');
  ASSERT (r ->> 'ok')::boolean, 'D2: new holder''s code admits, got ' || r;
  RAISE NOTICE 'OK  D2 transfer after sync is a conflict';
END $$;

-- D3. The offline window: at most 24 hours old, never in the future.
DO $$
DECLARE e1 uuid := 'd0000000-0000-0000-0000-0000000000e1'; c3 uuid := 'd0000000-0000-0000-0000-00000000c003';
BEGIN
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_check_in_offline('d0000000-0000-0000-0000-0000000000f4', c3, e1, now() - interval '25 hours',
           pg_temp.door_code(c3, now() - interval '25 hours')) ->> 'reason' = 'bad-scan-time', 'D3: 25h old refused';
  ASSERT public.exos_check_in_offline('d0000000-0000-0000-0000-0000000000f5', c3, e1, now() + interval '10 minutes',
           pg_temp.door_code(c3, now() + interval '10 minutes')) ->> 'reason' = 'bad-scan-time', 'D3: future refused';
  -- The code must match the claimed scan time, not just any time in the window.
  ASSERT public.exos_check_in_offline('d0000000-0000-0000-0000-0000000000f6', c3, e1, now() - interval '3 hours',
           pg_temp.door_code(c3, now() - interval '1 hour')) ->> 'reason' = 'barcode-expired', 'D3: code/time mismatch';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c3) = 'active', 'D3: nothing consumed';
  RAISE NOTICE 'OK  D3 offline window bounded';
END $$;

-- D4. Typed override: owner / manager, with a reason.
DO $$
DECLARE e1 uuid := 'd0000000-0000-0000-0000-0000000000e1'; c4 uuid := 'd0000000-0000-0000-0000-00000000c004'; r jsonb;
BEGIN
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_check_in_ticket(c4, 'manual', 'manual', NULL, e1, 'phone died') ->> 'reason' = 'needs-manager',
         'D4: a scanner cannot type a ticket in';
  ASSERT public.exos_check_in_ticket(c4, 'manual', 'manual', c4::text, e1, 'phone died') ->> 'reason' = 'needs-manager',
         'D4: a typed bare id is the same override';
  r := public.exos_check_in_offline('d0000000-0000-0000-0000-0000000000f7', c4, e1, now() - interval '2 minutes', NULL, 'manual', 'phone died');
  ASSERT r ->> 'reason' = 'needs-manager' AND (r ->> 'conflict')::boolean, 'D4: nor offline, got ' || r;
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a2');
  ASSERT public.exos_check_in_ticket(c4, 'manual', 'manual', NULL, e1) ->> 'reason' = 'reason-required',
         'D4: manager needs a reason';
  ASSERT public.exos_check_in_ticket(c4, 'manual', 'manual', NULL, e1, '  ') ->> 'reason' = 'reason-required',
         'D4: blank reason refused';
  ASSERT public.exos_check_in_ticket(c4, 'manual', 'manual', NULL, e1, 'Phone died, checked ID') ->> 'reason' = 'checked-in',
         'D4: manager with a reason admits';
  ASSERT (SELECT verification || '/' || source || '/' || override_reason FROM public.exos_event_checkins WHERE ticket_id = c4)
         = 'manual/manual/Phone died, checked ID', 'D4: override logged with its reason';
  RAISE NOTICE 'OK  D4 typed override needs a manager + reason';
END $$;

-- D5. "Already used" says when and where.
DO $$
DECLARE e1 uuid := 'd0000000-0000-0000-0000-0000000000e1'; c1 uuid := 'd0000000-0000-0000-0000-00000000c001'; r jsonb;
BEGIN
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a3');
  r := public.exos_check_in_ticket(c1, 'camera', 'verified', pg_temp.door_code(c1, now()), e1);
  ASSERT r ->> 'reason' = 'used', 'D5: used, got ' || r;
  ASSERT (r ->> 'check_in_at')::timestamptz = (SELECT check_in_at FROM public.exos_tickets WHERE id = c1), 'D5: carries check_in_at';
  ASSERT r ->> 'device' = 'Door A' AND r ->> 'source' = 'camera', 'D5: carries the device, got ' || r;
  r := public.exos_check_in_ticket('d0000000-0000-0000-0000-00000000c005', 'camera', 'verified',
                                   pg_temp.door_code('d0000000-0000-0000-0000-00000000c005', now()), e1);
  ASSERT r ->> 'reason' = 'checked-in' AND r ? 'check_in_at', 'D5: a fresh check-in returns its time, got ' || r;
  RAISE NOTICE 'OK  D5 used answer carries when + device';
END $$;

-- D6. Undo a check-in.
DO $$
DECLARE e1 uuid := 'd0000000-0000-0000-0000-0000000000e1'; c1 uuid := 'd0000000-0000-0000-0000-00000000c001'; r jsonb;
BEGIN
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_undo_check_in(c1, e1, 'wrong person') ->> 'reason' = 'needs-manager', 'D6: scanner cannot undo';
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a2');
  ASSERT public.exos_undo_check_in(c1, e1, '') ->> 'reason' = 'reason-required', 'D6: reason required';
  ASSERT public.exos_undo_check_in(c1, 'd0000000-0000-0000-0000-0000000000e2', 'wrong person') ->> 'reason' = 'wrong-event',
         'D6: event must match';
  r := public.exos_undo_check_in(c1, e1, 'Scanned the wrong person');
  ASSERT (r ->> 'ok')::boolean, 'D6: manager undoes, got ' || r;
  ASSERT (SELECT status = 'active' AND check_in_at IS NULL FROM public.exos_tickets WHERE id = c1), 'D6: ticket active again';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkins WHERE ticket_id = c1), 'D6: no longer counted';
  ASSERT (SELECT jsonb_array_length(checkins) = 1 AND reason = 'Scanned the wrong person'
                 AND undone_by = 'd0000000-0000-0000-0000-0000000000a2'
            FROM public.exos_checkin_undos WHERE ticket_id = c1), 'D6: audited with the removed row';
  ASSERT public.exos_undo_check_in(c1, e1, 'again please') ->> 'reason' = 'not-checked-in', 'D6: nothing to undo';
  -- The old offline ref replayed after the undo does not re-admit.
  r := public.exos_check_in_offline('d0000000-0000-0000-0000-0000000000f1', c1, e1, now() - interval '20 minutes',
                                    pg_temp.door_code(c1, now() - interval '20 minutes'), 'camera');
  ASSERT (r ->> 'duplicate')::boolean, 'D6: replayed ref is a duplicate';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c1) = 'active', 'D6: still active after the replay';
  -- And the ticket can be scanned in again.
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_check_in_ticket(c1, 'camera', 'verified', pg_temp.door_code(c1, now()), e1) ->> 'reason' = 'checked-in',
         'D6: rescans after an undo';
  RAISE NOTICE 'OK  D6 undo check-in';
END $$;

-- D7. Scanners limited to events.
INSERT INTO public.exos_guest_lists(id,event_id,org_id,name) VALUES
  ('d0000000-0000-0000-0000-0000000000b1','d0000000-0000-0000-0000-0000000000e2','d0000000-0000-0000-0000-000000000001','VIP');
INSERT INTO public.exos_guest_list_entries(id,list_id,event_id,org_id,guest_name,plus_ones) VALUES
  ('d0000000-0000-0000-0000-0000000000b2','d0000000-0000-0000-0000-0000000000b1','d0000000-0000-0000-0000-0000000000e2',
   'd0000000-0000-0000-0000-000000000001','Gina Guest',1);
DO $$
DECLARE
  org uuid := 'd0000000-0000-0000-0000-000000000001';
  e1 uuid := 'd0000000-0000-0000-0000-0000000000e1';
  e2 uuid := 'd0000000-0000-0000-0000-0000000000e2';
  a4 uuid := 'd0000000-0000-0000-0000-0000000000a4';
  c6 uuid := 'd0000000-0000-0000-0000-00000000c006';
  c9 uuid := 'd0000000-0000-0000-0000-00000000c009';
  raised boolean;
BEGIN
  -- Unrestricted by default.
  PERFORM pg_temp.act(a4::text);
  ASSERT public.exos_can_door_event(e1) AND public.exos_can_door_event(e2), 'D7: no rows = org-wide';
  -- Only owner / manager set it.
  raised := false;
  BEGIN PERFORM public.exos_set_scanner_events(org, a4, ARRAY[e1]);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'D7: a scanner cannot set scopes';
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a2');
  raised := false;
  BEGIN PERFORM public.exos_set_scanner_events(org, a4, ARRAY['d0000000-0000-0000-0000-0000000000e9'::uuid]);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'D7: another org''s event refused';
  ASSERT public.exos_set_scanner_events(org, a4, ARRAY[e1, e1]) = 1, 'D7: limited to e1';

  PERFORM pg_temp.act(a4::text);
  ASSERT public.exos_can_door_event(e1) AND NOT public.exos_can_door_event(e2), 'D7: e1 only';
  ASSERT public.exos_check_in_ticket(c9, 'camera', 'verified', pg_temp.door_code(c9, now()), e2) ->> 'reason' = 'not-assigned',
         'D7: ticket check-in on e2 refused';
  ASSERT public.exos_guest_check_in('d0000000-0000-0000-0000-0000000000b2', 1, e2) ->> 'reason' = 'not-assigned',
         'D7: guest check-in on e2 refused';
  ASSERT public.exos_check_in_ticket(c6, 'camera', 'verified', pg_temp.door_code(c6, now()), e1) ->> 'reason' = 'checked-in',
         'D7: e1 still works';
  -- The org-wide scanner and the manager are unaffected.
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_can_door_event(e2), 'D7: other scanners unaffected';
  PERFORM pg_temp.act('d0000000-0000-0000-0000-0000000000a2');
  ASSERT public.exos_can_door_event(e2), 'D7: managers never limited';
  -- Clearing the list restores org-wide access.
  ASSERT public.exos_set_scanner_events(org, a4, '{}') = 0, 'D7: cleared';
  PERFORM pg_temp.act(a4::text);
  ASSERT public.exos_guest_check_in('d0000000-0000-0000-0000-0000000000b2', 1, e2) ->> 'reason' = 'checked-in',
         'D7: guest check-in works again';
  RAISE NOTICE 'OK  D7 scanner event scope';
END $$;

-- D8. Server clock.
DO $$
BEGIN
  ASSERT abs(extract(epoch FROM public.exos_server_time() - clock_timestamp())) < 5, 'D8: server time is now';
  ASSERT has_function_privilege('anon', 'public.exos_server_time()', 'EXECUTE'), 'D8: callable before sign-in';
  ASSERT NOT has_function_privilege('anon', 'public.exos_check_in_offline(uuid, uuid, uuid, timestamptz, text, text, text, text)', 'EXECUTE'),
         'D8: offline replay is not anonymous';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_used_answer(uuid)', 'EXECUTE'), 'D8: helper is private';
  RAISE NOTICE 'OK  D8 server time + grants';
END $$;

ROLLBACK;
