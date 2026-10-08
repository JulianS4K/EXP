-- ============================================================================
-- Online / hybrid events, what to bring, noindex (mig 20261005090000).
-- Self-contained (0e… prefix), rolled back at the end.
--   O1 format / what_to_bring / noindex defaults and checks
--   O2 the join-link table has no grants; only owner / manager set it
--   O3 holders (active / used) get the link; voided, transferred-away and
--      strangers don't; staff always do
--   O4 reveal window: "later" before the time, "ready" after; cancelled
--      events and in-person events hand out nothing
--   O5 the reminder mail carries what to bring + the online hint, never the link
--   O6 anon reads format / what_to_bring / noindex through exos_public_events,
--      and a second apply is a no-op
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_online_events.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('0e000000-0000-0000-0000-0000000000a0','oe-owner@x.com',now()),
  ('0e000000-0000-0000-0000-0000000000a1','oe-scanner@x.com',now()),
  ('0e000000-0000-0000-0000-0000000000a2','oe-holder@x.com',now()),
  ('0e000000-0000-0000-0000-0000000000a3','oe-voided@x.com',now()),
  ('0e000000-0000-0000-0000-0000000000a4','oe-stranger@x.com',now()),
  ('0e000000-0000-0000-0000-0000000000a5','oe-used@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('0e000000-0000-0000-0000-000000000001','OE Org','oe-org','0e000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('0e000000-0000-0000-0000-000000000001','0e000000-0000-0000-0000-0000000000a0','owner'),
  ('0e000000-0000-0000-0000-000000000001','0e000000-0000-0000-0000-0000000000a1','scanner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at) VALUES
  ('0e000000-0000-0000-0000-0000000000e1','0e000000-0000-0000-0000-000000000001','OE Stream','oe-stream','published',
   now() + interval '3 hours'),
  ('0e000000-0000-0000-0000-0000000000e2','0e000000-0000-0000-0000-000000000001','OE Club','oe-club','published',
   now() + interval '3 hours');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  ('0e000000-0000-0000-0000-0000000000d1','0e000000-0000-0000-0000-0000000000e1','GA',0,100),
  ('0e000000-0000-0000-0000-0000000000d2','0e000000-0000-0000-0000-0000000000e2','GA',0,100);
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref) VALUES
  ('0e000000-0000-0000-0000-0000000000c1','0e000000-0000-0000-0000-0000000000e1','0e000000-0000-0000-0000-000000000001',
   '0e000000-0000-0000-0000-0000000000d1','GA','0e000000-0000-0000-0000-0000000000a2','0e000000-0000-0000-0000-0000000000a2',
   'active',gen_random_uuid()::text,0,'oe-o1'),
  ('0e000000-0000-0000-0000-0000000000c2','0e000000-0000-0000-0000-0000000000e1','0e000000-0000-0000-0000-000000000001',
   '0e000000-0000-0000-0000-0000000000d1','GA','0e000000-0000-0000-0000-0000000000a3','0e000000-0000-0000-0000-0000000000a3',
   'voided',gen_random_uuid()::text,0,'oe-o2'),
  ('0e000000-0000-0000-0000-0000000000c3','0e000000-0000-0000-0000-0000000000e1','0e000000-0000-0000-0000-000000000001',
   '0e000000-0000-0000-0000-0000000000d1','GA','0e000000-0000-0000-0000-0000000000a5','0e000000-0000-0000-0000-0000000000a5',
   'used',gen_random_uuid()::text,0,'oe-o3'),
  ('0e000000-0000-0000-0000-0000000000c4','0e000000-0000-0000-0000-0000000000e2','0e000000-0000-0000-0000-000000000001',
   '0e000000-0000-0000-0000-0000000000d2','GA','0e000000-0000-0000-0000-0000000000a2','0e000000-0000-0000-0000-0000000000a2',
   'active',gen_random_uuid()::text,0,'oe-o4');

-- O1 ---------------------------------------------------------------------------
DO $$
DECLARE bad text;
BEGIN
  ASSERT (SELECT format = 'in_person' AND NOT noindex AND what_to_bring IS NULL FROM public.exos_events
           WHERE id = '0e000000-0000-0000-0000-0000000000e1'), 'O1: defaults';
  UPDATE public.exos_events SET format = 'online', what_to_bring = 'Headphones & a snack <3', noindex = true
   WHERE id = '0e000000-0000-0000-0000-0000000000e1';
  UPDATE public.exos_events SET format = 'hybrid' WHERE id = '0e000000-0000-0000-0000-0000000000e1';
  FOREACH bad IN ARRAY ARRAY[$s$format = 'virtual'$s$, $s$what_to_bring = repeat('x', 501)$s$] LOOP
    BEGIN
      EXECUTE 'UPDATE public.exos_events SET ' || bad || $w$ WHERE id = '0e000000-0000-0000-0000-0000000000e1'$w$;
      RAISE EXCEPTION 'O1: accepted %', bad;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
  END LOOP;
  RAISE NOTICE 'OK  O1 columns, defaults and checks';
END $$;

-- O2 ---------------------------------------------------------------------------
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['format','what_to_bring','noindex'] LOOP
    ASSERT has_column_privilege('anon', 'public.exos_events', c, 'SELECT'), 'O2: anon reads ' || c;
    ASSERT has_column_privilege('authenticated', 'public.exos_events', c, 'UPDATE'), 'O2: authenticated updates ' || c;
    ASSERT NOT has_column_privilege('anon', 'public.exos_events', c, 'UPDATE'), 'O2: anon may update ' || c;
  END LOOP;
  ASSERT NOT has_table_privilege('anon', 'public.exos_event_online', 'SELECT'), 'O2: anon reads join links';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_event_online', 'SELECT'), 'O2: authenticated reads join links';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_event_online', 'INSERT'), 'O2: authenticated writes join links';
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_online_access(uuid)', 'EXECUTE'), 'O2: anon calls access';
  ASSERT NOT has_function_privilege('anon', 'public.exos_set_event_online(uuid,text,text,integer)', 'EXECUTE'), 'O2: anon sets';
  RAISE NOTICE 'OK  O2 grants';
