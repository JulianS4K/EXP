-- ============================================================================
-- Promoter-run events with no venue on Exos (mig 20261105130000).
-- Self-contained (f7e prefix), rolled back.
--   PE1  grants and RLS: who may call / read what
--   PE2  org type: a label, owner-set, existing orgs unaffected
--   PE3  venue_record and unlisted_venue (free text, never linked)
--   PE4  secret_location: public fields stay empty, the address is apart
--   PE5  tba: explicit sales choice, sales gate, announcement on set
--   PE6  the venue gate never blocks these modes and still can't be bypassed;
--        a matching owned venue is only a suggestion
--   PE7  capacity: one sellable type to publish; 0 closes sales (mig 20261105150000)
--   PE8  publish blockers and the published-row guard
--   PE9  the secret is nowhere public before (or after) reveal: anon and a
--        stranger sweep every readable relation, every feed / JSON builder,
--        partners; only the secret table holds it
--   PE10 ticket holders after reveal: event location, live link, wallet
--   PE11 reveal notices: cron queues, mails holders once, re-sends on change,
--        SMS to opted-in holders, wallet refresh; pins never stored
--   PE12 partner API create / update with location fields
--   PE13 cross-org isolation
-- Orgs: P (promoter: owner a1, manager a2, content a3, scanner a4),
-- V (a venue org: owner b1), X (another org: owner c1).
-- Holders d1, d2; stranger d3.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
SELECT set_config('app.uid', '', false);

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('f7e00000-0000-0000-0000-0000000000a1', 'f7-owner@x.com', now()),
  ('f7e00000-0000-0000-0000-0000000000a2', 'f7-manager@x.com', now()),
  ('f7e00000-0000-0000-0000-0000000000a3', 'f7-content@x.com', now()),
  ('f7e00000-0000-0000-0000-0000000000a4', 'f7-scanner@x.com', now()),
  ('f7e00000-0000-0000-0000-0000000000b1', 'f7-venue@x.com', now()),
  ('f7e00000-0000-0000-0000-0000000000c1', 'f7-other@x.com', now()),
  ('f7e00000-0000-0000-0000-0000000000d1', 'f7-holder1@x.com', now()),
  ('f7e00000-0000-0000-0000-0000000000d2', 'f7-holder2@x.com', now()),
  ('f7e00000-0000-0000-0000-0000000000d3', 'f7-stranger@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('f7e00000-0000-0000-0000-000000000001', 'F7 Collective', 'f7-collective', 'f7e00000-0000-0000-0000-0000000000a1'),
  ('f7e00000-0000-0000-0000-000000000002', 'F7 Venue Co', 'f7-venue', 'f7e00000-0000-0000-0000-0000000000b1'),
  ('f7e00000-0000-0000-0000-000000000003', 'F7 Other', 'f7-other', 'f7e00000-0000-0000-0000-0000000000c1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('f7e00000-0000-0000-0000-000000000001', 'f7e00000-0000-0000-0000-0000000000a1', 'owner'),
  ('f7e00000-0000-0000-0000-000000000001', 'f7e00000-0000-0000-0000-0000000000a2', 'manager'),
  ('f7e00000-0000-0000-0000-000000000001', 'f7e00000-0000-0000-0000-0000000000a3', 'content'),
  ('f7e00000-0000-0000-0000-000000000001', 'f7e00000-0000-0000-0000-0000000000a4', 'scanner'),
  ('f7e00000-0000-0000-0000-000000000002', 'f7e00000-0000-0000-0000-0000000000b1', 'owner'),
  ('f7e00000-0000-0000-0000-000000000003', 'f7e00000-0000-0000-0000-0000000000c1', 'owner');
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('f7e00000-0000-0000-0000-0000000000f1', 'f7e00000-0000-0000-0000-000000000001', 'collective', 'sk_live_f7f1', 'f7f1hash',
   ARRAY['events:write','booking:write','tickets:read'], 'f7e00000-0000-0000-0000-0000000000a1'),
  ('f7e00000-0000-0000-0000-0000000000f3', 'f7e00000-0000-0000-0000-000000000003', 'other', 'sk_live_f7f3', 'f7f3hash',
   ARRAY['events:write','booking:write'], 'f7e00000-0000-0000-0000-0000000000c1');

-- V runs "Warehouse 9" in Brooklyn on Exos (owned, takes requests); P keeps
-- its own record of a loft it owns.
INSERT INTO public.exos_venues (id, org_id, name, timezone, capacity, address, relationship) VALUES
  ('f7e00000-0000-0000-0000-0000000000e1', 'f7e00000-0000-0000-0000-000000000002', 'Warehouse 9', 'America/New_York', 800,
   '{"city":"Brooklyn","region":"NY"}', 'owned'),
  ('f7e00000-0000-0000-0000-0000000000e2', 'f7e00000-0000-0000-0000-000000000001', 'F7 Loft', 'America/New_York', 120,
   '{"city":"Queens","region":"NY"}', 'owned');

-- Events of P (all drafts to start): 01 secret, 02 tba, 03 unlisted, 04 at
-- its own venue record. 09: X's event.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, currency, created_by, venue_name, venue_location, venue_address) VALUES
  ('f7e00000-0000-0000-0000-000000000101', 'f7e00000-0000-0000-0000-000000000001', 'F7 Warehouse Rave', 'f7-rave', 'draft',
   now() + interval '3 days', 'America/New_York', 'usd', 'f7e00000-0000-0000-0000-0000000000a1',
   'Old Spot', 'Old Spot', '{"street":"1 Old Rd","city":"Brooklyn"}'),
  ('f7e00000-0000-0000-0000-000000000102', 'f7e00000-0000-0000-0000-000000000001', 'F7 Pop-up', 'f7-popup', 'draft',
   now() + interval '10 days', 'America/New_York', 'usd', 'f7e00000-0000-0000-0000-0000000000a1', NULL, NULL, NULL),
  ('f7e00000-0000-0000-0000-000000000103', 'f7e00000-0000-0000-0000-000000000001', 'F7 Unlisted', 'f7-unlisted', 'draft',
   now() + interval '5 days', 'America/New_York', 'usd', 'f7e00000-0000-0000-0000-0000000000a1', NULL, NULL, NULL),
  ('f7e00000-0000-0000-0000-000000000104', 'f7e00000-0000-0000-0000-000000000001', 'F7 Loft Night', 'f7-loft', 'draft',
   now() + interval '6 days', 'America/New_York', 'usd', 'f7e00000-0000-0000-0000-0000000000a1', 'F7 Loft', 'Queens', NULL),
  ('f7e00000-0000-0000-0000-000000000109', 'f7e00000-0000-0000-0000-000000000003', 'F7 Other Show', 'f7-other-show', 'draft',
   now() + interval '4 days', 'America/New_York', 'usd', 'f7e00000-0000-0000-0000-0000000000c1', 'Elsewhere', 'Elsewhere', NULL);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order, ticket_type) VALUES
  ('f7e00000-0000-0000-0000-000000000201', 'f7e00000-0000-0000-0000-000000000101', 'GA', 0, 100, 0, 'public', 1, 'free'),
  ('f7e00000-0000-0000-0000-000000000202', 'f7e00000-0000-0000-0000-000000000102', 'GA', 0, 0, 0, 'public', 1, 'free'),
  ('f7e00000-0000-0000-0000-000000000203', 'f7e00000-0000-0000-0000-000000000103', 'GA', 0, 50, 0, 'public', 1, 'free'),
  ('f7e00000-0000-0000-0000-000000000204', 'f7e00000-0000-0000-0000-000000000104', 'GA', 0, 0, 0, 'public', 1, 'free');

-- As the dashboard has them (the harness's base schema grants none; rolled back).
GRANT SELECT, INSERT, UPDATE ON public.exos_events TO authenticated;
GRANT SELECT ON public.exos_ticket_tiers TO authenticated;
-- Prod's public read of published events (mig 20260622210000: these columns
-- to anon, published rows to anon and signed-in users), so the sweeps below
-- read what a browser can.
DO $$
BEGIN
  EXECUTE format('GRANT SELECT (%s) ON public.exos_events TO anon', (
    SELECT string_agg(quote_ident(c), ', ') FROM unnest(ARRAY['id', 'org_id', 'name', 'slug', 'description',
      'occurs_at_local', 'starts_at', 'doors_at', 'ends_at', 'timezone', 'currency', 'venue_name', 'venue_location',
      'venue_address', 'primary_performer_name', 'performer_names', 'event_type', 'category', 'genres', 'subgenres',
      'image_url', 'branding', 'purchase_limits', 'total_tickets', 'tickets_sold', 'status']) c
     WHERE EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'exos_events' AND column_name = c)));
