-- ============================================================================
-- Event import with link-out (mig 20261029170000).
--   I1 Eventbrite import: a published link-out event (backend, URL, primary,
--      door link); importing the same Eventbrite event again updates it,
--      never a second event, and leaves the organizer's edits alone
--   I2 validation: owner / manager only; a URL that isn't the platform's or
--      doesn't name the id; cancelled / over at the source; a pasted Luma or
--      Posh link is always a draft; Posh allowed by both CHECKs
--   I3 Exos sells nothing, on every SQL path: ticket types, cart holds,
--      vouchers (bypass included), free claims, comps, box office, mint,
--      direct ticket rows on any channel (stripe and marketplaces included),
--      channel mirrors, marketplaces / S4K; resale locked, never last call,
--      free tier for fees; the backend and link can't be changed by the
--      organizer, other fields can
--   I4 where to buy: the storefront view, the anon link-out view (published
--      only), the feed function, the S4K / partner feed leaves it out, the
--      calendar row's buy link; an Exos event and a sold-elsewhere event
--   I5 re-check: claim (due, leased, token), sold out, rescheduled
--      (previous start kept), cancelled (event cancelled, checks stop),
--      a stale lease writes nothing, read errors back off, Check now is
--      owner / manager only, a disconnected org, ended a day after the end
--   I6 grants and RLS
-- Self-contained (ab prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
DELETE FROM public.exos_platform_settings
 WHERE key IN ('free_tier_max_capacity', 'resale_consent_required', 'free_tier_fee_bps', 'last_call_threshold');

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('ab000000-0000-0000-0000-0000000000a0','ab-owner@x.com',now()),
  ('ab000000-0000-0000-0000-0000000000a1','ab-manager@x.com',now()),
  ('ab000000-0000-0000-0000-0000000000a3','ab-scanner@x.com',now()),
  ('ab000000-0000-0000-0000-0000000000a4','ab-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('ab000000-0000-0000-0000-000000000001','AB Org','ab-org','ab000000-0000-0000-0000-0000000000a0'),
  ('ab000000-0000-0000-0000-000000000002','AB Other','ab-other','ab000000-0000-0000-0000-0000000000a4');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('ab000000-0000-0000-0000-000000000001','ab000000-0000-0000-0000-0000000000a0','owner'),
  ('ab000000-0000-0000-0000-000000000001','ab000000-0000-0000-0000-0000000000a1','manager'),
  ('ab000000-0000-0000-0000-000000000001','ab000000-0000-0000-0000-0000000000a3','scanner'),
  ('ab000000-0000-0000-0000-000000000002','ab000000-0000-0000-0000-0000000000a4','owner');
-- An Exos-sold event and a sold-elsewhere (pretix) event, for I4.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold,timezone,created_by,ticket_backend,external_ticket_url) VALUES
  ('ab000000-0000-0000-0000-0000000000e1','ab000000-0000-0000-0000-000000000001','Own','ab-own','published',now() + interval '20 days','Hall',100,0,'America/New_York','ab000000-0000-0000-0000-0000000000a0','exos',NULL),
  ('ab000000-0000-0000-0000-0000000000e2','ab000000-0000-0000-0000-000000000001','Pretix','ab-pretix','published',now() + interval '20 days','Hall',100,0,'America/New_York','ab000000-0000-0000-0000-0000000000a0','pretix','https://pretix.eu/ab/show/');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
  ('ab000000-0000-0000-0000-0000000000d1','ab000000-0000-0000-0000-0000000000e1','GA',20,100,0,'public',1);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"ab@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('ab000000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.org() RETURNS uuid LANGUAGE sql AS $$ SELECT 'ab000000-0000-0000-0000-000000000001'::uuid $$;
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
-- What exos-event-import hands the RPC for Eventbrite event 4400001.
CREATE FUNCTION pg_temp.eb_data(p_name text, p_min numeric, p_status text DEFAULT 'on_sale') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'source_event_id', '4400001', 'source_url', 'https://www.eventbrite.com/e/ab-night-tickets-4400001',
    'source_status', p_status, 'name', p_name, 'summary', 'A night out', 'description', 'Long text',
    'starts_at', (now() + interval '30 days')::text, 'ends_at', (now() + interval '30 days 4 hours')::text,
    'timezone', 'America/New_York', 'venue_name', 'Brooklyn Hall',
    'venue_address', jsonb_build_object('street', '1 Main St', 'city', 'Brooklyn', 'region', 'NY', 'postal', '11201', 'country', 'US', 'junk', 'x'),
    'image_url', 'https://img.evbuc.com/ab.jpg', 'category', 'Music', 'currency', 'usd',
    'price_min', p_min, 'price_max', 45, 'is_free', false,
    'ticket_types', jsonb_build_array(
      jsonb_build_object('name', 'Early', 'min_price', p_min, 'max_price', p_min, 'sold_out', true, 'hack', 1),
      jsonb_build_object('name', 'GA', 'min_price', 45, 'max_price', 45, 'sold_out', false)),
    'publish', true)
