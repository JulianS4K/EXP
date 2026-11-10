-- ============================================================================
-- Migration 20261113100000 — Exos: kiosk mode (self-serve card sales)
-- Branch:   claude/exos-kiosk
-- Touches:  C: TABLE exos_pos_kiosks (the kiosk flag on a POS device: one
--              event, the card reader, a printer, the admin PIN's bcrypt hash),
--              exos_pos_kiosk_sessions (a browser in kiosk mode: the sha-256
--              of its credential, never the credential). RLS; owners and
--              managers read them without the hashes (column grants); no client
--              writes.
--           W: TABLE exos_pos_orders (+channel 'door' | 'kiosk', +kiosk_session_id;
--              set only by the trigger exos_pos_orders_zkiosk)
--           C: FUNCTION exos_pos_kiosk_configure, exos_pos_kiosk_enter,
--              exos_pos_kiosk_end (authenticated: owner / manager, checked
--              here); _exos_pos_kiosk_resolve, _exos_pos_kiosk_tiers,
--              _exos_pos_kiosk_state, _exos_pos_kiosk_begin,
--              _exos_pos_kiosk_charge, _exos_pos_kiosk_lookup,
--              _exos_pos_kiosk_codes, _exos_pos_kiosk_email,
--              _exos_pos_kiosk_exit (service role only: exos-pos calls them
--              with the kiosk's credential; each resolves it first),
--              exos_pos_tg_order_kiosk (trigger)
--           W: FUNCTION _exos_pos_order_json (marker /* exos: pos kiosk channel */),
--              _exos_pos_walkup_complete (marker /* exos: pos kiosk card only */),
--              exos_pos_settlement_summary (marker /* exos: pos kiosk settlement */)
--           R: exos_pos_devices, exos_pos_terminal_readers, exos_events,
--              exos_ticket_tiers, _exos_pos_walkup_begin_card,
--              _exos_pos_card_begin, _exos_pos_card_lookup, _exos_print_mint,
--              _exos_pos_deliver_email, _exos_question_defs, _exos_audit
-- Pre-reqs: 20261107100000 (walk-up sales), 20261107130000 (card at the door),
--           20261108110000 (walk-up questions), 20261109100000 (org audit).
--
-- docs/pos.md "Kiosk mode". A kiosk is a POS device an owner or manager marks
-- for ONE event, with a card reader and an admin PIN. On that screen the
-- owner / manager starts kiosk mode: Exos mints a kiosk credential (256 bits,
-- shown once, kept as its sha-256), the browser signs the staff member out and
-- keeps only the credential. From then on the screen sells that event's
-- public ticket types to the public, by card on the reader only, and nothing
-- else:
--   * every kiosk call is a service-role core that resolves the credential
--     first (a live session, its kiosk still set to the same event and
--     device, the device active, the event not cancelled, and the member who
--     started it still an owner or manager of the org) and only then reaches
--     the card walk-up path with that member as the seller of record;
--   * the order trigger stamps channel 'kiosk' and the session, and refuses
--     an order for another event or device, and any comp;
--   * a kiosk device can't take a door sale (cash, comp or card) outside
--     kiosk mode, and a kiosk order can only be completed by a card;
--   * required checkout questions can't be skipped;
--   * no cash, comps, voids or refunds: those stay with staff in the door app;
--   * the PIN exits kiosk mode: 10 tries a minute per device and 5 wrong in a
--     row lock it for 5 minutes (a wrong PIN answers, it doesn't raise, so the
--     count sticks); entering and leaving are audited (pos.kiosk_enter,
--     pos.kiosk_exit, pos.kiosk_lockout; pos.kiosk_set / pos.kiosk_off for
--     the setup).
-- Kiosk sales are walk-up card sales: the same tender, the same
-- journal entry (pos_card_sale), settlement counts them and shows them apart.
--
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked
-- patches). D4 authors; not applied. Prod apply needs operator OK.
-- ROLLBACK: drop the trigger exos_pos_orders_zkiosk and the functions above;
-- re-run 20261107100000's _exos_pos_order_json / exos_pos_settlement_summary and
-- re-apply 20261107130000's two markers on _exos_pos_walkup_complete
-- (re-running 20261107100000 + 20261107130000 does it); drop the two columns
-- and the two tables.
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
-- 1. Tables.
-- ===========================================================================

-- The kiosk flag on a device: one event, the reader it charges on, whether a
-- ticket printer is attached, and the admin PIN (bcrypt; never the PIN).
CREATE TABLE IF NOT EXISTS public.exos_pos_kiosks (
  device_id        uuid        PRIMARY KEY REFERENCES public.exos_pos_devices (id) ON DELETE CASCADE,
  org_id           uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id         uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  reader_device_id uuid        REFERENCES public.exos_pos_devices (id) ON DELETE SET NULL,
  printer          boolean     NOT NULL DEFAULT false,
  pin_hash         text        NOT NULL CHECK (pin_hash ~ '^\$2[abxy]\$[0-9]{2}\$.{53}$'),
  pin_set_at       timestamptz NOT NULL DEFAULT now(),
  pin_failures     integer     NOT NULL DEFAULT 0 CHECK (pin_failures BETWEEN 0 AND 100),
  pin_locked_until timestamptz,
  configured_by    uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_pos_kiosks_org_idx ON public.exos_pos_kiosks (org_id, event_id);

-- A browser in kiosk mode. The credential is shown once (exos_pos_kiosk_enter);
-- only its sha-256 is kept. One live session per device.
CREATE TABLE IF NOT EXISTS public.exos_pos_kiosk_sessions (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id     uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  device_id    uuid        NOT NULL REFERENCES public.exos_pos_devices (id) ON DELETE CASCADE,
  token_hash   text        NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  started_by   uuid        NOT NULL,
  started_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  last_seen_at timestamptz,
  ended_at     timestamptz,
  ended_by     uuid,
  ended_reason text        CHECK (ended_reason IS NULL OR ended_reason IN ('pin', 'replaced', 'off', 'reconfigured', 'staff')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_pos_kiosk_sessions_live_idx ON public.exos_pos_kiosk_sessions (device_id) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_pos_kiosk_sessions_org_idx ON public.exos_pos_kiosk_sessions (org_id, started_at DESC);

DROP TRIGGER IF EXISTS exos_pos_kiosks_touch ON public.exos_pos_kiosks;
CREATE TRIGGER exos_pos_kiosks_touch BEFORE UPDATE ON public.exos_pos_kiosks
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_pos_kiosk_sessions_touch ON public.exos_pos_kiosk_sessions;
CREATE TRIGGER exos_pos_kiosk_sessions_touch BEFORE UPDATE ON public.exos_pos_kiosk_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_pos_kiosks         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_kiosk_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_pos_kiosks, public.exos_pos_kiosk_sessions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_pos_kiosks, public.exos_pos_kiosk_sessions TO service_role;
-- Owners and managers read the setup; never a hash or the PIN counters.
GRANT SELECT (device_id, org_id, event_id, reader_device_id, printer, pin_set_at, configured_by, created_at, updated_at)
  ON public.exos_pos_kiosks TO authenticated;
GRANT SELECT (id, org_id, event_id, device_id, started_by, started_at, expires_at, last_seen_at, ended_at, ended_by, ended_reason)
  ON public.exos_pos_kiosk_sessions TO authenticated;
DROP POLICY IF EXISTS exos_pos_kiosks_sel ON public.exos_pos_kiosks;
CREATE POLICY exos_pos_kiosks_sel ON public.exos_pos_kiosks FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
DROP POLICY IF EXISTS exos_pos_kiosk_sessions_sel ON public.exos_pos_kiosk_sessions;
CREATE POLICY exos_pos_kiosk_sessions_sel ON public.exos_pos_kiosk_sessions FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));

-- Which channel a POS order came through. Only the trigger below sets these.
ALTER TABLE public.exos_pos_orders
  ADD COLUMN IF NOT EXISTS channel          text NOT NULL DEFAULT 'door',
  ADD COLUMN IF NOT EXISTS kiosk_session_id uuid REFERENCES public.exos_pos_kiosk_sessions (id) ON DELETE SET NULL;
ALTER TABLE public.exos_pos_orders DROP CONSTRAINT IF EXISTS exos_pos_orders_channel_check;
ALTER TABLE public.exos_pos_orders ADD CONSTRAINT exos_pos_orders_channel_check CHECK (channel IN ('door', 'kiosk'));
CREATE INDEX IF NOT EXISTS exos_pos_orders_kiosk_idx ON public.exos_pos_orders (kiosk_session_id) WHERE kiosk_session_id IS NOT NULL;

-- Fires after exos_pos_orders_new / _walkup_fields (BEFORE triggers run in
-- name order). A kiosk order comes only from _exos_pos_kiosk_begin, which sets
-- exos.pos_kiosk_session for the one insert: its own event and device, no
-- comps. Anything else is a door order, and a kiosk device takes none.
CREATE OR REPLACE FUNCTION public.exos_pos_tg_order_kiosk()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_s text := nullif(current_setting('exos.pos_kiosk_session', true), ''); s public.exos_pos_kiosk_sessions%ROWTYPE;
BEGIN
  IF v_s IS NOT NULL THEN
    SELECT * INTO s FROM public.exos_pos_kiosk_sessions WHERE id = v_s::uuid AND ended_at IS NULL;
    IF s.id IS NULL OR s.event_id IS DISTINCT FROM NEW.event_id OR s.device_id IS DISTINCT FROM NEW.device_id THEN
      RAISE EXCEPTION 'this kiosk sells for its own event only' USING ERRCODE = '42501', HINT = 'kiosk-event';
    END IF;
    IF coalesce(NEW.comp_quantity, 0) > 0 THEN
      RAISE EXCEPTION 'a kiosk takes cards only' USING ERRCODE = '0A000', HINT = 'kiosk-card-only';
    END IF;
    NEW.channel := 'kiosk';
    NEW.kiosk_session_id := s.id;
  ELSE
    IF NEW.device_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_pos_kiosks k WHERE k.device_id = NEW.device_id) THEN
      RAISE EXCEPTION 'this device is a kiosk: it sells by card in kiosk mode only' USING ERRCODE = '0A000', HINT = 'kiosk-card-only';
    END IF;
    NEW.channel := 'door';
    NEW.kiosk_session_id := NULL;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_order_kiosk() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_orders_zkiosk ON public.exos_pos_orders;
CREATE TRIGGER exos_pos_orders_zkiosk BEFORE INSERT ON public.exos_pos_orders
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_order_kiosk();

-- ===========================================================================
-- 2. Patches: the channel on the order, card only, the settlement.
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public._exos_pos_order_json(uuid,uuid)',
  '/* exos: pos kiosk channel */',
  $o$'device_id', o.device_id, 'rung_by_me',$o$,
  $n$'device_id', o.device_id, /* exos: pos kiosk channel */ 'channel', o.channel, 'rung_by_me',$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_pos_walkup_complete(uuid,uuid,text,uuid,text)',
  '/* exos: pos kiosk card only */',
  $o$  IF o.status <> 'open' THEN
    RAISE EXCEPTION 'this sale was %', o.status USING ERRCODE = '55000';
  END IF;$o$,
  $n$  IF o.status <> 'open' THEN
    RAISE EXCEPTION 'this sale was %', o.status USING ERRCODE = '55000';
  END IF;
  /* exos: pos kiosk card only */ -- mig 20261113100000: a kiosk sale is paid by card, nothing else.
  IF o.channel = 'kiosk' AND lower(coalesce(p_payment, '')) <> 'card' THEN
    RAISE EXCEPTION 'a kiosk takes cards only' USING ERRCODE = '0A000', HINT = 'kiosk-card-only';
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_pos_settlement_summary(uuid)',
  '/* exos: pos kiosk settlement */',
  $o$'computed_at', now())$o$,
  $n$/* exos: pos kiosk settlement */ 'kiosk', (
             SELECT jsonb_build_object('orders', count(*),
                      'tickets', coalesce(sum((SELECT sum(l.quantity) FROM public.exos_pos_order_lines l
                                                WHERE l.order_id = k.id AND l.category = 'ticket')), 0),
                      'gross_cents', coalesce(sum(k.total_cents), 0))
               FROM public.exos_pos_orders k WHERE k.event_id = p_event_id AND k.channel = 'kiosk' AND k.status = 'paid'),
           'computed_at', now())$n$, 1);

