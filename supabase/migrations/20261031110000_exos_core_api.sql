-- ============================================================================
-- Migration 20261031110000 — Exos: the core partner API (writes) and publish
-- blockers
--
-- Touches:  C: TABLE exos_api_writes (new: the API's write log + idempotency)
--              FUNCTION exos_api_scope_names (replaced: + refunds:write)
--              FUNCTION _exos_event_publish_blockers, exos_event_publish_blockers,
--                       exos_publish_event (new)
--              FUNCTION _exos_api_has_scope, _exos_api_action_scope,
--                       _exos_api_uuid, _exos_api_event_of, _exos_api_columns,
--                       _exos_api_field_keys, _exos_api_insert, _exos_api_update,
--                       _exos_api_event_json, exos_api_write (new)
--           R: exos_api_keys, exos_org_memberships, exos_events,
--              exos_ticket_tiers, exos_event_addons, exos_vouchers,
--              exos_checkout_sessions, exos_tickets, exos_guest_lists,
--              exos_guest_list_entries, exos_pos_items, exos_org_secrets
--           Calls (unchanged): exos_issue_voucher, exos_issue_comp_batch,
--              exos_refund_claim, exos_refund_preview, exos_check_in_ticket,
--              exos_undo_check_in, exos_check_in_offline, exos_upsert_guest_list,
--              exos_delete_guest_list, exos_add_guest, exos_update_guest,
--              exos_remove_guest, exos_guest_check_in, exos_occurs_at_local
-- Pre-reqs: 20261027090000 (API scopes), 20260926040000 (refund claim),
--           20260926050000 (guest lists), 20260929140000 (door lists: latest
--           check-in functions), 20260929074000 (POS items)
--
-- The partner API (exos-api, docs/api-reference.md) gets write routes over
-- what the dashboard already does. Rule: a write over the API behaves exactly
-- like the same write in the dashboard. So every write goes through ONE
-- service-role function, exos_api_write(key, action, target, args, idem key),
-- which:
--   1. loads the API key (not revoked) and its org;
--   2. runs as the member who created the key: it sets the request's JWT
--      claims (sub / role / email) to that member for the rest of this
--      transaction, the way PostgREST does for a signed-in request, so
--      auth.uid() inside the existing RPCs is that member and their CURRENT
--      role in the org decides (exos_has_org_role). A key whose creator left
--      the org, or was disabled, can't write. Platform-admin status of the
--      creator never reaches another org: step 3 pins every target to the
--      key's org first;
--   3. checks the target (event, ticket type, order, ticket, list, ...)
--      belongs to the key's org (else 'not found', so ids can't be probed);
--   4. calls the dashboard's own RPC (refunds, comps, promo codes, check-ins,
--      guest lists), or, where the dashboard writes a table under RLS (events,
--      ticket types, add-ons, POS items), checks the same roles as the RLS
--      policy (owner / manager) and writes the whitelisted columns. Table
--      triggers (webhooks, mail, channel sync, date guard, ...) fire as usual;
--   5. logs the write in exos_api_writes (who, which key, what, target, the
--      answer). EXP has no general audit log; this is the API's, and the money
--      routes (refunds, comps) are flagged money_moving.
-- The key's scope is checked by the edge function per route AND again here
-- per action (_exos_api_action_scope), so a mis-wired route can't widen a key.
--
-- Idempotency: an Idempotency-Key (8-100 of A-Z a-z 0-9 _ . : -) is unique per
-- API key. The first request with it inserts the log row before doing the
-- work, so a concurrent duplicate waits on the unique index and then replays
-- the stored answer; a later duplicate replays it too. The same key on another
-- action or target is refused (22023). Refunds REQUIRE one (the edge function
-- enforces it): it becomes the refund request's nonce
-- (api:<key id>:<idem key>), so exos_refund_claim hands back the same request
-- and the Stripe idempotency key stays exos_refund_<request id>.
--
-- Publish blockers: what stops an event from going live (no name, no date, a
-- date in the past, no venue for an in-person event, no ticket types, paid
-- tickets without a connected Stripe account, ...). exos_publish_event
-- refuses while there are any; the dashboard's publish button and the API's
-- POST /events/:id/publish both call it.
--
-- Scopes: refunds:write (new) is the only scope that can refund. Comps stay
-- under tickets:write (vocabulary from the Firebase build).
--
-- Additive: one new table, new functions, one replaced function (the scope
-- vocabulary). Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- 1. Scope vocabulary: + refunds:write ---------------------------------------
-- Must equal SCOPES in supabase/functions/_shared/api/scopes.ts
-- (src/lib/apiScopes.test.ts reads the latest definition).
CREATE OR REPLACE FUNCTION public.exos_api_scope_names()
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY[
    'events:read', 'events:write', 'orders:read', 'refunds:write', 'tickets:read', 'tickets:write',
    'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
    'commerce:read', 'commerce:write', 'webhooks:read', 'webhooks:write', 'org:admin'
  ]::text[]
$$;
REVOKE ALL ON FUNCTION public.exos_api_scope_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_api_scope_names() TO authenticated, service_role;

