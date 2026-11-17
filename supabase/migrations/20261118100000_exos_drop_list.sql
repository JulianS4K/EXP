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
--   * SMS consent rules (mig 20261016120000): texts only for a signed-in fan,
--     and only for a number they PROVED: exos_drop_join texts a one-time
--     6-digit code to it (the guest-proof SMS path: exos_rsvp_sms_outbox,
--     drained by exos-sms-drain, dry run until EXOS_SMS_LIVE=on) and the
--     consent words are stored only when exos_drop_verify_sms gets that code
--     back. A STOP is a hard stop: any exos_sms_stops row for the number
--     (written by exos_sms_inbound, cleared only by START) or an opt-out on
--     exos_sms_subscribers blocks the text, at the blast AND in
--     exos_sms_claim (marker /* exos: drop list stop */, drop_list
--     campaigns only, so other audiences behave as before). 8 texts per
--     number per 30 days per org, 9:00-20:00 in the event's time zone (an
--     unknown zone falls back to America/New_York, the SMS default), from
--     the org's own Twilio / Telnyx through the existing outbox. The blast
--     queues one exos_sms_campaigns row per event (audience 'drop_list').
--   * The mail queue (exos_mail_enqueue): templates 'drop-confirm' and
--     'drop-on-sale', dedupe key per signup, List-Unsubscribe = the leave link.
--   * Presale: the existing machinery, a hidden ticket type unlocked by a code
--     (mig 20260925012000). The organizer picks a hidden type and N minutes;
--     Exos mints one voucher for it (valid until the public on-sale) and opens
--     that type N minutes early. exos_check_voucher (marker patch
--     /* exos: drop list code */) honours that code only for a confirmed list
--     member who confirmed BEFORE the presale opened (signups close when it
--     opens): a signed-in buyer whose account (or confirmed email) is on the
--     list, or, for the service role (exos-checkout), the verified email it
--     passes. Anonymous callers never pass (codes need an account already).
--     No new pricing path: the hidden type's own price applies.
--   * Tracking: the first-touch promoter code and UTM tags the visitor arrived
--     with (lib/attribution.ts), sanitized again here.
--
-- Touches:  C: TABLE exos_drop_signups, exos_drop_confirms, exos_drop_settings,
--              exos_drop_sms_codes, exos_drop_leave_tokens, exos_drop_sms_countries
--              (RLS on, no client grants: RPCs only)
--           C: FUNCTION exos_drop_status, exos_drop_signup, exos_drop_confirm,
--              exos_drop_confirm_code, exos_drop_leave (anon + authenticated);
--              exos_drop_set_sms_countries (owner; audited);
--              exos_drop_join, exos_drop_verify_sms, exos_drop_leave_mine
--              (authenticated);
--              exos_drop_list_summary (owner / manager / finance),
--              exos_drop_list_export, exos_drop_list_set_presale (owner /
--              manager; audited); exos_drop_list_blast, exos_drop_list_sweep
--              (service role); helpers _exos_drop_*
--           W: FUNCTION exos_check_voucher (marker /* exos: drop list code */),
--              exos_sms_claim (marker /* exos: drop list stop */)
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
  -- The address folded for rate limits (lower case, +tag dropped).
  email_key          text GENERATED ALWAYS AS (regexp_replace(email, '\+[^@]*@', '@')) STORED,
  -- A number waiting for its one-time code (exos_drop_verify_sms); only the
  -- code's hash. Nothing is consented until the code comes back.
  sms_pending_phone  text CHECK (sms_pending_phone IS NULL OR sms_pending_phone ~ '^\+[1-9][0-9]{7,14}$'),
  sms_code_hash      text CHECK (sms_code_hash IS NULL OR sms_code_hash ~ '^[0-9a-f]{64}$'),
  sms_code_at        timestamptz,
  sms_code_attempts  int NOT NULL DEFAULT 0 CHECK (sms_code_attempts >= 0),
  sms_code_sends     int NOT NULL DEFAULT 0 CHECK (sms_code_sends >= 0),
  left_at            timestamptz,
  -- The blast mail's leave link token, hashed (each confirm mail has its own,
  -- in exos_drop_leave_tokens).
  blast_leave_hash   text UNIQUE CHECK (blast_leave_hash IS NULL OR blast_leave_hash ~ '^[0-9a-f]{64}$'),
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
CREATE INDEX IF NOT EXISTS exos_drop_signups_key_idx ON public.exos_drop_signups (email_key);
CREATE INDEX IF NOT EXISTS exos_drop_signups_phone_idx ON public.exos_drop_signups (org_id, sms_phone) WHERE sms_phone IS NOT NULL;
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

