-- ============================================================================
-- Migration 20261118100000 — Exos: drop list ("Notify me") + on-sale blast
-- ============================================================================
-- Growth R&D pass 4, item 1 (branch claude/exos-drop-list). A published event
-- that is announced but not yet on sale (every public, sellable ticket type's
-- sales window opens in the future) takes "Notify me when tickets go on sale"
-- signups. When the event goes on sale, each confirmed signup gets ONE email
-- (and one text if they opted in), at most once.
--
-- What it reuses, and why it adds what it adds:
--   * Not the waitlist (exos_waitlist*): that list is for a SOLD-OUT event,
--     per ticket type, with queue positions, offers, holds and auto-assign
--     triggers. A pre-on-sale list has none of that; putting it there would
--     fire offers on a list that isn't waiting for returns. The event page
--     still shows the waitlist once an on-sale event sells out.
--   * Not followers (exos_org_follows): a follow is org-wide and long-lived;
--     this is one event, one mail.
--   * Not signup forms (exos_signup_*): those join the org's email list. This
--     list is narrower consent ("tell me when THIS event goes on sale"), so it
--     doesn't put anyone on the org's newsletter list or the fan profiles.
--     It reuses their shape: double opt-in for guests, a constant answer that
--     never says who is on a list, rate limits, minimal data.
--   * The guest-proof pattern (mig 20261105100000): a guest confirms by the
--     mailed link OR the 6-digit code typed on the page they signed up on; a
--     256-bit browser token (only its hash stored) gates the code, 5 tries
--     per code (_exos_proof_code / _exos_proof_hash reused).
--   * SMS consent rules (mig 20261016120000): texts only for a signed-in fan
--     (a stranger can't sign someone else's number up), the exact consent
--     words stored with the time, STOP honoured (exos_sms_stops, written by
--     exos_sms_inbound; a STOP after the consent wins), 8 texts per number per
--     30 days per org, 9:00-20:00 in the event's time zone, sent from the
--     org's own Twilio / Telnyx through the existing outbox + exos-sms-drain
--     (dry run until EXOS_SMS_LIVE=on). The blast queues one exos_sms_campaigns
--     row per event (new audience 'drop_list').
--   * The mail queue (exos_mail_enqueue): templates 'drop-confirm' and
--     'drop-on-sale', dedupe key per signup, List-Unsubscribe = the leave link.
--   * Presale: the existing machinery, a hidden ticket type unlocked by a code
--     (mig 20260925012000). The organizer picks a hidden type and N minutes;
--     Exos mints one voucher for it (valid until the public on-sale) and opens
--     that type N minutes early. exos_check_voucher (marker patch
--     /* exos: drop list code */) honours that code only for a confirmed list
--     member: a signed-in buyer whose account (or confirmed email) is on the
--     list, or, for the service role (exos-checkout), the verified email it
--     passes. Anonymous callers never pass (codes need an account already).
--     No new pricing path: the hidden type's own price applies.
--   * Tracking: the first-touch promoter code and UTM tags the visitor arrived
--     with (lib/attribution.ts), sanitized again here.
--
-- Touches:  C: TABLE exos_drop_signups, exos_drop_confirms, exos_drop_settings
--              (RLS on, no client grants: RPCs only)
--           C: FUNCTION exos_drop_status, exos_drop_signup, exos_drop_confirm,
--              exos_drop_confirm_code, exos_drop_leave (anon + authenticated);
--              exos_drop_join, exos_drop_leave_mine (authenticated);
--              exos_drop_list_summary (owner / manager / finance),
--              exos_drop_list_export, exos_drop_list_set_presale (owner /
--              manager; audited); exos_drop_list_blast, exos_drop_list_sweep
--              (service role); helpers _exos_drop_*
--           W: FUNCTION exos_check_voucher (marker /* exos: drop list code */)
--           W: CONSTRAINT exos_mail_template_check (+ drop-confirm,
--              drop-on-sale), exos_sms_campaigns_audience_check (+ drop_list)
--           C: cron exos-drop-list-blast-5min, created INACTIVE
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ROLLBACK (manual): unschedule the cron; drop the functions above and the
-- three tables; re-run 20260929080000's exos_check_voucher body.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_drop_signups (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id           uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  email              text NOT NULL CHECK (email = lower(btrim(email)) AND length(email) BETWEEN 3 AND 254),
  -- Set only when a signed-in account with that confirmed email joined.
  user_id            uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  email_consent_text text NOT NULL CHECK (length(email_consent_text) BETWEEN 20 AND 600),
  confirmed_at       timestamptz,
  -- Texts: signed-in only, the exact words shown, and when.
  sms_phone          text CHECK (sms_phone IS NULL OR sms_phone ~ '^\+[1-9][0-9]{7,14}$'),
  sms_consent_text   text CHECK (sms_consent_text IS NULL OR length(sms_consent_text) BETWEEN 20 AND 600),
  sms_consented_at   timestamptz,
  sms_opted_out_at   timestamptz,
  -- First touch: the promoter code and UTM tags the visitor arrived with.
  promoter           text CHECK (promoter IS NULL OR promoter ~ '^[A-Za-z0-9_-]{1,64}$'),
  utm_source         text CHECK (utm_source IS NULL OR length(utm_source) <= 100),
  utm_medium         text CHECK (utm_medium IS NULL OR length(utm_medium) <= 100),
  utm_campaign       text CHECK (utm_campaign IS NULL OR length(utm_campaign) <= 100),
  -- The leave link in every mail (/drop/leave?t=…).
  leave_token        text NOT NULL UNIQUE
                       DEFAULT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
                       CHECK (leave_token ~ '^[0-9a-f]{64}$'),
  left_at            timestamptz,
  -- The blast: claimed once (blasted_at), what went out, and the text's fate.
  blasted_at         timestamptz,
  blast_kind         text CHECK (blast_kind IS NULL OR blast_kind IN ('on_sale', 'presale')),
  blast_mail_id      uuid,
  blast_skip         text CHECK (blast_skip IS NULL OR blast_skip IN ('opted_out', 'no_address')),
  sms_status         text CHECK (sms_status IS NULL OR sms_status IN ('queued', 'no_provider', 'stopped', 'capped', 'cancelled', 'duplicate')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, email),
  CONSTRAINT exos_drop_signups_sms_chk CHECK ((sms_phone IS NULL) = (sms_consent_text IS NULL))
);
CREATE INDEX IF NOT EXISTS exos_drop_signups_org_idx ON public.exos_drop_signups (org_id);
CREATE INDEX IF NOT EXISTS exos_drop_signups_user_idx ON public.exos_drop_signups (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_drop_signups_due_idx ON public.exos_drop_signups (event_id, confirmed_at)
  WHERE confirmed_at IS NOT NULL AND left_at IS NULL AND blasted_at IS NULL;
ALTER TABLE public.exos_drop_signups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_drop_signups FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_drop_signups TO service_role;
DROP TRIGGER IF EXISTS exos_drop_signups_touch ON public.exos_drop_signups;
CREATE TRIGGER exos_drop_signups_touch BEFORE UPDATE ON public.exos_drop_signups
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- One row per guest signup attempt (at most 3 a day per address and event):
-- each keeps its own link (7 days) and code (24 hours), so a second signup
-- never voids the first mail.
CREATE TABLE IF NOT EXISTS public.exos_drop_confirms (
  id                 uuid PRIMARY KEY,
  signup_id          uuid NOT NULL REFERENCES public.exos_drop_signups (id) ON DELETE CASCADE,
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  token_hash         text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  code_hash          text NOT NULL CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  browser_token_hash text NOT NULL CHECK (browser_token_hash ~ '^[0-9a-f]{64}$'),
  attempts           int NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  used_at            timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_drop_confirms_signup_idx ON public.exos_drop_confirms (signup_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_drop_confirms_browser_idx ON public.exos_drop_confirms (browser_token_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_drop_confirms_org_idx ON public.exos_drop_confirms (org_id);
ALTER TABLE public.exos_drop_confirms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_drop_confirms FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_drop_confirms TO service_role;

-- Per event: the list presale (a hidden ticket type + one voucher), and the
-- public on-sale time it was set against (a later change makes it stale).
CREATE TABLE IF NOT EXISTS public.exos_drop_settings (
  event_id           uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  presale_minutes    int CHECK (presale_minutes IS NULL OR presale_minutes BETWEEN 5 AND 1440),
  presale_tier_id    uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  presale_voucher_id uuid REFERENCES public.exos_vouchers (id) ON DELETE SET NULL,
  public_on_sale_at  timestamptz,
  updated_by         uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_drop_settings_org_idx ON public.exos_drop_settings (org_id);
CREATE INDEX IF NOT EXISTS exos_drop_settings_voucher_idx ON public.exos_drop_settings (presale_voucher_id) WHERE presale_voucher_id IS NOT NULL;
ALTER TABLE public.exos_drop_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_drop_settings FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_drop_settings TO service_role;
DROP TRIGGER IF EXISTS exos_drop_settings_touch ON public.exos_drop_settings;
CREATE TRIGGER exos_drop_settings_touch BEFORE UPDATE ON public.exos_drop_settings
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- When the public can buy: the earliest sales_start of the public, sellable
-- (capacity > 0) ticket types; -infinity when one of them has no start (on
-- sale now); NULL with none (nothing to sell).
CREATE OR REPLACE FUNCTION public._exos_drop_open_at(p_event_id uuid)
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN count(*) = 0 THEN NULL
              WHEN bool_or(t.sales_start IS NULL) THEN '-infinity'::timestamptz
              ELSE min(t.sales_start) END
    FROM public.exos_ticket_tiers t
   WHERE t.event_id = p_event_id AND t.visibility = 'public' AND t.capacity > 0
$$;
REVOKE ALL ON FUNCTION public._exos_drop_open_at(uuid) FROM PUBLIC, anon, authenticated;

-- Taking signups: published, not cancelled, sold on Exos (not linked out),
-- not started, and not on sale yet.
CREATE OR REPLACE FUNCTION public._exos_drop_open(p_event_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT e.status = 'published' AND e.cancelled_at IS NULL AND NOT e.link_out
           AND coalesce(e.ticket_backend, 'exos') = 'exos'
           AND (e.starts_at IS NULL OR e.starts_at > now())
           AND public._exos_drop_open_at(e.id) > now()
      FROM public.exos_events e WHERE e.id = p_event_id), false)
$$;
REVOKE ALL ON FUNCTION public._exos_drop_open(uuid) FROM PUBLIC, anon, authenticated;

-- The words a fan agrees to; exos_drop_status hands them to the page, so
-- what is shown is what is stored.
CREATE OR REPLACE FUNCTION public.exos_drop_email_consent_text(p_org_name text, p_event_name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT 'Email me once when tickets for ' || left(coalesce(p_event_name, ''), 120) || ' from '
         || left(coalesce(p_org_name, ''), 80) || ' go on sale. I can leave this list at any time.'
$$;
GRANT EXECUTE ON FUNCTION public.exos_drop_email_consent_text(text, text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_drop_sms_consent_text(p_org_name text, p_event_name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT 'Text me once at this number when tickets for ' || left(coalesce(p_event_name, ''), 120) || ' from '
         || left(coalesce(p_org_name, ''), 80) || ' go on sale. Msg & data rates may apply. '
         || 'Reply STOP to cancel, HELP for help. Consent is not a condition of purchase.'
$$;
GRANT EXECUTE ON FUNCTION public.exos_drop_sms_consent_text(text, text) TO anon, authenticated, service_role;

-- UTM-style tag, the same character set as _shared/attribution.ts sanitizeTag.
CREATE OR REPLACE FUNCTION public._exos_drop_tag(p text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT nullif(left(regexp_replace(btrim(coalesce(p, '')), '[^A-Za-z0-9 _.+\-/:@]', '', 'g'), 100), '')
$$;
REVOKE ALL ON FUNCTION public._exos_drop_tag(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_drop_promoter(p text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p ~ '^[A-Za-z0-9_-]{1,64}$' THEN p END
$$;
REVOKE ALL ON FUNCTION public._exos_drop_promoter(text) FROM PUBLIC, anon, authenticated;

-- Is this buyer a confirmed member of the event's list? Signed in: the
-- account (or its confirmed email). The service role (exos-checkout, which
-- passes the verified account email): that email. Anonymous: never.
CREATE OR REPLACE FUNCTION public._exos_drop_member(p_event_id uuid, p_email text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_role  text := coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                           nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
  v_email text;
BEGIN
  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
    RETURN EXISTS (SELECT 1 FROM public.exos_drop_signups s
                    WHERE s.event_id = p_event_id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL
                      AND (s.user_id = v_uid OR (v_email IS NOT NULL AND s.email = v_email)));
  END IF;
  IF v_role = 'anon' OR v_role = 'authenticated' THEN RETURN false; END IF;
  v_email := public._exos_fan_email(p_email);
  RETURN v_email IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.exos_drop_signups s
     WHERE s.event_id = p_event_id AND s.email = v_email AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL);
END $$;
REVOKE ALL ON FUNCTION public._exos_drop_member(uuid, text) FROM PUBLIC, anon, authenticated;

-- The staff role on the event's org (admin counts as owner), or NULL.
CREATE OR REPLACE FUNCTION public._exos_drop_staff(p_event_id uuid, p_roles text[])
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT e.org_id FROM public.exos_events e
   WHERE e.id = p_event_id AND auth.uid() IS NOT NULL
     AND (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, p_roles))
$$;
REVOKE ALL ON FUNCTION public._exos_drop_staff(uuid, text[]) FROM PUBLIC, anon, authenticated;

-- The presale as it stands: set, and still matching the public on-sale time.
CREATE OR REPLACE FUNCTION public._exos_drop_presale(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN ds.presale_minutes IS NULL THEN jsonb_build_object('status', 'off')
    ELSE jsonb_build_object(
      'status', CASE WHEN v.id IS NULL OR v.valid_until IS DISTINCT FROM ds.public_on_sale_at
                       OR ds.public_on_sale_at IS DISTINCT FROM public._exos_drop_open_at(p_event_id)
                     THEN 'stale' ELSE 'set' END,
      'minutes', ds.presale_minutes, 'tier_id', ds.presale_tier_id, 'tier_name', t.name,
      'code', v.code, 'opens_at', ds.public_on_sale_at - make_interval(mins => ds.presale_minutes),
      'public_on_sale_at', ds.public_on_sale_at)
  END
  FROM (SELECT p_event_id AS id) x
  LEFT JOIN public.exos_drop_settings ds ON ds.event_id = x.id
  LEFT JOIN public.exos_vouchers v ON v.id = ds.presale_voucher_id AND v.event_id = x.id
  LEFT JOIN public.exos_ticket_tiers t ON t.id = ds.presale_tier_id AND t.event_id = x.id
$$;
REVOKE ALL ON FUNCTION public._exos_drop_presale(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Fans
-- ---------------------------------------------------------------------------
-- What the event page shows. Anyone: whether the list is open, when the
-- public on-sale is and whether the list gets a presale. Signed in: their own
-- signup only.
CREATE OR REPLACE FUNCTION public.exos_drop_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
  v_open  boolean := public._exos_drop_open(p_event_id);
  v_at    timestamptz;
  s       public.exos_drop_signups%ROWTYPE;
  v_out   jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.status = 'published') THEN
    RETURN jsonb_build_object('open', false);
  END IF;
  v_at := public._exos_drop_open_at(p_event_id);
  v_out := jsonb_build_object('open', v_open,
    'on_sale_at', CASE WHEN v_open THEN v_at END,
    'list_presale', v_open AND public._exos_drop_presale(p_event_id) ->> 'status' = 'set');
  IF v_open THEN   -- the exact words the signup stores, so the page shows what is kept
    SELECT v_out || jsonb_build_object('email_consent_text', public.exos_drop_email_consent_text(o.name, e.name),
                                       'sms_consent_text', public.exos_drop_sms_consent_text(o.name, e.name))
      INTO v_out FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id WHERE e.id = p_event_id;
  END IF;
  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
    SELECT * INTO s FROM public.exos_drop_signups x
     WHERE x.event_id = p_event_id AND (x.user_id = v_uid OR (v_email IS NOT NULL AND x.email = v_email))
     ORDER BY (x.user_id = v_uid) DESC NULLS LAST LIMIT 1;
    IF s.id IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(
        'joined', s.confirmed_at IS NOT NULL AND s.left_at IS NULL,
        'sms', s.sms_phone IS NOT NULL AND s.sms_opted_out_at IS NULL AND s.left_at IS NULL,
        'phone_hint', CASE WHEN s.sms_phone IS NOT NULL THEN '…' || right(s.sms_phone, 4) END);
    ELSE
      v_out := v_out || jsonb_build_object('joined', false, 'sms', false);
    END IF;
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_status(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_status(uuid) TO anon, authenticated, service_role;

-- A guest's signup (anon or signed in). ALWAYS answers {ok, status:
-- 'check_email'} for a well-formed request to an open list: whether the
-- address is new, pending, already on the list, or held back by a limit. A
-- confirm mail (link + 6-digit code) goes out unless the address is already
-- on the list or over its limits. Limits, before any work: 10 a minute per
-- network, 120 a minute per event, 5 a minute per address; then 3 confirm
-- mails a day per address and event.
CREATE OR REPLACE FUNCTION public.exos_drop_signup(
  p_event_id uuid, p_email text, p_browser_token text, p_source jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ok     constant jsonb := jsonb_build_object('ok', true, 'status', 'check_email');
  v_email  text := public._exos_fan_email(p_email);
  v_src    jsonb := CASE WHEN jsonb_typeof(p_source) = 'object' THEN p_source ELSE '{}'::jsonb END;
  e        record;
  s        public.exos_drop_signups%ROWTYPE;
  v_cid    uuid := gen_random_uuid();
  v_token  text;
  v_code   text;
BEGIN
  IF NOT public.exos_rate_hit('drop-ip:' || md5(public._exos_request_ip_bucket()), 10) THEN
    RETURN v_ok;
  END IF;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'exos_drop_signup: enter a valid email address' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_browser_token, '') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'exos_drop_signup: reload the page and try again' USING ERRCODE = '22023';
  END IF;
  IF NOT public._exos_drop_open(p_event_id) THEN
    RAISE EXCEPTION 'exos_drop_signup: this event isn''t taking signups' USING ERRCODE = 'P0002';
  END IF;
  IF NOT public.exos_rate_hit('drop-ev:' || p_event_id::text, 120)
     OR NOT public.exos_rate_hit('drop-em:' || md5(v_email), 5) THEN
    RETURN v_ok;
  END IF;
  SELECT ev.id, ev.org_id, ev.name, ev.starts_at, ev.timezone, ev.venue_name, ev.venue_location, o.name AS org_name
    INTO e FROM public.exos_events ev JOIN public.exos_orgs o ON o.id = ev.org_id WHERE ev.id = p_event_id;

  PERFORM pg_advisory_xact_lock(hashtextextended('exos_drop:' || p_event_id::text || ':' || v_email, 0));
  SELECT * INTO s FROM public.exos_drop_signups WHERE event_id = p_event_id AND email = v_email FOR UPDATE;
  IF s.id IS NOT NULL AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL THEN
    RETURN v_ok;                                   -- already on the list: nothing to send
  END IF;
  IF s.id IS NULL THEN
    INSERT INTO public.exos_drop_signups (org_id, event_id, email, email_consent_text,
                                          promoter, utm_source, utm_medium, utm_campaign)
    VALUES (e.org_id, p_event_id, v_email, public.exos_drop_email_consent_text(e.org_name, e.name),
            public._exos_drop_promoter(v_src ->> 'promoter'), public._exos_drop_tag(v_src ->> 'utm_source'),
            public._exos_drop_tag(v_src ->> 'utm_medium'), public._exos_drop_tag(v_src ->> 'utm_campaign'))
    RETURNING * INTO s;
  ELSIF (SELECT count(*) FROM public.exos_drop_confirms c
          WHERE c.signup_id = s.id AND c.created_at > now() - interval '1 day') >= 3 THEN
    RETURN v_ok;
  END IF;

  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_code  := public._exos_proof_code();
  INSERT INTO public.exos_drop_confirms (id, signup_id, org_id, token_hash, code_hash, browser_token_hash)
  VALUES (v_cid, s.id, s.org_id, encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
          public._exos_proof_hash(v_cid, 'drop', v_code), encode(sha256(convert_to(p_browser_token, 'UTF8')), 'hex'));
  PERFORM public.exos_mail_enqueue('drop-confirm', v_email,
    jsonb_build_object('org', jsonb_build_object('id', e.org_id, 'name', e.org_name),
                       'event', jsonb_build_object('id', e.id, 'name', e.name, 'starts_at', e.starts_at,
                                                   'timezone', e.timezone, 'venue_name', e.venue_name,
                                                   'venue_location', e.venue_location),
                       'token', v_token, 'code', v_code, 'leave_token', s.leave_token),
    'drop-confirm:' || v_cid::text, NULL, false, NULL);
  RETURN v_ok;
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_signup(uuid, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_signup(uuid, text, text, jsonb) TO anon, authenticated, service_role;

-- Mark a signup confirmed (the person proved the address).
CREATE OR REPLACE FUNCTION public._exos_drop_confirm_signup(p_signup_id uuid)
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_drop_signups
     SET confirmed_at = CASE WHEN confirmed_at IS NULL OR left_at IS NOT NULL THEN now() ELSE confirmed_at END,
         left_at = NULL
   WHERE id = p_signup_id
$$;
REVOKE ALL ON FUNCTION public._exos_drop_confirm_signup(uuid) FROM PUBLIC, anon, authenticated;

-- The mail's link (anon; the page takes a click so a mail scanner confirms
-- nothing). Answers the event and org name only.
CREATE OR REPLACE FUNCTION public.exos_drop_confirm(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_drop_confirms%ROWTYPE; v_ev uuid; v_name text; v_org text;
BEGIN
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('ok', false); END IF;
  SELECT * INTO c FROM public.exos_drop_confirms
   WHERE token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') AND created_at > now() - interval '7 days'
   FOR UPDATE;
  IF c.id IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  IF c.used_at IS NULL THEN
    UPDATE public.exos_drop_confirms SET used_at = now() WHERE id = c.id;
    PERFORM public._exos_drop_confirm_signup(c.signup_id);
  END IF;
  SELECT e.id, e.name, o.name INTO v_ev, v_name, v_org
    FROM public.exos_drop_signups s JOIN public.exos_events e ON e.id = s.event_id JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE s.id = c.signup_id;
  RETURN jsonb_build_object('ok', true, 'event_id', v_ev, 'event_name', v_name, 'org_name', v_org);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_confirm(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_confirm(text) TO anon, authenticated, service_role;

-- The 6-digit code, typed on the page the guest signed up on (its browser
-- token gates it). 5 wrong tries spend the code; 20 tries a minute per
-- network. Answers only {ok}: the same false for a wrong code, a spent one
-- or no signup from this browser.
CREATE OR REPLACE FUNCTION public.exos_drop_confirm_code(p_event_id uuid, p_browser_token text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_drop_confirms%ROWTYPE; v_code text := btrim(coalesce(p_code, ''));
BEGIN
  IF NOT public.exos_rate_hit('drop-code:' || md5(public._exos_request_ip_bucket()), 20) THEN
    RAISE EXCEPTION 'exos_drop_confirm_code: too many tries, wait a minute' USING ERRCODE = '54000';
  END IF;
  IF coalesce(p_browser_token, '') !~ '^[0-9a-f]{64}$' OR v_code !~ '^[0-9]{6}$' THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT c2.* INTO c FROM public.exos_drop_confirms c2
    JOIN public.exos_drop_signups s ON s.id = c2.signup_id AND s.event_id = p_event_id
   WHERE c2.browser_token_hash = encode(sha256(convert_to(p_browser_token, 'UTF8')), 'hex')
     AND c2.used_at IS NULL AND c2.attempts < 5 AND c2.created_at > now() - interval '1 day'
   ORDER BY c2.created_at DESC LIMIT 1
   FOR UPDATE OF c2;
  IF c.id IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  IF c.code_hash <> public._exos_proof_hash(c.id, 'drop', v_code) THEN
    UPDATE public.exos_drop_confirms SET attempts = attempts + 1 WHERE id = c.id;
    RETURN jsonb_build_object('ok', false);
  END IF;
  UPDATE public.exos_drop_confirms SET used_at = now() WHERE id = c.id;
  PERFORM public._exos_drop_confirm_signup(c.signup_id);
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_confirm_code(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_confirm_code(uuid, text, text) TO anon, authenticated, service_role;

-- One click for a signed-in fan with a confirmed email (it is their proof).
-- Texts: their own number with the consent words, 10 numbers a day per
-- account (exos_sms_opt_in's limit). 10 joins a minute per account.
CREATE OR REPLACE FUNCTION public.exos_drop_join(
  p_event_id uuid, p_sms boolean DEFAULT false, p_phone text DEFAULT NULL, p_source jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
  v_phone text;
  v_src   jsonb := CASE WHEN jsonb_typeof(p_source) = 'object' THEN p_source ELSE '{}'::jsonb END;
  e       record;
  s       public.exos_drop_signups%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_drop_join: sign in first' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('drop-join:' || v_uid::text, 10) THEN
    RAISE EXCEPTION 'exos_drop_join: too many tries, wait a minute' USING ERRCODE = '54000';
  END IF;
  SELECT public._exos_fan_email(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'exos_drop_join: confirm your email address first' USING ERRCODE = '42501';
  END IF;
  IF NOT public._exos_drop_open(p_event_id) THEN
    RAISE EXCEPTION 'exos_drop_join: this event isn''t taking signups' USING ERRCODE = 'P0002';
  END IF;
  IF coalesce(p_sms, false) THEN
    v_phone := public.exos_sms_normalize_phone(p_phone);
    IF v_phone IS NULL THEN
      RAISE EXCEPTION 'exos_drop_join: enter a mobile number, e.g. +1 212 555 0100' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM public.exos_drop_signups x
         WHERE x.user_id = v_uid AND x.sms_consented_at > now() - interval '1 day') >= 10 THEN
      RAISE EXCEPTION 'exos_drop_join: too many text sign-ups today' USING ERRCODE = '54000';
    END IF;
  END IF;
  SELECT ev.id, ev.org_id, ev.name, o.name AS org_name INTO e
    FROM public.exos_events ev JOIN public.exos_orgs o ON o.id = ev.org_id WHERE ev.id = p_event_id;

  PERFORM pg_advisory_xact_lock(hashtextextended('exos_drop:' || p_event_id::text || ':' || v_email, 0));
  INSERT INTO public.exos_drop_signups AS x (org_id, event_id, email, user_id, email_consent_text, confirmed_at,
                                             promoter, utm_source, utm_medium, utm_campaign)
  VALUES (e.org_id, p_event_id, v_email, v_uid, public.exos_drop_email_consent_text(e.org_name, e.name), now(),
          public._exos_drop_promoter(v_src ->> 'promoter'), public._exos_drop_tag(v_src ->> 'utm_source'),
          public._exos_drop_tag(v_src ->> 'utm_medium'), public._exos_drop_tag(v_src ->> 'utm_campaign'))
  ON CONFLICT (event_id, email) DO UPDATE
     SET user_id = v_uid,
         email_consent_text = EXCLUDED.email_consent_text,
         confirmed_at = CASE WHEN x.confirmed_at IS NULL OR x.left_at IS NOT NULL THEN now() ELSE x.confirmed_at END,
         left_at = NULL
  RETURNING * INTO s;
  IF v_phone IS NOT NULL THEN
    UPDATE public.exos_drop_signups
       SET sms_phone = v_phone, sms_consent_text = public.exos_drop_sms_consent_text(e.org_name, e.name),
           sms_consented_at = now(), sms_opted_out_at = NULL
     WHERE id = s.id;
  END IF;
  RETURN public.exos_drop_status(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_join(uuid, boolean, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_drop_join(uuid, boolean, text, jsonb) TO authenticated, service_role;

-- Leave by the mail's link (anon, 64-hex). Email and texts both stop.
CREATE OR REPLACE FUNCTION public.exos_drop_leave(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_ev uuid;
BEGIN
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('ok', false); END IF;
  UPDATE public.exos_drop_signups
     SET left_at = coalesce(left_at, now()),
         sms_opted_out_at = CASE WHEN sms_phone IS NOT NULL THEN coalesce(sms_opted_out_at, now()) END
   WHERE leave_token = p_token
  RETURNING event_id INTO v_ev;
  IF v_ev IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  RETURN jsonb_build_object('ok', true, 'event_name', (SELECT name FROM public.exos_events WHERE id = v_ev));
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_leave(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_leave(text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_drop_leave_mine(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_email text; v_n int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'exos_drop_leave_mine: sign in first' USING ERRCODE = '42501'; END IF;
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
  UPDATE public.exos_drop_signups
     SET left_at = coalesce(left_at, now()),
         sms_opted_out_at = CASE WHEN sms_phone IS NOT NULL THEN coalesce(sms_opted_out_at, now()) END
   WHERE event_id = p_event_id AND (user_id = v_uid OR (v_email IS NOT NULL AND email = v_email));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_leave_mine(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_drop_leave_mine(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Organizers
-- ---------------------------------------------------------------------------
-- The tile: counts and sources, never an address. Owner / manager / finance.
CREATE OR REPLACE FUNCTION public.exos_drop_list_summary(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := public._exos_drop_staff(p_event_id, ARRAY['owner', 'manager', 'finance']); v_at timestamptz;
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_drop_list_summary: not authorized' USING ERRCODE = '42501';
  END IF;
  v_at := public._exos_drop_open_at(p_event_id);
  RETURN jsonb_build_object(
    'open', public._exos_drop_open(p_event_id),
    'on_sale_at', CASE WHEN v_at > '-infinity'::timestamptz THEN v_at END,
    'signups',   (SELECT count(*) FROM public.exos_drop_signups s WHERE s.event_id = p_event_id),
    'confirmed', (SELECT count(*) FROM public.exos_drop_signups s
                   WHERE s.event_id = p_event_id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL),
    'pending',   (SELECT count(*) FROM public.exos_drop_signups s
                   WHERE s.event_id = p_event_id AND s.confirmed_at IS NULL AND s.left_at IS NULL),
    'sms',       (SELECT count(*) FROM public.exos_drop_signups s
                   WHERE s.event_id = p_event_id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL
                     AND s.sms_phone IS NOT NULL AND s.sms_opted_out_at IS NULL),
    'left',      (SELECT count(*) FROM public.exos_drop_signups s WHERE s.event_id = p_event_id AND s.left_at IS NOT NULL),
    'notified',  (SELECT count(*) FROM public.exos_drop_signups s
                   WHERE s.event_id = p_event_id AND s.blasted_at IS NOT NULL AND s.blast_skip IS NULL),
    'texts_queued', (SELECT count(*) FROM public.exos_drop_signups s WHERE s.event_id = p_event_id AND s.sms_status = 'queued'),
    'sources', coalesce((SELECT jsonb_agg(x ORDER BY (x->>'signups')::int DESC, x->>'label') FROM (
        SELECT jsonb_build_object(
                 'label', CASE WHEN s.promoter IS NOT NULL THEN 'promoter:' || s.promoter
                               WHEN s.utm_source IS NOT NULL THEN s.utm_source
                               ELSE 'direct' END,
                 'promoter', s.promoter, 'utm_source', s.utm_source, 'utm_medium', s.utm_medium,
                 'utm_campaign', s.utm_campaign,
                 'signups', count(*),
                 'confirmed', count(*) FILTER (WHERE s.confirmed_at IS NOT NULL AND s.left_at IS NULL)) AS x
          FROM public.exos_drop_signups s WHERE s.event_id = p_event_id
         GROUP BY s.promoter, s.utm_source, s.utm_medium, s.utm_campaign
         ORDER BY count(*) DESC LIMIT 20) q), '[]'::jsonb),
    'presale', public._exos_drop_presale(p_event_id),
    'can_manage', public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager']));
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_list_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_drop_list_summary(uuid) TO authenticated, service_role;

-- CSV rows (the fans export pattern): owner / manager only, 3 a minute and 20
-- a day per org, an export.run row each. Confirmed members still on the list;
-- email, when, texts yes / no and the source. No phone, no tokens.
CREATE OR REPLACE FUNCTION public.exos_drop_list_export(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := public._exos_drop_staff(p_event_id, ARRAY['owner', 'manager']); v_rows jsonb; v_n int;
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_drop_list_export: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('drop-export:' || v_org::text, 3) THEN
    RAISE EXCEPTION 'exos_drop_list_export: too many exports, try again in a minute' USING ERRCODE = '54000';
  END IF;
  IF (SELECT count(*) FROM public.exos_org_audit a
       WHERE a.org_id = v_org AND a.action = 'export.run' AND a.entity_id = 'drop_list'
         AND a.at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION 'exos_drop_list_export: daily export limit reached (20 per organization)' USING ERRCODE = '54000';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'email', s.email, 'joined_at', s.created_at, 'confirmed_at', s.confirmed_at,
           'texts', s.sms_phone IS NOT NULL AND s.sms_opted_out_at IS NULL,
           'promoter', s.promoter, 'utm_source', s.utm_source, 'utm_medium', s.utm_medium,
           'utm_campaign', s.utm_campaign) ORDER BY s.confirmed_at, s.id), '[]'::jsonb)
    INTO v_rows
    FROM public.exos_drop_signups s
   WHERE s.event_id = p_event_id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL;
  v_n := jsonb_array_length(v_rows);
  /* exos: audit export.run */
  PERFORM public._exos_audit(v_org, 'export.run', 'export', 'drop_list', p_event_id,
    jsonb_build_object('kind', jsonb_build_array(NULL, 'drop_list'), 'row_count', jsonb_build_array(NULL, v_n)));
  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_list_export(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_drop_list_export(uuid) TO authenticated, service_role;

-- The list presale: owner / manager. p_minutes 5-1440 before the public
-- on-sale, on one of the event's HIDDEN ticket types (the existing presale
-- shape: a hidden type + a code). Mints (or moves) the one voucher for it,
-- valid until the public on-sale, and opens that type N minutes early.
-- p_minutes NULL / 0 turns it off (the code is deleted, or expired if used).
-- Refused once the list has been notified, or when the presale would open
-- in less than 10 minutes.
CREATE OR REPLACE FUNCTION public.exos_drop_list_set_presale(p_event_id uuid, p_minutes int, p_tier_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid := public._exos_drop_staff(p_event_id, ARRAY['owner', 'manager']);
  v_min  int := nullif(coalesce(p_minutes, 0), 0);
  v_at   timestamptz;
  ds     public.exos_drop_settings%ROWTYPE;
  t      public.exos_ticket_tiers%ROWTYPE;
  v_vid  uuid;
  v_code text;
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_drop_list_set_presale: owners and managers only' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_drop_blast:' || p_event_id::text, 0));
  SELECT * INTO ds FROM public.exos_drop_settings WHERE event_id = p_event_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.exos_drop_signups s WHERE s.event_id = p_event_id AND s.blasted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_drop_list_set_presale: the list has already been notified' USING ERRCODE = '23514';
  END IF;

  IF v_min IS NULL THEN
    IF ds.presale_voucher_id IS NOT NULL THEN
      DELETE FROM public.exos_vouchers WHERE id = ds.presale_voucher_id AND used_count = 0;
      UPDATE public.exos_vouchers SET valid_until = least(coalesce(valid_until, now()), now())
       WHERE id = ds.presale_voucher_id;
    END IF;
    IF ds.event_id IS NOT NULL THEN
      UPDATE public.exos_drop_settings
         SET presale_minutes = NULL, presale_tier_id = NULL, presale_voucher_id = NULL, public_on_sale_at = NULL,
             updated_by = auth.uid()
       WHERE event_id = p_event_id;
      /* exos: audit drop_list.presale_set */
      PERFORM public._exos_audit(v_org, 'drop_list.presale_set', 'event', p_event_id::text, p_event_id,
        jsonb_build_object('presale_minutes', jsonb_build_array(ds.presale_minutes, NULL),
                           'presale_tier_id', jsonb_build_array(ds.presale_tier_id, NULL)));
    END IF;
    RETURN public._exos_drop_presale(p_event_id);
  END IF;

  IF v_min < 5 OR v_min > 1440 THEN
    RAISE EXCEPTION 'exos_drop_list_set_presale: 5 to 1440 minutes' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO t FROM public.exos_ticket_tiers WHERE id = p_tier_id AND event_id = p_event_id FOR UPDATE;
  IF t.id IS NULL OR t.visibility <> 'hidden' OR t.capacity <= 0 THEN
    RAISE EXCEPTION 'exos_drop_list_set_presale: pick one of this event''s hidden ticket types with capacity' USING ERRCODE = '22023';
  END IF;
  v_at := public._exos_drop_open_at(p_event_id);
  IF v_at IS NULL OR v_at = '-infinity'::timestamptz OR v_at - make_interval(mins => v_min) < now() + interval '10 minutes' THEN
    RAISE EXCEPTION 'exos_drop_list_set_presale: the presale has to open at least 10 minutes from now, before the public on-sale' USING ERRCODE = '22023';
  END IF;

  IF ds.presale_voucher_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.exos_vouchers v WHERE v.id = ds.presale_voucher_id AND v.event_id = p_event_id) THEN
    v_vid := ds.presale_voucher_id;
    UPDATE public.exos_vouchers
       SET tier_id = t.id, valid_until = v_at, max_uses = greatest(t.capacity, used_count, 1)
     WHERE id = v_vid;
  ELSE
    v_code := 'LIST' || upper(encode(extensions.gen_random_bytes(5), 'hex'));
    INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity, valid_until, comment, created_by)
    VALUES (p_event_id, v_code, t.id, greatest(t.capacity, 1), false, v_at,
            'Drop list presale: works only for confirmed list members', auth.uid())
    RETURNING id INTO v_vid;
  END IF;
  UPDATE public.exos_ticket_tiers SET sales_start = v_at - make_interval(mins => v_min) WHERE id = t.id;
  INSERT INTO public.exos_drop_settings AS x (event_id, org_id, presale_minutes, presale_tier_id, presale_voucher_id,
                                              public_on_sale_at, updated_by)
  VALUES (p_event_id, v_org, v_min, t.id, v_vid, v_at, auth.uid())
  ON CONFLICT (event_id) DO UPDATE
     SET presale_minutes = EXCLUDED.presale_minutes, presale_tier_id = EXCLUDED.presale_tier_id,
         presale_voucher_id = EXCLUDED.presale_voucher_id, public_on_sale_at = EXCLUDED.public_on_sale_at,
         updated_by = EXCLUDED.updated_by;
  /* exos: audit drop_list.presale_set */
  PERFORM public._exos_audit(v_org, 'drop_list.presale_set', 'event', p_event_id::text, p_event_id,
    jsonb_build_object('presale_minutes', jsonb_build_array(ds.presale_minutes, v_min),
                       'presale_tier_id', jsonb_build_array(ds.presale_tier_id, t.id)));
  RETURN public._exos_drop_presale(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_list_set_presale(uuid, int, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_drop_list_set_presale(uuid, int, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The code honours list members only (exos_check_voucher marker patch)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.exos_check_voucher(uuid, text, text)'::regprocedure);
  v_old text := '  IF v.valid_until IS NOT NULL AND v.valid_until < now() THEN';
  v_new text := '  /* exos: drop list code */ -- mig 20261118100000: a drop-list presale code works only for the list
  IF EXISTS (SELECT 1 FROM public.exos_drop_settings ds WHERE ds.presale_voucher_id = v.id)
     AND NOT public._exos_drop_member(p_event_id, v_email) THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, ''invalid code''; RETURN;
  END IF;
' || v_old;
BEGIN
  IF position('/* exos: drop list code */' in v_def) > 0 THEN RETURN; END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'exos_check_voucher: expected one valid_until check';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- ---------------------------------------------------------------------------
-- 6. The blast (service role; cron below, INACTIVE)
-- ---------------------------------------------------------------------------
-- For each event with confirmed members not yet notified, once it is due:
-- at the public on-sale, or N minutes before it when a presale is set and
-- still matches (stale presale: plain on-sale mail at the on-sale). Each
-- signup is claimed once (blasted_at, under a per-event lock and SKIP LOCKED)
-- and its mail keyed 'drop-on-sale:<id>' in exos_mail_dedupe, so a re-run or a
-- parallel run never mails twice. Texts: one exos_sms_campaigns row per event
-- (audience 'drop_list'), consent re-checked (opted out, STOP after consent,
-- 8 a month, the org's provider connected), 9:00-20:00 local; a presale text
-- that quiet hours push past the public on-sale says "on sale" instead.
CREATE OR REPLACE FUNCTION public.exos_drop_list_blast(p_limit int DEFAULT 500)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_left    int := greatest(1, least(coalesce(p_limit, 500), 5000));
  v_mails   int := 0;
  v_texts   int := 0;
  ev        record;
  r         record;
  v_at      timestamptz;
  ps        jsonb;
  v_presale boolean;
  v_kind    text;
  v_code    text;
  v_mail    uuid;
  v_tz      text;
  v_send    timestamptz;
  v_local   timestamp;
  v_prov    text;
  v_camp    uuid;
  v_body    text;
  v_n       int;
  v_status  text;
BEGIN
  FOR ev IN
    SELECT e.id, e.org_id, e.name, e.starts_at, e.timezone, e.venue_name, e.venue_location, o.name AS org_name
      FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
     WHERE e.status = 'published' AND e.cancelled_at IS NULL AND (e.starts_at IS NULL OR e.starts_at > now())
       AND EXISTS (SELECT 1 FROM public.exos_drop_signups s
                    WHERE s.event_id = e.id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL AND s.blasted_at IS NULL)
     ORDER BY e.starts_at NULLS LAST, e.id
  LOOP
    EXIT WHEN v_left <= 0;
    v_at := public._exos_drop_open_at(ev.id);
    CONTINUE WHEN v_at IS NULL;
    ps := public._exos_drop_presale(ev.id);
    v_presale := ps ->> 'status' = 'set';
    CONTINUE WHEN now() < CASE WHEN v_presale THEN v_at - make_interval(mins => (ps ->> 'minutes')::int) ELSE v_at END;
    IF v_presale AND now() >= v_at THEN v_presale := false; END IF;   -- presale over: plain on-sale
    v_kind := CASE WHEN v_presale THEN 'presale' ELSE 'on_sale' END;
    v_code := CASE WHEN v_presale THEN ps ->> 'code' END;

    PERFORM pg_advisory_xact_lock(hashtextextended('exos_drop_blast:' || ev.id::text, 0));
    v_tz := coalesce(nullif(ev.timezone, ''), 'America/New_York');
    v_send := now();
    v_local := v_send AT TIME ZONE v_tz;
    IF v_local::time < time '09:00' THEN
      v_send := (date_trunc('day', v_local) + interval '9 hours') AT TIME ZONE v_tz;
    ELSIF v_local::time >= time '20:00' THEN
      v_send := (date_trunc('day', v_local) + interval '1 day 9 hours') AT TIME ZONE v_tz;
    END IF;
    v_body := left(ev.org_name, 40) || ': ' || CASE
      WHEN v_presale AND v_send < v_at THEN 'The list presale for ' || left(ev.name, 80) || ' is open now with code ' || v_code
      ELSE 'Tickets for ' || left(ev.name, 80) || ' are on sale now' END
      || ': {{app_url}}/event/' || ev.id::text
      || CASE WHEN v_presale AND v_send < v_at THEN '?code=' || v_code ELSE '' END || ' Reply STOP to opt out.';
    SELECT i.provider INTO v_prov FROM public.exos_org_integrations i
     WHERE i.org_id = ev.org_id AND i.provider IN ('twilio', 'telnyx') AND i.status = 'connected'
     ORDER BY (i.provider = 'twilio') DESC LIMIT 1;
    v_camp := NULL;

    FOR r IN
      WITH c AS (
        SELECT s.id FROM public.exos_drop_signups s
         WHERE s.event_id = ev.id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL AND s.blasted_at IS NULL
         ORDER BY s.confirmed_at, s.id
         LIMIT v_left
         FOR UPDATE SKIP LOCKED)
      UPDATE public.exos_drop_signups s SET blasted_at = now(), blast_kind = v_kind
        FROM c WHERE s.id = c.id AND s.blasted_at IS NULL
      RETURNING s.*
    LOOP
      v_left := v_left - 1;
      -- Email: an account that opted out of follow-up mail since gets none.
      IF r.user_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_mail_prefs mp
                                            WHERE mp.user_id = r.user_id AND mp.marketing_opt_out) THEN
        UPDATE public.exos_drop_signups SET blast_skip = 'opted_out' WHERE id = r.id;
      ELSE
        v_mail := public.exos_mail_enqueue('drop-on-sale', r.email,
          jsonb_build_object('org', jsonb_build_object('id', ev.org_id, 'name', ev.org_name),
                             'event', jsonb_build_object('id', ev.id, 'name', ev.name, 'starts_at', ev.starts_at,
                                                         'timezone', ev.timezone, 'venue_name', ev.venue_name,
                                                         'venue_location', ev.venue_location),
                             'kind', v_kind, 'code', v_code, 'on_sale_at', v_at, 'leave_token', r.leave_token),
          'drop-on-sale:' || r.id::text, r.user_id, false, NULL);
        IF v_mail IS NOT NULL THEN
          UPDATE public.exos_mail SET list_unsubscribe = '{{app_url}}/drop/leave?t=' || r.leave_token WHERE id = v_mail;
          v_mails := v_mails + 1;
        END IF;
        UPDATE public.exos_drop_signups
           SET blast_mail_id = v_mail, blast_skip = CASE WHEN v_mail IS NULL THEN 'no_address' END
         WHERE id = r.id;
      END IF;

      -- Text, when they opted in and still may get one.
      CONTINUE WHEN r.sms_phone IS NULL OR r.sms_opted_out_at IS NOT NULL;
      IF EXISTS (SELECT 1 FROM public.exos_sms_stops st
                  WHERE st.org_id = ev.org_id AND st.phone = r.sms_phone AND st.stopped_at >= r.sms_consented_at)
         OR EXISTS (SELECT 1 FROM public.exos_sms_subscribers sb
                     WHERE sb.org_id = ev.org_id AND sb.phone = r.sms_phone AND sb.opted_out_at >= r.sms_consented_at) THEN
        v_status := 'stopped';
      ELSIF v_prov IS NULL THEN
        v_status := 'no_provider';
      ELSIF (SELECT count(*) FROM public.exos_sms_outbox o
              WHERE o.org_id = ev.org_id AND o.phone = r.sms_phone
                AND o.status IN ('queued', 'sending', 'sent', 'dry_run')
                AND o.created_at > now() - interval '30 days') >= 8 THEN
        v_status := 'capped';
      ELSE
        IF v_camp IS NULL THEN
          SELECT c.id INTO v_camp FROM public.exos_sms_campaigns c
           WHERE c.org_id = ev.org_id AND c.event_id = ev.id AND c.audience = 'drop_list'
           ORDER BY c.created_at LIMIT 1;
          IF v_camp IS NULL THEN
            INSERT INTO public.exos_sms_campaigns (org_id, event_id, audience, body, provider, send_after, status)
            VALUES (ev.org_id, ev.id, 'drop_list', left(v_body, 480), v_prov, v_send, 'queued')
            RETURNING id INTO v_camp;
          END IF;
        END IF;
        IF (SELECT c.status FROM public.exos_sms_campaigns c WHERE c.id = v_camp) = 'cancelled' THEN
          v_status := 'cancelled';
        ELSE
          INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after)
          VALUES (v_camp, ev.org_id, r.sms_phone, left(v_body, 480), v_send)
          ON CONFLICT (campaign_id, phone) DO NOTHING;
          GET DIAGNOSTICS v_n = ROW_COUNT;
          IF v_n = 0 THEN
            v_status := 'duplicate';                 -- this number already has the text
          ELSE
            v_status := 'queued';
            v_texts := v_texts + 1;
            UPDATE public.exos_sms_campaigns
               SET status = 'queued', queued_count = queued_count + 1
             WHERE id = v_camp AND status <> 'cancelled';
          END IF;
        END IF;
      END IF;
      UPDATE public.exos_drop_signups SET sms_status = v_status WHERE id = r.id;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('mails', v_mails, 'texts', v_texts);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_list_blast(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_drop_list_blast(int) TO service_role;

-- Minimal data: unconfirmed signups go after 30 days, used / expired confirm
-- rows after 8, and a list 30 days after its event started.
CREATE OR REPLACE FUNCTION public.exos_drop_list_sweep()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_c int; v_s int; v_e int;
BEGIN
  DELETE FROM public.exos_drop_confirms WHERE created_at < now() - interval '8 days';
  GET DIAGNOSTICS v_c = ROW_COUNT;
  DELETE FROM public.exos_drop_signups WHERE confirmed_at IS NULL AND created_at < now() - interval '30 days';
  GET DIAGNOSTICS v_s = ROW_COUNT;
  DELETE FROM public.exos_drop_signups s USING public.exos_events e
   WHERE e.id = s.event_id AND e.starts_at < now() - interval '30 days';
  GET DIAGNOSTICS v_e = ROW_COUNT;
  RETURN jsonb_build_object('confirms', v_c, 'unconfirmed', v_s, 'past_events', v_e);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_list_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_drop_list_sweep() TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Mail templates + SMS audience
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['drop-confirm', 'drop-on-sale'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF v_def IS NULL THEN RETURN; END IF;
  IF strpos(v_def, '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live FROM regexp_matches(v_def, '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN RETURN; END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION SELECT unnest(v_new)) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_sms_campaigns'::regclass AND c.conname = 'exos_sms_campaigns_audience_check';
  IF strpos(coalesce(v_def, ''), 'drop_list') > 0 THEN RETURN; END IF;
  ALTER TABLE public.exos_sms_campaigns DROP CONSTRAINT IF EXISTS exos_sms_campaigns_audience_check;
  ALTER TABLE public.exos_sms_campaigns ADD CONSTRAINT exos_sms_campaigns_audience_check
    CHECK (audience IN ('org', 'event_buyers', 'staff_report', 'drop_list'));
END $$;

-- ---------------------------------------------------------------------------
-- 8. Cron: every 5 minutes, created INACTIVE (prod keeps Exos crons off).
--    Turn on with the mail drain (and exos-sms-drain for texts):
--    SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'exos-drop-list-blast-5min'), active := true);
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_job bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  EXECUTE 'SELECT jobid FROM cron.job WHERE jobname = $1' INTO v_job USING 'exos-drop-list-blast-5min';
  IF v_job IS NULL THEN
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job
      USING 'exos-drop-list-blast-5min', '*/5 * * * *',
            'SELECT public.exos_drop_list_blast(500); SELECT public.exos_drop_list_sweep();';
    EXECUTE 'SELECT cron.alter_job(job_id := $1, active := false)' USING v_job;
  END IF;
END $$;
