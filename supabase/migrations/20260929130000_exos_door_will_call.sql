-- ============================================================================
-- Migration 20260929130000 — Exos (Bridge / D4): will-call for parked tickets
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: FUNCTION _exos_ticket_parked(exos_tickets, exos_transfers)
--              (internal, no client grant),
--              exos_door_admit_parked(uuid, uuid, text, text, timestamptz, uuid)
--           W: FUNCTION exos_event_checkin_roster(uuid) (DROPPED + re-created:
--              three columns appended; the 20260929041000 scanner-scope gate
--              is part of the new body),
--              exos_event_checkins verification CHECK (+ 'will-call'),
--              exos_tickets (status, check_in_at, pending_transfer_id),
--              exos_transfers (status -> 'cancelled'),
--              exos_event_checkins, exos_checkin_client_refs, exos_scan_rejects
--           R: exos_orgs.owner_uid, exos_org_memberships, exos_events,
--              exos_event_staff (via exos_can_door_event)
-- Pre-reqs: 20260929040000 (exos_checkin_client_refs, _exos_used_answer,
--           device / override_reason / offline_scanned_at on check-ins),
--           20260929041000 (exos_can_door_event), 20260927010000
--           (exos_transfers.receiver_name), 20260702240000 + 20260911134000
--           (the roster this replaces)
--
-- From the 2026-09-29 door audit (#30). Tickets nobody has claimed yet are
-- "parked": the platform minted them for an email address with no account
-- and holds them on the org (the org owner for marketplace sales and guest
-- checkout, the issuing owner / manager for comps and box-office issues)
-- with a pending claim-by-email transfer. Until the buyer claims the link,
-- the door refused them as "in transfer", even with a manager override, and
-- the roster showed the org owner's name, so the buyer couldn't be found.
--
-- A ticket is parked when its pending transfer was created by the mint:
--   transfer pending, sender = ticket owner = ticket buyer,
--   ticket.buyer_email = transfer.receiver_email (the mint writes the
--   recipient's email on the ticket; a holder forwarding their own ticket has
--   their own email there), and the sender is the org owner or an org owner /
--   manager (who issue comps).
--
-- 1. The roster adds parked, claim_name (attendee name, else the name the
--    transfer was addressed to) and claim_email_masked (j***@gmail.com). For a
--    parked ticket owner_name is that claim name / masked email instead of the
--    org owner. The full email and the claim key never leave the server.
-- 2. exos_door_admit_parked: will-call. An owner / manager (or platform admin)
--    who checked the buyer's ID admits a parked ticket with a reason. Scanners
--    get 'needs-manager', exactly like a typed override (which is also owner /
--    manager only). The pending transfer is cancelled (so nobody can claim the
--    link after the buyer is inside), the ticket stays on the org and is used,
--    and the check-in is logged with verification 'will-call' and the reason.
--    Idempotent on p_client_ref (shared with exos_check_in_offline), so the
--    offline queue replays it with the same semantics; a second admit of the
--    same ticket answers 'used'.
--
-- Re-run safe (DROP + CREATE of the roster, CREATE OR REPLACE, constraint
-- rebuilt only when it lacks 'will-call'). D4 authors; applying to prod is
-- operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Check-ins may be verified 'will-call' (the phase-2 CHECK allowed only
--    verified / legacy / manual).
-- ---------------------------------------------------------------------------
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname, pg_get_constraintdef(oid) AS def
      FROM pg_constraint
     WHERE conrelid = 'public.exos_event_checkins'::regclass AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%verification%'
  LOOP
    IF position('will-call' in c.def) = 0 THEN
      EXECUTE format('ALTER TABLE public.exos_event_checkins DROP CONSTRAINT %I', c.conname);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.exos_event_checkins'::regclass
                    AND conname = 'exos_event_checkins_verification_check') THEN
    ALTER TABLE public.exos_event_checkins
      ADD CONSTRAINT exos_event_checkins_verification_check
      CHECK (verification IS NULL OR verification IN ('verified', 'legacy', 'manual', 'will-call'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. Is this pending transfer a platform parking (see the header)?
--    Internal: called from definer functions only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_ticket_parked(t public.exos_tickets, tr public.exos_transfers)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
       tr.id IS NOT NULL
   AND tr.id = t.pending_transfer_id
   AND tr.ticket_id = t.id
   AND tr.status = 'pending'
   AND tr.sender_id = t.owner_id
   AND t.buyer_id = t.owner_id
   AND nullif(btrim(tr.receiver_email), '') IS NOT NULL
   AND lower(btrim(tr.receiver_email)) = lower(btrim(coalesce(t.buyer_email, '')))
   AND (EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = t.org_id AND o.owner_uid = tr.sender_id)
        OR EXISTS (SELECT 1 FROM public.exos_org_memberships m
                    WHERE m.org_id = t.org_id AND m.user_id = tr.sender_id
                      AND m.role IN ('owner', 'manager'))),
   false);
