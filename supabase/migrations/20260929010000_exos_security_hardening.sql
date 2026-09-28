-- ============================================================================
-- Migration 20260929010000 — Exos (Bridge / D4): security hardening
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_vouchers (trigger, policies), exos_transfers (+claim_key,
--              column grants), exos_org_secrets (trigger), exos_event_addons
--              (trigger), exos_api_keys / exos_webhooks (offboarding trigger)
--           C: exos_voucher_attempts, exos_voucher_throttle(),
--              exos_claim_transfer(uuid, text), exos_transfer_claim_key(uuid)
--           W: FUNCTION exos_tier_available, exos_quota_available,
--              exos_check_voucher, exos_claim_transfer(uuid),
--              exos_fulfill_checkout,
--              exos_issue_comp_batch, exos_create_transfer,
--              exos_issue_ticket_to_email, exos_fulfil_marketplace_order,
--              exos_record_marketplace_order (patched in place)
-- Pre-reqs: 20260928080000
--
-- From the 2026-09-28 build review (all reproduced on a scratch database):
--
-- 1. Cross-org sell-out through a voucher. exos_vouchers' policy checked only
--    the voucher's event; its tier_id could name ANOTHER org's ticket type,
--    and a block_quota voucher then held that tier's seats (availability
--    subtracted blocking vouchers by tier alone). The victim couldn't see or
--    delete it. Now a trigger keeps tier_id on the voucher's own event, the
--    availability sums only count vouchers of the tier's own event, and any
--    such row already there is deleted (it could never be redeemed: checkout
--    only offers a voucher's tier on its own event). Finance reads vouchers
--    but no longer deletes them.
-- 2. Voucher codes could be guessed through the public check (no limit).
--    Failed lookups are now throttled: per signed-in account, and per event
--    for anonymous and server callers; new custom codes are at least 6
--    characters.
-- 3. Claim links were bearer links on the transfer id, which org staff
--    (scanner, finance, ...) can read: a door-staff account could claim a
--    guest's or a marketplace buyer's unclaimed ticket. Each transfer now has
--    a random claim_key that no client role can read; the emailed links
--    carry it (?k=), and exos_claim_transfer(id, key) claims into any
--    account. Without the key (links sent before this migration, the My
--    Tickets inbox) only the account whose email the transfer was sent to
--    can claim. The sender can read the key of their own transfer
--    (exos_transfer_claim_key) to share the link.
-- 4. A marketplace cancellation after tickets were issued only flagged the
--    order. Now the order's unused tickets are voided and their pending
--    transfers cancelled; if one was already scanned the order still goes to
--    a person.
-- 5. Offboarding: removing or disabling a member (or dropping them below
--    manager) revokes the API keys they created and switches off their
--    webhooks; keys whose creator already left are revoked now.
-- 6. The Stripe payout account (exos_org_secrets.payments) is set only by the
--    server (Connect onboarding, stripe-webhook): client writes can't change it.
-- 7. An add-on's tax rate must be one of its own event's rates.
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

-- ── 1. Vouchers stay on their own event ────────────────────────────────────

DO $clean$
DECLARE n int;
BEGIN
  DELETE FROM public.exos_vouchers v
   USING public.exos_ticket_tiers t
   WHERE t.id = v.tier_id AND t.event_id <> v.event_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n > 0 THEN RAISE NOTICE 'exos_vouchers: deleted % voucher(s) naming another event''s ticket type', n; END IF;
END $clean$;

CREATE OR REPLACE FUNCTION public.exos_tg_voucher_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.tier_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.exos_ticket_tiers t WHERE t.id = NEW.tier_id AND t.event_id = NEW.event_id
  ) THEN
    RAISE EXCEPTION 'exos_vouchers: that ticket type is not on this event' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_voucher_scope() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_vouchers_scope ON public.exos_vouchers;
CREATE TRIGGER exos_vouchers_scope BEFORE INSERT OR UPDATE OF event_id, tier_id ON public.exos_vouchers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_voucher_scope();

