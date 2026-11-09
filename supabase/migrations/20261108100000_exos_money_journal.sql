-- ============================================================================
-- Migration 20261108100000 — Exos: money journal (double entry, per org),
--   sales tax by jurisdiction, $0 order rows for free claims and comps.
--   docs/journal.md. KANBAN "Next (money records: ERP-lite)" items 3, 8, 9.
--
-- Branch:   claude/exos-money-journal
-- Touches:  C: TABLE exos_journal_entries, exos_journal_lines (RLS: owner /
--              manager / finance read; no client writes; append-only)
--           C: VIEW exos_journal_rows (security_invoker: one row per line)
--           C: FUNCTION exos_journal_accounts (the chart), _exos_journal_post
--              (the one writer: an entry and its lines, balanced, idempotent
--              on (source_table, source_id, kind)), _exos_journal_sync (posts
--              the difference to a target), _exos_journal_lock,
--              exos_journal_post_order / _refund / _fee_adjustment /
--              _dispute / _marketplace / _payout_line / _commission /
--              _pos_payment / _pos_paid_out, _exos_journal_backfill
--              (service role), the trigger functions, _exos_journal_check
--              (deferred balance check), _exos_journal_guard (append-only)
--           C: FUNCTION exos_journal_trial_balance, exos_sales_tax_report
--              (owner / manager / finance or service role, checked in SQL)
--           C: COLUMN exos_checkout_sessions.free_kind; TRIGGER on
--              exos_tickets (_exos_tg_ticket_zero_order) that records a $0
--              order for tickets minted with no order: free claims, comps
--              (box office, batch, staff mint), RSVPs, referral rewards and
--              comps at the door (POS). No invoice: the invoice trigger fires
--              on UPDATE only, and only above $0 (mig 20261001100000).
--           W: FUNCTION _exos_channel_lines, _exos_buyer_geo,
--              _exos_cash_summary, _exos_gl_backfill, exos_event_in_app_report (marker
--              /* exos: zero orders */): leave the $0 rows out, because
--              those reports already count those tickets from exos_tickets
--              (or count checkouts, which a comp never was).
--           R: exos_checkout_sessions, exos_order_refunds, exos_order_fees,
--              exos_fee_adjustments, exos_disputes, exos_credit_notes,
--              exos_marketplace_orders, exos_org_payouts / _lines,
--              exos_promoter_commissions, exos_pos_orders / _order_lines /
--              _payments / _paid_outs / _reversals, exos_price_disclosure_lines,
--              exos_tax_rules, exos_ticket_tiers, exos_event_addons,
--              exos_invoices, exos_events
-- Pre-reqs: 20261107100000 (POS walk-up), 20261107110000 (fee-change log),
--           20261102120000 (cash summary), 20261106140000 (buyer geo),
--           20261105140000 (in-app report), 20261029120000 (channel lines).
--
-- The journal is the ORGANIZER's books as Exos sees them. Amounts follow the
-- existing money model and never a second one:
--   * an order (exos_checkout_sessions, a paid status) splits like
--     _exos_gl_backfill: tickets = order value (charge + gift card) − tax −
--     passed-on fees − donation; the application fee withheld is the Exos fee
--     plus the card-fee estimate (exos_order_money: organizer net = gross −
--     application fee). Stripe's actual fee is Exos's cost, not the
--     organizer's, so the journal books what was withheld.
--   * a refund returns the application fee in proportion (settlement.ts
--     orderNetAfterRefunds), cumulative per order so partial refunds never
--     drift by a cent; its tax share is the credit note's when one was issued.
--   * marketplace orders from exos_marketplace_orders (proceeds, Exos fee,
--     organizer net), paid out through exos_org_payout_lines.
--   * POS cash (exos_pos_payments 'cash', exos_pos_paid_outs), split by the
--     order's lines as exos_pos_settlement_summary does.
-- Every entry balances (checked before the insert and again by a deferred
-- constraint trigger), amounts are integer cents, and nothing is ever
-- updated or deleted: a change is a further entry (a reversal or the
-- difference to the new state). A posting failure in a trigger is a WARNING
-- and never undoes the sale; the backfill catches it up (re-runnable).
--
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked
-- patches, an idempotent backfill). D4 authors; not applied. Prod apply
-- needs operator OK.
-- ROLLBACK: DROP the triggers, the functions, the view and the two tables;
-- ALTER TABLE exos_checkout_sessions DROP COLUMN free_kind (after deleting
-- the rows with free_kind set); re-run the four patched functions' latest
-- migrations.
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
-- 1. The chart of accounts (fixed, the same for every org)
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
    ('marketplace_receivable',       1100, 'Marketplace receivable',                   'asset',          'debit'),
    ('organizer_payable',            2000, 'Organizer payable (owed to Exos)',         'liability',      'credit'),
    ('sales_tax_payable',            2100, 'Sales tax payable',                        'liability',      'credit'),
    ('promoter_commissions_payable', 2200, 'Promoter commissions payable',             'liability',      'credit'),
    ('gift_cards_outstanding',       2300, 'Gift cards outstanding',                   'liability',      'credit'),
    ('tips_payable',                 2400, 'Tips payable (POS)',                       'liability',      'credit'),
    ('ticket_revenue',               4000, 'Ticket revenue (face)',                    'revenue',        'credit'),
    ('buyer_fees',                   4010, 'Buyer fees',                               'revenue',        'credit'),
    ('pos_other_sales',              4020, 'Bar and merch sales (POS)',                'revenue',        'credit'),
    ('donations',                    4030, 'Donations',                                'revenue',        'credit'),
    ('refunds',                      4900, 'Refunds',                                  'contra_revenue', 'debit'),
    ('exos_fee',                     5000, 'Exos fee',                                 'expense',        'debit'),
    ('card_fees',                    5010, 'Card processing fees',                     'expense',        'debit'),
    ('disputes',                     5020, 'Disputes',                                 'expense',        'debit'),
    ('promoter_commissions',         5030, 'Promoter commissions',                     'expense',        'debit'),
    ('pos_paid_outs',                5040, 'Cash paid-outs (POS)',                     'expense',        'debit')
  ) a(code, number, name, type, normal)
