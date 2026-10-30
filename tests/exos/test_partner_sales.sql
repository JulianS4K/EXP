-- ============================================================================
-- Partner sales (mig 20261031130000). Self-contained (c3 prefix), rolled back.
--   PS1 grants: anon may call exos_ticket_link_view only; the core is service role
--   PS2 partner keys: owner only, shown once, hash only (no key_hash column grant),
--       25 a org, update / revoke, API-key path needs an owner-made key
--   PS3 key check: active keys resolve; paused and revoked don't
--   PS4 the per-tier switch: off by default, per partner, paused, no tables
--   PS5 reserve: all-in prices, holds of at most 10, availability drops
--   PS6 the race for the last seats: the loser is refused before paying
--   PS7 cancel gives the seats back; a completed reservation can't be cancelled
--   PS8 complete mints on the org owner as partner:<type>, once (idempotent)
--   PS9 an expired reservation answers 'expired' and releases its seats
--   PS10 the ticket link: right key -> the door's own code (and it scans);
--        wrong key / reissued ticket -> nothing
--   PS11 cross-org and cross-partner isolation
--   PS12 the resale rule closes partner sales; organizer reservations (API
--        key, channel 'api') may sell hidden types
--   PS13 orders: Opendate envelope, filters, only the partner's own
--   PS14 comps need the comps scope
--   PS15 RLS: owner / manager / finance read reservations of their org only
--   PS16 revoking a partner cancels its open reservations
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c3000000-0000-0000-0000-0000000000a1','c3-owner@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000a2','c3-manager@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000a3','c3-finance@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000a4','c3-scanner@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000b1','c3-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c3000000-0000-0000-0000-000000000001','C3 Org','c3-org','c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-000000000002','C3 Other','c3-other','c3000000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000a1','owner'),
  ('c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000a2','manager'),
  ('c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000a3','finance'),
  ('c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000a4','scanner'),
  ('c3000000-0000-0000-0000-000000000002','c3000000-0000-0000-0000-0000000000b1','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,tickets_sold,currency,created_by) VALUES
  ('c3000000-0000-0000-0000-0000000000e1','c3000000-0000-0000-0000-000000000001','C3 Show','c3-show','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 0, 'usd', 'c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-0000000000e2','c3000000-0000-0000-0000-000000000002','C3 Other Show','c3-other-show','published',
   now() + interval '2 days', NULL, 0, 0, 'usd', 'c3000000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
  ('c3000000-0000-0000-0000-0000000000d1','c3000000-0000-0000-0000-0000000000e1','GA',25,40,0,'public',1),
  ('c3000000-0000-0000-0000-0000000000d2','c3000000-0000-0000-0000-0000000000e1','Last five',30,5,0,'public',2),
  ('c3000000-0000-0000-0000-0000000000d3','c3000000-0000-0000-0000-0000000000e1','Crew',0,10,0,'hidden',3),
  ('c3000000-0000-0000-0000-0000000000d9','c3000000-0000-0000-0000-0000000000e2','Other GA',20,50,0,'public',1);
-- A $2 passed-on fee on GA: the partner's price is all-in.
INSERT INTO public.exos_fee_rules(org_id,event_id,name,kind,calc,amount_cents,per)
VALUES ('c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000e1','Facility','passed_on','fixed',200,'ticket');
-- An org API key made by the owner (organizer reservations, key management).
INSERT INTO public.exos_api_keys(id,org_id,name,key_prefix,key_hash,scopes,created_by) VALUES
  ('c3000000-0000-0000-0000-0000000000f1','c3000000-0000-0000-0000-000000000001','Box office','sk_live_c3c3c3c3',
   repeat('c3', 32),ARRAY['tickets:write','org:admin'],'c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-0000000000f2','c3000000-0000-0000-0000-000000000001','Manager key','sk_live_c3c3c3c4',
   repeat('c4', 32),ARRAY['org:admin'],'c3000000-0000-0000-0000-0000000000a2');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true);
$$;
CREATE TEMP TABLE c3_keys (name text PRIMARY KEY, id uuid, key text) ON COMMIT DROP;
GRANT ALL ON c3_keys TO authenticated;

-- PS1 -----------------------------------------------------------------------
DO $$
DECLARE f text; bad text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)',
    'public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)',
    'public._exos_partner_reservation_cancel(uuid,uuid,text)',
    'public._exos_partner_reservation_update(uuid,uuid,text,jsonb)',
    'public._exos_partner_orders(uuid,uuid,jsonb,integer,integer,text)',
    'public._exos_partner_ticket_types(uuid,uuid,uuid)',
    'public._exos_dist_partner_create(uuid,text,text,text[],uuid,uuid)',
    'public.exos_dist_partner_auth(text)',
    'public.exos_ticket_link_wallet_issue(uuid,text,text,text,text)',
    'public._exos_ticket_link_url(uuid,text)',
    'public.exos_partner_reservations_sweep(integer)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'PS1 anon can call ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'PS1 authenticated can call ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'PS1 service role can''t call ' || f;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_ticket_link_view(uuid,text)', 'EXECUTE'), 'PS1 link view';
  FOREACH f IN ARRAY ARRAY['public.exos_create_distribution_partner(uuid,text,text,text[])',
    'public.exos_update_distribution_partner(uuid,jsonb)', 'public.exos_revoke_distribution_partner(uuid)',
    'public.exos_set_tier_distribution(uuid,jsonb)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'PS1 dashboard grant ' || f;
  END LOOP;
  SELECT string_agg(p.proname, ', ') INTO bad FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
     AND (p.proname LIKE '%partner%' OR p.proname LIKE '%ticket_link%' OR p.proname LIKE '%tier_distribution%')
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%pg_temp%');
  ASSERT bad IS NULL, 'PS1 definer without search_path: ' || bad;
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_distribution_partners', 'key_hash', 'SELECT'), 'PS1 key_hash readable';
  ASSERT has_column_privilege('authenticated', 'public.exos_distribution_partners', 'key_prefix', 'SELECT'), 'PS1 prefix';
  RAISE NOTICE 'OK  PS1 grants';
END $$;

-- PS2 -----------------------------------------------------------------------
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a2');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM public.exos_create_distribution_partner('c3000000-0000-0000-0000-000000000001', 'x', 'stubhub', ARRAY['inventory']);
  RAISE EXCEPTION 'PS2 manager minted a key';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
DO $$
DECLARE v jsonb;
BEGIN
  v := public.exos_create_distribution_partner('c3000000-0000-0000-0000-000000000001', 'StubHub', 'stubhub', ARRAY['inventory']);
  ASSERT v->>'key' ~ '^dk_live_[0-9a-f]{48}$' AND v->>'key_prefix' = left(v->>'key', 16), 'PS2 key shape ' || v::text;
  INSERT INTO c3_keys VALUES ('stubhub', (v->>'id')::uuid, v->>'key');
  v := public.exos_create_distribution_partner('c3000000-0000-0000-0000-000000000001', 'Vivid', 'vivid', ARRAY['comps','inventory','comps']);
  ASSERT v->'scopes' = '["inventory","comps"]'::jsonb, 'PS2 scopes cleaned ' || (v->'scopes')::text;
  INSERT INTO c3_keys VALUES ('vivid', (v->>'id')::uuid, v->>'key');
  BEGIN
    PERFORM public.exos_create_distribution_partner('c3000000-0000-0000-0000-000000000001', 'x', 'ticketmaster', NULL);
    RAISE EXCEPTION 'PS2 unknown type accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_create_distribution_partner('c3000000-0000-0000-0000-000000000001', 'x', 'other', ARRAY['admin']);
    RAISE EXCEPTION 'PS2 unknown scope accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_create_distribution_partner('c3000000-0000-0000-0000-000000000002', 'x', 'other', NULL);
    RAISE EXCEPTION 'PS2 minted for another org';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- The owner reads the list (no hash), the stored hash is the key's SHA-256.
  ASSERT (SELECT count(*) FROM public.exos_distribution_partners) = 2, 'PS2 owner list';
  v := public.exos_update_distribution_partner((SELECT id FROM c3_keys WHERE name = 'vivid'), '{"label":"Vivid Seats"}');
  ASSERT v->>'label' = 'Vivid Seats', 'PS2 update';
END $$;
RESET ROLE;
DO $$
DECLARE v jsonb; i int;
BEGIN
  ASSERT (SELECT key_hash FROM public.exos_distribution_partners WHERE id = (SELECT id FROM c3_keys WHERE name = 'stubhub'))
       = encode(extensions.digest((SELECT key FROM c3_keys WHERE name = 'stubhub'), 'sha256'), 'hex'), 'PS2 hash';
  -- API-key path: the owner's key may, the manager's key may not.
  v := public._exos_dist_partner_create('c3000000-0000-0000-0000-000000000001', 'Automatiq', 'automatiq', NULL, NULL,
                                        'c3000000-0000-0000-0000-0000000000f1');
  ASSERT (SELECT created_by FROM public.exos_distribution_partners WHERE id = (v->>'id')::uuid)
       = 'c3000000-0000-0000-0000-0000000000a1', 'PS2 api-key actor';
  INSERT INTO c3_keys VALUES ('automatiq', (v->>'id')::uuid, v->>'key');
  BEGIN
    PERFORM public._exos_dist_partner_create('c3000000-0000-0000-0000-000000000001', 'x', 'other', NULL, NULL,
                                             'c3000000-0000-0000-0000-0000000000f2');
    RAISE EXCEPTION 'PS2 manager-made API key minted a partner key';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- At most 25 live keys.
  FOR i IN 1..22 LOOP
    PERFORM public._exos_dist_partner_create('c3000000-0000-0000-0000-000000000001', 'p' || i, 'other', NULL,
                                             'c3000000-0000-0000-0000-0000000000a1', NULL);
  END LOOP;
  BEGIN
    PERFORM public._exos_dist_partner_create('c3000000-0000-0000-0000-000000000001', 'one too many', 'other', NULL,
                                             'c3000000-0000-0000-0000-0000000000a1', NULL);
    RAISE EXCEPTION 'PS2 26th key';
  EXCEPTION WHEN program_limit_exceeded THEN NULL;
  END;
  DELETE FROM public.exos_distribution_partners WHERE label ~ '^p[0-9]+$';
  RAISE NOTICE 'OK  PS2 partner keys';
END $$;

-- PS3 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; h text := encode(extensions.digest((SELECT key FROM c3_keys WHERE name = 'vivid'), 'sha256'), 'hex');
BEGIN
  v := public.exos_dist_partner_auth(h);
  ASSERT v->>'partner_type' = 'vivid' AND v->>'org_id' = 'c3000000-0000-0000-0000-000000000001', 'PS3 resolve ' || v::text;
  ASSERT (SELECT last_used_at FROM public.exos_distribution_partners WHERE key_hash = h) IS NOT NULL, 'PS3 stamped';
  ASSERT public.exos_dist_partner_auth(repeat('0', 64)) IS NULL AND public.exos_dist_partner_auth('nope') IS NULL, 'PS3 unknown';
  PERFORM public._exos_dist_partner_update('c3000000-0000-0000-0000-000000000001',
            (SELECT id FROM c3_keys WHERE name = 'vivid'), '{"active":false}', NULL);
  ASSERT public.exos_dist_partner_auth(h) IS NULL, 'PS3 paused key resolved';
  PERFORM public._exos_dist_partner_update('c3000000-0000-0000-0000-000000000001',
            (SELECT id FROM c3_keys WHERE name = 'vivid'), '{"active":true}', NULL);
  ASSERT public.exos_dist_partner_auth(h) IS NOT NULL, 'PS3 resumed';
  RAISE NOTICE 'OK  PS3 key check';
END $$;

-- PS4 -----------------------------------------------------------------------
DO $$
DECLARE
  sh uuid := (SELECT id FROM c3_keys WHERE name = 'stubhub');
  vv uuid := (SELECT id FROM c3_keys WHERE name = 'vivid');
  v jsonb;
BEGIN
  ASSERT public._exos_partner_ticket_types('c3000000-0000-0000-0000-000000000001', sh,
           'c3000000-0000-0000-0000-0000000000e1') = '[]'::jsonb, 'PS4 off by default';
  v := public._exos_tier_distribution_set('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000e1',
         jsonb_build_array(
           jsonb_build_object('tier_id', 'c3000000-0000-0000-0000-0000000000d1', 'enabled', true),
           jsonb_build_object('tier_id', 'c3000000-0000-0000-0000-0000000000d2', 'enabled', true, 'partner_ids', jsonb_build_array(sh))),
         'c3000000-0000-0000-0000-0000000000a1');
  ASSERT jsonb_array_length(public._exos_partner_ticket_types('c3000000-0000-0000-0000-000000000001', sh,
           'c3000000-0000-0000-0000-0000000000e1')) = 2, 'PS4 stubhub sees two';
  v := public._exos_partner_ticket_types('c3000000-0000-0000-0000-000000000001', vv, 'c3000000-0000-0000-0000-0000000000e1');
  ASSERT jsonb_array_length(v) = 1 AND v->0->>'name' = 'GA', 'PS4 vivid sees GA only ' || v::text;
  ASSERT (v->0->>'price')::numeric = 25 AND (v->0->>'fees_total')::numeric = 2 AND (v->0->>'final_cost')::numeric = 27
     AND (v->0->>'available')::int = 40, 'PS4 all-in price ' || (v->0)::text;
  -- Paused: gone; another org's partner id: refused.
  PERFORM public._exos_tier_distribution_set('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000e1',
            jsonb_build_array(jsonb_build_object('tier_id', 'c3000000-0000-0000-0000-0000000000d1', 'enabled', true, 'paused', true)), NULL);
  ASSERT jsonb_array_length(public._exos_partner_ticket_types('c3000000-0000-0000-0000-000000000001', vv,
           'c3000000-0000-0000-0000-0000000000e1')) = 0, 'PS4 paused';
  PERFORM public._exos_tier_distribution_set('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000e1',
            jsonb_build_array(jsonb_build_object('tier_id', 'c3000000-0000-0000-0000-0000000000d1', 'enabled', true)), NULL);
  BEGIN
    PERFORM public._exos_tier_distribution_set('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000e1',
              jsonb_build_array(jsonb_build_object('tier_id', 'c3000000-0000-0000-0000-0000000000d9', 'enabled', true)), NULL);
    RAISE EXCEPTION 'PS4 another event''s tier';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_tier_distribution_set('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000e1',
              jsonb_build_array(jsonb_build_object('tier_id', 'c3000000-0000-0000-0000-0000000000d1', 'enabled', true,
                                'partner_ids', jsonb_build_array('c3000000-0000-0000-0000-0000000000f9'))), NULL);
    RAISE EXCEPTION 'PS4 unknown partner id';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  PS4 per-tier switch';
END $$;
-- The dashboard RPC: owner / manager only.
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a4');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM public.exos_set_tier_distribution('c3000000-0000-0000-0000-0000000000e1',
            '[{"tier_id":"c3000000-0000-0000-0000-0000000000d3","enabled":true}]');
  RAISE EXCEPTION 'PS4 scanner set the switch';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a2');
