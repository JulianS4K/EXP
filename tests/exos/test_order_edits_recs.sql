-- ============================================================================
-- Order / ticket edits, receipt resends, order check-out, guest-list preview
-- and recommendations (mig 20261102140000). Self-contained (de prefix),
-- rolled back. Org 1: owner a1, manager a2, scanner a3, finance a4, content
-- a6; org 2: owner a5. Buyers b1, b2, b3, b4.
--   O1  grants: exos_api_order_write is service_role only; staff RPCs
--       authenticated; internal helpers nobody's
--   O2  order edit: buyer name / email / phone / notes, audited; prices and
--       quantities refused; the tickets' buyer_email (purchase limits) kept;
--       a no-op writes nothing; scanner key refused; other org / other
--       event not found
--   O3  receipt resend: the address the order was bought with; editing the
--       contact email doesn't move receipts unless overrides are on; no claim
--       links; another address only once the owner allows it (managers can't
--       change that); rate limited per order; Idempotency-Key replays
--   O3b no address at the first edit: no original, any receipt is an
--       override; account deletion erases order details and edit-history
--       addresses, and an erased order gets no receipt
--   O3c erasure matches the email only when confirmed, and whole values
--       only: an unconfirmed look-alike erases nothing; jimbob@x.com
--       survives bob@x.com's deletion
--   O4  order check-out: every ticket inside a re-entry list goes out once;
--       again = nothing recorded (idempotent); the implicit list can't exit;
--       scanners can't (typed exit is an override)
--   O5  ticket edit: attendee name, audited; another email = transfer,
--       refused; the holder's own email is fine; voided refused; barcode
--       secret untouched; other org not found
--   O6  RLS: the audit and the details are the org's owner / manager only
--   G1  guest-list preview: ready / duplicate (existing, in file) / invalid
--       / too many plus-ones / invalid email; capacity; writes nothing;
--       other org not found; scanners refused
--   R1  the score's weights (pinned with src/lib/recommendations.ts)
--   R2  similar events: only public upcoming ones (no draft, noindex,
--       cancelled, past); signals; co-buyers counted, never named
--   R3  other orgs' events only when asked, public only, no co-buyers, no
--       buyer data in the answer
--   R4  events for a fan: from their purchases with this org, minus what
--       they hold from this org (a ticket at another org changes nothing:
--       no cross-tenant oracle); another org's fan is not found
--   R5  fans for an event: on the list, not holders, scored; roles
--   R6  wrappers: roles (content reads similars, not fans)
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.jwt', true), ''),
                  nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
SELECT set_config('app.uid', '', false), set_config('app.jwt', '', false);

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('de000000-0000-0000-0000-0000000000a1','de-owner@x.com',now()),
  ('de000000-0000-0000-0000-0000000000a2','de-manager@x.com',now()),
  ('de000000-0000-0000-0000-0000000000a3','de-scanner@x.com',now()),
  ('de000000-0000-0000-0000-0000000000a4','de-finance@x.com',now()),
  ('de000000-0000-0000-0000-0000000000a5','de-other@x.com',now()),
  ('de000000-0000-0000-0000-0000000000a6','de-content@x.com',now()),
  ('de000000-0000-0000-0000-0000000000b1','de-b1@x.com',now()),
  ('de000000-0000-0000-0000-0000000000b2','de-b2@x.com',now()),
  ('de000000-0000-0000-0000-0000000000b3','de-b3@x.com',now()),
  ('de000000-0000-0000-0000-0000000000b4','de-b4@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('de000000-0000-0000-0000-000000000001','DE Org','de-org','de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-000000000002','DE Other','de-other','de000000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000a1','owner'),
  ('de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000a2','manager'),
  ('de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000a3','scanner'),
  ('de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000a4','finance'),
  ('de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000a6','content'),
  ('de000000-0000-0000-0000-000000000002','de000000-0000-0000-0000-0000000000a5','owner');

-- Keys: f1 owner, f2 scanner, f6 org 2's owner.
INSERT INTO public.exos_api_keys(id,org_id,name,key_prefix,key_hash,scopes,created_by) VALUES
  ('de000000-0000-0000-0000-0000000000f1','de000000-0000-0000-0000-000000000001','k1','sk_live_dek1','dehash1',
   ARRAY['tickets:write','checkin:write','events:read','fans:read'],'de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-0000000000f2','de000000-0000-0000-0000-000000000001','k2','sk_live_dek2','dehash2',
   ARRAY['tickets:write','checkin:write'],'de000000-0000-0000-0000-0000000000a3'),
  ('de000000-0000-0000-0000-0000000000f6','de000000-0000-0000-0000-000000000002','k6','sk_live_dek6','dehash6',
   ARRAY['tickets:write','checkin:write'],'de000000-0000-0000-0000-0000000000a5');

-- Org 1: e1 live now (doors open), e2 upcoming public (same venue + artist),
-- e3 draft, e4 noindex, e5 cancelled, e6 past, e7 upcoming with nothing in
-- common. Org 2: e9 upcoming public (an artist of the same name), e8 draft.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,venue_address,total_tickets,tickets_sold,noindex,created_by) VALUES
  ('de000000-0000-0000-0000-0000000000e1','de000000-0000-0000-0000-000000000001','DE Live','de-live','published', now() - interval '1 hour','America/New_York','The Room','{"city":"New York"}',100,3,false,'de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-0000000000e2','de000000-0000-0000-0000-000000000001','DE Next','de-next','published', now() + interval '5 days','America/New_York','The Room','{"city":"New York"}',10,1,false,'de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-0000000000e3','de000000-0000-0000-0000-000000000001','DE Draft','de-draft','draft', now() + interval '6 days','America/New_York','The Room','{"city":"New York"}',100,0,false,'de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-0000000000e4','de000000-0000-0000-0000-000000000001','DE Hidden','de-hidden','published', now() + interval '6 days','America/New_York','The Room','{"city":"New York"}',100,0,true,'de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-0000000000e5','de000000-0000-0000-0000-000000000001','DE Off','de-off','cancelled', now() + interval '6 days','America/New_York','The Room','{"city":"New York"}',100,0,false,'de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-000000000001','DE Past','de-past','published', now() - interval '30 days','America/New_York','The Room','{"city":"New York"}',100,2,false,'de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-0000000000e7','de000000-0000-0000-0000-000000000001','DE Other Night','de-other-night','published', now() + interval '7 days','America/New_York','Elsewhere Hall','{"city":"Boston"}',100,0,false,'de000000-0000-0000-0000-0000000000a1'),
  ('de000000-0000-0000-0000-0000000000e9','de000000-0000-0000-0000-000000000002','DE Away','de-away','published', now() + interval '8 days','America/Chicago','Big Club','{"city":"Chicago"}',100,1,false,'de000000-0000-0000-0000-0000000000a5'),
  ('de000000-0000-0000-0000-0000000000e8','de000000-0000-0000-0000-000000000002','DE Away Draft','de-away-draft','draft', now() + interval '8 days','America/Chicago','Big Club','{"city":"Chicago"}',100,0,false,'de000000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('de000000-0000-0000-0000-0000000000d1','de000000-0000-0000-0000-0000000000e1','GA',20,100,3,'public'),
  ('de000000-0000-0000-0000-0000000000d2','de000000-0000-0000-0000-0000000000e2','GA',20,10,1,'public'),
  ('de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-0000000000e6','GA',20,100,2,'public'),
  ('de000000-0000-0000-0000-0000000000d9','de000000-0000-0000-0000-0000000000e9','GA',20,100,1,'public');
INSERT INTO public.exos_artists(id,org_id,name,permalink,genres) VALUES
  ('de000000-0000-0000-0000-0000000000c1','de000000-0000-0000-0000-000000000001','Nova Lane','nova-lane',ARRAY['House']),
  ('de000000-0000-0000-0000-0000000000c9','de000000-0000-0000-0000-000000000002','Nova  Lane','nova-lane',ARRAY['house']);
INSERT INTO public.exos_event_lineup(org_id,event_id,artist_id,act_type,position)
SELECT 'de000000-0000-0000-0000-000000000001', e, 'de000000-0000-0000-0000-0000000000c1', 'headline', 1
  FROM unnest(ARRAY['de000000-0000-0000-0000-0000000000e1','de000000-0000-0000-0000-0000000000e2','de000000-0000-0000-0000-0000000000e3',
                    'de000000-0000-0000-0000-0000000000e4','de000000-0000-0000-0000-0000000000e5','de000000-0000-0000-0000-0000000000e6']::uuid[]) e;
INSERT INTO public.exos_event_lineup(org_id,event_id,artist_id,act_type,position) VALUES
  ('de000000-0000-0000-0000-000000000002','de000000-0000-0000-0000-0000000000e9','de000000-0000-0000-0000-0000000000c9','headline',1),
  ('de000000-0000-0000-0000-000000000002','de000000-0000-0000-0000-0000000000e8','de000000-0000-0000-0000-0000000000c9','headline',1);

-- Orders: cs_de1 b1 x2 on e1; cs_de2 b2 on e1; cs_de3 b2 on e2; cs_de6 b3 on
-- e6 (past); cs_de7 b4 on e6; cs_de9 b1 on org 2's e9.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent) VALUES
  ('cs_de1','de000000-0000-0000-0000-0000000000e1','de000000-0000-0000-0000-0000000000d1','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000b1','de-b1@x.com',2,4000,'fulfilled','pi_de1'),
  ('cs_de2','de000000-0000-0000-0000-0000000000e1','de000000-0000-0000-0000-0000000000d1','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000b2','de-b2@x.com',1,2000,'fulfilled','pi_de2'),
  ('cs_de3','de000000-0000-0000-0000-0000000000e2','de000000-0000-0000-0000-0000000000d2','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000b2','de-b2@x.com',1,2000,'fulfilled','pi_de3'),
  ('cs_de6','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000b3','de-b3@x.com',1,2000,'fulfilled','pi_de6'),
  ('cs_de7','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000b4','de-b4@x.com',1,2000,'fulfilled','pi_de7'),
  ('cs_de9','de000000-0000-0000-0000-0000000000e9','de000000-0000-0000-0000-0000000000d9','de000000-0000-0000-0000-000000000002','de000000-0000-0000-0000-0000000000b1','de-b1@x.com',1,2000,'fulfilled','pi_de9');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref) VALUES
  ('de000000-0000-0000-0000-000000000101','de000000-0000-0000-0000-0000000000e1','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000d1','de000000-0000-0000-0000-0000000000b1','de000000-0000-0000-0000-0000000000b1','de-b1@x.com','active','sec101',20,'cs_de1'),
  ('de000000-0000-0000-0000-000000000102','de000000-0000-0000-0000-0000000000e1','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000d1','de000000-0000-0000-0000-0000000000b1','de000000-0000-0000-0000-0000000000b1','de-b1@x.com','active','sec102',20,'cs_de1'),
  ('de000000-0000-0000-0000-000000000103','de000000-0000-0000-0000-0000000000e1','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000d1','de000000-0000-0000-0000-0000000000b2','de000000-0000-0000-0000-0000000000b2','de-b2@x.com','active','sec103',20,'cs_de2'),
  ('de000000-0000-0000-0000-000000000201','de000000-0000-0000-0000-0000000000e2','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000d2','de000000-0000-0000-0000-0000000000b2','de000000-0000-0000-0000-0000000000b2','de-b2@x.com','active','sec201',20,'cs_de3'),
  ('de000000-0000-0000-0000-000000000601','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-0000000000b3','de000000-0000-0000-0000-0000000000b3','de-b3@x.com','used','sec601',20,'cs_de6'),
  ('de000000-0000-0000-0000-000000000602','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-0000000000b4','de000000-0000-0000-0000-0000000000b4','de-b4@x.com','voided','sec602',20,'cs_de7'),
  ('de000000-0000-0000-0000-000000000901','de000000-0000-0000-0000-0000000000e9','de000000-0000-0000-0000-000000000002','de000000-0000-0000-0000-0000000000d9','de000000-0000-0000-0000-0000000000b1','de000000-0000-0000-0000-0000000000b1','de-b1@x.com','active','sec901',20,'cs_de9');

