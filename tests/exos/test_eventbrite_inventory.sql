-- ============================================================================
-- Eventbrite inventory (mig 20261014110000):
--   I1 map: owner / manager only; needs a link; the ticket type must be the
--      event's; one class per ticket type; a scanner can't
--   I2 apply: Eventbrite sales take Exos seats; target capacity = Eventbrite
--      sold + (free on Exos - one pack); a second read with nothing new
--      changes nothing (counted once)
--   I3 Exos sells: the target shrinks; inside the last pack it is sold only
--   I4 Eventbrite oversells: only the free seats are taken, the rest counted
--      as oversold; a refund comes out of oversold first, then gives seats back
--   I5 skipped: a class missing on Eventbrite, a class in an inventory tier
--   I6 a cancelled event: target = sold (Eventbrite stops selling)
--   I7 unmap keeps the count (re-mapping doesn't count twice); moving a class
--      with counted sales to another ticket type is refused
--   I8 writes switch: owner only; status shows mappings to owner / manager
--   I9 ack: a dry run records the plan only; a sent one records capacity
--   I10 grants
--   I11 refused at map: a ticket type with no capacity, or in a shared
--       capacity group (a quota counts minted tickets, not these seats)
--   I12 a target of 0 is never planned: shown as an error instead
--   I13 two classes on two ticket types split the house remainder
--   I14 a read older than the last one applied is ignored (no false refund)
--   I15 the 2-minute inventory schedule: due once, again after 100 s; a
--       cancelled event stays due until Eventbrite is set to what it sold
-- Self-contained (e6 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('e6000000-0000-0000-0000-0000000000a1','e6own@x.com',now()),
  ('e6000000-0000-0000-0000-0000000000a2','e6mgr@x.com',now()),
  ('e6000000-0000-0000-0000-0000000000a3','e6scan@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('e6000000-0000-0000-0000-000000000001','EB Inv Org','eb-inv-org','e6000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('e6000000-0000-0000-0000-000000000001','e6000000-0000-0000-0000-0000000000a1','owner'),
  ('e6000000-0000-0000-0000-000000000001','e6000000-0000-0000-0000-0000000000a2','manager'),
  ('e6000000-0000-0000-0000-000000000001','e6000000-0000-0000-0000-0000000000a3','scanner');
-- e1: 100-seat GA (pack 4) + a free RSVP type; e2: not linked.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,purchase_limits,created_by) VALUES
  ('e6000000-0000-0000-0000-0000000000e1','e6000000-0000-0000-0000-000000000001','Shared Night','eb-inv-1','published',
   now() + interval '10 days', 0, 0, '{"maxPerOrder":4}', 'e6000000-0000-0000-0000-0000000000a1'),
  ('e6000000-0000-0000-0000-0000000000e2','e6000000-0000-0000-0000-000000000001','Other','eb-inv-2','published',
   now() + interval '10 days', 0, 0, '{}', 'e6000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order) VALUES
  ('e6000000-0000-0000-0000-0000000000d1','e6000000-0000-0000-0000-0000000000e1','GA',25,100,0,1),
  ('e6000000-0000-0000-0000-0000000000d2','e6000000-0000-0000-0000-0000000000e1','RSVP',0,20,0,2),
  ('e6000000-0000-0000-0000-0000000000d5','e6000000-0000-0000-0000-0000000000e2','GA',25,100,0,1);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"e6@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('e6000000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.sold(p text) RETURNS int LANGUAGE sql AS $$ SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u(p) $$;
CREATE FUNCTION pg_temp.cls(p_sold int, p_cap int DEFAULT 50, p_rsvp_sold int DEFAULT 0) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(
    jsonb_build_object('id', '9001', 'name', 'General Admission', 'capacity', p_cap, 'quantity_sold', p_sold, 'inventory_tier_id', NULL),
    jsonb_build_object('id', '9002', 'name', 'Free RSVP', 'capacity', 10, 'quantity_sold', p_rsvp_sold))
$$;
CREATE FUNCTION pg_temp.row(p_cls text) RETURNS public.exos_eventbrite_ticket_links LANGUAGE sql AS $$
  SELECT * FROM public.exos_eventbrite_ticket_links WHERE event_id = pg_temp.u('e1') AND eb_ticket_class_id = p_cls
$$;

-- Connected and linked (as in test_eventbrite_sync).
SELECT pg_temp.act(NULL);
SELECT public.exos_eventbrite_connect('e6000000-0000-0000-0000-000000000001', pg_temp.u('a1'), 'TOKENINV00001', 'Blue Room');
SELECT public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a1'), '555', 'Shared Night on Eventbrite');

-- I1. Map.
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a3'), '9001', 'General Admission', pg_temp.u('d1'));
    RAISE EXCEPTION 'I1: a scanner mapped';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e2'), pg_temp.u('a1'), '9001', 'x', pg_temp.u('d5'));
    RAISE EXCEPTION 'I1: mapped without a link';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN
    PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9001', 'x', pg_temp.u('d5'));
    RAISE EXCEPTION 'I1: mapped another event''s ticket type';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  ASSERT public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a2'), '9001', 'General Admission', pg_temp.u('d1')) ->> 'mapped' = 'true', 'I1: manager maps GA';
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9002', 'Free RSVP', pg_temp.u('d2'));
  -- One class per ticket type: mapping 9003 to GA deactivates 9001.
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9003', 'Late', pg_temp.u('d1'));
  ASSERT NOT (pg_temp.row('9001')).active AND (pg_temp.row('9003')).active, 'I1: one class per type';
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9001', 'General Admission', pg_temp.u('d1'));
  ASSERT (pg_temp.row('9001')).active AND NOT (pg_temp.row('9003')).active, 'I1: back to 9001';
  RAISE NOTICE 'I1 ok';
END $$;

-- I2. Eventbrite sales take Exos seats; the target is the shared count.
DO $$
DECLARE r record; n int;
BEGIN
  SELECT count(*) INTO n FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(10));
  ASSERT n = 2, 'I2: one row per mapping';
  ASSERT pg_temp.sold('d1') = 10, 'I2: 10 Eventbrite sales took 10 seats';
  -- free 90 - pack 4 = 86 shared; capacity = 10 sold + 86.
  ASSERT (pg_temp.row('9001')).target_capacity = 96 AND (pg_temp.row('9001')).counted_sold = 10, 'I2: target ' || row_to_json(pg_temp.row('9001'))::text;
  -- Free tickets are shared with Eventbrite too: 20 - 4.
  ASSERT (pg_temp.row('9002')).target_capacity = 16, 'I2: free type shared';
  SELECT * INTO r FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(10)) x WHERE x.eb_ticket_class_id = '9001';
  ASSERT pg_temp.sold('d1') = 10 AND r.target_capacity = 96 AND r.eb_capacity = 50 AND NOT r.writes_enabled, 'I2: nothing new, nothing counted';
  RAISE NOTICE 'I2 ok';
END $$;

-- I3. Exos sells; the shared count shrinks to zero inside the last pack.
DO $$
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = 60 WHERE id = pg_temp.u('d1');   -- 50 sold on Exos
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(12));
  ASSERT pg_temp.sold('d1') = 62, 'I3: 2 more Eventbrite sales';
  ASSERT (pg_temp.row('9001')).target_capacity = 12 + 34, 'I3: free 38 - 4: ' || row_to_json(pg_temp.row('9001'))::text;
  UPDATE public.exos_ticket_tiers SET sold = 97 WHERE id = pg_temp.u('d1');
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(12));
  ASSERT (pg_temp.row('9001')).target_capacity = 12, 'I3: inside the last pack: Eventbrite stops at what it sold';
  RAISE NOTICE 'I3 ok';
