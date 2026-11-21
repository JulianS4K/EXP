-- ============================================================================
-- Migration 20261121153000 — Exos: static door codes (2026-11-21)
-- ============================================================================
-- Operator, 2026-11-21: "keep under 150 capacity for event free on exos but
-- pdf not rotating barcodes". A free-tier event's tickets get ONE code that
-- never changes (a static code), so the ticket can be a PDF: attached to the
-- confirmation email, downloadable from My Tickets, printed. Events over the
-- free tier keep the rotating HMAC codes (T-, 30 s), the paid tier's
-- anti-screenshot feature. The door takes both, per ticket.
--
-- This is the generic "static-code" door mode: nothing here says "free tier"
-- except the rule that picks the mode at issuance, so the BYO marketplace's
-- allocated PDF tickets can be issued static too (code_mode = 'static' on
-- the insert, with exos.static_code_ok = 'on' set for its transaction).
--
-- 1. The mode is per ticket, fixed at issuance (exos_tickets.code_mode,
--    'static' | 'rotating'). Tickets that exist before this migration are
--    'rotating' (their behaviour doesn't change), and so is a row written
--    with triggers off (the column default). Every other new ticket gets
--    _exos_ticket_code_mode(event) from the BEFORE INSERT trigger
--    exos_tickets_code_mode. An insert that asks for 'static' is kept only
--    on the static-code path (the transaction sets exos.static_code_ok =
--    'on'; nothing does yet), else refused where the rule says rotating:
--    'static' while the event is the free
--    tier by the fee's own rule (exos_event_is_free_tier: bounded, and
--    max(max capacity, sold) at or under exos_free_tier_max_capacity()),
--    counting this ticket (the event's live tickets + 1 must also be at or
--    under the cutoff, so a path that counts the sale after inserting still
--    crosses on the ticket that crosses), under the event row lock (FOR NO KEY
--    UPDATE, the lock every issuing path's UPDATE exos_events takes, so no
--    path can deadlock on it) so two orders at the boundary can't both take
--    the last static place. The mode never changes after
--    (exos_tickets_code_mode_lock). So when an event grows past the cutoff,
--    tickets issued after that rotate and the earlier ones stay static.
-- 2. The code: S-{ticket}:{32 base32 chars}, the first 160 bits of
--    HMAC-SHA256(barcode_secret, 'static:{ticket}:{owner}') (_exos_static_code;
--    _shared/staticCodes.ts mirrors it). Nothing new is stored: it is derived
--    from the read-gated secret and the holder, so a transfer (new owner,
--    and the claim rotates the secret) or a reissued secret voids the old
--    code and gives the new holder a new one; a refund / void kills it with
--    the ticket's status. The door gets only its SHA-256 (door_keys.s, like
--    the Apple wallet code's `wa` and the print code's `p`): a leaked roster
--    can't make a code.
-- 3. The door: exos_check_in_ticket (both overloads, patched) takes an S-
--    code for a static-mode ticket only (a rotating ticket's S- code is
--    refused 'barcode-rejected': its anti-screenshot property stays). First
--    scan wins: the same atomic status flip as every code, so a second scan
--    gets the existing "already checked in" answer (_exos_used_answer).
--    A printed ticket (a live P- code) still refuses its other codes,
--    the S- code included ('printed'). Offline uploads: a refused S- code is
--    'barcode-rejected' → 'invalid-barcode' in the scan report, an S- code
--    another phone already used is 'used' (exos_check_in_offline, unchanged).
-- 4. Wallet passes of a static ticket carry the S- code (_exos_wallet_payload
--    + static_code; Apple barcode, Google static barcode); the partner /
--    RSVP ticket link page shows it too (exos_ticket_link_view + code_mode).
-- 5. The PDF in the email: a 'ticket-issued' mail is linked, when it is
--    queued, to the static tickets its own transaction issued or handed over
--    to that address (buyer_email; updated_at = now()) that no mail carries
--    yet (exos_mail_ticket_pdfs, trigger exos_mail_ticket_pdfs_link). The PDF
--    has the first 20; the mail says the rest are in My Tickets.
--    exos-mail-drain asks
--    exos_mail_ticket_pdf_rows (service role) for the ones still live with
--    the same holder, draws the PDF (_shared/print/tickets.ts) and attaches
--    it. The two mails that said "screenshots won't scan" (phone RSVP,
--    partner reservation) say the right thing for static tickets.
-- 6. A leaked code: exos_ticket_static_reissue (the holder) and
--    exos_wallet_reissue (patched) give a static ticket a new secret, so a
--    new code: both 3 a minute per holder, both only while it is active and
--    not being transferred. And the box office's email hand-over to an account now
--    rotates the secret like every other change of holder: it didn't, so the
--    selling scanner could still make the buyer's T- codes (live in prod).
--
-- Touches:  W: TABLE exos_tickets (+ code_mode, CHECK, column grant, index,
--              TRIGGERs exos_tickets_code_mode / exos_tickets_code_mode_lock)
--           C: TABLE exos_mail_ticket_pdfs, TRIGGER exos_mail_ticket_pdfs_link
--              on exos_mail
--           C: FUNCTION _exos_base32, _exos_static_code, _exos_static_code_canon,
--              _exos_static_code_check, _exos_ticket_code_mode,
--              exos_tg_ticket_code_mode, exos_tg_mail_ticket_pdfs,
--              exos_mail_ticket_pdf_rows, exos_ticket_static_reissue
--           W: FUNCTION (patched in place, marker-checked; the Applier checks
--              each anchor against prod's pg_get_functiondef first):
--                exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text, uuid, text)
--                exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)
--                _exos_door_keys(uuid, uuid, text)
--                _exos_wallet_payload(text)
--                exos_ticket_link_view(uuid, text)                    (2 patches)
--                exos_phone_rsvp_verify(uuid, text, text)
--                _exos_partner_reservation_complete(uuid, uuid, text, jsonb, text)
--                exos_wallet_reissue(uuid)                            (2 patches)
--                _exos_pos_deliver_email(uuid, uuid, text, boolean)    (a fix live in prod: see 6)
--              Anchors (the text each patch searches for, once):
--                check-in x2: "ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN"
--                _exos_door_keys: "IF v_print IS NOT NULL THEN ... RETURN v_out;" (the last 4 lines)
--                _exos_wallet_payload: "'google_pattern', 'W-' || t.id"
--                exos_ticket_link_view: its SELECT ... attendee_name line; "'code', CASE WHEN v_state = 'valid'"
--                exos_phone_rsvp_verify / _exos_partner_reservation_complete: the
--                  "Its QR code changes every 30 seconds" sentence of the mail
--                exos_wallet_reissue: "IF v_epoch IS NULL THEN ... 'no-pass' ... END IF;";
--                  its "RAISE ... 'exos_wallet_reissue: not the ticket owner' ... END IF;"
--                _exos_pos_deliver_email: "UPDATE public.exos_tickets SET owner_id = v_rcpt,
--                  buyer_id = v_rcpt, buyer_email = v_email / WHERE id = ANY (v_ids) AND owner_id = o.rung_by;"
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
-- 1. The mode, per ticket
-- ===========================================================================
-- Existing tickets: 'rotating' (the default fills them). The default stays,
-- so an insert that skips triggers (a restore, replica mode) is rotating;
-- the trigger below decides for every other new ticket.
ALTER TABLE public.exos_tickets ADD COLUMN IF NOT EXISTS code_mode text NOT NULL DEFAULT 'rotating';
ALTER TABLE public.exos_tickets ALTER COLUMN code_mode SET DEFAULT 'rotating';
-- The CHECK is added NOT VALID (no scan under the ACCESS EXCLUSIVE lock), then
-- validated (a scan under SHARE UPDATE EXCLUSIVE: reads and writes go on).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_tickets_code_mode_chk') THEN
    ALTER TABLE public.exos_tickets ADD CONSTRAINT exos_tickets_code_mode_chk CHECK (code_mode IN ('static', 'rotating')) NOT VALID;
  END IF;
