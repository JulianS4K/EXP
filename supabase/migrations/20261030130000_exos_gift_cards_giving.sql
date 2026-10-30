-- ============================================================================
-- Gift cards and giving (Opendate parity, round 12). docs/gift-cards.md,
-- docs/giving.md.
-- ============================================================================
-- Touches:  N: exos_gift_card_products, exos_gift_cards, exos_gift_card_ledger,
--              exos_gift_card_redemptions, exos_giving_campaigns, exos_donations,
--              exos_donation_receipt_counters, exos_commerce_orders (tables)
--           N: exos_public_gift_card_products, exos_public_giving_campaigns (views)
--           N: gift card + giving + commerce-order functions (see each)
--           A: exos_checkout_sessions.gift_card_cents / donation_cents /
--              donation_campaign_id (checkout pays with a gift card, adds a donation)
--           C: exos_mail template list (+ gift-card-issued, donation-receipt);
--              exos_price_disclosure_lines.kind (+ donation)
--           P: exos_fulfill_checkout (commerce hook + ticket price excludes the
--              donation, includes the gift card part), exos_refund_ticket_state
--              (refund pool excludes the donation), exos_tg_invoice (invoice total
--              = order value, not just the card part), exos_record_price_charged
--              (the gift card part counts as paid)
--           N: trigger exos_checkout_commerce on exos_checkout_sessions
-- Pre-reqs: 20261027100000 (fee rules) and everything before it.
--
-- Money: integer minor units everywhere. A gift card is a payment method, not a
-- discount: fees and tax are computed on the full price, then the card pays what
-- it can. Every balance change is one exos_gift_card_ledger row (unique per card,
-- kind and key), and the card row is locked for every change, so a hold, a
-- refund or a void can't race another.
--
-- Codes: 16 characters (15 random from a 32-letter alphabet = 75 bits, then a
-- Luhn mod 32 check character). Only SHA-256 of the code is stored; the plain
-- code is returned once at issue (and mailed). A lost code is replaced by
-- exos_gift_card_reissue_code (the old one stops working).
--
-- Checkout lifecycle of a gift card part (exos-checkout + this file):
--   quote (nothing reserved) -> Stripe session for the rest -> hold (balance
--   moves now, ledger 'redeem', redemption 'held') -> fulfillment captures it in
--   the same transaction as the tickets (XF001 if the hold is gone) -> the
--   session's status trigger gives it back on failed / expired (ledger
--   'release') or on a full refund (ledger 'refund').
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
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

-- Who called a SECURITY DEFINER function: inside one, current_user is the
-- owner, so it can't tell the service role from a signed-in user. The role
-- PostgREST (or a test) set for the request can; a direct superuser session
-- (migrations, cron) has none.
CREATE OR REPLACE FUNCTION public._exos_caller_is_service()
RETURNS boolean LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(nullif(current_setting('role', true), 'none'), session_user::text)
         IN ('service_role', 'postgres', 'supabase_admin');
$$;
REVOKE ALL ON FUNCTION public._exos_caller_is_service() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_caller_is_service() TO service_role;

-- ---------------------------------------------------------------------------
-- 0. Constraint lists: mail templates and price-disclosure line kinds. Rebuilt
--    from the live definition so a sibling migration's additions survive.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_def text; v_add text[] := ARRAY['gift-card-issued', 'donation-receipt', 'membership-gift',
                                         'membership-household', 'membership-welcome'];
        v_list text[]; t text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF v_def IS NULL THEN RETURN; END IF;
  SELECT array_agg(m[1]) INTO v_list FROM regexp_matches(v_def, '''([a-z0-9-]+)''', 'g') m;
  FOREACH t IN ARRAY v_add LOOP
    IF NOT t = ANY (v_list) THEN v_list := v_list || t; END IF;
  END LOOP;
  IF v_def NOT LIKE '%membership-welcome%' THEN
    ALTER TABLE public.exos_mail DROP CONSTRAINT exos_mail_template_check;
    EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template = ANY (%L::text[]))', v_list);
  END IF;
END $$;

DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_price_disclosure_lines'::regclass AND c.conname = 'exos_price_disclosure_lines_kind_check';
  IF v_def IS NOT NULL AND v_def NOT LIKE '%donation%' THEN
    ALTER TABLE public.exos_price_disclosure_lines DROP CONSTRAINT exos_price_disclosure_lines_kind_check;
    ALTER TABLE public.exos_price_disclosure_lines ADD CONSTRAINT exos_price_disclosure_lines_kind_check
      CHECK (kind = ANY (ARRAY['ticket', 'addon', 'donation']));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. Gift card products and cards
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_gift_card_products (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name          text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  description   text CHECK (description IS NULL OR length(description) <= 2000),
  currency      text NOT NULL DEFAULT 'usd' CHECK (currency ~ '^[a-z]{3}$'),
  amount_type   text NOT NULL DEFAULT 'fixed' CHECK (amount_type IN ('fixed', 'open')),
  amounts_cents integer[] NOT NULL DEFAULT '{}',
  min_cents     integer CHECK (min_cents IS NULL OR min_cents >= 100),
  max_cents     integer CHECK (max_cents IS NULL OR max_cents <= 100000000),
  image_url     text CHECK (image_url IS NULL OR (length(image_url) <= 1000 AND image_url ~ '^https://')),
  -- NULL = never expires (the default: many places limit or ban expiry).
  expiry_months integer CHECK (expiry_months IS NULL OR expiry_months BETWEEN 1 AND 240),
  active        boolean NOT NULL DEFAULT true,
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_gift_card_products_amounts_chk CHECK (
    (amount_type = 'fixed' AND cardinality(amounts_cents) BETWEEN 1 AND 12
       AND 100 <= ALL (amounts_cents) AND 100000000 >= ALL (amounts_cents))
    OR (amount_type = 'open' AND min_cents IS NOT NULL AND max_cents IS NOT NULL AND min_cents <= max_cents))
);
CREATE INDEX IF NOT EXISTS exos_gift_card_products_org_idx ON public.exos_gift_card_products (org_id);

CREATE TABLE IF NOT EXISTS public.exos_gift_cards (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  product_id      uuid REFERENCES public.exos_gift_card_products (id) ON DELETE SET NULL,
  code_hash       text NOT NULL UNIQUE CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  last4           text NOT NULL CHECK (last4 ~ '^[A-Z2-9]{4}$'),
  currency        text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  initial_cents   integer NOT NULL CHECK (initial_cents > 0 AND initial_cents <= 100000000),
  balance_cents   integer NOT NULL CHECK (balance_cents >= 0),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'voided')),
  source          text NOT NULL CHECK (source IN ('online', 'box_office', 'api', 'dashboard')),
  payment_method  text NOT NULL CHECK (payment_method IN ('card', 'cash', 'check', 'comp')),
  purchaser_uid   uuid,
  purchaser_email text CHECK (purchaser_email IS NULL OR length(purchaser_email) <= 320),
  recipient_email text CHECK (recipient_email IS NULL OR length(recipient_email) <= 320),
  recipient_name  text CHECK (recipient_name IS NULL OR length(recipient_name) <= 120),
  message         text CHECK (message IS NULL OR length(message) <= 1000),
  -- Issuing idempotency: the commerce order's Stripe session id or the till's
  -- external sale id (unique per org).
  issue_key       text CHECK (issue_key IS NULL OR issue_key ~ '^[A-Za-z0-9_:.-]{1,200}$'),
  issued_by       uuid,
  expires_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_gift_cards_balance_le_initial CHECK (balance_cents <= initial_cents)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_gift_cards_issue_key_uq ON public.exos_gift_cards (org_id, issue_key) WHERE issue_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_gift_cards_org_idx ON public.exos_gift_cards (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_gift_cards_purchaser_idx ON public.exos_gift_cards (purchaser_uid) WHERE purchaser_uid IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_gift_cards_recipient_idx ON public.exos_gift_cards (lower(recipient_email)) WHERE recipient_email IS NOT NULL;

-- Every balance change. amount_cents is signed (issue +, redeem -, release +,
-- refund +, void -, adjust ±); balance_after is the card's balance after it.
CREATE TABLE IF NOT EXISTS public.exos_gift_card_ledger (
  id            bigserial PRIMARY KEY,
  card_id       uuid NOT NULL REFERENCES public.exos_gift_cards (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('issue', 'redeem', 'release', 'refund', 'void', 'adjust')),
  amount_cents  integer NOT NULL,
  balance_after integer NOT NULL CHECK (balance_after >= 0),
  session_id    text,
  key           text NOT NULL CHECK (length(key) BETWEEN 1 AND 200),
  actor         uuid,
  note          text CHECK (note IS NULL OR length(note) <= 500),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (card_id, kind, key)
);
CREATE INDEX IF NOT EXISTS exos_gift_card_ledger_card_idx ON public.exos_gift_card_ledger (card_id, id);

-- What an order took from which card. One card per order.
CREATE TABLE IF NOT EXISTS public.exos_gift_card_redemptions (
  session_id     text PRIMARY KEY,
  card_id        uuid NOT NULL REFERENCES public.exos_gift_cards (id) ON DELETE CASCADE,
  org_id         uuid NOT NULL,
  amount_cents   integer NOT NULL CHECK (amount_cents > 0),
  refunded_cents integer NOT NULL DEFAULT 0 CHECK (refunded_cents >= 0),
  status         text NOT NULL DEFAULT 'held' CHECK (status IN ('held', 'captured', 'released')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_gift_card_redemptions_refund_le CHECK (refunded_cents <= amount_cents)
);
CREATE INDEX IF NOT EXISTS exos_gift_card_redemptions_card_idx ON public.exos_gift_card_redemptions (card_id);
CREATE INDEX IF NOT EXISTS exos_gift_card_redemptions_held_idx ON public.exos_gift_card_redemptions (created_at) WHERE status = 'held';

DROP TRIGGER IF EXISTS exos_gift_card_products_touch ON public.exos_gift_card_products;
CREATE TRIGGER exos_gift_card_products_touch BEFORE UPDATE ON public.exos_gift_card_products
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_gift_cards_touch ON public.exos_gift_cards;
CREATE TRIGGER exos_gift_cards_touch BEFORE UPDATE ON public.exos_gift_cards
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_gift_card_redemptions_touch ON public.exos_gift_card_redemptions;
CREATE TRIGGER exos_gift_card_redemptions_touch BEFORE UPDATE ON public.exos_gift_card_redemptions
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_gift_card_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_gift_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_gift_card_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_gift_card_redemptions ENABLE ROW LEVEL SECURITY;

-- Products: owner / manager write; finance and door staff (box office) read.
REVOKE ALL ON public.exos_gift_card_products FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_gift_card_products TO authenticated;
DROP POLICY IF EXISTS exos_gift_card_products_sel ON public.exos_gift_card_products;
CREATE POLICY exos_gift_card_products_sel ON public.exos_gift_card_products FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance', 'scanner']) OR public.exos_is_admin());
DROP POLICY IF EXISTS exos_gift_card_products_ins ON public.exos_gift_card_products;
CREATE POLICY exos_gift_card_products_ins ON public.exos_gift_card_products FOR INSERT TO authenticated
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin());
DROP POLICY IF EXISTS exos_gift_card_products_upd ON public.exos_gift_card_products;
CREATE POLICY exos_gift_card_products_upd ON public.exos_gift_card_products FOR UPDATE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin())
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin());
DROP POLICY IF EXISTS exos_gift_card_products_del ON public.exos_gift_card_products;
CREATE POLICY exos_gift_card_products_del ON public.exos_gift_card_products FOR DELETE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin());

