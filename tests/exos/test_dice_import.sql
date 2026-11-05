-- ============================================================================
-- Import from DICE (mig 20261106100000).
--   D1 connect: owner / manager only, the token's shape, Vault, the status
--      never carries the token
--   D2 the token is never readable: no client grant on secret_id, Vault
--      closed to clients, every token-returning function service role only
--   D3 events: an upcoming DICE event becomes a DRAFT link-out Exos event
--      (backend / primary 'dice', exos_event_imports platform 'dice',
--      display-only ticket types); a past or cancelled one is recorded, not
--      created; Exos sells nothing for it
--   D4 tickets: a 'DICE' door list, one entry per ticket with the DICE code;
--      the door finds the code (exos_door_code_lookup) and checks it in
--   D5 consent ONLY with optInPartners true (false, null, "true" as a string:
--      none); never over an Exos unsubscribe; a later false withdraws the
--      DICE-sourced consent
--   D6 an idempotent re-import: nothing duplicated, organizer edits kept,
--      a DICE reschedule moves the date
--   D7 orders: the row, the buyer, nested tickets idempotent with the tickets pass
--   D8 returns block admission (also a return that arrives before its
--      ticket), and a re-read never un-voids
--   D9 transfers: the entry follows the new holder
--   D10 leases and cursors: a stale lease writes nothing, a pass's last page
--      moves `since`, finish marks the full sync, claim refuses a busy or
--      recent one, reconnecting another account starts over
--   D11 cross-org isolation
--   D12 disconnect: the token goes, the imported data stays
--   D13 dry runs reserve a logged slot and are rate limited
--   D14 grants and RLS
--   D15 role first: a non-member, a scanner and finance are refused by every
--       gate before any token is used (connect, sync, dry run)
--   D16 the connect limit (10 an hour per org and per user), checked first
--   D17 the dry-run slot is reserved before the read; a second one at the same
--       time is refused (and a dead one older than 2 minutes is closed)
--   D18 a dry run is refused while a sync holds the lease (and a sync while a
--       preview runs)
-- Self-contained (d1ce prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d1ce0000-0000-0000-0000-0000000000a0','d1-owner@x.com',now()),
  ('d1ce0000-0000-0000-0000-0000000000a1','d1-manager@x.com',now()),
  ('d1ce0000-0000-0000-0000-0000000000a3','d1-scanner@x.com',now()),
  ('d1ce0000-0000-0000-0000-0000000000a4','d1-other@x.com',now()),
  ('d1ce0000-0000-0000-0000-0000000000a5','d1-finance@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d1ce0000-0000-0000-0000-000000000001','D1 Org','d1-org','d1ce0000-0000-0000-0000-0000000000a0'),
  ('d1ce0000-0000-0000-0000-000000000002','D1 Other','d1-other','d1ce0000-0000-0000-0000-0000000000a4');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d1ce0000-0000-0000-0000-000000000001','d1ce0000-0000-0000-0000-0000000000a0','owner'),
  ('d1ce0000-0000-0000-0000-000000000001','d1ce0000-0000-0000-0000-0000000000a1','manager'),
  ('d1ce0000-0000-0000-0000-000000000001','d1ce0000-0000-0000-0000-0000000000a3','scanner'),
  ('d1ce0000-0000-0000-0000-000000000001','d1ce0000-0000-0000-0000-0000000000a5','finance'),
  ('d1ce0000-0000-0000-0000-000000000002','d1ce0000-0000-0000-0000-0000000000a4','owner');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"d1@x.com"}', false);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('d1ce0000-0000-0000-0000-0000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.org() RETURNS uuid LANGUAGE sql AS $$ SELECT 'd1ce0000-0000-0000-0000-000000000001'::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.org() TO anon, authenticated;
CREATE FUNCTION pg_temp.org2() RETURNS uuid LANGUAGE sql AS $$ SELECT 'd1ce0000-0000-0000-0000-000000000002'::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.org2() TO anon, authenticated;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated;

-- DICE rows as _shared/dice/map.ts hands them over.
CREATE FUNCTION pg_temp.ev(p_id text, p_name text, p_start timestamptz, p_state text DEFAULT 'APPROVED') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'dice_id', p_id, 'name', p_name, 'state', p_state, 'starts_at', p_start, 'ends_at', p_start + interval '5 hours',
    'off_sale_at', p_start, 'description', 'From DICE', 'currency', 'GBP', 'url', 'https://dice.fm/event/' || lower(p_id),
    'image_url', 'https://dice-media.imgix.net/' || lower(p_id) || '.jpg', 'hidden', false, 'allocation', 300,
    'artists', jsonb_build_array('Artist A'), 'genres', jsonb_build_array('Techno'),
    'venue', jsonb_build_object('name', 'Corsica Studios', 'street', '4/5 Elephant Rd', 'city', 'London',
                                'country', 'United Kingdom', 'postal', 'SE17 1LB', 'timezone', 'Europe/London'),
    'ticket_types', jsonb_build_array(
      jsonb_build_object('dice_id', p_id || '-TT1', 'name', 'Early bird', 'price_cents', 1500, 'face_value_cents', 1300,
                         'archived', false, 'price_tiers', jsonb_build_array(jsonb_build_object('dice_id', 'PT1', 'price_cents', 1800))),
      jsonb_build_object('dice_id', p_id || '-TT2', 'name', 'Old', 'price_cents', 900, 'archived', true)))
