-- ============================================================================
-- Migration 20260929072000 — Exos (Bridge / D4): Apple Wallet + Google Wallet
-- ticket passes
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_wallet_passes (one row per issued pass: serial,
--              hashed Apple authenticationToken, code epoch, void state,
--              push-pending flag), TABLE exos_wallet_registrations (Apple
--              device library id + push token per pass)
--           C: FUNCTION _exos_wallet_apple_code, _exos_wallet_google_key,
--              _exos_wallet_totp, _exos_wallet_check_code, _exos_wallet_payload,
--              _exos_wallet_token_ok, exos_wallet_issue_pass,
--              exos_wallet_reissue, exos_wallet_pass_payload,
--              exos_wallet_fetch_pass, exos_wallet_register_device,
--              exos_wallet_unregister_device, exos_wallet_updated_serials,
--              exos_wallet_push_queue, exos_wallet_push_done,
--              exos_wallet_drop_push_tokens,
--              exos_tg_wallet_ticket_changed (+ AFTER UPDATE trigger on
--              exos_tickets)
--           W: FUNCTION exos_check_in_ticket (8 args) — patched to accept a
--              W- wallet code next to the T- rotating code
-- Pre-reqs: 20260929040000 (door hardening: the 8-argument check-in),
--           20260702123000 (barcode_secret least privilege)
--
-- The app's QR code rotates every 30 seconds: T-{ticket}:{owner}:{bucket}:
-- {HMAC-SHA256(barcode_secret)}. A wallet pass can't run that code, so a pass
-- carries a W- code the door accepts instead (docs/wallet.md):
--
--   W-{ticket}:{owner}:a{epoch}:{mac}    Apple Wallet (static between updates)
--       mac  = base64url(HMAC-SHA256(barcode_secret, 'wallet-a:{ticket}:{owner}:{epoch}'))
--   W-{ticket}:{owner}:g{epoch}:{totp}   Google Wallet rotatingBarcode
--       key  = first 20 bytes of HMAC-SHA256(barcode_secret, 'wallet-g:{ticket}:{owner}:{epoch}')
--       totp = RFC 6238, HMAC-SHA1, 30 s period, 8 digits; ±2 periods at the door
--
-- Both are bound to the ticket's CURRENT owner and secret (a transfer rotates
-- the secret and changes the owner, so every old wallet code dies) and to the
-- pass's current epoch (a void or a holder "reissue" bumps it). The door checks
-- the pass is still active. Google never receives barcode_secret, only the
-- derived TOTP key it needs to render the rotating code.
--
-- A void, release or transfer of a ticket voids its pass (trigger below) and
-- marks it push-pending, so Apple devices fetch the voided pass and Google's
-- object goes INACTIVE on the next exos-wallet push run. A check-in, undo,
-- transfer start/cancel or secret rotation marks the pass for a refresh.
--
-- Access: a pass is created only by the ticket's owner (exos_wallet_issue_pass
-- checks auth.uid()); clients can read their own pass rows (no token hash)
-- and nothing else. The PassKit web service functions are service_role only
-- and check the Apple authenticationToken against its SHA-256 hash.
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS; the
-- check-in patch asserts one match and is skipped once applied). D4 authors;
-- applying to prod is operator-gated.
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

-- ── Tables ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.exos_wallet_passes (
  serial_number        text        PRIMARY KEY,
  ticket_id            uuid        NOT NULL REFERENCES public.exos_tickets(id) ON DELETE CASCADE,
  owner_id             uuid        NOT NULL,
  status               text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'voided')),
  void_reason          text,
  voided_at            timestamptz,
  code_epoch           integer     NOT NULL DEFAULT 1 CHECK (code_epoch >= 1),
  pass_type_identifier text,
  auth_token_hash      text        CHECK (auth_token_hash IS NULL OR auth_token_hash ~ '^[0-9a-f]{64}$'),
  apple_issued_at      timestamptz,
  google_issued_at     timestamptz,
  push_pending         boolean     NOT NULL DEFAULT false,
  pushed_at            timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (serial_number ~ '^exw[0-9a-f]{32}$')
);
-- One live pass per ticket; voided ones stay (their devices still fetch them).
CREATE UNIQUE INDEX IF NOT EXISTS exos_wallet_passes_active_uq
  ON public.exos_wallet_passes (ticket_id) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS exos_wallet_passes_push_idx
  ON public.exos_wallet_passes (updated_at) WHERE push_pending;

