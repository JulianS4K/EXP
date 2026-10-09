-- ============================================================================
-- RPC hardening (mig 20260929080000). Self-contained (a8 prefix), rolled back
-- at the end.
--   H1 every Exos SECURITY DEFINER function (and exos_platform_fee_bps) pins
--      its search_path
--   H2 internal helpers are not client-callable; the public views that use
--      them still read fine as anon; service_role keeps them
--   H3 the anon-callable Exos definer RPCs are exactly the intended public
--      set (token-gated, throttled or public by design)
--   H4 exos_leave_waitlist: anon can't call it; a signed-in fan still leaves
--   H5 exos_check_in_offline: a signed-in outsider is refused and writes
--      nothing; the org's scanner still replays
--   H6 exos_queue_mail: the same mail twice is one row; 10 a minute per
--      caller; someone else's transfer is still refused
--   H7 exos_queue_ticket_issued: the same "ticket ready" mail twice is one
--      row; a stranger is still refused
--   H8 the transfer-initiated mail's claim link carries the claim key, and
--      that key lets any account claim
--   H9 exos_create_org: first org (onboarding) works; 3 a day and 20 per
--      account; platform admins exempt
--   H10 voucher checks need an account: anon can't run the three voucher
--      RPCs; a signed-in buyer still checks a code
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a8000000-0000-0000-0000-0000000000a1','a8-owner@x.com',now()),
  ('a8000000-0000-0000-0000-0000000000a2','a8-scan@x.com',now()),
  ('a8000000-0000-0000-0000-0000000000b1','a8-fan@x.com',now()),
  ('a8000000-0000-0000-0000-0000000000b2','a8-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a8000000-0000-0000-0000-000000000001','A8 Org','a8-org','a8000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a8000000-0000-0000-0000-000000000001','a8000000-0000-0000-0000-0000000000a1','owner'),
  ('a8000000-0000-0000-0000-000000000001','a8000000-0000-0000-0000-0000000000a2','scanner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('a8000000-0000-0000-0000-0000000000e1','a8000000-0000-0000-0000-000000000001','A8 Show','a8-show','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'a8000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('a8000000-0000-0000-0000-0000000000d1','a8000000-0000-0000-0000-0000000000e1','GA',25,100,0);
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
VALUES ('a8000000-0000-0000-0000-0000000000c1','a8000000-0000-0000-0000-0000000000e1','a8000000-0000-0000-0000-000000000001',
        'a8000000-0000-0000-0000-0000000000d1','GA','a8000000-0000-0000-0000-0000000000b1','a8000000-0000-0000-0000-0000000000b1',
        'active','sek-a8',25,'a8-order-1');

CREATE FUNCTION pg_temp.act(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true),
         set_config('app.jwt', CASE WHEN p_email IS NULL THEN '' ELSE json_build_object('email', p_email)::text END, true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text, text) TO anon, authenticated;

-- H1 -------------------------------------------------------------------------
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname LIKE '%exos%'
     AND (p.prosecdef OR p.proname = 'exos_platform_fee_bps')
     AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) c WHERE c LIKE 'search_path=%');
  ASSERT bad IS NULL, 'H1: functions without a pinned search_path: ' || bad;
  ASSERT public.exos_platform_fee_bps() = 300, 'H1: exos_platform_fee_bps still answers';
  RAISE NOTICE 'OK  H1 search_path pinned';
END $$;

-- H2 -------------------------------------------------------------------------
DO $$
DECLARE f text; n int;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_tier_is_table(uuid)', 'public.exos_tier_party_size(uuid)',
    'public.exos_channel_allocated(uuid)', 'public.exos_event_house_available(uuid)',
    'public.exos_redeem_discount_code(uuid,text)'
  ] LOOP
    CONTINUE WHEN to_regprocedure(f) IS NULL;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'H2: anon can still run ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'H2: authenticated can still run ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'H2: service_role lost ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('anon', 'public.exos_has_org_role(uuid,text[])', 'EXECUTE'), 'H2: has_org_role is signed-in only';
  ASSERT has_function_privilege('authenticated', 'public.exos_has_org_role(uuid,text[])', 'EXECUTE'), 'H2: policies still call has_org_role';
  -- exos_event_is_published backs the anon tier-read policy: it stays.
  ASSERT has_function_privilege('anon', 'public.exos_event_is_published(uuid)', 'EXECUTE'), 'H2: tier policy helper kept';
  RAISE NOTICE 'OK  H2 helper grants';
