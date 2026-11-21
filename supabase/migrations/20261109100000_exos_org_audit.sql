-- ============================================================================
-- Migration 20261109100000 — Exos: the org audit log (who changed what, when,
--   from where). docs/security.md "Org audit log". KANBAN "Public-sector RFP
--   readiness". Spec: R&D 2026-11-09 (pretix LogEntry as a design reference).
--
-- Branch:   claude/exos-org-audit
-- Touches:  C: TABLE exos_org_audit (append-only: UPDATE / DELETE / TRUNCATE
--              raise for the owner and the service role too; RLS: owner /
--              manager / finance of the org and platform admins read; no
--              client or service-role write grant)
--           C: FUNCTION _exos_audit (the one writer; definer; service role
--              only, never anon / authenticated), _exos_audit_actor,
--              _exos_audit_val, _exos_audit_diff, _exos_audit_scrub,
--              _exos_audit_pii_key, _exos_audit_has_pii, _exos_audit_group,
--              _exos_audit_guard, _exos_tg_audit_row (triggers)
--           C: FUNCTION exos_org_audit_list (authenticated: owner / manager /
--              finance or admin, else 42501), exos_audit_export
--              (authenticated: records an export.run the browser made)
--           C: TRIGGERS (AFTER, row) on exos_events, exos_ticket_tiers,
--              exos_quotas, exos_quota_tiers, exos_vouchers, exos_holds,
--              exos_org_memberships, exos_api_keys, exos_org_role_scopes,
--              exos_order_edits
--           W: FUNCTION exos_refund_claim, exos_decline_refund_ask,
--              _exos_fee_adjustment_add, exos_issue_comp_batch (6 args),
--              exos_ticket_print_void, _exos_pos_reverse, _exos_pos_paid_out,
--              exos_pos_close_drawer, exos_pos_recount_drawer,
--              exos_gift_card_void, exos_gift_card_reissue_code,
--              _exos_donation_offline_refund, _exos_donation_delete,
--              exos_mark_org_payout, exos_cancel_org_payout,
--              exos_instant_payout_begin, exos_settle_promoter,
--              exos_record_promoter_payout, exos_promoter_payout_cancel,
--              _exos_settlement_update / _finalize / _reopen,
--              exos_org_member_approve, exos_org_member_reject,
--              exos_set_invite_approval, exos_oauth_app_delete,
--              exos_issue_voucher, exos_set_price_steps,
--              _exos_api_price_steps_set, exos_set_channel_price,
--              exos_org_fans_export, exos_org_audience_export
--              (markers /* exos: audit <action> */, each matching once)
--           W: FUNCTION exos_set_org_comp_budget, exos_void_ticket: older
--              than 20260926, so prod's body may differ (supabase/README.md
--              rule 4): the patch is conditional and skips with a NOTICE when
--              its anchor isn't there (the Applier checks the anchors on prod)
--           R: FUNCTION exos_api_scope_names (+ audit:read, 21 scopes),
--              exos_role_token_scopes, exos_role_scope_ceiling (audit:read:
--              owner and finance)
-- Pre-reqs: 20261108100000 (money journal), 20261108110000 (DICE leftovers),
--           20261107130000 (POS terminal), 20261105120000 (print codes),
--           20261104180000 (per-role scopes), 20261105110000 (me:* scopes).
--
-- What a row holds: the org, the event when there is one, the actor (kind
-- user | api_key | oauth_app | service | cron; the API key's id, never its
-- secret; the actor's role in the org then), the action (`group.verb`), the
-- entity, the changed fields as {field: [old, new]} (a value set from nothing
-- is [null, new]), integer cents and currency for money actions, the reason
-- given, the source (dashboard | api | door | pos | webhook | system) and the
-- partner API's request id. Never card data, a buyer's email or phone, a
-- secret, a code, or a whole row: long text is shown as its length, objects
-- as "(changed)", and emails / phone numbers in short text are masked.
--
-- The actor: auth.uid() (a dashboard user, or the key creator exos_api_write
-- acts as), else an actor the caller names (the definer RPCs that take
-- p_actor). The partner API (exos-api) adds an X-Exos-Actor header
-- (api_key:<id>, pat:<id>, oauth_app:<client id>) and X-Exos-Request-Id to
-- its PostgREST calls; they are read only when the request's role is
-- service_role, so a browser can't name an actor. No actor: service, or cron
-- when pg_cron runs it.
--
-- A failure to write an audit row never blocks the action: _exos_audit (and
-- each trigger) catch it and RAISE WARNING, as the journal does.
--
-- Rows are kept for the life of the org: no foreign keys (the log outlives
-- the event, the tier, the key it names), and the retention sweep must leave
-- this table alone (docs/security.md).
--
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked
-- patches). Not applied. Prod apply needs operator OK.
-- ROLLBACK: DROP the ten audit triggers, the functions above and the table
-- (DROP TABLE needs the guard triggers dropped first); re-run each patched
-- function's latest migration; restore exos_api_scope_names /
-- exos_role_token_scopes / exos_role_scope_ceiling from 20261105110000 /
-- 20261104180000.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
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