$$;
CREATE FUNCTION pg_temp.fan(p_id text, p_email text, p_opt jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('dice_id', p_id, 'email', p_email, 'first_name', 'Fan', 'last_name', p_id,
                            'phone', '+44 7700 900' || right(p_id, 3), 'opt_in_partners', p_opt)
$$;
CREATE FUNCTION pg_temp.tk(p_id text, p_code text, p_tt text, p_holder jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('dice_id', p_id, 'code', p_code, 'ticket_type_id', p_tt, 'ticket_type_name', 'Early bird',
                            'holder', p_holder, 'full_price_cents', 1300, 'total_cents', 1500, 'claimed_at', now(),
                            'survey_answers', jsonb_build_array(jsonb_build_object('question', 'Postcode?', 'value', 'E1')))
$$;
-- Claim (manual, as the owner) and apply pages with that lease.
CREATE FUNCTION pg_temp.claim(p_org uuid, p_user uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  UPDATE public.exos_dice_connections SET last_sync_at = now() - interval '2 minutes' WHERE org_id = p_org;
  SELECT c.lease_id INTO v FROM public.exos_dice_sync_claim(p_org, p_user, 'dashboard') c;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.page(p_done boolean) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('after', CASE WHEN p_done THEN NULL ELSE 'cursor-1' END, 'done', p_done, 'pass_started_at', now())
$$;
CREATE FUNCTION pg_temp.entry(p_org uuid, p_tid text) RETURNS public.exos_guest_list_entries LANGUAGE sql AS $$
  SELECT g.* FROM public.exos_guest_list_entries g
    JOIN public.exos_dice_id_map m ON m.exos_id = g.id
   WHERE m.org_id = p_org AND m.entity = 'ticket' AND m.dice_id = p_tid
$$;
CREATE FUNCTION pg_temp.dev(p_org uuid, p_id text) RETURNS uuid LANGUAGE sql AS $$
  SELECT exos_id FROM public.exos_dice_id_map WHERE org_id = p_org AND entity = 'event' AND dice_id = p_id
$$;
CREATE FUNCTION pg_temp.fanrow(p_org uuid, p_email text) RETURNS public.exos_fans LANGUAGE sql AS $$
  SELECT * FROM public.exos_fans WHERE org_id = p_org AND email = p_email
$$;

-- D1. Connect.
DO $$
DECLARE r jsonb; c public.exos_dice_connections%ROWTYPE;
BEGIN
  PERFORM pg_temp.act(NULL);  -- the service role (exos-dice-import), user from the verified JWT
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_connect(pg_temp.org(), pg_temp.u('a3'), 'tok_dice_0123456789abcdef', 'v1', 'D1 Promotions')$q$, 'owner or manager only'), 'D1: scanner refused';
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_connect(pg_temp.org(), pg_temp.u('a5'), 'tok_dice_0123456789abcdef', 'v1', 'D1 Promotions')$q$, 'owner or manager only'), 'D1: finance refused';
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_connect(pg_temp.org(), pg_temp.u('a4'), 'tok_dice_0123456789abcdef', 'v1', 'D1 Promotions')$q$, 'owner or manager only'), 'D1: another org''s owner refused';
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_connect(pg_temp.org(), pg_temp.u('a0'), 'short', 'v1', 'D1')$q$, 'DICE API token'), 'D1: token shape';
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_connect(pg_temp.org(), pg_temp.u('a0'), 'tok dice with spaces 0123', 'v1', 'D1')$q$, 'DICE API token'), 'D1: no spaces';
  r := public.exos_dice_connect(pg_temp.org(), pg_temp.u('a1'), 'tok_dice_0123456789abcdef', 'viewer-1', 'D1 Promotions');
  ASSERT (r ->> 'connected')::boolean AND r ->> 'account_name' = 'D1 Promotions', 'D1: manager connects ' || r::text;
  SELECT * INTO c FROM public.exos_dice_connections WHERE org_id = pg_temp.org();
  ASSERT c.status = 'connected' AND c.secret_id IS NOT NULL AND c.account_id = 'viewer-1', 'D1: the row';
  ASSERT (SELECT secret FROM vault.secrets WHERE id = c.secret_id) = 'tok_dice_0123456789abcdef'
     AND (SELECT name FROM vault.secrets WHERE id = c.secret_id) = 'exos_dice:' || pg_temp.org()::text, 'D1: in Vault';
  ASSERT position('tok_dice' IN public._exos_dice_status_json(pg_temp.org())::text) = 0, 'D1: status never carries the token';
  ASSERT position(c.secret_id::text IN public._exos_dice_status_json(pg_temp.org())::text) = 0, 'D1: nor the secret id';
  -- Reconnecting with a new token for the same account updates the one secret.
  r := public.exos_dice_connect(pg_temp.org(), pg_temp.u('a0'), 'tok_dice_NEW_0123456789abcdef', 'viewer-1', 'D1 Promotions');
  ASSERT (r ->> 'same_account')::boolean, 'D1: same account';
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name = 'exos_dice:' || pg_temp.org()::text) = 1
     AND (SELECT secret FROM vault.secrets WHERE name = 'exos_dice:' || pg_temp.org()::text) = 'tok_dice_NEW_0123456789abcdef', 'D1: one secret, replaced';
  RAISE NOTICE 'OK  D1 connect';
END $$;

-- D2. The token is never readable by a client role.
DO $$
DECLARE f text; n int;
BEGIN
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_dice_connections', 'secret_id', 'SELECT'), 'D2: no secret_id grant';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_dice_connections', 'lease_id', 'SELECT'), 'D2: no lease grant';
  ASSERT has_column_privilege('authenticated', 'public.exos_dice_connections', 'status', 'SELECT'), 'D2: state readable';
  ASSERT NOT has_table_privilege('anon', 'public.exos_dice_connections', 'SELECT'), 'D2: anon nothing';
  FOREACH f IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
    ASSERT NOT has_table_privilege('authenticated', 'public.exos_dice_connections', f), 'D2: no client ' || f;
  END LOOP;
  ASSERT NOT has_schema_privilege('authenticated', 'vault', 'USAGE') AND NOT has_schema_privilege('anon', 'vault', 'USAGE'), 'D2: Vault closed';
  FOREACH f IN ARRAY ARRAY['public.exos_dice_dry_run_begin(uuid, uuid, text)', 'public.exos_dice_sync_claim(uuid, uuid, text, integer)',
                           'public.exos_dice_connect(uuid, uuid, text, text, text)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'D2: service role only ' || f;
  END LOOP;
  RAISE NOTICE 'OK  D2 grants keep the token server side';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1ce0000-0000-0000-0000-0000000000a0');
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT pg_temp.refused($q$SELECT secret_id FROM public.exos_dice_connections$q$, 'permission denied'), 'D2: owner can''t select secret_id';
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_connections$q$, 'permission denied'), 'D2: nor *';
  ASSERT pg_temp.refused($q$SELECT * FROM vault.decrypted_secrets$q$, 'permission denied'), 'D2: nor Vault';
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a0'), 'dashboard')$q$, 'permission denied'), 'D2: nor the token-returning dry run';
  ASSERT to_regprocedure('public.exos_dice_token(uuid, uuid)') IS NULL, 'D2: the old token function is gone';
  ASSERT (SELECT status FROM public.exos_dice_connections WHERE org_id = pg_temp.org()) = 'connected', 'D2: the owner reads the state';
  r := public.exos_dice_org_status(pg_temp.org());
  ASSERT (r ->> 'connected')::boolean AND (r ->> 'can_manage')::boolean AND position('tok_dice' IN r::text) = 0, 'D2: the card ' || r::text;
END $$;
SELECT pg_temp.act('d1ce0000-0000-0000-0000-0000000000a3');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_dice_connections) = 0, 'D2: a scanner sees no connection';
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_org_status(pg_temp.org())$q$, 'owners and managers only'), 'D2: nor the card';
END $$;
SELECT pg_temp.act('d1ce0000-0000-0000-0000-0000000000a5');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_dice_connections) = 0, 'D2: finance sees no connection';
  RAISE NOTICE 'OK  D2 the token is never readable';
END $$;
RESET ROLE;

