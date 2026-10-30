-- ============================================================================
-- Fixed block (mig 20261029160000): Exos sells a block for a platform it
-- can't sync, and hands the unsold rest back at the release time.
--   FB1 exos_set_fixed_block: who may, what it checks (platform, link, this
--       event's types only, 1-100000, not below sold, every type capped, the
--       overall cap, the release time, not over an Eventbrite primary); a
--       block type can't go unlimited; set_resale_options can't move the
--       primary off it
--   FB2 availability is exactly the block (checkout count, max capacity,
--       remaining, no primary hold); Exos mints from it; a copied event
--       starts unreleased
--   FB3 the free-tier and resale gates read the block: 40 is the free tier
--       (no opt-in, no resale); 180 resells only once opted in
--   FB4 last call: Exos is the block's seller (not closed, no hold, mints, the
--       storefront says exos); marketplaces close
--   FB5 the scheduled release: not before its time; the counts (sold, a cart
--       hold pending, a marketplace pool handed back); idempotent; Exos
--       closed (count 0, every mint refused but a held Stripe checkout and a
--       marketplace sale); pools 'block_released'; the mail (owner + manager,
--       once, no buyer data); a lapsed hold shows as "put back 2 more"; can't
--       be turned off or edited after
--   FB6 release now: roles, idempotent, the cron leaves it alone; refused on
--       a non-block event
--   FB7 RLS on the release table; grants (nothing anon; helpers service only)
-- Self-contained (fb prefix), rolled back. The harness turns the resale and
-- last-call rules off for older fixtures; this file puts the defaults back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
DELETE FROM public.exos_platform_settings
 WHERE key IN ('free_tier_max_capacity', 'resale_consent_required', 'free_tier_fee_bps', 'last_call_threshold');

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('fb000000-0000-0000-0000-0000000000a0','fb-owner@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a1','fb-manager@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a2','fb-finance@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a3','fb-scanner@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a4','fb-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('fb000000-0000-0000-0000-000000000001','FB Org','fb-org','fb000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a0','owner'),
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a1','manager'),
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a2','finance'),
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a3','scanner');
-- e1: GA + VIP, uncapped for now (a block of 120 + 60 below). e2: GA, a block
-- of 40 (the free tier). e3: Eventbrite is the primary. e4: doors in 12 hours.
-- e5: an ordinary Exos event.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,venue_name,total_tickets,tickets_sold,purchase_limits,timezone,distribution_networks,created_by) VALUES
  ('fb000000-0000-0000-0000-0000000000e1','fb000000-0000-0000-0000-000000000001','Club Night','fb-club','published',now() + interval '10 days',now() + interval '10 days' - interval '1 hour','Basement',0,0,'{"maxPerOrder":4}','America/New_York','{}','fb000000-0000-0000-0000-0000000000a0'),
  ('fb000000-0000-0000-0000-0000000000e2','fb000000-0000-0000-0000-000000000001','Small Room','fb-small','published',now() + interval '10 days',NULL,'Bar',0,0,'{}','America/New_York','{}','fb000000-0000-0000-0000-0000000000a0'),
  ('fb000000-0000-0000-0000-0000000000e3','fb000000-0000-0000-0000-000000000001','On Eventbrite','fb-eb','published',now() + interval '10 days',NULL,'Hall',0,0,'{}','America/New_York','{}','fb000000-0000-0000-0000-0000000000a0'),
  ('fb000000-0000-0000-0000-0000000000e4','fb000000-0000-0000-0000-000000000001','Tonight','fb-tonight','published',now() + interval '13 hours',now() + interval '12 hours','Bar',0,0,'{}','America/New_York','{}','fb000000-0000-0000-0000-0000000000a0'),
  ('fb000000-0000-0000-0000-0000000000e5','fb000000-0000-0000-0000-000000000001','Plain','fb-plain','published',now() + interval '10 days',NULL,'Hall',0,0,'{}','America/New_York','{}','fb000000-0000-0000-0000-0000000000a0');
