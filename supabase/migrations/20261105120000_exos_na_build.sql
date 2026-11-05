-- ============================================================================
-- Migration 20261105120000 — Exos: Opendate endpoints that were "not
-- applicable", built (2026-11-05)
-- ============================================================================
-- docs/opendate-coverage.json listed 58 Opendate endpoints as not applicable.
-- This builds the ones that fit Exos; the rest keep a sharper reason there.
--
-- 1. Printed tickets (docs/wallet.md "Printed tickets"). Exos has no static,
--    copyable barcode, so a printed ticket carries a one-time print code
--    instead: `P-{ticket}:{22 random characters}` (128 random bits), shown
--    once; only its SHA-256 is stored (exos_ticket_print_codes).
--      * single use: the door accepts it once, through exos_check_in_ticket
--        (both overloads, patched), in the same transaction that uses the
--        ticket; a second scan is refused 'print-code-used';
--      * one at a time: a partial unique index allows one live code per
--        ticket, and printing again voids the last one ('reprinted');
--      * never next to another code: while a print code is live, the
--        ticket's app (T-) and wallet (W-) codes are refused 'printed'.
--        Voiding the paper (exos_ticket_print_void) gives the phone back;
--      * voided on transfer (started or claimed), refund / release / void,
--        a rotated barcode secret, and spent when the ticket is admitted any
--        other way (by name, typed override): exos_tg_print_ticket_changed;
--      * offline doors: the roster's door keys carry `p`, the code's
--        SHA-256 (as `wa` is the Apple code's), so a door phone checks a
--        P- code without being able to make one, and knows the ticket is
--        printed. The upload re-checks it here.
--    Printing is staff-only (owner / manager: the box office): the
--    dashboard RPCs exos_ticket_print / exos_order_print and the API's
--    POST /v1/tickets/:id/print, POST /v1/orders/:id/print (_exos_api_print).
--    The edge function renders the codes as JSON, an HTML page or a PDF
--    (_shared/print). No printer language (FGL): any ticket printer prints
--    the PDF through its driver.
-- 2. Membership reservations (box office). Membership products can have a
--    capacity (NULL: unlimited). A reservation holds one place for 10
--    minutes; complete issues the membership (paid at the counter: cash,
--    check or a card on another terminal, recorded on the reservation row);
--    cancel frees it; an unfinished one expires. Capacity counts live
--    memberships plus open reservations, under a product row lock.
-- 3. Team switching: exos_api_token_auth_org. A personal access token may
--    act in another organization of its user with X-Exos-Org, held to the
--    user's role there. OAuth tokens stay pinned (the user approved the app
--    for one organization); org API keys are the organization.
-- 4. Staff shifts: clock in / out on the signed-in door phone (any active
--    member, optionally against an event and a registered device), one open
--    shift per member per organization, an owner / manager correction for a
--    forgotten clock-out, and the hours report.
-- 5. Tixel waitlist signups: _exos_tixel_ingest stores Tixel's fan-data
--    webhook (exos-tixel-webhook checks the secret, held in an env var) and
--    puts a WAITLIST signup on the waitlist of the org's event with that
--    title. Consent is never changed.
-- 6. Tagged items: _exos_tagged_item_retag moves an assignment to another
--    tag (PUT /v1/tagged-items/:id).
--
-- Touches:  C: TABLE exos_ticket_print_codes, exos_membership_reservations,
--              exos_staff_shifts, exos_tixel_signups
--           W: TABLE exos_membership_products (+ capacity)
--           W: FUNCTION exos_check_in_ticket (both), exos_check_in_offline
--              (both) (patched in place, marker-checked), _exos_door_keys
--              (redefined: + p)
--           C: FUNCTION _exos_print_*, exos_ticket_print, exos_order_print,
--              exos_ticket_print_void, _exos_api_print, the membership
--              reservation, staff shift, Tixel and retag functions,
--              exos_api_token_auth_org, TRIGGER exos_tickets_print
-- Pre-reqs: every exos migration before this one.
-- Re-run safe: marker-checked patches (pg_temp.exos_patch_n), CREATE OR
-- REPLACE, IF NOT EXISTS. D4 authors; not applied.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
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

-- ===========================================================================
-- 1. Printed tickets
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_ticket_print_codes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  ticket_id   uuid NOT NULL REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  -- The holder when printed: a code is only good for that holder.
  owner_id    uuid,
  code_hash   text NOT NULL UNIQUE CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'used', 'voided')),
  void_reason text CHECK (void_reason IS NULL OR void_reason IN (
                'reprinted', 'voided-by-staff', 'voided-by-holder', 'ticket-voided', 'released',
                'transferred', 'transfer-started', 'secret-rotated')),
  printed_by  uuid,
  printed_via text NOT NULL DEFAULT 'dashboard' CHECK (printed_via IN ('dashboard', 'api')),
  api_key_id  uuid,
  used_at     timestamptz,
  used_by     uuid,
  voided_at   timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_ticket_print_codes_state_chk CHECK (
    (status = 'active' AND used_at IS NULL AND voided_at IS NULL AND void_reason IS NULL)
    OR (status = 'used' AND used_at IS NOT NULL AND voided_at IS NULL)
    OR (status = 'voided' AND voided_at IS NOT NULL AND void_reason IS NOT NULL))
);
-- One live print code per ticket, whatever races.
CREATE UNIQUE INDEX IF NOT EXISTS exos_ticket_print_codes_live_uq ON public.exos_ticket_print_codes (ticket_id)
  WHERE status = 'active';
