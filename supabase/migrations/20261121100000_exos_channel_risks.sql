-- ============================================================================
-- Migration 20261121100000 — Exos: channel risks before Eventbrite / Luma
-- writes are switched on
-- ============================================================================
-- Touches:  C: FUNCTION _exos_channel_outstanding, _exos_channel_share_cap,
--              exos_channel_create_begin, exos_channel_external_taken,
--              exos_channel_lease_renew, exos_channel_link_verified (service role)
--           W: exos_channel_mirrors (+ external_verified_at), exos_eventbrite_links
--              (+ verified_at), exos_backend_links (+ verified_at)
--           W: exos_eventbrite_ticket_links (+ exos_created)
--           P: exos_eventbrite_inventory_apply, exos_luma_inventory_apply
--              (one lock per event, one promise across platforms),
--              exos_channel_claim (share_cap per tier, created per Eventbrite
--              mapping), exos_channel_mark (a link to another external event
--              is a conflict, never kept silently; first capacities and
--              created classes recorded; the pending create cleared),
--              exos_channel_set (refuses an event already linked elsewhere,
--              a taken id, link mode over a pending create; one lock per
--              event), exos_eventbrite_link / _unlink, exos_backend_link /
--              _unlink (refused under a mirror), exos_channel_remove (not while
--              a create may be in flight)
-- Pre-reqs: 20261014110000, 20261019090000, 20261029100000, 20261029160000
--
-- Every write to Eventbrite and Luma is still a dry run unless the org's
-- switch AND EXOS_EVENTBRITE_WRITES / EXOS_LUMA_WRITES=on are set; this
-- migration adds no write path, it only narrows what a live pass may do.
--
-- 1. One promise across platforms. Each inventory apply worked out what its
--    platform may sell from the Exos free count without looking at the other
--    platform, so an event mirrored on Eventbrite AND Luma offered the same
--    free seats twice. Both applies now take one advisory lock per event
--    first (before their mapping rows: nothing that holds those rows waits
--    on it), and cap each class's share with _exos_channel_share_cap: what
--    every OTHER platform can still sell of that ticket type and of the house
--    (its real capacity, or the target if higher, less what it sold:
--    _exos_channel_outstanding) comes off, and the shared pool (free less one
--    pack) is split evenly between the platforms that sell the ticket type,
--    so the first one to sync can't keep the second at 0 for good. The
--    primary hold stays the primary platform's, on top. One pack comes off
--    the house's contested part too, so the platforms together never pass
--    house - pack (+ the hold). With one platform the cap equals the share
--    it already computed. A platform counts while its door link OR its
--    mirror names the external event, so removing the channel (the event
--    stays on sale there) doesn't zero it. The first capacity claim offers
--    (share_cap) is read outside the lock with nothing used yet: the next
--    apply, under the lock, corrects it (and Eventbrite's floor is 1).
-- 2. A link to another external event. exos_channel_mark inserted the door /
--    inventory links with ON CONFLICT DO NOTHING, so an event already linked
--    to Eventbrite event A (or to pretix / another Luma event) kept that link
--    while Exos created and synced event B. Now mark records a conflict: the
--    new external id is KEPT on the mirror (so it is never created twice),
--    the state is error with the reason, no link or ticket mapping is written,
--    and exos-channel-sync makes no further call for that mirror until the
--    organizer resolves it and saves the channel again. An external id that
--    belongs to another Exos event (exos_channel_external_taken: in this org
--    any, in another org only a VERIFIED one, so linking someone's public
--    event id squats nothing) is a conflict too, but NOT kept, and the pending create is cleared (same
--    org, this used to fail 23505 on exos_channel_mirrors_external_uq on
--    every pass). Caught earlier as well: exos_channel_set refuses another
--    external id than the mirror has, a taken id, an Eventbrite door link to
--    a different event, a ticket backend that isn't this Luma event, link
--    mode while a create is pending, under one lock per event;
--    exos_channel_create_begin refuses (and records) a door link found
--    before anything is created; the door links can't be re-pointed or
--    unlinked under a mirror (exos_eventbrite_link / _unlink,
--    exos_backend_link / _unlink).
-- 3. Duplicate creates. exos_channel_create_begin records the create a live
--    pass is about to send (external_meta.pending_create: when, the name and
--    start sent, Luma's slug) and extends the lease; the next pass looks the
--    event up (Eventbrite: the org's events by name, start and creation
--    time; Luma: its own slug, which Luma also refuses to reuse) before it
--    creates again, and a create younger than 2 minutes is not repeated.
--    Eventbrite's lookup only takes an event created between the first try
--    (less 5 minutes) and the last try plus 2 minutes, never one another
--    Exos event uses. The venue is made only after the create is begun and
--    is kept with it, so a retry reuses it. mark clears it once the mirror
--    has its external id. Each live write renews the lease
--    (exos_channel_lease_renew), so a long pass isn't taken over.
-- 4. Adopted Eventbrite classes. exos_eventbrite_ticket_links.exos_created
--    marks the classes Exos created (from mark's tickets[].created); claim
--    sends it with each mapping, and the details pass updates only those
--    (with their price). A class Exos adopted by name is left to the
--    inventory sync's capacity-only write. Existing rows start false (no
--    backfill): fail-safe, since no mirror has synced live yet, and on an
--    event Exos created the pass treats every class as Exos's anyway.
--
-- Verified: a mirror's id once a live pass with the org's credentials
-- recorded it (mark); a door / ticket backend link once a read with the org's
-- credentials proved the event is the org's (exos_channel_link_verified,
-- from exos-eventbrite-sync and exos-integrations) or mark wrote it. Another
-- org's verified id is refused in the same words as an event not on the
-- account (by the pass, the door link, the backend link), never at
-- exos_channel_set, so nothing tells an org about another org's events. Locks:
-- the event (exos_channel_set:), the mirror row, then the id
-- (exos_channel_ext:); mark takes the mirror row, then the id.
-- exos_channel_remove also waits for a pass that holds the lease. A
-- verification belongs to its id: a re-link in place clears it (trigger
-- _exos_tg_channel_verified_reset on the three tables); pretix / hi.events
-- refs (read from an address the org supplies) are never verified.
--
-- Built from the live bodies: every patch is a counted text replacement on
-- pg_get_functiondef (supabase/README.md rule 4), checked against the body
-- the migration chain builds (tests/exos/run_p0.sh). Re-run safe: each
-- patch's marker is text its own replacement writes, so a second run skips it;
-- tests/exos/reapply_check.sh (in run_p0) applies the file again and checks
-- every patch says "already patched" and no function body changes. Prod
-- apply needs operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
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
-- 4 (column first: claim and mark read it). Classes Exos created on Eventbrite.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_eventbrite_ticket_links ADD COLUMN IF NOT EXISTS exos_created boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.exos_eventbrite_ticket_links.exos_created IS
  'Exos created this ticket class (exos-channel-sync): only these get name / price updates. mig 20261121100000.';

-- ---------------------------------------------------------------------------
-- 1. One promise across platforms.
-- ---------------------------------------------------------------------------
-- What each external platform can still sell of the event, per mapped ticket
-- type: its capacity there (or the target Exos set, if higher: a target not
-- yet sent doesn't lower what it can sell) less what it sold. Only the rows
-- of the external event the door link OR the mirror names (removing the
-- mirror keeps counting through the door link; both gone: no longer counted).
CREATE OR REPLACE FUNCTION public._exos_channel_outstanding(p_event_id uuid)
RETURNS TABLE (provider text, tier_id uuid, outstanding integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT 'eventbrite'::text, k.tier_id,
         greatest(greatest(coalesce(k.eb_capacity, 0), coalesce(k.target_capacity, 0))
                  - coalesce(k.eb_sold, k.counted_sold, 0), 0)::int
    FROM public.exos_eventbrite_ticket_links k
   WHERE k.event_id = p_event_id AND k.active
     AND (EXISTS (SELECT 1 FROM public.exos_eventbrite_links lk WHERE lk.event_id = k.event_id AND lk.eb_event_id = k.eb_event_id)
          OR EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
                      WHERE m.event_id = k.event_id AND m.provider = 'eventbrite' AND m.external_id = k.eb_event_id))
  UNION ALL
  SELECT 'luma'::text, k.tier_id,
         greatest(greatest(coalesce(k.luma_capacity, 0), coalesce(k.target_capacity, 0))
                  - coalesce(k.luma_sold, k.counted_sold, 0), 0)::int
    FROM public.exos_luma_ticket_links k
   WHERE k.event_id = p_event_id AND k.active
     AND (EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
                   WHERE m.event_id = k.event_id AND m.provider = 'luma' AND m.external_id = k.luma_event_id)
          OR EXISTS (SELECT 1 FROM public.exos_backend_links b
                      WHERE b.event_id = k.event_id AND b.provider = 'luma' AND b.external_ref = k.luma_event_id))
$$;
REVOKE ALL ON FUNCTION public._exos_channel_outstanding(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_channel_outstanding(uuid) TO service_role;

-- Verified: the org was shown to own the external event. A mirror's id once a
-- live pass with the org's own credentials recorded it (Exos created it, or
-- wrote to it: mark); a door link or ticket backend link once a read with the
-- org's credentials proved it is the org's (Eventbrite: one of the token's
-- organizations; Luma: an event the key's calendar manages) or mark wrote it.
-- Only verified ids of OTHER orgs count as taken, so linking someone else's
-- public event id blocks no one (no squatting) and says nothing about it.
ALTER TABLE public.exos_channel_mirrors ADD COLUMN IF NOT EXISTS external_verified_at timestamptz;
ALTER TABLE public.exos_eventbrite_links ADD COLUMN IF NOT EXISTS verified_at timestamptz;
ALTER TABLE public.exos_backend_links ADD COLUMN IF NOT EXISTS verified_at timestamptz;
-- A mirror synced live has written with the org's credentials; a Luma backend
-- link that synced read the guest list, which needs the calendar's key.
-- (Keyed on the mirror being in step now with a synced hash: synced_at alone
-- may date from before the id changed.)
UPDATE public.exos_channel_mirrors SET external_verified_at = synced_at
 WHERE external_verified_at IS NULL AND external_id IS NOT NULL AND synced_at IS NOT NULL
   AND status = 'synced' AND last_hash IS NOT NULL;

-- A verification belongs to the id it was made for: an update that changes
-- the external id (a re-link: exos_eventbrite_link / exos_backend_link
-- upsert in place) clears it, unless that same update sets it (mark).
CREATE OR REPLACE FUNCTION public._exos_tg_channel_verified_reset()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_TABLE_NAME = 'exos_channel_mirrors' THEN
    IF NEW.external_id IS DISTINCT FROM OLD.external_id AND NEW.external_verified_at IS NOT DISTINCT FROM OLD.external_verified_at THEN
      NEW.external_verified_at := NULL;
    END IF;
  ELSIF TG_TABLE_NAME = 'exos_eventbrite_links' THEN
    IF NEW.eb_event_id IS DISTINCT FROM OLD.eb_event_id AND NEW.verified_at IS NOT DISTINCT FROM OLD.verified_at THEN
      NEW.verified_at := NULL;
    END IF;
  ELSE
    IF (NEW.provider IS DISTINCT FROM OLD.provider OR NEW.external_ref IS DISTINCT FROM OLD.external_ref)
       AND NEW.verified_at IS NOT DISTINCT FROM OLD.verified_at THEN
      NEW.verified_at := NULL;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_channel_verified_reset() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_channel_mirrors_verified_reset ON public.exos_channel_mirrors;
CREATE TRIGGER exos_channel_mirrors_verified_reset BEFORE UPDATE ON public.exos_channel_mirrors
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_channel_verified_reset();
DROP TRIGGER IF EXISTS exos_eventbrite_links_verified_reset ON public.exos_eventbrite_links;
CREATE TRIGGER exos_eventbrite_links_verified_reset BEFORE UPDATE ON public.exos_eventbrite_links
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_channel_verified_reset();
DROP TRIGGER IF EXISTS exos_backend_links_verified_reset ON public.exos_backend_links;
CREATE TRIGGER exos_backend_links_verified_reset BEFORE UPDATE ON public.exos_backend_links
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_channel_verified_reset();
UPDATE public.exos_backend_links SET verified_at = last_ok_at
 WHERE verified_at IS NULL AND provider = 'luma' AND last_ok_at IS NOT NULL;

-- Which of p_ids another Exos event already uses on p_provider: its mirror,
-- or its door link (Eventbrite) / ticket backend link (Luma); in another org
-- only when verified (above). A pass never adopts one, and mark refuses to
-- record one (mig 20261121100000).
CREATE OR REPLACE FUNCTION public.exos_channel_external_taken(p_event_id uuid, p_provider text, p_ids text[])
RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH me AS (SELECT e.org_id FROM public.exos_events e WHERE e.id = p_event_id)
  SELECT coalesce(array_agg(DISTINCT x.id), '{}'::text[])
    FROM unnest(coalesce(p_ids, '{}'::text[])) AS x(id)
   WHERE EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
                  WHERE m.provider = p_provider AND m.external_id = x.id AND m.event_id <> p_event_id
                    AND (m.org_id = (SELECT org_id FROM me) OR m.external_verified_at IS NOT NULL))
      OR (p_provider = 'eventbrite' AND EXISTS (SELECT 1 FROM public.exos_eventbrite_links l
                                                 WHERE l.eb_event_id = x.id AND l.event_id <> p_event_id
                                                   AND (l.org_id = (SELECT org_id FROM me) OR l.verified_at IS NOT NULL)))
      OR (p_provider = 'luma' AND EXISTS (SELECT 1 FROM public.exos_backend_links b
                                           WHERE b.provider = 'luma' AND b.external_ref = x.id AND b.event_id <> p_event_id
                                             AND (b.org_id = (SELECT org_id FROM me) OR b.verified_at IS NOT NULL)))
$$;
REVOKE ALL ON FUNCTION public.exos_channel_external_taken(uuid, text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_external_taken(uuid, text, text[]) TO service_role;

-- The edge functions mark a door link / ticket backend link verified once a
-- read with the org's credentials proved the event is the org's
-- (exos-eventbrite-sync /link: the event is one of the token's Eventbrite
-- organizations'; exos-integrations /link: a Luma event the key's calendar
-- manages). Only Eventbrite and Luma: a pretix / hi.events ref is read from
-- an address the org supplies, which proves nothing. Only the link as it now
-- is: a changed link isn't verified by an older read (and the trigger above
-- clears it on a re-link).
CREATE OR REPLACE FUNCTION public.exos_channel_link_verified(p_event_id uuid, p_provider text, p_ref text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_provider = 'eventbrite' THEN
    UPDATE public.exos_eventbrite_links SET verified_at = coalesce(verified_at, now())
     WHERE event_id = p_event_id AND eb_event_id = p_ref;
  ELSIF p_provider = 'luma' THEN
    UPDATE public.exos_backend_links SET verified_at = coalesce(verified_at, now())
     WHERE event_id = p_event_id AND provider = 'luma' AND external_ref = p_ref;
  ELSE
    RETURN false;
  END IF;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_link_verified(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_link_verified(uuid, text, text) TO service_role;

-- The most `p_provider` may be offered for one ticket type, given what the
-- other platform holds: p_share is the share the apply worked out for its own
-- platform, p_used what it already gave its earlier classes of the event
-- (house). Returns least(p_share, cap):
--   tier:  shared = free on Exos (exos_effective_available) less one pack;
--          cap = least(ceil(shared / n) + hold if primary,
--                      shared + hold - what the others can still sell of it)
--          n = 1 + (the other platform sells this ticket type)
--   house: H = total_tickets - tickets_sold; Hc = H - holds - one pack;
--          cap = least(ceil(Hc / n) + holds if primary,
--                      Hc + holds - what the others can still sell) - p_used
-- The primary hold is _exos_tier_free_raw - exos_effective_available on a
-- ticket type the primary platform (eventbrite / luma) sells.
CREATE OR REPLACE FUNCTION public._exos_channel_share_cap(
  p_event_id uuid, p_tier_id uuid, p_provider text, p_share integer, p_used integer DEFAULT 0
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e          public.exos_events%ROWTYPE;
  v_pack     int;
  v_eff      int;
  v_hold     int := 0;
  v_shared   int;
  v_o_tier   int;
  v_o_house  int;
  v_n_tier   int;
  v_n_house  int;
  v_prim     uuid[];
  v_cap      int;
  v_h        int;
  v_hold_all int := 0;
  v_hc       int;
  v_mine     boolean;
  v_t        uuid;
BEGIN
  IF p_provider IS NULL OR p_provider NOT IN ('eventbrite', 'luma') THEN
    RAISE EXCEPTION '_exos_channel_share_cap: eventbrite or luma' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_share, 0) <= 0 THEN RETURN greatest(coalesce(p_share, 0), 0); END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL THEN RETURN 0; END IF;
  v_mine := e.primary_source = p_provider;
  -- One pack, as the applies count it.
  v_pack := CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$' AND (e.purchase_limits ->> 'maxPerOrder')::int > 0
                 THEN (e.purchase_limits ->> 'maxPerOrder')::int ELSE 8 END;
  IF e.primary_source = 'exos' AND e.distribution_route = 's4k' THEN
    v_pack := greatest(v_pack, e.resale_listing_qty);
  END IF;

  SELECT coalesce(sum(o.outstanding) FILTER (WHERE o.provider <> p_provider AND o.tier_id = p_tier_id), 0),
         coalesce(sum(o.outstanding) FILTER (WHERE o.provider <> p_provider), 0),
         1 + (count(*) FILTER (WHERE o.provider <> p_provider AND o.tier_id = p_tier_id) > 0)::int,
         1 + (count(*) FILTER (WHERE o.provider <> p_provider) > 0)::int,
         array_agg(DISTINCT o.tier_id) FILTER (WHERE o.provider = e.primary_source)
    INTO v_o_tier, v_o_house, v_n_tier, v_n_house, v_prim
    FROM public._exos_channel_outstanding(p_event_id) o;

  v_eff := greatest(coalesce(public.exos_effective_available(p_tier_id), 0), 0);
  IF e.primary_source IN ('eventbrite', 'luma') AND p_tier_id = ANY (coalesce(v_prim, '{}'::uuid[])) THEN
    v_hold := greatest(coalesce(public._exos_tier_free_raw(p_tier_id), 0) - v_eff, 0);
  END IF;
  v_shared := greatest(v_eff - v_pack, 0);
  v_cap := least(ceil(v_shared::numeric / v_n_tier)::int + CASE WHEN v_mine THEN v_hold ELSE 0 END,
                 greatest(v_shared + v_hold - v_o_tier, 0));

  IF coalesce(e.total_tickets, 0) > 0 THEN
    v_h := greatest(e.total_tickets - e.tickets_sold, 0);
    IF e.primary_source IN ('eventbrite', 'luma') THEN
      FOREACH v_t IN ARRAY coalesce(v_prim, '{}'::uuid[]) LOOP
        v_hold_all := v_hold_all + greatest(coalesce(public._exos_tier_free_raw(v_t), 0)
                                            - greatest(coalesce(public.exos_effective_available(v_t), 0), 0), 0);
      END LOOP;
    END IF;
    v_hold_all := least(v_hold_all, v_h);
    -- One pack off the house's contested part too, as at the ticket type
    -- (the hold stays the primary's): together the platforms never pass
    -- H - pack (+ the hold).
    v_hc := greatest(v_h - v_hold_all - v_pack, 0);
    v_cap := least(v_cap, greatest(least(ceil(v_hc::numeric / v_n_house)::int
                                         + CASE WHEN v_mine THEN v_hold_all ELSE 0 END,
                                         v_hc + v_hold_all - v_o_house) - coalesce(p_used, 0), 0));
  END IF;
  RETURN least(p_share, greatest(v_cap, 0));
END $$;
REVOKE ALL ON FUNCTION public._exos_channel_share_cap(uuid, uuid, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_channel_share_cap(uuid, uuid, text, integer, integer) TO service_role;

-- Eventbrite: the event's promise lock, before its mapping rows.
SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'exos_channel_promise:',
  $o$  -- All of the event's mapping rows, in class order (map_ticket takes the same).$o$,
  $n$  -- One promise across platforms (mig 20261121100000): Eventbrite's and Luma's
  -- applies of an event run one at a time; taken before any row lock.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_promise:' || p_event_id::text, 0));
  -- All of the event's mapping rows, in class order (map_ticket takes the same).$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  '_exos_channel_share_cap',
  $o$    v_promised := v_promised + v_share;$o$,
  $n$    -- What Luma can still sell comes off, and the shared pool is split (mig 20261121100000).
    v_share := public._exos_channel_share_cap(p_event_id, t.tier_id, 'eventbrite', v_share, v_promised);
    v_promised := v_promised + v_share;$n$, 1);

-- Luma: the same lock and cap.
SELECT pg_temp.exos_patch_n('public.exos_luma_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'exos_channel_promise:',
  $o$  PERFORM 1 FROM public.exos_luma_ticket_links x
    WHERE x.event_id = p_event_id ORDER BY x.luma_event_id, x.luma_ticket_type_id FOR UPDATE;$o$,
  $n$  -- One promise across platforms (mig 20261121100000), before any row lock.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_promise:' || p_event_id::text, 0));
  PERFORM 1 FROM public.exos_luma_ticket_links x
    WHERE x.event_id = p_event_id ORDER BY x.luma_event_id, x.luma_ticket_type_id FOR UPDATE;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_luma_inventory_apply(uuid, jsonb, timestamp with time zone)',
  '_exos_channel_share_cap',
  $o$    v_promised := v_promised + v_share;$o$,
  $n$    -- What Eventbrite can still sell comes off, and the shared pool is split (mig 20261121100000).
    v_share := public._exos_channel_share_cap(p_event_id, t.tier_id, 'luma', v_share, v_promised);
    v_promised := v_promised + v_share;$n$, 1);

-- The first capacity of a class / ticket type Exos creates follows the same
-- cap (share_cap), and each Eventbrite mapping says whether Exos created it.
SELECT pg_temp.exos_patch_n('public.exos_channel_claim(integer, uuid)',
  'share_cap',
  $o$'free_now', greatest(coalesce(public.exos_effective_available(t.id), 0), 0))$o$,
  $n$'free_now', greatest(coalesce(public.exos_effective_available(t.id), 0), 0),
                       'share_cap', public._exos_channel_share_cap(l.event_id, t.id, l.provider, 2147483647, 0))$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_claim(integer, uuid)',
  '''created'', k.exos_created',
  $o$jsonb_build_object('tier_id', k.tier_id, 'external_ticket_id', k.eb_ticket_class_id)$o$,
  $n$jsonb_build_object('tier_id', k.tier_id, 'external_ticket_id', k.eb_ticket_class_id, 'created', k.exos_created)$n$, 1);

-- ---------------------------------------------------------------------------
-- 2 + 3 + 4. exos_channel_mark.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  'v_conflict text;',
  $o$  v_maps   int := 0;$o$,
  $n$  v_maps   int := 0;
  v_conflict text;   -- mig 20261121100000
  v_taken  boolean := false;
  v_orig   text;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  'is a conflict (mig 20261121100000)',
  $o$  -- Where the door and inventory syncs read the platform.
  IF v_state = 'synced' AND m.external_id IS NOT NULL THEN$o$,
  $n$  -- A link to another external event is a conflict (mig 20261121100000): the
  -- old link is never kept silently next to a new external event. The new id
  -- stays on the mirror (so it is never created twice); no link or mapping is
  -- written and the pass is an error until the organizer resolves it.
  IF v_state = 'synced' AND m.external_id IS NOT NULL THEN
    -- Another Exos event's external event (any org): never adopted. One mark
    -- per external id at a time, so two passes can't both take it.
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_ext:' || p_provider || ':' || m.external_id, 0));
    IF m.external_id = ANY (public.exos_channel_external_taken(p_event_id, p_provider, ARRAY[m.external_id])) THEN
      v_taken := true;
      -- This org's own other event: say so. Another org's: the same words as
      -- an event not on this account (exos-channel-sync notOnAccount).
      v_conflict := CASE
        WHEN EXISTS (SELECT 1 FROM public.exos_channel_mirrors x
                      WHERE x.org_id = m.org_id AND x.provider = p_provider AND x.external_id = m.external_id AND x.event_id <> p_event_id)
          OR (p_provider = 'eventbrite' AND EXISTS (SELECT 1 FROM public.exos_eventbrite_links l
                      WHERE l.org_id = m.org_id AND l.eb_event_id = m.external_id AND l.event_id <> p_event_id))
          OR (p_provider = 'luma' AND EXISTS (SELECT 1 FROM public.exos_backend_links b
                      WHERE b.org_id = m.org_id AND b.provider = 'luma' AND b.external_ref = m.external_id AND b.event_id <> p_event_id))
        THEN initcap(p_provider) || ' event ' || m.external_id || ' already belongs to another Exos event'
        ELSE CASE p_provider WHEN 'eventbrite' THEN 'Eventbrite' ELSE 'Luma' END || ': that event wasn''t found on this account' END;
      SELECT x.external_id INTO v_orig FROM public.exos_channel_mirrors x WHERE x.event_id = p_event_id AND x.provider = p_provider;
      m.external_id := v_orig;   -- not kept: it isn't this event's
      v_state := 'error';
      p_result := p_result || jsonb_build_object('error', CASE WHEN v_conflict LIKE '%wasn''t found on this account' THEN v_conflict
        ELSE left('conflict: ' || v_conflict || '. Link the right event, or remove the channel and add it again.', 300) END);
    ELSIF p_provider = 'eventbrite' THEN
      SELECT 'this event is already linked to Eventbrite event ' || l.eb_event_id INTO v_conflict
        FROM public.exos_eventbrite_links l WHERE l.event_id = p_event_id AND l.eb_event_id <> m.external_id;
    ELSE
      SELECT CASE WHEN b.provider = 'luma' THEN 'this event''s door list already comes from Luma event ' || b.external_ref
                  ELSE 'this event''s door list already comes from ' || b.provider END INTO v_conflict
        FROM public.exos_backend_links b
       WHERE b.event_id = p_event_id AND (b.provider <> 'luma' OR b.external_ref <> m.external_id);
    END IF;
    IF v_conflict IS NOT NULL AND NOT v_taken THEN   -- (a taken id has its own error, above)
      v_state := 'error';
      p_result := p_result || jsonb_build_object('error', left('conflict: ' || v_conflict || '; ' || p_provider || ' event '
        || m.external_id || ' is kept on this mirror. Unlink one of them, then save the channel again.', 300));
    END IF;
  END IF;

  -- Where the door and inventory syncs read the platform.
  IF v_state = 'synced' AND m.external_id IS NOT NULL THEN$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  'exos_created, eb_capacity',
  $o$        INSERT INTO public.exos_eventbrite_ticket_links AS k (event_id, eb_event_id, eb_ticket_class_id, eb_ticket_class_name, tier_id, active)
        VALUES (p_event_id, m.external_id, v_tid, left(t ->> 'name', 200), v_tier, true)
        ON CONFLICT (event_id, eb_event_id, eb_ticket_class_id) DO UPDATE
          SET tier_id = CASE WHEN k.counted_sold > 0 THEN k.tier_id ELSE EXCLUDED.tier_id END, active = true,
              eb_ticket_class_name = coalesce(EXCLUDED.eb_ticket_class_name, k.eb_ticket_class_name);$o$,
  $n$        -- Whether Exos created the class, and the capacity it was created with
        -- (mig 20261121100000: the other platform's apply counts it at once).
        INSERT INTO public.exos_eventbrite_ticket_links AS k (event_id, eb_event_id, eb_ticket_class_id, eb_ticket_class_name, tier_id, active, exos_created, eb_capacity)
        VALUES (p_event_id, m.external_id, v_tid, left(t ->> 'name', 200), v_tier, true, coalesce(t ->> 'created', '') = 'true',
                CASE WHEN (t ->> 'capacity') ~ '^[0-9]{1,9}$' THEN (t ->> 'capacity')::int END)
        ON CONFLICT (event_id, eb_event_id, eb_ticket_class_id) DO UPDATE
          SET tier_id = CASE WHEN k.counted_sold > 0 THEN k.tier_id ELSE EXCLUDED.tier_id END, active = true,
              eb_ticket_class_name = coalesce(EXCLUDED.eb_ticket_class_name, k.eb_ticket_class_name),
              exos_created = k.exos_created OR EXCLUDED.exos_created,
              eb_capacity = coalesce(k.eb_capacity, EXCLUDED.eb_capacity);$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  'luma_capacity = coalesce(k.luma_capacity',
  $o$        INSERT INTO public.exos_luma_ticket_links AS k (event_id, luma_event_id, luma_ticket_type_id, luma_ticket_name, tier_id, active)
        VALUES (p_event_id, m.external_id, v_tid, left(t ->> 'name', 200), v_tier, true)
        ON CONFLICT (event_id, luma_event_id, luma_ticket_type_id) DO UPDATE
          SET tier_id = CASE WHEN k.counted_sold > 0 THEN k.tier_id ELSE EXCLUDED.tier_id END, active = true,
              luma_ticket_name = coalesce(EXCLUDED.luma_ticket_name, k.luma_ticket_name);$o$,
  $n$        INSERT INTO public.exos_luma_ticket_links AS k (event_id, luma_event_id, luma_ticket_type_id, luma_ticket_name, tier_id, active, luma_capacity)
        VALUES (p_event_id, m.external_id, v_tid, left(t ->> 'name', 200), v_tier, true,
                CASE WHEN (t ->> 'capacity') ~ '^[0-9]{1,9}$' THEN (t ->> 'capacity')::int END)
        ON CONFLICT (event_id, luma_event_id, luma_ticket_type_id) DO UPDATE
          SET tier_id = CASE WHEN k.counted_sold > 0 THEN k.tier_id ELSE EXCLUDED.tier_id END, active = true,
              luma_ticket_name = coalesce(EXCLUDED.luma_ticket_name, k.luma_ticket_name),
              luma_capacity = coalesce(k.luma_capacity, EXCLUDED.luma_capacity);$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  '''pending_create''',
  $o$         external_meta = CASE WHEN jsonb_typeof(p_result -> 'external_meta') = 'object' AND length((p_result -> 'external_meta')::text) <= 2000
                              THEN external_meta || (p_result -> 'external_meta') ELSE external_meta END,$o$,
  $n$         -- The pending create is done once the mirror has its id; a conflict
         -- stays until exos_channel_set clears it (mig 20261121100000).
         external_meta = ((CASE WHEN jsonb_typeof(p_result -> 'external_meta') = 'object' AND length((p_result -> 'external_meta')::text) <= 2000
                                THEN external_meta || (p_result -> 'external_meta') ELSE external_meta END)
                          - CASE WHEN m.external_id IS NOT NULL OR v_taken THEN 'pending_create' ELSE '' END)
                         || CASE WHEN v_conflict IS NOT NULL THEN jsonb_build_object('conflict', left(v_conflict, 200)) ELSE '{}'::jsonb END,
         -- A live pass with the org's credentials recorded this id: verified.
         external_verified_at = CASE WHEN m.external_id IS NULL THEN NULL
                                     WHEN external_id IS DISTINCT FROM m.external_id THEN now()
                                     WHEN v_state = 'synced' OR (v_conflict IS NOT NULL AND NOT v_taken) THEN coalesce(external_verified_at, now())
                                     ELSE external_verified_at END,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  '''conflict'', v_conflict',
  $o$  RETURN jsonb_build_object('ok', true, 'state', v_state, 'tickets_mapped', v_maps);$o$,
  $n$  -- The links mark wrote for a live pass are verified too (mig 20261121100000).
  IF v_state = 'synced' AND m.external_id IS NOT NULL THEN
    IF p_provider = 'eventbrite' THEN
      UPDATE public.exos_eventbrite_links SET verified_at = coalesce(verified_at, now())
       WHERE event_id = p_event_id AND eb_event_id = m.external_id;
    ELSE
      UPDATE public.exos_backend_links SET verified_at = coalesce(verified_at, now())
       WHERE event_id = p_event_id AND provider = 'luma' AND external_ref = m.external_id;
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'state', v_state, 'tickets_mapped', v_maps, 'conflict', v_conflict);$n$, 1);

-- ---------------------------------------------------------------------------
-- 2. exos_channel_set refuses an event already linked elsewhere.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_channel_set(uuid, text, text, text)',
  'v_cur  public.exos_channel_mirrors%ROWTYPE;',
  $o$  v_ext  text := nullif(btrim(coalesce(p_external_id, '')), '');$o$,
  $n$  v_ext  text := nullif(btrim(coalesce(p_external_id, '')), '');
  v_cur  public.exos_channel_mirrors%ROWTYPE;   -- mig 20261121100000
  v_want text;
  v_have text;
  v_bprov text;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_set(uuid, text, text, text)',
  'One external event per platform (mig 20261121100000)',
  $o$  INSERT INTO public.exos_channel_mirrors AS m (event_id, provider, org_id, mode, external_id, created_by)$o$,
  $n$  -- One external event per platform (mig 20261121100000): refuse rather than
  -- keep an old link next to a new external event.
  -- One change per event at a time (exos_eventbrite_link / exos_backend_link take it too).
  -- Locks: the event, its mirror row, then the external id (mark: the mirror
  -- row, then the id), so two links of one id are taken one at a time.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_set:' || p_event_id::text, 0));
  SELECT * INTO v_cur FROM public.exos_channel_mirrors WHERE event_id = p_event_id AND provider = p_provider FOR UPDATE;
  IF v_ext IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_ext:' || p_provider || ':' || v_ext, 0));
    -- The org's own check again, now under the lock. Another org's id isn't
    -- checked here: an unverified one blocks no one, and a verified one is
    -- refused by the pass with the same words as an event not on the account.
    IF EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
                WHERE m.org_id = e.org_id AND m.provider = p_provider AND m.external_id = v_ext AND m.event_id <> p_event_id) THEN
      RAISE EXCEPTION 'exos_channel_set: that % event is already linked to another event', p_provider USING ERRCODE = '23505';
    END IF;
  END IF;
  IF v_cur.external_id IS NULL AND v_ext IS NOT NULL AND jsonb_typeof(v_cur.external_meta -> 'pending_create') = 'object' THEN
    RAISE EXCEPTION 'exos_channel_set: Exos is creating this event on % already; wait for it, or remove the channel first', p_provider
      USING ERRCODE = '22023';
  END IF;
  IF v_cur.external_id IS NOT NULL AND v_ext IS NOT NULL AND v_ext <> v_cur.external_id THEN
    RAISE EXCEPTION 'exos_channel_set: this event is already mirrored on % event %; remove it first', p_provider, v_cur.external_id
      USING ERRCODE = '23505';
  END IF;
  v_want := coalesce(v_cur.external_id, v_ext);
  IF p_provider = 'eventbrite' THEN
    SELECT l.eb_event_id INTO v_have FROM public.exos_eventbrite_links l WHERE l.event_id = p_event_id;
    IF v_have IS NOT NULL AND v_have IS DISTINCT FROM v_want THEN
      RAISE EXCEPTION 'exos_channel_set: this event is already linked to Eventbrite event %: link that one, or unlink it first', v_have
        USING ERRCODE = '23505';
    END IF;
  ELSE
    SELECT b.provider, b.external_ref INTO v_bprov, v_have FROM public.exos_backend_links b WHERE b.event_id = p_event_id;
    IF v_bprov IS NOT NULL AND (v_bprov <> 'luma' OR v_have IS DISTINCT FROM v_want) THEN
      RAISE EXCEPTION 'exos_channel_set: this event''s door list already comes from % %: link that one, or unlink it first',
        v_bprov, v_have USING ERRCODE = '23505';
    END IF;
  END IF;

  INSERT INTO public.exos_channel_mirrors AS m (event_id, provider, org_id, mode, external_id, created_by)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_set(uuid, text, text, text)',
  'm.external_meta - ''conflict''',
  $o$         change_seq = m.change_seq + 1, next_try_at = now(), attempts = 0, last_error = NULL;$o$,
  $n$         change_seq = m.change_seq + 1, next_try_at = now(), attempts = 0, last_error = NULL,
         external_meta = m.external_meta - 'conflict';$n$, 1);

