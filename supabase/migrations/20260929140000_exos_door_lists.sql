-- ============================================================================
-- Migration 20260929140000 — Exos (Bridge / D4): check-in lists (gates),
--                            optional re-entry, and offline admissions the
--                            server refuses recorded as forced check-ins
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_checkin_lists (+ RLS, scope trigger)
--           W: exos_event_checkins (+list_id, +direction, +gate, +forced,
--              +conflict, CHECKs, index),
--           C: FUNCTION exos_check_in_ticket (10 args), exos_check_in_offline
--              (10 args), exos_door_checkin_by_name (8 args): new overloads
--              with + p_list_id, p_direction and NO defaults. The 8 / 8 / 6
--              argument versions stay exactly as they are (old clients).
--           W: FUNCTION exos_event_checkin_roster(uuid) (DROPPED +
--              re-created: + tier_id, list_state),
--              FUNCTION exos_tg_ticket_checked_in (webhook: first real entry
--              only),
--              FUNCTION _exos_used_answer, exos_event_analytics,
--              exos_send_mail_followups (patched in place: entries only)
--           C: FUNCTION _exos_scan_time_ok, _exos_checkin_list_refusal,
--              _exos_list_inside, _exos_post_transfer_code,
--              _exos_record_forced_checkin (internal, no client grant),
--              exos_tg_checkin_list_scope (trigger)
--           W: exos_tickets (status, check_in_at), exos_transfers,
--              exos_checkin_client_refs, exos_scan_rejects
--           R: exos_events, exos_ticket_tiers, exos_org_memberships,
--              exos_event_staff (via exos_can_door_event)
-- Pre-reqs: 20260929130000 (name check-in, the roster this replaces),
--           20260929072000 (wallet W- codes in exos_check_in_ticket),
--           20260929080000 (exos_check_in_offline staff gate),
--           20260929040000 (client refs, device, offline_scanned_at),
--           20260929041000 (exos_can_door_event)
--
-- Operator decision (2026-09-29): "Keep reentry optional". Re-entry is OFF
-- by default everywhere; an organizer opts a list in.
--
-- 1. Check-in lists (pretix CheckinList, kept simple). A list is a gate or
--    an area: a name, the ticket types it admits (tier_ids NULL = all), an
--    optional time window (valid_from / valid_until, checked at scan time,
--    entries only), and allow_reentry (default false). An event with no
--    lists behaves exactly as before: one implicit "everyone, no re-entry"
--    list. Nothing is migrated.
--      RLS: owner / manager of the event's org write; door staff of the
--      event (exos_can_door_event: owner, manager, assigned scanner) read.
--      The event decides org_id (trigger); tier ids must be the event's.
-- 2. exos_event_checkins gains list_id (NULL = no list / implicit),
--    direction 'entry' | 'exit' (default 'entry'), gate (the list's name when
--    scanned, kept if the list is renamed or deleted), forced + conflict
--    (section 4). Rows written by these functions use clock_timestamp() so
--    entry / exit order within one transaction is exact.
-- 3. exos_check_in_ticket / exos_check_in_offline / exos_door_checkin_by_name
--    get an overload with p_list_id and p_direction ('entry' | 'exit') on
--    the end. Every argument of the overload is required: with defaults a
--    call with the old argument count would match both versions ("function
--    is not unique"), in SQL and through PostgREST. The old versions are
--    untouched, so old clients (and every earlier migration's in-place
--    patch, re-run by the harness) see exactly today's behaviour: no list,
--    no exits, the 24-hour window, no forced rows. They can become thin
--    wrappers once nothing old calls them. The new versions, with a NULL
--    list and 'entry', behave like the old ones plus sections 4 and 5. With
--    a list:
--      * the list must be the ticket's event's ('unknown-list'),
--      * the ticket's tier must be on it ('wrong-list', entries and exits),
--      * an entry's scan time must be inside the window ('invalid-time'),
--      * allow_reentry = false: exactly today's rules (a used ticket is
--        refused 'used'; exits are refused 'exit-not-allowed'),
--      * allow_reentry = true: "inside" means the last scan ON THIS LIST at
--        or before the scan time was an entry. A second entry without an
--        exit is refused 'already-inside'; an exit (always accepted for a
--        ticket that isn't voided, as in pretix) re-opens the ticket.
--    Without a list an exit is 'exit-not-allowed'.
--    TICKET STATUS: the first entry (any list, or none) flips the ticket to
--    'used' and sets check_in_at, as today. Exits and re-entries never touch
--    the status: a ticket that has ever entered stays 'used', so sold /
--    checked-in counters (exos_event_analytics by tier / promoter / channel,
--    exos_mcp_door_status, the door's "In") keep counting tickets that came,
--    not people inside now. The per-list direction lives only in
--    exos_event_checkins. Undo (exos_undo_check_in) still removes every row
--    of the ticket, exits included, and re-opens it.
--    Reports that counted check-in rows now count entry rows only
--    (exos_event_analytics scans, the weekly summary mail, _exos_used_answer);
--    the ticket.checked_in webhook fires once, for the first non-forced entry.
-- 4. Offline admissions the server refuses (audit #6): the new
--    exos_check_in_offline and a by-name replay (with a client ref) still write the scan-reject row (reason kept in
--    reason_detail), and for an ENTRY refused as voided, doors-not-open,
--    too old (bad-scan-time, not future-dated), wrong-list, invalid-time,
--    in-transfer, or a code signed for a previous holder (post-transfer:
--    'barcode-rejected' whose owner segment is the sender of a completed
--    transfer of this ticket) they ALSO insert the check-in with forced =
--    true and conflict = the reason, so attendance stays true. A forced row
--    never changes the ticket's status and is not proof of a valid code (the
--    server could not verify it); it is written only for a ticket of the
--    event, by door staff assigned to the event. 'used' and 'already-inside'
--    stay reject-only (a true double entry).
-- 5. The replay window (new versions): a scan time may be up to 2 minutes in the future and
--    at most 24 hours old, OR (at most 7 days old and) the replay arrives
--    before the event's end + 48 hours (ends_at, else starts_at + 12 h).
-- 6. The roster adds tier_id and list_state ({list_id: 'entry'|'exit'}, the
--    last direction per re-entry list), so a device decides lists offline.
--
-- Re-run safe (CREATE TABLE / ADD COLUMN IF NOT EXISTS, constraints and
-- policies only when missing / dropped first, CREATE OR REPLACE, patches
-- that skip once applied). D4 authors; applying to prod is operator-gated.
-- Not applied to prod.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
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
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ---------------------------------------------------------------------------
-- 1. Check-in lists.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_checkin_lists (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id      uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL,
  name          text NOT NULL,
  tier_ids      uuid[],
  allow_reentry boolean NOT NULL DEFAULT false,
  valid_from    timestamptz,
  valid_until   timestamptz,
  sort_order    integer NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_checkin_lists_window_chk
    CHECK (valid_from IS NULL OR valid_until IS NULL OR valid_until > valid_from),
  CONSTRAINT exos_checkin_lists_tiers_chk
    CHECK (tier_ids IS NULL OR cardinality(tier_ids) BETWEEN 1 AND 200),
  CONSTRAINT exos_checkin_lists_name_chk
    CHECK (char_length(name) BETWEEN 1 AND 60)
);
CREATE INDEX IF NOT EXISTS exos_checkin_lists_event_idx ON public.exos_checkin_lists (event_id, sort_order);

CREATE OR REPLACE FUNCTION public.exos_tg_checkin_list_scope()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = NEW.event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'check-in list: event not found' USING ERRCODE = '23503';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.event_id IS DISTINCT FROM OLD.event_id THEN
    RAISE EXCEPTION 'check-in list: a list can''t move to another event' USING ERRCODE = '42501';
  END IF;
  -- The event decides the org; RLS then checks the caller's role in it.
  NEW.org_id := v_org;
  NEW.name := left(btrim(coalesce(NEW.name, '')), 60);
  IF NEW.name = '' THEN
    RAISE EXCEPTION 'check-in list: give it a name' USING ERRCODE = '22023';
  END IF;
  -- All ticket types is NULL; a list names at least one of the event's.
  IF NEW.tier_ids IS NOT NULL THEN
    NEW.tier_ids := ARRAY(SELECT DISTINCT x FROM unnest(NEW.tier_ids) x WHERE x IS NOT NULL ORDER BY x);
    IF cardinality(NEW.tier_ids) = 0 THEN
      RAISE EXCEPTION 'check-in list: pick at least one ticket type, or all' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(NEW.tier_ids) x
                WHERE NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers t
                                   WHERE t.id = x AND t.event_id = NEW.event_id)) THEN
      RAISE EXCEPTION 'check-in list: a ticket type is not on this event' USING ERRCODE = '42501';
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_checkin_list_scope() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_checkin_lists_scope ON public.exos_checkin_lists;
CREATE TRIGGER exos_checkin_lists_scope BEFORE INSERT OR UPDATE ON public.exos_checkin_lists
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_checkin_list_scope();

