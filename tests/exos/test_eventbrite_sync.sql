-- ============================================================================
-- Exos Door: Eventbrite sync (mig 20261013100000):
--   E1 connect: owner / manager only, token to Vault, shape checked; the
--      token is read back only for owners / managers
--   E2 link: the "Eventbrite" list is made once; one Eventbrite event per
--      Exos event; another Eventbrite event starts the cursor over
--   E3 claim: cron claims a due link with its token and a lease; a second
--      claim gets nothing; "Sync now" needs door staff (scanner scope) and
--      waits 20 s between taps
--   E4 apply 'more': attendees added, a CSV-imported barcode adopted (no
--      duplicate), a never-seen voided attendee skipped, the continuation
--      kept with the lease; 'pause' frees the link and the next run resumes
--   E5 apply 'done': cursor moves to the pass start, lease released
--   E6 void: the door refuses a voided guest and the download says so; a
--      restored ticket checks in; the house capacity is never touched
--   E7 status: door staff see it (never the token); outsider refused
--   E8 apply 'error': error kept, lease released, pass restarts; the cron
--      waits 10 minutes before retrying
--   E9 disconnect: Vault secret and links gone, guests stay
--   E10 grants
--   E11 (runs before E9) a run overtaken by a relink writes nothing; a pass
--      with a failed row keeps the cursor; a good page clears the error
-- Self-contained (BEGIN / ROLLBACK). Org e5…01 owned by …a1; manager …a2,
-- scanner …a3 (unscoped), scanner …a4 (assigned to e2 only), outsider …a6.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('e5000000-0000-0000-0000-0000000000a1','e5own@x.com',now()),
  ('e5000000-0000-0000-0000-0000000000a2','e5mgr@x.com',now()),
  ('e5000000-0000-0000-0000-0000000000a3','e5scan@x.com',now()),
  ('e5000000-0000-0000-0000-0000000000a4','e5scan2@x.com',now()),
  ('e5000000-0000-0000-0000-0000000000a6','e5out@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('e5000000-0000-0000-0000-000000000001','EB Org','eb-org-stub','e5000000-0000-0000-0000-0000000000a1'),
  ('e5000000-0000-0000-0000-000000000002','EB Other','eb-other-stub','e5000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('e5000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-0000000000a1','owner'),
  ('e5000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-0000000000a2','manager'),
  ('e5000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-0000000000a3','scanner'),
  ('e5000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-0000000000a4','scanner'),
  ('e5000000-0000-0000-0000-000000000002','e5000000-0000-0000-0000-0000000000a6','owner');
-- e1: tonight (doors open). e2: where a4 works. e3: next month.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('e5000000-0000-0000-0000-0000000000e1','e5000000-0000-0000-0000-000000000001','EB Night','eb-night-stub','draft',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'e5000000-0000-0000-0000-0000000000a1'),
  ('e5000000-0000-0000-0000-0000000000e2','e5000000-0000-0000-0000-000000000001','EB Other Night','eb-oth-stub','draft',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'e5000000-0000-0000-0000-0000000000a1'),
  ('e5000000-0000-0000-0000-0000000000e3','e5000000-0000-0000-0000-000000000001','EB Later','eb-later-stub','draft',
   now() + interval '30 days', now() + interval '30 days', 0, 'e5000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES
  ('e5000000-0000-0000-0000-0000000000e2','e5000000-0000-0000-0000-0000000000a4','e5000000-0000-0000-0000-000000000001');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('e5000000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.org() RETURNS uuid LANGUAGE sql AS $$ SELECT 'e5000000-0000-0000-0000-000000000001'::uuid $$;
-- exos_eventbrite_apply with the link's current lease (what the claiming run holds).
CREATE FUNCTION pg_temp.ap(p_event uuid, p_rows jsonb, p_state text, p_cont text DEFAULT NULL, p_err text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_eventbrite_apply(p_event, (SELECT lease_id FROM public.exos_eventbrite_links WHERE event_id = p_event),
                                      p_rows, p_state, p_cont, p_err)
$$;
CREATE FUNCTION pg_temp.entry(p_ref text) RETURNS public.exos_guest_list_entries LANGUAGE sql AS $$
  SELECT * FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND external_ref = 'eb:' || p_ref
$$;

-- E1. Connect.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);  -- the service role: no auth.uid()
  r := public.exos_eventbrite_connect(pg_temp.org(), pg_temp.u('a1'), 'TOKENAAAA1111', 'Blue Room');
  ASSERT r->>'connected' = 'true' AND r->>'account_name' = 'Blue Room', 'E1: ' || r::text;
  ASSERT (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'exos_eventbrite:' || pg_temp.org())
         = 'TOKENAAAA1111', 'E1: token in Vault';
  -- The manager replaces it; the same Vault row is reused.
  PERFORM public.exos_eventbrite_connect(pg_temp.org(), pg_temp.u('a2'), 'TOKENBBBB2222', 'Blue Room');
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name = 'exos_eventbrite:' || pg_temp.org()) = 1, 'E1: one secret';
  ASSERT public.exos_eventbrite_token(pg_temp.org(), pg_temp.u('a1')) = 'TOKENBBBB2222', 'E1: token read back';
  BEGIN
    PERFORM public.exos_eventbrite_connect(pg_temp.org(), pg_temp.u('a3'), 'TOKENCCCC3333', 'x');
    RAISE EXCEPTION 'E1: a scanner connected';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_eventbrite_connect(pg_temp.org(), pg_temp.u('a6'), 'TOKENCCCC3333', 'x');
    RAISE EXCEPTION 'E1: an outsider connected';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_eventbrite_connect(pg_temp.org(), pg_temp.u('a1'), 'bad token!', 'x');
    RAISE EXCEPTION 'E1: a malformed token was stored';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_eventbrite_token(pg_temp.org(), pg_temp.u('a3'));
    RAISE EXCEPTION 'E1: a scanner read the token';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- E2. Link.
DO $$
DECLARE r jsonb; v_list uuid;
BEGIN
  r := public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a1'), '111', 'EB Night on Eventbrite');
  ASSERT r->>'linked' = 'true', 'E2: ' || r::text;
  v_list := (r->>'list_id')::uuid;
  ASSERT (SELECT name FROM public.exos_guest_lists WHERE id = v_list) = 'Eventbrite', 'E2: list name';
  ASSERT NOT (SELECT counts_toward_capacity FROM public.exos_guest_lists WHERE id = v_list), 'E2: does not count';
  -- Linking again keeps the list and the cursor.
  UPDATE public.exos_eventbrite_links SET sync_cursor = now() - interval '1 hour' WHERE event_id = pg_temp.u('e1');
  r := public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a2'), '111', 'EB Night on Eventbrite');
  ASSERT (r->>'list_id')::uuid = v_list AND r->>'relinked' = 'false', 'E2: same list ' || r::text;
  ASSERT (SELECT sync_cursor FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')) IS NOT NULL, 'E2: cursor kept';
  -- Another Eventbrite event starts over.
  r := public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a1'), '112', 'Wrong one');
  ASSERT r->>'relinked' = 'true', 'E2: relinked';
  ASSERT (SELECT sync_cursor FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')) IS NULL, 'E2: cursor reset';
  PERFORM public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a1'), '111', 'EB Night on Eventbrite');
  BEGIN
    PERFORM public.exos_eventbrite_link(pg_temp.u('e2'), pg_temp.u('a1'), '111', 'dupe');
    RAISE EXCEPTION 'E2: one Eventbrite event linked twice';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_eventbrite_link(pg_temp.u('e2'), pg_temp.u('a3'), '222', 'x');
    RAISE EXCEPTION 'E2: a scanner linked';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_eventbrite_link(pg_temp.u('e2'), pg_temp.u('a1'), '12a', 'x');
    RAISE EXCEPTION 'E2: a non-numeric id was linked';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM public.exos_eventbrite_link(pg_temp.u('e3'), pg_temp.u('a1'), '333', 'Later');
END $$;

-- E3. Claim.
DO $$
DECLARE n int; v_tok text;
BEGIN
  SELECT count(*), max(token) INTO n, v_tok FROM public.exos_eventbrite_sync_claim();
  ASSERT n = 2 AND v_tok = 'TOKENBBBB2222', 'E3: cron claimed ' || n;
  ASSERT (SELECT lease_until > now() AND pass_started_at IS NOT NULL FROM public.exos_eventbrite_links
           WHERE event_id = pg_temp.u('e1')), 'E3: lease + pass start';
  SELECT count(*) INTO n FROM public.exos_eventbrite_sync_claim();
  ASSERT n = 0, 'E3: second claim got ' || n;
  -- 3 minutes on: tonight's event is due again (every 2 min), next month's is not (every 30).
  UPDATE public.exos_eventbrite_links SET lease_until = NULL, last_synced_at = now() - interval '3 minutes';
  SELECT count(*) INTO n FROM public.exos_eventbrite_sync_claim() c WHERE c.event_id = pg_temp.u('e1');
  ASSERT n = 1, 'E3: tonight due';
  SELECT count(*) INTO n FROM public.exos_eventbrite_sync_claim() c WHERE c.event_id = pg_temp.u('e3');
  ASSERT n = 0, 'E3: next month not due yet';
  -- An event two days past is never claimed by the cron.
  UPDATE public.exos_events SET starts_at = now() - interval '3 days' WHERE id = pg_temp.u('e3');
  UPDATE public.exos_eventbrite_links SET lease_until = NULL, last_synced_at = NULL WHERE event_id = pg_temp.u('e3');
  SELECT count(*) INTO n FROM public.exos_eventbrite_sync_claim() c WHERE c.event_id = pg_temp.u('e3');
  ASSERT n = 0, 'E3: past event claimed';
  -- Sync now: door staff of the event, every 20 s at most.
  UPDATE public.exos_eventbrite_links SET lease_until = NULL, last_synced_at = now() - interval '1 minute'
   WHERE event_id = pg_temp.u('e1');
  SELECT count(*) INTO n FROM public.exos_eventbrite_sync_claim(pg_temp.u('e1'), pg_temp.u('a3'));
  ASSERT n = 1, 'E3: scanner sync now';
  UPDATE public.exos_eventbrite_links SET lease_until = NULL WHERE event_id = pg_temp.u('e1');
  SELECT count(*) INTO n FROM public.exos_eventbrite_sync_claim(pg_temp.u('e1'), pg_temp.u('a3'));
  ASSERT n = 0, 'E3: sync now twice in 20 s';
  BEGIN
    PERFORM public.exos_eventbrite_sync_claim(pg_temp.u('e1'), pg_temp.u('a4'));
    RAISE EXCEPTION 'E3: a scanner assigned elsewhere synced';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_eventbrite_sync_claim(pg_temp.u('e1'), pg_temp.u('a6'));
    RAISE EXCEPTION 'E3: an outsider synced';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  SELECT count(*) INTO n FROM public.exos_eventbrite_sync_claim(pg_temp.u('e2'), pg_temp.u('a1'));
  ASSERT n = 0, 'E3: unlinked event';
END $$;

-- E4. Apply a page, more to come.
DO $$
DECLARE r jsonb; v_csv uuid;
BEGIN
  -- The CSV import already brought one attendee in (barcode 7001 0001).
  PERFORM pg_temp.act('e5000000-0000-0000-0000-0000000000a1');
  v_csv := public.exos_upsert_guest_list(pg_temp.u('e1'), 'Eventbrite import');
  PERFORM public.exos_import_guests(v_csv, jsonb_build_array(
    jsonb_build_object('name', 'Ada Lovelace', 'code', '7001 0001', 'source', 'Eventbrite')));
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_eventbrite_links SET lease_until = now() + interval '2 minutes' WHERE event_id = pg_temp.u('e1');

  r := pg_temp.ap(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('ref', '9001', 'code', '70010001', 'name', 'Ada Lovelace', 'ticket', 'GA', 'void', false),
    jsonb_build_object('ref', '9002', 'code', '70010002', 'name', 'Bo Diddley', 'email', 'BO@X.COM', 'ticket', 'VIP', 'void', false),
    jsonb_build_object('ref', '9003', 'code', '70010003', 'name', 'Cy Refunded', 'void', true, 'reason', 'refunded'),
    jsonb_build_object('ref', 'abc', 'name', 'Bad ref', 'void', false),
    jsonb_build_object('ref', '9004', 'name', 'No Barcode', 'void', false)),
    'more', 'CONT-1');
  ASSERT r->>'added' = '2' AND r->>'updated' = '1' AND r->>'skipped' = '1' AND r->>'errors' = '0'
         AND r->>'invalid' = '1', 'E4: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries WHERE event_id = pg_temp.u('e1') AND external_code = '70010001') = 1,
         'E4: CSV entry adopted, not duplicated';
  ASSERT (pg_temp.entry('9001')).list_id = v_csv AND (pg_temp.entry('9001')).ticket_label = 'GA', 'E4: adopted entry';
  ASSERT (pg_temp.entry('9002')).email = 'bo@x.com' AND (pg_temp.entry('9002')).source = 'Eventbrite'
         AND (pg_temp.entry('9002')).ticket_label = 'VIP', 'E4: new entry';
  ASSERT (pg_temp.entry('9003')).id IS NULL, 'E4: voided never-seen attendee added';
  ASSERT (pg_temp.entry('9004')).external_code IS NULL, 'E4: no-barcode attendee by name';
  ASSERT (SELECT continuation = 'CONT-1' AND lease_until > now() FROM public.exos_eventbrite_links
           WHERE event_id = pg_temp.u('e1')), 'E4: continuation + lease kept';
  -- The run stops with pages left: saved, link freed, claimed again next run.
  r := pg_temp.ap(pg_temp.u('e1'), '[]'::jsonb, 'pause', 'CONT-2');
  ASSERT (SELECT continuation = 'CONT-2' AND lease_until IS NULL AND pass_started_at IS NOT NULL
            FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')), 'E4: paused';
  ASSERT (SELECT c.continuation FROM public.exos_eventbrite_sync_claim() c WHERE c.event_id = pg_temp.u('e1')) = 'CONT-2',
         'E4: a paused pass resumes on the next cron run';
END $$;

-- E5. Apply the last page.
DO $$
DECLARE r jsonb; v_start timestamptz;
BEGIN
  UPDATE public.exos_eventbrite_links SET pass_started_at = now() - interval '5 minutes' WHERE event_id = pg_temp.u('e1');
  SELECT pass_started_at INTO v_start FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1');
  r := pg_temp.ap(pg_temp.u('e1'), '[]'::jsonb, 'done');
  ASSERT r->>'ok' = 'true', 'E5: ' || r::text;
  ASSERT (SELECT sync_cursor = v_start AND pass_started_at IS NULL AND continuation IS NULL
                 AND lease_until IS NULL AND last_ok_at IS NOT NULL AND last_error IS NULL
            FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')), 'E5: state';
  r := pg_temp.ap(pg_temp.u('e2'), '[]'::jsonb, 'done');
  ASSERT r->>'reason' = 'not-linked', 'E5: unlinked';
END $$;

-- E6. Void and restore.
DO $$
DECLARE r jsonb; v_g uuid; v_sold int;
BEGIN
  v_g := (pg_temp.entry('9002')).id;
  r := pg_temp.ap(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('ref', '9002', 'code', '70010002', 'name', 'Bo Diddley', 'void', true, 'reason', 'refunded')), 'done');
  ASSERT r->>'voided' = '1', 'E6: ' || r::text;
  ASSERT (pg_temp.entry('9002')).voided_at IS NOT NULL AND (pg_temp.entry('9002')).void_reason = 'refunded', 'E6: voided';

  PERFORM pg_temp.act('e5000000-0000-0000-0000-0000000000a3');
  r := public.exos_guest_check_in(v_g, 1, pg_temp.u('e1'), gen_random_uuid());
  ASSERT r->>'ok' = 'false' AND r->>'reason' = 'voided' AND r->>'source' = 'Eventbrite', 'E6: door refused ' || r::text;
  r := public.exos_event_door_extras(pg_temp.u('e1'));
  ASSERT (SELECT (g->>'voided')::boolean FROM jsonb_array_elements(r->'guests') g WHERE g->>'id' = v_g::text),
         'E6: download marks voided';
  ASSERT (SELECT g->>'void_reason' FROM jsonb_array_elements(r->'guests') g WHERE g->>'id' = v_g::text) = 'refunded',
         'E6: download says why';

  PERFORM pg_temp.act(NULL);
  r := pg_temp.ap(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('ref', '9002', 'code', '70010002', 'name', 'Bo Diddley', 'void', false)), 'done');
  ASSERT r->>'restored' = '1', 'E6: restored ' || r::text;
  PERFORM pg_temp.act('e5000000-0000-0000-0000-0000000000a3');
  r := public.exos_guest_check_in(v_g, 1, pg_temp.u('e1'), gen_random_uuid());
  ASSERT r->>'ok' = 'true' AND r->>'reason' = 'checked-in', 'E6: restored checks in ' || r::text;

  -- Voiding and restoring never touch the house capacity, even on a list
  -- that counts toward it (remove / delete-list paths count heads as stored).
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_guest_lists SET counts_toward_capacity = true
   WHERE id = (pg_temp.entry('9004')).list_id;
  UPDATE public.exos_events SET tickets_sold = 10 WHERE id = pg_temp.u('e1');
  PERFORM pg_temp.ap(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('ref', '9004', 'name', 'No Barcode', 'void', true, 'reason', 'cancelled')), 'done');
  PERFORM pg_temp.ap(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('ref', '9004', 'name', 'No Barcode', 'void', false)), 'done');
  SELECT tickets_sold INTO v_sold FROM public.exos_events WHERE id = pg_temp.u('e1');
  ASSERT v_sold = 10, 'E6: capacity unchanged ' || v_sold;
END $$;

-- E7. Status.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.ap(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('ref', '9004', 'name', 'No Barcode', 'void', true)), 'done');
  PERFORM pg_temp.act('e5000000-0000-0000-0000-0000000000a3');
  r := public.exos_eventbrite_status(pg_temp.u('e1'));
  ASSERT r->>'connected' = 'true' AND r->>'can_manage' = 'false' AND r->>'account_name' = 'Blue Room', 'E7: ' || r::text;
  ASSERT r->'link'->>'eb_event_id' = '111' AND (r->'link'->>'attendees')::int = 2 AND (r->'link'->>'voided')::int = 1,
         'E7: link ' || (r->'link')::text;
  ASSERT position('TOKEN' in r::text) = 0, 'E7: token leaked';
  PERFORM pg_temp.act('e5000000-0000-0000-0000-0000000000a1');
  r := public.exos_eventbrite_status(pg_temp.u('e2'));
  ASSERT r->>'can_manage' = 'true' AND r->'link' = 'null'::jsonb, 'E7: unlinked event ' || r::text;
  PERFORM pg_temp.act('e5000000-0000-0000-0000-0000000000a4');
  BEGIN
    PERFORM public.exos_eventbrite_status(pg_temp.u('e1'));
    RAISE EXCEPTION 'E7: a scanner assigned elsewhere saw it';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act('e5000000-0000-0000-0000-0000000000a6');
  BEGIN
    PERFORM public.exos_eventbrite_status(pg_temp.u('e1'));
    RAISE EXCEPTION 'E7: an outsider saw it';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act(NULL);
END $$;

-- E8. Errors.
DO $$
BEGIN
  UPDATE public.exos_eventbrite_links
     SET lease_until = now() + interval '1 minute', continuation = 'CONT-9', pass_started_at = now()
   WHERE event_id = pg_temp.u('e1');
  PERFORM pg_temp.ap(pg_temp.u('e1'), '[]'::jsonb, 'error', NULL, 'Eventbrite said 401');
  ASSERT (SELECT last_error = 'Eventbrite said 401' AND lease_until IS NULL AND continuation IS NULL
                 AND pass_started_at IS NULL AND sync_cursor IS NOT NULL
            FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')), 'E8: state';
  -- The cron waits 10 minutes after an error.
  UPDATE public.exos_eventbrite_links SET last_synced_at = now() - interval '5 minutes' WHERE event_id = pg_temp.u('e1');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_sync_claim() c WHERE c.event_id = pg_temp.u('e1')), 'E8: backoff';
  UPDATE public.exos_eventbrite_links SET last_synced_at = now() - interval '11 minutes' WHERE event_id = pg_temp.u('e1');
  ASSERT EXISTS (SELECT 1 FROM public.exos_eventbrite_sync_claim() c WHERE c.event_id = pg_temp.u('e1')), 'E8: retried';
  UPDATE public.exos_eventbrite_links SET lease_until = NULL WHERE event_id = pg_temp.u('e1');
  BEGIN
    PERFORM pg_temp.ap(pg_temp.u('e1'), '[]'::jsonb, 'later');
    RAISE EXCEPTION 'E8: bad state accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM pg_temp.ap(pg_temp.u('e1'), '{}'::jsonb, 'done');
    RAISE EXCEPTION 'E8: an object accepted as rows';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END $$;

-- E11. A run overtaken by a relink writes nothing; a failed row keeps the cursor.
DO $$
DECLARE r jsonb; v_old uuid; v_cur timestamptz;
BEGIN
  UPDATE public.exos_eventbrite_links SET lease_until = NULL, last_synced_at = NULL, last_error = NULL
   WHERE event_id = pg_temp.u('e1');
  SELECT c.lease_id INTO v_old FROM public.exos_eventbrite_sync_claim() c WHERE c.event_id = pg_temp.u('e1');
  ASSERT v_old IS NOT NULL, 'E11: claimed';
  PERFORM public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a1'), '113', 'Another one');
  r := public.exos_eventbrite_apply(pg_temp.u('e1'), v_old, jsonb_build_array(
    jsonb_build_object('ref', '9100', 'name', 'Stale', 'void', false)), 'more', 'OLD-CONT');
  ASSERT r->>'reason' = 'lease-lost', 'E11: ' || r::text;
  ASSERT (pg_temp.entry('9100')).id IS NULL, 'E11: stale row written';
  ASSERT (SELECT continuation IS NULL AND sync_cursor IS NULL FROM public.exos_eventbrite_links
           WHERE event_id = pg_temp.u('e1')), 'E11: stale state written';
  -- The /link sync can claim straight away.
  ASSERT EXISTS (SELECT 1 FROM public.exos_eventbrite_sync_claim(pg_temp.u('e1'), pg_temp.u('a1'))), 'E11: relink sync claims';
  -- A pass with a failed row (a barcode another guest holds) doesn't move the cursor.
  UPDATE public.exos_eventbrite_links SET sync_cursor = now() - interval '1 day' WHERE event_id = pg_temp.u('e1');
  SELECT sync_cursor INTO v_cur FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1');
  r := pg_temp.ap(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('ref', '9200', 'code', '70010001', 'name', 'Clash', 'void', false)), 'more', 'K2');
  ASSERT r->>'errors' = '1', 'E11: clash ' || r::text;
  r := pg_temp.ap(pg_temp.u('e1'), '[]'::jsonb, 'done');
  ASSERT (SELECT sync_cursor = v_cur AND row_errors = 1 AND pass_errors = 0 AND pass_started_at IS NULL
            FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')), 'E11: cursor kept';
  -- A clean pass moves it.
  UPDATE public.exos_eventbrite_links SET pass_started_at = now() WHERE event_id = pg_temp.u('e1');
  PERFORM pg_temp.ap(pg_temp.u('e1'), '[]'::jsonb, 'done');
  ASSERT (SELECT sync_cursor > v_cur AND row_errors = 0 FROM public.exos_eventbrite_links
           WHERE event_id = pg_temp.u('e1')), 'E11: cursor moved';
  -- A successful page clears an earlier error.
  UPDATE public.exos_eventbrite_links SET last_error = 'old' WHERE event_id = pg_temp.u('e1');
  PERFORM pg_temp.ap(pg_temp.u('e1'), '[]'::jsonb, 'pause', 'K5');
  ASSERT (SELECT last_error IS NULL FROM public.exos_eventbrite_links WHERE event_id = pg_temp.u('e1')), 'E11: error cleared';
  UPDATE public.exos_eventbrite_links SET continuation = NULL, pass_started_at = NULL, lease_until = NULL
   WHERE event_id = pg_temp.u('e1');
END $$;

-- E9. Disconnect.
DO $$
DECLARE r jsonb;
BEGIN
  BEGIN
    PERFORM public.exos_eventbrite_disconnect(pg_temp.org(), pg_temp.u('a3'));
    RAISE EXCEPTION 'E9: a scanner disconnected';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  r := public.exos_eventbrite_disconnect(pg_temp.org(), pg_temp.u('a1'));
  ASSERT r->>'connected' = 'false' AND (r->>'unlinked')::int = 2, 'E9: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'exos_eventbrite:' || pg_temp.org()), 'E9: secret gone';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_links WHERE org_id = pg_temp.org()), 'E9: links gone';
  ASSERT (pg_temp.entry('9001')).id IS NOT NULL, 'E9: guests stay';
  ASSERT public.exos_eventbrite_token(pg_temp.org(), pg_temp.u('a1')) IS NULL, 'E9: no token';
  BEGIN
    PERFORM public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a1'), '111', 'x');
    RAISE EXCEPTION 'E9: linked without an account';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END $$;

-- E10. Grants.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_eventbrite_connect(uuid,uuid,text,text)', 'public.exos_eventbrite_disconnect(uuid,uuid)',
    'public.exos_eventbrite_token(uuid,uuid)', 'public.exos_eventbrite_link(uuid,uuid,text,text)',
    'public.exos_eventbrite_unlink(uuid,uuid)', 'public.exos_eventbrite_sync_claim(uuid,uuid,integer)',
    'public.exos_eventbrite_apply(uuid,uuid,jsonb,text,text,text)', 'public._exos_eb_role(uuid,uuid,uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'E10: authenticated may run ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'E10: anon may run ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'E10: service role may not run ' || f;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_eventbrite_status(uuid)', 'EXECUTE'), 'E10: status';
  ASSERT NOT has_function_privilege('anon', 'public.exos_eventbrite_status(uuid)', 'EXECUTE'), 'E10: anon status';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_eventbrite_accounts', 'SELECT'), 'E10: accounts table';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_eventbrite_links', 'SELECT'), 'E10: links table';
END $$;

\echo 'test_eventbrite_sync: all passed'
ROLLBACK;
