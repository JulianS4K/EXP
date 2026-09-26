-- ============================================================================
-- Marketplace event links (mig 20260926191000). Self-contained (1c prefix),
-- rolled back at the end.
--   L1 existing bridge_event_xref ids are backfilled into links (re-run safe)
--   L2 SeatGeek / TEvo / Automatiq links mirror into bridge_event_xref
--   L3 a marketplace event links to at most one Exos event; status/id agree
--   L4 staff link or reject by hand; the StubHub request is re-queued
--   L5 organizers can't write links directly; strangers can't use the RPC
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
  ('1c000000-0000-0000-0000-0000000000e1','1c000000-0000-0000-0000-000000000001','One','published','2027-01-01T02:00:00Z','Hall','{"city":"Austin"}',ARRAY['stubhub','seatgeek']),
  ('1c000000-0000-0000-0000-0000000000e2','1c000000-0000-0000-0000-000000000001','Two','published','2027-01-02T02:00:00Z','Hall','{"city":"Austin"}',NULL),
  ('1c000000-0000-0000-0000-0000000000e3','1c000000-0000-0000-0000-000000000001','Three','draft','2027-01-03T02:00:00Z','Hall',NULL,NULL);

-- L1 ---------------------------------------------------------------------------
INSERT INTO public.bridge_event_xref(exos_event_id, sg_event_id, tevo_event_id, aq_short_event_id, match_method)
VALUES ('1c000000-0000-0000-0000-0000000000e3', 9001, 3003, 'AQ3', 'venue_date');
\ir ../../supabase/migrations/20260926191000_exos_channel_event_links.sql
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.exos_channel_event_links
   WHERE event_id = '1c000000-0000-0000-0000-0000000000e3' AND status = 'linked' AND method = 'backfill'
     AND (channel, external_event_id) IN (('seatgeek','9001'),('evo','3003'),('automatiq','AQ3'));
  IF n <> 3 THEN RAISE EXCEPTION 'L1 FAIL: backfilled % of 3 links', n; END IF;
  RAISE NOTICE 'L1 ok: bridge_event_xref ids backfilled into links';
END $$;

-- L2 ---------------------------------------------------------------------------
INSERT INTO public.exos_channel_event_links(event_id,org_id,channel,status,external_event_id,method,confidence)
VALUES ('1c000000-0000-0000-0000-0000000000e1','1c000000-0000-0000-0000-000000000001','seatgeek','linked','17692085','auto_match',0.95);
DO $$
DECLARE x record;
BEGIN
  SELECT * INTO x FROM public.bridge_event_xref WHERE exos_event_id = '1c000000-0000-0000-0000-0000000000e1';
  IF x.sg_event_id IS DISTINCT FROM 17692085 OR x.match_method <> 'auto_match' OR x.matched_at IS NULL THEN
    RAISE EXCEPTION 'L2 FAIL: seatgeek link not mirrored: %', row_to_json(x);
  END IF;
END $$;
-- Back to review (staff unsure): the xref id is cleared.
UPDATE public.exos_channel_event_links SET status = 'review', external_event_id = NULL
 WHERE event_id = '1c000000-0000-0000-0000-0000000000e1' AND channel = 'seatgeek';
DO $$
BEGIN
  IF (SELECT sg_event_id FROM public.bridge_event_xref WHERE exos_event_id = '1c000000-0000-0000-0000-0000000000e1') IS NOT NULL THEN
    RAISE EXCEPTION 'L2 FAIL: unlinked seatgeek id left in bridge_event_xref';
  END IF;
  -- StubHub has no xref column: its links don't touch the xref.
  INSERT INTO public.exos_channel_event_links(event_id,org_id,channel,status,external_event_id,method)
  VALUES ('1c000000-0000-0000-0000-0000000000e2','1c000000-0000-0000-0000-000000000001','stubhub','linked','104857','auto_match');
  IF EXISTS (SELECT 1 FROM public.bridge_event_xref WHERE exos_event_id = '1c000000-0000-0000-0000-0000000000e2') THEN
    RAISE EXCEPTION 'L2 FAIL: stubhub link wrote bridge_event_xref';
  END IF;
  RAISE NOTICE 'L2 ok: links mirror into bridge_event_xref';
END $$;

-- L3 ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.exos_channel_event_links(event_id,org_id,channel,status,external_event_id)
    VALUES ('1c000000-0000-0000-0000-0000000000e1','1c000000-0000-0000-0000-000000000001','stubhub','linked','104857');
    RAISE EXCEPTION 'L3 FAIL: one StubHub event linked to two Exos events';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_channel_event_links(event_id,org_id,channel,status,external_event_id)
    VALUES ('1c000000-0000-0000-0000-0000000000e1','1c000000-0000-0000-0000-000000000001','vivid','linked',NULL);
    RAISE EXCEPTION 'L3 FAIL: linked without an id';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'L3 ok: one Exos event per marketplace event; status and id agree';
END $$;

-- L4 ---------------------------------------------------------------------------
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
    RAISE EXCEPTION 'L4 FAIL: linked an id held by another event';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e1','stubhub','1; drop table x');
    RAISE EXCEPTION 'L4 FAIL: accepted a junk id';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  r := public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e1','stubhub',' 222333 ');
  IF r <> 'linked' THEN RAISE EXCEPTION 'L4 FAIL: link returned %', r; END IF;
END $$;
RESET ROLE;
DO $$
DECLARE l record; d record;
BEGIN
  SELECT * INTO l FROM public.exos_channel_event_links WHERE event_id = '1c000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub';
  IF l.status <> 'linked' OR l.external_event_id <> '222333' OR l.method <> 'manual'
     OR l.decided_by <> '1c000000-0000-0000-0000-0000000000a0' THEN
    RAISE EXCEPTION 'L4 FAIL: manual link row wrong: %', row_to_json(l);
  END IF;
  SELECT * INTO d FROM public.exos_distribution_listings WHERE event_id = '1c000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub';
  IF d.status <> 'pending' OR d.error IS NOT NULL THEN
    RAISE EXCEPTION 'L4 FAIL: StubHub request not re-queued after the decision: %', row_to_json(d);
  END IF;
END $$;
SELECT set_config('app.uid','1c000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e1','seatgeek',NULL) <> 'rejected' THEN
    RAISE EXCEPTION 'L4 FAIL: reject did not return rejected';
  END IF;
  RAISE NOTICE 'L4 ok: staff link / reject by hand, StubHub request re-queued';
END $$;

-- L5 ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.exos_channel_event_links(event_id,org_id,channel)
    VALUES ('1c000000-0000-0000-0000-0000000000e2','1c000000-0000-0000-0000-000000000001','vivid');
    RAISE EXCEPTION 'L5 FAIL: organizer wrote exos_channel_event_links directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
SELECT set_config('app.uid','1c000000-0000-0000-0000-0000000000a9',true);
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_link_channel_event('1c000000-0000-0000-0000-0000000000e2','stubhub','999');
    RAISE EXCEPTION 'L5 FAIL: stranger linked an event';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'L5 ok: no direct writes; strangers refused';
END $$;
RESET ROLE;
ROLLBACK;
