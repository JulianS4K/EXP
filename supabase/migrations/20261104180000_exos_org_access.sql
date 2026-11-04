-- ============================================================================
-- Organizer-controlled API permissions, venue booking requests with
-- event-scoped grants, and the partner presale setting (2026-11-04).
-- docs/org-access.md.
-- ============================================================================
-- Operator decisions:
--   1. "API permissions are organizer based, so a promoter has to go through
--      them if the venue already exists."
--      a. The org owner sets which API scopes each role's credentials may
--         carry, within a fixed ceiling per role.
--      b. An outside promoter can't put an event or a hold at a venue another
--         org owns on Exos; it sends that org a booking request, and the venue
--         org approves (a hold, or a draft event) and decides what the
--         promoter may do on that one event.
--   2. Partner presale: "allow both options". An org setting, overridable per
--      event: partners refused during a member presale (block, the default
--      and today's rule) or allowed (allow).
--
-- Touches:  C: TABLE exos_org_role_scopes (RLS: members read their org's;
--              writes through the owner's RPC only)
--           C: FUNCTION _exos_org_scope_vocab, exos_role_scope_ceiling,
--              _exos_org_role_scopes, _exos_scopes_for_role(text[], text, uuid, boolean),
--              _exos_api_key_scopes, exos_api_key_auth (service role),
--              exos_org_role_scopes_get / _set / _reset (authenticated;
--              set / reset: the org owner), _exos_org_role_scopes_set (service
--              role: exos-api), triggers _exos_tg_org_role_scopes,
--              _exos_tg_api_key_role_cap
--           W: FUNCTION exos_create_personal_token, exos_oauth_authorize_info,
--              exos_oauth_authorize_approve, exos_oauth_exchange_code,
--              exos_oauth_refresh, exos_oauth_introspect, exos_api_token_auth
--              (patched in place: a user token is narrowed to the org's
--              configured set for the user's role, not the fixed default)
--           W: FUNCTION exos_api_write, exos_api_commerce_write,
--              exos_api_order_write (patched: the scope check reads the key's
--              effective scopes, so a lowered role takes effect at once)
--           W: TABLE exos_venues (+ accepts_requests, listed_venue_id, verified)
--           C: TABLE exos_cohost_event_edits (RLS: both orgs' staff read)
--           C: TABLE exos_venue_requests, exos_event_partner_grants (RLS: staff
--              of either org read; writes through the functions only)
--           C: FUNCTION _exos_venue_gate, _exos_api_key_actor,
--              _exos_tg_venue_listing, _exos_venue_request_json,
--              _exos_venue_directory, _exos_venue_request_create,
--              _exos_venue_request_decide, _exos_venue_request_withdraw,
--              _exos_venue_requests_page, _exos_partner_grant_set,
--              _exos_partner_grant_revoke, _exos_partner_grants_list,
--              _exos_partner_grant_scopes, _exos_cohost_events,
--              _exos_cohost_event, _exos_cohost_event_update,
--              _exos_cohost_event_sales, _exos_venue_link_suggestions,
--              _exos_venue_link (service role: exos-api), their
--              signed-in wrappers exos_venue_directory,
--              exos_venue_request_create, exos_venue_request_decide,
--              exos_venue_request_withdraw, exos_venue_requests,
--              exos_venue_link_suggestions, exos_venue_link,
--              exos_partner_grant_set, exos_partner_grant_revoke,
--              exos_cohost_events (authenticated), trigger
--              _exos_tg_event_partner_grant, exos_event_partner_grant_vocab
--           R: FUNCTION _exos_tg_event_booking_links (CREATE OR REPLACE: the
--              20261030100000 body, plus the venue gate)
--           W: FUNCTION _exos_hold_add_position, _exos_tg_event_template
--              (patched: the venue gate before the "not in this organization"
--              check)
--           C: TABLE exos_org_partner_presale, exos_event_partner_presale
--              (RLS: staff read; writes through the functions)
--           C: FUNCTION _exos_partner_presale_mode, _exos_partner_presale_set,
--              _exos_partner_presale_get (service role),
--              exos_partner_presale_get / exos_partner_presale_set /
--              exos_event_partner_presale_set (authenticated)
--           W: FUNCTION _exos_partner_reserve (patched: the member-presale
--              refusal of 20261104130000 only when the mode is block)
-- Pre-reqs: 20261031130500 (developer platform), 20261101000000 (scope
--           union), 20261030100000 (booking), 20261102130000 (templates),
--           20261031110000 / 20261102100000 / 20261102140000 (API writes),
--           20261104130000 (partner presale refusal)
--
-- 1a. API permissions per role. Until now exos_role_token_scopes(role) was
--     the fixed most a user's token could carry, and an org API key carried
--     whatever its owner / manager creator chose. Now:
--       * exos_role_scope_ceiling(role) is the most a role can EVER be given,
--         from what its dashboard permissions allow (content never gets
--         finance or refunds; scanner stays door-only; only the owner has
--         org:admin). Must equal ROLE_SCOPE_CEILING in
--         supabase/functions/_shared/api/orgAccess.ts.
--       * exos_org_role_scopes holds the owner's choice per role, one set for
--         the role's keys and tokens alike. With no row, today's rules stay:
--         a user token gets exos_role_token_scopes(role), an org API key the
--         ceiling (until now a key was held only by its creator's dashboard
--         role, e.g. a finance member's key could refund). The owner's own
--         set is fixed (everything). User scopes (me:*, about the token's own
--         user) aren't org-configurable: tokens keep them as before.
--       * Every credential is narrowed at REQUEST time: a personal / OAuth
--         token to the user's live role's configured set; an org API key to
--         its creator's live role's configured set (exos_api_key_auth, and
--         the SQL scope checks of the API write functions). Lowering a role
--         takes effect on existing keys and tokens at once; raising it again
--         gives back what the key was created with, never more.
--       * Creating a key or token, or widening a key, is held to the caller's
--         configured set.
--     A key whose creator is no longer an active member (keys made before
--     the offboarding trigger) is treated as a manager's key.
--
-- 1b. Venues and promoters. A venue (exos_venues, #67) belongs to one org.
--     relationship 'owned' is a venue that org runs; 'rented' / 'partner' are
--     a promoter's own record of a room it doesn't own. Events link a venue
--     by exos_events.exos_venue_id (free-text venue_name / venue_location
--     remain labels, not ownership, and are not gated).
--       * The venue gate (_exos_venue_gate): an event, a hold night or an
--         event template of org B at org A's owned venue is refused with
--         "venue_approval_required: ..." (SQLSTATE 22023, as the "venue not
--         found in this organization" it replaces; exos-api answers 403 with
--         the request endpoint, by the message prefix). So is one at B's own rented / partner record of that
--         venue once B has linked it (listed_venue_id). Links are only ever
--         made by B, explicitly (exos_venue_link): `owned` is self-declared,
--         so a name match is a suggestion (_exos_venue_link_suggestions, all
--         candidates, with the staff-set `verified` flag), never a link. A
--         link B made can't be removed except by a platform admin.
--       * The request: B sends A a booking request for a date and room
--         (exos_venue_requests, like an inbound submission between two
--         orgs). A's owners / managers approve (a hold on A's calendar, or a
--         hold converted into a draft event of A) or decline; B may withdraw
--         while pending. One pending request per org, venue, room and date.
--       * The grant: approving names what B may do on that one event
--         (exos_event_partner_grants: events:read, events:write,
--         tickets:read, finance:read; default events:read, events:write,
--         tickets:read). It is created when the event is (now, or when A
--         converts the hold later). A changes or revokes it at any time; a
--         revoked grant stops B's next request. B's API calls on the event
--         need the scope in its own credential AND in the grant; money
--         (gross) needs finance:read in both, checked in SQL from the
--         credential's effective scopes. B's edits need a key whose creator
--         is an owner / manager of B now, and are logged
--         (exos_cohost_event_edits).
--       * Money: the event is A's, so it sells, refunds and settles exactly
--         as A's other events (#71's settlement rules; nothing here changes
--         payouts). A grant never carries refunds.
--
-- 2.  Partner presale. 20261104130000 refused a distribution partner's
--     reservation of a ticket type in a running member presale. That stays
--     the default ('block'); 'allow' lets partners sell it. The member gate
--     on Exos's own checkout (exos_member_checkout, per buyer) is unchanged
--     either way: a partner's buyer is not a member, so no member price.
--
-- Errors: 22023 bad input, P0002 not found, 23505 / 55000 / 54000 conflict or
-- limit, 42501 not allowed (22023 "venue_approval_required: ..." for the
-- venue gate). Additive only;
-- re-run safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked patches with
-- pg_temp.exos_patch_n). Nothing is granted to anon. Prod apply needs
-- operator OK.
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

-- ===========================================================================
-- 1a. API permissions per role
-- ===========================================================================

-- The org-configurable scopes: the vocabulary without the user scopes (me:*).
CREATE OR REPLACE FUNCTION public._exos_org_scope_vocab()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(array_agg(n ORDER BY i), '{}')
    FROM unnest(public.exos_api_scope_names()) WITH ORDINALITY v(n, i)
   WHERE n NOT LIKE 'me:%'
$$;
REVOKE ALL ON FUNCTION public._exos_org_scope_vocab() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_org_scope_vocab() TO service_role;

-- The most a role can ever be given, from its dashboard permissions. Must
-- equal ROLE_SCOPE_CEILING in supabase/functions/_shared/api/orgAccess.ts
-- (src/lib/orgAccess.test.ts reads this definition).
--   manager: everything but org:admin (managers run events, orders, refunds,
--            fans, the door, booking, finance, commerce and webhooks)
--   finance: reads, refunds, finance (no event, ticket, door or booking edits)
--   content: event content and booking reads (never orders, finance, refunds)
--   scanner: the door only
CREATE OR REPLACE FUNCTION public.exos_role_scope_ceiling(p_role text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE p_role
    WHEN 'owner' THEN ARRAY['events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write',
                            'tickets:read', 'tickets:write', 'checkin:write', 'booking:read', 'booking:write',
                            'finance:read', 'finance:write', 'commerce:read', 'commerce:write', 'webhooks:read',
                            'webhooks:write', 'org:admin']
    WHEN 'manager' THEN ARRAY['events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write',
                              'tickets:read', 'tickets:write', 'checkin:write', 'booking:read', 'booking:write',
                              'finance:read', 'finance:write', 'commerce:read', 'commerce:write', 'webhooks:read',
                              'webhooks:write']
    WHEN 'finance' THEN ARRAY['events:read', 'orders:read', 'refunds:write', 'fans:read', 'tickets:read', 'booking:read',
                              'finance:read', 'finance:write', 'commerce:read']
    WHEN 'content' THEN ARRAY['events:read', 'events:write', 'booking:read']
    WHEN 'scanner' THEN ARRAY['events:read', 'tickets:read', 'checkin:write']
    ELSE ARRAY[]::text[]
  END
$$;
REVOKE ALL ON FUNCTION public.exos_role_scope_ceiling(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_role_scope_ceiling(text) TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.exos_org_role_scopes (
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('manager', 'finance', 'content', 'scanner')),
  scopes     text[] NOT NULL DEFAULT '{}',
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, role)
);
COMMENT ON TABLE public.exos_org_role_scopes IS
  'mig 20261104180000: the API scopes the owner lets each role''s keys and tokens carry (no row: tokens exos_role_token_scopes, keys the ceiling, as before). Always within exos_role_scope_ceiling.';

-- Rows: known org scopes only, inside the role's ceiling, vocabulary order.
CREATE OR REPLACE FUNCTION public._exos_tg_org_role_scopes()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_bad text;
BEGIN
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
DROP TRIGGER IF EXISTS exos_org_role_scopes_guard ON public.exos_org_role_scopes;
CREATE TRIGGER exos_org_role_scopes_guard BEFORE INSERT OR UPDATE ON public.exos_org_role_scopes
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_org_role_scopes();
DROP TRIGGER IF EXISTS exos_org_role_scopes_touch ON public.exos_org_role_scopes;
CREATE TRIGGER exos_org_role_scopes_touch BEFORE UPDATE ON public.exos_org_role_scopes
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_org_role_scopes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_org_role_scopes_sel ON public.exos_org_role_scopes;
CREATE POLICY exos_org_role_scopes_sel ON public.exos_org_role_scopes FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance', 'content', 'scanner']));
REVOKE ALL ON public.exos_org_role_scopes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_org_role_scopes TO authenticated;
GRANT ALL ON public.exos_org_role_scopes TO service_role;

-- What a role's credentials may carry in an org right now, in vocabulary
-- order: the owner's choice inside the ceiling. With no choice, today's rule
-- for that kind of credential: a user token exos_role_token_scopes(role), an
-- org API key the ceiling (keys were held only by the creator's dashboard
-- role until now). User scopes (me:*) follow exos_role_token_scopes for
-- tokens and are never a key's.
CREATE OR REPLACE FUNCTION public._exos_org_role_scopes(p_org_id uuid, p_role text, p_for_key boolean DEFAULT false)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH cfg AS (
    SELECT (SELECT r.scopes FROM public.exos_org_role_scopes r WHERE r.org_id = p_org_id AND r.role = p_role) AS scopes
  )
  SELECT coalesce(array_agg(n ORDER BY i), '{}')
    FROM unnest(public.exos_api_scope_names()) WITH ORDINALITY v(n, i), cfg
   WHERE CASE
           WHEN NOT (n = ANY (public._exos_org_scope_vocab()))
             THEN NOT coalesce(p_for_key, false) AND n = ANY (public.exos_role_token_scopes(p_role))
           ELSE n = ANY (public.exos_role_scope_ceiling(p_role))
            AND n = ANY (CASE
                  WHEN p_role <> 'owner' AND p_org_id IS NOT NULL AND cfg.scopes IS NOT NULL THEN cfg.scopes
                  WHEN coalesce(p_for_key, false) THEN public.exos_role_scope_ceiling(p_role)
                  ELSE public.exos_role_token_scopes(p_role) END)
         END
$$;
REVOKE ALL ON FUNCTION public._exos_org_role_scopes(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_org_role_scopes(uuid, text, boolean) TO service_role;

-- _exos_scopes_for_role (mig 20261031130500) with the org's configured set:
-- kept when the role may use it there; a :write it lacks still gives the
-- :read when the role has that.
-- (Tokens; p_for_key for an org API key.)
CREATE OR REPLACE FUNCTION public._exos_scopes_for_role(p_scopes text[], p_role text, p_org_id uuid,
                                                        p_for_key boolean DEFAULT false)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(array_agg(n ORDER BY i), '{}')
    FROM unnest(public.exos_api_scope_names()) WITH ORDINALITY v(n, i)
   WHERE n = ANY (public._exos_org_role_scopes(p_org_id, p_role, p_for_key))
     AND (n = ANY (coalesce(p_scopes, '{}'))
          OR (n LIKE '%:read' AND replace(n, ':read', ':write') = ANY (coalesce(p_scopes, '{}'))))
$$;
REVOKE ALL ON FUNCTION public._exos_scopes_for_role(text[], text, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_scopes_for_role(text[], text, uuid, boolean) TO service_role;

-- An org API key's scopes now: what it was created with (the legacy `read`
-- standing for every org :read), narrowed to its creator's live role's set
-- (a creator who is no longer an active member: the manager set). Empty for
-- an unknown or revoked key.
CREATE OR REPLACE FUNCTION public._exos_api_key_scopes(p_key_id uuid)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((
    SELECT public._exos_scopes_for_role(
             k.scopes || CASE WHEN 'read' = ANY (k.scopes)
                              THEN ARRAY(SELECT n FROM unnest(public._exos_org_scope_vocab()) n WHERE n LIKE '%:read')
                              ELSE '{}'::text[] END,
             coalesce(public._exos_member_role(k.org_id, k.created_by), 'manager'), k.org_id, true)
      FROM public.exos_api_keys k WHERE k.id = p_key_id AND k.revoked_at IS NULL), '{}')
$$;
REVOKE ALL ON FUNCTION public._exos_api_key_scopes(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_key_scopes(uuid) TO service_role;

-- exos-api / exos-mcp: an org API key by the SHA-256 of its plaintext.
-- NULL: unknown or revoked (401). Else { id, org_id, name, key_prefix,
-- scopes (effective now), key_scopes (as stored), creator_role }.
CREATE OR REPLACE FUNCTION public.exos_api_key_auth(p_hash text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', k.id, 'org_id', k.org_id, 'name', k.name, 'key_prefix', k.key_prefix,
           'scopes', to_jsonb(public._exos_api_key_scopes(k.id)), 'key_scopes', to_jsonb(k.scopes),
           'creator_role', public._exos_member_role(k.org_id, k.created_by))
    FROM public.exos_api_keys k
   WHERE p_hash ~ '^[0-9a-f]{64}$' AND k.key_hash = p_hash AND k.revoked_at IS NULL
$$;
REVOKE ALL ON FUNCTION public.exos_api_key_auth(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_key_auth(text) TO service_role;

-- A key is created (or widened) within its maker's set. The legacy `read`
-- and user scopes are left to their own rules; a widening is checked for
-- the scopes it adds, so a narrowed key can still be edited.
CREATE OR REPLACE FUNCTION public._exos_tg_api_key_role_cap()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor uuid; v_role text; v_bad text;
BEGIN
  v_actor := auth.uid();   -- a signed-in maker (exos_create_api_key / exos_set_api_key_scopes); service-role writes are narrowed at use
  IF v_actor IS NULL THEN RETURN NEW; END IF;
  v_role := public._exos_member_role(NEW.org_id, v_actor);
  IF v_role IS NULL THEN RETURN NEW; END IF;   -- the creating RPC decides who may
  SELECT s INTO v_bad FROM unnest(NEW.scopes) s
   WHERE s = ANY (public._exos_org_scope_vocab())
     AND (TG_OP = 'INSERT' OR NOT (s = ANY (OLD.scopes)))
     AND NOT (s = ANY (public._exos_scopes_for_role(ARRAY[s], v_role, NEW.org_id, true)))
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'your role (%) can''t give a key % in this organization (Settings, API permissions)', v_role, v_bad
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_api_key_role_cap() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_api_keys_role_cap ON public.exos_api_keys;
CREATE TRIGGER exos_api_keys_role_cap BEFORE INSERT OR UPDATE OF scopes ON public.exos_api_keys
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_api_key_role_cap();

-- The settings page: each role's default, ceiling, the owner's choice and
-- what applies now. Any active member reads; `editable` for the owner.
CREATE OR REPLACE FUNCTION public.exos_org_role_scopes_get(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin()
       OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance', 'content', 'scanner'])) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_org_role_scopes_view(p_org_id) ||
         jsonb_build_object('editable', public.exos_has_org_role(p_org_id, ARRAY['owner']));
END $$;

CREATE OR REPLACE FUNCTION public._exos_org_role_scopes_view(p_org_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'scopes', to_jsonb(public._exos_org_scope_vocab()),
    'roles', (SELECT jsonb_agg(jsonb_build_object(
        'role', r.role,
        'configurable', r.role <> 'owner',
        'default', to_jsonb(ARRAY(SELECT s FROM unnest(public.exos_role_token_scopes(r.role)) s
                                   WHERE s = ANY (public._exos_org_scope_vocab()))),
        'ceiling', to_jsonb(public.exos_role_scope_ceiling(r.role)),
        'configured', (SELECT to_jsonb(c.scopes) FROM public.exos_org_role_scopes c
                        WHERE c.org_id = p_org_id AND c.role = r.role),
        'effective', to_jsonb(ARRAY(SELECT s FROM unnest(public._exos_org_role_scopes(p_org_id, r.role)) s
                                     WHERE s = ANY (public._exos_org_scope_vocab()))),
        'key_default', to_jsonb(public.exos_role_scope_ceiling(r.role)),
        'key_effective', to_jsonb(public._exos_org_role_scopes(p_org_id, r.role, true)),
        'updated_at', (SELECT c.updated_at FROM public.exos_org_role_scopes c
                        WHERE c.org_id = p_org_id AND c.role = r.role)) ORDER BY r.n)
      FROM unnest(ARRAY['owner', 'manager', 'finance', 'content', 'scanner']) WITH ORDINALITY r(role, n)))
$$;
REVOKE ALL ON FUNCTION public._exos_org_role_scopes_view(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_org_role_scopes_view(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.exos_org_role_scopes_get(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_role_scopes_get(uuid) TO authenticated;

-- Core (service role: exos-api checks the caller is the owner). p_scopes
-- NULL: back to the default.
CREATE OR REPLACE FUNCTION public._exos_org_role_scopes_set(p_org_id uuid, p_actor uuid, p_role text, p_scopes text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_role IS NULL OR p_role NOT IN ('manager', 'finance', 'content', 'scanner') THEN
    RAISE EXCEPTION 'role must be manager, finance, content or scanner (the owner always has every scope)'
      USING ERRCODE = '22023';
  END IF;
  IF p_scopes IS NULL THEN
    DELETE FROM public.exos_org_role_scopes WHERE org_id = p_org_id AND role = p_role;
  ELSE
    IF cardinality(p_scopes) > 40 THEN RAISE EXCEPTION 'too many scopes' USING ERRCODE = '22023'; END IF;
    INSERT INTO public.exos_org_role_scopes (org_id, role, scopes, updated_by)
    VALUES (p_org_id, p_role, p_scopes, p_actor)
    ON CONFLICT (org_id, role) DO UPDATE SET scopes = EXCLUDED.scopes, updated_by = EXCLUDED.updated_by;
  END IF;
  RETURN public._exos_org_role_scopes_view(p_org_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_org_role_scopes_set(uuid, uuid, text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_org_role_scopes_set(uuid, uuid, text, text[]) TO service_role;

-- The owner only (not managers, not platform admins acting for the org).
CREATE OR REPLACE FUNCTION public.exos_org_role_scopes_set(p_org_id uuid, p_role text, p_scopes text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'only the organization owner can change API permissions' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_org_role_scopes_set(p_org_id, auth.uid(), p_role, coalesce(p_scopes, '{}'::text[]))
         || jsonb_build_object('editable', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_role_scopes_set(uuid, text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_role_scopes_set(uuid, text, text[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_org_role_scopes_reset(p_org_id uuid, p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'only the organization owner can change API permissions' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_org_role_scopes_set(p_org_id, auth.uid(), p_role, NULL) || jsonb_build_object('editable', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_role_scopes_reset(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_role_scopes_reset(uuid, text) TO authenticated;

-- ---- Personal and OAuth tokens: the org's set, not the fixed default -------
SELECT pg_temp.exos_patch_n('public.exos_create_personal_token(uuid, text, text[], integer)',
  'ARRAY[s], v_role, p_org_id)',
  'public._exos_scopes_for_role(ARRAY[s], v_role)', 'public._exos_scopes_for_role(ARRAY[s], v_role, p_org_id)', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_authorize_info(text, text, text)',
  '(v_req, m.role, m.org_id)',
  'public._exos_scopes_for_role(v_req, m.role)', 'public._exos_scopes_for_role(v_req, m.role, m.org_id)', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_authorize_approve(text, text, text, uuid, text, text, text)',
  '''scopes'')), v_role, p_org_id)',
  'jsonb_array_elements_text(v_info->''scopes'')), v_role)',
  'jsonb_array_elements_text(v_info->''scopes'')), v_role, p_org_id)', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_exchange_code(text, text, text, text, text)',
  '(c.scopes, v_role, c.org_id)',
  'public._exos_scopes_for_role(c.scopes, v_role)', 'public._exos_scopes_for_role(c.scopes, v_role, c.org_id)', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_refresh(text, text, text, text[])',
  '(v_scopes, v_role, t.org_id)',
  'public._exos_scopes_for_role(v_scopes, v_role)', 'public._exos_scopes_for_role(v_scopes, v_role, t.org_id)', 1);
SELECT pg_temp.exos_patch_n('public.exos_oauth_introspect(text, text, text)',
  '(t.scopes, v_role, t.org_id)',
  'public._exos_scopes_for_role(t.scopes, v_role)', 'public._exos_scopes_for_role(t.scopes, v_role, t.org_id)', 1);
SELECT pg_temp.exos_patch_n('public.exos_api_token_auth(text, text)',
  '(p.scopes, v_role, p.org_id)',
  'public._exos_scopes_for_role(p.scopes, v_role)', 'public._exos_scopes_for_role(p.scopes, v_role, p.org_id)', 1);
SELECT pg_temp.exos_patch_n('public.exos_api_token_auth(text, text)',
  '(t.scopes, v_role, t.org_id)',
  'public._exos_scopes_for_role(t.scopes, v_role)', 'public._exos_scopes_for_role(t.scopes, v_role, t.org_id)', 1);

-- ---- API key writes in SQL: the key's scopes now, not as stored -----------
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)',
  '_exos_api_key_scopes(k.id)',
  'public._exos_api_has_scope(k.scopes, v_scope)', 'public._exos_api_has_scope(public._exos_api_key_scopes(k.id), v_scope)', 1);
SELECT pg_temp.exos_patch_n('public.exos_api_commerce_write(uuid, text, text, jsonb, text)',
  '_exos_api_key_scopes(k.id)',
  'public._exos_api_has_scope(k.scopes, v_scope)', 'public._exos_api_has_scope(public._exos_api_key_scopes(k.id), v_scope)', 1);
SELECT pg_temp.exos_patch_n('public.exos_api_order_write(uuid, text, text, jsonb, text)',
  '_exos_api_key_scopes(k.id)',
  'public._exos_api_has_scope(k.scopes, v_scope)', 'public._exos_api_has_scope(public._exos_api_key_scopes(k.id), v_scope)', 1);

-- ===========================================================================
-- 1b. Venues, booking requests, event-scoped grants
-- ===========================================================================
ALTER TABLE public.exos_venues ADD COLUMN IF NOT EXISTS accepts_requests boolean NOT NULL DEFAULT true;
ALTER TABLE public.exos_venues ADD COLUMN IF NOT EXISTS listed_venue_id uuid REFERENCES public.exos_venues (id) ON DELETE SET NULL;
ALTER TABLE public.exos_venues ADD COLUMN IF NOT EXISTS verified boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS exos_venues_listed_idx ON public.exos_venues (listed_venue_id) WHERE listed_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_venues_owned_name_idx ON public.exos_venues (lower(btrim(name))) WHERE relationship = 'owned';
COMMENT ON COLUMN public.exos_venues.accepts_requests IS
  'mig 20261104180000: an owned venue other orgs may send booking requests to (exos_venue_requests).';
COMMENT ON COLUMN public.exos_venues.listed_venue_id IS
  'mig 20261104180000: this rented / partner record is another org''s owned venue (linked by its own org, never automatically); events and holds here need that org''s approval.';
COMMENT ON COLUMN public.exos_venues.verified IS
  'mig 20261104180000: Exos staff checked the org runs this venue. Shown in suggestions and the directory; the venue gate does not require it.';

-- The venue gate: may org p_org put an event / hold night / template at
-- p_venue on its own? Another org's owned venue, or this org's record linked
-- to one, needs that org's approval (22023 venue_approval_required). Anything else passes here (the
-- callers' own checks still refuse a venue of another org).
CREATE OR REPLACE FUNCTION public._exos_venue_gate(p_org uuid, p_venue uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v public.exos_venues%ROWTYPE; v_target uuid;
BEGIN
  IF p_venue IS NULL THEN RETURN; END IF;
  SELECT * INTO v FROM public.exos_venues WHERE id = p_venue;
  IF NOT FOUND THEN RETURN; END IF;
  IF v.org_id IS DISTINCT FROM p_org THEN
    IF v.relationship <> 'owned' THEN RETURN; END IF;
    v_target := v.id;
  ELSIF v.listed_venue_id IS NOT NULL THEN
    v_target := v.listed_venue_id;
  ELSE
    RETURN;
  END IF;
  RAISE EXCEPTION 'venue_approval_required: this venue is run by another organization on Exos; send it a booking request (POST /v1/venue-requests with venue_id %)', v_target
    USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_gate(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_gate(uuid, uuid) TO service_role;

-- 20261030100000's event link check, with the gate first.
CREATE OR REPLACE FUNCTION public._exos_tg_event_booking_links()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.exos_venue_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.exos_venue_id IS DISTINCT FROM OLD.exos_venue_id) THEN
    PERFORM public._exos_venue_gate(NEW.org_id, NEW.exos_venue_id);   -- mig 20261104180000
  END IF;
  IF NEW.exos_venue_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.exos_venue_id IS DISTINCT FROM OLD.exos_venue_id OR NEW.exos_room_id IS DISTINCT FROM OLD.exos_room_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_venues v WHERE v.id = NEW.exos_venue_id AND v.org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'exos_events: venue not found in this organization' USING ERRCODE = '22023';
  END IF;
  IF NEW.exos_room_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.exos_room_id IS DISTINCT FROM OLD.exos_room_id OR NEW.exos_venue_id IS DISTINCT FROM OLD.exos_venue_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_venue_rooms r WHERE r.id = NEW.exos_room_id AND r.venue_id = NEW.exos_venue_id) THEN
    RAISE EXCEPTION 'exos_events: room not found in that venue' USING ERRCODE = '22023';
  END IF;
  IF coalesce(current_setting('exos.booking_convert', true), '') <> 'on' THEN
    IF TG_OP = 'INSERT' THEN
      -- A copy of a converted event (a series date, a duplicate) is not the
      -- night it came from: it starts without the hold links.
      NEW.hold_id := NULL;
      NEW.hold_position_id := NULL;
    ELSIF (NEW.hold_id IS DISTINCT FROM OLD.hold_id OR NEW.hold_position_id IS DISTINCT FROM OLD.hold_position_id)
          AND (NEW.hold_id IS NOT NULL OR NEW.hold_position_id IS NOT NULL) THEN
      RAISE EXCEPTION 'exos_events: hold links are set by converting a hold' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_booking_links() FROM PUBLIC, anon, authenticated;

-- Hold nights: the gate before "venue not found in this organization".
SELECT pg_temp.exos_patch_n('public._exos_hold_add_position(uuid, uuid, jsonb, text)',
  '/* exos: venue gate */',
  $o$  v_venue := public._exos_uuid(p->>'venue_id', p_label || '.venue_id');$o$,
  $n$  v_venue := public._exos_uuid(p->>'venue_id', p_label || '.venue_id');
  /* exos: venue gate */ PERFORM public._exos_venue_gate(p_org, v_venue);   -- mig 20261104180000$n$, 1);

-- Event templates naming a venue: the same.
SELECT pg_temp.exos_patch_n('public._exos_tg_event_template()',
  '/* exos: venue gate */',
  $o$  IF NEW.event_fields ? 'exos_venue_id' AND jsonb_typeof(NEW.event_fields -> 'exos_venue_id') = 'string'
     AND NOT EXISTS$o$,
  $n$  /* exos: venue gate */ -- mig 20261104180000
  IF NEW.event_fields ? 'exos_venue_id' AND jsonb_typeof(NEW.event_fields -> 'exos_venue_id') = 'string'
     AND (NEW.event_fields ->> 'exos_venue_id') ~ '^[0-9a-fA-F-]{36}$' THEN
    PERFORM public._exos_venue_gate(NEW.org_id, (NEW.event_fields ->> 'exos_venue_id')::uuid);
  END IF;
  IF NEW.event_fields ? 'exos_venue_id' AND jsonb_typeof(NEW.event_fields -> 'exos_venue_id') = 'string'
     AND NOT EXISTS$n$, 1);

-- Links are never made for an org: anyone can call a venue `owned`, so a
-- name match proves nothing (a squatter's "Elsewhere, Brooklyn" must not
-- capture other promoters' records). A promoter org links its own rented /
-- partner record to another org's owned venue explicitly (exos_venue_link,
-- or the column through RLS); _exos_venue_link_suggestions lists candidates,
-- ambiguous ones included, with `verified`. Once a promoter has linked, the
-- link stays (a platform admin may clear it), so it can't be dropped to get
-- around the gate. `verified` is set by platform admins (or the service
-- role) only and is shown, never required.
CREATE OR REPLACE FUNCTION public._exos_tg_venue_listing()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF (TG_OP = 'INSERT' AND NEW.verified) OR (TG_OP = 'UPDATE' AND NEW.verified IS DISTINCT FROM OLD.verified) THEN
    IF NOT (public.exos_is_admin() OR public._exos_caller_is_service()) THEN
      RAISE EXCEPTION 'only Exos staff verify a venue' USING ERRCODE = '42501';
    END IF;
  END IF;
  -- Verification is of this name, place, relationship and org: an org's own
  -- edit of any of them drops it (staff verify again).
  IF TG_OP = 'UPDATE' AND NEW.verified
     AND (NEW.name IS DISTINCT FROM OLD.name OR NEW.address IS DISTINCT FROM OLD.address
          OR NEW.relationship IS DISTINCT FROM OLD.relationship OR NEW.org_id IS DISTINCT FROM OLD.org_id)
     AND NOT (public.exos_is_admin() OR public._exos_caller_is_service()) THEN
    NEW.verified := false;
  END IF;
  -- (The owned venue being deleted clears it: ON DELETE SET NULL.)
  IF TG_OP = 'UPDATE' AND OLD.listed_venue_id IS NOT NULL AND NEW.listed_venue_id IS DISTINCT FROM OLD.listed_venue_id
     AND EXISTS (SELECT 1 FROM public.exos_venues v WHERE v.id = OLD.listed_venue_id)
     AND NOT public.exos_is_admin() THEN
    RAISE EXCEPTION 'this venue is linked to a venue another organization runs on Exos; the link stays'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.listed_venue_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.listed_venue_id IS DISTINCT FROM OLD.listed_venue_id) THEN
    IF NEW.relationship NOT IN ('rented', 'partner') THEN
      RAISE EXCEPTION 'only a rented or partner venue can be linked to a venue another organization runs'
        USING ERRCODE = '22023';
    END IF;
    -- Only a venue the directory shows (owned elsewhere, taking requests);
    -- anything else is the same refusal, so nothing is revealed about it.
    IF NOT EXISTS (SELECT 1 FROM public.exos_venues v
                    WHERE v.id = NEW.listed_venue_id AND v.org_id <> NEW.org_id AND v.relationship = 'owned'
                      AND v.accepts_requests) THEN
      RAISE EXCEPTION 'listed_venue_id must be a venue another organization runs on Exos that takes booking requests'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_venue_listing() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_venues_listing ON public.exos_venues;
CREATE TRIGGER exos_venues_listing BEFORE INSERT OR UPDATE ON public.exos_venues
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_venue_listing();

-- Owned venues of other orgs that may be the same place as this org's
-- rented / partner record (same name and city, case and spaces aside), each
-- with `verified`. Only venues the directory shows (taking requests). Every
-- candidate is listed: two matches are never decided for the promoter.
CREATE OR REPLACE FUNCTION public._exos_venue_link_suggestions(p_org uuid, p_venue uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_venues%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_venues WHERE id = p_venue AND org_id = p_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'venue not found' USING ERRCODE = 'P0002'; END IF;
  RETURN jsonb_build_object('venue_id', r.id, 'listed_venue_id', r.listed_venue_id, 'suggestions', coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'city', v.address ->> 'city',
             'region', v.address ->> 'region', 'verified', v.verified, 'accepts_requests', v.accepts_requests,
             'org', jsonb_build_object('id', o.id, 'name', o.name)) ORDER BY v.verified DESC, o.name, v.id)
      FROM public.exos_venues v JOIN public.exos_orgs o ON o.id = v.org_id
     WHERE r.relationship IN ('rented', 'partner') AND v.relationship = 'owned' AND v.accepts_requests
       AND v.org_id <> p_org
       AND lower(btrim(v.name)) = lower(btrim(r.name))
       AND lower(btrim(coalesce(v.address ->> 'city', ''))) = lower(btrim(coalesce(r.address ->> 'city', '')))
       AND btrim(coalesce(r.address ->> 'city', '')) <> ''), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_link_suggestions(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_link_suggestions(uuid, uuid) TO service_role;

-- The promoter org links its record (the trigger checks the target and keeps
-- the link). Returns the suggestions view.
CREATE OR REPLACE FUNCTION public._exos_venue_link(p_org uuid, p_venue uuid, p_listed uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_listed IS NULL THEN RAISE EXCEPTION 'listed_venue_id is required' USING ERRCODE = '22023'; END IF;
  UPDATE public.exos_venues SET listed_venue_id = p_listed WHERE id = p_venue AND org_id = p_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'venue not found' USING ERRCODE = 'P0002'; END IF;
  RETURN public._exos_venue_link_suggestions(p_org, p_venue);
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_link(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_link(uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_venue_link_suggestions(p_venue_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_venues WHERE id = p_venue_id);
BEGIN
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'content']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_venue_link_suggestions(v_org, p_venue_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_venue_link_suggestions(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_venue_link_suggestions(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_venue_link(p_venue_id uuid, p_listed_venue_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_venues WHERE id = p_venue_id);
BEGIN
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_venue_link(v_org, p_venue_id, p_listed_venue_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_venue_link(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_venue_link(uuid, uuid) TO authenticated;

-- An org API key's creator, when they hold one of p_roles in the key's org
-- now (as staffActor in exos-api/templates.ts); else 42501.
CREATE OR REPLACE FUNCTION public._exos_api_key_actor(p_org uuid, p_api_key uuid, p_roles text[])
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid;
BEGIN
  SELECT k.created_by INTO v_uid FROM public.exos_api_keys k
   WHERE k.id = p_api_key AND k.org_id = p_org AND k.revoked_at IS NULL;
  IF v_uid IS NULL OR NOT (public._exos_member_role(p_org, v_uid) = ANY (p_roles)) THEN
    RAISE EXCEPTION 'only a key created by an organization % can do this', array_to_string(p_roles, ' or ')
      USING ERRCODE = '42501';
  END IF;
  RETURN v_uid;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_key_actor(uuid, uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_key_actor(uuid, uuid, text[]) TO service_role;

-- What a venue org may let a promoter do on one event. Refunds are never
-- delegated: the event is the venue org's and its money stays there.
CREATE OR REPLACE FUNCTION public.exos_event_partner_grant_vocab()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT ARRAY['events:read', 'events:write', 'tickets:read', 'finance:read']::text[]
$$;
REVOKE ALL ON FUNCTION public.exos_event_partner_grant_vocab() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_partner_grant_vocab() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._exos_grant_clean_scopes(p jsonb)
RETURNS text[] LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE v text[]; v_bad text;
BEGIN
  IF p IS NULL OR p = 'null'::jsonb THEN
    RETURN ARRAY['events:read', 'events:write', 'tickets:read'];
  END IF;
  IF jsonb_typeof(p) <> 'array' OR EXISTS (SELECT 1 FROM jsonb_array_elements(p) x WHERE jsonb_typeof(x) <> 'string') THEN
    RAISE EXCEPTION 'scopes must be a list of scope names' USING ERRCODE = '22023';
  END IF;
  v := ARRAY(SELECT jsonb_array_elements_text(p));
  SELECT s INTO v_bad FROM unnest(v) s WHERE NOT (s = ANY (public.exos_event_partner_grant_vocab())) LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'a promoter can be given only % on an event, not %',
      array_to_string(public.exos_event_partner_grant_vocab(), ', '), left(v_bad, 40) USING ERRCODE = '22023';
  END IF;
  -- events:write implies events:read.
  IF 'events:write' = ANY (v) THEN v := v || 'events:read'::text; END IF;
  v := ARRAY(SELECT n FROM unnest(public.exos_event_partner_grant_vocab()) WITH ORDINALITY x(n, i) WHERE n = ANY (v) ORDER BY i);
  IF cardinality(v) = 0 THEN RAISE EXCEPTION 'give at least one scope (or revoke the grant)' USING ERRCODE = '22023'; END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_grant_clean_scopes(jsonb) FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.exos_venue_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,   -- the venue's org (decides)
  venue_id         uuid NOT NULL,
  room_id          uuid REFERENCES public.exos_venue_rooms (id) ON DELETE SET NULL,
  requester_org_id uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  date             date NOT NULL,
  start_time       time,
  title            text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 100),
  message          text NOT NULL DEFAULT '' CHECK (char_length(message) <= 2000),
  expected_draw    integer CHECK (expected_draw IS NULL OR expected_draw BETWEEN 0 AND 1000000),
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'declined', 'withdrawn')),
  outcome          text CHECK (outcome IS NULL OR outcome IN ('hold', 'event')),
  grant_scopes     text[],
  hold_id          uuid REFERENCES public.exos_holds (id) ON DELETE SET NULL,
  event_id         uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  decline_reason   text CHECK (decline_reason IS NULL OR char_length(decline_reason) <= 500),
  decided_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  decided_at       timestamptz,
  created_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_via      text NOT NULL DEFAULT 'dashboard' CHECK (created_via IN ('dashboard', 'api')),
  api_key_id       uuid,
  idempotency_key  text CHECK (idempotency_key IS NULL OR idempotency_key ~ '^[A-Za-z0-9_.:-]{8,100}$'),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (venue_id, org_id) REFERENCES public.exos_venues (id, org_id) ON DELETE CASCADE,
  CHECK (requester_org_id <> org_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_venue_requests_one_pending
  ON public.exos_venue_requests (requester_org_id, venue_id, coalesce(room_id, '00000000-0000-0000-0000-000000000000'::uuid), date)
  WHERE status = 'pending';
CREATE UNIQUE INDEX IF NOT EXISTS exos_venue_requests_idem
  ON public.exos_venue_requests (requester_org_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_venue_requests_org_idx ON public.exos_venue_requests (org_id, status, date);
CREATE INDEX IF NOT EXISTS exos_venue_requests_requester_idx ON public.exos_venue_requests (requester_org_id, status, date);
CREATE INDEX IF NOT EXISTS exos_venue_requests_hold_idx ON public.exos_venue_requests (hold_id) WHERE hold_id IS NOT NULL;
DROP TRIGGER IF EXISTS exos_venue_requests_touch ON public.exos_venue_requests;
CREATE TRIGGER exos_venue_requests_touch BEFORE UPDATE ON public.exos_venue_requests
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_venue_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_venue_requests_sel ON public.exos_venue_requests;
CREATE POLICY exos_venue_requests_sel ON public.exos_venue_requests FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content'])
         OR public.exos_has_org_role(requester_org_id, ARRAY['owner', 'manager', 'content']));
REVOKE ALL ON public.exos_venue_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_venue_requests TO authenticated;
GRANT ALL ON public.exos_venue_requests TO service_role;
COMMENT ON TABLE public.exos_venue_requests IS
  'mig 20261104180000: a promoter org asks a venue org for a date (and room) at a venue it runs. Written only by _exos_venue_request_*.';

CREATE TABLE IF NOT EXISTS public.exos_event_partner_grants (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,   -- the event's org
  event_id       uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  grantee_org_id uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  request_id     uuid REFERENCES public.exos_venue_requests (id) ON DELETE SET NULL,
  scopes         text[] NOT NULL CHECK (cardinality(scopes) >= 1),
  granted_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  revoked_at     timestamptz,
  revoked_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (grantee_org_id <> org_id),
  CHECK (scopes <@ ARRAY['events:read', 'events:write', 'tickets:read', 'finance:read']::text[])
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_event_partner_grants_one_live
  ON public.exos_event_partner_grants (event_id, grantee_org_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_event_partner_grants_grantee_idx
  ON public.exos_event_partner_grants (grantee_org_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_event_partner_grants_org_idx ON public.exos_event_partner_grants (org_id, created_at DESC);
DROP TRIGGER IF EXISTS exos_event_partner_grants_touch ON public.exos_event_partner_grants;
CREATE TRIGGER exos_event_partner_grants_touch BEFORE UPDATE ON public.exos_event_partner_grants
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_event_partner_grants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_event_partner_grants_sel ON public.exos_event_partner_grants;
CREATE POLICY exos_event_partner_grants_sel ON public.exos_event_partner_grants FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content'])
         OR public.exos_has_org_role(grantee_org_id, ARRAY['owner', 'manager', 'content']));
REVOKE ALL ON public.exos_event_partner_grants FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_event_partner_grants TO authenticated;
GRANT ALL ON public.exos_event_partner_grants TO service_role;
COMMENT ON TABLE public.exos_event_partner_grants IS
  'mig 20261104180000: what a promoter org may do on one event of a venue org (from an approved venue request). Revoked: refused at once.';

-- An approved request's hold becomes an event (now or later): the grant.
CREATE OR REPLACE FUNCTION public._exos_tg_event_partner_grant()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_venue_requests%ROWTYPE;
BEGIN
  FOR r IN SELECT * FROM public.exos_venue_requests
            WHERE hold_id = NEW.hold_id AND org_id = NEW.org_id AND status = 'approved' LOOP
    INSERT INTO public.exos_event_partner_grants (org_id, event_id, grantee_org_id, request_id, scopes, granted_by)
    VALUES (NEW.org_id, NEW.id, r.requester_org_id, r.id,
            coalesce(r.grant_scopes, ARRAY['events:read', 'events:write', 'tickets:read']), r.decided_by)
    ON CONFLICT (event_id, grantee_org_id) WHERE revoked_at IS NULL DO NOTHING;
    UPDATE public.exos_venue_requests SET event_id = coalesce(event_id, NEW.id) WHERE id = r.id;
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_partner_grant() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_partner_grant ON public.exos_events;
CREATE TRIGGER exos_events_partner_grant AFTER INSERT ON public.exos_events
  FOR EACH ROW WHEN (NEW.hold_id IS NOT NULL) EXECUTE FUNCTION public._exos_tg_event_partner_grant();

CREATE OR REPLACE FUNCTION public._exos_venue_request_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', r.id, 'status', r.status, 'date', r.date, 'start_time', to_char(r.start_time, 'HH24:MI'),
    'title', r.title, 'message', r.message, 'expected_draw', r.expected_draw,
    'venue', jsonb_build_object('id', v.id, 'name', v.name, 'city', v.address ->> 'city', 'timezone', v.timezone),
    'room', CASE WHEN rm.id IS NULL THEN NULL ELSE jsonb_build_object('id', rm.id, 'name', rm.name, 'capacity', rm.capacity) END,
    'venue_org', jsonb_build_object('id', vo.id, 'name', vo.name),
    'requester_org', jsonb_build_object('id', ro.id, 'name', ro.name),
    'outcome', r.outcome, 'hold_id', r.hold_id, 'event_id', r.event_id, 'grant_scopes', to_jsonb(r.grant_scopes),
    'grant', (SELECT jsonb_build_object('id', g.id, 'event_id', g.event_id, 'scopes', to_jsonb(g.scopes), 'revoked_at', g.revoked_at)
                FROM public.exos_event_partner_grants g WHERE g.request_id = r.id ORDER BY g.created_at DESC LIMIT 1),
    'decline_reason', r.decline_reason, 'decided_at', r.decided_at,
    'created_via', r.created_via, 'created_at', r.created_at, 'updated_at', r.updated_at)
    FROM public.exos_venue_requests r
    JOIN public.exos_venues v ON v.id = r.venue_id
    JOIN public.exos_orgs vo ON vo.id = r.org_id
    JOIN public.exos_orgs ro ON ro.id = r.requester_org_id
    LEFT JOIN public.exos_venue_rooms rm ON rm.id = r.room_id
   WHERE r.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_venue_request_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_request_json(uuid) TO service_role;

-- Venues other orgs run that take requests (name / city search, at least 2
-- characters), with their rooms. Never their contacts or notes.
CREATE OR REPLACE FUNCTION public._exos_venue_directory(p_org uuid, p_q text, p_limit int DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_q text := lower(btrim(coalesce(p_q, '')));
BEGIN
  IF char_length(v_q) < 2 OR char_length(v_q) > 100 THEN
    RAISE EXCEPTION 'q must be 2 to 100 characters (a venue name or city)' USING ERRCODE = '22023';
  END IF;
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'name', x->>'id') FROM (
    SELECT jsonb_build_object('id', v.id, 'name', v.name, 'city', v.address ->> 'city', 'region', v.address ->> 'region',
             'timezone', v.timezone, 'capacity', v.capacity, 'verified', v.verified,
             'org', jsonb_build_object('id', o.id, 'name', o.name),
             'rooms', coalesce((SELECT jsonb_agg(jsonb_build_object('id', rm.id, 'name', rm.name, 'capacity', rm.capacity)
                                                 ORDER BY rm.sort_order, rm.name)
                                  FROM public.exos_venue_rooms rm WHERE rm.venue_id = v.id), '[]'::jsonb)) AS x
      FROM public.exos_venues v JOIN public.exos_orgs o ON o.id = v.org_id
     WHERE v.relationship = 'owned' AND v.accepts_requests AND v.org_id <> p_org
       AND (lower(v.name) LIKE '%' || v_q || '%' OR lower(coalesce(v.address ->> 'city', '')) LIKE '%' || v_q || '%')
     ORDER BY v.name, v.id
     LIMIT least(greatest(coalesce(p_limit, 25), 1), 50)) s), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_directory(uuid, text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_directory(uuid, text, int) TO service_role;

-- p: { venue_id, room_id?, date, start_time?, title, message?, expected_draw?,
--      idempotency_key? }. The requester's org asks; 50 pending at once and
-- 30 a day per requester org.
CREATE OR REPLACE FUNCTION public._exos_venue_request_create(p_org uuid, p_actor uuid, p_via text, p_api_key uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v public.exos_venues%ROWTYPE; v_room uuid; v_date date; v_time time; v_title text; v_msg text; v_draw int;
  v_key text; v_prev public.exos_venue_requests%ROWTYPE; v_id uuid; v_vid uuid;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RAISE EXCEPTION 'body must be an object' USING ERRCODE = '22023'; END IF;
  v_key := nullif(p ->> 'idempotency_key', '');
  IF v_key IS NOT NULL THEN
    IF v_key !~ '^[A-Za-z0-9_.:-]{8,100}$' THEN
      RAISE EXCEPTION 'Idempotency-Key must be 8-100 letters, digits, _ . : or -' USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_venue_requests:' || p_org || ':' || v_key, 0));
    SELECT * INTO v_prev FROM public.exos_venue_requests WHERE requester_org_id = p_org AND idempotency_key = v_key;
    IF v_prev.id IS NOT NULL THEN
      RETURN public._exos_venue_request_json(v_prev.id) || jsonb_build_object('idempotent_replay', true);
    END IF;
  END IF;
  v_vid := public._exos_uuid(p ->> 'venue_id', 'venue_id');
  SELECT * INTO v FROM public.exos_venues WHERE id = v_vid;
  -- A copy linked to an owned venue: ask the venue it stands for.
  IF v.id IS NOT NULL AND v.org_id = p_org AND v.listed_venue_id IS NOT NULL THEN
    SELECT * INTO v FROM public.exos_venues WHERE id = v.listed_venue_id;
  END IF;
  IF v.id IS NULL OR v.org_id = p_org OR v.relationship <> 'owned' THEN
    RAISE EXCEPTION 'venue not found (send requests to a venue another organization runs)' USING ERRCODE = 'P0002';
  END IF;
  IF NOT v.accepts_requests THEN
    RAISE EXCEPTION 'this venue doesn''t take booking requests on Exos' USING ERRCODE = '55000';
  END IF;
  v_room := public._exos_uuid(p ->> 'room_id', 'room_id');
  IF v_room IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_venue_rooms WHERE id = v_room AND venue_id = v.id) THEN
    RAISE EXCEPTION 'room_id: room not found in that venue' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' THEN
    RAISE EXCEPTION 'date must be a date written YYYY-MM-DD' USING ERRCODE = '22023';
  END IF;
  BEGIN
    v_date := (p ->> 'date')::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'date must be a real date' USING ERRCODE = '22023';
  END;
  IF v_date < (now() AT TIME ZONE coalesce(v.timezone, 'UTC'))::date OR v_date > current_date + 1100 THEN
    RAISE EXCEPTION 'date must be today or later (within three years)' USING ERRCODE = '22023';
  END IF;
  v_time := public._exos_hm(p ->> 'start_time', 'start_time');
  IF jsonb_typeof(p -> 'title') IS DISTINCT FROM 'string' OR char_length(btrim(p ->> 'title')) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'title is required (at most 100 characters)' USING ERRCODE = '22023';
  END IF;
  v_title := btrim(p ->> 'title');
  IF p ? 'message' AND p -> 'message' <> 'null'::jsonb AND (jsonb_typeof(p -> 'message') <> 'string'
       OR char_length(p ->> 'message') > 2000) THEN
    RAISE EXCEPTION 'message must be at most 2000 characters' USING ERRCODE = '22023';
  END IF;
  v_msg := coalesce(p ->> 'message', '');
  IF p ? 'expected_draw' AND p -> 'expected_draw' <> 'null'::jsonb THEN
    IF jsonb_typeof(p -> 'expected_draw') <> 'number' OR (p ->> 'expected_draw')::numeric NOT BETWEEN 0 AND 1000000
       OR (p ->> 'expected_draw')::numeric % 1 <> 0 THEN
      RAISE EXCEPTION 'expected_draw must be a whole number from 0' USING ERRCODE = '22023';
    END IF;
    v_draw := (p ->> 'expected_draw')::int;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_venue_requests:' || p_org, 0));
  IF (SELECT count(*) FROM public.exos_venue_requests WHERE requester_org_id = p_org AND status = 'pending') >= 50 THEN
    RAISE EXCEPTION 'at most 50 pending booking requests; withdraw one first' USING ERRCODE = '54000';
  END IF;
  IF (SELECT count(*) FROM public.exos_venue_requests
       WHERE requester_org_id = p_org AND created_at > now() - interval '1 day') >= 30 THEN
    RAISE EXCEPTION 'at most 30 booking requests a day' USING ERRCODE = '54000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_venue_requests
              WHERE requester_org_id = p_org AND venue_id = v.id AND room_id IS NOT DISTINCT FROM v_room
                AND date = v_date AND status = 'pending') THEN
    RAISE EXCEPTION 'you already have a pending request for that date and room' USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.exos_venue_requests (org_id, venue_id, room_id, requester_org_id, date, start_time, title, message,
                                          expected_draw, created_by, created_via, api_key_id, idempotency_key)
  VALUES (v.org_id, v.id, v_room, p_org, v_date, v_time, v_title, v_msg, v_draw, p_actor, coalesce(p_via, 'dashboard'),
          p_api_key, v_key)
  RETURNING id INTO v_id;
  RETURN public._exos_venue_request_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_request_create(uuid, uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_request_create(uuid, uuid, text, uuid, jsonb) TO service_role;

-- The venue org decides. p_action 'approve': p { create: 'hold' | 'event'
-- (default hold), scopes?: [...] (the promoter's grant on the event; default
-- events:read, events:write, tickets:read), time?, capacity?, level? }.
-- 'decline': p { reason? }. Only a pending request (55000 otherwise; two
-- approvals at once: the second waits on the row and finds it decided).
CREATE OR REPLACE FUNCTION public._exos_venue_request_decide(p_org uuid, p_actor uuid, p_via text, p_api_key uuid,
                                                             p_id uuid, p_action text, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r public.exos_venue_requests%ROWTYPE; b jsonb := coalesce(p, '{}'::jsonb); v_create text; v_scopes text[];
  v_hold jsonb; v_hold_id uuid; v_conv jsonb; v_pos jsonb; v_from text; v_reason text;
BEGIN
  IF jsonb_typeof(b) <> 'object' THEN RAISE EXCEPTION 'body must be an object' USING ERRCODE = '22023'; END IF;
  SELECT * INTO r FROM public.exos_venue_requests WHERE id = p_id AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status <> 'pending' THEN
    RAISE EXCEPTION 'this request is already %', r.status USING ERRCODE = '55000';
  END IF;
  IF p_action = 'decline' THEN
    IF b ? 'reason' AND b -> 'reason' <> 'null'::jsonb AND (jsonb_typeof(b -> 'reason') <> 'string'
         OR char_length(b ->> 'reason') > 500) THEN
      RAISE EXCEPTION 'reason must be at most 500 characters' USING ERRCODE = '22023';
    END IF;
    v_reason := nullif(btrim(b ->> 'reason'), '');
    UPDATE public.exos_venue_requests
       SET status = 'declined', decline_reason = v_reason, decided_by = p_actor, decided_at = now()
     WHERE id = p_id;
    RETURN public._exos_venue_request_json(p_id);
  ELSIF p_action IS DISTINCT FROM 'approve' THEN
    RAISE EXCEPTION 'action must be approve or decline' USING ERRCODE = '22023';
  END IF;

  v_create := coalesce(b ->> 'create', 'hold');
  IF v_create NOT IN ('hold', 'event') THEN RAISE EXCEPTION 'create must be hold or event' USING ERRCODE = '22023'; END IF;
  v_scopes := public._exos_grant_clean_scopes(b -> 'scopes');
  SELECT name INTO v_from FROM public.exos_orgs WHERE id = r.requester_org_id;
  v_pos := jsonb_build_object('date', to_char(r.date, 'YYYY-MM-DD'), 'venue_id', r.venue_id)
        || CASE WHEN r.room_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('room_id', r.room_id) END
        || CASE WHEN r.start_time IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('start_time', to_char(r.start_time, 'HH24:MI')) END
        || CASE WHEN b ? 'level' THEN jsonb_build_object('level', b -> 'level') ELSE '{}'::jsonb END;
  v_hold := public._exos_hold_create(p_org, p_actor, coalesce(p_via, 'dashboard'), p_api_key, jsonb_build_object(
    'title', left(r.title, 100),
    'notes', left('Booking request from ' || coalesce(v_from, 'another organization')
                  || CASE WHEN r.expected_draw IS NULL THEN '' ELSE ' (expected draw ' || r.expected_draw || ')' END
                  || CASE WHEN r.message = '' THEN '' ELSE E'.\n\n' || r.message END, 2000),
    'positions', jsonb_build_array(v_pos)));
  v_hold_id := (v_hold ->> 'id')::uuid;
  UPDATE public.exos_venue_requests
     SET status = 'approved', outcome = v_create, grant_scopes = v_scopes, hold_id = v_hold_id,
         decided_by = p_actor, decided_at = now()
   WHERE id = p_id;
  IF v_create = 'event' THEN
    v_conv := public._exos_hold_convert(p_org, p_actor, coalesce(p_via, 'dashboard'), p_api_key, v_hold_id,
      jsonb_strip_nulls(jsonb_build_object('date', to_char(r.date, 'YYYY-MM-DD'), 'room_id', r.room_id,
                                           'time', b -> 'time', 'capacity', b -> 'capacity')));
  END IF;
  RETURN public._exos_venue_request_json(p_id) || jsonb_build_object('hold', v_hold);
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_request_decide(uuid, uuid, text, uuid, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_request_decide(uuid, uuid, text, uuid, uuid, text, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_venue_request_withdraw(p_org uuid, p_id uuid, p_actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_venue_requests%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_venue_requests WHERE id = p_id AND requester_org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status <> 'pending' THEN RAISE EXCEPTION 'this request is already %', r.status USING ERRCODE = '55000'; END IF;
  UPDATE public.exos_venue_requests SET status = 'withdrawn', decided_by = p_actor, decided_at = now() WHERE id = p_id;
  RETURN public._exos_venue_request_json(p_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_request_withdraw(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_request_withdraw(uuid, uuid, uuid) TO service_role;

-- One request the org sent or received; another's is not found.
CREATE OR REPLACE FUNCTION public._exos_venue_request_get(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_venue_requests WHERE id = p_id AND (org_id = p_org OR requester_org_id = p_org)) THEN
    RAISE EXCEPTION 'request not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN public._exos_venue_request_json(p_id)
      || jsonb_build_object('direction', CASE WHEN (SELECT org_id FROM public.exos_venue_requests WHERE id = p_id) = p_org
                                              THEN 'received' ELSE 'sent' END);
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_request_get(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_request_get(uuid, uuid) TO service_role;

-- A page: p_direction 'received' (the venue's) or 'sent' (the promoter's),
-- newest first; p_status filters. { data, total }.
CREATE OR REPLACE FUNCTION public._exos_venue_requests_page(p_org uuid, p_direction text, p_status text,
                                                            p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_dir text := coalesce(p_direction, 'received');
BEGIN
  IF v_dir NOT IN ('received', 'sent') THEN RAISE EXCEPTION 'direction must be received or sent' USING ERRCODE = '22023'; END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('pending', 'approved', 'declined', 'withdrawn') THEN
    RAISE EXCEPTION 'status must be pending, approved, declined or withdrawn' USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object(
    'data', coalesce((SELECT jsonb_agg(public._exos_venue_request_json(x.id) ORDER BY x.created_at DESC, x.id) FROM (
              SELECT r.id, r.created_at FROM public.exos_venue_requests r
               WHERE (CASE WHEN v_dir = 'received' THEN r.org_id ELSE r.requester_org_id END) = p_org
                 AND (p_status IS NULL OR r.status = p_status)
               ORDER BY r.created_at DESC, r.id
               LIMIT least(greatest(coalesce(p_limit, 50), 1), 200) OFFSET greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb),
    'total', (SELECT count(*) FROM public.exos_venue_requests r
               WHERE (CASE WHEN v_dir = 'received' THEN r.org_id ELSE r.requester_org_id END) = p_org
                 AND (p_status IS NULL OR r.status = p_status)));
END $$;
REVOKE ALL ON FUNCTION public._exos_venue_requests_page(uuid, text, text, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_venue_requests_page(uuid, text, text, int, int) TO service_role;

-- Grants (the venue org): change the scopes or revoke.
CREATE OR REPLACE FUNCTION public._exos_partner_grant_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', g.id, 'event', jsonb_build_object('id', e.id, 'name', e.name, 'starts_at', e.starts_at,
           'status', e.status), 'grantee_org', jsonb_build_object('id', o.id, 'name', o.name),
           'request_id', g.request_id, 'scopes', to_jsonb(g.scopes), 'revoked_at', g.revoked_at,
           'created_at', g.created_at, 'updated_at', g.updated_at)
    FROM public.exos_event_partner_grants g
    JOIN public.exos_events e ON e.id = g.event_id
    JOIN public.exos_orgs o ON o.id = g.grantee_org_id
   WHERE g.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_partner_grant_json(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_partner_grants_list(p_org uuid, p_event uuid DEFAULT NULL, p_live_only boolean DEFAULT true)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(public._exos_partner_grant_json(g.id) ORDER BY g.created_at DESC, g.id), '[]'::jsonb)
    FROM (SELECT id, created_at FROM public.exos_event_partner_grants
           WHERE org_id = p_org AND (p_event IS NULL OR event_id = p_event)
             AND (NOT p_live_only OR revoked_at IS NULL)
           ORDER BY created_at DESC, id LIMIT 500) g
$$;
REVOKE ALL ON FUNCTION public._exos_partner_grants_list(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_grants_list(uuid, uuid, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_partner_grant_set(p_org uuid, p_actor uuid, p_id uuid, p_scopes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_scopes text[];
BEGIN
  IF p_scopes IS NULL OR p_scopes = 'null'::jsonb THEN RAISE EXCEPTION 'scopes is required' USING ERRCODE = '22023'; END IF;
  v_scopes := public._exos_grant_clean_scopes(p_scopes);
  UPDATE public.exos_event_partner_grants SET scopes = v_scopes, updated_by = p_actor
   WHERE id = p_id AND org_id = p_org AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'grant not found' USING ERRCODE = 'P0002'; END IF;
  RETURN public._exos_partner_grant_json(p_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_grant_set(uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_grant_set(uuid, uuid, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_partner_grant_revoke(p_org uuid, p_actor uuid, p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE public.exos_event_partner_grants SET revoked_at = now(), revoked_by = p_actor
   WHERE id = p_id AND org_id = p_org AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'grant not found' USING ERRCODE = 'P0002'; END IF;
  RETURN public._exos_partner_grant_json(p_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_grant_revoke(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_grant_revoke(uuid, uuid, uuid) TO service_role;

-- The grantee's live scopes on an event (NULL: none, or revoked).
CREATE OR REPLACE FUNCTION public._exos_partner_grant_scopes(p_event uuid, p_grantee uuid)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT g.scopes FROM public.exos_event_partner_grants g
   WHERE g.event_id = p_event AND g.grantee_org_id = p_grantee AND g.revoked_at IS NULL
$$;
REVOKE ALL ON FUNCTION public._exos_partner_grant_scopes(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_grant_scopes(uuid, uuid) TO service_role;

-- The grantee's access check: 42501-free "not found" for no grant (ids
-- can't be probed), 403-style 42501 for a grant without the scope.
CREATE OR REPLACE FUNCTION public._exos_cohost_need(p_org uuid, p_event uuid, p_scope text)
RETURNS text[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v text[] := public._exos_partner_grant_scopes(p_event, p_org);
BEGIN
  IF v IS NULL THEN RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT (p_scope = ANY (v)) THEN
    RAISE EXCEPTION 'grant_scope_required: the venue has not given you % on this event', p_scope USING ERRCODE = '42501';
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_cohost_need(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- Events other orgs let this org work on.
CREATE OR REPLACE FUNCTION public._exos_cohost_events(p_org uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at, 'timezone', e.timezone,
           'venue_name', e.venue_name, 'host_org', jsonb_build_object('id', o.id, 'name', o.name),
           'grant_id', g.id, 'scopes', to_jsonb(g.scopes), 'request_id', g.request_id)
           ORDER BY e.starts_at, e.id), '[]'::jsonb)
    FROM public.exos_event_partner_grants g
    JOIN public.exos_events e ON e.id = g.event_id
    JOIN public.exos_orgs o ON o.id = g.org_id
   WHERE g.grantee_org_id = p_org AND g.revoked_at IS NULL
$$;
REVOKE ALL ON FUNCTION public._exos_cohost_events(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_cohost_events(uuid) TO service_role;

-- events:read on the grant.
CREATE OR REPLACE FUNCTION public._exos_cohost_event(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_scopes text[] := public._exos_cohost_need(p_org, p_event, 'events:read');
BEGIN
  RETURN (SELECT jsonb_build_object(
      'id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at, 'doors_at', e.doors_at,
      'ends_at', e.ends_at, 'timezone', e.timezone, 'currency', e.currency, 'description', e.description,
      'summary', to_jsonb(e) -> 'summary', 'description_md', to_jsonb(e) -> 'description_md',
      'image_url', e.image_url, 'video_url', to_jsonb(e) -> 'video_url',
      'venue_name', e.venue_name, 'total_tickets', e.total_tickets,
      'host_org', jsonb_build_object('id', o.id, 'name', o.name), 'scopes', to_jsonb(v_scopes),
      'ticket_types', coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'price', t.price,
                                  'capacity', t.capacity, 'ticket_type', t.ticket_type) ORDER BY t.sort_order, t.name)
                                  FROM public.exos_ticket_tiers t WHERE t.event_id = e.id), '[]'::jsonb))
    FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id WHERE e.id = p_event);
END $$;
REVOKE ALL ON FUNCTION public._exos_cohost_event(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_cohost_event(uuid, uuid) TO service_role;

-- Every co-host edit: who (the grantee's member behind the key), which
-- fields. The venue org's staff and the grantee's owners / managers read it.
CREATE TABLE IF NOT EXISTS public.exos_cohost_event_edits (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,   -- the event's org
  event_id       uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  grantee_org_id uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  grant_id       uuid REFERENCES public.exos_event_partner_grants (id) ON DELETE SET NULL,
  actor_uid      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  api_key_id     uuid,
  fields         text[] NOT NULL,
  at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_cohost_event_edits_event_idx ON public.exos_cohost_event_edits (event_id, at DESC);
ALTER TABLE public.exos_cohost_event_edits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_cohost_event_edits_sel ON public.exos_cohost_event_edits;
CREATE POLICY exos_cohost_event_edits_sel ON public.exos_cohost_event_edits FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content'])
         OR public.exos_has_org_role(grantee_org_id, ARRAY['owner', 'manager']));
REVOKE ALL ON public.exos_cohost_event_edits FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_cohost_event_edits TO authenticated;
GRANT ALL ON public.exos_cohost_event_edits TO service_role;

-- events:write on the grant: the show's copy only (never price, capacity,
-- dates, status or money settings, which stay with the venue org). Acts as
-- the grantee key's creator, who must be an owner or manager of the grantee
-- org now (as every other API write); logged in exos_cohost_event_edits.
CREATE OR REPLACE FUNCTION public._exos_cohost_event_update(p_org uuid, p_event uuid, p jsonb, p_api_key uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_bad text; k text; v_status text; v_actor uuid; v_ev_org uuid;
BEGIN
  v_actor := public._exos_api_key_actor(p_org, p_api_key, ARRAY['owner', 'manager']);
  PERFORM public._exos_cohost_need(p_org, p_event, 'events:write');
  IF p IS NULL OR jsonb_typeof(p) <> 'object' OR p = '{}'::jsonb THEN
    RAISE EXCEPTION 'Nothing to update' USING ERRCODE = '22023';
  END IF;
  SELECT x INTO v_bad FROM jsonb_object_keys(p) x
   WHERE x NOT IN ('name', 'description', 'summary', 'description_md', 'image_url', 'video_url') ORDER BY x LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'a co-host can change name, description, summary, description_md, image_url and video_url, not %',
      left(v_bad, 40) USING ERRCODE = '22023';
  END IF;
  SELECT status, org_id INTO v_status, v_ev_org FROM public.exos_events WHERE id = p_event FOR UPDATE;
  IF v_status = 'cancelled' THEN RAISE EXCEPTION 'the event is cancelled' USING ERRCODE = '55000'; END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF p -> k <> 'null'::jsonb AND jsonb_typeof(p -> k) <> 'string' THEN
      RAISE EXCEPTION '% must be a string', k USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF p ? 'name' AND char_length(btrim(coalesce(p ->> 'name', ''))) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'name must be 1 to 200 characters' USING ERRCODE = '22023';
  END IF;
  IF (p ? 'image_url' AND p ->> 'image_url' IS NOT NULL AND p ->> 'image_url' !~ '^https://')
     OR (p ? 'video_url' AND p ->> 'video_url' IS NOT NULL AND p ->> 'video_url' !~ '^https://') THEN
    RAISE EXCEPTION 'image_url and video_url must be https URLs' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_each_text(p) x WHERE char_length(coalesce(x.value, '')) > 20000) THEN
    RAISE EXCEPTION 'a field is too long (at most 20000 characters)' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_events SET
    name = CASE WHEN p ? 'name' THEN btrim(p ->> 'name') ELSE name END,
    description = CASE WHEN p ? 'description' THEN p ->> 'description' ELSE description END,
    image_url = CASE WHEN p ? 'image_url' THEN p ->> 'image_url' ELSE image_url END
   WHERE id = p_event;
  -- Store-content columns (present when their migration is): set by name.
  FOR k IN SELECT x FROM jsonb_object_keys(p) x WHERE x IN ('summary', 'description_md', 'video_url') LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'exos_events' AND column_name = k) THEN
      EXECUTE format('UPDATE public.exos_events SET %I = $1 WHERE id = $2', k) USING p ->> k, p_event;
    END IF;
  END LOOP;
  INSERT INTO public.exos_cohost_event_edits (org_id, event_id, grantee_org_id, grant_id, actor_uid, api_key_id, fields)
  VALUES (v_ev_org, p_event, p_org,
          (SELECT g.id FROM public.exos_event_partner_grants g
            WHERE g.event_id = p_event AND g.grantee_org_id = p_org AND g.revoked_at IS NULL),
          v_actor, p_api_key, ARRAY(SELECT jsonb_object_keys(p) ORDER BY 1));
  RETURN public._exos_cohost_event(p_org, p_event);
END $$;
REVOKE ALL ON FUNCTION public._exos_cohost_event_update(uuid, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_cohost_event_update(uuid, uuid, jsonb, uuid) TO service_role;

-- tickets:read on the grant: counts per ticket type (never attendees).
-- Gross in cents (what buyers paid for tickets still held) only when BOTH
-- the grant and the caller's credential (p_cred_scopes: its effective
-- scopes, from exos-api) have finance:read (finance:write covers it).
CREATE OR REPLACE FUNCTION public._exos_cohost_event_sales(p_org uuid, p_event uuid, p_cred_scopes text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_scopes text[] := public._exos_cohost_need(p_org, p_event, 'tickets:read'); v_money boolean;
BEGIN
  v_money := 'finance:read' = ANY (v_scopes)
         AND public._exos_api_has_scope(coalesce(p_cred_scopes, '{}'), 'finance:read');
  RETURN jsonb_build_object('event_id', p_event, 'ticket_types', coalesce((
    SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'id', t.id, 'name', t.name, 'capacity', t.capacity, 'sold', s.sold, 'checked_in', s.checked_in,
             'gross_cents', CASE WHEN v_money THEN s.gross_cents END)) ORDER BY t.sort_order, t.name)
      FROM public.exos_ticket_tiers t
      CROSS JOIN LATERAL (
        SELECT count(*) FILTER (WHERE k.status IN ('active', 'used'))::int AS sold,
               count(*) FILTER (WHERE k.status = 'used')::int AS checked_in,
               coalesce(round(sum(coalesce(k.price_paid, 0)) FILTER (WHERE k.status IN ('active', 'used')) * 100), 0)::bigint AS gross_cents
          FROM public.exos_tickets k WHERE k.tier_id = t.id) s
     WHERE t.event_id = p_event), '[]'::jsonb),
    'scopes', to_jsonb(v_scopes));
END $$;
REVOKE ALL ON FUNCTION public._exos_cohost_event_sales(uuid, uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_cohost_event_sales(uuid, uuid, text[]) TO service_role;

-- ---- Signed-in wrappers -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_venue_directory(p_org_id uuid, p_q text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'content']);
  RETURN public._exos_venue_directory(p_org_id, p_q, 25);
END $$;
REVOKE ALL ON FUNCTION public.exos_venue_directory(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_venue_directory(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_venue_request_create(p_org_id uuid, p_request jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_venue_request_create(p_org_id, auth.uid(), 'dashboard', NULL, p_request);
END $$;
REVOKE ALL ON FUNCTION public.exos_venue_request_create(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_venue_request_create(uuid, jsonb) TO authenticated;

-- p_action 'approve' | 'decline' | 'withdraw' (the side follows the action).
CREATE OR REPLACE FUNCTION public.exos_venue_request_decide(p_id uuid, p_action text, p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_venue_requests%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_venue_requests WHERE id = p_id;
  IF p_action = 'withdraw' THEN
    IF r.id IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(r.requester_org_id, ARRAY['owner', 'manager']) THEN
      RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;
    RETURN public._exos_venue_request_withdraw(r.requester_org_id, p_id, auth.uid());
  END IF;
  IF r.id IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(r.org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_venue_request_decide(r.org_id, auth.uid(), 'dashboard', NULL, p_id, p_action, p_args);
END $$;
REVOKE ALL ON FUNCTION public.exos_venue_request_decide(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_venue_request_decide(uuid, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_venue_requests(p_org_id uuid, p_direction text, p_status text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'content']);
  RETURN public._exos_venue_requests_page(p_org_id, p_direction, p_status, 200, 0);
END $$;
REVOKE ALL ON FUNCTION public.exos_venue_requests(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_venue_requests(uuid, text, text) TO authenticated;

-- The venue org's grants (owner / manager / content read; owner / manager change).
CREATE OR REPLACE FUNCTION public.exos_partner_grants(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'content']);
  RETURN public._exos_partner_grants_list(p_org_id, NULL, false);
END $$;
REVOKE ALL ON FUNCTION public.exos_partner_grants(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_partner_grants(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_partner_grant_set(p_grant_id uuid, p_scopes text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_event_partner_grants WHERE id = p_grant_id);
BEGIN
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_partner_grant_set(v_org, auth.uid(), p_grant_id, to_jsonb(coalesce(p_scopes, '{}'::text[])));
END $$;
REVOKE ALL ON FUNCTION public.exos_partner_grant_set(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_partner_grant_set(uuid, text[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_partner_grant_revoke(p_grant_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_event_partner_grants WHERE id = p_grant_id);
BEGIN
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_partner_grant_revoke(v_org, auth.uid(), p_grant_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_partner_grant_revoke(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_partner_grant_revoke(uuid) TO authenticated;

-- The promoter side: events shared with my org.
CREATE OR REPLACE FUNCTION public.exos_cohost_events(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'content']);
  RETURN public._exos_cohost_events(p_org_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_cohost_events(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_cohost_events(uuid) TO authenticated;

-- ===========================================================================
-- 2. Partner presale: block (default) or allow, per org, overridable per event
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_org_partner_presale (
  org_id     uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  mode       text NOT NULL DEFAULT 'block' CHECK (mode IN ('block', 'allow')),
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.exos_event_partner_presale (
  event_id   uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  mode       text NOT NULL CHECK (mode IN ('block', 'allow')),
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_partner_presale_org_idx ON public.exos_event_partner_presale (org_id);
DROP TRIGGER IF EXISTS exos_org_partner_presale_touch ON public.exos_org_partner_presale;
CREATE TRIGGER exos_org_partner_presale_touch BEFORE UPDATE ON public.exos_org_partner_presale
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_event_partner_presale_touch ON public.exos_event_partner_presale;
CREATE TRIGGER exos_event_partner_presale_touch BEFORE UPDATE ON public.exos_event_partner_presale
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_org_partner_presale ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_partner_presale ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_org_partner_presale_sel ON public.exos_org_partner_presale;
CREATE POLICY exos_org_partner_presale_sel ON public.exos_org_partner_presale FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance', 'content']));
DROP POLICY IF EXISTS exos_event_partner_presale_sel ON public.exos_event_partner_presale;
CREATE POLICY exos_event_partner_presale_sel ON public.exos_event_partner_presale FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance', 'content']));
REVOKE ALL ON public.exos_org_partner_presale, public.exos_event_partner_presale FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_org_partner_presale, public.exos_event_partner_presale TO authenticated;
GRANT ALL ON public.exos_org_partner_presale, public.exos_event_partner_presale TO service_role;

-- The mode for an event: its override, else its org's, else block.
CREATE OR REPLACE FUNCTION public._exos_partner_presale_mode(p_event_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(
    (SELECT x.mode FROM public.exos_event_partner_presale x WHERE x.event_id = p_event_id),
    (SELECT o.mode FROM public.exos_org_partner_presale o JOIN public.exos_events e ON e.org_id = o.org_id
      WHERE e.id = p_event_id),
    'block')
$$;
REVOKE ALL ON FUNCTION public._exos_partner_presale_mode(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_presale_mode(uuid) TO service_role;

-- { org_mode, event_id?, event_mode (override or null), effective? }.
CREATE OR REPLACE FUNCTION public._exos_partner_presale_get(p_org uuid, p_event uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_event IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object(
    'org_mode', coalesce((SELECT mode FROM public.exos_org_partner_presale WHERE org_id = p_org), 'block'))
    || CASE WHEN p_event IS NULL THEN '{}'::jsonb ELSE jsonb_build_object(
         'event_id', p_event,
         'event_mode', (SELECT mode FROM public.exos_event_partner_presale WHERE event_id = p_event),
         'effective', public._exos_partner_presale_mode(p_event)) END;
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_presale_get(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_presale_get(uuid, uuid) TO service_role;

-- p_event NULL: the org's mode ('block' | 'allow'). Else the event's
-- override ('block' | 'allow', or NULL / 'inherit' to follow the org).
CREATE OR REPLACE FUNCTION public._exos_partner_presale_set(p_org uuid, p_actor uuid, p_event uuid, p_mode text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_event IS NULL THEN
    IF p_mode IS NULL OR p_mode NOT IN ('block', 'allow') THEN
      RAISE EXCEPTION 'partner_presale must be block or allow' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_org_partner_presale (org_id, mode, updated_by) VALUES (p_org, p_mode, p_actor)
    ON CONFLICT (org_id) DO UPDATE SET mode = EXCLUDED.mode, updated_by = EXCLUDED.updated_by;
    RETURN public._exos_partner_presale_get(p_org, NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_mode IS NULL OR p_mode = 'inherit' THEN
    DELETE FROM public.exos_event_partner_presale WHERE event_id = p_event;
  ELSIF p_mode IN ('block', 'allow') THEN
    INSERT INTO public.exos_event_partner_presale (event_id, org_id, mode, updated_by) VALUES (p_event, p_org, p_mode, p_actor)
    ON CONFLICT (event_id) DO UPDATE SET mode = EXCLUDED.mode, updated_by = EXCLUDED.updated_by;
  ELSE
    RAISE EXCEPTION 'partner_presale must be block, allow or inherit' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_partner_presale_get(p_org, p_event);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_presale_set(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_presale_set(uuid, uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_partner_presale_get(p_org_id uuid, p_event_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'finance', 'content']);
  RETURN public._exos_partner_presale_get(p_org_id, p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_partner_presale_get(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_partner_presale_get(uuid, uuid) TO authenticated;

-- The org setting: owners (who manage distribution partners).
CREATE OR REPLACE FUNCTION public.exos_partner_presale_set(p_org_id uuid, p_mode text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner']);
  RETURN public._exos_partner_presale_set(p_org_id, auth.uid(), NULL, p_mode);
END $$;
REVOKE ALL ON FUNCTION public.exos_partner_presale_set(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_partner_presale_set(uuid, text) TO authenticated;

-- One event's override: owners and managers (who set the event's presale).
CREATE OR REPLACE FUNCTION public.exos_event_partner_presale_set(p_event_id uuid, p_mode text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_events WHERE id = p_event_id);
BEGIN
  IF v_org IS NULL THEN RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501'; END IF;
  PERFORM public._exos_fin_staff(v_org, ARRAY['owner', 'manager']);
  RETURN public._exos_partner_presale_set(v_org, auth.uid(), p_event_id, p_mode);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_partner_presale_set(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_partner_presale_set(uuid, text) TO authenticated;

-- 20261104130000's refusal, only in block mode.
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid, uuid, uuid, uuid, jsonb, jsonb, boolean, boolean)',
  '/* exos: partner presale mode */',
  $o$    IF p_partner_id IS NOT NULL AND public._exos_presale_blocks(p_event_id, t.id, NULL) THEN$o$,
  $n$    IF p_partner_id IS NOT NULL AND public._exos_presale_blocks(p_event_id, t.id, NULL)
       AND public._exos_partner_presale_mode(p_event_id) = 'block' THEN   /* exos: partner presale mode */ -- mig 20261104180000$n$, 1);