-- A re-entry list on e1.
INSERT INTO public.exos_checkin_lists(id,event_id,org_id,name,allow_reentry) VALUES
  ('de000000-0000-0000-0000-0000000000a9','de000000-0000-0000-0000-0000000000e1','de000000-0000-0000-0000-000000000001','Main door',true);

-- Fans (the order trigger may have made some already): b3 and b2 on the
-- list; b1 not; b4 unsubscribed. Consent is the fan's own: set here with the
-- guard's switch, as the opt-in paths do.
DO $$ BEGIN PERFORM set_config('exos.fan_consent_action', 'on', true); END $$;
INSERT INTO public.exos_fans(id,org_id,email,user_id,first_name,email_opt_in_at,email_opt_out_at) VALUES
  ('de000000-0000-0000-0000-0000000001f1','de000000-0000-0000-0000-000000000001','de-b1@x.com','de000000-0000-0000-0000-0000000000b1','B1',NULL,NULL),
  ('de000000-0000-0000-0000-0000000001f2','de000000-0000-0000-0000-000000000001','de-b2@x.com','de000000-0000-0000-0000-0000000000b2','B2',now() - interval '10 days',NULL),
  ('de000000-0000-0000-0000-0000000001f3','de000000-0000-0000-0000-000000000001','de-b3@x.com','de000000-0000-0000-0000-0000000000b3','B3',now() - interval '10 days',NULL),
  ('de000000-0000-0000-0000-0000000001f4','de000000-0000-0000-0000-000000000001','de-b4@x.com','de000000-0000-0000-0000-0000000000b4','B4',now() - interval '10 days',now() - interval '1 day'),
  ('de000000-0000-0000-0000-0000000009f1','de000000-0000-0000-0000-000000000002','de-b1@x.com','de000000-0000-0000-0000-0000000000b1','B1',now() - interval '10 days',NULL)
ON CONFLICT (org_id, email) DO UPDATE
  SET id = EXCLUDED.id, user_id = EXCLUDED.user_id, first_name = EXCLUDED.first_name,
      email_opt_in_at = EXCLUDED.email_opt_in_at, email_opt_out_at = EXCLUDED.email_opt_out_at;
DO $$ BEGIN PERFORM set_config('exos.fan_consent_action', '', true); END $$;

