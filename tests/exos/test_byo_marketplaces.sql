-- ============================================================================
-- Selling on the organizer's OWN marketplace accounts (mig 20261121214500).
-- Self-contained (b4 prefix), rolled back.
--   BY1  shape: exos_byo_allocations RLS on, no client grants; the helpers
--        internal; set / view for signed-in users only (role checked inside)
--   BY2  only an owner / manager of the event's org sets or reads it
--   BY3  % per ticket type: floor(capacity * %), at least 1 above 0; a $0
--        ticket type skipped (resale never), a table / no-capacity one too;
--        the rows are account 'own'; seats set aside from Exos checkout
--   BY4  one account per marketplace per event: not where the Exos network
--        is ticked; a row that sold can't change account
--   BY5  the Exos network's gates don't apply (a free-tier event, resale
--        locked for the network, still sells on the organizer's own account)
--   BY6  $0: no allocation of a $0 ticket type on an own-account channel,
--        even by hand (exos_set_channel_allocation)
--   BY7  an own-account sale: no Exos fee (0 bps, kept), the organizer nets
--        all of it, nothing on Exos's books, while Exos checkout on the same
--        150+ event pays 2%; its tickets are static codes
--   BY8  the share never goes below what the marketplace sold (the smallest
--        % allowed is in the error and the view)
--   BY9  every change is audited (event.byo_allocation, old / new %)
--   BY10 the auto split never touches an own-account marketplace
--   BY11 a network sale on the same event pays 2% and is on the books; matched
--        to the own-account listing instead it is re-priced at 0, and back
--   BY12 the view: %, smallest %, credential connected or not, per type
--   BY13 (review of #143, R1) ticking a marketplace under Distribution is
--        refused while it is sold with the organizer's own account
--   BY14 (R2) only exos_byo_set_allocation allocates an own-account channel;
--        0% with nothing ever done gives the marketplace back; 0% with sales
--        keeps it the organizer's
--   BY15 (R3) an own-account sale is never Exos's to pay out: state
--        own_account, no remittance covers it, no payout line
--   BY16 (R4) a once-network row is never reused for the own account (new
--        rows, new ids; a touched one refuses the switch); an order keeps the
--        account it was first matched on
--   BY17 an event edit doesn't pull an own-account marketplace's seats
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('b4000000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid
$$;
CREATE FUNCTION pg_temp.as_(p_role text, p_uid uuid DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', p_role, true);
  PERFORM set_config('app.uid', coalesce(p_uid::text, ''), true);
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', p_role)::text, true);
END $$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text), pg_temp.as_(text, uuid), pg_temp.st(text) TO anon, authenticated, service_role;

-- The rules this suite depends on, whatever an earlier suite left behind.
DELETE FROM public.exos_platform_settings WHERE key IN ('free_tier_max_capacity', 'resale_consent_required', 'platform_fee_bps');
INSERT INTO public.exos_platform_settings (key, value) VALUES ('free_tier_max_capacity', '149'), ('resale_consent_required', 'false');
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  (pg_temp.u('a0'),'b4-owner@x.com',now()), (pg_temp.u('a1'),'b4-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES (pg_temp.u('1'),'B4 Org','b4-org',pg_temp.u('a0'));
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES (pg_temp.u('1'),pg_temp.u('a0'),'owner')
  ON CONFLICT DO NOTHING;
-- A 257-seat event (paid tier) and a 40-seat one (the free tier: resale locked for the Exos network).
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  (pg_temp.u('e1'),pg_temp.u('1'),'B4 Big','published',now() + interval '60 days','Hall',257,0,ARRAY['seatgeek']),
  (pg_temp.u('e2'),pg_temp.u('1'),'B4 Small','published',now() + interval '60 days','Bar',40,0,'{}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order) VALUES
  (pg_temp.u('d1'),pg_temp.u('e1'),'GA',40,200,0,1),
  (pg_temp.u('d2'),pg_temp.u('e1'),'VIP',100,7,0,2),
  (pg_temp.u('d3'),pg_temp.u('e1'),'Free',0,50,0,3),
  (pg_temp.u('d4'),pg_temp.u('e2'),'GA',20,40,0,1);
-- After the org's free months, so the capacity rule is what applies.
UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day' WHERE org_id = pg_temp.u('1');
-- The org's own StubHub seller account (a credential in the store; no secret is read here).
INSERT INTO public.exos_org_integrations (org_id, provider, secret_id, status)
VALUES (pg_temp.u('1'), 'stubhub', gen_random_uuid(), 'connected');

-- BY1 shape
DO $$
DECLARE f text;
BEGIN
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_byo_allocations'::regclass), 'BY1: RLS on';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_byo_allocations', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_byo_allocations', 'SELECT'), 'BY1: no client reads';
  FOREACH f IN ARRAY ARRAY['public._exos_byo_channel(uuid,text)', 'public._exos_byo_listing(uuid)',
                           'public._exos_byo_ticket(text,text)', 'public._exos_tg_listing_account()'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
      'BY1: internal ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_byo_set_allocation(uuid,text,numeric)', 'public.exos_byo_allocations_view(uuid)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
      'BY1: signed-in only ' || f;
  END LOOP;
  RAISE NOTICE 'BY1 PASS: shape and grants';
END $$;

-- BY2 roles
SELECT pg_temp.as_('authenticated', pg_temp.u('a1'));
DO $$
BEGIN
  ASSERT left(pg_temp.st(format('SELECT public.exos_byo_set_allocation(%L, %L, 10)', pg_temp.u('e1'), 'stubhub')), 5) = '42501',
    'BY2: a stranger can''t set it';
  ASSERT left(pg_temp.st(format('SELECT public.exos_byo_allocations_view(%L)', pg_temp.u('e1'))), 5) = '42501',
    'BY2: a stranger can''t read it';
  RAISE NOTICE 'BY2 PASS: owner / manager only';
END $$;
RESET ROLE;

-- BY3 the %
SELECT pg_temp.as_('authenticated', pg_temp.u('a0'));
DO $$
DECLARE r jsonb; d record;
BEGIN
  r := public.exos_byo_set_allocation(pg_temp.u('e1'), 'stubhub', 10);
  ASSERT (r ->> 'pct')::numeric = 10, 'BY3: pct ' || r;
  ASSERT (SELECT (x ->> 'quantity')::int FROM jsonb_array_elements(r -> 'tiers') x WHERE x ->> 'name' = 'GA') = 20, 'BY3: GA floor(200 x 10%) ' || r;
  ASSERT (SELECT (x ->> 'quantity')::int FROM jsonb_array_elements(r -> 'tiers') x WHERE x ->> 'name' = 'VIP') = 1, 'BY3: VIP floor(0.7) -> at least 1 ' || r;
  ASSERT (SELECT x ->> 'reason' FROM jsonb_array_elements(r -> 'skipped') x WHERE x ->> 'name' = 'Free') LIKE '%$0%', 'BY3: $0 skipped ' || r;
  RESET ROLE;
  ASSERT (SELECT count(*) FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1') AND channel = 'stubhub') = 2, 'BY3: two rows';
  ASSERT (SELECT bool_and(account = 'own') FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1') AND channel = 'stubhub'), 'BY3: own';
  SELECT * INTO d FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1') AND channel = 'stubhub' AND tier_id = pg_temp.u('d1');
  ASSERT d.sell_cap = 20 AND d.requested_qty > 0, 'BY3: GA cap 20, a pool held ' || row_to_json(d);
  -- The held seats are out of Exos checkout's availability.
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 200 - d.requested_qty, 'BY3: set aside from checkout';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a0'));
  r := public.exos_byo_set_allocation(pg_temp.u('e1'), 'stubhub', 0.5);
  ASSERT (SELECT (x ->> 'quantity')::int FROM jsonb_array_elements(r -> 'tiers') x WHERE x ->> 'name' = 'GA') = 1, 'BY3: 0.5% of 200 = 1 ' || r;
  r := public.exos_byo_set_allocation(pg_temp.u('e1'), 'stubhub', 10);
  ASSERT left(pg_temp.st(format('SELECT public.exos_byo_set_allocation(%L, %L, 101)', pg_temp.u('e1'), 'stubhub')), 5) = '22023', 'BY3: 0-100';
  ASSERT left(pg_temp.st(format('SELECT public.exos_byo_set_allocation(%L, %L, 10)', pg_temp.u('e1'), 'gametime')), 5) = '22023', 'BY3: listed channels only';
  RAISE NOTICE 'BY3 PASS: %% of capacity per type, floor, at least 1, $0 skipped, own rows';
END $$;

-- BY4 one account per marketplace
DO $$
BEGIN
  -- SeatGeek is ticked under Distribution for e1: the Exos network sells it there.
  ASSERT pg_temp.st(format('SELECT public.exos_byo_set_allocation(%L, %L, 10)', pg_temp.u('e1'), 'seatgeek')) LIKE '22023%Distribution%',
    'BY4: not where the network is ticked';
  RESET ROLE;
  ASSERT left(pg_temp.st(format($q$UPDATE public.exos_distribution_listings SET account = 'platform'
                                   WHERE event_id = %L AND channel = 'stubhub'$q$, pg_temp.u('e1'))), 5) = '42501',
    'BY4: a row''s account is fixed when it is made';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a0'));
  RAISE NOTICE 'BY4 PASS: one account per marketplace per event';
END $$;

-- BY5 the Exos network's gates don't apply to the organizer's own account
DO $$
DECLARE r jsonb;
BEGIN
  RESET ROLE;
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e2')), 'BY5: e2 is resale-locked for the network';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a0'));
  ASSERT left(pg_temp.st(format('SELECT public.exos_set_channel_allocation(%L, %L, %L, 5)', pg_temp.u('e2'), 'vivid', pg_temp.u('d4'))), 5) = '22023',
    'BY5: the network still refuses it';
  r := public.exos_byo_set_allocation(pg_temp.u('e2'), 'vivid', 25);
  ASSERT (r -> 'tiers' -> 0 ->> 'quantity')::int = 10, 'BY5: 25% of 40 on the organizer''s own Vivid account ' || r;
  RAISE NOTICE 'BY5 PASS: own account sells a free-tier event; the network does not';
END $$;

-- BY6 $0 by hand: refused outright (only exos_byo_set_allocation allocates an
-- own-account channel), and behind that gate the $0 rule still holds.
DO $$
BEGIN
  ASSERT pg_temp.st(format('SELECT public.exos_set_channel_allocation(%L, %L, %L, 3)', pg_temp.u('e1'), 'stubhub', pg_temp.u('d3'))) LIKE '42501%own seller account%',
    'BY6: by hand, refused';
  PERFORM set_config('exos.byo_alloc_ok', 'on', true);
  ASSERT pg_temp.st(format('SELECT public.exos_set_channel_allocation(%L, %L, %L, 3)', pg_temp.u('e1'), 'stubhub', pg_temp.u('d3'))) LIKE '22023%$0%',
    'BY6: a $0 type is never on a resale marketplace';
  PERFORM set_config('exos.byo_alloc_ok', '', true);
  RAISE NOTICE 'BY6 PASS: $0 blocked';
END $$;
RESET ROLE;

-- BY7 an own-account sale
CREATE FUNCTION pg_temp.sale(p_id text, p_listing text, p_qty int, p_proceeds text) RETURNS uuid LANGUAGE sql AS $$
  SELECT order_id FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','stubhub','external_order_id', p_id, 'external_listing_id', p_listing,
    'quantity', p_qty, 'sale_status','confirmed', 'proceeds', p_proceeds, 'currency','USD', 'buyer_email', 'b4-buyer@x.com'));
$$;
DO $$
DECLARE o uuid; m record; ga uuid; n int;
BEGIN
  SELECT id INTO ga FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1') AND channel = 'stubhub' AND tier_id = pg_temp.u('d1');
  o := pg_temp.sale('b4-1', ga::text, 2, '80.00');
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  ASSERT m.distribution_listing_id = ga, 'BY7: matched';
  ASSERT m.exos_fee_bps = 0 AND m.exos_fee = 0 AND m.organizer_net = 80.00, 'BY7: no Exos fee ' || row_to_json(m);
  -- Exos checkout on the same 257-seat event pays the standard 2%.
  ASSERT public.exos_event_fee_bps(pg_temp.u('e1'), now()) = 200, 'BY7: checkout pays 200 bps here';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_journal_entries WHERE source_table = 'exos_marketplace_orders' AND source_id = o::text),
    'BY7: off Exos''s books';
  -- An unchanged re-poll keeps it.
  PERFORM pg_temp.sale('b4-1', ga::text, 2, '80.00');
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  ASSERT m.exos_fee_bps = 0 AND m.exos_fee = 0, 'BY7: kept on re-poll';
  -- The tickets: static codes, whatever the event's size.
  PERFORM public.exos_fulfil_marketplace_order(o);
  SELECT count(*) INTO n FROM public.exos_tickets WHERE order_ref = 'stubhub:b4-1';
  ASSERT n = 2, 'BY7: two tickets, got ' || n;
  ASSERT (SELECT bool_and(code_mode = 'static') FROM public.exos_tickets WHERE order_ref = 'stubhub:b4-1'), 'BY7: static codes';
  ASSERT public._exos_ticket_code_mode(pg_temp.u('e1')) = 'rotating', 'BY7: an Exos ticket here would rotate';
  ASSERT (SELECT sold_qty FROM public.exos_distribution_listings WHERE id = ga) = 2, 'BY7: sold on the listing';
  RAISE NOTICE 'BY7 PASS: no fee, off the books, static codes; checkout still 2%%';
END $$;

-- BY8 never below what sold
SELECT pg_temp.as_('authenticated', pg_temp.u('a0'));
DO $$
DECLARE r jsonb; e text;
BEGIN
  e := pg_temp.st(format('SELECT public.exos_byo_set_allocation(%L, %L, 0.5)', pg_temp.u('e1'), 'stubhub'));
  ASSERT e LIKE '22023%StubHub sold 2 of GA already%below 1.00\%', 'BY8: refused below sold, got ' || e;
  ASSERT left(pg_temp.st(format('SELECT public.exos_byo_set_allocation(%L, %L, 0)', pg_temp.u('e1'), 'stubhub')), 5) = '22023', 'BY8: not to 0 either';
  r := public.exos_byo_set_allocation(pg_temp.u('e1'), 'stubhub', 1);
  ASSERT (SELECT (x ->> 'quantity')::int FROM jsonb_array_elements(r -> 'tiers') x WHERE x ->> 'name' = 'GA') = 2, 'BY8: 1% = the 2 sold ' || r;
  RAISE NOTICE 'BY8 PASS: never below the share already sold';
END $$;
RESET ROLE;

-- BY9 audit
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.exos_org_audit
   WHERE org_id = pg_temp.u('1') AND action = 'event.byo_allocation' AND event_id = pg_temp.u('e1') AND changes ->> 'channel' = 'stubhub';
  ASSERT n = 4, 'BY9: one row per change (10, 0.5, 10, 1), got ' || n;
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'event.byo_allocation'
                  AND changes -> 'pct' = '[10, 1]'::jsonb AND actor_uid = pg_temp.u('a0')), 'BY9: old / new % and who';
  RAISE NOTICE 'BY9 PASS: audited';
END $$;

-- BY10 the auto split leaves it alone
DO $$
BEGIN
  UPDATE public.exos_events SET channel_split_mode = 'auto' WHERE id = pg_temp.u('e1');
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e1')) WHERE channel = 'stubhub'),
    'BY10: no split share for an own-account marketplace';
  ASSERT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e1')) WHERE channel = 'seatgeek'), 'BY10: the network still splits';
  UPDATE public.exos_events SET channel_split_mode = 'manual' WHERE id = pg_temp.u('e1');
  RAISE NOTICE 'BY10 PASS: never split';
END $$;

-- BY11 a network sale on the same event pays 2%; an unmatched sale first matched
-- to the own-account listing is re-priced at 0; a matched sale keeps its account
DO $$
DECLARE o uuid; m record; ga uuid; sg uuid;
BEGIN
  PERFORM public.exos_set_channel_allocation(pg_temp.u('e1'), 'seatgeek', pg_temp.u('d1'), 10);
  SELECT id INTO sg FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1') AND channel = 'seatgeek' AND tier_id = pg_temp.u('d1');
  SELECT id INTO ga FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1') AND channel = 'stubhub' AND tier_id = pg_temp.u('d1');
  ASSERT (SELECT account FROM public.exos_distribution_listings WHERE id = sg) = 'platform', 'BY11: SeatGeek is the network''s';
  SELECT order_id INTO o FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','seatgeek','external_order_id','b4-sg-1','external_listing_id', sg::text,
    'quantity', 1, 'sale_status','confirmed', 'proceeds', '40.00', 'currency','USD'));
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  ASSERT m.exos_fee_bps = 200 AND m.exos_fee = 0.80 AND m.organizer_net = 39.20, 'BY11: the network sale pays 2% ' || row_to_json(m);
  ASSERT EXISTS (SELECT 1 FROM public.exos_journal_entries WHERE source_table = 'exos_marketplace_orders' AND source_id = o::text),
    'BY11: the network sale is on the books';
  ASSERT m.account = 'platform', 'BY11: stamped the network''s ' || row_to_json(m);
  -- Re-matched to the own-account listing: the account it was sold on stays.
  UPDATE public.exos_marketplace_orders SET distribution_listing_id = ga WHERE id = o;
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  ASSERT m.account = 'platform' AND m.exos_fee_bps = 200 AND m.exos_fee = 0.80, 'BY11: a re-match keeps the account and fee ' || row_to_json(m);
  ASSERT left(pg_temp.st(format($q$UPDATE public.exos_marketplace_orders SET account = 'own' WHERE id = %L$q$, o)), 2) = 'ok'
     AND (SELECT account FROM public.exos_marketplace_orders WHERE id = o) = 'platform', 'BY11: the stamp can''t be rewritten';
  -- A sale recorded before it was matched (no listing): the network's rate,
  -- then first matched to the own-account listing: 0, off the books.
  INSERT INTO public.exos_marketplace_orders (channel, external_order_id, event_id, org_id, quantity, proceeds, currency, sale_status)
  VALUES ('stubhub', 'b4-sh-late', pg_temp.u('e1'), pg_temp.u('1'), 1, 40.00, 'USD', 'confirmed')
  RETURNING id INTO o;
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  ASSERT m.exos_fee_bps = 200, 'BY11: unmatched, priced as the network''s meanwhile ' || row_to_json(m);
  ASSERT m.account IS NULL AND m.distribution_listing_id IS NULL, 'BY11: unmatched, no account yet ' || row_to_json(m);
  UPDATE public.exos_marketplace_orders SET distribution_listing_id = ga WHERE id = o;
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  ASSERT m.account = 'own' AND m.exos_fee_bps = 0 AND m.exos_fee = 0 AND m.organizer_net = 40.00, 'BY11: first matched to its own-account listing: 0 ' || row_to_json(m);
  RAISE NOTICE 'BY11 PASS: the account a sale was first matched on decides its fee';
