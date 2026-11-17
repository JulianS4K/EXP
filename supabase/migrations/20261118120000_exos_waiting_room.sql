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
--     (admits per minute), how long an admission lasts (N minutes), how long
--     the room stays open once nobody waits, the most anonymous places, an
--     optional on-sale pin (opens_at) and Cloudflare Turnstile. Owner /
--     manager only, audited (event.waiting_room). Only published events.
--   * The on-sale moment: the organizer's pin (opens_at) when set; else the
--     earliest sales_start of the public types still sellable (tickets left,
--     not ended), or the moment the room was turned on if that is later
--     (turned on mid-sale: first come, first served). Frozen once live.
--   * Places: a visitor in the window gets a queue token (32 random bytes,
--     64 hex; only SHA-256(event_id:token) is stored, so it is unguessable and
--     means nothing for another event). Its place in line (order_key) is fixed
--     when it is minted: a random number in [0, 1) before the on-sale (so
--     everyone early gets a random place, revealed only at the on-sale), and
--     1 + the clock after it (arrival order, behind every early one). No draw,
--     nothing O(line) in any request.
--   * One place per account per run, keyed on SHA-256(event:account), so a
--     second browser resumes it and only that account can use it. An
--     account with a confirmed email that is 7+ days old or has paid for an
--     order (any org) gets a seat: always, outside the cap, the network shares
--     and Turnstile. Any other signed-in account queues under the guest rules
--     below (its place still keyed on the account; it counts as a guest).
--   * Anonymous places sit under per-network shares and the room's cap (5 x
--     the public capacity, at least 1,000, or the organizer's number), both on
--     the LIVE line. Full: "full", and the page offers "Sign in to get a
--     place". Shares without a CAPTCHA: 20 per IPv6 /48, 200 per IPv4 address,
--     100 per IPv6 /32. With the room's Turnstile on (only through
--     exos-wroom-join), scaled with the cap under a hard ceiling:
--     least(greatest(20, cap / 50), 200), least(greatest(200, cap / 10), 1000),
--     least(greatest(100, cap / 4), 2000). Minting is also limited to 60 a
--     minute per IPv4 / IPv6 /64 and 120 per IPv6 /48.
--   * Batches: admission runs on read, at most every 5 s per event under a
--     try-lock, admitting rate * elapsed / 60 from the front (bounded by the
--     rate), skipping places not seen for 3 minutes.
--   * Idle places: not polled for 3 minutes they don't count and are skipped;
--     they may come back within 30 minutes (an account always; an anonymous
--     place only if its network share and the cap still have room, else it is
--     released for good); after 30 minutes they are abandoned for good
--     (marked in bounded batches). An admission lasts N minutes, then expires.
--   * One turn, one order: the first hold / claim binds the turn to its buyer;
--     a completed order (fulfilment) or claim spends it (XWR03 after). Paths
--     that skip the hold attach their checkout to the turn under the entry's
--     row lock before Stripe: one open checkout per turn (XWR02). The same
--     buyer starting again takes over: exos-checkout expires the earlier
--     Stripe session (unless it is complete or paying) and attaches anew.
--     A failed or expired session frees the turn; its session id stays mapped
--     (exos_wroom_sessions), so if it is fulfilled after all the turn is spent.
--     A phone RSVP spends the turn only when the code is right (confirmed).
--   * The gate: while the room is open, exos_create_hold,
--     exos_create_guest_hold, exos_claim_free_tickets, exos_phone_rsvp_verify
--     and exos_redeem_referral_reward refuse (XWR01) unless the request carries
--     an admitted, unexpired, unspent turn for THAT event (the x-exos-queue
--     header, or the signed-in account's place), first thing in the body
--     (marker /* exos: waiting room gate */); the event is also taken from the
--     ticket type. exos-checkout checks it too, after resolving the event and
--     type and before any hold or Stripe call (exos_wroom_require is
--     check-only; exos_wroom_attach binds the checkout).
--   * Bypass, on purpose: the drop list presale type during its early window
--     (members only, until the public on-sale it was set against); partner
--     reservations and staff sales (POS, door, kiosk, comps), which never use
--     these functions.
--   * Closing: the organizer turns it off, or, once someone has waited or been
--     admitted, nobody has waited for idle_close_minutes. Turning it on again
--     starts a new run; admitted, unexpired turns carry over.
--   * Turnstile (per room, off by default): new anonymous places only through
--     the exos-wroom-join edge function (siteverify, then
--     exos_wroom_join_verified, service role); the anon join answers
--     'challenge' and mints nothing.
--   * No PII: an entry is token / account / buyer / network hashes, times and
--     a state. A caller only ever sees its own place.
--   * No cron: everything runs on read, each statement bounded.
--
-- Touches:  C: TABLE exos_wroom_settings, exos_wroom_entries, exos_wroom_counts,
--              exos_wroom_sessions (RLS on, no client grants: RPCs only)
--           C: FUNCTION exos_wroom_join, exos_wroom_status (anon +
--              authenticated; H3 allowlist), exos_wroom_summary (owner /
--              manager / finance), exos_wroom_configure (owner / manager;
--              audited event.waiting_room), exos_wroom_join_verified,
--              exos_wroom_verify_gate, exos_wroom_require, exos_wroom_attach,
--              exos_wroom_bind, exos_wroom_release (service role), helpers
--              _exos_wroom_*
--           C: TRIGGER exos_checkout_sessions_wroom (spends the turn of a
--              fulfilled order, frees it on a failed / expired one)
--           C: TRIGGER exos_phone_rsvps_wroom (spends the turn of a phone
--              RSVP confirmed in the same call)
--           W: FUNCTION exos_create_hold, exos_create_guest_hold,
--              exos_claim_free_tickets, exos_phone_rsvp_verify,
--              exos_redeem_referral_reward (marker /* exos: waiting room gate */,
--              one PERFORM as the first statement of the body)
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- Lock order: holds and the RSVP gate lock the place, then the inventory;
--   fulfilment (inventory first) takes the place with SKIP LOCKED and the gate
--   also reads a paid session directly (_exos_wroom_paid), so the two never
--   deadlock and a turn whose order was paid reads as used either way.
-- ROLLBACK (manual): re-create the five patched functions without the gate
--   line (or leave it: with no settings row the gate returns at once), drop
--   the two triggers, the functions above and the four tables.
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
  -- Most anonymous places in one run's live line; NULL = 5 x the public
  -- capacity (at least 1,000). Account places are outside it.
  max_entries         int CHECK (max_entries IS NULL OR max_entries BETWEEN 100 AND 1000000),
  -- The organizer's on-sale pin: when set, the room's on-sale moment.
  opens_at            timestamptz,
  -- Cloudflare Turnstile in front of new anonymous places (exos-wroom-join);
  -- needs the platform's TURNSTILE_SECRET_KEY and VITE_TURNSTILE_SITE_KEY.
  turnstile           boolean NOT NULL DEFAULT false,
  -- One run per "turned on": entries of another run are dead.
  run_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  enabled_at          timestamptz,
  -- Frozen when the room goes live.
  on_sale_at          timestamptz,
  -- Admissions are credited from here (rate per minute); advanced_at throttles.
  admit_clock         timestamptz,
  advanced_at         timestamptz,
  first_admit_at      timestamptz,
  last_waiting_at     timestamptz,
  closed_at           timestamptz,
  closed_reason       text CHECK (closed_reason IS NULL OR closed_reason IN ('idle', 'organizer')),
  -- The live anonymous line at the last recount (at most every 5 s), and the
  -- counter round that mints since then add to (exos_wroom_counts).
  live_count          int NOT NULL DEFAULT 0 CHECK (live_count >= 0),
  count_round         int NOT NULL DEFAULT 0 CHECK (count_round >= 0),
  counted_at          timestamptz,
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

-- One row per place. No IP, user id or email in clear.
CREATE TABLE IF NOT EXISTS public.exos_wroom_entries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  run_id            uuid NOT NULL,
  token_hash        text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  -- 'account': a signed-in buyer's place (account_hash = SHA-256(event:uid),
  -- one per run); 'anon': everyone else.
  kind              text NOT NULL DEFAULT 'anon' CHECK (kind IN ('anon', 'account')),
  account_hash      text CHECK (account_hash IS NULL OR account_hash ~ '^[0-9a-f]{64}$'),
  arrived_at        timestamptz NOT NULL DEFAULT now(),
  -- Place in line, fixed at mint: random in [0, 1) before the on-sale,
  -- 1 + epoch after it.
  order_key         double precision NOT NULL,
  state             text NOT NULL DEFAULT 'waiting'
                      CHECK (state IN ('waiting', 'admitted', 'expired', 'abandoned', 'spent')),
  admitted_at       timestamptz,
  admit_expires_at  timestamptz,
  -- First hold / claim / checkout with the turn, and who: SHA-256 of event +
  -- uid:<id> or email:<address>. The turn is that buyer's from then on.
  used_at           timestamptz,
  redeemer_hash     text CHECK (redeemer_hash IS NULL OR redeemer_hash ~ '^[0-9a-f]{64}$'),
  spent_at          timestamptz,
  -- The free claim's order reference that spent the turn (a retry with the
  -- same reference is the same claim, not a second order).
  spent_ref         text,
  -- The open checkout attached to the turn (exos_wroom_attach / _bind).
  checkout_ref      uuid,
  checkout_at       timestamptz,
  session_id        text,
  -- SHA-256(run:network) of the minting network (IPv6 /48, an IPv4 address)
  -- and of its IPv6 /32; never the address itself.
  net_hash          text NOT NULL CHECK (net_hash ~ '^[0-9a-f]{64}$'),
  net32_hash        text NOT NULL CHECK (net32_hash ~ '^[0-9a-f]{64}$'),
  net_v6            boolean NOT NULL DEFAULT false,
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  -- The last view handed out (a poll within 5 s gets it back, no write).
  view_cache        jsonb,
  view_at           timestamptz,
  CONSTRAINT exos_wroom_entries_admit_chk CHECK ((state IN ('waiting', 'abandoned')) = (admitted_at IS NULL)),
  -- An account seat always has its account; a guest place may have one (a
  -- signed-in buyer who isn't eligible for a seat keeps one place per run).
  CONSTRAINT exos_wroom_entries_kind_chk CHECK (kind = 'anon' OR account_hash IS NOT NULL)
);
-- The line, front first (admission, positions).
CREATE INDEX IF NOT EXISTS exos_wroom_entries_line_idx
  ON public.exos_wroom_entries (event_id, run_id, state, order_key, id) INCLUDE (last_seen_at, kind);
