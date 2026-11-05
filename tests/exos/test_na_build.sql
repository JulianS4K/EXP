-- ============================================================================
-- Opendate "not applicable" endpoints, built (mig 20261105120000):
--   NA1  grants and RLS on the new tables and functions
--   NA2  printing: owner / manager only, one org, the code is shown once
--        (only its hash is kept), one live code a ticket, a reprint voids
--        the last one, what can't be printed
--   NA3  the door takes a print code once: checked in, the paper spent; the
--        second scan is refused; another ticket's code is refused
--   NA4  never beside another code: while printed, the app (T-) and wallet
--        (W-) codes are refused; voiding the paper gives them back
--   NA5  refused after a transfer (claimed or started), a refund, a reprint,
--        a new secret
--   NA6  re-entry lists: the first entry spends the paper, a second list
--        can't take it, an exit with it is fine; a typed override and a
--        test-window scan
--   NA7  offline: door keys carry the code's hash; an upload takes the code
--        once and reports a spent one as 'used'
--   NA8  the API's print: scope, key creator's role, org and event pins, an
--        order skips what can't be printed, logged without the codes
--   NA9  membership reservations: capacity, reserve, sold out, one per
--        email, complete (and again), cancel, expiry, cross-org, the API
--   NA10 X-Exos-Org: a personal token in another org of its user, held to
--        the role there; not a member; OAuth stays pinned
--   NA11 staff shifts: clock in / out, one open shift, members only, the
--        device and event must be the org's, the report, closing a
--        forgotten shift, RLS
--   NA12 Tixel: only WAITLIST, email required, matched to one event's
--        waitlist, replay, an ambiguous title
--   NA13 tagged items: retag, conflict, scope, cross-org
-- Self-contained (BEGIN / ROLLBACK), prefix a9b. Org …01: owner a1, manager
-- a2, scanner a3, finance a4. Org …02: owner b1 (a2 is its scanner).
-- Holders h1, h2. Two scans of the same paper at once: the row lock in
-- _exos_print_code_use (by hand: two psql sessions, see docs/wallet.md).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('a9b00000-0000-0000-0000-0000000000a1', 'a9b-owner@x.com', now()),
  ('a9b00000-0000-0000-0000-0000000000a2', 'a9b-manager@x.com', now()),
  ('a9b00000-0000-0000-0000-0000000000a3', 'a9b-scanner@x.com', now()),
  ('a9b00000-0000-0000-0000-0000000000a4', 'a9b-finance@x.com', now()),
  ('a9b00000-0000-0000-0000-0000000000b1', 'a9b-other@x.com', now()),
  ('a9b00000-0000-0000-0000-0000000000c1', 'a9b-holder@x.com', now()),
  ('a9b00000-0000-0000-0000-0000000000c2', 'a9b-friend@x.com', now()),
  ('a9b00000-0000-0000-0000-0000000000c3', 'a9b-stranger@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('a9b00000-0000-0000-0000-000000000001', 'A9B Org', 'a9b-org', 'a9b00000-0000-0000-0000-0000000000a1'),
  ('a9b00000-0000-0000-0000-000000000002', 'A9B Other', 'a9b-other', 'a9b00000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('a9b00000-0000-0000-0000-000000000001', 'a9b00000-0000-0000-0000-0000000000a1', 'owner'),
  ('a9b00000-0000-0000-0000-000000000001', 'a9b00000-0000-0000-0000-0000000000a2', 'manager'),
  ('a9b00000-0000-0000-0000-000000000001', 'a9b00000-0000-0000-0000-0000000000a3', 'scanner'),
  ('a9b00000-0000-0000-0000-000000000001', 'a9b00000-0000-0000-0000-0000000000a4', 'finance'),
  ('a9b00000-0000-0000-0000-000000000002', 'a9b00000-0000-0000-0000-0000000000b1', 'owner'),
  ('a9b00000-0000-0000-0000-000000000002', 'a9b00000-0000-0000-0000-0000000000a2', 'scanner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency,
                                created_by, venue_name, venue_location) VALUES
  ('a9b00000-0000-0000-0000-0000000000e1', 'a9b00000-0000-0000-0000-000000000001', 'A9B Live', 'a9b-live', 'published',
   now() - interval '1 hour', 'America/New_York', 100, 0, 'usd', 'a9b00000-0000-0000-0000-0000000000a1', 'The Room', 'Brooklyn, NY'),
  ('a9b00000-0000-0000-0000-0000000000e3', 'a9b00000-0000-0000-0000-000000000001', 'A9B Tomorrow', 'a9b-tomorrow', 'published',
   now() + interval '1 day', 'America/New_York', 100, 0, 'usd', 'a9b00000-0000-0000-0000-0000000000a1', NULL, NULL),
  ('a9b00000-0000-0000-0000-0000000000e4', 'a9b00000-0000-0000-0000-000000000001', 'A9B Twice', 'a9b-twice-1', 'published',
   now() + interval '5 days', 'America/New_York', 100, 0, 'usd', 'a9b00000-0000-0000-0000-0000000000a1', NULL, NULL),
  ('a9b00000-0000-0000-0000-0000000000e5', 'a9b00000-0000-0000-0000-000000000001', 'A9B Twice', 'a9b-twice-2', 'published',
   now() + interval '6 days', 'America/New_York', 100, 0, 'usd', 'a9b00000-0000-0000-0000-0000000000a1', NULL, NULL),
  ('a9b00000-0000-0000-0000-0000000000e9', 'a9b00000-0000-0000-0000-000000000002', 'A9B Elsewhere', 'a9b-else', 'published',
   now() - interval '1 hour', 'America/New_York', 100, 0, 'usd', 'a9b00000-0000-0000-0000-0000000000b1', NULL, NULL);
UPDATE public.exos_events SET checkin_test_mode = true, checkin_test_until = now() + interval '1 hour'
 WHERE id = 'a9b00000-0000-0000-0000-0000000000e3';
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  ('a9b00000-0000-0000-0000-0000000000d1', 'a9b00000-0000-0000-0000-0000000000e1', 'GA', 25, 100, 0, 'public', 1),
  ('a9b00000-0000-0000-0000-0000000000d3', 'a9b00000-0000-0000-0000-0000000000e3', 'GA', 25, 100, 0, 'public', 1),
  ('a9b00000-0000-0000-0000-0000000000d9', 'a9b00000-0000-0000-0000-0000000000e9', 'GA', 25, 100, 0, 'public', 1);
-- Tickets …c0NN: 01-20 on e1, 31 on e3, 91 on e9 (org 2). Holder c1.
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status,
                                 barcode_secret, price_paid, order_ref, channel_source, attendee_name)
SELECT ('a9b00000-0000-0000-0000-0000000c00' || n)::uuid,
       CASE WHEN n = '31' THEN 'a9b00000-0000-0000-0000-0000000000e3'::uuid WHEN n = '91' THEN 'a9b00000-0000-0000-0000-0000000000e9'::uuid
            ELSE 'a9b00000-0000-0000-0000-0000000000e1'::uuid END,
       CASE WHEN n = '91' THEN 'a9b00000-0000-0000-0000-000000000002'::uuid ELSE 'a9b00000-0000-0000-0000-000000000001'::uuid END,
       CASE WHEN n = '31' THEN 'a9b00000-0000-0000-0000-0000000000d3'::uuid WHEN n = '91' THEN 'a9b00000-0000-0000-0000-0000000000d9'::uuid
            ELSE 'a9b00000-0000-0000-0000-0000000000d1'::uuid END,
       'GA', 'a9b00000-0000-0000-0000-0000000000c1', 'a9b00000-0000-0000-0000-0000000000c1', 'a9b-holder@x.com', 'active',
       'sek-a9b-' || n, 25, CASE WHEN n IN ('15', '16', '17') THEN 'cs_a9b1' ELSE 'web-a9b-' || n END, 'stripe',
       CASE WHEN n = '01' THEN 'Sam Lee' END
  FROM unnest(ARRAY['01','02','03','04','05','06','07','08','09','10','11','12','13','14','15','16','17','18','31','91']) n;
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity,
                                           amount_cents, status, payment_intent) VALUES
  ('cs_a9b1', 'a9b00000-0000-0000-0000-0000000000e1', 'a9b00000-0000-0000-0000-0000000000d1',
   'a9b00000-0000-0000-0000-000000000001', 'a9b00000-0000-0000-0000-0000000000c1', 'a9b-holder@x.com', 3, 7500, 'fulfilled', 'pi_a9b1');
