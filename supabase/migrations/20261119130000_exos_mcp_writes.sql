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
--      was disabled are refused; the token's consented scopes are capped by
--      its grant and narrowed to the user's role NOW), and runs as that user
--      instead of a key's creator. Only three actions are open to user tokens
--      (_exos_api_user_token_actions: event.create, ticket_type.create,
--      event.publish); every other action still needs an org API key
--      (42501). An OAuth token writes only on the API it was issued for:
--      p_token_resource (the caller's canonical URL) must be an Exos resource
--      and equal the token's resource (RFC 8707). The key path is unchanged.
--      The signature gains five defaulted parameters (p_token_hash,
--      p_token_kind, p_token_org, p_source, p_token_resource), so calls with
--      the old five arguments still resolve to it; the old five-argument
--      function is dropped (two would be ambiguous). A later migration that
--      patches it names
--      public.exos_api_write(uuid,text,text,jsonb,text,text,text,uuid,text,text).
--   2. exos_api_writes records the credential (kind api_key / pat / oauth and
--      its id: the key's, the personal token's, the OAuth grant's) and the
--      source (api / mcp). Idempotency-Keys are unique per credential; the
--      claim takes no conflict target, so a twin on either unique index waits
--      and replays (tests/exos/race_idem.sh). A BEFORE INSERT trigger fills the
--      credential from api_key_id for the other writers
--      (exos_api_commerce_write, _order_write, _gap_write).
--   2b. OAuth: authorization accepts only Exos resources
--      (_exos_oauth_resources: exos-api's and exos-mcp's canonical URLs,
--      platform setting oauth_resources elsewhere); a token's scopes are capped
--      by its grant's current scopes (exos_api_token_auth, exos_oauth_refresh,
--      exos_oauth_introspect), and re-consenting with fewer scopes revokes the
--      grant's live tokens (exos_oauth_authorize_approve).
--   3. 'mcp' is an org-audit source (exos_org_audit.source, _exos_audit_actor).
--   4. MCP write confirmations (exos_mcp_confirms) for drafts and ticket types:
--      the first call gets a preview and a confirm token (32 random bytes, only
--      its SHA-256 stored), bound to the credential, the tool and the exact
--      action / target / args (_exos_api_request_hash), 10 minutes, single
--      use; owner / manager only, refused before anything counts. The second
--      sends it back: exos_mcp_write checks it under a row lock, counts the
--      org's MCP writes that ran in the last hour (20, mcp_writes_per_hour)
--      and the credential's attempts (60, mcp_attempts_per_hour), spends it,
--      and calls exos_api_write with source mcp. Changed args burn the token.
--      The token goes back to the same assistant: it is not the person's
--      consent, so it guards only drafts.
--   5. exos_mcp_writes: one row per attempt (done / failed / blocked /
--      refused + reason), plus an exos_org_audit row mcp.write (source mcp)
--      for writes that ran and publishes.
--   6. exos_mcp_event_state / exos_mcp_fee_outcome: what the previews show
--      (the event, its ticket types, its publish blockers, its digest; the
--      free tier), for the credential's org only (NULL for another org's).
--   7. Publishing waits for the person: exos_mcp_publish_request (a review
--      bound to the event's digest, 30 minutes) and, on the SPA's review page,
--      exos_mcp_publish_review / exos_mcp_publish_approve (authenticated: the
--      request's own user, owner / manager; publishes through
--      exos_publish_event only if the event is unchanged).
--
-- All new functions are SECURITY DEFINER with a pinned search_path and
-- service_role EXECUTE only (exos-mcp / exos-api), except the review page's
-- two (authenticated); nothing is granted to anon; authenticated also gets
-- SELECT on exos_mcp_writes (owner / manager, RLS).
-- Re-run safe. Prod apply needs operator OK.
--
-- Touches:  W: FUNCTION exos_api_write (widened, see 1), _exos_audit_actor
--              (patched: 'mcp' source), exos_api_token_auth, exos_oauth_refresh,
--              exos_oauth_introspect (patched: grant cap),
--              exos_oauth_authorize_approve (patched: Exos resources only,
--              narrowed grant revokes tokens)
--              TABLE exos_api_writes (+ credential_kind, credential_id, source;
--              index, trigger), exos_org_audit (source CHECK + 'mcp')
--           C: TABLE exos_mcp_confirms, exos_mcp_writes, exos_mcp_publish_requests
--              FUNCTION _exos_api_user_token_actions, _exos_tg_api_writes_cred,
--              _exos_oauth_resources, _exos_oauth_grant_cap, _exos_mcp_tool_action,
--              _exos_mcp_credential, _exos_mcp_log, _exos_mcp_attempts_over,
--              _exos_mcp_event_digest, _exos_mcp_review_row,
--              exos_mcp_confirm_issue, exos_mcp_write, exos_mcp_event_state,
--              exos_mcp_fee_outcome, exos_mcp_publish_request,
--              exos_mcp_publish_status, exos_mcp_publish_review,
--              exos_mcp_publish_approve
--           R: exos_api_keys, exos_personal_tokens, exos_oauth_*, exos_events,
--              exos_ticket_tiers, exos_org_memberships, exos_platform_settings
--           Calls (unchanged): exos_api_token_auth_org, _exos_api_request_hash,
--              _exos_event_publish_blockers, exos_publish_event,
--              exos_event_is_free_tier, exos_event_max_capacity,
--              exos_event_capacity_bounded, exos_free_tier_max_capacity,
--              _exos_setting_int, _exos_audit
-- Pre-reqs: 20261031110000 (exos_api_write), 20261031130500 (user tokens,
--           OAuth), 20261104130000 (request hash), 20261105120000 (X-Exos-Org),
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
-- 2b. OAuth: Exos resources only, and the grant caps its tokens.
-- ---------------------------------------------------------------------------
-- The resources (RFC 8707) an OAuth token may be issued for: exos-api's
-- canonical URL and exos-mcp's organizer URL, exactly (no trailing slash).
-- Platform setting oauth_resources (a JSON array of https URLs) for another
-- install; the default is this project's.
CREATE OR REPLACE FUNCTION public._exos_oauth_resources()
RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb; r text[];
BEGIN
  SELECT value INTO v FROM public.exos_platform_settings WHERE key = 'oauth_resources';
  IF jsonb_typeof(v) = 'array' THEN
    r := ARRAY(SELECT x FROM jsonb_array_elements_text(v) x WHERE x ~ '^https://[^[:space:]/]+(/[^[:space:]]*)?$' AND x !~ '/$');
    IF cardinality(r) > 0 THEN RETURN r; END IF;
  END IF;
  RETURN ARRAY['https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-api',
               'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-mcp/organizer'];
END $$;
REVOKE ALL ON FUNCTION public._exos_oauth_resources() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_oauth_resources() TO service_role;

-- A token's scopes, capped by its grant's current scopes (none once revoked):
-- re-consenting with fewer scopes narrows every live token of the grant.
CREATE OR REPLACE FUNCTION public._exos_oauth_grant_cap(p_scopes text[], p_grant uuid)
RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(ARRAY(SELECT s FROM unnest(coalesce(p_scopes, '{}')) s
                         WHERE s = ANY (coalesce((SELECT g.scopes FROM public.exos_oauth_grants g
                                                   WHERE g.id = p_grant AND g.revoked_at IS NULL), '{}'))), '{}')
$$;
REVOKE ALL ON FUNCTION public._exos_oauth_grant_cap(text[], uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_oauth_grant_cap(text[], uuid) TO service_role;

SELECT pg_temp.exos_patch_n('public.exos_api_token_auth(text,text)', '/* exos: grant caps token */',
  '''scopes'', to_jsonb(public._exos_scopes_for_role(t.scopes, v_role, t.org_id)), ''token_scopes'', to_jsonb(t.scopes));',
  '''scopes'', to_jsonb(public._exos_scopes_for_role(public._exos_oauth_grant_cap(t.scopes, t.grant_id) /* exos: grant caps token */, v_role, t.org_id)), ''token_scopes'', to_jsonb(t.scopes));', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_refresh(text,text,text,text[])', '/* exos: grant caps token */',
  E'  v_scopes := t.scopes;\n',
  E'  v_scopes := public._exos_oauth_grant_cap(t.scopes, g.id); /* exos: grant caps token */\n', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_introspect(text,text,text)', '/* exos: grant caps token */',
  'public._exos_scopes_for_role(t.scopes, v_role, t.org_id)',
  'public._exos_scopes_for_role(public._exos_oauth_grant_cap(t.scopes, t.grant_id) /* exos: grant caps token */, v_role, t.org_id)', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_authorize_approve(text,text,text,uuid,text,text,text)', '/* exos: exos resources only */',
  E'    RAISE EXCEPTION ''invalid_target: resource must be an https URL'' USING ERRCODE = ''22023'';\n  END IF;\n',
  E'    RAISE EXCEPTION ''invalid_target: resource must be an https URL'' USING ERRCODE = ''22023'';\n  END IF;\n' ||
  E'  IF p_resource IS NOT NULL AND NOT (p_resource = ANY (public._exos_oauth_resources())) THEN /* exos: exos resources only */\n' ||
  E'    RAISE EXCEPTION ''invalid_target: resource must be the Exos API or the Exos MCP organizer URL'' USING ERRCODE = ''22023'';\n' ||
  E'  END IF;\n', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_authorize_approve(text,text,text,uuid,text,text,text)', '/* exos: narrowed grant revokes tokens */',
  E'  ELSIF g.scopes IS DISTINCT FROM v_scopes THEN\n    UPDATE public.exos_oauth_grants SET scopes = v_scopes WHERE id = g.id;\n',
  E'  ELSIF g.scopes IS DISTINCT FROM v_scopes THEN\n' ||
  E'    -- Fewer scopes than before: every live token of the grant ends now.\n' ||
  E'    IF EXISTS (SELECT 1 FROM unnest(g.scopes) s WHERE NOT (s = ANY (v_scopes))) THEN /* exos: narrowed grant revokes tokens */\n' ||
  E'      UPDATE public.exos_oauth_tokens SET revoked_at = now() WHERE grant_id = g.id AND revoked_at IS NULL;\n' ||
  E'    END IF;\n' ||
  E'    UPDATE public.exos_oauth_grants SET scopes = v_scopes WHERE id = g.id;\n', 1);

-- ---------------------------------------------------------------------------
-- 3. exos_api_write: a key or a user token, resolved in one place.
--    Built from the live body (prod's, by rule 4), then the five-argument
--    function is replaced by the ten-argument one. Re-run: when the old one
--    exists again (the replay re-creates it from 20261031110000) it is rebuilt
--    and every other overload is dropped first.
-- ---------------------------------------------------------------------------
DO $mig$
DECLARE
  v_old regprocedure := to_regprocedure('public.exos_api_write(uuid,text,text,jsonb,text)');
  v_new regprocedure := to_regprocedure('public.exos_api_write(uuid,text,text,jsonb,text,text,text,uuid,text,text)');
  d text;
  f regprocedure;
BEGIN
  IF v_old IS NULL THEN
    IF v_new IS NULL THEN RAISE EXCEPTION 'exos_api_write: not present'; END IF;
    RAISE NOTICE 'exos_api_write: already takes user tokens';
    RETURN;
  END IF;
  d := replace(pg_get_functiondef(v_old), chr(13), '');

  d := pg_temp.exos_sub(d, 'signature',
    'p_idempotency_key text DEFAULT NULL::text)',
    'p_idempotency_key text DEFAULT NULL::text, p_token_hash text DEFAULT NULL::text, p_token_kind text DEFAULT NULL::text, p_token_org uuid DEFAULT NULL::uuid, p_source text DEFAULT ''api''::text, p_token_resource text DEFAULT NULL::text)', 1);

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
    E'    -- The audience (RFC 8707): an OAuth token writes only on the Exos API it was\n' ||
    E'    -- issued for (p_token_resource, the caller''s own canonical URL), never one\n' ||
    E'    -- issued for another resource, or for none.\n' ||
    E'    IF p_token_kind = ''oauth'' AND (p_token_resource IS NULL\n' ||
    E'         OR NOT (p_token_resource = ANY (public._exos_oauth_resources()))\n' ||
    E'         OR (v_tok ->> ''resource'') IS DISTINCT FROM p_token_resource) THEN\n' ||
    E'      RAISE EXCEPTION ''exos_api_write: this OAuth token was not issued for this API (resource)'' USING ERRCODE = ''42501'';\n' ||
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
    -- No conflict target: a twin on either unique index (the key's old one or
    -- the credential's) waits, then does nothing and replays below.
    E'    ON CONFLICT DO NOTHING\n', 1);
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

  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'exos_api_write' AND p.oid <> v_old::oid LOOP
    EXECUTE 'DROP FUNCTION ' || f::text;
  END LOOP;
  DROP FUNCTION public.exos_api_write(uuid, text, text, jsonb, text);
  EXECUTE d;
END $mig$;
REVOKE ALL ON FUNCTION public.exos_api_write(uuid, text, text, jsonb, text, text, text, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_write(uuid, text, text, jsonb, text, text, text, uuid, text, text) TO service_role;

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

-- One row per MCP write attempt: done / failed (it ran), blocked (publish
-- blockers), refused (credential, role, confirmation, rate limit: `reason`).
-- Only `done` counts toward the org's hourly cap; every row toward the
-- credential's.
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
  status          text NOT NULL DEFAULT 'started',
  reason          text,
  error_code      text CHECK (error_code IS NULL OR error_code ~ '^[A-Z0-9]{5}$'),
  created_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz
);
ALTER TABLE public.exos_mcp_writes ADD COLUMN IF NOT EXISTS reason text;
ALTER TABLE public.exos_mcp_writes DROP CONSTRAINT IF EXISTS exos_mcp_writes_status_check;
ALTER TABLE public.exos_mcp_writes ADD CONSTRAINT exos_mcp_writes_status_check
  CHECK (status IN ('started', 'done', 'failed', 'refused', 'blocked'));
ALTER TABLE public.exos_mcp_writes DROP CONSTRAINT IF EXISTS exos_mcp_writes_reason_check;
ALTER TABLE public.exos_mcp_writes ADD CONSTRAINT exos_mcp_writes_reason_check
  CHECK (reason IS NULL OR reason ~ '^[a-z_]{2,40}$');
CREATE INDEX IF NOT EXISTS exos_mcp_writes_org_idx ON public.exos_mcp_writes (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_mcp_writes_cred_idx ON public.exos_mcp_writes (credential_kind, credential_id, created_at DESC);
ALTER TABLE public.exos_mcp_writes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_mcp_writes_sel ON public.exos_mcp_writes;
CREATE POLICY exos_mcp_writes_sel ON public.exos_mcp_writes FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
REVOKE ALL ON public.exos_mcp_writes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_mcp_writes TO authenticated;
GRANT ALL ON public.exos_mcp_writes TO service_role;

-- Publishing from an assistant waits for the person (section 7).
CREATE TABLE IF NOT EXISTS public.exos_mcp_publish_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  credential_kind text NOT NULL CHECK (credential_kind IN ('api_key', 'pat', 'oauth')),
  credential_id   uuid NOT NULL,
  actor           uuid NOT NULL,
  digest          text NOT NULL CHECK (digest ~ '^[0-9a-f]{64}$'),
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'published', 'blocked', 'changed', 'expired', 'cancelled')),
  expires_at      timestamptz NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  decided_at      timestamptz
);
CREATE INDEX IF NOT EXISTS exos_mcp_publish_requests_cred_idx
  ON public.exos_mcp_publish_requests (credential_kind, credential_id, status);
