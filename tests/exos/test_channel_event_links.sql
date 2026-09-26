-- ============================================================================
-- Marketplace event links (mig 20260926191000). Self-contained (1c prefix),
-- rolled back at the end.
--   L1 a marketplace event links to at most one Exos event; status/id agree
--   L2 staff link or reject by hand; the StubHub request is re-queued
--   L3 organizers can't write links directly; strangers can't use the RPC
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_channel_event_links.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('1c000000-0000-0000-0000-0000000000a0','1c-owner@x.com',now()),
  ('1c000000-0000-0000-0000-0000000000a9','1c-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('1c000000-0000-0000-0000-000000000001','1C Org','1c-org','1c000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('1c000000-0000-0000-0000-000000000001','1c000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,venue_address,distribution_networks) VALUES
  ('1c000000-0000-0000-0000-0000000000e1','1c000000-0000-0000-0000-000000000001','One','published','2027-01-01T02:00:00Z','Hall','{"city":"Austin"}',ARRAY['stubhub']),
  ('1c000000-0000-0000-0000-0000000000e2','1c000000-0000-0000-0000-000000000001','Two','published','2027-01-02T02:00:00Z','Hall','{"city":"Austin"}',NULL),
  ('1c000000-0000-0000-0000-0000000000e3','1c000000-0000-0000-0000-000000000001','Three','draft','2027-01-03T02:00:00Z','Hall',NULL,NULL);

INSERT INTO public.exos_channel_event_links(event_id,org_id,channel,status,external_event_id,method)
VALUES ('1c000000-0000-0000-0000-0000000000e2','1c000000-0000-0000-0000-000000000001','stubhub','linked','104857','auto_match');

-- L1 ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.exos_channel_event_links(event_id,org_id,channel,status,external_event_id)
    VALUES ('1c000000-0000-0000-0000-0000000000e1','1c000000-0000-0000-0000-000000000001','stubhub','linked','104857');
    RAISE EXCEPTION 'L1 FAIL: one StubHub event linked to two Exos events';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_channel_event_links(event_id,org_id,channel,status,external_event_id)
    VALUES ('1c000000-0000-0000-0000-0000000000e1','1c000000-0000-0000-0000-000000000001','vivid','linked',NULL);
    RAISE EXCEPTION 'L1 FAIL: linked without an id';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'L1 ok: one Exos event per marketplace event; status and id agree';
END $$;

-- L2 ---------------------------------------------------------------------------
-- e1 is published with StubHub, so it has a queued request; say it failed on review.
UPDATE public.exos_distribution_listings SET status = 'failed', error = 'possible StubHub matches need a decision'
 WHERE event_id = '1c000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub';
SELECT set_config('app.uid','1c000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE r text;
BEGIN
  -- Can't take an id another event holds.
  BEGIN
    PERFORM public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e1','stubhub','104857');
    RAISE EXCEPTION 'L2 FAIL: linked an id held by another event';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e1','stubhub','1; drop table x');
    RAISE EXCEPTION 'L2 FAIL: accepted a junk id';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  r := public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e1','stubhub',' 222333 ');
  IF r <> 'linked' THEN RAISE EXCEPTION 'L2 FAIL: link returned %', r; END IF;
END $$;
RESET ROLE;
DO $$
DECLARE l record; d record;
BEGIN
  SELECT * INTO l FROM public.exos_channel_event_links WHERE event_id = '1c000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub';
  IF l.status <> 'linked' OR l.external_event_id <> '222333' OR l.method <> 'manual'
     OR l.decided_by <> '1c000000-0000-0000-0000-0000000000a0' THEN
    RAISE EXCEPTION 'L2 FAIL: manual link row wrong: %', row_to_json(l);
  END IF;
  SELECT * INTO d FROM public.exos_distribution_listings WHERE event_id = '1c000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub';
  IF d.status <> 'pending' OR d.error IS NOT NULL THEN
    RAISE EXCEPTION 'L2 FAIL: StubHub request not re-queued after the decision: %', row_to_json(d);
  END IF;
END $$;
SELECT set_config('app.uid','1c000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e1','stubhub',NULL) <> 'rejected' THEN
    RAISE EXCEPTION 'L2 FAIL: reject did not return rejected';
  END IF;
  RAISE NOTICE 'L2 ok: staff link / reject by hand, StubHub request re-queued';
END $$;

-- L3 ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.exos_channel_event_links(event_id,org_id,channel)
    VALUES ('1c000000-0000-0000-0000-0000000000e2','1c000000-0000-0000-0000-000000000001','vivid');
    RAISE EXCEPTION 'L3 FAIL: organizer wrote exos_channel_event_links directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
SELECT set_config('app.uid','1c000000-0000-0000-0000-0000000000a9',true);
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e2','stubhub','999');
    RAISE EXCEPTION 'L3 FAIL: stranger linked an event';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'L3 ok: no direct writes; strangers refused';
END $$;
RESET ROLE;
ROLLBACK;