END $$;

-- BY12 the view
SELECT pg_temp.as_('authenticated', pg_temp.u('a0'));
DO $$
DECLARE v jsonb; sh jsonb; sg jsonb;
BEGIN
  v := public.exos_byo_allocations_view(pg_temp.u('e1'));
  ASSERT (v ->> 'dry_run')::boolean AND NOT (v -> 'event' ->> 'free_tier')::boolean, 'BY12: dry run, paid tier ' || v;
  SELECT x INTO sh FROM jsonb_array_elements(v -> 'channels') x WHERE x ->> 'channel' = 'stubhub';
  SELECT x INTO sg FROM jsonb_array_elements(v -> 'channels') x WHERE x ->> 'channel' = 'seatgeek';
  ASSERT (sh ->> 'own')::boolean AND (sh ->> 'pct')::numeric = 1 AND (sh ->> 'connected')::boolean, 'BY12: stubhub ' || sh;
  ASSERT (sh ->> 'min_pct')::numeric = 1, 'BY12: 2 GA sold of 200 = 1% at least ' || sh;
  ASSERT NOT (sg ->> 'own')::boolean AND NOT (sg ->> 'connected')::boolean AND (sg ->> 'network_ticked')::boolean, 'BY12: seatgeek ' || sg;
  ASSERT (SELECT x ->> 'skip' FROM jsonb_array_elements(sh -> 'tiers') x WHERE x ->> 'name' = 'Free') LIKE '%$0%', 'BY12: $0 shown as skipped';
  RAISE NOTICE 'BY12 PASS: the view';
