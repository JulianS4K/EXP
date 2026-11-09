-- ============================================================================
-- DICE leftovers (mig 20261108110000). Self-contained (dl… ids), rolled back.
--   DL0 shape: RLS on the new tables, clients read only, no anon grant;
--       internal functions service-role only; the client RPCs are
--       authenticated; search_path pinned; every patch marker in place
--       (and the earlier ones kept)
--   DL1 walk-up questions: a required per-order and per-ticket question is
--       required at the door (22023 'questions-required', nothing sold); a
--       "show only if" child is required only when shown; a question hidden
--       from checkout is never required; answers attach to the minted
--       tickets like online ones (source door); the explicit skip sells,
--       keeps what was given and logs who skipped which questions (once per
--       sale, nothing when nothing was missing); the flag never outlives the
--       call; the card begin takes the same flag; RLS on the log
--   DL2 POST fee adjustments (API core): an owner / manager / finance key
--       records, a scanner's key or a revoked key can't; an idempotency key
--       is required, a resend is one row, the same key for another change is
--       refused; never below zero; another org's order is not found (nothing
--       echoed); the actor and key are on the row
--   DL3 undo an add-on scan, online: the scanner who scanned it, within 10
--       minutes; another scanner or after the window needs a manager; owner /
--       manager any time; a reason; wrong event; not checked in; voided;
--       finance / outsider / another org's staff 42501; the pass scans again;
--       the audit row keeps the removed scans
--   DL4 undo, offline merge: the same client ref twice is one undo; a ref
--       used for another pass is refused; only scans at or before the undo
--       go (a later entry stands, the pass stays used); an undo time in the
--       future or over a day old is refused
--   DL5 add-on wallet codes: only the holder gets a pass (epoch issued once);
--       a voided pass gets none; the Apple and Google codes scan at the
--       add-on's list (online and offline replay); a code before the pass is
--       issued, of another epoch, forged, or after a new owner is refused; the
--       door keys carry wa / wg / we; another org's scanner 42501; the code
--       derivations match src/lib/wallet/addonPass.test.ts (same vectors)
-- Users: oa owner A, ma manager A, fa finance A, sa / sb scanners A, ob owner
--        B, sx scanner B, x1 outsider, b1 / b2 buyers.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid PRIMARY KEY, display_name text);

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT md5('dl:' || p)::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '{"email":"door@x.com"}', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
-- SQLSTATE (+ message, + hint) of a statement ('ok' when it ran).
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_hint text;
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  RETURN SQLSTATE || ' ' || SQLERRM || ' [' || coalesce(v_hint, '') || ']';
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO anon, authenticated;
-- A walk-up sale (13 arguments: the skip flag).
CREATE FUNCTION pg_temp.sell(p_actor text, p_qty int, p_key text, p_answers jsonb DEFAULT NULL, p_skip boolean DEFAULT false,
                             p_tier text DEFAULT 'tw') RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u(p_actor));
  RETURN public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u(p_tier), p_qty, pg_temp.u(p_key), 0, 'cash', NULL,
                                     pg_temp.u('dr'), 'Walk Up', NULL, p_answers, NULL, p_skip);
END $$;
-- An add-on code (the holder's app, 30-second buckets).
CREATE FUNCTION pg_temp.acode(p_pass uuid, p_at timestamptz DEFAULT now()) RETURNS text LANGUAGE sql AS $$
  SELECT 'A-' || p.id || ':' || p.owner_id || ':' || b || ':' || public._exos_door_code_mac(p.id, p.owner_id, b, p.barcode_secret)
    FROM public.exos_addon_passes p, (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint AS b) x
   WHERE p.id = p_pass
$$;
-- The wallet codes of a pass at an epoch (what the pass shows).
CREATE FUNCTION pg_temp.wapple(p_pass uuid, p_epoch int DEFAULT 1) RETURNS text LANGUAGE sql AS $$
  SELECT public._exos_addon_wallet_apple_code(p.id, p.owner_id, p.barcode_secret, p_epoch) FROM public.exos_addon_passes p WHERE p.id = p_pass
$$;
CREATE FUNCTION pg_temp.wgoogle(p_pass uuid, p_at timestamptz DEFAULT now(), p_epoch int DEFAULT 1) RETURNS text LANGUAGE sql AS $$
  SELECT 'A-' || p.id || ':' || p.owner_id || ':g' || p_epoch || ':'
         || public._exos_wallet_totp(public._exos_wallet_google_key(p.id, p.owner_id, p.barcode_secret, p_epoch),
                                     floor(extract(epoch FROM p_at) / 30)::bigint)
    FROM public.exos_addon_passes p WHERE p.id = p_pass
$$;
CREATE FUNCTION pg_temp.scan(p_id uuid, p_code text, p_list text, p_dir text DEFAULT 'entry', p_event text DEFAULT 'e1')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_check_in_ticket(p_id, 'camera', 'verified', p_code, pg_temp.u(p_event), NULL, NULL,
                                     'Door DL', pg_temp.u(p_list), p_dir)
$$;
CREATE FUNCTION pg_temp.undo(p_pass uuid, p_reason text DEFAULT 'wrong guest', p_ref uuid DEFAULT NULL,
                             p_at timestamptz DEFAULT NULL, p_event text DEFAULT 'e1') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_undo_addon_check_in(p_pass, pg_temp.u(p_event), p_reason, p_ref, p_at, 'Door DL')
$$;
CREATE FUNCTION pg_temp.pass(p_line text, p_unit int DEFAULT 1) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u(p_line) AND unit_index = p_unit
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('oa'), 'dl-oa@x.com', now()), (pg_temp.u('ma'), 'dl-ma@x.com', now()),
  (pg_temp.u('fa'), 'dl-fa@x.com', now()), (pg_temp.u('sa'), 'dl-sa@x.com', now()),
  (pg_temp.u('sb'), 'dl-sb@x.com', now()), (pg_temp.u('ob'), 'dl-ob@x.com', now()),
  (pg_temp.u('sx'), 'dl-sx@x.com', now()), (pg_temp.u('x1'), 'dl-x1@x.com', now()),
  (pg_temp.u('b1'), 'dl-b1@x.com', now()), (pg_temp.u('b2'), 'dl-b2@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('A'), 'DL Hall', 'dl-hall', pg_temp.u('oa')),
  (pg_temp.u('B'), 'DL Other', 'dl-other', pg_temp.u('ob'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('A'), pg_temp.u('oa'), 'owner'), (pg_temp.u('A'), pg_temp.u('ma'), 'manager'),
  (pg_temp.u('A'), pg_temp.u('fa'), 'finance'), (pg_temp.u('A'), pg_temp.u('sa'), 'scanner'),
  (pg_temp.u('A'), pg_temp.u('sb'), 'scanner'),
  (pg_temp.u('B'), pg_temp.u('ob'), 'owner'), (pg_temp.u('B'), pg_temp.u('sx'), 'scanner');
-- The harness has no phase-1 exos_org_secrets (card at the door): its prod shape, rolled back.
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.exos_org_secrets (org_id, payments) VALUES
  (pg_temp.u('A'), '{"connectedAccountId":"acct_dlOrgA","chargesEnabled":true}')
ON CONFLICT (org_id) DO UPDATE SET payments = EXCLUDED.payments;
-- e1: doors open an hour ago. e9: org B.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, ends_at, total_tickets, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('A'), 'DL Night', 'dl-night', 'published', now() + interval '1 hour', now() - interval '1 hour',
   now() + interval '6 hours', 500, 'usd', pg_temp.u('oa')),
  (pg_temp.u('e9'), pg_temp.u('B'), 'DL Elsewhere', 'dl-elsewhere', 'published', now() + interval '1 hour', now() - interval '1 hour',
   NULL, 500, 'usd', pg_temp.u('ob'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order, door_price_cents) VALUES
  (pg_temp.u('tw'), pg_temp.u('e1'), 'GA', 20, 100, 0, 'public', 1, 2500),
  (pg_temp.u('tv'), pg_temp.u('e1'), 'VIP', 50, 100, 0, 'public', 2, 6000),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'GA', 20, 100, 0, 'public', 1, NULL);
-- The scanner's cash drawer at e1.
SELECT pg_temp.act(pg_temp.u('sa'));
INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('dr'), pg_temp.u('e1'), 10000);
SELECT pg_temp.act(NULL);
-- Add-ons: ad1 VIP lounge (own code), ad9 org B's.
INSERT INTO public.exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode) VALUES
  (pg_temp.u('ad1'), pg_temp.u('e1'), 'VIP lounge', 30, 100, true),
  (pg_temp.u('ad9'), pg_temp.u('e9'), 'B lounge', 30, 100, true);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents, currency, status) VALUES
  ('cs_dl1', pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('b1'), 'dl-b1@x.com', false, 2, 14000, 'usd', 'fulfilled'),
  ('cs_dl2', pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('b2'), 'dl-b2@x.com', false, 1, 7000, 'usd', 'fulfilled'),
  ('cs_dl9', pg_temp.u('e9'), pg_temp.u('B'), pg_temp.u('b1'), 'dl-b1@x.com', false, 1, 7000, 'usd', 'fulfilled');
INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_name, kind, calc, per, item_kind, unit_cents, quantity, amount_cents) VALUES
  ('cs_dl1', pg_temp.u('A'), pg_temp.u('e1'), 'Service', 'passed_on', 'fixed', 'ticket', 'ticket', 150, 2, 300),
  ('cs_dl9', pg_temp.u('B'), pg_temp.u('e9'), 'Service', 'passed_on', 'fixed', 'ticket', 'ticket', 150, 1, 150);
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('k1'), pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('tw'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'dl-b1@x.com', 'active', 'sek-k1', 40, 'cs_dl1', 'stripe'),
  (pg_temp.u('k9'), pg_temp.u('e9'), pg_temp.u('B'), pg_temp.u('t9'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'dl-b1@x.com', 'active', 'sek-k9', 40, 'cs_dl9', 'stripe');
-- Add-on lines: the trigger issues one pass per unit.
INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('l1'), pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('ad1'), 'VIP lounge', pg_temp.u('b1'), pg_temp.u('b1'), 3, 30, 'cs_dl1', 'stripe'),
  (pg_temp.u('l2'), pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('ad1'), 'VIP lounge', pg_temp.u('b2'), pg_temp.u('b2'), 3, 30, 'cs_dl2', 'stripe'),
  (pg_temp.u('l9'), pg_temp.u('e9'), pg_temp.u('B'), pg_temp.u('ad9'), 'B lounge', pg_temp.u('b1'), pg_temp.u('b1'), 1, 30, 'cs_dl9', 'stripe');
-- Lists: ll the VIP lounge (no re-entry), lp pickup (any add-on, re-entry), l9 org B's.
INSERT INTO public.exos_checkin_lists (id, event_id, org_id, name, admits, addon_ids, allow_reentry, sort_order) VALUES
  (pg_temp.u('ll'), pg_temp.u('e1'), NULL, 'VIP lounge', 'addons', ARRAY[pg_temp.u('ad1')], false, 1),
  (pg_temp.u('lp'), pg_temp.u('e1'), NULL, 'Pickup', 'addons', NULL, true, 2),
  (pg_temp.u('l9'), pg_temp.u('e9'), NULL, 'B lounge', 'addons', NULL, false, 0);
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  (pg_temp.u('kf'), pg_temp.u('A'), 'finance key', 'sk_live_dlf', 'dlhashf', ARRAY['finance:write'], pg_temp.u('fa')),
  (pg_temp.u('km'), pg_temp.u('A'), 'manager key', 'sk_live_dlm', 'dlhashm', ARRAY['finance:write'], pg_temp.u('ma')),
  (pg_temp.u('ks'), pg_temp.u('A'), 'scanner key', 'sk_live_dls', 'dlhashs', ARRAY['finance:write'], pg_temp.u('sa')),
  (pg_temp.u('kr'), pg_temp.u('A'), 'revoked key', 'sk_live_dlr', 'dlhashr', ARRAY['finance:write'], pg_temp.u('oa')),
  (pg_temp.u('kb'), pg_temp.u('B'), 'B key', 'sk_live_dlb', 'dlhashb', ARRAY['finance:write'], pg_temp.u('ob'));
UPDATE public.exos_api_keys SET revoked_at = now() WHERE id = pg_temp.u('kr');

