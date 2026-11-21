-- ============================================================================
-- Migration 20261119130000 — Exos: event writes from AI assistants (MCP), and
-- user-token writes for three core actions
-- ============================================================================
-- Operator request (2026-11-21): free-tier organizers create events from
-- Claude / ChatGPT through exos-mcp (docs/mcp.md). claude.ai and ChatGPT sign
-- in with OAuth, so the assistant holds an OAuth access token (exos_oat_…),
-- not an org API key, and exos_api_write only took an API key. This
-- migration:
--
--   1. exos_api_write takes a user token as well as a key. ONE function
--      resolves both: with p_token_hash it re-resolves the personal or OAuth
--      token in SQL, in this transaction (exos_api_token_auth_org: a revoked
--      or expired token, a revoked grant or deleted app, a user who left or
--      was disabled are refused; the token's consented scopes are narrowed to
--      the user's role NOW), and runs as that user instead of a key's creator.
--      Only three actions are open to user tokens (_exos_api_user_token_actions:
--      event.create, ticket_type.create, event.publish); every other action
--      still needs an org API key (42501). The key path is unchanged. The
--      signature gains four defaulted parameters (p_token_hash, p_token_kind,
--      p_token_org, p_source), so calls with the old five arguments still
--      resolve to it; the old five-argument function is dropped (two would be
--      ambiguous). A later migration that patches it names
--      public.exos_api_write(uuid,text,text,jsonb,text,text,text,uuid,text).
--   2. exos_api_writes records the credential (kind api_key / pat / oauth and
--      its id: the key's, the personal token's, the OAuth grant's) and the
--      source (api / mcp). Idempotency-Keys are unique per credential. A
--      BEFORE INSERT trigger fills the credential from api_key_id for the
--      other writers (exos_api_commerce_write, _order_write, _gap_write).
--   3. 'mcp' is an org-audit source (exos_org_audit.source, _exos_audit_actor).
--   4. MCP write confirmations (exos_mcp_confirms): an assistant's write is two
--      calls. The first gets a preview and a confirm token (32 random bytes,
--      only its SHA-256 stored), bound to the credential, the tool and the
--      exact action / target / args (_exos_api_request_hash), 10 minutes,
--      single use. The second sends it back: exos_mcp_write checks it under a
--      row lock, counts the org's MCP writes in the last hour (20 by default,
--      platform setting mcp_writes_per_hour), spends it, and calls
--      exos_api_write with source mcp. Changed args burn the token.
--   5. exos_mcp_writes: one row per executed MCP write (credential, actor,
--      tool, route, action, target, event, outcome), plus an exos_org_audit
--      row mcp.write (source mcp).
--   6. exos_mcp_event_state / exos_mcp_fee_outcome: what the previews show
--      (the event, its ticket types, its publish blockers; the free tier),
--      for the credential's org only (NULL for any other org's event).
--
-- All new functions are SECURITY DEFINER with a pinned search_path and
-- service_role EXECUTE only (exos-mcp / exos-api); nothing is granted to anon
-- or authenticated except SELECT on exos_mcp_writes (owner / manager, RLS).
-- Re-run safe. Prod apply needs operator OK.
--
-- Touches:  W: FUNCTION exos_api_write (widened, see 1), _exos_audit_actor
--              (patched: 'mcp' source)
--              TABLE exos_api_writes (+ credential_kind, credential_id, source;
--              index, trigger), exos_org_audit (source CHECK + 'mcp')
--           C: TABLE exos_mcp_confirms, exos_mcp_writes
--              FUNCTION _exos_api_user_token_actions, _exos_tg_api_writes_cred,
--              _exos_mcp_credential, exos_mcp_confirm_issue, exos_mcp_write,
--              exos_mcp_event_state, exos_mcp_fee_outcome
--           R: exos_api_keys, exos_personal_tokens, exos_oauth_*, exos_events,
--              exos_ticket_tiers, exos_org_memberships, exos_platform_settings
--           Calls (unchanged): exos_api_token_auth_org, _exos_api_request_hash,
--              _exos_event_publish_blockers, exos_event_is_free_tier,
--              exos_event_max_capacity, exos_event_capacity_bounded,
--              exos_free_tier_max_capacity, _exos_setting_int, _exos_audit
-- Pre-reqs: 20261031110000 (exos_api_write), 20261031130500 (user tokens),
--           20261104130000 (request hash), 20261105120000 (X-Exos-Org),
--           20261109100000 (org audit), 20261029090000 (free tier)
-- ============================================================================