SELECT pg_temp.exos_patch('public.exos_tier_available(uuid)',
  'AND event_id = (SELECT t0.event_id FROM public.exos_ticket_tiers t0 WHERE t0.id = p_tier_id)',
  'WHERE tier_id = p_tier_id AND block_quota AND used_count < max_uses',
  'WHERE tier_id = p_tier_id AND block_quota AND used_count < max_uses
      AND event_id = (SELECT t0.event_id FROM public.exos_ticket_tiers t0 WHERE t0.id = p_tier_id)');

SELECT pg_temp.exos_patch('public.exos_quota_available(uuid)',
  'AND v.event_id = (SELECT q0.event_id FROM public.exos_quotas q0 WHERE q0.id = p_quota_id)',
  'WHERE v.tier_id IN (SELECT tier_id FROM public.exos_quota_tiers WHERE quota_id = p_quota_id)',
  'WHERE v.tier_id IN (SELECT tier_id FROM public.exos_quota_tiers WHERE quota_id = p_quota_id)
     AND v.event_id = (SELECT q0.event_id FROM public.exos_quotas q0 WHERE q0.id = p_quota_id)');

-- Owner / manager manage vouchers; finance only reads them.
DROP POLICY IF EXISTS exos_vouchers_all ON public.exos_vouchers;
DROP POLICY IF EXISTS exos_vouchers_sel ON public.exos_vouchers;
DROP POLICY IF EXISTS exos_vouchers_write ON public.exos_vouchers;
CREATE POLICY exos_vouchers_sel ON public.exos_vouchers FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e
                  WHERE e.id = exos_vouchers.event_id
                    AND public.exos_has_org_role(e.org_id, ARRAY['owner','manager','finance'])));
CREATE POLICY exos_vouchers_write ON public.exos_vouchers FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e
                  WHERE e.id = exos_vouchers.event_id
                    AND public.exos_has_org_role(e.org_id, ARRAY['owner','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_events e
                       WHERE e.id = exos_vouchers.event_id
                         AND public.exos_has_org_role(e.org_id, ARRAY['owner','manager'])));

-- ── 2. Voucher guessing ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.exos_voucher_attempts (
  bucket       text        NOT NULL,
  window_start timestamptz NOT NULL,
  failures     int         NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket, window_start)
);
ALTER TABLE public.exos_voucher_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_voucher_attempts FROM PUBLIC, anon, authenticated;