ALTER TABLE public.exos_mcp_publish_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_mcp_publish_requests FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_mcp_publish_requests TO service_role;

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

-- The previous version of this migration's helper (four arguments).
DROP FUNCTION IF EXISTS public._exos_mcp_credential(uuid, text, uuid, text);
DROP FUNCTION IF EXISTS public.exos_mcp_confirm_issue(uuid, text, uuid, text, text, text, text, jsonb, text);
DROP FUNCTION IF EXISTS public.exos_mcp_write(text, uuid, text, uuid, text, text, text, text, jsonb);

-- The credential's actor, if it is live and belongs to p_org; else NULL.
-- A key: not revoked, its creator an active member. A user token: the same
-- resolution as exos_api_write (exos_api_token_auth_org), the same id, and an
-- OAuth token only when it was issued for p_resource exactly (exos-mcp's
-- canonical URL), never one with no resource.
CREATE OR REPLACE FUNCTION public._exos_mcp_credential(p_org uuid, p_kind text, p_cred uuid, p_bearer_hash text, p_resource text)
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
    IF p_kind = 'oauth' AND (p_resource IS NULL OR NOT (p_resource = ANY (public._exos_oauth_resources()))
                             OR (v ->> 'resource') IS DISTINCT FROM p_resource) THEN
      RETURN NULL;
    END IF;
    RETURN (v ->> 'user_id')::uuid;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_mcp_credential(uuid, text, uuid, text, text) FROM PUBLIC, anon, authenticated;

