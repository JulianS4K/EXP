-- ============================================================================
-- Migration 20261114110000 — Exos: event tokens (drink tickets, ride credits,
-- tasting tickets). Branch claude/exos-event-tokens. docs/pos.md "Event
-- tokens", docs/journal.md "Event tokens".
--
-- 1. A token product (exos_event_token_products): event-scoped, a name and a
--    unit ("Drink token", "drink"), a price per credit, up to 5 bundles
--    ({credits, price_cents}, e.g. 10 for 4500), a max per order (credits),
--    an expiry grace after the event's end, and whether unused credits are
--    refundable. Owners / managers save it (exos_event_token_product_save).
--    Each offer (one credit, each bundle) is an ordinary add-on online
--    (exos_event_addons.token_product_id / token_credits) and an ordinary POS
--    item at the door (exos_pos_items.token_product_id / token_credits), kept
--    in step by _exos_event_token_sync_offers. So checkout, the all-in price,
--    passed-on fees, Stripe, fulfilment, refunds, the POS drawer and the POS
--    settlement are the existing paths; nothing in them is patched. Client
--    writes to a token add-on / POS item are refused (guard triggers): only
--    the product save changes them.
-- 2. Where credits live (exos_event_token_cards): on the buyer's ticket (one
--    card per ticket; scanned with the ticket's own rotating T- code) or on a
--    token code (16 characters + Luhn, the gift card alphabet; only its
--    SHA-256 kept; shown once; a wristband / paper QR "K-<code>") for walk-ups
--    without a ticket. Credits are held in lots (exos_event_token_lots), one
--    per purchase, so a refund of unused credits goes back to the payment that
--    bought them. Spends take the oldest lot first.
--    Why not the add-on entry codes (exos_addon_passes): a pass is one unit,
--    one owner, used once at a list; credits are a balance spent many times,
--    partly, by several staff, and walk-ups have no account to own a pass.
--    Cards reuse the pass idea (the ticket's own signed code) without its
--    one-unit / one-scan model.
-- 3. Every balance change is one row of exos_event_token_ledger (purchase,
--    spend, undo, refund, expire) with its value in cents and the balance
--    after; append-only. Overspends found when an offline device syncs are
--    exos_event_token_exceptions rows ('overspent': what was short), never a
--    negative balance (lots CHECK credits_left >= 0). A replay the server
--    refuses (code no longer valid) is a 'rejected' exception.
-- 4. Scan to spend (exos_event_token_spend): door staff (owner / manager /
--    scanner who may work the event) pick the product and the amount (1-50)
--    and scan; the card is locked, the balance checked, the lots taken, one
--    ledger row written. Idempotent on the device's client ref. Offline: the
--    device keeps its own ledger and an offline cap per code (the balance at
--    its last sync, exos_event_token_roster) and replays with p_offline_at;
--    the server takes what is left and records the rest as 'overspent'.
--    The claimed offline time is bounded by the server: not before the
--    member's last roster download (exos_event_token_roster_syncs) nor 12
--    hours back, not in the future; outside that the replay is a 'rejected'
--    exception and the balance is untouched, so a stale ticket code or a
--    backdated spend past the expiry can't pass.
--    Undo (exos_event_token_undo): owner / manager, a reason, once per spend,
--    within 24 hours and before the tokens expire; after the event's end the
--    owner only. Audited (token.undo). Lookups and spends are rate-limited per member
--    (120 a minute; a miss counts: misses answer instead of raising).
-- 5. Buying: online through the add-ons (a trigger on exos_order_addons puts
--    the credits on the order's ticket, the buyer's own first);
--    exos_event_token_order_check (service role, exos-checkout) refuses an
--    order over the product's max before Stripe. At the door
--    (exos_event_token_pos_sell): a POS order with the offer's item, cash into
--    the seller's drawer or a comp (owner / manager), onto a scanned ticket /
--    code or a new code; idempotent on the order key; audited (token.sell).
--    A POS void / refund of such a sale takes its credits back, and is refused
--    once any of them were spent (refund the unused ones instead).
-- 6. Expiry and refunds: credits can't be spent after the event's end (ends_at,
--    else starts_at + 12 hours) + the grace. Not refundable: the expiry job
--    (exos_event_token_expire, owner / manager; _exos_event_token_expire_due
--    for an inactive cron) writes 'expire' rows (breakage). Refundable:
--    exos_event_token_refund_unused (owner / manager, audited token.refund).
--    Online, the lot goes 'refund_pending' (not spendable, still on the
--    books) with a key for the existing partial refund (exos-refund
--    amount_cents); only when that request succeeds does a trigger on
--    exos_refund_requests close the lot (ledger + journal). A failed request
--    leaves it pending: refund again (a new key) or put it back
--    (exos_event_token_refund_cancel, audited token.refund_cancel). At the
--    door it pays the cash back out of a drawer (exos_pos_paid_outs kind
--    'refund'), in the same transaction. A full order refund (any path) takes
--    the remaining credits of its lines. Labels: "Event tokens, no cash value,
--    valid for <event> only"; the rule is in every offer's description.
-- 7. Journal (docs/journal.md): tokens are deferred revenue. New accounts
--    2310 event_tokens_outstanding (liability), 4050 event_token_redemptions,
--    4060 event_token_breakage. The sale itself posts as today (online: the
--    order's sale entry, face to 4000; door: pos_cash_sale, 4020); the
--    ledger's purchase row moves that value to 2310 (token_purchase); a spend
--    moves it to 4050 (token_spend), an undo back (token_undo), an expiry to
--    4060 (token_expire), a refund of unused credits back to the sale account
--    (token_refund; the money itself posts from the refund / paid-out row).
-- 8. Report (exos_event_token_report): per product sold / redeemed / expired /
--    refunded / outstanding credits and cents, the exceptions, the lots still
--    refundable; owner / manager / finance. CSV / XLSX in the browser, logged
--    as export.run (exos_audit_export kind 'event_tokens').
--
-- Touches:  C: TABLE exos_event_token_products, exos_event_token_cards,
--              exos_event_token_lots, exos_event_token_ledger,
--              exos_event_token_exceptions, exos_event_token_roster_syncs
--           T: exos_refund_requests (AFTER succeeded: closes a pending token refund)
--           W: TABLE exos_event_addons (+token_product_id, +token_credits),
--              exos_pos_items (+token_product_id, +token_credits),
--              exos_journal_entries (source check + exos_event_token_ledger)
--           R: FUNCTION exos_journal_accounts, _exos_journal_account_ok
--              (CREATE OR REPLACE: + the three accounts; nothing patches them)
--           P: _exos_journal_backfill (marker /* exos: journal event tokens */),
--              exos_audit_export (markers /* exos: event token export kinds */,
--              /* exos: event token export cap */)
--           C: FUNCTION (authenticated, role-checked inside)
--              exos_event_token_products, exos_event_token_product_save,
--              exos_event_token_lookup, exos_event_token_spend,
--              exos_event_token_undo, exos_event_token_roster,
--              exos_event_token_pos_sell, exos_event_token_card_reissue,
--              exos_event_token_refund_unused, exos_event_token_refund_cancel,
--              exos_event_token_expire,
--              exos_event_token_report, exos_my_event_tokens;
--              (service role) exos_event_token_order_check,
--              _exos_event_token_expire_due, exos_journal_post_event_token and
--              the helpers / triggers named below
-- Audit:    token.configure, token.sell, token.overspent, token.undo,
--           token.refund, token.refund_cancel, token.expire, token.reissue
--           (8 functions)
-- Grants:   nothing for anon (H3 unchanged); tables: RLS on, SELECT only
--           (owner / manager / finance; door staff read products), no client
--           writes, no code hash readable by clients.
-- Cron:     exos-event-token-expire, hourly, created INACTIVE.
-- Pre-reqs: 20261107100000 (POS walk-up: drawers, paid-outs),
--           20261110100000 + 20261111130000 (journal), 20261109100000 +
--           20261113120000 (exos_audit_export), 20261019100000 (door keys).
-- Additive and re-run safe. Not applied; prod apply needs operator OK.
-- ROLLBACK: drop the cron, the triggers, the functions, the five tables and
--           the four columns; re-run 20261110100000's exos_journal_accounts /
--           _exos_journal_account_ok / _exos_journal_backfill, then
--           20261111130000 (source check, backfill patch) and 20261113120000
--           (export kinds). Posted entries stay (append-only) and balance.
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
-- 1. Tables
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_event_token_products (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  unit_label      text NOT NULL DEFAULT 'token' CHECK (char_length(btrim(unit_label)) BETWEEN 1 AND 20),
  price_cents     integer NOT NULL CHECK (price_cents BETWEEN 1 AND 100000),
  -- [{"credits": 10, "price_cents": 4500}, ...]: up to 5, 2-500 credits each.
  bundles         jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(bundles) = 'array'),
  max_per_order   integer NOT NULL DEFAULT 50 CHECK (max_per_order BETWEEN 1 AND 500),
  refundable      boolean NOT NULL DEFAULT false,
  grace_hours     integer NOT NULL DEFAULT 0 CHECK (grace_hours BETWEEN 0 AND 720),
  active          boolean NOT NULL DEFAULT true,
  sort_order      integer NOT NULL DEFAULT 0,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_token_products_event_idx ON public.exos_event_token_products (event_id, sort_order);
CREATE INDEX IF NOT EXISTS exos_event_token_products_org_idx ON public.exos_event_token_products (org_id);
COMMENT ON TABLE public.exos_event_token_products IS
  'Event tokens: drink tickets, ride credits, tasting tickets (mig 20261114110000). Each offer (1 credit, each bundle) is an '
  'add-on online and a POS item at the door (token_product_id / token_credits). Saved only by exos_event_token_product_save.';

CREATE TABLE IF NOT EXISTS public.exos_event_token_cards (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id     uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  ticket_id    uuid UNIQUE REFERENCES public.exos_tickets (id) ON DELETE SET NULL,
  code_hash    text UNIQUE CHECK (code_hash IS NULL OR code_hash ~ '^[0-9a-f]{64}$'),
  code_last4   text CHECK (code_last4 IS NULL OR code_last4 ~ '^[A-Z2-9]{4}$'),
  order_ref    text,
  created_via  text NOT NULL CHECK (created_via IN ('online', 'pos')),
  created_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_event_token_cards_anchor_chk CHECK (ticket_id IS NOT NULL OR code_hash IS NOT NULL OR order_ref IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_event_token_cards_event_idx ON public.exos_event_token_cards (event_id);
CREATE INDEX IF NOT EXISTS exos_event_token_cards_org_idx ON public.exos_event_token_cards (org_id);
COMMENT ON TABLE public.exos_event_token_cards IS
  'Where event token credits are held: a ticket (scanned with its own T- code) or a token code (SHA-256 only; shown once). mig 20261114110000.';

CREATE TABLE IF NOT EXISTS public.exos_event_token_lots (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id       uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  card_id        uuid NOT NULL REFERENCES public.exos_event_token_cards (id) ON DELETE CASCADE,
  product_id     uuid NOT NULL REFERENCES public.exos_event_token_products (id) ON DELETE CASCADE,
  source         text NOT NULL CHECK (source IN ('online', 'pos', 'comp')),
  order_addon_id uuid UNIQUE REFERENCES public.exos_order_addons (id) ON DELETE SET NULL,
  pos_order_id   uuid REFERENCES public.exos_pos_orders (id) ON DELETE SET NULL,
  session_id     text,
  credits_bought integer NOT NULL CHECK (credits_bought BETWEEN 1 AND 25000),
  value_cents    integer NOT NULL CHECK (value_cents >= 0),
  credits_left   integer NOT NULL,
  value_left     integer NOT NULL,
  -- refund_pending: an online refund of the unused tokens was asked for and
  -- hasn't succeeded yet: not spendable, not yet off the books (S2 below).
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'refund_pending', 'refunded', 'expired')),
  refund_key     text UNIQUE CHECK (refund_key IS NULL OR refund_key ~ '^evtoken-refund:[0-9a-f-]{36}:[0-9]{1,4}$'),
  refund_attempt integer NOT NULL DEFAULT 0 CHECK (refund_attempt BETWEEN 0 AND 9999),
  refund_by      uuid,
  refund_reason  text CHECK (refund_reason IS NULL OR char_length(refund_reason) <= 300),
  -- clock_timestamp: lots bought in one order still spend in purchase order.
  created_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  -- Never a negative balance: an overspend is an exception row instead.
  CONSTRAINT exos_event_token_lots_left_chk CHECK (credits_left BETWEEN 0 AND credits_bought
                                                   AND value_left BETWEEN 0 AND value_cents
                                                   AND (credits_left > 0 OR value_left = 0))
);
CREATE INDEX IF NOT EXISTS exos_event_token_lots_card_idx ON public.exos_event_token_lots (card_id, product_id, created_at);
CREATE INDEX IF NOT EXISTS exos_event_token_lots_event_idx ON public.exos_event_token_lots (event_id, product_id);
CREATE INDEX IF NOT EXISTS exos_event_token_lots_pos_idx ON public.exos_event_token_lots (pos_order_id) WHERE pos_order_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_event_token_lots_org_idx ON public.exos_event_token_lots (org_id);

CREATE TABLE IF NOT EXISTS public.exos_event_token_ledger (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id      uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  card_id       uuid NOT NULL REFERENCES public.exos_event_token_cards (id) ON DELETE CASCADE,
  product_id    uuid NOT NULL REFERENCES public.exos_event_token_products (id) ON DELETE CASCADE,
  lot_id        uuid REFERENCES public.exos_event_token_lots (id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('purchase', 'spend', 'undo', 'refund', 'expire')),
  credits       integer NOT NULL CHECK (credits <> 0),
  amount_cents  integer NOT NULL,
  balance_after integer NOT NULL CHECK (balance_after >= 0),
  -- A spend: the lots it took [{"lot", "credits", "value"}]; an undo gives them back.
  detail        jsonb,
  client_ref    uuid,
  device        text CHECK (device IS NULL OR char_length(device) <= 60),
  actor         uuid,
  reason        text CHECK (reason IS NULL OR char_length(reason) <= 300),
  offline_at    timestamptz,
  undoes        bigint REFERENCES public.exos_event_token_ledger (id) ON DELETE CASCADE,
  created_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT exos_event_token_ledger_sign_chk CHECK (
    CASE kind WHEN 'purchase' THEN credits > 0 AND amount_cents >= 0
              WHEN 'undo' THEN credits > 0 AND amount_cents >= 0 AND undoes IS NOT NULL
              ELSE credits < 0 AND amount_cents <= 0 END)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_event_token_ledger_ref_uq ON public.exos_event_token_ledger (org_id, client_ref) WHERE client_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_event_token_ledger_undo_uq ON public.exos_event_token_ledger (undoes) WHERE kind = 'undo';
CREATE UNIQUE INDEX IF NOT EXISTS exos_event_token_ledger_lot_uq ON public.exos_event_token_ledger (lot_id, kind)
  WHERE kind IN ('purchase', 'refund', 'expire');
CREATE INDEX IF NOT EXISTS exos_event_token_ledger_card_idx ON public.exos_event_token_ledger (card_id, product_id, id);
CREATE INDEX IF NOT EXISTS exos_event_token_ledger_event_idx ON public.exos_event_token_ledger (event_id, product_id, kind);
CREATE INDEX IF NOT EXISTS exos_event_token_ledger_org_idx ON public.exos_event_token_ledger (org_id);
CREATE INDEX IF NOT EXISTS exos_event_token_ledger_lot_idx ON public.exos_event_token_ledger (lot_id) WHERE lot_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_event_token_exceptions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id      uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  card_id       uuid REFERENCES public.exos_event_token_cards (id) ON DELETE SET NULL,
  product_id    uuid NOT NULL REFERENCES public.exos_event_token_products (id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('overspent', 'rejected')),
  credits_asked integer NOT NULL CHECK (credits_asked BETWEEN 1 AND 50),
  credits_short integer NOT NULL CHECK (credits_short BETWEEN 1 AND 50),
  reason        text CHECK (reason IS NULL OR char_length(reason) <= 60),
  ledger_id     bigint REFERENCES public.exos_event_token_ledger (id) ON DELETE SET NULL,
  client_ref    uuid NOT NULL,
  device        text CHECK (device IS NULL OR char_length(device) <= 60),
  actor         uuid,
  offline_at    timestamptz NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, client_ref)
);
CREATE INDEX IF NOT EXISTS exos_event_token_exceptions_event_idx ON public.exos_event_token_exceptions (event_id, created_at);
CREATE INDEX IF NOT EXISTS exos_event_token_exceptions_card_idx ON public.exos_event_token_exceptions (card_id) WHERE card_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_event_token_exceptions_org_idx ON public.exos_event_token_exceptions (org_id);

-- When each member last downloaded the event's offline roster (server time).
-- An offline replay may not claim a time before it, nor more than 12 hours
-- back: the client's clock never decides a code window or the expiry.
CREATE TABLE IF NOT EXISTS public.exos_event_token_roster_syncs (
  event_id  uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  user_id   uuid NOT NULL,
  org_id    uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  synced_at timestamptz NOT NULL,
  PRIMARY KEY (event_id, user_id)
);
CREATE INDEX IF NOT EXISTS exos_event_token_roster_syncs_org_idx ON public.exos_event_token_roster_syncs (org_id);
ALTER TABLE public.exos_event_token_roster_syncs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_event_token_roster_syncs FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_event_token_roster_syncs TO service_role;

-- updated_at
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_event_token_products', 'exos_event_token_cards', 'exos_event_token_lots'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at()',
                   t || '_touch', t);
  END LOOP;
