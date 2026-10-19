-- ============================================================================
-- Exos: auto split of each ticket type across the marketplaces
-- ============================================================================
-- Touches:  W: exos_events (+ channel_split_mode, channel_reserve_pct,
--              channel_taper_hours, channel_split_at)
--           C: FUNCTION _exos_channel_split_plan (internal),
--              exos_apply_channel_split, exos_run_channel_splits (service
--              role), exos_set_channel_split, exos_channel_split_preview
--              (owner / manager)
--           W: FUNCTION exos_set_channel_allocation (patched in place: a hand
--              edit switches the event to manual), exos_channel_pool_plan
--              (patched in place: auto events use the split's share)
--           C: PROCEDURE exos_run_channel_splits_each (the cron's entry: one
--              commit per event)
--           C: cron.schedule (exos-channel-split-hourly, when pg_cron present)
--           R: exos_distribution_listings, exos_ticket_tiers,
--              exos_effective_available, exos_sync_channel_hold (20260928010000)
-- Pre-reqs: 20260928010000 (pools: sell_cap / sold_qty / pool_size and
--           exos_sync_channel_hold), 20260928040000 (exos_channel_pool_plan),
--           20260928070000 (the channel list)
--
-- The defaults come from docs/marketplace/channel-sim.md (Terminal-2 CRM
-- demand, 150 simulated events per cell): Exos keeps a reserve and shares the
-- rest evenly across the ticked marketplaces, rebalanced on a schedule.
--
--   reserve  = max(one pack, channel_reserve_pct of the ticket type), and
--              just one pack inside channel_taper_hours of the start
--              (defaults 10% and 48 h). A pack = the event's max per order,
--              8 without one.
--   shared   = the ticket type's unsold seats (free + held by marketplaces)
--              minus the reserve, split evenly; the remainder goes one seat
--              each to the marketplaces in channel order.
--   schedule = daily until a week out, every 6 hours until 48 hours out,
--              then hourly (exos_run_channel_splits, hourly cron).
--   free     = a ticket type priced 0 is not shared: the resale
--              marketplaces don't get free tickets by default (Exos keeps
--              them; Eventbrite may sell them once it is a channel). The
--              organizer can still put one on a marketplace by hand (manual).
--
-- In auto mode (once the split has run) the split is the plan for each pool: the scarcity and
-- stagnant rules of 20260928040000 (shrink to one order when Exos runs low,
-- shrink a pool that hasn't sold for a day) don't apply, since the split
-- already keeps Exos's reserve and moves seats to where they are needed.
-- The day-of cutoff (every pool to 0 three hours before doors) still does.
--
-- Each marketplace's share becomes its allocation row's hold target
-- (sell_cap = sold + share, pool_size = share), and exos_sync_channel_hold
-- moves the seats: growth only from seats free right now, under the checkout
-- locks; a LIVE listing keeps its seats until the marketplace confirms the
-- lower number. So a seat is still never on sale in two places, and a
-- marketplace sale does not top the pool up (its cap moved with it): the next
-- rebalance shares out what is left.
--
-- New events default to 'auto'. Every event that exists when this is applied
-- stays 'manual', so nothing changes under an organizer who already set the
-- grid. Editing the grid by hand (exos_set_channel_allocation by a user)
-- switches the event to 'manual'; exos_set_channel_split switches it back.
--
-- Nothing here talks to a marketplace: the holds are what exos-distribute
-- plans from, behind the same dry-run / write authorization as before.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated. Not applied.
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
-- 1. Settings. Existing events: 'manual' (the ADD COLUMN default fills them);
--    new events: 'auto'.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS channel_split_mode text NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS channel_reserve_pct integer NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS channel_taper_hours integer NOT NULL DEFAULT 48,
  ADD COLUMN IF NOT EXISTS channel_split_at timestamptz;
ALTER TABLE public.exos_events ALTER COLUMN channel_split_mode SET DEFAULT 'auto';

DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_channel_split_mode_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_channel_split_mode_chk
      CHECK (channel_split_mode IN ('auto', 'manual'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_channel_reserve_pct_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_channel_reserve_pct_chk
      CHECK (channel_reserve_pct BETWEEN 0 AND 90);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_channel_taper_hours_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_channel_taper_hours_chk
      CHECK (channel_taper_hours BETWEEN 0 AND 720);
  END IF;
END $c$;

COMMENT ON COLUMN public.exos_events.channel_split_mode IS
  'auto: Exos keeps a reserve and shares the rest of each ticket type evenly across the ticked marketplaces, rebalanced on a schedule (mig 20261014090000). manual: the organizer''s grid.';

-- ---------------------------------------------------------------------------
-- 2. The plan: each ticket type's reserve and each marketplace's share.
--    Internal; no auth (callers check).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_channel_split_plan(p_event_id uuid)
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
  t        record;
  v_unsold int;
  v_res    int;
  v_shared int;
  v_n      int;
  i        int;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL THEN
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
                  WHEN v_taper THEN v_pack
                  ELSE greatest(v_pack, ceil(t.capacity * e.channel_reserve_pct / 100.0)::int) END;
    v_res := least(v_res, v_unsold);
    v_shared := greatest(0, v_unsold - v_res);
    FOR i IN 1 .. v_n LOOP
      tier_id := t.id;
      channel := v_chs[i];
      unsold  := v_unsold;
      reserve := v_res;
      share   := v_shared / v_n + CASE WHEN i <= v_shared % v_n THEN 1 ELSE 0 END;
      RETURN NEXT;
    END LOOP;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public._exos_channel_split_plan(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_channel_split_plan(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Apply the plan to one event (auto mode only). Shrinks first, so the
--    seats they free can go to the marketplaces that grow. Returns how many
--    allocation rows changed, or NULL with a reason when the event is skipped.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_apply_channel_split(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  p        record;
  d        public.exos_distribution_listings%ROWTYPE;
  v_sum    bigint;
  v_uncap  boolean;
  v_rows   int := 0;
  v_before int;
  v_target int;
  v_free   int;
BEGIN
  -- No lock on the event row here: a marketplace sale locks its allocation
  -- row, then the event (exos_fulfil_marketplace_order); taking them in the
  -- other order could deadlock. The event is stamped at the end.
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'not-found');
  END IF;
  IF e.channel_split_mode <> 'auto' THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'manual');
  END IF;
  IF e.status <> 'published' OR (e.starts_at IS NOT NULL AND e.starts_at <= now()) THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'not-on-sale');
  END IF;
  IF coalesce(e.exclusivity ->> 'primaryMarketOnly', 'false') = 'true' THEN
    UPDATE public.exos_events SET channel_split_at = now() WHERE id = p_event_id;   -- not due again until its next slot
    RETURN jsonb_build_object('applied', false, 'reason', 'primary-market-only');
  END IF;
  -- Same rule as the grid: the house cap must not be tighter than the tiers.
  SELECT COALESCE(SUM(capacity), 0), bool_or(capacity = 0) INTO v_sum, v_uncap
    FROM public.exos_ticket_tiers WHERE event_id = p_event_id;
  IF e.total_tickets > 0 AND (v_uncap OR e.total_tickets < v_sum) THEN
    UPDATE public.exos_events SET channel_split_at = now() WHERE id = p_event_id;
    RETURN jsonb_build_object('applied', false, 'reason', 'house-cap');
  END IF;
  -- From here the pools follow the split's shares (exos_channel_pool_plan),
  -- also while the syncs below run, before the event is stamped.
  PERFORM set_config('exos.channel_split_event', p_event_id::text, true);

  FOR p IN
    SELECT pl.*, coalesce(al.requested_qty, 0) AS held
      FROM public._exos_channel_split_plan(p_event_id) pl
      LEFT JOIN public.exos_distribution_listings al
        ON al.event_id = p_event_id AND al.channel = pl.channel AND al.tier_id = pl.tier_id
     ORDER BY (pl.share - coalesce(al.requested_qty, 0)), pl.channel   -- shrinks first
  LOOP
    BEGIN
      -- Growing: only into seats free above the reserve, so a live listing
      -- still waiting to confirm its shrink can't make Exos lend its reserve.
      v_target := p.share;
      IF p.share > p.held THEN
        v_free := coalesce(public.exos_effective_available(p.tier_id), 0);
        v_target := least(p.share, p.held + greatest(0, v_free - p.reserve));
      END IF;
      SELECT * INTO d FROM public.exos_distribution_listings
       WHERE event_id = p_event_id AND channel = p.channel AND tier_id = p.tier_id FOR UPDATE;
      IF d.id IS NULL THEN
        IF v_target = 0 THEN
          CONTINUE;
        END IF;
        INSERT INTO public.exos_distribution_listings
          (event_id, org_id, channel, status, tier_id, requested_qty, sell_cap, pool_size, internal_seats)
        VALUES (p_event_id, e.org_id, p.channel, 'pending', p.tier_id, 0, v_target, v_target, '{}')
        RETURNING * INTO d;
        v_rows := v_rows + 1;
      ELSIF d.status = 'delisting' THEN
        CONTINUE;                                   -- on its way off; leave it
      ELSE
        v_before := coalesce(d.sell_cap, -1) - d.sold_qty;
        UPDATE public.exos_distribution_listings
           SET sell_cap  = d.sold_qty + v_target,
               pool_size = greatest(v_target, 1),
               requested_qty  = CASE WHEN status IN ('failed','delisted') THEN 0 ELSE requested_qty END,
               internal_seats = CASE WHEN status IN ('failed','delisted') THEN '{}'::int4multirange ELSE internal_seats END,
               status = CASE WHEN status IN ('failed','delisted') AND v_target > 0 THEN 'pending' ELSE status END,
               error  = CASE WHEN status IN ('failed','delisted') AND v_target > 0 THEN NULL ELSE error END,
               updated_at = now()
         WHERE id = d.id;
        IF v_before <> v_target THEN
          v_rows := v_rows + 1;
        END IF;
      END IF;
      PERFORM public.exos_sync_channel_hold(d.id);
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_apply_channel_split(% / % / %): %', p_event_id, p.tier_id, p.channel, SQLERRM;
    END;
  END LOOP;

  UPDATE public.exos_events SET channel_split_at = now() WHERE id = p_event_id;
  PERFORM set_config('exos.channel_split_event', '', true);
  RETURN jsonb_build_object('applied', true, 'changed', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_apply_channel_split(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_apply_channel_split(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. The schedule: every auto event that is due (hourly cron).
--    Daily until a week out, every 6 hours until 48 hours out, then hourly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_channel_split_due(p_starts_at timestamptz, p_last timestamptz)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT p_last IS NULL
      OR p_last <= now() - CASE
           WHEN p_starts_at IS NULL OR p_starts_at > now() + interval '7 days' THEN interval '23 hours 50 minutes'
           WHEN p_starts_at > now() + interval '48 hours' THEN interval '5 hours 50 minutes'
           ELSE interval '50 minutes' END
$$;
REVOKE ALL ON FUNCTION public._exos_channel_split_due(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_channel_split_due(timestamptz, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_run_channel_splits(p_limit integer DEFAULT 200)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r   record;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT e.id FROM public.exos_events e
     WHERE e.channel_split_mode = 'auto' AND e.status = 'published'
       AND (e.starts_at IS NULL OR e.starts_at > now())
       AND cardinality(coalesce(e.distribution_networks, '{}'::text[])) > 0
       AND coalesce(e.exclusivity ->> 'primaryMarketOnly', 'false') <> 'true'
       AND public._exos_channel_split_due(e.starts_at, e.channel_split_at)
     ORDER BY e.channel_split_at NULLS FIRST
     LIMIT LEAST(GREATEST(coalesce(p_limit, 200), 1), 1000)
  LOOP
    BEGIN
      PERFORM public.exos_apply_channel_split(r.id);
      v_n := v_n + 1;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_run_channel_splits(%): %', r.id, SQLERRM;
    END;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_run_channel_splits(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_run_channel_splits(integer) TO service_role;

-- The cron's entry point: the same run, committing after each event so one
-- event's locks (allocation rows, tiers) are never held while the next is
-- split. (The function above is the same loop in one transaction, for tests
-- and manual runs.)
-- No SET clause: a procedure with one can't COMMIT. Every name is qualified.
CREATE OR REPLACE PROCEDURE public.exos_run_channel_splits_each(p_limit integer DEFAULT 200)
LANGUAGE plpgsql
AS $$
DECLARE
  v_ids uuid[];
  v_id  uuid;
BEGIN
  v_ids := ARRAY(
    SELECT e.id FROM public.exos_events e
     WHERE e.channel_split_mode = 'auto' AND e.status = 'published'
       AND (e.starts_at IS NULL OR e.starts_at > now())
       AND cardinality(coalesce(e.distribution_networks, '{}'::text[])) > 0
       AND coalesce(e.exclusivity ->> 'primaryMarketOnly', 'false') <> 'true'
       AND public._exos_channel_split_due(e.starts_at, e.channel_split_at)
     ORDER BY e.channel_split_at NULLS FIRST
     LIMIT LEAST(GREATEST(coalesce(p_limit, 200), 1), 1000));
  FOREACH v_id IN ARRAY v_ids LOOP
    BEGIN
      PERFORM public.exos_apply_channel_split(v_id);
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_run_channel_splits_each(%): %', v_id, SQLERRM;
    END;
    COMMIT;
  END LOOP;
END $$;
REVOKE ALL ON PROCEDURE public.exos_run_channel_splits_each(integer) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. What the event editor shows, and the switch (owner / manager).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_channel_split_preview(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_channel_split_preview: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'mode', e.channel_split_mode,
    'reserve_pct', e.channel_reserve_pct,
    'taper_hours', e.channel_taper_hours,
    'tapered', e.starts_at IS NOT NULL AND e.starts_at <= now() + make_interval(hours => e.channel_taper_hours),
    'last_run_at', e.channel_split_at,
    'tiers', coalesce((
      SELECT jsonb_agg(jsonb_build_object('tier_id', x.tier_id, 'unsold', x.unsold, 'reserve', x.reserve,
                                          'shares', x.shares))
        FROM (SELECT pl.tier_id, max(pl.unsold) unsold, max(pl.reserve) reserve,
                     jsonb_object_agg(pl.channel, pl.share) shares
                FROM public._exos_channel_split_plan(p_event_id) pl GROUP BY pl.tier_id) x), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_split_preview(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_channel_split_preview(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_set_channel_split(
  p_event_id uuid, p_mode text, p_reserve_pct integer DEFAULT NULL, p_taper_hours integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_channel_split: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('auto', 'manual') THEN
    RAISE EXCEPTION 'exos_set_channel_split: mode must be auto or manual' USING ERRCODE = '22023';
  END IF;
  IF p_reserve_pct IS NOT NULL AND p_reserve_pct NOT BETWEEN 0 AND 90 THEN
    RAISE EXCEPTION 'exos_set_channel_split: reserve must be 0-90%%' USING ERRCODE = '22023';
  END IF;
  IF p_taper_hours IS NOT NULL AND p_taper_hours NOT BETWEEN 0 AND 720 THEN
    RAISE EXCEPTION 'exos_set_channel_split: taper must be 0-720 hours' USING ERRCODE = '22023';
  END IF;
  IF p_mode = 'manual' AND e.channel_split_mode = 'auto' THEN
    -- The split's pool sizes go: manual pools are 2 x max per order again.
    UPDATE public.exos_distribution_listings SET pool_size = NULL WHERE event_id = p_event_id AND tier_id IS NOT NULL;
  END IF;
  UPDATE public.exos_events
     SET channel_split_mode  = p_mode,
         channel_reserve_pct = coalesce(p_reserve_pct, channel_reserve_pct),
         channel_taper_hours = coalesce(p_taper_hours, channel_taper_hours),
         channel_split_at    = CASE WHEN p_mode = 'auto' THEN NULL ELSE channel_split_at END
   WHERE id = p_event_id;
  -- Switching on (or changing the numbers) applies at once when on sale.
  IF p_mode = 'auto' THEN
    PERFORM public.exos_apply_channel_split(p_event_id);
  END IF;
  RETURN public.exos_channel_split_preview(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_channel_split(uuid, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_channel_split(uuid, text, integer, integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. A hand edit of the grid means manual.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  'channel_split_mode = ''manual''',
  $o$    RAISE EXCEPTION 'exos_set_channel_allocation: not authorized' USING ERRCODE = '42501';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_set_channel_allocation: not authorized' USING ERRCODE = '42501';
  END IF;
  -- A person setting the grid takes over from the auto split (mig 20261014090000).
  IF auth.uid() IS NOT NULL THEN
    UPDATE public.exos_events SET channel_split_mode = 'manual' WHERE id = p_event_id AND channel_split_mode <> 'manual';
    IF FOUND THEN
      -- The split's pool sizes go: manual pools are 2 x max per order again.
      UPDATE public.exos_distribution_listings SET pool_size = NULL WHERE event_id = p_event_id AND tier_id IS NOT NULL;
    END IF;
  END IF;$n$, 1);

-- ---------------------------------------------------------------------------
-- 6b. Auto events: the pool target is the split's share (no scarcity or
--     stagnant shrink); the day-of cutoff above it still applies.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_channel_pool_plan(uuid)',
  $m$'auto'::text$m$,
  $o$  -- 2. Selling or stagnant.$o$,
  $n$  -- Auto split (mig 20261014090000): once it has run, its share is the target.
  IF e.channel_split_mode = 'auto'
     AND (e.channel_split_at IS NOT NULL OR current_setting('exos.channel_split_event', true) = e.id::text) THEN
    RETURN QUERY SELECT v_base, 'auto'::text, 0;
    RETURN;
  END IF;

  -- 2. Selling or stagnant.$n$, 1);

-- ---------------------------------------------------------------------------
-- 7. Cron: hourly at :37 (off the :00 / :05 cluster). Guarded so a preview
--    branch / CI Postgres without pg_cron applies.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-channel-split-hourly') THEN
      PERFORM cron.unschedule('exos-channel-split-hourly');
    END IF;
    PERFORM cron.schedule('exos-channel-split-hourly', '37 * * * *',
                          $cron$CALL public.exos_run_channel_splits_each();$cron$);
  END IF;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos-channel-split-hourly');
-- re-create exos_set_channel_allocation from 20260928010000 + its channel
-- patches; DROP the functions above; DROP the four exos_events columns.