-- D3. Events.
DO $$
DECLARE v_lease uuid; r jsonb; e public.exos_events%ROWTYPE; i public.exos_event_imports%ROWTYPE; v_past uuid;
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u('a3'), 'dashboard')$q$, 'owner or manager only'), 'D3: scanner can''t sync';
  v_lease := pg_temp.claim(pg_temp.org(), pg_temp.u('a0'));
  ASSERT v_lease IS NOT NULL, 'D3: claimed';
  ASSERT (SELECT kind FROM public.exos_dice_import_runs WHERE id = (SELECT run_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org())) = 'full', 'D3: a full first run';
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'events', jsonb_build_array(
         pg_temp.ev('EVT1', 'Warehouse Night', now() + interval '20 days'),
         pg_temp.ev('EVT2', 'Last Year', now() - interval '200 days'),
         pg_temp.ev('EVT3', 'Called Off', now() + interval '30 days', 'CANCELLED'),
         jsonb_build_object('name', 'no id')), pg_temp.page(true));
  ASSERT r ->> 'created' = '1' AND r ->> 'past' = '2' AND r ->> 'invalid' = '1' AND r ->> 'read' = '4', 'D3: counts ' || r::text;
  SELECT * INTO e FROM public.exos_events WHERE id = pg_temp.dev(pg_temp.org(), 'EVT1');
  SELECT * INTO i FROM public.exos_event_imports WHERE event_id = e.id;
  ASSERT e.status = 'draft' AND e.link_out AND e.ticket_backend = 'dice' AND e.primary_source = 'dice'
     AND e.external_ticket_url = 'https://dice.fm/event/evt1' AND e.org_id = pg_temp.org(), 'D3: a draft link-out event ' || row_to_json(e)::text;
  ASSERT e.name = 'Warehouse Night' AND e.venue_name = 'Corsica Studios' AND e.venue_address ->> 'city' = 'London'
     AND e.timezone = 'Europe/London' AND e.currency = 'gbp' AND e.total_tickets = 0, 'D3: details';
  ASSERT i.platform = 'dice' AND i.origin = 'account' AND i.source_event_id = 'EVT1' AND NOT i.checks_enabled
     AND i.price_min = 15 AND i.price_max = 18 AND i.currency = 'GBP' AND jsonb_array_length(i.ticket_types) = 1
     AND i.ticket_types -> 0 ->> 'name' = 'Early bird', 'D3: the import row, archived types left out ' || row_to_json(i)::text;
  ASSERT (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = pg_temp.org() AND entity = 'ticket_type' AND parent_dice_id = 'EVT1' AND event_id = e.id) = 2, 'D3: ticket types mapped';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE event_id = e.id), 'D3: no Exos ticket types';
  v_past := pg_temp.dev(pg_temp.org(), 'EVT2');
  ASSERT v_past IS NULL AND EXISTS (SELECT 1 FROM public.exos_dice_id_map WHERE org_id = pg_temp.org() AND entity = 'event' AND dice_id = 'EVT2'), 'D3: past recorded, not created';
  ASSERT pg_temp.dev(pg_temp.org(), 'EVT3') IS NULL, 'D3: cancelled not created';
  -- Exos never sells DICE's inventory (the link-out triggers).
  ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_ticket_tiers(event_id,name,price,capacity,sold,visibility,sort_order) VALUES (%L,'GA',10,10,0,'public',1)$q$, e.id), 'sold'), 'D3: no tiers';
  ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_cart_holds(event_id, tier_id, org_id, quantity, expires_at) VALUES (%L, gen_random_uuid(), pg_temp.org(), 1, now())$q$, e.id), 'sold'), 'D3: no holds';
  ASSERT (SELECT b.sells_on FROM public.exos_event_buy_link(e.id) b) = 'dice', 'D3: where to buy: DICE';
  RAISE NOTICE 'OK  D3 events become draft link-out events';
END $$;

