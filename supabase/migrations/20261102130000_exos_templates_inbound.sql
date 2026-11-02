-- ============================================================================
-- Migration 20261102130000 — Exos: event templates, note templates, rental
-- invoice templates and rental invoices, inbound booking submissions, and
-- deleting a draft event. docs/templates-inbound.md.
--
-- Touches:  C: TABLE exos_event_templates, exos_note_templates,
--              exos_rental_invoice_templates, exos_rental_invoices,
--              exos_rental_invoice_counters, exos_inbound_settings,
--              exos_inbound_submissions
--           C: FUNCTION _exos_event_template_fields, _exos_tg_event_template,
--              _exos_event_from_template / exos_event_from_template,
--              _exos_event_template_from_event / exos_event_template_from_event,
--              _exos_tg_note_template, _exos_rental_lines, _exos_rental_totals,
--              _exos_tg_rental_template, _exos_tg_rental_invoice,
--              _exos_tg_rental_invoice_del, _exos_rental_invoice_json,
--              _exos_rental_invoice_create / _update / _issue / _set_status /
--              _delete and their exos_rental_invoice_* wrappers,
--              exos_rental_invoice_prefix_set, _exos_tg_inbound_settings,
--              _exos_inbound_create, _exos_inbound_set_status,
--              _exos_inbound_hold and wrappers, _exos_request_ip,
--              _exos_request_ip_source, _exos_request_ip_bucket (internal),
--              exos_inbound_form_public (anon),
--              exos_inbound_submit (anon), _exos_event_delete / exos_event_delete
--           R: exos_platform_settings ('request_ip_source'), exos_orgs, exos_org_memberships, exos_events, exos_ticket_tiers,
--              exos_fee_rules, exos_event_fee_settings, exos_event_notes,
--              exos_venues, exos_venue_rooms, exos_holds, exos_hold_positions,
--              exos_tickets, exos_checkout_sessions and the other order tables
--           Calls (unchanged): _exos_api_insert, _exos_api_columns,
--              _exos_api_event_json, _exos_hold_create, _exos_fin_staff,
--              _exos_fin_cents / _pct / _text / _date / _email,
--              exos_occurs_at_local
-- Pre-reqs: 20261014140000 (exos_platform_settings), 20261030100000 (booking), 20261031100000 (offers: _exos_fin_*),
--           20261031110000 (core API: _exos_api_insert), 20261027100000 (fee
--           rules)
--
-- After Opendate's admin template inventory (event, note and rental invoice
-- templates) and inbound submissions, with pretix's invoice numbering as the
-- design reference for rental invoices:
--
--   * Event template: a saved event setup (name, description, capacity, doors
--     and length relative to the start, other event settings, ticket types
--     with prices in cents, fee rules, whether the org's fee rules apply).
--     "Create event from template" makes a DRAFT event with those tiers and
--     fee rules (exos_event_from_template, or the API); "save as template"
--     snapshots an existing event. Owners and managers write; content and
--     finance read.
--   * Note template: a reusable booking note body; applying one adds an
--     exos_event_notes row (#67). Owners, managers and content write.
--   * Rental invoice template: a venue rental's line items (fixed or per
--     head), deposits and taxes / fees. A rental invoice is made from a
--     template (or from scratch) for a hold, one held night, or a room on a
--     date, and copies the lines so later template edits don't change it.
--     Drafts can be edited and deleted; issuing assigns the org's next
--     number, after which the invoice is frozen (only paid / void). Numbers
--     are gapless and race-safe: the counter row is updated in the same
--     transaction as the issue (its row lock queues concurrent issues), an
--     issued invoice can never be deleted, and a failed issue rolls the
--     counter back with it. Like pretix, a cancelled invoice keeps its
--     number (void), it never frees it. Owners, managers and finance.
--   * Inbound submissions: an artist or agent asks for a show. Each org has a
--     public form (/book/<org slug>) that is OFF until an owner or manager
--     turns it on. The anon RPC exos_inbound_submit caps the body at 16 KB,
--     drops honeypot submissions silently (the hidden `homepage` field),
--     and limits per network (5 an hour per org, 20 a day across orgs: the
--     SHA-256 of the platform-set IP, _exos_request_ip(), never the IP;
--     requests without one share an "unknown" bucket), per email (3 a day per org)
--     and per org (300 a day). Staff (owner, manager, content) list, read,
--     review (new / reviewing / accepted / declined) and delete them; owners
--     and managers can turn one into a hold (accepted, linked).
--   * Deleting an event: only a draft (or cancelled) event with no orders,
--     tickets, reservations or payments, else 55000 "cancel it instead"
--     (the API answers 409). Published events are unpublished first.
--
-- Errors: 22023 bad input, P0002 not found, 55000 / 54000 conflict or limit,
-- 42501 not allowed. Additive only; re-run safe (IF NOT EXISTS, CREATE OR
-- REPLACE, DROP ... IF EXISTS before CREATE for policies and triggers). D4
-- authors; applying to prod is operator-gated.
-- ROLLBACK (manual): drop the functions above and the seven tables.
-- ============================================================================

-- ===========================================================================
-- 1. Event templates
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_event_templates (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id               uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name                 text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  -- The new event's name (else the template's name) and description.
  event_name           text CHECK (event_name IS NULL OR char_length(event_name) <= 200),
  description          text NOT NULL DEFAULT '' CHECK (char_length(description) <= 20000),
  capacity             integer CHECK (capacity IS NULL OR capacity BETWEEN 0 AND 1000000),
  -- Doors this many minutes before the start; the show lasts this long.
  doors_offset_minutes integer CHECK (doors_offset_minutes IS NULL OR doors_offset_minutes BETWEEN 0 AND 1440),
  duration_minutes     integer CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 1 AND 10080),
  -- Other event settings (keys from _exos_event_template_fields()).
  event_fields         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(event_fields) = 'object'),
  -- [{ name, description, price_cents, capacity, ticket_type, visibility, sort_order, accessible, accessible_note }]
  tiers                jsonb NOT NULL DEFAULT '[]'::jsonb
                       CHECK (jsonb_typeof(tiers) = 'array' AND jsonb_array_length(tiers) <= 50),
  -- [{ name, recipient, kind, calc, percent, amount_cents, cap_cents, per, taxable, applies_to_addons }]
  fee_rules            jsonb NOT NULL DEFAULT '[]'::jsonb
                       CHECK (jsonb_typeof(fee_rules) = 'array' AND jsonb_array_length(fee_rules) <= 25),
  inherit_org_fees     boolean NOT NULL DEFAULT true,
  use_count            integer NOT NULL DEFAULT 0,
  last_used_at         timestamptz,
  created_by           uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id)
);
CREATE INDEX IF NOT EXISTS exos_event_templates_org_idx ON public.exos_event_templates (org_id, status, name);

-- The event settings a template may carry (beyond name, description, dates
-- and capacity). Only those that exist as exos_events columns are copied.
CREATE OR REPLACE FUNCTION public._exos_event_template_fields()
RETURNS text[] LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY['timezone', 'currency', 'venue_name', 'venue_location', 'venue_address', 'primary_performer_name',
    'performer_names', 'category', 'genres', 'subgenres', 'image_url', 'purchase_limits', 'summary',
    'description_md', 'faq', 'video_url', 'min_age', 'refund_policy', 'policy_notes', 'format', 'what_to_bring',
    'noindex', 'allow_holder_release', 'release_cutoff_hours', 'accessibility', 'door_name_checkin',
    'exos_venue_id', 'exos_room_id']::text[]
$$;
REVOKE ALL ON FUNCTION public._exos_event_template_fields() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_event_template_fields() TO authenticated, service_role;

