-- ============================================================================
-- Drop list ("Notify me") + on-sale blast (mig 20261118100000). Self-contained
-- (d70… ids), rolled back.
--   DL0 shape: RLS on, no client grants on the three tables; definer +
--       search_path; anon may call exactly status / signup / confirm /
--       confirm_code / leave; join / leave_mine / summary / export /
--       set_presale signed-in only; blast / sweep / helpers service only
--   DL1 open: a published, upcoming, Exos-sold event whose public sellable
--       types all open later; not a draft, not one on sale, not a link-out
--   DL2 guest signup: the same answer for new, pending, confirmed and
--       throttled; a confirm mail (link + code) only when not on the list;
--       link confirms; the code confirms only from the browser that signed
--       up, 5 wrong tries spend it; a second signup keeps the first link
--   DL3 signed in: one click, confirmed; an unconfirmed account refused; a
--       guest's pending row for the same address joins it (dedupe); texts
--       need a number and store the SQL consent words
--   DL3b SMS pumping: 2 numbers per signup, 60 s apart, 5 code sends a day
--       per account, 5 per number (all accounts and orgs), 300 per org; the
--       same try_again whichever cap, nothing reaches the outbox past one
--   DL3c numbers: no extensions / dial strings, real NANP for +1; only the
--       org's country unless its owner allowed more (audited); accounts new
--       to the org share 100 of its 300 a day; the platform-wide daily cap
--   DL3d +1 numbers by area code: Jamaica / DR refused for a US org until
--       opted in, 900 never, Puerto Rico counts as US; the platform cap
--       stops newcomers only, never an established account
--   DL4 rate limits: 10 a minute per network (then no row, same answer), 3
--       confirm mails a day per address and event
--   DL5 roles: summary owner / manager / finance; content, scanner, an
--       outsider and the other org's owner 42501; export owner / manager
--       only, an export.run row, no phone; no anon read of the tables
--   DL6 presale: hidden type only, at least 10 minutes out; one voucher valid
--       until the public on-sale, the type opened N minutes early, an audit
--       row; the code works for a member (signed in, or the service role
--       with the member's email), never for others or anon; the hold path
--       honours it; turning it off deletes the unused code
--   DL7 blast: nothing before on-sale; then one mail per confirmed member
--       (not pending, not left, not opted out) with the leave link as
--       List-Unsubscribe; a re-run sends nothing; presale kind + code while
--       the presale runs; texts queued in quiet hours with STOP, refused
--       after a STOP, without a provider, at the monthly cap
--   DL8 leave: by token (email + texts) and signed in
--   DL9 sweep: unconfirmed after 30 days, a list 30 days after its event
--   DL10 a bad event time zone falls back (quiet hours still apply) and a
--       failing event is skipped while another org's event still goes out
--   DL11 leaving spends open confirms: an unused link or code (or one made
--       before leaving) never re-joins; a new signup after leaving does
--   DL12 exos_sms_claim: a queued drop_list text to a stopped number, or for
--       a signup that left, is skipped at send time; other audiences as before
-- Users: o owner A, m manager A, f finance A, c content A, s scanner A,
--        b owner B, f1 / f2 / f3 fans (f3 unconfirmed), x outsider.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d7000000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid
$$;
-- Act as a role / user from a network: role, auth.uid(), the JWT role
-- claim and the request IP (cf-connecting-ip).
CREATE FUNCTION pg_temp.as_(p_role text, p_uid uuid DEFAULT NULL, p_ip text DEFAULT '198.51.100.1') RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', p_role, true);
  PERFORM set_config('app.uid', coalesce(p_uid::text, ''), true);
  PERFORM set_config('request.jwt.claims', CASE WHEN p_role IN ('anon', 'authenticated', 'service_role')
                                                THEN jsonb_build_object('role', p_role)::text ELSE '' END, true);
  PERFORM set_config('request.headers', jsonb_build_object('cf-connecting-ip', p_ip)::text, true);
END $$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
CREATE FUNCTION pg_temp.bt(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to('browser-' || p, 'UTF8')), 'hex')
$$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text), pg_temp.as_(text, uuid, text), pg_temp.st(text), pg_temp.bt(text)
  TO anon, authenticated, service_role;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'd70-o@x.com', now()), (pg_temp.u('a2'), 'd70-m@x.com', now()),
  (pg_temp.u('a3'), 'd70-f@x.com', now()), (pg_temp.u('a4'), 'd70-c@x.com', now()),
  (pg_temp.u('a5'), 'd70-s@x.com', now()), (pg_temp.u('a6'), 'd70-b@x.com', now()),
  (pg_temp.u('b1'), 'd70-fan1@x.com', now()), (pg_temp.u('b2'), 'd70-fan2@x.com', now()),
  (pg_temp.u('b3'), 'd70-fan3@x.com', NULL), (pg_temp.u('b4'), 'd70-x@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'D70 Hall', 'd70-hall', pg_temp.u('a1')),
  (pg_temp.u('2'), 'D70 Elsewhere', 'd70-elsewhere', pg_temp.u('a6'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('a1'), 'owner'), (pg_temp.u('1'), pg_temp.u('a2'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('a3'), 'finance'), (pg_temp.u('1'), pg_temp.u('a4'), 'content'),
  (pg_temp.u('1'), pg_temp.u('a5'), 'scanner'), (pg_temp.u('2'), pg_temp.u('a6'), 'owner');
-- e1: announced, GA opens in 2 hours, a hidden "List presale" type.
-- e2: on sale (GA has no start). e3: a draft. e4: sold on Eventbrite. e9: org B's.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by, link_out) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'D70 Drop', 'd70-drop', 'published', now() + interval '30 days', 'America/New_York', 500, pg_temp.u('a1'), false),
  (pg_temp.u('e2'), pg_temp.u('1'), 'D70 On Sale', 'd70-on-sale', 'published', now() + interval '30 days', 'America/New_York', 500, pg_temp.u('a1'), false),
  (pg_temp.u('e3'), pg_temp.u('1'), 'D70 Draft', 'd70-draft', 'draft', now() + interval '30 days', 'America/New_York', 500, pg_temp.u('a1'), false),
  (pg_temp.u('e9'), pg_temp.u('2'), 'D70 Secret Gala', 'd70-secret', 'published', now() + interval '30 days', 'America/New_York', 500, pg_temp.u('a6'), false);
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by, link_out,
                                ticket_backend, external_ticket_url) VALUES
  (pg_temp.u('e4'), pg_temp.u('1'), 'D70 Linked', 'd70-linked', 'published', now() + interval '30 days', 'America/New_York', 500,
   pg_temp.u('a1'), false, 'eventbrite', 'https://www.eventbrite.com/e/1');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sales_start, visibility) VALUES
  (pg_temp.u('c1'), pg_temp.u('e1'), 'GA', 20, 100, now() + interval '2 hours', 'public'),
  (pg_temp.u('c2'), pg_temp.u('e1'), 'List presale', 20, 50, NULL, 'hidden'),
  (pg_temp.u('c3'), pg_temp.u('e1'), 'Closed', 20, 0, NULL, 'public'),
  (pg_temp.u('c4'), pg_temp.u('e2'), 'GA', 20, 100, NULL, 'public'),
  (pg_temp.u('c5'), pg_temp.u('e3'), 'GA', 20, 100, now() + interval '2 hours', 'public'),
  (pg_temp.u('c6'), pg_temp.u('e4'), 'GA', 20, 100, now() + interval '2 hours', 'public'),
  (pg_temp.u('c9'), pg_temp.u('e9'), 'GA', 20, 100, now() + interval '2 hours', 'public');

-- DL0 -----------------------------------------------------------------------
DO $$
DECLARE r record; v_anon text[]; v_auth text[]; v_svc text[];
BEGIN
  FOR r IN SELECT c.relname, c.relrowsecurity FROM pg_class c
            WHERE c.relname IN ('exos_drop_signups', 'exos_drop_confirms', 'exos_drop_settings', 'exos_drop_sms_codes',
                                'exos_drop_leave_tokens', 'exos_drop_sms_countries') LOOP
    ASSERT r.relrowsecurity, 'DL0 RLS on ' || r.relname;
    ASSERT NOT has_table_privilege('anon', 'public.' || r.relname, 'SELECT')
       AND NOT has_table_privilege('authenticated', 'public.' || r.relname, 'SELECT')
       AND NOT has_table_privilege('authenticated', 'public.' || r.relname, 'INSERT'), 'DL0 no client grants ' || r.relname;
  END LOOP;
  FOR r IN SELECT p.oid, p.proname, p.prosecdef, p.proconfig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.proname ~ '^_?exos_drop_' LOOP
    IF r.prosecdef THEN
      ASSERT array_to_string(r.proconfig, ',') LIKE '%search_path=public, pg_temp%', 'DL0 search_path ' || r.proname;
    END IF;
    IF has_function_privilege('anon', r.oid, 'EXECUTE') THEN v_anon := v_anon || r.proname::text; END IF;
    IF has_function_privilege('authenticated', r.oid, 'EXECUTE') THEN v_auth := v_auth || r.proname::text; END IF;
    IF has_function_privilege('service_role', r.oid, 'EXECUTE') THEN v_svc := v_svc || r.proname::text; END IF;
  END LOOP;
  ASSERT (SELECT array_agg(x ORDER BY x) FROM unnest(v_anon) x) = ARRAY['exos_drop_confirm', 'exos_drop_confirm_code',
    'exos_drop_email_consent_text', 'exos_drop_leave', 'exos_drop_signup', 'exos_drop_sms_consent_text', 'exos_drop_status'],
    'DL0 anon surface: ' || array_to_string(v_anon, ',');
  ASSERT (SELECT array_agg(x ORDER BY x) FROM unnest(v_auth) x) = ARRAY['exos_drop_confirm', 'exos_drop_confirm_code',
    'exos_drop_email_consent_text', 'exos_drop_join', 'exos_drop_leave', 'exos_drop_leave_mine', 'exos_drop_list_export',
    'exos_drop_list_set_presale', 'exos_drop_list_summary', 'exos_drop_set_sms_countries', 'exos_drop_signup',
    'exos_drop_sms_consent_text', 'exos_drop_status', 'exos_drop_verify_sms'],
    'DL0 authenticated surface: ' || array_to_string(v_auth, ',');
  ASSERT 'exos_drop_list_blast' = ANY (v_svc) AND 'exos_drop_list_sweep' = ANY (v_svc), 'DL0 service jobs';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_drop_list_blast(int)', 'EXECUTE'), 'DL0 blast service only';
  ASSERT position('/* exos: drop list code */' in pg_get_functiondef('public.exos_check_voucher(uuid,text,text)'::regprocedure)) > 0,
    'DL0 voucher marker';
  ASSERT position('/* exos: drop list stop */' in pg_get_functiondef('public.exos_sms_claim(integer)'::regprocedure)) > 0,
    'DL0 claim marker';
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'exos_drop_signups' AND column_name = 'leave_token'),
    'DL0 no plain leave token column';
  ASSERT (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'exos_sms_campaigns_audience_check')
         ~ 'staff_report' , 'DL0 audience values kept';
  RAISE NOTICE 'OK  DL0 RLS + no client grants, definer search_path, anon / signed-in / service surfaces, voucher marker';