END $$;

-- The public tier view still computes its tax column for anon (it runs as its
-- owner, so the helper grant was never needed).
SELECT pg_temp.act(NULL, NULL);
SET LOCAL ROLE anon;
DO $$
DECLARE n int; refused boolean := false;
BEGIN
  SELECT count(*) INTO n FROM public.exos_public_tiers WHERE event_id = 'a8000000-0000-0000-0000-0000000000e1';
  ASSERT n = 1, 'H2: anon reads the public tier view, got ' || n;
  -- Every column, as the event page does (select *): a count never evaluates
  -- exclusive_tax_percent, which is how a revoked helper slipped through
  -- (mig 20261008100000).
  SELECT count(*) INTO n FROM (SELECT * FROM public.exos_public_tiers
                                WHERE event_id = 'a8000000-0000-0000-0000-0000000000e1' OFFSET 0) x
   WHERE x.exclusive_tax_percent IS NOT NULL;
  ASSERT n = 1, 'H2: anon reads exclusive_tax_percent on the tier view, got ' || n;
  PERFORM * FROM (SELECT * FROM public.exos_public_addons OFFSET 0) y WHERE y.exclusive_tax_percent IS NOT NULL;
  BEGIN
    PERFORM public.exos_tier_party_size('a8000000-0000-0000-0000-0000000000d1');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'H2: anon calling the party-size helper is refused';
  RAISE NOTICE 'OK  H2 public view still reads as anon';
END $$;
RESET ROLE;

-- H3 -------------------------------------------------------------------------
DO $$
DECLARE extra text;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO extra
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname LIKE '%exos%' AND p.prosecdef
     AND p.proname NOT LIKE 'exos\_test\_%'          -- harness-only helpers (prereq.sql)
     AND has_function_privilege('anon', p.oid, 'EXECUTE')
     AND p.proname NOT IN (
       -- public by design
       'exos_event_is_published', 'exos_public_promoter', 'exos_public_table_tiers',
       'exos_transfer_claim_preview', 'exos_invite_preview', 'exos_server_time',
       -- the public tier / add-on views call these as the reader (mig 20261008100000)
       'exos_tier_exclusive_tax_percent', 'exos_addon_exclusive_tax_percent',
       -- bearer-token gated (64-hex unsubscribe token / promoter kit uuid)
       'exos_mail_unsubscribe',
       'exos_promoter_kit', 'exos_promoter_earnings', 'exos_promoter_guest_lists',
       'exos_promoter_limit_flags', 'exos_promoter_note_limit_flag', 'exos_promoter_add_guest',
       'exos_promoter_remove_guest', 'exos_promoter_set_guest_access_needs', 'exos_promoter_set_socials');
  ASSERT extra IS NULL, 'H3: unexpected anon-callable definer functions: ' || extra;
  RAISE NOTICE 'OK  H3 anon surface is the intended set';
END $$;

-- H4 -------------------------------------------------------------------------
INSERT INTO public.exos_waitlist(id,event_id,user_id,email,quantity)
VALUES ('a8000000-0000-0000-0000-0000000000f1','a8000000-0000-0000-0000-0000000000e1',
        'a8000000-0000-0000-0000-0000000000b1','a8-fan@x.com',1);
DO $$
BEGIN
  ASSERT NOT has_function_privilege('anon', 'public.exos_leave_waitlist(uuid,text)', 'EXECUTE'), 'H4: anon can''t leave';
END $$;
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b2', 'a8-stranger@x.com');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT NOT public.exos_leave_waitlist('a8000000-0000-0000-0000-0000000000f1', 'a8-fan@x.com'),
         'H4: a stranger can''t cancel someone''s entry';
END $$;
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b1', 'a8-fan@x.com');
DO $$
BEGIN
  ASSERT public.exos_leave_waitlist('a8000000-0000-0000-0000-0000000000f1', NULL), 'H4: the fan leaves';
  RAISE NOTICE 'OK  H4 leave waitlist';
END $$;
RESET ROLE;