-- An MCP write attempt that didn't run (or a publish the blockers stopped).
CREATE OR REPLACE FUNCTION public._exos_mcp_log(
  p_org uuid, p_kind text, p_cred uuid, p_actor uuid, p_tool text, p_target text, p_status text, p_reason text,
  p_event uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_map text[] := public._exos_mcp_tool_action(p_tool); v_id uuid;
BEGIN
  IF v_map IS NULL OR p_cred IS NULL OR p_kind NOT IN ('api_key', 'pat', 'oauth')
     OR NOT EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org) THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.exos_mcp_writes (org_id, credential_kind, credential_id, actor, tool, route_id, action, target,
                                      event_id, status, reason, finished_at)
  VALUES (p_org, p_kind, p_cred, p_actor, p_tool, v_map[2], v_map[1], left(p_target, 255), p_event, p_status, p_reason, now())
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_mcp_log(uuid, text, uuid, uuid, text, text, text, text, uuid) FROM PUBLIC, anon, authenticated;

-- The credential's MCP attempts in the last hour (every status).
CREATE OR REPLACE FUNCTION public._exos_mcp_attempts_over(p_kind text, p_cred uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT count(*) >= public._exos_setting_int('mcp_attempts_per_hour', 60, 1, 10000)
    FROM public.exos_mcp_writes
   WHERE credential_kind = p_kind AND credential_id = p_cred AND created_at > now() - interval '1 hour'
$$;
REVOKE ALL ON FUNCTION public._exos_mcp_attempts_over(text, uuid) FROM PUBLIC, anon, authenticated;

-- First call: store a confirmation for exactly this write. Drafts and ticket
-- types only; publishing goes through a review link (section 7).
CREATE OR REPLACE FUNCTION public.exos_mcp_confirm_issue(
  p_org uuid, p_cred_kind text, p_cred uuid, p_bearer_hash text, p_resource text, p_tool text,
  p_action text, p_target text, p_args jsonb, p_confirm_hash text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_map text[] := public._exos_mcp_tool_action(p_tool); v_live int; v_exp timestamptz; v_actor uuid;
BEGIN
  IF v_map IS NULL OR v_map[1] IS DISTINCT FROM p_action OR p_tool = 'publish_event' THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: unknown tool' USING ERRCODE = '22023';
  END IF;
  IF p_confirm_hash IS NULL OR p_confirm_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: bad confirmation' USING ERRCODE = '22023';
  END IF;
  v_actor := public._exos_mcp_credential(p_org, p_cred_kind, p_cred, p_bearer_hash, p_resource);
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: invalid or revoked credential' USING ERRCODE = '42501';
  END IF;
  -- Before anything is counted: only those who may make these changes in the
  -- dashboard (owner / manager now) may ask for one.
  IF public._exos_member_role(p_org, v_actor) IS DISTINCT FROM 'owner'
     AND public._exos_member_role(p_org, v_actor) IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: only an owner or manager can create events from an AI assistant'
      USING ERRCODE = '42501';
  END IF;
  IF public._exos_mcp_attempts_over(p_cred_kind, p_cred) THEN
    RAISE EXCEPTION 'exos_mcp_confirm_issue: too many attempts from this credential in the last hour' USING ERRCODE = '54000';
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
REVOKE ALL ON FUNCTION public.exos_mcp_confirm_issue(uuid, text, uuid, text, text, text, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_confirm_issue(uuid, text, uuid, text, text, text, text, text, jsonb, text) TO service_role;

-- Second call: check and spend the confirmation, count the hour, write.
-- Answers { ok: true, write_id, result } or { ok: false, error, message }
-- (credential / role / confirm_invalid / confirm_used / confirm_expired /
-- confirm_mismatch / rate_limited / write_failed with the SQLSTATE in code).
-- Every refusal is logged (status refused, the reason) except one over the
-- credential's own cap, so a flood can't grow the log. A mismatch burns the
-- confirmation; the org cap leaves it for later; a failed write spends it.
CREATE OR REPLACE FUNCTION public.exos_mcp_write(
  p_confirm_hash text, p_org uuid, p_cred_kind text, p_cred uuid, p_bearer_hash text, p_resource text, p_tool text,
  p_action text, p_target text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c        public.exos_mcp_confirms%ROWTYPE;
  v_map    text[] := public._exos_mcp_tool_action(p_tool);
  v_actor  uuid;
  v_role   text;
  v_n      int;
  v_cap    int := public._exos_setting_int('mcp_writes_per_hour', 20, 1, 1000);
  v_id     uuid;
  v_out    jsonb;
  v_state  text;
  v_msg    text;
  v_event  uuid;
  v_oldest timestamptz;
  v_why    text;
BEGIN
  IF v_map IS NULL OR v_map[1] IS DISTINCT FROM p_action OR p_tool = 'publish_event' THEN
    RAISE EXCEPTION 'exos_mcp_write: unknown tool' USING ERRCODE = '22023';
  END IF;
  IF public._exos_mcp_attempts_over(p_cred_kind, p_cred) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after_seconds', 3600,
      'message', 'too many attempts from this credential in the last hour; try again later');
  END IF;
  v_actor := public._exos_mcp_credential(p_org, p_cred_kind, p_cred, p_bearer_hash, p_resource);
  IF v_actor IS NULL THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, NULL, p_tool, p_target, 'refused', 'credential');
    RETURN jsonb_build_object('ok', false, 'error', 'credential', 'message', 'invalid or revoked credential');
  END IF;
  v_role := public._exos_member_role(p_org, v_actor);
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, v_actor, p_tool, p_target, 'refused', 'role');
    RETURN jsonb_build_object('ok', false, 'error', 'role',
      'message', 'only an owner or manager can create events from an AI assistant');
  END IF;
  SELECT * INTO c FROM public.exos_mcp_confirms WHERE token_hash = p_confirm_hash FOR UPDATE;
  v_why := CASE
    WHEN c.token_hash IS NULL OR c.org_id <> p_org OR c.credential_kind <> p_cred_kind OR c.credential_id <> p_cred THEN 'confirm_invalid'
    WHEN c.used_at IS NOT NULL THEN 'confirm_used'
    WHEN c.expires_at <= now() THEN 'confirm_expired'
    WHEN c.tool <> p_tool OR c.action <> p_action OR c.target IS DISTINCT FROM left(p_target, 255)
      OR c.request_hash <> public._exos_api_request_hash(p_action, p_target, coalesce(p_args, '{}'::jsonb)) THEN 'confirm_mismatch'
  END;
  IF v_why IS NOT NULL THEN
    IF v_why = 'confirm_mismatch' THEN
      UPDATE public.exos_mcp_confirms SET used_at = now() WHERE token_hash = p_confirm_hash;
    END IF;
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, v_actor, p_tool, p_target, 'refused', v_why);
    RETURN jsonb_build_object('ok', false, 'error', v_why, 'message', CASE v_why
      WHEN 'confirm_invalid' THEN 'this confirm_token is not valid; call the tool again without one for a new preview'
      WHEN 'confirm_used' THEN 'this confirm_token was already used; call the tool again without one for a new preview'
      WHEN 'confirm_expired' THEN 'this confirm_token expired (10 minutes); call the tool again without one for a new preview'
      ELSE 'the arguments changed since the preview, so that confirm_token no longer applies; call the tool again without one for a new preview'
    END);
  END IF;

  -- The org's MCP writes that ran in the last hour (refusals don't count).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-mcp-writes:' || p_org::text, 0));
  SELECT count(*), min(created_at) INTO v_n, v_oldest FROM public.exos_mcp_writes
   WHERE org_id = p_org AND status = 'done' AND created_at > now() - interval '1 hour';
  IF v_n >= v_cap THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, v_actor, p_tool, p_target, 'refused', 'rate_limited');
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited',
      'message', format('this organization has made %s changes from an AI assistant in the last hour (the most is %s); try again later', v_n, v_cap),
      'retry_after_seconds', greatest(1, ceil(extract(epoch FROM (v_oldest + interval '1 hour' - now())))::int));
  END IF;

  UPDATE public.exos_mcp_confirms SET used_at = now() WHERE token_hash = p_confirm_hash;
  INSERT INTO public.exos_mcp_writes (org_id, credential_kind, credential_id, actor, tool, route_id, action, target)
  VALUES (p_org, p_cred_kind, p_cred, v_actor, p_tool, v_map[2], p_action, left(p_target, 255))
  RETURNING id INTO v_id;

  BEGIN
    IF p_cred_kind = 'api_key' THEN
      v_out := public.exos_api_write(p_cred, p_action, p_target, coalesce(p_args, '{}'::jsonb),
                                     'mcp-' || replace(v_id::text, '-', ''), NULL, NULL, NULL, 'mcp', NULL);
    ELSE
      v_out := public.exos_api_write(NULL, p_action, p_target, coalesce(p_args, '{}'::jsonb),
                                     'mcp-' || replace(v_id::text, '-', ''), p_bearer_hash, p_cred_kind, p_org, 'mcp', p_resource);
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
REVOKE ALL ON FUNCTION public.exos_mcp_write(text, uuid, text, uuid, text, text, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_write(text, uuid, text, uuid, text, text, text, text, text, jsonb) TO service_role;

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

-- What a publish would make public: the event's buyer-facing fields and every
-- ticket type (id, name, price and steps, quantity, kind, visibility, sale
-- window, last change), as SHA-256 hex. Any edit in between changes it.
CREATE OR REPLACE FUNCTION public._exos_mcp_event_digest(p_event uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT encode(sha256(convert_to(jsonb_build_object(
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at,
      'ends_at', e.ends_at, 'doors_at', e.doors_at, 'timezone', e.timezone, 'currency', e.currency,
      'venue_name', e.venue_name, 'venue_address', e.venue_address, 'total_tickets', e.total_tickets,
      'format', e.format, 'description', e.description, 'image_url', e.image_url, 'updated_at', e.updated_at),
    'ticket_types', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'price', t.price, 'price_schedule', t.price_schedule,
               'capacity', t.capacity, 'ticket_type', t.ticket_type, 'kind', t.kind, 'party_size', t.party_size,
               'visibility', t.visibility, 'sales_start', t.sales_start, 'sales_end', t.sales_end,
               'updated_at', t.updated_at) ORDER BY t.id)
        FROM public.exos_ticket_tiers t WHERE t.event_id = e.id), '[]'::jsonb),
    -- What else the buyer pays (Applier #129 pass 2, info 2): add-ons and the
    -- event's fee settings. Whole rows, so any column change is a new digest.
    'add_ons', coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
                           FROM public.exos_event_addons a WHERE a.event_id = e.id), '[]'::jsonb),
    'fee_settings', (SELECT to_jsonb(f) FROM public.exos_event_fee_settings f WHERE f.event_id = e.id)
    )::text, 'UTF8')), 'hex')
    FROM public.exos_events e WHERE e.id = p_event
