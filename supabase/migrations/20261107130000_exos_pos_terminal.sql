-- ============================================================================
-- Migration 20261107130000 — Exos: card at the door (Stripe Terminal)
-- Branch:   claude/exos-pos-terminal
-- Touches:  C: TABLE exos_pos_terminal_locations (one Stripe Terminal Location
--              per org and mode), exos_pos_terminal_readers (readers we
--              registered), exos_pos_card_payments (one card attempt per
--              walk-up order: the PaymentIntent, its state, the fee split).
--              RLS: reads only (owner / manager / finance; door staff for
--              readers and their event's card attempts); no client writes.
--           W: TABLE exos_pos_reversals (card_cents may be > 0; +card_payment_intent,
--              card_refund_ref, card_refund_status, card_refund_error)
--           C: FUNCTION exos_pos_card_readers (authenticated, door staff);
--              _exos_pos_connected_account, _exos_pos_card_json,
--              _exos_pos_terminal_manage_check, _exos_pos_terminal_save_location,
--              _exos_pos_terminal_save_reader, _exos_pos_terminal_token_check,
--              _exos_pos_walkup_begin_card, _exos_pos_card_begin,
--              _exos_pos_card_attach, _exos_pos_card_lookup,
--              _exos_pos_card_capture_prepare, _exos_pos_card_complete,
--              _exos_pos_card_fail, _exos_pos_card_reverse,
--              _exos_pos_card_refund_record (service role only: exos-pos and
--              stripe-webhook call them; each checks the actor's role itself)
--           W: FUNCTION _exos_pos_walkup_complete (markers
--              /* exos: pos terminal card */, /* exos: pos terminal card tender */),
--              _exos_pos_reverse (marker /* exos: pos terminal card reverse */)
-- Pre-reqs: 20260929074000 (POS scaffold), 20261107100000 (walk-up sales).
--
-- docs/pos.md "Card at the door". The card path is the walk-up sale's two
-- steps with a Stripe PaymentIntent in the middle:
--   begin    _exos_pos_walkup_begin_card: the walk-up begin (reserve, door
--            price, order key), a 5-minute reservation, and an 'awaiting'
--            card row. No comps on a card sale; a $0 sale is cash.
--   charge   _exos_pos_card_begin (role, rate limit, the reader is the org's,
--            places still held, payment setup done) -> exos-pos creates a
--            card_present PaymentIntent (manual capture, destination charge
--            to the org's connected account with the application fee, like
--            exos-checkout), _exos_pos_card_attach records it, then the
--            reader is told to collect it (or the SDK gets its client secret).
--   capture  _exos_pos_card_capture_prepare decides capture / done / cancel
--            under the order lock (places still held, extended 2 minutes);
--            exos-pos (or the webhook) captures, then _exos_pos_card_complete
--            calls the walk-up complete with the PaymentIntent as the card
--            tender's terminal_ref. Idempotent on the order: a second
--            completion (door vs webhook) is a replay. A capture that can't
--            be fulfilled is marked refund_pending and refunded in full.
--   fail     _exos_pos_card_fail: a decline or cancel cancels the order
--            (places back); never after money was taken.
--   refund   _exos_pos_card_reverse: the walk-up void / refund rules
--            (_exos_pos_reverse), then the card part on the reversal ledger
--            row as a pending refund; exos-pos refunds at Stripe and
--            _exos_pos_card_refund_record stores the answer.
-- No card data, ever: the only card references are the PaymentIntent id
-- (exos_pos_payments.terminal_ref, exos_pos_card_payments.payment_intent_id)
-- and Stripe's decline code. EXOS_POS_CARD=on in exos-pos is the switch; the
-- SQL is reachable through the service role only.
--
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked
-- patches). D4 authors; not applied.
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

-- One Stripe Terminal Location per org and mode (test / live objects differ).
-- Under destination charges it lives on the PLATFORM account, like the
-- PaymentIntents; readers register to it and connection tokens are scoped to it.
CREATE TABLE IF NOT EXISTS public.exos_pos_terminal_locations (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  livemode           boolean     NOT NULL DEFAULT false,
  stripe_location_id text        NOT NULL UNIQUE CHECK (stripe_location_id ~ '^tml_[A-Za-z0-9]{1,250}$'),
  display_name       text        NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 100),
  address            jsonb       NOT NULL CHECK (jsonb_typeof(address) = 'object' AND octet_length(address::text) <= 2000),
  created_by         uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, livemode)
);

-- Readers Exos registered (by their registration code). The device row
-- (exos_pos_devices kind 'reader', hardware_ref = the reader id) is what the
-- door picks; this row is the proof the reader is ours and the org's: a
-- device row an owner edits by hand can't point a charge at another reader.
CREATE TABLE IF NOT EXISTS public.exos_pos_terminal_readers (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  device_id        uuid        NOT NULL UNIQUE REFERENCES public.exos_pos_devices (id) ON DELETE CASCADE,
  location_id      uuid        NOT NULL REFERENCES public.exos_pos_terminal_locations (id) ON DELETE CASCADE,
  livemode         boolean     NOT NULL DEFAULT false,
  stripe_reader_id text        NOT NULL UNIQUE CHECK (stripe_reader_id ~ '^tmr_[A-Za-z0-9]{1,250}$'),
  device_type      text        CHECK (device_type IS NULL OR device_type ~ '^[a-z0-9_]{1,40}$'),
  label            text        NOT NULL CHECK (char_length(btrim(label)) BETWEEN 1 AND 80),
  status           text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'retired')),
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_pos_terminal_readers_org_idx ON public.exos_pos_terminal_readers (org_id, status);

