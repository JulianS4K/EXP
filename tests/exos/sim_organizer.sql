-- ============================================================================
-- Organizer mistake simulations (SIM-ORG-n). Organizers and their staff
-- (owner, manager, finance, content, scanner) get things wrong; each block
-- drives the real RPCs / table writes the dashboard, the API and the edge
-- functions make, and asserts what Exos does about it.
--   OK     the mistake is refused, or harmless and undoable (why, inline)
--   FIXED  was broken; fixed in mig 20261104110000 (this block is the test)
--   KNOWN  broken or a product call; reported, never fails the run
-- Dashboard table writes run as `authenticated` under the phase-1 RLS
-- policies (prod's base schema; recreated here in the transaction).
-- Self-contained (5a prefix), rolled back.
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/sim_organizer.sql
-- ============================================================================
\set ON_ERROR_STOP on
\o /dev/null
BEGIN;

-- Platform defaults back on (run_p0.sh turns these off for older fixtures).
DELETE FROM public.exos_platform_settings
 WHERE key IN ('free_tier_max_capacity', 'resale_consent_required', 'last_call_threshold', 'resale_min_capacity');
INSERT INTO public.exos_platform_settings (key, value) VALUES ('last_call_threshold', '0');

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('5a000000-0000-0000-0000-0000000000a1', 'sim-owner@x.com', now()),
  ('5a000000-0000-0000-0000-0000000000a2', 'sim-manager@x.com', now()),
  ('5a000000-0000-0000-0000-0000000000a3', 'sim-finance@x.com', now()),
  ('5a000000-0000-0000-0000-0000000000a4', 'sim-content@x.com', now()),
  ('5a000000-0000-0000-0000-0000000000a5', 'sim-scanner@x.com', now()),
  ('5a000000-0000-0000-0000-0000000000a6', 'sim-owner2@x.com', now()),
  ('5a000000-0000-0000-0000-0000000000b1', 'sim-buyer@x.com', now()),
  ('5a000000-0000-0000-0000-0000000000b2', 'sim-wrong@x.com', now()),
  ('5a000000-0000-0000-0000-0000000000b9', 'sim-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('5a000000-0000-0000-0000-000000000001', 'Sim Org', 'sim-org-5a', '5a000000-0000-0000-0000-0000000000a1'),
  ('5a000000-0000-0000-0000-000000000002', 'Sim Other', 'sim-other-5a', '5a000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('5a000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-0000000000a1', 'owner'),
  ('5a000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-0000000000a2', 'manager'),
  ('5a000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-0000000000a3', 'finance'),
  ('5a000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-0000000000a4', 'content'),
  ('5a000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-0000000000a5', 'scanner'),
  ('5a000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-0000000000b9', 'owner');

-- e1 a published $30 show (4 sold), e2 a draft with no ticket types,
-- e3 the show that gets cancelled, e9 another org's show.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, venue_name, total_tickets, tickets_sold, created_by) VALUES
  ('5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-000000000001', 'Sim Night', 'sim-night-5a', 'published',
   date_trunc('day', now()) + interval '20 days 20 hours', 'America/New_York', 'Blue Room', 100, 4, '5a000000-0000-0000-0000-0000000000a1'),
  ('5a000000-0000-0000-0000-0000000000e2', '5a000000-0000-0000-0000-000000000001', 'Sim Draft', 'sim-draft-5a', 'draft',
   now() + interval '30 days', 'America/New_York', 'Blue Room', 0, 0, '5a000000-0000-0000-0000-0000000000a1'),
  ('5a000000-0000-0000-0000-0000000000e3', '5a000000-0000-0000-0000-000000000001', 'Sim Rainout', 'sim-rainout-5a', 'published',
   now() + interval '15 days', 'America/New_York', 'Park', 50, 2, '5a000000-0000-0000-0000-0000000000a1'),
  ('5a000000-0000-0000-0000-0000000000e9', '5a000000-0000-0000-0000-000000000002', 'Sim Theirs', 'sim-theirs-5a', 'published',
   now() + interval '15 days', 'America/New_York', 'Elsewhere', 0, 0, '5a000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, sort_order) VALUES
  ('5a000000-0000-0000-0000-0000000000d1', '5a000000-0000-0000-0000-0000000000e1', 'GA', 30, 100, 4, 1),
  ('5a000000-0000-0000-0000-0000000000d2', '5a000000-0000-0000-0000-0000000000e1', 'Comp', 0, 20, 0, 2),
  ('5a000000-0000-0000-0000-0000000000d3', '5a000000-0000-0000-0000-0000000000e3', 'GA', 25, 50, 2, 1);

-- Orders: cs_5a1 two GA at $30 ($60), cs_5a2 two GA ($60), cs_5a3 two on the rainout ($50).
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status, payment_intent) VALUES
  ('cs_5a1', '5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-0000000000d1', '5a000000-0000-0000-0000-000000000001',
   '5a000000-0000-0000-0000-0000000000b1', 'sim-buyer@x.com', 2, 6000, 'fulfilled', 'pi_5a1'),
  ('cs_5a2', '5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-0000000000d1', '5a000000-0000-0000-0000-000000000001',
   '5a000000-0000-0000-0000-0000000000b1', 'sim-buyer@x.com', 2, 6000, 'fulfilled', 'pi_5a2'),
  ('cs_5a3', '5a000000-0000-0000-0000-0000000000e3', '5a000000-0000-0000-0000-0000000000d3', '5a000000-0000-0000-0000-000000000001',
   '5a000000-0000-0000-0000-0000000000b1', 'sim-buyer@x.com', 2, 5000, 'fulfilled', 'pi_5a3');
SELECT public.exos_record_payment('cs_5a1', 'pi_5a1', 6000, 'succeeded');
SELECT public.exos_record_payment('cs_5a2', 'pi_5a2', 6000, 'succeeded');
SELECT public.exos_record_payment('cs_5a3', 'pi_5a3', 5000, 'succeeded');
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, created_at)
SELECT ('5a000000-0000-0000-0000-0000000' || o || '0' || lpad(n::text, 3, '0'))::uuid,
       ev::uuid, '5a000000-0000-0000-0000-000000000001', tr::uuid, 'GA',
       '5a000000-0000-0000-0000-0000000000b1', '5a000000-0000-0000-0000-0000000000b1', 'sim-buyer@x.com', 'active',
       gen_random_uuid()::text, px, 'cs_5a' || o, now() - interval '1 hour' + n * interval '1 second'
  FROM (VALUES (1, 1, '5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-0000000000d1', 30),
               (1, 2, '5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-0000000000d1', 30),
               (2, 1, '5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-0000000000d1', 30),
               (2, 2, '5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-0000000000d1', 30),
               (3, 1, '5a000000-0000-0000-0000-0000000000e3', '5a000000-0000-0000-0000-0000000000d3', 25),
               (3, 2, '5a000000-0000-0000-0000-0000000000e3', '5a000000-0000-0000-0000-0000000000d3', 25)) v(o, n, ev, tr, px);

-- Prod's phase-1 base policies on the tables the dashboard writes directly
-- (mig 20260520120000 §7; prereq.sql builds the tables without them).
ALTER TABLE public.exos_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_ticket_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_org_memberships ENABLE ROW LEVEL SECURITY;
CREATE POLICY sim_events_sel ON public.exos_events FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
CREATE POLICY sim_events_ins ON public.exos_events FOR INSERT TO authenticated
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner','manager']));
CREATE POLICY sim_events_upd ON public.exos_events FOR UPDATE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager'])) WITH CHECK (exos_has_org_role(org_id, ARRAY['owner','manager']));
CREATE POLICY sim_events_del ON public.exos_events FOR DELETE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner']));
CREATE POLICY sim_tiers_sel ON public.exos_ticket_tiers FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager','finance','scanner','content'])));
CREATE POLICY sim_tiers_wr ON public.exos_ticket_tiers FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])));
CREATE POLICY sim_mem_sel ON public.exos_org_memberships FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR exos_has_org_role(org_id, ARRAY['owner','manager']));
CREATE POLICY sim_mem_ins ON public.exos_org_memberships FOR INSERT TO authenticated WITH CHECK (exos_has_org_role(org_id, ARRAY['owner']));
CREATE POLICY sim_mem_upd ON public.exos_org_memberships FOR UPDATE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner'])) WITH CHECK (exos_has_org_role(org_id, ARRAY['owner']));
CREATE POLICY sim_mem_del ON public.exos_org_memberships FOR DELETE TO authenticated USING (exos_has_org_role(org_id, ARRAY['owner']));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_events, public.exos_ticket_tiers, public.exos_org_memberships TO authenticated;

