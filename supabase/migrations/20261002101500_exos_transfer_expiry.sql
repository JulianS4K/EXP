-- ============================================================================
-- Migration 20261002101500 — Exos (Bridge / D4): transfers and their claim
--                            links expire when the event ends
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_transfers (status adds 'expired'; expired_at)
--              FUNCTION _exos_event_over (new, internal)
--              FUNCTION exos_tg_transfer_expiry (new trigger) on
--                exos_transfers: BEFORE INSERT and BEFORE UPDATE OF status
--              FUNCTION exos_expire_transfers (new, cron / service_role)
--              FUNCTION exos_transfer_claim_preview (replaced: reports
--                'expired' for a pending transfer whose event is over)
--              cron.schedule exos_expire_transfers (hourly at :41, when
--                pg_cron is present)
--           R: exos_events (starts_at, ends_at), exos_tickets
-- Pre-reqs: 20260927010000 (exos_transfer_claim_preview), 20260929010000
--           (claim key), cron_should_fire (Terminal-2, as in 20260926060000).
--
-- Operator decision 2026-10-02: "acceptance link and transfers expire after
-- event end". A pending transfer (Exos-to-Exos, guest checkout, comp,
-- box office or marketplace claim link) can't be claimed once the event is
-- over, and the ticket goes back to whoever sent it.
--
-- "Over" = ends_at, or starts_at + 12 hours when there is no end time (the
-- rule the promoter guest lists already use). An event with no start time
-- never ends. The rule reads the event row at the moment of the check, so a
-- rescheduled event moves its links' expiry with it.
--
-- Enforcement is in triggers on exos_transfers, not in the claim / create
-- functions: those are patched in place by later migrations
-- (pg_temp.exos_patch in 20260925010000, 20260927010000, 20260929010000), and
-- every claim path, keyed or by email, flips the row 'pending' -> 'completed'.
--   * BEFORE UPDATE OF status: 'pending' -> 'completed' on an event that is
--     over raises "this claim link expired when the event ended" (42501, the
--     code the claim page already shows as a message). Nothing changes.
--   * BEFORE INSERT: a signed-in user (auth.uid() set: a holder's transfer, an
--     organizer's comp or box-office issue) can't start a transfer for an
--     event that is over. Service-role inserts (webhook fulfilment) are left
--     alone so a late fulfilment never fails a charge; its link is born
--     expired and the sweep returns the ticket.
--   * exos_expire_transfers(): hourly, marks pending transfers on events that
--     are over 'expired' (expired_at) and clears the ticket's
--     pending_transfer_id so it is the sender's again. Idempotent; the claim
--     trigger already blocks the link in the gap before the sweep runs.
--   * exos_transfer_claim_preview reports 'expired' for such a row right
--     away, so the claim page says so before the sweep.
-- Org invites already carry expires_at (7 days) and are not changed here.
--
-- Re-run safe. D4 authors; applying to prod and the cron are operator-gated.
-- NOT applied.
-- ROLLBACK: cron.unschedule('exos_expire_transfers'); DROP TRIGGER
--   exos_transfers_expiry ON exos_transfers; DROP FUNCTION
--   exos_expire_transfers(int), exos_tg_transfer_expiry(), _exos_event_over(uuid);
--   re-run 20260927010000's exos_transfer_claim_preview; restore the status
--   CHECK without 'expired' once no row uses it.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. When is an event over?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_event_over(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT coalesce(e.ends_at, e.starts_at + interval '12 hours') <= now()
      FROM public.exos_events e
     WHERE e.id = p_event_id), false)
