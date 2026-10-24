-- ============================================================================
-- Growth P1s (mig 20261021140000).
--   G1 promo-link limit is held: live holds carrying the code count against
--      max_uses (3rd buyer of a 2-use link refused before paying); the
--      buyer's own new cart replaces theirs; an expired hold frees its use;
--      an open checkout with no hold (bypass code) counts too
--   G2 SMS: dry runs don't count toward the 8 / 30 days cap; another account
--      can't take a number over (nor undo its STOP); quiet hours re-checked at
--      claim in the recipient's zone; 429 / 5xx retried 5 times with backoff,
--      then failed; STOP said in more ways
--   G3 promoter + fan referral on one order: promoter wins, no fan credit;
--      no commission on the promoter's own purchase
--   G4 abandoned-checkout link keeps coupon= and ref=
-- Self-contained ids 72…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('72000000-0000-0000-0000-0000000000a1','gpown@x.com',now()),
  ('72000000-0000-0000-0000-0000000000b1','gpfan1@x.com',now()),
  ('72000000-0000-0000-0000-0000000000b2','gpfan2@x.com',now()),
  ('72000000-0000-0000-0000-0000000000b3','gpfan3@x.com',now()),
  ('72000000-0000-0000-0000-0000000000b4','gpdj@x.com',now()),
  ('72000000-0000-0000-0000-0000000000b5','gpfan5@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('72000000-0000-0000-0000-000000000001','GP Club','gp-club','72000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000a1','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by,currency) VALUES
  ('72000000-0000-0000-0000-0000000000e1','72000000-0000-0000-0000-000000000001','GP Launch','gp-launch','published',now() + interval '9 days','America/New_York',200,0,'72000000-0000-0000-0000-0000000000a1','usd');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('72000000-0000-0000-0000-0000000000d1','72000000-0000-0000-0000-0000000000e1','GA',30,200,0,'public');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('72000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'OK';
EXCEPTION WHEN others THEN
  RETURN 'ERR ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.try(text) TO anon, authenticated;
-- A fixed-offset zone where it is noon (or 3am) right now.
CREATE FUNCTION pg_temp.zone_at(p_hour int) RETURNS text LANGUAGE sql AS $$
  SELECT 'Etc/GMT' || CASE WHEN o > 0 THEN '-' || o WHEN o < 0 THEN '+' || (-o) ELSE '' END
    FROM (SELECT ((p_hour - extract(hour FROM now() AT TIME ZONE 'UTC')::int + 36) % 24) - 12 AS o) x
$$;

-- G1 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000a1');
SELECT public.exos_create_promo_link(pg_temp.u('0000000000e1'), 'IG story', 'instagram', 2, 48, 'GPIGLAUNCH', 20);
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b1');
SELECT set_config('g.h1', public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 1800, 'GPIGLAUNCH')::text, true);
-- fan1 starts over (a new cart replaces the old one, so it doesn't use a second redemption)
SELECT set_config('g.h1b', public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 1800, 'gpiglaunch')::text, true);
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b2');
SELECT set_config('g.h2', public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 1800, 'GPIGLAUNCH')::text, true);
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b3');
SELECT set_config('g.h3', pg_temp.try($$SELECT public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 1800, 'GPIGLAUNCH')$$), true);
-- without the code the same buyer still gets a full-price hold
SELECT set_config('g.h3plain', pg_temp.try($$SELECT public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 1800, NULL)$$), true);
RESET ROLE;
DO $$
DECLARE v uuid := (SELECT id FROM public.exos_vouchers WHERE code = 'GPIGLAUNCH');
BEGIN
  ASSERT (SELECT voucher_id FROM public.exos_cart_holds WHERE id = current_setting('g.h2')::uuid) = v, 'G1: the hold records the code';
  ASSERT current_setting('g.h3') LIKE 'ERR %covers 0 more%', 'G1: 3rd buyer refused before paying: ' || current_setting('g.h3');
  ASSERT current_setting('g.h3plain') = 'OK', 'G1: no code, no limit';
  ASSERT public.exos_voucher_in_flight(v) = 2, 'G1: two in flight (fan1''s first cart released)';
  ASSERT public.exos_voucher_uses_left(v, pg_temp.u('0000000000b3'), 'gpfan3@x.com') = 0, 'G1: checkout check sees 0 left';
  ASSERT public.exos_voucher_uses_left(v, pg_temp.u('0000000000b1'), 'gpfan1@x.com') = 1, 'G1: fan1''s own hold is not held against fan1';
  -- fan2's hold runs out: the use comes back at once
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second' WHERE id = current_setting('g.h2')::uuid;
  ASSERT public.exos_voucher_uses_left(v, pg_temp.u('0000000000b3'), 'gpfan3@x.com') = 1, 'G1: expired hold frees its use';
  -- a code that skipped the hold (bypass) still counts while its checkout is open
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,voucher_id)
  VALUES ('cs_gp_bypass', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b2'), 'gpfan2@x.com', 1, 2400, 'pending', v);
  ASSERT public.exos_voucher_uses_left(v, pg_temp.u('0000000000b3'), 'gpfan3@x.com') = 0, 'G1: open checkout without a hold counts';
  UPDATE public.exos_checkout_sessions SET created_at = now() - interval '31 minutes' WHERE session_id = 'cs_gp_bypass';
  ASSERT public.exos_voucher_uses_left(v, pg_temp.u('0000000000b3'), 'gpfan3@x.com') = 1, 'G1: a stale open checkout stops counting';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_voucher_uses_left(uuid, uuid, text)', 'EXECUTE'), 'G1: service only';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b3');