END $$;

-- The ledger and the exceptions are append-only (a cascade from deleting the
-- org or event still removes them).
CREATE OR REPLACE FUNCTION public._exos_event_token_append_only()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  -- Only a foreign-key action (deleting the org / event, SET NULL of a
  -- deleted card or ledger row) changes a row.
  IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND pg_trigger_depth() > 1 AND (to_jsonb(NEW) - 'card_id' - 'ledger_id') = (to_jsonb(OLD) - 'card_id' - 'ledger_id') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '55000';
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_append_only() FROM PUBLIC, anon, authenticated;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_event_token_ledger', 'exos_event_token_exceptions'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_append_only', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public._exos_event_token_append_only()',
                   t || '_append_only', t);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_no_truncate', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public._exos_event_token_append_only()',
                   t || '_no_truncate', t);
  END LOOP;
END $$;

-- RLS: reads only. Door staff read the products (the door's picker);
-- owner / manager / finance read everything (the report). No client writes.
ALTER TABLE public.exos_event_token_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_token_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_token_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_token_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_token_exceptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_event_token_products_sel ON public.exos_event_token_products;
CREATE POLICY exos_event_token_products_sel ON public.exos_event_token_products FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance'])
         OR public.exos_can_door_event(event_id));
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_event_token_cards', 'exos_event_token_lots', 'exos_event_token_ledger',
                           'exos_event_token_exceptions'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_sel', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.exos_is_admin() '
                   'OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']))', t || '_sel', t);
  END LOOP;
END $$;
REVOKE ALL ON public.exos_event_token_products, public.exos_event_token_cards, public.exos_event_token_lots,
              public.exos_event_token_ledger, public.exos_event_token_exceptions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_event_token_products, public.exos_event_token_lots, public.exos_event_token_ledger,
                public.exos_event_token_exceptions TO authenticated;
-- Never the code hash.
GRANT SELECT (id, org_id, event_id, ticket_id, code_last4, order_ref, created_via, created_by, created_at, updated_at)
  ON public.exos_event_token_cards TO authenticated;
GRANT ALL ON public.exos_event_token_products, public.exos_event_token_cards, public.exos_event_token_lots,
             public.exos_event_token_ledger, public.exos_event_token_exceptions TO service_role;
REVOKE ALL ON SEQUENCE public.exos_event_token_ledger_id_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.exos_event_token_ledger_id_seq TO service_role;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_event_token_products', 'exos_event_token_cards', 'exos_event_token_lots',
                               'exos_event_token_ledger', 'exos_event_token_exceptions', 'exos_event_token_roster_syncs'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- The offers: add-ons online, POS items at the door.
ALTER TABLE public.exos_event_addons ADD COLUMN IF NOT EXISTS token_product_id uuid
  REFERENCES public.exos_event_token_products (id) ON DELETE CASCADE;
ALTER TABLE public.exos_event_addons ADD COLUMN IF NOT EXISTS token_credits integer;
ALTER TABLE public.exos_pos_items ADD COLUMN IF NOT EXISTS token_product_id uuid
  REFERENCES public.exos_event_token_products (id) ON DELETE SET NULL;
ALTER TABLE public.exos_pos_items ADD COLUMN IF NOT EXISTS token_credits integer;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_event_addons_token_chk') THEN
    ALTER TABLE public.exos_event_addons ADD CONSTRAINT exos_event_addons_token_chk
      CHECK ((token_product_id IS NULL) = (token_credits IS NULL) AND (token_credits IS NULL OR token_credits BETWEEN 1 AND 500));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_pos_items_token_chk') THEN
    ALTER TABLE public.exos_pos_items ADD CONSTRAINT exos_pos_items_token_chk
      CHECK ((token_credits IS NULL OR token_credits BETWEEN 1 AND 500)
             AND (token_product_id IS NULL OR (token_credits IS NOT NULL AND category = 'merch' AND event_id IS NOT NULL)));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS exos_event_addons_token_uq ON public.exos_event_addons (token_product_id, token_credits)
  WHERE token_product_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_pos_items_token_uq ON public.exos_pos_items (token_product_id, token_credits)
  WHERE token_product_id IS NOT NULL;
COMMENT ON COLUMN public.exos_event_addons.token_product_id IS
  'An event token offer (mig 20261114110000): buying it puts token_credits x quantity credits on the order''s ticket. Written only by the product save.';
COMMENT ON COLUMN public.exos_pos_items.token_product_id IS
  'An event token offer at the door (mig 20261114110000), sold only through exos_event_token_pos_sell.';

-- ===========================================================================
-- 2. Guards: the offers change only through the product save, and a token
--    item is rung only by the token sale.
-- ===========================================================================
-- Both guards run as the caller (SECURITY INVOKER) and let a write through
-- only when the transaction-local flag is set AND the statement runs as the
-- role that owns the token functions, i.e. inside the definer function that
-- set the flag. A client (authenticated, service_role over the API) that sets
-- the flag itself still runs as itself and is refused.
CREATE OR REPLACE FUNCTION public._exos_event_token_is_writer(p_flag text, p_value text)
RETURNS boolean LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(current_setting(p_flag, true), '') = p_value AND p_value <> ''
     AND current_user = (SELECT pg_get_userbyid(p.proowner) FROM pg_proc p
                          WHERE p.oid = to_regprocedure('public._exos_event_token_sync_offers(uuid)'))
$$;
REVOKE ALL ON FUNCTION public._exos_event_token_is_writer(text, text) FROM PUBLIC, anon;
-- The guards call it as the writing role, so signed-in clients need EXECUTE;
-- it says only whether the caller is the token functions' owner.
GRANT EXECUTE ON FUNCTION public._exos_event_token_is_writer(text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._exos_tg_event_token_offer_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
BEGIN
  IF public._exos_event_token_is_writer('exos.token_sync', 'on') THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.token_product_id IS NOT NULL OR NEW.token_credits IS NOT NULL THEN
      RAISE EXCEPTION 'event token offers are set on the token product' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.token_product_id IS NULL AND NEW.token_product_id IS NULL AND NEW.token_credits IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_TABLE_NAME = 'exos_event_addons' THEN
    IF (NEW.event_id, NEW.name, NEW.description, NEW.price, NEW.capacity, NEW.max_per_order, NEW.visibility,
        NEW.tax_rate_id, NEW.separate_access_barcode, NEW.token_product_id, NEW.token_credits)
       IS DISTINCT FROM
       (OLD.event_id, OLD.name, OLD.description, OLD.price, OLD.capacity, OLD.max_per_order, OLD.visibility,
        OLD.tax_rate_id, OLD.separate_access_barcode, OLD.token_product_id, OLD.token_credits) THEN
      RAISE EXCEPTION 'event token offers are set on the token product' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF (NEW.org_id, NEW.event_id, NEW.category, NEW.name, NEW.price_cents, NEW.tax_rule_id, NEW.tier_id, NEW.active,
        NEW.token_product_id, NEW.token_credits)
       IS DISTINCT FROM
       (OLD.org_id, OLD.event_id, OLD.category, OLD.name, OLD.price_cents, OLD.tax_rule_id, OLD.tier_id, OLD.active,
        OLD.token_product_id, OLD.token_credits)
       AND NOT (OLD.token_product_id IS NOT NULL AND NEW.token_product_id IS NULL AND pg_trigger_depth() > 1) THEN
      RAISE EXCEPTION 'event token offers are set on the token product' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_token_offer_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_event_addons_token_guard ON public.exos_event_addons;
CREATE TRIGGER exos_event_addons_token_guard BEFORE INSERT OR UPDATE ON public.exos_event_addons
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_token_offer_guard();
DROP TRIGGER IF EXISTS exos_pos_items_token_guard ON public.exos_pos_items;
CREATE TRIGGER exos_pos_items_token_guard BEFORE INSERT OR UPDATE ON public.exos_pos_items
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_token_offer_guard();

-- Invoker: whoever may insert a line at the event (exos_pos_can_ring) may
-- read the event's items, so the lookup sees every token item.
CREATE OR REPLACE FUNCTION public._exos_tg_event_token_line_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.exos_pos_items i WHERE i.id = NEW.item_id AND i.token_product_id IS NOT NULL)
     AND NOT public._exos_event_token_is_writer('exos.token_sale', NEW.order_id::text) THEN
    RAISE EXCEPTION 'event tokens are sold with the token sale (it puts the credits on a code)' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_token_line_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_lines_token_guard ON public.exos_pos_order_lines;
CREATE TRIGGER exos_pos_lines_token_guard BEFORE INSERT ON public.exos_pos_order_lines
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_token_line_guard();