END $$;

-- DL1 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.as_('anon');
  j := public.exos_drop_status(pg_temp.u('e1'));
  ASSERT (j->>'open')::boolean AND (j->>'on_sale_at')::timestamptz = (SELECT sales_start FROM public.exos_ticket_tiers WHERE id = pg_temp.u('c1'))
     AND NOT (j ? 'joined') AND (j->>'list_presale')::boolean = false
     AND j->>'email_consent_text' = public.exos_drop_email_consent_text('D70 Hall', 'D70 Drop')
     AND j->>'sms_consent_text' ~ 'Reply STOP to cancel', 'DL1 e1 open: ' || j::text;
  ASSERT NOT (public.exos_drop_status(pg_temp.u('e2'))->>'open')::boolean, 'DL1 on sale: closed';
  ASSERT public.exos_drop_status(pg_temp.u('e3')) = '{"open": false}'::jsonb, 'DL1 draft: nothing';
  ASSERT NOT (public.exos_drop_status(pg_temp.u('e4'))->>'open')::boolean, 'DL1 sold elsewhere: closed';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_signup(pg_temp.u('e2'), 'a@b.co', pg_temp.bt('z'))$q$) LIKE 'P0002%', 'DL1 signup on sale refused';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_signup(pg_temp.u('e3'), 'a@b.co', pg_temp.bt('z'))$q$) LIKE 'P0002%', 'DL1 signup draft refused';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_signup(pg_temp.u('e1'), 'not-an-email', pg_temp.bt('z'))$q$) LIKE '22023%', 'DL1 bad email';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_signup(pg_temp.u('e1'), 'a@b.co', 'short')$q$) LIKE '22023%', 'DL1 bad browser token';
  PERFORM pg_temp.as_('postgres');
  RAISE NOTICE 'OK  DL1 open only for an announced, published, Exos-sold event; anon status shows no person';
END $$;

-- DL2 -----------------------------------------------------------------------
DO $$
DECLARE
  j1 jsonb; j2 jsonb; j3 jsonb; j4 jsonb; m record; c2 record; v_tok text; v_code text; v_sid uuid; v_n int; i int;
BEGIN
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.21');
  j1 := public.exos_drop_signup(pg_temp.u('e1'), ' Guest1@X.com ', pg_temp.bt('g1'),
          '{"promoter":"dj_k","utm_source":"instagram","utm_medium":"story","utm_campaign":"drop<1>","evil":"x"}');
  PERFORM pg_temp.as_('postgres');
  SELECT * INTO m FROM public.exos_mail WHERE template = 'drop-confirm' AND to_email = 'guest1@x.com';
  ASSERT m.id IS NOT NULL AND m.payload->>'token' ~ '^[0-9a-f]{64}$' AND m.payload->>'code' ~ '^[0-9]{6}$'
     AND m.payload->'event'->>'id' = pg_temp.u('e1')::text AND m.payload->>'leave_token' ~ '^[0-9a-f]{64}$', 'DL2 confirm mail';
  v_tok := m.payload->>'token'; v_code := m.payload->>'code';
  SELECT id INTO v_sid FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e1') AND email = 'guest1@x.com';
  ASSERT (SELECT confirmed_at IS NULL AND promoter = 'dj_k' AND utm_source = 'instagram' AND utm_campaign = 'drop1'
            AND user_id IS NULL AND email_consent_text = public.exos_drop_email_consent_text('D70 Hall', 'D70 Drop')
            FROM public.exos_drop_signups WHERE id = v_sid), 'DL2 pending row, sanitized source, consent words';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_drop_confirms WHERE signup_id = v_sid AND (token_hash = v_tok OR code_hash = v_code)),
    'DL2 only hashes stored';
  ASSERT EXISTS (SELECT 1 FROM public.exos_drop_leave_tokens WHERE signup_id = v_sid AND token_hash = public._exos_drop_hash(m.payload->>'leave_token'))
     AND NOT EXISTS (SELECT 1 FROM public.exos_drop_leave_tokens WHERE token_hash = m.payload->>'leave_token'),
    'DL2 the leave token is stored hashed';

  -- A second signup (another browser): pending again, same answer, both links live.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.22');
  j2 := public.exos_drop_signup(pg_temp.u('e1'), 'guest1@x.com', pg_temp.bt('g1b'));
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'drop-confirm' AND to_email = 'guest1@x.com') = 2, 'DL2 second mail';
  ASSERT (SELECT count(*) FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e1') AND email = 'guest1@x.com') = 1, 'DL2 one row per address';

  -- The code: wrong browser, wrong code (5 spend it), right code.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.23');
  ASSERT NOT (public.exos_drop_confirm_code(pg_temp.u('e1'), pg_temp.bt('other'), v_code)->>'ok')::boolean, 'DL2 code needs the browser';
  ASSERT NOT (public.exos_drop_confirm_code(pg_temp.u('e9'), pg_temp.bt('g1'), v_code)->>'ok')::boolean, 'DL2 code is per event';
  ASSERT NOT (public.exos_drop_confirm_code(pg_temp.u('e1'), pg_temp.bt('g1'), CASE WHEN v_code = '000000' THEN '000001' ELSE '000000' END)->>'ok')::boolean,
    'DL2 wrong code';
  ASSERT public.exos_drop_confirm_code(pg_temp.u('e1'), pg_temp.bt('g1'), v_code) = '{"ok": true}'::jsonb, 'DL2 right code';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT confirmed_at IS NOT NULL FROM public.exos_drop_signups WHERE id = v_sid), 'DL2 confirmed by code';

  -- Already on the list: the same answer, no mail.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.24');
  j3 := public.exos_drop_signup(pg_temp.u('e1'), 'guest1@x.com', pg_temp.bt('g1c'));
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'drop-confirm' AND to_email = 'guest1@x.com') = 2, 'DL2 no mail when on the list';
  ASSERT j1 = j2 AND j2 = j3 AND j1 = '{"ok": true, "status": "check_email"}'::jsonb, 'DL2 constant answer';

  -- Guest 2 confirms by link (twice: idempotent); the code can't be guessed 5 times.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.25');
  j4 := public.exos_drop_signup(pg_temp.u('e1'), 'guest2@x.com', pg_temp.bt('g2'), '{"utm_source":"tiktok"}');
  PERFORM pg_temp.as_('postgres');
  SELECT payload->>'token' AS t, payload->>'code' AS c INTO c2 FROM public.exos_mail WHERE template = 'drop-confirm' AND to_email = 'guest2@x.com';
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.26');
  FOR i IN 1..5 LOOP
    PERFORM public.exos_drop_confirm_code(pg_temp.u('e1'), pg_temp.bt('g2'), CASE WHEN c2.c = '111111' THEN '222222' ELSE '111111' END);
  END LOOP;
  ASSERT NOT (public.exos_drop_confirm_code(pg_temp.u('e1'), pg_temp.bt('g2'), c2.c)->>'ok')::boolean, 'DL2 5 wrong tries spend the code';
  j4 := public.exos_drop_confirm(c2.t);
  ASSERT (j4->>'ok')::boolean AND j4->>'event_name' = 'D70 Drop' AND j4->>'org_name' = 'D70 Hall' AND NOT (j4 ? 'email'), 'DL2 link: ' || j4::text;
  ASSERT public.exos_drop_confirm(c2.t) = j4, 'DL2 link twice';
  ASSERT public.exos_drop_confirm(repeat('0', 64)) = '{"ok": false}'::jsonb AND public.exos_drop_confirm('x') = '{"ok": false}'::jsonb, 'DL2 bad links';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT confirmed_at IS NOT NULL FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e1') AND email = 'guest2@x.com'), 'DL2 confirmed by link';

  -- Guest 3 stays pending.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.27');
  PERFORM public.exos_drop_signup(pg_temp.u('e1'), 'guest3@x.com', pg_temp.bt('g3'));
  PERFORM pg_temp.as_('postgres');
  RAISE NOTICE 'OK  DL2 guest signup: constant answer, link or browser-bound code, 5 tries, no mail when listed, hashes only';
END $$;

