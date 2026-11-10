-- ============================================================================
-- Migration 20261113110000 — Exos: fair-day setup (county fairs, rodeos, state
--   fairs): day passes, multi-day and any-day passes, parking and camping,
--   and gate throughput. docs/organizer-guide.md "Fairs and multi-day events",
--   docs/booking.md, docs/security.md "Fair days and gate throughput".
--
-- Branch:   claude/exos-fair-day
--
-- Built on what exists: check-in lists (mig 20260929140000: ticket types, a
-- valid_from / valid_until window, allow_reentry, exits), add-ons with their
-- own entry codes and lists that scan only add-on codes (mig 20261107110000),
-- gate = the list's name on each scan row, direction entry / exit.
--
-- The gap (found reading exos_check_in_ticket): the first entry anywhere
-- flips the ticket to 'used', and a list without re-entry refuses a used
-- ticket. So a 3-day pass on per-day lists WITHOUT re-entry was refused on
-- day 2, online and offline; and an any-day pass on per-day lists WITH
-- re-entry got in on every day (re-entry state is per list). Nothing in the
-- model said "one day" or "once a day". Two small columns close it:
--
-- 1. exos_checkin_lists.entry_day (date, NULL = an ordinary list). A list
--    for one fair day. On it, for tickets:
--      * without re-entry: one entry per ticket per DAY (every list of the
--        event with the same entry_day, so several gates of one day share
--        it) instead of one per event; a ticket used on another day may enter;
--      * with re-entry: as before (inside = the last scan on this list);
--      * the ticket type's max_entry_days (below) is checked.
--    Add-on lists (admits 'addons') can't have one (CHECK): add-on passes
--    keep their own rules.
-- 2. exos_ticket_tiers.max_entry_days (int 1..366, NULL = no limit): a ticket
--    of this type enters on at most N different fair days (distinct
--    entry_day of its entries, forced ones included: they came in). An
--    any-day pass is 1; a "any 3 days of 10" flex pass is 3. A pass for a
--    fixed set of days just sits on those days' lists with no limit.
--    New refusal 'day-limit' { max_days, days_used }. A 'used' on a day list
--    carries { day }.
--    EVERY prior entry of the ticket for the event counts, whatever list it
--    was on: its day is the list's entry_day, else (no list, an ordinary
--    list, a deleted list) the scan's local date in the event's time zone
--    (_exos_event_tz). So an entry through a no-list or ordinary-list scan
--    can't be followed by a second one at a day list the same day, nor give
--    an any-day pass an extra day.
--    The check-in re-reads the ticket's status and pending transfer UNDER its
--    row lock on a day list (and on a re-entry list, which had the same
--    window): voided / transferred / mid-transfer between the first read and
--    the lock is refused, never let in.
--    _exos_checkin_day_refusal (internal) holds the rule. Marker patches:
--      exos_check_in_ticket (10 args)      /* exos: fair days 1..3 */
--      exos_door_checkin_by_name (8 args)  /* exos: fair days 1, 2 */
--      exos_check_in_offline (10 args),
--      exos_door_checkin_by_name           /* exos: fair days rejects */
--        (a refused replay logs 'day-limit' as 'used', reject only: it is a
--        true over-use, like 'used', so no forced row)
--      exos_event_door_roster              /* exos: fair days roster */
--        (list_state also covers day lists, and has a 'day:YYYY-MM-DD'
--        key per local date of an entry on no list / an ordinary list, so a
--        device decides offline)
--    The API check-in (POST /v1/tickets/:id/check-in) and the offline replay
--    both go through exos_check_in_ticket, so they follow too.
-- 3. exos_fair_setup(event, plan): the editor's "Fair / multi-day setup"
--    preset generator in one transaction: the add-ons (parking, camping;
--    separate_access_barcode on), the ticket types (a day pass per day, a
--    multi-day pass, an any-day pass), the day lists (one per day,
--    valid_from / valid_until, entry_day, the re-entry preset) and the lot
--    list (add-on codes only). Ordinary rows the organizer edits afterwards;
--    no new runtime concept besides 1 and 2. Owner / manager of the event's
--    org (or admin), checked in SQL; refused once the event has day lists;
--    sets the event's ends_at to the last day's close when it was earlier or
--    unset (the offline replay window and the door follow ends_at); one
--    _exos_audit row 'event.fair_setup' (the rows' own audit triggers log
--    each tier as well).
-- 4. exos_door_throughput(event, from, until, bucket minutes): the door
--    report's per-gate view, read from exos_event_checkins,
--    exos_addon_pass_checkins and exos_scan_rejects: scans per bucket per
--    list / gate (entries, exits, forced), per-gate totals (devices, peak),
--    the current in-park count on lists that track direction (re-entry
--    lists: last scan per ticket is an entry), and refusals by reason.
--    Owner / manager / finance of the event's org, a scanner assigned to the
--    event, or admin (exos_event_door_summary's rule). Indexes on the door
--    time (coalesce(offline_scanned_at, scanned_at)) per event and on
--    exos_scan_rejects (event_id, rejected_at).
--
-- Touches:  W: TABLE exos_checkin_lists (+entry_day, CHECK, index),
--              exos_ticket_tiers (+max_entry_days, CHECK)
--           C: INDEX exos_event_checkins_event_door_at_idx,
--              exos_event_checkins_list_ticket_idx,
--              exos_addon_pass_checkins_event_door_at_idx,
--              exos_scan_rejects_event_at_idx
--           C: FUNCTION _exos_checkin_day_refusal, _exos_event_tz (internal),
--              exos_fair_setup, exos_door_throughput
--           P: exos_check_in_ticket (10 args), exos_door_checkin_by_name
--              (8 args), exos_check_in_offline (10 args),
--              exos_event_door_roster (all created 2026-09-29 or later;
--              marker patches against the current text)
-- Grants:   authenticated: exos_fair_setup, exos_door_throughput (roles
--              checked inside). Nothing for anon (H3 unchanged).
-- Additive, replay-safe (IF NOT EXISTS, constraints only when missing,
-- CREATE OR REPLACE, marker-checked patches). No cron. Not applied. Prod
-- apply needs operator OK; apply after 20261112100000.
-- ROLLBACK: re-run 20261107110000's exos_check_in_ticket / offline patches on
--           20260929140000's bodies (or patch the markers out); DROP FUNCTION
--           exos_fair_setup, exos_door_throughput, _exos_checkin_day_refusal,
--           _exos_event_tz;
--           the columns can stay (NULL = today's behaviour).
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
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

-- ===========================================================================
-- 1. Schema: a list's fair day, a ticket type's day limit
-- ===========================================================================
ALTER TABLE public.exos_checkin_lists ADD COLUMN IF NOT EXISTS entry_day date;
ALTER TABLE public.exos_ticket_tiers ADD COLUMN IF NOT EXISTS max_entry_days integer;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkin_lists_entry_day_chk') THEN
    ALTER TABLE public.exos_checkin_lists ADD CONSTRAINT exos_checkin_lists_entry_day_chk
      CHECK (entry_day IS NULL OR admits <> 'addons');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_ticket_tiers_max_entry_days_chk') THEN
    ALTER TABLE public.exos_ticket_tiers ADD CONSTRAINT exos_ticket_tiers_max_entry_days_chk
      CHECK (max_entry_days IS NULL OR max_entry_days BETWEEN 1 AND 366);
  END IF;
END $$;
COMMENT ON COLUMN public.exos_checkin_lists.entry_day IS
  'A list for one fair day (mig 20261113110000). Without re-entry a ticket enters once per day (every list with this '
  'day), not once per event; the ticket type''s max_entry_days is checked. NULL = an ordinary list.';
COMMENT ON COLUMN public.exos_ticket_tiers.max_entry_days IS
  'At most this many different fair days (exos_checkin_lists.entry_day) per ticket: 1 = an any-day pass. NULL = no '
  'limit. mig 20261113110000.';
CREATE INDEX IF NOT EXISTS exos_checkin_lists_event_day_idx
  ON public.exos_checkin_lists (event_id, entry_day) WHERE entry_day IS NOT NULL;

-- The door report reads by door time (an offline scan's own time) per event.
CREATE INDEX IF NOT EXISTS exos_event_checkins_event_door_at_idx
  ON public.exos_event_checkins (event_id, (coalesce(offline_scanned_at, scanned_at)));
CREATE INDEX IF NOT EXISTS exos_event_checkins_list_ticket_idx
  ON public.exos_event_checkins (list_id, ticket_id) WHERE list_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_addon_pass_checkins_event_door_at_idx
  ON public.exos_addon_pass_checkins (event_id, (coalesce(offline_scanned_at, scanned_at)));
CREATE INDEX IF NOT EXISTS exos_scan_rejects_event_at_idx
  ON public.exos_scan_rejects (event_id, rejected_at);

-- ===========================================================================
-- 2. The day rule (internal; definer callers only)
-- ===========================================================================
-- The event's IANA time zone, or 'UTC' when unset or unknown (never raises).
CREATE OR REPLACE FUNCTION public._exos_event_tz(p_event_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tz text;
BEGIN
  SELECT nullif(btrim(timezone), '') INTO v_tz FROM public.exos_events WHERE id = p_event_id;
  IF v_tz IS NULL THEN
    RETURN 'UTC';
  END IF;
  BEGIN
    PERFORM now() AT TIME ZONE v_tz;
  EXCEPTION WHEN others THEN
    RETURN 'UTC';
  END;
  RETURN v_tz;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_tz(uuid) FROM PUBLIC, anon, authenticated;

-- Why a day list refuses this ticket's ENTRY, or NULL. Callers hold the
-- ticket's row lock, so two gates can't both pass it. Every prior entry of
-- the ticket for the event counts: its day is its list's entry_day, else (no
-- list, an ordinary list, a deleted list) the scan's local date in the
-- event's time zone.
CREATE OR REPLACE FUNCTION public._exos_checkin_day_refusal(p_ticket_id uuid, p_tier_id uuid, p_list_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  l      public.exos_checkin_lists%ROWTYPE;
  v_tz   text;
  v_max  int;
  v_days int;
  v_at   timestamptz;
  v_dev  text;
  v_src  text;
  v_gate text;
BEGIN
  SELECT * INTO l FROM public.exos_checkin_lists WHERE id = p_list_id;
  IF NOT FOUND OR l.entry_day IS NULL THEN
    RETURN NULL;
  END IF;
  v_tz := public._exos_event_tz(l.event_id);
  -- Without re-entry: once that day, through whichever list (or none).
  IF NOT l.allow_reentry THEN
    SELECT coalesce(ci.offline_scanned_at, ci.scanned_at), ci.device, ci.source, ci.gate
      INTO v_at, v_dev, v_src, v_gate
      FROM public.exos_event_checkins ci
      LEFT JOIN public.exos_checkin_lists dl ON dl.id = ci.list_id
     WHERE ci.ticket_id = p_ticket_id AND ci.event_id = l.event_id AND ci.direction = 'entry'
       AND coalesce(dl.entry_day, (coalesce(ci.offline_scanned_at, ci.scanned_at) AT TIME ZONE v_tz)::date) = l.entry_day
     ORDER BY coalesce(ci.offline_scanned_at, ci.scanned_at) DESC
     LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'used', 'day', l.entry_day)
             || jsonb_strip_nulls(jsonb_build_object('check_in_at', v_at, 'device', v_dev, 'source', v_src, 'list', v_gate));
    END IF;
  END IF;
  -- The ticket type's day limit: other days already used.
  SELECT tt.max_entry_days INTO v_max
    FROM public.exos_ticket_tiers tt WHERE tt.id = p_tier_id AND tt.event_id = l.event_id;
  IF v_max IS NOT NULL THEN
    SELECT count(DISTINCT coalesce(dl.entry_day, (coalesce(ci.offline_scanned_at, ci.scanned_at) AT TIME ZONE v_tz)::date))
      INTO v_days
      FROM public.exos_event_checkins ci
      LEFT JOIN public.exos_checkin_lists dl ON dl.id = ci.list_id
     WHERE ci.ticket_id = p_ticket_id AND ci.event_id = l.event_id AND ci.direction = 'entry'
       AND coalesce(dl.entry_day, (coalesce(ci.offline_scanned_at, ci.scanned_at) AT TIME ZONE v_tz)::date) <> l.entry_day;
    IF v_days >= v_max THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'day-limit', 'max_days', v_max, 'days_used', v_days,
                                'list', l.name);
    END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_checkin_day_refusal(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- 3. The door: online, offline replay, by name, the API (marker patches)
-- ===========================================================================
-- exos_check_in_ticket (10 args): the day rule after the transfer check, and
-- a day list doesn't refuse a ticket used on another day.
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamp with time zone, text, uuid, text)',
  '/* exos: fair days 1 */',
  $o$  IF v_pending IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer');
  END IF;
$o$,
  $n$  IF v_pending IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer');
  END IF;

  /* exos: fair days 1 */ -- mig 20261113110000: a list for one fair day admits a
  -- ticket once that day (re-entry lists: per list, as before) and checks the
  -- ticket type's day limit. The ticket row lock serializes two gates. On a
  -- day list or a re-entry list a used ticket isn't refused by its status, so
  -- the status and transfer are read again UNDER the lock: a ticket voided or
  -- sent into a transfer after the first read is refused, never let in.
  IF v_list.entry_day IS NOT NULL OR v_list.allow_reentry THEN
    SELECT status, pending_transfer_id INTO v_prev, v_pending
      FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
    IF v_prev = 'voided' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'voided');
    END IF;
    IF v_prev IS NULL OR v_prev NOT IN ('active', 'used') THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
    END IF;
    IF v_pending IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer');
    END IF;
  END IF;
  IF v_list.entry_day IS NOT NULL THEN
    v_refusal := public._exos_checkin_day_refusal(p_ticket_id, v_tier, v_list.id);
    IF v_refusal IS NOT NULL THEN
      RETURN v_refusal;
    END IF;
  END IF;
$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamp with time zone, text, uuid, text)',
  '/* exos: fair days 2 */',
  $o$  IF v_prev = 'used' THEN
    RETURN public._exos_used_answer(p_ticket_id);
  END IF;
