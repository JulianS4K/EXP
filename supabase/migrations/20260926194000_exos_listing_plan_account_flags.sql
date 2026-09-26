-- ============================================================================
-- Migration 20260926194000 — Exos (Bridge / D4): planned StubHub listings, and
--                            flags for accounts over the per-account limit
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_distribution_listings (+planned_listing)
--              exos_account_limit_flags (new)
--              FUNCTION exos_check_account_limit, exos_review_account_limit_flag (new)
--              FUNCTION exos_tg_tickets_account_limit, exos_tg_transfers_account_limit
--                + TRIGGER exos_tickets_account_limit ON exos_tickets,
--                  exos_transfers_account_limit ON exos_transfers (new)
--           R: exos_events.purchase_limits, exos_tickets, exos_transfers, auth.users,
--              exos_org_memberships
-- Pre-reqs: 20260926193000 (channel allocations), 20260523180000 (purchase_limits)
--
-- 1. planned_listing: the StubHub listing exos-distribute would create for an
--    allocation (_shared/marketplace/stubhub/listingPlan.ts), dry-run. One
--    listing per allocation, showing buyers at most the event's maxPerOrder
--    at a time (display_number_of_tickets), so one order can't take all of
--    it. A marketplace without that field would need the allocation split
--    into several listings instead: reserved, not built.
--
-- 2. Per-account limit flags. Exos enforces maxPerAccount at checkout, but a
--    marketplace can't: the same person can buy several orders there, under
--    an email we can't tie to them until they claim. So Exos doesn't block;
--    it FLAGS, for the organizer to review later. After any change to who
--    holds a ticket (mint, claim, transfer, void) or a new pending transfer,
--    exos_check_account_limit counts for that email on that event:
--      held      tickets the account owns (not voided), leaving out tickets
--                parked on it for delivery (pending_transfer_id set)
--      incoming  pending transfers to that email (claimable)
--    and when held + incoming > maxPerAccount, records / refreshes a row in
--    exos_account_limit_flags. The org's own staff are exempt (box office and
--    comps park tickets on them). Flags are never deleted by the trigger: the
--    organizer marks them reviewed (exos_review_account_limit_flag).
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_distribution_listings
  ADD COLUMN IF NOT EXISTS planned_listing jsonb;
COMMENT ON COLUMN public.exos_distribution_listings.planned_listing IS
  'Dry-run: the marketplace listing exos-distribute would create for this allocation (display-capped at maxPerOrder). Not sent.';

CREATE TABLE IF NOT EXISTS public.exos_account_limit_flags (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id         uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  email            text NOT NULL CHECK (email = lower(email)),
  user_id          uuid,                      -- the Exos account, once there is one
  held             integer NOT NULL DEFAULT 0,
  incoming         integer NOT NULL DEFAULT 0,
  max_per_account  integer NOT NULL,
  peak             integer NOT NULL DEFAULT 0, -- highest held + incoming seen
  first_flagged_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  reviewed_at      timestamptz,
  reviewed_by      uuid,
  review_note      text CHECK (review_note IS NULL OR char_length(review_note) <= 500),
  UNIQUE (event_id, email)
);
CREATE INDEX IF NOT EXISTS exos_account_limit_flags_open_idx
  ON public.exos_account_limit_flags (event_id) WHERE reviewed_at IS NULL;

ALTER TABLE public.exos_account_limit_flags ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_account_limit_flags_sel ON public.exos_account_limit_flags;
CREATE POLICY exos_account_limit_flags_sel ON public.exos_account_limit_flags FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_account_limit_flags FROM anon, authenticated;
GRANT  SELECT ON public.exos_account_limit_flags TO authenticated;