-- DL0 -------------------------------------------------------------------------
DO $$
DECLARE f text; bad text;
  v_internal text[] := ARRAY[
    'public._exos_pos_door_question_defs(uuid)', 'public._exos_pos_walkup_answers(uuid,uuid,uuid,uuid,integer,jsonb,uuid)',
    'public._exos_pos_walkup_begin_card(uuid,uuid,uuid,integer,uuid,uuid,text,text,jsonb,boolean,boolean)',
    'public._exos_api_fee_adjustment(uuid,uuid,text,bigint,text,uuid,text)',
    'public._exos_addon_wallet_apple_code(uuid,uuid,text,integer)', 'public._exos_addon_wallet_check(uuid,text,timestamptz)',
    'public._exos_addon_door_keys(uuid,uuid,text,integer)'];
  v_client text[] := ARRAY[
    'public.exos_pos_walkup_sell(uuid,uuid,integer,uuid,integer,text,uuid,uuid,text,text,jsonb,text,boolean)',
    'public.exos_undo_addon_check_in(uuid,uuid,text,uuid,timestamptz,text)', 'public.exos_wallet_addon_pass(uuid)'];
BEGIN
  FOR f IN SELECT unnest(ARRAY['exos_pos_question_skips', 'exos_addon_pass_undos']) LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || f)::regclass), 'DL0 RLS on ' || f;
    ASSERT NOT has_table_privilege('anon', 'public.' || f, 'SELECT'), 'DL0 anon reads ' || f;
    ASSERT has_table_privilege('authenticated', 'public.' || f, 'SELECT'), 'DL0 staff read ' || f;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || f, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || f, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || f, 'DELETE'), 'DL0 no client writes on ' || f;
  END LOOP;
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_addon_passes', 'barcode_secret', 'SELECT'), 'DL0 pass secret still closed';
  FOREACH f IN ARRAY v_internal LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'DL0 service role only: ' || f;
  END LOOP;
  FOREACH f IN ARRAY v_client LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'DL0 authenticated (not anon): ' || f;
  END LOOP;
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO bad FROM pg_proc p
   WHERE p.oid = ANY (ARRAY(SELECT to_regprocedure(x) FROM unnest(v_internal || v_client) x))
     AND p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%');
  ASSERT bad IS NULL, 'DL0 search_path not pinned: ' || bad;
  ASSERT position('/* exos: pos walkup questions */' in pg_get_functiondef(
    'public._exos_pos_walkup_begin(uuid,text,uuid,uuid,integer,integer,uuid,uuid,text,text,jsonb,integer)'::regprocedure)) > 0, 'DL0 walk-up marker';
  ASSERT position('/* exos: addon wallet codes */' in pg_get_functiondef(
    'public._exos_check_in_addon_pass(uuid,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure)) > 0, 'DL0 pass check-in marker';
  ASSERT position('/* exos: addon wallet keys */' in pg_get_functiondef('public.exos_event_addon_passes(uuid)'::regprocedure)) > 0,
    'DL0 door keys marker';
  ASSERT position('/* exos: pos walkup door price */' in pg_get_functiondef('public.exos_pos_tg_line()'::regprocedure)) > 0
      OR to_regprocedure('public.exos_pos_tg_line()') IS NULL, 'DL0 earlier walk-up markers kept';
  ASSERT position('/* exos: addon pass codes */' in pg_get_functiondef(
    'public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure)) > 0, 'DL0 earlier check-in marker kept';
  RAISE NOTICE 'OK  DL0 shape: RLS, grants, internal functions closed, search_path, markers';
END $$;

-- DL1 -------------------------------------------------------------------------
CREATE TEMP TABLE dlq (k text PRIMARY KEY, id uuid) ON COMMIT DROP;
DO $$
DECLARE q jsonb; r jsonb; v_sold int; v_order uuid; s text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('oa'));
  -- Order: "Company" (required). Ticket: "Size" (required, S/M/L), "Allergy?"
  -- (checkbox) and "Which allergy" (required, only if Allergy? is ticked).
  -- Hidden from checkout: "Wristband colour" (required, staff fill it).
  q := public.exos_save_event_question(pg_temp.u('e1'), '{"label":"Company","kind":"text","required":true,"scope":"order"}');
  INSERT INTO dlq VALUES ('company', (q ->> 'id')::uuid);
  q := public.exos_save_event_question(pg_temp.u('e1'), '{"label":"Size","kind":"single_choice","options":["S","M","L"],"required":true,"scope":"ticket"}');
  INSERT INTO dlq VALUES ('size', (q ->> 'id')::uuid);
  q := public.exos_save_event_question(pg_temp.u('e1'), '{"label":"Allergy?","kind":"checkbox","scope":"ticket"}');
  INSERT INTO dlq VALUES ('allergy', (q ->> 'id')::uuid);
  q := public.exos_save_event_question(pg_temp.u('e1'), jsonb_build_object('label', 'Which allergy', 'kind', 'text', 'required', true,
         'scope', 'ticket', 'parent_question_id', (SELECT id FROM dlq WHERE k = 'allergy'), 'parent_values', jsonb_build_array('true')));
  INSERT INTO dlq VALUES ('which', (q ->> 'id')::uuid);
  q := public.exos_save_event_question(pg_temp.u('e1'), '{"label":"Wristband colour","kind":"text","required":true,"scope":"ticket","hidden":true}');
  INSERT INTO dlq VALUES ('band', (q ->> 'id')::uuid);
  ASSERT (q ->> 'hidden')::boolean, 'DL1 hidden question saved: ' || q::text;

  -- No answers: refused, the reason names a question, nothing sold or held.
  v_sold := (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('tw'));
  s := pg_temp.st($q$SELECT pg_temp.sell('sa', 2, 'o1')$q$);
  ASSERT s LIKE '22023%required questions%[questions-required]', 'DL1 no answers: ' || s;
  ASSERT s NOT LIKE '%Wristband%', 'DL1 the hidden question is not the one asked for: ' || s;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('tw')) = v_sold, 'DL1 nothing sold';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_orders WHERE client_ref = pg_temp.u('o1')), 'DL1 no order';
  -- The 12-argument sale enforces it too.
  PERFORM pg_temp.act(pg_temp.u('sa'));
  s := pg_temp.st(format($q$SELECT public.exos_pos_walkup_sell(%L, %L, 1, %L, 0, 'cash', NULL, %L, NULL, NULL, NULL, NULL)$q$,
                         pg_temp.u('e1'), pg_temp.u('tw'), pg_temp.u('o2'), pg_temp.u('dr')));
  ASSERT s LIKE '22023%[questions-required]', 'DL1 12-argument sale: ' || s;
  -- Order answered, one ticket's size missing: refused.
  s := pg_temp.st(format($q$SELECT pg_temp.sell('sa', 2, 'o3', %L::jsonb)$q$, jsonb_build_object(
         'order', jsonb_build_object((SELECT id FROM dlq WHERE k = 'company'), 'Acme'),
         'tickets', jsonb_build_array(jsonb_build_object((SELECT id FROM dlq WHERE k = 'size'), 'M')))));
  ASSERT s LIKE '22023%[questions-required]', 'DL1 ticket 2 unanswered: ' || s;
  -- Allergy ticked on ticket 1: "Which allergy" is now required there.
  s := pg_temp.st(format($q$SELECT pg_temp.sell('sa', 2, 'o4', %L::jsonb)$q$, jsonb_build_object(
         'order', jsonb_build_object((SELECT id FROM dlq WHERE k = 'company'), 'Acme'),
         'tickets', jsonb_build_array(
           jsonb_build_object((SELECT id FROM dlq WHERE k = 'size'), 'M', (SELECT id FROM dlq WHERE k = 'allergy'), true),
           jsonb_build_object((SELECT id FROM dlq WHERE k = 'size'), 'L')))));
  ASSERT s LIKE '22023%Which allergy%[questions-required]', 'DL1 shown child required: ' || s;
  -- Everything shown answered (the hidden one left out): sold, answers on the tickets.
  r := pg_temp.sell('sa', 2, 'o5', jsonb_build_object(
         'order', jsonb_build_object((SELECT id FROM dlq WHERE k = 'company'), 'Acme'),
         'tickets', jsonb_build_array(
           jsonb_build_object((SELECT id FROM dlq WHERE k = 'size'), 'M', (SELECT id FROM dlq WHERE k = 'allergy'), true,
                              (SELECT id FROM dlq WHERE k = 'which'), 'Peanuts'),
           jsonb_build_object((SELECT id FROM dlq WHERE k = 'size'), 'L',
                              (SELECT id FROM dlq WHERE k = 'which'), 'stale: hidden, dropped'))));
  ASSERT r ->> 'status' = 'paid' AND NOT (r ->> 'questions_skipped')::boolean, 'DL1 sold: ' || r::text;
  v_order := (r ->> 'id')::uuid;
  ASSERT (SELECT count(*) FROM public.exos_question_answers a WHERE a.order_ref = 'pos:' || v_order AND a.source = 'door') = 5,
    'DL1 five answers kept (order 1, ticket 1: 3, ticket 2: 1)';
  ASSERT (SELECT a.display FROM public.exos_question_answers a JOIN public.exos_tickets t ON t.id = a.ticket_id
           WHERE t.order_ref = 'pos:' || v_order AND a.question_id = (SELECT id FROM dlq WHERE k = 'which')) = 'Peanuts',
    'DL1 the child answer is on ticket 1';
  ASSERT (SELECT count(DISTINCT a.ticket_id) FROM public.exos_question_answers a
           WHERE a.order_ref = 'pos:' || v_order AND a.question_id = (SELECT id FROM dlq WHERE k = 'size')) = 2,
    'DL1 each ticket has its size';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_question_skips WHERE pos_order_id = v_order), 'DL1 nothing skipped, nothing logged';
  -- A skip with nothing missing logs nothing.
  r := pg_temp.sell('sa', 1, 'o6', jsonb_build_object(
         'order', jsonb_build_object((SELECT id FROM dlq WHERE k = 'company'), 'Solo'),
         'tickets', jsonb_build_array(jsonb_build_object((SELECT id FROM dlq WHERE k = 'size'), 'S'))), true);
  ASSERT r ->> 'status' = 'paid' AND NOT (r ->> 'questions_skipped')::boolean, 'DL1 skip with nothing missing: ' || r::text;
  -- The explicit skip: sold, what was given kept, who skipped what logged.
  r := pg_temp.sell('sa', 2, 'o7', jsonb_build_object(
         'tickets', jsonb_build_array(jsonb_build_object((SELECT id FROM dlq WHERE k = 'size'), 'S'))), true);
  ASSERT r ->> 'status' = 'paid' AND (r ->> 'questions_skipped')::boolean, 'DL1 skipped: ' || r::text;
  v_order := (r ->> 'id')::uuid;
  ASSERT (SELECT skipped_by FROM public.exos_pos_question_skips WHERE pos_order_id = v_order) = pg_temp.u('sa'), 'DL1 skip: who';
  ASSERT (SELECT jsonb_array_length(missing) FROM public.exos_pos_question_skips WHERE pos_order_id = v_order) = 2,
    'DL1 skip: company + ticket 2 size';
  ASSERT (SELECT missing @> jsonb_build_array(jsonb_build_object('label', 'Company'))
                 AND missing @> jsonb_build_array(jsonb_build_object('label', 'Size', 'ticket', 2))
            FROM public.exos_pos_question_skips WHERE pos_order_id = v_order), 'DL1 skip: labels and ticket';
  ASSERT (SELECT org_id = pg_temp.u('A') AND event_id = pg_temp.u('e1') AND order_ref = 'pos:' || v_order
            FROM public.exos_pos_question_skips WHERE pos_order_id = v_order), 'DL1 skip: org, event, order';
  ASSERT (SELECT a.display FROM public.exos_question_answers a JOIN public.exos_tickets t ON t.id = a.ticket_id
           WHERE t.order_ref = 'pos:' || v_order AND a.question_id = (SELECT id FROM dlq WHERE k = 'size')) = 'S',
    'DL1 skip keeps the answer given';
  ASSERT coalesce(current_setting('exos.pos_skip_questions', true), '') = '', 'DL1 the flag never outlives the call';
  -- A replay of the skipped sale (same key): the same sale, one log row.
  r := pg_temp.sell('sa', 2, 'o7', NULL, true);
  ASSERT (r ->> 'replay')::boolean AND (r ->> 'id')::uuid = v_order, 'DL1 replay: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_pos_question_skips WHERE pos_order_id = v_order) = 1, 'DL1 one log row';
  -- Invalid answers are still refused with the skip.
  s := pg_temp.st(format($q$SELECT pg_temp.sell('sa', 1, 'o8', %L::jsonb, true)$q$, jsonb_build_object(
         'tickets', jsonb_build_array(jsonb_build_object((SELECT id FROM dlq WHERE k = 'size'), 'XXL')))));
  ASSERT s LIKE '22023%', 'DL1 a bad answer is refused even when skipping: ' || s;
  -- A type the questions don't apply to? (all questions apply to every type here); card: the same flag.
  PERFORM pg_temp.act(pg_temp.u('sa'));
  s := pg_temp.st(format($q$SELECT public._exos_pos_walkup_begin_card(%L, %L, %L, 1, %L, NULL, NULL, NULL, NULL, false, false)$q$,
                         pg_temp.u('sa'), pg_temp.u('e1'), pg_temp.u('tv'), pg_temp.u('o9')));
  ASSERT s LIKE '22023%[questions-required]', 'DL1 card begin, no skip: ' || s;
  r := public._exos_pos_walkup_begin_card(pg_temp.u('sa'), pg_temp.u('e1'), pg_temp.u('tv'), 1, pg_temp.u('oa'), NULL, NULL, NULL,
                                          NULL, false, true);
  ASSERT r ->> 'status' = 'pending' AND (r ->> 'questions_skipped')::boolean, 'DL1 card begin, skipped: ' || r::text;
  ASSERT (SELECT jsonb_array_length(missing) FROM public.exos_pos_question_skips WHERE pos_order_id = (r ->> 'id')::uuid) = 2,
    'DL1 card skip logged';
  RAISE NOTICE 'OK  DL1 walk-up questions: required (conditional, not hidden) unless skipped; skip logged once; answers attach';
