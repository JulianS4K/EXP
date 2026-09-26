-- ============================================================================
-- StubHub event request queue (mig 20260926190000). Self-contained (5b
-- prefix), rolled back at the end.
--   S1 publishing with StubHub queues one 'stubhub' row, as the organizer
--      (who can't write the table directly)
--   S2 drafts, other networks and primary-market-only queue nothing
--   S3 editing re-queues a planned/failed row, and never touches one that
--      reached StubHub
--   S4 unticking / unpublishing removes an unsent row, keeps a sent one
--   S5 status 'planned' + planned_request are accepted; unknown status isn't
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_stubhub_event_request.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5b000000-0000-0000-0000-0000000000a0','5b-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5b000000-0000-0000-0000-000000000001','5B Org','5b-org','5b000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5b000000-0000-0000-0000-000000000001','5b000000-0000-0000-0000-0000000000a0','owner');
-- Organizers write exos_events directly (RLS in prod); the stub has no policy,
-- so grant the write for this transaction only.
GRANT SELECT, INSERT, UPDATE ON public.exos_events TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.sh_rows(p_event uuid) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.exos_distribution_listings WHERE event_id = p_event AND channel = 'stubhub'
$$;
CREATE OR REPLACE FUNCTION pg_temp.sh_status(p_event uuid) RETURNS text LANGUAGE sql AS $$
  SELECT status FROM public.exos_distribution_listings WHERE event_id = p_event AND channel = 'stubhub'
$$;

-- S1 ---------------------------------------------------------------------------
SELECT set_config('app.uid','5b000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,venue_address,distribution_networks,exclusivity) VALUES
  ('5b000000-0000-0000-0000-0000000000e1','5b000000-0000-0000-0000-000000000001','Live','published','2027-01-01T02:00:00Z',
   'Hall','{"city":"Austin","region":"TX","country":"US"}',ARRAY['stubhub','seatgeek'],'{"primaryMarketOnly":false}'),
  ('5b000000-0000-0000-0000-0000000000e2','5b000000-0000-0000-0000-000000000001','Draft','draft','2027-01-01T02:00:00Z',
   'Hall',NULL,ARRAY['stubhub'],NULL),
  ('5b000000-0000-0000-0000-0000000000e3','5b000000-0000-0000-0000-000000000001','Other nets','published','2027-01-01T02:00:00Z',
   'Hall',NULL,ARRAY['seatgeek','vivid'],NULL),
  ('5b000000-0000-0000-0000-0000000000e4','5b000000-0000-0000-0000-000000000001','Primary only','published','2027-01-01T02:00:00Z',
   'Hall',NULL,ARRAY['stubhub'],'{"primaryMarketOnly":true}'),
  ('5b000000-0000-0000-0000-0000000000e5','5b000000-0000-0000-0000-000000000001','No nets','published','2027-01-01T02:00:00Z',
   'Hall',NULL,NULL,NULL);
DO $$
BEGIN
  -- The organizer has no direct write on the queue table.
  BEGIN
    INSERT INTO public.exos_distribution_listings(event_id,org_id,channel)
    VALUES ('5b000000-0000-0000-0000-0000000000e3','5b000000-0000-0000-0000-000000000001','stubhub');
    RAISE EXCEPTION 'S1 FAIL: organizer inserted into exos_distribution_listings';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM public.exos_distribution_listings WHERE event_id = '5b000000-0000-0000-0000-0000000000e1';
  IF r IS NULL OR r.channel <> 'stubhub' OR r.status <> 'pending' OR r.org_id <> '5b000000-0000-0000-0000-000000000001'
     OR r.requested_qty IS NOT NULL OR r.external_event_id IS NOT NULL THEN
    RAISE EXCEPTION 'S1 FAIL: expected one pending stubhub row, got %', row_to_json(r);
  END IF;
  -- seatgeek is ticked too, but only StubHub has an event request today.
  IF (SELECT count(*) FROM public.exos_distribution_listings WHERE event_id = '5b000000-0000-0000-0000-0000000000e1') <> 1 THEN
    RAISE EXCEPTION 'S1 FAIL: rows for channels other than stubhub';
  END IF;
  RAISE NOTICE 'S1 ok: publish with StubHub queues one row, as the organizer';
END $$;

-- S2 ---------------------------------------------------------------------------
DO $$
BEGIN
  IF pg_temp.sh_rows('5b000000-0000-0000-0000-0000000000e2') <> 0 THEN RAISE EXCEPTION 'S2 FAIL: draft queued'; END IF;
  IF pg_temp.sh_rows('5b000000-0000-0000-0000-0000000000e3') <> 0 THEN RAISE EXCEPTION 'S2 FAIL: no-stubhub event queued'; END IF;
  IF pg_temp.sh_rows('5b000000-0000-0000-0000-0000000000e4') <> 0 THEN RAISE EXCEPTION 'S2 FAIL: primary-only event queued'; END IF;
  IF pg_temp.sh_rows('5b000000-0000-0000-0000-0000000000e5') <> 0 THEN RAISE EXCEPTION 'S2 FAIL: null networks queued'; END IF;
  RAISE NOTICE 'S2 ok: drafts, other networks and primary-market-only queue nothing';
END $$;
-- Publishing the draft later queues it.
UPDATE public.exos_events SET status = 'published' WHERE id = '5b000000-0000-0000-0000-0000000000e2';
DO $$
BEGIN
  IF pg_temp.sh_status('5b000000-0000-0000-0000-0000000000e2') IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'S2 FAIL: publishing a draft did not queue it';
  END IF;
  RAISE NOTICE 'S2 ok: publishing a draft queues it';
END $$;

-- S3 ---------------------------------------------------------------------------
-- exos-distribute planned it (dry-run); an edit re-queues it and clears the plan.
UPDATE public.exos_distribution_listings
   SET status = 'planned', planned_request = '{"endpoint":"createSellerEvent"}'
 WHERE event_id = '5b000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub';
UPDATE public.exos_events SET name = 'Live (late show)' WHERE id = '5b000000-0000-0000-0000-0000000000e1';
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM public.exos_distribution_listings WHERE event_id = '5b000000-0000-0000-0000-0000000000e1';
  IF r.status <> 'pending' OR r.planned_request IS NOT NULL THEN
    RAISE EXCEPTION 'S3 FAIL: edit did not re-queue the planned row: %', row_to_json(r);
  END IF;
END $$;
-- A failed row (e.g. no venue city) is re-queued once the organizer fixes the event.
UPDATE public.exos_distribution_listings SET status = 'failed', error = 'venue city is required'
 WHERE event_id = '5b000000-0000-0000-0000-0000000000e2';
UPDATE public.exos_events SET venue_address = '{"city":"Austin"}' WHERE id = '5b000000-0000-0000-0000-0000000000e2';
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM public.exos_distribution_listings WHERE event_id = '5b000000-0000-0000-0000-0000000000e2';
  IF r.status <> 'pending' OR r.error IS NOT NULL THEN
    RAISE EXCEPTION 'S3 FAIL: fixed event not re-queued: %', row_to_json(r);
  END IF;
END $$;
-- Once StubHub has the event, edits leave the row alone.
UPDATE public.exos_distribution_listings SET status = 'listed', external_event_id = 'sh-123'
 WHERE event_id = '5b000000-0000-0000-0000-0000000000e1';
UPDATE public.exos_events SET starts_at = '2027-01-02T02:00:00Z' WHERE id = '5b000000-0000-0000-0000-0000000000e1';
DO $$
BEGIN
  IF pg_temp.sh_status('5b000000-0000-0000-0000-0000000000e1') <> 'listed' THEN
    RAISE EXCEPTION 'S3 FAIL: edit touched a row StubHub already has';
  END IF;
  RAISE NOTICE 'S3 ok: edits re-queue unsent rows, never sent ones';
END $$;

-- S4 ---------------------------------------------------------------------------
UPDATE public.exos_events SET distribution_networks = ARRAY['seatgeek'] WHERE id = '5b000000-0000-0000-0000-0000000000e2';
UPDATE public.exos_events SET status = 'cancelled' WHERE id = '5b000000-0000-0000-0000-0000000000e1';
DO $$
BEGIN
  IF pg_temp.sh_rows('5b000000-0000-0000-0000-0000000000e2') <> 0 THEN
    RAISE EXCEPTION 'S4 FAIL: unticking StubHub kept the unsent row';
  END IF;
  IF pg_temp.sh_status('5b000000-0000-0000-0000-0000000000e1') <> 'listed' THEN
    RAISE EXCEPTION 'S4 FAIL: cancelling removed a row StubHub already has';
  END IF;
  RAISE NOTICE 'S4 ok: unsent rows go away, sent ones stay for a human';
END $$;
-- Primary-market-only removes it too.
UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub'] WHERE id = '5b000000-0000-0000-0000-0000000000e2';
UPDATE public.exos_events SET exclusivity = '{"primaryMarketOnly":true}' WHERE id = '5b000000-0000-0000-0000-0000000000e2';
DO $$
BEGIN
  IF pg_temp.sh_rows('5b000000-0000-0000-0000-0000000000e2') <> 0 THEN
    RAISE EXCEPTION 'S4 FAIL: primary-market-only kept the unsent row';
  END IF;
END $$;

-- S5 ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    UPDATE public.exos_distribution_listings SET status = 'sent-maybe'
     WHERE event_id = '5b000000-0000-0000-0000-0000000000e1';
    RAISE EXCEPTION 'S5 FAIL: unknown status accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'S5 ok: status vocabulary enforced';
END $$;

ROLLBACK;
