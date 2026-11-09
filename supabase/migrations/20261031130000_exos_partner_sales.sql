-- ============================================================================
-- Partner sales: distribution partners sell an organizer's tickets through
-- the Opendate partner contract (reserve 10 minutes, then complete), and every
-- ticket they sell is delivered as a signed link to the live rotating ticket.
-- docs/partner-sales.md. Opendate parity, wave 2.
-- ============================================================================
-- Touches:  C: TABLE exos_distribution_partners (one per partner key; RLS:
--              owner / manager read, no key_hash column grant; writes through
--              the RPCs only)
--           C: TABLE exos_tier_distribution (the per-tier "sell through
--              partners" switch; RLS: owner / manager read; RPC writes)
--           C: TABLE exos_partner_reservations (a reservation, and once
--              completed the partner's order; RLS: owner / manager / finance
--              read; never written by clients)
--           W: TABLE exos_cart_holds (+ partner_reservation_id): a reservation
--              holds its seats with ordinary cart holds, so every availability
--              path (exos_effective_available, the house cap, quotas, pools,
--              last call, fixed blocks) sees them with no change
--           C: FUNCTION exos_create_distribution_partner,
--              exos_update_distribution_partner, exos_revoke_distribution_partner,
--              exos_set_tier_distribution (authenticated, role-checked)
--           C: FUNCTION exos_ticket_link_view (anon: a 256-bit link key)
--           C: FUNCTION _exos_dist_partner_create / _update / _revoke,
--              _exos_tier_distribution_set, exos_dist_partner_auth,
--              _exos_partner_may_sell, _exos_partner_ticket_types,
--              _exos_partner_reserve, _exos_partner_reservation_update,
--              _exos_partner_reservation_cancel, _exos_partner_reservation_complete,
--              _exos_partner_comp, _exos_partner_reservation_json,
--              _exos_partner_order_json, _exos_partner_orders,
--              _exos_ticket_link_key, _exos_ticket_link_url,
--              exos_ticket_link_wallet_issue, exos_partner_reservations_sweep
--              (service role: exos-api, exos-wallet, a cron)
--           W: FUNCTION exos_tg_ticket_last_call, exos_tg_ticket_fixed_block
--              (patched only when present: a partner sale whose seats were held
--              before last call / the block release completes, like 'stripe')
--           R: exos_events, exos_ticket_tiers, exos_tickets, exos_orgs,
--              exos_api_keys, exos_org_memberships, the fee and tax helpers
-- Pre-reqs: 20261027100000 (fee rules: exos_tier_passed_on_fees,
--           exos_all_in_unit_cents), 20261019100000 (_exos_door_code_mac),
--           20261014140000 (exos_resale_unlocked), 20260929072000 (wallet),
--           20260928050000 (guest holds: nullable buyer on a hold)
--
-- Who sells what:
--   * A partner key (dk_live_ + 48 hex) is minted by an org OWNER (dashboard)
--     or an org API key with org:admin whose creator is still an owner. Shown
--     once; only its SHA-256 and a 16-character prefix are kept. Scopes:
--     'inventory' (ticket types, reservations, orders) and 'comps'.
--   * A ticket type is offered to partners only when the organizer switched it
--     on (exos_tier_distribution.enabled), the switch isn't paused, and the
--     partner is in its list (an empty list = every partner of the org). Off
--     by default. Table ticket types are never offered.
--   * Partners are marketplaces, so the resale rule applies to them:
--     exos_resale_unlocked(event) must be true (the free tier is never sold
--     through a partner; over it the organizer's resale opt-in is required
--     once 20261029090000 lands, since that migration redefines the same
--     function). Last call (exos_event_last_call, when present) closes new
--     reservations.
--   * Organizer reservations (an org API key with tickets:write: a box office
--     or kiosk) use the same core, may sell any ticket type of the event, and
--     record channel_source 'api'.
--
-- How a sale works (the reservation core):
--   reserve  checks every line and holds the seats with exos_cart_holds rows
--            (chunks of at most 10, the table's own cap) for 10 minutes, locked
--            in the order exos_create_hold uses (quotas, then tiers), so two
--            partners racing for the last seats can't both get them: the loser
--            gets EXSLD (409 sold_out) before charging anyone.
--   update   attendee name / email, whether we email the tickets, the
--            partner's transaction id. Doesn't extend the hold.
--   cancel   releases the holds. A completed reservation can't be cancelled.
--   complete consumes the holds and mints in one transaction, the way
--            exos_fulfill_checkout does (consume, quota, tier cap, house cap).
--            Idempotent: a second call returns the same order. After
--            expires_at it answers 'expired' (410) and releases the seats.
--   Prices are the all-in unit price checkout charges (price schedule, the
--   organizer's passed-on fees and exclusive tax), integer cents.
--
-- Delivery: the tickets are minted on the org owner (as marketplace and guest
-- orders are) with no transfer pending, and each comes back with a signed link
-- to the live ticket: /t/<ticket>#k=<key>, key = base64url(HMAC-SHA256(
-- barcode_secret, 'ticket-link:<ticket>:<owner>')). The fragment never reaches
-- a server. exos_ticket_link_view checks the key and answers the current
-- 30-second door code (T-…, signed with the door day key exactly as the app
-- signs it), so the rotating code works without an account and the secret
-- never leaves the database. A reissue or a transfer rotates the secret and
-- changes the owner, so old links die. The wallet pass is the fallback
-- (exos_ticket_link_wallet_issue, exos-wallet POST /link-pass).
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded patches). Prod apply
-- needs operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
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

