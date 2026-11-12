-- ============================================================================
-- Fair days (mig 20261113110000)
--   FD0 grants, helpers private, markers, schema checks
--   FD1 exos_fair_setup: owner / manager only (scanner, finance, another org
--       refused, same message for an unknown event); bad plans refused with
--       nothing written (one transaction); the rows it writes (types with
--       max_entry_days, add-ons with their own codes, day lists, the lot
--       list); the event's end; one audit row; a second run refused
--   FD2 no re-entry preset: list validity per day (wrong day = wrong-list,
--       outside the day's hours = invalid-time), once per day (two gates of
--       one day share it), the 3-day pass on each day, the any-day pass on
--       one day only ('day-limit'), a 2-day flex pass
--   FD3 same-day re-entry preset: in / out / in on one day, the any-day pass
--       still one day, a 3-day pass inside on day 1 enters day 2
--   FD4 lot list isolation: a ticket at the lot is 'addon-only-list', a
--       parking / camping code at a day list is 'tickets-only-list', the lot
--       takes both with in / out, another event's code is refused
--   FD5 offline replay and by name follow the day rule; a refused replay
--       logs 'used' and writes no forced row; the roster's list_state covers
--       day lists
--   FD7 the security review of 3610a22: a voided / mid-transfer ticket is
--       refused at a day list (the interleaved case is race_fair_day.sh
--       races 4-5); every prior entry counts, whatever its list: a no-list
--       entry then a day list the same day is 'used', an ordinary-list entry
--       on another day uses an any-day pass's day, a deleted list's entry
--       still counts (by its scan's local date); the roster's day keys;
--       _exos_event_tz falls back to UTC
--   FD8 the Applier's review: two re-entry lists of one day share in / out
--       (scan, by name, offline replay), the day limit on re-entry lists, a
--       scan's local date must be the list's day (wrong_day, live and
--       offline; after midnight inside the day's window is that day)
--   FD6 exos_door_throughput: 15-minute buckets per gate and list (tickets
--       and lot), gate totals (devices, peak), in-park now on re-entry lists
--       (a person inside counted once), refusals by reason; scanner of the
--       event allowed; another org, an unassigned scanner and bad arguments
--       refused
-- Self-contained (BEGIN / ROLLBACK). Org 1: oa owner, ma manager, fa finance,
-- sa scanner (unscoped), sb scanner assigned to e9b only. Org 2: ob owner.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid PRIMARY KEY, display_name text);

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT md5('fd:' || p)::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '{"email":"gate@x.com"}', true);
$$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
-- A ticket's T- code (day-key MAC) in the window of p_at.
CREATE FUNCTION pg_temp.tcode(p_ticket uuid, p_at timestamptz) RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' || public._exos_door_code_mac(t.id, t.owner_id, b, t.barcode_secret)
    FROM public.exos_tickets t, (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint AS b) x
   WHERE t.id = p_ticket
$$;
-- An add-on pass's A- code.
CREATE FUNCTION pg_temp.acode(p_pass uuid, p_at timestamptz) RETURNS text LANGUAGE sql AS $$
  SELECT 'A-' || p.id || ':' || p.owner_id || ':' || b || ':' || public._exos_door_code_mac(p.id, p.owner_id, b, p.barcode_secret)
    FROM public.exos_addon_passes p, (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint AS b) x
   WHERE p.id = p_pass
$$;
-- A list of an event by name.
CREATE FUNCTION pg_temp.l(p_event text, p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_checkin_lists WHERE event_id = pg_temp.u(p_event) AND name = p_name
$$;
CREATE FUNCTION pg_temp.tier(p_event text, p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_ticket_tiers WHERE event_id = pg_temp.u(p_event) AND name = p_name
$$;
-- Today in the fair's zone (e1 / e2 are in America/Phoenix), and a time
-- p_days ago there.
CREATE FUNCTION pg_temp.today() RETURNS date LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'America/Phoenix')::date
$$;
CREATE FUNCTION pg_temp.at(p_days int, p_time time) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT ((pg_temp.today() - p_days) + p_time) AT TIME ZONE 'America/Phoenix'
$$;
-- The fair's three days (whole local days): day 1 two days ago, day 2
-- yesterday, day 3 today. A scan at noon on days 1 and 2, now on day 3.
CREATE FUNCTION pg_temp.day_at(p_day int) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT CASE p_day WHEN 1 THEN pg_temp.at(2, '12:00') WHEN 2 THEN pg_temp.at(1, '12:00') ELSE now() END
$$;
-- A scan at the door (exos_check_in_ticket, 10 arguments) at day p_day's time.
-- Day 3 is a live scan (no scan time; the code is drawn on the wall clock).
CREATE FUNCTION pg_temp.scan(p_ticket text, p_list uuid, p_day int, p_dir text DEFAULT 'entry') RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  RETURN public.exos_check_in_ticket(pg_temp.u(p_ticket), 'camera', 'verified',
           pg_temp.tcode(pg_temp.u(p_ticket), CASE WHEN p_day = 3 THEN clock_timestamp() ELSE pg_temp.day_at(p_day) END),
           (SELECT event_id FROM public.exos_tickets WHERE id = pg_temp.u(p_ticket)), NULL,
           CASE WHEN p_day = 3 THEN NULL ELSE pg_temp.day_at(p_day) END, 'Gate ' || p_day, p_list, p_dir);
END $$;
CREATE FUNCTION pg_temp.ascan(p_pass uuid, p_event text, p_list uuid, p_dir text DEFAULT 'entry') RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  RETURN public.exos_check_in_ticket(p_pass, 'camera', 'verified', pg_temp.acode(p_pass, clock_timestamp()), pg_temp.u(p_event),
                                     NULL, NULL, 'Lot 1', p_list, p_dir);
END $$;
-- The editor's plan (src/lib/fairSetup.ts builds the same shape).
CREATE FUNCTION pg_temp.plan(p_reentry boolean) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'tiers', jsonb_build_array(
      jsonb_build_object('key', 'day-1', 'name', 'Day pass · Day 1', 'price_cents', 1500, 'capacity', 1000),
      jsonb_build_object('key', 'day-2', 'name', 'Day pass · Day 2', 'price_cents', 1500, 'capacity', 1000),
      jsonb_build_object('key', 'day-3', 'name', 'Day pass · Day 3', 'price_cents', 1500, 'capacity', 1000),
      jsonb_build_object('key', 'multi', 'name', '3-day pass', 'price_cents', 3500, 'capacity', 500),
      jsonb_build_object('key', 'any', 'name', 'Any-day pass', 'price_cents', 1800, 'capacity', 500, 'max_entry_days', 1),
      jsonb_build_object('key', 'flex', 'name', 'Any 2 days', 'price_cents', 2800, 'capacity', 500, 'max_entry_days', 2)),
    'addons', jsonb_build_array(
      jsonb_build_object('key', 'parking', 'name', 'Parking', 'price_cents', 1000, 'capacity', 300),
      jsonb_build_object('key', 'camping', 'name', 'Camping', 'price_cents', 4500, 'capacity', 40)),
    'lists', jsonb_build_array(
      jsonb_build_object('name', 'Day 1', 'admits', 'tickets', 'tier_keys', jsonb_build_array('day-1', 'multi', 'any', 'flex'),
        'allow_reentry', p_reentry, 'valid_from', pg_temp.at(2, '00:00'), 'valid_until', pg_temp.at(2, '23:59:59'),
        'entry_day', pg_temp.today() - 2),
      jsonb_build_object('name', 'Day 2', 'admits', 'tickets', 'tier_keys', jsonb_build_array('day-2', 'multi', 'any', 'flex'),
        'allow_reentry', p_reentry, 'valid_from', pg_temp.at(1, '00:00'), 'valid_until', pg_temp.at(1, '23:59:59'),
        'entry_day', pg_temp.today() - 1),
      jsonb_build_object('name', 'Day 3', 'admits', 'tickets', 'tier_keys', jsonb_build_array('day-3', 'multi', 'any', 'flex'),
        'allow_reentry', p_reentry, 'valid_from', pg_temp.at(0, '00:00'), 'valid_until', pg_temp.at(0, '23:59:59'),
        'entry_day', pg_temp.today()),
      jsonb_build_object('name', 'Parking & camping', 'admits', 'addons', 'addon_keys', jsonb_build_array('parking', 'camping'),
        'allow_reentry', true, 'valid_from', pg_temp.at(2, '00:00'), 'valid_until', pg_temp.at(0, '23:59:59'))))