UPDATE public.exos_events SET primary_source = 'eventbrite' WHERE id = 'fb000000-0000-0000-0000-0000000000e3';
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order,kind,party_size) VALUES
  ('fb000000-0000-0000-0000-0000000000d1','fb000000-0000-0000-0000-0000000000e1','GA',30,0,0,'public',1,'standard',NULL),
  ('fb000000-0000-0000-0000-0000000000d2','fb000000-0000-0000-0000-0000000000e1','VIP',80,0,0,'public',2,'standard',NULL),
  ('fb000000-0000-0000-0000-0000000000d3','fb000000-0000-0000-0000-0000000000e2','GA',20,10,0,'public',1,'standard',NULL),
  ('fb000000-0000-0000-0000-0000000000d4','fb000000-0000-0000-0000-0000000000e3','GA',20,100,0,'public',1,'standard',NULL),
  ('fb000000-0000-0000-0000-0000000000d5','fb000000-0000-0000-0000-0000000000e4','GA',20,50,0,'public',1,'standard',NULL),
  ('fb000000-0000-0000-0000-0000000000d6','fb000000-0000-0000-0000-0000000000e5','GA',20,100,0,'public',1,'standard',NULL);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"fb@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('fb000000-0000-0000-0000-0000000000' || p)::uuid $$;
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
CREATE FUNCTION pg_temp.set_block(p_event text, p_blocks jsonb, p_release timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_set_fixed_block(pg_temp.u(p_event), true, 'DICE', 'https://dice.fm/event/fb-club', p_blocks, p_release)
$$;
CREATE FUNCTION pg_temp.mint(p_tier text, p_secret text, p_channel text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source)
  VALUES (pg_temp.u('e1'), 'fb000000-0000-0000-0000-000000000001', pg_temp.u(p_tier), 'GA', p_secret || '@x.com', 'active', p_secret, 30, 'ref-' || p_secret, p_channel)
$$;

-- FB1. Turning it on.
DO $$
DECLARE s jsonb;
BEGIN
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a2');
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', '{}')$q$, 'not allowed'), 'FB1: finance can''t';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', '{}')$q$, 'not allowed'), 'FB1: a scanner can''t';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', '{}')$q$, 'not allowed'), 'FB1: a stranger can''t';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', '{}')$q$, 'not allowed'), 'FB1: signed out can''t';

  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', jsonb_build_object(pg_temp.u('d1'), 120))$q$, 'give "VIP" a block size'),
    'FB1: every type is a block';
  ASSERT (SELECT capacity FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 0, 'FB1: a refusal changes nothing';
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', jsonb_build_object(pg_temp.u('d1'), 120, pg_temp.u('d3'), 5))$q$, 'unknown ticket type'),
    'FB1: another event''s type';
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', jsonb_build_object(pg_temp.u('d1'), 0, pg_temp.u('d2'), 60))$q$, '1 to 100000'),
    'FB1: 0 is not a block';
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', jsonb_build_object(pg_temp.u('d1'), '12', pg_temp.u('d2'), 60))$q$, '1 to 100000'),
    'FB1: a number';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_fixed_block(pg_temp.u('e1'), true, '  ', NULL, jsonb_build_object(pg_temp.u('d1'), 120, pg_temp.u('d2'), 60))$q$, 'name the platform'),
    'FB1: a platform name';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_fixed_block(pg_temp.u('e1'), true, 'DICE', 'http://dice.fm/x', jsonb_build_object(pg_temp.u('d1'), 120, pg_temp.u('d2'), 60))$q$, 'https://'),
    'FB1: an https link';
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', jsonb_build_object(pg_temp.u('d1'), 120, pg_temp.u('d2'), 60), now() - interval '1 minute')$q$, 'has passed'),
    'FB1: a release time ahead';
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e3', jsonb_build_object(pg_temp.u('d4'), 100))$q$, 'Exos syncs with it'),
    'FB1: an Eventbrite primary needs no block';
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e4', '{}')$q$, '24 hours before doors has passed'),
    'FB1: the default release time passed';
  UPDATE public.exos_events SET total_tickets = 100 WHERE id = pg_temp.u('e1');
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', jsonb_build_object(pg_temp.u('d1'), 120, pg_temp.u('d2'), 60))$q$, 'the event total (100) is below the block (180)'),
    'FB1: the overall cap';
  UPDATE public.exos_events SET total_tickets = 0 WHERE id = pg_temp.u('e1');

  s := pg_temp.set_block('e1', jsonb_build_object(pg_temp.u('d1'), 120, pg_temp.u('d2'), 60));
  ASSERT (s ->> 'on')::boolean AND s ->> 'platform' = 'DICE' AND s ->> 'platform_url' = 'https://dice.fm/event/fb-club', 'FB1: on ' || s::text;
  ASSERT (s ->> 'release_at')::timestamptz = (SELECT doors_at - interval '24 hours' FROM public.exos_events WHERE id = pg_temp.u('e1')),
    'FB1: 24 hours before doors';
  ASSERT s -> 'release_at_set' = 'null'::jsonb AND (s -> 'totals' ->> 'block')::int = 180 AND (s ->> 'can_manage')::boolean, 'FB1: totals';
  ASSERT (SELECT primary_source FROM public.exos_events WHERE id = pg_temp.u('e1')) = 'external', 'FB1: the primary';
  ASSERT (SELECT capacity FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d2')) = 60, 'FB1: the block is the capacity';

  s := pg_temp.set_block('e2', jsonb_build_object(pg_temp.u('d3'), 40));
  ASSERT (s -> 'totals' ->> 'block')::int = 40, 'FB1: e2';
  s := pg_temp.set_block('e4', '{}', now() + interval '6 hours');
  ASSERT (s ->> 'release_at')::timestamptz = (s ->> 'release_at_set')::timestamptz, 'FB1: a set release time';

  -- A block type can't go unlimited; a new type needs a block too.
  ASSERT pg_temp.refused($q$UPDATE public.exos_ticket_tiers SET capacity = 0 WHERE id = pg_temp.u('d1')$q$, 'give "GA" a block size'),
    'FB1: no unlimited block';
  ASSERT pg_temp.refused($q$INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity) VALUES (pg_temp.u('e1'), 'Late', 40, 0)$q$, 'block size'),
    'FB1: a new type needs one';
  -- The primary moves through exos_set_fixed_block only.
  ASSERT pg_temp.refused($q$SELECT public.exos_set_resale_options(pg_temp.u('e1'), NULL, 'exos', NULL)$q$, 'fixed block for DICE'),
    'FB1: set_resale_options can''t move it';
  ASSERT (public.exos_set_resale_options(pg_temp.u('e1'), 8, NULL, NULL) ->> 'listing_qty')::int = 8, 'FB1: other options still save';
  -- Off and on again before the release.
  s := public.exos_set_fixed_block(pg_temp.u('e2'), false);
  ASSERT NOT (s ->> 'on')::boolean AND (SELECT primary_platform FROM public.exos_events WHERE id = pg_temp.u('e2')) IS NULL, 'FB1: off';
  s := pg_temp.set_block('e2', '{}');
  ASSERT (s ->> 'on')::boolean AND (s -> 'totals' ->> 'block')::int = 40, 'FB1: on again, the block kept';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  FB1 turning it on';