CREATE FUNCTION pg_temp.act(p_uid text, p_email text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false),
         set_config('app.jwt', CASE WHEN p_email IS NULL THEN '' ELSE jsonb_build_object('email', p_email)::text END, false);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text, text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('5a000000-0000-0000-0000-0000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated, service_role;
-- The error a statement raises ('' = none).
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN others THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.err(text) TO anon, authenticated, service_role;
CREATE TEMP TABLE sim (k text PRIMARY KEY, v text);
GRANT ALL ON sim TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.g(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM sim WHERE k = p_k $$;
GRANT EXECUTE ON FUNCTION pg_temp.g(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.put(p_k text, p_v text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO sim VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v
$$;
GRANT EXECUTE ON FUNCTION pg_temp.put(text, text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.sold(p text) RETURNS int LANGUAGE sql AS $$ SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u(p) $$;
GRANT EXECUTE ON FUNCTION pg_temp.sold(text) TO anon, authenticated, service_role;

-- ============================================================================
-- Event setup
-- ============================================================================

-- SIM-ORG-1 -------------------------------------------------------------------
-- The manager priced GA at $30 by mistake and edits it to $45 after 4 sold.
SET ROLE authenticated;
SELECT pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
UPDATE public.exos_ticket_tiers SET price = 45 WHERE id = '5a000000-0000-0000-0000-0000000000d1';
RESET ROLE;
DO $$
DECLARE p jsonb;
BEGIN
  ASSERT (SELECT price FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 45, 'SIM-ORG-1: the edit took';
  ASSERT (SELECT bool_and(price_paid = 30) FROM public.exos_tickets WHERE order_ref IN ('cs_5a1', 'cs_5a2')),
         'SIM-ORG-1: an existing ticket changed price';
  ASSERT (SELECT amount_cents FROM public.exos_checkout_sessions WHERE session_id = 'cs_5a1') = 6000, 'SIM-ORG-1: order total moved';
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a3');
  p := public.exos_refund_preview('cs_5a1');
  ASSERT (p->>'refundable_cents')::int = 6000
     AND (SELECT bool_and((t->>'share_cents')::int = 3000) FROM jsonb_array_elements(p->'tickets') t),
         'SIM-ORG-1: refunds follow the new price: ' || p::text;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-1 a price edit after sales: buyers keep what they paid (tickets, order, refund shares)';
END $$;

-- SIM-ORG-2 -------------------------------------------------------------------
-- Capacity lowered below what is already sold (100 -> 2 with 4 sold), and
-- the overall cap below tickets_sold.
SET ROLE authenticated;
SELECT pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
SELECT pg_temp.put('2_tier', pg_temp.err($$UPDATE public.exos_ticket_tiers SET capacity = 2 WHERE id = pg_temp.u('d1')$$));
SELECT pg_temp.put('2_event', pg_temp.err($$UPDATE public.exos_events SET total_tickets = 3 WHERE id = pg_temp.u('e1')$$));
-- Down to exactly what's sold (the way to stop sales) is fine.
SELECT pg_temp.put('2_exact', pg_temp.err($$UPDATE public.exos_ticket_tiers SET capacity = 4 WHERE id = pg_temp.u('d1')$$));
RESET ROLE;
DO $$
BEGIN
  ASSERT pg_temp.g('2_tier') LIKE '%already sold%', 'SIM-ORG-2: tier capacity below sold accepted: ' || pg_temp.g('2_tier');
  ASSERT pg_temp.g('2_event') LIKE '%already sold%', 'SIM-ORG-2: event cap below sold accepted: ' || pg_temp.g('2_event');
  ASSERT pg_temp.g('2_exact') = '', 'SIM-ORG-2: capacity = sold refused: ' || pg_temp.g('2_exact');
  ASSERT public.exos_tier_available(pg_temp.u('d1')) = 0, 'SIM-ORG-2: sold out at capacity = sold';
  UPDATE public.exos_ticket_tiers SET capacity = 100 WHERE id = pg_temp.u('d1');
  RAISE NOTICE 'OK  SIM-ORG-2 FIXED capacity below sold is refused (tier and overall cap); = sold stops sales';
END $$;

-- SIM-ORG-3 -------------------------------------------------------------------
-- "Set capacity to 0 to stop sales": 0 means uncapped, so the tier sells on.
SET ROLE authenticated;
SELECT pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
SELECT pg_temp.put('3', pg_temp.err($$UPDATE public.exos_ticket_tiers SET capacity = 0 WHERE id = pg_temp.u('d1')$$));
RESET ROLE;
DO $$
BEGIN
  IF pg_temp.g('3') = '' AND public.exos_tier_available(pg_temp.u('d1')) IS NULL THEN
    RAISE NOTICE 'KNOWN SIM-ORG-3 capacity 0 on a tier that has sold means "uncapped": an organizer stopping sales opens them wide (product call: 0 = unlimited)';
  ELSE
    RAISE NOTICE 'OK  SIM-ORG-3 capacity 0 after sales: %', pg_temp.g('3');
  END IF;
  UPDATE public.exos_ticket_tiers SET capacity = 100 WHERE id = pg_temp.u('d1');
END $$;

-- SIM-ORG-4 -------------------------------------------------------------------
-- Wrong date / time zone, noticed after sales. A same-day fix within 3 h
-- saves directly; a new day goes through exos_reschedule_event (holders told).
SET ROLE authenticated;
SELECT pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
SELECT pg_temp.put('4_small', pg_temp.err($$UPDATE public.exos_events SET starts_at = starts_at - interval '1 hour' WHERE id = pg_temp.u('e1')$$));
SELECT pg_temp.put('4_big', pg_temp.err($$UPDATE public.exos_events SET starts_at = starts_at + interval '7 days' WHERE id = pg_temp.u('e1')$$));
-- The time zone alone (the instant stays): saved; nothing re-dates.
SELECT pg_temp.put('4_tz', pg_temp.err($$UPDATE public.exos_events SET timezone = 'America/Chicago' WHERE id = pg_temp.u('e1')$$));
RESET ROLE;
DO $$
BEGIN
  ASSERT pg_temp.g('4_small') = '', 'SIM-ORG-4: small same-day fix refused: ' || pg_temp.g('4_small');
  ASSERT pg_temp.g('4_big') LIKE '%exos_reschedule_event%', 'SIM-ORG-4: a week move saved directly: ' || pg_temp.g('4_big');
  ASSERT pg_temp.g('4_tz') = '', 'SIM-ORG-4: tz fix refused: ' || pg_temp.g('4_tz');
  UPDATE public.exos_events SET timezone = 'America/New_York' WHERE id = pg_temp.u('e1');
  RAISE NOTICE 'OK  SIM-ORG-4 a date move after sales goes through the reschedule flow; small same-day fixes save';
END $$;

-- SIM-ORG-5 -------------------------------------------------------------------
-- Publishing a draft with no ticket types; publishing as content / scanner.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  r := public.exos_publish_event(pg_temp.u('e2'));
  ASSERT (r->>'published')::boolean = false
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'blockers') b WHERE b->>'code' = 'no_ticket_types'), 'SIM-ORG-5: ' || r::text;
  ASSERT (SELECT status FROM public.exos_events WHERE id = pg_temp.u('e2')) = 'draft', 'SIM-ORG-5: went live';
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.err($q$SELECT public.exos_publish_event(pg_temp.u('e2'))$q$) LIKE '42501%', 'SIM-ORG-5: content published';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-5 publish with no ticket types is blocked (and content can''t publish)';
END $$;

-- SIM-ORG-6 -------------------------------------------------------------------
-- A 100-seat free-tier show: the organizer tries to put tickets on a resale
-- marketplace (the resale floor is 150 + an opt-in, #57/#63).
DO $$
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a1');
  ASSERT public.exos_event_is_free_tier(pg_temp.u('e1')), 'SIM-ORG-6: e1 is free tier';
  ASSERT pg_temp.err($q$SELECT public.exos_set_channel_allocation(pg_temp.u('e1'), 'stubhub', pg_temp.u('d1'), 5)$q$) <> '',
         'SIM-ORG-6: a free-tier event got a resale allocation';
  ASSERT pg_temp.err($q$SELECT public.exos_set_resale_consent(pg_temp.u('e1'), true, 'v1')$q$) <> '',
         'SIM-ORG-6: opted in at 100 seats';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1')), 'SIM-ORG-6: listing made';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-6 free tier + resale: allocation and opt-in refused under the floor';
END $$;

-- SIM-ORG-7 -------------------------------------------------------------------
-- Deleting an event that has sold; cancelling it instead (holders mailed,
-- every order refundable); then trying to un-cancel it.
DO $$
DECLARE r jsonb; c jsonb;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.err($q$SELECT public.exos_event_delete(pg_temp.u('e3'))$q$) LIKE '%published%', 'SIM-ORG-7: published event deleted';
  PERFORM pg_temp.act(NULL);
END $$;
SET ROLE authenticated;
SELECT pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
UPDATE public.exos_events SET status = 'cancelled' WHERE id = '5a000000-0000-0000-0000-0000000000e3';
RESET ROLE;
DO $$
DECLARE c jsonb; f jsonb; n int;
BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'sim-buyer@x.com' AND template = 'event-cancelled'),
         'SIM-ORG-7: holders not told';
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.err($q$SELECT public.exos_event_delete(pg_temp.u('e3'))$q$) LIKE '%cancel it instead%', 'SIM-ORG-7: cancelled event with sales deleted';
  PERFORM pg_temp.act(NULL);
  -- The cancel refund run (exos-refund, scope event_cancel): every order.
  SELECT count(*) INTO n FROM public.exos_refund_event_orders_svc(pg_temp.u('a3'), pg_temp.u('e3'));
  ASSERT n = 1, 'SIM-ORG-7: refundable orders listed: ' || n;
  c := public.exos_refund_claim(pg_temp.u('a3'), 'cs_5a3', 'sim7-cancel-cs5a3', NULL, NULL, true, 'event cancelled', 'event_cancel');
  f := public.exos_refund_finalize((c->>'request_id')::uuid, 're_sim7', 'succeeded');
  ASSERT (c->>'amount_cents')::int = 5000 AND (f->>'voided')::int = 2, 'SIM-ORG-7: refund ' || c::text || f::text;
  ASSERT pg_temp.sold('d3') = 0, 'SIM-ORG-7: seats not freed';
END $$;
SET ROLE authenticated;
SELECT pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
SELECT pg_temp.put('7_uncancel', pg_temp.err($$UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e3')$$));
SELECT pg_temp.put('7_draft', pg_temp.err($$UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('e3')$$));
RESET ROLE;
DO $$
BEGIN
  ASSERT pg_temp.g('7_uncancel') LIKE '%cancelled%' AND pg_temp.g('7_draft') LIKE '%cancelled%',
         'SIM-ORG-7: a cancelled, refunded event went back on sale: ' || pg_temp.g('7_uncancel') || ' / ' || pg_temp.g('7_draft');
  ASSERT (SELECT status FROM public.exos_events WHERE id = pg_temp.u('e3')) = 'cancelled', 'SIM-ORG-7: status moved';
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  ASSERT (public.exos_publish_event(pg_temp.u('e3'))->>'published')::boolean = false, 'SIM-ORG-7: publish RPC un-cancelled';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-7 FIXED delete refused with sales; cancel mails + refunds; un-cancel refused on the table too';
END $$;

-- SIM-ORG-8 -------------------------------------------------------------------
-- "Duplicate" from a template, forgetting the date: the copy has no date and
-- can't be published until one is set.
DO $$
DECLARE tp uuid; r jsonb; ev uuid;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  tp := public.exos_event_template_from_event(pg_temp.u('e1'), 'Sim Night template');
  r := public.exos_event_from_template(tp, '{}'::jsonb);
  ev := (r->>'event_id')::uuid;
  ASSERT (SELECT status = 'draft' AND starts_at IS NULL AND tickets_sold = 0 FROM public.exos_events WHERE id = ev),
         'SIM-ORG-8: copy carried the date or sales';
  ASSERT (SELECT count(*) = 2 AND bool_and(sold = 0) FROM public.exos_ticket_tiers WHERE event_id = ev), 'SIM-ORG-8: tiers';
  r := public.exos_publish_event(ev);
  ASSERT (r->>'published')::boolean = false
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'blockers') b WHERE b->>'code' = 'missing_start'), 'SIM-ORG-8: ' || r::text;
  -- The old date passed by mistake (now in the past): blocked too.
  r := public.exos_event_from_template(tp, jsonb_build_object('starts_at', now() - interval '3 days'));
  r := public.exos_publish_event((r->>'event_id')::uuid);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'blockers') b WHERE b->>'code' = 'starts_in_past'), 'SIM-ORG-8: past ' || r::text;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-8 a template copy without a date (or with a past one) can''t go live';
END $$;

-- ============================================================================
-- Comps and refunds
-- ============================================================================

-- SIM-ORG-9 -------------------------------------------------------------------
-- A comp to the wrong email (it belongs to an account), then undone.
DO $$
DECLARE r record; v_t uuid;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2', 'sim-manager@x.com');
  SELECT * INTO r FROM public.exos_issue_comp_batch(pg_temp.u('e1'), pg_temp.u('d2'), ARRAY['sim-wrong@x.com'], 1);
  ASSERT r.outcome = 'issued' AND pg_temp.sold('d2') = 1, 'SIM-ORG-9: comp';
  v_t := r.ticket_ids[1];
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = v_t) = pg_temp.u('b2'), 'SIM-ORG-9: owner';
  -- Staff release (a free ticket): voided, the seat back.
  PERFORM public.exos_release_ticket(v_t);
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = v_t) = 'voided' AND pg_temp.sold('d2') = 0
     AND (SELECT tickets_sold FROM public.exos_events WHERE id = pg_temp.u('e1')) = 4, 'SIM-ORG-9: undo';
  SELECT * INTO r FROM public.exos_issue_comp_batch(pg_temp.u('e1'), pg_temp.u('d2'), ARRAY['sim-buyer@x.com'], 1);
  ASSERT r.outcome = 'issued' AND pg_temp.sold('d2') = 1, 'SIM-ORG-9: reissue';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-9 a comp to the wrong account is released by staff (voided, seat back) and reissued';
