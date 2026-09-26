-- ============================================================================
-- Migration 20260926193000 — Exos (Bridge / D4): channel seat allocations, so
--                            Exos and StubHub can't sell the same seat
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_channel_allocated, exos_quota_channel_allocated,
--              exos_set_channel_allocation (new)
--              FUNCTION exos_tier_available, exos_quota_available (patched in place,
--                one marker each, from their live definitions)
--              FUNCTION exos_fulfil_marketplace_order (replaced: consumes the allocation)
--           R: exos_distribution_listings, exos_ticket_tiers, exos_quotas, exos_events
-- Pre-reqs: 20260926192000 (marketplace orders), 20260702123030 (quotas),
--           20260925003000 (latest exos_tier_available), 20260926050000 (party size)
--
-- The problem: the seats on a StubHub listing are the same seats Exos sells
-- on its own storefront. A buyer on StubHub and a buyer on Exos can take the
-- last seat at the same moment; StubHub's sale then reaches Exos minutes
-- later (webhook / poll) and finds it gone. Syncing the listing quantity
-- after every Exos sale only narrows that window.
--
-- The fix is disjoint pools. Seats listed on a channel are ALLOCATED to it:
--   * exos_distribution_listings.requested_qty (with tier_id), while the row
--     is pending / planned / listing / listed / delisting, is taken out of
--     the tier's availability (exos_tier_available) and of every shared
--     quota the tier is in (exos_quota_available). Every Exos path that
--     sells or reserves a seat (checkout holds, free claims, comps, box
--     office, waitlist offers, referral rewards) reads those two, so none
--     of them can sell an allocated seat.
--   * A marketplace sale takes its seats out of the allocation first, in the
--     same transaction that mints them (exos_fulfil_marketplace_order), so it
--     never competes with Exos buyers at all. Selling more than was
--     allocated is flagged for a human.
--   * exos_set_channel_allocation(event, channel, tier, qty) sets the
--     allocation. Growing it takes seats only if they're free right now,
--     under the same locks as a cart hold (quotas, then the tier row), so it
--     can't race an Exos checkout either. Shrinking it (or delisting) gives
--     the seats back to Exos at once.
--
-- Two limits it enforces rather than papers over:
--   * The event-wide cap (exos_events.total_tickets) is checked separately by
--     every mint. If an organizer set it BELOW the sum of the ticket types'
--     capacities, a tier-level allocation can't protect the house cap, so
--     allocation is refused for that event with the reason.
--   * Table ticket types aren't sold on marketplaces.
-- Keep the StubHub listing quantity equal to the allocation: StubHub stops
-- selling at its quantity, Exos at capacity minus the allocation.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. What's allocated.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_channel_allocated(p_tier_id uuid)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(greatest(requested_qty, 0)), 0)::int
    FROM public.exos_distribution_listings
   WHERE tier_id = p_tier_id
     AND status IN ('pending','planned','listing','listed','delisting')
     AND requested_qty > 0
$$;
REVOKE ALL ON FUNCTION public.exos_channel_allocated(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_channel_allocated(uuid) TO authenticated, service_role;

-- In admissions, for shared quotas (a table tier counts party_size per unit).
CREATE OR REPLACE FUNCTION public.exos_quota_channel_allocated(p_quota_id uuid)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(greatest(d.requested_qty, 0) * public.exos_tier_party_size(d.tier_id)), 0)::int
    FROM public.exos_distribution_listings d
   WHERE d.tier_id IN (SELECT tier_id FROM public.exos_quota_tiers WHERE quota_id = p_quota_id)
     AND d.status IN ('pending','planned','listing','listed','delisting')
     AND d.requested_qty > 0