-- The SQLSTATE a call fails with ('ok' when it doesn't).
CREATE FUNCTION pg_temp.st(p_key text, p_action text, p_target text, p_args jsonb DEFAULT '{}', p_idem text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.exos_api_order_write(('de000000-0000-0000-0000-0000000000' || p_key)::uuid, p_action, p_target, p_args, p_idem);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.w(p_key text, p_action text, p_target text, p_args jsonb DEFAULT '{}', p_idem text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_order_write(('de000000-0000-0000-0000-0000000000' || p_key)::uuid, p_action, p_target, p_args, p_idem)
$$;
-- A statement's SQLSTATE as a given user.
CREATE FUNCTION pg_temp.as_st(p_uid text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000' || p_uid, true);
  EXECUTE p_sql;
  PERFORM set_config('app.uid', '', true);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('app.uid', '', true);
  RETURN SQLSTATE;
END $$;

-- O1 -----------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  IF NOT has_function_privilege('service_role', 'public.exos_api_order_write(uuid,text,text,jsonb,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.exos_api_order_write(uuid,text,text,jsonb,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.exos_api_order_write(uuid,text,text,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'O1 FAIL: exos_api_order_write grants';
  END IF;
  FOREACH f IN ARRAY ARRAY['public.exos_order_update(text,jsonb)', 'public.exos_order_send_receipt(text,text)',
    'public.exos_order_check_out(text,uuid,text,text)', 'public.exos_ticket_update(uuid,jsonb)',
    'public.exos_org_orders(uuid,text,text,uuid,text,boolean,integer,integer)', 'public.exos_order_edit_log(uuid,text,text,integer,integer)',
    'public.exos_order_settings_get(uuid)', 'public.exos_order_settings_save(uuid,boolean,integer)', 'public.exos_order_tickets(text)',
    'public.exos_guest_list_preview(uuid,uuid,jsonb)', 'public.exos_event_similar_events(uuid,boolean,integer,integer)',
    'public.exos_fan_event_recommendations(uuid,uuid,boolean,integer,integer)', 'public.exos_event_fan_recommendations(uuid,integer,integer)'] LOOP
    IF NOT has_function_privilege('authenticated', f, 'EXECUTE') OR has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'O1 FAIL: % grants', f;
    END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_guest_list_preview(uuid,uuid,uuid,jsonb)', 'public._exos_rec_similar_events(uuid,uuid,boolean,integer,integer)',
    'public._exos_rec_fan_events(uuid,uuid,boolean,integer,integer)', 'public._exos_rec_event_fans(uuid,uuid,integer,integer)'] LOOP
    IF NOT has_function_privilege('service_role', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE')
       OR has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'O1 FAIL: % grants', f;
    END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_oe_order_json(text)', 'public._exos_oe_audit(uuid,text,uuid,text,jsonb,uuid)',
    'public._exos_oe_settings(uuid)', 'public._exos_rec_event_keys(uuid[])', 'public._exos_rec_public(uuid)',
    'public._exos_rec_rank(uuid,boolean,uuid[],uuid[],timestamp with time zone,integer,uuid[],text,integer,integer)'] LOOP
    IF has_function_privilege('service_role', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE')
       OR has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'O1 FAIL: % should be internal', f;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname IN ('exos_order_details', 'exos_order_edits', 'exos_order_settings')
              AND NOT relrowsecurity) THEN
    RAISE EXCEPTION 'O1 FAIL: RLS off';
  END IF;
  IF has_table_privilege('anon', 'public.exos_order_edits', 'SELECT')
     OR has_table_privilege('authenticated', 'public.exos_order_edits', 'INSERT')
     OR has_table_privilege('authenticated', 'public.exos_order_details', 'UPDATE') THEN
    RAISE EXCEPTION 'O1 FAIL: table grants';
  END IF;
  RAISE NOTICE 'OK O1 grants: API writes service_role only, staff RPCs signed in, helpers internal, RLS on';
END $$;

-- O2 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; n int;
BEGIN
  r := pg_temp.w('f1', 'order.update', 'cs_de1', jsonb_build_object('event_id', 'de000000-0000-0000-0000-0000000000e1',
         'fields', '{"first_name":"Dana","last_name":"Lee","email":"Dana.New@X.com","phone_number":"+1 555 0100","notes":"VIP table"}'::jsonb));
  IF NOT (r ->> 'changed')::boolean OR r ->> 'email' <> 'dana.new@x.com' OR r ->> 'first_name' <> 'Dana'
     OR r ->> 'phone_number' <> '+1 555 0100' OR r ->> 'notes' <> 'VIP table' THEN
    RAISE EXCEPTION 'O2 FAIL: edit %', r;
  END IF;
  IF (SELECT buyer_email FROM public.exos_checkout_sessions WHERE session_id = 'cs_de1') <> 'dana.new@x.com' THEN
    RAISE EXCEPTION 'O2 FAIL: contact email not saved';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'cs_de1' AND buyer_email <> 'de-b1@x.com') THEN
    RAISE EXCEPTION 'O2 FAIL: tickets'' buyer_email changed (purchase limits count it)';
  END IF;
  SELECT count(*) INTO n FROM public.exos_order_edits WHERE session_id = 'cs_de1' AND action = 'order.update'
     AND actor = 'de000000-0000-0000-0000-0000000000a1' AND api_key_id = 'de000000-0000-0000-0000-0000000000f1'
     AND changes -> 'email' ->> 'from' = 'de-b1@x.com' AND changes -> 'email' ->> 'to' = 'dana.new@x.com';
  IF n <> 1 THEN RAISE EXCEPTION 'O2 FAIL: audit row %', n; END IF;
  -- The same again: nothing changes, nothing is logged.
  r := pg_temp.w('f1', 'order.update', 'cs_de1', jsonb_build_object('fields', '{"first_name":"Dana"}'::jsonb));
  IF (r ->> 'changed')::boolean OR (SELECT count(*) FROM public.exos_order_edits WHERE session_id = 'cs_de1') <> 1 THEN
    RAISE EXCEPTION 'O2 FAIL: no-op logged %', r;
  END IF;
  IF pg_temp.st('f1', 'order.update', 'cs_de1', '{"fields":{"amount_cents":1}}') <> '22023'
     OR pg_temp.st('f1', 'order.update', 'cs_de1', '{"fields":{"quantity":5}}') <> '22023'
     OR pg_temp.st('f1', 'order.update', 'cs_de1', '{"fields":{"email":"nope"}}') <> '22023'
     OR pg_temp.st('f1', 'order.update', 'cs_de1', '{"fields":{"phone":"call me"}}') <> '22023' THEN
    RAISE EXCEPTION 'O2 FAIL: bad fields accepted';
  END IF;
  IF (SELECT amount_cents FROM public.exos_checkout_sessions WHERE session_id = 'cs_de1') <> 4000 THEN
    RAISE EXCEPTION 'O2 FAIL: price moved';
  END IF;
  IF pg_temp.st('f2', 'order.update', 'cs_de1', '{"fields":{"notes":"x"}}') <> '42501' THEN
    RAISE EXCEPTION 'O2 FAIL: scanner key edited an order';
  END IF;
  IF pg_temp.st('f6', 'order.update', 'cs_de1', '{"fields":{"notes":"x"}}') <> 'P0002'
     OR pg_temp.st('f1', 'order.update', 'cs_de9', '{"fields":{"notes":"x"}}') <> 'P0002'
     OR pg_temp.st('f1', 'order.update', 'cs_de1', '{"event_id":"de000000-0000-0000-0000-0000000000e2","fields":{"notes":"x"}}') <> 'P0002' THEN
    RAISE EXCEPTION 'O2 FAIL: cross-org / wrong event';
  END IF;
  IF pg_temp.st('f1', 'order.nope', 'cs_de1', '{}') <> '22023' THEN RAISE EXCEPTION 'O2 FAIL: unknown action'; END IF;
  RAISE NOTICE 'OK O2 order edit: contact fields only, audited, tickets and price untouched, roles and org pinned';
END $$;

-- O3 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; n int; h text;
BEGIN
  -- O2 moved the contact email to dana.new@x.com; the order was bought with
  -- de-b1@x.com. With overrides off an edit can't redirect receipts: the
  -- default goes to the original address, the edited one asked for is refused.
  IF (SELECT original_email FROM public.exos_order_details WHERE session_id = 'cs_de1') <> 'de-b1@x.com' THEN
    RAISE EXCEPTION 'O3 FAIL: original email not kept';
  END IF;
  r := pg_temp.w('f1', 'order.send_receipt', 'cs_de1', '{}');
  IF NOT (r ->> 'sent')::boolean OR r ->> 'to' <> 'de-b1@x.com' OR (r ->> 'override')::boolean THEN
    RAISE EXCEPTION 'O3 FAIL: edit-then-resend bypass %', r;
  END IF;
  IF pg_temp.st('f1', 'order.send_receipt', 'cs_de1', '{"email":"dana.new@x.com"}') <> '42501' THEN
    RAISE EXCEPTION 'O3 FAIL: the edited address treated as on file with overrides off';
  END IF;
  SELECT m.html INTO h FROM public.exos_mail m WHERE m.id = (r ->> 'mail_id')::uuid
     AND m.template = 'ticket-issued' AND m.to_email = 'de-b1@x.com' AND m.status = 'pending';
  IF h IS NULL OR position('/claim/' IN h) > 0 OR position('cs_de1' IN h) = 0 THEN
    RAISE EXCEPTION 'O3 FAIL: receipt mail %', h;
  END IF;
  -- Another address: refused until the owner allows it.
  IF pg_temp.st('f1', 'order.send_receipt', 'cs_de1', '{"email":"friend@y.com"}') <> '42501' THEN
    RAISE EXCEPTION 'O3 FAIL: override without the setting';
  END IF;
  IF pg_temp.as_st('a2', $q$SELECT public.exos_order_settings_save('de000000-0000-0000-0000-000000000001', true, 3)$q$) <> '42501' THEN
    RAISE EXCEPTION 'O3 FAIL: a manager changed the receipt rules';
  END IF;
  IF pg_temp.as_st('a1', $q$SELECT public.exos_order_settings_save('de000000-0000-0000-0000-000000000001', true, 3)$q$) <> 'ok' THEN
    RAISE EXCEPTION 'O3 FAIL: owner could not save the rules';
  END IF;
  r := pg_temp.w('f1', 'order.send_receipt', 'cs_de1', '{"email":"Friend@Y.com"}', 'rcpt-de-0001');
  IF r ->> 'to' <> 'friend@y.com' OR NOT (r ->> 'override')::boolean THEN RAISE EXCEPTION 'O3 FAIL: override %', r; END IF;
  -- The same Idempotency-Key replays: no second mail.
  SELECT count(*) INTO n FROM public.exos_mail WHERE to_email = 'friend@y.com';
  r := pg_temp.w('f1', 'order.send_receipt', 'cs_de1', '{"email":"Friend@Y.com"}', 'rcpt-de-0001');
  IF NOT (r ->> 'idempotent_replay')::boolean OR (SELECT count(*) FROM public.exos_mail WHERE to_email = 'friend@y.com') <> n THEN
    RAISE EXCEPTION 'O3 FAIL: replay sent again %', r;
  END IF;
  -- Overrides on: the edited contact email is allowed, as an override, and
  -- counts toward the same limit (third this hour); the fourth is refused.
  r := pg_temp.w('f1', 'order.send_receipt', 'cs_de1', '{}');
  IF r ->> 'to' <> 'dana.new@x.com' OR NOT (r ->> 'override')::boolean THEN
    RAISE EXCEPTION 'O3 FAIL: edited address with overrides on %', r;
  END IF;
  IF pg_temp.st('f1', 'order.send_receipt', 'cs_de1', '{}') <> '54000' THEN RAISE EXCEPTION 'O3 FAIL: no rate limit'; END IF;
  IF (SELECT count(*) FROM public.exos_order_edits WHERE session_id = 'cs_de1' AND action = 'order.receipt') <> 3 THEN
    RAISE EXCEPTION 'O3 FAIL: receipt audit rows';
  END IF;
  -- Another order has its own budget; scanners can't resend.
  IF pg_temp.st('f1', 'order.send_receipt', 'cs_de2', '{}') <> 'ok' THEN RAISE EXCEPTION 'O3 FAIL: per order'; END IF;
  IF pg_temp.st('f2', 'order.send_receipt', 'cs_de2', '{}') <> '42501' THEN RAISE EXCEPTION 'O3 FAIL: scanner resent'; END IF;
  IF pg_temp.st('f6', 'order.send_receipt', 'cs_de2', '{}') <> 'P0002' THEN RAISE EXCEPTION 'O3 FAIL: cross-org resend'; END IF;
  RAISE NOTICE 'OK O3 receipt resend: the original address unless overrides are on (an email edit can''t bypass it), no claim links, rate limited, idempotent';
END $$;

-- O3b ----------------------------------------------------------------------------
-- An order with no address at the first edit has no original: the edited
-- address is never treated as the original. Erasure clears the order desk's
-- PII and stops receipts (no fallback to the recorded original).
-- The test chain lacks some of prod's tables exos_delete_my_account touches:
-- minimal stand-ins (rolled back with everything else).
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS phone text, ADD COLUMN IF NOT EXISTS raw_user_meta_data jsonb,
  ADD COLUMN IF NOT EXISTS banned_until timestamptz, ADD COLUMN IF NOT EXISTS updated_at timestamptz;
CREATE TABLE IF NOT EXISTS auth.identities (user_id uuid);
CREATE TABLE IF NOT EXISTS auth.sessions (user_id uuid);
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (user_id text);
CREATE TABLE IF NOT EXISTS public.exos_org_invites (email text, claimed_by uuid);
CREATE TABLE IF NOT EXISTS public.exos_org_follows (follower_uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_event_saves (user_id uuid);
CREATE TABLE IF NOT EXISTS public.exos_notification_reads (uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid);
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('de000000-0000-0000-0000-0000000000b5','de-b5@x.com',now());
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent) VALUES
  ('cs_de4','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000b2',NULL,1,2000,'fulfilled','pi_de4'),
  ('cs_de5','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-000000000001','de000000-0000-0000-0000-0000000000b5','de-b5@x.com',1,2000,'fulfilled','pi_de5');
DO $$
DECLARE r jsonb; d public.exos_order_details%ROWTYPE;
BEGIN
  -- No address at the first edit.
  PERFORM pg_temp.w('f1', 'order.update', 'cs_de4', '{"fields":{"email":"new@y.com"}}'::jsonb);
  SELECT * INTO d FROM public.exos_order_details WHERE session_id = 'cs_de4';
  IF NOT d.original_captured OR d.original_email IS NOT NULL THEN RAISE EXCEPTION 'O3b FAIL: original not captured as none %', to_jsonb(d); END IF;
  -- A second edit doesn't make its address the original.
  PERFORM pg_temp.w('f1', 'order.update', 'cs_de4', '{"fields":{"email":"newer@y.com"}}'::jsonb);
  IF (SELECT original_email FROM public.exos_order_details WHERE session_id = 'cs_de4') IS NOT NULL THEN
    RAISE EXCEPTION 'O3b FAIL: a later edit set the original';
  END IF;
  IF pg_temp.as_st('a1', $q$SELECT public.exos_order_settings_save('de000000-0000-0000-0000-000000000001', false, 3)$q$) <> 'ok' THEN
    RAISE EXCEPTION 'O3b FAIL: overrides off';
  END IF;
  IF pg_temp.st('f1', 'order.send_receipt', 'cs_de4', '{}') <> '42501'
     OR pg_temp.st('f1', 'order.send_receipt', 'cs_de4', '{"email":"newer@y.com"}') <> '42501' THEN
    RAISE EXCEPTION 'O3b FAIL: no original, overrides off, but sent';
  END IF;
  IF pg_temp.as_st('a1', $q$SELECT public.exos_order_settings_save('de000000-0000-0000-0000-000000000001', true, 3)$q$) <> 'ok' THEN
    RAISE EXCEPTION 'O3b FAIL: overrides on';
  END IF;
  r := pg_temp.w('f1', 'order.send_receipt', 'cs_de4', '{}');
  IF r ->> 'to' <> 'newer@y.com' OR NOT (r ->> 'override')::boolean THEN RAISE EXCEPTION 'O3b FAIL: override with no original %', r; END IF;

  -- Erasure: b5's order has details, an original and an edit history.
  PERFORM pg_temp.w('f1', 'order.update', 'cs_de5',
    '{"fields":{"first_name":"Bea","last_name":"Five","phone":"+1 555 0105","notes":"aisle","email":"bea.alt@y.com"}}'::jsonb);
  PERFORM pg_temp.w('f1', 'order.send_receipt', 'cs_de5', '{}');
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000b5', true);
  PERFORM public.exos_delete_my_account();
  PERFORM set_config('app.uid', '', true);
  SELECT * INTO d FROM public.exos_order_details WHERE session_id = 'cs_de5';
  IF d.first_name IS NOT NULL OR d.last_name IS NOT NULL OR d.phone IS NOT NULL OR d.notes IS NOT NULL OR d.original_email IS NOT NULL
     OR (SELECT buyer_email FROM public.exos_checkout_sessions WHERE session_id = 'cs_de5') IS NOT NULL THEN
    RAISE EXCEPTION 'O3b FAIL: erasure left PII %', to_jsonb(d);
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_order_edits WHERE session_id = 'cs_de5'
              AND (position('de-b5@x.com' IN changes::text) > 0 OR position('bea.alt@y.com' IN changes::text) > 0)) THEN
    RAISE EXCEPTION 'O3b FAIL: addresses left in the edit history';
  END IF;
  -- Erased: refused, even with overrides on and an address given.
  IF pg_temp.st('f1', 'order.send_receipt', 'cs_de5', '{}') <> '22023'
     OR pg_temp.st('f1', 'order.send_receipt', 'cs_de5', '{"email":"de-b5@x.com"}') <> '22023' THEN
    RAISE EXCEPTION 'O3b FAIL: receipt for an erased order';
  END IF;
  RAISE NOTICE 'OK O3b no original = every address is an override; erasure clears order details and stops receipts';
END $$;

-- O3c ----------------------------------------------------------------------------
-- Erasure matches the email only when it is confirmed, and only whole values.
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('de000000-0000-0000-0000-0000000000b6','shared@x.com',NULL),
  ('de000000-0000-0000-0000-0000000000b7','bob@x.com',now());
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,guest,quantity,amount_cents,status,payment_intent) VALUES
  ('cs_deg1','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-000000000001',NULL,'shared@x.com',true,1,2000,'fulfilled','pi_deg1'),
  ('cs_deg2','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-000000000001',NULL,'bob@x.com',true,1,2000,'fulfilled','pi_deg2'),
  ('cs_dej','de000000-0000-0000-0000-0000000000e6','de000000-0000-0000-0000-0000000000d6','de000000-0000-0000-0000-000000000001',NULL,'jimbob@x.com',true,1,2000,'fulfilled','pi_dej');
DO $$
DECLARE d public.exos_order_details%ROWTYPE; h jsonb; n int;
BEGIN
  PERFORM pg_temp.w('f1', 'order.update', 'cs_deg1', '{"fields":{"first_name":"Guest","phone":"+1 555 0199","notes":"shared"}}'::jsonb);
  PERFORM pg_temp.w('f1', 'order.update', 'cs_deg2', '{"fields":{"first_name":"Bob","notes":"bob guest"}}'::jsonb);
  PERFORM pg_temp.w('f1', 'order.update', 'cs_dej', '{"fields":{"first_name":"Jim","email":"jim.b@x.com"}}'::jsonb);
  -- Overrides are on (O3b): a receipt of jimbob's order sent to bob@x.com.
  PERFORM pg_temp.w('f1', 'order.send_receipt', 'cs_dej', '{"email":"bob@x.com"}'::jsonb);

  -- An unconfirmed account with the guest's address erases nothing of theirs.
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000b6', true);
  PERFORM public.exos_delete_my_account();
  PERFORM set_config('app.uid', '', true);
  SELECT * INTO d FROM public.exos_order_details WHERE session_id = 'cs_deg1';
  IF d.first_name IS DISTINCT FROM 'Guest' OR d.phone IS DISTINCT FROM '+1 555 0199' OR d.original_email IS DISTINCT FROM 'shared@x.com'
     OR NOT EXISTS (SELECT 1 FROM public.exos_order_edits WHERE session_id = 'cs_deg1' AND changes ? 'first_name') THEN
    RAISE EXCEPTION 'O3c FAIL: an unconfirmed account erased a guest''s order %', to_jsonb(d);
  END IF;

  -- bob@x.com (confirmed) deletes: his guest order goes; jimbob@x.com stays,
  -- and only the receipt's exact bob@x.com value is redacted.
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000b7', true);
  PERFORM public.exos_delete_my_account();
  PERFORM set_config('app.uid', '', true);
  SELECT * INTO d FROM public.exos_order_details WHERE session_id = 'cs_deg2';
  IF d.first_name IS NOT NULL OR d.notes IS NOT NULL OR d.original_email IS NOT NULL
     OR EXISTS (SELECT 1 FROM public.exos_order_edits WHERE session_id = 'cs_deg2' AND NOT (changes = '{"erased": true}'::jsonb)) THEN
    RAISE EXCEPTION 'O3c FAIL: a confirmed email did not erase the guest order %', to_jsonb(d);
  END IF;
  SELECT * INTO d FROM public.exos_order_details WHERE session_id = 'cs_dej';
  IF d.first_name IS DISTINCT FROM 'Jim' OR d.original_email IS DISTINCT FROM 'jimbob@x.com' THEN
    RAISE EXCEPTION 'O3c FAIL: jimbob''s details erased %', to_jsonb(d);
  END IF;
  SELECT changes INTO h FROM public.exos_order_edits WHERE session_id = 'cs_dej' AND action = 'order.update';
  IF h #>> '{email,from}' <> 'jimbob@x.com' OR h #>> '{email,to}' <> 'jim.b@x.com' THEN
    RAISE EXCEPTION 'O3c FAIL: jimbob''s history touched %', h;
  END IF;
  SELECT changes INTO h FROM public.exos_order_edits WHERE session_id = 'cs_dej' AND action = 'order.receipt';
  IF h ->> 'to' <> '[erased]' OR NOT (h ->> 'override')::boolean THEN
    RAISE EXCEPTION 'O3c FAIL: receipt address not redacted (or the row wiped) %', h;
  END IF;
  SELECT count(*) INTO n FROM public.exos_order_edits WHERE position('bob@x.com' IN changes::text) > 0
     AND position('jimbob@x.com' IN changes::text) = 0;
  IF n <> 0 THEN RAISE EXCEPTION 'O3c FAIL: bob@x.com left in % history rows', n; END IF;
  RAISE NOTICE 'OK O3c erasure: confirmed email only, whole values only (jimbob@x.com survives bob@x.com)';
END $$;

-- O4 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; n int;
BEGIN
  -- b1's two tickets go in on the re-entry list; b2's on the implicit list.
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000a1', true);
  PERFORM public.exos_check_in_ticket('de000000-0000-0000-0000-000000000101', 'manual', 'manual', NULL, 'de000000-0000-0000-0000-0000000000e1',
    'box office', NULL, 'gate', 'de000000-0000-0000-0000-0000000000a9', 'entry');
  PERFORM public.exos_check_in_ticket('de000000-0000-0000-0000-000000000102', 'manual', 'manual', NULL, 'de000000-0000-0000-0000-0000000000e1',
    'box office', NULL, 'gate', 'de000000-0000-0000-0000-0000000000a9', 'entry');
  PERFORM public.exos_check_in_ticket('de000000-0000-0000-0000-000000000103', 'manual', 'manual', NULL, 'de000000-0000-0000-0000-0000000000e1',
    'box office', NULL, 'gate', NULL, 'entry');
  PERFORM set_config('app.uid', '', true);
  IF (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id IN ('de000000-0000-0000-0000-000000000101','de000000-0000-0000-0000-000000000102','de000000-0000-0000-0000-000000000103') AND direction = 'entry') <> 3 THEN
    RAISE EXCEPTION 'O4 FAIL: fixture check-ins';
  END IF;

  r := pg_temp.w('f1', 'order.check_out', 'cs_de1', '{"reason":"smoke break"}');
  IF (r ->> 'checked_out')::int <> 2 THEN RAISE EXCEPTION 'O4 FAIL: check-out %', r; END IF;
  SELECT count(*) INTO n FROM public.exos_event_checkins WHERE direction = 'exit'
     AND ticket_id IN ('de000000-0000-0000-0000-000000000101','de000000-0000-0000-0000-000000000102')
     AND scanned_by = 'de000000-0000-0000-0000-0000000000a1';
  IF n <> 2 THEN RAISE EXCEPTION 'O4 FAIL: exits recorded %', n; END IF;
  -- Again: everyone is already out.
  r := pg_temp.w('f1', 'order.check_out', 'cs_de1', '{}');
  IF (r ->> 'checked_out')::int <> 0 OR EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'results') x
                                                 WHERE x ->> 'reason' <> 'not-inside' OR (x ->> 'changed')::boolean) THEN
    RAISE EXCEPTION 'O4 FAIL: second check-out %', r;
  END IF;
  IF (SELECT count(*) FROM public.exos_event_checkins WHERE direction = 'exit'
       AND ticket_id IN ('de000000-0000-0000-0000-000000000101','de000000-0000-0000-0000-000000000102')) <> 2 THEN
    RAISE EXCEPTION 'O4 FAIL: not idempotent';
  END IF;
  -- Back in, then out once more (re-entry works after a check-out).
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000a1', true);
  r := public.exos_check_in_ticket('de000000-0000-0000-0000-000000000101', 'manual', 'manual', NULL, 'de000000-0000-0000-0000-0000000000e1',
    'back in', NULL, 'gate', 'de000000-0000-0000-0000-0000000000a9', 'entry');
  IF NOT (r ->> 'ok')::boolean THEN RAISE EXCEPTION 'O4 FAIL: re-entry %', r; END IF;
  r := public.exos_order_check_out('cs_de1', NULL, NULL, NULL);
  PERFORM set_config('app.uid', '', true);
  IF (r ->> 'checked_out')::int <> 1 THEN RAISE EXCEPTION 'O4 FAIL: re-exit %', r; END IF;
  -- The implicit list has no exits.
  r := pg_temp.w('f1', 'order.check_out', 'cs_de2', '{}');
  IF (r ->> 'checked_out')::int <> 0 OR r -> 'results' -> 0 ->> 'reason' <> 'exit-not-allowed' THEN
    RAISE EXCEPTION 'O4 FAIL: implicit list %', r;
  END IF;
  IF pg_temp.as_st('a3', $q$SELECT public.exos_order_check_out('cs_de1', NULL, NULL, NULL)$q$) <> '42501'
     OR pg_temp.st('f6', 'order.check_out', 'cs_de1', '{}') <> 'P0002' THEN
    RAISE EXCEPTION 'O4 FAIL: scanner / cross-org check-out';
  END IF;
  IF (SELECT count(*) FROM public.exos_order_edits WHERE session_id = 'cs_de1' AND action = 'order.check_out') <> 2 THEN
    RAISE EXCEPTION 'O4 FAIL: check-out audit (only calls that changed something)';
  END IF;
  RAISE NOTICE 'OK O4 order check-out: exits for tickets inside, idempotent, re-entry, implicit list refused, roles';