$$;
CREATE FUNCTION pg_temp.ev() RETURNS uuid LANGUAGE sql AS $$
  SELECT event_id FROM public.exos_event_imports WHERE platform = 'eventbrite' AND source_event_id = '4400001'
$$;

-- I1. Eventbrite import.
DO $$
DECLARE r jsonb; r2 jsonb; e public.exos_events%ROWTYPE; i public.exos_event_imports%ROWTYPE;
BEGIN
  PERFORM public.exos_eventbrite_connect(pg_temp.org(), pg_temp.u('a0'), 'TOKENAB000001', 'AB Room');
  r := public.exos_link_out_import(pg_temp.org(), pg_temp.u('a1'), 'eventbrite', 'account', pg_temp.eb_data('AB Night', 25));
  ASSERT (r ->> 'created')::boolean AND r ->> 'status' = 'published' AND (r ->> 'linked_door')::boolean, 'I1: created ' || r::text;
  SELECT * INTO e FROM public.exos_events WHERE id = (r ->> 'event_id')::uuid;
  SELECT * INTO i FROM public.exos_event_imports WHERE event_id = e.id;
  ASSERT e.link_out AND e.ticket_backend = 'eventbrite' AND e.primary_source = 'eventbrite'
     AND e.external_ticket_url = 'https://www.eventbrite.com/e/ab-night-tickets-4400001', 'I1: the mode ' || row_to_json(e)::text;
  ASSERT e.name = 'AB Night' AND e.timezone = 'America/New_York' AND e.venue_name = 'Brooklyn Hall'
     AND e.venue_address ->> 'city' = 'Brooklyn' AND NOT (e.venue_address ? 'junk') AND e.currency = 'usd'
     AND e.image_url = 'https://img.evbuc.com/ab.jpg' AND e.summary = 'A night out' AND e.total_tickets = 0, 'I1: the details';
  ASSERT i.price_min = 25 AND i.price_max = 45 AND i.currency = 'USD' AND i.checks_enabled AND i.origin = 'account'
     AND i.source_status = 'on_sale' AND i.next_check_at > now(), 'I1: the source row';
  ASSERT jsonb_array_length(i.ticket_types) = 2 AND NOT (i.ticket_types -> 0 ? 'hack')
     AND (i.ticket_types -> 0 ->> 'sold_out')::boolean, 'I1: display-only types ' || i.ticket_types::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE event_id = e.id), 'I1: no Exos ticket types';
  ASSERT (SELECT eb_event_id FROM public.exos_eventbrite_links WHERE event_id = e.id) = '4400001', 'I1: the door syncs its attendees';

  -- The organizer renames it; the same Eventbrite event comes in again with a new price.
  UPDATE public.exos_events SET name = 'AB Night (renamed)' WHERE id = e.id;
  r2 := public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'eventbrite', 'account', pg_temp.eb_data('Eventbrite name', 30));
  ASSERT NOT (r2 ->> 'created')::boolean AND r2 ->> 'event_id' = r ->> 'event_id', 'I1: idempotent ' || r2::text;
  ASSERT (SELECT count(*) FROM public.exos_event_imports WHERE org_id = pg_temp.org() AND source_event_id = '4400001') = 1, 'I1: one row';
  ASSERT (SELECT count(*) FROM public.exos_events WHERE org_id = pg_temp.org() AND link_out) = 1, 'I1: one event';
  ASSERT (SELECT name FROM public.exos_events WHERE id = e.id) = 'AB Night (renamed)', 'I1: organizer edits kept';
  ASSERT (SELECT price_min FROM public.exos_event_imports WHERE event_id = e.id) = 30, 'I1: source fields refreshed';
  -- Another org may import the same Eventbrite id (their own account): a separate event.
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_imports WHERE org_id <> pg_temp.org()), 'I1: per org';
  RAISE NOTICE 'OK  I1 Eventbrite import, idempotent';
