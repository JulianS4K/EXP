-- ============================================================================
-- Auto channel split (mig 20261014090000):
--   S1 new events default to auto (10%, 48 h); the plan: reserve = max(pack,
--      10%), the rest split evenly, remainder to the first marketplace
--   S2 apply: allocation rows created, the holds taken, Exos keeps the reserve
--   S3 Exos sells: the next run shrinks the marketplaces to keep the reserve
--   S4 a marketplace sells: the pool is not topped up at once; the next run
--      shrinks the other first, then grows it, never under the reserve
--   S5 inside 48 h the reserve drops to one pack and the rest is shared out
--   S6 a live listing keeps its seats until the marketplace confirms the
--      shrink, and nothing grows into the reserve meanwhile
--   S7 a hand edit of the grid switches to manual; the run then skips it;
--      exos_set_channel_split switches back (owner / manager only)
--   S8 the schedule: daily / 6 h / hourly; the run picks only due events
--   S9 skipped: drafts, past events, primary market only, a tight house cap
--   S10 grants
--   S11 a free ticket type is not shared with the resale marketplaces; set
--       by hand it still can be
-- Self-contained (a5 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a5000000-0000-0000-0000-0000000000a0','a5-owner@x.com',now()),
  ('a5000000-0000-0000-0000-0000000000a9','a5-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a5000000-0000-0000-0000-000000000001','A5 Org','a5-org','a5000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a5000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-0000000000a0','owner');
-- e1: 100 GA, two marketplaces, a month out, max 4 per order (pack = 4).
-- e2: a draft. e3: primary market only.
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks,purchase_limits,exclusivity) VALUES
  ('a5000000-0000-0000-0000-0000000000e1','a5000000-0000-0000-0000-000000000001','Split Show','published',now() + interval '30 days','Hall',0,0,ARRAY['stubhub','seatgeek'],'{"maxPerOrder":4}','{}'),
  ('a5000000-0000-0000-0000-0000000000e2','a5000000-0000-0000-0000-000000000001','Draft','draft',now() + interval '30 days','Hall',0,0,ARRAY['stubhub'],'{}','{}'),
  ('a5000000-0000-0000-0000-0000000000e3','a5000000-0000-0000-0000-000000000001','Primary only','published',now() + interval '30 days','Hall',0,0,ARRAY['stubhub'],'{}','{"primaryMarketOnly":"true"}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('a5000000-0000-0000-0000-0000000000d1','a5000000-0000-0000-0000-0000000000e1','GA',50,100,0),
  ('a5000000-0000-0000-0000-0000000000d2','a5000000-0000-0000-0000-0000000000e2','GA',50,100,0),
  ('a5000000-0000-0000-0000-0000000000d3','a5000000-0000-0000-0000-0000000000e3','GA',50,100,0);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"a5@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.held(p_ch text) RETURNS int LANGUAGE sql AS $$
  SELECT coalesce((SELECT requested_qty FROM public.exos_distribution_listings
                    WHERE tier_id = 'a5000000-0000-0000-0000-0000000000d1' AND channel = p_ch), 0)
$$;
CREATE FUNCTION pg_temp.free() RETURNS int LANGUAGE sql AS $$
  SELECT public.exos_effective_available('a5000000-0000-0000-0000-0000000000d1')
$$;
CREATE FUNCTION pg_temp.ev() RETURNS uuid LANGUAGE sql AS $$ SELECT 'a5000000-0000-0000-0000-0000000000e1'::uuid $$;

-- S1. Defaults and the plan.
DO $$
DECLARE r record;
BEGIN
  ASSERT (SELECT channel_split_mode = 'auto' AND channel_reserve_pct = 10 AND channel_taper_hours = 48
            FROM public.exos_events WHERE id = pg_temp.ev()), 'S1: defaults';
  FOR r IN SELECT * FROM public._exos_channel_split_plan(pg_temp.ev()) LOOP
    ASSERT r.unsold = 100 AND r.reserve = 10 AND r.share = 45, 'S1: plan ' || row_to_json(r)::text;
  END LOOP;
  ASSERT (SELECT count(*) FROM public._exos_channel_split_plan(pg_temp.ev())) = 2, 'S1: two marketplaces';
END $$;

-- S2. Apply.
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_apply_channel_split(pg_temp.ev());
  ASSERT r->>'applied' = 'true' AND r->>'changed' = '2', 'S2: ' || r::text;
  ASSERT pg_temp.held('stubhub') = 45 AND pg_temp.held('seatgeek') = 45, 'S2: holds';
  ASSERT pg_temp.free() = 10, 'S2: Exos keeps the reserve ' || pg_temp.free();
  ASSERT (SELECT channel_split_at IS NOT NULL FROM public.exos_events WHERE id = pg_temp.ev()), 'S2: stamped';
  -- Applying again changes nothing.
  r := public.exos_apply_channel_split(pg_temp.ev());
  ASSERT r->>'changed' = '0', 'S2: idempotent ' || r::text;
END $$;

-- S3. Exos sells 5 of its 10: the marketplaces give back to keep 10.
DO $$
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = 5 WHERE id = 'a5000000-0000-0000-0000-0000000000d1';
  ASSERT pg_temp.free() = 5, 'S3: Exos has 5';
  PERFORM public.exos_apply_channel_split(pg_temp.ev());
  -- 95 unsold, 10 reserve, 85 shared: 43 / 42.
  ASSERT pg_temp.held('stubhub') = 43 AND pg_temp.held('seatgeek') = 42, 'S3: ' || pg_temp.held('stubhub') || '/' || pg_temp.held('seatgeek');
  ASSERT pg_temp.free() = 10, 'S3: reserve back to 10, got ' || pg_temp.free();
END $$;

-- S4. StubHub sells 10.
DO $$
BEGIN
  UPDATE public.exos_distribution_listings SET sold_qty = sold_qty + 10, requested_qty = requested_qty - 10
   WHERE tier_id = 'a5000000-0000-0000-0000-0000000000d1' AND channel = 'stubhub';
  UPDATE public.exos_ticket_tiers SET sold = sold + 10 WHERE id = 'a5000000-0000-0000-0000-0000000000d1';
  -- A refill run between rebalances doesn't top StubHub back up (its cap moved with the sale).
  PERFORM public.exos_refill_channel_pools();
  ASSERT pg_temp.held('stubhub') = 33, 'S4: topped up at once ' || pg_temp.held('stubhub');
  PERFORM public.exos_apply_channel_split(pg_temp.ev());
  -- 85 unsold, 10 reserve, 75 shared: 38 / 37.
  ASSERT pg_temp.held('stubhub') = 38 AND pg_temp.held('seatgeek') = 37, 'S4: ' || pg_temp.held('stubhub') || '/' || pg_temp.held('seatgeek');
  ASSERT pg_temp.free() = 10, 'S4: reserve ' || pg_temp.free();
END $$;

-- S5. Inside 48 h: reserve = one pack (4), 81 shared: 41 / 40.
DO $$
DECLARE r record;
BEGIN
  UPDATE public.exos_events SET starts_at = now() + interval '24 hours' WHERE id = pg_temp.ev();
  SELECT * INTO r FROM public._exos_channel_split_plan(pg_temp.ev()) LIMIT 1;
  ASSERT r.reserve = 4, 'S5: tapered reserve ' || r.reserve;
  PERFORM public.exos_apply_channel_split(pg_temp.ev());
  ASSERT pg_temp.held('stubhub') = 41 AND pg_temp.held('seatgeek') = 40, 'S5: ' || pg_temp.held('stubhub') || '/' || pg_temp.held('seatgeek');
  ASSERT pg_temp.free() = 4, 'S5: one pack left on Exos ' || pg_temp.free();
END $$;

-- S6. Live SeatGeek must shrink (Exos sold out its 4 and wants a pack back):
--     the seats stay until confirmed, and StubHub can't grow into the reserve.
DO $$
DECLARE v_sg int;
BEGIN
  UPDATE public.exos_distribution_listings SET status = 'listed', external_listing_id = 'sg-1'
   WHERE tier_id = 'a5000000-0000-0000-0000-0000000000d1' AND channel = 'seatgeek';
  UPDATE public.exos_ticket_tiers SET sold = sold + 4 WHERE id = 'a5000000-0000-0000-0000-0000000000d1';
  ASSERT pg_temp.free() = 0, 'S6: Exos out';
  PERFORM public.exos_apply_channel_split(pg_temp.ev());
  -- 81 unsold, 4 reserve, 77 shared: 39 / 38. StubHub (not live) shrinks to 39 now;
  -- SeatGeek stays at 40 held but lists 38 until the marketplace confirms.
  ASSERT pg_temp.held('stubhub') = 39, 'S6: stubhub ' || pg_temp.held('stubhub');
  SELECT requested_qty INTO v_sg FROM public.exos_distribution_listings
   WHERE tier_id = 'a5000000-0000-0000-0000-0000000000d1' AND channel = 'seatgeek';
  ASSERT v_sg = 40, 'S6: live seats kept until confirmed ' || v_sg;
  ASSERT (SELECT list_qty FROM public.exos_distribution_listings
           WHERE tier_id = 'a5000000-0000-0000-0000-0000000000d1' AND channel = 'seatgeek') = 38, 'S6: lists the lower number';
  ASSERT pg_temp.free() = 2, 'S6: free ' || pg_temp.free();
  PERFORM public.exos_confirm_channel_listing((SELECT id FROM public.exos_distribution_listings
           WHERE tier_id = 'a5000000-0000-0000-0000-0000000000d1' AND channel = 'seatgeek'));
  ASSERT pg_temp.held('seatgeek') = 38 AND pg_temp.free() = 4, 'S6: confirmed, reserve back ' || pg_temp.free();
END $$;

-- S7. Manual and back.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('a5000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_channel_allocation(pg_temp.ev(), 'stubhub', 'a5000000-0000-0000-0000-0000000000d1', 50);
  ASSERT (SELECT channel_split_mode FROM public.exos_events WHERE id = pg_temp.ev()) = 'manual', 'S7: hand edit -> manual';
  PERFORM pg_temp.act(NULL);
  r := public.exos_apply_channel_split(pg_temp.ev());
  ASSERT r->>'reason' = 'manual', 'S7: manual skipped ' || r::text;
  PERFORM pg_temp.act('a5000000-0000-0000-0000-0000000000a9');
  BEGIN
    PERFORM public.exos_set_channel_split(pg_temp.ev(), 'auto');
    RAISE EXCEPTION 'S7: a stranger switched it';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_channel_split_preview(pg_temp.ev());
    RAISE EXCEPTION 'S7: a stranger previewed it';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act('a5000000-0000-0000-0000-0000000000a0');
  BEGIN
    PERFORM public.exos_set_channel_split(pg_temp.ev(), 'sometimes');
    RAISE EXCEPTION 'S7: bad mode accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_channel_split(pg_temp.ev(), 'auto', 95);
    RAISE EXCEPTION 'S7: 95%% reserve accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  r := public.exos_set_channel_split(pg_temp.ev(), 'auto', 20, 24);
  ASSERT r->>'mode' = 'auto' AND r->>'reserve_pct' = '20' AND r->>'taper_hours' = '24', 'S7: back to auto ' || r::text;
  ASSERT (r->'tiers'->0->>'reserve')::int = 4 AND (r->'tiers'->0->'shares'->>'stubhub') IS NOT NULL, 'S7: preview ' || r::text;
  -- Applied at once: still inside 24 h, so one pack (4) on Exos.
  ASSERT pg_temp.free() = 4, 'S7: applied on switch, free ' || pg_temp.free();
  PERFORM pg_temp.act(NULL);
END $$;

-- S8. Schedule.
DO $$
DECLARE n int;
BEGIN
  ASSERT public._exos_channel_split_due(now() + interval '30 days', NULL), 'S8: never run = due';
  ASSERT NOT public._exos_channel_split_due(now() + interval '30 days', now() - interval '12 hours'), 'S8: >7d waits a day';
  ASSERT public._exos_channel_split_due(now() + interval '30 days', now() - interval '24 hours'), 'S8: >7d after a day';
  ASSERT NOT public._exos_channel_split_due(now() + interval '4 days', now() - interval '3 hours'), 'S8: 2-7d waits 6h';
  ASSERT public._exos_channel_split_due(now() + interval '4 days', now() - interval '6 hours'), 'S8: 2-7d after 6h';
  ASSERT NOT public._exos_channel_split_due(now() + interval '24 hours', now() - interval '20 minutes'), 'S8: <48h waits ~1h';
  ASSERT public._exos_channel_split_due(now() + interval '24 hours', now() - interval '1 hour'), 'S8: <48h hourly';
  -- Just applied (S7): not due; an hour later it is.
  n := public.exos_run_channel_splits();
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = pg_temp.ev() AND channel_split_at < now() - interval '1 minute'), 'S8: stamp';
  UPDATE public.exos_events SET channel_split_at = now() - interval '2 hours' WHERE id = pg_temp.ev();
  n := public.exos_run_channel_splits();
  ASSERT (SELECT channel_split_at > now() - interval '1 minute' FROM public.exos_events WHERE id = pg_temp.ev()), 'S8: due one ran';
END $$;

-- S9. Skipped events.
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_apply_channel_split('a5000000-0000-0000-0000-0000000000e2');
  ASSERT r->>'reason' = 'not-on-sale', 'S9: draft ' || r::text;
  r := public.exos_apply_channel_split('a5000000-0000-0000-0000-0000000000e3');
  ASSERT r->>'reason' = 'primary-market-only', 'S9: primary ' || r::text;
  UPDATE public.exos_events SET total_tickets = 50 WHERE id = pg_temp.ev();
  r := public.exos_apply_channel_split(pg_temp.ev());
  ASSERT r->>'reason' = 'house-cap', 'S9: tight cap ' || r::text;
  UPDATE public.exos_events SET total_tickets = 0, starts_at = now() - interval '1 hour' WHERE id = pg_temp.ev();
  r := public.exos_apply_channel_split(pg_temp.ev());
  ASSERT r->>'reason' = 'not-on-sale', 'S9: past ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings WHERE tier_id IN
          ('a5000000-0000-0000-0000-0000000000d2','a5000000-0000-0000-0000-0000000000d3')), 'S9: nothing allocated';