-- Cards: staff read (owner / manager / finance); no client writes. Balances only
-- move inside the definer functions below.
REVOKE ALL ON public.exos_gift_cards FROM anon, authenticated;
GRANT SELECT ON public.exos_gift_cards TO authenticated;
DROP POLICY IF EXISTS exos_gift_cards_sel ON public.exos_gift_cards;
CREATE POLICY exos_gift_cards_sel ON public.exos_gift_cards FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin());

-- Ledger and redemptions: service role only (staff read the ledger through
-- exos_gift_card_ledger_for).
REVOKE ALL ON public.exos_gift_card_ledger FROM anon, authenticated;
REVOKE ALL ON public.exos_gift_card_redemptions FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.exos_gift_card_ledger_id_seq FROM anon, authenticated;

-- Product id/org can't move; org_id of a product is fixed.
CREATE OR REPLACE FUNCTION public._exos_tg_gift_card_product_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.org_id <> OLD.org_id OR NEW.currency <> OLD.currency) THEN
    RAISE EXCEPTION 'a gift card product''s organization and currency can''t change' USING ERRCODE = '22023';
  END IF;
  NEW.name := btrim(NEW.name);
  IF TG_OP = 'INSERT' THEN NEW.created_by := coalesce(NEW.created_by, auth.uid()); END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_gift_card_product_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_gift_card_products_guard ON public.exos_gift_card_products;
CREATE TRIGGER exos_gift_card_products_guard BEFORE INSERT OR UPDATE ON public.exos_gift_card_products
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_gift_card_product_guard();

-- A product that has sold cards can't be deleted (deactivate it instead).
CREATE OR REPLACE FUNCTION public._exos_tg_gift_card_product_del()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.exos_gift_cards c WHERE c.product_id = OLD.id) THEN
    RAISE EXCEPTION 'this product has sold gift cards: deactivate it instead' USING ERRCODE = '23503';
  END IF;
  RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_gift_card_product_del() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_gift_card_products_del ON public.exos_gift_card_products;
CREATE TRIGGER exos_gift_card_products_del BEFORE DELETE ON public.exos_gift_card_products
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_gift_card_product_del();

-- Buyers: the active products of an org (no creator, no timestamps).
CREATE OR REPLACE VIEW public.exos_public_gift_card_products WITH (security_barrier = true) AS
  SELECT p.id, p.org_id, o.slug AS org_slug, o.name AS org_name, p.name, p.description, p.currency,
         p.amount_type, p.amounts_cents, p.min_cents, p.max_cents, p.image_url, p.expiry_months
    FROM public.exos_gift_card_products p
    JOIN public.exos_orgs o ON o.id = p.org_id
   WHERE p.active;
