-- ============================================================================
-- Org lifecycle: ownership transfer, leaving a team, one owner always, and
-- ticket-backend switches that can't oversell
-- ============================================================================
-- Touches:  W: TABLE exos_orgs (+ created_by), exos_events (+ ticket_backend_changed_at)
--           C: FUNCTION exos_transfer_org_ownership, exos_leave_org,
--              exos_remove_org_member, exos_org_members (authenticated)
--           C: TRIGGER exos_orgs_owner_guard, exos_org_memberships_guard,
--              exos_org_memberships_owner_check (deferred), exos_orgs_owner_check
--              (deferred) + their functions (internal)
--           R: exos_create_org (records created_by; the caps count it),
--              exos_org_mail_recipients (current active owners only, not a
--              stale owner_uid), exos_set_ticket_backend (refuses a switch
--              while carts, checkouts or marketplace allocations are live;
--              stamps the switch; drops the old platform's door sync)
--           P: exos_delete_my_account (an owner membership blocks too),
--              exos_fulfill_checkout (a session opened after a switch fails and
--              refunds), exos_fulfil_marketplace_order (needs attention),
--              exos_issue_comp_batch, exos_issue_ticket_to_email,
--              exos_mint_tickets, exos_redeem_referral_reward,
--              exos_request_distribution, exos_set_channel_allocation (above
--              0), exos_apply_channel_split (skipped): refused while another
--              platform sells the event
-- Pre-reqs: 20260520120000 (orgs / memberships), 20261016100000 (ticket
--           backends), 20261020090000 + 20261020100000 (exos_delete_my_account)
--
-- Ownership. There was no way to hand an organization over, so an owner could
-- never delete their account. Raw RLS let the owner do it by hand instead, and
-- worse: set owner_uid to anyone (who then got the org's financial mail and
-- the deletion block, and the real owner a fresh 3-a-day org allowance), add
-- any account as a member without an invite, promote or demote owners, and
-- demote the last one (an org nobody owns). Now:
--   * exos_transfer_org_ownership(org, member): the owner (or a platform
--     admin) hands the org to an active member; owner_uid and both membership
--     rows change together and the previous owner stays on as a manager;
--   * client writes (as authenticated / anon, i.e. not inside a definer
--     function) can't change owner_uid / created_by, can't insert a membership
--     (members join through an invite or create the org), and can't touch an
--     owner's membership or make anyone owner; the RLS policies are unchanged;
--   * at commit, an org that loses an active owner must still have one, and a
--     changed owner_uid must be an active owner member;
--   * exos_leave_org (anyone but the owner), exos_remove_org_member (owner),
--     exos_org_members (owner / manager / admin see the team with email and
--     name; anyone else just their own row);
--   * the org caps count the orgs an account created (created_by; rows from
--     before this fall back to owner_uid, which can no longer be re-pointed).
--
-- Ticket backends. An event could move to Eventbrite / pretix / hi.events /
-- Luma with buyers mid-checkout, and comps, staff mints, referral rewards,
-- marketplace sales and allocations kept minting on Exos (two platforms
-- selling one room). A switch away from Exos is now refused while cart holds
-- are live, Stripe checkouts are open (30 min) or marketplaces hold an
-- allocation; checkouts created before the switch still fulfil. Switching
-- also unlinks the old pretix / hi.events / Luma door sync (guests already
-- synced stay on their list).
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, marker-guarded patches). The
-- patch helper skips a function a scratch chain doesn't have (prod has all of
-- them; tests/exos/test_org_lifecycle_p1.sql checks each patch took). D4
-- authors; applying to prod is operator-gated.
-- ============================================================================

-- CRLF-safe patch-in-place (as 20261019120000; a missing function is skipped
-- with a notice, as 20261016100000).
CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  -- Pasted through a browser the patch text can carry CRLF line ends; compare without CRs.
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

ALTER TABLE public.exos_orgs
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL;
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS ticket_backend_changed_at timestamptz;