$o$,
  $n$  IF v_prev = 'used' AND v_list.entry_day IS NULL THEN /* exos: fair days 2 */
    RETURN public._exos_used_answer(p_ticket_id);
  END IF;
$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamp with time zone, text, uuid, text)',
  '/* exos: fair days 3 */',
  $o$  IF v_updated = 0 THEN
    RETURN public._exos_used_answer(p_ticket_id);
$o$,
  $n$  IF v_updated = 0 AND (v_list.entry_day IS NULL OR v_prev IS DISTINCT FROM 'used') THEN /* exos: fair days 3 */
    -- A day list goes on only for a ticket the locked re-read saw used.
    RETURN public._exos_used_answer(p_ticket_id);
$n$, 1);

-- By name (8 args, the list-aware one): the same rule.
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* exos: fair days 1 */',
  $o$    IF v_list.allow_reentry THEN
      v_refusal := public._exos_list_inside(t.id, v_list.id, v_scan_at);
$o$,
  $n$    /* exos: fair days 1 */ -- mig 20261113110000 (see exos_check_in_ticket).
    IF v_list.entry_day IS NOT NULL THEN
      v_refusal := public._exos_checkin_day_refusal(t.id, t.tier_id, v_list.id);
      IF v_refusal IS NOT NULL THEN
        r := v_refusal; EXIT decide;
      END IF;
    END IF;
    IF v_list.allow_reentry THEN
      v_refusal := public._exos_list_inside(t.id, v_list.id, v_scan_at);