END $$;
DROP POLICY IF EXISTS exos_events_public_read ON public.exos_events;
CREATE POLICY exos_events_public_read ON public.exos_events FOR SELECT TO anon, authenticated USING (status = 'published');
CREATE TEMP TABLE f7 (k text PRIMARY KEY, v text) ON COMMIT DROP;
GRANT ALL ON f7 TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('f7e00000-0000-0000-0000-0000000000' || p)::uuid
$$;
CREATE FUNCTION pg_temp.ev(p int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('f7e00000-0000-0000-0000-000000000' || p)::uuid
$$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
CREATE FUNCTION pg_temp.w(p_action text, p_target text, p_args jsonb DEFAULT '{}', p_key text DEFAULT 'f1')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_write(('f7e00000-0000-0000-0000-0000000000' || p_key)::uuid, p_action, p_target, p_args, NULL)
$$;
-- Every public relation the CURRENT role may read (only the columns it may
-- read, through RLS), where a row contains p_marker. Run as anon / a
-- stranger: the answer must be empty.
CREATE FUNCTION pg_temp.sweep(p_marker text) RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE r record; v_cols text; v_n bigint; v_hits text[] := '{}';
BEGIN
  FOR r IN SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p') ORDER BY c.relname LOOP
    SELECT string_agg(quote_ident(a.attname), ', ') INTO v_cols
      FROM pg_attribute a
     WHERE a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
       AND has_column_privilege(current_user, r.oid, a.attnum, 'SELECT');
    CONTINUE WHEN v_cols IS NULL;
    BEGIN
      EXECUTE format('SELECT count(*) FROM (SELECT %s FROM public.%I) x WHERE x::text LIKE %L', v_cols, r.relname,
                     '%' || p_marker || '%') INTO v_n;
      IF v_n > 0 THEN v_hits := v_hits || r.relname::text; END IF;
    EXCEPTION WHEN insufficient_privilege OR undefined_function OR undefined_table THEN NULL;
    END;
  END LOOP;
  RETURN v_hits;
END $$;
-- Every public table that holds p_marker anywhere (as the superuser).
CREATE FUNCTION pg_temp.where_is(p_marker text) RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE r record; v_n bigint; v_hits text[] := '{}';
BEGIN
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY c.relname LOOP
    EXECUTE format('SELECT count(*) FROM public.%I x WHERE x::text LIKE %L', r.relname, '%' || p_marker || '%') INTO v_n;
    IF v_n > 0 THEN v_hits := v_hits || r.relname::text; END IF;
  END LOOP;
  RETURN v_hits;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text), pg_temp.u(text), pg_temp.ev(int), pg_temp.st(text),
  pg_temp.sweep(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.v(p text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM f7 WHERE k = p $$;
GRANT EXECUTE ON FUNCTION pg_temp.v(text) TO anon, authenticated, service_role;

-- PE1 ------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public._exos_location_blockers(uuid)', 'public._exos_event_location_json(uuid,boolean)',
      'public._exos_event_location_for_ticket(uuid)', 'public._exos_event_location_set(uuid,uuid,uuid,jsonb)',
      'public._exos_location_venue_matches(uuid,text,text)', 'public._exos_event_venue_matches(uuid)',
      'public._exos_event_location_holders(uuid)', 'public._exos_location_notice_send(uuid)',
      'public.exos_send_location_notices(integer)', 'public._exos_location_reveal_at(timestamptz,timestamptz)',
      'public._exos_location_blockers_row(public.exos_events,boolean)', 'public._exos_location_line(text,jsonb)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'PE1 ' || f || ' is service-role only';
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'PE1 service role calls ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_org_type_set(uuid,text)', 'public.exos_event_location_set(uuid,jsonb)',
      'public.exos_event_location(uuid)', 'public.exos_location_venue_matches(uuid,text,text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'PE1 ' || f || ' is for signed-in callers';
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_ticket_link_location(uuid,text)', 'EXECUTE'),
    'PE1 the live link reads its location without an account';
  ASSERT NOT has_table_privilege('anon', 'public.exos_event_secret_locations', 'SELECT'), 'PE1 anon: no secret table';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_event_secret_locations', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_event_secret_locations', 'UPDATE')
     AND NOT has_table_privilege('authenticated', 'public.exos_event_secret_locations', 'DELETE'),
    'PE1 no client writes to the secret table';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_event_location_notices', 'INSERT'), 'PE1 no client notices';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_event_secret_locations'::regclass)
     AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_event_location_notices'::regclass), 'PE1 RLS on';
  ASSERT has_column_privilege('anon', 'public.exos_events', 'location_mode', 'SELECT')
     AND NOT has_column_privilege('authenticated', 'public.exos_events', 'location_mode', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.exos_events', 'UPDATE'),
    'PE1 the mode is public; writes go through the RPC (or the dashboard''s table grant)';
  -- Every SECURITY DEFINER function here pins its search_path.
  ASSERT NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.prosecdef
                        AND p.proname IN ('exos_org_type_set', 'exos_event_location_set', 'exos_event_location',
                                          'exos_ticket_link_location', 'exos_location_venue_matches',
                                          '_exos_event_location_set', '_exos_location_notice_send', 'exos_send_location_notices')
                        AND NOT ('search_path=public, pg_temp' = ANY (coalesce(p.proconfig, '{}')))),
    'PE1 search_path pinned';
  -- Only this migration's functions read the secret table, and no view does.
  ASSERT NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.prosrc ~ 'exos_event_secret_locations'
                        AND p.proname NOT IN ('_exos_event_location_for_ticket', '_exos_event_location_json',
                          '_exos_event_location_set', '_exos_event_venue_matches', '_exos_location_blockers_row',
                          '_exos_location_notice_send', 'exos_send_location_notices', '_exos_tg_secret_location')),
    'PE1 the secret table has a closed set of readers';
  ASSERT NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')
                        AND pg_get_viewdef(c.oid) ~ 'exos_event_secret_locations'), 'PE1 no view reads it';
  -- The reveal cron exists and is off.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    ASSERT (SELECT NOT active FROM cron.job WHERE jobname = 'exos-location-notices-5min'), 'PE1 the cron is created off';
  END IF;
  RAISE NOTICE 'OK  PE1 grants: service-role cores, signed-in wrappers, one link-key anon read, RLS, closed readers, cron off';
END $$;