CREATE INDEX IF NOT EXISTS exos_ticket_print_codes_ticket_idx ON public.exos_ticket_print_codes (ticket_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_ticket_print_codes_event_idx ON public.exos_ticket_print_codes (event_id);
DROP TRIGGER IF EXISTS exos_ticket_print_codes_touch ON public.exos_ticket_print_codes;
CREATE TRIGGER exos_ticket_print_codes_touch BEFORE UPDATE ON public.exos_ticket_print_codes
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_ticket_print_codes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_ticket_print_codes_staff_read ON public.exos_ticket_print_codes;
CREATE POLICY exos_ticket_print_codes_staff_read ON public.exos_ticket_print_codes
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_ticket_print_codes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_ticket_print_codes TO authenticated;
GRANT ALL ON public.exos_ticket_print_codes TO service_role;
COMMENT ON TABLE public.exos_ticket_print_codes IS
  'One-time door codes for printed tickets (only the SHA-256 is kept). One live code per ticket; while live the ticket''s app and wallet codes are refused. mig 20261105120000.';

-- The stored form of a print code: SHA-256 hex of the code with an upper-case P.
CREATE OR REPLACE FUNCTION public._exos_print_hash(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT encode(extensions.digest('P' || substring(btrim(p_code) FROM 2), 'sha256'), 'hex')
$$;
REVOKE ALL ON FUNCTION public._exos_print_hash(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_print_hash(text) TO service_role;

-- A print code's shape: P- (either case), the ticket id, ':', 22 base64url characters.
CREATE OR REPLACE FUNCTION public._exos_print_code_ticket(p_code text)
RETURNS uuid LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN btrim(coalesce(p_code, '')) ~
                   '^[Pp]-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[A-Za-z0-9_-]{22}$'
              THEN substring(btrim(p_code) FROM 3 FOR 36)::uuid END
$$;
REVOKE ALL ON FUNCTION public._exos_print_code_ticket(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_print_code_ticket(text) TO service_role;

-- Does the ticket have a live print code (then its other codes are refused)?
CREATE OR REPLACE FUNCTION public._exos_print_code_live(p_ticket uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_ticket_print_codes WHERE ticket_id = p_ticket AND status = 'active')
$$;
REVOKE ALL ON FUNCTION public._exos_print_code_live(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_print_code_live(uuid) TO service_role;

-- The door's check of a P- code (no write): 'ok', 'print-code-used' (spent
-- already; an exit with the paper of someone inside is 'ok'), or
-- 'barcode-rejected' (not this ticket's, voided, another holder's, malformed).
CREATE OR REPLACE FUNCTION public._exos_print_code_check(p_ticket uuid, p_owner uuid, p_code text, p_dir text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_ticket_print_codes%ROWTYPE;
BEGIN
  IF p_ticket IS NULL OR public._exos_print_code_ticket(p_code) IS DISTINCT FROM p_ticket THEN
    RETURN 'barcode-rejected';
  END IF;
  SELECT * INTO r FROM public.exos_ticket_print_codes
   WHERE ticket_id = p_ticket AND code_hash = public._exos_print_hash(p_code);
  IF r.id IS NULL OR r.status = 'voided' OR r.owner_id IS DISTINCT FROM p_owner THEN
    RETURN 'barcode-rejected';
  END IF;
  IF r.status = 'used' THEN
    RETURN CASE WHEN coalesce(p_dir, 'entry') = 'exit' THEN 'ok' ELSE 'print-code-used' END;
  END IF;
  RETURN 'ok';
END $$;
REVOKE ALL ON FUNCTION public._exos_print_code_check(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_print_code_check(uuid, uuid, text, text) TO service_role;

-- Spend a live print code (the check-in calls this just before it uses the
-- ticket, in the same transaction). The row lock makes two scans of the
-- same paper wait for each other: the second finds it used. false = spent.
CREATE OR REPLACE FUNCTION public._exos_print_code_use(p_ticket uuid, p_code text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE public.exos_ticket_print_codes
     SET status = 'used', used_at = clock_timestamp(), used_by = auth.uid()
   WHERE ticket_id = p_ticket AND code_hash = public._exos_print_hash(p_code) AND status = 'active';
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public._exos_print_code_use(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_print_code_use(uuid, text) TO service_role;

-- Void the ticket's live print code, if any. true = one was voided.
CREATE OR REPLACE FUNCTION public._exos_print_code_void(p_ticket uuid, p_reason text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE public.exos_ticket_print_codes
     SET status = 'voided', void_reason = p_reason, voided_at = clock_timestamp()
   WHERE ticket_id = p_ticket AND status = 'active';
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public._exos_print_code_void(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_print_code_void(uuid, text) TO service_role;

-- The ticket changed: a transfer, a refund / release / void and a new secret
-- kill the paper; an admission any other way (by name, a typed override)
-- spends it, so the paper can't get a second person in.
CREATE OR REPLACE FUNCTION public.exos_tg_print_ticket_changed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_reason text;
BEGIN
  IF NEW.status = 'voided' AND OLD.status IS DISTINCT FROM 'voided' THEN
    v_reason := CASE WHEN NEW.released_at IS NOT NULL THEN 'released' ELSE 'ticket-voided' END;
  ELSIF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    v_reason := 'transferred';
  ELSIF NEW.pending_transfer_id IS NOT NULL AND OLD.pending_transfer_id IS NULL THEN
    v_reason := 'transfer-started';
  ELSIF NEW.barcode_secret IS DISTINCT FROM OLD.barcode_secret THEN
    v_reason := 'secret-rotated';
  END IF;
  IF v_reason IS NOT NULL THEN
    PERFORM public._exos_print_code_void(NEW.id, v_reason);
  ELSIF NEW.status = 'used' AND OLD.status = 'active' THEN
    UPDATE public.exos_ticket_print_codes
       SET status = 'used', used_at = clock_timestamp(), used_by = auth.uid()
     WHERE ticket_id = NEW.id AND status = 'active';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_print_ticket_changed() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_print ON public.exos_tickets;
CREATE TRIGGER exos_tickets_print AFTER UPDATE OF status, owner_id, pending_transfer_id, barcode_secret
  ON public.exos_tickets FOR EACH ROW EXECUTE FUNCTION public.exos_tg_print_ticket_changed();

-- Why a ticket can't be printed now, or NULL.
CREATE OR REPLACE FUNCTION public._exos_print_refusal(t public.exos_tickets)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN t.status = 'used' THEN 'used'
    WHEN t.status <> 'active' THEN 'voided'
    WHEN t.pending_transfer_id IS NOT NULL THEN 'in-transfer'
    WHEN EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = t.event_id AND e.status = 'cancelled') THEN 'event-cancelled'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_print_refusal(public.exos_tickets) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_print_refusal(public.exos_tickets) TO service_role;

-- Mint print codes for tickets of one org (the callers check who may).
-- Each ticket's last code is voided ('reprinted') and a new one made, under
-- the ticket's row lock. p_skip: leave out tickets that can't be printed
-- (an order) instead of refusing the call (one ticket). At most 50 tickets.
-- Returns { tickets: [ { ticket_id, print_code, event / venue / seat … } ],
-- skipped: [ { ticket_id, reason } ] }. The codes are in this answer only.
CREATE OR REPLACE FUNCTION public._exos_print_mint(p_org uuid, p_actor uuid, p_ticket_ids uuid[], p_via text,
                                                   p_api_key uuid, p_skip boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_id      uuid;
  t         public.exos_tickets%ROWTYPE;
  v_why     text;
  v_code    text;
  v_out     jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_n       int := coalesce(cardinality(p_ticket_ids), 0);
BEGIN
  IF v_n = 0 THEN RAISE EXCEPTION 'name at least one ticket' USING ERRCODE = '22023'; END IF;
  IF v_n > 50 THEN RAISE EXCEPTION 'at most 50 tickets at a time' USING ERRCODE = '22023'; END IF;
  IF NOT public.exos_rate_hit('print:' || coalesce(p_actor::text, p_org::text), 60) THEN
    RAISE EXCEPTION 'too many prints a minute' USING ERRCODE = '54000';
  END IF;
  FOR v_id IN SELECT DISTINCT x FROM unnest(p_ticket_ids) x ORDER BY x LOOP
    SELECT * INTO t FROM public.exos_tickets WHERE id = v_id AND org_id = p_org FOR UPDATE;
    IF t.id IS NULL THEN
      RAISE EXCEPTION 'ticket not found' USING ERRCODE = 'P0002';
    END IF;
    v_why := public._exos_print_refusal(t);
    IF v_why IS NOT NULL THEN
      IF p_skip THEN
        v_skipped := v_skipped || jsonb_build_object('ticket_id', t.id, 'reason', v_why);
        CONTINUE;
      END IF;
      RAISE EXCEPTION 'this ticket can''t be printed (%)', v_why USING ERRCODE = '55000';
    END IF;
    PERFORM public._exos_print_code_void(t.id, 'reprinted');
    v_code := 'P-' || t.id::text || ':' || public._exos_b64url(extensions.gen_random_bytes(16));
    INSERT INTO public.exos_ticket_print_codes (org_id, event_id, ticket_id, owner_id, code_hash, printed_by,
                                                printed_via, api_key_id)
    VALUES (t.org_id, t.event_id, t.id, t.owner_id, public._exos_print_hash(v_code), p_actor, p_via, p_api_key);
    v_out := v_out || (
      SELECT jsonb_build_object(
               'ticket_id', t.id, 'print_code', v_code, 'event_id', e.id, 'event_name', e.name,
               'starts_at', e.starts_at, 'doors_at', e.doors_at, 'timezone', e.timezone,
               'occurs_at_local', e.occurs_at_local, 'venue_name', e.venue_name, 'venue_location', e.venue_location,
               'tier_name', coalesce(t.tier_name, tr.name), 'attendee_name', t.attendee_name,
               'seat_label', t.seat_label, 'org_name', o.name, 'order_ref', t.order_ref, 'printed_at', now())
        FROM public.exos_events e
        JOIN public.exos_orgs o ON o.id = e.org_id
        LEFT JOIN public.exos_ticket_tiers tr ON tr.id = t.tier_id
       WHERE e.id = t.event_id);
  END LOOP;
  RETURN jsonb_build_object('tickets', v_out, 'skipped', v_skipped);
END $$;
REVOKE ALL ON FUNCTION public._exos_print_mint(uuid, uuid, uuid[], text, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_print_mint(uuid, uuid, uuid[], text, uuid, boolean) TO service_role;

-- Dashboard (box office): print tickets of one organization. Owner / manager.
CREATE OR REPLACE FUNCTION public.exos_ticket_print(p_ticket_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_orgs uuid[];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT array_agg(DISTINCT org_id) INTO v_orgs FROM public.exos_tickets WHERE id = ANY (coalesce(p_ticket_ids, '{}'));
  IF v_orgs IS NULL OR cardinality(v_orgs) <> 1
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_orgs[1], ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'only an owner or manager of the tickets'' organization can print them' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_print_mint(v_orgs[1], auth.uid(), p_ticket_ids, 'dashboard', NULL, false);
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_print(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_ticket_print(uuid[]) TO authenticated, service_role;

-- The tickets of an order that can be printed now (the rest come back as skipped).
CREATE OR REPLACE FUNCTION public._exos_order_print_ids(p_org uuid, p_session_id text, p_event uuid)
RETURNS uuid[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_ids uuid[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions s
                  WHERE s.session_id = p_session_id AND s.org_id = p_org
                    AND (p_event IS NULL OR s.event_id = p_event)) THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT array_agg(id ORDER BY id) INTO v_ids FROM public.exos_tickets
   WHERE order_ref = p_session_id AND org_id = p_org;
  IF v_ids IS NULL THEN RAISE EXCEPTION 'this order has no tickets' USING ERRCODE = '55000'; END IF;
  RETURN v_ids;
END $$;
REVOKE ALL ON FUNCTION public._exos_order_print_ids(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_order_print_ids(uuid, text, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_order_print(p_session_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT org_id INTO v_org FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'only an owner or manager of the order''s organization can print it' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_print_mint(v_org, auth.uid(), public._exos_order_print_ids(v_org, p_session_id, NULL),
                                 'dashboard', NULL, true);
END $$;
REVOKE ALL ON FUNCTION public.exos_order_print(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_order_print(text) TO authenticated, service_role;

-- Void the paper: the holder (to go back to the app or wallet) or an owner /
-- manager. { ok, voided }.
CREATE OR REPLACE FUNCTION public.exos_ticket_print_void(p_ticket_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t public.exos_tickets%ROWTYPE; v_staff boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'ticket not found' USING ERRCODE = 'P0002'; END IF;
  v_staff := public.exos_is_admin() OR public.exos_has_org_role(t.org_id, ARRAY['owner', 'manager']);
  IF NOT v_staff AND t.owner_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'ticket not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object('ok', true, 'ticket_id', t.id,
    'voided', public._exos_print_code_void(t.id, CASE WHEN t.owner_id = auth.uid() THEN 'voided-by-holder' ELSE 'voided-by-staff' END));
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_print_void(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_ticket_print_void(uuid) TO authenticated, service_role;

-- The ticket page: is this ticket printed? The holder (to explain why the
-- phone's code is refused, and offer to void the paper) or an owner /
-- manager; anyone else gets P0002 as for a missing ticket.
CREATE OR REPLACE FUNCTION public.exos_ticket_print_state(p_ticket_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t public.exos_tickets%ROWTYPE; v_at timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF t.id IS NULL OR NOT (t.owner_id = auth.uid() OR public.exos_is_admin()
                          OR public.exos_has_org_role(t.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'ticket not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT created_at INTO v_at FROM public.exos_ticket_print_codes WHERE ticket_id = t.id AND status = 'active';
  RETURN jsonb_build_object('ticket_id', t.id, 'printed', v_at IS NOT NULL, 'printed_at', v_at);
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_print_state(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_ticket_print_state(uuid) TO authenticated, service_role;

-- exos-api: POST /v1/tickets/:id/print, POST /v1/orders/:id/print (and the
-- /confirms/:eid/… spellings, p_event), DELETE /v1/tickets/:id/print
-- (p_kind 'ticket_void'). The key needs tickets:write and a
-- creator who is an owner or manager now. Logged in exos_api_writes without
-- the codes, and never replayed: a retry prints again (and voids the last
-- paper), so a lost answer can't leave a live code nobody holds.
CREATE OR REPLACE FUNCTION public._exos_api_print(p_org uuid, p_api_key uuid, p_kind text, p_target text, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor uuid; v_ids uuid[]; v_out jsonb; v_ticket uuid;
BEGIN
  v_actor := public._exos_api_key_actor(p_org, p_api_key, ARRAY['owner', 'manager']);
  IF NOT public._exos_api_has_scope(public._exos_api_key_scopes(p_api_key), 'tickets:write') THEN
    RAISE EXCEPTION 'the key lacks the tickets:write scope' USING ERRCODE = '42501';
  END IF;
  IF p_kind = 'ticket' THEN
    v_ticket := CASE WHEN p_target ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN p_target::uuid END;
    IF v_ticket IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_tickets
                                        WHERE id = v_ticket AND org_id = p_org AND (p_event IS NULL OR event_id = p_event)) THEN
      RAISE EXCEPTION 'ticket not found' USING ERRCODE = 'P0002';
    END IF;
    v_out := public._exos_print_mint(p_org, v_actor, ARRAY[v_ticket], 'api', p_api_key, false);
  ELSIF p_kind = 'order' THEN
    v_ids := public._exos_order_print_ids(p_org, p_target, p_event);
    v_out := public._exos_print_mint(p_org, v_actor, v_ids, 'api', p_api_key, true);
  ELSIF p_kind = 'ticket_void' THEN
    v_ticket := CASE WHEN p_target ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN p_target::uuid END;
    PERFORM 1 FROM public.exos_tickets WHERE id = v_ticket AND org_id = p_org AND (p_event IS NULL OR event_id = p_event) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ticket not found' USING ERRCODE = 'P0002'; END IF;
    v_out := jsonb_build_object('ticket_id', v_ticket, 'voided', public._exos_print_code_void(v_ticket, 'voided-by-staff'));
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, result)
    VALUES (p_org, p_api_key, v_actor, 'ticket.print_void', left(p_target, 255), v_out);
    RETURN v_out;
  ELSE
    RAISE EXCEPTION 'unknown print kind' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, result)
  VALUES (p_org, p_api_key, v_actor, p_kind || '.print', left(p_target, 255),
          jsonb_build_object('printed', jsonb_array_length(v_out -> 'tickets'),
            'ticket_ids', (SELECT coalesce(jsonb_agg(x -> 'ticket_id'), '[]') FROM jsonb_array_elements(v_out -> 'tickets') x),
            'skipped', v_out -> 'skipped'));
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_print(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_print(uuid, uuid, text, text, uuid) TO service_role;

-- -- The door: a P- code through the same check-in path as every other code --
-- exos_check_in_ticket, list-aware overload: check the paper with the codes,
-- refuse app / wallet codes while it is live, spend it with the ticket.
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text, uuid, text)',
  '/* exos: print codes */',
$o$    IF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN$o$,
$n$    /* exos: print codes */ -- mig 20261105120000: a printed ticket's one-time code.
    IF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'P-' THEN
      DECLARE
        v_print text := public._exos_print_code_check(p_ticket_id, v_owner, btrim(p_barcode_payload), v_dir);
      BEGIN
        IF v_print <> 'ok' THEN
          RETURN jsonb_build_object('ok', false, 'reason', v_print);
        END IF;
        v_verified := true;
      END;
    ELSIF v_signed AND public._exos_print_code_live(p_ticket_id) THEN
      -- The paper is the ticket now: no other code beside it.
      RETURN jsonb_build_object('ok', false, 'reason', 'printed');
    ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text, uuid, text)',
  '/* exos: print code use */',
$o$  UPDATE public.exos_tickets
     SET status = 'used', check_in_at = v_scan_at
   WHERE id = p_ticket_id AND status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;$o$,
$n$  /* exos: print code use */ -- mig 20261105120000: spent with the ticket, or refused.
  IF v_verified AND upper(left(btrim(coalesce(p_barcode_payload, '')), 2)) = 'P-'
     AND NOT public._exos_print_code_use(p_ticket_id, btrim(p_barcode_payload)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'print-code-used');
  END IF;
  UPDATE public.exos_tickets
     SET status = 'used', check_in_at = v_scan_at
   WHERE id = p_ticket_id AND status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;$n$, 1);

-- A re-entry list: the first entry spends the paper too (under the ticket
-- row lock taken just above), so a second list can't take the same paper.
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text, uuid, text)',
  '/* exos: print code use, re-entry */',
$o$    -- The first entry anywhere uses the ticket; later ones leave it be.
$o$,
$n$    /* exos: print code use, re-entry */ -- mig 20261105120000.
    IF v_verified AND upper(left(btrim(coalesce(p_barcode_payload, '')), 2)) = 'P-'
       AND NOT public._exos_print_code_use(p_ticket_id, btrim(p_barcode_payload)) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'print-code-used');
    END IF;
    -- The first entry anywhere uses the ticket; later ones leave it be.
$n$, 1);

-- The older overload (no lists): the same rules, entries only.
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  '/* exos: print codes */',
$o$    IF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN$o$,
$n$    /* exos: print codes */ -- mig 20261105120000: a printed ticket's one-time code.
    IF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'P-' THEN
      DECLARE
        v_print text := public._exos_print_code_check(p_ticket_id, v_owner, btrim(p_barcode_payload), 'entry');
      BEGIN
        IF v_print <> 'ok' THEN
          RETURN jsonb_build_object('ok', false, 'reason', v_print);
        END IF;
        v_verified := true;
      END;
    ELSIF v_signed AND public._exos_print_code_live(p_ticket_id) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'printed');
    ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  '/* exos: print code use */',
$o$  UPDATE public.exos_tickets
     SET status = 'used', check_in_at = v_scan_at
   WHERE id = p_ticket_id AND status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;$o$,
$n$  /* exos: print code use */ -- mig 20261105120000: spent with the ticket, or refused.
  IF v_verified AND upper(left(btrim(coalesce(p_barcode_payload, '')), 2)) = 'P-'
     AND NOT public._exos_print_code_use(p_ticket_id, btrim(p_barcode_payload)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'print-code-used');
  END IF;
  UPDATE public.exos_tickets
     SET status = 'used', check_in_at = v_scan_at
   WHERE id = p_ticket_id AND status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;$n$, 1);

-- Offline uploads: a spent paper is 'used' in the scan report, a code
-- beside a live paper an invalid barcode.
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamptz, text, text, text, text, uuid, text)',
  $m$WHEN 'print-code-used'  THEN 'used'$m$,
$o$              WHEN 'barcode-rejected' THEN 'invalid-barcode'
$o$,
$n$              WHEN 'print-code-used'  THEN 'used'
              WHEN 'printed'          THEN 'invalid-barcode'
              WHEN 'barcode-rejected' THEN 'invalid-barcode'
$n$, 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamptz, text, text, text, text)',
  $m$WHEN 'print-code-used'  THEN 'used'$m$,
$o$              WHEN 'barcode-rejected' THEN 'invalid-barcode'
$o$,
$n$              WHEN 'print-code-used'  THEN 'used'
              WHEN 'printed'          THEN 'invalid-barcode'
              WHEN 'barcode-rejected' THEN 'invalid-barcode'
$n$, 1);

-- Door keys (mig 20261019100000) + `p`: the live print code's SHA-256. The
-- door checks a P- code offline with it, and knows not to take the app or
-- wallet code of a printed ticket. A hash: a lost door phone can't print.
CREATE OR REPLACE FUNCTION public._exos_door_keys(p_ticket uuid, p_owner uuid, p_secret text)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_today int := floor(extract(epoch FROM now()) / 86400)::int;
  v_out   jsonb;
  v_epoch int;
  v_print text;
BEGIN
  SELECT code_hash INTO v_print FROM public.exos_ticket_print_codes WHERE ticket_id = p_ticket AND status = 'active';
  IF p_secret IS NULL OR p_secret = '' THEN
    RETURN jsonb_build_object('d', '{}'::jsonb) || CASE WHEN v_print IS NOT NULL THEN jsonb_build_object('p', v_print) ELSE '{}'::jsonb END;
  END IF;
  v_out := jsonb_build_object('d', jsonb_build_object(
    (v_today - 1)::text, public._exos_door_day_key(p_ticket, p_secret, v_today - 1),
    v_today::text,       public._exos_door_day_key(p_ticket, p_secret, v_today),
    (v_today + 1)::text, public._exos_door_day_key(p_ticket, p_secret, v_today + 1)));
  IF p_owner IS NOT NULL THEN
    SELECT code_epoch INTO v_epoch
      FROM public.exos_wallet_passes
     WHERE ticket_id = p_ticket AND status = 'active' AND owner_id = p_owner;
    IF v_epoch IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(
        'we', v_epoch,
        'wa', encode(extensions.digest(public._exos_wallet_apple_code(p_ticket, p_owner, p_secret, v_epoch), 'sha256'), 'hex'),
        'wg', encode(public._exos_wallet_google_key(p_ticket, p_owner, p_secret, v_epoch), 'hex'));
    END IF;
  END IF;
  IF v_print IS NOT NULL THEN
    v_out := v_out || jsonb_build_object('p', v_print);
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_door_keys(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- 2. Membership reservations (box office)
-- ===========================================================================
ALTER TABLE public.exos_membership_products ADD COLUMN IF NOT EXISTS capacity integer;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_membership_products_capacity_chk') THEN
    ALTER TABLE public.exos_membership_products ADD CONSTRAINT exos_membership_products_capacity_chk
      CHECK (capacity IS NULL OR capacity BETWEEN 1 AND 1000000);
  END IF;
END $$;
COMMENT ON COLUMN public.exos_membership_products.capacity IS
  'Most live memberships plus open box-office reservations (NULL: unlimited). mig 20261105120000.';

CREATE TABLE IF NOT EXISTS public.exos_membership_reservations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  product_id        uuid NOT NULL REFERENCES public.exos_membership_products (id) ON DELETE CASCADE,
  token             text NOT NULL UNIQUE CHECK (token ~ '^mbr_[A-Za-z0-9_-]{43}$'),
  status            text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved', 'completed', 'cancelled', 'expired')),
  email             text NOT NULL CHECK (email = lower(email) AND char_length(email) BETWEEN 3 AND 254),
  first_name        text CHECK (first_name IS NULL OR char_length(first_name) BETWEEN 1 AND 60),
  last_name         text CHECK (last_name IS NULL OR char_length(last_name) BETWEEN 1 AND 60),
  -- Paid at the counter: cash, a check, or a card on another terminal.
  payment_method    text NOT NULL CHECK (payment_method IN ('cash', 'check', 'external')),
  payment_reference text CHECK (payment_reference IS NULL OR char_length(payment_reference) <= 255),
  amount_cents      integer NOT NULL CHECK (amount_cents >= 0),
  currency          text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  device_name       text CHECK (device_name IS NULL OR char_length(device_name) <= 255),
  created_by        uuid,
  api_key_id        uuid,
  membership_id     uuid REFERENCES public.exos_fan_memberships (id) ON DELETE SET NULL,
  expires_at        timestamptz NOT NULL,
  completed_at      timestamptz,
  cancelled_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_membership_reservations_open_idx ON public.exos_membership_reservations (product_id, expires_at)
  WHERE status = 'reserved';
CREATE UNIQUE INDEX IF NOT EXISTS exos_membership_reservations_email_uq ON public.exos_membership_reservations (product_id, email)
  WHERE status = 'reserved';
DROP TRIGGER IF EXISTS exos_membership_reservations_touch ON public.exos_membership_reservations;
CREATE TRIGGER exos_membership_reservations_touch BEFORE UPDATE ON public.exos_membership_reservations
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_membership_reservations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_membership_reservations_staff_read ON public.exos_membership_reservations;
CREATE POLICY exos_membership_reservations_staff_read ON public.exos_membership_reservations
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_membership_reservations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_membership_reservations TO authenticated;
GRANT ALL ON public.exos_membership_reservations TO service_role;
COMMENT ON TABLE public.exos_membership_reservations IS
  'Box-office membership sales: a place held 10 minutes, then completed (paid at the counter; the row is the record of the money taken), cancelled or expired. mig 20261105120000.';

-- Places taken: memberships of the product that are pending or live, plus
-- open reservations that haven't expired.
CREATE OR REPLACE FUNCTION public._exos_membership_capacity_used(p_product uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (SELECT count(*) FROM public.exos_fan_memberships m
           WHERE m.product_id = p_product AND (m.status = 'pending' OR public._exos_membership_benefits_live(m)))::int
       + (SELECT count(*) FROM public.exos_membership_reservations r
           WHERE r.product_id = p_product AND r.status = 'reserved' AND r.expires_at > now())::int
$$;
REVOKE ALL ON FUNCTION public._exos_membership_capacity_used(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_membership_capacity_used(uuid) TO service_role;

-- Places left (NULL: no capacity). exos-commerce asks before an online sale.
CREATE OR REPLACE FUNCTION public.exos_membership_capacity_left(p_product_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p.capacity IS NULL THEN NULL
              ELSE greatest(p.capacity - public._exos_membership_capacity_used(p.id), 0) END
    FROM public.exos_membership_products p WHERE p.id = p_product_id
$$;
REVOKE ALL ON FUNCTION public.exos_membership_capacity_left(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_capacity_left(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_membership_capacity_json(p_product uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('product_id', p.id, 'capacity', p.capacity,
           'used', public._exos_membership_capacity_used(p.id),
           'left', public.exos_membership_capacity_left(p.id))
    FROM public.exos_membership_products p WHERE p.id = p_product
$$;
REVOKE ALL ON FUNCTION public._exos_membership_capacity_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_membership_capacity_json(uuid) TO service_role;

-- Set (or clear, NULL) a product's capacity. Lower than what is taken is
-- allowed: nobody loses a membership, new sales stop until places free up.
CREATE OR REPLACE FUNCTION public._exos_membership_set_capacity(p_org uuid, p_product uuid, p_capacity integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_capacity IS NOT NULL AND (p_capacity < 1 OR p_capacity > 1000000) THEN
    RAISE EXCEPTION 'capacity must be 1 to 1000000, or null for no limit' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_membership_products SET capacity = p_capacity WHERE id = p_product AND org_id = p_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'membership product not found' USING ERRCODE = 'P0002'; END IF;
  RETURN public._exos_membership_capacity_json(p_product);
END $$;
REVOKE ALL ON FUNCTION public._exos_membership_set_capacity(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_membership_set_capacity(uuid, uuid, integer) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_membership_reservation_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', r.id, 'token', r.token, 'product_id', r.product_id,
           'state', CASE WHEN r.status = 'reserved' AND r.expires_at <= now() THEN 'expired' ELSE r.status END,
           'email', r.email, 'first_name', r.first_name, 'last_name', r.last_name,
           'payment_method', r.payment_method, 'payment_reference', r.payment_reference,
           'amount_cents', r.amount_cents, 'currency', r.currency, 'device_name', r.device_name,
           'membership_id', r.membership_id, 'expires_at', r.expires_at, 'completed_at', r.completed_at,
           'cancelled_at', r.cancelled_at, 'created_at', r.created_at)
    FROM public.exos_membership_reservations r WHERE r.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_membership_reservation_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_membership_reservation_json(uuid) TO service_role;

-- Reserve one place: { email, first_name?, last_name?, payment_method
-- ('cash' default | 'check' | 'external'), payment_reference?, device_name? }.
-- The product must be on sale (active, published). Refused (23505) when the
-- email already holds a live membership of it or an open reservation, and
-- (55000 sold out) when no place is left. Serialised per product.
CREATE OR REPLACE FUNCTION public._exos_membership_reserve(p_org uuid, p_product uuid, p_actor uuid, p_api_key uuid,
                                                           p_fields jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  f jsonb := coalesce(p_fields, '{}'::jsonb);
  pr public.exos_membership_products%ROWTYPE;
  v_bad text; v_email text; v_pm text; v_id uuid;
  v_first text; v_last text; v_ref text; v_dev text;
BEGIN
  IF jsonb_typeof(f) <> 'object' THEN RAISE EXCEPTION 'the fields must be a JSON object' USING ERRCODE = '22023'; END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(f) k
   WHERE k NOT IN ('email', 'first_name', 'last_name', 'payment_method', 'payment_reference', 'device_name')
   ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'unknown field: %', left(v_bad, 60) USING ERRCODE = '22023'; END IF;
  v_email := lower(btrim(coalesce(f->>'email', '')));
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 254 THEN
    RAISE EXCEPTION 'enter a valid email' USING ERRCODE = '22023';
  END IF;
  v_pm := coalesce(nullif(btrim(coalesce(f->>'payment_method', '')), ''), 'cash');
  IF v_pm NOT IN ('cash', 'check', 'external') THEN
    RAISE EXCEPTION 'payment_method must be cash, check or external' USING ERRCODE = '22023';
  END IF;
  v_first := nullif(btrim(coalesce(f->>'first_name', '')), '');
  v_last  := nullif(btrim(coalesce(f->>'last_name', '')), '');
  v_ref   := nullif(btrim(coalesce(f->>'payment_reference', '')), '');
  v_dev   := nullif(btrim(coalesce(f->>'device_name', '')), '');
  IF length(v_first) > 60 OR length(v_last) > 60 THEN
    RAISE EXCEPTION 'first_name and last_name are at most 60 characters' USING ERRCODE = '22023';
  END IF;
  IF length(v_ref) > 255 OR length(v_dev) > 255 THEN
    RAISE EXCEPTION 'payment_reference and device_name are at most 255 characters' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO pr FROM public.exos_membership_products WHERE id = p_product AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'membership product not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT pr.active OR pr.status <> 'published' THEN
    RAISE EXCEPTION 'this membership product is not on sale' USING ERRCODE = '55000';
  END IF;
  -- Reservations past their time are expired now (they no longer count).
  UPDATE public.exos_membership_reservations SET status = 'expired'
   WHERE product_id = pr.id AND status = 'reserved' AND expires_at <= now();
  IF EXISTS (SELECT 1 FROM public.exos_fan_memberships m
              WHERE m.product_id = pr.id AND lower(m.holder_email) = v_email
                AND (m.status = 'pending' OR public._exos_membership_benefits_live(m))) THEN
    RAISE EXCEPTION '% already has this membership', v_email USING ERRCODE = '23505';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_membership_reservations
              WHERE product_id = pr.id AND email = v_email AND status = 'reserved') THEN
    RAISE EXCEPTION '% already has an open reservation for this membership', v_email USING ERRCODE = '23505';
  END IF;
  IF pr.capacity IS NOT NULL AND public._exos_membership_capacity_used(pr.id) >= pr.capacity THEN
    RAISE EXCEPTION 'this membership is sold out' USING ERRCODE = '55000';
  END IF;
  INSERT INTO public.exos_membership_reservations (org_id, product_id, token, email, first_name, last_name,
    payment_method, payment_reference, amount_cents, currency, device_name, created_by, api_key_id, expires_at)
  VALUES (pr.org_id, pr.id, 'mbr_' || public._exos_b64url(extensions.gen_random_bytes(32)), v_email, v_first, v_last,
    v_pm, v_ref, pr.price_cents, pr.currency, v_dev, p_actor, p_api_key, now() + interval '10 minutes')
  RETURNING id INTO v_id;
  RETURN public._exos_membership_reservation_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_membership_reserve(uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_membership_reserve(uuid, uuid, uuid, uuid, jsonb) TO service_role;

-- Complete: the money is in hand. Issues the membership (a one-time term of
-- the product, source 'purchase'). Completing again answers the same
-- membership. A cancelled or expired reservation is refused (55000).
CREATE OR REPLACE FUNCTION public._exos_membership_reservation_complete(p_org uuid, p_product uuid, p_token text, p_actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r  public.exos_membership_reservations%ROWTYPE;
  pr public.exos_membership_products%ROWTYPE;
  v_end timestamptz; v_id uuid; v_name text;
BEGIN
  -- Product first, then the reservation: the same lock order as reserve.
  SELECT * INTO pr FROM public.exos_membership_products WHERE id = p_product AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'membership product not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO r FROM public.exos_membership_reservations
   WHERE token = p_token AND product_id = p_product AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'reservation not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status = 'completed' THEN
    RETURN jsonb_build_object('reservation', public._exos_membership_reservation_json(r.id),
                              'membership', public._exos_membership_admin_json(r.membership_id), 'replay', true);
  END IF;
  IF r.status = 'cancelled' THEN RAISE EXCEPTION 'this reservation was cancelled' USING ERRCODE = '55000'; END IF;
  IF r.status = 'expired' OR r.expires_at <= now() THEN
    UPDATE public.exos_membership_reservations SET status = 'expired' WHERE id = r.id AND status = 'reserved';
    RAISE EXCEPTION 'this reservation expired; reserve again' USING ERRCODE = '55000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_fan_memberships m
              WHERE m.product_id = pr.id AND lower(m.holder_email) = r.email
                AND (m.status = 'pending' OR public._exos_membership_benefits_live(m))) THEN
    RAISE EXCEPTION '% already has this membership', r.email USING ERRCODE = '23505';
  END IF;
  v_end := now() + CASE pr.billing WHEN 'month' THEN interval '1 month' WHEN 'year' THEN interval '1 year'
                                   ELSE make_interval(days => pr.duration_days) END;
  v_name := nullif(btrim(concat_ws(' ', r.first_name, r.last_name)), '');
  INSERT INTO public.exos_fan_memberships (org_id, product_id, product_name, billing, holder_uid, holder_email, status,
    current_period_start, current_period_end, benefits, source, member_name, staff_notes, issued_by)
  VALUES (pr.org_id, pr.id, pr.name, 'once', public._exos_confirmed_uid(r.email), r.email, 'active', now(), v_end,
    jsonb_build_object('discount_percent', pr.discount_percent, 'presale', pr.presale,
      'free_tickets_per_period', pr.free_tickets_per_period, 'guest_allowance', pr.guest_allowance,
      'household_seats', pr.household_seats,
      'term', CASE pr.billing WHEN 'month' THEN '1 month' WHEN 'year' THEN '1 year' ELSE pr.duration_days || ' days' END),
    'purchase', left(v_name, 120),
    left('Box office (' || r.payment_method || coalesce(', ' || r.payment_reference, '') || ')', 2000), p_actor)
  RETURNING id INTO v_id;
  UPDATE public.exos_membership_reservations
     SET status = 'completed', completed_at = now(), membership_id = v_id
   WHERE id = r.id;
  BEGIN
    PERFORM public.exos_enqueue_webhook(pr.org_id, 'membership.created', jsonb_build_object('membership_id', v_id,
      'product_id', pr.id, 'billing', 'once', 'source', 'box_office', 'current_period_end', v_end));
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN jsonb_build_object('reservation', public._exos_membership_reservation_json(r.id),
                            'membership', public._exos_membership_admin_json(v_id));
END $$;
REVOKE ALL ON FUNCTION public._exos_membership_reservation_complete(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_membership_reservation_complete(uuid, uuid, text, uuid) TO service_role;

-- Cancel (back out before the money is taken). Again: the same answer. A
-- completed one can't be cancelled (refund the membership instead).
CREATE OR REPLACE FUNCTION public._exos_membership_reservation_cancel(p_org uuid, p_product uuid, p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_membership_reservations%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_membership_reservations
   WHERE token = p_token AND product_id = p_product AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'reservation not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status = 'completed' THEN
    RAISE EXCEPTION 'this reservation is completed; it can''t be cancelled' USING ERRCODE = '55000';
  END IF;
  IF r.status = 'reserved' THEN
    UPDATE public.exos_membership_reservations
       SET status = CASE WHEN expires_at <= now() THEN 'expired' ELSE 'cancelled' END,
           cancelled_at = CASE WHEN expires_at <= now() THEN NULL ELSE now() END
     WHERE id = r.id;
  END IF;
  RETURN public._exos_membership_reservation_json(r.id);
END $$;
REVOKE ALL ON FUNCTION public._exos_membership_reservation_cancel(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_membership_reservation_cancel(uuid, uuid, text) TO service_role;

-- Dashboard wrappers (owner / manager of the product's organization).
CREATE OR REPLACE FUNCTION public._exos_membership_staff_org(p_product uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_membership_products WHERE id = p_product);
BEGIN
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'only an owner or manager can sell memberships at the box office' USING ERRCODE = '42501';
  END IF;
  RETURN v_org;
END $$;
REVOKE ALL ON FUNCTION public._exos_membership_staff_org(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_membership_reserve(p_product_id uuid, p_fields jsonb)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_membership_reserve(public._exos_membership_staff_org(p_product_id), p_product_id, auth.uid(), NULL, p_fields)
$$;
CREATE OR REPLACE FUNCTION public.exos_membership_reservation_complete(p_product_id uuid, p_token text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_membership_reservation_complete(public._exos_membership_staff_org(p_product_id), p_product_id, p_token, auth.uid())
$$;
CREATE OR REPLACE FUNCTION public.exos_membership_reservation_cancel(p_product_id uuid, p_token text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_membership_reservation_cancel(public._exos_membership_staff_org(p_product_id), p_product_id, p_token)
$$;
CREATE OR REPLACE FUNCTION public.exos_membership_set_capacity(p_product_id uuid, p_capacity integer)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_membership_set_capacity(public._exos_membership_staff_org(p_product_id), p_product_id, p_capacity)
$$;
REVOKE ALL ON FUNCTION public.exos_membership_reserve(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_membership_reservation_complete(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_membership_reservation_cancel(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_membership_set_capacity(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_membership_reserve(uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_membership_reservation_complete(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_membership_reservation_cancel(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_membership_set_capacity(uuid, integer) TO authenticated, service_role;

-- exos-api: the reservation routes and the capacity. commerce:write (reads:
-- commerce:read) and a key creator who is an owner or manager now; writes
-- are logged in exos_api_writes.
CREATE OR REPLACE FUNCTION public._exos_api_membership_box_office(p_org uuid, p_api_key uuid, p_action text,
                                                                  p_product uuid, p_token text, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor uuid; v_out jsonb; v_scope text;
BEGIN
  v_scope := CASE WHEN p_action = 'capacity.get' THEN 'commerce:read' ELSE 'commerce:write' END;
  IF p_action NOT IN ('reserve', 'complete', 'cancel', 'capacity.get', 'capacity.set') THEN
    RAISE EXCEPTION 'unknown action' USING ERRCODE = '22023';
  END IF;
  IF NOT public._exos_api_has_scope(public._exos_api_key_scopes(p_api_key), v_scope) THEN
    RAISE EXCEPTION 'the key lacks the % scope', v_scope USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_membership_products WHERE id = p_product AND org_id = p_org) THEN
    RAISE EXCEPTION 'membership product not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_action = 'capacity.get' THEN
    RETURN public._exos_membership_capacity_json(p_product);
  END IF;
  v_actor := public._exos_api_key_actor(p_org, p_api_key, ARRAY['owner', 'manager']);
  v_out := CASE p_action
    WHEN 'reserve' THEN public._exos_membership_reserve(p_org, p_product, v_actor, p_api_key, p_args)
    WHEN 'complete' THEN public._exos_membership_reservation_complete(p_org, p_product, p_token, v_actor)
    WHEN 'cancel' THEN public._exos_membership_reservation_cancel(p_org, p_product, p_token)
    ELSE public._exos_membership_set_capacity(p_org, p_product,
           CASE WHEN jsonb_typeof(p_args -> 'capacity') = 'number' THEN (p_args ->> 'capacity')::numeric::int END) END;
  INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, result)
  VALUES (p_org, p_api_key, v_actor, 'membership_reservation.' || replace(p_action, '.', '_'),
          left(coalesce(p_token, p_product::text), 255),
          CASE WHEN p_action = 'reserve' THEN v_out - 'token' ELSE v_out END);
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_membership_box_office(uuid, uuid, text, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_membership_box_office(uuid, uuid, text, uuid, text, jsonb) TO service_role;

-- ===========================================================================
-- 3. Team switching: a personal access token in another org of its user
-- ===========================================================================
-- Opt-in per token, chosen when it is made: a token made for org A never
-- starts working on org B later. Existing tokens are pinned (false).
ALTER TABLE public.exos_personal_tokens ADD COLUMN IF NOT EXISTS multi_org boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.exos_personal_tokens.multi_org IS
  'Set at creation only: the token may act in any org its user is an active member of (X-Exos-Org), at the role there. mig 20261105120000.';
GRANT SELECT (multi_org) ON public.exos_personal_tokens TO authenticated;

-- multi_org is fixed after the transaction that made the token.
CREATE OR REPLACE FUNCTION public.exos_tg_pat_multi_org_fixed()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.multi_org IS DISTINCT FROM OLD.multi_org AND OLD.created_at <> now() THEN
    RAISE EXCEPTION 'multi_org is chosen when the token is created; make a new token' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_pat_multi_org_fixed() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_personal_tokens_multi_org ON public.exos_personal_tokens;
CREATE TRIGGER exos_personal_tokens_multi_org BEFORE UPDATE OF multi_org ON public.exos_personal_tokens
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_pat_multi_org_fixed();

-- Create a token, choosing multi_org (no default, so a 4-argument call is
-- never ambiguous: it reaches the old function and makes a pinned token).
CREATE OR REPLACE FUNCTION public.exos_create_personal_token(p_org_id uuid, p_name text, p_scopes text[],
                                                             p_expires_days integer, p_multi_org boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  v := public.exos_create_personal_token(p_org_id, p_name, p_scopes, p_expires_days);
  IF coalesce(p_multi_org, false) THEN
    -- Recorded on the row itself (the pat.created audit row names the token).
    UPDATE public.exos_personal_tokens SET multi_org = true WHERE id = (v ->> 'id')::uuid;
  END IF;
  RETURN v || jsonb_build_object('multi_org', coalesce(p_multi_org, false));
END $$;
REVOKE ALL ON FUNCTION public.exos_create_personal_token(uuid, text, text[], integer, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_create_personal_token(uuid, text, text[], integer, boolean) TO authenticated;

-- exos_api_token_auth's answer for the org the X-Exos-Org header names.
-- The same org: unchanged. Another org: a personal access token made with
-- multi_org, its user an active member there, scopes narrowed to the role
-- there (and that org's role settings, mig 20261104180000).
-- { error: 'org_switch' } for an OAuth token, { error: 'token_pinned_to_org' }
-- for a pinned personal token, { error: 'not_member' } when the user isn't
-- (or is no longer) a member there.
CREATE OR REPLACE FUNCTION public.exos_api_token_auth_org(p_hash text, p_kind text, p_org uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb; v_role text; v_scopes text[];
BEGIN
  v := public.exos_api_token_auth(p_hash, p_kind);
  IF v IS NULL OR v ? 'error' OR p_org IS NULL OR (v ->> 'org_id')::uuid = p_org THEN
    RETURN v;
  END IF;
  IF p_kind <> 'pat' THEN
    RETURN jsonb_build_object('error', 'org_switch');
  END IF;
  IF NOT coalesce((SELECT multi_org FROM public.exos_personal_tokens WHERE id = (v ->> 'credential_id')::uuid), false) THEN
    RETURN jsonb_build_object('error', 'token_pinned_to_org');
  END IF;
  v_role := public._exos_member_role(p_org, (v ->> 'user_id')::uuid);
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('error', 'not_member');
  END IF;
  SELECT array_agg(x) INTO v_scopes FROM jsonb_array_elements_text(v -> 'token_scopes') x;
  RETURN v || jsonb_build_object('org_id', p_org, 'home_org_id', v ->> 'org_id', 'role', v_role,
    'scopes', to_jsonb(public._exos_scopes_for_role(coalesce(v_scopes, '{}'), v_role, p_org)));
END $$;
REVOKE ALL ON FUNCTION public.exos_api_token_auth_org(text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_token_auth_org(text, text, uuid) TO service_role;

-- ===========================================================================
-- 4. Staff shifts (clock in / out)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_staff_shifts (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role           text NOT NULL,
  event_id       uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  device_id      uuid REFERENCES public.exos_pos_devices (id) ON DELETE SET NULL,
  clock_in_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  clock_out_at   timestamptz,
  clock_in_note  text CHECK (clock_in_note IS NULL OR char_length(clock_in_note) <= 300),
  clock_out_note text CHECK (clock_out_note IS NULL OR char_length(clock_out_note) <= 300),
  -- An owner / manager closing a forgotten shift.
  closed_by      uuid,
  close_reason   text CHECK (close_reason IS NULL OR char_length(close_reason) BETWEEN 3 AND 300),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_staff_shifts_order_chk CHECK (clock_out_at IS NULL OR clock_out_at >= clock_in_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_staff_shifts_open_uq ON public.exos_staff_shifts (org_id, user_id)
  WHERE clock_out_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_staff_shifts_org_idx ON public.exos_staff_shifts (org_id, clock_in_at DESC);
DROP TRIGGER IF EXISTS exos_staff_shifts_touch ON public.exos_staff_shifts;
CREATE TRIGGER exos_staff_shifts_touch BEFORE UPDATE ON public.exos_staff_shifts
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_staff_shifts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_staff_shifts_read ON public.exos_staff_shifts;
CREATE POLICY exos_staff_shifts_read ON public.exos_staff_shifts
  FOR SELECT TO authenticated
  USING ((user_id = auth.uid() AND public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','content','scanner']))
         OR public.exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_staff_shifts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_staff_shifts TO authenticated;
GRANT ALL ON public.exos_staff_shifts TO service_role;
COMMENT ON TABLE public.exos_staff_shifts IS
  'Staff clock-in / clock-out, one open shift per member per org; written through exos_staff_clock_in / _out only. mig 20261105120000.';

CREATE OR REPLACE FUNCTION public._exos_staff_shift_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', s.id, 'user_id', s.user_id, 'email', u.email, 'role', s.role,
           'event_id', s.event_id, 'device_id', s.device_id, 'clock_in_at', s.clock_in_at, 'clock_out_at', s.clock_out_at,
           'minutes', floor(extract(epoch FROM coalesce(s.clock_out_at, now()) - s.clock_in_at) / 60)::int,
           'open', s.clock_out_at IS NULL, 'clock_in_note', s.clock_in_note, 'clock_out_note', s.clock_out_note,
           'closed_by', s.closed_by, 'close_reason', s.close_reason)
    FROM public.exos_staff_shifts s LEFT JOIN auth.users u ON u.id = s.user_id
   WHERE s.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_staff_shift_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_staff_shift_json(uuid) TO service_role;

-- Clock a member in: any active role. The event and device, when given,
-- must be the org's (a device: not retired). One open shift at a time.
CREATE OR REPLACE FUNCTION public._exos_staff_clock_in(p_org uuid, p_uid uuid, p_event uuid, p_device uuid, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_role text := public._exos_member_role(p_org, p_uid); v_id uuid;
BEGIN
  IF p_uid IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'only a member of the organization can clock in' USING ERRCODE = '42501';
  END IF;
  IF p_event IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_device IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_pos_devices
                                           WHERE id = p_device AND org_id = p_org AND status IN ('pending', 'active')) THEN
    RAISE EXCEPTION 'device not found' USING ERRCODE = 'P0002';
  END IF;
  IF length(btrim(coalesce(p_note, ''))) > 300 THEN
    RAISE EXCEPTION 'the note is at most 300 characters' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_staff_shifts (org_id, user_id, role, event_id, device_id, clock_in_note)
  VALUES (p_org, p_uid, v_role, p_event, p_device, nullif(btrim(coalesce(p_note, '')), ''))
  ON CONFLICT (org_id, user_id) WHERE clock_out_at IS NULL DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'already clocked in; clock out first' USING ERRCODE = '23505';
  END IF;
  RETURN public._exos_staff_shift_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_staff_clock_in(uuid, uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_staff_clock_in(uuid, uuid, uuid, uuid, text) TO service_role;

-- Clock out the member's open shift (a member who has since left can still
-- close their own shift).
CREATE OR REPLACE FUNCTION public._exos_staff_clock_out(p_org uuid, p_uid uuid, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  IF length(btrim(coalesce(p_note, ''))) > 300 THEN
    RAISE EXCEPTION 'the note is at most 300 characters' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_staff_shifts
     SET clock_out_at = greatest(clock_timestamp(), clock_in_at), clock_out_note = nullif(btrim(coalesce(p_note, '')), '')
   WHERE org_id = p_org AND user_id = p_uid AND clock_out_at IS NULL
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'not clocked in' USING ERRCODE = 'P0002'; END IF;
  RETURN public._exos_staff_shift_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_staff_clock_out(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_staff_clock_out(uuid, uuid, text) TO service_role;

-- The hours report: shifts that started in [from, to) (at most 92 days),
-- each member's total minutes (an open shift counts up to now).
CREATE OR REPLACE FUNCTION public._exos_staff_shift_report(p_org uuid, p_from timestamptz, p_to timestamptz)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_from timestamptz := coalesce(p_from, now() - interval '7 days'); v_to timestamptz := coalesce(p_to, now());
BEGIN
  IF v_to <= v_from OR v_to - v_from > interval '92 days' THEN
    RAISE EXCEPTION 'from must be before to, at most 92 days apart' USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object('from', v_from, 'to', v_to,
    'members', coalesce((
      SELECT jsonb_agg(jsonb_build_object('user_id', x.user_id, 'email', x.email, 'shifts', x.n, 'minutes', x.minutes,
                                          'open', x.open) ORDER BY x.minutes DESC, x.user_id)
        FROM (SELECT s.user_id, min(u.email) AS email, count(*) AS n,
                     sum(floor(extract(epoch FROM coalesce(s.clock_out_at, now()) - s.clock_in_at) / 60))::int AS minutes,
                     bool_or(s.clock_out_at IS NULL) AS open
                FROM public.exos_staff_shifts s LEFT JOIN auth.users u ON u.id = s.user_id
               WHERE s.org_id = p_org AND s.clock_in_at >= v_from AND s.clock_in_at < v_to
               GROUP BY s.user_id) x), '[]'::jsonb),
    'shifts', coalesce((
      SELECT jsonb_agg(public._exos_staff_shift_json(s.id) ORDER BY s.clock_in_at DESC, s.id)
        FROM public.exos_staff_shifts s
       WHERE s.org_id = p_org AND s.clock_in_at >= v_from AND s.clock_in_at < v_to), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public._exos_staff_shift_report(uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_staff_shift_report(uuid, timestamptz, timestamptz) TO service_role;

-- Signed in (the door phone, the dashboard).
CREATE OR REPLACE FUNCTION public.exos_staff_clock_in(p_org_id uuid, p_event_id uuid DEFAULT NULL,
                                                      p_device_id uuid DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_staff_clock_in(p_org_id, auth.uid(), p_event_id, p_device_id, p_note);
END $$;
CREATE OR REPLACE FUNCTION public.exos_staff_clock_out(p_org_id uuid, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_staff_clock_out(p_org_id, auth.uid(), p_note);
END $$;
-- Owner / manager: close a shift somebody forgot, at a time between its
-- start and now, with a reason (kept on the row).
CREATE OR REPLACE FUNCTION public.exos_staff_shift_close(p_shift_id uuid, p_clock_out_at timestamptz, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.exos_staff_shifts%ROWTYPE;
BEGIN
  SELECT * INTO s FROM public.exos_staff_shifts WHERE id = p_shift_id FOR UPDATE;
  IF s.id IS NULL OR auth.uid() IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(s.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'shift not found' USING ERRCODE = 'P0002';
  END IF;
  IF s.clock_out_at IS NOT NULL THEN RAISE EXCEPTION 'this shift is already closed' USING ERRCODE = '55000'; END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    RAISE EXCEPTION 'give a reason (3 characters or more)' USING ERRCODE = '22023';
  END IF;
  IF p_clock_out_at IS NULL OR p_clock_out_at < s.clock_in_at OR p_clock_out_at > now() THEN
    RAISE EXCEPTION 'the clock-out time must be between the clock-in and now' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_staff_shifts
     SET clock_out_at = p_clock_out_at, closed_by = auth.uid(), close_reason = left(btrim(p_reason), 300)
   WHERE id = s.id;
  RETURN public._exos_staff_shift_json(s.id);
END $$;
CREATE OR REPLACE FUNCTION public.exos_staff_shift_report(p_org_id uuid, p_from timestamptz DEFAULT NULL,
                                                          p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'only an owner or manager can read the hours report' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_staff_shift_report(p_org_id, p_from, p_to);
END $$;
REVOKE ALL ON FUNCTION public.exos_staff_clock_in(uuid, uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_staff_clock_out(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_staff_shift_close(uuid, timestamptz, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_staff_shift_report(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_staff_clock_in(uuid, uuid, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_staff_clock_out(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_staff_shift_close(uuid, timestamptz, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_staff_shift_report(uuid, timestamptz, timestamptz) TO authenticated, service_role;

-- ===========================================================================
-- 5. Tixel waitlist signups (inbound webhook)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_tixel_signups (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  payload_hash     text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  email            text NOT NULL CHECK (email = lower(email) AND char_length(email) BETWEEN 3 AND 254),
  name             text CHECK (name IS NULL OR char_length(name) <= 120),
  event_title      text CHECK (event_title IS NULL OR char_length(event_title) <= 300),
  event_href       text CHECK (event_href IS NULL OR char_length(event_href) <= 1000),
  matched_event_id uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  waitlist_id      uuid REFERENCES public.exos_waitlist (id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_tixel_signups_once UNIQUE (org_id, payload_hash)
);
CREATE INDEX IF NOT EXISTS exos_tixel_signups_org_idx ON public.exos_tixel_signups (org_id, created_at DESC);
ALTER TABLE public.exos_tixel_signups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_tixel_signups_staff_read ON public.exos_tixel_signups;
CREATE POLICY exos_tixel_signups_staff_read ON public.exos_tixel_signups
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_tixel_signups FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_tixel_signups TO authenticated;
GRANT ALL ON public.exos_tixel_signups TO service_role;
COMMENT ON TABLE public.exos_tixel_signups IS
  'Tixel fan-data webhook WAITLIST signups (exos-tixel-webhook), matched to the org''s event by title when exactly one fits. mig 20261105120000.';

-- One delivery (exos-tixel-webhook has checked the secret and picked the
-- org). { recorded: false } for actions other than WAITLIST; else the
-- signup, put on the waitlist of the org's one upcoming published event
-- whose name is the Tixel event title (case-insensitive), if there is
-- exactly one. Same payload again: the first answer (replay: true).
CREATE OR REPLACE FUNCTION public._exos_tixel_ingest(p_org uuid, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_hash  text;
  v_email text;
  v_name  text;
  v_title text;
  v_href  text;
  v_event uuid;
  v_n     int;
  v_wl    uuid;
  v_id    uuid;
  s       public.exos_tixel_signups%ROWTYPE;
BEGIN
  IF p_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org) THEN
    RAISE EXCEPTION 'organization not found' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'the body must be a JSON object' USING ERRCODE = '22023';
  END IF;
  IF upper(coalesce(p_payload ->> 'action', '')) <> 'WAITLIST' THEN
    RETURN jsonb_build_object('recorded', false, 'action', left(coalesce(p_payload ->> 'action', ''), 40));
  END IF;
  v_email := lower(btrim(coalesce(p_payload #>> '{user,email}', '')));
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 254 THEN
    RAISE EXCEPTION 'Email is required' USING ERRCODE = '22023';
  END IF;
  v_hash := encode(extensions.digest(p_payload::text, 'sha256'), 'hex');
  SELECT * INTO s FROM public.exos_tixel_signups WHERE org_id = p_org AND payload_hash = v_hash;
  IF s.id IS NOT NULL THEN
    RETURN jsonb_build_object('recorded', true, 'id', s.id, 'event_id', s.matched_event_id,
                              'waitlist_id', s.waitlist_id, 'replay', true);
  END IF;
  v_name := left(nullif(btrim(concat_ws(' ', btrim(p_payload #>> '{user,firstName}'), btrim(p_payload #>> '{user,lastName}'))), ''), 120);
  v_title := left(nullif(btrim(coalesce(p_payload #>> '{metadata,eventTitle}', '')), ''), 300);
  v_href := left(nullif(btrim(coalesce(p_payload #>> '{metadata,href}', '')), ''), 1000);
  IF v_title IS NOT NULL THEN
    SELECT count(*), min(e.id::text)::uuid INTO v_n, v_event
      FROM public.exos_events e
     WHERE e.org_id = p_org AND e.status = 'published' AND lower(btrim(e.name)) = lower(v_title)
       AND coalesce(e.ends_at, e.starts_at, now()) >= now();
    IF v_n <> 1 THEN v_event := NULL; END IF;
  END IF;
  IF v_event IS NOT NULL THEN
    INSERT INTO public.exos_waitlist (event_id, email, name, quantity, status, meta)
    VALUES (v_event, v_email, v_name, 1, 'waiting', jsonb_build_object('source', 'tixel', 'href', v_href))
    ON CONFLICT (event_id, email) WHERE tier_id IS NULL DO NOTHING
    RETURNING id INTO v_wl;
    IF v_wl IS NULL THEN
      SELECT id INTO v_wl FROM public.exos_waitlist WHERE event_id = v_event AND email = v_email AND tier_id IS NULL;
    END IF;
  END IF;
  INSERT INTO public.exos_tixel_signups (org_id, payload_hash, email, name, event_title, event_href, matched_event_id, waitlist_id)
  VALUES (p_org, v_hash, v_email, v_name, v_title, v_href, v_event, v_wl)
  ON CONFLICT (org_id, payload_hash) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT * INTO s FROM public.exos_tixel_signups WHERE org_id = p_org AND payload_hash = v_hash;
    RETURN jsonb_build_object('recorded', true, 'id', s.id, 'event_id', s.matched_event_id,
                              'waitlist_id', s.waitlist_id, 'replay', true);
  END IF;
  RETURN jsonb_build_object('recorded', true, 'id', v_id, 'event_id', v_event, 'waitlist_id', v_wl);
END $$;
REVOKE ALL ON FUNCTION public._exos_tixel_ingest(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tixel_ingest(uuid, jsonb) TO service_role;

-- ===========================================================================
-- 6. Tagged items: move an assignment to another tag
-- ===========================================================================
-- p_tag_id, or p_tag_name (found, or made, with the item's type as scope,
-- as _exos_tag_apply does). The tag must be the org's and fit the item's
-- type. Already tagged with it: 23505. The same tag: unchanged.
CREATE OR REPLACE FUNCTION public._exos_tagged_item_retag(p_org_id uuid, p_item_id uuid, p_tag_id uuid, p_tag_name text,
                                                          p_actor uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  i public.exos_tagged_items%ROWTYPE;
  v_tag uuid := p_tag_id;
  v_scope text;
  v_name text := btrim(coalesce(p_tag_name, ''));
BEGIN
  SELECT * INTO i FROM public.exos_tagged_items WHERE id = p_item_id AND org_id = p_org_id FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'exos_tags: tagged item not found' USING ERRCODE = 'P0002'; END IF;
  IF v_tag IS NULL THEN
    IF v_name = '' THEN RAISE EXCEPTION 'exos_tags: give a tag id or a tag name' USING ERRCODE = '22023'; END IF;
    SELECT t.id INTO v_tag FROM public.exos_tags t
     WHERE t.org_id = p_org_id AND lower(t.name) = lower(v_name) AND (t.scope IS NULL OR t.scope = i.taggable_type)
     ORDER BY (t.scope IS NULL) LIMIT 1;
    IF v_tag IS NULL THEN
      v_tag := (public._exos_tag_save(p_org_id, NULL, jsonb_build_object('name', v_name, 'scope', i.taggable_type), p_actor)->>'id')::uuid;
    END IF;
  ELSE
    SELECT scope INTO v_scope FROM public.exos_tags WHERE id = v_tag AND org_id = p_org_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_tags: tag not found' USING ERRCODE = 'P0002'; END IF;
    IF v_scope IS NOT NULL AND v_scope <> i.taggable_type THEN
      RAISE EXCEPTION 'exos_tags: that tag is for %s', v_scope USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_tag <> i.tag_id THEN
    IF EXISTS (SELECT 1 FROM public.exos_tagged_items
                WHERE tag_id = v_tag AND taggable_type = i.taggable_type AND taggable_id = i.taggable_id) THEN
      RAISE EXCEPTION 'exos_tags: the record already has that tag' USING ERRCODE = '23505';
    END IF;
    UPDATE public.exos_tagged_items SET tag_id = v_tag WHERE id = i.id;
  END IF;
  RETURN jsonb_build_object('id', i.id, 'tag_id', v_tag, 'taggable_type', i.taggable_type, 'taggable_id', i.taggable_id,
                            'created_at', i.created_at, 'changed', v_tag <> i.tag_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_tagged_item_retag(uuid, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tagged_item_retag(uuid, uuid, uuid, text, uuid) TO service_role;
