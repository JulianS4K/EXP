-- ============================================================================
-- Migration 20261114130000: Exos, Spanish (event fields, order language,
-- buyer mail language)
--
-- Lane:     d4 (exos)
-- Touches:  W: exos_events.i18n (new column + CHECK), exos_public_events
--              (+ i18n, appended), exos_checkout_sessions.lang (new),
--              exos_mail.lang (new) + BEFORE INSERT trigger
--              exos_mail_set_lang, FUNCTIONS _exos_event_i18n_ok (CHECK
--              helper), _exos_buyer_lang, _exos_mail_set_lang (new)
-- Pre-reqs: 20260929120000 (store content: the column-grant pattern and the
--           public view append), 20261105130000 (the view's latest columns)
--
-- Growth R&D pass 3, #3: the NYC Latin and Caribbean party segment, and CA/TX
-- fair buyers with Spanish-first door staff. docs/i18n-review.md.
--
-- 1. Per-language event fields. One jsonb column, {"es": {"title", "description"}},
--    both optional. The smallest schema change: no new table, no RPC. It rides
--    the event's own column grants and RLS, so exactly the roles that can edit
--    the event (exos_events_upd: owner / manager) can set it, and the public
--    reads it only on published events (exos_events_public_read, the view).
--    Validated here, not only in the editor: only "es", only the two fields,
--    non-blank strings, title <= 200 characters with no control characters,
--    description <= 20000 (the description_md cap).
-- 2. The order's language (exos_checkout_sessions.lang): what the buyer had
--    the app in when they bought, recorded by exos-checkout. Nothing reads it
--    for money; it picks the language of that buyer's mail.
-- 3. A mail's language (exos_mail.lang). Mail bodies are built in English by
--    ~20 functions (fulfilment, transfers, the door, comps), several of them
--    on the checkout / mint path that other branches patch. None of them is
--    touched: a BEFORE INSERT trigger stamps the recipient's language on buyer
--    mails, and exos-mail-drain sends the Spanish version
--    (_shared/mail-es.ts) when it has one for that exact mail, else the English
--    row as queued. The stored subject and body stay English, so the dedupe
--    checks that compare subjects (exos_queue_ticket_issued) keep working.
--    The recipient's language: their latest order with a language, else their
--    account's choice (auth user_metadata.lang, set by the language switcher),
--    else English.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. exos_events.i18n
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_event_i18n_ok(p jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p IS NULL OR jsonb_typeof(p) <> 'object' THEN false
    ELSE NOT EXISTS (SELECT 1 FROM jsonb_object_keys(p) k WHERE k <> 'es')
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_each(p) l
        WHERE CASE
          WHEN jsonb_typeof(l.value) <> 'object' THEN true
          ELSE EXISTS (SELECT 1 FROM jsonb_object_keys(l.value) f WHERE f NOT IN ('title', 'description'))
            OR (l.value ? 'title' AND (
                  jsonb_typeof(l.value -> 'title') <> 'string'
                  OR btrim(l.value ->> 'title') = ''
                  OR char_length(l.value ->> 'title') > 200
                  OR (l.value ->> 'title') ~ '[\x01-\x1f\x7f]'))
            OR (l.value ? 'description' AND (
                  jsonb_typeof(l.value -> 'description') <> 'string'
                  OR btrim(l.value ->> 'description') = ''
                  OR char_length(l.value ->> 'description') > 20000))
        END)
  END
$$;
REVOKE ALL ON FUNCTION public._exos_event_i18n_ok(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_event_i18n_ok(jsonb) TO authenticated, service_role;

ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS i18n jsonb NOT NULL DEFAULT '{}'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'exos_events_i18n_chk' AND conrelid = 'public.exos_events'::regclass) THEN
    ALTER TABLE public.exos_events
      ADD CONSTRAINT exos_events_i18n_chk CHECK (public._exos_event_i18n_ok(i18n));
  END IF;
END $$;

-- Column grants follow the per-column pattern (migs 20260925021000,
-- 20260929120000); RLS still decides which rows: the public reads published
-- events only, owners and managers write their own org's events.
GRANT SELECT (i18n) ON public.exos_events TO anon, authenticated;
GRANT INSERT (i18n), UPDATE (i18n) ON public.exos_events TO authenticated;

-- The public view: append i18n to whatever the live definition is, keeping
-- its options (security_invoker), the way 20261105130000 did.
DO $$
DECLARE d text; opts text; i int;
BEGIN
  IF to_regclass('public.exos_public_events') IS NULL THEN
    RAISE NOTICE 'exos_public_events: view not present here, skipping';
    RETURN;
  END IF;
  d := pg_get_viewdef('public.exos_public_events'::regclass);
  IF d ~ '\mi18n\M' THEN
    RAISE NOTICE 'exos_public_events: already has i18n, skipping';
    RETURN;
  END IF;
  i := position(E'\n   FROM ' in d);
  IF i = 0 THEN
    RAISE EXCEPTION 'exos_public_events: unexpected view definition';
  END IF;
  d := left(d, i - 1) || ',
    i18n' || substr(d, i);
  SELECT coalesce(' WITH (' || array_to_string(c.reloptions, ', ') || ')', '') INTO opts
    FROM pg_class c WHERE c.oid = 'public.exos_public_events'::regclass;
  EXECUTE format('CREATE OR REPLACE VIEW public.exos_public_events%s AS %s', opts, d);
  GRANT SELECT ON public.exos_public_events TO anon, authenticated;
END $$;

-- ---------------------------------------------------------------------------
-- 2. The order's language
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS lang text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'exos_checkout_sessions_lang_chk'
                    AND conrelid = 'public.exos_checkout_sessions'::regclass) THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_lang_chk CHECK (lang IS NULL OR lang IN ('en', 'es'));
  END IF;
