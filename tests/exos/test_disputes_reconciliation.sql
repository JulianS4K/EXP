-- ============================================================================
-- Disputes + daily Stripe reconciliation (mig 20261001101000). Self-contained
-- (dd prefix), rolled back.
--   D1 objects, grants, RLS: the webhook entry point and the recorder are
--      service role only, definer, search_path pinned; clients can't write
--      any of the new tables; the snapshot and runs tables are service only
--   D2 lifecycle: created -> row + session columns + one dispute-opened per
--      owner / finance member (not manager, not scanner); a replay and an
--      update queue nothing new; evidence submitted sticks; lost -> closed,
--      recovery candidate (amount + fee), not_recovered by default, one
--      dispute-lost; a replayed earlier event can't reopen it; raw keeps no
--      evidence / buyer data; the mail payload has no buyer email or order id
--   D3 won -> dispute-won once; policy on -> a lost dispute is
--      recovery_pending; a dispute first seen closed sends only the close mail
--   D4 RLS: owner / manager / finance read their org's disputes; a scanner,
--      another org and anon read none
--   R1 reconciliation record: issues upserted with the session's org (never a
--      passed one when there is a session), re-running the same day is a
--      no-op, an issue not found again inside the checked window is
--      resolved (outside it: left alone), found again -> reopened, the run
--      row is one per day
--   R2 reading issues: platform-admin RPC scope; org owner / finance see
--      their org's (table + RPC), manager / scanner / other org / anon don't;
--      org-less issues are admin only
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('dd000000-0000-0000-0000-0000000000a0','dd-owner@x.com',now()),
  ('dd000000-0000-0000-0000-0000000000a1','dd-finance@x.com',now()),
  ('dd000000-0000-0000-0000-0000000000a2','dd-scanner@x.com',now()),
  ('dd000000-0000-0000-0000-0000000000a3','dd-manager@x.com',now()),
  ('dd000000-0000-0000-0000-0000000000a4','dd-finance-off@x.com',now()),
  ('dd000000-0000-0000-0000-0000000000b1','dd-buyer@x.com',now()),
  ('dd000000-0000-0000-0000-0000000000c0','dd-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('dd000000-0000-0000-0000-000000000001','DD <Org>','dd-org','dd000000-0000-0000-0000-0000000000a0'),
  ('dd000000-0000-0000-0000-000000000002','DD Other','dd-other','dd000000-0000-0000-0000-0000000000c0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('dd000000-0000-0000-0000-000000000001','dd000000-0000-0000-0000-0000000000a0','owner',false),
  ('dd000000-0000-0000-0000-000000000001','dd000000-0000-0000-0000-0000000000a1','finance',false),
  ('dd000000-0000-0000-0000-000000000001','dd000000-0000-0000-0000-0000000000a2','scanner',false),
  ('dd000000-0000-0000-0000-000000000001','dd000000-0000-0000-0000-0000000000a3','manager',false),
  ('dd000000-0000-0000-0000-000000000001','dd000000-0000-0000-0000-0000000000a4','finance',true),
  ('dd000000-0000-0000-0000-000000000002','dd000000-0000-0000-0000-0000000000c0','owner',false);
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('dd000000-0000-0000-0000-0000000000e1','dd000000-0000-0000-0000-000000000001','DD Show','published',now() + interval '10 days','Hall',100,0),
  ('dd000000-0000-0000-0000-0000000000e9','dd000000-0000-0000-0000-000000000002','Other Show','published',now() + interval '10 days','Hall',100,0);
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,payment_intent) VALUES
  ('cs_dd1','dd000000-0000-0000-0000-0000000000e1','dd000000-0000-0000-0000-000000000001','dd000000-0000-0000-0000-0000000000b1','dd-buyer@x.com',2,5000,'usd','fulfilled','pi_dd1'),
  ('cs_dd2','dd000000-0000-0000-0000-0000000000e1','dd000000-0000-0000-0000-000000000001','dd000000-0000-0000-0000-0000000000b1','dd-buyer@x.com',1,2500,'usd','fulfilled','pi_dd2'),
  ('cs_dd3','dd000000-0000-0000-0000-0000000000e1','dd000000-0000-0000-0000-000000000001','dd000000-0000-0000-0000-0000000000b1','dd-buyer@x.com',1,2500,'usd','fulfilled','pi_dd3'),
  ('cs_dd9','dd000000-0000-0000-0000-0000000000e9','dd000000-0000-0000-0000-000000000002','dd000000-0000-0000-0000-0000000000b1','dd-buyer@x.com',1,1000,'usd','fulfilled','pi_dd9');
INSERT INTO public.exos_order_payments(session_id,org_id,payment_intent,amount_cents,status) VALUES
  ('cs_dd1','dd000000-0000-0000-0000-000000000001','pi_dd1',5000,'succeeded'),
  ('cs_dd9','dd000000-0000-0000-0000-000000000002','pi_dd9',1000,'succeeded');

-- D1 -------------------------------------------------------------------------
DO $$
DECLARE f text; t text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_record_dispute_event(text,text,text,text,integer,text,text,text,integer,text,timestamptz,boolean,boolean,jsonb)',
    'public.exos_reconcile_stripe_record(date,timestamptz,timestamptz,jsonb,jsonb)',
    'public._exos_queue_dispute_mail(uuid,text)'
  ] LOOP
    ASSERT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure), 'D1: '||f||' not definer';
    ASSERT (SELECT proconfig::text FROM pg_proc WHERE oid = f::regprocedure) LIKE '%search_path=public, pg_temp%', 'D1: '||f||' search_path';
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'D1: anon runs '||f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'D1: authenticated runs '||f;
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_record_dispute_event(text,text,text,text,integer,text,text,text,integer,text,timestamptz,boolean,boolean,jsonb)', 'EXECUTE'),
    'D1: service_role can''t record';
  ASSERT has_function_privilege('authenticated', 'public.exos_reconciliation_issues_for(uuid,boolean,integer)', 'EXECUTE'), 'D1: issues RPC not callable';
  ASSERT NOT has_function_privilege('anon', 'public.exos_reconciliation_issues_for(uuid,boolean,integer)', 'EXECUTE'), 'D1: anon reads issues';
  FOREACH t IN ARRAY ARRAY['exos_disputes','exos_stripe_balance_txns','exos_reconciliation_issues','exos_reconciliation_runs'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.'||t)::regclass), 'D1: no RLS on '||t;
    ASSERT NOT has_table_privilege('anon', 'public.'||t, 'SELECT'), 'D1: anon reads '||t;
    ASSERT NOT has_table_privilege('authenticated', 'public.'||t, 'INSERT'), 'D1: clients insert '||t;
    ASSERT NOT has_table_privilege('authenticated', 'public.'||t, 'UPDATE'), 'D1: clients update '||t;
    ASSERT NOT has_table_privilege('authenticated', 'public.'||t, 'DELETE'), 'D1: clients delete '||t;
  END LOOP;
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_stripe_balance_txns', 'SELECT'), 'D1: clients read the Stripe snapshot';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_reconciliation_runs', 'SELECT'), 'D1: clients read the runs';
  ASSERT (SELECT NOT recover_lost_disputes FROM public.exos_org_billing WHERE org_id = 'dd000000-0000-0000-0000-000000000001'),
    'D1: recovery policy defaults off';
  RAISE NOTICE 'OK  D1 objects, grants, RLS';