END $$;
-- The skip log: org staff and door staff read it; another org, a buyer, anon don't.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('fa'));
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_pos_question_skips) = 2, 'DL1 finance reads the skips'; END $$;
SELECT pg_temp.act(pg_temp.u('sb'));
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_pos_question_skips) = 2, 'DL1 door staff read the skips'; END $$;
SELECT pg_temp.act(pg_temp.u('ob'));
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_pos_question_skips) = 0, 'DL1 another org reads none'; END $$;
SELECT pg_temp.act(pg_temp.u('b1'));
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_pos_question_skips) = 0, 'DL1 a buyer reads none'; END $$;
SELECT pg_temp.act(NULL);
RESET ROLE;

-- DL2 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; r2 jsonb; s text;
BEGIN
  r := public._exos_api_fee_adjustment(pg_temp.u('A'), pg_temp.u('kf'), 'cs_dl1', -100, 'Goodwill: late doors', NULL, 'dl-key-0001');
  ASSERT NOT (r ->> 'duplicate')::boolean AND (r ->> 'fees_change_cents')::int = -100 AND r ->> 'reason' = 'manual'
     AND (r ->> 'actor')::uuid = pg_temp.u('fa') AND (r ->> 'api_key_id')::uuid = pg_temp.u('kf'), 'DL2 recorded: ' || r::text;
  r2 := public._exos_api_fee_adjustment(pg_temp.u('A'), pg_temp.u('kf'), 'cs_dl1', -100, 'Goodwill: late doors', NULL, 'dl-key-0001');
  ASSERT (r2 ->> 'duplicate')::boolean AND r2 ->> 'id' = r ->> 'id', 'DL2 a resend is the same row: ' || r2::text;
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments WHERE session_id = 'cs_dl1') = 1, 'DL2 one row';
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -50, 'other', NULL, 'dl-key-0001')$q$,
                         pg_temp.u('A'), pg_temp.u('kf')));
  ASSERT s LIKE '22023%another adjustment%', 'DL2 the key reused for another change: ' || s;
  -- A manager's key; a ticket of the order.
  r := public._exos_api_fee_adjustment(pg_temp.u('A'), pg_temp.u('km'), 'cs_dl1', 25, 'Missed fee', pg_temp.u('k1'), 'dl-key-0002');
  ASSERT (r ->> 'ticket_id')::uuid = pg_temp.u('k1') AND (r ->> 'actor')::uuid = pg_temp.u('ma'), 'DL2 manager key: ' || r::text;
  -- Refusals: no key, a scanner's key, a revoked key, another org's key for this order, below zero, cents, note, ticket.
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -10, 'note', NULL, NULL)$q$, pg_temp.u('A'), pg_temp.u('kf')));
  ASSERT s LIKE '22023%idempotency key is required%', 'DL2 no idempotency key: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -10, 'note', NULL, 'dl-key-0003')$q$, pg_temp.u('A'), pg_temp.u('ks')));
  ASSERT s LIKE '42501%', 'DL2 a scanner''s key: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -10, 'note', NULL, 'dl-key-0004')$q$, pg_temp.u('A'), pg_temp.u('kr')));
  ASSERT s LIKE '42501%', 'DL2 a revoked key: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -10, 'note', NULL, 'dl-key-0005')$q$, pg_temp.u('A'), pg_temp.u('kb')));
  ASSERT s LIKE '42501%', 'DL2 org B''s key used as org A: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -10, 'note', NULL, 'dl-key-0006')$q$, pg_temp.u('B'), pg_temp.u('kb')));
  ASSERT s LIKE 'P0002 order not found%' AND s NOT LIKE '%cs_dl1%' AND s NOT LIKE '%DL Hall%', 'DL2 another org''s order, nothing echoed: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl9', -10, 'note', NULL, 'dl-key-0007')$q$, pg_temp.u('A'), pg_temp.u('kf')));
  ASSERT s LIKE 'P0002 order not found%', 'DL2 org B''s order with A''s key: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -300, 'too much', NULL, 'dl-key-0008')$q$, pg_temp.u('A'), pg_temp.u('kf')));
  ASSERT s LIKE '22023%below zero%', 'DL2 never below zero: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', 0, 'zero', NULL, 'dl-key-0009')$q$, pg_temp.u('A'), pg_temp.u('kf')));
  ASSERT s LIKE '22023%', 'DL2 zero cents: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -10, 'x', NULL, 'dl-key-0010')$q$, pg_temp.u('A'), pg_temp.u('kf')));
  ASSERT s LIKE '22023%say why%', 'DL2 a note: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_fee_adjustment(%L, %L, 'cs_dl1', -10, 'note', %L, 'dl-key-0011')$q$, pg_temp.u('A'), pg_temp.u('kf'), pg_temp.u('k9')));
  ASSERT s LIKE '22023%not on this order%', 'DL2 another order''s ticket: ' || s;
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments WHERE session_id = 'cs_dl1') = 2, 'DL2 two rows in the end';
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments WHERE session_id = 'cs_dl9') = 0, 'DL2 org B untouched';
  RAISE NOTICE 'OK  DL2 POST fee adjustments: owner / manager / finance keys, idempotent, never below zero, org-scoped';
