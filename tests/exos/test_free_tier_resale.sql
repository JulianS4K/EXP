-- ============================================================================
-- Free tier and the resale opt-in (mig 20261029090000):
--   T1 the cutoff: 150 is the free tier, 151 isn't; a table counts its party
--      size; an event with no max (uncapped type, no overall cap) isn't free tier
--   T2 over 150 without an opt-in: every resale path refused / planned out,
--      with the opt-in reason
--   T3 the opt-in: refused at 150 (the reason), for finance / scanner /
--      strangers / anon, and with a stale text version; recorded with who,
--      when, the version and the max capacity; idempotent
--   T4 opted in: allocation, request, marketplace event row, auto split, S4K
--      route, split and feed all work
--   T5 withdrawing: pulled at once (event row, pools 0, S4K pool released,
--      listings dropped, off the feed); allocations refused again
--   T6 a capacity drop to 150 revokes it (ticket type, overall cap, table
--      party size); going back over needs a new opt-in
--   T7 settings: the cutoff and the opt-in rule are operator rows; bad values
--      fall back; the old resale_min_capacity key is gone
--   T8 the fee: 0 on the free tier (free_tier_fee_bps), 3% over it after the
--      free months; marketplace sale and POS settlement use the event's rate
--   T8b a bypass voucher selling past 150 ends the free tier (fee terms say
--       paid, sold + the order's quantity counted); resale then needs the opt-in
--   T9 RLS on exos_resale_consents; grants (nothing anon; helpers service only)
--   T10 deleting an opted-in event still works
-- Self-contained (c9 prefix), rolled back. The harness turns the rules off for
-- older fixtures; this file puts the defaults back first.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
DELETE FROM public.exos_platform_settings
 WHERE key IN ('free_tier_max_capacity', 'resale_consent_required', 'free_tier_fee_bps', 'last_call_threshold');
-- Last call (mig 20261029100000) off here: these events sell nothing.
INSERT INTO public.exos_platform_settings (key, value) VALUES ('last_call_threshold', '0');

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c9000000-0000-0000-0000-0000000000a0','c9-owner@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a1','c9-manager@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a2','c9-finance@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a3','c9-scanner@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a4','c9-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c9000000-0000-0000-0000-000000000001','C9 Org','c9-org','c9000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a0','owner'),
  ('c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a1','manager'),
  ('c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a2','finance'),
  ('c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a3','scanner');
-- e1: 150 (100 + 50). e2: 151 (100 + 51). e3: tables 75 x 2 = 150.
-- e4: no max (100 + an uncapped paid type). e5: cap 300 over 300 of types.
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,purchase_limits,timezone,distribution_networks) VALUES
  ('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-000000000001','Room 150','draft',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":4}','America/New_York','{}'),
  ('c9000000-0000-0000-0000-0000000000e2','c9000000-0000-0000-0000-000000000001','Room 151','draft',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":4}','America/New_York','{}'),
  ('c9000000-0000-0000-0000-0000000000e3','c9000000-0000-0000-0000-000000000001','Tables','draft',now() + interval '20 days','Hall',0,0,'{}','America/New_York','{}'),
  ('c9000000-0000-0000-0000-0000000000e4','c9000000-0000-0000-0000-000000000001','Open','draft',now() + interval '20 days','Hall',0,0,'{}','America/New_York','{}'),
  ('c9000000-0000-0000-0000-0000000000e5','c9000000-0000-0000-0000-000000000001','Big','draft',now() + interval '20 days','Hall',300,0,'{"maxPerOrder":4}','America/New_York','{}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order,kind,party_size) VALUES
  ('c9000000-0000-0000-0000-0000000000d1','c9000000-0000-0000-0000-0000000000e1','GA',40,100,0,'public',1,'standard',NULL),
  ('c9000000-0000-0000-0000-0000000000d2','c9000000-0000-0000-0000-0000000000e1','VIP',90,50,0,'public',2,'standard',NULL),
  ('c9000000-0000-0000-0000-0000000000d3','c9000000-0000-0000-0000-0000000000e2','GA',40,100,0,'public',1,'standard',NULL),
  ('c9000000-0000-0000-0000-0000000000d4','c9000000-0000-0000-0000-0000000000e2','VIP',90,51,0,'public',2,'standard',NULL),
  ('c9000000-0000-0000-0000-0000000000d5','c9000000-0000-0000-0000-0000000000e3','Table',200,75,0,'public',1,'table',2),
  ('c9000000-0000-0000-0000-0000000000d6','c9000000-0000-0000-0000-0000000000e4','GA',40,100,0,'public',1,'standard',NULL),
  ('c9000000-0000-0000-0000-0000000000d7','c9000000-0000-0000-0000-0000000000e4','Open',40,0,0,'public',2,'standard',NULL),
  ('c9000000-0000-0000-0000-0000000000d8','c9000000-0000-0000-0000-0000000000e5','GA',40,200,0,'public',1,'standard',NULL),
  ('c9000000-0000-0000-0000-0000000000d9','c9000000-0000-0000-0000-0000000000e5','VIP',90,100,0,'public',2,'standard',NULL);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"c9@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('c9000000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
CREATE FUNCTION pg_temp.event_row(p_event text, p_ch text) RETURNS public.exos_distribution_listings LANGUAGE sql AS $$
  SELECT * FROM public.exos_distribution_listings WHERE event_id = pg_temp.u(p_event) AND channel = p_ch AND tier_id IS NULL
$$;
CREATE FUNCTION pg_temp.optin(p_event text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_set_resale_consent(pg_temp.u(p_event), true, '2026-10-29')
$$;

-- T1. The cutoff.
DO $$
BEGIN
  ASSERT public.exos_free_tier_max_capacity() = 150, 'T1: default 150';
  ASSERT public.exos_resale_min_capacity() = 151, 'T1: the old number is 151';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e1')) = 150 AND public.exos_event_is_free_tier(pg_temp.u('e1')), 'T1: 150 is free tier';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e2')) = 151 AND NOT public.exos_event_is_free_tier(pg_temp.u('e2')), 'T1: 151 is not';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e3')) = 150 AND public.exos_event_is_free_tier(pg_temp.u('e3')), 'T1: 75 tables of 2';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e4')) = 100 AND NOT public.exos_event_capacity_bounded(pg_temp.u('e4'))
     AND NOT public.exos_event_is_free_tier(pg_temp.u('e4')), 'T1: no max is not the free tier';
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e4')), 'T1: but its capped 100 cannot resell';
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e1')) AND NOT public.exos_resale_unlocked(pg_temp.u('e3')), 'T1: free tier locked';
END $$;
-- A 76th table: 152.
UPDATE public.exos_ticket_tiers SET capacity = 76 WHERE id = pg_temp.u('d5');
DO $$ BEGIN
  ASSERT NOT public.exos_event_is_free_tier(pg_temp.u('e3')), 'T1: 76 tables of 2';