END $$;

-- SIM-ORG-10 ------------------------------------------------------------------
-- The same comp batch submitted twice (double click / retry).
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2', 'sim-manager@x.com');
  PERFORM public.exos_issue_comp_batch(pg_temp.u('e1'), pg_temp.u('d2'), ARRAY['vip1@x.com', 'vip2@x.com'], 1);
  PERFORM public.exos_issue_comp_batch(pg_temp.u('e1'), pg_temp.u('d2'), ARRAY['vip1@x.com', 'vip2@x.com'], 1);
  SELECT count(*) INTO n FROM public.exos_tickets WHERE event_id = pg_temp.u('e1') AND buyer_email IN ('vip1@x.com', 'vip2@x.com');
  IF n = 4 THEN
    RAISE NOTICE 'KNOWN SIM-ORG-10 a comp batch sent twice issues twice (4 tickets, 4 claim mails); no idempotency key on exos_issue_comp_batch';
  ELSE
    ASSERT n = 2, 'SIM-ORG-10: ' || n;
    RAISE NOTICE 'OK  SIM-ORG-10 a repeated comp batch issues once';
  END IF;
  PERFORM pg_temp.act(NULL);
END $$;

-- SIM-ORG-11 ------------------------------------------------------------------
-- Box-office issue on a cancelled event.
DO $$
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2', 'sim-manager@x.com');
  ASSERT pg_temp.err($q$SELECT public.exos_issue_ticket_to_email(pg_temp.u('e3'), pg_temp.u('d3'), 'late@x.com', 1)$q$) LIKE '%cancelled%',
         'SIM-ORG-11: box office minted on a cancelled event';
  ASSERT pg_temp.err($q$SELECT * FROM public.exos_issue_comp_batch(pg_temp.u('e3'), pg_temp.u('d3'), ARRAY['late@x.com'], 1)$q$) LIKE '%cancelled%',
         'SIM-ORG-11: comp batch on a cancelled event';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE event_id = pg_temp.u('e3') AND status = 'active'), 'SIM-ORG-11: ticket made';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-11 FIXED box-office / comp tickets on a cancelled event are refused';
