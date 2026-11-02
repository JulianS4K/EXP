-- ============================================================================
-- Migration 20261102140000 — Exos: order and ticket edits, receipt resends,
-- whole-order check-out, guest-list import preview, event and fan
-- recommendations
--
-- Touches:  C: TABLE exos_order_details (new: buyer name / phone / notes)
--              TABLE exos_order_edits (new: the audit of everything below)
--              TABLE exos_order_settings (new: per-org receipt rules)
--              FUNCTION _exos_oe_order_json, _exos_oe_audit, _exos_oe_key_id,
--                       _exos_oe_settings (new, internal)
--              FUNCTION exos_order_update, exos_order_send_receipt,
--                       exos_order_check_out, exos_ticket_update,
--                       exos_org_orders, exos_order_tickets, exos_order_edit_log,
--                       exos_order_settings_get, exos_order_settings_save
--                       (new, signed-in staff)
--              FUNCTION exos_api_order_write (new, service_role: the API's
--                       writes for these, run as the key's creator)
--              FUNCTION _exos_guest_list_preview (new, service_role),
--                       exos_guest_list_preview (new, signed-in staff)
--              FUNCTION _exos_rec_score, _exos_rec_fan_score,
--                       _exos_rec_event_keys, _exos_rec_public, _exos_rec_rank
--                       (new, internal)
--              FUNCTION _exos_rec_similar_events, _exos_rec_fan_events,
--                       _exos_rec_event_fans (new, service_role)
--              FUNCTION exos_event_similar_events, exos_fan_event_recommendations,
--                       exos_event_fan_recommendations (new, signed-in staff)
--           R: exos_api_keys, exos_org_memberships, exos_api_writes, exos_events,
--              exos_checkout_sessions, exos_tickets, exos_event_checkins,
--              exos_checkin_lists, exos_guest_lists, exos_guest_list_entries,
--              exos_event_lineup, exos_artists, exos_tagged_items, exos_tags,
--              exos_fans, exos_orgs, exos_mail (insert: the receipt)
--           Calls (unchanged): exos_check_in_ticket, exos_receipt_html,
--              exos_mail_escape, exos_has_org_role, exos_is_admin,
--              exos_venue_key, _exos_door_code, _exos_fan_email_list
-- Pre-reqs: 20261031110000 (exos_api_writes, the core API), 20261031120000
--           (fans, tags), 20261030110000 (artists, lineups), 20260929140000
--           (door lists, exits), 20261013090000 (door imports), 20260929030000
--           (exos_receipt_html)
--
-- Orders and tickets (Opendate: PUT orders/:id, POST orders/:id/send_receipt,
-- POST orders/:id/check_out, PUT tickets/:barcode):
--   * An order edit changes the buyer's contact details only: first / last
--     name, phone and notes (exos_order_details, one row per order) and the
--     contact email (exos_checkout_sessions.buyer_email). Never a price, a
--     quantity, a ticket, its holder or its barcode: any other field is
--     refused (22023). The tickets keep their own buyer_email, which is what
--     purchase limits count, so an edit can't free a buyer's limit, and
--     invoices stay as issued. Owners and managers.
--   * A receipt resend mails the order's receipt (exos_receipt_html: amount,
--     lines, the all-in note) as a 'ticket-issued' mail through the normal
--     outbox (exos_mail, exos-mail-drain). It never carries claim links, so
--     sending it elsewhere can't hand tickets over. Any address other than the
--     one the order was bought with (exos_order_details.original_email, kept
--     from the first edit) is an override, so editing the contact email
--     can't redirect receipts. Per order at most
--     exos_order_settings.receipt_resends_per_hour (default 3) an hour, and
--     10 a day (54000). Another address than the one on file only when the
--     org has switched receipt_override_email on (owner only); otherwise the
--     email on file. Owners and managers.
--   * Order check-out records an exit for every ticket of the order that is
--     inside on a re-entry list (the last scan there was an entry), through
--     the door's own exos_check_in_ticket(direction 'exit'). A ticket already
--     out answers 'not-inside' and records nothing, so a second call changes
--     nothing (idempotent); the ticket rows are locked in id order first, so
--     two concurrent calls can't both record an exit. Tickets the order no
--     longer holds (transferred away) are skipped. Exits need a re-entry list
--     (the implicit list has none: 'exit-not-allowed'), as at the door. Owners
--     and managers (a typed exit is a door override).
--   * A ticket edit sets the attendee name (staff can, unlike the holder-only
--     exos_set_ticket_attendee). Changing who holds a ticket is a transfer:
--     the barcode secret rotates on a transfer and the transfer rules apply,
--     so an email other than the holder's is refused (55000) with a pointer to
--     the transfer flow. Never on a ticket in transfer or voided.
--   * Every change is a row in exos_order_edits (who, which key, before and
--     after); a no-op writes nothing. The API's writes also go to
--     exos_api_writes (idempotency, the write log) via exos_api_order_write,
--     which runs as the key's creator exactly like exos_api_write.
--
-- Guest list preview (Opendate: POST guest_list_preview): the rows of an
-- import (pasted names, CSV or JSON, parsed by the edge function with the
-- Door import parser) checked the way exos_import_guests would, writing
-- nothing: missing names, codes too long, malformed emails (dropped on
-- import), too many plus-ones, duplicates of a guest already on the event or
-- earlier in the file, and the capacity impact (the list's cap; the event's
-- capacity when the list counts toward it).
--
-- Recommendations (Opendate: GET confirms/:id/similars, confirms/recommendations,
-- confirms/:id/fans/recommendations): a small, explainable score. Signals:
-- shared artists (the lineup, matched by canonical artist or name), the same
-- venue (venue record or venue key), the same series, shared genres (the
-- lineup's artists), shared tags (canonical tag or name), date proximity,
-- and co-purchases (buyers of both events). Weights (src/lib/recommendations.ts
-- mirrors them): artist 50 each (max 3), venue 40, series 30, genre 15 each
-- (max 4), tag 10 each (max 5), co-buyer 5 each (max 10), plus up to 20 for
-- date proximity, which only counts when another signal matched. Ties: the
-- sooner event, then id.
--   Privacy: a recommended event is always public: published, not noindex,
--   not started yet (cancelled and drafts are never candidates, in the org or
--   outside it). Other orgs' events only when the caller asks (scope 'all'),
--   and then only their public fields. Co-purchases are counted only between
--   events of the caller's own org, and only as a number; no buyer is ever
--   named. A fan's history is their purchases from this org only, and only
--   events they hold from this org are left out (holdings elsewhere never
--   change an answer). Fan
--   recommendations list only the org's own fans who are on its email list
--   (they opted in themselves) and hold no ticket for the event.
--
-- Additive: new tables and functions only. Re-run safe. D4 authors; applying
-- to prod is operator-gated.
-- ============================================================================

-- 1. Tables -------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.exos_order_details (
  session_id  text PRIMARY KEY REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  first_name  text CHECK (first_name IS NULL OR char_length(first_name) BETWEEN 1 AND 60),
  last_name   text CHECK (last_name IS NULL OR char_length(last_name) BETWEEN 1 AND 60),
  phone       text CHECK (phone IS NULL OR phone ~ '^[0-9+() .-]{3,32}$'),
  notes       text CHECK (notes IS NULL OR char_length(notes) BETWEEN 1 AND 1000),
  -- The address the order was bought with, kept from the first edit on: a
  -- receipt anywhere else is an override (exos_order_send_receipt).
  original_email text CHECK (original_email IS NULL OR char_length(original_email) <= 320),
  updated_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_order_details ADD COLUMN IF NOT EXISTS original_email text
  CHECK (original_email IS NULL OR char_length(original_email) <= 320);
CREATE INDEX IF NOT EXISTS exos_order_details_org_idx ON public.exos_order_details (org_id);
DROP TRIGGER IF EXISTS exos_order_details_touch ON public.exos_order_details;
CREATE TRIGGER exos_order_details_touch BEFORE UPDATE ON public.exos_order_details
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_order_details ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_order_details_sel ON public.exos_order_details;
CREATE POLICY exos_order_details_sel ON public.exos_order_details FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
REVOKE ALL ON public.exos_order_details FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_order_details TO authenticated;
GRANT ALL ON public.exos_order_details TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_order_edits (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  session_id  text NOT NULL CHECK (char_length(session_id) <= 255),
  ticket_id   uuid,
  action      text NOT NULL CHECK (action IN ('order.update', 'order.receipt', 'order.check_out', 'ticket.update')),
  actor       uuid,
  api_key_id  uuid,
  changes     jsonb NOT NULL DEFAULT '{}'::jsonb
              CHECK (jsonb_typeof(changes) = 'object' AND octet_length(changes::text) <= 20000),
  mail_id     uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_order_edits_org_idx ON public.exos_order_edits (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_order_edits_session_idx ON public.exos_order_edits (session_id, action, created_at DESC);
DROP TRIGGER IF EXISTS exos_order_edits_touch ON public.exos_order_edits;
CREATE TRIGGER exos_order_edits_touch BEFORE UPDATE ON public.exos_order_edits
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_order_edits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_order_edits_sel ON public.exos_order_edits;
CREATE POLICY exos_order_edits_sel ON public.exos_order_edits FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
REVOKE ALL ON public.exos_order_edits FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_order_edits TO authenticated;
GRANT ALL ON public.exos_order_edits TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_order_settings (
  org_id                   uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  receipt_override_email   boolean NOT NULL DEFAULT false,
  receipt_resends_per_hour integer NOT NULL DEFAULT 3 CHECK (receipt_resends_per_hour BETWEEN 1 AND 10),
  updated_by               uuid,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS exos_order_settings_touch ON public.exos_order_settings;
CREATE TRIGGER exos_order_settings_touch BEFORE UPDATE ON public.exos_order_settings
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_order_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_order_settings_sel ON public.exos_order_settings;
CREATE POLICY exos_order_settings_sel ON public.exos_order_settings FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
REVOKE ALL ON public.exos_order_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_order_settings TO authenticated;
GRANT ALL ON public.exos_order_settings TO service_role;

-- 2. Internal helpers (no client grant) ------------------------------------------

-- The order as the API and the dashboard show it (never a payment id).
CREATE OR REPLACE FUNCTION public._exos_oe_order_json(p_session_id text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', s.session_id, 'session_id', s.session_id, 'event_id', s.event_id, 'status', s.status,
    'quantity', s.quantity, 'amount_cents', s.amount_cents, 'currency', s.currency,
    'email', s.buyer_email, 'first_name', d.first_name, 'last_name', d.last_name,
    'phone_number', d.phone, 'notes', d.notes, 'created_at', s.created_at, 'fulfilled_at', s.fulfilled_at,
    'details_updated_at', d.updated_at)
    FROM public.exos_checkout_sessions s
    LEFT JOIN public.exos_order_details d ON d.session_id = s.session_id
   WHERE s.session_id = p_session_id
$$;
REVOKE ALL ON FUNCTION public._exos_oe_order_json(text) FROM PUBLIC, anon, authenticated;

-- The API key a write came through (exos_api_order_write puts it in the
-- request's claims; a dashboard request has none).
CREATE OR REPLACE FUNCTION public._exos_oe_key_id()
RETURNS uuid
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v text := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'exos_api_key_id';
BEGIN
  RETURN CASE WHEN v ~* '^[0-9a-f-]{36}$' THEN v::uuid END;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_oe_key_id() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_oe_audit(
  p_org uuid, p_session text, p_ticket uuid, p_action text, p_changes jsonb, p_mail uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  INSERT INTO public.exos_order_edits (org_id, session_id, ticket_id, action, actor, api_key_id, changes, mail_id)
  VALUES (p_org, p_session, p_ticket, p_action, auth.uid(), public._exos_oe_key_id(), coalesce(p_changes, '{}'), p_mail)
  RETURNING id
$$;
REVOKE ALL ON FUNCTION public._exos_oe_audit(uuid, text, uuid, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;

-- The org's receipt rules (defaults when it never saved any).
CREATE OR REPLACE FUNCTION public._exos_oe_settings(p_org uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'receipt_override_email', coalesce((SELECT s.receipt_override_email FROM public.exos_order_settings s WHERE s.org_id = p_org), false),
    'receipt_resends_per_hour', coalesce((SELECT s.receipt_resends_per_hour FROM public.exos_order_settings s WHERE s.org_id = p_org), 3),
    'receipt_resends_per_day', 10)
$$;
REVOKE ALL ON FUNCTION public._exos_oe_settings(uuid) FROM PUBLIC, anon, authenticated;

-- 3. Staff writes (signed in; the API calls these as the key's creator) -----------

-- Buyer details. p_fields: first_name, last_name, email, phone (phone_number),
-- notes; a null / '' clears a field (not the email). Anything else: 22023.
CREATE OR REPLACE FUNCTION public.exos_order_update(p_session_id text, p_fields jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s        public.exos_checkout_sessions%ROWTYPE;
  d        public.exos_order_details%ROWTYPE;
  f        jsonb := coalesce(p_fields, '{}'::jsonb);
  k        text;
  v_first  text;
  v_last   text;
  v_phone  text;
  v_notes  text;
  v_email  text;
  v_chg    jsonb := '{}'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_order_update: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(f) <> 'object' THEN
    RAISE EXCEPTION 'exos_order_update: fields must be an object' USING ERRCODE = '22023';
  END IF;
  FOR k IN SELECT jsonb_object_keys(f) LOOP
    IF k NOT IN ('first_name', 'last_name', 'email', 'phone', 'phone_number', 'notes') THEN
      RAISE EXCEPTION 'exos_order_update: % can''t be changed on an order (buyer name, email, phone and notes only)', k
        USING ERRCODE = '22023';
    END IF;
  END LOOP;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_order_update: order not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(s.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_order_update: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF s.status IN ('pending', 'expired') THEN
    RAISE EXCEPTION 'exos_order_update: the order isn''t placed yet' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO d FROM public.exos_order_details WHERE session_id = p_session_id;

  v_first := CASE WHEN f ? 'first_name' THEN nullif(btrim(regexp_replace(coalesce(f ->> 'first_name', ''), '\s+', ' ', 'g')), '') ELSE d.first_name END;
  v_last  := CASE WHEN f ? 'last_name' THEN nullif(btrim(regexp_replace(coalesce(f ->> 'last_name', ''), '\s+', ' ', 'g')), '') ELSE d.last_name END;
  v_phone := CASE WHEN f ? 'phone' OR f ? 'phone_number'
                  THEN nullif(btrim(coalesce(f ->> 'phone', f ->> 'phone_number', '')), '') ELSE d.phone END;
  v_notes := CASE WHEN f ? 'notes' THEN nullif(btrim(coalesce(f ->> 'notes', '')), '') ELSE d.notes END;
  IF char_length(v_first) > 60 OR char_length(v_last) > 60 THEN
    RAISE EXCEPTION 'exos_order_update: names are at most 60 characters' USING ERRCODE = '22023';
  END IF;
  IF v_phone IS NOT NULL AND v_phone !~ '^[0-9+() .-]{3,32}$' THEN
    RAISE EXCEPTION 'exos_order_update: phone is not a phone number' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_notes) > 1000 THEN
    RAISE EXCEPTION 'exos_order_update: notes are at most 1000 characters' USING ERRCODE = '22023';
  END IF;
  v_email := s.buyer_email;
  IF f ? 'email' THEN
    v_email := lower(btrim(coalesce(f ->> 'email', '')));
    IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR char_length(v_email) > 254 THEN
      RAISE EXCEPTION 'exos_order_update: email is not an email address' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_first IS DISTINCT FROM d.first_name THEN v_chg := v_chg || jsonb_build_object('first_name', jsonb_build_object('from', d.first_name, 'to', v_first)); END IF;
  IF v_last IS DISTINCT FROM d.last_name THEN v_chg := v_chg || jsonb_build_object('last_name', jsonb_build_object('from', d.last_name, 'to', v_last)); END IF;
  IF v_phone IS DISTINCT FROM d.phone THEN v_chg := v_chg || jsonb_build_object('phone', jsonb_build_object('from', d.phone, 'to', v_phone)); END IF;
  IF v_notes IS DISTINCT FROM d.notes THEN v_chg := v_chg || jsonb_build_object('notes', jsonb_build_object('from', d.notes, 'to', v_notes)); END IF;
  IF v_email IS DISTINCT FROM s.buyer_email THEN v_chg := v_chg || jsonb_build_object('email', jsonb_build_object('from', s.buyer_email, 'to', v_email)); END IF;

  IF v_chg <> '{}'::jsonb THEN
    -- original_email: set once (the buyer's address before any edit), never updated.
    INSERT INTO public.exos_order_details (session_id, org_id, first_name, last_name, phone, notes, updated_by, original_email)
    VALUES (s.session_id, s.org_id, v_first, v_last, v_phone, v_notes, auth.uid(), lower(btrim(s.buyer_email)))
    ON CONFLICT (session_id) DO UPDATE
      SET first_name = EXCLUDED.first_name, last_name = EXCLUDED.last_name, phone = EXCLUDED.phone,
          notes = EXCLUDED.notes, updated_by = EXCLUDED.updated_by,
          original_email = coalesce(public.exos_order_details.original_email, EXCLUDED.original_email);
    IF v_chg ? 'email' THEN
      -- The contact address only: tickets keep theirs (purchase limits), invoices stay as issued.
      UPDATE public.exos_checkout_sessions SET buyer_email = v_email WHERE session_id = s.session_id;
    END IF;
    PERFORM public._exos_oe_audit(s.org_id, s.session_id, NULL, 'order.update', v_chg);
  END IF;
  RETURN public._exos_oe_order_json(s.session_id) || jsonb_build_object('changed', v_chg <> '{}'::jsonb,
           'changed_fields', (SELECT coalesce(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM jsonb_object_keys(v_chg) x));
END $$;
REVOKE ALL ON FUNCTION public.exos_order_update(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_update(text, jsonb) TO authenticated, service_role;

-- Resend the receipt. p_email: another address (only when the org allows it).
CREATE OR REPLACE FUNCTION public.exos_order_send_receipt(p_session_id text, p_email text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s        public.exos_checkout_sessions%ROWTYPE;
  v_set    jsonb;
  v_to     text;
  v_over   boolean := false;
  v_orig   text;
  v_hour   int;
  v_day    int;
  v_name   text;
  v_html   text;
  v_mail   uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_order_send_receipt: not authenticated' USING ERRCODE = '42501';
  END IF;
  -- The row lock serializes resends of one order (the rate limit below).
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_order_send_receipt: order not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(s.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_order_send_receipt: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF s.status NOT IN ('fulfilled', 'partially_refunded', 'refunded') THEN
    RAISE EXCEPTION 'exos_order_send_receipt: only a completed order has a receipt' USING ERRCODE = '55000';
  END IF;
  v_set := public._exos_oe_settings(s.org_id);
  -- The address the order was bought with (an edit can't move receipts:
  -- anything else is an override, allowed only when the org permits it).
  SELECT lower(btrim(coalesce(d.original_email, s.buyer_email, ''))) INTO v_orig
    FROM (SELECT 1) one LEFT JOIN public.exos_order_details d ON d.session_id = s.session_id;
  v_to := coalesce(nullif(lower(btrim(coalesce(p_email, ''))), ''), lower(btrim(coalesce(s.buyer_email, ''))));
  IF v_to <> v_orig THEN
    IF (v_set ->> 'receipt_override_email')::boolean THEN
      v_over := true;
    ELSIF nullif(btrim(coalesce(p_email, '')), '') IS NOT NULL THEN
      RAISE EXCEPTION 'exos_order_send_receipt: this organization sends receipts only to the email the order was placed with'
        USING ERRCODE = '42501';
    ELSE
      -- The contact email was edited and overrides are off: the original address.
      v_to := v_orig;
    END IF;
  END IF;
  IF v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR char_length(v_to) > 254 THEN
    RAISE EXCEPTION 'exos_order_send_receipt: no valid email to send to' USING ERRCODE = '22023';
  END IF;
  SELECT count(*) FILTER (WHERE e.created_at > now() - interval '1 hour'), count(*)
    INTO v_hour, v_day
    FROM public.exos_order_edits e
   WHERE e.session_id = s.session_id AND e.action = 'order.receipt' AND e.created_at > now() - interval '1 day';
  IF v_hour >= (v_set ->> 'receipt_resends_per_hour')::int OR v_day >= 10 THEN
    RAISE EXCEPTION 'exos_order_send_receipt: this order''s receipt was sent too often; try again later'
      USING ERRCODE = '54000';
  END IF;

  SELECT name INTO v_name FROM public.exos_events WHERE id = s.event_id;
  v_name := public.exos_mail_escape(coalesce(v_name, 'your event'));
  -- Receipt only: never claim links (an address other than the buyer's must
  -- not be able to take the tickets).
  v_html := '<p>Here is your receipt for <strong>' || v_name || '</strong>.</p>' ||
            coalesce(nullif(public.exos_receipt_html(s.session_id), ''),
                     '<p>No payment was taken for this order. Order reference: ' ||
                     public.exos_mail_escape(s.session_id) || '.</p>');
  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES ('ticket-issued', v_to, left('Your receipt for ' || v_name, 200), v_html, auth.uid(), 'pending')
  RETURNING id INTO v_mail;
  PERFORM public._exos_oe_audit(s.org_id, s.session_id, NULL, 'order.receipt',
    jsonb_build_object('to', v_to, 'override', v_over), v_mail);
  RETURN jsonb_build_object('order_id', s.session_id, 'sent', true, 'to', v_to, 'override', v_over,
                            'mail_id', v_mail, 'resends_left_this_hour',
                            greatest(0, (v_set ->> 'receipt_resends_per_hour')::int - v_hour - 1));
END $$;
REVOKE ALL ON FUNCTION public.exos_order_send_receipt(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_send_receipt(text, text) TO authenticated, service_role;

-- Check every ticket of the order out at the door (re-entry lists).
CREATE OR REPLACE FUNCTION public.exos_order_check_out(
  p_session_id text, p_list_id uuid DEFAULT NULL, p_reason text DEFAULT NULL, p_device text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s        public.exos_checkout_sessions%ROWTYPE;
  t        record;
  v_list   uuid;
  v_res    jsonb;
  v_rows   jsonb := '[]'::jsonb;
  v_out    int := 0;
  v_reason text := coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'order check-out');
  v_any    boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_order_check_out: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_order_check_out: order not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(s.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_order_check_out: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_reason) < 3 THEN v_reason := 'order check-out'; END IF;
  IF p_list_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_checkin_lists l WHERE l.id = p_list_id AND l.event_id = s.event_id) THEN
    RAISE EXCEPTION 'exos_order_check_out: check-in list not found' USING ERRCODE = 'P0002';
  END IF;
  -- Lock the order's tickets in id order: a concurrent check-out waits here,
  -- then sees the exits this one recorded.
  PERFORM 1 FROM public.exos_tickets tk WHERE tk.order_ref = s.session_id AND tk.org_id = s.org_id
   ORDER BY tk.id FOR UPDATE;
  FOR t IN
    SELECT tk.id, tk.event_id, tk.status, tk.owner_id, tk.transfer_id
      FROM public.exos_tickets tk
     WHERE tk.order_ref = s.session_id AND tk.org_id = s.org_id
     ORDER BY tk.created_at, tk.id
  LOOP
    IF t.transfer_id IS NOT NULL AND t.owner_id IS DISTINCT FROM s.buyer_uid THEN
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('ticket_id', t.id, 'ok', true, 'reason', 'not-held', 'changed', false));
      CONTINUE;
    END IF;
    IF t.status NOT IN ('active', 'used') THEN
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('ticket_id', t.id, 'ok', true, 'reason', t.status, 'changed', false));
      CONTINUE;
    END IF;
    v_any := false;
    -- Every re-entry list (or the one asked for) where the ticket is inside now.
    FOR v_list IN
      SELECT l.id FROM public.exos_checkin_lists l
       WHERE l.event_id = t.event_id AND l.allow_reentry AND (p_list_id IS NULL OR l.id = p_list_id)
         AND (SELECT c.direction FROM public.exos_event_checkins c
               WHERE c.ticket_id = t.id AND c.list_id = l.id
               ORDER BY coalesce(c.offline_scanned_at, c.scanned_at) DESC, c.scanned_at DESC LIMIT 1) = 'entry'
       ORDER BY l.sort_order, l.id
    LOOP
      v_any := true;
      v_res := public.exos_check_in_ticket(t.id, 'manual', 'manual', NULL, t.event_id, v_reason, NULL,
                                           left(coalesce(nullif(btrim(coalesce(p_device, '')), ''), 'order check-out'), 60),
                                           v_list, 'exit');
      IF (v_res ->> 'ok')::boolean AND v_res ->> 'reason' = 'checked-out' THEN v_out := v_out + 1; END IF;
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('ticket_id', t.id, 'list_id', v_list,
                  'changed', (v_res ->> 'reason') = 'checked-out') || v_res);
    END LOOP;
    IF NOT v_any THEN
      -- Already out (or never in): nothing to record. In on the implicit
      -- list (no re-entry): the door can't check it out either.
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('ticket_id', t.id, 'changed', false) ||
        CASE WHEN t.status = 'used' AND NOT EXISTS (
                    SELECT 1 FROM public.exos_event_checkins c
                      JOIN public.exos_checkin_lists l ON l.id = c.list_id AND l.allow_reentry
                     WHERE c.ticket_id = t.id)
             THEN jsonb_build_object('ok', false, 'reason', 'exit-not-allowed')
             ELSE jsonb_build_object('ok', true, 'reason', 'not-inside') END);
    END IF;
  END LOOP;
  IF v_out > 0 THEN
    PERFORM public._exos_oe_audit(s.org_id, s.session_id, NULL, 'order.check_out',
      jsonb_build_object('checked_out', v_out, 'list_id', p_list_id));
  END IF;
  RETURN jsonb_build_object('order_id', s.session_id, 'checked_out', v_out, 'results', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_order_check_out(text, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_check_out(text, uuid, text, text) TO authenticated, service_role;

-- A ticket's attendee. p_fields: attendee_name (or name, or first_name +
-- last_name), email. An email other than the holder's is a transfer: refused.
CREATE OR REPLACE FUNCTION public.exos_ticket_update(p_ticket_id uuid, p_fields jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t        public.exos_tickets%ROWTYPE;
  f        jsonb := coalesce(p_fields, '{}'::jsonb);
  k        text;
  v_name   text;
  v_holder text;
  v_email  text;
  v_chg    jsonb := '{}'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_ticket_update: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(f) <> 'object' THEN
    RAISE EXCEPTION 'exos_ticket_update: fields must be an object' USING ERRCODE = '22023';
  END IF;
  FOR k IN SELECT jsonb_object_keys(f) LOOP
    IF k NOT IN ('attendee_name', 'name', 'first_name', 'last_name', 'email', 'attendee_email') THEN
      RAISE EXCEPTION 'exos_ticket_update: % can''t be changed on a ticket (attendee name; the holder changes by transfer)', k
        USING ERRCODE = '22023';
    END IF;
  END LOOP;
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_ticket_update: ticket not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(t.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_ticket_update: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF t.status NOT IN ('active', 'used') THEN
    RAISE EXCEPTION 'exos_ticket_update: the ticket is %', t.status USING ERRCODE = '55000';
  END IF;
  IF t.pending_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'exos_ticket_update: the ticket is in transfer' USING ERRCODE = '55000';
  END IF;

  IF f ? 'email' OR f ? 'attendee_email' THEN
    v_email := lower(btrim(coalesce(f ->> 'email', f ->> 'attendee_email', '')));
    SELECT lower(u.email) INTO v_holder FROM auth.users u WHERE u.id = t.owner_id;
    v_holder := coalesce(v_holder, lower(t.buyer_email));
    IF v_email IS DISTINCT FROM v_holder THEN
      RAISE EXCEPTION 'exos_ticket_update: changing who holds a ticket is a transfer (the barcode changes); the holder sends it from their ticket, or refund and reissue'
        USING ERRCODE = '55000';
    END IF;
  END IF;

  v_name := t.attendee_name;
  IF f ? 'attendee_name' OR f ? 'name' THEN
    v_name := nullif(btrim(regexp_replace(coalesce(f ->> 'attendee_name', f ->> 'name', ''), '\s+', ' ', 'g')), '');
  ELSIF f ? 'first_name' OR f ? 'last_name' THEN
    v_name := nullif(btrim(regexp_replace(concat_ws(' ', f ->> 'first_name', f ->> 'last_name'), '\s+', ' ', 'g')), '');
  END IF;
  IF char_length(v_name) > 80 THEN
    RAISE EXCEPTION 'exos_ticket_update: name too long (max 80)' USING ERRCODE = '22023';
  END IF;
  IF v_name IS DISTINCT FROM t.attendee_name THEN
    v_chg := jsonb_build_object('attendee_name', jsonb_build_object('from', t.attendee_name, 'to', v_name));
    UPDATE public.exos_tickets SET attendee_name = v_name WHERE id = t.id;
    PERFORM public._exos_oe_audit(t.org_id, coalesce(t.order_ref, ''), t.id, 'ticket.update', v_chg);
  END IF;
  -- Never barcode_secret.
  RETURN jsonb_build_object('id', t.id, 'event_id', t.event_id, 'order_id', t.order_ref, 'tier_name', t.tier_name,
                            'attendee_name', v_name, 'status', t.status, 'check_in_at', t.check_in_at,
                            'changed', v_chg <> '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_update(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ticket_update(uuid, jsonb) TO authenticated, service_role;

-- 4. Staff reads -----------------------------------------------------------------------

-- The org's orders for the dashboard table: search (email, name, order id),
-- status, event, sort (created_at | amount_cents | email | event | status).
CREATE OR REPLACE FUNCTION public.exos_org_orders(
  p_org_id uuid, p_search text DEFAULT NULL, p_status text DEFAULT NULL, p_event_id uuid DEFAULT NULL,
  p_sort text DEFAULT 'created_at', p_desc boolean DEFAULT true, p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_q     text := nullif(lower(btrim(coalesce(p_search, ''))), '');
  v_lim   int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
  v_sort  text := CASE WHEN p_sort IN ('created_at', 'amount_cents', 'email', 'event', 'status') THEN p_sort ELSE 'created_at' END;
  v_total int;
  v_rows  jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_org_orders: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_org_orders: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_q IS NOT NULL AND char_length(v_q) > 100 THEN
    RAISE EXCEPTION 'exos_org_orders: search is at most 100 characters' USING ERRCODE = '22023';
  END IF;
  WITH base AS (
    SELECT s.session_id, s.event_id, e.name AS event_name, s.status, s.quantity, s.amount_cents, s.currency,
           s.buyer_email, d.first_name, d.last_name, d.phone, d.notes, s.created_at, s.fulfilled_at,
           (SELECT count(*) FROM public.exos_order_edits x WHERE x.session_id = s.session_id AND x.action = 'order.receipt') AS receipts_sent,
           (SELECT max(x.created_at) FROM public.exos_order_edits x WHERE x.session_id = s.session_id) AS last_edit_at
      FROM public.exos_checkout_sessions s
      JOIN public.exos_events e ON e.id = s.event_id
      LEFT JOIN public.exos_order_details d ON d.session_id = s.session_id
     WHERE s.org_id = p_org_id
       AND s.status IN ('fulfilled', 'partially_refunded', 'refunded', 'failed')
       AND (p_status IS NULL OR s.status = p_status)
       AND (p_event_id IS NULL OR s.event_id = p_event_id)
       AND (v_q IS NULL OR position(v_q IN lower(coalesce(s.buyer_email, ''))) > 0
            OR position(v_q IN lower(concat_ws(' ', d.first_name, d.last_name))) > 0
            OR lower(s.session_id) = v_q)
  )
  SELECT (SELECT count(*) FROM base),
         coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.rn), '[]'::jsonb)
    INTO v_total, v_rows
    FROM (SELECT b.*, row_number() OVER (ORDER BY
                   CASE WHEN v_sort = 'amount_cents' AND p_desc THEN b.amount_cents END DESC NULLS LAST,
                   CASE WHEN v_sort = 'amount_cents' AND NOT p_desc THEN b.amount_cents END ASC NULLS LAST,
                   CASE WHEN v_sort = 'email' AND p_desc THEN lower(b.buyer_email) END DESC NULLS LAST,
                   CASE WHEN v_sort = 'email' AND NOT p_desc THEN lower(b.buyer_email) END ASC NULLS LAST,
                   CASE WHEN v_sort = 'event' AND p_desc THEN lower(b.event_name) END DESC NULLS LAST,
                   CASE WHEN v_sort = 'event' AND NOT p_desc THEN lower(b.event_name) END ASC NULLS LAST,
                   CASE WHEN v_sort = 'status' AND p_desc THEN b.status END DESC NULLS LAST,
                   CASE WHEN v_sort = 'status' AND NOT p_desc THEN b.status END ASC NULLS LAST,
                   CASE WHEN p_desc THEN b.created_at END DESC,
                   CASE WHEN NOT p_desc THEN b.created_at END ASC,
                   b.session_id) AS rn
            FROM base b) p
   WHERE p.rn > v_off AND p.rn <= v_off + v_lim;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_orders(uuid, text, text, uuid, text, boolean, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_orders(uuid, text, text, uuid, text, boolean, int, int) TO authenticated, service_role;

-- An order's tickets for the Orders page (never a barcode secret).
CREATE OR REPLACE FUNCTION public.exos_order_tickets(p_session_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_order_tickets: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', t.id, 'tier_name', t.tier_name, 'attendee_name', t.attendee_name, 'status', t.status,
            'check_in_at', t.check_in_at, 'in_transfer', t.pending_transfer_id IS NOT NULL)
            ORDER BY t.created_at, t.id), '[]'::jsonb)
            FROM public.exos_tickets t WHERE t.order_ref = p_session_id AND t.org_id = v_org);
END $$;
REVOKE ALL ON FUNCTION public.exos_order_tickets(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_tickets(text) TO authenticated, service_role;

-- The audit of order edits, newest first (owner / manager).
CREATE OR REPLACE FUNCTION public.exos_order_edit_log(
  p_org_id uuid, p_session_id text DEFAULT NULL, p_action text DEFAULT NULL, p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_total int; v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_order_edit_log: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_order_edit_log: not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO v_total FROM public.exos_order_edits x
   WHERE x.org_id = p_org_id AND (p_session_id IS NULL OR x.session_id = p_session_id)
     AND (p_action IS NULL OR x.action = p_action);
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'session_id', x.session_id, 'ticket_id', x.ticket_id, 'action', x.action,
           'actor_email', (SELECT u.email FROM auth.users u WHERE u.id = x.actor),
           'via_api', x.api_key_id IS NOT NULL, 'changes', x.changes, 'created_at', x.created_at)
           ORDER BY x.created_at DESC, x.id), '[]'::jsonb)
    INTO v_rows
    FROM (SELECT * FROM public.exos_order_edits x
           WHERE x.org_id = p_org_id AND (p_session_id IS NULL OR x.session_id = p_session_id)
             AND (p_action IS NULL OR x.action = p_action)
           ORDER BY x.created_at DESC, x.id
           LIMIT least(greatest(coalesce(p_limit, 50), 1), 200) OFFSET greatest(coalesce(p_offset, 0), 0)) x;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_order_edit_log(uuid, text, text, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_edit_log(uuid, text, text, int, int) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_order_settings_get(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_order_settings_get: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_oe_settings(p_org_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_order_settings_get(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_settings_get(uuid) TO authenticated, service_role;

-- Owner only: whether receipts may go to another address, and how often.
CREATE OR REPLACE FUNCTION public.exos_order_settings_save(
  p_org_id uuid, p_receipt_override_email boolean, p_receipt_resends_per_hour int DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner'])) THEN
    RAISE EXCEPTION 'exos_order_settings_save: owners only' USING ERRCODE = '42501';
  END IF;
  IF p_receipt_resends_per_hour IS NULL OR p_receipt_resends_per_hour NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'exos_order_settings_save: 1 to 10 resends an hour' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_order_settings (org_id, receipt_override_email, receipt_resends_per_hour, updated_by)
  VALUES (p_org_id, coalesce(p_receipt_override_email, false), p_receipt_resends_per_hour, auth.uid())
  ON CONFLICT (org_id) DO UPDATE
    SET receipt_override_email = EXCLUDED.receipt_override_email,
        receipt_resends_per_hour = EXCLUDED.receipt_resends_per_hour, updated_by = EXCLUDED.updated_by;
  RETURN public._exos_oe_settings(p_org_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_order_settings_save(uuid, boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_settings_save(uuid, boolean, int) TO authenticated, service_role;

-- 5. The API's writes for these (service_role) -------------------------------------
-- Same contract as exos_api_write (mig 20261031110000): the key (not
-- revoked) and its scope, run as the key's creator while still an active
-- member, the target pinned to the key's org (else not found), an
-- Idempotency-Key replays the first answer, every write logged in
-- exos_api_writes. p_args.event_id (Opendate's confirm_id) must be the
-- target's event when given.
CREATE OR REPLACE FUNCTION public.exos_api_order_write(
  p_key_id          uuid,
  p_action          text,
  p_target          text,
  p_args            jsonb DEFAULT '{}'::jsonb,
  p_idempotency_key text  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  k        public.exos_api_keys%ROWTYPE;
  a        jsonb := coalesce(p_args, '{}'::jsonb);
  v_scope  text;
  v_actor  uuid;
  v_email  text;
  v_log    uuid;
  v_prev   public.exos_api_writes%ROWTYPE;
  v_was    jsonb;
  v_event  uuid;
  v_ticket uuid;
  v_out    jsonb;
BEGIN
  SELECT * INTO k FROM public.exos_api_keys WHERE id = p_key_id AND revoked_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_api_order_write: invalid or revoked API key' USING ERRCODE = '42501';
  END IF;
  v_scope := CASE p_action
    WHEN 'order.update' THEN 'tickets:write'
    WHEN 'order.send_receipt' THEN 'tickets:write'
    WHEN 'ticket.update' THEN 'tickets:write'
    WHEN 'order.check_out' THEN 'checkin:write' END;
  IF v_scope IS NULL THEN
    RAISE EXCEPTION 'exos_api_order_write: unknown action' USING ERRCODE = '22023';
  END IF;
  IF NOT public._exos_api_has_scope(k.scopes, v_scope) THEN
    RAISE EXCEPTION 'exos_api_order_write: the key lacks the % scope', v_scope USING ERRCODE = '42501';
  END IF;
  v_actor := k.created_by;
  IF v_actor IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = k.org_id AND m.user_id = v_actor AND m.disabled IS NOT TRUE) THEN
    RAISE EXCEPTION 'exos_api_order_write: the member who created this key is no longer in the organization; create a new key'
      USING ERRCODE = '42501';
  END IF;

  -- The target, pinned to the key's org.
  IF p_action = 'ticket.update' THEN
    v_ticket := public._exos_api_uuid(p_target, 'ticket');
    SELECT t.event_id INTO v_event FROM public.exos_tickets t WHERE t.id = v_ticket AND t.org_id = k.org_id;
    IF v_event IS NULL THEN RAISE EXCEPTION 'exos_api_order_write: ticket not found' USING ERRCODE = 'P0002'; END IF;
  ELSE
    SELECT s.event_id INTO v_event FROM public.exos_checkout_sessions s
     WHERE s.session_id = p_target AND s.org_id = k.org_id;
    IF v_event IS NULL THEN RAISE EXCEPTION 'exos_api_order_write: order not found' USING ERRCODE = 'P0002'; END IF;
  END IF;
  IF nullif(a ->> 'event_id', '') IS NOT NULL
     AND (a ->> 'event_id') IS DISTINCT FROM v_event::text THEN
    RAISE EXCEPTION 'exos_api_order_write: % not found on this event',
      CASE WHEN p_action = 'ticket.update' THEN 'ticket' ELSE 'order' END USING ERRCODE = 'P0002';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    IF p_idempotency_key !~ '^[A-Za-z0-9_.:-]{8,100}$' THEN
      RAISE EXCEPTION 'exos_api_order_write: Idempotency-Key must be 8-100 letters, digits, _ . : or -' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, idempotency_key)
    VALUES (k.org_id, k.id, v_actor, p_action, left(p_target, 255), p_idempotency_key)
    ON CONFLICT (api_key_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
    RETURNING id INTO v_log;
    IF v_log IS NULL THEN
      SELECT * INTO v_prev FROM public.exos_api_writes
       WHERE api_key_id = k.id AND idempotency_key = p_idempotency_key;
      IF v_prev.action IS DISTINCT FROM p_action OR v_prev.target IS DISTINCT FROM left(p_target, 255) THEN
        RAISE EXCEPTION 'exos_api_order_write: this Idempotency-Key was already used for another request' USING ERRCODE = '22023';
      END IF;
      RETURN coalesce(v_prev.result, '{}'::jsonb) || jsonb_build_object('idempotent_replay', true);
    END IF;
  END IF;

  v_was := jsonb_build_object(
    'claims', current_setting('request.jwt.claims', true), 'sub', current_setting('request.jwt.claim.sub', true),
    'role', current_setting('request.jwt.claim.role', true), 'email', current_setting('request.jwt.claim.email', true));
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_actor;
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_actor, 'role', 'authenticated', 'email', coalesce(v_email, ''),
                       'exos_api_key_id', k.id)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_actor::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_email, ''), true);

  CASE p_action
    WHEN 'order.update' THEN
      v_out := public.exos_order_update(p_target, coalesce(a -> 'fields', '{}'::jsonb));
    WHEN 'order.send_receipt' THEN
      v_out := public.exos_order_send_receipt(p_target, a ->> 'email');
    WHEN 'order.check_out' THEN
      v_out := public.exos_order_check_out(p_target, nullif(a ->> 'list_id', '')::uuid, a ->> 'reason', a ->> 'device');
    WHEN 'ticket.update' THEN
      v_out := public.exos_ticket_update(v_ticket, coalesce(a -> 'fields', '{}'::jsonb));
  END CASE;

  PERFORM set_config('request.jwt.claims', coalesce(v_was ->> 'claims', ''), true);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_was ->> 'sub', ''), true);
  PERFORM set_config('request.jwt.claim.role', coalesce(v_was ->> 'role', ''), true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_was ->> 'email', ''), true);

  IF v_log IS NOT NULL THEN
    UPDATE public.exos_api_writes SET result = v_out WHERE id = v_log;
  ELSE
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target)
    VALUES (k.org_id, k.id, v_actor, p_action, left(p_target, 255));
  END IF;
  RETURN coalesce(v_out, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_api_order_write(uuid, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_order_write(uuid, text, text, jsonb, text) TO service_role;

-- 6. Guest list preview (writes nothing) ----------------------------------------------
-- p_rows: [{ name, email?, phone?, code?, ticket?, note?, plus_ones? }] as
-- the Door import uploads them. Each row comes back with status ready,
-- invalid (reason), duplicate (existing | in_file) or too_many_plus_ones;
-- warnings: invalid_email (the import would drop it), invalid_phone.
CREATE OR REPLACE FUNCTION public._exos_guest_list_preview(p_org uuid, p_event_id uuid, p_list_id uuid, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  ev        public.exos_events%ROWTYPE;
  l         public.exos_guest_lists%ROWTYPE;
  r         jsonb;
  i         int := 0;
  v_name    text;
  v_email   text;
  v_raw     text;
  v_code    text;
  v_plus    int;
  v_status  text;
  v_reason  text;
  v_warn    jsonb;
  v_exist   text;
  v_max     int;
  v_seen    text[] := '{}';
  v_key     text;
  v_out     jsonb := '[]'::jsonb;
  v_ready   int := 0;
  v_heads   int := 0;
  v_dupes   int := 0;
  v_invalid int := 0;
  v_bad_em  int := 0;
  v_list_heads int;
  v_counted int;
BEGIN
  SELECT * INTO ev FROM public.exos_events WHERE id = p_event_id AND org_id = p_org;
  IF NOT FOUND THEN
    RAISE EXCEPTION '_exos_guest_list_preview: event not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_list_id IS NOT NULL THEN
    SELECT * INTO l FROM public.exos_guest_lists WHERE id = p_list_id AND event_id = p_event_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION '_exos_guest_list_preview: guest list not found' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION '_exos_guest_list_preview: rows must be a list' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_rows) > 5000 THEN
    RAISE EXCEPTION '_exos_guest_list_preview: at most 5000 rows per import' USING ERRCODE = '22023';
  END IF;
  v_max := least(coalesce(l.max_plus_ones, 10), 10);

  FOR r IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    i := i + 1;
    v_status := 'ready'; v_reason := NULL; v_warn := '[]'::jsonb; v_exist := NULL;
    IF jsonb_typeof(r) <> 'object' THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object('row', i, 'status', 'invalid', 'reason', 'not an object'));
      v_invalid := v_invalid + 1;
      CONTINUE;
    END IF;
    v_name := nullif(btrim(regexp_replace(coalesce(r ->> 'name', ''), '\s+', ' ', 'g')), '');
    v_raw  := nullif(lower(btrim(coalesce(r ->> 'email', ''))), '');
    v_email := CASE WHEN v_raw ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(v_raw) <= 254 THEN v_raw END;
    v_code := public._exos_door_code(r ->> 'code');
    v_plus := CASE WHEN coalesce(r ->> 'plus_ones', '') ~ '^\d{1,3}$' THEN (r ->> 'plus_ones')::int ELSE 0 END;
    IF v_raw IS NOT NULL AND v_email IS NULL THEN
      v_warn := v_warn || '["invalid_email"]'::jsonb;
      v_bad_em := v_bad_em + 1;
    END IF;
    IF nullif(btrim(coalesce(r ->> 'phone', '')), '') IS NOT NULL AND btrim(r ->> 'phone') !~ '^[0-9+() .-]{3,32}$' THEN
      v_warn := v_warn || '["invalid_phone"]'::jsonb;
    END IF;
    IF v_name IS NULL THEN
      v_status := 'invalid'; v_reason := 'missing name';
    ELSIF char_length(v_name) > 80 THEN
      v_status := 'invalid'; v_reason := 'name too long';
    ELSIF nullif(btrim(coalesce(r ->> 'code', '')), '') IS NOT NULL AND v_code IS NULL THEN
      v_status := 'invalid'; v_reason := 'code too long';
    ELSIF v_plus > v_max THEN
      v_status := 'too_many_plus_ones'; v_reason := format('at most %s plus-ones', v_max);
    ELSE
      v_key := CASE WHEN v_code IS NOT NULL THEN 'c:' || v_code ELSE 'n:' || lower(v_name) || '|' || coalesce(v_email, '') END;
      IF v_code IS NOT NULL THEN
        SELECT gl.name INTO v_exist FROM public.exos_guest_list_entries en
          JOIN public.exos_guest_lists gl ON gl.id = en.list_id
         WHERE en.event_id = p_event_id AND en.external_code = v_code LIMIT 1;
      ELSE
        SELECT gl.name INTO v_exist FROM public.exos_guest_list_entries en
          JOIN public.exos_guest_lists gl ON gl.id = en.list_id
         WHERE en.event_id = p_event_id AND lower(en.guest_name) = lower(v_name)
           AND en.email IS NOT DISTINCT FROM v_email AND en.voided_at IS NULL LIMIT 1;
      END IF;
      IF v_exist IS NOT NULL THEN
        v_status := 'duplicate'; v_reason := 'existing';
      ELSIF v_key = ANY (v_seen) THEN
        v_status := 'duplicate'; v_reason := 'in_file';
      ELSE
        v_seen := v_seen || v_key;
      END IF;
    END IF;
    IF v_status = 'ready' THEN
      v_ready := v_ready + 1;
      v_heads := v_heads + 1 + v_plus;
    ELSIF v_status = 'duplicate' THEN
      v_dupes := v_dupes + 1;
    ELSE
      v_invalid := v_invalid + 1;
    END IF;
    v_out := v_out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'row', i, 'status', v_status, 'reason', v_reason, 'name', left(v_name, 80), 'email', v_email,
      'code', v_code, 'plus_ones', v_plus, 'tickets', 1 + v_plus, 'existing_list_name', v_exist,
      'warnings', CASE WHEN jsonb_array_length(v_warn) > 0 THEN v_warn END)));
  END LOOP;

  SELECT coalesce(sum(1 + en.plus_ones), 0) INTO v_list_heads
    FROM public.exos_guest_list_entries en WHERE en.list_id = l.id AND en.voided_at IS NULL;
  SELECT coalesce(sum(1 + en.plus_ones), 0) INTO v_counted
    FROM public.exos_guest_list_entries en
    JOIN public.exos_guest_lists gl ON gl.id = en.list_id AND gl.counts_toward_capacity
   WHERE en.event_id = p_event_id AND en.voided_at IS NULL;

  RETURN jsonb_build_object(
    'event_id', p_event_id, 'list_id', l.id, 'rows', v_out,
    'summary', jsonb_build_object('rows', i, 'ready', v_ready, 'duplicates', v_dupes, 'invalid', v_invalid,
                                  'invalid_emails', v_bad_em, 'heads', v_heads),
    'capacity', jsonb_build_object(
      'list_cap', l.cap, 'list_heads', CASE WHEN l.id IS NOT NULL THEN v_list_heads END,
      'list_cap_left_after', CASE WHEN l.cap IS NOT NULL THEN l.cap - v_list_heads - v_heads END,
      'over_list_cap', l.cap IS NOT NULL AND v_list_heads + v_heads > l.cap,
      'counts_toward_capacity', coalesce(l.counts_toward_capacity, false),
      'event_capacity', ev.total_tickets, 'tickets_sold', ev.tickets_sold, 'counted_guest_heads', v_counted,
      'event_left_after', CASE WHEN ev.total_tickets IS NOT NULL THEN
        ev.total_tickets - coalesce(ev.tickets_sold, 0) - v_counted
        - CASE WHEN coalesce(l.counts_toward_capacity, false) THEN v_heads ELSE 0 END END),
    'writes', false);
END $$;
REVOKE ALL ON FUNCTION public._exos_guest_list_preview(uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_guest_list_preview(uuid, uuid, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_guest_list_preview(p_event_id uuid, p_list_id uuid, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_guest_list_preview: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_guest_list_preview: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_guest_list_preview(v_org, p_event_id, p_list_id, p_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_guest_list_preview(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_guest_list_preview(uuid, uuid, jsonb) TO authenticated, service_role;

-- 7. Recommendations -------------------------------------------------------------------
-- Weights: must equal REC_WEIGHTS in supabase/functions/_shared/recommend.ts
-- (src/lib/recommendations.test.ts and test_order_edits_recs.sql R1 pin them).
CREATE OR REPLACE FUNCTION public._exos_rec_score(
  p_artists int, p_venue boolean, p_series boolean, p_genres int, p_tags int, p_co_buyers int,
  p_days numeric, p_window_days int)
RETURNS int
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN base = 0 THEN 0 ELSE base +
           CASE WHEN p_days IS NULL OR coalesce(p_window_days, 0) <= 0 THEN 0
                ELSE greatest(0, 20 - floor(abs(p_days) * 20 / p_window_days)::int) END END
    FROM (SELECT 50 * least(greatest(coalesce(p_artists, 0), 0), 3)
               + CASE WHEN coalesce(p_venue, false) THEN 40 ELSE 0 END
               + CASE WHEN coalesce(p_series, false) THEN 30 ELSE 0 END
               + 15 * least(greatest(coalesce(p_genres, 0), 0), 4)
               + 10 * least(greatest(coalesce(p_tags, 0), 0), 5)
               + 5 * least(greatest(coalesce(p_co_buyers, 0), 0), 10) AS base) b
$$;
REVOKE ALL ON FUNCTION public._exos_rec_score(int, boolean, boolean, int, int, int, numeric, int) FROM PUBLIC, anon, authenticated;

-- A fan for an event: how many of their past events matched each way (max 3 each).
CREATE OR REPLACE FUNCTION public._exos_rec_fan_score(p_artist int, p_venue int, p_series int, p_genre int, p_tag int)
RETURNS int
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT 50 * least(greatest(coalesce(p_artist, 0), 0), 3) + 40 * least(greatest(coalesce(p_venue, 0), 0), 3)
       + 30 * least(greatest(coalesce(p_series, 0), 0), 3) + 15 * least(greatest(coalesce(p_genre, 0), 0), 3)
       + 10 * least(greatest(coalesce(p_tag, 0), 0), 3)
$$;
REVOKE ALL ON FUNCTION public._exos_rec_fan_score(int, int, int, int, int) FROM PUBLIC, anon, authenticated;

-- What an event is matched on: (event, kind, item, key). An artist is
-- matched by canonical artist or by name, a tag by canonical tag or name, a
-- venue by its record or its venue key (name + city).
CREATE OR REPLACE FUNCTION public._exos_rec_event_keys(p_event_ids uuid[])
RETURNS TABLE (event_id uuid, kind text, item text, key text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT l.event_id, 'artist', a.id::text, k.key
    FROM public.exos_event_lineup l
    JOIN public.exos_artists a ON a.id = l.artist_id
    CROSS JOIN LATERAL (VALUES ('n:' || lower(regexp_replace(btrim(a.name), '\s+', ' ', 'g'))),
                               ('c:' || a.canonical_artist_id::text)) k(key)
   WHERE l.event_id = ANY (p_event_ids) AND k.key IS NOT NULL
  UNION
  SELECT l.event_id, 'genre', lower(btrim(g)), 'g:' || lower(btrim(g))
    FROM public.exos_event_lineup l
    JOIN public.exos_artists a ON a.id = l.artist_id
    CROSS JOIN LATERAL unnest(coalesce(a.genres, '{}')) g
   WHERE l.event_id = ANY (p_event_ids) AND btrim(g) <> ''
  UNION
  SELECT ti.taggable_id, 'tag', t.id::text, k.key
    FROM public.exos_tagged_items ti
    JOIN public.exos_tags t ON t.id = ti.tag_id
    CROSS JOIN LATERAL (VALUES ('n:' || lower(btrim(t.name))), ('c:' || t.canonical_tag_id)) k(key)
   WHERE ti.taggable_type = 'event' AND ti.taggable_id = ANY (p_event_ids) AND k.key IS NOT NULL
  UNION
  SELECT e.id, 'venue', e.id::text, k.key
    FROM public.exos_events e
    CROSS JOIN LATERAL (VALUES ('v:' || e.exos_venue_id::text),
                               ('k:' || public.exos_venue_key(coalesce(e.venue_name, e.venue_location), e.venue_address))) k(key)
   WHERE e.id = ANY (p_event_ids) AND k.key IS NOT NULL
  UNION
  SELECT e.id, 'series', e.series_id::text, 's:' || e.series_id::text
    FROM public.exos_events e
   WHERE e.id = ANY (p_event_ids) AND e.series_id IS NOT NULL
$$;
REVOKE ALL ON FUNCTION public._exos_rec_event_keys(uuid[]) FROM PUBLIC, anon, authenticated;

-- A candidate's public card (the fields anyone sees on the event page).
CREATE OR REPLACE FUNCTION public._exos_rec_public(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'starts_at', e.starts_at,
           'timezone', e.timezone, 'venue_name', coalesce(e.venue_name, e.venue_location), 'image_url', e.image_url,
           'org', jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug))
    FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_rec_public(uuid) FROM PUBLIC, anon, authenticated;

-- Score the public upcoming candidates against a profile of keys (the
-- source event's, or a fan's past events'). Internal.
--   p_org: the caller's org; p_cross: other orgs' public events too;
--   p_profile_events: the events the profile is made of (excluded from the
--   results, like p_exclude); p_anchor: the date proximity is measured from;
--   p_co_from: events whose buyers count as co-buyers (the caller's org only).
CREATE OR REPLACE FUNCTION public._exos_rec_rank(
  p_org uuid, p_cross boolean, p_profile_events uuid[], p_exclude uuid[], p_anchor timestamptz,
  p_window_days int, p_co_from uuid[], p_exclude_buyer text, p_limit int, p_offset int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_total int; v_rows jsonb;
BEGIN
  WITH prof AS (
    SELECT DISTINCT k.kind, k.key FROM public._exos_rec_event_keys(coalesce(p_profile_events, '{}')) k
  ), cand AS (
    SELECT e.id, e.org_id, e.starts_at, e.series_id
      FROM public.exos_events e
     WHERE e.status = 'published' AND NOT coalesce(e.noindex, false) AND e.starts_at > now()
       AND (e.org_id = p_org OR coalesce(p_cross, false))
       AND NOT (e.id = ANY (coalesce(p_profile_events, '{}') || coalesce(p_exclude, '{}')))
  ), ck AS (
    SELECT k.* FROM public._exos_rec_event_keys((SELECT coalesce(array_agg(id), '{}') FROM cand)) k
  ), sig AS (
    SELECT c.id, c.org_id, c.starts_at,
           (SELECT count(DISTINCT ck.item) FROM ck JOIN prof p ON p.kind = ck.kind AND p.key = ck.key
             WHERE ck.event_id = c.id AND ck.kind = 'artist')::int AS artists,
           EXISTS (SELECT 1 FROM ck JOIN prof p ON p.kind = ck.kind AND p.key = ck.key
                    WHERE ck.event_id = c.id AND ck.kind = 'venue') AS venue,
           (c.org_id = p_org AND EXISTS (SELECT 1 FROM ck JOIN prof p ON p.kind = ck.kind AND p.key = ck.key
                    WHERE ck.event_id = c.id AND ck.kind = 'series')) AS series,
           (SELECT count(DISTINCT ck.item) FROM ck JOIN prof p ON p.kind = ck.kind AND p.key = ck.key
             WHERE ck.event_id = c.id AND ck.kind = 'genre')::int AS genres,
           (SELECT count(DISTINCT ck.item) FROM ck JOIN prof p ON p.kind = ck.kind AND p.key = ck.key
             WHERE ck.event_id = c.id AND ck.kind = 'tag')::int AS tags,
           -- Co-buyers: only between the caller's own events, and only a count.
           CASE WHEN c.org_id = p_org AND cardinality(coalesce(p_co_from, '{}')) > 0 THEN (
             SELECT count(DISTINCT coalesce(t1.owner_id::text, lower(t1.buyer_email)))
               FROM public.exos_tickets t1
              WHERE t1.event_id = c.id AND t1.org_id = p_org AND t1.status <> 'voided'
                AND coalesce(t1.owner_id::text, lower(t1.buyer_email)) IS DISTINCT FROM p_exclude_buyer
                AND EXISTS (SELECT 1 FROM public.exos_tickets t2
                             WHERE t2.event_id = ANY (p_co_from) AND t2.org_id = p_org AND t2.status <> 'voided'
                               AND ((t1.owner_id IS NOT NULL AND t2.owner_id = t1.owner_id)
                                    OR lower(t2.buyer_email) = lower(t1.buyer_email))))::int
           ELSE 0 END AS co_buyers,
           extract(epoch FROM (c.starts_at - p_anchor)) / 86400.0 AS days
      FROM cand c
  ), scored AS (
    SELECT s.*, public._exos_rec_score(s.artists, s.venue, s.series, s.genres, s.tags, s.co_buyers, s.days, p_window_days) AS score
      FROM sig s
  ), ranked AS (
    SELECT s.*, row_number() OVER (ORDER BY s.score DESC, s.starts_at, s.id) AS rn
      FROM scored s WHERE s.score > 0
  )
  SELECT (SELECT count(*) FROM ranked),
         coalesce(jsonb_agg(public._exos_rec_public(r.id) || jsonb_build_object(
           'score', r.score, 'same_org', r.org_id = p_org,
           'signals', jsonb_build_object('shared_artists', r.artists, 'same_venue', r.venue, 'same_series', r.series,
                                         'shared_genres', r.genres, 'shared_tags', r.tags, 'co_buyers', r.co_buyers,
                                         'days_apart', round(abs(r.days))::int))
           ORDER BY r.rn), '[]'::jsonb)
    INTO v_total, v_rows
    FROM ranked r
   WHERE r.rn > greatest(coalesce(p_offset, 0), 0)
     AND r.rn <= greatest(coalesce(p_offset, 0), 0) + least(greatest(coalesce(p_limit, 50), 1), 200);
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public._exos_rec_rank(uuid, boolean, uuid[], uuid[], timestamptz, int, uuid[], text, int, int) FROM PUBLIC, anon, authenticated;

-- Events like one of the org's (any status: the source stays private; only
-- public events come back).
CREATE OR REPLACE FUNCTION public._exos_rec_similar_events(
  p_org uuid, p_event_id uuid, p_cross boolean, p_limit int, p_offset int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_start timestamptz;
BEGIN
  SELECT e.starts_at INTO v_start FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = p_org;
  IF NOT FOUND THEN
    RAISE EXCEPTION '_exos_rec_similar_events: event not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object('event_id', p_event_id) || public._exos_rec_rank(
    p_org, p_cross, ARRAY[p_event_id], '{}', coalesce(v_start, now()), 30, ARRAY[p_event_id], NULL, p_limit, p_offset);
END $$;
REVOKE ALL ON FUNCTION public._exos_rec_similar_events(uuid, uuid, boolean, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rec_similar_events(uuid, uuid, boolean, int, int) TO service_role;

-- Events for one of the org's fans, from what they bought FROM THIS ORG.
-- Events they already hold a ticket for are left out.
CREATE OR REPLACE FUNCTION public._exos_rec_fan_events(
  p_org uuid, p_fan_id uuid, p_cross boolean, p_limit int, p_offset int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE f public.exos_fans%ROWTYPE; v_bought uuid[]; v_held uuid[];
BEGIN
  SELECT * INTO f FROM public.exos_fans WHERE id = p_fan_id AND org_id = p_org AND discarded_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION '_exos_rec_fan_events: fan not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT coalesce(array_agg(DISTINCT t.event_id), '{}') INTO v_bought
    FROM public.exos_tickets t
   WHERE t.org_id = p_org AND t.status <> 'voided'
     AND ((f.user_id IS NOT NULL AND t.owner_id = f.user_id) OR lower(t.buyer_email) = f.email);
  -- What they hold FROM THIS ORG is excluded. Never holdings at other orgs:
  -- an event missing from a scope=all answer would tell this org about a
  -- purchase elsewhere.
  SELECT coalesce(array_agg(DISTINCT t.event_id), '{}') INTO v_held
    FROM public.exos_tickets t
   WHERE t.org_id = p_org AND t.status <> 'voided'
     AND ((f.user_id IS NOT NULL AND t.owner_id = f.user_id) OR lower(t.buyer_email) = f.email);
  RETURN jsonb_build_object('fan_id', f.id) || public._exos_rec_rank(
    p_org, p_cross, v_bought, v_held, now(), 60, v_bought, coalesce(f.user_id::text, f.email), p_limit, p_offset);
END $$;
REVOKE ALL ON FUNCTION public._exos_rec_fan_events(uuid, uuid, boolean, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rec_fan_events(uuid, uuid, boolean, int, int) TO service_role;

-- The org's fans likely to want one of its events: on the email list (their
-- own opt-in), not discarded, no ticket for it yet; scored by how many of
-- their past events with the org share an artist, venue, series, genre or tag.
CREATE OR REPLACE FUNCTION public._exos_rec_event_fans(p_org uuid, p_event_id uuid, p_limit int, p_offset int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_total int; v_rows jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = p_org) THEN
    RAISE EXCEPTION '_exos_rec_event_fans: event not found' USING ERRCODE = 'P0002';
  END IF;
  WITH tgt AS (
    SELECT DISTINCT k.kind, k.key FROM public._exos_rec_event_keys(ARRAY[p_event_id]) k
  ), fans AS (
    SELECT f.* FROM public.exos_fans f
     WHERE f.org_id = p_org AND f.discarded_at IS NULL AND public._exos_fan_email_list(f) = 'subscribed'
       AND NOT EXISTS (SELECT 1 FROM public.exos_tickets t
                        WHERE t.event_id = p_event_id AND t.status <> 'voided'
                          AND ((f.user_id IS NOT NULL AND t.owner_id = f.user_id) OR lower(t.buyer_email) = f.email))
  ), hist AS (
    SELECT DISTINCT f.id AS fan_id, t.event_id
      FROM fans f JOIN public.exos_tickets t
        ON t.org_id = p_org AND t.status <> 'voided' AND t.event_id <> p_event_id
       AND ((f.user_id IS NOT NULL AND t.owner_id = f.user_id) OR lower(t.buyer_email) = f.email)
  ), hk AS (
    SELECT DISTINCT k.event_id, k.kind FROM public._exos_rec_event_keys((SELECT coalesce(array_agg(DISTINCT event_id), '{}') FROM hist)) k
      JOIN tgt g ON g.kind = k.kind AND g.key = k.key
  ), per AS (
    SELECT h.fan_id,
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM hk WHERE hk.event_id = h.event_id AND hk.kind = 'artist'))::int AS a,
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM hk WHERE hk.event_id = h.event_id AND hk.kind = 'venue'))::int AS v,
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM hk WHERE hk.event_id = h.event_id AND hk.kind = 'series'))::int AS s,
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM hk WHERE hk.event_id = h.event_id AND hk.kind = 'genre'))::int AS g,
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM hk WHERE hk.event_id = h.event_id AND hk.kind = 'tag'))::int AS t
      FROM hist h GROUP BY h.fan_id
  ), ranked AS (
    SELECT f.id, f.email, f.first_name, f.last_name, f.last_order_at, f.orders_count, p.a, p.v, p.s, p.g, p.t,
           public._exos_rec_fan_score(p.a, p.v, p.s, p.g, p.t) AS score
      FROM per p JOIN fans f ON f.id = p.fan_id
  ), paged AS (
    SELECT r.*, row_number() OVER (ORDER BY r.score DESC, r.last_order_at DESC NULLS LAST, r.id) AS rn
      FROM ranked r WHERE r.score > 0
  )
  SELECT (SELECT count(*) FROM paged),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'email', p.email, 'first_name', p.first_name, 'last_name', p.last_name,
           'orders_count', p.orders_count, 'last_order_at', p.last_order_at, 'score', p.score,
           'signals', jsonb_build_object('artist_events', p.a, 'venue_events', p.v, 'series_events', p.s,
                                         'genre_events', p.g, 'tag_events', p.t))
           ORDER BY p.rn), '[]'::jsonb)
    INTO v_total, v_rows
    FROM paged p
   WHERE p.rn > greatest(coalesce(p_offset, 0), 0)
     AND p.rn <= greatest(coalesce(p_offset, 0), 0) + least(greatest(coalesce(p_limit, 50), 1), 200);
  RETURN jsonb_build_object('event_id', p_event_id, 'total', v_total, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public._exos_rec_event_fans(uuid, uuid, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rec_event_fans(uuid, uuid, int, int) TO service_role;

-- Dashboard wrappers (signed in; the role decides).
CREATE OR REPLACE FUNCTION public.exos_event_similar_events(
  p_event_id uuid, p_cross boolean DEFAULT false, p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance', 'content'])) THEN
    RAISE EXCEPTION 'exos_event_similar_events: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_rec_similar_events(v_org, p_event_id, p_cross, p_limit, p_offset);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_similar_events(uuid, boolean, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_similar_events(uuid, boolean, int, int) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_fan_event_recommendations(
  p_org_id uuid, p_fan_id uuid, p_cross boolean DEFAULT false, p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_fan_event_recommendations: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_rec_fan_events(p_org_id, p_fan_id, p_cross, p_limit, p_offset);
END $$;
REVOKE ALL ON FUNCTION public.exos_fan_event_recommendations(uuid, uuid, boolean, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_fan_event_recommendations(uuid, uuid, boolean, int, int) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_event_fan_recommendations(p_event_id uuid, p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_event_fan_recommendations: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_rec_event_fans(v_org, p_event_id, p_limit, p_offset);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_fan_recommendations(uuid, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_fan_recommendations(uuid, int, int) TO authenticated, service_role;
