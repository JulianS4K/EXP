-- ============================================================================
-- Migration 20261030120000 — Exos: sales counts from other platforms
--
-- Touches:  W: TABLE exos_sales_counts (new)
--              VIEW exos_sales_count_totals (new, security_invoker)
--              FUNCTION _exos_sales_count_write, _exos_sales_count_tiers,
--                       _exos_sales_count_can (new, internal)
--              FUNCTION exos_set_sales_count, exos_import_sales_counts,
--                       exos_delete_sales_count (new, signed-in staff)
--              FUNCTION exos_api_sales_count_put, exos_api_sales_count_delete
--                       (new, service role: exos-api)
--              FUNCTION exos_public_sales_count_total (new, anon: the total
--                       per published event, nothing else)
--           R: exos_events, exos_org_memberships
-- Pre-reqs: 20260520120000 (exos_has_org_role, exos_touch_updated_at),
--           20260520130000 (exos_is_admin)
--
-- Tickets an organizer sold somewhere other than Exos: a box office, a
-- consignment, DICE / RA / Posh / Shotgun / Ticketmaster, anything that
-- exports a spreadsheet. One row per (event, source):
--   * kind 'manual': typed in by staff; the source is the label they give it
--     ("Box office"). Saving the same label again replaces it.
--   * kind 'import': a CSV of one platform's sales for the event, mapped
--     column by column in the browser (or by exos-api) and summed per ticket
--     type. Re-importing the same platform replaces its row (a snapshot, not
--     an increment), so importing the same file twice changes nothing
--     ('unchanged').
-- Counts and amounts only, never buyer data. These numbers are never added to
-- Exos's own orders, revenue or check-ins; reports show them beside those,
-- labelled. Amounts are minor units of the row's currency and are never
-- summed across currencies (exos_sales_count_totals groups by currency).
-- Settlements / P&L read exos_sales_count_totals (or the rows) by event.
--
-- Who can do what: owners, managers and finance of the event's org read and
-- write (finance reconciles box-office counts); scanners, content staff and
-- other orgs see nothing. Writes go through the RPCs (validation, the 20
-- entries / 50 ticket types caps, the 'unchanged' check), never a direct
-- table write. Anyone may read the published event's total sold elsewhere
-- (exos_public_sales_count_total), which is the same kind of number as the
-- public tickets_sold; never the platforms, amounts or tiers.
--
-- Additive, re-run safe. Prod apply needs operator OK.
-- ROLLBACK: DROP FUNCTION the functions above; DROP VIEW
--   exos_sales_count_totals; DROP TABLE exos_sales_counts.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The rows.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_sales_counts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id     uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  kind         text NOT NULL CHECK (kind IN ('manual', 'import')),
  -- import: the platform key; manual: NULL.
  platform     text CHECK (platform IS NULL OR platform ~ '^[a-z][a-z0-9_]{1,23}$'),
  -- The display name: the manual label, or the platform's name.
  label        text NOT NULL CHECK (length(label) BETWEEN 1 AND 40),
  -- Unique per event: 'manual:<lower(label)>' or the platform key.
  source_key   text NOT NULL CHECK (length(source_key) BETWEEN 1 AND 60),
  sold         integer NOT NULL CHECK (sold BETWEEN 0 AND 10000000),
  gross_cents  bigint NOT NULL DEFAULT 0 CHECK (gross_cents BETWEEN 0 AND 100000000000),
  currency     text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  capacity     integer CHECK (capacity IS NULL OR capacity BETWEEN 0 AND 10000000),
  -- [{ name, sold, gross_cents, capacity }] per ticket type (imports; may be []).
  tiers        jsonb NOT NULL DEFAULT '[]'::jsonb
               CHECK (jsonb_typeof(tiers) = 'array' AND jsonb_array_length(tiers) <= 50),
  note         text CHECK (note IS NULL OR length(note) <= 200),
  file_name    text CHECK (file_name IS NULL OR length(file_name) <= 200),
  row_count    integer CHECK (row_count IS NULL OR row_count BETWEEN 0 AND 100000),
  created_by   uuid,
  updated_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_sales_counts_source_uq UNIQUE (event_id, source_key),
  CONSTRAINT exos_sales_counts_kind_platform CHECK ((kind = 'manual') = (platform IS NULL))
);
COMMENT ON TABLE public.exos_sales_counts IS
  'Tickets sold outside Exos, per event and source (mig 20261030120000, docs/organizer-guide.md "Sold elsewhere"): manual counts and CSV imports. Counts and amounts only; never part of Exos order totals.';
CREATE INDEX IF NOT EXISTS exos_sales_counts_org_idx ON public.exos_sales_counts (org_id, event_id);