INSERT INTO public.exos_checkin_lists (id, event_id, org_id, name, tier_ids, allow_reentry, sort_order) VALUES
  ('a9b00000-0000-0000-0000-00000000aa01', 'a9b00000-0000-0000-0000-0000000000e1', NULL, 'Front', NULL, true, 0),
  ('a9b00000-0000-0000-0000-00000000aa02', 'a9b00000-0000-0000-0000-0000000000e1', NULL, 'Side', NULL, true, 1);
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('a9b00000-0000-0000-0000-0000000000f1', 'a9b00000-0000-0000-0000-000000000001', 'box office', 'sk_live_a9b1', 'a9bhash1',
   ARRAY['tickets:write','commerce:write','events:read'], 'a9b00000-0000-0000-0000-0000000000a1'),
  ('a9b00000-0000-0000-0000-0000000000f2', 'a9b00000-0000-0000-0000-000000000001', 'reader', 'sk_live_a9b2', 'a9bhash2',
   ARRAY['tickets:read','commerce:read'], 'a9b00000-0000-0000-0000-0000000000a1'),
  ('a9b00000-0000-0000-0000-0000000000f3', 'a9b00000-0000-0000-0000-000000000001', 'finance key', 'sk_live_a9b3', 'a9bhash3',
   ARRAY['tickets:write','commerce:write'], 'a9b00000-0000-0000-0000-0000000000a4'),
  ('a9b00000-0000-0000-0000-0000000000f9', 'a9b00000-0000-0000-0000-000000000002', 'other', 'sk_live_a9b9', 'a9bhash9',
   ARRAY['tickets:write','commerce:write'], 'a9b00000-0000-0000-0000-0000000000b1');