END $$;

-- SIM-ORG-12 ------------------------------------------------------------------
-- The same order refunded from the dashboard and the API (two nonces), a
-- double click (one nonce), and a partial larger than what's left.
DO $$
DECLARE c1 jsonb; c2 jsonb; f jsonb;
BEGIN
  c1 := public.exos_refund_claim(pg_temp.u('a3'), 'cs_5a1', 'sim12-dashboard', NULL, NULL, true, 'dashboard');
  c2 := public.exos_refund_claim(pg_temp.u('a3'), 'cs_5a1', 'sim12-dashboard', NULL, NULL, true, 'dashboard');
  ASSERT c2->>'request_id' = c1->>'request_id' AND (c2->>'existing')::boolean, 'SIM-ORG-12: double click made two';
  ASSERT pg_temp.err($q$SELECT public.exos_refund_claim(pg_temp.u('a2'), 'cs_5a1', 'sim12-api-key-1', NULL, NULL, true, 'api')$q$)
         LIKE '%nothing left%', 'SIM-ORG-12: API refund on top of the dashboard one';
  f := public.exos_refund_finalize((c1->>'request_id')::uuid, 're_sim12', 'succeeded');
  ASSERT (SELECT sum(amount_cents) FROM public.exos_order_refunds WHERE session_id = 'cs_5a1') = 6000, 'SIM-ORG-12: ledger';
  -- cs_5a2: $10 partial, then $55 (only $50 left).
  c1 := public.exos_refund_claim(pg_temp.u('a3'), 'cs_5a2', 'sim12-partial-1', NULL, 1000, false, 'goodwill');
  PERFORM public.exos_refund_finalize((c1->>'request_id')::uuid, 're_sim12b', 'succeeded');
  ASSERT pg_temp.err($q$SELECT public.exos_refund_claim(pg_temp.u('a3'), 'cs_5a2', 'sim12-partial-2', NULL, 5500)$q$)
         LIKE '%more than the 5000 cents left%', 'SIM-ORG-12: partial over the remainder';
  -- A refund made in the Stripe dashboard (webhook) counts too.
  PERFORM public.exos_record_refund('cs_5a2', 're_sim12_stripe', 2000, 'succeeded', 'pi_5a2', 'stripe dashboard');
  ASSERT pg_temp.err($q$SELECT public.exos_refund_claim(pg_temp.u('a3'), 'cs_5a2', 'sim12-partial-3', NULL, 3001)$q$)
         LIKE '%more than the 3000 cents left%', 'SIM-ORG-12: Stripe-side refund not counted';
  -- A content user can't refund.
  ASSERT pg_temp.err($q$SELECT public.exos_refund_claim(pg_temp.u('a4'), 'cs_5a2', 'sim12-content-1', NULL, 100)$q$) LIKE '42501%',
         'SIM-ORG-12: content refunded';
  RAISE NOTICE 'OK  SIM-ORG-12 double refunds, over-refunds and Stripe-side refunds are all bounded by what was paid';
END $$;

-- ============================================================================
-- Imports
-- ============================================================================

-- SIM-ORG-13 ------------------------------------------------------------------
-- The same guest CSV imported twice.
DO $$
DECLARE l uuid; r jsonb; rows jsonb := '[{"name":"Ada","email":"ada@x.com"},{"name":"Bo","email":"bo@x.com","plus_ones":"1"},
                                           {"name":"Cy","code":"GL-0003"}]';
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  l := public.exos_upsert_guest_list(pg_temp.u('e1'), 'Friends');
  PERFORM pg_temp.put('list', l::text);
  r := public.exos_import_guests(l, rows);
  ASSERT (r->>'inserted')::int = 3, 'SIM-ORG-13: first ' || r::text;
  r := public.exos_import_guests(l, rows);
  ASSERT (r->>'inserted')::int = 0 AND (r->>'duplicates')::int = 3, 'SIM-ORG-13: second ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries WHERE list_id = l) = 3, 'SIM-ORG-13: doubled';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-13 a guest CSV imported twice adds nobody the second time';
END $$;

-- SIM-ORG-14 ------------------------------------------------------------------
-- The wrong column mapping: name and email swapped.
DO $$
DECLARE l uuid := pg_temp.g('list')::uuid; r jsonb; n int;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  r := public.exos_import_guests(l, '[{"name":"dee@x.com","email":"Dee"},{"name":"eve@x.com","email":"Eve"}]');
  SELECT count(*) INTO n FROM public.exos_guest_list_entries WHERE list_id = l AND guest_name LIKE '%@%';
  IF (r->>'inserted')::int = 2 AND n = 2 THEN
    RAISE NOTICE 'KNOWN SIM-ORG-14 swapped name/email columns import as guests named by email (no email kept), reported as inserted; undo = delete them by hand';
  ELSE
    RAISE NOTICE 'OK  SIM-ORG-14 swapped columns flagged: %', r::text;
  END IF;
  PERFORM pg_temp.act(NULL);
