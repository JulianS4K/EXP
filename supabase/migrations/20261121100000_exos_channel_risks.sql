-- ============================================================================
-- Migration 20261121100000 — Exos: channel risks before Eventbrite / Luma
-- writes are switched on
-- ============================================================================
-- Touches:  C: FUNCTION _exos_channel_outstanding, _exos_channel_share_cap,
--              exos_channel_create_begin (service role)
--           W: exos_eventbrite_ticket_links (+ exos_created)
--           P: exos_eventbrite_inventory_apply, exos_luma_inventory_apply
--              (one lock per event, one promise across platforms),
--              exos_channel_claim (share_cap per tier, created per Eventbrite
--              mapping), exos_channel_mark (a link to another external event
--              is a conflict, never kept silently; first capacities and
--              created classes recorded; the pending create cleared),
--              exos_channel_set (refuses an event already linked elsewhere)
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
--    primary hold stays the primary platform's, on top. With one platform the
--    cap equals the share it already computed (no change).
-- 2. A link to another external event. exos_channel_mark inserted the door /
--    inventory links with ON CONFLICT DO NOTHING, so an event already linked
--    to Eventbrite event A (or to pretix / another Luma event) kept that link
--    while Exos created and synced event B. Now mark records a conflict: the
--    new external id is KEPT on the mirror (so it is never created twice),
--    the state is error with the reason, no link or ticket mapping is written,
--    and exos-channel-sync makes no further call for that mirror until the
--    organizer resolves it and saves the channel again. exos_channel_set
--    refuses up front: another external id than the mirror already has, an
--    Eventbrite door link to a different event (link that one instead), a
--    ticket backend that isn't this Luma event.
-- 3. Duplicate creates. exos_channel_create_begin records the create a live
--    pass is about to send (external_meta.pending_create: when, the name and
--    start sent, Luma's slug) and extends the lease; the next pass looks the
--    event up (Eventbrite: the org's events by name, start and creation
--    time; Luma: its own slug, which Luma also refuses to reuse) before it
--    creates again, and a create younger than 2 minutes is not repeated.
--    mark clears it once the mirror has its external id.
-- 4. Adopted Eventbrite classes. exos_eventbrite_ticket_links.exos_created
--    marks the classes Exos created (from mark's tickets[].created); claim
--    sends it with each mapping, and the details pass updates only those
--    (with their price). A class Exos adopted by name is left to the
--    inventory sync's capacity-only write.
--
-- Built from the live bodies: every patch is a counted text replacement on
-- pg_get_functiondef (supabase/README.md rule 4), checked against the body
-- the migration chain builds (tests/exos/run_p0.sh). Re-run safe (each patch
-- is skipped when its marker is present). Prod apply needs operator OK.
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
-- yet sent doesn't lower what it can sell) less what it sold. Only the
-- current external event's rows (Eventbrite: the door link's event; Luma: the
-- mirror's event).
CREATE OR REPLACE FUNCTION public._exos_channel_outstanding(p_event_id uuid)
RETURNS TABLE (provider text, tier_id uuid, outstanding integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT 'eventbrite'::text, k.tier_id,
         greatest(greatest(coalesce(k.eb_capacity, 0), coalesce(k.target_capacity, 0))
                  - coalesce(k.eb_sold, k.counted_sold, 0), 0)::int
    FROM public.exos_eventbrite_ticket_links k
    JOIN public.exos_eventbrite_links lk ON lk.event_id = k.event_id AND lk.eb_event_id = k.eb_event_id
   WHERE k.event_id = p_event_id AND k.active
  UNION ALL
  SELECT 'luma'::text, k.tier_id,
         greatest(greatest(coalesce(k.luma_capacity, 0), coalesce(k.target_capacity, 0))
                  - coalesce(k.luma_sold, k.counted_sold, 0), 0)::int
    FROM public.exos_luma_ticket_links k
    JOIN public.exos_channel_mirrors m ON m.event_id = k.event_id AND m.provider = 'luma' AND m.external_id = k.luma_event_id
   WHERE k.event_id = p_event_id AND k.active
$$;
REVOKE ALL ON FUNCTION public._exos_channel_outstanding(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_channel_outstanding(uuid) TO service_role;

-- The most `p_provider` may be offered for one ticket type, given what the
-- other platform holds: p_share is the share the apply worked out for its own
-- platform, p_used what it already gave its earlier classes of the event
-- (house). Returns least(p_share, cap):
--   tier:  shared = free on Exos (exos_effective_available) less one pack;
--          cap = least(ceil(shared / n) + hold if primary,
--                      shared + hold - what the others can still sell of it)
--          n = 1 + (the other platform sells this ticket type)
--   house: H = total_tickets - tickets_sold, its primary hold set apart;
--          cap = least(ceil((H - holds) / n) + holds if primary,
--                      H - what the others can still sell) - p_used
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
    v_cap := least(v_cap, greatest(least(ceil((v_h - v_hold_all)::numeric / v_n_house)::int
                                         + CASE WHEN v_mine THEN v_hold_all ELSE 0 END,
                                         v_h - v_o_house) - coalesce(p_used, 0), 0));
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
  v_conflict text;   -- mig 20261121100000$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  'is a conflict (mig 20261121100000)',
  $o$  -- Where the door and inventory syncs read the platform.
  IF v_state = 'synced' AND m.external_id IS NOT NULL THEN$o$,
  $n$  -- A link to another external event is a conflict (mig 20261121100000): the
  -- old link is never kept silently next to a new external event. The new id
  -- stays on the mirror (so it is never created twice); no link or mapping is
  -- written and the pass is an error until the organizer resolves it.
  IF v_state = 'synced' AND m.external_id IS NOT NULL THEN
    IF p_provider = 'eventbrite' THEN
      SELECT 'this event is already linked to Eventbrite event ' || l.eb_event_id INTO v_conflict
        FROM public.exos_eventbrite_links l WHERE l.event_id = p_event_id AND l.eb_event_id <> m.external_id;
    ELSE
      SELECT CASE WHEN b.provider = 'luma' THEN 'this event''s door list already comes from Luma event ' || b.external_ref
                  ELSE 'this event''s door list already comes from ' || b.provider END INTO v_conflict
        FROM public.exos_backend_links b
       WHERE b.event_id = p_event_id AND (b.provider <> 'luma' OR b.external_ref <> m.external_id);
    END IF;
    IF v_conflict IS NOT NULL THEN
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
                          - CASE WHEN m.external_id IS NOT NULL THEN 'pending_create' ELSE '' END)
                         || CASE WHEN v_conflict IS NOT NULL THEN jsonb_build_object('conflict', left(v_conflict, 200)) ELSE '{}'::jsonb END,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  '''conflict'', v_conflict',
  $o$  RETURN jsonb_build_object('ok', true, 'state', v_state, 'tickets_mapped', v_maps);$o$,
  $n$  RETURN jsonb_build_object('ok', true, 'state', v_state, 'tickets_mapped', v_maps, 'conflict', v_conflict);$n$, 1);

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
  'one external event per platform (mig 20261121100000)',
  $o$  INSERT INTO public.exos_channel_mirrors AS m (event_id, provider, org_id, mode, external_id, created_by)$o$,
  $n$  -- One external event per platform (mig 20261121100000): refuse rather than
  -- keep an old link next to a new external event.
  SELECT * INTO v_cur FROM public.exos_channel_mirrors WHERE event_id = p_event_id AND provider = p_provider;
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
-- or while an earlier create is younger than 2 minutes (in-flight: the next
-- pass looks it up instead). Keeps the first time and Luma's slug across
-- tries, extends the lease. Returns {ok, pending}.
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
    'tries', coalesce(CASE WHEN (v_prev ->> 'tries') ~ '^[0-9]{1,4}$' THEN (v_prev ->> 'tries')::int END, 0) + 1));
  UPDATE public.exos_channel_mirrors
     SET external_meta = external_meta || jsonb_build_object('pending_create', v_next),
         lease_until = greatest(lease_until, now() + interval '2 minutes')
   WHERE event_id = p_event_id AND provider = p_provider;
  RETURN jsonb_build_object('ok', true, 'pending', v_next);
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_create_begin(uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_create_begin(uuid, text, uuid, jsonb) TO service_role;

-- ROLLBACK (manual): restore exos_eventbrite_inventory_apply, exos_luma_inventory_apply,
-- exos_channel_claim, exos_channel_mark and exos_channel_set from their bodies before
-- this migration (pg_get_functiondef on a copy without it); drop
-- exos_channel_create_begin, _exos_channel_share_cap, _exos_channel_outstanding and
-- exos_eventbrite_ticket_links.exos_created.