-- The same for a function older than 20260926 (prod's body may differ):
-- absent, or its anchor missing, is a NOTICE and no patch; more than one
-- match is still an error.
CREATE OR REPLACE FUNCTION pg_temp.exos_patch_opt(p_sig text, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, audit patch "%" skipped', p_sig, p_marker;
    RETURN;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits = 0 THEN
    RAISE NOTICE '%: anchor for "%" not found (body differs), audit patch skipped', p_fn, p_marker;
    RETURN;
  END IF;
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected 1 match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ===========================================================================
-- 1. What never goes in a row
-- ===========================================================================
-- A field name that can carry a buyer's contact, card data, a secret or a
-- code: never logged, under any table.
CREATE OR REPLACE FUNCTION public._exos_audit_pii_key(p_key text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(p_key, '') ~* '(email|phone|card|secret|token|hash|password|last4|iban|routing|account_number|ssn|address|(^|_)code$|barcode)'
$$;
REVOKE ALL ON FUNCTION public._exos_audit_pii_key(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_audit_pii_key(text) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_audit_has_pii(p_changes jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN jsonb_typeof(p_changes) = 'object'
              THEN EXISTS (SELECT 1 FROM jsonb_object_keys(p_changes) k WHERE public._exos_audit_pii_key(k))
                   OR p_changes::text ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
              ELSE false END
$$;
REVOKE ALL ON FUNCTION public._exos_audit_has_pii(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_audit_has_pii(jsonb) TO service_role;

-- Short free text with emails and phone numbers masked (a refund reason, a
-- note). Ids and timestamps are left alone.
CREATE OR REPLACE FUNCTION public._exos_audit_scrub(p text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p IS NULL THEN NULL
    WHEN p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN p
    WHEN p ~ '^\d{4}-\d{2}-\d{2}([ T][0-9:.]+([+-]\d{2}(:?\d{2})?|Z)?)?$' THEN p
    ELSE regexp_replace(
           regexp_replace(p, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]', 'g'),
           '(\+\d{1,3}[\s.-]?)?\(?\d{2,4}\)?[\s.-]?\d{3}[\s.-]?\d{3,4}', '[phone]', 'g')
  END
$$;
REVOKE ALL ON FUNCTION public._exos_audit_scrub(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_audit_scrub(text) TO service_role;

-- One value as a row shows it: numbers, booleans and short strings as they
-- are (masked); long text as its length; objects and long or non-scalar
-- lists as "(changed)".
CREATE OR REPLACE FUNCTION public._exos_audit_val(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE jsonb_typeof(p)
    WHEN 'string' THEN CASE WHEN char_length(p #>> '{}') > 80
                            THEN to_jsonb('(' || char_length(p #>> '{}') || ' characters)')
                            ELSE to_jsonb(public._exos_audit_scrub(p #>> '{}')) END
    WHEN 'array' THEN CASE WHEN length(p::text) <= 160 AND p::text !~ '@'
                                AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p) e
                                                 WHERE jsonb_typeof(e) IN ('object', 'array'))
                           THEN p ELSE to_jsonb('(changed)'::text) END
    WHEN 'object' THEN to_jsonb('(changed)'::text)
    ELSE p
  END
$$;
REVOKE ALL ON FUNCTION public._exos_audit_val(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_audit_val(jsonb) TO service_role;

-- {field: [old, new]} for the fields that differ, never the skipped ones or
-- a PII-named one; p_only (when given) limits it to those fields. At most 30.
CREATE OR REPLACE FUNCTION public._exos_audit_diff(p_old jsonb, p_new jsonb, p_skip text[] DEFAULT '{}', p_only text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_object_agg(k, jsonb_build_array(public._exos_audit_val(coalesce(p_old, '{}') -> k),
                                                        public._exos_audit_val(coalesce(p_new, '{}') -> k))), '{}'::jsonb)
    FROM (SELECT k FROM (SELECT jsonb_object_keys(coalesce(p_old, '{}')) AS k
                         UNION SELECT jsonb_object_keys(coalesce(p_new, '{}'))) ks
           WHERE (coalesce(p_old, '{}') -> k) IS DISTINCT FROM (coalesce(p_new, '{}') -> k)
             AND NOT (k = ANY (coalesce(p_skip, '{}')))
             AND (p_only IS NULL OR k = ANY (p_only))
             AND NOT public._exos_audit_pii_key(k)
           ORDER BY k LIMIT 30) d
$$;
REVOKE ALL ON FUNCTION public._exos_audit_diff(jsonb, jsonb, text[], text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_audit_diff(jsonb, jsonb, text[], text[]) TO service_role;

-- The action groups the Activity page and GET /v1/audit filter on. Must
-- equal AUDIT_GROUPS in supabase/functions/_shared/api/audit.ts
-- (src/lib/orgAudit.test.ts reads this definition).
CREATE OR REPLACE FUNCTION public._exos_audit_group(p_action text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE split_part(coalesce(p_action, ''), '.', 1)
    WHEN 'event' THEN 'inventory' WHEN 'tier' THEN 'inventory' WHEN 'quota' THEN 'inventory'
    WHEN 'voucher' THEN 'inventory' WHEN 'hold' THEN 'inventory'
    WHEN 'refund' THEN 'money' WHEN 'refund_ask' THEN 'money' WHEN 'fee' THEN 'money' WHEN 'comp' THEN 'money'
    WHEN 'ticket' THEN 'money' WHEN 'order' THEN 'money' WHEN 'pos' THEN 'money' WHEN 'gift_card' THEN 'money'
    WHEN 'donation' THEN 'money' WHEN 'payout' THEN 'money' WHEN 'promoter' THEN 'money' WHEN 'settlement' THEN 'money'
    WHEN 'member' THEN 'access' WHEN 'invite' THEN 'access' WHEN 'api_key' THEN 'access'
    WHEN 'oauth_app' THEN 'access' WHEN 'role_scopes' THEN 'access'
    WHEN 'export' THEN 'data'
    ELSE 'other'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_audit_group(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_audit_group(text) TO authenticated, service_role;

-- ===========================================================================
-- 2. The table
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_org_audit (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id       uuid NOT NULL,
  event_id     uuid,
  at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor_uid    uuid,
  actor_kind   text NOT NULL CHECK (actor_kind IN ('user', 'api_key', 'oauth_app', 'service', 'cron')),
  actor_ref    text CHECK (actor_ref IS NULL OR actor_ref ~ '^[A-Za-z0-9_:.-]{1,120}$'),
  actor_role   text CHECK (actor_role IS NULL OR actor_role IN ('owner', 'manager', 'finance', 'content', 'scanner', 'platform_admin')),
  action       text NOT NULL CHECK (action ~ '^[a-z_]{2,30}\.[a-z_]{2,40}$'),
  entity_type  text NOT NULL CHECK (entity_type ~ '^[a-z_]{2,30}$'),
  entity_id    text CHECK (entity_id IS NULL OR char_length(entity_id) <= 200),
  changes      jsonb NOT NULL DEFAULT '{}'::jsonb
                 CHECK (jsonb_typeof(changes) = 'object' AND NOT public._exos_audit_has_pii(changes)),
  amount_cents bigint,
  currency     text CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
  reason       text CHECK (reason IS NULL OR char_length(reason) <= 300),
  source       text NOT NULL CHECK (source IN ('dashboard', 'api', 'door', 'pos', 'webhook', 'system')),
  request_id   text CHECK (request_id IS NULL OR request_id ~ '^[A-Za-z0-9_.:-]{1,100}$')
);
CREATE INDEX IF NOT EXISTS exos_org_audit_org_idx ON public.exos_org_audit (org_id, id DESC);
CREATE INDEX IF NOT EXISTS exos_org_audit_event_idx ON public.exos_org_audit (org_id, event_id, id DESC) WHERE event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_org_audit_actor_idx ON public.exos_org_audit (org_id, actor_uid, id DESC) WHERE actor_uid IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_org_audit_at_idx ON public.exos_org_audit (org_id, at);
COMMENT ON TABLE public.exos_org_audit IS
  'Org audit log (mig 20261109100000, docs/security.md): who changed what, when and from where. Append-only; written only by _exos_audit; kept for the life of the org (the retention sweep skips it).';

-- Append-only, for the table owner and the service role too.
CREATE OR REPLACE FUNCTION public._exos_audit_guard()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'the org audit log is append-only' USING ERRCODE = '55000';
END $$;
REVOKE ALL ON FUNCTION public._exos_audit_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_org_audit_append_only ON public.exos_org_audit;
CREATE TRIGGER exos_org_audit_append_only BEFORE UPDATE OR DELETE ON public.exos_org_audit
  FOR EACH ROW EXECUTE FUNCTION public._exos_audit_guard();
DROP TRIGGER IF EXISTS exos_org_audit_no_truncate ON public.exos_org_audit;
CREATE TRIGGER exos_org_audit_no_truncate BEFORE TRUNCATE ON public.exos_org_audit
  FOR EACH STATEMENT EXECUTE FUNCTION public._exos_audit_guard();

ALTER TABLE public.exos_org_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_org_audit FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.exos_org_audit TO authenticated, service_role;
DROP POLICY IF EXISTS exos_org_audit_sel ON public.exos_org_audit;
CREATE POLICY exos_org_audit_sel ON public.exos_org_audit FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_org_audit FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- ===========================================================================
-- 3. Who is acting
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_audit_actor(p_org uuid, p_actor uuid DEFAULT NULL, p_api_key uuid DEFAULT NULL,
                                                    p_source text DEFAULT NULL)
RETURNS TABLE (actor_uid uuid, actor_kind text, actor_ref text, actor_role text, source text, request_id text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hdr  jsonb;
  v_ctx  text;
  v_uid  uuid := coalesce(p_actor, auth.uid());
  v_kind text;
  v_ref  text;
  v_src  text;
  v_req  text;
  v_key  uuid := p_api_key;
BEGIN
  -- The partner API's context rides in request headers. Only a request made
  -- with the service role (exos-api) is believed; a browser's are ignored.
  IF coalesce(current_setting('role', true), '') = 'service_role' THEN
    BEGIN
      v_hdr := nullif(current_setting('request.headers', true), '')::jsonb;
    EXCEPTION WHEN others THEN
      v_hdr := NULL;
    END;
    IF jsonb_typeof(v_hdr) = 'object' THEN
      v_ctx := v_hdr ->> 'x-exos-actor';
      v_req := CASE WHEN (v_hdr ->> 'x-exos-request-id') ~ '^[A-Za-z0-9_.:-]{1,100}$' THEN v_hdr ->> 'x-exos-request-id' END;
      v_src := CASE WHEN v_hdr ->> 'x-exos-source' IN ('dashboard', 'api', 'door', 'pos', 'webhook', 'system')
                    THEN v_hdr ->> 'x-exos-source' END;
      IF v_uid IS NULL AND (v_hdr ->> 'x-exos-actor-uid') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        v_uid := (v_hdr ->> 'x-exos-actor-uid')::uuid;
      END IF;
    END IF;
  END IF;
  IF v_key IS NULL AND v_ctx ~* '^api_key:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    v_key := substr(v_ctx, 9)::uuid;
  END IF;
  IF v_key IS NOT NULL THEN
    v_kind := 'api_key';
    v_ref := v_key::text;
    -- The key acts as its creator (exos_api_write); only a key of this org counts.
    IF v_uid IS NULL THEN
      SELECT k.created_by INTO v_uid FROM public.exos_api_keys k WHERE k.id = v_key AND k.org_id = p_org;
    END IF;
  ELSIF v_ctx ~ '^pat:[A-Za-z0-9_.-]{1,100}$' THEN
    v_kind := 'user';
    v_ref := v_ctx;
  ELSIF v_ctx ~ '^oauth_app:[A-Za-z0-9_.-]{1,100}$' THEN
    v_kind := 'oauth_app';
    v_ref := substr(v_ctx, 11);
  ELSIF v_uid IS NOT NULL THEN
    v_kind := 'user';
  ELSIF coalesce(current_setting('application_name', true), '') ILIKE 'pg_cron%' THEN
    v_kind := 'cron';
  ELSE
    v_kind := 'service';
  END IF;
  actor_uid := v_uid;
  actor_kind := v_kind;
  actor_ref := v_ref;
  actor_role := CASE WHEN v_uid IS NULL THEN NULL ELSE public._exos_member_role(p_org, v_uid) END;
  IF actor_role IS NULL AND v_uid IS NOT NULL AND v_uid = auth.uid() AND public.exos_is_admin() THEN
    actor_role := 'platform_admin';
  END IF;
  source := coalesce(CASE WHEN p_source IN ('dashboard', 'api', 'door', 'pos', 'webhook', 'system') THEN p_source END,
                     v_src,
                     CASE WHEN v_kind IN ('api_key', 'oauth_app') OR v_ref LIKE 'pat:%' THEN 'api'
                          WHEN v_kind = 'user' THEN 'dashboard'
                          ELSE 'system' END);
  request_id := v_req;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public._exos_audit_actor(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_audit_actor(uuid, uuid, uuid, text) TO service_role;

-- ===========================================================================
-- 4. The writer
-- ===========================================================================
-- Never raises: a failure is a WARNING and the action stands.
CREATE OR REPLACE FUNCTION public._exos_audit(
  p_org uuid, p_action text, p_entity_type text, p_entity_id text,
  p_event uuid DEFAULT NULL, p_changes jsonb DEFAULT NULL, p_amount_cents bigint DEFAULT NULL,
  p_currency text DEFAULT NULL, p_reason text DEFAULT NULL, p_actor uuid DEFAULT NULL,
  p_api_key uuid DEFAULT NULL, p_source text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  a  record;
  v_changes jsonb;
  v_reason  text;
BEGIN
  IF p_org IS NULL THEN
    RETURN;
  END IF;
  BEGIN
    SELECT * INTO a FROM public._exos_audit_actor(p_org, p_actor, p_api_key, p_source);
    -- Values pass through _exos_audit_val; PII-named fields are dropped.
    SELECT coalesce(jsonb_object_agg(k, CASE WHEN jsonb_typeof(v) = 'array' AND jsonb_array_length(v) = 2
                                             THEN jsonb_build_array(public._exos_audit_val(v -> 0), public._exos_audit_val(v -> 1))
                                             ELSE public._exos_audit_val(v) END), '{}'::jsonb)
      INTO v_changes
      FROM jsonb_each(CASE WHEN jsonb_typeof(p_changes) = 'object' THEN p_changes ELSE '{}'::jsonb END) e(k, v)
     WHERE NOT public._exos_audit_pii_key(k);
    v_reason := left(public._exos_audit_scrub(nullif(btrim(regexp_replace(coalesce(p_reason, ''), '\s+', ' ', 'g')), '')), 300);
    INSERT INTO public.exos_org_audit (org_id, event_id, actor_uid, actor_kind, actor_ref, actor_role, action,
                                       entity_type, entity_id, changes, amount_cents, currency, reason, source, request_id)
    VALUES (p_org, p_event, a.actor_uid, a.actor_kind, a.actor_ref, a.actor_role, p_action,
            p_entity_type, left(p_entity_id, 200), v_changes, p_amount_cents,
            CASE WHEN p_currency ~* '^[a-z]{3}$' THEN upper(p_currency) END, v_reason, a.source, a.request_id);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'exos audit: % (%) on %: the action stands, no audit row', SQLERRM, SQLSTATE, p_action;
  END;
END $$;
REVOKE ALL ON FUNCTION public._exos_audit(uuid, text, text, text, uuid, jsonb, bigint, text, text, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_audit(uuid, text, text, text, uuid, jsonb, bigint, text, text, uuid, uuid, text)
  TO service_role;

-- ===========================================================================
-- 5. Browser-written tables: AFTER triggers
-- ===========================================================================
-- TG_ARGV[0]: the entity; TG_ARGV[1]: fields never compared (counters and
-- system stamps, comma-separated); TG_ARGV[2]: the fields a create / delete
-- row names.
CREATE OR REPLACE FUNCTION public._exos_tg_audit_row()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ent  text := TG_ARGV[0];
  v_skip text[] := string_to_array(coalesce(TG_ARGV[1], ''), ',');
  v_keep text[] := string_to_array(coalesce(TG_ARGV[2], ''), ',');
  o      jsonb := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END;
  n      jsonb := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END;
  r      jsonb := coalesce(n, o);
  v_org  uuid;
  v_ev   uuid;
  v_id   text := r ->> 'id';
  v_act  text;
  v_ch   jsonb;
  v_key  uuid;
  v_actor uuid;
  v_hint text;
BEGIN
  BEGIN
    IF v_ent = 'event' THEN
      v_org := (r ->> 'org_id')::uuid; v_ev := (r ->> 'id')::uuid;
    ELSIF v_ent IN ('tier', 'voucher') THEN
      v_ev := (r ->> 'event_id')::uuid;
      SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = v_ev;
    ELSIF v_ent = 'quota' THEN
      v_org := (r ->> 'org_id')::uuid; v_ev := (r ->> 'event_id')::uuid;
    ELSIF v_ent = 'quota_tier' THEN
      SELECT q.org_id, q.event_id INTO v_org, v_ev FROM public.exos_quotas q WHERE q.id = (r ->> 'quota_id')::uuid;
      v_id := r ->> 'quota_id';
    ELSIF v_ent = 'order' THEN
      v_org := (r ->> 'org_id')::uuid;
      SELECT s.event_id INTO v_ev FROM public.exos_checkout_sessions s WHERE s.session_id = r ->> 'session_id';
    ELSE
      v_org := (r ->> 'org_id')::uuid;
    END IF;
    -- A cascade from a deleted event or org: that delete is the record.
    IF v_org IS NULL THEN
      RETURN NULL;
    END IF;

    IF v_ent = 'member' THEN
      -- exos_org_member_approve / _reject log their own decision.
      IF current_setting('exos.audit_member_rpc', true) = v_id THEN RETURN NULL; END IF;
      v_id := r ->> 'user_id';
      IF TG_OP = 'INSERT' THEN
        v_act := CASE WHEN (n ->> 'user_id')::uuid = auth.uid() THEN 'member.join' ELSE 'member.add' END;
        v_ch := public._exos_audit_diff(NULL, n, '{}', ARRAY['role', 'status', 'pending_role']);
      ELSIF TG_OP = 'DELETE' THEN
        v_act := 'member.remove';
        v_ch := public._exos_audit_diff(o, NULL, '{}', ARRAY['role', 'status']);
      ELSE
        v_ch := public._exos_audit_diff(o, n, '{}', ARRAY['role', 'disabled']);
        IF v_ch = '{}'::jsonb THEN RETURN NULL; END IF;
        v_act := CASE WHEN v_ch ? 'disabled' THEN CASE WHEN (n ->> 'disabled')::boolean THEN 'member.remove' ELSE 'member.restore' END
                      ELSE 'member.role_change' END;
      END IF;
    ELSIF v_ent = 'api_key' THEN
      IF TG_OP = 'INSERT' THEN
        v_act := 'api_key.create';
        v_ch := public._exos_audit_diff(NULL, n, '{}', ARRAY['name', 'scopes']);
      ELSIF TG_OP = 'DELETE' THEN
        v_act := 'api_key.delete';
        v_ch := public._exos_audit_diff(o, NULL, '{}', ARRAY['name']);
      ELSIF (o ->> 'revoked_at') IS NULL AND (n ->> 'revoked_at') IS NOT NULL THEN
        v_act := 'api_key.revoke';
        v_ch := jsonb_build_object('revoked', jsonb_build_array(false, true));
      ELSIF (o -> 'scopes') IS DISTINCT FROM (n -> 'scopes') THEN
        v_act := 'api_key.scopes_set';
        v_ch := public._exos_audit_diff(o, n, '{}', ARRAY['scopes']);
      ELSE
        RETURN NULL;
      END IF;
    ELSIF v_ent = 'role_scopes' THEN
      v_id := r ->> 'role';
      v_act := CASE WHEN TG_OP = 'DELETE' THEN 'role_scopes.reset' ELSE 'role_scopes.set' END;
      v_ch := public._exos_audit_diff(o, n, '{}', ARRAY['scopes']);
      IF TG_OP = 'UPDATE' AND v_ch = '{}'::jsonb THEN RETURN NULL; END IF;
    ELSIF v_ent = 'order' THEN
      -- exos_order_edits is the order-edit log itself: one audit row per edit, linked by id.
      v_act := 'order.edit';
      v_id := r ->> 'session_id';
      v_actor := (r ->> 'actor')::uuid;
      v_key := (r ->> 'api_key_id')::uuid;
      v_ch := jsonb_build_object('edit', jsonb_build_array(NULL, r ->> 'action'), 'order_edit_id', jsonb_build_array(NULL, r ->> 'id'),
                                 'ticket_id', jsonb_build_array(NULL, r ->> 'ticket_id'));
    ELSIF v_ent = 'quota_tier' THEN
      v_act := CASE WHEN TG_OP = 'DELETE' THEN 'quota.tier_remove' ELSE 'quota.tier_add' END;
      v_ch := jsonb_build_object('tier_id', CASE WHEN TG_OP = 'DELETE' THEN jsonb_build_array(r ->> 'tier_id', NULL)
                                                 ELSE jsonb_build_array(NULL, r ->> 'tier_id') END);
    ELSE
      -- event / tier / quota / voucher / hold
      IF TG_OP = 'INSERT' THEN
        v_act := v_ent || '.create';
        v_hint := current_setting('exos.audit_action', true);
        IF v_ent = 'voucher' AND v_hint = 'voucher.issue' THEN
          v_act := v_hint;
          PERFORM set_config('exos.audit_action', '', true);
        END IF;
        v_ch := public._exos_audit_diff(NULL, n, v_skip, v_keep);
      ELSIF TG_OP = 'DELETE' THEN
        v_act := v_ent || '.delete';
        v_ch := public._exos_audit_diff(o, NULL, v_skip, v_keep);
      ELSE
        v_ch := public._exos_audit_diff(o, n, v_skip);
        IF v_ch = '{}'::jsonb THEN RETURN NULL; END IF;
        v_act := v_ent || '.update';
        IF v_ent = 'event' AND v_ch ? 'status' THEN
          v_act := CASE n ->> 'status' WHEN 'published' THEN 'event.publish' WHEN 'cancelled' THEN 'event.cancel'
                                       ELSE CASE WHEN o ->> 'status' = 'published' THEN 'event.unpublish' ELSE 'event.update' END END;
        ELSIF v_ent = 'hold' AND v_ch ? 'status' THEN
          v_act := CASE n ->> 'status' WHEN 'cleared' THEN 'hold.clear' WHEN 'converted' THEN 'hold.convert'
                                       WHEN 'active' THEN 'hold.restore' ELSE 'hold.update' END;
        END IF;
      END IF;
      IF v_ent = 'hold' THEN
        v_key := (r ->> 'api_key_id')::uuid;
        IF TG_OP <> 'INSERT' THEN v_key := NULL; END IF;  -- the key that made it, not the one changing it
      END IF;
    END IF;

    PERFORM public._exos_audit(v_org, v_act, CASE WHEN v_ent IN ('quota_tier') THEN 'quota' ELSE v_ent END, v_id, v_ev,
                               v_ch, NULL, NULL, NULL, v_actor, v_key);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'exos audit: % (%) on % %: the change stands, no audit row', SQLERRM, SQLSTATE, TG_OP, TG_TABLE_NAME;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_audit_row() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  t record;
BEGIN
  FOR t IN SELECT * FROM (VALUES
    -- table, entity, skipped fields, create / delete fields
    ('exos_events', 'event',
     'updated_at,created_at,tickets_sold,sync_status,reminder_24h_sent_at,reminder_2h_sent_at,reminder_manual_sent_at,channel_split_at,block_released_at,automatiq_listing_id',
     'name,status,starts_at,total_tickets'),
    ('exos_ticket_tiers', 'tier', 'updated_at,created_at,sold', 'name,price,capacity,ticket_type,visibility'),
    ('exos_quotas', 'quota', 'updated_at,created_at', 'name,size,closed'),
    ('exos_quota_tiers', 'quota_tier', '', ''),
    ('exos_vouchers', 'voucher', 'updated_at,created_at,used_count,link_clicks,code,reserved_email',
     'tier_id,max_uses,price_override,discount_percent,discount_amount,bypass_capacity,valid_until'),
    ('exos_holds', 'hold', 'updated_at,created_at', 'title,status,first_date,last_date'),
    ('exos_org_memberships', 'member', '', ''),
    ('exos_api_keys', 'api_key', '', ''),
    ('exos_org_role_scopes', 'role_scopes', '', ''),
    ('exos_order_edits', 'order', '', '')
  ) v(tbl, ent, skip, keep) LOOP
    IF to_regclass('public.' || t.tbl) IS NULL THEN
      RAISE NOTICE 'exos audit: % not present, no trigger', t.tbl;
      CONTINUE;
    END IF;
    EXECUTE format('DROP TRIGGER IF EXISTS exos_audit_ins_del ON public.%I', t.tbl);
    EXECUTE format('DROP TRIGGER IF EXISTS exos_audit_upd ON public.%I', t.tbl);
    IF t.ent = 'order' THEN
      -- The edit log: a new edit is the event (its own rows only change their mail id).
      EXECUTE format('CREATE TRIGGER exos_audit_ins_del AFTER INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public._exos_tg_audit_row(%L)',
                     t.tbl, t.ent);
      CONTINUE;
    END IF;
    EXECUTE format('CREATE TRIGGER exos_audit_ins_del AFTER INSERT OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public._exos_tg_audit_row(%L, %L, %L)',
                   t.tbl, t.ent, t.skip, t.keep);
    IF t.ent = 'quota_tier' THEN
      CONTINUE;
    END IF;
    -- Only when a compared field changed (a sale bumping `sold`, a key's
    -- last-used stamp, never reach the function).
    EXECUTE format('CREATE TRIGGER exos_audit_upd AFTER UPDATE ON public.%I FOR EACH ROW
                      WHEN ((to_jsonb(OLD) - %L::text[]) IS DISTINCT FROM (to_jsonb(NEW) - %L::text[]))
                      EXECUTE FUNCTION public._exos_tg_audit_row(%L, %L, %L)',
                   t.tbl,
                   CASE t.ent WHEN 'api_key' THEN '{last_used_at,updated_at,name,key_prefix,key_hash}'
                              WHEN 'member' THEN '{updated_at}'
                              WHEN 'role_scopes' THEN '{updated_at,updated_by}'
                              ELSE '{' || t.skip || '}' END,
                   CASE t.ent WHEN 'api_key' THEN '{last_used_at,updated_at,name,key_prefix,key_hash}'
                              WHEN 'member' THEN '{updated_at}'
                              WHEN 'role_scopes' THEN '{updated_at,updated_by}'
                              ELSE '{' || t.skip || '}' END,
                   t.ent, t.skip, t.keep);
  END LOOP;
END $$;

-- ===========================================================================
-- 6. Money and access actions: a call inside each definer RPC
-- ===========================================================================

-- refund.issue: the organizer's refund, when it is claimed (who asked, how
-- much, from where); the dashboard (exos-refund) and the API both claim here.
SELECT pg_temp.exos_patch_n('public.exos_refund_claim(uuid,text,text,jsonb,integer,boolean,text,text)',
  'exos: audit refund.issue',
  $o$  RETURN jsonb_build_object(
    'request_id', v_id, 'session_id', p_session_id, 'amount_cents', v_total,$o$,
  $n$  /* exos: audit refund.issue */
  PERFORM public._exos_audit(s.org_id, 'refund.issue', 'order', p_session_id, s.event_id,
    jsonb_build_object('refund_request', jsonb_build_array(NULL, v_id), 'scope', jsonb_build_array(NULL, v_scope)),
    v_total, s.currency, p_reason, p_actor);
  RETURN jsonb_build_object(
    'request_id', v_id, 'session_id', p_session_id, 'amount_cents', v_total,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_decline_refund_ask(uuid,text)',
  'exos: audit refund_ask.decline',
  $o$   WHERE id = p_ask_id;
  RETURN true;$o$,
  $n$   WHERE id = p_ask_id;
  /* exos: audit refund_ask.decline */
  PERFORM public._exos_audit(a.org_id, 'refund_ask.decline', 'refund_ask', a.id::text, a.event_id,
    jsonb_build_object('status', jsonb_build_array(a.status, 'declined')), a.amount_cents, a.currency, v_note);
  RETURN true;$n$, 1);

-- fee.adjust: the dashboard (exos_fee_adjustment_record) and POST
-- /v1/orders/:id/adjustments both add here; a duplicate is not a new row.
SELECT pg_temp.exos_patch_n('public._exos_fee_adjustment_add(uuid,text,uuid,bigint,text,uuid,uuid,text)',
  'exos: audit fee.adjust',
  $o$  RETURN to_jsonb(a) || jsonb_build_object('duplicate', false);$o$,
  $n$  /* exos: audit fee.adjust */
  PERFORM public._exos_audit(p_org, 'fee.adjust', 'order', p_session_id, s.event_id,
    jsonb_build_object('fee_adjustment', jsonb_build_array(NULL, a.id), 'net_fees_cents', jsonb_build_array(v_net, v_net + p_cents)),
    p_cents, a.currency, v_note, p_actor, p_key_id);
  RETURN to_jsonb(a) || jsonb_build_object('duplicate', false);$n$, 1);

-- comp.issue_batch: once per batch (a resent batch replays and logs nothing);
-- counts only, never the recipients.
SELECT pg_temp.exos_patch_n('public.exos_issue_comp_batch(uuid,uuid,text[],integer,text,text)',
  'exos: audit comp.issue_batch',
  $o$  INSERT INTO public.exos_comp_batch_requests (org_id, event_id, caller, request_key, fingerprint, results)
  VALUES (v_org, p_event_id, v_uid, v_key, v_fp, v_rows);$o$,
  $n$  INSERT INTO public.exos_comp_batch_requests (org_id, event_id, caller, request_key, fingerprint, results)
  VALUES (v_org, p_event_id, v_uid, v_key, v_fp, v_rows);
  /* exos: audit comp.issue_batch */
  PERFORM public._exos_audit(v_org, 'comp.issue_batch', 'event', p_event_id::text, p_event_id,
    jsonb_build_object('tier_id', jsonb_build_array(NULL, p_tier_id), 'qty_each', jsonb_build_array(NULL, p_qty_each),
                       'recipients', jsonb_build_array(NULL, jsonb_array_length(v_rows)),
                       'issued', jsonb_build_array(NULL, (SELECT count(*) FROM jsonb_array_elements(v_rows) x WHERE x ->> 'outcome' = 'issued'))),
    NULL, NULL, NULL, v_uid);$n$, 1);

-- comp.budget_set (20260911132000: conditional).
SELECT pg_temp.exos_patch_opt('public.exos_set_org_comp_budget(uuid,integer)',
  'exos: audit comp.budget_set',
  $o$  UPDATE public.exos_orgs SET comp_budget = p_budget WHERE id = p_org_id;$o$,
  $n$  /* exos: audit comp.budget_set */
  PERFORM public._exos_audit(p_org_id, 'comp.budget_set', 'org', p_org_id::text, NULL,
    jsonb_build_object('comp_budget', jsonb_build_array((SELECT o.comp_budget FROM public.exos_orgs o WHERE o.id = p_org_id), p_budget)));
  UPDATE public.exos_orgs SET comp_budget = p_budget WHERE id = p_org_id;$n$);

-- ticket.void (20260520130000: conditional).
SELECT pg_temp.exos_patch_opt('public.exos_void_ticket(uuid,text)',
  'exos: audit ticket.void',
  $o$         voided_reason = left(coalesce(p_reason, ''), 500)
   WHERE id = p_ticket_id;$o$,
  $n$         voided_reason = left(coalesce(p_reason, ''), 500)
   WHERE id = p_ticket_id;
  /* exos: audit ticket.void */
  PERFORM public._exos_audit(v_org, 'ticket.void', 'ticket', p_ticket_id::text,
    (SELECT t.event_id FROM public.exos_tickets t WHERE t.id = p_ticket_id),
    jsonb_build_object('status', jsonb_build_array(v_status, 'voided')), NULL, NULL, p_reason, v_uid);$n$);

-- ticket.print_void: staff only (a holder voiding their own printout is
-- buyer self-service, out of scope).
SELECT pg_temp.exos_patch_n('public.exos_ticket_print_void(uuid)',
  'exos: audit ticket.print_void',
  $o$  RETURN jsonb_build_object('ok', true, 'ticket_id', t.id,
    'voided', public._exos_print_code_void($o$,
  $n$  /* exos: audit ticket.print_void */
  IF v_staff AND t.owner_id IS DISTINCT FROM auth.uid() THEN
    IF public._exos_print_code_void(t.id, 'voided-by-staff') THEN
      PERFORM public._exos_audit(t.org_id, 'ticket.print_void', 'ticket', t.id::text, t.event_id,
        jsonb_build_object('print_code', jsonb_build_array('active', 'voided')));
      RETURN jsonb_build_object('ok', true, 'ticket_id', t.id, 'voided', true);
    END IF;
    RETURN jsonb_build_object('ok', true, 'ticket_id', t.id, 'voided', false);
  END IF;
  RETURN jsonb_build_object('ok', true, 'ticket_id', t.id,
    'voided', public._exos_print_code_void($n$, 1);

-- pos.void / pos.refund: the door app, the card path (exos-pos) and the API.
SELECT pg_temp.exos_patch_n('public._exos_pos_reverse(uuid,boolean,uuid,uuid,uuid,text,text,boolean,uuid,uuid)',
  'exos: audit pos.reverse',
  $o$  RETURN public._exos_pos_order_json(o.id, p_actor)
         || jsonb_build_object('replay', false,$o$,
  $n$  /* exos: audit pos.reverse */
  PERFORM public._exos_audit(o.org_id, 'pos.' || p_kind, 'pos_order', o.id::text, o.event_id,
    jsonb_build_object('status', jsonb_build_array(o.status, CASE p_kind WHEN 'void' THEN 'void' ELSE 'refunded' END),
                       'cash_returned_cents', jsonb_build_array(NULL, v_cash), 'tickets_voided', jsonb_build_array(NULL, v_void),
                       'override', jsonb_build_array(NULL, v_override)),
    o.total_cents, o.currency, v_reason, p_actor, p_api_key, CASE WHEN p_api_key IS NULL THEN 'pos' END);
  RETURN public._exos_pos_order_json(o.id, p_actor)
         || jsonb_build_object('replay', false,$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_pos_paid_out(uuid,boolean,uuid,integer,text,uuid)',
  'exos: audit pos.paid_out',
  $o$  RETURN jsonb_build_object('id', v_id, 'drawer_id', d.id, 'amount_cents', p_amount_cents, 'reason', v_reason,$o$,
  $n$  /* exos: audit pos.paid_out */
  PERFORM public._exos_audit(d.org_id, 'pos.paid_out', 'pos_drawer', d.id::text, d.event_id,
    jsonb_build_object('paid_out', jsonb_build_array(NULL, v_id), 'drawer_cash_cents', jsonb_build_array(v_have, v_have - p_amount_cents)),
    p_amount_cents, NULL, v_reason, p_actor, NULL, 'pos');
  RETURN jsonb_build_object('id', v_id, 'drawer_id', d.id, 'amount_cents', p_amount_cents, 'reason', v_reason,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_pos_close_drawer(uuid,integer,jsonb,text)',
  'exos: audit pos.drawer_close',
  $o$  RETURN jsonb_build_object('session_id', p_session_id, 'open_float_cents', d.open_float_cents,$o$,
  $n$  /* exos: audit pos.drawer_close */
  PERFORM public._exos_audit(d.org_id, 'pos.drawer_close', 'pos_drawer', p_session_id::text, d.event_id,
    jsonb_build_object('status', jsonb_build_array('open', 'closed'), 'expected_cents', jsonb_build_array(NULL, v_expected),
                       'counted_cents', jsonb_build_array(NULL, p_counted_cents),
                       'variance_cents', jsonb_build_array(NULL, p_counted_cents - v_expected)),
    p_counted_cents, NULL, p_note, NULL, NULL, 'pos');
  RETURN jsonb_build_object('session_id', p_session_id, 'open_float_cents', d.open_float_cents,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_pos_recount_drawer(uuid,integer,text,jsonb)',
  'exos: audit pos.drawer_recount',
  $o$  RETURN jsonb_build_object('session_id', d.id, 'recount_no', v_n + 1,$o$,
  $n$  /* exos: audit pos.drawer_recount */
  PERFORM public._exos_audit(d.org_id, 'pos.drawer_recount', 'pos_drawer', d.id::text, d.event_id,
    jsonb_build_object('counted_cents', jsonb_build_array(d.counted_cents, p_counted_cents),
                       'variance_cents', jsonb_build_array(d.variance_cents, p_counted_cents - d.expected_cents),
                       'recount_no', jsonb_build_array(v_n, v_n + 1)),
    p_counted_cents, NULL, v_reason, NULL, NULL, 'pos');
  RETURN jsonb_build_object('session_id', d.id, 'recount_no', v_n + 1,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_gift_card_void(uuid,text)',
  'exos: audit gift_card.void',
  $o$  RETURN jsonb_build_object('voided_cents', c.balance_cents, 'fresh', true);$o$,
  $n$  /* exos: audit gift_card.void */
  PERFORM public._exos_audit(c.org_id, 'gift_card.void', 'gift_card', c.id::text, NULL,
    jsonb_build_object('status', jsonb_build_array(c.status, 'voided'), 'balance_cents', jsonb_build_array(c.balance_cents, 0)),
    c.balance_cents, c.currency, p_note);
  RETURN jsonb_build_object('voided_cents', c.balance_cents, 'fresh', true);$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_gift_card_reissue_code(uuid,boolean)',
  'exos: audit gift_card.reissue',
  $o$  RETURN jsonb_build_object('card_id', c.id, 'code', v_code,$o$,
  $n$  /* exos: audit gift_card.reissue */
  PERFORM public._exos_audit(c.org_id, 'gift_card.reissue', 'gift_card', c.id::text, NULL,
    jsonb_build_object('new_code', jsonb_build_array(NULL, true), 'notified', jsonb_build_array(NULL, coalesce(p_notify, false))),
    NULL, NULL, 'new code');
  RETURN jsonb_build_object('card_id', c.id, 'code', v_code,$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_donation_offline_refund(uuid,uuid,uuid,integer,text,text,text)',
  'exos: audit donation.offline_refund',
  $o$  RETURN jsonb_build_object('fresh', true, 'donation', public._exos_donation_json(d.id));$o$,
  $n$  /* exos: audit donation.offline_refund */
  PERFORM public._exos_audit(d.org_id, 'donation.offline_refund', 'donation', d.id::text, d.event_id,
    jsonb_build_object('refunded_cents', jsonb_build_array(d.refunded_cents, d.refunded_cents + v_amt),
                       'method', jsonb_build_array(NULL, coalesce(p_method, 'other'))),
    v_amt, d.currency, p_note, p_actor);
  RETURN jsonb_build_object('fresh', true, 'donation', public._exos_donation_json(d.id));$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_donation_delete(uuid,uuid,uuid)',
  'exos: audit donation.delete',
  $o$  RETURN jsonb_build_object('id', d.id, 'deleted', true);$o$,
  $n$  /* exos: audit donation.delete */
  PERFORM public._exos_audit(d.org_id, 'donation.delete', 'donation', d.id::text, d.event_id,
    jsonb_build_object('amount_cents', jsonb_build_array(d.amount_cents, NULL), 'method', jsonb_build_array(d.method, NULL)),
    d.amount_cents, d.currency, NULL, p_actor);
  RETURN jsonb_build_object('id', d.id, 'deleted', true);$n$, 1);

-- payout.mark (the payout run: service), payout.cancel, payout.instant (owner).
SELECT pg_temp.exos_patch_n('public.exos_mark_org_payout(uuid,text,text,text)',
  'exos: audit payout.mark',
  $o$  RETURN p_status;$o$,
  $n$  /* exos: audit payout.mark */
  PERFORM public._exos_audit(p.org_id, 'payout.mark', 'payout', p_id::text, NULL,
    jsonb_build_object('status', jsonb_build_array(v_from, p_status)), round(p.amount * 100)::bigint, p.currency,
    CASE WHEN p_status = 'failed' THEN p_error END)
    FROM public.exos_org_payouts p WHERE p.id = p_id;
  RETURN p_status;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_cancel_org_payout(uuid)',
  'exos: audit payout.cancel',
  $o$  DELETE FROM public.exos_org_payout_lines WHERE payout_id = p_id;$o$,
  $n$  /* exos: audit payout.cancel */
  PERFORM public._exos_audit(p.org_id, 'payout.cancel', 'payout', p_id::text, NULL,
    jsonb_build_object('status', jsonb_build_array(p.status, 'cancelled')), round(p.amount * 100)::bigint, p.currency)
    FROM public.exos_org_payouts p WHERE p.id = p_id;
  DELETE FROM public.exos_org_payout_lines WHERE payout_id = p_id;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_instant_payout_begin(uuid,uuid,integer,text,integer,text)',
  'exos: audit payout.instant',
  $o$  RETURN jsonb_build_object('ok', true, 'id', r.id, 'replayed', false, 'status', r.status);$o$,
  $n$  /* exos: audit payout.instant */
  PERFORM public._exos_audit(p_org_id, 'payout.instant', 'instant_payout', r.id::text, NULL,
    jsonb_build_object('status', jsonb_build_array(NULL, r.status), 'fee_estimate_cents', jsonb_build_array(NULL, r.fee_estimate_cents)),
    p_amount_cents, p_currency, NULL, p_user);
  RETURN jsonb_build_object('ok', true, 'id', r.id, 'replayed', false, 'status', r.status);$n$, 1);

-- promoter.settle / payout_record / payout_cancel.
SELECT pg_temp.exos_patch_n('public.exos_settle_promoter(uuid,uuid[],integer,text,text,text,text,date)',
  'exos: audit promoter.settle',
  $o$  RETURN jsonb_build_object('payout_id', v_id, 'replayed', false, 'via', v_via,$o$,
  $n$  /* exos: audit promoter.settle */
  PERFORM public._exos_audit(v_org, 'promoter.settle', 'promoter', p_promoter_id::text, NULL,
    jsonb_build_object('payout', jsonb_build_array(NULL, v_id), 'via', jsonb_build_array(NULL, v_via),
                       'method', jsonb_build_array(NULL, p_method), 'commissions', jsonb_build_array(NULL, cardinality(v_ids))),
    p_amount_cents, v_cur, p_note);
  RETURN jsonb_build_object('payout_id', v_id, 'replayed', false, 'via', v_via,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_record_promoter_payout(uuid,uuid[],integer,text,text,date)',
  'exos: audit promoter.payout_record',
  $o$     AND public._exos_pc_funder(id, method) = 'organizer';
  RETURN v_id;$o$,
  $n$     AND public._exos_pc_funder(id, method) = 'organizer';
  /* exos: audit promoter.payout_record */
  PERFORM public._exos_audit(v_org, 'promoter.payout_record', 'promoter', p_promoter_id::text, NULL,
    jsonb_build_object('payout', jsonb_build_array(NULL, v_id), 'method', jsonb_build_array(NULL, btrim(p_method)),
                       'commissions', jsonb_build_array(NULL, cardinality(v_ids))),
    p_amount_cents, v_cur, p_note);
  RETURN v_id;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_promoter_payout_cancel(uuid,uuid,text)',
  'exos: audit promoter.payout_cancel',
  $o$         cancelled_commission_ids = v_ids, transfer_updated_at = now()
   WHERE id = po.id;
  RETURN true;$o$,
  $n$         cancelled_commission_ids = v_ids, transfer_updated_at = now()
   WHERE id = po.id;
  /* exos: audit promoter.payout_cancel */
  PERFORM public._exos_audit(po.org_id, 'promoter.payout_cancel', 'promoter_payout', po.id::text, NULL,
    jsonb_build_object('transfer_status', jsonb_build_array(po.transfer_status, 'cancelled'),
                       'commissions', jsonb_build_array(NULL, coalesce(cardinality(v_ids), 0))),
    po.amount_cents, po.currency);
  RETURN true;$n$, 1);

-- settlement.update / finalize / reopen: the cores the dashboard and the API share.
SELECT pg_temp.exos_patch_n('public._exos_settlement_update(uuid,uuid,uuid,jsonb,integer)',
  'exos: audit settlement.update',
  $o$  RETURN public._exos_settlement_view(st);$o$,
  $n$  /* exos: audit settlement.update */
  PERFORM public._exos_audit(p_org, 'settlement.update', 'settlement', p_event::text, p_event,
    jsonb_build_object('revision', jsonb_build_array(st.revision - 1, st.revision)), NULL, NULL,
    'edited: ' || coalesce((SELECT string_agg(fk, ', ' ORDER BY fk) FROM jsonb_object_keys(b) fk), 'nothing'), p_actor);
  RETURN public._exos_settlement_view(st);$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_settlement_finalize(uuid,uuid,uuid,integer)',
  'exos: audit settlement.finalize',
  $o$  RETURN public._exos_settlement_view(st) || jsonb_build_object('link_path'$o$,
  $n$  /* exos: audit settlement.finalize */
  PERFORM public._exos_audit(p_org, 'settlement.finalize', 'settlement', p_event::text, p_event,
    jsonb_build_object('status', jsonb_build_array('draft', 'finalized'), 'revision', jsonb_build_array(NULL, st.revision)),
    NULL, NULL, NULL, p_actor);
  RETURN public._exos_settlement_view(st) || jsonb_build_object('link_path'$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_settlement_reopen(uuid,uuid,uuid)',
  'exos: audit settlement.reopen',
  $o$  RETURN public._exos_settlement_view(st);$o$,
  $n$  /* exos: audit settlement.reopen */
  PERFORM public._exos_audit(p_org, 'settlement.reopen', 'settlement', p_event::text, p_event,
    jsonb_build_object('status', jsonb_build_array('finalized', 'draft'), 'revision', jsonb_build_array(st.revision - 1, st.revision)),
    NULL, NULL, NULL, p_actor);
  RETURN public._exos_settlement_view(st);$n$, 1);

-- member.approve / member.reject: logged here, before the row changes, and
-- the membership trigger is told to leave that row alone.
SELECT pg_temp.exos_patch_n('public.exos_org_member_approve(uuid,uuid)',
  'exos: audit member.approve',
  $o$  PERFORM public._exos_member_decider(p_org_id, p_user_id, m.pending_role);
  UPDATE public.exos_org_memberships$o$,
  $n$  PERFORM public._exos_member_decider(p_org_id, p_user_id, m.pending_role);
  /* exos: audit member.approve */
  PERFORM set_config('exos.audit_member_rpc', m.id::text, true);
  PERFORM public._exos_audit(p_org_id, 'member.approve', 'member', p_user_id::text, NULL,
    jsonb_build_object('role', jsonb_build_array(m.role, CASE WHEN m.role = 'owner' THEN m.role ELSE m.pending_role END),
                       'status', jsonb_build_array(m.status, 'active')));
  UPDATE public.exos_org_memberships$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_org_member_reject(uuid,uuid)',
  'exos: audit member.reject',
  $o$  PERFORM public._exos_member_decider(p_org_id, p_user_id, m.pending_role);
  IF m.status = 'pending_approval' THEN$o$,
  $n$  PERFORM public._exos_member_decider(p_org_id, p_user_id, m.pending_role);
  /* exos: audit member.reject */
  PERFORM set_config('exos.audit_member_rpc', m.id::text, true);
  PERFORM public._exos_audit(p_org_id, 'member.reject', 'member', p_user_id::text, NULL,
    jsonb_build_object('pending_role', jsonb_build_array(m.pending_role, NULL),
                       'removed', jsonb_build_array(NULL, m.status = 'pending_approval')));
  IF m.status = 'pending_approval' THEN$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_set_invite_approval(uuid,boolean)',
  'exos: audit invite.settings',
  $o$  UPDATE public.exos_orgs SET invite_approval = p_on WHERE id = p_org_id;$o$,
  $n$  /* exos: audit invite.settings */
  PERFORM public._exos_audit(p_org_id, 'invite.settings', 'org', p_org_id::text, NULL,
    jsonb_build_object('invite_approval', jsonb_build_array((SELECT o.invite_approval FROM public.exos_orgs o WHERE o.id = p_org_id), p_on)));
  UPDATE public.exos_orgs SET invite_approval = p_on WHERE id = p_org_id;$n$, 1);

-- oauth_app.delete: one row in each org the app had a live grant in.
SELECT pg_temp.exos_patch_n('public.exos_oauth_app_delete(text)',
  'exos: audit oauth_app.delete',
  $o$  FOR g IN SELECT id FROM public.exos_oauth_grants WHERE app_id = a.id AND revoked_at IS NULL LOOP$o$,
  $n$  /* exos: audit oauth_app.delete */
  PERFORM public._exos_audit(x.org_id, 'oauth_app.delete', 'oauth_app', a.client_id, NULL,
            jsonb_build_object('grants_revoked', jsonb_build_array(NULL, x.n)))
     FROM (SELECT gr.org_id, count(*) AS n FROM public.exos_oauth_grants gr
            WHERE gr.app_id = a.id AND gr.revoked_at IS NULL AND gr.org_id IS NOT NULL GROUP BY gr.org_id) x;
  FOR g IN SELECT id FROM public.exos_oauth_grants WHERE app_id = a.id AND revoked_at IS NULL LOOP$n$, 1);

-- ===========================================================================
-- 7. Inventory actions that aren't a plain row edit
-- ===========================================================================
-- voucher.issue: the voucher trigger names the insert after this hint.
SELECT pg_temp.exos_patch_n('public.exos_issue_voucher(uuid,uuid,text,boolean,numeric,integer,integer,text,text,numeric,numeric)',
  'exos: audit voucher.issue',
  $o$  INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,$o$,
  $n$  /* exos: audit voucher.issue */
  PERFORM set_config('exos.audit_action', 'voucher.issue', true);
  INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_set_price_steps(uuid,jsonb,integer,boolean)',
  'exos: audit tier.price_steps',
  $o$  RETURN public._exos_price_steps_json(p_tier_id);$o$,
  $n$  /* exos: audit tier.price_steps */
  PERFORM public._exos_audit(v_org, 'tier.price_steps', 'tier', p_tier_id::text,
    (SELECT t.event_id FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id),
    jsonb_build_object('price_steps', jsonb_build_array(NULL, CASE WHEN jsonb_typeof(p_steps) = 'array' THEN jsonb_array_length(p_steps) END))
      || CASE WHEN p_set_door THEN jsonb_build_object('door_price_cents', jsonb_build_array(NULL, p_door_price_cents)) ELSE '{}'::jsonb END);
  RETURN public._exos_price_steps_json(p_tier_id);$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_api_price_steps_set(uuid,uuid,uuid,uuid,jsonb)',
  'exos: audit tier.price_steps',
  $o$  RETURN public._exos_price_steps_json(p_tier);$o$,
  $n$  /* exos: audit tier.price_steps */
  PERFORM public._exos_audit(p_org, 'tier.price_steps', 'tier', p_tier::text, p_event,
    jsonb_build_object('price_steps', jsonb_build_array(NULL, CASE WHEN jsonb_typeof(p -> 'steps') = 'array' THEN jsonb_array_length(p -> 'steps') END))
      || CASE WHEN p ? 'door_price_cents' THEN jsonb_build_object('door_price_cents', jsonb_build_array(NULL, p -> 'door_price_cents')) ELSE '{}'::jsonb END,
    NULL, NULL, NULL, NULL, p_api_key);
  RETURN public._exos_price_steps_json(p_tier);$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_set_channel_price(uuid,text,uuid,numeric)',
  'exos: audit tier.channel_price',
  $o$  RETURN coalesce(v_price, v_exos);$o$,
  $n$  /* exos: audit tier.channel_price */
  PERFORM public._exos_audit(v_org, 'tier.channel_price', 'tier', p_tier_id::text, p_event_id,
    jsonb_build_object('channel', jsonb_build_array(NULL, p_channel), 'unit_price', jsonb_build_array(NULL, v_price)));
  RETURN coalesce(v_price, v_exos);$n$, 1);

-- ===========================================================================
-- 8. Data out: export.run
-- ===========================================================================
-- The two exports the server builds (fans, the hashed audience). Exports the
-- browser assembles (donations, price disclosure, attendees, this log)
-- record themselves through exos_audit_export below.
SELECT pg_temp.exos_patch_n('public.exos_org_fans_export(uuid,text,uuid[])',
  'exos: audit export.run',
  $o$  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);$o$,
  $n$  /* exos: audit export.run */
  PERFORM public._exos_audit(p_org_id, 'export.run', 'export', 'fans', NULL,
    jsonb_build_object('kind', jsonb_build_array(NULL, 'fans'), 'row_count', jsonb_build_array(NULL, v_n)));
  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_org_audience_export(uuid,uuid)',
  'exos: audit export.run',
  $o$  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);$o$,
  $n$  /* exos: audit export.run */
  PERFORM public._exos_audit(p_org_id, 'export.run', 'export', 'audience', p_event_id,
    jsonb_build_object('kind', jsonb_build_array(NULL, 'audience'), 'row_count', jsonb_build_array(NULL, v_n)));
  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);$n$, 1);

-- A CSV the browser built (owner / manager / finance; 30 a minute). The org
-- is p_org_id, or the event's when only an event is given.
CREATE OR REPLACE FUNCTION public.exos_audit_export(p_org_id uuid, p_kind text, p_row_count integer, p_event_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := coalesce(p_org_id, (SELECT e.org_id FROM public.exos_events e WHERE e.id = p_event_id));
BEGIN
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('audit', 'donations', 'price_disclosure', 'attendees') THEN
    RAISE EXCEPTION 'kind must be audit, donations, price_disclosure or attendees' USING ERRCODE = '22023';
  END IF;
  IF p_row_count IS NULL OR p_row_count < 0 OR p_row_count > 10000000 THEN
    RAISE EXCEPTION 'row_count must be 0 to 10,000,000' USING ERRCODE = '22023';
  END IF;
  IF p_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = v_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT public.exos_rate_hit('audit-export:' || auth.uid()::text, 30) THEN
    RAISE EXCEPTION 'too many exports a minute' USING ERRCODE = '54000';
  END IF;
  PERFORM public._exos_audit(v_org, 'export.run', 'export', p_kind, p_event_id,
    jsonb_build_object('kind', jsonb_build_array(NULL, p_kind), 'row_count', jsonb_build_array(NULL, p_row_count)));
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_audit_export(uuid, text, integer, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_audit_export(uuid, text, integer, uuid) TO authenticated;

-- ===========================================================================
-- 9. Reading it: the Activity page
-- ===========================================================================
-- Newest first, p_limit (1-500) at a time, before p_before (an id). Filters:
-- an event of the org, an actor, an action group, a time range. Staff see who
-- acted: a member's email (as exos_order_edit_log shows it; only for an actor
-- who held a role in the org when acting), an API key's name, "Exos support"
-- for a platform admin, "Not a team member" for anyone else.
CREATE OR REPLACE FUNCTION public.exos_org_audit_list(
  p_org_id uuid, p_event_id uuid DEFAULT NULL, p_actor_uid uuid DEFAULT NULL, p_group text DEFAULT NULL,
  p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL, p_before bigint DEFAULT NULL, p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_lim int := least(greatest(coalesce(p_limit, 100), 1), 500); v_rows jsonb; v_actors jsonb; v_last bigint; v_n int;
BEGIN
  IF auth.uid() IS NULL OR p_org_id IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_group IS NOT NULL AND p_group NOT IN ('inventory', 'money', 'access', 'data') THEN
    RAISE EXCEPTION 'group must be inventory, money, access or data' USING ERRCODE = '22023';
  END IF;
  WITH page AS (
    SELECT x.* FROM public.exos_org_audit x
     WHERE x.org_id = p_org_id
       AND (p_event_id IS NULL OR x.event_id = p_event_id)
       AND (p_actor_uid IS NULL OR x.actor_uid = p_actor_uid)
       AND (p_group IS NULL OR public._exos_audit_group(x.action) = p_group)
       AND (p_from IS NULL OR x.at >= p_from)
       AND (p_to IS NULL OR x.at < p_to)
       AND (p_before IS NULL OR x.id < p_before)
     ORDER BY x.id DESC
     LIMIT v_lim
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'at', x.at, 'event_id', x.event_id,
           'event_name', (SELECT e.name FROM public.exos_events e WHERE e.id = x.event_id AND e.org_id = p_org_id),
           'actor_uid', x.actor_uid, 'actor_kind', x.actor_kind, 'actor_ref', x.actor_ref, 'actor_role', x.actor_role,
           'actor_label', CASE
               WHEN x.actor_kind = 'api_key' THEN 'API key ' || coalesce(
                 (SELECT k.name FROM public.exos_api_keys k WHERE k.id::text = x.actor_ref AND k.org_id = p_org_id), 'deleted')
               WHEN x.actor_role = 'platform_admin' THEN 'Exos support'
               WHEN x.actor_uid IS NOT NULL AND x.actor_role IS NOT NULL
                 THEN coalesce((SELECT u.email FROM auth.users u WHERE u.id = x.actor_uid), 'deleted user')
               WHEN x.actor_uid IS NOT NULL THEN 'Not a team member'
               WHEN x.actor_kind = 'cron' THEN 'Scheduled job'
               ELSE 'Exos' END,
           'action', x.action, 'group', public._exos_audit_group(x.action), 'entity_type', x.entity_type, 'entity_id', x.entity_id,
           'changes', x.changes, 'amount_cents', x.amount_cents, 'currency', x.currency, 'reason', x.reason,
           'source', x.source, 'request_id', x.request_id) ORDER BY x.id DESC), '[]'::jsonb),
         min(x.id), count(*)
    INTO v_rows, v_last, v_n
    FROM page x;
  SELECT coalesce(jsonb_agg(jsonb_build_object('uid', a.actor_uid,
           'label', coalesce(CASE WHEN a.admin THEN 'Exos support' END,
                             (SELECT u.email FROM auth.users u WHERE u.id = a.actor_uid), 'deleted user'))
           ORDER BY a.last DESC), '[]'::jsonb)
    INTO v_actors
    FROM (SELECT x.actor_uid, max(x.id) AS last, bool_or(x.actor_role = 'platform_admin') AS admin
            FROM public.exos_org_audit x WHERE x.org_id = p_org_id AND x.actor_uid IS NOT NULL AND x.actor_role IS NOT NULL
           GROUP BY x.actor_uid ORDER BY max(x.id) DESC LIMIT 100) a;
  RETURN jsonb_build_object('rows', v_rows, 'next_before', CASE WHEN v_n = v_lim THEN v_last END, 'actors', v_actors);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_audit_list(uuid, uuid, uuid, text, timestamptz, timestamptz, bigint, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_audit_list(uuid, uuid, uuid, text, timestamptz, timestamptz, bigint, integer)
  TO authenticated;

-- ===========================================================================
-- 10. audit:read (GET /v1/audit), owner and finance by default
-- ===========================================================================
-- Same order as SCOPES in supabase/functions/_shared/api/scopes.ts
-- (src/lib/apiScopes.test.ts reads the latest definition); org:admin last.
CREATE OR REPLACE FUNCTION public.exos_api_scope_names()
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY[
    'events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write', 'tickets:read',
    'tickets:write', 'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
    'commerce:read', 'commerce:write', 'webhooks:read', 'webhooks:write', 'audit:read', 'me:read', 'me:write', 'org:admin'
  ]::text[]
$$;
REVOKE ALL ON FUNCTION public.exos_api_scope_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_api_scope_names() TO authenticated, service_role;

-- Must equal ROLE_SCOPES in supabase/functions/_shared/api/credentials.ts
-- (src/lib/credentials.test.ts reads the latest definition).
CREATE OR REPLACE FUNCTION public.exos_role_token_scopes(p_role text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE p_role
    WHEN 'owner' THEN ARRAY['events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write',
                            'tickets:read', 'tickets:write', 'checkin:write', 'booking:read', 'booking:write',
                            'finance:read', 'finance:write', 'commerce:read', 'commerce:write', 'webhooks:read',
                            'webhooks:write', 'audit:read', 'me:read', 'me:write', 'org:admin']
    WHEN 'manager' THEN ARRAY['events:read', 'events:write', 'orders:read', 'tickets:read', 'tickets:write',
                              'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
                              'commerce:read', 'commerce:write', 'me:read', 'me:write']
    WHEN 'finance' THEN ARRAY['events:read', 'orders:read', 'tickets:read', 'booking:read', 'finance:read',
                              'finance:write', 'commerce:read', 'audit:read', 'me:read', 'me:write']
    WHEN 'content' THEN ARRAY['events:read', 'events:write', 'booking:read', 'me:read', 'me:write']
    WHEN 'scanner' THEN ARRAY['events:read', 'tickets:read', 'checkin:write', 'me:read', 'me:write']
    ELSE ARRAY[]::text[]
  END
$$;
REVOKE ALL ON FUNCTION public.exos_role_token_scopes(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_role_token_scopes(text) TO authenticated, service_role;

-- Must equal ROLE_SCOPE_CEILING in supabase/functions/_shared/api/orgAccess.ts
-- (src/lib/orgAccess.test.ts reads this definition). audit:read: the owner
-- and finance only (a manager reads the log in the dashboard, not by key).
CREATE OR REPLACE FUNCTION public.exos_role_scope_ceiling(p_role text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE p_role
    WHEN 'owner' THEN ARRAY['events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write',
                            'tickets:read', 'tickets:write', 'checkin:write', 'booking:read', 'booking:write',
                            'finance:read', 'finance:write', 'commerce:read', 'commerce:write', 'webhooks:read',
                            'webhooks:write', 'audit:read', 'org:admin']
    WHEN 'manager' THEN ARRAY['events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write',
                              'tickets:read', 'tickets:write', 'checkin:write', 'booking:read', 'booking:write',
                              'finance:read', 'finance:write', 'commerce:read', 'commerce:write', 'webhooks:read',
                              'webhooks:write']
    WHEN 'finance' THEN ARRAY['events:read', 'orders:read', 'refunds:write', 'fans:read', 'tickets:read', 'booking:read',
                              'finance:read', 'finance:write', 'commerce:read', 'audit:read']
    WHEN 'content' THEN ARRAY['events:read', 'events:write', 'booking:read']
    WHEN 'scanner' THEN ARRAY['events:read', 'tickets:read', 'checkin:write']
    ELSE ARRAY[]::text[]
  END
$$;
REVOKE ALL ON FUNCTION public.exos_role_scope_ceiling(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_role_scope_ceiling(text) TO authenticated, service_role;