END $$;
UPDATE public.exos_ticket_tiers SET capacity = 75 WHERE id = pg_temp.u('d5');

-- T2. 151 with no opt-in: locked, with the opt-in reason.
DO $$
BEGIN
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_events SET status = 'published', distribution_networks = ARRAY['stubhub']
   WHERE id IN (pg_temp.u('e1'), pg_temp.u('e2'));
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e2')), 'T2: 151 locked without the opt-in';
  ASSERT (pg_temp.event_row('e2', 'stubhub')).id IS NULL AND (pg_temp.event_row('e1', 'stubhub')).id IS NULL, 'T2: no event rows';
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT public.exos_set_channel_allocation(pg_temp.u('e2'), 'stubhub', pg_temp.u('d3'), 10)$q$,
                         'until an owner or manager opts in'), 'T2: allocation';
  ASSERT pg_temp.refused($q$SELECT public.exos_request_distribution(pg_temp.u('e2'), ARRAY['stubhub'])$q$,
                         'until an owner or manager opts in'), 'T2: request';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_channel_allocation(pg_temp.u('e1'), 'stubhub', pg_temp.u('d1'), 10)$q$,
                         'need a max capacity over 150 (events of 150 or less are the free tier: no Exos fee, never resold); this event''s is 150'),
         'T2: free tier allocation';
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e2'))), 'T2: no auto split';
  PERFORM public.exos_set_s4k_network('c9000000-0000-0000-0000-000000000001', true);
  ASSERT pg_temp.refused($q$SELECT public.exos_set_distribution_route(pg_temp.u('e2'), 's4k')$q$,
                         'until an owner or manager opts in'), 'T2: S4K route';
