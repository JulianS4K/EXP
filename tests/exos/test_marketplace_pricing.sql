-- ============================================================================
-- Organizer price per marketplace (mig 20260929052000). Self-contained (5c
-- prefix), rolled back at the end.
--   P1 owner/manager set a price above the ticket type's; blank (NULL) or the
--      same price follows the ticket type; finance / outsiders can't
--   P2 never below the Exos price: the RPC refuses, and the trigger refuses
--      any direct write (service role included)
--   P3 needs the allocation row (seats first); the ticket type must be the event's
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_marketplace_pricing.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5c000000-0000-0000-0000-0000000000a0','5c-owner@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000a1','5c-manager@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000a2','5c-finance@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5c000000-0000-0000-0000-000000000001','5C Org','5c-org','5c000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000a0','owner'),
  ('5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000a1','manager'),
  ('5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000a2','finance');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  ('5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','Price Show','published','2027-01-01T02:00:00Z','Hall',100,0,ARRAY['stubhub','vivid']),
  ('5c000000-0000-0000-0000-0000000000e2','5c000000-0000-0000-0000-000000000001','Other Show','published','2027-01-02T02:00:00Z','Hall',100,0,ARRAY['stubhub']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-0000000000e1','GA',50,40,0),
  ('5c000000-0000-0000-0000-0000000000d2','5c000000-0000-0000-0000-0000000000e1','VIP',120,40,0),
  ('5c000000-0000-0000-0000-0000000000d9','5c000000-0000-0000-0000-0000000000e2','GA',10,40,0);
SELECT public.exos_set_channel_allocation('5c000000-0000-0000-0000-0000000000e1','stubhub','5c000000-0000-0000-0000-0000000000d1',6);
SELECT public.exos_set_channel_allocation('5c000000-0000-0000-0000-0000000000e1','vivid','5c000000-0000-0000-0000-0000000000d1',6);

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.price(p_channel text) RETURNS numeric LANGUAGE sql AS $$
  SELECT unit_price FROM public.exos_distribution_listings
   WHERE event_id = '5c000000-0000-0000-0000-0000000000e1' AND channel = p_channel AND tier_id = '5c000000-0000-0000-0000-0000000000d1';
$$;

-- P1 -------------------------------------------------------------------------
SELECT pg_temp.as_user('5c000000-0000-0000-0000-0000000000a1', '5c-manager@x.com');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','stubhub','5c000000-0000-0000-0000-0000000000d1', 64.999) <> 65 THEN
    RAISE EXCEPTION 'P1 FAIL: price not rounded / returned';
  END IF;
  IF public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','vivid','5c000000-0000-0000-0000-0000000000d1', 50) <> 50 THEN
    RAISE EXCEPTION 'P1 FAIL: same price';
  END IF;
END $$;
RESET ROLE;
DO $$
BEGIN
  IF pg_temp.price('stubhub') <> 65 OR pg_temp.price('vivid') IS NOT NULL THEN
    RAISE EXCEPTION 'P1 FAIL: stored % / %', pg_temp.price('stubhub'), pg_temp.price('vivid');
  END IF;
END $$;
SELECT pg_temp.as_user('5c000000-0000-0000-0000-0000000000a0', '5c-owner@x.com');
SET LOCAL ROLE authenticated;
SELECT public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','stubhub','5c000000-0000-0000-0000-0000000000d1', NULL);
RESET ROLE;
DO $$
BEGIN
  IF pg_temp.price('stubhub') IS NOT NULL THEN RAISE EXCEPTION 'P1 FAIL: blank did not clear'; END IF;
END $$;
SELECT pg_temp.as_user('5c000000-0000-0000-0000-0000000000a2', '5c-finance@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','stubhub','5c000000-0000-0000-0000-0000000000d1', 80);
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  IF NOT refused THEN RAISE EXCEPTION 'P1 FAIL: finance set a price'; END IF;
  RAISE NOTICE 'P1 ok: owner/manager set, round and clear a marketplace price; finance cannot';
END $$;
RESET ROLE;

-- P2 -------------------------------------------------------------------------
SELECT pg_temp.as_user('5c000000-0000-0000-0000-0000000000a0', '5c-owner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE e text;
BEGIN
  BEGIN
    PERFORM public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','stubhub','5c000000-0000-0000-0000-0000000000d1', 49.99);
  EXCEPTION WHEN check_violation THEN e := SQLERRM;
  END;
  IF e IS NULL OR e NOT LIKE '%never undercut%' THEN RAISE EXCEPTION 'P2 FAIL: RPC let it undercut (%)', e; END IF;
END $$;
RESET ROLE;
DO $$
DECLARE e text;
BEGIN
  BEGIN
    UPDATE public.exos_distribution_listings SET unit_price = 10
     WHERE event_id = '5c000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub' AND tier_id = '5c000000-0000-0000-0000-0000000000d1';
  EXCEPTION WHEN check_violation THEN e := SQLERRM;
  END;
  IF e IS NULL THEN RAISE EXCEPTION 'P2 FAIL: a direct write undercut the Exos price'; END IF;
  -- Moving a priced row to a pricier ticket type is checked too.
  UPDATE public.exos_distribution_listings SET unit_price = 60
   WHERE event_id = '5c000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub' AND tier_id = '5c000000-0000-0000-0000-0000000000d1';
  e := NULL;
  BEGIN
    UPDATE public.exos_distribution_listings SET tier_id = '5c000000-0000-0000-0000-0000000000d2'
     WHERE event_id = '5c000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub' AND tier_id = '5c000000-0000-0000-0000-0000000000d1';
  EXCEPTION WHEN check_violation THEN e := SQLERRM;
  END;
  IF e IS NULL THEN RAISE EXCEPTION 'P2 FAIL: tier change let it undercut'; END IF;
  RAISE NOTICE 'P2 ok: below the Exos price is refused by the RPC and by the trigger';
END $$;

-- P3 -------------------------------------------------------------------------
SELECT pg_temp.as_user('5c000000-0000-0000-0000-0000000000a0', '5c-owner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE e text;
BEGIN
  BEGIN
    PERFORM public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','stubhub','5c000000-0000-0000-0000-0000000000d2', 150);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e NOT LIKE '%seats on that marketplace first%' THEN RAISE EXCEPTION 'P3 FAIL: no allocation (%)', e; END IF;
  e := NULL;
  BEGIN
    PERFORM public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','stubhub','5c000000-0000-0000-0000-0000000000d9', 150);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e NOT LIKE '%ticket type not found%' THEN RAISE EXCEPTION 'P3 FAIL: other event''s ticket type (%)', e; END IF;
  RAISE NOTICE 'P3 ok: seats first; only this event''s ticket types';
END $$;
RESET ROLE;

-- P4 -------------------------------------------------------------------------
-- A scheduled step in force is the Exos price: the floor follows it.
UPDATE public.exos_ticket_tiers
   SET price_schedule = jsonb_build_array(jsonb_build_object('startsAt', (now() - interval '1 day')::text, 'price', 70))
 WHERE id = '5c000000-0000-0000-0000-0000000000d1';
SELECT pg_temp.as_user('5c000000-0000-0000-0000-0000000000a0', '5c-owner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE e text;
BEGIN
  BEGIN
    PERFORM public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','vivid','5c000000-0000-0000-0000-0000000000d1', 65);
  EXCEPTION WHEN check_violation THEN e := SQLERRM;
  END;
  IF e IS NULL OR e NOT LIKE '%(70)%' THEN RAISE EXCEPTION 'P4 FAIL: undercut the scheduled price (%)', e; END IF;
  IF public.exos_set_channel_price('5c000000-0000-0000-0000-0000000000e1','vivid','5c000000-0000-0000-0000-0000000000d1', 75) <> 75 THEN
    RAISE EXCEPTION 'P4 FAIL: above the scheduled price';
  END IF;
  RAISE NOTICE 'P4 ok: the floor is the price Exos charges now (scheduled step)';
END $$;
RESET ROLE;

ROLLBACK;
