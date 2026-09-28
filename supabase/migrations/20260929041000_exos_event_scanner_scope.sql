-- ============================================================================
-- Migration 20260929041000 — Exos (Bridge / D4): scanners limited to events
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: exos_event_staff, exos_can_door_event(uuid),
--              exos_set_scanner_events(uuid, uuid, uuid[])
--           W: FUNCTION exos_check_in_ticket (8-arg, 20260929040000),
--              exos_guest_check_in, exos_event_checkin_roster,
--              exos_can_read_ticket_secret (patched in place; each is skipped
--              where the chain doesn't have it)
-- Pre-reqs: 20260929040000 (for the check-in patch; the rest applies without it)
--
-- From the 2026-09-28 door review: a scanner could check in, and read the
-- barcode secrets of, every event in the org. Door staff hired for one show
-- could pull the roster (names + secrets) of every other show.
--
-- exos_event_staff lists the events a scanner may work. A scanner with no
-- rows there keeps today's org-wide access (backward compatible); once an
-- owner or manager gives them one or more events, check-in (tickets and guest
-- lists), the offline roster and the barcode-secret view only answer for
-- those events. Owners and managers are never restricted. Managed with
-- exos_set_scanner_events(org, user, events[]) — an empty list lifts the
-- restriction.
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE; each patch asserts one match
-- and is skipped once applied). D4 authors; applying to prod is operator-gated.
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

CREATE TABLE IF NOT EXISTS public.exos_event_staff (
  event_id   uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  user_id    uuid        NOT NULL,
  org_id     uuid        NOT NULL,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, user_id)
);
CREATE INDEX IF NOT EXISTS exos_event_staff_org_user_idx ON public.exos_event_staff (org_id, user_id);
ALTER TABLE public.exos_event_staff ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_event_staff FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_event_staff TO authenticated;
DROP POLICY IF EXISTS exos_event_staff_sel ON public.exos_event_staff;
CREATE POLICY exos_event_staff_sel ON public.exos_event_staff FOR SELECT TO authenticated
  USING (user_id = auth.uid()
         OR public.exos_is_admin()
         OR public.exos_has_org_role(org_id, ARRAY['owner','manager']));

-- May the caller work the door of this event? Owner / manager of its org, or a
-- scanner who is either unrestricted (no exos_event_staff rows in the org) or
-- assigned to this event.
CREATE OR REPLACE FUNCTION public.exos_can_door_event(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.exos_is_admin() OR EXISTS (
    SELECT 1
      FROM public.exos_events e
      JOIN public.exos_org_memberships m
        ON m.org_id = e.org_id AND m.user_id = auth.uid() AND m.disabled IS NOT TRUE
     WHERE e.id = p_event_id
       AND (m.role IN ('owner', 'manager')
            OR (m.role = 'scanner'
                AND (EXISTS (SELECT 1 FROM public.exos_event_staff s
                              WHERE s.event_id = e.id AND s.user_id = m.user_id)
                     OR NOT EXISTS (SELECT 1 FROM public.exos_event_staff s
                                     WHERE s.org_id = e.org_id AND s.user_id = m.user_id)))));
$$;
REVOKE ALL ON FUNCTION public.exos_can_door_event(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_can_door_event(uuid) TO authenticated, service_role;

-- Owner / manager: the events a member may scan (empty / NULL = all events).
-- Returns how many events the member is now limited to.
CREATE OR REPLACE FUNCTION public.exos_set_scanner_events(p_org_id uuid, p_user_id uuid, p_event_ids uuid[])
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_ids uuid[] := ARRAY(SELECT DISTINCT x FROM unnest(coalesce(p_event_ids, '{}'::uuid[])) x WHERE x IS NOT NULL);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_set_scanner_events: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_scanner_events: not authorized' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_org_memberships WHERE org_id = p_org_id AND user_id = p_user_id) THEN
    RAISE EXCEPTION 'exos_set_scanner_events: not a member of this organization' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_ids) x
              WHERE NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = x AND e.org_id = p_org_id)) THEN
    RAISE EXCEPTION 'exos_set_scanner_events: every event must belong to this organization' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.exos_event_staff WHERE org_id = p_org_id AND user_id = p_user_id;
  INSERT INTO public.exos_event_staff (event_id, user_id, org_id, created_by)
  SELECT x, p_user_id, p_org_id, auth.uid() FROM unnest(v_ids) x;
  RETURN cardinality(v_ids);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_scanner_events(uuid, uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_scanner_events(uuid, uuid, uuid[]) TO authenticated;

-- ── Enforcement ────────────────────────────────────────────────────────────

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'door: scanner event scope',
  $o$  IF EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = v_event AND e.status = 'cancelled') THEN$o$,
  $n$  -- door: scanner event scope (exos_event_staff, mig 20260929041000)
  IF NOT public.exos_can_door_event(v_event) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-assigned');
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = v_event AND e.status = 'cancelled') THEN$n$);

SELECT pg_temp.exos_patch('public.exos_guest_check_in(uuid, integer, uuid, uuid, text)',
  'door: scanner event scope',
  $o$  IF p_client_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_guest_list_checkins WHERE client_ref = p_client_ref) THEN$o$,
  $n$  -- door: scanner event scope (exos_event_staff, mig 20260929041000)
  IF NOT public.exos_can_door_event(en.event_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-assigned');
  END IF;
  IF p_client_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_guest_list_checkins WHERE client_ref = p_client_ref) THEN$n$);

SELECT pg_temp.exos_patch('public.exos_event_checkin_roster(uuid)',
  'door: scanner event scope',
  $o$  RETURN QUERY$o$,
  $n$  -- door: scanner event scope (exos_event_staff, mig 20260929041000)
  IF NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: not assigned to this event' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY$n$);

-- The barcode-secret view's gate: door staff only for events they may work.
SELECT pg_temp.exos_patch('public.exos_can_read_ticket_secret(uuid)',
  'exos_can_door_event(t.event_id)',
  $o$OR public.exos_has_org_role(t.org_id, ARRAY['owner','manager','scanner'])$o$,
  $n$OR (public.exos_has_org_role(t.org_id, ARRAY['owner','manager','scanner'])
            AND public.exos_can_door_event(t.event_id))$n$);

-- ROLLBACK: DROP TABLE exos_event_staff (every scanner is org-wide again; the
-- patched functions then treat everyone as unrestricted) — or re-create the
-- four functions from their previous migrations.
