-- ============================================================================
-- Org audit log (mig 20261109100000). Self-contained (BEGIN / ROLLBACK; ids
-- md5('0a7d:' || x)).
--   A0 shape: RLS on; reads only (no client or service-role write grant);
--      definer helpers pinned and revoked; every patch marker; the triggers
--   A1 an edit under RLS is logged: a tier's price (one row, [old, new], the
--      owner as actor), a sold-count bump is not; event / voucher / quota
--      creates; a member's role change and removal; voucher.issue
--   A2 UPDATE / DELETE / TRUNCATE raise for the owner and the service role
--   A3 anon and authenticated can't call _exos_audit; a role header from a
--      browser request is ignored
--   A4 money: a refund claim, a fee adjustment (a duplicate is no new row),
--      the comp budget, a refund-ask decline, invite settings, a role-scope
--      set / reset, an API key create / scopes / revoke
--   A5 an API key actor: kind api_key, the key's id and its creator, never
--      the key's hash or plaintext; a PAT and an OAuth app through the header
--   A6 no cross-org reads: the table under RLS, exos_org_audit_list (42501
--      for another org's owner and for a scanner), the API scope
--   A7 no email or phone: no such column; the CHECK refuses one in changes;
--      reasons and short values are masked; a voucher's email and code stay
--      out
--   A8 a failed audit write is a WARNING: the action stands
--   A9 export.run: exos_audit_export (roles, kinds, the event of another
--      org), the fans export logs itself
--   A10 member.approve / member.reject log once each (the membership trigger
--      stays out); oauth_app.delete logs in each org with a live grant
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT md5('0a7d:' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO authenticated, anon, service_role;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO authenticated, anon, service_role;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO authenticated, anon, service_role;
-- Rows of org 1 for one action (as the owner of the table, past RLS).
CREATE FUNCTION pg_temp.n(p_action text, p_org text DEFAULT '1') RETURNS int LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.exos_org_audit WHERE org_id = pg_temp.u(p_org) AND action = p_action
$$;
GRANT EXECUTE ON FUNCTION pg_temp.n(text, text) TO authenticated, anon, service_role;
CREATE FUNCTION pg_temp.last(p_action text, p_org text DEFAULT '1') RETURNS public.exos_org_audit LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.exos_org_audit WHERE org_id = pg_temp.u(p_org) AND action = p_action ORDER BY id DESC LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION pg_temp.last(text, text) TO authenticated, anon, service_role;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('o1'), 'oa-o1@x.com', now()), (pg_temp.u('m1'), 'oa-m1@x.com', now()),
  (pg_temp.u('f1'), 'oa-f1@x.com', now()), (pg_temp.u('s1'), 'oa-s1@x.com', now()),
  (pg_temp.u('o2'), 'oa-o2@x.com', now()), (pg_temp.u('b1'), 'oa-b1@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'OA Hall', 'oa-hall', pg_temp.u('o1')),
  (pg_temp.u('2'), 'OA Other', 'oa-other', pg_temp.u('o2'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('o1'), 'owner'), (pg_temp.u('1'), pg_temp.u('m1'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('f1'), 'finance'), (pg_temp.u('1'), pg_temp.u('s1'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('o2'), 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'OA Night', 'oa-night', 'published', now() + interval '3 days', 500, 0, 'usd', pg_temp.u('o1')),
  (pg_temp.u('e9'), pg_temp.u('2'), 'OA Elsewhere', 'oa-else', 'published', now() + interval '3 days', 500, 0, 'usd', pg_temp.u('o2'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold) VALUES
  (pg_temp.u('t1'), pg_temp.u('e1'), 'GA', 40, 200, 0),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'GA', 30, 200, 0);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents,
            currency, status, payment_intent, fulfilled_at) VALUES
  ('cs_oa_1', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'oa-b1@x.com', 2, 8000, 'usd', 'fulfilled', 'pi_oa_1', now());
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref) VALUES
  (pg_temp.u('k1'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'oa-b1@x.com', 'active',
   'oa-secret-1', 40, 'cs_oa_1');

-- A0 -------------------------------------------------------------------------
DO $$
DECLARE f text; m text;
BEGIN
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_org_audit'::regclass), 'A0 RLS on';
  ASSERT NOT has_table_privilege('anon', 'public.exos_org_audit', 'SELECT'), 'A0 anon reads';
  ASSERT has_table_privilege('authenticated', 'public.exos_org_audit', 'SELECT'), 'A0 authenticated reads';
  FOREACH f IN ARRAY ARRAY['authenticated', 'service_role', 'anon'] LOOP
    ASSERT NOT has_table_privilege(f, 'public.exos_org_audit', 'INSERT,UPDATE,DELETE,TRUNCATE'), 'A0 writes: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
      'public._exos_audit(uuid,text,text,text,uuid,jsonb,bigint,text,text,uuid,uuid,text)',
      'public._exos_audit_actor(uuid,uuid,uuid,text)', 'public._exos_tg_audit_row()',
      'public.exos_org_audit_list(uuid,uuid,uuid,text,timestamptz,timestamptz,bigint,integer)',
      'public.exos_audit_export(uuid,text,integer,uuid)'] LOOP
    ASSERT (SELECT prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'] FROM pg_proc WHERE oid = f::regprocedure),
      'A0 definer, search_path pinned: ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'A0 anon executes ' || f;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_org_audit_list(uuid,uuid,uuid,text,timestamptz,timestamptz,bigint,integer)', 'EXECUTE'),
    'A0 the list is for signed-in staff';
  ASSERT has_function_privilege('authenticated', 'public.exos_audit_export(uuid,text,integer,uuid)', 'EXECUTE'), 'A0 the export log';
  FOREACH m IN ARRAY ARRAY['refund.issue', 'refund_ask.decline', 'fee.adjust', 'comp.issue_batch', 'comp.budget_set', 'ticket.void',
      'ticket.print_void', 'pos.reverse', 'pos.paid_out', 'pos.drawer_close', 'pos.drawer_recount', 'gift_card.void',
      'gift_card.reissue', 'donation.offline_refund', 'donation.delete', 'payout.mark', 'payout.cancel', 'payout.instant',
      'promoter.settle', 'promoter.payout_record', 'promoter.payout_cancel', 'settlement.update', 'settlement.finalize',
      'settlement.reopen', 'member.approve', 'member.reject', 'invite.settings', 'oauth_app.delete', 'voucher.issue',
      'tier.price_steps', 'tier.channel_price', 'export.run',
      'order.group_cover', 'hold.group_cancel',  -- these two: mig 20261110110000 (group pay 2)
      'platform.group_pay'] LOOP  -- mig 20261111120000 (the group pay switch)
    ASSERT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                     AND position('/* exos: audit ' || m || ' */' in pg_get_functiondef(p.oid)) > 0), 'A0 marker ' || m;
  END LOOP;
  ASSERT (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
            AND pg_get_functiondef(p.oid) ~ '/\* exos: audit [a-z_]+\.[a-z_]+ \*/') = 38, 'A0 38 patched functions';  -- +1 exos_org_followers_export (mig 20261111110000), +1 exos_set_group_pay_enabled (mig 20261111120000)
  ASSERT (SELECT count(DISTINCT tgrelid) FROM pg_trigger WHERE tgname IN ('exos_audit_ins_del', 'exos_audit_upd')) = 10, 'A0 ten tables';
  RAISE NOTICE 'OK  A0 RLS, read-only grants, definer helpers pinned and revoked, 38 patched functions, 10 audited tables';
END $$;

-- A1 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE a public.exos_org_audit; v_n int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('o1'));
  UPDATE public.exos_ticket_tiers SET price = 45 WHERE id = pg_temp.u('t1');
  ASSERT pg_temp.n('tier.update') = 1, 'A1 one tier.update row';
  a := pg_temp.last('tier.update');
  ASSERT a.changes = '{"price": [40, 45]}'::jsonb, 'A1 changes ' || a.changes::text;
  ASSERT a.actor_uid = pg_temp.u('o1') AND a.actor_kind = 'user' AND a.actor_role = 'owner' AND a.source = 'dashboard'
         AND a.entity_type = 'tier' AND a.entity_id = pg_temp.u('t1')::text AND a.event_id = pg_temp.u('e1'), 'A1 actor and entity ' || row_to_json(a)::text;
  -- A sale's counter is not an edit.
  RESET ROLE;
  UPDATE public.exos_ticket_tiers SET sold = sold + 1 WHERE id = pg_temp.u('t1');
  UPDATE public.exos_events SET tickets_sold = tickets_sold + 1 WHERE id = pg_temp.u('e1');
  SET ROLE authenticated;
  ASSERT pg_temp.n('tier.update') = 1 AND pg_temp.n('event.update') = 0, 'A1 counters log nothing';
  -- Creates under RLS.
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, currency, created_by)
  VALUES (pg_temp.u('e2'), pg_temp.u('1'), 'OA Two', 'oa-two', 'draft', now() + interval '9 days', 100, 'usd', pg_temp.u('o1'));
  a := pg_temp.last('event.create');
  ASSERT a.changes ->> 'name' IS NOT NULL AND a.changes -> 'name' = '[null, "OA Two"]'::jsonb AND NOT a.changes ? 'description',
    'A1 event.create names a few fields ' || a.changes::text;
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e2');
  ASSERT pg_temp.n('event.publish') = 1, 'A1 publish';
  INSERT INTO public.exos_quotas (id, event_id, org_id, name, size) VALUES (pg_temp.u('q1'), pg_temp.u('e1'), pg_temp.u('1'), 'Floor', 50);
  INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES (pg_temp.u('q1'), pg_temp.u('t1'));
  ASSERT pg_temp.n('quota.create') = 1 AND pg_temp.n('quota.tier_add') = 1, 'A1 quota create + tier add';
  INSERT INTO public.exos_vouchers (id, event_id, code, max_uses, reserved_email) VALUES (pg_temp.u('v1'), pg_temp.u('e1'), 'OAPRESALE', 5, 'oa-b1@x.com');
  a := pg_temp.last('voucher.create');
  ASSERT a.changes -> 'max_uses' = '[null, 5]'::jsonb AND a.changes::text !~ 'OAPRESALE' AND a.changes::text !~ '@', 'A1 voucher ' || a.changes::text;
  -- Member edits through RLS (the owner).
  UPDATE public.exos_org_memberships SET role = 'content' WHERE org_id = pg_temp.u('1') AND user_id = pg_temp.u('m1');
  a := pg_temp.last('member.role_change');
  ASSERT a.changes = '{"role": ["manager", "content"]}'::jsonb AND a.entity_id = pg_temp.u('m1')::text, 'A1 role change ' || a.changes::text;
  UPDATE public.exos_org_memberships SET disabled = true WHERE org_id = pg_temp.u('1') AND user_id = pg_temp.u('m1');
  ASSERT pg_temp.n('member.remove') = 1, 'A1 member.remove';
  UPDATE public.exos_org_memberships SET disabled = false, role = 'manager' WHERE org_id = pg_temp.u('1') AND user_id = pg_temp.u('m1');
  ASSERT pg_temp.n('member.restore') = 1, 'A1 member.restore';
  -- voucher.issue: the RPC's hint names the insert.
  PERFORM public.exos_issue_voucher(pg_temp.u('e1'), NULL, NULL, true, NULL, 1, NULL, 'comp', 'OAISSUE1');
  ASSERT pg_temp.n('voucher.issue') = 1 AND pg_temp.n('voucher.create') = 1, 'A1 voucher.issue';
  RAISE NOTICE 'OK  A1 RLS edits logged ([old, new], the owner), counters not; creates, publish, quota, voucher, member';