-- H5 -------------------------------------------------------------------------
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b2', 'a8-stranger@x.com');
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_check_in_offline('a8000000-0000-0000-0000-00000000aaa1',
      'a8000000-0000-0000-0000-0000000000c1', 'a8000000-0000-0000-0000-0000000000e1',
      now() - interval '1 minute', 'T-junk:x:1:y', 'camera');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'H5: an outsider is refused';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref = 'a8000000-0000-0000-0000-00000000aaa1'),
         'H5: no client ref written';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_scan_rejects WHERE event_id = 'a8000000-0000-0000-0000-0000000000e1'),
         'H5: nothing in the org''s door log';
  -- Nor with a made-up ticket id (that path wrote a client ref before).
  refused := false;
  BEGIN
    PERFORM public.exos_check_in_offline('a8000000-0000-0000-0000-00000000aaa2',
      'a8000000-0000-0000-0000-00000000dead', 'a8000000-0000-0000-0000-0000000000e1',
      now() - interval '1 minute', NULL, 'manual');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'H5: an outsider with an unknown ticket is refused too';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref = 'a8000000-0000-0000-0000-00000000aaa2'),
         'H5: still no client ref';
END $$;
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000a2', 'a8-scan@x.com');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_check_in_offline('a8000000-0000-0000-0000-00000000aaa3',
         'a8000000-0000-0000-0000-0000000000c1', 'a8000000-0000-0000-0000-0000000000e1',
         now() - interval '1 minute', 'T-junk:x:1:y', 'camera');
  ASSERT NOT (r ->> 'ok')::boolean AND (r ->> 'conflict')::boolean, 'H5: the scanner gets the conflict, got ' || r;
  ASSERT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref = 'a8000000-0000-0000-0000-00000000aaa3'),
         'H5: the scanner''s replay is recorded';
  RAISE NOTICE 'OK  H5 offline check-in is door staff only';
END $$;

-- H6 -------------------------------------------------------------------------
INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status) VALUES
  ('a8000000-0000-0000-0000-0000000000f7','a8000000-0000-0000-0000-0000000000c1',
   'a8000000-0000-0000-0000-000000000001','a8000000-0000-0000-0000-0000000000b1','victim@x.com','pending');
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b1', 'a8-fan@x.com');
DO $$
DECLARE id1 uuid; id2 uuid; refused boolean := false;
BEGIN
  id1 := public.exos_queue_mail('transfer-initiated', 'a8000000-0000-0000-0000-0000000000f7');
  id2 := public.exos_queue_mail('transfer-initiated', 'a8000000-0000-0000-0000-0000000000f7');
  ASSERT id1 = id2, 'H6: the same mail twice is the same row';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE to_email = 'victim@x.com') = 1, 'H6: one mail queued';

  -- Past the dedupe window, but over the per-caller limit this minute.
  UPDATE public.exos_mail SET created_at = now() - interval '11 minutes' WHERE id = id1;
  INSERT INTO public.exos_rate_windows(bucket, window_start, hits)
  VALUES ('queue_mail:a8000000-0000-0000-0000-0000000000b1', date_trunc('minute', now()), 10)
  ON CONFLICT (bucket, window_start) DO UPDATE SET hits = 10;
  BEGIN
    PERFORM public.exos_queue_mail('transfer-initiated', 'a8000000-0000-0000-0000-0000000000f7');
  EXCEPTION WHEN program_limit_exceeded THEN refused := true;
  END;
  ASSERT refused, 'H6: the 11th mail in a minute is refused';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE to_email = 'victim@x.com') = 1, 'H6: still one mail';
  DELETE FROM public.exos_rate_windows WHERE bucket = 'queue_mail:a8000000-0000-0000-0000-0000000000b1';
  ASSERT public.exos_queue_mail('transfer-initiated', 'a8000000-0000-0000-0000-0000000000f7') <> id1,
         'H6: under the limit and past the window, a new mail is queued';
END $$;
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b2', 'a8-stranger@x.com');
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_queue_mail('transfer-initiated', 'a8000000-0000-0000-0000-0000000000f7');
  EXCEPTION WHEN raise_exception THEN refused := true;
  END;
  ASSERT refused, 'H6: someone else''s transfer is refused';
  RAISE NOTICE 'OK  H6 queue_mail dedupe + rate limit';
