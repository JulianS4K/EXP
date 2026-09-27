-- ============================================================================
-- Migration 20260927050000 — Exos (Bridge / D4): one Exos listing standard
--                            across StubHub, SeatGeek and Gametime
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_marketplace_orders (+listing_ref)
--              FUNCTION exos_record_marketplace_order (patched in place: stores
--                listing_ref)
--              FUNCTION exos_claim_internal_seat (replaced: every marketplace,
--                the shared plan shape)
-- Pre-reqs: 20260927030000 (marketplace sync), 20260927040000 (Gametime)
--
-- The three marketplaces now get the same Exos listings
-- (_shared/marketplace/exosListing.ts): blocks of at most the event's max per
-- order, each a run of the allocation's internal seats, each with a stable
-- "ex<base32 allocation id><n>" listing id. StubHub used to get one listing
-- per allocation keyed by the allocation id; now it gets the same blocks as
-- SeatGeek and Gametime. Stored plans share one shape:
--   { channel, listings: [{ listing_id, seat_from, seat_thru, quantity,
--                           request: { endpoint, method, path, body } }], ... }
--
-- 1. A sale records which listing it came from (listing_ref: the Exos
--    listing id as the marketplace reported it), the same way for every
--    marketplace, instead of each one's own raw field.
-- 2. exos_claim_internal_seat gives a sold ticket a seat from that listing's
--    block on any marketplace (it was SeatGeek / Gametime only, and read
--    each one's raw shape). Rows from before listing_ref still work: the id
--    is read from the raw sale as before.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_marketplace_orders
  ADD COLUMN IF NOT EXISTS listing_ref text;
COMMENT ON COLUMN public.exos_marketplace_orders.listing_ref IS
  'The marketplace listing the sale came from (the Exos listing id "ex…"): which block of internal seats.';

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

SELECT pg_temp.exos_patch('public.exos_record_marketplace_order(jsonb)',
  'distribution_listing_id, listing_ref,',
  'channel, external_order_id, external_event_id, external_listing_id, distribution_listing_id,',
  'channel, external_order_id, external_event_id, external_listing_id, distribution_listing_id, listing_ref,');
SELECT pg_temp.exos_patch('public.exos_record_marketplace_order(jsonb)',
  'p_sale ->> ''listing_ref''',
  'v_channel, v_order, p_sale ->> ''external_event_id'', v_listing, d.id,',
  'v_channel, v_order, p_sale ->> ''external_event_id'', v_listing, d.id, nullif(btrim(coalesce(p_sale ->> ''listing_ref'', '''')), ''''),');
SELECT pg_temp.exos_patch('public.exos_record_marketplace_order(jsonb)',
  'listing_ref = coalesce(EXCLUDED.listing_ref, m.listing_ref)',
  'raw         = coalesce(EXCLUDED.raw, m.raw),',
  'raw         = coalesce(EXCLUDED.raw, m.raw),
        listing_ref = coalesce(EXCLUDED.listing_ref, m.listing_ref),');

-- The seat for one ticket of a marketplace sale; takes it off the allocation
-- (whose row the caller has locked). Prefers the block of the listing the
-- sale came from (listed_snapshot, else the plan), then any seat left, then
-- a new number. Always the HIGHEST such seat: a listing sells from the top,
-- so its seat_from, and the blocks the next plan cuts, stay where they were.
CREATE OR REPLACE FUNCTION public.exos_claim_internal_seat(p_order_id uuid, p_listing_id uuid, p_tier_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_raw    jsonb;
  v_ref    text;
  v_plan   jsonb;
  v_l      jsonb;
  v_seats  int4multirange;
  v_pick   int4multirange;
  v_from   text;
  v_thru   text;
BEGIN
  IF p_tier_id IS NULL THEN RETURN NULL; END IF;
  SELECT raw, listing_ref INTO v_raw, v_ref FROM public.exos_marketplace_orders WHERE id = p_order_id;
  -- Sales recorded before listing_ref: each marketplace's raw field.
  v_ref := coalesce(v_ref, v_raw #>> '{listing,id}', v_raw ->> 'item_id', v_raw ->> 'listing_reference_id',
                    v_raw ->> 'source_id', v_raw ->> 'external_listing_id');
  SELECT internal_seats, coalesce(listed_snapshot, planned_listing) INTO v_seats, v_plan
    FROM public.exos_distribution_listings WHERE id = p_listing_id AND tier_id = p_tier_id;
  v_seats := coalesce(v_seats, '{}');

  IF v_ref IS NOT NULL AND jsonb_typeof(v_plan -> 'listings') = 'array' THEN
    SELECT l INTO v_l FROM jsonb_array_elements(v_plan -> 'listings') l
     WHERE coalesce(l ->> 'listing_id', l #>> '{body,seller_listing_id}') = v_ref
     LIMIT 1;
    v_from := coalesce(v_l ->> 'seat_from', v_l #>> '{body,seat_from}');
    v_thru := coalesce(v_l ->> 'seat_thru', v_l #>> '{body,seat_thru}');
    IF v_from ~ '^[0-9]{1,9}$' AND v_thru ~ '^[0-9]{1,9}$' AND v_thru::int >= v_from::int THEN
      v_pick := public.exos_seats_take(v_seats * int4multirange(int4range(v_from::int, v_thru::int, '[]')), 1, true);
    END IF;
  END IF;
  IF v_pick IS NULL OR isempty(v_pick) THEN
    v_pick := public.exos_seats_take(v_seats, 1, true);
  END IF;
  IF isempty(v_pick) THEN
    v_pick := public.exos_new_internal_seats(p_tier_id, 1);
  ELSE
    UPDATE public.exos_distribution_listings
       SET internal_seats = internal_seats - v_pick
     WHERE id = p_listing_id;
  END IF;
  RETURN lower(v_pick);
END $$;
REVOKE ALL ON FUNCTION public.exos_claim_internal_seat(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
