-- ============================================================================
-- Season passes, flex packs and memberships (Opendate parity, round 12).
-- docs/memberships.md.
-- ============================================================================
-- Touches:  N: exos_pass_products, exos_passes, exos_pass_redemptions,
--              exos_membership_products, exos_fan_memberships,
--              exos_membership_household, exos_membership_redemptions,
--              exos_member_presales (tables)
--           N: exos_public_pass_products, exos_public_membership_products (views)
--           A: exos_checkout_sessions.redemption / pass_id / membership_id /
--              member_discount_percent; exos_commerce_orders.stripe_customer_id
--           R: _exos_commerce_on_fulfill (+ pass and member credits, under the
--              row lock, in fulfillment's all-or-nothing block),
--              _exos_commerce_fulfill_ext / _exos_commerce_refund_ext (passes
--              and memberships; stubs in 20261030130000)
--           N: pass / membership functions (see each)
-- Pre-reqs: 20261030130000 (gift cards + giving, commerce orders).
--
-- Credits use the normal fulfillment: a redemption is a $0 order
-- (exos_checkout_sessions, session 'pass_<request>' / 'mbr_<request>') run
-- through exos_fulfill_checkout, so the tier's capacity, the event's capacity,
-- shared quotas and the per-account limit apply exactly as for a paid ticket,
-- and the credit is taken in the same transaction as the tickets (the pass or
-- membership row is locked). A retry with the same request id returns the
-- tickets already issued.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Passes
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_pass_products (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('season', 'flex')),
  name            text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  description     text CHECK (description IS NULL OR length(description) <= 2000),
  image_url       text CHECK (image_url IS NULL OR (length(image_url) <= 1000 AND image_url ~ '^https://')),
  price_cents     integer NOT NULL CHECK (price_cents BETWEEN 50 AND 100000000),
  currency        text NOT NULL DEFAULT 'usd' CHECK (currency ~ '^[a-z]{3}$'),
  -- Flex: admissions in the pack. Season: unused (one per event).
  credits         integer CHECK (credits IS NULL OR credits BETWEEN 1 AND 1000),
  -- Admissions per event (NULL = no per-event limit; a season pass defaults to 1).
  per_event_limit integer CHECK (per_event_limit IS NULL OR per_event_limit BETWEEN 1 AND 50),
  event_ids       uuid[] NOT NULL DEFAULT '{}',
  date_from       timestamptz,
  date_to         timestamptz,
  tier_ids        uuid[] NOT NULL DEFAULT '{}',
  valid_until     timestamptz,
  sales_end       timestamptz,
  max_sold        integer CHECK (max_sold IS NULL OR max_sold >= 0),
  sold            integer NOT NULL DEFAULT 0 CHECK (sold >= 0),
  active          boolean NOT NULL DEFAULT true,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_pass_products_shape_chk CHECK (
    (kind = 'flex' AND credits IS NOT NULL)
    OR (kind = 'season' AND (cardinality(event_ids) > 0 OR date_from IS NOT NULL OR date_to IS NOT NULL))),
  CONSTRAINT exos_pass_products_range_chk CHECK (date_from IS NULL OR date_to IS NULL OR date_from < date_to),
  CONSTRAINT exos_pass_products_sold_chk CHECK (max_sold IS NULL OR sold <= max_sold),
  CONSTRAINT exos_pass_products_events_chk CHECK (cardinality(event_ids) <= 200 AND cardinality(tier_ids) <= 200)
);
CREATE INDEX IF NOT EXISTS exos_pass_products_org_idx ON public.exos_pass_products (org_id);

CREATE TABLE IF NOT EXISTS public.exos_passes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  product_id      uuid REFERENCES public.exos_pass_products (id) ON DELETE SET NULL,
  kind            text NOT NULL CHECK (kind IN ('season', 'flex')),
  name            text NOT NULL,
  holder_uid      uuid,
  holder_email    text,
  -- NULL = no total (a season pass over a date range: one per event).
  credits_total   integer CHECK (credits_total IS NULL OR credits_total >= 0),
  credits_used    integer NOT NULL DEFAULT 0 CHECK (credits_used >= 0),
  per_event_limit integer,
  eligibility     jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(eligibility) = 'object'),
  valid_until     timestamptz,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'voided')),
  session_id      text UNIQUE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_passes_credits_chk CHECK (credits_total IS NULL OR credits_used <= credits_total)
);
CREATE INDEX IF NOT EXISTS exos_passes_holder_idx ON public.exos_passes (holder_uid);
CREATE INDEX IF NOT EXISTS exos_passes_org_idx ON public.exos_passes (org_id, created_at DESC);

-- The credit ledger: one row per redemption (unique per order and per request).
CREATE TABLE IF NOT EXISTS public.exos_pass_redemptions (
  id          bigserial PRIMARY KEY,
  pass_id     uuid NOT NULL REFERENCES public.exos_passes (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL,
  event_id    uuid NOT NULL,
  session_id  text NOT NULL UNIQUE,
  request_id  uuid NOT NULL,
  quantity    integer NOT NULL CHECK (quantity BETWEEN 1 AND 50),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pass_id, request_id)
);
CREATE INDEX IF NOT EXISTS exos_pass_redemptions_event_idx ON public.exos_pass_redemptions (pass_id, event_id);