-- D4. Tickets -> the door.
DO $$
DECLARE r jsonb; g public.exos_guest_list_entries%ROWTYPE; v_ev uuid := pg_temp.dev(pg_temp.org(), 'EVT1'); v_lease uuid;
BEGIN
  v_lease := (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org());
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T1', 'dice-qr 0001', 'EVT1-TT1', pg_temp.fan('F1', 'yes@x.com', 'true'::jsonb)),
         pg_temp.tk('T2', 'DICE-QR-0002', 'EVT1-TT1', pg_temp.fan('F2', 'no@x.com', 'false'::jsonb)),
         pg_temp.tk('T3', 'DICE-QR-0003', 'EVT1-TT1', pg_temp.fan('F3', 'null@x.com', 'null'::jsonb)),
         pg_temp.tk('T4', 'DICE-QR-0004', 'EVT1-TT1', pg_temp.fan('F4', 'str@x.com', '"true"'::jsonb)),
         pg_temp.tk('T5', 'DICE-QR-0005', 'EVT2-TT1', pg_temp.fan('F5', 'past@x.com', 'true'::jsonb)),
         pg_temp.tk('T6', NULL, 'EVT1-TT1', NULL)), pg_temp.page(false));
  ASSERT r ->> 'created' = '5' AND r ->> 'no_event' = '1' AND r ->> 'fans_created' = '5', 'D4: counts ' || r::text;
  g := pg_temp.entry(pg_temp.org(), 'T1');
  ASSERT g.event_id = v_ev AND g.external_code = 'DICE-QR0001' AND g.external_ref = 'dice:T1' AND g.source = 'DICE'
     AND g.ticket_label = 'Early bird' AND g.guest_name = 'Fan F1' AND g.email = 'yes@x.com' AND g.voided_at IS NULL, 'D4: entry ' || row_to_json(g)::text;
  ASSERT (SELECT name FROM public.exos_guest_lists WHERE id = g.list_id) = 'DICE'
     AND NOT (SELECT counts_toward_capacity FROM public.exos_guest_lists WHERE id = g.list_id), 'D4: the DICE list, outside capacity';
  ASSERT (pg_temp.entry(pg_temp.org(), 'T6')).guest_name = 'DICE ticket holder', 'D4: an unclaimed ticket';
  ASSERT pg_temp.entry(pg_temp.org(), 'T5') IS NULL
     AND EXISTS (SELECT 1 FROM public.exos_dice_id_map WHERE org_id = pg_temp.org() AND entity = 'ticket' AND dice_id = 'T5' AND exos_id IS NULL), 'D4: a past event''s ticket: no door entry';
  ASSERT (SELECT data -> 'survey_answers' -> 0 ->> 'value' FROM public.exos_dice_id_map WHERE org_id = pg_temp.org() AND entity = 'ticket' AND dice_id = 'T1') = 'E1', 'D4: survey answer kept';
  ASSERT (SELECT cursors #>> '{tickets,after}' FROM public.exos_dice_connections WHERE org_id = pg_temp.org()) = 'cursor-1'
     AND (SELECT cursors #>> '{tickets,since}' FROM public.exos_dice_connections WHERE org_id = pg_temp.org()) IS NULL, 'D4: mid-pass cursor';

  -- The door: the holder's DICE barcode, scanned (any spacing / case), is found and admitted once.
  UPDATE public.exos_events SET starts_at = now() - interval '5 minutes', ends_at = now() + interval '5 hours' WHERE id = v_ev;  -- doors open
  PERFORM pg_temp.act('d1ce0000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_door_code_lookup(v_ev, 'DICE-QR0001') = g.id, 'D4: exact code';
  ASSERT public.exos_door_code_lookup(v_ev, 'dice-qr 0001') = g.id, 'D4: as printed';
  r := public.exos_guest_check_in(g.id, 1, v_ev, gen_random_uuid());
  ASSERT r ->> 'ok' = 'true', 'D4: checked in ' || r::text;
  r := public.exos_guest_check_in(g.id, 1, v_ev, gen_random_uuid());
  ASSERT r ->> 'ok' = 'false', 'D4: once ' || r::text;
  r := public.exos_event_door_extras(v_ev);
  ASSERT (SELECT g2 ->> 'code' FROM jsonb_array_elements(r -> 'guests') g2 WHERE g2 ->> 'id' = (pg_temp.entry(pg_temp.org(), 'T2')).id::text) = 'DICE-QR-0002',
         'D4: the offline download carries the code';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  D4 DICE tickets are admitted at the Exos door by their code';
END $$;

-- D5. Consent only with optInPartners true.
DO $$
DECLARE f public.exos_fans%ROWTYPE; v_lease uuid := (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()); r jsonb;
BEGIN
  f := pg_temp.fanrow(pg_temp.org(), 'yes@x.com');
  ASSERT f.source = 'dice' AND f.email_opt_in_at IS NOT NULL AND f.email_opt_in_source = 'dice:optInPartners', 'D5: true -> on the list';
  ASSERT public._exos_fan_email_list(f) = 'subscribed', 'D5: shown subscribed';
  f := pg_temp.fanrow(pg_temp.org(), 'no@x.com');
  ASSERT f.id IS NOT NULL AND f.email_opt_in_at IS NULL AND public._exos_fan_email_list(f) = 'none', 'D5: false -> a holder without consent';
  ASSERT (pg_temp.fanrow(pg_temp.org(), 'null@x.com')).email_opt_in_at IS NULL, 'D5: null -> none';
  ASSERT (pg_temp.fanrow(pg_temp.org(), 'str@x.com')).email_opt_in_at IS NULL, 'D5: the string "true" -> none';
  ASSERT (pg_temp.fanrow(pg_temp.org(), 'past@x.com')).email_opt_in_at IS NOT NULL, 'D5: a past event''s fan with opt-in -> on the list';
  ASSERT (SELECT count(*) FROM public.exos_fans WHERE org_id = pg_temp.org() AND email_opt_in_source = 'dice:optInPartners') = 2, 'D5: exactly the two';
  -- No phone, birthday or SMS from DICE.
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_subscribers WHERE org_id = pg_temp.org()), 'D5: no SMS list';

  -- An Exos unsubscribe wins over a DICE opt-in.
  INSERT INTO public.exos_fans (org_id, email, source) VALUES (pg_temp.org(), 'gone@x.com', 'manual');
  PERFORM set_config('exos.fan_consent_action', 'on', true);
  UPDATE public.exos_fans SET email_opt_out_at = now() WHERE org_id = pg_temp.org() AND email = 'gone@x.com';
  PERFORM set_config('exos.fan_consent_action', '', true);
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T7', 'DICE-QR-0007', 'EVT1-TT1', pg_temp.fan('F7', 'gone@x.com', 'true'::jsonb))), pg_temp.page(false));
  f := pg_temp.fanrow(pg_temp.org(), 'gone@x.com');
  ASSERT f.email_opt_in_at IS NULL AND f.email_opt_out_at IS NOT NULL AND public._exos_fan_email_list(f) = 'unsubscribed', 'D5: never over an unsubscribe';

  -- DICE now says false: the DICE-sourced consent goes.
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T1', 'DICE-QR-0001', 'EVT1-TT1', pg_temp.fan('F1', 'yes@x.com', 'false'::jsonb))), pg_temp.page(false));
  f := pg_temp.fanrow(pg_temp.org(), 'yes@x.com');
  ASSERT f.email_opt_in_at IS NULL AND f.email_opt_in_source IS NULL, 'D5: withdrawn ' || r::text;
  -- and true again puts it back
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T1', 'DICE-QR-0001', 'EVT1-TT1', pg_temp.fan('F1', 'yes@x.com', 'true'::jsonb))), pg_temp.page(false));
  ASSERT (pg_temp.fanrow(pg_temp.org(), 'yes@x.com')).email_opt_in_at IS NOT NULL AND r ->> 'fans_consented' = '1', 'D5: back on ' || r::text;
  -- An Exos-sourced consent is never withdrawn by DICE.
  INSERT INTO public.exos_fans (org_id, email, source) VALUES (pg_temp.org(), 'exos@x.com', 'manual');
  PERFORM set_config('exos.fan_consent_action', 'on', true);
  UPDATE public.exos_fans SET email_opt_in_at = now(), email_opt_in_source = 'signup_form:x' WHERE org_id = pg_temp.org() AND email = 'exos@x.com';
  PERFORM set_config('exos.fan_consent_action', '', true);
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T8', 'DICE-QR-0008', 'EVT1-TT1', pg_temp.fan('F8', 'exos@x.com', 'false'::jsonb))), pg_temp.page(false));
  ASSERT (pg_temp.fanrow(pg_temp.org(), 'exos@x.com')).email_opt_in_source = 'signup_form:x', 'D5: Exos consent kept';
  -- Staff still can't set consent themselves (the guard, untouched).
  ASSERT pg_temp.refused($q$UPDATE public.exos_fans SET email_opt_in_at = now() WHERE email = 'no@x.com'$q$, 'consent'), 'D5: guard intact';
  RAISE NOTICE 'OK  D5 marketing consent only with optInPartners true';
END $$;

-- D6. Re-import is idempotent.
DO $$
DECLARE v_lease uuid; r jsonb; v_ev uuid := pg_temp.dev(pg_temp.org(), 'EVT1'); n_ev int; n_g int; n_f int; n_m int; v_start timestamptz;
BEGIN
  SELECT count(*) INTO n_ev FROM public.exos_events WHERE org_id = pg_temp.org();
  SELECT count(*) INTO n_g FROM public.exos_guest_list_entries WHERE org_id = pg_temp.org();
  SELECT count(*) INTO n_f FROM public.exos_fans WHERE org_id = pg_temp.org();
  SELECT count(*) INTO n_m FROM public.exos_dice_id_map WHERE org_id = pg_temp.org();
  UPDATE public.exos_events SET name = 'Warehouse Night (ours)' WHERE id = v_ev;
  SELECT starts_at INTO v_start FROM public.exos_events WHERE id = v_ev;
  r := public.exos_dice_sync_finish(pg_temp.org(), (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()), 'partial');
  v_lease := pg_temp.claim(pg_temp.org(), pg_temp.u('a1'));
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'events', jsonb_build_array(
         pg_temp.ev('EVT1', 'DICE renamed it', v_start + interval '1 day'),
         pg_temp.ev('EVT2', 'Last Year', now() - interval '200 days')), pg_temp.page(true));
  ASSERT r ->> 'updated' = '1' AND r ->> 'past' = '1' AND NOT (r ? 'created'), 'D6: events updated ' || r::text;
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T1', 'DICE-QR-0001', 'EVT1-TT1', pg_temp.fan('F1', 'yes@x.com', 'true'::jsonb)),
         pg_temp.tk('T2', 'DICE-QR-0002', 'EVT1-TT1', pg_temp.fan('F2', 'no@x.com', 'false'::jsonb)),
         pg_temp.tk('T5', 'DICE-QR-0005', 'EVT2-TT1', pg_temp.fan('F5', 'past@x.com', 'true'::jsonb))), pg_temp.page(true));
  ASSERT r ->> 'updated' = '2' AND r ->> 'no_event' = '1' AND NOT (r ? 'created') AND NOT (r ? 'fans_created'), 'D6: tickets updated ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_events WHERE org_id = pg_temp.org()) = n_ev, 'D6: no new event';
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries WHERE org_id = pg_temp.org()) = n_g, 'D6: no new entry';
  ASSERT (SELECT count(*) FROM public.exos_fans WHERE org_id = pg_temp.org()) = n_f, 'D6: no new fan';
  ASSERT (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = pg_temp.org()) = n_m, 'D6: no new map row';
  ASSERT (SELECT count(*) FROM public.exos_event_imports WHERE org_id = pg_temp.org() AND platform = 'dice') = 1, 'D6: one import row';
  ASSERT (SELECT name FROM public.exos_events WHERE id = v_ev) = 'Warehouse Night (ours)', 'D6: organizer edits kept';
  ASSERT (SELECT starts_at FROM public.exos_events WHERE id = v_ev) = v_start + interval '1 day'
     AND (SELECT previous_starts_at FROM public.exos_event_imports WHERE event_id = v_ev) = v_start, 'D6: rescheduled on DICE';
  ASSERT (pg_temp.entry(pg_temp.org(), 'T1')).arrived = 1, 'D6: the check-in survives a re-import';
  ASSERT (SELECT cursors #>> '{tickets,since}' FROM public.exos_dice_connections WHERE org_id = pg_temp.org()) IS NOT NULL
     AND (SELECT cursors #>> '{tickets,after}' FROM public.exos_dice_connections WHERE org_id = pg_temp.org()) IS NULL, 'D6: the pass completed';
  RAISE NOTICE 'OK  D6 re-import is idempotent and updates in place';
END $$;

-- D7. Orders.
DO $$
DECLARE v_lease uuid := (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()); r jsonb; o public.exos_dice_orders%ROWTYPE; n_g int;
BEGIN
  SELECT count(*) INTO n_g FROM public.exos_guest_list_entries WHERE org_id = pg_temp.org();
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'orders', jsonb_build_array(jsonb_build_object(
         'dice_id', 'O1', 'purchased_at', now() - interval '3 days', 'quantity', 2, 'sales_channel', 'INTERNET',
         'full_price_cents', 2600, 'commission_cents', 200, 'dice_commission_cents', 200, 'total_cents', 3000,
         'fees', jsonb_build_array(jsonb_build_object('category', 'BOOKING', 'promoter_cents', 0, 'dice_cents', 200)),
         'ip_city', 'London', 'ip_country', 'United Kingdom', 'dice_event_id', 'EVT1',
         'fan', pg_temp.fan('F9', 'buyer@x.com', 'true'::jsonb),
         'tickets', jsonb_build_array(
           pg_temp.tk('T2', 'DICE-QR-0002', 'EVT1-TT1', pg_temp.fan('F2', 'no@x.com', 'false'::jsonb)),
           pg_temp.tk('T9', 'DICE-QR-0009', 'EVT1-TT1', pg_temp.fan('F9', 'buyer@x.com', 'true'::jsonb))),
         'promo_code', 'EARLY', 'promo_type', 'discount', 'promo_discount_cents', 300)), pg_temp.page(true));
  ASSERT r ->> 'created' = '1' AND r ->> 'tickets_updated' = '1' AND r ->> 'tickets_created' = '1' AND r ->> 'fans_consented' = '1', 'D7: counts ' || r::text;
  SELECT * INTO o FROM public.exos_dice_orders WHERE org_id = pg_temp.org() AND dice_id = 'O1';
  ASSERT o.event_id = pg_temp.dev(pg_temp.org(), 'EVT1') AND o.fan_id = (pg_temp.fanrow(pg_temp.org(), 'buyer@x.com')).id
     AND o.total_cents = 3000 AND o.currency = 'GBP' AND o.ip_city = 'London' AND o.ip_country = 'United Kingdom'
     AND o.promo_code = 'EARLY' AND o.tickets = 2 AND jsonb_array_length(o.fees) = 1, 'D7: the order ' || row_to_json(o)::text;
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries WHERE org_id = pg_temp.org()) = n_g + 1, 'D7: T2 not duplicated, T9 added';
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'orders', jsonb_build_array(jsonb_build_object(
         'dice_id', 'O1', 'dice_event_id', 'EVT1', 'total_cents', 3000, 'fan', pg_temp.fan('F9', 'buyer@x.com', 'true'::jsonb))), pg_temp.page(true));
  ASSERT r ->> 'updated' = '1' AND (SELECT count(*) FROM public.exos_dice_orders WHERE org_id = pg_temp.org()) = 1, 'D7: idempotent';
  RAISE NOTICE 'OK  D7 orders';
