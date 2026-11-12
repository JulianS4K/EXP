-- ============================================================================
-- Migration 20261113130000 — Exos (Bridge / D4): promote events on Discord
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_discord_links (one row per org: the channel
--              webhook's id + its token in Vault, the linked server, the
--              org's switches, broken marks), exos_discord_posts (one
--              announcement per event per kind), exos_discord_event_syncs
--              (one Discord scheduled event per Exos event),
--              exos_discord_platform (one row: the circuit breaker and the
--              global-429 pause). RLS on, no client grants.
--           C: FUNCTION exos_discord_status, exos_discord_set_webhook,
--              exos_discord_remove_webhook, exos_discord_set_options,
--              exos_discord_unlink_guild, exos_discord_event_status,
--              exos_discord_set_show, exos_discord_request_post
--              (authenticated; role checked here);
--              exos_discord_post_claim, exos_discord_post_mark,
--              exos_discord_sync_claim, exos_discord_sync_mark,
--              exos_discord_install_begin, exos_discord_install_consume,
--              exos_discord_guild_link, exos_discord_webhook_parts,
--              exos_discord_call_gate, exos_discord_call_result,
--              exos_discord_breaker_clear, _exos_discord_blocked,
--              _exos_discord_role (service role only)
--           C: TRIGGER exos_events_discord_ins / exos_events_discord_upd
--              (exos_tg_discord_event): re-sync a shown event, queue the
--              publish announcement when the org turned that on
--           W: TABLE exos_oauth_states (provider check + 'discord')
--           W: FUNCTION exos_oauth_state_begin (marker patch: + 'discord')
--           C: cron exos-discord-2min, created INACTIVE
--           R: exos_orgs, exos_org_memberships, exos_events, vault.*,
--              _exos_oauth_state_take, _exos_oauth_can_connect,
--              exos_rate_hit, _exos_audit
-- Pre-reqs: 20260930102000 + 20261029140000 (the shared OAuth states),
--           20261109100000 (_exos_audit), 20260929060000 (exos_rate_hit).
--
-- Operator ask (2026-11-11): "find and add Discord events as a way to
-- promote events". Two levels, both dark until EXOS_DISCORD_ENABLED=on and
-- both a dry run unless the org's switch AND EXOS_DISCORD_WRITES=on
-- (docs/discord.md):
--
--   1. Announcement webhook (no bot). An owner / manager pastes one of
--      their channel's webhook URLs. Only https://discord.com or
--      https://discordapp.com, /api[/vN]/webhooks/<id>/<token>, nothing else
--      (no port, query, fragment, user info or other host: no SSRF). The
--      token goes to Vault (exos_discord_webhook:<org>); the table keeps the
--      webhook id. On publish (when the org turned it on) or with "Post to
--      Discord", one embed goes out: at most one post per event per kind
--      (publish / reminder), 10 requests a minute and 30 posts an hour per
--      org, never a mention (the edge function sends allowed_mentions
--      parse: []).
--
--   2. Scheduled events (the platform's bot). "Add Exos bot to your server"
--      runs Discord's bot authorization with the shared OAuth state
--      (exos_oauth_states, provider 'discord': 10-minute single use, the
--      finish token in the fragment, bound to the starting user). The
--      server is read from Discord's token response, never from the
--      redirect's guild_id (Discord calls that a hint). One server links
--      to one org. "Show on Discord" per event keeps one EXTERNAL scheduled
--      event in step (create, update, cancel when the Exos event is
--      cancelled, delete when unticked or unpublished).
--
-- Circuit breaker (Discord bans an IP or token at 10,000 invalid requests in
-- 10 minutes): every call to Discord goes through exos_discord_call_gate
-- first (300 calls a minute across all orgs) and reports a refusal to
-- exos_discord_call_result. A 401 on the bot token halts every bot call
-- until the token changes or an operator runs exos_discord_breaker_clear();
-- more than 500 invalid answers (401 / 403 / non-shared 429) in 10 minutes
-- halts every Discord call until an operator clears it; a global 429 pauses
-- bot calls for its retry_after. A server that refuses the bot (403
-- 50001 / 50013, unknown guild 10004) is marked broken and skipped until it
-- is linked again; a webhook that's gone (10015, 401 / 403 / 404) is marked
-- broken and skipped until a new URL is saved.
--
-- Every change an organizer makes is audited (_exos_audit): discord.webhook_set,
-- .webhook_remove, .settings, .guild_link, .guild_unlink, .event_show, .post.
-- Errors never carry the webhook URL or token.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded constraints, marker
-- checked patch). D4 authors; applying to prod is operator-gated. NOT applied.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := pg_get_functiondef(p_fn);
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

-- ===========================================================================
-- 1. The shared OAuth state: 'discord' as a provider
-- ===========================================================================
DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'exos_oauth_states_provider_chk'
                    AND pg_get_constraintdef(oid) LIKE '%discord%') THEN
    ALTER TABLE public.exos_oauth_states DROP CONSTRAINT IF EXISTS exos_oauth_states_provider_chk;
    ALTER TABLE public.exos_oauth_states ADD CONSTRAINT exos_oauth_states_provider_chk
      CHECK (provider IN ('google_ads', 'eventbrite', 'discord'));
  END IF;
END $c$;

SELECT pg_temp.exos_patch_n('public.exos_oauth_state_begin(text, uuid, uuid, text, integer)',
  '''discord''',
  $o$p_provider NOT IN ('google_ads', 'eventbrite')$o$,
  $n$p_provider NOT IN ('google_ads', 'eventbrite', 'discord')$n$, 1);