-- Live / idle by last poll (recount, abandonment, idle close).
CREATE INDEX IF NOT EXISTS exos_wroom_entries_seen_idx
  ON public.exos_wroom_entries (event_id, run_id, state, last_seen_at) INCLUDE (kind);
CREATE INDEX IF NOT EXISTS exos_wroom_entries_expiry_idx
  ON public.exos_wroom_entries (event_id, run_id, admit_expires_at) WHERE state = 'admitted';
CREATE UNIQUE INDEX IF NOT EXISTS exos_wroom_entries_account_idx
  ON public.exos_wroom_entries (event_id, run_id, account_hash) WHERE account_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_wroom_entries_session_idx
  ON public.exos_wroom_entries (session_id) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_wroom_entries_org_idx ON public.exos_wroom_entries (org_id);
CREATE INDEX IF NOT EXISTS exos_wroom_entries_net_idx ON public.exos_wroom_entries (event_id, run_id, net_hash);
CREATE INDEX IF NOT EXISTS exos_wroom_entries_net32_idx ON public.exos_wroom_entries (event_id, run_id, net32_hash);
ALTER TABLE public.exos_wroom_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_wroom_entries FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_wroom_entries TO service_role;

-- Every checkout session ever bound to a place (a place may try several):
-- a fulfilled one spends its place, however late it arrives.
CREATE TABLE IF NOT EXISTS public.exos_wroom_sessions (
  session_id  text PRIMARY KEY CHECK (length(session_id) BETWEEN 1 AND 255),
  entry_id    uuid NOT NULL REFERENCES public.exos_wroom_entries (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_wroom_sessions_entry_idx ON public.exos_wroom_sessions (entry_id);
CREATE INDEX IF NOT EXISTS exos_wroom_sessions_org_idx ON public.exos_wroom_sessions (org_id);
CREATE INDEX IF NOT EXISTS exos_wroom_sessions_event_idx ON public.exos_wroom_sessions (event_id);
ALTER TABLE public.exos_wroom_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_wroom_sessions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_wroom_sessions TO service_role;

-- Anonymous places handed out since the last recount, per counter round, in
-- 16 shards (a mint adds 1 to a random shard): the cap reads the live count of
-- the last recount plus 16 rows, never a count of the line per arrival.
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
-- Earlier drafts' signatures (never applied; dev databases only).
DROP FUNCTION IF EXISTS public._exos_wroom_touch(uuid, int);
DROP FUNCTION IF EXISTS public._exos_wroom_gate(uuid, uuid);
DROP FUNCTION IF EXISTS public._exos_wroom_gate(uuid, uuid, text);
DROP FUNCTION IF EXISTS public._exos_wroom_gate_token(uuid, uuid, text);
DROP FUNCTION IF EXISTS public._exos_wroom_gate_token(uuid, uuid, text, text);
DROP FUNCTION IF EXISTS public.exos_wroom_require(uuid, uuid, text);
DROP FUNCTION IF EXISTS public._exos_wroom_gate(uuid, uuid, text, text);
DROP FUNCTION IF EXISTS public._exos_wroom_gate_token(uuid, uuid, text, text, text);
-- attach changed its return type (boolean -> jsonb); re-created below.
DROP FUNCTION IF EXISTS public.exos_wroom_attach(uuid, uuid, text, uuid, text, uuid);

CREATE OR REPLACE FUNCTION public._exos_wroom_hash(p_event_id uuid, p_token text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT encode(sha256(convert_to(p_event_id::text || ':' || p_token, 'UTF8')), 'hex')
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_hash(uuid, text) FROM PUBLIC, anon, authenticated;

-- A uniform random number in [0, 1) from the CSPRNG.
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

-- The wider network: an IPv6 address's /48, an IPv4 address as is.
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

-- The IPv6 /32 of the caller (one provider's allocation), else as above.
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

-- The most anonymous places one run's live line may hold.
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

-- A network's share of the live anonymous line ('48', 'v4', '32'): fixed, or
-- scaled with the cap under a hard ceiling behind Turnstile.
CREATE OR REPLACE FUNCTION public._exos_wroom_share(p_kind text, p_cap int, p_scaled boolean)
RETURNS int
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE p_kind
    WHEN '48' THEN CASE WHEN p_scaled THEN least(greatest(20, p_cap / 50), 200) ELSE 20 END
    WHEN 'v4' THEN CASE WHEN p_scaled THEN least(greatest(200, p_cap / 10), 1000) ELSE 200 END
    ELSE CASE WHEN p_scaled THEN least(greatest(100, p_cap / 4), 2000) ELSE 100 END END
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_share(text, int, boolean) FROM PUBLIC, anon, authenticated;

-- When the public can buy: the earliest sales_start of the public types still
-- sellable (capacity left, not ended); -infinity when one of them has no start
-- (on sale now); NULL with none. A sold-out or ended early type doesn't count.
CREATE OR REPLACE FUNCTION public._exos_wroom_open_at(p_event_id uuid)
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN count(*) = 0 THEN NULL
              WHEN bool_or(t.sales_start IS NULL) THEN '-infinity'::timestamptz
              ELSE min(t.sales_start) END
    FROM public.exos_ticket_tiers t
   WHERE t.event_id = p_event_id AND t.visibility = 'public' AND t.capacity > 0
     AND t.capacity > coalesce(t.sold, 0)
     AND (t.sales_end IS NULL OR t.sales_end > now())
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_open_at(uuid) FROM PUBLIC, anon, authenticated;

-- Where a room stands: 'off' (none, turned off, closed, or the event isn't
-- published), 'before' (the window hasn't opened), 'lobby' (open, before the
-- on-sale), 'live'.
CREATE OR REPLACE FUNCTION public._exos_wroom_phase(s public.exos_wroom_settings,
  OUT phase text, OUT on_sale_at timestamptz, OUT opens_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF s.event_id IS NULL OR NOT s.enabled OR s.closed_at IS NOT NULL
     OR NOT EXISTS (SELECT 1 FROM public.exos_events e
                     WHERE e.id = s.event_id AND e.status = 'published' AND e.cancelled_at IS NULL) THEN
    phase := 'off';
    RETURN;
  END IF;
  -- greatest() skips NULL (nothing to sell) and -infinity (on sale now).
  on_sale_at := coalesce(s.on_sale_at, s.opens_at, greatest(public._exos_wroom_open_at(s.event_id), s.enabled_at));
  opens_at := on_sale_at - make_interval(mins => s.window_minutes);
  phase := CASE WHEN now() < opens_at THEN 'before' WHEN now() < on_sale_at THEN 'lobby' ELSE 'live' END;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_phase(public.exos_wroom_settings) FROM PUBLIC, anon, authenticated;

-- A live anonymous place (counts toward the cap and network shares).
CREATE OR REPLACE FUNCTION public._exos_wroom_is_live(e public.exos_wroom_entries)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT (e.state = 'waiting' AND e.last_seen_at > now() - interval '3 minutes')
      OR (e.state = 'admitted' AND e.admit_expires_at > now() AND e.used_at IS NULL)
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_is_live(public.exos_wroom_entries) FROM PUBLIC, anon, authenticated;

-- Does a network share still have room? (under the network's advisory lock,
-- taken here; live anonymous places only)
CREATE OR REPLACE FUNCTION public._exos_wroom_net_room(p_event_id uuid, p_run uuid, p_col text, p_hash text, p_share int)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_wroom_net:' || p_hash, 0));
  IF p_col = 'net' THEN
    SELECT count(*) INTO v_n FROM (
      SELECT 1 FROM public.exos_wroom_entries x
       WHERE x.event_id = p_event_id AND x.run_id = p_run AND x.net_hash = p_hash AND x.kind = 'anon'
         AND ((x.state = 'waiting' AND x.last_seen_at > now() - interval '3 minutes')
           OR (x.state = 'admitted' AND x.admit_expires_at > now() AND x.used_at IS NULL))
       LIMIT p_share) q;
  ELSE
    SELECT count(*) INTO v_n FROM (
      SELECT 1 FROM public.exos_wroom_entries x
       WHERE x.event_id = p_event_id AND x.run_id = p_run AND x.net32_hash = p_hash AND x.kind = 'anon'
         AND ((x.state = 'waiting' AND x.last_seen_at > now() - interval '3 minutes')
           OR (x.state = 'admitted' AND x.admit_expires_at > now() AND x.used_at IS NULL))
       LIMIT p_share) q;
  END IF;
  RETURN v_n < p_share;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_net_room(uuid, uuid, text, text, int) FROM PUBLIC, anon, authenticated;

-- The live anonymous line, recounted at most every 5 s per event (try-lock),
-- in any open phase. First abandons, in a batch of at most 500, waiting
-- places idle for 30 minutes (index range scan; the rest go next time).
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
  UPDATE public.exos_wroom_entries x SET state = 'abandoned'
   WHERE x.id IN (SELECT y.id FROM public.exos_wroom_entries y
                   WHERE y.event_id = p_event_id AND y.run_id = s.run_id AND y.state = 'waiting'
                     AND y.last_seen_at <= now() - interval '30 minutes'
                   ORDER BY y.last_seen_at LIMIT 500
                   FOR UPDATE SKIP LOCKED);
  SELECT (SELECT count(*) FROM public.exos_wroom_entries x
           WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.state = 'waiting'
             AND x.last_seen_at > now() - interval '3 minutes' AND x.kind = 'anon')
       + (SELECT count(*) FROM public.exos_wroom_entries x
           WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.state = 'admitted'
             AND x.admit_expires_at > now() AND x.used_at IS NULL AND x.kind = 'anon')
    INTO v_n;
  UPDATE public.exos_wroom_settings
     SET live_count = v_n, counted_at = now(), count_round = count_round + 1
   WHERE event_id = p_event_id;
  DELETE FROM public.exos_wroom_counts c
   WHERE c.event_id = p_event_id AND (c.run_id <> s.run_id OR c.round < s.count_round);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_recount(uuid) FROM PUBLIC, anon, authenticated;

-- Is there room in the anonymous cap? (the last recount + mints since)
CREATE OR REPLACE FUNCTION public._exos_wroom_cap_room(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_wroom_settings%ROWTYPE;
BEGIN
  PERFORM public._exos_wroom_recount(p_event_id);
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  RETURN s.live_count + (SELECT coalesce(sum(c.n), 0) FROM public.exos_wroom_counts c
                          WHERE c.event_id = p_event_id AND c.run_id = s.run_id AND c.round = s.count_round)
         < public._exos_wroom_cap(s);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_cap_room(uuid) FROM PUBLIC, anon, authenticated;

-- Count one more anonymous place toward the cap (a mint or a revival).
CREATE OR REPLACE FUNCTION public._exos_wroom_count_one(p_event_id uuid)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  INSERT INTO public.exos_wroom_counts AS c (event_id, run_id, round, shard, org_id, n)
  SELECT s.event_id, s.run_id, s.count_round, floor(random() * 16)::smallint, s.org_id, 1
    FROM public.exos_wroom_settings s WHERE s.event_id = p_event_id
  ON CONFLICT (event_id, run_id, round, shard) DO UPDATE SET n = c.n + 1
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_count_one(uuid) FROM PUBLIC, anon, authenticated;

-- One admission round: freeze the on-sale, expire lapsed turns (a batch), the
-- next batch from the front, and the idle close. Runs on read; at most every
-- 5 seconds per event, never two at a time (try-lock). Every statement is
-- bounded (batches of at most 500, admissions at most 2,000 a round).
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
  v_close  boolean;
BEGIN
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF NOT FOUND THEN RETURN; END IF;
  IF s.advanced_at > now() - interval '5 seconds' THEN RETURN; END IF;
  ph := public._exos_wroom_phase(s);
  IF ph.phase <> 'live' THEN RETURN; END IF;
  IF NOT pg_try_advisory_xact_lock(hashtextextended('exos_wroom:' || p_event_id::text, 0)) THEN RETURN; END IF;
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id FOR UPDATE;
  IF s.advanced_at > now() - interval '5 seconds' THEN RETURN; END IF;
  ph := public._exos_wroom_phase(s);
  IF ph.phase <> 'live' THEN RETURN; END IF;

  UPDATE public.exos_wroom_entries e SET state = 'expired'
   WHERE e.id IN (SELECT y.id FROM public.exos_wroom_entries y
                   WHERE y.event_id = p_event_id AND y.run_id = s.run_id AND y.state = 'admitted'
                     AND y.admit_expires_at <= now()
                   ORDER BY y.admit_expires_at LIMIT 500 FOR UPDATE SKIP LOCKED);

  v_clock := greatest(coalesce(s.admit_clock, now() - interval '6 seconds'), now() - interval '60 seconds');
  -- At most 2,000 a round (a round is due every 5 s: up to 24,000 a minute),
  -- so the round stays well inside an anonymous request's time limit.
  v_budget := least(2000, s.admit_per_minute, floor(s.admit_per_minute * extract(epoch FROM now() - v_clock) / 60.0)::int);
  IF v_budget >= 1 THEN
    WITH nxt AS (
      SELECT e.id FROM public.exos_wroom_entries e
       WHERE e.event_id = p_event_id AND e.run_id = s.run_id AND e.state = 'waiting'
         AND e.last_seen_at > now() - interval '3 minutes'
       ORDER BY e.order_key, e.id
       LIMIT v_budget
       FOR UPDATE SKIP LOCKED)
    UPDATE public.exos_wroom_entries e
       SET state = 'admitted', admitted_at = now(),
           admit_expires_at = now() + make_interval(mins => s.admission_minutes), view_at = NULL
      FROM nxt WHERE e.id = nxt.id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_clock := CASE WHEN v_n < v_budget THEN now()
                    ELSE v_clock + make_interval(secs => v_budget * 60.0 / s.admit_per_minute) END;
  END IF;

  v_wait := EXISTS (SELECT 1 FROM public.exos_wroom_entries e
                     WHERE e.event_id = p_event_id AND e.run_id = s.run_id AND e.state = 'waiting'
                       AND e.last_seen_at > now() - interval '3 minutes');
  -- Close only once someone has actually waited or been let in.
  v_since := coalesce(s.last_waiting_at, s.first_admit_at, CASE WHEN v_n > 0 THEN now() END);
  v_close := NOT v_wait AND v_since IS NOT NULL AND now() - v_since >= make_interval(mins => s.idle_close_minutes);
  UPDATE public.exos_wroom_settings
     SET on_sale_at = ph.on_sale_at,
         admit_clock = v_clock,
         advanced_at = now(),
         first_admit_at = coalesce(first_admit_at, CASE WHEN v_n > 0 THEN now() END),
         last_waiting_at = CASE WHEN v_wait THEN now() ELSE last_waiting_at END,
         closed_at = CASE WHEN v_close THEN now() END,
         closed_reason = CASE WHEN v_close THEN 'idle' END
   WHERE event_id = p_event_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_advance(uuid) FROM PUBLIC, anon, authenticated;

-- A poll or a return with a place: 'ok' (last seen now, at most every
-- p_every seconds) or 'idle' (released for good). Under the entry's row lock.
-- Idle 3-30 minutes: an account place comes back; an anonymous one only if
-- its network shares and the cap still have room, else it is released.
-- Idle 30+ minutes, or abandoned: released.
CREATE OR REPLACE FUNCTION public._exos_wroom_touch(p_entry_id uuid, p_every int)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e  public.exos_wroom_entries%ROWTYPE;
  s  public.exos_wroom_settings%ROWTYPE;
  v_cap int;
  v_sc  boolean;
BEGIN
  -- No row lock on the common path (a fresh place): the admission round skips
  -- locked rows, so a poll must not hold its place's lock for long.
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = p_entry_id;
  IF NOT FOUND OR e.state = 'abandoned' THEN RETURN 'idle'; END IF;
  IF e.state = 'waiting' AND e.last_seen_at <= now() - interval '30 minutes' THEN
    UPDATE public.exos_wroom_entries SET state = 'abandoned' WHERE id = p_entry_id AND state = 'waiting';
    RETURN 'idle';
  END IF;
  IF e.state = 'waiting' AND e.last_seen_at <= now() - interval '3 minutes' THEN
    -- Coming back: under the row lock, re-read (two polls can't both revive).
    SELECT * INTO e FROM public.exos_wroom_entries WHERE id = p_entry_id FOR UPDATE;
    IF e.state = 'abandoned' THEN RETURN 'idle'; END IF;
    IF e.state = 'waiting' AND e.last_seen_at <= now() - interval '3 minutes' AND e.kind = 'anon' THEN
      SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = e.event_id;
      v_cap := public._exos_wroom_cap(s);
      v_sc := s.turnstile;
      IF NOT public._exos_wroom_net_room(e.event_id, e.run_id, 'net', e.net_hash,
               public._exos_wroom_share(CASE WHEN e.net_v6 THEN '48' ELSE 'v4' END, v_cap, v_sc))
         OR (e.net_v6 AND NOT public._exos_wroom_net_room(e.event_id, e.run_id, 'net32', e.net32_hash,
                                                           public._exos_wroom_share('32', v_cap, v_sc)))
         OR NOT public._exos_wroom_cap_room(e.event_id) THEN
        UPDATE public.exos_wroom_entries SET state = 'abandoned' WHERE id = p_entry_id;
        RETURN 'idle';
      END IF;
      UPDATE public.exos_wroom_entries SET last_seen_at = now(), view_at = NULL WHERE id = p_entry_id;
      PERFORM public._exos_wroom_count_one(e.event_id);
      RETURN 'ok';
    END IF;
    UPDATE public.exos_wroom_entries SET last_seen_at = now(), view_at = NULL WHERE id = p_entry_id;  -- an account: always
    RETURN 'ok';
  END IF;
  IF p_every = 0 OR e.last_seen_at < now() - make_interval(secs => p_every) THEN
    UPDATE public.exos_wroom_entries SET last_seen_at = now() WHERE id = p_entry_id;
  END IF;
  RETURN 'ok';
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_touch(uuid, int) FROM PUBLIC, anon, authenticated;

-- What a place's holder sees: its own state and place, never anyone else's.
-- Positions count at most 10,000 ahead (an index range scan); past that
-- 'position_capped' says "10,000+".
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
  v_base := jsonb_build_object('phase', ph.phase, 'on_sale_at', ph.on_sale_at, 'admit_per_minute', s.admit_per_minute,
                               'kind', e.kind)
            || CASE WHEN p_token IS NOT NULL THEN jsonb_build_object('token', p_token) ELSE '{}'::jsonb END;
  IF e.state = 'abandoned' OR (e.state = 'waiting' AND e.last_seen_at <= now() - interval '30 minutes') THEN
    RETURN v_base - 'token' || jsonb_build_object('state', 'expired', 'reason', 'idle');
  END IF;
  IF e.state = 'spent' THEN
    RETURN v_base - 'token' || jsonb_build_object('state', 'expired', 'reason', 'used');
  END IF;
  IF e.state = 'admitted' AND e.admit_expires_at > now() THEN
    RETURN v_base || jsonb_build_object('state', 'admitted', 'admitted_until', e.admit_expires_at, 'poll_after_ms', 60000);
  END IF;
  IF e.state <> 'waiting' THEN
    RETURN v_base || jsonb_build_object('state', 'expired', 'reason', 'lapsed');
  END IF;
  -- The lobby wakes up after the on-sale spread over 15 seconds: places are
  -- random already, so being first to ask is worth nothing.
  IF ph.phase = 'lobby' THEN
    RETURN v_base || jsonb_build_object('state', 'lobby',
      'poll_after_ms', least(30000, greatest(2000, (extract(epoch FROM ph.on_sale_at - now()) * 1000)::bigint
                                                    + 1000 + (random() * 15000)::bigint)));
  END IF;
  SELECT count(*) INTO v_ah FROM (
    SELECT 1 FROM public.exos_wroom_entries x
     WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.state = 'waiting'
       AND (x.order_key, x.id) < (e.order_key, e.id) AND x.last_seen_at > now() - interval '3 minutes'
     LIMIT 10001) q;
  v_eta := ceil((v_ah + 1)::numeric / s.admit_per_minute)::int;
  RETURN v_base || jsonb_build_object('state', 'waiting', 'position', least(v_ah, 10000) + 1, 'ahead', least(v_ah, 10000),
    'position_capped', v_ah > 10000, 'eta_minutes', v_eta,
    -- Farther back, slower: a crowd of 10,000 polls a few hundred times a second.
    'poll_after_ms', CASE WHEN v_eta > 5 THEN 30000 WHEN v_eta > 1 THEN 15000 ELSE 5000 END);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_view(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- The signed-in caller's account key for the event, or NULL (signed out).
-- Any signed-in caller keeps one place per run under it.
CREATE OR REPLACE FUNCTION public._exos_wroom_account(p_event_id uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT encode(sha256(convert_to(p_event_id::text || ':uid:' || u.id::text, 'UTF8')), 'hex')
    FROM auth.users u WHERE u.id = auth.uid()
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_account(uuid) FROM PUBLIC, anon, authenticated;

-- Does the signed-in caller get an always-a-place account seat? Only a
-- confirmed email AND either an account at least 7 days old or a fulfilled
-- paid order (any org). It doesn't rely on the project's auth settings
-- (email confirmation, signup CAPTCHA): new accounts queue as guests.
CREATE OR REPLACE FUNCTION public._exos_wroom_seat_eligible()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT u.email_confirmed_at IS NOT NULL
       AND (u.created_at <= now() - interval '7 days'
            OR EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs
                        WHERE cs.buyer_uid = u.id AND cs.amount_cents > 0
                          AND cs.status IN ('fulfilled', 'partially_refunded')))
      FROM auth.users u WHERE u.id = auth.uid()), false)
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_seat_eligible() FROM PUBLIC, anon, authenticated;

-- Was one of this place's checkout sessions fulfilled? (the turn is spent,
-- even if the fulfilment's trigger couldn't take the row's lock)
CREATE OR REPLACE FUNCTION public._exos_wroom_paid(p_entry_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_wroom_sessions ws
                   JOIN public.exos_checkout_sessions cs ON cs.session_id = ws.session_id
                  WHERE ws.entry_id = p_entry_id AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded'))
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_paid(uuid) FROM PUBLIC, anon, authenticated;

-- The buyer key a turn binds to.
CREATE OR REPLACE FUNCTION public._exos_wroom_buyer_hash(p_event_id uuid, p_buyer text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT encode(sha256(convert_to(p_event_id::text || ':' || lower(p_buyer), 'UTF8')), 'hex')
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_buyer_hash(uuid, text) FROM PUBLIC, anon, authenticated;

-- The turn a request may use. One per account: for 'uid:<id>' the account's
-- own place comes first (a token of another place doesn't stand in for it);
-- else the token's place. NULL without one.
CREATE OR REPLACE FUNCTION public._exos_wroom_find(p_event_id uuid, p_run uuid, p_token text, p_buyer text)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT e.id FROM public.exos_wroom_entries e
      WHERE p_buyer LIKE 'uid:%' AND e.event_id = p_event_id AND e.run_id = p_run
        AND e.account_hash = encode(sha256(convert_to(p_event_id::text || ':' || lower(p_buyer), 'UTF8')), 'hex')),
    (SELECT e.id FROM public.exos_wroom_entries e
      WHERE coalesce(p_token, '') ~ '^[0-9a-f]{64}$' AND e.token_hash = public._exos_wroom_hash(p_event_id, p_token)
        AND e.event_id = p_event_id AND e.run_id = p_run))
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_find(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;

-- The gate. p_mode: 'check' (no writes: exos_wroom_require), 'hold' (binds
-- the turn to its buyer), 'claim' (binds and spends it: the claim completes
-- in this transaction; p_ref is its order reference, so a retry of the same
-- claim passes). Returns when there is no open room, for the drop list
-- presale type in its early window, or for an admitted, unexpired, unspent
-- turn of this event's current run that is unused or this buyer's. A signed-in
-- buyer uses the account's place; binding an unbound guest place to an account
-- keys it on the account (one place per account per run). Raises XWR01 (wait
-- your turn) or XWR03 (turn used). The event is also taken from the type.
CREATE OR REPLACE FUNCTION public._exos_wroom_gate_token(p_event_id uuid, p_tier_id uuid, p_token text, p_buyer text,
  p_mode text DEFAULT 'hold', p_ref text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_wroom_settings%ROWTYPE;
  ph      record;
  e       public.exos_wroom_entries%ROWTYPE;
  v_tev   uuid;
  v_id    uuid;
  v_r     text;
  v_acct  text;
BEGIN
  SELECT t.event_id INTO v_tev FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id;
  IF v_tev IS NOT NULL AND v_tev IS DISTINCT FROM p_event_id THEN
    PERFORM public._exos_wroom_gate_token(v_tev, p_tier_id, p_token, p_buyer, p_mode, p_ref);
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
  IF p_mode <> 'check' THEN
    PERFORM public._exos_wroom_advance(p_event_id);  -- may close an idle room
    SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
    IF s.closed_at IS NOT NULL THEN RETURN; END IF;
  END IF;
  IF coalesce(p_buyer, '') !~ '^(uid|email|phone):.+$' THEN
    RAISE EXCEPTION 'exos waiting room: wait for your turn in the queue' USING ERRCODE = 'XWR01';
  END IF;
  v_id := public._exos_wroom_find(p_event_id, s.run_id, p_token, p_buyer);
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'exos waiting room: wait for your turn in the queue' USING ERRCODE = 'XWR01';
  END IF;
  v_r := public._exos_wroom_buyer_hash(p_event_id, p_buyer);
  IF p_mode = 'check' THEN
    SELECT * INTO e FROM public.exos_wroom_entries WHERE id = v_id;
  ELSE
    SELECT * INTO e FROM public.exos_wroom_entries WHERE id = v_id FOR UPDATE;
  END IF;
  IF e.state = 'spent' AND p_mode = 'claim' AND p_ref IS NOT NULL AND e.spent_ref = p_ref
     AND e.redeemer_hash = v_r THEN
    RETURN;  -- the same claim again (its own idempotency answers with the same tickets)
  END IF;
  IF e.state = 'spent' OR public._exos_wroom_paid(e.id) THEN
    RAISE EXCEPTION 'exos waiting room: this turn was used; join the line again to buy more' USING ERRCODE = 'XWR03';
  END IF;
  IF e.state <> 'admitted' OR e.admit_expires_at <= now()
     OR (e.redeemer_hash IS NOT NULL AND e.redeemer_hash <> v_r) THEN
    RAISE EXCEPTION 'exos waiting room: wait for your turn in the queue' USING ERRCODE = 'XWR01';
  END IF;
  IF p_mode = 'check' THEN RETURN; END IF;
  IF p_mode = 'lock' THEN
    -- Checked and row-locked, nothing written: the caller spends it (or not).
    PERFORM set_config('exos.wroom_locked', e.id::text, true);
    RETURN;
  END IF;
  v_acct := CASE WHEN p_buyer LIKE 'uid:%' AND e.account_hash IS NULL
                 THEN encode(sha256(convert_to(p_event_id::text || ':' || lower(p_buyer), 'UTF8')), 'hex') END;
  BEGIN
    UPDATE public.exos_wroom_entries x
       SET used_at = coalesce(x.used_at, now()), redeemer_hash = coalesce(x.redeemer_hash, v_r), last_seen_at = now(),
           account_hash = coalesce(x.account_hash, v_acct),
           state = CASE WHEN p_mode = 'claim' THEN 'spent' ELSE x.state END,
           spent_at = CASE WHEN p_mode = 'claim' THEN now() ELSE x.spent_at END,
           spent_ref = CASE WHEN p_mode = 'claim' THEN p_ref ELSE x.spent_ref END,
           view_at = NULL
     WHERE x.id = e.id;
  EXCEPTION WHEN unique_violation THEN
    -- The account got a place of its own meanwhile: one place per account.
    RAISE EXCEPTION 'exos waiting room: wait for your turn in the queue' USING ERRCODE = 'XWR01';
  END;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_gate_token(uuid, uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;

-- The same, with the token from the request's x-exos-queue header (what the
-- patched hold / claim functions call first, with their buyer).
CREATE OR REPLACE FUNCTION public._exos_wroom_gate(p_event_id uuid, p_tier_id uuid, p_buyer text, p_mode text DEFAULT 'hold',
  p_ref text DEFAULT NULL)
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
  PERFORM public._exos_wroom_gate_token(p_event_id, p_tier_id, public._exos_wroom_header_token(), p_buyer, p_mode, p_ref);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_gate(uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;

-- The phone RSVP's gate: its event, type and phone from the RSVP row. It
-- checks the turn and locks its row (in the same order as a hold: the place,
-- then the inventory) but writes nothing; only the RSVP turning 'confirmed'
-- in this same call spends it (the trigger below), so a wrong, expired or
-- locked code costs nothing. An RSVP already confirmed answers as before.
CREATE OR REPLACE FUNCTION public._exos_wroom_gate_rsvp(p_rsvp_id uuid)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record;
BEGIN
  PERFORM set_config('exos.wroom_rsvp', '', true);
  SELECT x.event_id, x.tier_id, x.phone, x.status INTO r FROM public.exos_phone_rsvps x WHERE x.id = p_rsvp_id;
  IF r.event_id IS NULL OR r.status IN ('confirmed', 'duplicate') THEN RETURN; END IF;
  PERFORM set_config('exos.wroom_locked', '', true);
  PERFORM public._exos_wroom_gate(r.event_id, r.tier_id, 'phone:' || coalesce(r.phone, ''), 'lock');
  IF coalesce(current_setting('exos.wroom_locked', true), '') <> '' THEN
    PERFORM set_config('exos.wroom_rsvp', p_rsvp_id::text || ':' || current_setting('exos.wroom_locked', true), true);
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_gate_rsvp(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_tg_wroom_rsvp()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v text := coalesce(current_setting('exos.wroom_rsvp', true), '');
BEGIN
  IF split_part(v, ':', 1) <> NEW.id::text THEN RETURN NULL; END IF;
  UPDATE public.exos_wroom_entries e
     SET state = 'spent', spent_at = now(), spent_ref = 'rsvp:' || NEW.id::text, used_at = coalesce(e.used_at, now()),
         redeemer_hash = coalesce(e.redeemer_hash, public._exos_wroom_buyer_hash(NEW.event_id, 'phone:' || coalesce(NEW.phone, ''))),
         last_seen_at = now(), view_at = NULL
   WHERE e.id = split_part(v, ':', 2)::uuid AND e.state = 'admitted';
  PERFORM set_config('exos.wroom_rsvp', '', true);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_wroom_rsvp() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_phone_rsvps_wroom ON public.exos_phone_rsvps;
CREATE TRIGGER exos_phone_rsvps_wroom AFTER UPDATE OF status ON public.exos_phone_rsvps
  FOR EACH ROW WHEN (NEW.status = 'confirmed' AND OLD.status IS DISTINCT FROM 'confirmed')
  EXECUTE FUNCTION public._exos_tg_wroom_rsvp();

-- The referral reward's gate: the reward voucher's event, the chosen type.
CREATE OR REPLACE FUNCTION public._exos_wroom_gate_reward(p_reward_id uuid, p_tier_id uuid)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_ev uuid;
BEGIN
  SELECT v.event_id INTO v_ev FROM public.exos_referral_rewards rw
    JOIN public.exos_vouchers v ON v.id = rw.voucher_id
   WHERE rw.id = p_reward_id;
  IF v_ev IS NULL THEN RETURN; END IF;
  PERFORM public._exos_wroom_gate(v_ev, p_tier_id, 'uid:' || coalesce(auth.uid()::text, ''), 'claim');
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_gate_reward(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The queue (anon + authenticated; no login needed)
-- ---------------------------------------------------------------------------
-- Arrive. Order of the branches (nothing O(line) before any of them):
--   1. a signed-in buyer (confirmed email): the account's place, resumed (a
--      used / lapsed / released one goes to the back), or a new one: always,
--      outside the cap, the network shares and Turnstile;
--   2. the browser's token: its place (an anonymous one is taken over by the
--      account that signs in with it);
--   3. a new anonymous place: Turnstile (else 'challenge'), 60 a minute per
--      IPv4 / IPv6 /64 and 120 per /48 ('busy'), the network shares and the
--      cap on the live line ('full', the page offers sign-in).
-- No room: { state: 'off' } (buy as usual).
-- An existing place, from a join or a poll: the cached view within 5 s of
-- the last write (no write at all), else at most 30 a minute per place
-- ('busy' over that), then the touch (idle rules), the round, the view; the
-- view is cached alongside the last_seen write (at most every 20 s).
CREATE OR REPLACE FUNCTION public._exos_wroom_resume(p_event_id uuid, p_entry_id uuid, p_token text)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e  public.exos_wroom_entries%ROWTYPE;
  s  public.exos_wroom_settings%ROWTYPE;
  v  jsonb;
  v_tok jsonb := CASE WHEN p_token IS NOT NULL THEN jsonb_build_object('token', p_token) ELSE '{}'::jsonb END;
BEGIN
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = p_entry_id;
  IF e.view_at > now() - interval '5 seconds' AND e.view_cache IS NOT NULL THEN
    RETURN e.view_cache || CASE WHEN e.view_cache ->> 'state' IN ('waiting', 'lobby', 'admitted') THEN v_tok ELSE '{}'::jsonb END;
  END IF;
  IF NOT public.exos_rate_hit('wroom-place:' || p_entry_id::text, 30) THEN
    RETURN coalesce(e.view_cache, jsonb_build_object('state', 'busy', 'retry_after_ms', 2000));
  END IF;
  PERFORM public._exos_wroom_advance(p_event_id);
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF s.closed_at IS NOT NULL THEN
    RETURN jsonb_build_object('state', 'off');
  END IF;
  IF public._exos_wroom_touch(p_entry_id, 20) = 'idle' THEN
    RETURN jsonb_build_object('state', 'expired', 'reason', 'idle');
  END IF;
  v := public._exos_wroom_view(p_event_id, p_entry_id);
  UPDATE public.exos_wroom_entries SET view_cache = v, view_at = now()
   WHERE id = p_entry_id AND last_seen_at > now() - interval '1 second';
  RETURN v || CASE WHEN v ->> 'state' IN ('waiting', 'lobby', 'admitted') THEN v_tok ELSE '{}'::jsonb END;
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_resume(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_wroom_join_core(p_event_id uuid, p_token text, p_verified boolean)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_wroom_settings%ROWTYPE;
  ph      record;
  e       public.exos_wroom_entries%ROWTYPE;
  v_id    uuid;
  v_token text;
  v_acct  text := public._exos_wroom_account(p_event_id);
  v_seat  boolean := false;
  v_buyer text;
  v_key   double precision;
  v_narrow text;
  v_wide  text;
  v_n32   text;
  v_net   text;
  v_net32 text;
  v_cap   int;
  v_sc    boolean;
BEGIN
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  ph := public._exos_wroom_phase(s);
  IF ph.phase IN ('off', 'before') THEN
    RETURN public._exos_wroom_view(p_event_id, NULL);
  END IF;
  v_key := CASE WHEN ph.phase = 'lobby' THEN public._exos_wroom_rand() ELSE 1 + extract(epoch FROM clock_timestamp()) END;
  IF v_acct IS NOT NULL THEN
    v_seat := public._exos_wroom_seat_eligible();
    v_buyer := public._exos_wroom_buyer_hash(p_event_id, 'uid:' || auth.uid()::text);
  END IF;

  -- 1. The account's place (seat or guest place): resumed, or a dead one re-placed at the back.
  IF v_acct IS NOT NULL THEN
    SELECT * INTO e FROM public.exos_wroom_entries x
     WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.account_hash = v_acct;
    IF FOUND THEN
      IF e.state IN ('spent', 'expired', 'abandoned') OR public._exos_wroom_paid(e.id)
         OR (e.state = 'admitted' AND e.admit_expires_at <= now())
         OR (e.state = 'waiting' AND e.last_seen_at <= now() - interval '30 minutes') THEN
        IF NOT v_seat THEN
          -- A guest place again: the same rules as a new one (below), on this row.
          v_id := e.id;
        ELSE
          v_token := encode(extensions.gen_random_bytes(32), 'hex');
          UPDATE public.exos_wroom_entries
             SET token_hash = public._exos_wroom_hash(p_event_id, v_token), order_key = v_key, state = 'waiting', kind = 'account',
                 arrived_at = now(), admitted_at = NULL, admit_expires_at = NULL, used_at = NULL, spent_at = NULL, spent_ref = NULL,
                 checkout_ref = NULL, checkout_at = NULL, session_id = NULL, last_seen_at = now(), view_at = NULL,
                 redeemer_hash = v_buyer
           WHERE id = e.id;
          PERFORM public._exos_wroom_advance(p_event_id);
          RETURN public._exos_wroom_view(p_event_id, e.id, v_token);
        END IF;
      ELSE
        IF v_seat AND e.kind = 'anon' THEN
          UPDATE public.exos_wroom_entries SET kind = 'account' WHERE id = e.id;  -- eligible now: a seat
        END IF;
        RETURN public._exos_wroom_resume(p_event_id, e.id, NULL) || jsonb_build_object('signed_in', true);
      END IF;
    END IF;
  END IF;

  -- 2. The browser's own token (not when the account already has a place: one per account).
  IF v_id IS NULL AND coalesce(p_token, '') ~ '^[0-9a-f]{64}$' THEN
    SELECT x.id INTO v_id FROM public.exos_wroom_entries x
     WHERE x.token_hash = public._exos_wroom_hash(p_event_id, p_token)
       AND x.event_id = p_event_id AND x.run_id = s.run_id;
    IF v_id IS NOT NULL THEN
      IF v_acct IS NOT NULL THEN
        -- Signed in on a browser that already queued: the place becomes the account's
        -- (a seat when eligible). A parallel join may have given the account a place
        -- first: then that one is the account's (one per account).
        BEGIN
          UPDATE public.exos_wroom_entries
             SET account_hash = v_acct, kind = CASE WHEN v_seat THEN 'account' ELSE kind END,
                 redeemer_hash = coalesce(redeemer_hash, v_buyer)
           WHERE id = v_id AND account_hash IS NULL AND (redeemer_hash IS NULL OR redeemer_hash = v_buyer);
        EXCEPTION WHEN unique_violation THEN
          SELECT x.id INTO v_id FROM public.exos_wroom_entries x
           WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.account_hash = v_acct;
          RETURN public._exos_wroom_resume(p_event_id, v_id, NULL) || jsonb_build_object('signed_in', true);
        END;
      END IF;
      RETURN public._exos_wroom_resume(p_event_id, v_id, p_token);
    END IF;
  END IF;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_wide := public._exos_wroom_wide_bucket();
  v_n32 := public._exos_wroom_net32();
  v_net := encode(sha256(convert_to(s.run_id::text || ':' || v_wide, 'UTF8')), 'hex');
  v_net32 := encode(sha256(convert_to(s.run_id::text || ':' || v_n32, 'UTF8')), 'hex');

  -- 3a. A new account seat (eligible accounts): always.
  IF v_seat THEN
    INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, kind, account_hash, redeemer_hash,
                                           net_hash, net32_hash, net_v6, order_key)
    VALUES (s.org_id, p_event_id, s.run_id, public._exos_wroom_hash(p_event_id, v_token), 'account', v_acct,
            v_buyer, v_net, v_net32, position(':' in v_wide) > 0, v_key)
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN  -- a parallel join of the same account won
      SELECT x.id INTO v_id FROM public.exos_wroom_entries x
       WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.account_hash = v_acct;
      RETURN public._exos_wroom_resume(p_event_id, v_id, NULL) || jsonb_build_object('signed_in', true);
    END IF;
    PERFORM public._exos_wroom_advance(p_event_id);
    RETURN public._exos_wroom_view(p_event_id, v_id, v_token);
  END IF;

  -- 3b. A guest place (signed out, or a signed-in account that isn't eligible
  -- for a seat: keyed on the account, under the guest rules).
  IF s.turnstile AND NOT coalesce(p_verified, false) THEN
    RETURN jsonb_build_object('state', 'challenge', 'signed_in', v_acct IS NOT NULL);
  END IF;
  v_narrow := public._exos_request_ip_bucket();
  IF NOT public.exos_rate_hit('wroom-ip:' || md5(v_narrow), 60)
     OR (v_wide <> v_narrow AND NOT public.exos_rate_hit('wroom-net:' || md5(v_wide), 120)) THEN
    RETURN jsonb_build_object('state', 'busy', 'retry_after_ms', 5000);
  END IF;
  PERFORM public._exos_wroom_advance(p_event_id);
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = p_event_id;
  IF s.closed_at IS NOT NULL THEN
    RETURN jsonb_build_object('state', 'off');
  END IF;
  v_cap := public._exos_wroom_cap(s);
  v_sc := s.turnstile AND coalesce(p_verified, false);
  IF NOT public._exos_wroom_net_room(p_event_id, s.run_id, 'net', v_net,
           public._exos_wroom_share(CASE WHEN position(':' in v_wide) > 0 THEN '48' ELSE 'v4' END, v_cap, v_sc))
     OR (position(':' in v_n32) > 0
         AND NOT public._exos_wroom_net_room(p_event_id, s.run_id, 'net32', v_net32, public._exos_wroom_share('32', v_cap, v_sc))) THEN
    RETURN jsonb_build_object('state', 'full', 'reason', 'network', 'poll_after_ms', 60000, 'signed_in', v_acct IS NOT NULL);
  END IF;
  IF NOT public._exos_wroom_cap_room(p_event_id) THEN
    RETURN jsonb_build_object('state', 'full', 'reason', 'room', 'poll_after_ms', 60000, 'signed_in', v_acct IS NOT NULL);
  END IF;
  IF v_id IS NOT NULL THEN
    -- The account's dead guest place, re-placed at the back.
    UPDATE public.exos_wroom_entries
       SET token_hash = public._exos_wroom_hash(p_event_id, v_token), order_key = v_key, state = 'waiting', kind = 'anon',
           arrived_at = now(), admitted_at = NULL, admit_expires_at = NULL, used_at = NULL, spent_at = NULL, spent_ref = NULL,
           checkout_ref = NULL, checkout_at = NULL, session_id = NULL, last_seen_at = now(), view_at = NULL,
           net_hash = v_net, net32_hash = v_net32, net_v6 = position(':' in v_wide) > 0, redeemer_hash = v_buyer
     WHERE id = v_id;
  ELSE
    INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, account_hash, redeemer_hash,
                                           net_hash, net32_hash, net_v6, order_key)
    VALUES (s.org_id, p_event_id, s.run_id, public._exos_wroom_hash(p_event_id, v_token), v_acct, v_buyer,
            v_net, v_net32, position(':' in v_wide) > 0, v_key)
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN  -- a parallel join of the same account won
      SELECT x.id INTO v_id FROM public.exos_wroom_entries x
       WHERE x.event_id = p_event_id AND x.run_id = s.run_id AND x.account_hash = v_acct;
      RETURN public._exos_wroom_resume(p_event_id, v_id, NULL) || jsonb_build_object('signed_in', true);
    END IF;
  END IF;
  PERFORM public._exos_wroom_count_one(p_event_id);
  RETURN public._exos_wroom_view(p_event_id, v_id, v_token);
END $$;
REVOKE ALL ON FUNCTION public._exos_wroom_join_core(uuid, text, boolean) FROM PUBLIC, anon, authenticated;

-- The browser's join (anon + authenticated): never verified, so with the
-- room's Turnstile on it can't mint an anonymous place ('challenge').
CREATE OR REPLACE FUNCTION public.exos_wroom_join(p_event_id uuid, p_token text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public._exos_wroom_join_core(p_event_id, p_token, false)
$$;
REVOKE ALL ON FUNCTION public.exos_wroom_join(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_wroom_join(uuid, text) TO anon, authenticated, service_role;

-- The platform's client-address headers (what exos-wroom-join received) in
-- place of this request's own, for the transaction, so _exos_request_ip()
-- applies its trusted-source rule (request_ip_source) to them.
CREATE OR REPLACE FUNCTION public._exos_wroom_use_headers(p_headers jsonb)
RETURNS void
LANGUAGE sql VOLATILE
SET search_path = public, pg_temp
AS $$
  SELECT set_config('request.headers', jsonb_strip_nulls(jsonb_build_object(
    'cf-connecting-ip', left(p_headers ->> 'cf-connecting-ip', 64),
    'x-forwarded-for', left(p_headers ->> 'x-forwarded-for', 512)))::text, true)
$$;
REVOKE ALL ON FUNCTION public._exos_wroom_use_headers(jsonb) FROM PUBLIC, anon, authenticated;

-- exos-wroom-join, before the external call: the client address by the
-- _exos_request_ip() rule ('no_ip' without one: the edge answers 503, never a
-- place in 'unknown') and 30 checks a minute per IPv4 / IPv6 /64 ('busy').
CREATE OR REPLACE FUNCTION public.exos_wroom_verify_gate(p_headers jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_ip text;
BEGIN
  PERFORM public._exos_wroom_use_headers(p_headers);
  v_ip := public._exos_request_ip();
  IF v_ip IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_ip'); END IF;
  IF NOT public.exos_rate_hit('wroom-tv:' || md5(public._exos_request_ip_bucket()), 30) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'busy');
  END IF;
  RETURN jsonb_build_object('ok', true, 'ip', v_ip);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_verify_gate(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wroom_verify_gate(jsonb) TO service_role;

-- exos-wroom-join (service role) after Cloudflare Turnstile passed.
CREATE OR REPLACE FUNCTION public.exos_wroom_join_verified(p_event_id uuid, p_token text, p_headers jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_wroom_use_headers(p_headers);
  IF public._exos_request_ip() IS NULL THEN
    RETURN jsonb_build_object('state', 'busy', 'retry_after_ms', 10000);
  END IF;
  RETURN public._exos_wroom_join_core(p_event_id, p_token, true);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_join_verified(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wroom_join_verified(uuid, text, jsonb) TO service_role;

-- Poll: the caller's own state and place (the signed-in account's, else the
-- token's), by the same rules as a join that finds a place
-- (_exos_wroom_resume: 5 s cache, 30 a minute per place).
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
  v_id := public._exos_wroom_find(p_event_id, s.run_id, p_token,
            CASE WHEN public._exos_wroom_account(p_event_id) IS NOT NULL THEN 'uid:' || auth.uid()::text END);
  IF v_id IS NULL THEN
    RETURN jsonb_build_object('state', 'unknown', 'phase', ph.phase);
  END IF;
  RETURN public._exos_wroom_resume(p_event_id, v_id, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_wroom_status(uuid, text) TO anon, authenticated, service_role;

-- exos-checkout's check (service role), with the event and type it resolved,
-- the token from the body and the buyer: check-only, nothing is written.
CREATE OR REPLACE FUNCTION public.exos_wroom_require(p_event_id uuid, p_tier_id uuid, p_token text,
  p_buyer_uid uuid, p_email text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_wroom_gate_token(p_event_id, p_tier_id, p_token,
    CASE WHEN p_buyer_uid IS NOT NULL THEN 'uid:' || p_buyer_uid::text
         ELSE 'email:' || lower(btrim(coalesce(p_email, ''))) END, 'check');
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_require(uuid, uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wroom_require(uuid, uuid, text, uuid, text) TO service_role;

-- exos-checkout, after its checks and before any hold or Stripe call: attach
-- this checkout attempt to the turn under the entry's row lock. One open
-- checkout per turn. Answers:
--   { attached: true }            attached (or no turn needed: false);
--   { takeover: '<cs_ id>' }      the same buyer's earlier Stripe session is
--                                  still attached: exos-checkout expires it at
--                                  Stripe (our own account), marks its row
--                                  expired (the trigger frees the turn) and
--                                  attaches again; a session already complete
--                                  or paying stays (XWR02);
-- XWR02 another attempt in flight (2 minutes without a session), or another
-- buyer's / a non-Stripe open session (35 minutes); XWR03 used.
CREATE OR REPLACE FUNCTION public.exos_wroom_attach(p_event_id uuid, p_tier_id uuid, p_token text,
  p_buyer_uid uuid, p_email text, p_attempt uuid)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s  public.exos_wroom_settings%ROWTYPE;
  ph record;
  e  public.exos_wroom_entries%ROWTYPE;
  v_buyer text := CASE WHEN p_buyer_uid IS NOT NULL THEN 'uid:' || p_buyer_uid::text
                       ELSE 'email:' || lower(btrim(coalesce(p_email, ''))) END;
  v_ev uuid := coalesce((SELECT t.event_id FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id), p_event_id);
  v_id uuid;
BEGIN
  SELECT * INTO s FROM public.exos_wroom_settings WHERE event_id = v_ev;
  ph := public._exos_wroom_phase(s);
  IF ph.phase IN ('off', 'before') THEN RETURN jsonb_build_object('attached', false); END IF;
  IF EXISTS (SELECT 1 FROM public.exos_drop_settings ds
              WHERE ds.event_id = v_ev AND ds.presale_tier_id = p_tier_id AND now() < ds.public_on_sale_at) THEN
    RETURN jsonb_build_object('attached', false);
  END IF;
  -- The same checks as the gate, then the lock.
  PERFORM public._exos_wroom_gate_token(v_ev, p_tier_id, p_token, v_buyer, 'check');
  v_id := public._exos_wroom_find(v_ev, s.run_id, p_token, v_buyer);
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = v_id FOR UPDATE;
  IF e.state = 'spent' OR public._exos_wroom_paid(e.id) THEN
    RAISE EXCEPTION 'exos waiting room: this turn was used; join the line again to buy more' USING ERRCODE = 'XWR03';
  END IF;
  IF e.checkout_ref IS NOT NULL AND e.checkout_ref <> p_attempt THEN
    IF e.session_id IS NULL AND e.checkout_at > now() - interval '2 minutes' THEN
      RAISE EXCEPTION 'exos waiting room: your turn is already checking out in another window' USING ERRCODE = 'XWR02';
    END IF;
    IF e.session_id IS NOT NULL AND e.checkout_at > now() - interval '35 minutes'
       AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs
                        WHERE cs.session_id = e.session_id AND cs.status IN ('failed', 'expired')) THEN
      IF e.redeemer_hash = public._exos_wroom_buyer_hash(v_ev, v_buyer) AND e.session_id LIKE 'cs\_%' THEN
        RETURN jsonb_build_object('takeover', e.session_id);
      END IF;
      RAISE EXCEPTION 'exos waiting room: your turn is already checking out in another window' USING ERRCODE = 'XWR02';
    END IF;
  END IF;
  UPDATE public.exos_wroom_entries
     SET checkout_ref = p_attempt, checkout_at = now(), session_id = NULL, view_at = NULL
   WHERE id = e.id;
  RETURN jsonb_build_object('attached', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_attach(uuid, uuid, text, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wroom_attach(uuid, uuid, text, uuid, text, uuid) TO service_role;

-- The attempt's order: its session id, before the session row is written
-- (kept in exos_wroom_sessions too: a fulfilled session spends the turn,
-- however late), and the buyer the turn binds to. False when the attempt
-- isn't attached any more (exos-checkout then stops before taking money).
CREATE OR REPLACE FUNCTION public.exos_wroom_bind(p_event_id uuid, p_attempt uuid, p_session_id text,
  p_buyer_uid uuid, p_email text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_wroom_entries%ROWTYPE;
BEGIN
  UPDATE public.exos_wroom_entries x
     SET session_id = left(p_session_id, 255), used_at = coalesce(x.used_at, now()),
         redeemer_hash = coalesce(x.redeemer_hash, public._exos_wroom_buyer_hash(x.event_id,
           CASE WHEN p_buyer_uid IS NOT NULL THEN 'uid:' || p_buyer_uid::text
                ELSE 'email:' || lower(btrim(coalesce(p_email, ''))) END))
   WHERE x.checkout_ref = p_attempt AND x.event_id = p_event_id
  RETURNING * INTO e;
  IF NOT FOUND THEN RETURN false; END IF;
  INSERT INTO public.exos_wroom_sessions (session_id, entry_id, org_id, event_id)
  VALUES (left(p_session_id, 255), e.id, e.org_id, e.event_id)
  ON CONFLICT (session_id) DO NOTHING;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_bind(uuid, uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wroom_bind(uuid, uuid, text, uuid, text) TO service_role;

-- A failed checkout (whatever the step, a bound session too) lets the turn
-- try again.
CREATE OR REPLACE FUNCTION public.exos_wroom_release(p_event_id uuid, p_attempt uuid)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_wroom_entries
     SET checkout_ref = NULL, checkout_at = NULL, session_id = NULL
   WHERE checkout_ref = p_attempt AND event_id = p_event_id AND state <> 'spent'
$$;
REVOKE ALL ON FUNCTION public.exos_wroom_release(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wroom_release(uuid, uuid) TO service_role;

-- A fulfilled order spends its turn; a failed or expired one frees it (the
-- attachment only: its session stays mapped, so a later fulfilment still
-- spends). SKIP LOCKED: a fulfilment never waits on (or deadlocks with) a
-- hold holding the place's row; the gate then sees the paid session itself
-- (_exos_wroom_paid) and the turn reads as used anyway.
CREATE OR REPLACE FUNCTION public._exos_tg_wroom_session()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'fulfilled' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'fulfilled') THEN
    UPDATE public.exos_wroom_entries e
       SET state = 'spent', spent_at = now(), view_at = NULL
     WHERE e.id IN (SELECT x.id FROM public.exos_wroom_entries x
                      JOIN public.exos_wroom_sessions ws ON ws.entry_id = x.id
                     WHERE ws.session_id = NEW.session_id AND x.state <> 'spent'
                     FOR UPDATE OF x SKIP LOCKED);
  ELSIF NEW.status IN ('failed', 'expired') AND TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    UPDATE public.exos_wroom_entries e
       SET checkout_ref = NULL, checkout_at = NULL
     WHERE e.id IN (SELECT x.id FROM public.exos_wroom_entries x
                     WHERE x.session_id = NEW.session_id AND x.state <> 'spent'
                     FOR UPDATE SKIP LOCKED);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_wroom_session() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_checkout_sessions_wroom ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_sessions_wroom AFTER INSERT OR UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_wroom_session();

-- ---------------------------------------------------------------------------
-- 4. Organizers
-- ---------------------------------------------------------------------------
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
         count(*) FILTER (WHERE e.used_at IS NOT NULL OR e.state = 'spent') AS checked_out,
         -- Expired: turns that lapsed unused, and places released (idle).
         count(*) FILTER (WHERE e.used_at IS NULL AND (e.state IN ('expired', 'abandoned')
                            OR (e.state = 'admitted' AND e.admit_expires_at <= now())
                            OR (e.state = 'waiting' AND e.last_seen_at <= now() - interval '3 minutes'))) AS expired,
         count(*) FILTER (WHERE e.kind = 'account') AS accounts,
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
    'opens_at_pin', s.opens_at,
    'turnstile', coalesce(s.turnstile, false),
    'cap', CASE WHEN s.event_id IS NOT NULL THEN public._exos_wroom_cap(s) END,
    'on_sale_at', CASE WHEN s.event_id IS NOT NULL AND ph.phase <> 'off' THEN ph.on_sale_at END,
    'opens_at', CASE WHEN s.event_id IS NOT NULL AND ph.phase <> 'off' THEN ph.opens_at END,
    'closed_at', s.closed_at, 'closed_reason', s.closed_reason,
    'counts', jsonb_build_object('waiting', coalesce(c.waiting, 0), 'admitted', coalesce(c.admitted, 0),
                                 'checked_out', coalesce(c.checked_out, 0), 'expired', coalesce(c.expired, 0),
                                 'accounts', coalesce(c.accounts, 0), 'total', coalesce(c.total, 0)),
    'wait_minutes', CASE WHEN coalesce(c.waiting, 0) > 0
                         THEN ceil(c.waiting::numeric / s.admit_per_minute)::int ELSE 0 END,
    'can_manage', public._exos_wroom_staff(p_event_id, ARRAY['owner', 'manager']) IS NOT NULL,
    -- A public type on sale already (no sales start, or one passed) with no
    -- pin makes the line live at once: no lobby, first come first served.
    'warnings', CASE WHEN coalesce(s.enabled, false) AND s.closed_at IS NULL AND s.opens_at IS NULL
                          AND public._exos_wroom_open_at(p_event_id) <= now()
                     THEN jsonb_build_array(jsonb_build_object('code', 'live_now',
                            'message', 'A public ticket type is on sale now, so the line is live at once with no lobby. '
                                       || 'Pin the on-sale time (or give the types a sales start) for a fair start.'))
                     ELSE '[]'::jsonb END);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_wroom_summary(uuid) TO authenticated, service_role;

-- Turn it on / off and set its numbers: owner / manager (or admin), audited.
-- Off -> on starts a new run: admitted, unexpired, unspent turns carry over,
-- the rest of the old line is deleted. On -> off closes it at once
-- ('organizer'). NULL keeps a value as it is.
DROP FUNCTION IF EXISTS public.exos_wroom_configure(uuid, boolean, int, int, int, int);
DROP FUNCTION IF EXISTS public.exos_wroom_configure(uuid, boolean, int, int, int, int, int);
DROP FUNCTION IF EXISTS public.exos_wroom_configure(uuid, boolean, int, int, int, int, int, boolean);
CREATE OR REPLACE FUNCTION public.exos_wroom_configure(
  p_event_id uuid, p_enabled boolean,
  p_window_minutes int DEFAULT NULL, p_admit_per_minute int DEFAULT NULL,
  p_admission_minutes int DEFAULT NULL, p_idle_close_minutes int DEFAULT NULL,
  -- The most anonymous places in line: NULL keeps it, 0 = automatic (5 x capacity).
  p_max_entries int DEFAULT NULL,
  -- Cloudflare Turnstile in front of new anonymous places: NULL keeps it.
  p_turnstile boolean DEFAULT NULL,
  -- The on-sale pin: NULL keeps it; p_clear_opens_at removes it.
  p_opens_at timestamptz DEFAULT NULL,
  p_clear_opens_at boolean DEFAULT false
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
  v_run  uuid := gen_random_uuid();
  v_pin  boolean := p_opens_at IS NOT NULL OR coalesce(p_clear_opens_at, false);
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
     OR (p_max_entries IS NOT NULL AND p_max_entries <> 0 AND p_max_entries NOT BETWEEN 100 AND 1000000)
     OR (p_opens_at IS NOT NULL AND (p_opens_at < now() - interval '1 day' OR p_opens_at > now() + interval '400 days')) THEN
    RAISE EXCEPTION 'exos_wroom_configure: window 0-240 min, 1-20000 a minute, admission 2-60 min, idle close 1-240 min, line 100-1000000 people, on-sale within 400 days'
      USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_wroom:' || p_event_id::text, 0));
  SELECT * INTO o FROM public.exos_wroom_settings WHERE event_id = p_event_id FOR UPDATE;
  v_live := FOUND AND o.enabled AND o.closed_at IS NULL;
  v_on := p_enabled AND NOT v_live;   -- off (or closed) -> on: a new run
  IF v_on THEN
    -- Admitted turns still valid carry over to the new run; the rest go.
    DELETE FROM public.exos_wroom_entries
     WHERE event_id = p_event_id
       AND NOT (state = 'admitted' AND admit_expires_at > now() AND run_id = o.run_id);
    UPDATE public.exos_wroom_entries SET run_id = v_run WHERE event_id = p_event_id;
    DELETE FROM public.exos_wroom_counts WHERE event_id = p_event_id;
  END IF;
  INSERT INTO public.exos_wroom_settings AS w (event_id, org_id, enabled, window_minutes, admit_per_minute,
                                               admission_minutes, idle_close_minutes, max_entries, turnstile, opens_at,
                                               run_id, enabled_at, updated_by, closed_at, closed_reason)
  VALUES (p_event_id, v_org, p_enabled, coalesce(p_window_minutes, 15), coalesce(p_admit_per_minute, 200),
          coalesce(p_admission_minutes, 10), coalesce(p_idle_close_minutes, 10), nullif(p_max_entries, 0),
          coalesce(p_turnstile, false), CASE WHEN p_clear_opens_at THEN NULL ELSE p_opens_at END,
          v_run, CASE WHEN p_enabled THEN now() END, auth.uid(),
          CASE WHEN NOT p_enabled THEN now() END, CASE WHEN NOT p_enabled THEN 'organizer' END)
  ON CONFLICT (event_id) DO UPDATE
     SET enabled = EXCLUDED.enabled,
         window_minutes = coalesce(p_window_minutes, w.window_minutes),
         admit_per_minute = coalesce(p_admit_per_minute, w.admit_per_minute),
         admission_minutes = coalesce(p_admission_minutes, w.admission_minutes),
         idle_close_minutes = coalesce(p_idle_close_minutes, w.idle_close_minutes),
         max_entries = CASE WHEN p_max_entries IS NULL THEN w.max_entries ELSE nullif(p_max_entries, 0) END,
         turnstile = coalesce(p_turnstile, w.turnstile),
         opens_at = CASE WHEN p_clear_opens_at THEN NULL ELSE coalesce(p_opens_at, w.opens_at) END,
         updated_by = EXCLUDED.updated_by,
         run_id = CASE WHEN v_on THEN v_run ELSE w.run_id END,
         enabled_at = CASE WHEN v_on THEN now() ELSE w.enabled_at END,
         -- A new pin unfreezes the on-sale moment.
         on_sale_at = CASE WHEN v_on OR v_pin THEN NULL ELSE w.on_sale_at END,
         admit_clock = CASE WHEN v_on THEN NULL ELSE w.admit_clock END,
         advanced_at = CASE WHEN v_on THEN NULL ELSE w.advanced_at END,
         first_admit_at = CASE WHEN v_on THEN NULL ELSE w.first_admit_at END,
         last_waiting_at = CASE WHEN v_on THEN NULL ELSE w.last_waiting_at END,
         live_count = CASE WHEN v_on THEN 0 ELSE w.live_count END,
         count_round = CASE WHEN v_on THEN 0 ELSE w.count_round END,
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
                       'max_entries', jsonb_build_array(o.max_entries, n.max_entries),
                       'turnstile', jsonb_build_array(o.turnstile, n.turnstile),
                       'opens_at', jsonb_build_array(o.opens_at, n.opens_at)));
  RETURN public.exos_wroom_summary(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_wroom_configure(uuid, boolean, int, int, int, int, int, boolean, timestamptz, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_wroom_configure(uuid, boolean, int, int, int, int, int, boolean, timestamptz, boolean)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The gate in the hold / claim functions (marker patches)
-- ---------------------------------------------------------------------------
-- One PERFORM as the first statement of each body, anchored on the body's
-- first line that is exactly BEGIN (the top-level block: these DECLARE
-- sections hold no BEGIN), checked to come before any statement, so it matches
-- prod's body whatever its exact text (supabase/README.md rule 4).
DO $$
DECLARE
  r     record;
  v_def text;
  v_at  int;
  v_pre text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.exos_create_hold(uuid,uuid,integer,integer,text)',
       $q$public._exos_wroom_gate(p_event_id, p_tier_id, 'uid:' || coalesce(auth.uid()::text, ''), 'hold')$q$),
      ('public.exos_create_guest_hold(uuid,uuid,integer,text,text,text)',
       $q$public._exos_wroom_gate(p_event_id, p_tier_id, 'email:' || lower(btrim(coalesce(p_email, ''))), 'hold')$q$),
      ('public.exos_claim_free_tickets(uuid,uuid,integer,text,text,text)',
       $q$public._exos_wroom_gate(p_event_id, p_tier_id, 'uid:' || coalesce(auth.uid()::text, ''), 'claim', p_order_ref)$q$),
      ('public.exos_phone_rsvp_verify(uuid,text,text)',
       $q$public._exos_wroom_gate_rsvp(p_rsvp_id)$q$),
      ('public.exos_redeem_referral_reward(uuid,uuid)',
       $q$public._exos_wroom_gate_reward(p_reward_id, p_tier_id)$q$)) v(f, call) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION '%: not present', r.f;
    END IF;
    v_def := replace(pg_get_functiondef(r.f::regprocedure), chr(13), '');
    IF position('/* exos: waiting room gate */' in v_def) > 0 THEN
      CONTINUE;
    END IF;
    v_at := position(E'\nBEGIN\n' in v_def);
    v_pre := substr(v_def, 1, greatest(v_at, 1));
    IF v_at = 0 OR v_at < position('$function$' in v_def)
       OR v_pre ~* '\m(RAISE|RETURN|PERFORM|UPDATE|INSERT|DELETE)\M' THEN
      RAISE EXCEPTION '%: no top-level BEGIN before the first statement', r.f;
    END IF;
    EXECUTE overlay(v_def placing E'\nBEGIN\n  PERFORM ' || r.call || E';  /* exos: waiting room gate */\n' from v_at for 7);
  END LOOP;
END $$;
