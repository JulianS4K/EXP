-- ============================================================================
-- Giving and gift card writes (Opendate parity, gap wave): campaign lifecycle,
-- monthly recurring donations (Stripe subscriptions), donation delete and
-- offline refunds, a bulk import of external gift cards (Gift Up! and the
-- like), and gift cards applied to organizer / partner reservations.
-- docs/giving.md, docs/gift-cards.md, docs/partner-sales.md.
-- ============================================================================
-- Touches:  A: exos_giving_campaigns.completed_at
--           A: exos_donations.refunded_cents / recurring_id / payment_intent /
--              stripe_invoice_id
--           N: exos_donation_ledger (offline refunds and deletions; no FK, so a
--              deleted donation keeps its audit row)
--           N: exos_recurring_donations, exos_recurring_donation_events
--           N: exos_gift_card_imports (one row per import batch, idempotency)
--           A: exos_gift_cards.external_source / external_code_hash;
--              C: source (+ 'import'), payment_method (+ 'external'), last4
--              (any A-Z / 0-9: an imported code keeps its own characters)
--           A: exos_gift_card_redemptions.partner_reservation_id / fee_paid_at_sale
--           C: exos_commerce_orders.kind (+ 'recurring_donation')
--           R: _exos_gift_card_find (an imported code is found by its own hash)
--           R: exos_public_giving_campaigns (raised = net of offline refunds)
--           P: exos_commerce_fulfill / exos_commerce_refund (recurring branch)
--           N: trigger exos_partner_reservation_gift_cards on
--              exos_partner_reservations (expired / cancelled give the held
--              gift card parts back, completed captures them)
--           N: the functions below (service role for exos-api / exos-commerce /
--              stripe-webhook; authenticated wrappers for the dashboard, each
--              role-checked)
-- Pre-reqs: 20261030130000 (gift cards, giving), 20261030130500 (commerce
--           kinds), 20261031130000 (partner reservations).
--
-- Money: integer cents. Every gift card balance change is an
-- exos_gift_card_ledger row (through _exos_gift_card_move, which locks the
-- card), every donation refund or deletion an exos_donation_ledger row, every
-- recurring charge an exos_recurring_donation_events row; each is unique per
-- key, so a retry moves nothing twice.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded patches).
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

-- ---------------------------------------------------------------------------
-- 0. Columns and widened checks
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_giving_campaigns ADD COLUMN IF NOT EXISTS completed_at timestamptz;

ALTER TABLE public.exos_donations
  ADD COLUMN IF NOT EXISTS refunded_cents integer NOT NULL DEFAULT 0 CHECK (refunded_cents >= 0),
  ADD COLUMN IF NOT EXISTS recurring_id uuid,
  ADD COLUMN IF NOT EXISTS payment_intent text CHECK (payment_intent IS NULL OR payment_intent ~ '^pi_[A-Za-z0-9_]{1,250}$'),
  ADD COLUMN IF NOT EXISTS stripe_invoice_id text CHECK (stripe_invoice_id IS NULL OR stripe_invoice_id ~ '^in_[A-Za-z0-9_]{1,250}$');
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_donations_refunded_le_total') THEN
    ALTER TABLE public.exos_donations ADD CONSTRAINT exos_donations_refunded_le_total CHECK (refunded_cents <= total_cents);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_donations_recurring_idx ON public.exos_donations (recurring_id) WHERE recurring_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_donations_pi_idx ON public.exos_donations (payment_intent) WHERE payment_intent IS NOT NULL;

ALTER TABLE public.exos_gift_cards
  ADD COLUMN IF NOT EXISTS external_source text CHECK (external_source IS NULL OR external_source ~ '^[a-z0-9_]{2,40}$'),
  ADD COLUMN IF NOT EXISTS external_code_hash text CHECK (external_code_hash IS NULL OR external_code_hash ~ '^[0-9a-f]{64}$');
CREATE UNIQUE INDEX IF NOT EXISTS exos_gift_cards_external_uq
  ON public.exos_gift_cards (org_id, external_source, external_code_hash) WHERE external_code_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_gift_cards_external_lookup_idx
  ON public.exos_gift_cards (external_code_hash) WHERE external_code_hash IS NOT NULL;

-- Rebuild an inline CHECK (col IN / = ANY list) with extra values, from its
-- live definition, so a sibling migration's additions survive.
CREATE OR REPLACE FUNCTION pg_temp.exos_widen_check(p_table regclass, p_con text, p_col text, p_add text[])
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_def text; v_list text[]; t text; v_changed boolean := false;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def FROM pg_constraint c WHERE c.conrelid = p_table AND c.conname = p_con;
  IF v_def IS NULL THEN RAISE EXCEPTION '%: constraint % not found', p_table, p_con; END IF;
  SELECT array_agg(m[1]) INTO v_list FROM regexp_matches(v_def, '''([a-z0-9_-]+)''', 'g') m;
  FOREACH t IN ARRAY p_add LOOP
    IF NOT t = ANY (v_list) THEN v_list := v_list || t; v_changed := true; END IF;
  END LOOP;
  IF v_changed THEN
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', p_table, p_con);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%I = ANY (%L::text[]))', p_table, p_con, p_col, v_list);
  END IF;
END $$;
SELECT pg_temp.exos_widen_check('public.exos_gift_cards', 'exos_gift_cards_source_check', 'source', ARRAY['import']);
SELECT pg_temp.exos_widen_check('public.exos_gift_cards', 'exos_gift_cards_payment_method_check', 'payment_method', ARRAY['external']);
SELECT pg_temp.exos_widen_check('public.exos_commerce_orders', 'exos_commerce_orders_kind_check', 'kind', ARRAY['recurring_donation']);
DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_gift_cards'::regclass AND c.conname = 'exos_gift_cards_last4_check';
  IF v_def IS NOT NULL AND v_def LIKE '%A-Z2-9%' THEN
    ALTER TABLE public.exos_gift_cards DROP CONSTRAINT exos_gift_cards_last4_check;
    ALTER TABLE public.exos_gift_cards ADD CONSTRAINT exos_gift_cards_last4_check CHECK (last4 ~ '^[A-Z0-9]{4}$');
  END IF;
END $$;

ALTER TABLE public.exos_gift_card_redemptions
  ADD COLUMN IF NOT EXISTS partner_reservation_id uuid REFERENCES public.exos_partner_reservations (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS fee_paid_at_sale boolean;
CREATE INDEX IF NOT EXISTS exos_gift_card_redemptions_res_idx ON public.exos_gift_card_redemptions (partner_reservation_id)
  WHERE partner_reservation_id IS NOT NULL;

-- The monthly gifts table (section 3) comes first: the campaign JSON counts them.
CREATE TABLE IF NOT EXISTS public.exos_recurring_donations (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  campaign_id            uuid NOT NULL REFERENCES public.exos_giving_campaigns (id) ON DELETE RESTRICT,
  amount_cents           integer NOT NULL CHECK (amount_cents BETWEEN 100 AND 10000000),
  cover_fees_cents       integer NOT NULL DEFAULT 0 CHECK (cover_fees_cents >= 0),
  currency               text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  interval               text NOT NULL DEFAULT 'month' CHECK (interval IN ('month')),
  status                 text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'past_due', 'cancelled', 'ended')),
  donor_uid              uuid,
  donor_email            text NOT NULL CHECK (length(donor_email) BETWEEN 3 AND 320),
  donor_name             text CHECK (donor_name IS NULL OR length(donor_name) <= 120),
  anonymous              boolean NOT NULL DEFAULT false,
  note                   text CHECK (note IS NULL OR length(note) <= 1000),
  source                 text NOT NULL DEFAULT 'online' CHECK (source IN ('online', 'api')),
  session_id             text CHECK (session_id IS NULL OR session_id ~ '^[A-Za-z0-9_-]{1,255}$'),
  stripe_subscription_id text UNIQUE CHECK (stripe_subscription_id IS NULL OR stripe_subscription_id ~ '^sub_[A-Za-z0-9]{1,250}$'),
  stripe_customer_id     text CHECK (stripe_customer_id IS NULL OR stripe_customer_id ~ '^cus_[A-Za-z0-9]{1,250}$'),
  current_period_end     timestamptz,
  last_paid_at           timestamptz,
  failed_payments        integer NOT NULL DEFAULT 0 CHECK (failed_payments >= 0),
  last_failure           text CHECK (last_failure IS NULL OR length(last_failure) <= 500),
  cancel_requested_at    timestamptz,
  cancelled_at           timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_recurring_donations_org_idx ON public.exos_recurring_donations (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_recurring_donations_campaign_idx ON public.exos_recurring_donations (campaign_id);
CREATE INDEX IF NOT EXISTS exos_recurring_donations_donor_idx ON public.exos_recurring_donations (donor_uid) WHERE donor_uid IS NOT NULL;
DROP TRIGGER IF EXISTS exos_recurring_donations_touch ON public.exos_recurring_donations;
CREATE TRIGGER exos_recurring_donations_touch BEFORE UPDATE ON public.exos_recurring_donations
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_donations_recurring_fk') THEN
    ALTER TABLE public.exos_donations ADD CONSTRAINT exos_donations_recurring_fk
      FOREIGN KEY (recurring_id) REFERENCES public.exos_recurring_donations (id) ON DELETE SET NULL;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. Campaign lifecycle: create, update, activate, complete, delete
-- ---------------------------------------------------------------------------
-- Status as the API and the dashboard show it: completed (closed for good,
-- completed_at), active (taking gifts), draft (not yet activated, or turned off).
CREATE OR REPLACE FUNCTION public._exos_giving_campaign_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', c.id, 'name', c.name, 'slug', c.slug, 'description', c.description, 'image_url', c.image_url,
    'currency', c.currency, 'goal_cents', c.goal_cents, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
    'active', c.active, 'status', CASE WHEN c.completed_at IS NOT NULL THEN 'completed' WHEN c.active THEN 'active' ELSE 'draft' END,
    'completed_at', c.completed_at, 'suggested_cents', to_jsonb(c.suggested_cents), 'cover_fees', c.cover_fees,
    'cover_fees_bps', c.cover_fees_bps, 'checkout_add_on', c.checkout_add_on, 'round_up', c.round_up,
    'tax_receipt_text', c.tax_receipt_text, 'created_at', c.created_at, 'updated_at', c.updated_at,
    'raised_cents', coalesce((SELECT sum(greatest(d.amount_cents - d.refunded_cents, 0)) FROM public.exos_donations d
                               WHERE d.campaign_id = c.id AND d.status = 'received'), 0)::bigint,
    'donation_count', (SELECT count(*) FROM public.exos_donations d WHERE d.campaign_id = c.id AND d.status = 'received')::int,
    'recurring_count', (SELECT count(*) FROM public.exos_recurring_donations r
                         WHERE r.campaign_id = c.id AND r.status IN ('active', 'past_due'))::int)
  FROM public.exos_giving_campaigns c WHERE c.id = p_id