-- PE2 ------------------------------------------------------------------------
DO $$
DECLARE s text;
BEGIN
  ASSERT (SELECT org_type FROM public.exos_orgs WHERE id = 'f7e00000-0000-0000-0000-000000000002') = 'organizer',
    'PE2 an existing org is an organizer';
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a2');
  s := pg_temp.st($q$SELECT public.exos_org_type_set('f7e00000-0000-0000-0000-000000000001', 'collective')$q$);
  ASSERT s LIKE '42501%', 'PE2 a manager can''t set the type: ' || s;
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000c1');
  s := pg_temp.st($q$SELECT public.exos_org_type_set('f7e00000-0000-0000-0000-000000000001', 'collective')$q$);
  ASSERT s LIKE '42501%', 'PE2 another org''s owner can''t: ' || s;
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  s := pg_temp.st($q$SELECT public.exos_org_type_set('f7e00000-0000-0000-0000-000000000001', 'venue_squad')$q$);
  ASSERT s LIKE '22023%', 'PE2 a bad type: ' || s;
  ASSERT public.exos_org_type_set('f7e00000-0000-0000-0000-000000000001', 'collective') ->> 'org_type' = 'collective',
    'PE2 the owner declares a collective';
  -- A label only: the manager still edits events, the scanner still doesn't.
  ASSERT public.exos_has_org_role('f7e00000-0000-0000-0000-000000000001', ARRAY['owner', 'manager']), 'PE2 owner role unchanged';
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a4');
  s := pg_temp.st($q$SELECT public.exos_event_location_set('f7e00000-0000-0000-0000-000000000101', '{"location_mode":"tba"}')$q$);
  ASSERT s LIKE '42501%', 'PE2 a scanner of a collective still can''t edit: ' || s;
  PERFORM pg_temp.act('');
  RAISE NOTICE 'OK  PE2 org type: owner-only label, existing orgs organizer, no permission change';
END $$;

-- PE3 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text;
BEGIN
  -- venue_record: today's behaviour (labels kept, own venue record linked).
  UPDATE public.exos_events SET exos_venue_id = 'f7e00000-0000-0000-0000-0000000000e2' WHERE id = pg_temp.ev(104);
  ASSERT (SELECT location_mode = 'venue_record' AND venue_name = 'F7 Loft' AND exos_venue_id IS NOT NULL
            FROM public.exos_events WHERE id = pg_temp.ev(104)), 'PE3 venue_record is the default and unchanged';
  -- unlisted_venue through the RPC.
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a2');
  v := public.exos_event_location_set(pg_temp.ev(103), jsonb_build_object(
         'location_mode', 'unlisted_venue', 'venue_name', 'Warehouse 9', 'venue_location', 'Brooklyn',
         'venue_address', jsonb_build_object('street', '9 Dock St', 'city', 'brooklyn ')));
  ASSERT v ->> 'location_mode' = 'unlisted_venue' AND v ->> 'venue_name' = 'Warehouse 9'
     AND v -> 'venue_address' ->> 'street' = '9 Dock St', 'PE3 unlisted keeps its free text ' || v::text;
  ASSERT (SELECT exos_venue_id IS NULL FROM public.exos_events WHERE id = pg_temp.ev(103)), 'PE3 never linked';
  INSERT INTO f7 VALUES ('suggest', v -> 'venue_suggestions' ->> 0);
  PERFORM pg_temp.act('');
  -- A venue record set on an unlisted event is refused; one carried over is dropped.
  s := pg_temp.st(format($q$UPDATE public.exos_events SET exos_venue_id = %L WHERE id = %L$q$,
                         'f7e00000-0000-0000-0000-0000000000e2', pg_temp.ev(103)));
  ASSERT s LIKE '22023%location%', 'PE3 unlisted + venue record refused: ' || s;
  UPDATE public.exos_events SET location_mode = 'unlisted_venue' WHERE id = pg_temp.ev(104);
  ASSERT (SELECT exos_venue_id IS NULL AND venue_name = 'F7 Loft' FROM public.exos_events WHERE id = pg_temp.ev(104)),
    'PE3 switching to unlisted drops the record link, keeps the text';
  UPDATE public.exos_events SET location_mode = 'venue_record' WHERE id = pg_temp.ev(104);
  -- Mode values are checked.
  s := pg_temp.st(format($q$UPDATE public.exos_events SET location_mode = 'nowhere' WHERE id = %L$q$, pg_temp.ev(104)));
  ASSERT s LIKE '23514%', 'PE3 unknown mode: ' || s;
  RAISE NOTICE 'OK  PE3 venue_record unchanged; unlisted is free text, never linked to a record';
END $$;

-- PE4 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text;
BEGIN
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  -- Old Spot's public name and address go when the event turns secret.
  v := public.exos_event_location_set(pg_temp.ev(101), jsonb_build_object(
         'location_mode', 'secret_location', 'area', 'Bushwick, Brooklyn', 'reveal_hours_before', 24,
         'secret_location', jsonb_build_object('venue_name', 'Warehouse 9',
           'address', jsonb_build_object('street', 'ZQX-SECRET 77 Kent Ave', 'city', 'Brooklyn', 'region', 'NY'),
           'directions', 'Blue door, ring twice')));
  ASSERT v ->> 'location_mode' = 'secret_location' AND v ->> 'venue_location' = 'Bushwick, Brooklyn'
     AND v ->> 'venue_name' IS NULL AND v -> 'venue_address' = 'null'::jsonb, 'PE4 public part is the area ' || v::text;
  ASSERT v -> 'secret_location' -> 'address' ->> 'street' = 'ZQX-SECRET 77 Kent Ave' AND (v ->> 'has_secret')::boolean,
    'PE4 the staff answer has the address';
  ASSERT (v ->> 'location_reveal_at')::timestamptz = (SELECT starts_at - interval '24 hours' FROM public.exos_events WHERE id = pg_temp.ev(101)),
    'PE4 reveal 24h before';
  ASSERT jsonb_array_length(v -> 'venue_suggestions') = 1, 'PE4 the secret place matches a venue on Exos: a suggestion';
  ASSERT (SELECT venue_name IS NULL AND venue_address IS NULL AND exos_venue_id IS NULL
            FROM public.exos_events WHERE id = pg_temp.ev(101)), 'PE4 the event row holds nothing secret';
  PERFORM pg_temp.act('');
  -- Writing a public name / address onto a secret event is refused.
  s := pg_temp.st(format($q$UPDATE public.exos_events SET venue_address = '{"street":"77 Kent Ave"}' WHERE id = %L$q$, pg_temp.ev(101)));
  ASSERT s LIKE '22023%venue_address%', 'PE4 address refused: ' || s;
  s := pg_temp.st(format($q$UPDATE public.exos_events SET venue_name = 'Warehouse 9' WHERE id = %L$q$, pg_temp.ev(101)));
  ASSERT s LIKE '22023%venue_name%', 'PE4 name refused: ' || s;
  s := pg_temp.st(format($q$INSERT INTO public.exos_events (org_id, name, status, location_mode, venue_name) VALUES (%L, 'x', 'draft', 'secret_location', 'The Spot')$q$,
                         'f7e00000-0000-0000-0000-000000000001'));
  ASSERT s LIKE '22023%', 'PE4 insert with a name refused: ' || s;
  -- Bad secret shapes.
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  s := pg_temp.st(format($q$SELECT public.exos_event_location_set(%L, '{"secret_location":{"address":{"city":"Brooklyn"}}}')$q$, pg_temp.ev(101)));
  ASSERT s LIKE '22023%street%', 'PE4 a street is required: ' || s;
  s := pg_temp.st(format($q$SELECT public.exos_event_location_set(%L, '{"secret_location":{"address":{"street":"x","lat":1}}}')$q$, pg_temp.ev(101)));
  ASSERT s LIKE '22023%', 'PE4 unknown address key: ' || s;
  s := pg_temp.st(format($q$SELECT public.exos_event_location_set(%L, '{"where":"here"}')$q$, pg_temp.ev(101)));
  ASSERT s LIKE '22023%unknown field%', 'PE4 unknown field: ' || s;
  -- Staff of the org and its door staff read the secret table; finance too.
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a3');
  ASSERT (public.exos_event_location(pg_temp.ev(101)) ->> 'viewer') = 'staff', 'PE4 content staff see it';
  PERFORM pg_temp.act('');
  RAISE NOTICE 'OK  PE4 secret: public row is the area only, address apart, public fields refused';