END $$;

-- D8. Returns block admission.
DO $$
DECLARE v_lease uuid := (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()); r jsonb; v_ev uuid := pg_temp.dev(pg_temp.org(), 'EVT1');
BEGIN
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'returns', jsonb_build_array(
         jsonb_build_object('dice_id', 'R1', 'ticket_id', 'T2', 'order_id', 'O1', 'returned_at', now(), 'reason', 'Can''t make it'),
         jsonb_build_object('dice_id', 'R2', 'ticket_id', 'T10', 'returned_at', now())), pg_temp.page(true));
  ASSERT r ->> 'voided' = '1' AND r ->> 'pending' = '1', 'D8: counts ' || r::text;
  ASSERT (pg_temp.entry(pg_temp.org(), 'T2')).voided_at IS NOT NULL AND (pg_temp.entry(pg_temp.org(), 'T2')).void_reason = 'returned on DICE', 'D8: voided';
  PERFORM pg_temp.act('d1ce0000-0000-0000-0000-0000000000a3');
  r := public.exos_guest_check_in((pg_temp.entry(pg_temp.org(), 'T2')).id, 1, v_ev, gen_random_uuid());
  ASSERT r ->> 'ok' = 'false' AND r ->> 'reason' = 'voided' AND r ->> 'source' = 'DICE', 'D8: the door refuses a returned ticket ' || r::text;
  PERFORM pg_temp.act(NULL);
  -- A re-read of the ticket never un-voids it.
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T2', 'DICE-QR-0002', 'EVT1-TT1', pg_temp.fan('F2', 'no@x.com', 'false'::jsonb))), pg_temp.page(true));
  ASSERT (pg_temp.entry(pg_temp.org(), 'T2')).voided_at IS NOT NULL, 'D8: still voided';
  -- The return came first: its ticket arrives voided.
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T10', 'DICE-QR-0010', 'EVT1-TT1', pg_temp.fan('F10', 'late@x.com', 'false'::jsonb))), pg_temp.page(true));
  ASSERT (pg_temp.entry(pg_temp.org(), 'T10')).voided_at IS NOT NULL, 'D8: arrives voided';
  ASSERT (SELECT exos_id FROM public.exos_dice_id_map WHERE org_id = pg_temp.org() AND entity = 'return' AND dice_id = 'R2') = (pg_temp.entry(pg_temp.org(), 'T10')).id, 'D8: the return points at it';
  PERFORM pg_temp.act('d1ce0000-0000-0000-0000-0000000000a3');
  r := public.exos_guest_check_in((pg_temp.entry(pg_temp.org(), 'T10')).id, 1, v_ev, gen_random_uuid());
  ASSERT r ->> 'reason' = 'voided', 'D8: refused too ' || r::text;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  D8 returns block admission';
END $$;

-- D9. Transfers.
DO $$
DECLARE v_lease uuid := (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()); r jsonb; g public.exos_guest_list_entries%ROWTYPE;
BEGIN
  r := public.exos_dice_apply(pg_temp.org(), v_lease, 'transfers', jsonb_build_array(jsonb_build_object(
         'dice_id', 'X1', 'transferred_at', now(),
         'tickets', jsonb_build_array(pg_temp.tk('T3', 'DICE-QR-0003', 'EVT1-TT1', pg_temp.fan('F11', 'friend@x.com', 'false'::jsonb))))), pg_temp.page(true));
  ASSERT r ->> 'tickets_updated' = '1' AND r ->> 'transfers' = '1', 'D9: counts ' || r::text;
  g := pg_temp.entry(pg_temp.org(), 'T3');
  ASSERT g.email = 'friend@x.com' AND g.guest_name = 'Fan F11', 'D9: the new holder ' || row_to_json(g)::text;
  RAISE NOTICE 'OK  D9 transfers follow the holder';
END $$;

-- D10. Leases, cursors, the full sync, claim rules, reconnect.
DO $$
DECLARE v_lease uuid := (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org());
        v_run uuid := (SELECT run_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()); r jsonb; n int;
