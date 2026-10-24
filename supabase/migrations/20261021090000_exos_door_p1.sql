-- ============================================================================
-- Door P1s: scan times, refs, by-name test window, guests, summary, roster
-- paging, wallet push queue
-- ============================================================================
-- Touches:  P: exos_check_in_offline (10 args), exos_door_checkin_by_name
--              (8 args): a scan stamped up to 10 minutes ahead (a fast door
--              phone) is taken as now; a refusal for who uploaded it
--              ('not-assigned') or when ('bad-scan-time', nothing recorded)
--              keeps the client ref free so the scan can upload later.
--              exos_door_checkin_by_name: a parked (unclaimed) ticket checked
--              in by name inside the pre-doors test window is a test scan.
--              exos_event_door_summary: 'guests' (guest-list, imported and
--              Eventbrite arrivals).
--              exos_wallet_push_done: also stamps google_pushed_at.
--           C: COLUMN exos_guest_list_checkins.offline_scanned_at,
--              exos_wallet_passes.google_pushed_at
--              FUNCTION exos_event_door_roster_page (authenticated),
--              _exos_door_guest_summary (internal),
--              exos_wallet_google_done (service_role)
--           R: exos_guest_check_in: DROPPED and re-created with p_scanned_at
--              (the offline replay's scan time; same window rules as tickets).
--              Callers that pass the five named arguments keep working (the
--              new one defaults to NULL).
--              exos_event_door_roster: now a wrapper of the paged form (same
--              signature and rows).
--              exos_wallet_push_queue: Apple and Google read separately.
-- Pre-reqs: 20261019120000 (roster wallet delta), 20261014120000 (Eventbrite
--           check-ins), 20261008090000 (door summary), 20260929140000 (lists),
--           20260929072000 (wallet passes)
--
-- Roster paging: PostgREST pages the set-returning roster with ORDER BY /
-- LIMIT / OFFSET on top of the call, so every page computed the door keys of
-- every ticket (about 60 s of DB time per door per refresh at 30k tickets).
-- exos_event_door_roster_page pages inside: keyset on ticket_id (p_after) with
-- p_limit, so a page computes only its own rows.
--
-- Wallet: the queue read the oldest 100 pending passes. In the default Apple
-- dry run a pass with Apple devices registered is never cleared, so 100 of
-- them filled the window and Google passes behind them were never updated
-- (a voided ticket's Google pass stayed active). Apple (devices to push) and
-- Google (objects to update) now have their own windows, and Google's done
-- mark is separate (google_pushed_at), so a pass waiting on Apple leaves the
-- Google window once its object is updated.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  -- Pasted through a browser the patch text can carry CRLF line ends; compare without CRs.
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ---------------------------------------------------------------------------
-- 1. exos_check_in_offline (10 args)
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamp with time zone, text, text, text, text, uuid, text)',
  '/* p1 door: fast clock */',
  '  v_dir      text := lower(coalesce(nullif(btrim(p_direction), ''''), ''entry''));
BEGIN
',
  '  v_dir      text := lower(coalesce(nullif(btrim(p_direction), ''''), ''entry''));
  -- A door phone with a fast clock stamps its scans ahead: up to 10 minutes
  -- ahead is taken as now (the scan did happen), further is refused.
  v_at       timestamptz := CASE WHEN p_scanned_at > now() AND p_scanned_at <= now() + interval ''10 minutes''
                                 THEN now() ELSE p_scanned_at END; /* p1 door: fast clock */
BEGIN
', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamp with time zone, text, text, text, text, uuid, text)',
  '/* p1 door: scan at */',
  '''manual'', p_barcode_payload, p_event_id, p_reason, p_scanned_at, p_device,',
  '''manual'', p_barcode_payload, p_event_id, p_reason, v_at /* p1 door: scan at */, p_device,', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamp with time zone, text, text, text, text, uuid, text)',
  '/* p1 door: too old */',
  'CASE WHEN p_scanned_at <= now() + interval ''2 minutes'' THEN ''too-old'' END',
  'CASE WHEN v_at <= now() + interval ''2 minutes'' THEN ''too-old'' END /* p1 door: too old */', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamp with time zone, text, text, text, text, uuid, text)',
  '/* p1 door: forced at */',
  'p_source, ''manual'', p_device, p_scanned_at, v_conflict, p_reason);',
  'p_source, ''manual'', p_device, v_at /* p1 door: forced at */, v_conflict, p_reason);', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamp with time zone, text, text, text, text, uuid, text)',
  '/* p1 door: not-assigned */',
  '    IF v_org IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = v_org) THEN