END $$;

-- T3. The opt-in.
DO $$
DECLARE r jsonb; c public.exos_resale_consents%ROWTYPE;
BEGIN
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT pg_temp.optin('e1')$q$, 'need a max capacity over 150'), 'T3: refused at 150';
  ASSERT pg_temp.refused($q$SELECT pg_temp.optin('e3')$q$, 'this event''s is 150'), 'T3: refused at 75 tables of 2';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_resale_consent(pg_temp.u('e2'), true, '2026-01-01')$q$, 'the resale terms changed'), 'T3: stale text';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_resale_consent(pg_temp.u('e2'), true)$q$, 'the resale terms changed'), 'T3: no version';
  FOREACH r IN ARRAY ARRAY['"a2"', '"a3"', '"a4"', '""']::jsonb[] LOOP
    PERFORM pg_temp.act(CASE WHEN r #>> '{}' = '' THEN NULL ELSE 'c9000000-0000-0000-0000-0000000000' || (r #>> '{}') END);
    ASSERT pg_temp.refused($q$SELECT pg_temp.optin('e2')$q$, 'not allowed'), 'T3: refused for ' || r::text;
  END LOOP;
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a1');   -- a manager may
  r := pg_temp.optin('e2');
  ASSERT (r ->> 'resale_unlocked')::boolean AND (r -> 'consent' ->> 'given_by_email') = 'c9-manager@x.com', 'T3: opted in ' || r::text;
  SELECT * INTO c FROM public.exos_resale_consents WHERE event_id = pg_temp.u('e2') AND revoked_at IS NULL;
  ASSERT c.given_by = pg_temp.u('a1') AND c.consent_version = '2026-10-29' AND c.max_capacity_at_consent = 151
     AND c.cutoff_at_consent = 150 AND c.given_at IS NOT NULL AND c.org_id = 'c9000000-0000-0000-0000-000000000001', 'T3: the record';
  PERFORM pg_temp.optin('e2');
  ASSERT (SELECT count(*) FROM public.exos_resale_consents WHERE event_id = pg_temp.u('e2')) = 1, 'T3: idempotent';
  -- Finance reads the rules, can't change them.
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a2');
  r := public.exos_event_sales_rules(pg_temp.u('e2'));
  ASSERT (r ->> 'resale_unlocked')::boolean AND NOT (r ->> 'can_manage')::boolean AND (r ->> 'free_tier_max_capacity')::int = 150, 'T3: finance reads';
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.refused($q$SELECT public.exos_event_sales_rules(pg_temp.u('e2'))$q$, 'not allowed'), 'T3: scanner can''t read';
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  r := public.exos_event_sales_rules(pg_temp.u('e1'));
  ASSERT (r ->> 'free_tier')::boolean AND (r ->> 'locked_reason') LIKE '%free tier%', 'T3: e1 shows the free tier';
END $$;

-- T4. Opted in: every path works.
DO $$
DECLARE r jsonb; v_alloc uuid;
BEGIN
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  ASSERT (pg_temp.event_row('e2', 'stubhub')).status = 'pending', 'T4: the opt-in made the event row';
  ASSERT public.exos_set_channel_allocation(pg_temp.u('e2'), 'stubhub', pg_temp.u('d3'), 10) = 10, 'T4: allocation';
  SELECT id INTO v_alloc FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u('d3') AND channel = 'stubhub';
  ASSERT (SELECT requested_qty FROM public.exos_distribution_listings WHERE id = v_alloc) > 0, 'T4: pool held';
  ASSERT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e2'))), 'T4: auto split plans';
  PERFORM public.exos_set_channel_allocation(pg_temp.u('e2'), 'stubhub', pg_temp.u('d3'), 0);
  UPDATE public.exos_events SET distribution_networks = '{}' WHERE id = pg_temp.u('e2');
  ASSERT public.exos_set_distribution_route(pg_temp.u('e2'), 's4k') = 's4k', 'T4: S4K route';
  r := public.exos_set_s4k_split(pg_temp.u('e2'), jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d3'), 'seats', 20)));
  ASSERT public._exos_feed_eligible(pg_temp.u('e2')), 'T4: on the feed';
  PERFORM public.exos_s4k_listings_sync(pg_temp.u('e2'));
  ASSERT EXISTS (SELECT 1 FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e2')), 'T4: listings';
END $$;

-- T5. Withdrawing pulls it at once.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  r := public.exos_set_resale_consent(pg_temp.u('e2'), false);
  ASSERT NOT (r ->> 'resale_unlocked')::boolean AND (r -> 'last_revoked' ->> 'reason') = 'withdrawn', 'T5: withdrawn ' || r::text;
  ASSERT (SELECT revoked_by FROM public.exos_resale_consents WHERE event_id = pg_temp.u('e2')) = pg_temp.u('a0'), 'T5: who withdrew';
  ASSERT NOT public._exos_feed_eligible(pg_temp.u('e2')), 'T5: off the feed';
  ASSERT (SELECT requested_qty FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u('d3') AND channel = 's4k') = 0, 'T5: S4K pool released';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e2')), 'T5: listings dropped';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_s4k_split(pg_temp.u('e2'), '[{"tier_id":"c9000000-0000-0000-0000-0000000000d3","seats":5}]')$q$,
                         'until an owner or manager opts in'), 'T5: no split';
  -- Back to direct, ticked StubHub with an allocation, then withdraw again.
  PERFORM public.exos_set_distribution_route(pg_temp.u('e2'), 'direct');
  PERFORM pg_temp.optin('e2');
  UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub'] WHERE id = pg_temp.u('e2');
  ASSERT public.exos_set_channel_allocation(pg_temp.u('e2'), 'stubhub', pg_temp.u('d3'), 10) = 10, 'T5: allocation again';
  PERFORM public.exos_set_resale_consent(pg_temp.u('e2'), false);
  ASSERT (pg_temp.event_row('e2', 'stubhub')).id IS NULL, 'T5: event row gone';
  ASSERT coalesce((SELECT requested_qty FROM public.exos_distribution_listings
                    WHERE tier_id = pg_temp.u('d3') AND channel = 'stubhub' AND status IN ('pending','planned','listing','listed')), 0) = 0,
         'T5: the pool holds nothing';
  ASSERT public.exos_effective_available(pg_temp.u('d3')) = 100, 'T5: all back to Exos';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_channel_allocation(pg_temp.u('e2'), 'stubhub', pg_temp.u('d3'), 10)$q$,
                         'until an owner or manager opts in'), 'T5: allocation refused again';
  ASSERT (SELECT count(*) FROM public.exos_resale_consents WHERE event_id = pg_temp.u('e2')) = 2, 'T5: history kept';
END $$;

-- T6. A drop to 150 revokes; going back over needs a new opt-in.
DO $$
BEGIN
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  PERFORM pg_temp.optin('e2');
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_ticket_tiers SET capacity = 50 WHERE id = pg_temp.u('d4');   -- 150
  ASSERT NOT public.exos_resale_consent_active(pg_temp.u('e2')), 'T6: revoked by a ticket type';
  ASSERT (SELECT count(*) FROM public.exos_resale_consents WHERE event_id = pg_temp.u('e2') AND revoke_reason = 'capacity_dropped'
            AND revoked_by IS NULL) = 1, 'T6: reason';
  UPDATE public.exos_ticket_tiers SET capacity = 51 WHERE id = pg_temp.u('d4');   -- 151 again
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e2')), 'T6: still locked: opt in again';
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  PERFORM pg_temp.optin('e2');
  ASSERT public.exos_resale_unlocked(pg_temp.u('e2')), 'T6: re-opted in';
  -- The overall cap.
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_events SET total_tickets = 140 WHERE id = pg_temp.u('e2');
  ASSERT NOT public.exos_resale_consent_active(pg_temp.u('e2')), 'T6: revoked by the overall cap';
  UPDATE public.exos_events SET total_tickets = 0 WHERE id = pg_temp.u('e2');
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e2')), 'T6: cap lifted, still needs the opt-in';
  -- Tables: 76 x 2 = 152, opted in; the party size to 1 (76) revokes it.
  UPDATE public.exos_ticket_tiers SET capacity = 76 WHERE id = pg_temp.u('d5');
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  PERFORM pg_temp.optin('e3');
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_ticket_tiers SET party_size = 1 WHERE id = pg_temp.u('d5');
  ASSERT NOT public.exos_resale_consent_active(pg_temp.u('e3')), 'T6: revoked by a party size change';
  -- A rise doesn't touch a live opt-in.
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  PERFORM pg_temp.optin('e5');
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_ticket_tiers SET capacity = 250 WHERE id = pg_temp.u('d8');
  ASSERT public.exos_resale_consent_active(pg_temp.u('e5')), 'T6: a rise keeps it';
END $$;

-- T7. Settings.
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_platform_settings WHERE key = 'resale_min_capacity'), 'T7: old key gone';
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('free_tier_max_capacity', '99');
  ASSERT NOT public.exos_event_is_free_tier(pg_temp.u('e1')), 'T7: 150 over a cutoff of 99';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_channel_allocation(pg_temp.u('e1'), 'stubhub', pg_temp.u('d1'), 1)$q$, 'opts in'), 'T7: still needs the opt-in';
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('resale_consent_required', 'false');
  ASSERT public.exos_resale_unlocked(pg_temp.u('e1')), 'T7: no opt-in needed when the operator says so';
  UPDATE public.exos_platform_settings SET value = '"x"' WHERE key = 'free_tier_max_capacity';
  UPDATE public.exos_platform_settings SET value = '1' WHERE key = 'resale_consent_required';
  ASSERT public.exos_free_tier_max_capacity() = 150 AND public.exos_resale_consent_required(), 'T7: bad values fall back';
  UPDATE public.exos_platform_settings SET value = '-5' WHERE key = 'free_tier_max_capacity';
  ASSERT public.exos_free_tier_max_capacity() = 150, 'T7: negative falls back';
  DELETE FROM public.exos_platform_settings WHERE key IN ('free_tier_max_capacity', 'resale_consent_required');
