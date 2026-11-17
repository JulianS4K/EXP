-- ============================================================================
-- Migration 20261118120000 — Exos: on-sale waiting room
-- ============================================================================
-- Growth R&D #2 (branch claude/exos-waiting-room). Big drops (an Instagram
-- on-sale, a fair grandstand) spike in seconds. An organizer can turn on a
-- waiting room for one event (off by default): buyers queue fairly and the
-- server lets them in in batches, so checkout and seat holds see a steady
-- stream instead of a stampede.
--
-- How it works:
--   * Settings per event (exos_wroom_settings): on / off, the window before
--     the on-sale when the room opens (default 15 minutes), the batch rate
--     (admits per minute), how long an admission lasts (N minutes) and how
--     long the room stays open with nobody waiting (it then closes itself).
--     Owner / manager only, audited (event.waiting_room).
--   * The on-sale moment is the event's public on-sale (the earliest
--     sales_start of its public sellable types, _exos_drop_open_at from the
--     drop list), or the moment the room was turned on if that is later
--     (turned on mid-sale: everyone is first come, first served). It is
--     frozen when the line is drawn.
--   * A visitor who arrives in the window gets a queue token (32 random
--     bytes, 64 hex). Only SHA-256(event_id:token) is stored, so a token is
--     unguessable, opaque, and means nothing for another event. One token per
--     browser: the page keeps it and presents it again; minting a new one is
--     rate limited per network.
--   * Fair start: everyone who arrived before the on-sale gets a RANDOM place
--     at the on-sale (the "draw", one statement under the room's lock, with
--     gen_random_bytes). Later arrivals go to the back in arrival order.
--   * Batches: admission runs on read (exos_wroom_status / _join and the
--     gate), at most once every 5 seconds per event, under a try-lock (one
--     admitter at a time, the others skip). Each run admits
--     rate * elapsed / 60 of the people at the front who polled in the last 3
--     minutes. A place not polled for 3 minutes is ABANDONED for good (the
--     page polls at least every ~40 s, background tabs about once a minute):
--     it never takes a turn, its token answers "expired, idle" and the page
--     offers a new join at the back, through every cap. An admission lasts N
--     minutes, then expires, also for good. So a freed place stays freed:
--     tokens can't be parked idle and revived past the caps.
--   * The gate: while the room is open, exos_create_hold,
--     exos_create_guest_hold and exos_claim_free_tickets refuse (XWR01) unless
--     the request carries an admitted, unexpired token for THAT event in the
--     x-exos-queue header (PostgREST's request.headers), checked first thing
--     in the body (marker /* exos: waiting room gate */); the event is also
--     taken from the ticket type. exos-checkout also calls exos_wroom_require
--     (service role) with the event and type it resolved, before any hold,
--     write or Stripe call, which covers the bypass-voucher checkouts that
--     skip the hold.
--   * Bypass, on purpose: the drop list presale type (mig 20261118100000)
--     during its early window (before the public on-sale it was set
--     against): its buyers are confirmed list members, the code works only
--     for them and only until the public on-sale, the type has its own capacity, and
--     queuing them behind the public line defeats the presale. Partner API
--     reservations and staff sales (POS, door, kiosk, comps) never use these
--     three functions: they are credentialed, rate limited per key or staff
--     and drawn from their own caps, and a server can't sit in a browser
--     queue.
--   * Closing: the organizer turns it off, or, after the on-sale, nobody has
--     been waiting for idle_close_minutes (checked on read). Then everyone
--     buys as usual. Turning it on again starts a new run (old tokens die).
--   * One buyer per turn: the first checkout / hold / claim binds the
--     admission to its buyer (SHA-256 of event + account id or guest email);
--     anyone else with the token is refused, and two checkouts on one turn at
--     the same time are refused (XWR02). The hold functions keep one live cart
--     per buyer and event, so a turn never holds two carts.
--   * Stuffing: minting is limited per network (IPv4 address / IPv6 /64: 60 a
--     minute; IPv6 /48: 120 a minute), by live places per network scaled
--     with the room's cap (IPv6 /48 greatest(20, cap / 50), IPv4 address
--     greatest(200, cap / 10), IPv6 /32 greatest(100, cap / 4)), and by the
--     room's cap on the LIVE line (organizer's number, else 5 x the public capacity, at least
--     1,000; abandoned, expired and used places free up): over those, "full".
--     A CAPTCHA in front of minting is the real fix for distributed stuffing
--     (follow-up).
--   * No PII: an entry is a token hash, times, a state, a hash of the
--     redeeming buyer and of the minting network (salted with the run). No
--     IP, user id or email in clear. A caller only ever sees its own place.
--   * No cron: everything runs on read.
--
-- Touches:  C: TABLE exos_wroom_settings, exos_wroom_entries, exos_wroom_counts (RLS on, no client
--              grants: RPCs only)
--           C: FUNCTION exos_wroom_join, exos_wroom_status (anon + authenticated;
--              H3 allowlist), exos_wroom_summary (owner / manager / finance),
--              exos_wroom_configure (owner / manager; audited
--              event.waiting_room), exos_wroom_require (service role), helpers
--              _exos_wroom_*
--           W: FUNCTION exos_create_hold, exos_create_guest_hold,
--              exos_claim_free_tickets (marker /* exos: waiting room gate */,
--              one PERFORM as the first statement of the body)
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ROLLBACK (manual): re-create the three patched functions without the gate
--   line (or leave it: with no settings row the gate returns at once), drop
--   the functions above and the two tables.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_wroom_settings (
  event_id            uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  enabled             boolean NOT NULL DEFAULT false,
  window_minutes      int NOT NULL DEFAULT 15 CHECK (window_minutes BETWEEN 0 AND 240),
  admit_per_minute    int NOT NULL DEFAULT 200 CHECK (admit_per_minute BETWEEN 1 AND 20000),
  admission_minutes   int NOT NULL DEFAULT 10 CHECK (admission_minutes BETWEEN 2 AND 60),
  idle_close_minutes  int NOT NULL DEFAULT 10 CHECK (idle_close_minutes BETWEEN 1 AND 240),
  -- Most people in one run's line; NULL = 5 x the public capacity (at least 1,000).
  max_entries         int CHECK (max_entries IS NULL OR max_entries BETWEEN 100 AND 1000000),
  -- The live line (waiting and seen in the last 3 minutes, or admitted and not
  -- yet expired or used) at the last recount (at most every 5 s), and the
  -- counter round that mints since then add to (exos_wroom_counts).
  live_count          int NOT NULL DEFAULT 0 CHECK (live_count >= 0),
  count_round         int NOT NULL DEFAULT 0 CHECK (count_round >= 0),
  counted_at          timestamptz,
  -- One run per "turned on": entries of another run are dead.
  run_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  enabled_at          timestamptz,
  -- Frozen at the draw: the on-sale the early arrivals were shuffled at.
  on_sale_at          timestamptz,
  drawn_at            timestamptz,
  -- Admissions are credited from here (rate per minute); advanced_at throttles.
  admit_clock         timestamptz,
  advanced_at         timestamptz,
  last_waiting_at     timestamptz,
  closed_at           timestamptz,
  closed_reason       text CHECK (closed_reason IS NULL OR closed_reason IN ('idle', 'organizer')),
  updated_by          uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_wroom_settings_org_idx ON public.exos_wroom_settings (org_id);
ALTER TABLE public.exos_wroom_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_wroom_settings FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_wroom_settings TO service_role;
DROP TRIGGER IF EXISTS exos_wroom_settings_touch ON public.exos_wroom_settings;
CREATE TRIGGER exos_wroom_settings_touch BEFORE UPDATE ON public.exos_wroom_settings
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- One row per queue token. No IP, user or email.
CREATE TABLE IF NOT EXISTS public.exos_wroom_entries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  run_id            uuid NOT NULL,
  token_hash        text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  arrived_at        timestamptz NOT NULL DEFAULT now(),
  -- Place in line: random in [0, 1) for an early arrival (set at the draw),
  -- the arrival epoch (always > 1) for a late one. NULL until the draw.
  order_key         double precision,
  state             text NOT NULL DEFAULT 'waiting' CHECK (state IN ('waiting', 'admitted', 'expired', 'abandoned')),
  admitted_at       timestamptz,
  admit_expires_at  timestamptz,
  -- First checkout / hold / free claim made with the admission, and who made
  -- it: SHA-256(event:uid:<id> or event:email:<address>). The turn is that
  -- buyer's from then on.
  used_at           timestamptz,
  redeemer_hash     text CHECK (redeemer_hash IS NULL OR redeemer_hash ~ '^[0-9a-f]{64}$'),
  -- SHA-256(run:network) of the minting network (IPv6 /48, an IPv4 address),
  -- for the per-network cap of a run. Never the address itself.
  net_hash          text NOT NULL CHECK (net_hash ~ '^[0-9a-f]{64}$'),
  -- The same for the IPv6 /32 (an IPv4 address as itself), for the /32 quota.
  net32_hash        text NOT NULL CHECK (net32_hash ~ '^[0-9a-f]{64}$'),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_wroom_entries_admit_chk CHECK ((state IN ('waiting', 'abandoned')) = (admitted_at IS NULL))
);
CREATE INDEX IF NOT EXISTS exos_wroom_entries_line_idx
  ON public.exos_wroom_entries (event_id, run_id, state, order_key, id);
