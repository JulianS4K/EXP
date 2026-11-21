-- ============================================================================
-- Security hygiene (mig 20261109110000). Self-contained (c8b… prefix), rolled
-- back. Needs harness.policies_before (shim_security_hygiene.sql, run by
-- run_p0.sh's apply() before the migration).
--   S1 exos_paste_probe is gone
--   S2 exos_run_channel_splits_each stays without a SET clause (it COMMITs);
--      only its owner may CALL it
--   S3 no exos_* sequence that anon can use, read or update; a new one would
--      be caught (the harness carries Supabase's sequence default privileges)
--   S4 policies: no bare auth.* call left on an exos_* table; every policy
--      from before is there with the same command, roles and permissive flag,
--      and the same expressions apart from the wrapping; what each user sees,
--      and may insert, is the same under the old and the new expressions
--   S5 _exos_site_error / _exos_door_code_loose: no anon or PUBLIC EXECUTE;
--      their definer callers, the loose-code index and the service role work
--   S7 exos_group_seat_view: no event / ticket type id for an unpublished event
--   (the matched-seats fix, S6, is asserted in test_matched_seats.sql M4 / M6)
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_security_hygiene.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('c8b00000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid $$;

-- S1 ---------------------------------------------------------------------------
DO $$ BEGIN
  ASSERT to_regclass('public.exos_paste_probe') IS NULL, 'S1: exos_paste_probe still there';
  RAISE NOTICE 'OK  S1 exos_paste_probe dropped';
END $$;

-- S2 ---------------------------------------------------------------------------
DO $$
DECLARE p regprocedure := to_regprocedure('public.exos_run_channel_splits_each(integer)');
BEGIN
  ASSERT p IS NOT NULL, 'S2: the procedure is missing';
  ASSERT (SELECT prokind FROM pg_proc WHERE oid = p) = 'p', 'S2: not a procedure any more';
  -- A procedure with a SET clause can't COMMIT, and this one commits after
  -- each event: pinning its search_path would break the exos-channel-split cron.
  ASSERT (SELECT proconfig FROM pg_proc WHERE oid = p) IS NULL, 'S2: a SET clause stops the per-event COMMIT';
  ASSERT NOT (SELECT prosecdef FROM pg_proc WHERE oid = p), 'S2: security definer';
  ASSERT NOT has_function_privilege('anon', p, 'EXECUTE')
     AND NOT has_function_privilege('authenticated', p, 'EXECUTE')
     AND NOT has_function_privilege('service_role', p, 'EXECUTE'), 'S2: a client role may CALL it';
  RAISE NOTICE 'OK  S2 exos_run_channel_splits_each: no SET clause (COMMITs per event), owner-only';
END $$;

-- S3 ---------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v
    FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
   WHERE s.nspname = 'public' AND c.relkind = 'S' AND c.relname LIKE 'exos\_%'
     AND (has_sequence_privilege('anon', c.oid, 'USAGE') OR has_sequence_privilege('anon', c.oid, 'SELECT')
          OR has_sequence_privilege('anon', c.oid, 'UPDATE'));
  ASSERT v IS NULL, 'S3: anon can use, read or update ' || v
    || ' (REVOKE ALL ON SEQUENCE ... FROM PUBLIC, anon in the migration that creates it)';
  ASSERT (SELECT count(*) FROM pg_class WHERE relkind = 'S' AND relname IN ('exos_tevo_remote_ids_remote_id_seq',
          'exos_audience_exports_id_seq', 'exos_order_fees_id_seq', 'exos_fan_exports_id_seq')) = 4, 'S3: the advisor''s four';
  ASSERT has_sequence_privilege('service_role', 'public.exos_order_fees_id_seq', 'USAGE'), 'S3: service_role lost a sequence';
  -- The check bites: as in prod, a new sequence comes with anon grants.
  ASSERT EXISTS (SELECT 1 FROM pg_default_acl d WHERE d.defaclobjtype = 'S'
                    AND d.defaclnamespace = 'public'::regnamespace), 'S3: the harness lacks the sequence default privileges';
  CREATE SEQUENCE public.exos_hygiene_probe_seq;
  ASSERT has_sequence_privilege('anon', 'public.exos_hygiene_probe_seq', 'UPDATE'), 'S3: default privileges not applied';
  DROP SEQUENCE public.exos_hygiene_probe_seq;
  RAISE NOTICE 'OK  S3 no exos_* sequence anon can use / read / update; new ones are caught';
END $$;

-- S4 ---------------------------------------------------------------------------
-- unwrap: the wrapped form back to the bare call. bare: bare calls left.
CREATE FUNCTION pg_temp.unwrap(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(replace(p,
           '( SELECT auth.uid() AS uid)', 'auth.uid()'), '( SELECT auth.jwt() AS jwt)', 'auth.jwt()'),
           '( SELECT auth.role() AS role)', 'auth.role()'), '( SELECT auth.email() AS email)', 'auth.email()') $$;
CREATE FUNCTION pg_temp.bare(p text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT (SELECT count(*) FROM regexp_matches(coalesce(p, ''), 'auth\.(uid|jwt|role|email)\(\)', 'g'))::int
       - (SELECT count(*) FROM regexp_matches(coalesce(p, ''), '\( SELECT auth\.(uid|jwt|role|email)\(\) AS \1\)', 'g'))::int $$;

SET LOCAL search_path = '';
CREATE TEMP TABLE pa AS
SELECT c.relname::text AS relname, p.polname::text AS polname, p.polcmd::text AS cmd, p.polpermissive AS permissive,
       ARRAY(SELECT CASE WHEN r = 0 THEN 'public' ELSE r::regrole::text END FROM unnest(p.polroles) r ORDER BY 1) AS roles,
       pg_catalog.pg_get_expr(p.polqual, p.polrelid) AS qual,
       pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) AS chk
  FROM pg_catalog.pg_policy p
  JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
  JOIN pg_catalog.pg_namespace s ON s.oid = c.relnamespace
 WHERE s.nspname = 'public' AND c.relname LIKE 'exos\_%';
SET LOCAL search_path = public, pg_temp;
-- The policies the migration rewrote (bare calls before it).
CREATE TEMP TABLE changed AS
SELECT b.* FROM harness.policies_before b WHERE pg_temp.bare(b.qual) + pg_temp.bare(b.chk) > 0;
GRANT SELECT ON changed TO authenticated;

DO $$
DECLARE v text; n int;
BEGIN
  SELECT string_agg(relname || '.' || polname, ', ') INTO v FROM pa WHERE pg_temp.bare(qual) + pg_temp.bare(chk) > 0;
  ASSERT v IS NULL, 'S4: bare auth.* call per row in ' || v;
  -- Same set, command, roles, permissive flag; same expressions but the wrapping.
  SELECT string_agg(b.relname || '.' || b.polname, ', ') INTO v
    FROM harness.policies_before b LEFT JOIN pa a USING (relname, polname)
   WHERE a.polname IS NULL OR a.cmd <> b.cmd OR a.permissive <> b.permissive OR a.roles <> b.roles
      OR pg_temp.unwrap(a.qual) IS DISTINCT FROM pg_temp.unwrap(b.qual)
      OR pg_temp.unwrap(a.chk) IS DISTINCT FROM pg_temp.unwrap(b.chk);
  ASSERT v IS NULL, 'S4: changed beyond the wrapping (or gone): ' || v;
  -- Untouched policies are byte-identical.
  SELECT string_agg(b.relname || '.' || b.polname, ', ') INTO v
    FROM harness.policies_before b JOIN pa a USING (relname, polname)
   WHERE pg_temp.bare(b.qual) + pg_temp.bare(b.chk) = 0
     AND (a.qual IS DISTINCT FROM b.qual OR a.chk IS DISTINCT FROM b.chk);
  ASSERT v IS NULL, 'S4: a policy without a bare call was rewritten: ' || v;
  SELECT count(*) INTO n FROM changed;
  ASSERT n >= 40, 'S4: only ' || n || ' policies had bare calls (expected the advisor''s ~42)';
  SELECT string_agg(relname || '.' || polname, ', ' ORDER BY relname, polname) INTO v FROM changed;
  RAISE NOTICE 'S4: % policies wrapped: %', n, v;
  SELECT count(*) INTO n FROM pa a WHERE NOT EXISTS (SELECT 1 FROM harness.policies_before b WHERE b.relname = a.relname AND b.polname = a.polname);
  RAISE NOTICE 'S4: % exos policies added by later migrations', n;
  RAISE NOTICE 'OK  S4 no bare auth.* call; same policies, commands, roles, flags; only the wrapping differs';
END $$;

-- What each user sees: fixtures in the core tables, then a count per user and
-- table under the new expressions, then under the old ones (ALTER POLICY back
-- to the snapshot), and the two must match.
INSERT INTO auth.users(id, email, email_confirmed_at)
SELECT pg_temp.u(x), 'hyg-' || x || '@x.com', now() FROM unnest(ARRAY['a1','a2','a3','a4','a5']) x;
INSERT INTO public.exos_orgs(id, name, slug, owner_uid) VALUES
  (pg_temp.u('01'), 'Hyg A', 'hyg-a', pg_temp.u('a1')),
  (pg_temp.u('02'), 'Hyg B', 'hyg-b', pg_temp.u('a5'));
INSERT INTO public.exos_org_memberships(org_id, user_id, role) VALUES
  (pg_temp.u('01'), pg_temp.u('a1'), 'owner'), (pg_temp.u('01'), pg_temp.u('a2'), 'scanner'),
  (pg_temp.u('02'), pg_temp.u('a5'), 'owner');
INSERT INTO public.exos_events(id, org_id, name, slug, status, starts_at, timezone) VALUES
  (pg_temp.u('e1'), pg_temp.u('01'), 'Hyg Show', 'hyg-show', 'published', now() + interval '5 days', 'UTC'),
  (pg_temp.u('e2'), pg_temp.u('02'), 'Hyg Other', 'hyg-other', 'published', now() + interval '6 days', 'UTC');
INSERT INTO public.exos_ticket_tiers(id, event_id, name, price, capacity) VALUES
  (pg_temp.u('d1'), pg_temp.u('e1'), 'GA', 20, 50), (pg_temp.u('d2'), pg_temp.u('e2'), 'GA', 20, 50);
INSERT INTO public.exos_tickets(id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref)
VALUES
  (pg_temp.u('c1'), pg_temp.u('e1'), pg_temp.u('01'), pg_temp.u('d1'), 'GA', pg_temp.u('a3'), pg_temp.u('a3'), 'hyg-a3@x.com', 'active', gen_random_uuid()::text, 20, 'hyg_o1'),
  (pg_temp.u('c2'), pg_temp.u('e1'), pg_temp.u('01'), pg_temp.u('d1'), 'GA', pg_temp.u('a3'), pg_temp.u('a4'), 'hyg-a3@x.com', 'active', gen_random_uuid()::text, 20, 'hyg_o1'),
  (pg_temp.u('c3'), pg_temp.u('e2'), pg_temp.u('02'), pg_temp.u('d2'), 'GA', pg_temp.u('a3'), pg_temp.u('a3'), 'hyg-a3@x.com', 'active', gen_random_uuid()::text, 20, 'hyg_o2');
INSERT INTO public.exos_transfers(id, ticket_id, org_id, sender_id, receiver_email, status)
VALUES (pg_temp.u('f1'), pg_temp.u('c1'), pg_temp.u('01'), pg_temp.u('a3'), 'hyg-a4@x.com', 'pending');
INSERT INTO public.exos_profiles(id, is_public)
SELECT pg_temp.u(x), x = 'a5' FROM unnest(ARRAY['a1','a2','a3','a4','a5']) x ON CONFLICT (id) DO NOTHING;
INSERT INTO public.exos_event_saves(user_id, event_id) VALUES (pg_temp.u('a3'), pg_temp.u('e1')), (pg_temp.u('a4'), pg_temp.u('e2'));
INSERT INTO public.exos_org_follows(follower_uid, org_id) VALUES (pg_temp.u('a3'), pg_temp.u('01')), (pg_temp.u('a4'), pg_temp.u('02'));
INSERT INTO public.exos_org_invites(org_id, email, role) VALUES (pg_temp.u('01'), 'hyg-a4@x.com', 'scanner'), (pg_temp.u('02'), 'hyg-a3@x.com', 'manager');
INSERT INTO public.exos_waitlist(event_id, user_id, email) VALUES (pg_temp.u('e1'), pg_temp.u('a3'), 'hyg-a3@x.com');
INSERT INTO public.exos_checkout_sessions(session_id, event_id, tier_id, org_id, buyer_uid, quantity, amount_cents, status)
VALUES ('cs_hyg_1', pg_temp.u('e1'), pg_temp.u('d1'), pg_temp.u('01'), pg_temp.u('a3'), 2, 4000, 'fulfilled');
INSERT INTO public.exos_event_announcements(event_id, org_id, subject, body) VALUES (pg_temp.u('e1'), pg_temp.u('01'), 'Doors', 'Doors at 8');
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES (pg_temp.u('e1'), pg_temp.u('a2'), pg_temp.u('01'));

CREATE TEMP TABLE vis (phase text, who text, tbl text, n bigint, ins text);
GRANT INSERT, SELECT ON vis TO authenticated;
CREATE FUNCTION pg_temp.look(p_phase text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE w record; t text; n bigint; v_ins text;
BEGIN
  FOR w IN SELECT * FROM (VALUES ('owner', 'a1'), ('scanner', 'a2'), ('holder', 'a3'), ('receiver', 'a4'), ('other org', 'a5')) x(who, k) LOOP
    PERFORM set_config('app.uid', pg_temp.u(w.k)::text, true);
    PERFORM set_config('app.jwt', json_build_object('sub', pg_temp.u(w.k), 'email', 'hyg-' || w.k || '@x.com')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    FOR t IN SELECT DISTINCT relname FROM changed WHERE cmd IN ('r', '*') ORDER BY 1 LOOP
      IF has_any_column_privilege('authenticated', ('public.' || t)::regclass, 'SELECT') THEN
        EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
        INSERT INTO vis VALUES (p_phase, w.who, t, n, NULL);
      END IF;
    END LOOP;
    -- WITH CHECK: save an event for yourself (allowed) and for someone else
    -- (not). Undone right after, so the counts of the other phase don't move.
    BEGIN
      BEGIN
        INSERT INTO public.exos_event_saves(user_id, event_id) VALUES (pg_temp.u(w.k), pg_temp.u('e1')) ON CONFLICT DO NOTHING;
        v_ins := 'self ok';
      EXCEPTION WHEN insufficient_privilege THEN v_ins := 'self denied';
      END;
      BEGIN
        INSERT INTO public.exos_event_saves(user_id, event_id) VALUES (pg_temp.u('a5'), pg_temp.u('e2')) ON CONFLICT DO NOTHING;
        v_ins := v_ins || ', other ok';
      EXCEPTION WHEN insufficient_privilege THEN v_ins := v_ins || ', other denied';
      END;
      RAISE EXCEPTION 'undo' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    END;
    INSERT INTO vis VALUES (p_phase, w.who, 'insert exos_event_saves', NULL, v_ins);
    EXECUTE 'RESET ROLE';
  END LOOP;
END $$;

SELECT pg_temp.look('new');
-- Back to the expressions from before the migration.
SET LOCAL search_path = '';
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM pg_temp.changed LOOP
    EXECUTE format('ALTER POLICY %I ON public.%I', r.polname, r.relname)
         || CASE WHEN r.qual IS NOT NULL THEN format(' USING (%s)', r.qual) ELSE '' END
         || CASE WHEN r.chk IS NOT NULL THEN format(' WITH CHECK (%s)', r.chk) ELSE '' END;
  END LOOP;
END $$;
SET LOCAL search_path = public, pg_temp;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM pg_policy p JOIN changed c ON c.polname = p.polname AND p.polrelid = ('public.' || c.relname)::regclass
           WHERE pg_temp.bare(pg_get_expr(p.polqual, p.polrelid)) + pg_temp.bare(pg_get_expr(p.polwithcheck, p.polrelid)) > 0)
         = (SELECT count(*) FROM changed), 'S4: the old expressions did not go back';
END $$;
SELECT pg_temp.look('old');

DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(coalesce(a.who, b.who) || ' ' || coalesce(a.tbl, b.tbl) || ': new ' || coalesce(a.n::text, a.ins, '-')
                    || ' / old ' || coalesce(b.n::text, b.ins, '-'), '; ') INTO v
    FROM (SELECT * FROM vis WHERE phase = 'new') a
    FULL JOIN (SELECT * FROM vis WHERE phase = 'old') b ON a.who = b.who AND a.tbl = b.tbl
   WHERE a.n IS DISTINCT FROM b.n OR a.ins IS DISTINCT FROM b.ins OR a.who IS NULL OR b.who IS NULL;
  ASSERT v IS NULL, 'S4: access changed: ' || v;
  -- The fixtures were seen (the counts aren't all zero) and the checks bite.
  ASSERT (SELECT n FROM vis WHERE phase = 'new' AND who = 'holder' AND tbl = 'exos_tickets') = 3, 'S4: holder sees own + bought tickets';
  ASSERT (SELECT n FROM vis WHERE phase = 'new' AND who = 'receiver' AND tbl = 'exos_transfers') = 1, 'S4: receiver sees the transfer (jwt email)';
  ASSERT (SELECT n FROM vis WHERE phase = 'new' AND who = 'receiver' AND tbl = 'exos_org_invites') = 1, 'S4: invitee sees the invite (jwt email)';
  ASSERT (SELECT n FROM vis WHERE phase = 'new' AND who = 'other org' AND tbl = 'exos_checkout_sessions') = 0, 'S4: other org sees no session';
  ASSERT (SELECT ins FROM vis WHERE phase = 'new' AND who = 'holder' AND tbl = 'insert exos_event_saves') = 'self ok, other denied', 'S4: with check';
  ASSERT (SELECT ins FROM vis WHERE phase = 'new' AND who = 'other org' AND tbl = 'insert exos_event_saves') = 'self ok, other ok', 'S4: own save';
  ASSERT (SELECT count(DISTINCT tbl) FROM vis WHERE phase = 'new' AND n > 0) >= 8, 'S4: fixtures cover too few tables';
  RAISE NOTICE 'OK  S4 every user sees (and may insert) the same under the old and the new expressions (% checks)',
    (SELECT count(*) FROM vis WHERE phase = 'new');
END $$;

-- S5 ---------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public._exos_site_error(jsonb)', 'public._exos_door_code_loose(text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'S5: anon can call ' || f;
    ASSERT NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = f::regprocedure AND a.grantee = 0)
       AND (SELECT proacl FROM pg_proc WHERE oid = f::regprocedure) IS NOT NULL, 'S5: PUBLIC can call ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE') AND has_function_privilege('service_role', f, 'EXECUTE'),
      'S5: authenticated / service_role lost ' || f;
  END LOOP;
  -- No anon path writes exos_guest_list_entries (its loose-code index calls the helper).
  ASSERT NOT has_table_privilege('anon', 'public.exos_guest_list_entries', 'INSERT')
     AND NOT has_table_privilege('anon', 'public.exos_guest_list_entries', 'UPDATE'), 'S5: anon writes guest list entries';
  ASSERT NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = 'public.exos_guest_list_entries'::regclass
                      AND (0 = ANY (p.polroles) OR 'anon'::regrole = ANY (p.polroles))), 'S5: an anon / PUBLIC policy on guest list entries';
  RAISE NOTICE 'OK  S5 no anon / PUBLIC EXECUTE on the two helpers; no anon writes to guest list entries';
END $$;

-- The service role imports a coded guest (the index evaluates the helper as it).
INSERT INTO public.exos_guest_lists(id, event_id, org_id, name) VALUES (pg_temp.u('91'), pg_temp.u('e1'), pg_temp.u('01'), 'Hyg list');
SET LOCAL ROLE service_role;
INSERT INTO public.exos_guest_list_entries(id, list_id, event_id, org_id, guest_name, external_code)
VALUES (pg_temp.u('92'), pg_temp.u('91'), pg_temp.u('e1'), pg_temp.u('01'), 'Coded Guest', 'HY-12-ab');
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('app.uid', pg_temp.u('a1')::text, true);
  ASSERT public.exos_door_code_lookup(pg_temp.u('e1'), 'hy12ab') = pg_temp.u('92'), 'S5: loose code lookup (owner)';
  ASSERT public.exos_set_org_site(pg_temp.u('01'), '{"sections":[{"type":"text","body":"Hi"}]}') IS NOT NULL, 'S5: site saved';
  BEGIN
    PERFORM public.exos_set_org_site(pg_temp.u('01'), '{"sections":[{"type":"nope"}]}');
    RAISE EXCEPTION 'S5: a bad site was saved';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  S5 the definer callers, the loose-code index and the service role still work';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
  BEGIN
    PERFORM public._exos_door_code_loose('x-1');
    RAISE EXCEPTION 'S5: anon ran _exos_door_code_loose';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_site_error('{}');
    RAISE EXCEPTION 'S5: anon ran _exos_site_error';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  S5 anon calls are refused';
END $$;
RESET ROLE;

-- S7 ---------------------------------------------------------------------------
-- Group pay v2 is paused (mig 20261111120000): the seat page answers only
-- with the switch on, so S7 turns it on (rolled back with the rest).
SELECT public.exos_set_group_pay_enabled(true, 'test_security_hygiene.sql: S7');
INSERT INTO public.exos_group_buys(id, org_id, event_id, tier_id, host_uid, quantity, deadline)
VALUES (pg_temp.u('71'), pg_temp.u('01'), pg_temp.u('e1'), pg_temp.u('d1'), pg_temp.u('a3'), 2, now() + interval '20 minutes');
INSERT INTO public.exos_group_buy_seats(group_id, org_id, seat_no, token, status) VALUES
  (pg_temp.u('71'), pg_temp.u('01'), 1, 'c8b0000000000000000000000000aa01', 'paid'),
  (pg_temp.u('71'), pg_temp.u('01'), 2, 'c8b0000000000000000000000000aa02', 'waiting');
SET LOCAL ROLE anon;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_group_seat_view('c8b0000000000000000000000000aa01');
  ASSERT (r->>'event_id')::uuid = pg_temp.u('e1') AND (r->>'tier_id')::uuid = pg_temp.u('d1') AND r->'event'->>'name' = 'Hyg Show',
    'S7: published: the event and type ' || r;
END $$;
RESET ROLE;
UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('e1');
SET LOCAL ROLE anon;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_group_seat_view('c8b0000000000000000000000000aa01');
  ASSERT r IS NOT NULL AND r->>'state' = 'paid', 'S7: a paid seat still reads as paid ' || r;
  ASSERT r->'event_id' = 'null'::jsonb AND r->'tier_id' = 'null'::jsonb AND r->'event' = 'null'::jsonb, 'S7: unpublished: ids leak ' || r;
  ASSERT position(pg_temp.u('e1')::text in r::text) = 0 AND position(pg_temp.u('d1')::text in r::text) = 0, 'S7: an id in ' || r;
  r := public.exos_group_seat_view('c8b0000000000000000000000000aa02');
  ASSERT r->>'state' = 'released' AND r->'event_id' = 'null'::jsonb AND r->'tier_id' = 'null'::jsonb, 'S7: open seat ' || r;
  RAISE NOTICE 'OK  S7 the seat page names no event or ticket type once the event is unpublished';
END $$;
RESET ROLE;

SELECT public.exos_set_group_pay_enabled(false, 'test_security_hygiene.sql: S7 done');

ROLLBACK;