END $$;

-- I2. Validation.
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a3'), 'eventbrite', 'account', pg_temp.eb_data('x', 1))$q$,
                         'owner or manager only'), 'I2: scanner';
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a4'), 'eventbrite', 'account', pg_temp.eb_data('x', 1))$q$,
                         'owner or manager only'), 'I2: another org''s owner';
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'eventbrite', 'account',
                            pg_temp.eb_data('x', 1) || '{"source_url": "https://evil.example.com/e/x-4400001"}')$q$, 'isn''t a'), 'I2: foreign host';
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'eventbrite', 'account',
                            pg_temp.eb_data('x', 1) || '{"source_url": "https://www.eventbrite.com/e/other-tickets-4400002"}')$q$, 'isn''t a'), 'I2: URL names another id';
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'luma', 'link',
                            '{"source_event_id": "4400001", "source_url": "https://www.eventbrite.com/e/x-4400001", "name": "x"}')$q$, 'isn''t a'), 'I2: platform mismatch';
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'luma', 'account',
                            '{"source_event_id": "ab-party", "source_url": "https://lu.ma/ab-party", "name": "x"}')$q$, 'bad origin'), 'I2: no Luma account import yet';
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'dice', 'link', '{}')$q$, 'Eventbrite, Luma or Posh'), 'I2: platform';
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'eventbrite', 'account',
                            pg_temp.eb_data('x', 1, 'cancelled') || '{"source_event_id": "4400009", "source_url": "https://www.eventbrite.com/e/x-tickets-4400009"}')$q$,
                         'cancelled'), 'I2: cancelled at the source';
  -- Pasted Luma / Posh links: drafts, even when asked to publish.
  r := public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'luma', 'link',
         jsonb_build_object('source_event_id', 'ab-party', 'source_url', 'https://lu.ma/ab-party', 'name', 'AB Party',
                            'starts_at', (now() + interval '9 days')::text, 'price_min', 10, 'price_max', 10, 'currency', 'USD', 'publish', true));
  ASSERT r ->> 'status' = 'draft' AND NOT (r ->> 'linked_door')::boolean, 'I2: Luma draft ' || r::text;
  ASSERT NOT (SELECT checks_enabled FROM public.exos_event_imports WHERE event_id = (r ->> 'event_id')::uuid), 'I2: Luma not re-checked';
  r := public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'posh', 'link',
         jsonb_build_object('source_event_id', 'ab-rave', 'source_url', 'https://posh.vip/e/ab-rave', 'name', 'AB Rave', 'publish', true));
  ASSERT r ->> 'status' = 'draft', 'I2: Posh draft';
  ASSERT (SELECT ticket_backend = 'posh' AND primary_source = 'posh' FROM public.exos_events WHERE id = (r ->> 'event_id')::uuid), 'I2: Posh allowed';
  ASSERT pg_temp.refused($q$SELECT public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'posh', 'link',
                            '{"source_event_id": "ab-rave2", "source_url": "https://posh.vip/e/ab-rave2"}')$q$, 'give the event a name'), 'I2: a name';
  RAISE NOTICE 'OK  I2 validation; pasted Luma / Posh links are drafts';