$$;
-- A ticket k of event ev on tier tier_name, held by b1.
CREATE FUNCTION pg_temp.mk(p_k text, p_event text, p_tier text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status,
                                   barcode_secret, price_paid, order_ref, channel_source)
  SELECT pg_temp.u(p_k), pg_temp.u(p_event), e.org_id, pg_temp.tier(p_event, p_tier), p_tier, pg_temp.u('b1'),
         pg_temp.u('b1'), 'fd-b1@x.com', 'active', 'sek-' || p_k, 15, 'cs_fd_' || p_k, 'stripe'
    FROM public.exos_events e WHERE e.id = pg_temp.u(p_event)
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('oa'), 'fd-oa@x.com', now()), (pg_temp.u('ma'), 'fd-ma@x.com', now()),
  (pg_temp.u('fa'), 'fd-fa@x.com', now()), (pg_temp.u('sa'), 'fd-sa@x.com', now()),
  (pg_temp.u('sb'), 'fd-sb@x.com', now()), (pg_temp.u('ob'), 'fd-ob@x.com', now()),
  (pg_temp.u('b1'), 'fd-b1@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'County Fair Assn', 'fd-county', pg_temp.u('oa')),
  (pg_temp.u('2'), 'Other Rodeo', 'fd-rodeo', pg_temp.u('ob'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('oa'), 'owner'), (pg_temp.u('1'), pg_temp.u('ma'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('fa'), 'finance'), (pg_temp.u('1'), pg_temp.u('sa'), 'scanner'),
  (pg_temp.u('1'), pg_temp.u('sb'), 'scanner'), (pg_temp.u('2'), pg_temp.u('ob'), 'owner');
-- e1: the fair, no re-entry. e2: the same fair with same-day re-entry. e3:
-- the throughput fixture. e4: cancelled. e9: org 2's rodeo. e9b: another
-- event of org 1 (sb is assigned there only). Doors opened before day 1.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, ends_at, total_tickets, created_by, timezone) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'County Fair', 'fd-fair', 'published', now() - interval '50 hours', now() - interval '80 hours', NULL, 5000, pg_temp.u('oa'), 'America/Phoenix'),
  (pg_temp.u('e2'), pg_temp.u('1'), 'County Fair (re-entry)', 'fd-fair-2', 'published', now() - interval '50 hours', now() - interval '80 hours', NULL, 5000, pg_temp.u('oa'), 'America/Phoenix'),
  (pg_temp.u('e3'), pg_temp.u('1'), 'Gate fixture', 'fd-gates', 'published', now() - interval '5 hours', now() - interval '5 hours', now() + interval '5 hours', 5000, pg_temp.u('oa'), 'America/Phoenix'),
  (pg_temp.u('e4'), pg_temp.u('1'), 'Rained out', 'fd-rain', 'cancelled', now() + interval '5 days', NULL, NULL, 5000, pg_temp.u('oa'), NULL),
  (pg_temp.u('e9'), pg_temp.u('2'), 'Rodeo', 'fd-rodeo-ev', 'published', now() - interval '50 hours', now() - interval '60 hours', NULL, 5000, pg_temp.u('ob'), NULL),
  (pg_temp.u('e9b'), pg_temp.u('1'), 'Livestock show', 'fd-livestock', 'published', now() + interval '3 days', NULL, NULL, 500, pg_temp.u('oa'), NULL);
INSERT INTO public.exos_event_staff (event_id, user_id, org_id) VALUES (pg_temp.u('e9b'), pg_temp.u('sb'), pg_temp.u('1'));

-- FD0 -------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_fair_setup(uuid,jsonb)', 'public.exos_door_throughput(uuid,timestamptz,timestamptz,integer)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'FD0 authenticated runs ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'FD0 anon never runs ' || f;
    ASSERT (SELECT prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'] FROM pg_proc WHERE oid = f::regprocedure),
           'FD0 definer with a pinned search_path: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_checkin_day_refusal(uuid,uuid,uuid,timestamptz)', 'public._exos_event_tz(uuid)', 'public._exos_fair_text(jsonb,text,integer,boolean)',
                           'public._exos_fair_int(jsonb,text,bigint,bigint,boolean)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
           'FD0 helper private: ' || f;
  END LOOP;
  ASSERT position('/* exos: fair days 1 */' in pg_get_functiondef('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure)) > 0
     AND position('/* exos: fair days 2 */' in pg_get_functiondef('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure)) > 0
     AND position('/* exos: fair days 3 */' in pg_get_functiondef('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure)) > 0,
         'FD0 check-in markers';
  ASSERT position('/* exos: fair days 2 */' in pg_get_functiondef('public.exos_door_checkin_by_name(uuid,uuid,text,text,timestamptz,uuid,uuid,text)'::regprocedure)) > 0
     AND position('/* exos: fair days rejects */' in pg_get_functiondef('public.exos_door_checkin_by_name(uuid,uuid,text,text,timestamptz,uuid,uuid,text)'::regprocedure)) > 0,
         'FD0 by-name markers';
  ASSERT position('/* exos: fair days rejects */' in pg_get_functiondef('public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text,uuid,text)'::regprocedure)) > 0,
         'FD0 offline marker';
  ASSERT position('/* exos: fair days roster */' in pg_get_functiondef('public.exos_event_door_roster(uuid,timestamptz)'::regprocedure)) > 0,
         'FD0 roster marker';
  -- The old 8-argument check-in (no lists) is untouched.
  ASSERT position('fair days' in pg_get_functiondef('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text)'::regprocedure)) = 0,
         'FD0 the 8-argument check-in is untouched';
  ASSERT pg_temp.st($q$INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity, max_entry_days)
                       VALUES ('$q$ || pg_temp.u('e1') || $q$', 'x', 1, 1, 0)$q$) LIKE '23514%', 'FD0 max_entry_days >= 1';
  ASSERT pg_temp.st($q$INSERT INTO public.exos_checkin_lists (event_id, name, admits, entry_day)
                       VALUES ('$q$ || pg_temp.u('e1') || $q$', 'x', 'addons', now()::date)$q$) LIKE '23514%', 'FD0 an add-on list has no day';
  RAISE NOTICE 'OK  FD0 grants, private helpers, markers on 4 functions, the old check-in untouched, column checks';
END $$;

-- FD1 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; s text; v_bad jsonb; n_before int; e public.exos_events%ROWTYPE;
BEGIN
  -- Who may run it.
  FOREACH s IN ARRAY ARRAY['sa', 'fa', 'ob', 'b1'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'), pg_temp.plan(false)))
           = '42501 exos_fair_setup: not authorized for this event', 'FD1 refused for ' || s;
  END LOOP;
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'), pg_temp.plan(false))) LIKE '42501%',
         'FD1 signed out refused';
  PERFORM pg_temp.act(pg_temp.u('ob'));
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('nope'), pg_temp.plan(false)))
         = '42501 exos_fair_setup: not authorized for this event', 'FD1 an unknown event reads like another org''s';
  PERFORM pg_temp.act(pg_temp.u('ma'));
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e4'), pg_temp.plan(false))) LIKE '22023%cancelled%',
         'FD1 a cancelled event refused';

  -- Bad plans: refused, and nothing of them is written.
  SELECT (SELECT count(*) FROM public.exos_ticket_tiers WHERE event_id = pg_temp.u('e1'))
       + (SELECT count(*) FROM public.exos_event_addons WHERE event_id = pg_temp.u('e1'))
       + (SELECT count(*) FROM public.exos_checkin_lists WHERE event_id = pg_temp.u('e1')) INTO n_before;
  v_bad := pg_temp.plan(false);
  v_bad := jsonb_set(v_bad, '{lists,3,addon_keys}', '["parking","boats"]');
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'), v_bad)) LIKE '22023%must name add-ons%',
         'FD1 the lot names an add-on not in the plan';
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'),
           jsonb_set(pg_temp.plan(false), '{lists,0,tier_keys}', '["nobody"]'))) LIKE '22023%must name ticket types%', 'FD1 unknown tier key';
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'),
           jsonb_set(pg_temp.plan(false), '{lists,3,entry_day}', to_jsonb(pg_temp.today()::text)))) LIKE '22023%lot list has no fair day%', 'FD1 a lot list with a day';
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'),
           jsonb_set(pg_temp.plan(false), '{tiers,0,price_cents}', '12.5'))) LIKE '22023%price_cents%', 'FD1 cents are whole';
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'),
           jsonb_set(pg_temp.plan(false), '{tiers,1,key}', '"day-1"'))) LIKE '22023%keys are unique%', 'FD1 duplicate key';
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'),
           jsonb_set(pg_temp.plan(false), '{tiers,4,max_entry_days}', '0'))) LIKE '22023%max_entry_days%', 'FD1 day limit at least 1';
  -- 80 hours: always before day 1 opens (local midnight two days ago, 48-72 hours back); 60 failed after local noon.
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'),
           jsonb_set(pg_temp.plan(false), '{lists,0,valid_until}', to_jsonb((now() - interval '80 hours')::text)))) LIKE '22023%close after it opens%',
         'FD1 a window that closes before it opens';
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'),
           jsonb_set(pg_temp.plan(false), '{lists,0,valid_from}', '"Friday"'))) LIKE '22023%can''t be read%', 'FD1 unreadable date';
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'),
           jsonb_build_object('tiers', (pg_temp.plan(false)) -> 'tiers', 'lists', jsonb_build_array((pg_temp.plan(false)) #> '{lists,3}'),
                              'addons', (pg_temp.plan(false)) -> 'addons'))) LIKE '22023%at least one fair-day list%', 'FD1 no day list';
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'), '[]')) LIKE '22023%', 'FD1 not an object';
  ASSERT (SELECT count(*) FROM public.exos_ticket_tiers WHERE event_id = pg_temp.u('e1'))
       + (SELECT count(*) FROM public.exos_event_addons WHERE event_id = pg_temp.u('e1'))
       + (SELECT count(*) FROM public.exos_checkin_lists WHERE event_id = pg_temp.u('e1')) = n_before,
         'FD1 a refused plan writes nothing (one transaction)';

  -- The manager sets e1 up (no re-entry); the owner sets e2 up (same-day re-entry).
  r := public.exos_fair_setup(pg_temp.u('e1'), pg_temp.plan(false));
  ASSERT (r ->> 'ok')::boolean AND jsonb_array_length(r -> 'list_ids') = 4
     AND (SELECT count(*) FROM jsonb_object_keys(r -> 'tier_ids')) = 6
     AND (SELECT count(*) FROM jsonb_object_keys(r -> 'addon_ids')) = 2, 'FD1 the answer: 6 types, 2 add-ons, 4 lists';
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := public.exos_fair_setup(pg_temp.u('e2'), pg_temp.plan(true));
  ASSERT (r ->> 'ok')::boolean, 'FD1 the owner too';

  ASSERT (SELECT max_entry_days FROM public.exos_ticket_tiers WHERE id = pg_temp.tier('e1', 'Any-day pass')) = 1
     AND (SELECT max_entry_days FROM public.exos_ticket_tiers WHERE id = pg_temp.tier('e1', 'Any 2 days')) = 2
     AND (SELECT max_entry_days IS NULL FROM public.exos_ticket_tiers WHERE id = pg_temp.tier('e1', '3-day pass')),
         'FD1 day limits on the types';
  ASSERT (SELECT price = 15 AND capacity = 1000 AND ticket_type = 'paid' AND visibility = 'public'
            FROM public.exos_ticket_tiers WHERE id = pg_temp.tier('e1', 'Day pass · Day 1')), 'FD1 cents become the price column';
  ASSERT (SELECT bool_and(separate_access_barcode) AND count(*) = 2 FROM public.exos_event_addons WHERE event_id = pg_temp.u('e1')),
         'FD1 parking and camping have their own entry codes';
  ASSERT (SELECT entry_day = pg_temp.today() - 2 AND NOT allow_reentry AND admits = 'tickets' AND cardinality(tier_ids) = 4
                 AND org_id = pg_temp.u('1')
            FROM public.exos_checkin_lists WHERE id = pg_temp.l('e1', 'Day 1')), 'FD1 the day 1 list';
  ASSERT (SELECT entry_day IS NULL AND allow_reentry AND admits = 'addons' AND cardinality(addon_ids) = 2 AND tier_ids IS NULL
            FROM public.exos_checkin_lists WHERE id = pg_temp.l('e1', 'Parking & camping')), 'FD1 the lot list';
  ASSERT (SELECT bool_and(allow_reentry) FROM public.exos_checkin_lists WHERE event_id = pg_temp.u('e2')), 'FD1 the re-entry preset';
  SELECT * INTO e FROM public.exos_events WHERE id = pg_temp.u('e1');
  ASSERT e.ends_at = pg_temp.at(0, '23:59:59'), 'FD1 the event ends when the last day closes';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'event.fair_setup'
                                                   AND event_id = pg_temp.u('e1') AND actor_uid = pg_temp.u('ma')) = 1,
         'FD1 one audit row, the manager';

  -- Once per event.
  PERFORM pg_temp.act(pg_temp.u('ma'));
  ASSERT pg_temp.st(format('SELECT public.exos_fair_setup(%L, %L::jsonb)', pg_temp.u('e1'), pg_temp.plan(false))) LIKE '23505%already has fair-day lists%',
         'FD1 a second run refused';
  RAISE NOTICE 'OK  FD1 fair setup: roles, cross-org, bad plans write nothing, the rows, the end, audit, once';