END $$;

-- D2 -------------------------------------------------------------------------
DO $$
DECLARE v text; d public.exos_disputes%ROWTYPE; n int; p jsonb;
BEGIN
  v := public.exos_record_dispute_event(
    p_session_id => 'cs_dd1', p_dispute_id => 'du_dd1', p_status => 'needs_response', p_reason => 'fraudulent',
    p_amount_cents => 5000, p_provider_event_id => 'evt_dd1', p_charge_id => 'ch_dd1', p_payment_intent => 'pi_dd1',
    p_fee_cents => 1500, p_currency => 'USD', p_evidence_due_by => '2026-10-15T23:59:59Z', p_evidence_submitted => false,
    p_livemode => false,
    p_raw => '{"id":"du_dd1","amount":5000,"status":"needs_response","evidence":{"customer_email_address":"dd-buyer@x.com","customer_name":"Buyer"},"metadata":{"x":"y"},"charge":{"id":"ch_dd1","billing_details":{"email":"dd-buyer@x.com"}},"evidence_details":{"due_by":1792108799,"submission_count":0,"extra":"z"},"balance_transactions":[{"id":"txn_1","fee":1500,"amount":-5000,"description":"dd-buyer@x.com"}]}');
  ASSERT v = 'needs_response', 'D2: returns the stored status, got '||v;
  SELECT * INTO d FROM public.exos_disputes WHERE dispute_id = 'du_dd1';
  ASSERT d.org_id = 'dd000000-0000-0000-0000-000000000001' AND d.event_id = 'dd000000-0000-0000-0000-0000000000e1'
     AND d.session_id = 'cs_dd1' AND d.charge_id = 'ch_dd1' AND d.payment_intent = 'pi_dd1', 'D2: links';
  ASSERT d.amount_cents = 5000 AND d.fee_cents = 1500 AND d.currency = 'usd' AND d.reason = 'fraudulent'
     AND d.status = 'needs_response' AND d.evidence_due_by = '2026-10-15T23:59:59Z' AND NOT d.evidence_submitted
     AND d.closed_at IS NULL AND d.recovery_status = 'none' AND d.livemode = false, 'D2: fields';
  ASSERT (SELECT dispute_status FROM public.exos_checkout_sessions WHERE session_id = 'cs_dd1') = 'needs_response',
    'D2: session columns still written';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_dd1') = 'fulfilled', 'D2: order untouched';
  ASSERT d.raw ? 'id' AND NOT d.raw ? 'evidence' AND NOT d.raw ? 'metadata' AND d.raw ->> 'charge' IS NULL
     AND NOT (d.raw -> 'evidence_details') ? 'extra' AND d.raw::text NOT LIKE '%dd-buyer%', 'D2: raw allowlisted: '||d.raw;
  ASSERT (d.raw -> 'balance_transactions' -> 0 ->> 'fee')::int = 1500, 'D2: raw keeps the fee';

  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'dispute-opened' AND payload ->> 'dispute_id' = 'du_dd1';
  ASSERT n = 2, 'D2: dispute-opened to owner + finance, got '||n;
  ASSERT (SELECT array_agg(to_email ORDER BY to_email) FROM public.exos_mail WHERE template = 'dispute-opened' AND payload ->> 'dispute_id' = 'du_dd1')
       = ARRAY['dd-finance@x.com','dd-owner@x.com'], 'D2: recipients (no manager, scanner or disabled finance)';
  SELECT payload INTO p FROM public.exos_mail WHERE template = 'dispute-opened' AND to_email = 'dd-owner@x.com';
  ASSERT (p ->> 'amount_cents')::int = 5000 AND p ->> 'reason' = 'fraudulent' AND p ->> 'evidence_due_by' IS NOT NULL
     AND p -> 'org' ->> 'name' = 'DD <Org>' AND p -> 'event' ->> 'id' = 'dd000000-0000-0000-0000-0000000000e1'
     AND (p ->> 'livemode')::boolean = false AND (p ->> 'fee_cents')::int = 1500, 'D2: payload '||p;
  ASSERT p::text NOT LIKE '%dd-buyer%' AND p::text NOT LIKE '%cs_dd1%' AND p::text NOT LIKE '%pi_dd1%',
    'D2: no buyer email or order reference in organizer mail';

  -- Replay of the same event, then an update with evidence: no new opened mail.
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd1', p_dispute_id => 'du_dd1', p_status => 'needs_response',
    p_reason => 'fraudulent', p_amount_cents => 5000, p_provider_event_id => 'evt_dd1');
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd1', p_dispute_id => 'du_dd1', p_status => 'under_review',
    p_amount_cents => 5000, p_provider_event_id => 'evt_dd2', p_evidence_submitted => true);
  SELECT * INTO d FROM public.exos_disputes WHERE dispute_id = 'du_dd1';
  ASSERT d.status = 'under_review' AND d.evidence_submitted AND d.fee_cents = 1500 AND d.charge_id = 'ch_dd1'
     AND d.evidence_due_by IS NOT NULL AND d.last_event_id = 'evt_dd2', 'D2: update merges, keeps known fields';
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd1', p_dispute_id => 'du_dd1', p_status => 'under_review',
    p_provider_event_id => 'evt_dd3', p_evidence_submitted => false);
  ASSERT (SELECT evidence_submitted FROM public.exos_disputes WHERE dispute_id = 'du_dd1'), 'D2: evidence submitted sticks';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'dispute-opened' AND payload ->> 'dispute_id' = 'du_dd1') = 2,
    'D2: one opened mail per person, however many events';
  ASSERT (SELECT count(*) FROM public.exos_disputes WHERE dispute_id = 'du_dd1') = 1, 'D2: one row per dispute';

  -- Lost.
  v := public.exos_record_dispute_event(p_session_id => 'cs_dd1', p_dispute_id => 'du_dd1', p_status => 'lost',
    p_reason => 'fraudulent', p_amount_cents => 5000, p_provider_event_id => 'evt_dd4', p_fee_cents => 1500);
  ASSERT v = 'lost', 'D2: lost returned (the webhook voids on it)';
  SELECT * INTO d FROM public.exos_disputes WHERE dispute_id = 'du_dd1';
  ASSERT d.status = 'lost' AND d.closed_at IS NOT NULL AND d.recovery_status = 'not_recovered'
     AND d.recovery_candidate_cents = 6500, 'D2: lost, candidate amount + fee, policy off';
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd1', p_dispute_id => 'du_dd1', p_status => 'lost',
    p_provider_event_id => 'evt_dd4');
  v := public.exos_record_dispute_event(p_session_id => 'cs_dd1', p_dispute_id => 'du_dd1', p_status => 'needs_response',
    p_provider_event_id => 'evt_dd1');
  ASSERT v = 'lost' AND (SELECT status FROM public.exos_disputes WHERE dispute_id = 'du_dd1') = 'lost',
    'D2: a replayed earlier event can''t reopen a closed dispute';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'dispute-lost' AND payload ->> 'dispute_id' = 'du_dd1') = 2,
    'D2: dispute-lost once per person';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'dispute-opened' AND payload ->> 'dispute_id' = 'du_dd1') = 2,
    'D2: no second opened mail after the replay';
  ASSERT (SELECT (payload ->> 'recovery_candidate_cents')::int FROM public.exos_mail
           WHERE template = 'dispute-lost' AND to_email = 'dd-owner@x.com') = 6500, 'D2: lost mail carries the candidate';
  -- Bad input still refused (exos_record_dispute validates first).
  BEGIN
    PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd1', p_dispute_id => 'du_dd1', p_status => 'Bad Status!');
    RAISE EXCEPTION 'D2: bad status accepted';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%invalid status%', 'D2: bad status refused: '||SQLERRM;
  END;
  BEGIN
    PERFORM public.exos_record_dispute_event(p_session_id => 'cs_nope', p_dispute_id => 'du_dd0', p_status => 'needs_response');
    RAISE EXCEPTION 'D2: unknown session accepted';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%unknown session%', 'D2: unknown session refused: '||SQLERRM;
  END;
  RAISE NOTICE 'OK  D2 dispute lifecycle, mails once per event type';
