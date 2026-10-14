-- ============================================================================
-- Eventbrite check-ins at the Exos door (read only), and one status vocabulary
-- ============================================================================
-- Touches:  C: TABLE exos_eventbrite_attendees, exos_eventbrite_barcodes
--              (service role only)
--           C: FUNCTION _exos_eb_ts, _exos_eb_attendee_upsert (service role),
--              exos_eb_status_word (everyone: pure), exos_attendee_lookup
--              (authenticated, owner / manager)
--           W: FUNCTION exos_eventbrite_apply (patched in place: stores
--              Eventbrite's check-in state and barcodes per attendee),
--              exos_guest_check_in (patched: a guest Eventbrite already checked
--              in is refused as 'checked-in-elsewhere'),
--              exos_event_door_extras (patched: + elsewhere, eb_status),
--              exos_eventbrite_status (patched: + checked_in_on_eventbrite)
-- Pre-reqs: 20261013100000 (attendee sync), 20261013090000 (imported codes)
--
-- A venue that scans with Eventbrite's Organizer app AND the Exos door at the
-- same event could let one ticket in twice, once on each. The sync now reads
-- what Eventbrite says about each attendee: checked_in, refunded, cancelled,
-- its status word, and every barcode with Eventbrite's own status (unused /
-- used / refunded) and how it was validated (scan / name). The Exos door then
-- counts a guest Eventbrite checked in as already in.
--
-- Two barcode stores, never merged:
--   * Exos tickets keep their rotating HMAC codes (exos_tickets.barcode_secret).
--   * Eventbrite's codes live in exos_eventbrite_barcodes, keyed by event and
--     code, with Eventbrite's status. The guest entry keeps one of them as its
--     door code (external_code, as before) so a scan finds the guest offline.
--   Eventbrite's check-in state is kept apart from the Exos door's: the
--   guest's `arrived` counts Exos scans only; exos_eventbrite_attendees says
--   what Eventbrite saw. The door adds the two. Nothing is written back to
--   Eventbrite (checked_in is read only there, and upstream APIs stay read
--   only: CLAUDE.md).
--
-- One status vocabulary for the organizer: exos_eb_status_word maps an Exos
-- ticket or guest to Eventbrite's words (Attending / Checked In / Not
-- Attending / Transferred), and exos_attendee_lookup searches Exos tickets
-- and every guest (Eventbrite, CSV imports, guest lists) in those words, so a
-- lookup reads the same whichever platform sold the ticket.
--
-- A check-out on Eventbrite (the barcode back to unused) lets the guest in at
-- the Exos door again on the next sync. The sync is every 2 minutes near the
-- event, so a ticket scanned on both apps inside that window can still get in
-- twice: one scanning app per event is still the advice.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := pg_get_functiondef(p_fn);
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
-- 1. What Eventbrite says, per attendee and per barcode.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_eventbrite_attendees (
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  eb_attendee_id  text NOT NULL CHECK (eb_attendee_id ~ '^[0-9]{1,24}$'),
  entry_id        uuid NOT NULL REFERENCES public.exos_guest_list_entries (id) ON DELETE CASCADE,
  -- Eventbrite's own word, as sent ("Attending", "Checked In", ...).
  eb_status       text CHECK (eb_status IS NULL OR length(eb_status) <= 40),
  checked_in      boolean NOT NULL DEFAULT false,
  -- When a used barcode last changed on Eventbrite (their check-in time, as
  -- near as the API gives it), and how it was validated.
  checked_in_at   timestamptz,
  checkin_method  text CHECK (checkin_method IS NULL OR checkin_method IN ('scan', 'name')),
  refunded        boolean NOT NULL DEFAULT false,
  cancelled       boolean NOT NULL DEFAULT false,
  eb_changed_at   timestamptz,
  synced_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, eb_attendee_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_eventbrite_attendees_entry_uq ON public.exos_eventbrite_attendees (entry_id);
ALTER TABLE public.exos_eventbrite_attendees ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_eventbrite_attendees FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_eventbrite_attendees TO service_role;
COMMENT ON TABLE public.exos_eventbrite_attendees IS
  'Eventbrite''s view of each synced attendee (check-in, refund, status word), apart from the Exos door''s own arrivals. Read from Eventbrite only. Service role only. mig 20261014120000.';

CREATE TABLE IF NOT EXISTS public.exos_eventbrite_barcodes (
  event_id        uuid NOT NULL,
  barcode         text NOT NULL CHECK (length(barcode) BETWEEN 1 AND 128),
  eb_attendee_id  text NOT NULL,
  status          text NOT NULL CHECK (status IN ('unused', 'used', 'refunded')),
  checkin_type    smallint CHECK (checkin_type IS NULL OR checkin_type IN (0, 1, 2)),
  eb_changed_at   timestamptz,
  synced_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, barcode),
  FOREIGN KEY (event_id, eb_attendee_id)
    REFERENCES public.exos_eventbrite_attendees (event_id, eb_attendee_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS exos_eventbrite_barcodes_attendee_idx
  ON public.exos_eventbrite_barcodes (event_id, eb_attendee_id);
ALTER TABLE public.exos_eventbrite_barcodes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_eventbrite_barcodes FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_eventbrite_barcodes TO service_role;
COMMENT ON TABLE public.exos_eventbrite_barcodes IS
  'Eventbrite''s barcodes with Eventbrite''s status. Kept apart from Exos ticket codes (exos_tickets). Service role only. mig 20261014120000.';

-- An ISO time from Eventbrite, or NULL (never an error mid-sync).
-- The regex keeps the format; the cast can still refuse an impossible date
-- (2026-02-30), which is caught too.
CREATE OR REPLACE FUNCTION public._exos_eb_ts(p text)
RETURNS timestamptz LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
BEGIN
  IF p IS NULL OR p !~ '^[0-9]{4}-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-][0-9]{2}:?[0-9]{2})$' THEN
    RETURN NULL;
  END IF;
  RETURN p::timestamptz;
EXCEPTION WHEN data_exception THEN
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_eb_ts(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_eb_ts(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Store one attendee's state. r is the apply row:
--      {ref, checked_in?, status?, refunded?, cancelled?, changed?,
--       barcodes?: [{code, status, checkin_type?, changed?}]}
--    Checked in = Eventbrite says checked_in, or one of the attendee's
--    barcodes is used. Returns true when the checked-in state changed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_eb_attendee_upsert(p_event_id uuid, p_entry_id uuid, r jsonb)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ref    text := r->>'ref';
  v_prev   boolean;
  v_in     boolean;
  v_at     timestamptz;
  v_type   smallint;
  b        jsonb;
  v_code   text;
BEGIN
  SELECT checked_in INTO v_prev FROM public.exos_eventbrite_attendees
   WHERE event_id = p_event_id AND eb_attendee_id = v_ref FOR UPDATE;

  INSERT INTO public.exos_eventbrite_attendees AS a (event_id, eb_attendee_id, entry_id, eb_status, refunded, cancelled, eb_changed_at)
  VALUES (p_event_id, v_ref, p_entry_id, left(nullif(btrim(coalesce(r->>'status', '')), ''), 40),
          coalesce((r->'refunded') = 'true'::jsonb, false), coalesce((r->'cancelled') = 'true'::jsonb, false), public._exos_eb_ts(r->>'changed'))
  ON CONFLICT (event_id, eb_attendee_id) DO UPDATE
     SET entry_id = EXCLUDED.entry_id, eb_status = coalesce(EXCLUDED.eb_status, a.eb_status),
         refunded = EXCLUDED.refunded, cancelled = EXCLUDED.cancelled,
         eb_changed_at = coalesce(EXCLUDED.eb_changed_at, a.eb_changed_at), synced_at = now();

  IF jsonb_typeof(r->'barcodes') = 'array' THEN
    FOR b IN SELECT value FROM jsonb_array_elements(r->'barcodes') LIMIT 20 LOOP
      CONTINUE WHEN jsonb_typeof(b) <> 'object' OR coalesce(b->>'status', '') NOT IN ('unused', 'used', 'refunded');
      v_code := public._exos_door_code(b->>'code');
      CONTINUE WHEN v_code IS NULL;
      INSERT INTO public.exos_eventbrite_barcodes AS x (event_id, barcode, eb_attendee_id, status, checkin_type, eb_changed_at)
      VALUES (p_event_id, v_code, v_ref, b->>'status',
              CASE WHEN b->>'checkin_type' IN ('0', '1', '2') THEN (b->>'checkin_type')::smallint END,
              public._exos_eb_ts(b->>'changed'))
      ON CONFLICT (event_id, barcode) DO UPDATE
         SET eb_attendee_id = EXCLUDED.eb_attendee_id, status = EXCLUDED.status,
             checkin_type = EXCLUDED.checkin_type,
             eb_changed_at = coalesce(EXCLUDED.eb_changed_at, x.eb_changed_at), synced_at = now();
    END LOOP;
  END IF;

  SELECT max(x.eb_changed_at), (array_agg(x.checkin_type ORDER BY x.eb_changed_at DESC NULLS LAST))[1]
    INTO v_at, v_type
    FROM public.exos_eventbrite_barcodes x
   WHERE x.event_id = p_event_id AND x.eb_attendee_id = v_ref AND x.status = 'used';
  v_in := coalesce((r->'checked_in') = 'true'::jsonb, false)
          OR EXISTS (SELECT 1 FROM public.exos_eventbrite_barcodes x
                      WHERE x.event_id = p_event_id AND x.eb_attendee_id = v_ref AND x.status = 'used');

  UPDATE public.exos_eventbrite_attendees
     SET checked_in     = v_in,
         checked_in_at  = CASE WHEN v_in THEN coalesce(v_at, checked_in_at, now()) END,
         checkin_method = CASE WHEN NOT v_in THEN NULL
                               WHEN v_type = 1 THEN 'scan' WHEN v_type = 2 THEN 'name' ELSE checkin_method END
   WHERE event_id = p_event_id AND eb_attendee_id = v_ref;
  RETURN v_in IS DISTINCT FROM coalesce(v_prev, false);
END $$;
REVOKE ALL ON FUNCTION public._exos_eb_attendee_upsert(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_eb_attendee_upsert(uuid, uuid, jsonb) TO service_role;

-- The sync stores it after each attendee row (same pass, same lease).
SELECT pg_temp.exos_patch_n('public.exos_eventbrite_apply(uuid, uuid, jsonb, text, text, text)',
  '_exos_eb_attendee_upsert',
  $o$    END;
    g := NULL;
  END LOOP;$o$,
  $n$    END;
    -- Eventbrite's own check-in state and barcodes (mig 20261014120000).
    BEGIN
      PERFORM public._exos_eb_attendee_upsert(p_event_id, x.id, r)
         FROM public.exos_guest_list_entries x
        WHERE x.event_id = p_event_id AND x.external_ref = v_ref;
    EXCEPTION
      WHEN unique_violation OR check_violation OR foreign_key_violation OR not_null_violation OR data_exception THEN
        v_errors := v_errors + 1;
    END;
    g := NULL;
  END LOOP;$n$, 1);

-- ---------------------------------------------------------------------------
-- 3. The door: Eventbrite's check-in counts as in.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_guest_check_in(uuid, integer, uuid, uuid, text)',
  'v_else  jsonb;',
  $o$  v_evst  text;$o$,
  $n$  v_evst  text;
  v_else  jsonb;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_guest_check_in(uuid, integer, uuid, uuid, text)',
  'checked-in-elsewhere',
  $o$  v_left := en.plus_ones + 1 - en.arrived;
  IF coalesce(p_count, 0) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-count');
  END IF;
  IF p_count > v_left THEN
    RETURN jsonb_build_object('ok', false, 'reason', CASE WHEN v_left = 0 THEN 'used' ELSE 'over' END,
                              'remaining', v_left, 'arrived', en.arrived, 'party', en.plus_ones + 1);
  END IF;$o$,
  $n$  -- door: a guest Eventbrite's own app checked in counts as one in
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
  END IF;$n$, 1);

-- The door download says who Eventbrite checked in, so the offline door
-- refuses them too.
SELECT pg_temp.exos_patch_n('public.exos_event_door_extras(uuid)',
  $m$'elsewhere', (SELECT$m$,
  $o$'voided', g.voided_at IS NOT NULL, 'void_reason', g.void_reason)$o$,
  $n$'voided', g.voided_at IS NOT NULL, 'void_reason', g.void_reason,
               'elsewhere', (SELECT jsonb_build_object('where', 'Eventbrite', 'at', a.checked_in_at, 'method', a.checkin_method)
                               FROM public.exos_eventbrite_attendees a WHERE a.entry_id = g.id AND a.checked_in),
               'eb_status', (SELECT a.eb_status FROM public.exos_eventbrite_attendees a WHERE a.entry_id = g.id))$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_status(uuid)',
  'checked_in_on_eventbrite',
  $o$      'voided', (SELECT count(*) FROM public.exos_guest_list_entries g
                  WHERE g.event_id = p_event_id AND g.external_ref LIKE 'eb:%' AND g.voided_at IS NOT NULL)) END);$o$,
  $n$      'voided', (SELECT count(*) FROM public.exos_guest_list_entries g
                  WHERE g.event_id = p_event_id AND g.external_ref LIKE 'eb:%' AND g.voided_at IS NOT NULL),
      'checked_in_on_eventbrite', (SELECT count(*) FROM public.exos_eventbrite_attendees ea
                                    WHERE ea.event_id = p_event_id AND ea.checked_in)) END);$n$, 1);

