-- ============================================================================
-- Migration 20260928080000 — Exos (Bridge / D4): Ticket Evolution listings
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_tevo_remote_ids, FUNCTION exos_tevo_remote_ids
--           W: FUNCTION exos_sync_marketplace_distribution, exos_link_channel_event
--                (patched in place: 'evo' joins the marketplace lists)
-- Pre-reqs: 20260928070000 (Ticket Evolution orders)
--
-- Ticket Evolution joins StubHub, SeatGeek, Gametime, GoTickets and Vivid
-- Seats in the same sync (_shared/marketplace/tevo/listingPlan.ts): a
-- Marketplaces grid column with a small pool, publish / pull back, the same
-- Exos listings (blocks, internal seats, "ex…" ids), sold through the order
-- path of mig 20260928070000.
--
-- TEvo inventory needs a remote_id: a positive integer, unique per office,
-- that TEvo keeps for the ticket group. Exos listing ids are strings, so
-- each Exos listing gets a number here, once, never reused, from a range
-- that starts at 1,900,000,001 (clear of anything a broker POS numbers from
-- 1; the office may carry Terminal-2 broker inventory). A sale's ticket
-- group comes back with it, and exos-marketplace-sales maps it to the Exos
-- listing through this table. Service role only.
--
-- Publishing with Ticket Evolution ticked now queues its event row like the
-- others, pulling back releases its allocations, and a staff link decision
-- re-queues it (the TEvo event id goes on the listings). exos-distribute no
-- longer hands 'evo' rows to Automatiq.
-- Nothing is sent to Ticket Evolution (dry-run; Hard Rule #2).
--
-- Re-run safe (IF NOT EXISTS; each patch asserts one match and is skipped
-- once applied). D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_tevo_remote_ids (
  remote_id     bigint GENERATED ALWAYS AS IDENTITY (START WITH 1900000001 MINVALUE 1900000001 MAXVALUE 2147483647)
                PRIMARY KEY,
  listing_id    text NOT NULL UNIQUE CHECK (listing_id ~ '^ex[a-z2-7]{26}[1-9][0-9]{0,3}$'),
  allocation_id uuid NOT NULL REFERENCES public.exos_distribution_listings(id) ON DELETE CASCADE,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_tevo_remote_ids_allocation_idx ON public.exos_tevo_remote_ids (allocation_id);
ALTER TABLE public.exos_tevo_remote_ids ENABLE ROW LEVEL SECURITY;
-- No policies: the service role (exos-distribute, exos-marketplace-sales) only.
REVOKE ALL ON public.exos_tevo_remote_ids FROM PUBLIC, anon, authenticated;

-- The remote_id of each of an allocation's TEvo listings, numbering new ones.
CREATE OR REPLACE FUNCTION public.exos_tevo_remote_ids(p_allocation_id uuid, p_listing_ids text[])
RETURNS TABLE (listing_id text, remote_id bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_other uuid;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_tevo_remote_ids: service role only' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings d
                  WHERE d.id = p_allocation_id AND d.channel = 'evo' AND d.tier_id IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_tevo_remote_ids: not a Ticket Evolution allocation' USING ERRCODE = '22023';
  END IF;
  -- A listing id belongs to one allocation, for good.
  SELECT t.allocation_id INTO v_other FROM public.exos_tevo_remote_ids t
   WHERE t.listing_id = ANY (p_listing_ids) AND t.allocation_id <> p_allocation_id LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'exos_tevo_remote_ids: a listing id belongs to another allocation' USING ERRCODE = '23505';
  END IF;
  -- Only new ones: an insert that hits the conflict still uses up a number,
  -- and this runs for every listing on every exos-distribute run.
  INSERT INTO public.exos_tevo_remote_ids (listing_id, allocation_id)
  SELECT DISTINCT l, p_allocation_id FROM unnest(p_listing_ids) AS l
   WHERE NOT EXISTS (SELECT 1 FROM public.exos_tevo_remote_ids t WHERE t.listing_id = l)
   ORDER BY 1
  ON CONFLICT ON CONSTRAINT exos_tevo_remote_ids_listing_id_key DO NOTHING;
  RETURN QUERY SELECT t.listing_id, t.remote_id FROM public.exos_tevo_remote_ids t
   WHERE t.allocation_id = p_allocation_id AND t.listing_id = ANY (p_listing_ids)
   ORDER BY t.remote_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_tevo_remote_ids(uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_tevo_remote_ids(uuid, text[]) TO service_role;

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

-- A staff link decision re-queues the TEvo event row too (its event id).
SELECT pg_temp.exos_patch('public.exos_link_channel_event(uuid, text, text)',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'',''evo'') THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'') THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'',''evo'') THEN');

SELECT pg_temp.exos_patch('public.exos_sync_marketplace_distribution()',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'',''evo'']',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'']',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'',''evo'']');