END $$;
RESET ROLE;

-- A2 -------------------------------------------------------------------------
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st('UPDATE public.exos_org_audit SET reason = ''x''');
  ASSERT s LIKE '55000%', 'A2 owner update: ' || s;
  s := pg_temp.st('DELETE FROM public.exos_org_audit');
  ASSERT s LIKE '55000%', 'A2 owner delete: ' || s;
  s := pg_temp.st('TRUNCATE public.exos_org_audit');
  ASSERT s LIKE '55000%', 'A2 owner truncate: ' || s;
END $$;
SET ROLE service_role;
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st('UPDATE public.exos_org_audit SET reason = ''x''');
  ASSERT s NOT LIKE 'ok%', 'A2 service update: ' || s;
  s := pg_temp.st('DELETE FROM public.exos_org_audit');
  ASSERT s NOT LIKE 'ok%', 'A2 service delete: ' || s;
  s := pg_temp.st('TRUNCATE public.exos_org_audit');
  ASSERT s NOT LIKE 'ok%', 'A2 service truncate: ' || s;
  s := pg_temp.st($q$INSERT INTO public.exos_org_audit (org_id, actor_kind, action, entity_type, source)
                     VALUES ('00000000-0000-0000-0000-000000000001', 'service', 'event.update', 'event', 'system')$q$);
  ASSERT s LIKE '42501%', 'A2 service insert: ' || s;
  RAISE NOTICE 'OK  A2 UPDATE / DELETE / TRUNCATE raise (owner: append-only; service role too); no direct insert';