-- Cents as major units (2 decimals) for the Opendate-shaped answers.
CREATE OR REPLACE FUNCTION public._exos_major(p_cents bigint)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT round(p_cents::numeric / 100, 2)
$$;
REVOKE ALL ON FUNCTION public._exos_major(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_major(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 1. Partner keys.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_distribution_partners (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  label         text NOT NULL CHECK (length(btrim(label)) BETWEEN 1 AND 80),
  partner_type  text NOT NULL CHECK (partner_type IN
                  ('automatiq','stubhub','vivid','seatgeek','ticketnetwork','victorylive','other')),
  key_prefix    text NOT NULL,
  key_hash      text NOT NULL UNIQUE CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  scopes        text[] NOT NULL DEFAULT ARRAY['inventory']
                  CHECK (cardinality(scopes) BETWEEN 1 AND 2 AND scopes <@ ARRAY['inventory','comps']),
  active        boolean NOT NULL DEFAULT true,
  created_by    uuid,          -- the dashboard user, or the creator of the API key below
  api_key_id    uuid,          -- set when minted through exos-api
  last_used_at  timestamptz,
  revoked_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_distribution_partners_org_idx ON public.exos_distribution_partners (org_id);
DROP TRIGGER IF EXISTS exos_distribution_partners_touch ON public.exos_distribution_partners;
CREATE TRIGGER exos_distribution_partners_touch BEFORE UPDATE ON public.exos_distribution_partners
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_distribution_partners ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_distribution_partners_staff_read ON public.exos_distribution_partners;
CREATE POLICY exos_distribution_partners_staff_read ON public.exos_distribution_partners
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_distribution_partners FROM PUBLIC, anon, authenticated;
-- Never key_hash.
GRANT SELECT (id, org_id, label, partner_type, key_prefix, scopes, active, created_by, api_key_id,
              last_used_at, revoked_at, created_at, updated_at)
  ON public.exos_distribution_partners TO authenticated;
GRANT ALL ON public.exos_distribution_partners TO service_role;
COMMENT ON TABLE public.exos_distribution_partners IS
  'Distribution partner keys (dk_live_…, hash only). mig 20261031130000, docs/partner-sales.md.';

-- Validate a partner scope list (internal).
CREATE OR REPLACE FUNCTION public._exos_dist_clean_scopes(p_scopes text[])
RETURNS text[] LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE v text[];
BEGIN
  IF p_scopes IS NULL THEN RETURN ARRAY['inventory']; END IF;
  IF cardinality(p_scopes) = 0 OR cardinality(p_scopes) > 4
     OR EXISTS (SELECT 1 FROM unnest(p_scopes) s WHERE s IS NULL OR s NOT IN ('inventory','comps')) THEN
    RAISE EXCEPTION 'partner scopes must be a non-empty list of inventory, comps' USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(s ORDER BY s = 'comps', s) INTO v FROM (SELECT DISTINCT s FROM unnest(p_scopes) s) d;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_dist_clean_scopes(text[]) FROM PUBLIC, anon, authenticated;

-- An API key may mint / change partner keys only while the member who made
-- it is still an owner of its org (as the dashboard requires).
CREATE OR REPLACE FUNCTION public._exos_api_key_creator_is_owner(p_org_id uuid, p_api_key_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_api_keys k
                   JOIN public.exos_org_memberships m ON m.org_id = k.org_id AND m.user_id = k.created_by
                  WHERE k.id = p_api_key_id AND k.org_id = p_org_id AND k.revoked_at IS NULL
                    AND m.role = 'owner' AND m.disabled IS NOT TRUE)
$$;
REVOKE ALL ON FUNCTION public._exos_api_key_creator_is_owner(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_key_creator_is_owner(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_dist_partner_view(p public.exos_distribution_partners)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', p.id, 'label', p.label, 'partner_type', p.partner_type,
    'key_prefix', p.key_prefix, 'scopes', to_jsonb(p.scopes), 'active', p.active AND p.revoked_at IS NULL,
    'created_at', p.created_at, 'last_used_at', p.last_used_at, 'revoked_at', p.revoked_at)
$$;
REVOKE ALL ON FUNCTION public._exos_dist_partner_view(public.exos_distribution_partners) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dist_partner_view(public.exos_distribution_partners) TO service_role;

-- Mint a partner key. Internal: the caller has checked who may (owner, or an
-- API key whose creator is an owner). The key is in the answer ONCE.
CREATE OR REPLACE FUNCTION public._exos_dist_partner_create(
  p_org_id uuid, p_label text, p_partner_type text, p_scopes text[], p_actor uuid, p_api_key_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_type  text := lower(btrim(coalesce(p_partner_type, 'other')));
  v_label text := left(btrim(coalesce(nullif(btrim(p_label), ''), v_type)), 80);
  v_key   text;
  p       public.exos_distribution_partners%ROWTYPE;
BEGIN
  IF v_type NOT IN ('automatiq','stubhub','vivid','seatgeek','ticketnetwork','victorylive','other') THEN
    RAISE EXCEPTION 'partner_type must be automatiq, stubhub, vivid, seatgeek, ticketnetwork, victorylive or other'
      USING ERRCODE = '22023';
  END IF;
  IF p_api_key_id IS NOT NULL AND NOT public._exos_api_key_creator_is_owner(p_org_id, p_api_key_id) THEN
    RAISE EXCEPTION 'only a key made by an organization owner can manage partner keys' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_dist_partners:' || p_org_id::text, 0));
  IF (SELECT count(*) FROM public.exos_distribution_partners WHERE org_id = p_org_id AND revoked_at IS NULL) >= 25 THEN
    RAISE EXCEPTION 'at most 25 partner keys per organization; revoke one first' USING ERRCODE = '54000';
  END IF;
  v_key := 'dk_live_' || encode(extensions.gen_random_bytes(24), 'hex');
  INSERT INTO public.exos_distribution_partners (org_id, label, partner_type, key_prefix, key_hash, scopes,
                                                 created_by, api_key_id)
  VALUES (p_org_id, v_label, v_type, left(v_key, 16), encode(extensions.digest(v_key, 'sha256'), 'hex'),
          public._exos_dist_clean_scopes(p_scopes),
          coalesce(p_actor, (SELECT created_by FROM public.exos_api_keys WHERE id = p_api_key_id)), p_api_key_id)
  RETURNING * INTO p;
  RETURN public._exos_dist_partner_view(p) || jsonb_build_object('key', v_key);
END $$;
REVOKE ALL ON FUNCTION public._exos_dist_partner_create(uuid, text, text, text[], uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dist_partner_create(uuid, text, text, text[], uuid, uuid) TO service_role;

-- Change label / active / scopes. Internal. Unknown and other orgs' ids look the same.
CREATE OR REPLACE FUNCTION public._exos_dist_partner_update(p_org_id uuid, p_id uuid, p_patch jsonb, p_api_key_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_distribution_partners%ROWTYPE; v_label text; v_scopes text[];
BEGIN
  IF p_api_key_id IS NOT NULL AND NOT public._exos_api_key_creator_is_owner(p_org_id, p_api_key_id) THEN
    RAISE EXCEPTION 'only a key made by an organization owner can manage partner keys' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO p FROM public.exos_distribution_partners WHERE id = p_id AND org_id = p_org_id FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'partner not found' USING ERRCODE = 'P0002'; END IF;
  IF p.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'this partner key was revoked; mint a new one' USING ERRCODE = '55000';
  END IF;
  IF jsonb_typeof(p_patch) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'send label, active or scopes' USING ERRCODE = '22023';
  END IF;
  IF p_patch ? 'label' THEN
    v_label := btrim(coalesce(p_patch->>'label', ''));
    IF jsonb_typeof(p_patch->'label') <> 'string' OR length(v_label) NOT BETWEEN 1 AND 80 THEN
      RAISE EXCEPTION 'label must be 1-80 characters' USING ERRCODE = '22023';
    END IF;
    p.label := v_label;
  END IF;
  IF p_patch ? 'active' THEN
    IF jsonb_typeof(p_patch->'active') <> 'boolean' THEN
      RAISE EXCEPTION 'active must be true or false' USING ERRCODE = '22023';
    END IF;
    p.active := (p_patch->>'active')::boolean;
  END IF;
  IF p_patch ? 'scopes' THEN
    IF jsonb_typeof(p_patch->'scopes') <> 'array' THEN
      RAISE EXCEPTION 'scopes must be a list' USING ERRCODE = '22023';
    END IF;
    SELECT array_agg(x) INTO v_scopes FROM jsonb_array_elements_text(p_patch->'scopes') x;
    p.scopes := public._exos_dist_clean_scopes(coalesce(v_scopes, '{}'));
  END IF;
  UPDATE public.exos_distribution_partners SET label = p.label, active = p.active, scopes = p.scopes
   WHERE id = p.id RETURNING * INTO p;
  RETURN public._exos_dist_partner_view(p);
END $$;
REVOKE ALL ON FUNCTION public._exos_dist_partner_update(uuid, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dist_partner_update(uuid, uuid, jsonb, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_dist_partner_revoke(p_org_id uuid, p_id uuid, p_api_key_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_distribution_partners%ROWTYPE;
BEGIN
  IF p_api_key_id IS NOT NULL AND NOT public._exos_api_key_creator_is_owner(p_org_id, p_api_key_id) THEN
    RAISE EXCEPTION 'only a key made by an organization owner can manage partner keys' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_distribution_partners SET revoked_at = coalesce(revoked_at, now()), active = false
   WHERE id = p_id AND org_id = p_org_id RETURNING * INTO p;
  IF p.id IS NULL THEN RAISE EXCEPTION 'partner not found' USING ERRCODE = 'P0002'; END IF;
  -- Its open reservations give their seats back now.
  UPDATE public.exos_cart_holds h SET status = 'released', released_at = now()
    FROM public.exos_partner_reservations r
   WHERE h.partner_reservation_id = r.id AND r.partner_id = p.id AND h.status = 'active';
  UPDATE public.exos_partner_reservations SET status = 'cancelled', cancelled_at = now()
   WHERE partner_id = p.id AND status = 'active';
  RETURN public._exos_dist_partner_view(p);
END $$;
REVOKE ALL ON FUNCTION public._exos_dist_partner_revoke(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dist_partner_revoke(uuid, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. The per-tier switch.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_tier_distribution (
  tier_id     uuid PRIMARY KEY REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  enabled     boolean NOT NULL DEFAULT false,
  partner_ids uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(partner_ids) <= 25),
  paused      boolean NOT NULL DEFAULT false,
  updated_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_tier_distribution_event_idx ON public.exos_tier_distribution (event_id);
DROP TRIGGER IF EXISTS exos_tier_distribution_touch ON public.exos_tier_distribution;
CREATE TRIGGER exos_tier_distribution_touch BEFORE UPDATE ON public.exos_tier_distribution
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_tier_distribution ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_tier_distribution_staff_read ON public.exos_tier_distribution;
CREATE POLICY exos_tier_distribution_staff_read ON public.exos_tier_distribution
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_tier_distribution FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_tier_distribution TO authenticated;
GRANT ALL ON public.exos_tier_distribution TO service_role;
COMMENT ON TABLE public.exos_tier_distribution IS
  'Sell through partners, per ticket type (off unless a row says enabled). Empty partner_ids = every partner of the org. mig 20261031130000.';

-- Set tiers' switches: [{ tier_id, enabled, partner_ids?, paused? }]. Tiers not
-- listed keep theirs. Internal (owner / manager checked by the callers).
CREATE OR REPLACE FUNCTION public._exos_tier_distribution_set(p_org_id uuid, p_event_id uuid, p_tiers jsonb, p_actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r       jsonb;
  v_tier  uuid;
  v_ids   uuid[];
  v_bad   uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_typeof(p_tiers) IS DISTINCT FROM 'array' OR jsonb_array_length(p_tiers) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'tiers must be a list of { tier_id, enabled, partner_ids?, paused? }' USING ERRCODE = '22023';
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_tiers) LOOP
    BEGIN
      v_tier := coalesce(r->>'tier_id', r->>'id')::uuid;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'each tier needs a tier_id' USING ERRCODE = '22023';
    END;
    IF NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE id = v_tier AND event_id = p_event_id) THEN
      RAISE EXCEPTION 'tier % is not a ticket type of this event', v_tier USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(r->'enabled') IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'enabled must be true or false' USING ERRCODE = '22023';
    END IF;
    IF (r->>'enabled')::boolean AND public.exos_tier_is_table(v_tier) THEN
      RAISE EXCEPTION 'table ticket types can''t be sold through partners' USING ERRCODE = '22023';
    END IF;
    IF r ? 'paused' AND jsonb_typeof(r->'paused') <> 'boolean' THEN
      RAISE EXCEPTION 'paused must be true or false' USING ERRCODE = '22023';
    END IF;
    v_ids := '{}';
    IF jsonb_typeof(r->'partner_ids') = 'array' THEN
      BEGIN
        SELECT coalesce(array_agg(DISTINCT x::uuid), '{}') INTO v_ids FROM jsonb_array_elements_text(r->'partner_ids') x;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'partner_ids must be partner ids' USING ERRCODE = '22023';
      END;
      SELECT x INTO v_bad FROM unnest(v_ids) x
       WHERE NOT EXISTS (SELECT 1 FROM public.exos_distribution_partners p
                          WHERE p.id = x AND p.org_id = p_org_id AND p.revoked_at IS NULL) LIMIT 1;
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'partner % is not a partner of this organization', v_bad USING ERRCODE = '22023';
      END IF;
    ELSIF r ? 'partner_ids' AND jsonb_typeof(r->'partner_ids') <> 'null' THEN
      RAISE EXCEPTION 'partner_ids must be a list' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled, partner_ids, paused, updated_by)
    VALUES (v_tier, p_event_id, p_org_id, (r->>'enabled')::boolean, v_ids, coalesce((r->>'paused')::boolean, false), p_actor)
    ON CONFLICT (tier_id) DO UPDATE
      SET enabled = EXCLUDED.enabled, partner_ids = EXCLUDED.partner_ids, paused = EXCLUDED.paused,
          updated_by = EXCLUDED.updated_by;
  END LOOP;
  RETURN public._exos_event_distribution_json(p_event_id);
END $$;

CREATE OR REPLACE FUNCTION public._exos_event_distribution_json(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'tier_id', t.id, 'name', t.name, 'table', public.exos_tier_is_table(t.id),
           'enabled', coalesce(d.enabled, false), 'partner_ids', to_jsonb(coalesce(d.partner_ids, '{}'::uuid[])),
           'paused', coalesce(d.paused, false)) ORDER BY t.sort_order, t.id), '[]'::jsonb)
    FROM public.exos_ticket_tiers t
    LEFT JOIN public.exos_tier_distribution d ON d.tier_id = t.id
   WHERE t.event_id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_event_distribution_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_distribution_json(uuid) TO service_role;
REVOKE ALL ON FUNCTION public._exos_tier_distribution_set(uuid, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tier_distribution_set(uuid, uuid, jsonb, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Reservations (and, once completed, the partner's orders).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_partner_reservations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),   -- the order id once completed
  token             text NOT NULL UNIQUE CHECK (token ~ '^rsv_[A-Za-z0-9_-]{43}$'),
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  partner_id        uuid REFERENCES public.exos_distribution_partners (id) ON DELETE SET NULL,
  api_key_id        uuid,
  channel           text NOT NULL CHECK (channel IN ('partner', 'partner_comp', 'organizer')),
  channel_source    text NOT NULL,
  status            text NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','cancelled','expired')),
  expires_at        timestamptz NOT NULL,
  currency          text NOT NULL DEFAULT 'usd',
  lines             jsonb NOT NULL CHECK (jsonb_typeof(lines) = 'array'),
  subtotal_cents    integer NOT NULL DEFAULT 0 CHECK (subtotal_cents >= 0),
  fees_cents        integer NOT NULL DEFAULT 0 CHECK (fees_cents >= 0),
  tax_cents         integer NOT NULL DEFAULT 0 CHECK (tax_cents >= 0),
  total_cents       integer NOT NULL DEFAULT 0 CHECK (total_cents >= 0),
  quantity          integer NOT NULL CHECK (quantity BETWEEN 1 AND 100),
  cash_paid_cents   integer CHECK (cash_paid_cents IS NULL OR cash_paid_cents BETWEEN 0 AND 1000000000),
  send_ticket_email boolean NOT NULL DEFAULT false,
  first_name        text CHECK (first_name IS NULL OR length(first_name) BETWEEN 1 AND 60),
  last_name         text CHECK (last_name IS NULL OR length(last_name) BETWEEN 1 AND 60),
  email             text CHECK (email IS NULL OR (length(email) <= 254 AND email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$')),
  external_id       text CHECK (external_id IS NULL OR external_id ~ '^[A-Za-z0-9_.:#/-]{1,128}$'),
  comp_reason       text CHECK (comp_reason IS NULL OR length(comp_reason) <= 200),
  ticket_ids        uuid[] NOT NULL DEFAULT '{}',
  completed_at      timestamptz,
  cancelled_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (channel <> 'organizer' OR (api_key_id IS NOT NULL AND partner_id IS NULL)),
  CHECK (channel = 'organizer' OR api_key_id IS NULL)
);
CREATE INDEX IF NOT EXISTS exos_partner_reservations_partner_idx ON public.exos_partner_reservations (partner_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_partner_reservations_event_idx ON public.exos_partner_reservations (event_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_partner_reservations_active_idx ON public.exos_partner_reservations (expires_at) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS exos_partner_reservations_external_idx ON public.exos_partner_reservations (partner_id, external_id)
  WHERE external_id IS NOT NULL;
DROP TRIGGER IF EXISTS exos_partner_reservations_touch ON public.exos_partner_reservations;
CREATE TRIGGER exos_partner_reservations_touch BEFORE UPDATE ON public.exos_partner_reservations
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_partner_reservations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_partner_reservations_staff_read ON public.exos_partner_reservations;
CREATE POLICY exos_partner_reservations_staff_read ON public.exos_partner_reservations
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_partner_reservations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_partner_reservations TO authenticated;
GRANT ALL ON public.exos_partner_reservations TO service_role;
COMMENT ON TABLE public.exos_partner_reservations IS
  'Partner and organizer reservations (10-minute holds through exos_cart_holds) and the orders they become. mig 20261031130000.';

ALTER TABLE public.exos_cart_holds
  ADD COLUMN IF NOT EXISTS partner_reservation_id uuid REFERENCES public.exos_partner_reservations (id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS exos_cart_holds_partner_res_idx ON public.exos_cart_holds (partner_reservation_id)
  WHERE partner_reservation_id IS NOT NULL;
COMMENT ON COLUMN public.exos_cart_holds.partner_reservation_id IS
  'Set on the holds of a partner / organizer reservation (mig 20261031130000); buyer_uid is NULL on those.';

-- ---------------------------------------------------------------------------
-- 4. Partner key check (exos-api, every partner request).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_dist_partner_auth(p_key_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_distribution_partners%ROWTYPE;
BEGIN
  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  SELECT * INTO p FROM public.exos_distribution_partners
   WHERE key_hash = p_key_hash AND revoked_at IS NULL AND active;
  IF p.id IS NULL THEN RETURN NULL; END IF;
  IF p.last_used_at IS NULL OR p.last_used_at < now() - interval '1 minute' THEN
    UPDATE public.exos_distribution_partners SET last_used_at = now() WHERE id = p.id;
  END IF;
  RETURN jsonb_build_object('id', p.id, 'org_id', p.org_id, 'partner_type', p.partner_type,
                            'label', p.label, 'scopes', to_jsonb(p.scopes));
END $$;
REVOKE ALL ON FUNCTION public.exos_dist_partner_auth(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_dist_partner_auth(text) TO service_role;

-- May this partner sell this tier? Switch on, not paused, partner listed (or
-- no list), not a table type.
CREATE OR REPLACE FUNCTION public._exos_partner_may_sell(p_tier_id uuid, p_partner_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_tier_distribution d
     WHERE d.tier_id = p_tier_id AND d.enabled AND NOT d.paused
       AND (cardinality(d.partner_ids) = 0 OR p_partner_id = ANY (d.partner_ids)))
     AND NOT public.exos_tier_is_table(p_tier_id)
$$;
REVOKE ALL ON FUNCTION public._exos_partner_may_sell(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_may_sell(uuid, uuid) TO service_role;

-- Why this event can't sell through partners now (NULL = it can). The
-- resale rule and last call are partner-only; the rest applies to organizer
-- reservations too.
CREATE OR REPLACE FUNCTION public._exos_partner_event_blocker(p_event_id uuid, p_partner boolean)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE e record; v_last boolean := false;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL THEN RETURN 'not_found'; END IF;
  IF e.status = 'cancelled' THEN RETURN 'This event was cancelled.'; END IF;
  IF e.status <> 'published' THEN RETURN 'This event is not on sale.'; END IF;
  IF coalesce(to_jsonb(e)->>'ticket_backend', 'exos') <> 'exos' THEN
    RETURN 'Tickets for this event are sold on another site.';
  END IF;
  IF coalesce(e.ends_at, e.starts_at + interval '6 hours') < now() THEN RETURN 'This event has already ended.'; END IF;
  IF p_partner THEN
    IF NOT coalesce(public.exos_resale_unlocked(p_event_id), false) THEN
      RETURN 'This event is not sold through partners.';
    END IF;
    -- Last call (mig 20261029100000), when present: only the primary sells.
    IF to_regprocedure('public.exos_event_last_call(uuid)') IS NOT NULL THEN
      EXECUTE 'SELECT public.exos_event_last_call($1)' INTO v_last USING p_event_id;
      IF coalesce(v_last, false) THEN RETURN 'The last tickets for this event are on sale only on its own page.'; END IF;
    END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_event_blocker(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_event_blocker(uuid, boolean) TO service_role;

-- The all-in unit price in cents, and its parts (what checkout charges).
CREATE OR REPLACE FUNCTION public._exos_partner_unit_price(p_tier_id uuid, p_comp boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_unit int; v_fees jsonb; v_fee int; v_all int;
BEGIN
  v_unit := CASE WHEN p_comp THEN 0 ELSE greatest(round(coalesce(public.exos_rr_tier_price(p_tier_id), 0) * 100), 0)::int END;
  v_fees := public.exos_tier_passed_on_fees(p_tier_id);
  v_fee  := public.exos_fees_unit_total_cents(v_unit, v_fees);
  v_all  := public.exos_all_in_unit_cents(v_unit, public.exos_tier_exclusive_tax_percent(p_tier_id), v_fees);
  RETURN jsonb_build_object('unit_cents', v_unit, 'fees_cents', v_fee, 'tax_cents', greatest(v_all - v_unit - v_fee, 0),
                            'all_in_cents', v_all,
                            'fees', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', f->>'name',
                                       'amount_cents', public.exos_fee_unit_cents(v_unit, f))), '[]'::jsonb)
                                       FROM jsonb_array_elements(v_fees) f));
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_unit_price(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_unit_price(uuid, boolean) TO service_role;

-- Ticket types a partner may sell for an event, Opendate-shaped (major units).
CREATE OR REPLACE FUNCTION public._exos_partner_ticket_types(p_org_id uuid, p_partner_id uuid, p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_block text; v_cur text; v_left int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id AND status = 'published') THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  v_block := public._exos_partner_event_blocker(p_event_id, true);
  IF v_block IS NOT NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT upper(coalesce(currency, 'usd')) INTO v_cur FROM public.exos_events WHERE id = p_event_id;
  v_left := public.exos_event_house_available(p_event_id);
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.sort_order, x.id) FROM (
      SELECT t.id, t.sort_order, jsonb_build_object(
        'id', t.id, 'name', t.name, 'description', coalesce(t.description, ''),
        'ticket_type', coalesce(t.ticket_type, CASE WHEN (pr->>'unit_cents')::int = 0 THEN 'free' ELSE 'paid' END),
        'currency', v_cur,
        'price', public._exos_major((pr->>'unit_cents')::bigint),
        'calculated_fees', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', f->>'name',
                              'amount', public._exos_major((f->>'amount_cents')::bigint))), '[]'::jsonb)
                              FROM jsonb_array_elements(pr->'fees') f),
        'fees_total', public._exos_major((pr->>'fees_cents')::bigint),
        'taxes_total', public._exos_major((pr->>'tax_cents')::bigint),
        'final_cost', public._exos_major((pr->>'all_in_cents')::bigint),
        'available', a.avail,
        'sold_out', coalesce(a.avail, 1) <= 0,
        'on_sale', coalesce(a.avail, 1) > 0,
        'sales_start', t.sales_start, 'sales_end', t.sales_end) AS j
        FROM public.exos_ticket_tiers t
        CROSS JOIN LATERAL public._exos_partner_unit_price(t.id, false) pr
        CROSS JOIN LATERAL (SELECT CASE
                                     WHEN public.exos_effective_available(t.id) IS NULL THEN v_left
                                     WHEN v_left IS NULL THEN greatest(public.exos_effective_available(t.id), 0)
                                     ELSE least(greatest(public.exos_effective_available(t.id), 0), v_left)
                                   END AS avail) a
       WHERE t.event_id = p_event_id AND public._exos_partner_may_sell(t.id, p_partner_id)
         AND (t.sales_start IS NULL OR t.sales_start <= now())
         AND (t.sales_end IS NULL OR t.sales_end > now())
    ) x), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_ticket_types(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_ticket_types(uuid, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Ticket links: the signed link to the live ticket.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_ticket_link_key(p_ticket uuid, p_owner uuid, p_secret text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path = public, pg_temp AS $$
  SELECT public._exos_b64url(extensions.hmac('ticket-link:' || p_ticket || ':' || p_owner, p_secret, 'sha256'))
$$;
REVOKE ALL ON FUNCTION public._exos_ticket_link_key(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- The link for a ticket, if it can be shown (active or checked in, no
-- transfer pending, the app base is a plain https URL). Internal.
CREATE OR REPLACE FUNCTION public._exos_ticket_link_url(p_ticket uuid, p_app_base text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT rtrim(p_app_base, '/') || '/t/' || t.id || '#k=' || public._exos_ticket_link_key(t.id, t.owner_id, t.barcode_secret)
    FROM public.exos_tickets t
   WHERE t.id = p_ticket AND t.status IN ('active', 'used') AND t.pending_transfer_id IS NULL
     AND t.owner_id IS NOT NULL AND t.barcode_secret IS NOT NULL
     AND p_app_base ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
$$;
REVOKE ALL ON FUNCTION public._exos_ticket_link_url(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_ticket_link_url(uuid, text) TO service_role;

-- Anon: the live ticket behind a link. A wrong key and an unknown ticket give
-- the same answer. The door code is the app's own T- code for the current
-- 30-second bucket, signed here, so the secret never leaves the database.
CREATE OR REPLACE FUNCTION public.exos_ticket_link_view(p_ticket_id uuid, p_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  t       record;
  e       record;
  v_ms    bigint := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
  v_bkt   bigint;
  v_state text;
BEGIN
  IF p_ticket_id IS NULL OR p_key IS NULL OR p_key !~ '^[A-Za-z0-9_-]{43}$' THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT id, event_id, owner_id, status, pending_transfer_id, barcode_secret, tier_name, attendee_name
    INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF t.id IS NULL OR t.owner_id IS NULL OR t.barcode_secret IS NULL
     OR public._exos_ticket_link_key(t.id, t.owner_id, t.barcode_secret) IS DISTINCT FROM p_key THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT name, starts_at, doors_at, timezone, venue_name, image_url, status INTO e
    FROM public.exos_events WHERE id = t.event_id;
  v_state := CASE WHEN e.status = 'cancelled' THEN 'cancelled'
                  WHEN t.status = 'voided' THEN 'voided'
                  WHEN t.pending_transfer_id IS NOT NULL THEN 'in_transfer'
                  WHEN t.status = 'used' THEN 'checked_in'
                  WHEN t.status = 'active' THEN 'valid'
                  ELSE t.status END;
  v_bkt := v_ms / 30000;
  RETURN jsonb_build_object(
    'ok', true, 'ticket_id', t.id, 'state', v_state,
    'event', jsonb_build_object('name', e.name, 'starts_at', e.starts_at, 'doors_at', e.doors_at,
                                'timezone', e.timezone, 'venue_name', e.venue_name, 'image_url', e.image_url),
    'tier_name', t.tier_name, 'attendee_name', t.attendee_name,
    'code', CASE WHEN v_state = 'valid'
                 THEN 'T-' || t.id || ':' || t.owner_id || ':' || v_bkt || ':' ||
                      public._exos_door_code_mac(t.id, t.owner_id, v_bkt, t.barcode_secret) END,
    'refresh_in_ms', 30000 - (v_ms % 30000),
    'server_time', to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_link_view(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_ticket_link_view(uuid, text) TO anon, authenticated, service_role;

-- The wallet fallback: a pass for the holder of a link (service role,
-- exos-wallet POST /link-pass). Same rules as exos_wallet_issue_pass, with the
-- link key standing in for the owner's session; the pass is the owner's.
CREATE OR REPLACE FUNCTION public.exos_ticket_link_wallet_issue(
  p_ticket_id uuid, p_key text, p_kind text, p_token_hash text DEFAULT NULL, p_pass_type text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  t      record;
  v_pass public.exos_wallet_passes%ROWTYPE;
  v_new  boolean := false;
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('apple', 'google') THEN
    RAISE EXCEPTION 'kind must be apple or google' USING ERRCODE = '22023';
  END IF;
  IF p_kind = 'apple' AND (p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$'
                           OR p_pass_type IS NULL OR p_pass_type !~ '^[A-Za-z0-9.-]{3,128}$') THEN
    RAISE EXCEPTION 'apple needs a token hash and pass type' USING ERRCODE = '22023';
  END IF;
  SELECT id, owner_id, status, pending_transfer_id, barcode_secret INTO t
    FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF t.id IS NULL OR t.owner_id IS NULL OR t.barcode_secret IS NULL OR p_key IS NULL
     OR public._exos_ticket_link_key(t.id, t.owner_id, t.barcode_secret) IS DISTINCT FROM p_key THEN
    RAISE EXCEPTION 'not a valid ticket link' USING ERRCODE = '42501';
  END IF;
  IF t.status <> 'active' THEN RETURN jsonb_build_object('ok', false, 'reason', 'not-active'); END IF;
  IF t.pending_transfer_id IS NOT NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer'); END IF;
  UPDATE public.exos_wallet_passes
     SET status = 'voided', void_reason = 'transferred', voided_at = now(),
         code_epoch = code_epoch + 1, updated_at = clock_timestamp(), push_pending = true
   WHERE ticket_id = p_ticket_id AND status = 'active' AND owner_id <> t.owner_id;
  SELECT * INTO v_pass FROM public.exos_wallet_passes WHERE ticket_id = p_ticket_id AND status = 'active' FOR UPDATE;
  IF v_pass.serial_number IS NULL THEN
    INSERT INTO public.exos_wallet_passes (serial_number, ticket_id, owner_id)
    VALUES ('exw' || replace(gen_random_uuid()::text, '-', ''), p_ticket_id, t.owner_id)
    RETURNING * INTO v_pass;
    v_new := true;
  END IF;
  UPDATE public.exos_wallet_passes
     SET auth_token_hash      = CASE WHEN p_kind = 'apple' THEN p_token_hash ELSE auth_token_hash END,
         pass_type_identifier = CASE WHEN p_kind = 'apple' THEN p_pass_type ELSE pass_type_identifier END,
         apple_issued_at      = CASE WHEN p_kind = 'apple' THEN now() ELSE apple_issued_at END,
         google_issued_at     = CASE WHEN p_kind = 'google' THEN now() ELSE google_issued_at END
   WHERE serial_number = v_pass.serial_number;
  RETURN jsonb_build_object('ok', true, 'serial', v_pass.serial_number, 'code_epoch', v_pass.code_epoch, 'created', v_new);
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_link_wallet_issue(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ticket_link_wallet_issue(uuid, text, text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. The reservation core.
-- ---------------------------------------------------------------------------
-- Lazily expire one reservation (its holds stopped counting at expires_at
-- anyway; this makes the record say so).
CREATE OR REPLACE FUNCTION public._exos_partner_res_expire(p_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH r AS (
    UPDATE public.exos_partner_reservations SET status = 'expired'
     WHERE id = p_id AND status = 'active' AND expires_at <= now() RETURNING id)
  UPDATE public.exos_cart_holds SET status = 'expired' FROM r
   WHERE partner_reservation_id = r.id AND exos_cart_holds.status = 'active'
$$;
REVOKE ALL ON FUNCTION public._exos_partner_res_expire(uuid) FROM PUBLIC, anon, authenticated;

-- Opendate-shaped reservation (major units). Internal.
CREATE OR REPLACE FUNCTION public._exos_partner_reservation_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'token', r.token, 'status', r.status, 'expires_at', r.expires_at,
    'event_id', r.event_id, 'confirm_id', r.event_id, 'currency', upper(r.currency),
    'order_items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'ticket_type_id', l->>'tier_id', 'name', l->>'name', 'quantity', (l->>'quantity')::int,
        'price', public._exos_major((l->>'unit_cents')::bigint), 'fees_total', public._exos_major((l->>'fees_cents')::bigint),
        'taxes_total', public._exos_major((l->>'tax_cents')::bigint), 'total', public._exos_major((l->>'total_cents')::bigint))), '[]'::jsonb)
        FROM jsonb_array_elements(r.lines) l),
    'subtotal', public._exos_major(r.subtotal_cents), 'fees_total', public._exos_major(r.fees_cents),
    'taxes_total', public._exos_major(r.tax_cents), 'total', public._exos_major(r.total_cents),
    'cash_paid', public._exos_major(r.cash_paid_cents), 'should_send_ticket_email', r.send_ticket_email,
    'first_name', r.first_name, 'last_name', r.last_name, 'email', r.email,
    'stubhub_transaction_id', r.external_id,
    'order_id', CASE WHEN r.status = 'completed' THEN r.id END,
    'created_at', r.created_at, 'updated_at', r.updated_at)
    FROM public.exos_partner_reservations r WHERE r.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_partner_reservation_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_reservation_json(uuid) TO service_role;

-- Opendate-shaped order: the tickets the buyer still holds, each with its live
-- link (no PDF). Internal.
CREATE OR REPLACE FUNCTION public._exos_partner_order_json(p_id uuid, p_app_base text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', r.id, 'status', 'completed', 'state', 'paid', 'ticket_reservation_token', r.token,
    'event_id', r.event_id, 'confirm_id', r.event_id, 'calendar_event_id', r.event_id,
    'event_title', e.name, 'first_name', r.first_name, 'last_name', r.last_name, 'email', r.email,
    'stubhub_transaction_id', r.external_id, 'external_order_id', r.external_id,
    'device_name', coalesce(p.label, 'Exos API'), 'currency', upper(r.currency),
    'subtotal', public._exos_major(r.subtotal_cents), 'fees_total', public._exos_major(r.fees_cents),
    'taxes_total', public._exos_major(r.tax_cents), 'total', public._exos_major(r.total_cents),
    'cash_paid', public._exos_major(r.cash_paid_cents),
    'order_items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'ticket_type_id', l->>'tier_id', 'name', l->>'name', 'quantity', (l->>'quantity')::int,
        'price', public._exos_major((l->>'unit_cents')::bigint))), '[]'::jsonb) FROM jsonb_array_elements(r.lines) l),
    'tickets', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'ticket_type_id', t.tier_id, 'ticket_type_name', t.tier_name, 'product_name', t.tier_name,
        'attendee_name', t.attendee_name,
        'status', CASE t.status WHEN 'used' THEN 'checked_in' ELSE t.status END,
        'checked_in_at', t.check_in_at,
        'delivery', CASE WHEN t.status IN ('active', 'used')
                         THEN jsonb_build_object('url', public._exos_ticket_link_url(t.id, p_app_base),
                                                 'wallet', 'from the live ticket page') END)
        ORDER BY t.created_at, t.id), '[]'::jsonb)
        FROM public.exos_tickets t
       WHERE t.id = ANY (r.ticket_ids)
         -- Still with the buyer: not transferred away (voided ones stay, marked).
         AND (t.status = 'voided' OR (t.owner_id = o.owner_uid AND t.pending_transfer_id IS NULL))),
    'created_at', r.completed_at, 'updated_at', r.updated_at)
    FROM public.exos_partner_reservations r
    JOIN public.exos_events e ON e.id = r.event_id
    JOIN public.exos_orgs o ON o.id = r.org_id
    LEFT JOIN public.exos_distribution_partners p ON p.id = r.partner_id
   WHERE r.id = p_id AND r.status = 'completed'
$$;
REVOKE ALL ON FUNCTION public._exos_partner_order_json(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_order_json(uuid, text) TO service_role;

-- Reserve. p_partner_id for a partner (partner scope checked by the caller),
-- p_api_key_id for an organizer reservation. p_lines: [{ ticket_type_id,
-- quantity }]; p_attrs: first_name, last_name, email, should_send_ticket_email,
-- cash_paid_cents, external_id, comp_reason. Returns the reservation json.
CREATE OR REPLACE FUNCTION public._exos_partner_reserve(
  p_org_id uuid, p_event_id uuid, p_partner_id uuid, p_api_key_id uuid, p_lines jsonb, p_attrs jsonb,
  p_comp boolean DEFAULT false, p_dry_run boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_partner  public.exos_distribution_partners%ROWTYPE;
  v_ev       public.exos_events%ROWTYPE;
  v_block    text;
  v_sel      jsonb := '{}'::jsonb;   -- tier_id -> quantity
  l          jsonb;
  v_tier     uuid;
  v_qty      int;
  v_total    int := 0;
  t          record;
  pr         jsonb;
  v_avail    int;
  v_house    int;
  v_lines    jsonb := '[]'::jsonb;
  v_sub      int := 0;
  v_fee      int := 0;
  v_tax      int := 0;
  v_sum      int := 0;
  v_id       uuid := gen_random_uuid();
  v_token    text;
  v_left     int;
  v_chunk    int;
  v_channel  text;
  v_source   text;
  a          jsonb := coalesce(p_attrs, '{}'::jsonb);
BEGIN
  IF (p_partner_id IS NULL) = (p_api_key_id IS NULL) THEN
    RAISE EXCEPTION 'a reservation is made by a partner or an API key' USING ERRCODE = '22023';
  END IF;
  IF p_partner_id IS NOT NULL THEN
    SELECT * INTO v_partner FROM public.exos_distribution_partners
     WHERE id = p_partner_id AND org_id = p_org_id AND revoked_at IS NULL AND active;
    IF v_partner.id IS NULL THEN RAISE EXCEPTION 'partner not found' USING ERRCODE = '42501'; END IF;
    IF p_comp AND NOT ('comps' = ANY (v_partner.scopes)) THEN
      RAISE EXCEPTION 'this key does not have the comps scope' USING ERRCODE = '42501';
    END IF;
    v_channel := CASE WHEN p_comp THEN 'partner_comp' ELSE 'partner' END;
    v_source := 'partner:' || v_partner.partner_type;
  ELSE
    v_channel := 'organizer';
    v_source := 'api';
  END IF;

  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id;
  IF v_ev.id IS NULL OR (p_partner_id IS NOT NULL AND v_ev.status <> 'published') THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  v_block := public._exos_partner_event_blocker(p_event_id, p_partner_id IS NOT NULL);
  IF v_block IS NOT NULL THEN RAISE EXCEPTION '%', v_block USING ERRCODE = 'EX422'; END IF;

  -- The selection: up to 10 ticket types, 100 tickets.
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'order_items_attributes must list 1-10 { ticket_type_id, quantity }' USING ERRCODE = '22023';
  END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    BEGIN
      v_tier := coalesce(l->>'ticket_type_id', l->>'tier_id')::uuid;
      v_qty := (l->>'quantity')::int;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'each order item needs a ticket_type_id and a whole quantity' USING ERRCODE = '22023';
    END;
    IF v_tier IS NULL OR v_qty IS NULL OR v_qty NOT BETWEEN 1 AND 100 THEN
      RAISE EXCEPTION 'each order item needs a ticket_type_id and a quantity of 1-100' USING ERRCODE = '22023';
    END IF;
    v_sel := jsonb_set(v_sel, ARRAY[v_tier::text], to_jsonb(coalesce((v_sel->>v_tier::text)::int, 0) + v_qty));
    v_total := v_total + v_qty;
  END LOOP;
  IF v_total > 100 THEN RAISE EXCEPTION 'at most 100 tickets per reservation' USING ERRCODE = '22023'; END IF;

  -- Locks in exos_create_hold's order: every quota of these tiers, then the
  -- tiers, each by id, so two reservations can't deadlock or both pass.
  PERFORM 1 FROM public.exos_quotas q
    WHERE q.id IN (SELECT qt.quota_id FROM public.exos_quota_tiers qt
                    WHERE qt.tier_id IN (SELECT k::uuid FROM jsonb_object_keys(v_sel) k))
    ORDER BY q.id FOR UPDATE;
  PERFORM 1 FROM public.exos_ticket_tiers
    WHERE id IN (SELECT k::uuid FROM jsonb_object_keys(v_sel) k) ORDER BY id FOR UPDATE;

  FOR t IN SELECT tt.*, (v_sel->>tt.id::text)::int AS qty
             FROM public.exos_ticket_tiers tt
            WHERE tt.id IN (SELECT k::uuid FROM jsonb_object_keys(v_sel) k)
            ORDER BY tt.sort_order, tt.id LOOP
    IF t.event_id <> p_event_id THEN
      RAISE EXCEPTION 'ticket type % is not part of this event', t.id USING ERRCODE = 'EX422';
    END IF;
    IF public.exos_tier_is_table(t.id) THEN
      RAISE EXCEPTION 'ticket type % is a table and can''t be reserved here', t.id USING ERRCODE = 'EX422';
    END IF;
    IF p_partner_id IS NOT NULL AND NOT public._exos_partner_may_sell(t.id, p_partner_id) THEN
      RAISE EXCEPTION 'ticket type % is not available for distribution', t.id USING ERRCODE = 'EX422';
    END IF;
    IF t.sales_start IS NOT NULL AND now() < t.sales_start THEN
      RAISE EXCEPTION 'sales for % have not opened yet', t.name USING ERRCODE = 'EX422';
    END IF;
    IF t.sales_end IS NOT NULL AND now() > t.sales_end THEN
      RAISE EXCEPTION 'sales for % have ended', t.name USING ERRCODE = 'EX422';
    END IF;
    v_avail := public.exos_effective_available(t.id);
    IF v_avail IS NOT NULL AND v_avail < t.qty THEN
      RAISE EXCEPTION 'sold out: % has % left', t.name, greatest(v_avail, 0) USING ERRCODE = 'EXSLD';
    END IF;
    pr := public._exos_partner_unit_price(t.id, p_comp);
    v_lines := v_lines || jsonb_build_object(
      'tier_id', t.id, 'name', t.name, 'quantity', t.qty,
      'unit_cents', (pr->>'unit_cents')::int, 'fees_cents', (pr->>'fees_cents')::int * t.qty,
      'tax_cents', (pr->>'tax_cents')::int * t.qty, 'all_in_cents', (pr->>'all_in_cents')::int,
      'total_cents', (pr->>'all_in_cents')::int * t.qty);
    v_sub := v_sub + (pr->>'unit_cents')::int * t.qty;
    v_fee := v_fee + (pr->>'fees_cents')::int * t.qty;
    v_tax := v_tax + (pr->>'tax_cents')::int * t.qty;
    v_sum := v_sum + (pr->>'all_in_cents')::int * t.qty;
  END LOOP;
  IF jsonb_array_length(v_lines) <> (SELECT count(*) FROM jsonb_object_keys(v_sel)) THEN
    RAISE EXCEPTION 'unknown ticket type' USING ERRCODE = 'EX422';
  END IF;
  -- The house cap (non-table types: one admission per ticket).
  v_house := public.exos_event_house_available(p_event_id);
  IF v_house IS NOT NULL AND v_house < v_total THEN
    RAISE EXCEPTION 'sold out: the event has % left', v_house USING ERRCODE = 'EXSLD';
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object('event_id', p_event_id, 'currency', upper(coalesce(v_ev.currency, 'usd')),
      'order_items', (SELECT jsonb_agg(jsonb_build_object('ticket_type_id', x->>'tier_id', 'name', x->>'name',
          'quantity', (x->>'quantity')::int, 'price', public._exos_major((x->>'unit_cents')::bigint),
          'fees_total', public._exos_major((x->>'fees_cents')::bigint), 'taxes_total', public._exos_major((x->>'tax_cents')::bigint),
          'total', public._exos_major((x->>'total_cents')::bigint))) FROM jsonb_array_elements(v_lines) x),
      'subtotal', public._exos_major(v_sub), 'fees_total', public._exos_major(v_fee),
      'taxes_total', public._exos_major(v_tax), 'total', public._exos_major(v_sum));
  END IF;

  v_token := 'rsv_' || public._exos_b64url(extensions.gen_random_bytes(32));
  INSERT INTO public.exos_partner_reservations (
    id, token, org_id, event_id, partner_id, api_key_id, channel, channel_source, expires_at, currency, lines,
    subtotal_cents, fees_cents, tax_cents, total_cents, quantity, cash_paid_cents, send_ticket_email,
    first_name, last_name, email, external_id, comp_reason)
  VALUES (
    v_id, v_token, p_org_id, p_event_id, p_partner_id, p_api_key_id, v_channel, v_source,
    now() + interval '10 minutes', lower(coalesce(v_ev.currency, 'usd')), v_lines,
    v_sub, v_fee, v_tax, v_sum, v_total, (a->>'cash_paid_cents')::int,
    coalesce((a->>'should_send_ticket_email')::boolean, false),
    nullif(left(btrim(a->>'first_name'), 60), ''), nullif(left(btrim(a->>'last_name'), 60), ''),
    nullif(lower(btrim(a->>'email')), ''), nullif(btrim(a->>'external_id'), ''),
    nullif(left(btrim(a->>'comp_reason'), 200), ''));

  FOR l IN SELECT * FROM jsonb_array_elements(v_lines) LOOP
    v_left := (l->>'quantity')::int;
    WHILE v_left > 0 LOOP
      v_chunk := least(v_left, 10);
      INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, quantity, expires_at, partner_reservation_id)
      VALUES (p_event_id, (l->>'tier_id')::uuid, p_org_id, v_chunk, now() + interval '10 minutes', v_id);
      v_left := v_left - v_chunk;
    END LOOP;
  END LOOP;
  RETURN public._exos_partner_reservation_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_reserve(uuid, uuid, uuid, uuid, jsonb, jsonb, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_reserve(uuid, uuid, uuid, uuid, jsonb, jsonb, boolean, boolean) TO service_role;

-- One of the caller's reservations, locked. Partner: its own; API key: the
-- org's organizer reservations. Another org's / partner's look not found.
CREATE OR REPLACE FUNCTION public._exos_partner_res_lock(p_org_id uuid, p_partner_id uuid, p_token text)
RETURNS public.exos_partner_reservations LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_partner_reservations%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_partner_reservations
   WHERE token = p_token AND org_id = p_org_id
     AND ((p_partner_id IS NULL AND channel = 'organizer') OR partner_id = p_partner_id)
   FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'reservation not found' USING ERRCODE = 'P0002'; END IF;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_res_lock(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_partner_reservation_get(p_org_id uuid, p_partner_id uuid, p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_partner_reservations%ROWTYPE;
BEGIN
  r := public._exos_partner_res_lock(p_org_id, p_partner_id, p_token);
  PERFORM public._exos_partner_res_expire(r.id);
  RETURN public._exos_partner_reservation_json(r.id);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_reservation_get(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_reservation_get(uuid, uuid, text) TO service_role;

-- Attendee / email / transaction id. An expired reservation answers its
-- status ('expired', 410 at the edge); a finished one 409.
CREATE OR REPLACE FUNCTION public._exos_partner_reservation_update(p_org_id uuid, p_partner_id uuid, p_token text, p_attrs jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_partner_reservations%ROWTYPE; a jsonb := coalesce(p_attrs, '{}'::jsonb);
BEGIN
  r := public._exos_partner_res_lock(p_org_id, p_partner_id, p_token);
  PERFORM public._exos_partner_res_expire(r.id);
  SELECT * INTO r FROM public.exos_partner_reservations WHERE id = r.id;
  IF r.status = 'expired' THEN RETURN public._exos_partner_reservation_json(r.id); END IF;
  IF r.status <> 'active' THEN
    RAISE EXCEPTION 'this reservation is %', r.status USING ERRCODE = 'EX409';
  END IF;
  UPDATE public.exos_partner_reservations SET
    first_name = CASE WHEN a ? 'first_name' THEN nullif(left(btrim(a->>'first_name'), 60), '') ELSE first_name END,
    last_name  = CASE WHEN a ? 'last_name'  THEN nullif(left(btrim(a->>'last_name'), 60), '') ELSE last_name END,
    email      = CASE WHEN a ? 'email'      THEN nullif(lower(btrim(a->>'email')), '') ELSE email END,
    send_ticket_email = CASE WHEN a ? 'should_send_ticket_email'
                             THEN coalesce((a->>'should_send_ticket_email')::boolean, false) ELSE send_ticket_email END,
    external_id = CASE WHEN a ? 'external_id' THEN nullif(btrim(a->>'external_id'), '') ELSE external_id END,
    cash_paid_cents = CASE WHEN a ? 'cash_paid_cents' THEN (a->>'cash_paid_cents')::int ELSE cash_paid_cents END
   WHERE id = r.id;
  RETURN public._exos_partner_reservation_json(r.id);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_reservation_update(uuid, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_reservation_update(uuid, uuid, text, jsonb) TO service_role;

-- Cancel: the seats go back on sale. Cancelling twice is fine; a completed
-- reservation can't be cancelled (409).
CREATE OR REPLACE FUNCTION public._exos_partner_reservation_cancel(p_org_id uuid, p_partner_id uuid, p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_partner_reservations%ROWTYPE; v_n int := 0;
BEGIN
  r := public._exos_partner_res_lock(p_org_id, p_partner_id, p_token);
  IF r.status = 'completed' THEN
    RAISE EXCEPTION 'this reservation was completed; it can no longer be cancelled' USING ERRCODE = 'EX409';
  END IF;
  IF r.status = 'active' THEN
    UPDATE public.exos_cart_holds SET status = 'released', released_at = now()
     WHERE partner_reservation_id = r.id AND status = 'active';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    UPDATE public.exos_partner_reservations SET status = 'cancelled', cancelled_at = now() WHERE id = r.id;
  END IF;
  RETURN jsonb_build_object('token', r.token,
    'status', (SELECT status FROM public.exos_partner_reservations WHERE id = r.id), 'released', v_n > 0);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_reservation_cancel(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_reservation_cancel(uuid, uuid, text) TO service_role;

-- Complete: consume the holds and mint, once. Returns
--   { fresh, status, order }  status 'completed' (fresh false on a repeat)
--                             or 'expired' (nothing sold, seats released).
CREATE OR REPLACE FUNCTION public._exos_partner_reservation_complete(
  p_org_id uuid, p_partner_id uuid, p_token text, p_attrs jsonb, p_app_base text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r       public.exos_partner_reservations%ROWTYPE;
  v_ev    public.exos_events%ROWTYPE;
  v_owner uuid;
  l       jsonb;
  v_tier  uuid;
  v_qty   int;
  v_n     int;
  v_id    uuid;
  v_ids   uuid[] := '{}';
  v_name  text;
  v_safe  text;
  v_links text := '';
  i       int;
BEGIN
  r := public._exos_partner_res_lock(p_org_id, p_partner_id, p_token);
  IF r.status = 'completed' THEN
    RETURN jsonb_build_object('fresh', false, 'status', 'completed', 'order', public._exos_partner_order_json(r.id, p_app_base));
  END IF;
  IF r.status = 'active' AND r.expires_at <= now() THEN
    PERFORM public._exos_partner_res_expire(r.id);
    r.status := 'expired';
  END IF;
  IF r.status = 'expired' THEN
    RETURN jsonb_build_object('fresh', false, 'status', 'expired', 'reservation', public._exos_partner_reservation_json(r.id));
  END IF;
  IF r.status <> 'active' THEN
    RAISE EXCEPTION 'this reservation was %', r.status USING ERRCODE = 'EX409';
  END IF;
  -- Attendee fields may come with the complete call.
  IF p_attrs IS NOT NULL AND p_attrs <> '{}'::jsonb THEN
    PERFORM public._exos_partner_reservation_update(p_org_id, p_partner_id, p_token, p_attrs);
    SELECT * INTO r FROM public.exos_partner_reservations WHERE id = r.id;
  END IF;

  SELECT * INTO v_ev FROM public.exos_events WHERE id = r.event_id;
  SELECT owner_uid INTO v_owner FROM public.exos_orgs WHERE id = r.org_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'the organization has no owner to hold the tickets' USING ERRCODE = 'EX422';
  END IF;
  IF v_ev.status = 'cancelled' THEN
    RAISE EXCEPTION 'This event was cancelled.' USING ERRCODE = 'EX422';
  END IF;
  v_name := nullif(left(btrim(concat_ws(' ', r.first_name, r.last_name)), 80), '');

  -- The holds stop counting, then the mint claims the seats they kept, as
  -- exos_fulfill_checkout does (quotas, tier cap, house cap).
  UPDATE public.exos_cart_holds SET status = 'consumed', consumed_at = now()
   WHERE partner_reservation_id = r.id AND status = 'active';
  FOR l IN SELECT * FROM jsonb_array_elements(r.lines) LOOP
    v_tier := (l->>'tier_id')::uuid;
    v_qty := (l->>'quantity')::int;
    PERFORM public.exos_assert_quota(v_tier, v_qty);
    UPDATE public.exos_ticket_tiers SET sold = sold + v_qty
     WHERE id = v_tier AND event_id = r.event_id AND (capacity = 0 OR sold + v_qty <= capacity);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'sold out: % at completion', l->>'name' USING ERRCODE = 'EXSLD'; END IF;
    FOR i IN 1..v_qty LOOP
      INSERT INTO public.exos_tickets (
        event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
        status, barcode_secret, price_paid, order_ref, channel_source, attendee_name
      ) VALUES (
        r.event_id, r.org_id, v_tier, l->>'name', v_owner, v_owner, r.email,
        'active', gen_random_uuid()::text, public._exos_major((l->>'all_in_cents')::bigint),
        'po:' || r.id, r.channel_source, v_name
      ) RETURNING id INTO v_id;
      v_ids := v_ids || v_id;
    END LOOP;
  END LOOP;
  UPDATE public.exos_events SET tickets_sold = tickets_sold + r.quantity
   WHERE id = r.event_id AND (total_tickets = 0 OR tickets_sold + r.quantity <= total_tickets);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'sold out: the event is at capacity' USING ERRCODE = 'EXSLD'; END IF;

  UPDATE public.exos_partner_reservations SET status = 'completed', completed_at = now(), ticket_ids = v_ids
   WHERE id = r.id;

  -- The tickets email (asked for, with an address and a link base).
  IF r.send_ticket_email AND r.email IS NOT NULL
     AND p_app_base ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' THEN
    v_safe := replace(replace(replace(coalesce(v_ev.name, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    FOR i IN 1..cardinality(v_ids) LOOP
      v_links := v_links || '<li><a href="' || public._exos_ticket_link_url(v_ids[i], p_app_base) ||
                 '">Open ticket ' || i || '</a></li>';
    END LOOP;
    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES ('ticket-issued', r.email,
            left('Your ticket' || CASE WHEN cardinality(v_ids) > 1 THEN 's' ELSE '' END || ' for ' || v_safe, 200),
            '<p>Here ' || CASE WHEN cardinality(v_ids) > 1 THEN 'are your ' || cardinality(v_ids) || ' tickets'
                               ELSE 'is your ticket' END || ' for <strong>' || v_safe || '</strong>.</p>' ||
            '<p>Open a ticket on your phone at the door. Its QR code changes every 30 seconds, so screenshots ' ||
            'and printouts won''t scan. From the ticket page you can add it to Apple or Google Wallet.</p>' ||
            '<ul>' || v_links || '</ul><p>Anyone with a link can use that ticket, so keep this email to yourself.</p>',
            v_owner, 'pending');
  END IF;
  RETURN jsonb_build_object('fresh', true, 'status', 'completed', 'order', public._exos_partner_order_json(r.id, p_app_base));
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_reservation_complete(uuid, uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_reservation_complete(uuid, uuid, text, jsonb, text) TO service_role;

-- A partner comp: a free reservation completed in the same call.
CREATE OR REPLACE FUNCTION public._exos_partner_comp(
  p_org_id uuid, p_partner_id uuid, p_event_id uuid, p_lines jsonb, p_attrs jsonb, p_app_base text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  v := public._exos_partner_reserve(p_org_id, p_event_id, p_partner_id, NULL, p_lines, p_attrs, true, false);
  RETURN public._exos_partner_reservation_complete(p_org_id, p_partner_id, v->>'token', NULL, p_app_base);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_comp(uuid, uuid, uuid, jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_comp(uuid, uuid, uuid, jsonb, jsonb, text) TO service_role;

-- A partner's completed orders, newest first, Opendate's envelope.
-- p_filters: event_id, email, external_id, created_gte, created_lte, updated_gte.
CREATE OR REPLACE FUNCTION public._exos_partner_orders(
  p_org_id uuid, p_partner_id uuid, p_filters jsonb, p_page int, p_per_page int, p_app_base text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  f      jsonb := coalesce(p_filters, '{}'::jsonb);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_per  int := least(greatest(coalesce(p_per_page, 25), 1), 250);
  v_tot  int;
  v_rows jsonb;
BEGIN
  WITH m AS (
    SELECT r.id, r.completed_at FROM public.exos_partner_reservations r
     WHERE r.org_id = p_org_id AND r.partner_id = p_partner_id AND r.status = 'completed'
       AND (f->>'event_id' IS NULL OR r.event_id = (f->>'event_id')::uuid)
       AND (f->>'email' IS NULL OR r.email = lower(f->>'email'))
       AND (f->>'external_id' IS NULL OR r.external_id = f->>'external_id')
       AND (f->>'created_gte' IS NULL OR r.completed_at >= (f->>'created_gte')::timestamptz)
       AND (f->>'created_lte' IS NULL OR r.completed_at <= (f->>'created_lte')::timestamptz)
       AND (f->>'updated_gte' IS NULL OR r.updated_at >= (f->>'updated_gte')::timestamptz))
  SELECT (SELECT count(*) FROM m),
         (SELECT coalesce(jsonb_agg(public._exos_partner_order_json(p.id, p_app_base) ORDER BY p.completed_at DESC, p.id DESC), '[]'::jsonb)
            FROM (SELECT id, completed_at FROM m ORDER BY completed_at DESC, id DESC
                   LIMIT v_per OFFSET (v_page - 1) * v_per) p)
    INTO v_tot, v_rows;
  RETURN jsonb_build_object('current_page', v_page, 'per_page', v_per, 'total_entries', v_tot,
                            'total_pages', greatest(ceil(v_tot::numeric / v_per)::int, 1), 'collection', v_rows);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_orders(uuid, uuid, jsonb, int, int, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_orders(uuid, uuid, jsonb, int, int, text) TO service_role;

-- One order of the partner's (404 for anything else).
CREATE OR REPLACE FUNCTION public._exos_partner_order(p_org_id uuid, p_partner_id uuid, p_order_id uuid, p_app_base text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_partner_order_json(r.id, p_app_base)
    FROM public.exos_partner_reservations r
   WHERE r.id = p_order_id AND r.org_id = p_org_id AND r.status = 'completed'
     AND (r.partner_id = p_partner_id OR (p_partner_id IS NULL AND r.channel = 'organizer'))
$$;
REVOKE ALL ON FUNCTION public._exos_partner_order(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_order(uuid, uuid, uuid, text) TO service_role;

-- Housekeeping for a cron (not scheduled here): expired reservations say so.
CREATE OR REPLACE FUNCTION public.exos_partner_reservations_sweep(p_max int DEFAULT 500)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN SELECT id FROM public.exos_partner_reservations
            WHERE status = 'active' AND expires_at <= now() ORDER BY expires_at LIMIT greatest(p_max, 1)
            FOR UPDATE SKIP LOCKED LOOP
    PERFORM public._exos_partner_res_expire(r.id);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_partner_reservations_sweep(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_partner_reservations_sweep(int) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. The dashboard: owners mint / change / revoke keys; owners and managers
--    set the per-tier switch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_create_distribution_partner(
  p_org_id uuid, p_label text, p_partner_type text, p_scopes text[] DEFAULT ARRAY['inventory'])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'only an organization owner can add partner keys' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_dist_partner_create(p_org_id, p_label, p_partner_type, p_scopes, auth.uid(), NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_create_distribution_partner(uuid, text, text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_create_distribution_partner(uuid, text, text, text[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_update_distribution_partner(p_id uuid, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_distribution_partners WHERE id = p_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_dist_partner_update(v_org, p_id, p_patch, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_update_distribution_partner(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_update_distribution_partner(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_revoke_distribution_partner(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_distribution_partners WHERE id = p_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_dist_partner_revoke(v_org, p_id, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_revoke_distribution_partner(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_revoke_distribution_partner(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_set_tier_distribution(p_event_id uuid, p_tiers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_tier_distribution_set(v_org, p_event_id, p_tiers, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_set_tier_distribution(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_tier_distribution(uuid, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Seams with the channel rules that land in other migrations. Each patch
--    runs only when that function exists (it is created by 20261029100000
--    last call and 20261029160000 fixed block): a partner sale whose seats
--    were held before last call / the block release completes, as a paid
--    Exos checkout does ('stripe'). New reservations are refused by then
--    (the primary hold leaves no seats; _exos_partner_event_blocker).
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_tg_ticket_last_call()', 'partner: (mig 20261031130000)',
  $o$IF coalesce(NEW.channel_source, '') IN ('stripe',$o$,
  $n$IF coalesce(NEW.channel_source, '') LIKE 'partner:%' /* partner: (mig 20261031130000) */
     OR coalesce(NEW.channel_source, '') IN ('stripe',$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_tg_ticket_fixed_block()', 'partner: (mig 20261031130000)',
  $o$IF coalesce(NEW.channel_source, '') IN ('stripe',$o$,
  $n$IF coalesce(NEW.channel_source, '') LIKE 'partner:%' /* partner: (mig 20261031130000) */
     OR coalesce(NEW.channel_source, '') IN ('stripe',$n$, 1);

-- ROLLBACK (manual): DROP the functions above, exos_cart_holds.partner_reservation_id,
--   exos_partner_reservations, exos_tier_distribution, exos_distribution_partners.
