-- ============================================================================
-- Migration 20260929040000 — Exos (Bridge / D4): door hardening
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_event_checkins (+device, +override_reason,
--              +offline_scanned_at)
--           C: exos_checkin_client_refs, exos_checkin_undos,
--              exos_check_in_offline(...), exos_undo_check_in(uuid, uuid, text),
--              exos_server_time(), _exos_used_answer(uuid)
--           W: FUNCTION exos_check_in_ticket — the 5-argument version is
--              patched into an 8-argument one (+p_reason, +p_scanned_at,
--              +p_device, all defaulted) and the old overload dropped
-- Pre-reqs: 20260925021000 (check-in hardening), 20260929010000
--
-- From the 2026-09-28 door review:
--
-- 1. Offline replay skipped the barcode check. The scanner admitted from its
--    cached roster and later replayed the queue as manual check-ins, so a
--    ticket transferred after the roster sync (new owner, new secret) still
--    let the OLD holder in, and the server never noticed. The queue now keeps
--    the scanned code and the scan time, and exos_check_in_offline replays it:
--    the HMAC is checked against the ticket's CURRENT owner and secret for
--    the bucket of the original scan time (at most 24 hours old, never in the
--    future). A code signed before a transfer no longer matches, so the replay
--    is refused and logged as a conflict (exos_scan_rejects, reason_detail
--    offline-replay:...). Each queued scan carries a client_ref: a replay of
--    the same ref returns the first answer instead of counting twice.
-- 2. Typed override. A bare ticket id typed at the door admitted with no
--    signature, for any scanner. It now needs an owner or manager (scanners
--    get 'needs-manager') and a reason (at least 3 characters), which is
--    stored on the check-in row (override_reason).
-- 3. "Already used" now says when: the answer carries check_in_at, and the
--    device / source of the check-in that used it.
-- 4. Undo a check-in (pretix parity): owner / manager, with a reason. The
--    check-in row moves to exos_checkin_undos (so counts and analytics stay
--    right) and the ticket is active again.
-- 5. exos_server_time(): the database clock, so a phone with a wrong clock
--    can still show a code for the current 30-second window.
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE; each patch asserts one match
-- and is skipped once applied). D4 authors; applying to prod is operator-gated.
--
-- ⚠ DEPLOY ORDER. After this migration a bundle that types ticket ids without
-- a reason gets 'reason-required' / 'needs-manager', and the old offline queue
-- (plain ticket ids) replays as manual entries. Ship the matching bundle with
-- it (OrganizerCheckIn: reason prompt + exos_check_in_offline).
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_sig text, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected one match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ── Columns + tables ───────────────────────────────────────────────────────

ALTER TABLE public.exos_event_checkins
  ADD COLUMN IF NOT EXISTS device             text,
  ADD COLUMN IF NOT EXISTS override_reason    text,
  ADD COLUMN IF NOT EXISTS offline_scanned_at timestamptz;

-- One row per replayed offline scan: the answer it got the first time.
CREATE TABLE IF NOT EXISTS public.exos_checkin_client_refs (
  client_ref uuid        PRIMARY KEY,
  ticket_id  uuid        NOT NULL,
  event_id   uuid,
  org_id     uuid,
  scanned_by uuid,
  result     jsonb       NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_checkin_client_refs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_checkin_client_refs FROM PUBLIC, anon, authenticated;

-- Undone check-ins: the removed exos_event_checkins row(s) plus who and why.
CREATE TABLE IF NOT EXISTS public.exos_checkin_undos (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id   uuid        NOT NULL,
  ticket_id  uuid        NOT NULL,
  org_id     uuid        NOT NULL,
  checkins   jsonb       NOT NULL DEFAULT '[]'::jsonb,
  reason     text        NOT NULL,
  undone_by  uuid        NOT NULL,
  undone_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_checkin_undos_event_idx ON public.exos_checkin_undos (event_id);
ALTER TABLE public.exos_checkin_undos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_checkin_undos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_checkin_undos TO authenticated;
DROP POLICY IF EXISTS exos_checkin_undos_sel ON public.exos_checkin_undos;
CREATE POLICY exos_checkin_undos_sel ON public.exos_checkin_undos FOR SELECT TO authenticated
  USING (public.exos_is_admin()
         OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));

-- ── Server clock ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.exos_server_time()
RETURNS timestamptz LANGUAGE sql VOLATILE SET search_path = public, pg_temp AS $$
  SELECT clock_timestamp();
$$;
REVOKE ALL ON FUNCTION public.exos_server_time() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_server_time() TO anon, authenticated, service_role;

-- ── "Already used": when, and where ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._exos_used_answer(p_ticket_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('ok', false, 'reason', 'used')
         || jsonb_strip_nulls(jsonb_build_object(
              'check_in_at', coalesce(t.check_in_at, c.scanned_at),
              'device',      c.device,
              'source',      c.source))
    FROM public.exos_tickets t
    LEFT JOIN LATERAL (
      SELECT ci.scanned_at, ci.device, ci.source
        FROM public.exos_event_checkins ci
       WHERE ci.ticket_id = t.id
       ORDER BY ci.scanned_at DESC
       LIMIT 1) c ON true
   WHERE t.id = p_ticket_id;
$$;
REVOKE ALL ON FUNCTION public._exos_used_answer(uuid) FROM PUBLIC, anon, authenticated;

-- ── exos_check_in_ticket: 5 → 8 arguments ───────────────────────────────────
-- The header patch re-creates the function (body and every earlier patch
-- carried over) with three defaulted arguments; the 5-argument overload is
-- then dropped, so named calls from the current bundle still resolve.

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid)',
  'p_device text DEFAULT',
  'p_event_id uuid DEFAULT NULL::uuid)',
  'p_event_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_device text DEFAULT NULL::text)');
