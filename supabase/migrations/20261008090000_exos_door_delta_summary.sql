-- ============================================================================
-- Door: roster delta + end-of-night door summary (KANBAN "Next to build" #1)
-- ============================================================================
-- Touches:  C: FUNCTION exos_event_checkin_roster_since(uuid, timestamptz)
--           C: FUNCTION exos_event_door_summary(uuid)
--           W: TRIGGER exos_tickets_touch / exos_transfers_touch (created
--              only when missing; prod has both, the harness doesn't)
--           R: exos_events, exos_tickets, exos_transfers, exos_profiles,
--              exos_event_checkins, exos_checkin_lists, exos_scan_rejects,
--              exos_org_memberships, exos_event_staff (exos_can_door_event)
-- Pre-reqs: 20260929140000 (door lists: the roster this mirrors, direction,
--           forced, conflict, gate), 20260929041000 (exos_can_door_event),
--           20260929040000 (device, override_reason, offline_scanned_at)
--
-- 1. exos_event_checkin_roster_since(event, since): the same rows and columns
--    as exos_event_checkin_roster, only for tickets that changed at or after
--    `since`: the ticket row (status, owner, secret, transfer lock, name), its
--    pending transfer (claim name / email), its holder's profile name, or a
--    check-in row scanned since (re-entry list state). The door asked for
--    the whole roster every minute; now it asks for what changed and does a
--    full pull every few minutes as a backstop (lib/door/roster).
--    The cursor is the caller's job: read exos_server_time() BEFORE the call
--    and pass it back, minus an overlap, next time (rows written by a
--    transaction that started before the cursor but committed after it carry
--    the earlier time). Same gate as the roster: door roles assigned to the
--    event. A `since` more than 7 days back is refused (do a full pull).
--    Things the delta can't see, covered by the full pull: a list's re-entry
--    switch, a list deleted, an org role change that un-parks a ticket.
-- 2. exos_event_door_summary(event) -> jsonb: the end-of-night door report.
--    Tickets (sold, checked in, no-shows, voided), entries (first entries,
--    re-entries, exits, forced, offline, by verification), first / last
--    entry, the busiest 15 minutes, entries per hour in the event's time
--    zone, by ticket type, by list / gate, by staff member (entries and
--    refused scans), manual overrides by reason, offline conflicts by
--    reason, refused scans by reason, and "inside now" when the event has a
--    re-entry list (everyone who came in, minus those whose latest scan on
--    a re-entry list was an exit). No buyer names or emails; staff appear by display name
--    or masked email. Owner / manager / finance of the org, door staff
--    assigned to the event, or a platform admin.
--
-- Re-run safe (CREATE OR REPLACE, triggers only when missing). D4 authors;
-- applying to prod is operator-gated. Not applied to prod.
-- ============================================================================

-- The delta relies on updated_at moving on every ticket / transfer update.
DO $$
DECLARE t text;
BEGIN
  IF to_regprocedure('public.exos_touch_updated_at()') IS NULL THEN
    RAISE NOTICE 'exos_touch_updated_at() missing: touch triggers not created';
    RETURN;
  END IF;
  FOREACH t IN ARRAY ARRAY['exos_tickets','exos_transfers'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = ('public.' || t)::regclass AND tgname = t || '_touch' AND NOT tgisinternal) THEN
      EXECUTE format(
        'CREATE TRIGGER %I BEFORE UPDATE ON public.%I
           FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
    END IF;
  END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS exos_tickets_event_updated_idx ON public.exos_tickets (event_id, updated_at);
CREATE INDEX IF NOT EXISTS exos_event_checkins_event_scanned_idx ON public.exos_event_checkins (event_id, scanned_at);

-- ---------------------------------------------------------------------------
-- 1. Roster delta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_checkin_roster_since(p_event_id uuid, p_since timestamptz)
RETURNS TABLE (
  ticket_id           uuid,
  status              text,
  owner_id            uuid,
  owner_name          text,
  tier_name           text,
  barcode_secret      text,
  promoter_id         text,
  pending_transfer_id uuid,
  parked              boolean,
  claim_name          text,
  claim_email_masked  text,
  tier_id             uuid,
  list_state          jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_checkin_roster_since: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_since IS NULL OR p_since < now() - interval '7 days' THEN
    RAISE EXCEPTION 'exos_event_checkin_roster_since: since must be within 7 days (do a full pull)'
      USING ERRCODE = '22023';
  END IF;

  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_event_checkin_roster_since: event not found';
  END IF;
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_event_checkin_roster_since: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_event_checkin_roster_since: not assigned to this event' USING ERRCODE = '42501';
  END IF;

  -- Same projection as exos_event_checkin_roster (mig 20260929140000).
  RETURN QUERY
    SELECT t.id, t.status, t.owner_id,
           CASE WHEN pk.parked
                THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), ''),
                              public.exos_mask_email(lower(btrim(tr.receiver_email))), 'Unclaimed ticket')
                ELSE coalesce(nullif(t.attendee_name, ''), p.display_name) END,
           t.tier_name, t.barcode_secret, t.promoter_id, t.pending_transfer_id,
           pk.parked,
           CASE WHEN pk.parked THEN coalesce(nullif(t.attendee_name, ''), nullif(btrim(tr.receiver_name), '')) END,
           CASE WHEN pk.parked THEN public.exos_mask_email(lower(btrim(tr.receiver_email))) END,
           t.tier_id,
           (SELECT jsonb_object_agg(x.list_id, x.direction)
              FROM (SELECT DISTINCT ON (ci.list_id) ci.list_id, ci.direction
                      FROM public.exos_event_checkins ci
                      JOIN public.exos_checkin_lists l ON l.id = ci.list_id AND l.allow_reentry
                     WHERE ci.ticket_id = t.id
                     ORDER BY ci.list_id, coalesce(ci.offline_scanned_at, ci.scanned_at) DESC, ci.scanned_at DESC) x)
    FROM public.exos_tickets t
    LEFT JOIN public.exos_profiles p ON p.id = t.owner_id
    LEFT JOIN public.exos_transfers tr ON tr.id = t.pending_transfer_id
    CROSS JOIN LATERAL (SELECT (t.pending_transfer_id IS NOT NULL AND public._exos_ticket_parked(t, tr)) AS parked) pk
    WHERE t.event_id = p_event_id
      AND (t.updated_at >= p_since
           OR tr.updated_at >= p_since
           OR p.updated_at >= p_since
           OR t.id IN (SELECT ci.ticket_id FROM public.exos_event_checkins ci
                        WHERE ci.event_id = p_event_id AND ci.scanned_at >= p_since));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_checkin_roster_since(uuid, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_event_checkin_roster_since(uuid, timestamptz) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. End-of-night door summary.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_door_summary(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e   public.exos_events%ROWTYPE;
  v_tz text;
  v_out jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_door_summary: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'exos_event_door_summary: event not found';
  END IF;
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(e.org_id, ARRAY['owner','manager','finance'])
          OR (public.exos_has_org_role(e.org_id, ARRAY['scanner']) AND public.exos_can_door_event(p_event_id))) THEN
    RAISE EXCEPTION 'exos_event_door_summary: not authorized for this event' USING ERRCODE = '42501';
  END IF;

  v_tz := CASE WHEN e.timezone IS NOT NULL AND EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = e.timezone)
               THEN e.timezone ELSE 'UTC' END;

  WITH
  tk AS (
    SELECT t.id, t.status, coalesce(nullif(t.tier_name, ''), 'Standard') AS tier
      FROM public.exos_tickets t
     WHERE t.event_id = p_event_id AND t.status <> 'transferred'
  ),
  ci AS (
    SELECT c.*, coalesce(c.offline_scanned_at, c.scanned_at) AS at
      FROM public.exos_event_checkins c
     WHERE c.event_id = p_event_id
  ),
  ent AS (SELECT * FROM ci WHERE direction = 'entry'),
  -- Each ticket's first entry (forced ones count: they came in).
  first_ent AS (
    SELECT DISTINCT ON (ticket_id) ticket_id, at, forced
      FROM ent ORDER BY ticket_id, at, scanned_at
  ),
  rj AS (
    SELECT r.* FROM public.exos_scan_rejects r WHERE r.event_id = p_event_id
  ),
  staff AS (
    SELECT u.uid,
           coalesce(nullif(btrim(p.display_name), ''),
                    public.exos_mask_email(lower(btrim(coalesce(em.email, au.email)))),
                    'Staff ' || left(u.uid::text, 4)) AS label
      FROM (SELECT scanned_by AS uid FROM ci WHERE scanned_by IS NOT NULL
            UNION
            SELECT rejected_by FROM rj WHERE rejected_by IS NOT NULL) u
      LEFT JOIN (SELECT scanned_by AS uid, max(scanned_by_email) AS email FROM ci GROUP BY 1) em ON em.uid = u.uid
      LEFT JOIN auth.users au ON au.id = u.uid
      LEFT JOIN public.exos_profiles p ON p.id = u.uid
  ),
  inside AS (
    -- Venue-wide: every ticket that came in, minus those whose latest scan
    -- on a re-entry list was an exit (stepped out and not back yet).
    SELECT (SELECT count(*) FROM first_ent)
         - (SELECT count(*) FROM (
              SELECT DISTINCT ON (c.ticket_id) c.direction
                FROM ci c JOIN public.exos_checkin_lists l ON l.id = c.list_id AND l.allow_reentry
               ORDER BY c.ticket_id, c.at DESC, c.scanned_at DESC) x
             WHERE x.direction = 'exit') AS n
  )
  SELECT jsonb_build_object(
    'event', jsonb_build_object(
      'id', e.id, 'name', e.name, 'status', e.status, 'timezone', v_tz,
      'starts_at', e.starts_at, 'doors_at', e.doors_at, 'ends_at', e.ends_at),
    'generated_at', now(),
    'tickets', jsonb_build_object(
      'sold',       (SELECT count(*) FROM tk WHERE status IN ('active','used')),
      'voided',     (SELECT count(*) FROM tk WHERE status = 'voided'),
      'checked_in', (SELECT count(*) FROM first_ent fe JOIN tk ON tk.id = fe.ticket_id AND tk.status IN ('active','used')),
      'no_shows',   (SELECT count(*) FROM tk WHERE status IN ('active','used')
                        AND NOT EXISTS (SELECT 1 FROM first_ent fe WHERE fe.ticket_id = tk.id)),
      'voided_entered', (SELECT count(*) FROM first_ent fe JOIN tk ON tk.id = fe.ticket_id AND tk.status = 'voided')),
    'entries', jsonb_build_object(
      'total',      (SELECT count(*) FROM ent),
      'first',      (SELECT count(*) FROM first_ent),
      'reentries',  (SELECT count(*) FROM ent) - (SELECT count(*) FROM first_ent),
      'exits',      (SELECT count(*) FROM ci WHERE direction = 'exit'),
      'forced',     (SELECT count(*) FROM ent WHERE forced),
      'offline',    (SELECT count(*) FROM ent WHERE offline_scanned_at IS NOT NULL),
      'by_verification', coalesce((SELECT jsonb_object_agg(v, n) FROM (
                       SELECT coalesce(verification, 'unknown') AS v, count(*) AS n
                         FROM ent WHERE NOT forced GROUP BY 1) x), '{}'::jsonb)),
    'first_entry_at', (SELECT min(at) FROM ent),
    'last_entry_at',  (SELECT max(at) FROM ent),
    'peak', (SELECT jsonb_build_object('start', to_timestamp(b * 900), 'entries', n)
               FROM (SELECT floor(extract(epoch FROM at) / 900)::bigint AS b, count(*) AS n
                       FROM ent GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 1) x),
    'by_hour', coalesce((SELECT jsonb_agg(jsonb_build_object('hour', to_char(h, 'YYYY-MM-DD"T"HH24:00'), 'entries', n) ORDER BY h)
                  FROM (SELECT date_trunc('hour', at AT TIME ZONE v_tz) AS h, count(*) AS n FROM ent GROUP BY 1) x),
                '[]'::jsonb),
    'by_tier', coalesce((SELECT jsonb_agg(jsonb_build_object('tier', tier, 'sold', sold, 'checked_in', inn) ORDER BY sold DESC, tier)
                  FROM (SELECT tk.tier,
                               count(*) FILTER (WHERE tk.status IN ('active','used')) AS sold,
                               count(fe.ticket_id) FILTER (WHERE tk.status IN ('active','used')) AS inn
                          FROM tk LEFT JOIN first_ent fe ON fe.ticket_id = tk.id
                         GROUP BY tk.tier) x
                 WHERE sold > 0 OR inn > 0), '[]'::jsonb),
    'by_list', coalesce((SELECT jsonb_agg(jsonb_build_object('list', g, 'entries', en, 'exits', ex) ORDER BY en DESC, g)
                  FROM (SELECT coalesce(nullif(btrim(gate), ''), 'No list') AS g,
                               count(*) FILTER (WHERE direction = 'entry') AS en,
                               count(*) FILTER (WHERE direction = 'exit') AS ex
                          FROM ci GROUP BY 1) x), '[]'::jsonb),
    'by_staff', coalesce((SELECT jsonb_agg(jsonb_build_object('staff', s.label, 'entries', coalesce(a.en, 0),
                                                              'refused', coalesce(b.n, 0)) ORDER BY coalesce(a.en, 0) DESC, s.label)
                   FROM staff s
                   LEFT JOIN (SELECT scanned_by AS uid, count(*) AS en FROM ent GROUP BY 1) a ON a.uid = s.uid
                   LEFT JOIN (SELECT rejected_by AS uid, count(*) AS n FROM rj GROUP BY 1) b ON b.uid = s.uid),
                 '[]'::jsonb),
    'overrides', coalesce((SELECT jsonb_agg(jsonb_build_object('reason', r, 'count', n) ORDER BY n DESC, r)
                   FROM (SELECT coalesce(nullif(btrim(override_reason), ''), 'No reason given') AS r, count(*) AS n
                           FROM ent WHERE verification = 'manual' AND NOT forced GROUP BY 1) x), '[]'::jsonb),
    'conflicts', coalesce((SELECT jsonb_agg(jsonb_build_object('reason', conflict, 'count', n) ORDER BY n DESC, conflict)
                   FROM (SELECT conflict, count(*) AS n FROM ent WHERE forced GROUP BY 1) x), '[]'::jsonb),
    'refused', jsonb_build_object(
      'total', (SELECT count(*) FROM rj),
      'by_reason', coalesce((SELECT jsonb_agg(jsonb_build_object('reason', reason, 'count', n) ORDER BY n DESC, reason)
                     FROM (SELECT reason, count(*) AS n FROM rj GROUP BY 1) x), '[]'::jsonb)),
    'inside_now', CASE WHEN EXISTS (SELECT 1 FROM public.exos_checkin_lists l
                                     WHERE l.event_id = p_event_id AND l.allow_reentry)
                       THEN (SELECT n FROM inside) END
  ) INTO v_out;

  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_door_summary(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_event_door_summary(uuid) TO authenticated, service_role;