END $$;
RESET ROLE;

-- A3 -------------------------------------------------------------------------
DO $$
DECLARE f text := 'public._exos_audit(uuid,text,text,text,uuid,jsonb,bigint,text,text,uuid,uuid,text)';
BEGIN
  ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'A3 privileges';
  ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'A3 the service role writes';
END $$;
SET ROLE authenticated;
DO $$
DECLARE s text; a public.exos_org_audit;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('o1'));
  s := pg_temp.st($q$SELECT public._exos_audit('$q$ || pg_temp.u('1') || $q$', 'event.update', 'event', 'x')$q$);
  ASSERT s LIKE '42501%', 'A3 authenticated calls the writer: ' || s;
  -- A browser naming an actor in a header is not believed.
  PERFORM set_config('request.headers', json_build_object('x-exos-actor', 'api_key:' || pg_temp.u('kx'), 'x-exos-request-id', 'forged')::text, true);
  UPDATE public.exos_ticket_tiers SET capacity = 210 WHERE id = pg_temp.u('t1');
  a := pg_temp.last('tier.update');
  ASSERT a.actor_kind = 'user' AND a.actor_ref IS NULL AND a.request_id IS NULL AND a.source = 'dashboard', 'A3 header ignored ' || row_to_json(a)::text;
  PERFORM set_config('request.headers', '', true);