-- One card attempt per walk-up order.
--   awaiting    the sale is pending, no PaymentIntent yet
--   processing  the PaymentIntent exists (on the reader, or with the SDK)
--   capturing   authorized; the capture is under way
--   succeeded   captured and the sale completed (the card tender exists)
--   declined / canceled   nothing taken; the order was cancelled
--   refund_pending / refunded   captured but the sale couldn't complete: the
--                               whole charge goes back (never a silent charge)
CREATE TABLE IF NOT EXISTS public.exos_pos_card_payments (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id              uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  order_id              uuid        NOT NULL UNIQUE REFERENCES public.exos_pos_orders (id) ON DELETE CASCADE,
  mode                  text        NOT NULL DEFAULT 'reader' CHECK (mode IN ('reader', 'sdk')),
  reader_device_id      uuid        REFERENCES public.exos_pos_devices (id) ON DELETE SET NULL,
  livemode              boolean     NOT NULL DEFAULT false,
  payment_intent_id     text        UNIQUE CHECK (payment_intent_id IS NULL OR payment_intent_id ~ '^pi_[A-Za-z0-9]{1,250}$'),
  amount_cents          integer     NOT NULL CHECK (amount_cents > 0 AND amount_cents <= 10000000),
  currency              text        NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  application_fee_cents integer     CHECK (application_fee_cents IS NULL OR application_fee_cents >= 0),
  exos_fee_cents        integer     CHECK (exos_fee_cents IS NULL OR exos_fee_cents >= 0),
  card_fee_est_cents    integer     CHECK (card_fee_est_cents IS NULL OR card_fee_est_cents >= 0),
  fee_bps               integer     CHECK (fee_bps IS NULL OR fee_bps BETWEEN 0 AND 10000),
  status                text        NOT NULL DEFAULT 'awaiting' CHECK (status IN (
                          'awaiting', 'processing', 'capturing', 'succeeded', 'declined', 'canceled',
                          'refund_pending', 'refunded')),
  decline_code          text        CHECK (decline_code IS NULL OR decline_code ~ '^[a-z0-9_]{1,64}$'),
  completed_via         text        CHECK (completed_via IS NULL OR completed_via IN ('door', 'webhook')),
  stripe_event_id       text        CHECK (stripe_event_id IS NULL OR stripe_event_id ~ '^evt_[A-Za-z0-9]{1,250}$'),
  refund_ref            text        CHECK (refund_ref IS NULL OR refund_ref ~ '^re_[A-Za-z0-9]{1,250}$'),
  note                  text        CHECK (note IS NULL OR char_length(note) <= 300),
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_pos_card_payments_event_idx ON public.exos_pos_card_payments (event_id, status);

-- The reversal ledger now carries the card part of a void / refund.
ALTER TABLE public.exos_pos_reversals DROP CONSTRAINT IF EXISTS exos_pos_reversals_card_cents_check;
ALTER TABLE public.exos_pos_reversals ADD CONSTRAINT exos_pos_reversals_card_cents_check CHECK (card_cents >= 0);
ALTER TABLE public.exos_pos_reversals
  ADD COLUMN IF NOT EXISTS card_payment_intent text CHECK (card_payment_intent IS NULL OR card_payment_intent ~ '^pi_[A-Za-z0-9]{1,250}$'),
  ADD COLUMN IF NOT EXISTS card_refund_ref     text CHECK (card_refund_ref IS NULL OR card_refund_ref ~ '^re_[A-Za-z0-9]{1,250}$'),
  ADD COLUMN IF NOT EXISTS card_refund_status  text CHECK (card_refund_status IS NULL OR card_refund_status IN ('pending', 'succeeded', 'failed', 'canceled')),
  ADD COLUMN IF NOT EXISTS card_refund_error   text CHECK (card_refund_error IS NULL OR char_length(card_refund_error) <= 300);

DROP TRIGGER IF EXISTS exos_pos_terminal_locations_touch ON public.exos_pos_terminal_locations;
CREATE TRIGGER exos_pos_terminal_locations_touch BEFORE UPDATE ON public.exos_pos_terminal_locations
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_pos_terminal_readers_touch ON public.exos_pos_terminal_readers;
CREATE TRIGGER exos_pos_terminal_readers_touch BEFORE UPDATE ON public.exos_pos_terminal_readers
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_pos_card_payments_touch ON public.exos_pos_card_payments;
CREATE TRIGGER exos_pos_card_payments_touch BEFORE UPDATE ON public.exos_pos_card_payments
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_pos_terminal_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_terminal_readers   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_card_payments      ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_pos_terminal_locations, public.exos_pos_terminal_readers, public.exos_pos_card_payments
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_pos_terminal_locations, public.exos_pos_terminal_readers, public.exos_pos_card_payments TO service_role;
GRANT SELECT ON public.exos_pos_terminal_locations, public.exos_pos_terminal_readers, public.exos_pos_card_payments TO authenticated;
DROP POLICY IF EXISTS exos_pos_terminal_locations_sel ON public.exos_pos_terminal_locations;
CREATE POLICY exos_pos_terminal_locations_sel ON public.exos_pos_terminal_locations FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
DROP POLICY IF EXISTS exos_pos_terminal_readers_sel ON public.exos_pos_terminal_readers;
CREATE POLICY exos_pos_terminal_readers_sel ON public.exos_pos_terminal_readers FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance', 'scanner']));
DROP POLICY IF EXISTS exos_pos_card_payments_sel ON public.exos_pos_card_payments;
CREATE POLICY exos_pos_card_payments_sel ON public.exos_pos_card_payments FOR SELECT TO authenticated
  USING (public.exos_pos_can_ring(event_id) OR public.exos_has_org_role(org_id, ARRAY['finance']));
COMMENT ON TABLE public.exos_pos_terminal_locations IS
  'Stripe Terminal Location per org and mode, on the platform account (mig 20261107130000). Written by functions only.';
COMMENT ON TABLE public.exos_pos_terminal_readers IS
  'Stripe Terminal readers Exos registered for an org (mig 20261107130000). Written by functions only.';
COMMENT ON TABLE public.exos_pos_card_payments IS
  'One card attempt (PaymentIntent) per walk-up order (mig 20261107130000). No card data. Written by functions only.';

-- ===========================================================================
-- 2. Helpers (service role only).
-- ===========================================================================

-- The org's connected account when charges are enabled, else NULL. The
-- phase-1 secrets table (prod) holds it; without it, NULL.
CREATE OR REPLACE FUNCTION public._exos_pos_connected_account(p_org uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF to_regclass('public.exos_org_secrets') IS NULL THEN
    RETURN NULL;
  END IF;
  EXECUTE 'SELECT payments FROM public.exos_org_secrets WHERE org_id = $1' INTO v USING p_org;
  IF v IS NOT NULL AND v -> 'chargesEnabled' = 'true'::jsonb
     AND coalesce(v ->> 'connectedAccountId', '') ~ '^acct_[A-Za-z0-9]{1,250}$' THEN
    RETURN v ->> 'connectedAccountId';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_connected_account(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_connected_account(uuid) TO service_role;

-- A card attempt as the door app sees it (never the connected account).
CREATE OR REPLACE FUNCTION public._exos_pos_card_json(p_order uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('status', c.status, 'mode', c.mode, 'reader_device_id', c.reader_device_id,
                            'payment_intent', c.payment_intent_id, 'amount_cents', c.amount_cents,
                            'currency', c.currency, 'decline_code', c.decline_code, 'completed_via', c.completed_via)
    FROM public.exos_pos_card_payments c WHERE c.order_id = p_order
$$;
REVOKE ALL ON FUNCTION public._exos_pos_card_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_json(uuid) TO service_role;

-- ===========================================================================
-- 3. Locations, readers, connection tokens (exos-pos calls these BEFORE any
--    Stripe call: the role and the rate limit come first).
-- ===========================================================================

-- Owner / manager of the org (a platform admin is not enough: readers take
-- money for the org). Returns the org's location in this mode, if any.
CREATE OR REPLACE FUNCTION public._exos_pos_terminal_manage_check(p_actor uuid, p_org uuid, p_live boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE l public.exos_pos_terminal_locations%ROWTYPE; v_name text;
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = p_org AND m.user_id = p_actor AND m.disabled IS NOT TRUE AND m.role IN ('owner', 'manager')) THEN
    RAISE EXCEPTION 'only an owner or manager sets up card readers' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('pos:terminal:' || p_actor::text, 10) THEN
    RAISE EXCEPTION 'too many reader changes a minute' USING ERRCODE = '54000';
  END IF;
  IF public._exos_pos_connected_account(p_org) IS NULL THEN
    RAISE EXCEPTION 'finish payment setup (Stripe) before adding a card reader' USING ERRCODE = '55000', HINT = 'card-setup';
  END IF;
  SELECT name INTO v_name FROM public.exos_orgs WHERE id = p_org;
  SELECT * INTO l FROM public.exos_pos_terminal_locations WHERE org_id = p_org AND livemode = coalesce(p_live, false);
  RETURN jsonb_build_object('org_id', p_org, 'org_name', v_name,
                            'location', CASE WHEN l.id IS NULL THEN NULL ELSE jsonb_build_object(
                              'id', l.id, 'stripe_location_id', l.stripe_location_id, 'display_name', l.display_name) END);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_terminal_manage_check(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_terminal_manage_check(uuid, uuid, boolean) TO service_role;

-- Store the location Stripe created (idempotency key per org and mode, so two
-- racing creates get the same one). The first stored wins.
CREATE OR REPLACE FUNCTION public._exos_pos_terminal_save_location(
  p_actor uuid, p_org uuid, p_live boolean, p_stripe_location text, p_display text, p_address jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE l public.exos_pos_terminal_locations%ROWTYPE;
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = p_org AND m.user_id = p_actor AND m.disabled IS NOT TRUE AND m.role IN ('owner', 'manager')) THEN
    RAISE EXCEPTION 'only an owner or manager sets up card readers' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_pos_terminal_locations (org_id, livemode, stripe_location_id, display_name, address, created_by)
  VALUES (p_org, coalesce(p_live, false), p_stripe_location, left(btrim(p_display), 100), p_address, p_actor)
  ON CONFLICT (org_id, livemode) DO NOTHING;
  SELECT * INTO l FROM public.exos_pos_terminal_locations WHERE org_id = p_org AND livemode = coalesce(p_live, false);
  RETURN jsonb_build_object('id', l.id, 'stripe_location_id', l.stripe_location_id, 'display_name', l.display_name,
                            'address', l.address, 'livemode', l.livemode);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_terminal_save_location(uuid, uuid, boolean, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_terminal_save_location(uuid, uuid, boolean, text, text, jsonb) TO service_role;

-- Store a reader Stripe registered to the org's location: a device row (kind
-- 'reader', active, hardware_ref = the reader id) and the reader row.
-- Idempotent on the reader id for the same org; another org's reader id is
-- refused without saying whose it is.
CREATE OR REPLACE FUNCTION public._exos_pos_terminal_save_reader(
  p_actor uuid, p_org uuid, p_live boolean, p_stripe_reader text, p_label text, p_device_type text, p_event uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  l      public.exos_pos_terminal_locations%ROWTYPE;
  r      public.exos_pos_terminal_readers%ROWTYPE;
  v_dev  uuid;
  v_label text := left(nullif(btrim(coalesce(p_label, '')), ''), 80);
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = p_org AND m.user_id = p_actor AND m.disabled IS NOT TRUE AND m.role IN ('owner', 'manager')) THEN
    RAISE EXCEPTION 'only an owner or manager sets up card readers' USING ERRCODE = '42501';
  END IF;
  IF p_event IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO l FROM public.exos_pos_terminal_locations WHERE org_id = p_org AND livemode = coalesce(p_live, false);
  IF l.id IS NULL THEN
    RAISE EXCEPTION 'set up the card location first' USING ERRCODE = '55000', HINT = 'no-location';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_pos_reader:' || coalesce(p_stripe_reader, ''), 0));
  SELECT * INTO r FROM public.exos_pos_terminal_readers WHERE stripe_reader_id = p_stripe_reader;
  IF r.id IS NOT NULL THEN
    IF r.org_id <> p_org THEN
      RAISE EXCEPTION 'that reader is already registered' USING ERRCODE = '23505';
    END IF;
  ELSE
    INSERT INTO public.exos_pos_devices (org_id, event_id, name, kind, status, hardware_ref, registered_by)
    VALUES (p_org, p_event, coalesce(v_label, 'Card reader'), 'reader', 'active', p_stripe_reader, p_actor)
    RETURNING id INTO v_dev;
    INSERT INTO public.exos_pos_terminal_readers (org_id, device_id, location_id, livemode, stripe_reader_id, device_type, label, created_by)
    VALUES (p_org, v_dev, l.id, coalesce(p_live, false), p_stripe_reader,
            CASE WHEN lower(coalesce(p_device_type, '')) ~ '^[a-z0-9_]{1,40}$' THEN lower(p_device_type) END,
            coalesce(v_label, 'Card reader'), p_actor)
    RETURNING * INTO r;
  END IF;
  RETURN jsonb_build_object('device_id', r.device_id, 'label', r.label, 'device_type', r.device_type,
                            'status', r.status, 'livemode', r.livemode);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_terminal_save_reader(uuid, uuid, boolean, text, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_terminal_save_reader(uuid, uuid, boolean, text, text, text, uuid) TO service_role;

-- A connection token (Terminal SDK): door staff of the event, scoped to the
-- event's org's location in this mode.
CREATE OR REPLACE FUNCTION public._exos_pos_terminal_token_check(p_actor uuid, p_event uuid, p_live boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid; l public.exos_pos_terminal_locations%ROWTYPE;
BEGIN
  IF p_actor IS NULL OR public._exos_pos_actor_role(p_event, p_actor, false) IS NULL THEN
    RAISE EXCEPTION 'not authorized at this event' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('pos:conntoken:' || p_actor::text, 30) THEN
    RAISE EXCEPTION 'too many reader connections a minute' USING ERRCODE = '54000';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event;
  SELECT * INTO l FROM public.exos_pos_terminal_locations WHERE org_id = v_org AND livemode = coalesce(p_live, false);
  IF l.id IS NULL THEN
    RAISE EXCEPTION 'card at the door isn''t set up for this organization yet' USING ERRCODE = '55000', HINT = 'no-location';
  END IF;
  RETURN jsonb_build_object('location_id', l.stripe_location_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_terminal_token_check(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_terminal_token_check(uuid, uuid, boolean) TO service_role;

-- The readers the Sell tab may charge on (door staff of the event): the
-- org's active readers, org-wide or set to this event. Never another org's.
CREATE OR REPLACE FUNCTION public.exos_pos_card_readers(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_role text; v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  v_role := public._exos_pos_actor_role(p_event_id, auth.uid(), public.exos_is_admin());
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not authorized at this event' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  RETURN jsonb_build_object(
    'can_manage', v_role IN ('owner', 'manager'),
    'locations', (SELECT coalesce(jsonb_agg(jsonb_build_object('livemode', l.livemode, 'display_name', l.display_name)), '[]'::jsonb)
                    FROM public.exos_pos_terminal_locations l WHERE l.org_id = v_org),
    'readers', (SELECT coalesce(jsonb_agg(jsonb_build_object('device_id', r.device_id, 'label', r.label,
                                                             'device_type', r.device_type, 'livemode', r.livemode)
                                          ORDER BY r.label, r.device_id), '[]'::jsonb)
                  FROM public.exos_pos_terminal_readers r
                  JOIN public.exos_pos_devices d ON d.id = r.device_id AND d.org_id = r.org_id
                 WHERE r.org_id = v_org AND r.status = 'active' AND d.status = 'active'
                   AND (d.event_id IS NULL OR d.event_id = p_event_id)));
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_card_readers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_card_readers(uuid) TO authenticated, service_role;

-- ===========================================================================
-- 4. The walk-up complete takes a card tender, and the reversal a card part,
--    only from these functions (a session setting the service-role cores
--    set; never reachable from a client).
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public._exos_pos_walkup_complete(uuid,uuid,text,uuid,text)',
  '/* exos: pos terminal card */',
  $o$  IF lower(coalesce(p_payment, '')) = 'card' THEN
    RAISE EXCEPTION 'card at the door isn''t connected yet: take cash, or comp it' USING ERRCODE = '0A000', HINT = 'card-not-connected';
  END IF;$o$,
  $n$  /* exos: pos terminal card */ -- mig 20261107130000: a card tender comes only from
  -- _exos_pos_card_complete, which sets exos.pos_card_ref to the captured PaymentIntent.
  IF lower(coalesce(p_payment, '')) = 'card' AND nullif(current_setting('exos.pos_card_ref', true), '') IS NULL THEN
    RAISE EXCEPTION 'card at the door isn''t connected yet: take cash, or comp it' USING ERRCODE = '0A000', HINT = 'card-not-connected';
  END IF;$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_pos_walkup_complete(uuid,uuid,text,uuid,text)',
  '/* exos: pos terminal card tender */',
  $o$  IF v_cash > 0 AND p_drawer IS NULL THEN$o$,
  $n$  /* exos: pos terminal card tender */ -- mig 20261107130000: the card pays what cash would.
  IF v_cash > 0 AND lower(coalesce(p_payment, '')) = 'card' THEN
    INSERT INTO public.exos_pos_payments (order_id, org_id, event_id, method, amount_cents, terminal_ref, taken_by)
    VALUES (o.id, o.org_id, o.event_id, 'card', v_cash, current_setting('exos.pos_card_ref', true), p_actor);
    v_cash := 0;
  END IF;
  IF v_cash > 0 AND p_drawer IS NULL THEN$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_pos_reverse(uuid,boolean,uuid,uuid,uuid,text,text,boolean,uuid,uuid)',
  '/* exos: pos terminal card reverse */',
  $o$  IF v_card > 0 THEN
    RAISE EXCEPTION 'card refunds at the door aren''t connected yet' USING ERRCODE = '0A000', HINT = 'card-not-connected';
  END IF;$o$,
  $n$  /* exos: pos terminal card reverse */ -- mig 20261107130000: a card sale is reversed only
  -- through _exos_pos_card_reverse (exos-pos), which refunds the card at Stripe.
  IF v_card > 0 AND coalesce(current_setting('exos.pos_card_reverse', true), '') <> 'on' THEN
    RAISE EXCEPTION 'a card sale is refunded to the card from the door app' USING ERRCODE = '0A000', HINT = 'card-refund-in-app';
  END IF;$n$, 1);

-- ===========================================================================
-- 5. The card sale.
-- ===========================================================================

-- Begin: the walk-up begin for a card (no comps; 5 minutes to pay), plus the
-- 'awaiting' card row. Idempotent on the order key like a cash sale.
CREATE OR REPLACE FUNCTION public._exos_pos_walkup_begin_card(
  p_actor uuid, p_event_id uuid, p_tier_id uuid, p_quantity integer, p_order_key uuid, p_device_id uuid,
  p_buyer_name text, p_buyer_email text, p_answers jsonb, p_live boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_role  text;
  o       public.exos_pos_orders%ROWTYPE;
  v_line  public.exos_pos_order_lines%ROWTYPE;
  v_tier  uuid;
  v_order uuid;
  v_org   uuid;
BEGIN
  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  v_role := public._exos_pos_actor_role(p_event_id, p_actor, false);
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not authorized to sell at this event' USING ERRCODE = '42501';
  END IF;
  IF p_order_key IS NULL THEN
    RAISE EXCEPTION 'an order key is required (a new UUID per sale)' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('pos:sell:' || coalesce('d:' || p_device_id::text, 'u:' || p_actor::text), 30) THEN
    RAISE EXCEPTION 'too many sales a minute from this device' USING ERRCODE = '54000';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('exos_pos_key:' || p_order_key::text, 0));
  SELECT * INTO o FROM public.exos_pos_orders WHERE client_ref = p_order_key;
  IF o.id IS NOT NULL THEN
    SELECT * INTO v_line FROM public.exos_pos_order_lines WHERE order_id = o.id AND category = 'ticket' ORDER BY created_at LIMIT 1;
    SELECT tier_id INTO v_tier FROM public.exos_pos_items WHERE id = v_line.item_id;
    IF o.event_id <> p_event_id OR o.rung_by IS DISTINCT FROM p_actor OR v_tier IS DISTINCT FROM p_tier_id
       OR v_line.quantity IS DISTINCT FROM p_quantity OR o.comp_quantity <> 0
       OR NOT EXISTS (SELECT 1 FROM public.exos_pos_card_payments c WHERE c.order_id = o.id) THEN
      RAISE EXCEPTION 'this order key was already used for another sale' USING ERRCODE = '23505';
    END IF;
    RETURN public._exos_pos_order_json(o.id, p_actor)
           || jsonb_build_object('replay', true, 'card', public._exos_pos_card_json(o.id));
  END IF;

  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF public._exos_pos_connected_account(v_org) IS NULL THEN
    RAISE EXCEPTION 'this organizer hasn''t finished payment setup: take cash' USING ERRCODE = '55000', HINT = 'card-setup';
  END IF;
  v_order := public._exos_pos_walkup_begin(p_actor, v_role, p_event_id, p_tier_id, p_quantity, 0, p_order_key,
                                           p_device_id, p_buyer_name, p_buyer_email, p_answers, 300);
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = v_order;
  IF o.total_cents <= 0 THEN
    RAISE EXCEPTION 'nothing to charge: sell it as cash' USING ERRCODE = '22023', HINT = 'card-zero';
  END IF;
  INSERT INTO public.exos_pos_card_payments (org_id, event_id, order_id, amount_cents, currency, livemode, created_by)
  VALUES (o.org_id, o.event_id, o.id, o.total_cents, lower(coalesce(o.currency, 'usd')), coalesce(p_live, false), p_actor);
  RETURN public._exos_pos_order_json(o.id, p_actor)
         || jsonb_build_object('replay', false, 'card', public._exos_pos_card_json(o.id));
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_walkup_begin_card(uuid, uuid, uuid, integer, uuid, uuid, text, text, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_walkup_begin_card(uuid, uuid, uuid, integer, uuid, uuid, text, text, jsonb, boolean)
  TO service_role;

-- Charge: who may (the seller, an owner or a manager), the rate limit, the
-- reader (the org's, active, org-wide or set to this event, this mode), the
-- places still held (extended 5 minutes), payment setup done. Returns what
-- exos-pos needs to create the PaymentIntent; the amount is the order's.
CREATE OR REPLACE FUNCTION public._exos_pos_card_begin(p_actor uuid, p_order uuid, p_mode text, p_reader_device uuid, p_live boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o       public.exos_pos_orders%ROWTYPE;
  c       public.exos_pos_card_payments%ROWTYPE;
  v_role  text;
  v_mode  text := lower(coalesce(p_mode, 'reader'));
  v_qty   int;
  v_held  int;
  v_reader text;
  v_loc   text;
  v_acct  text;
  v_exp   timestamptz := now() + interval '5 minutes';
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order FOR UPDATE;
  v_role := CASE WHEN o.id IS NULL OR p_actor IS NULL THEN NULL ELSE public._exos_pos_actor_role(o.event_id, p_actor, false) END;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (o.rung_by = p_actor OR v_role IN ('owner', 'manager')) THEN
    RAISE EXCEPTION 'only the seller, an owner or a manager can charge this sale' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('pos:card:' || p_actor::text, 20) THEN
    RAISE EXCEPTION 'too many card charges a minute' USING ERRCODE = '54000';
  END IF;
  IF v_mode NOT IN ('reader', 'sdk') THEN
    RAISE EXCEPTION 'mode is reader or sdk' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO c FROM public.exos_pos_card_payments WHERE order_id = o.id FOR UPDATE;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'this sale isn''t a card sale' USING ERRCODE = '55000', HINT = 'not-card';
  END IF;
  IF o.status = 'paid' THEN
    RETURN jsonb_build_object('done', true, 'order_id', o.id);
  END IF;
  IF o.status <> 'open' OR c.status NOT IN ('awaiting', 'processing') THEN
    RAISE EXCEPTION 'this sale was %', CASE WHEN o.status = 'open' THEN c.status ELSE o.status END USING ERRCODE = '55000';
  END IF;
  IF c.livemode IS DISTINCT FROM coalesce(p_live, false) THEN
    RAISE EXCEPTION 'this sale was started in the other Stripe mode: start it again' USING ERRCODE = '55000';
  END IF;
  SELECT quantity INTO v_qty FROM public.exos_pos_order_lines WHERE order_id = o.id AND category = 'ticket' ORDER BY created_at LIMIT 1;
  SELECT coalesce(sum(quantity), 0) INTO v_held FROM public.exos_cart_holds
   WHERE pos_order_id = o.id AND status = 'active' AND expires_at > now();
  IF v_qty IS NULL OR v_held <> v_qty THEN
    RAISE EXCEPTION 'reservation_expired: the places were given back; start the sale again' USING ERRCODE = '55000', HINT = 'expired';
  END IF;
  IF o.total_cents <> c.amount_cents THEN
    RAISE EXCEPTION 'the sale''s total changed: start it again' USING ERRCODE = '55000';
  END IF;
  IF v_mode = 'reader' THEN
    SELECT r.stripe_reader_id INTO v_reader
      FROM public.exos_pos_terminal_readers r
      JOIN public.exos_pos_devices d ON d.id = r.device_id AND d.org_id = r.org_id
     WHERE r.device_id = p_reader_device AND r.org_id = o.org_id AND r.status = 'active' AND d.status = 'active'
       AND d.kind = 'reader' AND (d.event_id IS NULL OR d.event_id = o.event_id) AND r.livemode = coalesce(p_live, false);
    IF v_reader IS NULL THEN
      RAISE EXCEPTION 'pick one of this organization''s card readers' USING ERRCODE = '55000', HINT = 'no-reader';
    END IF;
  END IF;
  SELECT stripe_location_id INTO v_loc FROM public.exos_pos_terminal_locations
   WHERE org_id = o.org_id AND livemode = coalesce(p_live, false);
  IF v_loc IS NULL THEN
    RAISE EXCEPTION 'card at the door isn''t set up for this organization yet' USING ERRCODE = '55000', HINT = 'no-location';
  END IF;
  v_acct := public._exos_pos_connected_account(o.org_id);
  IF v_acct IS NULL THEN
    RAISE EXCEPTION 'this organizer hasn''t finished payment setup: take cash' USING ERRCODE = '55000', HINT = 'card-setup';
  END IF;
  -- The guest is at the reader: keep their places while they pay.
  UPDATE public.exos_cart_holds SET expires_at = greatest(expires_at, v_exp)
   WHERE pos_order_id = o.id AND status = 'active';
  UPDATE public.exos_pos_orders SET hold_expires_at = greatest(coalesce(hold_expires_at, v_exp), v_exp) WHERE id = o.id;
  UPDATE public.exos_pos_card_payments
     SET mode = v_mode, reader_device_id = CASE WHEN v_mode = 'reader' THEN p_reader_device END
   WHERE id = c.id;
  RETURN jsonb_build_object(
    'done', false, 'order_id', o.id, 'event_id', o.event_id, 'org_id', o.org_id,
    'amount_cents', o.total_cents, 'currency', lower(coalesce(o.currency, 'usd')),
    'fee_bps', coalesce(public.exos_event_fee_bps(o.event_id, now()), 0), 'fee_base', public.exos_pos_walkup_fee_base(),
    'destination', v_acct, 'location_id', v_loc, 'reader_id', v_reader, 'mode', v_mode,
    'payment_intent_id', c.payment_intent_id, 'status', c.status,
    'description', left(coalesce((SELECT e.name FROM public.exos_events e WHERE e.id = o.event_id), 'Event') || ' (door)', 200));
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_card_begin(uuid, uuid, text, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_begin(uuid, uuid, text, uuid, boolean) TO service_role;

-- Record the PaymentIntent Stripe made for the order (amount and currency
-- must be the order's). { cancel: true } when the sale ended meanwhile:
-- exos-pos then cancels the PaymentIntent.
CREATE OR REPLACE FUNCTION public._exos_pos_card_attach(
  p_order uuid, p_pi text, p_amount integer, p_currency text, p_app_fee integer, p_exos_fee integer,
  p_card_fee integer, p_fee_bps integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE; c public.exos_pos_card_payments%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order FOR UPDATE;
  SELECT * INTO c FROM public.exos_pos_card_payments WHERE order_id = p_order FOR UPDATE;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'no card payment for this order' USING ERRCODE = 'P0002';
  END IF;
  IF c.payment_intent_id IS NOT NULL AND c.payment_intent_id <> p_pi THEN
    RAISE EXCEPTION 'another PaymentIntent is already attached to this sale' USING ERRCODE = '23505';
  END IF;
  IF p_amount IS DISTINCT FROM o.total_cents OR p_amount IS DISTINCT FROM c.amount_cents
     OR lower(coalesce(p_currency, '')) <> c.currency THEN
    RAISE EXCEPTION 'the PaymentIntent doesn''t match the sale' USING ERRCODE = '22023';
  END IF;
  IF o.status <> 'open' OR c.status NOT IN ('awaiting', 'processing') THEN
    RETURN jsonb_build_object('cancel', true, 'status', c.status);
  END IF;
  UPDATE public.exos_pos_card_payments
     SET payment_intent_id = p_pi, status = 'processing',
         application_fee_cents = p_app_fee, exos_fee_cents = p_exos_fee, card_fee_est_cents = p_card_fee, fee_bps = p_fee_bps
   WHERE id = c.id;
  RETURN jsonb_build_object('cancel', false, 'status', 'processing');
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_card_attach(uuid, text, integer, text, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_attach(uuid, text, integer, text, integer, integer, integer, integer) TO service_role;

-- What the door needs to poll, cancel, void or refund a sale. p_need 'read'
-- (door staff of the event: polling) or 'act' (the seller, an owner or a
-- manager: cancel). Anyone else: "order not found".
CREATE OR REPLACE FUNCTION public._exos_pos_card_lookup(p_actor uuid, p_order uuid, p_need text, p_rate boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE; c public.exos_pos_card_payments%ROWTYPE; v_role text; v_reader text;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order;
  v_role := CASE WHEN o.id IS NULL OR p_actor IS NULL THEN NULL ELSE public._exos_pos_actor_role(o.event_id, p_actor, false) END;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  IF coalesce(p_need, 'read') = 'act' AND NOT (o.rung_by = p_actor OR v_role IN ('owner', 'manager')) THEN
    RAISE EXCEPTION 'only the seller, an owner or a manager can do that' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_rate, true) AND NOT public.exos_rate_hit('pos:cardpoll:' || p_actor::text, 120) THEN
    RAISE EXCEPTION 'too many requests a minute' USING ERRCODE = '54000';
  END IF;
  SELECT * INTO c FROM public.exos_pos_card_payments WHERE order_id = o.id;
  SELECT r.stripe_reader_id INTO v_reader FROM public.exos_pos_terminal_readers r WHERE r.device_id = c.reader_device_id AND r.org_id = o.org_id;
  RETURN jsonb_build_object(
    'order_id', o.id, 'order_status', CASE WHEN o.status = 'open' THEN 'pending' ELSE o.status END,
    'is_card', c.id IS NOT NULL,
    'card_tender_cents', (SELECT coalesce(sum(p.amount_cents), 0) FROM public.exos_pos_payments p
                           WHERE p.order_id = o.id AND p.method = 'card' AND p.status = 'succeeded'),
    'status', c.status, 'mode', c.mode, 'payment_intent_id', c.payment_intent_id, 'reader_id', v_reader,
    'livemode', c.livemode, 'amount_cents', c.amount_cents);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_card_lookup(uuid, uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_lookup(uuid, uuid, text, boolean) TO service_role;

-- Authorized on the reader: capture now? Under the order lock:
--   'capture'  the sale is pending and its places are held (extended 2
--              minutes); the row is 'capturing'
--   'done'     already completed (the other path got there first)
--   'cancel'   the sale ended or its places were given back: cancel the
--              PaymentIntent (an uncaptured authorization takes no money)
--   'ignore'   not this order's PaymentIntent
CREATE OR REPLACE FUNCTION public._exos_pos_card_capture_prepare(p_order uuid, p_pi text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE; c public.exos_pos_card_payments%ROWTYPE; v_qty int; v_held int;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order FOR UPDATE;
  SELECT * INTO c FROM public.exos_pos_card_payments WHERE order_id = p_order FOR UPDATE;
  IF c.id IS NULL OR c.payment_intent_id IS DISTINCT FROM p_pi THEN
    RETURN jsonb_build_object('action', 'ignore');
  END IF;
  IF o.status = 'paid' OR c.status IN ('succeeded', 'refund_pending', 'refunded') THEN
    RETURN jsonb_build_object('action', 'done', 'amount_cents', c.amount_cents);
  END IF;
  SELECT quantity INTO v_qty FROM public.exos_pos_order_lines WHERE order_id = o.id AND category = 'ticket' ORDER BY created_at LIMIT 1;
  SELECT coalesce(sum(quantity), 0) INTO v_held FROM public.exos_cart_holds
   WHERE pos_order_id = o.id AND status = 'active' AND expires_at > now();
  IF o.status <> 'open' OR c.status IN ('declined', 'canceled') OR v_qty IS NULL OR v_held <> v_qty THEN
    RETURN jsonb_build_object('action', 'cancel', 'amount_cents', c.amount_cents);
  END IF;
  UPDATE public.exos_cart_holds SET expires_at = greatest(expires_at, now() + interval '2 minutes')
   WHERE pos_order_id = o.id AND status = 'active';
  UPDATE public.exos_pos_card_payments SET status = 'capturing' WHERE id = c.id;
  RETURN jsonb_build_object('action', 'capture', 'amount_cents', c.amount_cents);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_card_capture_prepare(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_capture_prepare(uuid, text) TO service_role;

-- Captured: complete the walk-up with the PaymentIntent as the card tender.
-- Idempotent on the order (the door and the webhook may both get here; the
-- order lock serializes them and the second is a replay). A capture that
-- can't become tickets (the sale ended, the amount differs, the places are
-- gone) cancels the sale and answers refund_needed: the caller refunds the
-- whole charge.
CREATE OR REPLACE FUNCTION public._exos_pos_card_complete(p_order uuid, p_pi text, p_amount integer, p_via text, p_event_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o     public.exos_pos_orders%ROWTYPE;
  c     public.exos_pos_card_payments%ROWTYPE;
  v_out jsonb;
  v_err text;
  v_via text := CASE WHEN p_via IN ('door', 'webhook') THEN p_via ELSE 'door' END;
  v_evt text := CASE WHEN coalesce(p_event_id, '') ~ '^evt_[A-Za-z0-9]{1,250}$' THEN p_event_id END;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order FOR UPDATE;
  SELECT * INTO c FROM public.exos_pos_card_payments WHERE order_id = p_order FOR UPDATE;
  IF c.id IS NULL OR c.payment_intent_id IS DISTINCT FROM p_pi THEN
    RAISE EXCEPTION 'no such card payment' USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_pos_payments p WHERE p.order_id = o.id AND p.method = 'card' AND p.terminal_ref = p_pi) THEN
    RETURN public._exos_pos_order_json(o.id, o.rung_by)
           || jsonb_build_object('replay', true, 'refund_needed', false, 'card', public._exos_pos_card_json(o.id));
  END IF;
  IF c.status IN ('refund_pending', 'refunded') THEN
    RETURN jsonb_build_object('order_id', o.id, 'replay', true, 'refund_needed', c.status = 'refund_pending',
                              'card', public._exos_pos_card_json(o.id));
  END IF;
  IF o.status = 'open' AND p_amount IS NOT DISTINCT FROM o.total_cents AND p_amount = c.amount_cents THEN
    BEGIN
      PERFORM set_config('exos.pos_card_ref', p_pi, true);
      v_out := public._exos_pos_walkup_complete(o.rung_by, o.id, 'card', NULL, NULL);
      PERFORM set_config('exos.pos_card_ref', '', true);
    EXCEPTION WHEN OTHERS THEN
      v_err := left(SQLERRM, 300);
      PERFORM set_config('exos.pos_card_ref', '', true);
    END;
  ELSE
    v_err := CASE WHEN o.status <> 'open' THEN 'the sale was ' || o.status || ' before the card was captured'
                  ELSE 'the captured amount doesn''t match the sale' END;
  END IF;
  IF v_err IS NULL THEN
    UPDATE public.exos_pos_card_payments
       SET status = 'succeeded', completed_via = v_via, stripe_event_id = coalesce(v_evt, stripe_event_id), decline_code = NULL
     WHERE id = c.id;
    RETURN v_out || jsonb_build_object('replay', false, 'refund_needed', false, 'card', public._exos_pos_card_json(o.id));
  END IF;
  -- Money taken, no tickets: give the places back and refund in full.
  IF o.status = 'open' THEN
    PERFORM public._exos_pos_walkup_cancel(o.rung_by, o.id, 'card captured but the sale couldn''t complete; refunded');
  END IF;
  UPDATE public.exos_pos_card_payments
     SET status = 'refund_pending', completed_via = v_via, stripe_event_id = coalesce(v_evt, stripe_event_id), note = v_err
   WHERE id = c.id;
  RETURN jsonb_build_object('order_id', o.id, 'replay', false, 'refund_needed', true, 'reason', v_err,
                            'card', public._exos_pos_card_json(o.id));
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_card_complete(uuid, text, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_complete(uuid, text, integer, text, text) TO service_role;

-- Declined or cancelled: the sale is cancelled (places back). Never after
-- money was taken (succeeded / refund_*): then it's ignored. Idempotent.
CREATE OR REPLACE FUNCTION public._exos_pos_card_fail(p_order uuid, p_pi text, p_status text, p_code text, p_via text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE; c public.exos_pos_card_payments%ROWTYPE;
BEGIN
  IF p_status NOT IN ('declined', 'canceled') THEN
    RAISE EXCEPTION 'status is declined or canceled' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order FOR UPDATE;
  SELECT * INTO c FROM public.exos_pos_card_payments WHERE order_id = p_order FOR UPDATE;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'no card payment for this order' USING ERRCODE = 'P0002';
  END IF;
  IF (p_pi IS NOT NULL AND c.payment_intent_id IS DISTINCT FROM p_pi)
     OR c.status IN ('succeeded', 'refund_pending', 'refunded')
     OR o.status IN ('paid', 'refunded')
     OR EXISTS (SELECT 1 FROM public.exos_pos_payments p WHERE p.order_id = o.id AND p.status = 'succeeded') THEN
    RETURN jsonb_build_object('order_id', o.id, 'ignored', true, 'card', public._exos_pos_card_json(o.id));
  END IF;
  IF c.status NOT IN ('declined', 'canceled') THEN
    UPDATE public.exos_pos_card_payments
       SET status = p_status,
           decline_code = CASE WHEN lower(coalesce(p_code, '')) ~ '^[a-z0-9_]{1,64}$' THEN lower(p_code) END,
           completed_via = CASE WHEN p_via IN ('door', 'webhook') THEN p_via END,
           note = left(nullif(btrim(coalesce(p_reason, '')), ''), 300)
     WHERE id = c.id;
  END IF;
  IF o.status = 'open' THEN
    PERFORM public._exos_pos_walkup_cancel(o.rung_by, o.id,
      left(coalesce(nullif(btrim(coalesce(p_reason, '')), ''), CASE p_status WHEN 'declined' THEN 'card declined' ELSE 'card cancelled' END), 300));
  END IF;
  RETURN public._exos_pos_order_json(o.id, o.rung_by) || jsonb_build_object('ignored', false, 'card', public._exos_pos_card_json(o.id));
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_card_fail(uuid, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_fail(uuid, text, text, text, text, text) TO service_role;

-- Void / refund of a card sale: the walk-up rules (_exos_pos_reverse: who,
-- when, scans, override, the final settlement), then the card part on the
-- reversal ledger row as a pending Stripe refund. A replay (already reversed)
-- answers the refund's state so exos-pos can retry a refund still pending.
CREATE OR REPLACE FUNCTION public._exos_pos_card_reverse(
  p_actor uuid, p_order uuid, p_kind text, p_reason text, p_override boolean, p_drawer uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_out jsonb; v_card int; v_pi text; rv public.exos_pos_reversals%ROWTYPE;
BEGIN
  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('exos.pos_card_reverse', 'on', true);
  v_out := public._exos_pos_reverse(p_actor, false, NULL, NULL, p_order, p_kind, p_reason, coalesce(p_override, false), p_drawer, NULL);
  PERFORM set_config('exos.pos_card_reverse', '', true);
  SELECT coalesce(sum(p.amount_cents), 0)::int, max(p.terminal_ref) INTO v_card, v_pi
    FROM public.exos_pos_payments p WHERE p.order_id = p_order AND p.method = 'card';
  SELECT * INTO rv FROM public.exos_pos_reversals WHERE order_id = p_order FOR UPDATE;
  IF rv.id IS NOT NULL AND v_card > 0 AND rv.card_payment_intent IS NULL THEN
    UPDATE public.exos_pos_reversals
       SET card_cents = v_card, card_payment_intent = v_pi, card_refund_status = 'pending'
     WHERE id = rv.id
    RETURNING * INTO rv;
  END IF;
  RETURN v_out || jsonb_build_object('card_refund', CASE WHEN rv.card_payment_intent IS NULL THEN NULL ELSE jsonb_build_object(
    'payment_intent', rv.card_payment_intent, 'amount_cents', rv.card_cents, 'status', rv.card_refund_status,
    'refund_ref', rv.card_refund_ref, 'kind', rv.kind) END);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_card_reverse(uuid, uuid, text, text, boolean, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_reverse(uuid, uuid, text, text, boolean, uuid) TO service_role;

-- Stripe's answer to a card refund: on the reversal ledger row (a void /
-- refund) or, for a capture that couldn't be fulfilled, on the card row.
-- Idempotent; a later webhook moves a pending refund to its final state.
CREATE OR REPLACE FUNCTION public._exos_pos_card_refund_record(p_order uuid, p_refund_ref text, p_status text, p_error text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_status text := CASE WHEN p_status IN ('pending', 'succeeded', 'failed', 'canceled') THEN p_status ELSE 'pending' END;
  v_ref    text := CASE WHEN coalesce(p_refund_ref, '') ~ '^re_[A-Za-z0-9]{1,250}$' THEN p_refund_ref END;
  v_n      int;
BEGIN
  UPDATE public.exos_pos_reversals
     SET card_refund_ref = coalesce(v_ref, card_refund_ref),
         card_refund_status = CASE WHEN card_refund_status = 'succeeded' THEN 'succeeded' ELSE v_status END,
         card_refund_error = CASE WHEN v_status IN ('failed', 'canceled') THEN left(coalesce(p_error, v_status), 300) END
   WHERE order_id = p_order AND card_payment_intent IS NOT NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    UPDATE public.exos_pos_card_payments
       SET refund_ref = coalesce(v_ref, refund_ref),
           status = CASE WHEN v_status = 'succeeded' THEN 'refunded' ELSE status END,
           note = CASE WHEN v_status IN ('failed', 'canceled') THEN left('refund ' || v_status || ': ' || coalesce(p_error, ''), 300) ELSE note END
     WHERE order_id = p_order AND status IN ('refund_pending', 'refunded');
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  RETURN jsonb_build_object('order_id', p_order, 'recorded', v_n > 0, 'status', v_status);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_card_refund_record(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_card_refund_record(uuid, text, text, text) TO service_role;

-- ROLLBACK (manual): DROP the functions created above and the tables
-- exos_pos_card_payments / exos_pos_terminal_readers / exos_pos_terminal_locations;
-- drop the added exos_pos_reversals columns and put card_cents back to
-- CHECK (card_cents = 0); re-apply 20261107100000 to restore
-- _exos_pos_walkup_complete and _exos_pos_reverse without the card markers.
