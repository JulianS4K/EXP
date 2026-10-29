-- ============================================================================
-- Posh: webhooks in, a capped Posh tier, Posh buyers on the door list
-- ============================================================================
-- Touches:  C: TABLE exos_posh_hooks, exos_posh_event_links, exos_posh_caps,
--              exos_posh_orders, exos_posh_webhook_log (all service role only)
--           C: FUNCTION exos_posh_connect, exos_posh_disconnect, exos_posh_status,
--              exos_posh_link_event, exos_posh_unlink_event, exos_posh_assign_order,
--              exos_posh_set_cap, exos_posh_ack_oversell, exos_posh_cancel_order,
--              exos_posh_event_status (authenticated, role-checked);
--              exos_posh_ingest, exos_posh_log_payload, _exos_posh_reserved,
--              _exos_posh_ref, _exos_posh_match, _exos_posh_count, _exos_posh_door,
--              _exos_posh_process (service role)
--           W: FUNCTION exos_channel_allocated (patched in place, one marker:
--              + the unsold part of each Posh cap)
--           W: exos_guest_lists / exos_guest_list_entries (a 'Posh' list per
--              event; one entry per Posh ticket code, source 'Posh')
--           W: exos_ticket_tiers.sold, exos_events.tickets_sold (a confirmed
--              Posh order takes its seats, like a Luma / Eventbrite sale)
-- Pre-reqs: 20260926193000 (exos_channel_allocated), 20261013090000 (door
--           imports: external_code / source), 20261019120000 (external_ref,
--           voided_at on guest entries), 20260929060000 (exos_rate_hit, used
--           by the edge function)
--
-- docs/organizer-guide.md "Selling on Posh too", docs/marketplace/posh.md.
--
-- Posh has no organizer API: Exos can't read or set a Posh event's capacity.
-- What Posh does have is webhooks (Organization Settings -> API Webhooks):
-- "Order Created" (a purchase completed) and "Pending Order Created" (a
-- purchase waiting for the organizer's approval). So Posh is a CAPPED TIER
-- (docs/SPEC-DISTRIBUTION-LAYER.md section 5):
--
--   * The organizer gives Posh a cap on one Exos ticket type: N seats carved
--     out of it (exos_posh_set_cap), and sets the same N as the capacity of
--     the event's tickets on Posh by hand. The unsold part of the cap
--     (cap - what Posh has sold) is held off every Exos sale the way a
--     marketplace allocation is: exos_channel_allocated counts it, and both
--     exos_tier_available and exos_event_house_available read that, so
--     checkout, comps, the box office, Eventbrite's and Luma's shared counts
--     can't sell a Posh seat. Growing the cap takes seats only if they are
--     free right now, under the tier row's lock (as exos_set_channel_allocation).
--   * It is NOT the marketplace allocation (exos_distribution_listings). That
--     row is read by the resale machinery: the 250-capacity resale rule
--     (20261014140000), the pool planners, the auto split and the
--     marketplace sync / distribute worker, which would try to list a
--     'posh' row on a resale site or plan it to 0 below 250. Posh is primary
--     ticketing, not resale, so it gets its own table and none of those rules.
--   * A confirmed order takes its seats from the cap: the Exos ticket type's
--     sold and the event's tickets_sold go up, the reserve goes down by the
--     same amount, so Exos's free count doesn't move. Past the cap is an
--     OVERSELL (rule 3): it is never absorbed quietly. The tickets past the
--     cap are recorded on the order and the cap (over_qty), shown to the
--     organizer until acknowledged, and noted on the buyer's door entry. They
--     still take a free Exos seat if one is free (the buyer is real and will
--     come; Exos must stop selling that seat), and what no free seat covers
--     is counted as uncovered (the room is over capacity).
--   * A pending order is recorded, takes no seat and gets no door entry.
--     Exos expects the approval to arrive as an "Order Created" for the same
--     Posh order id (unverified: Posh's payload isn't documented); that turns
--     the pending order into a confirmed one. A pending webhook after the
--     order is confirmed changes nothing.
--   * Orders are idempotent on (org, Posh order id), or on a hash of the
--     body when the payload has no order id we can find. Exact redeliveries
--     (same body) are skipped by the log.
--   * Each order is matched to an Exos event through exos_posh_event_links
--     (a Posh event id, slug or name as it appears in the payloads -> an
--     Exos event). An order that matches nothing is "unmatched": it is kept,
--     counts nothing, and the organizer assigns it to an event (which also
--     links that Posh event for the next orders).
--   * Posh buyers go on the door list: a 'Posh' guest list per event, one
--     entry per ticket code in the payload (external_code, so the door app
--     scans it like an imported code), or one entry with plus-ones when the
--     payload carries no code. source = 'Posh'.
--
-- The webhook URL is /functions/v1/exos-posh-webhook/<token>. The token is 32
-- random bytes, shown once, stored as its SHA-256 (exos_posh_hooks), and
-- rotated by connecting again (the old URL stops at once). Nothing is ever
-- written to Posh.
--
-- Raw payloads are kept for replay in exos_posh_webhook_log (service role
-- only), with phone numbers, addresses and other extra personal fields
-- removed by the edge function before storing, and deleted after the hook's
-- retention window (default 30 days). Orders keep only the buyer's name and
-- email (the door and the attendee view need them).
--
-- Re-run safe. Prod apply needs operator OK.
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
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ---------------------------------------------------------------------------
-- 1. Tables (service role only; the RPCs below are the only client surface).
-- ---------------------------------------------------------------------------
-- One webhook per org.
CREATE TABLE IF NOT EXISTS public.exos_posh_hooks (
  org_id           uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  token_hash       text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  token_hint       text NOT NULL CHECK (token_hint ~ '^[0-9a-f]{4}$'),
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  retention_days   integer NOT NULL DEFAULT 30 CHECK (retention_days BETWEEN 1 AND 90),
  received_count   bigint NOT NULL DEFAULT 0,
  last_received_at timestamptz,
  last_outcome     text CHECK (last_outcome IS NULL OR length(last_outcome) <= 40),
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  rotated_at       timestamptz
);
ALTER TABLE public.exos_posh_hooks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_posh_hooks FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_posh_hooks TO service_role;
COMMENT ON TABLE public.exos_posh_hooks IS
  'Posh webhook per org: SHA-256 of the URL token (shown once). Service role only. mig 20261029150000.';

-- A Posh event (its id, slug or name as the payloads carry it) -> an Exos event.
CREATE TABLE IF NOT EXISTS public.exos_posh_event_links (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  posh_ref    text NOT NULL CHECK (length(posh_ref) BETWEEN 1 AND 160 AND posh_ref !~ '[[:cntrl:]]'),
  posh_label  text CHECK (posh_label IS NULL OR length(posh_label) <= 200),
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, posh_ref)
);
CREATE INDEX IF NOT EXISTS exos_posh_event_links_event_idx ON public.exos_posh_event_links (event_id);
ALTER TABLE public.exos_posh_event_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_posh_event_links FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_posh_event_links TO service_role;