END $$;

-- O5 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.w('f1', 'ticket.update', 'de000000-0000-0000-0000-000000000102', '{"fields":{"first_name":"Sam","last_name":"Ray"}}');
  IF r ->> 'attendee_name' <> 'Sam Ray' OR NOT (r ->> 'changed')::boolean OR r ? 'barcode_secret' THEN
    RAISE EXCEPTION 'O5 FAIL: name %', r;
  END IF;
  IF (SELECT barcode_secret FROM public.exos_tickets WHERE id = 'de000000-0000-0000-0000-000000000102') <> 'sec102'
     OR (SELECT owner_id FROM public.exos_tickets WHERE id = 'de000000-0000-0000-0000-000000000102') <> 'de000000-0000-0000-0000-0000000000b1' THEN
    RAISE EXCEPTION 'O5 FAIL: holder or barcode changed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_order_edits WHERE ticket_id = 'de000000-0000-0000-0000-000000000102'
                  AND action = 'ticket.update' AND changes -> 'attendee_name' ->> 'to' = 'Sam Ray') THEN
    RAISE EXCEPTION 'O5 FAIL: ticket audit';
  END IF;
  IF pg_temp.st('f1', 'ticket.update', 'de000000-0000-0000-0000-000000000102', '{"fields":{"email":"someone@else.com"}}') <> '55000' THEN
    RAISE EXCEPTION 'O5 FAIL: a holder change went through';
  END IF;
  IF pg_temp.st('f1', 'ticket.update', 'de000000-0000-0000-0000-000000000102', '{"fields":{"email":"DE-B1@x.com","attendee_name":"Sam Ray"}}') <> 'ok' THEN
    RAISE EXCEPTION 'O5 FAIL: the holder''s own email refused';
  END IF;
  IF pg_temp.st('f1', 'ticket.update', 'de000000-0000-0000-0000-000000000102', '{"fields":{"owner_id":"de000000-0000-0000-0000-0000000000b2"}}') <> '22023'
     OR pg_temp.st('f1', 'ticket.update', 'de000000-0000-0000-0000-000000000102', '{"fields":{"price_paid":0}}') <> '22023' THEN
    RAISE EXCEPTION 'O5 FAIL: other fields accepted';
  END IF;
  IF pg_temp.st('f1', 'ticket.update', 'de000000-0000-0000-0000-000000000602', '{"fields":{"attendee_name":"X"}}') <> '55000' THEN
    RAISE EXCEPTION 'O5 FAIL: voided ticket edited';
  END IF;
  IF pg_temp.st('f1', 'ticket.update', 'de000000-0000-0000-0000-000000000901', '{"fields":{"attendee_name":"X"}}') <> 'P0002'
     OR pg_temp.st('f1', 'ticket.update', 'not-a-uuid', '{"fields":{"attendee_name":"X"}}') <> 'P0002'
     OR pg_temp.st('f1', 'ticket.update', 'de000000-0000-0000-0000-000000000102', '{"event_id":"de000000-0000-0000-0000-0000000000e2","fields":{"attendee_name":"X"}}') <> 'P0002' THEN
    RAISE EXCEPTION 'O5 FAIL: cross-org ticket';
  END IF;
  IF pg_temp.st('f2', 'ticket.update', 'de000000-0000-0000-0000-000000000102', '{"fields":{"attendee_name":"X"}}') <> '42501' THEN
    RAISE EXCEPTION 'O5 FAIL: scanner edited a ticket';
  END IF;
  RAISE NOTICE 'OK O5 ticket edit: attendee name, audited; holder changes refused (transfer); voided / other org refused';
