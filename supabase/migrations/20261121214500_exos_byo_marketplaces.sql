-- ============================================================================
-- 20261121214500_exos_byo_marketplaces.sql — sell on the organizer's OWN
-- marketplace accounts (BYO), DRY RUN ONLY
-- ============================================================================
-- Touches:  W: TABLE exos_distribution_listings (+ account: 'platform' | 'own')
--           C: TABLE exos_byo_allocations (RLS on, RPCs only)
--           C: FUNCTION _exos_byo_channels, _exos_byo_provider, _exos_byo_channel,
--              _exos_byo_listing, _exos_byo_ticket (internal), the trigger
--              _exos_tg_listing_account, exos_byo_set_allocation and
--              exos_byo_allocations_view (owner / manager)
--           W: FUNCTION exos_set_channel_allocation (6 counted patches: an own-
--              account channel skips the S4K / network / resale-capacity gates
--              of the Exos network route and refuses a $0 ticket type),
--              _exos_channel_split_plan (1: the auto split never touches an
--              own-account channel), exos_tg_marketplace_fee (2: no Exos fee on
--              an own-account sale), exos_journal_post_marketplace (1: an own-
--              account sale is off Exos's books), exos_tg_ticket_code_mode
--              (1: an own-account sale's tickets are static codes)
--           R: exos_org_integrations (the org's marketplace credentials,
--              providers stubhub / seatgeek / vivid / tevo since mig
--              20261016090000), exos_org_audit (event.byo_allocation)
-- Pre-reqs: 20260926193000 (allocations), 20261014090000 (auto split),
--           20261014140000 (resale gate), 20261108100000 (journal),
--           20261121133000 (priced once: exos_fee_bps), 20261121153000
--           (static codes), 20261121162400 (channel core)
--
-- Operator decisions (Julian, 2026-11-21):
--   * "150 or sellers own accounts" / "Both": tickets sold through the
--     organizer's OWN seller account are static PDF codes AND pay no Exos fee,
--     at any event size. Sales through Exos checkout on the same event still
--     follow the capacity rule (exos_event_fee_bps).
--   * Allocations are a % of each ticket type's capacity per marketplace:
--     floor(capacity * % / 100), at least 1 when the % is above 0. They can be
--     changed at any time but never below what that marketplace already sold;
--     every change is audited; no cooldown.
--   * Resale is never offered for a $0 ticket type (block).
--   * "For the APIs build and keep read only till build is complete": nothing
--     here talks to a marketplace. The listing writes are planned by
--     exos-distribute (as for the Exos network) and replayed as a dry run by
--     the channel core (exos-byo, _shared/channels/adapters/byoMarketplace.ts),
--     with the writes pinned off in code.
--
-- The model. An own-account channel is the SAME allocation row Exos already
-- keeps per (event, marketplace, ticket type) (mig 20260926193000): the seats
-- are set aside from Exos checkout the same way, a marketplace sale takes
-- them out of the allocation in the transaction that mints them, and the
-- listings are planned the same way. What changes is whose account it is:
--   exos_byo_allocations (event, channel, pct) says the organizer sells that
--   marketplace with their own account, and every allocation row of the event
--   on it is account 'own' (_exos_tg_listing_account keeps the column in step;
--   a row that has sold or is live can't change account). Then:
--     * fee: exos_tg_marketplace_fee prices the sale at 0 bps (kept, as every
--       sale's rate since mig 20261121133000);
--     * books: the money goes from the marketplace to the organizer's own
--       account, never through Exos, so exos_journal_post_marketplace posts
--       nothing (no marketplace receivable, nothing paid out);
--     * door: the tickets are static codes (exos_tg_ticket_code_mode), PDF
--       delivery, whatever the event's size;
--     * gates: the Exos network route's gates don't apply (S4K route, ticked
--       under Distribution, the resale capacity rule): it's the organizer's
--       own account. The $0 rule does.
--   One account per marketplace per event: own-account selling on a
--   marketplace the event is ticked for under Distribution (the Exos network)
--   is refused, and so is a switch while a row of the other account is
--   holding seats, sold or live.
--
-- Re-run safe (counted marker patches; tests/exos/reapply_check.sh).
-- D4 authors; applying to prod is operator-gated.
-- ROLLBACK (manual): DROP the new functions and table; ALTER TABLE
--   exos_distribution_listings DROP COLUMN account; re-run each patched
--   function's previous body.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  -- Pasted through a browser the patch text can carry CRLF line ends; compare without CRs.
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  IF position(p_marker in p_new) = 0 THEN
    RAISE EXCEPTION '%: the marker "%" is not in its own new text', p_fn, p_marker;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ---------------------------------------------------------------------------
-- 1. Which marketplaces, and the org credential each one reads.
--    The four with a listing plan in exos-distribute AND an org credential
--    (exos_org_integrations, mig 20261016090000). Gametime takes listings
--    only as an FTP inventory file of the whole account, TickPick has no
--    listing plan, GoTickets has no org credential: later.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_byo_channels()
RETURNS text[] LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$ SELECT ARRAY['stubhub', 'seatgeek', 'vivid', 'evo']::text[] $$;

CREATE OR REPLACE FUNCTION public._exos_byo_provider(p_channel text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$ SELECT CASE p_channel WHEN 'evo' THEN 'tevo' ELSE p_channel END $$;

GRANT EXECUTE ON FUNCTION public._exos_byo_channels() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._exos_byo_provider(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. The organizer's % per marketplace, per event.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_byo_allocations (
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  channel     text NOT NULL,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  pct         numeric(5,2) NOT NULL DEFAULT 0,
  updated_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, channel),
  CONSTRAINT exos_byo_allocations_channel_chk CHECK (channel = ANY (public._exos_byo_channels())),
  CONSTRAINT exos_byo_allocations_pct_chk CHECK (pct >= 0 AND pct <= 100)
);
ALTER TABLE public.exos_byo_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_byo_allocations FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_byo_allocations TO service_role;
CREATE INDEX IF NOT EXISTS exos_byo_allocations_org_idx ON public.exos_byo_allocations (org_id);

CREATE OR REPLACE FUNCTION public._exos_byo_channel(p_event_id uuid, p_channel text)
RETURNS boolean LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_byo_allocations WHERE event_id = p_event_id AND channel = p_channel)
$$;
REVOKE ALL ON FUNCTION public._exos_byo_channel(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_byo_channel(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Whose account each allocation row is.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_distribution_listings ADD COLUMN IF NOT EXISTS account text NOT NULL DEFAULT 'platform';
DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_distribution_listings_account_chk') THEN
    ALTER TABLE public.exos_distribution_listings ADD CONSTRAINT exos_distribution_listings_account_chk
      CHECK (account IN ('platform', 'own'));
  END IF;
END $c$;

CREATE OR REPLACE FUNCTION public._exos_byo_listing(p_listing_id uuid)
RETURNS boolean LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT p_listing_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.exos_distribution_listings WHERE id = p_listing_id AND account = 'own')
$$;
REVOKE ALL ON FUNCTION public._exos_byo_listing(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_byo_listing(uuid) TO service_role;

-- A ticket minted for an own-account sale: its order_ref is
-- '<channel>:<external order id>' (exos_fulfil_marketplace_order).
CREATE OR REPLACE FUNCTION public._exos_byo_ticket(p_channel text, p_order_ref text)
RETURNS boolean LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(p_channel, '') = ANY (public._exos_byo_channels())
     AND left(coalesce(p_order_ref, ''), length(p_channel) + 1) = p_channel || ':'
     AND EXISTS (SELECT 1
                   FROM public.exos_marketplace_orders mo
                   JOIN public.exos_distribution_listings dl ON dl.id = mo.distribution_listing_id
                  WHERE mo.channel = p_channel
                    AND mo.external_order_id = substr(p_order_ref, length(p_channel) + 2)
                    AND dl.account = 'own')
$$;
REVOKE ALL ON FUNCTION public._exos_byo_ticket(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_byo_ticket(text, text) TO service_role;

-- The column follows exos_byo_allocations; a row that has sold, holds seats
-- or is (or was) live on the marketplace keeps the account it has.
CREATE OR REPLACE FUNCTION public._exos_tg_listing_account()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_want text;
BEGIN
  v_want := CASE WHEN public._exos_byo_channel(NEW.event_id, NEW.channel) THEN 'own' ELSE 'platform' END;
  IF TG_OP = 'INSERT' THEN
    NEW.account := v_want;
    RETURN NEW;
  END IF;
  IF NEW.account IS DISTINCT FROM OLD.account THEN
    IF NEW.account IS DISTINCT FROM v_want THEN
      RAISE EXCEPTION 'exos_distribution_listings: the account follows exos_byo_allocations' USING ERRCODE = '42501';
    END IF;
    IF OLD.sold_qty > 0 OR coalesce(OLD.requested_qty, 0) > 0 OR OLD.external_listing_id IS NOT NULL
       OR OLD.listed_snapshot IS NOT NULL OR OLD.status IN ('listing', 'listed', 'delisting') THEN
      RAISE EXCEPTION 'exos_distribution_listings: this marketplace has sold, holds seats or is live on the other account'
        USING ERRCODE = '55000';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_listing_account() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_distribution_listings_account ON public.exos_distribution_listings;
CREATE TRIGGER exos_distribution_listings_account
  BEFORE INSERT OR UPDATE OF account ON public.exos_distribution_listings
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_listing_account();

-- ---------------------------------------------------------------------------
-- 4. The Exos network route's gates don't apply to the organizer's own
--    account; the $0 rule does. exos_set_channel_allocation's live body
--    (20260926193000, patched by 20261014090000 / 20261014140000 / 20261112*).
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid,text,uuid,integer)',
  '/* exos: byo decl */',
  E'  v_label  text;\n',
  E'  v_label  text;\n  v_own    boolean := false; /* exos: byo decl */\n', 1);
SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid,text,uuid,integer)',
  '/* exos: byo own account */',
  E'  v_label := CASE p_channel WHEN ''stubhub''',
  E'  v_own := public._exos_byo_channel(p_event_id, p_channel); /* exos: byo own account */\n  v_label := CASE p_channel WHEN ''stubhub''', 1);
SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid,text,uuid,integer)',
  '/* exos: byo s4k */',
  E'IF v_ev.distribution_route = ''s4k'' AND p_qty > 0 THEN',
  E'IF v_ev.distribution_route = ''s4k'' AND p_qty > 0 AND NOT v_own /* exos: byo s4k */ THEN', 1);
SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid,text,uuid,integer)',
  '/* exos: byo resale gate */',
  E'IF p_qty > 0 AND NOT public.exos_resale_unlocked(p_event_id) THEN',
  E'IF p_qty > 0 AND NOT v_own /* exos: byo resale gate */ AND NOT public.exos_resale_unlocked(p_event_id) THEN', 1);
SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid,text,uuid,integer)',
  '/* exos: byo networks */',
  E'IF p_qty > 0 AND (NOT (p_channel = ANY (coalesce(v_ev.distribution_networks, ''{}''::text[])))',
  E'IF p_qty > 0 AND NOT v_own /* exos: byo networks */ AND (NOT (p_channel = ANY (coalesce(v_ev.distribution_networks, ''{}''::text[])))', 1);
SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid,text,uuid,integer)',
  '/* exos: byo no free resale */',
  E'  IF public.exos_tier_is_table(p_tier_id) THEN',
  E'  IF v_own AND p_qty > 0 /* exos: byo no free resale */\n     AND coalesce((SELECT price FROM public.exos_ticket_tiers WHERE id = p_tier_id), 0) <= 0 THEN\n    RAISE EXCEPTION ''exos_set_channel_allocation: a $0 ticket type is never offered on a resale marketplace'' USING ERRCODE = ''22023'';\n  END IF;\n  IF public.exos_tier_is_table(p_tier_id) THEN', 1);