END $$;

-- FB2. Availability is exactly the block.
DO $$
DECLARE v_new uuid := gen_random_uuid();
BEGIN
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 120 AND public.exos_tier_available(pg_temp.u('d2')) = 60, 'FB2: the checkout count';
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 120, 'FB2: effective';
  ASSERT public._exos_primary_hold(pg_temp.u('d1'), 120) = 0, 'FB2: no primary hold';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e1')) = 180 AND public.exos_event_remaining(pg_temp.u('e1')) = 180, 'FB2: max / remaining';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_issue_ticket_to_email(pg_temp.u('e1'), pg_temp.u('d1'), 'box@x.com', 2, 'fb-bo-1');
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE event_id = pg_temp.u('e1') AND order_ref = 'fb-bo-1') = 2, 'FB2: Exos mints its block';
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 118, 'FB2: sold off the block';
  -- 20 more sold (checkout fulfilment).
  UPDATE public.exos_ticket_tiers SET sold = sold + 20 WHERE id = pg_temp.u('d1');
  UPDATE public.exos_ticket_tiers SET sold = 10 WHERE id = pg_temp.u('d2');
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 98, 'FB2: 120 - 22';
  -- A copied event starts unreleased, its release time following its own dates.
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, created_by, primary_source, primary_platform,
                                  block_release_at, block_released_at)
  VALUES (v_new, 'fb000000-0000-0000-0000-000000000001', 'Copy', 'fb-copy', 'draft', now() + interval '30 days',
          'fb000000-0000-0000-0000-0000000000a0', 'external', 'DICE', now() + interval '1 day', now());
  ASSERT (SELECT block_released_at IS NULL AND block_release_at IS NULL FROM public.exos_events WHERE id = v_new), 'FB2: a copy starts fresh';
  ASSERT public.exos_event_block_release_at(v_new) = (SELECT starts_at - interval '24 hours' FROM public.exos_events WHERE id = v_new), 'FB2: its own default';
  DELETE FROM public.exos_events WHERE id = v_new;
  RAISE NOTICE 'OK  FB2 availability is the block';