END $$;

-- Tickets on e1 (no re-entry) and e2 (re-entry), all held by b1.
DO $$ BEGIN PERFORM pg_temp.mk(k, 'e1', t) FROM (VALUES ('d1', 'Day pass · Day 1'), ('d1b', 'Day pass · Day 1'), ('m1', '3-day pass'),
  ('a1', 'Any-day pass'), ('f1', 'Any 2 days'), ('a5', 'Any-day pass'), ('a6', 'Any-day pass'), ('m5', '3-day pass'),
  ('m6', '3-day pass')) v(k, t);
  PERFORM pg_temp.mk(k, 'e2', t) FROM (VALUES ('ra1', 'Any-day pass'), ('rm1', '3-day pass'), ('rd3', 'Day pass · Day 3')) v(k, t);
END $$;

-- FD2 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('sa'));
  -- Day pass: its own day only, its hours only, once.
  r := pg_temp.scan('d1', pg_temp.l('e1', 'Day 2'), 2);
  ASSERT r ->> 'reason' = 'wrong-list', 'FD2 a day 1 pass at day 2: ' || r::text;
  r := pg_temp.scan('d1', pg_temp.l('e1', 'Day 1'), 3);
  ASSERT r ->> 'reason' = 'invalid-time', 'FD2 the day 1 list after day 1 closed: ' || r::text;
  r := pg_temp.scan('d1', pg_temp.l('e1', 'Day 1'), 1);
  ASSERT (r ->> 'ok')::boolean, 'FD2 a day 1 pass on day 1: ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.u('d1')) = 'used', 'FD2 the first entry uses the ticket';
  r := pg_temp.scan('d1', pg_temp.l('e1', 'Day 1'), 1);
  ASSERT r ->> 'reason' = 'used' AND r ->> 'day' = (pg_temp.today() - 2)::text AND r ? 'check_in_at', 'FD2 once a day: ' || r::text;

  -- 3-day pass: each day once.
  ASSERT (pg_temp.scan('m1', pg_temp.l('e1', 'Day 1'), 1) ->> 'ok')::boolean, 'FD2 3-day pass day 1';
  r := pg_temp.scan('m1', pg_temp.l('e1', 'Day 2'), 2);
  ASSERT (r ->> 'ok')::boolean, 'FD2 3-day pass day 2 (used yesterday, no re-entry list): ' || r::text;
  ASSERT (pg_temp.scan('m1', pg_temp.l('e1', 'Day 3'), 3) ->> 'ok')::boolean, 'FD2 3-day pass day 3';
  ASSERT pg_temp.scan('m1', pg_temp.l('e1', 'Day 3'), 3) ->> 'reason' = 'used', 'FD2 3-day pass day 3 again';
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.u('m1') AND direction = 'entry') = 3,
         'FD2 three entries recorded';
  ASSERT (SELECT check_in_at FROM public.exos_tickets WHERE id = pg_temp.u('m1')) = pg_temp.day_at(1)
     OR (SELECT check_in_at FROM public.exos_tickets WHERE id = pg_temp.u('m1')) < now() - interval '40 hours',
         'FD2 check_in_at stays the first entry';

  -- Two gates on one day share it: a second day 3 list.
  INSERT INTO public.exos_checkin_lists (event_id, name, tier_ids, allow_reentry, valid_from, valid_until, entry_day)
  SELECT event_id, 'Day 3 north gate', tier_ids, false, valid_from, valid_until, entry_day
    FROM public.exos_checkin_lists WHERE id = pg_temp.l('e1', 'Day 3');
  r := pg_temp.scan('m1', pg_temp.l('e1', 'Day 3 north gate'), 3);
  ASSERT r ->> 'reason' = 'used' AND r ->> 'list' = 'Day 3', 'FD2 the north gate knows the main gate let them in today: ' || r::text;
  ASSERT (pg_temp.scan('m5', pg_temp.l('e1', 'Day 3 north gate'), 3) ->> 'ok')::boolean, 'FD2 north gate admits';
  ASSERT pg_temp.scan('m5', pg_temp.l('e1', 'Day 3'), 3) ->> 'reason' = 'used', 'FD2 then main gate refuses';

  -- Any-day pass: one day.
  ASSERT (pg_temp.scan('a1', pg_temp.l('e1', 'Day 1'), 1) ->> 'ok')::boolean, 'FD2 any-day pass day 1';
  r := pg_temp.scan('a1', pg_temp.l('e1', 'Day 2'), 2);
  ASSERT r ->> 'reason' = 'day-limit' AND (r ->> 'max_days')::int = 1 AND (r ->> 'days_used')::int = 1, 'FD2 any-day pass day 2: ' || r::text;
  ASSERT pg_temp.scan('a1', pg_temp.l('e1', 'Day 3'), 3) ->> 'reason' = 'day-limit', 'FD2 any-day pass day 3';
  ASSERT pg_temp.scan('a1', pg_temp.l('e1', 'Day 1'), 1) ->> 'reason' = 'used', 'FD2 any-day pass day 1 again: once';
  ASSERT (pg_temp.scan('a5', pg_temp.l('e1', 'Day 3'), 3) ->> 'ok')::boolean, 'FD2 another any-day pass picks day 3';

  -- Any 2 days.
  ASSERT (pg_temp.scan('f1', pg_temp.l('e1', 'Day 1'), 1) ->> 'ok')::boolean, 'FD2 flex day 1';
  ASSERT (pg_temp.scan('f1', pg_temp.l('e1', 'Day 3'), 3) ->> 'ok')::boolean, 'FD2 flex day 3';
  r := pg_temp.scan('f1', pg_temp.l('e1', 'Day 2'), 2);
  ASSERT r ->> 'reason' = 'day-limit' AND (r ->> 'days_used')::int = 2, 'FD2 flex: a third day refused: ' || r::text;
  RAISE NOTICE 'OK  FD2 no re-entry: list validity per day, once a day across gates, 3-day pass, any-day one day, flex 2';