-- ===========================================================================
-- 3. Helpers (service role only)
-- ===========================================================================
-- A token code as typed or scanned ("K-ABCD...", "ABCD-EFGH-...") -> the
-- 16 characters, or NULL.
CREATE OR REPLACE FUNCTION public._exos_event_token_code(p_payload text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN public.exos_gift_card_check_ok(x) THEN public.exos_gift_card_normalize(x) END
    FROM (SELECT CASE WHEN upper(left(btrim(coalesce(p_payload, '')), 2)) = 'K-' THEN substr(btrim(p_payload), 3)
                      ELSE btrim(coalesce(p_payload, '')) END AS x) s;
$$;
CREATE OR REPLACE FUNCTION public._exos_event_token_hash(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT encode(sha256(convert_to('exos-event-token:' || p_code, 'UTF8')), 'hex');
$$;
REVOKE ALL ON FUNCTION public._exos_event_token_code(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_event_token_hash(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_code(text) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_event_token_hash(text) TO service_role;

-- When credits of this product stop being spendable: the event's end (else
-- its start + 12 hours) + the grace. NULL: the event has no date.
CREATE OR REPLACE FUNCTION public._exos_event_token_expires_at(p_product uuid)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(e.ends_at, e.starts_at + interval '12 hours') + make_interval(hours => p.grace_hours)
    FROM public.exos_event_token_products p JOIN public.exos_events e ON e.id = p.event_id
   WHERE p.id = p_product
$$;
REVOKE ALL ON FUNCTION public._exos_event_token_expires_at(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_expires_at(uuid) TO service_role;

-- The label every offer and receipt carries.
CREATE OR REPLACE FUNCTION public._exos_event_token_rule(p_product uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT 'Event tokens, no cash value, valid for ' || left(e.name, 120) || ' only. '
         || 'They expire ' || CASE WHEN p.grace_hours = 0 THEN 'when the event ends'
                                   ELSE p.grace_hours || ' hours after the event ends' END
         || CASE WHEN p.refundable THEN '; unused tokens are refunded on request to how you paid.'
                 ELSE '; unused tokens are not refundable.' END
    FROM public.exos_event_token_products p JOIN public.exos_events e ON e.id = p.event_id
   WHERE p.id = p_product
$$;
REVOKE ALL ON FUNCTION public._exos_event_token_rule(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_rule(uuid) TO service_role;

-- The product's offers: [{credits, price_cents}], one credit first.
CREATE OR REPLACE FUNCTION public._exos_event_token_offers(p public.exos_event_token_products)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_array(jsonb_build_object('credits', 1, 'price_cents', p.price_cents))
         || coalesce((SELECT jsonb_agg(jsonb_build_object('credits', (b ->> 'credits')::int, 'price_cents', (b ->> 'price_cents')::int)
                                       ORDER BY (b ->> 'credits')::int)
                        FROM jsonb_array_elements(p.bundles) b), '[]'::jsonb)
$$;
REVOKE ALL ON FUNCTION public._exos_event_token_offers(public.exos_event_token_products) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_offers(public.exos_event_token_products) TO service_role;

-- Keep the add-ons and POS items in step with the product.
CREATE OR REPLACE FUNCTION public._exos_event_token_sync_offers(p_product uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  p      public.exos_event_token_products%ROWTYPE;
  o      jsonb;
  v_c    int;
  v_pr   int;
  v_name text;
  v_rule text;
  v_keep int[] := '{}';
BEGIN
  SELECT * INTO p FROM public.exos_event_token_products WHERE id = p_product;
  IF p.id IS NULL THEN
    RETURN;
  END IF;
  v_rule := public._exos_event_token_rule(p.id);
  PERFORM set_config('exos.token_sync', 'on', true);
  FOR o IN SELECT * FROM jsonb_array_elements(public._exos_event_token_offers(p)) LOOP
    v_c := (o ->> 'credits')::int;
    v_pr := (o ->> 'price_cents')::int;
    v_keep := v_keep || v_c;
    v_name := CASE WHEN v_c = 1 THEN p.name ELSE v_c || ' × ' || p.name END;
    UPDATE public.exos_event_addons
       SET name = left(v_name, 120), description = v_rule, price = round(v_pr::numeric / 100, 2), capacity = 100000,
           max_per_order = least(50, greatest(1, p.max_per_order / v_c)),
           visibility = CASE WHEN p.active AND v_c <= p.max_per_order THEN 'public' ELSE 'hidden' END,
           tax_rate_id = NULL, separate_access_barcode = false, sort_order = 1000 + p.sort_order * 10 + least(v_c, 9)
     WHERE token_product_id = p.id AND token_credits = v_c;
    IF NOT FOUND THEN
      INSERT INTO public.exos_event_addons (event_id, name, description, price, capacity, max_per_order, visibility,
                                            sort_order, token_product_id, token_credits)
      VALUES (p.event_id, left(v_name, 120), v_rule, round(v_pr::numeric / 100, 2), 100000,
              least(50, greatest(1, p.max_per_order / v_c)),
              CASE WHEN p.active AND v_c <= p.max_per_order THEN 'public' ELSE 'hidden' END,
              1000 + p.sort_order * 10 + least(v_c, 9), p.id, v_c);
    END IF;
    UPDATE public.exos_pos_items
       SET name = left(v_name, 120), price_cents = v_pr, active = p.active AND v_c <= p.max_per_order, tax_rule_id = NULL
     WHERE token_product_id = p.id AND token_credits = v_c;
    IF NOT FOUND THEN
      INSERT INTO public.exos_pos_items (org_id, event_id, category, name, price_cents, active, sort_order,
                                         token_product_id, token_credits)
      VALUES (p.org_id, p.event_id, 'merch', left(v_name, 120), v_pr, p.active AND v_c <= p.max_per_order,
              1000 + p.sort_order * 10 + least(v_c, 9), p.id, v_c);
    END IF;
  END LOOP;
  -- A bundle taken off: no longer sold (sold rows keep their history).
  UPDATE public.exos_event_addons SET visibility = 'hidden'
   WHERE token_product_id = p.id AND NOT (token_credits = ANY (v_keep)) AND visibility <> 'hidden';
  UPDATE public.exos_pos_items SET active = false
   WHERE token_product_id = p.id AND NOT (token_credits = ANY (v_keep)) AND active;
  PERFORM set_config('exos.token_sync', '', true);
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_sync_offers(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_sync_offers(uuid) TO service_role;

-- A card's balance of one product (the caller holds the card's lock when it
-- matters).
CREATE OR REPLACE FUNCTION public._exos_event_token_balance(p_card uuid, p_product uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(sum(credits_left), 0)::int FROM public.exos_event_token_lots
   WHERE card_id = p_card AND product_id = p_product AND status = 'active'
$$;
REVOKE ALL ON FUNCTION public._exos_event_token_balance(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_balance(uuid, uuid) TO service_role;

-- A card's balances: [{product_id, name, unit_label, credits, expires_at, refundable}].
CREATE OR REPLACE FUNCTION public._exos_event_token_balances(p_card uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'product_id', p.id, 'name', p.name, 'unit_label', p.unit_label, 'credits', x.credits,
           'expires_at', public._exos_event_token_expires_at(p.id), 'refundable', p.refundable)
           ORDER BY p.sort_order, p.name), '[]'::jsonb)
    FROM (SELECT l.product_id, sum(l.credits_left)::int AS credits FROM public.exos_event_token_lots l
           WHERE l.card_id = p_card AND l.status = 'active' GROUP BY l.product_id) x
    JOIN public.exos_event_token_products p ON p.id = x.product_id
$$;
REVOKE ALL ON FUNCTION public._exos_event_token_balances(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_balances(uuid) TO service_role;

-- The card of a ticket (made on first use).
CREATE OR REPLACE FUNCTION public._exos_event_token_ticket_card(p_ticket uuid, p_via text, p_actor uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; t public.exos_tickets%ROWTYPE;
BEGIN
  SELECT id INTO v_id FROM public.exos_event_token_cards WHERE ticket_id = p_ticket;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket;
  INSERT INTO public.exos_event_token_cards (org_id, event_id, ticket_id, order_ref, created_via, created_by)
  VALUES (t.org_id, t.event_id, t.id, t.order_ref, p_via, p_actor)
  ON CONFLICT (ticket_id) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM public.exos_event_token_cards WHERE ticket_id = p_ticket;
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_ticket_card(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_ticket_card(uuid, text, uuid) TO service_role;

-- A scanned code -> the event's card. {ok, card_id, ticket_id, reason}.
-- T- codes: the ticket's rotating code (day-key MAC, +-2 buckets of p_at);
-- K- / typed codes: the token code's hash. Nothing about another event or
-- org is ever said: those read 'not-found'.
CREATE OR REPLACE FUNCTION public._exos_event_token_resolve(p_event uuid, p_payload text, p_at timestamptz, p_make boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_payload text := btrim(coalesce(p_payload, ''));
  v_parts   text[];
  v_ticket  uuid;
  v_bkt     bigint;
  v_cur     bigint := floor(extract(epoch FROM coalesce(p_at, clock_timestamp())) * 1000 / 30000);
  t         public.exos_tickets%ROWTYPE;
  v_code    text;
  v_card    uuid;
BEGIN
  IF v_payload = '' OR length(v_payload) > 300 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  IF upper(left(v_payload, 2)) = 'T-' THEN
    v_parts := string_to_array(substring(v_payload FROM 3), ':');
    BEGIN
      IF array_length(v_parts, 1) <> 4 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END IF;
      v_ticket := v_parts[1]::uuid;
      v_bkt := v_parts[3]::bigint;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    END;
    SELECT * INTO t FROM public.exos_tickets WHERE id = v_ticket;
    IF t.id IS NULL OR t.event_id IS DISTINCT FROM p_event THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
    END IF;
    IF t.owner_id IS NULL OR v_parts[2] <> t.owner_id::text
       OR public._exos_door_code_mac(t.id, t.owner_id, v_bkt, coalesce(t.barcode_secret, '')) IS DISTINCT FROM v_parts[4] THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    END IF;
    IF abs(v_cur - v_bkt) > 2 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-expired');
    END IF;
    IF t.status NOT IN ('active', 'used') THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'ticket-voided');
    END IF;
    SELECT id INTO v_card FROM public.exos_event_token_cards WHERE ticket_id = t.id;
    IF v_card IS NULL AND p_make THEN
      v_card := public._exos_event_token_ticket_card(t.id, 'pos', auth.uid());
    END IF;
    RETURN jsonb_build_object('ok', true, 'card_id', v_card, 'ticket_id', t.id);
  END IF;
  v_code := public._exos_event_token_code(v_payload);
  IF v_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  SELECT id INTO v_card FROM public.exos_event_token_cards
   WHERE code_hash = public._exos_event_token_hash(v_code) AND event_id = p_event;
  IF v_card IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  RETURN jsonb_build_object('ok', true, 'card_id', v_card, 'ticket_id', NULL);
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_resolve(uuid, text, timestamptz, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_resolve(uuid, text, timestamptz, boolean) TO service_role;

-- A new lot and its purchase row (the card is locked by the caller).
CREATE OR REPLACE FUNCTION public._exos_event_token_add_lot(
  p_card uuid, p_product uuid, p_source text, p_credits int, p_value int, p_order_addon uuid, p_pos_order uuid,
  p_session text, p_actor uuid, p_device text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_event_token_cards%ROWTYPE; v_lot uuid;
BEGIN
  SELECT * INTO c FROM public.exos_event_token_cards WHERE id = p_card;
  INSERT INTO public.exos_event_token_lots (org_id, event_id, card_id, product_id, source, order_addon_id, pos_order_id,
                                            session_id, credits_bought, value_cents, credits_left, value_left)
  VALUES (c.org_id, c.event_id, c.id, p_product, p_source, p_order_addon, p_pos_order, p_session, p_credits, p_value,
          p_credits, p_value)
  RETURNING id INTO v_lot;
  INSERT INTO public.exos_event_token_ledger (org_id, event_id, card_id, product_id, lot_id, kind, credits, amount_cents,
                                              balance_after, actor, device)
  VALUES (c.org_id, c.event_id, c.id, p_product, v_lot, 'purchase', p_credits, p_value,
          public._exos_event_token_balance(c.id, p_product), p_actor, p_device);
  RETURN v_lot;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_add_lot(uuid, uuid, text, int, int, uuid, uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_add_lot(uuid, uuid, text, int, int, uuid, uuid, text, uuid, text) TO service_role;

-- Take up to p_credits from the card's lots of one product, oldest first
-- (the card is locked by the caller). {taken, value, lots: [{lot, credits, value}]}.
-- The value of k of a lot's n remaining credits is value_left x k / n, the
-- last credit taking what is left, so a lot's value always ends at 0.
CREATE OR REPLACE FUNCTION public._exos_event_token_take(p_card uuid, p_product uuid, p_credits int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  l       record;
  v_need  int := p_credits;
  v_k     int;
  v_v     int;
  v_value int := 0;
  v_lots  jsonb := '[]'::jsonb;
BEGIN
  FOR l IN SELECT id, credits_left, value_left FROM public.exos_event_token_lots
            WHERE card_id = p_card AND product_id = p_product AND status = 'active' AND credits_left > 0
            ORDER BY created_at, id FOR UPDATE LOOP
    EXIT WHEN v_need <= 0;
    v_k := least(v_need, l.credits_left);
    v_v := CASE WHEN v_k = l.credits_left THEN l.value_left
                ELSE round(l.value_left::numeric * v_k / l.credits_left)::int END;
    UPDATE public.exos_event_token_lots SET credits_left = credits_left - v_k, value_left = value_left - v_v WHERE id = l.id;
    v_lots := v_lots || jsonb_build_object('lot', l.id, 'credits', v_k, 'value', v_v);
    v_need := v_need - v_k;
    v_value := v_value + v_v;
  END LOOP;
  RETURN jsonb_build_object('taken', p_credits - v_need, 'value', v_value, 'lots', v_lots);
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_take(uuid, uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_take(uuid, uuid, int) TO service_role;

-- Close one lot (refund or expire): its unused credits leave the card in one
-- ledger row. The card is locked by the caller. Returns the ledger id (NULL:
-- nothing was left).
CREATE OR REPLACE FUNCTION public._exos_event_token_close_lot(p_lot uuid, p_kind text, p_actor uuid, p_reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE l public.exos_event_token_lots%ROWTYPE; v_id bigint;
BEGIN
  SELECT * INTO l FROM public.exos_event_token_lots WHERE id = p_lot FOR UPDATE;
  -- A pending refund closes only as a refund (never expires under it).
  IF l.id IS NULL OR NOT (l.status = 'active' OR (l.status = 'refund_pending' AND p_kind = 'refund')) THEN
    RETURN NULL;
  END IF;
  UPDATE public.exos_event_token_lots
     SET status = CASE p_kind WHEN 'refund' THEN 'refunded' ELSE 'expired' END, credits_left = 0, value_left = 0
   WHERE id = l.id;
  IF l.credits_left = 0 THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.exos_event_token_ledger (org_id, event_id, card_id, product_id, lot_id, kind, credits, amount_cents,
                                              balance_after, actor, reason)
  VALUES (l.org_id, l.event_id, l.card_id, l.product_id, l.id, p_kind, -l.credits_left, -l.value_left,
          public._exos_event_token_balance(l.card_id, l.product_id), p_actor, left(p_reason, 300))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_close_lot(uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_close_lot(uuid, text, uuid, text) TO service_role;

-- Who works this event's door ('owner' | 'manager' | 'scanner' | NULL).
CREATE OR REPLACE FUNCTION public._exos_event_token_role(p_event uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN auth.uid() IS NULL THEN NULL
              ELSE public._exos_pos_actor_role(p_event, auth.uid(), public.exos_is_admin()) END
$$;
REVOKE ALL ON FUNCTION public._exos_event_token_role(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_role(uuid) TO service_role;

-- ===========================================================================
-- 4. Configure (owner / manager)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_event_token_product_save(p_event_id uuid, p_product jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid     uuid := auth.uid();
  ev        public.exos_events%ROWTYPE;
  v_old     public.exos_event_token_products%ROWTYPE;
  p         public.exos_event_token_products%ROWTYPE;
  v_id      uuid;
  v_bundles jsonb := '[]'::jsonb;
  b         jsonb;
  v_c       int;
  v_pr      int;
  v_seen    int[] := '{}';
  v_name    text := btrim(coalesce(p_product ->> 'name', ''));
  v_unit    text := btrim(coalesce(nullif(p_product ->> 'unit_label', ''), 'token'));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ev FROM public.exos_events WHERE id = p_event_id;
  IF ev.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(ev.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_product) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'product must be an object' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('tok:save:' || v_uid::text, 30) THEN
    RAISE EXCEPTION 'too many changes a minute' USING ERRCODE = '54000';
  END IF;
  IF p_product ? 'id' AND nullif(p_product ->> 'id', '') IS NOT NULL THEN
    BEGIN
      v_id := (p_product ->> 'id')::uuid;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'product not found' USING ERRCODE = 'P0002';
    END;
    SELECT * INTO v_old FROM public.exos_event_token_products WHERE id = v_id AND event_id = ev.id FOR UPDATE;
    IF v_old.id IS NULL THEN
      RAISE EXCEPTION 'product not found' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  IF char_length(v_name) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'name: 1 to 60 characters' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_unit) NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'unit: 1 to 20 characters' USING ERRCODE = '22023';
  END IF;
  BEGIN
    v_pr := (p_product ->> 'price_cents')::int;
  EXCEPTION WHEN others THEN
    v_pr := NULL;
  END;
  IF v_pr IS NULL OR v_pr NOT BETWEEN 1 AND 100000 THEN
    RAISE EXCEPTION 'price per token: 0.01 to 1,000.00' USING ERRCODE = '22023';
  END IF;
  IF p_product ? 'bundles' AND jsonb_typeof(p_product -> 'bundles') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'bundles must be a list' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(coalesce(p_product -> 'bundles', '[]')) > 5 THEN
    RAISE EXCEPTION 'at most 5 bundles' USING ERRCODE = '22023';
  END IF;
  FOR b IN SELECT * FROM jsonb_array_elements(coalesce(p_product -> 'bundles', '[]')) LOOP
    BEGIN
      v_c := (b ->> 'credits')::int;
      v_pr := (b ->> 'price_cents')::int;
    EXCEPTION WHEN others THEN
      v_c := NULL;
    END;
    IF v_c IS NULL OR v_c NOT BETWEEN 2 AND 500 OR v_pr IS NULL OR v_pr NOT BETWEEN 1 AND 1000000 THEN
      RAISE EXCEPTION 'a bundle is 2 to 500 tokens for 0.01 to 10,000.00' USING ERRCODE = '22023';
    END IF;
    IF v_c = ANY (v_seen) THEN
      RAISE EXCEPTION 'two bundles of % tokens', v_c USING ERRCODE = '22023';
    END IF;
    v_seen := v_seen || v_c;
    v_bundles := v_bundles || jsonb_build_object('credits', v_c, 'price_cents', v_pr);
  END LOOP;

  IF v_old.id IS NULL THEN
    INSERT INTO public.exos_event_token_products (org_id, event_id, name, unit_label, price_cents, bundles, max_per_order,
                                                  refundable, grace_hours, active, sort_order, created_by)
    VALUES (ev.org_id, ev.id, v_name, v_unit, (p_product ->> 'price_cents')::int, v_bundles,
            coalesce((p_product ->> 'max_per_order')::int, 50), coalesce((p_product ->> 'refundable')::boolean, false),
            coalesce((p_product ->> 'grace_hours')::int, 0), coalesce((p_product ->> 'active')::boolean, true),
            coalesce((p_product ->> 'sort_order')::int, 0), v_uid)
    RETURNING * INTO p;
  ELSE
    UPDATE public.exos_event_token_products
       SET name = v_name, unit_label = v_unit, price_cents = (p_product ->> 'price_cents')::int, bundles = v_bundles,
           max_per_order = coalesce((p_product ->> 'max_per_order')::int, v_old.max_per_order),
           refundable = coalesce((p_product ->> 'refundable')::boolean, v_old.refundable),
           grace_hours = coalesce((p_product ->> 'grace_hours')::int, v_old.grace_hours),
           active = coalesce((p_product ->> 'active')::boolean, v_old.active),
           sort_order = coalesce((p_product ->> 'sort_order')::int, v_old.sort_order)
     WHERE id = v_old.id
    RETURNING * INTO p;
  END IF;
  PERFORM public._exos_event_token_sync_offers(p.id);
  /* exos: audit token.configure */
  PERFORM public._exos_audit(ev.org_id, 'token.configure', 'event_token_product', p.id::text, ev.id,
    jsonb_build_object('name', jsonb_build_array(v_old.name, p.name), 'price_cents', jsonb_build_array(v_old.price_cents, p.price_cents),
                       'bundles', jsonb_build_array(v_old.bundles, p.bundles),
                       'max_per_order', jsonb_build_array(v_old.max_per_order, p.max_per_order),
                       'refundable', jsonb_build_array(v_old.refundable, p.refundable),
                       'grace_hours', jsonb_build_array(v_old.grace_hours, p.grace_hours),
                       'active', jsonb_build_array(v_old.active, p.active)),
    NULL, NULL, NULL, v_uid, NULL, 'dashboard');
  RETURN to_jsonb(p) || jsonb_build_object('rule', public._exos_event_token_rule(p.id),
                                           'expires_at', public._exos_event_token_expires_at(p.id));
EXCEPTION
  WHEN check_violation OR invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'check the numbers: max per order 1 to 500, grace 0 to 720 hours' USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_product_save(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_product_save(uuid, jsonb) TO authenticated, service_role;

-- The event's products: door staff (the picker), owner / manager / finance.
CREATE OR REPLACE FUNCTION public.exos_event_token_products(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE ev public.exos_events%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ev FROM public.exos_events WHERE id = p_event_id;
  IF ev.id IS NULL OR NOT (public._exos_event_token_role(ev.id) IS NOT NULL
                           OR public.exos_has_org_role(ev.org_id, ARRAY['finance'])) THEN
    RAISE EXCEPTION 'not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object(
                     'rule', public._exos_event_token_rule(p.id), 'expires_at', public._exos_event_token_expires_at(p.id),
                     'offers', public._exos_event_token_offers(p))
                     ORDER BY p.sort_order, p.name)
                     FROM public.exos_event_token_products p WHERE p.event_id = ev.id), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_products(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_products(uuid) TO authenticated, service_role;

-- ===========================================================================
-- 5. Buying online (the add-ons) and the checkout's max-per-order check
-- ===========================================================================
-- exos-checkout (service role), before Stripe: p_addons = [{addon_id, quantity}]
-- (already merged per add-on). NULL when fine, else the buyer-facing refusal.
CREATE OR REPLACE FUNCTION public.exos_event_token_order_check(p_event_id uuid, p_addons jsonb)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  IF jsonb_typeof(p_addons) IS DISTINCT FROM 'array' THEN
    RETURN NULL;
  END IF;
  -- Whole, positive quantities only: a refusal (409 at checkout), never an error.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_addons) x
              WHERE jsonb_typeof(x) <> 'object' OR coalesce(x ->> 'quantity', '') !~ '^[0-9]{1,4}$'
                 OR (x ->> 'quantity')::int < 1) THEN
    RETURN 'add-on quantities must be whole numbers from 1';
  END IF;
  FOR r IN
    SELECT p.id, p.name, p.unit_label, p.max_per_order, p.active,
           sum(a.token_credits * greatest(coalesce((x ->> 'quantity')::int, 0), 0))::int AS credits,
           public._exos_event_token_expires_at(p.id) AS expires_at
      FROM jsonb_array_elements(p_addons) x
      JOIN public.exos_event_addons a ON a.id::text = x ->> 'addon_id' AND a.event_id = p_event_id
      JOIN public.exos_event_token_products p ON p.id = a.token_product_id
     GROUP BY p.id
  LOOP
    IF NOT r.active OR (r.expires_at IS NOT NULL AND now() >= r.expires_at) THEN
      RETURN r.name || ' isn''t on sale';
    END IF;
    IF r.credits > r.max_per_order THEN
      RETURN r.name || ': at most ' || r.max_per_order || ' per order';
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_order_check(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_order_check(uuid, jsonb) TO service_role;

-- A token add-on line (every purchase path: paid fulfilment, guest
-- checkout): the credits go on the order's ticket, the buyer's own first.
CREATE OR REPLACE FUNCTION public._exos_tg_event_token_order_addon()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a      public.exos_event_addons%ROWTYPE;
  v_tkt  uuid;
  v_card uuid;
BEGIN
  SELECT * INTO a FROM public.exos_event_addons WHERE id = NEW.addon_id;
  IF a.token_product_id IS NULL OR NEW.status <> 'active' THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_event_token_lots WHERE order_addon_id = NEW.id) THEN
    RETURN NULL;
  END IF;
  SELECT t.id INTO v_tkt FROM public.exos_tickets t
   WHERE t.order_ref = NEW.order_ref AND t.event_id = NEW.event_id AND t.status IN ('active', 'used')
   ORDER BY (t.owner_id IS NOT DISTINCT FROM NEW.buyer_id) DESC, t.created_at, t.id LIMIT 1;
  IF v_tkt IS NOT NULL THEN
    v_card := public._exos_event_token_ticket_card(v_tkt, 'online', NEW.buyer_id);
  ELSE
    -- No ticket on the order (never expected): the credits wait on the order;
    -- an owner / manager gives the buyer a code (exos_event_token_card_reissue).
    INSERT INTO public.exos_event_token_cards (org_id, event_id, order_ref, created_via, created_by)
    VALUES (NEW.org_id, NEW.event_id, coalesce(NEW.order_ref, NEW.id::text), 'online', NEW.buyer_id)
    RETURNING id INTO v_card;
  END IF;
  PERFORM 1 FROM public.exos_event_token_cards WHERE id = v_card FOR UPDATE;
  PERFORM public._exos_event_token_add_lot(v_card, a.token_product_id, 'online', a.token_credits * NEW.quantity,
                                           (round(NEW.unit_price_paid * 100) * NEW.quantity)::int, NEW.id, NULL,
                                           NEW.order_ref, NEW.buyer_id, NULL);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_token_order_addon() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_order_addons_event_tokens ON public.exos_order_addons;
CREATE TRIGGER exos_order_addons_event_tokens AFTER INSERT ON public.exos_order_addons
  FOR EACH ROW WHEN (NEW.status = 'active' AND NEW.addon_id IS NOT NULL)
  EXECUTE FUNCTION public._exos_tg_event_token_order_addon();

-- The line refunded or voided (a full order refund, any path): its credits
-- still on the card leave it. Spent ones stay spent.
CREATE OR REPLACE FUNCTION public._exos_tg_event_token_order_addon_upd()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE l record;
BEGIN
  FOR l IN SELECT id, card_id FROM public.exos_event_token_lots
            WHERE order_addon_id = NEW.id AND status IN ('active', 'refund_pending') LOOP
    PERFORM 1 FROM public.exos_event_token_cards WHERE id = l.card_id FOR UPDATE;
    PERFORM public._exos_event_token_close_lot(l.id, 'refund', NULL, 'order ' || NEW.status);
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_token_order_addon_upd() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_order_addons_event_tokens_upd ON public.exos_order_addons;
CREATE TRIGGER exos_order_addons_event_tokens_upd AFTER UPDATE OF status ON public.exos_order_addons
  FOR EACH ROW WHEN (NEW.status IN ('refunded', 'voided') AND OLD.status = 'active')
  EXECUTE FUNCTION public._exos_tg_event_token_order_addon_upd();

-- A door sale voided or refunded: its credits leave the card; refused once
-- any were spent (the guest drank them: refund the unused ones instead).
CREATE OR REPLACE FUNCTION public._exos_tg_event_token_pos_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE l record;
BEGIN
  FOR l IN SELECT id, card_id FROM public.exos_event_token_lots WHERE pos_order_id = NEW.id ORDER BY card_id, id LOOP
    PERFORM 1 FROM public.exos_event_token_cards WHERE id = l.card_id FOR UPDATE;
    -- Locked now: spent, refunded (refund_unused paid the cash back) or
    -- expired since, the sale can't be voided or refunded in full any more.
    IF (SELECT status <> 'active' OR credits_left < credits_bought FROM public.exos_event_token_lots WHERE id = l.id) THEN
      RAISE EXCEPTION 'tokens from this sale were already used or refunded: refund the unused ones instead'
        USING ERRCODE = '55000', HINT = 'tokens-spent';
    END IF;
    PERFORM public._exos_event_token_close_lot(l.id, 'refund', NEW.reversed_by, 'pos ' || NEW.status);
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_token_pos_order() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_orders_event_tokens ON public.exos_pos_orders;
CREATE TRIGGER exos_pos_orders_event_tokens AFTER UPDATE OF status ON public.exos_pos_orders
  FOR EACH ROW WHEN (NEW.status IN ('void', 'refunded') AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public._exos_tg_event_token_pos_order();

-- ===========================================================================
-- 6. The door: look up, spend, undo, the offline roster
-- ===========================================================================
-- A code's balances (door staff; 120 lookups + spends a minute per member,
-- a miss counts).
CREATE OR REPLACE FUNCTION public.exos_event_token_lookup(p_event_id uuid, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_role text; r jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  v_role := public._exos_event_token_role(p_event_id);
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('tok:door:' || auth.uid()::text, 120) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate-limited');
  END IF;
  r := public._exos_event_token_resolve(p_event_id, p_code, clock_timestamp(), false);
  IF NOT (r ->> 'ok')::boolean THEN
    RETURN r;
  END IF;
  RETURN jsonb_build_object('ok', true, 'card_id', r -> 'card_id', 'ticket', r ->> 'ticket_id' IS NOT NULL,
                            'balances', CASE WHEN r ->> 'card_id' IS NULL THEN '[]'::jsonb
                                             ELSE public._exos_event_token_balances((r ->> 'card_id')::uuid) END);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_lookup(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_lookup(uuid, text) TO authenticated;

-- Spend p_credits of a product from a scanned code. Online (p_offline_at
-- NULL): all or nothing ('insufficient' otherwise). An offline replay
-- (p_offline_at = when the device took it): what is left is taken and the
-- rest becomes an 'overspent' exception; a code that no longer passes is a
-- 'rejected' exception. Idempotent on p_client_ref (per org).
CREATE OR REPLACE FUNCTION public.exos_event_token_spend(
  p_event_id uuid, p_code text, p_product_id uuid, p_credits integer, p_client_ref uuid,
  p_offline_at timestamptz DEFAULT NULL, p_device text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_role    text;
  ev        public.exos_events%ROWTYPE;
  p         public.exos_event_token_products%ROWTYPE;
  v_at      timestamptz := coalesce(p_offline_at, clock_timestamp());
  v_offline boolean := p_offline_at IS NOT NULL;
  v_dev     text := nullif(left(btrim(coalesce(p_device, '')), 60), '');
  r         jsonb;
  v_card    uuid;
  v_bal     int;
  v_take    jsonb;
  v_n       int;
  v_lid     bigint;
  v_x       public.exos_event_token_exceptions%ROWTYPE;
  lg        public.exos_event_token_ledger%ROWTYPE;
  v_exp     timestamptz;
  v_floor   timestamptz;
  v_out     jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ev FROM public.exos_events WHERE id = p_event_id;
  v_role := public._exos_event_token_role(p_event_id);
  IF ev.id IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF p_client_ref IS NULL THEN
    RAISE EXCEPTION 'a client ref is required (a new UUID per spend)' USING ERRCODE = '22023';
  END IF;
  IF p_credits IS NULL OR p_credits NOT BETWEEN 1 AND 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-credits');
  END IF;
  SELECT * INTO p FROM public.exos_event_token_products WHERE id = p_product_id AND event_id = ev.id;
  IF p.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown-product');
  END IF;

  -- A replay of the same ref: the first answer.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_tok_ref:' || ev.org_id::text || ':' || p_client_ref::text, 0));
  SELECT * INTO lg FROM public.exos_event_token_ledger WHERE org_id = ev.org_id AND client_ref = p_client_ref;
  SELECT * INTO v_x FROM public.exos_event_token_exceptions WHERE org_id = ev.org_id AND client_ref = p_client_ref;
  IF lg.id IS NOT NULL OR v_x.id IS NOT NULL THEN
    IF (lg.id IS NOT NULL AND lg.kind <> 'spend')
       OR coalesce(lg.event_id, v_x.event_id) <> ev.id OR coalesce(lg.product_id, v_x.product_id) <> p.id
       OR coalesce(v_x.credits_asked, -lg.credits) <> p_credits THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'bad-client-ref');
    END IF;
    v_card := coalesce(lg.card_id, v_x.card_id);
    RETURN jsonb_build_object('ok', lg.id IS NOT NULL AND v_x.id IS NULL, 'duplicate', true,
                              'reason', CASE WHEN v_x.id IS NOT NULL THEN v_x.kind ELSE 'spent' END,
                              'ledger_id', lg.id, 'spent', coalesce(-lg.credits, 0),
                              'short', coalesce(v_x.credits_short, 0),
                              'balance', CASE WHEN v_card IS NULL THEN 0 ELSE public._exos_event_token_balance(v_card, p.id) END);
  END IF;

  IF NOT public.exos_rate_hit('tok:door:' || v_uid::text, 120) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate-limited');
  END IF;
  -- An offline time is the device's claim. It may not be later than now, nor
  -- earlier than this member's last roster download for the event, nor more
  -- than 12 hours back, whichever is later (server clock): a captured ticket
  -- code from days ago, or a spend backdated to before the expiry after a
  -- fresh download, can't pass. Outside that: a 'rejected' exception for
  -- review, the balance untouched.
  IF v_offline THEN
    SELECT greatest(y.synced_at, clock_timestamp() - interval '12 hours') INTO v_floor
      FROM (SELECT (SELECT s2.synced_at FROM public.exos_event_token_roster_syncs s2
                     WHERE s2.event_id = ev.id AND s2.user_id = v_uid) AS synced_at) y;
    IF p_offline_at > clock_timestamp() + interval '2 minutes' OR p_offline_at < v_floor THEN
      INSERT INTO public.exos_event_token_exceptions (org_id, event_id, card_id, product_id, kind, credits_asked, credits_short,
                                                      reason, client_ref, device, actor, offline_at)
      VALUES (ev.org_id, ev.id, NULL, p.id, 'rejected', p_credits, p_credits, 'bad-scan-time', p_client_ref, v_dev, v_uid,
              p_offline_at);
      RETURN jsonb_build_object('ok', false, 'reason', 'rejected', 'short', p_credits, 'why', 'bad-scan-time');
    END IF;
  END IF;
  v_exp := public._exos_event_token_expires_at(p.id);

  r := public._exos_event_token_resolve(ev.id, p_code, v_at, false);
  IF NOT (r ->> 'ok')::boolean OR ev.status = 'cancelled' OR (v_exp IS NOT NULL AND v_at >= v_exp) THEN
    IF v_offline THEN
      -- The device let it through; the server can't: on the report.
      INSERT INTO public.exos_event_token_exceptions (org_id, event_id, card_id, product_id, kind, credits_asked, credits_short,
                                                      reason, client_ref, device, actor, offline_at)
      VALUES (ev.org_id, ev.id, (r ->> 'card_id')::uuid, p.id, 'rejected', p_credits, p_credits,
              CASE WHEN ev.status = 'cancelled' THEN 'event-cancelled'
                   WHEN NOT (r ->> 'ok')::boolean THEN r ->> 'reason' ELSE 'expired' END,
              p_client_ref, v_dev, v_uid, p_offline_at);
      RETURN jsonb_build_object('ok', false, 'reason', 'rejected', 'short', p_credits,
                                'why', CASE WHEN ev.status = 'cancelled' THEN 'event-cancelled'
                                            WHEN NOT (r ->> 'ok')::boolean THEN r ->> 'reason' ELSE 'expired' END);
    END IF;
    IF NOT (r ->> 'ok')::boolean THEN
      RETURN r;
    END IF;
    RETURN jsonb_build_object('ok', false, 'reason', CASE WHEN ev.status = 'cancelled' THEN 'event-cancelled' ELSE 'expired' END);
  END IF;
  v_card := (r ->> 'card_id')::uuid;

  IF v_card IS NOT NULL THEN
    PERFORM 1 FROM public.exos_event_token_cards WHERE id = v_card FOR UPDATE;
    v_bal := public._exos_event_token_balance(v_card, p.id);
  ELSE
    v_bal := 0;
  END IF;
  IF NOT v_offline AND v_bal < p_credits THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient', 'balance', v_bal, 'card_id', v_card);
  END IF;

  v_n := least(v_bal, p_credits);
  IF v_n > 0 THEN
    v_take := public._exos_event_token_take(v_card, p.id, v_n);
    INSERT INTO public.exos_event_token_ledger (org_id, event_id, card_id, product_id, kind, credits, amount_cents,
                                                balance_after, detail, client_ref, device, actor, offline_at)
    VALUES (ev.org_id, ev.id, v_card, p.id, 'spend', -v_n, -(v_take ->> 'value')::int, v_bal - v_n, v_take -> 'lots',
            p_client_ref, v_dev, v_uid, p_offline_at)
    RETURNING id INTO v_lid;
  END IF;
  v_out := jsonb_build_object('ok', v_n = p_credits, 'reason', CASE WHEN v_n = p_credits THEN 'spent' ELSE 'overspent' END,
                              'ledger_id', v_lid, 'spent', v_n, 'short', p_credits - v_n, 'balance', v_bal - v_n,
                              'card_id', v_card, 'product', p.name, 'unit_label', p.unit_label);
  IF v_n < p_credits THEN
    -- Offline only: what the device gave away beyond the balance.
    INSERT INTO public.exos_event_token_exceptions (org_id, event_id, card_id, product_id, kind, credits_asked, credits_short,
                                                    reason, ledger_id, client_ref, device, actor, offline_at)
    VALUES (ev.org_id, ev.id, v_card, p.id, 'overspent', p_credits, p_credits - v_n, 'insufficient', v_lid,
            p_client_ref, v_dev, v_uid, p_offline_at);
    /* exos: audit token.overspent */
    PERFORM public._exos_audit(ev.org_id, 'token.overspent', 'event_token_card', coalesce(v_card::text, 'unknown'), ev.id,
      jsonb_build_object('product_id', jsonb_build_array(NULL, p.id), 'credits_short', jsonb_build_array(NULL, p_credits - v_n),
                         'device', jsonb_build_array(NULL, v_dev)),
      NULL, NULL, 'offline spend beyond the balance', v_uid, NULL, 'door');
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_spend(uuid, text, uuid, integer, uuid, timestamptz, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_spend(uuid, text, uuid, integer, uuid, timestamptz, text) TO authenticated;

-- Undo one spend (owner / manager, a reason; once). The credits go back to
-- the lots they came from, which must still be open.
CREATE OR REPLACE FUNCTION public.exos_event_token_undo(p_event_id uuid, p_ledger_id bigint, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  lg       public.exos_event_token_ledger%ROWTYPE;
  u        public.exos_event_token_ledger%ROWTYPE;
  x        jsonb;
  v_bal    int;
  v_id     bigint;
  v_role   text;
  v_end    timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  v_role := coalesce(public._exos_event_token_role(p_event_id), '');
  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'an owner or manager undoes a spend' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_reason) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'say why (3 to 300 characters)' USING ERRCODE = '22023', HINT = 'reason-required';
  END IF;
  SELECT * INTO lg FROM public.exos_event_token_ledger WHERE id = p_ledger_id AND event_id = p_event_id AND kind = 'spend';
  IF lg.id IS NULL THEN
    RAISE EXCEPTION 'spend not found' USING ERRCODE = 'P0002';
  END IF;
  PERFORM 1 FROM public.exos_event_token_cards WHERE id = lg.card_id FOR UPDATE;
  SELECT * INTO u FROM public.exos_event_token_ledger WHERE undoes = lg.id AND kind = 'undo';
  IF u.id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'duplicate', true, 'ledger_id', u.id, 'balance', u.balance_after);
  END IF;
  -- The window: 24 hours after the spend, and never after the tokens expire.
  -- After the event's end an undo is the owner's alone: it is the step that
  -- turns spent tokens of a refundable product back into refundable money.
  IF clock_timestamp() > least(lg.created_at + interval '24 hours',
                               coalesce(public._exos_event_token_expires_at(lg.product_id), 'infinity'::timestamptz)) THEN
    RAISE EXCEPTION 'too late to undo this spend (24 hours, or once the tokens expire)' USING ERRCODE = '55000', HINT = 'undo-window';
  END IF;
  SELECT coalesce(e.ends_at, e.starts_at + interval '12 hours') INTO v_end FROM public.exos_events e WHERE e.id = lg.event_id;
  IF v_end IS NOT NULL AND clock_timestamp() > v_end AND v_role <> 'owner' THEN
    RAISE EXCEPTION 'after the event, only an owner undoes a spend' USING ERRCODE = '42501', HINT = 'owner-after-event';
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(lg.detail, '[]')) LOOP
    UPDATE public.exos_event_token_lots
       SET credits_left = credits_left + (x ->> 'credits')::int, value_left = value_left + (x ->> 'value')::int
     WHERE id = (x ->> 'lot')::uuid AND status = 'active';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'those tokens were refunded or expired since: nothing to give back' USING ERRCODE = '55000', HINT = 'lot-closed';
    END IF;
  END LOOP;
  v_bal := public._exos_event_token_balance(lg.card_id, lg.product_id);
  INSERT INTO public.exos_event_token_ledger (org_id, event_id, card_id, product_id, kind, credits, amount_cents, balance_after,
                                              detail, actor, reason, undoes)
  VALUES (lg.org_id, lg.event_id, lg.card_id, lg.product_id, 'undo', -lg.credits, -lg.amount_cents, v_bal, lg.detail,
          v_uid, left(v_reason, 300), lg.id)
  RETURNING id INTO v_id;
  /* exos: audit token.undo */
  PERFORM public._exos_audit(lg.org_id, 'token.undo', 'event_token_ledger', lg.id::text, lg.event_id,
    jsonb_build_object('credits', jsonb_build_array(NULL, -lg.credits), 'product_id', jsonb_build_array(NULL, lg.product_id)),
    -lg.amount_cents, NULL, v_reason, v_uid, NULL, 'door');
  RETURN jsonb_build_object('ok', true, 'duplicate', false, 'ledger_id', v_id, 'balance', v_bal);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_undo(uuid, bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_undo(uuid, bigint, text) TO authenticated;

-- What a door device keeps for offline spends: every card with a balance,
-- by ticket id or code hash, and its balances (the offline cap per code).
-- The code hash is needed: offline, the device matches a scanned walk-up
-- code by hashing it (a 75-bit code's SHA-256 can't be reversed); no names,
-- no codes. Each download records the member's sync time, the floor for
-- their offline replays. Door staff; 10 a minute per member.
CREATE OR REPLACE FUNCTION public.exos_event_token_roster(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF public._exos_event_token_role(p_event_id) IS NULL THEN
    RAISE EXCEPTION 'not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('tok:roster:' || auth.uid()::text, 10) THEN
    RAISE EXCEPTION 'too many downloads a minute' USING ERRCODE = '54000';
  END IF;
  -- The floor for this member's offline replays (exos_event_token_spend).
  INSERT INTO public.exos_event_token_roster_syncs (event_id, user_id, org_id, synced_at)
  SELECT e.id, auth.uid(), e.org_id, clock_timestamp() FROM public.exos_events e WHERE e.id = p_event_id
  ON CONFLICT (event_id, user_id) DO UPDATE SET synced_at = EXCLUDED.synced_at;
  RETURN jsonb_build_object(
    'synced_at', clock_timestamp(),
    'cards', coalesce((
      SELECT jsonb_agg(jsonb_build_object('card_id', c.id, 'ticket_id', c.ticket_id, 'code_hash', c.code_hash,
                                          'balances', b.balances))
        FROM public.exos_event_token_cards c
        JOIN LATERAL (SELECT jsonb_object_agg(l.product_id, l.credits) AS balances
                        FROM (SELECT product_id, sum(credits_left)::int AS credits FROM public.exos_event_token_lots
                               WHERE card_id = c.id AND status = 'active' AND credits_left > 0 GROUP BY product_id) l) b
          ON b.balances IS NOT NULL
       WHERE c.event_id = p_event_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_roster(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_roster(uuid) TO authenticated;

-- ===========================================================================
-- 7. Selling at the door (cash or comp; a POS order with the offer's item)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_event_token_pos_sell(
  p_event_id uuid, p_product_id uuid, p_offer_credits integer, p_quantity integer, p_payment text, p_order_key uuid,
  p_code text DEFAULT NULL, p_device_id uuid DEFAULT NULL, p_drawer_id uuid DEFAULT NULL, p_comp_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_role   text;
  v_pay    text := lower(coalesce(nullif(btrim(coalesce(p_payment, '')), ''), 'cash'));
  ev       public.exos_events%ROWTYPE;
  p        public.exos_event_token_products%ROWTYPE;
  it       public.exos_pos_items%ROWTYPE;
  o        public.exos_pos_orders%ROWTYPE;
  v_order  uuid;
  v_drawer uuid;
  v_total  int;
  v_qty    int := coalesce(p_quantity, 0);
  v_credits int;
  r        jsonb;
  v_card   uuid;
  v_code   text;
  v_lot    uuid;
  v_exp    timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF v_pay = 'card' THEN
    RAISE EXCEPTION 'card for tokens at the door isn''t connected yet: take cash, or comp it' USING ERRCODE = '0A000', HINT = 'card-not-connected';
  END IF;
  IF v_pay NOT IN ('cash', 'comp') THEN
    RAISE EXCEPTION 'payment must be cash or comp' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO ev FROM public.exos_events WHERE id = p_event_id;
  v_role := public._exos_event_token_role(p_event_id);
  IF ev.id IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'not authorized to sell at this event' USING ERRCODE = '42501';
  END IF;
  IF v_pay = 'comp' AND v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'comps need an owner or manager' USING ERRCODE = '42501', HINT = 'comp-role';
  END IF;
  IF p_order_key IS NULL THEN
    RAISE EXCEPTION 'an order key is required (a new UUID per sale)' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('pos:sell:' || coalesce('d:' || p_device_id::text, 'u:' || v_uid::text), 30) THEN
    RAISE EXCEPTION 'too many sales a minute from this device' USING ERRCODE = '54000';
  END IF;
  SELECT * INTO p FROM public.exos_event_token_products WHERE id = p_product_id AND event_id = ev.id;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'token product not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO it FROM public.exos_pos_items WHERE token_product_id = p.id AND token_credits = p_offer_credits;
  IF it.id IS NULL THEN
    RAISE EXCEPTION 'no such bundle' USING ERRCODE = 'P0002';
  END IF;

  -- A double tap: the same key is the same sale (its code was shown the first time).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_pos_key:' || p_order_key::text, 0));
  SELECT * INTO o FROM public.exos_pos_orders WHERE client_ref = p_order_key;
  IF o.id IS NOT NULL THEN
    IF o.event_id <> ev.id OR o.rung_by IS DISTINCT FROM v_uid
       OR NOT EXISTS (SELECT 1 FROM public.exos_pos_order_lines li WHERE li.order_id = o.id AND li.item_id = it.id AND li.quantity = v_qty) THEN
      RAISE EXCEPTION 'this order key was already used for another sale' USING ERRCODE = '23505';
    END IF;
    SELECT card_id INTO v_card FROM public.exos_event_token_lots WHERE pos_order_id = o.id LIMIT 1;
    RETURN jsonb_build_object('order_id', o.id, 'card_id', v_card, 'code', NULL,
                              'code_last4', (SELECT code_last4 FROM public.exos_event_token_cards WHERE id = v_card),
                              'credits', p_offer_credits * v_qty, 'total_cents', o.total_cents, 'payment', v_pay,
                              'balance', public._exos_event_token_balance(v_card, p.id), 'replay', true);
  END IF;

  IF NOT it.active OR NOT p.active THEN
    RAISE EXCEPTION '% isn''t on sale', p.name USING ERRCODE = '55000', HINT = 'not-on-sale';
  END IF;
  v_exp := public._exos_event_token_expires_at(p.id);
  IF ev.status = 'cancelled' OR (v_exp IS NOT NULL AND now() >= v_exp) THEN
    RAISE EXCEPTION '% isn''t on sale any more', p.name USING ERRCODE = '55000', HINT = 'not-on-sale';
  END IF;
  IF v_qty NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'quantity: 1 to 20' USING ERRCODE = '22023';
  END IF;
  v_credits := p_offer_credits * v_qty;
  IF v_credits > p.max_per_order THEN
    RAISE EXCEPTION 'at most % % per sale', p.max_per_order, p.unit_label USING ERRCODE = '22023', HINT = 'max-per-order';
  END IF;

  -- Onto a scanned ticket or code, or a new code.
  IF nullif(btrim(coalesce(p_code, '')), '') IS NOT NULL THEN
    r := public._exos_event_token_resolve(ev.id, p_code, clock_timestamp(), true);
    IF NOT (r ->> 'ok')::boolean THEN
      RAISE EXCEPTION 'that code can''t take tokens here (%)', r ->> 'reason' USING ERRCODE = '22023', HINT = r ->> 'reason';
    END IF;
    v_card := (r ->> 'card_id')::uuid;
  END IF;

  IF v_pay = 'cash' THEN
    v_drawer := public._exos_pos_open_drawer(ev.id, v_uid, p_device_id, p_drawer_id, v_role IN ('owner', 'manager'));
    IF v_drawer IS NULL THEN
      IF p_drawer_id IS NOT NULL AND public._exos_pos_drawer_refusal(ev.id, v_uid, p_drawer_id, v_role IN ('owner', 'manager')) = '42501' THEN
        RAISE EXCEPTION 'that drawer is someone else''s: open your own, or ask a manager' USING ERRCODE = '42501', HINT = 'not-your-drawer';
      END IF;
      RAISE EXCEPTION 'open a cash drawer first' USING ERRCODE = '55000', HINT = 'no-drawer';
    END IF;
  END IF;

  INSERT INTO public.exos_pos_orders (event_id, device_id, client_ref, rung_by)
  VALUES (ev.id, p_device_id, p_order_key, v_uid)
  RETURNING id INTO v_order;
  PERFORM set_config('exos.token_sale', v_order::text, true);
  INSERT INTO public.exos_pos_order_lines (order_id, org_id, event_id, item_id, category, name, quantity, unit_price_cents)
  VALUES (v_order, ev.org_id, ev.id, it.id, 'merch', it.name, v_qty, it.price_cents);
  PERFORM set_config('exos.token_sale', '', true);
  SELECT total_cents INTO v_total FROM public.exos_pos_orders WHERE id = v_order;
  INSERT INTO public.exos_pos_payments (order_id, org_id, event_id, method, amount_cents, drawer_session_id, comp_reason, taken_by)
  VALUES (v_order, ev.org_id, ev.id, v_pay, v_total, CASE WHEN v_pay = 'cash' THEN v_drawer END,
          CASE WHEN v_pay = 'comp' THEN left(coalesce(nullif(btrim(coalesce(p_comp_reason, '')), ''), 'token comp'), 200) END, v_uid);

  IF v_card IS NULL THEN
    v_code := public._exos_gift_card_new_code();
    INSERT INTO public.exos_event_token_cards (org_id, event_id, code_hash, code_last4, created_via, created_by)
    VALUES (ev.org_id, ev.id, public._exos_event_token_hash(v_code), right(v_code, 4), 'pos', v_uid)
    RETURNING id INTO v_card;
  END IF;
  PERFORM 1 FROM public.exos_event_token_cards WHERE id = v_card FOR UPDATE;
  v_lot := public._exos_event_token_add_lot(v_card, p.id, CASE WHEN v_pay = 'comp' THEN 'comp' ELSE 'pos' END, v_credits,
                                            CASE WHEN v_pay = 'comp' THEN 0 ELSE v_total END, NULL, v_order, NULL, v_uid,
                                            p_device_id::text);
  /* exos: audit token.sell */
  PERFORM public._exos_audit(ev.org_id, 'token.sell', 'pos_order', v_order::text, ev.id,
    jsonb_build_object('product_id', jsonb_build_array(NULL, p.id), 'credits', jsonb_build_array(NULL, v_credits),
                       'payment', jsonb_build_array(NULL, v_pay), 'new_code', jsonb_build_array(NULL, v_code IS NOT NULL)),
    v_total, ev.currency, CASE WHEN v_pay = 'comp' THEN p_comp_reason END, v_uid, NULL, 'pos');
  RETURN jsonb_build_object('order_id', v_order, 'card_id', v_card,
                            'code', CASE WHEN v_code IS NOT NULL THEN 'K-' || v_code END,
                            'code_last4', (SELECT code_last4 FROM public.exos_event_token_cards WHERE id = v_card),
                            'credits', v_credits, 'total_cents', v_total, 'payment', v_pay,
                            'balance', public._exos_event_token_balance(v_card, p.id), 'replay', false,
                            'rule', public._exos_event_token_rule(p.id));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_pos_sell(uuid, uuid, integer, integer, text, uuid, text, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_pos_sell(uuid, uuid, integer, integer, text, uuid, text, uuid, uuid, text) TO authenticated;

-- A lost token code (or an online order with no ticket): owner / manager give
-- the card a new code; the old one stops working. Shown once.
CREATE OR REPLACE FUNCTION public.exos_event_token_card_reissue(p_event_id uuid, p_card_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_event_token_cards%ROWTYPE; v_code text; v_reason text := btrim(coalesce(p_reason, ''));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF coalesce(public._exos_event_token_role(p_event_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'an owner or manager issues a new code' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_reason) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'say why (3 to 300 characters)' USING ERRCODE = '22023', HINT = 'reason-required';
  END IF;
  SELECT * INTO c FROM public.exos_event_token_cards WHERE id = p_card_id AND event_id = p_event_id FOR UPDATE;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'card not found' USING ERRCODE = 'P0002';
  END IF;
  IF c.ticket_id IS NOT NULL THEN
    RAISE EXCEPTION 'these tokens ride on a ticket: its own code spends them' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('tok:reissue:' || auth.uid()::text, 10) THEN
    RAISE EXCEPTION 'too many new codes a minute' USING ERRCODE = '54000';
  END IF;
  v_code := public._exos_gift_card_new_code();
  UPDATE public.exos_event_token_cards SET code_hash = public._exos_event_token_hash(v_code), code_last4 = right(v_code, 4)
   WHERE id = c.id;
  /* exos: audit token.reissue */
  PERFORM public._exos_audit(c.org_id, 'token.reissue', 'event_token_card', c.id::text, c.event_id,
    jsonb_build_object('code_last4', jsonb_build_array(c.code_last4, right(v_code, 4))), NULL, NULL, v_reason, auth.uid(), NULL, 'dashboard');
  RETURN jsonb_build_object('card_id', c.id, 'code', 'K-' || v_code, 'code_last4', right(v_code, 4),
                            'balances', public._exos_event_token_balances(c.id));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_card_reissue(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_card_reissue(uuid, uuid, text) TO authenticated;

-- ===========================================================================
-- 8. Refunds of unused credits and expiry
-- ===========================================================================
-- Refundable products only.
-- Online (S2): the money must move before the tokens leave the books. The
-- lot becomes 'refund_pending' (not spendable, still on the books, on the
-- report) with a refund key; the caller refunds {session_id, amount_cents}
-- with the existing partial refund (exos-refund, nonce = refund_key: a retry
-- is one refund). When that request succeeds (exos_refund_requests.status,
-- written by exos-refund's finalize or the Stripe webhook) a trigger closes
-- the lot: the refund ledger row and its journal entry. A failed or
-- cancelled request leaves the lot pending: "Refund" again takes a new key,
-- "Put back" (exos_event_token_refund_cancel) makes the tokens spendable.
-- Door cash: paid back out of a drawer in this transaction (a paid-out of
-- kind 'refund' on the sale). A comp: the tokens just leave.
CREATE OR REPLACE FUNCTION public.exos_event_token_refund_unused(
  p_event_id uuid, p_lot_id uuid, p_reason text, p_drawer_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_role   text;
  v_reason text := btrim(coalesce(p_reason, ''));
  l        public.exos_event_token_lots%ROWTYPE;
  p        public.exos_event_token_products%ROWTYPE;
  lg       public.exos_event_token_ledger%ROWTYPE;
  v_req    text;
  v_drawer uuid;
  v_po     uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  v_role := public._exos_event_token_role(p_event_id);
  IF coalesce(v_role, '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'an owner or manager refunds tokens' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_reason) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'say why (3 to 300 characters)' USING ERRCODE = '22023', HINT = 'reason-required';
  END IF;
  SELECT * INTO l FROM public.exos_event_token_lots WHERE id = p_lot_id AND event_id = p_event_id;
  IF l.id IS NULL THEN
    RAISE EXCEPTION 'purchase not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO p FROM public.exos_event_token_products WHERE id = l.product_id;
  IF NOT p.refundable THEN
    RAISE EXCEPTION '% are not refundable', p.name USING ERRCODE = '55000', HINT = 'not-refundable';
  END IF;
  PERFORM 1 FROM public.exos_event_token_cards WHERE id = l.card_id FOR UPDATE;
  SELECT * INTO l FROM public.exos_event_token_lots WHERE id = l.id FOR UPDATE;
  IF l.status = 'refund_pending' THEN
    SELECT r.status INTO v_req FROM public.exos_refund_requests r WHERE r.org_id = l.org_id AND r.nonce = l.refund_key;
    IF v_req = 'succeeded' THEN
      -- The trigger closes it; a request recorded before this migration can't have fired it.
      PERFORM public._exos_event_token_close_lot(l.id, 'refund', l.refund_by, coalesce(l.refund_reason, v_reason));
      SELECT * INTO l FROM public.exos_event_token_lots WHERE id = l.id;
    ELSIF v_req IN ('failed', 'canceled') THEN
      -- That request is over: a new key for a new one (the old key answers its failure forever).
      UPDATE public.exos_event_token_lots
         SET refund_attempt = refund_attempt + 1,
             refund_key = 'evtoken-refund:' || id || ':' || (refund_attempt + 1)
       WHERE id = l.id
      RETURNING * INTO l;
    END IF;
  END IF;
  IF l.status = 'refunded' THEN
    SELECT * INTO lg FROM public.exos_event_token_ledger WHERE lot_id = l.id AND kind = 'refund';
    RETURN jsonb_build_object('replay', true, 'pending', false, 'lot_id', l.id, 'source', l.source,
                              'credits', coalesce(-lg.credits, 0), 'amount_cents', coalesce(-lg.amount_cents, 0),
                              'session_id', l.session_id, 'refund_key', l.refund_key);
  END IF;
  IF l.status = 'refund_pending' THEN
    RETURN jsonb_build_object('replay', true, 'pending', true, 'lot_id', l.id, 'source', l.source, 'credits', l.credits_left,
                              'amount_cents', l.value_left, 'session_id', l.session_id, 'refund_key', l.refund_key,
                              'request_status', v_req);
  END IF;
  IF l.status <> 'active' OR l.credits_left = 0 THEN
    RAISE EXCEPTION 'nothing left to refund on this purchase' USING ERRCODE = '55000', HINT = 'nothing-left';
  END IF;
  IF l.source = 'online' AND l.value_left > 0 THEN
    UPDATE public.exos_event_token_lots
       SET status = 'refund_pending', refund_attempt = refund_attempt + 1,
           refund_key = 'evtoken-refund:' || id || ':' || (refund_attempt + 1), refund_by = v_uid, refund_reason = left(v_reason, 300)
     WHERE id = l.id
    RETURNING * INTO l;
  ELSE
    IF l.source = 'pos' AND l.value_left > 0 THEN
      IF EXISTS (SELECT 1 FROM public.exos_pos_settlements s WHERE s.event_id = l.event_id AND s.status = 'final') THEN
        RAISE EXCEPTION 'the event''s settlement is final' USING ERRCODE = '55000', HINT = 'settlement-final';
      END IF;
      v_drawer := public._exos_pos_open_drawer(l.event_id, v_uid, NULL, p_drawer_id, true);
      IF v_drawer IS NULL THEN
        RAISE EXCEPTION 'open a cash drawer at this event to hand the cash back' USING ERRCODE = '55000', HINT = 'no-drawer';
      END IF;
      PERFORM 1 FROM public.exos_pos_drawer_sessions WHERE id = v_drawer FOR UPDATE;
      IF public._exos_pos_drawer_cash(v_drawer) < l.value_left THEN
        RAISE EXCEPTION 'the drawer only has % cents', public._exos_pos_drawer_cash(v_drawer) USING ERRCODE = '23514', HINT = 'drawer-short';
      END IF;
    END IF;
    PERFORM public._exos_event_token_close_lot(l.id, 'refund', v_uid, v_reason);
    IF v_drawer IS NOT NULL THEN
      INSERT INTO public.exos_pos_paid_outs (org_id, event_id, drawer_session_id, kind, amount_cents, reason, order_id, created_by)
      VALUES (l.org_id, l.event_id, v_drawer, 'refund', l.value_left, left('unused tokens: ' || v_reason, 300), l.pos_order_id, v_uid)
      RETURNING id INTO v_po;
    END IF;
  END IF;
  /* exos: audit token.refund */
  PERFORM public._exos_audit(l.org_id, 'token.refund', 'event_token_lot', l.id::text, l.event_id,
    jsonb_build_object('credits', jsonb_build_array(NULL, l.credits_left), 'source', jsonb_build_array(NULL, l.source),
                       'pending', jsonb_build_array(NULL, l.status = 'refund_pending')),
    l.value_left, NULL, v_reason, v_uid, NULL, 'dashboard');
  RETURN jsonb_build_object('replay', false, 'pending', l.status = 'refund_pending', 'lot_id', l.id, 'source', l.source,
                            'credits', l.credits_left, 'amount_cents', l.value_left, 'session_id', l.session_id,
                            'paid_out_id', v_po, 'refund_key', CASE WHEN l.status = 'refund_pending' THEN l.refund_key END);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_refund_unused(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_refund_unused(uuid, uuid, text, uuid) TO authenticated;

-- "Put back": a pending online refund that didn't go through (no request, or
-- it failed / was cancelled) makes the tokens spendable again. Refused while
-- its request is in flight or done. Owner / manager; audited.
CREATE OR REPLACE FUNCTION public.exos_event_token_refund_cancel(p_event_id uuid, p_lot_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE l public.exos_event_token_lots%ROWTYPE; v_req text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF coalesce(public._exos_event_token_role(p_event_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'an owner or manager refunds tokens' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO l FROM public.exos_event_token_lots WHERE id = p_lot_id AND event_id = p_event_id;
  IF l.id IS NULL THEN
    RAISE EXCEPTION 'purchase not found' USING ERRCODE = 'P0002';
  END IF;
  PERFORM 1 FROM public.exos_event_token_cards WHERE id = l.card_id FOR UPDATE;
  SELECT * INTO l FROM public.exos_event_token_lots WHERE id = l.id FOR UPDATE;
  IF l.status <> 'refund_pending' THEN
    RAISE EXCEPTION 'no refund is pending on this purchase' USING ERRCODE = '55000', HINT = 'not-pending';
  END IF;
  SELECT r.status INTO v_req FROM public.exos_refund_requests r WHERE r.org_id = l.org_id AND r.nonce = l.refund_key;
  IF v_req IN ('claimed', 'pending', 'succeeded') THEN
    RAISE EXCEPTION 'the refund is going through: wait for it' USING ERRCODE = '55000', HINT = 'refund-in-flight';
  END IF;
  UPDATE public.exos_event_token_lots SET status = 'active' WHERE id = l.id;
  /* exos: audit token.refund_cancel */
  PERFORM public._exos_audit(l.org_id, 'token.refund_cancel', 'event_token_lot', l.id::text, l.event_id,
    jsonb_build_object('status', jsonb_build_array('refund_pending', 'active'), 'request', jsonb_build_array(NULL, v_req)),
    NULL, NULL, NULL, auth.uid(), NULL, 'dashboard');
  RETURN jsonb_build_object('lot_id', l.id, 'status', 'active', 'credits', l.credits_left,
                            'balance', public._exos_event_token_balance(l.card_id, l.product_id));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_refund_cancel(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_refund_cancel(uuid, uuid) TO authenticated;

-- The refund went through (exos_refund_requests succeeded, by exos-refund's
-- finalize or the Stripe webhook): the pending lot closes as a refund. Never
-- blocks the refund's own write (a failure is a WARNING; "Refund" again
-- closes it from the request).
CREATE OR REPLACE FUNCTION public._exos_tg_event_token_refund_done()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE l public.exos_event_token_lots%ROWTYPE;
BEGIN
  BEGIN
    SELECT * INTO l FROM public.exos_event_token_lots
     WHERE refund_key = NEW.nonce AND org_id = NEW.org_id AND session_id = NEW.session_id AND status = 'refund_pending';
    IF l.id IS NOT NULL THEN
      PERFORM 1 FROM public.exos_event_token_cards WHERE id = l.card_id FOR UPDATE;
      PERFORM public._exos_event_token_close_lot(l.id, 'refund', l.refund_by, coalesce(l.refund_reason, 'unused tokens'));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos event tokens: % closing the lot of refund %', SQLERRM, NEW.nonce;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_token_refund_done() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_refund_requests_event_tokens ON public.exos_refund_requests;
CREATE TRIGGER exos_refund_requests_event_tokens AFTER INSERT OR UPDATE OF status ON public.exos_refund_requests
  FOR EACH ROW WHEN (NEW.status = 'succeeded' AND NEW.nonce LIKE 'evtoken-refund:%')
  EXECUTE FUNCTION public._exos_tg_event_token_refund_done();

-- Expire what can't be spent any more (not refundable products, past expiry).
-- Refundable products' unused credits stay on the report until refunded.
CREATE OR REPLACE FUNCTION public._exos_event_token_expire_core(p_event uuid, p_actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record; v_n int := 0; v_credits int := 0; v_cents int := 0; v_org uuid;
BEGIN
  FOR r IN SELECT l.id, l.card_id, l.org_id, l.credits_left, l.value_left
             FROM public.exos_event_token_lots l JOIN public.exos_event_token_products p ON p.id = l.product_id
            WHERE l.event_id = p_event AND l.status = 'active' AND NOT p.refundable
              AND public._exos_event_token_expires_at(p.id) <= now()
            ORDER BY l.card_id, l.id LOOP
    PERFORM 1 FROM public.exos_event_token_cards WHERE id = r.card_id FOR UPDATE;
    IF public._exos_event_token_close_lot(r.id, 'expire', p_actor, 'expired') IS NOT NULL THEN
      v_n := v_n + 1; v_credits := v_credits + r.credits_left; v_cents := v_cents + r.value_left;
    END IF;
    v_org := r.org_id;
  END LOOP;
  IF v_n > 0 THEN
    /* exos: audit token.expire */
    PERFORM public._exos_audit(v_org, 'token.expire', 'event', p_event::text, p_event,
      jsonb_build_object('lots', jsonb_build_array(NULL, v_n), 'credits', jsonb_build_array(NULL, v_credits)),
      v_cents, NULL, NULL, p_actor, NULL, CASE WHEN p_actor IS NULL THEN 'system' ELSE 'dashboard' END);
  END IF;
  RETURN jsonb_build_object('lots', v_n, 'credits', v_credits, 'cents', v_cents);
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_expire_core(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_expire_core(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_event_token_expire(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF coalesce(public._exos_event_token_role(p_event_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'an owner or manager expires tokens' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_event_token_expire_core(p_event_id, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_expire(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_expire(uuid) TO authenticated;

-- For the cron (service role): every event with something to expire.
CREATE OR REPLACE FUNCTION public._exos_event_token_expire_due()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record; v_events int := 0; v_lots int := 0; x jsonb;
BEGIN
  FOR r IN SELECT DISTINCT l.event_id FROM public.exos_event_token_lots l
             JOIN public.exos_event_token_products p ON p.id = l.product_id
            WHERE l.status = 'active' AND NOT p.refundable AND public._exos_event_token_expires_at(p.id) <= now()
            LIMIT 200 LOOP
    x := public._exos_event_token_expire_core(r.event_id, NULL);
    v_events := v_events + 1; v_lots := v_lots + (x ->> 'lots')::int;
  END LOOP;
  RETURN jsonb_build_object('events', v_events, 'lots', v_lots);
END $$;
REVOKE ALL ON FUNCTION public._exos_event_token_expire_due() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_token_expire_due() TO service_role;

-- ===========================================================================
-- 9. The buyer's ticket page and the organizer's report
-- ===========================================================================
-- Balances on the holder's tickets (for one event, or all).
CREATE OR REPLACE FUNCTION public.exos_my_event_tokens(p_event_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('ticket_id', t.id, 'event_id', t.event_id, 'event_name', e.name,
                                        'balances', public._exos_event_token_balances(c.id),
                                        'rules', (SELECT coalesce(jsonb_object_agg(p.id, public._exos_event_token_rule(p.id)), '{}'::jsonb)
                                                    FROM public.exos_event_token_products p
                                                   WHERE p.id IN (SELECT product_id FROM public.exos_event_token_lots WHERE card_id = c.id)))
                     ORDER BY t.created_at, t.id)
      FROM public.exos_tickets t
      JOIN public.exos_event_token_cards c ON c.ticket_id = t.id
      JOIN public.exos_events e ON e.id = t.event_id
     WHERE t.owner_id = (SELECT auth.uid()) AND t.status IN ('active', 'used')
       AND (p_event_id IS NULL OR t.event_id = p_event_id)
       AND EXISTS (SELECT 1 FROM public.exos_event_token_lots l WHERE l.card_id = c.id)), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_my_event_tokens(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_my_event_tokens(uuid) TO authenticated;

-- Per product: sold / redeemed / expired / refunded / outstanding, the
-- exceptions, the refundable lots. Owner / manager / finance. No buyer data.
CREATE OR REPLACE FUNCTION public.exos_event_token_report(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE ev public.exos_events%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ev FROM public.exos_events WHERE id = p_event_id;
  IF ev.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(ev.org_id, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'event_id', ev.id, 'currency', ev.currency, 'generated_at', now(),
    'products', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'product_id', p.id, 'name', p.name, 'unit_label', p.unit_label, 'refundable', p.refundable,
               'expires_at', public._exos_event_token_expires_at(p.id),
               'sold_credits', coalesce(s.sold_c, 0), 'sold_cents', coalesce(s.sold_v, 0),
               'redeemed_credits', coalesce(s.red_c, 0), 'redeemed_cents', coalesce(s.red_v, 0),
               'expired_credits', coalesce(s.exp_c, 0), 'expired_cents', coalesce(s.exp_v, 0),
               'refunded_credits', coalesce(s.ref_c, 0), 'refunded_cents', coalesce(s.ref_v, 0),
               'outstanding_credits', coalesce(s.sold_c, 0) - coalesce(s.red_c, 0) - coalesce(s.exp_c, 0) - coalesce(s.ref_c, 0),
               'outstanding_cents', coalesce(s.sold_v, 0) - coalesce(s.red_v, 0) - coalesce(s.exp_v, 0) - coalesce(s.ref_v, 0),
               'overspent_count', coalesce(x.n_over, 0), 'overspent_credits', coalesce(x.c_over, 0),
               'rejected_count', coalesce(x.n_rej, 0), 'rejected_credits', coalesce(x.c_rej, 0))
               ORDER BY p.sort_order, p.name)
        FROM public.exos_event_token_products p
        LEFT JOIN LATERAL (
          SELECT sum(credits) FILTER (WHERE kind = 'purchase') AS sold_c, sum(amount_cents) FILTER (WHERE kind = 'purchase') AS sold_v,
                 -(coalesce(sum(credits) FILTER (WHERE kind = 'spend'), 0) + coalesce(sum(credits) FILTER (WHERE kind = 'undo'), 0)) AS red_c,
                 -(coalesce(sum(amount_cents) FILTER (WHERE kind = 'spend'), 0) + coalesce(sum(amount_cents) FILTER (WHERE kind = 'undo'), 0)) AS red_v,
                 -sum(credits) FILTER (WHERE kind = 'expire') AS exp_c, -sum(amount_cents) FILTER (WHERE kind = 'expire') AS exp_v,
                 -sum(credits) FILTER (WHERE kind = 'refund') AS ref_c, -sum(amount_cents) FILTER (WHERE kind = 'refund') AS ref_v
            FROM public.exos_event_token_ledger WHERE product_id = p.id) s ON true
        LEFT JOIN LATERAL (
          SELECT count(*) FILTER (WHERE kind = 'overspent') AS n_over, sum(credits_short) FILTER (WHERE kind = 'overspent') AS c_over,
                 count(*) FILTER (WHERE kind = 'rejected') AS n_rej, sum(credits_short) FILTER (WHERE kind = 'rejected') AS c_rej
            FROM public.exos_event_token_exceptions WHERE product_id = p.id) x ON true
       WHERE p.event_id = ev.id), '[]'::jsonb),
    'exceptions', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'product', p.name, 'credits_asked', x.credits_asked,
                                          'credits_short', x.credits_short, 'reason', x.reason, 'device', x.device,
                                          'offline_at', x.offline_at, 'synced_at', x.created_at,
                                          'card_last4', c.code_last4, 'on_ticket', c.ticket_id IS NOT NULL)
                       ORDER BY x.offline_at DESC)
        FROM public.exos_event_token_exceptions x
        JOIN public.exos_event_token_products p ON p.id = x.product_id
        LEFT JOIN public.exos_event_token_cards c ON c.id = x.card_id
       WHERE x.event_id = ev.id), '[]'::jsonb),
    'refundable', coalesce((
      SELECT jsonb_agg(jsonb_build_object('lot_id', l.id, 'product', p.name, 'source', l.source, 'credits_left', l.credits_left,
                                          'value_left', l.value_left, 'bought_at', l.created_at, 'card_id', l.card_id,
                                          'card_last4', c.code_last4, 'on_ticket', c.ticket_id IS NOT NULL,
                                          'status', l.status,
                                          'request_status', (SELECT r.status FROM public.exos_refund_requests r
                                                              WHERE l.status = 'refund_pending' AND r.org_id = l.org_id
                                                                AND r.nonce = l.refund_key))
                       ORDER BY l.created_at)
        FROM public.exos_event_token_lots l
        JOIN public.exos_event_token_products p ON p.id = l.product_id AND (p.refundable OR l.status = 'refund_pending')
        JOIN public.exos_event_token_cards c ON c.id = l.card_id
       WHERE l.event_id = ev.id AND l.status IN ('active', 'refund_pending') AND l.credits_left > 0), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_token_report(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_token_report(uuid) TO authenticated;

-- ===========================================================================
-- 10. The journal: tokens are deferred revenue
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_journal_accounts()
RETURNS TABLE (code text, number int, name text, type text, normal text)
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT * FROM (VALUES
    ('stripe_clearing',              1000, 'Cash at Stripe / clearing',                'asset',          'debit'),
    ('paypal_receivable',            1010, 'PayPal balance due from Exos',             'asset',          'debit'),
    ('pos_cash_drawer',              1020, 'POS cash drawer',                          'asset',          'debit'),
    ('bank',                         1030, 'Bank (payouts received)',                  'asset',          'debit'),
    ('cash_on_hand',                 1040, 'Cash on hand (outside Exos)',              'asset',          'debit'),
    ('marketplace_receivable',       1100, 'Marketplace receivable',                   'asset',          'debit'),
    ('organizer_payable',            2000, 'Organizer payable (owed to Exos)',         'liability',      'credit'),
    ('sales_tax_payable',            2100, 'Sales tax payable',                        'liability',      'credit'),
    ('promoter_commissions_payable', 2200, 'Promoter commissions payable',             'liability',      'credit'),
    ('gift_cards_outstanding',       2300, 'Gift cards outstanding',                   'liability',      'credit'),
    ('event_tokens_outstanding',     2310, 'Event tokens outstanding',                 'liability',      'credit'),
    ('tips_payable',                 2400, 'Tips payable (POS)',                       'liability',      'credit'),
    ('opening_balances',             3000, 'Opening balances (imported gift cards)',   'equity',         'credit'),
    ('ticket_revenue',               4000, 'Ticket revenue (face)',                    'revenue',        'credit'),
    ('buyer_fees',                   4010, 'Buyer fees',                               'revenue',        'credit'),
    ('pos_other_sales',              4020, 'Bar and merch sales (POS)',                'revenue',        'credit'),
    ('donations',                    4030, 'Donations',                                'revenue',        'credit'),
    ('gift_card_breakage',           4040, 'Gift card breakage (voided balances)',     'revenue',        'credit'),
    ('event_token_redemptions',      4050, 'Event tokens redeemed',                    'revenue',        'credit'),
    ('event_token_breakage',         4060, 'Event token breakage (expired)',           'revenue',        'credit'),
    ('refunds',                      4900, 'Refunds',                                  'contra_revenue', 'debit'),
    ('exos_fee',                     5000, 'Exos fee',                                 'expense',        'debit'),
    ('card_fees',                    5010, 'Card processing fees',                     'expense',        'debit'),
    ('disputes',                     5020, 'Disputes',                                 'expense',        'debit'),
    ('promoter_commissions',         5030, 'Promoter commissions',                     'expense',        'debit'),
    ('pos_paid_outs',                5040, 'Cash paid-outs (POS)',                     'expense',        'debit'),
    ('cash_over_short',              5050, 'Cash over / short (POS)',                  'expense',        'debit'),
    ('gift_card_comps',              5060, 'Gift cards given away',                    'expense',        'debit')
  ) a(code, number, name, type, normal)
$$;
REVOKE ALL ON FUNCTION public.exos_journal_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_journal_accounts() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._exos_journal_account_ok(p_code text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT p_code IN ('stripe_clearing', 'paypal_receivable', 'pos_cash_drawer', 'bank', 'cash_on_hand', 'marketplace_receivable',
                    'organizer_payable', 'sales_tax_payable', 'promoter_commissions_payable', 'gift_cards_outstanding',
                    'event_tokens_outstanding', 'tips_payable', 'opening_balances', 'ticket_revenue', 'buyer_fees',
                    'pos_other_sales', 'donations', 'gift_card_breakage', 'event_token_redemptions', 'event_token_breakage',
                    'refunds', 'exos_fee', 'card_fees', 'disputes', 'promoter_commissions', 'pos_paid_outs',
                    'cash_over_short', 'gift_card_comps')
$$;
REVOKE ALL ON FUNCTION public._exos_journal_account_ok(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_journal_account_ok(text) TO authenticated, service_role;

ALTER TABLE public.exos_journal_entries DROP CONSTRAINT IF EXISTS exos_journal_entries_source_table_check;
ALTER TABLE public.exos_journal_entries ADD CONSTRAINT exos_journal_entries_source_table_check CHECK (source_table IN (
  'exos_checkout_sessions', 'exos_order_refunds', 'exos_fee_adjustments', 'exos_disputes',
  'exos_marketplace_orders', 'exos_org_payout_lines', 'exos_promoter_commissions',
  'exos_pos_payments', 'exos_pos_paid_outs',
  'exos_pos_reversals', 'exos_gift_card_ledger', 'exos_gift_card_redemptions', 'exos_pos_drawer_sessions',
  'exos_org_instant_payouts', 'exos_paypal_org_remittances',
  'exos_stripe_org_payouts',
  'exos_event_token_ledger'));

-- One ledger row -> one entry. The sale account the value came from:
-- online lots ticket revenue (the order's sale entry put the add-on's face
-- there), door lots bar and merch (pos_cash_sale), comps nothing (value 0).
CREATE OR REPLACE FUNCTION public.exos_journal_post_event_token(p_ledger bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE lg public.exos_event_token_ledger%ROWTYPE; v_src text; v_sale text; v_amt bigint; v_cur text; v_name text;
BEGIN
  SELECT * INTO lg FROM public.exos_event_token_ledger WHERE id = p_ledger;
  IF lg.id IS NULL OR lg.amount_cents = 0 THEN
    RETURN NULL;
  END IF;
  v_amt := abs(lg.amount_cents);
  SELECT coalesce(currency, 'usd') INTO v_cur FROM public.exos_events WHERE id = lg.event_id;
  SELECT name INTO v_name FROM public.exos_event_token_products WHERE id = lg.product_id;
  IF lg.kind IN ('purchase', 'refund') THEN
    SELECT source INTO v_src FROM public.exos_event_token_lots WHERE id = lg.lot_id;
    v_sale := CASE v_src WHEN 'online' THEN 'ticket_revenue' WHEN 'pos' THEN 'pos_other_sales' END;
    IF v_sale IS NULL THEN
      RETURN NULL;
    END IF;
    RETURN public._exos_journal_post(
      lg.org_id, lg.event_id, 'exos_event_token_ledger', lg.id::text, 'token_' || lg.kind, lg.created_at, v_cur,
      left(CASE lg.kind WHEN 'purchase' THEN 'Event tokens sold (deferred): ' ELSE 'Unused event tokens refunded: ' END
           || coalesce(v_name, ''), 300),
      CASE lg.kind WHEN 'purchase'
        THEN jsonb_build_array(jsonb_build_object('a', v_sale, 'c', v_amt),
                               jsonb_build_object('a', 'event_tokens_outstanding', 'c', -v_amt))
        ELSE jsonb_build_array(jsonb_build_object('a', 'event_tokens_outstanding', 'c', v_amt),
                               jsonb_build_object('a', v_sale, 'c', -v_amt)) END,
      NULL, v_amt);
  END IF;
  RETURN public._exos_journal_post(
    lg.org_id, lg.event_id, 'exos_event_token_ledger', lg.id::text, 'token_' || lg.kind, lg.created_at, v_cur,
    left(CASE lg.kind WHEN 'spend' THEN 'Event tokens redeemed: ' WHEN 'undo' THEN 'Event token redemption undone: '
                      ELSE 'Event tokens expired: ' END || coalesce(v_name, ''), 300),
    CASE lg.kind
      WHEN 'spend' THEN jsonb_build_array(jsonb_build_object('a', 'event_tokens_outstanding', 'c', v_amt),
                                          jsonb_build_object('a', 'event_token_redemptions', 'c', -v_amt))
      WHEN 'undo' THEN jsonb_build_array(jsonb_build_object('a', 'event_token_redemptions', 'c', v_amt),
                                         jsonb_build_object('a', 'event_tokens_outstanding', 'c', -v_amt))
      ELSE jsonb_build_array(jsonb_build_object('a', 'event_tokens_outstanding', 'c', v_amt),
                             jsonb_build_object('a', 'event_token_breakage', 'c', -v_amt)) END,
    NULL, v_amt);
END $$;
REVOKE ALL ON FUNCTION public.exos_journal_post_event_token(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_journal_post_event_token(bigint) TO service_role;

-- Posted as the row is written; a failure is a WARNING (the sale or spend
-- stands; the backfill posts it later).
CREATE OR REPLACE FUNCTION public._exos_tg_event_token_journal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  BEGIN
    PERFORM public.exos_journal_post_event_token(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos journal: % on exos_event_token_ledger (%): the backfill will post it', SQLERRM, SQLSTATE;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_token_journal() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_event_token_ledger_journal ON public.exos_event_token_ledger;
CREATE TRIGGER exos_event_token_ledger_journal AFTER INSERT ON public.exos_event_token_ledger
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_token_journal();

SELECT pg_temp.exos_patch_n('public._exos_journal_backfill(uuid)',
  '/* exos: journal event tokens */',
  $o$  SELECT count(*) INTO v_after FROM public.exos_journal_entries WHERE p_org IS NULL OR org_id = p_org;$o$,
  $n$  /* exos: journal event tokens */ -- mig 20261114110000
  FOR r IN SELECT id FROM public.exos_event_token_ledger WHERE p_org IS NULL OR org_id = p_org ORDER BY id LOOP
    PERFORM public.exos_journal_post_event_token(r.id);
  END LOOP;
  SELECT count(*) INTO v_after FROM public.exos_journal_entries WHERE p_org IS NULL OR org_id = p_org;$n$, 1);

-- ===========================================================================
-- 11. export.run for the report's CSV / XLSX
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_audit_export(uuid,text,integer,uuid)',
  '/* exos: event token export kinds */',
  $o$'journal' /* exos: attendance export kinds */) THEN$o$,
  $n$'journal' /* exos: attendance export kinds */, 'event_tokens' /* exos: event token export kinds */) THEN$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_audit_export(uuid,text,integer,uuid)',
  '/* exos: event token export cap */',
  $o$'journal' /* exos: attendance export cap */)$o$,
  $n$'journal' /* exos: attendance export cap */, 'event_tokens' /* exos: event token export cap */)$n$, 1);

-- ===========================================================================
-- 12. The expiry job: hourly, created INACTIVE (the operator turns it on).
-- ===========================================================================
DO $$
DECLARE v_job bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    SELECT jobid INTO v_job FROM cron.job WHERE jobname = 'exos-event-token-expire';
    IF v_job IS NULL THEN
      v_job := cron.schedule('exos-event-token-expire', '23 * * * *', 'SELECT public._exos_event_token_expire_due()');
      PERFORM cron.alter_job(v_job, active := false);
    END IF;
  END IF;
END $$;