-- DL3 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_code text;
BEGIN
  -- fan3's email isn't confirmed: refused (the guest form is their path).
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b3'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('e1'))$q$) LIKE '42501%confirm your email%', 'DL3 unconfirmed refused';
  PERFORM pg_temp.as_('anon');
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('e1'))$q$) LIKE '42501%', 'DL3 anon refused';

  -- fan1 had a pending guest row under the same address: one click joins it.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.31');
  PERFORM public.exos_drop_signup(pg_temp.u('e1'), 'd70-fan1@x.com', pg_temp.bt('f1'));
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  ASSERT (public.exos_drop_status(pg_temp.u('e1'))->>'joined')::boolean = false, 'DL3 pending is not joined';
  j := public.exos_drop_join(pg_temp.u('e1'), false, NULL, '{"promoter":"later"}');
  ASSERT (j->>'joined')::boolean AND NOT (j->>'sms')::boolean, 'DL3 one click: ' || j::text;
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('e1'), true, '12')$q$) LIKE '22023%', 'DL3 texts need a number';
  j := public.exos_drop_join(pg_temp.u('e1'), true, '(212) 555-0101');
  ASSERT NOT (j->>'sms')::boolean AND (j->>'sms_pending')::boolean AND j->>'pending_hint' = '…0101', 'DL3 texts wait for the code: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  -- Not consented yet: no number, no words; the code went by text.
  ASSERT (SELECT sms_phone IS NULL AND sms_consent_text IS NULL AND sms_consented_at IS NULL
            FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e1') AND email = 'd70-fan1@x.com'), 'DL3 unverified number never stored';
  v_code := (SELECT substring(o.body FROM '^[0-9]{6}') FROM public.exos_rsvp_sms_outbox o WHERE o.phone = '+12125550101' ORDER BY created_at DESC LIMIT 1);
  ASSERT v_code IS NOT NULL, 'DL3 code texted through the outbox';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b4'));
  ASSERT NOT (public.exos_drop_verify_sms(pg_temp.u('e1'), v_code)->>'verified')::boolean, 'DL3 someone else can''t use the code';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  j := public.exos_drop_verify_sms(pg_temp.u('e1'), CASE WHEN v_code = '000000' THEN '000001' ELSE '000000' END);
  ASSERT NOT (j->>'verified')::boolean AND NOT (j->>'sms')::boolean, 'DL3 wrong code';
  j := public.exos_drop_verify_sms(pg_temp.u('e1'), v_code);
  ASSERT (j->>'verified')::boolean AND (j->>'sms')::boolean AND j->>'phone_hint' = '…0101', 'DL3 texts on after the code: ' || j::text;
  -- An outsider signs up a stranger's number: it is never consented.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b4'));
  PERFORM public.exos_drop_join(pg_temp.u('e1'), true, '+12125550177');
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT sms_phone IS NULL AND sms_pending_phone = '+12125550177' FROM public.exos_drop_signups
           WHERE event_id = pg_temp.u('e1') AND email = 'd70-x@x.com'), 'DL3 a stranger''s number stays unverified';
  -- A number that replied STOP gets no code at all (same answer).
  INSERT INTO public.exos_sms_stops (org_id, phone, stopped_at) VALUES (pg_temp.u('1'), '+12125550178', now() - interval '2 days');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a6'));
  j := public.exos_drop_join(pg_temp.u('e1'), true, '+12125550178');
  PERFORM pg_temp.as_('postgres');
  ASSERT (j->>'sms_pending')::boolean AND NOT EXISTS (SELECT 1 FROM public.exos_rsvp_sms_outbox WHERE phone = '+12125550178'),
    'DL3 no code to a stopped number';
  UPDATE public.exos_drop_signups SET left_at = now() WHERE email IN ('d70-x@x.com', 'd70-b@x.com') AND event_id = pg_temp.u('e1');
  -- Leave, then re-join with the same proved number: a new code, texts back on after it.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  PERFORM public.exos_drop_leave_mine(pg_temp.u('e1'));
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_signups SET sms_code_at = now() - interval '2 minutes' WHERE email = 'd70-fan1@x.com' AND event_id = pg_temp.u('e1');
  UPDATE public.exos_rsvp_sms_outbox SET created_at = now() - interval '20 minutes' WHERE phone = '+12125550101';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  j := public.exos_drop_join(pg_temp.u('e1'), true, '+12125550101');
  ASSERT j->>'sms_code' = 'sent' AND (j->>'sms_pending')::boolean AND NOT (j->>'sms')::boolean, 'DL3 re-join gets a code: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  v_code := (SELECT substring(o.body FROM '^[0-9]{6}') FROM public.exos_rsvp_sms_outbox o WHERE o.phone = '+12125550101'
              ORDER BY created_at DESC LIMIT 1);
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  ASSERT (public.exos_drop_verify_sms(pg_temp.u('e1'), v_code)->>'sms')::boolean, 'DL3 texts back on after re-joining';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e1') AND email = 'd70-fan1@x.com') = 1, 'DL3 dedupe';
  ASSERT (SELECT user_id = pg_temp.u('b1') AND confirmed_at IS NOT NULL AND sms_phone = '+12125550101'
            AND sms_consent_text = public.exos_drop_sms_consent_text('D70 Hall', 'D70 Drop') AND sms_consent_text ~* 'reply stop'
            AND promoter IS NULL   -- first touch kept
            FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e1') AND email = 'd70-fan1@x.com'), 'DL3 row';
  -- fan2 joins with texts too; another org's event is its own list.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'));
  PERFORM public.exos_drop_join(pg_temp.u('e1'), true, '+12125550102');
  PERFORM pg_temp.as_('postgres');
  v_code := (SELECT substring(o.body FROM '^[0-9]{6}') FROM public.exos_rsvp_sms_outbox o WHERE o.phone = '+12125550102' ORDER BY created_at DESC LIMIT 1);
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'));
  ASSERT (public.exos_drop_verify_sms(pg_temp.u('e1'), v_code)->>'verified')::boolean, 'DL3 fan2 verified';
  PERFORM public.exos_drop_join(pg_temp.u('e9'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('e2'))$q$) LIKE 'P0002%', 'DL3 on-sale event refused';
  PERFORM pg_temp.as_('postgres');
  RAISE NOTICE 'OK  DL3 signed in: one click, confirmed email required, dedupe with the guest row, texts only for a number proved by a texted code';
END $$;

-- DL3b: SMS pumping caps on the texted code ---------------------------------
DO $$
DECLARE j jsonb; t text[] := '{}'; i int;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
    (pg_temp.u('d1'), 'd70-d1@x.com', now()), (pg_temp.u('d2'), 'd70-d2@x.com', now()),
    (pg_temp.u('d3'), 'd70-d3@x.com', now()), (pg_temp.u('d4'), 'd70-d4@x.com', now()),
    (pg_temp.u('d5'), 'd70-d5@x.com', now());
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
    (pg_temp.u('91'), pg_temp.u('1'), 'D70 G1', 'd70-g1', 'published', now() + interval '30 days', 'America/New_York', 100, pg_temp.u('a1')),
    (pg_temp.u('92'), pg_temp.u('1'), 'D70 G2', 'd70-g2', 'published', now() + interval '30 days', 'America/New_York', 100, pg_temp.u('a1')),
    (pg_temp.u('93'), pg_temp.u('1'), 'D70 G3', 'd70-g3', 'published', now() + interval '30 days', 'America/New_York', 100, pg_temp.u('a1')),
    (pg_temp.u('94'), pg_temp.u('2'), 'D70 G4', 'd70-g4', 'published', now() + interval '30 days', 'America/New_York', 100, pg_temp.u('a6'));
  INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity, sales_start)
  SELECT x, 'GA', 20, 100, now() + interval '2 days' FROM unnest(ARRAY[pg_temp.u('91'), pg_temp.u('92'), pg_temp.u('93'), pg_temp.u('94')]) x;

  -- Per signup: 2 different numbers (the second replaces the first), not 3.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d1'));
  ASSERT public.exos_drop_join(pg_temp.u('91'), true, '+12125550301')->>'sms_code' = 'sent', 'DL3b first number';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '+12125550399')$q$) = 'ok', 'DL3b call';
  ASSERT public.exos_drop_join(pg_temp.u('91'), true, '+12125550398')->>'sms_code' = 'try_again', 'DL3b 60 s apart';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_signups SET sms_code_at = now() - interval '2 minutes' WHERE user_id = pg_temp.u('d1');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d1'));
  j := public.exos_drop_join(pg_temp.u('91'), true, '+12125550302');
  ASSERT j->>'sms_code' = 'sent' AND j->>'pending_hint' = '…0302', 'DL3b the second number replaces the first: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_signups SET sms_code_at = now() - interval '2 minutes' WHERE user_id = pg_temp.u('d1');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d1'));
  j := public.exos_drop_join(pg_temp.u('91'), true, '+12125550303');
  t := t || (j->>'sms_code');
  ASSERT j->>'sms_code' = 'try_again' AND j->>'pending_hint' = '…0302', 'DL3b no third number: ' || j::text;

  -- Per account: 5 code sends a day, over actual sends, across events.
  ASSERT public.exos_drop_join(pg_temp.u('92'), true, '+12125550304')->>'sms_code' = 'sent', 'DL3b send 3';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_signups SET sms_code_at = now() - interval '2 minutes' WHERE user_id = pg_temp.u('d1');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d1'));
  ASSERT public.exos_drop_join(pg_temp.u('92'), true, '+12125550305')->>'sms_code' = 'sent', 'DL3b send 4';
  ASSERT public.exos_drop_join(pg_temp.u('93'), true, '+12125550306')->>'sms_code' = 'sent', 'DL3b send 5';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_signups SET sms_code_at = now() - interval '2 minutes' WHERE user_id = pg_temp.u('d1');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d1'));
  j := public.exos_drop_join(pg_temp.u('93'), true, '+12125550307');
  t := t || (j->>'sms_code');
  PERFORM pg_temp.as_('postgres');
  ASSERT j->>'sms_code' = 'try_again', 'DL3b account cap';
  ASSERT (SELECT count(*) FROM public.exos_drop_sms_codes WHERE user_id = pg_temp.u('d1')) = 5
     AND NOT EXISTS (SELECT 1 FROM public.exos_rsvp_sms_outbox WHERE phone IN ('+12125550303', '+12125550307')), 'DL3b 5 sends, nothing past the cap';

  -- Per number: 5 a day across accounts and orgs (4 earlier sends logged).
  INSERT INTO public.exos_drop_sms_codes (user_id, org_id, phone, created_at)
  SELECT pg_temp.u('d5'), pg_temp.u('2'), '+12125550310', now() - interval '3 hours' FROM generate_series(1, 4);
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d3'));
  ASSERT public.exos_drop_join(pg_temp.u('91'), true, '+12125550310')->>'sms_code' = 'sent', 'DL3b number send 5';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d4'));
  j := public.exos_drop_join(pg_temp.u('92'), true, '+12125550310');
  t := t || (j->>'sms_code');
  ASSERT j->>'sms_code' = 'try_again', 'DL3b number cap across accounts';

  -- Per org: 300 a day (another org unaffected).
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_drop_sms_codes (user_id, org_id, phone, created_at)
  SELECT pg_temp.u('d5'), pg_temp.u('1'), '+1212555' || lpad(g::text, 4, '0'), now() - interval '3 hours' FROM generate_series(4000, 4299) g;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d2'));
  j := public.exos_drop_join(pg_temp.u('93'), true, '+12125550320');
  t := t || (j->>'sms_code');
  ASSERT j->>'sms_code' = 'try_again', 'DL3b org cap';
  ASSERT public.exos_drop_join(pg_temp.u('94'), true, '+12125550321')->>'sms_code' = 'sent', 'DL3b another org unaffected';
  PERFORM pg_temp.as_('postgres');
  -- 10 wrong codes for a number in a day (across signups) stop new codes to it.
  INSERT INTO public.exos_drop_sms_codes (user_id, org_id, phone, fails, created_at)
  VALUES (pg_temp.u('d5'), pg_temp.u('2'), '+12125550330', 9, now() - interval '3 hours');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d3'));
  ASSERT public.exos_drop_join(pg_temp.u('94'), true, '+12125550330')->>'sms_code' = 'sent', 'DL3b code after 9 fails';
  ASSERT NOT (public.exos_drop_verify_sms(pg_temp.u('94'), '000000')->>'verified')::boolean
      OR NOT (public.exos_drop_verify_sms(pg_temp.u('94'), '000001')->>'verified')::boolean, 'DL3b a wrong code';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT sum(fails) FROM public.exos_drop_sms_codes WHERE phone = '+12125550330') >= 10, 'DL3b failed verifies counted per number';
  UPDATE public.exos_drop_signups SET sms_code_at = now() - interval '2 minutes' WHERE user_id = pg_temp.u('d4');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d4'));
  j := public.exos_drop_join(pg_temp.u('94'), true, '+12125550330');
  t := t || (j->>'sms_code');
  PERFORM pg_temp.as_('postgres');
  ASSERT j->>'sms_code' = 'try_again', 'DL3b 10 wrong codes stop new codes to the number';
  ASSERT t = ARRAY['try_again', 'try_again', 'try_again', 'try_again', 'try_again'], 'DL3b one answer whichever cap';
  DELETE FROM public.exos_drop_sms_codes WHERE user_id = pg_temp.u('d5');
  RAISE NOTICE 'OK  DL3b SMS code caps: 2 numbers per signup, 60 s, 5 a day per account, 5 per number, 10 wrong codes per number, 300 per org; one try_again';