-- ---------------------------------------------------------------------------
-- 3. A live create is recorded before it is sent.
-- ---------------------------------------------------------------------------
-- p_marker: {name, start, slug?} as the pass will send them. Refused without
-- the lease (lease-lost), once the mirror has an external id (has-external),
-- while the event's door is linked to an event on that platform or its door
-- list comes from elsewhere (conflict: recorded, so the sync stops; nothing
-- is created that no promise counts), or while an earlier create is younger
-- than 2 minutes (in-flight: the next pass looks it up instead). Keeps the
-- first time, Luma's slug and the venue noted across tries, extends the
-- lease. Returns {ok, pending}.
CREATE OR REPLACE FUNCTION public.exos_channel_create_begin(p_event_id uuid, p_provider text, p_lease uuid, p_marker jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  m       public.exos_channel_mirrors%ROWTYPE;
  v_prev  jsonb;
  v_at    timestamptz;
  v_slug  text;
  v_next  jsonb;
  v_conflict text;
BEGIN
  IF p_marker IS NULL OR jsonb_typeof(p_marker) <> 'object' OR length(p_marker::text) > 600 THEN
    RAISE EXCEPTION 'exos_channel_create_begin: bad marker' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO m FROM public.exos_channel_mirrors WHERE event_id = p_event_id AND provider = p_provider FOR UPDATE;
  IF m.event_id IS NULL OR p_lease IS NULL OR m.lease_id IS DISTINCT FROM p_lease OR m.lease_until < now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  IF m.external_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'has-external');
  END IF;
  v_conflict := CASE p_provider
    WHEN 'eventbrite' THEN (SELECT 'this event is already linked to Eventbrite event ' || l.eb_event_id
                              FROM public.exos_eventbrite_links l WHERE l.event_id = p_event_id)
    ELSE (SELECT 'this event''s door list already comes from ' || CASE WHEN b.provider = 'luma' THEN 'Luma event ' || b.external_ref ELSE b.provider END
            FROM public.exos_backend_links b WHERE b.event_id = p_event_id) END;
  IF v_conflict IS NOT NULL THEN
    UPDATE public.exos_channel_mirrors SET external_meta = external_meta || jsonb_build_object('conflict', left(v_conflict, 200))
     WHERE event_id = p_event_id AND provider = p_provider;
    RETURN jsonb_build_object('ok', false, 'reason', 'conflict', 'conflict', v_conflict);
  END IF;
  v_prev := CASE WHEN jsonb_typeof(m.external_meta -> 'pending_create') = 'object' THEN m.external_meta -> 'pending_create' END;
  v_at := CASE WHEN (v_prev ->> 'at') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (v_prev ->> 'at')::timestamptz END;
  IF v_at IS NOT NULL AND v_at > now() - interval '2 minutes' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in-flight', 'pending', v_prev);
  END IF;
  v_slug := coalesce(CASE WHEN (v_prev ->> 'slug') ~ '^[a-z0-9-]{3,50}$' THEN v_prev ->> 'slug' END,
                     CASE WHEN (p_marker ->> 'slug') ~ '^[a-z0-9-]{3,50}$' THEN p_marker ->> 'slug' END);
  v_next := jsonb_strip_nulls(jsonb_build_object(
    'at', now(),
    'first', coalesce(v_prev ->> 'first', v_prev ->> 'at', to_jsonb(now()) #>> '{}'),
    'name', left(p_marker ->> 'name', 200),
    'start', left(p_marker ->> 'start', 40),
    'slug', v_slug,
    'venue_id', v_prev ->> 'venue_id',
    'venue_key', v_prev ->> 'venue_key',
    'tries', coalesce(CASE WHEN (v_prev ->> 'tries') ~ '^[0-9]{1,4}$' THEN (v_prev ->> 'tries')::int END, 0) + 1));
  UPDATE public.exos_channel_mirrors
     SET external_meta = external_meta || jsonb_build_object('pending_create', v_next),
         lease_until = greatest(lease_until, now() + interval '2 minutes')
   WHERE event_id = p_event_id AND provider = p_provider;
  RETURN jsonb_build_object('ok', true, 'pending', v_next);
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_create_begin(uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_create_begin(uuid, text, uuid, jsonb) TO service_role;

-- Renew the lease before each write of a live pass (exos-channel-sync), so a
-- long pass isn't taken over mid-way; p_note ({venue_id, venue_key}) is kept
-- with a pending create, so a retry reuses the venue it made. false: lease lost.
CREATE OR REPLACE FUNCTION public.exos_channel_lease_renew(p_event_id uuid, p_provider text, p_lease uuid, p_note jsonb DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_note jsonb;
BEGIN
  IF p_note IS NOT NULL THEN
    v_note := jsonb_strip_nulls(jsonb_build_object(
      'venue_id', CASE WHEN (p_note ->> 'venue_id') ~ '^[0-9]{1,24}$' THEN p_note ->> 'venue_id' END,
      'venue_key', left(p_note ->> 'venue_key', 300)));
  END IF;
  UPDATE public.exos_channel_mirrors
     SET lease_until = greatest(lease_until, now() + interval '2 minutes'),
         external_meta = CASE WHEN v_note IS NOT NULL AND v_note <> '{}'::jsonb AND jsonb_typeof(external_meta -> 'pending_create') = 'object'
                              THEN jsonb_set(external_meta, '{pending_create}', (external_meta -> 'pending_create') || v_note)
                              ELSE external_meta END
   WHERE event_id = p_event_id AND provider = p_provider AND p_lease IS NOT NULL AND lease_id = p_lease AND lease_until >= now();
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_lease_renew(uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_lease_renew(uuid, text, uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. The door links can't be moved under a mirror.
-- ---------------------------------------------------------------------------
-- exos_eventbrite_link / _unlink and exos_backend_link / _unlink take the
-- event's channel lock and refuse while a mirror on that platform names
-- another external event (or is still creating one); unlinking refuses while
-- the mirror exists (its classes are on sale: remove the channel first).
-- exos_channel_remove refuses while a create may be in flight; after it, the
-- door link keeps that platform in the promise (_exos_channel_outstanding).
SELECT pg_temp.exos_patch_n('public.exos_eventbrite_link(uuid, uuid, text, text)',
  'exos_channel_set:',
  $o$  IF NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_accounts WHERE org_id = e.org_id) THEN
    RAISE EXCEPTION 'exos_eventbrite_link: connect Eventbrite first' USING ERRCODE = '22023';
  END IF;$o$,
  $n$  IF NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_accounts WHERE org_id = e.org_id) THEN
    RAISE EXCEPTION 'exos_eventbrite_link: connect Eventbrite first' USING ERRCODE = '22023';
  END IF;
  -- Not under a mirror on another Eventbrite event, nor one another Exos
  -- event's mirror uses (mig 20261121100000).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_set:' || p_event_id::text, 0));
  IF EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
              WHERE m.event_id = p_event_id AND m.provider = 'eventbrite' AND m.external_id IS DISTINCT FROM p_eb_event_id) THEN
    RAISE EXCEPTION 'exos_eventbrite_link: this event is sold on Eventbrite through Also sell on (event %): link that one, or remove it there first',
      coalesce((SELECT m.external_id FROM public.exos_channel_mirrors m WHERE m.event_id = p_event_id AND m.provider = 'eventbrite'), 'being created')
      USING ERRCODE = '23505';
  END IF;
  -- Another org's VERIFIED event: refused in the words of an event not on the
  -- account (exos-eventbrite-sync's 404), so it says nothing about other orgs.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_ext:eventbrite:' || p_eb_event_id, 0));
  -- (This org's own door link of it is refused just below, as before.)
  IF p_eb_event_id = ANY (public.exos_channel_external_taken(p_event_id, 'eventbrite', ARRAY[p_eb_event_id]))
     AND NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_links l
                      WHERE l.org_id = e.org_id AND l.eb_event_id = p_eb_event_id AND l.event_id <> p_event_id) THEN
    RAISE EXCEPTION 'exos_eventbrite_link: Eventbrite has no such event for this account.' USING ERRCODE = '22023';
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_unlink(uuid, uuid)',
  'remove it there first (mig 20261121100000)',
  $o$  DELETE FROM public.exos_eventbrite_links WHERE event_id = p_event_id;$o$,
  $n$  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_set:' || p_event_id::text, 0));
  IF EXISTS (SELECT 1 FROM public.exos_channel_mirrors m WHERE m.event_id = p_event_id AND m.provider = 'eventbrite') THEN
    RAISE EXCEPTION 'exos_eventbrite_unlink: this event is sold on Eventbrite through Also sell on: remove it there first (mig 20261121100000)'
      USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.exos_eventbrite_links WHERE event_id = p_event_id;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_backend_link(uuid, text, text, text)',
  'exos_channel_set:',
  $o$  INSERT INTO public.exos_backend_links AS l (event_id, org_id, provider, external_ref, external_name, list_id, linked_by, linked_at)$o$,
  $n$  -- Not under a Luma mirror on another event (mig 20261121100000).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_set:' || p_event_id::text, 0));
  IF EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
              WHERE m.event_id = p_event_id AND m.provider = 'luma'
                AND (p_provider <> 'luma' OR m.external_id IS DISTINCT FROM v_ref)) THEN
    RAISE EXCEPTION 'exos_backend_link: this event is sold on Luma through Also sell on (event %): link that one, or remove it there first',
      coalesce((SELECT m.external_id FROM public.exos_channel_mirrors m WHERE m.event_id = p_event_id AND m.provider = 'luma'), 'being created')
      USING ERRCODE = '23505';
  END IF;
  -- Another org's VERIFIED Luma event: refused in the words of an event Luma
  -- doesn't have (exos-integrations' checkRef), so nothing leaks.
  IF p_provider = 'luma' THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_ext:luma:' || v_ref, 0));
    IF v_ref = ANY (public.exos_channel_external_taken(p_event_id, 'luma', ARRAY[v_ref])) THEN
      RAISE EXCEPTION 'exos_backend_link: Luma has no event with that id.' USING ERRCODE = '22023';
    END IF;
  END IF;
  INSERT INTO public.exos_backend_links AS l (event_id, org_id, provider, external_ref, external_name, list_id, linked_by, linked_at)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_backend_unlink(uuid)',
  'remove it there first (mig 20261121100000)',
  $o$  DELETE FROM public.exos_backend_links WHERE event_id = p_event_id;$o$,
  $n$  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_set:' || p_event_id::text, 0));
  IF EXISTS (SELECT 1 FROM public.exos_channel_mirrors m WHERE m.event_id = p_event_id AND m.provider = 'luma') THEN
    RAISE EXCEPTION 'exos_backend_unlink: this event is sold on Luma through Also sell on: remove it there first (mig 20261121100000)'
      USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.exos_backend_links WHERE event_id = p_event_id;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_remove(uuid, text)',
  'try again in a few minutes (mig 20261121100000)',
  $o$  DELETE FROM public.exos_channel_mirrors WHERE event_id = p_event_id AND provider = p_provider;$o$,
  $n$  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_set:' || p_event_id::text, 0));
  IF EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
              WHERE m.event_id = p_event_id AND m.provider = p_provider AND m.external_id IS NULL
                AND (m.external_meta -> 'pending_create' ->> 'at') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
                AND (m.external_meta -> 'pending_create' ->> 'at')::timestamptz > now() - interval '5 minutes') THEN
    RAISE EXCEPTION 'exos_channel_remove: Exos is still creating this event on %; try again in a few minutes (mig 20261121100000)', p_provider
      USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
              WHERE m.event_id = p_event_id AND m.provider = p_provider AND m.lease_until > now()) THEN
    RAISE EXCEPTION 'exos_channel_remove: a sync of this event on % is running; try again in a few minutes (mig 20261121100000)', p_provider
      USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.exos_channel_mirrors WHERE event_id = p_event_id AND provider = p_provider;$n$, 1);

-- ROLLBACK (manual): restore exos_eventbrite_inventory_apply, exos_luma_inventory_apply,
-- exos_channel_claim, exos_channel_mark and exos_channel_set from their bodies before
-- this migration (pg_get_functiondef on a copy without it); drop
-- exos_channel_create_begin, _exos_channel_share_cap, _exos_channel_outstanding and
-- exos_eventbrite_ticket_links.exos_created.
