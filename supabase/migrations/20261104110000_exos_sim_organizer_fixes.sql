-- ============================================================================
-- Organizer mistake simulations: fixes (tests/exos/sim_organizer.sql).
-- Each fix is a guard on a write the dashboard makes straight to a table
-- (as `authenticated`, under the phase-1 RLS policies) or a small RPC change.
-- Definer functions and the service role are not affected unless a section
-- says so. Additive and replay-safe (CREATE OR REPLACE, DROP TRIGGER IF EXISTS).
--
--   1. Capacity below sold. A ticket type's capacity, or the event's overall
--      cap, can't be set below what has already sold (0 still means no cap).
--      It used to save, and the editor showed "4 of 2 sold".
--   2. Un-cancelling. A cancelled event can't be put back on sale by a
--      table write (exos_publish_event already refuses; the dashboard's
--      status field didn't). Holders were told and refunded; a new date is
--      a new event.
--   3. The last owner. An owner can't remove, disable or demote the last
--      active owner of an org (the org would have no one who can manage
--      members, payouts or the org itself).
--   4. Box-office tickets on a cancelled event. exos_issue_ticket_to_email
--      minted tickets for a cancelled event (the comp batch already refused).
--   5. Relinking Eventbrite. Linking an event to a different Eventbrite event
--      voids the door entries the old link synced (not yet arrived), so the
--      wrong event's attendees can't be admitted. Linking back restores them
--      on the next sync (it sends them again, not voided).
-- ============================================================================

-- ── 1. Capacity below sold ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.exos_tg_capacity_floor()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF current_user NOT IN ('anon', 'authenticated') THEN
    RETURN NEW;
  END IF;
  IF TG_TABLE_NAME = 'exos_ticket_tiers' THEN
    IF NEW.capacity IS DISTINCT FROM OLD.capacity AND NEW.capacity > 0 AND NEW.capacity < NEW.sold THEN
      RAISE EXCEPTION 'exos: "%" has already sold %; its capacity can''t be lower (set it to % to stop sales)',
        coalesce(NEW.name, 'this ticket type'), NEW.sold, NEW.sold USING ERRCODE = '23514';
    END IF;
  ELSE
    IF NEW.total_tickets IS DISTINCT FROM OLD.total_tickets AND NEW.total_tickets > 0 AND NEW.total_tickets < NEW.tickets_sold THEN
      RAISE EXCEPTION 'exos: this event has already sold % tickets; its overall cap can''t be lower (set it to % to stop sales)',
        NEW.tickets_sold, NEW.tickets_sold USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_capacity_floor() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_ticket_tiers_capacity_floor ON public.exos_ticket_tiers;
CREATE TRIGGER exos_ticket_tiers_capacity_floor
  BEFORE UPDATE OF capacity ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_capacity_floor();
DROP TRIGGER IF EXISTS exos_events_capacity_floor ON public.exos_events;
CREATE TRIGGER exos_events_capacity_floor
  BEFORE UPDATE OF total_tickets ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_capacity_floor();

-- ── 2. Un-cancelling ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.exos_tg_event_stay_cancelled()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF current_user IN ('anon', 'authenticated')
     AND OLD.status = 'cancelled' AND NEW.status IS DISTINCT FROM 'cancelled' THEN
    RAISE EXCEPTION 'exos: this event was cancelled (holders were told and refunded); a cancelled event stays cancelled. Make a new event for a new date.'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_stay_cancelled() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_events_stay_cancelled ON public.exos_events;
CREATE TRIGGER exos_events_stay_cancelled
  BEFORE UPDATE OF status ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_stay_cancelled();

-- ── 3. The last owner ───────────────────────────────────────────────────────
-- Client writes only (the dashboard's member editor, under the owner-only
-- RLS policies). The owner rows are locked first, so two owners removing
-- each other at once can't both win. Account deletion and admin tooling run
-- as definer / service role and keep their own rules.
CREATE OR REPLACE FUNCTION public.exos_tg_membership_last_owner()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF current_user NOT IN ('anon', 'authenticated') THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF OLD.role = 'owner' AND OLD.disabled IS NOT TRUE
     AND (TG_OP = 'DELETE' OR NEW.role IS DISTINCT FROM 'owner' OR NEW.disabled IS TRUE
          OR NEW.org_id IS DISTINCT FROM OLD.org_id OR NEW.user_id IS DISTINCT FROM OLD.user_id) THEN
    PERFORM 1 FROM public.exos_org_memberships
     WHERE org_id = OLD.org_id AND role = 'owner' AND disabled IS NOT TRUE
     ORDER BY id FOR UPDATE;
    IF NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                    WHERE m.org_id = OLD.org_id AND m.id <> OLD.id
                      AND m.role = 'owner' AND m.disabled IS NOT TRUE) THEN
      RAISE EXCEPTION 'exos: this is the organization''s last owner; make someone else an owner first'
        USING ERRCODE = '55000';
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_membership_last_owner() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_memberships_last_owner ON public.exos_org_memberships;
CREATE TRIGGER exos_memberships_last_owner
  BEFORE UPDATE OR DELETE ON public.exos_org_memberships
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_membership_last_owner();

-- ── 4. Box-office tickets on a cancelled event ─────────────────────────────
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

SELECT pg_temp.exos_patch_n('public.exos_issue_ticket_to_email(uuid, uuid, text, integer, text)',
  '/* exos: not on a cancelled event */',
  $o$    RAISE EXCEPTION 'exos_issue_ticket_to_email: not authorized' USING ERRCODE = '42501';
  END IF;
$o$,
  $n$    RAISE EXCEPTION 'exos_issue_ticket_to_email: not authorized' USING ERRCODE = '42501';
  END IF;
  /* exos: not on a cancelled event */ -- mig 20261104110000 (the comp batch already refuses).
  IF v_ev.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: event is cancelled' USING ERRCODE = '55000';
  END IF;
$n$, 1);

-- ── 5. Relinking Eventbrite ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.exos_tg_eventbrite_relink_void()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.eb_event_id IS DISTINCT FROM OLD.eb_event_id THEN
    UPDATE public.exos_guest_list_entries g
       SET voided_at = now(), void_reason = 'relinked to another Eventbrite event'
     WHERE g.event_id = NEW.event_id AND g.external_ref LIKE 'eb:%'
       AND g.voided_at IS NULL AND g.arrived = 0;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_eventbrite_relink_void() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_eventbrite_links_relink_void ON public.exos_eventbrite_links;
CREATE TRIGGER exos_eventbrite_links_relink_void
  AFTER UPDATE OF eb_event_id ON public.exos_eventbrite_links
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_eventbrite_relink_void();