',
  '    -- Who may upload is not a problem with the ticket: not on the scan report.
    IF v_org IS NOT NULL AND coalesce(r ->> ''reason'', '''') <> ''not-assigned'' /* p1 door: not-assigned */
       AND EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = v_org) THEN
', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamp with time zone, text, text, text, text, uuid, text)',
  '/* p1 door: ref kept */',
  '  INSERT INTO public.exos_checkin_client_refs (client_ref, ticket_id, event_id, org_id, scanned_by, result)
  VALUES (p_client_ref, p_ticket_id, v_event, v_org, v_uid, r)
  ON CONFLICT (client_ref) DO NOTHING;
',
  '  -- Refused for who uploaded it (not-assigned) or when (bad-scan-time, nothing
  -- recorded): the ref stays free, so the scan can still upload (the right
  -- account signs in, the clock is fixed) instead of the first answer standing.
  IF coalesce(r ->> ''reason'', '''') NOT IN (''not-assigned'', ''bad-scan-time'') OR r ? ''forced'' THEN /* p1 door: ref kept */
    INSERT INTO public.exos_checkin_client_refs (client_ref, ticket_id, event_id, org_id, scanned_by, result)
    VALUES (p_client_ref, p_ticket_id, v_event, v_org, v_uid, r)
    ON CONFLICT (client_ref) DO NOTHING;
  END IF;
', 1);

-- ---------------------------------------------------------------------------
-- 2. exos_door_checkin_by_name (8 args)
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* p1 door: fast clock */',
  '  v_scan_at  timestamptz := coalesce(p_scanned_at, clock_timestamp());
',
  '  -- A fast door phone: a replay stamped up to 10 minutes ahead is taken as now.
  v_at       timestamptz := CASE WHEN p_scanned_at > now() AND p_scanned_at <= now() + interval ''10 minutes''
                                 THEN now() ELSE p_scanned_at END; /* p1 door: fast clock */
  v_scan_at  timestamptz := coalesce(v_at, clock_timestamp());
', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* p1 door: scan time */',
  'IF NOT public._exos_scan_time_ok(t.event_id, p_scanned_at) THEN',
  'IF NOT public._exos_scan_time_ok(t.event_id, v_at) THEN /* p1 door: scan time */', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* p1 door: scan at */',
  'v_device, v_note, p_scanned_at, clock_timestamp(),',
  'v_device, v_note, v_at /* p1 door: scan at */, clock_timestamp(),', 2);
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* p1 door: too old */',
  'CASE WHEN p_scanned_at <= now() + interval ''2 minutes'' THEN ''too-old'' END',
  'CASE WHEN v_at <= now() + interval ''2 minutes'' THEN ''too-old'' END /* p1 door: too old */', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* p1 door: forced at */',
  '                        p_scanned_at, v_conflict, p_note);',
  '                        v_at /* p1 door: forced at */, v_conflict, p_note);', 1);
-- A parked ticket (pending claim to its buyer) inside the test window was
-- really checked in and its claim link cancelled: it is a test too.
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* p1 door: parked test */',
  '            OR (t.status = ''active'' AND t.pending_transfer_id IS NULL)) THEN',
  '            OR (t.status = ''active''
                AND (t.pending_transfer_id IS NULL /* p1 door: parked test */
                     OR public._exos_ticket_parked(t, (SELECT x FROM public.exos_transfers x
                                                        WHERE x.id = t.pending_transfer_id))))) THEN', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* p1 door: not-assigned */',
  '      INSERT INTO public.exos_scan_rejects
        (event_id, org_id, rejected_by, reason, source, ticket_id_attempted, reason_detail)
      VALUES (p_event_id, v_ev_org, v_uid, v_rr, ''manual'', p_ticket_id::text,
              left(''name-replay:'' || coalesce(r ->> ''reason'', ''unknown''), 200));