END $$;

-- DL3c: number format, country, newcomer sub-cap, platform cap -------------
DO $$
DECLARE j jsonb; a text[];
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
    (pg_temp.u('d6'), 'd70-d6@x.com', now()), (pg_temp.u('d7'), 'd70-d7@x.com', now());
  -- Formats: extensions and dial strings refused, +1 must be NANP; the shared normalizer is unchanged.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d6'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '212 555 9911 ext 7')$q$) LIKE '22023%no extension%', 'DL3c ext';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '212x5559911')$q$) LIKE '22023%', 'DL3c x';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '212-555-9911#')$q$) LIKE '22023%', 'DL3c #';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '2125559911;7')$q$) LIKE '22023%', 'DL3c ;';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '212 555 9911, 7')$q$) LIKE '22023%', 'DL3c ,';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '+1 112 555 0000')$q$) LIKE '22023%', 'DL3c +1 must be NANP';
  PERFORM pg_temp.as_('postgres');
  ASSERT public.exos_sms_normalize_phone('+1 112 555 0000') = '+11125550000', 'DL3c exos_sms_normalize_phone unchanged';

  -- Another country: refused before anything is logged or sent.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d6'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '+44 7700 900123')$q$) = '22023 exos_drop_join: texts aren''t available for this number',
    'DL3c off-country refused';
  PERFORM pg_temp.as_('postgres');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_drop_sms_codes WHERE phone = '+447700900123')
     AND NOT EXISTS (SELECT 1 FROM public.exos_rsvp_sms_outbox WHERE phone = '+447700900123'), 'DL3c nothing logged or sent';
  -- The owner allows GB (audited); a manager can't; unknown codes refused.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a2'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_set_sms_countries(pg_temp.u('1'), ARRAY['GB'])$q$) LIKE '42501%', 'DL3c manager refused';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_set_sms_countries(pg_temp.u('1'), ARRAY['XX'])$q$) LIKE '22023%', 'DL3c unknown country';
  a := public.exos_drop_set_sms_countries(pg_temp.u('1'), ARRAY[' gb ', 'GB']);
  ASSERT a = ARRAY['GB'], 'DL3c allowlist: ' || a::text;
  PERFORM pg_temp.as_('postgres');
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'drop_list.sms_countries_set'
                   AND actor_uid = pg_temp.u('a1') AND changes->'sms_countries'->>1 = 'GB'), 'DL3c audited';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d6'));
  ASSERT public.exos_drop_join(pg_temp.u('91'), true, '+44 7700 900123')->>'sms_code' = 'sent', 'DL3c allowlisted country works';
  -- Another org (B, US) still refuses GB.
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('94'), true, '+44 7700 900124')$q$) LIKE '22023%aren''t available%', 'DL3c per org';

  -- Accounts new to the org share 100 a day; an established one (a proved number with the org) still gets a code.
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT newcomer FROM public.exos_drop_sms_codes WHERE phone = '+447700900123'), 'DL3c a new account''s send is marked';
  INSERT INTO public.exos_drop_sms_codes (user_id, org_id, phone, newcomer, created_at)
  SELECT pg_temp.u('d5'), pg_temp.u('1'), '+1212555' || lpad(g::text, 4, '0'), true, now() - interval '3 hours' FROM generate_series(5000, 5099) g;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d7'));
  ASSERT public.exos_drop_join(pg_temp.u('91'), true, '+12125550340')->>'sms_code' = 'try_again', 'DL3c newcomer sub-cap';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  ASSERT public.exos_drop_join(pg_temp.u('92'), true, '+12125550341')->>'sms_code' = 'sent', 'DL3c established account unaffected';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT NOT newcomer FROM public.exos_drop_sms_codes WHERE phone = '+12125550341'), 'DL3c established send not marked';

  -- The platform-wide daily cap (a setting).
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('drop_sms_codes_daily_cap', '1'::jsonb)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d7'));
  ASSERT public.exos_drop_join(pg_temp.u('94'), true, '+12125550342')->>'sms_code' = 'try_again', 'DL3c platform cap';
  PERFORM pg_temp.as_('postgres');
  DELETE FROM public.exos_platform_settings WHERE key = 'drop_sms_codes_daily_cap';
  DELETE FROM public.exos_drop_sms_codes WHERE user_id = pg_temp.u('d5');
  RAISE NOTICE 'OK  DL3c numbers: no ext / dial strings, NANP for +1, org country unless the owner allows more (audited), newcomer sub-cap, platform cap';
END $$;

-- DL3d: NANP countries by area code; the platform cap spares established accounts
DO $$
DECLARE a text[];
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
    (pg_temp.u('d8'), 'd70-d8@x.com', now()), (pg_temp.u('d9'), 'd70-d9@x.com', now());
  ASSERT public._exos_drop_nanp_iso('+18765550100') = 'JM' AND public._exos_drop_nanp_iso('+18095550100') = 'DO'
     AND public._exos_drop_nanp_iso('+17875550100') IS NULL AND public._exos_drop_nanp_iso('+12125550100') IS NULL, 'DL3d area codes';
  -- A US org: Jamaica (876), the Dominican Republic (809) and 900 refused; Puerto Rico (787) is US.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d8'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '+1 876 555 0100')$q$) LIKE '22023%aren''t available%', 'DL3d JM refused';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '+1 809 555 0100')$q$) LIKE '22023%aren''t available%', 'DL3d DO refused';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('91'), true, '+1 900 555 0100')$q$) LIKE '22023%aren''t available%', 'DL3d 900 refused';
  ASSERT public.exos_drop_join(pg_temp.u('92'), true, '+1 787 555 0100')->>'sms_code' = 'sent', 'DL3d PR is US';
  PERFORM pg_temp.as_('postgres');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_drop_sms_codes WHERE phone IN ('+18765550100', '+18095550100', '+19005550100')), 'DL3d nothing logged';
  -- The owner opts into JM: Jamaica works, the Dominican Republic and 900 still don't.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  a := public.exos_drop_set_sms_countries(pg_temp.u('1'), ARRAY['GB', 'JM']);
  ASSERT a = ARRAY['GB', 'JM'], 'DL3d allowlist ' || a::text;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d8'));
  ASSERT public.exos_drop_join(pg_temp.u('91'), true, '+1 876 555 0100')->>'sms_code' = 'sent', 'DL3d JM after the opt-in';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('93'), true, '+1 809 555 0100')$q$) LIKE '22023%', 'DL3d DO still refused';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('93'), true, '+1 900 555 0101')$q$) LIKE '22023%', 'DL3d 900 never';
  -- Allowing JM doesn't open the rest of +1 for a GB org (org B allows nothing; a GB-country org allows only +44).
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_orgs SET country = 'GB' WHERE id = pg_temp.u('2');
  ASSERT NOT public._exos_drop_phone_country_ok(pg_temp.u('2'), '+12125550100')
     AND public._exos_drop_phone_country_ok(pg_temp.u('2'), '+447700900125'), 'DL3d a GB org: +44 only';
  UPDATE public.exos_orgs SET country = 'US' WHERE id = pg_temp.u('2');

  -- The platform cap full: a new account waits, an established one (b1) still gets a code.
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('drop_sms_codes_daily_cap', '1'::jsonb)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('d9'));
  ASSERT public.exos_drop_join(pg_temp.u('91'), true, '+12125550350')->>'sms_code' = 'try_again', 'DL3d newcomer stopped by the platform cap';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  ASSERT public.exos_drop_join(pg_temp.u('93'), true, '+12125550351')->>'sms_code' = 'sent', 'DL3d established account not blocked';
  PERFORM pg_temp.as_('postgres');
  DELETE FROM public.exos_platform_settings WHERE key = 'drop_sms_codes_daily_cap';
  RAISE NOTICE 'OK  DL3d +1 by area code (other NANP countries opt-in, 900 never, US territories US); the platform cap only stops newcomers';