CREATE TABLE IF NOT EXISTS public.exos_wallet_registrations (
  device_library_id    text        NOT NULL CHECK (length(device_library_id) BETWEEN 1 AND 128),
  pass_type_identifier text        NOT NULL,
  serial_number        text        NOT NULL REFERENCES public.exos_wallet_passes(serial_number) ON DELETE CASCADE,
  push_token           text        NOT NULL CHECK (length(push_token) BETWEEN 1 AND 256),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (device_library_id, pass_type_identifier, serial_number)
);
CREATE INDEX IF NOT EXISTS exos_wallet_registrations_serial_idx
  ON public.exos_wallet_registrations (serial_number);

ALTER TABLE public.exos_wallet_passes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_wallet_registrations ENABLE ROW LEVEL SECURITY;

-- Supabase grants new tables to anon/authenticated by default: take it back.
REVOKE ALL ON public.exos_wallet_passes        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.exos_wallet_registrations FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_wallet_passes, public.exos_wallet_registrations TO service_role;

-- The holder sees their own passes (no token hash, no push bookkeeping).
GRANT SELECT (serial_number, ticket_id, owner_id, status, void_reason, voided_at, code_epoch,
              apple_issued_at, google_issued_at, created_at, updated_at)
  ON public.exos_wallet_passes TO authenticated;
DROP POLICY IF EXISTS exos_wallet_passes_sel ON public.exos_wallet_passes;
CREATE POLICY exos_wallet_passes_sel ON public.exos_wallet_passes FOR SELECT TO authenticated
  USING (owner_id = (SELECT auth.uid()));
-- No client INSERT / UPDATE / DELETE: a pass is created only through
-- exos_wallet_issue_pass (owner-checked). Registrations: service role only.

-- ── Code derivation (internal) ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._exos_wallet_apple_code(p_ticket uuid, p_owner uuid, p_secret text, p_epoch int)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT 'W-' || p_ticket || ':' || p_owner || ':a' || p_epoch || ':' ||
         rtrim(translate(encode(extensions.hmac('wallet-a:' || p_ticket || ':' || p_owner || ':' || p_epoch,
                                                p_secret, 'sha256'), 'base64'), '+/', '-_'), '=');
$$;

CREATE OR REPLACE FUNCTION public._exos_wallet_google_key(p_ticket uuid, p_owner uuid, p_secret text, p_epoch int)
RETURNS bytea LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT substring(extensions.hmac('wallet-g:' || p_ticket || ':' || p_owner || ':' || p_epoch,
                                   p_secret, 'sha256') FROM 1 FOR 20);
$$;

-- RFC 6238 TOTP (HMAC-SHA1, 8 digits) for one 30-second step.
CREATE OR REPLACE FUNCTION public._exos_wallet_totp(p_key bytea, p_step bigint)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE h bytea := extensions.hmac(int8send(p_step), p_key, 'sha1'); o int; b bigint;
BEGIN
  o := get_byte(h, 19) & 15;
  b := ((get_byte(h, o) & 127)::bigint << 24) | (get_byte(h, o + 1)::bigint << 16)
     | (get_byte(h, o + 2)::bigint << 8) | get_byte(h, o + 3)::bigint;
  RETURN lpad((b % 100000000)::text, 8, '0');
END $$;

-- Door check of a W- code. 'ok' or a check-in refusal reason.
CREATE OR REPLACE FUNCTION public._exos_wallet_check_code(p_ticket uuid, p_owner uuid, p_secret text,
                                                          p_payload text, p_at timestamptz)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_parts text[] := string_to_array(substring(p_payload FROM 3), ':');
  v_kind  text;
  v_epoch int;
  v_live  int;
  v_key   bytea;
  v_cur   bigint;