END $$;

-- O6 -----------------------------------------------------------------------------
DO $$
DECLARE n_owner int; n_scan int; n_other int; n_fin int; d_fin int; d_scan int; r jsonb;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000a1', true);
  SELECT count(*) INTO n_owner FROM public.exos_order_edits WHERE org_id = 'de000000-0000-0000-0000-000000000001';
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000a3', true);
  SELECT count(*) INTO n_scan FROM public.exos_order_edits;
  SELECT count(*) INTO d_scan FROM public.exos_order_details;
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000a4', true);
  SELECT count(*) INTO n_fin FROM public.exos_order_edits;
  SELECT count(*) INTO d_fin FROM public.exos_order_details;
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000a5', true);
  SELECT count(*) INTO n_other FROM public.exos_order_edits WHERE org_id = 'de000000-0000-0000-0000-000000000001';
  RESET ROLE;
  PERFORM set_config('app.uid', '', true);
  IF n_owner = 0 OR n_scan <> 0 OR n_other <> 0 OR n_fin <> 0 OR d_scan <> 0 OR d_fin = 0 THEN
    RAISE EXCEPTION 'O6 FAIL: RLS owner % scanner % other % finance % / details finance % scanner %', n_owner, n_scan, n_other, n_fin, d_fin, d_scan;
  END IF;
  -- The dashboard table: finance reads orders, scanners don't; search and sort.
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000a4', true);
  r := public.exos_org_orders('de000000-0000-0000-0000-000000000001', 'dana', NULL, NULL, 'amount_cents', true, 10, 0);
  PERFORM set_config('app.uid', '', true);
  IF (r ->> 'total')::int <> 1 OR r -> 'rows' -> 0 ->> 'session_id' <> 'cs_de1' OR (r -> 'rows' -> 0 ->> 'receipts_sent')::int <> 3 THEN
    RAISE EXCEPTION 'O6 FAIL: orders table %', r;
  END IF;
  PERFORM set_config('app.uid', 'de000000-0000-0000-0000-0000000000a4', true);
  r := public.exos_order_tickets('cs_de1');
  PERFORM set_config('app.uid', '', true);
  IF jsonb_array_length(r) <> 2 OR r::text LIKE '%sec10%' THEN RAISE EXCEPTION 'O6 FAIL: order tickets %', r; END IF;
  IF pg_temp.as_st('a3', $q$SELECT public.exos_org_orders('de000000-0000-0000-0000-000000000001')$q$) <> '42501'
     OR pg_temp.as_st('a5', $q$SELECT public.exos_org_orders('de000000-0000-0000-0000-000000000001')$q$) <> '42501'
     OR pg_temp.as_st('a4', $q$SELECT public.exos_order_edit_log('de000000-0000-0000-0000-000000000001')$q$) <> '42501'
     OR pg_temp.as_st('a3', $q$SELECT public.exos_order_tickets('cs_de1')$q$) <> '42501'
     OR pg_temp.as_st('a5', $q$SELECT public.exos_order_tickets('cs_de1')$q$) <> '42501' THEN
    RAISE EXCEPTION 'O6 FAIL: orders / log roles';
  END IF;
  RAISE NOTICE 'OK O6 RLS: the audit is owner / manager only, details owner / manager / finance; the orders table by role';