SELECT set_config('g.h3b', pg_temp.try($$SELECT public.exos_create_hold(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, 1800, 'GPIGLAUNCH')$$), true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('g.h3b') = 'OK', 'G1: the freed use can be held: ' || current_setting('g.h3b');
END $$;

-- G2 ----------------------------------------------------------------------
INSERT INTO public.exos_org_integrations(org_id, provider, config, status) VALUES (pg_temp.u('000000000001'), 'twilio', '{"from":"+12125550199"}', 'connected');
CREATE TEMP TABLE consent AS SELECT 'Text me about GP Club. Up to 8 msgs/mo. Reply STOP to cancel.'::text AS t;
GRANT SELECT ON consent TO authenticated;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b1');
SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '212 555 0101', (SELECT t FROM consent), pg_temp.u('0000000000e1'));
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b2');
SELECT set_config('g.steal', pg_temp.try($$SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '+12125550101', (SELECT t FROM consent))$$), true);
SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '+12125550102', (SELECT t FROM consent));
-- fan1 changes their mind in the app, then signs up again: their own number, fine
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b1');
SELECT public.exos_sms_opt_out_mine(pg_temp.u('000000000001'));
SELECT set_config('g.self', pg_temp.try($$SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '2125550101', (SELECT t FROM consent))$$), true);
RESET ROLE;
-- A number that texted STOP and has no account on file can't be signed back up from an account either.
INSERT INTO public.exos_sms_subscribers(org_id, phone, user_id, consent_text, opted_out_at)
VALUES (pg_temp.u('000000000001'), '+12125550109', NULL, (SELECT t FROM consent), now());
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b3');
SELECT set_config('g.stop', pg_temp.try($$SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '+12125550109', (SELECT t FROM consent))$$), true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('g.steal') LIKE 'ERR %text START from the phone%', 'G2: steal refused: ' || current_setting('g.steal');
  ASSERT (SELECT user_id FROM public.exos_sms_subscribers WHERE phone = '+12125550101') = pg_temp.u('0000000000b1'), 'G2: owner kept';
  ASSERT current_setting('g.self') = 'OK', 'G2: own number re-opt-in';
  ASSERT current_setting('g.stop') LIKE 'ERR %text START%', 'G2: STOP not undone from an account';
  ASSERT (SELECT opted_out_at IS NOT NULL FROM public.exos_sms_subscribers WHERE phone = '+12125550109'), 'G2: still opted out';
  ASSERT public.exos_sms_inbound(pg_temp.u('000000000001'), '+12125550109', 'START') = 'started', 'G2: START from the phone works';
END $$;

