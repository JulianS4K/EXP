-- ============================================================================
-- Static door codes (mig 20261121153000, docs/wallet.md "Static codes"):
--   ST1  grants: code_mode readable, never writable by clients; the new
--        functions internal; exos_mail_ticket_pdfs service-only; rows that
--        existed before the migration read 'rotating'
--   ST2  the mode is chosen at issuance with the fee's own rule: the cutoff
--        (read from exos_free_tier_max_capacity(), never a literal) is
--        static, cutoff + 1 rotates (over the cap, a cap over the cutoff,
--        or sold past it), exos_mint_tickets issues static,
--        an event that grows past the cutoff keeps its earlier tickets static
--        and rotates the later ones, an explicit 'static' is kept only on the
--        static-code path (refused on a paid event without it), and the mode
--        never changes after
--   ST3  the code: the SQL derivation equals _shared/staticCodes.ts on one
--        vector, canonical case, base32 vectors (RFC 4648)
--   ST4  the door: a static ticket's S- code checks in (verified), the second
--        scan gets the "already checked in" answer, a lower-case read works,
--        a rotating ticket's S- code, another ticket's, another holder's and a
--        malformed one are refused, the T- code still works, a typed S- code
--        counts as verified, a printed ticket refuses it, the older overload
--   ST5  void on transfer and refund: a started transfer refuses it, the
--        claim kills the old code and the new holder's works; a refund voids
--        it; the mode stays static
--   ST6  the roster can't mint: door_keys carry only the code's SHA-256 (no
--        code, no secret), a rotating ticket has none
--   ST7  offline: two phones admitted the same static code; the first upload
--        wins, the second is a 'used' conflict in the scan report
--   ST8  wallet payload (static_code for a static ticket only) and the ticket
--        link page (code_mode, the S- code)
--   ST9  the PDF in the email: a ticket-issued mail links the static tickets
--        its own transaction issued to that address once (not rotating, not
--        an earlier transaction's, not another mail's, never by the holding
--        account's email: an org owner's guest tickets stay out of the
--        owner's mail), the whole order (the PDF has 20), the drain rows carry
--        the code and the page fields but never the holding account's name, a
--        transfer drops it; the RSVP / partner mails' copy is patched
--   ST10 a leaked code: the holder's exos_ticket_static_reissue and
--        exos_wallet_reissue give a new secret (the old S- code refused, the
--        new one works); only the holder, only static, rate-limited
--   ST11 the wallet's reissue: a used or in-transfer static ticket gets no
--        new secret (and no new epoch), 3 a minute per holder, a rotating
--        ticket's reissue as before
-- Self-contained (BEGIN / ROLLBACK), prefix b5c. The free-tier setting is
-- removed inside the transaction, so the cutoff is the shipped default.
-- Two scans of one static code at once: tests/exos/race_static_codes.sh (CI).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- run_p0.sh turns the free tier off for the other suites; here it is the default.
DELETE FROM public.exos_platform_settings WHERE key = 'free_tier_max_capacity';

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('b5c00000-0000-0000-0000-0000000000a1', 'b5c-owner@x.com', now()),
  ('b5c00000-0000-0000-0000-0000000000a2', 'b5c-manager@x.com', now()),
  ('b5c00000-0000-0000-0000-0000000000c1', 'b5c-holder@x.com', now()),
  ('b5c00000-0000-0000-0000-0000000000c2', 'b5c-friend@x.com', now()),
  ('b5c00000-0000-0000-0000-0000000000c3', 'b5c-buyer@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('b5c00000-0000-0000-0000-000000000001', 'B5C Org', 'b5c-org', 'b5c00000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('b5c00000-0000-0000-0000-000000000001', 'b5c00000-0000-0000-0000-0000000000a1', 'owner'),
  ('b5c00000-0000-0000-0000-000000000001', 'b5c00000-0000-0000-0000-0000000000a2', 'manager');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('b5c00000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.ev(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('b5c00000-0000-0000-0000-00000000e0' || p)::uuid $$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true) $$;
-- An event of the org, doors open, with one ticket type: p_cap is the house
-- cap and the type's capacity (0 = neither capped: no max capacity).
CREATE FUNCTION pg_temp.mkevent(p text, p_cap int) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency,
                                  created_by, venue_name, venue_location)
  VALUES (pg_temp.ev(p), pg_temp.u('01'), 'B5C Show ' || p, 'b5c-show-' || p, 'published',
          now() - interval '1 hour', 'America/New_York', p_cap, 0, 'usd', pg_temp.u('a1'), 'The Room', 'Brooklyn, NY');
  INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity, sold, visibility, sort_order)
  VALUES (pg_temp.ev(p), 'GA', 10, p_cap, 0, 'public', 1);
  SELECT pg_temp.ev(p) $$;
-- Issue one ticket the way the mint does: the counter first, then the row
-- (no code_mode: the trigger decides). Returns the ticket id.
CREATE FUNCTION pg_temp.issue(p_event uuid, p_owner uuid DEFAULT NULL, p_mode text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_owner uuid := coalesce(p_owner, pg_temp.u('c1'));
BEGIN
  UPDATE public.exos_events SET tickets_sold = tickets_sold + 1 WHERE id = p_event;
  IF p_mode IS NULL THEN
    INSERT INTO public.exos_tickets (event_id, org_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret,
                                     price_paid, order_ref, channel_source)
    VALUES (p_event, (SELECT org_id FROM public.exos_events WHERE id = p_event), 'GA', v_owner, v_owner,
            (SELECT email FROM auth.users WHERE id = v_owner), 'active', 'sek-' || gen_random_uuid(), 10, 'b5c-order', 'vibepass')
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO public.exos_tickets (event_id, org_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret,
                                     price_paid, order_ref, channel_source, code_mode)
    VALUES (p_event, (SELECT org_id FROM public.exos_events WHERE id = p_event), 'GA', v_owner, v_owner,
            (SELECT email FROM auth.users WHERE id = v_owner), 'active', 'sek-' || gen_random_uuid(), 10, 'b5c-order', 'vibepass', p_mode)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;
CREATE FUNCTION pg_temp.mode(p_ticket uuid) RETURNS text LANGUAGE sql AS $$
  SELECT code_mode FROM public.exos_tickets WHERE id = p_ticket $$;
-- The ticket's static code for its current holder (what the app shows).
CREATE FUNCTION pg_temp.scode(p_ticket uuid) RETURNS text LANGUAGE sql AS $$
  SELECT public._exos_static_code(t.id, t.owner_id, t.barcode_secret) FROM public.exos_tickets t WHERE t.id = p_ticket $$;
CREATE FUNCTION pg_temp.tcode(p_ticket uuid) RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' || public._exos_door_code_mac(t.id, t.owner_id, b, t.barcode_secret)
    FROM public.exos_tickets t, (SELECT floor(extract(epoch FROM now()) * 1000 / 30000)::bigint AS b) x
   WHERE t.id = p_ticket $$;
-- Scan as the manager at the ticket's event.
CREATE FUNCTION pg_temp.scan(p_ticket uuid, p_code text, p_source text DEFAULT 'camera') RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a2'));
  RETURN public.exos_check_in_ticket(p_ticket, p_source, 'verified', p_code,
           (SELECT event_id FROM public.exos_tickets WHERE id = p_ticket), NULL, NULL, 'door-1', NULL, 'entry');
END $$;
CREATE TEMP TABLE b5 (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT v::uuid FROM b5 WHERE k = p_k $$;

-- ── ST1 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE f text;
BEGIN
  ASSERT has_column_privilege('authenticated', 'public.exos_tickets', 'code_mode', 'SELECT')
     AND NOT has_column_privilege('authenticated', 'public.exos_tickets', 'code_mode', 'UPDATE')
     AND NOT has_column_privilege('anon', 'public.exos_tickets', 'code_mode', 'SELECT'), 'ST1: code_mode grants';
  -- Rows that existed when the column was added read its default: rotating.
  ASSERT (SELECT atthasmissing AND attmissingval::text = '{rotating}' FROM pg_attribute
           WHERE attrelid = 'public.exos_tickets'::regclass AND attname = 'code_mode'), 'ST1: earlier tickets rotating';
  -- And a row written with triggers off (a restore): the default, rotating.
  ASSERT (SELECT column_default = '''rotating''::text' AND is_nullable = 'NO' FROM information_schema.columns
           WHERE table_schema = 'public' AND table_name = 'exos_tickets' AND column_name = 'code_mode'), 'ST1: default rotating, not null';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_mail_ticket_pdfs'::regclass), 'ST1: RLS';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_mail_ticket_pdfs', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_mail_ticket_pdfs', 'SELECT'), 'ST1: pdf links service-only';
  FOREACH f IN ARRAY ARRAY['public._exos_base32(bytea)', 'public._exos_static_code(uuid,uuid,text)',
      'public._exos_static_code_canon(text)', 'public._exos_static_code_check(uuid,uuid,text,text)',
      'public._exos_ticket_code_mode(uuid)', 'public.exos_mail_ticket_pdf_rows(uuid[])'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'ST1: internal ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_tg_ticket_code_mode()', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_tg_mail_ticket_pdfs()', 'EXECUTE'), 'ST1: trigger fns';
  ASSERT has_function_privilege('authenticated', 'public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)', 'EXECUTE'),
    'ST1: check-in grants kept';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_door_keys(uuid,uuid,text)', 'EXECUTE'), 'ST1: door keys internal';
  RAISE NOTICE 'OK ST1 grants; earlier tickets rotating; internal functions service-only';
END $$;

-- ── ST2 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_cut int := public.exos_free_tier_max_capacity();
  v_e uuid; v_t uuid; v_first uuid; v_ids uuid[]; v_tier uuid; i int;
BEGIN
  ASSERT v_cut > 1, 'ST2: a free tier to test (cutoff ' || v_cut || ')';
  -- An event capped at the cutoff: every ticket up to the cutoff is static.
  v_e := pg_temp.mkevent('01', v_cut);
  FOR i IN 1 .. v_cut LOOP
    v_t := pg_temp.issue(v_e);
    IF i = 1 THEN v_first := v_t; END IF;
  END LOOP;
  ASSERT (SELECT count(*) FILTER (WHERE code_mode = 'static') FROM public.exos_tickets WHERE event_id = v_e) = v_cut,
    'ST2: cutoff tickets static';
  ASSERT pg_temp.mode(v_t) = 'static', 'ST2: ticket number cutoff is static';
  -- Ticket cutoff + 1 (a comp past the cap): the event left the free tier with it.
  v_t := pg_temp.issue(v_e);
  ASSERT pg_temp.mode(v_t) = 'rotating', 'ST2: ticket cutoff + 1 rotates';
  ASSERT pg_temp.mode(v_first) = 'static', 'ST2: the earlier tickets stay static';
  -- A cap of cutoff + 1: rotating from the first ticket (the fee's rule: max capacity).
  v_e := pg_temp.mkevent('02', v_cut + 1);
  ASSERT pg_temp.mode(pg_temp.issue(v_e)) = 'rotating', 'ST2: cap cutoff + 1 rotates';
  -- Its size counts what it sold too: a small cap that sold past the cutoff.
  v_e := pg_temp.mkevent('03', 10);
  UPDATE public.exos_events SET tickets_sold = v_cut WHERE id = v_e;
  ASSERT pg_temp.mode(pg_temp.issue(v_e)) = 'rotating', 'ST2: sold past the cutoff rotates';
  -- The mint RPC (an issuance path with a ticket type): static on a small event.
  v_e := pg_temp.mkevent('04', 10);
  SELECT id INTO v_tier FROM public.exos_ticket_tiers WHERE event_id = v_e;
  PERFORM pg_temp.act(pg_temp.u('a1'));
  v_ids := public.exos_mint_tickets(v_e, v_tier, 2, 'b5c-mint', 10, NULL);
  ASSERT (SELECT bool_and(code_mode = 'static') AND count(*) = 2 FROM public.exos_tickets WHERE id = ANY (v_ids)), 'ST2: mint static';
  -- Growth: the cap is raised past the cutoff; the next ticket rotates, the
  -- two issued before stay static.
  UPDATE public.exos_events SET total_tickets = v_cut + 50 WHERE id = v_e;
  UPDATE public.exos_ticket_tiers SET capacity = v_cut + 50 WHERE id = v_tier;
  v_t := (public.exos_mint_tickets(v_e, v_tier, 1, 'b5c-mint-2', 10, NULL))[1];
  ASSERT pg_temp.mode(v_t) = 'rotating', 'ST2: after growth rotates';
  ASSERT (SELECT bool_and(code_mode = 'static') FROM public.exos_tickets WHERE id = ANY (v_ids)), 'ST2: growth keeps earlier static';
  -- An explicit 'static' (the BYO marketplace's allocated PDF tickets) is kept
  -- only on the static-code path (exos.static_code_ok for the transaction);
  -- without it, refused on a paid event and simply the rule on a free one.
  PERFORM set_config('exos.static_code_ok', 'on', true);
  ASSERT pg_temp.mode(pg_temp.issue(pg_temp.ev('02'), NULL, 'static')) = 'static', 'ST2: explicit static kept on the path';
  PERFORM set_config('exos.static_code_ok', '', true);
  ASSERT pg_temp.st(format('SELECT pg_temp.issue(%L, NULL, %L)', pg_temp.ev('02'), 'static')) = '42501',
    'ST2: explicit static refused on a paid event';
  PERFORM set_config('exos.static_code_ok', 'yes', true);
  ASSERT pg_temp.st(format('SELECT pg_temp.issue(%L, NULL, %L)', pg_temp.ev('02'), 'static')) = '42501',
    'ST2: only ''on'' opens the path';
  PERFORM set_config('exos.static_code_ok', '', true);
  ASSERT pg_temp.mode(pg_temp.issue(pg_temp.mkevent('11', 5), NULL, 'static')) = 'static', 'ST2: explicit on a free event';
  -- The rule runs VOLATILE under a per-event lock (two orders at the boundary: race_static_codes.sh).
  ASSERT (SELECT provolatile FROM pg_proc WHERE oid = 'public._exos_ticket_code_mode(uuid)'::regprocedure) = 'v',
    'ST2: the rule sees each statement''s commits';
  -- And the mode never changes after issuance.
  ASSERT pg_temp.st(format('UPDATE public.exos_tickets SET code_mode = %L WHERE id = %L', 'rotating', v_first)) = '55000',
    'ST2: mode locked';
  ASSERT pg_temp.st(format('UPDATE public.exos_tickets SET code_mode = %L WHERE id = %L', 'bogus', v_first)) IN ('55000', '23514'),
    'ST2: bad mode';
  INSERT INTO b5 VALUES ('static', v_first), ('rotating', v_t);
  RAISE NOTICE 'OK ST2 mode at issuance: cutoff % static, % rotating, sold past rotating, mint static, growth keeps earlier static, explicit static only on its path, locked', v_cut, v_cut + 1;
END $$;

-- ── ST3 ─────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- The vector src/lib/staticCodes.test.ts pins for the TypeScript side.
  ASSERT public._exos_static_code('0b5e1c2a-0000-4000-8000-000000000001', '0b5e1c2a-0000-4000-8000-0000000000c1', 'sek-vector')
       = 'S-0b5e1c2a-0000-4000-8000-000000000001:ZW5XLXNZPIYH54TJQQPNWMLXV37RBE2T', 'ST3: vector';
  ASSERT public._exos_static_code('0b5e1c2a-0000-4000-8000-000000000001', NULL, '') IS NULL, 'ST3: no secret, no code';
  ASSERT public._exos_base32(convert_to('fooba', 'UTF8')) = 'MZXW6YTB'
     AND public._exos_base32('\x0000000000ffffffffff'::bytea) = 'AAAAAAAA77777777', 'ST3: base32 vectors';
  ASSERT public._exos_static_code_canon(' s-0B5E1C2A-0000-4000-8000-000000000001:zw5xlxnzpiyh54tjqqpnwmlxv37rbe2t ')
       = 'S-0b5e1c2a-0000-4000-8000-000000000001:ZW5XLXNZPIYH54TJQQPNWMLXV37RBE2T', 'ST3: canonical';
  ASSERT public._exos_static_code_canon('S-0b5e1c2a-0000-4000-8000-000000000001:ZW5XLXNZPIYH54TJQQPNWMLXV37RBE21') IS NULL
     AND public._exos_static_code_canon('T-0b5e1c2a-0000-4000-8000-000000000001:ZW5XLXNZPIYH54TJQQPNWMLXV37RBE2T') IS NULL
     AND public._exos_static_code_canon('S-0b5e1c2a-0000-4000-8000-000000000001:x:1:ZW5XLXNZ') IS NULL, 'ST3: other shapes';
  RAISE NOTICE 'OK ST3 the code: SQL = TS vector, base32, canonical case, other shapes refused';
END $$;

-- ── ST4 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_e uuid := pg_temp.mkevent('05', 20);
  a uuid := pg_temp.issue(v_e); b uuid := pg_temp.issue(v_e); c uuid := pg_temp.issue(v_e);
  d uuid := pg_temp.issue(v_e); f uuid := pg_temp.issue(v_e); g uuid := pg_temp.issue(v_e);
  rot uuid := pg_temp.issue(pg_temp.ev('02'));
  r jsonb; v_code text;
BEGIN
  ASSERT pg_temp.mode(a) = 'static' AND pg_temp.mode(rot) = 'rotating', 'ST4: fixtures';
  v_code := pg_temp.scode(a);
  ASSERT v_code ~ ('^S-' || a || ':[A-Z2-7]{32}$'), 'ST4: shape ' || v_code;
  r := pg_temp.scan(a, v_code);
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'verified')::boolean, 'ST4: first scan ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = a) = 'used', 'ST4: used';
  -- The second scan of the same code: the existing "already checked in" answer.
  r := pg_temp.scan(a, v_code);
  ASSERT r ->> 'reason' = 'used' AND NOT (r ->> 'ok')::boolean AND r ? 'check_in_at', 'ST4: second scan ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = a AND direction = 'entry') = 1, 'ST4: one admission';
  -- A scanner that changes case.
  r := pg_temp.scan(b, lower(pg_temp.scode(b)));
  ASSERT r ->> 'reason' = 'checked-in', 'ST4: lower-case read ' || r::text;
  -- A rotating ticket's S- code (derived the same way) is refused: no static mode.
  ASSERT pg_temp.scan(rot, pg_temp.scode(rot)) ->> 'reason' = 'barcode-rejected', 'ST4: rotating S- refused';
  ASSERT pg_temp.scan(rot, pg_temp.tcode(rot)) ->> 'reason' = 'checked-in', 'ST4: rotating T- works';
  -- Another ticket's code on this ticket; another holder's; a malformed one.
  ASSERT pg_temp.scan(c, pg_temp.scode(d)) ->> 'reason' = 'barcode-rejected', 'ST4: another ticket';
  ASSERT pg_temp.scan(c, 'S-' || c || ':' || split_part(pg_temp.scode(d), ':', 2)) ->> 'reason' = 'barcode-rejected', 'ST4: another tail';
  ASSERT pg_temp.scan(c, public._exos_static_code(c, pg_temp.u('c2'), (SELECT barcode_secret FROM public.exos_tickets WHERE id = c)))
           ->> 'reason' = 'barcode-rejected', 'ST4: another holder';
  ASSERT pg_temp.scan(c, 'S-' || c || ':ABC') ->> 'reason' = 'barcode-rejected', 'ST4: malformed';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c) = 'active', 'ST4: refusals leave it active';
  -- The rotating code still opens a static ticket (an app that hasn't reloaded).
  ASSERT pg_temp.scan(c, pg_temp.tcode(c)) ->> 'reason' = 'checked-in', 'ST4: T- on a static ticket';
  -- Typed at the door (the printed string): verified, not an override.
  r := pg_temp.scan(d, pg_temp.scode(d), 'manual');
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'verified')::boolean, 'ST4: typed ' || r::text;
  -- A printed ticket admits on its paper only.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  PERFORM public.exos_ticket_print(ARRAY[f]);
  ASSERT pg_temp.scan(f, pg_temp.scode(f)) ->> 'reason' = 'printed', 'ST4: printed';
  -- The older overload (no lists).
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_check_in_ticket(g, 'camera', 'verified', pg_temp.scode(g), v_e, NULL, NULL, 'door-1');
  ASSERT r ->> 'reason' = 'checked-in', 'ST4: older overload ' || r::text;
  r := public.exos_check_in_ticket(g, 'camera', 'verified', pg_temp.scode(g), v_e, NULL, NULL, 'door-1');
  ASSERT r ->> 'reason' = 'used', 'ST4: older overload second ' || r::text;
  RAISE NOTICE 'OK ST4 the door: first scan wins, second used, case, rotating S- refused, other ticket / holder / malformed refused, T- kept, typed verified, printed, older overload';
END $$;

-- ── ST5 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_e uuid := pg_temp.mkevent('06', 20);
  a uuid := pg_temp.issue(v_e); b uuid := pg_temp.issue(v_e);
  v_old text; v_tr uuid;
BEGIN
  v_old := pg_temp.scode(a);
  PERFORM pg_temp.act(pg_temp.u('c1'));
  v_tr := public.exos_create_transfer(a, 'b5c-friend@x.com', 'Friend');
  ASSERT pg_temp.scan(a, v_old) ->> 'reason' = 'in-transfer', 'ST5: transfer started';
  PERFORM pg_temp.act(pg_temp.u('c2'));
  PERFORM public.exos_test_claim(v_tr);
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = a) = pg_temp.u('c2'), 'ST5: claimed';
  ASSERT pg_temp.mode(a) = 'static', 'ST5: mode kept';
  ASSERT pg_temp.scode(a) <> v_old, 'ST5: a new code';
  ASSERT pg_temp.scan(a, v_old) ->> 'reason' = 'barcode-rejected', 'ST5: the old code is dead';
  ASSERT pg_temp.scan(a, pg_temp.scode(a)) ->> 'reason' = 'checked-in', 'ST5: the new holder''s code';
  -- A refund voids the ticket, and the code with it.
  v_old := pg_temp.scode(b);
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_void_ticket(b, 'refunded');
  ASSERT pg_temp.scan(b, v_old) ->> 'reason' = 'voided', 'ST5: refunded';
  RAISE NOTICE 'OK ST5 transfer started refuses, the claim kills the old code (new one works), a refund voids it';
END $$;

-- ── ST6 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_e uuid := pg_temp.mkevent('07', 20);
  a uuid := pg_temp.issue(v_e);
  rot uuid := pg_temp.issue(pg_temp.ev('02'));
  k jsonb; v_code text := pg_temp.scode(a); v_row text;
BEGIN
  k := (SELECT public._exos_door_keys(t.id, t.owner_id, t.barcode_secret) FROM public.exos_tickets t WHERE t.id = a);
  ASSERT k ->> 's' = encode(extensions.digest(v_code, 'sha256'), 'hex'), 'ST6: s is the hash ' || k::text;
  ASSERT (SELECT public._exos_door_keys(t.id, t.owner_id, t.barcode_secret) FROM public.exos_tickets t WHERE t.id = rot) ? 's' = false,
    'ST6: no s for rotating';
  -- What a door phone downloads: no code, no secret, nothing that is a code.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  SELECT r::text INTO v_row FROM public.exos_event_door_roster(v_e) r WHERE r.ticket_id = a;
  ASSERT v_row IS NOT NULL AND position(split_part(v_code, ':', 2) IN v_row) = 0
     AND position((SELECT barcode_secret FROM public.exos_tickets WHERE id = a) IN v_row) = 0
     AND v_row !~ 'S-[0-9a-f-]{36}:[A-Z2-7]{32}', 'ST6: roster holds no code / secret';
  ASSERT position(k ->> 's' IN v_row) > 0, 'ST6: roster carries the hash';
  -- The hash is not a code: the door refuses it as one.
  ASSERT pg_temp.scan(a, 'S-' || a || ':' || upper(left(k ->> 's', 32))) ->> 'reason' = 'barcode-rejected', 'ST6: hash as code';
  -- The single-ticket door read carries it too.
  ASSERT public.exos_door_ticket_keys(a) ->> 's' = k ->> 's', 'ST6: exos_door_ticket_keys';
  RAISE NOTICE 'OK ST6 the roster carries only the SHA-256 (can''t mint), none for rotating';
END $$;

-- ── ST7 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_e uuid := pg_temp.mkevent('08', 20);
  a uuid := pg_temp.issue(v_e);
  v_code text := pg_temp.scode(a); r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_check_in_offline(gen_random_uuid(), a, v_e, now() - interval '2 minutes', v_code, 'camera', NULL, 'door-2', NULL, 'entry');
  ASSERT r ->> 'reason' = 'checked-in', 'ST7: first upload ' || r::text;
  r := public.exos_check_in_offline(gen_random_uuid(), a, v_e, now() - interval '1 minute', v_code, 'camera', NULL, 'door-3', NULL, 'entry');
  ASSERT (r ->> 'conflict')::boolean AND r ->> 'reason' = 'used', 'ST7: second phone ' || r::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_scan_rejects WHERE ticket_id_attempted = a::text AND reason = 'used'), 'ST7: scan report used';
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = a AND direction = 'entry') = 1, 'ST7: one admission';
  RAISE NOTICE 'OK ST7 offline: first upload wins, the second is a used conflict';
END $$;

-- ── ST8 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_e uuid := pg_temp.mkevent('09', 20);
  a uuid := pg_temp.issue(v_e);
  rot uuid := pg_temp.issue(pg_temp.ev('02'));
  p jsonb; v_key text;
BEGIN
  INSERT INTO public.exos_wallet_passes (serial_number, ticket_id, owner_id)
  SELECT 'exw' || md5(t.id::text), t.id, t.owner_id FROM public.exos_tickets t WHERE t.id IN (a, rot);
  p := public._exos_wallet_payload('exw' || md5(a::text));
  ASSERT p ->> 'static_code' = pg_temp.scode(a) AND p ->> 'apple_code' IS NOT NULL, 'ST8: static pass ' || (p ->> 'static_code');
  p := public._exos_wallet_payload('exw' || md5(rot::text));
  ASSERT p ->> 'static_code' IS NULL AND p ->> 'google_key_hex' IS NOT NULL, 'ST8: rotating pass';
  -- The ticket link page.
  v_key := (SELECT public._exos_ticket_link_key(t.id, t.owner_id, t.barcode_secret) FROM public.exos_tickets t WHERE t.id = a);
  p := public.exos_ticket_link_view(a, v_key);
  ASSERT p ->> 'code_mode' = 'static' AND p ->> 'code' = pg_temp.scode(a), 'ST8: link view ' || p::text;
  v_key := (SELECT public._exos_ticket_link_key(t.id, t.owner_id, t.barcode_secret) FROM public.exos_tickets t WHERE t.id = rot);
  p := public.exos_ticket_link_view(rot, v_key);
  ASSERT p ->> 'code_mode' = 'rotating' AND p ->> 'code' LIKE 'T-%', 'ST8: link view rotating';
  RAISE NOTICE 'OK ST8 wallet payload and ticket link carry the static code for static tickets only';
END $$;

-- ── ST9 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_e uuid := pg_temp.mkevent('10', 20);
  a uuid := pg_temp.issue(v_e, pg_temp.u('c3')); b uuid := pg_temp.issue(v_e, pg_temp.u('c3'));
  old uuid := pg_temp.issue(v_e, pg_temp.u('c3'));
  rot uuid := pg_temp.issue(pg_temp.ev('02'), pg_temp.u('c3'));
  m1 uuid; m2 uuid; r jsonb; v_tr uuid; g uuid; i int;
BEGIN
  -- Issued in an earlier transaction (triggers off, so updated_at stays as set).
  SET LOCAL session_replication_role = replica;
  UPDATE public.exos_tickets SET created_at = now() - interval '1 hour', updated_at = now() - interval '1 hour' WHERE id = old;
  SET LOCAL session_replication_role = origin;
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('ticket-issued', 'b5c-buyer@x.com', 'Your tickets', '<p>ready</p>', 'pending') RETURNING id INTO m1;
  ASSERT (SELECT array_agg(ticket_id ORDER BY ticket_id) FROM public.exos_mail_ticket_pdfs WHERE mail_id = m1)
       @> ARRAY[a, b] AND NOT EXISTS (SELECT 1 FROM public.exos_mail_ticket_pdfs WHERE ticket_id IN (old, rot)), 'ST9: linked';
  -- A second mail (the app's own "ticket ready") doesn't carry them again.
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('ticket-issued', 'b5c-buyer@x.com', 'Ready', '<p>ready</p>', 'pending') RETURNING id INTO m2;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail_ticket_pdfs WHERE mail_id = m2 AND ticket_id IN (a, b)), 'ST9: once';
  -- Another template carries none.
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('event-updated', 'b5c-buyer@x.com', 'Changed', '<p>x</p>', 'pending') RETURNING id INTO m2;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail_ticket_pdfs WHERE mail_id = m2), 'ST9: ticket mails only';
  -- The drain's rows: the code and the page fields.
  SELECT ticket INTO r FROM public.exos_mail_ticket_pdf_rows(ARRAY[m1]) WHERE ticket ->> 'ticket_id' = a::text;
  ASSERT r ->> 'print_code' = pg_temp.scode(a) AND r ->> 'event_name' = 'B5C Show 10' AND r ->> 'venue_name' = 'The Room'
     AND r ->> 'tier_name' = 'GA' AND r ->> 'org_name' = 'B5C Org', 'ST9: rows ' || r::text;
  -- Transferred before the mail went out: not in the PDF.
  PERFORM pg_temp.act(pg_temp.u('c3'));
  v_tr := public.exos_create_transfer(b, 'b5c-friend@x.com', 'Friend');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail_ticket_pdf_rows(ARRAY[m1]) x WHERE x.ticket ->> 'ticket_id' = b::text), 'ST9: in transfer';
  PERFORM pg_temp.act(pg_temp.u('c2'));
  PERFORM public.exos_test_claim(v_tr);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail_ticket_pdf_rows(ARRAY[m1]) x WHERE x.ticket ->> 'ticket_id' = b::text), 'ST9: transferred';
  ASSERT (SELECT count(*) FROM public.exos_mail_ticket_pdf_rows(ARRAY[m1])) = 1, 'ST9: one left';
  -- A partner / RSVP ticket: held by the org owner for a guest. The guest's
  -- mail carries it, with no name rather than the owner's; the owner's own
  -- mail never does.
  INSERT INTO public.exos_profiles (id, display_name) VALUES (pg_temp.u('a1'), 'Org Owner Name')
  ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;
  g := pg_temp.issue(v_e, pg_temp.u('a1'));
  UPDATE public.exos_tickets SET buyer_email = 'b5c-guest@x.com', attendee_name = NULL WHERE id = g;
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('ticket-issued', 'b5c-owner@x.com', 'Your own', '<p>x</p>', 'pending') RETURNING id INTO m2;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail_ticket_pdfs WHERE mail_id = m2 AND ticket_id = g), 'ST9: not in the owner''s mail';
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('ticket-issued', 'b5c-guest@x.com', 'Your ticket', '<p>x</p>', 'pending') RETURNING id INTO m2;
  SELECT ticket INTO r FROM public.exos_mail_ticket_pdf_rows(ARRAY[m2]) WHERE ticket ->> 'ticket_id' = g::text;
  ASSERT r IS NOT NULL AND r ->> 'attendee_name' IS NULL AND position('Org Owner' IN r::text) = 0, 'ST9: no owner name ' || r::text;
  -- An order of 25: all linked to its own mail (the PDF has 20, the mail says
  -- where the rest are); a later mail to the same address carries none.
  FOR i IN 1 .. 25 LOOP PERFORM pg_temp.issue(v_e, pg_temp.u('c2')); END LOOP;
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('ticket-issued', 'b5c-friend@x.com', 'Your 25', '<p>x</p>', 'pending') RETURNING id INTO m2;
  ASSERT (SELECT count(*) FROM public.exos_mail_ticket_pdf_rows(ARRAY[m2])) >= 25, 'ST9: the whole order';
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('ticket-issued', 'b5c-friend@x.com', 'Later', '<p>x</p>', 'pending') RETURNING id INTO m1;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail_ticket_pdfs WHERE mail_id = m1), 'ST9: none ride on a later mail';
  -- The two mails that promised a rotating code know about static ones.
  ASSERT position('/* exos: static codes */' IN pg_get_functiondef('public.exos_phone_rsvp_verify(uuid,text,text)'::regprocedure)) > 0
     AND position('/* exos: static codes */' IN pg_get_functiondef('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)'::regprocedure)) > 0,
    'ST9: copy patched';
  RAISE NOTICE 'OK ST9 the PDF: linked once to its own transaction''s tickets, buyer email only (never the owner''s), no owner name, the whole order, drain rows, transfer drops it, copy patched';
END $$;

-- ── ST10 ────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_e uuid := pg_temp.mkevent('12', 20);
  a uuid := pg_temp.issue(v_e); b uuid := pg_temp.issue(v_e);
  rot uuid := pg_temp.issue(pg_temp.ev('02'));
  v_old text; v_old_b text; i int; v_st text;
BEGIN
  v_old := pg_temp.scode(a);
  PERFORM pg_temp.act(pg_temp.u('c2'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_static_reissue(%L)', a)) = 'P0002', 'ST10: not the holder';
  PERFORM pg_temp.act(pg_temp.u('c1'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_static_reissue(%L)', rot)) = '22023', 'ST10: a rotating ticket';
  ASSERT (public.exos_ticket_static_reissue(a) ->> 'ok')::boolean, 'ST10: reissued';
  ASSERT pg_temp.scode(a) <> v_old, 'ST10: a new code';
  ASSERT pg_temp.scan(a, v_old) ->> 'reason' = 'barcode-rejected', 'ST10: the old code is refused';
  -- The wallet's "my pass was screenshotted" does the same for a static ticket.
  v_old_b := pg_temp.scode(b);
  INSERT INTO public.exos_wallet_passes (serial_number, ticket_id, owner_id)
  SELECT 'exw' || md5(t.id::text || 'st10'), t.id, t.owner_id FROM public.exos_tickets t WHERE t.id = b;
  PERFORM pg_temp.act(pg_temp.u('c1'));
  ASSERT (public.exos_wallet_reissue(b) ->> 'ok')::boolean, 'ST10: wallet reissue';
  ASSERT pg_temp.scan(b, v_old_b) ->> 'reason' = 'barcode-rejected', 'ST10: the old code after a wallet reissue';
  ASSERT public._exos_wallet_payload('exw' || md5(b::text || 'st10')) ->> 'static_code' = pg_temp.scode(b), 'ST10: the pass has the new one';
  ASSERT pg_temp.scan(b, pg_temp.scode(b)) ->> 'reason' = 'checked-in', 'ST10: the new code works';
  ASSERT pg_temp.scan(a, pg_temp.scode(a)) ->> 'reason' = 'checked-in', 'ST10: the reissued one works';
  -- Used now: no new code for it. And at most 3 a minute per holder.
  PERFORM pg_temp.act(pg_temp.u('c1'));
  ASSERT pg_temp.st(format('SELECT public.exos_ticket_static_reissue(%L)', a)) = '55000', 'ST10: used';
  FOR i IN 1 .. 3 LOOP
    v_st := pg_temp.st(format('SELECT public.exos_ticket_static_reissue(%L)', pg_temp.issue(v_e)));
  END LOOP;
  ASSERT v_st = '54000', 'ST10: rate limit ' || v_st;
  ASSERT NOT has_function_privilege('anon', 'public.exos_ticket_static_reissue(uuid)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.exos_ticket_static_reissue(uuid)', 'EXECUTE'), 'ST10: grants';
  RAISE NOTICE 'OK ST10 a leaked code: holder reissue and wallet reissue give a new code; holder only, static only, rate-limited';
END $$;

-- ── ST11 ────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_e uuid := pg_temp.mkevent('13', 20);
  used_t uuid := pg_temp.issue(v_e); xfer_t uuid := pg_temp.issue(v_e); late_t uuid := pg_temp.issue(v_e);
  rot uuid := pg_temp.issue(pg_temp.ev('02'), pg_temp.u('c2'));
  v_sec text; v_ep int; r jsonb;
BEGIN
  INSERT INTO public.exos_wallet_passes (serial_number, ticket_id, owner_id)
  SELECT 'exw' || md5(t.id::text || 'st11'), t.id, t.owner_id FROM public.exos_tickets t WHERE t.id IN (used_t, xfer_t, late_t, rot);
  -- Used: no new secret, no new pass epoch (ST10 spent 1 of c1's 3 this minute).
  ASSERT pg_temp.scan(used_t, pg_temp.scode(used_t)) ->> 'reason' = 'checked-in', 'ST11: checked in';
  v_sec := (SELECT barcode_secret FROM public.exos_tickets WHERE id = used_t);
  PERFORM pg_temp.act(pg_temp.u('c1'));
  r := public.exos_wallet_reissue(used_t);
  ASSERT r ->> 'reason' = 'not-active', 'ST11: used refused ' || r;
  ASSERT (SELECT barcode_secret FROM public.exos_tickets WHERE id = used_t) = v_sec, 'ST11: used keeps its secret';
  ASSERT (SELECT code_epoch FROM public.exos_wallet_passes WHERE ticket_id = used_t) = 1, 'ST11: used keeps its epoch';
  -- Being transferred: the same.
  PERFORM public.exos_create_transfer(xfer_t, 'b5c-friend11@x.com', 'Friend');
  v_sec := (SELECT barcode_secret FROM public.exos_tickets WHERE id = xfer_t);
  r := public.exos_wallet_reissue(xfer_t);
  ASSERT r ->> 'reason' = 'not-active', 'ST11: in transfer refused ' || r;
  ASSERT (SELECT barcode_secret FROM public.exos_tickets WHERE id = xfer_t) = v_sec, 'ST11: in transfer keeps its secret';
  -- The fourth this minute: rate-limited, nothing changes.
  v_sec := (SELECT barcode_secret FROM public.exos_tickets WHERE id = late_t);
  r := public.exos_wallet_reissue(late_t);
  ASSERT r ->> 'reason' = 'rate-limited', 'ST11: rate limit ' || r;
  ASSERT (SELECT barcode_secret FROM public.exos_tickets WHERE id = late_t) = v_sec, 'ST11: rate-limited keeps its secret';
  ASSERT (SELECT code_epoch FROM public.exos_wallet_passes WHERE ticket_id = late_t) = 1, 'ST11: rate-limited keeps its epoch';
  -- A rotating ticket: the status guard is for static codes only (its pass
  -- epoch still moves once it is used); its holder has their own 3.
  UPDATE public.exos_tickets SET status = 'used' WHERE id = rot;
  PERFORM pg_temp.act(pg_temp.u('c2'));
  r := public.exos_wallet_reissue(rot);
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'code_epoch')::int = 2, 'ST11: rotating reissue ' || r;
  RAISE NOTICE 'OK ST11 wallet reissue: a used or in-transfer static ticket keeps its secret, 3 a minute per holder, rotating unchanged';
END $$;

ROLLBACK;