END $$;

-- G1 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_list uuid := 'de000000-0000-0000-0000-0000000000a8'; n int;
BEGIN
  INSERT INTO public.exos_guest_lists(id,event_id,org_id,name,cap,max_plus_ones,counts_toward_capacity)
  VALUES (v_list,'de000000-0000-0000-0000-0000000000e2','de000000-0000-0000-0000-000000000001','Friends',3,5,true);
  INSERT INTO public.exos_guest_list_entries(list_id,event_id,org_id,guest_name,email,plus_ones)
  VALUES (v_list,'de000000-0000-0000-0000-0000000000e2','de000000-0000-0000-0000-000000000001','Ann Lee','ann@x.com',0);
  SELECT count(*) INTO n FROM public.exos_guest_list_entries;
  r := public._exos_guest_list_preview('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000000e2', v_list,
    jsonb_build_array(
      jsonb_build_object('name', 'ann lee', 'email', 'ANN@x.com'),
      jsonb_build_object('name', 'Bob', 'email', 'bob@'),
      jsonb_build_object('name', '  '),
      jsonb_build_object('name', 'Cy', 'plus_ones', 2),
      jsonb_build_object('name', 'cy', 'plus_ones', 2),
      jsonb_build_object('name', 'Dee', 'code', repeat('Z', 130)),
      jsonb_build_object('name', 'Eve', 'plus_ones', 7)));
  IF r -> 'rows' -> 0 ->> 'status' <> 'duplicate' OR r -> 'rows' -> 0 ->> 'existing_list_name' <> 'Friends'
     OR r -> 'rows' -> 1 ->> 'status' <> 'ready' OR r -> 'rows' -> 1 -> 'warnings' ->> 0 <> 'invalid_email'
     OR r -> 'rows' -> 2 ->> 'status' <> 'invalid'
     OR r -> 'rows' -> 3 ->> 'status' <> 'ready' OR (r -> 'rows' -> 3 ->> 'tickets')::int <> 3
     OR r -> 'rows' -> 4 ->> 'reason' <> 'in_file'
     OR r -> 'rows' -> 5 ->> 'reason' <> 'code too long'
     OR r -> 'rows' -> 6 ->> 'status' <> 'too_many_plus_ones' THEN
    RAISE EXCEPTION 'G1 FAIL: rows %', r -> 'rows';
  END IF;
  IF (r -> 'summary' ->> 'ready')::int <> 2 OR (r -> 'summary' ->> 'duplicates')::int <> 2 OR (r -> 'summary' ->> 'invalid')::int <> 3
     OR (r -> 'summary' ->> 'invalid_emails')::int <> 1 OR (r -> 'summary' ->> 'heads')::int <> 4 THEN
    RAISE EXCEPTION 'G1 FAIL: summary %', r -> 'summary';
  END IF;
  -- Cap 3, one in, four more = 2 over; the list counts toward the event's 10 (1 sold, 1 guest).
  IF (r -> 'capacity' ->> 'list_cap_left_after')::int <> -2 OR NOT (r -> 'capacity' ->> 'over_list_cap')::boolean
     OR (r -> 'capacity' ->> 'event_left_after')::int <> 4 THEN
    RAISE EXCEPTION 'G1 FAIL: capacity %', r -> 'capacity';
  END IF;
  IF (SELECT count(*) FROM public.exos_guest_list_entries) <> n THEN RAISE EXCEPTION 'G1 FAIL: the preview wrote'; END IF;
  BEGIN
    PERFORM public._exos_guest_list_preview('de000000-0000-0000-0000-000000000002', 'de000000-0000-0000-0000-0000000000e2', NULL, '[]');
    RAISE EXCEPTION 'G1 FAIL: other org previewed';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  IF pg_temp.as_st('a3', $q$SELECT public.exos_guest_list_preview('de000000-0000-0000-0000-0000000000e2', NULL, '[]')$q$) <> '42501'
     OR pg_temp.as_st('a2', $q$SELECT public.exos_guest_list_preview('de000000-0000-0000-0000-0000000000e2', NULL, '[{"name":"Zed"}]')$q$) <> 'ok' THEN
    RAISE EXCEPTION 'G1 FAIL: preview roles';
  END IF;
  RAISE NOTICE 'OK G1 guest-list preview: statuses, duplicates, invalid emails, capacity; writes nothing; org-scoped';