BEGIN
  IF p_secret IS NULL OR p_owner IS NULL OR upper(left(p_payload, 2)) <> 'W-'
     OR coalesce(array_length(v_parts, 1), 0) <> 4
     OR v_parts[1] <> p_ticket::text OR v_parts[2] <> p_owner::text
     OR v_parts[3] !~ '^[ag][0-9]{1,9}$' THEN
    RETURN 'barcode-rejected';
  END IF;
  v_kind  := left(v_parts[3], 1);
  v_epoch := substring(v_parts[3] FROM 2)::int;

  -- The pass must still be live, for this holder, at this epoch.
  SELECT code_epoch INTO v_live
    FROM public.exos_wallet_passes
   WHERE ticket_id = p_ticket AND status = 'active' AND owner_id = p_owner;
  IF v_live IS NULL OR v_live <> v_epoch THEN
    RETURN 'barcode-rejected';
  END IF;

  IF v_kind = 'a' THEN
    RETURN CASE WHEN public._exos_wallet_apple_code(p_ticket, p_owner, p_secret, v_epoch) = p_payload
                THEN 'ok' ELSE 'barcode-rejected' END;
  END IF;

  IF v_parts[4] !~ '^[0-9]{8}$' THEN
    RETURN 'barcode-rejected';
  END IF;
  v_key := public._exos_wallet_google_key(p_ticket, p_owner, p_secret, v_epoch);
  v_cur := floor(extract(epoch FROM p_at) / 30);
  FOR s IN v_cur - 2 .. v_cur + 2 LOOP
    IF public._exos_wallet_totp(v_key, s) = v_parts[4] THEN
      RETURN 'ok';
    END IF;
  END LOOP;
  RETURN 'barcode-rejected';
EXCEPTION WHEN others THEN
  RETURN 'barcode-rejected';
END $$;