CREATE TEMP TABLE a9 (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('a9b00000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.org(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('a9b00000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.tk(n text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('a9b00000-0000-0000-0000-0000000c00' || n)::uuid $$;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM a9 WHERE k = p_k $$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true) $$;
-- Print one ticket as the manager; the code.
CREATE FUNCTION pg_temp.print(n text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_ticket_print(ARRAY[pg_temp.tk(n)]);
  RETURN r #>> '{tickets,0,print_code}';
END $$;
-- The ticket's app code (T-) for now.
CREATE FUNCTION pg_temp.tcode(n text) RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' || public._exos_door_code_mac(t.id, t.owner_id, b, t.barcode_secret)
    FROM public.exos_tickets t, (SELECT floor(extract(epoch FROM now()) * 1000 / 30000)::bigint AS b) x
   WHERE t.id = pg_temp.tk(n) $$;
-- A live Apple Wallet pass and its W- code.
CREATE FUNCTION pg_temp.wcode(n text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE t public.exos_tickets%ROWTYPE;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = pg_temp.tk(n);
  INSERT INTO public.exos_wallet_passes (serial_number, ticket_id, owner_id)
  VALUES ('exw' || md5(t.id::text), t.id, t.owner_id) ON CONFLICT DO NOTHING;
  RETURN public._exos_wallet_apple_code(t.id, t.owner_id, t.barcode_secret, 1);
END $$;
-- Scan as the manager at the door of the ticket's event.
CREATE FUNCTION pg_temp.scan(n text, p_code text, p_list text DEFAULT NULL, p_dir text DEFAULT 'entry') RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a2'));
  RETURN public.exos_check_in_ticket(pg_temp.tk(n), 'camera', 'verified', p_code,
           (SELECT event_id FROM public.exos_tickets WHERE id = pg_temp.tk(n)), NULL, NULL, 'door-1',
           CASE WHEN p_list IS NULL THEN NULL ELSE ('a9b00000-0000-0000-0000-00000000' || p_list)::uuid END, p_dir);
END $$;
CREATE FUNCTION pg_temp.reason(r jsonb) RETURNS text LANGUAGE sql AS $$ SELECT r ->> 'reason' $$;

-- ── NA1 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_ticket_print_codes', 'exos_membership_reservations', 'exos_staff_shifts', 'exos_tixel_signups'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'NA1: RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'NA1: anon reads ' || t;
    ASSERT has_table_privilege('authenticated', 'public.' || t, 'SELECT'), 'NA1: staff read ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'NA1: clients write ' || t;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
      'public._exos_print_hash(text)', 'public._exos_print_code_ticket(text)', 'public._exos_print_code_live(uuid)',
      'public._exos_print_code_check(uuid,uuid,text,text)', 'public._exos_print_code_use(uuid,text)',
      'public._exos_print_code_void(uuid,text)', 'public._exos_print_mint(uuid,uuid,uuid[],text,uuid,boolean)',
      'public._exos_order_print_ids(uuid,text,uuid)', 'public._exos_api_print(uuid,uuid,text,text,uuid)',
      'public._exos_membership_capacity_used(uuid)', 'public.exos_membership_capacity_left(uuid)',
      'public._exos_membership_reserve(uuid,uuid,uuid,uuid,jsonb)',
      'public._exos_membership_reservation_complete(uuid,uuid,text,uuid)',
      'public._exos_membership_reservation_cancel(uuid,uuid,text)',
      'public._exos_membership_set_capacity(uuid,uuid,integer)',
      'public._exos_api_membership_box_office(uuid,uuid,text,uuid,text,jsonb)',
      'public.exos_api_token_auth_org(text,text,uuid)',
      'public._exos_staff_clock_in(uuid,uuid,uuid,uuid,text)', 'public._exos_staff_clock_out(uuid,uuid,text)',
      'public._exos_staff_shift_report(uuid,timestamptz,timestamptz)',
      'public._exos_tixel_ingest(uuid,jsonb)', 'public._exos_tagged_item_retag(uuid,uuid,uuid,text,uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'NA1: internal ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_tg_print_ticket_changed()', 'EXECUTE'), 'NA1: trigger fn';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_door_keys(uuid,uuid,text)', 'EXECUTE'), 'NA1: door keys';
  FOREACH f IN ARRAY ARRAY[
      'public.exos_ticket_print(uuid[])', 'public.exos_order_print(text)', 'public.exos_ticket_print_void(uuid)',
      'public.exos_membership_reserve(uuid,jsonb)', 'public.exos_membership_reservation_complete(uuid,text)',
      'public.exos_membership_reservation_cancel(uuid,text)', 'public.exos_membership_set_capacity(uuid,integer)',
      'public.exos_staff_clock_in(uuid,uuid,uuid,text)', 'public.exos_staff_clock_out(uuid,text)',
      'public.exos_staff_shift_close(uuid,timestamptz,text)', 'public.exos_staff_shift_report(uuid,timestamptz,timestamptz)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'NA1: signed-in ' || f;
    ASSERT (SELECT prosecdef AND proconfig::text LIKE '%search_path=public, pg_temp%' FROM pg_proc WHERE oid = f::regprocedure),
      'NA1: secdef + search_path ' || f;
  END LOOP;
  -- The check-in RPCs keep their grants through the patches.
  ASSERT NOT has_function_privilege('anon', 'public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)', 'EXECUTE'),
    'NA1: check-in grants kept';
  RAISE NOTICE 'OK NA1 RLS + read-only grants on the new tables; internal fns service-only; wrappers signed-in only';
END $$;

-- ── NA2 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; c1 text; c2 text;
BEGIN
  -- Scanner, finance, the holder, another org's owner: not the box office.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print(ARRAY[%L::uuid])', pg_temp.tk('01'))) = '42501', 'NA2: scanner prints';
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print(ARRAY[%L::uuid])', pg_temp.tk('01'))) = '42501', 'NA2: finance prints';
  PERFORM pg_temp.act(pg_temp.u('c1'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print(ARRAY[%L::uuid])', pg_temp.tk('01'))) = '42501', 'NA2: holder prints';
  PERFORM pg_temp.act(pg_temp.u('b1'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print(ARRAY[%L::uuid])', pg_temp.tk('01'))) = '42501', 'NA2: other org prints';
  -- Two orgs' tickets in one call: refused.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print(ARRAY[%L::uuid, %L::uuid])', pg_temp.tk('01'), pg_temp.tk('91'))) = '42501',
    'NA2: mixed orgs';
  -- The owner prints: the code, the paper's fields, only the hash stored.
  r := public.exos_ticket_print(ARRAY[pg_temp.tk('01')]);
  c1 := r #>> '{tickets,0,print_code}';
  ASSERT c1 ~ ('^P-' || pg_temp.tk('01') || ':[A-Za-z0-9_-]{22}$'), 'NA2: code shape ' || c1;
  ASSERT r #>> '{tickets,0,event_name}' = 'A9B Live' AND r #>> '{tickets,0,attendee_name}' = 'Sam Lee'
     AND r #>> '{tickets,0,venue_name}' = 'The Room' AND r #>> '{tickets,0,org_name}' = 'A9B Org'
     AND r #>> '{tickets,0,tier_name}' = 'GA', 'NA2: paper fields ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_ticket_print_codes p, jsonb_each_text(to_jsonb(p)) x WHERE x.value = c1),
    'NA2: the code itself is stored nowhere';
  ASSERT (SELECT code_hash FROM public.exos_ticket_print_codes WHERE ticket_id = pg_temp.tk('01') AND status = 'active')
       = encode(extensions.digest(c1, 'sha256'), 'hex'), 'NA2: SHA-256 kept';
  -- Reprint (the manager): the old code is voided, one live code.
  c2 := pg_temp.print('01');
  ASSERT c2 <> c1, 'NA2: a new code';
  ASSERT (SELECT count(*) FROM public.exos_ticket_print_codes WHERE ticket_id = pg_temp.tk('01') AND status = 'active') = 1,
    'NA2: one live code';
  ASSERT (SELECT void_reason FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c1)) = 'reprinted',
    'NA2: reprinted';
  -- The index stops a second live row whatever the caller.
  ASSERT pg_temp.st(format($q$INSERT INTO public.exos_ticket_print_codes (org_id, event_id, ticket_id, code_hash)
                           VALUES (%L, %L, %L, repeat('a', 64))$q$, pg_temp.org('01'), pg_temp.u('e1'), pg_temp.tk('01'))) = '23505',
    'NA2: one live code (index)';
  INSERT INTO a9 VALUES ('c01', c2), ('c01_old', c1);
  -- Not printable: used, voided, in transfer, a cancelled event; nothing minted.
  UPDATE public.exos_tickets SET status = 'voided' WHERE id = pg_temp.tk('02');
  PERFORM pg_temp.act(pg_temp.u('a1'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print(ARRAY[%L::uuid])', pg_temp.tk('02'))) = '55000', 'NA2: voided';
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print(ARRAY[%L::uuid, %L::uuid])', pg_temp.tk('03'), pg_temp.tk('02'))) = '55000',
    'NA2: all or nothing';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_ticket_print_codes WHERE ticket_id = pg_temp.tk('03')), 'NA2: nothing minted';
  ASSERT pg_temp.st('SELECT public.exos_ticket_print(ARRAY[]::uuid[])') = '42501', 'NA2: no tickets';
  -- RLS: owner / manager read the rows; the scanner and the holder don't.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_ticket_print_codes) = 0, 'NA2: scanner reads print rows';
  RESET ROLE;
  PERFORM pg_temp.act(pg_temp.u('a2'));
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_ticket_print_codes) = 2, 'NA2: manager reads print rows';
  RESET ROLE;
  RAISE NOTICE 'OK NA2 owner / manager print one org''s tickets; only the hash is kept; one live code; reprint voids';
END $$;

-- ── NA3 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; c text := pg_temp.v('c01');
BEGIN
  -- The old paper is refused; another ticket's code is refused; a forged one too.
  ASSERT pg_temp.reason(pg_temp.scan('01', pg_temp.v('c01_old'))) = 'barcode-rejected', 'NA3: reprinted paper';
  ASSERT pg_temp.reason(pg_temp.scan('03', c)) = 'barcode-rejected', 'NA3: another ticket''s code';
  ASSERT pg_temp.reason(pg_temp.scan('01', 'P-' || pg_temp.tk('01') || ':' || repeat('A', 22))) = 'barcode-rejected', 'NA3: forged';
  -- Accepted once, lower-case prefix and all.
  r := pg_temp.scan('01', 'p' || substring(c FROM 2));
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in' AND (r ->> 'verified')::boolean, 'NA3: admitted ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('01')) = 'used', 'NA3: ticket used';
  ASSERT (SELECT status = 'used' AND used_at IS NOT NULL AND used_by = pg_temp.u('a2') FROM public.exos_ticket_print_codes
           WHERE code_hash = public._exos_print_hash(c)), 'NA3: paper spent';
  ASSERT (SELECT verification FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('01')) = 'verified', 'NA3: logged verified';
  -- The second scan of the same paper.
  ASSERT pg_temp.reason(pg_temp.scan('01', c)) = 'print-code-used', 'NA3: second scan';
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('01')) = 1, 'NA3: one check-in';
  RAISE NOTICE 'OK NA3 a print code checks in once (same transaction as the ticket); spent, reprinted and forged codes refused';
END $$;

-- ── NA4 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE c text; w text; r jsonb;
BEGIN
  w := pg_temp.wcode('04');
  c := pg_temp.print('04');
  ASSERT pg_temp.reason(pg_temp.scan('04', pg_temp.tcode('04'))) = 'printed', 'NA4: app code beside the paper';
  ASSERT pg_temp.reason(pg_temp.scan('04', w)) = 'printed', 'NA4: wallet code beside the paper';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('04')) = 'active', 'NA4: nothing used';
  -- The holder voids the paper: the phone works again, the paper doesn't.
  PERFORM pg_temp.act(pg_temp.u('c1'));
  r := public.exos_ticket_print_void(pg_temp.tk('04'));
  ASSERT (r ->> 'voided')::boolean, 'NA4: voided ' || r::text;
  ASSERT (SELECT void_reason FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'voided-by-holder',
    'NA4: by holder';
  -- Nobody else may void it.
  PERFORM pg_temp.act(pg_temp.u('c3'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print_void(%L)', pg_temp.tk('04'))) = 'P0002', 'NA4: stranger voids';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_print_void(%L)', pg_temp.tk('04'))) = 'P0002', 'NA4: scanner voids';
  ASSERT pg_temp.reason(pg_temp.scan('04', c)) = 'barcode-rejected', 'NA4: voided paper';
  ASSERT pg_temp.reason(pg_temp.scan('04', pg_temp.tcode('04'))) = 'checked-in', 'NA4: app code works again';
  -- Staff void: reason voided-by-staff.
  c := pg_temp.print('05');
  PERFORM pg_temp.act(pg_temp.u('a2'));
  PERFORM public.exos_ticket_print_void(pg_temp.tk('05'));
  ASSERT (SELECT void_reason FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'voided-by-staff',
    'NA4: by staff';
  RAISE NOTICE 'OK NA4 while printed the app and wallet codes are refused; voiding the paper (holder / staff) gives them back';
END $$;

-- ── NA5 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE c text;
BEGIN
  -- A transfer claimed (new owner): the paper dies.
  c := pg_temp.print('06');
  UPDATE public.exos_tickets SET owner_id = pg_temp.u('c2'), barcode_secret = 'sek-a9b-06b' WHERE id = pg_temp.tk('06');
  ASSERT (SELECT status || '/' || void_reason FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c))
       = 'voided/transferred', 'NA5: transfer';
  ASSERT pg_temp.reason(pg_temp.scan('06', c)) = 'barcode-rejected', 'NA5: refused after a transfer';
  ASSERT pg_temp.reason(pg_temp.scan('06', pg_temp.tcode('06'))) = 'checked-in', 'NA5: the new holder''s app code works';
  -- A transfer started.
  c := pg_temp.print('07');
  UPDATE public.exos_tickets SET pending_transfer_id = gen_random_uuid() WHERE id = pg_temp.tk('07');
  ASSERT (SELECT void_reason FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'transfer-started',
    'NA5: transfer started';
  UPDATE public.exos_tickets SET pending_transfer_id = NULL WHERE id = pg_temp.tk('07');
  ASSERT pg_temp.reason(pg_temp.scan('07', c)) = 'barcode-rejected', 'NA5: refused after a cancelled transfer too';
  -- A refund / void.
  c := pg_temp.print('08');
  UPDATE public.exos_tickets SET status = 'voided', voided_at = now() WHERE id = pg_temp.tk('08');
  ASSERT (SELECT void_reason FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'ticket-voided',
    'NA5: refund';
  ASSERT pg_temp.reason(pg_temp.scan('08', c)) = 'barcode-rejected', 'NA5: refused after a refund';
  -- A release.
  c := pg_temp.print('09');
  UPDATE public.exos_tickets SET status = 'voided', released_at = now() WHERE id = pg_temp.tk('09');
  ASSERT (SELECT void_reason FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'released',
    'NA5: release';
  -- A reprint (reissue): the first paper is refused, the second admits.
  c := pg_temp.print('10');
  INSERT INTO a9 VALUES ('c10', pg_temp.print('10'));
  ASSERT pg_temp.reason(pg_temp.scan('10', c)) = 'barcode-rejected', 'NA5: refused after a reprint';
  ASSERT pg_temp.reason(pg_temp.scan('10', pg_temp.v('c10'))) = 'checked-in', 'NA5: the new paper admits';
  -- A new barcode secret (the holder reissued).
  c := pg_temp.print('11');
  UPDATE public.exos_tickets SET barcode_secret = 'sek-a9b-11b' WHERE id = pg_temp.tk('11');
  ASSERT (SELECT void_reason FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'secret-rotated',
    'NA5: secret rotated';
  ASSERT pg_temp.reason(pg_temp.scan('11', c)) = 'barcode-rejected', 'NA5: refused after a new secret';
  -- A ticket of another org: its code can't be used on ours.
  PERFORM pg_temp.act(pg_temp.u('b1'));
  c := (public.exos_ticket_print(ARRAY[pg_temp.tk('91')])) #>> '{tickets,0,print_code}';
  ASSERT pg_temp.reason(pg_temp.scan('03', c)) = 'barcode-rejected', 'NA5: cross-org code';
  PERFORM pg_temp.act(pg_temp.u('a1'));
  ASSERT pg_temp.st(format('SELECT public.exos_check_in_ticket(%L, ''camera'', ''verified'', %L, %L, NULL, NULL, NULL, NULL, ''entry'')',
                           pg_temp.tk('91'), c, pg_temp.u('e9'))) = '42501', 'NA5: another org''s door';
  RAISE NOTICE 'OK NA5 a print code is refused after a transfer (claimed or started), a refund / release, a reprint, a new secret';
END $$;

-- ── NA6 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE c text; r jsonb;
BEGIN
  -- Re-entry lists: the first entry spends the paper.
  c := pg_temp.print('12');
  r := pg_temp.scan('12', c, 'aa01');
  ASSERT r ->> 'reason' = 'checked-in', 'NA6: list entry ' || r::text;
  ASSERT (SELECT status FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'used', 'NA6: spent';
  -- The same paper at the other list: refused (it would be a second person).
  ASSERT pg_temp.reason(pg_temp.scan('12', c, 'aa02')) = 'print-code-used', 'NA6: second list';
  -- Out with the paper, then back in with it: out yes, back in no (one entry).
  ASSERT pg_temp.reason(pg_temp.scan('12', c, 'aa01', 'exit')) = 'checked-out', 'NA6: exit with the paper';
  ASSERT pg_temp.reason(pg_temp.scan('12', c, 'aa01')) = 'print-code-used', 'NA6: back in with the paper';
  -- A typed override (the manager) admits the ticket: the paper is spent.
  c := pg_temp.print('13');
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_check_in_ticket(pg_temp.tk('13'), 'manual', 'manual', NULL, pg_temp.u('e1'), 'paper is torn', NULL, NULL, NULL, 'entry');
  ASSERT r ->> 'reason' = 'checked-in', 'NA6: override ' || r::text;
  ASSERT (SELECT status FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'used', 'NA6: override spends';
  ASSERT pg_temp.reason(pg_temp.scan('13', c)) = 'print-code-used', 'NA6: paper after an override';
  -- The pre-doors test window proves the scanner: the paper stays live.
  c := pg_temp.print('31');
  ASSERT pg_temp.reason(pg_temp.scan('31', c)) = 'test-scan', 'NA6: test scan';
  ASSERT (SELECT status FROM public.exos_ticket_print_codes WHERE code_hash = public._exos_print_hash(c)) = 'active', 'NA6: still live';
  -- The older overload (no lists) follows the same rules.
  c := pg_temp.print('14');
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT public.exos_check_in_ticket(pg_temp.tk('14'), 'camera', 'verified', pg_temp.tcode('14'), pg_temp.u('e1'), NULL::text,
                                     NULL::timestamptz, NULL::text) ->> 'reason' = 'printed', 'NA6: old overload, app code';
  ASSERT public.exos_check_in_ticket(pg_temp.tk('14'), 'camera', 'verified', c, pg_temp.u('e1'), NULL::text,
                                     NULL::timestamptz, NULL::text) ->> 'reason' = 'checked-in', 'NA6: old overload, paper';
  ASSERT public.exos_check_in_ticket(pg_temp.tk('14'), 'camera', 'verified', c, pg_temp.u('e1'), NULL::text,
                                     NULL::timestamptz, NULL::text) ->> 'reason' = 'print-code-used', 'NA6: old overload, again';
  RAISE NOTICE 'OK NA6 re-entry lists, exits, a typed override, the test window and the older overload follow the one-entry rule';
END $$;

-- ── NA7 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE c text; k jsonb; r jsonb; v_ref uuid := gen_random_uuid();
BEGIN
  c := pg_temp.print('18');
  k := public._exos_door_keys(pg_temp.tk('18'), pg_temp.u('c1'), 'sek-a9b-18');
  ASSERT k ->> 'p' = encode(extensions.digest(c, 'sha256'), 'hex'), 'NA7: door keys carry the hash ' || k::text;
  ASSERT k ? 'd', 'NA7: day keys still there';
  ASSERT NOT (public._exos_door_keys(pg_temp.tk('03'), pg_temp.u('c1'), 'sek-a9b-03') ? 'p'), 'NA7: no paper, no p';
  -- The upload: admitted once; the same ref again answers the same.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_check_in_offline(v_ref, pg_temp.tk('18'), pg_temp.u('e1'), now() - interval '2 minutes', c, 'camera',
                                    NULL, 'door-2', NULL, 'entry');
  ASSERT r ->> 'reason' = 'checked-in', 'NA7: offline upload ' || r::text;
  ASSERT (public.exos_check_in_offline(v_ref, pg_temp.tk('18'), pg_temp.u('e1'), now() - interval '2 minutes', c, 'camera',
                                       NULL, 'door-2', NULL, 'entry') ->> 'duplicate')::boolean, 'NA7: same ref';
  -- Another phone admitted the same paper offline: a conflict, reported 'used'.
  r := public.exos_check_in_offline(gen_random_uuid(), pg_temp.tk('18'), pg_temp.u('e1'), now() - interval '1 minute', c, 'camera',
                                    NULL, 'door-3', NULL, 'entry');
  ASSERT (r ->> 'conflict')::boolean AND r ->> 'reason' = 'print-code-used', 'NA7: second phone ' || r::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_scan_rejects WHERE ticket_id_attempted = pg_temp.tk('18')::text AND reason = 'used'
                   AND reason_detail = 'offline-replay:print-code-used'), 'NA7: scan report says used';
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('18')) = 1, 'NA7: one admission';
  RAISE NOTICE 'OK NA7 door keys carry the paper''s hash; an offline upload takes it once and reports the second as used';
END $$;

-- ── NA8 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb;
BEGIN
  -- Scope: a read key can't print.
  ASSERT pg_temp.st(format('SELECT public._exos_api_print(%L, %L, ''ticket'', %L, NULL)',
                           pg_temp.org('01'), pg_temp.u('f2'), pg_temp.tk('03'))) = '42501', 'NA8: tickets:read';
  -- A key made by the finance member: not the box office.
  ASSERT pg_temp.st(format('SELECT public._exos_api_print(%L, %L, ''ticket'', %L, NULL)',
                           pg_temp.org('01'), pg_temp.u('f3'), pg_temp.tk('03'))) = '42501', 'NA8: finance creator';
  -- Another org's ticket, and the wrong event in the path: not found.
  ASSERT pg_temp.st(format('SELECT public._exos_api_print(%L, %L, ''ticket'', %L, NULL)',
                           pg_temp.org('01'), pg_temp.u('f1'), pg_temp.tk('91'))) = 'P0002', 'NA8: other org ticket';
  ASSERT pg_temp.st(format('SELECT public._exos_api_print(%L, %L, ''ticket'', %L, %L)',
                           pg_temp.org('01'), pg_temp.u('f1'), pg_temp.tk('03'), pg_temp.u('e3'))) = 'P0002', 'NA8: event pin';
  ASSERT pg_temp.st(format('SELECT public._exos_api_print(%L, %L, ''ticket'', %L, NULL)',
                           pg_temp.org('01'), pg_temp.u('f1'), 'not-a-uuid')) = 'P0002', 'NA8: bad id';
  -- One ticket.
  r := public._exos_api_print(pg_temp.org('01'), pg_temp.u('f1'), 'ticket', pg_temp.tk('03')::text, pg_temp.u('e1'));
  ASSERT r #>> '{tickets,0,print_code}' LIKE 'P-' || pg_temp.tk('03') || ':%', 'NA8: printed ' || r::text;
  ASSERT (SELECT printed_via = 'api' AND api_key_id = pg_temp.u('f1') AND printed_by = pg_temp.u('a1')
            FROM public.exos_ticket_print_codes WHERE ticket_id = pg_temp.tk('03') AND status = 'active'), 'NA8: recorded as api';
  -- An order: the used ticket is skipped, the others printed.
  UPDATE public.exos_tickets SET status = 'used' WHERE id = pg_temp.tk('15');
  r := public._exos_api_print(pg_temp.org('01'), pg_temp.u('f1'), 'order', 'cs_a9b1', NULL);
  ASSERT jsonb_array_length(r -> 'tickets') = 2 AND r #>> '{skipped,0,reason}' = 'used'
     AND r #>> '{skipped,0,ticket_id}' = pg_temp.tk('15')::text, 'NA8: order ' || r::text;
  ASSERT pg_temp.st(format('SELECT public._exos_api_print(%L, %L, ''order'', ''cs_a9b1'', NULL)',
                           pg_temp.org('02'), pg_temp.u('f9'))) = 'P0002', 'NA8: another org''s order';
  ASSERT pg_temp.st(format('SELECT public._exos_api_print(%L, %L, ''order'', ''cs_a9b1'', %L)',
                           pg_temp.org('01'), pg_temp.u('f1'), pg_temp.u('e3'))) = 'P0002', 'NA8: order event pin';
  -- The dashboard prints an order the same way.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT jsonb_array_length(public.exos_order_print('cs_a9b1') -> 'tickets') = 2, 'NA8: dashboard order';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st('SELECT public.exos_order_print(''cs_a9b1'')') = '42501', 'NA8: scanner prints an order';
  -- The API voids a paper (staff).
  r := public._exos_api_print(pg_temp.org('01'), pg_temp.u('f1'), 'ticket_void', pg_temp.tk('03')::text, NULL);
  ASSERT (r ->> 'voided')::boolean AND NOT public._exos_print_code_live(pg_temp.tk('03')), 'NA8: API void ' || r::text;
  ASSERT NOT (public._exos_api_print(pg_temp.org('01'), pg_temp.u('f1'), 'ticket_void', pg_temp.tk('03')::text, NULL) ->> 'voided')::boolean,
    'NA8: nothing left to void';
  ASSERT pg_temp.st(format('SELECT public._exos_api_print(%L, %L, ''ticket_void'', %L, NULL)',
                           pg_temp.org('02'), pg_temp.u('f9'), pg_temp.tk('03'))) = 'P0002', 'NA8: API void other org';
  -- Logged, without a code.
  ASSERT (SELECT count(*) FROM public.exos_api_writes WHERE api_key_id = pg_temp.u('f1') AND action IN ('ticket.print', 'order.print')) = 2
     AND (SELECT count(*) FROM public.exos_api_writes WHERE api_key_id = pg_temp.u('f1') AND action = 'ticket.print_void') = 2,
    'NA8: logged';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_api_writes WHERE api_key_id = pg_temp.u('f1') AND result::text LIKE '%P-%'),
    'NA8: no code in the log';
  RAISE NOTICE 'OK NA8 the API prints with tickets:write and an owner / manager key; org and event pinned; orders skip; logged without codes';
END $$;

-- ── NA9 ─────────────────────────────────────────────────────────────────────
INSERT INTO public.exos_membership_products (id, org_id, name, price_cents, billing) VALUES
  ('a9b00000-0000-0000-0000-00000000b0a1', 'a9b00000-0000-0000-0000-000000000001', 'Friends', 2500, 'year'),
  ('a9b00000-0000-0000-0000-00000000b0a9', 'a9b00000-0000-0000-0000-000000000002', 'Elsewhere', 2500, 'year');
DO $$
DECLARE r jsonb; m uuid := 'a9b00000-0000-0000-0000-00000000b0a1'; t1 text; t2 text;
BEGIN
  -- Capacity: owner / manager set it; unlimited by default.
  ASSERT public.exos_membership_capacity_left(m) IS NULL, 'NA9: unlimited';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_membership_set_capacity(%L, 2)', m)) = '42501', 'NA9: scanner sets capacity';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_membership_set_capacity(%L, 0)', m)) = '22023', 'NA9: capacity 0';
  r := public.exos_membership_set_capacity(m, 2);
  ASSERT (r ->> 'capacity')::int = 2 AND (r ->> 'left')::int = 2, 'NA9: capacity ' || r::text;
  -- Reserve: validation, then two places.
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reserve(%L, ''{"email":"nope"}'')', m)) = '22023', 'NA9: bad email';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reserve(%L, ''{"email":"a@x.com","payment_method":"card"}'')', m)) = '22023',
    'NA9: card';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reserve(%L, ''{"email":"a@x.com","pin":"1"}'')', m)) = '22023', 'NA9: unknown field';
  r := public.exos_membership_reserve(m, '{"email":"Fan1@X.com","first_name":"Ana","last_name":"Diaz","payment_method":"check","payment_reference":"#1001","device_name":"Box 1"}');
  t1 := r ->> 'token';
  ASSERT t1 ~ '^mbr_[A-Za-z0-9_-]{43}$' AND r ->> 'state' = 'reserved' AND r ->> 'email' = 'fan1@x.com'
     AND (r ->> 'amount_cents')::int = 2500, 'NA9: reserved ' || r::text;
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reserve(%L, ''{"email":"fan1@x.com"}'')', m)) = '23505', 'NA9: one per email';
  t2 := public.exos_membership_reserve(m, '{"email":"fan2@x.com"}') ->> 'token';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reserve(%L, ''{"email":"fan3@x.com"}'')', m)) = '55000', 'NA9: sold out';
  ASSERT public.exos_membership_capacity_left(m) = 0, 'NA9: none left';
  -- Cancel frees a place; cancelling again answers the same.
  ASSERT public.exos_membership_reservation_cancel(m, t2) ->> 'state' = 'cancelled', 'NA9: cancelled';
  ASSERT public.exos_membership_reservation_cancel(m, t2) ->> 'state' = 'cancelled', 'NA9: cancel again';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reservation_complete(%L, %L)', m, t2)) = '55000', 'NA9: complete cancelled';
  -- Expiry frees a place.
  t2 := public.exos_membership_reserve(m, '{"email":"fan3@x.com"}') ->> 'token';
  UPDATE public.exos_membership_reservations SET expires_at = now() - interval '1 second' WHERE token = t2;
  ASSERT public.exos_membership_capacity_left(m) = 1, 'NA9: expired frees a place';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reservation_complete(%L, %L)', m, t2)) = '55000', 'NA9: complete expired';
  ASSERT (SELECT status FROM public.exos_membership_reservations WHERE token = t2) = 'reserved', 'NA9: (the refusal rolls back)';
  -- Complete: the membership; again: the same one.
  r := public.exos_membership_reservation_complete(m, t1);
  ASSERT r #>> '{reservation,state}' = 'completed' AND r #>> '{membership,status}' = 'active', 'NA9: completed ' || r::text;
  ASSERT (SELECT source = 'purchase' AND holder_email = 'fan1@x.com' AND member_name = 'Ana Diaz' AND issued_by = pg_temp.u('a2')
            FROM public.exos_fan_memberships WHERE id = (r #>> '{membership,id}')::uuid), 'NA9: the membership';
  ASSERT public.exos_membership_reservation_complete(m, t1) #>> '{membership,id}' = r #>> '{membership,id}'
     AND (public.exos_membership_reservation_complete(m, t1) ->> 'replay')::boolean, 'NA9: complete again';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reservation_cancel(%L, %L)', m, t1)) = '55000', 'NA9: cancel completed';
  -- A member can't reserve the product again.
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reserve(%L, ''{"email":"fan1@x.com"}'')', m)) = '23505', 'NA9: already a member';
  -- Capacity counts the membership: one live + one reserve = full.
  PERFORM public.exos_membership_reserve(m, '{"email":"fan4@x.com"}');
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reserve(%L, ''{"email":"fan5@x.com"}'')', m)) = '55000', 'NA9: full again';
  -- Another org: its staff can't sell ours; ours can't touch its product.
  PERFORM pg_temp.act(pg_temp.u('b1'));
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reserve(%L, ''{"email":"z@x.com"}'')', m)) = '42501', 'NA9: other org';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_reservation_complete(%L, %L)', m, t1)) = '42501', 'NA9: other org completes';
  -- The API: scope, creator role, org.
  ASSERT pg_temp.st(format('SELECT public._exos_api_membership_box_office(%L, %L, ''reserve'', %L, NULL, ''{"email":"q@x.com"}'')',
                           pg_temp.org('01'), pg_temp.u('f2'), m)) = '42501', 'NA9: commerce:read reserves';
  ASSERT (public._exos_api_membership_box_office(pg_temp.org('01'), pg_temp.u('f2'), 'capacity.get', m, NULL, NULL) ->> 'capacity')::int = 2,
    'NA9: commerce:read reads capacity';
  ASSERT pg_temp.st(format('SELECT public._exos_api_membership_box_office(%L, %L, ''reserve'', %L, NULL, ''{"email":"q@x.com"}'')',
                           pg_temp.org('02'), pg_temp.u('f9'), m)) = 'P0002', 'NA9: API other org';
  r := public._exos_api_membership_box_office(pg_temp.org('01'), pg_temp.u('f1'), 'capacity.set', m, NULL, '{"capacity":5}');
  ASSERT (r ->> 'capacity')::int = 5, 'NA9: API capacity ' || r::text;
  r := public._exos_api_membership_box_office(pg_temp.org('01'), pg_temp.u('f1'), 'reserve', m, NULL, '{"email":"api@x.com"}');
  ASSERT (SELECT api_key_id = pg_temp.u('f1') AND created_by = pg_temp.u('a1') FROM public.exos_membership_reservations
           WHERE token = r ->> 'token'), 'NA9: API reservation';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_api_writes WHERE action = 'membership_reservation.reserve' AND result ? 'token'),
    'NA9: no token in the log';
  r := public._exos_api_membership_box_office(pg_temp.org('01'), pg_temp.u('f1'), 'complete', m, r ->> 'token', NULL);
  ASSERT r #>> '{membership,status}' = 'active', 'NA9: API complete';
  ASSERT (public._exos_api_membership_box_office(pg_temp.org('01'), pg_temp.u('f1'), 'capacity.set', m, NULL, '{"capacity":null}') ->> 'capacity') IS NULL,
    'NA9: back to unlimited';
  ASSERT pg_temp.st(format('SELECT public._exos_api_membership_box_office(%L, %L, ''reserve'', %L, NULL, ''{"email":"q@x.com"}'')',
                           pg_temp.org('01'), pg_temp.u('f3'), m)) = '42501', 'NA9: finance creator';
  -- RLS: finance reads the counter's record; the scanner doesn't.
  PERFORM pg_temp.act(pg_temp.u('a4'));
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_membership_reservations) >= 4, 'NA9: finance reads';
  RESET ROLE;
  PERFORM pg_temp.act(pg_temp.u('a3'));
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_membership_reservations) = 0, 'NA9: scanner reads';
  RESET ROLE;
  RAISE NOTICE 'OK NA9 membership reservations: capacity, one per email, sold out, cancel / expire free a place, complete once, cross-org, API';