END $$;

SELECT set_config('app.uid','0e000000-0000-0000-0000-0000000000a1',true);   -- scanner: can't set
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_set_event_online('0e000000-0000-0000-0000-0000000000e1', 'https://stream.example.com/x', NULL, NULL);
    RAISE EXCEPTION 'O2: scanner set the join link';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.exos_event_online_staff('0e000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'O2: scanner read the staff view';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

SELECT set_config('app.uid','0e000000-0000-0000-0000-0000000000a0',true);   -- owner
SET LOCAL ROLE authenticated;
DO $$
DECLARE r record;
BEGIN
  BEGIN
    PERFORM public.exos_set_event_online('0e000000-0000-0000-0000-0000000000e1', 'http://stream.example.com/x', NULL, NULL);
    RAISE EXCEPTION 'O2: http link accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_event_online('0e000000-0000-0000-0000-0000000000e1', 'javascript:alert(1)', NULL, NULL);
    RAISE EXCEPTION 'O2: javascript link accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM public.exos_set_event_online('0e000000-0000-0000-0000-0000000000e1',
    '  https://stream.example.com/room?k=1  ', '  Passcode 4242 ', NULL);
  SELECT * INTO r FROM public.exos_event_online_staff('0e000000-0000-0000-0000-0000000000e1');
  ASSERT r.join_url = 'https://stream.example.com/room?k=1' AND r.join_note = 'Passcode 4242'
     AND r.reveal_minutes IS NULL, 'O2: owner sets and reads the link (trimmed)';
  -- Same call again updates in place.
  PERFORM public.exos_set_event_online('0e000000-0000-0000-0000-0000000000e1',
    'https://stream.example.com/room?k=2', 'Passcode 4242', NULL);
  ASSERT (SELECT count(*) FROM public.exos_event_online_staff('0e000000-0000-0000-0000-0000000000e1')) = 1, 'O2: one row';
  -- Blank removes it; set it back.
  PERFORM public.exos_set_event_online('0e000000-0000-0000-0000-0000000000e1', '  ', NULL, NULL);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_online_staff('0e000000-0000-0000-0000-0000000000e1')), 'O2: blank removes';
  PERFORM public.exos_set_event_online('0e000000-0000-0000-0000-0000000000e1',
    'https://stream.example.com/room?k=2', 'Passcode 4242', NULL);
  RAISE NOTICE 'OK  O2 only owner / manager set the link';
END $$;
RESET ROLE;

-- O3 ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.oe_access(p_uid uuid, p_event uuid) RETURNS record LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  PERFORM set_config('app.uid', p_uid::text, true);
  SELECT * INTO r FROM public.exos_event_online_access(p_event);
  RETURN r;
END $$;
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a2', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'ready' AND r.join_url = 'https://stream.example.com/room?k=2', 'O3: active holder gets the link';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a5', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'ready', 'O3: used ticket still gets the link';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a3', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'not_holder' AND r.join_url IS NULL, 'O3: voided ticket gets nothing';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a4', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'not_holder' AND r.join_url IS NULL, 'O3: stranger gets nothing';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a1', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'ready' AND r.join_url IS NOT NULL, 'O3: scanner (staff) gets the link';
  -- The holder transfers the ticket away (owner_id moves): access moves with it.
  UPDATE public.exos_tickets SET owner_id = '0e000000-0000-0000-0000-0000000000a4'
   WHERE id = '0e000000-0000-0000-0000-0000000000c1';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a2', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'not_holder', 'O3: original buyer loses it after a transfer';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a4', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'ready', 'O3: new holder gets it';
  UPDATE public.exos_tickets SET owner_id = '0e000000-0000-0000-0000-0000000000a2'
   WHERE id = '0e000000-0000-0000-0000-0000000000c1';
  RAISE NOTICE 'OK  O3 only current holders and staff get the link';