-- The auto split shares a ticket type across the Exos network's ticked
-- marketplaces: an own-account one is the organizer's, never split.
SELECT pg_temp.exos_patch_n('public._exos_channel_split_plan(uuid)',
  '/* exos: byo not split */',
  E'WHERE c = ANY (coalesce(e.distribution_networks, ''{}''::text[])) ORDER BY o);',
  E'WHERE c = ANY (coalesce(e.distribution_networks, ''{}''::text[]))\n                    AND NOT public._exos_byo_channel(p_event_id, c) /* exos: byo not split */ ORDER BY o);', 1);

-- ---------------------------------------------------------------------------
-- 5. No Exos fee on an own-account sale (priced once, as every sale since
--    mig 20261121133000), and none of its money on Exos's books.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_tg_marketplace_fee()',
  '/* exos: byo no fee */',
  E'      NEW.exos_fee_bps := public.exos_event_fee_bps(NEW.event_id, coalesce(NEW.sold_at, NEW.created_at, now()));',
  E'      NEW.exos_fee_bps := CASE WHEN public._exos_byo_listing(NEW.distribution_listing_id) THEN 0 /* exos: byo no fee */\n                               ELSE public.exos_event_fee_bps(NEW.event_id, coalesce(NEW.sold_at, NEW.created_at, now())) END;', 1);