',
  '      INSERT INTO public.exos_scan_rejects
        (event_id, org_id, rejected_by, reason, source, ticket_id_attempted, reason_detail)
      SELECT p_event_id, v_ev_org, v_uid, v_rr, ''manual'', p_ticket_id::text,
             left(''name-replay:'' || coalesce(r ->> ''reason'', ''unknown''), 200)
       WHERE coalesce(r ->> ''reason'', '''') <> ''not-assigned''; /* p1 door: not-assigned */
', 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* p1 door: ref kept */',
  '    INSERT INTO public.exos_checkin_client_refs (client_ref, ticket_id, event_id, org_id, scanned_by, result)
    VALUES (p_client_ref, p_ticket_id, p_event_id, v_ev_org, v_uid, r)
    ON CONFLICT (client_ref) DO NOTHING;
',
  '    -- Refused for who uploaded it or when (nothing recorded): the ref stays free.
    IF coalesce(r ->> ''reason'', '''') NOT IN (''not-assigned'', ''bad-scan-time'') OR r ? ''forced'' THEN /* p1 door: ref kept */
      INSERT INTO public.exos_checkin_client_refs (client_ref, ticket_id, event_id, org_id, scanned_by, result)
      VALUES (p_client_ref, p_ticket_id, p_event_id, v_ev_org, v_uid, r)
      ON CONFLICT (client_ref) DO NOTHING;
    END IF;
', 1);

-- ---------------------------------------------------------------------------
-- 3. exos_guest_check_in: the offline replay's scan time
-- ---------------------------------------------------------------------------
-- An arrival recorded offline replays with when it happened: refused when out
-- of the replay window like a ticket scan (_exos_scan_time_ok, after the same
-- 10-minute fast-clock allowance), and kept on the arrival row.
ALTER TABLE public.exos_guest_list_checkins ADD COLUMN IF NOT EXISTS offline_scanned_at timestamptz;

DROP FUNCTION IF EXISTS public.exos_guest_check_in(uuid, integer, uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.exos_guest_check_in(
  p_entry_id uuid, p_count integer, p_event_id uuid, p_client_ref uuid DEFAULT NULL,
  p_source text DEFAULT 'online', p_scanned_at timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  en      public.exos_guest_list_entries%ROWTYPE;
  v_left  int;
  v_open  timestamptz;
  v_test  boolean;
  v_evst  text;
  v_else  jsonb;
  v_at    timestamptz := CASE WHEN p_scanned_at > now() AND p_scanned_at <= now() + interval '10 minutes'
                              THEN now() ELSE p_scanned_at END;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_guest_check_in: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(en.org_id, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_guest_check_in: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_event_id IS NULL OR en.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;
  -- door: voided on the platform that sold it (mig 20261013100000)
  IF en.voided_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'voided', 'source', en.source,
                              'void_reason', en.void_reason, 'arrived', en.arrived, 'party', en.plus_ones + 1);
  END IF;
  -- door: scanner event scope (exos_event_staff, mig 20260929041000)
  IF NOT public.exos_can_door_event(en.event_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-assigned');
  END IF;
  IF p_client_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_guest_list_checkins WHERE client_ref = p_client_ref) THEN
    RETURN jsonb_build_object('ok', true, 'reason', 'duplicate', 'arrived', en.arrived, 'party', en.plus_ones + 1);
  END IF;
  -- An offline arrival: the replay window of ticket scans (never in the future,
  -- 24 hours old or up to the event's end + 48 hours).
  IF NOT public._exos_scan_time_ok(en.event_id, v_at) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-scan-time');
  END IF;
  SELECT e.status, coalesce(e.doors_at, e.starts_at),
         (coalesce(e.checkin_test_mode, false) AND e.checkin_test_until IS NOT NULL AND now() < e.checkin_test_until)
    INTO v_evst, v_open, v_test
    FROM public.exos_events e WHERE e.id = en.event_id;
  IF v_evst = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'event-cancelled');
  END IF;
  IF v_open IS NOT NULL AND now() < v_open THEN
    IF v_test THEN
      RETURN jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true,
                                'arrived', en.arrived, 'party', en.plus_ones + 1);
    END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'doors-not-open', 'opens_at', v_open);
  END IF;
  -- door: a guest Eventbrite's own app checked in counts as one in
  -- (mig 20261014120000; read from Eventbrite, never written back).
  SELECT jsonb_build_object('where', 'Eventbrite', 'at', a.checked_in_at, 'method', a.checkin_method)
    INTO v_else
    FROM public.exos_eventbrite_attendees a
   WHERE a.entry_id = en.id AND a.checked_in;
  v_left := greatest(0, en.plus_ones + 1 - en.arrived - CASE WHEN v_else IS NULL THEN 0 ELSE 1 END);
  IF coalesce(p_count, 0) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-count');
  END IF;
  IF p_count > v_left THEN
    RETURN jsonb_build_object('ok', false,
                              'reason', CASE WHEN v_left = 0 AND v_else IS NOT NULL AND en.arrived = 0 THEN 'checked-in-elsewhere'
                                             WHEN v_left = 0 THEN 'used' ELSE 'over' END,
                              'remaining', v_left, 'arrived', en.arrived, 'party', en.plus_ones + 1,
                              'elsewhere', v_else);
  END IF;
  UPDATE public.exos_guest_list_entries
     SET arrived = arrived + p_count, arrived_at = coalesce(arrived_at, v_at, now())
   WHERE id = en.id;
  INSERT INTO public.exos_guest_list_checkins (entry_id, event_id, org_id, count, client_ref, source, scanned_by,
                                               offline_scanned_at)
  VALUES (en.id, en.event_id, en.org_id, p_count, p_client_ref,
          CASE WHEN p_source = 'offline-sync' THEN 'offline-sync' ELSE 'online' END, auth.uid(), v_at);
  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in',
                            'arrived', en.arrived + p_count, 'party', en.plus_ones + 1);