DO $$
BEGIN
  ASSERT jsonb_array_length(public.exos_set_tier_distribution('c3000000-0000-0000-0000-0000000000e1',
            '[{"tier_id":"c3000000-0000-0000-0000-0000000000d1","enabled":true}]')) = 3, 'PS4 manager';
  ASSERT (SELECT count(*) FROM public.exos_tier_distribution) = 2, 'PS4 manager reads the switches';
END $$;
RESET ROLE;

-- PS5 / PS6 / PS7 / PS8 ---------------------------------------------------------
DO $$
DECLARE
  org uuid := 'c3000000-0000-0000-0000-000000000001';
  ev  uuid := 'c3000000-0000-0000-0000-0000000000e1';
  sh  uuid := (SELECT id FROM c3_keys WHERE name = 'stubhub');
  vv  uuid := (SELECT id FROM c3_keys WHERE name = 'vivid');
  r   jsonb; r2 jsonb; c jsonb; c2 jsonb;
  v_tok text; v_ok boolean;
BEGIN
  -- PS5: 12 GA + 2 Last five.
  r := public._exos_partner_reserve(org, ev, sh, NULL,
         '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d1","quantity":12},
           {"ticket_type_id":"c3000000-0000-0000-0000-0000000000d2","quantity":2}]',
         '{"external_id":"SH-1001","cash_paid_cents":38400}');
  v_tok := r->>'token';
  ASSERT v_tok ~ '^rsv_[A-Za-z0-9_-]{43}$' AND r->>'status' = 'active', 'PS5 token ' || r::text;
  ASSERT (r->>'total')::numeric = 12 * 27 + 2 * 32 AND (r->>'fees_total')::numeric = 28 AND r->>'total' = '388.00', 'PS5 totals ' || r::text;
  ASSERT (SELECT array_agg(h.quantity ORDER BY h.tier_id, h.quantity) FROM public.exos_cart_holds h
           JOIN public.exos_partner_reservations p ON p.id = h.partner_reservation_id WHERE p.token = v_tok)
         = ARRAY[2,10,2], 'PS5 holds in chunks of 10';
  ASSERT public.exos_effective_available('c3000000-0000-0000-0000-0000000000d1') = 28
     AND public.exos_effective_available('c3000000-0000-0000-0000-0000000000d2') = 3, 'PS5 availability drops';
  ASSERT (SELECT expires_at BETWEEN now() + interval '9 minutes' AND now() + interval '11 minutes'
            FROM public.exos_partner_reservations WHERE token = v_tok), 'PS5 ten-minute hold';
  RAISE NOTICE 'OK  PS5 reserve';

  -- PS6: Vivid can't see Last five at all; a second StubHub reservation for 4
  -- of the 3 left is refused before anyone pays.
  BEGIN
    PERFORM public._exos_partner_reserve(org, ev, vv, NULL, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d2","quantity":1}]', '{}');
    RAISE EXCEPTION 'PS6 vivid reserved a type not offered to it';
  EXCEPTION WHEN SQLSTATE 'EX422' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_partner_reserve(org, ev, sh, NULL, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d2","quantity":4}]', '{}');
    RAISE EXCEPTION 'PS6 oversold';
  EXCEPTION WHEN SQLSTATE 'EXSLD' THEN NULL;
  END;
  r2 := public._exos_partner_reserve(org, ev, sh, NULL, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d2","quantity":3}]', '{}');
  ASSERT public.exos_effective_available('c3000000-0000-0000-0000-0000000000d2') = 0, 'PS6 last three held';
  BEGIN
    PERFORM public._exos_partner_reserve(org, ev, sh, NULL, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d2","quantity":1}]', '{}');
    RAISE EXCEPTION 'PS6 sold a held seat';
  EXCEPTION WHEN SQLSTATE 'EXSLD' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_partner_reserve(org, ev, sh, NULL, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d1","quantity":101}]', '{}');
    RAISE EXCEPTION 'PS6 101 tickets';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  PS6 the race for the last seats';

  -- PS7: cancel r2 -> the three are back.
  c := public._exos_partner_reservation_cancel(org, sh, r2->>'token');
  ASSERT c->>'status' = 'cancelled' AND (c->>'released')::boolean, 'PS7 cancel ' || c::text;
  ASSERT public.exos_effective_available('c3000000-0000-0000-0000-0000000000d2') = 3, 'PS7 seats back';
  c := public._exos_partner_reservation_cancel(org, sh, r2->>'token');
  ASSERT c->>'status' = 'cancelled' AND NOT (c->>'released')::boolean, 'PS7 cancel twice';
  BEGIN
    PERFORM public._exos_partner_reservation_complete(org, sh, r2->>'token', NULL, 'https://exos.example/bridge');
    RAISE EXCEPTION 'PS7 completed a cancelled reservation';
  EXCEPTION WHEN SQLSTATE 'EX409' THEN NULL;
  END;
  RAISE NOTICE 'OK  PS7 cancel';

  -- PS8: attendee, then complete; the second call is the same order.
  r := public._exos_partner_reservation_update(org, sh, v_tok,
         '{"first_name":"Jane","last_name":"Buyer","email":"Jane@Example.com","should_send_ticket_email":true}');
  ASSERT r->>'email' = 'jane@example.com', 'PS8 update ' || r::text;
  c := public._exos_partner_reservation_complete(org, sh, v_tok, NULL, 'https://exos.example/bridge');
  ASSERT (c->>'fresh')::boolean AND c->>'status' = 'completed', 'PS8 fresh ' || left(c::text, 300);
  ASSERT jsonb_array_length(c->'order'->'tickets') = 14, 'PS8 14 tickets';
  ASSERT (SELECT count(*) FROM public.exos_tickets t JOIN public.exos_partner_reservations p ON t.id = ANY (p.ticket_ids)
           WHERE p.token = v_tok AND t.channel_source = 'partner:stubhub' AND t.owner_id = 'c3000000-0000-0000-0000-0000000000a1'
             AND t.order_ref = 'po:' || p.id AND t.attendee_name = 'Jane Buyer' AND t.pending_transfer_id IS NULL) = 14, 'PS8 minted';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = 'c3000000-0000-0000-0000-0000000000d1') = 12
     AND (SELECT tickets_sold FROM public.exos_events WHERE id = ev) = 14, 'PS8 counters';
  ASSERT (SELECT bool_and(h.status = 'consumed') FROM public.exos_cart_holds h JOIN public.exos_partner_reservations p
            ON p.id = h.partner_reservation_id WHERE p.token = v_tok), 'PS8 holds consumed';
  ASSERT public.exos_effective_available('c3000000-0000-0000-0000-0000000000d1') = 28, 'PS8 no double count';
  ASSERT (SELECT price_paid FROM public.exos_tickets WHERE tier_id = 'c3000000-0000-0000-0000-0000000000d1' AND channel_source = 'partner:stubhub' LIMIT 1) = 27,
    'PS8 price paid is all-in';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE to_email = 'jane@example.com' AND template = 'ticket-issued'
            AND html LIKE '%https://exos.example/bridge/t/%#k=%') = 1, 'PS8 tickets email with links';
  c2 := public._exos_partner_reservation_complete(org, sh, v_tok, NULL, 'https://exos.example/bridge');
  ASSERT NOT (c2->>'fresh')::boolean AND c2->'order'->>'id' = c->'order'->>'id', 'PS8 idempotent';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE channel_source = 'partner:stubhub') = 14, 'PS8 no second mint';
  ASSERT c->'order'->'tickets'->0->'delivery'->>'url' ~ '^https://exos\.example/bridge/t/[0-9a-f-]{36}#k=[A-Za-z0-9_-]{43}$',
    'PS8 delivery url ' || (c->'order'->'tickets'->0)::text;
  BEGIN
    PERFORM public._exos_partner_reservation_cancel(org, sh, v_tok);
    RAISE EXCEPTION 'PS8 cancelled a completed reservation';
  EXCEPTION WHEN SQLSTATE 'EX409' THEN NULL;
  END;
  RAISE NOTICE 'OK  PS7/PS8 complete is once, on the org owner';
END $$;

-- PS9 -----------------------------------------------------------------------
DO $$
DECLARE
  org uuid := 'c3000000-0000-0000-0000-000000000001';
  ev  uuid := 'c3000000-0000-0000-0000-0000000000e1';
  sh  uuid := (SELECT id FROM c3_keys WHERE name = 'stubhub');
  r jsonb; c jsonb;
BEGIN
  r := public._exos_partner_reserve(org, ev, sh, NULL, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d2","quantity":3}]', '{}');
  UPDATE public.exos_partner_reservations SET expires_at = now() - interval '1 second' WHERE token = r->>'token';
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second'
   WHERE partner_reservation_id = (SELECT id FROM public.exos_partner_reservations WHERE token = r->>'token');
  c := public._exos_partner_reservation_complete(org, sh, r->>'token', NULL, NULL);
  ASSERT c->>'status' = 'expired' AND NOT (c->>'fresh')::boolean, 'PS9 expired ' || c::text;
  ASSERT (SELECT status FROM public.exos_partner_reservations WHERE token = r->>'token') = 'expired', 'PS9 recorded';
  ASSERT public.exos_effective_available('c3000000-0000-0000-0000-0000000000d2') = 3, 'PS9 seats back';
  ASSERT public._exos_partner_reservation_update(org, sh, r->>'token', '{"first_name":"Late"}')->>'status' = 'expired', 'PS9 update';
  ASSERT public.exos_partner_reservations_sweep(10) = 0, 'PS9 sweep has nothing left';
  RAISE NOTICE 'OK  PS9 expiry';
END $$;

-- PS10 ----------------------------------------------------------------------
DO $$
DECLARE
  tk  record;
  v_key text;
  v jsonb; s jsonb;
BEGIN
  SELECT * INTO tk FROM public.exos_tickets WHERE channel_source = 'partner:stubhub' ORDER BY created_at, id LIMIT 1;
  v_key := public._exos_ticket_link_key(tk.id, tk.owner_id, tk.barcode_secret);
  SET LOCAL ROLE anon;
  v := public.exos_ticket_link_view(tk.id, v_key);
  RESET ROLE;
  ASSERT (v->>'ok')::boolean AND v->>'state' = 'valid' AND v->'event'->>'name' = 'C3 Show', 'PS10 view ' || v::text;
  ASSERT v->>'code' = 'T-' || tk.id || ':' || tk.owner_id || ':' || floor(extract(epoch FROM clock_timestamp()) * 1000 / 30000)::bigint
         || ':' || public._exos_door_code_mac(tk.id, tk.owner_id, floor(extract(epoch FROM clock_timestamp()) * 1000 / 30000)::bigint, tk.barcode_secret),
         'PS10 the door''s own code';
  ASSERT NOT (public.exos_ticket_link_view(tk.id, repeat('A', 43))->>'ok')::boolean, 'PS10 wrong key';
  ASSERT NOT (public.exos_ticket_link_view('c3000000-0000-0000-0000-00000000dead', v_key)->>'ok')::boolean, 'PS10 unknown ticket';
  ASSERT NOT (public.exos_ticket_link_view(tk.id, 'short')->>'ok')::boolean, 'PS10 malformed';
  -- It scans at the door.
  PERFORM pg_temp.act('c3000000-0000-0000-0000-0000000000a4');
  s := public.exos_check_in_ticket(tk.id, 'camera', 'verified', v->>'code', 'c3000000-0000-0000-0000-0000000000e1',
                                   NULL, NULL, 'Door', NULL, 'entry');
  ASSERT s->>'reason' = 'checked-in', 'PS10 scan ' || s::text;
  ASSERT public.exos_ticket_link_view(tk.id, v_key)->>'state' = 'checked_in'
     AND public.exos_ticket_link_view(tk.id, v_key)->>'code' IS NULL, 'PS10 checked in: no code';
  -- A rotated secret kills the link (reissue / transfer).
  UPDATE public.exos_tickets SET barcode_secret = gen_random_uuid()::text WHERE id = tk.id;
  ASSERT NOT (public.exos_ticket_link_view(tk.id, v_key)->>'ok')::boolean, 'PS10 old link after rotation';
  RAISE NOTICE 'OK  PS10 ticket links';
END $$;

-- PS11 ----------------------------------------------------------------------
DO $$
DECLARE
  sh uuid := (SELECT id FROM c3_keys WHERE name = 'stubhub');
  vv uuid := (SELECT id FROM c3_keys WHERE name = 'vivid');
  v_tok text := (SELECT token FROM public.exos_partner_reservations WHERE status = 'completed' LIMIT 1);
BEGIN
  BEGIN
    PERFORM public._exos_partner_reserve('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000e2', sh, NULL,
      '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d9","quantity":1}]', '{}');
    RAISE EXCEPTION 'PS11 reserved another org''s event';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_partner_reserve('c3000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000e2', sh, NULL,
      '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d9","quantity":1}]', '{}');
    RAISE EXCEPTION 'PS11 partner acted for another org';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_partner_reservation_get('c3000000-0000-0000-0000-000000000001', vv, v_tok);
    RAISE EXCEPTION 'PS11 vivid read stubhub''s reservation';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  ASSERT public._exos_partner_order('c3000000-0000-0000-0000-000000000001', vv,
           (SELECT id FROM public.exos_partner_reservations WHERE token = v_tok), NULL) IS NULL, 'PS11 vivid read the order';
  ASSERT public._exos_partner_order('c3000000-0000-0000-0000-000000000002', sh,
           (SELECT id FROM public.exos_partner_reservations WHERE token = v_tok), NULL) IS NULL, 'PS11 other org';
  BEGIN
    PERFORM public._exos_partner_ticket_types('c3000000-0000-0000-0000-000000000001', sh, 'c3000000-0000-0000-0000-0000000000e2');
    RAISE EXCEPTION 'PS11 ticket types of another org';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  RAISE NOTICE 'OK  PS11 isolation';
END $$;

-- PS12 ----------------------------------------------------------------------
DO $$
DECLARE
  org uuid := 'c3000000-0000-0000-0000-000000000001';
  ev  uuid := 'c3000000-0000-0000-0000-0000000000e1';
  sh  uuid := (SELECT id FROM c3_keys WHERE name = 'stubhub');
  r jsonb; c jsonb;
BEGIN
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('resale_min_capacity', '100000')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  BEGIN
    PERFORM public._exos_partner_reserve(org, ev, sh, NULL, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d1","quantity":1}]', '{}');
    RAISE EXCEPTION 'PS12 a partner sold under the resale rule';
  EXCEPTION WHEN SQLSTATE 'EX422' THEN NULL;
  END;
  ASSERT public._exos_partner_ticket_types(org, sh, ev) = '[]'::jsonb, 'PS12 nothing offered';
  -- An organizer reservation (API key): any type, the hidden comp crew tier too.
  r := public._exos_partner_reserve(org, ev, NULL, 'c3000000-0000-0000-0000-0000000000f1',
         '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d3","quantity":2}]', '{"first_name":"Crew"}');
  c := public._exos_partner_reservation_complete(org, NULL, r->>'token', NULL, NULL);
  ASSERT c->>'status' = 'completed' AND (SELECT count(*) FROM public.exos_tickets WHERE channel_source = 'api') = 2, 'PS12 organizer ' || c::text;
  -- A partner can't touch an organizer reservation, nor the API key a partner's.
  BEGIN
    PERFORM public._exos_partner_reservation_get(org, sh, r->>'token');
    RAISE EXCEPTION 'PS12 partner read an organizer reservation';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_partner_reservation_get(org, NULL, (SELECT token FROM public.exos_partner_reservations WHERE partner_id = sh LIMIT 1));
    RAISE EXCEPTION 'PS12 API key read a partner reservation';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  UPDATE public.exos_platform_settings SET value = '0' WHERE key = 'resale_min_capacity';
  RAISE NOTICE 'OK  PS12 resale rule; organizer reservations';
END $$;

-- PS13 ----------------------------------------------------------------------
DO $$
DECLARE
  org uuid := 'c3000000-0000-0000-0000-000000000001';
  sh  uuid := (SELECT id FROM c3_keys WHERE name = 'stubhub');
  vv  uuid := (SELECT id FROM c3_keys WHERE name = 'vivid');
  o jsonb;
BEGIN
  o := public._exos_partner_orders(org, sh, '{}', 1, 25, NULL);
  ASSERT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(o) k)
       = ARRAY['collection','current_page','per_page','total_entries','total_pages'], 'PS13 envelope';
  ASSERT (o->>'total_entries')::int = 1 AND o->'collection'->0->>'stubhub_transaction_id' = 'SH-1001', 'PS13 one order ' || left(o::text, 300);
  ASSERT (public._exos_partner_orders(org, sh, '{"external_id":"SH-1001"}', 1, 25, NULL)->>'total_entries')::int = 1
     AND (public._exos_partner_orders(org, sh, '{"external_id":"nope"}', 1, 25, NULL)->>'total_entries')::int = 0
     AND (public._exos_partner_orders(org, sh, '{"email":"jane@example.com"}', 1, 25, NULL)->>'total_entries')::int = 1
     AND (public._exos_partner_orders(org, sh, jsonb_build_object('created_gte', now() + interval '1 day'), 1, 25, NULL)->>'total_entries')::int = 0,
    'PS13 filters';
  ASSERT (public._exos_partner_orders(org, vv, '{}', 1, 25, NULL)->>'total_entries')::int = 0, 'PS13 vivid sees none';
  -- The checked-in ticket shows as such; still 14 tickets held.
  ASSERT (SELECT count(*) FROM jsonb_array_elements(o->'collection'->0->'tickets') t WHERE t->>'status' = 'checked_in') = 1,
    'PS13 checked in';
  RAISE NOTICE 'OK  PS13 orders';
END $$;

-- PS14 ----------------------------------------------------------------------
DO $$
DECLARE
  org uuid := 'c3000000-0000-0000-0000-000000000001';
  ev  uuid := 'c3000000-0000-0000-0000-0000000000e1';
  sh  uuid := (SELECT id FROM c3_keys WHERE name = 'stubhub');
  vv  uuid := (SELECT id FROM c3_keys WHERE name = 'vivid');
  c jsonb;
BEGIN
  BEGIN
    PERFORM public._exos_partner_comp(org, sh, ev, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d1","quantity":1}]', '{}', NULL);
    RAISE EXCEPTION 'PS14 comp without the scope';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  c := public._exos_partner_comp(org, vv, ev, '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d1","quantity":2}]',
         '{"first_name":"Guest","comp_reason":"Radio giveaway"}', NULL);
  ASSERT c->>'status' = 'completed' AND (c->'order'->>'total')::numeric = 0
     AND (SELECT count(*) FROM public.exos_tickets WHERE channel_source = 'partner:vivid' AND price_paid = 0) = 2, 'PS14 comp ' || c::text;
  RAISE NOTICE 'OK  PS14 comps';
END $$;

-- PS15 ----------------------------------------------------------------------
INSERT INTO public.exos_partner_reservations (token, org_id, event_id, api_key_id, channel, channel_source, status, expires_at, lines, quantity)
VALUES ('rsv_' || repeat('z', 43), 'c3000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000e2',
        'c3000000-0000-0000-0000-0000000000f1', 'organizer', 'api', 'cancelled', now(), '[]', 1);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a3');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_partner_reservations) > 0
     AND NOT EXISTS (SELECT 1 FROM public.exos_partner_reservations WHERE org_id = 'c3000000-0000-0000-0000-000000000002'),
    'PS15 finance sees its org only';
  ASSERT (SELECT count(*) FROM public.exos_distribution_partners) = 0, 'PS15 finance sees no partner keys';
END $$;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a4');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_partner_reservations) = 0, 'PS15 scanner sees nothing';
  BEGIN
    INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled)
    VALUES ('c3000000-0000-0000-0000-0000000000d3', 'c3000000-0000-0000-0000-0000000000e1', 'c3000000-0000-0000-0000-000000000001', true);
    RAISE EXCEPTION 'PS15 client wrote a switch';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  PS15 RLS';
END $$;
RESET ROLE;

-- PS16 ----------------------------------------------------------------------
DO $$
DECLARE
  org uuid := 'c3000000-0000-0000-0000-000000000001';
  sh  uuid := (SELECT id FROM c3_keys WHERE name = 'stubhub');
  r jsonb;
BEGIN
  r := public._exos_partner_reserve(org, 'c3000000-0000-0000-0000-0000000000e1', sh, NULL,
         '[{"ticket_type_id":"c3000000-0000-0000-0000-0000000000d2","quantity":2}]', '{}');
  ASSERT public.exos_effective_available('c3000000-0000-0000-0000-0000000000d2') = 1, 'PS16 held';
  PERFORM public._exos_dist_partner_revoke(org, sh, NULL);
  ASSERT (SELECT status FROM public.exos_partner_reservations WHERE token = r->>'token') = 'cancelled', 'PS16 cancelled';
  ASSERT public.exos_effective_available('c3000000-0000-0000-0000-0000000000d2') = 3, 'PS16 seats back';
  ASSERT public.exos_dist_partner_auth(encode(extensions.digest((SELECT key FROM c3_keys WHERE name = 'stubhub'), 'sha256'), 'hex')) IS NULL,
    'PS16 revoked key';
  -- Its completed orders stay readable to the org.
  ASSERT (SELECT count(*) FROM public.exos_partner_reservations WHERE partner_id = sh AND status = 'completed') = 1, 'PS16 history kept';
  RAISE NOTICE 'OK  PS16 revoke';
END $$;

SELECT '*** PARTNER SALES PASSED ***' AS result;
ROLLBACK;