END $$;

-- I3. Exos sells nothing.
DO $$
DECLARE v_e uuid := pg_temp.ev(); v_t uuid := gen_random_uuid(); v_n int; v_ok boolean;
BEGIN
  ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_ticket_tiers(event_id,name,price,capacity,sold,visibility) VALUES (%L,'GA',10,50,0,'public')$q$, v_e),
                         'Exos sells nothing'), 'I3: no ticket types';
  -- Even if a ticket type got in, nothing sells it.
  ALTER TABLE public.exos_ticket_tiers DISABLE TRIGGER exos_ticket_tiers_link_out;
  INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES (v_t, v_e, 'Sneaked', 0, 50, 0, 'public');
  ALTER TABLE public.exos_ticket_tiers ENABLE TRIGGER exos_ticket_tiers_link_out;

  ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_cart_holds(event_id, tier_id, org_id, buyer_uid, quantity, expires_at)
                                   VALUES (%L, %L, pg_temp.org(), pg_temp.u('a4'), 1, now() + interval '10 minutes')$q$, v_e, v_t), ''), 'I3: cart hold';
  ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity) VALUES (%L, 'ABBYPASS', %L, 5, true)$q$, v_e, v_t),
                         'Exos sells nothing'), 'I3: a bypass voucher';
  FOREACH v_n IN ARRAY ARRAY[1] LOOP
    ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source)
                                     VALUES (%L, pg_temp.org(), %L, 'x', 'v@x.com', 'active', 'ab-x1', 0, 'ABBYPASS', 'vibepass')$q$, v_e, v_t), ''), 'I3: a voucher mint';
    ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source)
                                     VALUES (%L, pg_temp.org(), %L, 'x', 's@x.com', 'active', 'ab-x2', 10, 'cs_ab', 'stripe')$q$, v_e, v_t), 'Exos sells nothing'), 'I3: a Stripe fulfilment';
    ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source)
                                     VALUES (%L, pg_temp.org(), %L, 'x', 'm@x.com', 'active', 'ab-x3', 10, 'sh-ab', 'stubhub')$q$, v_e, v_t), 'Exos sells nothing'), 'I3: a marketplace sale';
  END LOOP;
  PERFORM pg_temp.act('ab000000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.refused(format($q$SELECT public.exos_claim_free_tickets(%L, %L, 1, NULL, NULL, NULL)$q$, v_e, v_t), ''), 'I3: a free claim';
  PERFORM pg_temp.act('ab000000-0000-0000-0000-0000000000a0');
  BEGIN
    PERFORM public.exos_issue_comp_batch(v_e, v_t, ARRAY['comp@x.com'], 1);
  EXCEPTION WHEN others THEN NULL;
  END;
  ASSERT pg_temp.refused(format($q$SELECT public.exos_issue_ticket_to_email(%L, %L, 'door@x.com', 1, 'ab-bo-1')$q$, v_e, v_t), ''), 'I3: box office';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_mint_tickets(%L, %L, 1)$q$, v_e, v_t), ''), 'I3: mint';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_set_resale_consent(%L, true, '2026-10-29')$q$, v_e), ''), 'I3: resale opt-in';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_set_ticket_backend(%L, 'exos', NULL)$q$, v_e), 're-import'), 'I3: backend back to Exos';
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE event_id = v_e) = 0, 'I3: no ticket at all';
  ASSERT pg_temp.refused(format($q$INSERT INTO public.exos_channel_mirrors (event_id, provider, org_id, mode) VALUES (%L, 'eventbrite', pg_temp.org(), 'link')$q$, v_e),
                         'Exos sells nothing'), 'I3: no mirror back to the source';
  ASSERT pg_temp.refused(format($q$UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub'] WHERE id = %L$q$, v_e), 'no marketplaces'), 'I3: marketplaces';
  ASSERT pg_temp.refused(format($q$UPDATE public.exos_events SET distribution_route = 's4k' WHERE id = %L$q$, v_e), 'no marketplaces'), 'I3: S4K';
  -- Big at the source: still the free tier for fees, never resold, never last call.
  UPDATE public.exos_events SET total_tickets = 5000 WHERE id = v_e;
  ASSERT public.exos_event_is_free_tier(v_e) AND public.exos_event_fee_bps(v_e, now()) = 0, 'I3: free tier';
  ASSERT (public.exos_event_fee_terms(v_e, NULL, 1) ->> 'free_tier')::boolean, 'I3: checkout''s fee terms';
  ASSERT NOT public.exos_resale_unlocked(v_e) AND NOT public.exos_event_last_call(v_e), 'I3: no resale, no last call';
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('resale_consent_required', 'false');
  ASSERT NOT public.exos_resale_unlocked(v_e), 'I3: no resale even without the opt-in rule';
  DELETE FROM public.exos_platform_settings WHERE key = 'resale_consent_required';
  ALTER TABLE public.exos_ticket_tiers DISABLE TRIGGER USER;
  DELETE FROM public.exos_ticket_tiers WHERE id = v_t;
  ALTER TABLE public.exos_ticket_tiers ENABLE TRIGGER USER;
  -- The ordinary Exos event is unaffected.
  ASSERT NOT public.exos_event_is_link_out(pg_temp.u('e1')), 'I3: Exos event';
  RAISE NOTICE 'OK  I3 every SQL sell path refuses a link-out event';
END $$;

-- I3b. As the signed-in organizer (RLS client): the sale's link is locked,
-- the rest of the page isn't; nobody creates a link-out event directly.
-- The harness's grants and policies keep a client off these columns anyway
-- (prod's column grants too); open the table in this rolled-back
-- transaction so the trigger itself is what refuses.
GRANT SELECT, INSERT, UPDATE ON public.exos_events TO authenticated;
CREATE POLICY ab_tmp_open ON public.exos_events FOR ALL TO authenticated USING (true) WITH CHECK (true);
DO $$ BEGIN PERFORM pg_temp.act('ab000000-0000-0000-0000-0000000000a0'); END $$;
SET ROLE authenticated;
DO $$
DECLARE v_e uuid := (SELECT event_id FROM public.exos_event_imports WHERE source_event_id = '4400001');
BEGIN
  UPDATE public.exos_events SET summary = 'Edited' WHERE id = v_e;
  ASSERT (SELECT summary FROM public.exos_events WHERE id = v_e) = 'Edited', 'I3b: the page is editable';
  ASSERT pg_temp.refused(format($q$UPDATE public.exos_events SET external_ticket_url = 'https://evil.example.com/x' WHERE id = %L$q$, v_e), 'set by the import'), 'I3b: the link';
  ASSERT pg_temp.refused(format($q$UPDATE public.exos_events SET link_out = false WHERE id = %L$q$, v_e), 'set by the import'), 'I3b: the mode';
  ASSERT pg_temp.refused(format($q$UPDATE public.exos_events SET ticket_backend = 'exos' WHERE id = %L$q$, v_e), 'set by the import'), 'I3b: the backend';
  ASSERT pg_temp.refused($q$INSERT INTO public.exos_events (org_id, name, status, link_out, ticket_backend, external_ticket_url)
                           VALUES (pg_temp.org(), 'x', 'draft', true, 'eventbrite', 'https://www.eventbrite.com/e/1')$q$, 'created by importing'), 'I3b: no direct link-out';
END $$;
RESET ROLE;
DO $$ BEGIN PERFORM pg_temp.act(NULL); RAISE NOTICE 'OK  I3b the organizer can''t move the sale'; END $$;

-- I4. Where to buy.
DO $$
DECLARE v_e uuid := pg_temp.ev(); s record; w record; v_cal jsonb;
BEGIN
  SELECT * INTO s FROM public.exos_public_event_sales WHERE event_id = v_e;
  ASSERT NOT s.last_call AND s.sells_on = 'eventbrite' AND s.sells_on_url = 'https://www.eventbrite.com/e/ab-night-tickets-4400001', 'I4: storefront ' || row_to_json(s)::text;
  SELECT * INTO s FROM public.exos_public_event_sales WHERE event_id = pg_temp.u('e1');
  ASSERT s.sells_on = 'exos' AND s.sells_on_url IS NULL, 'I4: an Exos event sells on Exos';
  SELECT * INTO s FROM public.exos_public_event_sales WHERE event_id = pg_temp.u('e2');
  ASSERT s.sells_on = 'pretix' AND s.sells_on_url = 'https://pretix.eu/ab/show/', 'I4: a sold-elsewhere event';

  SELECT * INTO w FROM public.exos_feed_where_to_buy(ARRAY[v_e, pg_temp.u('e1')]) WHERE event_id = v_e;
  ASSERT w.link_out AND w.sells_on = 'eventbrite' AND w.price_min = 30 AND w.source_status = 'on_sale'
     AND jsonb_array_length(w.ticket_types) = 2, 'I4: feed function ' || row_to_json(w)::text;
  ASSERT (SELECT NOT link_out AND sells_on = 'exos' FROM public.exos_feed_where_to_buy(ARRAY[pg_temp.u('e1')])), 'I4: feed, Exos event';

  -- The S4K / partner feed leaves it out (and so does the marketplace path).
  UPDATE public.exos_orgs SET s4k_network = true WHERE id = pg_temp.org();
  ASSERT NOT public._exos_feed_eligible(v_e), 'I4: not partner-feed eligible';

  v_cal := public.exos_calendar_event_rows(ARRAY[v_e, pg_temp.u('e1')]);
  ASSERT (SELECT x ->> 'buy_url' FROM jsonb_array_elements(v_cal) x WHERE x ->> 'id' = v_e::text) = 'https://www.eventbrite.com/e/ab-night-tickets-4400001'
     AND (SELECT x ->> 'buy_on' FROM jsonb_array_elements(v_cal) x WHERE x ->> 'id' = v_e::text) = 'eventbrite', 'I4: calendar ' || v_cal::text;
  ASSERT (SELECT x ->> 'buy_url' FROM jsonb_array_elements(v_cal) x WHERE x ->> 'id' = pg_temp.u('e1')::text) IS NULL, 'I4: calendar, Exos event';
  RAISE NOTICE 'OK  I4 where to buy: storefront, feeds, calendar';
END $$;
-- The anon view: published link-out events only.
SET ROLE anon;
DO $$
DECLARE n int; r record;
BEGIN
  SELECT count(*) INTO n FROM public.exos_public_link_outs;
  ASSERT n = 1, 'I4: anon sees the one published link-out (not the drafts): ' || n;
  SELECT * INTO r FROM public.exos_public_link_outs;
  ASSERT r.platform = 'eventbrite' AND r.price_min = 30 AND r.price_max = 45 AND r.currency = 'USD' AND r.source_status = 'on_sale', 'I4: anon row';
  ASSERT pg_temp.refused('SELECT 1 FROM public.exos_event_imports', 'permission denied'), 'I4: anon can''t read the table';
END $$;
RESET ROLE;

-- I5. Re-check.
DO $$
DECLARE v_e uuid := pg_temp.ev(); c record; r jsonb; v_start timestamptz; v_lease uuid;
BEGIN
  UPDATE public.exos_event_imports SET next_check_at = now() - interval '1 minute' WHERE event_id = v_e;
  SELECT * INTO c FROM public.exos_link_out_check_claim(20) WHERE event_id = v_e;
  ASSERT c.token = 'TOKENAB000001' AND c.source_event_id = '4400001' AND c.lease_id IS NOT NULL, 'I5: claimed';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_link_out_check_claim(20) WHERE event_id = v_e), 'I5: leased, not claimed twice';
  ASSERT (public.exos_link_out_check_apply(v_e, gen_random_uuid(), '{"source_status": "cancelled"}') ->> 'reason') = 'lease-lost', 'I5: stale lease';
  ASSERT (SELECT status FROM public.exos_events WHERE id = v_e) = 'published', 'I5: stale lease wrote nothing';

  -- Sold out, and moved a day later.
  SELECT starts_at INTO v_start FROM public.exos_events WHERE id = v_e;
  r := public.exos_link_out_check_apply(v_e, c.lease_id, jsonb_build_object('source_status', 'sold_out',
         'starts_at', (v_start + interval '1 day')::text, 'ends_at', (v_start + interval '1 day 4 hours')::text,
         'price_min', 30, 'price_max', 45, 'currency', 'USD',
         'ticket_types', jsonb_build_array(jsonb_build_object('name', 'GA', 'min_price', 45, 'max_price', 45, 'sold_out', true))));
  ASSERT (r ->> 'rescheduled')::boolean AND r ->> 'status' = 'sold_out', 'I5: applied ' || r::text;
  ASSERT (SELECT starts_at FROM public.exos_events WHERE id = v_e) = v_start + interval '1 day', 'I5: the event moved';
  ASSERT (SELECT previous_starts_at = v_start AND rescheduled_at IS NOT NULL AND source_status = 'sold_out'
                 AND jsonb_array_length(ticket_types) = 1 AND lease_id IS NULL AND next_check_at > now()
            FROM public.exos_event_imports WHERE event_id = v_e), 'I5: the source row';
  ASSERT (SELECT source_status FROM public.exos_public_link_outs WHERE event_id = v_e) = 'sold_out', 'I5: storefront sees sold out';

  -- Check now: owner / manager, at most once a minute.
  ASSERT pg_temp.refused(format($q$SELECT * FROM public.exos_link_out_check_claim(1, %L, pg_temp.u('a3'))$q$, v_e), 'owner or manager only'), 'I5: scanner';
  ASSERT pg_temp.refused(format($q$SELECT * FROM public.exos_link_out_check_claim(1, %L, pg_temp.u('a4'))$q$, v_e), 'owner or manager only'), 'I5: stranger';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_link_out_check_claim(1, v_e, pg_temp.u('a1'))), 'I5: just checked';
  UPDATE public.exos_event_imports SET last_checked_at = now() - interval '2 minutes' WHERE event_id = v_e;
  SELECT * INTO c FROM public.exos_link_out_check_claim(1, v_e, pg_temp.u('a1'));
  ASSERT c.lease_id IS NOT NULL, 'I5: Check now';

  -- A failed read backs off and keeps the status.
  r := public.exos_link_out_check_apply(v_e, c.lease_id, NULL, 'Eventbrite didn''t answer; the next sync will retry.');
  ASSERT (SELECT check_errors = 1 AND source_status = 'sold_out' AND next_check_at > now() + interval '20 minutes' AND last_error LIKE 'Eventbrite%'
            FROM public.exos_event_imports WHERE event_id = v_e), 'I5: backoff';

  -- Cancelled at the source: the Exos event is cancelled and the checks stop.
  UPDATE public.exos_event_imports SET next_check_at = now() - interval '1 minute' WHERE event_id = v_e;
  SELECT lease_id INTO v_lease FROM public.exos_link_out_check_claim(20) WHERE event_id = v_e;
  r := public.exos_link_out_check_apply(v_e, v_lease, '{"source_status": "cancelled"}');
  ASSERT (r ->> 'cancelled')::boolean, 'I5: cancelled ' || r::text;
  ASSERT (SELECT status FROM public.exos_events WHERE id = v_e) = 'cancelled', 'I5: the Exos event is cancelled';
  ASSERT (SELECT next_check_at IS NULL FROM public.exos_event_imports WHERE event_id = v_e), 'I5: no more checks';
  UPDATE public.exos_event_imports SET next_check_at = now() - interval '1 minute' WHERE event_id = v_e;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_link_out_check_claim(20) WHERE event_id = v_e), 'I5: never claimed again';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_link_outs WHERE event_id = v_e)
     AND NOT EXISTS (SELECT 1 FROM public.exos_public_event_sales WHERE event_id = v_e), 'I5: off the public views';
  ASSERT public.exos_calendar_public_feed('org', 'ab-org') -> 'events' @> '[]'::jsonb
     AND NOT (public.exos_calendar_public_feed('org', 'ab-org')::text LIKE '%' || v_e::text || '%'), 'I5: off the org calendar';
  RAISE NOTICE 'OK  I5 re-check: sold out, rescheduled, cancelled, leases, backoff';