END $$;

-- DL4 -----------------------------------------------------------------------
DO $$
DECLARE i int; j jsonb;
BEGIN
  -- One network: the 11th signup in a minute answers the same and stores nothing.
  PERFORM pg_temp.as_('anon', NULL, '203.0.113.9');
  FOR i IN 1..10 LOOP
    PERFORM public.exos_drop_signup(pg_temp.u('e1'), 'burst' || i || '@x.com', pg_temp.bt('b' || i));
  END LOOP;
  j := public.exos_drop_signup(pg_temp.u('e1'), 'burst11@x.com', pg_temp.bt('b11'));
  PERFORM pg_temp.as_('postgres');
  ASSERT j = '{"ok": true, "status": "check_email"}'::jsonb, 'DL4 same answer when throttled';
  ASSERT (SELECT count(*) FROM public.exos_drop_signups WHERE email LIKE 'burst%@x.com') = 10, 'DL4 network limit';
  -- One address: 3 confirm mails a day per event (from different networks).
  FOR i IN 1..4 LOOP
    PERFORM pg_temp.as_('anon', NULL, '192.0.2.' || i);
    PERFORM public.exos_drop_signup(pg_temp.u('e1'), 'thrice@x.com', pg_temp.bt('t' || i));
  END LOOP;
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'drop-confirm' AND to_email = 'thrice@x.com') = 3, 'DL4 3 mails a day';
  -- +tags fold into one address: 5 a minute across "fold+1@" .. "fold+6@".
  FOR i IN 1..6 LOOP
    PERFORM pg_temp.as_('anon', NULL, '192.0.2.' || (10 + i));
    PERFORM public.exos_drop_signup(pg_temp.u('e1'), 'Fold+' || i || '@X.com', pg_temp.bt('fo' || i));
  END LOOP;
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_drop_signups WHERE email_key = 'fold@x.com') = 5, 'DL4 +tags share the address limit';
  -- 10 confirm mails a day per address across events.
  INSERT INTO public.exos_drop_confirms (id, signup_id, org_id, token_hash, code_hash, browser_token_hash)
  SELECT gen_random_uuid(), s.id, s.org_id, md5(random()::text) || md5(random()::text), repeat('0', 64), repeat('0', 64)
    FROM public.exos_drop_signups s, generate_series(1, 5) WHERE s.email_key = 'fold@x.com' AND s.email IN ('fold+1@x.com', 'fold+2@x.com');
  PERFORM pg_temp.as_('anon', NULL, '192.0.2.31');
  j := public.exos_drop_signup(pg_temp.u('e9'), 'fold+9@x.com', pg_temp.bt('fo9'));
  PERFORM pg_temp.as_('postgres');
  ASSERT j = '{"ok": true, "status": "check_email"}'::jsonb
     AND NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'fold+9@x.com'), 'DL4 10 a day per address across lists';
  -- The event's bucket full: a visible "try again" (per event, nothing about an address).
  FOR i IN 1..120 LOOP PERFORM public.exos_rate_hit('drop-ev:' || pg_temp.u('e9')::text, 120); END LOOP;
  PERFORM pg_temp.as_('anon', NULL, '192.0.2.32');
  j := public.exos_drop_signup(pg_temp.u('e9'), 'busy@x.com', pg_temp.bt('busy'));
  PERFORM pg_temp.as_('postgres');
  ASSERT j = '{"ok": false, "status": "try_again"}'::jsonb AND NOT EXISTS (SELECT 1 FROM public.exos_drop_signups WHERE email = 'busy@x.com'),
    'DL4 per-event limit says try again';
  RAISE NOTICE 'OK  DL4 rate limits: network, folded address (+tags), 3 a day per event and 10 across, per-event try_again';
END $$;

-- DL5 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['a1', 'a2', 'a3'] LOOP
    PERFORM pg_temp.as_('authenticated', pg_temp.u(s));
    j := public.exos_drop_list_summary(pg_temp.u('e1'));
    ASSERT (j->>'confirmed')::int = 4 AND (j->>'sms')::int = 2 AND (j->>'open')::boolean
       AND (j->>'pending')::int >= 12 AND NOT j::text ~ '@', 'DL5 summary for ' || s || ': ' || j::text;
    ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'sources') x
                    WHERE x->>'promoter' = 'dj_k' AND (x->>'confirmed')::int = 1), 'DL5 sources';
  END LOOP;
  ASSERT (j->>'can_manage')::boolean = false, 'DL5 finance cannot manage';
  FOREACH s IN ARRAY ARRAY['a4', 'a5', 'a6', 'b4'] LOOP
    PERFORM pg_temp.as_('authenticated', pg_temp.u(s));
    ASSERT pg_temp.st($q$SELECT public.exos_drop_list_summary(pg_temp.u('e1'))$q$) = '42501 exos_drop_list_summary: not authorized', 'DL5 refused ' || s;
    ASSERT pg_temp.st($q$SELECT public.exos_drop_list_export(pg_temp.u('e1'))$q$) LIKE '42501%', 'DL5 export refused ' || s;
  END LOOP;
  -- Another org's owner can't read A, and A's owner can't read B (no echo).
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_summary(pg_temp.u('e9'))$q$) = '42501 exos_drop_list_summary: not authorized', 'DL5 cross-org';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_summary(gen_random_uuid())$q$) = '42501 exos_drop_list_summary: not authorized', 'DL5 unknown event';
  -- Export: finance no; manager yes, audited, no phone.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a3'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_export(pg_temp.u('e1'))$q$) LIKE '42501%', 'DL5 finance no export';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a2'));
  j := public.exos_drop_list_export(pg_temp.u('e1'));
  PERFORM pg_temp.as_('postgres');
  ASSERT (j->>'count')::int = 4 AND NOT j::text ~ '\+1212' AND NOT j::text ~ 'leave' AND NOT j::text ~ 'guest3',
    'DL5 export rows: ' || j::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit a WHERE a.org_id = pg_temp.u('1') AND a.action = 'export.run'
                   AND a.entity_id = 'drop_list' AND a.event_id = pg_temp.u('e1') AND a.actor_uid = pg_temp.u('a2')
                   AND a.changes->'row_count'->>1 = '4'), 'DL5 export.run row';
  -- No anon read of the list.
  PERFORM pg_temp.as_('anon');
  ASSERT pg_temp.st('SELECT count(*) FROM public.exos_drop_signups') LIKE '42501%', 'DL5 anon table read refused';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_summary(pg_temp.u('e1'))$q$) LIKE '42501%', 'DL5 anon summary refused';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  ASSERT pg_temp.st('SELECT count(*) FROM public.exos_drop_signups') LIKE '42501%', 'DL5 fan table read refused';
  PERFORM pg_temp.as_('postgres');
  RAISE NOTICE 'OK  DL5 roles: summary owner / manager / finance, export owner / manager + export.run, others and cross-org 42501, no anon read';
END $$;

-- DL6 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_at timestamptz; v_code text; v record; h uuid;
BEGIN
  v_at := (SELECT sales_start FROM public.exos_ticket_tiers WHERE id = pg_temp.u('c1'));
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a3'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_set_presale(pg_temp.u('e1'), 60, pg_temp.u('c2'))$q$) LIKE '42501%', 'DL6 finance refused';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a6'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_set_presale(pg_temp.u('e1'), 60, pg_temp.u('c2'))$q$) LIKE '42501%', 'DL6 other org refused';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a2'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_set_presale(pg_temp.u('e1'), 60, pg_temp.u('c1'))$q$) LIKE '22023%hidden%', 'DL6 public type refused';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_set_presale(pg_temp.u('e1'), 60, pg_temp.u('c9'))$q$) LIKE '22023%hidden%', 'DL6 other event type refused';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_set_presale(pg_temp.u('e1'), 115, pg_temp.u('c2'))$q$) LIKE '22023%10 minutes%', 'DL6 too late';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_set_presale(pg_temp.u('e1'), 3, pg_temp.u('c2'))$q$) LIKE '22023%', 'DL6 too short';
  j := public.exos_drop_list_set_presale(pg_temp.u('e1'), 60, pg_temp.u('c2'));
  ASSERT j->>'status' = 'set' AND (j->>'minutes')::int = 60 AND j->>'tier_name' = 'List presale' AND j->>'code' ~ '^LIST[0-9A-F]{10}$', 'DL6 set: ' || j::text;
  v_code := j->>'code';
  PERFORM pg_temp.as_('postgres');
  SELECT * INTO v FROM public.exos_vouchers WHERE event_id = pg_temp.u('e1') AND code = v_code;
  ASSERT v.tier_id = pg_temp.u('c2') AND v.valid_until = v_at AND v.max_uses = 50 AND NOT v.bypass_capacity, 'DL6 voucher';
  ASSERT (SELECT sales_start FROM public.exos_ticket_tiers WHERE id = pg_temp.u('c2')) = v_at - interval '60 minutes', 'DL6 type opens early';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit a WHERE a.org_id = pg_temp.u('1') AND a.action = 'drop_list.presale_set'
                   AND a.actor_uid = pg_temp.u('a2') AND a.changes->'presale_minutes'->>1 = '60'), 'DL6 audit';
  PERFORM pg_temp.as_('anon');
  ASSERT (public.exos_drop_status(pg_temp.u('e1'))->>'list_presale')::boolean, 'DL6 page says the list gets a presale';

  -- The code: members yes, everyone else "invalid code".
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  ASSERT (SELECT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), lower(v_code), NULL)), 'DL6 member valid';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b4'));
  ASSERT (SELECT NOT is_valid AND reason = 'invalid code' FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, 'd70-fan1@x.com')),
    'DL6 non-member invalid even passing a member''s email';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b3'));
  ASSERT (SELECT NOT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, NULL)), 'DL6 unconfirmed account invalid';
  PERFORM pg_temp.as_('anon');
  ASSERT pg_temp.st(format('SELECT public.exos_check_voucher(%L, %L, %L)', pg_temp.u('e1'), v_code, 'guest1@x.com')) LIKE '42501%',
    'DL6 anon cannot check codes';
  -- A definer path called by anon (the guest hold) passes a typed email: never a member.
  PERFORM pg_temp.as_('postgres');
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  ASSERT (SELECT NOT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, 'guest1@x.com')), 'DL6 anon-claim invalid';
  PERFORM pg_temp.as_('service_role');
  ASSERT (SELECT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, 'guest1@x.com')), 'DL6 service + member email valid';
  ASSERT (SELECT NOT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, 'guest3@x.com')), 'DL6 service + pending email invalid';
  ASSERT (SELECT NOT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, 'd70-x@x.com')), 'DL6 service + other email invalid';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT NOT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, 'guest1@x.com')), 'DL6 no claims: fails closed';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a3'));
  j := public.exos_drop_list_summary(pg_temp.u('e1'));
  ASSERT j->'presale'->>'status' = 'set' AND NOT (j->'presale' ? 'code'), 'DL6 finance sees no code';
  PERFORM pg_temp.as_('postgres');

  -- The hold path, once the presale window is open (moved into the past).
  UPDATE public.exos_ticket_tiers SET sales_start = now() - interval '1 minute' WHERE id = pg_temp.u('c2');
  PERFORM set_config('app.jwt', '{"email":"d70-fan1@x.com"}', true);
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  h := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('c2'), 1, 600, v_code);
  ASSERT h IS NOT NULL, 'DL6 member holds the presale type';
  PERFORM set_config('app.jwt', '{"email":"d70-x@x.com"}', true);
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b4'));
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, %L)', pg_temp.u('e1'), pg_temp.u('c2'), v_code))
         LIKE '42501%not available%', 'DL6 non-member refused the presale type';
  PERFORM set_config('app.jwt', '', true);
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_ticket_tiers SET sales_start = v_at - interval '60 minutes' WHERE id = pg_temp.u('c2');
  DELETE FROM public.exos_cart_holds WHERE id = h;
  RAISE NOTICE 'OK  DL6 presale: hidden type, one list-only code (members only, signed in or verified email), hold path honours it, audited';