END $$;
-- Staff read the table under RLS; holders and strangers don't.
SELECT pg_temp.act('f7e00000-0000-0000-0000-0000000000a4');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_secret_locations) = 1, 'PE4 the event''s door staff read it';
END $$;
SELECT pg_temp.act('f7e00000-0000-0000-0000-0000000000d3');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_secret_locations) = 0, 'PE4 a stranger reads nothing';
END $$;
RESET ROLE;

-- PE5 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text; b jsonb;
BEGIN
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  v := public.exos_event_location_set(pg_temp.ev(102), '{"location_mode":"tba","area":"Somewhere in Queens"}');
  ASSERT v ->> 'location_mode' = 'tba' AND v -> 'tba_allow_sales' = 'null'::jsonb AND NOT (v ->> 'sales_open')::boolean,
    'PE5 tba starts with no choice: not on sale ' || v::text;
  b := public._exos_event_publish_blockers(pg_temp.ev(102));
  ASSERT b @> '[{"code":"tba_sales_choice"}]' AND NOT b @> '[{"code":"missing_venue"}]',
    'PE5 tba needs the sales choice, not a venue ' || b::text;
  v := public.exos_event_location_set(pg_temp.ev(102), '{"tba_allow_sales":false}');
  ASSERT v ->> 'tba_allow_sales' = 'false', 'PE5 chose: not yet';
  PERFORM pg_temp.act('');
  UPDATE public.exos_ticket_tiers SET capacity = 40 WHERE id = 'f7e00000-0000-0000-0000-000000000202';
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.ev(102);
  -- Published, not on sale: cart holds and free claims refuse.
  s := pg_temp.st(format($q$INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, quantity, expires_at) VALUES (%L, %L, %L, 1, now() + interval '10 minutes')$q$,
                         pg_temp.ev(102), 'f7e00000-0000-0000-0000-000000000202', 'f7e00000-0000-0000-0000-000000000001'));
  ASSERT s LIKE '42501%announced%', 'PE5 hold refused: ' || s;
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000d2');
  s := pg_temp.st(format($q$SELECT public.exos_claim_free_tickets(%L, %L, 1)$q$, pg_temp.ev(102), 'f7e00000-0000-0000-0000-000000000202'));
  ASSERT s LIKE '42501%announced%', 'PE5 free claim refused: ' || s;
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_event_location_set(pg_temp.ev(102), '{"tba_allow_sales":true}');
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000d2');
  PERFORM public.exos_claim_free_tickets(pg_temp.ev(102), 'f7e00000-0000-0000-0000-000000000202', 1);
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE event_id = pg_temp.ev(102) AND owner_id = pg_temp.u('d2')) = 1,
    'PE5 allowed: sold while tba';
  -- The location is set: holders get the announcement (queued here, sent by the cron).
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  v := public.exos_event_location_set(pg_temp.ev(102), jsonb_build_object('location_mode', 'unlisted_venue',
         'venue_name', 'Queens Lot', 'venue_location', 'Queens', 'venue_address', '{"street":"5 Lot Rd","city":"Queens"}'::jsonb));
  ASSERT v -> 'tba_allow_sales' = 'null'::jsonb AND (v ->> 'sales_open')::boolean, 'PE5 out of tba: the choice clears, on sale';
  PERFORM pg_temp.act('');
  ASSERT (SELECT count(*) FROM public.exos_event_location_notices
           WHERE event_id = pg_temp.ev(102) AND kind = 'announced' AND status = 'pending') = 1, 'PE5 announcement queued';
  RAISE NOTICE 'OK  PE5 tba: explicit choice, sales gate both ways, announcement when set';
END $$;

-- PE6 ------------------------------------------------------------------------
DO $$
DECLARE s text; v jsonb;
BEGIN
  -- The suggestion from PE3: V's venue, with its org and the request route.
  v := pg_temp.v('suggest')::jsonb;
  ASSERT v ->> 'venue_id' = 'f7e00000-0000-0000-0000-0000000000e1' AND v -> 'org' ->> 'name' = 'F7 Venue Co'
     AND v ->> 'request_endpoint' = 'POST /v1/venue-requests', 'PE6 suggestion ' || coalesce(v::text, 'none');
  -- Never blocked: free text naming V's venue, in every promoter mode, publishes.
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.ev(103);
  ASSERT (SELECT status FROM public.exos_events WHERE id = pg_temp.ev(103)) = 'published', 'PE6 unlisted at a venue on Exos publishes';
  -- Not bypassable: a venue_record event at V's venue still needs V's approval,
  -- and a promoter mode can't carry the link.
  s := pg_temp.st(format($q$UPDATE public.exos_events SET exos_venue_id = %L WHERE id = %L$q$,
                         'f7e00000-0000-0000-0000-0000000000e1', pg_temp.ev(104)));
  ASSERT s LIKE '22023 venue_approval_required%', 'PE6 the gate still holds: ' || s;
  s := pg_temp.st(format($q$UPDATE public.exos_events SET exos_venue_id = %L WHERE id = %L$q$,
                         'f7e00000-0000-0000-0000-0000000000e1', pg_temp.ev(101)));
  ASSERT s LIKE '22023%', 'PE6 a secret event can''t carry the link: ' || s;
  s := pg_temp.st(format($q$UPDATE public.exos_events SET location_mode = 'venue_record', exos_venue_id = %L WHERE id = %L$q$,
                         'f7e00000-0000-0000-0000-0000000000e1', pg_temp.ev(103)));
  ASSERT s LIKE '22023 venue_approval_required%', 'PE6 switching back to a record is gated: ' || s;
  -- Different city or name: no suggestion; a venue not taking requests: none.
  ASSERT jsonb_array_length(public._exos_location_venue_matches(pg_temp.u('00')::uuid, 'Warehouse 9', 'Queens')) = 0
     AND jsonb_array_length(public._exos_location_venue_matches(NULL, 'Warehouse 99', 'Brooklyn')) = 0, 'PE6 exact match only';
  UPDATE public.exos_venues SET accepts_requests = false WHERE id = 'f7e00000-0000-0000-0000-0000000000e1';
  ASSERT jsonb_array_length(public._exos_location_venue_matches(NULL, 'warehouse 9', 'BROOKLYN')) = 0, 'PE6 not taking requests';
  UPDATE public.exos_venues SET accepts_requests = true WHERE id = 'f7e00000-0000-0000-0000-0000000000e1';
  -- Its own venues are never suggested to itself.
  ASSERT jsonb_array_length(public._exos_location_venue_matches('f7e00000-0000-0000-0000-000000000002', 'Warehouse 9', 'Brooklyn')) = 0,
    'PE6 not your own venue';
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000d3');
  s := pg_temp.st($q$SELECT public.exos_location_venue_matches('f7e00000-0000-0000-0000-000000000001', 'Warehouse 9', 'Brooklyn')$q$);
  ASSERT s LIKE '42501%', 'PE6 a stranger can''t ask for an org: ' || s;
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a3');
  ASSERT jsonb_array_length(public.exos_location_venue_matches('f7e00000-0000-0000-0000-000000000001', 'Warehouse 9', 'Brooklyn')) = 1,
    'PE6 content staff see the suggestion';
  PERFORM pg_temp.act('');
  RAISE NOTICE 'OK  PE6 the gate never blocks unlisted / secret / tba, still holds for records; match = suggestion only';