END $$;

-- FB3. The free-tier and resale gates read the block.
DO $$
BEGIN
  ASSERT public.exos_event_is_free_tier(pg_temp.u('e2')) AND NOT public.exos_resale_unlocked(pg_temp.u('e2')), 'FB3: 40 is the free tier';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT public.exos_set_resale_consent(pg_temp.u('e2'), true, '2026-10-29')$q$, 'free tier'), 'FB3: no opt-in on the free tier';
  ASSERT NOT public.exos_event_is_free_tier(pg_temp.u('e1')) AND NOT public.exos_resale_unlocked(pg_temp.u('e1')), 'FB3: 180 needs the opt-in';
  PERFORM public.exos_set_resale_consent(pg_temp.u('e1'), true, '2026-10-29');
  ASSERT public.exos_resale_unlocked(pg_temp.u('e1')), 'FB3: opted in';
  UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub'] WHERE id = pg_temp.u('e1');
  ASSERT public.exos_set_channel_allocation(pg_temp.u('e1'), 'stubhub', pg_temp.u('d2'), 10) = 10, 'FB3: part of the block on StubHub';
  PERFORM pg_temp.act(NULL);
  -- The pool holds 8 of its cap of 10 (two orders' worth) off Exos's count.
  ASSERT public.exos_channel_allocated(pg_temp.u('d2')) = 8 AND public.exos_tier_available(pg_temp.u('d2')) = 42,
    'FB3: 60 - 10 sold - 8 in the StubHub pool';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e1')) = 180, 'FB3: the pool is still the block';
  RAISE NOTICE 'OK  FB3 free tier and resale gates';
END $$;

-- FB4. Last call: Exos is the block's seller.
DO $$
DECLARE p record; v_pool uuid; s public.exos_public_event_sales;
BEGIN
  SELECT id INTO v_pool FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u('d2') AND channel = 'stubhub';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_last_call_threshold(pg_temp.u('e1'), 200);
  PERFORM pg_temp.act(NULL);
  ASSERT public.exos_event_last_call(pg_temp.u('e1')), 'FB4: last call (148 left of the block)';
  ASSERT NOT public.exos_last_call_closes(pg_temp.u('e1'), 'exos'), 'FB4: Exos is not closed';
  ASSERT public.exos_last_call_closes(pg_temp.u('e1'), 'stubhub') AND public.exos_last_call_closes(pg_temp.u('e1'), 'eventbrite'), 'FB4: the rest are';
  ASSERT public._exos_primary_hold(pg_temp.u('d1'), 98) = 0, 'FB4: no hold on Exos''s own block';
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 98, 'FB4: Exos still sells GA';
  SELECT * INTO p FROM public.exos_channel_pool_plan(v_pool);
  ASSERT p.target = 0 AND p.state = 'last_call', 'FB4: StubHub plans 0 ' || p::text;
  s := (SELECT x FROM public.exos_public_event_sales x WHERE x.event_id = pg_temp.u('e1'));
  ASSERT s.last_call AND s.sells_on = 'exos' AND s.sells_on_url IS NULL, 'FB4: the storefront sells on Exos ' || s::text;
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_issue_ticket_to_email(pg_temp.u('e1'), pg_temp.u('d1'), 'box2@x.com', 1, 'fb-bo-2');
  ASSERT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'fb-bo-2'), 'FB4: Exos mints at last call';
  PERFORM public.exos_set_last_call_threshold(pg_temp.u('e1'), NULL);
  PERFORM pg_temp.act(NULL);
  ASSERT NOT public.exos_event_last_call(pg_temp.u('e1')), 'FB4: off with the default (10)';
  RAISE NOTICE 'OK  FB4 last call keeps Exos selling its block';