END $$;
-- The mail trigger's lookup: a buyer's latest order that has a language.
CREATE INDEX IF NOT EXISTS exos_checkout_sessions_buyer_lang_idx
  ON public.exos_checkout_sessions (lower(buyer_email), created_at DESC)
  WHERE lang IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. A mail's language
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_mail
  ADD COLUMN IF NOT EXISTS lang text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'exos_mail_lang_chk' AND conrelid = 'public.exos_mail'::regclass) THEN
    ALTER TABLE public.exos_mail
      ADD CONSTRAINT exos_mail_lang_chk CHECK (lang IS NULL OR lang IN ('en', 'es'));
  END IF;
END $$;

-- The language a buyer reads: their latest order with one, else their
-- account's choice, else English. Internal (the trigger's), never callable.
CREATE OR REPLACE FUNCTION public._exos_buyer_lang(p_email text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT s.lang FROM public.exos_checkout_sessions s
      WHERE lower(s.buyer_email) = lower(btrim(p_email)) AND s.lang IS NOT NULL
      ORDER BY s.created_at DESC LIMIT 1),
    (SELECT u.raw_user_meta_data ->> 'lang' FROM auth.users u
      WHERE lower(u.email) = lower(btrim(p_email))
        AND u.raw_user_meta_data ->> 'lang' IN ('en', 'es')
      LIMIT 1),
    'en')
$$;
REVOKE ALL ON FUNCTION public._exos_buyer_lang(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_buyer_lang(text) TO service_role;

-- Buyer mails only: organizer, partner and staff mail stays English.
CREATE OR REPLACE FUNCTION public._exos_mail_set_lang()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.lang IS NULL AND NEW.template IN (
       'ticket-issued', 'transfer-initiated', 'transfer-claimed', 'transfer-sent', 'order-failed',
       'event-cancelled', 'event-updated', 'event-rescheduled', 'refund-issued', 'post-event',
       'event-reminder', 'waitlist-open', 'checkout-abandoned') THEN
    NEW.lang := public._exos_buyer_lang(NEW.to_email);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_mail_set_lang() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_mail_set_lang ON public.exos_mail;
CREATE TRIGGER exos_mail_set_lang
  BEFORE INSERT ON public.exos_mail
  FOR EACH ROW EXECUTE FUNCTION public._exos_mail_set_lang();
