-- ============================================================================
-- Channels (mig 20261019090000): an Exos event mirrored on Eventbrite + Luma.
--   C1 set: owner / manager only; needs the platform connected; a linked id
--      must look right; a scanner can't; the same external event can't be
--      linked twice
--   C2 a change to the event / a ticket type marks the mirrors; a sale alone
--      doesn't
--   C3 claim: payload with the event, ticket types, maps, credential and
--      switch; leased (not claimed twice)
--   C4 mark: refused without the lease; synced records the external id and
--      the ticket mappings where the door + inventory syncs read them
--      (Eventbrite link + class links; Luma ticket links + backend link);
--      in step only up to what the pass read
--   C5 primary: luma needs a Luma mirror; the last set of a mapped ticket
--      type is held off Exos checkout
--   C6 Luma inventory: Luma sales take Exos seats once; target = Luma sold +
--      shared (+ the hold when Luma is primary); refunds come out of oversold
--   C7 comps: only on a Luma-primary event and a ticket type on Luma; a dry
--      run leaves them queued; added once sent
--   C8 remove: refused while that platform is the primary
--   C9 status + connections: owner / manager / finance; never a credential
--   C10 the Luma write switch: owner only
--   C11 errors back off; a dry run waits for the next change
-- Self-contained (c7 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c7000000-0000-0000-0000-0000000000a1','c7own@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000a2','c7mgr@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000a3','c7scan@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000a4','c7fin@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c7000000-0000-0000-0000-000000000001','Channel Org','channel-org','c7000000-0000-0000-0000-0000000000a1'),
  ('c7000000-0000-0000-0000-000000000002','Bare Org','bare-org','c7000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a1','owner'),
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a2','manager'),
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a3','scanner'),
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a4','finance'),
  ('c7000000-0000-0000-0000-000000000002','c7000000-0000-0000-0000-0000000000a1','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,purchase_limits,created_by) VALUES
  ('c7000000-0000-0000-0000-0000000000e1','c7000000-0000-0000-0000-000000000001','Mirror Night','mirror-night','published',
   now() + interval '10 days','America/New_York',0,0,'{"maxPerOrder":4}','c7000000-0000-0000-0000-0000000000a1'),
  ('c7000000-0000-0000-0000-0000000000e2','c7000000-0000-0000-0000-000000000002','Bare Night','bare-night','published',
   now() + interval '10 days','America/New_York',0,0,'{}','c7000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order) VALUES
  ('c7000000-0000-0000-0000-0000000000d1','c7000000-0000-0000-0000-0000000000e1','GA',25,100,0,1),
  ('c7000000-0000-0000-0000-0000000000d2','c7000000-0000-0000-0000-0000000000e1','VIP',80,20,0,2);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('c7000000-0000-0000-0000-0000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated;
CREATE FUNCTION pg_temp.mirror(p text) RETURNS public.exos_channel_mirrors LANGUAGE sql AS $$
  SELECT * FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e1') AND provider = p
$$;

-- Connected: Eventbrite (door app) and Luma (Integrations).
SELECT pg_temp.act(NULL);
SELECT public.exos_eventbrite_connect('c7000000-0000-0000-0000-000000000001', pg_temp.u('a1'), 'TOKENCHAN0001', 'Blue Room');

-- C1 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a1');
SELECT public.exos_save_integration('c7000000-0000-0000-0000-000000000001', 'luma', '{}', 'secret-luma-key-c7');
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a3');
SELECT set_config('c7.scan', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e1'), 'luma')$$, 'owner or manager only')::text, true);
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a1');
SELECT set_config('c7.bare', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e2'), 'luma')$$, 'connect Luma')::text, true);
SELECT set_config('c7.bare_eb', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e2'), 'eventbrite')$$, 'connect Eventbrite')::text, true);
SELECT set_config('c7.badid', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e1'), 'luma', 'link', '12345')$$, 'look right')::text, true);
SELECT set_config('c7.badprov', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e1'), 'dice')$$, 'eventbrite or luma')::text, true);
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a2');
SELECT public.exos_channel_set(pg_temp.u('e1'), 'luma');
SELECT public.exos_channel_set(pg_temp.u('e1'), 'eventbrite');
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('c7.scan')::boolean AND current_setting('c7.bare')::boolean AND current_setting('c7.bare_eb')::boolean
     AND current_setting('c7.badid')::boolean AND current_setting('c7.badprov')::boolean, 'C1: refusals';
  ASSERT (pg_temp.mirror('luma')).mode = 'create' AND (pg_temp.mirror('luma')).status = 'pending', 'C1: luma pending';
  ASSERT (pg_temp.mirror('eventbrite')).external_id IS NULL, 'C1: eventbrite to create';
END $$;

-- C2 ----------------------------------------------------------------------
DO $$
DECLARE v_seq bigint := (pg_temp.mirror('luma')).change_seq;
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = sold + 1 WHERE id = pg_temp.u('d1');
  UPDATE public.exos_events SET tickets_sold = tickets_sold + 1 WHERE id = pg_temp.u('e1');
  ASSERT (pg_temp.mirror('luma')).change_seq = v_seq, 'C2: a sale alone is not a change';
  UPDATE public.exos_ticket_tiers SET sold = sold - 1 WHERE id = pg_temp.u('d1');
  UPDATE public.exos_events SET tickets_sold = tickets_sold - 1 WHERE id = pg_temp.u('e1');
  UPDATE public.exos_events SET name = 'Mirror Night II' WHERE id = pg_temp.u('e1');
  ASSERT (pg_temp.mirror('luma')).change_seq = v_seq + 1 AND (pg_temp.mirror('eventbrite')).change_seq > 1, 'C2: rename marks both';
  UPDATE public.exos_ticket_tiers SET price = 30 WHERE id = pg_temp.u('d1');
  ASSERT (pg_temp.mirror('luma')).change_seq = v_seq + 2, 'C2: a price change marks';
END $$;

-- C3 / C4 -------------------------------------------------------------------
DO $$
DECLARE c record; j jsonb; n int;
BEGIN
  SELECT * INTO c FROM public.exos_channel_claim(10, NULL) x WHERE x.event_id = pg_temp.u('e1') AND x.provider = 'luma';
  ASSERT c.lease_id IS NOT NULL, 'C3: claimed';
  ASSERT c.payload ->> 'secret' = 'secret-luma-key-c7' AND (c.payload ->> 'writes_enabled')::boolean = false, 'C3: credential + switch';
  ASSERT c.payload -> 'event' ->> 'name' = 'Mirror Night II' AND jsonb_array_length(c.payload -> 'tiers') = 2, 'C3: event + tiers';
  ASSERT (c.payload -> 'tiers' -> 0 ->> 'free_now')::int = 100, 'C3: free seats';
  SELECT count(*) INTO n FROM public.exos_channel_claim(10, NULL) x WHERE x.event_id = pg_temp.u('e1') AND x.provider = 'luma';
  ASSERT n = 0, 'C3: leased, not claimed twice';
  -- (Those claims leased the Eventbrite mirror too; let it go for C4's second pass.)
  UPDATE public.exos_channel_mirrors SET lease_id = NULL, lease_until = NULL WHERE event_id = pg_temp.u('e1') AND provider = 'eventbrite';

  j := public.exos_channel_mark(pg_temp.u('e1'), 'luma', gen_random_uuid(), c.change_seq, '{"state":"synced"}');
  ASSERT j ->> 'reason' = 'lease-lost', 'C4: needs the lease';
  -- An edit lands while the pass runs.
  UPDATE public.exos_events SET name = 'Mirror Night III' WHERE id = pg_temp.u('e1');
  j := public.exos_channel_mark(pg_temp.u('e1'), 'luma', c.lease_id, c.change_seq, jsonb_build_object(
         'state', 'synced', 'external_id', 'evt-LumaMirror1', 'external_url', 'https://luma.com/mirror-night', 'hash', 'h1',
         'tickets', jsonb_build_array(
           jsonb_build_object('tier_id', pg_temp.u('d1'), 'external_ticket_id', 'ttype-GA1', 'name', 'GA'),
           jsonb_build_object('tier_id', pg_temp.u('d2'), 'external_ticket_id', 'ttype-VIP1', 'name', 'VIP'),
           jsonb_build_object('tier_id', gen_random_uuid(), 'external_ticket_id', 'ttype-X'))));
  ASSERT (j ->> 'tickets_mapped')::int = 2, 'C4: two mapped, the foreign tier ignored ' || j::text;
  ASSERT (pg_temp.mirror('luma')).external_id = 'evt-LumaMirror1' AND (pg_temp.mirror('luma')).status = 'synced', 'C4: recorded';
  ASSERT (pg_temp.mirror('luma')).synced_seq < (pg_temp.mirror('luma')).change_seq, 'C4: the edit during the pass is still pending';
  ASSERT (SELECT provider || ' ' || external_ref FROM public.exos_backend_links WHERE event_id = pg_temp.u('e1')) = 'luma evt-LumaMirror1',
         'C4: door sync link';
  ASSERT (SELECT name FROM public.exos_guest_lists l JOIN public.exos_backend_links b ON b.list_id = l.id WHERE b.event_id = pg_temp.u('e1')) = 'Luma',
         'C4: Luma guest list';
  ASSERT (SELECT count(*) FROM public.exos_luma_ticket_links WHERE event_id = pg_temp.u('e1') AND active) = 2, 'C4: Luma ticket links';
  ASSERT (pg_temp.mirror('luma')).lease_id IS NULL, 'C4: lease released';

  SELECT * INTO c FROM public.exos_channel_claim(10, NULL) x WHERE x.event_id = pg_temp.u('e1') AND x.provider = 'eventbrite';
  ASSERT c.payload ->> 'secret' = 'TOKENCHAN0001', 'C3: Eventbrite token';
  j := public.exos_channel_mark(pg_temp.u('e1'), 'eventbrite', c.lease_id, c.change_seq, jsonb_build_object(
         'state', 'synced', 'external_id', '777000111', 'external_url', 'https://www.eventbrite.com/e/777000111',
         'external_meta', jsonb_build_object('organization_id', '42', 'venue_id', '99'),
         'tickets', jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d1'), 'external_ticket_id', '5001', 'name', 'GA'))));
  ASSERT (SELECT eb_event_id FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')) = '777000111', 'C4: Eventbrite link';
  ASSERT (SELECT tier_id FROM public.exos_eventbrite_ticket_links WHERE event_id = pg_temp.u('e1') AND eb_ticket_class_id = '5001' AND active) = pg_temp.u('d1'),
         'C4: Eventbrite class mapped';
  ASSERT (pg_temp.mirror('eventbrite')).external_meta ->> 'venue_id' = '99', 'C4: meta kept';
END $$;

-- C5 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a1');
SELECT set_config('c7.p_bad', pg_temp.refused($$SELECT public.exos_set_resale_options(pg_temp.u('e1'), NULL, 'dice')$$, 'exos, eventbrite or luma')::text, true);
SELECT public.exos_set_resale_options(pg_temp.u('e1'), 8, 'luma');
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('c7.p_bad')::boolean, 'C5: bad source refused';
  ASSERT (SELECT primary_source FROM public.exos_events WHERE id = pg_temp.u('e1')) = 'luma', 'C5: luma primary';
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 92, 'C5: the last set (8) is Luma''s: ' || public.exos_tier_available(pg_temp.u('d1'));
END $$;

-- C6 ----------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  -- Luma sold 5 GA, 0 VIP.
  SELECT * INTO r FROM public.exos_luma_inventory_apply(pg_temp.u('e1'),
    '[{"id":"ttype-GA1","sold":5},{"id":"ttype-VIP1","sold":0}]', now()) x WHERE x.tier_id = pg_temp.u('d1');
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 5, 'C6: Luma sales took Exos seats';
  -- 95 free raw; 8 held for Luma: shared 87 - pack 4 = 83, + hold 8 = 91; target 5 + 91.
  ASSERT r.target_capacity = 96, 'C6: target ' || r.target_capacity;
  ASSERT r.oversold = 0 AND NOT r.writes_enabled, 'C6: switch off';
  -- Same read again: nothing counted twice.
  PERFORM public.exos_luma_inventory_apply(pg_temp.u('e1'), '[{"id":"ttype-GA1","sold":5},{"id":"ttype-VIP1","sold":0}]', now() + interval '1 second');
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 5, 'C6: counted once';
  -- An older read is ignored.
  PERFORM public.exos_luma_inventory_apply(pg_temp.u('e1'), '[{"id":"ttype-GA1","sold":0}]', now() - interval '1 hour');
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 5, 'C6: stale read ignored';
  -- VIP: Luma oversells (25 against 20 seats), then refunds 7.
  PERFORM public.exos_luma_inventory_apply(pg_temp.u('e1'), '[{"id":"ttype-GA1","sold":5},{"id":"ttype-VIP1","sold":25}]', now() + interval '2 seconds');
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d2')) = 20
     AND (SELECT oversold FROM public.exos_luma_ticket_links WHERE luma_ticket_type_id = 'ttype-VIP1') = 5, 'C6: oversold';
  PERFORM public.exos_luma_inventory_apply(pg_temp.u('e1'), '[{"id":"ttype-GA1","sold":5},{"id":"ttype-VIP1","sold":18}]', now() + interval '3 seconds');
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d2')) = 18
     AND (SELECT oversold FROM public.exos_luma_ticket_links WHERE luma_ticket_type_id = 'ttype-VIP1') = 0, 'C6: refund out of oversold first';
  PERFORM public.exos_luma_inventory_ack(pg_temp.u('e1'), 'ttype-GA1', '{"dry_run":true}', false, 96);
  ASSERT (SELECT pushed_capacity FROM public.exos_luma_ticket_links WHERE luma_ticket_type_id = 'ttype-GA1') IS NULL
     AND (SELECT plan FROM public.exos_luma_ticket_links WHERE luma_ticket_type_id = 'ttype-GA1') IS NOT NULL, 'C6: dry run plan only';
  PERFORM public.exos_luma_inventory_ack(pg_temp.u('e1'), 'ttype-GA1', '{"sent":true}', true, 96);
  ASSERT (SELECT pushed_capacity FROM public.exos_luma_ticket_links WHERE luma_ticket_type_id = 'ttype-GA1') = 96, 'C6: sent';
END $$;

-- C7 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a2');
SELECT set_config('c7.q', public.exos_channel_queue_comps(pg_temp.u('e1'), pg_temp.u('d1'),
  '[{"email":"Guest@x.com","name":"Guest One"},{"email":"bad"},{"email":"guest@x.com"}]', false)::text, true);
RESET ROLE;
DO $$
DECLARE q jsonb := current_setting('c7.q')::jsonb; r record; n int;
BEGIN
  ASSERT (q ->> 'queued')::int = 1 AND (q ->> 'invalid')::int = 1 AND (q ->> 'already')::int = 1, 'C7: queued ' || q::text;
  SELECT * INTO r FROM public.exos_luma_comp_claim(pg_temp.u('e1'), 10);
  ASSERT r.email = 'guest@x.com' AND r.luma_ticket_type_id = 'ttype-GA1' AND NOT r.send_email, 'C7: claimed';
  PERFORM public.exos_luma_comp_mark(r.id, 'planned');
  ASSERT (SELECT status || ' ' || attempts FROM public.exos_luma_comp_queue WHERE id = r.id) = 'queued 0', 'C7: dry run stays queued';
  SELECT * INTO r FROM public.exos_luma_comp_claim(pg_temp.u('e1'), 10);
  PERFORM public.exos_luma_comp_mark(r.id, 'added');
  SELECT count(*) INTO n FROM public.exos_luma_comp_claim(pg_temp.u('e1'), 10);
  ASSERT n = 0 AND (SELECT status FROM public.exos_luma_comp_queue WHERE id = r.id) = 'added', 'C7: added once';
  UPDATE public.exos_events SET primary_source = 'exos' WHERE id = pg_temp.u('e1');
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a2');
SELECT set_config('c7.q_exos', pg_temp.refused($$SELECT public.exos_channel_queue_comps(pg_temp.u('e1'), pg_temp.u('d1'), '[{"email":"a@x.com"}]')$$, 'only when Luma is the primary')::text, true);

-- C8 / C9 / C10 -------------------------------------------------------------
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a1');
SELECT public.exos_set_resale_options(pg_temp.u('e1'), NULL, 'eventbrite');
SELECT set_config('c7.rm_primary', pg_temp.refused($$SELECT public.exos_channel_remove(pg_temp.u('e1'), 'eventbrite')$$, 'primary ticketing system')::text, true);
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a4');
SELECT set_config('c7.st_fin', public.exos_channel_status(pg_temp.u('e1'))::text, true);
SELECT set_config('c7.conn', public.exos_channel_connections('c7000000-0000-0000-0000-000000000001')::text, true);
SELECT set_config('c7.sw_fin', pg_temp.refused($$SELECT public.exos_integration_set_writes('c7000000-0000-0000-0000-000000000001', 'luma', true)$$, 'owner only')::text, true);
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a3');
SELECT set_config('c7.st_scan', pg_temp.refused($$SELECT public.exos_channel_status(pg_temp.u('e1'))$$, 'not authorized')::text, true);
SELECT pg_temp.act('c7000000-0000-0000-0000-0000000000a1');
SELECT set_config('c7.sw', public.exos_integration_set_writes('c7000000-0000-0000-0000-000000000001', 'luma', true)::text, true);
SELECT set_config('c7.rm', public.exos_channel_remove(pg_temp.u('e1'), 'luma')::text, true);
RESET ROLE;
DO $$
DECLARE s jsonb := current_setting('c7.st_fin')::jsonb;
BEGIN
  ASSERT current_setting('c7.q_exos')::boolean AND current_setting('c7.rm_primary')::boolean, 'C7/C8: refusals';
  ASSERT s ->> 'primary_source' = 'eventbrite' AND NOT (s ->> 'can_manage')::boolean AND jsonb_array_length(s -> 'mirrors') = 2, 'C9: finance sees ' || s::text;
  ASSERT (s -> 'connected' ->> 'luma')::boolean AND (s -> 'connected' ->> 'eventbrite')::boolean, 'C9: connected';
  ASSERT s::text NOT LIKE '%secret-luma%' AND s::text NOT LIKE '%TOKENCHAN%', 'C9: never a credential';
  ASSERT (current_setting('c7.conn')::jsonb ->> 'luma')::boolean AND NOT (current_setting('c7.conn')::jsonb ->> 'can_switch')::boolean, 'C9: connections';
  ASSERT current_setting('c7.st_scan')::boolean AND current_setting('c7.sw_fin')::boolean, 'C9/C10: refusals';
  ASSERT current_setting('c7.sw')::boolean
     AND (SELECT writes_enabled FROM public.exos_org_integrations WHERE org_id = 'c7000000-0000-0000-0000-000000000001' AND provider = 'luma'), 'C10: switch on';
  ASSERT current_setting('c7.rm')::boolean AND (pg_temp.mirror('luma')).event_id IS NULL, 'C8: Luma mirror removed';
  ASSERT (SELECT count(*) FROM public.exos_luma_ticket_links WHERE event_id = pg_temp.u('e1')) = 2, 'C8: counted sales stay';
END $$;

-- C11 ---------------------------------------------------------------------
DO $$
DECLARE c record;
BEGIN
  UPDATE public.exos_events SET name = 'Mirror Night IV' WHERE id = pg_temp.u('e1');
  SELECT * INTO c FROM public.exos_channel_claim(10, NULL) x WHERE x.event_id = pg_temp.u('e1') AND x.provider = 'eventbrite';
  PERFORM public.exos_channel_mark(pg_temp.u('e1'), 'eventbrite', c.lease_id, c.change_seq, '{"state":"error","error":"Eventbrite answered 500"}');
  ASSERT (pg_temp.mirror('eventbrite')).status = 'error' AND (pg_temp.mirror('eventbrite')).attempts = 1
     AND (pg_temp.mirror('eventbrite')).next_try_at > now(), 'C11: backoff';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_channel_claim(10, NULL) x WHERE x.event_id = pg_temp.u('e1')), 'C11: not due during backoff';
  UPDATE public.exos_channel_mirrors SET next_try_at = now() WHERE event_id = pg_temp.u('e1');
  SELECT * INTO c FROM public.exos_channel_claim(10, NULL) x WHERE x.event_id = pg_temp.u('e1') AND x.provider = 'eventbrite';
  PERFORM public.exos_channel_mark(pg_temp.u('e1'), 'eventbrite', c.lease_id, c.change_seq, '{"state":"dry_run","plan":{"steps":[{"op":"update_event"}]}}');
  ASSERT (pg_temp.mirror('eventbrite')).status = 'dry_run' AND (pg_temp.mirror('eventbrite')).plan IS NOT NULL
     AND (pg_temp.mirror('eventbrite')).synced_seq < (pg_temp.mirror('eventbrite')).change_seq, 'C11: dry run not in step';
  ASSERT (pg_temp.mirror('eventbrite')).attempts = 0, 'C11: dry run resets attempts';
END $$;

\echo 'test_channel_mirrors: all passed'
ROLLBACK;