$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* exos: fair days 2 */',
  $o$    ELSIF t.status = 'used' THEN
$o$,
  $n$    ELSIF t.status = 'used' AND v_list.entry_day IS NULL THEN /* exos: fair days 2 */
$n$, 1);

-- A refused replay: 'day-limit' is logged as 'used' (reject only, no forced row).
SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamp with time zone, uuid, uuid, text)',
  '/* exos: fair days rejects */',
  $o$                WHEN 'already-inside' THEN 'used'
$o$,
  $n$                WHEN 'already-inside' THEN 'used'
                WHEN 'day-limit'      THEN 'used' /* exos: fair days rejects */
$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamp with time zone, text, text, text, text, uuid, text)',
  '/* exos: fair days rejects */',
  $o$              WHEN 'already-inside'   THEN 'used'
$o$,
  $n$              WHEN 'already-inside'   THEN 'used'
              WHEN 'day-limit'        THEN 'used' /* exos: fair days rejects */
$n$, 1);

-- The saved list: list_state covers day lists too (which days a ticket used),
-- and a 'day:YYYY-MM-DD' key (the scan's local date in the event's zone) for
-- each entry on no list, an ordinary list or a deleted list.
SELECT pg_temp.exos_patch_n(
  'public.exos_event_door_roster(uuid, timestamp with time zone)',
  '/* exos: fair days roster */',
  $o$           (SELECT jsonb_object_agg(x.list_id, x.direction)
              FROM (SELECT DISTINCT ON (ci.list_id) ci.list_id, ci.direction
                      FROM public.exos_event_checkins ci
                      JOIN public.exos_checkin_lists l ON l.id = ci.list_id AND l.allow_reentry
                     WHERE ci.ticket_id = t.id
                     ORDER BY ci.list_id, coalesce(ci.offline_scanned_at, ci.scanned_at) DESC, ci.scanned_at DESC) x)$o$,
  $n$           (SELECT jsonb_object_agg(x.k, x.direction) /* exos: fair days roster */
              FROM ((SELECT DISTINCT ON (ci.list_id) ci.list_id::text AS k, ci.direction
                       FROM public.exos_event_checkins ci
                       JOIN public.exos_checkin_lists l ON l.id = ci.list_id AND (l.allow_reentry OR l.entry_day IS NOT NULL)
                      WHERE ci.ticket_id = t.id
                      ORDER BY ci.list_id, coalesce(ci.offline_scanned_at, ci.scanned_at) DESC, ci.scanned_at DESC)
                    UNION ALL
                    (SELECT DISTINCT 'day:' || ((coalesce(ci.offline_scanned_at, ci.scanned_at)
                                                AT TIME ZONE public._exos_event_tz(p_event_id))::date)::text, 'entry'::text
                       FROM public.exos_event_checkins ci
                       LEFT JOIN public.exos_checkin_lists l ON l.id = ci.list_id
                      WHERE ci.ticket_id = t.id AND ci.event_id = p_event_id AND ci.direction = 'entry'
                        AND l.entry_day IS NULL)) x)$n$,
  1);

