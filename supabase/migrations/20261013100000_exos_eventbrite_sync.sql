-- ============================================================================
-- Exos Door: live attendee sync from Eventbrite (read-only)
-- ============================================================================
-- Touches:  C: TABLE exos_eventbrite_accounts, exos_eventbrite_links (new;
--              service role only)
--           W: exos_guest_list_entries (+ external_ref, voided_at,
--              void_reason; unique external_ref per event)
--           C: FUNCTION _exos_eb_role, exos_eventbrite_connect,
--              exos_eventbrite_disconnect, exos_eventbrite_token,
--              exos_eventbrite_link, exos_eventbrite_unlink,
--              exos_eventbrite_sync_claim, exos_eventbrite_apply (service
--              role only), exos_eventbrite_status (authenticated)
--           W: FUNCTION exos_guest_check_in (patched in place: a voided guest
--              is refused), exos_event_door_extras (patched in place: + voided)
--           C: cron.schedule (exos-eventbrite-sync-2min, when pg_cron present)
--           R: vault.secrets / vault.create_secret / vault.update_secret /
--              vault.decrypted_secrets (Supabase Vault), exos_events,
--              exos_org_memberships, exos_event_staff, exos_guest_lists
-- Pre-reqs: 20261013090000 (imported codes on guest entries, door extras
--           carrying code / ticket / source: the patch anchors on it)
--
-- The CSV import (20261013090000) is a snapshot: a ticket bought on
-- Eventbrite after the export isn't at the door, and a refunded one still
-- gets in. This keeps an Exos door event in step with its Eventbrite event:
--
-- 1. An owner / manager pastes an Eventbrite private token (Account settings
--    -> Developer links -> API keys). The exos-eventbrite-sync edge function
--    checks it with GET /users/me/ and stores it in Vault
--    (exos_eventbrite:<org>) through exos_eventbrite_connect. Nobody reads it
--    back except the service role.
-- 2. They link an Exos event to one of their Eventbrite events
--    (exos_eventbrite_link). The attendees land in that event's "Eventbrite"
--    guest list, which is created if missing (no cap, does not count toward
--    the house capacity).
-- 3. The edge function pulls GET /events/{id}/attendees/?changed_since=…
--    (every 2 minutes from two days before the event, every 30 minutes
--    before that, never once it is two days past) and hands each page to
--    exos_eventbrite_apply: new attendees are added, names and ticket types
--    follow Eventbrite, and a refunded, cancelled or deleted ticket is
--    VOIDED (voided_at): the door refuses it, by scan or by name. A ticket
--    that comes back (an undone refund) is un-voided. A voided attendee
--    never imported is not added.
--
-- Eventbrite is only read. Nothing is written to it: no check-ins, no
-- webhooks, no orders (CLAUDE.md, upstream APIs are read-only). Keyed on the
-- attendee id (external_ref 'eb:<id>'); an entry the CSV import already made
-- with the same barcode is adopted, not duplicated.
--
-- The claim takes a 2-minute lease per link, so the cron and a "Sync now" tap
-- never run the same link at once. A pass that needs more pages than one run
-- allows keeps Eventbrite's continuation token and resumes next run.
--
-- Order: deploy exos-eventbrite-sync, then apply (section 9 schedules its
-- cron when pg_cron is present).
--
-- Re-run safe. D4 authors; applying to prod is operator-gated. Not applied.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := pg_get_functiondef(p_fn);
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

-- ---------------------------------------------------------------------------
-- 1. Guest entries: the other platform's attendee id, and voiding.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_guest_list_entries
  ADD COLUMN IF NOT EXISTS external_ref text,
  ADD COLUMN IF NOT EXISTS voided_at    timestamptz,
  ADD COLUMN IF NOT EXISTS void_reason  text;

DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_guest_entries_external_ref_chk') THEN
    ALTER TABLE public.exos_guest_list_entries ADD CONSTRAINT exos_guest_entries_external_ref_chk
      CHECK (external_ref IS NULL OR external_ref ~ '^[a-z]{2,8}:[A-Za-z0-9_-]{1,64}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_guest_entries_void_reason_chk') THEN
    ALTER TABLE public.exos_guest_list_entries ADD CONSTRAINT exos_guest_entries_void_reason_chk
      CHECK (void_reason IS NULL OR length(void_reason) <= 40);
  END IF;
END $c$;

CREATE UNIQUE INDEX IF NOT EXISTS exos_guest_entries_event_ref_uq
  ON public.exos_guest_list_entries (event_id, external_ref) WHERE external_ref IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Accounts (one Eventbrite token per org) and event links.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_eventbrite_accounts (
  org_id        uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  secret_id     uuid NOT NULL,          -- vault.secrets id (exos_eventbrite:<org>)
  account_name  text CHECK (account_name IS NULL OR length(account_name) <= 120),
  connected_by  uuid,
  connected_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_eventbrite_accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_eventbrite_accounts FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_eventbrite_accounts TO service_role;
COMMENT ON TABLE public.exos_eventbrite_accounts IS
  'Exos Door: an org''s Eventbrite private token (in Vault; read-only sync). Service role only. mig 20261013100000.';

CREATE TABLE IF NOT EXISTS public.exos_eventbrite_links (
  event_id        uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  eb_event_id     text NOT NULL CONSTRAINT exos_eventbrite_links_eb_id_chk CHECK (eb_event_id ~ '^[0-9]{1,24}$'),
  eb_event_name   text CHECK (eb_event_name IS NULL OR length(eb_event_name) <= 200),
  list_id         uuid NOT NULL REFERENCES public.exos_guest_lists (id) ON DELETE CASCADE,
  linked_by       uuid,
  linked_at       timestamptz NOT NULL DEFAULT now(),
  sync_cursor     timestamptz,          -- changed_since for the next pass (NULL: everything)
  pass_started_at timestamptz,          -- the running pass's start: the next cursor once it completes
  continuation    text CHECK (continuation IS NULL OR length(continuation) <= 2048),
  lease_until     timestamptz,
  last_synced_at  timestamptz,
  last_ok_at      timestamptz,
  last_error      text CHECK (last_error IS NULL OR length(last_error) <= 200),
  CONSTRAINT exos_eventbrite_links_eb_uq UNIQUE (org_id, eb_event_id)
);
CREATE INDEX IF NOT EXISTS exos_eventbrite_links_due_idx ON public.exos_eventbrite_links (last_synced_at NULLS FIRST);
ALTER TABLE public.exos_eventbrite_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_eventbrite_links FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_eventbrite_links TO service_role;
COMMENT ON TABLE public.exos_eventbrite_links IS
  'Exos Door: an Exos event kept in step with an Eventbrite event''s attendees (read-only). Service role only. mig 20261013100000.';

-- The user's active role in the org (NULL: none). The service-role RPCs
-- take the user id from the edge function's verified JWT (auth.uid() is
-- NULL for the service role). p_event: also apply the scanner event scope
-- of exos_can_door_event, for that user.
CREATE OR REPLACE FUNCTION public._exos_eb_role(p_org_id uuid, p_user_id uuid, p_event_id uuid DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT m.role FROM public.exos_org_memberships m
   WHERE p_org_id IS NOT NULL AND p_user_id IS NOT NULL
     AND m.org_id = p_org_id AND m.user_id = p_user_id AND m.disabled IS NOT TRUE
     AND m.role IN ('owner', 'manager', 'scanner')
     AND (m.role <> 'scanner' OR p_event_id IS NULL
          OR EXISTS (SELECT 1 FROM public.exos_event_staff s WHERE s.event_id = p_event_id AND s.user_id = m.user_id)
          OR NOT EXISTS (SELECT 1 FROM public.exos_event_staff s WHERE s.org_id = m.org_id AND s.user_id = m.user_id))
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_eb_role(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_eb_role(uuid, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Connect / disconnect (owner / manager). The edge function has already
-- checked the token with Eventbrite (GET /users/me/).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_eventbrite_connect(
  p_org_id uuid, p_user_id uuid, p_token text, p_account_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_secret uuid;
  v_name   text := 'exos_eventbrite:' || p_org_id::text;
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_connect: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_token IS NULL OR p_token !~ '^[A-Za-z0-9_-]{8,255}$' THEN
    RAISE EXCEPTION 'exos_eventbrite_connect: bad token' USING ERRCODE = '22023';
  END IF;

  SELECT secret_id INTO v_secret FROM public.exos_eventbrite_accounts WHERE org_id = p_org_id FOR UPDATE;
  IF v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_secret) THEN
    SELECT id INTO v_secret FROM vault.secrets WHERE name = v_name;
  END IF;
  IF v_secret IS NULL THEN
    v_secret := vault.create_secret(p_token, v_name, 'Exos Door: Eventbrite private token (read-only sync)');
  ELSE
    PERFORM vault.update_secret(v_secret, p_token);
  END IF;

  INSERT INTO public.exos_eventbrite_accounts AS a (org_id, secret_id, account_name, connected_by, connected_at)
  VALUES (p_org_id, v_secret, left(nullif(btrim(coalesce(p_account_name, '')), ''), 120), p_user_id, now())
  ON CONFLICT (org_id) DO UPDATE
     SET secret_id = EXCLUDED.secret_id, account_name = EXCLUDED.account_name,
         connected_by = EXCLUDED.connected_by, connected_at = EXCLUDED.connected_at;
  -- Another account may see other events: start every link's next pass over.
  UPDATE public.exos_eventbrite_links
     SET sync_cursor = NULL, continuation = NULL, pass_started_at = NULL, last_error = NULL
   WHERE org_id = p_org_id;
  RETURN jsonb_build_object('connected', true,
                            'account_name', left(nullif(btrim(coalesce(p_account_name, '')), ''), 120));
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_connect(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_connect(uuid, uuid, text, text) TO service_role;

-- The token is deleted from Vault and the links are removed. Imported guests
-- stay (and stay voided or not) so a door already set up keeps working.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_disconnect(p_org_id uuid, p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_secret uuid;
  v_links  int;
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_disconnect: owner or manager only' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_eventbrite_accounts WHERE org_id = p_org_id RETURNING secret_id INTO v_secret;
  DELETE FROM vault.secrets WHERE id = v_secret OR name = 'exos_eventbrite:' || p_org_id::text;
  DELETE FROM public.exos_eventbrite_links WHERE org_id = p_org_id;
  GET DIAGNOSTICS v_links = ROW_COUNT;
  RETURN jsonb_build_object('connected', false, 'unlinked', v_links);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_disconnect(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_disconnect(uuid, uuid) TO service_role;

-- The org's token, for the edge function to list events or check a link
-- (owner / manager only). NULL when not connected.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_token(p_org_id uuid, p_user_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_token: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT d.decrypted_secret FROM public.exos_eventbrite_accounts a
            JOIN vault.decrypted_secrets d ON d.id = a.secret_id
           WHERE a.org_id = p_org_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_token(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_token(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Link / unlink an Exos event (owner / manager). The edge function has
-- read the Eventbrite event with the org's token (GET /events/{id}/).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_eventbrite_link(
  p_event_id uuid, p_user_id uuid, p_eb_event_id text, p_eb_event_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e       public.exos_events%ROWTYPE;
  v_list  uuid;
  v_prev  text;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_eventbrite_link: event not found' USING ERRCODE = '22023';
  END IF;
  IF coalesce(public._exos_eb_role(e.org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_link: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_eventbrite_link: the event was cancelled' USING ERRCODE = '22023';
  END IF;
  IF p_eb_event_id IS NULL OR p_eb_event_id !~ '^[0-9]{1,24}$' THEN
    RAISE EXCEPTION 'exos_eventbrite_link: bad Eventbrite event id' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_accounts WHERE org_id = e.org_id) THEN
    RAISE EXCEPTION 'exos_eventbrite_link: connect Eventbrite first' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_eventbrite_links
              WHERE org_id = e.org_id AND eb_event_id = p_eb_event_id AND event_id <> p_event_id) THEN
    RAISE EXCEPTION 'exos_eventbrite_link: that Eventbrite event is already linked to another event' USING ERRCODE = '23505';
  END IF;

  SELECT id INTO v_list FROM public.exos_guest_lists
   WHERE event_id = p_event_id AND name = 'Eventbrite' ORDER BY created_at LIMIT 1;
  IF v_list IS NULL THEN
    INSERT INTO public.exos_guest_lists (event_id, org_id, name, max_plus_ones, counts_toward_capacity, created_by)
    VALUES (p_event_id, e.org_id, 'Eventbrite', 0, false, p_user_id)
    RETURNING id INTO v_list;
  END IF;

  SELECT eb_event_id INTO v_prev FROM public.exos_eventbrite_links WHERE event_id = p_event_id FOR UPDATE;
  INSERT INTO public.exos_eventbrite_links AS l
         (event_id, org_id, eb_event_id, eb_event_name, list_id, linked_by, linked_at)
  VALUES (p_event_id, e.org_id, p_eb_event_id, left(nullif(btrim(coalesce(p_eb_event_name, '')), ''), 200),
          v_list, p_user_id, now())
  ON CONFLICT (event_id) DO UPDATE
     SET eb_event_id = EXCLUDED.eb_event_id, eb_event_name = EXCLUDED.eb_event_name,
         list_id = EXCLUDED.list_id, linked_by = EXCLUDED.linked_by, linked_at = EXCLUDED.linked_at,
         -- Same Eventbrite event: keep the cursor. Another one: start over.
         sync_cursor     = CASE WHEN l.eb_event_id = EXCLUDED.eb_event_id THEN l.sync_cursor END,
         pass_started_at = CASE WHEN l.eb_event_id = EXCLUDED.eb_event_id THEN l.pass_started_at END,
         continuation    = CASE WHEN l.eb_event_id = EXCLUDED.eb_event_id THEN l.continuation END,
         last_error = NULL;
  RETURN jsonb_build_object('linked', true, 'list_id', v_list, 'relinked', v_prev IS NOT NULL AND v_prev <> p_eb_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_link(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_link(uuid, uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_eventbrite_unlink(p_event_id uuid, p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF coalesce(public._exos_eb_role(v_org, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_unlink: owner or manager only' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_eventbrite_links WHERE event_id = p_event_id;
  RETURN jsonb_build_object('linked', false);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_unlink(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_unlink(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Claim links to sync, with a 2-minute lease and the token.
--    p_event_id NULL: the cron; the links that are due, oldest first.
--    p_event_id set:  "Sync now" by p_user_id (door roles, scanner scope);
--                     at most every 20 seconds.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_eventbrite_sync_claim(
  p_event_id uuid DEFAULT NULL, p_user_id uuid DEFAULT NULL, p_limit integer DEFAULT 10
) RETURNS TABLE(event_id uuid, eb_event_id text, token text, sync_cursor timestamptz,
                continuation text, pass_started_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  v_org uuid;
BEGIN
  IF p_event_id IS NOT NULL THEN
    SELECT l.org_id INTO v_org FROM public.exos_eventbrite_links l WHERE l.event_id = p_event_id;
    IF v_org IS NULL THEN
      RETURN;
    END IF;
    IF public._exos_eb_role(v_org, p_user_id, p_event_id) IS NULL THEN
      RAISE EXCEPTION 'exos_eventbrite_sync_claim: not door staff for this event' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN QUERY
  WITH due AS (
    SELECT l.event_id
      FROM public.exos_eventbrite_links l
      JOIN public.exos_events e ON e.id = l.event_id
      JOIN public.exos_eventbrite_accounts a ON a.org_id = l.org_id
     WHERE (l.lease_until IS NULL OR l.lease_until < now())
       AND e.status <> 'cancelled'
       AND (p_event_id IS NOT NULL OR e.starts_at IS NULL OR e.starts_at > now() - interval '2 days')
       AND CASE
             WHEN p_event_id IS NOT NULL THEN
               l.event_id = p_event_id
               AND (l.last_synced_at IS NULL OR l.last_synced_at < now() - interval '20 seconds')
             ELSE
               -- after an error, wait 10 minutes (a bad token stays bad)
               (l.last_error IS NULL OR l.last_synced_at < now() - interval '10 minutes')
               AND (l.continuation IS NOT NULL OR l.last_synced_at IS NULL
               OR l.last_synced_at < now() - CASE WHEN e.starts_at IS NULL OR e.starts_at < now() + interval '2 days'
                                                  THEN interval '110 seconds' ELSE interval '29 minutes' END)
           END
     ORDER BY l.last_synced_at NULLS FIRST
     LIMIT LEAST(GREATEST(coalesce(p_limit, 10), 1), 50)
     FOR UPDATE OF l SKIP LOCKED
  )
  UPDATE public.exos_eventbrite_links l
     SET lease_until = now() + interval '2 minutes',
         last_synced_at = now(),
         pass_started_at = coalesce(l.pass_started_at, now())
    FROM due, public.exos_eventbrite_accounts a, vault.decrypted_secrets d
   WHERE l.event_id = due.event_id AND a.org_id = l.org_id AND d.id = a.secret_id
  RETURNING l.event_id, l.eb_event_id, d.decrypted_secret, l.sync_cursor, l.continuation, l.pass_started_at;
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_sync_claim(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_sync_claim(uuid, uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Apply a page (or a few) of attendees, and move the link's state.
--    p_rows: [{ref, code?, name?, email?, ticket?, void: bool, reason?}]
--      ref    Eventbrite attendee id (digits)
--      void   refunded / cancelled / not attending / deleted
--    p_state: 'more' (another page follows in this run: the lease is
--      renewed), 'pause' (this run stops here: p_continuation is where the
--      next run resumes, the lease is released), 'done' (the pass is
--      complete: the cursor moves to the pass's start), 'error' (p_error;
--      the cursor stays, p_continuation NULL restarts the pass).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_eventbrite_apply(
  p_event_id uuid, p_rows jsonb, p_state text, p_continuation text DEFAULT NULL, p_error text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  lk        public.exos_eventbrite_links%ROWTYPE;
  l         public.exos_guest_lists%ROWTYPE;
  r         jsonb;
  g         public.exos_guest_list_entries%ROWTYPE;
  v_ref     text;
  v_code    text;
  v_name    text;
  v_email   text;
  v_void    boolean;
  v_counts  boolean;
  v_id      uuid;
  v_added   int := 0;
  v_updated int := 0;
  v_voided  int := 0;
  v_restored int := 0;
  v_skipped int := 0;
  v_errors  int := 0;
BEGIN
  SELECT * INTO lk FROM public.exos_eventbrite_links WHERE event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-linked');
  END IF;
  IF p_state IS NULL OR p_state NOT IN ('more', 'pause', 'done', 'error') THEN
    RAISE EXCEPTION 'exos_eventbrite_apply: bad state %', p_state USING ERRCODE = '22023';
  END IF;
  IF p_rows IS NOT NULL AND (jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) > 2000) THEN
    RAISE EXCEPTION 'exos_eventbrite_apply: rows must be an array of at most 2000' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO l FROM public.exos_guest_lists WHERE id = lk.list_id;

  FOR r IN SELECT value FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) LOOP
    IF jsonb_typeof(r) <> 'object' OR coalesce(r->>'ref', '') !~ '^[0-9]{1,24}$' THEN
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;
    v_ref   := 'eb:' || (r->>'ref');
    v_code  := public._exos_door_code(r->>'code');
    v_name  := left(nullif(btrim(coalesce(r->>'name', '')), ''), 80);
    v_email := nullif(lower(btrim(coalesce(r->>'email', ''))), '');
    v_email := CASE WHEN v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(v_email) <= 254 THEN v_email END;
    v_void  := (r->'void') = 'true'::jsonb;

    BEGIN
      -- The attendee, or the entry the CSV import made from the same barcode.
      SELECT * INTO g FROM public.exos_guest_list_entries x
       WHERE x.event_id = p_event_id
         AND (x.external_ref = v_ref OR (v_code IS NOT NULL AND x.external_code = v_code AND x.external_ref IS NULL))
       ORDER BY (x.external_ref = v_ref) DESC NULLS LAST
       LIMIT 1
       FOR UPDATE;

      IF g.id IS NULL THEN
        IF v_void THEN
          v_skipped := v_skipped + 1;      -- refunded before we ever saw it
        ELSE
          v_id := public._exos_guest_insert(l.id, coalesce(v_name, 'Eventbrite guest'), v_email, NULL, 0, NULL,
                                            lk.linked_by, NULL);
          UPDATE public.exos_guest_list_entries
             SET external_ref = v_ref, external_code = v_code,
                 ticket_label = left(nullif(btrim(coalesce(r->>'ticket', '')), ''), 80),
                 source = 'Eventbrite'
           WHERE id = v_id;
          v_added := v_added + 1;
        END IF;
      ELSE
        UPDATE public.exos_guest_list_entries
           SET external_ref  = v_ref,
               external_code = coalesce(v_code, external_code),
               guest_name    = coalesce(v_name, guest_name),
               ticket_label  = coalesce(left(nullif(btrim(coalesce(r->>'ticket', '')), ''), 80), ticket_label),
               source        = coalesce(source, 'Eventbrite'),
               voided_at     = CASE WHEN v_void THEN coalesce(voided_at, now()) END,
               void_reason   = CASE WHEN v_void THEN left(coalesce(nullif(btrim(r->>'reason'), ''), 'refunded'), 40) END
         WHERE id = g.id;
        -- An entry on a list that counts toward the house cap gives its
        -- heads back on void and takes them again on restore.
        v_counts := coalesce((SELECT counts_toward_capacity FROM public.exos_guest_lists WHERE id = g.list_id), false);
        IF v_void AND g.voided_at IS NULL THEN
          v_voided := v_voided + 1;
          IF v_counts THEN
            PERFORM public._exos_guest_capacity(p_event_id, -(1 + g.plus_ones));
          END IF;
        ELSIF NOT v_void AND g.voided_at IS NOT NULL THEN
          IF v_counts THEN
            PERFORM public._exos_guest_capacity(p_event_id, 1 + g.plus_ones);
          END IF;
          v_restored := v_restored + 1;
        ELSE
          v_updated := v_updated + 1;
        END IF;
      END IF;
    EXCEPTION
      WHEN unique_violation OR check_violation OR raise_exception THEN
        -- e.g. a barcode another entry already holds, or the list is full.
        v_errors := v_errors + 1;
    END;
    g := NULL;
  END LOOP;

  UPDATE public.exos_eventbrite_links
     SET lease_until     = CASE WHEN p_state = 'more' THEN now() + interval '2 minutes' END,
         continuation    = CASE WHEN p_state IN ('more', 'pause', 'error') THEN left(p_continuation, 2048) END,
         sync_cursor     = CASE WHEN p_state = 'done' THEN coalesce(pass_started_at, now()) ELSE sync_cursor END,
         pass_started_at = CASE WHEN p_state = 'done' OR (p_state = 'error' AND p_continuation IS NULL) THEN NULL
                                ELSE pass_started_at END,
         last_ok_at      = CASE WHEN p_state = 'done' THEN now() ELSE last_ok_at END,
         last_error      = CASE WHEN p_state = 'error' THEN left(coalesce(nullif(btrim(p_error), ''), 'sync failed'), 200)
                                WHEN p_state = 'done' THEN NULL ELSE last_error END
   WHERE event_id = p_event_id;

  RETURN jsonb_build_object('ok', true, 'added', v_added, 'updated', v_updated, 'voided', v_voided,
                            'restored', v_restored, 'skipped', v_skipped, 'errors', v_errors);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_apply(uuid, jsonb, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_apply(uuid, jsonb, text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. What the door page shows (door roles, scanner scope). Never the token.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_eventbrite_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid;
  v_role text;
  a      public.exos_eventbrite_accounts%ROWTYPE;
  lk     public.exos_eventbrite_links%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_eventbrite_status: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  v_role := public._exos_eb_role(v_org, auth.uid(), p_event_id);
  IF v_role IS NULL AND NOT public.exos_is_admin() THEN
    RAISE EXCEPTION 'exos_eventbrite_status: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO a FROM public.exos_eventbrite_accounts WHERE org_id = v_org;
  SELECT * INTO lk FROM public.exos_eventbrite_links WHERE event_id = p_event_id;
  RETURN jsonb_build_object(
    'can_manage', v_role IN ('owner', 'manager') OR public.exos_is_admin(),
    'connected', a.org_id IS NOT NULL,
    'account_name', a.account_name,
    'link', CASE WHEN lk.event_id IS NULL THEN NULL ELSE jsonb_build_object(
      'eb_event_id', lk.eb_event_id, 'eb_event_name', lk.eb_event_name,
      'last_synced_at', lk.last_synced_at, 'last_ok_at', lk.last_ok_at, 'last_error', lk.last_error,
      'syncing', lk.lease_until IS NOT NULL AND lk.lease_until > now(),
      'attendees', (SELECT count(*) FROM public.exos_guest_list_entries g
                     WHERE g.event_id = p_event_id AND g.external_ref LIKE 'eb:%' AND g.voided_at IS NULL),
      'voided', (SELECT count(*) FROM public.exos_guest_list_entries g
                  WHERE g.event_id = p_event_id AND g.external_ref LIKE 'eb:%' AND g.voided_at IS NOT NULL)) END);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_status(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. The door refuses a voided guest; the download says which are voided.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_guest_check_in(uuid, integer, uuid, uuid, text)',
  'en.voided_at IS NOT NULL',
  $o$  IF p_event_id IS NULL OR en.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;$o$,
  $n$  IF p_event_id IS NULL OR en.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;
  -- door: voided on the platform that sold it (mig 20261013100000)
  IF en.voided_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'voided', 'source', en.source,
                              'void_reason', en.void_reason, 'arrived', en.arrived, 'party', en.plus_ones + 1);
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_event_door_extras(uuid)',
  $m$'voided', g.voided_at IS NOT NULL$m$,
  $o$'code', g.external_code, 'ticket', g.ticket_label, 'source', g.source)$o$,
  $n$'code', g.external_code, 'ticket', g.ticket_label, 'source', g.source,
               'voided', g.voided_at IS NOT NULL, 'void_reason', g.void_reason)$n$, 1);

-- ---------------------------------------------------------------------------
-- 9. Cron: every 2 minutes, odd minutes (off the :00 / :05 cluster). The
-- function decides which links are due. Guarded so a preview branch / CI
-- Postgres without pg_cron applies. Deploy exos-eventbrite-sync first.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-eventbrite-sync-2min') THEN
      PERFORM cron.unschedule('exos-eventbrite-sync-2min');
    END IF;
    PERFORM cron.schedule('exos-eventbrite-sync-2min', '1-59/2 * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-eventbrite-sync/cron', '{}'::jsonb);
    $cron$);
  END IF;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos-eventbrite-sync-2min');: re-create exos_guest_check_in and exos_event_door_extras
-- from 20261013090000 / their sources; DROP the functions and the two tables
-- above; DELETE FROM vault.secrets WHERE name LIKE 'exos_eventbrite:%'; DROP
-- the three guest-entry columns.