END $$;

-- PE7 ------------------------------------------------------------------------
-- Operator rule (wave 3, mig 20261105150000): no unlimited capacity, and 0
-- closes sales. A promoter-run event needs one type that can sell to go
-- live; a type set to 0 is closed, never refused.
DO $$
DECLARE s text; b jsonb;
BEGIN
  -- A promoter-mode draft whose only type is closed is blocked; venue_record isn't checked here.
  UPDATE public.exos_ticket_tiers SET capacity = 0 WHERE id = 'f7e00000-0000-0000-0000-000000000201';
  b := public._exos_event_publish_blockers(pg_temp.ev(101));
  ASSERT b @> '[{"code":"capacity_required"}]', 'PE7 secret draft with every type closed ' || b::text;
  ASSERT NOT public._exos_event_publish_blockers(pg_temp.ev(104)) @> '[{"code":"capacity_required"}]',
    'PE7 venue_record events are unchanged';
  UPDATE public.exos_ticket_tiers SET capacity = 100 WHERE id = 'f7e00000-0000-0000-0000-000000000201';
  ASSERT NOT public._exos_event_publish_blockers(pg_temp.ev(101)) @> '[{"code":"capacity_required"}]', 'PE7 one open type is enough';
  -- On a live promoter event: 0 closes sales (allowed); a capacity is still required.
  s := pg_temp.st($q$UPDATE public.exos_ticket_tiers SET capacity = 0 WHERE id = 'f7e00000-0000-0000-0000-000000000203'$q$);
  ASSERT s = 'ok', 'PE7 live unlisted can close a type: ' || s;
  s := pg_temp.st($q$UPDATE public.exos_ticket_tiers SET capacity = NULL WHERE id = 'f7e00000-0000-0000-0000-000000000203'$q$);
  ASSERT s <> 'ok', 'PE7 no NULL capacity: ' || s;
  s := pg_temp.st($q$UPDATE public.exos_ticket_tiers SET capacity = -1 WHERE id = 'f7e00000-0000-0000-0000-000000000203'$q$);
  ASSERT s <> 'ok', 'PE7 no negative capacity: ' || s;
  -- Going live with every type closed is refused (direct status write).
  UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.ev(103);
  s := pg_temp.st(format($q$UPDATE public.exos_events SET status = 'published' WHERE id = %L$q$, pg_temp.ev(103)));
  ASSERT s LIKE '22023 location:%capacity%', 'PE7 publish with every type closed refused: ' || s;
  UPDATE public.exos_ticket_tiers SET capacity = 50 WHERE id = 'f7e00000-0000-0000-0000-000000000203';
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.ev(103);
  RAISE NOTICE 'OK  PE7 promoter-mode events: one sellable type to publish, 0 closes sales on a live one; venue_record unchanged';
END $$;

-- PE8 ------------------------------------------------------------------------
DO $$
DECLARE s text; b jsonb; v jsonb;
BEGIN
  -- Secret: reveal after the start is a blocker, and exos_publish_event says so.
  UPDATE public.exos_events SET location_reveal_at = starts_at + interval '1 hour' WHERE id = pg_temp.ev(101);
  b := public._exos_event_publish_blockers(pg_temp.ev(101));
  ASSERT b @> '[{"code":"reveal_after_start"}]', 'PE8 reveal after start ' || b::text;
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  v := public.exos_publish_event(pg_temp.ev(101));
  ASSERT NOT (v ->> 'published')::boolean AND v -> 'blockers' @> '[{"code":"reveal_after_start"}]', 'PE8 publish refused ' || v::text;
  PERFORM pg_temp.act('');
  s := pg_temp.st(format($q$UPDATE public.exos_events SET status = 'published' WHERE id = %L$q$, pg_temp.ev(101)));
  ASSERT s LIKE '22023 location:%', 'PE8 the direct write is refused too: ' || s;
  -- Missing reveal / area / address.
  UPDATE public.exos_events SET location_reveal_at = NULL, venue_location = NULL WHERE id = pg_temp.ev(101);
  b := public._exos_event_publish_blockers(pg_temp.ev(101));
  ASSERT b @> '[{"code":"missing_reveal_time"},{"code":"missing_location_area"}]' AND NOT b @> '[{"code":"missing_venue"}]',
    'PE8 secret blockers ' || b::text;
  ASSERT public._exos_event_publish_blockers(pg_temp.ev(109)) @> '[]' AND NOT public._exos_event_publish_blockers(pg_temp.ev(109)) @> '[{"code":"missing_reveal_time"}]',
    'PE8 other events untouched';
  -- Fixed and published (reveal 24h before).
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_event_location_set(pg_temp.ev(101), '{"area":"Bushwick, Brooklyn","reveal_hours_before":24}');
  v := public.exos_publish_event(pg_temp.ev(101));
  ASSERT (v ->> 'published')::boolean, 'PE8 a complete secret event publishes ' || v::text;
  -- Live: the secret can't be removed, the reveal can't move past the start.
  s := pg_temp.st(format($q$SELECT public.exos_event_location_set(%L, '{"secret_location":null}')$q$, pg_temp.ev(101)));
  ASSERT s LIKE '22023%', 'PE8 a live secret keeps its address: ' || s;
  s := pg_temp.st(format($q$SELECT public.exos_event_location_set(%L, '{"reveal_hours_before":0}')$q$, pg_temp.ev(101)));
  ASSERT s LIKE '22023 location:%', 'PE8 a reveal at the start is refused when live: ' || s;
  PERFORM pg_temp.act('');
  -- A reschedule alone is never refused (the reveal is by the start anyway).
  UPDATE public.exos_events SET starts_at = location_reveal_at - interval '1 hour' WHERE id = pg_temp.ev(101);
  ASSERT (SELECT public._exos_location_reveal_at(location_reveal_at, starts_at) = starts_at FROM public.exos_events WHERE id = pg_temp.ev(101)),
    'PE8 the effective reveal follows an earlier start';
  UPDATE public.exos_events SET starts_at = now() + interval '3 days' WHERE id = pg_temp.ev(101);
  UPDATE public.exos_events SET location_reveal_at = starts_at - interval '24 hours' WHERE id = pg_temp.ev(101);
  RAISE NOTICE 'OK  PE8 blockers: reveal before start, area, address, tba choice; live guard; reschedule allowed';
END $$;
DO $$
DECLARE b jsonb;
BEGIN
  UPDATE public.exos_events SET location_mode = 'unlisted_venue', venue_address = NULL WHERE id = pg_temp.ev(104);
  b := public._exos_event_publish_blockers(pg_temp.ev(104));
  ASSERT b @> '[{"code":"missing_venue_address"}]', 'PE8 unlisted without an address ' || b::text;
  UPDATE public.exos_events SET location_mode = 'venue_record' WHERE id = pg_temp.ev(104);
  ASSERT NOT public._exos_event_publish_blockers(pg_temp.ev(104)) @> '[{"code":"missing_venue_address"}]', 'PE8 a record needs no address';
  RAISE NOTICE 'OK  PE8b unlisted needs a street or city';