SELECT pg_temp.exos_patch_n('public.exos_tg_marketplace_fee()',
  '/* exos: byo relinked */',
  E'    NEW.exos_fee_bps := OLD.exos_fee_bps;\n',
  E'    NEW.exos_fee_bps := OLD.exos_fee_bps;\n    -- A sale matched to its listing after it was first priced. /* exos: byo relinked */\n    IF NEW.distribution_listing_id IS DISTINCT FROM OLD.distribution_listing_id THEN\n      IF public._exos_byo_listing(NEW.distribution_listing_id) THEN\n        NEW.exos_fee_bps := 0;\n      ELSIF public._exos_byo_listing(OLD.distribution_listing_id) THEN\n        NEW.exos_fee_bps := public.exos_event_fee_bps(NEW.event_id, coalesce(NEW.sold_at, OLD.created_at, now()));\n      END IF;\n    END IF;\n', 1);

SELECT pg_temp.exos_patch_n('public.exos_journal_post_marketplace(uuid)',
  '/* exos: byo off the books */',
  E'  IF o.organizer_net IS NOT NULL AND o.proceeds IS NOT NULL\n',
  E'  IF o.organizer_net IS NOT NULL AND o.proceeds IS NOT NULL\n     AND NOT public._exos_byo_listing(o.distribution_listing_id) /* exos: byo off the books */\n', 1);

-- ---------------------------------------------------------------------------
-- 6. An own-account sale's tickets are static codes (PDF), at any size.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_tg_ticket_code_mode()',
  '/* exos: byo static */',
  E'    IF NEW.code_mode = ''static'' AND coalesce(current_setting(''exos.static_code_ok'', true), '''') = ''on'' THEN',
  E'    IF public._exos_byo_ticket(NEW.channel_source, NEW.order_ref) THEN\n      NEW.code_mode := ''static''; /* exos: byo static */\n      RETURN NEW;\n    END IF;\n    IF NEW.code_mode = ''static'' AND coalesce(current_setting(''exos.static_code_ok'', true), '''') = ''on'' THEN', 1);

