-- ============================================================================
-- Partner / API mistake simulations: fixes (tests/exos/sim_partner.sql).
-- ============================================================================
-- Touches:  W: TABLE exos_api_writes (+ request_hash)
--           W: TABLE exos_gift_card_imports (+ request_hash)
--           W: TABLE exos_partner_reservations (+ idempotency_key, request_hash;
--              unique per org, seller and key)
--           C: FUNCTION _exos_api_request_hash (internal)
--           W: FUNCTION exos_api_write, exos_api_commerce_write,
--              exos_api_order_write (patched: an Idempotency-Key reused with a
--              different body is refused, not replayed)
--           W: FUNCTION _exos_gift_card_import (patched: the same)
--           W: FUNCTION _exos_partner_reserve (patched: Idempotency-Key, and a
--              partner can't reserve a ticket type in a member presale)
--           W: TABLE exos_ticket_tiers, exos_events (+ CHECKs, NOT VALID)
--           W: cron job exos-partner-reservations-sweep (every minute, only
--              where pg_cron exists)
-- Pre-reqs: 20261031110000 (core API), 20261031130000 (partner sales),
--           20261030130500 (member presales), 20261102100000 (commerce
--           writes), 20261102110000 (gift card import), 20261102140000 (order
--           writes), 20261101000000 (the needs-picker patch on reserve)
--
-- What the simulations found (tests/exos/sim_partner.sql, SIM-PARTNER-*):
--   1. Idempotency-Key reuse with a different body. The three API write
--      functions compared only the action and the target of a reused key, so
--      a client that reused a key for a NEW request with a different body (a
--      second comp batch, a different price) silently got the first answer
--      back and nothing was written. Now the args are hashed with the key and
--      a different body is 22023 (400 "already used for another request"),
--      as a different action already was. Rows written before this migration
--      have no hash and keep replaying as before.
--   2. The same for a gift-card import through the API: a reused
--      Idempotency-Key (stored as 'api:<key>') with a different file returned
--      the first import's result. Other batch keys (the dashboard's, and the
--      content hash used without a key) keep answering the stored result.
--   3. A partner (marketplace) could reserve and complete a ticket type that
--      is in a member presale: the presale is only checked at checkout
--      fulfilment (_exos_commerce_on_fulfill), which partner sales don't use.
--      Now a partner reservation of a presale type is refused (EX422) while
--      the presale runs. Organizer reservations (the box office) still sell,
--      as staff comps do.
--   4. A partner retrying POST …/ticket_reservations after a timeout made a
--      second reservation that held the seats again for 10 minutes (and a
--      retried comp minted twice). An Idempotency-Key on reserve now returns
--      the first reservation (same token) for the same body, 22023 for a
--      different one.
--   6. Ticket types took a negative price or capacity, events a negative
--      total_tickets, through the API (and the dashboard). CHECKs, NOT VALID.
--   5. exos_partner_reservations_sweep was never scheduled, so an abandoned
--      reservation stayed 'active' after expiry until someone read it. The
--      seats were back on sale (holds count only until expires_at), but a gift
--      card balance held on it stayed held. Scheduled every minute here.
--
-- Re-run safe: columns IF NOT EXISTS, marker-checked patches
-- (pg_temp.exos_patch_n), the cron job unscheduled before it is scheduled.
-- Grants are unchanged (CREATE OR REPLACE through pg_get_functiondef keeps
-- them). Prod apply needs operator OK.
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

-- ---------------------------------------------------------------------------
-- 1. Idempotency-Key + body: the API write functions.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_api_writes ADD COLUMN IF NOT EXISTS request_hash text
  CHECK (request_hash IS NULL OR request_hash ~ '^[0-9a-f]{64}$');
COMMENT ON COLUMN public.exos_api_writes.request_hash IS
  'SHA-256 of the action, target and args of a keyed write: a reused Idempotency-Key with another body is refused. mig 20261104130000.';