END $$;

-- H7 -------------------------------------------------------------------------
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b1', 'a8-fan@x.com');
DO $$
DECLARE id1 uuid; id2 uuid;
BEGIN
  id1 := public.exos_queue_ticket_issued('a8000000-0000-0000-0000-0000000000c1');
  id2 := public.exos_queue_ticket_issued('a8000000-0000-0000-0000-0000000000c1');
  ASSERT id1 = id2, 'H7: the same ticket-ready mail twice is the same row';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'ticket-issued' AND to_email = 'a8-fan@x.com') = 1,
         'H7: one mail queued';
END $$;
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b2', 'a8-stranger@x.com');
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_queue_ticket_issued('a8000000-0000-0000-0000-0000000000c1');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'H7: a stranger can''t mail a ticket holder';
  RAISE NOTICE 'OK  H7 queue_ticket_issued dedupe';
END $$;

-- H8 -------------------------------------------------------------------------
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
VALUES ('a8000000-0000-0000-0000-0000000000c2','a8000000-0000-0000-0000-0000000000e1','a8000000-0000-0000-0000-000000000001',
        'a8000000-0000-0000-0000-0000000000d1','GA','a8000000-0000-0000-0000-0000000000b1','a8000000-0000-0000-0000-0000000000b1',
        'active','sek-a8-2',25,'a8-order-2');
INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status) VALUES
  ('a8000000-0000-0000-0000-0000000000f8','a8000000-0000-0000-0000-0000000000c2',
   'a8000000-0000-0000-0000-000000000001','a8000000-0000-0000-0000-0000000000b1','friend@x.com','pending');
UPDATE public.exos_tickets SET pending_transfer_id = 'a8000000-0000-0000-0000-0000000000f8'
 WHERE id = 'a8000000-0000-0000-0000-0000000000c2';
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b1', 'a8-fan@x.com');
DO $$
DECLARE v_id uuid; v_html text; v_key text; v_link_key text; v_ticket uuid;
BEGIN
  v_id := public.exos_queue_mail('transfer-initiated', 'a8000000-0000-0000-0000-0000000000f8');
  SELECT html INTO v_html FROM public.exos_mail WHERE id = v_id;
  SELECT claim_key INTO v_key FROM public.exos_transfers WHERE id = 'a8000000-0000-0000-0000-0000000000f8';
  v_link_key := substring(v_html FROM '/claim/a8000000-0000-0000-0000-0000000000f8\?k=([0-9a-f]+)"');
  ASSERT v_link_key IS NOT NULL AND v_link_key = v_key, 'H8: the mailed link carries the claim key, got ' || v_html;
  -- A different account (not the addressed one) claims with the link's key.
  PERFORM pg_temp.act('a8000000-0000-0000-0000-0000000000b2', 'a8-stranger@x.com');
  v_ticket := public.exos_claim_transfer('a8000000-0000-0000-0000-0000000000f8', v_link_key);
  ASSERT v_ticket = 'a8000000-0000-0000-0000-0000000000c2'
     AND (SELECT owner_id FROM public.exos_tickets WHERE id = v_ticket) = 'a8000000-0000-0000-0000-0000000000b2',
         'H8: any account claims with the mailed link';
  RAISE NOTICE 'OK  H8 transfer mail carries the claim key';
END $$;

