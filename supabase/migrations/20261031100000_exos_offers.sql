-- ============================================================================
-- Migration 20261031100000 — Exos: offers, deal terms, budgets, offer pools,
-- offer templates and imports, finance categories, general ledger codes, CRM
-- deals. docs/offers-settlements.md.
--
-- Touches:  C: TABLE exos_gl_codes, exos_finance_categories, exos_budgets,
--              exos_budget_lines, exos_offer_pools, exos_offer_templates,
--              exos_offer_imports, exos_offers, exos_crm_deals
--           C: FUNCTION _exos_fin_* helpers, _exos_deal_terms,
--              _exos_fin_seed, _exos_offer_json, _exos_offer_save,
--              _exos_offer_send, _exos_offer_record_response,
--              _exos_offer_cancel, _exos_offer_delete, _exos_offer_import,
--              _exos_offer_pool_ensure (service_role: exos-api passes the key's
--              org), exos_offer_* / exos_finance_categories_ensure /
--              exos_offer_pool_ensure (signed-in staff), exos_offer_public,
--              exos_offer_respond (anon, 64-hex link token), trigger functions
--           W: exos_mail template allowlist (+ offer-sent)
--           R: exos_orgs, exos_org_memberships, exos_events, exos_holds,
--              exos_hold_positions, exos_venues, exos_venue_rooms,
--              exos_artists, exos_webhooks (via exos_enqueue_webhook),
--              exos_mail (via exos_mail_enqueue)
-- Pre-reqs: 20261030100000 (booking), 20261030110000 (artists),
--           20260929071000 (exos_mail_enqueue), 20260616200000 (webhooks)
--
-- Port of the Firebase build's offers (Exos-Bridge server/offers.ts,
-- docs/OFFERS-SETTLEMENTS.md), on Opendate's v3 model:
--
--   * An offer is one act's deal for a show: flat, versus, plus or door, with
--     a guarantee, a percentage, an expenses cap, promoter profit (plus
--     deals), cumulative bonuses, a merch share and a deposit. Terms are a
--     validated jsonb (_exos_deal_terms). Money is integer cents everywhere.
--   * Every offer sits on a budget (exos_budgets: capacity, average price,
--     sell-through, expense and income lines). Several offers can share one
--     budget: that is a lineup (Opendate's shared budget). The deal math
--     (supabase/functions/_shared/finance/dealMath.ts) runs on the budget.
--   * An offer pool (exos_offer_pools, one per budget) in `pool` mode pays the
--     lineup from one shared deal instead of each act's own: the pool's terms
--     make one payout, which is split by each member's pool_share_percent,
--     and members without a share split what is left equally. In
--     `independent` mode the pool changes nothing.
--   * Status: draft -> sent -> accepted | declined; expired (a sent offer past
--     expires_at, written back lazily); cancelled. Editing the terms of a
--     sent offer takes it back to draft and kills its link. Accepted,
--     declined, expired and cancelled offers only take notes and event_id.
--   * Sending emails the agent (exos_mail 'offer-sent') a link with a fresh
--     64-hex token; only its SHA-256 is stored. The agent answers on the
--     link without logging in (exos_offer_public / exos_offer_respond, anon,
--     token-gated): name required, IP and user agent recorded. The venue's
--     own tooling can record an answer too (via 'api' / 'dashboard').
--   * Converting a hold night links every open offer and budget on that hold
--     to the new event (trigger on exos_hold_positions).
--   * Finance categories (seeded per org: Talent, Production, Marketing,
--     Hospitality, Venue rental, Staff, Bar/F&B income, Merch income, Other;
--     the four system ones can be renamed and coded, not deleted or
--     re-kinded) each carry a general ledger code from the org's chart of
--     accounts (exos_gl_codes, soft-deleted).
--   * exos_crm_deals is the org-level equivalent of Opendate's admin deals:
--     a sales or fundraising opportunity with a stage, amount and owner.
--
-- Who: owners, managers and finance read everything here; owners and managers
-- write offers, templates, budgets, pools, imports and deals; owners,
-- managers and finance write finance categories and GL codes. Scanners and
-- content staff see nothing (money figures). Offers are written only by the
-- functions below (no client write grant).
--
-- Errors: 22023 bad input, P0002 not found, 55000 wrong state, 54000 limit,
-- 42501 not allowed. exos-api maps them to 400 / 404 / 409 / 409 / 403.
--
-- Additive only; re-run safe. Prod apply needs operator OK.
-- ROLLBACK: DROP the functions and tables above (offers first).
-- ============================================================================

-- ===========================================================================
-- 0. Small helpers (pure, internal)
-- ===========================================================================

-- A jsonb field as whole cents (>= 0). Missing / null: NULL when p_nullable,
-- else 0.
CREATE OR REPLACE FUNCTION public._exos_fin_cents(p jsonb, p_key text, p_field text, p_nullable boolean DEFAULT false)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb := p -> p_key; t text;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN CASE WHEN p_nullable THEN NULL ELSE 0 END;
  END IF;
  t := CASE jsonb_typeof(v) WHEN 'number' THEN v::text WHEN 'string' THEN btrim(v #>> '{}') END;
  IF t IS NULL OR t !~ '^[0-9]{1,12}$' THEN
    RAISE EXCEPTION '% must be a whole number of cents, 0 or more', p_field USING ERRCODE = '22023';
  END IF;
  RETURN t::bigint;
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_cents(jsonb, text, text, boolean) FROM PUBLIC, anon, authenticated;

-- A jsonb field as a percentage 0..100 with at most 3 decimals.
CREATE OR REPLACE FUNCTION public._exos_fin_pct(p jsonb, p_key text, p_field text, p_nullable boolean DEFAULT false)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb := p -> p_key; t text;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN CASE WHEN p_nullable THEN NULL ELSE 0 END;
  END IF;
  t := CASE jsonb_typeof(v) WHEN 'number' THEN v::text WHEN 'string' THEN btrim(v #>> '{}') END;
  IF t IS NULL OR t !~ '^[0-9]{1,3}(\.[0-9]{1,3})?$' OR t::numeric > 100 THEN
    RAISE EXCEPTION '% must be a percentage from 0 to 100 (at most 3 decimals)', p_field USING ERRCODE = '22023';
  END IF;
  RETURN t::numeric;
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_pct(jsonb, text, text, boolean) FROM PUBLIC, anon, authenticated;

-- A jsonb field as trimmed text of at most p_max characters ('' when missing).
CREATE OR REPLACE FUNCTION public._exos_fin_text(p jsonb, p_key text, p_field text, p_max int)
RETURNS text LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb := p -> p_key; t text;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN RETURN ''; END IF;
  IF jsonb_typeof(v) NOT IN ('string', 'number') THEN
    RAISE EXCEPTION '% must be text', p_field USING ERRCODE = '22023';
  END IF;
  t := btrim(v #>> '{}');
  IF char_length(t) > p_max THEN
    RAISE EXCEPTION '% must be at most % characters', p_field, p_max USING ERRCODE = '22023';
  END IF;
  RETURN t;
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_text(jsonb, text, text, int) FROM PUBLIC, anon, authenticated;

-- A jsonb field as a date (YYYY-MM-DD) or NULL.
CREATE OR REPLACE FUNCTION public._exos_fin_date(p jsonb, p_key text, p_field text)
RETURNS date LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE t text := nullif(btrim(coalesce(p ->> p_key, '')), '');
BEGIN
  IF t IS NULL THEN RETURN NULL; END IF;
  IF t !~ '^\d{4}-\d{2}-\d{2}$' THEN
    RAISE EXCEPTION '% must be a date (YYYY-MM-DD)', p_field USING ERRCODE = '22023';
  END IF;
  BEGIN
    RETURN t::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION '% is not a real date', p_field USING ERRCODE = '22023';
  END;
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_date(jsonb, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_fin_email(p text, p_field text)
RETURNS text LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE t text := lower(btrim(coalesce(p, '')));
BEGIN
  IF t = '' THEN RETURN NULL; END IF;
  IF char_length(t) > 200 OR t !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION '% is not a valid email address', p_field USING ERRCODE = '22023';
  END IF;
  RETURN t;
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_email(text, text) FROM PUBLIC, anon, authenticated;

-- Deal terms, validated and in canonical form (docs/offers-settlements.md):
--   { deal_type: flat | versus | plus | door, guarantee_cents, percentage,
--     expenses_cap_cents | null, promoter_profit_percent,
--     bonuses: [{ sold, amount_cents }] (<= 10, cumulative),
--     merch_artist_percent | null, deposit_cents, deposit_due_on | null,
--     hospitality, rider }
-- Pool terms (p_pool) add payout_cap_cents / payout_floor_cents and drop the
-- per-act fields (bonuses, merch, deposit, hospitality, rider).
CREATE OR REPLACE FUNCTION public._exos_deal_terms(p jsonb, p_pool boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  t   jsonb := CASE WHEN jsonb_typeof(p) = 'object' THEN p ELSE '{}'::jsonb END;
  v_type text := coalesce(nullif(btrim(t ->> 'deal_type'), ''), 'flat');
  v_bonuses jsonb := '[]'::jsonb;
  b jsonb;
  v_out jsonb;
BEGIN
  IF p IS NOT NULL AND jsonb_typeof(p) NOT IN ('object', 'null') THEN
    RAISE EXCEPTION 'terms must be an object' USING ERRCODE = '22023';
  END IF;
  IF v_type NOT IN ('flat', 'versus', 'plus', 'door') THEN
    RAISE EXCEPTION 'deal_type must be one of flat, versus, plus, door' USING ERRCODE = '22023';
  END IF;
  v_out := jsonb_build_object(
    'deal_type', v_type,
    'guarantee_cents', public._exos_fin_cents(t, 'guarantee_cents', 'guarantee_cents'),
    'percentage', public._exos_fin_pct(t, 'percentage', 'percentage'),
    'expenses_cap_cents', public._exos_fin_cents(t, 'expenses_cap_cents', 'expenses_cap_cents', true),
    'promoter_profit_percent', public._exos_fin_pct(t, 'promoter_profit_percent', 'promoter_profit_percent'));
  IF p_pool THEN
    v_out := v_out || jsonb_build_object(
      'payout_cap_cents', public._exos_fin_cents(t, 'payout_cap_cents', 'payout_cap_cents', true),
      'payout_floor_cents', public._exos_fin_cents(t, 'payout_floor_cents', 'payout_floor_cents', true));
    IF (v_out ->> 'payout_cap_cents')::bigint < (v_out ->> 'payout_floor_cents')::bigint THEN
      RAISE EXCEPTION 'payout_cap_cents must be at least payout_floor_cents' USING ERRCODE = '22023';
    END IF;
    RETURN v_out;
  END IF;
  IF t ? 'bonuses' AND jsonb_typeof(t -> 'bonuses') NOT IN ('array', 'null') THEN
    RAISE EXCEPTION 'bonuses must be a list' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(t -> 'bonuses') = 'array' THEN
    IF jsonb_array_length(t -> 'bonuses') > 10 THEN
      RAISE EXCEPTION 'at most 10 bonuses' USING ERRCODE = '54000';
    END IF;
    FOR b IN SELECT * FROM jsonb_array_elements(t -> 'bonuses') LOOP
      IF jsonb_typeof(b) <> 'object' THEN
        RAISE EXCEPTION 'each bonus must be an object' USING ERRCODE = '22023';
      END IF;
      IF coalesce(b ->> 'sold', '') !~ '^[0-9]{1,7}$' OR (b ->> 'sold')::int < 1 THEN
        RAISE EXCEPTION 'bonuses.sold must be a ticket count of 1 or more' USING ERRCODE = '22023';
      END IF;
      v_bonuses := v_bonuses || jsonb_build_array(jsonb_build_object(
        'sold', (b ->> 'sold')::int, 'amount_cents', public._exos_fin_cents(b, 'amount_cents', 'bonuses.amount_cents')));
    END LOOP;
    SELECT coalesce(jsonb_agg(x ORDER BY (x ->> 'sold')::int), '[]'::jsonb) INTO v_bonuses
      FROM jsonb_array_elements(v_bonuses) x;
  END IF;
  RETURN v_out || jsonb_build_object(
    'bonuses', v_bonuses,
    'merch_artist_percent', public._exos_fin_pct(t, 'merch_artist_percent', 'merch_artist_percent', true),
    'deposit_cents', public._exos_fin_cents(t, 'deposit_cents', 'deposit_cents'),
    'deposit_due_on', public._exos_fin_date(t, 'deposit_due_on', 'deposit_due_on'),
    'hospitality', public._exos_fin_text(t, 'hospitality', 'hospitality', 2000),
    'rider', public._exos_fin_text(t, 'rider', 'rider', 2000));
END $$;
REVOKE ALL ON FUNCTION public._exos_deal_terms(jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_deal_terms(jsonb, boolean) TO service_role;

-- Signed-in staff of p_org with one of p_roles (platform admins pass), else
-- 42501. Returns the org.
CREATE OR REPLACE FUNCTION public._exos_fin_staff(p_org uuid, p_roles text[])
RETURNS uuid LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org, p_roles)) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN p_org;
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_staff(uuid, text[]) FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- 1. Chart of accounts and finance categories
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_gl_codes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9.-]{0,23}$'),
  name         text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  kind         text NOT NULL DEFAULT 'expense'
               CHECK (kind IN ('income', 'expense', 'asset', 'liability', 'equity')),
  description  text NOT NULL DEFAULT '' CHECK (char_length(description) <= 500),
  discarded_at timestamptz,
  created_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_gl_codes_code_uq ON public.exos_gl_codes (org_id, lower(code))
  WHERE discarded_at IS NULL;

CREATE TABLE IF NOT EXISTS public.exos_finance_categories (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- Stable key: the system ones the maths reads ('talent', 'venue-rental',
  -- 'merch-income', 'other'), the seeded ones, or NULL for the org's own.
  key        text CHECK (key IS NULL OR key ~ '^[a-z][a-z0-9-]{1,30}$'),
  name       text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  kind       text NOT NULL CHECK (kind IN ('income', 'expense', 'both')),
  system     boolean NOT NULL DEFAULT false,
  gl_code_id uuid REFERENCES public.exos_gl_codes (id) ON DELETE SET NULL,
  position   integer NOT NULL DEFAULT 0 CHECK (position BETWEEN 0 AND 1000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, key),
  UNIQUE (id, org_id)
);
CREATE INDEX IF NOT EXISTS exos_finance_categories_org_idx ON public.exos_finance_categories (org_id, position);

-- The default categories, once per org (idempotent).
CREATE OR REPLACE FUNCTION public._exos_fin_seed(p_org uuid)
RETURNS void LANGUAGE sql
SET search_path = public, pg_temp
AS $$
  INSERT INTO public.exos_finance_categories (org_id, key, name, kind, system, position)
  SELECT p_org, d.key, d.name, d.kind, d.system, d.pos
    FROM (VALUES ('talent', 'Talent', 'expense', true, 10),
                 ('production', 'Production', 'expense', false, 20),
                 ('marketing', 'Marketing', 'expense', false, 30),
                 ('hospitality', 'Hospitality', 'expense', false, 40),
                 ('venue-rental', 'Venue rental', 'expense', true, 50),
                 ('staff', 'Staff', 'expense', false, 60),
                 ('bar-income', 'Bar/F&B income', 'income', false, 70),
                 ('merch-income', 'Merch income', 'income', true, 80),
                 ('other', 'Other', 'both', true, 90)) AS d(key, name, kind, system, pos)
   WHERE EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org)
  ON CONFLICT (org_id, key) DO NOTHING;
$$;
REVOKE ALL ON FUNCTION public._exos_fin_seed(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fin_seed(uuid) TO service_role;

-- The org's category id for a key (seeding first).
CREATE OR REPLACE FUNCTION public._exos_fin_category(p_org uuid, p_key text)
RETURNS uuid LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v uuid;
BEGIN
  SELECT id INTO v FROM public.exos_finance_categories WHERE org_id = p_org AND key = p_key;
  IF v IS NULL THEN
    PERFORM public._exos_fin_seed(p_org);
    SELECT id INTO v FROM public.exos_finance_categories WHERE org_id = p_org AND key = p_key;
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_category(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_finance_categories_ensure(p_org_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'finance']);
  PERFORM public._exos_fin_seed(p_org_id);
  RETURN (SELECT count(*)::int FROM public.exos_finance_categories WHERE org_id = p_org_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_finance_categories_ensure(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_finance_categories_ensure(uuid) TO authenticated;

-- Category rows: trimmed; a system category keeps its key and kind; a GL code
-- must be the org's own, live one; 50 per org; the org can't change.
CREATE OR REPLACE FUNCTION public._exos_tg_finance_category()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.org_id IS DISTINCT FROM OLD.org_id THEN
      RAISE EXCEPTION 'a finance category can''t move to another organization' USING ERRCODE = '22023';
    END IF;
    IF OLD.system AND (NEW.key IS DISTINCT FROM OLD.key OR NEW.kind IS DISTINCT FROM OLD.kind OR NOT NEW.system) THEN
      RAISE EXCEPTION 'a built-in category can be renamed and coded, not re-keyed or re-kinded' USING ERRCODE = '55000';
    END IF;
    IF NOT OLD.system AND NEW.system THEN
      RAISE EXCEPTION 'only the built-in categories are system categories' USING ERRCODE = '22023';
    END IF;
  ELSE
    -- The four built-in keys are always system rows of their own kind (so a
    -- custom row can't take a key the maths reads); no other row is.
    IF NEW.key IN ('talent', 'venue-rental') THEN
      NEW.system := true; NEW.kind := 'expense';
    ELSIF NEW.key = 'merch-income' THEN
      NEW.system := true; NEW.kind := 'income';
    ELSIF NEW.key = 'other' THEN
      NEW.system := true; NEW.kind := 'both';
    ELSIF NEW.system THEN
      RAISE EXCEPTION 'only the built-in categories are system categories' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM public.exos_finance_categories WHERE org_id = NEW.org_id) >= 50 THEN
      RAISE EXCEPTION 'at most 50 finance categories per organization' USING ERRCODE = '54000';
    END IF;
  END IF;
  NEW.name := btrim(NEW.name);
  IF NEW.gl_code_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_gl_codes g
        WHERE g.id = NEW.gl_code_id AND g.org_id = NEW.org_id AND g.discarded_at IS NULL) THEN
    RAISE EXCEPTION 'gl_code_id is not one of this organization''s ledger codes' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_finance_category() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_finance_categories_guard ON public.exos_finance_categories;
CREATE TRIGGER exos_finance_categories_guard BEFORE INSERT OR UPDATE ON public.exos_finance_categories
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_finance_category();

-- GL codes: trimmed, creator stamped, 500 per org, no org moves. Discarding
-- a code unlinks the categories that use it.
CREATE OR REPLACE FUNCTION public._exos_tg_gl_code()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'a ledger code can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    IF (SELECT count(*) FROM public.exos_gl_codes WHERE org_id = NEW.org_id) >= 500 THEN
      RAISE EXCEPTION 'at most 500 ledger codes per organization' USING ERRCODE = '54000';
    END IF;
  END IF;
  NEW.code := btrim(NEW.code);
  NEW.name := btrim(NEW.name);
  IF TG_OP = 'UPDATE' AND NEW.discarded_at IS NOT NULL AND OLD.discarded_at IS NULL THEN
    UPDATE public.exos_finance_categories SET gl_code_id = NULL WHERE gl_code_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_gl_code() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_gl_codes_guard ON public.exos_gl_codes;
CREATE TRIGGER exos_gl_codes_guard BEFORE INSERT OR UPDATE ON public.exos_gl_codes
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_gl_code();

-- ===========================================================================
-- 2. Budgets, budget lines, offer pools
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_budgets (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id               uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name                 text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 150),
  currency             text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  venue_id             uuid REFERENCES public.exos_venues (id) ON DELETE SET NULL,
  hold_id              uuid REFERENCES public.exos_holds (id) ON DELETE SET NULL,
  event_id             uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  capacity             integer NOT NULL DEFAULT 0 CHECK (capacity BETWEEN 0 AND 1000000),
  average_price_cents  bigint NOT NULL DEFAULT 0 CHECK (average_price_cents BETWEEN 0 AND 100000000),
  sell_through_percent numeric(6, 3) NOT NULL DEFAULT 100 CHECK (sell_through_percent BETWEEN 0 AND 100),
  notes                text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 2000),
  created_by           uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id)
);
CREATE INDEX IF NOT EXISTS exos_budgets_org_idx ON public.exos_budgets (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_budgets_event_idx ON public.exos_budgets (event_id) WHERE event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_budgets_hold_idx ON public.exos_budgets (hold_id) WHERE hold_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_budget_lines (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL,
  budget_id    uuid NOT NULL,
  category_id  uuid REFERENCES public.exos_finance_categories (id) ON DELETE SET NULL,
  kind         text NOT NULL DEFAULT 'expense' CHECK (kind IN ('income', 'expense')),
  label        text NOT NULL CHECK (char_length(btrim(label)) BETWEEN 1 AND 120),
  amount_cents bigint NOT NULL DEFAULT 0 CHECK (amount_cents BETWEEN 0 AND 100000000000),
  position     integer NOT NULL DEFAULT 0 CHECK (position BETWEEN 0 AND 1000),
  notes        text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 500),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (budget_id, org_id) REFERENCES public.exos_budgets (id, org_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS exos_budget_lines_budget_idx ON public.exos_budget_lines (budget_id, position);
CREATE INDEX IF NOT EXISTS exos_budget_lines_org_idx ON public.exos_budget_lines (org_id);

-- One pool per budget (Opendate's v3 offer pools).
CREATE TABLE IF NOT EXISTS public.exos_offer_pools (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL,
  budget_id  uuid NOT NULL UNIQUE,
  mode       text NOT NULL DEFAULT 'independent' CHECK (mode IN ('independent', 'pool')),
  -- The shared deal (_exos_deal_terms(.., true)).
  terms      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(terms) = 'object'),
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (budget_id, org_id) REFERENCES public.exos_budgets (id, org_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS exos_offer_pools_org_idx ON public.exos_offer_pools (org_id);

-- Budget rows: links must be the org's own; 2000 per org.
CREATE OR REPLACE FUNCTION public._exos_tg_budget()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'a budget can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.currency IS DISTINCT FROM OLD.currency
     AND EXISTS (SELECT 1 FROM public.exos_offers WHERE budget_id = NEW.id) THEN
    RAISE EXCEPTION 'a budget with offers keeps its currency' USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    IF (SELECT count(*) FROM public.exos_budgets WHERE org_id = NEW.org_id) >= 2000 THEN
      RAISE EXCEPTION 'at most 2000 budgets per organization' USING ERRCODE = '54000';
    END IF;
  END IF;
  NEW.name := btrim(NEW.name);
  IF NEW.venue_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_venues WHERE id = NEW.venue_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'venue_id is not one of this organization''s venues' USING ERRCODE = '22023';
  END IF;
  IF NEW.hold_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_holds WHERE id = NEW.hold_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'hold_id is not one of this organization''s holds' USING ERRCODE = '22023';
  END IF;
  IF NEW.event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = NEW.event_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'event_id is not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_budget() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_budgets_guard ON public.exos_budgets;
CREATE TRIGGER exos_budgets_guard BEFORE INSERT OR UPDATE ON public.exos_budgets
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_budget();

-- Budget lines and pools take their org from the budget; a line's category
-- is the org's own and of a kind that fits; 100 lines per budget.
CREATE OR REPLACE FUNCTION public._exos_tg_budget_child()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_kind text;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_budgets WHERE id = NEW.budget_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'budget not found' USING ERRCODE = 'P0002';
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.budget_id IS DISTINCT FROM OLD.budget_id OR v_org IS DISTINCT FROM OLD.org_id) THEN
    RAISE EXCEPTION 'can''t move to another budget' USING ERRCODE = '22023';
  END IF;
  NEW.org_id := v_org;
  IF TG_TABLE_NAME = 'exos_budget_lines' THEN
    NEW.label := btrim(NEW.label);
    IF NEW.category_id IS NOT NULL THEN
      SELECT kind INTO v_kind FROM public.exos_finance_categories WHERE id = NEW.category_id AND org_id = v_org;
      IF v_kind IS NULL THEN
        RAISE EXCEPTION 'category_id is not one of this organization''s finance categories' USING ERRCODE = '22023';
      END IF;
      IF v_kind <> 'both' AND v_kind <> NEW.kind THEN
        RAISE EXCEPTION 'that category is for % lines', v_kind USING ERRCODE = '22023';
      END IF;
    END IF;
    IF TG_OP = 'INSERT' AND (SELECT count(*) FROM public.exos_budget_lines WHERE budget_id = NEW.budget_id) >= 100 THEN
      RAISE EXCEPTION 'at most 100 lines per budget' USING ERRCODE = '54000';
    END IF;
  ELSE
    NEW.terms := public._exos_deal_terms(NEW.terms, true);
    IF TG_OP = 'INSERT' THEN NEW.created_by := coalesce(auth.uid(), NEW.created_by); END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_budget_child() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_budget_lines_guard ON public.exos_budget_lines;
CREATE TRIGGER exos_budget_lines_guard BEFORE INSERT OR UPDATE ON public.exos_budget_lines
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_budget_child();
DROP TRIGGER IF EXISTS exos_offer_pools_guard ON public.exos_offer_pools;
CREATE TRIGGER exos_offer_pools_guard BEFORE INSERT OR UPDATE ON public.exos_offer_pools
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_budget_child();

-- ===========================================================================
-- 3. Offer templates, imports, offers
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_offer_templates (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id               uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name                 text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  currency             text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  terms                jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(terms) = 'object'),
  boilerplate          text NOT NULL DEFAULT '' CHECK (char_length(boilerplate) <= 10000),
  -- [{ category_key | category_id, kind, label, amount_cents }] copied to a new budget.
  budget_lines         jsonb NOT NULL DEFAULT '[]'::jsonb
                       CHECK (jsonb_typeof(budget_lines) = 'array' AND jsonb_array_length(budget_lines) <= 50),
  capacity             integer CHECK (capacity IS NULL OR capacity BETWEEN 0 AND 1000000),
  average_price_cents  bigint CHECK (average_price_cents IS NULL OR average_price_cents BETWEEN 0 AND 100000000),
  sell_through_percent numeric(6, 3) CHECK (sell_through_percent IS NULL OR sell_through_percent BETWEEN 0 AND 100),
  expires_in_days      integer CHECK (expires_in_days IS NULL OR expires_in_days BETWEEN 1 AND 365),
  created_by           uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_offer_templates_org_idx ON public.exos_offer_templates (org_id, name);

CREATE OR REPLACE FUNCTION public._exos_tg_offer_template()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE l jsonb;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'a template can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    IF (SELECT count(*) FROM public.exos_offer_templates WHERE org_id = NEW.org_id) >= 50 THEN
      RAISE EXCEPTION 'at most 50 offer templates per organization' USING ERRCODE = '54000';
    END IF;
  END IF;
  NEW.name := btrim(NEW.name);
  NEW.terms := public._exos_deal_terms(NEW.terms);
  FOR l IN SELECT * FROM jsonb_array_elements(NEW.budget_lines) LOOP
    IF jsonb_typeof(l) <> 'object' OR char_length(btrim(coalesce(l ->> 'label', ''))) NOT BETWEEN 1 AND 120
       OR coalesce(l ->> 'kind', 'expense') NOT IN ('income', 'expense') THEN
      RAISE EXCEPTION 'each budget line needs a label (1-120 characters) and kind income or expense' USING ERRCODE = '22023';
    END IF;
    PERFORM public._exos_fin_cents(l, 'amount_cents', 'budget_lines.amount_cents');
  END LOOP;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_offer_template() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_offer_templates_guard ON public.exos_offer_templates;
CREATE TRIGGER exos_offer_templates_guard BEFORE INSERT OR UPDATE ON public.exos_offer_templates
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_offer_template();

CREATE TABLE IF NOT EXISTS public.exos_offer_imports (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  file_name     text CHECK (file_name IS NULL OR char_length(file_name) <= 200),
  status        text NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'partial', 'failed')),
  row_count     integer NOT NULL DEFAULT 0 CHECK (row_count BETWEEN 0 AND 200),
  created_count integer NOT NULL DEFAULT 0 CHECK (created_count BETWEEN 0 AND 200),
  -- [{ row, error }]
  errors        jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(errors) = 'array'),
  created_via   text NOT NULL DEFAULT 'dashboard' CHECK (created_via IN ('dashboard', 'api')),
  created_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_offer_imports_org_idx ON public.exos_offer_imports (org_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.exos_offers (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL,
  budget_id           uuid NOT NULL,
  title               text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 150),
  status              text NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft', 'sent', 'accepted', 'declined', 'expired', 'cancelled')),
  hold_id             uuid REFERENCES public.exos_holds (id) ON DELETE SET NULL,
  event_id            uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  venue_id            uuid REFERENCES public.exos_venues (id) ON DELETE SET NULL,
  room_id             uuid REFERENCES public.exos_venue_rooms (id) ON DELETE SET NULL,
  dates               date[] NOT NULL DEFAULT '{}' CHECK (cardinality(dates) <= 31),
  currency            text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  artist_id           uuid REFERENCES public.exos_artists (id) ON DELETE SET NULL,
  artist_name         text NOT NULL CHECK (char_length(btrim(artist_name)) BETWEEN 1 AND 150),
  act_type            text NOT NULL DEFAULT 'headliner'
                      CHECK (act_type IN ('headliner', 'co_headliner', 'support', 'opener', 'other')),
  terms               jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(terms) = 'object'),
  -- Share of the pool payout when the budget's pool is in `pool` mode; NULL =
  -- an equal part of what the explicit shares leave.
  pool_share_percent  numeric(6, 3) CHECK (pool_share_percent IS NULL OR pool_share_percent BETWEEN 0 AND 100),
  agent_name          text CHECK (agent_name IS NULL OR char_length(agent_name) <= 100),
  agent_email         text CHECK (agent_email IS NULL OR char_length(agent_email) <= 200),
  agent_company       text CHECK (agent_company IS NULL OR char_length(agent_company) <= 100),
  agent_phone         text CHECK (agent_phone IS NULL OR char_length(agent_phone) <= 40),
  boilerplate         text NOT NULL DEFAULT '' CHECK (char_length(boilerplate) <= 10000),
  notes               text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 4000),
  template_id         uuid REFERENCES public.exos_offer_templates (id) ON DELETE SET NULL,
  import_id           uuid REFERENCES public.exos_offer_imports (id) ON DELETE SET NULL,
  expires_at          timestamptz,
  sent_at             timestamptz,
  sent_to             text CHECK (sent_to IS NULL OR char_length(sent_to) <= 200),
  send_count          integer NOT NULL DEFAULT 0,
  -- SHA-256 (hex) of the link token; the token itself is only ever mailed.
  response_token_hash text CHECK (response_token_hash IS NULL OR response_token_hash ~ '^[0-9a-f]{64}$'),
  response            jsonb CHECK (response IS NULL OR jsonb_typeof(response) = 'object'),
  history             jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(history) = 'array'),
  created_by          uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_via         text NOT NULL DEFAULT 'dashboard' CHECK (created_via IN ('dashboard', 'api', 'import')),
  api_key_id          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id),
  FOREIGN KEY (budget_id, org_id) REFERENCES public.exos_budgets (id, org_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS exos_offers_org_idx ON public.exos_offers (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_offers_budget_idx ON public.exos_offers (budget_id);
CREATE INDEX IF NOT EXISTS exos_offers_event_idx ON public.exos_offers (event_id) WHERE event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_offers_hold_idx ON public.exos_offers (hold_id) WHERE hold_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_offers_status_idx ON public.exos_offers (org_id, status, expires_at);

-- Offer rows: every link is the org's own (room in the venue), terms
-- canonical, currency = the budget's, history capped at 100 entries.
CREATE OR REPLACE FUNCTION public._exos_tg_offer()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_cur text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'an offer can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  SELECT currency INTO v_cur FROM public.exos_budgets WHERE id = NEW.budget_id AND org_id = NEW.org_id;
  IF v_cur IS NULL THEN
    RAISE EXCEPTION 'budget_id is not one of this organization''s budgets' USING ERRCODE = '22023';
  END IF;
  NEW.currency := v_cur;
  NEW.title := btrim(NEW.title);
  NEW.artist_name := btrim(NEW.artist_name);
  NEW.terms := public._exos_deal_terms(NEW.terms);
  NEW.agent_email := public._exos_fin_email(NEW.agent_email, 'agent.email');
  IF NEW.hold_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_holds WHERE id = NEW.hold_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'hold_id is not one of this organization''s holds' USING ERRCODE = '22023';
  END IF;
  IF NEW.event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = NEW.event_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'event_id is not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  IF NEW.venue_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_venues WHERE id = NEW.venue_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'venue_id is not one of this organization''s venues' USING ERRCODE = '22023';
  END IF;
  IF NEW.room_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_venue_rooms WHERE id = NEW.room_id AND org_id = NEW.org_id
          AND (NEW.venue_id IS NULL OR venue_id = NEW.venue_id)) THEN
    RAISE EXCEPTION 'room_id is not a room of that venue' USING ERRCODE = '22023';
  END IF;
  IF NEW.artist_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_artists WHERE id = NEW.artist_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'artist_id is not one of this organization''s artists' USING ERRCODE = '22023';
  END IF;
  IF NEW.template_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.template_id IS DISTINCT FROM OLD.template_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_offer_templates WHERE id = NEW.template_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'template_id is not one of this organization''s templates' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(NEW.history) > 100 THEN
    SELECT jsonb_agg(x ORDER BY i) INTO NEW.history
      FROM jsonb_array_elements(NEW.history) WITH ORDINALITY AS h(x, i)
     WHERE i > jsonb_array_length(NEW.history) - 100;
  END IF;
  IF TG_OP = 'INSERT' AND (SELECT count(*) FROM public.exos_offers WHERE budget_id = NEW.budget_id) >= 20 THEN
    RAISE EXCEPTION 'at most 20 offers share one budget' USING ERRCODE = '54000';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_offer() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_offers_guard ON public.exos_offers;
CREATE TRIGGER exos_offers_guard BEFORE INSERT OR UPDATE ON public.exos_offers
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_offer();

-- A converted hold night links the hold's open offers and its budgets to the
-- new event (they never had one).
CREATE OR REPLACE FUNCTION public._exos_tg_offer_hold_converted()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'converted' AND NEW.event_id IS NOT NULL
     AND (OLD.status IS DISTINCT FROM 'converted' OR OLD.event_id IS DISTINCT FROM NEW.event_id) THEN
    UPDATE public.exos_offers SET event_id = NEW.event_id
     WHERE hold_id = NEW.hold_id AND org_id = NEW.org_id AND event_id IS NULL
       AND status IN ('draft', 'sent', 'accepted');
    UPDATE public.exos_budgets SET event_id = NEW.event_id
     WHERE hold_id = NEW.hold_id AND org_id = NEW.org_id AND event_id IS NULL;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_offer_hold_converted() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_hold_positions_offer_link ON public.exos_hold_positions;
CREATE TRIGGER exos_hold_positions_offer_link AFTER UPDATE OF status, event_id ON public.exos_hold_positions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_offer_hold_converted();

-- ===========================================================================
-- 4. CRM deals (org-level equivalent of Opendate's admin deals)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_crm_deals (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name              text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 150),
  deal_type         text NOT NULL DEFAULT 'sales' CHECK (deal_type IN ('sales', 'fundraising')),
  stage             text NOT NULL DEFAULT 'lead',
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'won', 'lost')),
  amount_cents      bigint NOT NULL DEFAULT 0 CHECK (amount_cents BETWEEN 0 AND 100000000000),
  currency          text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  probability       integer CHECK (probability IS NULL OR probability BETWEEN 0 AND 100),
  expected_close_on date,
  owner_user_id     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  contact_name      text CHECK (contact_name IS NULL OR char_length(contact_name) <= 100),
  contact_email     text CHECK (contact_email IS NULL OR char_length(contact_email) <= 200),
  company           text CHECK (company IS NULL OR char_length(company) <= 100),
  offer_id          uuid REFERENCES public.exos_offers (id) ON DELETE SET NULL,
  event_id          uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  notes             text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 4000),
  discarded_at      timestamptz,
  created_by        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_crm_deals_org_idx ON public.exos_crm_deals (org_id, status, expected_close_on);