-- The hash of one write request (jsonb text is canonical: keys sorted).
CREATE OR REPLACE FUNCTION public._exos_api_request_hash(p_action text, p_target text, p_args jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT encode(sha256(convert_to(coalesce(p_action, '') || E'\n' || coalesce(left(p_target, 255), '') || E'\n' ||
                                  coalesce(p_args, '{}'::jsonb)::text, 'UTF8')), 'hex')
$$;
REVOKE ALL ON FUNCTION public._exos_api_request_hash(text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_request_hash(text, text, jsonb) TO service_role;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_api_write(uuid, text, text, jsonb, text)',
    'public.exos_api_commerce_write(uuid, text, text, jsonb, text)',
    'public.exos_api_order_write(uuid, text, text, jsonb, text)'] LOOP
    -- A fresh claim records the hash of its body.
    PERFORM pg_temp.exos_patch_n(f, '/* exos: idem hash set */',
      $o$    RETURNING id INTO v_log;$o$,
      $n$    RETURNING id INTO v_log;
    /* exos: idem hash set */ -- mig 20261104130000
    IF v_log IS NOT NULL THEN
      UPDATE public.exos_api_writes SET request_hash = public._exos_api_request_hash(p_action, p_target, p_args)
       WHERE id = v_log;
    END IF;$n$, 1);
    -- A reused key with another body is another request.
    PERFORM pg_temp.exos_patch_n(f, '/* exos: idem hash check */',
      $o$IF v_prev.action IS DISTINCT FROM p_action OR v_prev.target IS DISTINCT FROM left(p_target, 255) THEN$o$,
      $n$IF v_prev.action IS DISTINCT FROM p_action OR v_prev.target IS DISTINCT FROM left(p_target, 255)
         /* exos: idem hash check */ -- mig 20261104130000: same key, different body
         OR (v_prev.request_hash IS NOT NULL
             AND v_prev.request_hash IS DISTINCT FROM public._exos_api_request_hash(p_action, p_target, p_args)) THEN$n$, 1);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Gift-card import: the same rule for its key.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_gift_card_imports ADD COLUMN IF NOT EXISTS request_hash text
  CHECK (request_hash IS NULL OR request_hash ~ '^[0-9a-f]{64}$');

SELECT pg_temp.exos_patch_n('public._exos_gift_card_import(uuid, uuid, text, jsonb, text)',
  '/* exos: import hash check */',
  $o$  IF FOUND THEN
    RETURN jsonb_build_object('import_id', prev.id, 'fresh', false,$o$,
  $n$  IF FOUND THEN
    /* exos: import hash check */ -- mig 20261104130000: same key, another file
    IF v_key LIKE 'api:%' AND prev.request_hash IS NOT NULL
       AND prev.request_hash IS DISTINCT FROM encode(sha256(convert_to(v_src || E'\n' || p_cards::text, 'UTF8')), 'hex') THEN
      RAISE EXCEPTION 'this Idempotency-Key was already used for another import' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object('import_id', prev.id, 'fresh', false,$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_gift_card_import(uuid, uuid, text, jsonb, text)',
  '/* exos: import hash set */',
  $o$  VALUES (p_org_id, v_src, v_key, i, v_new, v_dup, v_bad, v_cents, v_rows, p_actor)
  RETURNING id INTO v_id;$o$,
  $n$  VALUES (p_org_id, v_src, v_key, i, v_new, v_dup, v_bad, v_cents, v_rows, p_actor)
  RETURNING id INTO v_id;
  /* exos: import hash set */ -- mig 20261104130000
  UPDATE public.exos_gift_card_imports
     SET request_hash = encode(sha256(convert_to(v_src || E'\n' || p_cards::text, 'UTF8')), 'hex')
   WHERE id = v_id;$n$, 1);

-- ---------------------------------------------------------------------------
-- 3. + 4. Partner reservations: Idempotency-Key, and member presales.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_partner_reservations ADD COLUMN IF NOT EXISTS idempotency_key text
  CHECK (idempotency_key IS NULL OR idempotency_key ~ '^[A-Za-z0-9_.:-]{8,100}$');
ALTER TABLE public.exos_partner_reservations ADD COLUMN IF NOT EXISTS request_hash text
  CHECK (request_hash IS NULL OR request_hash ~ '^[0-9a-f]{64}$');
-- One reservation per seller (partner, or the organizer's API key) and key.
CREATE UNIQUE INDEX IF NOT EXISTS exos_partner_reservations_idem_uq
  ON public.exos_partner_reservations (org_id, (coalesce(partner_id, api_key_id)), idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- p_attrs.idempotency_key (exos-api passes the Idempotency-Key header there,
-- so the signature stays the same): a resend with the same event, lines and
-- comp flag answers the first reservation; anything else is 22023. A dry run
-- ignores it.
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid, uuid, uuid, uuid, jsonb, jsonb, boolean, boolean)',
  '/* exos: reserve idempotency */',
  $o$    v_source := 'api';
  END IF;$o$,
  $n$    v_source := 'api';
  END IF;
  /* exos: reserve idempotency */ -- mig 20261104130000
  IF NOT p_dry_run AND nullif(a->>'idempotency_key', '') IS NOT NULL THEN
    IF (a->>'idempotency_key') !~ '^[A-Za-z0-9_.:-]{8,100}$' THEN
      RAISE EXCEPTION 'Idempotency-Key must be 8-100 letters, digits, _ . : or -' USING ERRCODE = '22023';
    END IF;
    -- A concurrent twin waits here, then finds the first one.
    PERFORM pg_advisory_xact_lock(hashtextextended('partner-reserve:' || p_org_id || ':' ||
      coalesce(p_partner_id, p_api_key_id) || ':' || (a->>'idempotency_key'), 0));
    DECLARE v_prev public.exos_partner_reservations%ROWTYPE;
    BEGIN
      SELECT * INTO v_prev FROM public.exos_partner_reservations
       WHERE org_id = p_org_id AND coalesce(partner_id, api_key_id) = coalesce(p_partner_id, p_api_key_id)
         AND idempotency_key = a->>'idempotency_key';
      IF v_prev.id IS NOT NULL THEN
        IF v_prev.request_hash IS DISTINCT FROM encode(sha256(convert_to(p_event_id || E'\n' || p_comp || E'\n' ||
             coalesce(p_lines, 'null'::jsonb)::text, 'UTF8')), 'hex') THEN
          RAISE EXCEPTION 'this Idempotency-Key was already used for another reservation' USING ERRCODE = '22023';
        END IF;
        PERFORM public._exos_partner_res_expire(v_prev.id);
        RETURN public._exos_partner_reservation_json(v_prev.id) || jsonb_build_object('idempotent_replay', true);
      END IF;
    END;
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid, uuid, uuid, uuid, jsonb, jsonb, boolean, boolean)',
  '/* exos: reserve idem store */',
  $o$  RETURN public._exos_partner_reservation_json(v_id);$o$,
  $n$  /* exos: reserve idem store */ -- mig 20261104130000
  IF nullif(a->>'idempotency_key', '') IS NOT NULL THEN
    UPDATE public.exos_partner_reservations
       SET idempotency_key = a->>'idempotency_key',
           request_hash = encode(sha256(convert_to(p_event_id || E'\n' || p_comp || E'\n' ||
                                                   coalesce(p_lines, 'null'::jsonb)::text, 'UTF8')), 'hex')
     WHERE id = v_id;
  END IF;
  RETURN public._exos_partner_reservation_json(v_id);$n$, 1);

-- A member presale (mig 20261030130500) is for members buying on the event's
-- own page; a marketplace has no member to check.
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid, uuid, uuid, uuid, jsonb, jsonb, boolean, boolean)',
  '/* exos: partner presale */',
  $o$    IF t.sales_start IS NOT NULL AND now() < t.sales_start THEN$o$,
  $n$    /* exos: partner presale */ -- mig 20261104130000
    IF p_partner_id IS NOT NULL AND public._exos_presale_blocks(p_event_id, t.id, NULL) THEN
      RAISE EXCEPTION '% is on presale for members right now; partners can sell it once the presale ends', t.name
        USING ERRCODE = 'EX422';
    END IF;
    IF t.sales_start IS NOT NULL AND now() < t.sales_start THEN$n$, 1);

