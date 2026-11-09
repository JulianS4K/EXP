-- ============================================================================
-- Migration 20261104200000 — Exos: small operations fixes from the mistake
-- simulations (2026-11-04)
-- ============================================================================
-- 1. Optional per-partner caps (SIM-PARTNER-23). Partners shared the primary
--    pool, so one distribution partner could take every seat the event had
--    left. An organizer can now cap what one partner may hold or sell: per
--    ticket type, or across the event. _exos_partner_reserve counts the
--    partner's live holds plus the tickets it sold that are still valid
--    (active / used) under a per-partner, per-event advisory lock, and refuses
--    a reservation over the cap with SQLSTATE EXCAP (409
--    partner_cap_reached, DETAIL {"left": n, ...}). No cap = no change. The
--    partner's GET ticket_types answers the capped number as `available`.
--    docs/partner-sales.md "Caps".
-- 2. Owner approval for staff invites (the organizer sim's typo'd invite).
--    Any verified account with an invite link joins, first come first served
--    (mig 20260927010000), so an invite typed to the wrong address gave a
--    stranger access the moment they clicked. exos_orgs.invite_approval (on
--    for new orgs; off for every org that exists when this applies, so
--    nothing changes for them): a claimed invite leaves the new member
--    'pending_approval' (disabled, so no exos_has_org_role check passes) until
--    an owner, or a manager for roles below manager, approves. Rejecting
--    deletes the pending membership. An existing member who claims an invite
--    keeps their current access and the new role waits for approval. The
--    inviter's 'invite-accepted' mail names the account that claimed it and
--    says it is waiting. docs/organizer-guide.md (Team), docs/security.md.
-- 3. Drawer recount (SIM-DOOR-20). exos_pos_recount_drawer(session, counted,
--    reason, counts?): owner / manager, a closed drawer, within 7 days of the
--    close, at most 3 recounts, not after the event's settlement is final.
--    The count it replaces is kept in exos_pos_drawer_recounts, and the
--    variance is recomputed against the expected cash stored at close.
--
-- Touches:  C: TABLE exos_partner_caps (RLS: owner / manager read; writes
--              through the functions)
--           C: FUNCTION _exos_partner_cap_used, _exos_partner_cap_left,
--              _exos_partner_cap_check, _exos_partner_caps_json,
--              _exos_partner_caps_set (service role: exos-api),
--              exos_partner_caps, exos_set_partner_caps (authenticated:
--              owner / manager)
--           W: FUNCTION _exos_partner_reserve, _exos_partner_ticket_types
--              (patched in place, marker-checked)
--           W: TABLE exos_orgs (+ invite_approval)
--           W: TABLE exos_org_memberships (+ status, pending_role,
--              pending_invite, pending_since, approved_by, approved_at;
--              trigger _exos_tg_membership_approval)
--           W: FUNCTION exos_claim_invite (patched, when present)
--           C: FUNCTION exos_org_pending_members, exos_org_member_approve,
--              exos_org_member_reject, exos_set_invite_approval (authenticated)
--           C: TABLE exos_pos_drawer_recounts (RLS: owner / manager / finance
--              read), FUNCTION exos_pos_recount_drawer (authenticated)
-- Pre-reqs: 20261031130000 (partner sales), 20261101000000 /
--           20261104130000 (reserve patches), 20260929074000 (POS),
--           20261104120000 (drawer close), 20260927010000 (invite claim).
-- Re-run safe: IF NOT EXISTS, CREATE OR REPLACE, marker-checked patches.
-- Grants of patched functions are kept (CREATE OR REPLACE through
-- pg_get_functiondef). D4 authors; prod apply needs operator OK.
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