END $$;
RESET ROLE;

-- More events for the review cases: e3 (network SeatGeek with history), e4 (clean).
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  (pg_temp.u('e3'),pg_temp.u('1'),'B4 Switch','published',now() + interval '60 days','Hall',257,0,ARRAY['seatgeek']),
  (pg_temp.u('e4'),pg_temp.u('1'),'B4 Clean','published',now() + interval '60 days','Hall',257,0,'{}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sort_order) VALUES
  (pg_temp.u('d5'),pg_temp.u('e3'),'GA',40,200,0,1),
  (pg_temp.u('d6'),pg_temp.u('e4'),'GA',40,200,0,1);

-- BY13 R1: no ticking a marketplace the organizer sells with their own account
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.st(format($q$UPDATE public.exos_events SET distribution_networks = ARRAY['seatgeek', 'stubhub'] WHERE id = %L$q$, pg_temp.u('e1')));
  ASSERT e LIKE '22023%StubHub is sold with your own seller account%', 'BY13: the tick is refused, got ' || e;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = pg_temp.u('e1') AND 'stubhub' = ANY (distribution_networks)), 'BY13: not ticked';
  -- A save that doesn't add one still goes through.
  UPDATE public.exos_events SET distribution_networks = distribution_networks WHERE id = pg_temp.u('e1');
  RAISE NOTICE 'BY13 PASS: no ticking an own-account marketplace';