END $$;

-- FB5. The scheduled release.
DO $$
DECLARE x public.exos_fixed_block_releases%ROWTYPE; s jsonb; v_hold uuid; p record; v_pool uuid; ga jsonb; vip jsonb;
BEGIN
  -- GA: 120, 23 sold, 2 in a checkout. VIP: 60, 10 sold, 10 on StubHub.
  INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, quantity, status, expires_at)
  VALUES (pg_temp.u('e1'), pg_temp.u('d1'), 'fb000000-0000-0000-0000-000000000001', 2, 'active', now() + interval '10 minutes')
  RETURNING id INTO v_hold;
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 95, 'FB5: 120 - 23 - 2';
  ASSERT public.exos_release_fixed_blocks() = 0, 'FB5: not before its time';
  ASSERT (SELECT block_released_at FROM public.exos_events WHERE id = pg_temp.u('e1')) IS NULL, 'FB5: still selling';

  UPDATE public.exos_events SET block_release_at = now() - interval '1 minute' WHERE id = pg_temp.u('e1');
  ASSERT public.exos_release_fixed_blocks() = 1, 'FB5: released';
  ASSERT public.exos_release_fixed_blocks() = 0, 'FB5: once';
  SELECT * INTO x FROM public.exos_fixed_block_releases WHERE event_id = pg_temp.u('e1');
  ASSERT x.reason = 'scheduled' AND x.released_by IS NULL AND x.platform = 'DICE', 'FB5: the record ' || row_to_json(x)::text;
  SELECT r INTO ga FROM jsonb_array_elements(x.tiers) r WHERE r ->> 'name' = 'GA';
  SELECT r INTO vip FROM jsonb_array_elements(x.tiers) r WHERE r ->> 'name' = 'VIP';
  ASSERT (ga ->> 'block')::int = 120 AND (ga ->> 'sold')::int = 23 AND (ga ->> 'pending')::int = 2 AND (ga ->> 'returned')::int = 95,
    'FB5: GA ' || ga::text;
  ASSERT (vip ->> 'block')::int = 60 AND (vip ->> 'sold')::int = 10 AND (vip ->> 'pending')::int = 0 AND (vip ->> 'returned')::int = 50,
    'FB5: VIP, the StubHub pool handed back ' || vip::text;
  ASSERT x.total_returned = 145 AND x.total_pending = 2, 'FB5: totals';

  -- Exos is closed; capacity is untouched (the fee and resale rules don't move).
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 0 AND public.exos_tier_available(pg_temp.u('d2')) = 0, 'FB5: nothing to sell';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e1')) = 180 AND public.exos_resale_unlocked(pg_temp.u('e1')), 'FB5: capacity kept';
  SELECT id INTO v_pool FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u('d2') AND channel = 'stubhub';
  SELECT * INTO p FROM public.exos_channel_pool_plan(v_pool);
  ASSERT p.target = 0 AND p.state = 'block_released', 'FB5: pool plan ' || p::text;
  ASSERT public.exos_channel_allocated(pg_temp.u('d2')) = 0, 'FB5: the pool is back';
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e1'))), 'FB5: no auto split';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT public.exos_issue_ticket_to_email(pg_temp.u('e1'), pg_temp.u('d1'), 'box3@x.com', 1, 'fb-bo-3')$q$, ''), 'FB5: box office';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.refused($q$SELECT pg_temp.mint('d1', 'fbv1', 'vibepass')$q$, 'the rest sells on DICE'), 'FB5: a voucher / comp mint';
  ASSERT pg_temp.refused($q$SELECT pg_temp.mint('d1', 'fbv2', 'referral_reward')$q$, 'released'), 'FB5: a referral reward';
  -- The held checkout completes; a marketplace sale that already happened lands.
  PERFORM pg_temp.mint('d1', 'fbs1', 'stripe');
  PERFORM pg_temp.mint('d2', 'fbm1', 'stubhub');
  DELETE FROM public.exos_tickets WHERE barcode_secret IN ('fbs1', 'fbm1');

  -- The mail: owner + manager, once, counts only.
  ASSERT x.mailed = 2, 'FB5: mailed ' || x.mailed;
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'fixed-block-released'
           AND payload -> 'event' ->> 'id' = pg_temp.u('e1')::text) = 2, 'FB5: two rows';
  ASSERT (SELECT array_agg(to_email ORDER BY to_email) FROM public.exos_mail WHERE template = 'fixed-block-released'
           AND payload -> 'event' ->> 'id' = pg_temp.u('e1')::text) = ARRAY['fb-manager@x.com', 'fb-owner@x.com'], 'FB5: not finance';
  ASSERT public._exos_queue_fixed_block_mail(pg_temp.u('e1')) = 0, 'FB5: never twice';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'fixed-block-released' AND payload::text LIKE '%box@x.com%'),
    'FB5: no buyer data';
  ASSERT (SELECT (payload ->> 'total_returned')::int FROM public.exos_mail WHERE template = 'fixed-block-released' LIMIT 1) = 145, 'FB5: the count';

  -- The checkout lapses: 2 more go back.
  UPDATE public.exos_cart_holds SET status = 'expired' WHERE id = v_hold;
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a2');
  s := public.exos_fixed_block_status(pg_temp.u('e1'));
  ASSERT s ->> 'released_at' IS NOT NULL AND (s -> 'release' ->> 'total_returned')::int = 145, 'FB5: finance sees it';
  ASSERT (s -> 'totals' ->> 'more_to_return')::int = 2, 'FB5: put back 2 more ' || (s -> 'totals')::text;
  ASSERT (SELECT (r ->> 'more_to_return')::int FROM jsonb_array_elements(s -> 'tiers') r WHERE r ->> 'name' = 'GA') = 2, 'FB5: on GA';
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 0, 'FB5: still closed';

  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT public.exos_set_fixed_block(pg_temp.u('e1'), false)$q$, 'stays off Exos'), 'FB5: no turning it off';
  ASSERT pg_temp.refused($q$SELECT pg_temp.set_block('e1', '{}', now() + interval '1 day')$q$, 'already released'), 'FB5: no editing';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  FB5 the scheduled release';