REVOKE ALL ON FUNCTION public._exos_wallet_apple_code(uuid, uuid, text, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_wallet_google_key(uuid, uuid, text, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_wallet_totp(bytea, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_wallet_check_code(uuid, uuid, text, text, timestamptz) FROM PUBLIC, anon, authenticated;

-- ── The door accepts W- codes ──────────────────────────────────────────────

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  'wallet: W- pass code',
  $o$    IF v_signed THEN
      DECLARE$o$,
  $n$    IF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN
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
      DECLARE$n$);

-- ── Issue / reissue (the ticket's owner) ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.exos_wallet_issue_pass(p_ticket_id uuid, p_kind text,
                                                        p_token_hash text DEFAULT NULL,
                                                        p_pass_type text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid  uuid := auth.uid();
  t      record;
  v_pass public.exos_wallet_passes%ROWTYPE;
  v_new  boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_wallet_issue_pass: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('apple', 'google') THEN
    RAISE EXCEPTION 'exos_wallet_issue_pass: kind must be apple or google' USING ERRCODE = '22023';
  END IF;
  IF p_kind = 'apple' AND (p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$'
                           OR p_pass_type IS NULL OR p_pass_type !~ '^[A-Za-z0-9.-]{3,128}$') THEN
    RAISE EXCEPTION 'exos_wallet_issue_pass: apple needs a token hash and pass type' USING ERRCODE = '22023';
  END IF;

  SELECT id, owner_id, status, pending_transfer_id, barcode_secret INTO t
    FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  -- Not found and not yours look the same.
  IF t.id IS NULL OR t.owner_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'exos_wallet_issue_pass: not the ticket owner' USING ERRCODE = '42501';
  END IF;
  IF t.status <> 'active' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-active');
  END IF;
  IF t.pending_transfer_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer');
  END IF;
  IF t.barcode_secret IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no-secret');
  END IF;

  -- A live pass for someone else (can't normally happen: the trigger voids on
  -- an owner change) is voided before this holder gets their own serial.
  UPDATE public.exos_wallet_passes
     SET status = 'voided', void_reason = 'transferred', voided_at = now(),
         code_epoch = code_epoch + 1, updated_at = clock_timestamp(), push_pending = true
   WHERE ticket_id = p_ticket_id AND status = 'active' AND owner_id <> v_uid;

  SELECT * INTO v_pass FROM public.exos_wallet_passes
   WHERE ticket_id = p_ticket_id AND status = 'active' FOR UPDATE;
  IF v_pass.serial_number IS NULL THEN
    INSERT INTO public.exos_wallet_passes (serial_number, ticket_id, owner_id)
    VALUES ('exw' || replace(gen_random_uuid()::text, '-', ''), p_ticket_id, v_uid)
    RETURNING * INTO v_pass;
    v_new := true;
  END IF;

  -- Apple: a fresh authenticationToken each download (only its hash is kept;
  -- the new .pkpass replaces the old one on the device).
  UPDATE public.exos_wallet_passes
     SET auth_token_hash      = CASE WHEN p_kind = 'apple' THEN p_token_hash ELSE auth_token_hash END,
         pass_type_identifier = CASE WHEN p_kind = 'apple' THEN p_pass_type ELSE pass_type_identifier END,
         apple_issued_at      = CASE WHEN p_kind = 'apple' THEN now() ELSE apple_issued_at END,
         google_issued_at     = CASE WHEN p_kind = 'google' THEN now() ELSE google_issued_at END
   WHERE serial_number = v_pass.serial_number;

  RETURN jsonb_build_object('ok', true, 'serial', v_pass.serial_number,
                            'code_epoch', v_pass.code_epoch, 'created', v_new);
END $$;

-- "My pass was screenshotted": a new code; the old one stops working at the door.
CREATE OR REPLACE FUNCTION public.exos_wallet_reissue(p_ticket_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); v_epoch int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_wallet_reissue: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE id = p_ticket_id AND owner_id = v_uid) THEN
    RAISE EXCEPTION 'exos_wallet_reissue: not the ticket owner' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_wallet_passes
     SET code_epoch = code_epoch + 1, updated_at = clock_timestamp(), push_pending = true
   WHERE ticket_id = p_ticket_id AND status = 'active' AND owner_id = v_uid
  RETURNING code_epoch INTO v_epoch;
  IF v_epoch IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no-pass');
  END IF;
  RETURN jsonb_build_object('ok', true, 'code_epoch', v_epoch);
END $$;

REVOKE ALL ON FUNCTION public.exos_wallet_issue_pass(uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_wallet_reissue(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_wallet_issue_pass(uuid, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_wallet_reissue(uuid) TO authenticated, service_role;

-- ── What a pass shows (service role: the edge function builds from this) ────
-- The door code / TOTP key are derived here, so barcode_secret itself never
-- leaves the database. Holder-safe: no email, no price, no buyer id.

CREATE OR REPLACE FUNCTION public._exos_wallet_payload(p_serial text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'serial',        w.serial_number,
    'pass_type',     w.pass_type_identifier,
    'status',        w.status,
    'void_reason',   w.void_reason,
    'code_epoch',    w.code_epoch,
    'updated_at',    w.updated_at,
    'ticket', jsonb_build_object(
      'id', t.id, 'status', t.status, 'tier_name', coalesce(tt.name, t.tier_name),
      'section_label', tt.section_label, 'attendee_name', t.attendee_name,
      'in_transfer', t.pending_transfer_id IS NOT NULL, 'check_in_at', t.check_in_at),
    'event', jsonb_build_object(
      'id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
      'doors_at', e.doors_at, 'timezone', e.timezone, 'venue_name', e.venue_name,
      'venue_location', e.venue_location, 'lat', g.lat, 'lng', g.lng),
    'org_name',      o.name,
    'apple_code',    CASE WHEN w.status = 'active' AND t.status IN ('active', 'used') AND t.owner_id = w.owner_id
                          THEN public._exos_wallet_apple_code(t.id, w.owner_id, t.barcode_secret, w.code_epoch) END,
    'google_key_hex', CASE WHEN w.status = 'active' AND t.status IN ('active', 'used') AND t.owner_id = w.owner_id
                          THEN encode(public._exos_wallet_google_key(t.id, w.owner_id, t.barcode_secret, w.code_epoch), 'hex') END,
    'google_pattern', 'W-' || t.id || ':' || w.owner_id || ':g' || w.code_epoch || ':{totp_value_0}')
    FROM public.exos_wallet_passes w
    JOIN public.exos_tickets t ON t.id = w.ticket_id
    JOIN public.exos_events  e ON e.id = t.event_id
    LEFT JOIN public.exos_ticket_tiers tt ON tt.id = t.tier_id
    LEFT JOIN public.exos_orgs o ON o.id = t.org_id
    LEFT JOIN public.exos_event_geo g ON g.event_id = e.id
   WHERE w.serial_number = p_serial;
$$;

CREATE OR REPLACE FUNCTION public._exos_wallet_token_ok(p_serial text, p_pass_type text, p_token text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((
    SELECT w.auth_token_hash IS NOT NULL
           AND w.pass_type_identifier = p_pass_type
           AND p_token IS NOT NULL AND length(p_token) BETWEEN 16 AND 256
           AND encode(extensions.digest(p_token, 'sha256'), 'hex') = w.auth_token_hash
      FROM public.exos_wallet_passes w WHERE w.serial_number = p_serial), false);
$$;

-- Owner flow: payload of a serial the edge function just issued.
CREATE OR REPLACE FUNCTION public.exos_wallet_pass_payload(p_serial text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_wallet_payload(p_serial);
$$;

-- PassKit "get the latest pass": NULL unless the token matches.
CREATE OR REPLACE FUNCTION public.exos_wallet_fetch_pass(p_pass_type text, p_serial text, p_token text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN public._exos_wallet_token_ok(p_serial, p_pass_type, p_token)
              THEN public._exos_wallet_payload(p_serial) END;
$$;

-- ── PassKit web service (service role) ─────────────────────────────────────

CREATE OR REPLACE FUNCTION public.exos_wallet_register_device(p_device text, p_pass_type text, p_serial text,
                                                             p_token text, p_push_token text)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_old text;
BEGIN
  IF NOT public._exos_wallet_token_ok(p_serial, p_pass_type, p_token) THEN
    RETURN 'unauthorized';
  END IF;
  IF p_device IS NULL OR length(p_device) NOT BETWEEN 1 AND 128
     OR p_push_token IS NULL OR length(p_push_token) NOT BETWEEN 1 AND 256 THEN
    RETURN 'invalid';
  END IF;
  SELECT push_token INTO v_old FROM public.exos_wallet_registrations
   WHERE device_library_id = p_device AND pass_type_identifier = p_pass_type AND serial_number = p_serial;
  IF FOUND THEN
    IF v_old IS DISTINCT FROM p_push_token THEN
      UPDATE public.exos_wallet_registrations SET push_token = p_push_token, updated_at = now()
       WHERE device_library_id = p_device AND pass_type_identifier = p_pass_type AND serial_number = p_serial;
    END IF;
    RETURN 'exists';
  END IF;
  INSERT INTO public.exos_wallet_registrations (device_library_id, pass_type_identifier, serial_number, push_token)
  VALUES (p_device, p_pass_type, p_serial, p_push_token)
  ON CONFLICT DO NOTHING;
  RETURN 'created';
END $$;

CREATE OR REPLACE FUNCTION public.exos_wallet_unregister_device(p_device text, p_pass_type text, p_serial text,
                                                               p_token text)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT public._exos_wallet_token_ok(p_serial, p_pass_type, p_token) THEN
    RETURN 'unauthorized';
  END IF;
  DELETE FROM public.exos_wallet_registrations
   WHERE device_library_id = p_device AND pass_type_identifier = p_pass_type AND serial_number = p_serial;
  RETURN 'deleted';
END $$;

-- Serials registered on a device that changed after the tag. The tag is
-- opaque to Apple: microseconds since the epoch of the newest change.
CREATE OR REPLACE FUNCTION public.exos_wallet_updated_serials(p_device text, p_pass_type text, p_since text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_since timestamptz; v_serials text[]; v_last timestamptz;
BEGIN
  IF p_since ~ '^[0-9]{1,17}$' THEN
    v_since := to_timestamp(p_since::numeric / 1000000);
  END IF;
  SELECT array_agg(w.serial_number ORDER BY w.serial_number), max(w.updated_at)
    INTO v_serials, v_last
    FROM public.exos_wallet_registrations r
    JOIN public.exos_wallet_passes w ON w.serial_number = r.serial_number
   WHERE r.device_library_id = p_device AND r.pass_type_identifier = p_pass_type
     AND (v_since IS NULL OR w.updated_at > v_since);
  RETURN jsonb_build_object(
    'serials', coalesce(to_jsonb(v_serials), '[]'::jsonb),
    'last_updated', CASE WHEN v_last IS NULL THEN p_since
                         ELSE floor(extract(epoch FROM v_last) * 1000000)::bigint::text END);
END $$;

-- Passes waiting for a push (Apple) / object update (Google).
CREATE OR REPLACE FUNCTION public.exos_wallet_push_queue(p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'queued_at', clock_timestamp(),
    'passes', coalesce(jsonb_agg(q ORDER BY q.updated_at), '[]'::jsonb))
  FROM (
    SELECT w.serial_number AS serial, w.pass_type_identifier AS pass_type, w.status, w.updated_at,
           w.google_issued_at IS NOT NULL AS google,
           coalesce((SELECT jsonb_agg(DISTINCT r.push_token) FROM public.exos_wallet_registrations r
                      WHERE r.serial_number = w.serial_number), '[]'::jsonb) AS push_tokens
      FROM public.exos_wallet_passes w
     WHERE w.push_pending
     ORDER BY w.updated_at
     LIMIT greatest(1, least(coalesce(p_limit, 100), 500))) q;
$$;

-- Clear push_pending, unless the pass changed again after the queue read.
CREATE OR REPLACE FUNCTION public.exos_wallet_push_done(p_serials text[], p_queued_at timestamptz)
RETURNS int LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE public.exos_wallet_passes
     SET push_pending = false, pushed_at = now()
   WHERE serial_number = ANY (p_serials) AND push_pending AND updated_at <= p_queued_at;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- APNs said these tokens are gone (HTTP 410): drop their registrations.
CREATE OR REPLACE FUNCTION public.exos_wallet_drop_push_tokens(p_tokens text[])
RETURNS int LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  DELETE FROM public.exos_wallet_registrations WHERE push_token = ANY (p_tokens);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.exos_wallet_drop_push_tokens(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wallet_drop_push_tokens(text[]) TO service_role;
REVOKE ALL ON FUNCTION public._exos_wallet_payload(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_wallet_token_ok(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_wallet_pass_payload(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_wallet_fetch_pass(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_wallet_register_device(text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_wallet_unregister_device(text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_wallet_updated_serials(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_wallet_push_queue(int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_wallet_push_done(text[], timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wallet_pass_payload(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_wallet_fetch_pass(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_wallet_register_device(text, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_wallet_unregister_device(text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_wallet_updated_serials(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_wallet_push_queue(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_wallet_push_done(text[], timestamptz) TO service_role;

-- ── Void / transfer / check-in → the pass follows ──────────────────────────
-- Mirrors walletEffect() in supabase/functions/_shared/wallet/state.ts.

CREATE OR REPLACE FUNCTION public.exos_tg_wallet_ticket_changed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_reason text;
BEGIN
  IF NEW.status = 'voided' AND OLD.status IS DISTINCT FROM 'voided' THEN
    v_reason := CASE WHEN NEW.released_at IS NOT NULL THEN 'released' ELSE 'ticket-voided' END;
  ELSIF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    v_reason := 'transferred';
  END IF;

  IF v_reason IS NOT NULL THEN
    UPDATE public.exos_wallet_passes
       SET status = 'voided', void_reason = v_reason, voided_at = now(),
           code_epoch = code_epoch + 1, updated_at = clock_timestamp(), push_pending = true
     WHERE ticket_id = NEW.id AND status = 'active';
  ELSE
    -- Checked in / undone / transfer started or cancelled / secret rotated /
    -- name changed: the pass shows it (and a rotated secret changes the code).
    UPDATE public.exos_wallet_passes
       SET updated_at = clock_timestamp(), push_pending = true
     WHERE ticket_id = NEW.id AND status = 'active';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_wallet_ticket_changed() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_tickets_wallet ON public.exos_tickets;
CREATE TRIGGER exos_tickets_wallet
  AFTER UPDATE ON public.exos_tickets
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status
        OR OLD.owner_id IS DISTINCT FROM NEW.owner_id
        OR OLD.barcode_secret IS DISTINCT FROM NEW.barcode_secret
        OR OLD.pending_transfer_id IS DISTINCT FROM NEW.pending_transfer_id
        OR OLD.attendee_name IS DISTINCT FROM NEW.attendee_name)
  EXECUTE FUNCTION public.exos_tg_wallet_ticket_changed();