-- ---------------------------------------------------------------------------
-- 1. Per-partner caps.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_partner_caps (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  partner_id  uuid NOT NULL REFERENCES public.exos_distribution_partners (id) ON DELETE CASCADE,
  tier_id     uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,   -- NULL: the whole event
  max_tickets integer NOT NULL CHECK (max_tickets BETWEEN 0 AND 100000),
  updated_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_partner_caps_tier_uq ON public.exos_partner_caps (partner_id, tier_id)
  WHERE tier_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_partner_caps_event_uq ON public.exos_partner_caps (partner_id, event_id)
  WHERE tier_id IS NULL;
CREATE INDEX IF NOT EXISTS exos_partner_caps_event_idx ON public.exos_partner_caps (event_id);
DROP TRIGGER IF EXISTS exos_partner_caps_touch ON public.exos_partner_caps;
CREATE TRIGGER exos_partner_caps_touch BEFORE UPDATE ON public.exos_partner_caps
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_partner_caps ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_partner_caps_staff_read ON public.exos_partner_caps;
CREATE POLICY exos_partner_caps_staff_read ON public.exos_partner_caps
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_partner_caps FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_partner_caps TO authenticated;
GRANT ALL ON public.exos_partner_caps TO service_role;
COMMENT ON TABLE public.exos_partner_caps IS
  'Most tickets one distribution partner may hold + sell, per ticket type (tier_id) or per event (tier_id NULL). No row = no cap. mig 20261104200000.';

-- What a partner holds (live holds of its active reservations) plus what it
-- sold that is still valid, for one tier or (p_tier_id NULL) the whole event.
CREATE OR REPLACE FUNCTION public._exos_partner_cap_used(p_partner_id uuid, p_event_id uuid, p_tier_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (
    coalesce((SELECT sum(h.quantity) FROM public.exos_cart_holds h
                JOIN public.exos_partner_reservations r ON r.id = h.partner_reservation_id
               WHERE r.partner_id = p_partner_id AND r.event_id = p_event_id AND r.status = 'active'
                 AND h.status = 'active' AND h.expires_at > now()
                 AND (p_tier_id IS NULL OR h.tier_id = p_tier_id)), 0)
  + coalesce((SELECT count(*) FROM public.exos_partner_reservations r
                JOIN public.exos_tickets t ON t.id = ANY (r.ticket_ids)
               WHERE r.partner_id = p_partner_id AND r.event_id = p_event_id AND r.status = 'completed'
                 AND t.status IN ('active', 'used')
                 AND (p_tier_id IS NULL OR t.tier_id = p_tier_id)), 0))::int
$$;
REVOKE ALL ON FUNCTION public._exos_partner_cap_used(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_cap_used(uuid, uuid, uuid) TO service_role;

-- What the partner may still take of a tier: the tighter of the tier cap and
-- the event cap. NULL = no cap applies.
CREATE OR REPLACE FUNCTION public._exos_partner_cap_left(p_partner_id uuid, p_tier_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT min(greatest(c.max_tickets - public._exos_partner_cap_used(p_partner_id, c.event_id, c.tier_id), 0))::int
    FROM public.exos_partner_caps c
    JOIN public.exos_ticket_tiers t ON t.id = p_tier_id AND t.event_id = c.event_id
   WHERE c.partner_id = p_partner_id AND (c.tier_id = p_tier_id OR c.tier_id IS NULL)
$$;
REVOKE ALL ON FUNCTION public._exos_partner_cap_left(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_cap_left(uuid, uuid) TO service_role;

-- The reserve check. p_sel: { tier_id: quantity }. Takes the partner's cap
-- lock for the event first, so two reservations of the same partner can't
-- both pass on the same remaining count. Raises EXCAP with
-- DETAIL {"left", "max_tickets", "tier_id"} (tier_id null for an event cap).
CREATE OR REPLACE FUNCTION public._exos_partner_cap_check(p_partner_id uuid, p_event_id uuid, p_sel jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c record; v_used int; v_want int; v_left int;
BEGIN
  IF p_partner_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_partner_caps
                                          WHERE partner_id = p_partner_id AND event_id = p_event_id) THEN
    RETURN;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-partner-cap:' || p_partner_id || ':' || p_event_id, 0));
  FOR c IN SELECT * FROM public.exos_partner_caps
            WHERE partner_id = p_partner_id AND event_id = p_event_id
              AND (tier_id IS NULL OR p_sel ? tier_id::text)
            ORDER BY tier_id NULLS FIRST LOOP
    v_want := CASE WHEN c.tier_id IS NULL
                   THEN (SELECT coalesce(sum(value::int), 0) FROM jsonb_each_text(p_sel))
                   ELSE (p_sel ->> c.tier_id::text)::int END;
    IF v_want = 0 THEN CONTINUE; END IF;
    v_used := public._exos_partner_cap_used(p_partner_id, p_event_id, c.tier_id);
    v_left := greatest(c.max_tickets - v_used, 0);
    IF v_want > v_left THEN
      RAISE EXCEPTION 'partner_cap_reached: this partner may hold or sell % more %', v_left,
        CASE WHEN c.tier_id IS NULL THEN 'tickets for this event'
             ELSE 'of ' || coalesce((SELECT name FROM public.exos_ticket_tiers WHERE id = c.tier_id), 'this ticket type') END
        USING ERRCODE = 'EXCAP',
              DETAIL = jsonb_build_object('left', v_left, 'max_tickets', c.max_tickets, 'tier_id', c.tier_id)::text;
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_cap_check(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_cap_check(uuid, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_partner_caps_json(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'partner_id', c.partner_id, 'partner_label', p.label, 'tier_id', c.tier_id, 'tier_name', t.name,
           'max_tickets', c.max_tickets, 'used', u.used, 'left', greatest(c.max_tickets - u.used, 0),
           'updated_at', c.updated_at)
           ORDER BY p.label, p.id, c.tier_id NULLS FIRST, t.sort_order), '[]'::jsonb)
    FROM public.exos_partner_caps c
    JOIN public.exos_distribution_partners p ON p.id = c.partner_id
    LEFT JOIN public.exos_ticket_tiers t ON t.id = c.tier_id
    CROSS JOIN LATERAL (SELECT public._exos_partner_cap_used(c.partner_id, c.event_id, c.tier_id) AS used) u
   WHERE c.event_id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_partner_caps_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_caps_json(uuid) TO service_role;

-- Set caps: [{ partner_id, tier_id?, max_tickets }]; max_tickets null removes
-- that cap. Caps not listed are kept. Internal (owner / manager checked by the
-- callers). A cap below what the partner already holds is allowed: it only
-- stops new reservations.
CREATE OR REPLACE FUNCTION public._exos_partner_caps_set(p_org_id uuid, p_event_id uuid, p_caps jsonb, p_actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r jsonb; v_partner uuid; v_tier uuid; v_max int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_typeof(p_caps) IS DISTINCT FROM 'array' OR jsonb_array_length(p_caps) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'caps must be a list of 1-200 { partner_id, tier_id?, max_tickets }' USING ERRCODE = '22023';
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_caps) LOOP
    IF jsonb_typeof(r) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'each cap is an object { partner_id, tier_id?, max_tickets }' USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_partner := (r->>'partner_id')::uuid;
      v_tier := nullif(r->>'tier_id', '')::uuid;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'partner_id and tier_id must be ids' USING ERRCODE = '22023';
    END;
    IF v_partner IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_distribution_partners
                                         WHERE id = v_partner AND org_id = p_org_id AND revoked_at IS NULL) THEN
      RAISE EXCEPTION 'partner % is not a partner of this organization', coalesce(v_partner::text, '(none)')
        USING ERRCODE = '22023';
    END IF;
    IF v_tier IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE id = v_tier AND event_id = p_event_id) THEN
      RAISE EXCEPTION 'tier % is not a ticket type of this event', v_tier USING ERRCODE = '22023';
    END IF;
    IF NOT (r ? 'max_tickets') THEN
      RAISE EXCEPTION 'send max_tickets (a whole number, or null to remove the cap)' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(r->'max_tickets') = 'null' THEN
      DELETE FROM public.exos_partner_caps
       WHERE partner_id = v_partner AND event_id = p_event_id AND tier_id IS NOT DISTINCT FROM v_tier;
      CONTINUE;
    END IF;
    IF jsonb_typeof(r->'max_tickets') <> 'number' OR (r->>'max_tickets') !~ '^[0-9]{1,6}$'
       OR (r->>'max_tickets')::int > 100000 THEN
      RAISE EXCEPTION 'max_tickets must be a whole number from 0 to 100000' USING ERRCODE = '22023';
    END IF;
    v_max := (r->>'max_tickets')::int;
    UPDATE public.exos_partner_caps SET max_tickets = v_max, updated_by = p_actor
     WHERE partner_id = v_partner AND event_id = p_event_id AND tier_id IS NOT DISTINCT FROM v_tier;
    IF NOT FOUND THEN
      INSERT INTO public.exos_partner_caps (org_id, event_id, partner_id, tier_id, max_tickets, updated_by)
      VALUES (p_org_id, p_event_id, v_partner, v_tier, v_max, p_actor)
      ON CONFLICT DO NOTHING;
      IF NOT FOUND THEN   -- a concurrent insert of the same cap: take the newer number
        UPDATE public.exos_partner_caps SET max_tickets = v_max, updated_by = p_actor
         WHERE partner_id = v_partner AND event_id = p_event_id AND tier_id IS NOT DISTINCT FROM v_tier;
      END IF;
    END IF;
  END LOOP;
  RETURN public._exos_partner_caps_json(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_caps_set(uuid, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_caps_set(uuid, uuid, jsonb, uuid) TO service_role;

-- Signed-in wrappers (the event's partner panel). Owner / manager.
CREATE OR REPLACE FUNCTION public.exos_partner_caps(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_partner_caps_json(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_partner_caps(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_partner_caps(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_set_partner_caps(p_event_id uuid, p_caps jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_partner_caps_set(v_org, p_event_id, p_caps, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_set_partner_caps(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_partner_caps(uuid, jsonb) TO authenticated, service_role;

-- Reserve: after every line and the house cap passed, before the dry run
-- answers (a quote over the cap is refused the same way).
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid, uuid, uuid, uuid, jsonb, jsonb, boolean, boolean)',
  '/* exos: partner cap */',
  $o$  IF p_dry_run THEN
    RETURN jsonb_build_object('event_id', p_event_id,$o$,
  $n$  /* exos: partner cap */ -- mig 20261104200000
  IF p_partner_id IS NOT NULL THEN
    PERFORM public._exos_partner_cap_check(p_partner_id, p_event_id, v_sel);
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object('event_id', p_event_id,$n$, 1);

-- The partner's ticket types: `available` is at most what its cap leaves.
SELECT pg_temp.exos_patch_n('public._exos_partner_ticket_types(uuid, uuid, uuid)',
  '/* exos: partner cap view */',
  $o$                                   END AS avail) a$o$,
  $n$                                   END AS avail0) a0
        CROSS JOIN LATERAL (SELECT CASE   /* exos: partner cap view */ -- mig 20261104200000
                                     WHEN public._exos_partner_cap_left(p_partner_id, t.id) IS NULL THEN a0.avail0
                                     WHEN a0.avail0 IS NULL THEN public._exos_partner_cap_left(p_partner_id, t.id)
                                     ELSE least(a0.avail0, public._exos_partner_cap_left(p_partner_id, t.id))
                                   END AS avail) a$n$, 1);

-- ---------------------------------------------------------------------------
-- 2. Owner approval for staff invites.
-- ---------------------------------------------------------------------------
-- Existing orgs: off (the ADD COLUMN default). New orgs: on.
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS invite_approval boolean NOT NULL DEFAULT false;
ALTER TABLE public.exos_orgs ALTER COLUMN invite_approval SET DEFAULT true;
COMMENT ON COLUMN public.exos_orgs.invite_approval IS
  'A claimed staff invite waits for an owner (or a manager, below manager) to approve it. On for orgs made after mig 20261104200000; off for older ones.';

ALTER TABLE public.exos_org_memberships
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS pending_role text,
  ADD COLUMN IF NOT EXISTS pending_invite uuid,
  ADD COLUMN IF NOT EXISTS pending_since timestamptz,
  ADD COLUMN IF NOT EXISTS approved_by uuid,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_org_memberships_status_chk') THEN
    ALTER TABLE public.exos_org_memberships ADD CONSTRAINT exos_org_memberships_status_chk
      CHECK (status IN ('active', 'pending_approval'));
  END IF;
  -- A pending member has no access: disabled until approved.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_org_memberships_pending_chk') THEN
    ALTER TABLE public.exos_org_memberships ADD CONSTRAINT exos_org_memberships_pending_chk
      CHECK (status <> 'pending_approval' OR (disabled AND pending_role IS NOT NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_org_memberships_pending_role_chk') THEN
    ALTER TABLE public.exos_org_memberships ADD CONSTRAINT exos_org_memberships_pending_role_chk
      CHECK (pending_role IS NULL OR pending_role IN ('manager','finance','scanner','content'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_org_memberships_pending_idx ON public.exos_org_memberships (org_id)
  WHERE pending_role IS NOT NULL;
COMMENT ON COLUMN public.exos_org_memberships.status IS
  'pending_approval: joined through an invite, waiting for approval (disabled meanwhile). mig 20261104200000.';
COMMENT ON COLUMN public.exos_org_memberships.pending_role IS
  'The role a claimed invite asks for, until approved or rejected (exos_org_member_approve / _reject).';

-- Clients (owners editing rows directly) can't approve by flipping columns:
-- the approval columns change only inside the functions, and a pending
-- member can't be re-enabled before approval. A direct role change on a
-- pending row moves the requested role with it.
CREATE OR REPLACE FUNCTION public._exos_tg_membership_approval()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF current_user IN ('anon', 'authenticated') THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.status <> 'active' OR NEW.pending_role IS NOT NULL OR NEW.pending_invite IS NOT NULL
         OR NEW.approved_by IS NOT NULL THEN
        RAISE EXCEPTION 'pending memberships come from a claimed invite' USING ERRCODE = '42501';
      END IF;
    ELSIF (NEW.status, NEW.pending_invite, NEW.pending_since, NEW.approved_by, NEW.approved_at)
          IS DISTINCT FROM (OLD.status, OLD.pending_invite, OLD.pending_since, OLD.approved_by, OLD.approved_at)
       OR (NEW.pending_role IS DISTINCT FROM OLD.pending_role AND OLD.status <> 'pending_approval') THEN
      RAISE EXCEPTION 'approve or reject the member instead (exos_org_member_approve / exos_org_member_reject)'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'pending_approval' AND NEW.status = 'pending_approval' THEN
    IF NEW.disabled IS NOT TRUE THEN
      RAISE EXCEPTION 'this member is waiting for approval; approve them instead of enabling them'
        USING ERRCODE = '22023';
    END IF;
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      IF NEW.role NOT IN ('manager','finance','scanner','content') THEN
        RAISE EXCEPTION 'a pending member can''t be made %', NEW.role USING ERRCODE = '22023';
      END IF;
      NEW.pending_role := NEW.role;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_membership_approval() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_memberships_approval ON public.exos_org_memberships;
CREATE TRIGGER exos_memberships_approval BEFORE INSERT OR UPDATE ON public.exos_org_memberships
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_membership_approval();

-- May the caller decide on this request? Owners always; managers for the
-- roles below manager. Nobody decides their own.
CREATE OR REPLACE FUNCTION public._exos_member_decider(p_org_id uuid, p_user_id uuid, p_role text)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'someone else has to approve your own membership' USING ERRCODE = '42501';
  END IF;
  IF public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN RETURN; END IF;
  IF public.exos_has_org_role(p_org_id, ARRAY['manager']) AND p_role IN ('finance','scanner','content') THEN RETURN; END IF;
  RAISE EXCEPTION 'only an owner can decide this (managers approve finance, content and scanner members)'
    USING ERRCODE = '42501';
END $$;
REVOKE ALL ON FUNCTION public._exos_member_decider(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- The requests waiting in an org, with the account email of whoever claimed
-- each invite next to the address it was sent to (a typo shows). Owner /
-- manager.
CREATE OR REPLACE FUNCTION public.exos_org_pending_members(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb; v_owner boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  v_owner := public.exos_has_org_role(p_org_id, ARRAY['owner']);
  IF to_regclass('public.exos_org_invites') IS NOT NULL THEN
    EXECUTE $q$
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'user_id', m.user_id, 'account_email', lower(u.email),
               'invited_email', i.email, 'role', m.pending_role,
               'current_role', CASE WHEN m.status = 'active' AND m.disabled IS NOT TRUE THEN m.role END,
               'new_member', m.status = 'pending_approval',
               'email_matches', lower(btrim(coalesce(i.email, ''))) = lower(btrim(coalesce(u.email, ''))),
               'invited_by_email', lower(ib.email), 'invited_at', i.created_at, 'claimed_at', m.pending_since,
               'can_decide', m.user_id <> auth.uid() AND ($2 OR m.pending_role IN ('finance','scanner','content')))
             ORDER BY m.pending_since, m.user_id), '[]'::jsonb)
        FROM public.exos_org_memberships m
        LEFT JOIN auth.users u ON u.id = m.user_id
        LEFT JOIN public.exos_org_invites i ON i.token = m.pending_invite
        LEFT JOIN auth.users ib ON ib.id = i.created_by
       WHERE m.org_id = $1 AND m.pending_role IS NOT NULL$q$
      INTO v USING p_org_id, v_owner;
  ELSE
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'user_id', m.user_id, 'account_email', lower(u.email), 'invited_email', NULL, 'role', m.pending_role,
             'current_role', CASE WHEN m.status = 'active' AND m.disabled IS NOT TRUE THEN m.role END,
             'new_member', m.status = 'pending_approval', 'email_matches', NULL,
             'invited_by_email', NULL, 'invited_at', NULL, 'claimed_at', m.pending_since,
             'can_decide', m.user_id <> auth.uid() AND (v_owner OR m.pending_role IN ('finance','scanner','content')))
           ORDER BY m.pending_since, m.user_id), '[]'::jsonb)
      INTO v
      FROM public.exos_org_memberships m
      LEFT JOIN auth.users u ON u.id = m.user_id
     WHERE m.org_id = p_org_id AND m.pending_role IS NOT NULL;
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.exos_org_pending_members(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_pending_members(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_org_member_approve(p_org_id uuid, p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_org_memberships%ROWTYPE;
BEGIN
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = p_org_id AND user_id = p_user_id FOR UPDATE;
  IF m.id IS NULL OR m.pending_role IS NULL THEN
    -- Not found and "not yours to see" look the same to non-staff.
    IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
      RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'nothing is waiting for approval for this member' USING ERRCODE = 'P0002';
  END IF;
  PERFORM public._exos_member_decider(p_org_id, p_user_id, m.pending_role);
  UPDATE public.exos_org_memberships
     SET role = CASE WHEN role = 'owner' THEN role ELSE pending_role END,   -- an invite never demotes an owner
         disabled = false, status = 'active', pending_role = NULL, pending_invite = NULL, pending_since = NULL,
         approved_by = auth.uid(), approved_at = now()
   WHERE id = m.id RETURNING * INTO m;
  RETURN jsonb_build_object('user_id', m.user_id, 'role', m.role, 'status', m.status, 'approved', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_member_approve(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_member_approve(uuid, uuid) TO authenticated;

-- A new member: the membership is deleted. An existing member: they keep
-- what they had and the requested role is dropped.
CREATE OR REPLACE FUNCTION public.exos_org_member_reject(p_org_id uuid, p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_org_memberships%ROWTYPE;
BEGIN
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = p_org_id AND user_id = p_user_id FOR UPDATE;
  IF m.id IS NULL OR m.pending_role IS NULL THEN
    IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
      RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;
    RAISE EXCEPTION 'nothing is waiting for approval for this member' USING ERRCODE = 'P0002';
  END IF;
  PERFORM public._exos_member_decider(p_org_id, p_user_id, m.pending_role);
  IF m.status = 'pending_approval' THEN
    DELETE FROM public.exos_org_memberships WHERE id = m.id;
    RETURN jsonb_build_object('user_id', p_user_id, 'removed', true);
  END IF;
  UPDATE public.exos_org_memberships
     SET pending_role = NULL, pending_invite = NULL, pending_since = NULL
   WHERE id = m.id;
  RETURN jsonb_build_object('user_id', p_user_id, 'removed', false, 'role', m.role);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_member_reject(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_org_member_reject(uuid, uuid) TO authenticated;

-- The org switch. Owner only (exos_orgs_upd lets the owner write the column
-- too; this is the call the dashboard makes).
CREATE OR REPLACE FUNCTION public.exos_set_invite_approval(p_org_id uuid, p_on boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_on IS NULL THEN RAISE EXCEPTION 'send true or false' USING ERRCODE = '22023'; END IF;
  UPDATE public.exos_orgs SET invite_approval = p_on WHERE id = p_org_id;
  RETURN p_on;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_invite_approval(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_invite_approval(uuid, boolean) TO authenticated;

-- exos_claim_invite (when the invites table exists: prod; the offline chain
-- has neither, and test_small_ops.sql applies this to prod's body).
DO $p2$
BEGIN
  IF to_regprocedure('public.exos_claim_invite(uuid)') IS NULL THEN
    RAISE NOTICE 'exos_claim_invite(uuid): not present, invite approval patch skipped';
    RETURN;
  END IF;
  PERFORM pg_temp.exos_patch_n('public.exos_claim_invite(uuid)',
    '/* exos: invite approval */',
    $o$  INSERT INTO public.exos_org_memberships (org_id, user_id, role, added_by)
  VALUES (v_inv.org_id, v_uid, v_inv.role, v_uid)
  ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role, disabled = false
    -- p1: a stale invite never changes a membership edited after it was sent,
    -- and an invite never demotes an owner.
    WHERE exos_org_memberships.role <> 'owner'
      AND exos_org_memberships.updated_at < v_inv.created_at;$o$,
    $n$  /* exos: invite approval */ -- mig 20261104200000: with the org's invite_approval on,
  -- the claim only asks. A new member waits disabled ('pending_approval');
  -- an existing one keeps what they have and the role waits (pending_role).
  -- The same stale-invite and never-demote-an-owner rules as below.
  IF coalesce((SELECT o.invite_approval FROM public.exos_orgs o WHERE o.id = v_inv.org_id), false) THEN
    INSERT INTO public.exos_org_memberships (org_id, user_id, role, added_by, disabled, status,
                                             pending_role, pending_invite, pending_since)
    VALUES (v_inv.org_id, v_uid, v_inv.role, v_uid, true, 'pending_approval', v_inv.role, p_token, now())
    ON CONFLICT (org_id, user_id) DO UPDATE
      SET pending_role = EXCLUDED.pending_role, pending_invite = EXCLUDED.pending_invite,
          pending_since = EXCLUDED.pending_since
      WHERE exos_org_memberships.role <> 'owner'
        AND exos_org_memberships.updated_at < v_inv.created_at;
  ELSE
  INSERT INTO public.exos_org_memberships (org_id, user_id, role, added_by)
  VALUES (v_inv.org_id, v_uid, v_inv.role, v_uid)
  ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role, disabled = false
    -- p1: a stale invite never changes a membership edited after it was sent,
    -- and an invite never demotes an owner.
    WHERE exos_org_memberships.role <> 'owner'
      AND exos_org_memberships.updated_at < v_inv.created_at;
  END IF;$n$, 1);
  -- The inviter's receipt says it waits, and who claimed it.
  PERFORM pg_temp.exos_patch_n('public.exos_claim_invite(uuid)',
    '/* exos: invite approval mail */',
    $o$              '.</p><p>If that isn''t who you meant, remove them under Members.</p>',$o$,
    $n$              CASE WHEN EXISTS (SELECT 1 FROM public.exos_org_memberships pm   /* exos: invite approval mail */
                                 WHERE pm.org_id = v_inv.org_id AND pm.user_id = v_uid AND pm.pending_invite = p_token)
                   THEN '.</p><p><strong>They have no new access until you approve it.</strong> Check the account email '
                        || 'above against the address you meant, then approve or reject under Members: '
                        || '{{app_url}}/orgs/' || v_inv.org_id || '/members</p>'
                   ELSE '.</p><p>If that isn''t who you meant, remove them under Members.</p>' END,$n$, 1);
  PERFORM pg_temp.exos_patch_n('public.exos_claim_invite(uuid)',
    '/* exos: invite approval subject */',
    $o$              left('Your invite to ' || coalesce(v_org, 'your organization') || ' was accepted', 200),$o$,
    $n$              left(CASE WHEN EXISTS (SELECT 1 FROM public.exos_org_memberships pm   /* exos: invite approval subject */
                                      WHERE pm.org_id = v_inv.org_id AND pm.user_id = v_uid AND pm.pending_invite = p_token)
                        THEN 'Approve or reject: your invite to ' || coalesce(v_org, 'your organization') || ' was accepted'
                        ELSE 'Your invite to ' || coalesce(v_org, 'your organization') || ' was accepted' END, 200),$n$, 1);
END $p2$;

-- ---------------------------------------------------------------------------
-- 3. Drawer recount.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_pos_drawer_recounts (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                  uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id                uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  session_id              uuid NOT NULL REFERENCES public.exos_pos_drawer_sessions (id) ON DELETE CASCADE,
  recount_no              integer NOT NULL CHECK (recount_no BETWEEN 1 AND 3),
  expected_cents          integer NOT NULL,
  previous_counted_cents  integer NOT NULL CHECK (previous_counted_cents >= 0),
  previous_variance_cents integer NOT NULL,
  previous_counts         jsonb,
  previous_counted_by     uuid,    -- who made the count this one replaced
  counted_cents           integer NOT NULL CHECK (counted_cents >= 0),
  variance_cents          integer NOT NULL,
  counts                  jsonb,
  reason                  text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 500),
  recounted_by            uuid NOT NULL,
  created_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, recount_no)
);
CREATE INDEX IF NOT EXISTS exos_pos_drawer_recounts_event_idx ON public.exos_pos_drawer_recounts (event_id);
ALTER TABLE public.exos_pos_drawer_recounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_pos_drawer_recounts_staff_read ON public.exos_pos_drawer_recounts;
CREATE POLICY exos_pos_drawer_recounts_staff_read ON public.exos_pos_drawer_recounts
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_pos_drawer_recounts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_pos_drawer_recounts TO authenticated;
GRANT ALL ON public.exos_pos_drawer_recounts TO service_role;
COMMENT ON TABLE public.exos_pos_drawer_recounts IS
  'Each recount of a closed POS drawer and the count it replaced (exos_pos_recount_drawer). Never written by clients. mig 20261104200000.';

CREATE OR REPLACE FUNCTION public.exos_pos_recount_drawer(
  p_session_id uuid, p_counted_cents integer, p_reason text, p_counts jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE d public.exos_pos_drawer_sessions%ROWTYPE; v_sum bigint; v_n int; v_last public.exos_pos_drawer_recounts%ROWTYPE;
        v_reason text := btrim(coalesce(p_reason, '')); v_prev_by uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_pos_recount_drawer: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO d FROM public.exos_pos_drawer_sessions WHERE id = p_session_id FOR UPDATE;
  IF d.id IS NULL OR NOT public.exos_has_org_role(d.org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_pos_recount_drawer: not authorized' USING ERRCODE = '42501';
  END IF;
  IF d.status <> 'closed' OR d.closed_at IS NULL THEN
    RAISE EXCEPTION 'exos_pos_recount_drawer: close the drawer first' USING ERRCODE = '22023';
  END IF;
  IF p_counted_cents IS NULL OR p_counted_cents < 0 THEN
    RAISE EXCEPTION 'exos_pos_recount_drawer: counted amount required' USING ERRCODE = '22023';
  END IF;
  IF length(v_reason) < 3 OR length(v_reason) > 500 THEN
    RAISE EXCEPTION 'exos_pos_recount_drawer: say why it is recounted (3-500 characters)' USING ERRCODE = '22023';
  END IF;
  IF p_counts IS NOT NULL THEN
    IF jsonb_typeof(p_counts) <> 'object' OR EXISTS (
         SELECT 1 FROM jsonb_each_text(p_counts) e
          WHERE e.key !~ '^[1-9][0-9]{0,5}$' OR e.value !~ '^[0-9]{1,6}$') THEN
      RAISE EXCEPTION 'exos_pos_recount_drawer: counts must map denomination cents to whole counts' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(sum(e.key::bigint * e.value::bigint), 0) INTO v_sum FROM jsonb_each_text(p_counts) e;
    IF v_sum <> p_counted_cents THEN
      RAISE EXCEPTION 'exos_pos_recount_drawer: counts add up to %, not %', v_sum, p_counted_cents USING ERRCODE = '22023';
    END IF;
  END IF;
  -- A double tap: the same recount again answers the one already recorded.
  SELECT * INTO v_last FROM public.exos_pos_drawer_recounts
   WHERE session_id = p_session_id ORDER BY recount_no DESC LIMIT 1;
  IF v_last.id IS NOT NULL AND v_last.counted_cents = p_counted_cents AND v_last.reason = v_reason
     AND v_last.counts IS NOT DISTINCT FROM p_counts AND v_last.recounted_by = auth.uid()
     AND v_last.created_at > now() - interval '10 minutes' THEN
    RETURN jsonb_build_object('session_id', d.id, 'recount_no', v_last.recount_no, 'expected_cents', d.expected_cents,
             'counted_cents', d.counted_cents, 'variance_cents', d.variance_cents,
             'previous_counted_cents', v_last.previous_counted_cents, 'recounts_left', 3 - v_last.recount_no,
             'replay', true);
  END IF;
  IF d.closed_at < now() - interval '7 days' THEN
    RAISE EXCEPTION 'exos_pos_recount_drawer: a drawer can be recounted for 7 days after it closed' USING ERRCODE = '55000';
  END IF;
  v_n := coalesce(v_last.recount_no, 0);
  IF v_n >= 3 THEN
    RAISE EXCEPTION 'exos_pos_recount_drawer: this drawer was already recounted 3 times' USING ERRCODE = '55000';
  END IF;
  IF to_regclass('public.exos_pos_settlements') IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.exos_pos_settlements WHERE event_id = d.event_id AND status = 'final') THEN
    RAISE EXCEPTION 'exos_pos_recount_drawer: the event''s settlement is final' USING ERRCODE = '55000';
  END IF;
  v_prev_by := coalesce(v_last.recounted_by, d.closed_by);
  INSERT INTO public.exos_pos_drawer_recounts (org_id, event_id, session_id, recount_no, expected_cents,
    previous_counted_cents, previous_variance_cents, previous_counts, previous_counted_by,
    counted_cents, variance_cents, counts, reason, recounted_by)
  VALUES (d.org_id, d.event_id, d.id, v_n + 1, d.expected_cents,
    d.counted_cents, d.variance_cents, d.counts, v_prev_by,
    p_counted_cents, p_counted_cents - d.expected_cents, p_counts, v_reason, auth.uid());
  UPDATE public.exos_pos_drawer_sessions
     SET counted_cents = p_counted_cents, variance_cents = p_counted_cents - d.expected_cents, counts = p_counts
   WHERE id = d.id;
  RETURN jsonb_build_object('session_id', d.id, 'recount_no', v_n + 1, 'expected_cents', d.expected_cents,
           'counted_cents', p_counted_cents, 'variance_cents', p_counted_cents - d.expected_cents,
           'previous_counted_cents', d.counted_cents, 'recounts_left', 3 - (v_n + 1), 'replay', false);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_recount_drawer(uuid, integer, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_recount_drawer(uuid, integer, text, jsonb) TO authenticated;