-- The leave link of every confirm mail, hashed. Kept as long as the signup
-- (the sweep's 8-day cut of exos_drop_confirms doesn't touch it), so an old
-- mail's leave link always works.
CREATE TABLE IF NOT EXISTS public.exos_drop_leave_tokens (
  token_hash text PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  signup_id  uuid NOT NULL REFERENCES public.exos_drop_signups (id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_drop_leave_tokens_signup_idx ON public.exos_drop_leave_tokens (signup_id);
CREATE INDEX IF NOT EXISTS exos_drop_leave_tokens_org_idx ON public.exos_drop_leave_tokens (org_id);
ALTER TABLE public.exos_drop_leave_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_drop_leave_tokens FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_drop_leave_tokens TO service_role;

-- Every texted verification code (exos_drop_join), for its daily caps: per
-- account, per number, per org, and the numbers a signup tried. Two days kept.
CREATE TABLE IF NOT EXISTS public.exos_drop_sms_codes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  signup_id  uuid REFERENCES public.exos_drop_signups (id) ON DELETE SET NULL,
  phone      text NOT NULL CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  fails      int NOT NULL DEFAULT 0 CHECK (fails >= 0),          -- wrong codes typed for this send
  -- Sent to an account new to the org (no verified number or paid order with
  -- it before): those share 100 of the org's 300 a day.
  newcomer   boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_drop_sms_codes_user_idx ON public.exos_drop_sms_codes (user_id, created_at);
CREATE INDEX IF NOT EXISTS exos_drop_sms_codes_phone_idx ON public.exos_drop_sms_codes (phone, created_at);
CREATE INDEX IF NOT EXISTS exos_drop_sms_codes_org_idx ON public.exos_drop_sms_codes (org_id, created_at);
CREATE INDEX IF NOT EXISTS exos_drop_sms_codes_signup_idx ON public.exos_drop_sms_codes (signup_id);
CREATE INDEX IF NOT EXISTS exos_drop_sms_codes_new_idx ON public.exos_drop_sms_codes (created_at) WHERE newcomer;

-- Countries an org may text verification codes to beyond its own (owner
-- only, audited; exos_drop_set_sms_countries). ISO 3166-1 alpha-2 codes.
CREATE TABLE IF NOT EXISTS public.exos_drop_sms_countries (
  org_id     uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  countries  text[] NOT NULL DEFAULT '{}' CHECK (cardinality(countries) <= 30),
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_drop_sms_countries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_drop_sms_countries FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_drop_sms_countries TO service_role;
DROP TRIGGER IF EXISTS exos_drop_sms_countries_touch ON public.exos_drop_sms_countries;
CREATE TRIGGER exos_drop_sms_countries_touch BEFORE UPDATE ON public.exos_drop_sms_countries
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_drop_sms_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_drop_sms_codes FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_drop_sms_codes TO service_role;

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
-- not started, not on sale yet, and no list presale open yet.
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
           -- A list presale that has opened closes the list: only members who
           -- were on it before it opened may use its code.
           AND NOT EXISTS (SELECT 1 FROM public.exos_drop_settings ds
                            WHERE ds.event_id = e.id AND ds.presale_minutes IS NOT NULL
                              AND ds.public_on_sale_at = public._exos_drop_open_at(e.id)
                              AND ds.public_on_sale_at - make_interval(mins => ds.presale_minutes) <= now())
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
-- passes the verified account email; the JWT role must be exactly
-- service_role): that email. Anything else (anon, no claims): never. With a
-- list presale set, only members confirmed before it opened.
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
  v_cut   timestamptz := (SELECT ds.public_on_sale_at - make_interval(mins => ds.presale_minutes)
                            FROM public.exos_drop_settings ds
                           WHERE ds.event_id = p_event_id AND ds.presale_minutes IS NOT NULL);
BEGIN
  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
    RETURN EXISTS (SELECT 1 FROM public.exos_drop_signups s
                    WHERE s.event_id = p_event_id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL
                      AND (v_cut IS NULL OR s.confirmed_at <= v_cut)
                      AND (s.user_id = v_uid OR (v_email IS NOT NULL AND s.email = v_email)));
  END IF;
  IF v_role IS DISTINCT FROM 'service_role' THEN RETURN false; END IF;   -- fail closed
  v_email := public._exos_fan_email(p_email);
  RETURN v_email IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.exos_drop_signups s
     WHERE s.event_id = p_event_id AND s.email = v_email AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL
       AND (v_cut IS NULL OR s.confirmed_at <= v_cut));
END $$;
REVOKE ALL ON FUNCTION public._exos_drop_member(uuid, text) FROM PUBLIC, anon, authenticated;

-- An event's zone for quiet hours, if Postgres knows it; else the SMS
-- default (America/New_York, as exos_sms_create_campaign). An organizer-typed
-- zone never makes the blast raise.
CREATE OR REPLACE FUNCTION public._exos_drop_tz(p_tz text)
RETURNS text
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT z.name FROM pg_timezone_names z WHERE z.name = nullif(btrim(coalesce(p_tz, '')), '') LIMIT 1),
                  'America/New_York')
$$;
REVOKE ALL ON FUNCTION public._exos_drop_tz(text) FROM PUBLIC, anon, authenticated;