DROP FUNCTION IF EXISTS public.exos_check_in_ticket(uuid, text, text, text, uuid);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'v_scan_at   timestamptz',
  '  v_verified  boolean := false;',
  '  v_verified  boolean := false;
  v_scan_at   timestamptz := coalesce(p_scanned_at, now());
  v_manager   boolean := false;');

-- Offline replays: the scan time bounds the window, and it picks the bucket.
SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'door: offline scan window',
  $o$    RAISE EXCEPTION 'exos_check_in_ticket: not authorized' USING ERRCODE = '42501';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_check_in_ticket: not authorized' USING ERRCODE = '42501';
  END IF;
  v_manager := exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager']);

  -- door: offline scan window. A replayed scan is at most 24 hours old and
  -- never in the future (2 minutes of clock slack).
  IF p_scanned_at IS NOT NULL
     AND (p_scanned_at > now() + interval '2 minutes' OR p_scanned_at < now() - interval '24 hours') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-scan-time');
  END IF;$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'extract(epoch FROM v_scan_at)',
  'v_cur   bigint := floor(extract(epoch FROM now()) * 1000 / 30000);',
  'v_cur   bigint := floor(extract(epoch FROM v_scan_at) * 1000 / 30000);');

-- Typed override: owner / manager, with a reason.
SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'door: typed override',
  $o$    ELSIF p_source = 'camera' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    END IF;$o$,
  $n$    ELSIF p_source = 'camera' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    ELSE
      -- door: typed override (no signed code). Owner / manager only, with a
      -- reason that is kept on the check-in row.
      IF NOT v_manager THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'needs-manager');
      END IF;
      IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'reason-required');
      END IF;
    END IF;$n$);

-- "Already used" says when (both the early answer and the lost race).
SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  $m$IF v_prev = 'used' THEN
    RETURN public._exos_used_answer$m$,
  $o$  IF v_prev = 'used' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'used');
  END IF;$o$,
  $n$  IF v_prev = 'used' THEN
    RETURN public._exos_used_answer(p_ticket_id);
  END IF;$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'IF v_updated = 0 THEN
    RETURN public._exos_used_answer(p_ticket_id);',
  $o$  IF v_updated = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'used');$o$,
  $n$  IF v_updated = 0 THEN
    RETURN public._exos_used_answer(p_ticket_id);$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'check_in_at = v_scan_at',
  $o$     SET status = 'used', check_in_at = now()$o$,
  $n$     SET status = 'used', check_in_at = v_scan_at$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'override_reason, offline_scanned_at)',
  $o$    (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification)$o$,
  $n$    (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification,
     device, override_reason, offline_scanned_at)$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'nullif(left(btrim(coalesce(p_device',
  $o$    CASE WHEN v_verified THEN 'verified' ELSE 'manual' END
  );$o$,
  $n$    CASE WHEN v_verified THEN 'verified' ELSE 'manual' END,
    nullif(left(btrim(coalesce(p_device, '')), 60), ''),
    CASE WHEN v_verified THEN NULL ELSE left(btrim(p_reason), 300) END,
    p_scanned_at
  );$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  $m$'check_in_at', v_scan_at$m$,
  $o$  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in');$o$,
  $n$  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in', 'check_in_at', v_scan_at,
                            'verified', v_verified);$n$);

REVOKE ALL ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text) TO authenticated;