-- Validate and normalize a template row (org fixed, creator, 100 per org,
-- known setting keys, tiers and fee rules in the shape the tables take).
CREATE OR REPLACE FUNCTION public._exos_tg_event_template()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad text; t jsonb; v_tiers jsonb := '[]'::jsonb; v_fees jsonb := '[]'::jsonb; i int := 0;
  v_kind text; v_calc text; v_per text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'a template can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    NEW.use_count := 0;
    NEW.last_used_at := NULL;
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_event_templates:' || NEW.org_id::text, 0));
    IF (SELECT count(*) FROM public.exos_event_templates WHERE org_id = NEW.org_id) >= 100 THEN
      RAISE EXCEPTION 'at most 100 event templates per organization' USING ERRCODE = '54000';
    END IF;
  ELSE
    NEW.created_by := OLD.created_by;
  END IF;
  NEW.name := btrim(NEW.name);
  NEW.event_name := nullif(btrim(NEW.event_name), '');
  SELECT k INTO v_bad FROM jsonb_object_keys(NEW.event_fields) k
   WHERE NOT (k = ANY (public._exos_event_template_fields())) ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'event_fields: unknown setting %', left(v_bad, 60) USING ERRCODE = '22023';
  END IF;
  IF NEW.event_fields ? 'timezone' AND jsonb_typeof(NEW.event_fields -> 'timezone') = 'string'
     AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.event_fields ->> 'timezone') THEN
    RAISE EXCEPTION 'event_fields.timezone must be an IANA zone, e.g. America/New_York' USING ERRCODE = '22023';
  END IF;
  IF NEW.event_fields ? 'exos_venue_id' AND jsonb_typeof(NEW.event_fields -> 'exos_venue_id') = 'string'
     AND NOT EXISTS (SELECT 1 FROM public.exos_venues v
                      WHERE v.id::text = NEW.event_fields ->> 'exos_venue_id' AND v.org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'event_fields.exos_venue_id is not one of this organization''s venues' USING ERRCODE = '22023';
  END IF;

  FOR t IN SELECT x FROM jsonb_array_elements(NEW.tiers) x LOOP
    IF jsonb_typeof(t) <> 'object' THEN
      RAISE EXCEPTION 'tiers[%] must be an object', i USING ERRCODE = '22023';
    END IF;
    SELECT k INTO v_bad FROM jsonb_object_keys(t) k
     WHERE k NOT IN ('name', 'description', 'price_cents', 'capacity', 'ticket_type', 'visibility', 'sort_order',
                     'accessible', 'accessible_note') ORDER BY k LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION 'tiers[%]: unknown field %', i, left(v_bad, 60) USING ERRCODE = '22023';
    END IF;
    IF char_length(public._exos_fin_text(t, 'name', 'tiers.name', 100)) = 0 THEN
      RAISE EXCEPTION 'tiers[%] needs a name', i USING ERRCODE = '22023';
    END IF;
    IF coalesce(t ->> 'ticket_type', 'paid') NOT IN ('paid', 'free', 'donation') THEN
      RAISE EXCEPTION 'tiers[%].ticket_type must be paid, free or donation', i USING ERRCODE = '22023';
    END IF;
    IF coalesce(t ->> 'visibility', 'public') NOT IN ('public', 'hidden') THEN
      RAISE EXCEPTION 'tiers[%].visibility must be public or hidden', i USING ERRCODE = '22023';
    END IF;
    IF public._exos_fin_cents(t, 'capacity', 'tiers.capacity') > 1000000
       OR public._exos_fin_cents(t, 'price_cents', 'tiers.price_cents') > 100000000 THEN
      RAISE EXCEPTION 'tiers[%]: capacity at most 1,000,000 and price at most 1,000,000.00', i USING ERRCODE = '22023';
    END IF;
    v_tiers := v_tiers || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'name', public._exos_fin_text(t, 'name', 'tiers.name', 100),
      'description', nullif(public._exos_fin_text(t, 'description', 'tiers.description', 2000), ''),
      'price_cents', public._exos_fin_cents(t, 'price_cents', 'tiers.price_cents'),
      'capacity', public._exos_fin_cents(t, 'capacity', 'tiers.capacity'),
      'ticket_type', coalesce(t ->> 'ticket_type', 'paid'),
      'visibility', coalesce(t ->> 'visibility', 'public'),
      'sort_order', coalesce(public._exos_fin_cents(t, 'sort_order', 'tiers.sort_order', true), i),
      'accessible', CASE WHEN jsonb_typeof(t -> 'accessible') = 'boolean' THEN t -> 'accessible' END,
      'accessible_note', nullif(public._exos_fin_text(t, 'accessible_note', 'tiers.accessible_note', 200), ''))));
    i := i + 1;
  END LOOP;
  NEW.tiers := v_tiers;

  i := 0;
  FOR t IN SELECT x FROM jsonb_array_elements(NEW.fee_rules) x LOOP
    IF jsonb_typeof(t) <> 'object' THEN
      RAISE EXCEPTION 'fee_rules[%] must be an object', i USING ERRCODE = '22023';
    END IF;
    SELECT k INTO v_bad FROM jsonb_object_keys(t) k
     WHERE k NOT IN ('name', 'recipient', 'kind', 'calc', 'percent', 'amount_cents', 'cap_cents', 'per', 'taxable',
                     'applies_to_addons') ORDER BY k LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION 'fee_rules[%]: unknown field %', i, left(v_bad, 60) USING ERRCODE = '22023';
    END IF;
    v_kind := coalesce(t ->> 'kind', 'passed_on');
    v_calc := coalesce(t ->> 'calc', 'fixed');
    v_per := coalesce(t ->> 'per', 'ticket');
    IF char_length(public._exos_fin_text(t, 'name', 'fee_rules.name', 60)) = 0
       OR v_kind NOT IN ('passed_on', 'absorbed') OR v_calc NOT IN ('percent', 'fixed') OR v_per NOT IN ('ticket', 'order') THEN
      RAISE EXCEPTION 'fee_rules[%]: needs a name; kind passed_on or absorbed; calc percent or fixed; per ticket or order', i
        USING ERRCODE = '22023';
    END IF;
    IF v_per = 'order' AND v_kind <> 'absorbed' THEN
      RAISE EXCEPTION 'fee_rules[%]: a per-order fee can only be absorbed (all-in prices are per ticket)', i USING ERRCODE = '22023';
    END IF;
    IF v_calc = 'fixed' AND (t -> 'amount_cents' IS NULL OR t ? 'percent' OR t ? 'cap_cents') THEN
      RAISE EXCEPTION 'fee_rules[%]: a fixed fee has amount_cents (no percent or cap)', i USING ERRCODE = '22023';
    END IF;
    IF v_calc = 'percent' AND (t -> 'percent' IS NULL OR t ? 'amount_cents') THEN
      RAISE EXCEPTION 'fee_rules[%]: a percent fee has percent (no amount_cents)', i USING ERRCODE = '22023';
    END IF;
    IF public._exos_fin_cents(t, 'amount_cents', 'fee_rules.amount_cents') > 10000000 THEN
      RAISE EXCEPTION 'fee_rules[%].amount_cents is at most 10000000', i USING ERRCODE = '22023';
    END IF;
    v_fees := v_fees || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'name', public._exos_fin_text(t, 'name', 'fee_rules.name', 60),
      'recipient', coalesce(nullif(public._exos_fin_text(t, 'recipient', 'fee_rules.recipient', 40), ''), 'org'),
      'kind', v_kind, 'calc', v_calc, 'per', v_per,
      'percent', public._exos_fin_pct(t, 'percent', 'fee_rules.percent', true),
      'amount_cents', public._exos_fin_cents(t, 'amount_cents', 'fee_rules.amount_cents', true),
      'cap_cents', public._exos_fin_cents(t, 'cap_cents', 'fee_rules.cap_cents', true),
      'taxable', coalesce((t ->> 'taxable')::boolean, true),
      'applies_to_addons', coalesce((t ->> 'applies_to_addons')::boolean, false))));
    i := i + 1;
  END LOOP;
  NEW.fee_rules := v_fees;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_template() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_event_templates_guard ON public.exos_event_templates;
CREATE TRIGGER exos_event_templates_guard BEFORE INSERT OR UPDATE ON public.exos_event_templates
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_template();

-- Core (service_role: exos-api; the wrapper below for the dashboard).
-- p_args: { name?, starts_at?, timezone?, exos_venue_id?, exos_room_id? }.
-- Makes a DRAFT event from the template: settings, description, capacity,
-- doors / end from the start, the tiers and the fee rules. Returns
-- { event_id, template_id, event }.
CREATE OR REPLACE FUNCTION public._exos_event_from_template(p_org uuid, p_actor uuid, p_template uuid, p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  tp       public.exos_event_templates%ROWTYPE;
  a        jsonb := coalesce(p_args, '{}'::jsonb);
  v_bad    text;
  v_cols   text[];
  v_fields jsonb;
  v_start  timestamptz;
  v_id     uuid;
  t        jsonb;
  v_tcols  text[];
  v_fcols  text[];
  v_cap    bigint;
BEGIN
  IF jsonb_typeof(a) <> 'object' THEN
    RAISE EXCEPTION 'the body must be an object' USING ERRCODE = '22023';
  END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(a) k
   WHERE k NOT IN ('name', 'starts_at', 'timezone', 'exos_venue_id', 'exos_room_id') ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'unknown field: %', left(v_bad, 60) USING ERRCODE = '22023';
  END IF;
  SELECT * INTO tp FROM public.exos_event_templates WHERE id = p_template AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template not found' USING ERRCODE = 'P0002';
  END IF;
  IF tp.status <> 'active' THEN
    RAISE EXCEPTION 'this template is archived; restore it first' USING ERRCODE = '55000';
  END IF;
  IF nullif(a ->> 'starts_at', '') IS NOT NULL THEN
    BEGIN
      v_start := (a ->> 'starts_at')::timestamptz;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'starts_at must be an ISO 8601 time' USING ERRCODE = '22023';
    END;
  END IF;

  -- The settings that exist as columns here, then what this call overrides.
  v_cols := public._exos_api_columns('public.exos_events',
              public._exos_event_template_fields() || ARRAY['name', 'description', 'starts_at', 'doors_at', 'ends_at',
                                                            'total_tickets']);
  SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) INTO v_fields
    FROM jsonb_each(tp.event_fields) AS e(k, v) WHERE k = ANY (v_cols) AND jsonb_typeof(v) <> 'null';
  v_cap := coalesce(tp.capacity,
                    (SELECT sum((x ->> 'capacity')::bigint) FROM jsonb_array_elements(tp.tiers) x));
  v_fields := v_fields || jsonb_build_object('name', coalesce(nullif(btrim(a ->> 'name'), ''), tp.event_name, tp.name));
  IF tp.description <> '' THEN v_fields := v_fields || jsonb_build_object('description', tp.description); END IF;
  IF v_cap IS NOT NULL THEN v_fields := v_fields || jsonb_build_object('total_tickets', least(v_cap, 1000000)); END IF;
  IF nullif(a ->> 'timezone', '') IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = a ->> 'timezone') THEN
      RAISE EXCEPTION 'timezone must be an IANA zone, e.g. America/New_York' USING ERRCODE = '22023';
    END IF;
    v_fields := v_fields || jsonb_build_object('timezone', a ->> 'timezone');
  END IF;
  IF a ? 'exos_venue_id' THEN v_fields := v_fields || jsonb_build_object('exos_venue_id', a -> 'exos_venue_id'); END IF;
  IF a ? 'exos_room_id' THEN v_fields := v_fields || jsonb_build_object('exos_room_id', a -> 'exos_room_id'); END IF;
  IF v_start IS NOT NULL THEN
    v_fields := v_fields || jsonb_build_object('starts_at', v_start);
    IF tp.doors_offset_minutes IS NOT NULL THEN
      v_fields := v_fields || jsonb_build_object('doors_at', v_start - make_interval(mins => tp.doors_offset_minutes));
    END IF;
    IF tp.duration_minutes IS NOT NULL THEN
      v_fields := v_fields || jsonb_build_object('ends_at', v_start + make_interval(mins => tp.duration_minutes));
    END IF;
  END IF;
  SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) INTO v_fields FROM jsonb_each(v_fields) AS e(k, v) WHERE k = ANY (v_cols);

  -- Born a draft, like every new event.
  v_id := public._exos_api_insert('public.exos_events', v_cols, v_fields,
            jsonb_build_object('org_id', p_org, 'created_by', p_actor, 'status', 'draft'));
  IF to_regprocedure('public.exos_occurs_at_local(timestamptz, text)') IS NOT NULL THEN
    UPDATE public.exos_events SET occurs_at_local = public.exos_occurs_at_local(starts_at, timezone)
     WHERE id = v_id AND starts_at IS NOT NULL AND timezone IS NOT NULL;
  END IF;

  v_tcols := public._exos_api_columns('public.exos_ticket_tiers',
               ARRAY['name', 'description', 'price', 'capacity', 'ticket_type', 'visibility', 'sort_order',
                     'accessible', 'accessible_note']);
  FOR t IN SELECT x FROM jsonb_array_elements(tp.tiers) x LOOP
    t := (t - 'price_cents') || jsonb_build_object('price', round(((t ->> 'price_cents')::numeric) / 100, 2));
    SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) INTO t FROM jsonb_each(t) AS e(k, v) WHERE k = ANY (v_tcols);
    PERFORM public._exos_api_insert('public.exos_ticket_tiers', v_tcols, t, jsonb_build_object('event_id', v_id));
  END LOOP;

  IF to_regclass('public.exos_fee_rules') IS NOT NULL THEN
    v_fcols := public._exos_api_columns('public.exos_fee_rules',
                 ARRAY['name', 'recipient', 'kind', 'calc', 'percent', 'amount_cents', 'cap_cents', 'per', 'taxable',
                       'applies_to_addons']);
    FOR t IN SELECT x FROM jsonb_array_elements(tp.fee_rules) x LOOP
      PERFORM public._exos_api_insert('public.exos_fee_rules', v_fcols, t,
                jsonb_build_object('org_id', p_org, 'event_id', v_id, 'created_by', p_actor));
    END LOOP;
    IF NOT tp.inherit_org_fees THEN
      INSERT INTO public.exos_event_fee_settings (event_id, org_id, inherit_org_rules)
      VALUES (v_id, p_org, false)
      ON CONFLICT (event_id) DO UPDATE SET inherit_org_rules = false;
    END IF;
  END IF;

  UPDATE public.exos_event_templates SET use_count = use_count + 1, last_used_at = now() WHERE id = tp.id;
  RETURN jsonb_build_object('event_id', v_id, 'template_id', tp.id, 'event', public._exos_api_event_json(v_id));