END $$;

-- DL7 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_at timestamptz; m record; c record; v_code text;
BEGIN
  -- Org A texts from a connected Twilio.
  INSERT INTO public.exos_org_integrations (org_id, provider, status) VALUES (pg_temp.u('1'), 'twilio', 'connected');
  -- fan2's number replied STOP a day BEFORE fan2 joined and proved it: an old
  -- STOP still wins (only START clears it).
  INSERT INTO public.exos_sms_stops (org_id, phone, stopped_at) VALUES (pg_temp.u('1'), '+12125550102', now() - interval '1 day');
  -- A member who left, and one whose account opted out of follow-up mail.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.71');
  PERFORM public.exos_drop_signup(pg_temp.u('e1'), 'leaver@x.com', pg_temp.bt('lv'));
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_signups SET confirmed_at = now(), left_at = now() WHERE email = 'leaver@x.com';

  -- Not due: GA opens in 2 hours, the presale in 1.
  ASSERT public.exos_drop_list_blast(500) = '{"mails": 0, "texts": 0}'::jsonb, 'DL7 nothing before the presale';
  ASSERT pg_temp.st('SELECT public.exos_drop_list_set_presale(gen_random_uuid(), 0)') LIKE '42501%', 'DL7 set_presale needs a role';

  -- The presale window opens (shift the on-sale to 30 minutes from now).
  v_at := now() + interval '30 minutes';
  UPDATE public.exos_ticket_tiers SET sales_start = v_at WHERE id = pg_temp.u('c1');
  UPDATE public.exos_drop_settings SET public_on_sale_at = v_at WHERE event_id = pg_temp.u('e1');
  UPDATE public.exos_vouchers SET valid_until = v_at WHERE id = (SELECT presale_voucher_id FROM public.exos_drop_settings WHERE event_id = pg_temp.u('e1'));
  v_code := (SELECT v.code FROM public.exos_vouchers v JOIN public.exos_drop_settings ds ON ds.presale_voucher_id = v.id WHERE ds.event_id = pg_temp.u('e1'));
  -- (One transaction: now() never moves, so the members so far are dated
  -- back to before the presale opened.)
  UPDATE public.exos_drop_signups SET confirmed_at = now() - interval '2 hours'
   WHERE event_id = pg_temp.u('e1') AND confirmed_at IS NOT NULL;
  -- The open presale closes the list, and a late confirm isn't a presale member.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.73');
  ASSERT NOT (public.exos_drop_status(pg_temp.u('e1'))->>'open')::boolean, 'DL7 list closes when the presale opens';
  ASSERT pg_temp.st($q$SELECT public.exos_drop_signup(pg_temp.u('e1'), 'late2@x.com', pg_temp.bt('late2'))$q$) LIKE 'P0002%', 'DL7 no signups in the presale';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_signups SET confirmed_at = now() WHERE email = 'guest3@x.com';
  PERFORM pg_temp.as_('service_role');
  ASSERT (SELECT NOT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, 'guest3@x.com')), 'DL7 confirmed after the presale opened: no code';
  ASSERT (SELECT is_valid FROM public.exos_check_voucher(pg_temp.u('e1'), v_code, 'guest1@x.com')), 'DL7 confirmed before: code works';
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_mail_prefs (user_id, marketing_opt_out) VALUES (pg_temp.u('b2'), true)
  ON CONFLICT (user_id) DO UPDATE SET marketing_opt_out = true;

  j := public.exos_drop_list_blast(500);
  ASSERT j = '{"mails": 3, "texts": 1}'::jsonb, 'DL7 presale blast: ' || j::text;
  ASSERT public.exos_drop_list_blast(500) = '{"mails": 0, "texts": 0}'::jsonb, 'DL7 re-run sends nothing';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'drop-on-sale') = 3, 'DL7 one mail each';
  SELECT * INTO m FROM public.exos_mail WHERE template = 'drop-on-sale' AND to_email = 'guest1@x.com';
  ASSERT m.payload->>'kind' = 'presale' AND m.payload->>'code' = v_code
     AND m.list_unsubscribe = '{{app_url}}/drop/leave?t=' || (m.payload->>'leave_token')
     AND (SELECT blast_leave_hash FROM public.exos_drop_signups WHERE email = 'guest1@x.com') = public._exos_drop_hash(m.payload->>'leave_token'),
    'DL7 presale mail + List-Unsubscribe';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'drop-on-sale' AND to_email IN ('guest3@x.com', 'leaver@x.com', 'd70-fan2@x.com')),
    'DL7 pending, left and opted-out get none';
  ASSERT (SELECT blast_skip FROM public.exos_drop_signups WHERE email = 'd70-fan2@x.com' AND event_id = pg_temp.u('e1')) = 'opted_out', 'DL7 opted out recorded';
  ASSERT (SELECT sms_status FROM public.exos_drop_signups WHERE email = 'd70-fan2@x.com' AND event_id = pg_temp.u('e1')) = 'stopped', 'DL7 an old STOP beats a new join';
  ASSERT (SELECT blasted_at IS NULL FROM public.exos_drop_signups WHERE email = 'guest3@x.com'), 'DL7 the late confirmer waits for the on-sale';
  SELECT o.*, ca.audience, ca.event_id AS ev INTO c FROM public.exos_sms_outbox o JOIN public.exos_sms_campaigns ca ON ca.id = o.campaign_id
   WHERE o.phone = '+12125550101';
  ASSERT c.audience = 'drop_list' AND c.ev = pg_temp.u('e1') AND c.body ~ 'Reply STOP to opt out\.$' AND c.body ~ '^D70 Hall: '
     AND (c.send_after AT TIME ZONE 'America/New_York')::time >= time '09:00'
     AND (c.send_after AT TIME ZONE 'America/New_York')::time < time '20:00', 'DL7 text: ' || c.body || ' at ' || c.send_after;
  ASSERT (c.send_after < v_at AND c.body ~ ('code ' || v_code)) OR (c.send_after >= v_at AND c.body ~ 'on sale now' AND c.body !~ v_code),
    'DL7 a text after the on-sale never carries the expired code';

  -- A late confirmer after the public on-sale gets the plain on-sale mail.
  UPDATE public.exos_ticket_tiers SET sales_start = now() - interval '1 minute' WHERE id = pg_temp.u('c1');
  DELETE FROM public.exos_org_integrations WHERE org_id = pg_temp.u('1');
  UPDATE public.exos_drop_signups SET sms_phone = '+12125550103', sms_consent_text = public.exos_drop_sms_consent_text('D70 Hall', 'D70 Drop'),
         sms_consented_at = now() WHERE email = 'guest3@x.com';
  ASSERT public.exos_drop_list_blast(500) = '{"mails": 1, "texts": 0}'::jsonb, 'DL7 late confirmer';
  ASSERT (SELECT payload->>'kind' = 'on_sale' AND payload->>'code' IS NULL FROM public.exos_mail WHERE template = 'drop-on-sale' AND to_email = 'guest3@x.com'),
    'DL7 plain on-sale after the presale';
  ASSERT (SELECT sms_status FROM public.exos_drop_signups WHERE email = 'guest3@x.com') = 'no_provider', 'DL7 no provider';
  -- The signup closes once the event is on sale.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.72');
  ASSERT pg_temp.st($q$SELECT public.exos_drop_signup(pg_temp.u('e1'), 'late@x.com', pg_temp.bt('late'))$q$) LIKE 'P0002%', 'DL7 closed on sale';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a2'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_list_set_presale(pg_temp.u('e1'), 0)$q$) LIKE '23514%already been notified%', 'DL7 presale frozen after the blast';
  PERFORM pg_temp.as_('postgres');
  RAISE NOTICE 'OK  DL7 blast: once per member, presale code then plain on-sale, skips pending / left / opted out, texts with STOP in quiet hours';