END $$;
RESET ROLE;
SET ROLE anon;
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st($q$SELECT public._exos_audit('$q$ || pg_temp.u('1') || $q$', 'event.update', 'event', 'x')$q$);
  ASSERT s LIKE '42501%', 'A3 anon calls the writer: ' || s;
  s := pg_temp.st('SELECT count(*) FROM public.exos_org_audit');
  ASSERT s LIKE '42501%', 'A3 anon reads: ' || s;
  RAISE NOTICE 'OK  A3 anon / authenticated can''t write; a browser''s actor header is ignored';
END $$;
RESET ROLE;

-- A4 -------------------------------------------------------------------------
SET ROLE service_role;
DO $$
DECLARE a public.exos_org_audit; j jsonb;
BEGIN
  -- exos-refund claims as the service role for the signed-in finance member.
  j := public.exos_refund_claim(pg_temp.u('f1'), 'cs_oa_1', 'oa-nonce-0001', NULL, 1500, false, 'Buyer moved, mail them at oa-b1@x.com', NULL);
  a := pg_temp.last('refund.issue');
  ASSERT a.amount_cents = 1500 AND a.currency = 'USD' AND a.actor_uid = pg_temp.u('f1') AND a.actor_role = 'finance'
         AND a.entity_type = 'order' AND a.entity_id = 'cs_oa_1' AND a.event_id = pg_temp.u('e1'), 'A4 refund ' || row_to_json(a)::text;
  ASSERT a.reason = 'Buyer moved, mail them at [email]', 'A4 reason masked: ' || a.reason;
  -- The same click again: the same request, no second row.
  PERFORM public.exos_refund_claim(pg_temp.u('f1'), 'cs_oa_1', 'oa-nonce-0001', NULL, 1500, false, NULL, NULL);
  ASSERT pg_temp.n('refund.issue') = 1, 'A4 a replayed claim logs nothing';
  -- Fee adjustment with an idempotency key, twice.
  PERFORM public._exos_fee_adjustment_add(pg_temp.u('1'), 'cs_oa_1', NULL, 200, 'Waived the box fee', pg_temp.u('f1'), NULL, 'oa-fee-key-1');
  PERFORM public._exos_fee_adjustment_add(pg_temp.u('1'), 'cs_oa_1', NULL, 200, 'Waived the box fee', pg_temp.u('f1'), NULL, 'oa-fee-key-1');
  ASSERT pg_temp.n('fee.adjust') = 1, 'A4 one fee.adjust';
  ASSERT (pg_temp.last('fee.adjust')).amount_cents = 200, 'A4 fee cents';
END $$;
RESET ROLE;
SET ROLE authenticated;
DO $$
DECLARE a public.exos_org_audit; v_ask uuid := pg_temp.u('ask1'); v_key text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('o1'));
  PERFORM public.exos_set_org_comp_budget(pg_temp.u('1'), 40);
  a := pg_temp.last('comp.budget_set');
  ASSERT a.changes = '{"comp_budget": [null, 40]}'::jsonb AND a.entity_type = 'org', 'A4 comp budget ' || a.changes::text;
  PERFORM public.exos_set_invite_approval(pg_temp.u('1'), true);
  ASSERT pg_temp.n('invite.settings') = 1, 'A4 invite settings';
  -- Role scopes: set, then reset.
  PERFORM public.exos_org_role_scopes_set(pg_temp.u('1'), 'scanner', ARRAY['events:read', 'tickets:read']);
  PERFORM public.exos_org_role_scopes_reset(pg_temp.u('1'), 'scanner');
  ASSERT pg_temp.n('role_scopes.set') = 1 AND pg_temp.n('role_scopes.reset') = 1, 'A4 role scopes';
  ASSERT (pg_temp.last('role_scopes.set')).changes = '{"scopes": [null, ["events:read", "tickets:read"]]}'::jsonb, 'A4 role scope values';
  -- API keys: create, narrow, revoke.
  v_key := public.exos_create_api_key(pg_temp.u('1'), 'Box office', ARRAY['events:read', 'tickets:read']);
  a := pg_temp.last('api_key.create');
  ASSERT a.changes -> 'scopes' = '[null, ["events:read", "tickets:read"]]'::jsonb, 'A4 key create ' || a.changes::text;
  ASSERT position(v_key in row_to_json(a)::text) = 0 AND position(substr(v_key, 1, 12) in row_to_json(a)::text) = 0, 'A4 no key text';
  PERFORM public.exos_set_api_key_scopes(a.entity_id::uuid, ARRAY['events:read']);
  PERFORM public.exos_revoke_api_key(a.entity_id::uuid);
  ASSERT pg_temp.n('api_key.scopes_set') = 1 AND pg_temp.n('api_key.revoke') = 1, 'A4 key scopes + revoke';
  -- A refund ask, declined by finance.
  RESET ROLE;
  INSERT INTO public.exos_refund_asks (id, ticket_id, event_id, org_id, session_id, asked_by, reason, amount_cents, currency, status)
  VALUES (v_ask, pg_temp.u('k1'), pg_temp.u('e1'), pg_temp.u('1'), 'cs_oa_1', pg_temp.u('b1'), 'Sick', 4000, 'usd', 'open');
  SET ROLE authenticated;
  PERFORM pg_temp.act(pg_temp.u('f1'));
  ASSERT public.exos_decline_refund_ask(v_ask, 'Past the window'), 'A4 declined';
  ASSERT NOT public.exos_decline_refund_ask(v_ask, 'Again'), 'A4 a second decline is a no-op';
  ASSERT pg_temp.n('refund_ask.decline') = 1, 'A4 one decline row';
  -- A void by staff.
  PERFORM public.exos_void_ticket(pg_temp.u('k1'), 'duplicate');
  ASSERT (pg_temp.last('ticket.void')).changes = '{"status": ["active", "voided"]}'::jsonb, 'A4 void';
  RAISE NOTICE 'OK  A4 refund claim (once), fee adjust (once), comp budget, invite settings, role scopes, API keys, ask decline, void';