$$;
REVOKE ALL ON FUNCTION public._exos_mcp_event_digest(uuid) FROM PUBLIC, anon, authenticated;

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
    'blockers', public._exos_event_publish_blockers(e.id),
    'digest', public._exos_mcp_event_digest(e.id));
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_event_state(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_event_state(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Publishing waits for the person. An assistant's publish_event asks for a
--    review (exos_mcp_publish_request: the event as previewed, its digest, 30
--    minutes). The person opens /orgs/<org>/events/<id>/publish-review in
--    Exos, signed in as the credential's user, sees the event as it is now and
--    clicks Publish (exos_mcp_publish_approve), which publishes only if the
--    event is still exactly what the assistant previewed. The assistant can't
--    complete a publish on its own.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_mcp_publish_request(
  p_org uuid, p_cred_kind text, p_cred uuid, p_bearer_hash text, p_resource text, p_event uuid, p_digest text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid; v_role text; e public.exos_events%ROWTYPE; v_blk jsonb; v_id uuid; v_exp timestamptz; v_open int;
BEGIN
  IF public._exos_mcp_attempts_over(p_cred_kind, p_cred) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after_seconds', 3600,
      'message', 'too many attempts from this credential in the last hour; try again later');
  END IF;
  v_actor := public._exos_mcp_credential(p_org, p_cred_kind, p_cred, p_bearer_hash, p_resource);
  IF v_actor IS NULL THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, NULL, 'publish_event', p_event::text, 'refused', 'credential');
    RETURN jsonb_build_object('ok', false, 'error', 'credential', 'message', 'invalid or revoked credential');
  END IF;
  v_role := public._exos_member_role(p_org, v_actor);
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, v_actor, 'publish_event', p_event::text, 'refused', 'role');
    RETURN jsonb_build_object('ok', false, 'error', 'role', 'message', 'only an owner or manager can publish');
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event AND org_id = p_org;
  IF NOT FOUND THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, v_actor, 'publish_event', p_event::text, 'refused', 'not_found');
    RETURN jsonb_build_object('ok', false, 'error', 'not_found', 'message', 'no event with that id in your organization');
  END IF;
  IF e.status = 'published' THEN
    RETURN jsonb_build_object('ok', true, 'status', 'already_published', 'event_id', e.id);
  END IF;
  IF e.status <> 'draft' THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, v_actor, 'publish_event', p_event::text, 'refused', 'not_draft', e.id);
    RETURN jsonb_build_object('ok', false, 'error', 'not_draft', 'message', format('this event is %s and can''t be published', e.status));
  END IF;
  IF p_digest IS DISTINCT FROM public._exos_mcp_event_digest(e.id) THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, v_actor, 'publish_event', p_event::text, 'refused', 'changed', e.id);
    RETURN jsonb_build_object('ok', false, 'error', 'changed',
      'message', 'the event changed since the preview; call publish_event again for a new one');
  END IF;
  v_blk := public._exos_event_publish_blockers(e.id);
  IF jsonb_array_length(v_blk) > 0 THEN
    PERFORM public._exos_mcp_log(p_org, p_cred_kind, p_cred, v_actor, 'publish_event', p_event::text, 'blocked', 'blockers', e.id);
    RETURN jsonb_build_object('ok', false, 'error', 'blocked', 'blockers', v_blk, 'message', 'the event can''t be published yet');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-mcp-publish:' || p_cred::text, 0));
  -- One live request per event and credential; at most 10 open per credential.
  UPDATE public.exos_mcp_publish_requests SET status = 'cancelled', decided_at = now()
   WHERE credential_kind = p_cred_kind AND credential_id = p_cred AND event_id = e.id AND status = 'pending';
  SELECT count(*) INTO v_open FROM public.exos_mcp_publish_requests
   WHERE credential_kind = p_cred_kind AND credential_id = p_cred AND status = 'pending' AND expires_at > now();
  IF v_open >= 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after_seconds', 1800,
      'message', 'too many publish reviews are waiting; finish or let some expire first');
  END IF;
  v_exp := now() + interval '30 minutes';
  INSERT INTO public.exos_mcp_publish_requests (org_id, event_id, credential_kind, credential_id, actor, digest, expires_at)
  VALUES (p_org, e.id, p_cred_kind, p_cred, v_actor, p_digest, v_exp)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'status', 'pending', 'request_id', v_id, 'event_id', e.id, 'expires_at', v_exp);
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_publish_request(uuid, text, uuid, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_publish_request(uuid, text, uuid, text, text, uuid, text) TO service_role;

-- Where a request stands, for the credential that made it (else NULL).
CREATE OR REPLACE FUNCTION public.exos_mcp_publish_status(
  p_org uuid, p_cred_kind text, p_cred uuid, p_bearer_hash text, p_resource text, p_request uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_mcp_publish_requests%ROWTYPE;
BEGIN
  IF public._exos_mcp_credential(p_org, p_cred_kind, p_cred, p_bearer_hash, p_resource) IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.exos_mcp_publish_requests
   WHERE id = p_request AND org_id = p_org AND credential_kind = p_cred_kind AND credential_id = p_cred;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF r.status = 'pending' AND r.expires_at <= now() THEN
    UPDATE public.exos_mcp_publish_requests SET status = 'expired', decided_at = now() WHERE id = r.id;
    r.status := 'expired';
  END IF;
  RETURN jsonb_build_object('request_id', r.id, 'event_id', r.event_id, 'status', r.status, 'expires_at', r.expires_at,
                            'decided_at', r.decided_at);
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_publish_status(uuid, text, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_publish_status(uuid, text, uuid, text, text, uuid) TO service_role;

-- The review page (signed in). Only the credential's own user, still an
-- owner or manager of the org; anyone else, and an unknown id, get P0002.
CREATE OR REPLACE FUNCTION public._exos_mcp_review_row(p_request uuid, p_lock boolean)
RETURNS public.exos_mcp_publish_requests
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_mcp_publish_requests%ROWTYPE;
BEGIN
  IF p_lock THEN
    SELECT * INTO r FROM public.exos_mcp_publish_requests WHERE id = p_request FOR UPDATE;
  ELSE
    SELECT * INTO r FROM public.exos_mcp_publish_requests WHERE id = p_request;
  END IF;
  IF r.id IS NULL OR auth.uid() IS NULL OR r.actor <> auth.uid()
     OR NOT public.exos_has_org_role(r.org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'publish request not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION public._exos_mcp_review_row(uuid, boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_mcp_publish_review(p_request uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_mcp_publish_requests%ROWTYPE; v_app text;
BEGIN
  r := public._exos_mcp_review_row(p_request, false);
  IF r.status = 'pending' AND r.expires_at <= now() THEN
    UPDATE public.exos_mcp_publish_requests SET status = 'expired', decided_at = now() WHERE id = r.id;
    r.status := 'expired';
  END IF;
  IF r.credential_kind = 'oauth' THEN
    SELECT a.name INTO v_app FROM public.exos_oauth_grants g JOIN public.exos_oauth_apps a ON a.id = g.app_id
     WHERE g.id = r.credential_id;
  END IF;
  RETURN jsonb_build_object(
    'request', jsonb_build_object('id', r.id, 'status', r.status, 'expires_at', r.expires_at, 'created_at', r.created_at,
                                  'via', r.credential_kind, 'app', v_app),
    'state', public.exos_mcp_event_state(r.org_id, r.event_id),
    'fee', public.exos_mcp_fee_outcome(r.org_id, r.event_id),
    'unchanged', public._exos_mcp_event_digest(r.event_id) = r.digest);
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_publish_review(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_publish_review(uuid) TO authenticated, service_role;

-- The person's Publish click. Publishes through the dashboard's own
-- exos_publish_event as the signed-in user, only while the request is pending
-- and the event is exactly what was previewed (else changed / expired /
-- blocked, recorded). Answers { ok, status, event_id, blockers? }.
CREATE OR REPLACE FUNCTION public.exos_mcp_publish_approve(p_request uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_mcp_publish_requests%ROWTYPE; v_out jsonb; v_id uuid;
BEGIN
  r := public._exos_mcp_review_row(p_request, true);
  IF r.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'status', r.status, 'event_id', r.event_id);
  END IF;
  IF r.expires_at <= now() THEN
    UPDATE public.exos_mcp_publish_requests SET status = 'expired', decided_at = now() WHERE id = r.id;
    RETURN jsonb_build_object('ok', false, 'status', 'expired', 'event_id', r.event_id);
  END IF;
  PERFORM 1 FROM public.exos_events WHERE id = r.event_id FOR UPDATE;
  IF public._exos_mcp_event_digest(r.event_id) IS DISTINCT FROM r.digest THEN
    UPDATE public.exos_mcp_publish_requests SET status = 'changed', decided_at = now() WHERE id = r.id;
    PERFORM public._exos_mcp_log(r.org_id, r.credential_kind, r.credential_id, r.actor, 'publish_event', r.event_id::text,
                                 'refused', 'changed', r.event_id);
    RETURN jsonb_build_object('ok', false, 'status', 'changed', 'event_id', r.event_id);
  END IF;
  v_out := public.exos_publish_event(r.event_id);
  IF (v_out ->> 'published')::boolean IS NOT TRUE THEN
    UPDATE public.exos_mcp_publish_requests SET status = 'blocked', decided_at = now() WHERE id = r.id;
    PERFORM public._exos_mcp_log(r.org_id, r.credential_kind, r.credential_id, r.actor, 'publish_event', r.event_id::text,
                                 'blocked', 'blockers', r.event_id);
    RETURN jsonb_build_object('ok', false, 'status', 'blocked', 'event_id', r.event_id, 'blockers', v_out -> 'blockers');
  END IF;
  UPDATE public.exos_mcp_publish_requests SET status = 'published', decided_at = now() WHERE id = r.id;
  v_id := public._exos_mcp_log(r.org_id, r.credential_kind, r.credential_id, r.actor, 'publish_event', r.event_id::text,
                               'done', NULL, r.event_id);
  PERFORM public._exos_audit(r.org_id, 'mcp.write', 'mcp_write', v_id::text, r.event_id,
    jsonb_build_object('tool', 'publish_event', 'route', 'publish-event', 'credential', r.credential_kind,
                       'status', 'done', 'approved', 'review_page'),
    NULL, NULL, NULL, r.actor, CASE WHEN r.credential_kind = 'api_key' THEN r.credential_id END, 'mcp');
  RETURN jsonb_build_object('ok', true, 'status', 'published', 'event_id', r.event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_mcp_publish_approve(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_publish_approve(uuid) TO authenticated;