END $$;
REVOKE ALL ON FUNCTION public._exos_event_from_template(uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_from_template(uuid, uuid, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_event_from_template(p_template_id uuid, p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_event_templates WHERE id = p_template_id);
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_fin_staff(v_org, ARRAY['owner', 'manager']);
  RETURN public._exos_event_from_template(v_org, auth.uid(), p_template_id, p_args);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_from_template(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_from_template(uuid, jsonb) TO authenticated;

-- "Save as template": snapshot one of the org's events (settings, tiers,
-- active event fee rules, doors / length relative to the start).
CREATE OR REPLACE FUNCTION public._exos_event_template_from_event(p_org uuid, p_actor uuid, p_event uuid, p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e      jsonb;
  v_ev   public.exos_events%ROWTYPE;
  v_fields jsonb;
  v_tiers  jsonb;
  v_fees   jsonb := '[]'::jsonb;
  v_inherit boolean := true;
  v_id   uuid;
BEGIN
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event AND org_id = p_org;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  e := to_jsonb(v_ev);
  SELECT coalesce(jsonb_object_agg(k, e -> k), '{}'::jsonb) INTO v_fields
    FROM unnest(public._exos_event_template_fields()) k
   WHERE e ? k AND jsonb_typeof(e -> k) <> 'null';
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'name', left(coalesce(x ->> 'name', 'Ticket'), 100), 'description', left(x ->> 'description', 2000),
           'price_cents', round((coalesce(x ->> 'price', '0'))::numeric * 100)::bigint,
           'capacity', coalesce((x ->> 'capacity')::int, 0),
           'ticket_type', x ->> 'ticket_type', 'visibility', x ->> 'visibility',
           'sort_order', coalesce((x ->> 'sort_order')::int, 0),
           'accessible', x -> 'accessible', 'accessible_note', x ->> 'accessible_note'))
           ORDER BY (x ->> 'sort_order')::int NULLS LAST, x ->> 'id'), '[]'::jsonb)
    INTO v_tiers
    FROM (SELECT to_jsonb(t) x FROM public.exos_ticket_tiers t WHERE t.event_id = p_event LIMIT 50) s;
  IF to_regclass('public.exos_fee_rules') IS NOT NULL THEN
    EXECUTE $q$
      SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'name', r.name, 'recipient', r.recipient, 'kind', r.kind, 'calc', r.calc, 'percent', r.percent,
               'amount_cents', r.amount_cents, 'cap_cents', r.cap_cents, 'per', r.per, 'taxable', r.taxable,
               'applies_to_addons', r.applies_to_addons)) ORDER BY r.sort_order, r.id), '[]'::jsonb)
        FROM (SELECT * FROM public.exos_fee_rules WHERE event_id = $1 AND active LIMIT 25) r$q$
      INTO v_fees USING p_event;
    EXECUTE 'SELECT inherit_org_rules FROM public.exos_event_fee_settings WHERE event_id = $1' INTO v_inherit USING p_event;
  END IF;
  INSERT INTO public.exos_event_templates (org_id, name, event_name, description, capacity, doors_offset_minutes,
                                           duration_minutes, event_fields, tiers, fee_rules, inherit_org_fees, created_by)
  VALUES (p_org, left(coalesce(nullif(btrim(p_name), ''), v_ev.name, 'Template'), 100), left(v_ev.name, 200),
          left(coalesce(v_ev.description, ''), 20000), nullif(v_ev.total_tickets, 0),
          CASE WHEN v_ev.doors_at IS NOT NULL AND v_ev.starts_at IS NOT NULL AND v_ev.doors_at <= v_ev.starts_at
               THEN least(1440, (extract(epoch FROM v_ev.starts_at - v_ev.doors_at) / 60)::int) END,
          CASE WHEN v_ev.ends_at IS NOT NULL AND v_ev.starts_at IS NOT NULL AND v_ev.ends_at > v_ev.starts_at
               THEN least(10080, greatest(1, (extract(epoch FROM v_ev.ends_at - v_ev.starts_at) / 60)::int)) END,
          v_fields, v_tiers, v_fees, coalesce(v_inherit, true), p_actor)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_template_from_event(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_template_from_event(uuid, uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_event_template_from_event(p_event_id uuid, p_name text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_events WHERE id = p_event_id);
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_fin_staff(v_org, ARRAY['owner', 'manager']);
  RETURN public._exos_event_template_from_event(v_org, auth.uid(), p_event_id, p_name);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_template_from_event(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_template_from_event(uuid, text) TO authenticated;

-- ===========================================================================
-- 2. Note templates
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_note_templates (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  title      text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 100),
  body       text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 5000),
  status     text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_note_templates_org_idx ON public.exos_note_templates (org_id, status, title);

CREATE OR REPLACE FUNCTION public._exos_tg_note_template()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'a template can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_note_templates:' || NEW.org_id::text, 0));
    IF (SELECT count(*) FROM public.exos_note_templates WHERE org_id = NEW.org_id) >= 200 THEN
      RAISE EXCEPTION 'at most 200 note templates per organization' USING ERRCODE = '54000';
    END IF;
  ELSE
    NEW.created_by := OLD.created_by;
  END IF;
  NEW.title := btrim(NEW.title);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_note_template() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_note_templates_guard ON public.exos_note_templates;
CREATE TRIGGER exos_note_templates_guard BEFORE INSERT OR UPDATE ON public.exos_note_templates
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_note_template();

-- ===========================================================================
-- 3. Rental invoice templates and rental invoices
-- ===========================================================================
-- Lines, deposits and taxes in canonical form:
--   items:    [{ title, description?, category?, quantity (0-100000, 2 dp),
--                cost_type fixed | per_head, cost_cents, position }]  (<= 100)
--   deposits: [{ deposit_type flat | percent, value (cents | percent),
--                due_date_type relative | specific, relative_due_days?
--                (days before the rental date), specific_due_date? }] (<= 10)
--   tax_fees: [{ name, rate_percent, category? }]                      (<= 10)
CREATE OR REPLACE FUNCTION public._exos_rental_lines(p_items jsonb, p_deposits jsonb, p_tax jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  x jsonb; i int := 0; v_items jsonb := '[]'::jsonb; v_dep jsonb := '[]'::jsonb; v_tax jsonb := '[]'::jsonb;
  v_bad text; q text; v_type text; v_due text; v_val text;
BEGIN
  IF jsonb_typeof(coalesce(p_items, '[]')) <> 'array' OR jsonb_array_length(coalesce(p_items, '[]')) > 100 THEN
    RAISE EXCEPTION 'items must be a list of at most 100 lines' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(coalesce(p_deposits, '[]')) <> 'array' OR jsonb_array_length(coalesce(p_deposits, '[]')) > 10 THEN
    RAISE EXCEPTION 'deposits must be a list of at most 10' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(coalesce(p_tax, '[]')) <> 'array' OR jsonb_array_length(coalesce(p_tax, '[]')) > 10 THEN
    RAISE EXCEPTION 'tax_fees must be a list of at most 10' USING ERRCODE = '22023';
  END IF;
  FOR x IN SELECT y FROM jsonb_array_elements(coalesce(p_items, '[]')) y LOOP
    IF jsonb_typeof(x) <> 'object' THEN RAISE EXCEPTION 'items[%] must be an object', i USING ERRCODE = '22023'; END IF;
    SELECT k INTO v_bad FROM jsonb_object_keys(x) k
     WHERE k NOT IN ('title', 'description', 'category', 'quantity', 'cost_type', 'cost_cents', 'position') LIMIT 1;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'items[%]: unknown field %', i, left(v_bad, 60) USING ERRCODE = '22023'; END IF;
    IF char_length(public._exos_fin_text(x, 'title', 'items.title', 120)) = 0 THEN
      RAISE EXCEPTION 'items[%] needs a title', i USING ERRCODE = '22023';
    END IF;
    q := coalesce(x ->> 'quantity', '1');
    IF q !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' OR q::numeric > 100000 THEN
      RAISE EXCEPTION 'items[%].quantity must be 0-100000 with at most 2 decimals', i USING ERRCODE = '22023';
    END IF;
    IF coalesce(x ->> 'cost_type', 'fixed') NOT IN ('fixed', 'per_head') THEN
      RAISE EXCEPTION 'items[%].cost_type must be fixed or per_head', i USING ERRCODE = '22023';
    END IF;
    IF public._exos_fin_cents(x, 'cost_cents', 'items.cost_cents') > 1000000000 THEN
      RAISE EXCEPTION 'items[%].cost_cents is at most 1000000000', i USING ERRCODE = '22023';
    END IF;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'title', public._exos_fin_text(x, 'title', 'items.title', 120),
      'description', public._exos_fin_text(x, 'description', 'items.description', 1000),
      'category', public._exos_fin_text(x, 'category', 'items.category', 60),
      'quantity', q::numeric, 'cost_type', coalesce(x ->> 'cost_type', 'fixed'),
      'cost_cents', public._exos_fin_cents(x, 'cost_cents', 'items.cost_cents'), 'position', i));
    i := i + 1;
  END LOOP;
  i := 0;
  FOR x IN SELECT y FROM jsonb_array_elements(coalesce(p_deposits, '[]')) y LOOP
    IF jsonb_typeof(x) <> 'object' THEN RAISE EXCEPTION 'deposits[%] must be an object', i USING ERRCODE = '22023'; END IF;
    SELECT k INTO v_bad FROM jsonb_object_keys(x) k
     WHERE k NOT IN ('deposit_type', 'value', 'due_date_type', 'relative_due_days', 'specific_due_date') LIMIT 1;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'deposits[%]: unknown field %', i, left(v_bad, 60) USING ERRCODE = '22023'; END IF;
    v_type := coalesce(x ->> 'deposit_type', 'flat');
    v_due := coalesce(x ->> 'due_date_type', 'relative');
    IF v_type NOT IN ('flat', 'percent') OR v_due NOT IN ('relative', 'specific') THEN
      RAISE EXCEPTION 'deposits[%]: deposit_type flat or percent; due_date_type relative or specific', i USING ERRCODE = '22023';
    END IF;
    v_val := x ->> 'value';
    IF v_type = 'percent' THEN PERFORM public._exos_fin_pct(x, 'value', 'deposits.value');
    ELSE PERFORM public._exos_fin_cents(x, 'value', 'deposits.value'); END IF;
    IF v_due = 'relative' AND coalesce(x ->> 'relative_due_days', '0') !~ '^-?[0-9]{1,3}$' THEN
      RAISE EXCEPTION 'deposits[%].relative_due_days must be a whole number of days (-999 to 999)', i USING ERRCODE = '22023';
    END IF;
    v_dep := v_dep || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'deposit_type', v_type,
      'value', CASE WHEN v_type = 'percent' THEN to_jsonb(public._exos_fin_pct(x, 'value', 'deposits.value'))
                    ELSE to_jsonb(public._exos_fin_cents(x, 'value', 'deposits.value')) END,
      'due_date_type', v_due,
      'relative_due_days', CASE WHEN v_due = 'relative' THEN coalesce((x ->> 'relative_due_days')::int, 0) END,
      'specific_due_date', CASE WHEN v_due = 'specific'
                                THEN to_jsonb(coalesce(public._exos_fin_date(x, 'specific_due_date', 'deposits.specific_due_date'),
                                                       NULL)) END)));
    IF v_due = 'specific' AND public._exos_fin_date(x, 'specific_due_date', 'deposits.specific_due_date') IS NULL THEN
      RAISE EXCEPTION 'deposits[%] needs specific_due_date', i USING ERRCODE = '22023';
    END IF;
    i := i + 1;
  END LOOP;
  i := 0;
  FOR x IN SELECT y FROM jsonb_array_elements(coalesce(p_tax, '[]')) y LOOP
    IF jsonb_typeof(x) <> 'object' THEN RAISE EXCEPTION 'tax_fees[%] must be an object', i USING ERRCODE = '22023'; END IF;
    SELECT k INTO v_bad FROM jsonb_object_keys(x) k WHERE k NOT IN ('name', 'rate_percent', 'category') LIMIT 1;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'tax_fees[%]: unknown field %', i, left(v_bad, 60) USING ERRCODE = '22023'; END IF;
    IF char_length(public._exos_fin_text(x, 'name', 'tax_fees.name', 60)) = 0 THEN
      RAISE EXCEPTION 'tax_fees[%] needs a name', i USING ERRCODE = '22023';
    END IF;
    v_tax := v_tax || jsonb_build_array(jsonb_build_object(
      'name', public._exos_fin_text(x, 'name', 'tax_fees.name', 60),
      'rate_percent', public._exos_fin_pct(x, 'rate_percent', 'tax_fees.rate_percent'),
      'category', public._exos_fin_text(x, 'category', 'tax_fees.category', 60)));
    i := i + 1;
  END LOOP;
  RETURN jsonb_build_object('items', v_items, 'deposits', v_dep, 'tax_fees', v_tax);