END $$;
RESET ROLE;

-- A5 -------------------------------------------------------------------------
DO $$
DECLARE v_hash text := encode(extensions.digest('sk_live_oa_secret_plaintext', 'sha256'), 'hex');
BEGIN
  INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by)
  VALUES (pg_temp.u('key1'), pg_temp.u('1'), 'Partner', 'sk_live_oa_s', v_hash, ARRAY['finance:write'], pg_temp.u('f1'));
END $$;
-- Supabase grants the service role every table (the harness doesn't): the
-- trigger checks below write a tier as exos-api would.
GRANT SELECT, UPDATE ON public.exos_ticket_tiers TO service_role;
CREATE TEMP TABLE oa_hash AS SELECT encode(extensions.digest('sk_live_oa_secret_plaintext', 'sha256'), 'hex') AS h;
GRANT SELECT ON oa_hash TO service_role;
SET ROLE service_role;
DO $$
DECLARE a public.exos_org_audit; v_txt text;
BEGIN
  PERFORM pg_temp.act(NULL);
  -- exos-api: an org key, its request id; the fee core gets the key id too.
  PERFORM set_config('request.headers', json_build_object('x-exos-actor', 'api_key:' || pg_temp.u('key1'),
                                                          'x-exos-request-id', 'req_oa_1')::text, true);
  PERFORM public._exos_fee_adjustment_add(pg_temp.u('1'), 'cs_oa_1', NULL, -100, 'API correction', NULL, pg_temp.u('key1'), 'oa-fee-key-2');
  a := pg_temp.last('fee.adjust');
  ASSERT a.actor_kind = 'api_key' AND a.actor_ref = pg_temp.u('key1')::text AND a.actor_uid = pg_temp.u('f1')
         AND a.actor_role = 'finance' AND a.source = 'api' AND a.request_id = 'req_oa_1', 'A5 key actor ' || row_to_json(a)::text;
  -- A plain table write in the same request (a trigger) gets the same actor.
  UPDATE public.exos_ticket_tiers SET name = 'General' WHERE id = pg_temp.u('t1');
  a := pg_temp.last('tier.update');
  ASSERT a.actor_kind = 'api_key' AND a.actor_uid = pg_temp.u('f1') AND a.request_id = 'req_oa_1', 'A5 trigger actor ' || row_to_json(a)::text;
  -- Never the secret or its hash, in any row.
  SELECT string_agg(row_to_json(x)::text, '') INTO v_txt FROM public.exos_org_audit x WHERE x.org_id = pg_temp.u('1');
  ASSERT position('sk_live_oa' in v_txt) = 0
         AND position((SELECT h FROM oa_hash) in v_txt) = 0, 'A5 no secret';
  -- A key of another org is not this org's actor.
  PERFORM set_config('request.headers', json_build_object('x-exos-actor', 'api_key:' || pg_temp.u('key9'))::text, true);
  UPDATE public.exos_ticket_tiers SET capacity = 220 WHERE id = pg_temp.u('t1');
  ASSERT (pg_temp.last('tier.update')).actor_uid IS NULL, 'A5 unknown key: no creator';
  -- A personal token and an OAuth app.
  PERFORM set_config('request.headers', json_build_object('x-exos-actor', 'pat:' || pg_temp.u('pat1'),
                                                          'x-exos-actor-uid', pg_temp.u('o1'))::text, true);
  UPDATE public.exos_ticket_tiers SET capacity = 230 WHERE id = pg_temp.u('t1');
  a := pg_temp.last('tier.update');
  ASSERT a.actor_kind = 'user' AND a.actor_ref = 'pat:' || pg_temp.u('pat1') AND a.actor_uid = pg_temp.u('o1') AND a.source = 'api',
    'A5 pat ' || row_to_json(a)::text;
  PERFORM set_config('request.headers', json_build_object('x-exos-actor', 'oauth_app:exos_ci_oa1', 'x-exos-actor-uid', pg_temp.u('o1'))::text, true);
  UPDATE public.exos_ticket_tiers SET capacity = 240 WHERE id = pg_temp.u('t1');
  a := pg_temp.last('tier.update');
  ASSERT a.actor_kind = 'oauth_app' AND a.actor_ref = 'exos_ci_oa1' AND a.actor_role = 'owner', 'A5 oauth ' || row_to_json(a)::text;
  PERFORM set_config('request.headers', '', true);
  -- Someone outside the team (named by an RPC): no role recorded.
  PERFORM public._exos_audit(pg_temp.u('1'), 'event.update', 'event', pg_temp.u('e1')::text, pg_temp.u('e1'), NULL, NULL, NULL, NULL, pg_temp.u('b1'));
  ASSERT (pg_temp.last('event.update')).actor_role IS NULL, 'A5 an outsider has no role';
  -- No actor at all: the service.
  UPDATE public.exos_ticket_tiers SET capacity = 250 WHERE id = pg_temp.u('t1');
  a := pg_temp.last('tier.update');
  ASSERT a.actor_kind = 'service' AND a.actor_uid IS NULL AND a.source = 'system', 'A5 service ' || row_to_json(a)::text;
  RAISE NOTICE 'OK  A5 API key actor (id, creator, role, request id; never the secret); PAT, OAuth app, service';
END $$;
RESET ROLE;

-- A6 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE s text; j jsonb;
BEGIN
  -- Org B's own rows exist (its tier edit), and stay B's.
  PERFORM pg_temp.act(pg_temp.u('o2'));
  UPDATE public.exos_ticket_tiers SET price = 31 WHERE id = pg_temp.u('t9');
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('1')) = 0, 'A6 B''s owner reads none of A';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('2') AND action = 'tier.update') = 1, 'A6 B''s owner reads B';
  s := pg_temp.st(format('SELECT public.exos_org_audit_list(%L)', pg_temp.u('1')));
  ASSERT s LIKE '42501%', 'A6 B''s owner lists A: ' || s;
  PERFORM pg_temp.act(pg_temp.u('s1'));
  ASSERT (SELECT count(*) FROM public.exos_org_audit) = 0, 'A6 a scanner reads nothing';
  s := pg_temp.st(format('SELECT public.exos_org_audit_list(%L)', pg_temp.u('1')));
  ASSERT s LIKE '42501%', 'A6 a scanner lists: ' || s;
  PERFORM pg_temp.act(pg_temp.u('b1'));
  ASSERT (SELECT count(*) FROM public.exos_org_audit) = 0, 'A6 a buyer reads nothing';
  -- Finance lists A; filters; the API key's name; B's event as a filter matches nothing.
  PERFORM pg_temp.act(pg_temp.u('f1'));
  j := public.exos_org_audit_list(pg_temp.u('1'));
  ASSERT jsonb_array_length(j -> 'rows') > 10 AND (j -> 'rows' -> 0 ->> 'id')::bigint > (j -> 'rows' -> 1 ->> 'id')::bigint, 'A6 newest first';
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') r WHERE r ->> 'event_id' = pg_temp.u('e9')::text), 'A6 no B rows';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') r WHERE r ->> 'actor_label' = 'API key Partner'), 'A6 key label';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'actors') a WHERE a ->> 'label' = 'oa-o1@x.com'), 'A6 actors';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') r WHERE r ->> 'actor_label' = 'Not a team member')
         AND position('oa-b1@x.com' in j::text) = 0, 'A6 an outsider''s email is not shown';
  j := public.exos_org_audit_list(pg_temp.u('1'), pg_temp.u('e9'));
  ASSERT jsonb_array_length(j -> 'rows') = 0, 'A6 B''s event: nothing';
  j := public.exos_org_audit_list(pg_temp.u('1'), NULL, NULL, 'access');
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') r WHERE r ->> 'group' <> 'access')
         AND jsonb_array_length(j -> 'rows') >= 5, 'A6 group filter';
  j := public.exos_org_audit_list(pg_temp.u('1'), NULL, pg_temp.u('o1'), NULL, NULL, NULL, NULL, 2);
  ASSERT jsonb_array_length(j -> 'rows') = 2 AND (j ->> 'next_before') IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') r WHERE r ->> 'actor_uid' <> pg_temp.u('o1')::text), 'A6 actor filter, page';
  s := pg_temp.st(format('SELECT public.exos_org_audit_list(%L, NULL, NULL, %L)', pg_temp.u('1'), 'everything'));
  ASSERT s LIKE '22023%', 'A6 unknown group: ' || s;