END $$;

-- D3 -------------------------------------------------------------------------
DO $$
DECLARE d public.exos_disputes%ROWTYPE;
BEGIN
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd2', p_dispute_id => 'du_dd2', p_status => 'needs_response',
    p_amount_cents => 2500, p_provider_event_id => 'evt_dd20');
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd2', p_dispute_id => 'du_dd2', p_status => 'won',
    p_amount_cents => 2500, p_provider_event_id => 'evt_dd21');
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd2', p_dispute_id => 'du_dd2', p_status => 'won',
    p_provider_event_id => 'evt_dd21');
  SELECT * INTO d FROM public.exos_disputes WHERE dispute_id = 'du_dd2';
  ASSERT d.status = 'won' AND d.closed_at IS NOT NULL AND d.recovery_status = 'none' AND d.recovery_candidate_cents IS NULL,
    'D3: won is closed, nothing to recover';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'dispute-won' AND payload ->> 'dispute_id' = 'du_dd2') = 2,
    'D3: dispute-won once per person';

  -- Policy on; this dispute is first seen already lost (webhook missed created).
  UPDATE public.exos_org_billing SET recover_lost_disputes = true WHERE org_id = 'dd000000-0000-0000-0000-000000000001';
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd3', p_dispute_id => 'du_dd3', p_status => 'lost',
    p_amount_cents => 2500, p_fee_cents => 1500, p_provider_event_id => 'evt_dd30');
  SELECT * INTO d FROM public.exos_disputes WHERE dispute_id = 'du_dd3';
  ASSERT d.recovery_status = 'recovery_pending' AND d.recovery_candidate_cents = 4000, 'D3: policy on -> recovery_pending';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'dispute-opened' AND payload ->> 'dispute_id' = 'du_dd3') = 0
     AND (SELECT count(*) FROM public.exos_mail WHERE template = 'dispute-lost' AND payload ->> 'dispute_id' = 'du_dd3') = 2,
    'D3: first seen closed: only the close mail';
  -- The other org's dispute (for RLS below).
  PERFORM public.exos_record_dispute_event(p_session_id => 'cs_dd9', p_dispute_id => 'du_dd9', p_status => 'needs_response',
    p_amount_cents => 1000, p_provider_event_id => 'evt_dd90');
  ASSERT (SELECT array_agg(to_email) FROM public.exos_mail WHERE payload ->> 'dispute_id' = 'du_dd9') = ARRAY['dd-other@x.com'],
    'D3: the other org''s owner only';
  RAISE NOTICE 'OK  D3 won / recovery policy / first seen closed';
