-- ============================================================================
-- DICE gaps 6 (mig 20261107110000). Self-contained (d6… ids), rolled back.
--   DG0 shape: RLS on the new tables; clients read only (no insert / update /
--       delete grant); no anon grant; the pass secret column is not granted;
--       internal functions are service-role only; search_path pinned; every
--       patch marker is in place
--   DG1 the fee log is append-only: UPDATE, DELETE and TRUNCATE refused (as
--       the table owner too); a cascade from deleting the order still works
--   DG2 refunds log the buyer-fee part of the money returned: a partial
--       refund, its retry (nothing more), a second refund up to the full fees,
--       a pending refund (nothing), a succeeded refund that fails later
--       (refund_reversed), an order with no fees (nothing); exos_order_fees
--       and the refund money stay as they were; the refund request's actor
--   DG3 the order-edit path writes no row (it can't change fees); manual
--       adjustments: owner / manager / finance yes, scanner / outsider / other
--       org no; a note, a non-zero amount, a ticket of the order, a placed
--       order, never below zero; the same idempotency key is one row
--   DG4 RLS and cross-org isolation: owner / manager / finance read their
--       org's rows; scanner, buyer, outsider and the other org's owner none;
--       anon has no grant; a client can't insert
--   DG5 settlement inputs carry the fee changes (count, net, per reason)
--   DG6 add-on passes: one per unit for an add-on with its own barcode,
--       none without; turning it on later issues them; a new owner takes them
--       with a new secret; a refunded line voids them; the holder reads the
--       secret, door staff read day keys only, others nothing
--   DG7 the door, online: an add-on code scans at its list, once; refused at
--       a ticket-only list and with no list ('tickets-only-list'), at a list
--       for another add-on ('wrong-list'); a ticket is refused at an
--       add-on-only list ('addon-only-list') and still admitted at its own;
--       a 'both' list takes both; forged, expired, other-holder and voided
--       codes refused; another org's scanner 42501; a typed pass id needs a
--       manager and a reason; re-entry on an add-on list
--   DG8 offline merge: an add-on code replayed at its list is admitted (a
--       retry with the same ref answers the same); refused at a ticket list
--       with a reject row; a ticket replayed at an add-on-only list is
--       refused, recorded as a reject, never forced in, and still good at its
--       own door; the API's add-on write takes separate_access_barcode
--   DG9 conditional questions: save rules (choice / checkbox parent, same
--       event, scope, values in the options, cycles, depth), archive / kind /
--       option changes that would break a child are refused; hidden means not
--       required and dropped (validation, recording); shown means enforced;
--       the free-claim guard ignores conditional required questions; the
--       public RPC carries the condition
--   DG10 TS/SQL parity: the cases between the DG6-CASES markers, which
--       src/lib/conditionalQuestions.test.ts runs through _shared/questions.ts
-- Users: oa owner A, ma manager A, fa finance A, sa scanner A, ob owner B,
--        x1 outsider, b1 / b2 buyers.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid PRIMARY KEY, display_name text);

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT md5('d6:' || p)::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '{"email":"door@x.com"}', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO anon, authenticated;
-- An add-on code for a pass, in the window of p_at (the holder's app signs it).
CREATE FUNCTION pg_temp.acode(p_pass uuid, p_at timestamptz DEFAULT now(), p_owner uuid DEFAULT NULL) RETURNS text
LANGUAGE sql AS $$
  SELECT 'A-' || p.id || ':' || coalesce(p_owner, p.owner_id) || ':' || b || ':'
         || public._exos_door_code_mac(p.id, coalesce(p_owner, p.owner_id), b, p.barcode_secret)
    FROM public.exos_addon_passes p,
         (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint AS b) x
   WHERE p.id = p_pass
$$;
GRANT EXECUTE ON FUNCTION pg_temp.acode(uuid, timestamptz, uuid) TO authenticated;
-- A ticket's T- code (day-key MAC).
CREATE FUNCTION pg_temp.tcode(p_ticket uuid, p_at timestamptz DEFAULT now()) RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' || public._exos_door_code_mac(t.id, t.owner_id, b, t.barcode_secret)
    FROM public.exos_tickets t, (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint AS b) x
   WHERE t.id = p_ticket
$$;
-- Scan (the door's 10-argument check-in) on list p_list (NULL: none).
CREATE FUNCTION pg_temp.scan(p_id uuid, p_code text, p_list text, p_dir text DEFAULT 'entry',
                             p_event uuid DEFAULT NULL, p_source text DEFAULT 'camera', p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_check_in_ticket(p_id, p_source, 'verified', p_code, coalesce(p_event, pg_temp.u('e1')), p_reason, NULL,
                                     'Door DG', CASE WHEN p_list IS NULL THEN NULL ELSE pg_temp.u(p_list) END, p_dir)
$$;
CREATE FUNCTION pg_temp.pass(p_line text, p_unit int) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u(p_line) AND unit_index = p_unit
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'd6-oa@x.com', now()),
  (pg_temp.u('a2'), 'd6-ma@x.com', now()),
  (pg_temp.u('a3'), 'd6-fa@x.com', now()),
  (pg_temp.u('a4'), 'd6-sa@x.com', now()),
  (pg_temp.u('a5'), 'd6-ob@x.com', now()),
  (pg_temp.u('a6'), 'd6-x1@x.com', now()),
  (pg_temp.u('b1'), 'd6-b1@x.com', now()),
  (pg_temp.u('b2'), 'd6-b2@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'D6 Hall', 'd6-hall', pg_temp.u('a1')),
  (pg_temp.u('2'), 'D6 Other', 'd6-other', pg_temp.u('a5'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('a1'), 'owner'),
  (pg_temp.u('1'), pg_temp.u('a2'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('a3'), 'finance'),
  (pg_temp.u('1'), pg_temp.u('a4'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('a5'), 'owner'),
  (pg_temp.u('2'), pg_temp.u('a6'), 'scanner');
-- e1: doors open an hour ago. e2: a second event of A (questions). e9: org B.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, ends_at, total_tickets, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'D6 Night', 'd6-night', 'published', now() + interval '1 hour', now() - interval '1 hour',
   now() + interval '6 hours', 500, pg_temp.u('a1')),
  (pg_temp.u('e2'), pg_temp.u('1'), 'D6 Other Night', 'd6-other-night', 'published', now() + interval '3 days', NULL, NULL, 500, pg_temp.u('a1')),
  (pg_temp.u('e9'), pg_temp.u('2'), 'D6 Elsewhere', 'd6-elsewhere', 'published', now() + interval '1 hour', now() - interval '1 hour',
   NULL, 500, pg_temp.u('a5'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity) VALUES
  (pg_temp.u('t1'), pg_temp.u('e1'), 'GA', 40, 100),
  (pg_temp.u('t2'), pg_temp.u('e2'), 'GA', 40, 100),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'GA', 40, 100);
-- Add-ons: ad1 VIP lounge (own code), ad2 poster (none), ad3 merch pickup
-- (turned on later), ad9 org B's (own code).
INSERT INTO public.exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode) VALUES
  (pg_temp.u('ad1'), pg_temp.u('e1'), 'VIP lounge', 30, 100, true),
  (pg_temp.u('ad2'), pg_temp.u('e1'), 'Poster', 10, 100, false),
  (pg_temp.u('ad3'), pg_temp.u('e1'), 'Merch pickup', 25, 100, false),
  (pg_temp.u('ad9'), pg_temp.u('e9'), 'B lounge', 30, 100, true);

-- Orders: cs_d61 b1 (2 tickets $40 + 2 lounge + 1 poster + 1 merch = $135,
-- buyer fees $3.00 passed on, $1.00 absorbed), cs_d62 b2 (1 ticket, no fees),
-- cs_d63 pending, cs_d69 org B.
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents, currency, status) VALUES
  ('cs_d61', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b1'), 'd6-b1@x.com', false, 2, 13500, 'usd', 'fulfilled'),
  ('cs_d62', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), 'd6-b2@x.com', false, 1, 4000, 'usd', 'fulfilled'),
  ('cs_d63', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), 'd6-b2@x.com', false, 1, 4000, 'usd', 'pending'),
  ('cs_d69', pg_temp.u('e9'), pg_temp.u('2'), pg_temp.u('b1'), 'd6-b1@x.com', false, 1, 4000, 'usd', 'fulfilled');
INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_name, kind, calc, per, item_kind, unit_cents, quantity, amount_cents) VALUES
  ('cs_d61', pg_temp.u('1'), pg_temp.u('e1'), 'Service', 'passed_on', 'fixed', 'ticket', 'ticket', 150, 2, 300),
  ('cs_d61', pg_temp.u('1'), pg_temp.u('e1'), 'Venue', 'absorbed', 'fixed', 'order', 'order', 100, 1, 100),
  ('cs_d69', pg_temp.u('2'), pg_temp.u('e9'), 'Service', 'passed_on', 'fixed', 'ticket', 'ticket', 150, 1, 150);
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('k1'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'd6-b1@x.com', 'active', 'sek-k1', 40, 'cs_d61', 'stripe'),
  (pg_temp.u('k2'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'd6-b1@x.com', 'active', 'sek-k2', 40, 'cs_d61', 'stripe'),
  (pg_temp.u('k3'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b2'), pg_temp.u('b2'), 'd6-b2@x.com', 'active', 'sek-k3', 40, 'cs_d62', 'stripe'),
  (pg_temp.u('k9'), pg_temp.u('e9'), pg_temp.u('2'), pg_temp.u('t9'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'd6-b1@x.com', 'active', 'sek-k9', 40, 'cs_d69', 'stripe');
-- Add-on lines (as fulfilment writes them): the trigger issues the passes.
INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('l1'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('ad1'), 'VIP lounge', pg_temp.u('b1'), pg_temp.u('b1'), 2, 30, 'cs_d61', 'stripe'),
  (pg_temp.u('l2'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('ad2'), 'Poster', pg_temp.u('b1'), pg_temp.u('b1'), 1, 10, 'cs_d61', 'stripe'),
  (pg_temp.u('l3'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('ad3'), 'Merch pickup', pg_temp.u('b1'), pg_temp.u('b1'), 1, 25, 'cs_d61', 'stripe'),
  (pg_temp.u('l4'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('ad1'), 'VIP lounge', pg_temp.u('b2'), pg_temp.u('b2'), 1, 30, 'cs_d62', 'stripe'),
  (pg_temp.u('l9'), pg_temp.u('e9'), pg_temp.u('2'), pg_temp.u('ad9'), 'B lounge', pg_temp.u('b1'), pg_temp.u('b1'), 1, 30, 'cs_d69', 'stripe');
-- Lists on e1: main (tickets), lounge (VIP lounge add-on only), pickup (any
-- add-on, re-entry), both (tickets and add-ons). One on e9.
INSERT INTO public.exos_checkin_lists (id, event_id, org_id, name, admits, addon_ids, allow_reentry, sort_order) VALUES
  (pg_temp.u('lm'), pg_temp.u('e1'), NULL, 'Main door', 'tickets', NULL, false, 0),
  (pg_temp.u('ll'), pg_temp.u('e1'), NULL, 'VIP lounge', 'addons', ARRAY[pg_temp.u('ad1')], false, 1),
  (pg_temp.u('lp'), pg_temp.u('e1'), NULL, 'Pickup', 'addons', NULL, true, 2),
  (pg_temp.u('lb'), pg_temp.u('e1'), NULL, 'Everything', 'both', NULL, false, 3),
  (pg_temp.u('l9'), pg_temp.u('e9'), NULL, 'B lounge', 'addons', NULL, false, 0);

-- DG0 -------------------------------------------------------------------------
DO $$
DECLARE f text; bad text;
BEGIN
  FOR f IN SELECT unnest(ARRAY['exos_fee_adjustments', 'exos_addon_passes', 'exos_addon_pass_checkins']) LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || f)::regclass), 'DG0 RLS on ' || f;
    ASSERT NOT has_table_privilege('anon', 'public.' || f, 'SELECT'), 'DG0 anon reads ' || f;
    ASSERT has_table_privilege('authenticated', 'public.' || f, 'SELECT')
        OR f = 'exos_addon_passes', 'DG0 authenticated reads ' || f;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || f, 'INSERT'), 'DG0 authenticated inserts ' || f;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || f, 'UPDATE'), 'DG0 authenticated updates ' || f;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || f, 'DELETE'), 'DG0 authenticated deletes ' || f;
  END LOOP;
  ASSERT has_column_privilege('authenticated', 'public.exos_addon_passes', 'status', 'SELECT'), 'DG0 pass status readable';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_addon_passes', 'barcode_secret', 'SELECT'), 'DG0 pass secret not granted';
  ASSERT NOT has_table_privilege('service_role', 'public.exos_fee_adjustments', 'UPDATE'), 'DG0 service role can''t update the log';
  FOR f IN SELECT unnest(ARRAY[
      'public._exos_fee_adj_sync_refunds(text,uuid)', 'public._exos_fee_adjustment_add(uuid,text,uuid,bigint,text,uuid,uuid,text)',
      'public._exos_fee_adjustment_summary(uuid)', 'public._exos_addon_pass_issue(uuid)',
      'public._exos_check_in_addon_pass(uuid,text,text,uuid,text,timestamptz,text,uuid,text)',
      'public._exos_question_apply_condition(uuid,jsonb)', 'public._exos_question_condition_problem(public.exos_event_questions)',
      'public._exos_question_hidden(jsonb,uuid[],jsonb,jsonb)', 'public._exos_question_shown(jsonb,jsonb,integer,uuid[],jsonb,jsonb,integer)',
      'public._exos_condition_met(jsonb,jsonb,jsonb)', 'public._exos_tg_order_addon_passes()', 'public._exos_fee_adjustments_guard()']) LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'DG0 anon runs ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'DG0 authenticated runs ' || f;
  END LOOP;
  FOR f IN SELECT unnest(ARRAY['public.exos_fee_adjustment_record(text,bigint,text,uuid,text)',
                               'public.exos_my_addon_passes(uuid)', 'public.exos_event_addon_passes(uuid)']) LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'DG0 anon runs ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'DG0 authenticated can''t run ' || f;
  END LOOP;
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO bad FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
     AND p.proname IN ('_exos_fee_adj_sync_refunds', '_exos_fee_adjustment_add', 'exos_fee_adjustment_record',
                       '_exos_fee_adjustment_summary', '_exos_addon_pass_issue', '_exos_check_in_addon_pass',
                       'exos_my_addon_passes', 'exos_event_addon_passes', '_exos_question_apply_condition',
                       '_exos_question_condition_problem', '_exos_tg_order_addon_passes', '_exos_tg_order_addon_passes_upd',
                       '_exos_tg_addon_passes_enable', '_exos_tg_checkin_list_addons', '_exos_fee_adjustments_guard')
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%');
  ASSERT bad IS NULL, 'DG0 search_path not pinned: ' || bad;
  ASSERT position('/* exos: fee adjustments */' in pg_get_functiondef('public.exos_record_refund(text,text,integer,text,text,text,text,text,jsonb)'::regprocedure)) > 0, 'DG0 refund marker';
  ASSERT position('/* exos: fee adjustments */' in pg_get_functiondef('public._exos_settlement_inputs(uuid)'::regprocedure)) > 0, 'DG0 settlement marker';
  ASSERT position('/* exos: addon pass codes */' in pg_get_functiondef('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure)) > 0, 'DG0 check-in marker';
  ASSERT position('/* exos: print codes */' in pg_get_functiondef('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure)) > 0, 'DG0 earlier check-in markers kept';
  ASSERT position('/* exos: addon pass refs */' in pg_get_functiondef('public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text,uuid,text)'::regprocedure)) > 0, 'DG0 offline marker';
  ASSERT position('/* exos: replay not-assigned */' in pg_get_functiondef('public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text,uuid,text)'::regprocedure)) > 0, 'DG0 earlier offline marker kept';
  ASSERT position('/* exos: addon lists */' in pg_get_functiondef('public._exos_checkin_list_refusal(uuid,uuid,uuid,text,timestamptz)'::regprocedure)) > 0, 'DG0 list marker';
  ASSERT position('/* exos: addon access barcode */' in pg_get_functiondef('public.exos_api_write(uuid,text,text,jsonb,text)'::regprocedure)) > 0, 'DG0 api write marker';
  ASSERT position('/* exos: door price */' in pg_get_functiondef('public.exos_api_write(uuid,text,text,jsonb,text)'::regprocedure)) > 0, 'DG0 earlier api write marker kept';
  FOR f IN SELECT unnest(ARRAY['1', '2', '3', '4']) LOOP
    ASSERT position('/* exos: conditional questions ' || f || ' */' in pg_get_functiondef('public._exos_validate_answers_core(jsonb,uuid[],jsonb,boolean)'::regprocedure)) > 0, 'DG0 core marker ' || f;
  END LOOP;
  ASSERT position('/* exos: conditional questions apply */' in pg_get_functiondef('public._exos_question_upsert(uuid,uuid,uuid,jsonb,uuid)'::regprocedure)) > 0, 'DG0 upsert marker';
  ASSERT position('/* exos: conditional questions */' in pg_get_functiondef('public._exos_required_questions_for(uuid,uuid[])'::regprocedure)) > 0, 'DG0 required marker';
  RAISE NOTICE 'OK  DG0 shape: RLS, grants, no secret column, internal functions closed, search_path, markers';
END $$;

-- DG1 -------------------------------------------------------------------------
DO $$
DECLARE r text; n int;
BEGIN
  INSERT INTO public.exos_fee_adjustments (org_id, event_id, session_id, reason, note, fees_change_cents)
  VALUES (pg_temp.u('1'), pg_temp.u('e1'), 'cs_d62', 'manual', 'seed row', -1);
  r := pg_temp.st($q$UPDATE public.exos_fee_adjustments SET fees_change_cents = -2 WHERE session_id = 'cs_d62'$q$);
  ASSERT r LIKE '55000%append-only%', 'DG1 update refused: ' || r;
  r := pg_temp.st($q$DELETE FROM public.exos_fee_adjustments WHERE session_id = 'cs_d62'$q$);
  ASSERT r LIKE '55000%', 'DG1 delete refused: ' || r;
  r := pg_temp.st($q$TRUNCATE public.exos_fee_adjustments$q$);
  ASSERT r LIKE '55000%', 'DG1 truncate refused: ' || r;
  -- Deleting the order cascades (rolled back by the savepoint below).
  BEGIN
    DELETE FROM public.exos_checkout_sessions WHERE session_id = 'cs_d62';
    SELECT count(*) INTO n FROM public.exos_fee_adjustments WHERE session_id = 'cs_d62';
    ASSERT n = 0, 'DG1 cascade removed the order''s rows';
    RAISE EXCEPTION 'undo' USING ERRCODE = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments WHERE session_id = 'cs_d62') = 1, 'DG1 the order and its row are back';
  RAISE NOTICE 'OK  DG1 append-only: update / delete / truncate refused, a cascade still works';
END $$;

-- DG2 -------------------------------------------------------------------------
DO $$
DECLARE n int; s bigint; v_req uuid := gen_random_uuid(); a record;
BEGIN
  -- An organizer refund request (exos-refund) for the first refund: its actor.
  INSERT INTO public.exos_refund_requests (id, session_id, org_id, event_id, requested_by, scope, amount_cents, nonce, status, stripe_refund_id)
  VALUES (v_req, 'cs_d61', pg_temp.u('1'), pg_temp.u('e1'), pg_temp.u('a3'), 'order', 4500, 'd6-nonce-0001', 'pending', 're_d6_1');
  -- $45.00 of $135.00 back: a third of the $3.00 buyer fees.
  PERFORM public.exos_record_refund('cs_d61', 're_d6_1', 4500, 'succeeded', NULL, 'customer asked');
  SELECT count(*), sum(fees_change_cents) INTO n, s FROM public.exos_fee_adjustments WHERE session_id = 'cs_d61';
  ASSERT n = 1 AND s = -100, format('DG2 partial refund: %s rows, %s', n, s);
  SELECT * INTO a FROM public.exos_fee_adjustments WHERE session_id = 'cs_d61';
  ASSERT a.reason = 'refund' AND a.actor = pg_temp.u('a3') AND a.note = 'customer asked' AND a.org_id = pg_temp.u('1')
     AND a.event_id = pg_temp.u('e1') AND a.refund_id IS NOT NULL AND (a.detail->>'refunded_cents')::int = 4500
     AND a.currency = 'usd', 'DG2 row: ' || to_jsonb(a)::text;
  -- The webhook replays the same refund: nothing more.
  PERFORM public.exos_record_refund('cs_d61', 're_d6_1', 4500, 'succeeded', NULL, 'customer asked');
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments WHERE session_id = 'cs_d61') = 1, 'DG2 retry logs nothing';
  -- A pending refund: nothing yet.
  PERFORM public.exos_record_refund('cs_d61', 're_d6_2', 9000, 'pending');
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments WHERE session_id = 'cs_d61') = 1, 'DG2 pending logs nothing';
  -- It succeeds: the rest of the order, the rest of the fees ($3.00 in all).
  PERFORM public.exos_record_refund('cs_d61', 're_d6_2', 9000, 'succeeded');
  SELECT count(*), sum(fees_change_cents) INTO n, s FROM public.exos_fee_adjustments WHERE session_id = 'cs_d61';
  ASSERT n = 2 AND s = -300, format('DG2 full: %s rows, %s', n, s);
  -- Then fails (a bank reversal): +$2.00 back on the fees, as a new row.
  PERFORM public.exos_record_refund('cs_d61', 're_d6_2', 9000, 'failed');
  SELECT count(*), sum(fees_change_cents) INTO n, s FROM public.exos_fee_adjustments WHERE session_id = 'cs_d61';
  ASSERT n = 3 AND s = -100, format('DG2 reversal: %s rows, %s', n, s);
  ASSERT (SELECT reason FROM public.exos_fee_adjustments WHERE session_id = 'cs_d61' ORDER BY processed_at DESC, created_at DESC LIMIT 1) = 'refund_reversed'
      OR EXISTS (SELECT 1 FROM public.exos_fee_adjustments WHERE session_id = 'cs_d61' AND reason = 'refund_reversed' AND fees_change_cents = 200),
      'DG2 reversal reason';
  -- An order with no fees: nothing.
  PERFORM public.exos_record_refund('cs_d62', 're_d6_3', 4000, 'succeeded');
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments WHERE session_id = 'cs_d62' AND reason <> 'manual') = 0, 'DG2 no fees, no row';
  -- The money and the fee snapshot are as they were.
  ASSERT (SELECT sum(amount_cents) FROM public.exos_order_fees WHERE session_id = 'cs_d61') = 400, 'DG2 exos_order_fees untouched';
  ASSERT (SELECT amount_cents FROM public.exos_order_refunds WHERE refund_id = 're_d6_1') = 4500, 'DG2 refund money untouched';
  -- exos_record_refund's own rule: once refunded, a later failure doesn't move the order back.
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_d61') = 'refunded', 'DG2 order status as exos_record_refund sets it';
  RAISE NOTICE 'OK  DG2 refunds log the buyer-fee share, once, cumulatively, with reversals; money and fees untouched';
END $$;

-- DG3 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; r2 jsonb; n0 int; n1 int; e text;
BEGIN
  -- The order-edit path changes contact details only: no fee row.
  SELECT count(*) INTO n0 FROM public.exos_fee_adjustments;
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_order_update('cs_d61', '{"first_name": "Ada", "notes": "VIP"}'::jsonb);
  ASSERT (SELECT count(*) FROM public.exos_fee_adjustments) = n0, 'DG3 an order edit writes no fee row';
  -- Manual: finance credits $0.50 on ticket k1 of the order.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_fee_adjustment_record('cs_d61', -50, 'Goodwill: late doors', pg_temp.u('k1'), 'd6-key-0001');
  ASSERT r->>'reason' = 'manual' AND (r->>'fees_change_cents')::int = -50 AND r->>'actor' = pg_temp.u('a3')::text
     AND r->>'ticket_id' = pg_temp.u('k1')::text AND (r->>'duplicate')::boolean = false, 'DG3 manual: ' || r::text;
  -- The same key again (a double click): the same row.
  r2 := public.exos_fee_adjustment_record('cs_d61', -50, 'Goodwill: late doors', pg_temp.u('k1'), 'd6-key-0001');
  ASSERT r2->>'id' = r->>'id' AND (r2->>'duplicate')::boolean, 'DG3 idempotent';
  BEGIN
    PERFORM public.exos_fee_adjustment_record('cs_d62', -50, 'Other order', NULL, 'd6-key-0001');
    RAISE EXCEPTION 'DG3: a reused key on another order';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  -- Owner and manager may too.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_fee_adjustment_record('cs_d61', 25, 'Late fee re-added');
  PERFORM pg_temp.act(pg_temp.u('a2'));
  PERFORM public.exos_fee_adjustment_record('cs_d61', -25, 'Undo the late fee');
  -- Refused: scanner, outsider, another org's owner (and their own org's order is theirs only).
  FOREACH e IN ARRAY ARRAY['a4', 'a6', 'a5', 'b1'] LOOP
    PERFORM pg_temp.act(pg_temp.u(e));
    BEGIN
      PERFORM public.exos_fee_adjustment_record('cs_d61', -10, 'Not mine to do');
      RAISE EXCEPTION 'DG3: % adjusted', e;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('a3'));
  -- The rules.
  FOR e IN SELECT unnest(ARRAY[
      $q$SELECT public.exos_fee_adjustment_record('cs_d61', 0, 'Nothing')$q$,
      $q$SELECT public.exos_fee_adjustment_record('cs_d61', -10, 'x')$q$,
      format($q$SELECT public.exos_fee_adjustment_record('cs_d61', -10, 'Their ticket', %L)$q$, pg_temp.u('k3')),
      $q$SELECT public.exos_fee_adjustment_record('cs_d61', -100000000, 'Way too much')$q$,
      $q$SELECT public.exos_fee_adjustment_record('cs_d61', -10, 'Bad key', NULL, 'no')$q$]) LOOP
    ASSERT pg_temp.st(e) LIKE '22%', 'DG3 refused: ' || e || ' -> ' || pg_temp.st(e);
  END LOOP;
  ASSERT pg_temp.st($q$SELECT public.exos_fee_adjustment_record('cs_d63', -10, 'Pending order')$q$) LIKE '55000%', 'DG3 pending order refused';
  -- cs_d61 net fees now: 300 - 100 (refunds) - 50 + 25 - 25 = 150: -151 is refused, -150 is fine.
  ASSERT pg_temp.st($q$SELECT public.exos_fee_adjustment_record('cs_d61', -151, 'Below zero')$q$) LIKE '22023%below zero%',
    'DG3 never below zero: ' || pg_temp.st($q$SELECT public.exos_fee_adjustment_record('cs_d61', -151, 'Below zero')$q$);
  PERFORM public.exos_fee_adjustment_record('cs_d61', -150, 'Waive the rest');
  SELECT count(*) INTO n1 FROM public.exos_fee_adjustments WHERE reason = 'manual' AND session_id = 'cs_d61';
  ASSERT n1 = 4, 'DG3 four manual rows: ' || n1;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DG3 order edits log nothing; manual adjustments: roles, rules, idempotent, never below zero';
END $$;

-- DG4 -------------------------------------------------------------------------
-- Org B's own row (its refund).
SELECT public.exos_record_refund('cs_d69', 're_d6_9', 4000, 'succeeded') IS NOT NULL AS b_refund;
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int; e text;
BEGIN
  FOREACH e IN ARRAY ARRAY['a1', 'a2', 'a3'] LOOP
    PERFORM pg_temp.act(pg_temp.u(e));
    SELECT count(*) INTO n FROM public.exos_fee_adjustments;
    ASSERT n = (SELECT 8), format('DG4 %s reads org A''s 8 rows, got %s', e, n);
    ASSERT NOT EXISTS (SELECT 1 FROM public.exos_fee_adjustments WHERE session_id = 'cs_d69'), 'DG4 never org B''s';
  END LOOP;
  FOREACH e IN ARRAY ARRAY['a4', 'a6', 'b1', 'b2'] LOOP
    PERFORM pg_temp.act(pg_temp.u(e));
    SELECT count(*) INTO n FROM public.exos_fee_adjustments;
    ASSERT n = 0, format('DG4 %s reads nothing, got %s', e, n);
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('a5'));
  SELECT count(*) INTO n FROM public.exos_fee_adjustments;
  ASSERT n = 1 AND (SELECT session_id FROM public.exos_fee_adjustments) = 'cs_d69', 'DG4 org B''s owner reads B''s row only';
  PERFORM pg_temp.act(pg_temp.u('a1'));
  ASSERT pg_temp.st(format($q$INSERT INTO public.exos_fee_adjustments (org_id, event_id, session_id, reason, fees_change_cents)
                       VALUES (%L, %L, 'cs_d61', 'manual', -1)$q$, pg_temp.u('1'), pg_temp.u('e1')))
         LIKE '42501%', 'DG4 a client can''t insert';
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.st('SELECT count(*) FROM public.exos_fee_adjustments') LIKE '42501%', 'DG4 anon has no grant';
  ASSERT pg_temp.st($q$SELECT public.exos_fee_adjustment_record('cs_d61', -1, 'anon')$q$) LIKE '42501%', 'DG4 anon can''t record';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK  DG4 RLS: owner / manager / finance of the org only; other org isolated; anon none; no client insert'; END $$;