-- ---------------------------------------------------------------------------
-- 2. Memberships
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_membership_products (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                  uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name                    text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  description             text CHECK (description IS NULL OR length(description) <= 2000),
  image_url               text CHECK (image_url IS NULL OR (length(image_url) <= 1000 AND image_url ~ '^https://')),
  price_cents             integer NOT NULL CHECK (price_cents BETWEEN 50 AND 100000000),
  currency                text NOT NULL DEFAULT 'usd' CHECK (currency ~ '^[a-z]{3}$'),
  billing                 text NOT NULL CHECK (billing IN ('month', 'year', 'once')),
  duration_days           integer NOT NULL DEFAULT 365 CHECK (duration_days BETWEEN 1 AND 3660),
  discount_percent        numeric(6, 3) NOT NULL DEFAULT 0 CHECK (discount_percent BETWEEN 0 AND 100),
  presale                 boolean NOT NULL DEFAULT false,
  free_tickets_per_period integer NOT NULL DEFAULT 0 CHECK (free_tickets_per_period BETWEEN 0 AND 100),
  guest_allowance         integer NOT NULL DEFAULT 0 CHECK (guest_allowance BETWEEN 0 AND 20),
  household_seats         integer NOT NULL DEFAULT 0 CHECK (household_seats BETWEEN 0 AND 20),
  giftable                boolean NOT NULL DEFAULT true,
  active                  boolean NOT NULL DEFAULT true,
  archived_at             timestamptz,
  created_by              uuid,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_membership_products_org_idx ON public.exos_membership_products (org_id);

CREATE TABLE IF NOT EXISTS public.exos_fan_memberships (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  product_id             uuid REFERENCES public.exos_membership_products (id) ON DELETE SET NULL,
  product_name           text NOT NULL,
  billing                text NOT NULL CHECK (billing IN ('month', 'year', 'once')),
  holder_uid             uuid,
  holder_email           text,
  status                 text NOT NULL CHECK (status IN ('pending', 'active', 'past_due', 'cancelled', 'expired')),
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  cancel_at_period_end   boolean NOT NULL DEFAULT false,
  stripe_subscription_id text UNIQUE CHECK (stripe_subscription_id IS NULL OR stripe_subscription_id ~ '^sub_[A-Za-z0-9]{1,250}$'),
  stripe_customer_id     text CHECK (stripe_customer_id IS NULL OR stripe_customer_id ~ '^cus_[A-Za-z0-9]{1,250}$'),
  -- What it was bought with; editing the product never changes a member.
  benefits               jsonb NOT NULL CHECK (jsonb_typeof(benefits) = 'object'),
  source                 text NOT NULL CHECK (source IN ('purchase', 'gift', 'comp')),
  session_id             text UNIQUE,
  gift                   jsonb CHECK (gift IS NULL OR jsonb_typeof(gift) = 'object'),
  gift_token_hash        text UNIQUE CHECK (gift_token_hash IS NULL OR gift_token_hash ~ '^[0-9a-f]{64}$'),
  -- Why it ended for good: 'refunded' (the purchase was refunded) or
  -- 'gift_cancelled'. Terminal: no later Stripe event brings it back.
  ended_reason           text CHECK (ended_reason IS NULL OR ended_reason IN ('refunded', 'gift_cancelled')),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_fan_memberships ADD COLUMN IF NOT EXISTS ended_reason text
  CHECK (ended_reason IS NULL OR ended_reason IN ('refunded', 'gift_cancelled'));
CREATE INDEX IF NOT EXISTS exos_fan_memberships_holder_idx ON public.exos_fan_memberships (holder_uid);
CREATE INDEX IF NOT EXISTS exos_fan_memberships_org_idx ON public.exos_fan_memberships (org_id, status);

CREATE TABLE IF NOT EXISTS public.exos_membership_household (
  membership_id uuid NOT NULL REFERENCES public.exos_fan_memberships (id) ON DELETE CASCADE,
  email         text NOT NULL CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND email = lower(email)),
  added_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (membership_id, email)
);
CREATE INDEX IF NOT EXISTS exos_membership_household_email_idx ON public.exos_membership_household (email);

-- Free-ticket credits, keyed by the period they belong to.
CREATE TABLE IF NOT EXISTS public.exos_membership_redemptions (
  id            bigserial PRIMARY KEY,
  membership_id uuid NOT NULL REFERENCES public.exos_fan_memberships (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL,
  event_id      uuid NOT NULL,
  period_end    timestamptz,
  session_id    text NOT NULL UNIQUE,
  request_id    uuid NOT NULL,
  quantity      integer NOT NULL CHECK (quantity BETWEEN 1 AND 21),
  redeemed_by   uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (membership_id, request_id)
);

-- Member presale: from starts_at (or now) until ends_at, the covered tiers (all
-- when tier_ids is empty) sell only to members of the listed products (any of
-- the org's when empty) whose product has presale on.
CREATE TABLE IF NOT EXISTS public.exos_member_presales (
  event_id    uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL,
  starts_at   timestamptz,
  ends_at     timestamptz NOT NULL,
  tier_ids    uuid[] NOT NULL DEFAULT '{}',
  product_ids uuid[] NOT NULL DEFAULT '{}',
  updated_by  uuid,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_member_presales_window_chk CHECK (starts_at IS NULL OR starts_at < ends_at)
);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_pass_products', 'exos_passes', 'exos_membership_products', 'exos_fan_memberships'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at()', t || '_touch', t);
  END LOOP;
END $$;

-- Sessions: what a $0 credit order redeems, and the member price on a paid one.
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS redemption text,
  ADD COLUMN IF NOT EXISTS pass_id uuid,
  ADD COLUMN IF NOT EXISTS membership_id uuid,
  ADD COLUMN IF NOT EXISTS member_discount_percent numeric(6, 3);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_redemption_chk') THEN
    ALTER TABLE public.exos_checkout_sessions ADD CONSTRAINT exos_checkout_sessions_redemption_chk CHECK (
      (redemption IS NULL OR redemption IN ('pass', 'member_free'))
      AND (redemption IS DISTINCT FROM 'pass' OR (pass_id IS NOT NULL AND amount_cents = 0))
      AND (redemption IS DISTINCT FROM 'member_free' OR (membership_id IS NOT NULL AND amount_cents = 0))
      AND (member_discount_percent IS NULL OR member_discount_percent BETWEEN 0 AND 100));
  END IF;
END $$;
ALTER TABLE public.exos_commerce_orders ADD COLUMN IF NOT EXISTS stripe_customer_id text
  CHECK (stripe_customer_id IS NULL OR stripe_customer_id ~ '^cus_[A-Za-z0-9]{1,250}$');

-- ---------------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_pass_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_passes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pass_redemptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_membership_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_fan_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_membership_household ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_membership_redemptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_member_presales ENABLE ROW LEVEL SECURITY;

-- Products: owner / manager write (sold is server-kept), finance reads.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_pass_products', 'exos_membership_products'] LOOP
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_sel', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']) OR public.exos_is_admin())', t || '_sel', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_ins', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'']) OR public.exos_is_admin())', t || '_ins', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_upd', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'']) OR public.exos_is_admin()) WITH CHECK (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'']) OR public.exos_is_admin())', t || '_upd', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_del', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'']) OR public.exos_is_admin())', t || '_del', t);
  END LOOP;
END $$;

-- Passes and memberships: the holder and org staff read; no client writes.
REVOKE ALL ON public.exos_passes, public.exos_fan_memberships FROM anon, authenticated;
GRANT SELECT ON public.exos_passes, public.exos_fan_memberships TO authenticated;
DROP POLICY IF EXISTS exos_passes_sel ON public.exos_passes;
CREATE POLICY exos_passes_sel ON public.exos_passes FOR SELECT TO authenticated
  USING (holder_uid = auth.uid() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin());
DROP POLICY IF EXISTS exos_fan_memberships_sel ON public.exos_fan_memberships;
CREATE POLICY exos_fan_memberships_sel ON public.exos_fan_memberships FOR SELECT TO authenticated
  USING (holder_uid = auth.uid() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin());
-- The gift token hash is nobody's business but the claim function's: clients
-- get every other column (a table-wide grant would include it).
DO $$
DECLARE v_cols text;
BEGIN
  REVOKE SELECT ON public.exos_fan_memberships FROM authenticated;
  SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO v_cols FROM pg_attribute
   WHERE attrelid = 'public.exos_fan_memberships'::regclass AND attnum > 0 AND NOT attisdropped AND attname <> 'gift_token_hash';
  EXECUTE format('GRANT SELECT (%s) ON public.exos_fan_memberships TO authenticated', v_cols);
END $$;

REVOKE ALL ON public.exos_pass_redemptions, public.exos_membership_household, public.exos_membership_redemptions,
  public.exos_member_presales FROM anon, authenticated;
GRANT SELECT ON public.exos_membership_household, public.exos_member_presales TO authenticated;
DROP POLICY IF EXISTS exos_membership_household_sel ON public.exos_membership_household;
CREATE POLICY exos_membership_household_sel ON public.exos_membership_household FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_fan_memberships m WHERE m.id = membership_id
                  AND (m.holder_uid = auth.uid() OR public.exos_has_org_role(m.org_id, ARRAY['owner', 'manager', 'finance']))));
DROP POLICY IF EXISTS exos_member_presales_sel ON public.exos_member_presales;
CREATE POLICY exos_member_presales_sel ON public.exos_member_presales FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin());

GRANT ALL ON public.exos_pass_products, public.exos_passes, public.exos_pass_redemptions, public.exos_membership_products,
  public.exos_fan_memberships, public.exos_membership_household, public.exos_membership_redemptions,
  public.exos_member_presales TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.exos_pass_redemptions_id_seq, public.exos_membership_redemptions_id_seq TO service_role;
REVOKE ALL ON SEQUENCE public.exos_pass_redemptions_id_seq, public.exos_membership_redemptions_id_seq FROM anon, authenticated;

-- Product guard: org / currency fixed, sold is the server's, billing fixed.
CREATE OR REPLACE FUNCTION public._exos_tg_commerce_product_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_new jsonb := to_jsonb(NEW); v_old jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF (TG_TABLE_NAME = 'exos_pass_products' AND EXISTS (SELECT 1 FROM public.exos_passes p WHERE p.product_id = OLD.id))
       OR (TG_TABLE_NAME = 'exos_membership_products' AND EXISTS (SELECT 1 FROM public.exos_fan_memberships m WHERE m.product_id = OLD.id)) THEN
      RAISE EXCEPTION 'this product has been sold: archive it instead' USING ERRCODE = '23503';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD);
    IF v_new->'org_id' <> v_old->'org_id' OR v_new->'currency' <> v_old->'currency' THEN
      RAISE EXCEPTION 'a product''s organization and currency can''t change' USING ERRCODE = '22023';
    END IF;
    IF TG_TABLE_NAME = 'exos_membership_products' AND v_new->'billing' <> v_old->'billing' THEN
      RAISE EXCEPTION 'billing can''t change once set' USING ERRCODE = '22023';
    END IF;
    IF TG_TABLE_NAME = 'exos_pass_products' AND v_new->'sold' <> v_old->'sold' AND NOT public._exos_caller_is_service() THEN
      RAISE EXCEPTION 'sold is kept by the server' USING ERRCODE = '42501';
    END IF;
  ELSIF TG_TABLE_NAME = 'exos_pass_products' AND (v_new->>'sold')::int <> 0 AND NOT public._exos_caller_is_service() THEN
    RAISE EXCEPTION 'sold is kept by the server' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_commerce_product_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pass_products_guard ON public.exos_pass_products;