END $$;

-- DL3 -------------------------------------------------------------------------
DO $$
DECLARE p1 uuid := pg_temp.pass('l1', 1); p2 uuid := pg_temp.pass('l1', 2); r jsonb; s text; v_undo uuid;
BEGIN
  -- sa scans p1 at the lounge, then undoes it: their own scan, in the window.
  PERFORM pg_temp.act(pg_temp.u('sa'));
  r := pg_temp.scan(p1, pg_temp.acode(p1), 'll');
  ASSERT (r ->> 'ok')::boolean, 'DL3 scanned: ' || r::text;
  r := pg_temp.undo(p1, 'x');
  ASSERT r ->> 'reason' = 'reason-required', 'DL3 a reason: ' || r::text;
  r := pg_temp.undo(p1, 'wrong guest', NULL, NULL, 'e9');
  ASSERT r ->> 'reason' = 'wrong-event' AND NOT (r ? 'addon_name'), 'DL3 wrong event, nothing echoed: ' || r::text;
  -- Another scanner: not theirs.
  PERFORM pg_temp.act(pg_temp.u('sb'));
  r := pg_temp.undo(p1);
  ASSERT r ->> 'reason' = 'needs-manager', 'DL3 another scanner: ' || r::text;
  PERFORM pg_temp.act(pg_temp.u('sa'));
  r := pg_temp.undo(p1);
  ASSERT (r ->> 'ok')::boolean AND r ->> 'status' = 'active' AND (r ->> 'removed')::int = 1, 'DL3 own undo: ' || r::text;
  ASSERT (SELECT status = 'active' AND check_in_at IS NULL FROM public.exos_addon_passes WHERE id = p1), 'DL3 pass usable again';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_addon_pass_checkins WHERE pass_id = p1), 'DL3 scan removed';
  SELECT id INTO v_undo FROM public.exos_addon_pass_undos WHERE pass_id = p1;
  ASSERT (SELECT undone_by = pg_temp.u('sa') AND undone_as = 'scanner' AND reason = 'wrong guest' AND jsonb_array_length(checkins) = 1
                 AND checkins -> 0 ->> 'list_id' = pg_temp.u('ll')::text AND client_ref IS NULL AND device = 'Door DL'
            FROM public.exos_addon_pass_undos WHERE id = v_undo), 'DL3 audit row';
  r := pg_temp.undo(p1);
  ASSERT r ->> 'reason' = 'not-checked-in', 'DL3 nothing to undo: ' || r::text;
  r := pg_temp.scan(p1, pg_temp.acode(p1), 'll');
  ASSERT (r ->> 'ok')::boolean AND NOT (r ->> 'reentry')::boolean, 'DL3 scans again: ' || r::text;
  -- Out of the window (scanned 11 minutes ago): the scanner can't, a manager can.
  UPDATE public.exos_addon_pass_checkins SET scanned_at = now() - interval '11 minutes' WHERE pass_id = p1;
  r := pg_temp.undo(p1);
  ASSERT r ->> 'reason' = 'undo-window-passed' AND (r ->> 'window_minutes')::int = 10, 'DL3 window passed: ' || r::text;
  PERFORM pg_temp.act(pg_temp.u('ma'));
  r := pg_temp.undo(p1, 'manager: wrong pass');
  ASSERT (r ->> 'ok')::boolean AND EXISTS (SELECT 1 FROM public.exos_addon_pass_undos WHERE pass_id = p1 AND undone_as = 'manager' AND reason = 'manager: wrong pass' AND undone_by = pg_temp.u('ma')),
    'DL3 manager after the window: ' || r::text;
  -- The owner undoes another scanner's scan.
  PERFORM pg_temp.act(pg_temp.u('sb'));
  r := pg_temp.scan(p2, pg_temp.acode(p2), 'll');
  ASSERT (r ->> 'ok')::boolean, 'DL3 sb scans p2: ' || r::text;
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := pg_temp.undo(p2, 'owner says');
  ASSERT (r ->> 'ok')::boolean, 'DL3 owner undo: ' || r::text;
  -- Finance, an outsider, org B's scanner: not door staff here.
  FOREACH s IN ARRAY ARRAY['fa', 'x1', 'sx'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    BEGIN
      r := pg_temp.undo(p2);
      RAISE EXCEPTION 'DL3: % undid A''s add-on scan: %', s, r;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  -- Org A's manager can't reach org B's pass.
  PERFORM pg_temp.act(pg_temp.u('ma'));
  BEGIN
    r := pg_temp.undo(pg_temp.pass('l9'), 'nope', NULL, NULL, 'e9');
    RAISE EXCEPTION 'DL3: A''s manager undid B''s pass: %', r;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  r := public.exos_undo_addon_check_in(gen_random_uuid(), pg_temp.u('e1'), 'nothing', NULL, NULL, NULL);
  ASSERT r ->> 'reason' = 'not-found', 'DL3 unknown pass: ' || r::text;
  -- A voided pass.
  PERFORM pg_temp.act(pg_temp.u('sa'));
  r := pg_temp.scan(pg_temp.pass('l1', 3), pg_temp.acode(pg_temp.pass('l1', 3)), 'll');
  ASSERT (r ->> 'ok')::boolean, 'DL3 p3 in: ' || r::text;
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_addon_passes SET status = 'voided' WHERE id = pg_temp.pass('l1', 3);
  PERFORM pg_temp.act(pg_temp.u('ma'));
  r := pg_temp.undo(pg_temp.pass('l1', 3));
  ASSERT r ->> 'reason' = 'voided', 'DL3 voided: ' || r::text;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DL3 undo online: own scan within 10 minutes, else a manager; reason, event, roles, isolation; audit row';
END $$;
-- The undo log: org and door staff read it; org B, a buyer don't.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('sb'));
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_addon_pass_undos) = 3, 'DL3 door staff read the undos'; END $$;
SELECT pg_temp.act(pg_temp.u('ob'));
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_addon_pass_undos) = 0, 'DL3 org B reads none'; END $$;
SELECT pg_temp.act(pg_temp.u('b1'));
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_addon_pass_undos) = 0, 'DL3 the holder reads none'; END $$;
SELECT pg_temp.act(NULL);
RESET ROLE;