-- ===========================================================================
-- 3. Setup (authenticated: owner / manager of the device's org).
-- ===========================================================================

-- A PIN an onlooker can't guess at once: 6 to 12 digits, not one digit
-- repeated, not a run up or down (123456, 987654).
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_pin_ok(p_pin text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT p_pin ~ '^[0-9]{6,12}$'
     AND p_pin !~ '^(.)\1+$'
     AND position(p_pin in '01234567890123456789') = 0
     AND position(p_pin in '98765432109876543210') = 0
$$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_pin_ok(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_pin_ok(text) TO service_role;

-- Mark a device as a kiosk for one event (or, p_event NULL, unmark it).
-- p_pin NULL keeps the current PIN (required the first time). Changing the
-- event ends the device's live session. Owner / manager of the org only (a
-- platform admin is not enough: a kiosk takes money for the org).
CREATE OR REPLACE FUNCTION public.exos_pos_kiosk_configure(
  p_device uuid, p_event uuid, p_reader uuid DEFAULT NULL, p_pin text DEFAULT NULL, p_printer boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  d     public.exos_pos_devices%ROWTYPE;
  k     public.exos_pos_kiosks%ROWTYPE;
  ev    public.exos_events%ROWTYPE;
  v_n   int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT * INTO d FROM public.exos_pos_devices WHERE id = p_device FOR UPDATE;
  IF d.id IS NULL OR coalesce(public._exos_member_role(d.org_id, v_uid), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'device not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT public.exos_rate_hit('pos:kiosk:cfg:' || v_uid::text, 20) THEN
    RAISE EXCEPTION 'too many kiosk changes a minute' USING ERRCODE = '54000';
  END IF;
  SELECT * INTO k FROM public.exos_pos_kiosks WHERE device_id = d.id FOR UPDATE;

  IF p_event IS NULL THEN
    IF k.device_id IS NULL THEN
      RETURN jsonb_build_object('device_id', d.id, 'kiosk', false);
    END IF;
    UPDATE public.exos_pos_kiosk_sessions SET ended_at = now(), ended_by = v_uid, ended_reason = 'off'
     WHERE device_id = d.id AND ended_at IS NULL;
    DELETE FROM public.exos_pos_kiosks WHERE device_id = d.id;
    /* exos: audit pos.kiosk_off */
    PERFORM public._exos_audit(d.org_id, 'pos.kiosk_off', 'pos_device', d.id::text, k.event_id,
                               jsonb_build_object('kiosk', jsonb_build_array(true, false)), NULL, NULL, NULL, v_uid, NULL, 'pos');
    RETURN jsonb_build_object('device_id', d.id, 'kiosk', false);
  END IF;

  IF d.kind NOT IN ('register', 'other') OR d.status <> 'active' THEN
    RAISE EXCEPTION 'a kiosk is an active register device' USING ERRCODE = '22023', HINT = 'kiosk-device';
  END IF;
  SELECT * INTO ev FROM public.exos_events WHERE id = p_event AND org_id = d.org_id;
  IF ev.id IS NULL THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF ev.status = 'cancelled' THEN
    RAISE EXCEPTION 'the event is cancelled' USING ERRCODE = '55000';
  END IF;
  IF d.event_id IS NOT NULL AND d.event_id <> ev.id THEN
    RAISE EXCEPTION 'this device is set to another event' USING ERRCODE = '22023', HINT = 'kiosk-device';
  END IF;
  IF p_reader IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_pos_terminal_readers r
         JOIN public.exos_pos_devices rd ON rd.id = r.device_id AND rd.org_id = r.org_id
        WHERE r.device_id = p_reader AND r.org_id = d.org_id AND r.status = 'active' AND rd.status = 'active'
          AND rd.kind = 'reader' AND (rd.event_id IS NULL OR rd.event_id = ev.id)) THEN
    RAISE EXCEPTION 'pick one of this organization''s card readers' USING ERRCODE = '22023', HINT = 'no-reader';
  END IF;
  IF p_pin IS NULL AND k.device_id IS NULL THEN
    RAISE EXCEPTION 'set an admin PIN for the kiosk' USING ERRCODE = '22023', HINT = 'pin-required';
  END IF;
  IF p_pin IS NOT NULL AND NOT public._exos_pos_kiosk_pin_ok(p_pin) THEN
    RAISE EXCEPTION 'the PIN is 6 to 12 digits, not one digit repeated or a run like 123456' USING ERRCODE = '22023', HINT = 'pin-weak';
  END IF;

  INSERT INTO public.exos_pos_kiosks (device_id, org_id, event_id, reader_device_id, printer, pin_hash, pin_set_at, configured_by)
  VALUES (d.id, d.org_id, ev.id, p_reader, coalesce(p_printer, false),
          CASE WHEN p_pin IS NULL THEN k.pin_hash ELSE extensions.crypt(p_pin, extensions.gen_salt('bf', 8)) END, now(), v_uid)
  ON CONFLICT (device_id) DO UPDATE
     SET event_id = EXCLUDED.event_id, reader_device_id = EXCLUDED.reader_device_id, printer = EXCLUDED.printer,
         configured_by = v_uid,
         pin_hash = CASE WHEN p_pin IS NULL THEN public.exos_pos_kiosks.pin_hash ELSE EXCLUDED.pin_hash END,
         pin_set_at = CASE WHEN p_pin IS NULL THEN public.exos_pos_kiosks.pin_set_at ELSE now() END,
         pin_failures = CASE WHEN p_pin IS NULL THEN public.exos_pos_kiosks.pin_failures ELSE 0 END,
         pin_locked_until = CASE WHEN p_pin IS NULL THEN public.exos_pos_kiosks.pin_locked_until END;
  -- Another event: the live session (locked to the old one) ends.
  IF k.device_id IS NOT NULL AND k.event_id <> ev.id THEN
    UPDATE public.exos_pos_kiosk_sessions SET ended_at = now(), ended_by = v_uid, ended_reason = 'reconfigured'
     WHERE device_id = d.id AND ended_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  /* exos: audit pos.kiosk_set */
  PERFORM public._exos_audit(d.org_id, 'pos.kiosk_set', 'pos_device', d.id::text, ev.id,
    jsonb_build_object('event_id', jsonb_build_array(k.event_id, ev.id),
                       'reader_device_id', jsonb_build_array(k.reader_device_id, p_reader),
                       'printer', jsonb_build_array(k.printer, coalesce(p_printer, false)),
                       'pin_changed', p_pin IS NOT NULL),
    NULL, NULL, NULL, v_uid, NULL, 'pos');
  RETURN jsonb_build_object('device_id', d.id, 'kiosk', true, 'event_id', ev.id, 'reader_device_id', p_reader,
                            'printer', coalesce(p_printer, false), 'sessions_ended', coalesce(v_n, 0));
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_kiosk_configure(uuid, uuid, uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_kiosk_configure(uuid, uuid, uuid, text, boolean) TO authenticated, service_role;

-- Start kiosk mode on this screen: the kiosk credential, shown once. The
-- device's earlier session (another browser) ends. Owner / manager only.
CREATE OR REPLACE FUNCTION public.exos_pos_kiosk_enter(p_device uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid   uuid := auth.uid();
  k       public.exos_pos_kiosks%ROWTYPE;
  d       public.exos_pos_devices%ROWTYPE;
  ev      public.exos_events%ROWTYPE;
  v_token text;
  v_id    uuid;
  v_exp   timestamptz := now() + interval '24 hours';
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT * INTO k FROM public.exos_pos_kiosks WHERE device_id = p_device FOR UPDATE;
  IF k.device_id IS NULL OR coalesce(public._exos_member_role(k.org_id, v_uid), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'this device isn''t a kiosk' USING ERRCODE = 'P0002';
  END IF;
  IF NOT public.exos_rate_hit('pos:kiosk:enter:' || v_uid::text, 10) THEN
    RAISE EXCEPTION 'too many kiosk starts a minute' USING ERRCODE = '54000';
  END IF;
  SELECT * INTO d FROM public.exos_pos_devices WHERE id = k.device_id;
  SELECT * INTO ev FROM public.exos_events WHERE id = k.event_id;
  IF d.status <> 'active' OR ev.status = 'cancelled' THEN
    RAISE EXCEPTION 'this kiosk can''t start: the device is off or the event is cancelled' USING ERRCODE = '55000';
  END IF;
  UPDATE public.exos_pos_kiosk_sessions SET ended_at = now(), ended_by = v_uid, ended_reason = 'replaced'
   WHERE device_id = k.device_id AND ended_at IS NULL;
  v_token := 'exk_' || encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.exos_pos_kiosk_sessions (org_id, event_id, device_id, token_hash, started_by, expires_at)
  VALUES (k.org_id, k.event_id, k.device_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), v_uid, v_exp)
  RETURNING id INTO v_id;
  /* exos: audit pos.kiosk_enter */
  PERFORM public._exos_audit(k.org_id, 'pos.kiosk_enter', 'pos_device', k.device_id::text, k.event_id,
                             jsonb_build_object('session_id', v_id), NULL, NULL, NULL, v_uid, NULL, 'pos');
  RETURN jsonb_build_object('token', v_token, 'session_id', v_id, 'device_id', k.device_id, 'event_id', k.event_id,
                            'expires_at', v_exp);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_kiosk_enter(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_kiosk_enter(uuid) TO authenticated, service_role;

-- End the device's kiosk session from the dashboard (a stolen or stuck
-- screen); the setup stays. Owner / manager only.
CREATE OR REPLACE FUNCTION public.exos_pos_kiosk_end(p_device uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); s public.exos_pos_kiosk_sessions%ROWTYPE; v_org uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT org_id INTO v_org FROM public.exos_pos_devices WHERE id = p_device;
  IF v_org IS NULL OR coalesce(public._exos_member_role(v_org, v_uid), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'device not found' USING ERRCODE = 'P0002';
  END IF;
  UPDATE public.exos_pos_kiosk_sessions SET ended_at = now(), ended_by = v_uid, ended_reason = 'staff'
   WHERE device_id = p_device AND ended_at IS NULL
  RETURNING * INTO s;
  IF s.id IS NOT NULL THEN
    /* exos: audit pos.kiosk_exit */
    PERFORM public._exos_audit(s.org_id, 'pos.kiosk_exit', 'pos_device', p_device::text, s.event_id,
                               jsonb_build_object('session_id', s.id, 'via', 'staff'), NULL, NULL, NULL, v_uid, NULL, 'pos');
  END IF;
  RETURN jsonb_build_object('device_id', p_device, 'ended', s.id IS NOT NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_kiosk_end(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_kiosk_end(uuid) TO authenticated, service_role;

-- ===========================================================================
-- 4. The kiosk's own calls (service role: exos-pos, with the credential).
-- ===========================================================================

-- The live session behind a credential, or 42501 'kiosk-ended'. Live: not
-- ended or expired, its kiosk still set to the same event and device, the
-- device active, the event not cancelled, and the member who started it
-- still an owner or manager of the org (they are the seller of record).
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_resolve(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.exos_pos_kiosk_sessions%ROWTYPE; k public.exos_pos_kiosks%ROWTYPE;
BEGIN
  IF p_token IS NULL OR p_token !~ '^exk_[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'this kiosk session has ended' USING ERRCODE = '42501', HINT = 'kiosk-ended';
  END IF;
  SELECT * INTO s FROM public.exos_pos_kiosk_sessions
   WHERE token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') AND ended_at IS NULL AND expires_at > now();
  SELECT * INTO k FROM public.exos_pos_kiosks WHERE device_id = s.device_id;
  IF s.id IS NULL OR k.device_id IS NULL OR k.event_id <> s.event_id
     OR NOT EXISTS (SELECT 1 FROM public.exos_pos_devices d WHERE d.id = s.device_id AND d.org_id = s.org_id AND d.status = 'active')
     OR NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = s.event_id AND e.org_id = s.org_id AND e.status <> 'cancelled')
     OR coalesce(public._exos_pos_actor_role(s.event_id, s.started_by, false), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'this kiosk session has ended' USING ERRCODE = '42501', HINT = 'kiosk-ended';
  END IF;
  UPDATE public.exos_pos_kiosk_sessions SET last_seen_at = now()
   WHERE id = s.id AND (last_seen_at IS NULL OR last_seen_at < now() - interval '30 seconds');
  RETURN jsonb_build_object('session_id', s.id, 'org_id', s.org_id, 'event_id', s.event_id, 'device_id', s.device_id,
                            'actor', s.started_by, 'reader_device_id', k.reader_device_id, 'printer', k.printer,
                            'expires_at', s.expires_at);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_resolve(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_resolve(text) TO service_role;

-- What a kiosk sells: the event's public ticket types (never a table, never
-- a hidden type) at the door price, with what's left.
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_tiers(p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(x.j ORDER BY x.sort_order, x.name), '[]'::jsonb) FROM (
    SELECT t.sort_order, t.name, jsonb_build_object(
             'tier_id', t.id, 'name', t.name, 'description', left(t.description, 300),
             'price_cents', (p.j ->> 'price_cents')::int, 'price_source', p.j ->> 'source',
             'step_name', p.j ->> 'step_name', 'step_remaining', (p.j ->> 'step_remaining')::int,
             'tax', CASE WHEN r.id IS NULL THEN NULL
                         ELSE jsonb_build_object('rate_percent', r.rate_percent, 'price_includes_tax', r.price_includes_tax) END,
             'unit_total_cents', CASE WHEN r.id IS NULL OR r.price_includes_tax THEN (p.j ->> 'price_cents')::int
                                      ELSE (p.j ->> 'price_cents')::int + public.exos_tax_cents((p.j ->> 'price_cents')::int, r.rate_percent, false) END,
             'remaining', CASE WHEN a.tier IS NULL AND a.house IS NULL THEN NULL
                               ELSE greatest(least(coalesce(a.tier, a.house), coalesce(a.house, a.tier)), 0) END) AS j
      FROM public.exos_ticket_tiers t
      CROSS JOIN LATERAL (SELECT public.exos_tier_current_price(t.id, now(), 'door') AS j) p
      LEFT JOIN public.exos_tax_rules r ON r.id = t.tax_rate_id
      CROSS JOIN LATERAL (SELECT public.exos_effective_available(t.id) AS tier,
                                 public.exos_event_house_available(t.event_id) / greatest(public.exos_tier_party_size(t.id), 1) AS house) a
     WHERE t.event_id = p_event AND coalesce(t.kind, '') <> 'table' AND coalesce(t.visibility, 'public') = 'public') x
$$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_tiers(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_tiers(uuid) TO service_role;

-- Tickets per order at a kiosk: the event's maxPerOrder, at most 10 (the
-- walk-up limit).
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_max(p_event uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT least(10, coalesce(CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$'
                                      AND (e.purchase_limits ->> 'maxPerOrder')::int > 0
                                 THEN (e.purchase_limits ->> 'maxPerOrder')::int END, 10))
    FROM public.exos_events e WHERE e.id = p_event
$$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_max(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_max(uuid) TO service_role;

-- The kiosk screen: the event, what it sells, the questions, the reader.
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_state(p_token text, p_live boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s jsonb; ev public.exos_events%ROWTYPE; v_reader jsonb; v_dev text;
BEGIN
  s := public._exos_pos_kiosk_resolve(p_token);
  IF NOT public.exos_rate_hit('pos:kiosk:state:' || (s ->> 'session_id'), 60) THEN
    RAISE EXCEPTION 'too many requests a minute' USING ERRCODE = '54000';
  END IF;
  SELECT * INTO ev FROM public.exos_events WHERE id = (s ->> 'event_id')::uuid;
  SELECT name INTO v_dev FROM public.exos_pos_devices WHERE id = (s ->> 'device_id')::uuid;
  SELECT jsonb_build_object('label', r.label,
           'ready', r.status = 'active' AND d.status = 'active' AND d.kind = 'reader'
                    AND (d.event_id IS NULL OR d.event_id = ev.id) AND r.livemode = coalesce(p_live, false))
    INTO v_reader
    FROM public.exos_pos_terminal_readers r JOIN public.exos_pos_devices d ON d.id = r.device_id AND d.org_id = r.org_id
   WHERE r.device_id = (s ->> 'reader_device_id')::uuid AND r.org_id = ev.org_id;
  RETURN jsonb_build_object(
    'kiosk', jsonb_build_object('session_id', s ->> 'session_id', 'device_id', s ->> 'device_id', 'device_name', v_dev,
                                'printer', (s ->> 'printer')::boolean, 'expires_at', s ->> 'expires_at'),
    'event', jsonb_build_object('id', ev.id, 'name', ev.name, 'starts_at', ev.starts_at, 'venue_name', ev.venue_name,
                                'currency', upper(coalesce(ev.currency, 'usd'))),
    'tiers', public._exos_pos_kiosk_tiers(ev.id),
    'questions', public._exos_question_defs(ev.id, true),
    'max_per_order', public._exos_pos_kiosk_max(ev.id),
    'reader', coalesce(v_reader, jsonb_build_object('label', NULL, 'ready', false)));
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_state(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_state(text, boolean) TO service_role;

-- Begin a kiosk sale: the card walk-up begin for the kiosk's event and device,
-- a public type, at most maxPerOrder, the required questions answered (never
-- skipped), no name or email (email comes after, if the buyer wants it). The
-- order key replays only this session's own sale.
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_begin(
  p_token text, p_tier uuid, p_quantity integer, p_order_key uuid, p_answers jsonb, p_live boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s jsonb; v_sess uuid; v_event uuid; o public.exos_pos_orders%ROWTYPE; v_max int; v_out jsonb;
BEGIN
  s := public._exos_pos_kiosk_resolve(p_token);
  v_sess := (s ->> 'session_id')::uuid;
  v_event := (s ->> 'event_id')::uuid;
  IF p_order_key IS NULL THEN
    RAISE EXCEPTION 'an order key is required (a new UUID per sale)' USING ERRCODE = '22023';
  END IF;
  -- The walk-up's own key lock, taken first: a key is one session's sale.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_pos_key:' || p_order_key::text, 0));
  SELECT * INTO o FROM public.exos_pos_orders WHERE client_ref = p_order_key;
  IF o.id IS NOT NULL AND o.kiosk_session_id IS DISTINCT FROM v_sess THEN
    RAISE EXCEPTION 'this order key was already used for another sale' USING ERRCODE = '23505';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers t
                  WHERE t.id = p_tier AND t.event_id = v_event AND coalesce(t.kind, '') <> 'table'
                    AND coalesce(t.visibility, 'public') = 'public') THEN
    RAISE EXCEPTION 'ticket type not found' USING ERRCODE = 'P0002';
  END IF;
  v_max := public._exos_pos_kiosk_max(v_event);
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > v_max THEN
    RAISE EXCEPTION 'pick 1 to % tickets', v_max USING ERRCODE = '22023', HINT = 'max-per-order';
  END IF;
  PERFORM set_config('exos.pos_kiosk_session', v_sess::text, true);
  v_out := public._exos_pos_walkup_begin_card((s ->> 'actor')::uuid, v_event, p_tier, p_quantity, p_order_key,
                                              (s ->> 'device_id')::uuid, NULL, NULL, p_answers, p_live, false);
  PERFORM set_config('exos.pos_kiosk_session', '', true);
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_begin(text, uuid, integer, uuid, jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_begin(text, uuid, integer, uuid, jsonb, boolean) TO service_role;

-- This session's own order, or 'order not found'.
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_order(p_session uuid, p_order uuid)
RETURNS public.exos_pos_orders LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order AND channel = 'kiosk' AND kiosk_session_id = p_session;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN o;
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_order(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_order(uuid, uuid) TO service_role;

-- Charge the pending sale on the kiosk's own reader (never another).
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_charge(p_token text, p_order uuid, p_live boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s jsonb; o public.exos_pos_orders%ROWTYPE;
BEGIN
  s := public._exos_pos_kiosk_resolve(p_token);
  o := public._exos_pos_kiosk_order((s ->> 'session_id')::uuid, p_order);
  IF NOT public.exos_rate_hit('pos:kiosk:charge:' || (s ->> 'session_id'), 10) THEN
    RAISE EXCEPTION 'too many card charges a minute' USING ERRCODE = '54000';
  END IF;
  IF s ->> 'reader_device_id' IS NULL THEN
    RAISE EXCEPTION 'this kiosk has no card reader' USING ERRCODE = '55000', HINT = 'no-reader';
  END IF;
  RETURN public._exos_pos_card_begin((s ->> 'actor')::uuid, o.id, 'reader', (s ->> 'reader_device_id')::uuid, p_live);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_charge(text, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_charge(text, uuid, boolean) TO service_role;

-- Poll or cancel this session's card sale (the card lookup, as its seller).
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_lookup(p_token text, p_order uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s jsonb; o public.exos_pos_orders%ROWTYPE;
BEGIN
  s := public._exos_pos_kiosk_resolve(p_token);
  o := public._exos_pos_kiosk_order((s ->> 'session_id')::uuid, p_order);
  IF NOT public.exos_rate_hit('pos:kiosk:poll:' || (s ->> 'session_id'), 90) THEN
    RAISE EXCEPTION 'too many requests a minute' USING ERRCODE = '54000';
  END IF;
  RETURN public._exos_pos_card_lookup((s ->> 'actor')::uuid, o.id, 'act', false);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_lookup(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_lookup(text, uuid) TO service_role;

-- A paid kiosk sale, for its hand-over: this session's, paid in the last 10
-- minutes (the screen resets long before; a later buyer can't call it back).
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_paid(p_session uuid, p_order uuid)
RETURNS public.exos_pos_orders LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE;
BEGIN
  o := public._exos_pos_kiosk_order(p_session, p_order);
  IF o.status <> 'paid' THEN
    RAISE EXCEPTION 'this sale is %', CASE WHEN o.status = 'open' THEN 'pending' ELSE o.status END USING ERRCODE = '55000';
  END IF;
  IF o.paid_at < now() - interval '10 minutes' THEN
    RAISE EXCEPTION 'this sale can no longer be handed over here: ask the staff' USING ERRCODE = '55000', HINT = 'kiosk-too-late';
  END IF;
  RETURN o;
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_paid(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_paid(uuid, uuid) TO service_role;

-- The ticket QR codes on screen (print codes, as the Sell tab's), and paper
-- from the same codes when the kiosk has a printer.
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_codes(p_token text, p_order uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s jsonb; o public.exos_pos_orders%ROWTYPE; v_ids uuid[];
BEGIN
  s := public._exos_pos_kiosk_resolve(p_token);
  o := public._exos_pos_kiosk_paid((s ->> 'session_id')::uuid, p_order);
  IF NOT public.exos_rate_hit('pos:kiosk:codes:' || (s ->> 'session_id'), 10) THEN
    RAISE EXCEPTION 'too many requests a minute' USING ERRCODE = '54000';
  END IF;
  SELECT array_agg(t.id) INTO v_ids
    FROM public.exos_pos_order_lines l
    CROSS JOIN LATERAL unnest(coalesce(l.ticket_ids, '{}'::uuid[])) x(id)
    JOIN public.exos_tickets t ON t.id = x.id
   WHERE l.order_id = o.id AND t.status = 'active' AND t.check_in_at IS NULL AND t.owner_id = o.rung_by;
  IF v_ids IS NULL THEN
    RAISE EXCEPTION 'these tickets were already handed over, claimed or scanned' USING ERRCODE = '55000', HINT = 'handed-over';
  END IF;
  RETURN public._exos_print_mint(o.org_id, (s ->> 'actor')::uuid, v_ids, 'pos', NULL, true);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_codes(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_codes(text, uuid) TO service_role;

-- "Email it to me": queued mail (an account or a claim link), as the Sell tab's.
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_email(p_token text, p_order uuid, p_email text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s jsonb; o public.exos_pos_orders%ROWTYPE; v_n int;
BEGIN
  s := public._exos_pos_kiosk_resolve(p_token);
  o := public._exos_pos_kiosk_paid((s ->> 'session_id')::uuid, p_order);
  IF NOT public.exos_rate_hit('pos:kiosk:mail:' || (s ->> 'session_id'), 6) THEN
    RAISE EXCEPTION 'too many emails a minute' USING ERRCODE = '54000';
  END IF;
  PERFORM 1 FROM public.exos_pos_orders WHERE id = o.id FOR UPDATE;
  v_n := public._exos_pos_deliver_email(o.id, (s ->> 'actor')::uuid, p_email, false);
  RETURN jsonb_build_object('order_id', o.id, 'emailed', v_n);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_email(text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_email(text, uuid, text) TO service_role;

-- Leave kiosk mode with the admin PIN. Answers (never raises for a wrong PIN,
-- so the failure count and the rate limit stick):
--   { ok: true, actor, pending }         the session ended (audited); pending =
--                                        its card sales still open (exos-pos
--                                        cancels them, and answers { ok: true })
--   { ok: true, ended: true }            nothing to leave (no live session)
--   { ok: false, error: 'wrong-pin', attempts_left }
--   { ok: false, error: 'locked', retry_after_seconds }   5 wrong in a row: 5 minutes
--   { ok: false, error: 'rate' }         more than 10 tries a minute
CREATE OR REPLACE FUNCTION public._exos_pos_kiosk_exit(p_token text, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.exos_pos_kiosk_sessions%ROWTYPE; k public.exos_pos_kiosks%ROWTYPE; v_fail int;
BEGIN
  IF p_token IS NULL OR p_token !~ '^exk_[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', true, 'ended', true);
  END IF;
  SELECT * INTO s FROM public.exos_pos_kiosk_sessions
   WHERE token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') AND ended_at IS NULL AND expires_at > now()
   FOR UPDATE;
  IF s.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'ended', true);
  END IF;
  SELECT * INTO k FROM public.exos_pos_kiosks WHERE device_id = s.device_id FOR UPDATE;
  IF k.device_id IS NULL OR k.event_id <> s.event_id THEN
    UPDATE public.exos_pos_kiosk_sessions SET ended_at = now(), ended_reason = 'off' WHERE id = s.id;
    RETURN jsonb_build_object('ok', true, 'ended', true);
  END IF;
  IF k.pin_locked_until > now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'locked',
                              'retry_after_seconds', ceil(extract(epoch FROM k.pin_locked_until - now()))::int);
  END IF;
  IF NOT public.exos_rate_hit('pos:kiosk:pin:' || k.device_id::text, 10) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate');
  END IF;
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{1,12}$' OR extensions.crypt(p_pin, k.pin_hash) <> k.pin_hash THEN
    v_fail := k.pin_failures + 1;
    IF v_fail >= 5 THEN
      UPDATE public.exos_pos_kiosks SET pin_failures = 0, pin_locked_until = now() + interval '5 minutes'
       WHERE device_id = k.device_id;
      /* exos: audit pos.kiosk_lockout */
      PERFORM public._exos_audit(k.org_id, 'pos.kiosk_lockout', 'pos_device', k.device_id::text, k.event_id,
                                 jsonb_build_object('session_id', s.id, 'failures', v_fail), NULL, NULL,
                                 'wrong kiosk PIN 5 times', NULL, NULL, 'pos');
      RETURN jsonb_build_object('ok', false, 'error', 'locked', 'retry_after_seconds', 300);
    END IF;
    UPDATE public.exos_pos_kiosks SET pin_failures = v_fail WHERE device_id = k.device_id;
    RETURN jsonb_build_object('ok', false, 'error', 'wrong-pin', 'attempts_left', 5 - v_fail);
  END IF;
  UPDATE public.exos_pos_kiosks SET pin_failures = 0, pin_locked_until = NULL WHERE device_id = k.device_id;
  UPDATE public.exos_pos_kiosk_sessions SET ended_at = now(), ended_reason = 'pin' WHERE id = s.id;
  /* exos: audit pos.kiosk_exit */
  PERFORM public._exos_audit(k.org_id, 'pos.kiosk_exit', 'pos_device', k.device_id::text, k.event_id,
                             jsonb_build_object('session_id', s.id, 'via', 'pin'), NULL, NULL, NULL, NULL, NULL, 'pos');
  -- A card sale still pending on this screen: exos-pos cancels it on the
  -- reader (as its seller), then answers the kiosk { ok: true } only.
  RETURN jsonb_build_object('ok', true, 'actor', s.started_by,
    'pending', (SELECT coalesce(jsonb_agg(o.id ORDER BY o.created_at), '[]'::jsonb) FROM public.exos_pos_orders o
                 WHERE o.kiosk_session_id = s.id AND o.status = 'open'));
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_kiosk_exit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_kiosk_exit(text, text) TO service_role;