END $$;

-- R1 -----------------------------------------------------------------------------
DO $$
BEGIN
  -- Same weights as REC_WEIGHTS (src/lib/recommendations.test.ts has the same cases).
  IF public._exos_rec_score(1, true, false, 1, 0, 0, 0, 30) <> 125
     OR public._exos_rec_score(5, true, true, 9, 9, 99, 0, 30) <> 150 + 40 + 30 + 60 + 50 + 50 + 20
     OR public._exos_rec_score(0, false, false, 0, 0, 0, 0, 30) <> 0
     OR public._exos_rec_score(0, false, false, 0, 1, 0, 15, 30) <> 20
     OR public._exos_rec_score(0, false, false, 0, 1, 0, 45, 30) <> 10
     OR public._exos_rec_score(1, false, false, 0, 0, 0, NULL, 30) <> 50
     OR public._exos_rec_fan_score(1, 2, 0, 4, 1) <> 50 + 80 + 45 + 10 THEN
    RAISE EXCEPTION 'R1 FAIL: weights';
  END IF;
  RAISE NOTICE 'OK R1 the score''s weights';
END $$;

-- R2 / R3 ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; ids text[];
BEGIN
  r := public._exos_rec_similar_events('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000000e1', false, 50, 0);
  SELECT array_agg(x ->> 'id') INTO ids FROM jsonb_array_elements(r -> 'rows') x;
  IF ids IS DISTINCT FROM ARRAY['de000000-0000-0000-0000-0000000000e2'] OR (r ->> 'total')::int <> 1 THEN
    RAISE EXCEPTION 'R2 FAIL: candidates % (only the public upcoming match)', ids;
  END IF;
  -- e2: 1 artist, same venue, 1 genre, 1 co-buyer (b2), 5 days apart: 50 + 40 + 15 + 5 + (20 - 3).
  IF (r -> 'rows' -> 0 -> 'signals' ->> 'shared_artists')::int <> 1 OR NOT (r -> 'rows' -> 0 -> 'signals' ->> 'same_venue')::boolean
     OR (r -> 'rows' -> 0 -> 'signals' ->> 'shared_genres')::int <> 1 OR (r -> 'rows' -> 0 -> 'signals' ->> 'co_buyers')::int <> 1
     OR (r -> 'rows' -> 0 ->> 'score')::int <> 127 THEN
    RAISE EXCEPTION 'R2 FAIL: signals %', r -> 'rows' -> 0;
  END IF;
  IF position('@' IN r::text) > 0 THEN RAISE EXCEPTION 'R2 FAIL: an email in the answer'; END IF;

  r := public._exos_rec_similar_events('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000000e1', true, 50, 0);
  SELECT array_agg(x ->> 'id' ORDER BY x ->> 'id') INTO ids FROM jsonb_array_elements(r -> 'rows') x;
  IF ids IS DISTINCT FROM ARRAY['de000000-0000-0000-0000-0000000000e2', 'de000000-0000-0000-0000-0000000000e9'] THEN
    RAISE EXCEPTION 'R3 FAIL: cross-org candidates % (e8 is a draft)', ids;
  END IF;
  SELECT x INTO r FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'id' = 'de000000-0000-0000-0000-0000000000e9';
  -- b1 bought both e1 and e9, but co-buyers never cross orgs.
  IF (r ->> 'same_org')::boolean OR (r -> 'signals' ->> 'co_buyers')::int <> 0 OR (r -> 'signals' ->> 'shared_artists')::int <> 1
     OR (r -> 'signals' ->> 'same_series')::boolean OR r -> 'org' ->> 'slug' <> 'de-other' OR position('@' IN r::text) > 0
     OR r ? 'tickets_sold' OR r ? 'total_tickets' THEN
    RAISE EXCEPTION 'R3 FAIL: other org''s card %', r;
  END IF;
  -- Org 2 asking about org 1's event: not found; and it never sees org 1's draft e3.
  BEGIN
    PERFORM public._exos_rec_similar_events('de000000-0000-0000-0000-000000000002', 'de000000-0000-0000-0000-0000000000e1', true, 50, 0);
    RAISE EXCEPTION 'R3 FAIL: another org''s event as the source';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  r := public._exos_rec_similar_events('de000000-0000-0000-0000-000000000002', 'de000000-0000-0000-0000-0000000000e9', true, 50, 0);
  SELECT array_agg(x ->> 'id' ORDER BY x ->> 'id') INTO ids FROM jsonb_array_elements(r -> 'rows') x;
  IF ids IS DISTINCT FROM ARRAY['de000000-0000-0000-0000-0000000000e2'] THEN
    RAISE EXCEPTION 'R3 FAIL: org 2 sees % (e3 draft, e4 noindex, e5 cancelled, e6 past must not show)', ids;
  END IF;
  IF (r -> 'rows' -> 0 -> 'signals' ->> 'co_buyers')::int <> 0 THEN RAISE EXCEPTION 'R3 FAIL: co-buyers across orgs'; END IF;
  -- Paging is stable.
  r := public._exos_rec_similar_events('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000000e1', true, 1, 1);
  IF jsonb_array_length(r -> 'rows') <> 1 OR (r ->> 'total')::int <> 2 THEN RAISE EXCEPTION 'R3 FAIL: paging %', r; END IF;
  RAISE NOTICE 'OK R2/R3 similar events: public upcoming only, signals and score, co-buyers in-org and counted only, cross-org opt-in';