-- ---------------------------------------------------------------------------
-- 4. One vocabulary: Exos states in Eventbrite's words.
--    kind 'ticket': status active / used / transferred / voided.
--    kind 'guest':  status voided / in / expected.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_eb_status_word(p_kind text, p_status text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN p_kind = 'ticket' THEN CASE p_status
      WHEN 'active' THEN 'Attending'
      WHEN 'used' THEN 'Checked In'
      WHEN 'transferred' THEN 'Transferred'
      WHEN 'voided' THEN 'Not Attending'
    END
    WHEN p_kind = 'guest' THEN CASE p_status
      WHEN 'expected' THEN 'Attending'
      WHEN 'in' THEN 'Checked In'
      WHEN 'voided' THEN 'Not Attending'
    END
  END
$$;
REVOKE ALL ON FUNCTION public.exos_eb_status_word(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_eb_status_word(text, text) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Organizer lookup across Exos tickets and every guest, in those words.
--    p_query: name, email or code (contains, case-insensitive).
--    p_status: one of the words, or NULL for all.
--    Each row: source, name, email, ticket, status (the word), detail (Exos's
--    own state or Eventbrite's), refunded, checked_in_at, checked_in_on
--    (exos / eventbrite / both), code_status (unused / used / refunded), ref.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_attendee_lookup(
  p_event_id uuid, p_query text DEFAULT NULL, p_status text DEFAULT NULL, p_limit int DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid;
  v_q    text := nullif(lower(btrim(coalesce(p_query, ''))), '');
  v_lim  int := least(greatest(coalesce(p_limit, 100), 1), 500);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_attendee_lookup: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_attendee_lookup: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('Attending', 'Checked In', 'Not Attending', 'Transferred') THEN
    RAISE EXCEPTION 'exos_attendee_lookup: unknown status %', p_status USING ERRCODE = '22023';
  END IF;
  IF v_q IS NOT NULL AND length(v_q) > 100 THEN
    v_q := left(v_q, 100);
  END IF;

  RETURN (
    WITH r0 AS (
      SELECT 'Exos'::text AS source,
             coalesce(t.attendee_name, t.buyer_email) AS name, t.buyer_email AS email, t.tier_name AS ticket,
             public.exos_eb_status_word('ticket', t.status) AS status,
             CASE WHEN t.status = 'active' AND t.pending_transfer_id IS NOT NULL THEN 'in transfer'
                  WHEN t.status = 'voided' THEN coalesce('voided: ' || t.voided_reason, 'voided')
                  ELSE t.status END AS detail,
             (t.status = 'voided' AND coalesce(t.voided_reason, '') ILIKE '%refund%') AS refunded,
             t.check_in_at AS checked_in_at,
             CASE WHEN t.status = 'used' THEN 'exos' END AS checked_in_on,
             CASE t.status WHEN 'used' THEN 'used' WHEN 'voided' THEN 'refunded' ELSE 'unused' END AS code_status,
             coalesce(t.order_ref, t.id::text) AS ref,
             coalesce(t.channel_source, 'exos') AS channel,
             lower(coalesce(t.attendee_name, '') || ' ' || coalesce(t.buyer_email, '') || ' ' || coalesce(t.order_ref, '')) AS hay,
             t.created_at
        FROM public.exos_tickets t
       WHERE t.event_id = p_event_id
      UNION ALL
      SELECT coalesce(g.source, 'Guest list'),
             g.guest_name, g.email, coalesce(g.ticket_label, l.name),
             CASE WHEN g.voided_at IS NOT NULL THEN 'Not Attending'
                  WHEN g.arrived > 0 OR a.checked_in THEN 'Checked In'
                  ELSE 'Attending' END,
             coalesce(a.eb_status,
                      CASE WHEN g.voided_at IS NOT NULL THEN coalesce('voided: ' || g.void_reason, 'voided')
                           WHEN g.arrived > 0 THEN g.arrived || '/' || (g.plus_ones + 1) || ' in'
                           ELSE 'expected' END),
             coalesce(a.refunded, false) OR coalesce(g.void_reason, '') ILIKE '%refund%',
             CASE WHEN g.arrived > 0 AND a.checked_in THEN least(g.arrived_at, a.checked_in_at)
                  WHEN g.arrived > 0 THEN g.arrived_at ELSE a.checked_in_at END,
             CASE WHEN g.arrived > 0 AND a.checked_in THEN 'both' WHEN g.arrived > 0 THEN 'exos'
                  WHEN a.checked_in THEN 'eventbrite' END,
             coalesce((SELECT CASE WHEN bool_or(x.status = 'used') THEN 'used'
                                   WHEN bool_and(x.status = 'refunded') THEN 'refunded' ELSE 'unused' END
                         FROM public.exos_eventbrite_barcodes x
                        WHERE x.event_id = g.event_id AND x.eb_attendee_id = a.eb_attendee_id),
                      CASE WHEN g.voided_at IS NOT NULL THEN 'refunded' WHEN g.arrived > 0 THEN 'used' ELSE 'unused' END),
             coalesce(g.external_ref, g.external_code, g.id::text),
             CASE WHEN g.external_ref LIKE 'eb:%' THEN 'eventbrite' ELSE 'guest' END,
             lower(g.guest_name || ' ' || coalesce(g.email, '') || ' ' || coalesce(g.external_code, '') || ' ' ||
                   coalesce(g.external_ref, '')),
             g.created_at
        FROM public.exos_guest_list_entries g
        JOIN public.exos_guest_lists l ON l.id = g.list_id
        LEFT JOIN public.exos_eventbrite_attendees a ON a.entry_id = g.id
       WHERE g.event_id = p_event_id
    ), hit AS (
      SELECT * FROM r0
       WHERE (v_q IS NULL OR position(v_q in hay) > 0 OR position(replace(upper(v_q), ' ', '') in upper(hay)) > 0)
    )
    SELECT jsonb_build_object(
      'counts', (SELECT coalesce(jsonb_object_agg(s.status, s.n), '{}'::jsonb)
                   FROM (SELECT status, count(*) AS n FROM hit WHERE status IS NOT NULL GROUP BY status) s),
      'rows', coalesce((SELECT jsonb_agg(to_jsonb(z) - 'hay' - 'created_at' ORDER BY z.name, z.created_at)
                          FROM (SELECT * FROM hit WHERE p_status IS NULL OR status = p_status
                                 ORDER BY name, created_at LIMIT v_lim) z), '[]'::jsonb))
  );
END $$;
REVOKE ALL ON FUNCTION public.exos_attendee_lookup(uuid, text, text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_attendee_lookup(uuid, text, text, int) TO authenticated, service_role;

-- ROLLBACK (manual): re-create exos_eventbrite_apply, exos_guest_check_in,
-- exos_event_door_extras and exos_eventbrite_status from their sources
-- (20261013100000 and earlier); drop exos_attendee_lookup,
-- exos_eb_status_word, _exos_eb_attendee_upsert, _exos_eb_ts and the two tables.
