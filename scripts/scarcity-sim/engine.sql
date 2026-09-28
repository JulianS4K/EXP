-- Scarcity-mode simulator (dry run). Drives the real database functions
-- (exos_set_channel_allocation, exos_refill_channel_pools,
-- exos_confirm_channel_listing, exos_record_marketplace_order,
-- exos_fulfil_marketplace_order, exos_seats_available) through one event's
-- on-sale, from `start_h` hours before doors to the event start, with buyers
-- arriving on Exos and on each marketplace. Nothing leaves the database; each
-- scenario runs in a transaction the runner rolls back.
--
-- Time: the functions read now(), which is fixed inside a transaction, so
-- the clock "moves" by shifting every stored time of the scenario back by
-- each step (event start / doors, last_sold_at, idle_since).
--
-- Marketplaces are modelled as live listings with a sender: a marketplace
-- shows `shown` seats; when the planned quantity (list_qty) changes, the
-- sender updates the marketplace after `lag` steps and, on a shrink, calls
-- exos_confirm_channel_listing (seats go back to Exos only then). Buyers on
-- a marketplace buy against what it shows, so a slow sender lets them buy
-- seats Exos has already planned away: those are the edge cases to watch.
--
-- Scenario (jsonb):
--   name, seed, capacity, max_per_order (null: none), start_h (hours before
--   doors, default 336), doors_before_start_min (default 60; -1: no doors
--   time), publish_h (hours before doors it's published; default start_h),
--   step_far_min (60), step_near_min (15, inside 26 h of doors),
--   exos: { rate (buyers/hour), dayof_mult (x in the last 24 h), qty_max }
--   channels: [{ ch, cap, rate, dayof_mult, qty_max, lag (steps, default 1),
--                live (default true) }]
--   sender_down_h: hours before doors after which the sender stops
--   actions: [{ at_h, type: refund | set_cap | untick, ch?, qty? }]

CREATE OR REPLACE FUNCTION pg_temp.sim(p jsonb) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
  v_org   uuid := gen_random_uuid();
  v_uid   uuid := gen_random_uuid();
  v_ev    uuid := gen_random_uuid();
  v_tier  uuid := gen_random_uuid();
  v_cap   int := (p->>'capacity')::int;
  v_mpo   int := CASE WHEN jsonb_typeof(p->'max_per_order') = 'number' THEN (p->>'max_per_order')::int END;
  v_block int;
  v_h     numeric := coalesce((p->>'start_h')::numeric, 336);
  v_gap   int := coalesce((p->>'doors_before_start_min')::int, 60);
  v_pub_h numeric := coalesce((p->>'publish_h')::numeric, coalesce((p->>'start_h')::numeric, 336));
  v_far   numeric := coalesce((p->>'step_far_min')::numeric, 60) / 60;
  v_near  numeric := coalesce((p->>'step_near_min')::numeric, 15) / 60;
  v_down  numeric := (p->>'sender_down_h')::numeric;
  v_end   numeric;
  v_dt    numeric;
  v_step  int := 0;
  v_published boolean;
  v_marks numeric[] := ARRAY[168, 72, 24, 12, 6, 3, 1, 0];
  v_mark_i int := 1;
  v_done  int[] := '{}';
  v_viol  int := 0;
  v_soldout_h numeric := 0;
  v_held_at_doors int;
  v_seen_doors boolean := false;
  v_n     int;
  v_q     int;
  v_avail int;
  v_before int;
  v_status text;
  v_line  text;
  v_mult  numeric;
  v_lam   numeric;
  c       record;
  d       record;
  b       record;
  a       jsonb;
  i       int;
BEGIN
  PERFORM setseed(coalesce((p->>'seed')::numeric, 0.42));
  v_block := coalesce(v_mpo, 1000000);
  -- The event runs until its start (doors + gap); with no doors time, doors = start.
  v_end := CASE WHEN v_gap >= 0 THEN -(v_gap::numeric / 60) ELSE 0 END;

  INSERT INTO auth.users(id, email, email_confirmed_at) VALUES (v_uid, 'sim-' || v_uid || '@x.test', now());
  INSERT INTO public.exos_orgs(id, name, slug, owner_uid) VALUES (v_org, 'Sim', 'sim-' || v_org, v_uid);
  INSERT INTO public.exos_org_memberships(org_id, user_id, role) VALUES (v_org, v_uid, 'owner');
  v_published := v_pub_h >= v_h;
  INSERT INTO public.exos_events(id, org_id, name, status, starts_at, doors_at, venue_name, total_tickets, tickets_sold,
                                 distribution_networks, purchase_limits)
  VALUES (v_ev, v_org, p->>'name', CASE WHEN v_published THEN 'published' ELSE 'draft' END,
          now() + make_interval(secs => (v_h * 3600 + greatest(v_gap, 0) * 60)::double precision),
          CASE WHEN v_gap >= 0 THEN now() + make_interval(secs => (v_h * 3600)::double precision) END,
          'Hall', v_cap, 0,
          ARRAY(SELECT x->>'ch' FROM jsonb_array_elements(coalesce(p->'channels', '[]')) x),
          CASE WHEN v_mpo IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('maxPerOrder', v_mpo) END);
  INSERT INTO public.exos_ticket_tiers(id, event_id, name, price, capacity, sold) VALUES (v_tier, v_ev, 'GA', 50, v_cap, 0);

  DROP TABLE IF EXISTS pg_temp.sim_ch;
  CREATE TEMP TABLE sim_ch (
    ch text PRIMARY KEY, alloc uuid, live boolean, lag int, shown int DEFAULT 0, pend int,
    rate numeric, mult numeric, qmax int,
    buyers int DEFAULT 0, sold int DEFAULT 0, lost int DEFAULT 0, attn int DEFAULT 0, attn_qty int DEFAULT 0, from_free int DEFAULT 0);
  INSERT INTO sim_ch(ch, live, lag, rate, mult, qmax)
  VALUES ('exos', false, 0, coalesce((p#>>'{exos,rate}')::numeric, 0), coalesce((p#>>'{exos,dayof_mult}')::numeric, 1),
          least(coalesce((p#>>'{exos,qty_max}')::int, 4), v_block));
  FOR c IN SELECT x FROM jsonb_array_elements(coalesce(p->'channels', '[]')) x LOOP
    BEGIN
      PERFORM public.exos_set_channel_allocation(v_ev, c.x->>'ch', v_tier, (c.x->>'cap')::int);
    EXCEPTION WHEN others THEN
      RETURN NEXT format('   setup: the grid refused %s cap %s: %s', c.x->>'ch', c.x->>'cap', SQLERRM);
      CONTINUE;
    END;
    INSERT INTO sim_ch(ch, alloc, live, lag, rate, mult, qmax)
    SELECT c.x->>'ch', d2.id, coalesce((c.x->>'live')::boolean, true), coalesce((c.x->>'lag')::int, 1),
           coalesce((c.x->>'rate')::numeric, 0), coalesce((c.x->>'dayof_mult')::numeric, 1),
           least(coalesce((c.x->>'qty_max')::int, 4), v_block)
      FROM public.exos_distribution_listings d2
     WHERE d2.event_id = v_ev AND d2.channel = c.x->>'ch' AND d2.tier_id = v_tier;
  END LOOP;
  -- Live from the start: the marketplace shows what's held.
  UPDATE public.exos_distribution_listings dl SET status = 'listed', external_listing_id = 'SIM-' || dl.channel
    FROM sim_ch s WHERE s.alloc = dl.id AND s.live;
  UPDATE sim_ch s SET shown = coalesce(dl.list_qty, dl.requested_qty, 0)
    FROM public.exos_distribution_listings dl WHERE dl.id = s.alloc;

  RETURN NEXT format('== %s: %s seats, max per order %s, %s marketplace(s), %s h to doors%s',
    p->>'name', v_cap, coalesce(v_mpo::text, 'none'), (SELECT count(*) - 1 FROM sim_ch),
    v_h, CASE WHEN v_gap < 0 THEN ' (no doors time: cutoff from the start)' ELSE '' END);

  WHILE v_h > v_end LOOP
    v_step := v_step + 1;
    v_dt := CASE WHEN v_h <= 26 THEN v_near ELSE v_far END;

    -- Scheduled actions (organizer / refunds).
    i := 0;
    FOR a IN SELECT x FROM jsonb_array_elements(coalesce(p->'actions', '[]')) x LOOP
      i := i + 1;
      CONTINUE WHEN i = ANY (v_done) OR (a->>'at_h')::numeric < v_h;
      v_done := v_done || i;
      IF a->>'type' = 'refund' THEN
        v_q := least((a->>'qty')::int, (SELECT sold FROM public.exos_ticket_tiers WHERE id = v_tier));
        UPDATE public.exos_ticket_tiers SET sold = sold - v_q WHERE id = v_tier;
        UPDATE public.exos_events SET tickets_sold = greatest(tickets_sold - v_q, 0) WHERE id = v_ev;
        RETURN NEXT format('   T-%sh  action: %s seats refunded', round(v_h, 1), v_q);
      ELSIF a->>'type' = 'set_cap' THEN
        BEGIN
          PERFORM public.exos_set_channel_allocation(v_ev, a->>'ch', v_tier, (a->>'qty')::int);
          RETURN NEXT format('   T-%sh  action: %s cap set to %s', round(v_h, 1), a->>'ch', a->>'qty');
        EXCEPTION WHEN others THEN
          RETURN NEXT format('   T-%sh  action: %s cap %s refused: %s', round(v_h, 1), a->>'ch', a->>'qty', SQLERRM);
        END;
      ELSIF a->>'type' = 'untick' THEN
        UPDATE public.exos_events SET distribution_networks = array_remove(distribution_networks, a->>'ch') WHERE id = v_ev;
        RETURN NEXT format('   T-%sh  action: %s unticked', round(v_h, 1), a->>'ch');
      END IF;
    END LOOP;

    IF NOT v_published AND v_h <= v_pub_h THEN
      UPDATE public.exos_events SET status = 'published' WHERE id = v_ev;
      v_published := true;
      RETURN NEXT format('   T-%sh  published', round(v_h, 1));
    END IF;

    -- exos-distribute run: refill every pool.
    PERFORM public.exos_refill_channel_pools();

    -- The sender: brings each marketplace to the planned quantity after its lag.
    FOR c IN SELECT * FROM sim_ch WHERE ch <> 'exos' LOOP
      SELECT * INTO d FROM public.exos_distribution_listings WHERE id = c.alloc;
      v_q := CASE WHEN d.status IN ('pending','planned','listing','listed') THEN coalesce(d.list_qty, d.requested_qty, 0)
                  WHEN d.status = 'delisting' THEN 0 ELSE 0 END;
      IF NOT c.live THEN
        UPDATE sim_ch SET shown = v_q, pend = NULL WHERE ch = c.ch;
      ELSIF v_down IS NOT NULL AND v_h <= v_down THEN
        NULL; -- sender down: the marketplace keeps showing what it had
      ELSIF v_q = c.shown THEN
        UPDATE sim_ch SET pend = NULL WHERE ch = c.ch;
        IF d.status = 'delisting' AND c.shown = 0 THEN
          UPDATE public.exos_distribution_listings SET status = 'delisted', requested_qty = 0, internal_seats = '{}' WHERE id = c.alloc;
        ELSIF coalesce(d.requested_qty, 0) > v_q THEN
          PERFORM public.exos_confirm_channel_listing(c.alloc);
        END IF;
      ELSIF c.pend IS NULL AND c.lag > 0 THEN
        UPDATE sim_ch SET pend = v_step WHERE ch = c.ch;
      ELSIF c.lag = 0 OR v_step - c.pend >= c.lag THEN
        UPDATE sim_ch SET shown = v_q, pend = NULL WHERE ch = c.ch;
        IF d.status = 'delisting' AND v_q = 0 THEN
          UPDATE public.exos_distribution_listings SET status = 'delisted', requested_qty = 0, internal_seats = '{}' WHERE id = c.alloc;
        ELSIF coalesce(d.requested_qty, 0) > v_q THEN
          PERFORM public.exos_confirm_channel_listing(c.alloc);
        END IF;
      END IF;
    END LOOP;

    -- Checkpoints.
    WHILE v_mark_i <= array_length(v_marks, 1) AND v_h <= v_marks[v_mark_i] LOOP
      SELECT string_agg(format('%s %s/%s %s', s.ch, coalesce(dl.requested_qty, 0), s.shown,
                               coalesce((SELECT state FROM public.exos_channel_pool_plan(s.alloc)), '-')), ' | ' ORDER BY s.ch)
        INTO v_line
        FROM sim_ch s JOIN public.exos_distribution_listings dl ON dl.id = s.alloc WHERE s.ch <> 'exos';
      RETURN NEXT format('   T-%sh  Exos free %s | %s', v_marks[v_mark_i],
        public.exos_tier_available(v_tier), coalesce(v_line, '(no marketplaces)'));
      IF v_marks[v_mark_i] = 0 THEN
        v_held_at_doors := (SELECT coalesce(sum(requested_qty), 0) FROM public.exos_distribution_listings WHERE tier_id = v_tier
                             AND status IN ('pending','planned','listing','listed','delisting'));
        v_seen_doors := true;
      END IF;
      v_mark_i := v_mark_i + 1;
    END LOOP;

    -- Buyers arrive (Bernoulli-rounded Poisson), in random order.
    DROP TABLE IF EXISTS pg_temp.sim_buyers;
    CREATE TEMP TABLE sim_buyers (ch text, qty int, ord float8);
    -- Nobody can buy before the event is on sale.
    FOR c IN SELECT * FROM sim_ch WHERE v_published LOOP
      v_mult := CASE WHEN v_h <= 24 THEN c.mult ELSE 1 END;
      v_lam := c.rate * v_mult * v_dt;
      v_n := floor(v_lam)::int + CASE WHEN random() < v_lam - floor(v_lam) THEN 1 ELSE 0 END;
      FOR i IN 1..v_n LOOP
        INSERT INTO sim_buyers VALUES (c.ch, 1 + floor(random() * c.qmax)::int, random());
      END LOOP;
    END LOOP;
    FOR b IN SELECT * FROM sim_buyers ORDER BY ord LOOP
      UPDATE sim_ch SET buyers = buyers + 1 WHERE ch = b.ch;
      IF b.ch = 'exos' THEN
        IF public.exos_seats_available(v_tier, b.qty) THEN
          UPDATE public.exos_ticket_tiers SET sold = sold + b.qty WHERE id = v_tier;
          UPDATE public.exos_events SET tickets_sold = tickets_sold + b.qty WHERE id = v_ev;
          UPDATE sim_ch SET sold = sold + b.qty WHERE ch = 'exos';
        ELSE
          UPDATE sim_ch SET lost = lost + b.qty WHERE ch = 'exos';
        END IF;
        CONTINUE;
      END IF;
      SELECT * INTO c FROM sim_ch WHERE ch = b.ch;
      v_avail := least(c.shown, v_block);
      IF b.qty > v_avail THEN
        UPDATE sim_ch SET lost = lost + b.qty WHERE ch = b.ch;
        CONTINUE;
      END IF;
      v_before := (SELECT coalesce(requested_qty, 0) FROM public.exos_distribution_listings WHERE id = c.alloc);
      PERFORM public.exos_record_marketplace_order(jsonb_build_object(
        'channel', b.ch, 'external_order_id', 'SIM-' || v_step || '-' || b.ord, 'external_listing_id', c.alloc::text,
        'quantity', b.qty, 'sale_status', 'confirmed', 'buyer_email', 'buyer@sim.test'));
      PERFORM public.exos_fulfil_marketplace_order(
        (SELECT id FROM public.exos_marketplace_orders WHERE channel = b.ch AND external_order_id = 'SIM-' || v_step || '-' || b.ord));
      SELECT status INTO v_status FROM public.exos_marketplace_orders WHERE channel = b.ch AND external_order_id = 'SIM-' || v_step || '-' || b.ord;
      -- The marketplace thinks it sold them either way.
      UPDATE sim_ch SET shown = shown - b.qty WHERE ch = b.ch;
      IF v_status = 'fulfilled' THEN
        UPDATE sim_ch SET sold = sold + b.qty, from_free = from_free + CASE WHEN v_before < b.qty THEN 1 ELSE 0 END WHERE ch = b.ch;
      ELSE
        UPDATE sim_ch SET attn = attn + 1, attn_qty = attn_qty + b.qty WHERE ch = b.ch;
      END IF;
    END LOOP;

    -- Invariants: never more sold + held than capacity.
    IF (SELECT sold FROM public.exos_ticket_tiers WHERE id = v_tier) + public.exos_channel_allocated(v_tier) > v_cap
       OR (SELECT sold FROM public.exos_ticket_tiers WHERE id = v_tier) > v_cap THEN
      v_viol := v_viol + 1;
    END IF;
    IF NOT public.exos_seats_available(v_tier, 1) AND public.exos_channel_allocated(v_tier) > 0 THEN
      v_soldout_h := v_soldout_h + v_dt;
    END IF;

    -- Advance the clock.
    UPDATE public.exos_events
       SET starts_at = starts_at - make_interval(secs => (v_dt * 3600)::double precision),
           doors_at = doors_at - make_interval(secs => (v_dt * 3600)::double precision)
     WHERE id = v_ev;
    UPDATE public.exos_distribution_listings
       SET last_sold_at = last_sold_at - make_interval(secs => (v_dt * 3600)::double precision),
           idle_since = idle_since - make_interval(secs => (v_dt * 3600)::double precision)
     WHERE event_id = v_ev;
    v_h := v_h - v_dt;
  END LOOP;

  IF NOT v_seen_doors THEN
    v_held_at_doors := (SELECT coalesce(sum(requested_qty), 0) FROM public.exos_distribution_listings WHERE tier_id = v_tier
                         AND status IN ('pending','planned','listing','listed','delisting'));
  END IF;

  -- Results.
  SELECT string_agg(format('%s %s', ch, sold), ', ' ORDER BY ch = 'exos' DESC, ch) INTO v_line FROM sim_ch;
  RETURN NEXT format('   RESULT sold %s/%s (%s); unsold %s',
    (SELECT sold FROM public.exos_ticket_tiers WHERE id = v_tier), v_cap, v_line,
    v_cap - (SELECT sold FROM public.exos_ticket_tiers WHERE id = v_tier));
  SELECT string_agg(format('%s %s', ch, lost), ', ' ORDER BY ch = 'exos' DESC, ch) INTO v_line FROM sim_ch WHERE lost > 0;
  RETURN NEXT format('   lost demand (seats buyers wanted but couldn''t get there): %s', coalesce(v_line, 'none'));
  RETURN NEXT format('   held by marketplaces at doors: %s; hours Exos had no free seat while a pool held some: %s h',
    coalesce(v_held_at_doors::text, '-'), round(v_soldout_h, 1));
  SELECT string_agg(format('%s %s order(s)/%s seat(s)', ch, attn, attn_qty), ', ') INTO v_line FROM sim_ch WHERE attn > 0;
  RETURN NEXT format('   marketplace sales sent to a human (sold more than held): %s', coalesce(v_line, 'none'));
  SELECT string_agg(format('%s %s', ch, from_free), ', ') INTO v_line FROM sim_ch WHERE from_free > 0;
  RETURN NEXT format('   marketplace sales served from Exos''s free seats (pool short, seats free): %s', coalesce(v_line, 'none'));
  -- Integrity: never over capacity, no seat in two places.
  RETURN NEXT format('   integrity: %s',
    CASE WHEN v_viol = 0
          AND (SELECT sold FROM public.exos_ticket_tiers WHERE id = v_tier) <= v_cap
          AND NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings x JOIN public.exos_distribution_listings y
                            ON x.tier_id = y.tier_id AND x.id < y.id
                           WHERE x.tier_id = v_tier AND NOT isempty(x.internal_seats * y.internal_seats))
          AND NOT EXISTS (SELECT internal_seat FROM public.exos_tickets WHERE tier_id = v_tier AND internal_seat IS NOT NULL
                           GROUP BY internal_seat HAVING count(*) > 1)
         THEN 'ok (never over capacity, no seat held or sold twice)'
         ELSE format('VIOLATION (%s step(s) over capacity)', v_viol) END);
END $$;