-- DL4 -------------------------------------------------------------------------
DO $$
DECLARE p4 uuid := pg_temp.pass('l2', 1); p5 uuid := pg_temp.pass('l2', 2); r jsonb; r2 jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('sa'));
  -- Offline at the pickup list (re-entry): in at -6 min, out at -5.5, in again at -2.
  r := public.exos_check_in_offline(pg_temp.u('r1'), p4, pg_temp.u('e1'), now() - interval '6 minutes',
                                    pg_temp.acode(p4, now() - interval '6 minutes'), 'camera', NULL, 'Door DL', pg_temp.u('lp'), 'entry');
  ASSERT (r ->> 'ok')::boolean, 'DL4 offline in: ' || r::text;
  r := public.exos_check_in_offline(pg_temp.u('r2'), p4, pg_temp.u('e1'), now() - interval '330 seconds',
                                    pg_temp.acode(p4, now() - interval '330 seconds'), 'camera', NULL, 'Door DL', pg_temp.u('lp'), 'exit');
  ASSERT r ->> 'reason' = 'checked-out', 'DL4 offline out: ' || r::text;
  -- The undo the door made offline at -4 min, replayed: removes the first visit only.
  r := pg_temp.undo(p4, 'scanned the wrong wristband', pg_temp.u('u1'), now() - interval '4 minutes');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'removed')::int = 2 AND r ->> 'status' = 'active', 'DL4 offline undo: ' || r::text;
  r2 := pg_temp.undo(p4, 'scanned the wrong wristband', pg_temp.u('u1'), now() - interval '4 minutes');
  ASSERT (r2 ->> 'ok')::boolean AND (r2 ->> 'duplicate')::boolean, 'DL4 the same ref again: ' || r2::text;
  ASSERT (SELECT count(*) FROM public.exos_addon_pass_undos WHERE client_ref = pg_temp.u('u1')) = 1, 'DL4 one undo row';
  ASSERT (SELECT offline_undone_at IS NOT NULL FROM public.exos_addon_pass_undos WHERE client_ref = pg_temp.u('u1')), 'DL4 offline time kept';
  r := public.exos_check_in_offline(pg_temp.u('r3'), p4, pg_temp.u('e1'), now() - interval '2 minutes',
                                    pg_temp.acode(p4, now() - interval '2 minutes'), 'camera', NULL, 'Door DL', pg_temp.u('lp'), 'entry');
  ASSERT (r ->> 'ok')::boolean, 'DL4 the next entry after the undo: ' || r::text;
  -- A ref used for another pass: refused.
  r := pg_temp.undo(p5, 'reused ref', pg_temp.u('u1'), now() - interval '1 minute');
  ASSERT r ->> 'reason' = 'bad-client-ref', 'DL4 a ref of another pass: ' || r::text;
  -- An undo replayed after a later entry: the later entry stands.
  r := public.exos_check_in_offline(pg_temp.u('r4'), p5, pg_temp.u('e1'), now() - interval '8 minutes',
                                    pg_temp.acode(p5, now() - interval '8 minutes'), 'camera', NULL, 'Door DL', pg_temp.u('lp'), 'entry');
  ASSERT (r ->> 'ok')::boolean, 'DL4 p5 in at -8: ' || r::text;
  r := public.exos_check_in_offline(pg_temp.u('r5'), p5, pg_temp.u('e1'), now() - interval '7 minutes',
                                    pg_temp.acode(p5, now() - interval '7 minutes'), 'camera', NULL, 'Door DL', pg_temp.u('lp'), 'exit');
  r := public.exos_check_in_offline(pg_temp.u('r6'), p5, pg_temp.u('e1'), now() - interval '1 minute',
                                    pg_temp.acode(p5, now() - interval '1 minute'), 'camera', NULL, 'Door DL', pg_temp.u('lp'), 'entry');
  ASSERT (r ->> 'ok')::boolean, 'DL4 p5 in again at -1: ' || r::text;
  r := pg_temp.undo(p5, 'first visit was a mistake', pg_temp.u('u2'), now() - interval '7 minutes' + interval '10 seconds');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'status' = 'used' AND (r ->> 'removed')::int = 2, 'DL4 a later entry stands: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_addon_pass_checkins WHERE pass_id = p5) = 1, 'DL4 one scan left';
  ASSERT (SELECT status = 'used' AND check_in_at > now() - interval '2 minutes' FROM public.exos_addon_passes WHERE id = p5),
    'DL4 the pass stays used, at the later entry';
  -- Undo times: in the future, or more than a day ago.
  r := pg_temp.undo(p5, 'future', pg_temp.u('u3'), now() + interval '1 hour');
  ASSERT r ->> 'reason' = 'bad-undo-time', 'DL4 future: ' || r::text;
  r := pg_temp.undo(p5, 'old', pg_temp.u('u4'), now() - interval '25 hours');
  ASSERT r ->> 'reason' = 'bad-undo-time', 'DL4 too old: ' || r::text;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DL4 undo offline merge: once per ref, only scans before the undo, later entries stand, time bounds';