-- A 64-hex token and its hash.
CREATE OR REPLACE FUNCTION public._exos_drop_hash(p text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$ SELECT encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex') $$;
REVOKE ALL ON FUNCTION public._exos_drop_hash(text) FROM PUBLIC, anon, authenticated;

-- A mobile number as the drop list takes it: no extension or dial-string
-- characters (x, ext, ;, #, ",", any letter), E.164, and a +1 number must be
-- a real NANP one. exos_sms_normalize_phone itself is unchanged for its
-- other callers.
CREATE OR REPLACE FUNCTION public._exos_drop_phone(p_raw text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN coalesce(p_raw, '') ~ '[A-Za-z;#,]' THEN NULL
    WHEN n ~ '^\+1' AND n !~ '^\+1[2-9][0-9]{9}$' THEN NULL
    ELSE n END
    FROM (SELECT public.exos_sms_normalize_phone(p_raw) AS n) x
$$;
REVOKE ALL ON FUNCTION public._exos_drop_phone(text) FROM PUBLIC, anon, authenticated;

-- Country calling codes Exos texts verification codes to (ISO 3166-1
-- alpha-2). NANP countries share +1. Anything not here can't be texted.
CREATE OR REPLACE FUNCTION public._exos_drop_calling_code(p_iso text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE upper(btrim(coalesce(p_iso, '')))
    WHEN 'US' THEN '1' WHEN 'CA' THEN '1' WHEN 'PR' THEN '1' WHEN 'VI' THEN '1' WHEN 'GU' THEN '1'
    WHEN 'MP' THEN '1' WHEN 'AS' THEN '1'
    -- NANP countries outside US / CA: matched by area code (_exos_drop_nanp_iso), never by +1.
    WHEN 'BS' THEN '1' WHEN 'BB' THEN '1' WHEN 'AI' THEN '1' WHEN 'AG' THEN '1' WHEN 'VG' THEN '1'
    WHEN 'KY' THEN '1' WHEN 'BM' THEN '1' WHEN 'GD' THEN '1' WHEN 'TC' THEN '1' WHEN 'JM' THEN '1'
    WHEN 'MS' THEN '1' WHEN 'SX' THEN '1' WHEN 'LC' THEN '1' WHEN 'DM' THEN '1' WHEN 'VC' THEN '1'
    WHEN 'DO' THEN '1' WHEN 'TT' THEN '1' WHEN 'KN' THEN '1'
    WHEN 'GB' THEN '44' WHEN 'IE' THEN '353' WHEN 'FR' THEN '33' WHEN 'DE' THEN '49' WHEN 'ES' THEN '34'
    WHEN 'IT' THEN '39' WHEN 'NL' THEN '31' WHEN 'BE' THEN '32' WHEN 'PT' THEN '351' WHEN 'AT' THEN '43'
    WHEN 'CH' THEN '41' WHEN 'SE' THEN '46' WHEN 'NO' THEN '47' WHEN 'DK' THEN '45' WHEN 'FI' THEN '358'
    WHEN 'PL' THEN '48' WHEN 'AU' THEN '61' WHEN 'NZ' THEN '64' WHEN 'MX' THEN '52' WHEN 'BR' THEN '55'
    WHEN 'AR' THEN '54' WHEN 'CO' THEN '57' WHEN 'JP' THEN '81' WHEN 'KR' THEN '82' WHEN 'SG' THEN '65'
    WHEN 'IN' THEN '91' WHEN 'ZA' THEN '27' WHEN 'IL' THEN '972' WHEN 'AE' THEN '971'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_drop_calling_code(text) FROM PUBLIC, anon, authenticated;

-- The country of a +1 number by its area code, for the NANP members that
-- aren't the US / Canada (the classic SMS-pumping targets): their own
-- countries, which an owner must opt into. '900' (premium rate) is never
-- textable. NULL: US, Canada and the US territories (PR 787/939, VI 340,
-- GU 671, MP 670, AS 684), which count as the US group. From the NANPA
-- assignments as known 2026-11 (nationalnanpa.com wasn't reachable from the
-- build sandbox to re-check).
CREATE OR REPLACE FUNCTION public._exos_drop_nanp_iso(p_phone text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE substr(coalesce(p_phone, ''), 3, 3)
    WHEN '242' THEN 'BS' WHEN '246' THEN 'BB' WHEN '264' THEN 'AI' WHEN '268' THEN 'AG' WHEN '284' THEN 'VG'
    WHEN '345' THEN 'KY' WHEN '441' THEN 'BM' WHEN '473' THEN 'GD' WHEN '649' THEN 'TC' WHEN '658' THEN 'JM'
    WHEN '876' THEN 'JM' WHEN '664' THEN 'MS' WHEN '721' THEN 'SX' WHEN '758' THEN 'LC' WHEN '767' THEN 'DM'
    WHEN '784' THEN 'VC' WHEN '809' THEN 'DO' WHEN '829' THEN 'DO' WHEN '849' THEN 'DO' WHEN '868' THEN 'TT'
    WHEN '869' THEN 'KN' WHEN '900' THEN '900'
  END
  WHERE coalesce(p_phone, '') LIKE '+1%'
$$;
REVOKE ALL ON FUNCTION public._exos_drop_nanp_iso(text) FROM PUBLIC, anon, authenticated;

-- May this org text a code to this number? The org's own country (an org
-- with no country counts as US) plus the countries its owner allowed. A +1
-- number is placed by its area code: the US group (US, Canada and the US
-- territories, kept together) or one of the other NANP countries, each its
-- own opt-in; '900' never. Other numbers by calling-code prefix.
CREATE OR REPLACE FUNCTION public._exos_drop_phone_country_ok(p_org_id uuid, p_phone text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH allowed AS (
    SELECT upper(coalesce((SELECT o.country FROM public.exos_orgs o WHERE o.id = p_org_id), 'US')) AS iso
    UNION
    SELECT upper(c) FROM public.exos_drop_sms_countries a, unnest(a.countries) c WHERE a.org_id = p_org_id
  ), nanp AS (SELECT public._exos_drop_nanp_iso(p_phone) AS iso)
  SELECT CASE
    WHEN p_phone LIKE '+1%' THEN
      CASE WHEN (SELECT iso FROM nanp) = '900' THEN false
           WHEN (SELECT iso FROM nanp) IS NOT NULL THEN EXISTS (SELECT 1 FROM allowed a WHERE a.iso = (SELECT iso FROM nanp))
           ELSE EXISTS (SELECT 1 FROM allowed a WHERE a.iso IN ('US', 'CA', 'PR', 'VI', 'GU', 'MP', 'AS')) END
    ELSE EXISTS (SELECT 1 FROM allowed a
                  WHERE public._exos_drop_calling_code(a.iso) IS DISTINCT FROM '1'
                    AND public._exos_drop_calling_code(a.iso) IS NOT NULL
                    AND p_phone LIKE '+' || public._exos_drop_calling_code(a.iso) || '%')
  END
$$;
REVOKE ALL ON FUNCTION public._exos_drop_phone_country_ok(uuid, text) FROM PUBLIC, anon, authenticated;

-- Owner only (or admin): the extra countries the org's drop list may text
-- codes to. Every code must be one Exos texts (_exos_drop_calling_code).
CREATE OR REPLACE FUNCTION public.exos_drop_set_sms_countries(p_org_id uuid, p_countries text[])
RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_new text[]; v_old text[];
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner'])) THEN
    RAISE EXCEPTION 'exos_drop_set_sms_countries: owners only' USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(array_agg(DISTINCT upper(btrim(c)) ORDER BY upper(btrim(c))), '{}') INTO v_new
    FROM unnest(coalesce(p_countries, '{}'::text[])) c WHERE btrim(c) <> '';
  IF cardinality(v_new) > 30 OR EXISTS (SELECT 1 FROM unnest(v_new) c WHERE public._exos_drop_calling_code(c) IS NULL) THEN
    RAISE EXCEPTION 'exos_drop_set_sms_countries: pick up to 30 supported countries (ISO codes like GB)' USING ERRCODE = '22023';
  END IF;
  SELECT countries INTO v_old FROM public.exos_drop_sms_countries WHERE org_id = p_org_id FOR UPDATE;
  INSERT INTO public.exos_drop_sms_countries AS x (org_id, countries, updated_by) VALUES (p_org_id, v_new, auth.uid())
  ON CONFLICT (org_id) DO UPDATE SET countries = EXCLUDED.countries, updated_by = EXCLUDED.updated_by;
  /* exos: audit drop_list.sms_countries_set */
  PERFORM public._exos_audit(p_org_id, 'drop_list.sms_countries_set', 'org', p_org_id::text, NULL,
    jsonb_build_object('sms_countries', jsonb_build_array(array_to_string(v_old, ','), array_to_string(v_new, ','))));
  RETURN v_new;
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_set_sms_countries(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_drop_set_sms_countries(uuid, text[]) TO authenticated, service_role;

-- May this number get the drop-list text for this org? A hard stop: any
-- STOP on record (exos_sms_stops, until START deletes it) or an opt-out on
-- the org's subscriber row.
CREATE OR REPLACE FUNCTION public._exos_drop_phone_stopped(p_org_id uuid, p_phone text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_sms_stops st WHERE st.org_id = p_org_id AND st.phone = p_phone)
      OR EXISTS (SELECT 1 FROM public.exos_sms_subscribers sb
                  WHERE sb.org_id = p_org_id AND sb.phone = p_phone AND sb.opted_out_at IS NOT NULL)
$$;
REVOKE ALL ON FUNCTION public._exos_drop_phone_stopped(uuid, text) FROM PUBLIC, anon, authenticated;

-- exos_sms_claim's last check for a queued drop_list text: skip it when the
-- number is stopped, or no signup of that event still consents with it
-- (left, opted out). Other audiences: false (unchanged).
CREATE OR REPLACE FUNCTION public._exos_drop_sms_blocked(p_campaign_id uuid, p_org_id uuid, p_phone text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT public._exos_drop_phone_stopped(p_org_id, p_phone)
           OR NOT EXISTS (SELECT 1 FROM public.exos_drop_signups s
                           WHERE s.event_id = c.event_id AND s.sms_phone = p_phone
                             AND s.left_at IS NULL AND s.sms_opted_out_at IS NULL)
      FROM public.exos_sms_campaigns c WHERE c.id = p_campaign_id AND c.audience = 'drop_list'), false)
$$;
REVOKE ALL ON FUNCTION public._exos_drop_sms_blocked(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

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
        'phone_hint', CASE WHEN s.sms_phone IS NOT NULL THEN '…' || right(s.sms_phone, 4) END,
        -- A number waiting for its code (nothing consented yet).
        'sms_pending', s.sms_pending_phone IS NOT NULL AND s.left_at IS NULL,
        'pending_hint', CASE WHEN s.sms_pending_phone IS NOT NULL THEN '…' || right(s.sms_pending_phone, 4) END);
    ELSE
      v_out := v_out || jsonb_build_object('joined', false, 'sms', false);
    END IF;
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_status(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_status(uuid) TO anon, authenticated, service_role;

-- A guest's signup (anon or signed in). For a well-formed request to an
-- open list it answers {ok, status: 'check_email'} whether the address is
-- new, pending, already on the list, or held back by a per-address limit:
-- nothing says who is on a list. A confirm mail (link + 6-digit code +
-- leave link) goes out unless the address is already listed or over its
-- limits. Limits, before any work: 10 a minute per network; 5 a minute per
-- address (folded: lower case, +tag dropped); 120 a minute per event, which
-- answers {ok: false, status: 'try_again'} (per event, so it says nothing
-- about an address); then 3 confirm mails a day per address and event and
-- 10 a day per address across events.
CREATE OR REPLACE FUNCTION public.exos_drop_signup(
  p_event_id uuid, p_email text, p_browser_token text, p_source jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ok     constant jsonb := jsonb_build_object('ok', true, 'status', 'check_email');
  v_email  text := public._exos_fan_email(p_email);
  v_key    text;
  v_src    jsonb := CASE WHEN jsonb_typeof(p_source) = 'object' THEN p_source ELSE '{}'::jsonb END;
  e        record;
  s        public.exos_drop_signups%ROWTYPE;
  v_cid    uuid := gen_random_uuid();
  v_token  text;
  v_leave  text;
  v_code   text;
BEGIN
  IF NOT public.exos_rate_hit('drop-ip:' || md5(public._exos_request_ip_bucket()), 10) THEN
    RETURN v_ok;
  END IF;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'exos_drop_signup: enter a valid email address' USING ERRCODE = '22023';
  END IF;
  v_key := regexp_replace(v_email, '\+[^@]*@', '@');
  IF coalesce(p_browser_token, '') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'exos_drop_signup: reload the page and try again' USING ERRCODE = '22023';
  END IF;
  IF NOT public._exos_drop_open(p_event_id) THEN
    RAISE EXCEPTION 'exos_drop_signup: this event isn''t taking signups' USING ERRCODE = 'P0002';
  END IF;
  IF NOT public.exos_rate_hit('drop-em:' || md5(v_key), 5) THEN
    RETURN v_ok;
  END IF;
  IF NOT public.exos_rate_hit('drop-ev:' || p_event_id::text, 120) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'try_again');
  END IF;
  SELECT ev.id, ev.org_id, ev.name, ev.starts_at, ev.timezone, ev.venue_name, ev.venue_location, o.name AS org_name
    INTO e FROM public.exos_events ev JOIN public.exos_orgs o ON o.id = ev.org_id WHERE ev.id = p_event_id;

  PERFORM pg_advisory_xact_lock(hashtextextended('exos_drop:' || p_event_id::text || ':' || v_email, 0));
  SELECT * INTO s FROM public.exos_drop_signups WHERE event_id = p_event_id AND email = v_email FOR UPDATE;
  IF s.id IS NOT NULL AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL THEN
    RETURN v_ok;                                   -- already on the list: nothing to send
  END IF;
  -- 10 confirm mails a day per (folded) address across every list.
  IF (SELECT count(*) FROM public.exos_drop_confirms c JOIN public.exos_drop_signups x ON x.id = c.signup_id
       WHERE x.email_key = v_key AND c.created_at > now() - interval '1 day') >= 10 THEN
    RETURN v_ok;
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
  v_leave := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_code  := public._exos_proof_code();
  INSERT INTO public.exos_drop_confirms (id, signup_id, org_id, token_hash, code_hash, browser_token_hash)
  VALUES (v_cid, s.id, s.org_id, public._exos_drop_hash(v_token), public._exos_proof_hash(v_cid, 'drop', v_code),
          public._exos_drop_hash(p_browser_token));
  INSERT INTO public.exos_drop_leave_tokens (token_hash, signup_id, org_id) VALUES (public._exos_drop_hash(v_leave), s.id, s.org_id);
  PERFORM public.exos_mail_enqueue('drop-confirm', v_email,
    jsonb_build_object('org', jsonb_build_object('id', e.org_id, 'name', e.org_name),
                       'event', jsonb_build_object('id', e.id, 'name', e.name, 'starts_at', e.starts_at,
                                                   'timezone', e.timezone, 'venue_name', e.venue_name,
                                                   'venue_location', e.venue_location),
                       'token', v_token, 'code', v_code, 'leave_token', v_leave),
    'drop-confirm:' || v_cid::text, NULL, false, NULL);
  RETURN v_ok;
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_signup(uuid, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_signup(uuid, text, text, jsonb) TO anon, authenticated, service_role;

-- Mark a signup confirmed (the person proved the address with a confirm
-- made at p_since). A confirm made before the person left never re-joins
-- them: leaving spends the open confirms, and this refuses an older one.
CREATE OR REPLACE FUNCTION public._exos_drop_confirm_signup(p_signup_id uuid, p_since timestamptz)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_drop_signups
     SET confirmed_at = CASE WHEN confirmed_at IS NULL OR left_at IS NOT NULL THEN now() ELSE confirmed_at END,
         left_at = NULL
   WHERE id = p_signup_id AND (left_at IS NULL OR left_at <= p_since);
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public._exos_drop_confirm_signup(uuid, timestamptz) FROM PUBLIC, anon, authenticated;

-- The mail's link (anon; the page takes a click so a mail scanner confirms
-- nothing). Answers the event and org name only. A link already used
-- answers ok only while that signup is still on the list.
CREATE OR REPLACE FUNCTION public.exos_drop_confirm(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_drop_confirms%ROWTYPE; v_ok boolean; v_ev uuid; v_name text; v_org text;
BEGIN
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('ok', false); END IF;
  SELECT * INTO c FROM public.exos_drop_confirms
   WHERE token_hash = public._exos_drop_hash(p_token) AND created_at > now() - interval '7 days'
   FOR UPDATE;
  IF c.id IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  IF c.used_at IS NULL THEN
    UPDATE public.exos_drop_confirms SET used_at = now() WHERE id = c.id;
    v_ok := public._exos_drop_confirm_signup(c.signup_id, c.created_at);
  ELSE
    v_ok := EXISTS (SELECT 1 FROM public.exos_drop_signups s
                     WHERE s.id = c.signup_id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL);
  END IF;
  IF NOT v_ok THEN RETURN jsonb_build_object('ok', false); END IF;
  SELECT e.id, e.name, o.name INTO v_ev, v_name, v_org
    FROM public.exos_drop_signups s JOIN public.exos_events e ON e.id = s.event_id JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE s.id = c.signup_id;
  RETURN jsonb_build_object('ok', true, 'event_id', v_ev, 'event_name', v_name, 'org_name', v_org);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_confirm(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_confirm(text) TO anon, authenticated, service_role;

-- The 6-digit code, typed on the page the guest signed up on (its browser
-- token gates it). 5 wrong tries spend the code; 20 tries a minute per
-- network. Answers only {ok}: the same false for a wrong code, a spent one,
-- one made before the person left, or no signup from this browser.
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
   WHERE c2.browser_token_hash = public._exos_drop_hash(p_browser_token)
     AND c2.used_at IS NULL AND c2.attempts < 5 AND c2.created_at > now() - interval '1 day'
   ORDER BY c2.created_at DESC LIMIT 1
   FOR UPDATE OF c2;
  IF c.id IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  IF c.code_hash <> public._exos_proof_hash(c.id, 'drop', v_code) THEN
    UPDATE public.exos_drop_confirms SET attempts = attempts + 1 WHERE id = c.id;
    RETURN jsonb_build_object('ok', false);
  END IF;
  UPDATE public.exos_drop_confirms SET used_at = now() WHERE id = c.id;
  RETURN jsonb_build_object('ok', public._exos_drop_confirm_signup(c.signup_id, c.created_at));
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_confirm_code(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_confirm_code(uuid, text, text) TO anon, authenticated, service_role;

-- One click for a signed-in fan with a confirmed email (it is their proof).
-- Texts: never stored on the word of the form. A number gets a one-time
-- 6-digit code by text (exos_rsvp_sms_outbox, the guest-proof SMS path;
-- dry run until EXOS_SMS_LIVE=on); only exos_drop_verify_sms with that code
-- stores the consent. Code limits (SMS pumping), every one checked before
-- the outbox under per-account, per-org and per-number locks, over actual
-- sends logged in exos_drop_sms_codes: 5 a day per account, 5 a day per
-- number (all accounts and orgs), 300 a day per org of which accounts new to
-- the org (no verified number or paid order with it) share 100, and 2,000
-- newcomer sends a day platform-wide (exos_platform_settings
-- drop_sms_codes_daily_cap). The platform cap counts and blocks newcomers
-- only: an org's established accounts (a proved number or paid order with
-- it) are never stopped by other orgs, and with 100 newcomers per org at
-- most, filling it takes 20 orgs' worth of new accounts. The trade-off: on
-- such a day new accounts everywhere wait. 3 per
-- number per 10
-- minutes (shared with the order proofs), 60 s apart and 5 in all per
-- signup, at most 2 different numbers per signup (the second replaces the
-- first), and no new code to a number with 10 wrong codes typed in a day
-- across signups. Over any of them: sms_code 'try_again', the same whichever
-- cap. Quiet hours don't apply to the code: the person asked for it on the
-- page that very moment and it works for 10 minutes, so a held code is
-- useless (user-requested one-time codes are exempt in the usual practice,
-- as are the order-proof codes on the same outbox).
-- Numbers: no extensions or dial strings, a real NANP number for +1, and
-- only the org's own country (+1 for US / CA / US territories; the other
-- NANP countries, by area code, are their own opt-in; 900 never) unless its
-- owner allowed more
-- (exos_drop_set_sms_countries, audited); others: "texts aren't available
-- for this number" before anything is logged or sent.
-- A number that replied STOP gets no text but counts as a send and answers
-- 'sent' (so the answer doesn't reveal a STOP). 10 joins a minute per account.
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
  v_code  text;
  v_new   boolean;
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
    v_phone := public._exos_drop_phone(p_phone);
    IF v_phone IS NULL THEN
      RAISE EXCEPTION 'exos_drop_join: enter a mobile number, e.g. +1 212 555 0100 (no extension)' USING ERRCODE = '22023';
    END IF;
  END IF;
  SELECT ev.id, ev.org_id, ev.name, o.name AS org_name INTO e
    FROM public.exos_events ev JOIN public.exos_orgs o ON o.id = ev.org_id WHERE ev.id = p_event_id;
  -- Only the org's own country (and the ones its owner allowed): no codes to
  -- premium or far-away numbers. Before anything is logged or sent.
  IF v_phone IS NOT NULL AND NOT public._exos_drop_phone_country_ok(e.org_id, v_phone) THEN
    RAISE EXCEPTION 'exos_drop_join: texts aren''t available for this number' USING ERRCODE = '22023';
  END IF;

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
  -- A join is the person's own act: confirms still open for this signup are spent.
  UPDATE public.exos_drop_confirms SET used_at = now() WHERE signup_id = s.id AND used_at IS NULL;

  -- A new number, or the same one after leaving (its consent ended): a code.
  IF v_phone IS NOT NULL AND (v_phone IS DISTINCT FROM s.sms_phone OR s.sms_opted_out_at IS NOT NULL) THEN
    -- Locks in one order (account, org, number), then every cap, then send.
    PERFORM pg_advisory_xact_lock(hashtextextended('exos-drop-smscode-acct:' || v_uid::text, 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('exos-drop-smscode-org:' || e.org_id::text, 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('exos-proof-phone:' || v_phone, 0));
    SELECT * INTO s FROM public.exos_drop_signups WHERE id = s.id;
    -- New to the org: no verified number and no paid order with it before.
    v_new := NOT EXISTS (SELECT 1 FROM public.exos_drop_signups x
                          WHERE x.org_id = e.org_id AND x.user_id = v_uid AND x.sms_consented_at IS NOT NULL)
         AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs
                          WHERE cs.org_id = e.org_id AND cs.buyer_uid = v_uid
                            AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded'));
    IF (s.sms_code_at IS NOT NULL AND s.sms_code_at >= now() - interval '60 seconds')
       OR s.sms_code_sends >= 5
       OR (NOT EXISTS (SELECT 1 FROM public.exos_drop_sms_codes l WHERE l.signup_id = s.id AND l.phone = v_phone)
           AND (SELECT count(DISTINCT l.phone) FROM public.exos_drop_sms_codes l WHERE l.signup_id = s.id) >= 2)
       OR (SELECT count(*) FROM public.exos_drop_sms_codes l
            WHERE l.user_id = v_uid AND l.created_at > now() - interval '1 day') >= 5
       OR (SELECT count(*) FROM public.exos_drop_sms_codes l
            WHERE l.phone = v_phone AND l.created_at > now() - interval '1 day') >= 5
       OR (SELECT coalesce(sum(l.fails), 0) FROM public.exos_drop_sms_codes l
            WHERE l.phone = v_phone AND l.created_at > now() - interval '1 day') >= 10
       OR (SELECT count(*) FROM public.exos_drop_sms_codes l
            WHERE l.org_id = e.org_id AND l.created_at > now() - interval '1 day') >= 300
       OR (v_new AND (SELECT count(*) FROM public.exos_drop_sms_codes l
                       WHERE l.org_id = e.org_id AND l.newcomer AND l.created_at > now() - interval '1 day') >= 100)
       -- Platform-wide, newcomers only: exos_platform_settings drop_sms_codes_daily_cap
       -- (2,000 by default). Established accounts never hit it, so orgs filling it
       -- can't stop anyone's regulars; each org's newcomers take at most 100 of it.
       OR (v_new AND (SELECT count(*) FROM public.exos_drop_sms_codes l WHERE l.newcomer AND l.created_at > now() - interval '1 day')
          >= coalesce((SELECT (ps.value #>> '{}')::int FROM public.exos_platform_settings ps
                        WHERE ps.key = 'drop_sms_codes_daily_cap' AND jsonb_typeof(ps.value) = 'number'), 2000))
       OR (SELECT count(*) FROM public.exos_rsvp_sms_outbox o
            WHERE o.phone = v_phone AND o.created_at > now() - interval '10 minutes') >= 3 THEN
      RETURN public.exos_drop_status(p_event_id) || jsonb_build_object('sms_code', 'try_again');
    END IF;
    v_code := public._exos_proof_code();
    INSERT INTO public.exos_drop_sms_codes (user_id, org_id, signup_id, phone, newcomer) VALUES (v_uid, e.org_id, s.id, v_phone, v_new);
    UPDATE public.exos_drop_signups
       SET sms_pending_phone = v_phone, sms_code_hash = public._exos_proof_hash(id, 'drop_sms', v_code),
           sms_code_at = now(), sms_code_attempts = 0, sms_code_sends = sms_code_sends + 1
     WHERE id = s.id;
    IF NOT public._exos_drop_phone_stopped(e.org_id, v_phone) THEN
      INSERT INTO public.exos_rsvp_sms_outbox (org_id, phone, body)
      VALUES (e.org_id, v_phone, v_code || ' is your code to get one text when tickets for '
              || left(coalesce(e.name, 'the event'), 60) || ' go on sale. It works for 10 minutes. Don''t share it.');
    END IF;
    RETURN public.exos_drop_status(p_event_id) || jsonb_build_object('sms_code', 'sent');
  END IF;
  RETURN public.exos_drop_status(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_join(uuid, boolean, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_drop_join(uuid, boolean, text, jsonb) TO authenticated, service_role;

-- The code texted by exos_drop_join: only now are the number and the consent
-- words stored. 10 minutes, 5 tries; signed in, the caller's own signup.
CREATE OR REPLACE FUNCTION public.exos_drop_verify_sms(p_event_id uuid, p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); s public.exos_drop_signups%ROWTYPE; v_code text := btrim(coalesce(p_code, ''));
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'exos_drop_verify_sms: sign in first' USING ERRCODE = '42501'; END IF;
  IF NOT public.exos_rate_hit('drop-smsv:' || v_uid::text, 10) THEN
    RAISE EXCEPTION 'exos_drop_verify_sms: too many tries, wait a minute' USING ERRCODE = '54000';
  END IF;
  SELECT * INTO s FROM public.exos_drop_signups
   WHERE event_id = p_event_id AND user_id = v_uid AND left_at IS NULL AND sms_pending_phone IS NOT NULL
   FOR UPDATE;
  IF s.id IS NULL OR s.sms_code_at < now() - interval '10 minutes' OR s.sms_code_attempts >= 5 OR v_code !~ '^[0-9]{6}$' THEN
    RETURN public.exos_drop_status(p_event_id) || jsonb_build_object('verified', false);
  END IF;
  IF s.sms_code_hash <> public._exos_proof_hash(s.id, 'drop_sms', v_code) THEN
    UPDATE public.exos_drop_signups SET sms_code_attempts = sms_code_attempts + 1 WHERE id = s.id;
    -- Counted per number too: 10 wrong codes in a day across signups stop new codes to it.
    UPDATE public.exos_drop_sms_codes l SET fails = l.fails + 1
     WHERE l.id = (SELECT l2.id FROM public.exos_drop_sms_codes l2
                    WHERE l2.signup_id = s.id AND l2.phone = s.sms_pending_phone ORDER BY l2.created_at DESC LIMIT 1);
    RETURN public.exos_drop_status(p_event_id) || jsonb_build_object('verified', false);
  END IF;
  UPDATE public.exos_drop_signups x
     SET sms_phone = x.sms_pending_phone,
         sms_consent_text = public.exos_drop_sms_consent_text(o.name, e.name),
         sms_consented_at = now(), sms_opted_out_at = NULL,
         sms_pending_phone = NULL, sms_code_hash = NULL, sms_code_attempts = 0
    FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE x.id = s.id AND e.id = x.event_id;
  RETURN public.exos_drop_status(p_event_id) || jsonb_build_object('verified', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_verify_sms(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_drop_verify_sms(uuid, text) TO authenticated, service_role;

-- Leaving (email and texts). The signup's open confirms are spent FIRST
-- (the same lock order as a confirm: confirm row, then signup), so an
-- unused link or code can't re-join the person afterwards.
CREATE OR REPLACE FUNCTION public._exos_drop_leave_signups(p_ids uuid[])
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  UPDATE public.exos_drop_confirms SET used_at = now() WHERE signup_id = ANY (p_ids) AND used_at IS NULL;
  UPDATE public.exos_drop_signups
     SET left_at = coalesce(left_at, now()),
         sms_opted_out_at = CASE WHEN sms_phone IS NOT NULL THEN coalesce(sms_opted_out_at, now()) END,
         sms_pending_phone = NULL, sms_code_hash = NULL
   WHERE id = ANY (p_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_drop_leave_signups(uuid[]) FROM PUBLIC, anon, authenticated;

-- Leave by a mail's link (anon, 64-hex; only hashes are stored).
CREATE OR REPLACE FUNCTION public.exos_drop_leave(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_sid uuid; v_h text;
BEGIN
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('ok', false); END IF;
  v_h := public._exos_drop_hash(p_token);
  SELECT coalesce((SELECT lt.signup_id FROM public.exos_drop_leave_tokens lt WHERE lt.token_hash = v_h),
                  (SELECT s.id FROM public.exos_drop_signups s WHERE s.blast_leave_hash = v_h)) INTO v_sid;
  IF v_sid IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  PERFORM public._exos_drop_leave_signups(ARRAY[v_sid]);
  RETURN jsonb_build_object('ok', true, 'event_name',
    (SELECT e.name FROM public.exos_drop_signups s JOIN public.exos_events e ON e.id = s.event_id WHERE s.id = v_sid));
END $$;
REVOKE ALL ON FUNCTION public.exos_drop_leave(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_drop_leave(text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_drop_leave_mine(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_email text; v_ids uuid[];
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'exos_drop_leave_mine: sign in first' USING ERRCODE = '42501'; END IF;
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
  SELECT array_agg(s.id) INTO v_ids FROM public.exos_drop_signups s
   WHERE s.event_id = p_event_id AND (s.user_id = v_uid OR (v_email IS NOT NULL AND s.email = v_email));
  RETURN coalesce(public._exos_drop_leave_signups(coalesce(v_ids, '{}'::uuid[])), 0) > 0;
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
    -- The code is for owners / managers (finance sees that a presale is set).
    'presale', CASE WHEN public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])
                    THEN public._exos_drop_presale(p_event_id)
                    ELSE public._exos_drop_presale(p_event_id) - 'code' END,
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

-- exos_sms_claim: a queued drop_list text is skipped at send time when the
-- number has any STOP on record or its signup no longer consents. Other
-- audiences: the same test as before (subscriber opt-out only).
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.exos_sms_claim(integer)'::regprocedure);
  v_old text := '     AND EXISTS (SELECT 1 FROM public.exos_sms_subscribers s
                  WHERE s.org_id = o.org_id AND s.phone = o.phone AND s.opted_out_at IS NOT NULL);';
  v_new text := '     AND (EXISTS (SELECT 1 FROM public.exos_sms_subscribers s
                  WHERE s.org_id = o.org_id AND s.phone = o.phone AND s.opted_out_at IS NOT NULL)
          /* exos: drop list stop */ OR public._exos_drop_sms_blocked(o.campaign_id, o.org_id, o.phone));';
BEGIN
  IF position('/* exos: drop list stop */' in v_def) > 0 THEN RETURN; END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'exos_sms_claim: expected one subscriber opt-out check';
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
-- (audience 'drop_list'), consent re-checked (opted out, any STOP on record,
-- 8 a month, the org's provider connected), 9:00-20:00 in the event's zone
-- (_exos_drop_tz: an unknown zone falls back to America/New_York); a presale
-- text that quiet hours push past the public on-sale says "on sale" instead.
-- Each event runs in its own subtransaction: one that fails is skipped (a
-- WARNING, counted in failed_events) and retried next run.
CREATE OR REPLACE FUNCTION public.exos_drop_list_blast(p_limit int DEFAULT 500)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_left    int := greatest(1, least(coalesce(p_limit, 500), 5000));
  v_mails   int := 0;
  v_texts   int := 0;
  v_errors  int := 0;
  s_left    int;
  s_mails   int;
  s_texts   int;
  ev        record;
  r         record;
  v_at      timestamptz;
  ps        jsonb;
  v_presale boolean;
  v_opens   timestamptz;
  v_kind    text;
  v_code    text;
  v_mail    uuid;
  v_leave   text;
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
    s_left := v_left; s_mails := v_mails; s_texts := v_texts;
    -- One event at a time: a failure (anything) rolls back that event only
    -- and the others still go out.
    BEGIN
      -- The lock first, then the presale settings (exos_drop_list_set_presale
      -- takes the same lock), so a presale change can't slip in between.
      PERFORM pg_advisory_xact_lock(hashtextextended('exos_drop_blast:' || ev.id::text, 0));
      v_at := public._exos_drop_open_at(ev.id);
      CONTINUE WHEN v_at IS NULL;
      ps := public._exos_drop_presale(ev.id);
      v_presale := ps ->> 'status' = 'set';
      v_opens := CASE WHEN v_presale THEN v_at - make_interval(mins => (ps ->> 'minutes')::int) END;
      CONTINUE WHEN now() < coalesce(v_opens, v_at);
      IF v_presale AND now() >= v_at THEN v_presale := false; END IF;   -- presale over: plain on-sale
      v_kind := CASE WHEN v_presale THEN 'presale' ELSE 'on_sale' END;
      v_code := CASE WHEN v_presale THEN ps ->> 'code' END;

      v_tz := public._exos_drop_tz(ev.timezone);
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

      -- During the presale only members confirmed before it opened (the code
      -- works for them only); the rest wait for the public on-sale.
      FOR r IN
        WITH c AS (
          SELECT s.id FROM public.exos_drop_signups s
           WHERE s.event_id = ev.id AND s.confirmed_at IS NOT NULL AND s.left_at IS NULL AND s.blasted_at IS NULL
             AND (NOT v_presale OR s.confirmed_at <= v_opens)
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
          v_leave := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
          v_mail := public.exos_mail_enqueue('drop-on-sale', r.email,
            jsonb_build_object('org', jsonb_build_object('id', ev.org_id, 'name', ev.org_name),
                               'event', jsonb_build_object('id', ev.id, 'name', ev.name, 'starts_at', ev.starts_at,
                                                           'timezone', ev.timezone, 'venue_name', ev.venue_name,
                                                           'venue_location', ev.venue_location),
                               'kind', v_kind, 'code', v_code, 'on_sale_at', v_at, 'leave_token', v_leave),
            'drop-on-sale:' || r.id::text, r.user_id, false, NULL);
          IF v_mail IS NOT NULL THEN
            UPDATE public.exos_mail SET list_unsubscribe = '{{app_url}}/drop/leave?t=' || v_leave WHERE id = v_mail;
            v_mails := v_mails + 1;
          END IF;
          UPDATE public.exos_drop_signups
             SET blast_mail_id = v_mail, blast_skip = CASE WHEN v_mail IS NULL THEN 'no_address' END,
                 blast_leave_hash = CASE WHEN v_mail IS NOT NULL THEN public._exos_drop_hash(v_leave) END
           WHERE id = r.id;
        END IF;

        -- Text, when they proved the number and still may get one.
        CONTINUE WHEN r.sms_phone IS NULL OR r.sms_opted_out_at IS NOT NULL;
        IF public._exos_drop_phone_stopped(ev.org_id, r.sms_phone) THEN
          v_status := 'stopped';                    -- any STOP on record, until START
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
    EXCEPTION WHEN others THEN
      v_left := s_left; v_mails := s_mails; v_texts := s_texts; v_errors := v_errors + 1;
      RAISE WARNING 'exos_drop_list_blast: event %: % (%)', ev.id, SQLERRM, SQLSTATE;
    END;
  END LOOP;
  RETURN jsonb_build_object('mails', v_mails, 'texts', v_texts)
         || CASE WHEN v_errors > 0 THEN jsonb_build_object('failed_events', v_errors) ELSE '{}'::jsonb END;
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
  DELETE FROM public.exos_drop_sms_codes WHERE created_at < now() - interval '2 days';
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

-- Add 'drop_list' to whatever the audience check allows now (read live).
DO $$
DECLARE v_def text; v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_sms_campaigns'::regclass AND c.conname = 'exos_sms_campaigns_audience_check';
  IF v_def IS NULL THEN RETURN; END IF;
  SELECT array_agg(m[1]) INTO v_vals FROM regexp_matches(v_def, '''([^'']+)''', 'g') AS m;
  IF 'drop_list' = ANY (coalesce(v_vals, '{}'::text[])) THEN RETURN; END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM unnest(coalesce(v_vals, '{}'::text[]) || 'drop_list'::text) x;
  ALTER TABLE public.exos_sms_campaigns DROP CONSTRAINT exos_sms_campaigns_audience_check;
  EXECUTE format('ALTER TABLE public.exos_sms_campaigns ADD CONSTRAINT exos_sms_campaigns_audience_check CHECK (audience = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
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