-- 2. The API's write log --------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_api_writes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  api_key_id      uuid REFERENCES public.exos_api_keys (id) ON DELETE SET NULL,
  actor           uuid,                       -- the key's creator the write ran as
  action          text NOT NULL CHECK (action ~ '^[a-z_]{2,40}\.[a-z_]{2,40}$'),
  target          text CHECK (target IS NULL OR length(target) <= 255),
  idempotency_key text CHECK (idempotency_key IS NULL OR idempotency_key ~ '^[A-Za-z0-9_.:-]{8,100}$'),
  money_moving    boolean NOT NULL DEFAULT false,
  result          jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_api_writes_idem_uq
  ON public.exos_api_writes (api_key_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_api_writes_org_idx ON public.exos_api_writes (org_id, created_at DESC);

DROP TRIGGER IF EXISTS exos_api_writes_touch ON public.exos_api_writes;
CREATE TRIGGER exos_api_writes_touch BEFORE UPDATE ON public.exos_api_writes
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_api_writes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_api_writes_sel ON public.exos_api_writes;
CREATE POLICY exos_api_writes_sel ON public.exos_api_writes FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
REVOKE ALL ON public.exos_api_writes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_api_writes TO authenticated;
GRANT ALL ON public.exos_api_writes TO service_role;

-- 3. Publish blockers -----------------------------------------------------------
-- [{ code, field, message }] for everything that stops the event going live.
-- Empty = publishable. Internal (no role check); the wrappers below check.
CREATE OR REPLACE FUNCTION public._exos_event_publish_blockers(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  v_out    jsonb := '[]'::jsonb;
  v_tiers  int;
  v_paid   boolean;
  v_pay    jsonb;
  v_fmt    text;
  v_back   text;
  v_tz_ok  boolean;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_array(jsonb_build_object('code', 'not_found', 'field', null, 'message', 'Event not found.'));
  END IF;
  -- Columns from later migrations, read through jsonb so this works on any
  -- schema the harness builds (format: online events, ticket_backend: sold elsewhere).
  v_fmt  := coalesce(to_jsonb(e) ->> 'format', 'in_person');
  v_back := coalesce(to_jsonb(e) ->> 'ticket_backend', 'exos');

  IF e.status = 'cancelled' THEN
    v_out := v_out || jsonb_build_object('code', 'event_cancelled', 'field', 'status',
      'message', 'The event is cancelled; a cancelled event can''t go live again.');
  END IF;
  IF btrim(coalesce(e.name, '')) = '' THEN
    v_out := v_out || jsonb_build_object('code', 'missing_name', 'field', 'name', 'message', 'Add a name.');
  END IF;
  IF e.starts_at IS NULL THEN
    v_out := v_out || jsonb_build_object('code', 'missing_start', 'field', 'starts_at', 'message', 'Add a start date and time.');
  ELSIF e.status <> 'published' AND e.starts_at < now() THEN
    v_out := v_out || jsonb_build_object('code', 'starts_in_past', 'field', 'starts_at', 'message', 'The start date is in the past.');
  END IF;
  IF e.starts_at IS NOT NULL AND e.ends_at IS NOT NULL AND e.ends_at <= e.starts_at THEN
    v_out := v_out || jsonb_build_object('code', 'ends_before_start', 'field', 'ends_at', 'message', 'The event ends before it starts.');
  END IF;
  IF e.starts_at IS NOT NULL AND e.doors_at IS NOT NULL AND e.doors_at > e.starts_at THEN
    v_out := v_out || jsonb_build_object('code', 'doors_after_start', 'field', 'doors_at', 'message', 'Doors open after the start time.');
  END IF;
  v_tz_ok := e.timezone IS NOT NULL AND EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = e.timezone);
  IF NOT v_tz_ok THEN
    v_out := v_out || jsonb_build_object('code', 'missing_timezone', 'field', 'timezone', 'message', 'Pick the event''s time zone.');
  END IF;
  IF v_fmt <> 'online' AND btrim(coalesce(e.venue_name, '')) = '' AND btrim(coalesce(e.venue_location, '')) = '' THEN
    v_out := v_out || jsonb_build_object('code', 'missing_venue', 'field', 'venue_name', 'message', 'Add a venue (or make the event online).');
  END IF;

  -- Tickets sold on Exos need ticket types, and paid ones a payout account.
  IF v_back = 'exos' THEN
    SELECT count(*), coalesce(bool_or(t.price > 0 AND coalesce(t.ticket_type, 'paid') <> 'free'), false)
      INTO v_tiers, v_paid
      FROM public.exos_ticket_tiers t WHERE t.event_id = e.id;
    IF v_tiers = 0 THEN
      v_out := v_out || jsonb_build_object('code', 'no_ticket_types', 'field', 'ticket_types', 'message', 'Add at least one ticket type.');
    END IF;
    IF v_paid THEN
      -- exos_org_secrets (phase 1; what exos-checkout reads): dynamic, so the
      -- function also compiles on a schema without it (no table = not connected).
      IF to_regclass('public.exos_org_secrets') IS NOT NULL THEN
        EXECUTE 'SELECT payments FROM public.exos_org_secrets WHERE org_id = $1' INTO v_pay USING e.org_id;
      END IF;
      IF coalesce(v_pay ->> 'connectedAccountId', '') = '' OR coalesce((v_pay ->> 'chargesEnabled')::boolean, false) IS NOT TRUE THEN
        v_out := v_out || jsonb_build_object('code', 'stripe_not_connected', 'field', null,
          'message', 'Paid tickets need a connected Stripe account that can take payments (Org settings → Payouts).');
      END IF;
    END IF;
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_publish_blockers(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_publish_blockers(uuid) TO service_role;

-- The dashboard's read: org staff who edit events (owner / manager / content).
CREATE OR REPLACE FUNCTION public.exos_event_publish_blockers(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'content'])) THEN
    RAISE EXCEPTION 'exos_event_publish_blockers: event not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN public._exos_event_publish_blockers(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_publish_blockers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_publish_blockers(uuid) TO authenticated, service_role;