ALTER TABLE public.exos_checkin_lists ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_checkin_lists_sel ON public.exos_checkin_lists;
CREATE POLICY exos_checkin_lists_sel ON public.exos_checkin_lists FOR SELECT TO authenticated
  USING (public.exos_is_admin()
         OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager'])
         OR public.exos_can_door_event(event_id));
DROP POLICY IF EXISTS exos_checkin_lists_ins ON public.exos_checkin_lists;
CREATE POLICY exos_checkin_lists_ins ON public.exos_checkin_lists FOR INSERT TO authenticated
  WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
DROP POLICY IF EXISTS exos_checkin_lists_upd ON public.exos_checkin_lists;
CREATE POLICY exos_checkin_lists_upd ON public.exos_checkin_lists FOR UPDATE TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager']))
  WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
DROP POLICY IF EXISTS exos_checkin_lists_del ON public.exos_checkin_lists;
CREATE POLICY exos_checkin_lists_del ON public.exos_checkin_lists FOR DELETE TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
REVOKE ALL ON public.exos_checkin_lists FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_checkin_lists TO authenticated;
GRANT ALL ON public.exos_checkin_lists TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Check-in rows: list, direction, gate, forced / conflict.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_event_checkins
  ADD COLUMN IF NOT EXISTS list_id   uuid REFERENCES public.exos_checkin_lists (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS direction text NOT NULL DEFAULT 'entry',
  ADD COLUMN IF NOT EXISTS gate      text,
  ADD COLUMN IF NOT EXISTS forced    boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS conflict  text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.exos_event_checkins'::regclass
                    AND conname = 'exos_event_checkins_direction_chk') THEN
    ALTER TABLE public.exos_event_checkins ADD CONSTRAINT exos_event_checkins_direction_chk
      CHECK (direction IN ('entry', 'exit'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.exos_event_checkins'::regclass
                    AND conname = 'exos_event_checkins_forced_chk') THEN
    ALTER TABLE public.exos_event_checkins ADD CONSTRAINT exos_event_checkins_forced_chk
      CHECK ((forced AND conflict IS NOT NULL AND direction = 'entry') OR (NOT forced AND conflict IS NULL));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_event_checkins_ticket_list_idx
  ON public.exos_event_checkins (ticket_id, list_id);

-- ---------------------------------------------------------------------------
-- 3. Internal helpers (definer functions only; no client grant).
-- ---------------------------------------------------------------------------

-- The replay window (header, 5). NULL scan time = a live scan.
CREATE OR REPLACE FUNCTION public._exos_scan_time_ok(p_event_id uuid, p_scanned_at timestamptz)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_scanned_at IS NULL OR (
       p_scanned_at <= now() + interval '2 minutes'
   AND (p_scanned_at >= now() - interval '24 hours'
        OR (p_scanned_at >= now() - interval '7 days'
            AND EXISTS (SELECT 1 FROM public.exos_events e
                         WHERE e.id = p_event_id
                           AND now() <= coalesce(e.ends_at, e.starts_at + interval '12 hours') + interval '48 hours'))));
$$;
REVOKE ALL ON FUNCTION public._exos_scan_time_ok(uuid, timestamptz) FROM PUBLIC, anon, authenticated;

-- Why a list refuses this ticket, or NULL when it may pass. 'unknown-list',
-- 'wrong-list' (tier), 'invalid-time' (entries only), 'exit-not-allowed'.
-- A NULL list is the implicit one: everyone, no exits.
CREATE OR REPLACE FUNCTION public._exos_checkin_list_refusal(
  p_event_id uuid, p_tier_id uuid, p_list_id uuid, p_direction text, p_scan_at timestamptz)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE l public.exos_checkin_lists%ROWTYPE;
BEGIN
  IF p_list_id IS NULL THEN
    IF p_direction = 'exit' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'exit-not-allowed');
    END IF;
    RETURN NULL;
  END IF;
  SELECT * INTO l FROM public.exos_checkin_lists WHERE id = p_list_id;
  IF NOT FOUND OR l.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown-list');
  END IF;
  IF l.tier_ids IS NOT NULL AND (p_tier_id IS NULL OR NOT (p_tier_id = ANY (l.tier_ids))) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-list', 'list', l.name);
  END IF;
  IF p_direction = 'exit' AND NOT l.allow_reentry THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'exit-not-allowed', 'list', l.name);
  END IF;
  IF p_direction = 'entry'
     AND ((l.valid_from IS NOT NULL AND p_scan_at < l.valid_from)
          OR (l.valid_until IS NOT NULL AND p_scan_at > l.valid_until)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid-time', 'list', l.name)
           || jsonb_strip_nulls(jsonb_build_object('valid_from', l.valid_from, 'valid_until', l.valid_until));
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_checkin_list_refusal(uuid, uuid, uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;

-- On a re-entry list: the 'already-inside' answer when the last scan on the
-- list at or before p_at was an entry, else NULL.
CREATE OR REPLACE FUNCTION public._exos_list_inside(p_ticket_id uuid, p_list_id uuid, p_at timestamptz)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN c.direction = 'entry'
              THEN jsonb_build_object('ok', false, 'reason', 'already-inside')
                   || jsonb_strip_nulls(jsonb_build_object('check_in_at', c.at, 'device', c.device, 'list', c.gate))
         END
    FROM (SELECT ci.direction, coalesce(ci.offline_scanned_at, ci.scanned_at) AS at, ci.device, ci.gate
            FROM public.exos_event_checkins ci
           WHERE ci.ticket_id = p_ticket_id AND ci.list_id = p_list_id
             AND coalesce(ci.offline_scanned_at, ci.scanned_at) <= p_at
           ORDER BY coalesce(ci.offline_scanned_at, ci.scanned_at) DESC, ci.scanned_at DESC
           LIMIT 1) c;
$$;
REVOKE ALL ON FUNCTION public._exos_list_inside(uuid, uuid, timestamptz) FROM PUBLIC, anon, authenticated;

-- A T- code signed for a PREVIOUS holder of this ticket: the owner segment is
-- the sender of a completed transfer of it. (The secret rotated on the
-- claim, so the old signature can't be re-checked; this only names the case.)
CREATE OR REPLACE FUNCTION public._exos_post_transfer_code(p_ticket_id uuid, p_payload text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_parts text[];
BEGIN
  IF p_payload IS NULL OR upper(left(btrim(p_payload), 2)) <> 'T-' THEN
    RETURN false;
  END IF;
  v_parts := string_to_array(substring(btrim(p_payload) FROM 3), ':');
  IF array_length(v_parts, 1) <> 4 OR v_parts[1] <> p_ticket_id::text THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.exos_transfers tr JOIN public.exos_tickets t ON t.id = tr.ticket_id
     WHERE tr.ticket_id = p_ticket_id AND tr.status = 'completed'
       AND tr.sender_id::text = v_parts[2] AND t.owner_id::text <> v_parts[2]);
EXCEPTION WHEN others THEN
  RETURN false;
END $$;
REVOKE ALL ON FUNCTION public._exos_post_transfer_code(uuid, text) FROM PUBLIC, anon, authenticated;

-- Record an offline admission the server refused (header, 4). Returns the new
-- check-in id, or NULL when it may not be written (not this event's ticket,
-- caller not door staff of the event). Never touches the ticket.
CREATE OR REPLACE FUNCTION public._exos_record_forced_checkin(
  p_ticket_id uuid, p_event_id uuid, p_list_id uuid, p_source text, p_verification text,
  p_device text, p_scanned_at timestamptz, p_conflict text, p_note text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t      public.exos_tickets%ROWTYPE;
  v_list public.exos_checkin_lists%ROWTYPE;
  v_id   uuid;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF NOT FOUND OR t.event_id <> p_event_id
     OR NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = t.org_id)
     OR NOT public.exos_can_door_event(p_event_id) THEN
    RETURN NULL;
  END IF;
  IF p_list_id IS NOT NULL THEN
    SELECT * INTO v_list FROM public.exos_checkin_lists WHERE id = p_list_id AND event_id = p_event_id;
  END IF;
  INSERT INTO public.exos_event_checkins
    (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification,
     device, override_reason, offline_scanned_at, scanned_at, list_id, direction, gate, forced, conflict)
  VALUES (t.event_id, t.id, t.org_id, auth.uid(),
          lower(coalesce(auth.jwt() ->> 'email', '')),
          CASE WHEN p_source = 'camera' THEN 'camera' ELSE 'manual' END,
          CASE WHEN p_verification = 'name' THEN 'name' ELSE 'manual' END,
          nullif(left(btrim(coalesce(p_device, '')), 60), ''),
          left('offline conflict: ' || p_conflict
               || coalesce(' · ' || nullif(btrim(coalesce(p_note, '')), ''), ''), 300),
          p_scanned_at, clock_timestamp(), v_list.id, 'entry', v_list.name, true, left(p_conflict, 40))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_record_forced_checkin(uuid, uuid, uuid, text, text, text, timestamptz, text, text)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. exos_check_in_ticket(10 args). The body is the 20260929040000 /
--    041000 / 072000 one with the list rules and the replay window added
--    (header, 3 and 5). The 8-argument version is left as it is.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_check_in_ticket(
  p_ticket_id       uuid,
  p_source          text,
  p_verification    text,
  p_barcode_payload text,
  p_event_id        uuid,
  p_reason          text,
  p_scanned_at      timestamptz,
  p_device          text,
  p_list_id         uuid,
  p_direction       text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_org       uuid;
  v_event     uuid;
  v_prev      text;
  v_pending   uuid;
  v_owner     uuid;
  v_secret    text;
  v_tier      uuid;
  v_updated   int;
  v_open_at   timestamptz;
  v_test      boolean := false;
  v_verified  boolean := false;
  -- clock_timestamp: entry / exit order is exact even within one transaction.
  v_scan_at   timestamptz := coalesce(p_scanned_at, clock_timestamp());
  v_manager   boolean := false;
  v_dir       text := lower(coalesce(nullif(btrim(p_direction), ''), 'entry'));
  v_list      public.exos_checkin_lists%ROWTYPE;
  v_refusal   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT org_id, event_id, status, pending_transfer_id, owner_id, barcode_secret, tier_id
    INTO v_org, v_event, v_prev, v_pending, v_owner, v_secret, v_tier
    FROM public.exos_tickets WHERE id = p_ticket_id;
  IF v_org IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;

  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authorized' USING ERRCODE = '42501';
  END IF;
  v_manager := exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager']);

  IF v_dir NOT IN ('entry', 'exit') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-direction');
  END IF;

  -- door lists: offline scan window. Never in the future (2 minutes of clock
  -- slack); at most 24 hours old, or until the event's end + 48 hours.
  IF NOT public._exos_scan_time_ok(v_event, p_scanned_at) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-scan-time');
  END IF;

  -- p1: event scope required (the scanner always works on one event)
  IF p_event_id IS NULL OR v_event <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;
  -- door: scanner event scope (exos_event_staff, mig 20260929041000)
  IF NOT public.exos_can_door_event(v_event) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-assigned');
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = v_event AND e.status = 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'event-cancelled');
  END IF;

  -- Doors-open gate (entries). Test mode is honored ONLY while
  -- checkin_test_until is in the future (auto-expiry).
  SELECT coalesce(e.doors_at, e.starts_at),
         (coalesce(e.checkin_test_mode, false)
           AND e.checkin_test_until IS NOT NULL
           AND now() < e.checkin_test_until)
    INTO v_open_at, v_test
    FROM public.exos_events e WHERE e.id = v_event;
  IF v_dir = 'entry' AND NOT v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'doors-not-open',
                              'opens_at', v_open_at);
  END IF;

  -- Barcode verification: a camera scan MUST present a valid signed code
  -- (T- rotating HMAC or W- wallet pass); manual typed entry is a staff
  -- override; legacy / bare payloads are rejected.
  DECLARE
    v_signed boolean := (nullif(btrim(p_barcode_payload), '') IS NOT NULL
                         AND (upper(left(btrim(p_barcode_payload), 2)) = 'T-'
                              OR position(':' in p_barcode_payload) > 0));
  BEGIN
    IF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN
      -- wallet: W- pass code (Apple static / Google TOTP), mig 20260929072000.
      DECLARE
        v_wallet text := public._exos_wallet_check_code(p_ticket_id, v_owner, v_secret,
                                                        btrim(p_barcode_payload), v_scan_at);
      BEGIN
        IF v_wallet <> 'ok' THEN
          RETURN jsonb_build_object('ok', false, 'reason', v_wallet);
        END IF;
        v_verified := true;
      END;
    ELSIF v_signed THEN
      DECLARE
        v_parts text[] := string_to_array(substring(p_barcode_payload FROM 3), ':');
        v_cur   bigint := floor(extract(epoch FROM v_scan_at) * 1000 / 30000);
        v_bkt   bigint;
        v_exp   text;
      BEGIN
        IF array_length(v_parts, 1) <> 4 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        IF v_parts[1] <> p_ticket_id::text OR v_parts[2] <> v_owner::text THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        v_bkt := v_parts[3]::bigint;
        IF abs(v_cur - v_bkt) > 2 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-expired');
        END IF;
        v_exp := rtrim(translate(encode(
                   extensions.hmac(v_parts[1] || ':' || v_parts[2] || ':' || v_parts[3],
                                   coalesce(v_secret, ''), 'sha256'), 'base64'),
                   '+/', '-_'), '=');
        IF v_exp <> v_parts[4] THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        v_verified := true;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END;
    ELSIF p_source = 'camera' THEN
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
    END IF;
  END;

  -- door lists: tier, window, exits.
  v_refusal := public._exos_checkin_list_refusal(v_event, v_tier, p_list_id, v_dir, v_scan_at);
  IF v_refusal IS NOT NULL THEN
    RETURN v_refusal;
  END IF;
  IF p_list_id IS NOT NULL THEN
    SELECT * INTO v_list FROM public.exos_checkin_lists WHERE id = p_list_id;
  END IF;

  IF v_prev = 'voided' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'voided');
  END IF;
  IF v_prev NOT IN ('active', 'used') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;

  -- An exit (re-entry lists only): recorded, the ticket stays as it is.
  -- Before doors, the test window only proves the scanner works: nothing is
  -- recorded (entries and exits alike).
  IF v_dir = 'exit' THEN
    IF v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
      RETURN jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true);
    END IF;
    PERFORM 1 FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
    INSERT INTO public.exos_event_checkins
      (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification,
       device, override_reason, offline_scanned_at, scanned_at, list_id, direction, gate)
    VALUES (v_event, p_ticket_id, v_org, v_uid, lower(coalesce(auth.jwt() ->> 'email', '')),
            CASE WHEN v_verified AND p_source = 'camera' THEN 'camera' ELSE 'manual' END,
            CASE WHEN v_verified THEN 'verified' ELSE 'manual' END,
            nullif(left(btrim(coalesce(p_device, '')), 60), ''),
            CASE WHEN v_verified THEN NULL ELSE left(btrim(p_reason), 300) END,
            p_scanned_at, clock_timestamp(), v_list.id, 'exit', v_list.name);
    RETURN jsonb_build_object('ok', true, 'reason', 'checked-out', 'direction', 'exit',
                              'scanned_at', v_scan_at, 'verified', v_verified);
  END IF;

  IF v_pending IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer');
  END IF;

  -- A re-entry list: inside = the last scan on this list was an entry. The
  -- ticket row lock serializes two gates scanning the same ticket.
  IF v_list.allow_reentry THEN
    PERFORM 1 FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
    v_refusal := public._exos_list_inside(p_ticket_id, v_list.id, v_scan_at);
    IF v_refusal IS NOT NULL THEN
      RETURN v_refusal;
    END IF;
    IF v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
      RETURN jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true);
    END IF;
    -- The first entry anywhere uses the ticket; later ones leave it be.
    UPDATE public.exos_tickets
       SET status = 'used', check_in_at = v_scan_at
     WHERE id = p_ticket_id AND status = 'active';
    INSERT INTO public.exos_event_checkins
      (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification,
       device, override_reason, offline_scanned_at, scanned_at, list_id, direction, gate)
    VALUES (v_event, p_ticket_id, v_org, v_uid, lower(coalesce(auth.jwt() ->> 'email', '')),
            CASE WHEN v_verified AND p_source = 'camera' THEN 'camera' ELSE 'manual' END,
            CASE WHEN v_verified THEN 'verified' ELSE 'manual' END,
            nullif(left(btrim(coalesce(p_device, '')), 60), ''),
            CASE WHEN v_verified THEN NULL ELSE left(btrim(p_reason), 300) END,
            p_scanned_at, clock_timestamp(), v_list.id, 'entry', v_list.name);
    RETURN jsonb_build_object('ok', true, 'reason', 'checked-in', 'check_in_at', v_scan_at,
                              'verified', v_verified, 'reentry', v_prev = 'used');
  END IF;

  IF v_prev = 'used' THEN
    RETURN public._exos_used_answer(p_ticket_id);
  END IF;

  IF v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true);
  END IF;

  UPDATE public.exos_tickets
     SET status = 'used', check_in_at = v_scan_at
   WHERE id = p_ticket_id AND status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RETURN public._exos_used_answer(p_ticket_id);
  END IF;

  INSERT INTO public.exos_event_checkins
    (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification,
     device, override_reason, offline_scanned_at, scanned_at, list_id, direction, gate)
  VALUES (
    v_event, p_ticket_id, v_org, v_uid,
    lower(coalesce(auth.jwt() ->> 'email', '')),
    CASE WHEN v_verified AND p_source = 'camera' THEN 'camera' ELSE 'manual' END,
    CASE WHEN v_verified THEN 'verified' ELSE 'manual' END,
    nullif(left(btrim(coalesce(p_device, '')), 60), ''),
    CASE WHEN v_verified THEN NULL ELSE left(btrim(p_reason), 300) END,
    p_scanned_at, clock_timestamp(), v_list.id, 'entry', v_list.name
  );

  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in', 'check_in_at', v_scan_at,
                            'verified', v_verified);