END $$;
REVOKE ALL ON FUNCTION public.exos_guest_check_in(uuid, integer, uuid, uuid, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_guest_check_in(uuid, integer, uuid, uuid, text, timestamptz) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. End-of-night summary: guest-list, imported and Eventbrite arrivals
-- ---------------------------------------------------------------------------
-- Heads like the door counts them (lib/guestLists headsIn): the Exos door's
-- arrivals plus one when Eventbrite's own app checked the guest in, never more
-- than the party. A voided guest who never came in isn't expected.
CREATE OR REPLACE FUNCTION public._exos_door_guest_summary(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH g AS (
    SELECT CASE WHEN a.entry_id IS NOT NULL THEN 'Eventbrite'
                WHEN nullif(btrim(en.source), '') IS NOT NULL THEN btrim(en.source)
                ELSE 'Guest list' END AS src,
           en.plus_ones + 1 AS party,
           least(en.plus_ones + 1, en.arrived + CASE WHEN coalesce(a.checked_in, false) THEN 1 ELSE 0 END) AS heads,
           en.voided_at IS NOT NULL AS voided,
           coalesce(a.checked_in, false) AND en.arrived = 0 AS app_only
      FROM public.exos_guest_list_entries en
      LEFT JOIN public.exos_eventbrite_attendees a ON a.entry_id = en.id
     WHERE en.event_id = p_event_id
  ),
  kept AS (SELECT * FROM g WHERE NOT voided OR heads > 0)
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM g) THEN NULL ELSE jsonb_build_object(
    'entries',  (SELECT count(*) FROM kept),
    'expected', (SELECT coalesce(sum(party), 0) FROM kept),
    'arrived',  (SELECT coalesce(sum(heads), 0) FROM kept),
    'eventbrite_app', (SELECT count(*) FROM kept WHERE app_only),
    'offline',  (SELECT coalesce(sum(c.count), 0) FROM public.exos_guest_list_checkins c
                  WHERE c.event_id = p_event_id AND c.source = 'offline-sync'),
    'by_source', coalesce((SELECT jsonb_agg(jsonb_build_object('source', src, 'expected', ex, 'arrived', ar)
                                            ORDER BY ar DESC, src)
                             FROM (SELECT src, sum(party) AS ex, sum(heads) AS ar FROM kept GROUP BY src) x),
                          '[]'::jsonb)) END;
$$;
REVOKE ALL ON FUNCTION public._exos_door_guest_summary(uuid) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch_n('public.exos_event_door_summary(uuid)', '/* p1 door: guests */',
  '    ''inside_now'', CASE WHEN',
  '    ''guests'', public._exos_door_guest_summary(p_event_id), /* p1 door: guests */
    ''inside_now'', CASE WHEN', 1);

-- ---------------------------------------------------------------------------
-- 5. Door roster, paged inside the function
-- ---------------------------------------------------------------------------
-- The body of exos_event_door_roster (mig 20261019100000 + 20261019120000)
-- with a keyset page: tickets after p_after (ticket id order), at most
-- p_limit (1..5000; NULL = all). The client reads pages until one comes back
-- empty (PostgREST's max_rows can cut a page short of p_limit).
CREATE OR REPLACE FUNCTION public.exos_event_door_roster_page(
  p_event_id uuid, p_since timestamptz DEFAULT NULL, p_after uuid DEFAULT NULL, p_limit int DEFAULT NULL)
RETURNS TABLE(ticket_id uuid, status text, owner_id uuid, owner_name text, tier_name text, door_keys jsonb,
              promoter_id text, pending_transfer_id uuid, parked boolean, claim_name text,
              claim_email_masked text, tier_id uuid, list_state jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_door_roster: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_since IS NOT NULL AND p_since < now() - interval '7 days' THEN
    RAISE EXCEPTION 'exos_event_door_roster: since must be within 7 days (do a full pull)' USING ERRCODE = '22023';
  END IF;
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_event_door_roster: event not found';
  END IF;
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_event_door_roster: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_event_door_roster: not assigned to this event' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    WITH pg AS (
      -- The page first; keys, names and list state only for its rows.
      SELECT t.id
        FROM public.exos_tickets t
       WHERE t.event_id = p_event_id
         AND (p_after IS NULL OR t.id > p_after)
         AND (p_since IS NULL
              OR t.updated_at >= p_since
              OR EXISTS (SELECT 1 FROM public.exos_transfers tr0
                          WHERE tr0.id = t.pending_transfer_id AND tr0.updated_at >= p_since)
              OR EXISTS (SELECT 1 FROM public.exos_profiles p0
                          WHERE p0.id = t.owner_id AND p0.updated_at >= p_since)
              OR EXISTS (SELECT 1 FROM public.exos_wallet_passes w
                          WHERE w.ticket_id = t.id AND w.updated_at >= p_since)
              OR t.id IN (SELECT ci.ticket_id FROM public.exos_event_checkins ci
                           WHERE ci.event_id = p_event_id AND ci.scanned_at >= p_since))
       ORDER BY t.id
       LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE greatest(1, least(p_limit, 5000)) END
    )
    SELECT t.id, t.status, t.owner_id,
           CASE WHEN pk.parked
                THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), ''),
                              public.exos_mask_email(lower(btrim(tr.receiver_email))), 'Unclaimed ticket')
                ELSE coalesce(nullif(t.attendee_name, ''), p.display_name) END,
           t.tier_name, public._exos_door_keys(t.id, t.owner_id, t.barcode_secret), t.promoter_id,
           t.pending_transfer_id, pk.parked,
           CASE WHEN pk.parked THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), '')) END,
           CASE WHEN pk.parked THEN public.exos_mask_email(lower(btrim(tr.receiver_email))) END,
           t.tier_id,
           (SELECT jsonb_object_agg(x.list_id, x.direction)
              FROM (SELECT DISTINCT ON (ci.list_id) ci.list_id, ci.direction
                      FROM public.exos_event_checkins ci
                      JOIN public.exos_checkin_lists l ON l.id = ci.list_id AND l.allow_reentry
                     WHERE ci.ticket_id = t.id
                     ORDER BY ci.list_id, coalesce(ci.offline_scanned_at, ci.scanned_at) DESC, ci.scanned_at DESC) x)
      FROM pg
      JOIN public.exos_tickets t ON t.id = pg.id
      LEFT JOIN public.exos_profiles p ON p.id = t.owner_id
      LEFT JOIN public.exos_transfers tr ON tr.id = t.pending_transfer_id
      CROSS JOIN LATERAL (SELECT (t.pending_transfer_id IS NOT NULL
                                  AND public._exos_ticket_parked(t, tr)) AS parked) pk
     ORDER BY t.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_door_roster_page(uuid, timestamptz, uuid, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_door_roster_page(uuid, timestamptz, uuid, int) TO authenticated;

-- The unpaged form (older clients page it from outside): the same rows.
CREATE OR REPLACE FUNCTION public.exos_event_door_roster(p_event_id uuid, p_since timestamptz DEFAULT NULL)
RETURNS TABLE(ticket_id uuid, status text, owner_id uuid, owner_name text, tier_name text, door_keys jsonb,
              promoter_id text, pending_transfer_id uuid, parked boolean, claim_name text,
              claim_email_masked text, tier_id uuid, list_state jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Body in exos_event_door_roster_page (mig 20261021090000; it carries the
  -- wallet delta of mig 20261019120000).
  RETURN QUERY SELECT * FROM public.exos_event_door_roster_page(p_event_id, p_since, NULL, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_door_roster(uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_door_roster(uuid, timestamptz) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Wallet push queue: Apple and Google apart
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_wallet_passes ADD COLUMN IF NOT EXISTS google_pushed_at timestamptz;

-- Two windows of p_limit each, oldest first: passes with Apple devices to
-- push, and passes whose Google object is behind (or with nothing to send,
-- which just get cleared). 'google' is true only when the Google object is due.
CREATE OR REPLACE FUNCTION public.exos_wallet_push_queue(p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH due AS (
    SELECT w.serial_number, w.pass_type_identifier, w.status, w.updated_at,
           (w.google_issued_at IS NOT NULL
             AND (w.google_pushed_at IS NULL OR w.google_pushed_at < w.updated_at)) AS google_due,
           EXISTS (SELECT 1 FROM public.exos_wallet_registrations r WHERE r.serial_number = w.serial_number) AS apple_due
      FROM public.exos_wallet_passes w
     WHERE w.push_pending
  ),
  pick AS (
    (SELECT serial_number FROM due WHERE apple_due
      ORDER BY updated_at LIMIT greatest(1, least(coalesce(p_limit, 100), 500)))
    UNION
    (SELECT serial_number FROM due WHERE google_due OR NOT apple_due
      ORDER BY updated_at LIMIT greatest(1, least(coalesce(p_limit, 100), 500)))
  )
  SELECT jsonb_build_object(
    'queued_at', clock_timestamp(),
    'passes', coalesce(jsonb_agg(q ORDER BY q.updated_at), '[]'::jsonb))
  FROM (
    SELECT d.serial_number AS serial, d.pass_type_identifier AS pass_type, d.status, d.updated_at,
           d.google_due AS google,
           coalesce((SELECT jsonb_agg(DISTINCT r.push_token) FROM public.exos_wallet_registrations r
                      WHERE r.serial_number = d.serial_number), '[]'::jsonb) AS push_tokens
      FROM due d JOIN pick USING (serial_number)) q;
$$;

-- Google objects updated for these passes (their Apple push may still wait).
CREATE OR REPLACE FUNCTION public.exos_wallet_google_done(p_serials text[], p_queued_at timestamptz)
RETURNS int LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE public.exos_wallet_passes
     SET google_pushed_at = p_queued_at
   WHERE serial_number = ANY (p_serials) AND google_issued_at IS NOT NULL AND updated_at <= p_queued_at;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.exos_wallet_google_done(text[], timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wallet_google_done(text[], timestamptz) TO service_role;

SELECT pg_temp.exos_patch_n('public.exos_wallet_push_done(text[], timestamp with time zone)', '/* p1 door: google */',
  '     SET push_pending = false, pushed_at = now()
',
  '     SET push_pending = false, pushed_at = now(),
         google_pushed_at = CASE WHEN google_issued_at IS NOT NULL THEN p_queued_at ELSE google_pushed_at END /* p1 door: google */
', 1);
