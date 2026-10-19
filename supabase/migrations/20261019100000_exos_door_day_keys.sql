-- ============================================================================
-- Per-day door keys: door phones stop holding barcode secrets
-- ============================================================================
-- Touches:  C: FUNCTION _exos_b64url, _exos_door_day_key, _exos_door_code_mac,
--              _exos_door_keys (internal, no client grant)
--           C: FUNCTION exos_event_door_roster, exos_door_ticket_keys (authenticated,
--              door roles only)
--           R: CREATE OR REPLACE exos_can_read_ticket_secret (holder / buyer / admin only)
--           P: exos_event_checkin_roster, exos_event_checkin_roster_since
--              (barcode_secret now always NULL)
--           P: exos_check_in_ticket, both overloads (a T- code signed with the
--              day key is accepted; one signed with the secret still is)
-- Pre-reqs: 20260929072000 (wallet passes), 20260929140000 (door lists),
--           20261008090000 (roster delta)
--
-- Why: the door downloaded every ticket's barcode_secret (the roster, the
-- delta, the gated view). Anyone with a door phone, or a copy of its storage,
-- could mint a valid code for any ticket of the event at any time. Now:
--
--   day     = floor(bucket / 2880)        (2880 30-second buckets = one UTC day)
--   day_key = b64url(HMAC-SHA256(barcode_secret, 'door-day:{ticket}:{day}'))
--   mac     = b64url(HMAC-SHA256(day_key, '{ticket}:{owner}:{bucket}'))
--
-- The holder's app signs T- codes with the day key; the door gets yesterday's,
-- today's and tomorrow's keys and, for a live wallet pass, the SHA-256 of its
-- Apple code and its Google TOTP key (each already bound to one pass epoch).
-- supabase/functions/_shared/doorKeys.ts mirrors these functions;
-- src/lib/doorKeys.test.ts and tests/exos/test_door_day_keys.sql pin both to
-- the same vectors.
--
-- Order: apply this BEFORE the app that signs with day keys ships, or new
-- codes are refused at the door's server check. Apps that haven't reloaded
-- keep working: their secret-signed codes are still accepted by the server
-- (online only; the door can't check them offline any more).
-- ============================================================================

CREATE OR REPLACE FUNCTION public._exos_b64url(p bytea)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path = public, pg_temp AS $$
  SELECT rtrim(translate(encode(p, 'base64'), E'+/\n', '-_'), '=');
$$;

CREATE OR REPLACE FUNCTION public._exos_door_day_key(p_ticket uuid, p_secret text, p_day int)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path = public, pg_temp AS $$
  SELECT public._exos_b64url(extensions.hmac('door-day:' || p_ticket || ':' || p_day, p_secret, 'sha256'));
$$;

CREATE OR REPLACE FUNCTION public._exos_door_code_mac(p_ticket uuid, p_owner uuid, p_bucket bigint, p_secret text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path = public, pg_temp AS $$
  SELECT public._exos_b64url(extensions.hmac(
           p_ticket || ':' || p_owner || ':' || p_bucket,
           public._exos_door_day_key(p_ticket, p_secret, floor(p_bucket / 2880.0)::int),
           'sha256'));
$$;

-- What a door holds for one ticket: {"d": {day: key}, "wa", "wg", "we"}.
CREATE OR REPLACE FUNCTION public._exos_door_keys(p_ticket uuid, p_owner uuid, p_secret text)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_today int := floor(extract(epoch FROM now()) / 86400)::int;
  v_out   jsonb;
  v_epoch int;
BEGIN
  IF p_secret IS NULL OR p_secret = '' THEN
    RETURN jsonb_build_object('d', '{}'::jsonb);
  END IF;
  v_out := jsonb_build_object('d', jsonb_build_object(
    (v_today - 1)::text, public._exos_door_day_key(p_ticket, p_secret, v_today - 1),
    v_today::text,       public._exos_door_day_key(p_ticket, p_secret, v_today),
    (v_today + 1)::text, public._exos_door_day_key(p_ticket, p_secret, v_today + 1)));
  IF p_owner IS NOT NULL THEN
    SELECT code_epoch INTO v_epoch
      FROM public.exos_wallet_passes
     WHERE ticket_id = p_ticket AND status = 'active' AND owner_id = p_owner;
    IF v_epoch IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(
        'we', v_epoch,
        'wa', encode(extensions.digest(public._exos_wallet_apple_code(p_ticket, p_owner, p_secret, v_epoch), 'sha256'), 'hex'),
        'wg', encode(public._exos_wallet_google_key(p_ticket, p_owner, p_secret, v_epoch), 'hex'));
    END IF;
  END IF;
  RETURN v_out;
END $$;

REVOKE ALL ON FUNCTION public._exos_b64url(bytea) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_door_day_key(uuid, text, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_door_code_mac(uuid, uuid, bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_door_keys(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- ── The door roster, with keys instead of secrets ──────────────────────────
-- Full when p_since is NULL; otherwise the tickets that changed since (the same
-- rule as exos_event_checkin_roster_since, mig 20261008090000).
CREATE OR REPLACE FUNCTION public.exos_event_door_roster(p_event_id uuid, p_since timestamptz DEFAULT NULL)
RETURNS TABLE(ticket_id uuid, status text, owner_id uuid, owner_name text, tier_name text, door_keys jsonb,
              promoter_id text, pending_transfer_id uuid, parked boolean, claim_name text,
              claim_email_masked text, tier_id uuid, list_state jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_door_roster: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_since IS NOT NULL AND p_since < now() - interval '7 days' THEN
    RAISE EXCEPTION 'exos_event_door_roster: since must be within 7 days (do a full pull)' USING ERRCODE = '22023';
  END IF;
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_event_door_roster: event not found';
  END IF;
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_event_door_roster: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_event_door_roster: not assigned to this event' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT t.id, t.status, t.owner_id,
           CASE WHEN pk.parked
                THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), ''),
                              public.exos_mask_email(lower(btrim(tr.receiver_email))), 'Unclaimed ticket')
                ELSE coalesce(nullif(t.attendee_name, ''), p.display_name) END,
           t.tier_name, public._exos_door_keys(t.id, t.owner_id, t.barcode_secret), t.promoter_id,
           t.pending_transfer_id, pk.parked,
           CASE WHEN pk.parked THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), '')) END,
           CASE WHEN pk.parked THEN public.exos_mask_email(lower(btrim(tr.receiver_email))) END,
           t.tier_id,
           (SELECT jsonb_object_agg(x.list_id, x.direction)
              FROM (SELECT DISTINCT ON (ci.list_id) ci.list_id, ci.direction
                      FROM public.exos_event_checkins ci
                      JOIN public.exos_checkin_lists l ON l.id = ci.list_id AND l.allow_reentry
                     WHERE ci.ticket_id = t.id
                     ORDER BY ci.list_id, coalesce(ci.offline_scanned_at, ci.scanned_at) DESC, ci.scanned_at DESC) x)
    FROM public.exos_tickets t
    LEFT JOIN public.exos_profiles p ON p.id = t.owner_id
    LEFT JOIN public.exos_transfers tr ON tr.id = t.pending_transfer_id
    CROSS JOIN LATERAL (SELECT (t.pending_transfer_id IS NOT NULL AND public._exos_ticket_parked(t, tr)) AS parked) pk
    WHERE t.event_id = p_event_id
      AND (p_since IS NULL
           OR t.updated_at >= p_since
           OR tr.updated_at >= p_since
           OR p.updated_at >= p_since
           OR t.id IN (SELECT ci.ticket_id FROM public.exos_event_checkins ci
                        WHERE ci.event_id = p_event_id AND ci.scanned_at >= p_since));