REVOKE ALL ON public.exos_public_gift_card_products FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_gift_card_products TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Codes
-- ---------------------------------------------------------------------------
-- Upper case, no dashes or spaces. NULL if anything else is left.
CREATE OR REPLACE FUNCTION public.exos_gift_card_normalize(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN x ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{16}$' THEN x END
    FROM (SELECT upper(regexp_replace(coalesce(p_code, ''), '[\s-]', '', 'g')) AS x) s;
$$;

-- Luhn mod 32 over the alphabet; true for a well-formed code.
CREATE OR REPLACE FUNCTION public.exos_gift_card_check_ok(p_code text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text := public.exos_gift_card_normalize(p_code);
        f int := 1; s int := 0; v int; i int;
BEGIN
  IF c IS NULL THEN RETURN false; END IF;
  FOR i IN REVERSE 16..1 LOOP
    v := (position(substr(c, i, 1) in a) - 1) * f;
    s := s + v / 32 + v % 32;
    f := CASE WHEN f = 2 THEN 1 ELSE 2 END;
  END LOOP;
  RETURN s % 32 = 0;
END $$;

CREATE OR REPLACE FUNCTION public._exos_gift_card_hash(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT encode(sha256(convert_to('exos-gift-card:' || public.exos_gift_card_normalize(p_code), 'UTF8')), 'hex');
$$;

-- 15 random characters (one byte each, mod 32: uniform) + the check character.
CREATE OR REPLACE FUNCTION public._exos_gift_card_new_code()
RETURNS text LANGUAGE plpgsql VOLATILE SET search_path = public, pg_temp AS $$
DECLARE a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        b bytea := extensions.gen_random_bytes(15); c text := ''; f int := 2; s int := 0; v int; i int;
BEGIN
  FOR i IN 0..14 LOOP c := c || substr(a, get_byte(b, i) % 32 + 1, 1); END LOOP;
  FOR i IN REVERSE 15..1 LOOP
    v := (position(substr(c, i, 1) in a) - 1) * f;
    s := s + v / 32 + v % 32;
    f := CASE WHEN f = 2 THEN 1 ELSE 2 END;
  END LOOP;
  RETURN c || substr(a, (32 - s % 32) % 32 + 1, 1);
END $$;

REVOKE ALL ON FUNCTION public.exos_gift_card_normalize(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_normalize(text) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.exos_gift_card_check_ok(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_check_ok(text) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_gift_card_hash(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_gift_card_new_code() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Ledger primitive: change a LOCKED card's balance and write the row.
--    Idempotent per (card, kind, key): a repeat returns false and moves nothing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_gift_card_move(
  p_card_id uuid, p_kind text, p_amount integer, p_key text, p_session text, p_actor uuid, p_note text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_gift_cards%ROWTYPE; v_new int;
BEGIN
  SELECT * INTO c FROM public.exos_gift_cards WHERE id = p_card_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'gift card not found' USING ERRCODE = 'P0002'; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_gift_card_ledger l
              WHERE l.card_id = p_card_id AND l.kind = p_kind AND l.key = p_key) THEN
    RETURN false;
  END IF;
  v_new := c.balance_cents + p_amount;
  IF v_new < 0 THEN RAISE EXCEPTION 'gift card balance too low' USING ERRCODE = '22003'; END IF;
  IF v_new > c.initial_cents THEN RAISE EXCEPTION 'gift card balance above its value' USING ERRCODE = '22003'; END IF;
  IF p_amount <> 0 THEN
    UPDATE public.exos_gift_cards SET balance_cents = v_new WHERE id = p_card_id;
  END IF;
  INSERT INTO public.exos_gift_card_ledger (card_id, org_id, kind, amount_cents, balance_after, session_id, key, actor, note)
  VALUES (p_card_id, c.org_id, p_kind, p_amount, v_new, p_session, p_key, p_actor, left(p_note, 500));
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_gift_card_move(uuid, text, integer, text, text, uuid, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Issue
-- ---------------------------------------------------------------------------
-- Internal. Returns the card and, only when it was created now, the plain code.
-- Mails the code to the recipient (or the purchaser) when p_notify.
CREATE OR REPLACE FUNCTION public._exos_gift_card_issue(
  p_org_id uuid, p_product_id uuid, p_amount_cents integer, p_currency text, p_source text, p_method text,
  p_issue_key text, p_issued_by uuid, p_purchaser_uid uuid, p_purchaser_email text,
  p_recipient_email text, p_recipient_name text, p_message text, p_notify boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_prod public.exos_gift_card_products%ROWTYPE; v_card public.exos_gift_cards%ROWTYPE;
        v_code text; v_cur text := lower(coalesce(p_currency, '')); v_exp timestamptz; v_org text; v_to text; v_safe text;
BEGIN
  IF p_issue_key IS NOT NULL THEN
    SELECT * INTO v_card FROM public.exos_gift_cards WHERE org_id = p_org_id AND issue_key = p_issue_key;
    IF FOUND THEN
      RETURN jsonb_build_object('card_id', v_card.id, 'last4', v_card.last4, 'balance_cents', v_card.balance_cents,
        'currency', v_card.currency, 'fresh', false, 'code', NULL);
    END IF;
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents < 100 OR p_amount_cents > 100000000 THEN
    RAISE EXCEPTION 'gift card amount must be between 1.00 and 1,000,000.00' USING ERRCODE = '22023';
  END IF;
  IF p_product_id IS NOT NULL THEN
    SELECT * INTO v_prod FROM public.exos_gift_card_products WHERE id = p_product_id AND org_id = p_org_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'gift card product not found' USING ERRCODE = 'P0002'; END IF;
    v_cur := v_prod.currency;
    IF v_prod.amount_type = 'fixed' AND NOT p_amount_cents = ANY (v_prod.amounts_cents) THEN
      RAISE EXCEPTION 'that amount isn''t offered for this gift card' USING ERRCODE = '22023';
    END IF;
    IF v_prod.amount_type = 'open' AND (p_amount_cents < v_prod.min_cents OR p_amount_cents > v_prod.max_cents) THEN
      RAISE EXCEPTION 'amount must be between % and %', v_prod.min_cents, v_prod.max_cents USING ERRCODE = '22023';
    END IF;
    IF v_prod.expiry_months IS NOT NULL THEN
      v_exp := now() + make_interval(months => v_prod.expiry_months);
    END IF;
  END IF;
  IF v_cur !~ '^[a-z]{3}$' THEN RAISE EXCEPTION 'bad currency' USING ERRCODE = '22023'; END IF;

  v_code := public._exos_gift_card_new_code();
  INSERT INTO public.exos_gift_cards (org_id, product_id, code_hash, last4, currency, initial_cents, balance_cents,
    source, payment_method, purchaser_uid, purchaser_email, recipient_email, recipient_name, message,
    issue_key, issued_by, expires_at)
  VALUES (p_org_id, p_product_id, public._exos_gift_card_hash(v_code), right(v_code, 4), v_cur, p_amount_cents, 0,
    p_source, p_method, p_purchaser_uid, lower(nullif(btrim(p_purchaser_email), '')),
    lower(nullif(btrim(p_recipient_email), '')), nullif(btrim(p_recipient_name), ''), nullif(btrim(p_message), ''),
    p_issue_key, p_issued_by, v_exp)
  RETURNING * INTO v_card;
  PERFORM public._exos_gift_card_move(v_card.id, 'issue', p_amount_cents, 'issue', NULL, p_issued_by,
    p_source || ' / ' || p_method);

  v_to := coalesce(v_card.recipient_email, v_card.purchaser_email);
  IF p_notify AND v_to IS NOT NULL THEN
    SELECT name INTO v_org FROM public.exos_orgs WHERE id = p_org_id;
    v_safe := replace(replace(replace(coalesce(v_org, 'Exos'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    BEGIN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES ('gift-card-issued', v_to, left('Your ' || coalesce(v_org, '') || ' gift card', 200),
        '<p>' || CASE WHEN v_card.recipient_name IS NOT NULL
                      THEN replace(replace(replace(v_card.recipient_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ', you'
                      ELSE 'You' END ||
        ' have a <strong>' || v_safe || '</strong> gift card worth <strong>' ||
        to_char(p_amount_cents / 100.0, 'FM999,999,990.00') || ' ' || upper(v_cur) || '</strong>.</p>' ||
        coalesce('<p>' || replace(replace(replace(v_card.message, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</p>', '') ||
        '<p>Your code: <strong style="font-family:monospace;font-size:18px">' ||
        substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4) || '-' || substr(v_code, 13, 4) ||
        '</strong></p><p>Enter it at checkout on any of ' || v_safe || '''s events. Check the balance at {{app_url}}/gift-cards/balance.' ||
        coalesce(' It expires on ' || to_char(v_exp, 'YYYY-MM-DD') || '.', '') || ' Keep this email: the code is the card.</p>',
        p_issued_by, 'pending');
    EXCEPTION WHEN others THEN
      RAISE WARNING '_exos_gift_card_issue: mail not queued: %', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object('card_id', v_card.id, 'last4', v_card.last4, 'balance_cents', p_amount_cents,
    'currency', v_cur, 'fresh', true, 'code', v_code, 'expires_at', v_exp);
END $$;
REVOKE ALL ON FUNCTION public._exos_gift_card_issue(uuid, uuid, integer, text, text, text, text, uuid, uuid, text, text, text, text, boolean)
  FROM PUBLIC, anon, authenticated;

-- Staff: a box-office or dashboard sale (cash, check) or a comp. Owner and
-- manager may record any method; door staff (scanner) only cash or check.
-- p_external_id (the till's sale id) makes a retry return the same card (without
-- the code: it was shown once).
CREATE OR REPLACE FUNCTION public.exos_gift_card_issue(
  p_org_id uuid, p_amount_cents integer, p_payment_method text,
  p_product_id uuid DEFAULT NULL, p_currency text DEFAULT 'usd',
  p_recipient_email text DEFAULT NULL, p_recipient_name text DEFAULT NULL, p_message text DEFAULT NULL,
  p_purchaser_email text DEFAULT NULL, p_external_id text DEFAULT NULL, p_source text DEFAULT 'box_office')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_mgr boolean := public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  IF p_payment_method NOT IN ('cash', 'check', 'comp', 'card') THEN
    RAISE EXCEPTION 'payment method must be cash, check, comp or card' USING ERRCODE = '22023';
  END IF;
  IF p_source NOT IN ('box_office', 'dashboard') THEN RAISE EXCEPTION 'bad source' USING ERRCODE = '22023'; END IF;
  IF NOT v_mgr THEN
    IF NOT (public.exos_has_org_role(p_org_id, ARRAY['scanner']) AND p_payment_method IN ('cash', 'check')) THEN
      RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF NOT public.exos_rate_hit('gc-issue:' || auth.uid()::text, 30) THEN
    RAISE EXCEPTION 'too many gift cards a minute' USING ERRCODE = '54000';
  END IF;
  RETURN public._exos_gift_card_issue(p_org_id, p_product_id, p_amount_cents, p_currency, p_source, p_payment_method,
    CASE WHEN p_external_id IS NULL THEN NULL ELSE 'ext:' || p_external_id END, auth.uid(), NULL, p_purchaser_email,
    p_recipient_email, p_recipient_name, p_message, true);
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_issue(uuid, integer, text, uuid, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_issue(uuid, integer, text, uuid, text, text, text, text, text, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Look up, quote, hold, capture, release
-- ---------------------------------------------------------------------------
-- Internal: find a card by code. Never raises (a raise would roll back the
-- rate-limit hit with it): returns the card, or NULL and a buyer-readable error.
-- Rate limit per bucket (account id or hashed IP): 10 lookups a minute.
CREATE OR REPLACE FUNCTION public._exos_gift_card_find(p_code text, p_bucket text, p_org_id uuid, p_currency text,
  p_lock boolean, OUT card public.exos_gift_cards, OUT err text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_gift_cards%ROWTYPE;
BEGIN
  IF NOT public.exos_rate_hit('gc:' || left(coalesce(p_bucket, 'none'), 100), 10) THEN
    err := 'too many gift card attempts, try again in a minute'; RETURN;
  END IF;
  IF NOT public.exos_gift_card_check_ok(p_code) THEN
    err := 'that gift card code isn''t valid (check for a typo)'; RETURN;
  END IF;
  IF p_lock THEN
    SELECT * INTO c FROM public.exos_gift_cards WHERE code_hash = public._exos_gift_card_hash(p_code) FOR UPDATE;
  ELSE
    SELECT * INTO c FROM public.exos_gift_cards WHERE code_hash = public._exos_gift_card_hash(p_code);
  END IF;
  IF NOT FOUND THEN err := 'gift card not found'; RETURN; END IF;
  IF p_org_id IS NOT NULL AND c.org_id <> p_org_id THEN err := 'this gift card is for another organizer'; RETURN; END IF;
  IF p_currency IS NOT NULL AND c.currency <> lower(p_currency) THEN err := 'this gift card is in ' || upper(c.currency); RETURN; END IF;
  IF c.status <> 'active' THEN err := 'this gift card was voided'; RETURN; END IF;
  IF c.expires_at IS NOT NULL AND c.expires_at < now() THEN err := 'this gift card expired'; RETURN; END IF;
  IF c.balance_cents <= 0 THEN err := 'this gift card has no balance left'; card := c; RETURN; END IF;
  card := c;
END $$;
REVOKE ALL ON FUNCTION public._exos_gift_card_find(text, text, uuid, text, boolean) FROM PUBLIC, anon, authenticated;

-- Service role (exos-checkout, exos-commerce). Nothing reserved. Answers
-- { error } instead of raising, so a miss still counts against the rate limit.
CREATE OR REPLACE FUNCTION public.exos_gift_card_quote(p_code text, p_bucket text, p_org_id uuid DEFAULT NULL,
  p_currency text DEFAULT NULL, p_amount_cents integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE f record; v_org text;
BEGIN
  IF NOT public._exos_caller_is_service() THEN
    RAISE EXCEPTION 'exos_gift_card_quote: service role only' USING ERRCODE = '42501';
  END IF;
  f := public._exos_gift_card_find(p_code, p_bucket, p_org_id, p_currency, false);
  IF (f.card).id IS NULL THEN RETURN jsonb_build_object('error', f.err); END IF;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = (f.card).org_id;
  RETURN jsonb_build_object('error', f.err, 'last4', (f.card).last4, 'currency', (f.card).currency,
    'balance_cents', (f.card).balance_cents, 'initial_cents', (f.card).initial_cents, 'org_id', (f.card).org_id,
    'org_name', v_org, 'expires_at', (f.card).expires_at,
    'applicable_cents', CASE WHEN f.err IS NOT NULL THEN 0
                             WHEN p_amount_cents IS NULL THEN (f.card).balance_cents
                             ELSE least((f.card).balance_cents, greatest(p_amount_cents, 0)) END);
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_quote(text, text, uuid, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_quote(text, text, uuid, text, integer) TO service_role;

-- Signed-in balance check (the balance page when signed in; exos-commerce
-- serves signed-out visitors with a hashed-IP bucket through the quote above).
CREATE OR REPLACE FUNCTION public.exos_gift_card_balance(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE f record; v_org text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  f := public._exos_gift_card_find(p_code, 'u:' || auth.uid()::text, NULL, NULL, false);
  IF (f.card).id IS NULL THEN RETURN jsonb_build_object('error', f.err); END IF;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = (f.card).org_id;
  RETURN jsonb_build_object('error', CASE WHEN f.err LIKE '%no balance%' THEN NULL ELSE f.err END,
    'last4', (f.card).last4, 'currency', (f.card).currency, 'balance_cents', (f.card).balance_cents,
    'initial_cents', (f.card).initial_cents, 'org_name', v_org, 'expires_at', (f.card).expires_at);
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_balance(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_balance(text) TO authenticated, service_role;

-- Service role. Take exactly p_amount_cents off the card for an order and keep
-- it held until fulfillment. Idempotent per session (same card, same amount).
CREATE OR REPLACE FUNCTION public.exos_gift_card_hold(p_code text, p_session_id text, p_amount_cents integer,
  p_bucket text, p_org_id uuid, p_currency text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_gift_cards%ROWTYPE; r public.exos_gift_card_redemptions%ROWTYPE; f record;
BEGIN
  IF NOT public._exos_caller_is_service() THEN
    RAISE EXCEPTION 'exos_gift_card_hold: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_session_id IS NULL OR p_session_id !~ '^[A-Za-z0-9_-]{1,255}$' THEN
    RAISE EXCEPTION 'bad session id' USING ERRCODE = '22023';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN RAISE EXCEPTION 'bad amount' USING ERRCODE = '22023'; END IF;
  f := public._exos_gift_card_find(p_code, p_bucket, p_org_id, p_currency, true);
  -- An empty card may still be this session's own hold (a replay): checked below.
  IF (f.card).id IS NULL OR (f.err IS NOT NULL AND f.err NOT LIKE '%no balance%') THEN
    RAISE EXCEPTION '%', f.err USING ERRCODE = 'P0001';
  END IF;
  c := f.card;
  SELECT * INTO r FROM public.exos_gift_card_redemptions WHERE session_id = p_session_id FOR UPDATE;
  IF FOUND THEN
    IF r.card_id <> c.id OR r.amount_cents <> p_amount_cents OR r.status = 'released' THEN
      RAISE EXCEPTION 'this order already used a gift card' USING ERRCODE = 'P0001';
    END IF;
    RETURN jsonb_build_object('card_id', c.id, 'last4', c.last4, 'amount_cents', r.amount_cents,
      'balance_cents', c.balance_cents, 'fresh', false);
  END IF;
  IF c.balance_cents < p_amount_cents THEN
    RAISE EXCEPTION 'the gift card balance changed, please try again' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO public.exos_gift_card_redemptions (session_id, card_id, org_id, amount_cents)
  VALUES (p_session_id, c.id, c.org_id, p_amount_cents);
  PERFORM public._exos_gift_card_move(c.id, 'redeem', -p_amount_cents, p_session_id, p_session_id, NULL, 'held for checkout');
  RETURN jsonb_build_object('card_id', c.id, 'last4', c.last4, 'amount_cents', p_amount_cents,
    'balance_cents', c.balance_cents - p_amount_cents, 'fresh', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_hold(text, text, integer, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_hold(text, text, integer, text, uuid, text) TO service_role;

-- Internal (fulfillment): the held amount becomes spent. False if the hold is
-- missing, released or a different amount (the caller fails the order).
CREATE OR REPLACE FUNCTION public._exos_gift_card_capture(p_session_id text, p_amount_cents integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_gift_card_redemptions%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_gift_card_redemptions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND OR r.amount_cents <> p_amount_cents THEN RETURN false; END IF;
  IF r.status = 'captured' THEN RETURN true; END IF;
  IF r.status <> 'held' THEN RETURN false; END IF;
  UPDATE public.exos_gift_card_redemptions SET status = 'captured' WHERE session_id = p_session_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_gift_card_capture(text, integer) FROM PUBLIC, anon, authenticated;

-- Internal: give back a held amount (order failed / expired) or the not yet
-- refunded part of a captured one (order refunded). Idempotent.
CREATE OR REPLACE FUNCTION public._exos_gift_card_give_back(p_session_id text, p_reason text, p_actor uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_gift_card_redemptions%ROWTYPE; v_amt int;
BEGIN
  SELECT * INTO r FROM public.exos_gift_card_redemptions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND OR r.status = 'released' THEN RETURN 0; END IF;
  IF r.status = 'held' THEN
    PERFORM public._exos_gift_card_move(r.card_id, 'release', r.amount_cents, p_session_id, p_session_id, p_actor, p_reason);
    UPDATE public.exos_gift_card_redemptions SET status = 'released' WHERE session_id = p_session_id;
    RETURN r.amount_cents;
  END IF;
  v_amt := r.amount_cents - r.refunded_cents;
  IF v_amt <= 0 THEN RETURN 0; END IF;
  PERFORM public._exos_gift_card_move(r.card_id, 'refund', v_amt, p_session_id || ':rest:' || r.refunded_cents,
    p_session_id, p_actor, p_reason);
  UPDATE public.exos_gift_card_redemptions SET refunded_cents = amount_cents WHERE session_id = p_session_id;
  RETURN v_amt;
END $$;
REVOKE ALL ON FUNCTION public._exos_gift_card_give_back(text, text, uuid) FROM PUBLIC, anon, authenticated;

-- Staff (owner / manager): put part of an order's gift card payment back on the
-- card (a partial refund or a ticket void; the card part goes through Stripe).
-- Idempotent per p_key; never more than was taken.
CREATE OR REPLACE FUNCTION public.exos_gift_card_refund_order(p_session_id text, p_amount_cents integer DEFAULT NULL,
  p_key text DEFAULT 'full', p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_gift_card_redemptions%ROWTYPE; v_amt int; v_moved boolean;
BEGIN
  SELECT * INTO r FROM public.exos_gift_card_redemptions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'no gift card on this order' USING ERRCODE = 'P0002'; END IF;
  IF NOT (public.exos_has_org_role(r.org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()
          OR public._exos_caller_is_service()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF r.status <> 'captured' THEN RAISE EXCEPTION 'the order wasn''t paid with this card' USING ERRCODE = 'P0001'; END IF;
  IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9_:.-]{1,100}$' THEN RAISE EXCEPTION 'bad key' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_gift_card_ledger WHERE card_id = r.card_id AND kind = 'refund'
              AND key = p_session_id || ':' || p_key) THEN
    RETURN jsonb_build_object('refunded_cents', 0, 'fresh', false);
  END IF;
  v_amt := least(coalesce(p_amount_cents, r.amount_cents), r.amount_cents - r.refunded_cents);
  IF v_amt <= 0 THEN RETURN jsonb_build_object('refunded_cents', 0, 'fresh', false); END IF;
  v_moved := public._exos_gift_card_move(r.card_id, 'refund', v_amt, p_session_id || ':' || p_key, p_session_id,
    auth.uid(), coalesce(p_note, 'refund to gift card'));
  UPDATE public.exos_gift_card_redemptions SET refunded_cents = refunded_cents + v_amt WHERE session_id = p_session_id;
  RETURN jsonb_build_object('refunded_cents', v_amt, 'fresh', v_moved);
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_refund_order(text, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_refund_order(text, integer, text, text) TO authenticated, service_role;

-- Owner / manager: void a card (what's left on it is gone; ledger 'void').
CREATE OR REPLACE FUNCTION public.exos_gift_card_void(p_card_id uuid, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_gift_cards%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.exos_gift_cards WHERE id = p_card_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'gift card not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT (public.exos_has_org_role(c.org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()
          OR public._exos_caller_is_service()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF c.status = 'voided' THEN RETURN jsonb_build_object('voided_cents', 0, 'fresh', false); END IF;
  PERFORM public._exos_gift_card_move(c.id, 'void', -c.balance_cents, 'void', NULL, auth.uid(), coalesce(p_note, 'voided'));
  UPDATE public.exos_gift_cards SET status = 'voided' WHERE id = c.id;
  RETURN jsonb_build_object('voided_cents', c.balance_cents, 'fresh', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_void(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_void(uuid, text) TO authenticated, service_role;

-- Owner / manager: a lost code. New code, same balance; the old code stops working.
CREATE OR REPLACE FUNCTION public.exos_gift_card_reissue_code(p_card_id uuid, p_notify boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_gift_cards%ROWTYPE; v_code text := public._exos_gift_card_new_code();
BEGIN
  SELECT * INTO c FROM public.exos_gift_cards WHERE id = p_card_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'gift card not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT (public.exos_has_org_role(c.org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF c.status <> 'active' THEN RAISE EXCEPTION 'this gift card was voided' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.exos_gift_cards SET code_hash = public._exos_gift_card_hash(v_code), last4 = right(v_code, 4)
   WHERE id = c.id;
  PERFORM public._exos_gift_card_move(c.id, 'adjust', 0, 'reissue:' || gen_random_uuid()::text, NULL, auth.uid(),
    'new code (was ending ' || c.last4 || ')');
  IF p_notify AND coalesce(c.recipient_email, c.purchaser_email) IS NOT NULL THEN
    BEGIN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES ('gift-card-issued', coalesce(c.recipient_email, c.purchaser_email), 'Your new gift card code',
        '<p>Your gift card has a new code (the old one ending ' || c.last4 || ' no longer works): ' ||
        '<strong style="font-family:monospace;font-size:18px">' ||
        substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4) || '-' || substr(v_code, 13, 4) ||
        '</strong>. Balance: ' || to_char(c.balance_cents / 100.0, 'FM999,999,990.00') || ' ' || upper(c.currency) || '.</p>',
        auth.uid(), 'pending');
    EXCEPTION WHEN others THEN RAISE WARNING 'reissue mail not queued: %', SQLERRM;
    END;
  END IF;
  RETURN jsonb_build_object('card_id', c.id, 'code', v_code, 'last4', right(v_code, 4), 'balance_cents', c.balance_cents);
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_reissue_code(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_reissue_code(uuid, boolean) TO authenticated, service_role;

-- Owner / manager / finance: a card's ledger.
CREATE OR REPLACE FUNCTION public.exos_gift_card_ledger_for(p_card_id uuid)
RETURNS TABLE (id bigint, kind text, amount_cents integer, balance_after integer, session_id text, note text, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_gift_cards WHERE exos_gift_cards.id = p_card_id;
  IF v_org IS NULL OR NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT l.id, l.kind, l.amount_cents, l.balance_after, l.session_id, l.note, l.created_at
    FROM public.exos_gift_card_ledger l WHERE l.card_id = p_card_id ORDER BY l.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_ledger_for(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_ledger_for(uuid) TO authenticated, service_role;

-- Self: cards I bought or that were sent to my verified email (masked).
CREATE OR REPLACE FUNCTION public.exos_my_gift_cards()
RETURNS TABLE (id uuid, org_id uuid, org_name text, last4 text, currency text, initial_cents integer,
               balance_cents integer, status text, expires_at timestamptz, created_at timestamptz, sent_to_me boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_email text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL;
  RETURN QUERY SELECT c.id, c.org_id, o.name, c.last4, c.currency, c.initial_cents, c.balance_cents, c.status,
         c.expires_at, c.created_at, (v_email IS NOT NULL AND c.recipient_email = v_email)
    FROM public.exos_gift_cards c JOIN public.exos_orgs o ON o.id = c.org_id
   WHERE c.purchaser_uid = auth.uid() OR (v_email IS NOT NULL AND c.recipient_email = v_email)
   ORDER BY c.created_at DESC LIMIT 200;
END $$;
REVOKE ALL ON FUNCTION public.exos_my_gift_cards() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_my_gift_cards() TO authenticated;

-- Service role (a cron or the reconcile sweep): release holds whose order is no
-- longer pending (or still pending after 2 hours: Stripe sessions live 30 min).
CREATE OR REPLACE FUNCTION public.exos_gift_card_release_stale()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record; n int := 0;
BEGIN
  IF NOT public._exos_caller_is_service() THEN
    RAISE EXCEPTION 'service role only' USING ERRCODE = '42501';
  END IF;
  FOR r IN
    SELECT g.session_id FROM public.exos_gift_card_redemptions g
      LEFT JOIN public.exos_checkout_sessions s ON s.session_id = g.session_id
     WHERE g.status = 'held' AND g.created_at < now() - interval '35 minutes'
       AND (s.session_id IS NULL OR s.status IN ('failed', 'expired')
            OR (s.status = 'pending' AND s.created_at < now() - interval '2 hours'))
     LIMIT 500
  LOOP
    PERFORM public._exos_gift_card_give_back(r.session_id, 'hold released (order not completed)');
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.exos_gift_card_release_stale() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_release_stale() TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Giving: campaigns and donations
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_giving_campaigns (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name             text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  slug             text NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  description      text CHECK (description IS NULL OR length(description) <= 5000),
  image_url        text CHECK (image_url IS NULL OR (length(image_url) <= 1000 AND image_url ~ '^https://')),
  currency         text NOT NULL DEFAULT 'usd' CHECK (currency ~ '^[a-z]{3}$'),
  goal_cents       integer NOT NULL DEFAULT 0 CHECK (goal_cents BETWEEN 0 AND 1000000000),
  starts_at        timestamptz,
  ends_at          timestamptz,
  active           boolean NOT NULL DEFAULT true,
  suggested_cents  integer[] NOT NULL DEFAULT '{1000,2500,5000,10000}'
                   CHECK (cardinality(suggested_cents) <= 8 AND 100 <= ALL (suggested_cents) AND 100000000 >= ALL (suggested_cents)),
  cover_fees       boolean NOT NULL DEFAULT true,
  cover_fees_bps   integer NOT NULL DEFAULT 300 CHECK (cover_fees_bps BETWEEN 0 AND 1000),
  checkout_add_on  boolean NOT NULL DEFAULT false,
  round_up         boolean NOT NULL DEFAULT false,
  tax_receipt_text text CHECK (tax_receipt_text IS NULL OR length(tax_receipt_text) <= 2000),
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, slug),
  CONSTRAINT exos_giving_campaigns_window_chk CHECK (starts_at IS NULL OR ends_at IS NULL OR starts_at < ends_at)
);

CREATE TABLE IF NOT EXISTS public.exos_donations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  campaign_id      uuid NOT NULL REFERENCES public.exos_giving_campaigns (id) ON DELETE RESTRICT,
  amount_cents     integer NOT NULL CHECK (amount_cents > 0 AND amount_cents <= 100000000),
  cover_fees_cents integer NOT NULL DEFAULT 0 CHECK (cover_fees_cents >= 0),
  total_cents      integer NOT NULL,
  currency         text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  method           text NOT NULL CHECK (method IN ('card', 'checkout', 'cash', 'check', 'other')),
  donor_uid        uuid,
  donor_email      text CHECK (donor_email IS NULL OR length(donor_email) <= 320),
  donor_name       text CHECK (donor_name IS NULL OR length(donor_name) <= 120),
  anonymous        boolean NOT NULL DEFAULT false,
  note             text CHECK (note IS NULL OR length(note) <= 1000),
  -- Ticket order (exos_checkout_sessions) or standalone gift (exos_commerce_orders).
  session_id       text,
  event_id         uuid,
  -- Idempotency: 'order:<session>', 'stripe:<session>' or 'ext:<till id>'.
  key              text NOT NULL CHECK (length(key) BETWEEN 1 AND 220),
  status           text NOT NULL DEFAULT 'received' CHECK (status IN ('received', 'refunded')),
  recorded_by      uuid,
  receipt_number   integer,
  receipt_sent_at  timestamptz,
  refunded_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, key),
  CONSTRAINT exos_donations_total_chk CHECK (total_cents = amount_cents + cover_fees_cents)
);
CREATE INDEX IF NOT EXISTS exos_donations_campaign_idx ON public.exos_donations (campaign_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_donations_session_idx ON public.exos_donations (session_id) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_donations_donor_idx ON public.exos_donations (donor_uid) WHERE donor_uid IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_donation_receipt_counters (
  org_id uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  last_number integer NOT NULL DEFAULT 0
);

DROP TRIGGER IF EXISTS exos_giving_campaigns_touch ON public.exos_giving_campaigns;
CREATE TRIGGER exos_giving_campaigns_touch BEFORE UPDATE ON public.exos_giving_campaigns
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_giving_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_donations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_donation_receipt_counters ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.exos_giving_campaigns FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_giving_campaigns TO authenticated;
DROP POLICY IF EXISTS exos_giving_campaigns_sel ON public.exos_giving_campaigns;
CREATE POLICY exos_giving_campaigns_sel ON public.exos_giving_campaigns FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin());
DROP POLICY IF EXISTS exos_giving_campaigns_ins ON public.exos_giving_campaigns;
CREATE POLICY exos_giving_campaigns_ins ON public.exos_giving_campaigns FOR INSERT TO authenticated
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin());
DROP POLICY IF EXISTS exos_giving_campaigns_upd ON public.exos_giving_campaigns;
CREATE POLICY exos_giving_campaigns_upd ON public.exos_giving_campaigns FOR UPDATE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin())
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin());
DROP POLICY IF EXISTS exos_giving_campaigns_del ON public.exos_giving_campaigns;
CREATE POLICY exos_giving_campaigns_del ON public.exos_giving_campaigns FOR DELETE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin());

-- Donations: owner / manager / finance read the org's; a donor reads their own.
-- No client writes.
REVOKE ALL ON public.exos_donations FROM anon, authenticated;
GRANT SELECT ON public.exos_donations TO authenticated;
DROP POLICY IF EXISTS exos_donations_sel ON public.exos_donations;
CREATE POLICY exos_donations_sel ON public.exos_donations FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()
         OR donor_uid = auth.uid());
REVOKE ALL ON public.exos_donation_receipt_counters FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_tg_giving_campaign_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.org_id <> OLD.org_id OR NEW.currency <> OLD.currency) THEN
    IF EXISTS (SELECT 1 FROM public.exos_donations d WHERE d.campaign_id = OLD.id) OR NEW.org_id <> OLD.org_id THEN
      RAISE EXCEPTION 'a campaign''s organization (and, once it has donations, currency) can''t change' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF EXISTS (SELECT 1 FROM public.exos_donations d WHERE d.campaign_id = OLD.id) THEN
      RAISE EXCEPTION 'this campaign has donations: set it inactive instead' USING ERRCODE = '23503';
    END IF;
    RETURN OLD;
  END IF;
  NEW.name := btrim(NEW.name);
  IF TG_OP = 'INSERT' THEN NEW.created_by := coalesce(NEW.created_by, auth.uid()); END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_giving_campaign_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_giving_campaigns_guard ON public.exos_giving_campaigns;
CREATE TRIGGER exos_giving_campaigns_guard BEFORE INSERT OR UPDATE OR DELETE ON public.exos_giving_campaigns
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_giving_campaign_guard();

-- Public campaign page and the add-a-donation choice: active campaigns with the
-- amount raised (computed, never a stored counter that could drift).
CREATE OR REPLACE VIEW public.exos_public_giving_campaigns WITH (security_barrier = true) AS
  SELECT c.id, c.org_id, o.slug AS org_slug, o.name AS org_name, c.name, c.slug, c.description, c.image_url,
         c.currency, c.goal_cents, c.starts_at, c.ends_at, c.suggested_cents, c.cover_fees, c.cover_fees_bps,
         c.checkout_add_on, c.round_up,
         (c.starts_at IS NULL OR c.starts_at <= now()) AND (c.ends_at IS NULL OR c.ends_at > now()) AS open,
         coalesce(d.raised, 0)::bigint AS raised_cents, coalesce(d.n, 0)::int AS donation_count
    FROM public.exos_giving_campaigns c
    JOIN public.exos_orgs o ON o.id = c.org_id
    LEFT JOIN LATERAL (SELECT sum(x.amount_cents) AS raised, count(*) AS n FROM public.exos_donations x
                        WHERE x.campaign_id = c.id AND x.status = 'received') d ON true
   WHERE c.active;
REVOKE ALL ON public.exos_public_giving_campaigns FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_giving_campaigns TO anon, authenticated;

-- Internal: one donation + its receipt mail. Idempotent per (org, key); returns
-- the donation id.
CREATE OR REPLACE FUNCTION public._exos_donation_record(
  p_campaign_id uuid, p_amount_cents integer, p_cover_fees_cents integer, p_method text,
  p_donor_uid uuid, p_donor_email text, p_donor_name text, p_anonymous boolean, p_note text,
  p_session_id text, p_event_id uuid, p_key text, p_recorded_by uuid, p_currency text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_giving_campaigns%ROWTYPE; v_id uuid; v_no int; v_org text; v_email text; v_safe text;
BEGIN
  SELECT * INTO c FROM public.exos_giving_campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign not found' USING ERRCODE = 'P0002'; END IF;
  SELECT id INTO v_id FROM public.exos_donations WHERE org_id = c.org_id AND key = p_key;
  IF FOUND THEN RETURN v_id; END IF;
  IF p_currency IS NOT NULL AND lower(p_currency) <> c.currency THEN
    RAISE EXCEPTION 'this campaign takes %', upper(c.currency) USING ERRCODE = '22023';
  END IF;
  v_email := lower(nullif(btrim(p_donor_email), ''));
  INSERT INTO public.exos_donations (org_id, campaign_id, amount_cents, cover_fees_cents, total_cents, currency, method,
    donor_uid, donor_email, donor_name, anonymous, note, session_id, event_id, key, recorded_by)
  VALUES (c.org_id, c.id, p_amount_cents, coalesce(p_cover_fees_cents, 0), p_amount_cents + coalesce(p_cover_fees_cents, 0),
    c.currency, p_method, p_donor_uid, v_email, nullif(btrim(p_donor_name), ''), coalesce(p_anonymous, false),
    nullif(btrim(p_note), ''), p_session_id, p_event_id, p_key, p_recorded_by)
  ON CONFLICT (org_id, key) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM public.exos_donations WHERE org_id = c.org_id AND key = p_key;
    RETURN v_id;
  END IF;

  IF v_email IS NOT NULL THEN
    INSERT INTO public.exos_donation_receipt_counters (org_id, last_number) VALUES (c.org_id, 1)
    ON CONFLICT (org_id) DO UPDATE SET last_number = public.exos_donation_receipt_counters.last_number + 1
    RETURNING last_number INTO v_no;
    SELECT name INTO v_org FROM public.exos_orgs WHERE id = c.org_id;
    v_safe := replace(replace(replace(coalesce(v_org, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    BEGIN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES ('donation-receipt', v_email, left('Thank you for your gift to ' || coalesce(v_org, 'us'), 200),
        '<p>Thank you for your gift to <strong>' || v_safe || '</strong>.</p>' ||
        '<p>Receipt no. ' || v_no || '<br>Date: ' || to_char(now(), 'YYYY-MM-DD') ||
        '<br>Campaign: ' || replace(replace(replace(c.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') ||
        '<br>Payment: ' || p_method ||
        '<br>Gift: ' || to_char(p_amount_cents / 100.0, 'FM999,999,990.00') || ' ' || upper(c.currency) ||
        CASE WHEN coalesce(p_cover_fees_cents, 0) > 0 THEN '<br>Fees you covered: ' ||
          to_char(p_cover_fees_cents / 100.0, 'FM999,999,990.00') || ' ' || upper(c.currency) ELSE '' END ||
        '<br>Total: ' || to_char((p_amount_cents + coalesce(p_cover_fees_cents, 0)) / 100.0, 'FM999,999,990.00') || ' ' ||
        upper(c.currency) || '</p><p>' ||
        coalesce(replace(replace(replace(c.tax_receipt_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
          '[Legal name of the organization] is a [registered charity / 501(c)(3) nonprofit], tax ID [number]. ' ||
          'No goods or services were provided in exchange for this contribution. (The organization has not ' ||
          'filled in its receipt text yet: don''t rely on this as a tax receipt.)') || '</p>',
        p_donor_uid, 'pending');
      UPDATE public.exos_donations SET receipt_number = v_no, receipt_sent_at = now() WHERE id = v_id;
    EXCEPTION WHEN others THEN RAISE WARNING '_exos_donation_record: receipt not queued: %', SQLERRM;
    END;
  END IF;
  BEGIN
    PERFORM public.exos_enqueue_webhook(c.org_id, 'donation.received', jsonb_build_object(
      'donation_id', v_id, 'campaign_id', c.id, 'amount_cents', p_amount_cents, 'currency', c.currency,
      'method', p_method, 'session_id', p_session_id));
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_donation_record(uuid, integer, integer, text, uuid, text, text, boolean, text, text, uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated;

-- Staff (owner / manager / finance): a cash or check gift. p_external_id makes a
-- retry return the same donation.
CREATE OR REPLACE FUNCTION public.exos_record_offline_donation(p_campaign_id uuid, p_amount_cents integer,
  p_method text, p_donor_name text DEFAULT NULL, p_donor_email text DEFAULT NULL, p_anonymous boolean DEFAULT false,
  p_note text DEFAULT NULL, p_external_id text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_giving_campaigns WHERE id = p_campaign_id;
  IF v_org IS NULL OR NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_method NOT IN ('cash', 'check', 'other') THEN RAISE EXCEPTION 'method must be cash, check or other' USING ERRCODE = '22023'; END IF;
  IF p_amount_cents IS NULL OR p_amount_cents < 1 OR p_amount_cents > 100000000 THEN
    RAISE EXCEPTION 'bad amount' USING ERRCODE = '22023';
  END IF;
  IF p_external_id IS NOT NULL AND p_external_id !~ '^[A-Za-z0-9_:.-]{1,200}$' THEN
    RAISE EXCEPTION 'bad external id' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_donation_record(p_campaign_id, p_amount_cents, 0, p_method, NULL, p_donor_email, p_donor_name,
    p_anonymous, p_note, NULL, NULL, coalesce('ext:' || p_external_id, 'offline:' || gen_random_uuid()::text), auth.uid(), NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_record_offline_donation(uuid, integer, text, text, text, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_offline_donation(uuid, integer, text, text, text, boolean, text, text) TO authenticated, service_role;

-- Internal: a donation came back (order refunded, Stripe refund).
CREATE OR REPLACE FUNCTION public._exos_donation_refund(p_key_or_session text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE public.exos_donations SET status = 'refunded', refunded_at = now()
   WHERE session_id = p_key_or_session AND status = 'received';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public._exos_donation_refund(text) FROM PUBLIC, anon, authenticated;

-- Staff export rows (the client builds the CSV, escaping formula cells).
CREATE OR REPLACE FUNCTION public.exos_donations_export(p_org_id uuid, p_campaign_id uuid DEFAULT NULL)
RETURNS TABLE (created_at timestamptz, campaign text, amount_cents integer, cover_fees_cents integer, total_cents integer,
  currency text, method text, donor_name text, donor_email text, anonymous boolean, session_id text, status text,
  note text, receipt_number integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT d.created_at, c.name, d.amount_cents, d.cover_fees_cents, d.total_cents, d.currency, d.method,
         d.donor_name, d.donor_email, d.anonymous, d.session_id, d.status, d.note, d.receipt_number
    FROM public.exos_donations d JOIN public.exos_giving_campaigns c ON c.id = d.campaign_id
   WHERE d.org_id = p_org_id AND (p_campaign_id IS NULL OR d.campaign_id = p_campaign_id)
   ORDER BY d.created_at DESC LIMIT 50000;
END $$;
REVOKE ALL ON FUNCTION public.exos_donations_export(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_donations_export(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Checkout sessions: gift card part and donation
-- ---------------------------------------------------------------------------
-- amount_cents stays what Stripe charges (the payment ledger, refunds and
-- reconciliation all compare against it). The order's value is
-- amount_cents + gift_card_cents; donation_cents is inside amount_cents (its
-- own Stripe line, after tax, no fees).
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS gift_card_cents integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS donation_cents integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS donation_campaign_id uuid REFERENCES public.exos_giving_campaigns (id) ON DELETE SET NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_commerce_chk') THEN
    ALTER TABLE public.exos_checkout_sessions ADD CONSTRAINT exos_checkout_sessions_commerce_chk CHECK (
      gift_card_cents >= 0 AND donation_cents >= 0 AND donation_cents <= amount_cents + gift_card_cents
      AND (donation_cents = 0) = (donation_campaign_id IS NULL));
  END IF;
END $$;

-- Internal, called by exos_fulfill_checkout inside its all-or-nothing block:
-- capture the gift card hold and record the donation. Raises XF001 to fail the
-- order (the status trigger then gives the gift card part back).
CREATE OR REPLACE FUNCTION public._exos_commerce_on_fulfill(p_session_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.exos_checkout_sessions%ROWTYPE;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF coalesce(s.gift_card_cents, 0) > 0 THEN
    IF NOT public._exos_gift_card_capture(p_session_id, s.gift_card_cents) THEN
      RAISE EXCEPTION 'gift card hold lapsed at fulfillment' USING ERRCODE = 'XF001';
    END IF;
  END IF;
  IF coalesce(s.donation_cents, 0) > 0 AND s.donation_campaign_id IS NOT NULL THEN
    PERFORM public._exos_donation_record(s.donation_campaign_id, s.donation_cents, 0, 'checkout', s.buyer_uid,
      s.buyer_email, NULL, false, NULL, p_session_id, s.event_id, 'order:' || p_session_id, NULL, s.currency);
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_commerce_on_fulfill(text) FROM PUBLIC, anon, authenticated;

-- Fulfillment: hook + ticket price. The ticket's price_paid is the order value
-- (card + gift card) without the donation and the add-ons.
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)', '/* exos: commerce hook */',
  $o$    PERFORM public.exos_consume_holds_for_session(p_session_id);
$o$,
  $n$    PERFORM public.exos_consume_holds_for_session(p_session_id);
    PERFORM public._exos_commerce_on_fulfill(p_session_id); /* exos: commerce hook */
$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)', '/* exos: order value */',
  'round(greatest(s.amount_cents - coalesce((SELECT sum(',
  'round(greatest(s.amount_cents /* exos: order value */ + coalesce(s.gift_card_cents, 0) - coalesce(s.donation_cents, 0) - coalesce((SELECT sum(', 1);

-- Organizer refunds split the card part over the tickets: not the donation.
SELECT pg_temp.exos_patch_n('public.exos_refund_ticket_state(text)', '/* exos: no donation */',
  'greatest(cs.amount_cents - coalesce((',
  'greatest(cs.amount_cents - coalesce(cs.donation_cents, 0) /* exos: no donation */ - coalesce((', 1);

-- Invoice = the order's value (card + gift card), without the donation (a gift,
-- not a sale; it gets its own receipt).
SELECT pg_temp.exos_patch_n('public.exos_tg_invoice()', '/* exos: order value */',
  $o$     AND coalesce(NEW.amount_cents, 0) > 0$o$,
  $n$     AND coalesce(NEW.amount_cents, 0) + coalesce(NEW.gift_card_cents, 0) - coalesce(NEW.donation_cents, 0) > 0 /* exos: order value */$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_tg_invoice()', '/* exos: invoice total */',
  $o$    v_total := NEW.amount_cents;$o$,
  $n$    v_total := NEW.amount_cents + coalesce(NEW.gift_card_cents, 0) - coalesce(NEW.donation_cents, 0); /* exos: invoice total */$n$, 1);

-- The price shown is the whole order; Stripe charged the card part. The gift
-- card part counts as paid, so a correct order isn't flagged as a mismatch.
SELECT pg_temp.exos_patch_n('public.exos_record_price_charged(text, integer, text)', '/* exos: gift card part */',
  $o$     SET charged_cents    = p_amount_cents,$o$,
  $n$     SET charged_cents    = p_amount_cents + coalesce((SELECT cs.gift_card_cents FROM public.exos_checkout_sessions cs
                                                     WHERE cs.session_id = p_session_id), 0) /* exos: gift card part */,$n$, 1);

-- Status changes: failed / expired give a held gift card part back; refunded
-- gives back what wasn't refunded yet and marks the donation refunded.
CREATE OR REPLACE FUNCTION public.exos_tg_checkout_commerce()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NEW.status IN ('failed', 'expired') THEN
    PERFORM public._exos_gift_card_give_back(NEW.session_id, 'order ' || NEW.status);
  ELSIF NEW.status = 'refunded' THEN
    PERFORM public._exos_gift_card_give_back(NEW.session_id, 'order refunded');
    PERFORM public._exos_donation_refund(NEW.session_id);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_checkout_commerce() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_checkout_commerce ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_commerce AFTER UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_checkout_commerce();

-- ---------------------------------------------------------------------------
-- 8. Commerce orders: standalone Stripe purchases (gift cards, donations; passes
--    and memberships in 20261030130500). Written by exos-commerce, fulfilled by
--    stripe-webhook. Not ticket orders, so not exos_checkout_sessions.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_commerce_orders (
  session_id      text PRIMARY KEY CHECK (session_id ~ '^[A-Za-z0-9_-]{1,255}$'),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('gift_card', 'donation', 'pass', 'membership')),
  product_id      uuid,
  buyer_uid       uuid,
  buyer_email     text CHECK (buyer_email IS NULL OR length(buyer_email) <= 320),
  amount_cents    integer NOT NULL CHECK (amount_cents >= 0),
  currency        text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  details         jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(details) = 'object' AND octet_length(details::text) <= 8000),
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'fulfilled', 'failed', 'expired', 'refunded')),
  failure_reason  text,
  payment_intent  text,
  subscription_id text,
  result_id       uuid,
  application_fee_cents integer,
  created_at      timestamptz NOT NULL DEFAULT now(),
  fulfilled_at    timestamptz
);
CREATE INDEX IF NOT EXISTS exos_commerce_orders_org_idx ON public.exos_commerce_orders (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_commerce_orders_pi_idx ON public.exos_commerce_orders (payment_intent) WHERE payment_intent IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_commerce_orders_buyer_idx ON public.exos_commerce_orders (buyer_uid) WHERE buyer_uid IS NOT NULL;
ALTER TABLE public.exos_commerce_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_commerce_orders FROM anon, authenticated;
GRANT SELECT ON public.exos_commerce_orders TO authenticated;
DROP POLICY IF EXISTS exos_commerce_orders_sel ON public.exos_commerce_orders;
CREATE POLICY exos_commerce_orders_sel ON public.exos_commerce_orders FOR SELECT TO authenticated
  USING (buyer_uid = auth.uid() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin());

-- Service role (stripe-webhook): the payment settled. Idempotent (row lock +
-- status gate). Returns 'fulfilled', 'failed' (the webhook refunds) or the
-- stored final status on a replay.
CREATE OR REPLACE FUNCTION public.exos_commerce_fulfill(p_session_id text, p_payment_intent text, p_amount_cents integer,
  p_subscription_id text DEFAULT NULL, p_period_end timestamptz DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_commerce_orders%ROWTYPE; v_res jsonb; v_id uuid; v_fail text;
BEGIN
  IF NOT public._exos_caller_is_service() THEN
    RAISE EXCEPTION 'exos_commerce_fulfill: service role only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO o FROM public.exos_commerce_orders WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'exos_commerce_fulfill: unknown session %', p_session_id USING ERRCODE = 'P0002'; END IF;
  IF o.status <> 'pending' AND o.status <> 'expired' THEN RETURN o.status; END IF;
  IF p_amount_cents IS DISTINCT FROM o.amount_cents THEN
    v_fail := 'charged ' || coalesce(p_amount_cents::text, '?') || ', expected ' || o.amount_cents;
  END IF;

  IF v_fail IS NULL THEN
    BEGIN
      IF o.kind = 'gift_card' THEN
        v_res := public._exos_gift_card_issue(o.org_id, o.product_id, (o.details->>'amount_cents')::int, o.currency,
          'online', 'card', p_session_id, NULL, o.buyer_uid, o.buyer_email,
          o.details->>'recipient_email', o.details->>'recipient_name', o.details->>'message', true);
        v_id := (v_res->>'card_id')::uuid;
      ELSIF o.kind = 'donation' THEN
        v_id := public._exos_donation_record((o.details->>'campaign_id')::uuid, (o.details->>'amount_cents')::int,
          coalesce((o.details->>'cover_fees_cents')::int, 0), 'card', o.buyer_uid, o.buyer_email,
          o.details->>'donor_name', coalesce((o.details->>'anonymous')::boolean, false), o.details->>'note',
          p_session_id, NULL, 'stripe:' || p_session_id, NULL, o.currency);
      ELSE
        v_res := public._exos_commerce_fulfill_ext(o, p_subscription_id, p_period_end);
        v_id := (v_res->>'id')::uuid;
        v_fail := v_res->>'error';
      END IF;
    EXCEPTION WHEN others THEN
      v_fail := SQLERRM;
    END;
  END IF;

  IF v_fail IS NOT NULL THEN
    UPDATE public.exos_commerce_orders SET status = 'failed', failure_reason = left(v_fail, 500),
           payment_intent = coalesce(p_payment_intent, payment_intent)
     WHERE session_id = p_session_id;
    RETURN 'failed';
  END IF;
  UPDATE public.exos_commerce_orders SET status = 'fulfilled', fulfilled_at = now(), result_id = v_id,
         payment_intent = coalesce(p_payment_intent, payment_intent), subscription_id = coalesce(p_subscription_id, subscription_id)
   WHERE session_id = p_session_id;
  RETURN 'fulfilled';
END $$;
REVOKE ALL ON FUNCTION public.exos_commerce_fulfill(text, text, integer, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_commerce_fulfill(text, text, integer, text, timestamptz) TO service_role;

-- Passes and memberships: 20261030130500 defines the real body. Created here
-- only when missing, so replaying this file never overwrites it.
DO $do$ BEGIN
  IF to_regprocedure('public._exos_commerce_fulfill_ext(public.exos_commerce_orders, text, timestamptz)') IS NULL THEN
    EXECUTE $f$CREATE FUNCTION public._exos_commerce_fulfill_ext(o public.exos_commerce_orders, p_subscription_id text, p_period_end timestamptz)
      RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
      AS $b$ SELECT jsonb_build_object('error', 'unsupported order kind ' || o.kind) $b$$f$;
  END IF;
  IF to_regprocedure('public._exos_commerce_refund_ext(public.exos_commerce_orders, text)') IS NULL THEN
    EXECUTE $f$CREATE FUNCTION public._exos_commerce_refund_ext(o public.exos_commerce_orders, p_reason text)
      RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $b$ BEGIN NULL; END $b$$f$;
  END IF;
END $do$;
REVOKE ALL ON FUNCTION public._exos_commerce_fulfill_ext(public.exos_commerce_orders, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_commerce_refund_ext(public.exos_commerce_orders, text) FROM PUBLIC, anon, authenticated;

-- Service role (stripe-webhook): a standalone purchase was refunded in full.
-- Gift card: what's left on it is voided. Donation: marked refunded. Passes and
-- memberships: see 20261030130500.
CREATE OR REPLACE FUNCTION public.exos_commerce_refund(p_session_id text, p_reason text DEFAULT 'refunded')
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_commerce_orders%ROWTYPE;
BEGIN
  IF NOT public._exos_caller_is_service() THEN
    RAISE EXCEPTION 'exos_commerce_refund: service role only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO o FROM public.exos_commerce_orders WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF o.status = 'refunded' THEN RETURN 'refunded'; END IF;
  IF o.status = 'fulfilled' AND o.result_id IS NOT NULL THEN
    IF o.kind = 'gift_card' THEN
      PERFORM public.exos_gift_card_void(o.result_id, left('purchase refunded: ' || coalesce(p_reason, ''), 200));
    ELSIF o.kind = 'donation' THEN
      PERFORM public._exos_donation_refund(p_session_id);
    ELSE
      PERFORM public._exos_commerce_refund_ext(o, p_reason);
    END IF;
  END IF;
  UPDATE public.exos_commerce_orders SET status = 'refunded', failure_reason = left(coalesce(p_reason, 'refunded'), 500)
   WHERE session_id = p_session_id;
  RETURN 'refunded';
END $$;
REVOKE ALL ON FUNCTION public.exos_commerce_refund(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_commerce_refund(text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Service role: every new table (edge functions write through it).
-- ---------------------------------------------------------------------------
GRANT ALL ON public.exos_gift_card_products, public.exos_gift_cards, public.exos_gift_card_ledger,
  public.exos_gift_card_redemptions, public.exos_giving_campaigns, public.exos_donations,
  public.exos_donation_receipt_counters, public.exos_commerce_orders TO service_role;
GRANT SELECT ON public.exos_public_gift_card_products, public.exos_public_giving_campaigns TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.exos_gift_card_ledger_id_seq TO service_role;