END $$;

-- Tickets: d1 holds the secret event (and a wallet pass); d2 holds nothing there.
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, owner_id, buyer_id, status, barcode_secret) VALUES
  ('f7e00000-0000-0000-0000-000000000301', pg_temp.ev(101), 'f7e00000-0000-0000-0000-000000000001',
   'f7e00000-0000-0000-0000-000000000201', 'GA', pg_temp.u('d1'), pg_temp.u('d1'), 'active', repeat('ab', 32)),
  ('f7e00000-0000-0000-0000-000000000302', pg_temp.ev(101), 'f7e00000-0000-0000-0000-000000000001',
   'f7e00000-0000-0000-0000-000000000201', 'GA', pg_temp.u('d2'), pg_temp.u('d2'), 'voided', repeat('cd', 32));
INSERT INTO public.exos_wallet_passes (serial_number, ticket_id, owner_id, status)
VALUES ('exwf7e00000000000000000000000000301', 'f7e00000-0000-0000-0000-000000000301', pg_temp.u('d1'), 'active');
INSERT INTO f7 VALUES ('link1', public._exos_ticket_link_key('f7e00000-0000-0000-0000-000000000301', pg_temp.u('d1'), repeat('ab', 32)));
INSERT INTO f7 VALUES ('link2', public._exos_ticket_link_key('f7e00000-0000-0000-0000-000000000302', pg_temp.u('d2'), repeat('cd', 32)));
-- A geocoded pin from before (as exos-geocode would store it): dropped / never stored.
DO $$
BEGIN
  PERFORM public.exos_upsert_event_geo(pg_temp.ev(101), 'ZQX-SECRET 77 Kent Ave', 'ok', 'place-x', 40.7, -73.9, 'ZQX-SECRET 77 Kent Ave, Brooklyn', NULL);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_geo WHERE event_id = pg_temp.ev(101)), 'PE9 no pin stored for a secret event';
  PERFORM public.exos_upsert_event_geo(pg_temp.ev(103), '9 Dock St, Brooklyn', 'ok', 'place-y', 40.7, -73.9, '9 Dock St', NULL);
  ASSERT EXISTS (SELECT 1 FROM public.exos_public_event_geo WHERE event_id = pg_temp.ev(103)), 'PE9 an unlisted venue''s pin is public';
  UPDATE public.exos_events SET location_mode = 'tba', venue_name = NULL, venue_address = NULL, tba_allow_sales = true WHERE id = pg_temp.ev(103);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_geo WHERE event_id = pg_temp.ev(103)), 'PE9 going tba drops the pin';
  UPDATE public.exos_events SET location_mode = 'unlisted_venue', venue_name = 'Warehouse 9',
         venue_address = '{"street":"9 Dock St","city":"Brooklyn"}' WHERE id = pg_temp.ev(103);
END $$;

-- PE9 ------------------------------------------------------------------------
-- Before the reveal (it is 2 days away): nowhere but the secret table.
DO $$
DECLARE v jsonb; r record; t text;
BEGIN
  ASSERT pg_temp.where_is('ZQX-SECRET') = ARRAY['exos_event_secret_locations'],
    'PE9 only the secret table holds it: ' || array_to_string(pg_temp.where_is('ZQX-SECRET'), ', ');
  -- Every public / feed / partner / API JSON builder of the event.
  FOR r IN SELECT p.oid::regprocedure AS f FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.pronargs = 1 AND p.proargtypes[0] = 'uuid'::regtype
              AND p.proname IN ('_exos_public_event_json', '_exos_discovery_event_json', '_exos_mail_event_json',
                                '_exos_api_event_json', '_exos_rec_public', 'exos_public_event_sale', '_exos_feed_lines',
                                '_exos_event_location_json') LOOP
    EXECUTE format('SELECT to_jsonb(%s(%L))::text', r.f::oid::regproc, pg_temp.ev(101)) INTO t;
    ASSERT coalesce(t, '') NOT LIKE '%ZQX-SECRET%', 'PE9 ' || r.f::text || ' carries the secret';
  END LOOP;
  t := public._exos_listing_feed_event((SELECT e FROM public.exos_events e WHERE e.id = pg_temp.ev(101)))::text;
  ASSERT t NOT LIKE '%ZQX-SECRET%' AND t LIKE '%Bushwick%', 'PE9 the listing feed shows the area only';
  SELECT jsonb_agg(to_jsonb(c))::text INTO t FROM public.exos_calendar_event_rows(ARRAY[pg_temp.ev(101)], NULL) c;
  ASSERT coalesce(t, '') NOT LIKE '%ZQX-SECRET%', 'PE9 calendar rows';
  t := public._exos_cohost_events('f7e00000-0000-0000-0000-000000000002')::text;
  ASSERT coalesce(t, '') NOT LIKE '%ZQX-SECRET%', 'PE9 co-host view';
  t := public._exos_wallet_payload('exwf7e00000000000000000000000000301')::text;
  ASSERT t NOT LIKE '%ZQX-SECRET%' AND t NOT LIKE '%"lat": 40%', 'PE9 the wallet pass before reveal ' || t;
  -- Holders before the reveal: the area and the time, no address.
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000d1');
  v := public.exos_event_location(pg_temp.ev(101));
  ASSERT v ->> 'viewer' = 'holder' AND NOT (v ->> 'revealed')::boolean AND jsonb_typeof(v -> 'secret_location') = 'null'
     AND v::text NOT LIKE '%ZQX-SECRET%', 'PE9 holder before reveal ' || v::text;
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000d3');
  v := public.exos_event_location(pg_temp.ev(101));
  ASSERT v ->> 'viewer' = 'public' AND v::text NOT LIKE '%ZQX-SECRET%', 'PE9 stranger';
  PERFORM pg_temp.act('');
  v := public.exos_ticket_link_location('f7e00000-0000-0000-0000-000000000301', pg_temp.v('link1'));
  ASSERT (v ->> 'ok')::boolean AND v::text NOT LIKE '%ZQX-SECRET%', 'PE9 link before reveal';
  -- Partners: a distribution partner reserves on the secret event and sees no address.
  v := public._exos_dist_partner_create('f7e00000-0000-0000-0000-000000000001', 'F7 Partner', 'stubhub', ARRAY['inventory'],
                                        pg_temp.u('a1'), NULL);
  INSERT INTO f7 VALUES ('partner', v ->> 'id');
  INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled)
  VALUES ('f7e00000-0000-0000-0000-000000000201', pg_temp.ev(101), 'f7e00000-0000-0000-0000-000000000001', true);
  v := public._exos_partner_reserve('f7e00000-0000-0000-0000-000000000001', pg_temp.ev(101), (v ->> 'id')::uuid, NULL,
         jsonb_build_array(jsonb_build_object('ticket_type_id', 'f7e00000-0000-0000-0000-000000000201', 'quantity', 1)), '{}');
  ASSERT v ->> 'token' IS NOT NULL AND v::text NOT LIKE '%ZQX-SECRET%', 'PE9 partner reservation works, no address ' || v::text;
  ASSERT public._exos_partner_reservation_json((SELECT id FROM public.exos_partner_reservations WHERE token = v ->> 'token'))::text
         NOT LIKE '%ZQX-SECRET%', 'PE9 partner reservation json';
  RAISE NOTICE 'OK  PE9a before reveal: only the secret table; JSON builders, feeds, wallet, partners, holders: area only';