$$;
REVOKE ALL ON FUNCTION public.exos_journal_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_journal_accounts() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._exos_journal_account_ok(p_code text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT p_code IN ('stripe_clearing', 'paypal_receivable', 'pos_cash_drawer', 'marketplace_receivable',
                    'organizer_payable', 'sales_tax_payable', 'promoter_commissions_payable', 'gift_cards_outstanding',
                    'tips_payable', 'ticket_revenue', 'buyer_fees', 'pos_other_sales', 'donations', 'refunds',
                    'exos_fee', 'card_fees', 'disputes', 'promoter_commissions', 'pos_paid_outs')
$$;
REVOKE ALL ON FUNCTION public._exos_journal_account_ok(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_journal_account_ok(text) TO authenticated, service_role;

-- ===========================================================================
-- 2. Tables
-- ===========================================================================
-- No foreign keys to orgs, events or the sources: the journal is a record
-- and outlives them (an append-only table can't take a cascade). It holds
-- no buyer data (no email, no name; memos name the source only).
CREATE TABLE IF NOT EXISTS public.exos_journal_entries (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  number       bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  org_id       uuid NOT NULL,
  event_id     uuid,
  source_table text NOT NULL CHECK (source_table IN (
                 'exos_checkout_sessions', 'exos_order_refunds', 'exos_fee_adjustments', 'exos_disputes',
                 'exos_marketplace_orders', 'exos_org_payout_lines', 'exos_promoter_commissions',
                 'exos_pos_payments', 'exos_pos_paid_outs')),
  source_id    text NOT NULL CHECK (char_length(source_id) BETWEEN 1 AND 300),
  kind         text NOT NULL CHECK (kind ~ '^[a-z_]{1,40}(:[0-9]{1,6})?$'),
  occurred_at  timestamptz NOT NULL,
  currency     text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  memo         text NOT NULL DEFAULT '' CHECK (char_length(memo) <= 300),
  session_id   text,
  basis_cents  bigint NOT NULL DEFAULT 0,
  reverses     uuid REFERENCES public.exos_journal_entries (id),
  total_cents  bigint NOT NULL CHECK (total_cents > 0),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_journal_entries_source_uq UNIQUE (source_table, source_id, kind)
);
CREATE INDEX IF NOT EXISTS exos_journal_entries_org_idx ON public.exos_journal_entries (org_id, occurred_at, number);
CREATE INDEX IF NOT EXISTS exos_journal_entries_event_idx ON public.exos_journal_entries (event_id) WHERE event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_journal_entries_session_idx ON public.exos_journal_entries (session_id) WHERE session_id IS NOT NULL;
COMMENT ON TABLE public.exos_journal_entries IS
  'Double-entry journal per org (mig 20261108100000, docs/journal.md). Append-only; one entry per (source_table, source_id, kind).';

CREATE TABLE IF NOT EXISTS public.exos_journal_lines (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entry_id     uuid NOT NULL REFERENCES public.exos_journal_entries (id),
  org_id       uuid NOT NULL,
  line_no      smallint NOT NULL CHECK (line_no BETWEEN 1 AND 50),
  account      text NOT NULL CHECK (public._exos_journal_account_ok(account)),
  debit_cents  bigint NOT NULL DEFAULT 0 CHECK (debit_cents >= 0),
  credit_cents bigint NOT NULL DEFAULT 0 CHECK (credit_cents >= 0),
  memo         text CHECK (memo IS NULL OR char_length(memo) <= 200),
  CONSTRAINT exos_journal_lines_one_side CHECK ((debit_cents = 0) <> (credit_cents = 0)),
  CONSTRAINT exos_journal_lines_no_uq UNIQUE (entry_id, line_no)
);
CREATE INDEX IF NOT EXISTS exos_journal_lines_org_idx ON public.exos_journal_lines (org_id, account);
COMMENT ON TABLE public.exos_journal_lines IS
  'Lines of exos_journal_entries: exactly one of debit / credit, integer cents; every entry sums to zero.';

-- Append-only, for the table owner too (corrections are new entries).
CREATE OR REPLACE FUNCTION public._exos_journal_guard()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'the journal is append-only: post a reversing entry instead' USING ERRCODE = '55000';
END $$;
REVOKE ALL ON FUNCTION public._exos_journal_guard() FROM PUBLIC, anon, authenticated;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_journal_entries', 'exos_journal_lines'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_append_only', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public._exos_journal_guard()',
                   t || '_append_only', t);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_no_truncate', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public._exos_journal_guard()',
                   t || '_no_truncate', t);
  END LOOP;
END $$;

-- Every entry balances: at commit, its lines sum to zero, there are at least
-- two, and the debits equal the entry's total. Deferred, so the writer can
-- insert the entry and then its lines.
CREATE OR REPLACE FUNCTION public._exos_journal_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_entry uuid; v_n int; v_dr bigint; v_cr bigint; v_total bigint; v_org uuid; v_bad_org boolean;
BEGIN
  IF TG_TABLE_NAME = 'exos_journal_entries' THEN
    v_entry := NEW.id;
  ELSE
    v_entry := NEW.entry_id;
  END IF;
  SELECT e.total_cents, e.org_id INTO v_total, v_org FROM public.exos_journal_entries e WHERE e.id = v_entry;
  SELECT count(*), coalesce(sum(l.debit_cents), 0), coalesce(sum(l.credit_cents), 0), bool_or(l.org_id <> v_org)
    INTO v_n, v_dr, v_cr, v_bad_org
    FROM public.exos_journal_lines l WHERE l.entry_id = v_entry;
  IF v_n < 2 OR v_dr <> v_cr OR v_dr <> v_total OR coalesce(v_bad_org, false) THEN
    RAISE EXCEPTION 'journal entry % does not balance (% lines, debits %, credits %, total %)', v_entry, v_n, v_dr, v_cr, v_total
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_journal_check() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_journal_entries_balanced ON public.exos_journal_entries;
CREATE CONSTRAINT TRIGGER exos_journal_entries_balanced AFTER INSERT ON public.exos_journal_entries
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public._exos_journal_check();
DROP TRIGGER IF EXISTS exos_journal_lines_balanced ON public.exos_journal_lines;
CREATE CONSTRAINT TRIGGER exos_journal_lines_balanced AFTER INSERT ON public.exos_journal_lines
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public._exos_journal_check();

-- RLS: owner / manager / finance of the org read; nobody writes from a client.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_journal_entries', 'exos_journal_lines'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_sel', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']))',
                   t || '_sel', t);
  END LOOP;
END $$;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_journal_entries', 'exos_journal_lines'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- One row per line, with its entry and account (the CSV and the API read
-- this; security_invoker, so the tables' RLS applies).
CREATE OR REPLACE VIEW public.exos_journal_rows WITH (security_invoker = true) AS
  SELECT l.id AS line_id, e.id AS entry_id, e.number AS entry_number, e.org_id, e.event_id,
         e.occurred_at, e.currency, e.source_table, e.source_id, e.kind, e.session_id, e.reverses,
         l.line_no, l.account, a.number AS account_number, a.name AS account_name, a.type AS account_type,
         l.debit_cents, l.credit_cents, coalesce(l.memo, e.memo) AS memo
    FROM public.exos_journal_lines l
    JOIN public.exos_journal_entries e ON e.id = l.entry_id
    JOIN public.exos_journal_accounts() a ON a.code = l.account;
REVOKE ALL ON public.exos_journal_rows FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.exos_journal_rows TO authenticated, service_role;

-- ===========================================================================
-- 3. The writer
-- ===========================================================================
-- Serializes postings for one source (and for one order's refunds).
CREATE OR REPLACE FUNCTION public._exos_journal_lock(p_key text)
RETURNS void LANGUAGE sql
SET search_path = public, pg_temp
AS $$
  SELECT pg_advisory_xact_lock(hashtextextended('exos_journal:' || p_key, 0))
$$;
REVOKE ALL ON FUNCTION public._exos_journal_lock(text) FROM PUBLIC, anon, authenticated;

-- Post one entry. p_lines: [{"a": account, "c": signed cents (+ debit,
-- − credit), "m": memo?}, …]; zero lines are dropped. Returns the entry id,
-- or NULL when there's nothing to post or the (source, kind) is already
-- posted (a second call, or a concurrent one that lost the race, is a no-op).
CREATE OR REPLACE FUNCTION public._exos_journal_post(
  p_org uuid, p_event uuid, p_source_table text, p_source_id text, p_kind text, p_at timestamptz,
  p_currency text, p_memo text, p_lines jsonb, p_session text DEFAULT NULL, p_basis bigint DEFAULT 0,
  p_reverses uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  l jsonb; v_sum bigint := 0; v_dr bigint := 0; v_n int := 0; v_id uuid; v_c bigint; i int := 0;
BEGIN
  IF p_org IS NULL THEN
    RAISE EXCEPTION 'journal: no org' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'journal: lines must be a list' USING ERRCODE = '22023';
  END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_c := coalesce((l ->> 'c')::bigint, 0);
    IF NOT public._exos_journal_account_ok(l ->> 'a') THEN
      RAISE EXCEPTION 'journal: unknown account %', l ->> 'a' USING ERRCODE = '22023';
    END IF;
    IF v_c <> 0 THEN
      v_n := v_n + 1; v_sum := v_sum + v_c;
      IF v_c > 0 THEN v_dr := v_dr + v_c; END IF;
    END IF;
  END LOOP;
  IF v_n = 0 THEN
    RETURN NULL;
  END IF;
  IF v_sum <> 0 OR v_n < 2 THEN
    RAISE EXCEPTION 'journal: % % % does not balance (off by % cents)', p_source_table, p_source_id, p_kind, v_sum
      USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.exos_journal_entries (org_id, event_id, source_table, source_id, kind, occurred_at, currency, memo,
                                           session_id, basis_cents, reverses, total_cents)
  VALUES (p_org, p_event, p_source_table, p_source_id, p_kind, coalesce(p_at, now()), upper(coalesce(p_currency, 'usd')),
          left(coalesce(p_memo, ''), 300), p_session, coalesce(p_basis, 0), p_reverses, v_dr)
  ON CONFLICT ON CONSTRAINT exos_journal_entries_source_uq DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RETURN NULL;
  END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_c := coalesce((l ->> 'c')::bigint, 0);
    CONTINUE WHEN v_c = 0;
    i := i + 1;
    INSERT INTO public.exos_journal_lines (entry_id, org_id, line_no, account, debit_cents, credit_cents, memo)
    VALUES (v_id, p_org, i, l ->> 'a', greatest(v_c, 0), greatest(-v_c, 0), left(nullif(l ->> 'm', ''), 200));
  END LOOP;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_journal_post(uuid, uuid, text, text, text, timestamptz, text, text, jsonb, text, bigint, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_journal_post(uuid, uuid, text, text, text, timestamptz, text, text, jsonb, text, bigint, uuid)
  TO service_role;

-- The first unused kind of a source: p_base, then p_base:2, p_base:3, …
CREATE OR REPLACE FUNCTION public._exos_journal_next_kind(p_table text, p_id text, p_base text)
RETURNS text LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM public.exos_journal_entries
                                WHERE source_table = p_table AND source_id = p_id AND kind = p_base)
              THEN p_base
              ELSE p_base || ':' || (SELECT count(*) + 1 FROM public.exos_journal_entries
                                      WHERE source_table = p_table AND source_id = p_id
                                        AND (kind = p_base OR kind LIKE p_base || ':%'))::text END
$$;
REVOKE ALL ON FUNCTION public._exos_journal_next_kind(text, text, text) FROM PUBLIC, anon, authenticated;

-- Bring a source's posted balance per account to p_target ({account: signed
-- cents}): posts the difference, if any, as p_kind_new (nothing posted yet),
-- p_kind_zero (the target is empty: a reversal) or p_kind_adjust. The
-- caller holds the source's lock.
CREATE OR REPLACE FUNCTION public._exos_journal_sync(
  p_org uuid, p_event uuid, p_table text, p_id text, p_at timestamptz, p_currency text, p_memo text,
  p_target jsonb, p_kind_new text, p_kind_adjust text, p_kind_zero text, p_session text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_lines jsonb; v_any boolean; v_target_empty boolean; v_kind text; v_last uuid;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.exos_journal_entries WHERE source_table = p_table AND source_id = p_id)
    INTO v_any;
  v_target_empty := NOT EXISTS (SELECT 1 FROM jsonb_each_text(coalesce(p_target, '{}'::jsonb)) t WHERE t.value::bigint <> 0);
  WITH posted AS (
    SELECT l.account, sum(l.debit_cents - l.credit_cents)::bigint AS cents
      FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
     WHERE e.source_table = p_table AND e.source_id = p_id
     GROUP BY l.account
  ), want AS (
    SELECT t.key AS account, t.value::bigint AS cents FROM jsonb_each_text(coalesce(p_target, '{}'::jsonb)) t
  ), diff AS (
    SELECT coalesce(w.account, p.account) AS account, coalesce(w.cents, 0) - coalesce(p.cents, 0) AS cents
      FROM want w FULL JOIN posted p ON p.account = w.account
  )
  SELECT jsonb_agg(jsonb_build_object('a', d.account, 'c', d.cents) ORDER BY abs(d.cents) DESC, d.account)
    INTO v_lines FROM diff d WHERE d.cents <> 0;
  IF v_lines IS NULL THEN
    RETURN NULL;
  END IF;
  v_kind := CASE WHEN NOT v_any THEN p_kind_new WHEN v_target_empty THEN p_kind_zero ELSE p_kind_adjust END;
  IF v_any AND v_target_empty THEN
    SELECT id INTO v_last FROM public.exos_journal_entries
     WHERE source_table = p_table AND source_id = p_id ORDER BY number DESC LIMIT 1;
  END IF;
  RETURN public._exos_journal_post(p_org, p_event, p_table, p_id, public._exos_journal_next_kind(p_table, p_id, v_kind),
                                   p_at, p_currency, p_memo, v_lines, p_session, 0, v_last);
