-- ============================================================================
-- SMS marketing from the organizer's own Twilio / Telnyx number
-- ============================================================================
-- Touches:  C: TABLE exos_sms_subscribers, exos_sms_campaigns, exos_sms_outbox
--              (RLS on, no policies: RPCs only)
--           C: FUNCTION exos_sms_normalize_phone, exos_sms_opt_in,
--              exos_sms_my_status, exos_sms_opt_out_mine (fans);
--              exos_sms_audience, exos_sms_create_campaign,
--              exos_sms_cancel_campaign, exos_sms_campaigns (owner / manager,
--              finance reads); exos_sms_claim, exos_sms_mark,
--              exos_sms_inbound (service role)
--           C: cron.schedule (exos-sms-drain-1min, when pg_cron present)
-- Pre-reqs: 20261016090000 (org integrations: twilio / telnyx)
--
-- Consent first (TCPA / CTIA): a fan opts in with their own number and the
-- exact consent text they saw is stored with the time. Nothing is texted to a
-- number that didn't opt in to THAT org, or that replied STOP. Every message
-- ends with "Reply STOP to opt out" (added here, not left to the organizer).
-- Sends happen 9:00-20:00 in the event's (or New York) time, at most 8
-- marketing texts per number per 30 days per org. The sender is the org's own
-- Twilio / Telnyx account (Integrations); the org owns its registration
-- (10DLC / toll-free). The exos-sms-drain function sends; with
-- EXOS_SMS_LIVE unset it only records what it would send (dry run).
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_sms_normalize_phone(p_phone text, p_default_cc text DEFAULT '1')
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  WITH d AS (SELECT regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g') AS s)
  SELECT CASE
           WHEN s ~ '^\+[1-9][0-9]{7,14}$' THEN s
           WHEN s ~ '^[2-9][0-9]{9}$' AND p_default_cc = '1' THEN '+1' || s     -- US / CA 10 digits
           WHEN s ~ '^1[2-9][0-9]{9}$' AND p_default_cc = '1' THEN '+' || s
           ELSE NULL
         END
    FROM d
$$;
GRANT EXECUTE ON FUNCTION public.exos_sms_normalize_phone(text, text) TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.exos_sms_subscribers (
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  phone         text NOT NULL CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  user_id       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  source        text CHECK (source IS NULL OR length(source) <= 40),
  event_id      uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,  -- where they opted in
  consent_text  text NOT NULL CHECK (length(consent_text) BETWEEN 20 AND 600),
  consented_at  timestamptz NOT NULL DEFAULT now(),
  opted_out_at  timestamptz,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, phone)
);
CREATE INDEX IF NOT EXISTS exos_sms_subscribers_user_idx ON public.exos_sms_subscribers (user_id);
ALTER TABLE public.exos_sms_subscribers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_sms_subscribers FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.exos_sms_campaigns (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id     uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  audience     text NOT NULL CHECK (audience IN ('org', 'event_buyers')),
  body         text NOT NULL CHECK (length(body) BETWEEN 1 AND 480),
  provider     text NOT NULL CHECK (provider IN ('twilio', 'telnyx')),
  status       text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending', 'sent', 'cancelled')),
  send_after   timestamptz NOT NULL DEFAULT now(),
  queued_count integer NOT NULL DEFAULT 0,
  skipped_cap  integer NOT NULL DEFAULT 0,
  created_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_sms_campaigns_org_idx ON public.exos_sms_campaigns (org_id, created_at DESC);
ALTER TABLE public.exos_sms_campaigns ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_sms_campaigns FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.exos_sms_outbox (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id  uuid NOT NULL REFERENCES public.exos_sms_campaigns (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL,
  phone        text NOT NULL,
  body         text NOT NULL,
  status       text NOT NULL DEFAULT 'queued'
                 CHECK (status IN ('queued', 'sending', 'sent', 'dry_run', 'failed', 'skipped')),
  send_after   timestamptz NOT NULL,
  attempts     integer NOT NULL DEFAULT 0,
  lease_until  timestamptz,
  provider_id  text,
  error        text CHECK (error IS NULL OR length(error) <= 200),
  sent_at      timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, phone)
);
CREATE INDEX IF NOT EXISTS exos_sms_outbox_due_idx ON public.exos_sms_outbox (send_after) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS exos_sms_outbox_phone_idx ON public.exos_sms_outbox (org_id, phone, created_at DESC);
ALTER TABLE public.exos_sms_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_sms_outbox FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Fans
-- ---------------------------------------------------------------------------
-- Opt in to one org's texts with the consent text shown. Signed in only (so a
-- stranger can't sign someone else's number up anonymously); 10 a day per account.
CREATE OR REPLACE FUNCTION public.exos_sms_opt_in(
  p_org_id uuid, p_phone text, p_consent_text text, p_event_id uuid DEFAULT NULL, p_source text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_phone text := public.exos_sms_normalize_phone(p_phone);
  v_text  text := btrim(coalesce(p_consent_text, ''));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_sms_opt_in: sign in first' USING ERRCODE = '42501';
  END IF;
  IF v_phone IS NULL THEN
    RAISE EXCEPTION 'exos_sms_opt_in: enter a mobile number, e.g. +1 212 555 0100' USING ERRCODE = '22023';
  END IF;
  IF length(v_text) < 20 OR length(v_text) > 600 OR v_text !~* 'stop' THEN
    RAISE EXCEPTION 'exos_sms_opt_in: missing consent text' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org_id) THEN
    RAISE EXCEPTION 'exos_sms_opt_in: organizer not found' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_sms_subscribers WHERE user_id = v_uid AND updated_at > now() - interval '1 day') >= 10 THEN
    RAISE EXCEPTION 'exos_sms_opt_in: too many sign-ups today' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_sms_subscribers AS s (org_id, phone, user_id, source, event_id, consent_text, consented_at, opted_out_at, updated_at)
  VALUES (p_org_id, v_phone, v_uid, left(nullif(btrim(coalesce(p_source, '')), ''), 40), p_event_id, v_text, now(), NULL, now())
  ON CONFLICT (org_id, phone) DO UPDATE
     SET user_id = EXCLUDED.user_id, source = EXCLUDED.source, event_id = coalesce(EXCLUDED.event_id, s.event_id),
         consent_text = EXCLUDED.consent_text, consented_at = now(), opted_out_at = NULL, updated_at = now();
  RETURN jsonb_build_object('subscribed', true, 'phone', v_phone);
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_opt_in(uuid, text, text, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_sms_opt_in(uuid, text, text, uuid, text) TO authenticated, service_role;

-- The signed-in fan's subscription to an org (masked number), or nothing.
CREATE OR REPLACE FUNCTION public.exos_sms_my_status(p_org_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object('subscribed', s.opted_out_at IS NULL,
                            'phone_hint', '…' || right(s.phone, 4), 'since', s.consented_at)
    FROM public.exos_sms_subscribers s
   WHERE s.org_id = p_org_id AND s.user_id = auth.uid()
   ORDER BY s.updated_at DESC LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.exos_sms_my_status(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_sms_my_status(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_sms_opt_out_mine(p_org_id uuid)
RETURNS boolean
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH u AS (
    UPDATE public.exos_sms_subscribers SET opted_out_at = now(), updated_at = now()
     WHERE org_id = p_org_id AND user_id = auth.uid() AND opted_out_at IS NULL
    RETURNING 1)
  SELECT count(*) > 0 FROM u
$$;
REVOKE ALL ON FUNCTION public.exos_sms_opt_out_mine(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_sms_opt_out_mine(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Organizers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_sms_role(p_org_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public._exos_integ_role(p_org_id, auth.uid()) $$;
REVOKE ALL ON FUNCTION public._exos_sms_role(uuid) FROM PUBLIC, anon, authenticated;

-- How many numbers a campaign would reach (and how many the 30-day cap skips).
CREATE OR REPLACE FUNCTION public.exos_sms_audience(p_org_id uuid, p_audience text, p_event_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_total int; v_capped int;
BEGIN
  IF public._exos_sms_role(p_org_id) IS NULL THEN
    RAISE EXCEPTION 'exos_sms_audience: not authorized' USING ERRCODE = '42501';
  END IF;
  WITH a AS (
    SELECT s.phone FROM public.exos_sms_subscribers s
     WHERE s.org_id = p_org_id AND s.opted_out_at IS NULL
       AND (p_audience = 'org'
            OR (p_audience = 'event_buyers' AND s.user_id IS NOT NULL AND EXISTS (
                  SELECT 1 FROM public.exos_tickets t
                   WHERE t.event_id = p_event_id AND t.org_id = p_org_id
                     AND t.owner_id = s.user_id AND t.status IN ('active', 'used'))))
  )
  SELECT count(*),
         count(*) FILTER (WHERE (SELECT count(*) FROM public.exos_sms_outbox o
                                  WHERE o.org_id = p_org_id AND o.phone = a.phone
                                    AND o.status IN ('queued', 'sending', 'sent', 'dry_run')
                                    AND o.created_at > now() - interval '30 days') >= 8)
    INTO v_total, v_capped FROM a;
  RETURN jsonb_build_object('total', v_total, 'capped', v_capped, 'reachable', v_total - v_capped);
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_audience(uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_sms_audience(uuid, text, uuid) TO authenticated, service_role;

-- Owner / manager: queue a campaign. The send time moves into 9:00-20:00 in
-- the event's time zone (New York without an event).
CREATE OR REPLACE FUNCTION public.exos_sms_create_campaign(
  p_org_id uuid, p_body text, p_audience text, p_event_id uuid DEFAULT NULL, p_send_at timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_body     text := btrim(coalesce(p_body, ''));
  v_tz       text := 'America/New_York';
  v_provider text;
  v_at       timestamptz := greatest(coalesce(p_send_at, now()), now());
  v_local    timestamp;
  v_id       uuid;
  v_name     text;
  v_full     text;
  v_queued   int;
  v_capped   int;
BEGIN
  IF coalesce(public._exos_sms_role(p_org_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_sms_create_campaign: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_audience NOT IN ('org', 'event_buyers') THEN
    RAISE EXCEPTION 'exos_sms_create_campaign: pick who gets it' USING ERRCODE = '22023';
  END IF;
  IF p_audience = 'event_buyers' AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_sms_create_campaign: pick one of your events' USING ERRCODE = '22023';
  END IF;
  IF length(v_body) < 1 OR length(v_body) > 400 THEN
    RAISE EXCEPTION 'exos_sms_create_campaign: 1 to 400 characters' USING ERRCODE = '22023';
  END IF;
  SELECT i.provider INTO v_provider FROM public.exos_org_integrations i
   WHERE i.org_id = p_org_id AND i.provider IN ('twilio', 'telnyx') AND i.status = 'connected'
   ORDER BY (i.provider = 'twilio') DESC LIMIT 1;
  IF v_provider IS NULL THEN
    RAISE EXCEPTION 'exos_sms_create_campaign: connect Twilio or Telnyx in Integrations first (and test it)' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_sms_campaigns WHERE org_id = p_org_id AND created_at > now() - interval '1 day' AND status <> 'cancelled') >= 5 THEN
    RAISE EXCEPTION 'exos_sms_create_campaign: at most 5 campaigns a day' USING ERRCODE = '54000';
  END IF;
  IF p_event_id IS NOT NULL THEN
    SELECT coalesce(nullif(timezone, ''), v_tz) INTO v_tz FROM public.exos_events WHERE id = p_event_id;
  END IF;
  -- Quiet hours: 9:00-20:00 local.
  v_local := v_at AT TIME ZONE v_tz;
  IF v_local::time < time '09:00' THEN
    v_at := (date_trunc('day', v_local) + interval '9 hours') AT TIME ZONE v_tz;
  ELSIF v_local::time >= time '20:00' THEN
    v_at := (date_trunc('day', v_local) + interval '1 day 9 hours') AT TIME ZONE v_tz;
  END IF;

  SELECT name INTO v_name FROM public.exos_orgs WHERE id = p_org_id;
  -- Identify the sender and how to stop (CTIA): added to every message.
  v_full := left(v_name, 40) || ': ' || v_body || ' Reply STOP to opt out.';

  INSERT INTO public.exos_sms_campaigns (org_id, event_id, audience, body, provider, send_after, created_by)
  VALUES (p_org_id, p_event_id, p_audience, v_full, v_provider, v_at, auth.uid())
  RETURNING id INTO v_id;

  WITH a AS (
    SELECT s.phone,
           (SELECT count(*) FROM public.exos_sms_outbox o
             WHERE o.org_id = p_org_id AND o.phone = s.phone
               AND o.status IN ('queued', 'sending', 'sent', 'dry_run')
               AND o.created_at > now() - interval '30 days') AS recent
      FROM public.exos_sms_subscribers s
     WHERE s.org_id = p_org_id AND s.opted_out_at IS NULL
       AND (p_audience = 'org'
            OR (s.user_id IS NOT NULL AND EXISTS (
                  SELECT 1 FROM public.exos_tickets t
                   WHERE t.event_id = p_event_id AND t.org_id = p_org_id
                     AND t.owner_id = s.user_id AND t.status IN ('active', 'used'))))
  ), ins AS (
    INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after)
    SELECT v_id, p_org_id, a.phone, v_full, v_at FROM a WHERE a.recent < 8
    ON CONFLICT DO NOTHING
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM ins), (SELECT count(*) FROM a WHERE a.recent >= 8) INTO v_queued, v_capped;

  UPDATE public.exos_sms_campaigns SET queued_count = v_queued, skipped_cap = v_capped,
         status = CASE WHEN v_queued = 0 THEN 'sent' ELSE 'queued' END
   WHERE id = v_id;
  RETURN jsonb_build_object('campaign_id', v_id, 'queued', v_queued, 'skipped_cap', v_capped, 'send_after', v_at, 'body', v_full);
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_create_campaign(uuid, text, text, uuid, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_sms_create_campaign(uuid, text, text, uuid, timestamptz) TO authenticated, service_role;

-- Owner / manager: stop what hasn't gone out yet.
CREATE OR REPLACE FUNCTION public.exos_sms_cancel_campaign(p_campaign_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_sms_campaigns%ROWTYPE; v_n int;
BEGIN
  SELECT * INTO c FROM public.exos_sms_campaigns WHERE id = p_campaign_id FOR UPDATE;
  IF NOT FOUND OR coalesce(public._exos_sms_role(c.org_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_sms_cancel_campaign: owner or manager only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_sms_outbox SET status = 'skipped', error = 'cancelled'
   WHERE campaign_id = p_campaign_id AND status = 'queued';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.exos_sms_campaigns SET status = 'cancelled' WHERE id = p_campaign_id AND status IN ('queued', 'sending');
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_cancel_campaign(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_sms_cancel_campaign(uuid) TO authenticated, service_role;

-- Owner / manager / finance: campaigns with delivery counts, and the list size.
CREATE OR REPLACE FUNCTION public.exos_sms_campaigns(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public._exos_sms_role(p_org_id) IS NULL THEN
    RAISE EXCEPTION 'exos_sms_campaigns: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'subscribers', (SELECT count(*) FROM public.exos_sms_subscribers WHERE org_id = p_org_id AND opted_out_at IS NULL),
    'opted_out',   (SELECT count(*) FROM public.exos_sms_subscribers WHERE org_id = p_org_id AND opted_out_at IS NOT NULL),
    'provider',    (SELECT i.provider FROM public.exos_org_integrations i
                     WHERE i.org_id = p_org_id AND i.provider IN ('twilio', 'telnyx') AND i.status = 'connected'
                     ORDER BY (i.provider = 'twilio') DESC LIMIT 1),
    'campaigns', coalesce((SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC) FROM (
       SELECT jsonb_build_object('id', c.id, 'event_id', c.event_id, 'audience', c.audience, 'body', c.body,
                'status', c.status, 'send_after', c.send_after, 'created_at', c.created_at,
                'queued', c.queued_count, 'skipped_cap', c.skipped_cap,
                'sent', (SELECT count(*) FROM public.exos_sms_outbox o WHERE o.campaign_id = c.id AND o.status = 'sent'),
                'dry_run', (SELECT count(*) FROM public.exos_sms_outbox o WHERE o.campaign_id = c.id AND o.status = 'dry_run'),
                'failed', (SELECT count(*) FROM public.exos_sms_outbox o WHERE o.campaign_id = c.id AND o.status = 'failed')) AS x
         FROM public.exos_sms_campaigns c WHERE c.org_id = p_org_id ORDER BY c.created_at DESC LIMIT 50) q), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_campaigns(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_sms_campaigns(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- The drain (service role)
-- ---------------------------------------------------------------------------
-- Due messages with a 2-minute lease. A number that opted out since queuing
-- is skipped here (the last check before sending).
CREATE OR REPLACE FUNCTION public.exos_sms_claim(p_limit int DEFAULT 50)
RETURNS TABLE (id uuid, org_id uuid, provider text, phone text, body text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_sms_outbox o SET status = 'skipped', error = 'opted out'
   WHERE o.status = 'queued' AND o.send_after <= now()
     AND EXISTS (SELECT 1 FROM public.exos_sms_subscribers s
                  WHERE s.org_id = o.org_id AND s.phone = o.phone AND s.opted_out_at IS NOT NULL);
  RETURN QUERY
  WITH due AS (
    SELECT o.id FROM public.exos_sms_outbox o
      JOIN public.exos_sms_campaigns c ON c.id = o.campaign_id AND c.status IN ('queued', 'sending')
     WHERE (o.status = 'queued' OR (o.status = 'sending' AND o.lease_until < now() AND o.attempts < 3))
       AND o.send_after <= now()
     ORDER BY o.send_after
     LIMIT greatest(1, least(coalesce(p_limit, 50), 200))
     FOR UPDATE OF o SKIP LOCKED
  )
  UPDATE public.exos_sms_outbox o
     SET status = 'sending', attempts = o.attempts + 1, lease_until = now() + interval '2 minutes'
    FROM due, public.exos_sms_campaigns c
   WHERE o.id = due.id AND c.id = o.campaign_id
  RETURNING o.id, o.org_id, c.provider, o.phone, o.body;
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_claim(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_claim(int) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_sms_mark(p_id uuid, p_status text, p_provider_id text DEFAULT NULL, p_error text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_campaign uuid;
BEGIN
  IF p_status NOT IN ('sent', 'dry_run', 'failed', 'queued') THEN
    RAISE EXCEPTION 'exos_sms_mark: bad status' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_sms_outbox
     SET status = p_status, provider_id = left(p_provider_id, 80), error = left(p_error, 200),
         sent_at = CASE WHEN p_status IN ('sent', 'dry_run') THEN now() END,
         lease_until = NULL,
         send_after = CASE WHEN p_status = 'queued' THEN now() + interval '5 minutes' ELSE send_after END
   WHERE id = p_id AND status = 'sending'
  RETURNING campaign_id INTO v_campaign;
  IF v_campaign IS NULL THEN RETURN false; END IF;
  UPDATE public.exos_sms_campaigns c
     SET status = CASE WHEN EXISTS (SELECT 1 FROM public.exos_sms_outbox o WHERE o.campaign_id = c.id AND o.status IN ('queued', 'sending'))
                       THEN 'sending' ELSE 'sent' END
   WHERE c.id = v_campaign AND c.status IN ('queued', 'sending');
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_mark(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_mark(uuid, text, text, text) TO service_role;

-- Inbound replies (verified by the edge function): STOP-family opts out of
-- that org; START / UNSTOP opts back in (keeping the original consent).
CREATE OR REPLACE FUNCTION public.exos_sms_inbound(p_org_id uuid, p_from text, p_text text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_phone text := public.exos_sms_normalize_phone(p_from);
  v_word  text := upper(btrim(regexp_replace(coalesce(p_text, ''), '[^A-Za-z ]', '', 'g')));
BEGIN
  IF v_phone IS NULL THEN RETURN 'ignored'; END IF;
  IF v_word IN ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'STOP ALL', 'OPTOUT', 'REVOKE') THEN
    UPDATE public.exos_sms_subscribers SET opted_out_at = coalesce(opted_out_at, now()), updated_at = now()
     WHERE org_id = p_org_id AND phone = v_phone;
    UPDATE public.exos_sms_outbox SET status = 'skipped', error = 'opted out'
     WHERE org_id = p_org_id AND phone = v_phone AND status = 'queued';
    RETURN 'stopped';
  ELSIF v_word IN ('START', 'UNSTOP', 'YES') THEN
    UPDATE public.exos_sms_subscribers SET opted_out_at = NULL, updated_at = now()
     WHERE org_id = p_org_id AND phone = v_phone AND opted_out_at IS NOT NULL;
    RETURN CASE WHEN FOUND THEN 'started' ELSE 'ignored' END;
  ELSIF v_word = 'HELP' OR v_word = 'INFO' THEN
    RETURN 'help';
  END IF;
  RETURN 'ignored';
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_inbound(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_inbound(uuid, text, text) TO service_role;

-- Cron: every minute. Deploy exos-sms-drain first. Sending stays a dry run
-- until EXOS_SMS_LIVE=on is set on the function.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-sms-drain-1min') THEN
      PERFORM cron.unschedule('exos-sms-drain-1min');
    END IF;
    PERFORM cron.schedule('exos-sms-drain-1min', '* * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        coalesce(nullif(current_setting('app.exos_functions_url', true), ''),
                 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-sms-drain/cron', '{}'::jsonb);
    $cron$);
  END IF;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos-sms-drain-1min'); drop the
-- functions above and the three tables.