$$;
REVOKE ALL ON FUNCTION public._exos_event_over(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_over(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. 'expired' status + when
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_transfers ADD COLUMN IF NOT EXISTS expired_at timestamptz;

-- Prod has exos_transfers_status_check = ('pending','completed','cancelled')
-- (read 2026-10-02). Replace it with the same name plus 'expired'; drop any
-- other CHECK on status first so a re-run converges.
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT con.conname
      FROM pg_constraint con
     WHERE con.conrelid = 'public.exos_transfers'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) ~ '\mstatus\M'
       AND pg_get_constraintdef(con.oid) !~ 'expired'
  LOOP
    EXECUTE format('ALTER TABLE public.exos_transfers DROP CONSTRAINT %I', c.conname);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_transfers_status_check'
                    AND conrelid = 'public.exos_transfers'::regclass) THEN
    ALTER TABLE public.exos_transfers ADD CONSTRAINT exos_transfers_status_check
      CHECK (status IN ('pending','completed','cancelled','expired'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Triggers: no claim and no new transfer once the event is over
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_transfer_expiry()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_event uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'pending' AND auth.uid() IS NOT NULL THEN
      v_event := coalesce(NEW.event_id, (SELECT t.event_id FROM public.exos_tickets t WHERE t.id = NEW.ticket_id));
      IF public._exos_event_over(v_event) THEN
        RAISE EXCEPTION 'exos_transfer: this event has ended, so its tickets can''t be transferred'
          USING ERRCODE = '22023';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE OF status
  IF OLD.status = 'pending' AND NEW.status = 'completed' THEN
    v_event := coalesce(OLD.event_id, (SELECT t.event_id FROM public.exos_tickets t WHERE t.id = OLD.ticket_id));
    IF public._exos_event_over(v_event) THEN
      RAISE EXCEPTION 'exos_claim_transfer: this claim link expired when the event ended'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  IF NEW.status = 'expired' AND OLD.status IS DISTINCT FROM 'expired' THEN
    NEW.expired_at := coalesce(NEW.expired_at, now());
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_transfer_expiry() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_transfers_expiry ON public.exos_transfers;
CREATE TRIGGER exos_transfers_expiry
  BEFORE INSERT OR UPDATE OF status ON public.exos_transfers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_transfer_expiry();

-- ---------------------------------------------------------------------------
-- 4. Sweep: expire pending transfers on events that are over and give the
--    ticket back to the sender. Service role / cron only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_expire_transfers(p_limit int DEFAULT 1000)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE n int := 0;
BEGIN
  -- session_user: inside SECURITY DEFINER current_user is always the definer.
  IF session_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_expire_transfers: service role only' USING ERRCODE = '42501';
  END IF;
  IF to_regprocedure('public.cron_should_fire(text)') IS NOT NULL THEN
    IF NOT public.cron_should_fire('exos_expire_transfers') THEN
      RETURN 0;
    END IF;
  END IF;

  WITH due AS (
    SELECT tr.id, tr.ticket_id
      FROM public.exos_transfers tr
      JOIN public.exos_tickets t ON t.id = tr.ticket_id
      JOIN public.exos_events e  ON e.id = t.event_id
     WHERE tr.status = 'pending'
       AND coalesce(e.ends_at, e.starts_at + interval '12 hours') <= now()
     ORDER BY tr.created_at
     LIMIT GREATEST(LEAST(coalesce(p_limit, 1000), 10000), 1)
     FOR UPDATE OF tr SKIP LOCKED
  ), expired AS (
    UPDATE public.exos_transfers tr
       SET status = 'expired', expired_at = now(), updated_at = now()
      FROM due
     WHERE tr.id = due.id
    RETURNING tr.id, tr.ticket_id
  ), released AS (
    UPDATE public.exos_tickets t
       SET pending_transfer_id = NULL
      FROM expired x
     WHERE t.id = x.ticket_id AND t.pending_transfer_id = x.id
    RETURNING t.id
  )
  SELECT count(*) INTO n FROM expired;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.exos_expire_transfers(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_expire_transfers(int) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Claim page preview: say 'expired' before the sweep gets to it. Same
--    signature, columns and grants as 20260927010000.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_transfer_claim_preview(p_transfer_id uuid)
RETURNS TABLE (id uuid, status text, event_id uuid, event_title text,
               event_image text, tier_name text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT tr.id,
         CASE WHEN tr.status = 'pending' AND public._exos_event_over(tr.event_id)
              THEN 'expired' ELSE tr.status::text END,
         tr.event_id, tr.event_title, tr.event_image, tr.tier_name, tr.created_at
    FROM public.exos_transfers tr
   WHERE tr.id = p_transfer_id;
$$;

-- ---------------------------------------------------------------------------
-- 6. Cron, hourly at :41 (off the busy marks). Guarded so a preview branch /
--    CI Postgres without pg_cron applies.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos_expire_transfers') THEN
      PERFORM cron.unschedule('exos_expire_transfers');
    END IF;
    PERFORM cron.schedule('exos_expire_transfers', '41 * * * *',
                          $cron$SELECT public.exos_expire_transfers();$cron$);
  END IF;
END $$;