CREATE INDEX IF NOT EXISTS exos_wroom_entries_undrawn_idx
  ON public.exos_wroom_entries (event_id, run_id) WHERE order_key IS NULL;
CREATE INDEX IF NOT EXISTS exos_wroom_entries_org_idx ON public.exos_wroom_entries (org_id);
CREATE INDEX IF NOT EXISTS exos_wroom_entries_net_idx ON public.exos_wroom_entries (event_id, run_id, net_hash);
CREATE INDEX IF NOT EXISTS exos_wroom_entries_net32_idx ON public.exos_wroom_entries (event_id, run_id, net32_hash);
ALTER TABLE public.exos_wroom_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_wroom_entries FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_wroom_entries TO service_role;

-- Places handed out since the last recount, per counter round, in 16 shards
-- (a mint adds 1 to a random shard): the room cap reads the live count of the
-- last recount plus 16 rows, never a count of the whole line per arrival, and
-- parallel mints rarely wait on the same row.
CREATE TABLE IF NOT EXISTS public.exos_wroom_counts (
  event_id  uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  run_id    uuid NOT NULL,
  round     int NOT NULL CHECK (round >= 0),
  shard     smallint NOT NULL CHECK (shard BETWEEN 0 AND 15),
  org_id    uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  n         int NOT NULL DEFAULT 0 CHECK (n >= 0),
  PRIMARY KEY (event_id, run_id, round, shard)
);
CREATE INDEX IF NOT EXISTS exos_wroom_counts_org_idx ON public.exos_wroom_counts (org_id);
ALTER TABLE public.exos_wroom_counts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_wroom_counts FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_wroom_counts TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Helpers (no client grants)
-- ---------------------------------------------------------------------------
-- The stored form of a token: bound to its event, so a token for one event
-- never matches a row of another.
CREATE OR REPLACE FUNCTION public._exos_wroom_hash(p_event_id uuid, p_token text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT encode(sha256(convert_to(p_event_id::text || ':' || p_token, 'UTF8')), 'hex')
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_hash(uuid, text) FROM PUBLIC, anon, authenticated;

-- A uniform random number in [0, 1) from the CSPRNG (the draw).
CREATE OR REPLACE FUNCTION public._exos_wroom_rand()
RETURNS double precision
LANGUAGE sql VOLATILE
SET search_path = public, pg_temp
AS $$
  SELECT ('x' || encode(extensions.gen_random_bytes(6), 'hex'))::bit(48)::bigint / 281474976710656.0
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_rand() FROM PUBLIC, anon, authenticated;

-- The token a PostgREST request carries (x-exos-queue header), or NULL.
CREATE OR REPLACE FUNCTION public._exos_wroom_header_token()
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE h jsonb;
BEGIN
  BEGIN
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN others THEN RETURN NULL;
  END;
  IF h IS NULL OR jsonb_typeof(h) <> 'object' THEN RETURN NULL; END IF;
  RETURN nullif(btrim(coalesce(h ->> 'x-exos-queue', '')), '');
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_header_token() FROM PUBLIC, anon, authenticated;

-- The wider network for the queue's limits: an IPv6 address's /48 (one
-- customer's whole allocation: rotating /64s inside it doesn't help), an IPv4
-- address as is, 'unknown' without a trusted IP.
CREATE OR REPLACE FUNCTION public._exos_wroom_wide_bucket()
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v text := public._exos_request_ip(); i inet;
BEGIN
  IF v IS NULL THEN RETURN 'unknown'; END IF;
  i := v::inet;
  IF family(i) = 6 THEN RETURN network(set_masklen(i, 48))::text; END IF;
  RETURN host(i);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_wide_bucket() FROM PUBLIC, anon, authenticated;

-- The IPv6 /32 of the caller (one provider's allocation), else the wide bucket.
CREATE OR REPLACE FUNCTION public._exos_wroom_net32()
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v text := public._exos_request_ip(); i inet;
BEGIN
  IF v IS NULL THEN RETURN 'unknown'; END IF;
  i := v::inet;
  IF family(i) = 6 THEN RETURN network(set_masklen(i, 32))::text; END IF;
  RETURN host(i);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_net32() FROM PUBLIC, anon, authenticated;

-- The most people one run's line may hold: the organizer's number, or 5 x
-- the public sellable capacity (at least 1,000).
CREATE OR REPLACE FUNCTION public._exos_wroom_cap(s public.exos_wroom_settings)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(s.max_entries, greatest(1000, least(1000000, 5 * coalesce((
    SELECT sum(t.capacity) FROM public.exos_ticket_tiers t
     WHERE t.event_id = s.event_id AND t.visibility = 'public' AND t.capacity > 0), 0)))::int)
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_cap(public.exos_wroom_settings) FROM PUBLIC, anon, authenticated;

-- Where a room stands: 'off' (none, turned off or closed), 'before' (the
-- window hasn't opened), 'lobby' (open, before the on-sale), 'live'.
CREATE OR REPLACE FUNCTION public._exos_wroom_phase(s public.exos_wroom_settings,
  OUT phase text, OUT on_sale_at timestamptz, OUT opens_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF s.event_id IS NULL OR NOT s.enabled OR s.closed_at IS NOT NULL THEN
    phase := 'off';
    RETURN;
  END IF;
  -- greatest() skips NULL (nothing to sell) and -infinity (already on sale).
  on_sale_at := coalesce(s.on_sale_at, greatest(public._exos_drop_open_at(s.event_id), s.enabled_at));
  opens_at := on_sale_at - make_interval(mins => s.window_minutes);
  phase := CASE WHEN now() < opens_at THEN 'before' WHEN now() < on_sale_at THEN 'lobby' ELSE 'live' END;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_phase(public.exos_wroom_settings) FROM PUBLIC, anon, authenticated;

-- The live line, recounted at most every 5 s per event (try-lock: one at a
-- time, the others skip): waiting and seen in the last 3 minutes, or admitted
-- and not yet expired or used. Abandoned, expired and used places free up.
-- Mints since then go to the next counter round. Runs in any open phase.
CREATE OR REPLACE FUNCTION public._exos_wroom_recount(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_wroom_settings%ROWTYPE; v_n int;
BEGIN
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF NOT FOUND OR s.counted_at > now() - interval '5 seconds' THEN RETURN; END IF;
  IF NOT pg_try_advisory_xact_lock(hashtextextended('exos_wroom_count:' || p_event_id::text, 0)) THEN RETURN; END IF;
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF s.counted_at > now() - interval '5 seconds' THEN RETURN; END IF;
  -- Places idle for 3 minutes are abandoned for good.
  UPDATE public.exos_wroom_entries x SET state = 'abandoned'
   WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.state = 'waiting'
     AND x.last_seen_at <= now() - interval '3 minutes';
  SELECT count(*) INTO v_n FROM public.exos_wroom_entries x
   WHERE x.event_id = p_event_id AND x.run_id = s.run_id
     AND ((x.state = 'waiting' AND x.last_seen_at > now() - interval '3 minutes')
       OR (x.state = 'admitted' AND x.admit_expires_at > now() AND x.used_at IS NULL));
  UPDATE public.exos_wroom_settings
     SET live_count = v_n, counted_at = now(), count_round = count_round + 1
   WHERE event_id = p_event_id;
  DELETE FROM public.exos_wroom_counts c
   WHERE c.event_id = p_event_id AND (c.run_id <> s.run_id OR c.round < s.count_round);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_recount(uuid) FROM PUBLIC, anon, authenticated;

-- One admission round: the draw (once), expiries, the next batch, and the
-- idle close. Runs on read; at most every 5 seconds per event and never two
-- at a time (try-lock: a busy room skips, the next read catches up).
CREATE OR REPLACE FUNCTION public._exos_wroom_advance(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s        public.exos_wroom_settings%ROWTYPE;
  ph       record;
  v_clock  timestamptz;
  v_budget int;
  v_n      int := 0;
  v_wait   boolean;
  v_since  timestamptz;
BEGIN
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF NOT FOUND THEN RETURN; END IF;
  ph := public._exos_wroom_phase(s);
  IF ph.phase <> 'live' THEN RETURN; END IF;
  IF s.drawn_at IS NOT NULL AND s.advanced_at > now() - interval '5 seconds' THEN RETURN; END IF;
  IF NOT pg_try_advisory_xact_lock(hashtextextended('exos_wroom:' || p_event_id::text, 0)) THEN RETURN; END IF;
  -- Fresh, under the lock: the round before us has committed.
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id FOR UPDATE;
  ph := public._exos_wroom_phase(s);
  IF ph.phase <> 'live' OR (s.drawn_at IS NOT NULL AND s.advanced_at > now() - interval '5 seconds') THEN RETURN; END IF;

  -- The draw: early arrivals get a random place; anyone left without a key
  -- (a lobby insert that committed after an earlier draw) is placed too.
  UPDATE public.exos_wroom_entries e
     SET order_key = CASE WHEN e.arrived_at < ph.on_sale_at THEN public._exos_wroom_rand()
                          ELSE extract(epoch FROM e.arrived_at) END
   WHERE e.event_id = p_event_id AND e.run_id = s.run_id AND e.order_key IS NULL;

  UPDATE public.exos_wroom_entries e
     SET state = 'expired'
   WHERE e.event_id = p_event_id AND e.run_id = s.run_id AND e.state = 'admitted' AND e.admit_expires_at <= now();

  -- Credit since the last round, at most one minute's worth (no burst after a
  -- quiet spell); the first round at the on-sale lets in six seconds' worth.
  v_clock := greatest(coalesce(s.admit_clock, now() - interval '6 seconds'), now() - interval '60 seconds');
  v_budget := floor(s.admit_per_minute * extract(epoch FROM now() - v_clock) / 60.0)::int;
  IF v_budget >= 1 THEN
    WITH nxt AS (
      SELECT e.id FROM public.exos_wroom_entries e
       WHERE e.event_id = p_event_id AND e.run_id = s.run_id AND e.state = 'waiting'
         AND e.order_key IS NOT NULL AND e.last_seen_at > now() - interval '3 minutes'
       ORDER BY e.order_key, e.id
       LIMIT v_budget
       FOR UPDATE SKIP LOCKED)
    UPDATE public.exos_wroom_entries e
       SET state = 'admitted', admitted_at = now(),
           admit_expires_at = now() + make_interval(mins => s.admission_minutes)
      FROM nxt WHERE e.id = nxt.id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    -- Unused credit is dropped (nobody to let in); used credit moves the clock.
    v_clock := CASE WHEN v_n < v_budget THEN now()
                    ELSE v_clock + make_interval(secs => v_budget * 60.0 / s.admit_per_minute) END;
  END IF;

  v_wait := EXISTS (SELECT 1 FROM public.exos_wroom_entries e
                     WHERE e.event_id = p_event_id AND e.run_id = s.run_id AND e.state = 'waiting'
                       AND e.last_seen_at > now() - interval '3 minutes');
  v_since := coalesce(s.last_waiting_at, ph.on_sale_at);
  UPDATE public.exos_wroom_settings
     SET on_sale_at = ph.on_sale_at,
         drawn_at = coalesce(drawn_at, now()),
         admit_clock = v_clock,
         advanced_at = now(),
         last_waiting_at = CASE WHEN v_wait THEN now() ELSE last_waiting_at END,
         closed_at = CASE WHEN NOT v_wait AND now() - v_since >= make_interval(mins => s.idle_close_minutes)
                          THEN now() END,
         closed_reason = CASE WHEN NOT v_wait AND now() - v_since >= make_interval(mins => s.idle_close_minutes)
                              THEN 'idle' END
   WHERE event_id = p_event_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_advance(uuid) FROM PUBLIC, anon, authenticated;

-- A poll or a return with the token: true and last seen now (at most every
-- p_every seconds) for a live place; false for an abandoned one, marking a
-- waiting place idle for 3 minutes abandoned first (under its row lock, so
-- two polls can't race a place back). Admitted / expired places stay as they
-- are (their own clock decides).
CREATE OR REPLACE FUNCTION public._exos_wroom_touch(p_entry_id uuid, p_every int)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_wroom_entries%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND OR e.state = 'abandoned' THEN RETURN false; END IF;
  IF e.state = 'waiting' AND e.last_seen_at <= now() - interval '3 minutes' THEN
    UPDATE public.exos_wroom_entries SET state = 'abandoned' WHERE id = p_entry_id;
    RETURN false;
  END IF;
  IF e.last_seen_at < now() - make_interval(secs => p_every) OR p_every = 0 THEN
    UPDATE public.exos_wroom_entries SET last_seen_at = now() WHERE id = p_entry_id;
  END IF;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_touch(uuid, int) FROM PUBLIC, anon, authenticated;

-- What a token holder sees: its own state and place, never anyone else's.
CREATE OR REPLACE FUNCTION public._exos_wroom_view(p_event_id uuid, p_entry_id uuid, p_token text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s      public.exos_wroom_settings%ROWTYPE;
  ph     record;
  e      public.exos_wroom_entries%ROWTYPE;
  v_ah   bigint;
  v_eta  int;
  v_base jsonb;
BEGIN
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  ph := public._exos_wroom_phase(s);
  IF ph.phase IN ('off', 'before') THEN
    RETURN jsonb_build_object('state', ph.phase) || CASE WHEN ph.phase = 'before'
      THEN jsonb_build_object('opens_at', ph.opens_at, 'on_sale_at', ph.on_sale_at,
                              'poll_after_ms', least(300000, greatest(5000,
                                (extract(epoch FROM ph.opens_at - now()) * 1000)::bigint)))
      ELSE '{}'::jsonb END;
  END IF;
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = p_entry_id AND event_id = p_event_id AND run_id = s.run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'unknown', 'phase', ph.phase);
  END IF;
  v_base := jsonb_build_object('phase', ph.phase, 'on_sale_at', ph.on_sale_at, 'admit_per_minute', s.admit_per_minute)
            || CASE WHEN p_token IS NOT NULL THEN jsonb_build_object('token', p_token) ELSE '{}'::jsonb END;
  IF e.state = 'abandoned' OR (e.state = 'waiting' AND e.last_seen_at <= now() - interval '3 minutes') THEN
    RETURN v_base - 'token' || jsonb_build_object('state', 'expired', 'reason', 'idle');
  END IF;
  -- The lobby wakes up after the on-sale spread over 15 seconds: the draw
  -- makes being first to ask worth nothing, so nobody needs to stampede.
  IF ph.phase = 'lobby' OR (e.state = 'waiting' AND e.order_key IS NULL) THEN
    RETURN v_base || jsonb_build_object('state', 'lobby',
      'poll_after_ms', least(30000, greatest(2000, (extract(epoch FROM ph.on_sale_at - now()) * 1000)::bigint
                                                    + 1000 + (random() * 15000)::bigint)));
  END IF;
  IF e.state = 'admitted' AND e.admit_expires_at > now() THEN
    RETURN v_base || jsonb_build_object('state', 'admitted', 'admitted_until', e.admit_expires_at, 'poll_after_ms', 60000);
  END IF;
  IF e.state <> 'waiting' THEN
    RETURN v_base || jsonb_build_object('state', 'expired', 'reason', 'lapsed');
  END IF;
  SELECT count(*) INTO v_ah FROM public.exos_wroom_entries x
   WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.state = 'waiting'
     AND (x.order_key, x.id) < (e.order_key, e.id) AND x.last_seen_at > now() - interval '3 minutes';
  v_eta := ceil((v_ah + 1)::numeric / s.admit_per_minute)::int;
  RETURN v_base || jsonb_build_object('state', 'waiting', 'position', v_ah + 1, 'ahead', v_ah,
    'eta_minutes', v_eta,
    -- Farther back, slower: a crowd of 10,000 polls a few hundred times a second.
    'poll_after_ms', CASE WHEN v_eta > 5 THEN 30000 WHEN v_eta > 1 THEN 15000 ELSE 5000 END);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_view(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- The gate: may this buyer start a checkout, a hold or a free claim for this
-- event (and ticket type)? p_buyer is 'uid:<id>' or 'email:<address>'.
-- Returns when there is no open room, for the drop list presale type in its
-- early window, or for an admitted, unexpired token of this event's current
-- run that is unused or already this buyer's (the first use binds the turn to
-- its buyer). The event is also taken from the ticket type, so a request
-- can't name a roomless event for another event's type. Raises XWR01 (wait
-- your turn) or XWR02 (the turn is checking out in another window: one at a
-- time; the hold functions keep one live cart per buyer and event, so a turn
-- never holds two carts).
CREATE OR REPLACE FUNCTION public._exos_wroom_gate_token(p_event_id uuid, p_tier_id uuid, p_token text, p_buyer text)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_wroom_settings%ROWTYPE;
  ph      record;
  e       public.exos_wroom_entries%ROWTYPE;
  v_tev   uuid;
  v_h     text;
  v_r     text;
BEGIN
  SELECT t.event_id INTO v_tev FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id;
  IF v_tev IS NOT NULL AND v_tev IS DISTINCT FROM p_event_id THEN
    PERFORM public._exos_wroom_gate_token(v_tev, p_tier_id, p_token, p_buyer);
  END IF;
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF NOT FOUND OR NOT s.enabled OR s.closed_at IS NOT NULL THEN RETURN; END IF;
  ph := public._exos_wroom_phase(s);
  IF ph.phase IN ('off', 'before') THEN RETURN; END IF;
  IF p_tier_id IS NOT NULL AND v_tev = p_event_id AND EXISTS (SELECT 1 FROM public.exos_drop_settings ds
                                        WHERE ds.event_id = p_event_id AND ds.presale_tier_id = p_tier_id
                                          AND now() < ds.public_on_sale_at) THEN
    RETURN;  -- the drop list presale window: members only (their code), until the public on-sale
  END IF;
  PERFORM public._exos_wroom_advance(p_event_id);  -- may close an idle room
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF s.closed_at IS NOT NULL THEN RETURN; END IF;
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' OR coalesce(p_buyer, '') !~ '^(uid|email):.+$' THEN
    RAISE EXCEPTION 'exos waiting room: wait for your turn in the queue' USING ERRCODE = 'XWR01';
  END IF;
  v_h := public._exos_wroom_hash(p_event_id, p_token);
  v_r := encode(sha256(convert_to(p_event_id::text || ':' || lower(p_buyer), 'UTF8')), 'hex');
  -- One checkout per turn at a time (held until this transaction ends).
  IF NOT pg_try_advisory_xact_lock(hashtextextended('exos_wroom_turn:' || v_h, 0)) THEN
    RAISE EXCEPTION 'exos waiting room: your turn is already checking out in another window' USING ERRCODE = 'XWR02';
  END IF;
  SELECT * INTO e FROM public.exos_wroom_entries x
   WHERE x.token_hash = v_h AND x.event_id = p_event_id AND x.run_id = s.run_id
   FOR UPDATE;
  IF NOT FOUND OR e.state <> 'admitted' OR e.admit_expires_at <= now()
     OR (e.redeemer_hash IS NOT NULL AND e.redeemer_hash <> v_r) THEN
    RAISE EXCEPTION 'exos waiting room: wait for your turn in the queue' USING ERRCODE = 'XWR01';
  END IF;
  UPDATE public.exos_wroom_entries x
     SET used_at = coalesce(x.used_at, now()), redeemer_hash = coalesce(x.redeemer_hash, v_r), last_seen_at = now()
   WHERE x.id = e.id;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_gate_token(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;

-- The same, with the token from the request's x-exos-queue header (what the
-- three hold / claim functions call first, with their buyer).
CREATE OR REPLACE FUNCTION public._exos_wroom_gate(p_event_id uuid, p_tier_id uuid, p_buyer text)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Fast path for the common case: no room for this event (or the type's).
  IF NOT EXISTS (SELECT 1 FROM public.exos_wroom_settings s
                  WHERE s.enabled AND (s.event_id = p_event_id
                    OR s.event_id = (SELECT t.event_id FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id))) THEN
    RETURN;
  END IF;
  PERFORM public._exos_wroom_gate_token(p_event_id, p_tier_id, public._exos_wroom_header_token(), p_buyer);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_gate(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The queue (anon + authenticated; no login needed)
-- ---------------------------------------------------------------------------
-- Arrive: with the browser's token, its state; without one (or with a dead
-- one) a new token while the room is open. Minting, checked before any
-- write: 60 a minute per network (an IPv4 address or an IPv6 /64; generous,
-- phones on one carrier share addresses) and 120 a minute per IPv6 /48, over
-- that "busy" with a retry hint and nothing stored; then, on the LIVE line
-- (abandoned, expired and used places free up) and scaled with the room's cap:
-- an IPv6 /48 greatest(20, cap / 50), an IPv4 address greatest(200, cap / 10)
-- (shared NAT), an IPv6 /32 greatest(100, cap / 4), and the cap itself; over
-- those "full" (the page retries each minute).
-- Distributed stuffing needs a CAPTCHA in front of minting (follow-up).
-- No room: { state: 'off' } (buy as usual).
CREATE OR REPLACE FUNCTION public.exos_wroom_join(p_event_id uuid, p_token text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_wroom_settings%ROWTYPE;
  ph      record;
  v_id    uuid;
  v_token text;
  v_narrow text := public._exos_request_ip_bucket();
  v_wide  text := public._exos_wroom_wide_bucket();
  v_net   text;
  v_n32   text := public._exos_wroom_net32();
  v_net32 text;
  v_cap   int;
BEGIN
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  ph := public._exos_wroom_phase(s);
  IF ph.phase IN ('off', 'before') THEN
    RETURN public._exos_wroom_view(p_event_id, NULL);
  END IF;
  PERFORM public._exos_wroom_advance(p_event_id);
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF s.closed_at IS NOT NULL THEN
    RETURN jsonb_build_object('state', 'off');
  END IF;
  -- The browser's own token: one place per browser.
  -- An abandoned place stays abandoned: "expired, idle" (the page offers a new join).
  IF coalesce(p_token, '') ~ '^[0-9a-f]{64}$' THEN
    SELECT e.id INTO v_id FROM public.exos_wroom_entries e
     WHERE e.token_hash = public._exos_wroom_hash(p_event_id, p_token)
       AND e.event_id = p_event_id AND e.run_id = s.run_id;
    IF v_id IS NOT NULL THEN
      IF NOT public._exos_wroom_touch(v_id, 0) THEN
        RETURN jsonb_build_object('state', 'expired', 'reason', 'idle', 'phase', ph.phase);
      END IF;
      RETURN public._exos_wroom_view(p_event_id, v_id, p_token);
    END IF;
  END IF;
  IF NOT public.exos_rate_hit('wroom-ip:' || md5(v_narrow), 60)
     OR (v_wide <> v_narrow AND NOT public.exos_rate_hit('wroom-net:' || md5(v_wide), 120)) THEN
    RETURN jsonb_build_object('state', 'busy', 'retry_after_ms', 5000);
  END IF;
  -- Per-network shares of the room, on the live line, scaled with the cap
  -- (carriers put many phones behind one IPv4 address or in one /48 or /32):
  -- an IPv6 /48 greatest(20, cap / 50), an IPv4 address greatest(200, cap / 10),
  -- an IPv6 /32 greatest(100, cap / 4).
  v_cap := public._exos_wroom_cap(s);
  v_net := encode(sha256(convert_to(s.run_id::text || ':' || v_wide, 'UTF8')), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_wroom_net:' || v_net, 0));
  IF (SELECT count(*) FROM public.exos_wroom_entries x
       WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.net_hash = v_net
         AND ((x.state = 'waiting' AND x.last_seen_at > now() - interval '3 minutes')
             OR (x.state = 'admitted' AND x.admit_expires_at > now() AND x.used_at IS NULL)))
     >= (CASE WHEN position(':' in v_wide) > 0 THEN greatest(20, v_cap / 50) ELSE greatest(200, v_cap / 10) END) THEN
    RETURN jsonb_build_object('state', 'full', 'reason', 'network', 'poll_after_ms', 60000);
  END IF;
  v_net32 := encode(sha256(convert_to(s.run_id::text || ':' || v_n32, 'UTF8')), 'hex');
  IF position(':' in v_n32) > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_wroom_net:' || v_net32, 0));
    IF (SELECT count(*) FROM public.exos_wroom_entries x
         WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.net32_hash = v_net32
           AND ((x.state = 'waiting' AND x.last_seen_at > now() - interval '3 minutes')
             OR (x.state = 'admitted' AND x.admit_expires_at > now() AND x.used_at IS NULL))) >= greatest(100, v_cap / 4) THEN
      RETURN jsonb_build_object('state', 'full', 'reason', 'network', 'poll_after_ms', 60000);
    END IF;
  END IF;
  -- The room's cap on the live line: the last recount plus the mints since
  -- (soft: arrivals in flight at a recount may pass it by a few).
  PERFORM public._exos_wroom_recount(p_event_id);
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF s.live_count + (SELECT coalesce(sum(c.n), 0) FROM public.exos_wroom_counts c
                      WHERE c.event_id = p_event_id AND c.run_id = s.run_id AND c.round = s.count_round)
     >= v_cap THEN
    RETURN jsonb_build_object('state', 'full', 'reason', 'room', 'poll_after_ms', 60000);
  END IF;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, net_hash, net32_hash, order_key)
  VALUES (s.org_id, p_event_id, s.run_id, public._exos_wroom_hash(p_event_id, v_token), v_net, v_net32,
          -- After the draw a newcomer goes to the back (arrival order).
          CASE WHEN s.drawn_at IS NOT NULL THEN extract(epoch FROM now()) END)
  RETURNING id INTO v_id;
  INSERT INTO public.exos_wroom_counts AS c (event_id, run_id, round, shard, org_id, n)
  VALUES (p_event_id, s.run_id, s.count_round, floor(random() * 16)::smallint, s.org_id, 1)
  ON CONFLICT (event_id, run_id, round, shard) DO UPDATE SET n = c.n + 1;
  RETURN public._exos_wroom_view(p_event_id, v_id, v_token);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_join(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_wroom_join(uuid, text) TO anon, authenticated, service_role;

-- Poll: the caller's own state and place (and the admission round on read).
-- An unknown or malformed token answers { state: 'unknown' } (join again);
-- the token is never echoed back.
CREATE OR REPLACE FUNCTION public.exos_wroom_status(p_event_id uuid, p_token text)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s    public.exos_wroom_settings%ROWTYPE;
  ph   record;
  v_id uuid;
BEGIN
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  ph := public._exos_wroom_phase(s);
  IF ph.phase IN ('off', 'before') THEN
    RETURN public._exos_wroom_view(p_event_id, NULL);
  END IF;
  PERFORM public._exos_wroom_advance(p_event_id);
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF s.closed_at IS NOT NULL THEN
    RETURN jsonb_build_object('state', 'off');
  END IF;
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('state', 'unknown', 'phase', ph.phase);
  END IF;
  SELECT e.id INTO v_id FROM public.exos_wroom_entries e
   WHERE e.token_hash = public._exos_wroom_hash(p_event_id, p_token)
     AND e.event_id = p_event_id AND e.run_id = s.run_id;
  IF v_id IS NULL THEN
    RETURN jsonb_build_object('state', 'unknown', 'phase', ph.phase);
  END IF;
  -- last_seen_at at most every 20 s per entry; an abandoned place stays so.
  IF NOT public._exos_wroom_touch(v_id, 20) THEN
    RETURN jsonb_build_object('state', 'expired', 'reason', 'idle', 'phase', ph.phase);
  END IF;
  PERFORM public._exos_wroom_recount(p_event_id);
  RETURN public._exos_wroom_view(p_event_id, v_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_wroom_status(uuid, text) TO anon, authenticated, service_role;

-- exos-checkout's check (service role), with the event and type it resolved,
-- the token from the body and the buyer (the account, else the guest email).
CREATE OR REPLACE FUNCTION public.exos_wroom_require(p_event_id uuid, p_tier_id uuid, p_token text,
  p_buyer_uid uuid, p_email text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_wroom_gate_token(p_event_id, p_tier_id, p_token,
    CASE WHEN p_buyer_uid IS NOT NULL THEN 'uid:' || p_buyer_uid::text
         ELSE 'email:' || lower(btrim(coalesce(p_email, ''))) END);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_require(uuid, uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wroom_require(uuid, uuid, text, uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Organizers
-- ---------------------------------------------------------------------------
-- The event's org (or NULL) when the caller holds one of p_roles there, or is
-- a platform admin.
CREATE OR REPLACE FUNCTION public._exos_wroom_staff(p_event_id uuid, p_roles text[])
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT e.org_id FROM public.exos_events e
   WHERE e.id = p_event_id AND auth.uid() IS NOT NULL
     AND (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, p_roles))
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_staff(uuid, text[]) FROM PUBLIC, anon, authenticated;

-- Settings and live counts: owner / manager / finance (or admin). Counts
-- only, never a token or an entry id. Another org's event and an unknown id
-- are the same 42501.
CREATE OR REPLACE FUNCTION public.exos_wroom_summary(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid := public._exos_wroom_staff(p_event_id, ARRAY['owner', 'manager', 'finance']);
  s     public.exos_wroom_settings%ROWTYPE;
  ph    record;
  c     record;
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_wroom_summary: not authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_wroom_advance(p_event_id);
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  ph := public._exos_wroom_phase(s);
  SELECT count(*) FILTER (WHERE e.state = 'waiting' AND e.last_seen_at > now() - interval '3 minutes') AS waiting,
         count(*) FILTER (WHERE e.state = 'admitted' AND e.admit_expires_at > now() AND e.used_at IS NULL) AS admitted,
         count(*) FILTER (WHERE e.used_at IS NOT NULL) AS checked_out,
         -- Expired: turns that lapsed unused, and places abandoned (idle 3 minutes).
         count(*) FILTER (WHERE e.used_at IS NULL AND (e.state IN ('expired', 'abandoned')
                            OR (e.state = 'admitted' AND e.admit_expires_at <= now())
                            OR (e.state = 'waiting' AND e.last_seen_at <= now() - interval '3 minutes'))) AS expired,
         count(*) AS total
    INTO c
    FROM public.exos_wroom_entries e
   WHERE e.event_id = p_event_id AND e.run_id = s.run_id;
  RETURN jsonb_build_object(
    'enabled', coalesce(s.enabled, false),
    'phase', ph.phase,
    'window_minutes', coalesce(s.window_minutes, 15),
    'admit_per_minute', coalesce(s.admit_per_minute, 200),
    'admission_minutes', coalesce(s.admission_minutes, 10),
    'idle_close_minutes', coalesce(s.idle_close_minutes, 10),
    'max_entries', s.max_entries,
    'cap', CASE WHEN s.event_id IS NOT NULL THEN public._exos_wroom_cap(s) END,
    'on_sale_at', CASE WHEN s.event_id IS NOT NULL AND ph.phase <> 'off' THEN ph.on_sale_at END,
    'opens_at', CASE WHEN s.event_id IS NOT NULL AND ph.phase <> 'off' THEN ph.opens_at END,
    'closed_at', s.closed_at, 'closed_reason', s.closed_reason,
    'counts', jsonb_build_object('waiting', coalesce(c.waiting, 0), 'admitted', coalesce(c.admitted, 0),
                                 'checked_out', coalesce(c.checked_out, 0), 'expired', coalesce(c.expired, 0),
                                 'total', coalesce(c.total, 0)),
    'wait_minutes', CASE WHEN coalesce(c.waiting, 0) > 0
                         THEN ceil(c.waiting::numeric / s.admit_per_minute)::int ELSE 0 END,
    'can_manage', public._exos_wroom_staff(p_event_id, ARRAY['owner', 'manager']) IS NOT NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_wroom_summary(uuid) TO authenticated, service_role;

-- Turn it on / off and set its numbers: owner / manager (or admin), audited.
-- Off -> on starts a new run (fresh line; the old run's entries are deleted);
-- on -> off closes it at once ('organizer'). NULL keeps a number as it is.
CREATE OR REPLACE FUNCTION public.exos_wroom_configure(
  p_event_id uuid, p_enabled boolean,
  p_window_minutes int DEFAULT NULL, p_admit_per_minute int DEFAULT NULL,
  p_admission_minutes int DEFAULT NULL, p_idle_close_minutes int DEFAULT NULL,
  -- The most people in line: NULL keeps it, 0 = automatic (5 x capacity).
  p_max_entries int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid := public._exos_wroom_staff(p_event_id, ARRAY['owner', 'manager']);
  o      public.exos_wroom_settings%ROWTYPE;
  n      public.exos_wroom_settings%ROWTYPE;
  v_on   boolean;
  v_live boolean;
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_wroom_configure: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'exos_wroom_configure: say on or off' USING ERRCODE = '22023';
  END IF;
  IF (p_window_minutes IS NOT NULL AND p_window_minutes NOT BETWEEN 0 AND 240)
     OR (p_admit_per_minute IS NOT NULL AND p_admit_per_minute NOT BETWEEN 1 AND 20000)
     OR (p_admission_minutes IS NOT NULL AND p_admission_minutes NOT BETWEEN 2 AND 60)
     OR (p_idle_close_minutes IS NOT NULL AND p_idle_close_minutes NOT BETWEEN 1 AND 240)
     OR (p_max_entries IS NOT NULL AND p_max_entries <> 0 AND p_max_entries NOT BETWEEN 100 AND 1000000) THEN
    RAISE EXCEPTION 'exos_wroom_configure: window 0-240 min, 1-20000 a minute, admission 2-60 min, idle close 1-240 min, line 100-1000000 people'
      USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_wroom:' || p_event_id::text, 0));
  SELECT * INTO o FROM public.exos_wroom_settings WHERE event_id = p_event_id FOR UPDATE;
  v_live := FOUND AND o.enabled AND o.closed_at IS NULL;
  v_on := p_enabled AND NOT v_live;   -- off (or closed) -> on: a new run
  IF v_on THEN
    DELETE FROM public.exos_wroom_entries WHERE event_id = p_event_id;
    DELETE FROM public.exos_wroom_counts WHERE event_id = p_event_id;
  END IF;
  INSERT INTO public.exos_wroom_settings AS w (event_id, org_id, enabled, window_minutes, admit_per_minute,
                                               admission_minutes, idle_close_minutes, max_entries, enabled_at, updated_by,
                                               closed_at, closed_reason)
  VALUES (p_event_id, v_org, p_enabled, coalesce(p_window_minutes, 15), coalesce(p_admit_per_minute, 200),
          coalesce(p_admission_minutes, 10), coalesce(p_idle_close_minutes, 10), nullif(p_max_entries, 0),
          CASE WHEN p_enabled THEN now() END, auth.uid(),
          CASE WHEN NOT p_enabled THEN now() END, CASE WHEN NOT p_enabled THEN 'organizer' END)
  ON CONFLICT (event_id) DO UPDATE
     SET enabled = EXCLUDED.enabled,
         window_minutes = coalesce(p_window_minutes, w.window_minutes),
         admit_per_minute = coalesce(p_admit_per_minute, w.admit_per_minute),
         admission_minutes = coalesce(p_admission_minutes, w.admission_minutes),
         idle_close_minutes = coalesce(p_idle_close_minutes, w.idle_close_minutes),
         max_entries = CASE WHEN p_max_entries IS NULL THEN w.max_entries ELSE nullif(p_max_entries, 0) END,
         updated_by = EXCLUDED.updated_by,
         run_id = CASE WHEN v_on THEN gen_random_uuid() ELSE w.run_id END,
         enabled_at = CASE WHEN v_on THEN now() ELSE w.enabled_at END,
         on_sale_at = CASE WHEN v_on THEN NULL ELSE w.on_sale_at END,
         drawn_at = CASE WHEN v_on THEN NULL ELSE w.drawn_at END,
         admit_clock = CASE WHEN v_on THEN NULL ELSE w.admit_clock END,
         advanced_at = CASE WHEN v_on THEN NULL ELSE w.advanced_at END,
         last_waiting_at = CASE WHEN v_on THEN NULL ELSE w.last_waiting_at END,
         live_count = CASE WHEN v_on THEN 0 ELSE w.live_count END,
         counted_at = CASE WHEN v_on THEN NULL ELSE w.counted_at END,
         closed_at = CASE WHEN NOT p_enabled THEN coalesce(w.closed_at, now()) WHEN v_on THEN NULL ELSE w.closed_at END,
         closed_reason = CASE WHEN NOT p_enabled THEN coalesce(w.closed_reason, 'organizer')
                              WHEN v_on THEN NULL ELSE w.closed_reason END
  RETURNING * INTO n;
  /* exos: audit event.waiting_room */
  PERFORM public._exos_audit(v_org, 'event.waiting_room', 'event', p_event_id::text, p_event_id,
    jsonb_build_object('enabled', jsonb_build_array(coalesce(o.enabled, false), n.enabled),
                       'window_minutes', jsonb_build_array(o.window_minutes, n.window_minutes),
                       'admit_per_minute', jsonb_build_array(o.admit_per_minute, n.admit_per_minute),
                       'admission_minutes', jsonb_build_array(o.admission_minutes, n.admission_minutes),
                       'idle_close_minutes', jsonb_build_array(o.idle_close_minutes, n.idle_close_minutes),
                       'max_entries', jsonb_build_array(o.max_entries, n.max_entries)));
  RETURN public.exos_wroom_summary(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_configure(uuid, boolean, int, int, int, int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_wroom_configure(uuid, boolean, int, int, int, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The gate in the hold / claim functions (marker patches)
-- ---------------------------------------------------------------------------
-- One PERFORM as the first statement of each body. Anchored on the body's
-- first line that is exactly BEGIN (the top-level block: these DECLARE
-- sections hold no BEGIN), and checked to come before the first RAISE, so it
-- matches prod's body whatever its exact text (supabase/README.md rule 4).
DO $$
DECLARE
  r     record;
  v_def text;
  v_at  int;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.exos_create_hold(uuid,uuid,integer,integer,text)', $q$'uid:' || coalesce(auth.uid()::text, '')$q$),
      ('public.exos_create_guest_hold(uuid,uuid,integer,text,text,text)', $q$'email:' || lower(btrim(coalesce(p_email, '')))$q$),
      ('public.exos_claim_free_tickets(uuid,uuid,integer,text,text,text)', $q$'uid:' || coalesce(auth.uid()::text, '')$q$)) v(f, buyer) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION '%: not present', r.f;
    END IF;
    v_def := replace(pg_get_functiondef(r.f::regprocedure), chr(13), '');
    IF position('/* exos: waiting room gate */' in v_def) > 0 THEN
      CONTINUE;
    END IF;
    v_at := position(E'\nBEGIN\n' in v_def);
    IF v_at = 0 OR v_at > position('RAISE EXCEPTION' in v_def) OR v_at < position('$function$' in v_def) THEN
      RAISE EXCEPTION '%: no top-level BEGIN before the first RAISE', r.f;
    END IF;
    EXECUTE overlay(v_def placing E'\nBEGIN\n  PERFORM public._exos_wroom_gate(p_event_id, p_tier_id, ' || r.buyer
                                  || E');  /* exos: waiting room gate */\n' from v_at for 7);
  END LOOP;
END $$;