END $$;

-- R4 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; ids text[];
BEGIN
  -- b3 bought e6 (past, Nova Lane, The Room): e2 is the match (e1 has started).
  r := public._exos_rec_fan_events('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000001f3', false, 50, 0);
  SELECT array_agg(x ->> 'id') INTO ids FROM jsonb_array_elements(r -> 'rows') x;
  IF ids IS DISTINCT FROM ARRAY['de000000-0000-0000-0000-0000000000e2'] THEN RAISE EXCEPTION 'R4 FAIL: fan events %', ids; END IF;
  -- b2 already holds e2: not recommended back.
  r := public._exos_rec_fan_events('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000001f2', true, 50, 0);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'id' = 'de000000-0000-0000-0000-0000000000e2') THEN
    RAISE EXCEPTION 'R4 FAIL: a held event recommended %', r;
  END IF;
  -- b1 as org 2's fan: only their org-2 history (e9: the artist, Big Club)
  -- counts, never their org-1 orders (e1 at The Room); e9 itself is held.
  r := public._exos_rec_fan_events('de000000-0000-0000-0000-000000000002', 'de000000-0000-0000-0000-0000000009f1', false, 50, 0);
  IF (r ->> 'total')::int <> 0 THEN RAISE EXCEPTION 'R4 FAIL: org 2 alone %', r; END IF;
  r := public._exos_rec_fan_events('de000000-0000-0000-0000-000000000002', 'de000000-0000-0000-0000-0000000009f1', true, 50, 0);
  IF (r ->> 'total')::int <> 1 OR r -> 'rows' -> 0 ->> 'id' <> 'de000000-0000-0000-0000-0000000000e2'
     OR (r -> 'rows' -> 0 -> 'signals' ->> 'same_venue')::boolean OR (r -> 'rows' -> 0 -> 'signals' ->> 'co_buyers')::int <> 0
     OR (r -> 'rows' -> 0 ->> 'same_org')::boolean THEN
    RAISE EXCEPTION 'R4 FAIL: another org''s history used %', r;
  END IF;
  -- No cross-tenant oracle: b1 (org 1's fan) holds org 2's e9; scope=all for
  -- org 1 must still list e9, and the same answer comes back without that ticket.
  r := public._exos_rec_fan_events('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000001f1', true, 50, 0);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'id' = 'de000000-0000-0000-0000-0000000000e9') THEN
    RAISE EXCEPTION 'R4 FAIL: another org''s ticket hid e9 %', r;
  END IF;
  UPDATE public.exos_tickets SET status = 'voided' WHERE id = 'de000000-0000-0000-0000-000000000901';
  IF public._exos_rec_fan_events('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000001f1', true, 50, 0) <> r THEN
    RAISE EXCEPTION 'R4 FAIL: a ticket at another org changed the answer';
  END IF;
  UPDATE public.exos_tickets SET status = 'active' WHERE id = 'de000000-0000-0000-0000-000000000901';
  BEGIN
    PERFORM public._exos_rec_fan_events('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000009f1', true, 50, 0);
    RAISE EXCEPTION 'R4 FAIL: another org''s fan';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  RAISE NOTICE 'OK R4 events for a fan: this org''s history only, held events left out, fans org-scoped';
END $$;

-- R5 / R6 ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; ids text[];
BEGIN
  r := public._exos_rec_event_fans('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000000e2', 50, 0);
  SELECT array_agg(x ->> 'id') INTO ids FROM jsonb_array_elements(r -> 'rows') x;
  -- b3: on the list, bought e6 (artist, venue, genre). b2 holds e2; b1 never
  -- opted in; b4 unsubscribed (and voided).
  IF ids IS DISTINCT FROM ARRAY['de000000-0000-0000-0000-0000000001f3'] THEN RAISE EXCEPTION 'R5 FAIL: fans %', ids; END IF;
  IF (r -> 'rows' -> 0 ->> 'score')::int <> 50 + 40 + 15 OR (r -> 'rows' -> 0 -> 'signals' ->> 'artist_events')::int <> 1 THEN
    RAISE EXCEPTION 'R5 FAIL: fan score %', r -> 'rows' -> 0;
  END IF;
  BEGIN
    PERFORM public._exos_rec_event_fans('de000000-0000-0000-0000-000000000002', 'de000000-0000-0000-0000-0000000000e2', 50, 0);
    RAISE EXCEPTION 'R5 FAIL: another org''s event';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  IF pg_temp.as_st('a6', $q$SELECT public.exos_event_similar_events('de000000-0000-0000-0000-0000000000e1')$q$) <> 'ok'
     OR pg_temp.as_st('a6', $q$SELECT public.exos_event_fan_recommendations('de000000-0000-0000-0000-0000000000e2')$q$) <> '42501'
     OR pg_temp.as_st('a3', $q$SELECT public.exos_event_similar_events('de000000-0000-0000-0000-0000000000e1')$q$) <> '42501'
     OR pg_temp.as_st('a4', $q$SELECT public.exos_event_fan_recommendations('de000000-0000-0000-0000-0000000000e2')$q$) <> 'ok'
     OR pg_temp.as_st('a5', $q$SELECT public.exos_event_fan_recommendations('de000000-0000-0000-0000-0000000000e2')$q$) <> '42501'
     OR pg_temp.as_st('a5', $q$SELECT public.exos_fan_event_recommendations('de000000-0000-0000-0000-000000000001', 'de000000-0000-0000-0000-0000000001f3')$q$) <> '42501' THEN
    RAISE EXCEPTION 'R6 FAIL: wrapper roles';
  END IF;
  RAISE NOTICE 'OK R5/R6 fans for an event: on the list, not holders, scored; wrappers by role';
END $$;

ROLLBACK;
