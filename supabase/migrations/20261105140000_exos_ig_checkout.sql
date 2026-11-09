-- ============================================================================
-- Migration 20261105140000 — Exos: Instagram / Facebook in-app browser
-- checkout (roadmap item 7a, docs/gtm-nyc.md "the wedge")
-- ============================================================================
-- NYC promoters sell from Instagram bio links and story swipe-ups, so most
-- buyers start checkout inside an app's embedded browser. The success metric
-- (docs/gtm-nyc.md) is checkout conversion inside the Instagram webview within
-- 10% of a real browser. This records where each checkout started so that
-- can be measured, and gives organizers the breakdown.
--
-- 1. exos_checkout_sessions.in_app_browser: 'instagram', 'facebook',
--    'messenger', 'threads', 'tiktok', 'snapchat', 'x', 'linkedin', 'webview'
--    (some other app's embedded browser), or 'none' (a real browser). NULL:
--    not recorded (sessions without a user agent). exos-checkout writes it
--    from the request's user agent plus the page's own probe
--    (supabase/functions/_shared/inAppBrowser.ts inAppRecordFor). A buyer who
--    left the app through the page's "open in your browser" link arrives with
--    ?iab_from=<kind>, kept in attribution.iab_from (_shared/attribution.ts),
--    so their browser sale still counts as Instagram traffic.
-- 2. _exos_in_app_browser_from_ua(text): the user-agent half of that rule in
--    SQL (the named app, else an Android WebView, else 'none'). It mirrors
--    _shared/inAppBrowser.ts PATTERNS; test_ig_checkout.sql runs the same
--    user agents as src/lib/inAppBrowser.test.ts. Used by
-- 3. a BEFORE INSERT trigger that fills in_app_browser from user_agent when
--    the inserter left it NULL (an exos-checkout deployed before this
--    migration, or any other insert path), and a one-time backfill of the
--    sessions recorded so far (user_agent is on them since 20260929131000).
-- 4. exos_event_in_app_report(event): per in-app browser (and escape
--    source), checkouts started, paid, tickets and gross. Owner / manager /
--    finance of the event's org, like the other event reports.
--
-- Touches:  W: TABLE exos_checkout_sessions (+ in_app_browser, CHECK,
--              trigger exos_checkout_in_app_browser, backfill)
--           C: FUNCTION _exos_in_app_browser_from_ua (pure, service role),
--              _exos_tg_checkout_in_app_browser (trigger, no client grant),
--              exos_event_in_app_report (authenticated: owner / manager /
--              finance)
-- Pre-reqs: 20260523170000 (sessions), 20260924223000 (attribution),
--           20260929131000 (user_agent)
-- Additive and re-run safe. No anon grant.
-- ============================================================================

-- 1. The column ----------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS in_app_browser text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_in_app_browser_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_in_app_browser_chk
      CHECK (in_app_browser IS NULL OR in_app_browser IN
        ('instagram', 'facebook', 'messenger', 'threads', 'tiktok', 'snapchat', 'x', 'linkedin', 'webview', 'none'));
  END IF;
END $$;

COMMENT ON COLUMN public.exos_checkout_sessions.in_app_browser IS
  'Where the checkout started: an app''s in-app browser (instagram, facebook, messenger, threads, tiktok, snapchat, x, linkedin), '
  'webview (another embedded browser) or none (a real browser); NULL = not recorded. '
  'exos-checkout (_shared/inAppBrowser.ts), else trigger exos_checkout_in_app_browser from user_agent. mig 20261105140000.';

-- 2. User agent -> kind --------------------------------------------------------
-- Same order as PATTERNS in _shared/inAppBrowser.ts: Threads ("Barcelona") and
-- Messenger before Facebook. Every in-app browser is a WebKit / Blink view, so
-- AppleWebKit/ is required (keeps link-preview bots out).
CREATE OR REPLACE FUNCTION public._exos_in_app_browser_from_ua(p_ua text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p_ua IS NULL OR p_ua = '' THEN NULL
    WHEN p_ua !~ 'AppleWebKit/' THEN 'none'
    WHEN p_ua ~ '\mBarcelona\M|\mThreads\M' THEN 'threads'
    WHEN p_ua ~* '\mInstagram\M' THEN 'instagram'
    WHEN p_ua ~* 'FB_IAB/(MESSENGER|Orca-Android)\M|\mFBAN/Messenger|\mMessengerForiOS|\mMessengerLite' THEN 'messenger'
    WHEN p_ua ~ '\mFBAN/|\mFBAV/|\mFB_IAB\M|\mFBIOS\M|\mFB4A\M' THEN 'facebook'
    WHEN p_ua ~* 'musical_ly|\mBytedanceWebview\M|\mTikTok\M|\mtrill_[0-9]' THEN 'tiktok'
    WHEN p_ua ~* '\mSnapchat\M' THEN 'snapchat'
    WHEN p_ua ~* '\mLinkedInApp\M' THEN 'linkedin'
    WHEN p_ua ~ '\mTwitter(Android)?\M' THEN 'x'
    WHEN p_ua ~* '\mAndroid\M' AND p_ua ~ ';\s*wv\)' THEN 'webview'
    ELSE 'none'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_in_app_browser_from_ua(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_in_app_browser_from_ua(text) TO service_role;

-- 3. Fill it on insert when the inserter didn't -------------------------------
-- Not SECURITY DEFINER: it only reads NEW. Only service_role (and table
-- owners) insert checkout sessions.
CREATE OR REPLACE FUNCTION public._exos_tg_checkout_in_app_browser()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.in_app_browser IS NULL AND NEW.user_agent IS NOT NULL THEN
    NEW.in_app_browser := public._exos_in_app_browser_from_ua(NEW.user_agent);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_checkout_in_app_browser() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_checkout_in_app_browser ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_in_app_browser BEFORE INSERT ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_checkout_in_app_browser();

-- The sessions recorded so far. Only NULLs with a user agent, so a re-run (and
-- the P0 replay) touches nothing. Every UPDATE trigger on this table acts on
-- a status change only (webhook, voucher, invoice, fees, commerce,
-- conversions), and status doesn't change here.
UPDATE public.exos_checkout_sessions
   SET in_app_browser = public._exos_in_app_browser_from_ua(user_agent)
 WHERE in_app_browser IS NULL AND user_agent IS NOT NULL;

-- Conversion reads scan one event's sessions by browser.
CREATE INDEX IF NOT EXISTS exos_checkout_sessions_event_in_app_idx
  ON public.exos_checkout_sessions (event_id, in_app_browser);

-- 4. The organizer's breakdown -------------------------------------------------
-- One row per (in_app_browser, attribution.iab_from): checkouts started (any
-- status), paid (fulfilled / partially refunded / refunded: the buyer paid),
-- their tickets and gross (amount_cents, before refunds). Conversion is
-- paid / started; the page works it out.
CREATE OR REPLACE FUNCTION public.exos_event_in_app_report(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_rows jsonb; v_currency text;
BEGIN
  SELECT e.org_id, lower(coalesce(e.currency, 'usd')) INTO v_org, v_currency
    FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_event_in_app_report: not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'in_app_browser', g.kind, 'escaped_from', g.escaped_from,
           'started', g.started, 'paid', g.paid, 'tickets', g.tickets, 'gross_cents', g.gross_cents)
           ORDER BY g.started DESC, g.kind, g.escaped_from NULLS FIRST), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT s.in_app_browser AS kind,
             CASE WHEN s.attribution ->> 'iab_from' IN
                    ('instagram', 'facebook', 'messenger', 'threads', 'tiktok', 'snapchat', 'x', 'linkedin', 'webview')
                  THEN s.attribution ->> 'iab_from' END AS escaped_from,
             count(*)::int AS started,
             count(*) FILTER (WHERE s.status IN ('fulfilled', 'partially_refunded', 'refunded'))::int AS paid,
             coalesce(sum(s.quantity) FILTER (WHERE s.status IN ('fulfilled', 'partially_refunded', 'refunded')), 0)::int AS tickets,
             coalesce(sum(s.amount_cents) FILTER (WHERE s.status IN ('fulfilled', 'partially_refunded', 'refunded')), 0)::bigint AS gross_cents
        FROM public.exos_checkout_sessions s
       WHERE s.event_id = p_event_id
       GROUP BY 1, 2
    ) g;
  RETURN jsonb_build_object('event_id', p_event_id, 'currency', v_currency, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_in_app_report(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_event_in_app_report(uuid) TO authenticated, service_role;
