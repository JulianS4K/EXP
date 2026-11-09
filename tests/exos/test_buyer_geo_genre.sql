-- ============================================================================
-- Buyer location + genre filter (mig 20261106140000). Self-contained (b9e…
-- ids), rolled back.
--   BG0 shape: no street column; RLS on; clients read only; the recorder and
--       the internal readers are service-role only; the dashboard reports are
--       signed-in only; search_path pinned
--   BG1 recording: values cleaned, first location wins, free / unpaid /
--       unknown orders skipped, a bad postal code dropped, an unknown source
--       refused
--   BG2 RLS: owner and finance read their org's rows only; a scanner and an
--       outsider read none; a buyer reads their own order's row only; anon
--       has no grant
--   BG3 the report sums: per country, per city, unknown (free + unlocated),
--       other tickets (no checkout), refunded counted, pending and the other
--       org's orders not; the org rollup, since and limit
--   BG4 report access: owner / finance yes; scanner, outsider, the other
--       org's owner 42501; anon no grant
--   BG5 account deletion clears the caller's locations (own sessions and
--       guest orders under the confirmed email), keeps everyone else's, and a
--       late webhook can't put one back; an unconfirmed account sharing the
--       email erases nothing keyed by email
--   BG6 genres for the organizer API: the key, ids by genre (any status, any
--       case, one org), the genres in use
--   BG7 public discovery: the genre filter returns only matching published,
--       listed, upcoming events (no draft, no noindex, no past, no other
--       org's when filtered); genres.list leaks no draft / noindex / past
--       genre; bad filters 22023; search drops noindex; anon through
--       exos_api_public
--   BG8 every patch marker is in place
-- Users: oa owner A, fa finance A, sa scanner A, ob owner B, x1 outsider,
--        b1 / b2 buyers (confirmed), u1 unconfirmed (shares the guest email).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Prod's read rule on checkout sessions (mig 20260523170000; the chain's stub
-- table has none): the buyer's own, and the org's owner / manager / finance.
ALTER TABLE public.exos_checkout_sessions ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'exos_checkout_sel'
                   AND polrelid = 'public.exos_checkout_sessions'::regclass) THEN
    CREATE POLICY exos_checkout_sel ON public.exos_checkout_sessions FOR SELECT TO authenticated
      USING (buyer_uid = auth.uid() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
  END IF;
END $$;
REVOKE ALL ON public.exos_checkout_sessions FROM anon, authenticated;
GRANT SELECT ON public.exos_checkout_sessions TO authenticated;

-- The test chain lacks some of prod's tables exos_delete_my_account touches.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS phone text, ADD COLUMN IF NOT EXISTS raw_user_meta_data jsonb,
  ADD COLUMN IF NOT EXISTS banned_until timestamptz, ADD COLUMN IF NOT EXISTS updated_at timestamptz;
CREATE TABLE IF NOT EXISTS auth.identities (user_id uuid);
CREATE TABLE IF NOT EXISTS auth.sessions (user_id uuid);
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (user_id text);
CREATE TABLE IF NOT EXISTS public.exos_org_invites (email text, claimed_by uuid);
CREATE TABLE IF NOT EXISTS public.exos_org_follows (follower_uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_event_saves (user_id uuid);
CREATE TABLE IF NOT EXISTS public.exos_notification_reads (uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid);

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('b9e00000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true);
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
CREATE FUNCTION pg_temp.rec(p_sid text, p_country text, p_region text, p_city text, p_postal text,
                            p_source text DEFAULT 'stripe_billing') RETURNS text LANGUAGE sql AS $$
  SELECT public.exos_record_order_location(p_sid, p_country, p_region, p_city, p_postal, p_source)
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'b9e-oa@x.com', now()),
  (pg_temp.u('a2'), 'b9e-fa@x.com', now()),
  (pg_temp.u('a3'), 'b9e-sa@x.com', now()),
  (pg_temp.u('a4'), 'b9e-ob@x.com', now()),
  (pg_temp.u('a5'), 'b9e-x1@x.com', now()),
  (pg_temp.u('b1'), 'b9e-b1@x.com', now()),
  (pg_temp.u('b2'), 'b9e-b2@x.com', now()),
  (pg_temp.u('b3'), 'B9E-Guest@x.com', NULL);
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'B9E Hall', 'b9e-hall', pg_temp.u('a1')),
  (pg_temp.u('2'), 'B9E Other', 'b9e-other', pg_temp.u('a4'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('a1'), 'owner'),
  (pg_temp.u('1'), pg_temp.u('a2'), 'finance'),
  (pg_temp.u('1'), pg_temp.u('a3'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('a4'), 'owner');
-- Org A: e1 (published, house + techno), e2 (published, past, house),
-- e3 (draft, house), e4 (published but noindex, house), e5 (published, Jazz).
-- Org B: e9 (published, house).
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, ends_at, total_tickets, created_by, genres, noindex) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'B9E Warehouse', 'b9e-warehouse', 'published', now() + interval '10 days', NULL, 500, pg_temp.u('a1'),
   ARRAY['House', ' Techno '], false),
  (pg_temp.u('e2'), pg_temp.u('1'), 'B9E Last Year', 'b9e-last-year', 'published', now() - interval '30 days', now() - interval '29 days', 500,
   pg_temp.u('a1'), ARRAY['house'], false),
  (pg_temp.u('e3'), pg_temp.u('1'), 'B9E Draft', 'b9e-draft', 'draft', now() + interval '20 days', NULL, 500, pg_temp.u('a1'),
   ARRAY['HOUSE', 'Secret Genre'], false),
  (pg_temp.u('e4'), pg_temp.u('1'), 'B9E Private', 'b9e-private', 'published', now() + interval '12 days', NULL, 500, pg_temp.u('a1'),
   ARRAY['House', 'Hidden Genre'], true),
  (pg_temp.u('e5'), pg_temp.u('1'), 'B9E Jazz Night', 'b9e-jazz', 'published', now() + interval '15 days', NULL, 500, pg_temp.u('a1'),
   ARRAY['Jazz'], false),
  (pg_temp.u('e9'), pg_temp.u('2'), 'B9E Elsewhere', 'b9e-elsewhere', 'published', now() + interval '11 days', NULL, 500, pg_temp.u('a4'),
   ARRAY['house'], false);

-- Orders. e1: s1 b1 2 x $20 (US, New York), s2 b2 1 x $20 (US, New York),
-- s3 b2 1 x $25 (US, Brooklyn), s4 guest under b3's address 1 x $30 (GB,
-- London), s5 free (no location), s6 paid but never located, s7 refunded
-- (US, New York, counted), s8 pending (not counted), s9 partially refunded
-- (CA, no city). e5: s10 b1 1 x $40 (GB, London). Org B: s20 (US, New York).
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents, currency, status) VALUES
  ('cs_b9e1', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b1'), 'b9e-b1@x.com', false, 2, 4000, 'usd', 'fulfilled'),
  ('cs_b9e2', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), 'b9e-b2@x.com', false, 1, 2000, 'usd', 'fulfilled'),
  ('cs_b9e3', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), 'b9e-b2@x.com', false, 1, 2500, 'usd', 'fulfilled'),
  ('cs_b9e4', pg_temp.u('e1'), pg_temp.u('1'), NULL, 'b9e-guest@x.com', true, 1, 3000, 'usd', 'fulfilled'),
  ('cs_b9e5', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b1'), 'b9e-b1@x.com', false, 1, 0, 'usd', 'fulfilled'),
  ('cs_b9e6', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), 'b9e-b2@x.com', false, 1, 2000, 'usd', 'fulfilled'),
  ('cs_b9e7', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), 'b9e-b2@x.com', false, 1, 2000, 'usd', 'refunded'),
  ('cs_b9e8', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), 'b9e-b2@x.com', false, 3, 6000, 'usd', 'pending'),
  ('cs_b9e9', pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), 'b9e-b2@x.com', false, 1, 1500, 'usd', 'partially_refunded'),
  ('cs_b9e10', pg_temp.u('e5'), pg_temp.u('1'), pg_temp.u('b1'), 'b9e-b1@x.com', false, 1, 4000, 'usd', 'fulfilled'),
  ('cs_b9e20', pg_temp.u('e9'), pg_temp.u('2'), pg_temp.u('b1'), 'b9e-b1@x.com', false, 1, 9900, 'usd', 'fulfilled');