-- ---------------------------------------------------------------------------
-- 7. Set a marketplace's % for the event (owner / manager).
--    Per ticket type: floor(capacity * pct / 100), at least 1 above 0; never
--    below what that marketplace sold (the % shown is the smallest allowed);
--    a $0 or table ticket type, or one without a capacity, is skipped with
--    the reason. Each ticket type goes through exos_set_channel_allocation
--    (its locks and free-seat check). Audited (event.byo_allocation).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_byo_set_allocation(p_event_id uuid, p_channel text, p_pct numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ev     public.exos_events%ROWTYPE;
  v_old    numeric;
  v_pct    numeric := round(coalesce(p_pct, -1), 2);
  v_label  text;
  t        record;
  d        public.exos_distribution_listings%ROWTYPE;
  v_qty    int;
  v_sold   int;
  v_min    numeric;
  v_tiers  jsonb := '[]'::jsonb;
  v_skip   jsonb := '[]'::jsonb;
  v_why    text;
BEGIN
  -- The route lock every allocation change takes (exos_set_channel_allocation).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_route:' || p_event_id::text, 0));
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_byo_set_allocation: event not found' USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NOT NULL
     AND NOT (public.exos_is_admin() OR public.exos_has_org_role(v_ev.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_byo_set_allocation: not authorized' USING ERRCODE = '42501';
  END IF;
  IF NOT (coalesce(p_channel, '') = ANY (public._exos_byo_channels())) THEN
    RAISE EXCEPTION 'exos_byo_set_allocation: pick one of %', array_to_string(public._exos_byo_channels(), ', ') USING ERRCODE = '22023';
  END IF;
  v_label := CASE p_channel WHEN 'stubhub' THEN 'StubHub' WHEN 'seatgeek' THEN 'SeatGeek' WHEN 'vivid' THEN 'Vivid Seats' WHEN 'evo' THEN 'Ticket Evolution' END;
  IF v_pct < 0 OR v_pct > 100 THEN
    RAISE EXCEPTION 'exos_byo_set_allocation: the share must be 0-100%%' USING ERRCODE = '22023';
  END IF;
  IF v_ev.status = 'cancelled' AND v_pct > 0 THEN
    RAISE EXCEPTION 'exos_byo_set_allocation: event is cancelled' USING ERRCODE = '22023';
  END IF;

  SELECT pct INTO v_old FROM public.exos_byo_allocations WHERE event_id = p_event_id AND channel = p_channel FOR UPDATE;
  IF NOT FOUND THEN
    -- One account per marketplace per event: not while the Exos network sells it.
    IF v_pct > 0 AND p_channel = ANY (coalesce(v_ev.distribution_networks, '{}'::text[])) THEN
      RAISE EXCEPTION 'exos_byo_set_allocation: % is ticked under Distribution (the Exos network sells it there): untick it first to sell it with your own account', v_label
        USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.exos_distribution_listings
                WHERE event_id = p_event_id AND channel = p_channel AND account = 'platform'
                  AND (sold_qty > 0 OR coalesce(requested_qty, 0) > 0 OR coalesce(sell_cap, 0) > 0
                       OR external_listing_id IS NOT NULL OR listed_snapshot IS NOT NULL
                       OR status IN ('listing', 'listed', 'delisting'))) THEN
      RAISE EXCEPTION 'exos_byo_set_allocation: the Exos network still has seats or sales on % for this event', v_label
        USING ERRCODE = '22023';
    END IF;
    IF v_pct = 0 THEN
      RETURN jsonb_build_object('channel', p_channel, 'pct', 0, 'tiers', '[]'::jsonb, 'skipped', '[]'::jsonb);
    END IF;
    INSERT INTO public.exos_byo_allocations (event_id, channel, org_id, pct, updated_by)
    VALUES (p_event_id, p_channel, v_ev.org_id, v_pct, auth.uid());
    -- Rows the Exos network left idle on it become the organizer's.
    UPDATE public.exos_distribution_listings SET account = 'own'
     WHERE event_id = p_event_id AND channel = p_channel AND account = 'platform';
  ELSE
    UPDATE public.exos_byo_allocations SET pct = v_pct, updated_by = auth.uid(), updated_at = now()
     WHERE event_id = p_event_id AND channel = p_channel;
  END IF;

  FOR t IN SELECT id, name, capacity, coalesce(price, 0) AS price
             FROM public.exos_ticket_tiers WHERE event_id = p_event_id ORDER BY sort_order, id LOOP
    -- The row first, as exos_set_channel_allocation and a marketplace sale take it,
    -- so a sale can't land between the sold floor read here and the change.
    SELECT * INTO d FROM public.exos_distribution_listings
     WHERE event_id = p_event_id AND channel = p_channel AND tier_id = t.id FOR UPDATE;
    v_sold := coalesce(d.sold_qty, 0);
    v_why := CASE
      WHEN coalesce(t.capacity, 0) <= 0 THEN 'no capacity set'
      WHEN public.exos_tier_is_table(t.id) THEN 'table ticket types aren''t sold on a marketplace'
      WHEN t.price <= 0 THEN 'a $0 ticket type is never offered on a resale marketplace'
    END;
    IF v_why IS NOT NULL THEN
      v_skip := v_skip || jsonb_build_object('tier_id', t.id, 'name', t.name, 'reason', v_why, 'sold', v_sold);
      IF d.id IS NOT NULL AND v_sold = 0 AND coalesce(d.sell_cap, 0) > 0 THEN
        PERFORM public.exos_set_channel_allocation(p_event_id, p_channel, t.id, 0);
      END IF;
      CONTINUE;
    END IF;
    v_qty := CASE WHEN v_pct = 0 THEN 0 ELSE greatest(floor(t.capacity * v_pct / 100.0)::int, 1) END;
    IF v_qty < v_sold THEN
      v_min := ceil(v_sold * 10000.0 / t.capacity) / 100.0;
      RAISE EXCEPTION 'exos_byo_set_allocation: % sold % of % already: the share can''t go below %',
        v_label, v_sold, t.name, to_char(v_min, 'FM990.00') || '%' USING ERRCODE = '22023';
    END IF;
    PERFORM public.exos_set_channel_allocation(p_event_id, p_channel, t.id, v_qty);
    v_tiers := v_tiers || jsonb_build_object('tier_id', t.id, 'name', t.name, 'capacity', t.capacity, 'quantity', v_qty, 'sold', v_sold);
  END LOOP;

  PERFORM public._exos_audit(v_ev.org_id, 'event.byo_allocation', 'event', p_event_id::text, p_event_id,
    jsonb_build_object('channel', p_channel, 'pct', jsonb_build_array(v_old, v_pct)),
    NULL, NULL, v_label || ' with your own account');
  RETURN jsonb_build_object('channel', p_channel, 'pct', v_pct, 'tiers', v_tiers, 'skipped', v_skip);
END $$;
REVOKE ALL ON FUNCTION public.exos_byo_set_allocation(uuid, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_byo_set_allocation(uuid, text, numeric) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. What the panel shows (owner / manager): per own-account marketplace, the
--    %, whether the org's credential is there, and per ticket type what is
--    allocated, held, sold and the smallest % allowed, plus the listings
--    exos-distribute planned (the payloads exos-byo replays as a dry run).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_byo_allocations_view(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ev  public.exos_events%ROWTYPE;
  v_out jsonb := '[]'::jsonb;
  c     text;
  v_pct numeric;
  v_tiers jsonb;
  v_conn boolean;
  v_min numeric;
BEGIN
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_byo_allocations_view: event not found' USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NOT NULL
     AND NOT (public.exos_is_admin() OR public.exos_has_org_role(v_ev.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_byo_allocations_view: not authorized' USING ERRCODE = '42501';
  END IF;
  FOREACH c IN ARRAY public._exos_byo_channels() LOOP
    SELECT pct INTO v_pct FROM public.exos_byo_allocations WHERE event_id = p_event_id AND channel = c;
    SELECT EXISTS (SELECT 1 FROM public.exos_org_integrations i
                    WHERE i.org_id = v_ev.org_id AND i.provider = public._exos_byo_provider(c)
                      AND i.secret_id IS NOT NULL AND i.status <> 'disabled')
      INTO v_conn;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'tier_id', t.id, 'name', t.name, 'capacity', t.capacity, 'price', t.price,
             'allocated', coalesce(dl.sell_cap, 0), 'held', coalesce(dl.requested_qty, 0), 'sold', coalesce(dl.sold_qty, 0),
             'status', dl.status, 'account', dl.account,
             'min_pct', CASE WHEN coalesce(t.capacity, 0) > 0 THEN round(ceil(coalesce(dl.sold_qty, 0) * 10000.0 / t.capacity) / 100.0, 2) ELSE 0 END,
             'skip', CASE WHEN coalesce(t.capacity, 0) <= 0 THEN 'no capacity set'
                          WHEN public.exos_tier_is_table(t.id) THEN 'table ticket type'
                          WHEN coalesce(t.price, 0) <= 0 THEN 'a $0 ticket type is never offered on a resale marketplace' END,
             'planned_listing', dl.planned_listing,
             'listed', dl.listed_snapshot IS NOT NULL OR dl.external_listing_id IS NOT NULL)
           ORDER BY t.sort_order, t.id), '[]'::jsonb),
           coalesce(max(CASE WHEN coalesce(t.capacity, 0) > 0 THEN round(ceil(coalesce(dl.sold_qty, 0) * 10000.0 / t.capacity) / 100.0, 2) END), 0)
      INTO v_tiers, v_min
      FROM public.exos_ticket_tiers t
      LEFT JOIN public.exos_distribution_listings dl ON dl.event_id = p_event_id AND dl.channel = c AND dl.tier_id = t.id
     WHERE t.event_id = p_event_id;
    v_out := v_out || jsonb_build_object(
      'channel', c, 'provider', public._exos_byo_provider(c), 'own', v_pct IS NOT NULL, 'pct', coalesce(v_pct, 0),
      'min_pct', v_min, 'connected', v_conn,
      'network_ticked', c = ANY (coalesce(v_ev.distribution_networks, '{}'::text[])),
      'tiers', v_tiers);
  END LOOP;
  RETURN jsonb_build_object(
    'event', jsonb_build_object('id', v_ev.id, 'org_id', v_ev.org_id, 'name', v_ev.name, 'status', v_ev.status,
                                'free_tier', coalesce(public.exos_event_is_free_tier(p_event_id), false)),
    'dry_run', true,
    'channels', v_out);
END $$;
REVOKE ALL ON FUNCTION public.exos_byo_allocations_view(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_byo_allocations_view(uuid) TO authenticated, service_role;
