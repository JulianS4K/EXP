-- ============================================================================
-- Migration 20260926194000 — Exos (Bridge / D4): planned StubHub listings, and
--                            flags for accounts over the per-account limit
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_distribution_listings (+planned_listing)
--              exos_account_limit_flags (new)
--              FUNCTION exos_check_account_limit, exos_review_account_limit_flag,
--                exos_promoter_limit_flags, exos_promoter_note_limit_flag (new)
--              FUNCTION exos_tg_tickets_account_limit
--                + TRIGGER exos_tickets_account_limit ON exos_tickets (new)
--           R: exos_events.purchase_limits, exos_tickets, auth.users,
--              exos_org_memberships, exos_promoters
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
--    marketplace can't: one person can place several orders there. Exos
--    doesn't block those sales; it FLAGS the Exos ACCOUNT once it actually
--    holds more of the event's tickets than maxPerAccount (the sale itself,
--    and tickets still on their way by transfer, never raise a flag). After
--    any change to who holds a ticket (mint, claim, transfer, void)
--    exos_check_account_limit counts the tickets the account owns (not
--    voided, not parked on it for delivery) and records / refreshes a row in
--    exos_account_limit_flags, with the promoter codes those tickets were
--    sold through. The org's own staff are exempt (box office, comps).
--    Nothing is blocked and flags are never deleted by the trigger.
--
--    Review: the organizer (owner / manager) reviews every flag in the org's
--    "Limit flags" tab (exos_review_account_limit_flag). A promoter sees, in
--    their portal, the flags for accounts that bought through their links
--    (email masked) and can leave a note for the organizer
--    (exos_promoter_limit_flags / exos_promoter_note_limit_flag, by kit
--    token). A reviewed flag re-opens when the account goes higher.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_distribution_listings
  ADD COLUMN IF NOT EXISTS planned_listing jsonb;
COMMENT ON COLUMN public.exos_distribution_listings.planned_listing IS
  'Dry-run: the marketplace listing exos-distribute would create for this allocation (display-capped at maxPerOrder). Not sent.';

CREATE TABLE IF NOT EXISTS public.exos_account_limit_flags (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  user_id           uuid NOT NULL,                -- the Exos account
  email             text,                         -- the account's email, for display
  held              integer NOT NULL DEFAULT 0,   -- tickets it holds now
  max_per_account   integer NOT NULL,
  peak              integer NOT NULL DEFAULT 0,   -- most it has held
  promoter_codes    text[] NOT NULL DEFAULT '{}', -- promoters whose links sold those tickets
  first_flagged_at  timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  reviewed_at       timestamptz,
  reviewed_by       uuid,
  review_note       text CHECK (review_note IS NULL OR char_length(review_note) <= 500),
  promoter_note     text CHECK (promoter_note IS NULL OR char_length(promoter_note) <= 500),
  promoter_noted_by text,                         -- promoter code
  promoter_noted_at timestamptz,
  UNIQUE (event_id, user_id)
);
CREATE INDEX IF NOT EXISTS exos_account_limit_flags_org_open_idx
  ON public.exos_account_limit_flags (org_id) WHERE reviewed_at IS NULL;

ALTER TABLE public.exos_account_limit_flags ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_account_limit_flags_sel ON public.exos_account_limit_flags;
CREATE POLICY exos_account_limit_flags_sel ON public.exos_account_limit_flags FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_account_limit_flags FROM anon, authenticated;
GRANT  SELECT ON public.exos_account_limit_flags TO authenticated;