END $$;

-- SIM-ORG-15 ------------------------------------------------------------------
-- Gift cards: duplicate codes inside one file, then the same file again.
DO $$
DECLARE r jsonb; cards jsonb := '[{"code":"GIFT-AAA-111","balance_cents":5000},{"code":"giftaaa111","balance_cents":9000},
                                   {"code":"GIFT-BBB-222","balance_cents":2500}]';
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  r := public.exos_gift_card_import(pg_temp.u('01'), 'gift_up', cards, NULL);
  ASSERT (r->>'created')::int = 2 AND (r->>'duplicates')::int = 1 AND (r->>'imported_cents')::int = 7500, 'SIM-ORG-15: ' || r::text;
  r := public.exos_gift_card_import(pg_temp.u('01'), 'gift_up', cards, NULL);
  ASSERT (r->>'fresh')::boolean = false, 'SIM-ORG-15: same file not replayed ' || r::text;
  r := public.exos_gift_card_import(pg_temp.u('01'), 'gift_up', '[{"code":"GIFT-AAA-111","balance_cents":5000}]', 'sim15-other-batch');
  ASSERT (r->>'created')::int = 0 AND (r->>'duplicates')::int = 1, 'SIM-ORG-15: re-import in a new batch ' || r::text;
  ASSERT (SELECT sum(balance_cents) FROM public.exos_gift_cards WHERE org_id = pg_temp.u('01') AND external_source = 'gift_up') = 7500,
         'SIM-ORG-15: balances doubled';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-15 gift-card codes import once (duplicates in a file, a repeated file, a new batch); the 2nd balance of a dup code is reported, not added';
END $$;

-- ============================================================================
-- Finance
-- ============================================================================

-- SIM-ORG-16 ------------------------------------------------------------------
-- Deal brackets typed out of order / overlapping; edited after the offer is final.
SET ROLE authenticated;
DO $$
DECLARE r jsonb; o uuid;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  r := public.exos_offer_create(pg_temp.u('01'), jsonb_build_object('artist_name', 'Sim Act', 'event_id', pg_temp.u('e1'),
         'terms', jsonb_build_object('deal_type', 'door', 'percentage', 80)));
  o := (r->>'id')::uuid;
  PERFORM pg_temp.put('offer', o::text);
  -- Out of order is fine (sorted by threshold); the same threshold twice isn't.
  INSERT INTO public.exos_deal_brackets (offer_id, basis, threshold, percentage) VALUES (o, 'amount', 5000000, 95);
  INSERT INTO public.exos_deal_brackets (offer_id, basis, threshold, percentage) VALUES (o, 'amount', 2000000, 90);
  ASSERT pg_temp.err(format($q$INSERT INTO public.exos_deal_brackets (offer_id, basis, threshold, percentage) VALUES (%L, 'amount', 2000000, 85)$q$, o))
         LIKE '22023%', 'SIM-ORG-16: overlapping bracket';
  PERFORM public.exos_offer_record_response(o, 'accept', 'Agent on the phone');
  ASSERT pg_temp.err(format($q$UPDATE public.exos_deal_brackets SET percentage = 99 WHERE offer_id = %L$q$, o)) LIKE '55000%',
         'SIM-ORG-16: bracket edited after acceptance';
  ASSERT pg_temp.err(format($q$INSERT INTO public.exos_deal_brackets (offer_id, basis, threshold, percentage) VALUES (%L, 'amount', 9000000, 99)$q$, o))
         LIKE '55000%', 'SIM-ORG-16: bracket added after acceptance';
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
DO $$
DECLARE o uuid := pg_temp.g('offer')::uuid;
BEGIN
  -- $60k door: 80% to $20k, 90% to $50k, 95% above.
  ASSERT public._exos_bracket_amount(6000000, 0, 80, public._exos_offer_brackets_json(o)) = 80 * 20000 + 90 * 30000 + 95 * 10000,
         'SIM-ORG-16: bracket maths ' || public._exos_bracket_amount(6000000, 0, 80, public._exos_offer_brackets_json(o));
  RAISE NOTICE 'OK  SIM-ORG-16 brackets: order doesn''t matter, overlaps refused, frozen once the offer is accepted';
END $$;

-- SIM-ORG-17 ------------------------------------------------------------------
-- A promoter settled twice; the commission changed after sales.
INSERT INTO public.exos_promoters (id, org_id, code, name, commission_bps) VALUES
  ('5a000000-0000-0000-0000-0000000000f1', '5a000000-0000-0000-0000-000000000001', 'sim-promo', 'Sim Promo', 1000);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status, promoter_id) VALUES
  ('cs_5a_p1', '5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-0000000000d1', '5a000000-0000-0000-0000-000000000001',
   '5a000000-0000-0000-0000-0000000000b1', 'sim-buyer@x.com', 2, 9000, 'pending', 'sim-promo'),
  ('cs_5a_p2', '5a000000-0000-0000-0000-0000000000e1', '5a000000-0000-0000-0000-0000000000d1', '5a000000-0000-0000-0000-000000000001',
   '5a000000-0000-0000-0000-0000000000b1', 'sim-buyer@x.com', 1, 4500, 'pending', 'sim-promo');
SELECT public.exos_fulfill_checkout('cs_5a_p1');
DO $$
DECLARE p uuid := pg_temp.u('f1'); ids uuid[]; r jsonb; n int;
BEGIN
  SELECT array_agg(id ORDER BY id) INTO ids FROM public.exos_promoter_commissions WHERE promoter_id = p AND status = 'accrued';
  ASSERT cardinality(ids) = 2 AND (SELECT sum(commission_cents) FROM public.exos_promoter_commissions WHERE id = ANY (ids)) = 900,
         'SIM-ORG-17: 10% of 2 x $45';
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  r := public.exos_settle_promoter(p, ids, 900, 'Venmo', 'sim17-settle-1');
  ASSERT pg_temp.err(format($q$SELECT public.exos_settle_promoter(%L, %L, 900, 'Venmo', 'sim17-settle-2')$q$, p, ids)) LIKE '%already paid%',
         'SIM-ORG-17: settled twice';
  ASSERT (public.exos_settle_promoter(p, ids, 900, 'Venmo', 'sim17-settle-1')->>'replayed')::boolean, 'SIM-ORG-17: retry not replayed';
  ASSERT (SELECT count(*) FROM public.exos_promoter_payouts WHERE promoter_id = p) = 1, 'SIM-ORG-17: two payouts';
  -- Commission raised to 20% with "reprice": the paid rows keep 10%; the next sale is at 20%.
  n := public.exos_set_promoter_terms(p, 2000, 0, NULL, true);
  ASSERT n = 0, 'SIM-ORG-17: repriced a paid row: ' || n;
  ASSERT (SELECT sum(commission_cents) FROM public.exos_promoter_commissions WHERE id = ANY (ids)) = 900, 'SIM-ORG-17: paid rows changed';
  -- A step (20 -> 30% from the 3rd ticket on), set after sales.
  PERFORM public.exos_set_promoter_step(p, 2, 3000, 0, NULL, false);
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_fulfill_checkout('cs_5a_p2');
  ASSERT (SELECT c.commission_cents FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id
           WHERE t.order_ref = 'cs_5a_p2') = 1350, 'SIM-ORG-17: the 3rd ticket earns the step rate: ' ||
         (SELECT string_agg(c.commission_cents || '/' || c.rate_bps || '/' || c.base_cents || '/' || coalesce(c.stepped::text, '-'), ',')
            FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id WHERE t.order_ref = 'cs_5a_p2');
  ASSERT (SELECT sum(commission_cents) FROM public.exos_promoter_commissions WHERE id = ANY (ids)) = 900, 'SIM-ORG-17: step repriced paid';
  RAISE NOTICE 'OK  SIM-ORG-17 a second settlement is refused, a retry replays; new terms / steps never touch paid commission';
