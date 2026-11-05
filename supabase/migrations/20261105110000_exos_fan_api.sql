-- ============================================================================
-- Fan API: the signed-in user's own tickets, orders, transfers, memberships,
-- passes, refund requests, wallet passes and profile over exos-api /v1/me/…,
-- for personal access tokens and OAuth tokens; account tokens (a user, no
-- organization) so a fan who belongs to no organization can have one; and
-- the organization writes the Opendate gap list still pointed at the
-- dashboard (series, fee rules, API keys, seat reconciliation, donations,
-- membership scans and gifts, gift card issue, imported attendees); and
-- public discovery (events, venues, search, series) with no credential.
-- Opendate parity: fan_app, ticket_transfers, public_refund_requests,
-- membership_scans, memberships, gift_card_sales, giving_campaigns and the
-- admin_* entries of docs/opendate-coverage.json. docs/api/me.json.
-- ============================================================================
-- Touches:  R: FUNCTION exos_api_scope_names (+ me:read, me:write before
--              org:admin: 20 scopes), exos_role_token_scopes (+ me:read,
--              me:write for every role: they are about the user, not the org)
--           N: TRIGGER exos_api_keys_no_user_scopes (an org API key never
--              carries me:*: it has no user)
--           C: TABLE exos_account_tokens (RLS: the user reads their own; no
--              key_hash column grant). An account token is a user's
--              credential, not organization data, so it has no org_id.
--           N: exos_create_account_token, exos_revoke_account_token
--              (authenticated, checked against auth.uid());
--              exos_api_account_token_auth, _exos_account_token_revoke_self
--              (service role: exos-api)
--           N: exos_api_me (service role: exos-api), _exos_api_me_cred,
--              _exos_api_me_action_scope, _exos_api_me_ticket_json,
--              _exos_api_me_order_json (internal)
--           N: exos_api_gap_write (service role: exos-api),
--              _exos_api_gap_action_scope, _exos_api_gap_action_roles,
--              _exos_api_gap_membership_json (internal)
--           R: FUNCTION _exos_tg_org_role_scopes (20261104180000's body; a
--              role's org-configured set drops me:* instead of failing)
--           N: _exos_api_public (service role: exos-api), exos_api_public
--              (anon, authenticated: the H3 allowlist), _exos_api_public_org_json,
--              _exos_api_public_tiers_json, _exos_api_public_event_full,
--              _exos_api_public_like (internal)
--           Calls (unchanged): exos_api_token_auth, _exos_scopes_for_role,
--              _exos_mint_secret, _exos_sha256, _exos_token_audit,
--              exos_my_ticket_bundles, exos_my_memberships, exos_my_passes,
--              exos_my_refund_asks_all, exos_ask_refund,
--              exos_withdraw_refund_ask, exos_bulk_create_transfers,
--              exos_cancel_transfer, exos_claim_transfer(uuid, text),
--              exos_wallet_issue_pass, exos_wallet_season_pass,
--              exos_set_marketing_emails, _exos_door_code_mac,
--              exos_membership_scan, exos_membership_gift,
--              exos_membership_cancel_gift, exos_gift_card_issue,
--              exos_record_offline_donation, exos_series_create /
--              update / cancel / delete / attach_event / detach_event /
--              generate / cancel_date, exos_release_orphan_seats,
--              exos_create_api_key, exos_revoke_api_key, exos_import_guests,
--              _exos_api_has_scope, _exos_api_uuid, _exos_api_key_scopes,
--              _exos_api_key_actor, exos_create_personal_token,
--              exos_revoke_personal_token, _exos_public_event_json,
--              exos_tier_exclusive_tax_percent, exos_public_series,
--              exos_public_org_series, exos_rate_hit, _exos_request_ip_bucket
-- Pre-reqs: 20261104180000 (per-role scopes, _exos_api_key_actor),
--           20261101000000 (scope union), 20261031130500 (developer
--           platform), 20261102100000 (commerce writes, season-pass wallet),
--           20261019100000 (door day keys), 20261030150000 (series),
--           20261030140000 (seating), 20261027100000 (fee rules)
--
-- Every /v1/me action runs as the token's own user: exos_api_me re-resolves
-- the token from its hash (so only a personal, account or OAuth token can
-- act as a user; an org API key has no user and is refused), checks the
-- me:read / me:write scope, sets the request's claims to that user and calls
-- the same signed-in RPC the app calls. Every existing rule holds as is:
-- ownership, transfer locks (a ticket in a pending transfer can't move or
-- get a wallet pass), claim keys, refund windows, rate limits. A barcode is
-- the current 30-second rotating code (T-…, the app's own format), signed
-- with the day key; the barcode secret never leaves the database.
--
-- Org writes (section 5) need an org API key whose creator holds the
-- action's dashboard role now (_exos_api_key_actor) and the key's scopes as
-- narrowed now (_exos_api_key_scopes, mig 20261104180000). Public discovery
-- (section 7) reads only what the storefront shows anyone, 60 calls a minute
-- per network.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Scopes: me:read and me:write.
--    Same order as SCOPES in supabase/functions/_shared/api/scopes.ts
--    (src/lib/apiScopes.test.ts reads the latest definition); org:admin
--    stays last.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_api_scope_names()
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY[
    'events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write', 'tickets:read',
    'tickets:write', 'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
    'commerce:read', 'commerce:write', 'webhooks:read', 'webhooks:write', 'me:read', 'me:write', 'org:admin'
  ]::text[]
$$;
REVOKE ALL ON FUNCTION public.exos_api_scope_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_api_scope_names() TO authenticated, service_role;

-- me:* is about the token's own user, so every role may grant it. Must equal
-- ROLE_SCOPES in supabase/functions/_shared/api/credentials.ts
-- (src/lib/credentials.test.ts reads the latest definition).
CREATE OR REPLACE FUNCTION public.exos_role_token_scopes(p_role text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE p_role
    WHEN 'owner' THEN ARRAY['events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write',
                            'tickets:read', 'tickets:write', 'checkin:write', 'booking:read', 'booking:write',
                            'finance:read', 'finance:write', 'commerce:read', 'commerce:write', 'webhooks:read',
                            'webhooks:write', 'me:read', 'me:write', 'org:admin']
    WHEN 'manager' THEN ARRAY['events:read', 'events:write', 'orders:read', 'tickets:read', 'tickets:write',
                              'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
                              'commerce:read', 'commerce:write', 'me:read', 'me:write']
    WHEN 'finance' THEN ARRAY['events:read', 'orders:read', 'tickets:read', 'booking:read', 'finance:read',
                              'finance:write', 'commerce:read', 'me:read', 'me:write']
    WHEN 'content' THEN ARRAY['events:read', 'events:write', 'booking:read', 'me:read', 'me:write']
    WHEN 'scanner' THEN ARRAY['events:read', 'tickets:read', 'checkin:write', 'me:read', 'me:write']
    ELSE ARRAY[]::text[]
  END
$$;
REVOKE ALL ON FUNCTION public.exos_role_token_scopes(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_role_token_scopes(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. An org API key has no user: it never carries me:*.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_tg_api_key_no_user_scopes()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.scopes && ARRAY['me:read', 'me:write']::text[] THEN
    RAISE EXCEPTION 'exos_api_scopes: me:read and me:write belong to user tokens, not organization keys'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_api_key_no_user_scopes() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_api_keys_no_user_scopes ON public.exos_api_keys;
CREATE TRIGGER exos_api_keys_no_user_scopes BEFORE INSERT OR UPDATE OF scopes ON public.exos_api_keys
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_api_key_no_user_scopes();

-- ---------------------------------------------------------------------------
-- 3. Account tokens: exos_pat_… of a user with no organization, me:* only.
--    Same format and hashing as personal access tokens (prefix + 43
--    base64url characters, SHA-256 at rest, shown once).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_account_tokens (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  name           text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  key_prefix     text NOT NULL,
  key_hash       text NOT NULL UNIQUE CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  scopes         text[] NOT NULL CHECK (cardinality(scopes) >= 1 AND scopes <@ ARRAY['me:read', 'me:write']::text[]),
  expires_at     timestamptz,
  last_used_at   timestamptz,
  revoked_at     timestamptz,
  revoked_reason text CHECK (revoked_reason IS NULL OR revoked_reason IN ('user', 'api')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_account_tokens_user_idx ON public.exos_account_tokens (user_id);
DROP TRIGGER IF EXISTS exos_account_tokens_touch ON public.exos_account_tokens;
CREATE TRIGGER exos_account_tokens_touch BEFORE UPDATE ON public.exos_account_tokens
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_account_tokens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_account_tokens_own ON public.exos_account_tokens;
CREATE POLICY exos_account_tokens_own ON public.exos_account_tokens FOR SELECT TO authenticated
  USING (user_id = auth.uid());
REVOKE ALL ON public.exos_account_tokens FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, user_id, name, key_prefix, scopes, expires_at, last_used_at, revoked_at, revoked_reason,
              created_at, updated_at) ON public.exos_account_tokens TO authenticated;
GRANT ALL ON public.exos_account_tokens TO service_role;
COMMENT ON TABLE public.exos_account_tokens IS
  'Account tokens (exos_pat_…, hash only): a user with no organization, me:read / me:write only (exos-api /v1/me). mig 20261105110000.';

CREATE OR REPLACE FUNCTION public.exos_create_account_token(
  p_name text, p_scopes text[], p_expires_days integer DEFAULT 90)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_scopes text[];
  v_tok    text;
  v_id     uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_uid AND email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'confirm your email address before creating a token' USING ERRCODE = '42501';
  END IF;
  IF p_expires_days IS NOT NULL AND p_expires_days NOT IN (30, 90, 365) THEN
    RAISE EXCEPTION 'expires_days must be 30, 90, 365 or none' USING ERRCODE = '22023';
  END IF;
  IF p_scopes IS NULL OR cardinality(p_scopes) = 0 OR cardinality(p_scopes) > 4
     OR NOT (p_scopes <@ ARRAY['me:read', 'me:write']::text[]) THEN
    RAISE EXCEPTION 'invalid_scope: an account token takes me:read and / or me:write' USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(s ORDER BY s) INTO v_scopes FROM (SELECT DISTINCT unnest(p_scopes) s) x;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_acct_tok:' || v_uid::text, 0));
  IF (SELECT count(*) FROM public.exos_account_tokens
       WHERE user_id = v_uid AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())) >= 10 THEN
    RAISE EXCEPTION 'at most 10 active account tokens; revoke one first' USING ERRCODE = '54000';
  END IF;
  v_tok := public._exos_mint_secret('exos_pat_');
  INSERT INTO public.exos_account_tokens (user_id, name, key_prefix, key_hash, scopes, expires_at)
  VALUES (v_uid, left(btrim(coalesce(nullif(btrim(p_name), ''), 'Token')), 80), left(v_tok, 13),
          public._exos_sha256(v_tok), v_scopes,
          CASE WHEN p_expires_days IS NULL THEN NULL ELSE now() + make_interval(days => p_expires_days) END)
  RETURNING id INTO v_id;
  PERFORM public._exos_token_audit('pat.created', v_uid, v_uid, NULL, NULL, v_id::text,
                                   jsonb_build_object('account', true, 'scopes', to_jsonb(v_scopes)));
  RETURN jsonb_build_object('id', v_id, 'token', v_tok, 'key_prefix', left(v_tok, 13), 'scopes', to_jsonb(v_scopes),
    'expires_at', (SELECT expires_at FROM public.exos_account_tokens WHERE id = v_id));
END $$;
REVOKE ALL ON FUNCTION public.exos_create_account_token(text, text[], integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_create_account_token(text, text[], integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_revoke_account_token(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); v_id uuid;
BEGIN
  UPDATE public.exos_account_tokens SET revoked_at = now(), revoked_reason = 'user'
   WHERE id = p_id AND user_id = v_uid AND revoked_at IS NULL
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN false; END IF;
  PERFORM public._exos_token_audit('pat.revoked', v_uid, v_uid, NULL, NULL, p_id::text, '{"account":true}'::jsonb);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_revoke_account_token(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_revoke_account_token(uuid) TO authenticated;

-- exos-api: an exos_pat_… that is not an org-pinned personal token.
CREATE OR REPLACE FUNCTION public.exos_api_account_token_auth(p_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t public.exos_account_tokens%ROWTYPE;
BEGIN
  IF p_hash IS NULL OR p_hash !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  SELECT * INTO t FROM public.exos_account_tokens
   WHERE key_hash = p_hash AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now());
  IF t.id IS NULL THEN RETURN NULL; END IF;
  IF t.last_used_at IS NULL OR t.last_used_at < now() - interval '1 minute' THEN
    UPDATE public.exos_account_tokens SET last_used_at = now() WHERE id = t.id;
  END IF;
  RETURN jsonb_build_object('kind', 'pat', 'account', true, 'credential_id', t.id, 'name', t.name,
    'key_prefix', t.key_prefix, 'user_id', t.user_id, 'org_id', NULL, 'role', NULL,
    'scopes', to_jsonb(t.scopes), 'token_scopes', to_jsonb(t.scopes));
END $$;
REVOKE ALL ON FUNCTION public.exos_api_account_token_auth(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_account_token_auth(text) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_account_token_revoke_self(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_user uuid;
BEGIN
  UPDATE public.exos_account_tokens SET revoked_at = now(), revoked_reason = 'api'
   WHERE id = p_id AND revoked_at IS NULL RETURNING user_id INTO v_user;
  IF v_user IS NULL THEN RETURN false; END IF;
  PERFORM public._exos_token_audit('pat.revoked', v_user, v_user, NULL, NULL, p_id::text,
                                   '{"account":true,"via":"api"}'::jsonb);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_account_token_revoke_self(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_account_token_revoke_self(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. /v1/me: the token's own user.
-- ---------------------------------------------------------------------------
-- The user and live scopes behind a user token, from its hash. Only a
-- personal access token, an account token or an OAuth access token has a
-- user; anything else (an org API key's hash, a revoked or expired token, a
-- member who left) is refused.
CREATE OR REPLACE FUNCTION public._exos_api_me_cred(p_hash text, p_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('pat', 'oauth') THEN
    RAISE EXCEPTION 'exos_api_me: this route needs a personal access token, an account token or an OAuth token'
      USING ERRCODE = '42501';
  END IF;
  v := public.exos_api_token_auth(p_hash, p_kind);
  IF v IS NULL AND p_kind = 'pat' THEN v := public.exos_api_account_token_auth(p_hash); END IF;
  IF v IS NULL OR v ? 'error' OR v->>'user_id' IS NULL THEN
    RAISE EXCEPTION 'exos_api_me: invalid or revoked token' USING ERRCODE = '42501';
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_me_cred(text, text) FROM PUBLIC, anon, authenticated;

-- The scope each action needs (mirrors ME_ACTIONS in _shared/api/me.ts).
CREATE OR REPLACE FUNCTION public._exos_api_me_action_scope(p_action text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN p_action IN ('profile.get', 'tickets.list', 'ticket.get', 'bundles.list', 'orders.list', 'order.get',
                      'order.transferable', 'transfers.list', 'memberships.list', 'membership.get', 'passes.list',
                      'pass.get', 'refund_asks.list', 'order.refund_asks', 'wallet.ticket', 'wallet.season_pass',
                      'tokens.list')
      THEN 'me:read'
    WHEN p_action IN ('profile.update', 'marketing.set', 'transfers.create', 'order.transfer', 'transfer.cancel',
                      'transfer.claim', 'refund.ask', 'order.refund_ask', 'refund.withdraw', 'token.create',
                      'token.revoke')
      THEN 'me:write'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_api_me_action_scope(text) FROM PUBLIC, anon, authenticated;

-- A ticket as its holder sees it: never the barcode secret, never the buyer's
-- email (after a transfer that is someone else's). With p_code, the current
-- rotating barcode (T-{ticket}:{owner}:{bucket}:{mac}, 30-second buckets,
-- signed with the day key as the app does): only for an active ticket the
-- user holds and that is not in a pending transfer.
CREATE OR REPLACE FUNCTION public._exos_api_me_ticket_json(p_ticket uuid, p_uid uuid, p_code boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  t       jsonb;
  v_sec   text;
  v_owner uuid;
  v_bkt   bigint;
  v_out   jsonb;
  v_why   text;
BEGIN
  SELECT to_jsonb(tk), tk.barcode_secret, tk.owner_id INTO t, v_sec, v_owner
    FROM public.exos_tickets tk WHERE tk.id = p_ticket AND tk.owner_id = p_uid;
  IF t IS NULL THEN RETURN NULL; END IF;
  SELECT jsonb_build_object(
      'id', t->'id', 'event_id', t->'event_id', 'org_id', t->'org_id', 'tier_id', t->'tier_id',
      'tier_name', t->'tier_name', 'status', t->'status', 'attendee_name', t->'attendee_name',
      'price_paid', t->'price_paid', 'order_id', t->'order_ref',
      'seat', CASE WHEN t->>'seat_label' IS NULL THEN NULL ELSE jsonb_build_object('label', t->'seat_label',
               'section', t->'seat_section', 'row', t->'seat_row', 'number', t->'seat_number') END,
      'checked_in_at', t->'check_in_at', 'in_transfer', t->>'pending_transfer_id' IS NOT NULL,
      'pending_transfer_id', t->'pending_transfer_id', 'created_at', t->'created_at',
      'event', jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'status', e.status,
                                  'starts_at', e.starts_at, 'doors_at', e.doors_at, 'timezone', e.timezone,
                                  'venue_name', e.venue_name, 'venue_location', e.venue_location),
      'org', jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug))
    INTO v_out
    FROM public.exos_events e LEFT JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE e.id = (t->>'event_id')::uuid;
  IF v_out IS NULL THEN RETURN NULL; END IF;
  IF p_code THEN
    v_why := CASE WHEN v_out #>> '{event,status}' = 'cancelled' THEN 'event_cancelled'
                  WHEN t->>'status' <> 'active' THEN 'not_active'
                  WHEN t->>'pending_transfer_id' IS NOT NULL THEN 'in_transfer'
                  WHEN v_sec IS NULL OR v_sec = '' THEN 'no_barcode' END;
    IF v_why IS NULL THEN
      v_bkt := floor(extract(epoch FROM clock_timestamp()) / 30)::bigint;
      v_out := v_out || jsonb_build_object('barcode', jsonb_build_object(
        'format', 'qr',
        'value', 'T-' || p_ticket || ':' || v_owner || ':' || v_bkt || ':'
                 || public._exos_door_code_mac(p_ticket, v_owner, v_bkt, v_sec),
        'rotates_every_seconds', 30,
        'valid_until', to_timestamp((v_bkt + 1) * 30)));
    ELSE
      v_out := v_out || jsonb_build_object('barcode', NULL, 'barcode_unavailable', v_why);
    END IF;
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_me_ticket_json(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;

-- An order the user paid for, with the tickets of it they still hold.
CREATE OR REPLACE FUNCTION public._exos_api_me_order_json(p_session text, p_uid uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o jsonb; v_held jsonb; v_n int;
BEGIN
  SELECT to_jsonb(cs) INTO o FROM public.exos_checkout_sessions cs
   WHERE cs.session_id = p_session AND cs.buyer_uid = p_uid;
  IF o IS NULL THEN RETURN NULL; END IF;
  SELECT coalesce(jsonb_agg(public._exos_api_me_ticket_json(tk.id, p_uid, false) ORDER BY tk.created_at, tk.id), '[]'),
         (SELECT count(*) FROM public.exos_tickets x WHERE x.order_ref = p_session)
    INTO v_held, v_n
    FROM public.exos_tickets tk WHERE tk.order_ref = p_session AND tk.owner_id = p_uid;
  RETURN jsonb_build_object(
    'id', o->'session_id', 'event_id', o->'event_id', 'status', o->'status', 'quantity', o->'quantity',
    'amount_cents', o->'amount_cents', 'tax_cents', o->'tax_cents', 'currency', o->'currency',
    'created_at', o->'created_at', 'fulfilled_at', o->'fulfilled_at',
    'event', (SELECT jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'starts_at', e.starts_at,
                                        'timezone', e.timezone, 'venue_name', e.venue_name)
                FROM public.exos_events e WHERE e.id = (o->>'event_id')::uuid),
    'tickets_count', v_n, 'tickets_held', v_held);
END $$;
REVOKE ALL ON FUNCTION public._exos_api_me_order_json(text, uuid) FROM PUBLIC, anon, authenticated;

-- One /v1/me request. p_hash / p_kind: the bearer token's SHA-256 and kind
-- (exos-api passes them; this re-resolves them). p_args.limit / offset page
-- the lists that are paged. Returns jsonb; paged lists { rows, total }.
CREATE OR REPLACE FUNCTION public.exos_api_me(
  p_hash text, p_kind text, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a        jsonb := coalesce(p_args, '{}'::jsonb);
  v_cred   jsonb;
  v_uid    uuid;
  v_scopes text[];
  v_need   text;
  v_email  text;
  v_was    jsonb;
  v_out    jsonb;
  v_lim    int := least(greatest(coalesce((a->>'limit')::int, 50), 1), 200);
  v_off    int := least(greatest(coalesce((a->>'offset')::int, 0), 0), 2000000);
  v_id     uuid;
  v_ids    uuid[];
  v_items  jsonb;
  v_name   text;
  v_req    text[];
  v_exp    timestamptz;
  v_days   int;
BEGIN
  v_need := public._exos_api_me_action_scope(p_action);
  IF v_need IS NULL THEN RAISE EXCEPTION 'exos_api_me: unknown action' USING ERRCODE = '22023'; END IF;
  v_cred := public._exos_api_me_cred(p_hash, p_kind);
  v_uid := (v_cred->>'user_id')::uuid;
  v_scopes := ARRAY(SELECT jsonb_array_elements_text(coalesce(v_cred->'scopes', '[]'::jsonb)));
  IF NOT (v_need = ANY (v_scopes) OR (v_need = 'me:read' AND 'me:write' = ANY (v_scopes))) THEN
    RAISE EXCEPTION 'exos_api_me: the token lacks the % scope', v_need USING ERRCODE = '42501';
  END IF;

  -- Run as the token's user (the request's claims, put back at the end).
  v_was := jsonb_build_object(
    'claims', current_setting('request.jwt.claims', true), 'sub', current_setting('request.jwt.claim.sub', true),
    'role', current_setting('request.jwt.claim.role', true), 'email', current_setting('request.jwt.claim.email', true));
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_uid;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_uid, 'role', 'authenticated',
    'email', coalesce(v_email, ''), 'exos_token', v_cred->>'credential_id')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_email, ''), true);

  CASE p_action
  -- Profile ---------------------------------------------------------------------
  WHEN 'profile.get' THEN
    v_out := jsonb_build_object('id', v_uid, 'email', v_email,
      'email_confirmed', EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL),
      'display_name', NULL, 'photo_url', NULL,
      'marketing_emails', NOT coalesce((SELECT mp.marketing_opt_out FROM public.exos_mail_prefs mp WHERE mp.user_id = v_uid), false));
    IF to_regclass('public.exos_profiles') IS NOT NULL THEN
      EXECUTE 'SELECT jsonb_build_object(''display_name'', p.display_name, ''photo_url'', p.photo_url)
                 FROM public.exos_profiles p WHERE p.id = $1' INTO v_items USING v_uid;
      v_out := v_out || coalesce(v_items, '{}'::jsonb);
    END IF;

  WHEN 'profile.update' THEN
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(a) k WHERE k <> 'display_name') THEN
      RAISE EXCEPTION 'exos_api_me: only display_name can be changed here' USING ERRCODE = '22023';
    END IF;
    IF a ? 'display_name' THEN
      v_name := nullif(btrim(regexp_replace(coalesce(a->>'display_name', ''), '\s+', ' ', 'g')), '');
      IF v_name IS NOT NULL AND char_length(v_name) > 80 THEN
        RAISE EXCEPTION 'exos_api_me: display_name is at most 80 characters' USING ERRCODE = '22023';
      END IF;
      IF to_regclass('public.exos_profiles') IS NULL THEN
        RAISE EXCEPTION 'exos_api_me: profiles are not available' USING ERRCODE = '55000';
      END IF;
      EXECUTE 'INSERT INTO public.exos_profiles (id, display_name) VALUES ($1, $2)
               ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name' USING v_uid, v_name;
    END IF;
    v_out := public.exos_api_me(p_hash, p_kind, 'profile.get', NULL, '{}'::jsonb);

  WHEN 'marketing.set' THEN
    IF jsonb_typeof(a->'marketing_emails') IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'exos_api_me: marketing_emails must be true or false' USING ERRCODE = '22023';
    END IF;
    v_out := jsonb_build_object('marketing_emails', public.exos_set_marketing_emails((a->>'marketing_emails')::boolean));

  -- Tickets -----------------------------------------------------------------------
  WHEN 'tickets.list' THEN
    IF a ? 'event_id' THEN v_id := public._exos_api_uuid(a->>'event_id', 'event'); END IF;
    IF a ? 'status' AND coalesce(a->>'status', '') NOT IN ('active', 'used', 'voided', 'refunded', 'transferred') THEN
      RAISE EXCEPTION 'exos_api_me: status must be active, used, voided, refunded or transferred' USING ERRCODE = '22023';
    END IF;
    SELECT jsonb_build_object(
             'rows', coalesce((SELECT jsonb_agg(public._exos_api_me_ticket_json(x.id, v_uid, false) ORDER BY x.ord)
                                 FROM (SELECT tk.id, row_number() OVER (ORDER BY e.starts_at NULLS LAST, tk.created_at, tk.id) ord
                                         FROM public.exos_tickets tk JOIN public.exos_events e ON e.id = tk.event_id
                                        WHERE tk.owner_id = v_uid
                                          AND (v_id IS NULL OR tk.event_id = v_id)
                                          AND (NOT a ? 'status' OR tk.status = a->>'status')
                                        ORDER BY e.starts_at NULLS LAST, tk.created_at, tk.id
                                        LIMIT v_lim OFFSET v_off) x), '[]'::jsonb),
             'total', (SELECT count(*) FROM public.exos_tickets tk
                        WHERE tk.owner_id = v_uid AND (v_id IS NULL OR tk.event_id = v_id)
                          AND (NOT a ? 'status' OR tk.status = a->>'status')))
      INTO v_out;

  WHEN 'ticket.get' THEN
    v_out := public._exos_api_me_ticket_json(public._exos_api_uuid(p_target, 'ticket'), v_uid, true);
    IF v_out IS NULL THEN RAISE EXCEPTION 'exos_api_me: ticket not found' USING ERRCODE = 'P0002'; END IF;

  WHEN 'bundles.list' THEN
    IF p_target IS NOT NULL THEN v_id := public._exos_api_uuid(p_target, 'event'); END IF;
    v_out := public.exos_my_ticket_bundles(v_id);
    IF p_target IS NOT NULL THEN
      IF jsonb_array_length(v_out) = 0 THEN RAISE EXCEPTION 'exos_api_me: no tickets for that event' USING ERRCODE = 'P0002'; END IF;
      v_out := v_out->0;
    END IF;

  -- Orders --------------------------------------------------------------------------
  WHEN 'orders.list' THEN
    SELECT jsonb_build_object(
             'rows', coalesce((SELECT jsonb_agg(public._exos_api_me_order_json(x.session_id, v_uid) ORDER BY x.created_at DESC, x.session_id)
                                 FROM (SELECT cs.session_id, cs.created_at FROM public.exos_checkout_sessions cs
                                        WHERE cs.buyer_uid = v_uid
                                        ORDER BY cs.created_at DESC, cs.session_id LIMIT v_lim OFFSET v_off) x), '[]'::jsonb),
             'total', (SELECT count(*) FROM public.exos_checkout_sessions cs WHERE cs.buyer_uid = v_uid))
      INTO v_out;

  WHEN 'order.get' THEN
    v_out := public._exos_api_me_order_json(p_target, v_uid);
    IF v_out IS NULL THEN RAISE EXCEPTION 'exos_api_me: order not found' USING ERRCODE = 'P0002'; END IF;

  WHEN 'order.transferable' THEN
    IF NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs WHERE cs.session_id = p_target AND cs.buyer_uid = v_uid) THEN
      RAISE EXCEPTION 'exos_api_me: order not found' USING ERRCODE = 'P0002';
    END IF;
    SELECT jsonb_build_object('order_id', p_target, 'tickets',
             coalesce(jsonb_agg(public._exos_api_me_ticket_json(tk.id, v_uid, false) ORDER BY tk.created_at, tk.id), '[]'::jsonb))
      INTO v_out
      FROM public.exos_tickets tk
     WHERE tk.order_ref = p_target AND tk.owner_id = v_uid AND tk.status = 'active' AND tk.pending_transfer_id IS NULL;

  WHEN 'order.transfer' THEN
    IF NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs WHERE cs.session_id = p_target AND cs.buyer_uid = v_uid) THEN
      RAISE EXCEPTION 'exos_api_me: order not found' USING ERRCODE = 'P0002';
    END IF;
    IF a ? 'ticket_ids' THEN
      IF jsonb_typeof(a->'ticket_ids') <> 'array' OR jsonb_array_length(a->'ticket_ids') NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'exos_api_me: ticket_ids must be a list of 1 to 50 ids' USING ERRCODE = '22023';
      END IF;
      v_ids := ARRAY(SELECT public._exos_api_uuid(x, 'ticket') FROM jsonb_array_elements_text(a->'ticket_ids') x);
      IF EXISTS (SELECT 1 FROM unnest(v_ids) i WHERE NOT EXISTS (
           SELECT 1 FROM public.exos_tickets tk WHERE tk.id = i AND tk.order_ref = p_target)) THEN
        RAISE EXCEPTION 'exos_api_me: a ticket is not part of this order' USING ERRCODE = '22023';
      END IF;
    ELSE
      v_ids := ARRAY(SELECT tk.id FROM public.exos_tickets tk
                      WHERE tk.order_ref = p_target AND tk.owner_id = v_uid AND tk.status = 'active'
                        AND tk.pending_transfer_id IS NULL ORDER BY tk.created_at, tk.id LIMIT 50);
      IF cardinality(v_ids) = 0 THEN
        RAISE EXCEPTION 'exos_api_me: this order has no tickets you can transfer' USING ERRCODE = '55000';
      END IF;
    END IF;
    SELECT jsonb_agg(jsonb_build_object('ticket_id', i, 'email', a->>'email', 'name', a->>'name'))
      INTO v_items FROM unnest(v_ids) i;
    v_out := jsonb_build_object('transfers', public.exos_bulk_create_transfers(v_items));

  -- Transfers -------------------------------------------------------------------------
  WHEN 'transfers.list' THEN
    SELECT coalesce(jsonb_agg(x.j ORDER BY x.created_at DESC, x.id), '[]'::jsonb) INTO v_out
      FROM (SELECT tr.id, tr.created_at, jsonb_build_object(
                     'id', tr.id, 'direction', 'sent', 'ticket_id', tr.ticket_id, 'status', tr.status,
                     'event_id', to_jsonb(tr)->'event_id', 'event_title', to_jsonb(tr)->'event_title',
                     'tier_name', to_jsonb(tr)->'tier_name', 'to_email', tr.receiver_email,
                     'to_name', to_jsonb(tr)->'receiver_name', 'created_at', tr.created_at) AS j
              FROM public.exos_transfers tr WHERE tr.sender_id = v_uid
            UNION ALL
            SELECT tr.id, tr.created_at, jsonb_build_object(
                     'id', tr.id, 'direction', 'received', 'ticket_id', tr.ticket_id, 'status', tr.status,
                     'event_id', to_jsonb(tr)->'event_id', 'event_title', to_jsonb(tr)->'event_title',
                     'tier_name', to_jsonb(tr)->'tier_name', 'created_at', tr.created_at)
              FROM public.exos_transfers tr
             WHERE tr.status = 'pending' AND tr.sender_id IS DISTINCT FROM v_uid
               AND lower(btrim(coalesce(tr.receiver_email, ''))) = (
                     SELECT lower(u.email) FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL)
             ORDER BY 2 DESC LIMIT 500) x;

  WHEN 'transfers.create' THEN
    IF jsonb_typeof(a->'items') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'exos_api_me: send items: [{ ticket_id, email, name }]' USING ERRCODE = '22023';
    END IF;
    v_out := jsonb_build_object('transfers', public.exos_bulk_create_transfers(a->'items'));

  WHEN 'transfer.cancel' THEN
    v_id := public._exos_api_uuid(p_target, 'transfer');
    IF NOT EXISTS (SELECT 1 FROM public.exos_transfers tr WHERE tr.id = v_id AND tr.sender_id = v_uid) THEN
      RAISE EXCEPTION 'exos_api_me: transfer not found' USING ERRCODE = 'P0002';
    END IF;
    PERFORM public.exos_cancel_transfer(v_id);
    v_out := jsonb_build_object('id', v_id, 'status', 'cancelled');

  WHEN 'transfer.claim' THEN
    v_id := public._exos_api_uuid(p_target, 'transfer');
    IF nullif(btrim(coalesce(a->>'key', '')), '') IS NULL THEN
      RAISE EXCEPTION 'exos_api_me: key (from the claim link) is required' USING ERRCODE = '22023';
    END IF;
    v_id := public.exos_claim_transfer(v_id, a->>'key');
    v_out := public._exos_api_me_ticket_json(v_id, v_uid, false);

  -- Memberships and passes ------------------------------------------------------------
  WHEN 'memberships.list', 'membership.get' THEN
    IF p_action = 'membership.get' THEN v_id := public._exos_api_uuid(p_target, 'membership'); END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) INTO v_out FROM public.exos_my_memberships() m
     WHERE v_id IS NULL OR m.id = v_id;
    IF p_action = 'membership.get' THEN
      IF jsonb_array_length(v_out) = 0 THEN RAISE EXCEPTION 'exos_api_me: membership not found' USING ERRCODE = 'P0002'; END IF;
      v_out := v_out->0;
    END IF;

  WHEN 'passes.list', 'pass.get' THEN
    IF a ? 'kind' AND coalesce(a->>'kind', '') NOT IN ('season', 'flex') THEN
      RAISE EXCEPTION 'exos_api_me: kind must be season or flex' USING ERRCODE = '22023';
    END IF;
    IF p_action = 'pass.get' THEN v_id := public._exos_api_uuid(p_target, 'pass'); END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) INTO v_out FROM public.exos_my_passes() p
     WHERE (NOT a ? 'kind' OR p.kind = a->>'kind') AND (v_id IS NULL OR p.id = v_id);
    IF p_action = 'pass.get' THEN
      IF jsonb_array_length(v_out) = 0 THEN RAISE EXCEPTION 'exos_api_me: pass not found' USING ERRCODE = 'P0002'; END IF;
      v_out := v_out->0;
    END IF;

  -- Refund requests -------------------------------------------------------------------
  WHEN 'refund_asks.list' THEN
    SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) INTO v_out FROM public.exos_my_refund_asks_all() r;

  WHEN 'order.refund_asks' THEN
    IF NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs WHERE cs.session_id = p_target AND cs.buyer_uid = v_uid) THEN
      RAISE EXCEPTION 'exos_api_me: order not found' USING ERRCODE = 'P0002';
    END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) INTO v_out FROM public.exos_my_refund_asks_all() r
     WHERE r.ticket_id IN (SELECT tk.id FROM public.exos_tickets tk WHERE tk.order_ref = p_target);

  WHEN 'refund.ask', 'order.refund_ask' THEN
    IF p_action = 'order.refund_ask'
       AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs WHERE cs.session_id = p_target AND cs.buyer_uid = v_uid) THEN
      RAISE EXCEPTION 'exos_api_me: order not found' USING ERRCODE = 'P0002';
    END IF;
    IF a ? 'ticket_ids' THEN
      IF jsonb_typeof(a->'ticket_ids') <> 'array' OR jsonb_array_length(a->'ticket_ids') NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'exos_api_me: ticket_ids must be a list of 1 to 50 ids' USING ERRCODE = '22023';
      END IF;
      v_ids := ARRAY(SELECT public._exos_api_uuid(x, 'ticket') FROM jsonb_array_elements_text(a->'ticket_ids') x);
      IF p_action = 'order.refund_ask' AND EXISTS (SELECT 1 FROM unnest(v_ids) i WHERE NOT EXISTS (
           SELECT 1 FROM public.exos_tickets tk WHERE tk.id = i AND tk.order_ref = p_target)) THEN
        RAISE EXCEPTION 'exos_api_me: a ticket is not part of this order' USING ERRCODE = '22023';
      END IF;
    ELSIF p_action = 'order.refund_ask' THEN
      -- Default: the order's tickets the user still holds (a ticket they
      -- transferred is someone else's now; naming it explicitly leaves the
      -- decision to exos_ask_refund's own rules).
      v_ids := ARRAY(SELECT tk.id FROM public.exos_tickets tk
                      WHERE tk.order_ref = p_target AND tk.owner_id = v_uid AND tk.status = 'active'
                      ORDER BY tk.created_at, tk.id LIMIT 50);
      IF cardinality(v_ids) = 0 THEN
        RAISE EXCEPTION 'exos_api_me: this order has no tickets you hold' USING ERRCODE = '55000';
      END IF;
    ELSE
      RAISE EXCEPTION 'exos_api_me: ticket_ids is required' USING ERRCODE = '22023';
    END IF;
    v_out := public.exos_ask_refund(v_ids, a->>'reason');

  WHEN 'refund.withdraw' THEN
    v_id := public._exos_api_uuid(p_target, 'refund request');
    v_out := jsonb_build_object('id', v_id, 'withdrawn', public.exos_withdraw_refund_ask(v_id));

  -- Wallet ---------------------------------------------------------------------------
  WHEN 'wallet.ticket' THEN
    v_out := public.exos_wallet_issue_pass(public._exos_api_uuid(p_target, 'ticket'), a->>'kind',
                                           a->>'token_hash', a->>'pass_type');

  WHEN 'wallet.season_pass' THEN
    v_id := public._exos_api_uuid(p_target, 'pass');
    IF a ? 'kind' AND NOT EXISTS (SELECT 1 FROM public.exos_passes p WHERE p.id = v_id AND p.kind = a->>'kind') THEN
      RAISE EXCEPTION 'exos_api_me: pass not found' USING ERRCODE = 'P0002';
    END IF;
    v_out := public.exos_wallet_season_pass(v_id);

  -- Tokens (Opendate POST /personal_access_tokens) ----------------------------------
  -- Only a personal access token or an account token manages tokens (an app
  -- never mints or revokes its user's credentials). A new token gets at most
  -- the scopes of the token that makes it and never outlives it; a personal
  -- token makes one for the same organization (exos_create_personal_token's
  -- role rules hold), an account token another account token.
  WHEN 'tokens.list' THEN
    SELECT coalesce(jsonb_agg(x.j ORDER BY x.created_at DESC, x.id), '[]'::jsonb) INTO v_out
      FROM (SELECT p.id, p.created_at, jsonb_build_object('id', p.id, 'kind', 'personal', 'org_id', p.org_id,
                     'name', p.name, 'key_prefix', p.key_prefix, 'scopes', to_jsonb(p.scopes),
                     'expires_at', p.expires_at, 'last_used_at', p.last_used_at, 'created_at', p.created_at,
                     'current', p.id::text = v_cred->>'credential_id') AS j
              FROM public.exos_personal_tokens p
             WHERE p.user_id = v_uid AND p.revoked_at IS NULL AND (p.expires_at IS NULL OR p.expires_at > now())
            UNION ALL
            SELECT t.id, t.created_at, jsonb_build_object('id', t.id, 'kind', 'account', 'org_id', NULL,
                     'name', t.name, 'key_prefix', t.key_prefix, 'scopes', to_jsonb(t.scopes),
                     'expires_at', t.expires_at, 'last_used_at', t.last_used_at, 'created_at', t.created_at,
                     'current', t.id::text = v_cred->>'credential_id')
              FROM public.exos_account_tokens t
             WHERE t.user_id = v_uid AND t.revoked_at IS NULL AND (t.expires_at IS NULL OR t.expires_at > now())) x;

  WHEN 'token.create', 'token.revoke' THEN
    IF p_kind <> 'pat' THEN
      RAISE EXCEPTION 'exos_api_me: an app can''t manage your tokens; use a personal access token or an account token'
        USING ERRCODE = '42501';
    END IF;
    IF p_action = 'token.revoke' THEN
      v_id := public._exos_api_uuid(p_target, 'token');
      IF EXISTS (SELECT 1 FROM public.exos_personal_tokens WHERE id = v_id AND user_id = v_uid) THEN
        v_out := jsonb_build_object('id', v_id, 'revoked', public.exos_revoke_personal_token(v_id));
      ELSIF EXISTS (SELECT 1 FROM public.exos_account_tokens WHERE id = v_id AND user_id = v_uid) THEN
        v_out := jsonb_build_object('id', v_id, 'revoked', public.exos_revoke_account_token(v_id));
      ELSE
        RAISE EXCEPTION 'exos_api_me: token not found' USING ERRCODE = 'P0002';
      END IF;
    ELSE
      IF jsonb_typeof(a->'scopes') IS DISTINCT FROM 'array' OR jsonb_array_length(a->'scopes') NOT BETWEEN 1 AND 40 THEN
        RAISE EXCEPTION 'exos_api_me: scopes must be a list of scope names' USING ERRCODE = '22023';
      END IF;
      v_req := ARRAY(SELECT DISTINCT x FROM jsonb_array_elements_text(a->'scopes') x);
      SELECT x INTO v_name FROM unnest(v_req) x
       WHERE NOT (x = ANY (v_scopes) OR (x LIKE '%:read' AND replace(x, ':read', ':write') = ANY (v_scopes))) LIMIT 1;
      IF v_name IS NOT NULL THEN
        RAISE EXCEPTION 'exos_api_me: this token can''t grant % (a new token gets at most the scopes of the token that makes it)',
          left(v_name, 40) USING ERRCODE = '42501';
      END IF;
      IF a ? 'expires_days' AND jsonb_typeof(a->'expires_days') NOT IN ('number', 'null') THEN
        RAISE EXCEPTION 'exos_api_me: expires_days must be 30, 90, 365 or null' USING ERRCODE = '22023';
      END IF;
      v_days := CASE WHEN a ? 'expires_days' THEN (a->>'expires_days')::int ELSE 90 END;
      SELECT coalesce((SELECT p.expires_at FROM public.exos_personal_tokens p WHERE p.id::text = v_cred->>'credential_id'),
                      (SELECT t.expires_at FROM public.exos_account_tokens t WHERE t.id::text = v_cred->>'credential_id'))
        INTO v_exp;
      IF coalesce((v_cred->>'account')::boolean, false) THEN
        v_out := public.exos_create_account_token(a->>'name', v_req, v_days);
        IF v_exp IS NOT NULL THEN
          UPDATE public.exos_account_tokens SET expires_at = least(coalesce(expires_at, v_exp), v_exp)
           WHERE id = (v_out->>'id')::uuid RETURNING expires_at INTO v_exp;
        END IF;
      ELSE
        v_out := public.exos_create_personal_token((v_cred->>'org_id')::uuid, a->>'name', v_req, v_days);
        IF v_exp IS NOT NULL THEN
          UPDATE public.exos_personal_tokens SET expires_at = least(coalesce(expires_at, v_exp), v_exp)
           WHERE id = (v_out->>'id')::uuid RETURNING expires_at INTO v_exp;
        END IF;
      END IF;
      v_out := v_out || jsonb_build_object('kind', CASE WHEN coalesce((v_cred->>'account')::boolean, false)
                                                        THEN 'account' ELSE 'personal' END,
                                           'org_id', v_cred->'org_id',
                                           'expires_at', coalesce(to_jsonb(v_exp), v_out->'expires_at'));
    END IF;
  END CASE;

  PERFORM set_config('request.jwt.claims', coalesce(v_was ->> 'claims', ''), true);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_was ->> 'sub', ''), true);
  PERFORM set_config('request.jwt.claim.role', coalesce(v_was ->> 'role', ''), true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_was ->> 'email', ''), true);
  RETURN coalesce(v_out, 'null'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_api_me(text, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_me(text, text, text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Organization writes still missing from /v1 (org API keys).
--    exos_api_commerce_write's steps (20261102100000): the key and its org,
--    the scope again, run as the key's creator while an active member, the
--    Idempotency-Key (claimed first, replayed after), the dashboard RPC, the
--    log. Every target is pinned to the key's org first (else not found).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_api_gap_action_scope(p_action text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN p_action IN ('series.create', 'series.update', 'series.cancel', 'series.delete', 'series.attach',
                      'series.detach', 'series.generate', 'series.cancel_date',
                      'fee_rule.create', 'fee_rule.update', 'fee_rule.delete') THEN 'events:write'
    WHEN p_action IN ('membership.gift', 'membership.cancel_gift', 'gift_card.issue', 'donation.offline')
      THEN 'commerce:write'
    WHEN p_action = 'membership.scan' THEN 'checkin:write'
    WHEN p_action IN ('seats.release_orphans', 'migrated_attendees.bulk') THEN 'tickets:write'
    WHEN p_action IN ('api_key.create', 'api_key.revoke') THEN 'org:admin'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_api_gap_action_scope(text) FROM PUBLIC, anon, authenticated;

-- The dashboard roles each action needs from the key's creator NOW (mirrors
-- GAP_ACTION_ROLES in _shared/api/gapWrites.ts; _exos_api_key_actor checks
-- it, as the sibling routes' actor() does). The dashboard RPCs check their
-- own role again as that member.
CREATE OR REPLACE FUNCTION public._exos_api_gap_action_roles(p_action text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN p_action IN ('api_key.create', 'api_key.revoke') THEN ARRAY['owner']
    WHEN p_action = 'membership.scan' THEN ARRAY['owner', 'manager', 'scanner']
    WHEN p_action = 'donation.offline' THEN ARRAY['owner', 'manager', 'finance']
    WHEN public._exos_api_gap_action_scope(p_action) IS NOT NULL THEN ARRAY['owner', 'manager']
  END
$$;
REVOKE ALL ON FUNCTION public._exos_api_gap_action_roles(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_api_gap_membership_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', m.id, 'product_id', m.product_id, 'product_name', m.product_name,
           'status', m.status, 'holder_email', m.holder_email, 'current_period_end', m.current_period_end,
           'source', m.source, 'gift', CASE WHEN m.gift IS NULL THEN NULL
                                            ELSE (m.gift - 'from_uid' - 'token' - 'claim_token') END,
           'created_at', m.created_at)
    FROM public.exos_fan_memberships m WHERE m.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_api_gap_membership_json(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_api_gap_write(
  p_key_id uuid, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb,
  p_idempotency_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  k public.exos_api_keys%ROWTYPE; v_org uuid; v_actor uuid; v_email text; v_scope text; v_log uuid;
  v_prev public.exos_api_writes%ROWTYPE; v_was jsonb; v_out jsonb; v_id uuid; v_id2 uuid; v_tmp jsonb;
  v_scopes text[]; v_bad text; v_key text; v_n int; v_res jsonb;
  a jsonb := coalesce(p_args, '{}'::jsonb);
  c_rule_fields text[] := ARRAY['name', 'recipient', 'kind', 'calc', 'percent', 'amount_cents', 'cap_cents', 'per',
                                'taxable', 'applies_to_addons', 'tier_ids', 'active', 'sort_order'];
BEGIN
  SELECT * INTO k FROM public.exos_api_keys WHERE id = p_key_id AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: invalid or revoked API key' USING ERRCODE = '42501'; END IF;
  v_org := k.org_id;
  v_scope := public._exos_api_gap_action_scope(p_action);
  IF v_scope IS NULL THEN RAISE EXCEPTION 'exos_api_write: unknown action' USING ERRCODE = '22023'; END IF;
  -- The key's scopes NOW (as stored, narrowed to its creator's live role's
  -- set in the org, mig 20261104180000), not as stored.
  IF NOT public._exos_api_has_scope(public._exos_api_key_scopes(k.id), v_scope) THEN
    RAISE EXCEPTION 'exos_api_write: the key lacks the % scope', v_scope USING ERRCODE = '42501';
  END IF;
  -- The key's creator, holding the dashboard role this action needs now
  -- (keys are the owner's business: org:admin key writes need an owner).
  v_actor := public._exos_api_key_actor(v_org, k.id, public._exos_api_gap_action_roles(p_action));
  IF p_idempotency_key IS NOT NULL THEN
    IF p_idempotency_key !~ '^[A-Za-z0-9_.:-]{8,100}$' THEN
      RAISE EXCEPTION 'exos_api_write: Idempotency-Key must be 8-100 letters, digits, _ . : or -' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, idempotency_key)
    VALUES (v_org, k.id, v_actor, p_action, left(p_target, 255), p_idempotency_key)
    ON CONFLICT (api_key_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
    RETURNING id INTO v_log;
    IF v_log IS NULL THEN
      SELECT * INTO v_prev FROM public.exos_api_writes WHERE api_key_id = k.id AND idempotency_key = p_idempotency_key;
      IF v_prev.action IS DISTINCT FROM p_action OR v_prev.target IS DISTINCT FROM left(p_target, 255) THEN
        RAISE EXCEPTION 'exos_api_write: this Idempotency-Key was already used for another request' USING ERRCODE = '22023';
      END IF;
      RETURN coalesce(v_prev.result, '{}'::jsonb) || jsonb_build_object('idempotent_replay', true);
    END IF;
  END IF;

  v_was := jsonb_build_object(
    'claims', current_setting('request.jwt.claims', true), 'sub', current_setting('request.jwt.claim.sub', true),
    'role', current_setting('request.jwt.claim.role', true), 'email', current_setting('request.jwt.claim.email', true));
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_actor;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_actor, 'role', 'authenticated',
    'email', coalesce(v_email, ''), 'exos_api_key_id', k.id)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_actor::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_email, ''), true);

  CASE
  -- Event series ----------------------------------------------------------------------
  WHEN p_action = 'series.create' THEN
    v_id := public._exos_api_uuid(a->>'template_event_id', 'event');
    IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: event not found' USING ERRCODE = 'P0002';
    END IF;
    IF nullif(btrim(coalesce(a->>'name', '')), '') IS NULL OR jsonb_typeof(a->'rule') IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'exos_api_write: a series needs a name and a rule' USING ERRCODE = '22023';
    END IF;
    v_id := public.exos_series_create(v_id, a->>'name', a->'rule', a->>'description');
    SELECT to_jsonb(s) INTO v_out FROM public.exos_event_series s WHERE s.id = v_id;

  WHEN p_action LIKE 'series.%' THEN
    v_id := public._exos_api_uuid(p_target, 'series');
    IF NOT EXISTS (SELECT 1 FROM public.exos_event_series WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: series not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_action IN ('series.attach', 'series.detach') THEN
      v_id2 := public._exos_api_uuid(coalesce(a->>'event_id', p_args->>'event_id'), 'event');
      IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = v_id2 AND org_id = v_org) THEN
        RAISE EXCEPTION 'exos_api_write: event not found' USING ERRCODE = 'P0002';
      END IF;
    END IF;
    CASE p_action
      WHEN 'series.update' THEN v_res := public.exos_series_update(v_id, a);
      WHEN 'series.cancel' THEN
        v_res := public.exos_series_cancel(v_id, coalesce(a->>'scope', 'series_only'),
                   CASE WHEN jsonb_typeof(a->'event_ids') = 'array'
                        THEN ARRAY(SELECT public._exos_api_uuid(x, 'event') FROM jsonb_array_elements_text(a->'event_ids') x) END,
                   a->>'reason');
      WHEN 'series.delete' THEN v_res := public.exos_series_delete(v_id);
      WHEN 'series.attach' THEN v_res := public.exos_series_attach_event(v_id, v_id2);
      WHEN 'series.detach' THEN
        v_res := jsonb_build_object('detached', public.exos_series_detach_event(v_id, v_id2), 'event_id', v_id2);
      WHEN 'series.generate' THEN
        IF jsonb_typeof(a->'dates') IS DISTINCT FROM 'array' THEN
          RAISE EXCEPTION 'exos_api_write: dates must be a list of { date, time }' USING ERRCODE = '22023';
        END IF;
        v_res := public.exos_series_generate(v_id, a->'dates');
      ELSE -- series.cancel_date
        IF coalesce(a->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$' THEN
          RAISE EXCEPTION 'exos_api_write: date must be YYYY-MM-DD' USING ERRCODE = '22023';
        END IF;
        v_res := to_jsonb(public.exos_series_cancel_date(v_id, (a->>'date')::date, a->>'reason'));
    END CASE;
    v_out := jsonb_build_object('result', v_res,
      'series', (SELECT to_jsonb(s) FROM public.exos_event_series s WHERE s.id = v_id));

  -- Fee rules of an event (Opendate organizer_fee_components) ---------------------------
  WHEN p_action LIKE 'fee_rule.%' THEN
    IF NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can change fee rules' USING ERRCODE = '42501';
    END IF;
    v_id := public._exos_api_uuid(p_target, 'event');
    IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: event not found' USING ERRCODE = 'P0002';
    END IF;
    SELECT k2 INTO v_bad FROM jsonb_object_keys(a - 'rule_id') k2 WHERE NOT (k2 = ANY (c_rule_fields)) LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION 'exos_api_write: unknown or read-only field: %', left(v_bad, 40) USING ERRCODE = '22023';
    END IF;
    IF p_action = 'fee_rule.create' THEN
      v_tmp := jsonb_build_object('kind', 'passed_on', 'calc', 'percent', 'recipient', 'org', 'per', 'ticket') || a;
      INSERT INTO public.exos_fee_rules (org_id, event_id, name, recipient, kind, calc, percent, amount_cents, cap_cents,
                                         per, taxable, applies_to_addons, tier_ids, active, sort_order, created_by)
      SELECT v_org, v_id, r.name, r.recipient, r.kind, r.calc, r.percent, r.amount_cents, r.cap_cents, r.per,
             coalesce(r.taxable, true), coalesce(r.applies_to_addons, false), r.tier_ids, coalesce(r.active, true),
             coalesce(r.sort_order, 0), v_actor
        FROM jsonb_populate_record(NULL::public.exos_fee_rules, v_tmp) r
      RETURNING id INTO v_id2;
    ELSE
      v_id2 := public._exos_api_uuid(a->>'rule_id', 'fee rule');
      IF NOT EXISTS (SELECT 1 FROM public.exos_fee_rules WHERE id = v_id2 AND org_id = v_org AND event_id = v_id) THEN
        RAISE EXCEPTION 'exos_api_write: fee rule not found' USING ERRCODE = 'P0002';
      END IF;
      IF p_action = 'fee_rule.delete' THEN
        DELETE FROM public.exos_fee_rules WHERE id = v_id2;
        v_out := jsonb_build_object('id', v_id2, 'deleted', true);
      ELSE
        SELECT to_jsonb(f) || (a - 'rule_id') INTO v_tmp FROM public.exos_fee_rules f WHERE f.id = v_id2;
        UPDATE public.exos_fee_rules f SET
          name = r.name, recipient = r.recipient, kind = r.kind, calc = r.calc, percent = r.percent,
          amount_cents = r.amount_cents, cap_cents = r.cap_cents, per = r.per, taxable = r.taxable,
          applies_to_addons = r.applies_to_addons, tier_ids = r.tier_ids, active = r.active, sort_order = r.sort_order
          FROM jsonb_populate_record(NULL::public.exos_fee_rules, v_tmp) r
         WHERE f.id = v_id2;
      END IF;
    END IF;
    IF p_action <> 'fee_rule.delete' THEN
      SELECT jsonb_build_object('id', f.id, 'event_id', f.event_id, 'name', f.name, 'recipient', f.recipient,
               'kind', f.kind, 'calc', f.calc, 'percent', f.percent, 'amount_cents', f.amount_cents,
               'cap_cents', f.cap_cents, 'per', f.per, 'taxable', f.taxable, 'applies_to_addons', f.applies_to_addons,
               'tier_ids', f.tier_ids, 'active', f.active, 'sort_order', f.sort_order,
               'created_at', f.created_at, 'updated_at', f.updated_at)
        INTO v_out FROM public.exos_fee_rules f WHERE f.id = v_id2;
    END IF;

  -- Memberships ---------------------------------------------------------------------
  WHEN p_action = 'membership.scan' THEN
    v_out := public.exos_membership_scan(v_org, public._exos_api_uuid(p_target, 'membership'));

  WHEN p_action = 'membership.gift' THEN
    v_id := public._exos_api_uuid(p_target, 'membership product');
    IF NOT EXISTS (SELECT 1 FROM public.exos_membership_products WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: membership product not found' USING ERRCODE = 'P0002';
    END IF;
    v_id2 := public.exos_membership_gift(v_id, a->>'to_email', a->>'from_name', a->>'message');
    v_out := public._exos_api_gap_membership_json(v_id2);

  WHEN p_action = 'membership.cancel_gift' THEN
    v_id := public._exos_api_uuid(p_target, 'membership');
    IF NOT EXISTS (SELECT 1 FROM public.exos_fan_memberships WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: membership not found' USING ERRCODE = 'P0002';
    END IF;
    PERFORM public.exos_membership_cancel_gift(v_id);
    v_out := public._exos_api_gap_membership_json(v_id);

  -- Gift cards and donations ------------------------------------------------------------
  WHEN p_action = 'gift_card.issue' THEN
    v_id := public._exos_api_uuid(p_target, 'gift card product');
    IF NOT EXISTS (SELECT 1 FROM public.exos_gift_card_products WHERE id = v_id AND org_id = v_org AND active) THEN
      RAISE EXCEPTION 'exos_api_write: gift card product not found' USING ERRCODE = 'P0002';
    END IF;
    -- The code is the card: it is emailed, never returned by the API.
    IF nullif(btrim(coalesce(a->>'recipient_email', '')), '') IS NULL
       AND nullif(btrim(coalesce(a->>'purchaser_email', '')), '') IS NULL THEN
      RAISE EXCEPTION 'exos_api_write: recipient_email or purchaser_email is required (the code is emailed)' USING ERRCODE = '22023';
    END IF;
    IF a ? 'amount_cents' AND jsonb_typeof(a->'amount_cents') <> 'number' THEN
      RAISE EXCEPTION 'exos_api_write: amount_cents must be a whole number' USING ERRCODE = '22023';
    END IF;
    v_res := public.exos_gift_card_issue(v_org, (a->>'amount_cents')::int, coalesce(a->>'payment_method', 'comp'), v_id,
      coalesce(a->>'currency', (SELECT currency FROM public.exos_gift_card_products WHERE id = v_id)),
      a->>'recipient_email', a->>'recipient_name', a->>'message', a->>'purchaser_email', a->>'external_id', 'dashboard', NULL);
    v_out := (v_res - 'code') || jsonb_build_object('product_id', v_id, 'emailed', true);

  WHEN p_action = 'donation.offline' THEN
    v_id := public._exos_api_uuid(p_target, 'giving campaign');
    IF NOT EXISTS (SELECT 1 FROM public.exos_giving_campaigns WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: giving campaign not found' USING ERRCODE = 'P0002';
    END IF;
    IF a ? 'amount_cents' AND jsonb_typeof(a->'amount_cents') <> 'number' THEN
      RAISE EXCEPTION 'exos_api_write: amount_cents must be a whole number' USING ERRCODE = '22023';
    END IF;
    v_id2 := public.exos_record_offline_donation(v_id, (a->>'amount_cents')::int, coalesce(a->>'method', 'other'),
      a->>'donor_name', a->>'donor_email', coalesce((a->>'anonymous')::boolean, false), a->>'note', a->>'external_id');
    SELECT jsonb_build_object('id', d.id, 'campaign_id', d.campaign_id, 'amount_cents', d.amount_cents,
             'currency', d.currency, 'method', d.method, 'donor_name', d.donor_name, 'donor_email', d.donor_email,
             'anonymous', d.anonymous, 'status', d.status, 'created_at', d.created_at)
      INTO v_out FROM public.exos_donations d WHERE d.id = v_id2;

  -- Seats and imported attendees ----------------------------------------------------------
  WHEN p_action = 'seats.release_orphans' THEN
    v_id := public._exos_api_uuid(p_target, 'event');
    IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: event not found' USING ERRCODE = 'P0002';
    END IF;
    IF jsonb_typeof(a->'seat_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(a->'seat_ids') NOT BETWEEN 1 AND 500 THEN
      RAISE EXCEPTION 'exos_api_write: seat_ids must be a list of 1 to 500 seat ids' USING ERRCODE = '22023';
    END IF;
    v_out := jsonb_build_object('event_id', v_id, 'released',
      public.exos_release_orphan_seats(v_id, ARRAY(SELECT jsonb_array_elements_text(a->'seat_ids'))));

  WHEN p_action = 'migrated_attendees.bulk' THEN
    v_id := public._exos_api_uuid(a->>'list_id', 'guest list');
    IF NOT EXISTS (SELECT 1 FROM public.exos_guest_lists WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: guest list not found' USING ERRCODE = 'P0002';
    END IF;
    IF jsonb_typeof(a->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(a->'rows') NOT BETWEEN 1 AND 5000 THEN
      RAISE EXCEPTION 'exos_api_write: rows must be a list of 1 to 5000 attendees' USING ERRCODE = '22023';
    END IF;
    v_out := public.exos_import_guests(v_id, a->'rows');

  -- API keys --------------------------------------------------------------------------
  WHEN p_action = 'api_key.create' THEN
    IF jsonb_typeof(a->'scopes') IS DISTINCT FROM 'array' OR jsonb_array_length(a->'scopes') = 0 THEN
      RAISE EXCEPTION 'exos_api_write: scopes must be a non-empty list' USING ERRCODE = '22023';
    END IF;
    v_scopes := ARRAY(SELECT jsonb_array_elements_text(a->'scopes'));
    -- A key can't mint a key that can do more than itself.
    SELECT s INTO v_bad FROM unnest(v_scopes) s WHERE NOT public._exos_api_has_scope(public._exos_api_key_scopes(k.id), s) LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION 'exos_api_write: this key can''t grant % (a new key gets at most the scopes of the key that makes it)',
        left(v_bad, 40) USING ERRCODE = '42501';
    END IF;
    v_key := public.exos_create_api_key(v_org, a->>'name', v_scopes);
    SELECT jsonb_build_object('id', x.id, 'name', x.name, 'key_prefix', x.key_prefix, 'scopes', to_jsonb(x.scopes),
             'created_at', x.created_at) INTO v_out
      FROM public.exos_api_keys x WHERE x.key_hash = encode(extensions.digest(v_key, 'sha256'), 'hex');
    -- The plaintext goes back once and is never logged (v_res is what is logged).
    v_res := v_out;
    v_out := v_out || jsonb_build_object('key', v_key);

  WHEN p_action = 'api_key.revoke' THEN
    v_id := public._exos_api_uuid(p_target, 'API key');
    IF NOT EXISTS (SELECT 1 FROM public.exos_api_keys WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: API key not found' USING ERRCODE = 'P0002';
    END IF;
    v_out := jsonb_build_object('id', v_id, 'revoked', public.exos_revoke_api_key(v_id));
  END CASE;

  PERFORM set_config('request.jwt.claims', coalesce(v_was ->> 'claims', ''), true);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_was ->> 'sub', ''), true);
  PERFORM set_config('request.jwt.claim.role', coalesce(v_was ->> 'role', ''), true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_was ->> 'email', ''), true);

  IF v_log IS NOT NULL THEN
    UPDATE public.exos_api_writes SET result = CASE WHEN p_action = 'api_key.create' THEN v_res ELSE v_out END
     WHERE id = v_log;
  ELSE
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target)
    VALUES (v_org, k.id, v_actor, p_action, left(p_target, 255));
  END IF;
  RETURN coalesce(v_out, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_api_gap_write(uuid, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_gap_write(uuid, text, text, jsonb, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. A role's API permissions (mig 20261104180000) never hold user scopes.
--    me:read / me:write are about the token's own user, not the org, so they
--    aren't the owner's to set: now that every role's token default carries
--    them, a set built from that default drops them instead of failing as an
--    unknown scope. Same body as 20261104180000 plus the first statement.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_tg_org_role_scopes()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_bad text;
BEGIN
  NEW.scopes := ARRAY(SELECT s FROM unnest(coalesce(NEW.scopes, '{}')) s WHERE s IS NULL OR s NOT LIKE 'me:%');
  IF TG_OP = 'UPDATE' AND (NEW.org_id IS DISTINCT FROM OLD.org_id OR NEW.role IS DISTINCT FROM OLD.role) THEN
    RAISE EXCEPTION 'a role''s API permissions can''t move' USING ERRCODE = '22023';
  END IF;
  SELECT s INTO v_bad FROM unnest(coalesce(NEW.scopes, '{}')) s
   WHERE s IS NULL OR NOT (s = ANY (public._exos_org_scope_vocab())) LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'unknown scope %', left(coalesce(v_bad, 'null'), 40) USING ERRCODE = '22023';
  END IF;
  SELECT s INTO v_bad FROM unnest(NEW.scopes) s WHERE NOT (s = ANY (public.exos_role_scope_ceiling(NEW.role))) LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'role_scope_ceiling: the % role can never be given %', NEW.role, v_bad USING ERRCODE = '42501';
  END IF;
  NEW.scopes := ARRAY(SELECT n FROM unnest(public._exos_org_scope_vocab()) WITH ORDINALITY v(n, i)
                       WHERE n = ANY (NEW.scopes) ORDER BY i);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_org_role_scopes() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Public discovery (exos-api /v1/public/discovery/…, /public/venues,
--    /public/search, /public/event-series; Opendate fan_app and
--    public_website_event_series). No credential. Only what the storefront
--    already shows anyone: published events through _exos_public_event_json
--    (its fixed column list), public ticket types (price, tax and schedule
--    so exos-api can quote the all-in price; never capacity or sales
--    counts), an organizer's public profile, and the public series RPCs.
--
--    _exos_api_public is the core (service role: exos-api passes the
--    caller's network bucket, a salted hash of the IP). exos_api_public is
--    the same for anon callers, bucketed by _exos_request_ip_bucket(). Both
--    allow 60 requests a minute per network (exos_rate_hit), else 54000.
-- ---------------------------------------------------------------------------

-- An organizer as the public sees it (the storefront's column set).
CREATE OR REPLACE FUNCTION public._exos_api_public_org_json(p_org uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (SELECT jsonb_object_agg(k.key, k.value) FROM jsonb_each(to_jsonb(o)) k
           WHERE k.key = ANY (ARRAY['id', 'name', 'slug', 'description', 'theme', 'followers_count']))
         || jsonb_build_object('upcoming_events_count',
              (SELECT count(*) FROM public.exos_events e
                WHERE e.org_id = o.id AND e.status = 'published' AND coalesce(e.ends_at, e.starts_at) >= now()))
    FROM public.exos_orgs o WHERE o.id = p_org
$$;
REVOKE ALL ON FUNCTION public._exos_api_public_org_json(uuid) FROM PUBLIC, anon, authenticated;

-- An event's public ticket types: what the storefront lists (public
-- visibility), with what exos-api needs for the all-in price.
CREATE OR REPLACE FUNCTION public._exos_api_public_tiers_json(p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'event_id', t.event_id, 'name', t.name, 'description', t.description, 'price', t.price,
           'price_schedule', t.price_schedule, 'sales_start', t.sales_start, 'sales_end', t.sales_end,
           'exclusive_tax_percent', public.exos_tier_exclusive_tax_percent(t.id),
           'sold_out', t.capacity IS NOT NULL AND t.capacity > 0 AND coalesce(t.sold, 0) >= t.capacity)
           ORDER BY t.sort_order, t.name, t.id), '[]'::jsonb)
    FROM public.exos_ticket_tiers t
   WHERE t.event_id = p_event AND coalesce(t.visibility, 'public') = 'public'
     AND EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = t.event_id AND e.status = 'published')
$$;
REVOKE ALL ON FUNCTION public._exos_api_public_tiers_json(uuid) FROM PUBLIC, anon, authenticated;

-- A published event for discovery: the public event, its organizer, its
-- ticket types (lists: for the "from" price only).
CREATE OR REPLACE FUNCTION public._exos_api_public_event_full(p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_public_event_json(e.id)
         || jsonb_build_object('org', (SELECT jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug)
                                          FROM public.exos_orgs o WHERE o.id = e.org_id),
                               'ticket_types', public._exos_api_public_tiers_json(e.id))
    FROM public.exos_events e WHERE e.id = p_event AND e.status = 'published'
$$;
REVOKE ALL ON FUNCTION public._exos_api_public_event_full(uuid) FROM PUBLIC, anon, authenticated;

-- Search words as an ILIKE pattern: letters, digits, spaces and ' & . -
-- only (mirrors cleanSearch in _shared/api/publicDiscovery.ts), 2-80 long.
CREATE OR REPLACE FUNCTION public._exos_api_public_like(p_q text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN char_length(w) >= 2 THEN '%' || w || '%' END
    FROM (SELECT left(btrim(regexp_replace(regexp_replace(normalize(coalesce(p_q, ''), NFKC),
                   '[^[:alnum:] ''&.-]', ' ', 'g'), '\s+', ' ', 'g')), 80) AS w) x
$$;
REVOKE ALL ON FUNCTION public._exos_api_public_like(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_api_public(
  p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb, p_bucket text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a       jsonb := coalesce(p_args, '{}'::jsonb);
  v_lim   int := least(greatest(coalesce((a->>'limit')::int, 50), 1), 200);
  v_off   int := least(greatest(coalesce((a->>'offset')::int, 0), 0), 200000);
  v_org   uuid;
  v_id    uuid;
  v_like  text;
  v_after timestamptz;
  v_before timestamptz;
  v_out   jsonb;
BEGIN
  IF p_action IS NULL OR p_action NOT IN ('events.list', 'event.get', 'venues.list', 'venue.get', 'search',
                                          'series.list', 'series.get') THEN
    RAISE EXCEPTION 'exos_api_public: unknown action' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('api-public:' || left(coalesce(nullif(p_bucket, ''), 'unknown'), 100), 60) THEN
    RAISE EXCEPTION 'exos_api_public: too many requests from this network; try again in a minute' USING ERRCODE = '54000';
  END IF;
  -- An organizer by id or slug (?venue_id= / the venue path).
  IF coalesce(a->>'venue', p_target) IS NOT NULL AND p_action IN ('events.list', 'venue.get', 'series.list') THEN
    SELECT o.id INTO v_org FROM public.exos_orgs o
     WHERE (coalesce(a->>'venue', p_target) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            AND o.id = coalesce(a->>'venue', p_target)::uuid)
        OR o.slug = lower(coalesce(a->>'venue', p_target))
     LIMIT 1;
    IF v_org IS NULL THEN RAISE EXCEPTION 'exos_api_public: venue not found' USING ERRCODE = 'P0002'; END IF;
  END IF;
  BEGIN
    v_after := nullif(a->>'starts_after', '')::timestamptz;
    v_before := nullif(a->>'starts_before', '')::timestamptz;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'exos_api_public: starts_after / starts_before must be ISO 8601 times' USING ERRCODE = '22023';
  END;
  v_like := public._exos_api_public_like(coalesce(a->>'q', ''));
  IF p_action = 'search' AND v_like IS NULL THEN
    RAISE EXCEPTION 'exos_api_public: q must be at least 2 letters or digits' USING ERRCODE = '22023';
  END IF;

  CASE p_action
  WHEN 'events.list' THEN
    WITH m AS (
      SELECT e.id, e.starts_at FROM public.exos_events e
       WHERE e.status = 'published'
         AND coalesce(e.ends_at, e.starts_at) >= coalesce(v_after, now())
         AND (v_before IS NULL OR e.starts_at < v_before)
         AND (v_org IS NULL OR e.org_id = v_org)
         AND (v_like IS NULL OR e.name ILIKE v_like OR coalesce(e.venue_name, '') ILIKE v_like))
    SELECT jsonb_build_object(
             'rows', coalesce((SELECT jsonb_agg(public._exos_api_public_event_full(x.id) ORDER BY x.starts_at, x.id)
                                 FROM (SELECT id, starts_at FROM m ORDER BY starts_at, id LIMIT v_lim OFFSET v_off) x),
                              '[]'::jsonb),
             'total', (SELECT count(*) FROM m))
      INTO v_out;

  WHEN 'event.get' THEN
    IF coalesce(p_target, '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'exos_api_public: event not found' USING ERRCODE = 'P0002';
    END IF;
    v_out := public._exos_api_public_event_full(p_target::uuid);
    IF v_out IS NULL THEN RAISE EXCEPTION 'exos_api_public: event not found' USING ERRCODE = 'P0002'; END IF;

  WHEN 'venues.list' THEN
    -- Organizers with an upcoming published event (an empty account isn't a venue to discover).
    WITH m AS (
      SELECT o.id, o.name FROM public.exos_orgs o
       WHERE EXISTS (SELECT 1 FROM public.exos_events e WHERE e.org_id = o.id AND e.status = 'published'
                        AND coalesce(e.ends_at, e.starts_at) >= now())
         AND (v_like IS NULL OR o.name ILIKE v_like))
    SELECT jsonb_build_object(
             'rows', coalesce((SELECT jsonb_agg(public._exos_api_public_org_json(x.id) ORDER BY x.name, x.id)
                                 FROM (SELECT id, name FROM m ORDER BY name, id LIMIT v_lim OFFSET v_off) x), '[]'::jsonb),
             'total', (SELECT count(*) FROM m))
      INTO v_out;

  WHEN 'venue.get' THEN
    v_out := public._exos_api_public_org_json(v_org) || jsonb_build_object('upcoming_events',
      coalesce((SELECT jsonb_agg(public._exos_public_event_json(x.id) ORDER BY x.starts_at, x.id)
                  FROM (SELECT e.id, e.starts_at FROM public.exos_events e
                         WHERE e.org_id = v_org AND e.status = 'published' AND coalesce(e.ends_at, e.starts_at) >= now()
                         ORDER BY e.starts_at, e.id LIMIT 50) x), '[]'::jsonb));

  WHEN 'search' THEN
    v_out := jsonb_build_object(
      'events', coalesce((SELECT jsonb_agg(public._exos_public_event_json(x.id) ORDER BY x.starts_at, x.id)
                            FROM (SELECT e.id, e.starts_at FROM public.exos_events e
                                   WHERE e.status = 'published' AND coalesce(e.ends_at, e.starts_at) >= now()
                                     AND (e.name ILIKE v_like OR coalesce(e.venue_name, '') ILIKE v_like)
                                   ORDER BY e.starts_at, e.id LIMIT 20) x), '[]'::jsonb),
      'venues', coalesce((SELECT jsonb_agg(public._exos_api_public_org_json(x.id) ORDER BY x.name, x.id)
                            FROM (SELECT o.id, o.name FROM public.exos_orgs o
                                   WHERE o.name ILIKE v_like
                                     AND EXISTS (SELECT 1 FROM public.exos_events e WHERE e.org_id = o.id
                                                    AND e.status = 'published' AND coalesce(e.ends_at, e.starts_at) >= now())
                                   ORDER BY o.name, o.id LIMIT 20) x), '[]'::jsonb));

  WHEN 'series.list' THEN
    IF v_org IS NULL THEN
      RAISE EXCEPTION 'exos_api_public: venue_id (the organizer''s id or slug) is required' USING ERRCODE = '22023';
    END IF;
    v_out := public.exos_public_org_series((SELECT slug FROM public.exos_orgs WHERE id = v_org));

  WHEN 'series.get' THEN
    IF coalesce(p_target, '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'exos_api_public: series not found' USING ERRCODE = 'P0002';
    END IF;
    v_out := public.exos_public_series(p_target::uuid, coalesce((a->>'page')::int, 1), coalesce((a->>'per_page')::int, 20));
    IF v_out IS NULL THEN RAISE EXCEPTION 'exos_api_public: series not found' USING ERRCODE = 'P0002'; END IF;
  END CASE;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_public(text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_public(text, text, jsonb, text) TO service_role;

-- The same for an anonymous caller of the Data API: the network bucket is
-- the platform-set IP (_exos_request_ip_bucket), never one the caller names.
CREATE OR REPLACE FUNCTION public.exos_api_public(p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_api_public(p_action, p_target, p_args, 'ip:' || public._exos_request_ip_bucket())
$$;
REVOKE ALL ON FUNCTION public.exos_api_public(text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_api_public(text, text, jsonb) TO anon, authenticated, service_role;
