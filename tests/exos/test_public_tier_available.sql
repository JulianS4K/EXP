-- ============================================================================
-- exos_public_tiers readable by visitors again (mig 20261027080000).
-- Self-contained (b7 prefix), rolled back.
--   P1 anon and authenticated can `select *` the view (the 2026-10-28 outage:
--      permission denied for function exos_effective_available)
--   P2 `available` is the effective availability for a public tier
--   P3 the wrapper answers NULL for a hidden tier and an unpublished event's
--      tier (no hidden-tier stock leak); exos_effective_available stays
--      service role only
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('b7000000-0000-0000-0000-0000000000a1','b7@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('b7000000-0000-0000-0000-000000000001','B7 Org','b7-org','b7000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,total_tickets) VALUES
  ('b7000000-0000-0000-0000-0000000000e1','b7000000-0000-0000-0000-000000000001','B7 Live','b7-live','published',now() + interval '9 days',100),
  ('b7000000-0000-0000-0000-0000000000e2','b7000000-0000-0000-0000-000000000001','B7 Draft','b7-draft','draft',now() + interval '9 days',100);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('b7000000-0000-0000-0000-0000000000d1','b7000000-0000-0000-0000-0000000000e1','GA',30,100,40,'public'),
  ('b7000000-0000-0000-0000-0000000000d2','b7000000-0000-0000-0000-0000000000e1','Secret',10,50,0,'hidden'),
  ('b7000000-0000-0000-0000-0000000000d3','b7000000-0000-0000-0000-0000000000e2','Draft GA',30,100,0,'public');

-- P1 + P2: read the view as the browser roles.
SET ROLE anon;
DO $$
DECLARE r record; n int;
BEGIN
  SELECT count(*) INTO n FROM public.exos_public_tiers WHERE event_id::text LIKE 'b7%';
  ASSERT n = 1, 'P1 FAIL: anon sees ' || n || ' tiers';
  SELECT * INTO r FROM public.exos_public_tiers WHERE id = 'b7000000-0000-0000-0000-0000000000d1';
  ASSERT r.available IS NOT DISTINCT FROM public.exos_public_tier_available(r.id), 'P2 FAIL';
  RAISE NOTICE 'OK  P1 anon reads exos_public_tiers (available = %)', r.available;
END $$;
RESET ROLE;
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM * FROM public.exos_public_tiers WHERE event_id::text LIKE 'b7%';
  RAISE NOTICE 'OK  P1 authenticated reads exos_public_tiers';
END $$;
RESET ROLE;

DO $$
BEGIN
  ASSERT public.exos_public_tier_available('b7000000-0000-0000-0000-0000000000d1')
         IS NOT DISTINCT FROM public.exos_effective_available('b7000000-0000-0000-0000-0000000000d1'),
    'P2 FAIL: wrapper differs from exos_effective_available';
  RAISE NOTICE 'OK  P2 public tier: same as exos_effective_available';

  -- P3
  ASSERT public.exos_public_tier_available('b7000000-0000-0000-0000-0000000000d2') IS NULL, 'P3 FAIL: hidden tier stock';
  ASSERT public.exos_public_tier_available('b7000000-0000-0000-0000-0000000000d3') IS NULL, 'P3 FAIL: draft event stock';
  ASSERT public.exos_public_tier_available(gen_random_uuid()) IS NULL, 'P3 FAIL: unknown tier';
  ASSERT NOT has_function_privilege('anon', 'public.exos_effective_available(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_effective_available(uuid)', 'EXECUTE'),
    'P3 FAIL: exos_effective_available is client-callable';
  RAISE NOTICE 'OK  P3 no hidden or draft stock; the inner helper stays internal';
END $$;

SELECT '*** PUBLIC TIER AVAILABLE PASSED ***' AS result;
ROLLBACK;
