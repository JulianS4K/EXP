-- ============================================================================
-- Migration 20260930101000 — Exos (Bridge / D4): hashed customer-list export
--                            for custom audiences (Meta, Google Customer
--                            Match, TikTok)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_audience_exports (new; the export log, RLS)
--           C: FUNCTION exos_org_audience_export(uuid, uuid) (new, owner /
--              manager)
--           R: exos_checkout_sessions (buyer_email, buyer_uid,
--              consent_marketing, status), exos_mail_prefs,
--              auth.users (email, phone), exos_events, exos_has_org_role,
--              exos_rate_hit (when present, mig 20260929060000)
-- Pre-reqs: 20260929131000 (consent_marketing on the checkout session),
--           20260926060000 (exos_mail_prefs), 20260520140000 (follows).
--
-- Marketing audit build list #10. Organizers upload a list of their buyers
-- to Meta / Google / TikTok to build a custom (or lookalike) audience. The
-- export returns ONLY SHA-256 hashes, never an email or a phone number, as
-- one jsonb {count, generated_at, rows: [{email_sha256, phone_sha256,
-- phone_digits_sha256}]} (one value, so PostgREST's max-rows cap can't
-- silently cut a big list):
--   * email_sha256: sha256(lower(trim(email))), hex. For a guest checkout the
--     email on the session; for a signed-in buyer the session email, else
--     their account email.
--   * phone_sha256: sha256 of the E.164 number with the "+" ("+15551234567"),
--     what Google Customer Match and TikTok want; phone_digits_sha256: the
--     same digits without "+" ("15551234567"), what Meta wants. Only signed-
--     in buyers with a phone on their account have one (checkout collects no
--     phone); otherwise NULL.
--
-- Who is on the list (per org; p_event_id narrows it to that event's buyers):
--   buyers with a fulfilled (or partly refunded) order from this org who
--   granted advertising consent at checkout
--   (exos_checkout_sessions.consent_marketing = 'granted'). Following the
--   org is NOT ad consent (it opts into the org's emails only; operator
--   decision 2026-09-30: uploading to ad platforms needs the explicit
--   advertising choice);
--   and whose LATEST recorded consent choice at this org's checkouts is not
--   'denied' (the most recent choice wins, so a later "no" removes an
--   earlier "yes").
-- Always excluded:
--   * anyone who unsubscribed from marketing mail (exos_mail_prefs.
--     marketing_opt_out), matched by account or by the account's email, so
--     a guest checkout with an opted-out account's address is dropped too;
--   * deleted accounts (exos_delete_my_account tombstones the login as
--     deleted+<uid>@deleted.invalid and nulls the session email), and
--     orders whose account no longer exists.
--
-- Guard rails: owner / manager of the org only (not finance, not platform
-- admins by role alone); every export is logged in exos_audience_exports
-- (who, when, org, event, row count) readable by the org's owners /
-- managers; at most 3 a minute (exos_rate_hit, when installed) and 20 a day
-- per org.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded policy).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Export log
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_audience_exports (
  id          bigserial PRIMARY KEY,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id    uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  exported_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  row_count   integer NOT NULL CHECK (row_count >= 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_audience_exports_org_idx ON public.exos_audience_exports (org_id, created_at DESC);
COMMENT ON TABLE public.exos_audience_exports IS
  'One row per hashed customer-list export (exos_org_audience_export): who, when, which org / event, how many rows. No hashes stored. mig 20260930101000.';

ALTER TABLE public.exos_audience_exports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_audience_exports FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_audience_exports TO authenticated;
GRANT ALL ON public.exos_audience_exports TO service_role;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'exos_audience_exports_sel'
                   AND polrelid = 'public.exos_audience_exports'::regclass) THEN
    CREATE POLICY exos_audience_exports_sel ON public.exos_audience_exports FOR SELECT TO authenticated
      USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. The export
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_org_audience_export(p_org_id uuid, p_event_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_rows jsonb;
  v_n    integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_org_audience_export: sign in first' USING ERRCODE = '42501';
  END IF;
  IF p_org_id IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_org_audience_export: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF p_event_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_org_audience_export: not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  -- Throttle: 3 a minute per org (the shared limiter, when installed) and 20
  -- a day per org (the log).
  IF to_regprocedure('public.exos_rate_hit(text,integer)') IS NOT NULL
     AND NOT public.exos_rate_hit('audience:' || p_org_id::text, 3) THEN
    RAISE EXCEPTION 'exos_org_audience_export: too many exports, try again in a minute' USING ERRCODE = 'P0001';
  END IF;
  IF (SELECT count(*) FROM public.exos_audience_exports x
       WHERE x.org_id = p_org_id AND x.created_at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION 'exos_org_audience_export: daily export limit reached (20 per organization)' USING ERRCODE = 'P0001';
  END IF;

  WITH sess AS (
    -- Every checkout of this org, with the email it belongs to (normalized).
    SELECT s.session_id, s.event_id, s.buyer_uid, s.status, s.consent_marketing, s.created_at,
           lower(btrim(coalesce(nullif(btrim(s.buyer_email), ''), u.email))) AS email,
           -- auth.users.phone (Supabase stores the digits with the country code).
           regexp_replace(regexp_replace(coalesce(to_jsonb(u) ->> 'phone', ''), '\D', '', 'g'), '^0+', '') AS phone_digits,
           (s.buyer_uid IS NOT NULL AND u.id IS NULL) AS account_gone
      FROM public.exos_checkout_sessions s
      LEFT JOIN auth.users u ON u.id = s.buyer_uid
     WHERE s.org_id = p_org_id
  ),
  latest AS (
    -- The most recent consent choice per email at this org's checkouts.
    SELECT DISTINCT ON (x.email) x.email, x.consent_marketing AS choice
      FROM sess x
     WHERE x.email IS NOT NULL AND x.consent_marketing IN ('granted', 'denied')
     ORDER BY x.email, x.created_at DESC, x.session_id DESC
  ),
  eligible AS (
    SELECT b.email,
           CASE WHEN b.phone_digits ~ '^[1-9][0-9]{7,14}$' THEN b.phone_digits END AS phone_digits
      FROM sess b
      LEFT JOIN latest l ON l.email = b.email
     WHERE b.status IN ('fulfilled', 'partially_refunded')
       AND (p_event_id IS NULL OR b.event_id = p_event_id)
       AND NOT b.account_gone
       AND b.email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       AND b.email NOT LIKE 'deleted+%@deleted.invalid'
       -- Advertising consent at checkout; never when the latest choice was "no".
       AND coalesce(l.choice, '') <> 'denied'
       AND b.consent_marketing = 'granted'
       -- Unsubscribed from marketing mail: this account, or any account
       -- with this email.
       AND NOT EXISTS (SELECT 1 FROM public.exos_mail_prefs mp
                        WHERE mp.user_id = b.buyer_uid AND mp.marketing_opt_out)
       AND NOT EXISTS (SELECT 1 FROM auth.users ou
                         JOIN public.exos_mail_prefs mp ON mp.user_id = ou.id AND mp.marketing_opt_out
                        WHERE lower(btrim(ou.email)) = b.email)
  ),
  per_email AS (
    SELECT e.email, max(e.phone_digits) AS phone_digits
      FROM eligible e
     GROUP BY e.email
  ),
  hashed AS (
    SELECT encode(sha256(convert_to(p.email, 'UTF8')), 'hex') AS email_sha256,
           CASE WHEN p.phone_digits IS NOT NULL
                THEN encode(sha256(convert_to('+' || p.phone_digits, 'UTF8')), 'hex') END AS phone_sha256,
           CASE WHEN p.phone_digits IS NOT NULL
                THEN encode(sha256(convert_to(p.phone_digits, 'UTF8')), 'hex') END AS phone_digits_sha256
      FROM per_email p
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('email_sha256', h.email_sha256, 'phone_sha256', h.phone_sha256,
                                               'phone_digits_sha256', h.phone_digits_sha256)
                            ORDER BY h.email_sha256), '[]'::jsonb)
    INTO v_rows
    FROM hashed h;
  v_n := jsonb_array_length(v_rows);

  INSERT INTO public.exos_audience_exports (org_id, event_id, exported_by, row_count)
  VALUES (p_org_id, p_event_id, v_uid, v_n);
  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);
END $$;

REVOKE ALL ON FUNCTION public.exos_org_audience_export(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_audience_export(uuid, uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.exos_org_audience_export(uuid, uuid) IS
  'Owner / manager: SHA-256 hashes (email; phone E.164 and digits-only) of the org''s consenting buyers for custom-audience upload. Never raw PII. Logged in exos_audience_exports. mig 20260930101000.';
