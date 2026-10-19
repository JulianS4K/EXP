-- ============================================================================
-- Online events follow-ups (mig 20261019110000):
--   O1 an online event's wallet payload has no lat / lng (no geofence); an
--      in-person or hybrid one keeps them; format is in the payload
--   O2 org and venue calendars leave out noindex events; the event's own
--      calendar link still answers
-- Self-contained (BEGIN / ROLLBACK).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d8000000-0000-0000-0000-0000000000a1','oown@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d8000000-0000-0000-0000-000000000001','Online Org','online-org-stub','d8000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,total_tickets,created_by,format,noindex,venue_name) VALUES
  ('d8000000-0000-0000-0000-0000000000e1','d8000000-0000-0000-0000-000000000001','Live Stream','o-stream-stub','published',
   now() + interval '1 day', 0, 'd8000000-0000-0000-0000-0000000000a1', 'online', false, 'Pier 17'),
  ('d8000000-0000-0000-0000-0000000000e2','d8000000-0000-0000-0000-000000000001','Both Ways','o-hybrid-stub','published',
   now() + interval '2 days', 0, 'd8000000-0000-0000-0000-0000000000a1', 'hybrid', false, 'Pier 17'),
  ('d8000000-0000-0000-0000-0000000000e3','d8000000-0000-0000-0000-000000000001','Private Night','o-hidden-stub','published',
   now() + interval '3 days', 0, 'd8000000-0000-0000-0000-0000000000a1', 'in_person', true, 'Pier 17');
INSERT INTO public.exos_event_geo(event_id, query, status, place_id, lat, lng)
SELECT e, 'Pier 17', 'ok', 'pier17', 40.7057, -74.0018
  FROM unnest(ARRAY['d8000000-0000-0000-0000-0000000000e1','d8000000-0000-0000-0000-0000000000e2',
                    'd8000000-0000-0000-0000-0000000000e3']::uuid[]) e;
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
SELECT ('d8000000-0000-0000-0000-00000000c00' || i)::uuid, ('d8000000-0000-0000-0000-0000000000e' || i)::uuid,
       'd8000000-0000-0000-0000-000000000001', 'GA', 'd8000000-0000-0000-0000-0000000000a1',
       'd8000000-0000-0000-0000-0000000000a1', 'oown@x.com', 'active', 'sek-o' || i, 0, 'web-o' || i, 'stripe'
  FROM generate_series(1, 3) i;
INSERT INTO public.exos_wallet_passes(serial_number, ticket_id, owner_id)
SELECT 'exw' || repeat('d8', 15) || '0' || i, ('d8000000-0000-0000-0000-00000000c00' || i)::uuid,
       'd8000000-0000-0000-0000-0000000000a1'
  FROM generate_series(1, 3) i;

-- O1. Wallet payloads.
DO $$
DECLARE p jsonb;
BEGIN
  p := public._exos_wallet_payload('exw' || repeat('d8', 15) || '01');
  ASSERT p -> 'event' ->> 'format' = 'online', 'O1 format';
  ASSERT p -> 'event' -> 'lat' = 'null'::jsonb AND p -> 'event' -> 'lng' = 'null'::jsonb, format('O1 online has no location: %s', p -> 'event');
  p := public._exos_wallet_payload('exw' || repeat('d8', 15) || '02');
  ASSERT (p -> 'event' ->> 'lat')::float = 40.7057, 'O1 hybrid keeps the location';
  p := public._exos_wallet_payload('exw' || repeat('d8', 15) || '03');
  ASSERT (p -> 'event' ->> 'lng')::float = -74.0018 AND p -> 'event' ->> 'format' = 'in_person', 'O1 in person keeps it';
  RAISE NOTICE 'O1 ok: online passes carry no location';
END $$;

-- O2. Calendars.
DO $$
DECLARE f jsonb; ids text[];
BEGIN
  f := public.exos_calendar_public_feed('org', 'online-org-stub');
  SELECT array_agg(x ->> 'id' ORDER BY x ->> 'id') INTO ids FROM jsonb_array_elements(f -> 'events') x;
  ASSERT ids = ARRAY['d8000000-0000-0000-0000-0000000000e1', 'd8000000-0000-0000-0000-0000000000e2'],
         format('O2 org calendar without the noindex event: %s', ids);
  f := public.exos_calendar_public_feed('venue', 'place-pier17');
  SELECT array_agg(x ->> 'id' ORDER BY x ->> 'id') INTO ids FROM jsonb_array_elements(f -> 'events') x;
  ASSERT NOT ('d8000000-0000-0000-0000-0000000000e3' = ANY (ids)) AND cardinality(ids) = 2,
         format('O2 venue calendar without it: %s', ids);
  f := public.exos_calendar_public_feed('event', 'd8000000-0000-0000-0000-0000000000e3');
  ASSERT jsonb_array_length(f -> 'events') = 1, 'O2 its own link still answers';
  RAISE NOTICE 'O2 ok: org and venue calendars leave out noindex events';
END $$;

SELECT '*** online event follow-ups: ALL ASSERTIONS PASSED ***' AS result;
ROLLBACK;
