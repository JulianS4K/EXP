-- ============================================================================
-- Migration 20261106140000 — Exos: buyer location + genre filter (DICE gaps #5)
-- ============================================================================
-- DICE's partner API carries Order.ipCity / Order.ipCountry and a
-- genreTypes connection. Exos gets the same two things its own way.
--
-- 1. Buyer location. Each paid order records where the buyer is: country,
--    region (state), city and postal code of the billing address the payment
--    processor already gave us. Exos does NOT geolocate IP addresses and
--    never stores a street line.
--      * exos_order_locations: one row per checkout session (an order).
--        stripe-webhook fills it from the Checkout Session's
--        customer_details.address (in the event payload), else from the
--        charge's billing address / card country that its fee-actuals read
--        already fetched (no extra Stripe call); exos-paypal from the payer's
--        address in the capture response (_shared/buyerLocation.ts).
--      * Free and RSVP orders have none: the report counts them as unknown.
--      * Read: the org's owner / manager / finance, and the buyer their own
--        order's row. No client writes. Written only through
--        exos_record_order_location (service role), which cleans each value
--        again, ignores free / unpaid orders and closed accounts, and keeps
--        the first location an order gets.
--      * Erased with the account: exos_delete_my_account deletes the rows of
--        the caller's orders (their own sessions, and guest orders under
--        their CONFIRMED email), before the email is cleared.
--      * Report: _exos_buyer_geo (service role: exos-api), and for the
--        dashboard exos_event_buyer_geo (one event) and exos_org_buyer_geo
--        (the whole org, optionally since a date): orders, tickets and gross
--        per country and per city, plus an unknown row.
--
-- 2. Genres. exos_events.genres (text[], free text since the phase-1 schema)
--    becomes filterable and listable:
--      * exos_genre_key: the comparison key (NFKC, lower case, single spaces).
--      * _exos_org_event_ids_by_genre / _exos_org_genres (service role):
--        exos-api's GET /v1/events?genre= / ?genres= and GET /v1/genres.
--      * _exos_api_public (patched in place): events.list takes a genres
--        filter, a new genres.list action lists the genres of upcoming
--        published events (exos-api GET /v1/public/discovery/genres; anon
--        through the existing exos_api_public). Both, and search's events,
--        now leave out noindex events: "keep the event out of search
--        engines, the sitemap and the public feeds" (mig 20261005090000).
--
-- Touches:  N: TABLE exos_order_locations; FUNCTION exos_record_order_location,
--              _exos_buyer_geo, exos_event_buyer_geo, exos_org_buyer_geo,
--              exos_genre_key, _exos_genre_keys, _exos_org_event_ids_by_genre,
--              _exos_org_genres
--           W: FUNCTION _exos_api_public (patched in place: markers
--              'exos: genres decl', 'exos: genres action', 'exos: genres venue',
--              'exos: genres parse', 'exos: genres filter', 'exos: genres list',
--              'exos: search noindex'),
--              exos_delete_my_account (patched in place: 'exos: buyer location')
-- Callers:  stripe-webhook, exos-paypal (record); exos-api
--           (/v1/events/:id/buyer-locations, /v1/buyer-locations, /v1/events?genre=,
--           /v1/genres, /v1/public/discovery/genres); the event report's
--           Marketing tab (BuyerLocationsPanel); Home's genre chips.
-- Pre-reqs: every exos migration before this one (20261105110000 for
--           _exos_api_public, 20261102160000 for the account-deletion text).
-- Re-run safe: IF NOT EXISTS / CREATE OR REPLACE / marker-checked patches.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ===========================================================================
-- 1. Buyer location
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_order_locations (
  session_id   text PRIMARY KEY REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id     uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  country      text NOT NULL,
  region       text,
  city         text,
  postal_code  text,
  source       text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_order_locations_country_chk CHECK (country ~ '^[A-Z]{2}$'),
  CONSTRAINT exos_order_locations_region_chk CHECK (region IS NULL OR char_length(region) BETWEEN 1 AND 80),
  CONSTRAINT exos_order_locations_city_chk CHECK (city IS NULL OR char_length(city) BETWEEN 1 AND 80),
  CONSTRAINT exos_order_locations_postal_chk CHECK (postal_code IS NULL OR postal_code ~ '^[A-Z0-9][A-Z0-9 -]{0,15}$'),
  CONSTRAINT exos_order_locations_source_chk CHECK (source IN
    ('stripe_billing', 'stripe_card_billing', 'stripe_card_country', 'paypal_payer', 'paypal_shipping'))
);
CREATE INDEX IF NOT EXISTS exos_order_locations_org_idx ON public.exos_order_locations (org_id, country);
CREATE INDEX IF NOT EXISTS exos_order_locations_event_idx ON public.exos_order_locations (event_id, country);
COMMENT ON TABLE public.exos_order_locations IS
  'Where an order''s buyer is: country, region, city, postal code of the billing address from Stripe / PayPal. Never a street, never from an IP (mig 20261106140000).';