END $$;

-- ── NA10 ────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; h text := repeat('ab', 32); ho text := repeat('cd', 32); v_app uuid; v_grant uuid;
BEGIN
  -- The manager's personal token, made in org 1.
  INSERT INTO public.exos_personal_tokens (user_id, org_id, name, key_prefix, key_hash, scopes)
  VALUES (pg_temp.u('a2'), pg_temp.org('01'), 'laptop', 'exos_pat_a9b', h, ARRAY['events:read','tickets:read','checkin:write','booking:write']);
  -- No header / the same org: unchanged.
  r := public.exos_api_token_auth_org(h, 'pat', pg_temp.org('01'));
  ASSERT r ->> 'org_id' = pg_temp.org('01')::text AND r ->> 'role' = 'manager' AND NOT (r ? 'home_org_id'), 'NA10: same org ' || r::text;
  ASSERT public.exos_api_token_auth_org(h, 'pat', NULL) ->> 'org_id' = pg_temp.org('01')::text, 'NA10: no header';
  -- Org 2, where the manager is a scanner: the scanner's scopes.
  r := public.exos_api_token_auth_org(h, 'pat', pg_temp.org('02'));
  ASSERT r ->> 'org_id' = pg_temp.org('02')::text AND r ->> 'home_org_id' = pg_temp.org('01')::text AND r ->> 'role' = 'scanner',
    'NA10: switched ' || r::text;
  ASSERT NOT (r -> 'scopes' ? 'booking:write') AND NOT (r -> 'scopes' ? 'booking:read') AND r -> 'scopes' ? 'checkin:write'
     AND r -> 'scopes' ? 'tickets:read', 'NA10: held to the scanner role ' || (r -> 'scopes')::text;
  -- Not a member there.
  ASSERT public.exos_api_token_auth_org(h, 'pat', gen_random_uuid()) ->> 'error' = 'not_member', 'NA10: not a member';
  -- Disabled there: not a member any more.
  UPDATE public.exos_org_memberships SET disabled = true WHERE org_id = pg_temp.org('02') AND user_id = pg_temp.u('a2');
  ASSERT public.exos_api_token_auth_org(h, 'pat', pg_temp.org('02')) ->> 'error' = 'not_member', 'NA10: disabled there';
  UPDATE public.exos_org_memberships SET disabled = false WHERE org_id = pg_temp.org('02') AND user_id = pg_temp.u('a2');
  -- An unknown token: NULL, as without the header.
  ASSERT public.exos_api_token_auth_org(repeat('ef', 32), 'pat', pg_temp.org('02')) IS NULL, 'NA10: unknown token';
  -- OAuth: pinned to the org the user approved.
  INSERT INTO public.exos_oauth_apps (client_id, name, redirect_uris, scopes, client_type, owner_uid)
  VALUES ('exos_app_a9b000000000000000000001', 'A9B App', ARRAY['https://x.com/cb'], ARRAY['events:read'], 'public', pg_temp.u('a2'))
  RETURNING id INTO v_app;
  INSERT INTO public.exos_oauth_grants (app_id, user_id, org_id, scopes)
  VALUES (v_app, pg_temp.u('a2'), pg_temp.org('01'), ARRAY['events:read']) RETURNING id INTO v_grant;
  INSERT INTO public.exos_oauth_tokens (token_hash, kind, app_id, grant_id, family_id, user_id, org_id, scopes, expires_at)
  VALUES (ho, 'access', v_app, v_grant, gen_random_uuid(), pg_temp.u('a2'), pg_temp.org('01'), ARRAY['events:read'], now() + interval '1 hour');
  ASSERT public.exos_api_token_auth_org(ho, 'oauth', pg_temp.org('01')) ->> 'org_id' = pg_temp.org('01')::text, 'NA10: oauth home';
  ASSERT public.exos_api_token_auth_org(ho, 'oauth', pg_temp.org('02')) ->> 'error' = 'org_switch', 'NA10: oauth pinned';
  RAISE NOTICE 'OK NA10 X-Exos-Org: a personal token acts in another org of its user at the role there; OAuth stays pinned';