END $$;
REVOKE ALL ON FUNCTION public._exos_journal_sync(uuid, uuid, text, text, timestamptz, text, text, jsonb, text, text, text, text)
  FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- 4. Posting each source
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_journal_paid(p_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$ SELECT p_status IN ('fulfilled', 'partially_refunded', 'refunded') $$;
REVOKE ALL ON FUNCTION public._exos_journal_paid(text) FROM PUBLIC, anon, authenticated;

-- 4a. An order: the sale and what was withheld, then any refunds already there.
CREATE OR REPLACE FUNCTION public.exos_journal_post_order(p_session text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s public.exos_checkout_sessions%ROWTYPE; v_id uuid; v_passed bigint; v_value bigint; v_clear text;
  v_app bigint; v_exos bigint; v_card bigint; v_owed bigint; r record;
BEGIN
  PERFORM public._exos_journal_lock('order:' || p_session);
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session;
  IF s.session_id IS NULL OR NOT public._exos_journal_paid(s.status) THEN
    RETURN NULL;
  END IF;
  v_value := coalesce(s.amount_cents, 0)::bigint + coalesce(s.gift_card_cents, 0);
  IF v_value <= 0 THEN
    RETURN NULL;   -- a $0 order (free claim, comp, pass, 100% code): no money, no entry
  END IF;
  SELECT coalesce(sum(f.amount_cents), 0) INTO v_passed FROM public.exos_order_fees f
   WHERE f.session_id = s.session_id AND f.kind = 'passed_on';
  v_clear := CASE WHEN s.processor = 'paypal' THEN 'paypal_receivable' ELSE 'stripe_clearing' END;
  v_app  := coalesce(s.application_fee_cents, 0);
  v_exos := least(greatest(coalesce(s.exos_fee_cents, v_app - coalesce(s.card_fee_est_cents, 0)), 0), v_app);
  v_card := v_app - v_exos;
  v_owed := coalesce(s.exos_fee_owed_cents, 0);
  v_id := public._exos_journal_post(
    s.org_id, s.event_id, 'exos_checkout_sessions', s.session_id, 'sale', coalesce(s.fulfilled_at, s.created_at),
    s.currency, 'Order ' || s.session_id,
    jsonb_build_array(
      jsonb_build_object('a', v_clear, 'c', coalesce(s.amount_cents, 0), 'm', 'Charged'),
      jsonb_build_object('a', 'gift_cards_outstanding', 'c', coalesce(s.gift_card_cents, 0), 'm', 'Paid by gift card'),
      jsonb_build_object('a', 'ticket_revenue', 'c', -(v_value - coalesce(s.tax_cents, 0) - v_passed - coalesce(s.donation_cents, 0))),
      jsonb_build_object('a', 'buyer_fees', 'c', -v_passed),
      jsonb_build_object('a', 'sales_tax_payable', 'c', -coalesce(s.tax_cents, 0)),
      jsonb_build_object('a', 'donations', 'c', -coalesce(s.donation_cents, 0)),
      jsonb_build_object('a', 'exos_fee', 'c', v_exos),
      jsonb_build_object('a', 'card_fees', 'c', v_card, 'm', 'Card-fee estimate in the application fee'),
      jsonb_build_object('a', v_clear, 'c', -v_app, 'm', 'Application fee withheld'),
      jsonb_build_object('a', 'exos_fee', 'c', v_owed, 'm', 'Exos fee not withheld (gift card)'),
      jsonb_build_object('a', 'organizer_payable', 'c', -v_owed)),
    s.session_id, v_value);
  -- Refunds recorded before the sale was posted (the backfill, a replay).
  FOR r IN SELECT id FROM public.exos_order_refunds WHERE session_id = s.session_id ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_refund(r.id);
  END LOOP;
  RETURN v_id;
END $$;

-- 4b. A refund (and its reversal when it fails later). The application fee
-- comes back in proportion; tax as the credit note says (else pro rata).
CREATE OR REPLACE FUNCTION public.exos_journal_post_refund(p_refund uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  rf public.exos_order_refunds%ROWTYPE; s public.exos_checkout_sessions%ROWTYPE;
  v_n_ref int; v_n_rev int; v_last uuid; v_lines jsonb; v_kind text;
  v_g bigint; v_value bigint; v_net bigint; v_app bigint; v_exos bigint; v_cum0 bigint; v_cum1 bigint; v_amt bigint;
  v_net_d bigint; v_exos_d bigint; v_card_d bigint; v_tax_d bigint; v_clear text; v_cn int;
BEGIN
  SELECT session_id INTO rf.session_id FROM public.exos_order_refunds WHERE id = p_refund;
  IF rf.session_id IS NULL THEN
    RETURN NULL;
  END IF;
  PERFORM public._exos_journal_lock('order:' || rf.session_id);
  SELECT * INTO rf FROM public.exos_order_refunds WHERE id = p_refund;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = rf.session_id;
  IF s.session_id IS NULL OR NOT public._exos_journal_paid(s.status) OR coalesce(s.amount_cents, 0) <= 0 THEN
    RETURN NULL;   -- never sold (a refund of a failed fulfilment nets out at Stripe), or nothing charged
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_journal_entries
                  WHERE source_table = 'exos_checkout_sessions' AND source_id = s.session_id AND kind = 'sale') THEN
    PERFORM public.exos_journal_post_order(s.session_id);   -- posts the sale, then this refund
    RETURN NULL;
  END IF;

  SELECT count(*) FILTER (WHERE kind = 'refund' OR kind LIKE 'refund:%'),
         count(*) FILTER (WHERE kind = 'refund_reversal' OR kind LIKE 'refund_reversal:%')
    INTO v_n_ref, v_n_rev
    FROM public.exos_journal_entries WHERE source_table = 'exos_order_refunds' AND source_id = rf.id::text;

  IF rf.status = 'succeeded' AND v_n_ref = v_n_rev THEN
    v_g := s.amount_cents;
    v_value := v_g + coalesce(s.gift_card_cents, 0) - coalesce(s.donation_cents, 0);
    v_app := coalesce(s.application_fee_cents, 0);
    v_exos := least(greatest(coalesce(s.exos_fee_cents, v_app - coalesce(s.card_fee_est_cents, 0)), 0), v_app);
    v_net := v_g - v_app;
    v_amt := least(greatest(rf.amount_cents, 0), v_g);
    SELECT coalesce(sum(basis_cents), 0) INTO v_cum0 FROM public.exos_journal_entries
     WHERE session_id = s.session_id AND source_table = 'exos_order_refunds';
    v_cum0 := least(greatest(v_cum0, 0), v_g);
    v_cum1 := least(v_cum0 + v_amt, v_g);
    v_amt := v_cum1 - v_cum0;
    IF v_amt <= 0 THEN
      RETURN NULL;
    END IF;
    v_net_d  := round(v_net::numeric * v_cum1 / v_g) - round(v_net::numeric * v_cum0 / v_g);
    v_exos_d := round(v_exos::numeric * v_cum1 / v_g) - round(v_exos::numeric * v_cum0 / v_g);
    v_card_d := (v_amt - v_net_d) - v_exos_d;
    SELECT c.tax_cents INTO v_cn FROM public.exos_credit_notes c WHERE c.refund_id = rf.id;
    v_tax_d := coalesce(v_cn::bigint,
                        CASE WHEN v_value > 0
                             THEN round(coalesce(s.tax_cents, 0)::numeric * least(v_cum1, v_value) / v_value)
                                  - round(coalesce(s.tax_cents, 0)::numeric * least(v_cum0, v_value) / v_value)
                             ELSE 0 END);
    v_tax_d := least(greatest(v_tax_d, 0), v_amt);
    v_clear := CASE WHEN s.processor = 'paypal' THEN 'paypal_receivable' ELSE 'stripe_clearing' END;
    v_kind := CASE WHEN v_n_ref = 0 THEN 'refund' ELSE 'refund:' || (v_n_ref + 1) END;
    RETURN public._exos_journal_post(
      s.org_id, s.event_id, 'exos_order_refunds', rf.id::text, v_kind, rf.created_at, coalesce(s.currency, rf.currency),
      'Refund of order ' || s.session_id,
      jsonb_build_array(
        jsonb_build_object('a', 'refunds', 'c', v_amt - v_tax_d),
        jsonb_build_object('a', 'sales_tax_payable', 'c', v_tax_d),
        jsonb_build_object('a', v_clear, 'c', -v_net_d, 'm', 'Pulled back from the organizer'),
        jsonb_build_object('a', 'exos_fee', 'c', -v_exos_d, 'm', 'Application fee returned'),
        jsonb_build_object('a', 'card_fees', 'c', -v_card_d, 'm', 'Application fee returned')),
      s.session_id, v_amt);
  ELSIF rf.status <> 'succeeded' AND v_n_ref > v_n_rev THEN
    SELECT id INTO v_last FROM public.exos_journal_entries
     WHERE source_table = 'exos_order_refunds' AND source_id = rf.id::text AND (kind = 'refund' OR kind LIKE 'refund:%')
     ORDER BY number DESC LIMIT 1;
    SELECT jsonb_agg(jsonb_build_object('a', l.account, 'c', l.credit_cents - l.debit_cents, 'm', l.memo) ORDER BY l.line_no)
      INTO v_lines FROM public.exos_journal_lines l WHERE l.entry_id = v_last;
    v_kind := CASE WHEN v_n_rev = 0 THEN 'refund_reversal' ELSE 'refund_reversal:' || (v_n_rev + 1) END;
    RETURN public._exos_journal_post(
      s.org_id, s.event_id, 'exos_order_refunds', rf.id::text, v_kind, coalesce(rf.updated_at, now()),
      coalesce(s.currency, rf.currency), 'Refund of order ' || s.session_id || ' failed: reversed', v_lines,
      s.session_id, -(SELECT basis_cents FROM public.exos_journal_entries WHERE id = v_last), v_last);
  END IF;
  RETURN NULL;
END $$;

-- 4c. The fee-change log: a reclassification, never cash. The buyer-fee part
-- of a refund moves from Refunds to Buyer fees; any other change moves
-- between Ticket revenue and Buyer fees.
CREATE OR REPLACE FUNCTION public.exos_journal_post_fee_adjustment(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE a public.exos_fee_adjustments%ROWTYPE; s public.exos_checkout_sessions%ROWTYPE; v_other text;
BEGIN
  SELECT * INTO a FROM public.exos_fee_adjustments WHERE id = p_id;
  IF a.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = a.session_id;
  IF s.session_id IS NULL OR NOT public._exos_journal_paid(s.status) THEN
    RETURN NULL;
  END IF;
  v_other := CASE WHEN a.reason IN ('refund', 'refund_reversed') THEN 'refunds' ELSE 'ticket_revenue' END;
  RETURN public._exos_journal_post(
    a.org_id, a.event_id, 'exos_fee_adjustments', a.id::text, 'fee_adjustment', a.processed_at, a.currency,
    'Fee change (' || a.reason || ') on order ' || a.session_id,
    jsonb_build_array(jsonb_build_object('a', 'buyer_fees', 'c', -a.fees_change_cents),
                      jsonb_build_object('a', v_other, 'c', a.fees_change_cents)),
    a.session_id, a.fees_change_cents);
END $$;

-- 4d. Disputes. A Stripe charge is a destination charge: a dispute debits
-- Exos's platform balance, not the organizer, so it touches the organizer's
-- books only when it is lost AND the org's policy recovers it
-- (exos_org_billing.recover_lost_disputes: amount + dispute fee owed to Exos).
-- Dropping the recovery (back to not_recovered) posts the reversal. PayPal
-- money sits with Exos: a lost PayPal dispute writes off what Exos still
-- owed the org for that order (as exos_paypal_order_owed).
CREATE OR REPLACE FUNCTION public.exos_journal_post_dispute(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE d public.exos_disputes%ROWTYPE; s public.exos_checkout_sessions%ROWTYPE; v_target jsonb := '{}'::jsonb;
        v_x bigint; v_ref bigint; v_app bigint;
BEGIN
  PERFORM public._exos_journal_lock('dispute:' || p_id);
  SELECT * INTO d FROM public.exos_disputes WHERE id = p_id;
  IF d.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = d.session_id;
  IF d.status = 'lost' AND d.provider = 'stripe'
     AND d.recovery_status IN ('recovery_pending', 'recovered') THEN
    v_x := coalesce(d.recovery_candidate_cents, coalesce(d.amount_cents, 0) + coalesce(d.fee_cents, 0));
    v_target := jsonb_build_object('disputes', v_x, 'organizer_payable', -v_x);
  ELSIF d.status = 'lost' AND d.provider = 'paypal' AND s.session_id IS NOT NULL AND public._exos_journal_paid(s.status)
        AND coalesce(s.amount_cents, 0) > 0 THEN
    v_app := coalesce(s.application_fee_cents, 0);
    SELECT coalesce(sum(amount_cents), 0) INTO v_ref FROM public.exos_order_refunds
     WHERE session_id = s.session_id AND status = 'succeeded';
    v_x := greatest(0, s.amount_cents - v_app - (v_ref - round(v_app::numeric * v_ref / s.amount_cents)));
    v_target := jsonb_build_object('disputes', v_x, 'paypal_receivable', -v_x);
  END IF;
  RETURN public._exos_journal_sync(
    d.org_id, coalesce(d.event_id, s.event_id), 'exos_disputes', d.id::text, coalesce(d.closed_at, d.updated_at, now()),
    d.currency, 'Dispute ' || d.dispute_id || CASE WHEN s.session_id IS NOT NULL THEN ' on order ' || s.session_id ELSE '' END,
    v_target, 'dispute_lost', 'dispute_adjust', 'dispute_lost_reversal', d.session_id);
END $$;

-- 4e. A marketplace order: the organizer's net is receivable from Exos until
-- the payout. Re-priced: the difference; cancelled: reversed.
CREATE OR REPLACE FUNCTION public.exos_journal_post_marketplace(p_order uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE o public.exos_marketplace_orders%ROWTYPE; v_target jsonb := '{}'::jsonb; v_p bigint; v_f bigint;
BEGIN
  PERFORM public._exos_journal_lock('mkt:' || p_order);
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE id = p_order;
  IF o.id IS NULL OR o.org_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF o.organizer_net IS NOT NULL AND o.proceeds IS NOT NULL
     AND o.status <> 'cancelled' AND o.sale_status <> 'cancelled' THEN
    v_p := round(o.proceeds * 100);
    v_f := round(coalesce(o.exos_fee, 0) * 100);
    v_target := jsonb_build_object('marketplace_receivable', v_p - v_f, 'exos_fee', v_f, 'ticket_revenue', -v_p);
  END IF;
  RETURN public._exos_journal_sync(
    o.org_id, o.event_id, 'exos_marketplace_orders', o.id::text, coalesce(o.sold_at, o.created_at), coalesce(o.currency, 'usd'),
    initcap(o.channel) || ' order ' || coalesce(o.external_order_id, o.id::text),
    v_target, 'mkt_sale', 'mkt_adjust', 'mkt_cancel');
END $$;

-- 4f. A payout line, once its payout is sent: the receivable becomes cash at
-- Stripe (a clawback line the other way). A sent payout that is later
-- failed / cancelled reverses.
CREATE OR REPLACE FUNCTION public.exos_journal_post_payout_line(p_line uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE l public.exos_org_payout_lines%ROWTYPE; p public.exos_org_payouts%ROWTYPE; o public.exos_marketplace_orders%ROWTYPE;
        v_target jsonb := '{}'::jsonb; v_c bigint;
BEGIN
  PERFORM public._exos_journal_lock('payline:' || p_line);
  SELECT * INTO l FROM public.exos_org_payout_lines WHERE id = p_line;
  IF l.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO p FROM public.exos_org_payouts WHERE id = l.payout_id;
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE id = l.order_id;
  IF p.status = 'sent' THEN
    v_c := round(l.amount * 100);
    v_target := CASE WHEN l.kind = 'clawback'
                     THEN jsonb_build_object('marketplace_receivable', abs(v_c), 'stripe_clearing', -abs(v_c))
                     ELSE jsonb_build_object('stripe_clearing', v_c, 'marketplace_receivable', -v_c) END;
  END IF;
  RETURN public._exos_journal_sync(
    l.org_id, o.event_id, 'exos_org_payout_lines', l.id::text, coalesce(p.sent_at, p.updated_at, l.created_at),
    coalesce(p.currency, o.currency, 'usd'), 'Marketplace payout ' || l.payout_id || ' (' || l.kind || ')',
    v_target, CASE WHEN l.kind = 'clawback' THEN 'mkt_clawback' ELSE 'mkt_payout' END, 'mkt_payout_adjust', 'mkt_payout_reversal');
END $$;

-- 4g. A promoter commission: accrued as an expense owed to the promoter,
-- moved out of Stripe cash when paid; reversed: the accrual goes. A
-- commission paid inside the Exos fee (method platform_fee) is Exos's cost
-- and never in the organizer's books.
CREATE OR REPLACE FUNCTION public.exos_journal_post_commission(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_promoter_commissions%ROWTYPE; v_acc jsonb := '{}'::jsonb; v_paid jsonb := '{}'::jsonb; v_id uuid; v_id2 uuid;
BEGIN
  PERFORM public._exos_journal_lock('commission:' || p_id);
  SELECT * INTO c FROM public.exos_promoter_commissions WHERE id = p_id;
  IF c.id IS NULL THEN
    RETURN NULL;
  END IF;
  IF c.method <> 'platform_fee' AND c.status IN ('accrued', 'paid') AND c.commission_cents > 0 THEN
    v_acc := jsonb_build_object('promoter_commissions', c.commission_cents, 'promoter_commissions_payable', -c.commission_cents);
  END IF;
  IF c.method <> 'platform_fee' AND c.status = 'paid' AND c.commission_cents > 0 THEN
    v_paid := jsonb_build_object('promoter_commissions_payable', c.commission_cents, 'stripe_clearing', -c.commission_cents);
  END IF;
  v_id := public._exos_journal_sync(
    c.org_id, c.event_id, 'exos_promoter_commissions', c.id::text, coalesce(c.reversed_at, c.accrued_at), c.currency,
    'Promoter commission (' || c.method || ')', v_acc, 'commission_accrued', 'commission_adjust', 'commission_reversed', c.session_id);
  v_id2 := public._exos_journal_sync(
    c.org_id, c.event_id, 'exos_promoter_commissions', c.id::text || ':paid', coalesce(c.paid_at, now()), c.currency,
    'Promoter commission paid (' || c.method || ')', v_paid, 'commission_paid', 'commission_paid_adjust', 'commission_paid_reversal',
    c.session_id);
  RETURN coalesce(v_id2, v_id);
END $$;

-- 4h. A POS cash tender: into the drawer, split by the order's lines (tax
-- pro rata to the order, tickets vs bar / merch by their net). Card tenders
-- and comps aren't here (docs/journal.md).
CREATE OR REPLACE FUNCTION public.exos_journal_post_pos_payment(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE p public.exos_pos_payments%ROWTYPE; o public.exos_pos_orders%ROWTYPE; v_ticket bigint; v_other bigint;
        v_tax bigint; v_net bigint; v_tk bigint;
BEGIN
  SELECT * INTO p FROM public.exos_pos_payments WHERE id = p_id;
  IF p.id IS NULL OR p.method <> 'cash' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p.order_id;
  SELECT coalesce(sum(line_total_cents - tax_cents) FILTER (WHERE category = 'ticket'), 0),
         coalesce(sum(line_total_cents - tax_cents) FILTER (WHERE category <> 'ticket'), 0)
    INTO v_ticket, v_other FROM public.exos_pos_order_lines WHERE order_id = p.order_id;
  v_tax := CASE WHEN coalesce(o.total_cents, 0) > 0 THEN round(p.amount_cents::numeric * o.tax_cents / o.total_cents) ELSE 0 END;
  v_net := p.amount_cents - v_tax;
  v_tk := CASE WHEN v_ticket + v_other > 0 THEN round(v_net::numeric * v_ticket / (v_ticket + v_other)) ELSE v_net END;
  RETURN public._exos_journal_post(
    p.org_id, p.event_id, 'exos_pos_payments', p.id::text, 'pos_cash_sale', p.created_at, o.currency,
    'POS cash sale ' || p.order_id,
    jsonb_build_array(
      jsonb_build_object('a', 'pos_cash_drawer', 'c', p.amount_cents + p.tip_cents),
      jsonb_build_object('a', 'tips_payable', 'c', -p.tip_cents),
      jsonb_build_object('a', 'sales_tax_payable', 'c', -v_tax),
      jsonb_build_object('a', 'ticket_revenue', 'c', -v_tk),
      jsonb_build_object('a', 'pos_other_sales', 'c', -(v_net - v_tk))),
    NULL, p.amount_cents);
END $$;

-- 4i. Cash out of a drawer: a void / refund hands the sale's cash back (tax
-- share pro rata to the order); a paid-out is an expense.
CREATE OR REPLACE FUNCTION public.exos_journal_post_pos_paid_out(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE x public.exos_pos_paid_outs%ROWTYPE; o public.exos_pos_orders%ROWTYPE; v_tax bigint; v_cur text;
BEGIN
  SELECT * INTO x FROM public.exos_pos_paid_outs WHERE id = p_id;
  IF x.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT coalesce(currency, 'usd') INTO v_cur FROM public.exos_events WHERE id = x.event_id;
  IF x.kind = 'paid_out' THEN
    RETURN public._exos_journal_post(
      x.org_id, x.event_id, 'exos_pos_paid_outs', x.id::text, 'pos_paid_out', x.created_at, v_cur, 'POS paid-out',
      jsonb_build_array(jsonb_build_object('a', 'pos_paid_outs', 'c', x.amount_cents),
                        jsonb_build_object('a', 'pos_cash_drawer', 'c', -x.amount_cents)),
      NULL, x.amount_cents);
  END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = x.order_id;
  v_tax := CASE WHEN coalesce(o.total_cents, 0) > 0 THEN round(x.amount_cents::numeric * o.tax_cents / o.total_cents) ELSE 0 END;
  RETURN public._exos_journal_post(
    x.org_id, x.event_id, 'exos_pos_paid_outs', x.id::text, 'pos_' || x.kind, x.created_at, coalesce(o.currency, v_cur),
    'POS ' || x.kind || ' ' || x.order_id,
    jsonb_build_array(jsonb_build_object('a', 'refunds', 'c', x.amount_cents - v_tax),
                      jsonb_build_object('a', 'sales_tax_payable', 'c', v_tax),
                      jsonb_build_object('a', 'pos_cash_drawer', 'c', -x.amount_cents, 'm', 'Cash handed back')),
    NULL, x.amount_cents);
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['exos_journal_post_order(text)', 'exos_journal_post_refund(uuid)',
                           'exos_journal_post_fee_adjustment(uuid)', 'exos_journal_post_dispute(uuid)',
                           'exos_journal_post_marketplace(uuid)', 'exos_journal_post_payout_line(uuid)',
                           'exos_journal_post_commission(uuid)', 'exos_journal_post_pos_payment(uuid)',
                           'exos_journal_post_pos_paid_out(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', f);
  END LOOP;
END $$;

-- ===========================================================================
-- 5. Triggers on the sources (a failure warns; the sale stands)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_tg_journal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record;
BEGIN
  BEGIN
    CASE TG_TABLE_NAME
      WHEN 'exos_checkout_sessions' THEN
        IF public._exos_journal_paid(NEW.status) THEN PERFORM public.exos_journal_post_order(NEW.session_id); END IF;
      WHEN 'exos_order_refunds' THEN PERFORM public.exos_journal_post_refund(NEW.id);
      WHEN 'exos_fee_adjustments' THEN PERFORM public.exos_journal_post_fee_adjustment(NEW.id);
      WHEN 'exos_disputes' THEN PERFORM public.exos_journal_post_dispute(NEW.id);
      WHEN 'exos_marketplace_orders' THEN PERFORM public.exos_journal_post_marketplace(NEW.id);
      WHEN 'exos_org_payout_lines' THEN PERFORM public.exos_journal_post_payout_line(NEW.id);
      WHEN 'exos_org_payouts' THEN
        FOR r IN SELECT id FROM public.exos_org_payout_lines WHERE payout_id = NEW.id LOOP
          PERFORM public.exos_journal_post_payout_line(r.id);
        END LOOP;
      WHEN 'exos_promoter_commissions' THEN PERFORM public.exos_journal_post_commission(NEW.id);
      WHEN 'exos_pos_payments' THEN PERFORM public.exos_journal_post_pos_payment(NEW.id);
      WHEN 'exos_pos_paid_outs' THEN PERFORM public.exos_journal_post_pos_paid_out(NEW.id);
      ELSE NULL;
    END CASE;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos journal: % on % (%): the backfill will post it', SQLERRM, TG_TABLE_NAME, SQLSTATE;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_journal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_checkout_journal ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_journal AFTER INSERT OR UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_order_refunds_journal ON public.exos_order_refunds;
CREATE TRIGGER exos_order_refunds_journal AFTER INSERT OR UPDATE OF status, amount_cents ON public.exos_order_refunds
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_fee_adjustments_journal ON public.exos_fee_adjustments;
CREATE TRIGGER exos_fee_adjustments_journal AFTER INSERT ON public.exos_fee_adjustments
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_disputes_journal ON public.exos_disputes;
CREATE TRIGGER exos_disputes_journal AFTER INSERT OR UPDATE OF status, recovery_status, recovery_candidate_cents ON public.exos_disputes
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_marketplace_orders_journal ON public.exos_marketplace_orders;
CREATE TRIGGER exos_marketplace_orders_journal
  AFTER INSERT OR UPDATE OF proceeds, exos_fee, organizer_net, status, sale_status ON public.exos_marketplace_orders
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_org_payout_lines_journal ON public.exos_org_payout_lines;
CREATE TRIGGER exos_org_payout_lines_journal AFTER INSERT ON public.exos_org_payout_lines
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_org_payouts_journal ON public.exos_org_payouts;
CREATE TRIGGER exos_org_payouts_journal AFTER UPDATE OF status ON public.exos_org_payouts
  FOR EACH ROW WHEN (NEW.status IS DISTINCT FROM OLD.status) EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_promoter_commissions_journal ON public.exos_promoter_commissions;
CREATE TRIGGER exos_promoter_commissions_journal AFTER INSERT OR UPDATE OF status, commission_cents ON public.exos_promoter_commissions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_pos_payments_journal ON public.exos_pos_payments;
CREATE TRIGGER exos_pos_payments_journal AFTER INSERT ON public.exos_pos_payments
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_pos_paid_outs_journal ON public.exos_pos_paid_outs;
CREATE TRIGGER exos_pos_paid_outs_journal AFTER INSERT ON public.exos_pos_paid_outs
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();

-- ===========================================================================
-- 6. Backfill (service role; re-runnable: every posting is idempotent)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_journal_backfill(p_org uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_before bigint; v_after bigint;
BEGIN
  SELECT count(*) INTO v_before FROM public.exos_journal_entries WHERE p_org IS NULL OR org_id = p_org;
  FOR r IN SELECT session_id FROM public.exos_checkout_sessions
            WHERE (p_org IS NULL OR org_id = p_org) AND public._exos_journal_paid(status)
            ORDER BY coalesce(fulfilled_at, created_at), session_id LOOP
    PERFORM public.exos_journal_post_order(r.session_id);   -- and its refunds
  END LOOP;
  FOR r IN SELECT id FROM public.exos_fee_adjustments WHERE p_org IS NULL OR org_id = p_org ORDER BY processed_at, id LOOP
    PERFORM public.exos_journal_post_fee_adjustment(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_disputes WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_dispute(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_marketplace_orders WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_marketplace(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_org_payout_lines WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_payout_line(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_promoter_commissions WHERE p_org IS NULL OR org_id = p_org ORDER BY accrued_at, id LOOP
    PERFORM public.exos_journal_post_commission(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_pos_payments
            WHERE (p_org IS NULL OR org_id = p_org) AND method = 'cash' ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_pos_payment(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_pos_paid_outs WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_pos_paid_out(r.id);
  END LOOP;
  SELECT count(*) INTO v_after FROM public.exos_journal_entries WHERE p_org IS NULL OR org_id = p_org;
  RETURN jsonb_build_object('org_id', p_org, 'posted', v_after - v_before, 'entries', v_after);
END $$;
REVOKE ALL ON FUNCTION public._exos_journal_backfill(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_journal_backfill(uuid) TO service_role;

-- ===========================================================================
-- 7. Reads: the trial balance and sales tax by jurisdiction
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_journal_reader_ok(p_org uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.exos_is_admin()
      OR public.exos_has_org_role(p_org, ARRAY['owner', 'manager', 'finance'])
      OR (auth.uid() IS NULL AND coalesce(auth.jwt() ->> 'role', '') = 'service_role')
$$;
REVOKE ALL ON FUNCTION public._exos_journal_reader_ok(uuid) FROM PUBLIC, anon, authenticated;

-- Movements per account and currency for entries dated in [p_from, p_to)
-- (NULL: unbounded). Balance is signed debit − credit. Optional event.
CREATE OR REPLACE FUNCTION public.exos_journal_trial_balance(p_org uuid, p_from timestamptz DEFAULT NULL,
                                                             p_to timestamptz DEFAULT NULL, p_event uuid DEFAULT NULL)
RETURNS TABLE (account text, account_number int, account_name text, account_type text, currency text,
               debit_cents bigint, credit_cents bigint, balance_cents bigint, entries bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_org IS NULL OR NOT public._exos_journal_reader_ok(p_org) THEN
    RAISE EXCEPTION 'exos_journal_trial_balance: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT a.code, a.number, a.name, a.type, e.currency,
           sum(l.debit_cents)::bigint, sum(l.credit_cents)::bigint, sum(l.debit_cents - l.credit_cents)::bigint,
           count(DISTINCT e.id)::bigint
      FROM public.exos_journal_lines l
      JOIN public.exos_journal_entries e ON e.id = l.entry_id
      JOIN public.exos_journal_accounts() a ON a.code = l.account
     WHERE e.org_id = p_org AND l.org_id = p_org
       AND (p_from IS NULL OR e.occurred_at >= p_from) AND (p_to IS NULL OR e.occurred_at < p_to)
       AND (p_event IS NULL OR e.event_id = p_event)
     GROUP BY a.code, a.number, a.name, a.type, e.currency
     ORDER BY e.currency, a.number;
END $$;
REVOKE ALL ON FUNCTION public.exos_journal_trial_balance(uuid, timestamptz, timestamptz, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_journal_trial_balance(uuid, timestamptz, timestamptz, uuid) TO authenticated, service_role;

-- Sales tax by jurisdiction: the event's venue (country, region, city,
-- postal code from venue_address) and the tax rule (name, rate) of each
-- line. Online: collected = the price-disclosure lines' tax (what doesn't
-- match a line is "unspecified"), refunded = the credit notes' tax spread over
-- the order's rates. POS: the order lines' tax on the part paid in money
-- (not a comp tender), refunded when the sale is voided or refunded. Dated by fulfilment / payment / credit note / reversal.
CREATE OR REPLACE FUNCTION public.exos_sales_tax_report(p_org uuid, p_from timestamptz DEFAULT NULL,
                                                        p_to timestamptz DEFAULT NULL, p_event uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_rows jsonb;
BEGIN
  IF p_org IS NULL OR NOT public._exos_journal_reader_ok(p_org) THEN
    RAISE EXCEPTION 'exos_sales_tax_report: not authorized' USING ERRCODE = '42501';
  END IF;
  WITH ev AS (
    SELECT e.id,
           nullif(upper(btrim(coalesce(e.venue_address ->> 'country', ''))), '') AS country,
           nullif(btrim(coalesce(e.venue_address ->> 'region', '')), '') AS region,
           nullif(btrim(coalesce(e.venue_address ->> 'city', '')), '') AS city,
           nullif(btrim(coalesce(e.venue_address ->> 'postal', '')), '') AS postal
      FROM public.exos_events e
     WHERE e.org_id = p_org AND (p_event IS NULL OR e.id = p_event)
  ), so AS (   -- paid orders with tax or lines, any date (refunds may fall in the period later)
    SELECT s.session_id, s.event_id, upper(coalesce(s.currency, 'usd')) AS currency, coalesce(s.tax_cents, 0)::bigint AS tax,
           (coalesce(s.amount_cents, 0) + coalesce(s.gift_card_cents, 0) - coalesce(s.donation_cents, 0))::bigint AS value,
           coalesce(s.fulfilled_at, s.created_at) AS at
      FROM public.exos_checkout_sessions s JOIN ev ON ev.id = s.event_id
     WHERE s.org_id = p_org AND public._exos_journal_paid(s.status) AND s.free_kind IS NULL
  ), sl AS (   -- per order and rate: tax and taxable base from the disclosure lines
    SELECT l.session_id, r.name AS tax_name, r.rate_percent AS rate,
           sum(l.tax_cents)::bigint AS tax, sum(l.line_total_cents - l.tax_cents)::bigint AS taxable
      FROM public.exos_price_disclosure_lines l
      JOIN so ON so.session_id = l.session_id
      LEFT JOIN public.exos_ticket_tiers tt ON l.kind = 'ticket' AND tt.id = l.item_id
      LEFT JOIN public.exos_event_addons ea ON l.kind = 'addon' AND ea.id = l.item_id
      LEFT JOIN public.exos_tax_rules r ON r.id = coalesce(tt.tax_rate_id, ea.tax_rate_id)
     WHERE coalesce(l.tax_cents, 0) <> 0 OR r.id IS NOT NULL
     GROUP BY l.session_id, r.name, r.rate_percent
  ), sg AS (   -- the order's groups, plus what the lines don't explain
    SELECT sl.session_id, sl.tax_name, sl.rate, sl.tax, sl.taxable FROM sl
    UNION ALL
    SELECT so.session_id, NULL, NULL, so.tax - coalesce(x.tax, 0),
           CASE WHEN x.session_id IS NULL THEN so.value - so.tax ELSE 0 END
      FROM so LEFT JOIN (SELECT session_id, sum(tax) AS tax FROM sl GROUP BY session_id) x ON x.session_id = so.session_id
     WHERE so.tax - coalesce(x.tax, 0) <> 0 OR (x.session_id IS NULL AND so.tax <> 0)
  ), sgw AS (   -- each group's share of the order's tax (largest gets the remainder)
    SELECT sg.*, sum(sg.tax) OVER (PARTITION BY sg.session_id) AS order_tax,
           row_number() OVER (PARTITION BY sg.session_id ORDER BY sg.tax DESC, sg.tax_name NULLS LAST, sg.rate) AS rk
      FROM sg
  ), cn AS (
    SELECT c.session_id, c.tax_cents::bigint AS tax, c.created_at
      FROM public.exos_credit_notes c JOIN so ON so.session_id = c.session_id
     WHERE c.org_id = p_org AND coalesce(c.tax_cents, 0) <> 0
       AND (p_from IS NULL OR c.created_at >= p_from) AND (p_to IS NULL OR c.created_at < p_to)
  ), cn_alloc AS (
    SELECT g.session_id, g.tax_name, g.rate,
           CASE WHEN g.order_tax = 0 THEN CASE WHEN g.rk = 1 THEN cn.tax ELSE 0 END
                ELSE (cn.tax * g.tax) / g.order_tax
                     + CASE WHEN g.rk = 1 THEN cn.tax - (SELECT coalesce(sum((cn.tax * g2.tax) / g2.order_tax), 0)
                                                          FROM sgw g2 WHERE g2.session_id = g.session_id) ELSE 0 END END AS tax
      FROM cn JOIN sgw g ON g.session_id = cn.session_id
  ), online AS (
    SELECT so.event_id, so.currency, g.tax_name, g.rate, 'online'::text AS source,
           count(DISTINCT so.session_id) AS orders, sum(g.taxable) AS taxable, sum(g.tax) AS collected, 0::bigint AS refunded
      FROM so JOIN sg g ON g.session_id = so.session_id
     WHERE (p_from IS NULL OR so.at >= p_from) AND (p_to IS NULL OR so.at < p_to)
     GROUP BY so.event_id, so.currency, g.tax_name, g.rate
    UNION ALL
    SELECT so.event_id, so.currency, a.tax_name, a.rate, 'online', 0, 0, 0, sum(a.tax)
      FROM cn_alloc a JOIN so ON so.session_id = a.session_id
     GROUP BY so.event_id, so.currency, a.tax_name, a.rate
  ), po AS (   -- the share of each door sale paid in money (a comp tender collects no tax)
    SELECT o.id, o.event_id, upper(coalesce(o.currency, 'usd')) AS currency, o.paid_at, o.status, o.total_cents::bigint AS total,
           coalesce((SELECT sum(p.amount_cents) FROM public.exos_pos_payments p
                      WHERE p.order_id = o.id AND p.method <> 'comp' AND p.status IN ('succeeded', 'refunded')), 0)::bigint AS paid
      FROM public.exos_pos_orders o JOIN ev ON ev.id = o.event_id
     WHERE o.org_id = p_org AND o.paid_at IS NOT NULL AND o.status IN ('paid', 'void', 'refunded') AND o.total_cents > 0
  ), pl AS (
    SELECT po.*, l.tax_rate_percent AS rate, (l.tax_cents::bigint * po.paid) / po.total AS tax,
           ((l.line_total_cents - l.tax_cents)::bigint * po.paid) / po.total AS taxable
      FROM po JOIN public.exos_pos_order_lines l ON l.order_id = po.id
     WHERE po.paid > 0
  ), pos AS (
    SELECT pl.event_id, pl.currency, NULL::text AS tax_name, pl.rate, 'pos'::text AS source,
           count(DISTINCT pl.id) AS orders, sum(pl.taxable)::bigint AS taxable, sum(pl.tax)::bigint AS collected, 0::bigint AS refunded
      FROM pl
     WHERE (p_from IS NULL OR pl.paid_at >= p_from) AND (p_to IS NULL OR pl.paid_at < p_to)
     GROUP BY pl.event_id, pl.currency, pl.rate
    UNION ALL
    SELECT pl.event_id, pl.currency, NULL, pl.rate, 'pos', 0, 0, 0, sum(pl.tax)::bigint
      FROM public.exos_pos_reversals rv JOIN pl ON pl.id = rv.order_id
     WHERE (p_from IS NULL OR rv.created_at >= p_from) AND (p_to IS NULL OR rv.created_at < p_to)
     GROUP BY pl.event_id, pl.currency, pl.rate
  ), allrows AS (
    SELECT * FROM online UNION ALL SELECT * FROM pos
  ), g AS (
    SELECT ev.country, ev.region, ev.city, ev.postal, a.tax_name, a.rate, a.source, a.currency,
           sum(a.orders)::bigint AS orders, sum(a.taxable)::bigint AS taxable, sum(a.collected)::bigint AS collected,
           sum(a.refunded)::bigint AS refunded
      FROM allrows a JOIN ev ON ev.id = a.event_id
     GROUP BY ev.country, ev.region, ev.city, ev.postal, a.tax_name, a.rate, a.source, a.currency
    HAVING sum(a.collected) <> 0 OR sum(a.refunded) <> 0
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'country', g.country, 'region', g.region, 'city', g.city, 'postal_code', g.postal,
           'tax_name', g.tax_name, 'rate_percent', g.rate, 'source', g.source, 'currency', g.currency,
           'orders', g.orders, 'taxable_cents', g.taxable, 'tax_collected_cents', g.collected,
           'tax_refunded_cents', g.refunded, 'net_tax_cents', g.collected - g.refunded)
           ORDER BY g.currency, g.country NULLS LAST, g.region NULLS LAST, g.city NULLS LAST, g.postal NULLS LAST,
                    g.source, g.tax_name NULLS LAST, g.rate NULLS LAST), '[]'::jsonb)
    INTO v_rows FROM g;
  RETURN jsonb_build_object('org_id', p_org, 'event_id', p_event, 'from', p_from, 'to', p_to, 'rows', v_rows,
                            'computed_at', now());
END $$;
REVOKE ALL ON FUNCTION public.exos_sales_tax_report(uuid, timestamptz, timestamptz, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_sales_tax_report(uuid, timestamptz, timestamptz, uuid) TO authenticated, service_role;

-- ===========================================================================
-- 8. $0 order rows for tickets minted with no order
-- ===========================================================================
-- free_kind marks an order Exos recorded for tickets that cost nothing and
-- had no checkout: reports, exports, fans and My Tickets see it; nothing
-- invoices it (the invoice trigger is UPDATE-only and skips $0) and the
-- journal has nothing to post for it.
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS free_kind text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_free_kind_chk'
                   AND conrelid = 'public.exos_checkout_sessions'::regclass) THEN
    ALTER TABLE public.exos_checkout_sessions ADD CONSTRAINT exos_checkout_sessions_free_kind_chk
      CHECK (free_kind IS NULL OR (free_kind IN ('free_claim', 'comp', 'rsvp', 'referral', 'pos_comp')
                                   AND amount_cents = 0 AND gift_card_cents = 0 AND donation_cents = 0));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_checkout_sessions_free_kind_idx ON public.exos_checkout_sessions (event_id)
  WHERE free_kind IS NOT NULL;
COMMENT ON COLUMN public.exos_checkout_sessions.free_kind IS
  'A $0 order Exos recorded for tickets minted without a checkout (mig 20261108100000): free_claim, comp, rsvp, referral, pos_comp.';

-- Every free ticket of one mint call (same transaction, event, order ref,
-- holder and kind) lands on one order. The id is new ('zero_' + 32 hex): the
-- tickets keep their order_ref, so refund, reschedule and door paths, which
-- match tickets to orders by order_ref, see exactly what they saw before.
CREATE OR REPLACE FUNCTION public._exos_zero_order_attach(t public.exos_tickets, p_kind text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text; v_uid uuid; v_owner_email text; v_sid text; v_cur text;
BEGIN
  v_email := lower(nullif(btrim(coalesce(t.buyer_email, '')), ''));
  v_uid := t.owner_id;
  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email) INTO v_owner_email FROM auth.users u WHERE u.id = v_uid;
    -- A comp parked on the staff member (no account yet) is the recipient's.
    IF v_email IS NOT NULL AND v_owner_email IS DISTINCT FROM v_email THEN
      v_uid := NULL;
    END IF;
  END IF;
  IF v_uid IS NULL AND (v_email IS NULL OR v_email !~ '^[^@\s]+@[^@\s]+$') THEN
    RETURN NULL;   -- nobody to record (a phone-only RSVP): the ticket stands alone, as before
  END IF;
  SELECT lower(coalesce(nullif(e.currency, ''), 'usd')) INTO v_cur FROM public.exos_events e WHERE e.id = t.event_id;
  -- A free claim mints each ticket under its own 'free_<uuid>' ref: one claim is one order all the same.
  v_sid := 'zero_' || md5(concat_ws(':', txid_current(), t.event_id,
                                    CASE WHEN t.order_ref ~ '^free_[0-9a-f-]{36}$' THEN '' ELSE coalesce(t.order_ref, '') END,
                                    v_uid, v_email, p_kind));
  INSERT INTO public.exos_checkout_sessions AS s (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, guest,
              quantity, amount_cents, currency, status, ticket_ids, fulfilled_at, tax_cents,
              application_fee_cents, exos_fee_cents, card_fee_est_cents, free_kind)
  VALUES (v_sid, t.event_id, t.tier_id, t.org_id, v_uid, v_email, v_uid IS NULL,
          1, 0, coalesce(v_cur, 'usd'), 'fulfilled', ARRAY[t.id], now(), 0, 0, 0, 0, p_kind)
  ON CONFLICT (session_id) DO UPDATE
     SET quantity = s.quantity + 1,
         ticket_ids = s.ticket_ids || EXCLUDED.ticket_ids,
         tier_id = CASE WHEN s.tier_id IS NOT DISTINCT FROM EXCLUDED.tier_id THEN s.tier_id END
   WHERE s.free_kind = EXCLUDED.free_kind AND s.event_id = EXCLUDED.event_id AND NOT (EXCLUDED.ticket_ids[1] = ANY (s.ticket_ids));
  RETURN v_sid;
END $$;
REVOKE ALL ON FUNCTION public._exos_zero_order_attach(public.exos_tickets, text) FROM PUBLIC, anon, authenticated;

-- Which minted tickets get one: no price, an Exos channel (the free claim's
-- vibepass / link:…, box office, comp batch, referral reward), and no order
-- of their own. Paid checkouts (order_ref = the session), marketplace
-- (their channel) and partner sales (po:…) have records already.
CREATE OR REPLACE FUNCTION public._exos_tg_ticket_zero_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_cs text := lower(btrim(coalesce(NEW.channel_source, ''))); v_kind text;
BEGIN
  IF coalesce(NEW.price_paid, 0) <> 0
     OR NOT (v_cs IN ('', 'vibepass', 'boxoffice', 'comp', 'referral_reward') OR v_cs LIKE 'link:%')
     OR coalesce(NEW.order_ref, '') LIKE 'po:%'
     OR (NEW.order_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_checkout_sessions s WHERE s.session_id = NEW.order_ref)) THEN
    RETURN NULL;
  END IF;
  v_kind := CASE WHEN coalesce(NEW.order_ref, '') LIKE 'pos:%' THEN 'pos_comp'
                 WHEN coalesce(NEW.order_ref, '') LIKE 'rsvp:%' THEN 'rsvp'
                 WHEN v_cs = 'referral_reward' THEN 'referral'
                 WHEN v_cs IN ('boxoffice', 'comp') THEN 'comp'
                 ELSE 'free_claim' END;
  BEGIN
    PERFORM public._exos_zero_order_attach(NEW, v_kind);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos zero order: % (ticket %)', SQLERRM, NEW.id;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_ticket_zero_order() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_zero_order ON public.exos_tickets;
CREATE TRIGGER exos_tickets_zero_order AFTER INSERT ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_ticket_zero_order();

-- Reports that count those tickets from exos_tickets already (channel lines,
-- buyer geo's "other tickets", the cash summary's comps), post money lines
-- (the reporting-row backfill: a $0 order has none), or count checkouts
-- a comp never started (in-app browser report), leave the $0 rows out.
SELECT pg_temp.exos_patch_n('public._exos_channel_lines(uuid)', '/* exos: zero orders */',
  $o$WHERE s.event_id = p_event_id AND s.status IN ('fulfilled', 'partially_refunded')$o$,
  $n$WHERE s.event_id = p_event_id AND s.status IN ('fulfilled', 'partially_refunded') AND s.free_kind IS NULL /* exos: zero orders */$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_buyer_geo(uuid,uuid,timestamptz,integer)', '/* exos: zero orders */',
  $o$AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded')$o$,
  $n$AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded') AND cs.free_kind IS NULL /* exos: zero orders */$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_cash_summary(uuid,uuid,timestamptz,timestamptz)', '/* exos: zero orders */',
  $o$s.status IN ('fulfilled', 'refunded', 'partially_refunded')$o$,
  $n$s.status IN ('fulfilled', 'refunded', 'partially_refunded') AND s.free_kind IS NULL /* exos: zero orders */$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_gl_backfill(uuid,uuid)', '/* exos: zero orders */',
  $o$WHERE s.event_id = p_event AND s.org_id = p_org AND s.status IN ('fulfilled', 'refunded', 'partially_refunded')$o$,
  $n$WHERE s.event_id = p_event AND s.org_id = p_org AND s.status IN ('fulfilled', 'refunded', 'partially_refunded') AND s.free_kind IS NULL /* exos: zero orders */$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_event_in_app_report(uuid)', '/* exos: zero orders */',
  $o$       WHERE s.event_id = p_event_id
       GROUP BY 1, 2$o$,
  $n$       WHERE s.event_id = p_event_id AND s.free_kind IS NULL /* exos: zero orders */
       GROUP BY 1, 2$n$, 1);

-- ===========================================================================
-- 9. Backfill what's already there
-- ===========================================================================
SELECT public._exos_journal_backfill(NULL);