-- DG5 -------------------------------------------------------------------------
DO $$
DECLARE j jsonb;
BEGIN
  j := public._exos_settlement_inputs(pg_temp.u('e1'))->'fee_adjustments';
  ASSERT (j->>'count')::int = 8, 'DG5 count: ' || j::text;
  -- -100 (refunds net) - 200 (manual net) - 1 (DG1 seed)
  ASSERT (j->>'net_cents')::int = -301, 'DG5 net: ' || j::text;
  ASSERT (j->'by_reason'->>'refund')::int = -300 AND (j->'by_reason'->>'refund_reversed')::int = 200
     AND (j->'by_reason'->>'manual')::int = -201, 'DG5 by reason: ' || j::text;
  ASSERT (public._exos_settlement_inputs(pg_temp.u('e9'))->'fee_adjustments'->>'net_cents')::int = -150, 'DG5 org B''s own';
  RAISE NOTICE 'OK  DG5 settlement inputs carry the fee changes';
END $$;

-- DG6 -------------------------------------------------------------------------
DO $$
DECLARE n int; v_old text; j jsonb;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l1')) = 2, 'DG6 two lounge passes for 2 units';
  ASSERT (SELECT count(*) FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l2')) = 0, 'DG6 no pass for the poster';
  ASSERT (SELECT count(*) FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l3')) = 0, 'DG6 merch not yet';
  ASSERT (SELECT bool_and(owner_id = pg_temp.u('b1') AND org_id = pg_temp.u('1') AND event_id = pg_temp.u('e1')
                          AND status = 'active' AND order_ref = 'cs_d61' AND addon_name = 'VIP lounge')
            FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l1')), 'DG6 pass fields';
  ASSERT (SELECT count(DISTINCT barcode_secret) FROM public.exos_addon_passes) = (SELECT count(*) FROM public.exos_addon_passes),
    'DG6 one secret per pass';
  -- Turned on for merch pickup: its live line gets its pass; again does nothing.
  UPDATE public.exos_event_addons SET separate_access_barcode = true WHERE id = pg_temp.u('ad3');
  ASSERT (SELECT count(*) FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l3')) = 1, 'DG6 turned on later';
  ASSERT public._exos_addon_pass_issue(pg_temp.u('l3')) = 0, 'DG6 issue twice: nothing more';
  -- A new owner (proof of email) takes the passes, with a new secret.
  INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source)
  VALUES (pg_temp.u('l5'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('ad1'), 'VIP lounge', pg_temp.u('a1'), pg_temp.u('a1'), 1, 30, 'cs_d62', 'stripe');
  v_old := (SELECT barcode_secret FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l5'));
  UPDATE public.exos_order_addons SET owner_id = pg_temp.u('b2'), buyer_id = pg_temp.u('b2') WHERE id = pg_temp.u('l5');
  ASSERT (SELECT owner_id = pg_temp.u('b2') AND barcode_secret <> v_old FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l5')),
    'DG6 new owner, new secret';
  -- Refunded: its passes are void.
  UPDATE public.exos_order_addons SET status = 'refunded' WHERE id = pg_temp.u('l5');
  ASSERT (SELECT status FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l5')) = 'voided', 'DG6 refunded line voids';
  -- The holder reads the secret; door staff read keys only; others nothing.
  PERFORM pg_temp.act(pg_temp.u('b1'));
  j := public.exos_my_addon_passes(pg_temp.u('e1'));
  ASSERT jsonb_array_length(j) = 3 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j) x WHERE x->>'barcode_secret' IS NULL),
    'DG6 holder''s passes with secrets: ' || j::text;
  ASSERT jsonb_array_length(public.exos_my_addon_passes(NULL)) = 4, 'DG6 every event (org B''s too)';
  PERFORM pg_temp.act(pg_temp.u('b2'));
  ASSERT (SELECT bool_and(x->>'barcode_secret' IS NULL) FROM jsonb_array_elements(public.exos_my_addon_passes(pg_temp.u('e1'))) x
           WHERE x->>'status' = 'voided'), 'DG6 a void pass has no secret';
  PERFORM pg_temp.act(pg_temp.u('a4'));
  j := public.exos_event_addon_passes(pg_temp.u('e1'));
  ASSERT jsonb_array_length(j) = 5 AND position('barcode_secret' in j::text) = 0
     AND NOT EXISTS (SELECT 1 FROM public.exos_addon_passes p WHERE position(p.barcode_secret in j::text) > 0),
     'DG6 door: keys, never a secret';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(j) x WHERE jsonb_typeof(x->'door_keys'->'d') = 'object'
            AND (SELECT count(*) FROM jsonb_object_keys(x->'door_keys'->'d')) = 3) = 4, 'DG6 three days of keys per live pass';
  FOREACH v_old IN ARRAY ARRAY['a3', 'a6', 'b1'] LOOP
    PERFORM pg_temp.act(pg_temp.u(v_old));
    BEGIN
      PERFORM public.exos_event_addon_passes(pg_temp.u('e1'));
      RAISE EXCEPTION 'DG6: % read the door''s passes', v_old;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DG6 passes: per unit, turned on later, new owner rotates, refund voids; secret holder-only';
END $$;
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b1'));
  SELECT count(*) INTO n FROM public.exos_addon_passes;
  ASSERT n = 4, 'DG6 RLS: b1 reads own 4: ' || n;
  PERFORM pg_temp.act(pg_temp.u('a5'));
  SELECT count(*) INTO n FROM public.exos_addon_passes;
  ASSERT n = 1, 'DG6 RLS: org B''s owner reads B''s 1: ' || n;
  PERFORM pg_temp.act(pg_temp.u('a6'));
  SELECT count(*) INTO n FROM public.exos_addon_passes WHERE event_id = pg_temp.u('e1');
  ASSERT n = 0, 'DG6 RLS: org B''s scanner reads none of A''s';
  ASSERT pg_temp.st('SELECT barcode_secret FROM public.exos_addon_passes') LIKE '42501%', 'DG6 the secret column is not readable';
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;

-- DG7 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; p1 uuid := pg_temp.pass('l1', 1); p2 uuid := pg_temp.pass('l1', 2); pm uuid := pg_temp.pass('l3', 1);
        p4 uuid := pg_temp.pass('l4', 1); p9 uuid := pg_temp.pass('l9', 1); pv uuid := pg_temp.pass('l5', 1);
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a4'));
  -- Refused before anything is recorded.
  r := pg_temp.scan(p1, pg_temp.acode(p1), 'lm');
  ASSERT r->>'reason' = 'tickets-only-list' AND r->>'kind' = 'addon', 'DG7 add-on at the main door: ' || r::text;
  r := pg_temp.scan(p1, pg_temp.acode(p1), NULL);
  ASSERT r->>'reason' = 'tickets-only-list', 'DG7 add-on with no list: ' || r::text;
  r := pg_temp.scan(pm, pg_temp.acode(pm), 'll');
  ASSERT r->>'reason' = 'wrong-list', 'DG7 merch pass at the lounge: ' || r::text;
  r := pg_temp.scan(p1, 'A-' || p1 || ':' || pg_temp.u('b1') || ':' || floor(extract(epoch FROM now()) * 1000 / 30000)::bigint || ':forged', 'll');
  ASSERT r->>'reason' = 'barcode-rejected', 'DG7 forged: ' || r::text;
  r := pg_temp.scan(p1, pg_temp.acode(p1, now() - interval '10 minutes'), 'll');
  ASSERT r->>'reason' = 'barcode-expired', 'DG7 expired: ' || r::text;
  r := pg_temp.scan(p1, pg_temp.acode(p1, now(), pg_temp.u('b2')), 'll');
  ASSERT r->>'reason' = 'barcode-rejected', 'DG7 another holder''s code: ' || r::text;
  r := pg_temp.scan(p1, pg_temp.tcode(pg_temp.u('k1')), 'll');
  ASSERT r->>'reason' = 'barcode-rejected', 'DG7 a ticket''s code with a pass id: ' || r::text;
  r := pg_temp.scan(pv, pg_temp.acode(pv), 'll');
  ASSERT r->>'reason' = 'voided', 'DG7 void pass: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_addon_pass_checkins) = 0, 'DG7 nothing recorded yet';
  -- At its list: in, once.
  r := pg_temp.scan(p1, pg_temp.acode(p1), 'll');
  ASSERT (r->>'ok')::boolean AND r->>'reason' = 'checked-in' AND (r->>'verified')::boolean AND r->>'addon_name' = 'VIP lounge'
     AND r->>'list' = 'VIP lounge', 'DG7 in: ' || r::text;
  r := pg_temp.scan(p1, pg_temp.acode(p1), 'll');
  ASSERT r->>'reason' = 'used', 'DG7 second scan: ' || r::text;
  ASSERT (SELECT status FROM public.exos_addon_passes WHERE id = p1) = 'used', 'DG7 pass used';
  ASSERT (SELECT count(*) FROM public.exos_addon_pass_checkins WHERE pass_id = p1 AND list_id = pg_temp.u('ll')
            AND verification = 'verified' AND source = 'camera' AND gate = 'VIP lounge' AND scanned_by = pg_temp.u('a4')) = 1,
    'DG7 one check-in row';
  -- The ticket is unaffected; at the lounge it's refused, at its door it's in.
  r := pg_temp.scan(pg_temp.u('k1'), pg_temp.tcode(pg_temp.u('k1')), 'll');
  ASSERT r->>'reason' = 'addon-only-list' AND r->>'list' = 'VIP lounge', 'DG7 ticket at the lounge: ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.u('k1')) = 'active', 'DG7 ticket untouched';
  r := pg_temp.scan(pg_temp.u('k1'), pg_temp.tcode(pg_temp.u('k1')), 'lm');
  ASSERT (r->>'ok')::boolean, 'DG7 ticket at the main door: ' || r::text;
  -- A 'both' list takes both.
  r := pg_temp.scan(p2, pg_temp.acode(p2), 'lb');
  ASSERT (r->>'ok')::boolean, 'DG7 add-on at both: ' || r::text;
  r := pg_temp.scan(pg_temp.u('k2'), pg_temp.tcode(pg_temp.u('k2')), 'lb');
  ASSERT (r->>'ok')::boolean, 'DG7 ticket at both: ' || r::text;
  -- Re-entry list (pickup): in, already inside, out, in again.
  r := pg_temp.scan(pm, pg_temp.acode(pm), 'lp');
  ASSERT (r->>'ok')::boolean, 'DG7 pickup in: ' || r::text;
  r := pg_temp.scan(pm, pg_temp.acode(pm), 'lp');
  ASSERT r->>'reason' = 'already-inside', 'DG7 pickup twice: ' || r::text;
  r := pg_temp.scan(pm, pg_temp.acode(pm), 'lp', 'exit');
  ASSERT r->>'reason' = 'checked-out', 'DG7 pickup out: ' || r::text;
  r := pg_temp.scan(pm, pg_temp.acode(pm), 'lp');
  ASSERT (r->>'ok')::boolean AND (r->>'reentry')::boolean, 'DG7 pickup again: ' || r::text;
  r := pg_temp.scan(p4, pg_temp.acode(p4), 'll', 'exit');
  ASSERT r->>'reason' = 'exit-not-allowed', 'DG7 exit on a list without re-entry: ' || r::text;
  -- Typed pass id: a scanner can't; a manager can with a reason.
  r := pg_temp.scan(p4, NULL, 'll', 'entry', NULL, 'manual');
  ASSERT r->>'reason' = 'needs-manager', 'DG7 typed by a scanner: ' || r::text;
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := pg_temp.scan(p4, NULL, 'll', 'entry', NULL, 'manual');
  ASSERT r->>'reason' = 'reason-required', 'DG7 typed, no reason: ' || r::text;
  r := pg_temp.scan(p4, NULL, 'll', 'entry', NULL, 'manual', 'phone died');
  ASSERT (r->>'ok')::boolean AND NOT (r->>'verified')::boolean, 'DG7 typed by a manager: ' || r::text;
  -- Org B's pass at A's door: A's manager is not staff of org B (42501, as for a ticket).
  BEGIN
    r := pg_temp.scan(p9, pg_temp.acode(p9), 'll');
    RAISE EXCEPTION 'DG7: org A''s manager scanned org B''s pass: %', r;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a6'));
  BEGIN
    r := pg_temp.scan(pg_temp.pass('l1', 1), pg_temp.acode(pg_temp.pass('l1', 1)), 'll');
    RAISE EXCEPTION 'DG7: org B''s scanner scanned A''s pass: %', r;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- org B's scanner at B's own list, with A's event id: wrong event.
  r := pg_temp.scan(pg_temp.pass('l9', 1), pg_temp.acode(pg_temp.pass('l9', 1)), 'l9', 'entry', pg_temp.u('e1'));
  ASSERT r->>'reason' = 'wrong-event' AND NOT (r ? 'addon_name'), 'DG7 wrong event, nothing echoed: ' || r::text;
  r := pg_temp.scan(pg_temp.pass('l9', 1), pg_temp.acode(pg_temp.pass('l9', 1)), 'l9', 'entry', pg_temp.u('e9'));
  ASSERT (r->>'ok')::boolean, 'DG7 B at B: ' || r::text;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DG7 door online: add-on codes at their lists only, tickets refused at add-on lists, both, re-entry, overrides, isolation';
END $$;

-- DG8 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; r2 jsonb; p4b uuid; n int;
BEGIN
  -- A second lounge pass for b2 (a fresh line), scanned offline 5 minutes ago.
  INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source)
  VALUES (pg_temp.u('l6'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('ad1'), 'VIP lounge', pg_temp.u('b2'), pg_temp.u('b2'), 1, 30, 'cs_d62', 'stripe');
  p4b := pg_temp.pass('l6', 1);
  PERFORM pg_temp.act(pg_temp.u('a4'));
  -- At a ticket list: refused, a reject row, no forced entry.
  r := public.exos_check_in_offline(pg_temp.u('f0001'), p4b, pg_temp.u('e1'), now() - interval '5 minutes',
                                    pg_temp.acode(p4b, now() - interval '5 minutes'), 'camera', NULL, 'Door DG', pg_temp.u('lm'), 'entry');
  ASSERT NOT (r->>'ok')::boolean AND r->>'reason' = 'tickets-only-list' AND (r->>'conflict')::boolean AND NOT (r ? 'forced'),
    'DG8 add-on offline at the main door: ' || r::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_scan_rejects WHERE ticket_id_attempted = p4b::text AND org_id = pg_temp.u('1')
                   AND reason_detail = 'offline-replay:tickets-only-list'), 'DG8 reject row';
  ASSERT (SELECT status FROM public.exos_addon_passes WHERE id = p4b) = 'active', 'DG8 still good';
  -- At the lounge: in; the same ref again answers the same.
  r := public.exos_check_in_offline(pg_temp.u('f0002'), p4b, pg_temp.u('e1'), now() - interval '5 minutes',
                                    pg_temp.acode(p4b, now() - interval '5 minutes'), 'camera', NULL, 'Door DG', pg_temp.u('ll'), 'entry');
  ASSERT (r->>'ok')::boolean AND r->>'reason' = 'checked-in', 'DG8 add-on offline at the lounge: ' || r::text;
  r2 := public.exos_check_in_offline(pg_temp.u('f0002'), p4b, pg_temp.u('e1'), now() - interval '5 minutes',
                                     pg_temp.acode(p4b, now() - interval '5 minutes'), 'camera', NULL, 'Door DG', pg_temp.u('ll'), 'entry');
  ASSERT (r2->>'duplicate')::boolean AND r2->>'reason' = 'checked-in', 'DG8 retry: ' || r2::text;
  ASSERT (SELECT count(*) FROM public.exos_addon_pass_checkins WHERE pass_id = p4b) = 1, 'DG8 one row';
  ASSERT (SELECT offline_scanned_at IS NOT NULL FROM public.exos_addon_pass_checkins WHERE pass_id = p4b), 'DG8 offline time kept';
  ASSERT (SELECT org_id = pg_temp.u('1') AND event_id = pg_temp.u('e1') FROM public.exos_checkin_client_refs WHERE client_ref = pg_temp.u('f0002')),
    'DG8 ref under the pass''s org and event';
  -- Another scan of it offline: used (the door double-admitted).
  r := public.exos_check_in_offline(pg_temp.u('f0003'), p4b, pg_temp.u('e1'), now() - interval '4 minutes',
                                    pg_temp.acode(p4b, now() - interval '4 minutes'), 'camera', NULL, 'Door DG', pg_temp.u('ll'), 'entry');
  ASSERT r->>'reason' = 'used' AND (r->>'conflict')::boolean, 'DG8 double: ' || r::text;
  -- A ticket replayed at the lounge: refused, recorded, never forced in, still good at its door.
  r := public.exos_check_in_offline(pg_temp.u('f0004'), pg_temp.u('k3'), pg_temp.u('e1'), now() - interval '5 minutes',
                                    pg_temp.tcode(pg_temp.u('k3'), now() - interval '5 minutes'), 'camera', NULL, 'Door DG', pg_temp.u('ll'), 'entry');
  ASSERT NOT (r->>'ok')::boolean AND r->>'reason' = 'addon-only-list' AND NOT (r ? 'forced'), 'DG8 ticket offline at the lounge: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkins WHERE ticket_id = pg_temp.u('k3')), 'DG8 no forced row';
  ASSERT EXISTS (SELECT 1 FROM public.exos_scan_rejects WHERE ticket_id_attempted = pg_temp.u('k3')::text
                   AND reason_detail = 'offline-replay:addon-only-list'), 'DG8 ticket reject row';
  r := public.exos_check_in_offline(pg_temp.u('f0005'), pg_temp.u('k3'), pg_temp.u('e1'), now() - interval '4 minutes',
                                    pg_temp.tcode(pg_temp.u('k3'), now() - interval '4 minutes'), 'camera', NULL, 'Door DG', pg_temp.u('lm'), 'entry');
  ASSERT (r->>'ok')::boolean, 'DG8 the ticket at its door: ' || r::text;
  -- Org B's scanner can't replay A's pass.
  PERFORM pg_temp.act(pg_temp.u('a6'));
  BEGIN
    r := public.exos_check_in_offline(pg_temp.u('f0006'), p4b, pg_temp.u('e1'), now() - interval '5 minutes',
                                      pg_temp.acode(p4b, now() - interval '5 minutes'), 'camera', NULL, 'Door DG', pg_temp.u('ll'), 'entry');
    RAISE EXCEPTION 'DG8: org B''s scanner replayed A''s pass: %', r;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act(NULL);
  -- The list rules: add-on ids must be the event's; a ticket list keeps none.
  ASSERT pg_temp.st(format($q$UPDATE public.exos_checkin_lists SET addon_ids = ARRAY['%s']::uuid[] WHERE id = '%s'$q$,
                           pg_temp.u('ad9'), pg_temp.u('lp'))) LIKE '42501%add-on is not on this event%', 'DG8 other event''s add-on refused';
  UPDATE public.exos_checkin_lists SET admits = 'tickets', addon_ids = ARRAY[pg_temp.u('ad1')] WHERE id = pg_temp.u('lb');
  ASSERT (SELECT addon_ids IS NULL FROM public.exos_checkin_lists WHERE id = pg_temp.u('lb')), 'DG8 a ticket list keeps no add-ons';
  RAISE NOTICE 'OK  DG8 offline merge: add-on codes at their list, refused elsewhere (reject, no forced row); tickets refused at add-on lists';
END $$;

-- The API's add-on write takes the setting (exos_api_write as the key's creator).
DO $$
DECLARE v_key uuid := gen_random_uuid(); r jsonb;
BEGIN
  INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by)
  VALUES (v_key, pg_temp.u('1'), 'd6 key', 'sk_live_d6', 'd6hash', ARRAY['events:write'], pg_temp.u('a1'));
  PERFORM pg_temp.act(pg_temp.u('a1')); -- exos-api runs it as the key's creator
  r := public.exos_api_write(v_key, 'add_on.update', pg_temp.u('ad2')::text, '{"add_on": {"separate_access_barcode": true}}'::jsonb, NULL);
  ASSERT (SELECT separate_access_barcode FROM public.exos_event_addons WHERE id = pg_temp.u('ad2')), 'DG8 API write: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u('l2')) = 1, 'DG8 the poster line got its pass';
  -- POST /v1/tickets/:id/check-in with a pass id and its code, at the pickup list.
  UPDATE public.exos_api_keys SET scopes = ARRAY['events:write', 'checkin:write'] WHERE id = v_key;
  r := public.exos_api_write(v_key, 'ticket.check_in', pg_temp.pass('l2', 1)::text,
         jsonb_build_object('barcode', pg_temp.acode(pg_temp.pass('l2', 1)), 'list_id', pg_temp.u('lp')), NULL);
  ASSERT (r->>'ok')::boolean AND r->>'kind' = 'addon', 'DG8 API check-in of a pass: ' || r::text;
  r := public.exos_api_write(v_key, 'ticket.check_in', pg_temp.pass('l2', 1)::text,
         jsonb_build_object('barcode', pg_temp.acode(pg_temp.pass('l2', 1)), 'list_id', pg_temp.u('lm')), NULL);
  ASSERT r->>'reason' = 'tickets-only-list', 'DG8 API: at a ticket list: ' || r::text;
  ASSERT pg_temp.st(format($q$SELECT public.exos_api_write(%L, 'ticket.check_in', %L, '{}'::jsonb, NULL)$q$, v_key, pg_temp.pass('l9', 1)))
         LIKE 'P0002%', 'DG8 API: another org''s pass is not found';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DG8 the API''s add-on write takes separate_access_barcode; the API checks a pass in';
END $$;

-- DG9 -------------------------------------------------------------------------
DO $$
DECLARE
  qa jsonb; qb jsonb; qc jsonb; qs jsonb; qt jsonb; qo jsonb; r jsonb; e text;
  v_e uuid := pg_temp.u('e1');
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  qa := public.exos_save_event_question(v_e, '{"label": "Bringing a guest?", "kind": "single_choice", "options": ["Yes", "No"], "required": true, "scope": "order"}');
  qb := public.exos_save_event_question(v_e, jsonb_build_object('label', 'Guest name', 'kind', 'text', 'required', true, 'scope', 'order',
                                                                'parent_question_id', qa->>'id', 'parent_values', jsonb_build_array('Yes')));
  ASSERT qb->>'parent_question_id' = qa->>'id' AND qb->'parent_values' = '["Yes"]'::jsonb, 'DG9 condition saved: ' || qb::text;
  qs := public.exos_save_event_question(v_e, '{"label": "Size", "kind": "single_choice", "options": ["S", "L"], "required": false, "scope": "ticket"}');
  qc := public.exos_save_event_question(v_e, jsonb_build_object('label', 'Tall fit?', 'kind', 'checkbox', 'scope', 'ticket',
                                                                'parent_question_id', qs->>'id', 'parent_values', jsonb_build_array('L')));
  qt := public.exos_save_event_question(v_e, '{"label": "Notes", "kind": "text", "scope": "order"}');
  -- Save rules.
  FOR e IN SELECT unnest(ARRAY[
      -- a text parent
      format('{"label": "x", "kind": "text", "scope": "order", "parent_question_id": "%s", "parent_values": ["a"]}', qt->>'id'),
      -- a value that isn't an option
      format('{"label": "x", "kind": "text", "scope": "order", "parent_question_id": "%s", "parent_values": ["Maybe"]}', qa->>'id'),
      -- no value
      format('{"label": "x", "kind": "text", "scope": "order", "parent_question_id": "%s", "parent_values": []}', qa->>'id'),
      -- an order question under a per-ticket parent
      format('{"label": "x", "kind": "text", "scope": "order", "parent_question_id": "%s", "parent_values": ["L"]}', qs->>'id'),
      -- a checkbox parent needs "true"
      format('{"label": "x", "kind": "text", "scope": "ticket", "parent_question_id": "%s", "parent_values": ["Yes"]}', qc->>'id'),
      -- not a question id
      '{"label": "x", "kind": "text", "scope": "order", "parent_question_id": "nope", "parent_values": ["Yes"]}']) LOOP
    ASSERT pg_temp.st(format('SELECT public.exos_save_event_question(%L, %L::jsonb)', v_e, e)) LIKE '22023%',
      'DG9 refused: ' || e || ' -> ' || pg_temp.st(format('SELECT public.exos_save_event_question(%L, %L::jsonb)', v_e, e));
  END LOOP;
  -- Another event's question as the parent: refused, without its label.
  qo := public.exos_save_event_question(pg_temp.u('e2'), '{"label": "Secret other question", "kind": "checkbox", "scope": "order"}');
  e := pg_temp.st(format('SELECT public.exos_save_event_question(%L, %L::jsonb)', v_e,
         format('{"label": "x", "kind": "text", "scope": "order", "parent_question_id": "%s", "parent_values": ["true"]}', qo->>'id')));
  ASSERT e LIKE '22023%not one of this event%' AND position('Secret' in e) = 0, 'DG9 cross-event parent: ' || e;
  -- A cycle: A under B (B is under A).
  e := pg_temp.st(format('SELECT public.exos_save_event_question(%L, %L::jsonb, %L)', v_e,
         format('{"parent_question_id": "%s", "parent_values": ["x"]}', qb->>'id'), qa->>'id'));
  ASSERT e LIKE '22023%', 'DG9 cycle (text parent) refused: ' || e;
  r := public.exos_save_event_question(v_e, '{"label": "Pick", "kind": "single_choice", "options": ["x", "y"], "scope": "order"}');
  PERFORM public.exos_save_event_question(v_e, jsonb_build_object('parent_question_id', r->>'id', 'parent_values', '["x"]'::jsonb), (qa->>'id')::uuid);
  e := pg_temp.st(format('SELECT public.exos_save_event_question(%L, %L::jsonb, %L)', v_e,
         format('{"parent_question_id": "%s", "parent_values": ["Yes"]}', qa->>'id'), r->>'id'));
  ASSERT e LIKE '22023%loop%', 'DG9 cycle refused: ' || e;
  ASSERT pg_temp.st(format('SELECT public.exos_save_event_question(%L, %L::jsonb, %L)', v_e,
                           format('{"parent_question_id": "%s", "parent_values": ["Yes"]}', r->>'id'), r->>'id')) LIKE '22023%',
    'DG9 its own parent refused';
  PERFORM public.exos_save_event_question(v_e, '{"parent_question_id": null}'::jsonb, (qa->>'id')::uuid);
  -- A parent with an active child: no archive, no kind change, no dropping the option it uses.
  ASSERT pg_temp.st(format('SELECT public.exos_archive_event_question(%L)', qa->>'id')) LIKE '22023%Guest name%', 'DG9 archive parent refused';
  ASSERT pg_temp.st(format('SELECT public.exos_save_event_question(%L, %L::jsonb, %L)', v_e, '{"options": ["No", "Maybe"]}', qa->>'id'))
         LIKE '22023%', 'DG9 dropping the used option refused';
  ASSERT pg_temp.st(format('SELECT public.exos_save_event_question(%L, %L::jsonb, %L)', v_e, '{"scope": "ticket"}', qa->>'id'))
         LIKE '22023%', 'DG9 moving the parent per ticket refused';
  -- Archive the child first, then the parent is free.
  PERFORM public.exos_archive_event_question((qb->>'id')::uuid);
  PERFORM public.exos_archive_event_question((qa->>'id')::uuid);
  -- Restoring the child while its parent is archived: refused.
  ASSERT pg_temp.st(format('SELECT public.exos_archive_event_question(%L, false)', qb->>'id')) LIKE '22023%archived%', 'DG9 restore under an archived parent';
  PERFORM public.exos_archive_event_question((qa->>'id')::uuid, false);
  PERFORM public.exos_archive_event_question((qb->>'id')::uuid, false);
  -- Archive the other test question (Pick) so only the guest pair, size pair and notes stay asked.
  PERFORM public.exos_archive_event_question((r->>'id')::uuid);
  PERFORM pg_temp.act(NULL);

  -- Validation through the event's questions.
  r := public._exos_validate_answers(v_e, ARRAY[pg_temp.u('t1'), pg_temp.u('t1')],
         jsonb_build_object('order', jsonb_build_object(qa->>'id', 'No', qb->>'id', 'Stale name'),
                            'tickets', jsonb_build_array(jsonb_build_object(qs->>'id', 'S', qc->>'id', true))), true);
  ASSERT (r->>'ok')::boolean AND r->'answers'->'order' = jsonb_build_object(qa->>'id', 'No')
     AND r->'answers'->'tickets' = jsonb_build_array(jsonb_build_object(qs->>'id', 'S'), '{}'::jsonb),
     'DG9 hidden: not required, dropped: ' || r::text;
  r := public._exos_validate_answers(v_e, ARRAY[pg_temp.u('t1')],
         jsonb_build_object('order', jsonb_build_object(qa->>'id', 'Yes')), true);
  ASSERT NOT (r->>'ok')::boolean AND r->'problems' @> jsonb_build_array(jsonb_build_object('code', 'required', 'question_id', qb->>'id')),
    'DG9 shown: required: ' || r::text;
  ASSERT public._exos_required_questions_for(v_e, ARRAY[pg_temp.u('t1')]), 'DG9 the guest question is required of everyone';
  -- Recording: the hidden answer isn't kept.
  ASSERT public._exos_record_answers(pg_temp.u('1'), v_e, 'cs_d6_q1', ARRAY[pg_temp.u('t1')],
           jsonb_build_object('order', jsonb_build_object(qa->>'id', 'No', qb->>'id', 'Stale name')), true, false, 'checkout', pg_temp.u('b1')) = 1,
    'DG9 one answer recorded';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_question_answers WHERE order_ref = 'cs_d6_q1' AND question_id = (qb->>'id')::uuid),
    'DG9 the hidden answer is dropped';
  ASSERT public._exos_record_answers(pg_temp.u('1'), v_e, 'cs_d6_q2', ARRAY[pg_temp.u('t1')],
           jsonb_build_object('order', jsonb_build_object(qa->>'id', 'Yes', qb->>'id', ' Bob ')), true, false, 'checkout', pg_temp.u('b1')) = 2,
    'DG9 shown and answered: both recorded';
  ASSERT pg_temp.st(format($q$SELECT public._exos_record_answers(%L, %L, 'cs_d6_q3', ARRAY[%L]::uuid[], %L::jsonb, true, false, 'checkout', NULL)$q$,
                           pg_temp.u('1'), v_e, pg_temp.u('t1'), jsonb_build_object('order', jsonb_build_object(qa->>'id', 'Yes'))))
         LIKE '22023%Guest name%required%', 'DG9 shown and missing: refused';
  -- The free-claim guard only counts unconditional required questions.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_save_event_question(v_e, '{"required": false}'::jsonb, (qa->>'id')::uuid);
  PERFORM pg_temp.act(NULL);
  ASSERT NOT public._exos_required_questions_for(v_e, ARRAY[pg_temp.u('t1')]), 'DG9 a conditional required question doesn''t force the answered claim';
  -- The public RPC carries the condition.
  r := public.exos_public_event_questions(v_e);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'questions') x
                  WHERE x->>'id' = qb->>'id' AND x->>'parent_question_id' = qa->>'id' AND x->'parent_values' = '["Yes"]'::jsonb),
    'DG9 public questions: ' || r::text;
  RAISE NOTICE 'OK  DG9 conditional questions: save rules, cycles, parents kept, hidden dropped, shown enforced, claim guard, public RPC';