-- ── Offline replay ─────────────────────────────────────────────────────────
-- One queued scan. p_barcode_payload is the code the camera read (NULL for a
-- typed override, which then needs a manager and p_reason like any other).
-- p_scanned_at is when the door admitted it. A refusal is a conflict: someone
-- got in on a ticket the server doesn't accept, so it is logged to
-- exos_scan_rejects for the scan report.
CREATE OR REPLACE FUNCTION public.exos_check_in_offline(
  p_client_ref      uuid,
  p_ticket_id       uuid,
  p_event_id        uuid,
  p_scanned_at      timestamptz,
  p_barcode_payload text DEFAULT NULL,
  p_source          text DEFAULT 'camera',
  p_reason          text DEFAULT NULL,
  p_device          text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_prev  public.exos_checkin_client_refs%ROWTYPE;
  v_org   uuid;
  v_event uuid;
  r       jsonb;
  v_rr    text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_offline: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_client_ref IS NULL OR p_scanned_at IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_offline: client_ref and scanned_at are required' USING ERRCODE = '22023';
  END IF;

  -- Same ref twice (a retry after a lost response): the first answer stands.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_checkin_ref:' || p_client_ref::text, 0));
  SELECT * INTO v_prev FROM public.exos_checkin_client_refs WHERE client_ref = p_client_ref;
  IF FOUND THEN
    IF v_prev.ticket_id <> p_ticket_id THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'bad-client-ref');
    END IF;
    RETURN v_prev.result || jsonb_build_object('duplicate', true);
  END IF;

  r := public.exos_check_in_ticket(
         p_ticket_id,
         CASE WHEN p_source = 'camera' THEN 'camera' ELSE 'manual' END,
         'manual', p_barcode_payload, p_event_id, p_reason, p_scanned_at, p_device);

  SELECT org_id, event_id INTO v_org, v_event FROM public.exos_tickets WHERE id = p_ticket_id;

  IF NOT coalesce((r ->> 'ok')::boolean, false) THEN
    r := r || jsonb_build_object('conflict', true);
    v_rr := CASE r ->> 'reason'
              WHEN 'barcode-rejected' THEN 'invalid-barcode'
              WHEN 'barcode-expired'  THEN 'expired-code'
              WHEN 'used'             THEN 'used'
              WHEN 'voided'           THEN 'voided'
              WHEN 'in-transfer'      THEN 'in-transfer'
              WHEN 'wrong-event'      THEN 'wrong-event'
              ELSE 'not-found' END;
    IF v_org IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = v_org) THEN
      INSERT INTO public.exos_scan_rejects
        (event_id, org_id, rejected_by, reason, source, ticket_id_attempted, reason_detail)
      VALUES (p_event_id, v_org, v_uid, v_rr,
              CASE WHEN p_source = 'camera' THEN 'camera' ELSE 'manual' END,
              p_ticket_id::text, left('offline-replay:' || coalesce(r ->> 'reason', 'unknown'), 200));
    END IF;
  END IF;

  INSERT INTO public.exos_checkin_client_refs (client_ref, ticket_id, event_id, org_id, scanned_by, result)
  VALUES (p_client_ref, p_ticket_id, v_event, v_org, v_uid, r)
  ON CONFLICT (client_ref) DO NOTHING;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.exos_check_in_offline(uuid, uuid, uuid, timestamptz, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_check_in_offline(uuid, uuid, uuid, timestamptz, text, text, text, text) TO authenticated;

-- ── Undo a check-in ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.exos_undo_check_in(p_ticket_id uuid, p_event_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  t        public.exos_tickets%ROWTYPE;
  v_rows   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_undo_check_in: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(t.org_id, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_undo_check_in: not authorized' USING ERRCODE = '42501';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(t.org_id, ARRAY['owner','manager'])) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'needs-manager');
  END IF;
  IF p_event_id IS NULL OR t.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason-required');
  END IF;
  IF t.status <> 'used' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-checked-in');
  END IF;

  WITH gone AS (
    DELETE FROM public.exos_event_checkins WHERE ticket_id = p_ticket_id RETURNING *
  )
  SELECT coalesce(jsonb_agg(to_jsonb(gone) ORDER BY gone.scanned_at), '[]'::jsonb) INTO v_rows FROM gone;

  INSERT INTO public.exos_checkin_undos (event_id, ticket_id, org_id, checkins, reason, undone_by)
  VALUES (t.event_id, t.id, t.org_id, v_rows, left(btrim(p_reason), 300), v_uid);

  UPDATE public.exos_tickets SET status = 'active', check_in_at = NULL
   WHERE id = p_ticket_id AND status = 'used';

  RETURN jsonb_build_object('ok', true, 'reason', 'undone');
END $$;
REVOKE ALL ON FUNCTION public.exos_undo_check_in(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_undo_check_in(uuid, uuid, text) TO authenticated;

-- ROLLBACK: recreate exos_check_in_ticket(uuid, text, text, text, uuid) from
-- the pre-migration definition (20260925021000 applied on 20260702144537),
-- drop the 8-argument one, exos_check_in_offline, exos_undo_check_in,
-- exos_server_time, _exos_used_answer and the two new tables; the new
-- exos_event_checkins columns can stay.