-- Stages per type (Opendate's); status follows the stage.
CREATE OR REPLACE FUNCTION public._exos_tg_crm_deal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'a deal can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    IF (SELECT count(*) FROM public.exos_crm_deals WHERE org_id = NEW.org_id AND discarded_at IS NULL) >= 5000 THEN
      RAISE EXCEPTION 'at most 5000 open deals per organization' USING ERRCODE = '54000';
    END IF;
  END IF;
  NEW.name := btrim(NEW.name);
  NEW.contact_email := public._exos_fin_email(NEW.contact_email, 'contact_email');
  IF NEW.deal_type = 'sales' AND NEW.stage NOT IN ('lead', 'qualified', 'proposal', 'negotiation', 'closed_won', 'closed_lost') THEN
    RAISE EXCEPTION 'a sales deal''s stage is one of lead, qualified, proposal, negotiation, closed_won, closed_lost' USING ERRCODE = '22023';
  END IF;
  IF NEW.deal_type = 'fundraising' AND NEW.stage NOT IN ('identification', 'qualification', 'cultivation', 'solicitation',
                                                         'stewardship', 'closed_won', 'closed_lost', 'not_a_prospect') THEN
    RAISE EXCEPTION 'a fundraising deal''s stage is one of identification, qualification, cultivation, solicitation, stewardship, closed_won, closed_lost, not_a_prospect' USING ERRCODE = '22023';
  END IF;
  NEW.status := CASE NEW.stage WHEN 'closed_won' THEN 'won' WHEN 'closed_lost' THEN 'lost' WHEN 'not_a_prospect' THEN 'lost' ELSE 'open' END;
  IF NEW.owner_user_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m WHERE m.org_id = NEW.org_id AND m.user_id = NEW.owner_user_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = NEW.org_id AND o.owner_uid = NEW.owner_user_id) THEN
    RAISE EXCEPTION 'owner_user_id is not a member of this organization' USING ERRCODE = '22023';
  END IF;
  IF NEW.offer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_offers WHERE id = NEW.offer_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'offer_id is not one of this organization''s offers' USING ERRCODE = '22023';
  END IF;
  IF NEW.event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = NEW.event_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'event_id is not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_crm_deal() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_crm_deals_guard ON public.exos_crm_deals;