CREATE TRIGGER exos_pass_products_guard BEFORE INSERT OR UPDATE OR DELETE ON public.exos_pass_products
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_commerce_product_guard();
DROP TRIGGER IF EXISTS exos_membership_products_guard ON public.exos_membership_products;
CREATE TRIGGER exos_membership_products_guard BEFORE INSERT OR UPDATE OR DELETE ON public.exos_membership_products
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_commerce_product_guard();

-- Public product lists (/shop/:orgSlug).
CREATE OR REPLACE VIEW public.exos_public_pass_products WITH (security_barrier = true) AS
  SELECT p.id, p.org_id, o.slug AS org_slug, o.name AS org_name, p.kind, p.name, p.description, p.image_url,
         p.price_cents, p.currency, p.credits, p.per_event_limit, p.event_ids, p.date_from, p.date_to, p.valid_until,
         p.sales_end, (p.max_sold IS NOT NULL AND p.sold >= p.max_sold) AS sold_out
    FROM public.exos_pass_products p JOIN public.exos_orgs o ON o.id = p.org_id
   WHERE p.active AND (p.sales_end IS NULL OR p.sales_end > now());
CREATE OR REPLACE VIEW public.exos_public_membership_products WITH (security_barrier = true) AS
  SELECT p.id, p.org_id, o.slug AS org_slug, o.name AS org_name, p.name, p.description, p.image_url, p.price_cents,
         p.currency, p.billing, p.duration_days, p.discount_percent, p.presale, p.free_tickets_per_period,
         p.guest_allowance, p.household_seats, p.giftable
    FROM public.exos_membership_products p JOIN public.exos_orgs o ON o.id = p.org_id
   WHERE p.active AND p.archived_at IS NULL;
REVOKE ALL ON public.exos_public_pass_products, public.exos_public_membership_products FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_pass_products, public.exos_public_membership_products TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Membership helpers
-- ---------------------------------------------------------------------------
-- Status as of now: an active membership past its period end has expired
-- (one-time terms end this way); past_due keeps benefits for 3 days.
CREATE OR REPLACE FUNCTION public.exos_membership_effective_status(p_status text, p_period_end timestamptz)
RETURNS text LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN p_status = 'active' AND p_period_end IS NOT NULL AND p_period_end < now() THEN 'expired'
    WHEN p_status = 'past_due' AND p_period_end IS NOT NULL AND p_period_end + interval '3 days' < now() THEN 'expired'
    WHEN p_status = 'cancelled' AND p_period_end IS NOT NULL AND p_period_end > now() THEN 'cancelled'
    ELSE p_status END;