END $$;

-- T8. The fee.
DO $$
DECLARE j jsonb; o uuid; m record;
BEGIN
  -- New orgs are in their free months.
  ASSERT public.exos_event_fee_bps(pg_temp.u('e1'), now()) = 0 AND public.exos_event_fee_bps(pg_temp.u('e2'), now()) = 0, 'T8: free months';
  UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day' WHERE org_id = 'c9000000-0000-0000-0000-000000000001';
  ASSERT public.exos_event_fee_bps(pg_temp.u('e1'), now()) = 0, 'T8: free tier 0';
  ASSERT public.exos_event_fee_bps(pg_temp.u('e2'), now()) = 300, 'T8: 151 pays 3%';
  ASSERT public.exos_event_fee_bps(pg_temp.u('e4'), now()) = 300, 'T8: no max pays 3%';
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('free_tier_fee_bps', '50');
  ASSERT public.exos_event_fee_bps(pg_temp.u('e1'), now()) = 50, 'T8: the free tier''s rate is a setting';
  ASSERT public.exos_event_fee_bps(pg_temp.u('e1'), now() - interval '2 days') = 0, 'T8: free months still win';
  DELETE FROM public.exos_platform_settings WHERE key = 'free_tier_fee_bps';
  j := public.exos_event_fee_terms(pg_temp.u('e1'));
  ASSERT (j ->> 'max_capacity')::int = 150 AND (j ->> 'free_tier_max_capacity')::int = 150 AND (j ->> 'free_tier_fee_bps')::int = 0
     AND (j ->> 'free_tier')::boolean, 'T8: terms ' || j::text;
  j := public.exos_event_fee_terms(pg_temp.u('e4'));
  ASSERT (j -> 'max_capacity') = 'null'::jsonb AND NOT (j ->> 'free_tier')::boolean, 'T8: no max ' || j::text;
  -- A marketplace sale on a free-tier event (a listing still shrinking).
  INSERT INTO public.exos_marketplace_orders (channel, external_order_id, event_id, org_id, quantity, proceeds, sold_at, sale_status)
  VALUES ('stubhub', 'c9-1', pg_temp.u('e1'), 'c9000000-0000-0000-0000-000000000001', 2, 100, now(), 'confirmed') RETURNING id INTO o;
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  ASSERT m.exos_fee = 0 AND m.organizer_net = 100, 'T8: marketplace free tier';
  INSERT INTO public.exos_marketplace_orders (channel, external_order_id, event_id, org_id, quantity, proceeds, sold_at, sale_status)
  VALUES ('stubhub', 'c9-2', pg_temp.u('e2'), 'c9000000-0000-0000-0000-000000000001', 2, 100, now(), 'confirmed') RETURNING id INTO o;
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  ASSERT m.exos_fee = 3, 'T8: marketplace 3% over the cutoff';
  -- Box office.
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  ASSERT (public.exos_pos_settlement_summary(pg_temp.u('e1')) ->> 'fee_bps')::int = 0, 'T8: POS free tier';
  ASSERT (public.exos_pos_settlement_summary(pg_temp.u('e2')) ->> 'fee_bps')::int = 300, 'T8: POS 3%';
