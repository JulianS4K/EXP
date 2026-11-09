-- ============================================================================
-- Fixed block: Exos sells a block of tickets for a platform it can't sync
-- (distribution layer spec §5 "Fixed block": DICE, Shotgun, RA, a box office)
-- ============================================================================
-- Touches:  W: exos_events (primary_source + 'external'; + primary_platform,
--              primary_platform_url, block_release_at, block_released_at)
--           C: TABLE exos_fixed_block_releases (RLS: owner / manager / finance
--              read; written by the release only)
--           C: FUNCTION exos_event_fixed_block, exos_event_block_release_at,
--              exos_event_block_closed, _exos_fixed_block_release,
--              _exos_queue_fixed_block_mail, exos_release_fixed_blocks (service
--              role: the cron); exos_fixed_block_status, exos_set_fixed_block,
--              exos_release_fixed_block_now (authenticated, role-checked)
--           C: TRIGGER exos_tickets_fixed_block (BEFORE INSERT on exos_tickets),
--              exos_ticket_tiers_fixed_block (a block type is capped),
--              exos_events_fixed_block_new (a copied event starts unreleased)
--           R: FUNCTION _exos_primary_hold, exos_last_call_closes,
--              exos_public_event_sale (CREATE OR REPLACE: 'external' is not a
--              primary that takes Exos's seats; Exos sells its own block)
--           W: FUNCTION exos_channel_pool_plan, _exos_channel_split_plan,
--              _exos_feed_eligible, exos_eventbrite_inventory_apply,
--              exos_luma_inventory_apply, exos_set_resale_options,
--              exos_s4k_listings_sync (patched in place)
--           W: TABLE exos_mail (template allowlist + fixed-block-released)
--           C: cron.schedule exos-fixed-block-release-5min (when pg_cron is
--              present), created INACTIVE
-- Pre-reqs: 20261029100000 (last call), 20261029090000 (free tier, resale
--           opt-in), 20261019090000 (primary_source incl. luma, mirrors),
--           20260929071000 (mail templates)
--
-- The organizer's PRIMARY is a platform Exos can't sync. They lower its public
-- capacity by N and give Exos a block of N (per ticket type). Exos is the
-- source of truth for those N, and sells them on its own channels.
--
--   * The event: primary_source = 'external', primary_platform = the
--     platform's name ("DICE"), primary_platform_url its event page (https,
--     optional).
--   * The block is the ticket type's capacity. Every ticket type of a block
--     event is capped (trigger): capacity 0 ("no limit") can't be a block.
--     Reusing capacity keeps every availability path exact with no change:
--     exos_tier_available / exos_effective_available, cart holds, quotas, the
--     public tier view, marketplace pools, and the free-tier and resale rules
--     (exos_event_max_capacity is the block: a block of 150 or less is the free
--     tier and never resold; over 150 it resells only with the opt-in).
--   * release_at: block_release_at, else 24 hours before doors (or the start).
--     At that time the cron (or the organizer's "release now") closes Exos's
--     sales of the block and records how many tickets of each type go back to
--     the primary (exos_fixed_block_releases), and mails the owner and
--     managers that count. Exos can't write to DICE: the organizer puts them
--     back there.
--   * Closing uses the primary hold, the mechanism every Exos sale path
--     already reads (exos_tier_available): once released, the hold takes every
--     free seat of the event's ticket types, so Exos checkout, free claims,
--     comps and the box office sell nothing. Capacity is NOT lowered to the
--     sold count: that would move the max capacity and so the free tier,
--     the fee on later marketplace / box office settlements, and the resale
--     opt-in (capacity_dropped). A ticket insert trigger refuses every other
--     mint (vouchers that bypass the count, referral rewards); a paid Exos
--     checkout already held, and a marketplace sale that already happened, go
--     through (as at last call). Marketplace and S4K pools plan to 0
--     ('block_released'), the auto split plans nothing, the S4K feed leaves
--     the event out, and Eventbrite / Luma mirrors (if any) plan sold out.
--   * The count: per type, the free seats at release (capacity less sold,
--     cart holds, voucher reservations and marketplace pools still out once
--     they are synced). Seats still in a checkout or a live marketplace
--     listing are "pending": they may still sell. The status RPC shows any
--     that come back later ("put back N more").
--   * Last call (mig 20261029100000): for a block event Exos IS the seller of
--     its block, so 'external' counts as Exos there. Last call reads the
--     block's remaining (capacity is the block), closes the marketplaces and
--     S4K, and keeps Exos selling (the primary hold does not take Exos's
--     seats, the mint trigger lets Exos through, the storefront says exos).
--
-- Cron: exos-fixed-block-release-5min, created inactive (Exos crons are off
-- on prod). The operator turns it on with:
--   SELECT cron.alter_job(jobid, active := true) FROM cron.job
--    WHERE jobname = 'exos-fixed-block-release-5min';
-- Until then "release now" is the only release.
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
-- 1. The event.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events DROP CONSTRAINT IF EXISTS exos_events_primary_source_check;
ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_primary_source_check
  CHECK (primary_source IN ('exos', 'eventbrite', 'luma', 'external'));

ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS primary_platform text;
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS primary_platform_url text;
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS block_release_at timestamptz;
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS block_released_at timestamptz;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_primary_platform_check') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_primary_platform_check
      CHECK ((primary_source = 'external') = (primary_platform IS NOT NULL)
             AND (primary_platform IS NULL OR (char_length(primary_platform) BETWEEN 1 AND 60
                                               AND primary_platform !~ '[[:cntrl:]]')));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_primary_platform_url_check') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_primary_platform_url_check
      CHECK (primary_platform_url IS NULL
             OR (primary_source = 'external' AND primary_platform_url ~ '^https://[^\s/]+\.[^\s]+$'
                 AND length(primary_platform_url) <= 500));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_events.primary_platform IS
  'primary_source = external: the platform the organizer sells on (DICE, Shotgun, RA, a box office). Exos sells a fixed block for it. mig 20261029160000.';
COMMENT ON COLUMN public.exos_events.primary_platform_url IS
  'The primary platform''s event page (https), optional. mig 20261029160000.';
COMMENT ON COLUMN public.exos_events.block_release_at IS
  'When Exos hands the unsold block back (NULL: 24 hours before doors, else the start). mig 20261029160000.';
COMMENT ON COLUMN public.exos_events.block_released_at IS
  'When the block was released: Exos stops selling it (exos_fixed_block_releases has the counts). mig 20261029160000.';

-- A copied event (series, duplicate) starts with its own block: not released,
-- the release time following its own dates.
CREATE OR REPLACE FUNCTION public.exos_tg_event_fixed_block_new()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.block_released_at := NULL;
  NEW.block_release_at := NULL;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_fixed_block_new() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER exos_events_fixed_block_new
  BEFORE INSERT ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_fixed_block_new();

-- ---------------------------------------------------------------------------
-- 2. The release record: one per event.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_fixed_block_releases (
  event_id        uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  released_at     timestamptz NOT NULL DEFAULT now(),
  reason          text NOT NULL CHECK (reason IN ('scheduled', 'manual')),
  released_by     uuid,
  release_at      timestamptz,
  platform        text NOT NULL,
  tiers           jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(tiers) = 'array'),
  total_returned  integer NOT NULL CHECK (total_returned >= 0),
  total_pending   integer NOT NULL CHECK (total_pending >= 0),
  mailed          integer NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS exos_fixed_block_releases_org_idx ON public.exos_fixed_block_releases (org_id, released_at DESC);
ALTER TABLE public.exos_fixed_block_releases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_fixed_block_releases FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.exos_fixed_block_releases TO authenticated;
GRANT ALL ON TABLE public.exos_fixed_block_releases TO service_role;
DROP POLICY IF EXISTS exos_fixed_block_releases_sel ON public.exos_fixed_block_releases;
CREATE POLICY exos_fixed_block_releases_sel ON public.exos_fixed_block_releases FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
COMMENT ON TABLE public.exos_fixed_block_releases IS
  'A fixed block handed back to its primary platform: per ticket type the block, sold, pending and returned counts (tiers). Written by _exos_fixed_block_release only. mig 20261029160000.';

-- ---------------------------------------------------------------------------
-- 3. Helpers (service role).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_fixed_block(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT e.primary_source = 'external' FROM public.exos_events e WHERE e.id = p_event_id), false)
$$;
REVOKE ALL ON FUNCTION public.exos_event_fixed_block(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_fixed_block(uuid) TO service_role;

-- The release time: the organizer's, else 24 hours before doors (or the start).
-- NULL for an event that isn't a block, or has no date and no time set.
CREATE OR REPLACE FUNCTION public.exos_event_block_release_at(p_event_id uuid)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN e.primary_source = 'external'
              THEN coalesce(e.block_release_at, coalesce(e.doors_at, e.starts_at) - interval '24 hours') END
    FROM public.exos_events e WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public.exos_event_block_release_at(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_block_release_at(uuid) TO service_role;

-- Released: Exos sells none of it any more.
CREATE OR REPLACE FUNCTION public.exos_event_block_closed(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT e.primary_source = 'external' AND e.block_released_at IS NOT NULL
                     FROM public.exos_events e WHERE e.id = p_event_id), false)
$$;
REVOKE ALL ON FUNCTION public.exos_event_block_closed(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_block_closed(uuid) TO service_role;

-- A block type is capped: capacity 0 means "no limit", which no block is.
CREATE OR REPLACE FUNCTION public.exos_tg_tier_fixed_block()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(NEW.capacity, 0) = 0 AND public.exos_event_fixed_block(NEW.event_id) THEN
    RAISE EXCEPTION 'this event sells a fixed block for %: give "%" a block size (its capacity can''t be unlimited)',
      (SELECT primary_platform FROM public.exos_events WHERE id = NEW.event_id), NEW.name
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_tier_fixed_block() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER exos_ticket_tiers_fixed_block
  BEFORE INSERT OR UPDATE OF capacity, event_id ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_tier_fixed_block();

-- ---------------------------------------------------------------------------
-- 4. Exos's own block: 'external' is not a primary that takes Exos's seats.
-- ---------------------------------------------------------------------------
-- The 20261029100000 version, plus: a released block holds every free seat
-- (Exos closed); last call with an external primary holds nothing (Exos is
-- the seller of its block).
CREATE OR REPLACE FUNCTION public._exos_primary_hold(p_tier_id uuid, p_free bigint)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN coalesce(current_setting('exos.primary_hold_off', true), '') = '1' THEN 0
    -- A released fixed block (mig 20261029160000): the rest is the primary platform's.
    WHEN EXISTS (SELECT 1 FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
                  WHERE t.id = p_tier_id AND e.primary_source = 'external' AND e.block_released_at IS NOT NULL)
      THEN greatest(coalesce(p_free, 0), 0)::int
    -- Last call (mig 20261029100000) with another primary: none of it is Exos's.
    -- An external primary is Exos's own block (mig 20261029160000): Exos sells it.
    WHEN EXISTS (SELECT 1 FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
                  WHERE t.id = p_tier_id AND e.primary_source NOT IN ('exos', 'external') AND e.status <> 'cancelled'
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

-- Last call closes everything but the primary; for a block event the seller
-- of the block is Exos (mig 20261029160000).
CREATE OR REPLACE FUNCTION public.exos_last_call_closes(p_event_id uuid, p_channel text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN e.primary_source = 'external' THEN 'exos' ELSE e.primary_source END IS DISTINCT FROM p_channel
                          AND public.exos_event_last_call(e.id)
                     FROM public.exos_events e WHERE e.id = p_event_id), false)
$$;
REVOKE ALL ON FUNCTION public.exos_last_call_closes(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_last_call_closes(uuid, text) TO service_role;

-- The storefront: at last call a block event still sells on Exos.
CREATE OR REPLACE FUNCTION public.exos_public_event_sale(p_event_id uuid)
RETURNS TABLE (last_call boolean, sells_on text, sells_on_url text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT x.lc,
         CASE WHEN x.lc AND e.primary_source NOT IN ('exos', 'external') THEN e.primary_source ELSE 'exos' END,
         CASE WHEN x.lc AND e.primary_source NOT IN ('exos', 'external') THEN public._exos_primary_url(e.id) END
    FROM public.exos_events e
    CROSS JOIN LATERAL (SELECT public.exos_event_last_call(e.id) AS lc) x
   WHERE e.id = p_event_id AND e.status = 'published'
$$;
REVOKE ALL ON FUNCTION public.exos_public_event_sale(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_event_sale(uuid) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Released: pools to 0, no auto split, off the S4K feed, mirrors sold out.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_channel_pool_plan(uuid)',
  'exos_event_block_closed',
  $o$  -- Last call (mig 20261029100000): only the primary sells; every pool to 0.$o$,
  $n$  -- A released fixed block (mig 20261029160000): back to the primary; every pool to 0.
  IF public.exos_event_block_closed(d.event_id) THEN
    RETURN QUERY SELECT 0, 'block_released'::text, 0;
    RETURN;
  END IF;
  -- Last call (mig 20261029100000): only the primary sells; every pool to 0.$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_channel_split_plan(uuid)',
  'exos_event_block_closed',
  $o$  IF public.exos_event_last_call(p_event_id) THEN          -- last call (mig 20261029100000)$o$,
  $n$  IF public.exos_event_last_call(p_event_id)               -- last call (mig 20261029100000)
     OR public.exos_event_block_closed(p_event_id) THEN      -- a released fixed block (mig 20261029160000)$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_feed_eligible(uuid)',
  'exos_event_block_closed',
  $o$    AND NOT public.exos_event_last_call(p_event_id);   -- last call (mig 20261029100000)$o$,
  $n$    AND NOT public.exos_event_last_call(p_event_id)   -- last call (mig 20261029100000)
    AND NOT public.exos_event_block_closed(p_event_id);   -- a released fixed block (mig 20261029160000)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'exos_event_block_closed',
  $o$              AND NOT public.exos_last_call_closes(e.id, 'eventbrite');   -- last call (mig 20261029100000)$o$,
  $n$              AND NOT public.exos_last_call_closes(e.id, 'eventbrite')   -- last call (mig 20261029100000)
              AND NOT public.exos_event_block_closed(e.id);   -- a released fixed block (mig 20261029160000)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_luma_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'exos_event_block_closed',
  $o$              AND NOT public.exos_last_call_closes(e.id, 'luma');   -- last call (mig 20261029100000)$o$,
  $n$              AND NOT public.exos_last_call_closes(e.id, 'luma')   -- last call (mig 20261029100000)
              AND NOT public.exos_event_block_closed(e.id);   -- a released fixed block (mig 20261029160000)$n$, 1);

-- The primary of a block event is set by exos_set_fixed_block only.
SELECT pg_temp.exos_patch_n('public.exos_set_resale_options(uuid, integer, text, boolean)',
  'fixed block (mig 20261029160000)',
  $o$    RAISE EXCEPTION 'exos_set_resale_options: the primary source is exos, eventbrite or luma' USING ERRCODE = '22023';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_set_resale_options: the primary source is exos, eventbrite or luma' USING ERRCODE = '22023';
  END IF;
  -- A fixed block (mig 20261029160000): its primary is the other platform until the block is turned off.
  IF e.primary_source = 'external' AND p_primary_source IS NOT NULL THEN
    RAISE EXCEPTION 'exos_set_resale_options: this event sells a fixed block for %; turn that off first', e.primary_platform
      USING ERRCODE = '22023';
  END IF;$n$, 1);

-- S4K reads the QR source: a block's codes are Exos's.
SELECT pg_temp.exos_patch_n('public.exos_s4k_listings_sync(uuid)',
  'fixed block (mig 20261029160000)',
  $o$e.name, e.starts_at, e.doors_at, e.timezone, e.venue_name, e.primary_source, now()$o$,
  $n$e.name, e.starts_at, e.doors_at, e.timezone, e.venue_name,
           CASE WHEN e.primary_source = 'external' THEN 'exos' ELSE e.primary_source END /* fixed block (mig 20261029160000) */, now()$n$, 1);

-- ---------------------------------------------------------------------------
-- 6. No Exos mint once the block is released, whatever the path (the
--    last-call trigger's rule): a paid Exos checkout already held and a
--    marketplace / S4K sale that already happened go through.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_fixed_block()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(NEW.channel_source, '') IN ('stripe', 's4k', 'stubhub', 'seatgeek', 'gametime', 'vivid', 'gotickets',
                                          'tickpick', 'evo', 'automatiq') THEN
    RETURN NEW;
  END IF;
  IF public.exos_event_block_closed(NEW.event_id) THEN
    RAISE EXCEPTION 'the Exos block for this event was released: the rest sells on %',
      (SELECT primary_platform FROM public.exos_events WHERE id = NEW.event_id)
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_ticket_fixed_block() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER exos_tickets_fixed_block
  BEFORE INSERT ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_fixed_block();

-- ---------------------------------------------------------------------------
-- 7. The mail: owner + active managers, once per event and person.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['fixed-block-released'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF strpos(coalesce(v_def, ''), '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live
      FROM regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN
    RETURN;  -- already allowed; leave the live list alone
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION
    SELECT unnest(ARRAY[
      'transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled',
      'event-reminder','order-failed','checkout-abandoned','marketplace-attention',
      'event-published','inventory-low','inventory-sold-out','payout-sent',
      'payout-pending','fee-free-ending','org-welcome','org-first-event',
      'org-connect-stripe','org-sales-digest','org-weekly-summary',
      'refund-issued','post-event','dispute-opened','dispute-won','dispute-lost'] || v_new)
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- Counts and event facts only (no buyer data). Never raises: a mail problem
-- must not undo the release.
CREATE OR REPLACE FUNCTION public._exos_queue_fixed_block_mail(p_event_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  x    public.exos_fixed_block_releases%ROWTYPE;
  v_pay jsonb;
  v_n  int := 0;
  r    record;
BEGIN
  SELECT * INTO x FROM public.exos_fixed_block_releases WHERE event_id = p_event_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  v_pay := jsonb_build_object(
    'event', public._exos_mail_event_json(p_event_id),
    'platform', x.platform,
    'released_at', x.released_at,
    'reason', x.reason,
    'tiers', x.tiers,
    'total_returned', x.total_returned,
    'total_pending', x.total_pending);
  FOR r IN SELECT * FROM public.exos_org_mail_recipients(x.org_id, ARRAY['manager']) LOOP
    IF public.exos_mail_enqueue('fixed-block-released', r.email, v_pay,
         'fixed-block-released:' || p_event_id::text || ':' || r.user_id::text, r.user_id, false, NULL) IS NOT NULL THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '_exos_queue_fixed_block_mail(%): % (mail skipped)', p_event_id, SQLERRM;
  RETURN 0;
END $$;
REVOKE ALL ON FUNCTION public._exos_queue_fixed_block_mail(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_queue_fixed_block_mail(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. The release. Idempotent: an event is released once; later calls return
--    false and change nothing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_fixed_block_release(p_event_id uuid, p_reason text, p_by uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  d        record;
  t        record;
  v_free   int;
  v_pend   int;
  v_tiers  jsonb := '[]'::jsonb;
  v_ret    int := 0;
  v_pall   int := 0;
BEGIN
  IF p_reason IS NULL OR p_reason NOT IN ('scheduled', 'manual') THEN
    RAISE EXCEPTION '_exos_fixed_block_release: reason is scheduled or manual' USING ERRCODE = '22023';
  END IF;
  -- The route / split lock, then pools, then ticket types, then the event
  -- (the order an S4K order, a route change and the opt-in take them).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_route:' || p_event_id::text, 0));
  PERFORM 1 FROM public.exos_distribution_listings
   WHERE event_id = p_event_id AND tier_id IS NOT NULL
   ORDER BY tier_id, channel FOR UPDATE;
  PERFORM 1 FROM public.exos_ticket_tiers WHERE event_id = p_event_id ORDER BY id FOR UPDATE;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF e.id IS NULL OR e.primary_source IS DISTINCT FROM 'external' OR e.block_released_at IS NOT NULL THEN
    RETURN false;
  END IF;

  UPDATE public.exos_events SET block_released_at = now() WHERE id = p_event_id;
  -- Pools hand their seats back now (a live listing once the marketplace confirms).
  FOR d IN SELECT id FROM public.exos_distribution_listings
            WHERE event_id = p_event_id AND tier_id IS NOT NULL AND sell_cap IS NOT NULL
              AND status IN ('pending', 'planned', 'listing', 'listed')
            ORDER BY tier_id, channel LOOP
    PERFORM public.exos_sync_channel_hold(d.id, false);
  END LOOP;
  PERFORM public.exos_s4k_listings_sync(p_event_id);

  -- The count: what Exos had free once the pools are back (the primary hold
  -- off, so it is the raw count), and what is still in a checkout or a live
  -- listing.
  PERFORM set_config('exos.primary_hold_off', '1', true);
  FOR t IN SELECT tt.id, tt.name, tt.kind, tt.party_size, tt.capacity, tt.sold
             FROM public.exos_ticket_tiers tt WHERE tt.event_id = p_event_id
            ORDER BY tt.sort_order NULLS LAST, tt.id LOOP
    v_free := greatest(coalesce(public.exos_tier_available(t.id), 0), 0);
    v_pend := greatest(t.capacity - t.sold - v_free, 0);
    v_tiers := v_tiers || jsonb_build_object(
      'tier_id', t.id, 'name', t.name, 'kind', t.kind,
      'party_size', CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) END,
      'block', t.capacity, 'sold', t.sold, 'pending', v_pend, 'returned', v_free);
    v_ret := v_ret + v_free;
    v_pall := v_pall + v_pend;
  END LOOP;
  PERFORM set_config('exos.primary_hold_off', '', true);

  INSERT INTO public.exos_fixed_block_releases (event_id, org_id, released_at, reason, released_by, release_at, platform,
                                                tiers, total_returned, total_pending)
  VALUES (p_event_id, e.org_id, now(), p_reason, p_by, public.exos_event_block_release_at(p_event_id), e.primary_platform,
          v_tiers, v_ret, v_pall);
  UPDATE public.exos_fixed_block_releases SET mailed = public._exos_queue_fixed_block_mail(p_event_id)
   WHERE event_id = p_event_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_fixed_block_release(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fixed_block_release(uuid, text, uuid) TO service_role;

-- The cron: every block whose release time has passed. One event's error
-- doesn't stop the others. Returns how many were released.
CREATE OR REPLACE FUNCTION public.exos_release_fixed_blocks(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN SELECT e.id FROM public.exos_events e
            WHERE e.primary_source = 'external' AND e.block_released_at IS NULL AND e.status <> 'cancelled'
              AND public.exos_event_block_release_at(e.id) <= now()
            ORDER BY public.exos_event_block_release_at(e.id), e.id
            LIMIT greatest(coalesce(p_limit, 100), 1) LOOP
    BEGIN
      IF public._exos_fixed_block_release(r.id, 'scheduled', NULL) THEN
        v_n := v_n + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'exos_release_fixed_blocks: event %: %', r.id, SQLERRM;
    END;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_release_fixed_blocks(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_release_fixed_blocks(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Organizer RPCs.
-- ---------------------------------------------------------------------------
-- What the editor and the dashboard show. Owner / manager / finance.
--   tiers[]: block (the capacity), sold, left (block - sold) and, once
--   released, returned (at release), unsold_now (free now, the hold off) and
--   more_to_return (unsold_now - returned: seats that were pending and came
--   back since; the organizer puts these back too).
-- (Not STABLE: it reads the raw free count with the primary hold off.)
CREATE OR REPLACE FUNCTION public.exos_fixed_block_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  x        public.exos_fixed_block_releases%ROWTYPE;
  t        record;
  v_tiers  jsonb := '[]'::jsonb;
  v_free   int;
  v_ret    int;
  v_block  int := 0;
  v_sold   int := 0;
  v_more   int := 0;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_fixed_block_status: not allowed' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO x FROM public.exos_fixed_block_releases WHERE event_id = p_event_id;
  PERFORM set_config('exos.primary_hold_off', '1', true);
  FOR t IN SELECT tt.id, tt.name, tt.kind, tt.party_size, tt.capacity, tt.sold
             FROM public.exos_ticket_tiers tt WHERE tt.event_id = p_event_id
            ORDER BY tt.sort_order NULLS LAST, tt.id LOOP
    v_ret := NULL; v_free := NULL;
    IF x.event_id IS NOT NULL THEN
      v_free := greatest(coalesce(public.exos_tier_available(t.id), 0), 0);
      SELECT (r ->> 'returned')::int INTO v_ret FROM jsonb_array_elements(x.tiers) r WHERE r ->> 'tier_id' = t.id::text;
      v_more := v_more + greatest(v_free - coalesce(v_ret, 0), 0);
    END IF;
    v_block := v_block + t.capacity;
    v_sold := v_sold + t.sold;
    v_tiers := v_tiers || jsonb_build_object(
      'tier_id', t.id, 'name', t.name, 'kind', t.kind,
      'party_size', CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) END,
      'block', t.capacity, 'sold', t.sold, 'left', greatest(t.capacity - t.sold, 0),
      'returned', v_ret, 'unsold_now', v_free,
      'more_to_return', CASE WHEN x.event_id IS NOT NULL THEN greatest(v_free - coalesce(v_ret, 0), 0) END);
  END LOOP;
  PERFORM set_config('exos.primary_hold_off', '', true);
  RETURN jsonb_build_object(
    'on', e.primary_source = 'external',
    'primary_source', e.primary_source,
    'platform', e.primary_platform,
    'platform_url', e.primary_platform_url,
    'release_at', public.exos_event_block_release_at(p_event_id),
    'release_at_set', e.block_release_at,
    'release_at_default', coalesce(e.doors_at, e.starts_at) - interval '24 hours',
    'released_at', e.block_released_at,
    'release', CASE WHEN x.event_id IS NOT NULL THEN jsonb_build_object(
        'released_at', x.released_at, 'reason', x.reason, 'release_at', x.release_at, 'platform', x.platform,
        'tiers', x.tiers, 'total_returned', x.total_returned, 'total_pending', x.total_pending,
        'mailed', x.mailed) END,
    'tiers', v_tiers,
    'totals', jsonb_build_object('block', v_block, 'sold', v_sold, 'left', greatest(v_block - v_sold, 0),
                                 'more_to_return', CASE WHEN x.event_id IS NOT NULL THEN v_more END),
    'total_tickets', e.total_tickets,
    'cancelled', e.status = 'cancelled',
    'can_manage', public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager']));
END $$;
REVOKE ALL ON FUNCTION public.exos_fixed_block_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_fixed_block_status(uuid) TO authenticated, service_role;

-- Turn the block on / edit it (p_on) or off. Owner / manager of the event's
-- org. p_blocks: {"<ticket type id>": block size, ...} for this event's
-- ticket types (in its own units: tables for a table type); a type left out
-- keeps its capacity, which must be a block (not unlimited). p_release_at:
-- NULL = 24 hours before doors. Off only before the release (the count has
-- gone to the organizer by then).
CREATE OR REPLACE FUNCTION public.exos_set_fixed_block(
  p_event_id uuid, p_on boolean, p_platform text DEFAULT NULL, p_platform_url text DEFAULT NULL,
  p_blocks jsonb DEFAULT NULL, p_release_at timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  v_name   text := btrim(coalesce(p_platform, ''));
  v_url    text := nullif(btrim(coalesce(p_platform_url, '')), '');
  k        text;
  v        jsonb;
  t        public.exos_ticket_tiers%ROWTYPE;
  v_qty    int;
  v_rel    timestamptz;
  v_adm    int;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_fixed_block: not allowed' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_route:' || p_event_id::text, 0));
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;

  IF NOT coalesce(p_on, false) THEN
    IF e.primary_source <> 'external' THEN
      RETURN public.exos_fixed_block_status(p_event_id);
    END IF;
    IF e.block_released_at IS NOT NULL THEN
      RAISE EXCEPTION 'exos_set_fixed_block: the block went back to % on %; it stays off Exos', e.primary_platform,
        to_char(e.block_released_at AT TIME ZONE coalesce(e.timezone, 'UTC'), 'Mon DD HH24:MI') USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_events
       SET primary_source = 'exos', primary_platform = NULL, primary_platform_url = NULL, block_release_at = NULL
     WHERE id = p_event_id;
    RETURN public.exos_fixed_block_status(p_event_id);
  END IF;

  IF e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_set_fixed_block: the event was cancelled' USING ERRCODE = '22023';
  END IF;
  IF e.block_released_at IS NOT NULL THEN
    RAISE EXCEPTION 'exos_set_fixed_block: the block was already released to %', e.primary_platform USING ERRCODE = '22023';
  END IF;
  IF e.primary_source NOT IN ('exos', 'external') THEN
    RAISE EXCEPTION 'exos_set_fixed_block: % is this event''s primary and Exos syncs with it, so it needs no block',
      initcap(e.primary_source) USING ERRCODE = '22023';
  END IF;
  IF char_length(v_name) NOT BETWEEN 1 AND 60 OR v_name ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'exos_set_fixed_block: name the platform (1 to 60 characters)' USING ERRCODE = '22023';
  END IF;
  IF v_url IS NOT NULL AND (v_url !~ '^https://[^\s/]+\.[^\s]+$' OR length(v_url) > 500) THEN
    RAISE EXCEPTION 'exos_set_fixed_block: the platform link must be an https:// address' USING ERRCODE = '22023';
  END IF;
  IF p_blocks IS NOT NULL AND jsonb_typeof(p_blocks) <> 'object' THEN
    RAISE EXCEPTION 'exos_set_fixed_block: blocks are {ticket type id: size}' USING ERRCODE = '22023';
  END IF;

  -- The blocks: only this event's ticket types; at least what each has sold.
  FOR k, v IN SELECT * FROM jsonb_each(coalesce(p_blocks, '{}'::jsonb)) LOOP
    IF k !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'exos_set_fixed_block: unknown ticket type' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO t FROM public.exos_ticket_tiers WHERE id = k::uuid AND event_id = p_event_id FOR UPDATE;
    IF t.id IS NULL THEN
      RAISE EXCEPTION 'exos_set_fixed_block: unknown ticket type' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v) <> 'number' OR (v #>> '{}') !~ '^[0-9]{1,6}$' OR (v #>> '{}')::int NOT BETWEEN 1 AND 100000 THEN
      RAISE EXCEPTION 'exos_set_fixed_block: a block is 1 to 100000 (%)', t.name USING ERRCODE = '22023';
    END IF;
    v_qty := (v #>> '{}')::int;
    IF v_qty < t.sold THEN
      RAISE EXCEPTION 'exos_set_fixed_block: "%" has sold % already; its block can''t be smaller', t.name, t.sold USING ERRCODE = '22023';
    END IF;
    IF v_qty IS DISTINCT FROM t.capacity THEN
      UPDATE public.exos_ticket_tiers SET capacity = v_qty WHERE id = t.id;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE event_id = p_event_id) THEN
    RAISE EXCEPTION 'exos_set_fixed_block: add a ticket type first' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO t FROM public.exos_ticket_tiers WHERE event_id = p_event_id AND capacity = 0 ORDER BY sort_order NULLS LAST, id LIMIT 1;
  IF t.id IS NOT NULL THEN
    RAISE EXCEPTION 'exos_set_fixed_block: give "%" a block size', t.name USING ERRCODE = '22023';
  END IF;
  -- An overall cap below the block would sell less than the block.
  SELECT sum(capacity * CASE WHEN kind = 'table' THEN greatest(coalesce(party_size, 1), 1) ELSE 1 END)::int INTO v_adm
    FROM public.exos_ticket_tiers WHERE event_id = p_event_id;
  IF coalesce(e.total_tickets, 0) > 0 AND e.total_tickets < v_adm THEN
    RAISE EXCEPTION 'exos_set_fixed_block: the event total (%) is below the block (%); raise it or clear it', e.total_tickets, v_adm
      USING ERRCODE = '22023';
  END IF;

  -- The release time: a set one must be ahead; the default must not have passed.
  IF p_release_at IS NOT NULL THEN
    IF p_release_at <= now() THEN
      RAISE EXCEPTION 'exos_set_fixed_block: the release time has passed (use Release now to hand it back today)' USING ERRCODE = '22023';
    END IF;
    v_rel := p_release_at;
  ELSE
    v_rel := coalesce(e.doors_at, e.starts_at) - interval '24 hours';
    IF v_rel IS NULL THEN
      RAISE EXCEPTION 'exos_set_fixed_block: set the event''s date, or pick a release time' USING ERRCODE = '22023';
    END IF;
    IF v_rel <= now() THEN
      RAISE EXCEPTION 'exos_set_fixed_block: 24 hours before doors has passed; pick a release time' USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE public.exos_events
     SET primary_source = 'external', primary_platform = v_name, primary_platform_url = v_url,
         block_release_at = p_release_at
   WHERE id = p_event_id;
  RETURN public.exos_fixed_block_status(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_fixed_block(uuid, boolean, text, text, jsonb, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_fixed_block(uuid, boolean, text, text, jsonb, timestamptz) TO authenticated, service_role;

-- "Release now": hand the unsold block back before the set time. Owner /
-- manager. A second call changes nothing.
CREATE OR REPLACE FUNCTION public.exos_release_fixed_block_now(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_release_fixed_block_now: not allowed' USING ERRCODE = '42501';
  END IF;
  IF e.primary_source <> 'external' THEN
    RAISE EXCEPTION 'exos_release_fixed_block_now: this event doesn''t sell a fixed block' USING ERRCODE = '22023';
  END IF;
  PERFORM public._exos_fixed_block_release(p_event_id, 'manual', auth.uid());
  RETURN public.exos_fixed_block_status(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_release_fixed_block_now(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_release_fixed_block_now(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Cron: every 5 minutes, off the :00 cluster. Created INACTIVE (Exos crons
--     are off on prod); a re-run leaves an existing job, and its on/off
--     state, alone. Guarded so a preview branch / CI Postgres without pg_cron
--     applies.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_job bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-fixed-block-release-5min') THEN
      v_job := cron.schedule('exos-fixed-block-release-5min', '3-58/5 * * * *',
                             $cron$SELECT public.exos_release_fixed_blocks(100);$cron$);
      PERFORM cron.alter_job(v_job, active := false);
    END IF;
  END IF;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos-fixed-block-release-5min');
-- re-create _exos_primary_hold, exos_last_call_closes and
-- exos_public_event_sale from 20261029100000 and the seven patched functions
-- from their earlier sources; DROP TRIGGER exos_tickets_fixed_block,
-- exos_ticket_tiers_fixed_block, exos_events_fixed_block_new; drop
-- exos_fixed_block_releases and the functions above; restore the
-- primary_source CHECK (exos, eventbrite, luma) once no event is 'external';
-- drop the four exos_events columns.
