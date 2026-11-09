-- ============================================================================
-- Migration 20261030150000 — Exos: event series, collections, timed entry
--   (Opendate parity round 12; docs/series-timed-entry.md)
--
-- Touches:  W: exos_event_series (+status, +description, +image_url, +cancelled_at)
--              TABLE exos_series_occurrences (new; one row per series date)
--              TABLE exos_collections (new; RLS writes owner/manager/content)
--              TABLE exos_timed_entry (new; per-event slot config, RPC writes)
--              TABLE exos_event_slots (new; sparse slot inventory, RPC writes)
--              TABLE exos_slot_entry_overrides (new; door "admit anyway")
--              exos_cart_holds (+slot_id), exos_checkout_sessions (+slot_id),
--              exos_tickets (+slot_id, +slot_starts_at, +slot_ends_at,
--                            +slot_entry_from, +slot_entry_until)
--           P: exos_fulfill_checkout (slot capacity in the claim block, next
--              to the tier counter; marker exos.slot_mint)
--           P: exos_check_in_ticket (both overloads: entry window on live
--              entry scans; marker _exos_slot_entry_refusal)
--           NEW functions: see the grants block at the end.
-- Pre-reqs: 20260911133000 (+20260925001000) series, 20260702123000 holds,
--           20260929030000 (latest exos_fulfill_checkout), 20261019100000
--           (latest exos_check_in_ticket), 20260929140000 (door lists)
--
-- SERIES. The existing series (template = member 0, column-agnostic clones by
-- exos_create_event_series) gains a schedule: exos_series_occurrences holds a
-- row per DATE the series ever generated, cancelled, skipped or had removed,
-- keyed (series_id, occ_date). Generation inserts that row first (ON CONFLICT
-- DO NOTHING) and only clones for rows it actually inserted, so generating
-- twice, or two staff at once, never duplicates a date. The recurrence rule is
-- expanded by the shared TypeScript (src/lib/recurrence.ts); the database
-- enforces idempotence, the rule's exceptions, past dates and roles, so a
-- client sending odd dates can only add dates its own staff could add by hand.
-- Propagation (title, description, image, tier prices) skips dates edited
-- since the series last wrote them (an md5 fingerprint per field), dates with
-- sales (prices), past and cancelled dates, and reports each skip.
--
-- COLLECTIONS. A public page grouping events: manual (event ids, <= 100) or a
-- rule (series / artist / venue / tag) resolved on read against the org's
-- upcoming published events. Only published events ever leave the database
-- through the public functions.
--
-- TIMED ENTRY. exos_timed_entry is the per-event config (which tiers, slot
-- length, capacity per slot, optional per-tier cap, entry window, opening
-- hours per weekday, date range, closed dates). Slot ids are the wall-clock
-- start, 'YYYYMMDDTHHMM'. exos_event_slots is sparse: a row exists once a slot
-- held, sold or was changed by staff. Capacity is never oversold:
--   * checkout: exos_create_hold (tier + quota), then exos_attach_hold_slot
--     locks the slot row and counts sold + live slot holds;
--   * fulfillment: _exos_slot_commit locks the same row inside
--     exos_fulfill_checkout's all-or-nothing block (same transaction as the
--     tier counter) and refuses with XF001 (refund) when full;
--   * every ticket of a timed tier must carry a slot (BEFORE INSERT trigger),
--     so no other mint path (comps, free claims, box office, partners) can
--     sell into a slot without being counted; voids / refunds give the place
--     back (AFTER UPDATE OF status trigger).
-- Door: a live entry scan outside the ticket's entry window answers
-- 'outside-entry-window' (early / late) unless staff recorded "admit anyway"
-- (exos_admit_outside_window). Offline replays are decided on the device
-- (exos_event_door_slots syncs the windows), so the server doesn't re-judge
-- them.
--
-- Re-run safe: IF NOT EXISTS / OR REPLACE / marker-guarded patches.
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Patch helper (same as earlier migrations; markers keep a replay a no-op).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
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
-- 1. SERIES
-- ===========================================================================
ALTER TABLE public.exos_event_series
  ADD COLUMN IF NOT EXISTS status       text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'archived', 'cancelled')),
  ADD COLUMN IF NOT EXISTS description  text CHECK (description IS NULL OR char_length(description) <= 4000),
  ADD COLUMN IF NOT EXISTS image_url    text CHECK (image_url IS NULL OR char_length(image_url) <= 2000),
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;