END $$;
REVOKE ALL ON FUNCTION public._exos_rental_lines(jsonb, jsonb, jsonb) FROM PUBLIC, anon, authenticated;

-- The totals of canonical lines (src/lib/rentalInvoice.ts computes the same):
-- line = round(quantity x cost x (attendance when per head)); the discount is
-- capped at the subtotal; each tax / fee = round(taxable x rate / 100);
-- total = taxable + taxes; deposits = flat cents or round(total x pct / 100).
CREATE OR REPLACE FUNCTION public._exos_rental_totals(p_items jsonb, p_attendance integer, p_discount bigint,
                                                      p_tax jsonb, p_deposits jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  WITH l AS (
    SELECT coalesce(sum(round((x ->> 'quantity')::numeric * (x ->> 'cost_cents')::numeric
                              * CASE WHEN x ->> 'cost_type' = 'per_head' THEN coalesce(p_attendance, 0) ELSE 1 END)), 0)::bigint AS sub
      FROM jsonb_array_elements(coalesce(p_items, '[]')) x
  ), d AS (
    SELECT sub, least(coalesce(p_discount, 0), sub) AS disc FROM l
  ), t AS (
    SELECT sub, disc, sub - disc AS taxable,
           coalesce((SELECT sum(round((sub - disc) * (x ->> 'rate_percent')::numeric / 100))
                       FROM jsonb_array_elements(coalesce(p_tax, '[]')) x), 0)::bigint AS tax
      FROM d
  )
  SELECT jsonb_build_object('subtotal_cents', sub, 'discount_cents', disc, 'taxable_cents', taxable,
           'tax_cents', tax, 'total_cents', taxable + tax,
           'deposits_cents', coalesce((SELECT sum(CASE WHEN x ->> 'deposit_type' = 'percent'
                                                        THEN round((taxable + tax) * (x ->> 'value')::numeric / 100)
                                                        ELSE (x ->> 'value')::numeric END)
                                         FROM jsonb_array_elements(coalesce(p_deposits, '[]')) x), 0)::bigint)
    FROM t
$$;
REVOKE ALL ON FUNCTION public._exos_rental_totals(jsonb, integer, bigint, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_rental_totals(jsonb, integer, bigint, jsonb, jsonb) TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.exos_rental_invoice_templates (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  title            text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 100),
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  currency         text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  payee_name       text CHECK (payee_name IS NULL OR char_length(payee_name) <= 200),
  notes            text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 10000),
  terms            text NOT NULL DEFAULT '' CHECK (char_length(terms) <= 20000),
  attendance_count integer CHECK (attendance_count IS NULL OR attendance_count BETWEEN 0 AND 1000000),
  discount_cents   bigint NOT NULL DEFAULT 0 CHECK (discount_cents BETWEEN 0 AND 100000000000),
  items            jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(items) = 'array'),
  deposits         jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(deposits) = 'array'),
  tax_fees         jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(tax_fees) = 'array'),
  created_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id)
);
CREATE INDEX IF NOT EXISTS exos_rental_invoice_templates_org_idx ON public.exos_rental_invoice_templates (org_id, status, title);

CREATE OR REPLACE FUNCTION public._exos_tg_rental_template()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'a template can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_rental_invoice_templates:' || NEW.org_id::text, 0));
    IF (SELECT count(*) FROM public.exos_rental_invoice_templates WHERE org_id = NEW.org_id) >= 100 THEN
      RAISE EXCEPTION 'at most 100 rental invoice templates per organization' USING ERRCODE = '54000';
    END IF;
  ELSE
    NEW.created_by := OLD.created_by;
  END IF;
  NEW.title := btrim(NEW.title);
  NEW.payee_name := nullif(btrim(NEW.payee_name), '');
  v := public._exos_rental_lines(NEW.items, NEW.deposits, NEW.tax_fees);
  NEW.items := v -> 'items'; NEW.deposits := v -> 'deposits'; NEW.tax_fees := v -> 'tax_fees';
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_rental_template() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_rental_invoice_templates_guard ON public.exos_rental_invoice_templates;
CREATE TRIGGER exos_rental_invoice_templates_guard BEFORE INSERT OR UPDATE ON public.exos_rental_invoice_templates
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_rental_template();