END $$;

-- I4. Eventbrite oversells, then refunds.
DO $$
BEGIN
  -- 3 seats left; Eventbrite reports 5 new sales.
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(17));
  ASSERT pg_temp.sold('d1') = 100 AND (pg_temp.row('9001')).oversold = 2 AND (pg_temp.row('9001')).counted_sold = 17, 'I4: 3 taken, 2 oversold';
  ASSERT (pg_temp.row('9001')).target_capacity = 17, 'I4: sold out: target = sold';
  -- Three refunds on Eventbrite: two clear the oversold, one seat comes back.
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(14));
  ASSERT (pg_temp.row('9001')).oversold = 0 AND pg_temp.sold('d1') = 99 AND (pg_temp.row('9001')).counted_sold = 14, 'I4: refunds ' || row_to_json(pg_temp.row('9001'))::text;
  RAISE NOTICE 'I4 ok';
END $$;

-- I5. Skipped classes.
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'),
    jsonb_build_array(jsonb_build_object('id', '9002', 'capacity', 10, 'quantity_sold', 0))) x WHERE x.eb_ticket_class_id = '9001';
  ASSERT r.skip_reason = 'ticket class not found on Eventbrite' AND pg_temp.sold('d1') = 99, 'I5: missing class: ' || row_to_json(r)::text;
  SELECT * INTO r FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'),
    jsonb_build_array(jsonb_build_object('id', '9001', 'capacity', 10, 'quantity_sold', 40, 'inventory_tier_id', '777'))) x WHERE x.eb_ticket_class_id = '9001';
  ASSERT r.skip_reason LIKE '%inventory tier%' AND pg_temp.sold('d1') = 99 AND (pg_temp.row('9001')).counted_sold = 14, 'I5: tiered class not counted';
  RAISE NOTICE 'I5 ok';