END $$;

-- D4 -------------------------------------------------------------------------
CREATE TEMP TABLE dd_out(tag text, n int);
GRANT ALL ON dd_out TO authenticated, anon;
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a1', true);  -- finance
INSERT INTO dd_out SELECT 'finance', count(*) FROM public.exos_disputes;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a0', true);  -- owner
INSERT INTO dd_out SELECT 'owner', count(*) FROM public.exos_disputes;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a3', true);  -- manager
INSERT INTO dd_out SELECT 'manager', count(*) FROM public.exos_disputes;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a2', true);  -- scanner
INSERT INTO dd_out SELECT 'scanner', count(*) FROM public.exos_disputes;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a4', true);  -- disabled finance
INSERT INTO dd_out SELECT 'finance-off', count(*) FROM public.exos_disputes;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000c0', true);  -- other org
INSERT INTO dd_out SELECT 'other', count(*) FROM public.exos_disputes;
SELECT set_config('app.uid', '', true);
INSERT INTO dd_out SELECT 'signed-out', count(*) FROM public.exos_disputes;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  PERFORM 1 FROM public.exos_disputes;
  RAISE EXCEPTION 'D4: anon read disputes';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT n FROM dd_out WHERE tag = 'finance') = 3, 'D4: finance sees the org''s 3';
  ASSERT (SELECT n FROM dd_out WHERE tag = 'owner') = 3, 'D4: owner sees 3';
  ASSERT (SELECT n FROM dd_out WHERE tag = 'manager') = 3, 'D4: manager sees 3';
  ASSERT (SELECT n FROM dd_out WHERE tag = 'scanner') = 0, 'D4: scanner sees none';
  ASSERT (SELECT n FROM dd_out WHERE tag = 'finance-off') = 0, 'D4: disabled finance sees none';
  ASSERT (SELECT n FROM dd_out WHERE tag = 'other') = 1, 'D4: other org sees only its own';
  ASSERT (SELECT n FROM dd_out WHERE tag = 'signed-out') = 0, 'D4: signed out sees none';
  RAISE NOTICE 'OK  D4 dispute RLS';