END $$;

-- BY14 R2: only exos_byo_set_allocation; 0% gives it back when nothing happened
SELECT pg_temp.as_('authenticated', pg_temp.u('a0'));
DO $$
DECLARE e text; r jsonb;
BEGIN
  e := pg_temp.st(format('SELECT public.exos_set_channel_allocation(%L, %L, %L, 150)', pg_temp.u('e1'), 'stubhub', pg_temp.u('d1')));
  ASSERT e LIKE '42501%own seller account%', 'BY14: a direct allocation on an own channel is refused, got ' || e;
  ASSERT (SELECT sell_cap FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1') AND channel = 'stubhub' AND tier_id = pg_temp.u('d1')) = 2,
    'BY14: the share stands (1% = 2)';
  -- e4: own StubHub at 10%, back to 0% with nothing sold or sent: nobody's again.
  PERFORM public.exos_byo_set_allocation(pg_temp.u('e4'), 'stubhub', 10);
  r := public.exos_byo_set_allocation(pg_temp.u('e4'), 'stubhub', 0);
  ASSERT (r ->> 'removed')::boolean, 'BY14: removed ' || r;
  RESET ROLE;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_byo_allocations WHERE event_id = pg_temp.u('e4')), 'BY14: no own-account row';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e4') AND channel = 'stubhub'), 'BY14: its rows gone';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'event.byo_allocation'
                  AND event_id = pg_temp.u('e4') AND (changes ->> 'removed')::boolean), 'BY14: the removal is audited';
  -- And the network can be ticked for it again.
  UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub'] WHERE id = pg_temp.u('e4');
  UPDATE public.exos_events SET distribution_networks = '{}' WHERE id = pg_temp.u('e4');
  -- e1's StubHub sold 2: 0% is refused (BY8), so it stays the organizer's.
  ASSERT EXISTS (SELECT 1 FROM public.exos_byo_allocations WHERE event_id = pg_temp.u('e1') AND channel = 'stubhub'), 'BY14: e1 stays own';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a0'));
  RAISE NOTICE 'BY14 PASS: only the %% function allocates; 0%% gives an untouched marketplace back';