$$;
REVOKE ALL ON FUNCTION public._exos_ticket_parked(public.exos_tickets, public.exos_transfers) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Roster: + parked, claim_name, claim_email_masked. Return type changes,
--    so DROP + CREATE (grants re-applied below).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.exos_event_checkin_roster(uuid);
CREATE FUNCTION public.exos_event_checkin_roster(p_event_id uuid)
RETURNS TABLE (
  ticket_id           uuid,
  status              text,
  owner_id            uuid,
  owner_name          text,
  tier_name           text,
  barcode_secret      text,
  promoter_id         text,
  pending_transfer_id uuid,
  parked              boolean,
  claim_name          text,
  claim_email_masked  text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: event not found';
  END IF;

  -- ONE authorization check for the entire roster. Door roles only
  -- (owner/manager/scanner or platform admin); finance/content never read
  -- barcode_secret in bulk.
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: not authorized for this event'
      USING ERRCODE = '42501';
  END IF;

  -- door: scanner event scope (exos_event_staff, mig 20260929041000)
  IF NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: not assigned to this event' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT t.id, t.status, t.owner_id,
           -- The person the ticket is FOR beats the account that holds it; a
           -- parked ticket is for the buyer, not the org owner holding it.
           CASE WHEN pk.parked
                THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), ''),
                              public.exos_mask_email(lower(btrim(tr.receiver_email))), 'Unclaimed ticket')
                ELSE coalesce(nullif(t.attendee_name, ''), p.display_name) END,
           t.tier_name, t.barcode_secret, t.promoter_id, t.pending_transfer_id,
           pk.parked,
           CASE WHEN pk.parked THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), '')) END,
           CASE WHEN pk.parked THEN public.exos_mask_email(lower(btrim(tr.receiver_email))) END
    FROM public.exos_tickets t
    LEFT JOIN public.exos_profiles p ON p.id = t.owner_id
    LEFT JOIN public.exos_transfers tr ON tr.id = t.pending_transfer_id
    CROSS JOIN LATERAL (SELECT (t.pending_transfer_id IS NOT NULL AND public._exos_ticket_parked(t, tr)) AS parked) pk
    WHERE t.event_id = p_event_id;
END $$;