END $$;

-- I5b. A second import: a disconnected org records an error; an event a day
-- past its end is marked ended without a read.
DO $$
DECLARE r jsonb; v_e uuid;
BEGIN
  r := public.exos_link_out_import(pg_temp.org(), pg_temp.u('a0'), 'eventbrite', 'link',
         pg_temp.eb_data('Second', 15) || '{"source_event_id": "4400002", "source_url": "https://www.eventbrite.co.uk/e/second-tickets-4400002"}');
  v_e := (r ->> 'event_id')::uuid;
  PERFORM public.exos_eventbrite_disconnect(pg_temp.org(), pg_temp.u('a0'));
  UPDATE public.exos_event_imports SET next_check_at = now() - interval '1 minute' WHERE event_id = v_e;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_link_out_check_claim(20) WHERE event_id = v_e), 'I5b: no token, no claim';
  ASSERT (SELECT check_errors = 1 AND last_error LIKE '%isn''t connected%' AND next_check_at > now() + interval '23 hours'
            FROM public.exos_event_imports WHERE event_id = v_e), 'I5b: recorded';
  UPDATE public.exos_events SET starts_at = now() - interval '3 days', ends_at = now() - interval '3 days' + interval '3 hours' WHERE id = v_e;
  PERFORM * FROM public.exos_link_out_check_claim(20);
  ASSERT (SELECT source_status FROM public.exos_event_imports WHERE event_id = v_e) = 'ended', 'I5b: ended';
  RAISE NOTICE 'OK  I5b disconnected org, ended';