END $$;
RESET ROLE;

-- BY15 R3: an own-account sale is never Exos's to pay out
DO $$
DECLARE o uuid; e text; st text; n int;
BEGIN
  SELECT id INTO o FROM public.exos_marketplace_orders WHERE channel = 'stubhub' AND external_order_id = 'b4-1';
  ASSERT (SELECT account FROM public.exos_marketplace_orders WHERE id = o) = 'own', 'BY15: stamped own';
  e := pg_temp.st($q$SELECT public.exos_record_remittance('{"channel":"stubhub","external_id":"b4-rem-1","amount":"80.00","source":"manual","allocations":[{"external_order_id":"b4-1","amount":"80.00"}]}'::jsonb)$q$);
  ASSERT e LIKE '22023%own seller account%', 'BY15: no remittance covers it, got ' || e;
  SELECT state INTO st FROM public.exos_marketplace_order_money WHERE order_id = o;
  ASSERT st = 'own_account', 'BY15: state ' || coalesce(st, 'null');
  PERFORM public.exos_plan_org_payouts(pg_temp.u('1'));
  SELECT count(*) INTO n FROM public.exos_org_payout_lines WHERE order_id = o;
  ASSERT n = 0, 'BY15: never in a payout';
  RAISE NOTICE 'BY15 PASS: own-account money never through Exos''s payouts';