END $$;

-- R1 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; i public.exos_reconciliation_issues%ROWTYPE;
  v_issues jsonb := jsonb_build_array(
    jsonb_build_object('kind','fee_mismatch','key','ch_dd1','stripe_id','ch_dd1','session_id','cs_dd1',
                       'org_id','dd000000-0000-0000-0000-000000000002',   -- wrong org passed: the session's wins
                       'occurred_at', now() - interval '1 day', 'detail', jsonb_build_object('stripe_fee_cents', 175, 'exos_fee_cents', 170)),
    jsonb_build_object('kind','stripe_payment_missing','key','ch_orphan','stripe_id','ch_orphan',
                       'occurred_at', now() - interval '1 day', 'detail', jsonb_build_object('amount_cents', 900)),
    jsonb_build_object('kind','exos_refund_missing','key','re_dd9','stripe_id','re_dd9','session_id','cs_dd9',
                       'occurred_at', now() - interval '2 days', 'detail', '{}'::jsonb),
    jsonb_build_object('kind','fee_mismatch','key','ch_dd1','session_id','cs_dd1','occurred_at', now() - interval '1 day'),  -- duplicate
    jsonb_build_object('kind','not_a_kind','key','x','occurred_at', now()));
BEGIN
  -- An old open issue outside any window this test checks.
  INSERT INTO public.exos_reconciliation_issues(kind,key,occurred_at,org_id)
  VALUES ('amount_mismatch','ch_old', now() - interval '40 days','dd000000-0000-0000-0000-000000000001');

  r := public.exos_reconcile_stripe_record(current_date, now() - interval '3 days', now(), v_issues, '{"txns": 12}');
  ASSERT (r ->> 'found')::int = 3 AND (r ->> 'resolved')::int = 0, 'R1: 3 found (dupes / bad kinds dropped): '||r;
  SELECT * INTO i FROM public.exos_reconciliation_issues WHERE kind = 'fee_mismatch' AND key = 'ch_dd1';
  ASSERT i.org_id = 'dd000000-0000-0000-0000-000000000001' AND i.session_id = 'cs_dd1' AND i.seen_days = 1
     AND i.resolved_at IS NULL, 'R1: org from the session, not the payload';
  ASSERT (SELECT org_id IS NULL FROM public.exos_reconciliation_issues WHERE key = 'ch_orphan'), 'R1: orphan has no org';
  ASSERT (SELECT org_id FROM public.exos_reconciliation_issues WHERE key = 're_dd9') = 'dd000000-0000-0000-0000-000000000002', 'R1: re_dd9 org';

  -- Same day again: nothing changes but timestamps.
  r := public.exos_reconcile_stripe_record(current_date, now() - interval '3 days', now(), v_issues, '{"txns": 12}');
  ASSERT (SELECT seen_days FROM public.exos_reconciliation_issues WHERE key = 'ch_dd1') = 1, 'R1: same-day rerun is a no-op';
  ASSERT (SELECT count(*) FROM public.exos_reconciliation_runs WHERE run_day = current_date) = 1, 'R1: one run row per day';
  ASSERT (SELECT txns FROM public.exos_reconciliation_runs WHERE run_day = current_date) = 12, 'R1: run stats';

  -- Next day: the fee mismatch is fixed (not found), the others are still there.
  r := public.exos_reconcile_stripe_record(current_date + 1, now() - interval '3 days', now(), v_issues - 0 - 2, NULL);
  ASSERT (r ->> 'resolved')::int = 1, 'R1: one resolved: '||r;
  ASSERT (SELECT resolved_at IS NOT NULL FROM public.exos_reconciliation_issues WHERE key = 'ch_dd1'), 'R1: fixed issue resolved';
  ASSERT (SELECT seen_days FROM public.exos_reconciliation_issues WHERE key = 'ch_orphan') = 2, 'R1: seen on a second day';
  ASSERT (SELECT resolved_at IS NULL FROM public.exos_reconciliation_issues WHERE key = 'ch_old'), 'R1: outside the window: left open';

  -- Found again later: reopened.
  r := public.exos_reconcile_stripe_record(current_date + 2, now() - interval '3 days', now(), v_issues, NULL);
  ASSERT (SELECT resolved_at IS NULL AND seen_days = 2 FROM public.exos_reconciliation_issues WHERE key = 'ch_dd1'), 'R1: reopened';
  BEGIN
    PERFORM public.exos_reconcile_stripe_record(current_date, now(), now() - interval '1 day', '[]', NULL);
    RAISE EXCEPTION 'R1: bad window accepted';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%bad window%', 'R1: bad window refused';
  END;
  RAISE NOTICE 'OK  R1 reconciliation issues recorded, resolved, reopened; idempotent per day';
