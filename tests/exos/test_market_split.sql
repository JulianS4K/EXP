-- ============================================================================
-- Marketplace split policy per ticket type (mig 20260929061000). 7d prefix,
-- rolled back.
--   D1 new ticket types default to 'any'
--   D2 the four policies are accepted; anything else is refused
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('7d000000-0000-0000-0000-0000000000a0','7d-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('7d000000-0000-0000-0000-000000000001','7D Org','7d-org','7d000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,currency) VALUES
  ('7d000000-0000-0000-0000-0000000000e1','7d000000-0000-0000-0000-000000000001','7D Show','7d-show','draft',now() + interval '5 days','Hall',100,'usd');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  ('7d000000-0000-0000-0000-0000000000d1','7d000000-0000-0000-0000-0000000000e1','GA',40,100);

DO $$
DECLARE v text;
BEGIN
  SELECT market_split INTO v FROM public.exos_ticket_tiers WHERE id = '7d000000-0000-0000-0000-0000000000d1';
  IF v IS DISTINCT FROM 'any' THEN RAISE EXCEPTION 'D1 FAIL: default is %', v; END IF;
  RAISE NOTICE 'D1 PASS: default any';

  UPDATE public.exos_ticket_tiers SET market_split = 'pairs' WHERE id = '7d000000-0000-0000-0000-0000000000d1';
  UPDATE public.exos_ticket_tiers SET market_split = 'no_single' WHERE id = '7d000000-0000-0000-0000-0000000000d1';
  UPDATE public.exos_ticket_tiers SET market_split = 'together' WHERE id = '7d000000-0000-0000-0000-0000000000d1';
  BEGIN
    UPDATE public.exos_ticket_tiers SET market_split = 'Pairs' WHERE id = '7d000000-0000-0000-0000-0000000000d1';
    RAISE EXCEPTION 'D2 FAIL: a marketplace spelling was accepted';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'D2 PASS: only the four Exos policies';
  END;
END $$;
ROLLBACK;