-- The capped Posh tier: one per event, carved out of one Exos ticket type.
CREATE TABLE IF NOT EXISTS public.exos_posh_caps (
  event_id      uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  tier_id       uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  cap           integer NOT NULL CHECK (cap BETWEEN 0 AND 100000),
  -- Posh tickets counted inside the cap (cap - cap_used is held off Exos).
  cap_used      integer NOT NULL DEFAULT 0 CHECK (cap_used >= 0 AND cap_used <= cap),
  -- Posh tickets past the cap (the oversell), how many of them the
  -- organizer has seen, and how many no free Exos seat covered.
  over_qty      integer NOT NULL DEFAULT 0 CHECK (over_qty >= 0),
  over_acked    integer NOT NULL DEFAULT 0 CHECK (over_acked >= 0),
  uncovered_qty integer NOT NULL DEFAULT 0 CHECK (uncovered_qty >= 0),
  updated_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_posh_caps_tier_idx ON public.exos_posh_caps (tier_id);
ALTER TABLE public.exos_posh_caps ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_posh_caps FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_posh_caps TO service_role;

-- One row per Posh order. event_id NULL = unmatched.
CREATE TABLE IF NOT EXISTS public.exos_posh_orders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- 'o:' + Posh's order id, or 'h:' + the body's SHA-256 when there is none.
  order_key       text NOT NULL CHECK (order_key ~ '^(o:[A-Za-z0-9_.:-]{1,128}|h:[0-9a-f]{64})$'),
  posh_order_id   text CHECK (posh_order_id IS NULL OR posh_order_id ~ '^[A-Za-z0-9_.:-]{1,128}$'),
  posh_event_id   text CHECK (posh_event_id IS NULL OR length(posh_event_id) <= 128),
  posh_event_slug text CHECK (posh_event_slug IS NULL OR length(posh_event_slug) <= 160),
  posh_event_name text CHECK (posh_event_name IS NULL OR length(posh_event_name) <= 200),
  event_id        uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  state           text NOT NULL CHECK (state IN ('pending', 'confirmed', 'cancelled')),
  quantity        integer NOT NULL CHECK (quantity BETWEEN 1 AND 100),
  ticket_label    text CHECK (ticket_label IS NULL OR length(ticket_label) <= 80),
  codes           text[] NOT NULL DEFAULT '{}' CHECK (cardinality(codes) <= 100),
  buyer_name      text CHECK (buyer_name IS NULL OR length(buyer_name) <= 80),
  buyer_email     text CHECK (buyer_email IS NULL OR (length(buyer_email) <= 254 AND buyer_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  total           numeric CHECK (total IS NULL OR (total >= 0 AND total < 10000000)),
  currency        text CHECK (currency IS NULL OR currency ~ '^[a-z]{3}$'),
  -- Seats: counted = the order has been applied to the count.
  counted         boolean NOT NULL DEFAULT false,
  cap_qty         integer NOT NULL DEFAULT 0 CHECK (cap_qty >= 0),
  house_qty       integer NOT NULL DEFAULT 0 CHECK (house_qty >= 0),
  over_qty        integer NOT NULL DEFAULT 0 CHECK (over_qty >= 0),
  uncovered_qty   integer NOT NULL DEFAULT 0 CHECK (uncovered_qty >= 0),
  tier_id         uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  attention       text CHECK (attention IS NULL OR length(attention) <= 200),
  posh_created_at timestamptz,
  received_at     timestamptz NOT NULL DEFAULT now(),
  confirmed_at    timestamptz,
  cancelled_at    timestamptz,
  cancelled_by    uuid,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, order_key)
);
CREATE INDEX IF NOT EXISTS exos_posh_orders_event_idx ON public.exos_posh_orders (event_id);
CREATE INDEX IF NOT EXISTS exos_posh_orders_unmatched_idx ON public.exos_posh_orders (org_id, received_at DESC) WHERE event_id IS NULL;
ALTER TABLE public.exos_posh_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_posh_orders FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_posh_orders TO service_role;
COMMENT ON TABLE public.exos_posh_orders IS
  'Posh orders from webhooks (buyer name + email only). Service role only; exos_posh_* RPCs. mig 20261029150000.';

-- Every delivery, with its (PII-trimmed) payload for replay, kept for the
-- hook's retention window.
CREATE TABLE IF NOT EXISTS public.exos_posh_webhook_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  received_at  timestamptz NOT NULL DEFAULT now(),
  body_hash    text NOT NULL CHECK (body_hash ~ '^[0-9a-f]{64}$'),
  kind         text NOT NULL CHECK (kind IN ('order_created', 'pending_order_created')),
  order_key    text,
  outcome      text NOT NULL CHECK (length(outcome) <= 40),
  -- Header NAMES only (to find a signature scheme later), never values.
  header_names text[] NOT NULL DEFAULT '{}' CHECK (cardinality(header_names) <= 60),
  payload      jsonb CHECK (payload IS NULL OR length(payload::text) <= 65536),
  UNIQUE (org_id, body_hash)
);
CREATE INDEX IF NOT EXISTS exos_posh_webhook_log_age_idx ON public.exos_posh_webhook_log (org_id, received_at);
ALTER TABLE public.exos_posh_webhook_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_posh_webhook_log FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_posh_webhook_log TO service_role;