BEGIN
  SELECT count(*) INTO n FROM public.exos_dice_id_map WHERE org_id = pg_temp.org();
  r := public.exos_dice_apply(pg_temp.org(), gen_random_uuid(), 'events', jsonb_build_array(pg_temp.ev('EVT9', 'Sneaky', now() + interval '9 days')), pg_temp.page(true));
  ASSERT r ->> 'reason' = 'lease-lost' AND (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = pg_temp.org()) = n, 'D10: stale lease writes nothing';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_dice_apply(pg_temp.org(), %L, 'orders', '[]', '{"done": false, "pass_started_at": "2026-01-01"}')$q$, v_lease), 'bad page state'), 'D10: a mid-pass page needs a cursor';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_dice_apply(pg_temp.org(), %L, 'users', '[]', '{"done": true, "pass_started_at": "2026-01-01"}')$q$, v_lease), 'bad entity'), 'D10: entities';
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u('a0'), 'dashboard')$q$, 'already running'), 'D10: busy';
  r := public.exos_dice_sync_finish(pg_temp.org(), v_lease, 'ok');
  ASSERT (r ->> 'full_sync_done')::boolean, 'D10: every entity passed once ' || r::text;
  ASSERT (SELECT full_sync_done_at IS NOT NULL AND lease_id IS NULL AND last_ok_at IS NOT NULL FROM public.exos_dice_connections WHERE org_id = pg_temp.org()), 'D10: finished';
  ASSERT (SELECT status = 'ok' AND finished_at IS NOT NULL AND (counts #>> '{tickets,read}')::int > 0 FROM public.exos_dice_import_runs WHERE id = v_run), 'D10: the run';
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u('a0'), 'dashboard')$q$, 'less than a minute'), 'D10: recent';
  -- A run whose function died (lease lapsed, run still 'running') is closed by the next claim.
  INSERT INTO public.exos_dice_import_runs (org_id, kind, trigger, status) VALUES (pg_temp.org(), 'full', 'cron', 'running');
  -- The next claim is incremental; the cron skips an org synced within 6 hours.
  UPDATE public.exos_dice_connections SET last_sync_at = now() - interval '2 minutes' WHERE org_id = pg_temp.org();
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_dice_sync_claim(NULL, NULL, 'cron') c WHERE c.org_id = pg_temp.org()), 'D10: the cron waits';
  ASSERT (SELECT c.kind FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u('a0'), 'api') c) = 'incremental', 'D10: incremental';
  ASSERT (SELECT count(*) FROM public.exos_dice_import_runs WHERE org_id = pg_temp.org() AND status = 'running') = 1, 'D10: the stale run closed, the new one running';
  r := public.exos_dice_sync_finish(pg_temp.org(), (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()), 'error', 'DICE refused the token', '["x"]', true);
  ASSERT (SELECT status FROM public.exos_dice_connections WHERE org_id = pg_temp.org()) = 'error', 'D10: auth failure marks the connection';
  UPDATE public.exos_dice_connections SET last_sync_at = now() - interval '7 hours' WHERE org_id = pg_temp.org();
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_dice_sync_claim(NULL, NULL, 'cron') c WHERE c.org_id = pg_temp.org()), 'D10: the cron skips a refused token';
  -- Reconnecting the same account keeps the cursors; another account starts over.
  r := public.exos_dice_connect(pg_temp.org(), pg_temp.u('a0'), 'tok_dice_0123456789abcdef', 'viewer-1', 'D1 Promotions');
  ASSERT (SELECT status = 'connected' AND full_sync_done_at IS NOT NULL AND cursors ? 'events' FROM public.exos_dice_connections WHERE org_id = pg_temp.org()), 'D10: same account keeps cursors';
  r := public.exos_dice_connect(pg_temp.org(), pg_temp.u('a0'), 'tok_dice_0123456789abcdef', 'viewer-2', 'Other DICE');
  ASSERT (SELECT full_sync_done_at IS NULL AND cursors = '{}'::jsonb FROM public.exos_dice_connections WHERE org_id = pg_temp.org()), 'D10: another account starts over';
  RAISE NOTICE 'OK  D10 leases, cursors and claims';
END $$;

-- D11. Cross-org isolation: org 2 imports the same DICE ids.
DO $$
DECLARE v_lease uuid; r jsonb; v_ev1 uuid := pg_temp.dev(pg_temp.org(), 'EVT1'); v_ev2 uuid; n1 int;
BEGIN
  SELECT count(*) INTO n1 FROM public.exos_guest_list_entries WHERE org_id = pg_temp.org();
  r := public.exos_dice_connect(pg_temp.org2(), pg_temp.u('a4'), 'tok_dice_other_0123456789', 'viewer-1', 'Same DICE account');
  v_lease := pg_temp.claim(pg_temp.org2(), pg_temp.u('a4'));
  ASSERT pg_temp.refused(format($q$SELECT * FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u('a4'), 'api')$q$), 'owner or manager only'), 'D11: org 2''s owner can''t sync org 1';
  r := public.exos_dice_apply(pg_temp.org2(), v_lease, 'events', jsonb_build_array(pg_temp.ev('EVT1', 'Warehouse Night', now() + interval '20 days')), pg_temp.page(true));
  r := public.exos_dice_apply(pg_temp.org2(), v_lease, 'tickets', jsonb_build_array(
         pg_temp.tk('T1', 'DICE-QR-0001', 'EVT1-TT1', pg_temp.fan('F1', 'yes@x.com', 'false'::jsonb))), pg_temp.page(true));
  v_ev2 := pg_temp.dev(pg_temp.org2(), 'EVT1');
  ASSERT v_ev2 IS NOT NULL AND v_ev2 <> v_ev1 AND (SELECT org_id FROM public.exos_events WHERE id = v_ev2) = pg_temp.org2(), 'D11: its own event';
  ASSERT (pg_temp.entry(pg_temp.org2(), 'T1')).event_id = v_ev2 AND (pg_temp.entry(pg_temp.org(), 'T1')).event_id = v_ev1, 'D11: its own entry';
  ASSERT (pg_temp.fanrow(pg_temp.org2(), 'yes@x.com')).email_opt_in_at IS NULL
     AND (pg_temp.fanrow(pg_temp.org(), 'yes@x.com')).email_opt_in_at IS NOT NULL, 'D11: consent per org';
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries WHERE org_id = pg_temp.org()) = n1, 'D11: org 1 untouched';
  -- Org 1's lease can't write org 2.
  r := public.exos_dice_apply(pg_temp.org2(), (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()), 'events', '[]', pg_temp.page(true));
  ASSERT r ->> 'reason' = 'lease-lost', 'D11: lease per org';
  RAISE NOTICE 'OK  D11 cross-org (service side)';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1ce0000-0000-0000-0000-0000000000a4');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = pg_temp.org()) = 0
     AND (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = pg_temp.org2()) > 0, 'D11: map rows by RLS';
  ASSERT (SELECT count(*) FROM public.exos_dice_orders WHERE org_id = pg_temp.org()) = 0, 'D11: orders by RLS';
  ASSERT (SELECT count(*) FROM public.exos_dice_import_runs WHERE org_id = pg_temp.org()) = 0
     AND (SELECT count(*) FROM public.exos_dice_import_runs WHERE org_id = pg_temp.org2()) = 1, 'D11: runs by RLS';
  ASSERT (SELECT count(*) FROM public.exos_dice_connections WHERE org_id = pg_temp.org()) = 0, 'D11: connection by RLS';
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_org_status(pg_temp.org())$q$, 'owners and managers only'), 'D11: the other org''s card';
END $$;
SELECT pg_temp.act('d1ce0000-0000-0000-0000-0000000000a1');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = pg_temp.org2()) = 0
     AND (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = pg_temp.org()) > 0, 'D11: the manager sees org 1 only';
  ASSERT pg_temp.refused($q$INSERT INTO public.exos_dice_id_map (org_id, entity, dice_id) VALUES (pg_temp.org(), 'fan', 'x')$q$, 'permission denied'), 'D11: no client writes';
  RAISE NOTICE 'OK  D11 cross-org isolation';