DROP TRIGGER IF EXISTS exos_sales_counts_touch ON public.exos_sales_counts;
CREATE TRIGGER exos_sales_counts_touch BEFORE UPDATE ON public.exos_sales_counts
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- RLS: owner / manager / finance of the org read. No client writes (RPCs).
ALTER TABLE public.exos_sales_counts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_sales_counts_sel ON public.exos_sales_counts;
CREATE POLICY exos_sales_counts_sel ON public.exos_sales_counts FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_sales_counts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_sales_counts TO authenticated;
GRANT ALL ON public.exos_sales_counts TO service_role;

-- Per event and currency: what settlements and reports read. Runs as the
-- reader, so the table's RLS applies.
CREATE OR REPLACE VIEW public.exos_sales_count_totals
WITH (security_invoker = true) AS
SELECT event_id, org_id, currency,
       sum(sold)::bigint        AS sold,
       sum(gross_cents)::bigint AS gross_cents,
       count(*)::integer        AS entries,
       max(updated_at)          AS updated_at
  FROM public.exos_sales_counts
 GROUP BY event_id, org_id, currency;
COMMENT ON VIEW public.exos_sales_count_totals IS
  'Tickets sold elsewhere per event and currency (mig 20261030120000). Same readers as exos_sales_counts.';
REVOKE ALL ON public.exos_sales_count_totals FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_sales_count_totals TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (no client grant).
-- ---------------------------------------------------------------------------

-- Caller may read / write the org's counts: owner, manager, finance, or admin.
CREATE OR REPLACE FUNCTION public._exos_sales_count_can(p_org uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT auth.uid() IS NOT NULL
     AND (public.exos_is_admin() OR public.exos_has_org_role(p_org, ARRAY['owner','manager','finance']));
$$;
REVOKE ALL ON FUNCTION public._exos_sales_count_can(uuid) FROM PUBLIC, anon, authenticated;

-- Validates and merges ticket types (same name, any case = one type; numbers
-- add up, capacity is the largest given). Raises 22023 on bad input.
CREATE OR REPLACE FUNCTION public._exos_sales_count_tiers(p_tiers jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t       jsonb;
  v_name  text;
  v_sold  bigint;
  v_gross bigint;
  v_cap   bigint;
  v_out   jsonb := '[]'::jsonb;
  v_key   text;
  v_idx   int;
  v_keys  text[] := '{}';
BEGIN
  IF p_tiers IS NULL OR p_tiers = 'null'::jsonb THEN RETURN '[]'::jsonb; END IF;
  IF jsonb_typeof(p_tiers) <> 'array' THEN
    RAISE EXCEPTION 'sales counts: tiers must be an array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_tiers) > 2000 THEN
    RAISE EXCEPTION 'sales counts: at most 2000 ticket type lines' USING ERRCODE = '22023';
  END IF;
  FOR t IN SELECT value FROM jsonb_array_elements(p_tiers) LOOP
    IF jsonb_typeof(t) <> 'object' THEN
      RAISE EXCEPTION 'sales counts: each ticket type must be an object' USING ERRCODE = '22023';
    END IF;
    v_name := btrim(regexp_replace(coalesce(t->>'name', ''), '\s+', ' ', 'g'));
    IF length(v_name) < 1 OR length(v_name) > 80 OR v_name ~ '[\x00-\x1f\x7f]' THEN
      RAISE EXCEPTION 'sales counts: a ticket type name must be 1-80 characters' USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_sold  := coalesce((t->>'sold')::bigint, 0);
      v_gross := coalesce((t->>'gross_cents')::bigint, 0);
      v_cap   := (t->>'capacity')::bigint;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'sales counts: ticket type "%": sold, gross_cents and capacity must be whole numbers', v_name
        USING ERRCODE = '22023';
    END;
    IF v_sold < 0 OR v_sold > 10000000 OR v_gross < 0 OR v_gross > 100000000000
       OR (v_cap IS NOT NULL AND (v_cap < 0 OR v_cap > 10000000)) THEN
      RAISE EXCEPTION 'sales counts: ticket type "%": a number is out of range', v_name USING ERRCODE = '22023';
    END IF;
    v_key := lower(v_name);
    v_idx := array_position(v_keys, v_key);
    IF v_idx IS NULL THEN
      v_keys := v_keys || v_key;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'name', v_name, 'sold', v_sold, 'gross_cents', v_gross,
        'capacity', CASE WHEN v_cap IS NULL THEN 'null'::jsonb ELSE to_jsonb(v_cap) END));
    ELSE
      v_out := jsonb_set(v_out, ARRAY[(v_idx - 1)::text], jsonb_build_object(
        'name', v_out->(v_idx - 1)->>'name',
        'sold', (v_out->(v_idx - 1)->>'sold')::bigint + v_sold,
        'gross_cents', (v_out->(v_idx - 1)->>'gross_cents')::bigint + v_gross,
        'capacity', CASE
          WHEN v_cap IS NULL THEN v_out->(v_idx - 1)->'capacity'
          WHEN v_out->(v_idx - 1)->'capacity' = 'null'::jsonb THEN to_jsonb(v_cap)
          ELSE to_jsonb(greatest(v_cap, (v_out->(v_idx - 1)->>'capacity')::bigint)) END));
    END IF;
  END LOOP;
  IF jsonb_array_length(v_out) > 50 THEN
    RAISE EXCEPTION 'sales counts: at most 50 ticket types per entry' USING ERRCODE = '22023';
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_sales_count_tiers(jsonb) FROM PUBLIC, anon, authenticated;