END $$;

-- DL7b: the monthly text cap, and turning the presale off ---------------------
DO $$
DECLARE j jsonb; v_vid uuid; i int; v_camp uuid;
BEGIN
  -- Org B (e9): fan2 joined without texts; give a number that hit the cap.
  INSERT INTO public.exos_org_integrations (org_id, provider, status) VALUES (pg_temp.u('2'), 'telnyx', 'connected');
  UPDATE public.exos_drop_signups SET sms_phone = '+12125550109', sms_consent_text = public.exos_drop_sms_consent_text('D70 Elsewhere', 'D70 Secret Gala'),
         sms_consented_at = now() WHERE event_id = pg_temp.u('e9');
  INSERT INTO public.exos_sms_campaigns (org_id, audience, body, provider) VALUES (pg_temp.u('2'), 'org', 'x', 'telnyx') RETURNING id INTO v_camp;
  FOR i IN 1..8 LOOP
    INSERT INTO public.exos_sms_campaigns (org_id, audience, body, provider) VALUES (pg_temp.u('2'), 'org', 'x', 'telnyx') RETURNING id INTO v_camp;
    INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after, status)
    VALUES (v_camp, pg_temp.u('2'), '+12125550109', 'x', now(), 'sent');
  END LOOP;
  UPDATE public.exos_ticket_tiers SET sales_start = now() - interval '1 minute' WHERE id = pg_temp.u('c9');
  UPDATE public.exos_mail_prefs SET marketing_opt_out = false WHERE user_id = pg_temp.u('b2');
  j := public.exos_drop_list_blast(500);
  ASSERT j = '{"mails": 1, "texts": 0}'::jsonb, 'DL7b e9: ' || j::text;
  ASSERT (SELECT sms_status FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e9')) = 'capped', 'DL7b monthly cap';

  -- Presale off before any blast deletes the unused code (a fresh event).
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
    (pg_temp.u('e5'), pg_temp.u('1'), 'D70 Later', 'd70-later', 'published', now() + interval '40 days', 'America/New_York', 100, pg_temp.u('a1'));
  INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sales_start, visibility) VALUES
    (pg_temp.u('c7'), pg_temp.u('e5'), 'GA', 20, 100, now() + interval '3 days', 'public'),
    (pg_temp.u('c8'), pg_temp.u('e5'), 'Early', 15, 20, NULL, 'hidden');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_drop_list_set_presale(pg_temp.u('e5'), 1440, pg_temp.u('c8'));
  PERFORM pg_temp.as_('postgres');
  v_vid := (SELECT presale_voucher_id FROM public.exos_drop_settings WHERE event_id = pg_temp.u('e5'));
  ASSERT v_vid IS NOT NULL, 'DL7b set';
  -- The public on-sale moves: the presale is stale (no early mail).
  UPDATE public.exos_ticket_tiers SET sales_start = now() + interval '4 days' WHERE id = pg_temp.u('c7');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  ASSERT public.exos_drop_list_summary(pg_temp.u('e5'))->'presale'->>'status' = 'stale', 'DL7b stale after the on-sale moved';
  j := public.exos_drop_list_set_presale(pg_temp.u('e5'), 0);
  PERFORM pg_temp.as_('postgres');
  ASSERT j->>'status' = 'off' AND NOT EXISTS (SELECT 1 FROM public.exos_vouchers WHERE id = v_vid), 'DL7b off deletes the unused code';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE action = 'drop_list.presale_set' AND event_id = pg_temp.u('e5')) = 2, 'DL7b audited twice';
  RAISE NOTICE 'OK  DL7b 8 texts a month per number, a moved on-sale makes the presale stale, off deletes the unused code';
END $$;

-- DL8 -----------------------------------------------------------------------
DO $$
DECLARE v_tok text; j jsonb;
BEGIN
  v_tok := (SELECT payload->>'leave_token' FROM public.exos_mail WHERE template = 'drop-on-sale' AND to_email = 'guest2@x.com');
  ASSERT (SELECT blast_leave_hash = public._exos_drop_hash(v_tok) FROM public.exos_drop_signups WHERE email = 'guest2@x.com'), 'DL8 hashed';
  PERFORM pg_temp.as_('anon');
  j := public.exos_drop_leave(v_tok);
  ASSERT j = jsonb_build_object('ok', true, 'event_name', 'D70 Drop'), 'DL8 leave: ' || j::text;
  ASSERT public.exos_drop_leave(repeat('a', 64)) = '{"ok": false}'::jsonb AND public.exos_drop_leave('nope') = '{"ok": false}'::jsonb, 'DL8 bad token';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  ASSERT public.exos_drop_leave_mine(pg_temp.u('e1')), 'DL8 leave mine';
  ASSERT NOT (public.exos_drop_status(pg_temp.u('e1')) ? 'phone_hint' AND (public.exos_drop_status(pg_temp.u('e1'))->>'sms')::boolean), 'DL8 texts off';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT left_at IS NOT NULL FROM public.exos_drop_signups WHERE email = 'guest2@x.com'), 'DL8 left';
  ASSERT (SELECT left_at IS NOT NULL AND sms_opted_out_at IS NOT NULL FROM public.exos_drop_signups
           WHERE email = 'd70-fan1@x.com' AND event_id = pg_temp.u('e1')), 'DL8 email + texts stop';
  RAISE NOTICE 'OK  DL8 leave by token (anon) and signed in; email and texts both stop';
END $$;

-- DL10 ----------------------------------------------------------------------
DO $$
DECLARE j jsonb; c record;
BEGIN
  -- An organizer-typed zone Postgres doesn't know, and another org's event.
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
    (pg_temp.u('f1'), pg_temp.u('1'), 'D70 Bad Zone', 'd70-bad-zone', 'published', now() + interval '20 days', 'Not/AZone', 100, pg_temp.u('a1')),
    (pg_temp.u('f2'), pg_temp.u('2'), 'D70 Other Org', 'd70-other-org', 'published', now() + interval '20 days', 'America/Chicago', 100, pg_temp.u('a6')),
    (pg_temp.u('f3'), pg_temp.u('1'), 'D70 Boom', 'd70-boom', 'published', now() + interval '20 days', 'America/New_York', 100, pg_temp.u('a1')),
    (pg_temp.u('f4'), pg_temp.u('2'), 'D70 Fine', 'd70-fine', 'published', now() + interval '20 days', 'America/New_York', 100, pg_temp.u('a6'));
  INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity, sales_start)
  SELECT x, 'GA', 20, 100, now() - interval '1 minute' FROM unnest(ARRAY[pg_temp.u('f1'), pg_temp.u('f2'), pg_temp.u('f3'), pg_temp.u('f4')]) x;
  INSERT INTO public.exos_org_integrations (org_id, provider, status) VALUES (pg_temp.u('1'), 'twilio', 'connected')
  ON CONFLICT (org_id, provider) DO UPDATE SET status = 'connected';
  INSERT INTO public.exos_drop_signups (org_id, event_id, email, email_consent_text, confirmed_at, sms_phone, sms_consent_text, sms_consented_at)
  VALUES (pg_temp.u('1'), pg_temp.u('f1'), 'tz1@x.com', public.exos_drop_email_consent_text('D70 Hall', 'D70 Bad Zone'), now(),
          '+12125550188', public.exos_drop_sms_consent_text('D70 Hall', 'D70 Bad Zone'), now()),
         (pg_temp.u('2'), pg_temp.u('f2'), 'tz2@x.com', public.exos_drop_email_consent_text('D70 Elsewhere', 'D70 Other Org'), now(), NULL, NULL, NULL);
  ASSERT public._exos_drop_tz('Not/AZone') = 'America/New_York' AND public._exos_drop_tz('Europe/Berlin') = 'Europe/Berlin', 'DL10 tz helper';
  j := public.exos_drop_list_blast(500);
  ASSERT j = '{"mails": 2, "texts": 1}'::jsonb, 'DL10 bad zone falls back, both orgs mailed: ' || j::text;
  SELECT o.send_after INTO c FROM public.exos_sms_outbox o WHERE o.phone = '+12125550188';
  ASSERT (c.send_after AT TIME ZONE 'America/New_York')::time BETWEEN time '09:00' AND time '20:00', 'DL10 quiet hours in the fallback zone';

  -- One event failing (a trigger stands in for any error) is skipped; the other org's goes out.
  INSERT INTO public.exos_drop_signups (org_id, event_id, email, email_consent_text, confirmed_at) VALUES
    (pg_temp.u('1'), pg_temp.u('f3'), 'boom@x.com', public.exos_drop_email_consent_text('D70 Hall', 'D70 Boom'), now()),
    (pg_temp.u('2'), pg_temp.u('f4'), 'fine@x.com', public.exos_drop_email_consent_text('D70 Elsewhere', 'D70 Fine'), now());
  CREATE FUNCTION public.exos_test_drop_boom() RETURNS trigger LANGUAGE plpgsql AS $f$
  BEGIN RAISE EXCEPTION 'boom'; END $f$;
  EXECUTE format('CREATE TRIGGER exos_test_drop_boom BEFORE UPDATE ON public.exos_drop_signups FOR EACH ROW WHEN (NEW.event_id = %L) EXECUTE FUNCTION public.exos_test_drop_boom()', pg_temp.u('f3'));
  j := public.exos_drop_list_blast(500);
  ASSERT j = '{"mails": 1, "texts": 0, "failed_events": 1}'::jsonb, 'DL10 one event isolated: ' || j::text;
  ASSERT (SELECT blasted_at IS NULL FROM public.exos_drop_signups WHERE email = 'boom@x.com')
     AND (SELECT blasted_at IS NOT NULL FROM public.exos_drop_signups WHERE email = 'fine@x.com')
     AND NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'boom@x.com'), 'DL10 the failed event rolled back alone';
  DROP TRIGGER exos_test_drop_boom ON public.exos_drop_signups;
  DROP FUNCTION public.exos_test_drop_boom();
  ASSERT public.exos_drop_list_blast(500) = '{"mails": 1, "texts": 0}'::jsonb, 'DL10 retried next run';
  RAISE NOTICE 'OK  DL10 an unknown zone falls back (quiet hours kept); a failing event is skipped, other orgs still go out, retried next run';