END $$;

-- FD3 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('sa'));
  -- Any-day pass with same-day re-entry: in, out, in again on day 1; not day 2.
  ASSERT (pg_temp.scan('ra1', pg_temp.l('e2', 'Day 1'), 1) ->> 'ok')::boolean, 'FD3 in';
  ASSERT pg_temp.scan('ra1', pg_temp.l('e2', 'Day 1'), 1) ->> 'reason' = 'already-inside', 'FD3 in twice';
  r := pg_temp.scan('ra1', pg_temp.l('e2', 'Day 1'), 1, 'exit');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'direction' = 'exit', 'FD3 out: ' || r::text;
  r := pg_temp.scan('ra1', pg_temp.l('e2', 'Day 1'), 1);
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'reentry')::boolean, 'FD3 back in the same day: ' || r::text;
  r := pg_temp.scan('ra1', pg_temp.l('e2', 'Day 2'), 2);
  ASSERT r ->> 'reason' = 'day-limit', 'FD3 any-day pass with re-entry still one day: ' || r::text;
  -- 3-day pass, never scanned out on day 1: day 2 is its own list.
  ASSERT (pg_temp.scan('rm1', pg_temp.l('e2', 'Day 1'), 1) ->> 'ok')::boolean, 'FD3 3-day pass day 1';
  r := pg_temp.scan('rm1', pg_temp.l('e2', 'Day 2'), 2);
  ASSERT (r ->> 'ok')::boolean, 'FD3 3-day pass day 2: ' || r::text;
  ASSERT pg_temp.scan('rm1', pg_temp.l('e2', 'Day 2'), 2) ->> 'reason' = 'already-inside', 'FD3 3-day pass day 2 twice';
  -- Exits are refused without re-entry (e1).
  ASSERT pg_temp.scan('m1', pg_temp.l('e1', 'Day 3'), 3, 'exit') ->> 'reason' = 'exit-not-allowed', 'FD3 no exits on the no re-entry preset';
  -- A day 3 pass, day 3, in and out.
  ASSERT (pg_temp.scan('rd3', pg_temp.l('e2', 'Day 3'), 3) ->> 'ok')::boolean, 'FD3 day 3 pass in';
  ASSERT pg_temp.scan('rd3', pg_temp.l('e2', 'Day 1'), 1) ->> 'reason' = 'wrong-list', 'FD3 day 3 pass at day 1';
  RAISE NOTICE 'OK  FD3 same-day re-entry: in / out / in, the any-day pass one day, a 3-day pass inside day 1 enters day 2';
END $$;

-- Parking and camping bought on e1 and e2 by b1, and a rodeo add-on on e9.
INSERT INTO public.exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode)
VALUES (pg_temp.u('ad9'), pg_temp.u('e9'), 'Rodeo parking', 10, 10, true);
INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source)
SELECT pg_temp.u('ln-' || ev || '-' || a.name), pg_temp.u(ev), a_ev.org_id, a.id, a.name, pg_temp.u('b1'), pg_temp.u('b1'), 1, a.price,
       'cs_fd_' || ev, 'stripe'
  FROM unnest(ARRAY['e1', 'e2', 'e9']) ev
  JOIN public.exos_event_addons a ON a.event_id = pg_temp.u(ev)
  JOIN public.exos_events a_ev ON a_ev.id = a.event_id;
