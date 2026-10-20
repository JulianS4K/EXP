-- ============================================================================
-- Organizer P1 (mig 20261021110000):
--   O1 draft → published → draft and other edits work as before
--   O2 a cancelled event can't go back to published or draft (any caller,
--      the service role included); its other columns still save, and a save
--      that re-sends status = 'cancelled' is fine
--   O3 exos_org_payments_ready: false with no Stripe account, true once
--      chargesEnabled; refused for a non-member and signed out
-- Self-contained (BEGIN / ROLLBACK).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- The p0 chain has no phase-1 secrets sidecar; the readiness check reads it.
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id uuid PRIMARY KEY, payments jsonb, distribution jsonb);

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a9300000-0000-0000-0000-0000000000a1','op1own@x.test',now()),
  ('a9300000-0000-0000-0000-0000000000a2','op1mgr@x.test',now()),
  ('a9300000-0000-0000-0000-0000000000a9','op1out@x.test',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a9300000-0000-0000-0000-000000000001','Org P1','org-p1-stub','a9300000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a9300000-0000-0000-0000-000000000001','a9300000-0000-0000-0000-0000000000a1','owner'),
  ('a9300000-0000-0000-0000-000000000001','a9300000-0000-0000-0000-0000000000a2','manager');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by) VALUES
  ('a9300000-0000-0000-0000-0000000000e1','a9300000-0000-0000-0000-000000000001','Show','org-p1-show','draft',
   now() + interval '10 days', 'UTC', 100, 0, 'a9300000-0000-0000-0000-0000000000a1');

CREATE FUNCTION pg_temp.act(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, false),
         set_config('app.jwt', json_build_object('email', p_email, 'role', 'authenticated')::text, false);
$$;
CREATE FUNCTION pg_temp.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'ok'; EXCEPTION WHEN others THEN RETURN SQLSTATE || ' ' || SQLERRM; END $$;

DO $$
DECLARE r text; s text;
BEGIN
  -- O1. The ordinary lifecycle.
  UPDATE public.exos_events SET status = 'published' WHERE id = 'a9300000-0000-0000-0000-0000000000e1';
  UPDATE public.exos_events SET status = 'draft' WHERE id = 'a9300000-0000-0000-0000-0000000000e1';
  UPDATE public.exos_events SET status = 'published', name = 'Show!' WHERE id = 'a9300000-0000-0000-0000-0000000000e1';
  SELECT status INTO s FROM public.exos_events WHERE id = 'a9300000-0000-0000-0000-0000000000e1';
  IF s <> 'published' THEN RAISE EXCEPTION 'O1: expected published, got %', s; END IF;

  -- O2. Cancel, then try to bring it back.
  UPDATE public.exos_events SET status = 'cancelled' WHERE id = 'a9300000-0000-0000-0000-0000000000e1';
  r := pg_temp.try($q$UPDATE public.exos_events SET status = 'published' WHERE id = 'a9300000-0000-0000-0000-0000000000e1'$q$);
  IF r NOT LIKE '23514%cancelled event%' THEN RAISE EXCEPTION 'O2: republish not refused: %', r; END IF;
  r := pg_temp.try($q$UPDATE public.exos_events SET status = 'draft' WHERE id = 'a9300000-0000-0000-0000-0000000000e1'$q$);
  IF r NOT LIKE '23514%' THEN RAISE EXCEPTION 'O2: back to draft not refused: %', r; END IF;
  -- The SPA's save re-sends status with the other fields: unchanged is fine.
  r := pg_temp.try($q$UPDATE public.exos_events SET status = 'cancelled', description = 'see you next year' WHERE id = 'a9300000-0000-0000-0000-0000000000e1'$q$);
  IF r <> 'ok' THEN RAISE EXCEPTION 'O2: editing a cancelled event refused: %', r; END IF;
  r := pg_temp.try($q$UPDATE public.exos_events SET name = 'Show (cancelled)' WHERE id = 'a9300000-0000-0000-0000-0000000000e1'$q$);
  IF r <> 'ok' THEN RAISE EXCEPTION 'O2: renaming a cancelled event refused: %', r; END IF;
  SELECT status INTO s FROM public.exos_events WHERE id = 'a9300000-0000-0000-0000-0000000000e1';
  IF s <> 'cancelled' THEN RAISE EXCEPTION 'O2: status moved to %', s; END IF;
  RAISE NOTICE 'O1 O2 ok';