-- ---------------------------------------------------------------------------
-- 1. Invariants. "Client" = the statement runs as authenticated / anon, not
--    inside a SECURITY DEFINER function (those run as their owner).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_orgs_owner_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon')
     AND (NEW.owner_uid IS DISTINCT FROM OLD.owner_uid OR NEW.created_by IS DISTINCT FROM OLD.created_by) THEN
    RAISE EXCEPTION 'exos_orgs: ownership changes go through exos_transfer_org_ownership' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_orgs_owner_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_orgs_owner_guard ON public.exos_orgs;
CREATE TRIGGER exos_orgs_owner_guard BEFORE UPDATE ON public.exos_orgs
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_orgs_owner_guard();

CREATE OR REPLACE FUNCTION public.exos_tg_memberships_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_OP = 'INSERT' THEN
    RAISE EXCEPTION 'exos_org_memberships: members join through an invite' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF OLD.role = 'owner' THEN
      RAISE EXCEPTION 'exos_org_memberships: the owner can''t be removed; transfer ownership first' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;
  IF NEW.org_id IS DISTINCT FROM OLD.org_id OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'exos_org_memberships: a membership can''t be moved to another person or org' USING ERRCODE = '42501';
  END IF;
  IF OLD.role = 'owner' OR NEW.role = 'owner' THEN
    RAISE EXCEPTION 'exos_org_memberships: ownership changes go through exos_transfer_org_ownership' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_memberships_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_org_memberships_guard ON public.exos_org_memberships;
CREATE TRIGGER exos_org_memberships_guard BEFORE INSERT OR UPDATE OR DELETE ON public.exos_org_memberships
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_memberships_guard();

-- At commit: an org that lost an active owner still has one (a deleted org's
-- memberships cascade away with it, which is fine).
CREATE OR REPLACE FUNCTION public.exos_tg_memberships_owner_check()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.role = 'owner' AND OLD.disabled IS NOT TRUE
     AND (TG_OP = 'DELETE' OR NEW.role <> 'owner' OR NEW.disabled IS TRUE OR NEW.org_id IS DISTINCT FROM OLD.org_id)
     AND EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = OLD.org_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                      WHERE m.org_id = OLD.org_id AND m.role = 'owner' AND m.disabled IS NOT TRUE) THEN
    RAISE EXCEPTION 'exos_org_memberships: an organization needs an active owner; transfer ownership first' USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_memberships_owner_check() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_org_memberships_owner_check ON public.exos_org_memberships;
CREATE CONSTRAINT TRIGGER exos_org_memberships_owner_check
  AFTER UPDATE OR DELETE ON public.exos_org_memberships
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_memberships_owner_check();

-- At commit: a changed owner_uid is an active owner member.
CREATE OR REPLACE FUNCTION public.exos_tg_orgs_owner_check()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.owner_uid IS DISTINCT FROM OLD.owner_uid
     AND EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = NEW.id AND o.owner_uid = NEW.owner_uid)
     AND NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                      WHERE m.org_id = NEW.id AND m.user_id = NEW.owner_uid
                        AND m.role = 'owner' AND m.disabled IS NOT TRUE) THEN
    RAISE EXCEPTION 'exos_orgs: the owner must be an active owner member; use exos_transfer_org_ownership' USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_orgs_owner_check() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_orgs_owner_check ON public.exos_orgs;
CREATE CONSTRAINT TRIGGER exos_orgs_owner_check
  AFTER UPDATE OF owner_uid ON public.exos_orgs
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_orgs_owner_check();