-- p_failed NULL: may this caller look a code up now? true/false: record the
-- outcome (only failures count). Windows are 10 minutes. Signed-in accounts
-- get 10 misses; anonymous callers share 60 per event, the server
-- (exos-checkout, which has its own per-network limit) 120 per event.
CREATE OR REPLACE FUNCTION public.exos_voucher_throttle(p_event_id uuid, p_failed boolean DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_role   text := coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                            nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
  v_bucket text;
  v_limit  int;
  v_win    timestamptz := to_timestamp(floor(extract(epoch FROM now()) / 600) * 600);
  v_n      int;
BEGIN
  IF v_uid IS NOT NULL THEN
    v_bucket := 'u:' || v_uid; v_limit := 10;
  ELSIF v_role = 'service_role' THEN
    v_bucket := 's:' || p_event_id; v_limit := 120;
  ELSE
    v_bucket := 'a:' || p_event_id; v_limit := 60;
  END IF;
  IF p_failed IS NULL THEN
    SELECT failures INTO v_n FROM public.exos_voucher_attempts WHERE bucket = v_bucket AND window_start = v_win;
    RETURN coalesce(v_n, 0) < v_limit;
  END IF;
  IF p_failed THEN
    INSERT INTO public.exos_voucher_attempts (bucket, window_start, failures) VALUES (v_bucket, v_win, 1)
    ON CONFLICT (bucket, window_start) DO UPDATE SET failures = public.exos_voucher_attempts.failures + 1;
    DELETE FROM public.exos_voucher_attempts WHERE window_start < now() - interval '1 day';
  END IF;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_voucher_throttle(uuid, boolean) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch('public.exos_check_voucher(uuid, text, text)',
  'exos_voucher_throttle(p_event_id)',
  'BEGIN
  SELECT * INTO v FROM public.exos_vouchers
   WHERE event_id = p_event_id AND upper(code) = upper(btrim(p_code));
  IF NOT FOUND THEN
    RETURN QUERY',
  'BEGIN
  -- Guessing codes is throttled (mig 20260929010000).
  IF NOT public.exos_voucher_throttle(p_event_id) THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, ''too many attempts''; RETURN;
  END IF;
  SELECT * INTO v FROM public.exos_vouchers
   WHERE event_id = p_event_id AND upper(code) = upper(btrim(p_code));
  IF NOT FOUND THEN
    PERFORM public.exos_voucher_throttle(p_event_id, true);
    RETURN QUERY');
-- It now records misses, so the discount lookup that calls it can't be STABLE.
ALTER FUNCTION public.exos_voucher_discount(uuid, text, text) VOLATILE;

-- Codes a person types in (an organizer, through the editor or the API) are
-- at least 6 characters; existing ones keep working, and the server's own
-- codes (waitlist offers, carry-overs) are long already.
CREATE OR REPLACE FUNCTION public.exos_tg_voucher_code_length()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND length(btrim(NEW.code)) < 6
     AND (TG_OP = 'INSERT' OR NEW.code IS DISTINCT FROM OLD.code) THEN
    RAISE EXCEPTION 'exos_vouchers: codes need at least 6 characters' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_voucher_code_length() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_vouchers_code_length ON public.exos_vouchers;
CREATE TRIGGER exos_vouchers_code_length BEFORE INSERT OR UPDATE OF code ON public.exos_vouchers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_voucher_code_length();

-- ── 3. Claim links carry a key staff can't read ────────────────────────────

ALTER TABLE public.exos_transfers
  ADD COLUMN IF NOT EXISTS claim_key text NOT NULL DEFAULT encode(extensions.gen_random_bytes(16), 'hex');

-- Inserts built with jsonb_populate_record pass NULL, not the default.
CREATE OR REPLACE FUNCTION public.exos_tg_transfer_claim_key()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.claim_key IS NULL OR length(NEW.claim_key) < 32 THEN
    NEW.claim_key := encode(extensions.gen_random_bytes(16), 'hex');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_transfer_claim_key() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_transfers_claim_key ON public.exos_transfers;
CREATE TRIGGER exos_transfers_claim_key BEFORE INSERT ON public.exos_transfers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_transfer_claim_key();

-- Every column but claim_key for signed-in users (row access stays with RLS).
DO $grants$
DECLARE v_cols text;
BEGIN
  SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) INTO v_cols
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'exos_transfers' AND column_name <> 'claim_key';
  EXECUTE 'REVOKE SELECT ON public.exos_transfers FROM anon, authenticated';
  EXECUTE 'REVOKE SELECT (claim_key) ON public.exos_transfers FROM anon, authenticated';
  EXECUTE format('GRANT SELECT (%s) ON public.exos_transfers TO authenticated', v_cols);
  EXECUTE 'REVOKE INSERT, UPDATE ON public.exos_transfers FROM anon, authenticated';
END $grants$;

-- Without the key, only the account the transfer was sent to may claim.
SELECT pg_temp.exos_patch('public.exos_claim_transfer(uuid)',
  'exos.claim_key_ok',
  '  -- Transfers are claimed into any account (mig 20260927010000): the
  -- receiver email is only where the link was sent. First claim wins.
',
  '  -- Transfers are claimed into any account (mig 20260927010000): the
  -- receiver email is only where the link was sent. First claim wins.
  -- But only with the link''s key (mig 20260929010000: exos_claim_transfer(id,
  -- key) vouches for it); without it, only the address it was sent to.
  IF current_setting(''exos.claim_key_ok'', true) IS DISTINCT FROM p_transfer_id::text
     AND lower(coalesce(tr.receiver_email, '''')) <> v_email THEN
    RAISE EXCEPTION ''exos_claim_transfer: open the claim link from the email, or sign in with the address it was sent to''
      USING ERRCODE = ''42501'';
  END IF;
');

-- With the key from the link: any verified account (first claim wins).
CREATE OR REPLACE FUNCTION public.exos_claim_transfer(p_transfer_id uuid, p_key text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_key text; v_ticket uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_claim_transfer: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT claim_key INTO v_key FROM public.exos_transfers WHERE id = p_transfer_id;
  IF v_key IS NULL OR p_key IS NULL
     OR extensions.digest(v_key, 'sha256') <> extensions.digest(btrim(p_key), 'sha256') THEN
    RAISE EXCEPTION 'exos_claim_transfer: this claim link is not valid' USING ERRCODE = '42501';
  END IF;
  -- Transaction-local; clients can't set it (no SQL access, not an exposed function).
  PERFORM set_config('exos.claim_key_ok', p_transfer_id::text, true);
  v_ticket := public.exos_claim_transfer(p_transfer_id);
  PERFORM set_config('exos.claim_key_ok', '', true);
  RETURN v_ticket;
END $$;
REVOKE ALL ON FUNCTION public.exos_claim_transfer(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_claim_transfer(uuid, text) TO authenticated, service_role;

-- The sender's own link, to forward it (TransferTicket's "copy link").
CREATE OR REPLACE FUNCTION public.exos_transfer_claim_key(p_transfer_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT tr.claim_key FROM public.exos_transfers tr
   WHERE tr.id = p_transfer_id AND tr.sender_id = auth.uid() AND tr.status = 'pending';
$$;
REVOKE ALL ON FUNCTION public.exos_transfer_claim_key(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_transfer_claim_key(uuid) TO authenticated;

-- The emailed links.
SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  'tr0.claim_key',
  '/claim/'' || tr.id || ''">Claim ticket '' || n',
  '/claim/'' || tr.id || ''?k='' || tr.claim_key || ''">Claim ticket '' || n');
SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  'SELECT tr0.id, tr0.claim_key,',
  'SELECT tr0.id, row_number()',
  'SELECT tr0.id, tr0.claim_key, row_number()');
SELECT pg_temp.exos_patch('public.exos_issue_comp_batch(uuid, uuid, text[], integer, text)',
  '?k=',
  '/claim/'' || tr.id || ''">Claim ticket</a></li>''',
  '/claim/'' || tr.id || ''?k='' || tr.claim_key || ''">Claim ticket</a></li>''');
SELECT pg_temp.exos_patch('public.exos_issue_ticket_to_email(uuid, uuid, text, integer, text)',
  '?k=',
  '/claim/'' || tr.id || ''">Claim ticket</a></li>''',
  '/claim/'' || tr.id || ''?k='' || tr.claim_key || ''">Claim ticket</a></li>''');
SELECT pg_temp.exos_patch('public.exos_create_transfer(uuid, text, text)',
  '?k=',
  '''<a href="{{app_url}}/claim/'' || v_transfer_id || ''">{{app_url}}/claim/'' || v_transfer_id || ''</a></p>''',
  '''<a href="{{app_url}}/claim/'' || v_transfer_id || ''?k='' || (SELECT k0.claim_key FROM public.exos_transfers k0 WHERE k0.id = v_transfer_id) ||
            ''">{{app_url}}/claim/'' || v_transfer_id || ''?k='' || (SELECT k0.claim_key FROM public.exos_transfers k0 WHERE k0.id = v_transfer_id) || ''</a></p>''');
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  '?k=',
  '''/claim/'' || v_trs[i] || ''">Claim ticket ''',
  '''/claim/'' || v_trs[i] || ''?k='' || (SELECT k0.claim_key FROM public.exos_transfers k0 WHERE k0.id = v_trs[i]) || ''">Claim ticket ''');

-- ── 4. A marketplace cancellation voids what was issued ────────────────────

SELECT pg_temp.exos_patch('public.exos_record_marketplace_order(jsonb)',
  'cancelled on the marketplace after a ticket was scanned',
  '    ELSIF o.status IN (''fulfilled'',''delivered'') THEN
      UPDATE public.exos_marketplace_orders
         SET status = ''needs_attention'',
             attention_reason = ''cancelled on the marketplace after tickets were issued: void them'',
             updated_at = now()
       WHERE id = o.id RETURNING * INTO o;
    END IF;',
  '    ELSIF o.status IN (''fulfilled'',''delivered'') THEN
      -- The marketplace refunded its buyer: their tickets stop working.
      UPDATE public.exos_transfers x SET status = ''cancelled'', updated_at = now()
       WHERE x.ticket_id = ANY (o.ticket_ids) AND x.status = ''pending'';
      UPDATE public.exos_tickets tk
         SET status = ''voided'', voided_at = now(), pending_transfer_id = NULL,
             voided_reason = left(''cancelled on '' || o.channel || '': order '' || o.external_order_id, 500)
       WHERE tk.id = ANY (o.ticket_ids) AND tk.status = ''active'';
      IF EXISTS (SELECT 1 FROM public.exos_tickets tk WHERE tk.id = ANY (o.ticket_ids) AND tk.status = ''used'') THEN
        UPDATE public.exos_marketplace_orders
           SET status = ''needs_attention'',
               attention_reason = ''cancelled on the marketplace after a ticket was scanned: the rest were voided'',
               updated_at = now()
         WHERE id = o.id RETURNING * INTO o;
      ELSE
        UPDATE public.exos_marketplace_orders
           SET status = ''cancelled'', attention_reason = NULL, updated_at = now()
         WHERE id = o.id RETURNING * INTO o;
      END IF;
    END IF;');

-- ── 5. Offboarding revokes API keys and webhooks ───────────────────────────

CREATE OR REPLACE FUNCTION public.exos_tg_membership_offboard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  IF TG_OP = 'DELETE' OR NEW.disabled IS TRUE OR NEW.role NOT IN ('owner','manager') THEN
    UPDATE public.exos_api_keys SET revoked_at = now(), updated_at = now()
     WHERE org_id = r.org_id AND created_by = r.user_id AND revoked_at IS NULL;
    UPDATE public.exos_webhooks SET enabled = false, updated_at = now()
     WHERE org_id = r.org_id AND created_by = r.user_id AND enabled;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_membership_offboard() FROM PUBLIC, anon, authenticated;

DO $offboard$
BEGIN
  IF to_regclass('public.exos_api_keys') IS NOT NULL AND to_regclass('public.exos_webhooks') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS exos_memberships_offboard ON public.exos_org_memberships;
    CREATE TRIGGER exos_memberships_offboard
      AFTER DELETE OR UPDATE OF role, disabled ON public.exos_org_memberships
      FOR EACH ROW EXECUTE FUNCTION public.exos_tg_membership_offboard();
    -- Keys and webhooks whose creator is no longer an active owner or manager.
    UPDATE public.exos_api_keys k SET revoked_at = now(), updated_at = now()
     WHERE k.revoked_at IS NULL AND k.created_by IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                        WHERE m.org_id = k.org_id AND m.user_id = k.created_by
                          AND m.role IN ('owner','manager') AND m.disabled IS NOT TRUE);
    UPDATE public.exos_webhooks w SET enabled = false, updated_at = now()
     WHERE w.enabled AND w.created_by IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                        WHERE m.org_id = w.org_id AND m.user_id = w.created_by
                          AND m.role IN ('owner','manager') AND m.disabled IS NOT TRUE);
  END IF;
END $offboard$;

-- ── 6. The payout account is the server's to set ───────────────────────────

CREATE OR REPLACE FUNCTION public.exos_tg_org_secrets_payments()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF current_setting('request.jwt.claim.role', true) IN ('anon', 'authenticated')
     OR coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') IN ('anon', 'authenticated') THEN
    IF TG_OP = 'INSERT' THEN
      NEW.payments := NULL;
    ELSE
      NEW.payments := OLD.payments;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_org_secrets_payments() FROM PUBLIC, anon, authenticated;
DO $secrets$
BEGIN
  IF to_regclass('public.exos_org_secrets') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS exos_org_secrets_payments ON public.exos_org_secrets;
    CREATE TRIGGER exos_org_secrets_payments BEFORE INSERT OR UPDATE ON public.exos_org_secrets
      FOR EACH ROW EXECUTE FUNCTION public.exos_tg_org_secrets_payments();
  END IF;
END $secrets$;

-- ── 7. An add-on's tax rate belongs to its event ───────────────────────────

CREATE OR REPLACE FUNCTION public.exos_tg_addon_tax_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.tax_rate_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.exos_tax_rules r WHERE r.id = NEW.tax_rate_id AND r.event_id = NEW.event_id
  ) THEN
    RAISE EXCEPTION 'exos_event_addons: that tax rate is not on this event' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_addon_tax_scope() FROM PUBLIC, anon, authenticated;
DO $addons$
BEGIN
  IF to_regclass('public.exos_event_addons') IS NOT NULL AND to_regclass('public.exos_tax_rules') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS exos_event_addons_tax_scope ON public.exos_event_addons;
    CREATE TRIGGER exos_event_addons_tax_scope BEFORE INSERT OR UPDATE OF event_id, tax_rate_id ON public.exos_event_addons
      FOR EACH ROW EXECUTE FUNCTION public.exos_tg_addon_tax_scope();
  END IF;
END $addons$;