-- ===========================================================================
-- 4. exos_fair_setup: the editor's preset generator, in one transaction
-- ===========================================================================
-- p_plan (built by src/lib/fairSetup.ts):
--   { tiers:  [{ key, name, description?, price_cents, capacity, max_entry_days? }],
--     addons: [{ key, name, description?, price_cents, capacity }],
--     lists:  [{ name, admits: 'tickets' | 'addons', tier_keys?, addon_keys?,
--                allow_reentry, valid_from, valid_until, entry_day? }] }
CREATE OR REPLACE FUNCTION public._exos_fair_text(p jsonb, p_field text, p_max int, p_required boolean)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE v text;
BEGIN
  IF p -> p_field IS NULL OR jsonb_typeof(p -> p_field) = 'null' THEN
    v := NULL;
  ELSIF jsonb_typeof(p -> p_field) <> 'string' THEN
    RAISE EXCEPTION 'exos_fair_setup: % must be text', p_field USING ERRCODE = '22023';
  ELSE
    v := nullif(btrim(p ->> p_field), '');
  END IF;
  IF v IS NULL AND p_required THEN
    RAISE EXCEPTION 'exos_fair_setup: % is required', p_field USING ERRCODE = '22023';
  END IF;
  IF char_length(v) > p_max THEN
    RAISE EXCEPTION 'exos_fair_setup: % is longer than % characters', p_field, p_max USING ERRCODE = '22023';
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_fair_text(jsonb, text, int, boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_fair_int(p jsonb, p_field text, p_min bigint, p_max bigint, p_required boolean)
RETURNS bigint
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE v numeric;
BEGIN
  IF p -> p_field IS NULL OR jsonb_typeof(p -> p_field) = 'null' THEN
    IF p_required THEN
      RAISE EXCEPTION 'exos_fair_setup: % is required', p_field USING ERRCODE = '22023';
    END IF;
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p -> p_field) <> 'number' THEN
    RAISE EXCEPTION 'exos_fair_setup: % must be a whole number', p_field USING ERRCODE = '22023';
  END IF;
  v := (p ->> p_field)::numeric;
  IF v <> trunc(v) OR v < p_min OR v > p_max THEN
    RAISE EXCEPTION 'exos_fair_setup: % must be a whole number from % to %', p_field, p_min, p_max USING ERRCODE = '22023';
  END IF;
  RETURN v::bigint;