CREATE TABLE IF NOT EXISTS public.exos_series_occurrences (
  series_id   uuid NOT NULL REFERENCES public.exos_event_series (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  occ_date    date NOT NULL,
  occ_time    time NOT NULL,
  starts_at   timestamptz NOT NULL,
  event_id    uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  status      text NOT NULL DEFAULT 'generated'
              CHECK (status IN ('generated', 'cancelled', 'skipped', 'removed')),
  -- md5 per field as the series last wrote it (name, description, image_url).
  fingerprint jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (series_id, occ_date)
);
CREATE INDEX IF NOT EXISTS exos_series_occurrences_event_idx
  ON public.exos_series_occurrences (event_id) WHERE event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_series_occurrences_org_idx ON public.exos_series_occurrences (org_id);
COMMENT ON TABLE public.exos_series_occurrences IS
  'Mig 20261030150000: one row per date a series generated, cancelled, skipped or had removed. The PK makes generation idempotent. Written only by the exos_series_* RPCs.';

ALTER TABLE public.exos_series_occurrences ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_series_occurrences_sel ON public.exos_series_occurrences;
CREATE POLICY exos_series_occurrences_sel ON public.exos_series_occurrences FOR SELECT TO authenticated
  USING (exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
REVOKE ALL ON public.exos_series_occurrences FROM anon, authenticated;
GRANT SELECT ON public.exos_series_occurrences TO authenticated;

-- Wall-clock date + time in a zone -> instant. Ambiguous times (the repeated
-- hour when clocks go back) take the earlier instant; times in the spring-
-- forward gap move forward by the gap (Postgres' own reading). Matches
-- zonedToUtcMs in src/lib/recurrence.ts.
CREATE OR REPLACE FUNCTION public._exos_zoned_ts(p_date date, p_time time, p_tz text)
RETURNS timestamptz LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_local timestamp := p_date + p_time; v_tz text := coalesce(nullif(p_tz, ''), 'UTC'); v_at timestamptz;
BEGIN
  BEGIN
    v_at := v_local AT TIME ZONE v_tz;
  EXCEPTION WHEN invalid_parameter_value THEN
    v_tz := 'UTC';
    v_at := v_local AT TIME ZONE 'UTC';
  END;
  IF ((v_at - interval '1 hour') AT TIME ZONE v_tz) = v_local THEN
    RETURN v_at - interval '1 hour';
  END IF;
  RETURN v_at;
END $$;

CREATE OR REPLACE FUNCTION public._exos_series_fp(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object('name', md5(coalesce(e.name, '')),
                            'description', md5(coalesce(e.description, '')),
                            'image_url', md5(coalesce(e.image_url, '')))
    FROM public.exos_events e WHERE e.id = p_event_id
$$;

CREATE OR REPLACE FUNCTION public._exos_series_tz(p_tz text)
RETURNS text LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM now() AT TIME ZONE coalesce(nullif(p_tz, ''), 'UTC');
  RETURN coalesce(nullif(p_tz, ''), 'UTC');
EXCEPTION WHEN invalid_parameter_value THEN
  RETURN 'UTC';
END $$;

-- The caller may manage this series (owner / manager / admin). Returns the row.
CREATE OR REPLACE FUNCTION public._exos_series_for_write(p_series_id uuid)
RETURNS public.exos_event_series LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_event_series%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'series: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO s FROM public.exos_event_series WHERE id = p_series_id;
  IF s.id IS NULL OR NOT (exos_is_admin() OR exos_has_org_role(s.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'series: not found' USING ERRCODE = '42501';
  END IF;
  RETURN s;
END $$;

-- Create a series from a template event and its recurrence rule. The template
-- becomes member 0 and its own date the first occurrence; dates are added
-- with exos_series_generate.
CREATE OR REPLACE FUNCTION public.exos_series_create(
  p_template_event_id uuid, p_name text, p_rule jsonb, p_description text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  e     public.exos_events%ROWTYPE;
  v_tz  text;
  v_id  uuid;
  v_loc timestamp;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_series_create: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_template_event_id FOR UPDATE;
  IF e.id IS NULL OR NOT (exos_is_admin() OR exos_has_org_role(e.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_series_create: event not found' USING ERRCODE = '42501';
  END IF;
  IF e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_series_create: a cancelled event can''t start a series' USING ERRCODE = '23514';
  END IF;
  IF e.series_id IS NOT NULL THEN
    RAISE EXCEPTION 'exos_series_create: this event is already in a series' USING ERRCODE = '23514';
  END IF;
  IF e.starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_series_create: the event has no start time' USING ERRCODE = '23514';
  END IF;
  IF coalesce(to_jsonb(e) ->> 'ticket_backend', 'exos') <> 'exos' THEN
    RAISE EXCEPTION 'exos_series_create: an externally ticketed event can''t start a series' USING ERRCODE = '23514';
  END IF;
  IF p_rule IS NULL OR jsonb_typeof(p_rule) <> 'object'
     OR coalesce(p_rule ->> 'freq', '') NOT IN ('daily', 'weekly', 'monthly')
     OR coalesce(p_rule ->> 'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     OR coalesce(p_rule ->> 'startDate', '') !~ '^\d{4}-\d{2}-\d{2}$'
     OR length(p_rule::text) > 20000 THEN
    RAISE EXCEPTION 'exos_series_create: rule needs freq, startDate and time' USING ERRCODE = '22023';
  END IF;

  v_tz := public._exos_series_tz(e.timezone);
  INSERT INTO public.exos_event_series (org_id, name, kind, template_event_id, timezone, rule, created_by, description, image_url)
  VALUES (e.org_id, left(coalesce(nullif(btrim(p_name), ''), e.name, 'Series'), 200), 'recurring', e.id, v_tz,
          p_rule, v_uid, left(nullif(btrim(p_description), ''), 4000), e.image_url)
  RETURNING id INTO v_id;
  UPDATE public.exos_events SET series_id = v_id, series_index = 0 WHERE id = e.id;

  v_loc := e.starts_at AT TIME ZONE v_tz;
  INSERT INTO public.exos_series_occurrences (series_id, org_id, occ_date, occ_time, starts_at, event_id, fingerprint)
  VALUES (v_id, e.org_id, v_loc::date, v_loc::time, e.starts_at, e.id, public._exos_series_fp(e.id));
  RETURN v_id;
END $$;

-- Generate the given dates ([{date:'YYYY-MM-DD', time:'HH:MM'}], <= 120 per
-- call; the client expands the rule with src/lib/recurrence.ts). Each new
-- date becomes a draft clone of the template. Dates already recorded (any
-- status), past starts and the rule's exceptions are skipped and reported.
CREATE OR REPLACE FUNCTION public.exos_series_generate(p_series_id uuid, p_dates jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s         public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id);
  v_tz      text := public._exos_series_tz(s.timezone);
  v_exc     text[];
  d         jsonb;
  v_date    date;
  v_time    time;
  v_at      timestamptz;
  v_new     timestamptz[] := '{}';
  v_created jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_ins     int;
  v_member  uuid;
  r         record;
BEGIN
  IF s.status <> 'active' THEN
    RAISE EXCEPTION 'exos_series_generate: the series is %', s.status USING ERRCODE = '23514';
  END IF;
  IF s.template_event_id IS NULL THEN
    RAISE EXCEPTION 'exos_series_generate: the series has no template event' USING ERRCODE = '23514';
  END IF;
  IF p_dates IS NULL OR jsonb_typeof(p_dates) <> 'array' THEN
    RAISE EXCEPTION 'exos_series_generate: dates must be an array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_dates) > 120 THEN
    RAISE EXCEPTION 'exos_series_generate: at most 120 dates per call' USING ERRCODE = '22023';
  END IF;
  SELECT coalesce(array_agg(x), '{}') INTO v_exc
    FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(s.rule -> 'exceptions') = 'array'
                                        THEN s.rule -> 'exceptions' ELSE '[]'::jsonb END) x;
  -- One generator at a time per series (the PK would hold anyway; this keeps
  -- the clone batch and its occurrence rows together).
  PERFORM 1 FROM public.exos_event_series WHERE id = s.id FOR UPDATE;

  FOR d IN SELECT * FROM jsonb_array_elements(p_dates) LOOP
    BEGIN
      v_date := (d ->> 'date')::date;
      IF coalesce(d ->> 'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
        RAISE EXCEPTION 'bad time';
      END IF;
      v_time := (d ->> 'time')::time;
    EXCEPTION WHEN others THEN
      v_skipped := v_skipped || jsonb_build_object('date', d ->> 'date', 'reason', 'invalid');
      CONTINUE;
    END;
    IF v_date::text = ANY (v_exc) THEN
      v_skipped := v_skipped || jsonb_build_object('date', v_date, 'reason', 'exception');
      CONTINUE;
    END IF;
    v_at := public._exos_zoned_ts(v_date, v_time, v_tz);
    IF v_at <= now() THEN
      v_skipped := v_skipped || jsonb_build_object('date', v_date, 'reason', 'past');
      CONTINUE;
    END IF;
    INSERT INTO public.exos_series_occurrences (series_id, org_id, occ_date, occ_time, starts_at)
    VALUES (s.id, s.org_id, v_date, v_time, v_at)
    ON CONFLICT (series_id, occ_date) DO NOTHING;
    GET DIAGNOSTICS v_ins = ROW_COUNT;
    IF v_ins = 0 THEN
      v_skipped := v_skipped || jsonb_build_object('date', v_date, 'reason', 'exists');
      CONTINUE;
    END IF;
    -- A member made before occurrences existed (exos_create_event_series) at
    -- this exact start: adopt it rather than cloning a twin.
    SELECT id INTO v_member FROM public.exos_events WHERE series_id = s.id AND starts_at = v_at LIMIT 1;
    IF v_member IS NOT NULL THEN
      UPDATE public.exos_series_occurrences SET event_id = v_member, fingerprint = public._exos_series_fp(v_member)
       WHERE series_id = s.id AND occ_date = v_date;
      v_created := v_created || jsonb_build_object('date', v_date, 'event_id', v_member, 'adopted', true);
      CONTINUE;
    END IF;
    v_new := v_new || v_at;
  END LOOP;

  IF cardinality(v_new) > 0 THEN
    FOR r IN SELECT * FROM public.exos_create_event_series(s.template_event_id, v_new, 'recurring', NULL, NULL, false) LOOP
      UPDATE public.exos_series_occurrences o
         SET event_id = r.event_id, fingerprint = public._exos_series_fp(r.event_id), updated_at = now()
       WHERE o.series_id = s.id AND o.starts_at = r.starts_at AND o.event_id IS NULL;
      v_created := v_created || jsonb_build_object(
        'date', (SELECT o.occ_date FROM public.exos_series_occurrences o WHERE o.series_id = s.id AND o.event_id = r.event_id),
        'event_id', r.event_id);
    END LOOP;
  END IF;
  UPDATE public.exos_event_series SET updated_at = now() WHERE id = s.id;
  RETURN jsonb_build_object('created', v_created, 'skipped', v_skipped);
END $$;

-- Publish every generated draft date that hasn't started. Returns the count.
CREATE OR REPLACE FUNCTION public.exos_series_publish(p_series_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id); v_n int;
BEGIN
  IF s.status <> 'active' THEN
    RAISE EXCEPTION 'exos_series_publish: the series is %', s.status USING ERRCODE = '23514';
  END IF;
  UPDATE public.exos_events e SET status = 'published'
    FROM public.exos_series_occurrences o
   WHERE o.series_id = s.id AND o.event_id = e.id AND o.status = 'generated'
     AND e.series_id = s.id AND e.status = 'draft' AND e.starts_at > now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- Cancel one event (status + optional reason/stamp where those columns exist).
-- The event-cancelled trigger mails holders; refunds run through exos-refund.
CREATE OR REPLACE FUNCTION public._exos_series_cancel_event(p_event_id uuid, p_reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  UPDATE public.exos_events SET status = 'cancelled' WHERE id = p_event_id AND status <> 'cancelled';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 AND EXISTS (SELECT 1 FROM information_schema.columns
                          WHERE table_schema = 'public' AND table_name = 'exos_events' AND column_name = 'cancel_reason') THEN
    EXECUTE 'UPDATE public.exos_events SET cancelled_at = now(), cancel_reason = $2 WHERE id = $1'
      USING p_event_id, left(nullif(btrim(p_reason), ''), 500);
  END IF;
  RETURN v_n > 0;
END $$;

-- Cancel one date. With an event: the event is cancelled (holders mailed by
-- the trigger; the dashboard then refunds through exos-refund cancel_event).
-- Without one yet: the date is recorded 'skipped' and never generated.
CREATE OR REPLACE FUNCTION public.exos_series_cancel_date(p_series_id uuid, p_date date, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id);
  o public.exos_series_occurrences%ROWTYPE;
  v_tz text := public._exos_series_tz(s.timezone);
BEGIN
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'exos_series_cancel_date: date required' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO o FROM public.exos_series_occurrences WHERE series_id = s.id AND occ_date = p_date FOR UPDATE;
  IF o.series_id IS NULL THEN
    IF p_date < (now() AT TIME ZONE v_tz)::date THEN
      RAISE EXCEPTION 'exos_series_cancel_date: that date has passed' USING ERRCODE = '23514';
    END IF;
    INSERT INTO public.exos_series_occurrences (series_id, org_id, occ_date, occ_time, starts_at, status)
    VALUES (s.id, s.org_id, p_date, coalesce(nullif(s.rule ->> 'time', '')::time, '00:00'),
            public._exos_zoned_ts(p_date, coalesce(nullif(s.rule ->> 'time', '')::time, '00:00'), v_tz), 'skipped');
    RETURN jsonb_build_object('date', p_date, 'status', 'skipped', 'event_id', NULL);
  END IF;
  IF o.status IN ('skipped', 'removed') THEN
    RETURN jsonb_build_object('date', p_date, 'status', o.status, 'event_id', o.event_id);
  END IF;
  IF o.event_id IS NOT NULL THEN
    PERFORM public._exos_series_cancel_event(o.event_id, p_reason);
  END IF;
  UPDATE public.exos_series_occurrences SET status = CASE WHEN o.event_id IS NULL THEN 'skipped' ELSE 'cancelled' END,
         updated_at = now()
   WHERE series_id = s.id AND occ_date = p_date;
  RETURN jsonb_build_object('date', p_date, 'status', CASE WHEN o.event_id IS NULL THEN 'skipped' ELSE 'cancelled' END,
                            'event_id', o.event_id);
END $$;

-- Edit future dates: { name?, description?, image_url?, prices?: { "<tier name>": number } }.
CREATE OR REPLACE FUNCTION public.exos_series_propagate(p_series_id uuid, p_changes jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s         public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id);
  o         record;
  e         public.exos_events%ROWTYPE;
  f         text;
  v_cur     text;
  v_fp      jsonb;
  v_fields  text[];
  v_changed jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_prices  jsonb := CASE WHEN jsonb_typeof(p_changes -> 'prices') = 'object' THEN p_changes -> 'prices' ELSE '{}'::jsonb END;
  t         record;
  v_tpl     boolean;
BEGIN
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
    RAISE EXCEPTION 'exos_series_propagate: changes must be an object' USING ERRCODE = '22023';
  END IF;
  IF p_changes ? 'name' AND char_length(btrim(coalesce(p_changes ->> 'name', ''))) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'exos_series_propagate: name must be 1-200 characters' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_each(v_prices) p
              WHERE CASE WHEN jsonb_typeof(p.value) <> 'number' THEN true
                         ELSE (p.value)::numeric NOT BETWEEN 0 AND 100000 END) THEN
    RAISE EXCEPTION 'exos_series_propagate: prices must be numbers from 0 to 100000' USING ERRCODE = '22023';
  END IF;

  FOR o IN
    SELECT oc.* FROM public.exos_series_occurrences oc
     WHERE oc.series_id = s.id AND oc.event_id IS NOT NULL AND oc.status IN ('generated', 'cancelled')
     ORDER BY oc.occ_date
  LOOP
    SELECT * INTO e FROM public.exos_events WHERE id = o.event_id FOR UPDATE;
    IF e.id IS NULL OR e.series_id IS DISTINCT FROM s.id THEN CONTINUE; END IF;
    v_tpl := e.id = s.template_event_id;
    IF e.status = 'cancelled' OR o.status = 'cancelled' THEN
      v_skipped := v_skipped || jsonb_build_object('event_id', e.id, 'date', o.occ_date, 'field', '*', 'reason', 'cancelled');
      CONTINUE;
    END IF;
    -- The template is the source of later dates: it always takes the edit.
    IF NOT v_tpl AND e.starts_at <= now() THEN
      v_skipped := v_skipped || jsonb_build_object('event_id', e.id, 'date', o.occ_date, 'field', '*', 'reason', 'past');
      CONTINUE;
    END IF;
    v_fp := o.fingerprint;
    v_fields := '{}';
    FOREACH f IN ARRAY ARRAY['name', 'description', 'image_url'] LOOP
      CONTINUE WHEN NOT p_changes ? f;
      v_cur := CASE f WHEN 'name' THEN e.name WHEN 'description' THEN e.description ELSE e.image_url END;
      IF NOT v_tpl AND (v_fp ->> f) IS DISTINCT FROM md5(coalesce(v_cur, '')) THEN
        v_skipped := v_skipped || jsonb_build_object('event_id', e.id, 'date', o.occ_date, 'field', f, 'reason', 'edited');
        CONTINUE;
      END IF;
      EXECUTE format('UPDATE public.exos_events SET %I = $1 WHERE id = $2', f)
        USING CASE WHEN f = 'name' THEN left(btrim(p_changes ->> f), 200) ELSE nullif(p_changes ->> f, '') END, e.id;
      v_fields := v_fields || f;
    END LOOP;
    FOR t IN SELECT tt.id, tt.name, tt.sold FROM public.exos_ticket_tiers tt
              WHERE tt.event_id = e.id AND v_prices ? coalesce(tt.name, '') LOOP
      IF t.sold > 0 THEN
        v_skipped := v_skipped || jsonb_build_object('event_id', e.id, 'date', o.occ_date, 'field', 'price:' || t.name, 'reason', 'has_sales');
        CONTINUE;
      END IF;
      UPDATE public.exos_ticket_tiers SET price = (v_prices ->> t.name)::numeric WHERE id = t.id;
      v_fields := v_fields || ('price:' || t.name);
    END LOOP;
    IF cardinality(v_fields) > 0 THEN
      UPDATE public.exos_series_occurrences SET fingerprint = public._exos_series_fp(e.id), updated_at = now()
       WHERE series_id = s.id AND occ_date = o.occ_date;
      v_changed := v_changed || jsonb_build_object('event_id', e.id, 'date', o.occ_date, 'fields', to_jsonb(v_fields));
    END IF;
  END LOOP;
  IF p_changes ? 'image_url' THEN
    UPDATE public.exos_event_series SET image_url = nullif(p_changes ->> 'image_url', '') WHERE id = s.id;
  END IF;
  UPDATE public.exos_event_series SET updated_at = now() WHERE id = s.id;
  RETURN jsonb_build_object('changed', v_changed, 'skipped', v_skipped);
END $$;

-- Series details: { name?, description?, image_url?, rule?, status?: 'active' | 'archived' }.
-- A rule change only affects later generation; nothing existing moves.
CREATE OR REPLACE FUNCTION public.exos_series_update(p_series_id uuid, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id);
BEGIN
  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'exos_series_update: patch must be an object' USING ERRCODE = '22023';
  END IF;
  IF s.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_series_update: the series is cancelled' USING ERRCODE = '23514';
  END IF;
  IF p_patch ? 'status' AND coalesce(p_patch ->> 'status', '') NOT IN ('active', 'archived') THEN
    RAISE EXCEPTION 'exos_series_update: status must be active or archived (cancel with exos_series_cancel)' USING ERRCODE = '22023';
  END IF;
  IF p_patch ? 'rule' AND (jsonb_typeof(p_patch -> 'rule') <> 'object'
       OR coalesce(p_patch -> 'rule' ->> 'freq', '') NOT IN ('daily', 'weekly', 'monthly')
       OR coalesce(p_patch -> 'rule' ->> 'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
       OR length((p_patch -> 'rule')::text) > 20000) THEN
    RAISE EXCEPTION 'exos_series_update: rule needs freq and time' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_event_series SET
    name        = CASE WHEN p_patch ? 'name' AND char_length(btrim(p_patch ->> 'name')) BETWEEN 1 AND 200
                       THEN btrim(p_patch ->> 'name') ELSE name END,
    description = CASE WHEN p_patch ? 'description' THEN left(nullif(btrim(p_patch ->> 'description'), ''), 4000) ELSE description END,
    image_url   = CASE WHEN p_patch ? 'image_url' THEN left(nullif(btrim(p_patch ->> 'image_url'), ''), 2000) ELSE image_url END,
    rule        = CASE WHEN p_patch ? 'rule' THEN p_patch -> 'rule' ELSE rule END,
    status      = CASE WHEN p_patch ? 'status' THEN p_patch ->> 'status' ELSE status END,
    updated_at  = now()
  WHERE id = s.id
  RETURNING * INTO s;
  RETURN to_jsonb(s);
END $$;

-- Cancel the whole series. scope is required: 'series_only' (shows keep
-- running), 'all_shows' (every future show is cancelled too) or 'selected'
-- (only p_event_ids that are members).
CREATE OR REPLACE FUNCTION public.exos_series_cancel(p_series_id uuid, p_scope text, p_event_ids uuid[] DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s     public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id);
  v_ids uuid[] := '{}';
  r     record;
BEGIN
  IF coalesce(p_scope, '') NOT IN ('series_only', 'all_shows', 'selected') THEN
    RAISE EXCEPTION 'exos_series_cancel: scope must be series_only, all_shows or selected' USING ERRCODE = '22023';
  END IF;
  FOR r IN SELECT e.id FROM public.exos_events e
            WHERE e.series_id = s.id AND e.status <> 'cancelled' AND e.starts_at > now()
              AND (p_scope = 'all_shows' OR (p_scope = 'selected' AND e.id = ANY (coalesce(p_event_ids, '{}'))))
            ORDER BY e.starts_at LOOP
    IF public._exos_series_cancel_event(r.id, p_reason) THEN
      v_ids := v_ids || r.id;
    END IF;
  END LOOP;
  IF p_scope = 'selected' AND cardinality(v_ids) = 0 AND cardinality(coalesce(p_event_ids, '{}')) > 0 THEN
    RAISE EXCEPTION 'exos_series_cancel: none of the selected shows can be cancelled' USING ERRCODE = '23514';
  END IF;
  UPDATE public.exos_series_occurrences SET status = 'cancelled', updated_at = now()
   WHERE series_id = s.id AND event_id = ANY (v_ids);
  UPDATE public.exos_event_series SET status = 'cancelled', cancelled_at = now(), updated_at = now() WHERE id = s.id;
  RETURN jsonb_build_object('series_id', s.id, 'status', 'cancelled', 'cancelled_event_ids', to_jsonb(v_ids));
END $$;

-- Delete a series that never sold: its unsold, unpublished generated dates
-- are deleted, the template (and any published member) is detached and kept.
CREATE OR REPLACE FUNCTION public.exos_series_delete(p_series_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id);
  v_drop  uuid[];
  v_keep  int;
BEGIN
  IF EXISTS (SELECT 1 FROM public.exos_events e
              WHERE e.series_id = s.id
                AND (e.tickets_sold > 0 OR EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.event_id = e.id))) THEN
    RAISE EXCEPTION 'exos_series_delete: a date in this series has tickets; cancel the series instead' USING ERRCODE = '23514';
  END IF;
  SELECT coalesce(array_agg(e.id), '{}') INTO v_drop FROM public.exos_events e
   WHERE e.series_id = s.id AND e.id IS DISTINCT FROM s.template_event_id AND e.status = 'draft';
  UPDATE public.exos_events SET series_id = NULL, series_index = NULL
   WHERE series_id = s.id AND NOT (id = ANY (v_drop));
  GET DIAGNOSTICS v_keep = ROW_COUNT;
  BEGIN
    DELETE FROM public.exos_ticket_tiers WHERE event_id = ANY (v_drop);
    DELETE FROM public.exos_events WHERE id = ANY (v_drop);
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'exos_series_delete: a draft date is referenced elsewhere; cancel the series instead' USING ERRCODE = '23514';
  END;
  DELETE FROM public.exos_event_series WHERE id = s.id;
  RETURN jsonb_build_object('deleted_event_ids', to_jsonb(v_drop), 'detached', v_keep);
END $$;

-- Attach an existing event of the org by reference (nothing is copied).
CREATE OR REPLACE FUNCTION public.exos_series_attach_event(p_series_id uuid, p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s     public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id);
  e     public.exos_events%ROWTYPE;
  o     public.exos_series_occurrences%ROWTYPE;
  v_loc timestamp;
  v_idx int;
BEGIN
  IF s.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_series_attach_event: the series is cancelled' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF e.id IS NULL OR e.org_id <> s.org_id THEN
    RAISE EXCEPTION 'exos_series_attach_event: event not found' USING ERRCODE = '42501';
  END IF;
  IF e.status = 'cancelled' OR e.starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_series_attach_event: a cancelled or undated event can''t join' USING ERRCODE = '23514';
  END IF;
  IF e.series_id IS NOT NULL AND e.series_id <> s.id THEN
    RAISE EXCEPTION 'exos_series_attach_event: the event is in another series' USING ERRCODE = '23514';
  END IF;
  v_loc := e.starts_at AT TIME ZONE public._exos_series_tz(s.timezone);
  SELECT * INTO o FROM public.exos_series_occurrences WHERE series_id = s.id AND occ_date = v_loc::date FOR UPDATE;
  IF o.series_id IS NOT NULL AND NOT (o.status IN ('removed', 'skipped') OR o.event_id = e.id) THEN
    RAISE EXCEPTION 'exos_series_attach_event: the series already has a show on %', v_loc::date USING ERRCODE = '23505';
  END IF;
  IF e.series_id IS NULL THEN
    SELECT coalesce(max(series_index), 0) + 1 INTO v_idx FROM public.exos_events WHERE series_id = s.id;
    UPDATE public.exos_events SET series_id = s.id, series_index = v_idx WHERE id = e.id;
  END IF;
  INSERT INTO public.exos_series_occurrences (series_id, org_id, occ_date, occ_time, starts_at, event_id, status, fingerprint)
  VALUES (s.id, s.org_id, v_loc::date, v_loc::time, e.starts_at, e.id, 'generated', public._exos_series_fp(e.id))
  ON CONFLICT (series_id, occ_date) DO UPDATE
    SET event_id = EXCLUDED.event_id, occ_time = EXCLUDED.occ_time, starts_at = EXCLUDED.starts_at,
        status = 'generated', fingerprint = EXCLUDED.fingerprint, updated_at = now();
  RETURN jsonb_build_object('series_id', s.id, 'event_id', e.id, 'date', v_loc::date);
END $$;

-- Detach a show (it keeps selling as a standalone event). The date stays
-- recorded as 'removed', so generation never re-creates it.
CREATE OR REPLACE FUNCTION public.exos_series_detach_event(p_series_id uuid, p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_event_series%ROWTYPE := public._exos_series_for_write(p_series_id); v_n int;
BEGIN
  IF p_event_id = s.template_event_id THEN
    RAISE EXCEPTION 'exos_series_detach_event: the template can''t leave its series' USING ERRCODE = '23514';
  END IF;
  UPDATE public.exos_events SET series_id = NULL, series_index = NULL WHERE id = p_event_id AND series_id = s.id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.exos_series_occurrences SET status = 'removed', updated_at = now()
   WHERE series_id = s.id AND event_id = p_event_id;
  RETURN v_n > 0;
END $$;

-- ---------------------------------------------------------------------------
-- Public event shape (published events only; column-agnostic so prod's extra
-- columns come through where they exist).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_public_event_json(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT (SELECT jsonb_object_agg(k.key, k.value) FROM jsonb_each(to_jsonb(e)) k
           WHERE k.key = ANY (ARRAY['id','name','slug','starts_at','doors_at','ends_at','timezone','occurs_at_local',
                                     'currency','venue_name','venue_location','venue_address','image_url','summary',
                                     'category','genres','subgenres','primary_performer_name','performer_names',
                                     'min_age','format','series_id','series_index']))
         || jsonb_build_object('from_price',
              (SELECT min(t.price) FROM public.exos_ticket_tiers t
                WHERE t.event_id = e.id AND coalesce(t.visibility, 'public') = 'public'),
              'sold_out', e.total_tickets > 0 AND e.tickets_sold >= e.total_tickets)
    FROM public.exos_events e
   WHERE e.id = p_event_id AND e.status = 'published'
$$;

-- One public series: its upcoming published dates, paged. NULL when the
-- series isn't active or has no upcoming published date.
CREATE OR REPLACE FUNCTION public.exos_public_series(p_series_id uuid, p_page int DEFAULT 1, p_per_page int DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s      public.exos_event_series%ROWTYPE;
  v_per  int := least(greatest(coalesce(p_per_page, 20), 1), 100);
  v_page int := least(greatest(coalesce(p_page, 1), 1), 1000);
  v_n    int;
  v_tpl  public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO s FROM public.exos_event_series WHERE id = p_series_id AND status = 'active';
  IF s.id IS NULL THEN RETURN NULL; END IF;
  SELECT count(*) INTO v_n FROM public.exos_events e
   WHERE e.series_id = s.id AND e.status = 'published' AND coalesce(e.ends_at, e.starts_at) >= now();
  IF v_n = 0 THEN RETURN NULL; END IF;
  SELECT * INTO v_tpl FROM public.exos_events WHERE id = s.template_event_id;
  RETURN jsonb_build_object(
    'id', s.id, 'name', s.name,
    'description', coalesce(s.description, v_tpl.description),
    'image_url', coalesce(s.image_url, v_tpl.image_url),
    'org', (SELECT jsonb_build_object('name', o.name, 'slug', o.slug) FROM public.exos_orgs o WHERE o.id = s.org_id),
    'upcoming_count', v_n, 'page', v_page, 'per_page', v_per, 'total_pages', ceil(v_n::numeric / v_per)::int,
    'events', coalesce((SELECT jsonb_agg(public._exos_public_event_json(x.id) ORDER BY x.starts_at, x.id)
                          FROM (SELECT e.id, e.starts_at FROM public.exos_events e
                                 WHERE e.series_id = s.id AND e.status = 'published'
                                   AND coalesce(e.ends_at, e.starts_at) >= now()
                                 ORDER BY e.starts_at, e.id
                                 OFFSET (v_page - 1) * v_per LIMIT v_per) x), '[]'::jsonb));
END $$;

-- An org's public series (venue website list): each active series with an
-- upcoming published date, its next 10 dates and the upcoming count.
CREATE OR REPLACE FUNCTION public.exos_public_org_series(p_org_slug text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(x.j ORDER BY x.next_at, x.id), '[]'::jsonb)
    FROM (
      SELECT s.id, min(e.starts_at) AS next_at,
             jsonb_build_object(
               'id', s.id, 'name', s.name,
               'description', coalesce(s.description, (SELECT t.description FROM public.exos_events t WHERE t.id = s.template_event_id)),
               'image_url', coalesce(s.image_url, (SELECT t.image_url FROM public.exos_events t WHERE t.id = s.template_event_id)),
               'upcoming_count', count(*),
               'events', (SELECT jsonb_agg(public._exos_public_event_json(n.id) ORDER BY n.starts_at, n.id)
                            FROM (SELECT e2.id, e2.starts_at FROM public.exos_events e2
                                   WHERE e2.series_id = s.id AND e2.status = 'published'
                                     AND coalesce(e2.ends_at, e2.starts_at) >= now()
                                   ORDER BY e2.starts_at, e2.id LIMIT 10) n)) AS j
        FROM public.exos_orgs o
        JOIN public.exos_event_series s ON s.org_id = o.id AND s.status = 'active'
        JOIN public.exos_events e ON e.series_id = s.id AND e.status = 'published'
                                 AND coalesce(e.ends_at, e.starts_at) >= now()
       WHERE o.slug = p_org_slug
       GROUP BY s.id
       LIMIT 100) x
$$;

-- ===========================================================================
-- 2. COLLECTIONS
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_collections (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name        text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  slug        text NOT NULL CHECK (slug ~ '^[a-z0-9](?:[a-z0-9-]{0,78}[a-z0-9])?$'),
  description text CHECK (description IS NULL OR char_length(description) <= 4000),
  image_url   text CHECK (image_url IS NULL OR char_length(image_url) <= 2000),
  mode        text NOT NULL DEFAULT 'manual' CHECK (mode IN ('manual', 'rule')),
  event_ids   uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(event_ids) <= 100),
  rule_kind   text CHECK (rule_kind IS NULL OR rule_kind IN ('series', 'artist', 'venue', 'tag')),
  rule_value  text CHECK (rule_value IS NULL OR char_length(rule_value) BETWEEN 1 AND 200),
  published   boolean NOT NULL DEFAULT false,
  sort_order  int NOT NULL DEFAULT 0,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, slug),
  CHECK (mode = 'manual' OR (rule_kind IS NOT NULL AND rule_value IS NOT NULL))
);
COMMENT ON TABLE public.exos_collections IS
  'Mig 20261030150000: a public page grouping events (manual list or a rule). Public reads only through exos_public_collection (published events only).';

ALTER TABLE public.exos_collections ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_collections_sel ON public.exos_collections;
CREATE POLICY exos_collections_sel ON public.exos_collections FOR SELECT TO authenticated
  USING (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
DROP POLICY IF EXISTS exos_collections_ins ON public.exos_collections;
CREATE POLICY exos_collections_ins ON public.exos_collections FOR INSERT TO authenticated
  WITH CHECK (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','content']));
DROP POLICY IF EXISTS exos_collections_upd ON public.exos_collections;
CREATE POLICY exos_collections_upd ON public.exos_collections FOR UPDATE TO authenticated
  USING (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','content']))
  WITH CHECK (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','content']));
DROP POLICY IF EXISTS exos_collections_del ON public.exos_collections;
CREATE POLICY exos_collections_del ON public.exos_collections FOR DELETE TO authenticated
  USING (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','content']));
REVOKE ALL ON public.exos_collections FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_collections TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_tg_collections()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.slug := lower(btrim(NEW.slug));
  NEW.name := btrim(NEW.name);
  NEW.updated_at := now();
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
  ELSE
    NEW.org_id := OLD.org_id;          -- a collection never changes org
    NEW.created_by := OLD.created_by;
  END IF;
  -- Manual lists keep only distinct ids; the public read filters by org anyway.
  SELECT coalesce(array_agg(DISTINCT x), '{}') INTO NEW.event_ids FROM unnest(NEW.event_ids) x;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS exos_collections_biu ON public.exos_collections;
CREATE TRIGGER exos_collections_biu BEFORE INSERT OR UPDATE ON public.exos_collections
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_collections();

-- The collection's events: manual ids in this org, or the rule against the
-- org's events. p_public: published and upcoming only (500 scanned for rules).
CREATE OR REPLACE FUNCTION public._exos_collection_event_ids(p_collection_id uuid, p_public boolean)
RETURNS SETOF uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_collections%ROWTYPE; v text;
BEGIN
  SELECT * INTO c FROM public.exos_collections WHERE id = p_collection_id;
  IF c.id IS NULL THEN RETURN; END IF;
  v := lower(btrim(coalesce(c.rule_value, '')));
  RETURN QUERY
    SELECT x.id FROM (
      SELECT e.id, e.starts_at, to_jsonb(e) AS j FROM public.exos_events e
       WHERE e.org_id = c.org_id
         AND (NOT p_public OR (e.status = 'published' AND coalesce(e.ends_at, e.starts_at) >= now()))
         AND (c.mode = 'rule' OR e.id = ANY (c.event_ids))
       ORDER BY e.starts_at NULLS LAST, e.id
       LIMIT 500) x
     WHERE c.mode = 'manual'
        OR (c.rule_kind = 'series' AND x.j ->> 'series_id' = c.rule_value)
        OR (c.rule_kind = 'venue' AND lower(coalesce(x.j ->> 'venue_name', '')) = v)
        OR (c.rule_kind = 'artist' AND (lower(coalesce(x.j ->> 'primary_performer_name', '')) = v
              OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(x.j -> 'performer_names') = 'array'
                                                                       THEN x.j -> 'performer_names' ELSE '[]'::jsonb END) p
                          WHERE lower(p) = v)))
        OR (c.rule_kind = 'tag' AND (lower(coalesce(x.j ->> 'category', '')) = v
              OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(
                           (CASE WHEN jsonb_typeof(x.j -> 'genres') = 'array' THEN x.j -> 'genres' ELSE '[]'::jsonb END)
                           || (CASE WHEN jsonb_typeof(x.j -> 'subgenres') = 'array' THEN x.j -> 'subgenres' ELSE '[]'::jsonb END)) g
                          WHERE lower(g) = v)))
     ORDER BY x.starts_at NULLS LAST, x.id;
END $$;

-- Staff preview (drafts included): owner/manager/finance/scanner/content.
CREATE OR REPLACE FUNCTION public.exos_collection_event_ids(p_collection_id uuid)
RETURNS SETOF uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_collections WHERE id = p_collection_id;
  IF v_org IS NULL OR NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','finance','scanner','content'])) THEN
    RAISE EXCEPTION 'exos_collection_event_ids: not found' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public._exos_collection_event_ids(p_collection_id, false);
END $$;

-- The public collection page: published collection, upcoming published events.
CREATE OR REPLACE FUNCTION public.exos_public_collection(p_org_slug text, p_slug text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_collections%ROWTYPE; o public.exos_orgs%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.exos_orgs WHERE slug = p_org_slug;
  IF o.id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.exos_collections WHERE org_id = o.id AND slug = lower(btrim(p_slug)) AND published;
  IF c.id IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'id', c.id, 'name', c.name, 'slug', c.slug, 'description', c.description, 'image_url', c.image_url,
    'org', jsonb_build_object('name', o.name, 'slug', o.slug),
    'events', coalesce((SELECT jsonb_agg(q.j ORDER BY q.n) FROM (
                 SELECT public._exos_public_event_json(i.id) AS j, i.n
                   FROM public._exos_collection_event_ids(c.id, true) WITH ORDINALITY i(id, n)) q
                WHERE q.j IS NOT NULL), '[]'::jsonb));
END $$;

-- ===========================================================================
-- 3. TIMED ENTRY
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_timed_entry (
  event_id             uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id               uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  tier_ids             uuid[] NOT NULL CHECK (cardinality(tier_ids) BETWEEN 1 AND 50),
  slot_minutes         int NOT NULL CHECK (slot_minutes BETWEEN 5 AND 480),
  capacity             int NOT NULL CHECK (capacity BETWEEN 1 AND 100000),
  tier_capacity        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(tier_capacity) = 'object'),
  entry_window_minutes int CHECK (entry_window_minutes IS NULL OR entry_window_minutes BETWEEN 1 AND 1440),
  early_entry_minutes  int NOT NULL DEFAULT 0 CHECK (early_entry_minutes BETWEEN 0 AND 240),
  hours                jsonb NOT NULL CHECK (jsonb_typeof(hours) = 'object'),
  start_date           date NOT NULL,
  end_date             date NOT NULL,
  closed_dates         date[] NOT NULL DEFAULT '{}' CHECK (cardinality(closed_dates) <= 200),
  version              bigint NOT NULL DEFAULT 0,
  updated_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date AND end_date - start_date <= 400)
);
COMMENT ON TABLE public.exos_timed_entry IS
  'Mig 20261030150000: timed-entry config per event (docs/series-timed-entry.md). Written only by exos_set_timed_entry / exos_clear_timed_entry.';

CREATE TABLE IF NOT EXISTS public.exos_event_slots (
  event_id   uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  slot_id    text NOT NULL CHECK (slot_id ~ '^\d{8}T\d{4}$'),
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  starts_at  timestamptz NOT NULL,
  ends_at    timestamptz NOT NULL,
  -- NULL: the config's capacity; set: staff changed it (kept across config edits).
  capacity   int CHECK (capacity IS NULL OR capacity BETWEEN 0 AND 100000),
  closed     boolean NOT NULL DEFAULT false,
  sold       int NOT NULL DEFAULT 0 CHECK (sold >= 0),
  tier_sold  jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, slot_id)
);
COMMENT ON TABLE public.exos_event_slots IS
  'Mig 20261030150000: sparse slot inventory (a row once a slot held, sold or was changed). Locked FOR UPDATE by exos_attach_hold_slot and _exos_slot_commit; written by definer functions only.';

CREATE TABLE IF NOT EXISTS public.exos_slot_entry_overrides (
  ticket_id   uuid PRIMARY KEY REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL,
  org_id      uuid NOT NULL,
  admitted_by uuid,
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.exos_timed_entry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_slot_entry_overrides ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_timed_entry_sel ON public.exos_timed_entry;
CREATE POLICY exos_timed_entry_sel ON public.exos_timed_entry FOR SELECT TO authenticated
  USING (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
DROP POLICY IF EXISTS exos_event_slots_sel ON public.exos_event_slots;
CREATE POLICY exos_event_slots_sel ON public.exos_event_slots FOR SELECT TO authenticated
  USING (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
REVOKE ALL ON public.exos_timed_entry, public.exos_event_slots, public.exos_slot_entry_overrides FROM anon, authenticated;
GRANT SELECT ON public.exos_timed_entry, public.exos_event_slots TO authenticated;

ALTER TABLE public.exos_cart_holds ADD COLUMN IF NOT EXISTS slot_id text;
CREATE INDEX IF NOT EXISTS exos_cart_holds_live_slot_idx ON public.exos_cart_holds (event_id, slot_id)
  WHERE status = 'active' AND slot_id IS NOT NULL;
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS slot_id text
  CHECK (slot_id IS NULL OR slot_id ~ '^\d{8}T\d{4}$');
ALTER TABLE public.exos_tickets
  ADD COLUMN IF NOT EXISTS slot_id          text,
  ADD COLUMN IF NOT EXISTS slot_starts_at   timestamptz,
  ADD COLUMN IF NOT EXISTS slot_ends_at     timestamptz,
  ADD COLUMN IF NOT EXISTS slot_entry_from  timestamptz,
  ADD COLUMN IF NOT EXISTS slot_entry_until timestamptz;
CREATE INDEX IF NOT EXISTS exos_tickets_slot_idx ON public.exos_tickets (event_id, slot_id) WHERE slot_id IS NOT NULL;
-- Ticket holders read their own slot (RLS on exos_tickets decides the rows).
GRANT SELECT (slot_id, slot_starts_at, slot_ends_at, slot_entry_from, slot_entry_until) ON public.exos_tickets TO authenticated;

-- Slot start times of one date under a config (wall clock), in order.
CREATE OR REPLACE FUNCTION public._exos_slot_times(c public.exos_timed_entry, p_date date)
RETURNS SETOF time
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE rg jsonb; v_open int; v_close int; m int; n int := 0;
BEGIN
  IF c.event_id IS NULL OR p_date IS NULL OR p_date < c.start_date OR p_date > c.end_date
     OR p_date = ANY (c.closed_dates) THEN
    RETURN;
  END IF;
  FOR rg IN SELECT r FROM jsonb_array_elements(CASE WHEN jsonb_typeof(c.hours -> extract(dow FROM p_date)::int::text) = 'array'
                                                    THEN c.hours -> extract(dow FROM p_date)::int::text ELSE '[]'::jsonb END) r
             ORDER BY r ->> 'open' LOOP
    v_open  := split_part(rg ->> 'open', ':', 1)::int * 60 + split_part(rg ->> 'open', ':', 2)::int;
    v_close := split_part(rg ->> 'close', ':', 1)::int * 60 + split_part(rg ->> 'close', ':', 2)::int;
    m := v_open;
    WHILE m + c.slot_minutes <= v_close AND n < 96 LOOP
      RETURN NEXT make_time(m / 60, m % 60, 0);
      n := n + 1;
      m := m + c.slot_minutes;
    END LOOP;
  END LOOP;
END $$;

-- A slot id resolved against a config: empty when the config has no such slot.
CREATE OR REPLACE FUNCTION public._exos_slot_of(c public.exos_timed_entry, p_slot_id text)
RETURNS TABLE (slot_date date, slot_time time, starts_at timestamptz, ends_at timestamptz,
               entry_from timestamptz, entry_until timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_date date; v_time time; v_tz text; v_start timestamptz;
BEGIN
  IF c.event_id IS NULL OR p_slot_id IS NULL OR p_slot_id !~ '^\d{8}T\d{4}$' THEN RETURN; END IF;
  BEGIN
    v_date := to_date(left(p_slot_id, 8), 'YYYYMMDD');
    IF to_char(v_date, 'YYYYMMDD') <> left(p_slot_id, 8) THEN RETURN; END IF;
    IF substr(p_slot_id, 10, 2)::int > 23 OR substr(p_slot_id, 12, 2)::int > 59 THEN RETURN; END IF;
    v_time := make_time(substr(p_slot_id, 10, 2)::int, substr(p_slot_id, 12, 2)::int, 0);
  EXCEPTION WHEN others THEN
    RETURN;
  END;
  IF NOT EXISTS (SELECT 1 FROM public._exos_slot_times(c, v_date) t WHERE t = v_time) THEN RETURN; END IF;
  SELECT public._exos_series_tz(e.timezone) INTO v_tz FROM public.exos_events e WHERE e.id = c.event_id;
  v_start := public._exos_zoned_ts(v_date, v_time, v_tz);
  slot_date := v_date; slot_time := v_time; starts_at := v_start;
  ends_at := v_start + make_interval(mins => c.slot_minutes);
  entry_from := v_start - make_interval(mins => c.early_entry_minutes);
  entry_until := CASE WHEN c.entry_window_minutes IS NULL THEN ends_at
                      ELSE v_start + make_interval(mins => c.entry_window_minutes) END;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION public._exos_tier_is_timed(p_tier_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_ticket_tiers t
                   JOIN public.exos_timed_entry te ON te.event_id = t.event_id
                  WHERE t.id = p_tier_id AND p_tier_id = ANY (te.tier_ids))
$$;

-- Places left in a slot for a tier: effective capacity minus sold, minus
-- live (unexpired, active) slot holds when p_count_holds, and the tier's own
-- per-slot cap. Reads the row as it stands; callers lock it first.
CREATE OR REPLACE FUNCTION public._exos_slot_remaining(
  p_event_id uuid, p_slot_id text, p_tier_id uuid, p_count_holds boolean, p_exclude_hold uuid DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c      public.exos_timed_entry%ROWTYPE;
  sl     public.exos_event_slots%ROWTYPE;
  v_left int;
  v_tcap int;
  v_held int := 0;
  v_theld int := 0;
BEGIN
  SELECT * INTO c FROM public.exos_timed_entry WHERE event_id = p_event_id;
  IF c.event_id IS NULL THEN RETURN 0; END IF;
  SELECT * INTO sl FROM public.exos_event_slots WHERE event_id = p_event_id AND slot_id = p_slot_id;
  IF coalesce(sl.closed, false) THEN RETURN 0; END IF;
  IF p_count_holds THEN
    SELECT coalesce(sum(h.quantity), 0), coalesce(sum(h.quantity) FILTER (WHERE h.tier_id = p_tier_id), 0)
      INTO v_held, v_theld
      FROM public.exos_cart_holds h
     WHERE h.event_id = p_event_id AND h.slot_id = p_slot_id AND h.status = 'active' AND h.expires_at > now()
       AND h.id IS DISTINCT FROM p_exclude_hold;
  END IF;
  v_left := coalesce(sl.capacity, c.capacity) - coalesce(sl.sold, 0) - v_held;
  IF p_tier_id IS NOT NULL AND c.tier_capacity ? p_tier_id::text THEN
    v_tcap := (c.tier_capacity ->> p_tier_id::text)::int;
    v_left := least(v_left, v_tcap - coalesce((sl.tier_sold ->> p_tier_id::text)::int, 0) - v_theld);
  END IF;
  RETURN greatest(v_left, 0);
END $$;

-- The slot row, created on first touch, locked for this transaction.
CREATE OR REPLACE FUNCTION public._exos_slot_lock(p_event_id uuid, p_slot_id text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_timed_entry%ROWTYPE; s record;
BEGIN
  SELECT * INTO c FROM public.exos_timed_entry WHERE event_id = p_event_id;
  SELECT * INTO s FROM public._exos_slot_of(c, p_slot_id);
  IF s.starts_at IS NULL THEN RETURN false; END IF;
  INSERT INTO public.exos_event_slots (event_id, slot_id, org_id, starts_at, ends_at)
  VALUES (p_event_id, p_slot_id, c.org_id, s.starts_at, s.ends_at)
  ON CONFLICT (event_id, slot_id) DO NOTHING;
  PERFORM 1 FROM public.exos_event_slots WHERE event_id = p_event_id AND slot_id = p_slot_id FOR UPDATE;
  RETURN true;
END $$;

-- Checkout: put a fresh cart hold on a slot (service role, after
-- exos_create_hold / exos_create_guest_hold). Race-safe: the slot row lock
-- serializes attaches; sold + live slot holds never exceed the capacity.
CREATE OR REPLACE FUNCTION public.exos_attach_hold_slot(p_hold_id uuid, p_slot_id text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  h public.exos_cart_holds%ROWTYPE;
  c public.exos_timed_entry%ROWTYPE;
  s record;
BEGIN
  SELECT * INTO h FROM public.exos_cart_holds WHERE id = p_hold_id FOR UPDATE;
  IF h.id IS NULL OR h.status <> 'active' OR h.expires_at <= now() THEN
    RAISE EXCEPTION 'exos_attach_hold_slot: the reservation has expired' USING ERRCODE = '23514';
  END IF;
  IF NOT public._exos_tier_is_timed(h.tier_id) THEN
    RAISE EXCEPTION 'exos_attach_hold_slot: this ticket type isn''t sold by time slot' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO c FROM public.exos_timed_entry WHERE event_id = h.event_id;
  SELECT * INTO s FROM public._exos_slot_of(c, p_slot_id);
  IF s.starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_attach_hold_slot: that time slot isn''t offered' USING ERRCODE = '23514';
  END IF;
  IF s.entry_until <= now() THEN
    RAISE EXCEPTION 'exos_attach_hold_slot: that time slot has ended' USING ERRCODE = '23514';
  END IF;
  PERFORM public._exos_slot_lock(h.event_id, p_slot_id);
  IF public._exos_slot_remaining(h.event_id, p_slot_id, h.tier_id, true, h.id) < h.quantity THEN
    RAISE EXCEPTION 'exos_attach_hold_slot: that time slot is full' USING ERRCODE = '23514';
  END IF;
  UPDATE public.exos_cart_holds SET slot_id = p_slot_id WHERE id = h.id;
  RETURN true;
END $$;

-- Fulfillment (inside exos_fulfill_checkout's all-or-nothing block): count the
-- order into its slot, or refuse with XF001 (the order is refunded). Holds
-- were consumed just before, so only sold counts here.
CREATE OR REPLACE FUNCTION public._exos_slot_commit(p_session_id text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_checkout_sessions%ROWTYPE; v_k text;
BEGIN
  PERFORM set_config('exos.slot_mint', '', true);
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT public._exos_tier_is_timed(s.tier_id) THEN
    IF s.slot_id IS NOT NULL THEN
      RAISE EXCEPTION 'time slot given for a ticket type sold without one' USING ERRCODE = 'XF001';
    END IF;
    RETURN;
  END IF;
  IF s.slot_id IS NULL THEN
    RAISE EXCEPTION 'pick a date and time slot' USING ERRCODE = 'XF001';
  END IF;
  IF NOT public._exos_slot_lock(s.event_id, s.slot_id) THEN
    RAISE EXCEPTION 'time slot no longer offered at fulfillment' USING ERRCODE = 'XF001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_event_slots WHERE event_id = s.event_id AND slot_id = s.slot_id AND closed) THEN
    RAISE EXCEPTION 'time slot closed at fulfillment' USING ERRCODE = 'XF001';
  END IF;
  IF public._exos_slot_remaining(s.event_id, s.slot_id, s.tier_id, false) < s.quantity THEN
    RAISE EXCEPTION 'time slot sold out at fulfillment' USING ERRCODE = 'XF001';
  END IF;
  v_k := s.tier_id::text;
  UPDATE public.exos_event_slots
     SET sold = sold + s.quantity,
         tier_sold = tier_sold || jsonb_build_object(v_k, coalesce((tier_sold ->> v_k)::int, 0) + s.quantity),
         updated_at = now()
   WHERE event_id = s.event_id AND slot_id = s.slot_id;
  PERFORM set_config('exos.slot_mint', s.slot_id, true);
END $$;

-- Every ticket of a timed tier carries a slot, and only fulfillment (which
-- counted it) can give one: any other mint path is refused for timed tiers.
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_slot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_slot text; c public.exos_timed_entry%ROWTYPE; s record;
BEGIN
  IF NOT public._exos_tier_is_timed(NEW.tier_id) THEN
    IF NEW.slot_id IS NOT NULL THEN
      RAISE EXCEPTION 'this ticket type isn''t sold by time slot' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;
  v_slot := nullif(current_setting('exos.slot_mint', true), '');
  IF v_slot IS NULL OR (NEW.slot_id IS NOT NULL AND NEW.slot_id <> v_slot) THEN
    RAISE EXCEPTION 'Please pick a date and time slot: this ticket type is sold by time slot' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO c FROM public.exos_timed_entry WHERE event_id = NEW.event_id;
  SELECT * INTO s FROM public._exos_slot_of(c, v_slot);
  IF s.starts_at IS NULL THEN
    RAISE EXCEPTION 'that time slot isn''t offered' USING ERRCODE = '23514';
  END IF;
  NEW.slot_id := v_slot;
  NEW.slot_starts_at := s.starts_at;
  NEW.slot_ends_at := s.ends_at;
  NEW.slot_entry_from := s.entry_from;
  NEW.slot_entry_until := s.entry_until;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS exos_tickets_slot ON public.exos_tickets;
CREATE TRIGGER exos_tickets_slot BEFORE INSERT ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.tier_id IS NOT NULL) EXECUTE FUNCTION public.exos_tg_ticket_slot();

-- A void / refund / release gives the place back.
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_slot_release()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_k text := OLD.tier_id::text;
BEGIN
  UPDATE public.exos_event_slots
     SET sold = greatest(sold - 1, 0),
         tier_sold = CASE WHEN v_k IS NULL THEN tier_sold
                          ELSE tier_sold || jsonb_build_object(v_k, greatest(coalesce((tier_sold ->> v_k)::int, 0) - 1, 0)) END,
         updated_at = now()
   WHERE event_id = OLD.event_id AND slot_id = OLD.slot_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS exos_tickets_slot_release ON public.exos_tickets;
CREATE TRIGGER exos_tickets_slot_release AFTER UPDATE OF status ON public.exos_tickets
  FOR EACH ROW WHEN (OLD.slot_id IS NOT NULL AND OLD.status IN ('active', 'used')
                     AND NEW.status NOT IN ('active', 'used'))
  EXECUTE FUNCTION public.exos_tg_ticket_slot_release();

-- Validated config from jsonb (the organizer's input) -> row (not saved).
CREATE OR REPLACE FUNCTION public._exos_timed_entry_parse(p_event_id uuid, p_org_id uuid, p_config jsonb)
RETURNS public.exos_timed_entry
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  c        public.exos_timed_entry;
  v_tiers  uuid[];
  k        text;
  rg       jsonb;
  prev_close int;
  v_o      int;
  v_c      int;
  v_per    int;
  v_any    boolean := false;
  v_hours  jsonb := '{}'::jsonb;
  v_list   jsonb;
BEGIN
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
    RAISE EXCEPTION 'timed entry: settings must be an object' USING ERRCODE = '22023';
  END IF;
  BEGIN
    SELECT array_agg(DISTINCT x::uuid) INTO v_tiers
      FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_config -> 'tierIds') = 'array' THEN p_config -> 'tierIds' ELSE '[]'::jsonb END) x;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'timed entry: tierIds must be ticket type ids' USING ERRCODE = '22023';
  END;
  IF coalesce(cardinality(v_tiers), 0) = 0 THEN
    RAISE EXCEPTION 'timed entry: pick at least one ticket type to sell as time slots' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_tiers) t WHERE NOT EXISTS (
               SELECT 1 FROM public.exos_ticket_tiers tt WHERE tt.id = t AND tt.event_id = p_event_id)) THEN
    RAISE EXCEPTION 'timed entry: a timed ticket type is not part of this event' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_ticket_tiers tt WHERE tt.id = ANY (v_tiers) AND tt.kind <> 'standard') THEN
    RAISE EXCEPTION 'timed entry: a table ticket type can''t be sold by time slot' USING ERRCODE = '22023';
  END IF;
  c.event_id := p_event_id;
  c.org_id := p_org_id;
  c.tier_ids := v_tiers;
  BEGIN
    c.slot_minutes := (p_config ->> 'slotMinutes')::int;
    c.capacity := (p_config ->> 'capacity')::int;
    c.entry_window_minutes := nullif(p_config ->> 'entryWindowMinutes', '')::int;
    c.early_entry_minutes := coalesce(nullif(p_config ->> 'earlyEntryMinutes', '')::int, 0);
    c.start_date := (p_config ->> 'startDate')::date;
    c.end_date := (p_config ->> 'endDate')::date;
    SELECT coalesce(array_agg(DISTINCT x::date ORDER BY x::date), '{}') INTO c.closed_dates
      FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_config -> 'closedDates') = 'array' THEN p_config -> 'closedDates' ELSE '[]'::jsonb END) x;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'timed entry: slotMinutes, capacity, startDate and endDate are required (whole numbers, YYYY-MM-DD)' USING ERRCODE = '22023';
  END;
  IF c.slot_minutes IS NULL OR c.slot_minutes NOT BETWEEN 5 AND 480 THEN
    RAISE EXCEPTION 'timed entry: slotMinutes must be 5-480' USING ERRCODE = '22023';
  END IF;
  IF c.capacity IS NULL OR c.capacity NOT BETWEEN 1 AND 100000 THEN
    RAISE EXCEPTION 'timed entry: capacity must be 1-100000' USING ERRCODE = '22023';
  END IF;
  IF c.entry_window_minutes IS NOT NULL AND c.entry_window_minutes NOT BETWEEN 1 AND 1440 THEN
    RAISE EXCEPTION 'timed entry: entryWindowMinutes must be 1-1440' USING ERRCODE = '22023';
  END IF;
  IF c.early_entry_minutes NOT BETWEEN 0 AND 240 THEN
    RAISE EXCEPTION 'timed entry: earlyEntryMinutes must be 0-240' USING ERRCODE = '22023';
  END IF;
  IF c.start_date IS NULL OR c.end_date IS NULL OR c.end_date < c.start_date OR c.end_date - c.start_date > 400 THEN
    RAISE EXCEPTION 'timed entry: dates must run forward, at most 400 days' USING ERRCODE = '22023';
  END IF;
  IF cardinality(c.closed_dates) > 200 THEN
    RAISE EXCEPTION 'timed entry: at most 200 closed dates' USING ERRCODE = '22023';
  END IF;
  c.tier_capacity := '{}'::jsonb;
  IF jsonb_typeof(p_config -> 'tierCapacity') = 'object' THEN
    FOR k IN SELECT jsonb_object_keys(p_config -> 'tierCapacity') LOOP
      CONTINUE WHEN p_config -> 'tierCapacity' -> k IS NULL OR jsonb_typeof(p_config -> 'tierCapacity' -> k) = 'null'
                    OR (p_config -> 'tierCapacity' ->> k) = '';
      IF NOT (k = ANY (v_tiers::text[])) THEN
        RAISE EXCEPTION 'timed entry: a per-slot limit names a ticket type that is not timed' USING ERRCODE = '22023';
      END IF;
      IF (p_config -> 'tierCapacity' ->> k) !~ '^\d{1,6}$' OR (p_config -> 'tierCapacity' ->> k)::int > 100000 THEN
        RAISE EXCEPTION 'timed entry: per-slot limits must be 0-100000' USING ERRCODE = '22023';
      END IF;
      c.tier_capacity := c.tier_capacity || jsonb_build_object(k, (p_config -> 'tierCapacity' ->> k)::int);
    END LOOP;
  END IF;
  FOR k IN SELECT generate_series(0, 6)::text LOOP
    v_list := p_config -> 'hours' -> k;
    CONTINUE WHEN v_list IS NULL OR jsonb_typeof(v_list) = 'null';
    IF jsonb_typeof(v_list) <> 'array' OR jsonb_array_length(v_list) > 4 THEN
      RAISE EXCEPTION 'timed entry: each weekday takes at most 4 opening ranges' USING ERRCODE = '22023';
    END IF;
    CONTINUE WHEN jsonb_array_length(v_list) = 0;
    prev_close := -1; v_per := 0;
    FOR rg IN SELECT r FROM jsonb_array_elements(v_list) r ORDER BY r ->> 'open' LOOP
      IF coalesce(rg ->> 'open', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
         OR NOT (coalesce(rg ->> 'close', '') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' OR rg ->> 'close' = '24:00') THEN
        RAISE EXCEPTION 'timed entry: opening hours must be HH:MM' USING ERRCODE = '22023';
      END IF;
      v_o := split_part(rg ->> 'open', ':', 1)::int * 60 + split_part(rg ->> 'open', ':', 2)::int;
      v_c := split_part(rg ->> 'close', ':', 1)::int * 60 + split_part(rg ->> 'close', ':', 2)::int;
      IF v_c <= v_o THEN
        RAISE EXCEPTION 'timed entry: closing time must be after opening time' USING ERRCODE = '22023';
      END IF;
      IF v_o < prev_close THEN
        RAISE EXCEPTION 'timed entry: opening ranges on one day must not overlap' USING ERRCODE = '22023';
      END IF;
      prev_close := v_c;
      v_per := v_per + (v_c - v_o) / c.slot_minutes;
    END LOOP;
    IF v_per > 96 THEN
      RAISE EXCEPTION 'timed entry: at most 96 slots a day (weekday % has %); use longer slots', k, v_per USING ERRCODE = '22023';
    END IF;
    v_hours := v_hours || jsonb_build_object(k, (SELECT jsonb_agg(jsonb_build_object('open', r ->> 'open', 'close', r ->> 'close') ORDER BY r ->> 'open')
                                                   FROM jsonb_array_elements(v_list) r));
    v_any := true;
  END LOOP;
  IF NOT v_any THEN
    RAISE EXCEPTION 'timed entry: add opening hours for at least one weekday' USING ERRCODE = '22023';
  END IF;
  c.hours := v_hours;
  RETURN c;
END $$;

-- Save the config (owner / manager). A change never strands a sale: every
-- slot with sales stays in the schedule with room for what it sold, and a
-- tier with slot sales stays timed.
CREATE OR REPLACE FUNCTION public.exos_set_timed_entry(p_event_id uuid, p_config jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e   public.exos_events%ROWTYPE;
  c   public.exos_timed_entry;
  sl  record;
  k   text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_set_timed_entry: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF e.id IS NULL OR NOT (exos_is_admin() OR exos_has_org_role(e.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_timed_entry: event not found' USING ERRCODE = '42501';
  END IF;
  c := public._exos_timed_entry_parse(e.id, e.org_id, p_config);
  FOR sl IN SELECT * FROM public.exos_event_slots WHERE event_id = e.id AND sold > 0 FOR UPDATE LOOP
    IF NOT EXISTS (SELECT 1 FROM public._exos_slot_of(c, sl.slot_id)) THEN
      RAISE EXCEPTION 'exos_set_timed_entry: slot % has sales and must stay in the schedule', sl.slot_id USING ERRCODE = '23514';
    END IF;
    IF coalesce(sl.capacity, c.capacity) < sl.sold THEN
      RAISE EXCEPTION 'exos_set_timed_entry: slot % sold %, more than the new capacity', sl.slot_id, sl.sold USING ERRCODE = '23514';
    END IF;
    FOR k IN SELECT jsonb_object_keys(sl.tier_sold) LOOP
      IF (sl.tier_sold ->> k)::int > 0 AND NOT (k = ANY (c.tier_ids::text[])) THEN
        RAISE EXCEPTION 'exos_set_timed_entry: a ticket type with slot sales must stay timed' USING ERRCODE = '23514';
      END IF;
      IF c.tier_capacity ? k AND (c.tier_capacity ->> k)::int < (sl.tier_sold ->> k)::int THEN
        RAISE EXCEPTION 'exos_set_timed_entry: slot % sold more of a ticket type than its new limit', sl.slot_id USING ERRCODE = '23514';
      END IF;
    END LOOP;
  END LOOP;
  INSERT INTO public.exos_timed_entry AS t (event_id, org_id, tier_ids, slot_minutes, capacity, tier_capacity,
         entry_window_minutes, early_entry_minutes, hours, start_date, end_date, closed_dates, version, updated_by)
  VALUES (c.event_id, c.org_id, c.tier_ids, c.slot_minutes, c.capacity, c.tier_capacity, c.entry_window_minutes,
          c.early_entry_minutes, c.hours, c.start_date, c.end_date, c.closed_dates,
          (extract(epoch FROM clock_timestamp()) * 1000)::bigint, auth.uid())
  ON CONFLICT (event_id) DO UPDATE SET
    tier_ids = EXCLUDED.tier_ids, slot_minutes = EXCLUDED.slot_minutes, capacity = EXCLUDED.capacity,
    tier_capacity = EXCLUDED.tier_capacity, entry_window_minutes = EXCLUDED.entry_window_minutes,
    early_entry_minutes = EXCLUDED.early_entry_minutes, hours = EXCLUDED.hours, start_date = EXCLUDED.start_date,
    end_date = EXCLUDED.end_date, closed_dates = EXCLUDED.closed_dates,
    version = greatest(EXCLUDED.version, t.version + 1), updated_by = EXCLUDED.updated_by, updated_at = now()
  RETURNING * INTO c;
  RETURN to_jsonb(c);
END $$;

CREATE OR REPLACE FUNCTION public.exos_clear_timed_entry(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_clear_timed_entry: event not found' USING ERRCODE = '42501';
  END IF;
  PERFORM 1 FROM public.exos_timed_entry WHERE event_id = p_event_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.exos_event_slots WHERE event_id = p_event_id AND sold > 0)
     OR EXISTS (SELECT 1 FROM public.exos_cart_holds WHERE event_id = p_event_id AND slot_id IS NOT NULL
                  AND status = 'active' AND expires_at > now()) THEN
    RAISE EXCEPTION 'exos_clear_timed_entry: slots have sales; timed entry can''t be turned off' USING ERRCODE = '23514';
  END IF;
  DELETE FROM public.exos_event_slots WHERE event_id = p_event_id;
  DELETE FROM public.exos_timed_entry WHERE event_id = p_event_id;
  RETURN FOUND;
END $$;

-- Staff: one slot's capacity (NULL with p_reset = back to the config's) or closed flag.
CREATE OR REPLACE FUNCTION public.exos_set_event_slot(
  p_event_id uuid, p_slot_id text, p_capacity int DEFAULT NULL, p_closed boolean DEFAULT NULL, p_reset boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; sl public.exos_event_slots%ROWTYPE;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_event_slot: event not found' USING ERRCODE = '42501';
  END IF;
  IF NOT public._exos_slot_lock(p_event_id, p_slot_id) THEN
    RAISE EXCEPTION 'exos_set_event_slot: no such slot' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO sl FROM public.exos_event_slots WHERE event_id = p_event_id AND slot_id = p_slot_id;
  IF p_capacity IS NOT NULL AND (p_capacity < 0 OR p_capacity > 100000) THEN
    RAISE EXCEPTION 'exos_set_event_slot: capacity must be 0-100000' USING ERRCODE = '22023';
  END IF;
  IF p_capacity IS NOT NULL AND p_capacity < sl.sold THEN
    RAISE EXCEPTION 'exos_set_event_slot: the slot already sold %', sl.sold USING ERRCODE = '23514';
  END IF;
  UPDATE public.exos_event_slots
     SET capacity = CASE WHEN p_reset THEN NULL WHEN p_capacity IS NOT NULL THEN p_capacity ELSE capacity END,
         closed = coalesce(p_closed, closed), updated_at = now()
   WHERE event_id = p_event_id AND slot_id = p_slot_id
   RETURNING * INTO sl;
  RETURN to_jsonb(sl);
END $$;

-- Who can see a timed event's slots: published / cancelled for everyone,
-- drafts for the org's staff.
CREATE OR REPLACE FUNCTION public._exos_timed_visible(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id
                   AND (e.status IN ('published', 'cancelled')
                        OR (auth.uid() IS NOT NULL
                            AND (exos_is_admin() OR exos_has_org_role(e.org_id, ARRAY['owner','manager','finance','scanner','content'])))))
$$;

-- Public: the config a slot picker needs (no counts). NULL when not timed.
CREATE OR REPLACE FUNCTION public.exos_public_timed_entry(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
           'event_id', c.event_id, 'tier_ids', to_jsonb(c.tier_ids), 'slot_minutes', c.slot_minutes,
           'entry_window_minutes', c.entry_window_minutes, 'early_entry_minutes', c.early_entry_minutes,
           'hours', c.hours, 'start_date', c.start_date, 'end_date', c.end_date,
           'closed_dates', to_jsonb(c.closed_dates), 'version', c.version,
           'timezone', (SELECT public._exos_series_tz(e.timezone) FROM public.exos_events e WHERE e.id = c.event_id))
    FROM public.exos_timed_entry c
   WHERE c.event_id = p_event_id AND public._exos_timed_visible(p_event_id)
$$;

-- Public: slots between two dates (<= 62 days) with what's left, overall and
-- per timed ticket type. Live holds count as taken.
CREATE OR REPLACE FUNCTION public.exos_public_event_slots(p_event_id uuid, p_from date, p_to date)
RETURNS TABLE (slot_id text, slot_date date, slot_time text, starts_at timestamptz, ends_at timestamptz,
               entry_until timestamptz, capacity int, remaining int, tier_remaining jsonb, closed boolean, ended boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_timed_entry%ROWTYPE; d date; v_to date;
BEGIN
  IF NOT public._exos_timed_visible(p_event_id) THEN RETURN; END IF;
  SELECT * INTO c FROM public.exos_timed_entry WHERE event_id = p_event_id;
  IF c.event_id IS NULL OR p_from IS NULL OR p_to IS NULL THEN RETURN; END IF;
  v_to := least(p_to, p_from + 61, c.end_date);
  d := greatest(p_from, c.start_date);
  WHILE d <= v_to LOOP
    RETURN QUERY
      SELECT x.id, d, to_char(t.tm, 'HH24:MI'), so.starts_at, so.ends_at, so.entry_until,
             coalesce(sl.capacity, c.capacity),
             public._exos_slot_remaining(p_event_id, x.id, NULL, true),
             (SELECT jsonb_object_agg(tid::text, public._exos_slot_remaining(p_event_id, x.id, tid, true))
                FROM unnest(c.tier_ids) tid),
             coalesce(sl.closed, false), so.entry_until <= now()
        FROM public._exos_slot_times(c, d) t(tm)
        CROSS JOIN LATERAL (SELECT to_char(d, 'YYYYMMDD') || 'T' || to_char(t.tm, 'HH24MI') AS id) x
        CROSS JOIN LATERAL public._exos_slot_of(c, x.id) so
        LEFT JOIN public.exos_event_slots sl ON sl.event_id = p_event_id AND sl.slot_id = x.id
       ORDER BY t.tm;
    d := d + 1;
  END LOOP;
END $$;

-- Staff report: every scheduled slot in the range (<= 62 days) plus any slot
-- with tickets, with sold, held, checked in and gross.
-- The rows (no caller check: service role for exos-api, and the staff wrapper below).
CREATE OR REPLACE FUNCTION public._exos_slot_report(p_event_id uuid, p_from date, p_to date)
RETURNS TABLE (slot_id text, slot_date date, slot_time text, starts_at timestamptz, capacity int, custom boolean,
               closed boolean, sold int, held int, checked_in int, gross numeric, tier_sold jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_timed_entry%ROWTYPE; v_from date; v_to date;
BEGIN
  SELECT * INTO c FROM public.exos_timed_entry WHERE event_id = p_event_id;
  IF c.event_id IS NULL THEN RETURN; END IF;
  v_from := coalesce(p_from, greatest(c.start_date, (now() AT TIME ZONE 'UTC')::date - 1));
  v_to := least(coalesce(p_to, v_from + 30), v_from + 61);
  RETURN QUERY
    WITH sched AS (
      SELECT to_char(dd.d, 'YYYYMMDD') || 'T' || to_char(t.tm, 'HH24MI') AS id
        FROM generate_series(v_from, v_to, interval '1 day') g(d0)
        CROSS JOIN LATERAL (SELECT g.d0::date AS d) dd
        CROSS JOIN LATERAL public._exos_slot_times(c, dd.d) t(tm)
      UNION
      SELECT s.slot_id FROM public.exos_event_slots s
       WHERE s.event_id = p_event_id AND to_date(left(s.slot_id, 8), 'YYYYMMDD') BETWEEN v_from AND v_to
    ), tk AS (
      SELECT t.slot_id, count(*) FILTER (WHERE t.check_in_at IS NOT NULL) AS cin,
             coalesce(sum(t.price_paid) FILTER (WHERE t.status IN ('active', 'used')), 0) AS gross
        FROM public.exos_tickets t
       WHERE t.event_id = p_event_id AND t.slot_id IN (SELECT id FROM sched)
       GROUP BY t.slot_id
    )
    SELECT x.id, to_date(left(x.id, 8), 'YYYYMMDD'), substr(x.id, 10, 2) || ':' || substr(x.id, 12, 2),
           coalesce(sl.starts_at, (SELECT so.starts_at FROM public._exos_slot_of(c, x.id) so)),
           coalesce(sl.capacity, c.capacity), sl.capacity IS NOT NULL, coalesce(sl.closed, false),
           coalesce(sl.sold, 0),
           (SELECT coalesce(sum(h.quantity), 0)::int FROM public.exos_cart_holds h
             WHERE h.event_id = p_event_id AND h.slot_id = x.id AND h.status = 'active' AND h.expires_at > now()),
           coalesce(tk.cin, 0)::int, coalesce(tk.gross, 0), coalesce(sl.tier_sold, '{}'::jsonb)
      FROM sched x
      LEFT JOIN public.exos_event_slots sl ON sl.event_id = p_event_id AND sl.slot_id = x.id
      LEFT JOIN tk ON tk.slot_id = x.id
     ORDER BY x.id;
END $$;

CREATE OR REPLACE FUNCTION public.exos_event_slot_report(p_event_id uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS TABLE (slot_id text, slot_date date, slot_time text, starts_at timestamptz, capacity int, custom boolean,
               closed boolean, sold int, held int, checked_in int, gross numeric, tier_sold jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL
     OR NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','finance','scanner','content'])) THEN
    RAISE EXCEPTION 'exos_event_slot_report: event not found' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public._exos_slot_report(p_event_id, p_from, p_to);
END $$;

-- Door: entry windows of every slotted ticket (the offline registry and the
-- door's "Time slots" list).
CREATE OR REPLACE FUNCTION public.exos_event_door_slots(p_event_id uuid)
RETURNS TABLE (ticket_id uuid, slot_id text, slot_starts_at timestamptz, entry_from timestamptz,
               entry_until timestamptz, status text, check_in_at timestamptz, admit_override boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL
     OR NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','scanner']))
     OR NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_event_door_slots: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT t.id, t.slot_id, t.slot_starts_at, t.slot_entry_from, t.slot_entry_until, t.status, t.check_in_at,
           EXISTS (SELECT 1 FROM public.exos_slot_entry_overrides o WHERE o.ticket_id = t.id)
      FROM public.exos_tickets t
     WHERE t.event_id = p_event_id AND t.slot_id IS NOT NULL
     ORDER BY t.slot_id, t.id;
END $$;

-- Door: "Admit anyway" for a ticket outside its entry window; the next live
-- scan of that ticket then passes the window check.
CREATE OR REPLACE FUNCTION public.exos_admit_outside_window(p_ticket_id uuid, p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_event uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_admit_outside_window: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, event_id INTO v_org, v_event FROM public.exos_tickets WHERE id = p_ticket_id AND slot_id IS NOT NULL;
  IF v_org IS NULL OR v_event IS DISTINCT FROM p_event_id
     OR NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','scanner']))
     OR NOT public.exos_can_door_event(v_event) THEN
    RAISE EXCEPTION 'exos_admit_outside_window: not authorized' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_slot_entry_overrides (ticket_id, event_id, org_id, admitted_by)
  VALUES (p_ticket_id, v_event, v_org, auth.uid())
  ON CONFLICT (ticket_id) DO NOTHING;
  RETURN true;
END $$;

-- The window answer for a live entry scan, or NULL when it may proceed.
CREATE OR REPLACE FUNCTION public._exos_slot_entry_refusal(p_ticket_id uuid, p_at timestamptz)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE t record;
BEGIN
  SELECT slot_id, slot_entry_from, slot_entry_until, status INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF t.slot_id IS NULL OR t.status <> 'active' OR t.slot_entry_from IS NULL THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_slot_entry_overrides o WHERE o.ticket_id = p_ticket_id) THEN RETURN NULL; END IF;
  IF p_at < t.slot_entry_from OR p_at > t.slot_entry_until THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'outside-entry-window',
                              'window', CASE WHEN p_at < t.slot_entry_from THEN 'early' ELSE 'late' END,
                              'slot_id', t.slot_id, 'entry_from', t.slot_entry_from, 'entry_until', t.slot_entry_until);
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Patches: fulfillment (slot counter in the claim block) and the door.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)', '_exos_slot_commit',
  $o$    PERFORM set_config('exos.table_mint', p_session_id, true);$o$,
  $n$    -- timed entry (mig 20261030150000): the slot counter, same transaction as the tier's.
    PERFORM public._exos_slot_commit(p_session_id);
    PERFORM set_config('exos.table_mint', p_session_id, true);$n$, 1);
-- _exos_slot_commit sets exos.slot_mint for the mint loop; clear it right after.
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)', 'slot_mint cleared',
  $o$    -- A table order: one booking per table (mig 20260926050000).$o$,
  $n$    PERFORM set_config('exos.slot_mint', '', true);  -- slot_mint cleared
    -- A table order: one booking per table (mig 20260926050000).$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text, uuid, text)',
  '_exos_slot_entry_refusal',
  $o$  IF v_prev = 'voided' THEN$o$,
  $n$  -- timed entry (mig 20261030150000): the entry window, live entry scans only
  -- (an offline replay was already decided at the door).
  IF p_scanned_at IS NULL AND v_dir = 'entry' AND NOT v_test THEN
    v_refusal := public._exos_slot_entry_refusal(p_ticket_id, v_scan_at);
    IF v_refusal IS NOT NULL THEN
      RETURN v_refusal;
    END IF;
  END IF;

  IF v_prev = 'voided' THEN$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamptz, text)',
  '_exos_slot_entry_refusal',
  $o$  IF v_prev = 'voided' THEN$o$,
  $n$  -- timed entry (mig 20261030150000): the entry window, live scans only.
  IF p_scanned_at IS NULL AND NOT v_test AND public._exos_slot_entry_refusal(p_ticket_id, v_scan_at) IS NOT NULL THEN
    RETURN public._exos_slot_entry_refusal(p_ticket_id, v_scan_at);
  END IF;

  IF v_prev = 'voided' THEN$n$, 1);

-- ---------------------------------------------------------------------------
-- 5. Grants. Revoke first; then only the callers that need each function.
-- ---------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    -- internal helpers: no client grant
    'public._exos_zoned_ts(date, time, text)', 'public._exos_series_fp(uuid)', 'public._exos_series_tz(text)',
    'public._exos_series_for_write(uuid)', 'public._exos_series_cancel_event(uuid, text)',
    'public._exos_public_event_json(uuid)', 'public._exos_collection_event_ids(uuid, boolean)',
    'public._exos_slot_times(public.exos_timed_entry, date)', 'public._exos_slot_of(public.exos_timed_entry, text)',
    'public._exos_tier_is_timed(uuid)', 'public._exos_slot_remaining(uuid, text, uuid, boolean, uuid)',
    'public._exos_slot_lock(uuid, text)', 'public._exos_slot_commit(text)',
    'public._exos_timed_entry_parse(uuid, uuid, jsonb)', 'public._exos_timed_visible(uuid)',
    'public._exos_slot_entry_refusal(uuid, timestamptz)', 'public._exos_slot_report(uuid, date, date)',
    'public.exos_tg_collections()', 'public.exos_tg_ticket_slot()', 'public.exos_tg_ticket_slot_release()',
    -- staff (signed in; each checks the org role)
    'public.exos_series_create(uuid, text, jsonb, text)', 'public.exos_series_generate(uuid, jsonb)',
    'public.exos_series_publish(uuid)', 'public.exos_series_cancel_date(uuid, date, text)',
    'public.exos_series_propagate(uuid, jsonb)', 'public.exos_series_update(uuid, jsonb)',
    'public.exos_series_cancel(uuid, text, uuid[], text)', 'public.exos_series_delete(uuid)',
    'public.exos_series_attach_event(uuid, uuid)', 'public.exos_series_detach_event(uuid, uuid)',
    'public.exos_collection_event_ids(uuid)',
    'public.exos_set_timed_entry(uuid, jsonb)', 'public.exos_clear_timed_entry(uuid)',
    'public.exos_set_event_slot(uuid, text, int, boolean, boolean)', 'public.exos_event_slot_report(uuid, date, date)',
    'public.exos_event_door_slots(uuid)', 'public.exos_admit_outside_window(uuid, uuid)',
    -- public
    'public.exos_public_series(uuid, int, int)', 'public.exos_public_org_series(text)',
    'public.exos_public_collection(text, text)', 'public.exos_public_timed_entry(uuid)',
    'public.exos_public_event_slots(uuid, date, date)',
    -- service role (exos-checkout)
    'public.exos_attach_hold_slot(uuid, text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
    'public.exos_series_create(uuid, text, jsonb, text)', 'public.exos_series_generate(uuid, jsonb)',
    'public.exos_series_publish(uuid)', 'public.exos_series_cancel_date(uuid, date, text)',
    'public.exos_series_propagate(uuid, jsonb)', 'public.exos_series_update(uuid, jsonb)',
    'public.exos_series_cancel(uuid, text, uuid[], text)', 'public.exos_series_delete(uuid)',
    'public.exos_series_attach_event(uuid, uuid)', 'public.exos_series_detach_event(uuid, uuid)',
    'public.exos_collection_event_ids(uuid)',
    'public.exos_set_timed_entry(uuid, jsonb)', 'public.exos_clear_timed_entry(uuid)',
    'public.exos_set_event_slot(uuid, text, int, boolean, boolean)', 'public.exos_event_slot_report(uuid, date, date)',
    'public.exos_event_door_slots(uuid)', 'public.exos_admit_outside_window(uuid, uuid)'
  ] LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
    'public.exos_public_series(uuid, int, int)', 'public.exos_public_org_series(text)',
    'public.exos_public_collection(text, text)', 'public.exos_public_timed_entry(uuid)',
    'public.exos_public_event_slots(uuid, date, date)'
  ] LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated, service_role', f);
  END LOOP;
  -- exos-api (service role) reads collection membership and slot reports.
  GRANT EXECUTE ON FUNCTION public.exos_attach_hold_slot(uuid, text) TO service_role;
  GRANT EXECUTE ON FUNCTION public._exos_collection_event_ids(uuid, boolean) TO service_role;
  GRANT EXECUTE ON FUNCTION public._exos_slot_report(uuid, date, date) TO service_role;
END $$;