END $$;
RESET ROLE;
DO $$
BEGIN
  -- audit:read: owner and finance tokens by default; a manager can't be given it; legacy read follows the vocabulary.
  ASSERT public.exos_role_token_scopes('owner') @> ARRAY['audit:read'] AND public.exos_role_token_scopes('finance') @> ARRAY['audit:read'], 'A6 defaults';
  ASSERT NOT (public.exos_role_token_scopes('manager') @> ARRAY['audit:read'])
         AND NOT (public.exos_role_scope_ceiling('manager') @> ARRAY['audit:read'])
         AND NOT (public.exos_role_scope_ceiling('content') @> ARRAY['audit:read']), 'A6 not a manager''s';
  ASSERT public._exos_api_key_scopes(pg_temp.u('key1')) @> ARRAY['audit:read'] IS FALSE, 'A6 a key without it has none';
  RAISE NOTICE 'OK  A6 no cross-org reads (table, list, filters); scanners and buyers read nothing; audit:read owner / finance';
END $$;

-- A7 -------------------------------------------------------------------------
DO $$
DECLARE s text;
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'exos_org_audit'
                      AND column_name ~* '(email|phone|card|name)'), 'A7 no such column';
  s := pg_temp.st($q$INSERT INTO public.exos_org_audit (org_id, actor_kind, action, entity_type, source, changes)
                     VALUES ('00000000-0000-0000-0000-000000000001', 'service', 'event.update', 'event', 'system',
                             '{"note": [null, "call oa-b1@x.com"]}')$q$);
  ASSERT s LIKE '23514%', 'A7 the CHECK refuses an email: ' || s;
  s := pg_temp.st($q$INSERT INTO public.exos_org_audit (org_id, actor_kind, action, entity_type, source, changes)
                     VALUES ('00000000-0000-0000-0000-000000000001', 'service', 'event.update', 'event', 'system',
                             '{"buyer_phone": [null, "1"]}')$q$);
  ASSERT s LIKE '23514%', 'A7 the CHECK refuses a phone field: ' || s;
  ASSERT public._exos_audit_scrub('ring +1 (212) 555-0101 or oa@x.co') = 'ring [phone] or [email]', 'A7 scrub ' || public._exos_audit_scrub('ring +1 (212) 555-0101 or oa@x.co');
  ASSERT public._exos_audit_scrub(pg_temp.u('x')::text) = pg_temp.u('x')::text, 'A7 an id stays';
  ASSERT public._exos_audit_val(to_jsonb(repeat('x', 200))) = '"(200 characters)"', 'A7 long text';
  ASSERT public._exos_audit_val('{"a": 1}') = '"(changed)"', 'A7 an object';
  ASSERT public._exos_audit_diff('{"buyer_email": "a@b.co", "price": 1}', '{"buyer_email": "c@d.co", "price": 2}') = '{"price": [1, 2]}', 'A7 diff drops PII fields';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('1')
                      AND (changes::text ~ '@' OR coalesce(reason, '') ~ '@' OR changes::text ~ 'OAPRESALE|OAISSUE1')), 'A7 no email or code logged';
  RAISE NOTICE 'OK  A7 no email / phone column; the CHECK refuses them in changes; values masked, long text summarized';