-- ---------------------------------------------------------------------------
-- The check: does this ACCOUNT hold more than the limit? Never raises: a flag
-- must not block a sale, a claim or a transfer.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_check_account_limit(p_event_id uuid, p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org   uuid;
  v_max   int;
  v_held  int;
  v_codes text[];
  v_email text;
BEGIN
  IF p_event_id IS NULL OR p_user_id IS NULL THEN RETURN; END IF;
  SELECT org_id,
         CASE WHEN (purchase_limits ->> 'maxPerAccount') ~ '^[0-9]+$' THEN (purchase_limits ->> 'maxPerAccount')::int END
    INTO v_org, v_max
    FROM public.exos_events WHERE id = p_event_id;
  IF v_max IS NULL OR v_max <= 0 THEN RETURN; END IF;
  -- The organizer's own staff hold tickets for box office / comps.
  IF EXISTS (SELECT 1 FROM public.exos_org_memberships m
              WHERE m.org_id = v_org AND m.user_id = p_user_id AND m.disabled IS NOT TRUE) THEN
    RETURN;
  END IF;

  SELECT count(*), coalesce(array_agg(DISTINCT promoter_id) FILTER (WHERE promoter_id IS NOT NULL), '{}')
    INTO v_held, v_codes
    FROM public.exos_tickets
   WHERE event_id = p_event_id AND owner_id = p_user_id
     AND status <> 'voided' AND pending_transfer_id IS NULL;

  IF v_held > v_max THEN
    SELECT lower(email) INTO v_email FROM auth.users WHERE id = p_user_id;
    INSERT INTO public.exos_account_limit_flags AS f
      (event_id, org_id, user_id, email, held, max_per_account, peak, promoter_codes)
    VALUES (p_event_id, v_org, p_user_id, v_email, v_held, v_max, v_held, v_codes)
    ON CONFLICT (event_id, user_id) DO UPDATE
      SET email = coalesce(EXCLUDED.email, f.email),
          held = EXCLUDED.held,
          max_per_account = EXCLUDED.max_per_account,
          peak = greatest(f.peak, EXCLUDED.held),
          promoter_codes = ARRAY(SELECT DISTINCT unnest(f.promoter_codes || EXCLUDED.promoter_codes) ORDER BY 1),
          last_seen_at = now(),
          -- Went higher than ever after a review: open it again.
          reviewed_at = CASE WHEN EXCLUDED.held > f.peak THEN NULL ELSE f.reviewed_at END;
  ELSE
    -- Back under: keep the flag (history), with honest numbers.
    UPDATE public.exos_account_limit_flags
       SET held = v_held, last_seen_at = now()
     WHERE event_id = p_event_id AND user_id = p_user_id;
  END IF;
EXCEPTION WHEN others THEN
  RAISE WARNING 'exos_check_account_limit(%, %): %', p_event_id, p_user_id, SQLERRM;
END $$;
REVOKE ALL ON FUNCTION public.exos_check_account_limit(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_check_account_limit(uuid, uuid) TO service_role;

-- A ticket changed hands (or was voided): re-count its holder, and the
-- previous holder when it moved.
CREATE OR REPLACE FUNCTION public.exos_tg_tickets_account_limit()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.exos_check_account_limit(NEW.event_id, NEW.owner_id);
  IF TG_OP = 'UPDATE' AND OLD.owner_id IS DISTINCT FROM NEW.owner_id THEN
    PERFORM public.exos_check_account_limit(OLD.event_id, OLD.owner_id);
  END IF;
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_tg_tickets_account_limit() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_tickets_account_limit ON public.exos_tickets;
CREATE TRIGGER exos_tickets_account_limit
  AFTER INSERT OR UPDATE OF owner_id, status, pending_transfer_id ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_tickets_account_limit();

-- ---------------------------------------------------------------------------
-- Organizer review (owner / manager): the org's "Limit flags" tab.
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

-- ---------------------------------------------------------------------------
-- Promoter review, by kit token (the portal has no login): the flags for
-- accounts that bought through this promoter's links. The email is masked
-- (a promoter isn't staff); the promoter can leave a note for the organizer.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_mask_email(p_email text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p_email IS NULL OR position('@' in p_email) < 2 THEN NULL
    ELSE left(p_email, 1) || '***' || substr(p_email, position('@' in p_email))
  END
$$;

CREATE OR REPLACE FUNCTION public.exos_promoter_limit_flags(p_token uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id, 'event_id', f.event_id, 'event_name', e.name, 'starts_at', e.starts_at,
           'buyer', public.exos_mask_email(f.email),
           'held', f.held, 'max_per_account', f.max_per_account, 'peak', f.peak,
           'from_you', (SELECT count(*) FROM public.exos_tickets t
                         WHERE t.event_id = f.event_id AND t.owner_id = f.user_id
                           AND t.promoter_id = p.code AND t.status <> 'voided'),
           'reviewed', f.reviewed_at IS NOT NULL,
           'promoter_note', f.promoter_note)
         ORDER BY (f.reviewed_at IS NULL) DESC, e.starts_at, f.peak DESC), '[]'::jsonb)
    FROM public.exos_promoters p
    JOIN public.exos_account_limit_flags f ON f.org_id = p.org_id AND p.code = ANY (f.promoter_codes)
    JOIN public.exos_events e ON e.id = f.event_id
   WHERE p.kit_token = p_token AND p.status = 'active';
$$;
REVOKE ALL ON FUNCTION public.exos_promoter_limit_flags(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_limit_flags(uuid) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_promoter_note_limit_flag(p_token uuid, p_flag_id uuid, p_note text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_code text;
BEGIN
  SELECT p.code INTO v_code
    FROM public.exos_promoters p
    JOIN public.exos_account_limit_flags f ON f.org_id = p.org_id AND p.code = ANY (f.promoter_codes)
   WHERE p.kit_token = p_token AND p.status = 'active' AND f.id = p_flag_id;
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'exos_promoter_note_limit_flag: not found' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_account_limit_flags
     SET promoter_note = left(nullif(btrim(p_note), ''), 500), promoter_noted_by = v_code, promoter_noted_at = now()
   WHERE id = p_flag_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_note_limit_flag(uuid, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_note_limit_flag(uuid, uuid, text) TO anon, authenticated, service_role;