END $$;
-- anon and a stranger sweep every relation they may read.
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT 'exos_events' = ANY (pg_temp.sweep('Bushwick')), 'PE9 control: anon''s sweep reads the published event (its area)';
  ASSERT pg_temp.sweep('ZQX-SECRET') = '{}', 'PE9 anon finds it in ' || array_to_string(pg_temp.sweep('ZQX-SECRET'), ', ');
  ASSERT NOT (public.exos_ticket_link_location('f7e00000-0000-0000-0000-000000000301', repeat('A', 43)) ->> 'ok')::boolean,
    'PE9 a wrong link key answers nothing';
END $$;
RESET ROLE;
SELECT pg_temp.act('f7e00000-0000-0000-0000-0000000000d3');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT 'exos_events' = ANY (pg_temp.sweep('Bushwick')), 'PE9 control: the stranger''s sweep reads the published event';
  ASSERT pg_temp.sweep('ZQX-SECRET') = '{}', 'PE9 a stranger finds it in ' || array_to_string(pg_temp.sweep('ZQX-SECRET'), ', ');
END $$;
-- A holder (before the reveal) finds it nowhere either.
SELECT pg_temp.act('f7e00000-0000-0000-0000-0000000000d1');
DO $$
BEGIN
  ASSERT pg_temp.sweep('ZQX-SECRET') = '{}', 'PE9 a holder before the reveal finds it in ' || array_to_string(pg_temp.sweep('ZQX-SECRET'), ', ');
  RAISE NOTICE 'OK  PE9b anon, a stranger and a holder sweep every readable relation: nothing';
END $$;
RESET ROLE;

-- PE10 -----------------------------------------------------------------------
-- The reveal time passes (read time: no cron needed for the ticket page).
UPDATE public.exos_events SET location_reveal_at = now() - interval '1 minute' WHERE id = pg_temp.ev(101);
DO $$
DECLARE v jsonb; t text;
BEGIN
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000d1');
  v := public.exos_event_location(pg_temp.ev(101));
  ASSERT v ->> 'viewer' = 'holder' AND (v ->> 'revealed')::boolean
     AND v -> 'secret_location' -> 'address' ->> 'street' = 'ZQX-SECRET 77 Kent Ave'
     AND v -> 'secret_location' ->> 'directions' = 'Blue door, ring twice', 'PE10 holder after reveal ' || v::text;
  -- d2's ticket is voided: no address.
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000d2');
  v := public.exos_event_location(pg_temp.ev(101));
  ASSERT v ->> 'viewer' = 'public' AND v::text NOT LIKE '%ZQX-SECRET%', 'PE10 a voided ticket gets nothing';
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000d3');
  ASSERT public.exos_event_location(pg_temp.ev(101))::text NOT LIKE '%ZQX-SECRET%', 'PE10 a stranger after reveal: nothing';
  PERFORM pg_temp.act('');
  v := public.exos_ticket_link_location('f7e00000-0000-0000-0000-000000000301', pg_temp.v('link1'));
  ASSERT v -> 'secret_location' -> 'address' ->> 'street' = 'ZQX-SECRET 77 Kent Ave', 'PE10 the live link after reveal';
  v := public.exos_ticket_link_location('f7e00000-0000-0000-0000-000000000302', pg_temp.v('link2'));
  ASSERT v::text NOT LIKE '%ZQX-SECRET%', 'PE10 a voided ticket''s link: nothing';
  t := public._exos_wallet_payload('exwf7e00000000000000000000000000301')::text;
  ASSERT t LIKE '%ZQX-SECRET 77 Kent Ave%', 'PE10 the wallet pass carries it';
  -- Still nowhere public.
  ASSERT public._exos_public_event_json(pg_temp.ev(101))::text NOT LIKE '%ZQX-SECRET%'
     AND public._exos_listing_feed_event((SELECT e FROM public.exos_events e WHERE e.id = pg_temp.ev(101)))::text NOT LIKE '%ZQX-SECRET%'
     AND public._exos_api_event_json(pg_temp.ev(101))::text NOT LIKE '%ZQX-SECRET%', 'PE10 public paths after reveal: nothing';
  RAISE NOTICE 'OK  PE10 after reveal: holders (account, live link, wallet) only; voided tickets and strangers nothing';
END $$;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.sweep('ZQX-SECRET') = '{}', 'PE10 anon after reveal finds it in ' || array_to_string(pg_temp.sweep('ZQX-SECRET'), ', ');
END $$;
RESET ROLE;

-- PE11 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; n int;
BEGIN
  -- d1 opted in to the org's texts; the org has a connected Twilio number.
  INSERT INTO public.exos_org_integrations (org_id, provider, status)
  VALUES ('f7e00000-0000-0000-0000-000000000001', 'twilio', 'connected');
  INSERT INTO public.exos_sms_subscribers (org_id, phone, user_id, consent_text)
  VALUES ('f7e00000-0000-0000-0000-000000000001', '+12125550101', pg_temp.u('d1'), 'Yes, text me about F7 Collective events please.');
  v := public.exos_send_location_notices(100);
  ASSERT (v ->> 'queued')::int >= 1 AND (v ->> 'sent')::int >= 2, 'PE11 reveal queued, reveal + announcement sent ' || v::text;
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'location-revealed' AND to_email = 'f7-holder1@x.com'
            AND html LIKE '%ZQX-SECRET 77 Kent Ave%' AND html LIKE '%Blue door%') = 1, 'PE11 the holder''s reveal mail';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE html LIKE '%ZQX-SECRET%' AND to_email <> 'f7-holder1@x.com'),
    'PE11 nobody else is mailed the address (voided, staff, strangers)';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'location-announced' AND to_email = 'f7-holder2@x.com'
            AND html LIKE '%5 Lot Rd%') = 1, 'PE11 the tba holder hears where it is';
  ASSERT (SELECT count(*) FROM public.exos_sms_outbox WHERE phone = '+12125550101' AND body LIKE '%ZQX-SECRET%' AND body LIKE '%Reply STOP%') = 1,
    'PE11 the opted-in holder''s text';
  ASSERT (SELECT push_pending FROM public.exos_wallet_passes WHERE serial_number = 'exwf7e00000000000000000000000000301'), 'PE11 the pass refreshes';
  ASSERT (SELECT notified_version = version FROM public.exos_event_secret_locations WHERE event_id = pg_temp.ev(101)), 'PE11 marked sent';
  -- Again: nothing new.
  v := public.exos_send_location_notices(100);
  ASSERT (v ->> 'queued')::int = 0 AND (v ->> 'sent')::int = 0, 'PE11 a rerun sends nothing ' || v::text;
  -- The address changes after the reveal: holders get the new one, once.
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_event_location_set(pg_temp.ev(101), jsonb_build_object('secret_location', jsonb_build_object(
           'venue_name', 'Warehouse 9', 'address', jsonb_build_object('street', 'ZQX-SECRET 80 Kent Ave', 'city', 'Brooklyn'))));
  PERFORM pg_temp.act('');
  v := public.exos_send_location_notices(100);
  ASSERT (v ->> 'sent')::int = 1, 'PE11 the change is sent ' || v::text;
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'location-revealed' AND to_email = 'f7-holder1@x.com';
  ASSERT n = 2 AND EXISTS (SELECT 1 FROM public.exos_mail WHERE subject LIKE 'New location:%' AND html LIKE '%80 Kent Ave%'),
    'PE11 the new address mail';
  -- Same content saved again: no new version, no mail.
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_event_location_set(pg_temp.ev(101), jsonb_build_object('secret_location', jsonb_build_object(
           'venue_name', 'Warehouse 9', 'address', jsonb_build_object('street', 'ZQX-SECRET 80 Kent Ave', 'city', 'Brooklyn'))));
  PERFORM pg_temp.act('');
  ASSERT (public.exos_send_location_notices(100) ->> 'sent')::int = 0, 'PE11 an unchanged save sends nothing';
  -- Where the address is now: the secret table and the holder's mail / text only.
  ASSERT pg_temp.where_is('ZQX-SECRET') <@ ARRAY['exos_event_secret_locations', 'exos_mail', 'exos_sms_campaigns', 'exos_sms_outbox'],
    'PE11 after sending: ' || array_to_string(pg_temp.where_is('ZQX-SECRET'), ', ');
  ASSERT NOT has_table_privilege('anon', 'public.exos_mail', 'SELECT') AND NOT has_table_privilege('authenticated', 'public.exos_mail', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_sms_outbox', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_sms_campaigns', 'SELECT'), 'PE11 and no client reads those';
  -- Not before its time: a secret event whose reveal is ahead queues nothing.
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_location_notices WHERE event_id = pg_temp.ev(109)), 'PE11 nothing for others';
  -- The cron is service-role only.
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_send_location_notices(integer)', 'EXECUTE'), 'PE11 cron fn';
  RAISE NOTICE 'OK  PE11 notices: reveal once per address version, announcement, SMS opt-ins, wallet refresh, rerun-safe';