REVOKE ALL ON FUNCTION public.exos_event_checkin_roster(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_event_checkin_roster(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Will-call admit.
--    Answers {ok, reason}: 'checked-in' (ok) | 'test-scan' (ok, pre-doors
--    test window, nothing changes) | 'needs-manager' | 'reason-required' |
--    'not-found' | 'wrong-event' | 'not-assigned' | 'event-cancelled' |
--    'doors-not-open' | 'bad-scan-time' | 'voided' | 'used' (with when /
--    device) | 'not-parked' (no pending transfer: scan or override normally) |
--    'in-transfer' (a holder's own transfer, not a parking) |
--    'bad-client-ref'. A replayed ref returns its first answer + duplicate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_door_admit_parked(
  p_ticket_id  uuid,
  p_event_id   uuid,
  p_reason     text,
  p_device     text DEFAULT NULL,
  p_scanned_at timestamptz DEFAULT NULL,
  p_client_ref uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_ev_org  uuid;
  v_prev    public.exos_checkin_client_refs%ROWTYPE;
  t         public.exos_tickets%ROWTYPE;
  tr        public.exos_transfers%ROWTYPE;
  v_scan_at timestamptz := coalesce(p_scanned_at, now());
  v_open_at timestamptz;
  v_test    boolean := false;
  v_name    text;
  r         jsonb;
  v_rr      text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_door_admit_parked: not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Door staff of the event's org only (the row's org, not a caller-given id).
  SELECT e.org_id INTO v_ev_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_ev_org IS NULL OR NOT (public.exos_is_admin()
       OR public.exos_has_org_role(v_ev_org, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_door_admit_parked: not authorized' USING ERRCODE = '42501';
  END IF;

  -- Same ref twice (a retry after a lost response): the first answer stands.
  IF p_client_ref IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_checkin_ref:' || p_client_ref::text, 0));
    SELECT * INTO v_prev FROM public.exos_checkin_client_refs WHERE client_ref = p_client_ref;
    IF FOUND THEN
      IF v_prev.ticket_id <> p_ticket_id THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'bad-client-ref');
      END IF;
      RETURN v_prev.result || jsonb_build_object('duplicate', true);
    END IF;
  END IF;

  -- The decision, in a block so every answer is recorded against the ref.
  <<decide>>
  BEGIN
    SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
    IF NOT FOUND THEN
      r := jsonb_build_object('ok', false, 'reason', 'not-found'); EXIT decide;
    END IF;
    IF t.event_id <> p_event_id OR t.org_id <> v_ev_org THEN
      r := jsonb_build_object('ok', false, 'reason', 'wrong-event'); EXIT decide;
    END IF;
    -- Will-call is an override: owner / manager (or admin), like a typed id.
    IF NOT (public.exos_is_admin() OR public.exos_has_org_role(t.org_id, ARRAY['owner', 'manager'])) THEN
      r := jsonb_build_object('ok', false, 'reason', 'needs-manager'); EXIT decide;
    END IF;
    IF NOT public.exos_can_door_event(t.event_id) THEN
      r := jsonb_build_object('ok', false, 'reason', 'not-assigned'); EXIT decide;
    END IF;
    IF p_scanned_at IS NOT NULL
       AND (p_scanned_at > now() + interval '2 minutes' OR p_scanned_at < now() - interval '24 hours') THEN
      r := jsonb_build_object('ok', false, 'reason', 'bad-scan-time'); EXIT decide;
    END IF;
    IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
      r := jsonb_build_object('ok', false, 'reason', 'reason-required'); EXIT decide;
    END IF;
    IF EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = t.event_id AND e.status = 'cancelled') THEN
      r := jsonb_build_object('ok', false, 'reason', 'event-cancelled'); EXIT decide;
    END IF;

    SELECT coalesce(e.doors_at, e.starts_at),
           (coalesce(e.checkin_test_mode, false)
             AND e.checkin_test_until IS NOT NULL
             AND now() < e.checkin_test_until)
      INTO v_open_at, v_test
      FROM public.exos_events e WHERE e.id = t.event_id;
    IF NOT v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
      r := jsonb_build_object('ok', false, 'reason', 'doors-not-open', 'opens_at', v_open_at); EXIT decide;
    END IF;

    IF t.status = 'voided' THEN
      r := jsonb_build_object('ok', false, 'reason', 'voided'); EXIT decide;
    END IF;
    IF t.status = 'used' THEN
      r := public._exos_used_answer(t.id); EXIT decide;
    END IF;
    IF t.status <> 'active' THEN
      r := jsonb_build_object('ok', false, 'reason', 'not-found'); EXIT decide;
    END IF;
    IF t.pending_transfer_id IS NULL THEN
      r := jsonb_build_object('ok', false, 'reason', 'not-parked'); EXIT decide;
    END IF;
    SELECT * INTO tr FROM public.exos_transfers WHERE id = t.pending_transfer_id FOR UPDATE;
    IF NOT public._exos_ticket_parked(t, tr) THEN
      r := jsonb_build_object('ok', false, 'reason', 'in-transfer'); EXIT decide;
    END IF;

    -- Pre-doors test window: proves the flow works, changes nothing.
    IF v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
      r := jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true); EXIT decide;
    END IF;

    -- The claim link dies with the admission: nobody claims a ticket whose
    -- buyer is already inside. The ticket stays on the org, used.
    UPDATE public.exos_transfers SET status = 'cancelled', updated_at = now() WHERE id = tr.id;
    UPDATE public.exos_tickets
       SET status = 'used', check_in_at = v_scan_at, pending_transfer_id = NULL
     WHERE id = t.id AND status = 'active';

    INSERT INTO public.exos_event_checkins
      (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification,
       device, override_reason, offline_scanned_at)
    VALUES (t.event_id, t.id, t.org_id, v_uid,
            lower(coalesce(auth.jwt() ->> 'email', '')),
            'manual', 'will-call',
            nullif(left(btrim(coalesce(p_device, '')), 60), ''),
            left(btrim(p_reason), 300),
            p_scanned_at);

    v_name := coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), ''));
    r := jsonb_build_object('ok', true, 'reason', 'checked-in', 'check_in_at', v_scan_at,
                            'verified', false, 'will_call', true)
         || jsonb_strip_nulls(jsonb_build_object('claim_name', v_name));
  END decide;

  IF p_client_ref IS NOT NULL THEN
    -- An offline replay the server refused: a conflict, logged for the scan
    -- report like exos_check_in_offline's.
    IF NOT coalesce((r ->> 'ok')::boolean, false) THEN
      r := r || jsonb_build_object('conflict', true);
      v_rr := CASE r ->> 'reason'
                WHEN 'used'        THEN 'used'
                WHEN 'voided'      THEN 'voided'
                WHEN 'in-transfer' THEN 'in-transfer'
                WHEN 'wrong-event' THEN 'wrong-event'
                ELSE 'not-found' END;
      INSERT INTO public.exos_scan_rejects
        (event_id, org_id, rejected_by, reason, source, ticket_id_attempted, reason_detail)
      VALUES (p_event_id, v_ev_org, v_uid, v_rr, 'manual', p_ticket_id::text,
              left('will-call-replay:' || coalesce(r ->> 'reason', 'unknown'), 200));
    END IF;
    INSERT INTO public.exos_checkin_client_refs (client_ref, ticket_id, event_id, org_id, scanned_by, result)
    VALUES (p_client_ref, p_ticket_id, p_event_id, v_ev_org, v_uid, r)
    ON CONFLICT (client_ref) DO NOTHING;
  END IF;
  RETURN r;
END $$;

REVOKE ALL ON FUNCTION public.exos_door_admit_parked(uuid, uuid, text, text, timestamptz, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_door_admit_parked(uuid, uuid, text, text, timestamptz, uuid) TO authenticated;

-- ROLLBACK: DROP FUNCTION exos_door_admit_parked(uuid, uuid, text, text,
-- timestamptz, uuid), _exos_ticket_parked(exos_tickets, exos_transfers);
-- re-create exos_event_checkin_roster from 20260911134000 + the 20260929041000
-- patch (DROP first: the return type shrinks). The widened CHECK can stay.