END $$;

-- A8 -------------------------------------------------------------------------
DO $$
DECLARE v_before int := (SELECT count(*) FROM public.exos_org_audit);
BEGIN
  -- An action name the table refuses: a WARNING, no row, no error.
  PERFORM public._exos_audit(pg_temp.u('1'), 'Not An Action', 'event', 'x');
  ASSERT (SELECT count(*) FROM public.exos_org_audit) = v_before, 'A8 no row';
  -- No org: nothing, quietly.
  PERFORM public._exos_audit(NULL, 'event.update', 'event', 'x');
  ASSERT (SELECT count(*) FROM public.exos_org_audit) = v_before, 'A8 no org';
  RAISE NOTICE 'OK  A8 a failed audit write is a WARNING; the action stands';
END $$;

-- A9 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE s text; a public.exos_org_audit;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('f1'));
  ASSERT public.exos_audit_export(pg_temp.u('1'), 'audit', 25), 'A9 logged';
  a := pg_temp.last('export.run');
  ASSERT a.changes = '{"kind": [null, "audit"], "row_count": [null, 25]}'::jsonb AND a.entity_id = 'audit', 'A9 ' || a.changes::text;
  s := pg_temp.st(format('SELECT public.exos_audit_export(%L, %L, 3, %L)', pg_temp.u('1'), 'attendees', pg_temp.u('e9')));
  ASSERT s LIKE 'P0002%', 'A9 another org''s event: ' || s;
  s := pg_temp.st(format('SELECT public.exos_audit_export(%L, %L, 3)', pg_temp.u('1'), 'everything'));
  ASSERT s LIKE '22023%', 'A9 unknown kind: ' || s;
  PERFORM pg_temp.act(pg_temp.u('s1'));
  s := pg_temp.st(format('SELECT public.exos_audit_export(%L, %L, 3)', pg_temp.u('1'), 'attendees'));
  ASSERT s LIKE '42501%', 'A9 a scanner: ' || s;
  PERFORM pg_temp.act(pg_temp.u('o2'));
  s := pg_temp.st(format('SELECT public.exos_audit_export(%L, %L, 3)', pg_temp.u('1'), 'audit'));
  ASSERT s LIKE '42501%', 'A9 another org''s owner: ' || s;
  -- An event's CSV names only the event: the org is the event's (B's event: B's staff only).
  PERFORM pg_temp.act(pg_temp.u('f1'));
  PERFORM public.exos_audit_export(NULL, 'attendees', 4, pg_temp.u('e1'));
  ASSERT (pg_temp.last('export.run')).event_id = pg_temp.u('e1'), 'A9 event export';
  s := pg_temp.st(format('SELECT public.exos_audit_export(NULL, %L, 3, %L)', 'attendees', pg_temp.u('e9')));
  ASSERT s LIKE '42501%', 'A9 B''s event by A''s finance: ' || s;
  -- The fans export logs itself.
  PERFORM pg_temp.act(pg_temp.u('o1'));
  PERFORM public.exos_org_fans_export(pg_temp.u('1'));
  ASSERT (SELECT count(*) FROM public.exos_org_audit x WHERE x.org_id = pg_temp.u('1') AND x.action = 'export.run' AND x.entity_id = 'fans') = 1, 'A9 fans';
  RAISE NOTICE 'OK  A9 export.run: staff only, known kinds, own events; the fans export logs itself';