-- Text patches (supabase/README.md rule 4): count, then replace.
CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
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

-- One replacement on a text, after counting its matches.
CREATE OR REPLACE FUNCTION pg_temp.exos_sub(p_def text, p_what text, p_old text, p_new text, p_hits int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_hits int;
BEGIN
  v_hits := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION 'exos_api_write: expected % match(es) for "%", found %', p_hits, p_what, v_hits;
  END IF;
  RETURN replace(p_def, p_old, p_new);
END $$;

-- ---------------------------------------------------------------------------
-- 1. exos_api_writes: the credential and the source.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_api_writes
  ADD COLUMN IF NOT EXISTS credential_kind text,
  ADD COLUMN IF NOT EXISTS credential_id   uuid,
  ADD COLUMN IF NOT EXISTS source          text NOT NULL DEFAULT 'api';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_api_writes_credential_kind_chk') THEN
    ALTER TABLE public.exos_api_writes ADD CONSTRAINT exos_api_writes_credential_kind_chk
      CHECK (credential_kind IS NULL OR credential_kind IN ('api_key', 'pat', 'oauth'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_api_writes_source_chk') THEN
    ALTER TABLE public.exos_api_writes ADD CONSTRAINT exos_api_writes_source_chk CHECK (source IN ('api', 'mcp'));
  END IF;
END $$;
UPDATE public.exos_api_writes SET credential_kind = 'api_key', credential_id = api_key_id
 WHERE credential_kind IS NULL AND api_key_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_api_writes_cred_idem_uq
  ON public.exos_api_writes (credential_kind, credential_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

-- The other writers name only api_key_id: their rows are that key's.
CREATE OR REPLACE FUNCTION public._exos_tg_api_writes_cred()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.credential_id IS NULL AND NEW.api_key_id IS NOT NULL THEN
    NEW.credential_kind := 'api_key';
    NEW.credential_id := NEW.api_key_id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_api_writes_cred() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_api_writes_cred ON public.exos_api_writes;
CREATE TRIGGER exos_api_writes_cred BEFORE INSERT ON public.exos_api_writes
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_api_writes_cred();

-- ---------------------------------------------------------------------------
-- 2. The actions a personal or OAuth token may write (exos-api's
--    USER_TOKEN_CORE_WRITES in _shared/api/request.ts: create-event,
--    create-ticket-type, publish-event; src/lib/mcp/mcpWrites.test.ts checks
--    the two agree).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_api_user_token_actions()
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$ SELECT ARRAY['event.create', 'ticket_type.create', 'event.publish']::text[] $$;
REVOKE ALL ON FUNCTION public._exos_api_user_token_actions() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_user_token_actions() TO service_role;

-- ---------------------------------------------------------------------------
-- 3. exos_api_write: a key or a user token, resolved in one place.
--    Built from the live body (prod's, by rule 4), then the five-argument
--    function is replaced by the nine-argument one. Re-run: when the old one
--    exists again (the replay re-creates it from 20261031110000) it is rebuilt.
-- ---------------------------------------------------------------------------
DO $mig$
DECLARE
  v_old regprocedure := to_regprocedure('public.exos_api_write(uuid,text,text,jsonb,text)');
  v_new regprocedure := to_regprocedure('public.exos_api_write(uuid,text,text,jsonb,text,text,text,uuid,text)');
  d text;
BEGIN
  IF v_old IS NULL THEN
    IF v_new IS NULL THEN RAISE EXCEPTION 'exos_api_write: not present'; END IF;
    RAISE NOTICE 'exos_api_write: already takes user tokens';
    RETURN;
  END IF;
  d := replace(pg_get_functiondef(v_old), chr(13), '');

  d := pg_temp.exos_sub(d, 'signature',
    'p_idempotency_key text DEFAULT NULL::text)',
    'p_idempotency_key text DEFAULT NULL::text, p_token_hash text DEFAULT NULL::text, p_token_kind text DEFAULT NULL::text, p_token_org uuid DEFAULT NULL::uuid, p_source text DEFAULT ''api''::text)', 1);

  d := pg_temp.exos_sub(d, 'declare',
    E'  v_was      jsonb;\n',
    E'  v_was      jsonb;\n  v_tok      jsonb;  /* exos: user-token writes */\n  v_cred_kind text;\n  v_cred     uuid;\n  v_tscopes  text[];\n', 1);

  -- Step 1: a user token, else the key exactly as before.
  d := pg_temp.exos_sub(d, 'step 1',
    E'  -- 1. The key and its org.\n  SELECT * INTO k FROM public.exos_api_keys WHERE id = p_key_id AND revoked_at IS NULL;\n',
    E'  IF p_source IS NULL OR p_source NOT IN (''api'', ''mcp'') THEN\n' ||
    E'    RAISE EXCEPTION ''exos_api_write: unknown source'' USING ERRCODE = ''22023'';\n' ||
    E'  END IF;\n' ||
    E'  IF p_token_hash IS NOT NULL THEN\n' ||
    E'    -- 1u. A personal or OAuth token acts as its own user (mig 20261119130000).\n' ||
    E'    -- Re-resolved here, in this transaction: a revoked or expired token, a\n' ||
    E'    -- revoked grant or deleted app, a user who left or was disabled are\n' ||
    E'    -- refused; the consented scopes are narrowed to the user''s role now.\n' ||
    E'    IF p_key_id IS NOT NULL OR p_token_kind IS NULL OR p_token_kind NOT IN (''pat'', ''oauth'') THEN\n' ||
    E'      RAISE EXCEPTION ''exos_api_write: send an API key or a user token, not both'' USING ERRCODE = ''22023'';\n' ||
    E'    END IF;\n' ||
    E'    IF NOT (p_action = ANY (public._exos_api_user_token_actions())) THEN\n' ||
    E'      RAISE EXCEPTION ''exos_api_write: this write needs an organization API key (sk_live_…)'' USING ERRCODE = ''42501'';\n' ||
    E'    END IF;\n' ||
    E'    v_tok := public.exos_api_token_auth_org(p_token_hash, p_token_kind, p_token_org);\n' ||
    E'    IF v_tok IS NULL OR v_tok ? ''error'' OR (v_tok ->> ''org_id'') IS NULL THEN\n' ||
    E'      RAISE EXCEPTION ''exos_api_write: invalid, expired or revoked token, or its user is no longer a member of the organization''\n' ||
    E'        USING ERRCODE = ''42501'';\n' ||
    E'    END IF;\n' ||
    E'    v_org := (v_tok ->> ''org_id'')::uuid;\n' ||
    E'    v_actor := (v_tok ->> ''user_id'')::uuid;\n' ||
    E'    v_cred_kind := p_token_kind;\n' ||
    E'    v_cred := (v_tok ->> ''credential_id'')::uuid;\n' ||
    E'    v_scope := public._exos_api_action_scope(p_action);\n' ||
    E'    IF v_scope IS NULL THEN\n' ||
    E'      RAISE EXCEPTION ''exos_api_write: unknown action'' USING ERRCODE = ''22023'';\n' ||
    E'    END IF;\n' ||
    E'    SELECT coalesce(array_agg(x), ''{}'') INTO v_tscopes FROM jsonb_array_elements_text(v_tok -> ''scopes'') x;\n' ||
    E'    IF NOT public._exos_api_has_scope(v_tscopes, v_scope) THEN\n' ||
    E'      RAISE EXCEPTION ''exos_api_write: the token lacks the % scope'', v_scope USING ERRCODE = ''42501'';\n' ||
    E'    END IF;\n' ||
    E'  ELSE\n' ||
    E'  -- 1. The key and its org.\n  SELECT * INTO k FROM public.exos_api_keys WHERE id = p_key_id AND revoked_at IS NULL;\n', 1);

  d := pg_temp.exos_sub(d, 'step 2 end',
    E'create a new key''\n      USING ERRCODE = ''42501'';\n  END IF;\n',
    E'create a new key''\n      USING ERRCODE = ''42501'';\n  END IF;\n  v_cred_kind := ''api_key'';\n  v_cred := k.id;\n  END IF;\n', 1);

  -- Idempotency: per credential.
  d := pg_temp.exos_sub(d, 'idempotency claim',
    E'    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, idempotency_key, money_moving)\n' ||
    E'    VALUES (v_org, k.id, v_actor, p_action, left(p_target, 255), p_idempotency_key, v_money)\n' ||
    E'    ON CONFLICT (api_key_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING\n',
    E'    INSERT INTO public.exos_api_writes (org_id, api_key_id, credential_kind, credential_id, source, actor, action, target, idempotency_key, money_moving)\n' ||
    E'    VALUES (v_org, k.id, v_cred_kind, v_cred, p_source, v_actor, p_action, left(p_target, 255), p_idempotency_key, v_money)\n' ||
    E'    ON CONFLICT (credential_kind, credential_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING\n', 1);
  d := pg_temp.exos_sub(d, 'idempotency replay',
    E'       WHERE api_key_id = k.id AND idempotency_key = p_idempotency_key;\n',
    E'       WHERE credential_kind = v_cred_kind AND credential_id = v_cred AND idempotency_key = p_idempotency_key;\n', 1);
  -- Refund nonce / comp request key: the credential's id (a key's is k.id, as before).
  d := pg_temp.exos_sub(d, 'request keys',
    E'''api:'' || replace(k.id::text, ''-'', '''') || '':'' || p_idempotency_key',
    E'''api:'' || replace(v_cred::text, ''-'', '''') || '':'' || p_idempotency_key', 2);
  -- The log row.
  d := pg_temp.exos_sub(d, 'log row',
    E'    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, money_moving, result)\n' ||
    E'    VALUES (v_org, k.id, v_actor, p_action, left(p_target, 255), v_money,\n',
    E'    INSERT INTO public.exos_api_writes (org_id, api_key_id, credential_kind, credential_id, source, actor, action, target, money_moving, result)\n' ||
    E'    VALUES (v_org, k.id, v_cred_kind, v_cred, p_source, v_actor, p_action, left(p_target, 255), v_money,\n', 1);

  IF v_new IS NOT NULL THEN
    DROP FUNCTION public.exos_api_write(uuid, text, text, jsonb, text, text, text, uuid, text);
  END IF;
  DROP FUNCTION public.exos_api_write(uuid, text, text, jsonb, text);
  EXECUTE d;
END $mig$;
REVOKE ALL ON FUNCTION public.exos_api_write(uuid, text, text, jsonb, text, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_write(uuid, text, text, jsonb, text, text, text, uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. 'mcp' as an org-audit source.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_org_audit DROP CONSTRAINT IF EXISTS exos_org_audit_source_check;
ALTER TABLE public.exos_org_audit ADD CONSTRAINT exos_org_audit_source_check
  CHECK (source IN ('dashboard', 'api', 'door', 'pos', 'webhook', 'system', 'mcp'));
SELECT pg_temp.exos_patch_n('public._exos_audit_actor(uuid,uuid,uuid,text)',
  '''webhook'', ''system'', ''mcp'')',
  '(''dashboard'', ''api'', ''door'', ''pos'', ''webhook'', ''system'')',
  '(''dashboard'', ''api'', ''door'', ''pos'', ''webhook'', ''system'', ''mcp'')', 2);

-- ---------------------------------------------------------------------------
-- 5. Confirmations and the MCP write log.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_mcp_confirms (
  token_hash      text PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  credential_kind text NOT NULL CHECK (credential_kind IN ('api_key', 'pat', 'oauth')),
  credential_id   uuid NOT NULL,
  tool            text NOT NULL CHECK (tool ~ '^[a-z_]{2,40}$'),
  action          text NOT NULL CHECK (action ~ '^[a-z_]{2,40}\.[a-z_]{2,40}$'),
  target          text CHECK (target IS NULL OR length(target) <= 255),
  request_hash    text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  expires_at      timestamptz NOT NULL,
  used_at         timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_mcp_confirms_cred_idx
  ON public.exos_mcp_confirms (credential_kind, credential_id, created_at);
ALTER TABLE public.exos_mcp_confirms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_mcp_confirms FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_mcp_confirms TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_mcp_writes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  credential_kind text NOT NULL CHECK (credential_kind IN ('api_key', 'pat', 'oauth')),
  credential_id   uuid NOT NULL,
  actor           uuid,
  tool            text NOT NULL CHECK (tool ~ '^[a-z_]{2,40}$'),
  route_id        text NOT NULL CHECK (route_id ~ '^[a-z-]{2,60}$'),
  action          text NOT NULL,
  target          text CHECK (target IS NULL OR length(target) <= 255),
  event_id        uuid,
  status          text NOT NULL DEFAULT 'started' CHECK (status IN ('started', 'done', 'failed')),
  error_code      text CHECK (error_code IS NULL OR error_code ~ '^[A-Z0-9]{5}$'),
  created_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz
);
CREATE INDEX IF NOT EXISTS exos_mcp_writes_org_idx ON public.exos_mcp_writes (org_id, created_at DESC);
ALTER TABLE public.exos_mcp_writes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_mcp_writes_sel ON public.exos_mcp_writes;
CREATE POLICY exos_mcp_writes_sel ON public.exos_mcp_writes FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
REVOKE ALL ON public.exos_mcp_writes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_mcp_writes TO authenticated;
GRANT ALL ON public.exos_mcp_writes TO service_role;

-- The tools and what each one writes (exos-mcp's WRITE_TOOLS, checked by
-- src/lib/mcp/mcpWrites.test.ts).
CREATE OR REPLACE FUNCTION public._exos_mcp_tool_action(p_tool text)
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE p_tool
    WHEN 'create_event_draft' THEN ARRAY['event.create', 'create-event']
    WHEN 'add_ticket_type' THEN ARRAY['ticket_type.create', 'create-ticket-type']
    WHEN 'publish_event' THEN ARRAY['event.publish', 'publish-event']
  END
$$;
REVOKE ALL ON FUNCTION public._exos_mcp_tool_action(text) FROM PUBLIC, anon, authenticated;

-- The credential's actor, if it is live and belongs to p_org; else NULL.
-- A key: not revoked, its creator an active member. A user token: the same
-- resolution as exos_api_write (exos_api_token_auth_org), and the same id.
CREATE OR REPLACE FUNCTION public._exos_mcp_credential(p_org uuid, p_kind text, p_cred uuid, p_bearer_hash text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb; v_uid uuid;
BEGIN
  IF p_org IS NULL OR p_cred IS NULL THEN RETURN NULL; END IF;
  IF p_kind = 'api_key' THEN
    SELECT k.created_by INTO v_uid FROM public.exos_api_keys k
     WHERE k.id = p_cred AND k.org_id = p_org AND k.revoked_at IS NULL;
    IF v_uid IS NULL OR public._exos_member_role(p_org, v_uid) IS NULL THEN RETURN NULL; END IF;
    RETURN v_uid;
  ELSIF p_kind IN ('pat', 'oauth') THEN
    v := public.exos_api_token_auth_org(p_bearer_hash, p_kind, p_org);
    IF v IS NULL OR v ? 'error' OR (v ->> 'org_id') IS DISTINCT FROM p_org::text
       OR (v ->> 'credential_id') IS DISTINCT FROM p_cred::text THEN
      RETURN NULL;
    END IF;
    RETURN (v ->> 'user_id')::uuid;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_mcp_credential(uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;

-- First call: store a confirmation for exactly this write.
CREATE OR REPLACE FUNCTION public.exos_mcp_confirm_issue(
  p_org uuid, p_cred_kind text, p_cred uuid, p_bearer_hash text, p_tool text,
  p_action text, p_target text, p_args jsonb, p_confirm_hash text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_map text[] := public._exos_mcp_tool_action(p_tool); v_live int; v_exp timestamptz;
BEGIN
  IF v_map IS NULL OR v_map[1] IS DISTINCT FROM p_action THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: unknown tool' USING ERRCODE = '22023';
  END IF;
  IF p_confirm_hash IS NULL OR p_confirm_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: bad confirmation' USING ERRCODE = '22023';
  END IF;
  IF public._exos_mcp_credential(p_org, p_cred_kind, p_cred, p_bearer_hash) IS NULL THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: invalid or revoked credential' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-mcp-confirm:' || p_cred::text, 0));
  DELETE FROM public.exos_mcp_confirms
   WHERE credential_kind = p_cred_kind AND credential_id = p_cred AND expires_at < now() - interval '1 day';
  SELECT count(*) INTO v_live FROM public.exos_mcp_confirms
   WHERE credential_kind = p_cred_kind AND credential_id = p_cred AND used_at IS NULL AND expires_at > now();
  IF v_live >= 30 THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: too many open confirmations; wait a few minutes' USING ERRCODE = '54000';
  END IF;
  v_exp := now() + interval '10 minutes';
  INSERT INTO public.exos_mcp_confirms (token_hash, org_id, credential_kind, credential_id, tool, action, target,
                                        request_hash, expires_at)
  VALUES (p_confirm_hash, p_org, p_cred_kind, p_cred, p_tool, p_action, left(p_target, 255),
          public._exos_api_request_hash(p_action, p_target, coalesce(p_args, '{}'::jsonb)), v_exp);
  RETURN jsonb_build_object('expires_at', v_exp);
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_confirm_issue(uuid, text, uuid, text, text, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_confirm_issue(uuid, text, uuid, text, text, text, text, jsonb, text) TO service_role;

-- Second call: check and spend the confirmation, count the hour, write.
-- Answers { ok: true, write_id, result } or { ok: false, error, message }
-- (confirm_invalid / confirm_used / confirm_expired / confirm_mismatch /
-- rate_limited / write_failed with the SQLSTATE in code). A mismatch burns
-- the confirmation; a rate limit leaves it for later; a failed write spends it.
CREATE OR REPLACE FUNCTION public.exos_mcp_write(
  p_confirm_hash text, p_org uuid, p_cred_kind text, p_cred uuid, p_bearer_hash text, p_tool text,
  p_action text, p_target text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c        public.exos_mcp_confirms%ROWTYPE;
  v_map    text[] := public._exos_mcp_tool_action(p_tool);
  v_actor  uuid;
  v_n      int;
  v_cap    int := public._exos_setting_int('mcp_writes_per_hour', 20, 1, 1000);
  v_id     uuid;
  v_out    jsonb;
  v_state  text;
  v_msg    text;
  v_event  uuid;
  v_oldest timestamptz;
BEGIN
  IF v_map IS NULL OR v_map[1] IS DISTINCT FROM p_action THEN
    RAISE EXCEPTION 'exos_mcp_write: unknown tool' USING ERRCODE = '22023';
  END IF;
  v_actor := public._exos_mcp_credential(p_org, p_cred_kind, p_cred, p_bearer_hash);
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'credential', 'message', 'invalid or revoked credential');
  END IF;
  SELECT * INTO c FROM public.exos_mcp_confirms WHERE token_hash = p_confirm_hash FOR UPDATE;
  IF NOT FOUND OR c.org_id <> p_org OR c.credential_kind <> p_cred_kind OR c.credential_id <> p_cred THEN
    RETURN jsonb_build_object('ok', false, 'error', 'confirm_invalid',
      'message', 'this confirm_token is not valid; call the tool again without one for a new preview');
  END IF;
  IF c.used_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'confirm_used',
      'message', 'this confirm_token was already used; call the tool again without one for a new preview');
  END IF;
  IF c.expires_at <= now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'confirm_expired',
      'message', 'this confirm_token expired (10 minutes); call the tool again without one for a new preview');
  END IF;
  IF c.tool <> p_tool OR c.action <> p_action OR c.target IS DISTINCT FROM left(p_target, 255)
     OR c.request_hash <> public._exos_api_request_hash(p_action, p_target, coalesce(p_args, '{}'::jsonb)) THEN
    UPDATE public.exos_mcp_confirms SET used_at = now() WHERE token_hash = p_confirm_hash;
    RETURN jsonb_build_object('ok', false, 'error', 'confirm_mismatch',
      'message', 'the arguments changed since the preview, so that confirm_token no longer applies; call the tool again without one for a new preview');
  END IF;

  -- The org's MCP writes in the last hour (every attempt counts).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-mcp-writes:' || p_org::text, 0));
  SELECT count(*), min(created_at) INTO v_n, v_oldest FROM public.exos_mcp_writes
   WHERE org_id = p_org AND created_at > now() - interval '1 hour';
  IF v_n >= v_cap THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited',
      'message', format('this organization has made %s writes from an AI assistant in the last hour (the most is %s); try again later', v_n, v_cap),
      'retry_after_seconds', greatest(1, ceil(extract(epoch FROM (v_oldest + interval '1 hour' - now())))::int));
  END IF;

  UPDATE public.exos_mcp_confirms SET used_at = now() WHERE token_hash = p_confirm_hash;
  INSERT INTO public.exos_mcp_writes (org_id, credential_kind, credential_id, actor, tool, route_id, action, target)
  VALUES (p_org, p_cred_kind, p_cred, v_actor, p_tool, v_map[2], p_action, left(p_target, 255))
  RETURNING id INTO v_id;

  BEGIN
    IF p_cred_kind = 'api_key' THEN
      v_out := public.exos_api_write(p_cred, p_action, p_target, coalesce(p_args, '{}'::jsonb),
                                     'mcp-' || replace(v_id::text, '-', ''), NULL, NULL, NULL, 'mcp');
    ELSE
      v_out := public.exos_api_write(NULL, p_action, p_target, coalesce(p_args, '{}'::jsonb),
                                     'mcp-' || replace(v_id::text, '-', ''), p_bearer_hash, p_cred_kind, p_org, 'mcp');
    END IF;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;

  v_event := CASE
    WHEN p_action = 'event.create' AND v_state IS NULL AND (v_out ->> 'id') ~* '^[0-9a-f-]{36}$' THEN (v_out ->> 'id')::uuid
    WHEN p_target ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN p_target::uuid
  END;
  UPDATE public.exos_mcp_writes
     SET status = CASE WHEN v_state IS NULL THEN 'done' ELSE 'failed' END,
         error_code = CASE WHEN v_state ~ '^[A-Z0-9]{5}$' THEN v_state END,
         event_id = v_event, finished_at = now()
   WHERE id = v_id;
  -- The org audit row points at the MCP write (its id), which names the
  -- credential; short text there would be masked (ids look like phone numbers).
  PERFORM public._exos_audit(p_org, 'mcp.write', 'mcp_write', v_id::text, v_event,
    jsonb_build_object('tool', p_tool, 'route', v_map[2], 'credential', p_cred_kind,
                       'status', CASE WHEN v_state IS NULL THEN 'done' ELSE 'failed' END),
    NULL, NULL, CASE WHEN v_state IS NOT NULL THEN 'failed: ' || v_state END,
    v_actor, CASE WHEN p_cred_kind = 'api_key' THEN p_cred END, 'mcp');

  IF v_state IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'write_failed', 'code', v_state,
                              'message', left(regexp_replace(v_msg, '^exos_api_write: ', ''), 300), 'write_id', v_id);
  END IF;
  RETURN jsonb_build_object('ok', true, 'write_id', v_id, 'result', coalesce(v_out, '{}'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_write(text, uuid, text, uuid, text, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_write(text, uuid, text, uuid, text, text, text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. What the previews read, for the credential's org only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_mcp_fee_outcome(p_org uuid, p_event uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event AND e.org_id = p_org) THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'event_id', p_event,
    'free_tier', public.exos_event_is_free_tier(p_event),
    'max_capacity', public.exos_event_max_capacity(p_event),
    'bounded', public.exos_event_capacity_bounded(p_event),
    'free_tier_max_capacity', public.exos_free_tier_max_capacity());
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_fee_outcome(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_fee_outcome(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_mcp_event_state(p_org uuid, p_event uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event AND org_id = p_org;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at,
                                'ends_at', e.ends_at, 'timezone', e.timezone, 'currency', coalesce(e.currency, 'USD'),
                                'venue_name', e.venue_name, 'total_tickets', e.total_tickets),
    'ticket_types', coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'price', t.price,
                                                                  'capacity', t.capacity, 'visibility', t.visibility,
                                                                  'sales_start', t.sales_start, 'sales_end', t.sales_end)
                                               ORDER BY t.sort_order, t.created_at)
                                FROM public.exos_ticket_tiers t WHERE t.event_id = e.id), '[]'::jsonb),
    'blockers', public._exos_event_publish_blockers(e.id));
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_event_state(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_event_state(uuid, uuid) TO service_role;