CREATE FUNCTION pg_temp.pass(p_event text, p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_addon_passes WHERE event_id = pg_temp.u(p_event) AND addon_name = p_name
$$;

-- FD4 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_lot uuid := pg_temp.l('e1', 'Parking & camping');
BEGIN
  PERFORM pg_temp.act(pg_temp.u('sa'));
  ASSERT pg_temp.pass('e1', 'Parking') IS NOT NULL AND pg_temp.pass('e1', 'Camping') IS NOT NULL, 'FD4 passes issued';
  -- Lot staff scan only lot products.
  r := pg_temp.scan('m6', v_lot, 3);
  ASSERT r ->> 'reason' = 'addon-only-list', 'FD4 a ticket at the lot: ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.u('m6')) = 'active', 'FD4 and the ticket is still good';
  r := pg_temp.ascan(pg_temp.pass('e1', 'Parking'), 'e1', pg_temp.l('e1', 'Day 3'));
  ASSERT r ->> 'reason' = 'tickets-only-list', 'FD4 a parking code at the gate: ' || r::text;
  r := pg_temp.ascan(pg_temp.pass('e1', 'Parking'), 'e1', v_lot);
  ASSERT (r ->> 'ok')::boolean AND r ->> 'kind' = 'addon', 'FD4 parking at the lot: ' || r::text;
  ASSERT (pg_temp.ascan(pg_temp.pass('e1', 'Parking'), 'e1', v_lot, 'exit') ->> 'ok')::boolean, 'FD4 the car leaves';
  ASSERT (pg_temp.ascan(pg_temp.pass('e1', 'Parking'), 'e1', v_lot) ->> 'ok')::boolean, 'FD4 and comes back';
  ASSERT (pg_temp.ascan(pg_temp.pass('e1', 'Camping'), 'e1', v_lot) ->> 'ok')::boolean, 'FD4 camping at the lot';
  ASSERT pg_temp.ascan(pg_temp.pass('e1', 'Camping'), 'e1', v_lot) ->> 'reason' = 'already-inside', 'FD4 camping twice';
  ASSERT pg_temp.st(format('SELECT pg_temp.ascan(%L, %L, %L)', pg_temp.pass('e9', 'Rodeo parking'), 'e1', v_lot))
         = '42501 exos_check_in_ticket: not authorized', 'FD4 another org''s code at this lot: refused before anything is read';
  ASSERT pg_temp.ascan(pg_temp.pass('e2', 'Parking'), 'e1', v_lot) ->> 'reason' = 'wrong-event', 'FD4 the other fair''s code';
  ASSERT pg_temp.ascan(pg_temp.pass('e1', 'Parking'), 'e1', pg_temp.l('e2', 'Parking & camping')) ->> 'reason' = 'unknown-list',
         'FD4 another event''s lot list';
  RAISE NOTICE 'OK  FD4 lot isolation: tickets refused at the lot, lot codes refused at the gates, in / out at the lot, other events refused';
END $$;

-- FD5 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_ref uuid := gen_random_uuid(); n_forced int; st jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('sa'));
  -- An offline replay of the any-day pass a5 (used on day 3) at day 2's list.
  SELECT count(*) INTO n_forced FROM public.exos_event_checkins WHERE forced;
  r := public.exos_check_in_offline(v_ref, pg_temp.u('a5'), pg_temp.u('e1'), pg_temp.day_at(2),
         pg_temp.tcode(pg_temp.u('a5'), pg_temp.day_at(2)), 'camera', NULL, 'Gate 2', pg_temp.l('e1', 'Day 2'), 'entry');
  ASSERT r ->> 'reason' = 'day-limit' AND (r ->> 'conflict')::boolean AND NOT (r ? 'forced'), 'FD5 offline replay refused: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE forced) = n_forced, 'FD5 no forced row for an over-use';
  ASSERT (SELECT reason FROM public.exos_scan_rejects WHERE ticket_id_attempted = pg_temp.u('a5')::text) = 'used',
         'FD5 logged as used';
  ASSERT public.exos_check_in_offline(v_ref, pg_temp.u('a5'), pg_temp.u('e1'), pg_temp.day_at(2),
         pg_temp.tcode(pg_temp.u('a5'), pg_temp.day_at(2)), 'camera', NULL, 'Gate 2', pg_temp.l('e1', 'Day 2'), 'entry') ->> 'duplicate' = 'true',
         'FD5 the same ref again: the first answer';
  -- An offline replay of the 3-day pass m6 on day 2 (unused): admitted.
  r := public.exos_check_in_offline(gen_random_uuid(), pg_temp.u('m6'), pg_temp.u('e1'), pg_temp.day_at(2),
         pg_temp.tcode(pg_temp.u('m6'), pg_temp.day_at(2)), 'camera', NULL, 'Gate 2', pg_temp.l('e1', 'Day 2'), 'entry');
  ASSERT (r ->> 'ok')::boolean, 'FD5 3-day pass replayed on day 2: ' || r::text;
  -- By name: the 3-day pass m6 on day 3 (used day 2) passes; the any-day pass a6 after a day.
  r := public.exos_door_checkin_by_name(pg_temp.u('m6'), pg_temp.u('e1'), 'dead phone', 'Gate 3', NULL, NULL,
                                        pg_temp.l('e1', 'Day 3'), 'entry');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'by_name')::boolean, 'FD5 by name, 3-day pass, day 3: ' || r::text;
  r := public.exos_door_checkin_by_name(pg_temp.u('m6'), pg_temp.u('e1'), 'again', 'Gate 3', NULL, NULL,
                                        pg_temp.l('e1', 'Day 3'), 'entry');
  ASSERT r ->> 'reason' = 'used', 'FD5 by name twice the same day: ' || r::text;
  ASSERT (pg_temp.scan('a6', pg_temp.l('e1', 'Day 2'), 2) ->> 'ok')::boolean, 'FD5 a6 on day 2';
  r := public.exos_door_checkin_by_name(pg_temp.u('a6'), pg_temp.u('e1'), NULL, 'Gate 3', NULL, gen_random_uuid(),
                                        pg_temp.l('e1', 'Day 3'), 'entry');
  ASSERT r ->> 'reason' = 'day-limit' AND (r ->> 'conflict')::boolean, 'FD5 by-name replay, any-day pass on a second day: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_scan_rejects WHERE ticket_id_attempted = pg_temp.u('a6')::text AND reason = 'used'
             AND reason_detail = 'name-replay:day-limit') = 1, 'FD5 by-name replay logged as used';
  -- The saved list: list_state names the day lists a ticket entered.
  SELECT x.list_state INTO st FROM public.exos_event_door_roster(pg_temp.u('e1')) x WHERE x.ticket_id = pg_temp.u('m1');
  ASSERT st ->> pg_temp.l('e1', 'Day 1')::text = 'entry' AND st ->> pg_temp.l('e1', 'Day 2')::text = 'entry'
     AND st ->> pg_temp.l('e1', 'Day 3')::text = 'entry', 'FD5 roster list_state covers day lists: ' || st::text;
  SELECT x.list_state INTO st FROM public.exos_event_door_roster(pg_temp.u('e1')) x WHERE x.ticket_id = pg_temp.u('d1b');
  ASSERT st IS NULL, 'FD5 an unused ticket has no list state';
  RAISE NOTICE 'OK  FD5 offline replay and by name follow the day rule (logged as used, no forced row), roster list_state';
END $$;

-- FD7 -------------------------------------------------------------------------
-- A scan at a given time (offline replay through the door's check-in).
CREATE FUNCTION pg_temp.scan_at(p_ticket text, p_list uuid, p_at timestamptz) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  RETURN public.exos_check_in_ticket(pg_temp.u(p_ticket), 'camera', 'verified', pg_temp.tcode(pg_temp.u(p_ticket), p_at),
           (SELECT event_id FROM public.exos_tickets WHERE id = pg_temp.u(p_ticket)), NULL, p_at, 'Gate X', p_list, 'entry');
END $$;
-- Noon, three days ago, in the fair's zone: a day none of e1's day lists is for.
CREATE FUNCTION pg_temp.t3() RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT ((pg_temp.today() - 3) + time '12:00') AT TIME ZONE 'America/Phoenix'
$$;
DO $$ BEGIN PERFORM pg_temp.mk(k, 'e1', t) FROM (VALUES ('v1', '3-day pass'), ('v2', '3-day pass'), ('x1', '3-day pass'),
  ('n1', '3-day pass'), ('a7', 'Any-day pass'), ('a8', 'Any-day pass')) v(k, t); END $$;
INSERT INTO public.exos_transfers (id, ticket_id, org_id, sender_id, receiver_email, status, event_id, created_at, updated_at)
VALUES (pg_temp.u('tr-x1'), pg_temp.u('x1'), pg_temp.u('1'), pg_temp.u('b1'), 'friend@x.com', 'pending', pg_temp.u('e1'), now(), now());

DO $$
DECLARE r jsonb; st jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('sa'));
  -- (a) voided / mid-transfer at a day list: refused, nothing written.
  UPDATE public.exos_tickets SET status = 'voided' WHERE id = pg_temp.u('v1');
  ASSERT pg_temp.scan('v1', pg_temp.l('e1', 'Day 3'), 3) ->> 'reason' = 'voided', 'FD7 a voided pass at a day list';
  ASSERT (pg_temp.scan('v2', pg_temp.l('e1', 'Day 1'), 1) ->> 'ok')::boolean, 'FD7 v2 in on day 1';
  UPDATE public.exos_tickets SET status = 'voided' WHERE id = pg_temp.u('v2');
  ASSERT pg_temp.scan('v2', pg_temp.l('e1', 'Day 3'), 3) ->> 'reason' = 'voided', 'FD7 used, then refunded: refused on day 3';
  UPDATE public.exos_tickets SET pending_transfer_id = pg_temp.u('tr-x1') WHERE id = pg_temp.u('x1');
  ASSERT pg_temp.scan('x1', pg_temp.l('e1', 'Day 3'), 3) ->> 'reason' = 'in-transfer', 'FD7 mid-transfer at a day list';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkins
                      WHERE ticket_id IN (pg_temp.u('v1'), pg_temp.u('x1')) OR (ticket_id = pg_temp.u('v2') AND gate = 'Day 3')),
         'FD7 no entry written for them';

  -- (b) a scan with no list today, then today's day list: once a day.
  r := pg_temp.scan('n1', NULL, 3);
  ASSERT (r ->> 'ok')::boolean, 'FD7 n1 in through a no-list scan: ' || r::text;
  r := pg_temp.scan('n1', pg_temp.l('e1', 'Day 3'), 3);
  ASSERT r ->> 'reason' = 'used' AND r ->> 'day' = pg_temp.today()::text, 'FD7 then the day 3 list: used: ' || r::text;
  r := public.exos_door_checkin_by_name(pg_temp.u('n1'), pg_temp.u('e1'), NULL, 'Gate 3', NULL, NULL, pg_temp.l('e1', 'Day 3'), 'entry');
  ASSERT r ->> 'reason' = 'used', 'FD7 and by name: ' || r::text;
  ASSERT (pg_temp.scan('n1', pg_temp.l('e1', 'Day 2'), 2) ->> 'ok')::boolean, 'FD7 another day is still its own';

  -- (c) an ordinary list on another day uses an any-day pass's day.
  INSERT INTO public.exos_checkin_lists (id, event_id, name, tier_ids, allow_reentry)
  VALUES (pg_temp.u('l-main'), pg_temp.u('e1'), 'Main gate (any day)', NULL, false);
  r := pg_temp.scan_at('a7', pg_temp.u('l-main'), pg_temp.t3());
  ASSERT (r ->> 'ok')::boolean, 'FD7 a7 in at the ordinary gate: ' || r::text;
  r := pg_temp.scan('a7', pg_temp.l('e1', 'Day 2'), 2);
  ASSERT r ->> 'reason' = 'day-limit' AND (r ->> 'days_used')::int = 1, 'FD7 then day 2: day-limit: ' || r::text;

  -- (d) a deleted list's entry still counts, by its scan's local date.
  INSERT INTO public.exos_checkin_lists (id, event_id, name, tier_ids, allow_reentry, entry_day)
  VALUES (pg_temp.u('l-old'), pg_temp.u('e1'), 'Old gate', NULL, false, pg_temp.today() - 3);
  ASSERT (pg_temp.scan_at('a8', pg_temp.u('l-old'), pg_temp.t3()) ->> 'ok')::boolean, 'FD7 a8 in at the old gate';
  DELETE FROM public.exos_checkin_lists WHERE id = pg_temp.u('l-old');
  ASSERT (SELECT list_id IS NULL AND gate = 'Old gate' FROM public.exos_event_checkins WHERE ticket_id = pg_temp.u('a8')),
         'FD7 the entry stays, its list gone';
  r := pg_temp.scan('a8', pg_temp.l('e1', 'Day 2'), 2);
  ASSERT r ->> 'reason' = 'day-limit', 'FD7 the deleted list''s day still used: ' || r::text;

  -- The roster carries a day key for entries off the day lists.
  SELECT x.list_state INTO st FROM public.exos_event_door_roster(pg_temp.u('e1')) x WHERE x.ticket_id = pg_temp.u('n1');
  ASSERT st ->> ('day:' || pg_temp.today()) = 'entry' AND st ->> pg_temp.l('e1', 'Day 2')::text = 'entry'
     AND NOT st ? ('day:' || (pg_temp.today() - 1)), 'FD7 n1 roster: ' || st::text;
  SELECT x.list_state INTO st FROM public.exos_event_door_roster(pg_temp.u('e1')) x WHERE x.ticket_id = pg_temp.u('a8');
  ASSERT st ->> ('day:' || (pg_temp.today() - 3)) = 'entry', 'FD7 a8 roster (deleted list): ' || st::text;
  SELECT x.list_state INTO st FROM public.exos_event_door_roster(pg_temp.u('e1')) x WHERE x.ticket_id = pg_temp.u('m1');
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_object_keys(st) k WHERE k LIKE 'day:%'), 'FD7 day-list entries need no day key';

  -- The zone helper.
  ASSERT public._exos_event_tz(pg_temp.u('e1')) = 'America/Phoenix' AND public._exos_event_tz(pg_temp.u('e4')) = 'UTC',
         'FD7 event zone, unset = UTC';
  UPDATE public.exos_events SET timezone = 'Mars/Olympus' WHERE id = pg_temp.u('e4');
  ASSERT public._exos_event_tz(pg_temp.u('e4')) = 'UTC', 'FD7 an unknown zone = UTC';
  RAISE NOTICE 'OK  FD7 voided / mid-transfer refused at day lists; every entry counts (no list, ordinary, deleted list); roster day keys';
