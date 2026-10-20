-- ============================================================================
-- Channels: one count across Exos, Eventbrite and Luma; the auto split
-- (mig 20261020110000).
--   S1 end of a sale (50 GA left, Eventbrite primary): Eventbrite + Luma
--      split what Exos has free, a pack each held back; outside <= free - 2
--      packs (was 42 + 34 on top of Exos's 42)
--   S2 both sell everything they were given in one window: nothing oversold
--   S3 the other platform's promise (its capacity left) comes off first
--   S4 T-40h auto split with no marketplace live (all dry run): nobody gets
--      seats, Eventbrite keeps selling from the shared count, nothing oversold
--   S5 with StubHub + SeatGeek live: the mirrors count in the split; the
--      marketplaces never grow into seats the mirrors are still promised;
--      after the mirrors shrink to their share, the marketplaces grow; one
--      total never above what is unsold
--   S6 a 0 target on a class Exos created: hidden (not an error), shown again
--      at 1+; a class Exos didn't create still says to hide it there
--   S7 exos_channel_mark: classes of a created event are Exos's; on a linked
--      event only the ones its sync added
-- Self-contained (cb prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('cb000000-0000-0000-0000-0000000000a1','cbown@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('cb000000-0000-0000-0000-000000000001','Sold Everywhere','cb-sold-everywhere','cb000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('cb000000-0000-0000-0000-000000000001','cb000000-0000-0000-0000-0000000000a1','owner');
-- e1: the end of a sale. e2: the auto split, 40 hours out. e3: a small one
-- (a 0 target). e4: a linked Eventbrite event.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,purchase_limits,created_by,venue_name) VALUES
  ('cb000000-0000-0000-0000-0000000000e1','cb000000-0000-0000-0000-000000000001','Everywhere Show','cb-everywhere','published',
   now() + interval '10 days','America/New_York',400,0,'{"maxPerOrder":8}','cb000000-0000-0000-0000-0000000000a1','Blue Room'),
  ('cb000000-0000-0000-0000-0000000000e2','cb000000-0000-0000-0000-000000000001','Split Show','cb-split','published',
   now() + interval '40 hours','America/New_York',400,0,'{"maxPerOrder":8}','cb000000-0000-0000-0000-0000000000a1','Blue Room'),
  ('cb000000-0000-0000-0000-0000000000e3','cb000000-0000-0000-0000-000000000001','Small Show','cb-small','published',
   now() + interval '10 days','America/New_York',0,0,'{"maxPerOrder":8}','cb000000-0000-0000-0000-0000000000a1','Blue Room'),
  ('cb000000-0000-0000-0000-0000000000e4','cb000000-0000-0000-0000-000000000001','Linked Show','cb-linked','published',
   now() + interval '10 days','America/New_York',0,0,'{"maxPerOrder":8}','cb000000-0000-0000-0000-0000000000a1','Blue Room');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order) VALUES
  ('cb000000-0000-0000-0000-0000000000d1','cb000000-0000-0000-0000-0000000000e1','GA',30,300,0,1),
  ('cb000000-0000-0000-0000-0000000000d2','cb000000-0000-0000-0000-0000000000e1','VIP',80,100,0,2),
  ('cb000000-0000-0000-0000-0000000000d3','cb000000-0000-0000-0000-0000000000e2','GA',30,300,0,1),
  ('cb000000-0000-0000-0000-0000000000d4','cb000000-0000-0000-0000-0000000000e2','VIP',80,100,0,2),
  ('cb000000-0000-0000-0000-0000000000d5','cb000000-0000-0000-0000-0000000000e3','GA',30,20,0,1),
  ('cb000000-0000-0000-0000-0000000000d6','cb000000-0000-0000-0000-0000000000e4','GA',30,20,0,1),
  ('cb000000-0000-0000-0000-0000000000d7','cb000000-0000-0000-0000-0000000000e4','VIP',80,20,0,2);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('cb000000-0000-0000-0000-0000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
-- One sync pass of a mirror, marked with p_result.
CREATE FUNCTION pg_temp.pass(p_ev text, p_provider text, p_result jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c record;
BEGIN
  UPDATE public.exos_channel_mirrors SET lease_id = NULL, lease_until = NULL, next_try_at = now() WHERE event_id = pg_temp.u(p_ev);
  SELECT * INTO c FROM public.exos_channel_claim(10, pg_temp.u(p_ev)) x WHERE x.provider = p_provider;
  IF c.lease_id IS NULL THEN RETURN '{"claimed":false}'; END IF;
  RETURN public.exos_channel_mark(pg_temp.u(p_ev), p_provider, c.lease_id, c.change_seq, p_result);
END $$;
CREATE FUNCTION pg_temp.tickets(VARIADIC p text[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('tier_id', pg_temp.u(p[i]), 'external_ticket_id', p[i + 1], 'name', p[i]))
    FROM generate_series(1, array_length(p, 1), 2) i
$$;
-- Eventbrite / Luma inventory passes; the target of one ticket type.
CREATE FUNCTION pg_temp.eb(p_ev text, p_classes jsonb, p_tier text) RETURNS integer LANGUAGE sql AS $$
  SELECT x.target_capacity FROM public.exos_eventbrite_inventory_apply(pg_temp.u(p_ev), p_classes, clock_timestamp()) x
   WHERE x.tier_id = pg_temp.u(p_tier)
$$;
CREATE FUNCTION pg_temp.luma(p_ev text, p_counts jsonb, p_tier text) RETURNS integer LANGUAGE sql AS $$
  SELECT x.target_capacity FROM public.exos_luma_inventory_apply(pg_temp.u(p_ev), p_counts, clock_timestamp()) x
   WHERE x.tier_id = pg_temp.u(p_tier)
$$;
-- What both platforms have on sale for a ticket type.
CREATE FUNCTION pg_temp.outside(p_ev text, p_tier text) RETURNS integer LANGUAGE sql AS $$
  SELECT public._exos_outside_out(pg_temp.u(p_ev), 'eventbrite', pg_temp.u(p_tier))
       + public._exos_outside_out(pg_temp.u(p_ev), 'luma', pg_temp.u(p_tier))
$$;
CREATE FUNCTION pg_temp.raw(p_tier text) RETURNS integer LANGUAGE sql AS $$ SELECT public._exos_tier_free_raw(pg_temp.u(p_tier)) $$;
CREATE FUNCTION pg_temp.held(p_tier text, p_ch text) RETURNS integer LANGUAGE sql AS $$
  SELECT coalesce((SELECT requested_qty FROM public.exos_distribution_listings
                    WHERE tier_id = pg_temp.u(p_tier) AND channel = p_ch), 0)
$$;
CREATE FUNCTION pg_temp.over(p_ev text) RETURNS integer LANGUAGE sql AS $$
  SELECT coalesce((SELECT sum(oversold) FROM public.exos_eventbrite_ticket_links WHERE event_id = pg_temp.u(p_ev)), 0)
       + coalesce((SELECT sum(oversold) FROM public.exos_luma_ticket_links WHERE event_id = pg_temp.u(p_ev)), 0)
$$;

-- Connected; e1-e3 mirrored on both (created there), e4 on Eventbrite (linked).
SELECT pg_temp.act(NULL);
SELECT public.exos_eventbrite_connect('cb000000-0000-0000-0000-000000000001', pg_temp.u('a1'), 'TOKENCB000001', 'Blue Room');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('cb000000-0000-0000-0000-0000000000a1');
SELECT public.exos_save_integration('cb000000-0000-0000-0000-000000000001', 'luma', '{}', 'secret-luma-key-cb');
SELECT public.exos_channel_set(pg_temp.u('e1'), 'eventbrite'), public.exos_channel_set(pg_temp.u('e1'), 'luma'),
       public.exos_channel_set(pg_temp.u('e2'), 'eventbrite'), public.exos_channel_set(pg_temp.u('e2'), 'luma'),
       public.exos_channel_set(pg_temp.u('e3'), 'eventbrite'),
       public.exos_channel_set(pg_temp.u('e4'), 'eventbrite', 'link', '900000044');
RESET ROLE;
SELECT pg_temp.pass('e1', 'eventbrite', jsonb_build_object('state','synced','external_id','900000041','hash','h','tickets', pg_temp.tickets('d1','6101','d2','6102')));
SELECT pg_temp.pass('e1', 'luma', jsonb_build_object('state','synced','external_id','evt-CBLuma01','hash','h','tickets', pg_temp.tickets('d1','lt-GA1','d2','lt-VIP1')));
SELECT pg_temp.pass('e2', 'eventbrite', jsonb_build_object('state','synced','external_id','900000042','hash','h','tickets', pg_temp.tickets('d3','6201','d4','6202')));
SELECT pg_temp.pass('e2', 'luma', jsonb_build_object('state','synced','external_id','evt-CBLuma02','hash','h','tickets', pg_temp.tickets('d3','lt-GA2','d4','lt-VIP2')));
SELECT pg_temp.pass('e3', 'eventbrite', jsonb_build_object('state','synced','external_id','900000043','hash','h','tickets', pg_temp.tickets('d5','6301')));
SELECT pg_temp.pass('e4', 'eventbrite', jsonb_build_object('state','synced','external_id','900000044','hash','h',
  'tickets', jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d6'), 'external_ticket_id', '6401', 'name', 'GA', 'created', true),
                               jsonb_build_object('tier_id', pg_temp.u('d7'), 'external_ticket_id', '6402', 'name', 'VIP'))));
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('cb000000-0000-0000-0000-0000000000a1');
SELECT public.exos_set_resale_options(pg_temp.u('e1'), 8, 'eventbrite');
RESET ROLE;

-- S1 -----------------------------------------------------------------------
DO $$
DECLARE v_eb int; v_lu int;
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = 250 WHERE id = pg_temp.u('d1');
  UPDATE public.exos_ticket_tiers SET sold = 80 WHERE id = pg_temp.u('d2');
  UPDATE public.exos_events SET tickets_sold = 330 WHERE id = pg_temp.u('e1');
  ASSERT pg_temp.raw('d1') = 50 AND public.exos_effective_available(pg_temp.u('d1')) = 42, 'S1: 50 left, 8 held for Eventbrite';
  ASSERT public._exos_outside_platforms(pg_temp.u('d1')) = 2, 'S1: two platforms sell GA';
  v_eb := pg_temp.eb('e1', '[{"id":"6101","quantity_sold":0,"capacity":10},{"id":"6102","quantity_sold":0,"capacity":10}]', 'd1');
  v_lu := pg_temp.luma('e1', '[{"id":"lt-GA1","sold":0},{"id":"lt-VIP1","sold":0}]', 'd1');
  -- 42 free less 2 packs = 26, 13 each; Eventbrite (primary) + the 8 held.
  ASSERT v_eb = 21 AND v_lu = 13, 'S1: targets ' || v_eb || ' / ' || v_lu;
  ASSERT pg_temp.outside('e1', 'd1') <= pg_temp.raw('d1') - 2 * 8, 'S1: outside ' || pg_temp.outside('e1', 'd1');
  -- VIP: 20 left, 8 held: only the hold (12 free is less than 2 packs).
  ASSERT (SELECT target_capacity FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d2') AND active) = 8, 'S1: VIP Eventbrite';
  ASSERT (SELECT target_capacity FROM public.exos_luma_ticket_links WHERE tier_id = pg_temp.u('d2') AND active) = 0, 'S1: VIP Luma';
END $$;

-- S2 -----------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.eb('e1', '[{"id":"6101","quantity_sold":21,"capacity":21},{"id":"6102","quantity_sold":8,"capacity":8}]', 'd1');
  PERFORM pg_temp.luma('e1', '[{"id":"lt-GA1","sold":13},{"id":"lt-VIP1","sold":0}]', 'd1');
  ASSERT pg_temp.over('e1') = 0, 'S2: oversold ' || pg_temp.over('e1');
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 284, 'S2: GA sold';
  ASSERT pg_temp.raw('d1') = 16, 'S2: two packs left for Exos';
  ASSERT (SELECT sold <= capacity FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d2')), 'S2: VIP';
END $$;

-- S3 -----------------------------------------------------------------------
DO $$
DECLARE v int;
BEGIN
  -- 40 refunded on Exos: 56 left, 8 held, 48 free. Eventbrite still reports
  -- a capacity of 60 (a higher target not lowered there yet): 39 on sale, 8
  -- of them the hold, 31 off Exos's count.
  UPDATE public.exos_ticket_tiers SET sold = sold - 40 WHERE id = pg_temp.u('d1');
  UPDATE public.exos_events SET tickets_sold = tickets_sold - 40 WHERE id = pg_temp.u('e1');
  UPDATE public.exos_eventbrite_ticket_links SET eb_capacity = 60 WHERE tier_id = pg_temp.u('d1') AND active;
  ASSERT public._exos_outside_out(pg_temp.u('e1'), 'eventbrite', pg_temp.u('d1')) = 39, 'S3: Eventbrite promised';
  v := pg_temp.luma('e1', '[{"id":"lt-GA1","sold":13},{"id":"lt-VIP1","sold":0}]', 'd1');
  -- 48 - 2 packs = 32 to share; 31 are Eventbrite's: Luma gets 1, not 16.
  ASSERT v = 13 + 1, 'S3: Luma target ' || v;
END $$;

-- S4 -----------------------------------------------------------------------
DO $$
DECLARE r jsonb; v int; v_lu int;
BEGIN
  DELETE FROM public.exos_platform_settings WHERE key = 'marketplace_live_channels';   -- every marketplace dry run
  ASSERT NOT public.exos_marketplace_live('stubhub'), 'S4: nothing live by default';
  UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub','seatgeek','gametime','gotickets'], channel_split_mode = 'auto'
   WHERE id = pg_temp.u('e2');
  v := pg_temp.eb('e2', '[{"id":"6201","quantity_sold":0,"capacity":292},{"id":"6202","quantity_sold":0,"capacity":92}]', 'd3');
  ASSERT v = 142, 'S4: Eventbrite GA ' || v;     -- 300 - 2 packs, halved
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e2'), '6201', '{}', true, 142);
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e2'), '6202', '{}', true, 42);
  v_lu := pg_temp.luma('e2', '[{"id":"lt-GA2","sold":0},{"id":"lt-VIP2","sold":0}]', 'd3');
  ASSERT v_lu = 142, 'S4: Luma GA ' || v_lu;
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e2')) WHERE share > 0), 'S4: no marketplace share';
  r := public.exos_apply_channel_split(pg_temp.u('e2'));
  ASSERT r ->> 'applied' = 'true', 'S4: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e2') AND tier_id IS NOT NULL AND requested_qty > 0),
    'S4: no seats to dry-run marketplaces';
  ASSERT pg_temp.raw('d3') = 300, 'S4: Exos keeps them';
  -- Eventbrite sells 50 of its 142: counted, nothing oversold, its target
  -- still on the shared count.
  v := pg_temp.eb('e2', '[{"id":"6201","quantity_sold":50,"capacity":142},{"id":"6202","quantity_sold":0,"capacity":42}]', 'd3');
  ASSERT pg_temp.over('e2') = 0, 'S4: oversold';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d3')) = 50, 'S4: counted';
  ASSERT v - 50 + 142 <= 250 - 16, 'S4: outside ' || v;
END $$;

-- S5 -----------------------------------------------------------------------
DO $$
DECLARE r record; v int;
BEGIN
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('marketplace_live_channels', '["stubhub","seatgeek"]')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e2'), '6201', '{}', true, 142);
  -- GA: 250 unsold; one pack + a pack per mirror = 24 kept; 226 over 4 = 56
  -- (+1 to StubHub and SeatGeek); the mirrors' rows say 56.
  FOR r IN SELECT * FROM public._exos_channel_split_plan_x(pg_temp.u('e2')) x WHERE x.tier_id = pg_temp.u('d3') LOOP
    ASSERT r.share = CASE r.channel WHEN 'stubhub' THEN 57 WHEN 'seatgeek' THEN 57 WHEN 'eventbrite' THEN 56 WHEN 'luma' THEN 56 ELSE 0 END,
      'S5: plan ' || row_to_json(r)::text;
  END LOOP;
  ASSERT (SELECT count(*) FROM public._exos_channel_split_plan(pg_temp.u('e2')) WHERE tier_id = pg_temp.u('d3')) = 4, 'S5: marketplace rows only';
  -- The mirrors are still promised 92 + 142: the marketplaces can't grow yet.
  PERFORM public.exos_apply_channel_split(pg_temp.u('e2'));
  ASSERT pg_temp.held('d3', 'stubhub') = 0 AND pg_temp.held('d3', 'seatgeek') = 0, 'S5: grew into the mirrors '
    || pg_temp.held('d3', 'stubhub') || '/' || pg_temp.held('d3', 'seatgeek');
  ASSERT pg_temp.held('d3', 'gametime') = 0 AND pg_temp.held('d3', 'gotickets') = 0, 'S5: dry-run marketplaces';
  -- The mirrors' next passes shrink them to their share (sent).
  v := pg_temp.eb('e2', '[{"id":"6201","quantity_sold":50,"capacity":142},{"id":"6202","quantity_sold":0,"capacity":42}]', 'd3');
  ASSERT v = 50 + 56, 'S5: Eventbrite GA ' || v;
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e2'), '6201', '{}', true, v);
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e2'), '6202', '{}', true,
    (SELECT target_capacity FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d4') AND active));
  v := pg_temp.luma('e2', '[{"id":"lt-GA2","sold":0},{"id":"lt-VIP2","sold":0}]', 'd3');
  ASSERT v = 56, 'S5: Luma GA ' || v;
  PERFORM public.exos_luma_inventory_ack(pg_temp.u('e2'), 'lt-GA2', '{}', true, v);
  PERFORM public.exos_luma_inventory_ack(pg_temp.u('e2'), 'lt-VIP2', '{}', true,
    (SELECT target_capacity FROM public.exos_luma_ticket_links WHERE tier_id = pg_temp.u('d4') AND active));
  -- Now the marketplaces grow.
  PERFORM public.exos_apply_channel_split(pg_temp.u('e2'));
  ASSERT pg_temp.held('d3', 'stubhub') = 57 AND pg_temp.held('d3', 'seatgeek') = 57, 'S5: grew '
    || pg_temp.held('d3', 'stubhub') || '/' || pg_temp.held('d3', 'seatgeek');
  ASSERT pg_temp.held('d4', 'stubhub') = 19 AND pg_temp.held('d4', 'seatgeek') = 19, 'S5: VIP '
    || pg_temp.held('d4', 'stubhub') || '/' || pg_temp.held('d4', 'seatgeek');
  -- One total: marketplaces + mirrors + the mirrors' packs never above unsold.
  FOR r IN SELECT t.id, t.capacity - t.sold AS unsold FROM public.exos_ticket_tiers t WHERE t.event_id = pg_temp.u('e2') LOOP
    ASSERT (SELECT coalesce(sum(requested_qty), 0) FROM public.exos_distribution_listings WHERE tier_id = r.id)
           + public._exos_outside_out(pg_temp.u('e2'), 'eventbrite', r.id) + public._exos_outside_out(pg_temp.u('e2'), 'luma', r.id)
           + 2 * 8 <= r.unsold, 'S5: over the count on ' || r.id;
  END LOOP;
  -- And the mirrors' next passes stay at their share.
  ASSERT pg_temp.eb('e2', '[{"id":"6201","quantity_sold":50,"capacity":106},{"id":"6202","quantity_sold":0,"capacity":19}]', 'd3') = 106, 'S5: stable (Eventbrite)';
  ASSERT pg_temp.luma('e2', '[{"id":"lt-GA2","sold":0},{"id":"lt-VIP2","sold":0}]', 'd3') = 56, 'S5: stable (Luma)';
END $$;

-- S6 -----------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  -- 20 GA, Exos sold 15: 5 free is less than a pack, Eventbrite's target is 0.
  UPDATE public.exos_ticket_tiers SET sold = 15 WHERE id = pg_temp.u('d5');
  ASSERT (SELECT exos_created FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d5') AND active), 'S6: created by Exos';
  SELECT * INTO r FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e3'), '[{"id":"6301","quantity_sold":0,"capacity":12}]', clock_timestamp());
  ASSERT r.target_capacity = 0 AND r.skip_reason IS NULL, 'S6: 0 is planned ' || row_to_json(r)::text;
  ASSERT (SELECT last_error IS NULL FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d5') AND active), 'S6: no error';
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e3'), '6301', '{"body":{"ticket_class":{"hidden":true}}}', true, 0);
  ASSERT (SELECT hidden_by_count FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d5') AND active), 'S6: hidden';
  -- Hidden: it sells nothing, even with the capacity it reports.
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e3'), '[{"id":"6301","quantity_sold":0,"capacity":12}]', clock_timestamp());
  ASSERT public._exos_outside_out(pg_temp.u('e3'), 'eventbrite', pg_temp.u('d5')) = 0, 'S6: hidden sells nothing';
  -- Seats back: a capacity again, shown.
  UPDATE public.exos_ticket_tiers SET sold = 0 WHERE id = pg_temp.u('d5');
  SELECT * INTO r FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e3'), '[{"id":"6301","quantity_sold":0,"capacity":12}]', clock_timestamp());
  ASSERT r.target_capacity = 12, 'S6: back ' || r.target_capacity;
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e3'), '6301', '{}', true, 12);
  ASSERT NOT (SELECT hidden_by_count FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d5') AND active), 'S6: shown';
  -- A class Exos didn't create: still refused at 0.
  UPDATE public.exos_ticket_tiers SET sold = 15 WHERE id = pg_temp.u('d5');
  UPDATE public.exos_eventbrite_ticket_links SET exos_created = false WHERE tier_id = pg_temp.u('d5');
  SELECT * INTO r FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e3'), '[{"id":"6301","quantity_sold":0,"capacity":12}]', clock_timestamp());
  ASSERT r.target_capacity = 0 AND r.skip_reason = 'target 0', 'S6: not ours ' || row_to_json(r)::text;
  ASSERT (SELECT last_error LIKE '%hide or end%' FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d5') AND active), 'S6: says so';
END $$;

-- S7 -----------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT exos_created FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d1') AND active), 'S7: created event';
  ASSERT (SELECT exos_created FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d6') AND active), 'S7: added by the sync';
  ASSERT NOT (SELECT exos_created FROM public.exos_eventbrite_ticket_links WHERE tier_id = pg_temp.u('d7') AND active), 'S7: the organizer''s';
END $$;

\echo 'test_channel_shared_count: all passed'
ROLLBACK;