END $$;

-- S10. Grants.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public._exos_channel_split_plan(uuid)', 'public.exos_apply_channel_split(uuid)',
                           'public.exos_run_channel_splits(integer)', 'public._exos_channel_split_due(timestamptz,timestamptz)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'S10: authenticated may run ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'S10: anon may run ' || f;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_set_channel_split(uuid,text,integer,integer)', 'EXECUTE'), 'S10: set';
  ASSERT has_function_privilege('authenticated', 'public.exos_channel_split_preview(uuid)', 'EXECUTE'), 'S10: preview';
  ASSERT NOT has_function_privilege('anon', 'public.exos_set_channel_split(uuid,text,integer,integer)', 'EXECUTE'), 'S10: anon set';
END $$;

-- S11. Free tickets.
DO $$
DECLARE r jsonb;
BEGIN
  INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks,purchase_limits,exclusivity) VALUES
    ('a5000000-0000-0000-0000-0000000000e4','a5000000-0000-0000-0000-000000000001','Free + paid','published',now() + interval '30 days','Hall',0,0,ARRAY['stubhub','seatgeek'],'{}','{}');
  INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
    ('a5000000-0000-0000-0000-0000000000f1','a5000000-0000-0000-0000-0000000000e4','RSVP',0,100,0),
    ('a5000000-0000-0000-0000-0000000000f2','a5000000-0000-0000-0000-0000000000e4','Paid',20,100,0);
  r := public.exos_apply_channel_split('a5000000-0000-0000-0000-0000000000e4');
  ASSERT r->>'applied' = 'true', 'S11: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings
                      WHERE tier_id = 'a5000000-0000-0000-0000-0000000000f1' AND coalesce(requested_qty, 0) > 0),
         'S11: free tickets went to a marketplace';
  -- Default pack 8 (no max per order): reserve max(8, 10) = 10, 90 shared.
  ASSERT (SELECT sum(requested_qty) FROM public.exos_distribution_listings
           WHERE tier_id = 'a5000000-0000-0000-0000-0000000000f2') = 90, 'S11: paid tier shared';
  ASSERT public.exos_effective_available('a5000000-0000-0000-0000-0000000000f1') = 100, 'S11: Exos keeps all free';
  -- By hand, the organizer can still list free tickets (and the event goes manual).
  PERFORM pg_temp.act('a5000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_channel_allocation('a5000000-0000-0000-0000-0000000000e4', 'stubhub', 'a5000000-0000-0000-0000-0000000000f1', 6);
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT requested_qty FROM public.exos_distribution_listings
           WHERE tier_id = 'a5000000-0000-0000-0000-0000000000f1' AND channel = 'stubhub') > 0, 'S11: manual free listing';
  ASSERT (SELECT channel_split_mode FROM public.exos_events WHERE id = 'a5000000-0000-0000-0000-0000000000e4') = 'manual', 'S11: manual';
END $$;

\echo 'test_auto_channel_split: all passed'
ROLLBACK;