END $$;
RESET ROLE;

-- D12. Disconnect.
DO $$
DECLARE v_lease uuid := (SELECT lease_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org2()); r jsonb; n int;
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_disconnect(pg_temp.org2(), pg_temp.u('a0'))$q$, 'owner or manager only'), 'D12: not another org';
  SELECT count(*) INTO n FROM public.exos_guest_list_entries WHERE org_id = pg_temp.org2();
  r := public.exos_dice_disconnect(pg_temp.org2(), pg_temp.u('a4'));
  ASSERT NOT (r ->> 'connected')::boolean, 'D12: disconnected';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'exos_dice:' || pg_temp.org2()::text), 'D12: the token is gone';
  ASSERT (SELECT status = 'disconnected' AND secret_id IS NULL FROM public.exos_dice_connections WHERE org_id = pg_temp.org2()), 'D12: the row';
  r := public.exos_dice_apply(pg_temp.org2(), v_lease, 'events', '[]', pg_temp.page(true));
  ASSERT r ->> 'reason' = 'lease-lost', 'D12: a running sync stops writing';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_dice_import_runs WHERE org_id = pg_temp.org2() AND status = 'running'), 'D12: its run closed';
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_sync_claim(pg_temp.org2(), pg_temp.u('a4'), 'dashboard')$q$, 'connect DICE first'), 'D12: no sync';
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_dry_run_begin(pg_temp.org2(), pg_temp.u('a4'), 'dashboard')$q$, 'connect DICE first'), 'D12: no token for a preview';
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries WHERE org_id = pg_temp.org2()) = n AND pg_temp.dev(pg_temp.org2(), 'EVT1') IS NOT NULL, 'D12: imported data stays';
  RAISE NOTICE 'OK  D12 disconnect';
END $$;

-- D13. Dry runs: a reserved, logged run row; nothing else written; rate limited.
DO $$
DECLARE r record; n int; i int; v_fin jsonb;
BEGIN
  SELECT count(*) INTO n FROM public.exos_dice_id_map;
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a3'), 'dashboard')$q$, 'owner or manager only'), 'D13: scanner refused';
  SELECT * INTO r FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a0'), 'dashboard');
  ASSERT r.run_id IS NOT NULL AND r.token = 'tok_dice_0123456789abcdef' AND r.cursors IS NOT NULL, 'D13: slot, token, cursors';
  v_fin := public.exos_dice_dry_run_finish(pg_temp.org(), r.run_id, 'ok', '{"preview": {"events_upcoming": 3, "fans_marketing_consent": 2}}');
  ASSERT (v_fin ->> 'ok')::boolean, 'D13: finished';
  ASSERT (SELECT dry_run AND status = 'ok' AND finished_at IS NOT NULL AND counts #>> '{preview,events_upcoming}' = '3' FROM public.exos_dice_import_runs WHERE id = r.run_id), 'D13: logged';
  ASSERT NOT (public.exos_dice_dry_run_finish(pg_temp.org(), r.run_id, 'ok', '{}') ->> 'ok')::boolean, 'D13: finished once';
  ASSERT NOT (public.exos_dice_dry_run_finish(pg_temp.org2(), r.run_id, 'ok', '{}') ->> 'ok')::boolean, 'D13: not another org''s run';
  ASSERT (SELECT count(*) FROM public.exos_dice_id_map) = n, 'D13: nothing imported';
  FOR i IN 1..4 LOOP
    SELECT * INTO r FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a0'), 'api');
    PERFORM public.exos_dice_dry_run_finish(pg_temp.org(), r.run_id, 'ok', '{}');
  END LOOP;
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a0'), 'api')$q$, 'too many previews'), 'D13: rate limit, before any read';
  ASSERT (public._exos_dice_runs(pg_temp.org(), 3, 0) ->> 'total')::int >= 6 AND jsonb_array_length(public._exos_dice_runs(pg_temp.org(), 3, 0) -> 'rows') = 3, 'D13: the runs list pages';
  RAISE NOTICE 'OK  D13 dry runs';
END $$;

-- D14. Grants and RLS.
DO $$
DECLARE f text; t text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_dice_connect(uuid, uuid, text, text, text)', 'public.exos_dice_disconnect(uuid, uuid)',
    'public.exos_dice_connect_begin(uuid, uuid)', 'public.exos_dice_sync_claim(uuid, uuid, text, integer)',
    'public.exos_dice_apply(uuid, uuid, text, jsonb, jsonb)',
    'public.exos_dice_sync_finish(uuid, uuid, text, text, jsonb, boolean)',
    'public.exos_dice_dry_run_begin(uuid, uuid, text)', 'public.exos_dice_dry_run_finish(uuid, uuid, text, jsonb, text)',
    'public._exos_dice_status_json(uuid)', 'public._exos_dice_runs(uuid, integer, integer)',
    'public._exos_dice_id(text)', 'public._exos_dice_ref(text)', 'public._exos_dice_ts(text)',
    'public._exos_dice_counts_merge(jsonb, jsonb)', 'public._exos_dice_list(uuid, uuid)',
    'public._exos_dice_fan_upsert(uuid, jsonb)', 'public._exos_dice_event_upsert(uuid, uuid, jsonb)',
    'public._exos_dice_ticket_upsert(uuid, uuid, jsonb, text)', 'public._exos_dice_return_upsert(uuid, jsonb, text)',
    'public._exos_dice_order_upsert(uuid, uuid, jsonb)', 'public._exos_dice_transfer_upsert(uuid, uuid, jsonb)',
    'public._exos_dice_run_json(public.exos_dice_import_runs)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'D14: service only ' || f;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_dice_org_status(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_dice_org_status(uuid)', 'EXECUTE'), 'D14: the card';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_dice_connect_attempts', 'SELECT'), 'D14: attempts are service only';
  FOREACH t IN ARRAY ARRAY['public.exos_dice_connections', 'public.exos_dice_import_runs', 'public.exos_dice_id_map', 'public.exos_dice_orders',
                           'public.exos_dice_connect_attempts'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = t::regclass), 'D14: RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', t, 'SELECT'), 'D14: anon ' || t;
    ASSERT NOT has_table_privilege('authenticated', t, 'INSERT') AND NOT has_table_privilege('authenticated', t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', t, 'DELETE'), 'D14: no client writes ' || t;
  END LOOP;
  -- Definer functions pin their search_path.
  ASSERT NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE '%exos_dice%'
                      AND p.prosecdef AND NOT coalesce(p.proconfig::text LIKE '%search_path=public, pg_temp%', false)), 'D14: search_path';
  -- The cron, when pg_cron is here, is inactive.
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE $q$SELECT NOT coalesce(bool_or(active), false) FROM cron.job WHERE jobname = 'exos-dice-import-sync-hourly'$q$ INTO STRICT f;
    ASSERT f::boolean, 'D14: the cron is inactive';
  END IF;
  RAISE NOTICE 'OK  D14 grants and RLS';
END $$;

