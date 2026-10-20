-- ============================================================================
-- SMS marketing (mig 20261016120000).
--   S1 phone normalizing; opt-in needs an account, a real number and consent
--      text mentioning STOP; re-opt-in after STOP clears the opt-out
--   S2 campaigns: owner / manager only, a connected Twilio / Telnyx needed;
--      the sender name and "Reply STOP" are added; quiet hours move the time
--   S3 audience: org list vs this event's ticket holders; opted-out skipped;
--      the 30-day cap of 8 skips a number
--   S4 drain: claim leases due rows; a number that opted out since queuing is
--      skipped; mark sent / dry_run / failed; campaign status follows
--   S5 inbound STOP / START; cancel; grants
-- Self-contained ids 60…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('60000000-0000-0000-0000-0000000000a1','smown@x.com',now()),
  ('60000000-0000-0000-0000-0000000000a3','smfin@x.com',now()),
  ('60000000-0000-0000-0000-0000000000b1','smfan1@x.com',now()),
  ('60000000-0000-0000-0000-0000000000b2','smfan2@x.com',now()),
  ('60000000-0000-0000-0000-0000000000b3','smfan3@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('60000000-0000-0000-0000-000000000001','SM Club','sm-org-stub','60000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('60000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-0000000000a1','owner'),
  ('60000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-0000000000a3','finance');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by) VALUES
  ('60000000-0000-0000-0000-0000000000e1','60000000-0000-0000-0000-000000000001','SM One','sm-one','published',now() + interval '9 days','America/New_York',100,1,'60000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('60000000-0000-0000-0000-0000000000d1','60000000-0000-0000-0000-0000000000e1','GA',30,100,1,'public');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source) VALUES
  ('60000000-0000-0000-0000-000000000c11','60000000-0000-0000-0000-0000000000e1','60000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-0000000000d1','GA',
   '60000000-0000-0000-0000-0000000000b1','60000000-0000-0000-0000-0000000000b1','smfan1@x.com','active','k',30,'cs_sm1','stripe');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('60000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
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
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated;
CREATE TEMP TABLE consent AS SELECT 'Text me about SM Club events. Up to 8 msgs/mo. Msg & data rates may apply. Reply STOP to cancel, HELP for help.'::text AS t;
GRANT SELECT ON consent TO authenticated;

-- S1 ----------------------------------------------------------------------
DO $$
BEGIN
  ASSERT public.exos_sms_normalize_phone('(212) 555-0100') = '+12125550100', 'S1: US 10 digits';
  ASSERT public.exos_sms_normalize_phone('1 212 555 0100') = '+12125550100', 'S1: US 11 digits';
  ASSERT public.exos_sms_normalize_phone('+44 7700 900123') = '+447700900123', 'S1: E.164';
  ASSERT public.exos_sms_normalize_phone('555-0100') IS NULL AND public.exos_sms_normalize_phone(NULL) IS NULL, 'S1: junk';
END $$;
SET LOCAL ROLE anon;
SELECT pg_temp.act(NULL);
SELECT set_config('sm.anon', pg_temp.refused($$SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '2125550101', (SELECT t FROM consent))$$, 'permission denied')::text, true);
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('60000000-0000-0000-0000-0000000000b1');
SELECT set_config('sm.badph', pg_temp.refused($$SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '555', (SELECT t FROM consent))$$, 'mobile number')::text, true);
SELECT set_config('sm.nocons', pg_temp.refused($$SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '2125550101', 'ok text me whenever you like')$$, 'consent')::text, true);
SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '(212) 555-0101', (SELECT t FROM consent), pg_temp.u('0000000000e1'), 'ticket');
SELECT pg_temp.act('60000000-0000-0000-0000-0000000000b2');
SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '2125550102', (SELECT t FROM consent));
SELECT pg_temp.act('60000000-0000-0000-0000-0000000000b3');
SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '2125550103', (SELECT t FROM consent));
SELECT set_config('sm.out3', public.exos_sms_opt_out_mine(pg_temp.u('000000000001'))::text, true);
SELECT set_config('sm.st3', public.exos_sms_my_status(pg_temp.u('000000000001'))::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('sm.anon')::boolean AND current_setting('sm.badph')::boolean AND current_setting('sm.nocons')::boolean, 'S1: refusals';
  ASSERT (SELECT consent_text FROM public.exos_sms_subscribers WHERE phone = '+12125550101') LIKE '%STOP%', 'S1: consent stored';
  ASSERT current_setting('sm.out3')::boolean AND NOT (current_setting('sm.st3')::jsonb->>'subscribed')::boolean, 'S1: opted out';
  ASSERT current_setting('sm.st3')::jsonb->>'phone_hint' = '…0103', 'S1: masked';
END $$;

-- S2 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('60000000-0000-0000-0000-0000000000a3');
SELECT set_config('sm.fin', pg_temp.refused($$SELECT public.exos_sms_create_campaign(pg_temp.u('000000000001'), 'Hi', 'org')$$, 'owner or manager')::text, true);
SELECT set_config('sm.finlist', (public.exos_sms_campaigns(pg_temp.u('000000000001'))->>'subscribers'), true);
SELECT pg_temp.act('60000000-0000-0000-0000-0000000000a1');
SELECT set_config('sm.noprov', pg_temp.refused($$SELECT public.exos_sms_create_campaign(pg_temp.u('000000000001'), 'Hi', 'org')$$, 'connect Twilio')::text, true);
RESET ROLE;
INSERT INTO public.exos_org_integrations(org_id, provider, config, status) VALUES (pg_temp.u('000000000001'), 'twilio', '{"from":"+12125550199"}', 'connected');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('60000000-0000-0000-0000-0000000000a1');
SELECT set_config('sm.long', pg_temp.refused($$SELECT public.exos_sms_create_campaign(pg_temp.u('000000000001'), repeat('x', 401), 'org')$$, '400')::text, true);
-- 3am New York next week: moves to 9:00.
SELECT set_config('sm.c1', public.exos_sms_create_campaign(pg_temp.u('000000000001'), 'Doors at 10 tonight!', 'org', NULL,
  ((date_trunc('day', now() AT TIME ZONE 'America/New_York') + interval '7 days 3 hours') AT TIME ZONE 'America/New_York'))::text, true);
SELECT set_config('sm.aud', public.exos_sms_audience(pg_temp.u('000000000001'), 'event_buyers', pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('sm.c2', public.exos_sms_create_campaign(pg_temp.u('000000000001'), 'Ticket holders: set times are up', 'event_buyers', pg_temp.u('0000000000e1'))::text, true);
RESET ROLE;
DO $$
DECLARE c1 jsonb := current_setting('sm.c1')::jsonb; c2 jsonb := current_setting('sm.c2')::jsonb;
BEGIN
  ASSERT current_setting('sm.fin')::boolean AND current_setting('sm.finlist')::int = 2, 'S2: finance reads, can''t send';
  ASSERT current_setting('sm.noprov')::boolean AND current_setting('sm.long')::boolean, 'S2: provider / length';
  ASSERT c1->>'body' = 'SM Club: Doors at 10 tonight! Reply STOP to opt out.', 'S2: body ' || c1::text;
  ASSERT ((c1->>'send_after')::timestamptz AT TIME ZONE 'America/New_York')::time = time '09:00', 'S2: quiet hours ' || c1::text;
  ASSERT (c1->>'queued')::int = 2, 'S2: org list minus the opted-out number';
  ASSERT (current_setting('sm.aud')::jsonb->>'total')::int = 1 AND (c2->>'queued')::int = 1, 'S3: only the ticket holder';
END $$;

-- S3 cap ------------------------------------------------------------------
-- Eight texts to b2's number in the last 30 days.
INSERT INTO public.exos_sms_campaigns(id, org_id, audience, body, provider, status, created_at) SELECT gen_random_uuid(), pg_temp.u('000000000001'), 'org', 'old', 'twilio', 'sent', now() - interval '2 days' FROM generate_series(1, 8);
INSERT INTO public.exos_sms_outbox(campaign_id, org_id, phone, body, status, send_after)
SELECT id, org_id, '+12125550102', 'old', 'sent', now() FROM public.exos_sms_campaigns WHERE body = 'old';
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('60000000-0000-0000-0000-0000000000a1');
SELECT set_config('sm.capaud', public.exos_sms_audience(pg_temp.u('000000000001'), 'org')::text, true);
SELECT set_config('sm.c3', public.exos_sms_create_campaign(pg_temp.u('000000000001'), 'Third one', 'org')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT (current_setting('sm.capaud')::jsonb->>'capped')::int = 1, 'S3: capped ' || current_setting('sm.capaud');
  ASSERT (current_setting('sm.c3')::jsonb->>'queued')::int = 1 AND (current_setting('sm.c3')::jsonb->>'skipped_cap')::int = 1, 'S3: cap skips ' || current_setting('sm.c3');
END $$;

-- S4 drain ----------------------------------------------------------------
-- The claim re-checks quiet hours where the recipient is (mig 20261021140000):
-- put the event in a zone where it's midday now, whatever time the run is.
UPDATE public.exos_events
   SET timezone = (SELECT 'Etc/GMT' || CASE WHEN o > 0 THEN '-' || o WHEN o < 0 THEN '+' || (-o) ELSE '' END
                     FROM (SELECT ((12 - extract(hour FROM now() AT TIME ZONE 'UTC')::int + 36) % 24) - 12 AS o) x)
 WHERE id = pg_temp.u('0000000000e1');
DO $$
DECLARE r record; n int := 0; v_c2 uuid := (current_setting('sm.c2')::jsonb->>'campaign_id')::uuid;
BEGIN
  -- c1 is next week (not due); c2 and c3 are due now (for b1). A due row for b2,
  -- who opts out after it was queued, must be skipped at claim time.
  INSERT INTO public.exos_sms_outbox(campaign_id, org_id, phone, body, send_after)
  VALUES ((current_setting('sm.c3')::jsonb->>'campaign_id')::uuid, pg_temp.u('000000000001'), '+12125550102', 'x Reply STOP', now());
  UPDATE public.exos_sms_subscribers SET opted_out_at = now() WHERE phone = '+12125550102';
  FOR r IN SELECT * FROM public.exos_sms_claim(50) LOOP
    n := n + 1;
    ASSERT r.provider = 'twilio' AND r.body LIKE '%Reply STOP%', 'S4: claimed row';
    PERFORM public.exos_sms_mark(r.id, CASE WHEN r.body LIKE '%set times%' THEN 'sent' ELSE 'dry_run' END, 'SM' || n, NULL);
  END LOOP;
  ASSERT n = 2, 'S4: c2 + c3 for b1 only, got ' || n;
  ASSERT (SELECT count(*) FROM public.exos_sms_claim(50)) = 0, 'S4: nothing left due';
  ASSERT (SELECT status FROM public.exos_sms_outbox WHERE phone = '+12125550102' AND campaign_id = (current_setting('sm.c3')::jsonb->>'campaign_id')::uuid) = 'skipped', 'S4: opted out since queuing';
  ASSERT (SELECT status FROM public.exos_sms_campaigns WHERE id = v_c2) = 'sent', 'S4: campaign done';
  ASSERT NOT public.exos_sms_mark((SELECT id FROM public.exos_sms_outbox WHERE campaign_id = v_c2 LIMIT 1), 'sent'), 'S4: mark only a sending row';
END $$;

-- S5 ----------------------------------------------------------------------
DO $$
BEGIN
  ASSERT public.exos_sms_inbound(pg_temp.u('000000000001'), '+12125550101', 'Stop') = 'stopped', 'S5: STOP';
  ASSERT (SELECT opted_out_at IS NOT NULL FROM public.exos_sms_subscribers WHERE phone = '+12125550101'), 'S5: opted out';
  ASSERT (SELECT status FROM public.exos_sms_outbox WHERE phone = '+12125550101' AND campaign_id = (current_setting('sm.c1')::jsonb->>'campaign_id')::uuid) = 'skipped', 'S5: queued skipped';
  ASSERT public.exos_sms_inbound(pg_temp.u('000000000001'), '+12125550101', 'START') = 'started', 'S5: START';
  ASSERT public.exos_sms_inbound(pg_temp.u('000000000001'), '+12125550101', 'what time?') = 'ignored', 'S5: other text';
  ASSERT public.exos_sms_inbound(pg_temp.u('000000000001'), '+19995550000', 'START') = 'ignored', 'S5: unknown number stays out';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_sms_claim(int)', 'EXECUTE'), 'S5: drain is service-only';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_sms_inbound(uuid, text, text)', 'EXECUTE'), 'S5: inbound is service-only';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_sms_subscribers', 'SELECT'), 'S5: list via RPCs only';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('60000000-0000-0000-0000-0000000000a1');
SELECT set_config('sm.cancel', public.exos_sms_cancel_campaign((current_setting('sm.c1')::jsonb->>'campaign_id')::uuid)::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT status FROM public.exos_sms_campaigns WHERE id = (current_setting('sm.c1')::jsonb->>'campaign_id')::uuid) = 'cancelled', 'S5: cancelled';
END $$;

\echo 'test_sms: all passed'
ROLLBACK;