-- ---------------------------------------------------------------------------
-- The check. Never raises: a flag must not block a sale or a claim.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_check_account_limit(p_event_id uuid, p_email text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_org   uuid;
  v_max   int;
  v_uid   uuid;
  v_held  int := 0;
  v_in    int := 0;
BEGIN
  IF v_email = '' OR p_event_id IS NULL THEN RETURN; END IF;
  SELECT org_id,
         CASE WHEN (purchase_limits ->> 'maxPerAccount') ~ '^[0-9]+$' THEN (purchase_limits ->> 'maxPerAccount')::int END
    INTO v_org, v_max
    FROM public.exos_events WHERE id = p_event_id;
  IF v_max IS NULL OR v_max <= 0 THEN RETURN; END IF;

  SELECT id INTO v_uid FROM auth.users WHERE lower(email) = v_email LIMIT 1;
  -- The organizer's own staff hold tickets for box office / comps.
  IF v_uid IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = v_org AND m.user_id = v_uid AND m.disabled IS NOT TRUE) THEN
    RETURN;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT count(*) INTO v_held FROM public.exos_tickets
     WHERE event_id = p_event_id AND owner_id = v_uid
       AND status <> 'voided' AND pending_transfer_id IS NULL;
  END IF;
  SELECT count(*) INTO v_in
    FROM public.exos_transfers t
    JOIN public.exos_tickets k ON k.id = t.ticket_id
   WHERE k.event_id = p_event_id AND t.status = 'pending'
     AND lower(t.receiver_email) = v_email;

  IF v_held + v_in > v_max THEN
    INSERT INTO public.exos_account_limit_flags AS f
      (event_id, org_id, email, user_id, held, incoming, max_per_account, peak)
    VALUES (p_event_id, v_org, v_email, v_uid, v_held, v_in, v_max, v_held + v_in)
    ON CONFLICT (event_id, email) DO UPDATE
      SET user_id = coalesce(EXCLUDED.user_id, f.user_id),
          held = EXCLUDED.held, incoming = EXCLUDED.incoming,
          max_per_account = EXCLUDED.max_per_account,
          peak = greatest(f.peak, EXCLUDED.peak),
          last_seen_at = now(),
          -- Went over again after a review: open it again.
          reviewed_at = CASE WHEN EXCLUDED.peak > f.peak THEN NULL ELSE f.reviewed_at END;
  ELSE
    -- Keep an existing flag's current numbers honest (it stays for review).
    UPDATE public.exos_account_limit_flags
       SET held = v_held, incoming = v_in, user_id = coalesce(v_uid, user_id), last_seen_at = now()
     WHERE event_id = p_event_id AND email = v_email;
  END IF;
EXCEPTION WHEN others THEN
  RAISE WARNING 'exos_check_account_limit(%, %): %', p_event_id, v_email, SQLERRM;
END $$;
REVOKE ALL ON FUNCTION public.exos_check_account_limit(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_check_account_limit(uuid, text) TO service_role;

-- Who a ticket row now counts against: its holder (by account email).
CREATE OR REPLACE FUNCTION public.exos_tg_tickets_account_limit()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text;
BEGIN
  IF NEW.owner_id IS NOT NULL THEN
    SELECT lower(email) INTO v_email FROM auth.users WHERE id = NEW.owner_id;
    PERFORM public.exos_check_account_limit(NEW.event_id, v_email);
  END IF;
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_tg_tickets_account_limit() FROM PUBLIC, anon, authenticated;

-- A new (or re-opened) pending transfer counts against its receiver.
CREATE OR REPLACE FUNCTION public.exos_tg_transfers_account_limit()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_event uuid;
BEGIN
  IF NEW.status = 'pending' AND NEW.receiver_email IS NOT NULL THEN
    SELECT event_id INTO v_event FROM public.exos_tickets WHERE id = NEW.ticket_id;
    PERFORM public.exos_check_account_limit(v_event, NEW.receiver_email);
  END IF;
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_tg_transfers_account_limit() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_tickets_account_limit ON public.exos_tickets;
CREATE TRIGGER exos_tickets_account_limit
  AFTER INSERT OR UPDATE OF owner_id, status, pending_transfer_id ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_tickets_account_limit();

DROP TRIGGER IF EXISTS exos_transfers_account_limit ON public.exos_transfers;
CREATE TRIGGER exos_transfers_account_limit
  AFTER INSERT OR UPDATE OF status, receiver_email ON public.exos_transfers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_transfers_account_limit();

-- ---------------------------------------------------------------------------
-- The organizer marks a flag reviewed (owner / manager).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_review_account_limit_flag(p_flag_id uuid, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_review_account_limit_flag: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_account_limit_flags WHERE id = p_flag_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_review_account_limit_flag: flag not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_review_account_limit_flag: not authorized' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_account_limit_flags
     SET reviewed_at = now(), reviewed_by = auth.uid(), review_note = left(nullif(btrim(p_note), ''), 500)
   WHERE id = p_flag_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_review_account_limit_flag(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_review_account_limit_flag(uuid, text) TO authenticated;