END $$;

-- T8b. Selling past the cap ends the free tier: capped at 150, 148 sold, a
-- bypass_capacity voucher order of 5 goes through (153 sold). The fee terms
-- then say paid tier, and resale is possible again with the opt-in.
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,purchase_limits,timezone,distribution_networks) VALUES
  ('c9000000-0000-0000-0000-0000000000e6','c9000000-0000-0000-0000-000000000001','Packed','published',now() + interval '20 days','Hall',0,148,'{}','America/New_York','{}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
  ('c9000000-0000-0000-0000-0000000000da','c9000000-0000-0000-0000-0000000000e6','GA',20,150,148,'public',1);
DO $$
DECLARE j jsonb; v uuid; ids uuid[];
BEGIN
  ASSERT public.exos_event_is_free_tier(pg_temp.u('e6')), 'T8b: free tier at 148 of 150';
  j := public.exos_event_fee_terms(pg_temp.u('e6'), pg_temp.u('da'), 2);
  ASSERT (j ->> 'free_tier')::boolean AND (j ->> 'sold')::int = 148 AND (j ->> 'order_admissions')::int = 2, 'T8b: 150 with the order ' || j::text;
  j := public.exos_event_fee_terms(pg_temp.u('e6'), pg_temp.u('da'), 3);
  ASSERT NOT (j ->> 'free_tier')::boolean, 'T8b: 151 with the order is paid ' || j::text;
  INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity)
  VALUES (pg_temp.u('e6'), 'C9PAST', pg_temp.u('da'), 5, true) RETURNING id INTO v;
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status, voucher_id)
  VALUES ('c9-past', pg_temp.u('e6'), pg_temp.u('da'), 'c9000000-0000-0000-0000-000000000001', pg_temp.u('a0'), 'c9-owner@x.com', 5, 10000, 'pending', v);
  ids := public.exos_fulfill_checkout('c9-past');
  ASSERT array_length(ids, 1) = 5, 'T8b: the bypass order went through';
  ASSERT public.exos_event_sold_count(pg_temp.u('e6')) = 153, 'T8b: 153 sold';
  ASSERT NOT public.exos_event_is_free_tier(pg_temp.u('e6')), 'T8b: no longer the free tier';
  j := public.exos_event_fee_terms(pg_temp.u('e6'), pg_temp.u('da'), 1);
  ASSERT NOT (j ->> 'free_tier')::boolean AND (j ->> 'max_capacity')::int = 150 AND (j ->> 'sold')::int = 153, 'T8b: terms ' || j::text;
  ASSERT public.exos_event_fee_bps(pg_temp.u('e6'), now()) = 300, 'T8b: 3% from here on';
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e6')), 'T8b: resale still needs the opt-in';
  PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a0');
  PERFORM pg_temp.optin('e6');
  ASSERT public.exos_resale_unlocked(pg_temp.u('e6')), 'T8b: opted in at 153 sold';
  PERFORM pg_temp.act(NULL);
