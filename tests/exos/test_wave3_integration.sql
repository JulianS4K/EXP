-- ============================================================================
-- Wave 3 integration (#85 fan API, #87 na-build, #88 sim decisions, #89
-- promoter events). Self-contained (e3a prefix), rolled back.
--   W1  every in-place patch of the four migrations is still in the live
--       function body after the full apply + replay: no later migration's
--       redefinition wiped another branch's change (markers, by function)
--   W2  an account token (#85) has no organization, so X-Exos-Org (#87)
--       reaches none: exos_api_token_auth_org gives nothing for it (exos-api
--       then refuses it with account_no_org), and its own auth has no org
--   W3  a token minted from an opt-in (multi_org) personal token through
--       /v1/me is pinned: it can't use X-Exos-Org; the parent still can
--   W4  public discovery (#85) reads capacity 0 as closed (#88): a closed
--       type is sold out, like a used-up one (mig 20261105150000)
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- W1 -------------------------------------------------------------------------
DO $$
DECLARE r record; v_lost text := ''; n int := 0;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    -- #88 sim decisions (mig 20261105100000)
    ('public.exos_tier_available(uuid)', '/* exos: capacity 0 is closed */'),
    ('public.exos_claim_free_tickets(uuid,uuid,integer,text,text,text)', '/* exos: cap0 closed */'),
    ('public.exos_claim_free_addons(uuid,text,jsonb)', '/* exos: cap0 closed */'),
    ('public.exos_issue_ticket_to_email(uuid,uuid,text,integer,text)', '/* exos: cap0 closed */'),
    ('public.exos_mint_tickets(uuid,uuid,integer,text,numeric,text)', '/* exos: cap0 closed */'),
    ('public.exos_redeem_referral_reward(uuid,uuid)', '/* exos: cap0 closed */'),
    ('public.exos_fulfil_marketplace_order(uuid,text)', '/* exos: cap0 closed */'),
    ('public.exos_issue_comp_batch(uuid,uuid,text[],integer,text)', '/* exos: cap0 closed */'),
    ('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)', '/* exos: cap0 closed */'),
    ('public.exos_phone_rsvp_verify(uuid,text,text)', '/* exos: cap0 closed */'),
    ('public.exos_fulfill_checkout(text)', '/* exos: cap0 closed */'),
    ('public.exos_fulfill_checkout(text)', '/* exos: bypass not closed */'),
    ('public.exos_set_channel_allocation(uuid,text,uuid,integer)', '/* exos: no uncapped types */'),
    ('public.exos_apply_channel_split(uuid)', '/* exos: no uncapped types */'),
    ('public.exos_set_s4k_split(uuid,jsonb)', '/* exos: no uncapped types */'),
    ('public._exos_posh_count(uuid)', '/* exos: closed has no room */'),
    ('public.exos_issue_comp_batch(uuid,uuid,text[],integer,text)', '/* exos: comp batch guard */'),
    ('public.exos_api_write(uuid,text,text,jsonb,text)', '/* exos: comp request key */'),
    ('public.exos_import_guests(uuid,jsonb)', '/* exos: name is an email */'),
    ('public._exos_guest_list_preview(uuid,uuid,uuid,jsonb)', '/* exos: name is an email */'),
    ('public._exos_guest_insert(uuid,text,text,text,integer,text,uuid,uuid)', '/* exos: name is an email */'),
    ('public.exos_update_guest(uuid,text,text,text,integer,text)', '/* exos: name is an email */'),
    ('public.exos_set_ticket_attendee(uuid,text)', '/* exos: name is an email */'),
    ('public.exos_ticket_update(uuid,jsonb)', '/* exos: name is an email */'),
    ('public.exos_join_waitlist(uuid,text,uuid,text,integer,jsonb)', '/* exos: name is an email */'),
    ('public.exos_phone_rsvp_start(uuid,text,text,text,integer,text,boolean,text,text)', '/* exos: name is an email */'),
    ('public.exos_order_update(text,jsonb)', '/* exos: name is an email */'),
    ('public.exos_fulfill_checkout(text)', '/* exos: guests prove first */'),
    ('public.exos_fulfill_checkout(text)', '/* exos: unconfirmed prove first */'),
    ('public.exos_fulfill_checkout(text)', '/* exos: guest proof */'),
    ('public.exos_claim_transfer(uuid)', '/* exos: proof before claim */'),
    ('public.exos_cancel_transfer(uuid)', '/* exos: proof pending */'),
    ('public._exos_refund_ask_payer_ok(jsonb,uuid)', '/* exos: proven email payer */'),
    ('public._exos_resched_actor_ok(jsonb,uuid)', '/* exos: proven email payer */'),
    ('public._exos_resched_actor_ok(jsonb,uuid)', '/* exos: proven email holder */'),
    ('public.exos_my_reschedule_offers()', '/* exos: proven email payer */'),
    ('public.exos_my_reschedule_offers()', '/* exos: proven email holder */'),
    ('public.exos_my_invoices()', '/* exos: proven email payer */'),
    ('public.exos_invoice_document(uuid)', '/* exos: proven email payer */'),
    ('public.exos_my_refund_asks(uuid)', '/* exos: proven email payer */'),
    ('public._exos_record_forced_checkin(uuid,uuid,uuid,text,text,text,timestamptz,text,text)',
     '/* exos: forced entry uses the ticket */'),
    ('public.exos_phone_rsvp_start(uuid,text,text,text,integer,text,boolean,text,text)', '/* exos: not enough seats */'),
    ('public.exos_api_write(uuid,text,text,jsonb,text)', '/* exos: event tiers need a capacity */'),
    ('public.exos_api_write(uuid,text,text,jsonb,text)', '/* exos: a tier needs a capacity */'),
    ('public.exos_api_write(uuid,text,text,jsonb,text)', '/* exos: an add-on needs a capacity */'),
    -- #87 na-build (mig 20261105120000)
    ('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)', '/* exos: print codes */'),
    ('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)', '/* exos: print code use */'),
    ('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)',
     '/* exos: print code use, re-entry */'),
    ('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text)', '/* exos: print codes */'),
    ('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text)', '/* exos: print code use */'),
    ('public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text,uuid,text)', 'print-code-used'),
    ('public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text)', 'print-code-used'),
    -- #89 promoter events (mig 20261105130000)
    ('public.exos_claim_free_tickets(uuid,uuid,integer,text,text,text)', 'exos:location-tba'),
    ('public._exos_event_publish_blockers(uuid)', '/* exos: location modes */'),
    ('public._exos_event_publish_blockers(uuid)', '/* exos: location blockers */'),
    ('public.exos_api_write(uuid,text,text,jsonb,text)', '''location_mode'', ''location_reveal_at'', ''tba_allow_sales'','),
    ('public.exos_api_write(uuid,text,text,jsonb,text)', '/* exos: location create */'),
    ('public.exos_api_write(uuid,text,text,jsonb,text)', '/* exos: location create secret */'),
    ('public.exos_api_write(uuid,text,text,jsonb,text)', '/* exos: location update */'),
    ('public._exos_api_event_json(uuid)', '/* exos: location json */'),
    ('public._exos_wallet_payload(text)', '/* exos: location wallet */'),
    -- wave 3 integration (mig 20261105150000)
    ('public._exos_api_public_tiers_json(uuid)', '/* exos: closed is sold out */')
  ) AS t(sig, marker) LOOP
    n := n + 1;
    IF to_regprocedure(r.sig) IS NULL THEN
      v_lost := v_lost || format(E'\n  missing function %s', r.sig);
    ELSIF position(r.marker IN pg_get_functiondef(to_regprocedure(r.sig))) = 0 THEN
      v_lost := v_lost || format(E'\n  %s lost %s', r.sig, r.marker);
    END IF;
  END LOOP;
  ASSERT v_lost = '', 'W1 patches lost:' || v_lost;
  -- The publish gate keeps both: #89's location blockers and #88's closed-type rules live side by side.
  ASSERT position('_exos_location_blockers' IN pg_get_functiondef('public._exos_event_publish_blockers(uuid)'::regprocedure)) > 0,
    'W1 publish blockers call the location blockers';
  RAISE NOTICE 'OK  W1 all % wave-3 patches are in the replayed function bodies', n;
END $$;

-- Fixtures: a user who manages org 1 and scans for org 2, a fan with no org.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
SELECT set_config('app.uid', '', false);
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('e3a00000-0000-0000-0000-0000000000a1', 'e3a-staff@x.com', now()),
  ('e3a00000-0000-0000-0000-0000000000b1', 'e3a-fan@x.com', now()),
  ('e3a00000-0000-0000-0000-0000000000c1', 'e3a-owner2@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('e3a00000-0000-0000-0000-000000000001', 'E3A One', 'e3a-one', 'e3a00000-0000-0000-0000-0000000000a1'),
  ('e3a00000-0000-0000-0000-000000000002', 'E3A Two', 'e3a-two', 'e3a00000-0000-0000-0000-0000000000c1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('e3a00000-0000-0000-0000-000000000001', 'e3a00000-0000-0000-0000-0000000000a1', 'owner'),
  ('e3a00000-0000-0000-0000-000000000002', 'e3a00000-0000-0000-0000-0000000000c1', 'owner'),
  ('e3a00000-0000-0000-0000-000000000002', 'e3a00000-0000-0000-0000-0000000000a1', 'scanner');
CREATE TEMP TABLE e3a (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(extensions.digest(p, 'sha256'), 'hex')
$$;
CREATE FUNCTION pg_temp.v(p text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM e3a WHERE k = p $$;
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM set_config('app.uid', 'e3a00000-0000-0000-0000-0000000000b1', true);
  v := public.exos_create_account_token('fan app', ARRAY['me:read', 'me:write'], 30);
  INSERT INTO e3a VALUES ('acct', v->>'token');
  PERFORM set_config('app.uid', 'e3a00000-0000-0000-0000-0000000000a1', true);
  v := public.exos_create_personal_token('e3a00000-0000-0000-0000-000000000001', 'all orgs',
                                         ARRAY['me:read', 'me:write', 'events:read', 'checkin:write'], 30, true);
  ASSERT (v->>'multi_org')::boolean, 'fixture: multi-org token ' || v::text;
  INSERT INTO e3a VALUES ('multi', v->>'token');
  PERFORM set_config('app.uid', '', true);
END $$;

-- W2 -------------------------------------------------------------------------
DO $$
DECLARE h text := pg_temp.h(pg_temp.v('acct')); r jsonb;
BEGIN
  r := public.exos_api_account_token_auth(h);
  ASSERT (r->>'account')::boolean AND r->>'org_id' IS NULL AND r->>'role' IS NULL, 'W2 account token has no org: ' || r::text;
  -- What exos-api asks for a request naming an org: never an org for an account token.
  ASSERT public.exos_api_token_auth(h, 'pat') IS NULL, 'W2 not an org token';
  r := public.exos_api_token_auth_org(h, 'pat', 'e3a00000-0000-0000-0000-000000000001');
  ASSERT r IS NULL OR (r ? 'error' AND NOT (r ? 'org_id')), 'W2 X-Exos-Org reaches no org: ' || coalesce(r::text, 'null');
  r := public.exos_api_token_auth_org(h, 'pat', 'e3a00000-0000-0000-0000-000000000002');
  ASSERT r IS NULL OR (r ? 'error' AND NOT (r ? 'org_id')), 'W2 X-Exos-Org reaches no org (2): ' || coalesce(r::text, 'null');
  -- Its /v1/me credential is the fan, with no organization.
  r := public._exos_api_me_cred(h, 'pat');
  ASSERT r->>'user_id' = 'e3a00000-0000-0000-0000-0000000000b1' AND r->>'org_id' IS NULL, 'W2 me cred: ' || r::text;
  -- Account tokens have no multi_org switch at all.
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = 'exos_account_tokens' AND column_name = 'multi_org'),
    'W2 no multi_org on account tokens';
  RAISE NOTICE 'OK  W2 an account token has no org, and X-Exos-Org reaches none with it';
END $$;

-- W3 -------------------------------------------------------------------------
DO $$
DECLARE hp text := pg_temp.h(pg_temp.v('multi')); r jsonb; v_child text;
BEGIN
  -- The opt-in parent switches into org 2 at the scanner role.
  r := public.exos_api_token_auth_org(hp, 'pat', 'e3a00000-0000-0000-0000-000000000002');
  ASSERT r->>'org_id' = 'e3a00000-0000-0000-0000-000000000002' AND r->>'role' = 'scanner', 'W3 parent switches: ' || r::text;
  -- A token it mints through /v1/me is pinned to the parent's home org.
  r := public.exos_api_me(hp, 'pat', 'token.create', NULL, '{"name": "child", "scopes": ["events:read"], "multi_org": true}');
  ASSERT r->>'kind' = 'personal' AND r->>'org_id' = 'e3a00000-0000-0000-0000-000000000001', 'W3 minted: ' || r::text;
  v_child := r->>'token';
  ASSERT NOT (SELECT multi_org FROM public.exos_personal_tokens WHERE key_hash = pg_temp.h(v_child)), 'W3 child pinned';
  ASSERT public.exos_api_token_auth_org(pg_temp.h(v_child), 'pat', 'e3a00000-0000-0000-0000-000000000002') ->> 'error'
         = 'token_pinned_to_org', 'W3 child can''t switch';
  ASSERT public.exos_api_token_auth_org(pg_temp.h(v_child), 'pat', 'e3a00000-0000-0000-0000-000000000001') ->> 'org_id'
         = 'e3a00000-0000-0000-0000-000000000001', 'W3 child works at home';
  RAISE NOTICE 'OK  W3 a token minted from an opt-in token is pinned';
END $$;

-- W4 -------------------------------------------------------------------------
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, created_by) VALUES
  ('e3a00000-0000-0000-0000-0000000000e1', 'e3a00000-0000-0000-0000-000000000001', 'E3A Live', 'e3a-live', 'published',
   now() + interval '10 days', 0, 'e3a00000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, sort_order) VALUES
  ('e3a00000-0000-0000-0000-0000000000d1', 'e3a00000-0000-0000-0000-0000000000e1', 'Closed', 10, 0, 0, 1),
  ('e3a00000-0000-0000-0000-0000000000d2', 'e3a00000-0000-0000-0000-0000000000e1', 'Gone', 20, 5, 5, 2),
  ('e3a00000-0000-0000-0000-0000000000d3', 'e3a00000-0000-0000-0000-0000000000e1', 'Open', 30, 5, 1, 3);
DO $$
DECLARE j jsonb := public._exos_api_public_tiers_json('e3a00000-0000-0000-0000-0000000000e1');
BEGIN
  ASSERT jsonb_array_length(j) = 3, 'W4 three public types: ' || j::text;
  ASSERT (SELECT bool_and(CASE x->>'name' WHEN 'Open' THEN NOT (x->>'sold_out')::boolean ELSE (x->>'sold_out')::boolean END)
            FROM jsonb_array_elements(j) x), 'W4 closed and used-up are sold out, open is not: ' || j::text;
  ASSERT public.exos_tier_available('e3a00000-0000-0000-0000-0000000000d1') = 0, 'W4 the closed type has 0 left';
  RAISE NOTICE 'OK  W4 a closed type is sold out in public discovery';
END $$;

ROLLBACK;
\echo test_wave3_integration: all passed