END $$;

-- DL5 -------------------------------------------------------------------------
DO $$
DECLARE p6 uuid := pg_temp.pass('l2', 3); r jsonb; k jsonb; v_code text; v_old text; s text;
BEGIN
  -- TS / SQL parity (src/lib/wallet/addonPass.test.ts uses the same vectors).
  ASSERT public._exos_addon_wallet_apple_code('11111111-2222-4333-8444-555555555555', '66666666-7777-4888-8999-000000000000', 'vector-secret', 3)
         = 'A-11111111-2222-4333-8444-555555555555:66666666-7777-4888-8999-000000000000:a3:rYCAPorA6t4ek-4LcOG5D7xjTJsvYFsdU5QpaAkwEI0',
    'DL5 Apple add-on code parity';
  ASSERT encode(public._exos_wallet_google_key('11111111-2222-4333-8444-555555555555', '66666666-7777-4888-8999-000000000000', 'vector-secret', 3), 'hex')
         = '7beafda181d04e474166c4ed466b67c97832c28f', 'DL5 Google key parity';
  ASSERT public._exos_wallet_totp(decode('7beafda181d04e474166c4ed466b67c97832c28f', 'hex'), 59000000) = '11095586', 'DL5 TOTP parity';
  -- Before a wallet pass is issued, a wallet-shaped code is refused.
  PERFORM pg_temp.act(pg_temp.u('sa'));
  r := pg_temp.scan(p6, pg_temp.wapple(p6), 'll');
  ASSERT r ->> 'reason' = 'barcode-rejected', 'DL5 no wallet pass yet: ' || r::text;
  -- Only the holder gets the pass.
  FOREACH s IN ARRAY ARRAY['b1', 'oa', 'sa'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    ASSERT pg_temp.st(format('SELECT public.exos_wallet_addon_pass(%L)', p6)) LIKE '42501%', 'DL5 not the holder: ' || s;
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('b2'));
  r := public.exos_wallet_addon_pass(p6);
  ASSERT (r ->> 'ok')::boolean AND (r -> 'payload' ->> 'code_epoch')::int = 1, 'DL5 issued: ' || r::text;
  ASSERT r -> 'payload' ->> 'apple_code' = pg_temp.wapple(p6), 'DL5 the Apple code';
  ASSERT r -> 'payload' ->> 'apple_code' LIKE 'A-' || p6 || ':' || pg_temp.u('b2') || ':a1:%', 'DL5 the code''s shape';
  ASSERT r -> 'payload' ->> 'google_pattern' = 'A-' || p6 || ':' || pg_temp.u('b2') || ':g1:{totp_value_0}', 'DL5 the Google pattern';
  ASSERT r -> 'payload' ->> 'google_key_hex' ~ '^[0-9a-f]{40}$', 'DL5 the TOTP key';
  ASSERT (r -> 'payload' ->> 'unit_count')::int = 3 AND r -> 'payload' -> 'event' ->> 'name' = 'DL Night'
     AND r -> 'payload' ->> 'org_name' = 'DL Hall' AND NOT (r::text LIKE '%barcode_secret%') AND NOT (r::text LIKE '%dl-b2@%'),
    'DL5 holder-safe payload';
  r := public.exos_wallet_addon_pass(p6);
  ASSERT (r -> 'payload' ->> 'code_epoch')::int = 1, 'DL5 the epoch is issued once';
  -- The door keys carry the wallet keys.
  PERFORM pg_temp.act(pg_temp.u('sa'));
  k := (SELECT x -> 'door_keys' FROM jsonb_array_elements(public.exos_event_addon_passes(pg_temp.u('e1'))) x WHERE x ->> 'id' = p6::text);
  ASSERT (k ->> 'we')::int = 1 AND k ->> 'wa' = encode(extensions.digest(pg_temp.wapple(p6), 'sha256'), 'hex')
     AND k ->> 'wg' = encode(public._exos_wallet_google_key(p6, pg_temp.u('b2'), (SELECT barcode_secret FROM public.exos_addon_passes WHERE id = p6), 1), 'hex')
     AND jsonb_typeof(k -> 'd') = 'object', 'DL5 door keys: ' || k::text;
  ASSERT NOT ((SELECT x -> 'door_keys' FROM jsonb_array_elements(public.exos_event_addon_passes(pg_temp.u('e1'))) x
                WHERE x ->> 'id' = pg_temp.pass('l1', 1)::text) ? 'wa'), 'DL5 no wallet keys without a wallet pass';
  -- Forged / another epoch: refused. Apple: in, once.
  r := pg_temp.scan(p6, left(pg_temp.wapple(p6), -4) || 'AAAA', 'll');
  ASSERT r ->> 'reason' = 'barcode-rejected', 'DL5 forged Apple: ' || r::text;
  r := pg_temp.scan(p6, pg_temp.wapple(p6, 2), 'll');
  ASSERT r ->> 'reason' = 'barcode-rejected', 'DL5 another epoch: ' || r::text;
  r := pg_temp.scan(p6, pg_temp.wapple(p6), 'll');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'verified')::boolean AND r ->> 'kind' = 'addon', 'DL5 Apple in: ' || r::text;
  r := pg_temp.scan(p6, pg_temp.wapple(p6), 'll');
  ASSERT r ->> 'reason' = 'used', 'DL5 Apple twice: ' || r::text;
  -- Google: rotating; an old step is refused; the current one at the pickup list.
  r := pg_temp.scan(p6, pg_temp.wgoogle(p6, now() - interval '10 minutes'), 'lp');
  ASSERT r ->> 'reason' = 'barcode-rejected', 'DL5 old TOTP: ' || r::text;
  r := pg_temp.scan(p6, pg_temp.wgoogle(p6), 'lp');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'verified')::boolean, 'DL5 Google in: ' || r::text;
  -- Offline replay of a Google code scanned 5 minutes ago (checked at the scan time).
  PERFORM pg_temp.act(pg_temp.u('b1'));
  r := public.exos_wallet_addon_pass(pg_temp.pass('l1', 2));
  ASSERT (r ->> 'ok')::boolean, 'DL5 b1''s pass: ' || r::text;
  PERFORM pg_temp.act(pg_temp.u('sa'));
  r := public.exos_check_in_offline(pg_temp.u('r7'), pg_temp.pass('l1', 2), pg_temp.u('e1'), now() - interval '5 minutes',
                                    pg_temp.wgoogle(pg_temp.pass('l1', 2), now() - interval '5 minutes'), 'camera', NULL, 'Door DL',
                                    pg_temp.u('lp'), 'entry');
  ASSERT (r ->> 'ok')::boolean, 'DL5 offline Google replay: ' || r::text;
  -- A new owner (the secret rotates): the old wallet code is dead.
  v_old := pg_temp.wapple(pg_temp.pass('l1', 2));
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_order_addons SET owner_id = pg_temp.u('x1') WHERE id = pg_temp.u('l1');
  PERFORM pg_temp.act(pg_temp.u('sa'));
  r := pg_temp.scan(pg_temp.pass('l1', 2), v_old, 'll');
  ASSERT r ->> 'reason' = 'barcode-rejected', 'DL5 old holder''s code after a transfer: ' || r::text;
  -- A voided pass gets no wallet pass.
  PERFORM pg_temp.act(pg_temp.u('x1'));
  r := public.exos_wallet_addon_pass(pg_temp.pass('l1', 3));
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'voided', 'DL5 voided: ' || r::text;
  -- Org B's scanner can't scan A's wallet code.
  PERFORM pg_temp.act(pg_temp.u('sx'));
  BEGIN
    r := pg_temp.scan(p6, pg_temp.wapple(p6), 'll');
    RAISE EXCEPTION 'DL5: org B''s scanner scanned A''s wallet code: %', r;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DL5 add-on wallet codes: holder-only issue, Apple + Google at the door (online, offline), keys, transfer, isolation';
END $$;

DO $$ BEGIN RAISE NOTICE 'test_dice_leftovers: all passed'; END $$;
ROLLBACK;
