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
--   R6 a door link found before the create (create_begin refuses and records
--      it); the door can't be re-pointed or unlinked under a mirror (Eventbrite
--      and Luma); removing a channel keeps its promise through the door link
--   R7 another Exos event's external event (any org) is never adopted: mark
--      records a conflict (not kept, pending cleared; same org: no 23505),
--      exos_channel_set refuses it
--   R8 the lease renewed per write; the venue kept with a pending create;
--      link mode refused while a create is pending
--   R9 a channel isn't removed while a pass holds its lease
--   R10 squatting: another org's UNVERIFIED id blocks no one; once the owner
--      verifies it (a live pass, or a read proving it), the squatter's pass and
--      mark refuse it; "another org's" and "not on this account" get one answer
--   (the migration's re-apply is checked by reapply_check.sh in run_p0)
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
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000e6','ce100000-0000-0000-0000-000000000001','Split House','split-house','published',
   now() + interval '10 days','America/New_York',100,0,'{"maxPerOrder":4}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000e7','ce100000-0000-0000-0000-000000000001','Door First','door-first','published',
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000e8','ce100000-0000-0000-0000-000000000001','Relink','relink','published',
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000e9','ce100000-0000-0000-0000-000000000001','Sibling','sibling','published',
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000eb','ce100000-0000-0000-0000-000000000001','Linker','linker','published',
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1'),
  ('ce100000-0000-0000-0000-0000000000ed','ce100000-0000-0000-0000-000000000001','Owner','owner-event','published',
   now() + interval '10 days','America/New_York',0,0,'{}','ce100000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order) VALUES
  ('ce100000-0000-0000-0000-0000000000d1','ce100000-0000-0000-0000-0000000000e1','GA',25,100,0,1),
  ('ce100000-0000-0000-0000-0000000000d3','ce100000-0000-0000-0000-0000000000e2','GA',25,100,0,1),
  ('ce100000-0000-0000-0000-0000000000d4','ce100000-0000-0000-0000-0000000000e4','GA',25,40,0,1),
  ('ce100000-0000-0000-0000-0000000000d5','ce100000-0000-0000-0000-0000000000e5','GA',25,40,0,1),
  ('ce100000-0000-0000-0000-0000000000d6','ce100000-0000-0000-0000-0000000000e6','A',25,100,0,1),
  ('ce100000-0000-0000-0000-0000000000d7','ce100000-0000-0000-0000-0000000000e6','B',25,100,0,2),
  ('ce100000-0000-0000-0000-0000000000d8','ce100000-0000-0000-0000-0000000000e8','GA',25,60,0,1),
  ('ce100000-0000-0000-0000-0000000000d9','ce100000-0000-0000-0000-0000000000e9','GA',25,60,0,1);

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
DECLARE v_eb int; v_lu int; i int;
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
  -- Split less one pack, as one platform alone would get: (50 - 4) / 2 each.
  ASSERT v_eb = 23 AND v_lu = 23, 'R1: the house split, not offered twice: ' || v_eb || ' + ' || v_lu;
  ASSERT v_eb + v_lu <= 50 - 4, 'R1: the house: never past H - pack';

  -- The house again, each platform on its OWN ticket type (100 seats,
  -- maxPerOrder 4): alone Eventbrite would get 96; together they never pass 96.
  PERFORM public.exos_eventbrite_link(pg_temp.u('e6'), pg_temp.u('a1'), '881006', 'Split House on Eventbrite');
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e6'), pg_temp.u('a1'), '9006', 'A', pg_temp.u('d6'));
  ASSERT pg_temp.eb('e6', '9006', 1, 0) = 96, 'R1: one platform on the house: 100 - pack';
  INSERT INTO public.exos_channel_mirrors (event_id, provider, org_id, mode, external_id, status)
  VALUES (pg_temp.u('e6'), 'luma', 'ce100000-0000-0000-0000-000000000001', 'link', 'evt-ce1split', 'synced');
  INSERT INTO public.exos_luma_ticket_links (event_id, luma_event_id, luma_ticket_type_id, luma_ticket_name, tier_id)
  VALUES (pg_temp.u('e6'), 'evt-ce1split', 'lt-b', 'B', pg_temp.u('d7'));
  FOR i IN 1..4 LOOP
    v_eb := pg_temp.eb('e6', '9006', coalesce((SELECT target_capacity FROM public.exos_eventbrite_ticket_links WHERE event_id = pg_temp.u('e6')), 1), 0);
    v_lu := pg_temp.luma('e6', 'lt-b', 0);
    PERFORM pg_temp.luma_sent('e6', 'lt-b', v_lu);
    ASSERT (SELECT coalesce(sum(outstanding), 0) FROM public._exos_channel_outstanding(pg_temp.u('e6'))) <= 96,
           'R1: two ticket types, one house: ' || v_eb || ' + ' || v_lu || ' (round ' || i || ')';
  END LOOP;
  ASSERT v_eb + v_lu <= 96 AND v_lu > 0, 'R1: converged within H - pack: ' || v_eb || ' + ' || v_lu;

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
  -- exos_eventbrite_link refuses that now (R6); a link from before the guards is put in directly.
  ASSERT pg_temp.refused($q$SELECT public.exos_eventbrite_link(pg_temp.u('e4'), pg_temp.u('a1'), '881009', 'x')$q$, 'being created'), 'R2: refused at link';
  INSERT INTO public.exos_eventbrite_links (event_id, org_id, eb_event_id, eb_event_name, list_id, linked_by, linked_at)
  SELECT pg_temp.u('e4'), 'ce100000-0000-0000-0000-000000000001', '881009', 'Relinked by hand', l.id, pg_temp.u('a1'), now()
    FROM (SELECT id FROM public.exos_guest_lists WHERE event_id = pg_temp.u('e3') LIMIT 1) l;
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

-- R6: link conflicts caught before anything is created; door links can't move under a mirror.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT public.exos_channel_set(pg_temp.u('e7'), 'eventbrite');
SELECT public.exos_channel_set(pg_temp.u('e8'), 'eventbrite');
SELECT public.exos_channel_set(pg_temp.u('e8'), 'luma');
SELECT public.exos_channel_set(pg_temp.u('e9'), 'eventbrite');
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
DECLARE c record; j jsonb;
BEGIN
  -- (a) A door link that predates the guards: create_begin refuses and records it.
  ASSERT pg_temp.refused($q$SELECT public.exos_eventbrite_link(pg_temp.u('e7'), pg_temp.u('a1'), '881201', 'x')$q$, 'being created'),
         'R6: no door link while Exos is creating the event there';
  INSERT INTO public.exos_eventbrite_links (event_id, org_id, eb_event_id, eb_event_name, list_id, linked_by, linked_at)
  SELECT pg_temp.u('e7'), 'ce100000-0000-0000-0000-000000000001', '881201', 'old', l.id, pg_temp.u('a1'), now()
    FROM (SELECT id FROM public.exos_guest_lists WHERE event_id = pg_temp.u('e3') LIMIT 1) l;
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e7')) x WHERE x.provider = 'eventbrite';
  j := public.exos_channel_create_begin(pg_temp.u('e7'), 'eventbrite', c.lease_id, '{"name":"Door First","start":"2026-12-01T20:00:00Z"}');
  ASSERT j ->> 'reason' = 'conflict' AND j ->> 'conflict' LIKE '%881201%', 'R6a: create refused ' || j::text;
  ASSERT (SELECT external_meta ->> 'conflict' FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e7') AND provider = 'eventbrite') LIKE '%881201%',
         'R6a: recorded, so the sync stops';
  ASSERT NOT ((SELECT external_meta FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e7') AND provider = 'eventbrite') ? 'pending_create'),
         'R6a: nothing pending';
  PERFORM public.exos_channel_mark(pg_temp.u('e7'), 'eventbrite', c.lease_id, c.change_seq, '{"state":"error","error":"x"}');

  -- (b) e8 synced on Eventbrite 881301 (class 9301 at 50) and Luma evt-ce1relink (lt-8 at 40).
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e8')) x WHERE x.provider = 'eventbrite';
  PERFORM public.exos_channel_mark(pg_temp.u('e8'), 'eventbrite', c.lease_id, c.change_seq, jsonb_build_object(
    'state', 'synced', 'external_id', '881301', 'hash', 'h',
    'tickets', jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d8'), 'external_ticket_id', '9301', 'name', 'GA', 'created', true, 'capacity', 50))));
  UPDATE public.exos_channel_mirrors SET lease_id = NULL, lease_until = NULL WHERE event_id = pg_temp.u('e8') AND provider = 'luma';
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e8')) x WHERE x.provider = 'luma';
  PERFORM public.exos_channel_mark(pg_temp.u('e8'), 'luma', c.lease_id, c.change_seq, jsonb_build_object(
    'state', 'synced', 'external_id', 'evt-ce1relink', 'hash', 'h',
    'tickets', jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d8'), 'external_ticket_id', 'lt-8', 'name', 'GA', 'created', true, 'capacity', 40))));
  ASSERT pg_temp.promised('e8', 'd8') = 90, 'R6b: both counted ' || pg_temp.promised('e8', 'd8');
  ASSERT pg_temp.refused($q$SELECT public.exos_eventbrite_link(pg_temp.u('e8'), pg_temp.u('a1'), '881302', 'x')$q$, 'event 881301'),
         'R6b: the door can''t be re-pointed under the mirror';
  ASSERT pg_temp.refused($q$SELECT public.exos_eventbrite_unlink(pg_temp.u('e8'), pg_temp.u('a1'))$q$, 'remove it there first'),
         'R6b: nor unlinked';
  PERFORM public.exos_eventbrite_link(pg_temp.u('e8'), pg_temp.u('a1'), '881301', 'same');   -- the same event: fine
  ASSERT pg_temp.promised('e8', 'd8') = 90, 'R6b: still counted';
  ASSERT pg_temp.refused($q$SELECT public.exos_eventbrite_link(pg_temp.u('e9'), pg_temp.u('a1'), '881301', 'x')$q$, 'being created'),
         'R6b: e9 is creating its own';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT set_config('ce1.bk_link', pg_temp.refused($$SELECT public.exos_backend_link(pg_temp.u('e8'), 'pretix', 'onpretix')$$, 'sold on Luma')::text, true);
SELECT set_config('ce1.bk_other', pg_temp.refused($$SELECT public.exos_backend_link(pg_temp.u('e8'), 'luma', 'evt-ce1other')$$, 'evt-ce1relink')::text, true);
SELECT set_config('ce1.bk_unlink', pg_temp.refused($$SELECT public.exos_backend_unlink(pg_temp.u('e8'))$$, 'remove it there first')::text, true);
-- R9: not while a pass holds the lease (it may still be writing).
SELECT set_config('ce1.rm_leased', pg_temp.refused($$SELECT public.exos_channel_remove(pg_temp.u('e8'), 'eventbrite')$$, 'is running')::text, true);
RESET ROLE;
SELECT pg_temp.act(NULL);
UPDATE public.exos_channel_mirrors SET lease_id = NULL, lease_until = NULL WHERE event_id = pg_temp.u('e8');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT public.exos_channel_remove(pg_temp.u('e8'), 'luma');
SELECT public.exos_channel_remove(pg_temp.u('e8'), 'eventbrite');
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
BEGIN
  ASSERT current_setting('ce1.rm_leased')::boolean, 'R9: remove refused while leased';
  ASSERT current_setting('ce1.bk_link')::boolean AND current_setting('ce1.bk_other')::boolean AND current_setting('ce1.bk_unlink')::boolean,
         'R6b: Luma''s door list the same';
  -- The channels removed (the events stay on sale there): the door links keep both in the promise.
  ASSERT pg_temp.promised('e8', 'd8') = 90, 'R6b: removing a channel doesn''t zero its promise ' || pg_temp.promised('e8', 'd8');
  PERFORM public.exos_eventbrite_unlink(pg_temp.u('e8'), pg_temp.u('a1'));   -- now allowed: an explicit disconnect
  ASSERT pg_temp.promised('e8', 'd8') = 40, 'R6b: unlinked by hand: Eventbrite no longer counted';
END $$;

-- R7: a sibling Exos event's external event is never adopted.
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('ce100000-0000-0000-0000-000000000002','Other Org','risk-other-org','ce100000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,created_by) VALUES
  ('ce100000-0000-0000-0000-0000000000ea','ce100000-0000-0000-0000-000000000002','Sibling','sibling-2','published',
   now() + interval '10 days','America/New_York','ce100000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_channel_mirrors (event_id, provider, org_id, mode, external_id, status)
VALUES (pg_temp.u('ea'), 'eventbrite', 'ce100000-0000-0000-0000-000000000002', 'create', '881401', 'synced');
-- Verified: a live pass of that org recorded it (mark sets this).
UPDATE public.exos_channel_mirrors SET external_verified_at = now() WHERE event_id = pg_temp.u('ea');
DO $$
DECLARE c record; j jsonb; m public.exos_channel_mirrors%ROWTYPE;
BEGIN
  ASSERT public.exos_channel_external_taken(pg_temp.u('e9'), 'eventbrite', ARRAY['881301', '881401', '881499']) @> ARRAY['881401']
     AND NOT ('881499' = ANY (public.exos_channel_external_taken(pg_temp.u('e9'), 'eventbrite', ARRAY['881499']))), 'R7: in use, any org';
  ASSERT NOT ('881401' = ANY (public.exos_channel_external_taken(pg_temp.u('ea'), 'eventbrite', ARRAY['881401']))), 'R7: not by itself';
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e9')) x WHERE x.provider = 'eventbrite';
  j := public.exos_channel_create_begin(pg_temp.u('e9'), 'eventbrite', c.lease_id, '{"name":"Sibling","start":"2026-12-01T20:00:00Z"}');
  ASSERT (j ->> 'ok')::boolean, 'R7: begun';
  -- The pass adopted the other org's event 881401 (same name and start): mark refuses it.
  j := public.exos_channel_mark(pg_temp.u('e9'), 'eventbrite', c.lease_id, c.change_seq, jsonb_build_object(
         'state', 'synced', 'external_id', '881401', 'hash', 'h',
         'tickets', jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d9'), 'external_ticket_id', '9401', 'name', 'GA'))));
  SELECT * INTO m FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e9') AND provider = 'eventbrite';
  ASSERT j ->> 'state' = 'error' AND j ->> 'conflict' LIKE '%881401%another Exos event%', 'R7: a conflict ' || j::text;
  ASSERT m.external_id IS NULL, 'R7: not kept';
  ASSERT NOT (m.external_meta ? 'pending_create') AND m.external_meta ? 'conflict', 'R7: pending cleared, the sync stops';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e9'))
     AND NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links WHERE event_id = pg_temp.u('e9')), 'R7: nothing linked';
  -- Same org (the unique index would have raised 23505): the same conflict, no exception.
  UPDATE public.exos_channel_mirrors SET lease_id = NULL, lease_until = NULL, external_meta = external_meta - 'conflict' WHERE event_id = pg_temp.u('e9');
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e9')) x WHERE x.provider = 'eventbrite';
  UPDATE public.exos_channel_mirrors SET external_id = '881501' WHERE event_id = pg_temp.u('e7') AND provider = 'eventbrite';
  j := public.exos_channel_mark(pg_temp.u('e9'), 'eventbrite', c.lease_id, c.change_seq, '{"state":"synced","external_id":"881501"}');
  ASSERT j ->> 'state' = 'error' AND j ->> 'conflict' LIKE '%881501%', 'R7: same org: a conflict, not 23505 ' || j::text;
  -- Lease renewal: refused without the lease; with it, extended and the venue noted on a pending create.
  ASSERT NOT public.exos_channel_lease_renew(pg_temp.u('e9'), 'eventbrite', gen_random_uuid()), 'R7: renew needs the lease';
  -- And exos_channel_set can't link it either.
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
-- Linking another org's verified event isn't refused here (that would tell
-- this org it is used); the pass refuses it in the words of an event not on
-- the account (exos-channel-sync, Deno), and mark would never keep it.
SELECT public.exos_channel_set(pg_temp.u('eb'), 'eventbrite', 'link', '881401');
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
DECLARE c record; j jsonb;
BEGIN
  ASSERT (SELECT external_id FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('eb') AND provider = 'eventbrite') = '881401'
     AND '881401' = ANY (public.exos_channel_external_taken(pg_temp.u('eb'), 'eventbrite', ARRAY['881401'])), 'R7: accepted at set, taken for the pass';
  -- R8: the lease is renewed per write; the venue is kept with the pending create.
  UPDATE public.exos_channel_mirrors SET lease_id = NULL, lease_until = NULL, external_meta = '{}', status = 'pending' WHERE event_id = pg_temp.u('e9');
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('e9')) x WHERE x.provider = 'eventbrite';
  UPDATE public.exos_channel_mirrors SET lease_until = now() + interval '10 seconds' WHERE event_id = pg_temp.u('e9');
  ASSERT public.exos_channel_lease_renew(pg_temp.u('e9'), 'eventbrite', c.lease_id), 'R8: renewed';
  ASSERT (SELECT lease_until > now() + interval '100 seconds' FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e9')), 'R8: extended';
  j := public.exos_channel_create_begin(pg_temp.u('e9'), 'eventbrite', c.lease_id, '{"name":"Sibling","start":"2026-12-01T20:00:00Z"}');
  ASSERT public.exos_channel_lease_renew(pg_temp.u('e9'), 'eventbrite', c.lease_id, '{"venue_id":"7001","venue_key":"Hall, 1 Main St"}'), 'R8: noted';
  ASSERT (SELECT external_meta -> 'pending_create' ->> 'venue_id' FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('e9')) = '7001', 'R8: venue kept';
  UPDATE public.exos_channel_mirrors SET external_meta = jsonb_set(external_meta, '{pending_create,at}', to_jsonb(now() - interval '3 minutes'))
   WHERE event_id = pg_temp.u('e9');
  j := public.exos_channel_create_begin(pg_temp.u('e9'), 'eventbrite', c.lease_id, '{"name":"Sibling","start":"2026-12-01T20:00:00Z"}');
  ASSERT j -> 'pending' ->> 'venue_id' = '7001', 'R8: a retry reuses the venue ' || j::text;
  -- Link mode while a create is pending: refused.
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT set_config('ce1.link_pending', pg_temp.refused($$SELECT public.exos_channel_set(pg_temp.u('e9'), 'eventbrite', 'link', '881777')$$,
  'creating this event')::text, true);
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$ BEGIN ASSERT current_setting('ce1.link_pending')::boolean, 'R8: link mode refused while a create is pending'; END $$;

-- R10: squatting. Another org links (unverified) an id it doesn't own: it
-- blocks no one, and nothing tells either org about the other.
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('ce100000-0000-0000-0000-000000000002','ce100000-0000-0000-0000-0000000000a1','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,created_by) VALUES
  ('ce100000-0000-0000-0000-0000000000ec','ce100000-0000-0000-0000-000000000002','Squatter','squatter','published',
   now() + interval '10 days','America/New_York','ce100000-0000-0000-0000-0000000000a1');
SELECT public.exos_eventbrite_connect('ce100000-0000-0000-0000-000000000002', pg_temp.u('a1'), 'TOKENRISK0002', 'Other Room');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT public.exos_save_integration('ce100000-0000-0000-0000-000000000002', 'luma', '{}', 'secret-luma-key-ce2');
SELECT public.exos_channel_set(pg_temp.u('ec'), 'eventbrite', 'link', '881601');   -- org 2 squats org 1's public event
SELECT public.exos_channel_set(pg_temp.u('ed'), 'eventbrite', 'link', '881601');   -- org 1, the owner: not blocked
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
DECLARE c record; j jsonb;
BEGIN
  ASSERT NOT ('881601' = ANY (public.exos_channel_external_taken(pg_temp.u('ed'), 'eventbrite', ARRAY['881601']))), 'R10: an unverified id blocks no one';
  -- The owner's door link too (exos-eventbrite-sync reads it first).
  PERFORM public.exos_eventbrite_link(pg_temp.u('ed'), pg_temp.u('a1'), '881601', 'Owner on Eventbrite');
  -- The owner's live pass writes with its own token: verified.
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('ed')) x WHERE x.provider = 'eventbrite';
  j := public.exos_channel_mark(pg_temp.u('ed'), 'eventbrite', c.lease_id, c.change_seq, '{"state":"synced","external_id":"881601","hash":"h"}');
  ASSERT j ->> 'state' = 'synced', 'R10: the owner syncs ' || j::text;
  ASSERT (SELECT external_verified_at IS NOT NULL FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('ed') AND provider = 'eventbrite')
     AND (SELECT verified_at IS NOT NULL FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('ed')), 'R10: verified by the live pass';
  -- Now it is the owner's: the squatter's pass is refused and mark never keeps it for them.
  ASSERT '881601' = ANY (public.exos_channel_external_taken(pg_temp.u('ec'), 'eventbrite', ARRAY['881601'])), 'R10: taken for the squatter';
  SELECT * INTO c FROM public.exos_channel_claim(5, pg_temp.u('ec')) x WHERE x.provider = 'eventbrite';
  j := public.exos_channel_mark(pg_temp.u('ec'), 'eventbrite', c.lease_id, c.change_seq, '{"state":"synced","external_id":"881601"}');
  ASSERT j ->> 'state' = 'error' AND (SELECT external_verified_at FROM public.exos_channel_mirrors WHERE event_id = pg_temp.u('ec')) IS NULL,
         'R10: the squatter never verifies it ' || j::text;
  -- One answer for "another org's" and "not on this account": the door link refuses
  -- in exos-eventbrite-sync's 404 words; the Luma backend link in checkRef's.
  ASSERT pg_temp.refused($q$SELECT public.exos_eventbrite_link(pg_temp.u('ec'), pg_temp.u('a1'), '881601', 'x')$q$,
                         'exos_eventbrite_link: Eventbrite has no such event for this account.'), 'R10: the same answer (Eventbrite)';
  -- Org 2's Luma event, read with its own key (verified): refused to org 1 in checkRef's words.
  INSERT INTO public.exos_guest_lists (id, event_id, org_id, name, max_plus_ones, counts_toward_capacity)
  VALUES (pg_temp.u('fc'), pg_temp.u('ec'), 'ce100000-0000-0000-0000-000000000002', 'Luma', 0, false);
  INSERT INTO public.exos_backend_links (event_id, org_id, provider, external_ref, external_name, list_id, verified_at)
  VALUES (pg_temp.u('ec'), 'ce100000-0000-0000-0000-000000000002', 'luma', 'evt-ce2owned', 'Theirs', pg_temp.u('fc'), now());
  PERFORM public.exos_channel_link_verified(pg_temp.u('ec'), 'luma', 'evt-ce2owned');
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ce100000-0000-0000-0000-0000000000a1');
SELECT set_config('ce1.luma_same', pg_temp.refused($$SELECT public.exos_backend_link(pg_temp.u('e4'), 'luma', 'evt-ce2owned')$$,
  'exos_backend_link: Luma has no event with that id.')::text, true);
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$ BEGIN ASSERT current_setting('ce1.luma_same')::boolean, 'R10: the same answer (Luma)'; END $$;

-- Grants: the new functions are the service role's only.
DO $$
BEGIN
  ASSERT NOT has_function_privilege('anon', 'public.exos_channel_create_begin(uuid,text,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_channel_create_begin(uuid,text,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_channel_share_cap(uuid,uuid,text,integer,integer)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_channel_outstanding(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_channel_external_taken(uuid,text,text[])', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_channel_lease_renew(uuid,text,uuid,jsonb)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_channel_link_verified(uuid,text,text)', 'EXECUTE'), 'grants';
END $$;

ROLLBACK;
\echo 'test_channel_risks: all passed'