END $$;

REVOKE ALL ON FUNCTION public.exos_event_door_roster(uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_door_roster(uuid, timestamptz) TO authenticated;

-- One ticket's keys, for the scanner's online lookup (fast local fail).
CREATE OR REPLACE FUNCTION public.exos_door_ticket_keys(p_ticket_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  t public.exos_tickets%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_door_ticket_keys: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF t.id IS NULL THEN
    RETURN NULL;
  END IF;
  IF NOT (public.exos_is_admin()
          OR (public.exos_has_org_role(t.org_id, ARRAY['owner','manager','scanner'])
              AND public.exos_can_door_event(t.event_id))) THEN
    RAISE EXCEPTION 'exos_door_ticket_keys: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_door_keys(t.id, t.owner_id, t.barcode_secret);
END $$;

REVOKE ALL ON FUNCTION public.exos_door_ticket_keys(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_door_ticket_keys(uuid) TO authenticated;

-- ── The secret itself: the ticket's holder and buyer (and platform admin) ──
-- Door staff read keys, above. (Was: + owner / manager / scanner of the org,
-- for events they may work.) The comment in the body keeps mig 20260929041000's
-- patch marker, so replaying that migration leaves this version alone.
CREATE OR REPLACE FUNCTION public.exos_can_read_ticket_secret(p_ticket_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  -- door staff: exos_door_ticket_keys / exos_event_door_roster, not this
  -- (was: org door roles AND exos_can_door_event(t.event_id)).
  SELECT EXISTS (
    SELECT 1 FROM public.exos_tickets t
    WHERE t.id = p_ticket_id
      AND (t.owner_id = auth.uid() OR t.buyer_id = auth.uid() OR public.exos_is_admin())
  );
$$;
REVOKE EXECUTE ON FUNCTION public.exos_can_read_ticket_secret(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_can_read_ticket_secret(uuid) TO authenticated, service_role;

-- ── Patches ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  -- Pasted through a browser the patch text can carry CRLF line ends; compare without CRs.
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
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

-- The old roster RPCs stay (an app that hasn't reloaded calls them) but no
-- longer carry the secret.
SELECT pg_temp.exos_patch_n('public.exos_event_checkin_roster(uuid)', 'NULL::text /* door keys */',
  't.tier_name, t.barcode_secret, t.promoter_id',
  't.tier_name, NULL::text /* door keys */, t.promoter_id', 1);
SELECT pg_temp.exos_patch_n('public.exos_event_checkin_roster_since(uuid, timestamp with time zone)', 'NULL::text /* door keys */',
  't.tier_name, t.barcode_secret, t.promoter_id',
  't.tier_name, NULL::text /* door keys */, t.promoter_id', 1);

-- Check-in: a T- code passes with the day-key MAC (or, from an app that hasn't
-- reloaded, the secret-keyed one).
SELECT pg_temp.exos_patch_n(sig, '_exos_door_code_mac',
  'IF v_exp <> v_parts[4] THEN',
  'IF v_exp <> v_parts[4]
           AND public._exos_door_code_mac(p_ticket_id, v_owner, v_bkt, coalesce(v_secret, '''')) IS DISTINCT FROM v_parts[4] THEN', 1)
  FROM unnest(ARRAY[
    'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamp with time zone, text)',
    'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamp with time zone, text, uuid, text)']) sig;