END $$;

-- T9. RLS and grants.
DO $$ BEGIN PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a2'); END $$;
SET ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_resale_consents) >= 4, 'T9: finance reads its org''s';
END $$;
RESET ROLE;
DO $$ BEGIN PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a3'); END $$;
SET ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_resale_consents) = 0, 'T9: scanner reads none';
END $$;
RESET ROLE;
DO $$ BEGIN PERFORM pg_temp.act('c9000000-0000-0000-0000-0000000000a4'); END $$;
SET ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_resale_consents) = 0, 'T9: stranger reads none';
END $$;
RESET ROLE;
DO $$
DECLARE f text;
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_resale_consents', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_resale_consents', 'UPDATE')
     AND NOT has_table_privilege('anon', 'public.exos_resale_consents', 'SELECT'), 'T9: table grants';
  FOREACH f IN ARRAY ARRAY['public.exos_set_resale_consent(uuid, boolean, text)', 'public.exos_event_sales_rules(uuid)',
                           'public.exos_free_tier_max_capacity()', 'public.exos_resale_min_capacity()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'), 'T9: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_setting_int(text, integer, integer, integer)', 'public._exos_setting_bool(text, boolean)',
                           'public.exos_free_tier_fee_bps()', 'public.exos_resale_consent_required()',
                           'public.exos_event_capacity_bounded(uuid)', 'public.exos_event_is_free_tier(uuid)',
                           'public.exos_resale_consent_active(uuid)', 'public._exos_resale_consent_version()',
                           'public._exos_resale_consent_recheck(uuid)', 'public.exos_event_fee_bps(uuid, timestamp with time zone)',
                           'public.exos_event_fee_terms(uuid, uuid, integer)', 'public.exos_event_sold_count(uuid)',
                           'public.exos_event_tier_size(uuid)', 'public.exos_resale_unlocked(uuid)', 'public._exos_resale_locked_msg(uuid)',
                           'public.exos_tg_event_resale_consent()', 'public.exos_tg_tier_resale_resync()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'T9: service only ' || f;
  END LOOP;
  ASSERT (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
            AND p.proname IN ('exos_set_resale_consent', 'exos_event_sales_rules', 'exos_event_fee_bps', '_exos_resale_consent_recheck')
            AND NOT (p.proconfig @> ARRAY['search_path=public, pg_temp'])) = 0, 'T9: search_path';
END $$;

-- T10. An opted-in event can still be deleted.
DO $$ BEGIN
  DELETE FROM public.exos_events WHERE id = pg_temp.u('e5');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_resale_consents WHERE event_id = pg_temp.u('e5')), 'T10: gone with it';
END $$;

\echo 'test_free_tier_resale: all passed'
ROLLBACK;