END $$;

-- PE12 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text; id uuid;
BEGIN
  v := pg_temp.w('event.create', NULL, jsonb_build_object('event', jsonb_build_object(
         'name', 'F7 API Secret', 'starts_at', now() + interval '8 days', 'timezone', 'America/New_York',
         'location_mode', 'secret_location', 'venue_location', 'Red Hook', 'location_reveal_at', now() + interval '7 days',
         'secret_location', jsonb_build_object('address', jsonb_build_object('street', 'ZQX-API 1 Pier', 'city', 'Brooklyn'))),
         'ticket_types', jsonb_build_array(jsonb_build_object('name', 'GA', 'price', 0, 'capacity', 30, 'ticket_type', 'free'))));
  id := (v ->> 'id')::uuid;
  ASSERT v -> 'location' ->> 'location_mode' = 'secret_location' AND v -> 'location' ->> 'venue_location' = 'Red Hook'
     AND v::text NOT LIKE '%ZQX-API%', 'PE12 created, the answer has no address ' || v::text;
  ASSERT (SELECT address ->> 'street' FROM public.exos_event_secret_locations WHERE event_id = id) = 'ZQX-API 1 Pier', 'PE12 secret saved';
  ASSERT NOT (v -> 'publish_blockers') @> '[{"code":"missing_secret_address"}]', 'PE12 complete';
  v := pg_temp.w('event.publish', id::text);
  ASSERT (v ->> 'published')::boolean, 'PE12 published through the API ' || v::text;
  -- Update: a new address and a public field in one call.
  v := pg_temp.w('event.update', id::text, jsonb_build_object('event', jsonb_build_object('venue_location', 'Red Hook, Brooklyn',
         'secret_location', jsonb_build_object('address', jsonb_build_object('street', 'ZQX-API 2 Pier')))));
  ASSERT v -> 'location' ->> 'venue_location' = 'Red Hook, Brooklyn'
     AND (SELECT address ->> 'street' FROM public.exos_event_secret_locations WHERE event_id = id) = 'ZQX-API 2 Pier', 'PE12 updated';
  -- A public address on a secret event is refused; so is a bad mode.
  s := pg_temp.st(format($q$SELECT pg_temp.w('event.update', %L, '{"event":{"venue_address":{"street":"2 Pier"}}}')$q$, id));
  ASSERT s LIKE '22023%', 'PE12 public address refused: ' || s;
  s := pg_temp.st(format($q$SELECT pg_temp.w('event.update', %L, '{"event":{"location_mode":"underground"}}')$q$, id));
  ASSERT s LIKE '23514%', 'PE12 bad mode: ' || s;
  -- tba through the API: the choice is a field.
  v := pg_temp.w('event.create', NULL, jsonb_build_object('event', jsonb_build_object(
         'name', 'F7 API TBA', 'starts_at', now() + interval '20 days', 'timezone', 'America/New_York',
         'location_mode', 'tba', 'tba_allow_sales', true)));
  ASSERT v -> 'location' ->> 'tba_allow_sales' = 'true' AND NOT (v -> 'publish_blockers') @> '[{"code":"missing_venue"}]',
    'PE12 tba event ' || v::text;
  RAISE NOTICE 'OK  PE12 partner API: create / update take location fields and secret_location; answers never carry it';
END $$;

-- PE13 -----------------------------------------------------------------------
DO $$
DECLARE s text;
BEGIN
  -- X's owner and X's key can't touch P's location.
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000c1');
  s := pg_temp.st(format($q$SELECT public.exos_event_location_set(%L, '{"location_mode":"tba"}')$q$, pg_temp.ev(101)));
  ASSERT s LIKE '42501%', 'PE13 another org''s owner: ' || s;
  ASSERT public.exos_event_location(pg_temp.ev(101)) ->> 'viewer' = 'public'
     AND public.exos_event_location(pg_temp.ev(101))::text NOT LIKE '%ZQX-SECRET%', 'PE13 another org sees the public part';
  s := pg_temp.st(format($q$SELECT public.exos_event_location(%L)$q$, pg_temp.ev(109)));
  ASSERT s = 'ok', 'PE13 its own draft';
  PERFORM pg_temp.act('f7e00000-0000-0000-0000-0000000000a1');
  s := pg_temp.st(format($q$SELECT public.exos_event_location(%L)$q$, pg_temp.ev(109)));
  ASSERT s LIKE 'P0002%', 'PE13 another org''s draft is not found: ' || s;
  PERFORM pg_temp.act('');
  s := pg_temp.st(format($q$SELECT public._exos_event_location_set('f7e00000-0000-0000-0000-000000000003', %L, %L, '{"location_mode":"tba"}')$q$,
                         pg_temp.ev(101), pg_temp.u('c1')));
  ASSERT s LIKE 'P0002%', 'PE13 the core pins the org: ' || s;
  s := pg_temp.st(format($q$SELECT pg_temp.w('event.update', %L, '{"event":{"secret_location":{"address":{"street":"x"}}}}', 'f3')$q$, pg_temp.ev(101)));
  ASSERT s LIKE 'P0002%', 'PE13 another org''s key: ' || s;
  ASSERT (SELECT address ->> 'street' FROM public.exos_event_secret_locations WHERE event_id = pg_temp.ev(101)) = 'ZQX-SECRET 80 Kent Ave',
    'PE13 unchanged';
END $$;
SELECT pg_temp.act('f7e00000-0000-0000-0000-0000000000c1');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_secret_locations) = 0
     AND (SELECT count(*) FROM public.exos_event_location_notices) = 0, 'PE13 another org reads no secret or notice rows';
END $$;
SELECT pg_temp.act('f7e00000-0000-0000-0000-0000000000a3');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_location_notices) >= 2, 'PE13 the org''s content staff read its notices';
  RAISE NOTICE 'OK  PE13 cross-org isolation: RPCs, cores, keys, RLS';
END $$;
RESET ROLE;

\echo 'test_promoter_events: all passed'
ROLLBACK;