END $$;

-- ── NA11 ────────────────────────────────────────────────────────────────────
INSERT INTO public.exos_pos_devices (id, org_id, name, status) VALUES
  ('a9b00000-0000-0000-0000-00000000dd01', 'a9b00000-0000-0000-0000-000000000001', 'Door phone', 'active'),
  ('a9b00000-0000-0000-0000-00000000dd02', 'a9b00000-0000-0000-0000-000000000001', 'Old phone', 'retired'),
  ('a9b00000-0000-0000-0000-00000000dd09', 'a9b00000-0000-0000-0000-000000000002', 'Their phone', 'active');
DO $$
DECLARE r jsonb; v_shift uuid;
BEGIN
  -- Any member clocks in (the scanner, at the door, on the door phone).
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_staff_clock_in(pg_temp.org('01'), pg_temp.u('e1'), 'a9b00000-0000-0000-0000-00000000dd01', 'doors');
  ASSERT (r ->> 'open')::boolean AND r ->> 'role' = 'scanner' AND r ->> 'event_id' = pg_temp.u('e1')::text, 'NA11: in ' || r::text;
  ASSERT pg_temp.st(format('SELECT public.exos_staff_clock_in(%L)', pg_temp.org('01'))) = '23505', 'NA11: one open shift';
  ASSERT pg_temp.st(format('SELECT public.exos_staff_clock_out(%L)', pg_temp.org('02'))) = 'P0002', 'NA11: not clocked in there';
  -- Another org's event or device, a retired device: refused.
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_staff_clock_in(%L, %L)', pg_temp.org('01'), pg_temp.u('e9'))) = 'P0002', 'NA11: their event';
  ASSERT pg_temp.st(format('SELECT public.exos_staff_clock_in(%L, NULL, %L)', pg_temp.org('01'), 'a9b00000-0000-0000-0000-00000000dd09')) = 'P0002',
    'NA11: their device';
  ASSERT pg_temp.st(format('SELECT public.exos_staff_clock_in(%L, NULL, %L)', pg_temp.org('01'), 'a9b00000-0000-0000-0000-00000000dd02')) = 'P0002',
    'NA11: retired device';
  -- Not a member.
  PERFORM pg_temp.act(pg_temp.u('c3'));
  ASSERT pg_temp.st(format('SELECT public.exos_staff_clock_in(%L)', pg_temp.org('01'))) = '42501', 'NA11: stranger';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_staff_clock_in(%L)', pg_temp.org('01'))) = '42501', 'NA11: signed out';
  -- Out.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_staff_clock_out(pg_temp.org('01'), 'done');
  ASSERT NOT (r ->> 'open')::boolean AND r ->> 'clock_out_note' = 'done', 'NA11: out ' || r::text;
  -- The finance member forgets to clock out; the manager closes it.
  PERFORM pg_temp.act(pg_temp.u('a4'));
  v_shift := (public.exos_staff_clock_in(pg_temp.org('01')) ->> 'id')::uuid;
  UPDATE public.exos_staff_shifts SET clock_in_at = now() - interval '9 hours' WHERE id = v_shift;
  ASSERT pg_temp.st(format('SELECT public.exos_staff_shift_close(%L, now(), ''forgot'')', v_shift)) = 'P0002', 'NA11: closes own';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_staff_shift_close(%L, now(), ''x'')', v_shift)) = '22023', 'NA11: reason';
  ASSERT pg_temp.st(format('SELECT public.exos_staff_shift_close(%L, now() - interval ''10 hours'', ''forgot'')', v_shift)) = '22023',
    'NA11: before clock-in';
  r := public.exos_staff_shift_close(v_shift, now() - interval '1 hour', 'forgot to clock out');
  ASSERT (r ->> 'minutes')::int = 480 AND r ->> 'closed_by' = pg_temp.u('a2')::text, 'NA11: closed ' || r::text;
  ASSERT pg_temp.st(format('SELECT public.exos_staff_shift_close(%L, now(), ''again'')', v_shift)) = '55000', 'NA11: closed twice';
  -- The report: owner / manager only.
  r := public.exos_staff_shift_report(pg_temp.org('01'), now() - interval '1 day', now() + interval '1 minute');
  ASSERT jsonb_array_length(r -> 'shifts') = 2 AND jsonb_array_length(r -> 'members') = 2
     AND (r #>> '{members,0,minutes}')::int = 480 AND r #>> '{members,0,email}' = 'a9b-finance@x.com', 'NA11: report ' || r::text;
  ASSERT pg_temp.st(format('SELECT public.exos_staff_shift_report(%L, now() - interval ''100 days'', now())', pg_temp.org('01'))) = '22023',
    'NA11: at most 92 days';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_staff_shift_report(%L)', pg_temp.org('01'))) = '42501', 'NA11: scanner reads the report';
  PERFORM pg_temp.act(pg_temp.u('b1'));
  ASSERT pg_temp.st(format('SELECT public.exos_staff_shift_report(%L)', pg_temp.org('01'))) = '42501', 'NA11: other org';
  ASSERT jsonb_array_length(public.exos_staff_shift_report(pg_temp.org('02')) -> 'shifts') = 0, 'NA11: their report is theirs';
  -- RLS: the scanner sees their own shifts, the manager all.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_staff_shifts) = 1, 'NA11: scanner sees own';
  RESET ROLE;
  PERFORM pg_temp.act(pg_temp.u('a2'));
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_staff_shifts) = 2, 'NA11: manager sees all';
  RESET ROLE;
  -- The API's internal calls take the org and user explicitly.
  r := public._exos_staff_clock_in(pg_temp.org('02'), pg_temp.u('a2'), NULL, NULL, NULL);
  ASSERT r ->> 'role' = 'scanner', 'NA11: internal clock-in at the role there';
  ASSERT pg_temp.st(format('SELECT public._exos_staff_clock_in(%L, %L, NULL, NULL, NULL)', pg_temp.org('02'), pg_temp.u('a3'))) = '42501',
    'NA11: internal, not a member';
  RAISE NOTICE 'OK NA11 staff shifts: members clock in once at a time on the org''s devices / events; corrections, report and RLS';
