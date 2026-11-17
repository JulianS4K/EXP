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
  PERFORM set_config('request.jwt.claims', CASE WHEN p_role IN ('anon', 'authenticated')
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
            WHERE c.relname IN ('exos_drop_signups', 'exos_drop_confirms', 'exos_drop_settings') LOOP
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
    'exos_drop_list_set_presale', 'exos_drop_list_summary', 'exos_drop_signup', 'exos_drop_sms_consent_text', 'exos_drop_status'],
    'DL0 authenticated surface: ' || array_to_string(v_auth, ',');
  ASSERT 'exos_drop_list_blast' = ANY (v_svc) AND 'exos_drop_list_sweep' = ANY (v_svc), 'DL0 service jobs';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_drop_list_blast(int)', 'EXECUTE'), 'DL0 blast service only';
  ASSERT position('/* exos: drop list code */' in pg_get_functiondef('public.exos_check_voucher(uuid,text,text)'::regprocedure)) > 0,
    'DL0 voucher marker';
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
DECLARE j jsonb;
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
  ASSERT (j->>'sms')::boolean AND j->>'phone_hint' = '…0101', 'DL3 texts on: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e1') AND email = 'd70-fan1@x.com') = 1, 'DL3 dedupe';
  ASSERT (SELECT user_id = pg_temp.u('b1') AND confirmed_at IS NOT NULL AND sms_phone = '+12125550101'
            AND sms_consent_text = public.exos_drop_sms_consent_text('D70 Hall', 'D70 Drop') AND sms_consent_text ~* 'reply stop'
            AND promoter IS NULL   -- first touch kept
            FROM public.exos_drop_signups WHERE event_id = pg_temp.u('e1') AND email = 'd70-fan1@x.com'), 'DL3 row';
  -- fan2 joins with texts too; another org's event is its own list.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'));
  PERFORM public.exos_drop_join(pg_temp.u('e1'), true, '+12125550102');
  PERFORM public.exos_drop_join(pg_temp.u('e9'));
  ASSERT pg_temp.st($q$SELECT public.exos_drop_join(pg_temp.u('e2'))$q$) LIKE 'P0002%', 'DL3 on-sale event refused';
  PERFORM pg_temp.as_('postgres');
  RAISE NOTICE 'OK  DL3 signed in: one click, confirmed email required, dedupe with the guest row, texts with the SQL consent words';
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
  RAISE NOTICE 'OK  DL4 rate limits: 10 a minute per network, 3 confirm mails a day per address and event, same answer';
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
  -- Org A texts from a connected Twilio; fan2's number replied STOP after
  -- opting in on another list (exos_sms_stops), so it gets no text.
  INSERT INTO public.exos_org_integrations (org_id, provider, status) VALUES (pg_temp.u('1'), 'twilio', 'connected');
  INSERT INTO public.exos_sms_stops (org_id, phone, stopped_at) VALUES (pg_temp.u('1'), '+12125550102', now());
  UPDATE public.exos_drop_signups SET sms_consented_at = now() - interval '1 hour' WHERE sms_phone = '+12125550102';
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
  INSERT INTO public.exos_mail_prefs (user_id, marketing_opt_out) VALUES (pg_temp.u('b2'), true)
  ON CONFLICT (user_id) DO UPDATE SET marketing_opt_out = true;

  j := public.exos_drop_list_blast(500);
  ASSERT j = '{"mails": 3, "texts": 1}'::jsonb, 'DL7 presale blast: ' || j::text;
  ASSERT public.exos_drop_list_blast(500) = '{"mails": 0, "texts": 0}'::jsonb, 'DL7 re-run sends nothing';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'drop-on-sale') = 3, 'DL7 one mail each';
  SELECT * INTO m FROM public.exos_mail WHERE template = 'drop-on-sale' AND to_email = 'guest1@x.com';
  ASSERT m.payload->>'kind' = 'presale' AND m.payload->>'code' = v_code
     AND m.list_unsubscribe = '{{app_url}}/drop/leave?t=' || (SELECT leave_token FROM public.exos_drop_signups WHERE email = 'guest1@x.com'),
    'DL7 presale mail + List-Unsubscribe';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'drop-on-sale' AND to_email IN ('guest3@x.com', 'leaver@x.com', 'd70-fan2@x.com')),
    'DL7 pending, left and opted-out get none';
  ASSERT (SELECT blast_skip FROM public.exos_drop_signups WHERE email = 'd70-fan2@x.com' AND event_id = pg_temp.u('e1')) = 'opted_out', 'DL7 opted out recorded';
  ASSERT (SELECT sms_status FROM public.exos_drop_signups WHERE email = 'd70-fan2@x.com' AND event_id = pg_temp.u('e1')) = 'stopped', 'DL7 STOP after consent wins';
  SELECT o.*, ca.audience, ca.event_id AS ev INTO c FROM public.exos_sms_outbox o JOIN public.exos_sms_campaigns ca ON ca.id = o.campaign_id
   WHERE o.phone = '+12125550101';
  ASSERT c.audience = 'drop_list' AND c.ev = pg_temp.u('e1') AND c.body ~ 'Reply STOP to opt out\.$' AND c.body ~ '^D70 Hall: '
     AND (c.send_after AT TIME ZONE 'America/New_York')::time >= time '09:00'
     AND (c.send_after AT TIME ZONE 'America/New_York')::time < time '20:00', 'DL7 text: ' || c.body || ' at ' || c.send_after;
  ASSERT (c.send_after < v_at AND c.body ~ ('code ' || v_code)) OR (c.send_after >= v_at AND c.body ~ 'on sale now' AND c.body !~ v_code),
    'DL7 a text after the on-sale never carries the expired code';

  -- A late confirmer after the public on-sale gets the plain on-sale mail.
  UPDATE public.exos_ticket_tiers SET sales_start = now() - interval '1 minute' WHERE id = pg_temp.u('c1');
  UPDATE public.exos_drop_signups SET confirmed_at = now() WHERE email = 'guest3@x.com';
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
  v_tok := (SELECT leave_token FROM public.exos_drop_signups WHERE email = 'guest2@x.com');
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

-- DL9 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb;
BEGIN
  UPDATE public.exos_drop_signups SET created_at = now() - interval '31 days' WHERE email = 'burst1@x.com';
  UPDATE public.exos_drop_confirms SET created_at = now() - interval '9 days'
   WHERE signup_id = (SELECT id FROM public.exos_drop_signups WHERE email = 'burst2@x.com');
  UPDATE public.exos_events SET starts_at = now() - interval '31 days' WHERE id = pg_temp.u('e9');
  j := public.exos_drop_list_sweep();
  ASSERT (j->>'unconfirmed')::int = 1 AND (j->>'past_events')::int = 1 AND (j->>'confirms')::int >= 1, 'DL9 sweep: ' || j::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_drop_signups WHERE email = 'burst1@x.com' OR event_id = pg_temp.u('e9')), 'DL9 gone';
  RAISE NOTICE 'OK  DL9 sweep: unconfirmed after 30 days, confirm rows after 8, lists 30 days after the event';
END $$;

ROLLBACK;