DROP TRIGGER IF EXISTS exos_order_locations_touch ON public.exos_order_locations;
CREATE TRIGGER exos_order_locations_touch BEFORE UPDATE ON public.exos_order_locations
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_order_locations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_order_locations_sel ON public.exos_order_locations;
CREATE POLICY exos_order_locations_sel ON public.exos_order_locations FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance'])
         OR EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs
                     WHERE cs.session_id = exos_order_locations.session_id
                       AND cs.buyer_uid = (SELECT auth.uid())));
REVOKE ALL ON public.exos_order_locations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_order_locations TO authenticated;
GRANT ALL ON public.exos_order_locations TO service_role;

-- Record one order's location (stripe-webhook, exos-paypal). Returns
-- 'recorded', 'kept' (the order already has one: the first wins) or
-- 'skipped:<why>'. Free text is cleaned like _shared/buyerLocation.ts; a
-- value that can't be cleaned is dropped, never stored raw.
CREATE OR REPLACE FUNCTION public.exos_record_order_location(
  p_session_id text, p_country text, p_region text, p_city text, p_postal_code text, p_source text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  s         public.exos_checkout_sessions%ROWTYPE;
  v_country text := upper(btrim(coalesce(p_country, '')));
  v_region  text;
  v_city    text;
  v_postal  text := upper(regexp_replace(btrim(normalize(coalesce(p_postal_code, ''), NFKC)), '\s+', ' ', 'g'));
  v_n       int;
BEGIN
  IF v_country !~ '^[A-Z]{2}$' THEN RETURN 'skipped:country'; END IF;
  IF p_source IS NULL OR p_source NOT IN
     ('stripe_billing', 'stripe_card_billing', 'stripe_card_country', 'paypal_payer', 'paypal_shipping') THEN
    RAISE EXCEPTION 'exos_record_order_location: unknown source' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN RETURN 'skipped:unknown_order'; END IF;
  -- Paid orders only: a free / RSVP / pass order has no billing address.
  IF s.amount_cents <= 0 THEN RETURN 'skipped:free'; END IF;
  IF s.status NOT IN ('fulfilled', 'partially_refunded', 'refunded') THEN RETURN 'skipped:status'; END IF;
  -- A closed account (exos_delete_my_account) never gets a location back
  -- from a late webhook replay.
  IF s.buyer_uid IS NOT NULL AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = s.buyer_uid
                                          AND u.email LIKE 'deleted+%@deleted.invalid') THEN
    RETURN 'skipped:account_closed';
  END IF;
  v_region := nullif(left(btrim(regexp_replace(regexp_replace(normalize(coalesce(p_region, ''), NFKC),
                '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g')), 80), '');
  v_city := nullif(left(btrim(regexp_replace(regexp_replace(normalize(coalesce(p_city, ''), NFKC),
                '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g')), 80), '');
  v_region := nullif(btrim(v_region), '');
  v_city := nullif(btrim(v_city), '');
  IF v_postal !~ '^[A-Z0-9][A-Z0-9 -]{0,15}$' THEN v_postal := NULL; END IF;

  INSERT INTO public.exos_order_locations (session_id, org_id, event_id, country, region, city, postal_code, source)
  VALUES (s.session_id, s.org_id, s.event_id, v_country, v_region, v_city, v_postal, p_source)
  ON CONFLICT (session_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN CASE WHEN v_n > 0 THEN 'recorded' ELSE 'kept' END;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_order_location(text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_order_location(text, text, text, text, text, text) TO service_role;

-- The "Where buyers are" report: paid and free Exos orders (fulfilled,
-- partially or fully refunded) of one org, one event or since a date.
-- countries / cities: the top p_limit (1-100, default 10) by orders, each
-- { country, region, city, currency, orders, tickets, gross_cents };
-- gross is what buyers paid (amount_cents, all-in) in that currency. The
-- unknown row (country null) is every counted order without a location
-- (free orders, RSVPs through checkout, orders before this migration).
-- other_tickets: live tickets that came from no checkout (RSVPs, comps,
-- door sales, imports); they have no location either.
CREATE OR REPLACE FUNCTION public._exos_buyer_geo(
  p_org uuid, p_event uuid DEFAULT NULL, p_since timestamptz DEFAULT NULL, p_limit int DEFAULT 10)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH s AS (
    SELECT cs.session_id, cs.quantity, cs.amount_cents, upper(cs.currency) AS currency,
           l.country, l.region, l.city
      FROM public.exos_checkout_sessions cs
      LEFT JOIN public.exos_order_locations l ON l.session_id = cs.session_id
     WHERE cs.org_id = p_org
       AND (p_event IS NULL OR cs.event_id = p_event)
       AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded')
       AND (p_since IS NULL OR cs.created_at >= p_since)
  ), lim AS (
    SELECT least(greatest(coalesce(p_limit, 10), 1), 100) AS n
  ), c AS (
    SELECT country, currency, count(*)::int AS orders, sum(quantity)::int AS tickets,
           sum(amount_cents)::bigint AS gross_cents
      FROM s WHERE country IS NOT NULL GROUP BY country, currency
  ), t AS (
    SELECT country, region, city, currency, count(*)::int AS orders, sum(quantity)::int AS tickets,
           sum(amount_cents)::bigint AS gross_cents
      FROM s WHERE country IS NOT NULL AND city IS NOT NULL GROUP BY country, region, city, currency
  ), u AS (
    SELECT currency, count(*)::int AS orders, sum(quantity)::int AS tickets, sum(amount_cents)::bigint AS gross_cents
      FROM s WHERE country IS NULL GROUP BY currency
  )
  SELECT jsonb_build_object(
    'org_id', p_org,
    'event_id', p_event,
    'since', p_since,
    'orders', (SELECT count(*) FROM s),
    'tickets', (SELECT coalesce(sum(quantity), 0) FROM s),
    'located_orders', (SELECT count(*) FROM s WHERE country IS NOT NULL),
    'unknown_orders', (SELECT count(*) FROM s WHERE country IS NULL),
    'countries', coalesce((SELECT jsonb_agg(jsonb_build_object('country', x.country, 'currency', x.currency,
                    'orders', x.orders, 'tickets', x.tickets, 'gross_cents', x.gross_cents)
                    ORDER BY x.orders DESC, x.gross_cents DESC, x.country, x.currency)
                    FROM (SELECT * FROM c ORDER BY orders DESC, gross_cents DESC, country, currency
                           LIMIT (SELECT n FROM lim)) x), '[]'::jsonb),
    'cities', coalesce((SELECT jsonb_agg(jsonb_build_object('country', x.country, 'region', x.region, 'city', x.city,
                    'currency', x.currency, 'orders', x.orders, 'tickets', x.tickets, 'gross_cents', x.gross_cents)
                    ORDER BY x.orders DESC, x.gross_cents DESC, x.country, x.city, x.region, x.currency)
                    FROM (SELECT * FROM t ORDER BY orders DESC, gross_cents DESC, country, city, region, currency
                           LIMIT (SELECT n FROM lim)) x), '[]'::jsonb),
    'unknown', coalesce((SELECT jsonb_agg(jsonb_build_object('country', NULL, 'currency', u.currency,
                    'orders', u.orders, 'tickets', u.tickets, 'gross_cents', u.gross_cents) ORDER BY u.currency)
                    FROM u), '[]'::jsonb),
    'other_tickets', (SELECT count(*) FROM public.exos_tickets tk
                       WHERE tk.org_id = p_org AND (p_event IS NULL OR tk.event_id = p_event)
                         AND tk.status IN ('active', 'used')
                         AND (p_since IS NULL OR tk.created_at >= p_since)
                         AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs2
                                          WHERE cs2.session_id = tk.order_ref)))
$$;
REVOKE ALL ON FUNCTION public._exos_buyer_geo(uuid, uuid, timestamptz, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_buyer_geo(uuid, uuid, timestamptz, int) TO service_role;

-- Dashboard: one event's report (the event report's Marketing tab).
CREATE OR REPLACE FUNCTION public.exos_event_buyer_geo(p_event_id uuid, p_limit int DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL THEN RAISE EXCEPTION 'exos_event_buyer_geo: event not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'exos_event_buyer_geo: owner, manager or finance only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_buyer_geo(v_org, p_event_id, NULL, p_limit);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_buyer_geo(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_buyer_geo(uuid, int) TO authenticated, service_role;

-- Dashboard: the whole org, optionally since a date.
CREATE OR REPLACE FUNCTION public.exos_org_buyer_geo(p_org_id uuid, p_since timestamptz DEFAULT NULL, p_limit int DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_org_id IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'exos_org_buyer_geo: owner, manager or finance only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_buyer_geo(p_org_id, NULL, p_since, p_limit);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_buyer_geo(uuid, timestamptz, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_buyer_geo(uuid, timestamptz, int) TO authenticated, service_role;

-- Account deletion: the caller's orders lose their location. Their own
-- sessions, and guest orders under their confirmed email (v_email is NULL
-- for an unconfirmed address since mig 20261102160000). Before any email
-- is cleared.
SELECT pg_temp.exos_patch_n('public.exos_delete_my_account()',
  '/* exos: buyer location */',
  $o$  -- Order records stay for the organizer, without personal data.
$o$,
  $n$  /* exos: buyer location */ -- mig 20261106140000: where the buyer was is personal data.
  DELETE FROM public.exos_order_locations l
   WHERE l.session_id IN (
           SELECT cs.session_id FROM public.exos_checkout_sessions cs WHERE cs.buyer_uid = v_uid
           UNION
           SELECT cs.session_id FROM public.exos_checkout_sessions cs
            WHERE v_email IS NOT NULL AND v_email <> '' AND lower(btrim(cs.buyer_email)) = v_email);

  -- Order records stay for the organizer, without personal data.
$n$, 1);

-- ===========================================================================
-- 2. Genres
-- ===========================================================================
-- exos_events.genres has been there since the phase-1 schema
-- (20260520120000), so this is a no-op on the shared project; the SQL
-- harness chain starts from a stub table without it.
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS genres text[];

-- The comparison key of a genre: NFKC, lower case, single spaces, 40
-- characters (the artists' genre cap). NULL for an empty one. Mirrors
-- genreKey in _shared/api/genres.ts.
CREATE OR REPLACE FUNCTION public.exos_genre_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT nullif(btrim(left(btrim(regexp_replace(lower(normalize(coalesce(p, ''), NFKC)), '\s+', ' ', 'g')), 40)), '')
$$;

-- A genres filter from an API argument: a string or a list of strings, each
-- keyed by exos_genre_key; at most 20; NULL when none.
CREATE OR REPLACE FUNCTION public._exos_genre_keys(p jsonb)
RETURNS text[] LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE v text[];
BEGIN
  IF p IS NULL OR jsonb_typeof(p) = 'null' THEN RETURN NULL; END IF;
  IF jsonb_typeof(p) = 'string' THEN p := jsonb_build_array(p); END IF;
  IF jsonb_typeof(p) <> 'array' OR EXISTS (SELECT 1 FROM jsonb_array_elements(p) x WHERE jsonb_typeof(x) <> 'string') THEN
    RAISE EXCEPTION 'exos_api_public: genres must be a list of strings' USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(DISTINCT k) INTO v FROM (
    SELECT public.exos_genre_key(x) AS k FROM jsonb_array_elements_text(p) x) y WHERE k IS NOT NULL;
  IF cardinality(v) > 20 THEN
    RAISE EXCEPTION 'exos_api_public: at most 20 genres' USING ERRCODE = '22023';
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_genre_keys(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_genre_keys(jsonb) TO service_role;

-- exos-api GET /v1/events?genre= / ?genres=: the org's events (any status)
-- with at least one of the genres.
CREATE OR REPLACE FUNCTION public._exos_org_event_ids_by_genre(p_org uuid, p_genres text[])
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(array_agg(e.id), '{}'::uuid[]) FROM public.exos_events e
   WHERE e.org_id = p_org
     AND EXISTS (SELECT 1 FROM unnest(coalesce(e.genres, '{}'::text[])) g
                  WHERE public.exos_genre_key(g) = ANY (
                    SELECT public.exos_genre_key(x) FROM unnest(coalesce(p_genres, '{}'::text[])) x))
$$;
REVOKE ALL ON FUNCTION public._exos_org_event_ids_by_genre(uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_org_event_ids_by_genre(uuid, text[]) TO service_role;

-- exos-api GET /v1/genres: the genres on the org's events, every status:
-- { genre (the key), name (the most used spelling), events, published_events }.
CREATE OR REPLACE FUNCTION public._exos_org_genres(p_org uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('genre', g.k, 'name', g.name, 'events', g.n, 'published_events', g.p)
                            ORDER BY g.n DESC, g.k), '[]'::jsonb)
    FROM (SELECT x.k, mode() WITHIN GROUP (ORDER BY x.raw) AS name, count(DISTINCT x.id)::int AS n,
                 count(DISTINCT x.id) FILTER (WHERE x.status = 'published')::int AS p
            FROM (SELECT e.id, e.status, public.exos_genre_key(r) AS k, btrim(r) AS raw
                    FROM public.exos_events e CROSS JOIN LATERAL unnest(coalesce(e.genres, '{}'::text[])) r
                   WHERE e.org_id = p_org) x
           WHERE x.k IS NOT NULL GROUP BY x.k) g
$$;
REVOKE ALL ON FUNCTION public._exos_org_genres(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_org_genres(uuid) TO service_role;

-- Public discovery (_exos_api_public, mig 20261105110000), patched in place.
SELECT pg_temp.exos_patch_n('public._exos_api_public(text, text, jsonb, text)',
  '/* exos: genres decl */',
  $o$  v_out   jsonb;
$o$,
  $n$  v_out   jsonb;
  v_genres text[]; /* exos: genres decl */ -- mig 20261106140000
$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_api_public(text, text, jsonb, text)',
  '/* exos: genres action */',
  $o$'series.list', 'series.get') THEN$o$,
  $n$'series.list', 'series.get', 'genres.list' /* exos: genres action */) THEN$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_api_public(text, text, jsonb, text)',
  '/* exos: genres venue */',
  $o$p_action IN ('events.list', 'venue.get', 'series.list')$o$,
  $n$p_action IN ('events.list', 'venue.get', 'series.list', 'genres.list' /* exos: genres venue */)$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_api_public(text, text, jsonb, text)',
  '/* exos: genres parse */',
  $o$  IF p_action = 'search' AND v_like IS NULL THEN$o$,
  $n$  v_genres := public._exos_genre_keys(a->'genres'); /* exos: genres parse */
  IF p_action = 'search' AND v_like IS NULL THEN$n$, 1);

-- events.list: the genres filter, and no noindex events.
SELECT pg_temp.exos_patch_n('public._exos_api_public(text, text, jsonb, text)',
  '/* exos: genres filter */',
  $o$         AND (v_like IS NULL OR e.name ILIKE v_like OR coalesce(e.venue_name, '') ILIKE v_like))$o$,
  $n$         AND (v_like IS NULL OR e.name ILIKE v_like OR coalesce(e.venue_name, '') ILIKE v_like)
         AND NOT coalesce(e.noindex, false) /* exos: genres filter */
         AND (v_genres IS NULL OR EXISTS (SELECT 1 FROM unnest(coalesce(e.genres, '{}'::text[])) g
                                           WHERE public.exos_genre_key(g) = ANY (v_genres))))$n$, 1);

-- genres.list: the genres of upcoming published, listed events (optionally
-- one organizer's), most used first: { genre, name, events, variants }.
-- variants: the spellings in use (at most 5), for a client filtering a
-- view by exact array overlap.
SELECT pg_temp.exos_patch_n('public._exos_api_public(text, text, jsonb, text)',
  '/* exos: genres list */',
  $o$  WHEN 'series.list' THEN$o$,
  $n$  WHEN 'genres.list' THEN /* exos: genres list */
    SELECT coalesce(jsonb_agg(jsonb_build_object('genre', g.k, 'name', g.name, 'events', g.n,
                                                 'variants', to_jsonb(g.variants[1:5]))
                              ORDER BY g.n DESC, g.k), '[]'::jsonb)
      INTO v_out
      FROM (SELECT x.k, mode() WITHIN GROUP (ORDER BY x.raw) AS name, count(DISTINCT x.id)::int AS n,
                   array_agg(DISTINCT x.raw) AS variants
              FROM (SELECT e.id, public.exos_genre_key(r) AS k, btrim(r) AS raw
                      FROM public.exos_events e CROSS JOIN LATERAL unnest(coalesce(e.genres, '{}'::text[])) r
                     WHERE e.status = 'published' AND NOT coalesce(e.noindex, false)
                       AND coalesce(e.ends_at, e.starts_at) >= now()
                       AND (v_org IS NULL OR e.org_id = v_org)) x
             WHERE x.k IS NOT NULL GROUP BY x.k
             ORDER BY count(DISTINCT x.id) DESC, x.k LIMIT v_lim) g;

  WHEN 'series.list' THEN$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_api_public(text, text, jsonb, text)',
  '/* exos: search noindex */',
  $o$                                     AND (e.name ILIKE v_like OR coalesce(e.venue_name, '') ILIKE v_like)$o$,
  $n$                                     AND (e.name ILIKE v_like OR coalesce(e.venue_name, '') ILIKE v_like)
                                     AND NOT coalesce(e.noindex, false) /* exos: search noindex */$n$, 1);