END $$;

-- BY16 R4: a network row is never reused; a touched one refuses the switch
DO $$
DECLARE old_id uuid; new_id uuid; e text;
BEGIN
  -- e3 SeatGeek on the network: set aside, then pulled back to 0 (untouched otherwise).
  PERFORM public.exos_set_channel_allocation(pg_temp.u('e3'), 'seatgeek', pg_temp.u('d5'), 10);
  SELECT id INTO old_id FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e3') AND channel = 'seatgeek' AND tier_id = pg_temp.u('d5');
  PERFORM public.exos_set_channel_allocation(pg_temp.u('e3'), 'seatgeek', pg_temp.u('d5'), 0);
  UPDATE public.exos_events SET distribution_networks = '{}' WHERE id = pg_temp.u('e3');
  -- A row the network synced once is the network's for good.
  UPDATE public.exos_distribution_listings SET last_synced_at = now() WHERE id = old_id;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a0'));
  e := pg_temp.st(format('SELECT public.exos_byo_set_allocation(%L, %L, 10)', pg_temp.u('e3'), 'seatgeek'));
  ASSERT e LIKE '22023%stays the network''s%', 'BY16: a touched network row refuses the switch, got ' || e;
  RESET ROLE;
  UPDATE public.exos_distribution_listings SET last_synced_at = NULL WHERE id = old_id;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a0'));
  PERFORM public.exos_byo_set_allocation(pg_temp.u('e3'), 'seatgeek', 10);
  RESET ROLE;
  SELECT id INTO new_id FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e3') AND channel = 'seatgeek' AND tier_id = pg_temp.u('d5');
  ASSERT new_id IS DISTINCT FROM old_id AND (SELECT account FROM public.exos_distribution_listings WHERE id = new_id) = 'own',
    'BY16: a new own row, new id';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings WHERE id = old_id), 'BY16: the untouched network row is gone';
  ASSERT left(pg_temp.st(format($q$UPDATE public.exos_distribution_listings SET account = 'platform' WHERE id = %L$q$, new_id)), 5) = '42501',
    'BY16: never flipped back';
  RAISE NOTICE 'BY16 PASS: rows never change account';
END $$;

-- BY17 an event edit keeps the organizer's own listings
DO $$
DECLARE d record;
BEGIN
  UPDATE public.exos_events SET name = 'B4 Big renamed', starts_at = starts_at + interval '1 day' WHERE id = pg_temp.u('e1');
  SELECT * INTO d FROM public.exos_distribution_listings WHERE event_id = pg_temp.u('e1') AND channel = 'stubhub' AND tier_id = pg_temp.u('d1');
  ASSERT d.sell_cap = 2 AND d.status <> 'delisted', 'BY17: own seats kept ' || row_to_json(d);
  RAISE NOTICE 'BY17 PASS: an edit doesn''t pull own-account seats';
END $$;

ROLLBACK;