END $$;

-- ── NA12 ────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; p jsonb;
BEGIN
  ASSERT public._exos_tixel_ingest(pg_temp.org('01'), '{"action":"PURCHASE","user":{"email":"x@x.com"}}') ->> 'recorded' = 'false',
    'NA12: purchase ignored';
  ASSERT pg_temp.st(format('SELECT public._exos_tixel_ingest(%L, ''{"action":"WAITLIST","user":{}}'')', pg_temp.org('01'))) = '22023',
    'NA12: no email';
  ASSERT pg_temp.st(format('SELECT public._exos_tixel_ingest(%L, ''[]'')', pg_temp.org('01'))) = '22023', 'NA12: not an object';
  ASSERT pg_temp.st(format('SELECT public._exos_tixel_ingest(%L, ''{"action":"WAITLIST"}'')', gen_random_uuid())) = 'P0002', 'NA12: no org';
  -- A title that matches one upcoming event: on its waitlist.
  p := '{"action":"WAITLIST","metadata":{"eventTitle":"a9b tomorrow","href":"https://tixel.com/x"},"user":{"firstName":"Kim","lastName":"Ng","email":"Kim@X.com","marketingConsent":true}}';
  r := public._exos_tixel_ingest(pg_temp.org('01'), p);
  ASSERT (r ->> 'recorded')::boolean AND r ->> 'event_id' = pg_temp.u('e3')::text AND r ->> 'waitlist_id' IS NOT NULL, 'NA12: matched ' || r::text;
  ASSERT (SELECT email = 'kim@x.com' AND name = 'Kim Ng' AND status = 'waiting' AND meta ->> 'source' = 'tixel'
            FROM public.exos_waitlist WHERE id = (r ->> 'waitlist_id')::uuid), 'NA12: waitlist row';
  -- Redelivery: the same answer, nothing new.
  ASSERT (public._exos_tixel_ingest(pg_temp.org('01'), p) ->> 'replay')::boolean, 'NA12: replay';
  ASSERT (SELECT count(*) FROM public.exos_tixel_signups WHERE org_id = pg_temp.org('01')) = 1, 'NA12: once';
  -- Two events with the title, or none: kept, on no waitlist.
  r := public._exos_tixel_ingest(pg_temp.org('01'), '{"action":"WAITLIST","metadata":{"eventTitle":"A9B Twice"},"user":{"email":"t@x.com"}}');
  ASSERT r ->> 'event_id' IS NULL AND (r ->> 'recorded')::boolean, 'NA12: ambiguous ' || r::text;
  -- Another org's title isn't ours.
  r := public._exos_tixel_ingest(pg_temp.org('02'), '{"action":"WAITLIST","metadata":{"eventTitle":"A9B Tomorrow"},"user":{"email":"o@x.com"}}');
  ASSERT r ->> 'event_id' IS NULL, 'NA12: cross-org title';
  -- Consent is untouched: no fan row is changed or made.
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tixel_signups WHERE email = 'kim@x.com' AND matched_event_id IS NULL), 'NA12: one match';
  RAISE NOTICE 'OK NA12 Tixel: only WAITLIST, email required, one matching event''s waitlist, idempotent, ambiguous titles kept unmatched';