END $$;

-- DG10 ------------------------------------------------------------------------
-- The shared cases: src/lib/conditionalQuestions.test.ts reads the JSON
-- between the DG6-CASES markers and runs it through _shared/questions.ts.
-- "q" names questions; "tiers" names ticket types A / B; "expect" lists
-- "code|question|ticket" (any order); "normalized" is the expected answers.
CREATE TEMP TABLE dg_cases AS SELECT $cases$
-- DG6-CASES-BEGIN
{
  "tiers": { "A": "aaaaaaaa-0000-0000-0000-000000000001", "B": "aaaaaaaa-0000-0000-0000-000000000002" },
  "questions": {
    "guest":     { "id": "d6c00000-0000-0000-0000-000000000001", "label": "Guest?", "kind": "single_choice", "options": ["Yes", "No"], "required": true, "scope": "order", "tier_ids": null },
    "guestname": { "id": "d6c00000-0000-0000-0000-000000000002", "label": "Guest name", "kind": "text", "options": [], "required": true, "scope": "order", "tier_ids": null, "parent_question_id": "d6c00000-0000-0000-0000-000000000001", "parent_values": ["Yes"] },
    "size":      { "id": "d6c00000-0000-0000-0000-000000000003", "label": "Size", "kind": "single_choice", "options": ["S", "M", "L"], "required": false, "scope": "ticket", "tier_ids": null },
    "sizenote":  { "id": "d6c00000-0000-0000-0000-000000000004", "label": "Size note", "kind": "text", "options": [], "required": true, "scope": "ticket", "tier_ids": null, "parent_question_id": "d6c00000-0000-0000-0000-000000000003", "parent_values": ["L"] },
    "diet":      { "id": "d6c00000-0000-0000-0000-000000000005", "label": "Diet", "kind": "multiple_choice", "options": ["Vegan", "Halal", "None"], "required": false, "scope": "order", "tier_ids": null },
    "dietnote":  { "id": "d6c00000-0000-0000-0000-000000000006", "label": "Diet note", "kind": "long_text", "options": [], "required": true, "scope": "ticket", "tier_ids": null, "parent_question_id": "d6c00000-0000-0000-0000-000000000005", "parent_values": ["Vegan", "Halal"] },
    "agree":     { "id": "d6c00000-0000-0000-0000-000000000007", "label": "Photos ok?", "kind": "checkbox", "options": [], "required": false, "scope": "order", "tier_ids": null },
    "agreenote": { "id": "d6c00000-0000-0000-0000-000000000008", "label": "Instagram", "kind": "text", "options": [], "required": true, "scope": "order", "tier_ids": null, "parent_question_id": "d6c00000-0000-0000-0000-000000000007", "parent_values": ["true"] },
    "plusone":   { "id": "d6c00000-0000-0000-0000-000000000009", "label": "Plus one?", "kind": "single_choice", "options": ["Yes", "No"], "required": true, "scope": "order", "tier_ids": null, "parent_question_id": "d6c00000-0000-0000-0000-000000000001", "parent_values": ["Yes"] },
    "plusname":  { "id": "d6c00000-0000-0000-0000-00000000000a", "label": "Plus one name", "kind": "text", "options": [], "required": true, "scope": "order", "tier_ids": null, "parent_question_id": "d6c00000-0000-0000-0000-000000000009", "parent_values": ["Yes"] },
    "viponly":   { "id": "d6c00000-0000-0000-0000-00000000000b", "label": "VIP pick", "kind": "text", "options": [], "required": true, "scope": "ticket", "tier_ids": ["aaaaaaaa-0000-0000-0000-000000000002"], "parent_question_id": "d6c00000-0000-0000-0000-000000000003", "parent_values": ["M"] },
    "age":       { "id": "d6c00000-0000-0000-0000-00000000000c", "label": "Age", "kind": "number", "options": [], "required": false, "scope": "order", "tier_ids": null, "min_value": 0, "max_value": 120, "parent_question_id": "d6c00000-0000-0000-0000-000000000001", "parent_values": ["Yes"] }
  },
  "cases": [
    { "name": "hidden child is not required", "q": ["guest", "guestname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "No" } }, "expect": [], "normalized": { "order": { "guest": "No" }, "tickets": [{}] } },
    { "name": "hidden child's answer is dropped", "q": ["guest", "guestname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "No", "guestname": "Bob" } }, "expect": [], "normalized": { "order": { "guest": "No" }, "tickets": [{}] } },
    { "name": "hidden child's invalid answer is dropped too", "q": ["guest", "guestname", "age"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "No", "guestname": 42, "age": "old" } }, "expect": [], "normalized": { "order": { "guest": "No" }, "tickets": [{}] } },
    { "name": "shown child is required", "q": ["guest", "guestname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "Yes" } }, "expect": ["required|guestname|"] },
    { "name": "shown child answered", "q": ["guest", "guestname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "Yes", "guestname": " Bob " } }, "expect": [],
      "normalized": { "order": { "guest": "Yes", "guestname": "Bob" }, "tickets": [{}] } },
    { "name": "shown child keeps its own rules", "q": ["guest", "age"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "Yes", "age": 130 } }, "expect": ["out_of_range|age|"] },
    { "name": "unanswered parent hides the child", "q": ["guest", "guestname"], "tiers": ["A"], "require": true,
      "answers": {}, "expect": ["required|guest|"] },
    { "name": "an invalid parent answer hides the child", "q": ["guest", "guestname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "Maybe", "guestname": "" } }, "expect": ["invalid_choice|guest|"] },
    { "name": "not required when require is off", "q": ["guest", "guestname"], "tiers": ["A"], "require": false,
      "answers": { "order": { "guest": "Yes" } }, "expect": [], "normalized": { "order": { "guest": "Yes" }, "tickets": [{}] } },
    { "name": "per-ticket parent, per ticket", "q": ["size", "sizenote"], "tiers": ["A", "A"], "require": true,
      "answers": { "tickets": [{ "size": "L" }, { "size": "S" }] }, "expect": ["required|sizenote|1"] },
    { "name": "per-ticket parent answered", "q": ["size", "sizenote"], "tiers": ["A", "A"], "require": true,
      "answers": { "tickets": [{ "size": "L", "sizenote": "tall" }, { "size": "S", "sizenote": "dropped" }] }, "expect": [],
      "normalized": { "order": {}, "tickets": [{ "size": "L", "sizenote": "tall" }, { "size": "S" }] } },
    { "name": "per-order parent shows a per-ticket child on every ticket", "q": ["diet", "dietnote"], "tiers": ["A", "A"], "require": true,
      "answers": { "order": { "diet": ["Halal"] }, "tickets": [{ "dietnote": "no pork" }] }, "expect": ["required|dietnote|2"] },
    { "name": "multiple choice: any picked value shows it", "q": ["diet", "dietnote"], "tiers": ["A"], "require": true,
      "answers": { "order": { "diet": ["None", "Vegan"] }, "tickets": [{ "dietnote": " oat milk " }] }, "expect": [],
      "normalized": { "order": { "diet": ["Vegan", "None"] }, "tickets": [{ "dietnote": "oat milk" }] } },
    { "name": "multiple choice: no shown value hides it", "q": ["diet", "dietnote"], "tiers": ["A", "A"], "require": true,
      "answers": { "order": { "diet": ["None"] } }, "expect": [], "normalized": { "order": { "diet": ["None"] }, "tickets": [{}, {}] } },
    { "name": "checkbox ticked shows it", "q": ["agree", "agreenote"], "tiers": ["A"], "require": true,
      "answers": { "order": { "agree": true } }, "expect": ["required|agreenote|"] },
    { "name": "checkbox unticked hides it", "q": ["agree", "agreenote"], "tiers": ["A"], "require": true,
      "answers": { "order": { "agree": false, "agreenote": "@me" } }, "expect": [], "normalized": { "order": {}, "tickets": [{}] } },
    { "name": "a chain hidden at the top hides all", "q": ["guest", "plusone", "plusname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "No", "plusone": "Yes", "plusname": "x" } }, "expect": [],
      "normalized": { "order": { "guest": "No" }, "tickets": [{}] } },
    { "name": "a chain shown at the top", "q": ["guest", "plusone", "plusname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "Yes", "plusone": "Yes" } }, "expect": ["required|plusname|"] },
    { "name": "a chain, middle answered no", "q": ["guest", "plusone", "plusname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "Yes", "plusone": "No", "plusname": "dropped" } }, "expect": [],
      "normalized": { "order": { "guest": "Yes", "plusone": "No" }, "tickets": [{}] } },
    { "name": "a parent not asked hides the child", "q": ["guestname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guestname": "Bob" } }, "expect": [], "normalized": { "order": {}, "tickets": [{}] } },
    { "name": "the child's own ticket types still apply", "q": ["size", "viponly"], "tiers": ["A", "B"], "require": true,
      "answers": { "tickets": [{ "size": "M" }, { "size": "M" }] }, "expect": ["required|viponly|2"] },
    { "name": "a hidden child for a ticket type it isn't asked of is still not_for_ticket_type", "q": ["size", "viponly"], "tiers": ["A"], "require": true,
      "answers": { "tickets": [{ "size": "S", "viponly": "x" }] }, "expect": ["not_for_ticket_type|viponly|1"] },
    { "name": "unknown keys are still refused", "q": ["guest", "guestname"], "tiers": ["A"], "require": true,
      "answers": { "order": { "guest": "No", "nope": 1 } }, "expect": ["unknown_question|nope|"] }
  ]
}
-- DG6-CASES-END
$cases$::text AS doc;

DO $$
DECLARE
  doc jsonb := (SELECT substring(doc from '-- DG6-CASES-BEGIN(.*)-- DG6-CASES-END')::jsonb FROM dg_cases);
  c jsonb; qs jsonb; tiers uuid[]; res jsonb; got text[]; want text[]; bad text := ''; n int := 0; id_to_name jsonb;
BEGIN
  SELECT jsonb_object_agg(value->>'id', key) INTO id_to_name FROM jsonb_each(doc->'questions');
  FOR c IN SELECT x FROM jsonb_array_elements(doc->'cases') x LOOP
    qs := (SELECT jsonb_agg(doc->'questions'->(nm #>> '{}')) FROM jsonb_array_elements(c->'q') nm);
    tiers := ARRAY(SELECT (doc->'tiers'->>(t #>> '{}'))::uuid FROM jsonb_array_elements(c->'tiers') WITH ORDINALITY AS u(t, i) ORDER BY i);
    res := public._exos_validate_answers_core(qs, tiers,
      CASE WHEN jsonb_typeof(c->'answers') = 'object' THEN
        jsonb_strip_nulls(jsonb_build_object(
          'order', CASE WHEN jsonb_typeof(c->'answers'->'order') = 'object'
                        THEN (SELECT coalesce(jsonb_object_agg(coalesce(doc->'questions'->k->>'id', k), v), '{}'::jsonb) FROM jsonb_each(c->'answers'->'order') e(k, v))
                        ELSE c->'answers'->'order' END,
          'tickets', CASE WHEN jsonb_typeof(c->'answers'->'tickets') = 'array'
                          THEN (SELECT coalesce(jsonb_agg(CASE WHEN jsonb_typeof(t) = 'object'
                                   THEN (SELECT coalesce(jsonb_object_agg(coalesce(doc->'questions'->k->>'id', k), v), '{}'::jsonb) FROM jsonb_each(t) e(k, v))
                                   ELSE t END ORDER BY i), '[]'::jsonb)
                                  FROM jsonb_array_elements(c->'answers'->'tickets') WITH ORDINALITY AS u(t, i))
                          ELSE c->'answers'->'tickets' END))
      ELSE c->'answers' END,
      (c->>'require')::boolean);
    got := ARRAY(SELECT s FROM (SELECT (p->>'code') || '|' || coalesce(id_to_name->>(p->>'question_id'), p->>'question_id', '') || '|' || coalesce(p->>'ticket', '') AS s
                   FROM jsonb_array_elements(res->'problems') p) z ORDER BY s COLLATE "C");
    want := ARRAY(SELECT s FROM (SELECT x #>> '{}' AS s FROM jsonb_array_elements(c->'expect') x) z ORDER BY s COLLATE "C");
    IF got IS DISTINCT FROM want THEN
      bad := bad || format(E'\n  %s: want %s got %s', c->>'name', want, got);
    ELSIF c ? 'normalized' THEN
      IF jsonb_build_object(
           'order', (SELECT coalesce(jsonb_object_agg(id_to_name->>k, v), '{}'::jsonb) FROM jsonb_each(res->'answers'->'order') e(k, v)),
           'tickets', (SELECT coalesce(jsonb_agg((SELECT coalesce(jsonb_object_agg(id_to_name->>k, v), '{}'::jsonb) FROM jsonb_each(t) e(k, v)) ORDER BY i), '[]'::jsonb)
                         FROM jsonb_array_elements(res->'answers'->'tickets') WITH ORDINALITY AS u(t, i)))
         IS DISTINCT FROM c->'normalized' THEN
        bad := bad || format(E'\n  %s: normalised %s', c->>'name', res->'answers');
      END IF;
    END IF;
    n := n + 1;
  END LOOP;
  ASSERT bad = '', 'DG10: SQL disagrees with the shared cases:' || bad;
  RAISE NOTICE 'OK  DG10 TS/SQL parity: % shared conditional cases agree in SQL', n;
END $$;

DO $$ BEGIN RAISE NOTICE 'test_dice_gaps_6: all passed'; END $$;
ROLLBACK;
