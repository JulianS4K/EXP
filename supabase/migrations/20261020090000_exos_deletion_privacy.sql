-- ============================================================================
-- Account deletion: no way back onto marketing lists; SMS, queues and flags
-- scrubbed too
-- ============================================================================
-- Touches:  C: TABLE exos_marketing_suppressions (email hash + reason; RLS on,
--              no policies), FUNCTION _exos_suppress_email,
--              _exos_marketing_suppressed (internal)
--           P: exos_delete_my_account (email-matched sessions / tickets /
--              invoices, webhook payloads, ad conversions, limit flags, SMS
--              subscriptions; writes the suppression)
--           P: exos_mail_unsubscribe, exos_set_marketing_emails (write / clear
--              the suppression)
--           P: exos_org_audience_export, exos_mail_enqueue (marketing),
--              exos_tg_conversions_checkout (check it)
--           W: backfill of the suppression for accounts already opted out
-- Pre-reqs: 20260926010000 (account deletion), 20260926060000 (mail prefs),
--           20260929071000 (mail enqueue), 20260930100000 (conversions),
--           20260930101000 (audience export), 20261016120000 (SMS)
--
-- The audience export dropped opted-out buyers by matching auth.users.email,
-- and deletion only cleared the email on sessions with buyer_uid = the user.
-- Deleting the account tombstoned that email, so a guest-era checkout under
-- the same address (still carrying it, with ad consent) came back on the
-- export. Now:
--   * deletion also clears the address from every session / ticket / invoice
--     that carries it (a guest session must keep an address,
--     exos_checkout_sessions_buyer_chk, so it gets the tombstone the exports
--     already skip; invoices keep their frozen fields as before);
--   * a one-way SHA-256 of the address goes on exos_marketing_suppressions at
--     deletion and at marketing unsubscribe, and the email-matched marketing
--     paths (audience export, marketing mail, ad conversions) check it. An
--     unsubscribe holds until the account turns marketing mail back on; a
--     deletion suppresses consent given before it (a new checkout with fresh
--     consent afterwards counts);
--   * deletion opts the user's SMS numbers out for good (the subscriber rows,
--     by account and by the account's phone, are deleted and queued texts to
--     them skipped), takes the address out of webhook payloads and ad
--     conversions not yet sent (pending conversions are skipped), and clears
--     the email on the user's account-limit flags.
-- Already-deleted accounts can't be backfilled (their address is gone).
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, marker-guarded patches).
-- Prod apply needs operator OK.
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
-- 1. Suppression list
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_marketing_suppressions (
  email_sha256 text NOT NULL CHECK (email_sha256 ~ '^[0-9a-f]{64}$'),
  reason       text NOT NULL CHECK (reason IN ('unsubscribe', 'account_deleted')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (email_sha256, reason)
);
COMMENT ON TABLE public.exos_marketing_suppressions IS
  'SHA-256 of lower(trim(email)) kept off marketing (audience export, marketing mail, ad conversions): unsubscribe (until re-enabled) or account_deleted (consent given before it). No addresses stored. mig 20261020090000.';
ALTER TABLE public.exos_marketing_suppressions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_marketing_suppressions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_marketing_suppressions TO service_role;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_marketing_suppressions FROM %I', r);
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public._exos_suppress_email(p_email text, p_reason text)
RETURNS void LANGUAGE sql
SET search_path TO 'public', 'pg_temp'
AS $$
  INSERT INTO public.exos_marketing_suppressions (email_sha256, reason)
  SELECT public._exos_email_sha256(p_email), p_reason
   WHERE public._exos_email_sha256(p_email) IS NOT NULL
     AND lower(btrim(p_email)) NOT LIKE 'deleted+%@deleted.invalid'
  ON CONFLICT DO NOTHING
$$;
REVOKE ALL ON FUNCTION public._exos_suppress_email(text, text) FROM PUBLIC, anon, authenticated;

-- p_at: when the consent being used was given (NULL = any time).
CREATE OR REPLACE FUNCTION public._exos_marketing_suppressed(p_email text, p_at timestamptz DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_marketing_suppressions x
     WHERE x.email_sha256 = public._exos_email_sha256(p_email)
       AND (x.reason = 'unsubscribe' OR p_at IS NULL OR x.created_at >= p_at))
$$;
REVOKE ALL ON FUNCTION public._exos_marketing_suppressed(text, timestamptz) FROM PUBLIC, anon, authenticated;

-- Accounts already opted out.
INSERT INTO public.exos_marketing_suppressions (email_sha256, reason, created_at)
SELECT public._exos_email_sha256(u.email), 'unsubscribe', coalesce(min(mp.opted_out_at), now())
  FROM public.exos_mail_prefs mp
  JOIN auth.users u ON u.id = mp.user_id
 WHERE mp.marketing_opt_out
   AND public._exos_email_sha256(u.email) IS NOT NULL
   AND lower(btrim(u.email)) NOT LIKE 'deleted+%@deleted.invalid'
 GROUP BY 1
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Unsubscribe / re-subscribe write it
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_mail_unsubscribe(text)', '/* suppression list */',
'  GET DIAGNOSTICS v_n = ROW_COUNT;
',
'  GET DIAGNOSTICS v_n = ROW_COUNT;
  /* suppression list */
  PERFORM public._exos_suppress_email(u.email, ''unsubscribe'')
     FROM public.exos_mail_prefs p JOIN auth.users u ON u.id = p.user_id
    WHERE p.unsubscribe_token = p_token;
', 1);

SELECT pg_temp.exos_patch_n('public.exos_set_marketing_emails(boolean)', '/* suppression list */',
'  RETURN coalesce(p_enabled, true);
',
'  /* suppression list */
  IF coalesce(p_enabled, true) THEN
    DELETE FROM public.exos_marketing_suppressions x
     WHERE x.reason = ''unsubscribe''
       AND x.email_sha256 = (SELECT public._exos_email_sha256(u.email) FROM auth.users u WHERE u.id = v_uid);
  ELSE
    PERFORM public._exos_suppress_email((SELECT u.email FROM auth.users u WHERE u.id = v_uid), ''unsubscribe'');
  END IF;
  RETURN coalesce(p_enabled, true);
', 1);

-- ---------------------------------------------------------------------------
-- 3. Marketing paths that match by email check it
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_org_audience_export(uuid, uuid)', '/* suppression list */',
'                        WHERE lower(btrim(ou.email)) = b.email)
',
'                        WHERE lower(btrim(ou.email)) = b.email)
       -- Unsubscribed or deleted (by email hash; outlives the account).
       AND NOT public._exos_marketing_suppressed(b.email, b.created_at) /* suppression list */
', 1);

SELECT pg_temp.exos_patch_n('public.exos_mail_enqueue(text, text, jsonb, text, uuid, boolean, uuid)', '/* suppression list */',
'    IF EXISTS (SELECT 1 FROM public.exos_mail_prefs WHERE user_id = p_user_id AND marketing_opt_out) THEN
      RETURN NULL;
    END IF;
',
'    IF EXISTS (SELECT 1 FROM public.exos_mail_prefs WHERE user_id = p_user_id AND marketing_opt_out) THEN
      RETURN NULL;
    END IF;
    IF public._exos_marketing_suppressed(v_to, now()) THEN  /* suppression list */
      RETURN NULL;
    END IF;
', 1);

SELECT pg_temp.exos_patch_n('public.exos_tg_conversions_checkout()', '/* suppression list */',
'     OR NEW.consent_marketing IS DISTINCT FROM ''granted'' THEN
',
'     OR NEW.consent_marketing IS DISTINCT FROM ''granted''
     OR public._exos_marketing_suppressed(NEW.buyer_email, NEW.created_at) /* suppression list */ THEN
', 1);

-- ---------------------------------------------------------------------------
-- 4. Deletion: email-matched records, outbound queues, flags, SMS
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_delete_my_account()', '/* deletion privacy */',
'  -- Personal data that has no record-keeping value.
',
'  /* deletion privacy */
  IF v_email IS NOT NULL AND v_email <> '''' THEN
    -- Guest-era orders under this address lose it too. A guest session must
    -- keep an address (exos_checkout_sessions_buyer_chk): it gets the tombstone.
    UPDATE public.exos_tickets SET buyer_email = NULL, attendee_name = NULL
     WHERE lower(btrim(buyer_email)) = v_email;
    UPDATE public.exos_checkout_sessions SET buyer_email = CASE WHEN buyer_uid IS NULL THEN v_tomb END
     WHERE lower(btrim(buyer_email)) = v_email;
    UPDATE public.exos_invoices SET buyer_email = NULL WHERE lower(btrim(buyer_email)) = v_email;
    -- Webhook payloads (ticket.created owner_email, order.fulfilled buyer_email).
    UPDATE public.exos_webhook_deliveries d
       SET payload = jsonb_set(d.payload, ''{data,owner_email}'', ''null''::jsonb)
     WHERE lower(btrim(d.payload #>> ''{data,owner_email}'')) = v_email;
    UPDATE public.exos_webhook_deliveries d
       SET payload = jsonb_set(d.payload, ''{data,buyer_email}'', ''null''::jsonb)
     WHERE lower(btrim(d.payload #>> ''{data,buyer_email}'')) = v_email;
    -- Off every marketing list for good (consent given before now).
    PERFORM public._exos_suppress_email(v_email, ''account_deleted'');
  END IF;
  -- Ad conversions: hashed address out; nothing pending goes out.
  UPDATE public.exos_marketing_conversions c
     SET payload = c.payload - ''em'' - ''em_google'', payload_planned = NULL,
         status = CASE WHEN c.status = ''pending'' THEN ''skipped'' ELSE c.status END,
         last_error = CASE WHEN c.status = ''pending'' THEN ''account deleted'' ELSE c.last_error END
   WHERE (v_email <> '''' AND c.payload ->> ''em'' = public._exos_email_sha256(v_email))
      OR c.session_id IN (SELECT s.session_id FROM public.exos_checkout_sessions s WHERE s.buyer_uid = v_uid);
  UPDATE public.exos_account_limit_flags SET email = NULL
   WHERE user_id = v_uid OR (v_email <> '''' AND lower(btrim(email)) = v_email);
  -- SMS: this account''s numbers (and its own phone) are unsubscribed for good.
  WITH gone AS (
    DELETE FROM public.exos_sms_subscribers s
     WHERE s.user_id = v_uid
        OR s.phone = public.exos_sms_normalize_phone(
             (SELECT to_jsonb(u) ->> ''phone'' FROM auth.users u WHERE u.id = v_uid))
    RETURNING s.org_id, s.phone)
  UPDATE public.exos_sms_outbox o SET status = ''skipped'', error = ''account deleted''
    FROM gone WHERE o.org_id = gone.org_id AND o.phone = gone.phone AND o.status = ''queued'';

  -- Personal data that has no record-keeping value.
', 1);