END $$;

-- FD8 -------------------------------------------------------------------------
-- The Applier's review of wave 13: a fair day's re-entry lists share in / out
-- (two gates of one day), the day limit on re-entry lists, and a scan's local
-- date must be the list's day (live and offline).
INSERT INTO public.exos_checkin_lists (event_id, name, tier_ids, allow_reentry, valid_from, valid_until, entry_day)
SELECT event_id, 'Day 3 north', tier_ids, true, valid_from, valid_until, entry_day
  FROM public.exos_checkin_lists WHERE id = pg_temp.l('e2', 'Day 3');
INSERT INTO public.exos_checkin_lists (id, event_id, name, tier_ids, allow_reentry, valid_from, valid_until, entry_day) VALUES
  (pg_temp.u('l-d2open'), pg_temp.u('e1'), 'Day 2 (no hours)', NULL, false, NULL, NULL, pg_temp.today() - 1),
  (pg_temp.u('l-d1open'), pg_temp.u('e1'), 'Day 1 (no hours)', NULL, false, NULL, NULL, pg_temp.today() - 2),
  (pg_temp.u('l-late'), pg_temp.u('e1'), 'Late night', NULL, false, pg_temp.at(2, '18:00'), pg_temp.at(1, '02:00'), pg_temp.today() - 2);
DO $$ BEGIN
  PERFORM pg_temp.mk(k, 'e2', t) FROM (VALUES ('rm3', '3-day pass'), ('ra2', 'Any-day pass')) v(k, t);
  PERFORM pg_temp.mk(k, 'e1', t) FROM (VALUES ('wd1', '3-day pass'), ('wd2', '3-day pass'), ('wd3', '3-day pass'),
    ('wd4', '3-day pass'), ('wd5', '3-day pass')) v(k, t);
END $$;