CREATE TRIGGER exos_crm_deals_guard BEFORE INSERT OR UPDATE ON public.exos_crm_deals
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_crm_deal();

-- ===========================================================================
-- 5. updated_at, RLS, grants
--    Read: owner / manager / finance (every table here holds money figures).
--    Write: owner / manager (offers only through the functions below);
--    finance categories and GL codes also finance.
-- ===========================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_gl_codes', 'exos_finance_categories', 'exos_budgets', 'exos_budget_lines',
                           'exos_offer_pools', 'exos_offer_templates', 'exos_offer_imports', 'exos_offers',
                           'exos_crm_deals'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I
                      FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated;', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role;', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_sel', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']));',
                   t || '_sel', t);
  END LOOP;
  -- Plain row writes (triggers validate).
  FOREACH t IN ARRAY ARRAY['exos_budgets', 'exos_budget_lines', 'exos_offer_pools', 'exos_offer_templates',
                           'exos_crm_deals'] LOOP
    EXECUTE format('GRANT INSERT, UPDATE, DELETE ON public.%I TO authenticated;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_write', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'']))
                      WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'']));',
                   t || '_write', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['exos_gl_codes', 'exos_finance_categories'] LOOP
    EXECUTE format('GRANT INSERT, UPDATE ON public.%I TO authenticated;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_ins', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated
                      WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']));',
                   t || '_ins', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_upd', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated
                      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']))
                      WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']));',
                   t || '_upd', t);
  END LOOP;
