-- ============================================================================
-- Last call: near sell-out, only the event's primary checkout sells
-- (distribution layer spec §5, operator 2026-10-29)
-- ============================================================================
-- Touches:  W: exos_events (+ last_call_threshold), exos_orgs (+ last_call_threshold)
--           C: FUNCTION exos_last_call_default, exos_event_last_call_threshold,
--              exos_event_remaining, exos_event_last_call, exos_last_call_closes,
--              _exos_primary_url (service role); exos_last_call_status,
--              exos_set_last_call_threshold, exos_set_org_last_call_threshold
--              (authenticated, role-checked)
--           C: VIEW exos_public_event_sales + FUNCTION exos_public_event_sale
--              (anon: published events only, where to buy and nothing else)
--           R: FUNCTION _exos_primary_hold (+ last call: Exos closes when it
--              isn't the primary)
--           W: FUNCTION exos_channel_pool_plan, _exos_channel_split_plan,
--              _exos_feed_eligible, exos_eventbrite_inventory_apply,
--              exos_luma_inventory_apply (patched in place)
-- Pre-reqs: 20261029090000 (settings helpers), 20261019090000 (mirrors,
--           primary_source incl. luma), 20261014150000 (primary hold),
--           20261014130000 (S4K pools), 20261014090000 (auto split)
--
-- Once an event's remaining inventory is at or below its threshold, every
-- channel but the event's PRIMARY (exos_events.primary_source: exos |
-- eventbrite | luma) stops selling, so the last tickets sell on one checkout
-- and nothing oversells:
--
--   remaining  = unsold seats, wherever they sit (Exos, cart holds, marketplace
--                and S4K pools): the overall cap less tickets sold, never more
--                than the capped ticket types have left (unless a type is
--                uncapped); a table counts its party size. NULL (no limit) for
--                an event with an uncapped type and no overall cap, or no ticket
--                types: never last call. Pools releasing seats doesn't change
--                it, so the state can't flap.
--   threshold  = exos_events.last_call_threshold, else the org's, else the
--                operator setting 'last_call_threshold' (default 10). 0 = off.
--   last call  = not cancelled AND threshold > 0 AND remaining <= threshold.
--
-- While it is on (exos_event_last_call, one predicate for every planner):
--   * marketplace pools and the S4K pool plan to 0 ('last_call'), the auto
--     split plans nothing and the S4K feed / listings / rebalance leave the
--     event out, as when resale is locked;
--   * Eventbrite's and Luma's capacity targets plan to sold out (target =
--     their sold count) unless that platform is the primary; they keep
--     counting their sales and refunds;
--   * Exos itself: when the primary isn't Exos, the primary hold
--     (_exos_primary_hold) takes every free seat, so Exos checkout, free
--     claims, comps and box office sell nothing and the primary platform's
--     capacity gets them all (exos_public_event_sales tells the storefront
--     where to send buyers); when the primary is Exos, Exos keeps selling.
--   * the buffer (one pack held back for sync lag) is unchanged: it still
--     applies to the shared part of a platform's capacity, which is empty
--     once the primary holds everything.
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
-- 1. The threshold.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS last_call_threshold integer;
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS last_call_threshold integer;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_last_call_threshold_check') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_last_call_threshold_check
      CHECK (last_call_threshold IS NULL OR last_call_threshold BETWEEN 0 AND 10000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_orgs_last_call_threshold_check') THEN
    ALTER TABLE public.exos_orgs ADD CONSTRAINT exos_orgs_last_call_threshold_check
      CHECK (last_call_threshold IS NULL OR last_call_threshold BETWEEN 0 AND 10000);
  END IF;
END $$;
COMMENT ON COLUMN public.exos_events.last_call_threshold IS
  'Last call at this many tickets remaining (NULL: the org''s, else the platform''s 10; 0 = off). mig 20261029100000.';
COMMENT ON COLUMN public.exos_orgs.last_call_threshold IS
  'The org''s default last-call threshold (NULL: the platform''s 10; 0 = off). mig 20261029100000.';

CREATE OR REPLACE FUNCTION public.exos_last_call_default()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_setting_int('last_call_threshold', 10, 0, 10000)
$$;
REVOKE ALL ON FUNCTION public.exos_last_call_default() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_last_call_default() TO service_role;

CREATE OR REPLACE FUNCTION public.exos_event_last_call_threshold(p_event_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(e.last_call_threshold, o.last_call_threshold, public.exos_last_call_default())
    FROM public.exos_events e LEFT JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public.exos_event_last_call_threshold(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_last_call_threshold(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Remaining, and the one predicate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_remaining(p_event_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE
           WHEN coalesce(e.total_tickets, 0) > 0 AND (count(t.id) = 0 OR coalesce(bool_or(t.capacity = 0), false))
             THEN greatest(e.total_tickets - coalesce(e.tickets_sold, 0), 0)
           WHEN coalesce(e.total_tickets, 0) > 0
             THEN least(greatest(e.total_tickets - coalesce(e.tickets_sold, 0), 0),
                        sum(greatest(t.capacity - t.sold, 0)
                            * CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) ELSE 1 END))::int
           WHEN count(t.id) = 0 OR coalesce(bool_or(t.capacity = 0), false) THEN NULL   -- no limit
           ELSE sum(greatest(t.capacity - t.sold, 0)
                    * CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) ELSE 1 END)::int
         END
    FROM public.exos_events e
    LEFT JOIN public.exos_ticket_tiers t ON t.event_id = e.id
   WHERE e.id = p_event_id
   GROUP BY e.id, e.total_tickets, e.tickets_sold
$$;
REVOKE ALL ON FUNCTION public.exos_event_remaining(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_remaining(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_event_last_call(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((
    SELECT e.status IS DISTINCT FROM 'cancelled'
           AND public.exos_event_last_call_threshold(e.id) > 0
           AND public.exos_event_remaining(e.id) <= public.exos_event_last_call_threshold(e.id)
      FROM public.exos_events e WHERE e.id = p_event_id), false)
$$;
REVOKE ALL ON FUNCTION public.exos_event_last_call(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_last_call(uuid) TO service_role;

-- Does last call close this channel ('exos', 'eventbrite', 'luma', a
-- marketplace, 's4k')? Everything but the primary.
CREATE OR REPLACE FUNCTION public.exos_last_call_closes(p_event_id uuid, p_channel text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT e.primary_source IS DISTINCT FROM p_channel AND public.exos_event_last_call(e.id)
                     FROM public.exos_events e WHERE e.id = p_event_id), false)
$$;
REVOKE ALL ON FUNCTION public.exos_last_call_closes(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_last_call_closes(uuid, text) TO service_role;

-- The primary platform's event page, when one is known: the mirror's URL, or
-- Eventbrite's public page from its event id.
CREATE OR REPLACE FUNCTION public._exos_primary_url(p_event_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE e.primary_source
           WHEN 'eventbrite' THEN coalesce(
             (SELECT m.external_url FROM public.exos_channel_mirrors m
               WHERE m.event_id = e.id AND m.provider = 'eventbrite' AND m.external_url ~ '^https://'),
             (SELECT 'https://www.eventbrite.com/e/' || l.eb_event_id FROM public.exos_eventbrite_links l WHERE l.event_id = e.id))
           WHEN 'luma' THEN
             (SELECT m.external_url FROM public.exos_channel_mirrors m
               WHERE m.event_id = e.id AND m.provider = 'luma' AND m.external_url ~ '^https://')
         END
    FROM public.exos_events e WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_primary_url(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_primary_url(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Marketplace and S4K pools plan to 0; the auto split plans nothing; the
--    S4K feed leaves the event out (listings dropped, no rebalance, no orders).
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_channel_pool_plan(uuid)',
  'exos_event_last_call',
  $o$  -- S4K pool (mig 20261014130000): the organizer's split, held whole.$o$,
  $n$  -- Last call (mig 20261029100000): only the primary sells; every pool to 0.
  IF public.exos_event_last_call(d.event_id) THEN
    RETURN QUERY SELECT 0, 'last_call'::text, 0;
    RETURN;
  END IF;
  -- S4K pool (mig 20261014130000): the organizer's split, held whole.$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_channel_split_plan(uuid)',
  'exos_event_last_call',
  $o$  v_pack := CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$'$o$,
  $n$  IF public.exos_event_last_call(p_event_id) THEN          -- last call (mig 20261029100000)
    RETURN;
  END IF;
  v_pack := CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$'$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_feed_eligible(uuid)',
  'exos_event_last_call',
  $o$    AND public.exos_resale_unlocked(p_event_id);   -- 250+ capacity (mig 20261014140000)$o$,
  $n$    AND public.exos_resale_unlocked(p_event_id)   -- the resale rule (migs 20261014140000, 20261029090000)
    AND NOT public.exos_event_last_call(p_event_id);   -- last call (mig 20261029100000)$n$, 1);

-- ---------------------------------------------------------------------------
-- 4. Eventbrite and Luma: sold out unless primary. Their sales and refunds
--    still count (the code above the patched line is untouched).
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'exos_last_call_closes',
  $o$    v_live := e.status = 'published' AND coalesce(e.ends_at, e.starts_at, now() + interval '1 day') > now();$o$,
  $n$    v_live := e.status = 'published' AND coalesce(e.ends_at, e.starts_at, now() + interval '1 day') > now()
              AND NOT public.exos_last_call_closes(e.id, 'eventbrite');   -- last call (mig 20261029100000)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_luma_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'exos_last_call_closes',
  $o$    v_live := e.status = 'published' AND coalesce(e.ends_at, e.starts_at, now() + interval '1 day') > now();$o$,
  $n$    v_live := e.status = 'published' AND coalesce(e.ends_at, e.starts_at, now() + interval '1 day') > now()
              AND NOT public.exos_last_call_closes(e.id, 'luma');   -- last call (mig 20261029100000)$n$, 1);

-- ---------------------------------------------------------------------------
-- 5. Exos closes when it isn't the primary: the primary hold takes every free
--    seat (Exos checkout reads exos_tier_available; the primary platform's
--    capacity adds the hold back, 20261014150000 / 20261019090000). The
--    20261019090000 version, plus the first WHEN after the switch-off.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_primary_hold(p_tier_id uuid, p_free bigint)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN coalesce(current_setting('exos.primary_hold_off', true), '') = '1' THEN 0
    -- Last call (mig 20261029100000) with another primary: none of it is Exos's.
    WHEN EXISTS (SELECT 1 FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
                  WHERE t.id = p_tier_id AND e.primary_source <> 'exos' AND e.status <> 'cancelled'
                    AND public.exos_event_last_call(e.id))
      THEN greatest(coalesce(p_free, 0), 0)::int
    ELSE coalesce((
      SELECT least(e.resale_listing_qty, greatest(coalesce(p_free, 0), 0))::int
        FROM public.exos_ticket_tiers t
        JOIN public.exos_events e ON e.id = t.event_id
       WHERE t.id = p_tier_id AND e.status <> 'cancelled'
         AND ((e.primary_source = 'eventbrite'
               AND EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links k WHERE k.tier_id = t.id AND k.active))
           OR (e.primary_source = 'luma'
               AND EXISTS (SELECT 1 FROM public.exos_luma_ticket_links k WHERE k.tier_id = t.id AND k.active)))), 0)
  END
$$;
REVOKE ALL ON FUNCTION public._exos_primary_hold(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_primary_hold(uuid, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. The storefront: published events only, nothing but where to buy.
--    A view calls its functions as the READER (PostgreSQL checks EXECUTE
--    against the querying role), so the view goes through one definer
--    function the public may call, like exos_tier_exclusive_tax_percent for
--    exos_public_tiers. It answers for published events only and returns no
--    more than the view shows (H3 allowlist, test_rpc_hardening.sql).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_public_event_sale(p_event_id uuid)
RETURNS TABLE (last_call boolean, sells_on text, sells_on_url text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT x.lc,
         CASE WHEN x.lc THEN e.primary_source ELSE 'exos' END,
         CASE WHEN x.lc AND e.primary_source <> 'exos' THEN public._exos_primary_url(e.id) END
    FROM public.exos_events e
    CROSS JOIN LATERAL (SELECT public.exos_event_last_call(e.id) AS lc) x
   WHERE e.id = p_event_id AND e.status = 'published'
$$;
REVOKE ALL ON FUNCTION public.exos_public_event_sale(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_event_sale(uuid) TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.exos_public_event_sales
WITH (security_barrier = true)
AS
SELECT e.id AS event_id, s.last_call, s.sells_on, s.sells_on_url
  FROM public.exos_events e
  CROSS JOIN LATERAL public.exos_public_event_sale(e.id) s
 WHERE e.status = 'published';
REVOKE ALL ON public.exos_public_event_sales FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_event_sales TO anon, authenticated, service_role;
COMMENT ON VIEW public.exos_public_event_sales IS
  'Where a published event sells now: last call moves every sale to its primary checkout (sells_on, with its page when known). mig 20261029100000.';

-- ---------------------------------------------------------------------------
-- 7. Organizer RPCs.
-- ---------------------------------------------------------------------------
-- Owner / manager / finance.
CREATE OR REPLACE FUNCTION public.exos_last_call_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE; v_org int;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_last_call_status: not allowed' USING ERRCODE = '42501';
  END IF;
  SELECT last_call_threshold INTO v_org FROM public.exos_orgs WHERE id = e.org_id;
  RETURN jsonb_build_object(
    'active', public.exos_event_last_call(p_event_id),
    'remaining', public.exos_event_remaining(p_event_id),
    'threshold', public.exos_event_last_call_threshold(p_event_id),
    'threshold_source', CASE WHEN e.last_call_threshold IS NOT NULL THEN 'event'
                             WHEN v_org IS NOT NULL THEN 'org' ELSE 'platform' END,
    'event_threshold', e.last_call_threshold,
    'org_threshold', v_org,
    'platform_threshold', public.exos_last_call_default(),
    'primary_source', e.primary_source,
    'primary_url', public._exos_primary_url(p_event_id),
    'can_manage', public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager']));
END $$;
REVOKE ALL ON FUNCTION public.exos_last_call_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_last_call_status(uuid) TO authenticated, service_role;

-- NULL goes back to the org's (or the platform's) default; 0 turns it off.
CREATE OR REPLACE FUNCTION public.exos_set_last_call_threshold(p_event_id uuid, p_threshold integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_last_call_threshold: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_threshold IS NOT NULL AND (p_threshold < 0 OR p_threshold > 10000) THEN
    RAISE EXCEPTION 'exos_set_last_call_threshold: 0 (off) to 10000 tickets' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_events SET last_call_threshold = p_threshold WHERE id = p_event_id;
  RETURN public.exos_last_call_status(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_last_call_threshold(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_last_call_threshold(uuid, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_set_org_last_call_threshold(p_org_id uuid, p_threshold integer)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_org_id IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_org_last_call_threshold: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_threshold IS NOT NULL AND (p_threshold < 0 OR p_threshold > 10000) THEN
    RAISE EXCEPTION 'exos_set_org_last_call_threshold: 0 (off) to 10000 tickets' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_orgs SET last_call_threshold = p_threshold WHERE id = p_org_id;
  RETURN p_threshold;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_org_last_call_threshold(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_org_last_call_threshold(uuid, integer) TO authenticated, service_role;

-- ROLLBACK (manual): re-create _exos_primary_hold from 20261019090000 and the
-- five patched functions from their earlier sources; DROP VIEW
-- exos_public_event_sales; drop the functions above and the two
-- last_call_threshold columns.