$$;
REVOKE ALL ON FUNCTION public.exos_quota_channel_allocated(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_quota_channel_allocated(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Availability excludes allocations. Patched from the live definitions
--    (one marker each; raises if the pattern isn't there exactly once; a
--    no-op once applied), like 20260924210103.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  p      record;
  v_def  text;
  v_hits int;
BEGIN
  FOR p IN
    SELECT * FROM (VALUES
      ('public.exos_tier_available(uuid)',
       '- COALESCE(v.blocked, 0))',
       '- COALESCE(v.blocked, 0) - public.exos_channel_allocated(t.id))'),
      ('public.exos_quota_available(uuid)',
       'v_size - v_used - v_held - v_blocked)',
       'v_size - v_used - v_held - v_blocked - public.exos_quota_channel_allocated(p_quota_id))')
    ) AS t(fn, pat, repl)
  LOOP
    v_def := pg_get_functiondef(p.fn::regprocedure);
    CONTINUE WHEN position(p.repl in v_def) > 0;   -- already patched
    v_hits := (length(v_def) - length(replace(v_def, p.pat, ''))) / length(p.pat);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'channel allocations: expected one "%" in %, found %', p.pat, p.fn, v_hits;
    END IF;
    EXECUTE replace(v_def, p.pat, p.repl);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Set a channel's allocation (org owner / manager, or the service role).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_channel_allocation(
  p_event_id uuid,
  p_channel  text,
  p_tier_id  uuid,
  p_qty      int
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ev     public.exos_events%ROWTYPE;
  d        public.exos_distribution_listings%ROWTYPE;
  v_tev    uuid;
  v_cur    int := 0;
  v_avail  int;
  v_sum    bigint;
  v_uncap  boolean;
  q        record;
BEGIN
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: event not found';
  END IF;
  -- Only authenticated (always has a uid) and service_role can execute this;
  -- current_user is the owner inside SECURITY DEFINER, so the caller is told
  -- apart by auth.uid(): a user must be org owner/manager, no uid = service.
  IF auth.uid() IS NOT NULL
     AND NOT (exos_is_admin() OR exos_has_org_role(v_ev.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_channel NOT IN ('stubhub','seatgeek','vivid','tickpick','evo','automatiq') THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: unknown channel %', p_channel;
  END IF;
  IF p_qty IS NULL OR p_qty < 0 OR p_qty > 10000 THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: quantity must be 0-10000';
  END IF;
  IF v_ev.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: event is cancelled';
  END IF;
  SELECT event_id INTO v_tev FROM public.exos_ticket_tiers WHERE id = p_tier_id;
  IF v_tev IS DISTINCT FROM p_event_id THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: ticket type not found for this event';
  END IF;
  IF public.exos_tier_is_table(p_tier_id) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: table ticket types can''t be sold on a marketplace';
  END IF;

  -- The house cap must not be tighter than the ticket types, or a tier-level
  -- allocation can't protect it (see header).
  SELECT COALESCE(SUM(capacity), 0), bool_or(capacity = 0) INTO v_sum, v_uncap
    FROM public.exos_ticket_tiers WHERE event_id = p_event_id;
  IF p_qty > 0 AND v_ev.total_tickets > 0 AND (v_uncap OR v_ev.total_tickets < v_sum) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: the event''s overall capacity (%) is lower than its ticket types add up to; give every ticket type a capacity and make the overall cap at least their sum (% ) before selling on a marketplace',
      v_ev.total_tickets, v_sum USING ERRCODE = '23514';
  END IF;

  -- Locks: the listing row, then quotas, then the tier (as exos_create_hold,
  -- and as a marketplace fulfil), so this can't race a checkout.
  SELECT * INTO d FROM public.exos_distribution_listings
   WHERE event_id = p_event_id AND channel = p_channel FOR UPDATE;
  IF d.id IS NOT NULL AND d.tier_id IS NOT NULL AND d.tier_id <> p_tier_id
     AND (d.external_listing_id IS NOT NULL OR coalesce(d.requested_qty, 0) > 0) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: this % listing sells another ticket type; set its allocation to 0 first', p_channel;
  END IF;
  FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id ORDER BY quota_id LOOP
    PERFORM 1 FROM public.exos_quotas WHERE id = q.quota_id FOR UPDATE;
  END LOOP;
  -- WRITE the tier row, not just lock it: a concurrent mint that already
  -- evaluated its availability check and is waiting on this row only
  -- re-checks (READ COMMITTED EvalPlanQual) if the row actually changed.
  -- A bare FOR UPDATE let it proceed on its stale answer and sell an
  -- allocated seat. sort_order carries no triggers.
  UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = p_tier_id;

  IF d.id IS NOT NULL AND d.tier_id = p_tier_id AND d.status IN ('pending','planned','listing','listed','delisting') THEN
    v_cur := greatest(coalesce(d.requested_qty, 0), 0);
  END IF;
  IF p_qty > v_cur THEN
    v_avail := public.exos_effective_available(p_tier_id);   -- already excludes v_cur
    IF v_avail IS NOT NULL AND v_avail < p_qty - v_cur THEN
      RAISE EXCEPTION 'exos_set_channel_allocation: only % more seat(s) free on this ticket type', v_avail
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF d.id IS NULL THEN
    INSERT INTO public.exos_distribution_listings (event_id, org_id, channel, status, tier_id, requested_qty)
    VALUES (p_event_id, v_ev.org_id, p_channel, 'pending', p_tier_id, p_qty);
  ELSE
    UPDATE public.exos_distribution_listings
       SET tier_id = p_tier_id,
           requested_qty = p_qty,
           -- A failed / delisted row holds nothing; allocating again revives it.
           status = CASE WHEN status IN ('failed','delisted') AND p_qty > 0 THEN 'pending' ELSE status END,
           updated_at = now()
     WHERE id = d.id;
  END IF;
  RETURN p_qty;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_channel_allocation(uuid, text, uuid, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_channel_allocation(uuid, text, uuid, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Marketplace fulfil consumes the allocation (replaces 20260926192000's).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_fulfil_marketplace_order(p_order_id uuid, p_app_base text DEFAULT NULL)
RETURNS TABLE (status text, transfer_ids uuid[], reason text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o         public.exos_marketplace_orders%ROWTYPE;
  v_ev      public.exos_events%ROWTYPE;
  v_owner   uuid;
  v_tier    text;
  v_tier_ev uuid;
  v_price   numeric := 0;
  v_ref     text;
  v_ids     uuid[] := '{}';
  v_trs     uuid[] := '{}';
  v_id      uuid;
  v_tr      uuid;
  v_n       int;
  v_why     text;
  v_label   text;
  v_safe    text;
  v_base    text;
  v_links   text := '';
  v_alloc   int := 0;
  v_taken   int := 0;
  d         public.exos_distribution_listings%ROWTYPE;
  i         int;
BEGIN
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE id = p_order_id FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'exos_fulfil_marketplace_order: order not found';
  END IF;
  IF o.status <> 'received' THEN
    status := o.status; transfer_ids := o.transfer_ids; reason := o.attention_reason;
    RETURN NEXT; RETURN;
  END IF;

  SELECT * INTO v_ev FROM public.exos_events WHERE id = o.event_id;
  SELECT owner_uid INTO v_owner FROM public.exos_orgs WHERE id = o.org_id;
  IF o.tier_id IS NOT NULL THEN
    SELECT name, event_id INTO v_tier, v_tier_ev FROM public.exos_ticket_tiers WHERE id = o.tier_id;
  END IF;

  v_why := CASE
    WHEN o.sale_status = 'cancelled' THEN NULL
    WHEN o.sale_status NOT IN ('pending','confirmed') THEN 'marketplace status is ' || o.sale_status || ': check the sale'
    WHEN v_ev.status IS DISTINCT FROM 'published' THEN 'event is ' || coalesce(v_ev.status, 'missing')
    WHEN o.tier_id IS NULL OR v_tier_ev IS DISTINCT FROM o.event_id THEN 'the listing has no ticket type: set one, then retry'
    WHEN public.exos_tier_is_table(o.tier_id) THEN 'table ticket types can''t be sold on a marketplace: issue it by hand'
    WHEN o.buyer_email IS NULL THEN 'no buyer email from the marketplace: deliver by hand'
    WHEN v_owner IS NULL THEN 'the organization has no owner to hold the tickets'
  END;
  IF o.sale_status = 'cancelled' THEN
    UPDATE public.exos_marketplace_orders SET status = 'cancelled', updated_at = now() WHERE id = o.id;
    status := 'cancelled'; transfer_ids := '{}'; reason := NULL;
    RETURN NEXT; RETURN;
  END IF;

  IF v_why IS NULL THEN
    -- The seats were set aside for this channel when they were allocated
    -- (exos_set_channel_allocation). Take this sale out of that allocation
    -- first, in this transaction, so the claim below finds them free. Locks
    -- the listing, then (in exos_seats_available / the tier UPDATE) quotas
    -- and tier: the same order as exos_set_channel_allocation.
    SELECT * INTO d FROM public.exos_distribution_listings
     WHERE id = o.distribution_listing_id FOR UPDATE;
    IF d.id IS NOT NULL AND d.tier_id = o.tier_id
       AND d.status IN ('pending','planned','listing','listed','delisting') THEN
      v_alloc := greatest(coalesce(d.requested_qty, 0), 0);
    END IF;
    IF v_alloc > 0 AND v_alloc < o.quantity THEN
      v_why := 'the marketplace sold ' || o.quantity || ' but only ' || v_alloc ||
               ' were allocated to it: check the listing quantity';
    ELSIF v_alloc > 0 THEN
      UPDATE public.exos_distribution_listings
         SET requested_qty = requested_qty - o.quantity, updated_at = now()
       WHERE id = d.id;
      v_taken := o.quantity;
    END IF;
  END IF;

  IF v_why IS NULL THEN
    -- House cap first (trigger-free counter, safe to undo), then the tier with
    -- quotas / holds / offers / other allocations, as every other mint.
    UPDATE public.exos_events
       SET tickets_sold = tickets_sold + o.quantity
     WHERE id = o.event_id
       AND (total_tickets = 0 OR tickets_sold + o.quantity <= total_tickets);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
      v_why := 'oversold: the event is at capacity';
    ELSE
      UPDATE public.exos_ticket_tiers
         SET sold = sold + o.quantity
       WHERE id = o.tier_id
         AND (capacity = 0 OR sold + o.quantity <= capacity)
         AND public.exos_seats_available(o.tier_id, o.quantity);
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n = 0 THEN
        UPDATE public.exos_events SET tickets_sold = greatest(tickets_sold - o.quantity, 0) WHERE id = o.event_id;
        v_why := 'oversold: ' || coalesce(v_tier, 'the ticket type') || ' has no seats left';
      END IF;
    END IF;
  END IF;

  IF v_why IS NOT NULL THEN
    IF v_taken > 0 THEN
      -- Nothing was minted: the seats go back to the allocation.
      UPDATE public.exos_distribution_listings
         SET requested_qty = requested_qty + v_taken, updated_at = now()
       WHERE id = d.id;
    END IF;
    UPDATE public.exos_marketplace_orders
       SET status = 'needs_attention', attention_reason = v_why, updated_at = now()
     WHERE id = o.id;
    status := 'needs_attention'; transfer_ids := '{}'; reason := v_why;
    RETURN NEXT; RETURN;
  END IF;

  IF o.proceeds IS NOT NULL THEN
    v_price := round(o.proceeds / o.quantity, 2);
  END IF;
  v_ref := o.channel || ':' || o.external_order_id;
  FOR i IN 1..o.quantity LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source
    ) VALUES (
      o.event_id, o.org_id, o.tier_id, v_tier, v_owner, v_owner, o.buyer_email,
      'active', gen_random_uuid()::text, v_price, v_ref, o.channel
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);

    INSERT INTO public.exos_transfers
    SELECT * FROM jsonb_populate_record(NULL::public.exos_transfers, jsonb_build_object(
      'id', gen_random_uuid(), 'ticket_id', v_id, 'org_id', o.org_id,
      'sender_id', v_owner, 'receiver_email', o.buyer_email,
      'status', 'pending', 'event_id', o.event_id, 'event_title', v_ev.name,
      'event_image', v_ev.image_url, 'tier_name', v_tier, 'organizer_id', v_ev.created_by,
      -- jsonb_populate_record yields NULL (not DEFAULT) for absent keys.
      'created_at', now(), 'updated_at', now()))
    RETURNING id INTO v_tr;
    v_trs := array_append(v_trs, v_tr);
    UPDATE public.exos_tickets SET pending_transfer_id = v_tr, last_reissue_at = now() WHERE id = v_id;
  END LOOP;

  -- Issue them to the buyer as a transfer they're told about, not only as the
  -- links the marketplace passes on. Server-built body; names are escaped.
  v_label := CASE o.channel WHEN 'stubhub' THEN 'StubHub' ELSE initcap(o.channel) END;
  v_safe := replace(replace(replace(coalesce(v_ev.name, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  IF p_app_base ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' THEN
    v_base := rtrim(p_app_base, '/');
    FOR i IN 1..cardinality(v_trs) LOOP
      v_links := v_links || '<li><a href="' || v_base || '/claim/' || v_trs[i] || '">Claim ticket ' || i || '</a></li>';
    END LOOP;
    v_links := '<ul>' || v_links || '</ul>';
  END IF;
  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES ('transfer-initiated', o.buyer_email,
          left('Your ' || v_label || ' ticket' || CASE WHEN o.quantity > 1 THEN 's' ELSE '' END || ' for ' || v_safe, 200),
          '<p>Your ' || v_label || ' order ' ||
          replace(replace(replace(o.external_order_id, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') ||
          ' is ' || o.quantity || ' ticket' || CASE WHEN o.quantity > 1 THEN 's' ELSE '' END ||
          ' for <strong>' || v_safe || '</strong>. ' ||
          CASE WHEN o.quantity > 1 THEN 'They have' ELSE 'It has' END ||
          ' been transferred to you on Exos. Sign in with ' || o.buyer_email || ' to claim ' ||
          CASE WHEN o.quantity > 1 THEN 'them' ELSE 'it' END ||
          ' and get your entry QR code.</p>' || v_links,
          v_owner, 'pending');

  UPDATE public.exos_marketplace_orders
     SET status = 'fulfilled', ticket_ids = v_ids, transfer_ids = v_trs, attention_reason = NULL, updated_at = now()
   WHERE id = o.id;
  status := 'fulfilled'; transfer_ids := v_trs; reason := NULL;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public.exos_fulfil_marketplace_order(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_fulfil_marketplace_order(uuid, text) TO service_role;