$$;

CREATE OR REPLACE FUNCTION public._exos_int_array(p jsonb, p_name text)
RETURNS integer[] LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
BEGIN
  IF p IS NULL OR jsonb_typeof(p) = 'null' THEN RETURN NULL; END IF;
  IF jsonb_typeof(p) <> 'array' THEN RAISE EXCEPTION '% must be a list of whole cents', p_name USING ERRCODE = '22023'; END IF;
  RETURN ARRAY(SELECT (x #>> '{}')::int FROM jsonb_array_elements(p) x);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RAISE EXCEPTION '% must be a list of whole cents', p_name USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public._exos_int_array(jsonb, text) FROM PUBLIC, anon, authenticated;

-- Internal (callers check who may). p_op: create | update | activate |
-- complete | delete. Returns { campaign, cancel_subscriptions } (complete: the
-- Stripe subscriptions of its recurring donations, for the caller to cancel).
CREATE OR REPLACE FUNCTION public._exos_giving_campaign_op(p_org_id uuid, p_actor uuid, p_op text, p_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_giving_campaigns%ROWTYPE; b jsonb := coalesce(p_body, '{}'::jsonb); v_id uuid; v_subs text[];
        v_slug text;
BEGIN
  IF p_op NOT IN ('create', 'update', 'activate', 'complete', 'delete') THEN
    RAISE EXCEPTION 'bad operation' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(b) <> 'object' THEN RAISE EXCEPTION 'the body must be an object' USING ERRCODE = '22023'; END IF;
  IF p_op = 'create' THEN
    IF nullif(btrim(b->>'name'), '') IS NULL THEN RAISE EXCEPTION 'name is required' USING ERRCODE = '22023'; END IF;
    v_slug := coalesce(nullif(btrim(b->>'slug'), ''),
      nullif(left(regexp_replace(regexp_replace(lower(b->>'name'), '[^a-z0-9]+', '-', 'g'), '^-+|-+$', '', 'g'), 80), ''), 'give');
    IF EXISTS (SELECT 1 FROM public.exos_giving_campaigns WHERE org_id = p_org_id AND slug = v_slug) THEN
      RAISE EXCEPTION 'a campaign with the slug "%" already exists', v_slug USING ERRCODE = '23505';
    END IF;
    INSERT INTO public.exos_giving_campaigns (org_id, name, slug, description, image_url, currency, goal_cents,
      starts_at, ends_at, active, suggested_cents, cover_fees, cover_fees_bps, checkout_add_on, round_up, tax_receipt_text, created_by)
    VALUES (p_org_id, btrim(b->>'name'), v_slug, b->>'description', b->>'image_url',
      lower(coalesce(b->>'currency', 'usd')), coalesce((b->>'goal_cents')::int, 0),
      (b->>'starts_at')::timestamptz, (b->>'ends_at')::timestamptz,
      -- A partner-created campaign starts as a draft (POST …/activate opens it).
      coalesce((b->>'active')::boolean, false),
      coalesce(public._exos_int_array(b->'suggested_cents', 'suggested_cents'), '{1000,2500,5000,10000}'),
      coalesce((b->>'cover_fees')::boolean, true), coalesce((b->>'cover_fees_bps')::int, 300),
      coalesce((b->>'checkout_add_on')::boolean, false), coalesce((b->>'round_up')::boolean, false),
      b->>'tax_receipt_text', p_actor)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('campaign', public._exos_giving_campaign_json(v_id), 'cancel_subscriptions', '[]'::jsonb);
  END IF;

  SELECT * INTO c FROM public.exos_giving_campaigns WHERE id = p_id AND org_id = p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'campaign not found' USING ERRCODE = 'P0002'; END IF;

  IF p_op = 'update' THEN
    IF b ? 'slug' AND b->>'slug' IS DISTINCT FROM c.slug
       AND EXISTS (SELECT 1 FROM public.exos_giving_campaigns WHERE org_id = p_org_id AND slug = b->>'slug') THEN
      RAISE EXCEPTION 'a campaign with the slug "%" already exists', b->>'slug' USING ERRCODE = '23505';
    END IF;
    IF b ? 'active' AND c.completed_at IS NOT NULL AND (b->>'active')::boolean THEN
      RAISE EXCEPTION 'this campaign was completed; it can''t take gifts again' USING ERRCODE = '55000';
    END IF;
    UPDATE public.exos_giving_campaigns SET
      name            = CASE WHEN b ? 'name' THEN btrim(b->>'name') ELSE name END,
      slug            = CASE WHEN b ? 'slug' THEN b->>'slug' ELSE slug END,
      description     = CASE WHEN b ? 'description' THEN b->>'description' ELSE description END,
      image_url       = CASE WHEN b ? 'image_url' THEN b->>'image_url' ELSE image_url END,
      currency        = CASE WHEN b ? 'currency' THEN lower(b->>'currency') ELSE currency END,
      goal_cents      = CASE WHEN b ? 'goal_cents' THEN coalesce((b->>'goal_cents')::int, 0) ELSE goal_cents END,
      starts_at       = CASE WHEN b ? 'starts_at' THEN (b->>'starts_at')::timestamptz ELSE starts_at END,
      ends_at         = CASE WHEN b ? 'ends_at' THEN (b->>'ends_at')::timestamptz ELSE ends_at END,
      active          = CASE WHEN b ? 'active' THEN coalesce((b->>'active')::boolean, active) ELSE active END,
      suggested_cents = CASE WHEN b ? 'suggested_cents' THEN coalesce(public._exos_int_array(b->'suggested_cents', 'suggested_cents'), '{}') ELSE suggested_cents END,
      cover_fees      = CASE WHEN b ? 'cover_fees' THEN coalesce((b->>'cover_fees')::boolean, cover_fees) ELSE cover_fees END,
      cover_fees_bps  = CASE WHEN b ? 'cover_fees_bps' THEN coalesce((b->>'cover_fees_bps')::int, cover_fees_bps) ELSE cover_fees_bps END,
      checkout_add_on = CASE WHEN b ? 'checkout_add_on' THEN coalesce((b->>'checkout_add_on')::boolean, checkout_add_on) ELSE checkout_add_on END,
      round_up        = CASE WHEN b ? 'round_up' THEN coalesce((b->>'round_up')::boolean, round_up) ELSE round_up END,
      tax_receipt_text = CASE WHEN b ? 'tax_receipt_text' THEN b->>'tax_receipt_text' ELSE tax_receipt_text END
     WHERE id = c.id;
  ELSIF p_op = 'activate' THEN
    IF c.completed_at IS NOT NULL THEN
      RAISE EXCEPTION 'this campaign was completed; it can''t take gifts again' USING ERRCODE = '55000';
    END IF;
    IF c.ends_at IS NOT NULL AND c.ends_at <= now() THEN
      RAISE EXCEPTION 'this campaign ended on %: move ends_at first', to_char(c.ends_at, 'YYYY-MM-DD') USING ERRCODE = '55000';
    END IF;
    UPDATE public.exos_giving_campaigns SET active = true WHERE id = c.id AND NOT active;
  ELSIF p_op = 'complete' THEN
    -- Closed for good: off the public page and checkout, and its monthly gifts
    -- stop (the caller cancels the subscriptions in Stripe; the webhook's
    -- customer.subscription.deleted then marks each one cancelled).
    UPDATE public.exos_giving_campaigns SET active = false, completed_at = coalesce(completed_at, now()) WHERE id = c.id;
    UPDATE public.exos_recurring_donations SET cancel_requested_at = coalesce(cancel_requested_at, now())
     WHERE campaign_id = c.id AND status IN ('pending', 'active', 'past_due');
    SELECT coalesce(array_agg(stripe_subscription_id ORDER BY created_at), '{}') INTO v_subs
      FROM public.exos_recurring_donations
     WHERE campaign_id = c.id AND status IN ('pending', 'active', 'past_due') AND stripe_subscription_id IS NOT NULL;
    -- A monthly gift that never got a subscription (checkout abandoned) just ends.
    UPDATE public.exos_recurring_donations SET status = 'cancelled', cancelled_at = now()
     WHERE campaign_id = c.id AND status = 'pending' AND stripe_subscription_id IS NULL;
  ELSIF p_op = 'delete' THEN
    IF EXISTS (SELECT 1 FROM public.exos_donations d WHERE d.campaign_id = c.id)
       OR EXISTS (SELECT 1 FROM public.exos_recurring_donations r WHERE r.campaign_id = c.id) THEN
      RAISE EXCEPTION 'this campaign has donations: complete it instead' USING ERRCODE = '55000';
    END IF;
    DELETE FROM public.exos_giving_campaigns WHERE id = c.id;
    RETURN jsonb_build_object('campaign', jsonb_build_object('id', c.id, 'deleted', true), 'cancel_subscriptions', '[]'::jsonb);
  END IF;
  RETURN jsonb_build_object('campaign', public._exos_giving_campaign_json(c.id), 'cancel_subscriptions', to_jsonb(coalesce(v_subs, '{}')));
EXCEPTION
  WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'a field has the wrong type: %', SQLERRM USING ERRCODE = '22023';
END $$;

-- Service role (exos-api): the key's org explicitly.
CREATE OR REPLACE FUNCTION public.exos_api_giving_campaign_op(p_org_id uuid, p_op text, p_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_giving_campaign_op(p_org_id, NULL, p_op, p_id, p_body);
END $$;

-- Dashboard: owner / manager (as the table's own write policies).
CREATE OR REPLACE FUNCTION public.exos_giving_campaign_op(p_op text, p_id uuid DEFAULT NULL, p_body jsonb DEFAULT '{}'::jsonb,
  p_org_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid := p_org_id;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  IF p_op <> 'create' THEN SELECT org_id INTO v_org FROM public.exos_giving_campaigns WHERE id = p_id; END IF;
  IF v_org IS NULL OR NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_giving_campaign_op(v_org, auth.uid(), p_op, p_id, p_body);
END $$;

-- ---------------------------------------------------------------------------
-- 2. Donations: delete an offline one, record an offline refund
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_donation_ledger (
  id           bigserial PRIMARY KEY,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  donation_id  uuid NOT NULL,   -- no FK: a deleted donation keeps its row here
  campaign_id  uuid,
  kind         text NOT NULL CHECK (kind IN ('offline_refund', 'deleted')),
  amount_cents integer NOT NULL,   -- signed: what left the campaign's total
  method       text CHECK (method IS NULL OR method IN ('cash', 'check', 'card', 'bank_transfer', 'other')),
  key          text NOT NULL CHECK (key ~ '^[A-Za-z0-9_:.-]{1,200}$'),
  note         text CHECK (note IS NULL OR length(note) <= 1000),
  snapshot     jsonb,
  actor        uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (donation_id, kind, key)
);
CREATE INDEX IF NOT EXISTS exos_donation_ledger_org_idx ON public.exos_donation_ledger (org_id, created_at DESC);
ALTER TABLE public.exos_donation_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_donation_ledger FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_donation_ledger TO authenticated;
DROP POLICY IF EXISTS exos_donation_ledger_sel ON public.exos_donation_ledger;
CREATE POLICY exos_donation_ledger_sel ON public.exos_donation_ledger FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin());
REVOKE ALL ON SEQUENCE public.exos_donation_ledger_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_donation_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', d.id, 'campaign_id', d.campaign_id, 'amount_cents', d.amount_cents,
    'cover_fees_cents', d.cover_fees_cents, 'total_cents', d.total_cents, 'refunded_cents', d.refunded_cents,
    'currency', d.currency, 'method', d.method, 'status', d.status, 'donor_name', d.donor_name, 'donor_email', d.donor_email,
    'anonymous', d.anonymous, 'recurring_id', d.recurring_id, 'session_id', d.session_id, 'receipt_number', d.receipt_number,
    'refunded_at', d.refunded_at, 'created_at', d.created_at,
    'refunds', coalesce((SELECT jsonb_agg(jsonb_build_object('amount_cents', -l.amount_cents, 'method', l.method,
        'reference', l.key, 'note', l.note, 'created_at', l.created_at) ORDER BY l.id)
       FROM public.exos_donation_ledger l WHERE l.donation_id = d.id AND l.kind = 'offline_refund'), '[]'::jsonb))
  FROM public.exos_donations d WHERE d.id = p_id
$$;

-- Only a cash / check / other gift that no payment stands behind (no order,
-- no Stripe charge, no monthly plan, nothing refunded) can be deleted: a typo
-- in the books. Anything else is refunded instead (55000 -> 409).
CREATE OR REPLACE FUNCTION public._exos_donation_delete(p_org_id uuid, p_actor uuid, p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE d public.exos_donations%ROWTYPE;
BEGIN
  SELECT * INTO d FROM public.exos_donations WHERE id = p_id AND org_id = p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'donation not found' USING ERRCODE = 'P0002'; END IF;
  IF d.method NOT IN ('cash', 'check', 'other') OR d.session_id IS NOT NULL OR d.recurring_id IS NOT NULL
     OR d.payment_intent IS NOT NULL THEN
    RAISE EXCEPTION 'only an offline donation with no payment behind it can be deleted: refund this one instead'
      USING ERRCODE = '55000';
  END IF;
  IF d.refunded_cents > 0 OR d.status <> 'received'
     OR EXISTS (SELECT 1 FROM public.exos_donation_ledger l WHERE l.donation_id = d.id) THEN
    RAISE EXCEPTION 'this donation has a refund recorded, so it stays in the books' USING ERRCODE = '55000';
  END IF;
  INSERT INTO public.exos_donation_ledger (org_id, donation_id, campaign_id, kind, amount_cents, method, key, note, snapshot, actor)
  VALUES (d.org_id, d.id, d.campaign_id, 'deleted', -d.amount_cents, CASE WHEN d.method IN ('cash', 'check', 'other') THEN d.method END,
          'delete', 'deleted', public._exos_donation_json(d.id), p_actor);
  DELETE FROM public.exos_donations WHERE id = d.id;
  RETURN jsonb_build_object('id', d.id, 'deleted', true);
END $$;

-- A refund paid outside Stripe (cash back, a check, a bank transfer). Never
-- calls Stripe. Idempotent per p_key (default 'full'); never more than is left;
-- the donation reads 'refunded' once nothing is left.
CREATE OR REPLACE FUNCTION public._exos_donation_offline_refund(p_org_id uuid, p_actor uuid, p_id uuid,
  p_amount_cents integer, p_key text, p_method text, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE d public.exos_donations%ROWTYPE; v_key text := coalesce(nullif(btrim(p_key), ''), 'full'); v_amt int; v_left int;
BEGIN
  IF v_key !~ '^[A-Za-z0-9_:.-]{1,200}$' THEN RAISE EXCEPTION 'bad reference' USING ERRCODE = '22023'; END IF;
  IF p_method IS NOT NULL AND p_method NOT IN ('cash', 'check', 'card', 'bank_transfer', 'other') THEN
    RAISE EXCEPTION 'method must be cash, check, card, bank_transfer or other' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO d FROM public.exos_donations WHERE id = p_id AND org_id = p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'donation not found' USING ERRCODE = 'P0002'; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_donation_ledger WHERE donation_id = d.id AND kind = 'offline_refund' AND key = v_key) THEN
    RETURN jsonb_build_object('fresh', false, 'donation', public._exos_donation_json(d.id));
  END IF;
  IF d.status = 'refunded' THEN RAISE EXCEPTION 'this donation was already refunded' USING ERRCODE = '55000'; END IF;
  v_left := d.total_cents - d.refunded_cents;
  v_amt := coalesce(p_amount_cents, v_left);
  IF v_amt <= 0 OR v_amt > v_left THEN
    RAISE EXCEPTION 'amount_cents must be between 1 and % (what is left of this donation)', v_left USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_donation_ledger (org_id, donation_id, campaign_id, kind, amount_cents, method, key, note, actor)
  VALUES (d.org_id, d.id, d.campaign_id, 'offline_refund', -v_amt, coalesce(p_method, 'other'), v_key, left(p_note, 1000), p_actor);
  UPDATE public.exos_donations SET refunded_cents = refunded_cents + v_amt,
         status = CASE WHEN refunded_cents + v_amt >= total_cents THEN 'refunded' ELSE status END,
         refunded_at = CASE WHEN refunded_cents + v_amt >= total_cents THEN now() ELSE refunded_at END
   WHERE id = d.id;
  BEGIN
    PERFORM public.exos_enqueue_webhook(d.org_id, 'donation.refunded', jsonb_build_object(
      'donation_id', d.id, 'campaign_id', d.campaign_id, 'amount_cents', v_amt, 'currency', d.currency, 'offline', true));
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN jsonb_build_object('fresh', true, 'donation', public._exos_donation_json(d.id));
END $$;

CREATE OR REPLACE FUNCTION public.exos_api_donation_op(p_org_id uuid, p_op text, p_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE b jsonb := coalesce(p_body, '{}'::jsonb);
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  IF p_op = 'delete' THEN RETURN public._exos_donation_delete(p_org_id, NULL, p_id); END IF;
  IF p_op = 'offline_refund' THEN
    RETURN public._exos_donation_offline_refund(p_org_id, NULL, p_id, (b->>'amount_cents')::int, b->>'reference',
      b->>'method', b->>'note');
  END IF;
  RAISE EXCEPTION 'bad operation' USING ERRCODE = '22023';
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RAISE EXCEPTION 'amount_cents must be whole cents' USING ERRCODE = '22023';
END $$;

-- Dashboard: delete owner / manager; offline refund owner / manager / finance
-- (who records offline gifts).
CREATE OR REPLACE FUNCTION public.exos_donation_delete(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_donations WHERE id = p_id;
  IF auth.uid() IS NULL OR v_org IS NULL OR NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_donation_delete(v_org, auth.uid(), p_id);
END $$;

CREATE OR REPLACE FUNCTION public.exos_donation_offline_refund(p_id uuid, p_amount_cents integer DEFAULT NULL,
  p_reference text DEFAULT NULL, p_method text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_donations WHERE id = p_id;
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_donation_offline_refund(v_org, auth.uid(), p_id, p_amount_cents, p_reference, p_method, p_note);
END $$;

-- Raised totals net of offline refunds (same columns as 20261030130000).
CREATE OR REPLACE VIEW public.exos_public_giving_campaigns WITH (security_barrier = true) AS
  SELECT c.id, c.org_id, o.slug AS org_slug, o.name AS org_name, c.name, c.slug, c.description, c.image_url,
         c.currency, c.goal_cents, c.starts_at, c.ends_at, c.suggested_cents, c.cover_fees, c.cover_fees_bps,
         c.checkout_add_on, c.round_up,
         (c.starts_at IS NULL OR c.starts_at <= now()) AND (c.ends_at IS NULL OR c.ends_at > now()) AS open,
         coalesce(d.raised, 0)::bigint AS raised_cents, coalesce(d.n, 0)::int AS donation_count
    FROM public.exos_giving_campaigns c
    JOIN public.exos_orgs o ON o.id = c.org_id
    LEFT JOIN LATERAL (SELECT sum(greatest(x.amount_cents - x.refunded_cents, 0)) AS raised, count(*) AS n
                         FROM public.exos_donations x
                        WHERE x.campaign_id = c.id AND x.status = 'received') d ON true
   WHERE c.active;
REVOKE ALL ON public.exos_public_giving_campaigns FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_giving_campaigns TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Recurring (monthly) donations: a Stripe subscription per donor
-- ---------------------------------------------------------------------------
-- exos-commerce (donate_monthly) or exos-api (POST /v1/giving-campaigns/:id/
-- recurring-donations) inserts the plan as 'pending', then opens a Stripe
-- Checkout session in subscription mode whose subscription metadata carries
-- exos_recurring_id. stripe-webhook: checkout.session.completed attaches the
-- subscription (exos_commerce_fulfill); every invoice.paid records one
-- donation (key 'inv:<invoice id>', so a replay or the first invoice landing
-- before the session event is still one row); invoice.payment_failed marks
-- the plan past_due; customer.subscription.deleted cancels it.
CREATE TABLE IF NOT EXISTS public.exos_recurring_donation_events (
  id           bigserial PRIMARY KEY,
  recurring_id uuid NOT NULL REFERENCES public.exos_recurring_donations (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('paid', 'failed', 'cancelled')),
  key          text NOT NULL CHECK (length(key) BETWEEN 1 AND 255),   -- invoice id (paid) / Stripe event id
  invoice_id   text,
  amount_cents integer,
  donation_id  uuid,
  note         text CHECK (note IS NULL OR length(note) <= 500),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (recurring_id, kind, key)
);

ALTER TABLE public.exos_recurring_donations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_recurring_donation_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_recurring_donations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.exos_recurring_donation_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.exos_recurring_donation_events_id_seq FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_recurring_donations TO authenticated;
DROP POLICY IF EXISTS exos_recurring_donations_sel ON public.exos_recurring_donations;
CREATE POLICY exos_recurring_donations_sel ON public.exos_recurring_donations FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()
         OR donor_uid = auth.uid());

CREATE OR REPLACE FUNCTION public._exos_recurring_donation_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', r.id, 'campaign_id', r.campaign_id, 'amount_cents', r.amount_cents,
    'cover_fees_cents', r.cover_fees_cents, 'currency', r.currency, 'interval', r.interval, 'status', r.status,
    'donor_name', r.donor_name, 'donor_email', r.donor_email, 'anonymous', r.anonymous, 'source', r.source,
    'current_period_end', r.current_period_end, 'last_paid_at', r.last_paid_at, 'failed_payments', r.failed_payments,
    'cancel_requested_at', r.cancel_requested_at, 'cancelled_at', r.cancelled_at, 'created_at', r.created_at,
    'donations_count', (SELECT count(*) FROM public.exos_donations d WHERE d.recurring_id = r.id)::int,
    'donated_cents', coalesce((SELECT sum(greatest(d.amount_cents - d.refunded_cents, 0)) FROM public.exos_donations d
                                WHERE d.recurring_id = r.id AND d.status = 'received'), 0)::bigint)
  FROM public.exos_recurring_donations r WHERE r.id = p_id
$$;

-- exos_commerce_fulfill's branch (checkout.session.completed): the plan gets
-- its subscription. Returns the plan id (the order's result_id).
CREATE OR REPLACE FUNCTION public._exos_recurring_donation_activate(o public.exos_commerce_orders, p_subscription_id text,
  p_period_end timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_recurring_donations%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_recurring_donations
   WHERE id = (o.details->>'recurring_id')::uuid AND org_id = o.org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'recurring donation not found' USING ERRCODE = 'P0002'; END IF;
  IF p_subscription_id IS NULL THEN RAISE EXCEPTION 'no subscription on a monthly gift' USING ERRCODE = '22023'; END IF;
  IF r.stripe_subscription_id IS NOT NULL AND r.stripe_subscription_id <> p_subscription_id THEN
    RAISE EXCEPTION 'this monthly gift has another subscription' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_recurring_donations SET stripe_subscription_id = p_subscription_id,
         stripe_customer_id = coalesce(stripe_customer_id, o.stripe_customer_id), session_id = coalesce(session_id, o.session_id),
         status = CASE WHEN status = 'pending' THEN 'active' ELSE status END,
         current_period_end = greatest(current_period_end, p_period_end)
   WHERE id = r.id;
  RETURN r.id;
END $$;

-- Service role (stripe-webhook): invoice.paid ('paid') or
-- invoice.payment_failed ('failed'). The plan by p_recurring_id (subscription
-- metadata) or by its subscription. Returns 'recorded', 'duplicate',
-- 'failed_recorded', 'skipped' or 'unknown' (not one of ours: ignored).
CREATE OR REPLACE FUNCTION public.exos_recurring_donation_invoice(p_recurring_id uuid, p_subscription_id text,
  p_customer_id text, p_invoice_id text, p_payment_intent text, p_amount_cents integer, p_currency text,
  p_period_end timestamptz, p_event text, p_event_key text DEFAULT NULL, p_failure text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_recurring_donations%ROWTYPE; v_amt int; v_cover int; v_don uuid; v_n int;
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  IF p_event NOT IN ('paid', 'failed') THEN RAISE EXCEPTION 'bad event' USING ERRCODE = '22023'; END IF;
  IF p_invoice_id IS NULL OR p_invoice_id !~ '^in_[A-Za-z0-9_]{1,250}$' THEN RAISE EXCEPTION 'bad invoice id' USING ERRCODE = '22023'; END IF;
  IF p_recurring_id IS NOT NULL THEN
    SELECT * INTO r FROM public.exos_recurring_donations WHERE id = p_recurring_id FOR UPDATE;
  END IF;
  IF r.id IS NULL AND p_subscription_id IS NOT NULL THEN
    SELECT * INTO r FROM public.exos_recurring_donations WHERE stripe_subscription_id = p_subscription_id FOR UPDATE;
  END IF;
  IF r.id IS NULL THEN RETURN 'unknown'; END IF;
  IF p_subscription_id IS NOT NULL AND r.stripe_subscription_id IS NOT NULL AND r.stripe_subscription_id <> p_subscription_id THEN
    RETURN 'unknown';
  END IF;
  IF r.stripe_subscription_id IS NULL AND p_subscription_id ~ '^sub_[A-Za-z0-9]{1,250}$' THEN
    UPDATE public.exos_recurring_donations SET stripe_subscription_id = p_subscription_id,
           stripe_customer_id = coalesce(stripe_customer_id, CASE WHEN p_customer_id ~ '^cus_[A-Za-z0-9]{1,250}$' THEN p_customer_id END)
     WHERE id = r.id;
  END IF;

  IF p_event = 'failed' THEN
    INSERT INTO public.exos_recurring_donation_events (recurring_id, org_id, kind, key, invoice_id, amount_cents, note)
    VALUES (r.id, r.org_id, 'failed', coalesce(p_event_key, p_invoice_id), p_invoice_id, p_amount_cents, left(p_failure, 500))
    ON CONFLICT (recurring_id, kind, key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RETURN 'duplicate'; END IF;
    UPDATE public.exos_recurring_donations SET failed_payments = failed_payments + 1, last_failure = left(p_failure, 500),
           status = CASE WHEN status IN ('pending', 'active') THEN 'past_due' ELSE status END
     WHERE id = r.id;
    RETURN 'failed_recorded';
  END IF;

  IF coalesce(p_amount_cents, 0) <= 0 THEN RETURN 'skipped'; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_recurring_donation_events WHERE recurring_id = r.id AND kind = 'paid' AND key = p_invoice_id) THEN
    RETURN 'duplicate';
  END IF;
  -- The plan's split when Stripe charged exactly its total; otherwise the whole
  -- charge is the gift (a price change made in Stripe).
  IF p_amount_cents = r.amount_cents + r.cover_fees_cents THEN
    v_amt := r.amount_cents; v_cover := r.cover_fees_cents;
  ELSE
    v_amt := p_amount_cents; v_cover := 0;
  END IF;
  v_don := public._exos_donation_record(r.campaign_id, v_amt, v_cover, 'card', r.donor_uid, r.donor_email, r.donor_name,
    r.anonymous, r.note, NULL, NULL, 'inv:' || p_invoice_id, NULL, coalesce(p_currency, r.currency));
  UPDATE public.exos_donations SET recurring_id = r.id, stripe_invoice_id = p_invoice_id,
         payment_intent = CASE WHEN p_payment_intent ~ '^pi_[A-Za-z0-9_]{1,250}$' THEN p_payment_intent END
   WHERE id = v_don;
  INSERT INTO public.exos_recurring_donation_events (recurring_id, org_id, kind, key, invoice_id, amount_cents, donation_id)
  VALUES (r.id, r.org_id, 'paid', p_invoice_id, p_invoice_id, p_amount_cents, v_don);
  -- A late invoice of a cancelled plan is still a gift received; it never revives the plan.
  UPDATE public.exos_recurring_donations SET last_paid_at = now(), failed_payments = 0, last_failure = NULL,
         status = CASE WHEN status IN ('pending', 'past_due', 'active') THEN 'active' ELSE status END,
         current_period_end = CASE WHEN p_period_end IS NOT NULL THEN greatest(current_period_end, p_period_end) ELSE current_period_end END
   WHERE id = r.id;
  RETURN 'recorded';
END $$;

-- Service role (stripe-webhook): customer.subscription.updated / .deleted.
-- Returns the plan's status, NULL when the subscription isn't a monthly gift.
CREATE OR REPLACE FUNCTION public.exos_recurring_donation_sync(p_subscription_id text, p_event text, p_status text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_recurring_donations%ROWTYPE; v_new text;
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  SELECT * INTO r FROM public.exos_recurring_donations WHERE stripe_subscription_id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF r.status IN ('cancelled', 'ended') THEN RETURN r.status; END IF;
  v_new := CASE
    WHEN p_event = 'deleted' OR p_status = 'canceled' THEN 'cancelled'
    WHEN p_status = 'incomplete_expired' THEN 'ended'
    WHEN p_status IN ('past_due', 'unpaid') THEN 'past_due'
    WHEN p_status IN ('active', 'trialing') AND r.status = 'pending' THEN 'active'
    ELSE r.status END;
  UPDATE public.exos_recurring_donations SET status = v_new,
         cancelled_at = CASE WHEN v_new IN ('cancelled', 'ended') THEN coalesce(cancelled_at, now()) ELSE cancelled_at END
   WHERE id = r.id;
  IF v_new = 'cancelled' THEN
    INSERT INTO public.exos_recurring_donation_events (recurring_id, org_id, kind, key)
    VALUES (r.id, r.org_id, 'cancelled', 'cancelled') ON CONFLICT DO NOTHING;
  END IF;
  RETURN v_new;
END $$;

-- Service role: a cancel was asked for (donor, staff or the API). Returns the
-- subscription to cancel in Stripe (NULL: nothing to cancel there, the plan
-- just ends). Idempotent.
CREATE OR REPLACE FUNCTION public.exos_recurring_donation_cancel(p_org_id uuid, p_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_recurring_donations%ROWTYPE;
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  SELECT * INTO r FROM public.exos_recurring_donations WHERE id = p_id AND (p_org_id IS NULL OR org_id = p_org_id) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'recurring donation not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status NOT IN ('cancelled', 'ended') THEN
    UPDATE public.exos_recurring_donations SET cancel_requested_at = coalesce(cancel_requested_at, now()),
           status = CASE WHEN stripe_subscription_id IS NULL THEN 'cancelled' ELSE status END,
           cancelled_at = CASE WHEN stripe_subscription_id IS NULL THEN now() ELSE cancelled_at END
     WHERE id = r.id;
  END IF;
  RETURN jsonb_build_object('subscription_id', CASE WHEN r.status NOT IN ('cancelled', 'ended') THEN r.stripe_subscription_id END,
    'recurring_donation', public._exos_recurring_donation_json(r.id));
END $$;

-- Service role: Stripe confirmed the cancel (the webhook's .deleted lands too;
-- either one is enough).
CREATE OR REPLACE FUNCTION public.exos_recurring_donation_cancelled(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_recurring_donations%ROWTYPE;
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  SELECT * INTO r FROM public.exos_recurring_donations WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'recurring donation not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status NOT IN ('cancelled', 'ended') THEN
    UPDATE public.exos_recurring_donations SET status = 'cancelled', cancelled_at = now() WHERE id = r.id;
    INSERT INTO public.exos_recurring_donation_events (recurring_id, org_id, kind, key)
    VALUES (r.id, r.org_id, 'cancelled', 'cancelled') ON CONFLICT DO NOTHING;
  END IF;
  RETURN public._exos_recurring_donation_json(r.id);
END $$;

-- Authenticated (exos-commerce asks with the caller's JWT): may this person
-- cancel the monthly gift? The donor, or the org's owner / manager / finance.
CREATE OR REPLACE FUNCTION public.exos_recurring_donation_can_cancel(p_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.exos_recurring_donations r
     WHERE r.id = p_id AND (r.donor_uid = auth.uid()
           OR public.exos_has_org_role(r.org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()))
$$;

-- Authenticated (exos-commerce, staff completing a campaign): owner / manager.
CREATE OR REPLACE FUNCTION public.exos_giving_campaign_can_edit(p_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.exos_giving_campaigns c
     WHERE c.id = p_id AND (public.exos_has_org_role(c.org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()))
$$;

-- Internal: a Stripe refund of one monthly charge (full) marks its donation refunded.
CREATE OR REPLACE FUNCTION public._exos_recurring_donation_refund_pi(p_payment_intent text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE public.exos_donations SET status = 'refunded', refunded_at = now()
   WHERE payment_intent = p_payment_intent AND recurring_id IS NOT NULL AND status = 'received';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Service role (stripe-webhook, a refund whose PaymentIntent isn't a ticket
-- order or a commerce order: a later monthly charge).
CREATE OR REPLACE FUNCTION public.exos_recurring_donation_refund(p_payment_intent text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_recurring_donation_refund_pi(p_payment_intent);
END $$;

-- Commerce: the recurring branch of fulfil and refund.
SELECT pg_temp.exos_patch_n('public.exos_commerce_fulfill(text, text, integer, text, timestamptz)', '/* exos: recurring donation */',
  $o$      ELSE
        v_res := public._exos_commerce_fulfill_ext(o, p_subscription_id, p_period_end);$o$,
  $n$      ELSIF o.kind = 'recurring_donation' THEN /* exos: recurring donation */
        v_id := public._exos_recurring_donation_activate(o, p_subscription_id, p_period_end);
      ELSE
        v_res := public._exos_commerce_fulfill_ext(o, p_subscription_id, p_period_end);$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_commerce_refund(text, text)', '/* exos: recurring donation */',
  $o$    ELSE
      PERFORM public._exos_commerce_refund_ext(o, p_reason);$o$,
  $n$    ELSIF o.kind = 'recurring_donation' THEN /* exos: recurring donation */
      PERFORM public._exos_recurring_donation_refund_pi(o.payment_intent);
      UPDATE public.exos_recurring_donations SET cancel_requested_at = coalesce(cancel_requested_at, now()) WHERE id = o.result_id;
    ELSE
      PERFORM public._exos_commerce_refund_ext(o, p_reason);$n$, 1);

-- ---------------------------------------------------------------------------
-- 4. External gift cards: bulk import, and finding an imported code
-- ---------------------------------------------------------------------------
-- An imported code keeps its own characters: upper case, no spaces or dashes,
-- 6-64 of A-Z / 0-9. NULL otherwise.
CREATE OR REPLACE FUNCTION public._exos_gift_card_ext_normalize(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN x ~ '^[A-Z0-9]{6,64}$' THEN x END
    FROM (SELECT upper(regexp_replace(coalesce(p_code, ''), '[\s-]', '', 'g')) AS x) s;
$$;
CREATE OR REPLACE FUNCTION public._exos_gift_card_ext_hash(p_norm text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT encode(sha256(convert_to('exos-gift-card-ext:' || p_norm, 'UTF8')), 'hex');
$$;
REVOKE ALL ON FUNCTION public._exos_gift_card_ext_normalize(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_gift_card_ext_hash(text) FROM PUBLIC, anon, authenticated;

-- Same contract as 20261030130000 (never raises; rate limit first), plus: a
-- code that isn't an Exos code (or no Exos card has it) is looked up among the
-- imported cards, within p_org_id when given. One code in two organizations'
-- imports is ambiguous without an organizer, so it asks for their checkout.
CREATE OR REPLACE FUNCTION public._exos_gift_card_find(p_code text, p_bucket text, p_org_id uuid, p_currency text,
  p_lock boolean, OUT card public.exos_gift_cards, OUT err text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_gift_cards%ROWTYPE; v_exos boolean; v_ext text; v_hash text; v_n int;
BEGIN
  IF NOT public.exos_rate_hit('gc:' || left(coalesce(p_bucket, 'none'), 100), 10) THEN
    err := 'too many gift card attempts, try again in a minute'; RETURN;
  END IF;
  v_exos := public.exos_gift_card_check_ok(p_code);
  v_ext := public._exos_gift_card_ext_normalize(p_code);
  IF NOT v_exos AND v_ext IS NULL THEN
    err := 'that gift card code isn''t valid (check for a typo)'; RETURN;
  END IF;
  IF v_exos THEN
    IF p_lock THEN
      SELECT * INTO c FROM public.exos_gift_cards WHERE code_hash = public._exos_gift_card_hash(p_code) FOR UPDATE;
    ELSE
      SELECT * INTO c FROM public.exos_gift_cards WHERE code_hash = public._exos_gift_card_hash(p_code);
    END IF;
  END IF;
  IF c.id IS NULL AND v_ext IS NOT NULL THEN
    v_hash := public._exos_gift_card_ext_hash(v_ext);
    SELECT count(*) INTO v_n FROM public.exos_gift_cards
     WHERE external_code_hash = v_hash AND (p_org_id IS NULL OR org_id = p_org_id);
    IF v_n > 1 THEN
      err := 'enter this gift card at the organizer''s checkout'; RETURN;
    END IF;
    IF v_n = 1 THEN
      IF p_lock THEN
        SELECT * INTO c FROM public.exos_gift_cards
         WHERE external_code_hash = v_hash AND (p_org_id IS NULL OR org_id = p_org_id) FOR UPDATE;
      ELSE
        SELECT * INTO c FROM public.exos_gift_cards
         WHERE external_code_hash = v_hash AND (p_org_id IS NULL OR org_id = p_org_id);
      END IF;
    END IF;
  END IF;
  IF c.id IS NULL THEN
    -- Shaped like an Exos code but its check character is off: a typo (as before).
    err := CASE WHEN NOT v_exos AND public.exos_gift_card_normalize(p_code) IS NOT NULL
                THEN 'that gift card code isn''t valid (check for a typo)' ELSE 'gift card not found' END;
    RETURN;
  END IF;
  IF p_org_id IS NOT NULL AND c.org_id <> p_org_id THEN err := 'this gift card is for another organizer'; RETURN; END IF;
  IF p_currency IS NOT NULL AND c.currency <> lower(p_currency) THEN err := 'this gift card is in ' || upper(c.currency); RETURN; END IF;
  IF c.status <> 'active' THEN err := 'this gift card was voided'; RETURN; END IF;
  IF c.expires_at IS NOT NULL AND c.expires_at < now() THEN err := 'this gift card expired'; RETURN; END IF;
  IF c.balance_cents <= 0 THEN err := 'this gift card has no balance left'; card := c; RETURN; END IF;
  card := c;
END $$;
REVOKE ALL ON FUNCTION public._exos_gift_card_find(text, text, uuid, text, boolean) FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.exos_gift_card_imports (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  source          text NOT NULL CHECK (source ~ '^[a-z0-9_]{2,40}$'),
  key             text NOT NULL CHECK (key ~ '^[A-Za-z0-9_:.-]{1,200}$'),
  row_count       integer NOT NULL,
  created_count   integer NOT NULL,
  duplicate_count integer NOT NULL,
  error_count     integer NOT NULL,
  imported_cents  bigint NOT NULL,
  results         jsonb NOT NULL,
  actor           uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, key)
);
ALTER TABLE public.exos_gift_card_imports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_gift_card_imports FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_gift_card_imports TO authenticated;
DROP POLICY IF EXISTS exos_gift_card_imports_sel ON public.exos_gift_card_imports;
CREATE POLICY exos_gift_card_imports_sel ON public.exos_gift_card_imports FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin());

-- Import up to 500 cards from another provider. Each card: code, balance_cents,
-- and optionally initial_cents (>= balance), currency (default usd),
-- expires_at, recipient_email, recipient_name. A card already imported from
-- the same source (same org, same code) is a 'duplicate' and is left alone;
-- p_key makes a resent batch answer the first result. Imported cards are
-- source 'import' / payment method 'external': they never paid the Exos fee,
-- so spending one owes it on its part like a box-office card (#70).
CREATE OR REPLACE FUNCTION public._exos_gift_card_import(p_org_id uuid, p_actor uuid, p_source text, p_cards jsonb, p_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_src text := lower(btrim(coalesce(p_source, ''))); v_key text; prev public.exos_gift_card_imports%ROWTYPE;
        x jsonb; i int := 0; v_code text; v_hash text; v_bal int; v_init int; v_cur text; v_exp timestamptz;
        v_id uuid; v_rows jsonb := '[]'::jsonb; v_new int := 0; v_dup int := 0; v_bad int := 0; v_cents bigint := 0;
        v_res jsonb; v_email text;
BEGIN
  IF v_src !~ '^[a-z0-9_]{2,40}$' THEN
    RAISE EXCEPTION 'source must be 2-40 of a-z, 0-9 and _ (e.g. gift_up)' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_cards) IS DISTINCT FROM 'array' OR jsonb_array_length(p_cards) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'cards must list 1-500 gift cards' USING ERRCODE = '22023';
  END IF;
  -- One import per org and source at a time (two overlapping batches of the
  -- same file can't both create a card; the unique index backs this up).
  PERFORM pg_advisory_xact_lock(hashtextextended('gc-import:' || p_org_id::text || ':' || v_src, 0));
  v_key := coalesce(nullif(btrim(p_key), ''), 'batch:' || encode(sha256(convert_to(v_src || p_cards::text, 'UTF8')), 'hex'));
  IF v_key !~ '^[A-Za-z0-9_:.-]{1,200}$' THEN RAISE EXCEPTION 'bad idempotency key' USING ERRCODE = '22023'; END IF;
  SELECT * INTO prev FROM public.exos_gift_card_imports WHERE org_id = p_org_id AND key = v_key;
  IF FOUND THEN
    RETURN jsonb_build_object('import_id', prev.id, 'fresh', false, 'source', prev.source, 'row_count', prev.row_count,
      'created', prev.created_count, 'duplicates', prev.duplicate_count, 'errors', prev.error_count,
      'imported_cents', prev.imported_cents, 'rows', prev.results);
  END IF;

  FOR x IN SELECT * FROM jsonb_array_elements(p_cards) LOOP
    i := i + 1;
    v_res := NULL;
    BEGIN
      IF jsonb_typeof(x) <> 'object' THEN RAISE EXCEPTION 'each card must be an object' USING ERRCODE = '22023'; END IF;
      v_code := public._exos_gift_card_ext_normalize(x->>'code');
      IF v_code IS NULL THEN RAISE EXCEPTION 'code must be 6-64 letters and digits' USING ERRCODE = '22023'; END IF;
      BEGIN
        v_bal := (x->>'balance_cents')::int;
        v_init := coalesce((x->>'initial_cents')::int, v_bal);
        v_exp := (x->>'expires_at')::timestamptz;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'balance_cents / initial_cents must be whole cents and expires_at a date' USING ERRCODE = '22023';
      END;
      IF v_bal IS NULL OR v_bal < 1 OR v_bal > 100000000 THEN
        RAISE EXCEPTION 'balance_cents must be 1 to 100000000' USING ERRCODE = '22023';
      END IF;
      IF v_init < v_bal OR v_init > 100000000 THEN RAISE EXCEPTION 'initial_cents must be at least balance_cents' USING ERRCODE = '22023'; END IF;
      IF v_exp IS NOT NULL AND v_exp <= now() THEN RAISE EXCEPTION 'this card already expired' USING ERRCODE = '22023'; END IF;
      v_cur := lower(coalesce(nullif(btrim(x->>'currency'), ''), 'usd'));
      IF v_cur !~ '^[a-z]{3}$' THEN RAISE EXCEPTION 'bad currency' USING ERRCODE = '22023'; END IF;
      v_email := lower(nullif(btrim(x->>'recipient_email'), ''));
      IF v_email IS NOT NULL AND (length(v_email) > 320 OR v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$') THEN
        RAISE EXCEPTION 'recipient_email isn''t valid' USING ERRCODE = '22023';
      END IF;
      v_hash := public._exos_gift_card_ext_hash(v_code);
      SELECT id INTO v_id FROM public.exos_gift_cards
       WHERE org_id = p_org_id AND external_code_hash = v_hash AND external_source = v_src;
      IF v_id IS NOT NULL THEN
        v_dup := v_dup + 1;
        v_res := jsonb_build_object('row', i, 'status', 'duplicate', 'card_id', v_id, 'last4', right(v_code, 4));
      ELSIF EXISTS (SELECT 1 FROM public.exos_gift_cards WHERE org_id = p_org_id AND external_code_hash = v_hash) THEN
        RAISE EXCEPTION 'this code was already imported from another source' USING ERRCODE = '23505';
      ELSE
        INSERT INTO public.exos_gift_cards (org_id, code_hash, last4, currency, initial_cents, balance_cents, source,
          payment_method, recipient_email, recipient_name, issued_by, expires_at, external_source, external_code_hash)
        VALUES (p_org_id, encode(sha256(convert_to('exos-gift-card-import:' || p_org_id || ':' || v_src || ':' || v_code, 'UTF8')), 'hex'),
          right(v_code, 4), v_cur, v_init, 0, 'import', 'external', v_email,
          nullif(left(btrim(x->>'recipient_name'), 120), ''), p_actor, v_exp, v_src, v_hash)
        ON CONFLICT (org_id, external_source, external_code_hash) WHERE external_code_hash IS NOT NULL DO NOTHING
        RETURNING id INTO v_id;
        IF v_id IS NULL THEN
          v_dup := v_dup + 1;
          v_res := jsonb_build_object('row', i, 'status', 'duplicate', 'last4', right(v_code, 4));
        ELSE
          PERFORM public._exos_gift_card_move(v_id, 'issue', v_bal, 'issue', NULL, p_actor,
            left('imported from ' || v_src || CASE WHEN v_init > v_bal THEN ' (original value ' || v_init || ')' ELSE '' END, 500));
          v_new := v_new + 1; v_cents := v_cents + v_bal;
          v_res := jsonb_build_object('row', i, 'status', 'created', 'card_id', v_id, 'last4', right(v_code, 4),
            'balance_cents', v_bal, 'currency', v_cur);
        END IF;
      END IF;
    EXCEPTION WHEN others THEN
      v_bad := v_bad + 1;
      v_res := jsonb_build_object('row', i, 'status', 'error', 'error', left(SQLERRM, 200));
    END;
    v_rows := v_rows || v_res;
  END LOOP;

  INSERT INTO public.exos_gift_card_imports (org_id, source, key, row_count, created_count, duplicate_count, error_count,
    imported_cents, results, actor)
  VALUES (p_org_id, v_src, v_key, i, v_new, v_dup, v_bad, v_cents, v_rows, p_actor)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('import_id', v_id, 'fresh', true, 'source', v_src, 'row_count', i, 'created', v_new,
    'duplicates', v_dup, 'errors', v_bad, 'imported_cents', v_cents, 'rows', v_rows);
END $$;

CREATE OR REPLACE FUNCTION public.exos_api_gift_card_import(p_org_id uuid, p_source text, p_cards jsonb, p_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT public._exos_caller_is_service() THEN RAISE EXCEPTION 'service role only' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_gift_card_import(p_org_id, NULL, p_source, p_cards, p_key);
END $$;

-- Dashboard: owner / manager (stored value is money; door staff never import).
CREATE OR REPLACE FUNCTION public.exos_gift_card_import(p_org_id uuid, p_source text, p_cards jsonb, p_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_gift_card_import(p_org_id, auth.uid(), p_source, p_cards, p_key);
END $$;

-- ---------------------------------------------------------------------------
-- 5. Gift cards on organizer / partner reservations
-- ---------------------------------------------------------------------------
-- A redemption is an exos_gift_card_redemptions row (session_id 'gcr_…',
-- partner_reservation_id set) held while the reservation is active: the
-- balance moves at once (ledger 'redeem'). Completing the reservation captures
-- it; cancelling or expiring it gives it back (ledger 'release', the trigger
-- below). The card row is locked for every change (_exos_gift_card_find with
-- p_lock, _exos_gift_card_move), so two reservations can't overdraw one card.
-- Lock order everywhere: reservation, redemption, card.
CREATE OR REPLACE FUNCTION public._exos_reservation_gift_cards_json(p_res_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'total_cents', r.total_cents,
    'gift_card_cents', coalesce((SELECT sum(g.amount_cents - g.refunded_cents) FROM public.exos_gift_card_redemptions g
                                  WHERE g.partner_reservation_id = r.id AND g.status IN ('held', 'captured')), 0)::int,
    'amount_due_cents', greatest(r.total_cents - coalesce((SELECT sum(g.amount_cents - g.refunded_cents) FROM public.exos_gift_card_redemptions g
                                  WHERE g.partner_reservation_id = r.id AND g.status IN ('held', 'captured')), 0), 0)::int,
    'redemptions', coalesce((SELECT jsonb_agg(jsonb_build_object('id', g.session_id, 'last4', c.last4,
        'amount_cents', g.amount_cents, 'status', g.status, 'fee_paid_at_sale', g.fee_paid_at_sale,
        'created_at', g.created_at) ORDER BY g.created_at, g.session_id)
       FROM public.exos_gift_card_redemptions g JOIN public.exos_gift_cards c ON c.id = g.card_id
      WHERE g.partner_reservation_id = r.id), '[]'::jsonb))
  FROM public.exos_partner_reservations r WHERE r.id = p_res_id
$$;

-- Service role (exos-api). Never raises for a card problem (wrong code, no
-- balance...): answers { error }, so a guess still counts against the rate
-- limit (10 a minute per bucket). p_key (Idempotency-Key) makes a resend the
-- same redemption. Amount: p_amount_cents, at most what's due and the balance.
CREATE OR REPLACE FUNCTION public._exos_reservation_gift_card_apply(p_org_id uuid, p_partner_id uuid, p_token text,
  p_code text, p_amount_cents integer, p_bucket text, p_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_partner_reservations%ROWTYPE; f record; c public.exos_gift_cards%ROWTYPE; v_sid text; v_due int; v_amt int;
BEGIN
  IF p_key IS NOT NULL AND p_key !~ '^[A-Za-z0-9_:.-]{1,200}$' THEN RAISE EXCEPTION 'bad idempotency key' USING ERRCODE = '22023'; END IF;
  IF p_amount_cents IS NOT NULL AND p_amount_cents <= 0 THEN RAISE EXCEPTION 'amount_cents must be positive' USING ERRCODE = '22023'; END IF;
  r := public._exos_partner_res_lock(p_org_id, p_partner_id, p_token);
  IF p_key IS NOT NULL THEN
    v_sid := 'gcr_' || substr(encode(sha256(convert_to(r.id::text || ':' || p_key, 'UTF8')), 'hex'), 1, 40);
    IF EXISTS (SELECT 1 FROM public.exos_gift_card_redemptions WHERE session_id = v_sid AND partner_reservation_id = r.id) THEN
      RETURN jsonb_build_object('fresh', false, 'redemption_id', v_sid) || public._exos_reservation_gift_cards_json(r.id);
    END IF;
  ELSE
    v_sid := 'gcr_' || replace(gen_random_uuid()::text, '-', '');
  END IF;
  PERFORM public._exos_partner_res_expire(r.id);
  SELECT * INTO r FROM public.exos_partner_reservations WHERE id = r.id;
  IF r.status <> 'active' THEN
    RAISE EXCEPTION 'this reservation is %; a gift card can only go on an active one', r.status USING ERRCODE = '55000';
  END IF;
  v_due := (public._exos_reservation_gift_cards_json(r.id)->>'amount_due_cents')::int;
  IF v_due <= 0 THEN RAISE EXCEPTION 'gift cards already cover this reservation' USING ERRCODE = '55000'; END IF;

  f := public._exos_gift_card_find(p_code, p_bucket, r.org_id, r.currency, true);
  IF (f.card).id IS NULL OR f.err IS NOT NULL THEN
    RETURN jsonb_build_object('error', coalesce(f.err, 'gift card not found'));
  END IF;
  c := f.card;
  IF EXISTS (SELECT 1 FROM public.exos_gift_card_redemptions WHERE partner_reservation_id = r.id AND card_id = c.id
              AND status IN ('held', 'captured')) THEN
    RETURN jsonb_build_object('error', 'this gift card is already on this reservation');
  END IF;
  v_amt := least(c.balance_cents, v_due, coalesce(p_amount_cents, v_due));
  INSERT INTO public.exos_gift_card_redemptions (session_id, card_id, org_id, amount_cents, partner_reservation_id, fee_paid_at_sale)
  VALUES (v_sid, c.id, c.org_id, v_amt, r.id, c.source = 'online' AND c.payment_method = 'card');
  PERFORM public._exos_gift_card_move(c.id, 'redeem', -v_amt, v_sid, v_sid, NULL, 'held for reservation');
  RETURN jsonb_build_object('fresh', true, 'redemption_id', v_sid, 'last4', c.last4, 'amount_cents', v_amt,
    'card_balance_cents', c.balance_cents - v_amt) || public._exos_reservation_gift_cards_json(r.id);
END $$;

-- Service role (exos-api): take a gift card off an active reservation (the
-- balance comes back now). Removing one already released is a no-op. A
-- completed reservation keeps it (refund the card part instead: 55000).
CREATE OR REPLACE FUNCTION public._exos_reservation_gift_card_remove(p_org_id uuid, p_partner_id uuid, p_token text, p_redemption_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_partner_reservations%ROWTYPE; g public.exos_gift_card_redemptions%ROWTYPE; v_back int;
BEGIN
  r := public._exos_partner_res_lock(p_org_id, p_partner_id, p_token);
  SELECT * INTO g FROM public.exos_gift_card_redemptions WHERE session_id = p_redemption_id AND partner_reservation_id = r.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'gift card redemption not found' USING ERRCODE = 'P0002'; END IF;
  IF g.status = 'captured' OR r.status = 'completed' THEN
    RAISE EXCEPTION 'this reservation was completed: refund the gift card part instead' USING ERRCODE = '55000';
  END IF;
  v_back := public._exos_gift_card_give_back(g.session_id, 'removed from reservation');
  RETURN jsonb_build_object('redemption_id', g.session_id, 'released_cents', v_back, 'status', 'released')
    || public._exos_reservation_gift_cards_json(r.id);
END $$;

-- Service role (exos-api): the reservation's gift cards.
CREATE OR REPLACE FUNCTION public._exos_reservation_gift_cards(p_org_id uuid, p_partner_id uuid, p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.exos_partner_reservations
   WHERE token = p_token AND org_id = p_org_id
     AND ((p_partner_id IS NULL AND channel = 'organizer') OR partner_id = p_partner_id);
  IF v_id IS NULL THEN RAISE EXCEPTION 'reservation not found' USING ERRCODE = 'P0002'; END IF;
  RETURN public._exos_reservation_gift_cards_json(v_id);
END $$;

-- Reservation status -> its gift card parts. Expired / cancelled: every held
-- part goes back to its card. Completed: held parts are spent (captured).
CREATE OR REPLACE FUNCTION public._exos_tg_reservation_gift_cards()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE g record;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NEW.status IN ('expired', 'cancelled') THEN
    FOR g IN SELECT session_id FROM public.exos_gift_card_redemptions
              WHERE partner_reservation_id = NEW.id AND status = 'held' ORDER BY session_id LOOP
      PERFORM public._exos_gift_card_give_back(g.session_id, 'reservation ' || NEW.status);
    END LOOP;
  ELSIF NEW.status = 'completed' THEN
    UPDATE public.exos_gift_card_redemptions SET status = 'captured'
     WHERE partner_reservation_id = NEW.id AND status = 'held';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS exos_partner_reservation_gift_cards ON public.exos_partner_reservations;
CREATE TRIGGER exos_partner_reservation_gift_cards AFTER UPDATE OF status ON public.exos_partner_reservations
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_reservation_gift_cards();

-- ---------------------------------------------------------------------------
-- 6. Grants. Every definer function: revoked from everyone first.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._exos_giving_campaign_json(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_giving_campaign_op(uuid, uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_api_giving_campaign_op(uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_giving_campaign_op(text, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_donation_json(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_donation_delete(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_donation_offline_refund(uuid, uuid, uuid, integer, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_api_donation_op(uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_donation_delete(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_donation_offline_refund(uuid, integer, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_recurring_donation_json(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_recurring_donation_activate(public.exos_commerce_orders, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_recurring_donation_invoice(uuid, text, text, text, text, integer, text, timestamptz, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_recurring_donation_sync(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_recurring_donation_cancel(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_recurring_donation_cancelled(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_recurring_donation_can_cancel(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_giving_campaign_can_edit(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_recurring_donation_refund_pi(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_recurring_donation_refund(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_gift_card_import(uuid, uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_api_gift_card_import(uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_gift_card_import(uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_reservation_gift_cards_json(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_reservation_gift_card_apply(uuid, uuid, text, text, integer, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_reservation_gift_card_remove(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_reservation_gift_cards(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_tg_reservation_gift_cards() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.exos_api_giving_campaign_op(uuid, text, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_api_donation_op(uuid, text, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_recurring_donation_invoice(uuid, text, text, text, text, integer, text, timestamptz, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_recurring_donation_sync(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_recurring_donation_cancel(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_recurring_donation_cancelled(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_recurring_donation_refund(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_api_gift_card_import(uuid, text, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_reservation_gift_card_apply(uuid, uuid, text, text, integer, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_reservation_gift_card_remove(uuid, uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_reservation_gift_cards(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_recurring_donation_json(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_giving_campaign_json(uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.exos_giving_campaign_op(text, uuid, jsonb, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_donation_delete(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_donation_offline_refund(uuid, integer, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_gift_card_import(uuid, text, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_recurring_donation_can_cancel(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_giving_campaign_can_edit(uuid) TO authenticated, service_role;

GRANT ALL ON public.exos_donation_ledger, public.exos_recurring_donations, public.exos_recurring_donation_events,
  public.exos_gift_card_imports TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.exos_donation_ledger_id_seq, public.exos_recurring_donation_events_id_seq TO service_role;
