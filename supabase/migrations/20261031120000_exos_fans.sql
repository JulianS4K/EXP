-- ============================================================================
-- Fans: per-org fan profiles, tags, embeddable signup forms (double opt-in),
-- an org-wide refund-request queue, a logged fan export and fan-app reads
-- ============================================================================
-- Touches:  C: TABLE exos_canonical_tags (seeded library, read-only),
--              exos_tags, exos_tagged_items, exos_fans, exos_signup_forms,
--              exos_signup_submissions, exos_fan_exports
--              (RLS on everywhere; staff SELECT policies via exos_has_org_role
--              where a direct read is useful, every write through RPCs)
--           C: TRIGGER exos_checkout_sessions_fans (AFTER INSERT / UPDATE OF
--              status: a fulfilled order makes or refreshes the buyer's fan
--              profile), exos_fans_consent_guard, exos_tagged_items_check,
--              *_touch (exos_touch_updated_at)
--           C: FUNCTION (staff, authenticated) exos_org_fans, exos_org_fan,
--              exos_org_fan_save, exos_org_fan_discard, exos_org_fans_export,
--              exos_org_tags, exos_tag_save, exos_tag_delete, exos_tag_apply,
--              exos_tag_remove, exos_org_tagged, exos_org_tag_filter,
--              exos_signup_forms_list, exos_signup_form_save,
--              exos_org_refund_asks
--           C: FUNCTION (fan, authenticated) exos_signup_confirm_sms,
--              exos_my_refund_asks_all, exos_my_ticket_bundles
--           C: FUNCTION (anon: public by design or 64-hex token gated)
--              exos_signup_form_public, exos_signup_confirm,
--              exos_signup_unsubscribe
--           C: FUNCTION (service role: exos-signup, exos-api)
--              _exos_signup_submit, _exos_fans_page, _exos_fan_detail,
--              _exos_fan_save, _exos_fan_discard, _exos_tag_save,
--              _exos_tag_delete, _exos_tag_apply, _exos_tagged_item_delete,
--              exos_api_refund_asks
--           W: exos_mail_template_check (+ 'signup-confirm', union pattern)
--           R: exos_checkout_sessions, exos_tickets, exos_events,
--              exos_order_refunds, exos_refund_asks, exos_org_follows (when
--              present),
--              exos_mail_prefs, exos_sms_subscribers, exos_artists (when
--              present, dynamic SQL), auth.users
-- Pre-reqs: 20261015090000 (refund asks), 20261016120000 (SMS consent),
--           20260929071000 (exos_mail_enqueue), 20260929060000 (exos_rate_hit),
--           20260929131000 (consent_marketing on checkouts)
--
-- Fan profiles (exos_fans). One row per (org, email): the person behind the
-- org's orders and signups. Built automatically: a fulfilled order (trigger,
-- plus a one-off backfill below) and a signup-form submission each make or
-- refresh one. Staff can add a contact by hand (name + email, nothing else)
-- and discard one (soft delete: hidden, names scrubbed; a later order or
-- signup by that person brings it back). Personal data stays minimal: email,
-- an optional first / last name and the account link. No phone, address or
-- birthday on the profile; order money is computed live from the ledger.
--
-- Consent is read-only for staff. The profile SHOWS each consent state (the
-- org email list, following the org, the latest advertising choice at
-- checkout, the platform-wide marketing opt-out, the SMS list with a masked
-- number), but no staff or API path can change one: the email-list columns on
-- exos_fans change only inside the fan's own actions (confirming a signup,
-- unsubscribing), enforced by a trigger that refuses any other write to them.
--
-- Signup forms. An org builds a form (title, intro, ask for a name, offer
-- texts, default tags) and embeds it (an iframe of /embed/signup/<form id>,
-- snippet in the dashboard). Submissions go to the exos-signup edge function
-- (anon, CORS-open, rate limited per network and per form, honeypot field,
-- optional captcha) which calls _exos_signup_submit as the service role.
-- Email is double opt-in: the submission mails a confirm link
-- (signup-confirm, /signup/confirm?t=<64 hex>); only the click puts the fan
-- on the org's email list. Texts follow the existing compliant SMS flow
-- (mig 20261016120000): the form shows the same consent wording
-- (exos_sms_consent_text, identical to src/lib/sms.ts consentText) and
-- stores it, but the number joins exos_sms_subscribers only when the fan,
-- signed in, confirms it from the confirm page (exos_signup_confirm_sms), the
-- same "signed-in only, so a stranger can't sign someone else's number up"
-- rule as exos_sms_opt_in. Anonymous paths never return fan data: the submit
-- always answers the same thing, and the token RPCs answer only the org name.
--
-- Tags. Org tags (exos_tags; optionally scoped to event, fan or artist, and
-- optionally linked to a canonical tag from a small seeded library) applied
-- to records via exos_tagged_items. The trigger checks the record is the
-- org's own (artists only once exos_artists exists). Filters:
-- exos_org_tag_filter (record ids carrying all the given tags), the fan list
-- and the exos-api ?tag_id= filters.
--
-- Refund requests. The fan asks from the ticket page (exos_ask_refund, mig
-- 20261015090000); My Tickets now lists every ask (exos_my_refund_asks_all).
-- Staff get an org-wide queue (exos_org_refund_asks); approving runs the
-- EXISTING refund (exos-refund with nonce 'ask:<id>', whose success closes the
-- ask), declining the existing exos_decline_refund_ask. Nothing new moves money.
--
-- Fan export. Owner / manager only, logged in exos_fan_exports (who, when,
-- filters, row count), 3 a minute and 20 a day per org. CSV built in the SPA.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded policies, allowlist
-- union). D4 authors; applying to prod is operator-gated.
-- ROLLBACK (manual): drop the trigger on exos_checkout_sessions, the functions
-- above and the seven tables; the 'signup-confirm' allowlist value can stay.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Canonical tag library (system-wide, seeded, read-only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_canonical_tags (
  id         text PRIMARY KEY CHECK (id ~ '^[a-z0-9-]{1,40}$'),
  category   text NOT NULL CHECK (category IN ('genre', 'audience', 'format', 'access')),
  name       text NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
  sort_order int  NOT NULL DEFAULT 0
);
ALTER TABLE public.exos_canonical_tags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_canonical_tags FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_canonical_tags TO authenticated;
GRANT ALL ON public.exos_canonical_tags TO service_role;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'exos_canonical_tags_sel'
                   AND polrelid = 'public.exos_canonical_tags'::regclass) THEN
    CREATE POLICY exos_canonical_tags_sel ON public.exos_canonical_tags FOR SELECT TO authenticated USING (true);
  END IF;
END $$;
INSERT INTO public.exos_canonical_tags (id, category, name, sort_order) VALUES
  ('rock', 'genre', 'Rock', 10), ('pop', 'genre', 'Pop', 11), ('hip-hop', 'genre', 'Hip-hop', 12),
  ('electronic', 'genre', 'Electronic', 13), ('jazz', 'genre', 'Jazz', 14), ('country', 'genre', 'Country', 15),
  ('latin', 'genre', 'Latin', 16), ('classical', 'genre', 'Classical', 17), ('comedy', 'genre', 'Comedy', 18),
  ('theatre', 'genre', 'Theatre', 19), ('folk', 'genre', 'Folk', 20), ('metal', 'genre', 'Metal', 21),
  ('rnb', 'genre', 'R&B', 22), ('indie', 'genre', 'Indie', 23),
  ('vip', 'audience', 'VIP', 30), ('regular', 'audience', 'Regular', 31), ('first-timer', 'audience', 'First-timer', 32),
  ('press', 'audience', 'Press', 33), ('industry', 'audience', 'Industry', 34), ('member', 'audience', 'Member', 35),
  ('all-ages', 'access', 'All ages', 40), ('18-plus', 'access', '18+', 41), ('21-plus', 'access', '21+', 42),
  ('seated', 'format', 'Seated', 50), ('standing', 'format', 'Standing', 51), ('festival', 'format', 'Festival', 52),
  ('livestream', 'format', 'Livestream', 53), ('workshop', 'format', 'Workshop', 54)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Org tags and tagged items
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_tags (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name             text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 40),
  scope            text CHECK (scope IS NULL OR scope IN ('event', 'fan', 'artist')),
  color            text CHECK (color IS NULL OR color ~ '^#[0-9a-fA-F]{6}$'),
  canonical_tag_id text REFERENCES public.exos_canonical_tags (id) ON DELETE SET NULL,
  created_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_tags_org_name_uq ON public.exos_tags (org_id, lower(name), coalesce(scope, ''));
ALTER TABLE public.exos_tags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_tags FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_tags TO authenticated;
GRANT ALL ON public.exos_tags TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_tagged_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  tag_id        uuid NOT NULL REFERENCES public.exos_tags (id) ON DELETE CASCADE,
  taggable_type text NOT NULL CHECK (taggable_type IN ('event', 'fan', 'artist')),
  taggable_id   uuid NOT NULL,
  created_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tag_id, taggable_type, taggable_id)
);
CREATE INDEX IF NOT EXISTS exos_tagged_items_target_idx ON public.exos_tagged_items (org_id, taggable_type, taggable_id);
ALTER TABLE public.exos_tagged_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_tagged_items FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_tagged_items TO authenticated;
GRANT ALL ON public.exos_tagged_items TO service_role;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'exos_tags_sel' AND polrelid = 'public.exos_tags'::regclass) THEN
    CREATE POLICY exos_tags_sel ON public.exos_tags FOR SELECT TO authenticated
      USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','content']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'exos_tagged_items_sel' AND polrelid = 'public.exos_tagged_items'::regclass) THEN
    CREATE POLICY exos_tagged_items_sel ON public.exos_tagged_items FOR SELECT TO authenticated
      USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','content']));
  END IF;
END $$;