-- ---------------------------------------------------------------------------
-- 2. The cap holds its unsold seats off every Exos sale.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_posh_reserved(p_tier_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(sum(greatest(c.cap - c.cap_used, 0)), 0)::int
    FROM public.exos_posh_caps c
    JOIN public.exos_events e ON e.id = c.event_id
   WHERE c.tier_id = p_tier_id AND e.status <> 'cancelled'
$$;
REVOKE ALL ON FUNCTION public._exos_posh_reserved(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_reserved(uuid) TO service_role;

-- exos_channel_allocated feeds exos_tier_available and
-- exos_event_house_available (and nothing in the resale planners).
SELECT pg_temp.exos_patch_n('public.exos_channel_allocated(uuid)',
  '_exos_posh_reserved',
  $o$  SELECT COALESCE(SUM(greatest(requested_qty, 0)), 0)::int
    FROM public.exos_distribution_listings$o$,
  $n$  -- + the unsold part of a Posh cap (mig 20261029150000)
  SELECT (COALESCE(SUM(greatest(requested_qty, 0)), 0) + public._exos_posh_reserved(p_tier_id))::int
    FROM public.exos_distribution_listings$n$, 1);

-- ---------------------------------------------------------------------------
-- 3. Helpers.
-- ---------------------------------------------------------------------------
-- How a Posh event reference is compared: lower case, spaces collapsed; a
-- posh.vip/e/<slug> link becomes the slug.
CREATE OR REPLACE FUNCTION public._exos_posh_ref(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN length(r) BETWEEN 1 AND 160 AND r !~ '[[:cntrl:]]' THEN r END
    FROM (SELECT left(btrim(regexp_replace(
                   regexp_replace(lower(coalesce(p, '')), '^\s*(https?://)?(www\.)?posh\.vip/e/([^/?#\s]+).*$', '\3'),
                   '\s+', ' ', 'g')), 160) AS r) x
$$;
REVOKE ALL ON FUNCTION public._exos_posh_ref(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_ref(text) TO service_role;

-- The Exos event a Posh order belongs to (id first, then slug, then name).
CREATE OR REPLACE FUNCTION public._exos_posh_match(p_org_id uuid, p_id text, p_slug text, p_name text)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT l.event_id FROM public.exos_posh_event_links l
    JOIN public.exos_events e ON e.id = l.event_id AND e.org_id = p_org_id
   WHERE l.org_id = p_org_id
     AND l.posh_ref IN (public._exos_posh_ref(p_id), public._exos_posh_ref(p_slug), public._exos_posh_ref(p_name))
   ORDER BY CASE l.posh_ref WHEN public._exos_posh_ref(p_id) THEN 0 WHEN public._exos_posh_ref(p_slug) THEN 1 ELSE 2 END
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_posh_match(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_match(uuid, text, text, text) TO service_role;

-- Count a confirmed, matched order once: seats from the cap first, then past
-- the cap (flagged) from Exos's free seats, then uncovered. Locks: the cap,
-- then the ticket type, then the event (as checkout).
CREATE OR REPLACE FUNCTION public._exos_posh_count(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o        public.exos_posh_orders%ROWTYPE;
  c        public.exos_posh_caps%ROWTYPE;
  t        public.exos_ticket_tiers%ROWTYPE;
  v_cap    int;
  v_room   int;
  v_excess int;
  v_free   int;
  v_house  int;
  v_take   int;
BEGIN
  SELECT * INTO o FROM public.exos_posh_orders WHERE id = p_order_id FOR UPDATE;
  IF o.id IS NULL OR o.counted OR o.state <> 'confirmed' OR o.event_id IS NULL THEN
    RETURN;
  END IF;
  SELECT * INTO c FROM public.exos_posh_caps WHERE event_id = o.event_id FOR UPDATE;
  IF c.event_id IS NULL THEN
    -- No Posh cap yet: everything is past the cap; nothing to take seats
    -- from until the organizer sets one (setting it counts this order).
    UPDATE public.exos_posh_orders
       SET attention = 'no Posh cap is set for this event: set one to count this order', updated_at = now()
     WHERE id = o.id;
    RETURN;
  END IF;
  -- Write the tier row (not only lock it) so a concurrent mint re-checks.
  UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = c.tier_id RETURNING * INTO t;
  PERFORM 1 FROM public.exos_events WHERE id = o.event_id FOR UPDATE;

  v_room := CASE WHEN t.capacity > 0 THEN greatest(t.capacity - t.sold, 0) ELSE o.quantity END;
  v_cap := least(o.quantity, greatest(c.cap - c.cap_used, 0), v_room);
  v_excess := o.quantity - least(o.quantity, greatest(c.cap - c.cap_used, 0));
  IF v_cap > 0 THEN
    UPDATE public.exos_posh_caps SET cap_used = cap_used + v_cap, updated_at = now() WHERE event_id = c.event_id;
    UPDATE public.exos_ticket_tiers SET sold = sold + v_cap WHERE id = c.tier_id;
    UPDATE public.exos_events SET tickets_sold = tickets_sold + v_cap WHERE id = o.event_id;
  END IF;
  -- Inside the cap but the ticket type had no room (its capacity was lowered
  -- under the cap): uncovered, though not past the cap.
  v_take := 0;
  IF v_excess > 0 THEN
    v_free  := greatest(coalesce(public.exos_effective_available(c.tier_id), v_excess), 0);
    v_house := coalesce(public.exos_event_house_available(o.event_id), v_excess);
    v_take  := least(v_excess, v_free, greatest(v_house, 0));
    IF v_take > 0 THEN
      UPDATE public.exos_ticket_tiers SET sold = sold + v_take WHERE id = c.tier_id;
      UPDATE public.exos_events SET tickets_sold = tickets_sold + v_take WHERE id = o.event_id;
    END IF;
  END IF;
  UPDATE public.exos_posh_caps
     SET over_qty = over_qty + v_excess,
         uncovered_qty = uncovered_qty + (o.quantity - v_cap - v_take),
         updated_at = now()
   WHERE event_id = c.event_id;
  UPDATE public.exos_posh_orders
     SET counted = true, tier_id = c.tier_id, cap_qty = v_cap, house_qty = v_take, over_qty = v_excess,
         uncovered_qty = o.quantity - v_cap - v_take,
         attention = CASE
           WHEN v_excess > 0 THEN format('oversold: %s ticket(s) past the Posh cap of %s', v_excess, c.cap)
           WHEN o.quantity - v_cap - v_take > 0 THEN 'the Exos ticket type had no room left for this order'
         END,
         updated_at = now()
   WHERE id = o.id;
END $$;
REVOKE ALL ON FUNCTION public._exos_posh_count(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_count(uuid) TO service_role;

-- Put a confirmed, matched order on the door list (once): the event's 'Posh'
-- list, one entry per ticket code, the tickets without a code as plus-ones.
CREATE OR REPLACE FUNCTION public._exos_posh_door(p_order_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o       public.exos_posh_orders%ROWTYPE;
  v_list  uuid;
  v_org   uuid;
  v_by    uuid;
  v_name  text;
  v_code  text;
  v_left  int;
  v_plus  int;
  v_n     int := 0;
  v_i     int := 0;
  v_note  text;
  v_codes text[];
BEGIN
  SELECT * INTO o FROM public.exos_posh_orders WHERE id = p_order_id;
  IF o.id IS NULL OR o.state <> 'confirmed' OR o.event_id IS NULL THEN
    RETURN 0;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_guest_list_entries g
              WHERE g.event_id = o.event_id AND g.external_ref LIKE 'posh:' || left(md5(o.order_key), 16) || '%') THEN
    RETURN 0;
  END IF;
  SELECT e.org_id, e.created_by INTO v_org, v_by FROM public.exos_events e WHERE e.id = o.event_id;
  SELECT id INTO v_list FROM public.exos_guest_lists WHERE event_id = o.event_id AND name = 'Posh' ORDER BY created_at LIMIT 1;
  IF v_list IS NULL THEN
    INSERT INTO public.exos_guest_lists (event_id, org_id, name, max_plus_ones, counts_toward_capacity, created_by)
    VALUES (o.event_id, v_org, 'Posh', 20, false, NULL) RETURNING id INTO v_list;
  END IF;
  v_name := left(coalesce(nullif(btrim(o.buyer_name), ''), split_part(o.buyer_email, '@', 1), 'Posh buyer'), 80);
  IF length(btrim(v_name)) < 1 THEN v_name := 'Posh buyer'; END IF;
  v_note := CASE WHEN o.over_qty > 0 THEN format('Posh oversell: %s of %s past the Posh cap', o.over_qty, o.quantity) END;
  -- Codes not already on this event's door list.
  SELECT coalesce(array_agg(x.c ORDER BY x.ord), '{}') INTO v_codes
    FROM (SELECT DISTINCT ON (public._exos_door_code(u.c)) public._exos_door_code(u.c) AS c, u.ord
            FROM unnest(o.codes) WITH ORDINALITY AS u(c, ord)
           WHERE public._exos_door_code(u.c) IS NOT NULL
           ORDER BY public._exos_door_code(u.c), u.ord) x
   WHERE NOT EXISTS (SELECT 1 FROM public.exos_guest_list_entries g WHERE g.event_id = o.event_id AND g.external_code = x.c);
  v_codes := v_codes[1:o.quantity];
  v_left := o.quantity - cardinality(v_codes);
  FOREACH v_code IN ARRAY v_codes LOOP
    v_i := v_i + 1;
    INSERT INTO public.exos_guest_list_entries (list_id, event_id, org_id, guest_name, email, plus_ones, note,
                                                external_code, ticket_label, source, external_ref)
    VALUES (v_list, o.event_id, v_org, v_name, o.buyer_email, 0, v_note, v_code, o.ticket_label, 'Posh',
            'posh:' || left(md5(o.order_key), 16) || '-' || v_i);
    v_n := v_n + 1;
  END LOOP;
  -- Tickets without a code: one entry with up to 20 plus-ones each.
  WHILE v_left > 0 LOOP
    v_i := v_i + 1;
    v_plus := least(v_left - 1, 20);
    INSERT INTO public.exos_guest_list_entries (list_id, event_id, org_id, guest_name, email, plus_ones, note,
                                                external_code, ticket_label, source, external_ref)
    VALUES (v_list, o.event_id, v_org, v_name, o.buyer_email, v_plus, v_note, NULL, o.ticket_label, 'Posh',
            'posh:' || left(md5(o.order_key), 16) || '-' || v_i);
    v_left := v_left - v_plus - 1;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_posh_door(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_door(uuid) TO service_role;

-- A confirmed, matched order: count it, then the door (so the door note
-- knows about an oversell).
CREATE OR REPLACE FUNCTION public._exos_posh_process(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_posh_count(p_order_id);
  PERFORM public._exos_posh_door(p_order_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_posh_process(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_process(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. The webhook (service role: the exos-posh-webhook edge function).
-- ---------------------------------------------------------------------------
-- p_token_hash: SHA-256 hex of the URL token. p_kind: order_created |
-- pending_order_created. p_order: what the parser found (any field may be
-- missing): {order_id, event_id, event_slug, event_name, quantity,
-- buyer_name, buyer_email, ticket_label, codes[], total, currency,
-- created_at}. p_payload: the PII-trimmed body for replay. p_replay: an
-- operator replay of a logged delivery (skips the redelivery check).
-- Returns {ok, outcome, order_id?}. Never raises on bad payload fields: they
-- are dropped.
CREATE OR REPLACE FUNCTION public.exos_posh_ingest(
  p_token_hash text, p_body_hash text, p_kind text, p_order jsonb,
  p_payload jsonb DEFAULT NULL, p_header_names text[] DEFAULT '{}', p_replay boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  h        public.exos_posh_hooks%ROWTYPE;
  o        public.exos_posh_orders%ROWTYPE;
  v_oid    text;
  v_key    text;
  v_qty    int;
  v_codes  text[];
  v_email  text;
  v_cur    text;
  v_total  numeric;
  v_at     timestamptz;
  v_event  uuid;
  v_out    text;
  v_state  text;
BEGIN
  IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', false, 'outcome', 'unknown_hook');
  END IF;
  SELECT * INTO h FROM public.exos_posh_hooks WHERE token_hash = p_token_hash AND status = 'active';
  IF h.org_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'outcome', 'unknown_hook');
  END IF;
  IF p_body_hash IS NULL OR p_body_hash !~ '^[0-9a-f]{64}$' OR p_kind NOT IN ('order_created', 'pending_order_created')
     OR p_order IS NULL OR jsonb_typeof(p_order) <> 'object' THEN
    RAISE EXCEPTION 'exos_posh_ingest: bad call' USING ERRCODE = '22023';
  END IF;
  v_state := CASE p_kind WHEN 'order_created' THEN 'confirmed' ELSE 'pending' END;

  -- Retention: this org's deliveries past the window go (a batch per call).
  DELETE FROM public.exos_posh_webhook_log
   WHERE id IN (SELECT id FROM public.exos_posh_webhook_log
                 WHERE org_id = h.org_id AND received_at < now() - make_interval(days => h.retention_days)
                 LIMIT 200);

  -- An exact redelivery is a no-op.
  IF NOT p_replay AND EXISTS (SELECT 1 FROM public.exos_posh_webhook_log WHERE org_id = h.org_id AND body_hash = p_body_hash) THEN
    UPDATE public.exos_posh_hooks SET received_count = received_count + 1, last_received_at = now(), last_outcome = 'duplicate'
     WHERE org_id = h.org_id;
    RETURN jsonb_build_object('ok', true, 'outcome', 'duplicate');
  END IF;

  -- Fields (anything that doesn't fit is dropped, not fatal).
  v_oid := CASE WHEN btrim(p_order ->> 'order_id') ~ '^[A-Za-z0-9_.:-]{1,128}$' THEN btrim(p_order ->> 'order_id') END;
  v_key := CASE WHEN v_oid IS NOT NULL THEN 'o:' || v_oid ELSE 'h:' || p_body_hash END;
  SELECT coalesce(array_agg(left(btrim(x), 128)) FILTER (WHERE btrim(x) <> ''), '{}') INTO v_codes
    FROM (SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_order -> 'codes') = 'array' THEN p_order -> 'codes' ELSE '[]' END) AS x
           LIMIT 100) s;
  v_qty := CASE WHEN (p_order ->> 'quantity') ~ '^[0-9]{1,3}$' AND (p_order ->> 'quantity')::int BETWEEN 1 AND 100
                THEN (p_order ->> 'quantity')::int END;
  -- NULL when the payload says nothing (a confirmation then keeps the pending order's).
  -- (least / greatest skip NULLs, hence the CASE.)
  v_qty := CASE WHEN coalesce(v_qty, nullif(cardinality(v_codes), 0)) IS NOT NULL
                THEN least(greatest(v_qty, nullif(cardinality(v_codes), 0)), 100) END;
  v_email := lower(btrim(coalesce(p_order ->> 'buyer_email', '')));
  v_email := CASE WHEN v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(v_email) <= 254 THEN v_email END;
  v_cur := CASE WHEN lower(p_order ->> 'currency') ~ '^[a-z]{3}$' THEN lower(p_order ->> 'currency') END;
  v_total := CASE WHEN (p_order ->> 'total') ~ '^[0-9]{1,7}(\.[0-9]{1,4})?$' THEN (p_order ->> 'total')::numeric END;
  BEGIN
    v_at := CASE WHEN length(p_order ->> 'created_at') <= 40 THEN (p_order ->> 'created_at')::timestamptz END;
  EXCEPTION WHEN others THEN v_at := NULL;
  END;

  SELECT * INTO o FROM public.exos_posh_orders WHERE org_id = h.org_id AND order_key = v_key FOR UPDATE;
  IF o.id IS NULL THEN
    v_event := public._exos_posh_match(h.org_id, p_order ->> 'event_id', p_order ->> 'event_slug', p_order ->> 'event_name');
    INSERT INTO public.exos_posh_orders (org_id, order_key, posh_order_id, posh_event_id, posh_event_slug, posh_event_name,
                                         event_id, state, quantity, ticket_label, codes, buyer_name, buyer_email, total,
                                         currency, posh_created_at, confirmed_at)
    VALUES (h.org_id, v_key, v_oid,
            left(nullif(btrim(p_order ->> 'event_id'), ''), 128), left(nullif(btrim(p_order ->> 'event_slug'), ''), 160),
            left(nullif(btrim(p_order ->> 'event_name'), ''), 200),
            v_event, v_state, coalesce(v_qty, 1), left(nullif(btrim(p_order ->> 'ticket_label'), ''), 80), v_codes,
            left(nullif(btrim(p_order ->> 'buyer_name'), ''), 80), v_email, v_total, v_cur, v_at,
            CASE WHEN v_state = 'confirmed' THEN now() END)
    RETURNING * INTO o;
    v_out := CASE WHEN v_event IS NULL THEN 'unmatched' WHEN v_state = 'pending' THEN 'pending' ELSE 'confirmed' END;
  ELSIF o.state = 'pending' AND v_state = 'confirmed' THEN
    -- The approval: the pending order becomes a sale. What the confirmation
    -- carries wins (Posh may only issue the codes now).
    UPDATE public.exos_posh_orders
       SET state = 'confirmed', confirmed_at = now(),
           quantity = coalesce(v_qty, quantity),
           codes = CASE WHEN cardinality(v_codes) > 0 THEN v_codes ELSE codes END,
           ticket_label = coalesce(left(nullif(btrim(p_order ->> 'ticket_label'), ''), 80), ticket_label),
           buyer_name = coalesce(left(nullif(btrim(p_order ->> 'buyer_name'), ''), 80), buyer_name),
           buyer_email = coalesce(v_email, buyer_email),
           total = coalesce(v_total, total), currency = coalesce(v_cur, currency),
           event_id = coalesce(event_id, public._exos_posh_match(h.org_id, p_order ->> 'event_id', p_order ->> 'event_slug', p_order ->> 'event_name')),
           updated_at = now()
     WHERE id = o.id RETURNING * INTO o;
    v_out := CASE WHEN o.event_id IS NULL THEN 'unmatched' ELSE 'confirmed' END;
  ELSE
    -- Same order again (or a pending after the confirmation, or a cancelled
    -- order): nothing changes.
    v_out := 'duplicate';
  END IF;

  IF v_out = 'confirmed' THEN
    PERFORM public._exos_posh_process(o.id);
  END IF;

  INSERT INTO public.exos_posh_webhook_log (org_id, body_hash, kind, order_key, outcome, header_names, payload)
  VALUES (h.org_id, p_body_hash, p_kind, v_key, v_out,
          coalesce((SELECT array_agg(left(lower(n), 60)) FROM (SELECT unnest(p_header_names) n LIMIT 60) s), '{}'),
          CASE WHEN p_payload IS NOT NULL AND length(p_payload::text) <= 65536 THEN p_payload END)
  ON CONFLICT (org_id, body_hash) DO UPDATE SET outcome = EXCLUDED.outcome, received_at = now();
  UPDATE public.exos_posh_hooks SET received_count = received_count + 1, last_received_at = now(), last_outcome = v_out
   WHERE org_id = h.org_id;
  RETURN jsonb_build_object('ok', true, 'outcome', v_out, 'order_id', o.id);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_ingest(text, text, text, jsonb, jsonb, text[], boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_posh_ingest(text, text, text, jsonb, jsonb, text[], boolean) TO service_role;

-- A logged delivery, for an operator replay (exos-posh-webhook /replay).
CREATE OR REPLACE FUNCTION public.exos_posh_log_payload(p_log_id uuid)
RETURNS TABLE (token_hash text, body_hash text, kind text, payload jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT h.token_hash, l.body_hash, l.kind, l.payload
    FROM public.exos_posh_webhook_log l JOIN public.exos_posh_hooks h ON h.org_id = l.org_id
   WHERE l.id = p_log_id AND l.payload IS NOT NULL
$$;
REVOKE ALL ON FUNCTION public.exos_posh_log_payload(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_posh_log_payload(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Organizer RPCs: the webhook (Org settings -> Integrations).
-- ---------------------------------------------------------------------------
-- Create (or rotate) the org's webhook. Owner / manager. Returns the token
-- once; only its hash is kept. The old URL stops working at once.
CREATE OR REPLACE FUNCTION public.exos_posh_connect(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tok  text := encode(extensions.gen_random_bytes(32), 'hex');
  v_hash text := encode(sha256(convert_to(v_tok, 'UTF8')), 'hex');
  v_new  boolean;
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_posh_connect: owner or manager only' USING ERRCODE = '42501';
  END IF;
  v_new := NOT EXISTS (SELECT 1 FROM public.exos_posh_hooks WHERE org_id = p_org_id);
  INSERT INTO public.exos_posh_hooks AS k (org_id, token_hash, token_hint, status, created_by)
  VALUES (p_org_id, v_hash, right(v_tok, 4), 'active', auth.uid())
  ON CONFLICT (org_id) DO UPDATE
     SET token_hash = EXCLUDED.token_hash, token_hint = EXCLUDED.token_hint, status = 'active', rotated_at = now();
  RETURN jsonb_build_object('token', v_tok, 'hint', right(v_tok, 4), 'rotated', NOT v_new);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_connect(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_connect(uuid) TO authenticated, service_role;

-- Stop accepting Posh webhooks (orders already in stay). Owner / manager.
CREATE OR REPLACE FUNCTION public.exos_posh_disconnect(p_org_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_posh_disconnect: owner or manager only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_posh_hooks SET status = 'disabled' WHERE org_id = p_org_id;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_disconnect(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_disconnect(uuid) TO authenticated, service_role;

-- What the integration screen shows. Owner / manager / finance. No token,
-- no buyer emails.
CREATE OR REPLACE FUNCTION public.exos_posh_status(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text := public._exos_integ_role(p_org_id, auth.uid());
  h      public.exos_posh_hooks%ROWTYPE;
BEGIN
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'exos_posh_status: not a member of this org' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO h FROM public.exos_posh_hooks WHERE org_id = p_org_id;
  RETURN jsonb_build_object(
    'connected', h.org_id IS NOT NULL AND h.status = 'active',
    'status', h.status,
    'hint', h.token_hint,
    'created_at', h.created_at,
    'rotated_at', h.rotated_at,
    'last_received_at', h.last_received_at,
    'last_outcome', h.last_outcome,
    'received', coalesce(h.received_count, 0),
    'can_manage', v_role IN ('owner', 'manager'),
    'counts', (SELECT jsonb_build_object(
        'orders', count(*),
        'confirmed', count(*) FILTER (WHERE state = 'confirmed' AND event_id IS NOT NULL),
        'pending', count(*) FILTER (WHERE state = 'pending' AND event_id IS NOT NULL),
        'unmatched', count(*) FILTER (WHERE event_id IS NULL AND state <> 'cancelled'),
        'tickets', coalesce(sum(quantity) FILTER (WHERE state = 'confirmed' AND event_id IS NOT NULL), 0),
        'oversold', coalesce(sum(over_qty) FILTER (WHERE state = 'confirmed'), 0))
        FROM public.exos_posh_orders WHERE org_id = p_org_id),
    'links', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', l.id, 'posh_ref', l.posh_ref, 'posh_label', l.posh_label, 'event_id', l.event_id,
        'event_name', e.name, 'starts_at', e.starts_at) ORDER BY e.starts_at DESC NULLS LAST, l.posh_ref)
        FROM public.exos_posh_event_links l JOIN public.exos_events e ON e.id = l.event_id
       WHERE l.org_id = p_org_id), '[]'::jsonb),
    'unmatched', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', u.id, 'posh_event_id', u.posh_event_id, 'posh_event_slug', u.posh_event_slug,
        'posh_event_name', u.posh_event_name, 'state', u.state, 'quantity', u.quantity,
        'ticket_label', u.ticket_label, 'received_at', u.received_at) ORDER BY u.received_at DESC)
        FROM (SELECT * FROM public.exos_posh_orders
               WHERE org_id = p_org_id AND event_id IS NULL AND state <> 'cancelled'
               ORDER BY received_at DESC LIMIT 50) u), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_status(uuid) TO authenticated, service_role;

-- Link a Posh event (id, slug, name or posh.vip/e/ link) to an Exos event,
-- and pick up the unmatched orders it covers. Owner / manager of the org,
-- and the event must be the org's.
CREATE OR REPLACE FUNCTION public.exos_posh_link_event(p_org_id uuid, p_posh_ref text, p_event_id uuid, p_label text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ref  text := public._exos_posh_ref(p_posh_ref);
  e      public.exos_events%ROWTYPE;
  v_id   uuid;
  r      record;
  v_n    int := 0;
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_posh_link_event: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR e.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'exos_posh_link_event: that event isn''t this organization''s' USING ERRCODE = '42501';
  END IF;
  IF v_ref IS NULL THEN
    RAISE EXCEPTION 'exos_posh_link_event: give the Posh event''s id, link or name' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_posh_event_links AS l (org_id, posh_ref, posh_label, event_id, created_by)
  VALUES (p_org_id, v_ref, left(nullif(btrim(coalesce(p_label, '')), ''), 200), p_event_id, auth.uid())
  ON CONFLICT (org_id, posh_ref) DO UPDATE SET event_id = EXCLUDED.event_id, posh_label = coalesce(EXCLUDED.posh_label, l.posh_label)
  RETURNING id INTO v_id;
  FOR r IN
    SELECT o.id FROM public.exos_posh_orders o
     WHERE o.org_id = p_org_id AND o.event_id IS NULL AND o.state <> 'cancelled'
       AND v_ref IN (public._exos_posh_ref(o.posh_event_id), public._exos_posh_ref(o.posh_event_slug), public._exos_posh_ref(o.posh_event_name))
     ORDER BY o.received_at
     FOR UPDATE
  LOOP
    UPDATE public.exos_posh_orders SET event_id = p_event_id, updated_at = now() WHERE id = r.id;
    PERFORM public._exos_posh_process(r.id);
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('id', v_id, 'posh_ref', v_ref, 'orders_matched', v_n);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_link_event(uuid, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_link_event(uuid, text, uuid, text) TO authenticated, service_role;

-- Remove a link (orders already matched stay with their event).
CREATE OR REPLACE FUNCTION public.exos_posh_unlink_event(p_link_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_posh_event_links WHERE id = p_link_id;
  IF v_org IS NULL OR coalesce(public._exos_integ_role(v_org, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_posh_unlink_event: owner or manager only' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_posh_event_links WHERE id = p_link_id;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_unlink_event(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_unlink_event(uuid) TO authenticated, service_role;

-- Assign an unmatched order to an event. Links the order's Posh event too
-- (by id, else slug, else name), so its other orders follow.
CREATE OR REPLACE FUNCTION public.exos_posh_assign_order(p_order_id uuid, p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o     public.exos_posh_orders%ROWTYPE;
  v_ref text;
  v_res jsonb;
BEGIN
  SELECT * INTO o FROM public.exos_posh_orders WHERE id = p_order_id;
  IF o.id IS NULL OR coalesce(public._exos_integ_role(o.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_posh_assign_order: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF o.event_id IS NOT NULL THEN
    RAISE EXCEPTION 'exos_posh_assign_order: that order is already on an event' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = o.org_id) THEN
    RAISE EXCEPTION 'exos_posh_assign_order: that event isn''t this organization''s' USING ERRCODE = '42501';
  END IF;
  v_ref := coalesce(public._exos_posh_ref(o.posh_event_id), public._exos_posh_ref(o.posh_event_slug), public._exos_posh_ref(o.posh_event_name));
  IF v_ref IS NOT NULL THEN
    v_res := public.exos_posh_link_event(o.org_id, v_ref, p_event_id, o.posh_event_name);
  END IF;
  -- An order with no event reference at all (or whose link pointed
  -- elsewhere) is assigned on its own.
  IF (SELECT event_id FROM public.exos_posh_orders WHERE id = o.id) IS NULL THEN
    UPDATE public.exos_posh_orders SET event_id = p_event_id, updated_at = now() WHERE id = o.id;
    PERFORM public._exos_posh_process(o.id);
  END IF;
  RETURN jsonb_build_object('ok', true, 'linked', v_ref, 'orders_matched', coalesce((v_res ->> 'orders_matched')::int, 1));
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_assign_order(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_assign_order(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Organizer RPCs: the event's Posh tier.
-- ---------------------------------------------------------------------------
-- Set the Posh cap: how many tickets of p_tier_id Posh may sell, sold
-- included. Owner / manager. Growing it takes seats only if they are free in
-- Exos right now; it can't go below what Posh has sold inside it. Not the
-- resale allocation: no capacity minimum applies. The first time a cap is
-- set, confirmed orders already in for the event are counted against it.
CREATE OR REPLACE FUNCTION public.exos_posh_set_cap(p_event_id uuid, p_tier_id uuid, p_cap integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e       public.exos_events%ROWTYPE;
  c       public.exos_posh_caps%ROWTYPE;
  t       public.exos_ticket_tiers%ROWTYPE;
  v_cur   int := 0;
  v_grow  int;
  v_free  int;
  v_house int;
  r       record;
  v_n     int := 0;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR coalesce(public._exos_integ_role(e.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_posh_set_cap: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_cap IS NULL OR p_cap < 0 OR p_cap > 100000 THEN
    RAISE EXCEPTION 'exos_posh_set_cap: the cap is 0 to 100000 tickets' USING ERRCODE = '22023';
  END IF;
  IF e.status = 'cancelled' AND p_cap > 0 THEN
    RAISE EXCEPTION 'exos_posh_set_cap: the event was cancelled' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO t FROM public.exos_ticket_tiers WHERE id = p_tier_id;
  IF t.id IS NULL OR t.event_id IS DISTINCT FROM p_event_id THEN
    RAISE EXCEPTION 'exos_posh_set_cap: ticket type not found for this event' USING ERRCODE = '22023';
  END IF;
  IF public.exos_tier_is_table(p_tier_id) THEN
    RAISE EXCEPTION 'exos_posh_set_cap: table ticket types can''t be capped for Posh' USING ERRCODE = '22023';
  END IF;
  IF t.capacity <= 0 THEN
    RAISE EXCEPTION 'exos_posh_set_cap: give the ticket type a capacity first' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_quota_tiers q WHERE q.tier_id = p_tier_id) THEN
    RAISE EXCEPTION 'exos_posh_set_cap: ticket types in a shared capacity group can''t be capped for Posh yet' USING ERRCODE = '22023';
  END IF;

  -- Locks: the cap, then the ticket type (written, so a mint re-checks).
  SELECT * INTO c FROM public.exos_posh_caps WHERE event_id = p_event_id FOR UPDATE;
  IF c.event_id IS NOT NULL AND c.tier_id <> p_tier_id AND (c.cap_used > 0 OR c.over_qty > 0) THEN
    RAISE EXCEPTION 'exos_posh_set_cap: Posh has sold % on another ticket type; it stays on that one', c.cap_used + c.over_qty
      USING ERRCODE = '22023';
  END IF;
  IF c.event_id IS NOT NULL AND p_cap < c.cap_used THEN
    RAISE EXCEPTION 'exos_posh_set_cap: Posh has already sold % inside the cap', c.cap_used USING ERRCODE = '23514';
  END IF;
  UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = p_tier_id;
  IF c.event_id IS NOT NULL AND c.tier_id = p_tier_id AND e.status <> 'cancelled' THEN
    v_cur := greatest(c.cap - c.cap_used, 0);
  END IF;
  v_grow := (p_cap - coalesce(c.cap_used, 0)) - v_cur;
  IF v_grow > 0 THEN
    v_free := greatest(coalesce(public.exos_effective_available(p_tier_id), v_grow), 0);
    v_house := public.exos_event_house_available(p_event_id);
    IF v_free < v_grow OR (v_house IS NOT NULL AND v_house < v_grow) THEN
      RAISE EXCEPTION 'exos_posh_set_cap: only % more ticket(s) free to give Posh', least(v_free, coalesce(v_house, v_free))
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF c.event_id IS NULL THEN
    INSERT INTO public.exos_posh_caps (event_id, org_id, tier_id, cap, updated_by)
    VALUES (p_event_id, e.org_id, p_tier_id, p_cap, auth.uid());
    -- Orders that came in before there was a cap.
    FOR r IN SELECT o.id FROM public.exos_posh_orders o
              WHERE o.event_id = p_event_id AND o.state = 'confirmed' AND NOT o.counted
              ORDER BY o.confirmed_at NULLS LAST, o.received_at LOOP
      PERFORM public._exos_posh_count(r.id);
      v_n := v_n + 1;
    END LOOP;
  ELSE
    UPDATE public.exos_posh_caps SET tier_id = p_tier_id, cap = p_cap, updated_by = auth.uid(), updated_at = now()
     WHERE event_id = p_event_id;
  END IF;
  SELECT * INTO c FROM public.exos_posh_caps WHERE event_id = p_event_id;
  RETURN jsonb_build_object('cap', c.cap, 'sold_in_cap', c.cap_used, 'remaining', greatest(c.cap - c.cap_used, 0),
                            'oversold', c.over_qty, 'orders_counted', v_n);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_set_cap(uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_set_cap(uuid, uuid, integer) TO authenticated, service_role;

-- The organizer has seen the oversell (the flag clears; the numbers stay).
CREATE OR REPLACE FUNCTION public.exos_posh_ack_oversell(p_event_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_n int;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR coalesce(public._exos_integ_role(v_org, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_posh_ack_oversell: owner or manager only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_posh_caps SET over_acked = over_qty, updated_at = now() WHERE event_id = p_event_id
  RETURNING over_qty INTO v_n;
  RETURN coalesce(v_n, 0);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_ack_oversell(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_ack_oversell(uuid) TO authenticated, service_role;

-- Cancel a Posh order in Exos (refunded or cancelled on Posh: Posh sends no
-- webhook for that). Its seats go back (inside the cap: back to Posh's
-- share), its door entries are voided. Owner / manager.
CREATE OR REPLACE FUNCTION public.exos_posh_cancel_order(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o    public.exos_posh_orders%ROWTYPE;
  v_n  int := 0;
BEGIN
  SELECT * INTO o FROM public.exos_posh_orders WHERE id = p_order_id;
  IF o.id IS NULL OR coalesce(public._exos_integ_role(o.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_posh_cancel_order: owner or manager only' USING ERRCODE = '42501';
  END IF;
  -- Locks: the cap, the ticket type, the event, then the order.
  IF o.event_id IS NOT NULL THEN
    PERFORM 1 FROM public.exos_posh_caps WHERE event_id = o.event_id FOR UPDATE;
  END IF;
  IF o.tier_id IS NOT NULL THEN
    PERFORM 1 FROM public.exos_ticket_tiers WHERE id = o.tier_id FOR UPDATE;
  END IF;
  IF o.event_id IS NOT NULL THEN
    PERFORM 1 FROM public.exos_events WHERE id = o.event_id FOR UPDATE;
  END IF;
  SELECT * INTO o FROM public.exos_posh_orders WHERE id = p_order_id FOR UPDATE;
  IF o.state = 'cancelled' THEN
    RETURN jsonb_build_object('ok', true, 'already', true);
  END IF;
  IF o.counted THEN
    UPDATE public.exos_posh_caps
       SET cap_used = greatest(cap_used - o.cap_qty, 0), over_qty = greatest(over_qty - o.over_qty, 0),
           over_acked = least(over_acked, greatest(over_qty - o.over_qty, 0)),
           uncovered_qty = greatest(uncovered_qty - o.uncovered_qty, 0), updated_at = now()
     WHERE event_id = o.event_id AND tier_id = o.tier_id;
    UPDATE public.exos_ticket_tiers SET sold = greatest(sold - o.cap_qty - o.house_qty, 0) WHERE id = o.tier_id;
    UPDATE public.exos_events SET tickets_sold = greatest(tickets_sold - o.cap_qty - o.house_qty, 0) WHERE id = o.event_id;
  END IF;
  IF o.event_id IS NOT NULL THEN
    UPDATE public.exos_guest_list_entries
       SET voided_at = now(), void_reason = 'Posh order cancelled'
     WHERE event_id = o.event_id AND external_ref LIKE 'posh:' || left(md5(o.order_key), 16) || '-%' AND voided_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  UPDATE public.exos_posh_orders
     SET state = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), counted = false,
         cap_qty = 0, house_qty = 0, over_qty = 0, uncovered_qty = 0, attention = NULL, updated_at = now()
   WHERE id = o.id;
  RETURN jsonb_build_object('ok', true, 'door_entries_voided', v_n);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_cancel_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_cancel_order(uuid) TO authenticated, service_role;

-- The event's Posh area. Owner / manager / finance (org staff: buyer names
-- and emails are shown to them, as on the attendee list).
CREATE OR REPLACE FUNCTION public.exos_posh_event_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e      public.exos_events%ROWTYPE;
  v_role text;
  c      public.exos_posh_caps%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  v_role := public._exos_integ_role(e.org_id, auth.uid());
  IF e.id IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'exos_posh_event_status: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO c FROM public.exos_posh_caps WHERE event_id = p_event_id;
  RETURN jsonb_build_object(
    'connected', EXISTS (SELECT 1 FROM public.exos_posh_hooks h WHERE h.org_id = e.org_id AND h.status = 'active'),
    'can_manage', v_role IN ('owner', 'manager'),
    'links', coalesce((SELECT jsonb_agg(jsonb_build_object('id', l.id, 'posh_ref', l.posh_ref, 'posh_label', l.posh_label) ORDER BY l.posh_ref)
                         FROM public.exos_posh_event_links l WHERE l.event_id = p_event_id), '[]'::jsonb),
    'cap', CASE WHEN c.event_id IS NOT NULL THEN jsonb_build_object(
        'tier_id', c.tier_id, 'tier_name', (SELECT name FROM public.exos_ticket_tiers WHERE id = c.tier_id),
        'cap', c.cap, 'sold_in_cap', c.cap_used, 'remaining', greatest(c.cap - c.cap_used, 0),
        'oversold', c.over_qty, 'oversold_unacked', greatest(c.over_qty - c.over_acked, 0),
        'uncovered', c.uncovered_qty, 'updated_at', c.updated_at) END,
    'sales', (SELECT jsonb_build_object(
        'confirmed_orders', count(*) FILTER (WHERE state = 'confirmed'),
        'confirmed_tickets', coalesce(sum(quantity) FILTER (WHERE state = 'confirmed'), 0),
        'pending_orders', count(*) FILTER (WHERE state = 'pending'),
        'pending_tickets', coalesce(sum(quantity) FILTER (WHERE state = 'pending'), 0),
        'uncounted_orders', count(*) FILTER (WHERE state = 'confirmed' AND NOT counted),
        'gross', sum(total) FILTER (WHERE state = 'confirmed'))
        FROM public.exos_posh_orders WHERE event_id = p_event_id),
    'orders', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', x.id, 'posh_order_id', x.posh_order_id, 'state', x.state, 'quantity', x.quantity,
        'ticket_label', x.ticket_label, 'buyer_name', x.buyer_name, 'buyer_email', x.buyer_email,
        'over_qty', x.over_qty, 'attention', x.attention, 'received_at', x.received_at,
        'confirmed_at', x.confirmed_at) ORDER BY x.received_at DESC)
        FROM (SELECT * FROM public.exos_posh_orders WHERE event_id = p_event_id
               ORDER BY received_at DESC LIMIT 100) x), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_event_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_event_status(uuid) TO authenticated, service_role;

-- ROLLBACK (manual): restore exos_channel_allocated from 20260926193000 (drop
-- the "+ public._exos_posh_reserved(p_tier_id)" term), then drop the
-- exos_posh_* functions and tables above.
