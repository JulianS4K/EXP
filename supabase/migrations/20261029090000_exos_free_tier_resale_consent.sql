-- ============================================================================
-- Free tier (max capacity 150 or less) and the organizer's resale opt-in
-- (operator decisions 2026-10-29)
-- ============================================================================
-- Touches:  C: TABLE exos_resale_consents (RLS: owner / manager / finance read;
--              writes through the RPC only)
--           C: FUNCTION _exos_setting_int, _exos_setting_bool,
--              exos_free_tier_max_capacity (authenticated: the number only),
--              exos_free_tier_fee_bps, exos_resale_consent_required,
--              exos_event_capacity_bounded, exos_event_is_free_tier,
--              exos_resale_consent_active, _exos_resale_consent_version,
--              _exos_resale_consent_recheck, exos_event_fee_bps,
--              exos_event_fee_terms, exos_tg_event_resale_consent (service role)
--              exos_set_resale_consent, exos_event_sales_rules (authenticated,
--              role-checked)
--           R: FUNCTION exos_resale_min_capacity, exos_resale_unlocked,
--              _exos_resale_locked_msg, exos_tg_tier_resale_resync (CREATE OR
--              REPLACE: the new rule; every path 20261014140000 patched calls
--              exos_resale_unlocked, so they all follow)
--           W: FUNCTION exos_tg_marketplace_fee, exos_pos_settlement_summary
--              (patched: the Exos rate is the event's, 0 on the free tier)
--           C: TRIGGER exos_events_resale_consent (total_tickets)
-- Pre-reqs: 20261014140000 (resale rule) and the marketplace / S4K / POS chain
--
-- The rules:
--   1. An event whose max capacity (exos_event_max_capacity: the overall cap,
--      else the capped ticket types, a table counting its party size) is 150
--      or less is the FREE TIER: no Exos fee and no commission. It must also
--      be bounded (an overall cap, or every ticket type capped): an event with
--      an uncapped ticket type and no overall cap has no max, pays the normal
--      fee, and stays off resale (its capped types alone set its "max").
--   2. Free-tier events are never listed on resale marketplaces (StubHub,
--      SeatGeek, Vivid, Gametime, TickPick, GoTickets, Ticket Evolution, the
--      S4K route; Tixel later).
--   3. Over 150, resale needs the organizer's opt-in for that event: a consent
--      record (who, when, the consent text version, the max capacity then).
--      If the max capacity later drops to 150 or less the consent is revoked
--      (capacity_dropped), so going back over 150 needs a new opt-in.
--      Withdrawing it takes effect like a drop below the cutoff: ticked
--      marketplaces are pulled, pools planned to 0, the S4K pool released and
--      the event's S4K listings dropped.
--   4. Over 150 the fee stays as it is (3%, the org's first 6 months free).
--
-- Operator settings (exos_platform_settings, service role only; no row = the
-- default; a malformed value falls back to the default):
--   free_tier_max_capacity   int,  default 150: resale needs a max capacity
--                            over it; at or under it (bounded) is the free tier.
--                            -1: no free tier, any capacity may resell (the SQL
--                            harness's older fixtures, which have no caps)
--   free_tier_fee_bps        int,  default 0: the free tier's Exos rate
--   resale_consent_required  bool, default true: the opt-in rule (false is for
--                            the SQL harness's older marketplace fixtures)
-- The old key resale_min_capacity (20261014140000, "at least 250") is no
-- longer read: its row, if any, is removed here so nobody thinks it still
-- applies. exos_resale_min_capacity() stays (authenticated) and now answers
-- the smallest capacity that can resell: free_tier_max_capacity + 1.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

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

-- ---------------------------------------------------------------------------
-- 1. Settings.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_setting_int(p_key text, p_default integer, p_min integer, p_max integer)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN jsonb_typeof(value) = 'number' AND (value #>> '{}') ~ '^-?[0-9]{1,9}$'
                                AND (value #>> '{}')::bigint BETWEEN p_min AND p_max
                               THEN (value #>> '{}')::int END
                     FROM public.exos_platform_settings WHERE key = p_key), p_default)
$$;
REVOKE ALL ON FUNCTION public._exos_setting_int(text, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_setting_int(text, integer, integer, integer) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_setting_bool(p_key text, p_default boolean)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN jsonb_typeof(value) = 'boolean' THEN (value #>> '{}')::boolean END
                     FROM public.exos_platform_settings WHERE key = p_key), p_default)
$$;
REVOKE ALL ON FUNCTION public._exos_setting_bool(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_setting_bool(text, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_free_tier_max_capacity()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_setting_int('free_tier_max_capacity', 150, -1, 999999)
$$;
REVOKE ALL ON FUNCTION public.exos_free_tier_max_capacity() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_free_tier_max_capacity() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_free_tier_fee_bps()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_setting_int('free_tier_fee_bps', 0, 0, 10000)
$$;
REVOKE ALL ON FUNCTION public.exos_free_tier_fee_bps() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_free_tier_fee_bps() TO service_role;

CREATE OR REPLACE FUNCTION public.exos_resale_consent_required()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_setting_bool('resale_consent_required', true)
$$;
REVOKE ALL ON FUNCTION public.exos_resale_consent_required() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_resale_consent_required() TO service_role;

-- The old "at least N" number, kept for callers: the smallest max capacity
-- that can resell.
CREATE OR REPLACE FUNCTION public.exos_resale_min_capacity()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.exos_free_tier_max_capacity() + 1
$$;
REVOKE ALL ON FUNCTION public.exos_resale_min_capacity() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_resale_min_capacity() TO authenticated, service_role;

DELETE FROM public.exos_platform_settings WHERE key = 'resale_min_capacity';
COMMENT ON TABLE public.exos_platform_settings IS
  'Operator-set platform rules: free_tier_max_capacity (150), free_tier_fee_bps (0), resale_consent_required (true), last_call_threshold (10). Service role only. migs 20261014140000, 20261029090000, 20261029100000.';

-- ---------------------------------------------------------------------------
-- 2. Free tier.
-- ---------------------------------------------------------------------------
-- Bounded: an overall cap, or at least one ticket type and every one capped.
CREATE OR REPLACE FUNCTION public.exos_event_capacity_bounded(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(e.total_tickets, 0) > 0
         OR (count(t.id) > 0 AND NOT coalesce(bool_or(t.capacity = 0), false))
    FROM public.exos_events e
    LEFT JOIN public.exos_ticket_tiers t ON t.event_id = e.id
   WHERE e.id = p_event_id
   GROUP BY e.id, e.total_tickets
$$;
REVOKE ALL ON FUNCTION public.exos_event_capacity_bounded(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_capacity_bounded(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_event_is_free_tier(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(public.exos_event_capacity_bounded(p_event_id), false)
     AND coalesce(public.exos_event_max_capacity(p_event_id), 0) <= public.exos_free_tier_max_capacity()
$$;
REVOKE ALL ON FUNCTION public.exos_event_is_free_tier(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_is_free_tier(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Consent.
-- ---------------------------------------------------------------------------
-- The version of the opt-in text the organizer reads (src/lib/marketplace/
-- resaleConsent.ts RESALE_CONSENT_VERSION). Bump both together when the text
-- changes; an opt-in must name the current one.
CREATE OR REPLACE FUNCTION public._exos_resale_consent_version()
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$ SELECT '2026-10-29'::text $$;
REVOKE ALL ON FUNCTION public._exos_resale_consent_version() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_resale_consent_version() TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_resale_consents (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id               uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id                 uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  given_by               uuid NOT NULL,
  given_at               timestamptz NOT NULL DEFAULT now(),
  consent_version        text NOT NULL CHECK (length(consent_version) BETWEEN 1 AND 40),
  max_capacity_at_consent integer NOT NULL CHECK (max_capacity_at_consent >= 0),
  cutoff_at_consent      integer NOT NULL CHECK (cutoff_at_consent >= 0),
  revoked_at             timestamptz,
  revoked_by             uuid,
  revoke_reason          text CHECK (revoke_reason IS NULL OR revoke_reason IN ('withdrawn', 'capacity_dropped')),
  CHECK ((revoked_at IS NULL) = (revoke_reason IS NULL))
);
-- One live opt-in per event; withdrawn / revoked ones stay as history.
CREATE UNIQUE INDEX IF NOT EXISTS exos_resale_consents_live_uq
  ON public.exos_resale_consents (event_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_resale_consents_event_idx ON public.exos_resale_consents (event_id, given_at DESC);
ALTER TABLE public.exos_resale_consents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_resale_consents FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.exos_resale_consents TO authenticated;
GRANT ALL ON TABLE public.exos_resale_consents TO service_role;
DROP POLICY IF EXISTS exos_resale_consents_sel ON public.exos_resale_consents;
CREATE POLICY exos_resale_consents_sel ON public.exos_resale_consents FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
COMMENT ON TABLE public.exos_resale_consents IS
  'The organizer''s per-event resale opt-in (events over the free tier). Written by exos_set_resale_consent and the capacity triggers only. mig 20261029090000.';

CREATE OR REPLACE FUNCTION public.exos_resale_consent_active(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_resale_consents c WHERE c.event_id = p_event_id AND c.revoked_at IS NULL)
$$;
REVOKE ALL ON FUNCTION public.exos_resale_consent_active(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_resale_consent_active(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. The rule. Every resale path (20261014140000) asks exos_resale_unlocked.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_resale_unlocked(p_event_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(public.exos_event_max_capacity(p_event_id), 0) > public.exos_free_tier_max_capacity()
     AND (NOT public.exos_resale_consent_required() OR public.exos_resale_consent_active(p_event_id))
$$;
REVOKE ALL ON FUNCTION public.exos_resale_unlocked(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_resale_unlocked(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_resale_locked_msg(p_event_id uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN coalesce(public.exos_event_max_capacity(p_event_id), 0) <= public.exos_free_tier_max_capacity()
      THEN format('resale marketplaces need a max capacity over %s (events of %s or less are the free tier: no Exos fee, never resold); this event''s is %s',
                  public.exos_free_tier_max_capacity(), public.exos_free_tier_max_capacity(),
                  coalesce(public.exos_event_max_capacity(p_event_id), 0))
    ELSE 'resale is off for this event until an owner or manager opts in (Marketplaces, Resale opt-in)'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_resale_locked_msg(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_resale_locked_msg(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Revocation when the max capacity drops to the cutoff or below. Only the
--    consent row changes here: the resale paths already read the capacity
--    (the marketplace trigger pulls ticked marketplaces, the pool refill
--    plans every pool to 0 and releases the S4K pool, the feed drops it), as
--    for any drop below the cutoff.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_resale_consent_recheck(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_resale_consent_active(p_event_id)
     OR coalesce(public.exos_event_max_capacity(p_event_id), 0) > public.exos_free_tier_max_capacity() THEN
    RETURN false;
  END IF;
  UPDATE public.exos_resale_consents
     SET revoked_at = now(), revoked_by = NULL, revoke_reason = 'capacity_dropped'
   WHERE event_id = p_event_id AND revoked_at IS NULL;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public._exos_resale_consent_recheck(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_resale_consent_recheck(uuid) TO service_role;

-- A ticket type's capacity, kind or party size moves the max capacity. The
-- 20261014140000 version returned early unless capacity itself changed, so a
-- switch to / from a table (or a new party size) never re-ran the sync; it
-- now compares all three.
CREATE OR REPLACE FUNCTION public.exos_tg_tier_resale_resync()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_event uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.event_id ELSE NEW.event_id END;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.capacity, NEW.kind, NEW.party_size) IS NOT DISTINCT FROM (OLD.capacity, OLD.kind, OLD.party_size) THEN
    RETURN NULL;
  END IF;
  -- Down to the cutoff or below: the opt-in lapses (mig 20261029090000).
  PERFORM public._exos_resale_consent_recheck(v_event);
  UPDATE public.exos_events SET distribution_networks = distribution_networks
   WHERE id = v_event AND cardinality(coalesce(distribution_networks, '{}'::text[])) > 0;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_tier_resale_resync() FROM PUBLIC, anon, authenticated;

-- The overall cap.
CREATE OR REPLACE FUNCTION public.exos_tg_event_resale_consent()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.total_tickets IS DISTINCT FROM OLD.total_tickets THEN
    PERFORM public._exos_resale_consent_recheck(NEW.id);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_resale_consent() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER exos_events_resale_consent
  AFTER UPDATE OF total_tickets ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_resale_consent();

-- ---------------------------------------------------------------------------
-- 6. Organizer RPCs.
-- ---------------------------------------------------------------------------
-- What the event's resale settings show. Owner / manager / finance.
CREATE OR REPLACE FUNCTION public.exos_event_sales_rules(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e      public.exos_events%ROWTYPE;
  c      public.exos_resale_consents%ROWTYPE;
  l      public.exos_resale_consents%ROWTYPE;
  v_cap  int;
  v_cut  int;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_event_sales_rules: not allowed' USING ERRCODE = '42501';
  END IF;
  v_cap := coalesce(public.exos_event_max_capacity(p_event_id), 0);
  v_cut := public.exos_free_tier_max_capacity();
  SELECT * INTO c FROM public.exos_resale_consents WHERE event_id = p_event_id AND revoked_at IS NULL;
  SELECT * INTO l FROM public.exos_resale_consents WHERE event_id = p_event_id AND revoked_at IS NOT NULL
   ORDER BY revoked_at DESC LIMIT 1;
  RETURN jsonb_build_object(
    'max_capacity', v_cap,
    'capacity_bounded', coalesce(public.exos_event_capacity_bounded(p_event_id), false),
    'free_tier_max_capacity', v_cut,
    'free_tier', public.exos_event_is_free_tier(p_event_id),
    'consent_required', public.exos_resale_consent_required(),
    'consent_version', public._exos_resale_consent_version(),
    'consent', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object(
        'given_at', c.given_at, 'given_by_email', (SELECT u.email FROM auth.users u WHERE u.id = c.given_by),
        'version', c.consent_version, 'max_capacity_at_consent', c.max_capacity_at_consent) END,
    'last_revoked', CASE WHEN l.id IS NOT NULL THEN jsonb_build_object(
        'revoked_at', l.revoked_at, 'reason', l.revoke_reason) END,
    'resale_unlocked', public.exos_resale_unlocked(p_event_id),
    'locked_reason', CASE WHEN NOT public.exos_resale_unlocked(p_event_id) THEN public._exos_resale_locked_msg(p_event_id) END,
    'can_manage', public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager']));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_sales_rules(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_sales_rules(uuid) TO authenticated, service_role;

-- Opt in (p_on, naming the consent text version read) or withdraw. Owner /
-- manager of the event's org; refused on the free tier. Withdrawing takes
-- effect at once: ticked marketplaces pulled, pools planned to 0 (a live
-- listing shrinks once the marketplace confirms, as any pool), the S4K pool
-- released and the event's S4K listings dropped.
CREATE OR REPLACE FUNCTION public.exos_set_resale_consent(p_event_id uuid, p_on boolean, p_consent_version text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e      public.exos_events%ROWTYPE;
  v_cap  int;
  v_cut  int;
  d      record;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_resale_consent: not allowed' USING ERRCODE = '42501';
  END IF;
  -- The route / split lock: an opt-in can't interleave with a route change.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_route:' || p_event_id::text, 0));

  IF coalesce(p_on, false) THEN
    IF e.status = 'cancelled' THEN
      RAISE EXCEPTION 'exos_set_resale_consent: the event was cancelled' USING ERRCODE = '22023';
    END IF;
    v_cap := coalesce(public.exos_event_max_capacity(p_event_id), 0);
    v_cut := public.exos_free_tier_max_capacity();
    IF v_cap <= v_cut THEN
      RAISE EXCEPTION 'exos_set_resale_consent: %', public._exos_resale_locked_msg(p_event_id) USING ERRCODE = '22023';
    END IF;
    IF p_consent_version IS DISTINCT FROM public._exos_resale_consent_version() THEN
      RAISE EXCEPTION 'exos_set_resale_consent: the resale terms changed; reload the page and read them again' USING ERRCODE = '22023';
    END IF;
    IF NOT public.exos_resale_consent_active(p_event_id) THEN
      INSERT INTO public.exos_resale_consents (event_id, org_id, given_by, consent_version, max_capacity_at_consent, cutoff_at_consent)
      VALUES (p_event_id, e.org_id, auth.uid(), p_consent_version, v_cap, v_cut);
      -- Marketplaces ticked before the opt-in get their event rows now.
      UPDATE public.exos_events SET distribution_networks = distribution_networks
       WHERE id = p_event_id AND cardinality(coalesce(distribution_networks, '{}'::text[])) > 0;
    END IF;
  ELSE
    -- Pools first, then the event, as an S4K order and a route change lock them.
    PERFORM 1 FROM public.exos_distribution_listings
     WHERE event_id = p_event_id AND tier_id IS NOT NULL
     ORDER BY tier_id, channel FOR UPDATE;
    UPDATE public.exos_resale_consents
       SET revoked_at = now(), revoked_by = auth.uid(), revoke_reason = 'withdrawn'
     WHERE event_id = p_event_id AND revoked_at IS NULL;
    IF FOUND THEN
      UPDATE public.exos_events SET distribution_networks = distribution_networks
       WHERE id = p_event_id AND cardinality(coalesce(distribution_networks, '{}'::text[])) > 0;
      FOR d IN SELECT id FROM public.exos_distribution_listings
                WHERE event_id = p_event_id AND tier_id IS NOT NULL AND sell_cap IS NOT NULL
                  AND status IN ('pending', 'planned', 'listing', 'listed')
                ORDER BY tier_id, channel LOOP
        PERFORM public.exos_sync_channel_hold(d.id, false);
      END LOOP;
      PERFORM public.exos_s4k_listings_sync(p_event_id);
    END IF;
  END IF;
  RETURN public.exos_event_sales_rules(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_resale_consent(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_resale_consent(uuid, boolean, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. The Exos fee: 0 (free_tier_fee_bps) on the free tier. The org's free
--    months still win (0); over the cutoff it's exos_org_fee_bps as before.
--    Same rule as _shared/platformFee.ts exosFeeBpsForEvent.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_fee_bps(p_event_id uuid, p_at timestamptz)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE
           WHEN public.exos_org_fee_bps(e.org_id, p_at) = 0 THEN 0
           WHEN public.exos_event_is_free_tier(e.id) THEN public.exos_free_tier_fee_bps()
           ELSE public.exos_org_fee_bps(e.org_id, p_at)
         END
    FROM public.exos_events e WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public.exos_event_fee_bps(uuid, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_fee_bps(uuid, timestamptz) TO service_role;

-- What exos-checkout needs to pick the rate (exosFeeBpsForEvent). max_capacity
-- is NULL for an event with no max (not bounded): never the free tier.
CREATE OR REPLACE FUNCTION public.exos_event_fee_terms(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
           'max_capacity', CASE WHEN public.exos_event_capacity_bounded(e.id) THEN public.exos_event_max_capacity(e.id) END,
           'free_tier_max_capacity', public.exos_free_tier_max_capacity(),
           'free_tier_fee_bps', public.exos_free_tier_fee_bps(),
           'free_tier', public.exos_event_is_free_tier(e.id))
    FROM public.exos_events e WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public.exos_event_fee_terms(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_fee_terms(uuid) TO service_role;

-- A marketplace sale on an event that is the free tier by the time it lands
-- (a live listing still shrinking) pays the free tier's rate.
SELECT pg_temp.exos_patch_n('public.exos_tg_marketplace_fee()',
  'exos_event_fee_bps',
  $o$public.exos_org_fee_bps(NEW.org_id, coalesce(NEW.sold_at, NEW.created_at, now()))$o$,
  $n$public.exos_event_fee_bps(NEW.event_id, coalesce(NEW.sold_at, NEW.created_at, now()))$n$, 1);

-- Box office (POS) card sales are the one fee path a free-tier event reaches.
SELECT pg_temp.exos_patch_n('public.exos_pos_settlement_summary(uuid)',
  'exos_event_fee_bps',
  $o$  v_bps := public.exos_org_fee_bps(v_org, now());$o$,
  $n$  v_bps := public.exos_event_fee_bps(p_event_id, now());   -- free tier: 0 (mig 20261029090000)$n$, 1);

-- ROLLBACK (manual): re-create exos_resale_min_capacity, exos_resale_unlocked,
-- _exos_resale_locked_msg and exos_tg_tier_resale_resync from 20261014140000;
-- restore exos_tg_marketplace_fee / exos_pos_settlement_summary to
-- exos_org_fee_bps; DROP TRIGGER exos_events_resale_consent; drop
-- exos_resale_consents and the functions created above.