END $$;

-- I6. A cancelled event: Eventbrite stops selling.
DO $$
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = 50 WHERE id = pg_temp.u('d1');
  UPDATE public.exos_events SET status = 'cancelled' WHERE id = pg_temp.u('e1');
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(14));
  ASSERT (pg_temp.row('9001')).target_capacity = 14, 'I6: target = sold';
  -- Back on sale for the next cases (cancelled is final otherwise, mig 20261021110000).
  PERFORM set_config('exos.uncancel_ok', pg_temp.u('e1')::text, true);
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e1');
  RAISE NOTICE 'I6 ok';
END $$;

-- I7. Unmap keeps the count; a counted class can't move to another type.
DO $$
BEGIN
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9001', NULL, NULL);
  ASSERT NOT (pg_temp.row('9001')).active AND (pg_temp.row('9001')).counted_sold = 14, 'I7: unmapped, count kept';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(20)) x WHERE x.eb_ticket_class_id = '9001'), 'I7: unmapped: not applied';
  ASSERT pg_temp.sold('d1') = 50, 'I7: no seats taken while unmapped';
  BEGIN
    PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9001', 'General Admission', pg_temp.u('d2'));
    RAISE EXCEPTION 'I7: moved counted sales to another type';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9001', 'General Admission', pg_temp.u('d1'));
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(20));
  ASSERT pg_temp.sold('d1') = 56, 'I7: re-mapped: only the 6 new sales counted';
  RAISE NOTICE 'I7 ok';
END $$;

-- I8. Writes switch and status.
DO $$
DECLARE s jsonb; ok boolean;
BEGIN
  BEGIN
    PERFORM public.exos_eventbrite_set_writes('e6000000-0000-0000-0000-000000000001', pg_temp.u('a2'), true); ok := true;
  EXCEPTION WHEN insufficient_privilege THEN ok := false; END;
  ASSERT NOT ok, 'I8: manager can''t switch writes on';
  ASSERT public.exos_eventbrite_set_writes('e6000000-0000-0000-0000-000000000001', pg_temp.u('a1'), true), 'I8: owner switches on';
  ASSERT (SELECT bool_and(x.writes_enabled) FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(20)) x), 'I8: apply reports it';
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a2');
  s := public.exos_eventbrite_inventory_status(pg_temp.u('e1'));
  ASSERT (s ->> 'writes_enabled')::boolean AND NOT (s ->> 'can_switch')::boolean AND jsonb_array_length(s -> 'mappings') = 2
     AND jsonb_array_length(s -> 'tiers') = 2, 'I8: status ' || s::text;
  PERFORM pg_temp.act('e6000000-0000-0000-0000-0000000000a3');
  BEGIN
    PERFORM public.exos_eventbrite_inventory_status(pg_temp.u('e1')); ok := true;
  EXCEPTION WHEN insufficient_privilege THEN ok := false; END;
  ASSERT NOT ok, 'I8: scanner can''t read it';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'I8 ok';