END $$;

-- DL11 ----------------------------------------------------------------------
DO $$
DECLARE c1 record; c2 record; c3 record; c4 record; j jsonb;
BEGIN
  -- Pending guest leaves by the confirm mail's link: that link and code are spent.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.111');
  PERFORM public.exos_drop_signup(pg_temp.u('e5'), 'lv2@x.com', pg_temp.bt('lv2'));
  PERFORM pg_temp.as_('postgres');
  SELECT payload->>'token' AS t, payload->>'code' AS c, payload->>'leave_token' AS l INTO c1
    FROM public.exos_mail WHERE template = 'drop-confirm' AND to_email = 'lv2@x.com';
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.112');
  ASSERT (public.exos_drop_leave(c1.l)->>'ok')::boolean, 'DL11 leave';
  ASSERT public.exos_drop_confirm(c1.t) = '{"ok": false}'::jsonb, 'DL11 link spent by leaving';
  ASSERT public.exos_drop_confirm_code(pg_temp.u('e5'), pg_temp.bt('lv2'), c1.c) = '{"ok": false}'::jsonb, 'DL11 code spent by leaving';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT left_at IS NOT NULL AND confirmed_at IS NULL FROM public.exos_drop_signups WHERE email = 'lv2@x.com'), 'DL11 still off';

  -- A member with two mails confirms by one, leaves; the other (older than
  -- the leave) can't bring them back, and the used one now answers false.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.113');
  PERFORM public.exos_drop_signup(pg_temp.u('e5'), 'lv3@x.com', pg_temp.bt('lv3a'));
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.114');
  PERFORM public.exos_drop_signup(pg_temp.u('e5'), 'lv3@x.com', pg_temp.bt('lv3b'));
  PERFORM pg_temp.as_('postgres');
  SELECT payload->>'token' AS t, payload->>'leave_token' AS l INTO c2 FROM public.exos_mail
   WHERE template = 'drop-confirm' AND to_email = 'lv3@x.com' ORDER BY created_at, id LIMIT 1;
  SELECT payload->>'token' AS t, payload->>'code' AS c INTO c3 FROM public.exos_mail
   WHERE template = 'drop-confirm' AND to_email = 'lv3@x.com' AND payload->>'token' <> c2.t;
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.115');
  ASSERT (public.exos_drop_confirm(c2.t)->>'ok')::boolean, 'DL11 confirmed';
  ASSERT (public.exos_drop_leave(c2.l)->>'ok')::boolean, 'DL11 left';
  ASSERT public.exos_drop_confirm(c3.t) = '{"ok": false}'::jsonb, 'DL11 the other link can''t re-join';
  ASSERT public.exos_drop_confirm(c2.t) = '{"ok": false}'::jsonb, 'DL11 the used link answers false once left';
  PERFORM pg_temp.as_('postgres');
  -- A confirm row made before the leave but somehow unspent is refused too.
  UPDATE public.exos_drop_confirms SET used_at = NULL, created_at = now() - interval '1 hour'
   WHERE token_hash = public._exos_drop_hash(c3.t);
  UPDATE public.exos_drop_signups SET left_at = now() - interval '1 minute' WHERE email = 'lv3@x.com';
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.116');
  ASSERT public.exos_drop_confirm(c3.t) = '{"ok": false}'::jsonb, 'DL11 a confirm older than the leave is refused';
  -- A new signup after leaving works.
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.117');
  PERFORM public.exos_drop_signup(pg_temp.u('e5'), 'lv3@x.com', pg_temp.bt('lv3c'));
  PERFORM pg_temp.as_('postgres');
  SELECT payload->>'token' AS t INTO c4 FROM public.exos_mail WHERE template = 'drop-confirm' AND to_email = 'lv3@x.com'
     AND payload->>'token' NOT IN (c2.t, c3.t);
  UPDATE public.exos_drop_confirms SET created_at = now() WHERE token_hash = public._exos_drop_hash(c4.t);
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.118');
  ASSERT (public.exos_drop_confirm(c4.t)->>'ok')::boolean, 'DL11 a new signup after leaving re-joins';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT left_at IS NULL AND confirmed_at IS NOT NULL FROM public.exos_drop_signups WHERE email = 'lv3@x.com'), 'DL11 back on';
  RAISE NOTICE 'OK  DL11 leaving spends open confirms; older links / codes never re-join; a fresh signup does';
END $$;

-- DL12 ----------------------------------------------------------------------
DO $$
DECLARE v_drop uuid; v_org uuid; o_ok uuid; o_stop uuid; o_left uuid; o_org uuid;
BEGIN
  INSERT INTO public.exos_drop_signups (org_id, event_id, email, email_consent_text, confirmed_at, sms_phone, sms_consent_text, sms_consented_at)
  VALUES (pg_temp.u('1'), pg_temp.u('e5'), 'sms-ok@x.com', 'Email me once when tickets for D70 Later go on sale.', now(),
          '+12125550151', public.exos_drop_sms_consent_text('D70 Hall', 'D70 Later'), now()),
         (pg_temp.u('1'), pg_temp.u('e5'), 'sms-stop@x.com', 'Email me once when tickets for D70 Later go on sale.', now(),
          '+12125550152', public.exos_drop_sms_consent_text('D70 Hall', 'D70 Later'), now()),
         (pg_temp.u('1'), pg_temp.u('e5'), 'sms-left@x.com', 'Email me once when tickets for D70 Later go on sale.', now(),
          '+12125550153', public.exos_drop_sms_consent_text('D70 Hall', 'D70 Later'), now());
  INSERT INTO public.exos_sms_campaigns (org_id, event_id, audience, body, provider) VALUES (pg_temp.u('1'), pg_temp.u('e5'), 'drop_list', 'x', 'twilio')
  RETURNING id INTO v_drop;
  INSERT INTO public.exos_sms_campaigns (org_id, audience, body, provider) VALUES (pg_temp.u('1'), 'org', 'x', 'twilio') RETURNING id INTO v_org;
  INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after) VALUES (v_drop, pg_temp.u('1'), '+12125550151', 'x', now() - interval '1 minute') RETURNING id INTO o_ok;
  INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after) VALUES (v_drop, pg_temp.u('1'), '+12125550152', 'x', now() - interval '1 minute') RETURNING id INTO o_stop;
  INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after) VALUES (v_drop, pg_temp.u('1'), '+12125550153', 'x', now() - interval '1 minute') RETURNING id INTO o_left;
  INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after) VALUES (v_org, pg_temp.u('1'), '+12125550152', 'x', now() - interval '1 minute') RETURNING id INTO o_org;
  -- After queuing: a STOP for one number (the drop list's), and one signup leaves.
  INSERT INTO public.exos_sms_stops (org_id, phone, stopped_at) VALUES (pg_temp.u('1'), '+12125550152', now());
  UPDATE public.exos_drop_signups SET left_at = now(), sms_opted_out_at = now() WHERE email = 'sms-left@x.com';
  PERFORM count(*) FROM public.exos_sms_claim(200);
  ASSERT (SELECT status FROM public.exos_sms_outbox WHERE id = o_ok) = 'sending', 'DL12 a consenting number is sent';
  ASSERT (SELECT status = 'skipped' AND error = 'opted out' FROM public.exos_sms_outbox WHERE id = o_stop), 'DL12 claim skips a stopped number';
  ASSERT (SELECT status FROM public.exos_sms_outbox WHERE id = o_left) = 'skipped', 'DL12 claim skips a signup that left';
  ASSERT (SELECT status FROM public.exos_sms_outbox WHERE id = o_org) = 'sending', 'DL12 other audiences unchanged';
  RAISE NOTICE 'OK  DL12 exos_sms_claim skips drop-list texts to stopped numbers or departed signups; other audiences as before';
END $$;

-- DL9 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_tok text;
BEGIN
  UPDATE public.exos_drop_signups SET created_at = now() - interval '31 days' WHERE email = 'burst1@x.com';
  UPDATE public.exos_drop_confirms SET created_at = now() - interval '9 days'
   WHERE signup_id = (SELECT id FROM public.exos_drop_signups WHERE email = 'burst2@x.com');
  UPDATE public.exos_events SET starts_at = now() - interval '31 days' WHERE id = pg_temp.u('e9');
  -- lv3 (DL11, confirmed): its confirm mails are 9 days old.
  UPDATE public.exos_drop_confirms SET created_at = now() - interval '9 days'
   WHERE signup_id = (SELECT id FROM public.exos_drop_signups WHERE email = 'lv3@x.com');
  j := public.exos_drop_list_sweep();
  ASSERT (j->>'unconfirmed')::int = 1 AND (j->>'past_events')::int = 1 AND (j->>'confirms')::int >= 1, 'DL9 sweep: ' || j::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_drop_signups WHERE email = 'burst1@x.com' OR event_id = pg_temp.u('e9')), 'DL9 gone';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_drop_confirms c JOIN public.exos_drop_signups s ON s.id = c.signup_id WHERE s.email = 'lv3@x.com'),
    'DL9 old confirm rows swept';
  v_tok := (SELECT payload->>'leave_token' FROM public.exos_mail WHERE template = 'drop-confirm' AND to_email = 'lv3@x.com'
             ORDER BY created_at DESC, id LIMIT 1);
  PERFORM pg_temp.as_('anon');
  ASSERT (public.exos_drop_leave(v_tok)->>'ok')::boolean, 'DL9 a 9-day-old confirm mail''s leave link still works';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT left_at IS NOT NULL FROM public.exos_drop_signups WHERE email = 'lv3@x.com'), 'DL9 left by the old link';
  RAISE NOTICE 'OK  DL9 sweep: unconfirmed after 30 days, confirm rows after 8 (leave links kept), lists 30 days after the event';
END $$;

ROLLBACK;