-- One numbering series per org. last_number only ever moves inside
-- _exos_rental_invoice_issue, in the transaction that issues the invoice.
CREATE TABLE IF NOT EXISTS public.exos_rental_invoice_counters (
  org_id      uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  prefix      text NOT NULL DEFAULT 'R-' CHECK (prefix ~ '^[A-Za-z0-9][A-Za-z0-9_./-]{0,15}$'),
  last_number integer NOT NULL DEFAULT 0 CHECK (last_number >= 0),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.exos_rental_invoices (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  template_id      uuid REFERENCES public.exos_rental_invoice_templates (id) ON DELETE SET NULL,
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'issued', 'paid', 'void')),
  number           text CHECK (number IS NULL OR char_length(number) <= 40),
  number_seq       integer CHECK (number_seq IS NULL OR number_seq >= 1),
  title            text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 100),
  currency         text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  payee_name       text CHECK (payee_name IS NULL OR char_length(payee_name) <= 200),
  bill_to_name     text CHECK (bill_to_name IS NULL OR char_length(bill_to_name) <= 200),
  bill_to_email    text CHECK (bill_to_email IS NULL OR (char_length(bill_to_email) <= 200
                               AND bill_to_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
  notes            text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 10000),
  terms            text NOT NULL DEFAULT '' CHECK (char_length(terms) <= 20000),
  attendance_count integer CHECK (attendance_count IS NULL OR attendance_count BETWEEN 0 AND 1000000),
  discount_cents   bigint NOT NULL DEFAULT 0 CHECK (discount_cents BETWEEN 0 AND 100000000000),
  items            jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(items) = 'array'),
  deposits         jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(deposits) = 'array'),
  tax_fees         jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(tax_fees) = 'array'),
  -- Computed by the trigger from the lines (never from a client).
  subtotal_cents   bigint NOT NULL DEFAULT 0,
  tax_cents        bigint NOT NULL DEFAULT 0,
  total_cents      bigint NOT NULL DEFAULT 0,
  deposits_cents   bigint NOT NULL DEFAULT 0,
  -- What is rented: a hold (optionally one night of it), or a venue / room on a date.
  hold_id          uuid REFERENCES public.exos_holds (id) ON DELETE SET NULL,
  hold_position_id uuid REFERENCES public.exos_hold_positions (id) ON DELETE SET NULL,
  venue_id         uuid REFERENCES public.exos_venues (id) ON DELETE SET NULL,
  room_id          uuid REFERENCES public.exos_venue_rooms (id) ON DELETE SET NULL,
  rental_date      date,
  event_id         uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  due_on           date,
  issued_at        timestamptz,
  paid_at          timestamptz,
  voided_at        timestamptz,
  void_reason      text CHECK (void_reason IS NULL OR char_length(void_reason) <= 500),
  created_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_via      text NOT NULL DEFAULT 'dashboard' CHECK (created_via IN ('dashboard', 'api')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'draft') = (number IS NULL)),
  CHECK ((number IS NULL) = (number_seq IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_rental_invoices_number_uq ON public.exos_rental_invoices (org_id, number) WHERE number IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_rental_invoices_seq_uq ON public.exos_rental_invoices (org_id, number_seq) WHERE number_seq IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_rental_invoices_org_idx ON public.exos_rental_invoices (org_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_rental_invoices_hold_idx ON public.exos_rental_invoices (hold_id) WHERE hold_id IS NOT NULL;

-- Rental invoice rows: links stay in the org (a night fixes its hold, venue,
-- room and date), lines normalized and totals computed while a draft; an
-- issued invoice is frozen except paid / void; the number is set only by the
-- issue function.
CREATE OR REPLACE FUNCTION public._exos_tg_rental_invoice()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb; p public.exos_hold_positions%ROWTYPE; v_issuing boolean := coalesce(current_setting('exos.rental_issue', true), '') = 'on';
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'an invoice can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.number IS NOT NULL THEN
      RAISE EXCEPTION 'a rental invoice starts as a draft; issue it to number it' USING ERRCODE = '22023';
    END IF;
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_rental_invoices:' || NEW.org_id::text, 0));
    IF (SELECT count(*) FROM public.exos_rental_invoices WHERE org_id = NEW.org_id AND status = 'draft') >= 500 THEN
      RAISE EXCEPTION 'at most 500 draft rental invoices per organization' USING ERRCODE = '54000';
    END IF;
  ELSE
    NEW.created_by := OLD.created_by;
    NEW.created_via := OLD.created_via;
    IF (NEW.number IS DISTINCT FROM OLD.number OR NEW.number_seq IS DISTINCT FROM OLD.number_seq) AND NOT v_issuing THEN
      RAISE EXCEPTION 'an invoice number is assigned by issuing it' USING ERRCODE = '42501';
    END IF;
    IF OLD.status <> 'draft' THEN
      -- Frozen: only the payment / void fields may change.
      IF (to_jsonb(NEW) - ARRAY['status', 'paid_at', 'voided_at', 'void_reason', 'updated_at', 'template_id',
                                'hold_id', 'hold_position_id', 'venue_id', 'room_id', 'event_id'])
         IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['status', 'paid_at', 'voided_at', 'void_reason', 'updated_at', 'template_id',
                                'hold_id', 'hold_position_id', 'venue_id', 'room_id', 'event_id'])
         OR (NEW.hold_id IS NOT NULL AND NEW.hold_id IS DISTINCT FROM OLD.hold_id)
         OR (NEW.venue_id IS NOT NULL AND NEW.venue_id IS DISTINCT FROM OLD.venue_id)
         OR (NEW.event_id IS NOT NULL AND NEW.event_id IS DISTINCT FROM OLD.event_id) THEN
        RAISE EXCEPTION 'an issued invoice can''t be edited; void it and make a new one' USING ERRCODE = '55000';
      END IF;
      IF NOT ((OLD.status = NEW.status) OR (OLD.status = 'issued' AND NEW.status IN ('paid', 'void'))
              OR (OLD.status = 'paid' AND NEW.status IN ('issued', 'void'))) THEN
        RAISE EXCEPTION 'an invoice can''t go from % to %', OLD.status, NEW.status USING ERRCODE = '55000';
      END IF;
      RETURN NEW;
    END IF;
    IF NEW.status <> 'draft' AND NOT v_issuing THEN
      RAISE EXCEPTION 'issue the invoice to change its status' USING ERRCODE = '55000';
    END IF;
  END IF;

  -- Links (drafts): all in this org. Only links set or changed now are
  -- checked, so a hold or venue going away (ON DELETE SET NULL) never trips.
  IF NEW.hold_position_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.hold_position_id IS DISTINCT FROM OLD.hold_position_id) THEN
    SELECT * INTO p FROM public.exos_hold_positions WHERE id = NEW.hold_position_id AND org_id = NEW.org_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'hold_position_id is not one of this organization''s held nights' USING ERRCODE = '22023'; END IF;
    NEW.hold_id := p.hold_id; NEW.venue_id := p.venue_id; NEW.room_id := p.room_id; NEW.rental_date := p.date;
  END IF;
  IF NEW.hold_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.hold_id IS DISTINCT FROM OLD.hold_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_holds WHERE id = NEW.hold_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'hold_id is not one of this organization''s holds' USING ERRCODE = '22023';
  END IF;
  IF NEW.venue_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.venue_id IS DISTINCT FROM OLD.venue_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_venues WHERE id = NEW.venue_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'venue_id is not one of this organization''s venues' USING ERRCODE = '22023';
  END IF;
  IF NEW.room_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.room_id IS DISTINCT FROM OLD.room_id OR NEW.venue_id IS DISTINCT FROM OLD.venue_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_venue_rooms WHERE id = NEW.room_id
                       AND venue_id IS NOT DISTINCT FROM NEW.venue_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'room_id is not a room of that venue' USING ERRCODE = '22023';
  END IF;
  IF NEW.event_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.event_id IS DISTINCT FROM OLD.event_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = NEW.event_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'event_id is not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  IF NEW.template_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.template_id IS DISTINCT FROM OLD.template_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_rental_invoice_templates WHERE id = NEW.template_id AND org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'template_id is not one of this organization''s rental invoice templates' USING ERRCODE = '22023';
  END IF;
  NEW.title := btrim(NEW.title);
  NEW.payee_name := nullif(btrim(NEW.payee_name), '');
  NEW.bill_to_name := nullif(btrim(NEW.bill_to_name), '');
  NEW.bill_to_email := nullif(lower(btrim(NEW.bill_to_email)), '');
  v := public._exos_rental_lines(NEW.items, NEW.deposits, NEW.tax_fees);
  NEW.items := v -> 'items'; NEW.deposits := v -> 'deposits'; NEW.tax_fees := v -> 'tax_fees';
  v := public._exos_rental_totals(NEW.items, NEW.attendance_count, NEW.discount_cents, NEW.tax_fees, NEW.deposits);
  NEW.subtotal_cents := (v ->> 'subtotal_cents')::bigint;
  NEW.tax_cents := (v ->> 'tax_cents')::bigint;
  NEW.total_cents := (v ->> 'total_cents')::bigint;
  NEW.deposits_cents := (v ->> 'deposits_cents')::bigint;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_rental_invoice() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_rental_invoices_guard ON public.exos_rental_invoices;
CREATE TRIGGER exos_rental_invoices_guard BEFORE INSERT OR UPDATE ON public.exos_rental_invoices
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_rental_invoice();

-- A number, once given, is never freed: issued / paid / void invoices can't
-- be deleted (an org's deletion cascades past this: TG_LEVEL is per row but
-- the org row is already gone, so it is allowed then).
CREATE OR REPLACE FUNCTION public._exos_tg_rental_invoice_del()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.number IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = OLD.org_id) THEN
    RAISE EXCEPTION 'an issued invoice can''t be deleted; void it instead' USING ERRCODE = '55000';
  END IF;
  RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_rental_invoice_del() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_rental_invoices_del_guard ON public.exos_rental_invoices;
CREATE TRIGGER exos_rental_invoices_del_guard BEFORE DELETE ON public.exos_rental_invoices
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_rental_invoice_del();

CREATE OR REPLACE FUNCTION public._exos_rental_invoice_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT to_jsonb(r) - 'org_id' - 'created_by' FROM public.exos_rental_invoices r WHERE r.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_rental_invoice_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rental_invoice_json(uuid) TO service_role;

-- The fields a draft takes from a body (create and update).
CREATE OR REPLACE FUNCTION public._exos_rental_invoice_fields(p jsonb, p_create boolean)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_bad text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'the body must be an object' USING ERRCODE = '22023';
  END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(p) k
   WHERE NOT (k = ANY (ARRAY['title', 'currency', 'payee_name', 'bill_to_name', 'bill_to_email', 'notes', 'terms',
                            'attendance_count', 'discount_cents', 'items', 'deposits', 'tax_fees', 'hold_id',
                            'hold_position_id', 'venue_id', 'room_id', 'rental_date', 'event_id', 'due_on']
                      || CASE WHEN p_create THEN ARRAY['template_id'] ELSE ARRAY[]::text[] END))
   ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'unknown or read-only field: %', left(v_bad, 60) USING ERRCODE = '22023';
  END IF;
  RETURN p;
END $$;
REVOKE ALL ON FUNCTION public._exos_rental_invoice_fields(jsonb, boolean) FROM PUBLIC, anon, authenticated;