END $$;

-- FB6. Release now.
DO $$
DECLARE s jsonb; v_at timestamptz;
BEGIN
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a2');
  ASSERT pg_temp.refused($q$SELECT public.exos_release_fixed_block_now(pg_temp.u('e4'))$q$, 'not allowed'), 'FB6: finance can''t';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.refused($q$SELECT public.exos_release_fixed_block_now(pg_temp.u('e4'))$q$, 'not allowed'), 'FB6: a scanner can''t';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.refused($q$SELECT public.exos_release_fixed_block_now(pg_temp.u('e4'))$q$, 'not allowed'), 'FB6: a stranger can''t';
  ASSERT pg_temp.refused($q$SELECT public.exos_fixed_block_status(pg_temp.u('e4'))$q$, 'not allowed'), 'FB6: nor read it';
  PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.refused($q$SELECT public.exos_release_fixed_block_now(pg_temp.u('e5'))$q$, 'doesn''t sell a fixed block'), 'FB6: not a block event';
  UPDATE public.exos_ticket_tiers SET sold = 5 WHERE id = pg_temp.u('d5');
  s := public.exos_release_fixed_block_now(pg_temp.u('e4'));
  ASSERT (s -> 'release' ->> 'reason') = 'manual' AND (s -> 'release' ->> 'total_returned')::int = 45, 'FB6: released ' || s::text;
  ASSERT (SELECT released_by FROM public.exos_fixed_block_releases WHERE event_id = pg_temp.u('e4')) = pg_temp.u('a1'), 'FB6: who';
  v_at := (s -> 'release' ->> 'released_at')::timestamptz;
  s := public.exos_release_fixed_block_now(pg_temp.u('e4'));
  ASSERT (s -> 'release' ->> 'released_at')::timestamptz = v_at AND (s -> 'release' ->> 'total_returned')::int = 45, 'FB6: a second call changes nothing';
  PERFORM pg_temp.act(NULL);
  ASSERT public.exos_release_fixed_blocks() = 0, 'FB6: the cron leaves it';
  ASSERT (SELECT count(*) FROM public.exos_fixed_block_releases WHERE event_id = pg_temp.u('e4')) = 1, 'FB6: one record';
  ASSERT public.exos_tier_available(pg_temp.u('d5')) = 0, 'FB6: closed';
  -- A cancelled block event is left alone by the cron.
  UPDATE public.exos_events SET status = 'cancelled', block_release_at = NULL WHERE id = pg_temp.u('e2');
  UPDATE public.exos_events SET starts_at = now() - interval '1 hour' WHERE id = pg_temp.u('e2');
  ASSERT public.exos_release_fixed_blocks() = 0, 'FB6: not a cancelled one';
  RAISE NOTICE 'OK  FB6 release now';