END $$;

-- O4 ---------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  -- Show 60 minutes before a start 3 hours away: held back for holders.
  UPDATE public.exos_event_online SET reveal_minutes = 60 WHERE event_id = '0e000000-0000-0000-0000-0000000000e1';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a2', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'later' AND r.join_url IS NULL AND r.join_note = 'Passcode 4242'
     AND abs(extract(epoch FROM r.available_at - (now() + interval '2 hours'))) < 5, 'O4: held back until reveal time';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a1', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'ready', 'O4: staff see it early';
  UPDATE public.exos_event_online SET reveal_minutes = 240 WHERE event_id = '0e000000-0000-0000-0000-0000000000e1';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a2', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'ready', 'O4: inside the window';
  -- An in-person event with a stray link hands nothing out.
  INSERT INTO public.exos_event_online(event_id, join_url) VALUES
    ('0e000000-0000-0000-0000-0000000000e2', 'https://stray.example.com/');
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a2', '0e000000-0000-0000-0000-0000000000e2')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'none' AND r.join_url IS NULL, 'O4: in-person event gives no link';
  -- Cancelled.
  UPDATE public.exos_events SET status = 'cancelled' WHERE id = '0e000000-0000-0000-0000-0000000000e1';
  SELECT * INTO r FROM pg_temp.oe_access('0e000000-0000-0000-0000-0000000000a2', '0e000000-0000-0000-0000-0000000000e1')
    AS (state text, join_url text, join_note text, available_at timestamptz);
  ASSERT r.state = 'cancelled' AND r.join_url IS NULL, 'O4: cancelled event gives no link';
  UPDATE public.exos_events SET status = 'published' WHERE id = '0e000000-0000-0000-0000-0000000000e1';
  RAISE NOTICE 'OK  O4 reveal window, in-person and cancelled';
END $$;

-- O5 ---------------------------------------------------------------------------
DO $$
DECLARE h text;
BEGIN
  IF to_regprocedure('public.exos_queue_event_reminder(uuid,uuid)') IS NULL THEN
    RAISE NOTICE 'O5: no reminder function in this schema, skipped';
    RETURN;
  END IF;
  PERFORM public.exos_queue_event_reminder('0e000000-0000-0000-0000-0000000000e1', NULL);
  SELECT html INTO h FROM public.exos_mail WHERE to_email = 'oe-holder@x.com' AND template = 'event-reminder'
   ORDER BY created_at DESC LIMIT 1;
  ASSERT h LIKE '%join link is on your ticket%', 'O5: online hint';
  ASSERT h LIKE '%What to bring:</strong> Headphones &amp; a snack &lt;3%', 'O5: what to bring, escaped';
  ASSERT h NOT LIKE '%stream.example.com%', 'O5: the link itself is never mailed';
  PERFORM public.exos_queue_event_reminder('0e000000-0000-0000-0000-0000000000e2', NULL);
  SELECT html INTO h FROM public.exos_mail WHERE to_email = 'oe-holder@x.com' AND template = 'event-reminder'
     AND subject LIKE '%OE Club%' ORDER BY created_at DESC LIMIT 1;
  ASSERT h NOT LIKE '%join link%' AND h NOT LIKE '%What to bring%', 'O5: in-person, nothing to bring: unchanged body';
  RAISE NOTICE 'OK  O5 reminder mail';
END $$;

-- O6 ---------------------------------------------------------------------------
SELECT to_regclass('public.exos_public_events') IS NULL AS need_stub_view \gset
\if :need_stub_view
  GRANT SELECT (id, name, status) ON public.exos_events TO anon, authenticated;
  CREATE VIEW public.exos_public_events WITH (security_invoker = true) AS
    SELECT id, name FROM public.exos_events WHERE status = 'published';
  GRANT SELECT ON public.exos_public_events TO anon, authenticated;
\endif
\ir ../../supabase/migrations/20261005090000_exos_online_events.sql
\ir ../../supabase/migrations/20261005090000_exos_online_events.sql
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM information_schema.columns
           WHERE table_schema = 'public' AND table_name = 'exos_public_events'
             AND column_name = 'what_to_bring') = 1, 'O6: view has what_to_bring once';
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'public' AND table_name = 'exos_public_events'
             AND column_name IN ('join_url', 'online_url')), 'O6: no join link in the view';
END $$;
SET LOCAL ROLE anon;
DO $$
DECLARE e record;
BEGIN
  SELECT format, what_to_bring, noindex INTO e FROM public.exos_public_events
   WHERE id = '0e000000-0000-0000-0000-0000000000e1';
  ASSERT e.format = 'hybrid' AND e.noindex AND e.what_to_bring LIKE 'Headphones%', 'O6: anon reads the new columns';
  RAISE NOTICE 'OK  O6 anon reads format / what_to_bring / noindex through exos_public_events';
END $$;
RESET ROLE;

ROLLBACK;