-- Eight dry-run texts to fan1's number in the last 30 days: not a cap.
INSERT INTO public.exos_sms_campaigns(id, org_id, audience, body, provider, status, created_at)
SELECT gen_random_uuid(), pg_temp.u('000000000001'), 'org', 'gpdry', 'twilio', 'sent', now() - interval '2 days' FROM generate_series(1, 8);
INSERT INTO public.exos_sms_outbox(campaign_id, org_id, phone, body, status, send_after)
SELECT id, org_id, '+12125550101', 'gpdry', 'dry_run', now() FROM public.exos_sms_campaigns WHERE body = 'gpdry';
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000a1');
SELECT set_config('g.aud', public.exos_sms_audience(pg_temp.u('000000000001'), 'org')::text, true);
SELECT set_config('g.c1', public.exos_sms_create_campaign(pg_temp.u('000000000001'), 'Launch night tickets', 'org', pg_temp.u('0000000000e1'))::text, true);
RESET ROLE;
DO $$
DECLARE r record; n int := 0; v_c uuid := (current_setting('g.c1')::jsonb->>'campaign_id')::uuid;
BEGIN
  ASSERT (current_setting('g.aud')::jsonb->>'capped')::int = 0, 'G2: dry runs don''t cap: ' || current_setting('g.aud');
  ASSERT (current_setting('g.c1')::jsonb->>'queued')::int = 3, 'G2: all three numbers queued: ' || current_setting('g.c1');
  UPDATE public.exos_sms_outbox SET send_after = now() - interval '1 minute' WHERE campaign_id = v_c;

  -- 3am where the event is: nothing goes out; it waits for 9:00 there.
  UPDATE public.exos_events SET timezone = pg_temp.zone_at(3) WHERE id = pg_temp.u('0000000000e1');
  ASSERT (SELECT count(*) FROM public.exos_sms_claim(50) c WHERE c.org_id = pg_temp.u('000000000001')) = 0, 'G2: quiet hours at claim';
  ASSERT (SELECT bool_and(((send_after AT TIME ZONE pg_temp.zone_at(3))::time = time '09:00') AND send_after > now())
            FROM public.exos_sms_outbox WHERE campaign_id = v_c), 'G2: moved to 9:00 local';

  -- Noon there: due again, claimed.
  UPDATE public.exos_events SET timezone = pg_temp.zone_at(12) WHERE id = pg_temp.u('0000000000e1');
  UPDATE public.exos_sms_outbox SET send_after = now() - interval '1 minute' WHERE campaign_id = v_c;
  ASSERT (SELECT count(*) FROM public.exos_sms_claim(50) c WHERE c.org_id = pg_temp.u('000000000001')) = 3, 'G2: claimed at noon';
  -- Keep one row for the retry run below.
  UPDATE public.exos_sms_outbox SET status = 'skipped', lease_until = NULL WHERE campaign_id = v_c AND phone <> '+12125550101';
  UPDATE public.exos_sms_outbox SET status = 'queued', attempts = 0, lease_until = NULL WHERE campaign_id = v_c AND phone = '+12125550101';

  -- Provider 503 every time: 5 attempts, backing off, then failed.
  FOR i IN 1..10 LOOP
    UPDATE public.exos_sms_outbox SET send_after = now() - interval '1 minute' WHERE campaign_id = v_c AND status = 'queued';
    FOR r IN SELECT * FROM public.exos_sms_claim(50) c WHERE c.org_id = pg_temp.u('000000000001') LOOP
      n := n + 1;
      IF n = 1 THEN
        PERFORM public.exos_sms_mark(r.id, 'queued', NULL, 'out of time');   -- the drain's own hand-back: not a try
      ELSE
        PERFORM public.exos_sms_mark(r.id, 'queued', NULL, 'HTTP 503');
      END IF;
      IF n = 3 THEN
        ASSERT (SELECT send_after BETWEEN now() + interval '3 minutes' AND now() + interval '5 minutes'
                  FROM public.exos_sms_outbox WHERE id = r.id), 'G2: backoff grows';
      END IF;
    END LOOP;
  END LOOP;
  ASSERT (SELECT status FROM public.exos_sms_outbox WHERE campaign_id = v_c AND phone = '+12125550101') = 'failed', 'G2: gave up';
  ASSERT (SELECT attempts FROM public.exos_sms_outbox WHERE campaign_id = v_c AND phone = '+12125550101') = 5, 'G2: 5 attempts';
  ASSERT n = 6, 'G2: 1 hand-back + 5 tries, got ' || n;
  ASSERT (SELECT error FROM public.exos_sms_outbox WHERE campaign_id = v_c AND phone = '+12125550101') LIKE 'gave up after 5 attempts%', 'G2: error says why';
  ASSERT (SELECT status FROM public.exos_sms_campaigns WHERE id = v_c) = 'sent', 'G2: campaign finished';

  -- STOP variants.
  FOR r IN SELECT w FROM unnest(ARRAY['Stop please', 'STOP!', 'stop.', 'Unsubscribe me', 'No more texts', 'cancel', 'End', 'quit',
                                      'Please remove me', 'don''t text me', 'Arrêt', 'PARAR']) w LOOP
    UPDATE public.exos_sms_subscribers SET opted_out_at = NULL WHERE phone = '+12125550102';
    ASSERT public.exos_sms_inbound(pg_temp.u('000000000001'), '+12125550102', r.w) = 'stopped', 'G2: STOP variant ' || r.w;
    ASSERT (SELECT opted_out_at IS NOT NULL FROM public.exos_sms_subscribers WHERE phone = '+12125550102'), 'G2: opted out by ' || r.w;
  END LOOP;
  FOR r IN SELECT w FROM unnest(ARRAY['what time are doors?', 'see you at the end', 'yes!']) w LOOP
    ASSERT public.exos_sms_inbound(pg_temp.u('000000000001'), '+12125550101', r.w) <> 'stopped', 'G2: not a STOP: ' || r.w;
  END LOOP;