END $$;

-- ── NA13 ────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; t1 uuid; t2 uuid; t3 uuid; t4 uuid; i1 uuid; i2 uuid;
BEGIN
  INSERT INTO public.exos_tags (org_id, name, scope) VALUES (pg_temp.org('01'), 'VIP', NULL) RETURNING id INTO t1;
  INSERT INTO public.exos_tags (org_id, name, scope) VALUES (pg_temp.org('01'), 'Big spender', 'fan') RETURNING id INTO t2;
  INSERT INTO public.exos_tags (org_id, name, scope) VALUES (pg_temp.org('02'), 'Theirs', NULL) RETURNING id INTO t3;
  INSERT INTO public.exos_tags (org_id, name, scope) VALUES (pg_temp.org('01'), 'Comedy', 'event') RETURNING id INTO t4;
  i1 := (public._exos_tag_apply(pg_temp.org('01'), t1, NULL, 'event', pg_temp.u('e3')) ->> 'id')::uuid;
  i2 := (public._exos_tag_apply(pg_temp.org('01'), t1, NULL, 'event', pg_temp.u('e1')) ->> 'id')::uuid;
  -- A fan-only tag on an event: refused.
  ASSERT pg_temp.st(format('SELECT public._exos_tagged_item_retag(%L, %L, %L, NULL)', pg_temp.org('01'), i1, t2)) = '22023', 'NA13: scope';
  -- Another org's tag, another org's item.
  ASSERT pg_temp.st(format('SELECT public._exos_tagged_item_retag(%L, %L, %L, NULL)', pg_temp.org('01'), i1, t3)) = 'P0002', 'NA13: their tag';
  ASSERT pg_temp.st(format('SELECT public._exos_tagged_item_retag(%L, %L, %L, NULL)', pg_temp.org('02'), i1, t3)) = 'P0002', 'NA13: their item';
  -- Move e1's VIP to Comedy.
  r := public._exos_tagged_item_retag(pg_temp.org('01'), i2, t4, NULL);
  ASSERT r ->> 'tag_id' = t4::text AND (r ->> 'changed')::boolean AND r ->> 'id' = i2::text, 'NA13: moved ' || r::text;
  ASSERT NOT (public._exos_tagged_item_retag(pg_temp.org('01'), i2, t4, NULL) ->> 'changed')::boolean, 'NA13: same tag';
  -- By name: found or made with the item's type.
  r := public._exos_tagged_item_retag(pg_temp.org('01'), i1, NULL, 'Late show');
  ASSERT (SELECT scope FROM public.exos_tags WHERE id = (r ->> 'tag_id')::uuid) = 'event', 'NA13: made by name';
  -- Already tagged: e1 gets VIP again, then Comedy -> VIP collides.
  PERFORM public._exos_tag_apply(pg_temp.org('01'), t1, NULL, 'event', pg_temp.u('e1'));
  ASSERT pg_temp.st(format('SELECT public._exos_tagged_item_retag(%L, %L, %L, NULL)', pg_temp.org('01'), i2, t1)) = '23505', 'NA13: conflict';
  RAISE NOTICE 'OK NA13 tagged items move to another tag: scope checked, org pinned, a duplicate refused';
END $$;

\echo 'test_na_build: all passed'
ROLLBACK;