DO $$
DECLARE r jsonb; st jsonb; v_a uuid := pg_temp.l('e2', 'Day 3'); v_b uuid := pg_temp.l('e2', 'Day 3 north');
BEGIN
  ASSERT position('/* exos: fair days 4 */' in pg_get_functiondef('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure)) > 0,
         'FD8 marker fair days 4';
  PERFORM pg_temp.act(pg_temp.u('sa'));
  -- Two re-entry gates of one day: in at A, refused at B until an exit.
  ASSERT (pg_temp.scan('rm3', v_a, 3) ->> 'ok')::boolean, 'FD8 in at gate A';
  r := pg_temp.scan('rm3', v_b, 3);
  ASSERT r ->> 'reason' = 'already-inside' AND r ->> 'list' = 'Day 3', 'FD8 in again at gate B, no exit: ' || r::text;
  r := public.exos_door_checkin_by_name(pg_temp.u('rm3'), pg_temp.u('e2'), NULL, 'Gate B', NULL, NULL, v_b, 'entry');
  ASSERT r ->> 'reason' = 'already-inside', 'FD8 and by name at gate B: ' || r::text;
  r := public.exos_check_in_offline(gen_random_uuid(), pg_temp.u('rm3'), pg_temp.u('e2'), clock_timestamp(),
         pg_temp.tcode(pg_temp.u('rm3'), clock_timestamp()), 'camera', NULL, 'Gate B', v_b, 'entry');
  ASSERT r ->> 'reason' = 'already-inside' AND NOT (r ? 'forced'), 'FD8 and an offline replay at gate B: ' || r::text;
  ASSERT (pg_temp.scan('rm3', v_b, 3, 'exit') ->> 'ok')::boolean, 'FD8 out at gate B';
  r := pg_temp.scan('rm3', v_a, 3);
  ASSERT (r ->> 'ok')::boolean, 'FD8 back in at gate A after leaving by B: ' || r::text;
  ASSERT pg_temp.scan('rm3', v_b, 3) ->> 'reason' = 'already-inside', 'FD8 and inside again';
  SELECT x.list_state INTO st FROM public.exos_event_door_roster(pg_temp.u('e2')) x WHERE x.ticket_id = pg_temp.u('rm3');
  ASSERT st ->> ('dayin:' || pg_temp.today()) = 'entry', 'FD8 roster: the day''s last direction: ' || st::text;
  r := public.exos_door_throughput(pg_temp.u('e2'), now() - interval '1 day', now() + interval '1 minute', 60);
  ASSERT (SELECT count(DISTINCT x ->> 'tickets_inside') = 1 FROM jsonb_array_elements(r -> 'inside') x
           WHERE x ->> 'name' IN ('Day 3', 'Day 3 north')), 'FD8 throughput: one day, one inside count';

  -- The day limit holds on re-entry lists; re-entering the day used is not a new day.
  ASSERT (pg_temp.scan('ra2', pg_temp.l('e2', 'Day 1'), 1) ->> 'ok')::boolean, 'FD8 ra2 in day 1';
  ASSERT (pg_temp.scan('ra2', pg_temp.l('e2', 'Day 1'), 1, 'exit') ->> 'ok')::boolean, 'FD8 ra2 out';
  ASSERT (pg_temp.scan('ra2', pg_temp.l('e2', 'Day 1'), 1) ->> 'ok')::boolean, 'FD8 ra2 back in day 1';
  ASSERT (pg_temp.scan('ra2', pg_temp.l('e2', 'Day 1'), 1, 'exit') ->> 'ok')::boolean, 'FD8 ra2 out again';
  r := pg_temp.scan('ra2', pg_temp.l('e2', 'Day 2'), 2);
  ASSERT r ->> 'reason' = 'day-limit' AND (r ->> 'days_used')::int = 1, 'FD8 any-day pass, re-entry list, a second day: ' || r::text;

  -- The scan's local date must be the list's day (no hours on these lists).
  r := pg_temp.scan_at('wd1', pg_temp.u('l-d2open'), pg_temp.day_at(1));
  ASSERT r ->> 'reason' = 'invalid-time' AND (r ->> 'wrong_day')::boolean, 'FD8 a day-1 time on the day-2 list: ' || r::text;
  r := pg_temp.scan_at('wd2', pg_temp.u('l-d1open'), pg_temp.day_at(2));
  ASSERT r ->> 'reason' = 'invalid-time' AND (r ->> 'wrong_day')::boolean, 'FD8 a day-2 time on the day-1 list: ' || r::text;
  r := pg_temp.scan('wd5', pg_temp.u('l-d2open'), 3);
  ASSERT r ->> 'reason' = 'invalid-time' AND (r ->> 'wrong_day')::boolean, 'FD8 a live scan today on the day-2 list: ' || r::text;
  ASSERT (pg_temp.scan_at('wd1', pg_temp.u('l-d2open'), pg_temp.day_at(2)) ->> 'ok')::boolean, 'FD8 its own day: in';
  -- With hours: the window refuses first (no wrong_day needed).
  r := pg_temp.scan_at('wd2', pg_temp.l('e1', 'Day 2'), pg_temp.day_at(1));
  ASSERT r ->> 'reason' = 'invalid-time', 'FD8 a day-1 time on the windowed day-2 list: ' || r::text;
  -- An offline replay refused this way is recorded as attended (forced), like any invalid-time.
  r := public.exos_check_in_offline(gen_random_uuid(), pg_temp.u('wd3'), pg_temp.u('e1'), pg_temp.day_at(1),
         pg_temp.tcode(pg_temp.u('wd3'), pg_temp.day_at(1)), 'camera', NULL, 'Gate 2', pg_temp.u('l-d2open'), 'entry');
  ASSERT r ->> 'reason' = 'invalid-time' AND (r ->> 'forced')::boolean AND r ->> 'conflict_reason' = 'invalid-time',
         'FD8 offline replay, day-1 time on the day-2 list: refused, recorded: ' || r::text;
  -- After midnight inside a window that opens on the list's day: that day.
  r := pg_temp.scan_at('wd4', pg_temp.u('l-late'), pg_temp.at(1, '00:30'));
  ASSERT (r ->> 'ok')::boolean, 'FD8 00:30 on a late night that opened the day before: ' || r::text;
  RAISE NOTICE 'OK  FD8 a day''s re-entry gates share in / out (scan, by name, offline), day limit on re-entry, the scan''s day must be the list''s';
END $$;

-- FD6 -------------------------------------------------------------------------
-- e3: two gates (Main re-entry, North no re-entry) and a lot, scans at fixed
-- times in one 15-minute bucket and the next.
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity) VALUES (pg_temp.u('t3'), pg_temp.u('e3'), 'Gate GA', 10, 100);
INSERT INTO public.exos_checkin_lists (id, event_id, name, allow_reentry, valid_from, valid_until, sort_order) VALUES
  (pg_temp.u('g-main'), pg_temp.u('e3'), 'Main gate', true, now() - interval '5 hours', now() + interval '5 hours', 0),
  (pg_temp.u('g-north'), pg_temp.u('e3'), 'North gate', false, NULL, NULL, 1),
  (pg_temp.u('g-old'), pg_temp.u('e3'), 'Yesterday gate', true, now() - interval '30 hours', now() - interval '20 hours', 2);
INSERT INTO public.exos_checkin_lists (id, event_id, name, allow_reentry, admits) VALUES
  (pg_temp.u('g-lot'), pg_temp.u('e3'), 'Lot', true, 'addons');
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source)
SELECT pg_temp.u('g' || i), pg_temp.u('e3'), pg_temp.u('1'), pg_temp.u('t3'), 'Gate GA', pg_temp.u('b1'), pg_temp.u('b1'), 'fd-b1@x.com',
       'used', 'sek-g' || i, 10, 'cs_fd_g', 'stripe'
  FROM generate_series(1, 6) i;
INSERT INTO public.exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode)
VALUES (pg_temp.u('ad3'), pg_temp.u('e3'), 'Parking', 10, 10, true);
INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source)
VALUES (pg_temp.u('ln-e3'), pg_temp.u('e3'), pg_temp.u('1'), pg_temp.u('ad3'), 'Parking', pg_temp.u('b1'), pg_temp.u('b1'), 2, 10, 'cs_fd_g', 'stripe');
CREATE FUNCTION pg_temp.b0() RETURNS timestamptz LANGUAGE sql STABLE AS $$
  -- The start of the 15-minute bucket two hours ago.
  SELECT to_timestamp(floor(extract(epoch FROM now() - interval '2 hours') / 900) * 900)
$$;
-- Main gate: g1 in (b0+1m), g2 in (b0+2m), g1 out (b0+5m), g3 in (b0+16m, next
-- bucket), g1 back in (b0+17m); g4 forced in (offline conflict, b0+3m).
-- North gate: g5 in (b0+4m). Yesterday gate (closed now): g6 in.
INSERT INTO public.exos_event_checkins (event_id, ticket_id, org_id, scanned_by, source, verification, device,
                                        offline_scanned_at, scanned_at, list_id, direction, gate, forced, conflict) VALUES
  (pg_temp.u('e3'), pg_temp.u('g1'), pg_temp.u('1'), pg_temp.u('sa'), 'camera', 'verified', 'Door A1', NULL, pg_temp.b0() + interval '1 minute', pg_temp.u('g-main'), 'entry', 'Main gate', false, NULL),
  (pg_temp.u('e3'), pg_temp.u('g2'), pg_temp.u('1'), pg_temp.u('sa'), 'camera', 'verified', 'Door A2', NULL, pg_temp.b0() + interval '2 minutes', pg_temp.u('g-main'), 'entry', 'Main gate', false, NULL),
  (pg_temp.u('e3'), pg_temp.u('g4'), pg_temp.u('1'), pg_temp.u('sa'), 'manual', 'manual', 'Door A2', pg_temp.b0() + interval '3 minutes', now(), pg_temp.u('g-main'), 'entry', 'Main gate', true, 'invalid-time'),
  (pg_temp.u('e3'), pg_temp.u('g1'), pg_temp.u('1'), pg_temp.u('sa'), 'camera', 'verified', 'Door A1', NULL, pg_temp.b0() + interval '5 minutes', pg_temp.u('g-main'), 'exit', 'Main gate', false, NULL),
  (pg_temp.u('e3'), pg_temp.u('g3'), pg_temp.u('1'), pg_temp.u('sa'), 'camera', 'verified', 'Door A1', NULL, pg_temp.b0() + interval '16 minutes', pg_temp.u('g-main'), 'entry', 'Main gate', false, NULL),
  (pg_temp.u('e3'), pg_temp.u('g1'), pg_temp.u('1'), pg_temp.u('sa'), 'camera', 'verified', 'Door A1', NULL, pg_temp.b0() + interval '17 minutes', pg_temp.u('g-main'), 'entry', 'Main gate', false, NULL),
  (pg_temp.u('e3'), pg_temp.u('g5'), pg_temp.u('1'), pg_temp.u('sa'), 'camera', 'verified', 'Door N1', NULL, pg_temp.b0() + interval '4 minutes', pg_temp.u('g-north'), 'entry', 'North gate', false, NULL),
  (pg_temp.u('e3'), pg_temp.u('g6'), pg_temp.u('1'), pg_temp.u('sa'), 'camera', 'verified', 'Door Y1', NULL, now() - interval '25 hours', pg_temp.u('g-old'), 'entry', 'Yesterday gate', false, NULL);
-- Lot: pass 1 in (b0+6m), pass 2 in and out (b0+7m, b0+8m).
INSERT INTO public.exos_addon_pass_checkins (org_id, event_id, pass_id, list_id, gate, direction, scanned_by, source, verification, device, scanned_at)
SELECT pg_temp.u('1'), pg_temp.u('e3'), p.id, pg_temp.u('g-lot'), 'Lot', d, pg_temp.u('sa'), 'camera', 'verified', 'Lot L1', pg_temp.b0() + m
  FROM (VALUES (1, 'entry', interval '6 minutes'), (2, 'entry', interval '7 minutes'), (2, 'exit', interval '8 minutes')) v(unit, d, m)
  JOIN public.exos_addon_passes p ON p.order_addon_id = pg_temp.u('ln-e3') AND p.unit_index = v.unit;