END $$;
RESET ROLE;

-- A10 ------------------------------------------------------------------------
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('p1'), 'oa-p1@x.com', now()), (pg_temp.u('p2'), 'oa-p2@x.com', now());
INSERT INTO public.exos_org_memberships (org_id, user_id, role, disabled, status, pending_role, pending_since) VALUES
  (pg_temp.u('1'), pg_temp.u('p1'), 'scanner', true, 'pending_approval', 'scanner', now()),
  (pg_temp.u('1'), pg_temp.u('p2'), 'scanner', true, 'pending_approval', 'content', now());
INSERT INTO public.exos_oauth_apps (id, client_id, name, redirect_uris, scopes, client_type, owner_uid) VALUES
  (pg_temp.u('app1'), 'exos_app_0a7d0a7d0a7d0a7d0a7d0a7d', 'OA Sync', ARRAY['https://oa.example/cb'], ARRAY['events:read'], 'public', pg_temp.u('o1'));
INSERT INTO public.exos_oauth_grants (app_id, user_id, org_id, scopes) VALUES
  (pg_temp.u('app1'), pg_temp.u('o1'), pg_temp.u('1'), ARRAY['events:read']),
  (pg_temp.u('app1'), pg_temp.u('o2'), pg_temp.u('2'), ARRAY['events:read']);
SET ROLE authenticated;
DO $$
DECLARE a public.exos_org_audit; v_before int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('o1'));
  SELECT count(*) INTO v_before FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action LIKE 'member.%';
  PERFORM public.exos_org_member_approve(pg_temp.u('1'), pg_temp.u('p1'));
  a := pg_temp.last('member.approve');
  ASSERT a.entity_id = pg_temp.u('p1')::text AND a.changes -> 'status' = '["pending_approval", "active"]'::jsonb
         AND a.actor_uid = pg_temp.u('o1'), 'A10 approve ' || row_to_json(a)::text;
  PERFORM public.exos_org_member_reject(pg_temp.u('1'), pg_temp.u('p2'));
  a := pg_temp.last('member.reject');
  ASSERT a.entity_id = pg_temp.u('p2')::text AND a.changes -> 'removed' = '[null, true]'::jsonb, 'A10 reject ' || row_to_json(a)::text;
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action LIKE 'member.%') = v_before + 2,
    'A10 one row per decision (no trigger rows)';
  ASSERT public.exos_oauth_app_delete('exos_app_0a7d0a7d0a7d0a7d0a7d0a7d'), 'A10 app deleted';
  ASSERT pg_temp.n('oauth_app.delete') = 1 AND pg_temp.n('oauth_app.delete', '2') = 1, 'A10 one row in each org';
  ASSERT (pg_temp.last('oauth_app.delete')).entity_id = 'exos_app_0a7d0a7d0a7d0a7d0a7d0a7d', 'A10 the client id';
  RAISE NOTICE 'OK  A10 member approve / reject once each; oauth_app.delete in each org with a live grant';
END $$;
RESET ROLE;

ROLLBACK;
\echo test_org_audit: all passed