END $$;
-- Custom categories can be deleted (system ones can't); GL codes are
-- discarded (discarded_at), never deleted from a browser.
GRANT DELETE ON public.exos_finance_categories TO authenticated;
DROP POLICY IF EXISTS exos_finance_categories_del ON public.exos_finance_categories;
CREATE POLICY exos_finance_categories_del ON public.exos_finance_categories FOR DELETE TO authenticated
  USING (NOT system AND (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance'])));
-- The link token's hash is nobody's business in a browser.
REVOKE SELECT ON public.exos_offers FROM authenticated;
GRANT SELECT (id, org_id, budget_id, title, status, hold_id, event_id, venue_id, room_id, dates, currency,
              artist_id, artist_name, act_type, terms, pool_share_percent, agent_name, agent_email,
              agent_company, agent_phone, boilerplate, notes, template_id, import_id, expires_at, sent_at,
              sent_to, send_count, response, history, created_by, created_via, created_at, updated_at)
  ON public.exos_offers TO authenticated;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_gl_codes', 'exos_finance_categories', 'exos_budgets', 'exos_budget_lines',
                               'exos_offer_pools', 'exos_offer_templates', 'exos_offer_imports', 'exos_offers',
                               'exos_crm_deals'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- ===========================================================================
-- 6. Offer logic (cores: service_role; exos-api passes the key's org)
-- ===========================================================================

-- The status an offer reads as now (a sent offer past expires_at is expired).
CREATE OR REPLACE FUNCTION public._exos_offer_status(p_status text, p_expires_at timestamptz)
RETURNS text LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p_status = 'sent' AND p_expires_at IS NOT NULL AND p_expires_at <= now() THEN 'expired' ELSE p_status END;
$$;
REVOKE ALL ON FUNCTION public._exos_offer_status(text, timestamptz) FROM PUBLIC, anon, authenticated;

-- Write back offers that have expired (one org, or all when NULL).
CREATE OR REPLACE FUNCTION public._exos_offers_expire(p_org uuid)
RETURNS integer LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE n int;
BEGIN
  UPDATE public.exos_offers
     SET status = 'expired',
         history = history || jsonb_build_array(jsonb_build_object('at', now(), 'action', 'expired'))
   WHERE status = 'sent' AND expires_at IS NOT NULL AND expires_at <= now()
     AND (p_org IS NULL OR org_id = p_org);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public._exos_offers_expire(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offers_expire(uuid) TO service_role;

-- The offer as the API and the webhooks show it (never the token hash).
CREATE OR REPLACE FUNCTION public._exos_offer_json(p_offer_id uuid)
RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', o.id, 'budget_id', o.budget_id, 'title', o.title,
    'status', public._exos_offer_status(o.status, o.expires_at),
    'hold_id', o.hold_id, 'event_id', o.event_id, 'venue_id', o.venue_id, 'room_id', o.room_id,
    'dates', to_jsonb(o.dates), 'currency', o.currency,
    'artist_id', o.artist_id, 'artist_name', o.artist_name, 'act_type', o.act_type,
    'terms', o.terms, 'pool_share_percent', o.pool_share_percent,
    'pool', (SELECT jsonb_build_object('id', p.id, 'mode', p.mode) FROM public.exos_offer_pools p WHERE p.budget_id = o.budget_id),
    'agent', CASE WHEN o.agent_name IS NULL AND o.agent_email IS NULL THEN NULL ELSE jsonb_build_object(
      'name', o.agent_name, 'email', o.agent_email, 'company', o.agent_company, 'phone', o.agent_phone) END,
    'boilerplate', o.boilerplate, 'notes', o.notes, 'template_id', o.template_id, 'import_id', o.import_id,
    'expires_at', o.expires_at, 'sent_at', o.sent_at, 'sent_to', o.sent_to, 'response', o.response,
    'history', o.history, 'created_via', o.created_via, 'created_at', o.created_at, 'updated_at', o.updated_at)
    FROM public.exos_offers o WHERE o.id = p_offer_id;
$$;
REVOKE ALL ON FUNCTION public._exos_offer_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_json(uuid) TO service_role;

-- Budget lines from a list ([{ category_id | category_key, kind, label, amount_cents }]).
CREATE OR REPLACE FUNCTION public._exos_budget_add_lines(p_org uuid, p_budget uuid, p_lines jsonb)
RETURNS void LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE l jsonb; v_cat uuid; i int := 0;
BEGIN
  IF p_lines IS NULL OR jsonb_typeof(p_lines) = 'null' THEN RETURN; END IF;
  IF jsonb_typeof(p_lines) <> 'array' THEN
    RAISE EXCEPTION 'budget.lines must be a list' USING ERRCODE = '22023';
  END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    i := i + 1;
    IF jsonb_typeof(l) <> 'object' THEN
      RAISE EXCEPTION 'each budget line must be an object' USING ERRCODE = '22023';
    END IF;
    v_cat := CASE WHEN nullif(l ->> 'category_id', '') IS NOT NULL
                  THEN public._exos_uuid(l ->> 'category_id', 'budget.lines.category_id')
                  WHEN nullif(l ->> 'category_key', '') IS NOT NULL
                  THEN public._exos_fin_category(p_org, l ->> 'category_key') END;
    IF nullif(l ->> 'category_key', '') IS NOT NULL AND v_cat IS NULL THEN
      RAISE EXCEPTION 'budget.lines.category_key % is not a category of this organization', l ->> 'category_key'
        USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_budget_lines (org_id, budget_id, category_id, kind, label, amount_cents, position)
    VALUES (p_org, p_budget, v_cat, coalesce(nullif(l ->> 'kind', ''), 'expense'),
            coalesce(l ->> 'label', ''), public._exos_fin_cents(l, 'amount_cents', 'budget.lines.amount_cents'), i * 10);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public._exos_budget_add_lines(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- Create (p_offer_id NULL) or change an offer. Body fields (all optional on a
-- change): title, artist_id, artist_name, act_type, dates[], hold_id,
-- event_id, venue_id, room_id, terms (merged into the current terms),
-- pool_share_percent, agent { name, email, company, phone }, boilerplate,
-- notes, expires_at, budget_id (join a shared budget), budget { name,
-- capacity, average_price_cents, sell_through_percent, lines[] } (a new
-- budget, on create), template_id (on create).
CREATE OR REPLACE FUNCTION public._exos_offer_save(p_org uuid, p_actor uuid, p_via text, p_api_key uuid,
                                                   p_offer_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  b       jsonb := CASE WHEN jsonb_typeof(p) = 'object' THEN p ELSE '{}'::jsonb END;
  o       public.exos_offers%ROWTYPE;
  tpl     public.exos_offer_templates%ROWTYPE;
  h       public.exos_holds%ROWTYPE;
  bud     jsonb := CASE WHEN jsonb_typeof(b -> 'budget') = 'object' THEN b -> 'budget' ELSE '{}'::jsonb END;
  ag      jsonb := CASE WHEN jsonb_typeof(b -> 'agent') = 'object' THEN b -> 'agent' ELSE NULL END;
  v_id    uuid;
  v_budget uuid;
  v_cap   int;
  v_dates date[];
  v_venue uuid; v_room uuid;
  v_rental numeric; v_rel text;
  v_terms_changed boolean := false;
  v_old_status text;
  v_artist_name text;
BEGIN
  IF p IS NOT NULL AND jsonb_typeof(p) NOT IN ('object', 'null') THEN
    RAISE EXCEPTION 'the body must be an object' USING ERRCODE = '22023';
  END IF;
  IF b ? 'terms' AND jsonb_typeof(b -> 'terms') NOT IN ('object', 'null') THEN
    RAISE EXCEPTION 'terms must be an object' USING ERRCODE = '22023';
  END IF;
  IF b ? 'budget' AND jsonb_typeof(b -> 'budget') NOT IN ('object', 'null') THEN
    RAISE EXCEPTION 'budget must be an object' USING ERRCODE = '22023';
  END IF;
  IF b ? 'dates' AND jsonb_typeof(b -> 'dates') NOT IN ('array', 'null') THEN
    RAISE EXCEPTION 'dates must be a list of YYYY-MM-DD dates' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(b -> 'dates') = 'array' THEN
    BEGIN
      SELECT coalesce(array_agg(DISTINCT x::date ORDER BY x::date), '{}') INTO v_dates
        FROM jsonb_array_elements_text(b -> 'dates') x;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'dates must be a list of YYYY-MM-DD dates' USING ERRCODE = '22023';
    END;
  END IF;

  IF p_offer_id IS NULL THEN
    -- ---- create ----
    IF nullif(b ->> 'template_id', '') IS NOT NULL THEN
      SELECT * INTO tpl FROM public.exos_offer_templates
       WHERE id = public._exos_uuid(b ->> 'template_id', 'template_id') AND org_id = p_org;
      IF tpl.id IS NULL THEN
        RAISE EXCEPTION 'template not found' USING ERRCODE = 'P0002';
      END IF;
    END IF;
    IF nullif(b ->> 'hold_id', '') IS NOT NULL THEN
      SELECT * INTO h FROM public.exos_holds WHERE id = public._exos_uuid(b ->> 'hold_id', 'hold_id') AND org_id = p_org;
      IF h.id IS NULL THEN
        RAISE EXCEPTION 'hold not found' USING ERRCODE = 'P0002';
      END IF;
      IF v_dates IS NULL THEN
        SELECT array_agg(DISTINCT date ORDER BY date) INTO v_dates FROM public.exos_hold_positions
         WHERE hold_id = h.id AND status = 'active';
      END IF;
      SELECT venue_id, room_id INTO v_venue, v_room FROM public.exos_hold_positions
       WHERE hold_id = h.id ORDER BY (status = 'active') DESC, date LIMIT 1;
    END IF;
    v_venue := coalesce(public._exos_uuid(b ->> 'venue_id', 'venue_id'), v_venue);
    v_room := coalesce(public._exos_uuid(b ->> 'room_id', 'room_id'), v_room);
    SELECT coalesce(r.capacity, v.capacity), v.relationship INTO v_cap, v_rel
      FROM public.exos_venues v LEFT JOIN public.exos_venue_rooms r ON r.id = v_room
     WHERE v.id = v_venue AND v.org_id = p_org;
    v_artist_name := nullif(btrim(coalesce(b ->> 'artist_name', '')), '');
    IF v_artist_name IS NULL AND nullif(b ->> 'artist_id', '') IS NOT NULL THEN
      SELECT name INTO v_artist_name FROM public.exos_artists
       WHERE id = public._exos_uuid(b ->> 'artist_id', 'artist_id') AND org_id = p_org;
    END IF;
    IF v_artist_name IS NULL AND h.id IS NOT NULL AND cardinality(h.artist_ids) > 0 THEN
      SELECT name INTO v_artist_name FROM public.exos_artists WHERE id = h.artist_ids[1] AND org_id = p_org;
    END IF;
    IF v_artist_name IS NULL THEN
      RAISE EXCEPTION 'artist_name (or an artist_id) is required' USING ERRCODE = '22023';
    END IF;

    IF nullif(b ->> 'budget_id', '') IS NOT NULL THEN
      SELECT id INTO v_budget FROM public.exos_budgets
       WHERE id = public._exos_uuid(b ->> 'budget_id', 'budget_id') AND org_id = p_org FOR UPDATE;
      IF v_budget IS NULL THEN
        RAISE EXCEPTION 'budget not found' USING ERRCODE = 'P0002';
      END IF;
    ELSE
      INSERT INTO public.exos_budgets (org_id, name, currency, venue_id, hold_id, event_id, capacity,
                                       average_price_cents, sell_through_percent, created_by)
      VALUES (p_org,
              coalesce(nullif(btrim(coalesce(bud ->> 'name', '')), ''), nullif(btrim(coalesce(b ->> 'title', '')), ''), v_artist_name),
              upper(coalesce(nullif(bud ->> 'currency', ''), nullif(b ->> 'currency', ''), tpl.currency,
                             (SELECT to_jsonb(g) ->> 'currency' FROM public.exos_orgs g WHERE g.id = p_org), 'USD')),
              v_venue, h.id, public._exos_uuid(b ->> 'event_id', 'event_id'),
              coalesce(CASE WHEN bud ? 'capacity' THEN public._exos_fin_cents(bud, 'capacity', 'budget.capacity') END,
                       tpl.capacity, v_cap, h.ticket_forecast, 0),
              coalesce(CASE WHEN bud ? 'average_price_cents' THEN public._exos_fin_cents(bud, 'average_price_cents', 'budget.average_price_cents') END,
                       tpl.average_price_cents, 0),
              coalesce(CASE WHEN bud ? 'sell_through_percent' THEN public._exos_fin_pct(bud, 'sell_through_percent', 'budget.sell_through_percent') END,
                       tpl.sell_through_percent, 100),
              p_actor)
      RETURNING id INTO v_budget;
      IF bud ? 'lines' THEN
        PERFORM public._exos_budget_add_lines(p_org, v_budget, bud -> 'lines');
      ELSIF tpl.id IS NOT NULL THEN
        PERFORM public._exos_budget_add_lines(p_org, v_budget, tpl.budget_lines);
      END IF;
      -- Promoter mode: a rented / partner room with rental terms on the hold
      -- gets a Venue rental line with the fee.
      IF h.id IS NOT NULL AND h.rental_status IN ('requested', 'confirmed') AND coalesce(h.rental_fee, 0) > 0
         AND NOT EXISTS (SELECT 1 FROM public.exos_budget_lines l JOIN public.exos_finance_categories c ON c.id = l.category_id
                          WHERE l.budget_id = v_budget AND c.key = 'venue-rental') THEN
        INSERT INTO public.exos_budget_lines (org_id, budget_id, category_id, kind, label, amount_cents, position)
        VALUES (p_org, v_budget, public._exos_fin_category(p_org, 'venue-rental'), 'expense', 'Venue rental',
                round(h.rental_fee * 100)::bigint, 0);
      END IF;
    END IF;

    INSERT INTO public.exos_offers (org_id, budget_id, title, hold_id, event_id, venue_id, room_id, dates,
                                    artist_id, artist_name, act_type, terms, pool_share_percent,
                                    agent_name, agent_email, agent_company, agent_phone, boilerplate, notes,
                                    template_id, expires_at, created_by, created_via, api_key_id, history)
    VALUES (p_org, v_budget,
            coalesce(nullif(btrim(coalesce(b ->> 'title', '')), ''), h.title, v_artist_name),
            h.id, public._exos_uuid(b ->> 'event_id', 'event_id'), v_venue, v_room, coalesce(v_dates, '{}'),
            public._exos_uuid(b ->> 'artist_id', 'artist_id'), v_artist_name,
            coalesce(nullif(b ->> 'act_type', ''), 'headliner'),
            coalesce(tpl.terms, '{}'::jsonb) || CASE WHEN jsonb_typeof(b -> 'terms') = 'object' THEN b -> 'terms' ELSE '{}'::jsonb END,
            public._exos_fin_pct(b, 'pool_share_percent', 'pool_share_percent', true),
            nullif(btrim(coalesce(ag ->> 'name', '')), ''), ag ->> 'email',
            nullif(btrim(coalesce(ag ->> 'company', '')), ''), nullif(btrim(coalesce(ag ->> 'phone', '')), ''),
            CASE WHEN b ? 'boilerplate' THEN public._exos_fin_text(b, 'boilerplate', 'boilerplate', 10000) ELSE coalesce(tpl.boilerplate, '') END,
            public._exos_fin_text(b, 'notes', 'notes', 4000),
            tpl.id,
            CASE WHEN nullif(b ->> 'expires_at', '') IS NOT NULL THEN public._exos_fin_time(b ->> 'expires_at', 'expires_at')
                 WHEN tpl.expires_in_days IS NOT NULL THEN now() + make_interval(days => tpl.expires_in_days) END,
            p_actor, coalesce(p_via, 'dashboard'), p_api_key,
            jsonb_build_array(jsonb_build_object('at', now(), 'action', 'created', 'by', p_actor, 'via', coalesce(p_via, 'dashboard'))))
    RETURNING id INTO v_id;
    RETURN public._exos_offer_json(v_id);
  END IF;

  -- ---- change ----
  PERFORM public._exos_offers_expire(p_org);
  SELECT * INTO o FROM public.exos_offers WHERE id = p_offer_id AND org_id = p_org FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'offer not found' USING ERRCODE = 'P0002';
  END IF;
  v_old_status := o.status;
  IF o.status IN ('accepted', 'declined', 'expired', 'cancelled') THEN
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(b) k WHERE k NOT IN ('notes', 'event_id')) THEN
      RAISE EXCEPTION 'a % offer only takes notes and event_id', o.status USING ERRCODE = '55000';
    END IF;
  END IF;
  IF b ? 'title' THEN o.title := coalesce(b ->> 'title', ''); v_terms_changed := true; END IF;
  IF b ? 'artist_name' THEN o.artist_name := coalesce(b ->> 'artist_name', ''); v_terms_changed := true; END IF;
  IF b ? 'artist_id' THEN o.artist_id := public._exos_uuid(b ->> 'artist_id', 'artist_id'); v_terms_changed := true; END IF;
  IF b ? 'act_type' THEN o.act_type := coalesce(b ->> 'act_type', 'headliner'); END IF;
  IF b ? 'dates' THEN o.dates := coalesce(v_dates, '{}'); v_terms_changed := true; END IF;
  IF b ? 'hold_id' THEN o.hold_id := public._exos_uuid(b ->> 'hold_id', 'hold_id'); END IF;
  IF b ? 'event_id' THEN o.event_id := public._exos_uuid(b ->> 'event_id', 'event_id'); END IF;
  IF b ? 'venue_id' THEN o.venue_id := public._exos_uuid(b ->> 'venue_id', 'venue_id'); v_terms_changed := true; END IF;
  IF b ? 'room_id' THEN o.room_id := public._exos_uuid(b ->> 'room_id', 'room_id'); v_terms_changed := true; END IF;
  IF b ? 'terms' THEN
    IF jsonb_typeof(b -> 'terms') <> 'object' THEN
      RAISE EXCEPTION 'terms must be an object' USING ERRCODE = '22023';
    END IF;
    o.terms := public._exos_deal_terms(o.terms || (b -> 'terms'));
    v_terms_changed := true;
  END IF;
  IF b ? 'pool_share_percent' THEN
    o.pool_share_percent := public._exos_fin_pct(b, 'pool_share_percent', 'pool_share_percent', true);
    v_terms_changed := true;
  END IF;
  IF b ? 'agent' THEN
    IF ag IS NULL AND jsonb_typeof(b -> 'agent') <> 'null' THEN
      RAISE EXCEPTION 'agent must be an object' USING ERRCODE = '22023';
    END IF;
    o.agent_name := nullif(btrim(coalesce(ag ->> 'name', '')), '');
    o.agent_email := ag ->> 'email';
    o.agent_company := nullif(btrim(coalesce(ag ->> 'company', '')), '');
    o.agent_phone := nullif(btrim(coalesce(ag ->> 'phone', '')), '');
  END IF;
  IF b ? 'boilerplate' THEN o.boilerplate := public._exos_fin_text(b, 'boilerplate', 'boilerplate', 10000); v_terms_changed := true; END IF;
  IF b ? 'notes' THEN o.notes := public._exos_fin_text(b, 'notes', 'notes', 4000); END IF;
  IF b ? 'expires_at' THEN
    o.expires_at := CASE WHEN nullif(b ->> 'expires_at', '') IS NULL THEN NULL
                         ELSE public._exos_fin_time(b ->> 'expires_at', 'expires_at') END;
  END IF;
  IF b ? 'budget_id' THEN
    IF o.status <> 'draft' THEN
      RAISE EXCEPTION 'only a draft offer moves to another budget' USING ERRCODE = '55000';
    END IF;
    o.budget_id := public._exos_uuid(b ->> 'budget_id', 'budget_id');
    IF NOT EXISTS (SELECT 1 FROM public.exos_budgets WHERE id = o.budget_id AND org_id = p_org) THEN
      RAISE EXCEPTION 'budget not found' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  IF o.status = 'sent' AND v_terms_changed THEN
    o.status := 'draft';
    o.response_token_hash := NULL;
    o.history := o.history || jsonb_build_array(jsonb_build_object('at', now(), 'action', 'returned_to_draft', 'by', p_actor,
                                                                   'note', 'terms changed after sending; send again'));
  END IF;
  o.history := o.history || jsonb_build_array(jsonb_build_object('at', now(), 'action', 'edited', 'by', p_actor,
                                                                 'via', coalesce(p_via, 'dashboard')));
  UPDATE public.exos_offers SET
    title = o.title, artist_name = o.artist_name, artist_id = o.artist_id, act_type = o.act_type, dates = o.dates,
    hold_id = o.hold_id, event_id = o.event_id, venue_id = o.venue_id, room_id = o.room_id, terms = o.terms,
    pool_share_percent = o.pool_share_percent, agent_name = o.agent_name, agent_email = o.agent_email,
    agent_company = o.agent_company, agent_phone = o.agent_phone, boilerplate = o.boilerplate, notes = o.notes,
    expires_at = o.expires_at, budget_id = o.budget_id, status = o.status,
    response_token_hash = o.response_token_hash, history = o.history
  WHERE id = o.id;
  RETURN public._exos_offer_json(o.id);
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_save(uuid, uuid, text, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_save(uuid, uuid, text, uuid, uuid, jsonb) TO service_role;

-- An ISO 8601 timestamp or a 22023 naming the field.
CREATE OR REPLACE FUNCTION public._exos_fin_time(p text, p_field text)
RETURNS timestamptz LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p !~ '^\d{4}-\d{2}-\d{2}([T ][0-9:.]+)?(Z|[+-]\d{2}(:?\d{2})?)?$' THEN
    RAISE EXCEPTION '% must be an ISO 8601 time', p_field USING ERRCODE = '22023';
  END IF;
  RETURN p::timestamptz;
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
  RAISE EXCEPTION '% must be an ISO 8601 time', p_field USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_time(text, text) FROM PUBLIC, anon, authenticated;

-- Send (or send again): a new link token, status sent, the offer-sent mail to
-- p_to or the agent, webhook offer.sent. Returns the offer plus the link path
-- (with the token) for the sender to copy; the token is not stored.
CREATE OR REPLACE FUNCTION public._exos_offer_send(p_org uuid, p_actor uuid, p_offer_id uuid, p_to text)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  o       public.exos_offers%ROWTYPE;
  v_to    text;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_org   jsonb;
  v_venue text;
BEGIN
  PERFORM public._exos_offers_expire(p_org);
  SELECT * INTO o FROM public.exos_offers WHERE id = p_offer_id AND org_id = p_org FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'offer not found' USING ERRCODE = 'P0002';
  END IF;
  IF o.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'a % offer can''t be sent', o.status USING ERRCODE = '55000';
  END IF;
  v_to := coalesce(public._exos_fin_email(p_to, 'to'), o.agent_email);
  IF v_to IS NULL THEN
    RAISE EXCEPTION 'no address to send to: give the agent an email, or a to address' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_offers SET
    status = 'sent', sent_at = now(), sent_to = v_to, send_count = send_count + 1,
    response_token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'action', 'sent', 'by', p_actor, 'to', v_to))
  WHERE id = o.id;
  SELECT jsonb_build_object('id', g.id, 'name', g.name) INTO v_org FROM public.exos_orgs g WHERE g.id = p_org;
  SELECT v.name || coalesce(' — ' || r.name, '') INTO v_venue
    FROM public.exos_venues v LEFT JOIN public.exos_venue_rooms r ON r.id = o.room_id WHERE v.id = o.venue_id;
  PERFORM public.exos_mail_enqueue('offer-sent', v_to, jsonb_build_object(
    'org', v_org,
    'offer', jsonb_build_object('id', o.id, 'title', o.title, 'artist_name', o.artist_name,
                                'dates', to_jsonb(o.dates), 'venue', v_venue, 'currency', o.currency,
                                'terms', o.terms, 'expires_at', o.expires_at, 'agent_name', o.agent_name),
    'token', v_token), NULL, NULL, false, p_actor);
  PERFORM public.exos_enqueue_webhook(p_org, 'offer.sent', public._exos_offer_json(o.id));
  RETURN public._exos_offer_json(o.id) || jsonb_build_object('link_path', '/offer/' || o.id || '?t=' || v_token);
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_send(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_send(uuid, uuid, uuid, text) TO service_role;

-- Record an answer. via 'link' (the agent, from sent only) or 'api' /
-- 'dashboard' (the venue's own record, from draft or sent).
CREATE OR REPLACE FUNCTION public._exos_offer_record_response(p_org uuid, p_actor uuid, p_offer_id uuid,
                                                              p_action text, p_name text, p_note text, p_via text,
                                                              p_ip text DEFAULT NULL, p_user_agent text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE o public.exos_offers%ROWTYPE; v_name text := btrim(coalesce(p_name, '')); v_note text := btrim(coalesce(p_note, ''));
BEGIN
  IF p_action NOT IN ('accept', 'decline') THEN
    RAISE EXCEPTION 'action must be accept or decline' USING ERRCODE = '22023';
  END IF;
  IF p_via NOT IN ('link', 'api', 'dashboard') THEN
    RAISE EXCEPTION 'bad via' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_name) > 100 OR char_length(v_note) > 1000 THEN
    RAISE EXCEPTION 'name must be at most 100 characters and note at most 1000' USING ERRCODE = '22023';
  END IF;
  IF p_via = 'link' AND v_name = '' THEN
    RAISE EXCEPTION 'your name is required' USING ERRCODE = '22023';
  END IF;
  PERFORM public._exos_offers_expire(p_org);
  SELECT * INTO o FROM public.exos_offers WHERE id = p_offer_id AND org_id = p_org FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'offer not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (o.status = 'sent' OR (o.status = 'draft' AND p_via <> 'link')) THEN
    RAISE EXCEPTION 'this offer is % and can''t be answered', o.status USING ERRCODE = '55000';
  END IF;
  UPDATE public.exos_offers SET
    status = CASE p_action WHEN 'accept' THEN 'accepted' ELSE 'declined' END,
    response = jsonb_build_object('action', p_action, 'name', nullif(v_name, ''), 'note', nullif(v_note, ''),
                                  'at', now(), 'ip', left(p_ip, 64), 'user_agent', left(p_user_agent, 300),
                                  'via', p_via, 'by', p_actor),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'action', p_action || 'ed', 'by', p_actor,
                                                              'via', p_via, 'name', nullif(v_name, '')))
  WHERE id = o.id;
  PERFORM public.exos_enqueue_webhook(p_org, CASE p_action WHEN 'accept' THEN 'offer.accepted' ELSE 'offer.declined' END,
                                      public._exos_offer_json(o.id));
  RETURN public._exos_offer_json(o.id);
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_record_response(uuid, uuid, uuid, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_record_response(uuid, uuid, uuid, text, text, text, text, text, text) TO service_role;

-- Cancel (draft, sent or accepted) or delete (drafts only; the budget goes
-- too when nothing else uses it).
CREATE OR REPLACE FUNCTION public._exos_offer_cancel(p_org uuid, p_actor uuid, p_offer_id uuid, p_note text)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE o public.exos_offers%ROWTYPE;
BEGIN
  PERFORM public._exos_offers_expire(p_org);
  SELECT * INTO o FROM public.exos_offers WHERE id = p_offer_id AND org_id = p_org FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'offer not found' USING ERRCODE = 'P0002';
  END IF;
  IF o.status NOT IN ('draft', 'sent', 'accepted') THEN
    RAISE EXCEPTION 'a % offer can''t be cancelled', o.status USING ERRCODE = '55000';
  END IF;
  UPDATE public.exos_offers SET status = 'cancelled', response_token_hash = NULL,
         history = history || jsonb_build_array(jsonb_build_object('at', now(), 'action', 'cancelled', 'by', p_actor,
                                                                   'note', left(nullif(btrim(coalesce(p_note, '')), ''), 500)))
   WHERE id = o.id;
  RETURN public._exos_offer_json(o.id);
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_cancel(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_cancel(uuid, uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_offer_delete(p_org uuid, p_offer_id uuid)
RETURNS void LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE o public.exos_offers%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.exos_offers WHERE id = p_offer_id AND org_id = p_org FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'offer not found' USING ERRCODE = 'P0002';
  END IF;
  IF o.status <> 'draft' THEN
    RAISE EXCEPTION 'only a draft offer can be deleted; cancel it instead' USING ERRCODE = '55000';
  END IF;
  DELETE FROM public.exos_offers WHERE id = o.id;
  UPDATE public.exos_crm_deals SET offer_id = NULL WHERE offer_id = o.id;
  DELETE FROM public.exos_budgets b WHERE b.id = o.budget_id
     AND NOT EXISTS (SELECT 1 FROM public.exos_offers x WHERE x.budget_id = b.id);
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_delete(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_delete(uuid, uuid) TO service_role;

-- The pool over an offer's budget (or a budget), created on first ask:
-- idempotent. p_mode / p_terms change it when given.
CREATE OR REPLACE FUNCTION public._exos_offer_pool_ensure(p_org uuid, p_actor uuid, p_budget_id uuid,
                                                          p_mode text DEFAULT NULL, p_terms jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_pool public.exos_offer_pools%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_budgets WHERE id = p_budget_id AND org_id = p_org) THEN
    RAISE EXCEPTION 'budget not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_mode IS NOT NULL AND p_mode NOT IN ('independent', 'pool') THEN
    RAISE EXCEPTION 'mode must be independent or pool' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_offer_pools (org_id, budget_id, mode, terms, created_by)
  VALUES (p_org, p_budget_id, coalesce(p_mode, 'independent'), coalesce(p_terms, '{}'::jsonb), p_actor)
  ON CONFLICT (budget_id) DO NOTHING;
  SELECT * INTO v_pool FROM public.exos_offer_pools WHERE budget_id = p_budget_id FOR UPDATE;
  IF p_mode IS NOT NULL OR p_terms IS NOT NULL THEN
    UPDATE public.exos_offer_pools
       SET mode = coalesce(p_mode, mode),
           terms = CASE WHEN p_terms IS NULL THEN terms ELSE terms || p_terms END
     WHERE id = v_pool.id
     RETURNING * INTO v_pool;
  END IF;
  RETURN jsonb_build_object('id', v_pool.id, 'budget_id', v_pool.budget_id, 'mode', v_pool.mode, 'terms', v_pool.terms,
    'offer_ids', coalesce((SELECT jsonb_agg(o.id ORDER BY o.created_at) FROM public.exos_offers o WHERE o.budget_id = p_budget_id), '[]'::jsonb),
    'created_at', v_pool.created_at, 'updated_at', v_pool.updated_at);
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_pool_ensure(uuid, uuid, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_pool_ensure(uuid, uuid, uuid, text, jsonb) TO service_role;

-- Import offers from rows a client parsed from a spreadsheet (CSV), at most
-- 200: each row is an _exos_offer_save body plus optional `group` (rows with
-- the same group share one budget, a lineup). Each row is its own
-- sub-transaction: a bad row is reported, the good ones are created.
CREATE OR REPLACE FUNCTION public._exos_offer_import(p_org uuid, p_actor uuid, p_via text, p_api_key uuid,
                                                     p_file_name text, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_import uuid;
  r jsonb; i int := 0;
  v_groups jsonb := '{}'::jsonb;
  v_created jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_offer jsonb;
  v_group text;
  v_body jsonb;
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'rows must be a non-empty list' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_rows) > 200 THEN
    RAISE EXCEPTION 'at most 200 rows per import' USING ERRCODE = '54000';
  END IF;
  IF p_file_name IS NOT NULL AND char_length(p_file_name) > 200 THEN
    RAISE EXCEPTION 'file_name must be at most 200 characters' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_offer_imports (org_id, file_name, row_count, created_via, created_by)
  VALUES (p_org, p_file_name, jsonb_array_length(p_rows), CASE WHEN p_via = 'api' THEN 'api' ELSE 'dashboard' END, p_actor)
  RETURNING id INTO v_import;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    i := i + 1;
    BEGIN
      IF jsonb_typeof(r) <> 'object' THEN
        RAISE EXCEPTION 'the row is not an object' USING ERRCODE = '22023';
      END IF;
      v_group := nullif(btrim(coalesce(r ->> 'group', '')), '');
      v_body := r - 'group' - 'template_id';
      IF v_group IS NOT NULL AND v_groups ? v_group THEN
        v_body := v_body - 'budget' || jsonb_build_object('budget_id', v_groups ->> v_group);
      END IF;
      v_offer := public._exos_offer_save(p_org, p_actor, 'import', p_api_key, NULL, v_body);
      UPDATE public.exos_offers SET import_id = v_import WHERE id = (v_offer ->> 'id')::uuid;
      IF v_group IS NOT NULL AND NOT v_groups ? v_group THEN
        v_groups := v_groups || jsonb_build_object(v_group, v_offer ->> 'budget_id');
      END IF;
      v_created := v_created || jsonb_build_array(v_offer ->> 'id');
    EXCEPTION WHEN others THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row', i, 'error', left(SQLERRM, 300)));
    END;
  END LOOP;
  UPDATE public.exos_offer_imports SET
    created_count = jsonb_array_length(v_created), errors = v_errors,
    status = CASE WHEN jsonb_array_length(v_errors) = 0 THEN 'completed'
                  WHEN jsonb_array_length(v_created) = 0 THEN 'failed' ELSE 'partial' END
  WHERE id = v_import;
  RETURN (SELECT to_jsonb(x) - 'org_id' FROM public.exos_offer_imports x WHERE x.id = v_import)
         || jsonb_build_object('offer_ids', v_created);
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_import(uuid, uuid, text, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_import(uuid, uuid, text, uuid, text, jsonb) TO service_role;

-- ---- Signed-in wrappers (owner / manager of the offer's org) ---------------
-- An unknown offer and another org's offer get the same 42501.
CREATE OR REPLACE FUNCTION public._exos_offer_org_for_staff(p_offer_id uuid)
RETURNS uuid LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_offers WHERE id = p_offer_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN v_org;
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_org_for_staff(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_offer_create(p_org_id uuid, p_offer jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager']);
  RETURN public._exos_offer_save(p_org_id, auth.uid(), 'dashboard', NULL, NULL, p_offer);
END $$;

CREATE OR REPLACE FUNCTION public.exos_offer_update(p_offer_id uuid, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_offer_save(public._exos_offer_org_for_staff(p_offer_id), auth.uid(), 'dashboard', NULL, p_offer_id, p_patch);
END $$;

CREATE OR REPLACE FUNCTION public.exos_offer_send(p_offer_id uuid, p_to text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_offer_send(public._exos_offer_org_for_staff(p_offer_id), auth.uid(), p_offer_id, p_to);
END $$;

CREATE OR REPLACE FUNCTION public.exos_offer_record_response(p_offer_id uuid, p_action text, p_name text DEFAULT NULL,
                                                             p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_offer_record_response(public._exos_offer_org_for_staff(p_offer_id), auth.uid(), p_offer_id,
                                            p_action, p_name, p_note, 'dashboard');
END $$;

CREATE OR REPLACE FUNCTION public.exos_offer_cancel(p_offer_id uuid, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_offer_cancel(public._exos_offer_org_for_staff(p_offer_id), auth.uid(), p_offer_id, p_note);
END $$;

CREATE OR REPLACE FUNCTION public.exos_offer_delete(p_offer_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_offer_delete(public._exos_offer_org_for_staff(p_offer_id), p_offer_id);
END $$;

CREATE OR REPLACE FUNCTION public.exos_offer_pool_ensure(p_budget_id uuid, p_mode text DEFAULT NULL, p_terms jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_budgets WHERE id = p_budget_id;
  PERFORM public._exos_fin_staff(v_org, ARRAY['owner', 'manager']);
  RETURN public._exos_offer_pool_ensure(v_org, auth.uid(), p_budget_id, p_mode, p_terms);
END $$;

CREATE OR REPLACE FUNCTION public.exos_offer_import(p_org_id uuid, p_file_name text, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager']);
  RETURN public._exos_offer_import(p_org_id, auth.uid(), 'dashboard', NULL, p_file_name, p_rows);
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['exos_offer_create(uuid, jsonb)', 'exos_offer_update(uuid, jsonb)',
                           'exos_offer_send(uuid, text)', 'exos_offer_record_response(uuid, text, text, text)',
                           'exos_offer_cancel(uuid, text)', 'exos_offer_delete(uuid)',
                           'exos_offer_pool_ensure(uuid, text, jsonb)', 'exos_offer_import(uuid, text, jsonb)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon;', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated;', f);
  END LOOP;
END $$;

-- ---- The agent's link (anon; the 64-hex token is the credential) ------------
-- An offer id with the wrong token, an unknown id and a cancelled offer all
-- read as "not found".
CREATE OR REPLACE FUNCTION public._exos_offer_by_token(p_offer_id uuid, p_token text)
RETURNS public.exos_offers LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE o public.exos_offers%ROWTYPE;
BEGIN
  IF p_offer_id IS NULL OR p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'offer not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO o FROM public.exos_offers
   WHERE id = p_offer_id AND response_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     AND status IN ('sent', 'accepted', 'declined', 'expired');
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'offer not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN o;
END $$;
REVOKE ALL ON FUNCTION public._exos_offer_by_token(uuid, text) FROM PUBLIC, anon, authenticated;

-- What the agent sees: the org, the show, the act's terms, the boilerplate
-- and the budget's headline numbers; never notes, history or other offers.
CREATE OR REPLACE FUNCTION public.exos_offer_public(p_offer_id uuid, p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE o public.exos_offers%ROWTYPE;
BEGIN
  o := public._exos_offer_by_token(p_offer_id, p_token);
  RETURN jsonb_build_object(
    'id', o.id, 'title', o.title, 'status', public._exos_offer_status(o.status, o.expires_at),
    'org', (SELECT jsonb_build_object('name', g.name) FROM public.exos_orgs g WHERE g.id = o.org_id),
    'artist_name', o.artist_name, 'act_type', o.act_type, 'dates', to_jsonb(o.dates), 'currency', o.currency,
    'venue', (SELECT jsonb_build_object('name', v.name, 'room', r.name, 'timezone', v.timezone)
                FROM public.exos_venues v LEFT JOIN public.exos_venue_rooms r ON r.id = o.room_id WHERE v.id = o.venue_id),
    'terms', o.terms,
    'budget', (SELECT jsonb_build_object('capacity', b.capacity, 'average_price_cents', b.average_price_cents)
                 FROM public.exos_budgets b WHERE b.id = o.budget_id),
    'agent_name', o.agent_name, 'boilerplate', o.boilerplate, 'expires_at', o.expires_at, 'sent_at', o.sent_at,
    'response', CASE WHEN o.response IS NULL THEN NULL
                     ELSE jsonb_build_object('action', o.response -> 'action', 'name', o.response -> 'name', 'at', o.response -> 'at') END);
END $$;
REVOKE ALL ON FUNCTION public.exos_offer_public(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_offer_public(uuid, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_offer_respond(p_offer_id uuid, p_token text, p_action text, p_name text,
                                                    p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE o public.exos_offers%ROWTYPE; v_headers jsonb; v_ip text; v_ua text;
BEGIN
  o := public._exos_offer_by_token(p_offer_id, p_token);
  BEGIN
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN others THEN v_headers := NULL;
  END;
  v_ip := btrim(split_part(coalesce(v_headers ->> 'x-forwarded-for', v_headers ->> 'x-real-ip', ''), ',', 1));
  v_ua := v_headers ->> 'user-agent';
  PERFORM public._exos_offer_record_response(o.org_id, NULL, o.id, p_action, p_name, p_note, 'link',
                                             nullif(v_ip, ''), v_ua);
  RETURN public.exos_offer_public(p_offer_id, p_token);
END $$;
REVOKE ALL ON FUNCTION public.exos_offer_respond(uuid, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_offer_respond(uuid, text, text, text, text) TO anon, authenticated;

-- ===========================================================================
-- 7. Mail template: offer-sent (same additive pattern as mig 20261001101000)
-- ===========================================================================
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['offer-sent'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF v_def IS NULL THEN RETURN; END IF;
  IF strpos(v_def, '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live FROM regexp_matches(v_def, '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN RETURN; END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION SELECT unnest(v_new)
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

COMMENT ON TABLE public.exos_offers IS
  'mig 20261031100000: one act''s deal for a show (docs/offers-settlements.md). Written only by exos_offer_* / _exos_offer_*; terms canonical (_exos_deal_terms); response_token_hash has no client column grant.';
COMMENT ON TABLE public.exos_budgets IS
  'mig 20261031100000: an offer budget (Opendate v3 budget), shared by every offer on it (a lineup).';
COMMENT ON TABLE public.exos_offer_pools IS
  'mig 20261031100000: one per budget; in pool mode the shared deal pays the lineup, split by pool_share_percent.';
