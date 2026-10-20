-- ============================================================================
-- Organizer P1: a cancelled event stays cancelled; Stripe Connect state for staff
-- ============================================================================
-- Touches:  C: FUNCTION exos_tg_event_cancelled_final (trigger fn, no client
--              grant) + TRIGGER exos_events_cancelled_final
--           C: FUNCTION exos_org_payments_ready(uuid) (authenticated)
-- Pre-reqs: 20260929071000 (_exos_org_payments_ready)
--
-- 1. Edit Event offered "Mark as published" on a cancelled event, and nothing
--    on the server refused it: the event went back on sale after every holder
--    had been emailed that it was off (and refunds may already be running).
--    Cancelled is now final for every caller, the service role included: a
--    BEFORE UPDATE trigger refuses cancelled → draft / published. Other
--    columns of a cancelled event can still be edited. (An operator undoing a
--    mistaken cancellation sets exos.uncancel_ok to the event id first:
--    SELECT set_config('exos.uncancel_ok', '<event id>', true).)
--
-- 2. Publishing paid tiers before Stripe Connect can take payments sends
--    buyers into a refused checkout, and only owners / finance can read
--    exos_org_secrets. exos_org_payments_ready tells any org staff member
--    (owner, manager, finance, content) whether the org's Stripe account can
--    take payments, nothing else, so the editor can warn before publishing.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cancelled is final
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_event_cancelled_final()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  -- exos.uncancel_ok = the event id: an operator (SQL console) undoing a
  -- mistaken cancellation. Clients can't set it (PostgREST sets only request.*).
  IF OLD.status = 'cancelled' AND NEW.status IS DISTINCT FROM 'cancelled'
     AND coalesce(current_setting('exos.uncancel_ok', true), '') <> NEW.id::text THEN
    RAISE EXCEPTION 'exos_events: a cancelled event can''t be published or moved back to draft (its ticket holders were told it is off). Create a new event instead.'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_cancelled_final() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_cancelled_final ON public.exos_events;
CREATE TRIGGER exos_events_cancelled_final BEFORE UPDATE OF status ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_cancelled_final();

-- ---------------------------------------------------------------------------
-- 2. Can this org take payments? (org staff)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_org_payments_ready(p_org_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_org_payments_ready: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager','finance','content']) THEN
    RAISE EXCEPTION 'exos_org_payments_ready: not a member of this organization' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_org_payments_ready(p_org_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_payments_ready(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_org_payments_ready(uuid) TO authenticated;
COMMENT ON FUNCTION public.exos_org_payments_ready(uuid) IS
  'Org staff: true when the org''s Stripe Connect account can take payments (exos_org_secrets.payments.chargesEnabled). mig 20261021110000.';