END $$;

-- I9. Ack.
DO $$
BEGIN
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e1'), '9001', '{"dry_run":true}', false, 90);
  ASSERT (pg_temp.row('9001')).plan ->> 'dry_run' = 'true' AND (pg_temp.row('9001')).pushed_capacity IS NULL, 'I9: dry run: plan only';
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e1'), '9001', '{"sent":true}', true, 90);
  ASSERT (pg_temp.row('9001')).pushed_capacity = 90 AND (pg_temp.row('9001')).eb_capacity = 90, 'I9: sent';
  PERFORM public.exos_eventbrite_inventory_ack(pg_temp.u('e1'), '9001', '{"sent":true}', true, 80, 'HTTP 400 ARGUMENTS_ERROR');
  ASSERT (pg_temp.row('9001')).pushed_capacity = 90 AND (pg_temp.row('9001')).last_error = 'HTTP 400 ARGUMENTS_ERROR', 'I9: a failed send keeps the last good one';
  RAISE NOTICE 'I9 ok';
END $$;

-- I11. Refused at map.
DO $$
DECLARE ok boolean;
BEGIN
  INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order) VALUES
    ('e6000000-0000-0000-0000-0000000000d3','e6000000-0000-0000-0000-0000000000e1','Uncapped',25,0,0,3),
    ('e6000000-0000-0000-0000-0000000000d4','e6000000-0000-0000-0000-0000000000e1','In a quota',25,50,0,4);
  INSERT INTO public.exos_quotas(id,event_id,name,size) VALUES
    ('e6000000-0000-0000-0000-0000000000f1','e6000000-0000-0000-0000-0000000000e1','Floor',60);
  INSERT INTO public.exos_quota_tiers(quota_id,tier_id) VALUES
    ('e6000000-0000-0000-0000-0000000000f1','e6000000-0000-0000-0000-0000000000d4');
  BEGIN
    PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9004', 'x', pg_temp.u('d3')); ok := true;
  EXCEPTION WHEN invalid_parameter_value THEN ok := false; END;
  ASSERT NOT ok, 'I11: uncapped refused';
  BEGIN
    PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9005', 'x', pg_temp.u('d4')); ok := true;
  EXCEPTION WHEN invalid_parameter_value THEN ok := false; END;
  ASSERT NOT ok, 'I11: quota tier refused';
  RAISE NOTICE 'I11 ok';
END $$;

-- I12. Target 0: nothing left and nothing sold on Eventbrite.
DO $$
DECLARE r record;
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = 18 WHERE id = pg_temp.u('d2');   -- RSVP: 2 free, pack 4
  SELECT * INTO r FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(20, 50, 0)) x WHERE x.eb_ticket_class_id = '9002';
  ASSERT r.target_capacity = 0 AND r.skip_reason = 'target 0' AND (pg_temp.row('9002')).last_error LIKE '%can''t set it to 0%', 'I12: ' || row_to_json(r)::text;
  UPDATE public.exos_ticket_tiers SET sold = 0 WHERE id = pg_temp.u('d2');
  RAISE NOTICE 'I12 ok';
END $$;