END $$;

-- R2 -------------------------------------------------------------------------
CREATE TEMP TABLE dd_rq(tag text, n int, err text);
GRANT ALL ON dd_rq TO authenticated, anon;
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a1', true);  -- finance
INSERT INTO dd_rq SELECT 'finance-table', count(*), NULL FROM public.exos_reconciliation_issues;
INSERT INTO dd_rq SELECT 'finance-rpc', count(*), NULL FROM public.exos_reconciliation_issues_for('dd000000-0000-0000-0000-000000000001', true);
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a0', true);  -- owner
INSERT INTO dd_rq SELECT 'owner-table', count(*), NULL FROM public.exos_reconciliation_issues;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a3', true);  -- manager
INSERT INTO dd_rq SELECT 'manager-table', count(*), NULL FROM public.exos_reconciliation_issues;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000a2', true);  -- scanner
INSERT INTO dd_rq SELECT 'scanner-table', count(*), NULL FROM public.exos_reconciliation_issues;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000c0', true);  -- other org owner
INSERT INTO dd_rq SELECT 'other-table', count(*), NULL FROM public.exos_reconciliation_issues;
DO $$
DECLARE who text; org uuid;
BEGIN
  FOR who, org IN VALUES
    ('dd000000-0000-0000-0000-0000000000a3', 'dd000000-0000-0000-0000-000000000001'::uuid),  -- manager
    ('dd000000-0000-0000-0000-0000000000a2', 'dd000000-0000-0000-0000-000000000001'::uuid),  -- scanner
    ('dd000000-0000-0000-0000-0000000000c0', 'dd000000-0000-0000-0000-000000000001'::uuid),  -- other org
    ('dd000000-0000-0000-0000-0000000000a1', NULL::uuid),                                     -- finance, all orgs
    ('', 'dd000000-0000-0000-0000-000000000001'::uuid)                                        -- signed out
  LOOP
    PERFORM set_config('app.uid', who, true);
    BEGIN
      PERFORM public.exos_reconciliation_issues_for(org);
      INSERT INTO dd_rq VALUES ('rpc-allowed:'||coalesce(nullif(who, ''), 'anon')||':'||coalesce(org::text, 'all'), 1, NULL);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