END $$;

-- SIM-ORG-18 ------------------------------------------------------------------
-- A rental invoice issued twice; voided, and the number expected back.
DO $$
DECLARE r jsonb; i uuid; n1 text; r2 jsonb;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a3');
  r := public.exos_rental_invoice_create(pg_temp.u('01'), jsonb_build_object('title', 'Room rental', 'bill_to_name', 'Party Host',
         'items', jsonb_build_array(jsonb_build_object('title', 'Room hire', 'quantity', 1, 'cost_type', 'fixed', 'cost_cents', 50000))));
  i := (r->>'id')::uuid;
  r := public.exos_rental_invoice_issue(i, NULL);
  n1 := r->>'number';
  r := public.exos_rental_invoice_issue(i, NULL);
  ASSERT (r->>'already_issued')::boolean AND r->>'number' = n1, 'SIM-ORG-18: issued twice ' || r::text;
  r := public.exos_rental_invoice_set_status(i, 'void', 'wrong client');
  ASSERT r->>'status' = 'void' AND r->>'number' = n1, 'SIM-ORG-18: void';
  ASSERT pg_temp.err(format($q$SELECT public.exos_rental_invoice_set_status(%L, 'issued')$q$, i)) LIKE '55000%', 'SIM-ORG-18: un-voided';
  r2 := public.exos_rental_invoice_create(pg_temp.u('01'), jsonb_build_object('title', 'Room rental', 'bill_to_name', 'Right Client',
          'items', jsonb_build_array(jsonb_build_object('title', 'Room hire', 'quantity', 1, 'cost_type', 'fixed', 'cost_cents', 50000))));
  r2 := public.exos_rental_invoice_issue((r2->>'id')::uuid, NULL);
  ASSERT r2->>'number' <> n1, 'SIM-ORG-18: a void number was reused';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-18 issuing twice is a no-op; a void keeps its number (never reused) and can''t come back';
END $$;

-- SIM-ORG-19 ------------------------------------------------------------------
-- The GL backfill run twice, and again after more sales came in.
DO $$
DECLARE r jsonb; r2 jsonb;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a3');
  r := public.exos_gl_backfill(pg_temp.u('e1'));
  r2 := public.exos_gl_backfill(pg_temp.u('e1'));
  ASSERT (r2->>'created')::int = 0 AND (r2->>'retagged')::int = 0 AND (r2->>'rows')::int = (r->>'rows')::int, 'SIM-ORG-19: ' || r2::text;
  -- A sale lands between runs (a backfill "while sales are still happening").
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status, payment_intent)
  VALUES ('cs_5a_gl', pg_temp.u('e1'), pg_temp.u('d1'), pg_temp.u('01'), pg_temp.u('b1'), 'sim-buyer@x.com', 1, 4500, 'fulfilled', 'pi_5a_gl');
  r2 := public.exos_gl_backfill(pg_temp.u('e1'));
  ASSERT (r2->>'created')::int = 1 AND (SELECT count(*) FROM public.exos_reporting_rows WHERE source_id = 'cs_5a_gl') = 1, 'SIM-ORG-19: late sale ' || r2::text;
  -- A content user can't run it.
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.err($q$SELECT public.exos_gl_backfill(pg_temp.u('e1'))$q$) LIKE '42501%', 'SIM-ORG-19: content ran the backfill';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-19 GL backfill is idempotent; a re-run picks up sales made since (one row each)';
END $$;

-- ============================================================================
-- Team and settings
-- ============================================================================
ALTER TABLE public.exos_orgs ENABLE ROW LEVEL SECURITY;
CREATE POLICY sim_orgs_sel ON public.exos_orgs FOR SELECT TO authenticated USING (true);
CREATE POLICY sim_orgs_upd ON public.exos_orgs FOR UPDATE TO authenticated
  USING (exos_has_org_role(id, ARRAY['owner'])) WITH CHECK (exos_has_org_role(id, ARRAY['owner']));
GRANT SELECT, UPDATE ON public.exos_orgs TO authenticated;

