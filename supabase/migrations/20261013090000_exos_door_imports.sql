-- ============================================================================
-- Exos Door: check in tickets sold anywhere (imported attendee lists)
-- ============================================================================
-- Touches:  W: exos_guest_list_entries (+ external_code, ticket_label, source;
--              unique external_code per event)
--           C: FUNCTION exos_import_guests(uuid, jsonb), _exos_door_code(text)
--           W: FUNCTION exos_event_door_extras (patched in place: + code,
--              ticket, source per guest; + the per-event scanner scope)
--           R: exos_guest_lists, exos_events, exos_org_memberships,
--              exos_event_staff (exos_can_door_event)
-- Pre-reqs: 20260926050000 (guest lists, door extras), 20260926090000
--           (access needs in door extras: the patch anchors on it),
--           20260929041000 (exos_can_door_event)
--
-- The first app of the Exos suite (docs/strategy.md "Apps"): a free door
-- for any event, including one whose tickets were sold on Eventbrite, Posh,
-- DICE, Shotgun or RA. The organizer imports that platform's attendee export
-- into a guest list; the door then checks people in by name (as today) or by
-- scanning the barcode the other platform issued.
--
-- 1. Guest entries gain external_code (the other platform's barcode / ticket
--    number, normalized by _exos_door_code: whitespace removed, upper case,
--    1-128 chars), ticket_label (their ticket type, <= 80) and source (the
--    platform's name, <= 40). A code is unique within an event.
-- 2. exos_import_guests(list, rows) adds up to 5000 rows at once (owner /
--    manager of the list's org). Each row: {name, email?, phone?, code?,
--    ticket?, plus_ones?, note?, source?}. Rows whose code is already in the
--    event, or (without a code) whose name + email is already on the list,
--    are skipped, so importing the same export twice adds nothing. Bad rows
--    are skipped and reported (first 20). Same per-row rules as adding a
--    guest by hand (_exos_guest_insert: list cap, plus-ones limit, event not
--    cancelled). Returns {inserted, duplicates, invalid, errors[]}.
-- 3. The door download carries code / ticket / source, so a scanned code is
--    matched on the device (online or offline) and checked in through the
--    existing exos_guest_check_in. It now also applies the per-event scanner
--    scope (exos_can_door_event), like the roster: a scanner assigned to other
--    events no longer downloads this event's guests.
--
-- An imported code is not a signed Exos code: whoever holds a copy of it gets
-- in once, as with the other platform's own door app. The door says which
-- platform issued it.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated. Not applied.
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
-- 1. Columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_guest_list_entries
  ADD COLUMN IF NOT EXISTS external_code text,
  ADD COLUMN IF NOT EXISTS ticket_label  text,
  ADD COLUMN IF NOT EXISTS source        text;

DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_guest_entries_external_code_chk') THEN
    ALTER TABLE public.exos_guest_list_entries ADD CONSTRAINT exos_guest_entries_external_code_chk
      CHECK (external_code IS NULL OR external_code ~ '^[^\s]{1,128}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_guest_entries_ticket_label_chk') THEN
    ALTER TABLE public.exos_guest_list_entries ADD CONSTRAINT exos_guest_entries_ticket_label_chk
      CHECK (ticket_label IS NULL OR length(ticket_label) <= 80);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_guest_entries_source_chk') THEN
    ALTER TABLE public.exos_guest_list_entries ADD CONSTRAINT exos_guest_entries_source_chk
      CHECK (source IS NULL OR length(source) <= 40);
  END IF;
END $c$;

CREATE UNIQUE INDEX IF NOT EXISTS exos_guest_entries_event_code_uq
  ON public.exos_guest_list_entries (event_id, external_code) WHERE external_code IS NOT NULL;

-- The one normalization (the SPA's lib/door/imports normalizeDoorCode is the
-- same): whitespace removed, upper case. NULL when empty or longer than 128.
CREATE OR REPLACE FUNCTION public._exos_door_code(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN length(c) BETWEEN 1 AND 128 THEN c END
    FROM (SELECT upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')) AS c) x;
$$;
REVOKE ALL ON FUNCTION public._exos_door_code(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_door_code(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Bulk import.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_import_guests(p_list_id uuid, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  l          public.exos_guest_lists%ROWTYPE;
  r          jsonb;
  i          int := 0;
  v_name     text;
  v_email    text;
  v_code     text;
  v_id       uuid;
  v_inserted int := 0;
  v_dupes    int := 0;
  v_invalid  int := 0;
  v_errors   jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_import_guests: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO l FROM public.exos_guest_lists WHERE id = p_list_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_import_guests: guest list not found';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(l.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_import_guests: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'exos_import_guests: rows must be an array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_rows) > 5000 THEN
    RAISE EXCEPTION 'exos_import_guests: at most 5000 rows per import' USING ERRCODE = '22023';
  END IF;

  FOR r IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    i := i + 1;
    v_name  := nullif(btrim(coalesce(r->>'name', '')), '');
    v_email := nullif(lower(btrim(coalesce(r->>'email', ''))), '');
    v_code  := public._exos_door_code(r->>'code');
    IF jsonb_typeof(r) <> 'object' OR v_name IS NULL
       OR (nullif(btrim(coalesce(r->>'code', '')), '') IS NOT NULL AND v_code IS NULL) THEN
      v_invalid := v_invalid + 1;
      IF jsonb_array_length(v_errors) < 20 THEN
        v_errors := v_errors || jsonb_build_object('row', i,
          'reason', CASE WHEN v_name IS NULL THEN 'missing name' ELSE 'code too long' END);
      END IF;
      CONTINUE;
    END IF;
    IF v_code IS NOT NULL THEN
      IF EXISTS (SELECT 1 FROM public.exos_guest_list_entries
                  WHERE event_id = l.event_id AND external_code = v_code) THEN
        v_dupes := v_dupes + 1;
        CONTINUE;
      END IF;
    ELSIF EXISTS (SELECT 1 FROM public.exos_guest_list_entries
                   WHERE list_id = l.id AND lower(guest_name) = lower(left(v_name, 80))
                     AND email IS NOT DISTINCT FROM v_email) THEN
      v_dupes := v_dupes + 1;
      CONTINUE;
    END IF;
    BEGIN
      v_id := public._exos_guest_insert(
        l.id, v_name,
        CASE WHEN v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(v_email) <= 254 THEN v_email END,
        CASE WHEN btrim(coalesce(r->>'phone', '')) ~ '^[0-9+() .-]{3,32}$' THEN btrim(r->>'phone') END,
        CASE WHEN coalesce(r->>'plus_ones', '') ~ '^\d{1,2}$' THEN (r->>'plus_ones')::int ELSE 0 END,
        left(nullif(btrim(coalesce(r->>'note', '')), ''), 200),
        auth.uid(), NULL);
      UPDATE public.exos_guest_list_entries
         SET external_code = v_code,
             ticket_label  = left(nullif(btrim(coalesce(r->>'ticket', '')), ''), 80),
             source        = left(nullif(btrim(coalesce(r->>'source', '')), ''), 40)
       WHERE id = v_id;
      v_inserted := v_inserted + 1;
    EXCEPTION
      WHEN unique_violation THEN
        -- The same code twice in one file.
        v_dupes := v_dupes + 1;
      WHEN check_violation OR raise_exception THEN
        v_invalid := v_invalid + 1;
        IF jsonb_array_length(v_errors) < 20 THEN
          v_errors := v_errors || jsonb_build_object('row', i,
            'reason', regexp_replace(SQLERRM, '^exos: ', ''));
        END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object('inserted', v_inserted, 'duplicates', v_dupes,
                            'invalid', v_invalid, 'errors', v_errors);
END $$;
REVOKE ALL ON FUNCTION public.exos_import_guests(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_import_guests(uuid, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Door download: imported code / ticket / source, and the scanner scope.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_event_door_extras(uuid)',
  $m$'code', g.external_code$m$,
  $o$'access_needs', to_jsonb(g.access_needs)) ORDER BY g.guest_name)$o$,
  $n$'access_needs', to_jsonb(g.access_needs),
               'code', g.external_code, 'ticket', g.ticket_label, 'source', g.source) ORDER BY g.guest_name)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_event_door_extras(uuid)',
  'exos_can_door_event(p_event_id)',
  $o$RAISE EXCEPTION 'exos_event_door_extras: not authorized for this event' USING ERRCODE = '42501';
  END IF;$o$,
  $n$RAISE EXCEPTION 'exos_event_door_extras: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  -- door: scanner event scope (exos_event_staff, mig 20260929041000)
  IF NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_event_door_extras: not assigned to this event' USING ERRCODE = '42501';
  END IF;$n$, 1);
