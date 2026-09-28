-- ============================================================================
-- Scanner event scope on the real roster + barcode-secret view (mig
-- 20260929041000; run_lifecycle.sh chain). The check-in RPC side is in
-- test_door_hardening.sql (run_p0.sh).
-- Self-contained (BEGIN / ROLLBACK). Org d1…01, owner …a1, scanner …a3,
-- holder …a5; events …e1 and …e2, one ticket each.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d1000000-0000-0000-0000-0000000000a1','d1own@x',now()),
  ('d1000000-0000-0000-0000-0000000000a3','d1scan@x',now()),
  ('d1000000-0000-0000-0000-0000000000a5','d1hold@x',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d1000000-0000-0000-0000-000000000001','Scope Org','scope-org','d1000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a1','owner'),
  ('d1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a3','scanner');
INSERT INTO public.exos_events(id,org_id,name,status) VALUES
  ('d1000000-0000-0000-0000-0000000000e1','d1000000-0000-0000-0000-000000000001','Scope One','published'),
  ('d1000000-0000-0000-0000-0000000000e2','d1000000-0000-0000-0000-000000000001','Scope Two','published');
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,status,barcode_secret) VALUES
  ('d1000000-0000-0000-0000-00000000c001','d1000000-0000-0000-0000-0000000000e1','d1000000-0000-0000-0000-000000000001',
   'd1000000-0000-0000-0000-0000000000a5','d1000000-0000-0000-0000-0000000000a5','active','sek-1'),
  ('d1000000-0000-0000-0000-00000000c002','d1000000-0000-0000-0000-0000000000e2','d1000000-0000-0000-0000-000000000001',
   'd1000000-0000-0000-0000-0000000000a5','d1000000-0000-0000-0000-0000000000a5','active','sek-2');

DO $$
DECLARE
  org uuid := 'd1000000-0000-0000-0000-000000000001';
  e1 uuid := 'd1000000-0000-0000-0000-0000000000e1';
  e2 uuid := 'd1000000-0000-0000-0000-0000000000e2';
  scan uuid := 'd1000000-0000-0000-0000-0000000000a3';
  raised boolean;
BEGIN
  -- Unrestricted scanner: both rosters, both secrets.
  PERFORM set_config('app.uid', scan::text, true);
  ASSERT (SELECT count(*) FROM public.exos_event_checkin_roster(e2)) = 1, 'S1: org-wide scanner reads e2';
  ASSERT (SELECT count(*) FROM public.exos_ticket_barcode_secrets
           WHERE ticket_id IN ('d1000000-0000-0000-0000-00000000c001','d1000000-0000-0000-0000-00000000c002')) = 2,
         'S1: org-wide scanner reads both secrets';

  -- The owner limits the scanner to e1.
  PERFORM set_config('app.uid', 'd1000000-0000-0000-0000-0000000000a1', true);
  ASSERT public.exos_set_scanner_events(org, scan, ARRAY[e1]) = 1, 'S2: limited to e1';

  PERFORM set_config('app.uid', scan::text, true);
  ASSERT (SELECT count(*) FROM public.exos_event_checkin_roster(e1)) = 1, 'S2: e1 roster still readable';
  raised := false;
  BEGIN PERFORM * FROM public.exos_event_checkin_roster(e2);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'S2: e2 roster refused';
  ASSERT (SELECT array_agg(ticket_id) FROM public.exos_ticket_barcode_secrets
           WHERE ticket_id IN ('d1000000-0000-0000-0000-00000000c001','d1000000-0000-0000-0000-00000000c002'))
         = ARRAY['d1000000-0000-0000-0000-00000000c001'::uuid], 'S2: only e1''s secret';

  -- The owner is never limited; the holder still reads their own secret.
  PERFORM set_config('app.uid', 'd1000000-0000-0000-0000-0000000000a1', true);
  ASSERT (SELECT count(*) FROM public.exos_event_checkin_roster(e2)) = 1, 'S3: owner reads e2';
  PERFORM set_config('app.uid', 'd1000000-0000-0000-0000-0000000000a5', true);
  ASSERT (SELECT count(*) FROM public.exos_ticket_barcode_secrets
           WHERE ticket_id = 'd1000000-0000-0000-0000-00000000c002') = 1, 'S3: holder reads own secret';
  RAISE NOTICE 'OK  scanner event scope (roster + barcode-secret view)';
END $$;

ROLLBACK;