END $$;
REVOKE ALL ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text, uuid, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. exos_check_in_offline(10 args): + p_list_id, p_direction; refused
--    entries are recorded as forced check-ins (header, 4). The 8-argument
--    version is left as it is.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_check_in_offline(
  p_client_ref      uuid,
  p_ticket_id       uuid,
  p_event_id        uuid,
  p_scanned_at      timestamptz,
  p_barcode_payload text,
  p_source          text,
  p_reason          text,
  p_device          text,
  p_list_id         uuid,
  p_direction       text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_prev     public.exos_checkin_client_refs%ROWTYPE;
  v_org      uuid;
  v_event    uuid;
  r          jsonb;
  v_rr       text;
  v_conflict text;
  v_forced   uuid;
  v_dir      text := lower(coalesce(nullif(btrim(p_direction), ''), 'entry'));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_offline: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_client_ref IS NULL OR p_scanned_at IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_offline: client_ref and scanned_at are required' USING ERRCODE = '22023';
  END IF;

  -- rpc hardening (mig 20260929080000): only the event org's door staff
  -- write client refs and scan rejects, or read a ref's cached answer.
  IF NOT (public.exos_is_admin() OR EXISTS (
            SELECT 1 FROM public.exos_events e
             WHERE e.id = p_event_id
               AND public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'scanner']))) THEN
    RAISE EXCEPTION 'exos_check_in_offline: not authorized' USING ERRCODE = '42501';
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
         'manual', p_barcode_payload, p_event_id, p_reason, p_scanned_at, p_device,
         p_list_id, v_dir);

  SELECT org_id, event_id INTO v_org, v_event FROM public.exos_tickets WHERE id = p_ticket_id;

  IF NOT coalesce((r ->> 'ok')::boolean, false) THEN
    r := r || jsonb_build_object('conflict', true);
    v_rr := CASE r ->> 'reason'
              WHEN 'barcode-rejected' THEN 'invalid-barcode'
              WHEN 'barcode-expired'  THEN 'expired-code'
              WHEN 'used'             THEN 'used'
              WHEN 'already-inside'   THEN 'used'
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

    -- door lists: the door admitted them, so attendance is recorded (forced).
    IF v_dir = 'entry' THEN
      v_conflict := CASE r ->> 'reason'
                      WHEN 'voided'         THEN 'voided'
                      WHEN 'doors-not-open' THEN 'doors-not-open'
                      WHEN 'wrong-list'     THEN 'wrong-list'
                      WHEN 'invalid-time'   THEN 'invalid-time'
                      WHEN 'in-transfer'    THEN 'in-transfer'
                      WHEN 'bad-scan-time'  THEN
                        CASE WHEN p_scanned_at <= now() + interval '2 minutes' THEN 'too-old' END
                      WHEN 'barcode-rejected' THEN
                        CASE WHEN public._exos_post_transfer_code(p_ticket_id, p_barcode_payload) THEN 'post-transfer' END
                    END;
      IF v_conflict IS NOT NULL THEN
        v_forced := public._exos_record_forced_checkin(
                      p_ticket_id, p_event_id,
                      CASE WHEN r ->> 'reason' = 'unknown-list' THEN NULL ELSE p_list_id END,
                      p_source, 'manual', p_device, p_scanned_at, v_conflict, p_reason);
        IF v_forced IS NOT NULL THEN
          r := r || jsonb_build_object('forced', true, 'conflict_reason', v_conflict);
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO public.exos_checkin_client_refs (client_ref, ticket_id, event_id, org_id, scanned_by, result)
  VALUES (p_client_ref, p_ticket_id, v_event, v_org, v_uid, r)
  ON CONFLICT (client_ref) DO NOTHING;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.exos_check_in_offline(uuid, uuid, uuid, timestamptz, text, text, text, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_check_in_offline(uuid, uuid, uuid, timestamptz, text, text, text, text, uuid, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. exos_door_checkin_by_name(8 args): + p_list_id, p_direction (the
--    20260929130000 body with the list rules, the replay window and forced
--    replays added). The 6-argument version is left as it is.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_door_checkin_by_name(
  p_ticket_id  uuid,
  p_event_id   uuid,
  p_note       text,
  p_device     text,
  p_scanned_at timestamptz,
  p_client_ref uuid,
  p_list_id    uuid,
  p_direction  text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_ev_org   uuid;
  v_mode     text;
  v_prev     public.exos_checkin_client_refs%ROWTYPE;
  t          public.exos_tickets%ROWTYPE;
  tr         public.exos_transfers%ROWTYPE;
  v_parked   boolean := false;
  v_scan_at  timestamptz := coalesce(p_scanned_at, clock_timestamp());
  v_open_at  timestamptz;
  v_test     boolean := false;
  v_name     text;
  v_dir      text := lower(coalesce(nullif(btrim(p_direction), ''), 'entry'));
  v_list     public.exos_checkin_lists%ROWTYPE;
  v_refusal  jsonb;
  v_note     text := nullif(left(btrim(coalesce(p_note, '')), 300), '');
  v_device   text := nullif(left(btrim(coalesce(p_device, '')), 60), '');
  r          jsonb;
  v_rr       text;
  v_conflict text;
  v_forced   uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_door_checkin_by_name: not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Door staff of the event's org only (the row's org, not a caller-given id).
  SELECT e.org_id, e.door_name_checkin INTO v_ev_org, v_mode FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_ev_org IS NULL OR NOT (public.exos_is_admin()
       OR public.exos_has_org_role(v_ev_org, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_door_checkin_by_name: not authorized' USING ERRCODE = '42501';
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
    IF v_dir NOT IN ('entry', 'exit') THEN
      r := jsonb_build_object('ok', false, 'reason', 'bad-direction'); EXIT decide;
    END IF;
    SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
    IF NOT FOUND THEN
      r := jsonb_build_object('ok', false, 'reason', 'not-found'); EXIT decide;
    END IF;
    IF t.event_id <> p_event_id OR t.org_id <> v_ev_org THEN
      r := jsonb_build_object('ok', false, 'reason', 'wrong-event'); EXIT decide;
    END IF;
    -- The event's setting: off = QR only; managers = owner / manager (or admin).
    IF coalesce(v_mode, 'staff') = 'off' THEN
      r := jsonb_build_object('ok', false, 'reason', 'name-checkin-off'); EXIT decide;
    END IF;
    IF v_mode = 'managers'
       AND NOT (public.exos_is_admin() OR public.exos_has_org_role(t.org_id, ARRAY['owner', 'manager'])) THEN
      r := jsonb_build_object('ok', false, 'reason', 'needs-manager'); EXIT decide;
    END IF;
    -- Scanners only on the events they are assigned to.
    IF NOT public.exos_can_door_event(t.event_id) THEN
      r := jsonb_build_object('ok', false, 'reason', 'not-assigned'); EXIT decide;
    END IF;
    IF NOT public._exos_scan_time_ok(t.event_id, p_scanned_at) THEN
      r := jsonb_build_object('ok', false, 'reason', 'bad-scan-time'); EXIT decide;
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
    IF v_dir = 'entry' AND NOT v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
      r := jsonb_build_object('ok', false, 'reason', 'doors-not-open', 'opens_at', v_open_at); EXIT decide;
    END IF;

    IF t.status = 'voided' THEN
      r := jsonb_build_object('ok', false, 'reason', 'voided'); EXIT decide;
    END IF;
    IF t.status NOT IN ('active', 'used') THEN
      r := jsonb_build_object('ok', false, 'reason', 'not-found'); EXIT decide;
    END IF;

    -- door lists: tier, window, exits.
    v_refusal := public._exos_checkin_list_refusal(t.event_id, t.tier_id, p_list_id, v_dir, v_scan_at);
    IF v_refusal IS NOT NULL THEN
      r := v_refusal; EXIT decide;
    END IF;
    IF p_list_id IS NOT NULL THEN
      SELECT * INTO v_list FROM public.exos_checkin_lists WHERE id = p_list_id;
    END IF;

    -- Pre-doors test window: proves the flow works, changes nothing.
    IF v_test AND v_open_at IS NOT NULL AND now() < v_open_at
       AND (v_dir = 'exit' OR v_list.allow_reentry
            OR (t.status = 'active' AND t.pending_transfer_id IS NULL)) THEN
      r := jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true); EXIT decide;
    END IF;

    -- An exit (re-entry lists only): recorded, the ticket stays as it is.
    IF v_dir = 'exit' THEN
      INSERT INTO public.exos_event_checkins
        (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification,
         device, override_reason, offline_scanned_at, scanned_at, list_id, direction, gate)
      VALUES (t.event_id, t.id, t.org_id, v_uid, lower(coalesce(auth.jwt() ->> 'email', '')),
              'manual', 'name', v_device, v_note, p_scanned_at, clock_timestamp(),
              v_list.id, 'exit', v_list.name);
      r := jsonb_build_object('ok', true, 'reason', 'checked-out', 'direction', 'exit',
                              'scanned_at', v_scan_at, 'by_name', true);
      EXIT decide;
    END IF;

    IF v_list.allow_reentry THEN
      v_refusal := public._exos_list_inside(t.id, v_list.id, v_scan_at);
      IF v_refusal IS NOT NULL THEN
        r := v_refusal; EXIT decide;
      END IF;
    ELSIF t.status = 'used' THEN
      r := public._exos_used_answer(t.id); EXIT decide;
    END IF;

    IF t.pending_transfer_id IS NOT NULL THEN
      SELECT * INTO tr FROM public.exos_transfers WHERE id = t.pending_transfer_id FOR UPDATE;
      v_parked := public._exos_ticket_parked(t, tr);
      -- A holder's own transfer: the ticket may already be the friend's.
      IF NOT v_parked THEN
        r := jsonb_build_object('ok', false, 'reason', 'in-transfer'); EXIT decide;
      END IF;
    END IF;

    -- An unclaimed ticket's link dies with the check-in: nobody claims a
    -- ticket whose buyer is already inside. It stays on the org, used.
    IF v_parked THEN
      UPDATE public.exos_transfers SET status = 'cancelled', updated_at = now() WHERE id = tr.id;
    END IF;
    -- The first entry uses the ticket; a re-entry leaves it be.
    UPDATE public.exos_tickets
       SET status = 'used', check_in_at = v_scan_at, pending_transfer_id = NULL
     WHERE id = t.id AND status = 'active';

    INSERT INTO public.exos_event_checkins
      (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification,
       device, override_reason, offline_scanned_at, scanned_at, list_id, direction, gate)
    VALUES (t.event_id, t.id, t.org_id, v_uid,
            lower(coalesce(auth.jwt() ->> 'email', '')),
            'manual', 'name', v_device, v_note, p_scanned_at, clock_timestamp(),
            v_list.id, 'entry', v_list.name);

    v_name := CASE WHEN v_parked THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), ''))
                   ELSE nullif(t.attendee_name, '') END;
    r := jsonb_build_object('ok', true, 'reason', 'checked-in', 'check_in_at', v_scan_at,
                            'verified', false, 'by_name', true, 'parked', v_parked)
         || CASE WHEN v_list.allow_reentry THEN jsonb_build_object('reentry', t.status = 'used') ELSE '{}'::jsonb END
         || jsonb_strip_nulls(jsonb_build_object('name', v_name));
  END decide;

  IF p_client_ref IS NOT NULL THEN
    -- An offline replay the server refused: a conflict, logged for the scan
    -- report like exos_check_in_offline's, and (entries refused for a reason
    -- the door couldn't know) recorded as a forced check-in.
    IF NOT coalesce((r ->> 'ok')::boolean, false) THEN
      r := r || jsonb_build_object('conflict', true);
      v_rr := CASE r ->> 'reason'
                WHEN 'used'           THEN 'used'
                WHEN 'already-inside' THEN 'used'
                WHEN 'voided'         THEN 'voided'
                WHEN 'in-transfer'    THEN 'in-transfer'
                WHEN 'wrong-event'    THEN 'wrong-event'
                ELSE 'not-found' END;
      INSERT INTO public.exos_scan_rejects
        (event_id, org_id, rejected_by, reason, source, ticket_id_attempted, reason_detail)
      VALUES (p_event_id, v_ev_org, v_uid, v_rr, 'manual', p_ticket_id::text,
              left('name-replay:' || coalesce(r ->> 'reason', 'unknown'), 200));
      IF v_dir = 'entry' THEN
        v_conflict := CASE r ->> 'reason'
                        WHEN 'voided'         THEN 'voided'
                        WHEN 'doors-not-open' THEN 'doors-not-open'
                        WHEN 'wrong-list'     THEN 'wrong-list'
                        WHEN 'invalid-time'   THEN 'invalid-time'
                        WHEN 'in-transfer'    THEN 'in-transfer'
                        WHEN 'bad-scan-time'  THEN
                          CASE WHEN p_scanned_at <= now() + interval '2 minutes' THEN 'too-old' END
                      END;
        IF v_conflict IS NOT NULL THEN
          v_forced := public._exos_record_forced_checkin(
                        p_ticket_id, p_event_id, p_list_id, 'manual', 'name', p_device,
                        p_scanned_at, v_conflict, p_note);
          IF v_forced IS NOT NULL THEN
            r := r || jsonb_build_object('forced', true, 'conflict_reason', v_conflict);
          END IF;
        END IF;
      END IF;
    END IF;
    INSERT INTO public.exos_checkin_client_refs (client_ref, ticket_id, event_id, org_id, scanned_by, result)
    VALUES (p_client_ref, p_ticket_id, p_event_id, v_ev_org, v_uid, r)
    ON CONFLICT (client_ref) DO NOTHING;
  END IF;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamptz, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamptz, uuid, uuid, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Roster: + tier_id, list_state. Return type changes: DROP + CREATE.
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
  claim_email_masked  text,
  tier_id             uuid,
  list_state          jsonb
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
           CASE WHEN pk.parked THEN public.exos_mask_email(lower(btrim(tr.receiver_email))) END,
           t.tier_id,
           -- door lists: the last direction per re-entry list, so a device
           -- decides entry / exit offline. NULL when there is none.
           (SELECT jsonb_object_agg(x.list_id, x.direction)
              FROM (SELECT DISTINCT ON (ci.list_id) ci.list_id, ci.direction
                      FROM public.exos_event_checkins ci
                      JOIN public.exos_checkin_lists l ON l.id = ci.list_id AND l.allow_reentry
                     WHERE ci.ticket_id = t.id
                     ORDER BY ci.list_id, coalesce(ci.offline_scanned_at, ci.scanned_at) DESC, ci.scanned_at DESC) x)
    FROM public.exos_tickets t
    LEFT JOIN public.exos_profiles p ON p.id = t.owner_id
    LEFT JOIN public.exos_transfers tr ON tr.id = t.pending_transfer_id
    CROSS JOIN LATERAL (SELECT (t.pending_transfer_id IS NOT NULL AND public._exos_ticket_parked(t, tr)) AS parked) pk
    WHERE t.event_id = p_event_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_checkin_roster(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_event_checkin_roster(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Webhook: ticket.checked_in fires for the first real entry only (not an
--    exit, a re-entry or a forced record).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_checked_in()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.direction = 'exit' OR NEW.forced
     OR EXISTS (SELECT 1 FROM public.exos_event_checkins c
                 WHERE c.ticket_id = NEW.ticket_id AND c.id <> NEW.id
                   AND c.direction = 'entry' AND NOT c.forced) THEN
    RETURN NEW;
  END IF;
  PERFORM public.exos_enqueue_webhook(NEW.org_id, 'ticket.checked_in', jsonb_build_object(
    'ticket_id', NEW.ticket_id, 'event_id', NEW.event_id,
    'verification', NEW.verification, 'scanned_at', NEW.scanned_at));
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- 9. Reports that counted check-in rows count entries only.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public._exos_used_answer(uuid)',
  'ci.direction = ''entry''',
  'WHERE ci.ticket_id = t.id',
  'WHERE ci.ticket_id = t.id AND ci.direction = ''entry''', 1);

SELECT pg_temp.exos_patch_n('public.exos_event_analytics(uuid)',
  'AND direction = ''entry''',
  'FROM public.exos_event_checkins WHERE event_id = p_event_id',
  'FROM public.exos_event_checkins WHERE event_id = p_event_id AND direction = ''entry''', 3);

SELECT pg_temp.exos_patch_n('public.exos_send_mail_followups(integer)',
  'c.direction = ''entry''',
  'WHERE c.org_id = r.org_id AND c.scanned_at >= v_from',
  'WHERE c.org_id = r.org_id AND c.direction = ''entry'' AND c.scanned_at >= v_from', 1);

-- ROLLBACK: DROP the 10 / 10 / 8-argument door overloads (the old versions
-- were never touched);
-- re-create exos_event_checkin_roster from 20260929130000 (DROP first: the
-- return type shrinks); re-create exos_tg_ticket_checked_in from
-- 20260616200000; revert the three patches; DROP the _exos_* helpers above;
-- ALTER TABLE exos_event_checkins DROP COLUMN list_id, direction, gate,
-- forced, conflict; DROP TABLE exos_checkin_lists.