END $$;

-- I6. Grants and RLS.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_event_is_link_out(uuid)', 'public.exos_event_buy_link(uuid)',
                           'public.exos_feed_where_to_buy(uuid[])', 'public._exos_link_out_url_ok(text, text, text)',
                           'public._exos_link_out_slug(text)', 'public._exos_link_out_types(jsonb)',
                           'public._exos_link_out_next_check(timestamp with time zone, integer)',
                           'public._exos_eventbrite_org_token(uuid)',
                           'public.exos_link_out_import(uuid, uuid, text, text, jsonb)',
                           'public.exos_link_out_check_claim(integer, uuid, uuid)',
                           'public.exos_link_out_check_apply(uuid, uuid, jsonb, text)',
                           'public.exos_tg_event_link_out_guard()', 'public.exos_tg_link_out_refuse()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'I6: service only ' || f;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_public_link_out(uuid)', 'EXECUTE'), 'I6: the view''s function';
  ASSERT has_table_privilege('anon', 'public.exos_public_link_outs', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_public_link_outs', 'INSERT'), 'I6: the anon view';
  ASSERT NOT has_table_privilege('anon', 'public.exos_event_imports', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_event_imports', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_event_imports', 'UPDATE'), 'I6: table grants';
END $$;
DO $$ BEGIN PERFORM pg_temp.act('ab000000-0000-0000-0000-0000000000a1'); END $$;
SET ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_imports) >= 3, 'I6: the manager reads the org''s imports';
END $$;
RESET ROLE;
DO $$ BEGIN PERFORM pg_temp.act('ab000000-0000-0000-0000-0000000000a4'); END $$;
SET ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_imports) = 0, 'I6: another org sees none';
END $$;
RESET ROLE;
DO $$ BEGIN PERFORM pg_temp.act(NULL); RAISE NOTICE 'OK  I6 grants and RLS'; END $$;

\echo 'test_event_import: all passed'
ROLLBACK;