-- SIM-ORG-20 ------------------------------------------------------------------
-- A content user tries finance writes; a manager tries owner-only settings.
SET ROLE authenticated;
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a4');   -- content
  ASSERT pg_temp.err($q$SELECT public.exos_rental_invoice_create(pg_temp.u('01'), '{"title":"x"}')$q$) LIKE '42501%', 'SIM-ORG-20: content invoices';
  ASSERT pg_temp.err($q$SELECT public.exos_set_promoter_terms(pg_temp.u('f1'), 5000, 0)$q$) LIKE '42501%', 'SIM-ORG-20: content sets commission';
  ASSERT pg_temp.err($q$SELECT public.exos_ledger_import(pg_temp.u('e1'), '[]')$q$) LIKE '42501%', 'SIM-ORG-20: content imports ledger';
  ASSERT pg_temp.err($q$SELECT public.exos_cash_summary(pg_temp.u('e1'), NULL, NULL)$q$) LIKE '42501%', 'SIM-ORG-20: content reads cash';
  ASSERT pg_temp.err($q$UPDATE public.exos_ticket_tiers SET price = 1 WHERE id = pg_temp.u('d1')$q$) = '', 'SIM-ORG-20: statement';
  ASSERT (SELECT price FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 45, 'SIM-ORG-20: content repriced';
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');   -- manager
  ASSERT pg_temp.err($q$SELECT public.exos_order_settings_save(pg_temp.u('01'), true, 5)$q$) LIKE '42501%', 'SIM-ORG-20: manager saved order settings';
  UPDATE public.exos_orgs SET name = 'Renamed by manager' WHERE id = pg_temp.u('01');
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'SIM-ORG-20: manager renamed the org';
  ASSERT pg_temp.err($q$INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES (pg_temp.u('01'), pg_temp.u('b2'), 'manager')$q$)
         LIKE '42501%', 'SIM-ORG-20: manager added a member';
  UPDATE public.exos_org_memberships SET role = 'owner' WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a2');
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'SIM-ORG-20: manager made themselves owner';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-20 content can''t write finance (refused or silently no row); a manager can''t touch owner-only settings or members';
END $$;
RESET ROLE;

-- SIM-ORG-21 ------------------------------------------------------------------
-- The only owner removes, disables or demotes themselves.
SET ROLE authenticated;
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.err($q$DELETE FROM public.exos_org_memberships WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a1')$q$)
         LIKE '%last owner%', 'SIM-ORG-21: last owner left';
  ASSERT pg_temp.err($q$UPDATE public.exos_org_memberships SET disabled = true WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a1')$q$)
         LIKE '%last owner%', 'SIM-ORG-21: last owner disabled';
  ASSERT pg_temp.err($q$UPDATE public.exos_org_memberships SET role = 'manager' WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a1')$q$)
         LIKE '%last owner%', 'SIM-ORG-21: last owner demoted';
  -- With a second owner, the first may step down.
  INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES (pg_temp.u('01'), pg_temp.u('a6'), 'owner');
  UPDATE public.exos_org_memberships SET role = 'manager' WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a1');
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, 'SIM-ORG-21: step down with a co-owner';
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a6');
  ASSERT pg_temp.err($q$DELETE FROM public.exos_org_memberships WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a6')$q$)
         LIKE '%last owner%', 'SIM-ORG-21: the new last owner left';
  UPDATE public.exos_org_memberships SET role = 'owner' WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a1');
  DELETE FROM public.exos_org_memberships WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a6');
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-21 FIXED the last active owner can''t leave, be disabled or demoted; with a co-owner they can';
END $$;
RESET ROLE;

-- SIM-ORG-22 ------------------------------------------------------------------
-- Receipt override: on, the buyer email edited to a typo, a resend.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  r := public.exos_order_update('cs_5a_p1', '{"email":"sim-buyer@x.cm"}');           -- typo
  -- Override off (default): the resend still goes to the address the order was placed with.
  r := public.exos_order_send_receipt('cs_5a_p1');
  ASSERT r->>'to' = 'sim-buyer@x.com' AND NOT (r->>'override')::boolean, 'SIM-ORG-22: off ' || r::text;
  ASSERT pg_temp.err($q$SELECT public.exos_order_send_receipt('cs_5a_p1', 'someone@else.com')$q$) LIKE '42501%', 'SIM-ORG-22: off, any address';
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_order_settings_save(pg_temp.u('01'), true, 3);
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  r := public.exos_order_send_receipt('cs_5a_p1');
  ASSERT r->>'to' = 'sim-buyer@x.cm' AND (r->>'override')::boolean, 'SIM-ORG-22: on ' || r::text;
  ASSERT position('/claim/' in (SELECT html FROM public.exos_mail WHERE id = (r->>'mail_id')::uuid)) = 0, 'SIM-ORG-22: claim link to the wrong person';
  ASSERT (SELECT bool_and(buyer_email = 'sim-buyer@x.com') FROM public.exos_tickets WHERE order_ref = 'cs_5a_p1'), 'SIM-ORG-22: tickets moved';
  ASSERT EXISTS (SELECT 1 FROM public.exos_order_edits WHERE session_id = 'cs_5a_p1' AND action = 'order.receipt'
                  AND changes->>'to' = 'sim-buyer@x.cm'), 'SIM-ORG-22: no audit row';
  -- Undo: the email back, resend to the right person (rate limit 3 an hour).
  PERFORM public.exos_order_update('cs_5a_p1', '{"email":"sim-buyer@x.com"}');
  r := public.exos_order_send_receipt('cs_5a_p1');
  ASSERT r->>'to' = 'sim-buyer@x.com', 'SIM-ORG-22: fix';
  ASSERT pg_temp.err($q$SELECT public.exos_order_send_receipt('cs_5a_p1')$q$) LIKE '54000%', 'SIM-ORG-22: rate limit';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-22 a wrong-address resend is a receipt only (no claim links, tickets stay), audited, rate limited';
END $$;

-- ============================================================================
-- Distribution
-- ============================================================================

-- SIM-ORG-23 ------------------------------------------------------------------
-- The wrong Eventbrite event linked; its attendees sync onto the door list;
-- the organizer relinks to the right one.
CREATE FUNCTION pg_temp.eb_apply(p_rows jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.exos_eventbrite_links SET lease_until = NULL, last_synced_at = NULL WHERE event_id = pg_temp.u('e1');
  PERFORM 1 FROM public.exos_eventbrite_sync_claim(pg_temp.u('e1'), pg_temp.u('a1'));
  RETURN public.exos_eventbrite_apply(pg_temp.u('e1'), (SELECT lease_id FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')),
                                      p_rows, 'done', NULL, NULL);
END $$;
DO $$
DECLARE r jsonb; g uuid; v_wrong jsonb := '[{"ref":"8001","code":"WRONG0001","name":"Wrong Event Guest","void":false},
                                              {"ref":"8002","code":"WRONG0002","name":"Already In","void":false}]';
BEGIN
  -- Door test window on, so the door answers before doors open.
  UPDATE public.exos_events SET checkin_test_mode = true, checkin_test_until = now() + interval '1 hour' WHERE id = pg_temp.u('e1');
  PERFORM public.exos_eventbrite_connect(pg_temp.u('01'), pg_temp.u('a1'), 'TOKENSIM5A0001', 'Sim EB');
  r := public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a2'), '111', 'Some other night');
  r := pg_temp.eb_apply(v_wrong);
  ASSERT (r->>'added')::int = 2, 'SIM-ORG-23: sync ' || r::text;
  -- One wrong guest got in before anyone noticed (an arrival, as the door records it).
  UPDATE public.exos_guest_list_entries SET arrived = 1, arrived_at = now()
   WHERE event_id = pg_temp.u('e1') AND external_ref = 'eb:8002';
  r := public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a2'), '222', 'Sim Night');
  ASSERT (r->>'relinked')::boolean, 'SIM-ORG-23: relinked';
  g := (SELECT id FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND external_ref = 'eb:8001');
  ASSERT (SELECT voided_at IS NOT NULL FROM public.exos_guest_list_entries WHERE id = g), 'SIM-ORG-23: the wrong event''s guest is still admissible';
  ASSERT (SELECT voided_at IS NULL AND arrived = 1 FROM public.exos_guest_list_entries WHERE external_ref = 'eb:8002' AND event_id = pg_temp.u('e1')),
         'SIM-ORG-23: an arrived guest was voided (the count would drop): ' ||
         (SELECT row_to_json(x)::text FROM (SELECT arrived, voided_at, void_reason FROM public.exos_guest_list_entries
                                             WHERE external_ref = 'eb:8002' AND event_id = pg_temp.u('e1')) x);
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a5');
  r := public.exos_guest_check_in(g, 1, pg_temp.u('e1'), gen_random_uuid());
  ASSERT (r->>'ok')::boolean = false AND r->>'reason' = 'voided', 'SIM-ORG-23: door admitted ' || r::text;
  PERFORM pg_temp.act(NULL);
  -- Linking back (it was right after all): the next sync sends them again and restores them.
  r := public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a2'), '111', 'Some other night');
  r := pg_temp.eb_apply(v_wrong);
  ASSERT (SELECT voided_at IS NULL FROM public.exos_guest_list_entries WHERE id = g), 'SIM-ORG-23: not restored ' || r::text;
  UPDATE public.exos_events SET checkin_test_mode = false, checkin_test_until = NULL WHERE id = pg_temp.u('e1');
  RAISE NOTICE 'OK  SIM-ORG-23 FIXED relinking Eventbrite voids the old link''s unarrived guests; linking back restores them';
END $$;

-- SIM-ORG-24 ------------------------------------------------------------------
-- Posh retries a webhook; the organizer cancels an order and Posh replays
-- the original create afterwards.
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
DO $$
DECLARE c jsonb; th text; r jsonb; o uuid; v0 int := pg_temp.sold('d1');
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a1');
  c := public.exos_posh_connect(pg_temp.u('01'));
  th := pg_temp.h(c->>'token');
  PERFORM public.exos_posh_set_cap(pg_temp.u('e1'), pg_temp.u('d1'), 10);
  PERFORM public.exos_posh_link_event(pg_temp.u('01'), 'https://posh.vip/e/sim-night', pg_temp.u('e1'));
  PERFORM pg_temp.act(NULL);
  r := public.exos_posh_ingest(th, pg_temp.h('sim-p1'), 'order_created', '{"order_id":"p1","event_slug":"sim-night","quantity":2}',
                               '{"body":"sim-p1"}', ARRAY['Content-Type'], false);
  ASSERT r->>'outcome' = 'confirmed', 'SIM-ORG-24: ' || r::text;
  r := public.exos_posh_ingest(th, pg_temp.h('sim-p1'), 'order_created', '{"order_id":"p1","event_slug":"sim-night","quantity":2}',
                               '{"body":"sim-p1"}', ARRAY['Content-Type'], true);
  ASSERT r->>'outcome' = 'duplicate' AND pg_temp.sold('d1') = v0 + 2, 'SIM-ORG-24: replay counted ' || r::text || pg_temp.sold('d1');
  o := (SELECT id FROM public.exos_posh_orders WHERE org_id = pg_temp.u('01') AND order_key = 'o:p1');
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  PERFORM public.exos_posh_cancel_order(o);
  PERFORM pg_temp.act(NULL);
  r := public.exos_posh_ingest(th, pg_temp.h('sim-p1-late'), 'order_created', '{"order_id":"p1","event_slug":"sim-night","quantity":2}',
                               '{"body":"sim-p1-late"}', ARRAY['Content-Type'], true);
  ASSERT r->>'outcome' = 'duplicate' AND pg_temp.sold('d1') = v0
     AND (SELECT state FROM public.exos_posh_orders WHERE id = o) = 'cancelled', 'SIM-ORG-24: late replay revived the order';
  RAISE NOTICE 'OK  SIM-ORG-24 Posh replays count once; a cancelled order stays cancelled when Posh replays it';
END $$;

-- SIM-ORG-25 ------------------------------------------------------------------
-- A fixed block bigger than the event's cap, or smaller than what's sold.
DO $$
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_posh_disconnect(pg_temp.u('01'));
  ASSERT pg_temp.err(format($q$SELECT public.exos_set_fixed_block(pg_temp.u('e1'), true, 'Venue box office', NULL, '{"%s": 500, "%s": 20}')$q$,
                            pg_temp.u('d1'), pg_temp.u('d2'))) LIKE '%event total (100) is below the block%', 'SIM-ORG-25: block over the cap';
  ASSERT pg_temp.err(format($q$SELECT public.exos_set_fixed_block(pg_temp.u('e1'), true, 'Venue box office', NULL, '{"%s": 3, "%s": 20}')$q$,
                            pg_temp.u('d1'), pg_temp.u('d2'))) LIKE '%can''t be smaller%', 'SIM-ORG-25: block under sold';
  ASSERT (SELECT primary_source FROM public.exos_events WHERE id = pg_temp.u('e1')) = 'exos', 'SIM-ORG-25: half applied';
  ASSERT (SELECT capacity FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = 100, 'SIM-ORG-25: capacity changed by a refused call';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-25 a fixed block over the cap or under sold is refused, all or nothing';
END $$;

-- SIM-ORG-26 ------------------------------------------------------------------
-- A link-out event (sold on the organizer's own checkout): the organizer
-- adds an Exos ticket type, mints a comp, turns link-out off, or lists it.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, venue_name, link_out, external_ticket_url, ticket_backend, created_by) VALUES
  ('5a000000-0000-0000-0000-0000000000e5', '5a000000-0000-0000-0000-000000000001', 'Sim Elsewhere', 'sim-elsewhere-5a', 'published',
   now() + interval '25 days', 'America/New_York', 'Club', true, 'https://tickets.example.com/sim', 'eventbrite', '5a000000-0000-0000-0000-0000000000a1');
SET ROLE authenticated;
SELECT pg_temp.act('5a000000-0000-0000-0000-0000000000a2', 'sim-manager@x.com');
SELECT pg_temp.put('26_tier', pg_temp.err($$INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity) VALUES (pg_temp.u('e5'), 'GA', 20, 50)$$));
SELECT pg_temp.put('26_flip', pg_temp.err($$UPDATE public.exos_events SET link_out = false WHERE id = pg_temp.u('e5')$$));
SELECT pg_temp.put('26_list', pg_temp.err($$UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub'] WHERE id = pg_temp.u('e5')$$));
SELECT pg_temp.put('26_comp', pg_temp.err($$SELECT public.exos_issue_ticket_to_email(pg_temp.u('e5'), NULL, 'x@x.com', 1)$$));
RESET ROLE;
DO $$
BEGIN
  ASSERT pg_temp.g('26_tier') LIKE '%link-out%', 'SIM-ORG-26: tier on a link-out event ' || pg_temp.g('26_tier');
  ASSERT pg_temp.g('26_flip') LIKE '%link-out%', 'SIM-ORG-26: link-out flipped ' || pg_temp.g('26_flip');
  ASSERT pg_temp.g('26_list') LIKE '%link-out%', 'SIM-ORG-26: listed on a marketplace ' || pg_temp.g('26_list');
  ASSERT pg_temp.g('26_comp') LIKE '%link-out%', 'SIM-ORG-26: comp minted ' || pg_temp.g('26_comp');
  ASSERT public.exos_event_is_free_tier(pg_temp.u('e5')) AND NOT public.exos_resale_unlocked(pg_temp.u('e5')), 'SIM-ORG-26: tiering';
  RAISE NOTICE 'OK  SIM-ORG-26 a link-out event sells nothing on Exos: no tiers, no comps, no marketplaces, link-out stays on';
END $$;

-- ============================================================================
-- Membership products
-- ============================================================================

-- SIM-ORG-27 ------------------------------------------------------------------
-- A product with active members archived by mistake, then republished.
SET ROLE authenticated;
DO $$
DECLARE r jsonb; p uuid; m uuid;
BEGIN
  PERFORM pg_temp.act('5a000000-0000-0000-0000-0000000000a2');
  r := public.exos_membership_product_save(pg_temp.u('01'), NULL, '{"name":"Sim Gold","price_cents":1500,"billing":"month"}');
  p := (r->>'id')::uuid;
  PERFORM public.exos_membership_product_transition(p, 'publish');
  r := public.exos_membership_issue(pg_temp.u('01'), jsonb_build_object('product_id', p, 'email', 'sim-buyer@x.com'));
  m := (r->>'id')::uuid;
  r := public.exos_membership_product_transition(p, 'archive');
  ASSERT r->>'status' = 'archived', 'SIM-ORG-27: archive';
  ASSERT pg_temp.err(format($q$SELECT public.exos_membership_product_transition(%L, 'publish')$q$, p)) LIKE '55000%', 'SIM-ORG-27: republished';
  ASSERT (SELECT status FROM public.exos_fan_memberships WHERE id = m) = 'active', 'SIM-ORG-27: the member lost their membership';
  ASSERT pg_temp.err(format($q$SELECT public.exos_membership_issue(pg_temp.u('01'), '{"product_id":"%s","email":"new@x.com"}')$q$, p)) <> '',
         'SIM-ORG-27: a new member on an archived product';
  -- The way back: a new product with the same name (free again once archived).
  r := public.exos_membership_product_save(pg_temp.u('01'), NULL, '{"name":"Sim Gold","price_cents":1500,"billing":"month"}');
  ASSERT r->>'status' = 'draft', 'SIM-ORG-27: same name again';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  SIM-ORG-27 archiving is final (by design) but members keep their membership; recovery = a new product, same name';
END $$;
RESET ROLE;

ROLLBACK;