END $$;

-- FB7. RLS and grants.
DO $$ BEGIN PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a2'); END $$;
SET ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_fixed_block_releases) = 2, 'FB7: finance reads its org''s';
END $$;
RESET ROLE;
DO $$ BEGIN PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a3'); END $$;
SET ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_fixed_block_releases) = 0, 'FB7: a scanner reads none';
END $$;
RESET ROLE;
DO $$ BEGIN PERFORM pg_temp.act('fb000000-0000-0000-0000-0000000000a4'); END $$;
SET ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_fixed_block_releases) = 0, 'FB7: a stranger reads none';
END $$;
RESET ROLE;
DO $$
DECLARE f text;
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_fixed_block_releases', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_fixed_block_releases', 'UPDATE')
     AND NOT has_table_privilege('authenticated', 'public.exos_fixed_block_releases', 'DELETE')
     AND NOT has_table_privilege('anon', 'public.exos_fixed_block_releases', 'SELECT'), 'FB7: table grants';
  FOREACH f IN ARRAY ARRAY['public.exos_event_fixed_block(uuid)', 'public.exos_event_block_release_at(uuid)',
                           'public.exos_event_block_closed(uuid)', 'public._exos_fixed_block_release(uuid,text,uuid)',
                           'public._exos_queue_fixed_block_mail(uuid)', 'public.exos_release_fixed_blocks(integer)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'FB7: service only: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_fixed_block_status(uuid)', 'public.exos_release_fixed_block_now(uuid)',
                           'public.exos_set_fixed_block(uuid,boolean,text,text,jsonb,timestamp with time zone)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'FB7: signed in, role-checked: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_tg_ticket_fixed_block()', 'public.exos_tg_tier_fixed_block()', 'public.exos_tg_event_fixed_block_new()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'FB7: trigger fn: ' || f;
  END LOOP;
  RAISE NOTICE 'OK  FB7 RLS and grants';
END $$;

ROLLBACK;