-- D15. Role first: every gate refuses a non-member, a scanner and finance
-- before any token is read or any attempt or run is recorded.
DO $$
DECLARE u text; n_att int; n_run int;
BEGIN
  PERFORM pg_temp.act(NULL);
  SELECT count(*) INTO n_att FROM public.exos_dice_connect_attempts;
  SELECT count(*) INTO n_run FROM public.exos_dice_import_runs;
  UPDATE public.exos_dice_connections SET last_sync_at = now() - interval '2 minutes' WHERE org_id = pg_temp.org();
  FOREACH u IN ARRAY ARRAY['a3', 'a5', 'a4', 'ff'] LOOP   -- scanner, finance, another org's owner, nobody
    ASSERT pg_temp.refused(format($q$SELECT public.exos_dice_connect_begin(pg_temp.org(), pg_temp.u(%L))$q$, u), 'owner or manager only'), 'D15: connect ' || u;
    ASSERT pg_temp.refused(format($q$SELECT * FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u(%L), 'dashboard')$q$, u), 'owner or manager only'), 'D15: sync ' || u;
    ASSERT pg_temp.refused(format($q$SELECT * FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u(%L), 'api')$q$, u), 'owner or manager only'), 'D15: api sync ' || u;
    ASSERT pg_temp.refused(format($q$SELECT * FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u(%L), 'dashboard')$q$, u), 'owner or manager only'), 'D15: dry run ' || u;
    ASSERT pg_temp.refused(format($q$SELECT public.exos_dice_connect(pg_temp.org(), pg_temp.u(%L), 'tok_dice_0123456789abcdef', 'viewer-2', 'x')$q$, u), 'owner or manager only'), 'D15: store ' || u;
  END LOOP;
  ASSERT (SELECT count(*) FROM public.exos_dice_connect_attempts) = n_att, 'D15: no attempt recorded';
  ASSERT (SELECT count(*) FROM public.exos_dice_import_runs) = n_run, 'D15: no run reserved';
  ASSERT (SELECT lease_id IS NULL FROM public.exos_dice_connections WHERE org_id = pg_temp.org()), 'D15: no lease taken';
  RAISE NOTICE 'OK  D15 the role is checked before any token use';
END $$;

-- D16. The connect limit: 10 attempts an hour per org and per user, checked first.
DO $$
DECLARE i int; r jsonb;
BEGIN
  DELETE FROM public.exos_dice_connect_attempts;
  FOR i IN 1..10 LOOP r := public.exos_dice_connect_begin(pg_temp.org(), pg_temp.u('a0')); END LOOP;
  ASSERT (r ->> 'attempts_left')::int = 0, 'D16: counted ' || r::text;
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_connect_begin(pg_temp.org(), pg_temp.u('a0'))$q$, 'too many connect attempts'), 'D16: the 11th for the user';
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_connect_begin(pg_temp.org(), pg_temp.u('a1'))$q$, 'too many connect attempts'), 'D16: the org is at its limit for everyone';
  ASSERT (SELECT count(*) FROM public.exos_dice_connect_attempts WHERE org_id = pg_temp.org()) = 10, 'D16: refusals are not recorded';
  -- Per user, across orgs: the manager of org 1 also manages org 2.
  INSERT INTO public.exos_org_memberships(org_id, user_id, role) VALUES (pg_temp.org2(), pg_temp.u('a1'), 'manager');
  INSERT INTO public.exos_dice_connect_attempts (org_id, user_id) SELECT pg_temp.org(), pg_temp.u('a1') FROM generate_series(1, 10);
  ASSERT (SELECT count(*) FROM public.exos_dice_connect_attempts WHERE org_id = pg_temp.org2()) = 0, 'D16: org 2 is fresh';
  ASSERT pg_temp.refused($q$SELECT public.exos_dice_connect_begin(pg_temp.org2(), pg_temp.u('a1'))$q$, 'too many connect attempts'), 'D16: the user is at the limit in any org';
  r := public.exos_dice_connect_begin(pg_temp.org2(), pg_temp.u('a4'));
  ASSERT (r ->> 'ok')::boolean, 'D16: org 2''s owner still may';
  -- An hour later the window has passed.
  UPDATE public.exos_dice_connect_attempts SET at = now() - interval '61 minutes';
  r := public.exos_dice_connect_begin(pg_temp.org(), pg_temp.u('a0'));
  ASSERT (r ->> 'attempts_left')::int = 9, 'D16: a fresh hour ' || r::text;
  RAISE NOTICE 'OK  D16 the connect limit';
END $$;

-- D17. The dry-run slot is reserved before the read; a second one at the same time is refused.
DO $$
DECLARE r record; v_run uuid;
BEGIN
  UPDATE public.exos_dice_import_runs SET started_at = now() - interval '10 minutes' WHERE org_id = pg_temp.org() AND dry_run;  -- out of D13's minute
  SELECT * INTO r FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a0'), 'dashboard');
  -- What exists when the edge function starts reading: the running row, reserved.
  ASSERT (SELECT status = 'running' AND dry_run AND started_by = pg_temp.u('a0') FROM public.exos_dice_import_runs WHERE id = r.run_id), 'D17: reserved first';
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a1'), 'api')$q$, 'already running'), 'D17: a second preview is refused';
  UPDATE public.exos_dice_connections SET last_sync_at = now() - interval '2 minutes' WHERE org_id = pg_temp.org();
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u('a0'), 'dashboard')$q$, 'a preview is running'), 'D17: and a sync';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_dice_sync_claim(NULL, NULL, 'cron') c WHERE c.org_id = pg_temp.org()), 'D17: and the cron';
  PERFORM public.exos_dice_dry_run_finish(pg_temp.org(), r.run_id, 'ok', '{}');
  -- A preview whose function died (still 'running' after 2 minutes) doesn't block: it is closed.
  INSERT INTO public.exos_dice_import_runs (org_id, kind, trigger, dry_run, status, started_at)
  VALUES (pg_temp.org(), 'full', 'dashboard', true, 'running', now() - interval '3 minutes') RETURNING id INTO v_run;
  SELECT * INTO r FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a0'), 'dashboard');
  ASSERT (SELECT status = 'error' AND error = 'interrupted' FROM public.exos_dice_import_runs WHERE id = v_run), 'D17: the dead one closed';
  PERFORM public.exos_dice_dry_run_finish(pg_temp.org(), r.run_id, 'ok', '{}');
  RAISE NOTICE 'OK  D17 the dry-run slot is reserved before reading';
END $$;

-- D18. A dry run is refused while a sync holds the lease.
DO $$
DECLARE v_lease uuid; r jsonb;
BEGIN
  UPDATE public.exos_dice_import_runs SET started_at = now() - interval '10 minutes' WHERE org_id = pg_temp.org() AND dry_run;
  v_lease := pg_temp.claim(pg_temp.org(), pg_temp.u('a0'));
  ASSERT v_lease IS NOT NULL, 'D18: a sync holds the lease';
  ASSERT pg_temp.refused($q$SELECT * FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a1'), 'dashboard')$q$, 'a DICE sync is running'), 'D18: preview refused';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_dice_import_runs WHERE org_id = pg_temp.org() AND dry_run AND status = 'running'), 'D18: nothing reserved';
  r := public.exos_dice_sync_finish(pg_temp.org(), v_lease, 'ok');
  ASSERT EXISTS (SELECT 1 FROM public.exos_dice_dry_run_begin(pg_temp.org(), pg_temp.u('a1'), 'dashboard')), 'D18: allowed once the lease is released';
  RAISE NOTICE 'OK  D18 no preview while a sync runs';
END $$;

\echo 'test_dice_import: all passed'
ROLLBACK;