END $$;
REVOKE ALL ON FUNCTION public._exos_fair_int(jsonb, text, bigint, bigint, boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_fair_setup(p_event_id uuid, p_plan jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e          public.exos_events%ROWTYPE;
  v_tiers    jsonb;
  v_addons   jsonb;
  v_lists    jsonb;
  x          jsonb;
  v_key      text;
  v_name     text;
  v_admits   text;
  v_reentry  boolean;
  v_from     timestamptz;
  v_until    timestamptz;
  v_day      date;
  v_price    bigint;
  v_cap      bigint;
  v_max      bigint;
  v_sort     int;
  v_id       uuid;
  v_ids      uuid[];
  v_tier_ids  jsonb := '{}'::jsonb;
  v_addon_ids jsonb := '{}'::jsonb;
  v_list_ids  jsonb := '[]'::jsonb;
  v_last     timestamptz;
  v_ends     boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_fair_setup: not authenticated' USING ERRCODE = '42501';
  END IF;
  -- The org comes from the event row; an unknown event and another org's look
  -- the same.
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_fair_setup: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_fair_setup: the event is cancelled' USING ERRCODE = '22023';
  END IF;
  IF p_plan IS NULL OR jsonb_typeof(p_plan) <> 'object' OR octet_length(p_plan::text) > 65536 THEN
    RAISE EXCEPTION 'exos_fair_setup: the plan must be an object of at most 64 KB' USING ERRCODE = '22023';
  END IF;
  v_tiers  := coalesce(p_plan -> 'tiers', '[]'::jsonb);
  v_addons := coalesce(p_plan -> 'addons', '[]'::jsonb);
  v_lists  := coalesce(p_plan -> 'lists', '[]'::jsonb);
  IF jsonb_typeof(v_tiers) <> 'array' OR jsonb_typeof(v_addons) <> 'array' OR jsonb_typeof(v_lists) <> 'array' THEN
    RAISE EXCEPTION 'exos_fair_setup: tiers, addons and lists must be lists' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(v_tiers) NOT BETWEEN 1 AND 30 OR jsonb_array_length(v_addons) > 10
     OR jsonb_array_length(v_lists) NOT BETWEEN 1 AND 40 THEN
    RAISE EXCEPTION 'exos_fair_setup: 1 to 30 ticket types, up to 10 add-ons, 1 to 40 lists' USING ERRCODE = '22023';
  END IF;

  -- One setup per event (two tabs, a double click): the event row's lock, then
  -- refuse once it has day lists.
  PERFORM 1 FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.exos_checkin_lists WHERE event_id = p_event_id AND entry_day IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_fair_setup: this event already has fair-day lists; change them under Check-in lists'
      USING ERRCODE = '23505';
  END IF;

  -- Add-ons: parking, camping. Each unit gets its own entry code.
  SELECT coalesce(max(sort_order), -1) + 1 INTO v_sort FROM public.exos_event_addons WHERE event_id = p_event_id;
  FOR x IN SELECT value FROM jsonb_array_elements(v_addons) LOOP
    IF jsonb_typeof(x) <> 'object' THEN
      RAISE EXCEPTION 'exos_fair_setup: each add-on must be an object' USING ERRCODE = '22023';
    END IF;
    v_key := public._exos_fair_text(x, 'key', 40, true);
    IF v_key !~ '^[a-z0-9-]+$' OR v_addon_ids ? v_key THEN
      RAISE EXCEPTION 'exos_fair_setup: add-on keys are unique, lowercase letters, digits and dashes' USING ERRCODE = '22023';
    END IF;
    v_price := public._exos_fair_int(x, 'price_cents', 0, 10000000, true);
    v_cap   := public._exos_fair_int(x, 'capacity', 1, 1000000, true);
    INSERT INTO public.exos_event_addons (event_id, name, description, price, capacity, visibility, sort_order,
                                          separate_access_barcode)
    VALUES (p_event_id, public._exos_fair_text(x, 'name', 80, true), public._exos_fair_text(x, 'description', 500, false),
            v_price / 100.0, v_cap, 'public', v_sort, true)
    RETURNING id INTO v_id;
    v_addon_ids := v_addon_ids || jsonb_build_object(v_key, v_id);
    v_sort := v_sort + 1;
  END LOOP;

  -- Ticket types: day passes, the multi-day pass, the any-day pass.
  SELECT coalesce(max(sort_order), -1) + 1 INTO v_sort FROM public.exos_ticket_tiers WHERE event_id = p_event_id;
  FOR x IN SELECT value FROM jsonb_array_elements(v_tiers) LOOP
    IF jsonb_typeof(x) <> 'object' THEN
      RAISE EXCEPTION 'exos_fair_setup: each ticket type must be an object' USING ERRCODE = '22023';
    END IF;
    v_key := public._exos_fair_text(x, 'key', 40, true);
    IF v_key !~ '^[a-z0-9-]+$' OR v_tier_ids ? v_key THEN
      RAISE EXCEPTION 'exos_fair_setup: ticket type keys are unique, lowercase letters, digits and dashes' USING ERRCODE = '22023';
    END IF;
    v_price := public._exos_fair_int(x, 'price_cents', 0, 10000000, true);
    v_cap   := public._exos_fair_int(x, 'capacity', 1, 1000000, true);
    v_max   := public._exos_fair_int(x, 'max_entry_days', 1, 366, false);
    INSERT INTO public.exos_ticket_tiers (event_id, name, description, price, capacity, ticket_type, visibility,
                                          sort_order, max_entry_days)
    VALUES (p_event_id, public._exos_fair_text(x, 'name', 80, true), public._exos_fair_text(x, 'description', 500, false),
            v_price / 100.0, v_cap, CASE WHEN v_price = 0 THEN 'free' ELSE 'paid' END, 'public', v_sort, v_max)
    RETURNING id INTO v_id;
    v_tier_ids := v_tier_ids || jsonb_build_object(v_key, v_id);
    v_sort := v_sort + 1;
  END LOOP;

  -- Check-in lists: one per day (entry_day), and the lot.
  SELECT coalesce(max(sort_order), -1) + 1 INTO v_sort FROM public.exos_checkin_lists WHERE event_id = p_event_id;
  FOR x IN SELECT value FROM jsonb_array_elements(v_lists) LOOP
    IF jsonb_typeof(x) <> 'object' THEN
      RAISE EXCEPTION 'exos_fair_setup: each list must be an object' USING ERRCODE = '22023';
    END IF;
    v_name := public._exos_fair_text(x, 'name', 60, true);
    v_admits := coalesce(public._exos_fair_text(x, 'admits', 10, false), 'tickets');
    IF v_admits NOT IN ('tickets', 'addons') THEN
      RAISE EXCEPTION 'exos_fair_setup: a list admits tickets or addons' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(x -> 'allow_reentry') IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'exos_fair_setup: allow_reentry must be true or false' USING ERRCODE = '22023';
    END IF;
    v_reentry := (x ->> 'allow_reentry')::boolean;
    BEGIN
      v_from  := public._exos_fair_text(x, 'valid_from', 40, true)::timestamptz;
      v_until := public._exos_fair_text(x, 'valid_until', 40, true)::timestamptz;
      v_day   := public._exos_fair_text(x, 'entry_day', 10, false)::date;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
      RAISE EXCEPTION 'exos_fair_setup: list "%" has a date that can''t be read', v_name USING ERRCODE = '22023';
    END;
    IF v_until <= v_from OR v_until - v_from > interval '31 days' THEN
      RAISE EXCEPTION 'exos_fair_setup: list "%" must close after it opens, within 31 days', v_name USING ERRCODE = '22023';
    END IF;
    IF v_admits = 'addons' THEN
      IF v_day IS NOT NULL THEN
        RAISE EXCEPTION 'exos_fair_setup: a lot list has no fair day' USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(x -> 'addon_keys') IS DISTINCT FROM 'array' OR jsonb_array_length(x -> 'addon_keys') = 0
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(x -> 'addon_keys') k
                     WHERE jsonb_typeof(k) <> 'string' OR NOT (v_addon_ids ? (k #>> '{}'))) THEN
        RAISE EXCEPTION 'exos_fair_setup: lot list "%" must name add-ons of this plan', v_name USING ERRCODE = '22023';
      END IF;
      SELECT array_agg((v_addon_ids ->> (k #>> '{}'))::uuid) INTO v_ids FROM jsonb_array_elements(x -> 'addon_keys') k;
      INSERT INTO public.exos_checkin_lists (event_id, org_id, name, tier_ids, allow_reentry, valid_from, valid_until,
                                             sort_order, admits, addon_ids, entry_day)
      VALUES (p_event_id, e.org_id, v_name, NULL, v_reentry, v_from, v_until, v_sort, 'addons', v_ids, NULL)
      RETURNING id INTO v_id;
    ELSE
      IF jsonb_typeof(x -> 'tier_keys') IS DISTINCT FROM 'array' OR jsonb_array_length(x -> 'tier_keys') = 0
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(x -> 'tier_keys') k
                     WHERE jsonb_typeof(k) <> 'string' OR NOT (v_tier_ids ? (k #>> '{}'))) THEN
        RAISE EXCEPTION 'exos_fair_setup: list "%" must name ticket types of this plan', v_name USING ERRCODE = '22023';
      END IF;
      SELECT array_agg((v_tier_ids ->> (k #>> '{}'))::uuid) INTO v_ids FROM jsonb_array_elements(x -> 'tier_keys') k;
      INSERT INTO public.exos_checkin_lists (event_id, org_id, name, tier_ids, allow_reentry, valid_from, valid_until,
                                             sort_order, admits, addon_ids, entry_day)
      VALUES (p_event_id, e.org_id, v_name, v_ids, v_reentry, v_from, v_until, v_sort, 'tickets', NULL, v_day)
      RETURNING id INTO v_id;
    END IF;
    v_list_ids := v_list_ids || to_jsonb(v_id);
    v_last := greatest(v_last, v_until);
    v_sort := v_sort + 1;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.exos_checkin_lists WHERE event_id = p_event_id AND entry_day IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_fair_setup: the plan needs at least one fair-day list' USING ERRCODE = '22023';
  END IF;

  -- The event runs until the last day closes (the door's offline replay window
  -- and every "has it ended" check follow ends_at).
  IF v_last IS NOT NULL AND (e.ends_at IS NULL OR e.ends_at < v_last) THEN
    UPDATE public.exos_events SET ends_at = v_last WHERE id = p_event_id;
    v_ends := true;
  END IF;

  /* exos: audit event.fair_setup */
  PERFORM public._exos_audit(e.org_id, 'event.fair_setup', 'event', p_event_id::text, p_event_id,
    jsonb_build_object('ticket_types', jsonb_build_array(NULL, jsonb_array_length(v_tiers)),
                       'add_ons', jsonb_build_array(NULL, jsonb_array_length(v_addons)),
                       'check_in_lists', jsonb_build_array(NULL, jsonb_array_length(v_lists))));

  RETURN jsonb_build_object('ok', true, 'tier_ids', v_tier_ids, 'addon_ids', v_addon_ids, 'list_ids', v_list_ids,
                            'ends_at', CASE WHEN v_ends THEN v_last END);
END $$;
REVOKE ALL ON FUNCTION public.exos_fair_setup(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_fair_setup(uuid, jsonb) TO authenticated, service_role;

-- ===========================================================================
-- 5. exos_door_throughput: per-gate scans, in-park now, refusals
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_door_throughput(
  p_event_id uuid, p_from timestamptz DEFAULT NULL, p_until timestamptz DEFAULT NULL, p_bucket_minutes int DEFAULT 15)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e       public.exos_events%ROWTYPE;
  v_until timestamptz := coalesce(p_until, now());
  v_from  timestamptz := coalesce(p_from, coalesce(p_until, now()) - interval '24 hours');
  v_step  int := coalesce(p_bucket_minutes, 15);
  v_out   jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_door_throughput: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin()
          OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'finance'])
          OR (public.exos_has_org_role(e.org_id, ARRAY['scanner']) AND public.exos_can_door_event(p_event_id))) THEN
    RAISE EXCEPTION 'exos_door_throughput: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF v_step NOT IN (5, 10, 15, 30, 60) THEN
    RAISE EXCEPTION 'exos_door_throughput: bucket minutes must be 5, 10, 15, 30 or 60' USING ERRCODE = '22023';
  END IF;
  IF v_until <= v_from OR v_until - v_from > interval '14 days' THEN
    RAISE EXCEPTION 'exos_door_throughput: the window must end after it starts, within 14 days' USING ERRCODE = '22023';
  END IF;

  WITH
  scans AS (
    SELECT 'ticket'::text AS kind, c.list_id, coalesce(c.gate, l.name, 'No list') AS gate, c.direction, c.forced,
           c.device, coalesce(c.offline_scanned_at, c.scanned_at) AS at
      FROM public.exos_event_checkins c
      LEFT JOIN public.exos_checkin_lists l ON l.id = c.list_id
     WHERE c.event_id = p_event_id
       AND coalesce(c.offline_scanned_at, c.scanned_at) >= v_from
       AND coalesce(c.offline_scanned_at, c.scanned_at) < v_until
    UNION ALL
    SELECT 'addon', c.list_id, coalesce(c.gate, l.name, 'No list'), c.direction, false,
           c.device, coalesce(c.offline_scanned_at, c.scanned_at)
      FROM public.exos_addon_pass_checkins c
      LEFT JOIN public.exos_checkin_lists l ON l.id = c.list_id
     WHERE c.event_id = p_event_id
       AND coalesce(c.offline_scanned_at, c.scanned_at) >= v_from
       AND coalesce(c.offline_scanned_at, c.scanned_at) < v_until
  ),
  b AS (
    SELECT to_timestamp(floor(extract(epoch FROM s.at) / (v_step * 60)) * (v_step * 60)) AS bucket,
           s.kind, s.list_id, s.gate,
           count(*) FILTER (WHERE s.direction = 'entry') AS entries,
           count(*) FILTER (WHERE s.direction = 'exit')  AS exits,
           count(*) FILTER (WHERE s.forced)              AS forced
      FROM scans s
     GROUP BY 1, 2, 3, 4
  ),
  g AS (
    SELECT s.kind, s.list_id, s.gate,
           count(*) FILTER (WHERE s.direction = 'entry') AS entries,
           count(*) FILTER (WHERE s.direction = 'exit')  AS exits,
           count(*) FILTER (WHERE s.forced)              AS forced,
           count(DISTINCT s.device)                      AS devices,
           min(s.at) AS first_at, max(s.at) AS last_at,
           (SELECT max(b.entries) FROM b WHERE b.kind = s.kind AND b.gate = s.gate
                                         AND b.list_id IS NOT DISTINCT FROM s.list_id) AS peak_entries
      FROM scans s
     GROUP BY s.kind, s.list_id, s.gate
  ),
  -- Direction is tracked on re-entry lists: inside = the last scan there
  -- (any time, not only this window) was an entry.
  rl AS (
    SELECT l.id, l.name, l.admits, l.entry_day, l.valid_from, l.valid_until,
           (l.valid_from IS NULL OR now() >= l.valid_from) AND (l.valid_until IS NULL OR now() <= l.valid_until) AS open_now
      FROM public.exos_checkin_lists l
     WHERE l.event_id = p_event_id AND l.allow_reentry
  ),
  t_last AS (
    SELECT DISTINCT ON (c.list_id, c.ticket_id) c.list_id, c.ticket_id, c.direction
      FROM public.exos_event_checkins c
     WHERE c.event_id = p_event_id AND c.list_id IN (SELECT id FROM rl)
     ORDER BY c.list_id, c.ticket_id, coalesce(c.offline_scanned_at, c.scanned_at) DESC, c.scanned_at DESC
  ),
  a_last AS (
    SELECT DISTINCT ON (c.list_id, c.pass_id) c.list_id, c.pass_id, c.direction
      FROM public.exos_addon_pass_checkins c
     WHERE c.event_id = p_event_id AND c.list_id IN (SELECT id FROM rl)
     ORDER BY c.list_id, c.pass_id, coalesce(c.offline_scanned_at, c.scanned_at) DESC, c.scanned_at DESC
  ),
  inside AS (
    SELECT rl.*,
           (SELECT count(*) FROM t_last x WHERE x.list_id = rl.id AND x.direction = 'entry') AS tickets_inside,
           (SELECT count(*) FROM a_last x WHERE x.list_id = rl.id AND x.direction = 'entry') AS addons_inside
      FROM rl
  ),
  rj AS (
    SELECT CASE WHEN regexp_replace(coalesce(r.reason_detail, ''), '^(offline-replay|name-replay):', '') ~ '^[a-z][a-z-]{1,39}$'
                THEN regexp_replace(r.reason_detail, '^(offline-replay|name-replay):', '')
                ELSE r.reason END AS reason,
           count(*) AS n
      FROM public.exos_scan_rejects r
     WHERE r.event_id = p_event_id AND r.rejected_at >= v_from AND r.rejected_at < v_until
     GROUP BY 1
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id,
    'timezone', e.timezone,
    'from', v_from, 'until', v_until, 'bucket_minutes', v_step,
    'buckets', coalesce((SELECT jsonb_agg(jsonb_build_object(
                  'at', b.bucket, 'kind', b.kind, 'list_id', b.list_id, 'gate', b.gate,
                  'entries', b.entries, 'exits', b.exits, 'forced', b.forced)
                  ORDER BY b.bucket, b.kind, b.gate) FROM b), '[]'::jsonb),
    'gates', coalesce((SELECT jsonb_agg(jsonb_build_object(
                  'kind', g.kind, 'list_id', g.list_id, 'gate', g.gate, 'entries', g.entries, 'exits', g.exits,
                  'forced', g.forced, 'devices', g.devices, 'first_at', g.first_at, 'last_at', g.last_at,
                  'peak_entries', g.peak_entries)
                  ORDER BY g.kind DESC, g.entries DESC, g.gate) FROM g), '[]'::jsonb),
    'inside', coalesce((SELECT jsonb_agg(jsonb_build_object(
                  'list_id', i.id, 'name', i.name, 'admits', i.admits, 'entry_day', i.entry_day, 'open_now', i.open_now,
                  'tickets_inside', i.tickets_inside, 'addons_inside', i.addons_inside)
                  ORDER BY i.entry_day NULLS LAST, i.name) FROM inside i), '[]'::jsonb),
    -- Distinct tickets inside on an open re-entry list (several gates of one
    -- day count a person once); the lot counts add-on passes.
    'in_park_now', (SELECT count(DISTINCT x.ticket_id) FROM t_last x JOIN rl ON rl.id = x.list_id
                     WHERE x.direction = 'entry' AND rl.open_now),
    'lot_now', (SELECT count(DISTINCT x.pass_id) FROM a_last x JOIN rl ON rl.id = x.list_id
                 WHERE x.direction = 'entry' AND rl.open_now),
    'tracks_direction', EXISTS (SELECT 1 FROM rl),
    'refusals', coalesce((SELECT jsonb_agg(jsonb_build_object('reason', rj.reason, 'count', rj.n)
                  ORDER BY rj.n DESC, rj.reason) FROM (SELECT * FROM rj ORDER BY n DESC, reason LIMIT 30) rj), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_door_throughput(uuid, timestamptz, timestamptz, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_door_throughput(uuid, timestamptz, timestamptz, int) TO authenticated, service_role;