-- I13. A house cap is split across the classes, not offered to each.
DO $$
BEGIN
  UPDATE public.exos_events SET total_tickets = 100, tickets_sold = 50 WHERE id = pg_temp.u('e1');   -- 50 left in the house
  UPDATE public.exos_ticket_tiers SET sold = 50 WHERE id = pg_temp.u('d1');                          -- GA: 50 free
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(20, 50, 0));
  -- GA (class 9001) first: min(50 free, 50 house) - 4 = 46; RSVP: 20 free but only 50 - 46 = 4 house left, - 4 = 0.
  ASSERT (pg_temp.row('9001')).target_capacity = 20 + 46, 'I13: GA ' || row_to_json(pg_temp.row('9001'))::text;
  ASSERT (pg_temp.row('9002')).target_capacity = 0, 'I13: RSVP gets what is left of the house ' || row_to_json(pg_temp.row('9002'))::text;
  UPDATE public.exos_events SET total_tickets = 0 WHERE id = pg_temp.u('e1');
  RAISE NOTICE 'I13 ok';
END $$;

-- I14. A stale read is ignored.
DO $$
DECLARE r record; v_sold int;
BEGIN
  PERFORM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(22));
  v_sold := pg_temp.sold('d1');
  SELECT * INTO r FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), pg_temp.cls(20), now() - interval '1 hour') x WHERE x.eb_ticket_class_id = '9001';
  ASSERT r.skip_reason = 'stale' AND pg_temp.sold('d1') = v_sold AND (pg_temp.row('9001')).counted_sold = 22, 'I14: older read ignored';
  RAISE NOTICE 'I14 ok';
END $$;

-- I15. The inventory schedule.
DO $$
DECLARE n int;
BEGIN
  UPDATE public.exos_eventbrite_links SET inventory_at = NULL WHERE event_id = pg_temp.u('e1');
  SELECT count(*) INTO n FROM public.exos_eventbrite_inventory_due() d WHERE d.event_id = pg_temp.u('e1') AND d.token = 'TOKENINV00001';
  ASSERT n = 1, 'I15: due with its token';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_inventory_due() d WHERE d.event_id = pg_temp.u('e1')), 'I15: not again within 100 s';
  UPDATE public.exos_eventbrite_links SET inventory_at = now() - interval '5 minutes' WHERE event_id = pg_temp.u('e1');
  UPDATE public.exos_events SET status = 'cancelled' WHERE id = pg_temp.u('e1');
  UPDATE public.exos_eventbrite_ticket_links SET eb_capacity = eb_sold WHERE event_id = pg_temp.u('e1');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_inventory_due() d WHERE d.event_id = pg_temp.u('e1')), 'I15: cancelled and closed on Eventbrite: done';
  UPDATE public.exos_eventbrite_ticket_links SET eb_capacity = eb_sold + 10 WHERE event_id = pg_temp.u('e1') AND eb_ticket_class_id = '9001';
  ASSERT EXISTS (SELECT 1 FROM public.exos_eventbrite_inventory_due() d WHERE d.event_id = pg_temp.u('e1')), 'I15: cancelled, still selling: due';
  PERFORM set_config('exos.uncancel_ok', pg_temp.u('e1')::text, true);
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e1');
  RAISE NOTICE 'I15 ok';
END $$;

-- I10. Grants.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_eventbrite_map_ticket(uuid,uuid,text,text,uuid)', 'public.exos_eventbrite_set_writes(uuid,uuid,boolean)',
                           'public.exos_eventbrite_inventory_apply(uuid,jsonb,timestamptz)', 'public.exos_eventbrite_inventory_ack(uuid,text,jsonb,boolean,integer,text)', 'public.exos_eventbrite_inventory_due(integer)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'I10: ' || f;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_eventbrite_inventory_status(uuid)', 'EXECUTE'), 'I10: status';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_eventbrite_ticket_links', 'SELECT'), 'I10: table hidden';
  RAISE NOTICE 'I10 ok';
END $$;

\echo 'test_eventbrite_inventory: all passed'
ROLLBACK;