END $$;
ALTER TABLE public.exos_tickets VALIDATE CONSTRAINT exos_tickets_code_mode_chk;
COMMENT ON COLUMN public.exos_tickets.code_mode IS
  'How the ticket''s door code works, fixed at issuance: static (one S- code, printable; the free tier) or rotating (T- HMAC, 30 s). mig 20261121153000.';
GRANT SELECT (code_mode) ON public.exos_tickets TO authenticated;
-- The mail link below looks for the static tickets its own transaction
-- issued or handed over (updated_at = now()). Partial: static tickets only.
-- On a big exos_tickets: run the ADD COLUMN above on its own, then build this
-- index CONCURRENTLY (outside a transaction, same name), then apply: this
-- line skips it (scripts/rollout-prod.sh).
CREATE INDEX IF NOT EXISTS exos_tickets_static_touched_idx ON public.exos_tickets (updated_at)
  WHERE code_mode = 'static';

-- The mode a ticket of this event gets if issued now: the fee's free-tier
-- rule (exos_event_is_free_tier), with this ticket counted. VOLATILE, so each
-- statement sees what committed before it. A free-tier event's issues lock
-- the event row (FOR NO KEY UPDATE, held to commit) before counting, so two
-- orders at the boundary can't both see room for one more static ticket;
-- events over the cutoff never take it here (their paths' UPDATE does).
CREATE OR REPLACE FUNCTION public._exos_ticket_code_mode(p_event_id uuid)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cut  int := public.exos_free_tier_max_capacity();
  v_live int;
BEGIN
  IF p_event_id IS NULL OR NOT coalesce(public.exos_event_is_free_tier(p_event_id), false) THEN
    RETURN 'rotating';
  END IF;
  -- The event row lock every issuing path takes (UPDATE exos_events), not a
  -- lock of its own: a path that inserts before that UPDATE (the partner /
  -- API reservation complete) would otherwise wait for another path's event
  -- row while holding what that path's insert waits for (a deadlock).
  PERFORM 1 FROM public.exos_events WHERE id = p_event_id FOR NO KEY UPDATE;
  -- Again under the lock: another order may have crossed while we waited.
  IF NOT coalesce(public.exos_event_is_free_tier(p_event_id), false) THEN
    RETURN 'rotating';
  END IF;
  SELECT count(*) INTO v_live
    FROM (SELECT 1 FROM public.exos_tickets
           WHERE event_id = p_event_id AND status IN ('active', 'used')
           LIMIT greatest(v_cut, 0) + 1) x;
  RETURN CASE WHEN v_live + 1 <= v_cut THEN 'static' ELSE 'rotating' END;
END $$;
REVOKE ALL ON FUNCTION public._exos_ticket_code_mode(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_ticket_code_mode(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_tg_ticket_code_mode()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- 'static' asked for is kept only on the static-code path (a marketplace's
    -- PDF allocation), which sets exos.static_code_ok = 'on' for its own
    -- transaction. Nothing sets it yet. Anything else, the column default
    -- included, is the rule's answer, and 'static' asked for where the rule
    -- says rotating is refused.
    IF NEW.code_mode = 'static' AND coalesce(current_setting('exos.static_code_ok', true), '') = 'on' THEN
      RETURN NEW;
    END IF;
    IF NEW.code_mode = 'static' THEN
      IF public._exos_ticket_code_mode(NEW.event_id) <> 'static' THEN
        RAISE EXCEPTION 'static codes are for free-tier events (or the static-code path)' USING ERRCODE = '42501';
      END IF;
    ELSE
      NEW.code_mode := public._exos_ticket_code_mode(NEW.event_id);
    END IF;
  ELSIF NEW.code_mode IS DISTINCT FROM OLD.code_mode THEN
    RAISE EXCEPTION 'a ticket''s code mode is fixed when it is issued' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_ticket_code_mode() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_code_mode ON public.exos_tickets;
CREATE TRIGGER exos_tickets_code_mode BEFORE INSERT ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_code_mode();
DROP TRIGGER IF EXISTS exos_tickets_code_mode_lock ON public.exos_tickets;
CREATE TRIGGER exos_tickets_code_mode_lock BEFORE UPDATE OF code_mode ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_code_mode();

-- ===========================================================================
-- 2. The code
-- ===========================================================================
-- RFC 4648 base32 (A-Z, 2-7), no padding, of whole 5-byte groups.
CREATE OR REPLACE FUNCTION public._exos_base32(p bytea)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_alpha text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  v_out   text := '';
  v_n     bigint;
  i int; j int;
BEGIN
  IF p IS NULL OR length(p) % 5 <> 0 THEN
    RAISE EXCEPTION '_exos_base32: whole 5-byte groups only' USING ERRCODE = '22023';
  END IF;
  FOR i IN 0 .. length(p) / 5 - 1 LOOP
    v_n := 0;
    FOR j IN 0 .. 4 LOOP
      v_n := (v_n << 8) | get_byte(p, i * 5 + j);
    END LOOP;
    FOR j IN REVERSE 7 .. 0 LOOP
      v_out := v_out || substr(v_alpha, ((v_n >> (j * 5)) & 31)::int + 1, 1);
    END LOOP;
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_base32(bytea) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_base32(bytea) TO service_role;

-- A ticket's static code for a holder (NULL without a secret).
CREATE OR REPLACE FUNCTION public._exos_static_code(p_ticket uuid, p_owner uuid, p_secret text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_ticket IS NOT NULL AND coalesce(p_secret, '') <> '' THEN
    'S-' || p_ticket::text || ':' || public._exos_base32(substring(
      extensions.hmac('static:' || p_ticket::text || ':' || coalesce(p_owner::text, ''), p_secret, 'sha256') FROM 1 FOR 20))
  END
$$;
REVOKE ALL ON FUNCTION public._exos_static_code(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_static_code(uuid, uuid, text) TO service_role;

-- A read code in canonical form (S, lower-case id, upper-case tail), or NULL.
CREATE OR REPLACE FUNCTION public._exos_static_code_canon(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT 'S-' || lower(m[1]) || ':' || upper(m[2])
    FROM regexp_match(btrim(coalesce(p_code, '')),
           '^[Ss]-([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}):([A-Za-z2-7]{32})$') m
$$;
REVOKE ALL ON FUNCTION public._exos_static_code_canon(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_static_code_canon(text) TO service_role;

-- The door's check: a static-mode ticket, its own id, its current holder.
CREATE OR REPLACE FUNCTION public._exos_static_code_check(p_ticket uuid, p_owner uuid, p_secret text, p_code text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_canon text := public._exos_static_code_canon(p_code);
  v_mode  text;
BEGIN
  SELECT code_mode INTO v_mode FROM public.exos_tickets WHERE id = p_ticket;
  IF v_canon IS NULL OR v_mode IS DISTINCT FROM 'static' OR p_owner IS NULL
     OR substring(v_canon FROM 3 FOR 36) <> p_ticket::text
     OR public._exos_static_code(p_ticket, p_owner, p_secret) IS DISTINCT FROM v_canon THEN
    RETURN 'barcode-rejected';
  END IF;
  RETURN 'ok';
END $$;
REVOKE ALL ON FUNCTION public._exos_static_code_check(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_static_code_check(uuid, uuid, text, text) TO service_role;

-- ===========================================================================
-- 3. The door
-- ===========================================================================
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text, uuid, text)',
  '/* exos: static codes */',
$o$    ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN$o$,
$n$    ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'S-' THEN
      /* exos: static codes */ -- mig 20261121153000: a static-mode ticket's one code.
      IF public._exos_static_code_check(p_ticket_id, v_owner, v_secret, p_barcode_payload) <> 'ok' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END IF;
      v_verified := true;
    ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  '/* exos: static codes */',
$o$    ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN$o$,
$n$    ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'S-' THEN
      /* exos: static codes */ -- mig 20261121153000: a static-mode ticket's one code.
      IF public._exos_static_code_check(p_ticket_id, v_owner, v_secret, p_barcode_payload) <> 'ok' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END IF;
      v_verified := true;
    ELSIF v_signed AND upper(left(btrim(p_barcode_payload), 2)) = 'W-' THEN$n$, 1);

-- Door keys + `s`: the static code's SHA-256, for a static-mode ticket with
-- a holder. A hash: a lost door phone can check the code, never make one.
SELECT pg_temp.exos_patch_n(
  'public._exos_door_keys(uuid, uuid, text)',
  '/* exos: static codes */',
$o$  IF v_print IS NOT NULL THEN
    v_out := v_out || jsonb_build_object('p', v_print);
  END IF;
  RETURN v_out;$o$,
$n$  /* exos: static codes */ -- mig 20261121153000.
  IF p_owner IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_tickets WHERE id = p_ticket AND code_mode = 'static') THEN
    v_out := v_out || jsonb_build_object('s',
      encode(extensions.digest(public._exos_static_code(p_ticket, p_owner, p_secret), 'sha256'), 'hex'));
  END IF;
  IF v_print IS NOT NULL THEN
    v_out := v_out || jsonb_build_object('p', v_print);
  END IF;
  RETURN v_out;$n$, 1);

-- -- A new code when one leaked: a new secret ----------------------------------
-- The static code is derived from the secret and the holder, so a new secret
-- is a new code (and new T- / W- codes, and voids a live print code: the
-- triggers on barcode_secret). Chosen over adding the wallet epoch to the MAC:
-- the app, the email's PDF and the door roster all derive the code from the
-- secret, and a holder without a wallet pass needs a way too.
-- The holder only, a static-mode ticket, active and not in a transfer; 3 a
-- minute per holder.
CREATE OR REPLACE FUNCTION public.exos_ticket_static_reissue(p_ticket_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t public.exos_tickets%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  IF NOT public.exos_rate_hit('static_reissue:' || auth.uid()::text, 3) THEN
    RAISE EXCEPTION 'too many new codes, try again in a minute' USING ERRCODE = '54000';
  END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF t.id IS NULL OR t.owner_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'ticket not found' USING ERRCODE = 'P0002';
  END IF;
  IF t.code_mode <> 'static' THEN
    RAISE EXCEPTION 'this ticket''s code already changes every 30 seconds' USING ERRCODE = '22023';
  END IF;
  IF t.status <> 'active' OR t.pending_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'only an active ticket that isn''t being transferred gets a new code' USING ERRCODE = '55000';
  END IF;
  UPDATE public.exos_tickets SET barcode_secret = gen_random_uuid()::text, last_reissue_at = now() WHERE id = t.id;
  RETURN jsonb_build_object('ok', true, 'ticket_id', t.id);
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_static_reissue(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_ticket_static_reissue(uuid) TO authenticated, service_role;

-- "My pass was screenshotted" (exos_wallet_reissue) bumps the pass epoch,
-- which a static code doesn't carry: for a static-mode ticket it also gives
-- the ticket a new secret, so the pass's new code is a new S- code.
SELECT pg_temp.exos_patch_n(
  'public.exos_wallet_reissue(uuid)',
  '/* exos: static codes */',
$o$  IF v_epoch IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no-pass');
  END IF;$o$,
$n$  IF v_epoch IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no-pass');
  END IF;
  /* exos: static codes */ -- mig 20261121153000: a new S- code too.
  UPDATE public.exos_tickets SET barcode_secret = gen_random_uuid()::text, last_reissue_at = now()
   WHERE id = p_ticket_id AND owner_id = v_uid AND code_mode = 'static';$n$, 1);

-- The same guards as exos_ticket_static_reissue, before the pass epoch moves:
-- 3 a minute per holder (every ticket: each reissue pushes the pass), and a
-- static ticket gets a new secret only while active and not being
-- transferred (its row locked, so a check-in or a transfer can't start in
-- between). Answers, not errors, so exos-wallet's reissue keeps its shape
-- ({ ok: false, reason } with 409, as 'no-pass').
SELECT pg_temp.exos_patch_n(
  'public.exos_wallet_reissue(uuid)',
  '/* exos: static reissue guards */',
$o$    RAISE EXCEPTION 'exos_wallet_reissue: not the ticket owner' USING ERRCODE = '42501';
  END IF;$o$,
$n$    RAISE EXCEPTION 'exos_wallet_reissue: not the ticket owner' USING ERRCODE = '42501';
  END IF;
  /* exos: static reissue guards */ -- mig 20261121153000
  IF NOT public.exos_rate_hit('wallet_reissue:' || v_uid::text, 3) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate-limited');
  END IF;
  PERFORM 1 FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.exos_tickets WHERE id = p_ticket_id AND code_mode = 'static'
              AND (status <> 'active' OR pending_transfer_id IS NOT NULL)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-active');
  END IF;$n$, 1);

-- The box office's email hand-over to a confirmed account moved the ticket
-- to the buyer without a new secret, so the seller, who could read it while
-- holding the ticket, could still make the buyer's codes (every other change
-- of holder rotates it: exos_claim_transfer, exos_phone_rsvp_claim). Fixed
-- for every ticket, rotating too.
SELECT pg_temp.exos_patch_n(
  'public._exos_pos_deliver_email(uuid, uuid, text, boolean)',
  '/* exos: pos deliver rotates */',
$o$    UPDATE public.exos_tickets SET owner_id = v_rcpt, buyer_id = v_rcpt, buyer_email = v_email
     WHERE id = ANY (v_ids) AND owner_id = o.rung_by;$o$,
$n$    UPDATE public.exos_tickets SET owner_id = v_rcpt, buyer_id = v_rcpt, buyer_email = v_email,
           barcode_secret = gen_random_uuid()::text /* exos: pos deliver rotates */ -- mig 20261121153000
     WHERE id = ANY (v_ids) AND owner_id = o.rung_by;$n$, 1);

-- ===========================================================================
-- 4. Wallet passes and the ticket link page
-- ===========================================================================
SELECT pg_temp.exos_patch_n(
  'public._exos_wallet_payload(text)',
  '/* exos: static codes */',
$o$    'google_pattern', 'W-' || t.id$o$,
$n$    'static_code',   CASE WHEN w.status = 'active' AND t.status IN ('active', 'used') AND t.owner_id = w.owner_id
                           AND t.code_mode = 'static' /* exos: static codes */
                          THEN public._exos_static_code(t.id, w.owner_id, t.barcode_secret) END,
    'google_pattern', 'W-' || t.id$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_ticket_link_view(uuid, text)',
  '/* exos: static codes select */',
$o$  SELECT id, event_id, owner_id, status, pending_transfer_id, barcode_secret, tier_name, attendee_name
$o$,
$n$  SELECT id, event_id, owner_id, status, pending_transfer_id, barcode_secret, tier_name, attendee_name,
         code_mode /* exos: static codes select */
$n$, 1);
SELECT pg_temp.exos_patch_n(
  'public.exos_ticket_link_view(uuid, text)',
  '/* exos: static codes */',
$o$    'code', CASE WHEN v_state = 'valid'
$o$,
$n$    'code_mode', t.code_mode, /* exos: static codes */
    'code', CASE WHEN v_state = 'valid' AND t.code_mode = 'static'
                 THEN public._exos_static_code(t.id, t.owner_id, t.barcode_secret)
                 WHEN v_state = 'valid'
$n$, 1);

-- The two ticket mails that promise a rotating code say the right thing for
-- static tickets (which carry the PDF, section 5).
SELECT pg_temp.exos_patch_n(
  'public.exos_phone_rsvp_verify(uuid, text, text)',
  '/* exos: static codes */',
$o$'<p>Open your ticket on your phone at the door. Its QR code changes every 30 seconds, so screenshots won''t scan.</p>' ||$o$,
$n$CASE WHEN EXISTS (SELECT 1 FROM public.exos_tickets x WHERE x.id = ANY (v_ids) AND x.code_mode = 'static') /* exos: static codes */
                   THEN '<p>Open your ticket on your phone at the door, or print the PDF attached to this email. One entry per ticket: the first scan wins.</p>'
                   ELSE '<p>Open your ticket on your phone at the door. Its QR code changes every 30 seconds, so screenshots won''t scan.</p>' END ||$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public._exos_partner_reservation_complete(uuid, uuid, text, jsonb, text)',
  '/* exos: static codes */',
$o$'<p>Open a ticket on your phone at the door. Its QR code changes every 30 seconds, so screenshots ' ||
            'and printouts won''t scan. From the ticket page you can add it to Apple or Google Wallet.</p>' ||$o$,
$n$CASE WHEN EXISTS (SELECT 1 FROM public.exos_tickets x WHERE x.id = ANY (v_ids) AND x.code_mode = 'static') /* exos: static codes */
                 THEN '<p>Open a ticket on your phone at the door, or print the PDF attached to this email. One entry per ' ||
                      'ticket: the first scan wins. From the ticket page you can add it to Apple or Google Wallet.</p>'
                 ELSE '<p>Open a ticket on your phone at the door. Its QR code changes every 30 seconds, so screenshots ' ||
            'and printouts won''t scan. From the ticket page you can add it to Apple or Google Wallet.</p>' END ||$n$, 1);

-- ===========================================================================
-- 5. The PDF in the confirmation email
-- ===========================================================================
-- Which static tickets a 'ticket-issued' mail carries as a PDF, and their
-- holder then: the drain attaches only those still live with that holder.
CREATE TABLE IF NOT EXISTS public.exos_mail_ticket_pdfs (
  mail_id    uuid NOT NULL REFERENCES public.exos_mail (id) ON DELETE CASCADE,
  ticket_id  uuid NOT NULL REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  owner_id   uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (mail_id, ticket_id)
);
CREATE INDEX IF NOT EXISTS exos_mail_ticket_pdfs_ticket_idx ON public.exos_mail_ticket_pdfs (ticket_id);
ALTER TABLE public.exos_mail_ticket_pdfs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_mail_ticket_pdfs FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_mail_ticket_pdfs TO service_role;
COMMENT ON TABLE public.exos_mail_ticket_pdfs IS
  'Static-code tickets a ticket-issued mail carries as a PDF (linked when the mail is queued; the drain re-checks they are live with the same holder). Service role only. mig 20261121153000.';

-- At queue time: the static tickets this mail's own transaction issued or
-- handed over (updated_at = now(), the transaction's start) to this address
-- (buyer_email), that no mail carries yet. That is the order the mail is
-- about: checkout, comps, issue to email, the box office hand-over, partner,
-- RSVP. Never matched by the holder's account email, so a ticket the org
-- owner holds for a guest (partner, RSVP) never lands in the owner's mail,
-- and an order's tickets past the PDF's 20 pages never ride on a later mail.
CREATE OR REPLACE FUNCTION public.exos_tg_mail_ticket_pdfs()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO public.exos_mail_ticket_pdfs (mail_id, ticket_id, owner_id)
  SELECT NEW.id, t.id, t.owner_id
    FROM public.exos_tickets t
   WHERE t.code_mode = 'static' AND t.updated_at = now()
     AND t.status = 'active' AND t.owner_id IS NOT NULL AND t.pending_transfer_id IS NULL
     AND lower(t.buyer_email) = lower(NEW.to_email)
     AND NOT EXISTS (SELECT 1 FROM public.exos_mail_ticket_pdfs p WHERE p.ticket_id = t.id)
   ORDER BY t.created_at, t.id
   LIMIT 500
  ON CONFLICT DO NOTHING;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_mail_ticket_pdfs() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_mail_ticket_pdfs_link ON public.exos_mail;
CREATE TRIGGER exos_mail_ticket_pdfs_link AFTER INSERT ON public.exos_mail
  FOR EACH ROW WHEN (NEW.template = 'ticket-issued') EXECUTE FUNCTION public.exos_tg_mail_ticket_pdfs();

-- exos-mail-drain: what goes on each PDF, for the mails it claimed. Only
-- tickets still active, static, with the holder they had when the mail was
-- queued, not in a transfer, not printed (a live P- paper refuses the S-
-- code), on an event not cancelled. The code is in this answer only.
CREATE OR REPLACE FUNCTION public.exos_mail_ticket_pdf_rows(p_mail_ids uuid[])
RETURNS TABLE (mail_id uuid, ticket jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT l.mail_id, jsonb_build_object(
           'ticket_id', t.id, 'print_code', public._exos_static_code(t.id, t.owner_id, t.barcode_secret),
           'event_name', e.name, 'starts_at', e.starts_at, 'doors_at', e.doors_at, 'timezone', e.timezone,
           'occurs_at_local', e.occurs_at_local, 'venue_name', e.venue_name, 'venue_location', e.venue_location,
           'tier_name', coalesce(t.tier_name, tr.name),
           -- The name the holder (or the checkout) put on the ticket, never the
           -- holding account's: partner / RSVP tickets are held by the org owner.
           'attendee_name', nullif(btrim(t.attendee_name), ''),
           'seat_label', t.seat_label, 'org_name', o.name, 'order_ref', t.order_ref)
    FROM public.exos_mail_ticket_pdfs l
    JOIN public.exos_tickets t ON t.id = l.ticket_id
    JOIN public.exos_events e ON e.id = t.event_id
    JOIN public.exos_orgs o ON o.id = e.org_id
    LEFT JOIN public.exos_ticket_tiers tr ON tr.id = t.tier_id
   WHERE l.mail_id = ANY (coalesce(p_mail_ids, '{}'))
     AND t.code_mode = 'static' AND t.status = 'active' AND t.owner_id = l.owner_id
     AND t.pending_transfer_id IS NULL AND coalesce(t.barcode_secret, '') <> ''
     AND e.status IS DISTINCT FROM 'cancelled'
     AND NOT EXISTS (SELECT 1 FROM public.exos_ticket_print_codes pc WHERE pc.ticket_id = t.id AND pc.status = 'active')
   ORDER BY l.mail_id, t.created_at, t.id
$$;
REVOKE ALL ON FUNCTION public.exos_mail_ticket_pdf_rows(uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mail_ticket_pdf_rows(uuid[]) TO service_role;

-- ROLLBACK (manual): DROP TRIGGER exos_mail_ticket_pdfs_link ON exos_mail,
-- exos_tickets_code_mode / exos_tickets_code_mode_lock ON exos_tickets; DROP
-- TABLE exos_mail_ticket_pdfs; re-create the seven patched functions from
-- their pre-migration pg_get_functiondef (the patches only add branches);
-- DROP the functions created above; ALTER TABLE exos_tickets DROP COLUMN
-- code_mode (static tickets' S- codes stop working; their T- codes still do).