DROP TRIGGER IF EXISTS exos_tags_touch ON public.exos_tags;
CREATE TRIGGER exos_tags_touch BEFORE UPDATE ON public.exos_tags
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Fan profiles
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_fans (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  email               text NOT NULL CHECK (email = lower(btrim(email)) AND length(email) BETWEEN 3 AND 254),
  user_id             uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  first_name          text CHECK (first_name IS NULL OR length(first_name) <= 60),
  last_name           text CHECK (last_name IS NULL OR length(last_name) <= 60),
  source              text NOT NULL DEFAULT 'order' CHECK (source IN ('order', 'signup', 'manual', 'api')),
  orders_count        int  NOT NULL DEFAULT 0 CHECK (orders_count >= 0),
  first_order_at      timestamptz,
  last_order_at       timestamptz,
  -- The org email list. Changed only by the fan's own actions (trigger below).
  email_opt_in_at     timestamptz,
  email_opt_in_source text CHECK (email_opt_in_source IS NULL OR length(email_opt_in_source) <= 80),
  email_opt_out_at    timestamptz,
  unsubscribe_token   text NOT NULL UNIQUE
                        DEFAULT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
                        CHECK (unsubscribe_token ~ '^[0-9a-f]{64}$'),
  discarded_at        timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, email)
);
CREATE INDEX IF NOT EXISTS exos_fans_user_idx ON public.exos_fans (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_fans_org_updated_idx ON public.exos_fans (org_id, updated_at DESC);
ALTER TABLE public.exos_fans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_fans FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_fans TO service_role;
-- No client grants: staff read fans through exos_org_fans / exos_org_fan
-- (which never hand out the unsubscribe token).

DROP TRIGGER IF EXISTS exos_fans_touch ON public.exos_fans;
CREATE TRIGGER exos_fans_touch BEFORE UPDATE ON public.exos_fans
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- The email-list columns move only inside a fan action (exos_signup_confirm,
-- exos_signup_unsubscribe), which raises the transaction-local flag
-- exos.fan_consent_action for that one write. Any other writer (a staff RPC,
-- the partner API, a service-role script) is refused.
CREATE OR REPLACE FUNCTION public._exos_fans_consent_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(current_setting('exos.fan_consent_action', true), '') = 'on' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.email_opt_in_at IS NOT NULL OR NEW.email_opt_out_at IS NOT NULL OR NEW.email_opt_in_source IS NOT NULL THEN
      RAISE EXCEPTION 'exos_fans: email consent is set only by the fan' USING ERRCODE = '42501';
    END IF;
  ELSIF NEW.email_opt_in_at IS DISTINCT FROM OLD.email_opt_in_at
     OR NEW.email_opt_out_at IS DISTINCT FROM OLD.email_opt_out_at
     OR NEW.email_opt_in_source IS DISTINCT FROM OLD.email_opt_in_source
     OR NEW.unsubscribe_token IS DISTINCT FROM OLD.unsubscribe_token THEN
    RAISE EXCEPTION 'exos_fans: email consent is changed only by the fan' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_fans_consent_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_fans_consent_guard ON public.exos_fans;
CREATE TRIGGER exos_fans_consent_guard BEFORE INSERT OR UPDATE ON public.exos_fans
  FOR EACH ROW EXECUTE FUNCTION public._exos_fans_consent_guard();

-- Tagged records must be the org's own. Artists only once exos_artists exists.
CREATE OR REPLACE FUNCTION public._exos_tagged_items_check()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_scope text; v_tag_org uuid; v_ok boolean := false;
BEGIN
  SELECT t.org_id, t.scope INTO v_tag_org, v_scope FROM public.exos_tags t WHERE t.id = NEW.tag_id;
  IF v_tag_org IS NULL OR v_tag_org <> NEW.org_id THEN
    RAISE EXCEPTION 'exos_tagged_items: tag not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_scope IS NOT NULL AND v_scope <> NEW.taggable_type THEN
    RAISE EXCEPTION 'exos_tagged_items: this tag is for % records', v_scope USING ERRCODE = '22023';
  END IF;
  IF NEW.taggable_type = 'event' THEN
    v_ok := EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = NEW.taggable_id AND e.org_id = NEW.org_id);
  ELSIF NEW.taggable_type = 'fan' THEN
    v_ok := EXISTS (SELECT 1 FROM public.exos_fans f WHERE f.id = NEW.taggable_id AND f.org_id = NEW.org_id AND f.discarded_at IS NULL);
  ELSIF NEW.taggable_type = 'artist' AND to_regclass('public.exos_artists') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.exos_artists a WHERE a.id = $1 AND a.org_id = $2)'
       INTO v_ok USING NEW.taggable_id, NEW.org_id;
  END IF;
  IF NOT coalesce(v_ok, false) THEN
    RAISE EXCEPTION 'exos_tagged_items: % not found', NEW.taggable_type USING ERRCODE = 'P0002';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tagged_items_check() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tagged_items_check ON public.exos_tagged_items;
CREATE TRIGGER exos_tagged_items_check BEFORE INSERT OR UPDATE ON public.exos_tagged_items
  FOR EACH ROW EXECUTE FUNCTION public._exos_tagged_items_check();

-- ---------------------------------------------------------------------------
-- 4. Signup forms and submissions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_signup_forms (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),     -- staff label
  title           text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),   -- what fans see
  intro           text CHECK (intro IS NULL OR length(intro) <= 500),
  button_label    text CHECK (button_label IS NULL OR length(button_label) <= 40),
  ask_name        boolean NOT NULL DEFAULT true,
  offer_sms       boolean NOT NULL DEFAULT false,
  default_tag_ids uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(default_tag_ids) <= 10),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'archived')),
  created_by      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_signup_forms_org_idx ON public.exos_signup_forms (org_id, created_at DESC);
ALTER TABLE public.exos_signup_forms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_signup_forms FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_signup_forms TO authenticated;
GRANT ALL ON public.exos_signup_forms TO service_role;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'exos_signup_forms_sel' AND polrelid = 'public.exos_signup_forms'::regclass) THEN
    CREATE POLICY exos_signup_forms_sel ON public.exos_signup_forms FOR SELECT TO authenticated
      USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
  END IF;
END $$;
DROP TRIGGER IF EXISTS exos_signup_forms_touch ON public.exos_signup_forms;
CREATE TRIGGER exos_signup_forms_touch BEFORE UPDATE ON public.exos_signup_forms
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