-- ===========================================================================
-- 2. Tables
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_discord_links (
  org_id             uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- Level 1: the channel webhook. The id is in the URL Discord shows; the
  -- token is the secret (Vault exos_discord_webhook:<org>).
  webhook_id         text CONSTRAINT exos_discord_links_webhook_id_chk CHECK (webhook_id IS NULL OR webhook_id ~ '^[0-9]{17,20}$'),
  webhook_secret_id  uuid,
  webhook_set_by     uuid,
  webhook_set_at     timestamptz,
  -- Level 2: the server the platform bot was added to (from Discord's token response).
  guild_id           text CONSTRAINT exos_discord_links_guild_id_chk CHECK (guild_id IS NULL OR guild_id ~ '^[0-9]{17,20}$'),
  guild_name         text CHECK (guild_name IS NULL OR length(guild_name) <= 100),
  guild_linked_by    uuid,
  guild_linked_at    timestamptz,
  -- Discord refused them: skipped until a new webhook is saved / the server is linked again.
  webhook_broken_at  timestamptz,
  webhook_broken_reason text CHECK (webhook_broken_reason IS NULL OR length(webhook_broken_reason) <= 200),
  guild_broken_at    timestamptz,
  guild_broken_reason text CHECK (guild_broken_reason IS NULL OR length(guild_broken_reason) <= 200),
  -- The org's switches: writes (owner) and the publish announcement (owner / manager).
  writes_enabled     boolean NOT NULL DEFAULT false,
  auto_post          boolean NOT NULL DEFAULT false,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_discord_links_webhook_pair_chk CHECK ((webhook_id IS NULL) = (webhook_secret_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_discord_links_guild_uq ON public.exos_discord_links (guild_id) WHERE guild_id IS NOT NULL;
ALTER TABLE public.exos_discord_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_discord_links FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_discord_links TO service_role;
DROP TRIGGER IF EXISTS exos_discord_links_touch ON public.exos_discord_links;
CREATE TRIGGER exos_discord_links_touch BEFORE UPDATE ON public.exos_discord_links
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_discord_links IS
  'Discord per org: the channel webhook id (token in Vault exos_discord_webhook:<org>), the linked server, the switches. Service role only; exos_discord_* RPCs. mig 20261113130000.';

-- One row: the platform-wide circuit breaker. scope 'bot' (the bot token got
-- a 401: bot calls stop; cleared by a new token or the operator) or 'all'
-- (too many invalid answers: every Discord call stops; operator only).
-- bot_paused_until: a global 429 (every bot call waits).
CREATE TABLE IF NOT EXISTS public.exos_discord_platform (
  id               boolean PRIMARY KEY DEFAULT true CHECK (id),
  breaker_scope    text CHECK (breaker_scope IS NULL OR breaker_scope IN ('bot', 'all')),
  breaker_at       timestamptz,
  breaker_reason   text CHECK (breaker_reason IS NULL OR length(breaker_reason) <= 200),
  breaker_fp text CHECK (breaker_fp IS NULL OR breaker_fp ~ '^[0-9a-f]{16,64}$'),
  bot_paused_until timestamptz,
  updated_at       timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.exos_discord_platform (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.exos_discord_platform ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_discord_platform FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_discord_platform TO service_role;
COMMENT ON TABLE public.exos_discord_platform IS
  'Discord circuit breaker and global-429 pause, one row. Service role only; exos_discord_call_gate / _result / breaker_clear. mig 20261113130000.';

CREATE TABLE IF NOT EXISTS public.exos_discord_posts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id      uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  kind          text NOT NULL CONSTRAINT exos_discord_posts_kind_chk CHECK (kind IN ('publish', 'reminder')),
  status        text NOT NULL DEFAULT 'queued'
                  CONSTRAINT exos_discord_posts_status_chk CHECK (status IN ('queued', 'sending', 'sent', 'dry_run', 'error')),
  requested_by  uuid,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  attempts      integer NOT NULL DEFAULT 0,
  next_try_at   timestamptz NOT NULL DEFAULT now(),
  lease_id      uuid,
  lease_until   timestamptz,
  webhook_id    text CHECK (webhook_id IS NULL OR webhook_id ~ '^[0-9]{17,20}$'),
  message_id    text CHECK (message_id IS NULL OR message_id ~ '^[0-9]{17,20}$'),
  sent_at       timestamptz,
  plan          jsonb CHECK (plan IS NULL OR length(plan::text) <= 8000),
  last_error    text CHECK (last_error IS NULL OR length(last_error) <= 300),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_discord_posts_once UNIQUE (event_id, kind)
);
CREATE INDEX IF NOT EXISTS exos_discord_posts_due_idx ON public.exos_discord_posts (next_try_at) WHERE status IN ('queued', 'sending');
CREATE INDEX IF NOT EXISTS exos_discord_posts_org_idx ON public.exos_discord_posts (org_id, requested_at DESC);
ALTER TABLE public.exos_discord_posts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_discord_posts FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_discord_posts TO service_role;
DROP TRIGGER IF EXISTS exos_discord_posts_touch ON public.exos_discord_posts;
CREATE TRIGGER exos_discord_posts_touch BEFORE UPDATE ON public.exos_discord_posts
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_discord_posts IS
  'One Discord announcement per event per kind (publish / reminder) through the org''s channel webhook. Service role only. mig 20261113130000.';

CREATE TABLE IF NOT EXISTS public.exos_discord_event_syncs (
  event_id     uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  show         boolean NOT NULL DEFAULT true,
  -- The server and scheduled event Exos made (another server's id is never reused).
  guild_id     text CHECK (guild_id IS NULL OR guild_id ~ '^[0-9]{17,20}$'),
  external_id  text CHECK (external_id IS NULL OR external_id ~ '^[0-9]{17,20}$'),
  status       text NOT NULL DEFAULT 'pending'
                 CONSTRAINT exos_discord_syncs_status_chk CHECK (status IN ('pending', 'synced', 'dry_run', 'error', 'removed')),
  change_seq   bigint NOT NULL DEFAULT 1,
  synced_seq   bigint NOT NULL DEFAULT 0,
  last_hash    text CHECK (last_hash IS NULL OR length(last_hash) <= 128),
  plan         jsonb CHECK (plan IS NULL OR length(plan::text) <= 8000),
  planned_at   timestamptz,
  synced_at    timestamptz,
  attempts     integer NOT NULL DEFAULT 0,
  next_try_at  timestamptz NOT NULL DEFAULT now(),
  lease_id     uuid,
  lease_until  timestamptz,
  last_error   text CHECK (last_error IS NULL OR length(last_error) <= 300),
  created_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_discord_syncs_due_idx ON public.exos_discord_event_syncs (next_try_at) WHERE synced_seq < change_seq;
CREATE INDEX IF NOT EXISTS exos_discord_syncs_org_idx ON public.exos_discord_event_syncs (org_id);
ALTER TABLE public.exos_discord_event_syncs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_discord_event_syncs FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_discord_event_syncs TO service_role;
DROP TRIGGER IF EXISTS exos_discord_event_syncs_touch ON public.exos_discord_event_syncs;
CREATE TRIGGER exos_discord_event_syncs_touch BEFORE UPDATE ON public.exos_discord_event_syncs
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_discord_event_syncs IS
  'An Exos event shown on the org''s Discord server as an EXTERNAL scheduled event (Exos is the source). Service role only. mig 20261113130000.';

-- ===========================================================================
-- 3. Helpers
-- ===========================================================================
-- The caller's role (owner / manager) in the org, or NULL. A disabled
-- membership counts as none.
CREATE OR REPLACE FUNCTION public._exos_discord_role(p_org_id uuid, p_user_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT m.role FROM public.exos_org_memberships m
   WHERE p_org_id IS NOT NULL AND p_user_id IS NOT NULL
     AND m.org_id = p_org_id AND m.user_id = p_user_id AND m.disabled IS NOT TRUE
     AND m.role IN ('owner', 'manager')
   ORDER BY CASE m.role WHEN 'owner' THEN 0 ELSE 1 END
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_discord_role(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_discord_role(uuid, uuid) TO service_role;

-- A pasted channel webhook URL -> (webhook id, token), or no row. Only
--   https://discord.com/api[/v<n>]/webhooks/<17-20 digit id>/<token>
-- and the same on discordapp.com (Discord's older host). Anything else (a
-- port, user info, a query, a fragment, any other host or path, a
-- percent-escape, whitespace) gives no row: the edge function only ever
-- calls https://discord.com/api/v10/webhooks/<id>/<token> rebuilt from these
-- two parts, so a pasted URL can't steer a request anywhere else.
CREATE OR REPLACE FUNCTION public.exos_discord_webhook_parts(p_url text)
RETURNS TABLE (webhook_id text, token text)
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT m[1], m[2]
    FROM regexp_match(btrim(coalesce(p_url, '')),
           '^https://(?:discord\.com|discordapp\.com)/api(?:/v[0-9]{1,2})?/webhooks/([0-9]{17,20})/([A-Za-z0-9_-]{60,100})/?$') m
   WHERE length(coalesce(p_url, '')) <= 300 AND m IS NOT NULL
$$;
REVOKE ALL ON FUNCTION public.exos_discord_webhook_parts(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_webhook_parts(text) TO service_role;

-- Why a Discord call may not go out now, or NULL. p_kind 'bot' (guild
-- routes, the bot token) or 'webhook'. A 'bot' breaker set for another
-- token (p_token_fp: the first hex of the token's SHA-256) is cleared: the
-- operator rotated the token.
CREATE OR REPLACE FUNCTION public._exos_discord_blocked(p_kind text, p_token_fp text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE b public.exos_discord_platform%ROWTYPE;
BEGIN
  SELECT * INTO b FROM public.exos_discord_platform WHERE id;
  IF b.breaker_scope = 'all' THEN
    RETURN jsonb_build_object('reason', 'breaker', 'detail', b.breaker_reason, 'retry_after', 600);
  END IF;
  IF p_kind = 'bot' AND b.breaker_scope = 'bot' THEN
    IF p_token_fp IS NOT NULL AND b.breaker_fp IS NOT NULL AND p_token_fp <> b.breaker_fp THEN
      UPDATE public.exos_discord_platform SET breaker_scope = NULL, breaker_at = NULL, breaker_reason = NULL,
             breaker_fp = NULL, updated_at = now() WHERE id AND breaker_scope = 'bot';
    ELSE
      RETURN jsonb_build_object('reason', 'breaker', 'detail', b.breaker_reason, 'retry_after', 600);
    END IF;
  END IF;
  IF p_kind = 'bot' AND b.bot_paused_until > now() THEN
    RETURN jsonb_build_object('reason', 'paused', 'retry_after', ceil(extract(epoch FROM b.bot_paused_until - now()))::int);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_discord_blocked(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_discord_blocked(text, text) TO service_role;

-- Before every request to Discord: the breaker, the pause, then 300 calls a
-- minute across every org (counted here, so refused calls count too).
CREATE OR REPLACE FUNCTION public.exos_discord_call_gate(p_kind text, p_token_fp text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb;
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('bot', 'webhook') THEN
    RAISE EXCEPTION 'exos_discord_call_gate: bot or webhook' USING ERRCODE = '22023';
  END IF;
  v := public._exos_discord_blocked(p_kind, p_token_fp);
  IF v IS NOT NULL THEN
    RETURN v || jsonb_build_object('ok', false);
  END IF;
  IF NOT public.exos_rate_hit('discord_platform', 300) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'platform_cap', 'retry_after', 60);
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_call_gate(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_call_gate(text, text) TO service_role;

-- After a refused request: count it if Discord counts it as invalid (401,
-- 403, a 429 that isn't scope 'shared'); over 500 in 10 minutes trips the
-- breaker for every call. A 401 on a bot call trips it for bot calls. A
-- global 429 on a bot call pauses bot calls for retry_after.
CREATE OR REPLACE FUNCTION public.exos_discord_call_result(
  p_kind text, p_status int, p_code int DEFAULT NULL, p_global boolean DEFAULT false, p_scope text DEFAULT NULL,
  p_retry_after numeric DEFAULT NULL, p_token_fp text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_invalid boolean := coalesce(p_status IN (401, 403) OR (p_status = 429 AND coalesce(p_scope, '') <> 'shared'), false);
  v_n       bigint := 0;
  v_trip    text;
BEGIN
  IF v_invalid THEN
    PERFORM public.exos_rate_hit('discord_invalid', 2147483647);
    SELECT coalesce(sum(hits), 0) INTO v_n FROM public.exos_rate_windows
     WHERE bucket = 'discord_invalid' AND window_start > now() - interval '10 minutes';
  END IF;
  IF v_n > 500 THEN
    UPDATE public.exos_discord_platform
       SET breaker_scope = 'all', breaker_at = coalesce(CASE WHEN breaker_scope = 'all' THEN breaker_at END, now()),
           breaker_reason = 'more than 500 invalid Discord answers in 10 minutes', updated_at = now()
     WHERE id;
    v_trip := 'all';
  ELSIF p_kind = 'bot' AND p_status = 401 THEN
    UPDATE public.exos_discord_platform
       SET breaker_scope = 'bot', breaker_at = now(), breaker_reason = 'Discord refused the bot token (401)',
           breaker_fp = CASE WHEN p_token_fp ~ '^[0-9a-f]{16,64}$' THEN p_token_fp END, updated_at = now()
     WHERE id AND breaker_scope IS DISTINCT FROM 'all';
    v_trip := 'bot';
  END IF;
  IF p_kind = 'bot' AND p_status = 429 AND (coalesce(p_global, false) OR p_scope = 'global') THEN
    UPDATE public.exos_discord_platform
       SET bot_paused_until = greatest(coalesce(bot_paused_until, now()),
                                       now() + make_interval(secs => least(greatest(coalesce(p_retry_after, 1), 1), 3600)::double precision)),
           updated_at = now()
     WHERE id;
  END IF;
  RETURN jsonb_build_object('invalid', v_invalid, 'invalid_10min', v_n, 'tripped', v_trip);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_call_result(text, int, int, boolean, text, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_call_result(text, int, int, boolean, text, numeric, text) TO service_role;

-- Operator: clear the breaker and the pause (SELECT public.exos_discord_breaker_clear();).
CREATE OR REPLACE FUNCTION public.exos_discord_breaker_clear()
RETURNS boolean LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_discord_platform
     SET breaker_scope = NULL, breaker_at = NULL, breaker_reason = NULL, breaker_fp = NULL,
         bot_paused_until = NULL, updated_at = now()
   WHERE id
  RETURNING true
$$;
REVOKE ALL ON FUNCTION public.exos_discord_breaker_clear() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_breaker_clear() TO service_role;

-- ===========================================================================
-- 4. Organizer RPCs (authenticated; the role is checked here)
-- ===========================================================================
-- What the settings panel shows. Owner / manager (or a platform admin, read
-- only). Never the token or the full URL.
CREATE OR REPLACE FUNCTION public.exos_discord_status(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text := public._exos_discord_role(p_org_id, auth.uid());
  l      public.exos_discord_links%ROWTYPE;
BEGIN
  IF v_role IS NULL AND NOT public.exos_is_admin() THEN
    RAISE EXCEPTION 'exos_discord_status: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO l FROM public.exos_discord_links WHERE org_id = p_org_id;
  RETURN jsonb_build_object(
    'can_manage', v_role IS NOT NULL,
    'is_owner', v_role = 'owner',
    'webhook', jsonb_build_object('set', l.webhook_id IS NOT NULL, 'broken', l.webhook_broken_at IS NOT NULL AND l.webhook_id IS NOT NULL,
                                  'hint', CASE WHEN l.webhook_id IS NOT NULL THEN '…' || right(l.webhook_id, 4) END,
                                  'set_at', l.webhook_set_at, 'by_you', l.webhook_set_by IS NOT DISTINCT FROM auth.uid() AND l.webhook_id IS NOT NULL),
    'guild', jsonb_build_object('linked', l.guild_id IS NOT NULL, 'id', l.guild_id, 'name', l.guild_name,
                                'linked_at', l.guild_linked_at, 'broken', l.guild_broken_at IS NOT NULL AND l.guild_id IS NOT NULL),
    'paused', coalesce((SELECT b.breaker_scope IS NOT NULL FROM public.exos_discord_platform b WHERE b.id), false),
    'writes_enabled', coalesce(l.writes_enabled, false),
    'auto_post', coalesce(l.auto_post, false),
    'shown_events', (SELECT count(*) FROM public.exos_discord_event_syncs s WHERE s.org_id = p_org_id AND s.show),
    'posts_last_hour', (SELECT count(*) FROM public.exos_discord_posts p
                         WHERE p.org_id = p_org_id AND p.requested_at > now() - interval '1 hour'));
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_status(uuid) TO authenticated, service_role;

-- Owner / manager: save the channel webhook (replaces the old one).
CREATE OR REPLACE FUNCTION public.exos_discord_set_webhook(p_org_id uuid, p_url text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_name   text := 'exos_discord_webhook:' || coalesce(p_org_id::text, '');
  v_id     text;
  v_token  text;
  v_secret uuid;
  v_old    text;
BEGIN
  IF public._exos_discord_role(p_org_id, v_uid) IS NULL THEN
    RAISE EXCEPTION 'exos_discord_set_webhook: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('discord_cfg:' || v_uid::text, 10) THEN
    RAISE EXCEPTION 'exos_discord_set_webhook: too many changes, try again in a minute' USING ERRCODE = '54000';
  END IF;
  SELECT w.webhook_id, w.token INTO v_id, v_token FROM public.exos_discord_webhook_parts(p_url) w;
  IF v_id IS NULL THEN
    -- Never echo what was pasted.
    RAISE EXCEPTION 'exos_discord_set_webhook: that is not a Discord channel webhook URL (Channel settings, Integrations, Webhooks, Copy Webhook URL)'
      USING ERRCODE = '22023';
  END IF;

  SELECT webhook_id, webhook_secret_id INTO v_old, v_secret FROM public.exos_discord_links WHERE org_id = p_org_id FOR UPDATE;
  IF v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_secret) THEN
    SELECT id INTO v_secret FROM vault.secrets WHERE name = v_name;
  END IF;
  IF v_secret IS NULL THEN
    v_secret := vault.create_secret(v_token, v_name, 'Exos Discord channel webhook token');
  ELSE
    PERFORM vault.update_secret(v_secret, v_token);
  END IF;

  INSERT INTO public.exos_discord_links AS l (org_id, webhook_id, webhook_secret_id, webhook_set_by, webhook_set_at)
  VALUES (p_org_id, v_id, v_secret, v_uid, now())
  ON CONFLICT (org_id) DO UPDATE
     SET webhook_id = EXCLUDED.webhook_id, webhook_secret_id = EXCLUDED.webhook_secret_id,
         webhook_set_by = EXCLUDED.webhook_set_by, webhook_set_at = now(),
         webhook_broken_at = NULL, webhook_broken_reason = NULL;

  /* exos: audit discord.webhook_set */
  PERFORM public._exos_audit(p_org_id, 'discord.webhook_set', 'discord_webhook', p_org_id::text, NULL,
    jsonb_build_object('webhook', jsonb_build_array(CASE WHEN v_old IS NULL THEN 'none' ELSE '…' || right(v_old, 4) END,
                                                    '…' || right(v_id, 4))),
    NULL, NULL, NULL, v_uid, NULL, 'dashboard');
  RETURN jsonb_build_object('ok', true, 'hint', '…' || right(v_id, 4), 'replaced', v_old IS NOT NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_set_webhook(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_set_webhook(uuid, text) TO authenticated, service_role;

-- Owner / manager: forget the webhook (the token is deleted from Vault).
-- Announcements still waiting can't go out any more.
CREATE OR REPLACE FUNCTION public.exos_discord_remove_webhook(p_org_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_secret uuid;
  v_id     text;
BEGIN
  IF public._exos_discord_role(p_org_id, v_uid) IS NULL THEN
    RAISE EXCEPTION 'exos_discord_remove_webhook: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT webhook_id, webhook_secret_id INTO v_id, v_secret FROM public.exos_discord_links WHERE org_id = p_org_id FOR UPDATE;
  IF v_id IS NULL THEN
    RETURN false;
  END IF;
  UPDATE public.exos_discord_links SET webhook_id = NULL, webhook_secret_id = NULL, webhook_set_by = NULL, webhook_set_at = NULL,
         webhook_broken_at = NULL, webhook_broken_reason = NULL
   WHERE org_id = p_org_id;
  DELETE FROM vault.secrets WHERE id = v_secret OR name = 'exos_discord_webhook:' || p_org_id::text;
  UPDATE public.exos_discord_posts SET status = 'error', last_error = 'the Discord webhook was removed', lease_id = NULL, lease_until = NULL
   WHERE org_id = p_org_id AND status = 'queued';
  /* exos: audit discord.webhook_remove */
  PERFORM public._exos_audit(p_org_id, 'discord.webhook_remove', 'discord_webhook', p_org_id::text, NULL,
    jsonb_build_object('webhook', jsonb_build_array('…' || right(v_id, 4), 'none')), NULL, NULL, NULL, v_uid, NULL, 'dashboard');
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_remove_webhook(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_remove_webhook(uuid) TO authenticated, service_role;

-- The switches. Writes: owner only (as Eventbrite's); the publish
-- announcement: owner / manager. NULL leaves a switch as it is. Turning
-- writes on re-runs every shown event once (a dry run waits for a change).
CREATE OR REPLACE FUNCTION public.exos_discord_set_options(p_org_id uuid, p_writes boolean DEFAULT NULL, p_auto_post boolean DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text := public._exos_discord_role(p_org_id, auth.uid());
  l      public.exos_discord_links%ROWTYPE;
BEGIN
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'exos_discord_set_options: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_writes IS NOT NULL AND v_role <> 'owner' THEN
    RAISE EXCEPTION 'exos_discord_set_options: only an owner turns Discord writes on or off' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_discord_links (org_id) VALUES (p_org_id) ON CONFLICT (org_id) DO NOTHING;
  SELECT * INTO l FROM public.exos_discord_links WHERE org_id = p_org_id FOR UPDATE;
  UPDATE public.exos_discord_links
     SET writes_enabled = coalesce(p_writes, writes_enabled), auto_post = coalesce(p_auto_post, auto_post)
   WHERE org_id = p_org_id;
  IF p_writes IS TRUE AND NOT l.writes_enabled THEN
    UPDATE public.exos_discord_event_syncs SET change_seq = change_seq + 1, next_try_at = now()
     WHERE org_id = p_org_id;
  END IF;
  /* exos: audit discord.settings */
  PERFORM public._exos_audit(p_org_id, 'discord.settings', 'discord_link', p_org_id::text, NULL,
    jsonb_strip_nulls(jsonb_build_object(
      'writes_enabled', CASE WHEN p_writes IS NOT NULL THEN jsonb_build_array(l.writes_enabled, p_writes) END,
      'auto_post', CASE WHEN p_auto_post IS NOT NULL THEN jsonb_build_array(l.auto_post, p_auto_post) END)),
    NULL, NULL, NULL, v_uid, NULL, 'dashboard');
  RETURN jsonb_build_object('writes_enabled', coalesce(p_writes, l.writes_enabled), 'auto_post', coalesce(p_auto_post, l.auto_post));
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_set_options(uuid, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_set_options(uuid, boolean, boolean) TO authenticated, service_role;

-- Owner / manager: disconnect the server. Exos stops managing its scheduled
-- events (they stay on Discord; untick "Show on Discord" first to remove
-- them). The bot leaves when someone removes it in Discord's server settings.
CREATE OR REPLACE FUNCTION public.exos_discord_unlink_guild(p_org_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_guild text;
BEGIN
  IF public._exos_discord_role(p_org_id, v_uid) IS NULL THEN
    RAISE EXCEPTION 'exos_discord_unlink_guild: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT guild_id INTO v_guild FROM public.exos_discord_links WHERE org_id = p_org_id FOR UPDATE;
  IF v_guild IS NULL THEN
    RETURN false;
  END IF;
  UPDATE public.exos_discord_links SET guild_id = NULL, guild_name = NULL, guild_linked_by = NULL, guild_linked_at = NULL,
         guild_broken_at = NULL, guild_broken_reason = NULL
   WHERE org_id = p_org_id;
  UPDATE public.exos_discord_event_syncs SET status = 'removed', lease_id = NULL, lease_until = NULL,
         last_error = 'the Discord server was disconnected'
   WHERE org_id = p_org_id;
  /* exos: audit discord.guild_unlink */
  PERFORM public._exos_audit(p_org_id, 'discord.guild_unlink', 'discord_guild', v_guild, NULL,
    jsonb_build_object('guild_id', jsonb_build_array(v_guild, NULL)), NULL, NULL, NULL, v_uid, NULL, 'dashboard');
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_unlink_guild(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_unlink_guild(uuid) TO authenticated, service_role;

-- The event panel: owner / manager of the event's org (or an admin, read
-- only). An unknown event and another org's event answer the same.
CREATE OR REPLACE FUNCTION public.exos_discord_event_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e      public.exos_events%ROWTYPE;
  v_role text;
  l      public.exos_discord_links%ROWTYPE;
  s      public.exos_discord_event_syncs%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  v_role := public._exos_discord_role(e.org_id, auth.uid());
  IF e.id IS NULL OR (v_role IS NULL AND NOT public.exos_is_admin()) THEN
    RAISE EXCEPTION 'exos_discord_event_status: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO l FROM public.exos_discord_links WHERE org_id = e.org_id;
  SELECT * INTO s FROM public.exos_discord_event_syncs WHERE event_id = p_event_id;
  RETURN jsonb_build_object(
    'can_manage', v_role IS NOT NULL,
    'event_status', e.status,
    'has_webhook', l.webhook_id IS NOT NULL,
    'guild_linked', l.guild_id IS NOT NULL,
    'guild_name', l.guild_name,
    'guild_broken', l.guild_broken_at IS NOT NULL,
    'webhook_broken', l.webhook_broken_at IS NOT NULL,
    'writes_enabled', coalesce(l.writes_enabled, false),
    'show', coalesce(s.show, false),
    'sync', CASE WHEN s.event_id IS NULL THEN NULL ELSE jsonb_build_object(
              'status', s.status, 'on_discord', s.external_id IS NOT NULL AND s.guild_id IS NOT DISTINCT FROM l.guild_id,
              'pending', s.synced_seq < s.change_seq, 'synced_at', s.synced_at, 'last_error', s.last_error) END,
    'posts', coalesce((SELECT jsonb_agg(jsonb_build_object('kind', p.kind, 'status', p.status, 'sent_at', p.sent_at,
                                                           'requested_at', p.requested_at, 'last_error', p.last_error)
                                        ORDER BY p.kind)
                         FROM public.exos_discord_posts p WHERE p.event_id = p_event_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_event_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_event_status(uuid) TO authenticated, service_role;

-- Owner / manager: "Show on Discord" on or off for one event. On needs a
-- linked server and an event that isn't cancelled. 30 changes a minute per
-- user. Off removes the scheduled event on the next pass.
CREATE OR REPLACE FUNCTION public.exos_discord_set_show(p_event_id uuid, p_show boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  e      public.exos_events%ROWTYPE;
  v_was  boolean;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR public._exos_discord_role(e.org_id, v_uid) IS NULL THEN
    RAISE EXCEPTION 'exos_discord_set_show: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_show IS NULL THEN
    RAISE EXCEPTION 'exos_discord_set_show: on or off' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('discord_show:' || v_uid::text, 30) THEN
    RAISE EXCEPTION 'exos_discord_set_show: too many changes, try again in a minute' USING ERRCODE = '54000';
  END IF;
  IF p_show AND NOT EXISTS (SELECT 1 FROM public.exos_discord_links l WHERE l.org_id = e.org_id AND l.guild_id IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_discord_set_show: add the Exos bot to your Discord server first' USING ERRCODE = '22023';
  END IF;
  IF p_show AND e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_discord_set_show: the event was cancelled' USING ERRCODE = '22023';
  END IF;
  SELECT s.show INTO v_was FROM public.exos_discord_event_syncs s WHERE s.event_id = p_event_id FOR UPDATE;
  IF v_was IS NOT DISTINCT FROM p_show THEN
    RETURN jsonb_build_object('show', p_show, 'changed', false);
  END IF;
  IF v_was IS NULL AND NOT p_show THEN
    RETURN jsonb_build_object('show', false, 'changed', false);
  END IF;
  INSERT INTO public.exos_discord_event_syncs AS s (event_id, org_id, show, created_by)
  VALUES (p_event_id, e.org_id, p_show, v_uid)
  ON CONFLICT (event_id) DO UPDATE
     SET show = EXCLUDED.show, change_seq = s.change_seq + 1, next_try_at = now(), attempts = 0,
         status = CASE WHEN EXCLUDED.show THEN 'pending' ELSE s.status END, last_error = NULL;
  /* exos: audit discord.event_show */
  PERFORM public._exos_audit(e.org_id, 'discord.event_show', 'event', p_event_id::text, p_event_id,
    jsonb_build_object('show', jsonb_build_array(coalesce(v_was, false), p_show)), NULL, NULL, NULL, v_uid, NULL, 'dashboard');
  RETURN jsonb_build_object('show', p_show, 'changed', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_set_show(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_set_show(uuid, boolean) TO authenticated, service_role;

-- Owner / manager: queue the event's announcement ('publish') or reminder.
-- Once per event per kind: a post that went out (or is going out) answers
-- already = true and nothing new is queued; one that failed or was only a
-- dry run is queued again. The event must be published and not over; the
-- org needs a webhook. 10 requests a minute and 30 posts an hour per org.
CREATE OR REPLACE FUNCTION public.exos_discord_request_post(p_event_id uuid, p_kind text DEFAULT 'publish')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  e      public.exos_events%ROWTYPE;
  p      public.exos_discord_posts%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR public._exos_discord_role(e.org_id, v_uid) IS NULL THEN
    RAISE EXCEPTION 'exos_discord_request_post: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_kind IS NULL OR p_kind NOT IN ('publish', 'reminder') THEN
    RAISE EXCEPTION 'exos_discord_request_post: publish or reminder' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('discord_post:' || e.org_id::text, 10) THEN
    RAISE EXCEPTION 'exos_discord_request_post: too many requests, try again in a minute' USING ERRCODE = '54000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_discord_links l WHERE l.org_id = e.org_id AND l.webhook_id IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_discord_request_post: add a Discord webhook in Org settings first' USING ERRCODE = '22023';
  END IF;
  IF e.status <> 'published' OR coalesce(e.ends_at, e.starts_at + interval '3 hours', now()) <= now() THEN
    RAISE EXCEPTION 'exos_discord_request_post: only a published event that isn''t over can be posted' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO p FROM public.exos_discord_posts WHERE event_id = p_event_id AND kind = p_kind FOR UPDATE;
  IF p.id IS NOT NULL AND p.status IN ('queued', 'sending', 'sent') THEN
    RETURN jsonb_build_object('post_id', p.id, 'status', p.status, 'already', true);
  END IF;
  IF (SELECT count(*) FROM public.exos_discord_posts x
       WHERE x.org_id = e.org_id AND x.requested_at > now() - interval '1 hour') >= 30 THEN
    RAISE EXCEPTION 'exos_discord_request_post: 30 Discord posts an hour is the limit; try again later' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_discord_posts AS x (org_id, event_id, kind, requested_by)
  VALUES (e.org_id, p_event_id, p_kind, v_uid)
  ON CONFLICT (event_id, kind) DO UPDATE
     SET status = 'queued', requested_by = EXCLUDED.requested_by, requested_at = now(), attempts = 0,
         next_try_at = now(), last_error = NULL, plan = NULL, lease_id = NULL, lease_until = NULL
  RETURNING * INTO p;
  RETURN jsonb_build_object('post_id', p.id, 'status', p.status, 'already', false);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_request_post(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_request_post(uuid, text) TO authenticated, service_role;

-- ===========================================================================
-- 5. Event changes: re-sync a shown event; queue the publish announcement
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_tg_discord_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- A shown event: one pass after edits settle (15 seconds).
  UPDATE public.exos_discord_event_syncs
     SET change_seq = change_seq + 1, next_try_at = now() + interval '15 seconds'
   WHERE event_id = NEW.id;
  -- Published just now, and the org asked for the announcement: queue it once.
  IF NEW.status = 'published' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'published')
     AND EXISTS (SELECT 1 FROM public.exos_discord_links l
                  WHERE l.org_id = NEW.org_id AND l.auto_post AND l.webhook_id IS NOT NULL) THEN
    INSERT INTO public.exos_discord_posts (org_id, event_id, kind, requested_by)
    VALUES (NEW.org_id, NEW.id, 'publish', auth.uid())
    ON CONFLICT (event_id, kind) DO NOTHING;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_discord_event() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_events_discord_ins ON public.exos_events;
CREATE TRIGGER exos_events_discord_ins AFTER INSERT ON public.exos_events
  FOR EACH ROW WHEN (NEW.status = 'published') EXECUTE FUNCTION public.exos_tg_discord_event();
-- Only the columns Discord shows (a sale bumps tickets_sold: no work).
DROP TRIGGER IF EXISTS exos_events_discord_upd ON public.exos_events;
CREATE TRIGGER exos_events_discord_upd AFTER UPDATE ON public.exos_events
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.name IS DISTINCT FROM NEW.name
                     OR OLD.starts_at IS DISTINCT FROM NEW.starts_at OR OLD.ends_at IS DISTINCT FROM NEW.ends_at
                     OR OLD.description IS DISTINCT FROM NEW.description OR OLD.image_url IS DISTINCT FROM NEW.image_url
                     OR OLD.slug IS DISTINCT FROM NEW.slug OR OLD.timezone IS DISTINCT FROM NEW.timezone
                     OR OLD.venue_name IS DISTINCT FROM NEW.venue_name OR OLD.venue_location IS DISTINCT FROM NEW.venue_location
                     OR OLD.location_mode IS DISTINCT FROM NEW.location_mode)
  EXECUTE FUNCTION public.exos_tg_discord_event();

-- ===========================================================================
-- 6. The edge function (exos-discord; service role only)
-- ===========================================================================
-- What a post or a scheduled event shows: the event as the public sees it.
-- A secret location shows only the area (venue_name / address are empty on
-- such an event already); TBA shows nothing.
CREATE OR REPLACE FUNCTION public._exos_discord_event_json(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', e.id, 'slug', e.slug, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
    'timezone', e.timezone, 'description', left(e.description, 2000), 'image_url', e.image_url,
    'location_mode', e.location_mode,
    'venue_name', CASE WHEN e.location_mode IN ('venue_record', 'unlisted_venue') THEN e.venue_name END,
    'venue_location', CASE WHEN e.location_mode <> 'tba' THEN e.venue_location END,
    'city', CASE WHEN e.location_mode IN ('venue_record', 'unlisted_venue') THEN e.venue_address ->> 'city' END,
    'org_name', o.name)
    FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_discord_event_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_discord_event_json(uuid) TO service_role;

-- Posts due, each with a 2-minute lease, the webhook (id + token from
-- Vault) and the event. A post left 'sending' by a crashed pass is not
-- resent (Discord may have it): it becomes an error to retry by hand. An
-- org that sent 30 posts in the last hour waits. An event no longer
-- published (or over), or a webhook Discord refused, gets an error instead.
-- Nothing is handed out while the breaker stops every Discord call.
CREATE OR REPLACE FUNCTION public.exos_discord_post_claim(p_limit int DEFAULT 10, p_post_id uuid DEFAULT NULL)
RETURNS TABLE (post_id uuid, org_id uuid, event_id uuid, kind text, lease_id uuid, payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  r    record;
  v_l  uuid;
BEGIN
  UPDATE public.exos_discord_posts p
     SET status = 'error', lease_id = NULL, lease_until = NULL,
         last_error = 'Exos lost track of this post while sending; check the channel before posting again'
   WHERE p.status = 'sending' AND p.lease_until < now();
  IF public._exos_discord_blocked('webhook') IS NOT NULL THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT p.id, p.org_id, p.event_id, p.kind, e.status AS ev_status,
           coalesce(e.ends_at, e.starts_at + interval '3 hours', now() + interval '1 day') AS ev_end,
           l.webhook_id, l.webhook_secret_id, l.writes_enabled, l.webhook_broken_at
      FROM public.exos_discord_posts p
      JOIN public.exos_events e ON e.id = p.event_id
      LEFT JOIN public.exos_discord_links l ON l.org_id = p.org_id
     WHERE p.status = 'queued' AND p.next_try_at <= now()
       AND (p_post_id IS NULL OR p.id = p_post_id)
     ORDER BY p.next_try_at
     LIMIT greatest(1, least(coalesce(p_limit, 10), 50))
     FOR UPDATE OF p SKIP LOCKED
  LOOP
    IF r.webhook_id IS NULL THEN
      UPDATE public.exos_discord_posts SET status = 'error', last_error = 'add a Discord webhook first' WHERE id = r.id;
      CONTINUE;
    END IF;
    IF r.webhook_broken_at IS NOT NULL THEN
      UPDATE public.exos_discord_posts SET status = 'error', last_error = 'Discord refused the webhook; paste a new one' WHERE id = r.id;
      CONTINUE;
    END IF;
    IF r.ev_status <> 'published' OR r.ev_end <= now() THEN
      UPDATE public.exos_discord_posts SET status = 'error', last_error = 'the event is not published (or is over)' WHERE id = r.id;
      CONTINUE;
    END IF;
    IF (SELECT count(*) FROM public.exos_discord_posts x
         WHERE x.org_id = r.org_id AND x.status = 'sent' AND x.sent_at > now() - interval '1 hour') >= 30 THEN
      UPDATE public.exos_discord_posts SET next_try_at = now() + interval '10 minutes' WHERE id = r.id;
      CONTINUE;
    END IF;
    v_l := gen_random_uuid();
    UPDATE public.exos_discord_posts SET status = 'sending', lease_id = v_l, lease_until = now() + interval '2 minutes',
           attempts = attempts + 1, webhook_id = r.webhook_id
     WHERE id = r.id;
    post_id := r.id; org_id := r.org_id; event_id := r.event_id; kind := r.kind; lease_id := v_l;
    payload := jsonb_build_object(
      'event', public._exos_discord_event_json(r.event_id),
      'webhook', jsonb_build_object('id', r.webhook_id,
                   'token', (SELECT d.decrypted_secret FROM vault.decrypted_secrets d WHERE d.id = r.webhook_secret_id)),
      'writes_enabled', coalesce(r.writes_enabled, false));
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_post_claim(int, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_post_claim(int, uuid) TO service_role;

-- Record a send. p_state: sent (Discord took it; message id), dry_run (the
-- plan only), retry (a 429 or a request that never left: queued again after
-- p_retry_seconds, at most 5 tries), error (including a 5xx or a timeout,
-- which may have posted: never retried by itself). p_webhook_broken: Discord
-- refused the webhook, so the org's webhook (if it is still the one this
-- post used) is skipped until a new one is saved. Refused without the
-- lease. A sent or dry-run post is audited as discord.post with the person
-- who asked for it.
CREATE OR REPLACE FUNCTION public.exos_discord_post_mark(
  p_post_id uuid, p_lease uuid, p_state text, p_message_id text DEFAULT NULL, p_error text DEFAULT NULL,
  p_plan jsonb DEFAULT NULL, p_retry_seconds int DEFAULT NULL, p_webhook_broken boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  p   public.exos_discord_posts%ROWTYPE;
  v_s text := p_state;
BEGIN
  SELECT * INTO p FROM public.exos_discord_posts WHERE id = p_post_id FOR UPDATE;
  IF p.id IS NULL OR p_lease IS NULL OR p.lease_id IS DISTINCT FROM p_lease OR p.status <> 'sending' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  IF v_s IS NULL OR v_s NOT IN ('sent', 'dry_run', 'retry', 'error') THEN
    RAISE EXCEPTION 'exos_discord_post_mark: bad state' USING ERRCODE = '22023';
  END IF;
  IF v_s = 'retry' AND p.attempts >= 5 THEN
    v_s := 'error';
  END IF;
  UPDATE public.exos_discord_posts
     SET status      = CASE v_s WHEN 'retry' THEN 'queued' ELSE v_s END,
         message_id  = CASE WHEN v_s = 'sent' AND p_message_id ~ '^[0-9]{17,20}$' THEN p_message_id ELSE message_id END,
         sent_at     = CASE WHEN v_s = 'sent' THEN now() ELSE sent_at END,
         plan        = CASE WHEN p_plan IS NOT NULL AND length(p_plan::text) <= 8000 THEN p_plan ELSE plan END,
         next_try_at = CASE WHEN v_s = 'retry' THEN now() + make_interval(secs => least(greatest(coalesce(p_retry_seconds, 30), 5), 3600))
                            ELSE next_try_at END,
         last_error  = CASE WHEN v_s IN ('retry', 'error') THEN left(coalesce(nullif(btrim(p_error), ''), 'Discord refused the post'), 300) END,
         lease_id = NULL, lease_until = NULL
   WHERE id = p_post_id;
  IF p_webhook_broken THEN
    UPDATE public.exos_discord_links
       SET webhook_broken_at = now(), webhook_broken_reason = left(coalesce(nullif(btrim(p_error), ''), 'Discord refused the webhook'), 200)
     WHERE org_id = p.org_id AND webhook_id IS NOT NULL AND webhook_id IS NOT DISTINCT FROM p.webhook_id;
  END IF;
  IF v_s IN ('sent', 'dry_run') THEN
    /* exos: audit discord.post */
    PERFORM public._exos_audit(p.org_id, 'discord.post', 'event', p.event_id::text, p.event_id,
      jsonb_build_object('kind', p.kind, 'dry_run', v_s = 'dry_run', 'webhook', '…' || right(coalesce(p.webhook_id, ''), 4)),
      NULL, NULL, NULL, p.requested_by, NULL, 'system');
  END IF;
  RETURN jsonb_build_object('ok', true, 'state', CASE v_s WHEN 'retry' THEN 'queued' ELSE v_s END);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_post_mark(uuid, uuid, text, text, text, jsonb, int, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_post_mark(uuid, uuid, text, text, text, jsonb, int, boolean) TO service_role;

-- Scheduled events due a pass (changed since the last one, or a failed one
-- backing off), each with a 2-minute lease, the org's server and switch and
-- the event. An org gets at most 20 passes a minute (exos_rate_hit, before
-- any call to Discord); the rest wait a minute. Events over for a day are
-- left alone (Discord ends an EXTERNAL event at its end time). A "sync now"
-- for one event (p_event_id) still waits out its backoff (next_try_at). A
-- server Discord refused (guild_broken_at) is skipped until linked again;
-- nothing is handed out while the breaker or a global 429 stops bot calls
-- (p_token_fp: the bot token's fingerprint, so a new token clears a 401).
CREATE OR REPLACE FUNCTION public.exos_discord_sync_claim(p_limit int DEFAULT 10, p_event_id uuid DEFAULT NULL, p_token_fp text DEFAULT NULL)
RETURNS TABLE (event_id uuid, org_id uuid, lease_id uuid, change_seq bigint, payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  r   record;
  v_l uuid;
BEGIN
  IF public._exos_discord_blocked('bot', p_token_fp) IS NOT NULL THEN
    RETURN;
  END IF;
  FOR r IN
    SELECT s.*, l.guild_id AS link_guild, coalesce(l.writes_enabled, false) AS link_writes
      FROM public.exos_discord_event_syncs s
      JOIN public.exos_events e ON e.id = s.event_id
      JOIN public.exos_discord_links l ON l.org_id = s.org_id AND l.guild_id IS NOT NULL AND l.guild_broken_at IS NULL
     WHERE (s.lease_until IS NULL OR s.lease_until < now())
       AND (s.show OR s.status <> 'removed')
       AND coalesce(e.ends_at, e.starts_at + interval '3 hours', now()) > now() - interval '1 day'
       AND (p_event_id IS NULL OR s.event_id = p_event_id)
       AND (s.synced_seq < s.change_seq OR p_event_id IS NOT NULL) AND s.next_try_at <= now()
     ORDER BY s.next_try_at
     LIMIT greatest(1, least(coalesce(p_limit, 10), 50))
     FOR UPDATE OF s SKIP LOCKED
  LOOP
    IF NOT public.exos_rate_hit('discord_sync:' || r.org_id::text, 20) THEN
      UPDATE public.exos_discord_event_syncs SET next_try_at = now() + interval '1 minute' WHERE event_id = r.event_id;
      CONTINUE;
    END IF;
    v_l := gen_random_uuid();
    UPDATE public.exos_discord_event_syncs SET lease_id = v_l, lease_until = now() + interval '2 minutes'
     WHERE event_id = r.event_id;
    event_id := r.event_id; org_id := r.org_id; lease_id := v_l; change_seq := r.change_seq;
    payload := jsonb_build_object(
      'event', public._exos_discord_event_json(r.event_id),
      'sync', jsonb_build_object('show', r.show, 'status', r.status, 'last_hash', r.last_hash,
                                 -- A scheduled event on another server is not ours to touch.
                                 'external_id', CASE WHEN r.guild_id IS NOT DISTINCT FROM r.link_guild THEN r.external_id END),
      'guild_id', r.link_guild,
      'writes_enabled', r.link_writes);
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_sync_claim(int, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_sync_claim(int, uuid, text) TO service_role;

-- Record a pass. p_result: {state: synced | dry_run | error | retry,
-- guild_id, external_id (null once deleted), hash, plan, error, gone,
-- retry_seconds}. Refused without the lease. synced / dry_run: in step up
-- to what the pass read (a dry run waits for the next change or the writes
-- switch). gone: someone deleted it in Discord; "Show on Discord" goes off
-- rather than putting it back. link_broken: the server refused the bot
-- (403 missing access / permissions, unknown guild); the org's link to that
-- server is skipped until it's linked again.
CREATE OR REPLACE FUNCTION public.exos_discord_sync_mark(p_event_id uuid, p_lease uuid, p_change_seq bigint, p_result jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_discord_event_syncs%ROWTYPE;
  v_state text := p_result ->> 'state';
  v_ext   text := nullif(p_result ->> 'external_id', '');
  v_guild text := nullif(p_result ->> 'guild_id', '');
  v_gone  boolean := coalesce((p_result ->> 'gone')::boolean, false);
  v_broke boolean := coalesce((p_result ->> 'link_broken')::boolean, false);
BEGIN
  SELECT * INTO s FROM public.exos_discord_event_syncs WHERE event_id = p_event_id FOR UPDATE;
  IF s.event_id IS NULL OR p_lease IS NULL OR s.lease_id IS DISTINCT FROM p_lease THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  IF v_state IS NULL OR v_state NOT IN ('synced', 'dry_run', 'error', 'retry') THEN
    RAISE EXCEPTION 'exos_discord_sync_mark: bad state' USING ERRCODE = '22023';
  END IF;
  IF v_ext IS NOT NULL AND v_ext !~ '^[0-9]{17,20}$' THEN v_ext := NULL; END IF;
  IF v_guild IS NOT NULL AND v_guild !~ '^[0-9]{17,20}$' THEN v_guild := NULL; END IF;

  UPDATE public.exos_discord_event_syncs
     SET external_id = CASE WHEN v_state = 'synced' OR v_gone THEN v_ext ELSE external_id END,
         guild_id    = CASE WHEN v_state = 'synced' AND v_ext IS NOT NULL THEN v_guild
                            WHEN v_state = 'synced' OR v_gone THEN NULL ELSE guild_id END,
         show        = CASE WHEN v_gone THEN false ELSE show END,
         status      = CASE WHEN v_gone THEN 'removed'
                            WHEN v_state = 'synced' AND v_ext IS NULL AND NOT s.show THEN 'removed'
                            WHEN v_state = 'retry' THEN 'error' ELSE v_state END,
         synced_seq  = CASE WHEN v_state IN ('synced', 'dry_run') OR v_gone THEN greatest(synced_seq, coalesce(p_change_seq, 0)) ELSE synced_seq END,
         last_hash   = CASE WHEN v_state = 'synced' THEN left(p_result ->> 'hash', 128) ELSE last_hash END,
         plan        = CASE WHEN jsonb_typeof(p_result -> 'plan') = 'object' AND length((p_result -> 'plan')::text) <= 8000
                            THEN p_result -> 'plan' ELSE plan END,
         planned_at  = CASE WHEN p_result ? 'plan' THEN now() ELSE planned_at END,
         synced_at   = CASE WHEN v_state = 'synced' THEN now() ELSE synced_at END,
         attempts    = CASE WHEN v_state IN ('error', 'retry') THEN attempts + 1 ELSE 0 END,
         next_try_at = CASE WHEN v_state = 'retry' THEN now() + make_interval(secs => least(greatest(coalesce((p_result ->> 'retry_seconds')::int, 30), 5), 3600))
                            WHEN v_state = 'error' THEN now() + least(make_interval(mins => (2 ^ least(attempts, 6))::int), interval '60 minutes')
                            ELSE next_try_at END,
         last_error  = CASE WHEN v_state IN ('error', 'retry') OR v_gone THEN left(coalesce(nullif(btrim(p_result ->> 'error'), ''), 'Discord sync failed'), 300) END,
         lease_id = NULL, lease_until = NULL
   WHERE event_id = p_event_id;
  IF v_broke AND v_guild IS NOT NULL THEN
    UPDATE public.exos_discord_links
       SET guild_broken_at = now(), guild_broken_reason = left(coalesce(nullif(btrim(p_result ->> 'error'), ''), 'Discord refused the bot'), 200)
     WHERE org_id = s.org_id AND guild_id = v_guild;
  END IF;
  RETURN jsonb_build_object('ok', true, 'state', v_state);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_sync_mark(uuid, uuid, bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_sync_mark(uuid, uuid, bigint, jsonb) TO service_role;

-- "Add Exos bot to your server": the shared OAuth state (owner / manager,
-- 10 starts a user in 10 minutes, 10-minute expiry) for provider 'discord'.
CREATE OR REPLACE FUNCTION public.exos_discord_install_begin(p_org_id uuid, p_user_id uuid, p_state_hash text)
RETURNS timestamptz
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.exos_oauth_state_begin('discord', p_org_id, p_user_id, p_state_hash, 10)
$$;
REVOKE ALL ON FUNCTION public.exos_discord_install_begin(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_install_begin(uuid, uuid, text) TO service_role;

-- Discord states only; the finish token and the starting user, once
-- (_exos_oauth_state_take: refused other_user / token / forbidden / expired).
CREATE OR REPLACE FUNCTION public.exos_discord_install_consume(p_state_hash text, p_user_id uuid, p_finish_hash text)
RETURNS TABLE (org_id uuid, code text, refused text)
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT t.org_id, t.code, t.refused FROM public._exos_oauth_state_take('discord', p_state_hash, p_user_id, p_finish_hash) t
$$;
REVOKE ALL ON FUNCTION public.exos_discord_install_consume(text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_install_consume(text, uuid, text) TO service_role;

-- Link the server Discord's token response named. The user is re-checked
-- (still owner / manager); a server already linked to another org is
-- refused (it can only be unlinked there). A different server than before:
-- every shown event is made again there on the next pass.
CREATE OR REPLACE FUNCTION public.exos_discord_guild_link(p_org_id uuid, p_user_id uuid, p_guild_id text, p_guild_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old  text;
  v_name text := left(nullif(btrim(regexp_replace(coalesce(p_guild_name, ''), '[[:cntrl:]]', '', 'g')), ''), 100);
BEGIN
  IF public._exos_discord_role(p_org_id, p_user_id) IS NULL THEN
    RAISE EXCEPTION 'exos_discord_guild_link: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_guild_id IS NULL OR p_guild_id !~ '^[0-9]{17,20}$' THEN
    RAISE EXCEPTION 'exos_discord_guild_link: bad server id' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_discord_links l WHERE l.guild_id = p_guild_id AND l.org_id <> p_org_id) THEN
    RAISE EXCEPTION 'exos_discord_guild_link: that Discord server is linked to another Exos organization' USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.exos_discord_links (org_id) VALUES (p_org_id) ON CONFLICT (org_id) DO NOTHING;
  SELECT guild_id INTO v_old FROM public.exos_discord_links WHERE org_id = p_org_id FOR UPDATE;
  UPDATE public.exos_discord_links
     SET guild_id = p_guild_id, guild_name = v_name, guild_linked_by = p_user_id, guild_linked_at = now(),
         guild_broken_at = NULL, guild_broken_reason = NULL
   WHERE org_id = p_org_id;
  UPDATE public.exos_discord_event_syncs
     SET status = CASE WHEN show THEN 'pending' ELSE status END, change_seq = change_seq + 1, next_try_at = now(),
         attempts = 0, last_error = NULL
   WHERE org_id = p_org_id AND show;
  /* exos: audit discord.guild_link */
  PERFORM public._exos_audit(p_org_id, 'discord.guild_link', 'discord_guild', p_guild_id, NULL,
    jsonb_build_object('guild_id', jsonb_build_array(v_old, p_guild_id)), NULL, NULL, NULL, p_user_id, NULL, 'dashboard');
  RETURN jsonb_build_object('linked', true, 'guild_id', p_guild_id, 'guild_name', v_name, 'replaced', v_old IS NOT NULL AND v_old <> p_guild_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_guild_link(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_guild_link(uuid, uuid, text, text) TO service_role;

-- ===========================================================================
-- 7. Schedule: every 2 minutes, created INACTIVE (prod keeps Exos crons off).
--    Turn on once EXOS_DISCORD_ENABLED=on:
--      SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'exos-discord-2min'), active := true);
--    A re-run leaves the job alone.
-- ===========================================================================
DO $$
DECLARE v_job bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     OR to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NULL THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT jobid FROM cron.job WHERE jobname = $1' INTO v_job USING 'exos-discord-2min';
  IF v_job IS NULL THEN
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job
      USING 'exos-discord-2min', '*/2 * * * *',
            $cron$SELECT public._cron_invoke_edge_fn(coalesce(nullif(current_setting('app.exos_functions_url', true), ''), 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-discord/cron', '{}'::jsonb);$cron$;
    EXECUTE 'SELECT cron.alter_job(job_id := $1, active := false)' USING v_job;
  END IF;
END $$;

-- ROLLBACK (manual): unschedule exos-discord-2min; drop the triggers
-- exos_events_discord_ins / _upd and exos_tg_discord_event; drop the
-- exos_discord_* functions and tables; delete vault.secrets named
-- 'exos_discord_webhook:%'; the 'discord' provider in exos_oauth_states can stay.