-- The one writer. Callers have already checked who may act for p_org; this
-- checks the event (and the row, by id) belong to p_org, validates, caps and
-- upserts. Returns { id, status: created | updated | unchanged, ... }.
CREATE OR REPLACE FUNCTION public._exos_sales_count_write(
  p_org uuid, p_event uuid, p_id uuid, p_kind text, p_label text, p_platform text,
  p_sold integer, p_gross_cents bigint, p_currency text, p_capacity integer,
  p_tiers jsonb, p_note text, p_actor uuid, p_file_name text, p_row_count integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row     public.exos_sales_counts;
  v_event   uuid := p_event;
  v_kind    text := p_kind;
  v_label   text;
  v_plat    text;
  v_key     text;
  v_tiers   jsonb;
  v_sold    bigint;
  v_gross   bigint;
  v_cap     bigint;
  v_cur     text;
  v_note    text;
  v_n       int;
  v_status  text;
  v_id      uuid;
BEGIN
  IF p_org IS NULL THEN
    RAISE EXCEPTION 'sales counts: organization required' USING ERRCODE = '22023';
  END IF;

  -- Updating by id: the row must be the org's; it keeps its event and kind.
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM public.exos_sales_counts WHERE id = p_id AND org_id = p_org;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sales counts: not found' USING ERRCODE = 'P0002';
    END IF;
    v_event := v_row.event_id;
    v_kind := v_row.kind;
  END IF;

  IF v_event IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = v_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'sales counts: event not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_kind NOT IN ('manual', 'import') THEN
    RAISE EXCEPTION 'sales counts: kind must be manual or import' USING ERRCODE = '22023';
  END IF;

  -- One writer per event at a time (the 20-entry cap and the unchanged check).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_sales_counts:' || v_event::text, 0));

  IF v_kind = 'manual' THEN
    v_label := btrim(regexp_replace(coalesce(p_label, v_row.label, ''), '\s+', ' ', 'g'));
    IF length(v_label) < 1 OR length(v_label) > 40 OR v_label ~ '[\x00-\x1f\x7f]' THEN
      RAISE EXCEPTION 'sales counts: a label (where these tickets were sold) of 1-40 characters is required'
        USING ERRCODE = '22023';
    END IF;
    v_plat := NULL;
    v_key := 'manual:' || lower(v_label);
  ELSE
    v_plat := lower(btrim(coalesce(p_platform, v_row.platform, '')));
    IF v_plat NOT IN ('eventbrite', 'dice', 'ra', 'posh', 'shotgun', 'ticketmaster', 'axs', 'seetickets',
                      'tixr', 'etix', 'partiful', 'luma', 'other') THEN
      RAISE EXCEPTION 'sales counts: unknown platform "%"', v_plat USING ERRCODE = '22023';
    END IF;
    v_label := CASE v_plat
      WHEN 'eventbrite' THEN 'Eventbrite' WHEN 'dice' THEN 'DICE' WHEN 'ra' THEN 'Resident Advisor'
      WHEN 'posh' THEN 'Posh' WHEN 'shotgun' THEN 'Shotgun' WHEN 'ticketmaster' THEN 'Ticketmaster'
      WHEN 'axs' THEN 'AXS' WHEN 'seetickets' THEN 'See Tickets' WHEN 'tixr' THEN 'Tixr'
      WHEN 'etix' THEN 'Etix' WHEN 'partiful' THEN 'Partiful' WHEN 'luma' THEN 'Luma'
      ELSE 'Other platform' END;
    v_key := v_plat;
  END IF;

  v_tiers := public._exos_sales_count_tiers(coalesce(p_tiers, CASE WHEN p_id IS NOT NULL THEN v_row.tiers END));
  IF jsonb_array_length(v_tiers) > 0 THEN
    SELECT sum((x->>'sold')::bigint), sum((x->>'gross_cents')::bigint),
           CASE WHEN bool_and(x->'capacity' <> 'null'::jsonb) THEN sum((x->>'capacity')::bigint) END
      INTO v_sold, v_gross, v_cap
      FROM jsonb_array_elements(v_tiers) x;
    v_cap := coalesce(p_capacity, v_cap);
  ELSE
    v_sold := coalesce(p_sold, v_row.sold);
    v_gross := coalesce(p_gross_cents, v_row.gross_cents, 0);
    v_cap := CASE WHEN p_id IS NOT NULL AND p_capacity IS NULL THEN v_row.capacity ELSE p_capacity END;
  END IF;
  IF v_sold IS NULL OR v_sold < 0 OR v_sold > 10000000 THEN
    RAISE EXCEPTION 'sales counts: sold must be a whole number from 0 to 10,000,000' USING ERRCODE = '22023';
  END IF;
  IF v_gross < 0 OR v_gross > 100000000000 THEN
    RAISE EXCEPTION 'sales counts: gross_cents is out of range' USING ERRCODE = '22023';
  END IF;
  IF v_cap IS NOT NULL AND (v_cap < 0 OR v_cap > 10000000) THEN
    RAISE EXCEPTION 'sales counts: capacity is out of range' USING ERRCODE = '22023';
  END IF;
  v_cur := upper(btrim(coalesce(p_currency, v_row.currency, '')));
  IF v_cur !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'sales counts: currency must be a 3-letter code' USING ERRCODE = '22023';
  END IF;
  v_note := nullif(btrim(coalesce(p_note, CASE WHEN p_id IS NOT NULL THEN v_row.note END, '')), '');
  IF length(v_note) > 200 THEN
    RAISE EXCEPTION 'sales counts: note must be at most 200 characters' USING ERRCODE = '22023';
  END IF;
  IF p_file_name IS NOT NULL AND length(p_file_name) > 200 THEN
    RAISE EXCEPTION 'sales counts: file name too long' USING ERRCODE = '22023';
  END IF;

  -- The entry this write lands on: by id, else by source.
  IF p_id IS NULL THEN
    SELECT * INTO v_row FROM public.exos_sales_counts WHERE event_id = v_event AND source_key = v_key;
  ELSIF v_key <> v_row.source_key
        AND EXISTS (SELECT 1 FROM public.exos_sales_counts WHERE event_id = v_event AND source_key = v_key) THEN
    RAISE EXCEPTION 'sales counts: this event already has an entry called "%"', v_label USING ERRCODE = '23505';
  END IF;

  IF v_row.id IS NULL THEN
    SELECT count(*) INTO v_n FROM public.exos_sales_counts WHERE event_id = v_event;
    IF v_n >= 20 THEN
      RAISE EXCEPTION 'sales counts: an event keeps at most 20 entries' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_sales_counts (org_id, event_id, kind, platform, label, source_key, sold, gross_cents,
                                          currency, capacity, tiers, note, file_name, row_count, created_by, updated_by)
    VALUES (p_org, v_event, v_kind, v_plat, v_label, v_key, v_sold, v_gross, v_cur, v_cap, v_tiers, v_note,
            p_file_name, p_row_count, p_actor, p_actor)
    RETURNING id INTO v_id;
    v_status := 'created';
  ELSIF v_row.label = v_label AND v_row.sold = v_sold AND v_row.gross_cents = v_gross AND v_row.currency = v_cur
        AND v_row.capacity IS NOT DISTINCT FROM v_cap::integer AND v_row.tiers = v_tiers
        AND v_row.note IS NOT DISTINCT FROM v_note THEN
    v_id := v_row.id;
    v_status := 'unchanged';
  ELSE
    UPDATE public.exos_sales_counts
       SET label = v_label, source_key = v_key, sold = v_sold, gross_cents = v_gross, currency = v_cur,
           capacity = v_cap, tiers = v_tiers, note = v_note,
           file_name = coalesce(p_file_name, file_name), row_count = coalesce(p_row_count, row_count),
           updated_by = p_actor
     WHERE id = v_row.id;
    v_id := v_row.id;
    v_status := 'updated';
  END IF;

  RETURN (SELECT jsonb_build_object('id', s.id, 'status', v_status, 'event_id', s.event_id, 'kind', s.kind,
                                    'platform', s.platform, 'label', s.label, 'sold', s.sold,
                                    'gross_cents', s.gross_cents, 'currency', s.currency, 'capacity', s.capacity,
                                    'tiers', s.tiers, 'note', s.note, 'updated_at', s.updated_at)
            FROM public.exos_sales_counts s WHERE s.id = v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_sales_count_write(uuid, uuid, uuid, text, text, text, integer, bigint, text,
  integer, jsonb, text, uuid, text, integer) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Signed-in staff (the event report).
-- ---------------------------------------------------------------------------

-- A manual count, by label (saving the same label again replaces it).
CREATE OR REPLACE FUNCTION public.exos_set_sales_count(
  p_event_id uuid, p_label text, p_sold integer, p_gross_cents bigint, p_currency text,
  p_capacity integer DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT public._exos_sales_count_can(v_org) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_sales_count_write(v_org, p_event_id, NULL, 'manual', p_label, NULL, p_sold,
    coalesce(p_gross_cents, 0), p_currency, p_capacity, '[]'::jsonb, coalesce(p_note, ''), auth.uid(), NULL, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_sales_count(uuid, text, integer, bigint, text, integer, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_set_sales_count(uuid, text, integer, bigint, text, integer, text)
  TO authenticated, service_role;

-- A platform's CSV, already mapped and summed per ticket type in the browser
-- (src/lib/salesCounts.ts); re-summed and re-validated here. Replaces that
-- platform's entry; the same numbers again answer 'unchanged'.
CREATE OR REPLACE FUNCTION public.exos_import_sales_counts(
  p_event_id uuid, p_platform text, p_currency text, p_tiers jsonb,
  p_sold integer DEFAULT NULL, p_gross_cents bigint DEFAULT NULL, p_capacity integer DEFAULT NULL,
  p_file_name text DEFAULT NULL, p_row_count integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT public._exos_sales_count_can(v_org) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_sales_count_write(v_org, p_event_id, NULL, 'import', NULL, p_platform, p_sold,
    coalesce(p_gross_cents, 0), p_currency, p_capacity, coalesce(p_tiers, '[]'::jsonb), '', auth.uid(),
    left(p_file_name, 200), p_row_count);
END $$;
REVOKE ALL ON FUNCTION public.exos_import_sales_counts(uuid, text, text, jsonb, integer, bigint, integer, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_import_sales_counts(uuid, text, text, jsonb, integer, bigint, integer, text, integer)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_delete_sales_count(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_sales_counts WHERE id = p_id;
  IF v_org IS NULL OR NOT public._exos_sales_count_can(v_org) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_sales_counts WHERE id = p_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_delete_sales_count(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_delete_sales_count(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Partner API (exos-api, service role). The function resolved p_org from
--    the API key's hash; the event / row must be that org's.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_api_sales_count_put(
  p_org_id uuid, p_event_id uuid, p_id uuid, p_kind text, p_label text, p_platform text,
  p_sold integer, p_gross_cents bigint, p_currency text, p_capacity integer, p_tiers jsonb,
  p_note text, p_file_name text DEFAULT NULL, p_row_count integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public._exos_sales_count_write(p_org_id, p_event_id, p_id, p_kind, p_label, p_platform, p_sold,
    p_gross_cents, p_currency, p_capacity, p_tiers, p_note, NULL, left(p_file_name, 200), p_row_count);
$$;
REVOKE ALL ON FUNCTION public.exos_api_sales_count_put(uuid, uuid, uuid, text, text, text, integer, bigint, text,
  integer, jsonb, text, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_sales_count_put(uuid, uuid, uuid, text, text, text, integer, bigint, text,
  integer, jsonb, text, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_api_sales_count_delete(p_org_id uuid, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  DELETE FROM public.exos_sales_counts WHERE id = p_id AND org_id = p_org_id;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_api_sales_count_delete(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_sales_count_delete(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Public: the total sold elsewhere for published events only (at most 200
--    ids a call). No platforms, amounts, tiers or drafts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_public_sales_count_total(p_event_ids uuid[])
RETURNS TABLE (event_id uuid, sold bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_event_ids IS NULL OR cardinality(p_event_ids) = 0 THEN RETURN; END IF;
  IF cardinality(p_event_ids) > 200 THEN
    RAISE EXCEPTION 'at most 200 events per call' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
    SELECT e.id, coalesce(sum(s.sold), 0)::bigint
      FROM public.exos_events e
      LEFT JOIN public.exos_sales_counts s ON s.event_id = e.id
     WHERE e.id = ANY (p_event_ids) AND e.status = 'published'
     GROUP BY e.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_public_sales_count_total(uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_sales_count_total(uuid[]) TO anon, authenticated, service_role;