CREATE TABLE IF NOT EXISTS public.exos_signup_submissions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  form_id            uuid NOT NULL REFERENCES public.exos_signup_forms (id) ON DELETE CASCADE,
  fan_id             uuid NOT NULL REFERENCES public.exos_fans (id) ON DELETE CASCADE,
  email_requested    boolean NOT NULL DEFAULT false,
  email_consent_text text CHECK (email_consent_text IS NULL OR length(email_consent_text) <= 600),
  confirm_token_hash text UNIQUE CHECK (confirm_token_hash IS NULL OR confirm_token_hash ~ '^[0-9a-f]{64}$'),
  confirm_sent_at    timestamptz,
  confirmed_at       timestamptz,
  -- Texts: the number and the exact wording shown, kept until the fan,
  -- signed in, confirms it (exos_signup_confirm_sms). Cleared after 30 days.
  sms_requested      boolean NOT NULL DEFAULT false,
  sms_phone          text CHECK (sms_phone IS NULL OR sms_phone ~ '^\+[1-9][0-9]{7,14}$'),
  sms_consent_text   text CHECK (sms_consent_text IS NULL OR length(sms_consent_text) BETWEEN 20 AND 600),
  sms_confirmed_at   timestamptz,
  ip_hash            text CHECK (ip_hash IS NULL OR ip_hash ~ '^[0-9a-f]{64}$'),
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_signup_submissions_form_idx ON public.exos_signup_submissions (form_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_signup_submissions_fan_idx ON public.exos_signup_submissions (fan_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_signup_submissions_ip_idx ON public.exos_signup_submissions (ip_hash, created_at DESC) WHERE ip_hash IS NOT NULL;
ALTER TABLE public.exos_signup_submissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_signup_submissions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_signup_submissions TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Fan export log
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_fan_exports (
  id          bigserial PRIMARY KEY,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  exported_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  filters     jsonb NOT NULL DEFAULT '{}'::jsonb,
  row_count   int NOT NULL CHECK (row_count >= 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_fan_exports_org_idx ON public.exos_fan_exports (org_id, created_at DESC);
ALTER TABLE public.exos_fan_exports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_fan_exports FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_fan_exports TO authenticated;
GRANT ALL ON public.exos_fan_exports TO service_role;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'exos_fan_exports_sel' AND polrelid = 'public.exos_fan_exports'::regclass) THEN
    CREATE POLICY exos_fan_exports_sel ON public.exos_fan_exports FOR SELECT TO authenticated
      USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 6. Building profiles from orders
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_fan_email(p_email text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN e ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' AND length(e) <= 254
                   AND e NOT LIKE 'deleted+%@deleted.invalid'
              THEN e END
    FROM (SELECT lower(btrim(coalesce(p_email, ''))) AS e) x
$$;
REVOKE ALL ON FUNCTION public._exos_fan_email(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_fan_email(text) TO authenticated, service_role;

-- Make or refresh the org's profile for this email. Never overwrites a name,
-- never touches consent. A discarded profile comes back (the person acted).
CREATE OR REPLACE FUNCTION public._exos_fan_touch(
  p_org_id uuid, p_email text, p_user_id uuid, p_source text,
  p_first text DEFAULT NULL, p_last text DEFAULT NULL, p_order_at timestamptz DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text := public._exos_fan_email(p_email);
  v_first text := left(nullif(btrim(coalesce(p_first, '')), ''), 60);
  v_last  text := left(nullif(btrim(coalesce(p_last, '')), ''), 60);
  v_id    uuid;
BEGIN
  IF v_email IS NULL OR p_org_id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.exos_fans AS f (org_id, email, user_id, first_name, last_name, source,
                                     orders_count, first_order_at, last_order_at)
  VALUES (p_org_id, v_email, p_user_id, v_first, v_last, p_source,
          CASE WHEN p_order_at IS NOT NULL THEN 1 ELSE 0 END, p_order_at, p_order_at)
  ON CONFLICT (org_id, email) DO UPDATE
     SET user_id        = coalesce(f.user_id, EXCLUDED.user_id),
         first_name     = coalesce(f.first_name, EXCLUDED.first_name),
         last_name      = coalesce(f.last_name, EXCLUDED.last_name),
         orders_count   = f.orders_count + CASE WHEN p_order_at IS NOT NULL THEN 1 ELSE 0 END,
         first_order_at = CASE WHEN p_order_at IS NULL THEN f.first_order_at
                               ELSE least(coalesce(f.first_order_at, p_order_at), p_order_at) END,
         last_order_at  = CASE WHEN p_order_at IS NULL THEN f.last_order_at
                               ELSE greatest(coalesce(f.last_order_at, p_order_at), p_order_at) END,
         discarded_at   = NULL,
         updated_at     = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_fan_touch(uuid, text, uuid, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated;

-- A checkout that becomes fulfilled (or is inserted fulfilled) counts once.
-- Never fails the order: a problem here is a warning.
CREATE OR REPLACE FUNCTION public.exos_tg_checkout_fans()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text;
BEGIN
  IF NEW.status NOT IN ('fulfilled', 'partially_refunded') THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IN ('fulfilled', 'partially_refunded', 'refunded') THEN RETURN NEW; END IF;
  BEGIN
    v_email := nullif(btrim(coalesce(NEW.buyer_email, '')), '');
    IF v_email IS NULL AND NEW.buyer_uid IS NOT NULL THEN
      SELECT u.email INTO v_email FROM auth.users u WHERE u.id = NEW.buyer_uid;
    END IF;
    PERFORM public._exos_fan_touch(NEW.org_id, v_email, NEW.buyer_uid, 'order', NULL, NULL,
                                   coalesce(NEW.fulfilled_at, NEW.created_at, now()));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos_tg_checkout_fans: % (session %)', SQLERRM, NEW.session_id;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_checkout_fans() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_checkout_sessions_fans ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_sessions_fans
  AFTER INSERT OR UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_checkout_fans();

-- One-off backfill from existing orders (re-run safe: only orgs/emails not
-- yet profiled; counts computed, not incremented).
INSERT INTO public.exos_fans (org_id, email, user_id, source, orders_count, first_order_at, last_order_at)
SELECT x.org_id, x.email, (array_agg(x.buyer_uid ORDER BY x.at DESC) FILTER (WHERE x.buyer_uid IS NOT NULL))[1],
       'order', count(*), min(x.at), max(x.at)
  FROM (
    SELECT s.org_id, s.buyer_uid, coalesce(s.fulfilled_at, s.created_at) AS at,
           public._exos_fan_email(coalesce(nullif(btrim(s.buyer_email), ''), u.email)) AS email
      FROM public.exos_checkout_sessions s
      LEFT JOIN auth.users u ON u.id = s.buyer_uid
     WHERE s.status IN ('fulfilled', 'partially_refunded', 'refunded')
  ) x
 WHERE x.email IS NOT NULL AND x.org_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.exos_fans f WHERE f.org_id = x.org_id AND f.email = x.email)
 GROUP BY x.org_id, x.email;

-- ---------------------------------------------------------------------------
-- 7. Reading fans (internal: explicit org; staff wrappers check the role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_fan_email_list(f public.exos_fans)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
           WHEN f.email_opt_out_at IS NOT NULL THEN 'unsubscribed'
           WHEN f.email_opt_in_at IS NOT NULL THEN 'subscribed'
           WHEN EXISTS (SELECT 1 FROM public.exos_signup_submissions s
                         WHERE s.fan_id = f.id AND s.email_requested AND s.confirmed_at IS NULL
                           AND s.created_at > now() - interval '7 days') THEN 'pending'
           ELSE 'none'
         END
$$;
REVOKE ALL ON FUNCTION public._exos_fan_email_list(public.exos_fans) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_fan_tags(p_fan_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'color', t.color, 'tagged_item_id', ti.id)
                            ORDER BY lower(t.name)), '[]'::jsonb)
    FROM public.exos_tagged_items ti
    JOIN public.exos_tags t ON t.id = ti.tag_id
   WHERE ti.taggable_type = 'fan' AND ti.taggable_id = p_fan_id
$$;
REVOKE ALL ON FUNCTION public._exos_fan_tags(uuid) FROM PUBLIC, anon, authenticated;

-- A page of the org's fans. Search matches email / name; tag ids must ALL be
-- on the fan; updated_after for incremental sync. Sorts: created_at,
-- updated_at, last_order_at, email (asc / desc).
CREATE OR REPLACE FUNCTION public._exos_fans_page(
  p_org_id uuid, p_search text DEFAULT NULL, p_email text DEFAULT NULL, p_tag_ids uuid[] DEFAULT NULL,
  p_updated_after timestamptz DEFAULT NULL, p_sort text DEFAULT 'created_at desc',
  p_limit int DEFAULT 50, p_offset int DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_q     text := nullif(btrim(coalesce(p_search, '')), '');
  v_like  text;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_tags  uuid[] := (SELECT array_agg(DISTINCT t) FROM unnest(coalesce(p_tag_ids, '{}'::uuid[])) t WHERE t IS NOT NULL);
  v_sort  text := lower(regexp_replace(btrim(coalesce(p_sort, 'created_at desc')), '\s+', ' ', 'g'));
  -- Callers clamp their own page size (dashboard 500, API 200); the export
  -- asks for everything.
  v_lim   int := least(greatest(coalesce(p_limit, 50), 1), 100000);
  v_off   int := least(greatest(coalesce(p_offset, 0), 0), 2000000);
  v_total int;
  v_rows  jsonb;
BEGIN
  IF v_q IS NOT NULL AND length(v_q) > 100 THEN
    RAISE EXCEPTION 'exos_fans: search is at most 100 characters' USING ERRCODE = '22023';
  END IF;
  IF v_sort NOT IN ('created_at asc', 'created_at desc', 'updated_at asc', 'updated_at desc',
                    'last_order_at asc', 'last_order_at desc', 'email asc', 'email desc') THEN
    RAISE EXCEPTION 'exos_fans: sort must be created_at, updated_at, last_order_at or email, then asc or desc' USING ERRCODE = '22023';
  END IF;
  IF coalesce(cardinality(v_tags), 0) > 10 THEN
    RAISE EXCEPTION 'exos_fans: at most 10 tags' USING ERRCODE = '22023';
  END IF;
  v_like := '%' || replace(replace(replace(coalesce(v_q, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';

  WITH hits AS (
    SELECT f.*
      FROM public.exos_fans f
     WHERE f.org_id = p_org_id AND f.discarded_at IS NULL
       AND (v_q IS NULL OR f.email ILIKE v_like OR f.first_name ILIKE v_like OR f.last_name ILIKE v_like
            OR (coalesce(f.first_name, '') || ' ' || coalesce(f.last_name, '')) ILIKE v_like)
       AND (v_email IS NULL OR f.email = v_email)
       AND (p_updated_after IS NULL OR f.updated_at > p_updated_after)
       AND (v_tags IS NULL OR (SELECT count(DISTINCT ti.tag_id) FROM public.exos_tagged_items ti
                                WHERE ti.taggable_type = 'fan' AND ti.taggable_id = f.id
                                  AND ti.tag_id = ANY (v_tags)) = cardinality(v_tags))
  ),
  ordered AS (
    SELECT h.id, row_number() OVER (ORDER BY
             CASE WHEN v_sort = 'created_at asc' THEN h.created_at END ASC,
             CASE WHEN v_sort = 'created_at desc' THEN h.created_at END DESC,
             CASE WHEN v_sort = 'updated_at asc' THEN h.updated_at END ASC,
             CASE WHEN v_sort = 'updated_at desc' THEN h.updated_at END DESC,
             CASE WHEN v_sort = 'last_order_at asc' THEN h.last_order_at END ASC NULLS LAST,
             CASE WHEN v_sort = 'last_order_at desc' THEN h.last_order_at END DESC NULLS LAST,
             CASE WHEN v_sort = 'email asc' THEN h.email END ASC,
             CASE WHEN v_sort = 'email desc' THEN h.email END DESC,
             h.id) AS n
      FROM hits h
  )
  SELECT (SELECT count(*) FROM hits),
         (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'id', f.id, 'email', f.email, 'first_name', f.first_name, 'last_name', f.last_name,
                   'has_account', f.user_id IS NOT NULL, 'source', f.source,
                   'orders_count', f.orders_count, 'first_order_at', f.first_order_at, 'last_order_at', f.last_order_at,
                   'email_list', public._exos_fan_email_list(f), 'tags', public._exos_fan_tags(f.id),
                   'created_at', f.created_at, 'updated_at', f.updated_at) ORDER BY o.n), '[]'::jsonb)
            FROM ordered o JOIN public.exos_fans f ON f.id = o.id
           WHERE o.n > v_off AND o.n <= v_off + v_lim)
    INTO v_total, v_rows;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public._exos_fans_page(uuid, text, text, uuid[], timestamptz, text, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fans_page(uuid, text, text, uuid[], timestamptz, text, int, int) TO service_role;

-- One fan: profile, consent (read-only), orders and money, tags, signups.
CREATE OR REPLACE FUNCTION public._exos_fan_detail(p_org_id uuid, p_fan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  f        public.exos_fans%ROWTYPE;
  v_sids   text[];
  v_orders jsonb;
  v_money  jsonb;
  v_ntix   int;
  v_ad     text;
  v_sms    jsonb;
  v_signup jsonb;
  v_follow boolean := false;
  v_optout boolean := false;
BEGIN
  SELECT * INTO f FROM public.exos_fans WHERE id = p_fan_id AND org_id = p_org_id AND discarded_at IS NULL;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT coalesce(array_agg(s.session_id), '{}') INTO v_sids
    FROM public.exos_checkout_sessions s
   WHERE s.org_id = p_org_id
     AND s.status IN ('fulfilled', 'partially_refunded', 'refunded')
     AND (lower(btrim(coalesce(s.buyer_email, ''))) = f.email
          OR (f.user_id IS NOT NULL AND s.buyer_uid = f.user_id));

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'session_id', x.session_id, 'event_id', x.event_id, 'event_name', e.name, 'starts_at', e.starts_at,
           'quantity', x.quantity, 'amount_cents', x.amount_cents, 'currency', lower(coalesce(x.currency, 'usd')),
           'status', x.status, 'created_at', x.created_at) ORDER BY x.created_at DESC), '[]'::jsonb)
    INTO v_orders
    FROM (SELECT * FROM public.exos_checkout_sessions WHERE session_id = ANY (v_sids)
           ORDER BY created_at DESC LIMIT 20) x
    LEFT JOIN public.exos_events e ON e.id = x.event_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('currency', m.currency, 'paid_cents', m.paid, 'refunded_cents', m.refunded,
                                               'orders', m.n) ORDER BY m.currency), '[]'::jsonb)
    INTO v_money
    FROM (SELECT lower(coalesce(s.currency, 'usd')) AS currency, count(*) AS n, sum(s.amount_cents) AS paid,
                 coalesce(sum((SELECT sum(r.amount_cents) FROM public.exos_order_refunds r
                                WHERE r.session_id = s.session_id AND r.status = 'succeeded')), 0) AS refunded
            FROM public.exos_checkout_sessions s WHERE s.session_id = ANY (v_sids)
           GROUP BY lower(coalesce(s.currency, 'usd'))) m;

  SELECT count(*) INTO v_ntix
    FROM public.exos_tickets t
   WHERE t.org_id = p_org_id AND t.order_ref = ANY (v_sids) AND t.status IN ('active', 'used');

  -- Consent, read-only: what the fan chose, where they chose it.
  SELECT s.consent_marketing INTO v_ad
    FROM public.exos_checkout_sessions s
   WHERE s.org_id = p_org_id AND s.consent_marketing IN ('granted', 'denied')
     AND (lower(btrim(coalesce(s.buyer_email, ''))) = f.email OR (f.user_id IS NOT NULL AND s.buyer_uid = f.user_id))
   ORDER BY s.created_at DESC LIMIT 1;
  IF f.user_id IS NOT NULL THEN
    IF to_regclass('public.exos_org_follows') IS NOT NULL THEN  -- dynamic: not in every replay chain
      EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.exos_org_follows o WHERE o.org_id = $1 AND o.follower_uid = $2)'
         INTO v_follow USING p_org_id, f.user_id;
    END IF;
    v_optout := EXISTS (SELECT 1 FROM public.exos_mail_prefs mp WHERE mp.user_id = f.user_id AND mp.marketing_opt_out);
  END IF;
  SELECT jsonb_build_object('status', CASE WHEN ss.opted_out_at IS NULL THEN 'subscribed' ELSE 'opted_out' END,
                            'phone_hint', '…' || right(ss.phone, 4), 'since', ss.consented_at,
                            'opted_out_at', ss.opted_out_at, 'source', ss.source)
    INTO v_sms
    FROM public.exos_sms_subscribers ss
   WHERE ss.org_id = p_org_id
     AND ((f.user_id IS NOT NULL AND ss.user_id = f.user_id)
          OR ss.phone IN (SELECT su.sms_phone FROM public.exos_signup_submissions su
                           WHERE su.fan_id = f.id AND su.sms_confirmed_at IS NOT NULL))
   ORDER BY ss.updated_at DESC LIMIT 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object('form_id', su.form_id, 'form_name', fo.name, 'created_at', su.created_at,
                                               'email_requested', su.email_requested, 'confirmed_at', su.confirmed_at,
                                               'sms_requested', su.sms_requested, 'sms_confirmed_at', su.sms_confirmed_at)
                            ORDER BY su.created_at DESC), '[]'::jsonb)
    INTO v_signup
    FROM (SELECT * FROM public.exos_signup_submissions WHERE fan_id = f.id ORDER BY created_at DESC LIMIT 20) su
    JOIN public.exos_signup_forms fo ON fo.id = su.form_id;

  RETURN jsonb_build_object(
    'id', f.id, 'email', f.email, 'first_name', f.first_name, 'last_name', f.last_name,
    'has_account', f.user_id IS NOT NULL, 'source', f.source, 'created_at', f.created_at, 'updated_at', f.updated_at,
    'stats', jsonb_build_object('orders', f.orders_count, 'tickets', v_ntix, 'first_order_at', f.first_order_at,
                                'last_order_at', f.last_order_at, 'money', v_money),
    'consent', jsonb_build_object(
      'email_list', jsonb_build_object('status', public._exos_fan_email_list(f), 'since', f.email_opt_in_at,
                                       'source', f.email_opt_in_source, 'unsubscribed_at', f.email_opt_out_at),
      'follows_org', v_follow,
      'ad_consent', v_ad,
      'marketing_mail_opt_out', v_optout,
      'sms', coalesce(v_sms, jsonb_build_object('status', 'none'))),
    'orders', v_orders,
    'tags', public._exos_fan_tags(f.id),
    'signups', v_signup);
END $$;
REVOKE ALL ON FUNCTION public._exos_fan_detail(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fan_detail(uuid, uuid) TO service_role;

-- Staff: owner / manager / finance read fans.
CREATE OR REPLACE FUNCTION public.exos_org_fans(
  p_org_id uuid, p_search text DEFAULT NULL, p_tag_ids uuid[] DEFAULT NULL,
  p_sort text DEFAULT 'created_at desc', p_limit int DEFAULT 50, p_offset int DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager','finance']) THEN
    RAISE EXCEPTION 'exos_org_fans: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_fans_page(p_org_id, p_search, NULL, p_tag_ids, NULL, p_sort,
                                least(greatest(coalesce(p_limit, 50), 1), 500), p_offset);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_fans(uuid, text, uuid[], text, int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_fans(uuid, text, uuid[], text, int, int) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_org_fan(p_org_id uuid, p_fan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager','finance']) THEN
    RAISE EXCEPTION 'exos_org_fan: not authorized' USING ERRCODE = '42501';
  END IF;
  v := public._exos_fan_detail(p_org_id, p_fan_id);
  IF v IS NULL THEN RAISE EXCEPTION 'exos_org_fan: fan not found' USING ERRCODE = 'P0002'; END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.exos_org_fan(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_fan(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Changing fans (contact fields only; never consent)
-- ---------------------------------------------------------------------------
-- p_fields: first_name, last_name; email on create only. Returns the profile.
CREATE OR REPLACE FUNCTION public._exos_fan_save(p_org_id uuid, p_fan_id uuid, p_fields jsonb, p_source text DEFAULT 'manual')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  b       jsonb := CASE WHEN jsonb_typeof(p_fields) = 'object' THEN p_fields ELSE '{}'::jsonb END;
  v_email text;
  v_first text;
  v_last  text;
  v_id    uuid := p_fan_id;
  k       text;
BEGIN
  FOR k IN SELECT jsonb_object_keys(b) LOOP
    IF k IN ('email_opt_in_at', 'email_opt_out_at', 'email_opt_in_source', 'marketing_opt_ins',
             'subscribe_to_marketing', 'subscribe_to_marketing_email', 'subscribe_to_marketing_sms', 'consent') THEN
      RAISE EXCEPTION 'exos_fans: consent can''t be set for a fan; they opt in themselves (signup form, ticket page)' USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF b ? 'first_name' AND jsonb_typeof(b->'first_name') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION 'exos_fans: first_name must be text' USING ERRCODE = '22023';
  END IF;
  IF b ? 'last_name' AND jsonb_typeof(b->'last_name') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION 'exos_fans: last_name must be text' USING ERRCODE = '22023';
  END IF;
  v_first := nullif(btrim(coalesce(b->>'first_name', '')), '');
  v_last  := nullif(btrim(coalesce(b->>'last_name', '')), '');
  IF length(v_first) > 60 OR length(v_last) > 60 THEN
    RAISE EXCEPTION 'exos_fans: names are at most 60 characters' USING ERRCODE = '22023';
  END IF;

  IF v_id IS NULL THEN
    v_email := public._exos_fan_email(b->>'email');
    IF v_email IS NULL THEN
      RAISE EXCEPTION 'exos_fans: a valid email is required' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.exos_fans WHERE org_id = p_org_id AND email = v_email AND discarded_at IS NULL) THEN
      RAISE EXCEPTION 'exos_fans: a fan with this email already exists' USING ERRCODE = '23505';
    END IF;
    IF (SELECT count(*) FROM public.exos_fans WHERE org_id = p_org_id AND source IN ('manual', 'api')
          AND created_at > now() - interval '1 day') >= 1000 THEN
      RAISE EXCEPTION 'exos_fans: at most 1000 fans added by hand a day' USING ERRCODE = '54000';
    END IF;
    v_id := public._exos_fan_touch(p_org_id, v_email, NULL, CASE WHEN p_source = 'api' THEN 'api' ELSE 'manual' END, v_first, v_last, NULL);
    -- A revived profile takes the names given now.
    UPDATE public.exos_fans SET first_name = coalesce(v_first, first_name), last_name = coalesce(v_last, last_name)
     WHERE id = v_id;
  ELSE
    IF b ? 'email' AND public._exos_fan_email(b->>'email') IS DISTINCT FROM
         (SELECT email FROM public.exos_fans WHERE id = v_id AND org_id = p_org_id) THEN
      RAISE EXCEPTION 'exos_fans: a fan''s email can''t be changed' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_fans
       SET first_name = CASE WHEN b ? 'first_name' THEN v_first ELSE first_name END,
           last_name  = CASE WHEN b ? 'last_name' THEN v_last ELSE last_name END
     WHERE id = v_id AND org_id = p_org_id AND discarded_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_fans: fan not found' USING ERRCODE = 'P0002'; END IF;
  END IF;
  RETURN public._exos_fan_detail(p_org_id, v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_fan_save(uuid, uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fan_save(uuid, uuid, jsonb, text) TO service_role;

-- Soft delete: hidden from lists and exports, names scrubbed, tags removed.
-- Orders stay (they are the org's records); consent stays as the fan left it.
CREATE OR REPLACE FUNCTION public._exos_fan_discard(p_org_id uuid, p_fan_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_fans SET discarded_at = now(), first_name = NULL, last_name = NULL
   WHERE id = p_fan_id AND org_id = p_org_id AND discarded_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'exos_fans: fan not found' USING ERRCODE = 'P0002'; END IF;
  DELETE FROM public.exos_tagged_items WHERE org_id = p_org_id AND taggable_type = 'fan' AND taggable_id = p_fan_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_fan_discard(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fan_discard(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_org_fan_save(p_org_id uuid, p_fan_id uuid, p_fields jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_org_fan_save: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_fan_save(p_org_id, p_fan_id, p_fields, 'manual');
END $$;
REVOKE ALL ON FUNCTION public.exos_org_fan_save(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_fan_save(uuid, uuid, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_org_fan_discard(p_org_id uuid, p_fan_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_org_fan_discard: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_fan_discard(p_org_id, p_fan_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_fan_discard(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_fan_discard(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Tags
-- ---------------------------------------------------------------------------
-- p_fields: name, scope ('event' | 'fan' | 'artist' | null), color (#rrggbb |
-- null), canonical_tag_id. On update, only the keys given change; the scope
-- can't narrow below what the tag is already on.
CREATE OR REPLACE FUNCTION public._exos_tag_save(p_org_id uuid, p_tag_id uuid, p_fields jsonb, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  b       jsonb := CASE WHEN jsonb_typeof(p_fields) = 'object' THEN p_fields ELSE '{}'::jsonb END;
  t       public.exos_tags%ROWTYPE;
  v_name  text;
  v_scope text;
  v_color text;
  v_canon text;
BEGIN
  IF p_tag_id IS NOT NULL THEN
    SELECT * INTO t FROM public.exos_tags WHERE id = p_tag_id AND org_id = p_org_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_tags: tag not found' USING ERRCODE = 'P0002'; END IF;
  END IF;
  v_name  := CASE WHEN b ? 'name' THEN btrim(coalesce(b->>'name', '')) ELSE t.name END;
  v_scope := CASE WHEN b ? 'scope' THEN nullif(btrim(coalesce(b->>'scope', '')), '') ELSE t.scope END;
  v_color := CASE WHEN b ? 'color' THEN nullif(btrim(coalesce(b->>'color', '')), '') ELSE t.color END;
  v_canon := CASE WHEN b ? 'canonical_tag_id' THEN nullif(btrim(coalesce(b->>'canonical_tag_id', '')), '') ELSE t.canonical_tag_id END;
  IF v_name IS NULL AND v_canon IS NOT NULL THEN
    SELECT c.name INTO v_name FROM public.exos_canonical_tags c WHERE c.id = v_canon;
  END IF;
  IF coalesce(length(v_name), 0) NOT BETWEEN 1 AND 40 THEN
    RAISE EXCEPTION 'exos_tags: a tag name is 1 to 40 characters' USING ERRCODE = '22023';
  END IF;
  IF v_scope IS NOT NULL AND v_scope NOT IN ('event', 'fan', 'artist') THEN
    RAISE EXCEPTION 'exos_tags: scope must be event, fan or artist (or empty for any)' USING ERRCODE = '22023';
  END IF;
  IF v_color IS NOT NULL AND v_color !~ '^#[0-9a-fA-F]{6}$' THEN
    RAISE EXCEPTION 'exos_tags: color must look like #1a2b3c' USING ERRCODE = '22023';
  END IF;
  IF v_canon IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_canonical_tags WHERE id = v_canon) THEN
    RAISE EXCEPTION 'exos_tags: unknown canonical tag' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_tags x WHERE x.org_id = p_org_id AND lower(x.name) = lower(v_name)
               AND coalesce(x.scope, '') = coalesce(v_scope, '') AND x.id IS DISTINCT FROM p_tag_id) THEN
    RAISE EXCEPTION 'exos_tags: a tag with this name already exists' USING ERRCODE = '23505';
  END IF;
  IF p_tag_id IS NULL THEN
    IF (SELECT count(*) FROM public.exos_tags WHERE org_id = p_org_id) >= 500 THEN
      RAISE EXCEPTION 'exos_tags: at most 500 tags per organization' USING ERRCODE = '54000';
    END IF;
    INSERT INTO public.exos_tags (org_id, name, scope, color, canonical_tag_id, created_by)
    VALUES (p_org_id, v_name, v_scope, v_color, v_canon, p_actor)
    RETURNING * INTO t;
  ELSE
    IF v_scope IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_tagged_items i
                                        WHERE i.tag_id = p_tag_id AND i.taggable_type <> v_scope) THEN
      RAISE EXCEPTION 'exos_tags: this tag is on other kinds of records; remove it from them first' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_tags SET name = v_name, scope = v_scope, color = v_color, canonical_tag_id = v_canon
     WHERE id = p_tag_id
    RETURNING * INTO t;
  END IF;
  RETURN jsonb_build_object('id', t.id, 'name', t.name, 'scope', t.scope, 'color', t.color,
                            'canonical_tag_id', t.canonical_tag_id, 'created_at', t.created_at, 'updated_at', t.updated_at,
                            'items_count', (SELECT count(*) FROM public.exos_tagged_items i WHERE i.tag_id = t.id));
END $$;
REVOKE ALL ON FUNCTION public._exos_tag_save(uuid, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tag_save(uuid, uuid, jsonb, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_tag_delete(p_org_id uuid, p_tag_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  DELETE FROM public.exos_tags WHERE id = p_tag_id AND org_id = p_org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'exos_tags: tag not found' USING ERRCODE = 'P0002'; END IF;
  -- Signup forms stop applying it.
  UPDATE public.exos_signup_forms SET default_tag_ids = array_remove(default_tag_ids, p_tag_id)
   WHERE org_id = p_org_id AND p_tag_id = ANY (default_tag_ids);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_tag_delete(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tag_delete(uuid, uuid) TO service_role;

-- Tag a record: by tag id, or by name (made on the fly, scoped to the
-- record's type). Idempotent: tagging twice returns the same item.
CREATE OR REPLACE FUNCTION public._exos_tag_apply(
  p_org_id uuid, p_tag_id uuid, p_tag_name text, p_type text, p_id uuid, p_actor uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tag uuid := p_tag_id; v_item uuid; v_new boolean := false; v_name text := btrim(coalesce(p_tag_name, ''));
BEGIN
  IF p_type IS NULL OR p_type NOT IN ('event', 'fan', 'artist') THEN
    RAISE EXCEPTION 'exos_tags: taggable_type must be event, fan or artist' USING ERRCODE = '22023';
  END IF;
  IF p_id IS NULL THEN RAISE EXCEPTION 'exos_tags: say which record' USING ERRCODE = '22023'; END IF;
  IF v_tag IS NULL THEN
    IF v_name = '' THEN RAISE EXCEPTION 'exos_tags: give a tag id or a tag name' USING ERRCODE = '22023'; END IF;
    SELECT t.id INTO v_tag FROM public.exos_tags t
     WHERE t.org_id = p_org_id AND lower(t.name) = lower(v_name) AND (t.scope IS NULL OR t.scope = p_type)
     ORDER BY (t.scope IS NULL) LIMIT 1;
    IF v_tag IS NULL THEN
      v_tag := (public._exos_tag_save(p_org_id, NULL, jsonb_build_object('name', v_name, 'scope', p_type), p_actor)->>'id')::uuid;
    END IF;
  ELSIF NOT EXISTS (SELECT 1 FROM public.exos_tags WHERE id = v_tag AND org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_tags: tag not found' USING ERRCODE = 'P0002';
  END IF;
  IF (SELECT count(*) FROM public.exos_tagged_items WHERE org_id = p_org_id AND taggable_type = p_type AND taggable_id = p_id) >= 50 THEN
    RAISE EXCEPTION 'exos_tags: at most 50 tags on one record' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_tagged_items (org_id, tag_id, taggable_type, taggable_id, created_by)
  VALUES (p_org_id, v_tag, p_type, p_id, p_actor)
  ON CONFLICT (tag_id, taggable_type, taggable_id) DO NOTHING
  RETURNING id INTO v_item;
  IF v_item IS NULL THEN
    SELECT id INTO v_item FROM public.exos_tagged_items WHERE tag_id = v_tag AND taggable_type = p_type AND taggable_id = p_id;
  ELSE
    v_new := true;
  END IF;
  RETURN jsonb_build_object('id', v_item, 'tag_id', v_tag, 'taggable_type', p_type, 'taggable_id', p_id, 'created', v_new);
END $$;
REVOKE ALL ON FUNCTION public._exos_tag_apply(uuid, uuid, text, text, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tag_apply(uuid, uuid, text, text, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_tagged_item_delete(p_org_id uuid, p_item_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  DELETE FROM public.exos_tagged_items WHERE id = p_item_id AND org_id = p_org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'exos_tags: tagged item not found' USING ERRCODE = 'P0002'; END IF;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_tagged_item_delete(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tagged_item_delete(uuid, uuid) TO service_role;

-- Staff wrappers. Read: owner / manager / finance / content. Write: owner / manager.
CREATE OR REPLACE FUNCTION public.exos_org_tags(p_org_id uuid, p_scope text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager','finance','content']) THEN
    RAISE EXCEPTION 'exos_org_tags: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', t.id, 'name', t.name, 'scope', t.scope, 'color', t.color, 'canonical_tag_id', t.canonical_tag_id,
            'items_count', (SELECT count(*) FROM public.exos_tagged_items i WHERE i.tag_id = t.id),
            'created_at', t.created_at, 'updated_at', t.updated_at) ORDER BY lower(t.name), t.id), '[]'::jsonb)
            FROM public.exos_tags t
           WHERE t.org_id = p_org_id AND (p_scope IS NULL OR t.scope IS NULL OR t.scope = p_scope));
END $$;
REVOKE ALL ON FUNCTION public.exos_org_tags(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_tags(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_tag_save(p_org_id uuid, p_tag_id uuid, p_fields jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_tag_save: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_tag_save(p_org_id, p_tag_id, p_fields, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_tag_save(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_tag_save(uuid, uuid, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_tag_delete(p_org_id uuid, p_tag_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_tag_delete: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_tag_delete(p_org_id, p_tag_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_tag_delete(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_tag_delete(uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_tag_apply(p_org_id uuid, p_tag_id uuid, p_tag_name text, p_type text, p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_tag_apply: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_tag_apply(p_org_id, p_tag_id, p_tag_name, p_type, p_id, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_tag_apply(uuid, uuid, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_tag_apply(uuid, uuid, text, text, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_tag_remove(p_org_id uuid, p_tagged_item_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_tag_remove: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_tagged_item_delete(p_org_id, p_tagged_item_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_tag_remove(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_tag_remove(uuid, uuid) TO authenticated, service_role;

-- The tags on these records (for chips next to events / artists / fans).
CREATE OR REPLACE FUNCTION public.exos_org_tagged(p_org_id uuid, p_type text, p_ids uuid[])
RETURNS TABLE (taggable_id uuid, tagged_item_id uuid, tag_id uuid, name text, color text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager','finance','content']) THEN
    RAISE EXCEPTION 'exos_org_tagged: not authorized' USING ERRCODE = '42501';
  END IF;
  IF coalesce(cardinality(p_ids), 0) > 1000 THEN
    RAISE EXCEPTION 'exos_org_tagged: at most 1000 records' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
    SELECT i.taggable_id, i.id, t.id, t.name, t.color
      FROM public.exos_tagged_items i JOIN public.exos_tags t ON t.id = i.tag_id
     WHERE i.org_id = p_org_id AND i.taggable_type = p_type AND i.taggable_id = ANY (coalesce(p_ids, '{}'::uuid[]))
     ORDER BY i.taggable_id, lower(t.name);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_tagged(uuid, text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_tagged(uuid, text, uuid[]) TO authenticated, service_role;

-- Filter: the ids of this type carrying ALL of these tags.
CREATE OR REPLACE FUNCTION public.exos_org_tag_filter(p_org_id uuid, p_type text, p_tag_ids uuid[])
RETURNS uuid[]
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tags uuid[] := (SELECT array_agg(DISTINCT t) FROM unnest(coalesce(p_tag_ids, '{}'::uuid[])) t WHERE t IS NOT NULL);
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager','finance','content']) THEN
    RAISE EXCEPTION 'exos_org_tag_filter: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_tags IS NULL THEN RETURN NULL; END IF;
  RETURN (SELECT coalesce(array_agg(x.taggable_id), '{}'::uuid[]) FROM (
            SELECT i.taggable_id FROM public.exos_tagged_items i
             WHERE i.org_id = p_org_id AND i.taggable_type = p_type AND i.tag_id = ANY (v_tags)
             GROUP BY i.taggable_id HAVING count(DISTINCT i.tag_id) = cardinality(v_tags)) x);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_tag_filter(uuid, text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_tag_filter(uuid, text, uuid[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Signup forms (staff)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_signup_forms_list(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_signup_forms_list: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', f.id, 'name', f.name, 'title', f.title, 'intro', f.intro, 'button_label', f.button_label,
            'ask_name', f.ask_name, 'offer_sms', f.offer_sms, 'default_tag_ids', to_jsonb(f.default_tag_ids),
            'status', f.status, 'created_at', f.created_at, 'updated_at', f.updated_at,
            'submissions', (SELECT count(*) FROM public.exos_signup_submissions s WHERE s.form_id = f.id),
            'confirmed', (SELECT count(*) FROM public.exos_signup_submissions s WHERE s.form_id = f.id AND s.confirmed_at IS NOT NULL))
            ORDER BY f.created_at DESC), '[]'::jsonb)
            FROM public.exos_signup_forms f WHERE f.org_id = p_org_id AND f.status <> 'archived');
END $$;
REVOKE ALL ON FUNCTION public.exos_signup_forms_list(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_signup_forms_list(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_signup_form_save(p_org_id uuid, p_form_id uuid, p_fields jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  b       jsonb := CASE WHEN jsonb_typeof(p_fields) = 'object' THEN p_fields ELSE '{}'::jsonb END;
  f       public.exos_signup_forms%ROWTYPE;
  v_tags  uuid[];
  v_id    uuid;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_signup_form_save: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF p_form_id IS NOT NULL THEN
    SELECT * INTO f FROM public.exos_signup_forms WHERE id = p_form_id AND org_id = p_org_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_signup_form_save: form not found' USING ERRCODE = 'P0002'; END IF;
  ELSIF (SELECT count(*) FROM public.exos_signup_forms WHERE org_id = p_org_id AND status <> 'archived') >= 50 THEN
    RAISE EXCEPTION 'exos_signup_form_save: at most 50 forms' USING ERRCODE = '54000';
  END IF;
  IF b ? 'default_tag_ids' THEN
    IF jsonb_typeof(b->'default_tag_ids') <> 'array' THEN
      RAISE EXCEPTION 'exos_signup_form_save: default_tag_ids must be a list' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(array_agg(DISTINCT x::uuid), '{}') INTO v_tags FROM jsonb_array_elements_text(b->'default_tag_ids') x;
    IF cardinality(v_tags) > 10 THEN
      RAISE EXCEPTION 'exos_signup_form_save: at most 10 tags' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(v_tags) t WHERE NOT EXISTS (
                 SELECT 1 FROM public.exos_tags x WHERE x.id = t AND x.org_id = p_org_id AND (x.scope IS NULL OR x.scope = 'fan'))) THEN
      RAISE EXCEPTION 'exos_signup_form_save: pick fan tags of this organization' USING ERRCODE = '22023';
    END IF;
  ELSE
    v_tags := coalesce(f.default_tag_ids, '{}');
  END IF;
  f.name         := CASE WHEN b ? 'name' THEN btrim(coalesce(b->>'name', '')) ELSE f.name END;
  f.title        := CASE WHEN b ? 'title' THEN btrim(coalesce(b->>'title', '')) ELSE f.title END;
  f.intro        := CASE WHEN b ? 'intro' THEN nullif(btrim(coalesce(b->>'intro', '')), '') ELSE f.intro END;
  f.button_label := CASE WHEN b ? 'button_label' THEN nullif(btrim(coalesce(b->>'button_label', '')), '') ELSE f.button_label END;
  f.ask_name     := CASE WHEN b ? 'ask_name' THEN coalesce((b->>'ask_name')::boolean, true) ELSE coalesce(f.ask_name, true) END;
  f.offer_sms    := CASE WHEN b ? 'offer_sms' THEN coalesce((b->>'offer_sms')::boolean, false) ELSE coalesce(f.offer_sms, false) END;
  f.status       := CASE WHEN b ? 'status' THEN b->>'status' ELSE coalesce(f.status, 'active') END;
  IF coalesce(length(f.name), 0) NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'exos_signup_form_save: give the form a name (up to 80 characters)' USING ERRCODE = '22023';
  END IF;
  IF coalesce(length(f.title), 0) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'exos_signup_form_save: the title is 1 to 120 characters' USING ERRCODE = '22023';
  END IF;
  IF length(f.intro) > 500 OR length(f.button_label) > 40 THEN
    RAISE EXCEPTION 'exos_signup_form_save: intro up to 500 characters, button up to 40' USING ERRCODE = '22023';
  END IF;
  IF f.status NOT IN ('active', 'paused', 'archived') THEN
    RAISE EXCEPTION 'exos_signup_form_save: status must be active, paused or archived' USING ERRCODE = '22023';
  END IF;
  IF p_form_id IS NULL THEN
    INSERT INTO public.exos_signup_forms (org_id, name, title, intro, button_label, ask_name, offer_sms, default_tag_ids, status, created_by)
    VALUES (p_org_id, f.name, f.title, f.intro, f.button_label, f.ask_name, f.offer_sms, v_tags, f.status, auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.exos_signup_forms
       SET name = f.name, title = f.title, intro = f.intro, button_label = f.button_label, ask_name = f.ask_name,
           offer_sms = f.offer_sms, default_tag_ids = v_tags, status = f.status
     WHERE id = p_form_id
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_signup_form_save(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_signup_form_save(uuid, uuid, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 11. Signup forms (public)
-- ---------------------------------------------------------------------------
-- The SMS consent wording. Must stay identical to consentText() in
-- src/lib/sms.ts (the ticket-page opt-in); src/lib/signupForms.test.ts checks.
CREATE OR REPLACE FUNCTION public.exos_sms_consent_text(p_org_name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT 'Text me about ' || coalesce(p_org_name, '') || '''s events at this number. Up to 8 msgs/month. Msg & data rates may apply. '
         || 'Reply STOP to cancel, HELP for help. Consent is not a condition of purchase.'
$$;
GRANT EXECUTE ON FUNCTION public.exos_sms_consent_text(text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_signup_email_consent_text(p_org_name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT 'Email me news and events from ' || coalesce(p_org_name, '') || '. I can unsubscribe at any time.'
$$;
GRANT EXECUTE ON FUNCTION public.exos_signup_email_consent_text(text) TO anon, authenticated, service_role;

-- What the embed renders. Active forms only; nothing about any fan.
CREATE OR REPLACE FUNCTION public.exos_signup_form_public(p_form_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
           'id', f.id, 'org_name', o.name, 'title', f.title, 'intro', f.intro,
           'button_label', coalesce(f.button_label, 'Sign up'), 'ask_name', f.ask_name, 'offer_sms', f.offer_sms,
           'email_consent_text', public.exos_signup_email_consent_text(o.name),
           'sms_consent_text', CASE WHEN f.offer_sms THEN public.exos_sms_consent_text(o.name) END)
    FROM public.exos_signup_forms f
    JOIN public.exos_orgs o ON o.id = f.org_id
   WHERE f.id = p_form_id AND f.status = 'active'
$$;
REVOKE ALL ON FUNCTION public.exos_signup_form_public(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_signup_form_public(uuid) TO anon, authenticated, service_role;

-- The submission (exos-signup edge function, service role). Always answers
-- the same {ok: true, status: 'check_email'}, whether a mail was queued, the
-- address was already on the list or a throttle held it back: nothing about
-- the fan. Bad input raises 22023 (the function answers 422).
CREATE OR REPLACE FUNCTION public._exos_signup_submit(
  p_form_id uuid, p_email text, p_first text DEFAULT NULL, p_last text DEFAULT NULL,
  p_email_opt_in boolean DEFAULT true, p_sms_opt_in boolean DEFAULT false, p_phone text DEFAULT NULL,
  p_ip_hash text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  fo       public.exos_signup_forms%ROWTYPE;
  v_org    text;
  v_email  text := public._exos_fan_email(p_email);
  v_first  text := nullif(btrim(coalesce(p_first, '')), '');
  v_last   text := nullif(btrim(coalesce(p_last, '')), '');
  v_phone  text;
  v_fan    uuid;
  f        public.exos_fans%ROWTYPE;
  v_sms    boolean := coalesce(p_sms_opt_in, false);
  v_mail   boolean;
  v_token  text;
  v_sub    uuid;
  v_recent int;
  t        uuid;
BEGIN
  SELECT * INTO fo FROM public.exos_signup_forms WHERE id = p_form_id AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_signup: this form isn''t taking signups' USING ERRCODE = 'P0002';
  END IF;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = fo.org_id;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'exos_signup: enter a valid email address' USING ERRCODE = '22023';
  END IF;
  IF length(v_first) > 60 OR length(v_last) > 60 THEN
    RAISE EXCEPTION 'exos_signup: names are at most 60 characters' USING ERRCODE = '22023';
  END IF;
  IF NOT fo.ask_name THEN v_first := NULL; v_last := NULL; END IF;
  IF v_sms THEN
    IF NOT fo.offer_sms THEN v_sms := false;
    ELSE
      v_phone := public.exos_sms_normalize_phone(p_phone);
      IF v_phone IS NULL THEN
        RAISE EXCEPTION 'exos_signup: enter a mobile number, e.g. +1 212 555 0100' USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;
  IF NOT coalesce(p_email_opt_in, false) AND NOT v_sms THEN
    RAISE EXCEPTION 'exos_signup: choose email or texts' USING ERRCODE = '22023';
  END IF;
  IF p_ip_hash IS NOT NULL AND p_ip_hash !~ '^[0-9a-f]{64}$' THEN p_ip_hash := NULL; END IF;

  -- Per network: 20 an hour on this org's forms (the edge function also caps per minute).
  IF p_ip_hash IS NOT NULL AND (SELECT count(*) FROM public.exos_signup_submissions s
                                 WHERE s.ip_hash = p_ip_hash AND s.org_id = fo.org_id
                                   AND s.created_at > now() - interval '1 hour') >= 20 THEN
    RETURN jsonb_build_object('ok', true, 'status', 'check_email');
  END IF;

  v_fan := public._exos_fan_touch(fo.org_id, v_email, NULL, 'signup', v_first, v_last, NULL);
  SELECT * INTO f FROM public.exos_fans WHERE id = v_fan;
  -- The same address on this org: 3 submissions a day, at most.
  SELECT count(*) INTO v_recent FROM public.exos_signup_submissions s
   WHERE s.fan_id = v_fan AND s.created_at > now() - interval '1 day';
  IF v_recent >= 3 THEN
    RETURN jsonb_build_object('ok', true, 'status', 'check_email');
  END IF;

  -- Always a confirm mail (texts are confirmed from the same page), even for
  -- someone already on the list: the answer must not say who is subscribed.
  v_mail := true;
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  INSERT INTO public.exos_signup_submissions (org_id, form_id, fan_id, email_requested, email_consent_text,
                                              confirm_token_hash, confirm_sent_at, sms_requested, sms_phone,
                                              sms_consent_text, ip_hash)
  VALUES (fo.org_id, fo.id, v_fan, coalesce(p_email_opt_in, false),
          CASE WHEN coalesce(p_email_opt_in, false) THEN public.exos_signup_email_consent_text(v_org) END,
          CASE WHEN v_mail THEN encode(sha256(convert_to(v_token, 'UTF8')), 'hex') END,
          CASE WHEN v_mail THEN now() END,
          v_sms, v_phone, CASE WHEN v_sms THEN public.exos_sms_consent_text(v_org) END, p_ip_hash)
  RETURNING id INTO v_sub;

  FOREACH t IN ARRAY fo.default_tag_ids LOOP
    BEGIN
      PERFORM public._exos_tag_apply(fo.org_id, t, NULL, 'fan', v_fan, NULL);
    EXCEPTION WHEN OTHERS THEN NULL;  -- a tag deleted or re-scoped since: skip it
    END;
  END LOOP;

  PERFORM public.exos_mail_enqueue('signup-confirm', v_email,
    jsonb_build_object('org', jsonb_build_object('id', fo.org_id, 'name', v_org), 'form_title', fo.title,
                       'token', v_token, 'email_requested', coalesce(p_email_opt_in, false), 'sms_requested', v_sms),
    'signup-confirm:' || v_sub::text, NULL, false, NULL);
  RETURN jsonb_build_object('ok', true, 'status', 'check_email');
END $$;
REVOKE ALL ON FUNCTION public._exos_signup_submit(uuid, text, text, text, boolean, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_signup_submit(uuid, text, text, text, boolean, boolean, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_signup_by_token(p_token text)
RETURNS public.exos_signup_submissions
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT s.* FROM public.exos_signup_submissions s
   WHERE p_token ~ '^[0-9a-f]{64}$'
     AND s.confirm_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
     AND s.created_at > now() - interval '7 days'
$$;
REVOKE ALL ON FUNCTION public._exos_signup_by_token(text) FROM PUBLIC, anon, authenticated;

-- The fan clicked the confirm link (anon). Answers the org name and whether
-- texts are waiting for a signed-in confirm; never anything about the fan.
CREATE OR REPLACE FUNCTION public.exos_signup_confirm(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_signup_submissions%ROWTYPE; v_org text; v_already boolean;
BEGIN
  s := public._exos_signup_by_token(p_token);
  IF s.id IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = s.org_id;
  v_already := s.confirmed_at IS NOT NULL;
  IF NOT v_already THEN
    UPDATE public.exos_signup_submissions SET confirmed_at = now() WHERE id = s.id;
    IF s.email_requested THEN
      PERFORM set_config('exos.fan_consent_action', 'on', true);
      -- Already on the list: keep when and where they first joined.
      UPDATE public.exos_fans
         SET email_opt_in_source = CASE WHEN email_opt_in_at IS NOT NULL AND email_opt_out_at IS NULL
                                        THEN email_opt_in_source ELSE 'signup_form:' || s.form_id::text END,
             email_opt_in_at     = CASE WHEN email_opt_in_at IS NOT NULL AND email_opt_out_at IS NULL
                                        THEN email_opt_in_at ELSE now() END,
             email_opt_out_at = NULL, discarded_at = NULL
       WHERE id = s.fan_id;
      PERFORM set_config('exos.fan_consent_action', '', true);
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'org_name', v_org, 'already', v_already,
                            'email', s.email_requested,
                            'sms_pending', s.sms_requested AND s.sms_confirmed_at IS NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_signup_confirm(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_signup_confirm(text) TO anon, authenticated, service_role;

-- Texts from a signup: the fan, signed in, confirms the number they gave with
-- the wording they saw (the exos_sms_opt_in rule: signed in only).
CREATE OR REPLACE FUNCTION public.exos_signup_confirm_sms(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_signup_submissions%ROWTYPE; v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_signup_confirm_sms: sign in first' USING ERRCODE = '42501';
  END IF;
  s := public._exos_signup_by_token(p_token);
  IF s.id IS NULL OR NOT s.sms_requested OR s.sms_phone IS NULL OR s.confirmed_at IS NULL THEN
    RAISE EXCEPTION 'exos_signup_confirm_sms: this link has expired' USING ERRCODE = 'P0002';
  END IF;
  IF s.sms_confirmed_at IS NULL THEN
    IF (SELECT count(*) FROM public.exos_sms_subscribers WHERE user_id = v_uid AND updated_at > now() - interval '1 day') >= 10 THEN
      RAISE EXCEPTION 'exos_signup_confirm_sms: too many sign-ups today' USING ERRCODE = '54000';
    END IF;
    INSERT INTO public.exos_sms_subscribers AS x (org_id, phone, user_id, source, event_id, consent_text, consented_at, opted_out_at, updated_at)
    VALUES (s.org_id, s.sms_phone, v_uid, 'signup_form', NULL, s.sms_consent_text, now(), NULL, now())
    ON CONFLICT (org_id, phone) DO UPDATE
       SET user_id = EXCLUDED.user_id, source = EXCLUDED.source, consent_text = EXCLUDED.consent_text,
           consented_at = now(), opted_out_at = NULL, updated_at = now();
    UPDATE public.exos_signup_submissions SET sms_confirmed_at = now() WHERE id = s.id;
  END IF;
  RETURN jsonb_build_object('subscribed', true, 'phone_hint', '…' || right(s.sms_phone, 4));
END $$;
REVOKE ALL ON FUNCTION public.exos_signup_confirm_sms(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_signup_confirm_sms(text) TO authenticated, service_role;

-- Leave the org's email list (anon, the fan's 64-hex unsubscribe token).
CREATE OR REPLACE FUNCTION public.exos_signup_unsubscribe(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_fan uuid; v_org uuid;
BEGIN
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('ok', false); END IF;
  SELECT id, org_id INTO v_fan, v_org FROM public.exos_fans WHERE unsubscribe_token = p_token;
  IF v_fan IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;
  PERFORM set_config('exos.fan_consent_action', 'on', true);
  UPDATE public.exos_fans SET email_opt_out_at = coalesce(email_opt_out_at, now()) WHERE id = v_fan;
  PERFORM set_config('exos.fan_consent_action', '', true);
  RETURN jsonb_build_object('ok', true, 'org_name', (SELECT name FROM public.exos_orgs WHERE id = v_org));
END $$;
REVOKE ALL ON FUNCTION public.exos_signup_unsubscribe(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_signup_unsubscribe(text) TO anon, authenticated, service_role;

-- Sweep: the number and its wording go after 30 days unconfirmed.
CREATE OR REPLACE FUNCTION public.exos_signup_sweep()
RETURNS int
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH u AS (
    UPDATE public.exos_signup_submissions
       SET sms_phone = NULL, sms_consent_text = NULL
     WHERE sms_confirmed_at IS NULL AND sms_phone IS NOT NULL AND created_at < now() - interval '30 days'
    RETURNING 1)
  SELECT count(*)::int FROM u
$$;
REVOKE ALL ON FUNCTION public.exos_signup_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_signup_sweep() TO service_role;

-- ---------------------------------------------------------------------------
-- 12. Mail: 'signup-confirm' (allowlist = live list ∪ last known ∪ new)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['signup-confirm'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF strpos(coalesce(v_def, ''), '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live
      FROM regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN
    RETURN;
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION
    SELECT unnest(ARRAY[
      'transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled',
      'event-reminder','order-failed','checkout-abandoned','marketplace-attention',
      'event-published','inventory-low','inventory-sold-out','payout-sent',
      'payout-pending','fee-free-ending','org-welcome','org-first-event',
      'org-connect-stripe','org-sales-digest','org-weekly-summary',
      'refund-issued','post-event','dispute-opened','dispute-won','dispute-lost'] || v_new)
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- ---------------------------------------------------------------------------
-- 13. Fan export (owner / manager, logged)
-- ---------------------------------------------------------------------------
-- Rows: email, names, account yes/no, source, orders, first / last order,
-- email-list state, tag names, created. No unsubscribe token, no phone.
CREATE OR REPLACE FUNCTION public.exos_org_fans_export(p_org_id uuid, p_search text DEFAULT NULL, p_tag_ids uuid[] DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_page jsonb; v_rows jsonb; v_n int;
BEGIN
  IF v_uid IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_org_fans_export: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF to_regprocedure('public.exos_rate_hit(text,integer)') IS NOT NULL
     AND NOT public.exos_rate_hit('fans-export:' || p_org_id::text, 3) THEN
    RAISE EXCEPTION 'exos_org_fans_export: too many exports, try again in a minute' USING ERRCODE = '54000';
  END IF;
  IF (SELECT count(*) FROM public.exos_fan_exports x WHERE x.org_id = p_org_id AND x.created_at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION 'exos_org_fans_export: daily export limit reached (20 per organization)' USING ERRCODE = '54000';
  END IF;
  v_page := public._exos_fans_page(p_org_id, p_search, NULL, p_tag_ids, NULL, 'email asc', 100000, 0);
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'email', r->'email', 'first_name', r->'first_name', 'last_name', r->'last_name',
           'has_account', r->'has_account', 'source', r->'source', 'orders_count', r->'orders_count',
           'first_order_at', r->'first_order_at', 'last_order_at', r->'last_order_at', 'email_list', r->'email_list',
           'tags', (SELECT coalesce(jsonb_agg(t->'name'), '[]'::jsonb) FROM jsonb_array_elements(r->'tags') t),
           'created_at', r->'created_at')), '[]'::jsonb)
    INTO v_rows
    FROM jsonb_array_elements(v_page->'rows') r;
  v_n := jsonb_array_length(v_rows);
  INSERT INTO public.exos_fan_exports (org_id, exported_by, filters, row_count)
  VALUES (p_org_id, v_uid, jsonb_strip_nulls(jsonb_build_object('search', nullif(btrim(coalesce(p_search, '')), ''),
                                                                'tag_ids', to_jsonb(p_tag_ids))), v_n);
  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_fans_export(uuid, text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_fans_export(uuid, text, uuid[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 14. Refund requests: the org queue, the fan's list, the API read
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_refund_asks_page(
  p_org_id uuid, p_status text DEFAULT 'open', p_event_id uuid DEFAULT NULL, p_limit int DEFAULT 50, p_offset int DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_total int; v_rows jsonb;
        v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200);
        v_off int := least(greatest(coalesce(p_offset, 0), 0), 2000000);
BEGIN
  IF p_status IS NOT NULL AND p_status NOT IN ('open', 'refunded', 'declined', 'withdrawn') THEN
    RAISE EXCEPTION 'exos_refund_asks: status must be open, refunded, declined or withdrawn' USING ERRCODE = '22023';
  END IF;
  SELECT count(*) INTO v_total FROM public.exos_refund_asks a
   WHERE a.org_id = p_org_id AND (p_status IS NULL OR a.status = p_status) AND (p_event_id IS NULL OR a.event_id = p_event_id);
  SELECT coalesce(jsonb_agg(x.j ORDER BY x.created_at DESC, x.id), '[]'::jsonb) INTO v_rows FROM (
    SELECT a.id, a.created_at, jsonb_build_object(
             'id', a.id, 'ticket_id', a.ticket_id, 'event_id', a.event_id, 'event_name', e.name, 'starts_at', e.starts_at,
             'tier_name', tk.tier_name, 'session_id', a.session_id,
             'buyer_email', coalesce(nullif(cs.buyer_email, ''), (SELECT u.email::text FROM auth.users u WHERE u.id = a.asked_by)),
             'reason', a.reason, 'amount_cents', a.amount_cents, 'currency', a.currency, 'status', a.status,
             'decline_note', a.decline_note, 'created_at', a.created_at, 'decided_at', a.decided_at,
             'ticket_status', tk.status, 'checked_in', tk.check_in_at IS NOT NULL) AS j
      FROM public.exos_refund_asks a
      JOIN public.exos_tickets tk ON tk.id = a.ticket_id
      JOIN public.exos_events e ON e.id = a.event_id
      LEFT JOIN public.exos_checkout_sessions cs ON cs.session_id = a.session_id
     WHERE a.org_id = p_org_id AND (p_status IS NULL OR a.status = p_status) AND (p_event_id IS NULL OR a.event_id = p_event_id)
     ORDER BY a.created_at DESC, a.id
     LIMIT v_lim OFFSET v_off) x;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public._exos_refund_asks_page(uuid, text, uuid, int, int) FROM PUBLIC, anon, authenticated;

-- Staff queue across events: owner / manager / finance (as on the event report).
CREATE OR REPLACE FUNCTION public.exos_org_refund_asks(
  p_org_id uuid, p_status text DEFAULT 'open', p_limit int DEFAULT 50, p_offset int DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager','finance']) THEN
    RAISE EXCEPTION 'exos_org_refund_asks: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_refund_asks_page(p_org_id, p_status, NULL, p_limit, p_offset);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_refund_asks(uuid, text, int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_refund_asks(uuid, text, int, int) TO authenticated, service_role;

-- Partner API read (orders:read), explicit org.
CREATE OR REPLACE FUNCTION public.exos_api_refund_asks(
  p_org_id uuid, p_status text DEFAULT NULL, p_event_id uuid DEFAULT NULL, p_limit int DEFAULT 50, p_offset int DEFAULT 0
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public._exos_refund_asks_page(p_org_id, p_status, p_event_id, p_limit, p_offset) $$;
REVOKE ALL ON FUNCTION public.exos_api_refund_asks(uuid, text, uuid, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_refund_asks(uuid, text, uuid, int, int) TO service_role;

-- The fan's asks, every event (My Tickets).
CREATE OR REPLACE FUNCTION public.exos_my_refund_asks_all()
RETURNS TABLE (ask_id uuid, ticket_id uuid, event_id uuid, event_name text, starts_at timestamptz, tier_name text,
               amount_cents int, currency text, status text, decline_note text, created_at timestamptz, decided_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT a.id, a.ticket_id, a.event_id, e.name, e.starts_at, tk.tier_name, a.amount_cents, a.currency, a.status,
         a.decline_note, a.created_at, a.decided_at
    FROM public.exos_refund_asks a
    JOIN public.exos_events e ON e.id = a.event_id
    JOIN public.exos_tickets tk ON tk.id = a.ticket_id
   WHERE auth.uid() IS NOT NULL AND a.asked_by = auth.uid()
   ORDER BY (a.status = 'open') DESC, a.created_at DESC
   LIMIT 200
$$;
REVOKE ALL ON FUNCTION public.exos_my_refund_asks_all() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_my_refund_asks_all() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 15. Partner API scopes: + fans:read, fans:write
-- ---------------------------------------------------------------------------
-- Same list as SCOPES in supabase/functions/_shared/api/scopes.ts
-- (src/lib/apiScopes.test.ts reads the latest definition). Fan profiles,
-- signup forms and fan tags are personal data with their own scope; the
-- legacy `read` covers fans:read like every :read (those keys already read
-- buyer emails through orders:read).
CREATE OR REPLACE FUNCTION public.exos_api_scope_names()
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY[
    'events:read', 'events:write', 'orders:read', 'fans:read', 'fans:write', 'tickets:read', 'tickets:write',
    'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
    'commerce:read', 'commerce:write', 'webhooks:read', 'webhooks:write', 'org:admin'
  ]::text[]
$$;
REVOKE ALL ON FUNCTION public.exos_api_scope_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_api_scope_names() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 16. Fan app: my tickets grouped by event (Opendate ticket_bundles)
-- ---------------------------------------------------------------------------
-- Never the barcode secret: the ticket page fetches its rotating code itself.
CREATE OR REPLACE FUNCTION public.exos_my_ticket_bundles(p_event_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(b.j ORDER BY b.starts_at NULLS LAST, b.event_id), '[]'::jsonb)
    FROM (
      SELECT e.id AS event_id, e.starts_at,
             jsonb_build_object(
               'event', jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'starts_at', e.starts_at,
                                           'doors_at', e.doors_at, 'timezone', e.timezone, 'venue_name', e.venue_name,
                                           'venue_location', e.venue_location, 'status', e.status,
                                           'org_id', e.org_id),
               'count', count(*),
               'tickets', jsonb_agg(jsonb_build_object('id', t.id, 'tier_name', t.tier_name, 'status', t.status,
                                                       'checked_in', t.check_in_at IS NOT NULL,
                                                       'in_transfer', t.pending_transfer_id IS NOT NULL)
                                    ORDER BY t.created_at, t.id)) AS j
        FROM public.exos_tickets t
        JOIN public.exos_events e ON e.id = t.event_id
       WHERE auth.uid() IS NOT NULL AND t.owner_id = auth.uid()
         AND t.status IN ('active', 'used')
         AND (p_event_id IS NULL OR t.event_id = p_event_id)
       GROUP BY e.id
    ) b
$$;
REVOKE ALL ON FUNCTION public.exos_my_ticket_bundles(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_my_ticket_bundles(uuid) TO authenticated, service_role;
