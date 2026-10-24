-- ============================================================================
-- Channels: Eventbrite + Luma share one count; the auto split gives seats
-- only to marketplaces that list, and counts the mirrors
-- ============================================================================
-- Touches:  C: FUNCTION exos_marketplace_live, _exos_outside_platforms,
--              _exos_outside_out, _exos_outside_share,
--              _exos_channel_split_plan_x (service role, internal)
--           R: CREATE OR REPLACE _exos_channel_split_plan (same signature:
--              the marketplace rows of _exos_channel_split_plan_x)
--           W: exos_eventbrite_ticket_links (+ exos_created, hidden_by_count)
--           P: exos_eventbrite_inventory_apply, exos_luma_inventory_apply
--              (share from _exos_outside_share; the other platform's promise
--              comes off the house first), exos_eventbrite_inventory_ack
--              (hidden_by_count), exos_channel_mark (exos_created)
--           W: exos_platform_settings ('marketplace_live_channels'; no row = none)
-- Pre-reqs: 20261019090000 (channel mirrors) and the chain it patches
--           (20261014090000, 20261014110000, 20261014140000, 20261014150000)
--
-- 1. Oversell at the end of a sale. Eventbrite and Luma were each given what
--    Exos had free less one pack, independently: with 50 left, 42 + 34 seats
--    were on sale outside on top of Exos's own 42. Now the platforms selling a
--    ticket type (an active Eventbrite class link, a Luma ticket type of the
--    mirror) split one figure:
--        room  = free on Exos - n packs        (n = platforms selling it;
--                                               a pack each for the sync's lag)
--        share = least(room / n,  room - what the other platform is promised)
--    so what is on sale outside is at most free - n packs, plus the primary
--    hold (unchanged: the primary platform's alone). "Promised" is the other
--    platform's capacity left: the larger of the target Exos last set and the
--    capacity it last reported (until a lower target is sent, the higher one
--    is what it sells), less what it sold; a class hidden for a 0 count, 0.
--    With n = 1 the share is what it was (free less one pack).
-- 2. The T-48h auto split.
--    * Only marketplaces that really list get seats. Every distributor is
--      dry run today (exos-distribute "DRY-RUN ONLY": nothing is sent without
--      an operator WriteAuthorization, and none is recorded in the database),
--      so SQL can't see one: the operator says which are live in
--      exos_platform_settings 'marketplace_live_channels' (a JSON array of
--      channel names), set when a channel's sending is authorized and turned
--      on. No row = none live: a ticked marketplace that isn't live gets a
--      share of 0 (its pool is given back), and the seats stay on Exos.
--    * Eventbrite and Luma count in the split: each platform selling the
--      ticket type takes a pack of buffer and a share like a marketplace, both
--      left on Exos's count (which they sell from). Marketplaces never grow
--      into seats those platforms are still promised.
--    * A 0 target: for a ticket class Exos created on Eventbrite (a mirror in
--      create mode, or a class its sync added) the inventory sync now hides
--      the class (`hidden: true`, in the channel allowlist) and shows it again
--      with the next capacity of 1 or more. A class Exos didn't create still
--      isn't touched at 0 (the panel says to hide or end it there).
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
-- 1. Which marketplaces list for real (operator setting; none by default).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_marketplace_live(p_channel text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT jsonb_typeof(s.value) = 'array' AND s.value ? p_channel
                     FROM public.exos_platform_settings s WHERE s.key = 'marketplace_live_channels'), false)
$$;
REVOKE ALL ON FUNCTION public.exos_marketplace_live(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_marketplace_live(text) TO service_role;

COMMENT ON TABLE public.exos_platform_settings IS
  'Operator-set platform rules: resale_min_capacity (default 250, mig 20261014140000); marketplace_live_channels (JSON array of the marketplaces whose listings are really sent; default none, mig 20261020110000). Service role only.';

-- ---------------------------------------------------------------------------
-- 2. Eventbrite / Luma: who sells a ticket type, and what each is promised.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_eventbrite_ticket_links
  ADD COLUMN IF NOT EXISTS exos_created boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS hidden_by_count boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.exos_eventbrite_ticket_links.exos_created IS
  'Exos created this class (a mirror in create mode, or added by the channel sync): a 0 count may hide it. mig 20261020110000.';
COMMENT ON COLUMN public.exos_eventbrite_ticket_links.hidden_by_count IS
  'The inventory sync hid this class for a 0 count; the next capacity of 1+ shows it again. mig 20261020110000.';

-- How many outside platforms sell this ticket type now (0-2).
CREATE OR REPLACE FUNCTION public._exos_outside_platforms(p_tier_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links k
                    JOIN public.exos_eventbrite_links lk ON lk.event_id = k.event_id AND lk.eb_event_id = k.eb_event_id
                   WHERE k.tier_id = p_tier_id AND k.active))::int
       + (EXISTS (SELECT 1 FROM public.exos_luma_ticket_links k
                    JOIN public.exos_channel_mirrors m ON m.event_id = k.event_id AND m.provider = 'luma' AND m.external_id = k.luma_event_id
                   WHERE k.tier_id = p_tier_id AND k.active))::int
$$;
REVOKE ALL ON FUNCTION public._exos_outside_platforms(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_outside_platforms(uuid) TO service_role;

-- What a platform still has on sale for the event (one ticket type, or all):
-- the larger of the target Exos set and the capacity it last reported, less
-- what it sold. A class hidden for a 0 count sells nothing.
CREATE OR REPLACE FUNCTION public._exos_outside_out(p_event_id uuid, p_provider text, p_tier_id uuid DEFAULT NULL)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE p_provider
    WHEN 'eventbrite' THEN coalesce((
      SELECT sum(CASE WHEN k.hidden_by_count THEN 0
                      ELSE greatest(greatest(coalesce(k.target_capacity, 0), coalesce(k.eb_capacity, 0)) - k.counted_sold, 0) END)
        FROM public.exos_eventbrite_ticket_links k
        JOIN public.exos_eventbrite_links lk ON lk.event_id = k.event_id AND lk.eb_event_id = k.eb_event_id
       WHERE k.event_id = p_event_id AND k.active AND (p_tier_id IS NULL OR k.tier_id = p_tier_id)), 0)
    WHEN 'luma' THEN coalesce((
      SELECT sum(greatest(greatest(coalesce(k.target_capacity, 0), coalesce(k.luma_capacity, 0)) - k.counted_sold, 0))
        FROM public.exos_luma_ticket_links k
        JOIN public.exos_channel_mirrors m ON m.event_id = k.event_id AND m.provider = 'luma' AND m.external_id = k.luma_event_id
       WHERE k.event_id = p_event_id AND k.active AND (p_tier_id IS NULL OR k.tier_id = p_tier_id)), 0)
    ELSE 0 END::int
$$;
REVOKE ALL ON FUNCTION public._exos_outside_out(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_outside_out(uuid, text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. The auto split, with live marketplaces only and the mirrors counted.
--    _x also returns a row per mirror (channel 'eventbrite' / 'luma': what
--    the split leaves it, on Exos's count); _exos_channel_split_plan keeps
--    its signature and returns the marketplace rows. reserve = what stays on
--    Exos (its reserve, the mirrors' packs and shares, and never less than
--    what the mirrors are still promised, so no marketplace grows into it).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_channel_split_plan_x(p_event_id uuid)
RETURNS TABLE(tier_id uuid, channel text, unsold integer, reserve integer, share integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  e        public.exos_events%ROWTYPE;
  v_pack   int;
  v_taper  boolean;
  v_chs    text[];
  v_live   boolean[];
  t        record;
  v_unsold int;
  v_res    int;
  v_shared int;
  v_n      int;
  v_k      int;      -- live marketplaces
  v_m      int;      -- Eventbrite / Luma selling the ticket type
  v_p      int;      -- everyone sharing
  v_out    int;
  v_mk     int;
  v_s      int;
  v_j      int;
  i        int;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR e.distribution_route = 's4k' THEN   -- S4K lists it
    RETURN;
  END IF;
  IF NOT public.exos_resale_unlocked(p_event_id) THEN       -- under 250 (mig 20261014140000)
    RETURN;
  END IF;
  v_pack := CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$'
                      AND (e.purchase_limits ->> 'maxPerOrder')::int > 0
                 THEN (e.purchase_limits ->> 'maxPerOrder')::int ELSE 8 END;
  v_taper := e.starts_at IS NOT NULL AND e.starts_at <= now() + make_interval(hours => e.channel_taper_hours);
  -- The ticked marketplaces, in a fixed order (the remainder goes first come).
  v_chs := ARRAY(SELECT c FROM unnest(ARRAY['stubhub','seatgeek','gametime','vivid','gotickets','evo']) WITH ORDINALITY u(c, o)
                  WHERE c = ANY (coalesce(e.distribution_networks, '{}'::text[])) ORDER BY o);
  v_n := coalesce(array_length(v_chs, 1), 0);
  IF v_n = 0 THEN
    RETURN;
  END IF;
  v_live := ARRAY(SELECT public.exos_marketplace_live(c) FROM unnest(v_chs) WITH ORDINALITY u(c, o) ORDER BY o);
  v_k := (SELECT count(*) FROM unnest(v_live) x WHERE x);

  FOR t IN
    SELECT tt.id, tt.capacity, coalesce(tt.price, 0) <= 0 AS free_tier FROM public.exos_ticket_tiers tt
     WHERE tt.event_id = p_event_id AND tt.capacity > 0 AND NOT public.exos_tier_is_table(tt.id)
     ORDER BY tt.sort_order NULLS LAST, tt.id
  LOOP
    -- Unsold = free for Exos now + what the marketplaces hold now.
    v_unsold := coalesce(public.exos_effective_available(t.id), 0)
              + coalesce((SELECT sum(greatest(coalesce(d.requested_qty, 0), 0))
                            FROM public.exos_distribution_listings d
                           WHERE d.tier_id = t.id AND d.status IN ('pending','planned','listing','listed')), 0);
    v_res := CASE WHEN t.free_tier THEN v_unsold        -- free tickets stay on Exos
                  WHEN v_k = 0 THEN v_unsold             -- no marketplace lists yet (dry run)
                  WHEN v_taper THEN v_pack
                  ELSE greatest(v_pack, ceil(t.capacity * e.channel_reserve_pct / 100.0)::int) END;
    v_m := CASE WHEN v_k = 0 THEN 0 ELSE public._exos_outside_platforms(t.id) END;
    v_res := least(v_res + v_m * v_pack, v_unsold);     -- + a pack of lag buffer per mirror
    v_shared := greatest(0, v_unsold - v_res);
    v_p := greatest(v_k + v_m, 1);
    -- Marketplace shares (the remainder to the first live ones).
    v_mk := 0; v_j := 0;
    FOR i IN 1 .. v_n LOOP
      IF v_live[i] THEN
        v_j := v_j + 1;
        v_mk := v_mk + v_shared / v_p + CASE WHEN v_j <= v_shared % v_p THEN 1 ELSE 0 END;
      END IF;
    END LOOP;
    v_out := CASE WHEN v_m > 0 THEN public._exos_outside_out(p_event_id, 'eventbrite', t.id)
                                  + public._exos_outside_out(p_event_id, 'luma', t.id) ELSE 0 END;
    v_res := greatest(v_unsold - v_mk, least(v_unsold, v_res + v_out));
    v_j := 0;
    FOR i IN 1 .. v_n LOOP
      v_s := 0;
      IF v_live[i] THEN
        v_j := v_j + 1;
        v_s := v_shared / v_p + CASE WHEN v_j <= v_shared % v_p THEN 1 ELSE 0 END;
      END IF;
      tier_id := t.id;
      channel := v_chs[i];
      unsold  := v_unsold;
      reserve := v_res;
      share   := v_s;
      RETURN NEXT;
    END LOOP;
    -- The mirrors' shares (no remainder: it stays with Exos).
    IF v_m > 0 AND EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links k
                             JOIN public.exos_eventbrite_links lk ON lk.event_id = k.event_id AND lk.eb_event_id = k.eb_event_id
                            WHERE k.tier_id = t.id AND k.active) THEN
      tier_id := t.id; channel := 'eventbrite'; unsold := v_unsold; reserve := v_res; share := v_shared / v_p;
      RETURN NEXT;
    END IF;
    IF v_m > 0 AND EXISTS (SELECT 1 FROM public.exos_luma_ticket_links k
                             JOIN public.exos_channel_mirrors m ON m.event_id = k.event_id AND m.provider = 'luma' AND m.external_id = k.luma_event_id
                            WHERE k.tier_id = t.id AND k.active) THEN
      tier_id := t.id; channel := 'luma'; unsold := v_unsold; reserve := v_res; share := v_shared / v_p;
      RETURN NEXT;
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public._exos_channel_split_plan_x(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_channel_split_plan_x(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_channel_split_plan(p_event_id uuid)
RETURNS TABLE(tier_id uuid, channel text, unsold integer, reserve integer, share integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT x.tier_id, x.channel, x.unsold, x.reserve, x.share
    FROM public._exos_channel_split_plan_x(p_event_id) x
   WHERE x.channel NOT IN ('eventbrite', 'luma')
$$;
REVOKE ALL ON FUNCTION public._exos_channel_split_plan(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_channel_split_plan(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. A platform's share of a ticket type (before the primary hold).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_outside_share(p_tier_id uuid, p_provider text, p_pack integer)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  v_avail  int := greatest(coalesce(public.exos_effective_available(p_tier_id), 0), 0);
  v_hold   int;
  v_n      int := greatest(public._exos_outside_platforms(p_tier_id), 1);
  v_room   int;
  v_fair   int;
  v_other  text := CASE WHEN p_provider = 'eventbrite' THEN 'luma' ELSE 'eventbrite' END;
  v_out    int;
  v_split  int;
BEGIN
  SELECT ev.* INTO e FROM public.exos_events ev JOIN public.exos_ticket_tiers tt ON tt.event_id = ev.id WHERE tt.id = p_tier_id;
  IF e.id IS NULL THEN
    RETURN 0;
  END IF;
  v_hold := greatest(greatest(coalesce(public._exos_tier_free_raw(p_tier_id), 0), 0) - v_avail, 0);
  v_room := greatest(v_avail - v_n * greatest(coalesce(p_pack, 0), 0), 0);
  v_fair := v_room / v_n + CASE WHEN p_provider = 'eventbrite' THEN v_room % v_n ELSE 0 END;
  -- The other platform's promise; the primary hold in it is not on Exos's count.
  v_out := public._exos_outside_out(e.id, v_other, p_tier_id);
  IF e.primary_source = v_other THEN
    v_out := greatest(v_out - v_hold, 0);
  END IF;
  -- On an auto split with live marketplaces, no more than the split leaves it.
  IF e.channel_split_mode = 'auto' THEN
    SELECT min(x.share) INTO v_split FROM public._exos_channel_split_plan_x(e.id) x
     WHERE x.tier_id = p_tier_id AND x.channel = p_provider;
    IF v_split IS NOT NULL THEN
      v_fair := least(v_fair, v_split);
    END IF;
  END IF;
  RETURN greatest(least(v_fair, v_room - v_out), 0);
END $$;
REVOKE ALL ON FUNCTION public._exos_outside_share(uuid, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_outside_share(uuid, text, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Eventbrite's inventory: the shared share; Luma's promise off the house;
--    a 0 count on a class Exos created is planned as hidden, not an error.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  '_exos_outside_share',
  $o$    v_share := CASE WHEN v_live THEN greatest(v_avail - v_pack, 0)
                                     + CASE WHEN e.primary_source = 'eventbrite' THEN v_hold ELSE 0 END ELSE 0 END;$o$,
  $n$    -- One count with Luma (mig 20261020110000): Eventbrite's part of what is free.
    v_share := CASE WHEN v_live THEN least(public._exos_outside_share(t.tier_id, 'eventbrite', v_pack), greatest(v_avail - v_pack, 0))
                                     + CASE WHEN e.primary_source = 'eventbrite' THEN v_hold ELSE 0 END ELSE 0 END;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'Luma''s promise comes off the house',
  $o$  IF lk.event_id IS NULL THEN RETURN; END IF;$o$,
  $n$  IF lk.event_id IS NULL THEN RETURN; END IF;
  v_promised := public._exos_outside_out(p_event_id, 'luma');   -- Luma's promise comes off the house (mig 20261020110000)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'v_target < 1 AND NOT t.exos_created',
  $o$           last_error = CASE WHEN v_target < 1 THEN 'nothing$o$,
  $n$           -- A class Exos created is hidden instead (mig 20261020110000).
           last_error = CASE WHEN v_target < 1 AND NOT t.exos_created THEN 'nothing$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'skip_reason := CASE WHEN v_target < 1 AND NOT t.exos_created',
  $o$    skip_reason := CASE WHEN v_target < 1 THEN 'target 0' END;$o$,
  $n$    skip_reason := CASE WHEN v_target < 1 AND NOT t.exos_created THEN 'target 0' END;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_ack(uuid, text, jsonb, boolean, integer, text)',
  'hidden_by_count',
  $o$         last_error      = left(p_error, 200)$o$,
  $n$         -- Sent 0 = the class was hidden (mig 20261020110000); 1+ shows it again.
         hidden_by_count = CASE WHEN p_sent AND p_error IS NULL THEN coalesce(p_capacity, 1) < 1 ELSE t.hidden_by_count END,
         last_error      = left(p_error, 200)$n$, 1);

-- Classes on an event Exos created, or added by the channel sync, are Exos's.
SELECT pg_temp.exos_patch_n('public.exos_channel_mark(uuid, text, uuid, bigint, jsonb)',
  'exos_created',
  $o$        INSERT INTO public.exos_eventbrite_ticket_links AS k (event_id, eb_event_id, eb_ticket_class_id, eb_ticket_class_name, tier_id, active)
        VALUES (p_event_id, m.external_id, v_tid, left(t ->> 'name', 200), v_tier, true)
        ON CONFLICT (event_id, eb_event_id, eb_ticket_class_id) DO UPDATE
          SET tier_id = CASE WHEN k.counted_sold > 0 THEN k.tier_id ELSE EXCLUDED.tier_id END, active = true,$o$,
  $n$        INSERT INTO public.exos_eventbrite_ticket_links AS k (event_id, eb_event_id, eb_ticket_class_id, eb_ticket_class_name, tier_id, active, exos_created)
        VALUES (p_event_id, m.external_id, v_tid, left(t ->> 'name', 200), v_tier, true,
                m.mode = 'create' OR coalesce(t ->> 'created', '') = 'true')
        ON CONFLICT (event_id, eb_event_id, eb_ticket_class_id) DO UPDATE
          SET tier_id = CASE WHEN k.counted_sold > 0 THEN k.tier_id ELSE EXCLUDED.tier_id END, active = true,
              exos_created = k.exos_created OR EXCLUDED.exos_created,$n$, 1);

-- ---------------------------------------------------------------------------
-- 6. Luma's inventory: the shared share; Eventbrite's promise off the house.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_luma_inventory_apply(uuid, jsonb, timestamp with time zone)',
  '_exos_outside_share',
  $o$    v_share := CASE WHEN v_live THEN greatest(v_avail - v_pack, 0) + greatest(v_hold, 0) ELSE 0 END;$o$,
  $n$    -- One count with Eventbrite (mig 20261020110000): Luma's part of what is free.
    v_share := CASE WHEN v_live THEN least(public._exos_outside_share(t.tier_id, 'luma', v_pack), greatest(v_avail - v_pack, 0))
                                     + greatest(v_hold, 0) ELSE 0 END;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_luma_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'Eventbrite''s promise comes off the house',
  $o$  IF m.event_id IS NULL OR m.external_id IS NULL THEN RETURN; END IF;$o$,
  $n$  IF m.event_id IS NULL OR m.external_id IS NULL THEN RETURN; END IF;
  v_promised := public._exos_outside_out(p_event_id, 'eventbrite');   -- Eventbrite's promise comes off the house (mig 20261020110000)$n$, 1);

-- ROLLBACK (manual): re-run the CREATE OR REPLACE of _exos_channel_split_plan
-- from 20261014090000 + its patches (20261014100000, 20261014140000); restore
-- the two inventory applies, the ack and exos_channel_mark from
-- 20261019090000 / 20261014110000 / 20261014150000; DROP the functions above
-- and the two exos_eventbrite_ticket_links columns.