$$;
REVOKE ALL ON FUNCTION public.exos_membership_effective_status(text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_membership_effective_status(text, timestamptz) TO authenticated, service_role;

-- Benefits apply while active, past due (grace) or cancelled-but-paid-up.
CREATE OR REPLACE FUNCTION public._exos_membership_benefits_live(m public.exos_fan_memberships)
RETURNS boolean LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT m.status IN ('active', 'past_due', 'cancelled')
     AND public.exos_membership_effective_status(m.status, m.current_period_end) IN ('active', 'past_due', 'cancelled')
     AND (m.status <> 'cancelled' OR (m.current_period_end IS NOT NULL AND m.current_period_end > now()));
$$;
REVOKE ALL ON FUNCTION public._exos_membership_benefits_live(public.exos_fan_memberships) FROM PUBLIC, anon, authenticated;

-- Does this account (as holder, or by confirmed email in a household) have
-- live benefits in this membership?
CREATE OR REPLACE FUNCTION public._exos_membership_uses(m public.exos_fan_memberships, p_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p_uid IS NOT NULL AND public._exos_membership_benefits_live(m) AND (
    m.holder_uid = p_uid OR EXISTS (
      SELECT 1 FROM public.exos_membership_household h JOIN auth.users u ON u.id = p_uid
       WHERE h.membership_id = m.id AND u.email_confirmed_at IS NOT NULL AND h.email = lower(u.email)));
$$;
REVOKE ALL ON FUNCTION public._exos_membership_uses(public.exos_fan_memberships, uuid) FROM PUBLIC, anon, authenticated;

-- The best membership of an org for an account: highest discount first.
CREATE OR REPLACE FUNCTION public._exos_member_best(p_org_id uuid, p_uid uuid, p_product_ids uuid[] DEFAULT NULL, p_need_presale boolean DEFAULT false)
RETURNS public.exos_fan_memberships LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m.* FROM public.exos_fan_memberships m
   WHERE m.org_id = p_org_id AND public._exos_membership_uses(m, p_uid)
     AND (p_product_ids IS NULL OR cardinality(p_product_ids) = 0 OR m.product_id = ANY (p_product_ids))
     AND (NOT p_need_presale OR coalesce((m.benefits->>'presale')::boolean, false))
   ORDER BY coalesce((m.benefits->>'discount_percent')::numeric, 0) DESC, m.created_at
   LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public._exos_member_best(uuid, uuid, uuid[], boolean) FROM PUBLIC, anon, authenticated;

-- Is the tier in a member presale right now, and may this account buy it?
CREATE OR REPLACE FUNCTION public._exos_presale_blocks(p_event_id uuid, p_tier_id uuid, p_uid uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE ps public.exos_member_presales%ROWTYPE; m public.exos_fan_memberships%ROWTYPE;
BEGIN
  SELECT * INTO ps FROM public.exos_member_presales WHERE event_id = p_event_id;
  IF NOT FOUND OR now() >= ps.ends_at OR (ps.starts_at IS NOT NULL AND now() < ps.starts_at) THEN RETURN false; END IF;
  IF cardinality(ps.tier_ids) > 0 AND NOT p_tier_id = ANY (ps.tier_ids) THEN RETURN false; END IF;
  m := public._exos_member_best(ps.org_id, p_uid, ps.product_ids, true);
  RETURN m.id IS NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_presale_blocks(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Service role (exos-checkout): presale gate + member price for a paid order.
CREATE OR REPLACE FUNCTION public.exos_member_checkout(p_event_id uuid, p_tier_id uuid, p_buyer uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid; m public.exos_fan_memberships%ROWTYPE;
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF public._exos_presale_blocks(p_event_id, p_tier_id, p_buyer) THEN
    RETURN jsonb_build_object('presale_blocked', true);
  END IF;
  m := public._exos_member_best(v_org, p_buyer);
  IF m.id IS NULL OR coalesce((m.benefits->>'discount_percent')::numeric, 0) <= 0 THEN
    RETURN jsonb_build_object('presale_blocked', false, 'membership_id', m.id);
  END IF;
  RETURN jsonb_build_object('presale_blocked', false, 'membership_id', m.id,
    'discount_percent', (m.benefits->>'discount_percent')::numeric,
    'guest_allowance', coalesce((m.benefits->>'guest_allowance')::int, 0), 'product_name', m.product_name);
END $$;
REVOKE ALL ON FUNCTION public.exos_member_checkout(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_member_checkout(uuid, uuid, uuid) TO service_role;

-- Self: my member benefit at an org (the event page shows the member price).
CREATE OR REPLACE FUNCTION public.exos_my_member_benefit(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_fan_memberships%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  m := public._exos_member_best(p_org_id, auth.uid());
  IF m.id IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('membership_id', m.id, 'product_name', m.product_name,
    'discount_percent', coalesce((m.benefits->>'discount_percent')::numeric, 0),
    'guest_allowance', coalesce((m.benefits->>'guest_allowance')::int, 0),
    'presale', coalesce((m.benefits->>'presale')::boolean, false));
END $$;
REVOKE ALL ON FUNCTION public.exos_my_member_benefit(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_my_member_benefit(uuid) TO authenticated;

-- Owner / manager: set or clear an event's member presale.
CREATE OR REPLACE FUNCTION public.exos_set_member_presale(p_event_id uuid, p_starts_at timestamptz, p_ends_at timestamptz,
  p_tier_ids uuid[] DEFAULT '{}', p_product_ids uuid[] DEFAULT '{}')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_ends_at IS NULL THEN
    DELETE FROM public.exos_member_presales WHERE event_id = p_event_id;
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(coalesce(p_tier_ids, '{}')) t
              WHERE NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers x WHERE x.id = t AND x.event_id = p_event_id))
     OR EXISTS (SELECT 1 FROM unnest(coalesce(p_product_ids, '{}')) pr
              WHERE NOT EXISTS (SELECT 1 FROM public.exos_membership_products x WHERE x.id = pr AND x.org_id = v_org)) THEN
    RAISE EXCEPTION 'tiers must be this event''s and products this organization''s' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_member_presales (event_id, org_id, starts_at, ends_at, tier_ids, product_ids, updated_by)
  VALUES (p_event_id, v_org, p_starts_at, p_ends_at, coalesce(p_tier_ids, '{}'), coalesce(p_product_ids, '{}'), auth.uid())
  ON CONFLICT (event_id) DO UPDATE SET starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at,
    tier_ids = EXCLUDED.tier_ids, product_ids = EXCLUDED.product_ids, updated_by = EXCLUDED.updated_by, updated_at = now();
END $$;
REVOKE ALL ON FUNCTION public.exos_set_member_presale(uuid, timestamptz, timestamptz, uuid[], uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_set_member_presale(uuid, timestamptz, timestamptz, uuid[], uuid[]) TO authenticated, service_role;

-- Public: is there a member presale on this event now (the event page says so)?
CREATE OR REPLACE VIEW public.exos_public_member_presales WITH (security_barrier = true) AS
  SELECT ps.event_id, ps.starts_at, ps.ends_at, ps.tier_ids
    FROM public.exos_member_presales ps JOIN public.exos_events e ON e.id = ps.event_id
   WHERE e.status = 'published' AND ps.ends_at > now();
REVOKE ALL ON public.exos_public_member_presales FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_member_presales TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Fulfillment hook: gift cards + donations (as before) + credits
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_commerce_on_fulfill(p_session_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.exos_checkout_sessions%ROWTYPE; p public.exos_passes%ROWTYPE; m public.exos_fan_memberships%ROWTYPE;
        v_ev public.exos_events%ROWTYPE; v_used int; v_req uuid;
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

  -- Member presale (any order that isn't a credit redemption, which checked it
  -- already): a buyer who isn't an eligible member fails the order (refunded).
  IF s.redemption IS NULL AND public._exos_presale_blocks(s.event_id, s.tier_id, s.buyer_uid) THEN
    RAISE EXCEPTION 'tickets are on presale for members right now' USING ERRCODE = 'XF001';
  END IF;

  -- Credits: the row is locked here, inside fulfillment's all-or-nothing block,
  -- so two redemptions racing for the last credit can't both pass.
  IF s.redemption IS NOT NULL THEN
    v_req := nullif(s.attribution->>'request_id', '')::uuid;
    SELECT * INTO v_ev FROM public.exos_events WHERE id = s.event_id;
  END IF;
  IF s.redemption = 'pass' THEN
    SELECT * INTO p FROM public.exos_passes WHERE id = s.pass_id FOR UPDATE;
    IF NOT FOUND OR p.status <> 'active' OR p.org_id <> s.org_id OR p.holder_uid IS DISTINCT FROM s.buyer_uid
       OR (p.valid_until IS NOT NULL AND p.valid_until < now()) THEN
      RAISE EXCEPTION 'pass not usable' USING ERRCODE = 'XF001';
    END IF;
    IF p.credits_total IS NOT NULL AND p.credits_used + s.quantity > p.credits_total THEN
      RAISE EXCEPTION 'not enough admissions left on the pass' USING ERRCODE = 'XF001';
    END IF;
    SELECT coalesce(sum(quantity), 0) INTO v_used FROM public.exos_pass_redemptions WHERE pass_id = p.id AND event_id = s.event_id;
    IF p.per_event_limit IS NOT NULL AND v_used + s.quantity > p.per_event_limit THEN
      RAISE EXCEPTION 'the pass''s limit for this event is reached' USING ERRCODE = 'XF001';
    END IF;
    UPDATE public.exos_passes SET credits_used = credits_used + s.quantity WHERE id = p.id;
    INSERT INTO public.exos_pass_redemptions (pass_id, org_id, event_id, session_id, request_id, quantity)
    VALUES (p.id, p.org_id, s.event_id, p_session_id, coalesce(v_req, gen_random_uuid()), s.quantity);
  ELSIF s.redemption = 'member_free' THEN
    SELECT * INTO m FROM public.exos_fan_memberships WHERE id = s.membership_id FOR UPDATE;
    IF NOT FOUND OR m.org_id <> s.org_id OR NOT public._exos_membership_uses(m, s.buyer_uid) THEN
      RAISE EXCEPTION 'membership not usable' USING ERRCODE = 'XF001';
    END IF;
    IF s.quantity > 1 + coalesce((m.benefits->>'guest_allowance')::int, 0) THEN
      RAISE EXCEPTION 'more tickets than the membership covers' USING ERRCODE = 'XF001';
    END IF;
    SELECT count(*) INTO v_used FROM public.exos_membership_redemptions
     WHERE membership_id = m.id AND period_end IS NOT DISTINCT FROM m.current_period_end;
    IF v_used + 1 > coalesce((m.benefits->>'free_tickets_per_period')::int, 0) THEN
      RAISE EXCEPTION 'no free tickets left this period' USING ERRCODE = 'XF001';
    END IF;
    INSERT INTO public.exos_membership_redemptions (membership_id, org_id, event_id, period_end, session_id, request_id, quantity, redeemed_by)
    VALUES (m.id, m.org_id, s.event_id, m.current_period_end, p_session_id, coalesce(v_req, gen_random_uuid()), s.quantity, s.buyer_uid);
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_commerce_on_fulfill(text) FROM PUBLIC, anon, authenticated;

-- Internal: run a $0 credit order through the normal fulfillment. Idempotent
-- per session id (derived from the request id).
CREATE OR REPLACE FUNCTION public._exos_credit_order(p_kind text, p_ref uuid, p_org_id uuid, p_event_id uuid, p_tier_id uuid,
  p_quantity int, p_request_id uuid, p_uid uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_sid text := CASE WHEN p_kind = 'pass' THEN 'pass_' ELSE 'mbr_' END || replace(p_request_id::text, '-', '');
        s public.exos_checkout_sessions%ROWTYPE; t public.exos_ticket_tiers%ROWTYPE; e public.exos_events%ROWTYPE;
        v_ids uuid[]; v_email text;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = v_sid;
  IF FOUND THEN
    IF s.buyer_uid IS DISTINCT FROM p_uid THEN RAISE EXCEPTION 'request id already used' USING ERRCODE = '22023'; END IF;
    IF s.status = 'fulfilled' THEN
      RETURN jsonb_build_object('session_id', v_sid, 'ticket_ids', to_jsonb(s.ticket_ids), 'fresh', false);
    END IF;
    RAISE EXCEPTION '%', coalesce(s.failure_reason, 'that redemption did not go through') USING ERRCODE = 'P0001';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 10 THEN RAISE EXCEPTION 'quantity must be 1-10' USING ERRCODE = '22023'; END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND OR e.org_id <> p_org_id THEN RAISE EXCEPTION 'this event isn''t covered' USING ERRCODE = 'P0001'; END IF;
  IF e.status <> 'published' THEN RAISE EXCEPTION 'event not on sale' USING ERRCODE = 'P0001'; END IF;
  IF coalesce(e.ticket_backend, 'exos') <> 'exos' THEN RAISE EXCEPTION 'tickets for this event are sold on another site' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO t FROM public.exos_ticket_tiers WHERE id = p_tier_id AND event_id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ticket type not found' USING ERRCODE = 'P0002'; END IF;
  IF coalesce(t.visibility, 'public') <> 'public' THEN RAISE EXCEPTION 'ticket type not available' USING ERRCODE = 'P0001'; END IF;
  IF (t.sales_end IS NOT NULL AND t.sales_end < now()) OR (t.sales_start IS NOT NULL AND t.sales_start > now()) THEN
    RAISE EXCEPTION 'this ticket type isn''t on sale now' USING ERRCODE = 'P0001';
  END IF;
  IF public._exos_presale_blocks(p_event_id, p_tier_id, p_uid) THEN
    RAISE EXCEPTION 'Tickets are on presale for members right now.' USING ERRCODE = 'P0001';
  END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = p_uid;

  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity,
    amount_cents, currency, status, redemption, pass_id, membership_id, attribution)
  VALUES (v_sid, p_event_id, p_tier_id, p_org_id, p_uid, v_email, p_quantity, 0, coalesce(e.currency, 'usd'), 'pending',
    p_kind, CASE WHEN p_kind = 'pass' THEN p_ref END, CASE WHEN p_kind = 'member_free' THEN p_ref END,
    jsonb_build_object('request_id', p_request_id::text, 'utm_source', p_kind));
  v_ids := public.exos_fulfill_checkout(v_sid);
  IF coalesce(cardinality(v_ids), 0) = 0 THEN
    SELECT failure_reason INTO s.failure_reason FROM public.exos_checkout_sessions WHERE session_id = v_sid;
    RETURN jsonb_build_object('session_id', v_sid, 'error', coalesce(s.failure_reason, 'not available'));
  END IF;
  RETURN jsonb_build_object('session_id', v_sid, 'ticket_ids', to_jsonb(v_ids), 'fresh', true);
END $$;
REVOKE ALL ON FUNCTION public._exos_credit_order(text, uuid, uuid, uuid, uuid, int, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Holder: use a pass for tickets. Same request id = the same tickets.
CREATE OR REPLACE FUNCTION public.exos_pass_redeem(p_pass_id uuid, p_event_id uuid, p_tier_id uuid, p_quantity integer, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_passes%ROWTYPE; e public.exos_events%ROWTYPE; v_named uuid[]; v_tiers uuid[];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'request id required' USING ERRCODE = '22023'; END IF;
  SELECT * INTO p FROM public.exos_passes WHERE id = p_pass_id;
  IF NOT FOUND OR p.holder_uid IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'pass not found' USING ERRCODE = 'P0002'; END IF;
  IF p.status <> 'active' THEN RAISE EXCEPTION 'this pass was voided' USING ERRCODE = 'P0001'; END IF;
  IF p.valid_until IS NOT NULL AND p.valid_until < now() THEN RAISE EXCEPTION 'this pass has expired' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND OR e.org_id <> p.org_id THEN RAISE EXCEPTION 'this event isn''t covered by the pass' USING ERRCODE = 'P0001'; END IF;
  SELECT coalesce(array_agg(x::uuid), '{}') INTO v_named FROM jsonb_array_elements_text(coalesce(p.eligibility->'event_ids', '[]')) x;
  SELECT coalesce(array_agg(x::uuid), '{}') INTO v_tiers FROM jsonb_array_elements_text(coalesce(p.eligibility->'tier_ids', '[]')) x;
  IF cardinality(v_named) > 0 THEN
    IF NOT p_event_id = ANY (v_named) THEN RAISE EXCEPTION 'this event isn''t covered by the pass' USING ERRCODE = 'P0001'; END IF;
  ELSIF e.starts_at IS NULL
     OR (p.eligibility->>'date_from' IS NOT NULL AND e.starts_at < (p.eligibility->>'date_from')::timestamptz)
     OR (p.eligibility->>'date_to' IS NOT NULL AND e.starts_at >= (p.eligibility->>'date_to')::timestamptz) THEN
    RAISE EXCEPTION 'this event isn''t covered by the pass' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(v_tiers) > 0 AND NOT p_tier_id = ANY (v_tiers) THEN
    RAISE EXCEPTION 'this ticket type isn''t covered by the pass' USING ERRCODE = 'P0001';
  END IF;
  RETURN public._exos_credit_order('pass', p.id, p.org_id, p_event_id, p_tier_id, p_quantity, p_request_id, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_pass_redeem(uuid, uuid, uuid, integer, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_pass_redeem(uuid, uuid, uuid, integer, uuid) TO authenticated;

-- Member (holder or household): use a free ticket of this period.
CREATE OR REPLACE FUNCTION public.exos_membership_redeem(p_membership_id uuid, p_event_id uuid, p_tier_id uuid, p_quantity integer, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_fan_memberships%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'request id required' USING ERRCODE = '22023'; END IF;
  SELECT * INTO m FROM public.exos_fan_memberships WHERE id = p_membership_id;
  IF NOT FOUND OR NOT public._exos_membership_uses(m, auth.uid()) THEN RAISE EXCEPTION 'membership not found' USING ERRCODE = 'P0002'; END IF;
  IF coalesce((m.benefits->>'free_tickets_per_period')::int, 0) <= 0 THEN
    RAISE EXCEPTION 'this membership has no free tickets' USING ERRCODE = 'P0001';
  END IF;
  RETURN public._exos_credit_order('member_free', m.id, m.org_id, p_event_id, p_tier_id, p_quantity, p_request_id, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_redeem(uuid, uuid, uuid, integer, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_redeem(uuid, uuid, uuid, integer, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Purchases (exos_commerce_fulfill) and refunds of passes / memberships
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_membership_new_gift_token()
RETURNS text LANGUAGE sql VOLATILE SET search_path = public, pg_temp AS $$
  SELECT encode(extensions.gen_random_bytes(32), 'hex');
$$;
REVOKE ALL ON FUNCTION public._exos_membership_new_gift_token() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_membership_gift_mail(p_to text, p_org text, p_product text, p_from text, p_message text, p_token text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE esc text;
BEGIN
  BEGIN
    INSERT INTO public.exos_mail (template, to_email, subject, html, status)
    VALUES ('membership-gift', p_to, left('You''ve been given a ' || coalesce(p_org, '') || ' membership', 200),
      '<p>' || coalesce(replace(replace(replace(p_from, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), 'Someone') ||
      ' gave you a <strong>' || replace(replace(replace(coalesce(p_product, 'membership'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') ||
      '</strong> membership at ' || replace(replace(replace(coalesce(p_org, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '.</p>' ||
      coalesce('<p>' || replace(replace(replace(p_message, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</p>', '') ||
      '<p><a href="{{app_url}}/membership/claim?token=' || p_token || '">Claim your membership</a> (the link works for 90 days; ' ||
      'the membership starts the day you claim it).</p>', 'pending');
  EXCEPTION WHEN others THEN RAISE WARNING 'gift mail not queued: %', SQLERRM;
  END;
END $$;
REVOKE ALL ON FUNCTION public._exos_membership_gift_mail(text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;

-- Internal: a membership from a product. Gifts are pending with a claim token.
CREATE OR REPLACE FUNCTION public._exos_membership_create(p_product_id uuid, p_holder_uid uuid, p_holder_email text,
  p_source text, p_session_id text, p_subscription_id text, p_customer_id text, p_period_end timestamptz,
  p_gift_to text, p_gift_from text, p_gift_message text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE pr public.exos_membership_products%ROWTYPE; v_id uuid; v_start timestamptz := now(); v_end timestamptz;
        v_token text; v_org text;
BEGIN
  SELECT * INTO pr FROM public.exos_membership_products WHERE id = p_product_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'membership product not found' USING ERRCODE = 'P0002'; END IF;
  IF p_session_id IS NOT NULL THEN
    SELECT id INTO v_id FROM public.exos_fan_memberships WHERE session_id = p_session_id;
    IF FOUND THEN RETURN v_id; END IF;
  END IF;
  IF p_gift_to IS NULL THEN
    IF p_subscription_id IS NOT NULL THEN
      v_end := coalesce(p_period_end, now() + CASE pr.billing WHEN 'month' THEN interval '1 month' ELSE interval '1 year' END);
    ELSE
      -- One-time term: a renewal starts when the current term ends.
      SELECT max(current_period_end) INTO v_start FROM public.exos_fan_memberships
       WHERE product_id = pr.id AND holder_uid = p_holder_uid AND status = 'active' AND current_period_end > now();
      v_start := greatest(coalesce(v_start, now()), now());
      v_end := v_start + make_interval(days => pr.duration_days);
    END IF;
  END IF;
  IF p_gift_to IS NOT NULL THEN v_token := public._exos_membership_new_gift_token(); END IF;
  INSERT INTO public.exos_fan_memberships (org_id, product_id, product_name, billing, holder_uid, holder_email, status,
    current_period_start, current_period_end, stripe_subscription_id, stripe_customer_id, benefits, source, session_id,
    gift, gift_token_hash)
  VALUES (pr.org_id, pr.id, pr.name, CASE WHEN p_gift_to IS NOT NULL THEN 'once' ELSE pr.billing END,
    CASE WHEN p_gift_to IS NULL THEN p_holder_uid END, CASE WHEN p_gift_to IS NULL THEN lower(p_holder_email) ELSE lower(p_gift_to) END,
    CASE WHEN p_gift_to IS NULL THEN 'active' ELSE 'pending' END,
    CASE WHEN p_gift_to IS NULL THEN v_start END, v_end, p_subscription_id, p_customer_id,
    jsonb_build_object('discount_percent', pr.discount_percent, 'presale', pr.presale,
      'free_tickets_per_period', pr.free_tickets_per_period, 'guest_allowance', pr.guest_allowance,
      'household_seats', pr.household_seats,
      -- A gift is one period of the product.
      'term', CASE pr.billing WHEN 'month' THEN '1 month' WHEN 'year' THEN '1 year' ELSE pr.duration_days || ' days' END),
    p_source, p_session_id,
    CASE WHEN p_gift_to IS NOT NULL THEN jsonb_build_object('to_email', lower(p_gift_to), 'from_name', p_gift_from,
      'message', p_gift_message, 'status', 'pending', 'expires_at', now() + interval '90 days',
      'from_uid', p_holder_uid) END,
    CASE WHEN v_token IS NOT NULL THEN encode(sha256(convert_to(v_token, 'UTF8')), 'hex') END)
  RETURNING id INTO v_id;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = pr.org_id;
  IF v_token IS NOT NULL THEN
    PERFORM public._exos_membership_gift_mail(lower(p_gift_to), v_org, pr.name, p_gift_from, p_gift_message, v_token);
  ELSE
    BEGIN
      PERFORM public.exos_enqueue_webhook(pr.org_id, 'membership.created', jsonb_build_object('membership_id', v_id,
        'product_id', pr.id, 'billing', pr.billing, 'current_period_end', v_end));
    EXCEPTION WHEN others THEN NULL;
    END;
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_membership_create(uuid, uuid, text, text, text, text, text, timestamptz, text, text, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_commerce_fulfill_ext(o public.exos_commerce_orders, p_subscription_id text, p_period_end timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE pr public.exos_pass_products%ROWTYPE; v_id uuid; v_total int;
BEGIN
  IF o.kind = 'pass' THEN
    SELECT id INTO v_id FROM public.exos_passes WHERE session_id = o.session_id;
    IF v_id IS NOT NULL THEN RETURN jsonb_build_object('id', v_id); END IF;
    SELECT * INTO pr FROM public.exos_pass_products WHERE id = o.product_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'pass product gone'); END IF;
    IF pr.max_sold IS NOT NULL AND pr.sold >= pr.max_sold THEN RETURN jsonb_build_object('error', 'pass sold out'); END IF;
    UPDATE public.exos_pass_products SET sold = sold + 1 WHERE id = pr.id;
    v_total := CASE WHEN pr.kind = 'flex' THEN pr.credits
                    WHEN cardinality(pr.event_ids) > 0 THEN cardinality(pr.event_ids) * coalesce(pr.per_event_limit, 1)
                    ELSE NULL END;
    INSERT INTO public.exos_passes (org_id, product_id, kind, name, holder_uid, holder_email, credits_total,
      per_event_limit, eligibility, valid_until, session_id)
    VALUES (pr.org_id, pr.id, pr.kind, pr.name, o.buyer_uid, o.buyer_email, v_total,
      CASE WHEN pr.kind = 'season' THEN coalesce(pr.per_event_limit, 1) ELSE pr.per_event_limit END,
      jsonb_build_object('event_ids', to_jsonb(pr.event_ids), 'date_from', pr.date_from, 'date_to', pr.date_to,
        'tier_ids', to_jsonb(pr.tier_ids)),
      pr.valid_until, o.session_id)
    RETURNING id INTO v_id;
    IF o.buyer_uid IS NULL THEN
      RETURN jsonb_build_object('id', v_id, 'note', 'held for the buyer''s email');
    END IF;
    RETURN jsonb_build_object('id', v_id);
  ELSIF o.kind = 'membership' THEN
    IF o.buyer_uid IS NULL AND o.details->>'gift_to_email' IS NULL THEN
      RETURN jsonb_build_object('error', 'a membership needs an account');
    END IF;
    v_id := public._exos_membership_create(o.product_id, o.buyer_uid, o.buyer_email,
      CASE WHEN o.details->>'gift_to_email' IS NOT NULL THEN 'gift' ELSE 'purchase' END, o.session_id,
      p_subscription_id, o.stripe_customer_id, p_period_end,
      o.details->>'gift_to_email', o.details->>'gift_from_name', o.details->>'gift_message');
    RETURN jsonb_build_object('id', v_id);
  END IF;
  RETURN jsonb_build_object('error', 'unsupported order kind ' || o.kind);
END $$;
REVOKE ALL ON FUNCTION public._exos_commerce_fulfill_ext(public.exos_commerce_orders, text, timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_commerce_refund_ext(o public.exos_commerce_orders, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF o.kind = 'pass' THEN
    UPDATE public.exos_passes SET status = 'voided' WHERE id = o.result_id;
  ELSIF o.kind = 'membership' THEN
    -- Terminal (ended_reason): a later subscription event can't revive it.
    -- stripe-webhook also cancels the Stripe subscription.
    UPDATE public.exos_fan_memberships SET status = 'cancelled', ended_reason = 'refunded',
           current_period_end = least(coalesce(current_period_end, now()), now()),
           gift = CASE WHEN gift IS NULL THEN NULL ELSE gift || '{"status":"cancelled"}' END, gift_token_hash = NULL
     WHERE id = o.result_id;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_commerce_refund_ext(public.exos_commerce_orders, text) FROM PUBLIC, anon, authenticated;

-- Service role (stripe-webhook): invoice.paid, customer.subscription.updated /
-- .deleted. Finds the membership by subscription id; an unknown one (the first
-- invoice can land before checkout.session.completed) is ignored.
-- Rules:
--   * A refunded or cancelled-gift membership (ended_reason) is terminal: nothing
--     changes it again.
--   * Only invoice.paid moves the period end, and only forward. A cancelled or
--     expired membership comes back to active only through invoice.paid for a
--     period after the current one (money for a new period). A
--     customer.subscription.updated never reactivates and never extends.
CREATE OR REPLACE FUNCTION public.exos_membership_sync(p_subscription_id text, p_event text, p_status text,
  p_period_end timestamptz, p_cancel_at_period_end boolean DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_fan_memberships%ROWTYPE; v_status text; v_new_period boolean;
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  IF p_event NOT IN ('invoice_paid', 'updated', 'deleted') THEN RAISE EXCEPTION 'bad event' USING ERRCODE = '22023'; END IF;
  SELECT * INTO m FROM public.exos_fan_memberships WHERE stripe_subscription_id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'unknown'; END IF;
  IF m.ended_reason IS NOT NULL THEN RETURN m.status; END IF;
  v_new_period := p_event = 'invoice_paid' AND p_period_end IS NOT NULL
                  AND p_period_end > coalesce(m.current_period_end, '-infinity');
  v_status := CASE
    WHEN p_event = 'deleted' THEN 'cancelled'
    WHEN p_event = 'invoice_paid' THEN CASE WHEN v_new_period OR m.status IN ('active', 'past_due') THEN 'active' ELSE m.status END
    WHEN p_status IN ('active', 'trialing') THEN 'active'
    WHEN p_status IN ('past_due', 'unpaid') THEN 'past_due'
    WHEN p_status = 'canceled' THEN 'cancelled'
    WHEN p_status = 'incomplete_expired' THEN 'expired'
    ELSE m.status END;
  -- An update can end or degrade a membership, never revive one.
  IF p_event = 'updated' AND m.status IN ('cancelled', 'expired', 'pending') AND v_status IN ('active', 'past_due') THEN
    v_status := m.status;
  END IF;
  UPDATE public.exos_fan_memberships
     SET status = v_status,
         current_period_start = CASE WHEN v_new_period THEN coalesce(least(current_period_end, p_period_end), now()) ELSE current_period_start END,
         current_period_end = CASE WHEN v_new_period THEN p_period_end ELSE current_period_end END,
         cancel_at_period_end = CASE WHEN p_event = 'updated' THEN coalesce(p_cancel_at_period_end, cancel_at_period_end)
                                     ELSE cancel_at_period_end END
   WHERE id = m.id;
  BEGIN
    IF v_new_period AND m.current_period_end IS NOT NULL THEN
      PERFORM public.exos_enqueue_webhook(m.org_id, 'membership.renewed', jsonb_build_object('membership_id', m.id, 'current_period_end', p_period_end));
    ELSIF v_status = 'cancelled' AND m.status <> 'cancelled' THEN
      PERFORM public.exos_enqueue_webhook(m.org_id, 'membership.cancelled', jsonb_build_object('membership_id', m.id));
    END IF;
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN v_status;
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_sync(text, text, text, timestamptz, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_sync(text, text, text, timestamptz, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Gifts, household, door lookup, my lists
-- ---------------------------------------------------------------------------
-- Staff comp gift (owner / manager).
CREATE OR REPLACE FUNCTION public.exos_membership_gift(p_product_id uuid, p_to_email text, p_from_name text DEFAULT NULL, p_message text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_membership_products WHERE id = p_product_id;
  IF v_org IS NULL OR NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_to_email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'enter a valid email' USING ERRCODE = '22023'; END IF;
  IF NOT public.exos_rate_hit('mbr-gift:' || auth.uid()::text, 20) THEN RAISE EXCEPTION 'too many gifts a minute' USING ERRCODE = '54000'; END IF;
  RETURN public._exos_membership_create(p_product_id, auth.uid(), NULL, 'comp', NULL, NULL, NULL, NULL,
    btrim(p_to_email), p_from_name, p_message);
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_gift(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_gift(uuid, text, text, text) TO authenticated;

-- Cancel an unclaimed gift: owner / manager, or whoever gave it. A paid gift
-- isn't refunded automatically.
CREATE OR REPLACE FUNCTION public.exos_membership_cancel_gift(p_membership_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_fan_memberships%ROWTYPE;
BEGIN
  SELECT * INTO m FROM public.exos_fan_memberships WHERE id = p_membership_id FOR UPDATE;
  IF NOT FOUND OR NOT (public.exos_has_org_role(m.org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()
                       OR (m.gift->>'from_uid') = auth.uid()::text) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF m.status <> 'pending' THEN RAISE EXCEPTION 'this gift was already claimed' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.exos_fan_memberships SET status = 'cancelled', ended_reason = 'gift_cancelled',
         gift = gift || '{"status":"cancelled"}', gift_token_hash = NULL
   WHERE id = m.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_cancel_gift(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_cancel_gift(uuid) TO authenticated;

-- Claim a gift with the mailed token (signed in; the term starts now).
CREATE OR REPLACE FUNCTION public.exos_membership_claim_gift(p_token text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_fan_memberships%ROWTYPE; v_email text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  IF NOT public.exos_rate_hit('mbr-claim:' || auth.uid()::text, 10) THEN RAISE EXCEPTION 'too many attempts' USING ERRCODE = '54000'; END IF;
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'that link isn''t valid' USING ERRCODE = '22023'; END IF;
  SELECT * INTO m FROM public.exos_fan_memberships
   WHERE gift_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') FOR UPDATE;
  IF NOT FOUND OR m.status <> 'pending' THEN RAISE EXCEPTION 'that gift was claimed or cancelled' USING ERRCODE = 'P0001'; END IF;
  IF (m.gift->>'expires_at')::timestamptz < now() THEN RAISE EXCEPTION 'that gift link has expired' USING ERRCODE = 'P0001'; END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = auth.uid();
  UPDATE public.exos_fan_memberships
     SET holder_uid = auth.uid(), holder_email = coalesce(v_email, holder_email), status = 'active',
         current_period_start = now(), current_period_end = now() + (benefits->>'term')::interval,
         gift = gift || jsonb_build_object('status', 'claimed', 'claimed_at', now()), gift_token_hash = NULL
   WHERE id = m.id;
  BEGIN
    PERFORM public.exos_enqueue_webhook(m.org_id, 'membership.created', jsonb_build_object('membership_id', m.id, 'gift', true));
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN m.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_claim_gift(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_claim_gift(text) TO authenticated;

-- Every household add / remove, for the anti-spam rules below (service only).
CREATE TABLE IF NOT EXISTS public.exos_membership_household_changes (
  id            bigserial PRIMARY KEY,
  membership_id uuid NOT NULL REFERENCES public.exos_fan_memberships (id) ON DELETE CASCADE,
  email         text NOT NULL,
  action        text NOT NULL CHECK (action IN ('add', 'remove')),
  mailed        boolean NOT NULL DEFAULT false,
  actor         uuid,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_membership_household_changes_idx ON public.exos_membership_household_changes (membership_id, created_at);
CREATE INDEX IF NOT EXISTS exos_membership_household_changes_email_idx ON public.exos_membership_household_changes (email, created_at) WHERE mailed;
ALTER TABLE public.exos_membership_household_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_membership_household_changes FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.exos_membership_household_changes_id_seq FROM anon, authenticated;
GRANT ALL ON public.exos_membership_household_changes TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.exos_membership_household_changes_id_seq TO service_role;

-- Holder: share benefits with up to household_seats emails.
-- Anti-spam: 10 changes a minute per account (exos_rate_hit); at most
-- 2 x seats + 4 adds / removes per membership per billing period (at least
-- the last 30 days);
-- an address gets at most 3 household mails a day from all memberships, and
-- none when it was removed from this same membership in the last 24 hours (a
-- re-add then is silent).
CREATE OR REPLACE FUNCTION public.exos_membership_household_set(p_membership_id uuid, p_email text, p_add boolean DEFAULT true)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_fan_memberships%ROWTYPE; v_email text := lower(btrim(coalesce(p_email, ''))); n int; v_org text;
        v_mail boolean;
BEGIN
  SELECT * INTO m FROM public.exos_fan_memberships WHERE id = p_membership_id FOR UPDATE;
  IF NOT FOUND OR m.holder_uid IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'membership not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT public.exos_rate_hit('mbr-hh:u:' || auth.uid()::text, 10) THEN
    RAISE EXCEPTION 'too many household changes, try again in a minute' USING ERRCODE = '54000';
  END IF;
  SELECT count(*) INTO n FROM public.exos_membership_household_changes c
   WHERE c.membership_id = m.id
     -- The current period, and never less than the last 30 days.
     AND c.created_at >= least(coalesce(m.current_period_start, now()), now() - interval '30 days');
  IF n >= 2 * coalesce((m.benefits->>'household_seats')::int, 0) + 4 THEN
    RAISE EXCEPTION 'too many household changes this period' USING ERRCODE = '54000';
  END IF;
  IF NOT p_add THEN
    DELETE FROM public.exos_membership_household WHERE membership_id = m.id AND email = v_email;
    IF FOUND THEN
      INSERT INTO public.exos_membership_household_changes (membership_id, email, action, actor) VALUES (m.id, v_email, 'remove', auth.uid());
    END IF;
  ELSE
    IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'enter a valid email' USING ERRCODE = '22023'; END IF;
    IF v_email = lower(coalesce(m.holder_email, '')) THEN RAISE EXCEPTION 'that''s you' USING ERRCODE = '22023'; END IF;
    SELECT count(*) INTO n FROM public.exos_membership_household WHERE membership_id = m.id;
    IF n >= coalesce((m.benefits->>'household_seats')::int, 0) THEN
      RAISE EXCEPTION 'no household seats left' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.exos_membership_household (membership_id, email) VALUES (m.id, v_email) ON CONFLICT DO NOTHING;
    IF FOUND THEN
      v_mail := NOT EXISTS (SELECT 1 FROM public.exos_membership_household_changes c
                             WHERE c.membership_id = m.id AND c.email = v_email AND c.action = 'remove'
                               AND c.created_at > now() - interval '24 hours')
            AND (SELECT count(*) FROM public.exos_membership_household_changes c
                  WHERE c.email = v_email AND c.mailed AND c.created_at > now() - interval '24 hours') < 3
            AND public.exos_rate_hit('mbr-hh:to:' || v_email, 2);
      INSERT INTO public.exos_membership_household_changes (membership_id, email, action, mailed, actor)
      VALUES (m.id, v_email, 'add', v_mail, auth.uid());
      SELECT name INTO v_org FROM public.exos_orgs WHERE id = m.org_id;
      IF v_mail THEN BEGIN
        INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
        VALUES ('membership-household', v_email, left('You''re on a ' || coalesce(v_org, '') || ' membership', 200),
          '<p>' || replace(replace(replace(coalesce(m.holder_email, 'A member'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') ||
          ' added you to their <strong>' || replace(replace(replace(m.product_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') ||
          '</strong> membership. Sign in with this email to get the member price, presales and free tickets.</p>',
          auth.uid(), 'pending');
      EXCEPTION WHEN others THEN NULL;
      END; END IF;
    END IF;
  END IF;
  SELECT count(*) INTO n FROM public.exos_membership_household WHERE membership_id = m.id;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_household_set(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_household_set(uuid, text, boolean) TO authenticated;

-- Door staff: look up a membership card (its QR carries the membership id).
-- Status, product and the member's first name; never the email.
CREATE OR REPLACE FUNCTION public.exos_membership_scan(p_org_id uuid, p_membership_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_fan_memberships%ROWTYPE; v_name text;
BEGIN
  IF NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'scanner']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO m FROM public.exos_fan_memberships WHERE id = p_membership_id AND org_id = p_org_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('valid', false, 'reason', 'not a member card of this organization'); END IF;
  SELECT coalesce(nullif(split_part(coalesce(u.raw_user_meta_data->>'full_name', ''), ' ', 1), ''), NULL) INTO v_name
    FROM auth.users u WHERE u.id = m.holder_uid;
  RETURN jsonb_build_object('valid', public._exos_membership_benefits_live(m),
    'status', public.exos_membership_effective_status(m.status, m.current_period_end),
    'product_name', m.product_name, 'member_first_name', v_name, 'current_period_end', m.current_period_end,
    'discount_percent', (m.benefits->>'discount_percent')::numeric,
    'household_seats_used', (SELECT count(*) FROM public.exos_membership_household h WHERE h.membership_id = m.id));
EXCEPTION WHEN undefined_column THEN
  -- auth.users without raw_user_meta_data (test harnesses): no name.
  RETURN jsonb_build_object('valid', public._exos_membership_benefits_live(m),
    'status', public.exos_membership_effective_status(m.status, m.current_period_end),
    'product_name', m.product_name, 'member_first_name', NULL, 'current_period_end', m.current_period_end,
    'discount_percent', (m.benefits->>'discount_percent')::numeric,
    'household_seats_used', (SELECT count(*) FROM public.exos_membership_household h WHERE h.membership_id = m.id));
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_scan(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_scan(uuid, uuid) TO authenticated;

-- Self: memberships I hold or share (shared rows: no billing details).
CREATE OR REPLACE FUNCTION public.exos_my_memberships()
RETURNS TABLE (id uuid, org_id uuid, org_name text, product_name text, billing text, status text,
  current_period_end timestamptz, cancel_at_period_end boolean, benefits jsonb, shared boolean,
  household text[], free_used_this_period integer, can_manage_billing boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_email text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL;
  RETURN QUERY
  SELECT m.id, m.org_id, o.name, m.product_name, CASE WHEN m.holder_uid = auth.uid() THEN m.billing END,
         public.exos_membership_effective_status(m.status, m.current_period_end), m.current_period_end,
         m.cancel_at_period_end, m.benefits, m.holder_uid IS DISTINCT FROM auth.uid(),
         CASE WHEN m.holder_uid = auth.uid() THEN ARRAY(SELECT h.email FROM public.exos_membership_household h WHERE h.membership_id = m.id ORDER BY h.email) END,
         (SELECT count(*)::int FROM public.exos_membership_redemptions r WHERE r.membership_id = m.id
            AND r.period_end IS NOT DISTINCT FROM m.current_period_end),
         m.holder_uid = auth.uid() AND m.stripe_subscription_id IS NOT NULL
    FROM public.exos_fan_memberships m JOIN public.exos_orgs o ON o.id = m.org_id
   WHERE m.status <> 'pending' AND (m.holder_uid = auth.uid() OR (v_email IS NOT NULL AND EXISTS (
           SELECT 1 FROM public.exos_membership_household h WHERE h.membership_id = m.id AND h.email = v_email)))
   ORDER BY m.created_at DESC;
END $$;
REVOKE ALL ON FUNCTION public.exos_my_memberships() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_my_memberships() TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_my_passes()
RETURNS TABLE (id uuid, org_id uuid, org_name text, kind text, name text, credits_total integer, credits_used integer,
  per_event_limit integer, eligibility jsonb, valid_until timestamptz, status text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p.id, p.org_id, o.name, p.kind, p.name, p.credits_total, p.credits_used, p.per_event_limit, p.eligibility,
         p.valid_until, p.status
    FROM public.exos_passes p JOIN public.exos_orgs o ON o.id = p.org_id
   WHERE p.holder_uid = auth.uid() ORDER BY p.created_at DESC;
$$;
REVOKE ALL ON FUNCTION public.exos_my_passes() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_my_passes() TO authenticated;

-- A guest who bought a pass: it is claimed by the account with that confirmed email.
CREATE OR REPLACE FUNCTION public.exos_claim_my_passes()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_email text; n int;
BEGIN
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL;
  IF v_email IS NULL THEN RETURN 0; END IF;
  UPDATE public.exos_passes SET holder_uid = auth.uid() WHERE holder_uid IS NULL AND holder_email = v_email;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.exos_claim_my_passes() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_claim_my_passes() TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Member presale on every ticket-issuing path
-- ---------------------------------------------------------------------------
-- Checkout fulfillment checks it in _exos_commerce_on_fulfill (a failed order
-- is refunded). Every other insert of a ticket into a presale tier (free
-- claims, waitlist / voucher claims, any future box-office mint) is checked
-- here, against the signed-in caller (or the ticket owner):
--   * staff of the event's org (owner / manager / scanner) keep their override
--     (comps, guest lists, box office);
--   * a server-side insert with no signed-in user and not inside checkout
--     fulfillment (marketplace / feed orders the organizer configured) passes;
--   * everyone else must be an eligible member.
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_member_presale()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF NEW.tier_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_member_presales ps WHERE ps.event_id = NEW.event_id) THEN
    RETURN NEW;
  END IF;
  -- Inside exos_fulfill_checkout: the commerce hook decided (graceful failure).
  -- The setting lives for the rest of the transaction, so it only counts while
  -- that order is still being fulfilled (pending, same event).
  IF EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs
              WHERE cs.session_id = nullif(current_setting('exos.table_mint', true), '')
                AND cs.status = 'pending' AND cs.event_id = NEW.event_id) THEN
    RETURN NEW;
  END IF;
  IF v_uid IS NULL THEN RETURN NEW; END IF;
  IF public.exos_has_org_role(NEW.org_id, ARRAY['owner', 'manager', 'scanner']) OR public.exos_is_admin() THEN RETURN NEW; END IF;
  IF public._exos_presale_blocks(NEW.event_id, NEW.tier_id, v_uid) THEN
    RAISE EXCEPTION 'Tickets are on presale for members right now.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_ticket_member_presale() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_member_presale ON public.exos_tickets;
CREATE TRIGGER exos_tickets_member_presale BEFORE INSERT ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_member_presale();