-- H9 -------------------------------------------------------------------------
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a8000000-0000-0000-0000-0000000000c9','a8-founder@x.com',now()),
  ('a8000000-0000-0000-0000-0000000000ca','a8-veteran@x.com',now()),
  ('a8000000-0000-0000-0000-0000000000cb','a8-admin@x.com',now());
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000c9', 'a8-founder@x.com');
DO $$
DECLARE v_org uuid; refused boolean := false; msg text;
BEGIN
  v_org := public.exos_create_org('Founder One', 'a8-founder-1');
  ASSERT (SELECT role FROM public.exos_org_memberships
           WHERE org_id = v_org AND user_id = 'a8000000-0000-0000-0000-0000000000c9') = 'owner',
         'H9: onboarding still creates the org with the caller as owner';
  PERFORM public.exos_create_org('Founder Two', 'a8-founder-2');
  PERFORM public.exos_create_org('Founder Three', 'a8-founder-3');
  BEGIN
    PERFORM public.exos_create_org('Founder Four', 'a8-founder-4');
  EXCEPTION WHEN program_limit_exceeded THEN refused := true; msg := SQLERRM;
  END;
  ASSERT refused AND msg LIKE '%3 a day%', 'H9: the 4th org in a day is refused';
  ASSERT (SELECT count(*) FROM public.exos_orgs WHERE owner_uid = 'a8000000-0000-0000-0000-0000000000c9') = 3,
         'H9: nothing created by the refused call';
  -- A day later the daily cap is clear again.
  UPDATE public.exos_orgs SET created_at = now() - interval '25 hours'
   WHERE owner_uid = 'a8000000-0000-0000-0000-0000000000c9';
  PERFORM public.exos_create_org('Founder Four', 'a8-founder-4');
END $$;
-- 20 in all: a veteran owning 20 old orgs can't create a 21st.
INSERT INTO public.exos_orgs(id,name,slug,owner_uid,created_at)
SELECT ('a8000000-0000-0000-0000-0000000010' || lpad(n::text, 2, '0'))::uuid, 'Old ' || n, 'a8-old-' || n,
       'a8000000-0000-0000-0000-0000000000ca', now() - interval '30 days'
  FROM generate_series(1, 20) n;
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000ca', 'a8-veteran@x.com');
DO $$
DECLARE refused boolean := false; msg text;
BEGIN
  BEGIN
    PERFORM public.exos_create_org('One Too Many', 'a8-too-many');
  EXCEPTION WHEN program_limit_exceeded THEN refused := true; msg := SQLERRM;
  END;
  ASSERT refused AND msg LIKE '%20 per account%', 'H9: the 21st org is refused';
END $$;
-- Platform admins are exempt (the harness stub says false; flip it here,
-- rolled back with the rest).
CREATE OR REPLACE FUNCTION public.exos_is_admin() RETURNS boolean
  LANGUAGE sql STABLE AS $$ SELECT coalesce(auth.uid() = 'a8000000-0000-0000-0000-0000000000cb'::uuid, false) $$;
INSERT INTO public.exos_orgs(id,name,slug,owner_uid,created_at)
SELECT ('a8000000-0000-0000-0000-0000000020' || lpad(n::text, 2, '0'))::uuid, 'Adm ' || n, 'a8-adm-' || n,
       'a8000000-0000-0000-0000-0000000000cb', now() - interval '1 hour'
  FROM generate_series(1, 20) n;
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000cb', 'a8-admin@x.com');
DO $$
BEGIN
  ASSERT public.exos_create_org('Admin Org', 'a8-admin-org') IS NOT NULL, 'H9: admins are exempt';
  RAISE NOTICE 'OK  H9 org creation cap';
END $$;
RESET ROLE;

-- H10 ------------------------------------------------------------------------
INSERT INTO public.exos_vouchers(id,event_id,code,max_uses)
VALUES ('a8000000-0000-0000-0000-0000000000aa','a8000000-0000-0000-0000-0000000000e1','A8CODE1',5);
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_check_voucher(uuid,text,text)',
                           'public.exos_voucher_discount(uuid,text,text)',
                           'public.exos_voucher_tier(uuid,text,text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'H10: anon can still run ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'H10: signed-in lost ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'H10: service_role lost ' || f;
  END LOOP;
END $$;
SELECT pg_temp.act(NULL, NULL);
SET LOCAL ROLE anon;
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_check_voucher('a8000000-0000-0000-0000-0000000000e1', 'A8CODE1', NULL);
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'H10: anon checking a code is refused';
END $$;
RESET ROLE;
SELECT pg_temp.act('a8000000-0000-0000-0000-0000000000b1', 'a8-fan@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE ok boolean;
BEGIN
  SELECT is_valid INTO ok FROM public.exos_check_voucher('a8000000-0000-0000-0000-0000000000e1', 'a8code1', 'a8-fan@x.com');
  ASSERT ok, 'H10: a signed-in buyer checks a code';
  RAISE NOTICE 'OK  H10 codes need an account';
END $$;
RESET ROLE;

ROLLBACK;