-- ---------------------------------------------------------------------------
-- 2. Handing over, leaving, removing, listing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_transfer_org_ownership(p_org_id uuid, p_new_owner uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o public.exos_orgs%ROWTYPE;
  m public.exos_org_memberships%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_transfer_org_ownership: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO o FROM public.exos_orgs WHERE id = p_org_id FOR UPDATE;
  IF NOT FOUND OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'exos_transfer_org_ownership: only the owner can hand over the organization' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = p_org_id AND user_id = p_new_owner FOR UPDATE;
  IF NOT FOUND OR m.disabled IS TRUE THEN
    RAISE EXCEPTION 'exos_transfer_org_ownership: the new owner must be an active member of the team' USING ERRCODE = '22023';
  END IF;
  IF m.role = 'owner' AND o.owner_uid = p_new_owner THEN
    RAISE EXCEPTION 'exos_transfer_org_ownership: they already own it' USING ERRCODE = '22023';
  END IF;

  -- One owner: everyone else holding the role (the caller included) stays on as a manager.
  UPDATE public.exos_org_memberships SET role = 'manager'
   WHERE org_id = p_org_id AND role = 'owner' AND user_id <> p_new_owner;
  UPDATE public.exos_org_memberships SET role = 'owner' WHERE id = m.id AND role <> 'owner';
  UPDATE public.exos_orgs SET owner_uid = p_new_owner WHERE id = p_org_id;
  RETURN jsonb_build_object('org_id', p_org_id, 'owner_uid', p_new_owner, 'previous_owner_uid', o.owner_uid);
END $$;
REVOKE ALL ON FUNCTION public.exos_transfer_org_ownership(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_transfer_org_ownership(uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_leave_org(p_org_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); m public.exos_org_memberships%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_leave_org: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = p_org_id AND user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_leave_org: you''re not on this team' USING ERRCODE = '22023';
  END IF;
  IF m.role = 'owner' OR EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = p_org_id AND o.owner_uid = v_uid) THEN
    RAISE EXCEPTION 'exos_leave_org: you own this organization; make someone else the owner first' USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.exos_event_staff WHERE org_id = p_org_id AND user_id = v_uid;
  DELETE FROM public.exos_org_memberships WHERE id = m.id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_leave_org(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_leave_org(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_remove_org_member(p_org_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE m public.exos_org_memberships%ROWTYPE;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'exos_remove_org_member: owner only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = p_org_id AND user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_remove_org_member: not on this team' USING ERRCODE = '22023';
  END IF;
  IF m.role = 'owner' OR EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = p_org_id AND o.owner_uid = p_user_id) THEN
    RAISE EXCEPTION 'exos_remove_org_member: the owner can''t be removed' USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.exos_event_staff WHERE org_id = p_org_id AND user_id = p_user_id;
  DELETE FROM public.exos_org_memberships WHERE id = m.id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_remove_org_member(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_remove_org_member(uuid, uuid) TO authenticated, service_role;

-- The Members page: who is on the team. Owner / manager / platform admin see
-- everyone with email and name; any other member just their own row.
CREATE OR REPLACE FUNCTION public.exos_org_members(p_org_id uuid)
RETURNS TABLE (id uuid, user_id uuid, role text, disabled boolean, added_at timestamptz, added_by uuid,
               email text, display_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_all boolean := public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']);
BEGIN
  IF auth.uid() IS NULL OR NOT (v_all OR EXISTS (
       SELECT 1 FROM public.exos_org_memberships x WHERE x.org_id = p_org_id AND x.user_id = auth.uid())) THEN
    RAISE EXCEPTION 'exos_org_members: not on this team' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT m.id, m.user_id, m.role, m.disabled, m.created_at, m.added_by,
           u.email::text, nullif(btrim(p.display_name), '')
      FROM public.exos_org_memberships m
      LEFT JOIN auth.users u ON u.id = m.user_id
      LEFT JOIN public.exos_profiles p ON p.id = m.user_id
     WHERE m.org_id = p_org_id AND (v_all OR m.user_id = auth.uid())
     ORDER BY (m.role = 'owner') DESC, m.created_at, m.user_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_org_members(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_org_members(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Org caps by creator; financial mail to current owners only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_create_org(p_name text, p_slug text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_org_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_org: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR length(btrim(p_name)) = 0 OR length(p_name) > 100 THEN
    RAISE EXCEPTION 'exos_create_org: name must be 1-100 chars';
  END IF;
  IF p_slug !~ '^[a-z0-9][a-z0-9-]{0,79}$' THEN
    RAISE EXCEPTION 'exos_create_org: invalid slug %', p_slug;
  END IF;

  -- rpc hardening (mig 20260929080000): at most 3 new organizations a day and
  -- 20 in all per account; platform admins are exempt. Counted by who created
  -- them (mig 20261021150000; older rows by owner), so handing an org over
  -- doesn't free a slot. The lock serializes one account's concurrent calls
  -- so they can't race past the cap.
  IF NOT public.exos_is_admin() THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_create_org:' || v_uid::text, 0));
    IF (SELECT count(*) FROM public.exos_orgs o
         WHERE coalesce(o.created_by, o.owner_uid) = v_uid AND o.created_at > now() - interval '24 hours') >= 3 THEN
      RAISE EXCEPTION 'exos_create_org: organization limit reached (3 a day). Try again tomorrow, or contact support.'
        USING ERRCODE = '54000';
    END IF;
    IF (SELECT count(*) FROM public.exos_orgs o WHERE coalesce(o.created_by, o.owner_uid) = v_uid) >= 20 THEN
      RAISE EXCEPTION 'exos_create_org: organization limit reached (20 per account). Contact support for more.'
        USING ERRCODE = '54000';
    END IF;
  END IF;

  INSERT INTO public.exos_orgs (name, slug, owner_uid, created_by)
  VALUES (p_name, p_slug, v_uid, v_uid)
  RETURNING id INTO v_org_id;

  INSERT INTO public.exos_org_memberships (org_id, user_id, role, added_by)
  VALUES (v_org_id, v_uid, 'owner', v_uid);

  RETURN v_org_id;
END $function$;

CREATE OR REPLACE FUNCTION public.exos_org_mail_recipients(p_org_id uuid, p_roles text[])
RETURNS TABLE (user_id uuid, email text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  -- Active members in p_roles, plus the active owner(s) (mig 20261021150000:
  -- by membership, not owner_uid, so a removed or disabled owner gets nothing).
  SELECT DISTINCT ON (lower(u.email)) u.id, lower(u.email)
    FROM auth.users u
   WHERE coalesce(u.email, '') <> ''
     AND u.id IN (SELECT m.user_id FROM public.exos_org_memberships m
                   WHERE m.org_id = p_org_id AND m.disabled IS NOT TRUE
                     AND (m.role = 'owner' OR m.role = ANY (p_roles)))
   ORDER BY lower(u.email), u.id
$$;
REVOKE ALL ON FUNCTION public.exos_org_mail_recipients(uuid, text[]) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch_n('public.exos_delete_my_account()', 'exos:owner-membership',
  $o$  IF EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.owner_uid = v_uid) THEN$o$,
  $n$  IF EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.owner_uid = v_uid)
     OR EXISTS (SELECT 1 FROM public.exos_org_memberships m  -- exos:owner-membership
                 WHERE m.user_id = v_uid AND m.role = 'owner' AND m.disabled IS NOT TRUE) THEN$n$,
  1);

-- ---------------------------------------------------------------------------
-- 4. Switching the ticket backend.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_ticket_backend(p_event_id uuid, p_backend text, p_url text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e      public.exos_events%ROWTYPE;
  v_url  text := nullif(btrim(coalesce(p_url, '')), '');
  v_n    bigint;
  v_unlinked boolean := false;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND OR coalesce(public._exos_integ_role(e.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_set_ticket_backend: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_backend IS NULL OR p_backend NOT IN ('exos', 'eventbrite', 'pretix', 'hievents', 'luma') THEN
    RAISE EXCEPTION 'exos_set_ticket_backend: unknown backend' USING ERRCODE = '22023';
  END IF;
  IF p_backend <> 'exos' AND (v_url IS NULL OR v_url !~ '^https://[^\s/]+\.[^\s]+$' OR length(v_url) > 500) THEN
    RAISE EXCEPTION 'exos_set_ticket_backend: give the https link where buyers get tickets' USING ERRCODE = '22023';
  END IF;
  IF p_backend <> 'exos' AND e.tickets_sold > 0 AND e.ticket_backend = 'exos' THEN
    RAISE EXCEPTION 'exos_set_ticket_backend: % tickets were already sold on Exos; keep Exos as the backend for this event', e.tickets_sold
      USING ERRCODE = '22023';
  END IF;
  -- Leaving Exos mid-sale (mig 20261021150000): nobody may be buying here.
  IF p_backend <> 'exos' AND e.ticket_backend = 'exos' THEN
    SELECT coalesce(sum(h.quantity), 0) INTO v_n FROM public.exos_cart_holds h
     WHERE h.event_id = p_event_id AND h.status = 'active' AND h.expires_at > now();
    IF v_n > 0 THEN
      RAISE EXCEPTION 'exos_set_ticket_backend: % tickets are in buyers'' carts right now; try again once they clear (up to 15 minutes)', v_n
        USING ERRCODE = '55006';
    END IF;
    SELECT count(*) INTO v_n FROM public.exos_checkout_sessions s
     WHERE s.event_id = p_event_id AND s.status = 'pending' AND s.created_at > now() - interval '35 minutes';
    IF v_n > 0 THEN
      RAISE EXCEPTION 'exos_set_ticket_backend: % checkouts are still open; try again in half an hour', v_n
        USING ERRCODE = '55006';
    END IF;
    IF to_regclass('public.exos_distribution_listings') IS NOT NULL THEN
      EXECUTE $q$SELECT count(*) FROM public.exos_distribution_listings d
                  WHERE d.event_id = $1 AND coalesce(d.requested_qty, 0) > 0
                    AND d.status IN ('pending', 'planned', 'listing', 'listed', 'delisting')$q$
         INTO v_n USING p_event_id;
      IF v_n > 0 THEN
        RAISE EXCEPTION 'exos_set_ticket_backend: tickets are still allocated to resale marketplaces; set those to 0 first'
          USING ERRCODE = '55006';
      END IF;
    END IF;
  END IF;
  UPDATE public.exos_events
     SET ticket_backend = p_backend, external_ticket_url = CASE WHEN p_backend = 'exos' THEN NULL ELSE v_url END,
         ticket_backend_changed_at = CASE WHEN p_backend IS DISTINCT FROM e.ticket_backend THEN now() ELSE ticket_backend_changed_at END
   WHERE id = p_event_id;
  -- The old platform's door sync stops; guests already synced stay on their list.
  DELETE FROM public.exos_backend_links WHERE event_id = p_event_id AND provider IS DISTINCT FROM p_backend;
  v_unlinked := FOUND;
  RETURN jsonb_build_object('ticket_backend', p_backend, 'external_ticket_url', CASE WHEN p_backend = 'exos' THEN NULL ELSE v_url END,
                            'unlinked', v_unlinked);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_ticket_backend(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_ticket_backend(uuid, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Exos's other ticket paths refuse an event another platform sells.
-- ---------------------------------------------------------------------------
-- Stripe: only a session opened after the switch (it then fails and refunds).
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)', 'exos:backend-mint',
  $o$      RAISE EXCEPTION 'per-account purchase limit exceeded at fulfillment' USING ERRCODE = 'XF001';
    END;
$o$,
  $n$      RAISE EXCEPTION 'per-account purchase limit exceeded at fulfillment' USING ERRCODE = 'XF001';
    END;

    -- exos:backend-mint: the session was opened after the event moved to another platform.
    IF EXISTS (SELECT 1 FROM public.exos_events e
                WHERE e.id = s.event_id AND e.ticket_backend <> 'exos'
                  AND coalesce(s.created_at, now()) > coalesce(e.ticket_backend_changed_at, '-infinity'::timestamptz)) THEN
      RAISE EXCEPTION 'tickets for this event are now sold on another site' USING ERRCODE = 'XF001';
    END IF;
$n$,
  1);

-- Marketplace sale: a person delivers it (the other platform holds the stock).
SELECT pg_temp.exos_patch_n('public.exos_fulfil_marketplace_order(uuid, text)', 'exos:backend-mint',
  $o$    WHEN v_ev.status IS DISTINCT FROM 'published' THEN 'event is ' || coalesce(v_ev.status, 'missing')
$o$,
  $n$    WHEN v_ev.status IS DISTINCT FROM 'published' THEN 'event is ' || coalesce(v_ev.status, 'missing')
    WHEN coalesce(v_ev.ticket_backend, 'exos') <> 'exos' THEN 'tickets for this event are sold on ' || v_ev.ticket_backend || ': deliver by hand'  -- exos:backend-mint
$n$,
  1);

SELECT pg_temp.exos_patch_n('public.exos_issue_comp_batch(uuid, uuid, text[], integer, text)', 'exos:backend-mint',
  $o$    RAISE EXCEPTION 'exos_issue_comp_batch: event is cancelled';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_issue_comp_batch: event is cancelled';
  END IF;
  IF coalesce(v_ev.ticket_backend, 'exos') <> 'exos' THEN  -- exos:backend-mint
    RAISE EXCEPTION 'exos_issue_comp_batch: tickets for this event are sold on another site; issue comps there' USING ERRCODE = '42501';
  END IF;$n$,
  1);

SELECT pg_temp.exos_patch_n('public.exos_issue_ticket_to_email(uuid, uuid, text, integer, text)', 'exos:backend-mint',
  $o$    RAISE EXCEPTION 'exos_issue_ticket_to_email: not authorized' USING ERRCODE = '42501';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_issue_ticket_to_email: not authorized' USING ERRCODE = '42501';
  END IF;
  IF coalesce(v_ev.ticket_backend, 'exos') <> 'exos' THEN  -- exos:backend-mint
    RAISE EXCEPTION 'exos_issue_ticket_to_email: tickets for this event are sold on another site; issue them there' USING ERRCODE = '42501';
  END IF;$n$,
  1);

SELECT pg_temp.exos_patch_n('public.exos_mint_tickets(uuid, uuid, integer, text, numeric, text)', 'exos:backend-mint',
  $o$    RAISE EXCEPTION 'exos_mint_tickets: not authorized for this event' USING ERRCODE = '42501';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_mint_tickets: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND ticket_backend <> 'exos') THEN  -- exos:backend-mint
    RAISE EXCEPTION 'exos_mint_tickets: tickets for this event are sold on another site' USING ERRCODE = '42501';
  END IF;$n$,
  1);

SELECT pg_temp.exos_patch_n('public.exos_redeem_referral_reward(uuid, uuid)', 'exos:backend-mint',
  $o$    RAISE EXCEPTION 'exos_redeem_referral_reward: event not on sale' USING ERRCODE = '42501';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_redeem_referral_reward: event not on sale' USING ERRCODE = '42501';
  END IF;
  IF coalesce(ev.ticket_backend, 'exos') <> 'exos' THEN  -- exos:backend-mint
    RAISE EXCEPTION 'exos_redeem_referral_reward: tickets for this event are sold on another site' USING ERRCODE = '42501';
  END IF;$n$,
  1);

-- Resale distribution: nothing new goes out (setting an allocation to 0 still works).
SELECT pg_temp.exos_patch_n('public.exos_request_distribution(uuid, text[], integer, numeric)', 'exos:backend-mint',
  $o$    RAISE EXCEPTION 'exos_request_distribution: event must be published (is %)', v_status;
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_request_distribution: event must be published (is %)', v_status;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND ticket_backend <> 'exos') THEN  -- exos:backend-mint
    RAISE EXCEPTION 'exos_request_distribution: tickets for this event are sold on another site' USING ERRCODE = '22023';
  END IF;$n$,
  1);

SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid, text, uuid, integer)', 'exos:backend-mint',
  $o$    RAISE EXCEPTION 'exos_set_channel_allocation: event is cancelled';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_set_channel_allocation: event is cancelled';
  END IF;
  IF coalesce(v_ev.ticket_backend, 'exos') <> 'exos' AND p_qty > 0 THEN  -- exos:backend-mint
    RAISE EXCEPTION 'exos_set_channel_allocation: tickets for this event are sold on another site' USING ERRCODE = '22023';
  END IF;$n$,
  1);

-- The T-48h split: skipped and stamped (so it isn't picked again every run).
SELECT pg_temp.exos_patch_n('public.exos_apply_channel_split(uuid)', 'exos:backend-mint',
  $o$    RETURN jsonb_build_object('applied', false, 'reason', 's4k');
  END IF;$o$,
  $n$    RETURN jsonb_build_object('applied', false, 'reason', 's4k');
  END IF;
  IF coalesce(e.ticket_backend, 'exos') <> 'exos' THEN  -- exos:backend-mint
    UPDATE public.exos_events SET channel_split_at = now() WHERE id = p_event_id;
    RETURN jsonb_build_object('applied', false, 'reason', 'other-backend');
  END IF;$n$,
  1);

-- ROLLBACK (manual): drop the four triggers and their functions, the four new
-- RPCs; re-run 20261016100000 §1 (exos_set_ticket_backend), 20260929080000 §6
-- (exos_create_org), 20260929071000 (exos_org_mail_recipients); the patches
-- are additive guards (re-create those functions from their last migration to
-- drop them). The two new columns can stay.