INSERT INTO public.exos_scan_rejects (event_id, org_id, rejected_by, reason, source, ticket_id_attempted, reason_detail, rejected_at) VALUES
  (pg_temp.u('e3'), pg_temp.u('1'), pg_temp.u('sa'), 'used', 'camera', 'x', 'day-limit', now() - interval '1 hour'),
  (pg_temp.u('e3'), pg_temp.u('1'), pg_temp.u('sa'), 'used', 'camera', 'x', 'offline-replay:day-limit', now() - interval '1 hour'),
  (pg_temp.u('e3'), pg_temp.u('1'), pg_temp.u('sa'), 'not-found', 'camera', 'x', 'wrong-list', now() - interval '1 hour'),
  (pg_temp.u('e3'), pg_temp.u('1'), pg_temp.u('sa'), 'invalid-barcode', 'camera', 'x', 'Some Free Text <b>', now() - interval '1 hour'),
  (pg_temp.u('e3'), pg_temp.u('1'), pg_temp.u('sa'), 'used', 'camera', 'x', NULL, now() - interval '3 days'),
  (pg_temp.u('e9'), pg_temp.u('2'), pg_temp.u('ob'), 'used', 'camera', 'x', 'secret-other-org', now() - interval '1 hour');

DO $$
DECLARE r jsonb; b jsonb; s text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('fa'));
  r := public.exos_door_throughput(pg_temp.u('e3'), now() - interval '6 hours', now(), 15);
  ASSERT (r ->> 'bucket_minutes')::int = 15 AND r ->> 'timezone' = 'America/Phoenix', 'FD6 header: ' || r::text;
  -- Main gate, first bucket: 3 entries (one forced), 1 exit; second bucket: 2 entries.
  SELECT x INTO b FROM jsonb_array_elements(r -> 'buckets') x
   WHERE x ->> 'gate' = 'Main gate' AND (x ->> 'at')::timestamptz = pg_temp.b0();
  ASSERT (b ->> 'entries')::int = 3 AND (b ->> 'exits')::int = 1 AND (b ->> 'forced')::int = 1
     AND b ->> 'list_id' = pg_temp.u('g-main')::text AND b ->> 'kind' = 'ticket', 'FD6 main gate bucket 1: ' || b::text;
  SELECT x INTO b FROM jsonb_array_elements(r -> 'buckets') x
   WHERE x ->> 'gate' = 'Main gate' AND (x ->> 'at')::timestamptz = pg_temp.b0() + interval '15 minutes';
  ASSERT (b ->> 'entries')::int = 2 AND (b ->> 'exits')::int = 0, 'FD6 main gate bucket 2: ' || b::text;
  SELECT x INTO b FROM jsonb_array_elements(r -> 'buckets') x WHERE x ->> 'gate' = 'Lot';
  ASSERT (b ->> 'entries')::int = 2 AND (b ->> 'exits')::int = 1 AND b ->> 'kind' = 'addon', 'FD6 lot bucket: ' || b::text;
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'buckets') x WHERE x ->> 'gate' = 'Yesterday gate'),
         'FD6 outside the window: not in the buckets';
  -- Gate totals.
  SELECT x INTO b FROM jsonb_array_elements(r -> 'gates') x WHERE x ->> 'gate' = 'Main gate';
  ASSERT (b ->> 'entries')::int = 5 AND (b ->> 'exits')::int = 1 AND (b ->> 'devices')::int = 2
     AND (b ->> 'peak_entries')::int = 3, 'FD6 main gate totals: ' || b::text;
  SELECT x INTO b FROM jsonb_array_elements(r -> 'gates') x WHERE x ->> 'gate' = 'North gate';
  ASSERT (b ->> 'entries')::int = 1 AND (b ->> 'devices')::int = 1, 'FD6 north gate totals: ' || b::text;
  -- In park now: Main gate (re-entry, open): g1 back in, g2, g3, g4 (forced) = 4;
  -- North gate tracks no direction; Yesterday gate is closed (g6 not counted).
  ASSERT (r ->> 'in_park_now')::int = 4, 'FD6 in park now: ' || (r ->> 'in_park_now');
  ASSERT (r ->> 'lot_now')::int = 1, 'FD6 lot now: ' || (r ->> 'lot_now');
  ASSERT (r ->> 'tracks_direction')::boolean, 'FD6 direction tracked';
  SELECT x INTO b FROM jsonb_array_elements(r -> 'inside') x WHERE x ->> 'name' = 'Yesterday gate';
  ASSERT (b ->> 'tickets_inside')::int = 1 AND NOT (b ->> 'open_now')::boolean, 'FD6 a closed list still reports its own count: ' || b::text;
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'inside') x WHERE x ->> 'name' = 'North gate'), 'FD6 no re-entry: not listed';
  -- Refusals by reason: prefixes dropped, free text falls back to the reason, other orgs' never.
  ASSERT (SELECT (x ->> 'count')::int FROM jsonb_array_elements(r -> 'refusals') x WHERE x ->> 'reason' = 'day-limit') = 2,
         'FD6 day-limit twice: ' || (r -> 'refusals')::text;
  ASSERT (SELECT (x ->> 'count')::int FROM jsonb_array_elements(r -> 'refusals') x WHERE x ->> 'reason' = 'wrong-list') = 1
     AND (SELECT (x ->> 'count')::int FROM jsonb_array_elements(r -> 'refusals') x WHERE x ->> 'reason' = 'invalid-barcode') = 1,
         'FD6 the rest: ' || (r -> 'refusals')::text;
  ASSERT jsonb_array_length(r -> 'refusals') = 3 AND position('secret-other-org' in r::text) = 0 AND position('Free Text' in r::text) = 0,
         'FD6 nothing else: ' || (r -> 'refusals')::text;

  -- Who may read it: the event's scanner yes; another org, a scanner assigned elsewhere, signed out no.
  PERFORM pg_temp.act(pg_temp.u('sa'));
  ASSERT (public.exos_door_throughput(pg_temp.u('e3'), NULL, NULL, 60) ->> 'bucket_minutes')::int = 60, 'FD6 scanner of the event';
  FOREACH s IN ARRAY ARRAY['ob', 'sb', 'b1'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    ASSERT pg_temp.st(format('SELECT public.exos_door_throughput(%L)', pg_temp.u('e3')))
           = '42501 exos_door_throughput: not authorized for this event', 'FD6 refused for ' || s;
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('oa'));
  ASSERT pg_temp.st(format('SELECT public.exos_door_throughput(%L)', pg_temp.u('e9'))) LIKE '42501%', 'FD6 org 1 owner, org 2 event';
  ASSERT pg_temp.st(format('SELECT public.exos_door_throughput(%L)', pg_temp.u('none'))) LIKE '42501%', 'FD6 unknown event';
  ASSERT pg_temp.st(format('SELECT public.exos_door_throughput(%L, NULL, NULL, 7)', pg_temp.u('e3'))) LIKE '22023%', 'FD6 bucket size';
  ASSERT pg_temp.st(format('SELECT public.exos_door_throughput(%L, %L, %L)', pg_temp.u('e3'), now() - interval '20 days', now())) LIKE '22023%',
         'FD6 at most 14 days';
  ASSERT pg_temp.st(format('SELECT public.exos_door_throughput(%L, %L, %L)', pg_temp.u('e3'), now(), now() - interval '1 hour')) LIKE '22023%',
         'FD6 the window ends after it starts';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_door_throughput(%L)', pg_temp.u('e3'))) LIKE '42501%', 'FD6 signed out';
  -- The fair: e1's report sees its day lists and lot.
  PERFORM pg_temp.act(pg_temp.u('ma'));
  r := public.exos_door_throughput(pg_temp.u('e1'), now() - interval '6 days', now() + interval '1 minute', 60);
  ASSERT (SELECT sum((x ->> 'entries')::int) FROM jsonb_array_elements(r -> 'gates') x WHERE x ->> 'kind' = 'ticket')
         = (SELECT count(*) FROM public.exos_event_checkins WHERE event_id = pg_temp.u('e1') AND direction = 'entry'),
         'FD6 the fair: every entry in a gate';
  ASSERT (r ->> 'lot_now')::int = 2, 'FD6 the fair lot: parking and camping inside: ' || (r ->> 'lot_now');
  RAISE NOTICE 'OK  FD6 throughput: buckets per gate and lot, totals, in park now, refusals; roles and cross-org refused';
END $$;

ROLLBACK;