-- ---------------------------------------------------------------------------
-- 6. Ticket types and events: no negative price, capacity or event cap.
-- ---------------------------------------------------------------------------
-- Add-ons and POS items already refuse these; ticket types and events did
-- not, so POST /v1/events/:id/ticket-types {"price": -5} made a type that
-- checkout would price below zero (and capacity 0 means unlimited, so a
-- negative capacity is never what was meant). NOT VALID: new and changed rows
-- are checked, rows already stored are left alone.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_ticket_tiers_price_nonneg_chk') THEN
    ALTER TABLE public.exos_ticket_tiers ADD CONSTRAINT exos_ticket_tiers_price_nonneg_chk
      CHECK (price IS NULL OR price >= 0) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_ticket_tiers_capacity_nonneg_chk') THEN
    ALTER TABLE public.exos_ticket_tiers ADD CONSTRAINT exos_ticket_tiers_capacity_nonneg_chk
      CHECK (capacity IS NULL OR capacity >= 0) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_total_tickets_nonneg_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_total_tickets_nonneg_chk
      CHECK (total_tickets IS NULL OR total_tickets >= 0) NOT VALID;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. The reservation sweep, every minute (where pg_cron exists).
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-partner-reservations-sweep') THEN
      PERFORM cron.unschedule('exos-partner-reservations-sweep');
    END IF;
    PERFORM cron.schedule('exos-partner-reservations-sweep', '* * * * *',
      'SELECT public.exos_partner_reservations_sweep(500)');
  END IF;
END $$;

-- ROLLBACK (manual): unschedule exos-partner-reservations-sweep; the columns
-- and patches are additive (re-create the functions from their migrations to
-- drop the patches).