-- Publish: owner / manager (the exos_events_upd policy's roles), only with no
-- blockers. Already published: a no-op. The event row lock makes the check
-- and the update one step.
CREATE OR REPLACE FUNCTION public.exos_publish_event(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e         public.exos_events%ROWTYPE;
  v_block   jsonb;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF auth.uid() IS NULL OR NOT FOUND
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'finance', 'scanner', 'content'])) THEN
    RAISE EXCEPTION 'exos_publish_event: event not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_publish_event: only an owner or manager can publish' USING ERRCODE = '42501';
  END IF;
  IF e.status = 'published' THEN
    RETURN jsonb_build_object('event_id', e.id, 'status', 'published', 'published', true, 'blockers', '[]'::jsonb);
  END IF;
  v_block := public._exos_event_publish_blockers(p_event_id);
  IF jsonb_array_length(v_block) > 0 THEN
    RETURN jsonb_build_object('event_id', e.id, 'status', e.status, 'published', false, 'blockers', v_block);
  END IF;
  UPDATE public.exos_events SET status = 'published' WHERE id = p_event_id;
  RETURN jsonb_build_object('event_id', e.id, 'status', 'published', 'published', true, 'blockers', '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_publish_event(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_publish_event(uuid) TO authenticated, service_role;

-- 4. Internal helpers for exos_api_write -------------------------------------------
-- Not callable by any client role, service_role included: only exos_api_write
-- (their owner) runs them.

-- `granted` covers `needed`: the same rule as hasScope() in _shared/api/scopes.ts.
CREATE OR REPLACE FUNCTION public._exos_api_has_scope(p_granted text[], p_needed text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT p_needed = ANY (coalesce(p_granted, '{}'))
      OR (p_needed LIKE '%:read'
          AND ('read' = ANY (coalesce(p_granted, '{}'))
               OR regexp_replace(p_needed, ':read$', ':write') = ANY (coalesce(p_granted, '{}'))))
$$;
REVOKE ALL ON FUNCTION public._exos_api_has_scope(text[], text) FROM PUBLIC, anon, authenticated;

-- The scope each action needs (mirrors the route table, _shared/api/routes.ts).
CREATE OR REPLACE FUNCTION public._exos_api_action_scope(p_action text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p_action IN ('event.create', 'event.update', 'event.publish', 'event.unpublish',
                      'ticket_type.create', 'ticket_type.update', 'ticket_type.delete',
                      'add_on.create', 'add_on.update', 'add_on.delete',
                      'promo_code.create', 'promo_code.update', 'promo_code.delete',
                      'pos_item.create', 'pos_item.update') THEN 'events:write'
    WHEN p_action = 'refund.claim' THEN 'refunds:write'
    WHEN p_action = 'refund.preview' THEN 'orders:read'
    WHEN p_action IN ('comp.issue', 'guest_list.create', 'guest_list.update', 'guest_list.delete',
                      'guest.add', 'guest.update', 'guest.remove') THEN 'tickets:write'
    WHEN p_action IN ('ticket.check_in', 'ticket.undo_check_in', 'order.check_in',
                      'event.offline_check_ins', 'guest.check_in') THEN 'checkin:write'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_api_action_scope(text) FROM PUBLIC, anon, authenticated;

-- A path id as a uuid; anything else is simply not found.
CREATE OR REPLACE FUNCTION public._exos_api_uuid(p_text text, p_what text)
RETURNS uuid
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN p_text::uuid;
  END IF;
  RAISE EXCEPTION 'exos_api_write: % not found', p_what USING ERRCODE = 'P0002';
END $$;
REVOKE ALL ON FUNCTION public._exos_api_uuid(text, text) FROM PUBLIC, anon, authenticated;

-- The event `p_text` when it is one of `p_org`'s; else not found.
CREATE OR REPLACE FUNCTION public._exos_api_event_of(p_org uuid, p_text text)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid := public._exos_api_uuid(p_text, 'event');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = v_id AND org_id = p_org) THEN
    RAISE EXCEPTION 'exos_api_write: event not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_event_of(uuid, text) FROM PUBLIC, anon, authenticated;

-- The columns of `p_table` from `p_allowed` that exist on this schema.
CREATE OR REPLACE FUNCTION public._exos_api_columns(p_table regclass, p_allowed text[])
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(array_agg(a.attname::text ORDER BY a.attnum), '{}')
    FROM pg_attribute a
   WHERE a.attrelid = p_table AND a.attnum > 0 AND NOT a.attisdropped
     AND a.attname::text = ANY (p_allowed)
$$;
REVOKE ALL ON FUNCTION public._exos_api_columns(regclass, text[]) FROM PUBLIC, anon, authenticated;

-- The keys of `p_fields` checked against the writable columns (unknown or
-- read-only keys are refused, so a typo never silently does nothing).
CREATE OR REPLACE FUNCTION public._exos_api_field_keys(p_table regclass, p_allowed text[], p_fields jsonb)
RETURNS text[]
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_cols text[] := public._exos_api_columns(p_table, p_allowed); v_bad text; v_keys text[];
BEGIN
  IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN
    RAISE EXCEPTION 'the fields must be a JSON object' USING ERRCODE = '22023';
  END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(p_fields) k WHERE NOT (k = ANY (v_cols)) ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'unknown or read-only field: %', left(v_bad, 60) USING ERRCODE = '22023';
  END IF;
  SELECT coalesce(array_agg(k ORDER BY k), '{}') INTO v_keys FROM jsonb_object_keys(p_fields) k;
  RETURN v_keys;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_field_keys(regclass, text[], jsonb) FROM PUBLIC, anon, authenticated;

-- INSERT the allowed `p_fields` plus the server-set `p_fixed` (org, event,
-- creator) into `p_table`; values are cast by the column types
-- (jsonb_populate_record), so a bad value is a 22P02-style error. Returns the id.
CREATE OR REPLACE FUNCTION public._exos_api_insert(p_table regclass, p_allowed text[], p_fields jsonb, p_fixed jsonb)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_keys text[] := public._exos_api_field_keys(p_table, p_allowed, p_fields);
  v_all  text[];
  v_id   uuid;
BEGIN
  SELECT array_agg(DISTINCT k ORDER BY k) INTO v_all
    FROM unnest(v_keys || ARRAY(SELECT jsonb_object_keys(coalesce(p_fixed, '{}'::jsonb)))) k;
  EXECUTE format('INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_record(NULL::%s, $1) r RETURNING id',
                 p_table,
                 (SELECT string_agg(quote_ident(c), ', ') FROM unnest(v_all) c),
                 (SELECT string_agg('r.' || quote_ident(c), ', ') FROM unnest(v_all) c),
                 p_table)
    INTO v_id USING (p_fields || coalesce(p_fixed, '{}'::jsonb));
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_insert(regclass, text[], jsonb, jsonb) FROM PUBLIC, anon, authenticated;

-- UPDATE the allowed `p_fields` of one row. Nothing to change: a no-op.
CREATE OR REPLACE FUNCTION public._exos_api_update(p_table regclass, p_id uuid, p_allowed text[], p_fields jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_keys text[] := public._exos_api_field_keys(p_table, p_allowed, p_fields);
BEGIN
  IF cardinality(v_keys) = 0 THEN RETURN; END IF;
  EXECUTE format('UPDATE %s t SET (%s) = (SELECT %s FROM jsonb_populate_record(NULL::%s, $1) r) WHERE t.id = $2',
                 p_table,
                 (SELECT string_agg(quote_ident(c), ', ') FROM unnest(v_keys) c),
                 (SELECT string_agg('r.' || quote_ident(c), ', ') FROM unnest(v_keys) c),
                 p_table)
    USING p_fields, p_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_update(regclass, uuid, text[], jsonb) FROM PUBLIC, anon, authenticated;

-- An event as the API shows it (the GET /events/:id columns, its ticket types
-- and its publish blockers).
CREATE OR REPLACE FUNCTION public._exos_api_event_json(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', e.id, 'name', e.name, 'slug', e.slug, 'status', e.status, 'starts_at', e.starts_at,
    'doors_at', e.doors_at, 'ends_at', e.ends_at, 'timezone', e.timezone, 'currency', e.currency,
    'venue_name', e.venue_name, 'venue_location', e.venue_location,
    'tickets_sold', e.tickets_sold, 'total_tickets', e.total_tickets, 'created_at', e.created_at,
    'tiers', coalesce((SELECT jsonb_agg(jsonb_build_object(
                 'id', t.id, 'name', t.name, 'description', t.description, 'price', t.price,
                 'capacity', t.capacity, 'sold', t.sold, 'ticket_type', t.ticket_type,
                 'visibility', t.visibility, 'sales_start', t.sales_start, 'sales_end', t.sales_end,
                 'sort_order', t.sort_order) ORDER BY t.sort_order, t.id)
               FROM public.exos_ticket_tiers t WHERE t.event_id = e.id), '[]'::jsonb),
    'publish_blockers', public._exos_event_publish_blockers(e.id))
  FROM public.exos_events e WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_api_event_json(uuid) FROM PUBLIC, anon, authenticated;

-- 5. exos_api_write: every partner-API write -----------------------------------------
CREATE OR REPLACE FUNCTION public.exos_api_write(
  p_key_id          uuid,
  p_action          text,
  p_target          text  DEFAULT NULL,
  p_args            jsonb DEFAULT '{}'::jsonb,
  p_idempotency_key text  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  k          public.exos_api_keys%ROWTYPE;
  v_org      uuid;
  v_actor    uuid;
  v_email    text;
  v_scope    text;
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  v_log      uuid;
  v_prev     public.exos_api_writes%ROWTYPE;
  v_out      jsonb;
  v_id       uuid;
  v_uuid     uuid;
  v_event    uuid;
  v_ev       public.exos_events%ROWTYPE;
  v_tmp      jsonb;
  v_rows     jsonb;
  v_item     jsonb;
  v_res      jsonb;
  v_n        int;
  v_money    boolean := p_action IN ('refund.claim', 'comp.issue');
  v_was      jsonb;
  -- What a caller may set (server-owned columns are never in these lists).
  c_event   CONSTANT text[] := ARRAY['name', 'description', 'slug', 'starts_at', 'doors_at', 'ends_at',
    'timezone', 'currency', 'venue_name', 'venue_location', 'venue_address', 'primary_performer_name',
    'performer_names', 'category', 'genres', 'subgenres', 'image_url', 'total_tickets', 'purchase_limits',
    'summary', 'description_md', 'faq', 'video_url', 'min_age', 'refund_policy', 'policy_notes', 'format',
    'what_to_bring', 'noindex', 'allow_holder_release', 'release_cutoff_hours', 'accessibility',
    'door_name_checkin'];
  c_tier    CONSTANT text[] := ARRAY['name', 'description', 'price', 'capacity', 'ticket_type', 'visibility',
    'sales_start', 'sales_end', 'sort_order', 'price_schedule', 'accessible', 'accessible_note', 'market_split'];
  c_addon   CONSTANT text[] := ARRAY['name', 'description', 'price', 'capacity', 'max_per_order', 'visibility',
    'image_url', 'sort_order'];
  c_voucher CONSTANT text[] := ARRAY['max_uses', 'valid_until', 'comment', 'link_label'];
  c_pos     CONSTANT text[] := ARRAY['event_id', 'category', 'name', 'sku', 'price_cents', 'tax_rule_id',
    'tier_id', 'active', 'is_86d', 'inventory_count', 'sort_order'];
  c_staff   CONSTANT text[] := ARRAY['owner', 'manager'];
BEGIN
  -- 1. The key and its org.
  SELECT * INTO k FROM public.exos_api_keys WHERE id = p_key_id AND revoked_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_api_write: invalid or revoked API key' USING ERRCODE = '42501';
  END IF;
  v_org := k.org_id;
  v_scope := public._exos_api_action_scope(p_action);
  IF v_scope IS NULL THEN
    RAISE EXCEPTION 'exos_api_write: unknown action' USING ERRCODE = '22023';
  END IF;
  IF NOT public._exos_api_has_scope(k.scopes, v_scope) THEN
    RAISE EXCEPTION 'exos_api_write: the key lacks the % scope', v_scope USING ERRCODE = '42501';
  END IF;

  -- 2. Run as the key's creator, while they are still an active member.
  v_actor := k.created_by;
  IF v_actor IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = v_org AND m.user_id = v_actor AND m.disabled IS NOT TRUE) THEN
    RAISE EXCEPTION 'exos_api_write: the member who created this key is no longer in the organization; create a new key'
      USING ERRCODE = '42501';
  END IF;
  -- 3. Idempotency: claim the key first (a concurrent twin waits here).
  IF p_idempotency_key IS NOT NULL THEN
    IF p_idempotency_key !~ '^[A-Za-z0-9_.:-]{8,100}$' THEN
      RAISE EXCEPTION 'exos_api_write: Idempotency-Key must be 8-100 letters, digits, _ . : or -' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, idempotency_key, money_moving)
    VALUES (v_org, k.id, v_actor, p_action, left(p_target, 255), p_idempotency_key, v_money)
    ON CONFLICT (api_key_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
    RETURNING id INTO v_log;
    IF v_log IS NULL THEN
      SELECT * INTO v_prev FROM public.exos_api_writes
       WHERE api_key_id = k.id AND idempotency_key = p_idempotency_key;
      IF v_prev.action IS DISTINCT FROM p_action OR v_prev.target IS DISTINCT FROM left(p_target, 255) THEN
        RAISE EXCEPTION 'exos_api_write: this Idempotency-Key was already used for another request' USING ERRCODE = '22023';
      END IF;
      -- A refund re-claims (the claim itself is idempotent on the nonce and
      -- says whether Stripe still has to be asked); everything else replays.
      IF p_action <> 'refund.claim' THEN
        RETURN coalesce(v_prev.result, '{}'::jsonb) || jsonb_build_object('idempotent_replay', true);
      END IF;
      v_log := v_prev.id;
    END IF;
  END IF;

  -- The request's claims, put back once the action is done.
  v_was := jsonb_build_object(
    'claims', current_setting('request.jwt.claims', true), 'sub', current_setting('request.jwt.claim.sub', true),
    'role', current_setting('request.jwt.claim.role', true), 'email', current_setting('request.jwt.claim.email', true));
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_actor;
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', v_actor, 'role', 'authenticated', 'email', coalesce(v_email, ''),
                       'exos_api_key_id', k.id)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_actor::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_email, ''), true);

  -- 4. The action. Every target is pinned to the key's org first.
  CASE p_action

  -- Events ----------------------------------------------------------------------
  WHEN 'event.create' THEN
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can create events' USING ERRCODE = '42501';
    END IF;
    v_tmp := coalesce(a -> 'event', '{}'::jsonb);
    IF jsonb_typeof(v_tmp) <> 'object' OR btrim(coalesce(v_tmp ->> 'name', '')) = '' THEN
      RAISE EXCEPTION 'exos_api_write: an event needs a name' USING ERRCODE = '22023';
    END IF;
    IF a ? 'ticket_types' AND (jsonb_typeof(a -> 'ticket_types') <> 'array' OR jsonb_array_length(a -> 'ticket_types') > 50) THEN
      RAISE EXCEPTION 'exos_api_write: ticket_types must be a list of at most 50' USING ERRCODE = '22023';
    END IF;
    -- Born a draft; publishing is its own step (POST /events/:id/publish).
    v_id := public._exos_api_insert('public.exos_events', c_event, v_tmp,
              jsonb_build_object('org_id', v_org, 'created_by', v_actor, 'status', 'draft'));
    UPDATE public.exos_events SET occurs_at_local = public.exos_occurs_at_local(starts_at, timezone)
     WHERE id = v_id AND starts_at IS NOT NULL AND timezone IS NOT NULL;
    v_n := 0;
    FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(a -> 'ticket_types', '[]'::jsonb)) LOOP
      IF jsonb_typeof(v_item) <> 'object' OR btrim(coalesce(v_item ->> 'name', '')) = '' THEN
        RAISE EXCEPTION 'exos_api_write: each ticket type needs a name' USING ERRCODE = '22023';
      END IF;
      PERFORM public._exos_api_insert('public.exos_ticket_tiers', c_tier,
                CASE WHEN v_item ? 'sort_order' THEN v_item ELSE v_item || jsonb_build_object('sort_order', v_n) END,
                jsonb_build_object('event_id', v_id));
      v_n := v_n + 1;
    END LOOP;
    v_out := public._exos_api_event_json(v_id);

  WHEN 'event.update' THEN
    v_event := public._exos_api_uuid(p_target, 'event');
    SELECT * INTO v_ev FROM public.exos_events WHERE id = v_event AND org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: event not found' USING ERRCODE = 'P0002'; END IF;
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can edit events' USING ERRCODE = '42501';
    END IF;
    v_tmp := coalesce(a -> 'event', '{}'::jsonb);
    IF v_tmp ? 'name' AND btrim(coalesce(v_tmp ->> 'name', '')) = '' THEN
      RAISE EXCEPTION 'exos_api_write: an event needs a name' USING ERRCODE = '22023';
    END IF;
    PERFORM public._exos_api_update('public.exos_events', v_event, c_event, v_tmp);
    IF v_tmp ? 'starts_at' OR v_tmp ? 'timezone' THEN
      UPDATE public.exos_events SET occurs_at_local = public.exos_occurs_at_local(starts_at, timezone)
       WHERE id = v_event AND starts_at IS NOT NULL AND timezone IS NOT NULL;
    END IF;
    v_out := public._exos_api_event_json(v_event);

  WHEN 'event.publish' THEN
    v_event := public._exos_api_event_of(v_org, p_target);
    v_out := public.exos_publish_event(v_event);

  WHEN 'event.unpublish' THEN
    v_event := public._exos_api_event_of(v_org, p_target);
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can unpublish' USING ERRCODE = '42501';
    END IF;
    UPDATE public.exos_events SET status = 'draft' WHERE id = v_event AND status = 'published';
    v_out := jsonb_build_object('event_id', v_event,
                                'status', (SELECT status FROM public.exos_events WHERE id = v_event));

  -- Ticket types (the exos_tiers_wr policy: owner / manager) -------------------------
  WHEN 'ticket_type.create' THEN
    v_event := public._exos_api_event_of(v_org, p_target);
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can change ticket types' USING ERRCODE = '42501';
    END IF;
    v_tmp := coalesce(a -> 'ticket_type', '{}'::jsonb);
    IF jsonb_typeof(v_tmp) <> 'object' OR btrim(coalesce(v_tmp ->> 'name', '')) = '' THEN
      RAISE EXCEPTION 'exos_api_write: a ticket type needs a name' USING ERRCODE = '22023';
    END IF;
    v_id := public._exos_api_insert('public.exos_ticket_tiers', c_tier, v_tmp, jsonb_build_object('event_id', v_event));
    SELECT to_jsonb(t) INTO v_out FROM public.exos_ticket_tiers t WHERE t.id = v_id;

  WHEN 'ticket_type.update', 'ticket_type.delete' THEN
    v_id := public._exos_api_uuid(p_target, 'ticket type');
    PERFORM 1 FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
     WHERE t.id = v_id AND e.org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: ticket type not found' USING ERRCODE = 'P0002'; END IF;
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can change ticket types' USING ERRCODE = '42501';
    END IF;
    IF p_action = 'ticket_type.delete' THEN
      IF EXISTS (SELECT 1 FROM public.exos_tickets WHERE tier_id = v_id) THEN
        RAISE EXCEPTION 'exos_api_write: this ticket type has tickets; hide it instead' USING ERRCODE = '23503';
      END IF;
      DELETE FROM public.exos_ticket_tiers WHERE id = v_id;
      v_out := jsonb_build_object('id', v_id, 'deleted', true);
    ELSE
      v_tmp := coalesce(a -> 'ticket_type', '{}'::jsonb);
      IF v_tmp ? 'name' AND btrim(coalesce(v_tmp ->> 'name', '')) = '' THEN
        RAISE EXCEPTION 'exos_api_write: a ticket type needs a name' USING ERRCODE = '22023';
      END IF;
      PERFORM public._exos_api_update('public.exos_ticket_tiers', v_id, c_tier, v_tmp);
      SELECT to_jsonb(t) INTO v_out FROM public.exos_ticket_tiers t WHERE t.id = v_id;
    END IF;

  -- Add-ons (the exos_addons_wr policy: owner / manager) ---------------------------
  WHEN 'add_on.create' THEN
    v_event := public._exos_api_event_of(v_org, p_target);
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can change add-ons' USING ERRCODE = '42501';
    END IF;
    v_tmp := coalesce(a -> 'add_on', '{}'::jsonb);
    IF jsonb_typeof(v_tmp) <> 'object' OR btrim(coalesce(v_tmp ->> 'name', '')) = '' THEN
      RAISE EXCEPTION 'exos_api_write: an add-on needs a name' USING ERRCODE = '22023';
    END IF;
    v_id := public._exos_api_insert('public.exos_event_addons', c_addon, v_tmp, jsonb_build_object('event_id', v_event));
    SELECT to_jsonb(x) - 'tax_rate_id' INTO v_out FROM public.exos_event_addons x WHERE x.id = v_id;

  WHEN 'add_on.update', 'add_on.delete' THEN
    v_id := public._exos_api_uuid(p_target, 'add-on');
    PERFORM 1 FROM public.exos_event_addons x JOIN public.exos_events e ON e.id = x.event_id
     WHERE x.id = v_id AND e.org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: add-on not found' USING ERRCODE = 'P0002'; END IF;
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can change add-ons' USING ERRCODE = '42501';
    END IF;
    IF p_action = 'add_on.delete' THEN
      IF EXISTS (SELECT 1 FROM public.exos_event_addons WHERE id = v_id AND sold > 0) THEN
        RAISE EXCEPTION 'exos_api_write: this add-on has been sold; hide it instead' USING ERRCODE = '23503';
      END IF;
      DELETE FROM public.exos_event_addons WHERE id = v_id;
      v_out := jsonb_build_object('id', v_id, 'deleted', true);
    ELSE
      PERFORM public._exos_api_update('public.exos_event_addons', v_id, c_addon, coalesce(a -> 'add_on', '{}'::jsonb));
      SELECT to_jsonb(x) - 'tax_rate_id' INTO v_out FROM public.exos_event_addons x WHERE x.id = v_id;
    END IF;

  -- Promo codes: issued by the dashboard's exos_issue_voucher ----------------------------
  WHEN 'promo_code.create' THEN
    v_event := public._exos_api_event_of(v_org, p_target);
    v_tmp := coalesce(a -> 'promo_code', '{}'::jsonb);
    IF jsonb_typeof(v_tmp) <> 'object' THEN
      RAISE EXCEPTION 'exos_api_write: promo_code must be an object' USING ERRCODE = '22023';
    END IF;
    PERFORM public._exos_api_field_keys('public.exos_vouchers',
      ARRAY['code', 'tier_id', 'max_uses', 'valid_hours', 'comment', 'price_override', 'discount_percent',
            'discount_amount', 'reserved_email', 'bypass_capacity'],
      v_tmp - 'valid_hours');
    v_res := to_jsonb(public.exos_issue_voucher(
      v_event,
      (v_tmp ->> 'tier_id')::uuid,
      lower(nullif(btrim(coalesce(v_tmp ->> 'reserved_email', '')), '')),
      coalesce((v_tmp ->> 'bypass_capacity')::boolean, true),  -- the dashboard's default
      (v_tmp ->> 'price_override')::numeric,
      coalesce((v_tmp ->> 'max_uses')::int, 1),
      (v_tmp ->> 'valid_hours')::int,
      v_tmp ->> 'comment',
      v_tmp ->> 'code',
      (v_tmp ->> 'discount_percent')::numeric,
      (v_tmp ->> 'discount_amount')::numeric));
    SELECT jsonb_build_object('id', v.id, 'code', v.code, 'tier_id', v.tier_id, 'max_uses', v.max_uses,
             'used_count', v.used_count, 'discount_percent', v.discount_percent, 'discount_amount', v.discount_amount,
             'price_override', v.price_override, 'valid_until', v.valid_until, 'comment', v.comment,
             'created_at', v.created_at)
      INTO v_out FROM public.exos_vouchers v WHERE v.event_id = v_event AND v.code = v_res #>> '{}';

  WHEN 'promo_code.update', 'promo_code.delete' THEN
    v_id := public._exos_api_uuid(p_target, 'promo code');
    PERFORM 1 FROM public.exos_vouchers v JOIN public.exos_events e ON e.id = v.event_id
     WHERE v.id = v_id AND e.org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: promo code not found' USING ERRCODE = 'P0002'; END IF;
    -- exos_vouchers_write policy: owner / manager.
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can change promo codes' USING ERRCODE = '42501';
    END IF;
    IF p_action = 'promo_code.delete' THEN
      DELETE FROM public.exos_vouchers WHERE id = v_id;
      v_out := jsonb_build_object('id', v_id, 'deleted', true);
    ELSE
      PERFORM public._exos_api_update('public.exos_vouchers', v_id, c_voucher, coalesce(a -> 'promo_code', '{}'::jsonb));
      SELECT jsonb_build_object('id', v.id, 'code', v.code, 'tier_id', v.tier_id, 'max_uses', v.max_uses,
               'used_count', v.used_count, 'discount_percent', v.discount_percent, 'discount_amount', v.discount_amount,
               'price_override', v.price_override, 'valid_until', v.valid_until, 'comment', v.comment,
               'link_label', v.link_label, 'created_at', v.created_at)
        INTO v_out FROM public.exos_vouchers v WHERE v.id = v_id;
    END IF;

  -- POS / food and beverage items (exos_pos_items_wr: owner / manager) ---------------
  WHEN 'pos_item.create' THEN
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can change POS items' USING ERRCODE = '42501';
    END IF;
    v_tmp := coalesce(a -> 'item', '{}'::jsonb);
    IF jsonb_typeof(v_tmp) <> 'object' OR btrim(coalesce(v_tmp ->> 'name', '')) = '' THEN
      RAISE EXCEPTION 'exos_api_write: an item needs a name' USING ERRCODE = '22023';
    END IF;
    IF v_tmp ? 'event_id' AND v_tmp ->> 'event_id' IS NOT NULL THEN
      PERFORM public._exos_api_event_of(v_org, v_tmp ->> 'event_id');
    END IF;
    v_id := public._exos_api_insert('public.exos_pos_items', c_pos, v_tmp, jsonb_build_object('org_id', v_org));
    SELECT to_jsonb(x) - 'eighty_sixed_by' INTO v_out FROM public.exos_pos_items x WHERE x.id = v_id;

  WHEN 'pos_item.update' THEN
    v_id := public._exos_api_uuid(p_target, 'item');
    PERFORM 1 FROM public.exos_pos_items x WHERE x.id = v_id AND x.org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: item not found' USING ERRCODE = 'P0002'; END IF;
    IF NOT public.exos_has_org_role(v_org, c_staff) THEN
      RAISE EXCEPTION 'exos_api_write: only an owner or manager can change POS items' USING ERRCODE = '42501';
    END IF;
    v_tmp := coalesce(a -> 'item', '{}'::jsonb);
    IF v_tmp ? 'event_id' AND v_tmp ->> 'event_id' IS NOT NULL THEN
      PERFORM public._exos_api_event_of(v_org, v_tmp ->> 'event_id');
    END IF;
    PERFORM public._exos_api_update('public.exos_pos_items', v_id, c_pos, v_tmp);
    SELECT to_jsonb(x) - 'eighty_sixed_by' INTO v_out FROM public.exos_pos_items x WHERE x.id = v_id;

  -- Refunds: the dashboard's claim (role, amounts, locks, nonce) -----------------------
  WHEN 'refund.claim' THEN
    IF p_idempotency_key IS NULL THEN
      RAISE EXCEPTION 'exos_api_write: refunds need an Idempotency-Key' USING ERRCODE = '22023';
    END IF;
    PERFORM 1 FROM public.exos_checkout_sessions s WHERE s.session_id = p_target AND s.org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: order not found' USING ERRCODE = 'P0002'; END IF;
    v_out := public.exos_refund_claim(
      v_actor, p_target,
      'api:' || replace(k.id::text, '-', '') || ':' || p_idempotency_key,
      CASE WHEN jsonb_typeof(a -> 'items') = 'array' THEN a -> 'items' END,
      (a ->> 'amount_cents')::int,
      coalesce((a ->> 'whole_order')::boolean, false),
      left(a ->> 'reason', 500),
      NULL);

  WHEN 'refund.preview' THEN
    PERFORM 1 FROM public.exos_checkout_sessions s WHERE s.session_id = p_target AND s.org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: order not found' USING ERRCODE = 'P0002'; END IF;
    v_out := public.exos_refund_preview(p_target);

  -- Comps: the dashboard's batch (owner / manager, tier, caps, mail) -----------------
  WHEN 'comp.issue' THEN
    v_event := public._exos_api_event_of(v_org, p_target);
    IF jsonb_typeof(a -> 'emails') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'exos_api_write: emails must be a list' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object('email', r.email, 'outcome', r.outcome,
                                                 'ticket_ids', to_jsonb(r.ticket_ids), 'detail', r.detail)), '[]'::jsonb)
      INTO v_rows
      FROM public.exos_issue_comp_batch(
             v_event, (a ->> 'tier_id')::uuid,
             ARRAY(SELECT jsonb_array_elements_text(a -> 'emails')),
             coalesce((a ->> 'quantity_each')::int, 1), NULL) r;
    v_out := jsonb_build_object('event_id', v_event, 'results', v_rows);

  -- Door: the dashboard's check-in functions ---------------------------------------
  WHEN 'ticket.check_in', 'ticket.undo_check_in' THEN
    v_id := public._exos_api_uuid(p_target, 'ticket');
    SELECT t.event_id INTO v_event FROM public.exos_tickets t WHERE t.id = v_id AND t.org_id = v_org;
    IF v_event IS NULL THEN RAISE EXCEPTION 'exos_api_write: ticket not found' USING ERRCODE = 'P0002'; END IF;
    IF p_action = 'ticket.undo_check_in' THEN
      v_out := public.exos_undo_check_in(v_id, v_event, a ->> 'reason');
    ELSE
      -- A signed code from a scanner is checked like a camera scan; without
      -- one it is a typed override (owner / manager, with a reason).
      v_out := public.exos_check_in_ticket(
        v_id,
        CASE WHEN nullif(btrim(coalesce(a ->> 'barcode', '')), '') IS NOT NULL THEN 'camera' ELSE 'manual' END,
        'manual', nullif(btrim(coalesce(a ->> 'barcode', '')), ''), v_event, a ->> 'reason',
        NULL, left(coalesce(a ->> 'device', 'api'), 60), (a ->> 'list_id')::uuid,
        coalesce(a ->> 'direction', 'entry'));
    END IF;

  WHEN 'order.check_in' THEN
    PERFORM 1 FROM public.exos_checkout_sessions s WHERE s.session_id = p_target AND s.org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: order not found' USING ERRCODE = 'P0002'; END IF;
    v_rows := '[]'::jsonb;
    FOR v_uuid, v_event IN
      SELECT t.id, t.event_id FROM public.exos_tickets t
       WHERE t.org_id = v_org AND t.order_ref = p_target AND t.status IN ('active', 'used')
       ORDER BY t.created_at, t.id
    LOOP
      v_res := public.exos_check_in_ticket(v_uuid, 'manual', 'manual', NULL, v_event, a ->> 'reason',
                                           NULL, left(coalesce(a ->> 'device', 'api'), 60),
                                           (a ->> 'list_id')::uuid, coalesce(a ->> 'direction', 'entry'));
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('ticket_id', v_uuid) || v_res);
    END LOOP;
    v_out := jsonb_build_object('order_id', p_target, 'results', v_rows);

  WHEN 'event.offline_check_ins' THEN
    v_event := public._exos_api_event_of(v_org, p_target);
    IF jsonb_typeof(a -> 'scans') IS DISTINCT FROM 'array' OR jsonb_array_length(a -> 'scans') > 500 THEN
      RAISE EXCEPTION 'exos_api_write: scans must be a list of at most 500' USING ERRCODE = '22023';
    END IF;
    v_rows := '[]'::jsonb;
    FOR v_item IN SELECT * FROM jsonb_array_elements(a -> 'scans') LOOP
      BEGIN
        v_uuid := (v_item ->> 'ticket_id')::uuid;
        -- A ticket of another org reads as not found, like everywhere else.
        IF NOT EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.id = v_uuid AND t.org_id = v_org) THEN
          v_res := jsonb_build_object('ok', false, 'reason', 'not-found');
        ELSE
          v_res := public.exos_check_in_offline(
            (v_item ->> 'client_ref')::uuid, v_uuid, v_event, (v_item ->> 'scanned_at')::timestamptz,
            nullif(btrim(coalesce(v_item ->> 'barcode', '')), ''),
            coalesce(v_item ->> 'source', CASE WHEN nullif(btrim(coalesce(v_item ->> 'barcode', '')), '') IS NULL
                                               THEN 'manual' ELSE 'camera' END),
            v_item ->> 'reason', left(coalesce(v_item ->> 'device', 'api'), 60),
            (v_item ->> 'list_id')::uuid, coalesce(v_item ->> 'direction', 'entry'));
        END IF;
      EXCEPTION
        WHEN invalid_text_representation OR datetime_field_overflow OR invalid_datetime_format THEN
          v_res := jsonb_build_object('ok', false, 'reason', 'bad-scan');
        WHEN SQLSTATE '22023' THEN
          v_res := jsonb_build_object('ok', false, 'reason', 'bad-scan', 'detail', SQLERRM);
      END;
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('client_ref', v_item -> 'client_ref', 'ticket_id', v_item -> 'ticket_id') || v_res);
    END LOOP;
    v_out := jsonb_build_object('event_id', v_event, 'results', v_rows);

  -- Guest lists: the dashboard's functions ------------------------------------------
  WHEN 'guest_list.create' THEN
    v_event := public._exos_api_event_of(v_org, p_target);
    v_tmp := coalesce(a -> 'guest_list', '{}'::jsonb);
    v_id := public.exos_upsert_guest_list(
      v_event, v_tmp ->> 'name', (v_tmp ->> 'cap')::int, (v_tmp ->> 'promoter_id')::uuid,
      coalesce((v_tmp ->> 'counts_toward_capacity')::boolean, false), coalesce((v_tmp ->> 'max_plus_ones')::int, 5),
      NULL, coalesce(v_tmp ->> 'status', 'open'), (v_tmp ->> 'closes_at')::timestamptz, NULL);
    SELECT to_jsonb(l) - 'created_by' - 'owner_uid' INTO v_out FROM public.exos_guest_lists l WHERE l.id = v_id;

  WHEN 'guest_list.update', 'guest_list.delete' THEN
    v_id := public._exos_api_uuid(p_target, 'guest list');
    SELECT to_jsonb(l) INTO v_tmp FROM public.exos_guest_lists l WHERE l.id = v_id AND l.org_id = v_org;
    IF v_tmp IS NULL THEN RAISE EXCEPTION 'exos_api_write: guest list not found' USING ERRCODE = 'P0002'; END IF;
    IF p_action = 'guest_list.delete' THEN
      PERFORM public.exos_delete_guest_list(v_id);
      v_out := jsonb_build_object('id', v_id, 'deleted', true);
    ELSE
      -- The upsert takes every field: unspecified ones keep their value.
      v_tmp := v_tmp || (coalesce(a -> 'guest_list', '{}'::jsonb)
                          - 'id' - 'event_id' - 'org_id' - 'owner_uid' - 'created_by' - 'created_at' - 'updated_at');
      PERFORM public.exos_upsert_guest_list(
        (v_tmp ->> 'event_id')::uuid, v_tmp ->> 'name', (v_tmp ->> 'cap')::int, (v_tmp ->> 'promoter_id')::uuid,
        (v_tmp ->> 'counts_toward_capacity')::boolean, (v_tmp ->> 'max_plus_ones')::int,
        v_id, v_tmp ->> 'status', (v_tmp ->> 'closes_at')::timestamptz, (v_tmp ->> 'owner_uid')::uuid);
      SELECT to_jsonb(l) - 'created_by' - 'owner_uid' INTO v_out FROM public.exos_guest_lists l WHERE l.id = v_id;
    END IF;

  WHEN 'guest.add' THEN
    v_id := public._exos_api_uuid(p_target, 'guest list');
    PERFORM 1 FROM public.exos_guest_lists l WHERE l.id = v_id AND l.org_id = v_org;
    IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: guest list not found' USING ERRCODE = 'P0002'; END IF;
    v_rows := CASE WHEN jsonb_typeof(a -> 'guests') = 'array' THEN a -> 'guests' ELSE jsonb_build_array(a) END;
    IF jsonb_array_length(v_rows) = 0 OR jsonb_array_length(v_rows) > 500 THEN
      RAISE EXCEPTION 'exos_api_write: add 1 to 500 guests at a time' USING ERRCODE = '22023';
    END IF;
    v_out := '[]'::jsonb;
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_rows) LOOP
      v_uuid := public.exos_add_guest(v_id, v_item ->> 'guest_name', v_item ->> 'email', v_item ->> 'phone',
                                      coalesce((v_item ->> 'plus_ones')::int, 0), v_item ->> 'note');
      v_out := v_out || jsonb_build_array(v_uuid);
    END LOOP;
    SELECT jsonb_build_object('list_id', v_id, 'data', coalesce(jsonb_agg(
             to_jsonb(en) - 'added_by' - 'added_by_promoter' ORDER BY en.created_at, en.id), '[]'::jsonb))
      INTO v_out FROM public.exos_guest_list_entries en
     WHERE en.id IN (SELECT (x #>> '{}')::uuid FROM jsonb_array_elements(v_out) x);

  WHEN 'guest.update', 'guest.remove', 'guest.check_in' THEN
    v_id := public._exos_api_uuid(p_target, 'guest');
    SELECT to_jsonb(en) INTO v_tmp FROM public.exos_guest_list_entries en WHERE en.id = v_id AND en.org_id = v_org;
    IF v_tmp IS NULL THEN RAISE EXCEPTION 'exos_api_write: guest not found' USING ERRCODE = 'P0002'; END IF;
    IF p_action = 'guest.remove' THEN
      PERFORM public.exos_remove_guest(v_id);
      v_out := jsonb_build_object('id', v_id, 'deleted', true);
    ELSIF p_action = 'guest.check_in' THEN
      v_out := public.exos_guest_check_in(v_id, coalesce((a ->> 'count')::int, 1), (v_tmp ->> 'event_id')::uuid,
                                          (a ->> 'client_ref')::uuid, 'online');
    ELSE
      v_tmp := v_tmp || (a - 'id' - 'list_id' - 'event_id' - 'org_id');
      PERFORM public.exos_update_guest(v_id, v_tmp ->> 'guest_name', v_tmp ->> 'email', v_tmp ->> 'phone',
                                       coalesce((v_tmp ->> 'plus_ones')::int, 0), v_tmp ->> 'note');
      SELECT to_jsonb(en) - 'added_by' - 'added_by_promoter' INTO v_out
        FROM public.exos_guest_list_entries en WHERE en.id = v_id;
    END IF;

  ELSE
    RAISE EXCEPTION 'exos_api_write: unknown action' USING ERRCODE = '22023';
  END CASE;

  PERFORM set_config('request.jwt.claims', coalesce(v_was ->> 'claims', ''), true);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_was ->> 'sub', ''), true);
  PERFORM set_config('request.jwt.claim.role', coalesce(v_was ->> 'role', ''), true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_was ->> 'email', ''), true);

  -- 5. Log it (and keep the answer for a replay).
  IF v_log IS NOT NULL THEN
    UPDATE public.exos_api_writes SET result = v_out WHERE id = v_log;
  ELSIF p_action <> 'refund.preview' THEN
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, money_moving, result)
    VALUES (v_org, k.id, v_actor, p_action, left(p_target, 255), v_money,
            CASE WHEN v_money THEN v_out END);
  END IF;
  RETURN coalesce(v_out, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_api_write(uuid, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_write(uuid, text, text, jsonb, text) TO service_role;