UPDATE public.exos_checkout_sessions SET created_at = now() - interval '40 days' WHERE session_id = 'cs_b9e10';

-- Two RSVP tickets on e1 that came from no checkout, and one voided one.
SET LOCAL session_replication_role = replica;
INSERT INTO public.exos_tickets (id, event_id, org_id, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref) VALUES
  (pg_temp.u('101'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b1'), pg_temp.u('b1'), 'active', 's1', 0, 'rsvp_b9e_1'),
  (pg_temp.u('102'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), pg_temp.u('b2'), 'used', 's2', 0, NULL),
  (pg_temp.u('103'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b2'), pg_temp.u('b2'), 'voided', 's3', 0, NULL),
  (pg_temp.u('104'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('b1'), pg_temp.u('b1'), 'active', 's4', 20, 'cs_b9e1');
SET LOCAL session_replication_role = origin;

-- BG0 -------------------------------------------------------------------------
DO $$
DECLARE cols text; f text;
BEGIN
  SELECT string_agg(column_name, ',' ORDER BY column_name) INTO cols
    FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'exos_order_locations';
  ASSERT cols = 'city,country,created_at,event_id,org_id,postal_code,region,session_id,source,updated_at',
    'BG0 columns (no street): ' || cols;
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_order_locations'::regclass), 'BG0 RLS on';
  ASSERT NOT has_table_privilege('anon', 'public.exos_order_locations', 'SELECT'), 'BG0 anon reads nothing';
  ASSERT has_table_privilege('authenticated', 'public.exos_order_locations', 'SELECT'), 'BG0 signed-in read (RLS)';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_order_locations', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_order_locations', 'UPDATE')
     AND NOT has_table_privilege('authenticated', 'public.exos_order_locations', 'DELETE'), 'BG0 no client writes';
  FOREACH f IN ARRAY ARRAY[
    'public.exos_record_order_location(text,text,text,text,text,text)',
    'public._exos_buyer_geo(uuid,uuid,timestamptz,integer)',
    'public._exos_org_event_ids_by_genre(uuid,text[])',
    'public._exos_org_genres(uuid)',
    'public._exos_genre_keys(jsonb)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'BG0 anon runs ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'BG0 authenticated runs ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'BG0 service_role lost ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_event_buyer_geo(uuid,integer)', 'public.exos_org_buyer_geo(uuid,timestamptz,integer)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'BG0 anon runs ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'BG0 signed-in report ' || f;
  END LOOP;
  ASSERT (SELECT bool_and(p.prosecdef AND array_to_string(p.proconfig, ',') LIKE '%search_path=public, pg_temp%')
            FROM pg_proc p WHERE p.oid IN ('public.exos_record_order_location(text,text,text,text,text,text)'::regprocedure,
              'public._exos_buyer_geo(uuid,uuid,timestamptz,integer)'::regprocedure,
              'public.exos_event_buyer_geo(uuid,integer)'::regprocedure,
              'public.exos_org_buyer_geo(uuid,timestamptz,integer)'::regprocedure,
              'public._exos_org_event_ids_by_genre(uuid,text[])'::regprocedure,
              'public._exos_org_genres(uuid)'::regprocedure)), 'BG0 definer + search_path';
  RAISE NOTICE 'OK  BG0 shape and grants';
END $$;

-- BG1 -------------------------------------------------------------------------
DO $$
DECLARE l public.exos_order_locations%ROWTYPE; s text;
BEGIN
  ASSERT pg_temp.rec('cs_b9e1', 'us', ' NY ', E'New\tYork', '10001') = 'recorded', 'BG1 record';
  SELECT * INTO l FROM public.exos_order_locations WHERE session_id = 'cs_b9e1';
  ASSERT l.country = 'US' AND l.region = 'NY' AND l.city = 'New York' AND l.postal_code = '10001'
     AND l.org_id = pg_temp.u('1') AND l.event_id = pg_temp.u('e1') AND l.source = 'stripe_billing',
    'BG1 cleaned: ' || row_to_json(l)::text;
  -- First location wins (the card-country fallback or a replay can't move it).
  ASSERT pg_temp.rec('cs_b9e1', 'FR', NULL, 'Paris', NULL, 'stripe_card_country') = 'kept', 'BG1 first wins';
  ASSERT (SELECT country FROM public.exos_order_locations WHERE session_id = 'cs_b9e1') = 'US', 'BG1 still US';
  ASSERT pg_temp.rec('cs_b9e2', 'US', 'NY', 'New York', '10002') = 'recorded', 'BG1 s2';
  ASSERT pg_temp.rec('cs_b9e3', 'US', 'NY', 'Brooklyn', '11211') = 'recorded', 'BG1 s3';
  ASSERT pg_temp.rec('cs_b9e4', 'GB', 'England', 'London', 'sw1a 1aa', 'paypal_payer') = 'recorded', 'BG1 s4 (paypal)';
  ASSERT (SELECT postal_code FROM public.exos_order_locations WHERE session_id = 'cs_b9e4') = 'SW1A 1AA', 'BG1 postal upper';
  ASSERT pg_temp.rec('cs_b9e5', 'US', 'NY', 'New York', '10003') = 'skipped:free', 'BG1 free order has no location';
  ASSERT pg_temp.rec('cs_b9e8', 'US', 'NY', 'New York', '10003') = 'skipped:status', 'BG1 pending skipped';
  ASSERT pg_temp.rec('cs_nope', 'US', 'NY', 'New York', '10003') = 'skipped:unknown_order', 'BG1 unknown order';
  ASSERT pg_temp.rec('cs_b9e6', 'USA', 'NY', 'New York', '10003') = 'skipped:country', 'BG1 bad country';
  ASSERT pg_temp.rec('cs_b9e6', NULL, 'NY', 'New York', '10003') = 'skipped:country', 'BG1 no country';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_locations WHERE session_id IN ('cs_b9e5', 'cs_b9e6', 'cs_b9e8')), 'BG1 nothing stored';
  s := pg_temp.st($q$SELECT pg_temp.rec('cs_b9e6', 'US', NULL, NULL, NULL, 'ip_lookup')$q$);
  ASSERT s LIKE '22023%', 'BG1 unknown source refused: ' || s;
  ASSERT pg_temp.rec('cs_b9e7', 'US', 'NY', 'New York', '<script>') = 'recorded', 'BG1 refunded order recorded';
  ASSERT (SELECT postal_code FROM public.exos_order_locations WHERE session_id = 'cs_b9e7') IS NULL, 'BG1 bad postal dropped';
  ASSERT pg_temp.rec('cs_b9e9', 'CA', '', '   ', NULL, 'stripe_card_country') = 'recorded', 'BG1 country only';
  ASSERT (SELECT region IS NULL AND city IS NULL FROM public.exos_order_locations WHERE session_id = 'cs_b9e9'), 'BG1 blanks are null';
  ASSERT pg_temp.rec('cs_b9e10', 'GB', 'England', 'London', 'E1 6AN') = 'recorded', 'BG1 s10';
  ASSERT pg_temp.rec('cs_b9e20', 'US', 'NY', 'New York', '10001') = 'recorded', 'BG1 org B';
  RAISE NOTICE 'OK  BG1 recording';
END $$;

-- BG2 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  SELECT count(*) INTO n FROM public.exos_order_locations;
  ASSERT n = 7, 'BG2 owner A sees A''s 7: ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_locations WHERE session_id = 'cs_b9e20'), 'BG2 owner A not B''s';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  SELECT count(*) INTO n FROM public.exos_order_locations;
  ASSERT n = 7, 'BG2 finance A: ' || n;
  PERFORM pg_temp.act(pg_temp.u('a3'));
  SELECT count(*) INTO n FROM public.exos_order_locations;
  ASSERT n = 0, 'BG2 scanner sees none: ' || n;
  PERFORM pg_temp.act(pg_temp.u('a4'));
  SELECT count(*) INTO n FROM public.exos_order_locations;
  ASSERT n = 1 AND EXISTS (SELECT 1 FROM public.exos_order_locations WHERE session_id = 'cs_b9e20'), 'BG2 owner B: B only';
  PERFORM pg_temp.act(pg_temp.u('a5'));
  SELECT count(*) INTO n FROM public.exos_order_locations;
  ASSERT n = 0, 'BG2 outsider: ' || n;
  -- b1 bought s1, s10 and s20 (the free s5 has no row); b2 never sees them.
  PERFORM pg_temp.act(pg_temp.u('b1'));
  ASSERT (SELECT array_agg(session_id ORDER BY session_id) FROM public.exos_order_locations)
       = ARRAY['cs_b9e1', 'cs_b9e10', 'cs_b9e20'], 'BG2 buyer reads their own';
  PERFORM pg_temp.act(pg_temp.u('b2'));
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_locations WHERE session_id IN ('cs_b9e1', 'cs_b9e10', 'cs_b9e4')),
    'BG2 b2 never reads b1''s or the guest''s';
  SELECT count(*) INTO n FROM public.exos_order_locations;
  ASSERT n = 4, 'BG2 b2 own (s2, s3, s7, s9): ' || n;
  ASSERT pg_temp.st($q$INSERT INTO public.exos_order_locations (session_id, org_id, event_id, country, source)
                       VALUES ('cs_b9e6', pg_temp.u('1'), pg_temp.u('e1'), 'US', 'stripe_billing')$q$) LIKE '42501%', 'BG2 no insert';
  ASSERT pg_temp.st($q$SELECT public.exos_record_order_location('cs_b9e6', 'US', NULL, NULL, NULL, 'stripe_billing')$q$) LIKE '42501%',
    'BG2 a client can''t record';
  RAISE NOTICE 'OK  BG2 RLS and cross-org isolation';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.st('SELECT count(*) FROM public.exos_order_locations') LIKE '42501%', 'BG2 anon refused';
  ASSERT pg_temp.st(format('SELECT public.exos_event_buyer_geo(%L)', pg_temp.u('e1'))) LIKE '42501%', 'BG4 anon report refused';
END $$;
RESET ROLE;

-- BG3 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; c jsonb;
BEGIN
  r := public._exos_buyer_geo(pg_temp.u('1'), pg_temp.u('e1'), NULL, 10);
  -- Counted: s1 s2 s3 s4 s5 s6 s7 s9 (8); s8 pending is not.
  ASSERT (r->>'orders')::int = 8 AND (r->>'tickets')::int = 9, 'BG3 totals: ' || r::text;
  ASSERT (r->>'located_orders')::int = 6 AND (r->>'unknown_orders')::int = 2, 'BG3 located / unknown: ' || r::text;
  -- US: s1 s2 s3 s7 = 4 orders, 5 tickets, 4000 + 2000 + 2500 + 2000.
  c := r->'countries'->0;
  ASSERT c->>'country' = 'US' AND (c->>'orders')::int = 4 AND (c->>'tickets')::int = 5
     AND (c->>'gross_cents')::bigint = 10500 AND c->>'currency' = 'USD', 'BG3 US: ' || c::text;
  ASSERT r->'countries' @> '[{"country": "GB", "orders": 1, "tickets": 1, "gross_cents": 3000}]'::jsonb, 'BG3 GB: ' || r::text;
  ASSERT r->'countries' @> '[{"country": "CA", "orders": 1, "gross_cents": 1500}]'::jsonb, 'BG3 CA (country only)';
  ASSERT jsonb_array_length(r->'countries') = 3, 'BG3 three countries';
  -- Cities: New York (s1 s2 s7) 3 orders 8000, then Brooklyn, London; CA has no city.
  c := r->'cities'->0;
  ASSERT c->>'city' = 'New York' AND c->>'region' = 'NY' AND (c->>'orders')::int = 3 AND (c->>'gross_cents')::bigint = 8000,
    'BG3 New York: ' || c::text;
  ASSERT r->'cities' @> '[{"city": "Brooklyn", "orders": 1, "gross_cents": 2500}, {"city": "London", "country": "GB"}]'::jsonb,
    'BG3 cities: ' || (r->'cities')::text;
  ASSERT jsonb_array_length(r->'cities') = 3, 'BG3 three cities';
  ASSERT NOT (r::text LIKE '%postal%' OR r::text LIKE '%10001%'), 'BG3 the report carries no postal code';
  -- Unknown: the free s5 and the unlocated s6.
  ASSERT r->'unknown' = '[{"country": null, "currency": "USD", "orders": 2, "tickets": 2, "gross_cents": 2000}]'::jsonb,
    'BG3 unknown: ' || (r->'unknown')::text;
  -- Other tickets: the two live RSVP tickets (the voided one and s1's ticket don't count).
  ASSERT (r->>'other_tickets')::int = 2, 'BG3 other tickets: ' || (r->>'other_tickets');
  -- Limit 1: the top country and city only; unknown still there.
  r := public._exos_buyer_geo(pg_temp.u('1'), pg_temp.u('e1'), NULL, 1);
  ASSERT jsonb_array_length(r->'countries') = 1 AND r #>> '{countries,0,country}' = 'US'
     AND jsonb_array_length(r->'cities') = 1 AND jsonb_array_length(r->'unknown') = 1, 'BG3 limit: ' || r::text;
  -- Org rollup: e1 plus e5's s10 (GB, London), never org B's s20.
  r := public._exos_buyer_geo(pg_temp.u('1'), NULL, NULL, 10);
  ASSERT (r->>'orders')::int = 9 AND r->'countries' @> '[{"country": "GB", "orders": 2, "gross_cents": 7000}]'::jsonb
     AND r->'cities' @> '[{"city": "London", "orders": 2}]'::jsonb, 'BG3 org rollup: ' || r::text;
  ASSERT r->'countries' @> '[{"country": "US", "orders": 4, "gross_cents": 10500}]'::jsonb, 'BG3 org B''s order not counted';
  -- Since 7 days ago: s10 (40 days old) drops out.
  r := public._exos_buyer_geo(pg_temp.u('1'), NULL, now() - interval '7 days', 10);
  ASSERT (r->>'orders')::int = 8 AND r->'countries' @> '[{"country": "GB", "orders": 1}]'::jsonb, 'BG3 since: ' || r::text;
  -- Another org's event through org A's id: nothing.
  r := public._exos_buyer_geo(pg_temp.u('1'), pg_temp.u('e9'), NULL, 10);
  ASSERT (r->>'orders')::int = 0 AND r->'countries' = '[]'::jsonb, 'BG3 other org''s event: ' || r::text;
  RAISE NOTICE 'OK  BG3 report sums';
END $$;

-- BG4 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb; s text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  r := public.exos_event_buyer_geo(pg_temp.u('e1'));
  ASSERT (r->>'orders')::int = 8, 'BG4 owner';
  r := public.exos_org_buyer_geo(pg_temp.u('1'));
  ASSERT (r->>'orders')::int = 9, 'BG4 owner org rollup';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT (public.exos_event_buyer_geo(pg_temp.u('e1'))->>'orders')::int = 8, 'BG4 finance';
  FOREACH s IN ARRAY ARRAY['a3', 'a4', 'a5', 'b1'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    ASSERT pg_temp.st(format('SELECT public.exos_event_buyer_geo(%L)', pg_temp.u('e1'))) LIKE '42501%', 'BG4 event refused for ' || s;
    ASSERT pg_temp.st(format('SELECT public.exos_org_buyer_geo(%L)', pg_temp.u('1'))) LIKE '42501%', 'BG4 org refused for ' || s;
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('a1'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_buyer_geo(%L)', gen_random_uuid())) LIKE 'P0002%', 'BG4 unknown event';
  ASSERT pg_temp.st(format('SELECT public._exos_buyer_geo(%L)', pg_temp.u('1'))) LIKE '42501%', 'BG4 internal not callable';
  RAISE NOTICE 'OK  BG4 report access';
END $$;
RESET ROLE;

-- BG5 -------------------------------------------------------------------------
DO $$
BEGIN
  -- u1 (unconfirmed, the guest's address) deletes itself: the guest order's
  -- location stays (an unconfirmed address may be someone else's).
  UPDATE auth.users SET email = 'b9e-guest@x.com' WHERE id = pg_temp.u('b3');
  PERFORM pg_temp.act(pg_temp.u('b3'));
  PERFORM public.exos_delete_my_account();
  ASSERT EXISTS (SELECT 1 FROM public.exos_order_locations WHERE session_id = 'cs_b9e4'), 'BG5 unconfirmed erases nothing by email';
  -- A guest order bought with b1's (confirmed) address, in another spelling.
  UPDATE public.exos_checkout_sessions SET buyer_email = 'B9E-B1@x.com ' WHERE session_id = 'cs_b9e4';
  -- b1's upcoming ticket would block deletion: the fixture ticket isn't b1's
  -- order (it's an RSVP); move it out of the way.
  UPDATE public.exos_tickets SET owner_id = pg_temp.u('a1') WHERE owner_id = pg_temp.u('b1');
  PERFORM pg_temp.act(pg_temp.u('b1'));
  PERFORM public.exos_delete_my_account();
  PERFORM pg_temp.act(NULL);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_locations
                      WHERE session_id IN ('cs_b9e1', 'cs_b9e10', 'cs_b9e20', 'cs_b9e4')),
    'BG5 b1''s locations gone (own sessions in both orgs and the guest order under the confirmed email)';
  ASSERT (SELECT count(*) FROM public.exos_order_locations WHERE session_id IN ('cs_b9e2', 'cs_b9e3', 'cs_b9e7', 'cs_b9e9')) = 4,
    'BG5 b2''s stay';
  -- The orders themselves stay for the organizer; a late replay can't
  -- put the location back on the closed account.
  ASSERT EXISTS (SELECT 1 FROM public.exos_checkout_sessions WHERE session_id = 'cs_b9e1'), 'BG5 order kept';
  ASSERT pg_temp.rec('cs_b9e1', 'US', 'NY', 'New York', '10001') = 'skipped:account_closed', 'BG5 no location after deletion';
  -- The report now counts b1's e1 order as unknown.
  ASSERT (public._exos_buyer_geo(pg_temp.u('1'), pg_temp.u('e1'), NULL, 10)->>'unknown_orders')::int = 4, 'BG5 report unknown';
  RAISE NOTICE 'OK  BG5 account deletion clears the location';
END $$;

-- BG6 -------------------------------------------------------------------------
DO $$
DECLARE ids uuid[]; g jsonb;
BEGIN
  ASSERT public.exos_genre_key('  Hip   Hop ') = 'hip hop' AND public.exos_genre_key('ＨＯＵＳＥ') = 'house'
     AND public.exos_genre_key('   ') IS NULL AND public.exos_genre_key(NULL) IS NULL, 'BG6 genre key';
  ids := public._exos_org_event_ids_by_genre(pg_temp.u('1'), ARRAY['HOUSE']);
  ASSERT ids @> ARRAY[pg_temp.u('e1'), pg_temp.u('e2'), pg_temp.u('e3'), pg_temp.u('e4')] AND cardinality(ids) = 4,
    'BG6 house, any status, any case: ' || ids::text;
  ids := public._exos_org_event_ids_by_genre(pg_temp.u('1'), ARRAY['jazz', 'techno']);
  ASSERT ids @> ARRAY[pg_temp.u('e1'), pg_temp.u('e5')] AND cardinality(ids) = 2, 'BG6 any of: ' || ids::text;
  ids := public._exos_org_event_ids_by_genre(pg_temp.u('2'), ARRAY['house']);
  ASSERT ids = ARRAY[pg_temp.u('e9')], 'BG6 one org only: ' || ids::text;
  ASSERT public._exos_org_event_ids_by_genre(pg_temp.u('1'), ARRAY['polka']) = '{}'::uuid[], 'BG6 none';
  g := public._exos_org_genres(pg_temp.u('1'));
  ASSERT g->0 = '{"genre": "house", "name": "House", "events": 4, "published_events": 3}'::jsonb, 'BG6 genres in use: ' || g::text;
  ASSERT g @> '[{"genre": "secret genre", "events": 1, "published_events": 0}, {"genre": "techno", "name": "Techno"}]'::jsonb,
    'BG6 every status for the organizer: ' || g::text;
  ASSERT jsonb_array_length(g) = 5, 'BG6 org A''s five, never org B''s: ' || g::text;
  RAISE NOTICE 'OK  BG6 organizer genres';
END $$;

-- BG7 -------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text; ids text;
BEGIN
  v := public._exos_api_public('events.list', NULL, '{"genres": ["house"]}', 'net:b9e');
  SELECT string_agg(x->>'id', ',' ORDER BY x->>'id') INTO ids FROM jsonb_array_elements(v->'rows') x;
  -- e1 (A) and e9 (B): never the past e2, the draft e3 or the noindex e4.
  ASSERT ids = pg_temp.u('e1')::text || ',' || pg_temp.u('e9')::text AND (v->>'total')::int = 2, 'BG7 house: ' || coalesce(ids, 'none');
  ASSERT NOT (v::text LIKE '%B9E Draft%' OR v::text LIKE '%B9E Private%' OR v::text LIKE '%B9E Last Year%'), 'BG7 no leak';
  ASSERT v #> '{rows,0,genres}' IS NOT NULL, 'BG7 genres in the response';
  v := public._exos_api_public('events.list', NULL, '{"genres": "  JAZZ "}', 'net:b9e');
  ASSERT (v->>'total')::int = 1 AND v #>> '{rows,0,id}' = pg_temp.u('e5')::text, 'BG7 one genre as a string: ' || v::text;
  v := public._exos_api_public('events.list', NULL, '{"genres": ["house"], "venue": "b9e-other"}', 'net:b9e');
  ASSERT (v->>'total')::int = 1 AND v #>> '{rows,0,id}' = pg_temp.u('e9')::text, 'BG7 genre + organizer';
  v := public._exos_api_public('events.list', NULL, '{"genres": ["Secret Genre"]}', 'net:b9e');
  ASSERT (v->>'total')::int = 0, 'BG7 a draft''s genre finds nothing';
  v := public._exos_api_public('events.list', NULL, '{"genres": ["hidden genre"]}', 'net:b9e');
  ASSERT (v->>'total')::int = 0, 'BG7 a noindex event''s genre finds nothing';
  v := public._exos_api_public('events.list', NULL, '{"venue": "b9e-hall"}', 'net:b9e');
  ASSERT (v->>'total')::int = 2 AND NOT (v::text LIKE '%B9E Private%'), 'BG7 unfiltered list drops noindex too: ' || (v->>'total');
  s := pg_temp.st($q$SELECT public._exos_api_public('events.list', NULL, '{"genres": [1]}', 'net:b9e')$q$);
  ASSERT s LIKE '22023%', 'BG7 bad genres: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_api_public('events.list', NULL, %L, 'net:b9e')$q$,
                         jsonb_build_object('genres', (SELECT jsonb_agg('g' || i) FROM generate_series(1, 21) i))));
  ASSERT s LIKE '22023%at most 20%', 'BG7 too many genres: ' || s;
  -- genres.list: upcoming published listed events only.
  v := public._exos_api_public('genres.list', NULL, '{}', 'net:b9e');
  ASSERT v @> '[{"genre": "house", "events": 2}, {"genre": "techno", "events": 1, "name": "Techno"}, {"genre": "jazz", "events": 1}]'::jsonb,
    'BG7 genres.list: ' || v::text;
  ASSERT NOT (v::text ILIKE '%secret genre%' OR v::text ILIKE '%hidden genre%'), 'BG7 no draft / noindex genre: ' || v::text;
  ASSERT v->0->'variants' @> '["House", "house"]'::jsonb, 'BG7 variants: ' || (v->0)::text;
  v := public._exos_api_public('genres.list', NULL, '{"venue": "b9e-other"}', 'net:b9e');
  ASSERT v = '[{"genre": "house", "name": "house", "events": 1, "variants": ["house"]}]'::jsonb, 'BG7 one organizer: ' || v::text;
  -- search: a noindex event is not found by name.
  v := public._exos_api_public('search', NULL, '{"q": "B9E Private"}', 'net:b9e');
  ASSERT v->'events' = '[]'::jsonb, 'BG7 search drops noindex: ' || v::text;
  v := public._exos_api_public('search', NULL, '{"q": "B9E Warehouse"}', 'net:b9e');
  ASSERT jsonb_array_length(v->'events') = 1, 'BG7 search still finds a listed event';
  RAISE NOTICE 'OK  BG7 public discovery genre filter';
END $$;

SELECT set_config('request.headers', '{"cf-connecting-ip": "203.0.113.77"}', true);
SET LOCAL ROLE anon;
DO $$
DECLARE v jsonb;
BEGIN
  v := public.exos_api_public('genres.list', NULL, '{}');
  ASSERT v @> '[{"genre": "house"}]'::jsonb AND NOT (v::text ILIKE '%secret%'), 'BG7 anon genres.list: ' || v::text;
  v := public.exos_api_public('events.list', NULL, '{"genres": ["house"]}');
  ASSERT (v->>'total')::int = 2, 'BG7 anon filter';
  RAISE NOTICE 'OK  BG7 anon through exos_api_public';
END $$;
RESET ROLE;

-- BG8 -------------------------------------------------------------------------
DO $$
DECLARE d text; m text;
BEGIN
  d := pg_get_functiondef('public._exos_api_public(text,text,jsonb,text)'::regprocedure);
  FOREACH m IN ARRAY ARRAY['exos: genres decl', 'exos: genres action', 'exos: genres venue', 'exos: genres parse',
                           'exos: genres filter', 'exos: genres list', 'exos: search noindex'] LOOP
    ASSERT position(m IN d) > 0, 'BG8 missing ' || m;
  END LOOP;
  d := pg_get_functiondef('public.exos_delete_my_account()'::regprocedure);
  ASSERT position('exos: buyer location' IN d) > 0 AND position('exos: confirmed email only' IN d) > 0
     AND position('exos_order_details' IN d) > 0, 'BG8 deletion keeps every earlier patch';
  RAISE NOTICE 'OK  BG8 patch markers';
END $$;

\echo 'test_buyer_geo_genre: all passed'
ROLLBACK;