END $$;

-- O2 as a signed-in owner too (the SPA path).
SELECT pg_temp.act('a9300000-0000-0000-0000-0000000000a1', 'op1own@x.test');
DO $$
DECLARE r text;
BEGIN
  r := pg_temp.try($q$UPDATE public.exos_events SET status = 'published' WHERE id = 'a9300000-0000-0000-0000-0000000000e1'$q$);
  IF r NOT LIKE '23514%' THEN RAISE EXCEPTION 'O2: owner republish not refused: %', r; END IF;
END $$;

-- O3. Stripe Connect readiness.
DO $$
DECLARE r text; v boolean;
BEGIN
  PERFORM pg_temp.act('a9300000-0000-0000-0000-0000000000a2', 'op1mgr@x.test');
  v := public.exos_org_payments_ready('a9300000-0000-0000-0000-000000000001');
  IF v IS DISTINCT FROM false THEN RAISE EXCEPTION 'O3: no account should be false, got %', v; END IF;

  INSERT INTO public.exos_org_secrets(org_id, payments) VALUES
    ('a9300000-0000-0000-0000-000000000001', '{"connectedAccountId":"acct_1","chargesEnabled":false}');
  v := public.exos_org_payments_ready('a9300000-0000-0000-0000-000000000001');
  IF v IS DISTINCT FROM false THEN RAISE EXCEPTION 'O3: pending account should be false, got %', v; END IF;

  UPDATE public.exos_org_secrets SET payments = '{"connectedAccountId":"acct_1","chargesEnabled":true}'
   WHERE org_id = 'a9300000-0000-0000-0000-000000000001';
  v := public.exos_org_payments_ready('a9300000-0000-0000-0000-000000000001');
  IF v IS DISTINCT FROM true THEN RAISE EXCEPTION 'O3: charges enabled should be true, got %', v; END IF;

  PERFORM pg_temp.act('a9300000-0000-0000-0000-0000000000a9', 'op1out@x.test');
  r := pg_temp.try($q$SELECT public.exos_org_payments_ready('a9300000-0000-0000-0000-000000000001')$q$);
  IF r NOT LIKE '42501%' THEN RAISE EXCEPTION 'O3: non-member not refused: %', r; END IF;

  PERFORM set_config('app.uid', '', false);
  r := pg_temp.try($q$SELECT public.exos_org_payments_ready('a9300000-0000-0000-0000-000000000001')$q$);
  IF r NOT LIKE '42501%' THEN RAISE EXCEPTION 'O3: signed out not refused: %', r; END IF;
  RAISE NOTICE 'O3 ok';
END $$;

-- O2 escape hatch (last: set_config(..., true) lasts the transaction): an
-- operator undoing a mistaken cancellation names the event; only that one.
DO $$
DECLARE r text;
BEGIN
  PERFORM set_config('app.uid', '', false);
  PERFORM set_config('exos.uncancel_ok', 'a9300000-0000-0000-0000-0000000000ff', true);
  r := pg_temp.try($q$UPDATE public.exos_events SET status = 'published' WHERE id = 'a9300000-0000-0000-0000-0000000000e1'$q$);
  IF r NOT LIKE '23514%' THEN RAISE EXCEPTION 'O2: another event''s id let it through: %', r; END IF;
  PERFORM set_config('exos.uncancel_ok', 'a9300000-0000-0000-0000-0000000000e1', true);
  r := pg_temp.try($q$UPDATE public.exos_events SET status = 'published' WHERE id = 'a9300000-0000-0000-0000-0000000000e1'$q$);
  IF r <> 'ok' THEN RAISE EXCEPTION 'O2: operator un-cancel refused: %', r; END IF;
  RAISE NOTICE 'O2 escape hatch ok';
END $$;

\echo 'test_organizer_p1: all passed'
ROLLBACK;