-- ---- Cores (service_role: exos-api passes the key's org) --------------------
-- p: { template_id?, title?, ...any draft field }. The template's lines,
-- terms and defaults are copied, then the body's fields win.
CREATE OR REPLACE FUNCTION public._exos_rental_invoice_create(p_org uuid, p_actor uuid, p_via text, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  b   jsonb := public._exos_rental_invoice_fields(p, true);
  tp  public.exos_rental_invoice_templates%ROWTYPE;
  v   jsonb := '{}'::jsonb;
  v_id uuid;
BEGIN
  IF nullif(b ->> 'template_id', '') IS NOT NULL THEN
    SELECT * INTO tp FROM public.exos_rental_invoice_templates
     WHERE id::text = b ->> 'template_id' AND org_id = p_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'template not found' USING ERRCODE = 'P0002'; END IF;
    IF tp.status <> 'active' THEN RAISE EXCEPTION 'this template is archived' USING ERRCODE = '55000'; END IF;
    v := jsonb_build_object('template_id', tp.id, 'title', tp.title, 'currency', tp.currency, 'payee_name', tp.payee_name,
                            'notes', tp.notes, 'terms', tp.terms, 'attendance_count', tp.attendance_count,
                            'discount_cents', tp.discount_cents, 'items', tp.items, 'deposits', tp.deposits,
                            'tax_fees', tp.tax_fees);
  END IF;
  v := v || (b - 'template_id');
  IF btrim(coalesce(v ->> 'title', '')) = '' THEN
    RAISE EXCEPTION 'a rental invoice needs a title (or a template_id)' USING ERRCODE = '22023';
  END IF;
  v_id := public._exos_api_insert('public.exos_rental_invoices',
            ARRAY['template_id', 'title', 'currency', 'payee_name', 'bill_to_name', 'bill_to_email', 'notes', 'terms',
                  'attendance_count', 'discount_cents', 'items', 'deposits', 'tax_fees', 'hold_id', 'hold_position_id',
                  'venue_id', 'room_id', 'rental_date', 'event_id', 'due_on'],
            jsonb_strip_nulls(v),
            jsonb_build_object('org_id', p_org, 'created_by', p_actor, 'created_via', coalesce(p_via, 'dashboard')));
  RETURN public._exos_rental_invoice_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_rental_invoice_create(uuid, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rental_invoice_create(uuid, uuid, text, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_rental_invoice_update(p_org uuid, p_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_rental_invoices%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_rental_invoices WHERE id = p_id AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'rental invoice not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status <> 'draft' THEN
    RAISE EXCEPTION 'an issued invoice can''t be edited; void it and make a new one' USING ERRCODE = '55000';
  END IF;
  PERFORM public._exos_api_update('public.exos_rental_invoices', p_id,
            ARRAY['title', 'currency', 'payee_name', 'bill_to_name', 'bill_to_email', 'notes', 'terms',
                  'attendance_count', 'discount_cents', 'items', 'deposits', 'tax_fees', 'hold_id', 'hold_position_id',
                  'venue_id', 'room_id', 'rental_date', 'event_id', 'due_on'],
            public._exos_rental_invoice_fields(p, false));
  RETURN public._exos_rental_invoice_json(p_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_rental_invoice_update(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rental_invoice_update(uuid, uuid, jsonb) TO service_role;

-- Issue: the org's next number, in this transaction. Concurrent issues queue
-- on the counter row; a failure rolls the counter back too, so numbers are
-- gapless. Issuing an issued invoice answers it again (already_issued).
CREATE OR REPLACE FUNCTION public._exos_rental_invoice_issue(p_org uuid, p_id uuid, p_due_on date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_rental_invoices%ROWTYPE; v_n int; v_prefix text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_rental_invoices WHERE id = p_id AND org_id = p_org) THEN
    RAISE EXCEPTION 'rental invoice not found' USING ERRCODE = 'P0002';
  END IF;
  -- Lock order: the org's counter row first, then the invoice, in every
  -- issue, so concurrent issues queue instead of deadlocking.
  INSERT INTO public.exos_rental_invoice_counters (org_id) VALUES (p_org) ON CONFLICT (org_id) DO NOTHING;
  PERFORM 1 FROM public.exos_rental_invoice_counters WHERE org_id = p_org FOR UPDATE;
  SELECT * INTO r FROM public.exos_rental_invoices WHERE id = p_id AND org_id = p_org FOR UPDATE;
  IF r.status <> 'draft' THEN
    RETURN public._exos_rental_invoice_json(p_id) || jsonb_build_object('already_issued', true);
  END IF;
  IF jsonb_array_length(r.items) = 0 THEN
    RAISE EXCEPTION 'add at least one line before issuing' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_rental_invoice_counters SET last_number = last_number + 1, updated_at = now()
   WHERE org_id = p_org RETURNING last_number, prefix INTO v_n, v_prefix;
  PERFORM set_config('exos.rental_issue', 'on', true);
  UPDATE public.exos_rental_invoices
     SET status = 'issued', number = v_prefix || lpad(v_n::text, 5, '0'), number_seq = v_n, issued_at = now(),
         due_on = coalesce(p_due_on, due_on)
   WHERE id = p_id;
  PERFORM set_config('exos.rental_issue', '', true);
  RETURN public._exos_rental_invoice_json(p_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_rental_invoice_issue(uuid, uuid, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rental_invoice_issue(uuid, uuid, date) TO service_role;

-- paid / issued (unmark) / void. Idempotent: the same status again is a no-op.
CREATE OR REPLACE FUNCTION public._exos_rental_invoice_set_status(p_org uuid, p_id uuid, p_status text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_rental_invoices%ROWTYPE;
BEGIN
  IF p_status NOT IN ('paid', 'issued', 'void') THEN
    RAISE EXCEPTION 'status must be paid, issued or void' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO r FROM public.exos_rental_invoices WHERE id = p_id AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'rental invoice not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status = p_status THEN RETURN public._exos_rental_invoice_json(p_id); END IF;
  IF r.status = 'draft' THEN
    RAISE EXCEPTION 'issue the invoice first (a draft can simply be deleted)' USING ERRCODE = '55000';
  END IF;
  UPDATE public.exos_rental_invoices
     SET status = p_status,
         paid_at = CASE WHEN p_status = 'paid' THEN now() WHEN p_status = 'issued' THEN NULL ELSE paid_at END,
         voided_at = CASE WHEN p_status = 'void' THEN now() ELSE voided_at END,
         void_reason = CASE WHEN p_status = 'void' THEN nullif(left(btrim(coalesce(p_reason, '')), 500), '') ELSE void_reason END
   WHERE id = p_id;
  RETURN public._exos_rental_invoice_json(p_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_rental_invoice_set_status(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rental_invoice_set_status(uuid, uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_rental_invoice_delete(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_rental_invoices%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_rental_invoices WHERE id = p_id AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'rental invoice not found' USING ERRCODE = 'P0002'; END IF;
  IF r.status <> 'draft' THEN
    RAISE EXCEPTION 'an issued invoice can''t be deleted; void it instead' USING ERRCODE = '55000';
  END IF;
  DELETE FROM public.exos_rental_invoices WHERE id = p_id;
  RETURN jsonb_build_object('id', p_id, 'deleted', true);
END $$;
REVOKE ALL ON FUNCTION public._exos_rental_invoice_delete(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_rental_invoice_delete(uuid, uuid) TO service_role;

-- ---- Signed-in wrappers (owner / manager / finance) -------------------------
CREATE OR REPLACE FUNCTION public._exos_rental_invoice_org(p_id uuid)
RETURNS uuid LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_rental_invoices WHERE id = p_id);
BEGIN
  IF v_org IS NULL THEN RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_fin_staff(v_org, ARRAY['owner', 'manager', 'finance']);
END $$;
REVOKE ALL ON FUNCTION public._exos_rental_invoice_org(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_rental_invoice_create(p_org_id uuid, p_invoice jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'finance']);
  RETURN public._exos_rental_invoice_create(p_org_id, auth.uid(), 'dashboard', p_invoice);
END $$;
CREATE OR REPLACE FUNCTION public.exos_rental_invoice_update(p_id uuid, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ BEGIN RETURN public._exos_rental_invoice_update(public._exos_rental_invoice_org(p_id), p_id, p_patch); END $$;
CREATE OR REPLACE FUNCTION public.exos_rental_invoice_issue(p_id uuid, p_due_on date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ BEGIN RETURN public._exos_rental_invoice_issue(public._exos_rental_invoice_org(p_id), p_id, p_due_on); END $$;
CREATE OR REPLACE FUNCTION public.exos_rental_invoice_set_status(p_id uuid, p_status text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ BEGIN RETURN public._exos_rental_invoice_set_status(public._exos_rental_invoice_org(p_id), p_id, p_status, p_reason); END $$;
CREATE OR REPLACE FUNCTION public.exos_rental_invoice_delete(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ BEGIN RETURN public._exos_rental_invoice_delete(public._exos_rental_invoice_org(p_id), p_id); END $$;
-- The prefix of numbers not yet given (owner / manager). Numbers already
-- given keep theirs; the sequence carries on.
CREATE OR REPLACE FUNCTION public.exos_rental_invoice_prefix_set(p_org_id uuid, p_prefix text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v text := btrim(coalesce(p_prefix, ''));
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager']);
  IF v !~ '^[A-Za-z0-9][A-Za-z0-9_./-]{0,15}$' THEN
    RAISE EXCEPTION 'prefix: 1-16 letters, digits, _ . / or -, starting with a letter or digit' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_rental_invoice_counters (org_id, prefix) VALUES (p_org_id, v)
  ON CONFLICT (org_id) DO UPDATE SET prefix = EXCLUDED.prefix, updated_at = now();
  RETURN v;
END $$;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['exos_rental_invoice_create(uuid, jsonb)', 'exos_rental_invoice_update(uuid, jsonb)',
                           'exos_rental_invoice_issue(uuid, date)', 'exos_rental_invoice_set_status(uuid, text, text)',
                           'exos_rental_invoice_delete(uuid)', 'exos_rental_invoice_prefix_set(uuid, text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;

-- ===========================================================================
-- 4. Inbound booking submissions
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_inbound_settings (
  org_id     uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  enabled    boolean NOT NULL DEFAULT false,
  title      text CHECK (title IS NULL OR char_length(title) <= 120),
  intro      text CHECK (intro IS NULL OR char_length(intro) <= 2000),
  -- The venues the form offers (empty = all of the org's venues).
  venue_ids  uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(venue_ids) <= 50),
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public._exos_tg_inbound_settings()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'settings can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  NEW.updated_by := coalesce(auth.uid(), NEW.updated_by);
  NEW.title := nullif(btrim(NEW.title), '');
  NEW.intro := nullif(btrim(NEW.intro), '');
  IF EXISTS (SELECT 1 FROM unnest(NEW.venue_ids) v
              WHERE NOT EXISTS (SELECT 1 FROM public.exos_venues x WHERE x.id = v AND x.org_id = NEW.org_id)) THEN
    RAISE EXCEPTION 'venue_ids: every venue must be one of this organization''s' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_inbound_settings() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_inbound_settings_guard ON public.exos_inbound_settings;
CREATE TRIGGER exos_inbound_settings_guard BEFORE INSERT OR UPDATE ON public.exos_inbound_settings
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_inbound_settings();

CREATE TABLE IF NOT EXISTS public.exos_inbound_submissions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  status          text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'reviewing', 'accepted', 'declined')),
  source          text NOT NULL DEFAULT 'form' CHECK (source IN ('form', 'api')),
  artist_name     text NOT NULL CHECK (char_length(btrim(artist_name)) BETWEEN 1 AND 150),
  contact_name    text CHECK (contact_name IS NULL OR char_length(contact_name) <= 100),
  contact_role    text CHECK (contact_role IS NULL OR contact_role IN ('artist', 'agent', 'manager', 'promoter', 'other')),
  email           text CHECK (email IS NULL OR (char_length(email) <= 200
                              AND email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
  phone           text CHECK (phone IS NULL OR char_length(phone) <= 40),
  company         text CHECK (company IS NULL OR char_length(company) <= 100),
  message         text NOT NULL DEFAULT '' CHECK (char_length(message) <= 5000),
  -- { spotify, instagram, website, youtube, tiktok, bandcamp, soundcloud }: https URLs.
  links           jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(links) = 'object'),
  genres          text[] NOT NULL DEFAULT '{}' CHECK (cardinality(genres) <= 10),
  venue_id        uuid REFERENCES public.exos_venues (id) ON DELETE SET NULL,
  preferred_dates date[] NOT NULL DEFAULT '{}' CHECK (cardinality(preferred_dates) <= 10),
  dates_flexible  boolean NOT NULL DEFAULT true,
  expected_draw   integer CHECK (expected_draw IS NULL OR expected_draw BETWEEN 0 AND 1000000),
  -- SHA-256 of the forwarded IP (never the IP), for the per-network limits.
  ip_hash         text CHECK (ip_hash IS NULL OR ip_hash ~ '^[0-9a-f]{64}$'),
  user_agent      text CHECK (user_agent IS NULL OR char_length(user_agent) <= 300),
  hold_id         uuid REFERENCES public.exos_holds (id) ON DELETE SET NULL,
  staff_note      text NOT NULL DEFAULT '' CHECK (char_length(staff_note) <= 2000),
  reviewed_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  reviewed_at     timestamptz,
  api_key_id      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_inbound_submissions_org_idx ON public.exos_inbound_submissions (org_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_inbound_submissions_ip_idx ON public.exos_inbound_submissions (ip_hash, created_at DESC) WHERE ip_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_inbound_submissions_email_idx ON public.exos_inbound_submissions (org_id, email, created_at DESC) WHERE email IS NOT NULL;

-- Validate and insert one submission. p: { artist_name, contact_name?,
-- contact_role?, email?, phone?, company?, message?, links?, genres?,
-- venue_id?, preferred_dates?, dates_flexible?, expected_draw? }.
CREATE OR REPLACE FUNCTION public._exos_inbound_create(p_org uuid, p_source text, p jsonb, p_ip_hash text,
                                                       p_ua text, p_api_key uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad text; v_links jsonb := '{}'::jsonb; k text; v text; v_genres text[] := '{}'; v_dates date[] := '{}';
  v_venue uuid; v_id uuid; x jsonb; v_draw text; v_email text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'the submission must be an object' USING ERRCODE = '22023';
  END IF;
  IF octet_length(p::text) > 16384 THEN
    RAISE EXCEPTION 'the submission is too large (16 KB at most)' USING ERRCODE = '22023';
  END IF;
  SELECT key INTO v_bad FROM jsonb_object_keys(p) key
   WHERE key NOT IN ('artist_name', 'contact_name', 'contact_role', 'email', 'phone', 'company', 'message', 'links',
                     'genres', 'venue_id', 'preferred_dates', 'dates_flexible', 'expected_draw', 'homepage')
   ORDER BY key LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'unknown field: %', left(v_bad, 60) USING ERRCODE = '22023';
  END IF;
  IF char_length(public._exos_fin_text(p, 'artist_name', 'artist_name', 150)) = 0 THEN
    RAISE EXCEPTION 'artist_name is required' USING ERRCODE = '22023';
  END IF;
  v_email := public._exos_fin_email(p ->> 'email', 'email');
  IF p_source = 'form' AND v_email IS NULL THEN
    RAISE EXCEPTION 'enter an email address so the venue can reply' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p ->> 'contact_role', 'other') NOT IN ('artist', 'agent', 'manager', 'promoter', 'other') THEN
    RAISE EXCEPTION 'contact_role must be artist, agent, manager, promoter or other' USING ERRCODE = '22023';
  END IF;
  IF p ? 'links' AND jsonb_typeof(p -> 'links') NOT IN ('object', 'null') THEN
    RAISE EXCEPTION 'links must be an object of https URLs' USING ERRCODE = '22023';
  END IF;
  FOR k, v IN SELECT key, value #>> '{}' FROM jsonb_each(coalesce(nullif(p -> 'links', 'null'::jsonb), '{}')) LOOP
    IF k NOT IN ('spotify', 'instagram', 'website', 'youtube', 'tiktok', 'bandcamp', 'soundcloud') THEN
      RAISE EXCEPTION 'links: unknown link %', left(k, 40) USING ERRCODE = '22023';
    END IF;
    IF nullif(btrim(coalesce(v, '')), '') IS NULL THEN CONTINUE; END IF;
    IF char_length(btrim(v)) > 300 OR btrim(v) !~ '^https://[^[:space:]<>"]{3,}$' THEN
      RAISE EXCEPTION 'links.% must be an https:// URL', k USING ERRCODE = '22023';
    END IF;
    v_links := v_links || jsonb_build_object(k, btrim(v));
  END LOOP;
  IF p ? 'genres' AND jsonb_typeof(p -> 'genres') = 'array' THEN
    IF jsonb_array_length(p -> 'genres') > 10 THEN RAISE EXCEPTION 'at most 10 genres' USING ERRCODE = '22023'; END IF;
    FOR x IN SELECT y FROM jsonb_array_elements(p -> 'genres') y LOOP
      IF jsonb_typeof(x) <> 'string' OR char_length(btrim(x #>> '{}')) NOT BETWEEN 1 AND 40 THEN
        RAISE EXCEPTION 'each genre is 1-40 characters' USING ERRCODE = '22023';
      END IF;
      v_genres := v_genres || btrim(x #>> '{}');
    END LOOP;
  ELSIF p ? 'genres' AND jsonb_typeof(p -> 'genres') <> 'null' THEN
    RAISE EXCEPTION 'genres must be a list' USING ERRCODE = '22023';
  END IF;
  IF p ? 'preferred_dates' AND jsonb_typeof(p -> 'preferred_dates') = 'array' THEN
    IF jsonb_array_length(p -> 'preferred_dates') > 10 THEN RAISE EXCEPTION 'at most 10 preferred dates' USING ERRCODE = '22023'; END IF;
    FOR x IN SELECT y FROM jsonb_array_elements(p -> 'preferred_dates') y LOOP
      v_dates := v_dates || public._exos_fin_date(jsonb_build_object('d', x), 'd', 'preferred_dates');
    END LOOP;
  ELSIF p ? 'preferred_dates' AND jsonb_typeof(p -> 'preferred_dates') <> 'null' THEN
    RAISE EXCEPTION 'preferred_dates must be a list of dates' USING ERRCODE = '22023';
  END IF;
  IF nullif(p ->> 'venue_id', '') IS NOT NULL THEN
    SELECT id INTO v_venue FROM public.exos_venues WHERE id::text = p ->> 'venue_id' AND org_id = p_org;
    IF v_venue IS NULL THEN RAISE EXCEPTION 'venue_id is not one of this organization''s venues' USING ERRCODE = '22023'; END IF;
  END IF;
  v_draw := nullif(p ->> 'expected_draw', '');
  IF v_draw IS NOT NULL AND (v_draw !~ '^[0-9]{1,7}$' OR v_draw::int > 1000000) THEN
    RAISE EXCEPTION 'expected_draw must be a whole number up to 1000000' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_inbound_submissions (org_id, source, artist_name, contact_name, contact_role, email, phone,
                                               company, message, links, genres, venue_id, preferred_dates,
                                               dates_flexible, expected_draw, ip_hash, user_agent, api_key_id)
  VALUES (p_org, p_source, public._exos_fin_text(p, 'artist_name', 'artist_name', 150),
          nullif(public._exos_fin_text(p, 'contact_name', 'contact_name', 100), ''),
          nullif(p ->> 'contact_role', ''), v_email,
          nullif(public._exos_fin_text(p, 'phone', 'phone', 40), ''),
          nullif(public._exos_fin_text(p, 'company', 'company', 100), ''),
          public._exos_fin_text(p, 'message', 'message', 5000), v_links, v_genres, v_venue, v_dates,
          coalesce((p ->> 'dates_flexible')::boolean, true), v_draw::int,
          CASE WHEN p_ip_hash ~ '^[0-9a-f]{64}$' THEN p_ip_hash END, left(p_ua, 300), p_api_key)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_inbound_create(uuid, text, jsonb, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_inbound_create(uuid, text, jsonb, text, text, uuid) TO service_role;

-- The public form's text (anon): an org whose form is ON. Nothing else.
CREATE OR REPLACE FUNCTION public.exos_inbound_form_public(p_org_slug text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
           'org_name', o.name, 'org_slug', o.slug,
           'title', coalesce(s.title, 'Book a show with ' || o.name), 'intro', s.intro,
           'venues', coalesce((SELECT jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name) ORDER BY v.name)
                                 FROM public.exos_venues v
                                WHERE v.org_id = o.id AND (cardinality(s.venue_ids) = 0 OR v.id = ANY (s.venue_ids))), '[]'::jsonb))
    FROM public.exos_orgs o JOIN public.exos_inbound_settings s ON s.org_id = o.id
   WHERE o.slug = p_org_slug AND s.enabled
$$;
REVOKE ALL ON FUNCTION public.exos_inbound_form_public(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_inbound_form_public(text) TO anon, authenticated, service_role;

-- The caller's IP as the platform saw it, for rate limits. Only headers the
-- platform sets are trusted; which ones is a deployment setting
-- (exos_platform_settings 'request_ip_source', docs/self-hosting.md):
--   cloudflare (default; hosted Supabase is behind Cloudflare, which
--              overwrites cf-connecting-ip): cf-connecting-ip, else the LAST
--              X-Forwarded-For entry;
--   xff_last   (self-hosted without Cloudflare, where a client could send
--              cf-connecting-ip itself): only the LAST X-Forwarded-For entry.
-- Never the first X-Forwarded-For entry: the client writes that one. NULL
-- when there is no valid address (callers then use a shared bucket).
-- Internal: no grants; definer RPCs call it.
CREATE OR REPLACE FUNCTION public._exos_request_ip_source()
RETURNS text LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT value #>> '{}' FROM public.exos_platform_settings
                    WHERE key = 'request_ip_source' AND jsonb_typeof(value) = 'string'
                      AND value #>> '{}' IN ('cloudflare', 'xff_last')), 'cloudflare')
$$;
REVOKE ALL ON FUNCTION public._exos_request_ip_source() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_request_ip()
RETURNS text LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE h jsonb; v text; parts text[];
BEGIN
  BEGIN
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN others THEN RETURN NULL;
  END;
  IF h IS NULL OR jsonb_typeof(h) <> 'object' THEN RETURN NULL; END IF;
  IF public._exos_request_ip_source() = 'cloudflare' THEN
    v := nullif(btrim(coalesce(h ->> 'cf-connecting-ip', '')), '');
  END IF;
  IF v IS NULL THEN
    parts := string_to_array(coalesce(h ->> 'x-forwarded-for', ''), ',');
    IF cardinality(parts) > 0 THEN v := nullif(btrim(parts[cardinality(parts)]), ''); END IF;
  END IF;
  IF v IS NULL OR char_length(v) > 45 THEN RETURN NULL; END IF;
  BEGIN
    RETURN host(v::inet);
  EXCEPTION WHEN others THEN RETURN NULL;
  END;
END $$;
REVOKE ALL ON FUNCTION public._exos_request_ip() FROM PUBLIC, anon, authenticated;

-- The rate-limit bucket of the caller's network: an IPv4 address as is, an
-- IPv6 address as its /64 (one client can rotate addresses inside it);
-- 'unknown' without a trusted IP. Internal: no grants.
CREATE OR REPLACE FUNCTION public._exos_request_ip_bucket()
RETURNS text LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v text := public._exos_request_ip(); i inet;
BEGIN
  IF v IS NULL THEN RETURN 'unknown'; END IF;
  i := v::inet;
  IF family(i) = 6 THEN RETURN network(set_masklen(i, 64))::text; END IF;
  RETURN host(i);
END $$;
REVOKE ALL ON FUNCTION public._exos_request_ip_bucket() FROM PUBLIC, anon, authenticated;

-- The public submission (anon). Always { ok: true } once accepted (also for
-- a honeypot hit, which stores nothing). Limits: 16 KB body; per network 5 an
-- hour per org and 20 a day across orgs; per email 3 a day per org; 300 a day
-- per org. Over a limit: 54000 (the form says "try again later").
CREATE OR REPLACE FUNCTION public.exos_inbound_submit(p_org_slug text, p_submission jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org     uuid;
  v_headers jsonb;
  v_ip      text;
  v_hash    text;
  v_email   text;
  v_ua      text;
BEGIN
  IF p_submission IS NULL OR jsonb_typeof(p_submission) <> 'object' OR octet_length(p_submission::text) > 16384 THEN
    RAISE EXCEPTION 'the submission is missing or too large (16 KB at most)' USING ERRCODE = '22023';
  END IF;
  SELECT o.id INTO v_org FROM public.exos_orgs o JOIN public.exos_inbound_settings s ON s.org_id = o.id
   WHERE o.slug = p_org_slug AND s.enabled;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'this organization isn''t taking booking requests' USING ERRCODE = 'P0002';
  END IF;
  -- Honeypot: a hidden field people never see. Answer as if accepted.
  IF nullif(btrim(coalesce(p_submission ->> 'homepage', '')), '') IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true);
  END IF;
  BEGIN
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN others THEN v_headers := NULL;
  END;
  -- IPv4 as is, IPv6 by /64; no trusted IP: one shared "unknown" bucket with
  -- the same caps (never no limit).
  v_ip := public._exos_request_ip_bucket();
  v_ua := v_headers ->> 'user-agent';
  v_hash := encode(sha256(convert_to('exos-inbound:' || v_ip, 'UTF8')), 'hex');
  v_email := lower(btrim(coalesce(p_submission ->> 'email', '')));

  -- Count-then-insert under locks, so parallel requests can't slip past.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_inbound:org:' || v_org::text, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_inbound:ip:' || v_hash, 0));
  IF (SELECT count(*) FROM public.exos_inbound_submissions
       WHERE ip_hash = v_hash AND org_id = v_org AND created_at > now() - interval '1 hour') >= 5
     OR (SELECT count(*) FROM public.exos_inbound_submissions
          WHERE ip_hash = v_hash AND created_at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION 'too many requests from this network; try again later' USING ERRCODE = '54000';
  END IF;
  IF v_email <> '' AND (SELECT count(*) FROM public.exos_inbound_submissions
                         WHERE org_id = v_org AND email = v_email AND created_at > now() - interval '1 day') >= 3 THEN
    RAISE EXCEPTION 'too many requests from this email address today; try again tomorrow' USING ERRCODE = '54000';
  END IF;
  IF (SELECT count(*) FROM public.exos_inbound_submissions
       WHERE org_id = v_org AND source = 'form' AND created_at > now() - interval '1 day') >= 300 THEN
    RAISE EXCEPTION 'this organization has had too many requests today; try again tomorrow' USING ERRCODE = '54000';
  END IF;
  PERFORM public._exos_inbound_create(v_org, 'form', p_submission - 'homepage', v_hash, v_ua, NULL);
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_inbound_submit(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_inbound_submit(text, jsonb) TO anon, authenticated, service_role;

-- Review: new / reviewing / accepted / declined, with a staff note.
CREATE OR REPLACE FUNCTION public._exos_inbound_set_status(p_org uuid, p_actor uuid, p_id uuid, p_status text,
                                                           p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_inbound_submissions%ROWTYPE;
BEGIN
  IF p_status IS NOT NULL AND p_status NOT IN ('new', 'reviewing', 'accepted', 'declined') THEN
    RAISE EXCEPTION 'status must be new, reviewing, accepted or declined' USING ERRCODE = '22023';
  END IF;
  IF p_note IS NOT NULL AND char_length(p_note) > 2000 THEN
    RAISE EXCEPTION 'staff_note is at most 2000 characters' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_inbound_submissions
     SET status = coalesce(p_status, status), staff_note = coalesce(p_note, staff_note),
         reviewed_by = CASE WHEN p_status IS NOT NULL THEN p_actor ELSE reviewed_by END,
         reviewed_at = CASE WHEN p_status IS NOT NULL THEN now() ELSE reviewed_at END
   WHERE id = p_id AND org_id = p_org
  RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'submission not found' USING ERRCODE = 'P0002'; END IF;
  RETURN to_jsonb(r) - 'org_id' - 'ip_hash' - 'user_agent' - 'api_key_id';
END $$;
REVOKE ALL ON FUNCTION public._exos_inbound_set_status(uuid, uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_inbound_set_status(uuid, uuid, uuid, text, text) TO service_role;

-- A hold from a submission: p is the hold body (_exos_hold_create: positions
-- required; title defaults to the artist, notes to the message). Marks the
-- submission accepted and links the hold. Once only.
CREATE OR REPLACE FUNCTION public._exos_inbound_hold(p_org uuid, p_actor uuid, p_via text, p_api_key uuid,
                                                     p_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_inbound_submissions%ROWTYPE; b jsonb := coalesce(p, '{}'::jsonb); v_hold jsonb;
BEGIN
  SELECT * INTO r FROM public.exos_inbound_submissions WHERE id = p_id AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'submission not found' USING ERRCODE = 'P0002'; END IF;
  IF r.hold_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_holds WHERE id = r.hold_id) THEN
    RAISE EXCEPTION 'this submission already has a hold' USING ERRCODE = '55000';
  END IF;
  IF jsonb_typeof(b) <> 'object' THEN RAISE EXCEPTION 'the body must be an object' USING ERRCODE = '22023'; END IF;
  IF NOT b ? 'title' THEN b := b || jsonb_build_object('title', left(r.artist_name, 100)); END IF;
  IF NOT b ? 'notes' AND r.message <> '' THEN b := b || jsonb_build_object('notes', left(r.message, 2000)); END IF;
  v_hold := public._exos_hold_create(p_org, p_actor, p_via, p_api_key, b);
  UPDATE public.exos_inbound_submissions
     SET hold_id = (v_hold ->> 'id')::uuid, status = 'accepted', reviewed_by = coalesce(p_actor, reviewed_by), reviewed_at = now()
   WHERE id = p_id;
  RETURN jsonb_build_object('submission_id', p_id, 'hold', v_hold);
END $$;
REVOKE ALL ON FUNCTION public._exos_inbound_hold(uuid, uuid, text, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_inbound_hold(uuid, uuid, text, uuid, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_inbound_set_status(p_id uuid, p_status text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_inbound_submissions WHERE id = p_id);
BEGIN
  IF v_org IS NULL THEN RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501'; END IF;
  PERFORM public._exos_fin_staff(v_org, ARRAY['owner', 'manager', 'content']);
  RETURN public._exos_inbound_set_status(v_org, auth.uid(), p_id, p_status, p_note);
END $$;
REVOKE ALL ON FUNCTION public.exos_inbound_set_status(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_inbound_set_status(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_inbound_create_hold(p_id uuid, p_hold jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_inbound_submissions WHERE id = p_id);
BEGIN
  IF v_org IS NULL THEN RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501'; END IF;
  PERFORM public._exos_fin_staff(v_org, ARRAY['owner', 'manager']);
  RETURN public._exos_inbound_hold(v_org, auth.uid(), 'dashboard', NULL, p_id, p_hold);
END $$;
REVOKE ALL ON FUNCTION public.exos_inbound_create_hold(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_inbound_create_hold(uuid, jsonb) TO authenticated;

-- ===========================================================================
-- 5. Deleting an event (drafts with nothing sold)
-- ===========================================================================
-- An event that never sold may be deleted outright; anything with orders,
-- tickets, reservations, payments or invoices must be cancelled instead
-- (cancelling keeps the record and notifies holders). Published events are
-- unpublished first. 55000 says which.
CREATE OR REPLACE FUNCTION public._exos_event_delete(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e  public.exos_events%ROWTYPE;
  t  text;
  v  boolean;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002'; END IF;
  IF e.status = 'published' THEN
    RAISE EXCEPTION 'the event is published: unpublish it first (or cancel it, which keeps it on record)' USING ERRCODE = '55000';
  END IF;
  IF coalesce(e.tickets_sold, 0) > 0 THEN
    RAISE EXCEPTION 'the event has sold tickets: cancel it instead' USING ERRCODE = '55000';
  END IF;
  -- Anything that is an order, a ticket or money, where it exists here.
  FOREACH t IN ARRAY ARRAY['exos_tickets', 'exos_checkout_sessions', 'exos_invoices', 'exos_order_payments',
                           'exos_refund_requests', 'exos_disputes', 'exos_marketplace_orders', 'exos_posh_orders',
                           'exos_pos_orders', 'exos_partner_reservations', 'exos_order_addons', 'exos_table_bookings',
                           'exos_eventbrite_attendees', 'exos_sales_counts'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL AND EXISTS (
         SELECT 1 FROM pg_attribute WHERE attrelid = ('public.' || t)::regclass AND attname = 'event_id' AND NOT attisdropped) THEN
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE event_id = $1)', t) INTO v USING p_event;
      IF v THEN
        RAISE EXCEPTION 'the event has orders, tickets or payments (%): cancel it instead', replace(replace(t, 'exos_', ''), '_', ' ')
          USING ERRCODE = '55000';
      END IF;
    END IF;
  END LOOP;
  BEGIN
    DELETE FROM public.exos_events WHERE id = p_event;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'other records still point at this event: cancel it instead' USING ERRCODE = '55000';
  END;
  RETURN jsonb_build_object('id', p_event, 'deleted', true);
END $$;
REVOKE ALL ON FUNCTION public._exos_event_delete(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_delete(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_event_delete(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_events WHERE id = p_event_id);
BEGIN
  IF v_org IS NULL THEN RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501'; END IF;
  PERFORM public._exos_fin_staff(v_org, ARRAY['owner', 'manager']);
  RETURN public._exos_event_delete(v_org, p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_delete(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_delete(uuid) TO authenticated;

-- ===========================================================================
-- 6. updated_at, RLS, grants
--    Event templates:   read owner / manager / content / finance; write owner / manager.
--    Note templates:    read owner / manager / content / finance; write owner / manager / content.
--    Rental templates:  read owner / manager / finance; write owner / manager.
--    Rental invoices + counters: read owner / manager / finance; written only
--                       through the functions above (numbering).
--    Inbound settings:  read owner / manager / content; write owner / manager.
--    Inbound submissions: read owner / manager / content; delete owner /
--                       manager; status and holds through the functions.
--    Nothing for anon or scanners.
-- ===========================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_event_templates', 'exos_note_templates', 'exos_rental_invoice_templates',
                           'exos_rental_invoice_counters', 'exos_rental_invoices', 'exos_inbound_settings',
                           'exos_inbound_submissions'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I
                      FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated;', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role;', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_sel', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_write', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_del', t);
  END LOOP;
END $$;

CREATE POLICY exos_event_templates_sel ON public.exos_event_templates FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance']));
CREATE POLICY exos_event_templates_write ON public.exos_event_templates FOR ALL TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']))
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
GRANT INSERT, UPDATE, DELETE ON public.exos_event_templates TO authenticated;

CREATE POLICY exos_note_templates_sel ON public.exos_note_templates FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance']));
CREATE POLICY exos_note_templates_write ON public.exos_note_templates FOR ALL TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']))
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']));
GRANT INSERT, UPDATE, DELETE ON public.exos_note_templates TO authenticated;

CREATE POLICY exos_rental_invoice_templates_sel ON public.exos_rental_invoice_templates FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
CREATE POLICY exos_rental_invoice_templates_write ON public.exos_rental_invoice_templates FOR ALL TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']))
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
GRANT INSERT, UPDATE, DELETE ON public.exos_rental_invoice_templates TO authenticated;

CREATE POLICY exos_rental_invoice_counters_sel ON public.exos_rental_invoice_counters FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
CREATE POLICY exos_rental_invoices_sel ON public.exos_rental_invoices FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));

CREATE POLICY exos_inbound_settings_sel ON public.exos_inbound_settings FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']));
CREATE POLICY exos_inbound_settings_write ON public.exos_inbound_settings FOR ALL TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']))
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
GRANT INSERT, UPDATE ON public.exos_inbound_settings TO authenticated;

CREATE POLICY exos_inbound_submissions_sel ON public.exos_inbound_submissions FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']));
CREATE POLICY exos_inbound_submissions_del ON public.exos_inbound_submissions FOR DELETE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
GRANT DELETE ON public.exos_inbound_submissions TO authenticated;
-- The network hash is the limiter's, not the dashboard's.
REVOKE SELECT ON public.exos_inbound_submissions FROM authenticated;
GRANT SELECT (id, org_id, status, source, artist_name, contact_name, contact_role, email, phone, company, message,
              links, genres, venue_id, preferred_dates, dates_flexible, expected_draw, hold_id, staff_note,
              reviewed_by, reviewed_at, created_at, updated_at)
  ON public.exos_inbound_submissions TO authenticated;

DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_event_templates', 'exos_note_templates', 'exos_rental_invoice_templates',
                               'exos_rental_invoice_counters', 'exos_rental_invoices', 'exos_inbound_settings',
                               'exos_inbound_submissions'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

COMMENT ON TABLE public.exos_event_templates IS
  'mig 20261102130000: saved event setups; exos_event_from_template makes a draft event from one.';
COMMENT ON TABLE public.exos_rental_invoices IS
  'mig 20261102130000: venue rental invoices. Numbered on issue from exos_rental_invoice_counters (gapless per org); issued ones are frozen and never deleted.';
COMMENT ON TABLE public.exos_inbound_submissions IS
  'mig 20261102130000: booking requests from outside (exos_inbound_submit, anon, rate limited; or the API).';
