-- ============================================================================
-- Migration 20261113120000 — Exos: attendance report (postal rollup, daily
--   pacing against a prior event, XLSX export kinds). Wave 13.
-- ============================================================================
-- Branch: claude/exos-attendance-report
--
-- Two RFP asks: a demographic report by postal code (Coconino County) and
-- sales pacing (UT). docs/fans.md "Attendance report", docs/api/attendance.json.
--
-- 1. Postal rollup. Where an event's attendees are, by billing postal area:
--    the postal code Stripe / PayPal gave at payment, already recorded per
--    order since 20261106140000 (exos_order_locations.postal_code, no
--    backfill needed, nothing new collected). Aggregate only:
--      * one row per (country, postal area) with buyers, orders, live
--        tickets (active / used) and checked in (used);
--      * a postal area with FEWER THAN 5 distinct buyers is never named:
--        its orders fold into one "Other (fewer than 5)" row;
--      * orders with no postal code (free orders, card-country-only
--        locations, orders from before locations were recorded) are one
--        "No postal code" row; live tickets with no order (door sales,
--        imports) are a count;
--      * the area is coarsened before grouping (_exos_postal_area): US ZIP+4
--        to the 5-digit ZIP, Canada to the forward sortation area (first 3),
--        the UK to the outward code; elsewhere the code as recorded.
--    No per-buyer row, no email, no city, no street.
-- 2. Daily pacing. Per day of sale, in the event's time zone: paid orders,
--    paid tickets and gross (amount charged + gift card part, integer
--    cents, before refunds), and $0 orders (free claims, comps, RSVPs,
--    pass / member redemptions) with their tickets counted separately and
--    never in gross; running totals; days before the event (sales on or
--    after the event day fold into day 0). The same for a chosen comparison
--    event of the SAME org, so the two line up by days before the event.
--    On-sale = the earlier of the first tier sales_start and the first sale.
--    The org's other events that started before this one are listed to
--    pick from (at most 50, newest first).
-- 3. Reads, all owner / manager / finance (role checked in SQL):
--      * exos_event_attendance(event, compare): the dashboard (signed in;
--        or a platform admin). 20 a minute per user (exos_rate_hit). An
--        unknown event and another org's event both answer 42501 (no
--        existence oracle); a comparison event outside the org is P0002
--        "comparison event not found" (nothing about it echoed).
--      * _exos_api_attendance(org, event, compare, cred kind, cred id,
--        user): exos-api GET /v1/events/:id/attendance (orders:read). An
--        org API key acts as its creator, who must be owner / manager /
--        finance now (_exos_api_key_actor); a personal / OAuth token's user
--        must hold one of those roles in the org now. 20 a minute per
--        credential. Service role only.
--      * _exos_attendance_report(org, event, compare): the shared core,
--        service role only; every read names the org and the event.
-- 4. XLSX exports log export.run like the CSV exports: exos_audit_export
--    takes the kinds attendance, settlement, sales_tax and journal (the
--    workbooks the browser builds), and they count toward its 200-a-day cap.
--
-- Touches:  C: FUNCTION _exos_postal_area, _exos_attendance_tz,
--              _exos_attendance_pacing, _exos_attendance_report,
--              exos_event_attendance, _exos_api_attendance
--           W: FUNCTION exos_audit_export (20261109100000, patched by
--              20261112100000; two marker patches, each matching once:
--              /* exos: attendance export kinds */,
--              /* exos: attendance export cap */)
-- Grants:   exos_event_attendance -> authenticated (role-checked inside);
--           everything else service_role only. Nothing for anon (H3
--           unchanged). No table, no sequence, no cron.
-- Callers:  the event report's Attendees tab (AttendanceReportPanel), the
--           XLSX buttons (settlement, sales tax, journal), exos-api.
-- Pre-reqs: 20261106140000 (exos_order_locations), 20261108100000 ($0
--           orders, free_kind), 20261104180000 (_exos_api_key_actor),
--           20261109100000 + 20261112100000 (exos_audit_export).
-- Additive, re-run safe (CREATE OR REPLACE, marker-checked patches). Not
-- applied. Prod apply needs operator OK; apply before deploying exos-api.
-- ROLLBACK: DROP FUNCTION exos_event_attendance(uuid, uuid),
--           _exos_api_attendance(uuid, uuid, uuid, text, text, uuid),
--           _exos_attendance_report(uuid, uuid, uuid),
--           _exos_attendance_pacing(uuid, uuid), _exos_attendance_tz(text),
--           _exos_postal_area(text, text); re-run 20261112100000 section 5
--           after re-creating exos_audit_export from 20261109100000.
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
-- 1. Helpers
-- ===========================================================================
-- The postal area a rollup groups by: coarser where a full code is a block.
-- US ZIP+4 -> ZIP; CA -> forward sortation area; GB -> outward code. NULL for
-- no code.
CREATE OR REPLACE FUNCTION public._exos_postal_area(p_country text, p_postal text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN nullif(btrim(coalesce(p_postal, '')), '') IS NULL THEN NULL
    WHEN upper(p_country) = 'US' AND upper(btrim(p_postal)) ~ '^[0-9]{5}' THEN left(btrim(p_postal), 5)
    WHEN upper(p_country) = 'CA' AND upper(btrim(p_postal)) ~ '^[A-Z][0-9][A-Z]' THEN left(upper(btrim(p_postal)), 3)
    WHEN upper(p_country) = 'GB' AND upper(btrim(p_postal)) ~ ' ' THEN split_part(upper(btrim(p_postal)), ' ', 1)
    WHEN upper(p_country) = 'GB' AND length(btrim(p_postal)) > 3 THEN left(upper(btrim(p_postal)), length(btrim(p_postal)) - 3)
    ELSE upper(btrim(p_postal))
  END
$$;
REVOKE ALL ON FUNCTION public._exos_postal_area(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_postal_area(text, text) TO service_role;

-- An event's IANA zone, or UTC when it has none or the name is unknown.
CREATE OR REPLACE FUNCTION public._exos_attendance_tz(p_tz text)
RETURNS text LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
BEGIN
  IF p_tz IS NULL OR btrim(p_tz) = '' OR length(p_tz) > 64 THEN RETURN 'UTC'; END IF;
  PERFORM now() AT TIME ZONE p_tz;
  RETURN p_tz;
EXCEPTION WHEN invalid_parameter_value OR data_exception THEN
  RETURN 'UTC';
END $$;
REVOKE ALL ON FUNCTION public._exos_attendance_tz(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_attendance_tz(text) TO service_role;

-- ===========================================================================
-- 2. Pacing of one event (service role; the callers checked the org)
-- ===========================================================================
-- { event_id, name, starts_at, timezone, currency, event_day, on_sale_day,
--   on_sale_days_before, days_out_now, totals {...}, rows [...] }; rows are
-- the days with a sale, oldest first: { day, days_before, paid_orders,
-- paid_tickets, gross_cents, free_orders, free_tickets, cum_paid_tickets,
-- cum_gross_cents, cum_free_tickets }. days_before is NULL when the event has
-- no start. NULL when the event isn't the org's.
CREATE OR REPLACE FUNCTION public._exos_attendance_pacing(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  ev      record;
  v_tz    text;
  v_eday  date;
  v_today date;
  v_first date;
  v_tier  date;
  v_onsale date;
  v_rows  jsonb;
  v_tot   jsonb;
BEGIN
  SELECT e.id, e.name, e.starts_at, e.timezone, upper(coalesce(nullif(e.currency, ''), 'USD')) AS currency
    INTO ev FROM public.exos_events e WHERE e.id = p_event AND e.org_id = p_org;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_tz := public._exos_attendance_tz(ev.timezone);
  v_eday := (ev.starts_at AT TIME ZONE v_tz)::date;
  v_today := (now() AT TIME ZONE v_tz)::date;

  -- Every order that sold (refunded later or not): paid ones and the $0 rows.
  -- A $0 order is one that charged nothing, card or gift card.
  WITH s AS (
    SELECT (coalesce(cs.fulfilled_at, cs.created_at) AT TIME ZONE v_tz)::date AS d,
           cs.quantity, (cs.amount_cents + coalesce(cs.gift_card_cents, 0))::bigint AS paid_cents
      FROM public.exos_checkout_sessions cs
     WHERE cs.org_id = p_org AND cs.event_id = p_event
       AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded')
  ), g AS (
    SELECT CASE WHEN v_eday IS NULL THEN s.d ELSE least(s.d, v_eday) END AS day,
           count(*) FILTER (WHERE s.paid_cents > 0)::int AS paid_orders,
           coalesce(sum(s.quantity) FILTER (WHERE s.paid_cents > 0), 0)::int AS paid_tickets,
           coalesce(sum(s.paid_cents) FILTER (WHERE s.paid_cents > 0), 0)::bigint AS gross_cents,
           count(*) FILTER (WHERE s.paid_cents = 0)::int AS free_orders,
           coalesce(sum(s.quantity) FILTER (WHERE s.paid_cents = 0), 0)::int AS free_tickets
      FROM s GROUP BY 1
  ), c AS (
    SELECT g.*,
           sum(g.paid_tickets) OVER w AS cum_paid_tickets,
           sum(g.gross_cents) OVER w AS cum_gross_cents,
           sum(g.free_tickets) OVER w AS cum_free_tickets
      FROM g WINDOW w AS (ORDER BY g.day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'day', c.day, 'days_before', v_eday - c.day,
           'paid_orders', c.paid_orders, 'paid_tickets', c.paid_tickets, 'gross_cents', c.gross_cents,
           'free_orders', c.free_orders, 'free_tickets', c.free_tickets,
           'cum_paid_tickets', c.cum_paid_tickets::int, 'cum_gross_cents', c.cum_gross_cents::bigint,
           'cum_free_tickets', c.cum_free_tickets::int) ORDER BY c.day), '[]'::jsonb),
         jsonb_build_object(
           'paid_orders', coalesce(sum(c.paid_orders), 0)::int, 'paid_tickets', coalesce(sum(c.paid_tickets), 0)::int,
           'gross_cents', coalesce(sum(c.gross_cents), 0)::bigint,
           'free_orders', coalesce(sum(c.free_orders), 0)::int, 'free_tickets', coalesce(sum(c.free_tickets), 0)::int),
         min(c.day)
    INTO v_rows, v_tot, v_first
    FROM c;

  SELECT min((t.sales_start AT TIME ZONE v_tz)::date) INTO v_tier
    FROM public.exos_ticket_tiers t WHERE t.event_id = p_event AND t.sales_start IS NOT NULL;
  v_onsale := least(v_tier, v_first);
  IF v_eday IS NOT NULL AND v_onsale > v_eday THEN v_onsale := v_eday; END IF;

  RETURN jsonb_build_object(
    'event_id', ev.id, 'name', ev.name, 'starts_at', ev.starts_at, 'timezone', v_tz, 'currency', ev.currency,
    'event_day', v_eday, 'on_sale_day', v_onsale, 'on_sale_days_before', v_eday - v_onsale,
    'days_out_now', v_eday - v_today, 'totals', v_tot, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public._exos_attendance_pacing(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_attendance_pacing(uuid, uuid) TO service_role;

-- ===========================================================================
-- 3. The report (service role; the callers checked who is asking)
-- ===========================================================================
-- { org_id, event_id, generated_at, min_buyers: 5, attendance: { totals,
--   postal [...], postal_other, postal_unknown, other_tickets }, pacing:
--   { event, comparison }, comparison_candidates [...] }.
-- Attendance counts an order (paid or $0, any paid status) by its LIVE
-- tickets now (active / used; a $0 order's tickets are its ticket_ids, a
-- paid order's are the tickets with its order_ref), so a refunded order
-- with no ticket left drops out. Buyers: distinct account, else email, else
-- the order itself. Every live order is in exactly one row: a named area,
-- Other (fewer than 5) or No postal code.
CREATE OR REPLACE FUNCTION public._exos_attendance_report(p_org uuid, p_event uuid, p_compare uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  k_min     constant int := 5;
  v_start   timestamptz;
  v_att     jsonb;
  v_cands   jsonb;
BEGIN
  SELECT e.starts_at INTO v_start FROM public.exos_events e WHERE e.id = p_event AND e.org_id = p_org;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_compare IS NOT NULL THEN
    IF p_compare = p_event THEN
      RAISE EXCEPTION 'compare with another event' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_compare AND e.org_id = p_org) THEN
      RAISE EXCEPTION 'comparison event not found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  WITH o AS (
    SELECT cs.session_id, cs.ticket_ids, cs.free_kind,
           -- An order with neither an account nor an email is its own buyer.
           coalesce(cs.buyer_uid::text, 'e:' || nullif(lower(btrim(cs.buyer_email)), ''), 'o:' || cs.session_id) AS buyer,
           l.country, public._exos_postal_area(l.country, l.postal_code) AS area
      FROM public.exos_checkout_sessions cs
      LEFT JOIN public.exos_order_locations l ON l.session_id = cs.session_id AND l.org_id = p_org
     WHERE cs.org_id = p_org AND cs.event_id = p_event
       AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded')
  ), z AS (
    -- $0 orders name their tickets (mig 20261108100000); the tickets keep their own order_ref.
    SELECT DISTINCT ON (x.tid) x.tid, o.session_id
      FROM o CROSS JOIN LATERAL unnest(coalesce(o.ticket_ids, '{}'::uuid[])) AS x(tid)
     WHERE o.free_kind IS NOT NULL
     ORDER BY x.tid, o.session_id
  ), tk AS (
    SELECT t.id, t.status, coalesce(z.session_id, t.order_ref) AS sid
      FROM public.exos_tickets t
      LEFT JOIN z ON z.tid = t.id
     WHERE t.event_id = p_event AND t.org_id = p_org AND t.status IN ('active', 'used')
  ), per AS (
    SELECT o.session_id, o.buyer, o.country, o.area,
           count(tk.id)::int AS tickets, count(tk.id) FILTER (WHERE tk.status = 'used')::int AS checked_in
      FROM o JOIN tk ON tk.sid = o.session_id
     GROUP BY o.session_id, o.buyer, o.country, o.area
  ), grp AS (
    SELECT per.country, per.area, count(DISTINCT per.buyer)::int AS buyers, count(*)::int AS orders,
           sum(per.tickets)::int AS tickets, sum(per.checked_in)::int AS checked_in
      FROM per WHERE per.area IS NOT NULL GROUP BY per.country, per.area
  ), small AS (
    -- NULL-safe: an area with no country still folds into Other, so the
    -- named rows + Other + No postal code always add up to the totals.
    SELECT per.* FROM per JOIN grp ON grp.country IS NOT DISTINCT FROM per.country AND grp.area = per.area
     WHERE grp.buyers < k_min
  )
  SELECT jsonb_build_object(
    'totals', jsonb_build_object(
      'buyers', (SELECT count(DISTINCT buyer) FROM per),
      'orders', (SELECT count(*) FROM per),
      'tickets', (SELECT coalesce(sum(tickets), 0) FROM per),
      'checked_in', (SELECT coalesce(sum(checked_in), 0) FROM per),
      'located_orders', (SELECT count(*) FROM per WHERE area IS NOT NULL)),
    'postal', coalesce((SELECT jsonb_agg(jsonb_build_object('country', g.country, 'postal_code', g.area,
                 'buyers', g.buyers, 'orders', g.orders, 'tickets', g.tickets, 'checked_in', g.checked_in)
                 ORDER BY g.tickets DESC, g.buyers DESC, g.country, g.area)
                 FROM grp g WHERE g.buyers >= k_min), '[]'::jsonb),
    'postal_other', jsonb_build_object('label', 'Other (fewer than 5)',
                 'buyers', (SELECT count(DISTINCT buyer) FROM small), 'orders', (SELECT count(*) FROM small),
                 'tickets', (SELECT coalesce(sum(tickets), 0) FROM small),
                 'checked_in', (SELECT coalesce(sum(checked_in), 0) FROM small)),
    'postal_unknown', jsonb_build_object('label', 'No postal code',
                 'buyers', (SELECT count(DISTINCT buyer) FROM per WHERE area IS NULL),
                 'orders', (SELECT count(*) FROM per WHERE area IS NULL),
                 'tickets', (SELECT coalesce(sum(tickets), 0) FROM per WHERE area IS NULL),
                 'checked_in', (SELECT coalesce(sum(checked_in), 0) FROM per WHERE area IS NULL)),
    'other_tickets', (SELECT count(*) FROM tk WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.session_id = tk.sid)))
    INTO v_att;

  SELECT coalesce(jsonb_agg(jsonb_build_object('event_id', x.id, 'name', x.name, 'starts_at', x.starts_at)
                            ORDER BY x.starts_at DESC, x.id), '[]'::jsonb)
    INTO v_cands
    FROM (SELECT e.id, e.name, e.starts_at FROM public.exos_events e
           WHERE e.org_id = p_org AND e.id <> p_event AND e.starts_at IS NOT NULL
             AND (v_start IS NULL OR e.starts_at < v_start)
           ORDER BY e.starts_at DESC, e.id LIMIT 50) x;

  RETURN jsonb_build_object(
    'org_id', p_org, 'event_id', p_event, 'generated_at', now(), 'min_buyers', k_min,
    'attendance', v_att,
    'pacing', jsonb_build_object(
      'event', public._exos_attendance_pacing(p_org, p_event),
      'comparison', CASE WHEN p_compare IS NULL THEN NULL ELSE public._exos_attendance_pacing(p_org, p_compare) END),
    'comparison_candidates', v_cands);
END $$;
REVOKE ALL ON FUNCTION public._exos_attendance_report(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_attendance_report(uuid, uuid, uuid) TO service_role;

-- ===========================================================================
-- 4. Dashboard read: owner / manager / finance (or a platform admin)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_event_attendance(p_event_id uuid, p_compare_event_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); v_org uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_event_attendance: sign in first' USING ERRCODE = '42501';
  END IF;
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  -- An unknown event reads like one the caller may not see.
  IF v_org IS NULL OR NOT (public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'exos_event_attendance: owner, manager or finance only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('attendance:' || v_uid::text, 20) THEN
    RAISE EXCEPTION 'exos_event_attendance: too many reports a minute' USING ERRCODE = '54000';
  END IF;
  RETURN public._exos_attendance_report(v_org, p_event_id, p_compare_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_attendance(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_attendance(uuid, uuid) TO authenticated, service_role;

-- ===========================================================================
-- 5. Partner API read (exos-api, service role)
-- ===========================================================================
-- The credential's scope (orders:read) was checked at the edge; the role is
-- checked here: an org API key acts as its creator (owner / manager / finance
-- now), a personal or OAuth token as its user (the same roles, now). The
-- event and the comparison are the org's or 404.
CREATE OR REPLACE FUNCTION public._exos_api_attendance(
  p_org uuid, p_event uuid, p_compare uuid, p_cred_kind text, p_cred_id text, p_user uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE k_roles constant text[] := ARRAY['owner', 'manager', 'finance']; v_key uuid;
BEGIN
  IF p_org IS NULL OR coalesce(p_cred_id, '') = '' THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_cred_kind = 'api_key' THEN
    BEGIN
      v_key := p_cred_id::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END;
    PERFORM public._exos_api_key_actor(p_org, v_key, k_roles);
  ELSIF p_cred_kind IN ('pat', 'oauth') THEN
    IF p_user IS NULL OR coalesce(public._exos_member_role(p_org, p_user), '') <> ALL (k_roles) THEN
      RAISE EXCEPTION 'only an organization owner, manager or finance can read the attendance report' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('attendance-api:' || p_cred_id, 20) THEN
    RAISE EXCEPTION 'too many attendance reports a minute' USING ERRCODE = '54000';
  END IF;
  RETURN public._exos_attendance_report(p_org, p_event, p_compare);
END $$;
REVOKE ALL ON FUNCTION public._exos_api_attendance(uuid, uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_attendance(uuid, uuid, uuid, text, text, uuid) TO service_role;

-- ===========================================================================
-- 6. exos_audit_export: the XLSX workbooks' kinds
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_audit_export(uuid,text,integer,uuid)',
  '/* exos: attendance export kinds */',
  $o$  IF p_kind IS NULL OR p_kind NOT IN ('audit', 'donations', 'price_disclosure', 'attendees') THEN
    RAISE EXCEPTION 'kind must be audit, donations, price_disclosure or attendees' USING ERRCODE = '22023';$o$,
  $n$  IF p_kind IS NULL OR p_kind NOT IN ('audit', 'donations', 'price_disclosure', 'attendees',
       'attendance', 'settlement', 'sales_tax', 'journal' /* exos: attendance export kinds */) THEN
    RAISE EXCEPTION 'kind must be audit, donations, price_disclosure, attendees, attendance, settlement, sales_tax or journal' USING ERRCODE = '22023';$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_audit_export(uuid,text,integer,uuid)',
  '/* exos: attendance export cap */',
  $o$         AND a.entity_id IN ('audit', 'donations', 'price_disclosure', 'attendees')$o$,
  $n$         AND a.entity_id IN ('audit', 'donations', 'price_disclosure', 'attendees',
                             'attendance', 'settlement', 'sales_tax', 'journal' /* exos: attendance export cap */)$n$, 1);
