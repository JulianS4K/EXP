-- ============================================================================
-- Channel risks (mig 20261121100000), before Eventbrite / Luma writes go live.
--   R1 one promise across platforms: an event sold on Eventbrite AND Luma
--      never offers the same free seats twice (per ticket type and per
--      house), the shared pool is split so neither keeps the other at 0, a
--      single platform gets what it got before; both applies take the
--      event's lock before their rows
--   R2 a link to another external event: exos_channel_set refuses it up
--      front; exos_channel_mark records a conflict (the new id kept, no link
--      or mapping written, error with the reason) and the next save clears it
--   R3 duplicate creates: exos_channel_create_begin needs the lease, refuses a
--      create younger than 2 minutes, keeps the first time and the slug, and
--      mark clears it once the mirror has its id
--   R4 a Luma ack stores the steps it was given
--   R5 created classes and first capacities: mark records them, claim sends
--      created per Eventbrite mapping and share_cap per ticket type
-- Self-contained (ce1 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('ce100000-0000-0000-0000-0000000000a1','ce1own@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('ce100000-0000-0000-0000-000000000001','Risk Org','risk-org','ce100000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('ce100000-0000-0000-0000-000000000001','ce100000-0000-0000-0000-0000000000a1','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,purchase_limits,created_by) VALUES
  ('ce100000-0000-0000-0000-0000000000e1','ce100000-0000-0000-0000-000000000001','Two Primaries','two-primaries','published',
   now() + interval '10 days','America/New_York',0,0,'{"maxPerOrder":4}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000e2','ce100000-0000-0000-0000-000000000001','House Cap','house-cap','published',
   now() + interval '10 days','America/New_York',50,0,'{"maxPerOrder":4}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000e3','ce100000-0000-0000-0000-000000000001','On pretix','on-pretix','published',
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000e4','ce100000-0000-0000-0000-000000000001','Relinked','relinked','published',
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000e5','ce100000-0000-0000-0000-000000000001','Retried','retried','published',
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order) VALUES
  ('ce100000-0000-0000-0000-0000000000d1','ce100000-0000-0000-0000-0000000000e1','GA',25,100,0,1),
  ('ce100000-0000-0000-0000-0000000000d3','ce100000-0000-0000-0000-0000000000e2','GA',25,100,0,1),
  ('ce100000-0000-0000-0000-0000000000d4','ce100000-0000-0000-0000-0000000000e4','GA',25,40,0,1),
  ('ce100000-0000-0000-0000-0000000000d5','ce100000-0000-0000-0000-0000000000e5','GA',25,40,0,1);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('ce100000-0000-0000-0000-0000000000' || p)::uuid $$;
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
-- Eventbrite reads class 9001 (event e) with `cap` capacity and `sold` sold.
CREATE FUNCTION pg_temp.eb(p_event text, p_class text, p_cap int, p_sold int) RETURNS int LANGUAGE sql AS $$
  SELECT x.target_capacity FROM public.exos_eventbrite_inventory_apply(pg_temp.u(p_event), jsonb_build_array(
    jsonb_build_object('id', p_class, 'capacity', p_cap, 'quantity_sold', p_sold)), clock_timestamp()) x
$$;
CREATE FUNCTION pg_temp.luma(p_event text, p_type text, p_sold int) RETURNS int LANGUAGE sql AS $$
  SELECT x.target_capacity FROM public.exos_luma_inventory_apply(pg_temp.u(p_event), jsonb_build_array(
    jsonb_build_object('id', p_type, 'sold', p_sold)), clock_timestamp()) x
$$;
-- Luma's capacity once the target is sent (the ack of a live push).
CREATE FUNCTION pg_temp.luma_sent(p_event text, p_type text, p_cap int) RETURNS void LANGUAGE sql AS $$
  SELECT public.exos_luma_inventory_ack(pg_temp.u(p_event), p_type, '{"sent":true,"steps":[]}', true, p_cap)
$$;
-- What every platform can still sell of a ticket type.
CREATE FUNCTION pg_temp.promised(p_event text, p_tier text) RETURNS int LANGUAGE sql AS $$
  SELECT coalesce(sum(o.outstanding), 0)::int FROM public._exos_channel_outstanding(pg_temp.u(p_event)) o WHERE o.tier_id = pg_temp.u(p_tier)
$$;
CREATE FUNCTION pg_temp.free_less_pack(p_tier text) RETURNS int LANGUAGE sql AS $$
  SELECT greatest(public.exos_effective_available(pg_temp.u(p_tier)) - 4, 0)
$$;

-- Connected: Eventbrite (door app) and Luma (Integrations).
SELECT pg_temp.act(NULL);
SELECT public.exos_eventbrite_connect('ce100000-0000-0000-0000-000000000001', pg_temp.u('a1'), 'TOKENRISK0001', 'Risk Room');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT public.exos_save_integration('ce100000-0000-0000-0000-000000000001', 'luma', '{}', 'secret-luma-key-ce1');
RESET ROLE;
SELECT pg_temp.act(NULL);

-- R1 ----------------------------------------------------------------------
DO $$
DECLARE v_eb int; v_lu int;
BEGIN
  -- Eventbrite alone (its door link, class 9001 mapped to GA): as before,
  -- free 100 less one pack of 4.
  PERFORM public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a1'), '881001', 'Two Primaries on Eventbrite');
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a1'), '9001', 'GA', pg_temp.u('d1'));
  ASSERT pg_temp.eb('e1', '9001', 100, 0) = 96, 'R1: one platform: unchanged';
  ASSERT public._exos_channel_share_cap(pg_temp.u('e1'), pg_temp.u('d1'), 'eventbrite', 96, 0) = 96, 'R1: the cap alone changes nothing';

  -- Luma sells the same ticket type too.
  INSERT INTO public.exos_channel_mirrors (event_id, provider, org_id, mode, external_id, status)
  VALUES (pg_temp.u('e1'), 'luma', 'ce100000-0000-0000-0000-000000000001', 'link', 'evt-ce1show', 'synced');
  INSERT INTO public.exos_luma_ticket_links (event_id, luma_event_id, luma_ticket_type_id, luma_ticket_name, tier_id)
  VALUES (pg_temp.u('e1'), 'evt-ce1show', 'lt-ga', 'GA', pg_temp.u('d1'));

  -- Before: Eventbrite 96 AND Luma 96 of the same 96. Now Eventbrite (still
  -- at 96 on Eventbrite) is asked down to its half, and Luma gets nothing
  -- while Eventbrite can still sell 96.
  ASSERT pg_temp.eb('e1', '9001', 96, 0) = 48, 'R1: Eventbrite: half of the shared pool';
  ASSERT pg_temp.luma('e1', 'lt-ga', 0) = 0, 'R1: Luma waits while Eventbrite still has 96';
  ASSERT pg_temp.promised('e1', 'd1') <= pg_temp.free_less_pack('d1'), 'R1: never offered twice (Eventbrite at 96)';
  -- Eventbrite set to 48 (its next read says so): Luma gets the other half.
  ASSERT pg_temp.eb('e1', '9001', 48, 0) = 48, 'R1: Eventbrite stays at its half';
  v_lu := pg_temp.luma('e1', 'lt-ga', 0);
  ASSERT v_lu = 48, 'R1: Luma: the other half ' || v_lu;
  PERFORM pg_temp.luma_sent('e1', 'lt-ga', v_lu);
  ASSERT pg_temp.promised('e1', 'd1') = 96 AND pg_temp.free_less_pack('d1') = 96, 'R1: together exactly the shared pool';

  -- Luma sells 10: the seats come off Exos; Luma keeps only what Eventbrite leaves.
  v_lu := pg_temp.luma('e1', 'lt-ga', 10);
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 10, 'R1: Luma sales counted';
  ASSERT v_lu = 10 + 38, 'R1: Luma target: sold 10 + (86 shared - 48 Eventbrite) ' || v_lu;
  PERFORM pg_temp.luma_sent('e1', 'lt-ga', v_lu);
  ASSERT pg_temp.promised('e1', 'd1') <= pg_temp.free_less_pack('d1'), 'R1: never offered twice (after a Luma sale)';
  -- Eventbrite's next pass rebalances to its half of 86.
  v_eb := pg_temp.eb('e1', '9001', 48, 0);
  ASSERT v_eb = 43, 'R1: Eventbrite: half of 86 ' || v_eb;
  ASSERT pg_temp.promised('e1', 'd1') <= pg_temp.free_less_pack('d1'), 'R1: never offered twice (rebalanced)';
  -- Eventbrite sells 5 more than Exos knew of: still within what is left.
  v_eb := pg_temp.eb('e1', '9001', 43, 5);
  ASSERT pg_temp.promised('e1', 'd1') <= pg_temp.free_less_pack('d1'), 'R1: never offered twice (after an Eventbrite sale)';

  -- The house: 50 seats, one ticket type of 100 on both platforms.
  PERFORM public.exos_eventbrite_link(pg_temp.u('e2'), pg_temp.u('a1'), '881002', 'House Cap on Eventbrite');
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e2'), pg_temp.u('a1'), '9002', 'GA', pg_temp.u('d3'));
  INSERT INTO public.exos_channel_mirrors (event_id, provider, org_id, mode, external_id, status)
  VALUES (pg_temp.u('e2'), 'luma', 'ce100000-0000-0000-0000-000000000001', 'link', 'evt-ce1house', 'synced');
  INSERT INTO public.exos_luma_ticket_links (event_id, luma_event_id, luma_ticket_type_id, luma_ticket_name, tier_id)
  VALUES (pg_temp.u('e2'), 'evt-ce1house', 'lt-h', 'GA', pg_temp.u('d3'));
  v_eb := pg_temp.eb('e2', '9002', 1, 0);
  v_lu := pg_temp.luma('e2', 'lt-h', 0);
  ASSERT v_eb = 25 AND v_lu = 25, 'R1: the house split, not offered twice: ' || v_eb || ' + ' || v_lu;

  -- Both applies take the event's lock before any row lock.
  ASSERT position('exos_channel_promise:' in pg_get_functiondef('public.exos_eventbrite_inventory_apply(uuid,jsonb,timestamptz)'::regprocedure))
       < position('FOR UPDATE' in pg_get_functiondef('public.exos_eventbrite_inventory_apply(uuid,jsonb,timestamptz)'::regprocedure)), 'R1: Eventbrite lock first';
  ASSERT position('exos_channel_promise:' in pg_get_functiondef('public.exos_luma_inventory_apply(uuid,jsonb,timestamptz)'::regprocedure))
       < position('FOR UPDATE' in pg_get_functiondef('public.exos_luma_inventory_apply(uuid,jsonb,timestamptz)'::regprocedure)), 'R1: Luma lock first';
END $$;

-- R2 ----------------------------------------------------------------------
INSERT INTO public.exos_org_integrations (org_id, provider, status, config)
VALUES ('ce100000-0000-0000-0000-000000000001', 'pretix', 'connected', '{}')
ON CONFLICT DO NOTHING;
INSERT INTO public.exos_guest_lists (id, event_id, org_id, name, max_plus_ones, counts_toward_capacity)
VALUES (pg_temp.u('f3'), pg_temp.u('e3'), 'ce100000-0000-0000-0000-000000000001', 'pretix', 0, false);
INSERT INTO public.exos_backend_links (event_id, org_id, provider, external_ref, external_name, list_id)
VALUES (pg_temp.u('e3'), 'ce100000-0000-0000-0000-000000000001', 'pretix', 'onpretix', 'On pretix', pg_temp.u('f3'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
-- e1 is door-linked to Eventbrite 881001: creating another there, or linking another, is refused.
SELECT set_config('ce1.eb_create', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e1'), 'eventbrite')$$,
  'already linked to Eventbrite event 881001')::text, true);
SELECT set_config('ce1.eb_other', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e1'), 'eventbrite', 'link', '881099')$$,
  'already linked to Eventbrite event 881001')::text, true);
SELECT public.exos_channel_set(pg_temp.u('e1'), 'eventbrite', 'link', '881001');
SELECT set_config('ce1.mirror_other', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e1'), 'luma', 'link', 'evt-ce1other')$$,
  'already mirrored on luma event evt-ce1show')::text, true);
SELECT set_config('ce1.pretix', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e3'), 'luma')$$,
  'door list already comes from pretix')::text, true);
SELECT public.exos_channel_set(pg_temp.u('e4'), 'eventbrite');
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
DECLARE c record; j jsonb; m public.exos_channel_mirrors%ROWTYPE;
BEGIN
  ASSERT current_setting('ce1.eb_create')::boolean AND current_setting('ce1.eb_other')::boolean, 'R2: Eventbrite: another event refused';
  ASSERT current_setting('ce1.mirror_other')::boolean, 'R2: a mirror keeps its external event';
  ASSERT current_setting('ce1.pretix')::boolean, 'R2: a door list from pretix refused';
  ASSERT (SELECT external_id FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e1') AND provider = 'eventbrite') = '881001',
         'R2: linking the door link''s own event is fine';

  -- e4 gets linked to Eventbrite 881009 while Exos creates its mirror there.
  PERFORM public.exos_eventbrite_link(pg_temp.u('e4'), pg_temp.u('a1'), '881009', 'Relinked by hand');
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e4')) x WHERE x.provider = 'eventbrite';
  ASSERT c.lease_id IS NOT NULL, 'R2: claimed';
  j := public.exos_channel_mark(pg_temp.u('e4'), 'eventbrite', c.lease_id, c.change_seq, jsonb_build_object(
         'state', 'synced', 'external_id', '881010', 'hash', 'h1', 'external_meta', jsonb_build_object('organization_id', '42'),
         'tickets', jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d4'), 'external_ticket_id', '9010', 'name', 'GA', 'created', true))));
  SELECT * INTO m FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e4') AND provider = 'eventbrite';
  ASSERT j ->> 'state' = 'error' AND j ->> 'conflict' LIKE '%Eventbrite event 881009%', 'R2: a conflict ' || j::text;
  ASSERT m.external_id = '881010', 'R2: the new event is kept on the mirror (never created twice)';
  ASSERT m.status = 'error' AND m.last_error LIKE 'conflict: %881009%881010%' AND m.synced_seq = 0, 'R2: shown, not in step: ' || coalesce(m.last_error, '');
  ASSERT m.external_meta ->> 'conflict' LIKE '%881009%', 'R2: recorded for the sync';
  ASSERT (SELECT eb_event_id FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e4')) = '881009', 'R2: the door link untouched';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links WHERE event_id = pg_temp.u('e4')), 'R2: no mapping on either';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT set_config('ce1.still', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e4'), 'eventbrite')$$,
  'already linked to Eventbrite event 881009')::text, true);
RESET ROLE;
SELECT pg_temp.act(NULL);
-- Resolved: the hand link removed, the channel saved again.
DELETE FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e4');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT public.exos_channel_set(pg_temp.u('e4'), 'eventbrite');
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
DECLARE c record; j jsonb;
BEGIN
  ASSERT current_setting('ce1.still')::boolean, 'R2: refused while the conflict stands';
  ASSERT NOT ((SELECT external_meta FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e4') AND provider = 'eventbrite') ? 'conflict'),
         'R2: the save clears the conflict';
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e4')) x WHERE x.provider = 'eventbrite';
  ASSERT c.payload -> 'mirror' ->> 'external_id' = '881010', 'R2: the kept event is used (no new create)';
  j := public.exos_channel_mark(pg_temp.u('e4'), 'eventbrite', c.lease_id, c.change_seq, jsonb_build_object(
         'state', 'synced', 'external_id', '881010', 'hash', 'h2',
         'tickets', jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d4'), 'external_ticket_id', '9010', 'name', 'GA',
                                                         'created', true, 'capacity', 30))));
  ASSERT j ->> 'state' = 'synced' AND j -> 'conflict' = 'null'::jsonb, 'R2: synced once resolved ' || j::text;
  ASSERT (SELECT eb_event_id FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e4')) = '881010', 'R2: linked now';

  -- R5: the class Exos created, with its first capacity; claim sends both.
  ASSERT (SELECT exos_created AND eb_capacity = 30 FROM public.exos_eventbrite_ticket_links WHERE event_id = pg_temp.u('e4') AND eb_ticket_class_id = '9010'),
         'R5: created + first capacity recorded';
  ASSERT (SELECT NOT exos_created FROM public.exos_eventbrite_ticket_links WHERE event_id = pg_temp.u('e1') AND eb_ticket_class_id = '9001'),
         'R5: a class the organizer mapped is not Exos''s';
  UPDATE public.exos_channel_mirrors SET change_seq = change_seq + 1, lease_id = NULL, lease_until = NULL WHERE event_id = pg_temp.u('e4');
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e4')) x WHERE x.provider = 'eventbrite';
  ASSERT c.payload -> 'maps' -> 0 ->> 'created' = 'true', 'R5: claim sends created ' || (c.payload -> 'maps')::text;
  ASSERT (c.payload -> 'tiers' -> 0 ->> 'share_cap')::int = 32, 'R5: share_cap: 40 free less the default pack of 8 ' || (c.payload -> 'tiers')::text;
  -- On e1, Luma holds 48 of GA's 86: Eventbrite's share_cap is what's left.
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e1')) x WHERE x.provider = 'eventbrite';
  ASSERT (c.payload -> 'tiers' -> 0 ->> 'share_cap')::int <= pg_temp.free_less_pack('d1') - 38, 'R5: e1 share_cap ' || (c.payload -> 'tiers')::text;
  PERFORM public.exos_channel_mark(pg_temp.u('e1'), 'eventbrite', c.lease_id, c.change_seq, '{"state":"dry_run"}');
END $$;

-- R3 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT public.exos_channel_set(pg_temp.u('e5'), 'luma');
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
DECLARE c record; j jsonb; p jsonb;
BEGIN
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e5')) x WHERE x.provider = 'luma';
  j := public.exos_channel_create_begin(pg_temp.u('e5'), 'luma', gen_random_uuid(), '{"name":"Retried","start":"2026-12-01T20:00:00Z","slug":"retried-aaaa1111"}');
  ASSERT j ->> 'reason' = 'lease-lost', 'R3: needs the lease';
  ASSERT pg_temp.refused($q$SELECT public.exos_channel_create_begin(pg_temp.u('e5'), 'luma', gen_random_uuid(), '[]')$q$, 'bad marker'), 'R3: a marker object';
  j := public.exos_channel_create_begin(pg_temp.u('e5'), 'luma', c.lease_id, '{"name":"Retried","start":"2026-12-01T20:00:00Z","slug":"retried-aaaa1111"}');
  ASSERT (j ->> 'ok')::boolean AND j -> 'pending' ->> 'slug' = 'retried-aaaa1111' AND (j -> 'pending' ->> 'tries')::int = 1, 'R3: begun ' || j::text;
  p := (SELECT external_meta -> 'pending_create' FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e5') AND provider = 'luma');
  ASSERT p ->> 'name' = 'Retried' AND p ->> 'start' = '2026-12-01T20:00:00Z' AND p ->> 'first' IS NOT NULL, 'R3: recorded ' || p::text;
  ASSERT (SELECT lease_until > now() + interval '100 seconds' FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e5') AND provider = 'luma'),
         'R3: lease extended';
  -- A second try at once: refused (the first may still be in flight).
  j := public.exos_channel_create_begin(pg_temp.u('e5'), 'luma', c.lease_id, '{"name":"Retried","start":"2026-12-01T20:00:00Z","slug":"retried-bbbb2222"}');
  ASSERT j ->> 'reason' = 'in-flight', 'R3: in flight ' || j::text;
  -- The pass dies; the lease runs out; a later pass finds nothing and tries again.
  UPDATE public.exos_channel_mirrors
     SET external_meta = jsonb_set(external_meta, '{pending_create,at}', to_jsonb(now() - interval '3 minutes')),
         lease_id = NULL, lease_until = NULL
   WHERE event_id = pg_temp.u('e5') AND provider = 'luma';
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e5')) x WHERE x.provider = 'luma';
  ASSERT c.payload -> 'mirror' -> 'external_meta' -> 'pending_create' ->> 'slug' = 'retried-aaaa1111', 'R3: the next pass sees the pending create';
  j := public.exos_channel_create_begin(pg_temp.u('e5'), 'luma', c.lease_id, '{"name":"Retried","start":"2026-12-01T20:00:00Z","slug":"retried-bbbb2222"}');
  ASSERT (j ->> 'ok')::boolean AND j -> 'pending' ->> 'slug' = 'retried-aaaa1111' AND (j -> 'pending' ->> 'tries')::int = 2
     AND j -> 'pending' ->> 'first' = p ->> 'first', 'R3: the same slug, the first time kept ' || j::text;
  -- Found (or created) and marked: the pending create is cleared; no more creates.
  j := public.exos_channel_mark(pg_temp.u('e5'), 'luma', c.lease_id, c.change_seq, jsonb_build_object(
         'state', 'synced', 'external_id', 'evt-ce1retry', 'hash', 'h1',
         'external_meta', jsonb_build_object('pending_create', p),
         'tickets', jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d5'), 'external_ticket_id', 'lt-r', 'name', 'GA',
                                                         'created', true, 'capacity', 36))));
  ASSERT j ->> 'state' = 'synced', 'R3: synced ' || j::text;
  ASSERT NOT ((SELECT external_meta FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e5') AND provider = 'luma') ? 'pending_create'),
         'R3: pending create cleared';
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e5')) x WHERE x.provider = 'luma';
  j := public.exos_channel_create_begin(pg_temp.u('e5'), 'luma', c.lease_id, '{"name":"Retried"}');
  ASSERT j ->> 'reason' = 'has-external', 'R3: no create once it has its id';
  -- R5: Luma's first capacity recorded (the other platform counts it at once).
  ASSERT (SELECT luma_capacity FROM public.exos_luma_ticket_links WHERE event_id = pg_temp.u('e5') AND luma_ticket_type_id = 'lt-r') = 36,
         'R5: Luma first capacity';
  ASSERT pg_temp.promised('e5', 'd5') = 36, 'R5: counted as Luma''s promise';
  PERFORM public.exos_channel_mark(pg_temp.u('e5'), 'luma', c.lease_id, c.change_seq, '{"state":"dry_run"}');
END $$;

-- R4 ----------------------------------------------------------------------
DO $$
DECLARE v_plan jsonb := jsonb_build_object('dry_run', true, 'path', '/v1/events/ticket-types/update',
  'body', jsonb_build_object('event_ticket_type_id', 'lt-ga', 'max_capacity', 40),
  'steps', jsonb_build_array(jsonb_build_object('op', 'planned', 'method', 'POST', 'path', '/v1/events/ticket-types/update',
                                                'body', jsonb_build_object('event_ticket_type_id', 'lt-ga', 'max_capacity', 40))));
BEGIN
  PERFORM public.exos_luma_inventory_ack(pg_temp.u('e1'), 'lt-ga', v_plan, false, 40);
  ASSERT (SELECT jsonb_array_length(plan -> 'steps') FROM public.exos_luma_ticket_links WHERE event_id = pg_temp.u('e1') AND luma_ticket_type_id = 'lt-ga') = 1,
         'R4: the ack keeps its steps';
  ASSERT (SELECT plan -> 'steps' -> 0 ->> 'op' FROM public.exos_luma_ticket_links WHERE event_id = pg_temp.u('e1') AND luma_ticket_type_id = 'lt-ga') = 'planned',
         'R4: planned';
END $$;

-- Grants: the new functions are the service role's only.
DO $$
BEGIN
  ASSERT NOT has_function_privilege('anon', 'public.exos_channel_create_begin(uuid,text,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_channel_create_begin(uuid,text,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_channel_share_cap(uuid,uuid,text,integer,integer)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_channel_outstanding(uuid)', 'EXECUTE'), 'grants';
END $$;

ROLLBACK;
\echo 'test_channel_risks: all passed'