END $$;
RESET ROLE;
-- A platform admin (the harness stub says no one is; swap it for this
-- transaction only).
CREATE OR REPLACE FUNCTION public.exos_is_admin() RETURNS boolean
  LANGUAGE sql STABLE AS $$ SELECT current_setting('app.uid', true) = 'dd000000-0000-0000-0000-0000000000ad' $$;
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'dd000000-0000-0000-0000-0000000000ad', true);
INSERT INTO dd_rq SELECT 'admin-rpc-all', count(*), NULL FROM public.exos_reconciliation_issues_for(NULL, true);
INSERT INTO dd_rq SELECT 'admin-rpc-org2', count(*), NULL FROM public.exos_reconciliation_issues_for('dd000000-0000-0000-0000-000000000002');
INSERT INTO dd_rq SELECT 'admin-table', count(*), NULL FROM public.exos_reconciliation_issues;
INSERT INTO dd_rq SELECT 'admin-disputes', count(*), NULL FROM public.exos_disputes;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  PERFORM 1 FROM public.exos_reconciliation_issues;
  RAISE EXCEPTION 'R2: anon read issues';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
DO $$
BEGIN
  PERFORM 1 FROM public.exos_stripe_balance_txns;
  RAISE EXCEPTION 'R2: anon read the Stripe snapshot';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;
DO $$
DECLARE bad text;
BEGIN
  -- Org 1 has ch_dd1 and ch_old; ch_orphan (no org) and re_dd9 (org 2) aren't theirs.
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'finance-table') = 2, 'R2: finance reads their org''s 2';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'finance-rpc') = 2, 'R2: finance RPC';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'owner-table') = 2, 'R2: owner reads 2';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'manager-table') = 0, 'R2: manager reads none';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'scanner-table') = 0, 'R2: scanner reads none';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'other-table') = 1, 'R2: other org reads only its own';
  SELECT string_agg(tag, ', ') INTO bad FROM dd_rq WHERE tag LIKE 'rpc-allowed:%';
  ASSERT bad IS NULL, 'R2: RPC let through: '||bad;
  -- Platform admin: everything, org-less included.
  ASSERT (SELECT count(*) FROM public.exos_reconciliation_issues WHERE org_id IS NULL) = 1, 'R2: orphan stored';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'admin-rpc-all') = 4, 'R2: admin RPC sees all 4';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'admin-rpc-org2') = 1, 'R2: admin RPC narrowed to an org';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'admin-table') = 4, 'R2: admin table read sees all 4';
  ASSERT (SELECT n FROM dd_rq WHERE tag = 'admin-disputes') = 4, 'R2: admin reads every dispute';
  RAISE NOTICE 'OK  R2 reconciliation issues: admin + org owner / finance only';
END $$;

ROLLBACK;