END $$;

-- G3 ----------------------------------------------------------------------
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source) VALUES
  (pg_temp.u('0000000000e1'),pg_temp.u('000000000001'),pg_temp.u('0000000000d1'),'GA',pg_temp.u('0000000000b1'),pg_temp.u('0000000000b1'),'gpfan1@x.com','active','k',30,'cs_gp_seed','stripe');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000a1');
SELECT public.exos_upsert_promoter(pg_temp.u('000000000001'), 'gpdj', 'GP DJ', 'GPDJ@x.com') IS NOT NULL;
SELECT public.exos_set_promoter_terms((SELECT id FROM public.exos_promoters WHERE code = 'gpdj'), 1000, 0);
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000b1');
SELECT set_config('g.ref', public.exos_my_referral_code(pg_temp.u('0000000000e1')), true);
RESET ROLE;
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,promoter_id,attribution) VALUES
  ('cs_gp_both', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b2'), 'gpfan2@x.com', 2, 6000, 'pending', 'gpdj',
   jsonb_build_object('ref', current_setting('g.ref'))),
  ('cs_gp_refonly', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b3'), 'gpfan3@x.com', 1, 3000, 'pending', NULL,
   jsonb_build_object('ref', current_setting('g.ref'))),
  ('cs_gp_self', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b4'), 'gpdj@x.com', 2, 6000, 'pending', 'gpdj', NULL);
SELECT public.exos_fulfill_checkout(s) IS NOT NULL FROM unnest(ARRAY['cs_gp_both', 'cs_gp_refonly', 'cs_gp_self']) s;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_gp_both' AND promoter_id = 'gpdj' AND referral_code IS NULL) = 2, 'G3: promoter wins, no fan credit';
  ASSERT (SELECT count(*) FROM public.exos_tickets t JOIN public.exos_promoter_commissions c ON c.ticket_id = t.id WHERE t.order_ref = 'cs_gp_both') = 2, 'G3: promoter paid';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_gp_refonly' AND referral_code = current_setting('g.ref')) = 1, 'G3: a ref-only order keeps the fan credit';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_gp_self') = 2, 'G3: self purchase sold';
  ASSERT (SELECT count(*) FROM public.exos_tickets t JOIN public.exos_promoter_commissions c ON c.ticket_id = t.id WHERE t.order_ref = 'cs_gp_self') = 0, 'G3: no commission on own purchase';
END $$;

-- G4 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('72000000-0000-0000-0000-0000000000a1');
SELECT public.exos_create_promo_link(pg_temp.u('0000000000e1'), 'SMS blast', 'sms', 50, 48, 'GPSMS20', 20);
RESET ROLE;
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,voucher_id,promoter_id,attribution,created_at)
VALUES ('cs_gp_ab', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b5'), 'gpfan5@x.com', 2, 4800, 'expired',
        (SELECT id FROM public.exos_vouchers WHERE code = 'GPSMS20'), NULL, '{"ref":"abcdef1234","utm_source":"instagram"}', now() - interval '2 hours');
SELECT * FROM public.exos_send_checkout_reminders();
DO $$
DECLARE v_link text := (SELECT substring(html from 'href="([^"]*checkout[^"]*)"') FROM public.exos_mail WHERE template = 'checkout-abandoned' AND to_email = 'gpfan5@x.com');
BEGIN
  ASSERT v_link IS NOT NULL, 'G4: reminder sent';
  ASSERT v_link LIKE '%&amp;coupon=GPSMS20%', 'G4: keeps the code: ' || v_link;
  ASSERT v_link LIKE '%&amp;ref=abcdef1234%', 'G4: keeps the referral: ' || v_link;
END $$;

\echo 'test_growth_p1: all passed'
ROLLBACK;
