-- ============================================================================
-- Migration 20261106100000 — Exos: import from DICE (KANBAN "DICE gaps" 1)
-- ============================================================================
-- Touches:  C: TABLE exos_dice_connections (owner / manager read, never the
--              token: no secret_id / lease_id column grant), exos_dice_import_runs,
--              exos_dice_id_map, exos_dice_orders (owner / manager read);
--              every write goes through the definer functions below
--           W: exos_events (CHECKs primary_source and ticket_backend gain
--              'dice', rebuilt from their current lists), exos_event_imports
--              (platform gains 'dice'), exos_fans (source gains 'dice')
--           C: FUNCTION (service role: exos-dice-import, exos-api)
--              exos_dice_connect, exos_dice_disconnect, exos_dice_token,
--              exos_dice_sync_claim, exos_dice_apply, exos_dice_sync_finish,
--              exos_dice_log_dry_run, _exos_dice_status_json, _exos_dice_runs,
--              _exos_dice_run_json,
--              and the helpers _exos_dice_id, _exos_dice_ref, _exos_dice_ts,
--              _exos_dice_counts_merge, _exos_dice_list, _exos_dice_fan_upsert,
--              _exos_dice_event_upsert, _exos_dice_ticket_upsert,
--              _exos_dice_return_upsert, _exos_dice_order_upsert,
--              _exos_dice_transfer_upsert
--           C: FUNCTION exos_dice_org_status (authenticated, owner / manager)
--           W: exos_guest_lists / exos_guest_list_entries (a 'DICE' list per
--              imported event; one entry per DICE ticket, source 'DICE',
--              external_ref 'dice:<id>', external_code = the DICE code)
--           W: exos_fans (DICE buyers and holders; the email list ONLY when
--              DICE's optInPartners is true, under exos.fan_consent_action)
--           C: cron.schedule exos-dice-import-sync-hourly (when pg_cron and
--              _cron_invoke_edge_fn are present), created INACTIVE
--           R: vault.secrets / vault.create_secret / vault.update_secret /
--              vault.decrypted_secrets, exos_org_memberships (_exos_eb_role),
--              exos_signup_submissions
-- Pre-reqs: 20261029170500 (link-out events, exos_event_imports,
--           _exos_link_out_slug / _exos_link_out_types), 20261013090000 and
--           20261013100000 (imported codes, external_ref / voided_at on guest
--           entries, _exos_eb_role), 20261031120000 (exos_fans and its consent
--           guard), 20261105100000 (exos_door_code_lookup: a scanned code ->
--           its guest entry).
--
-- A promoter moving from DICE pastes the API token they generated in MIO
-- (DICE's partner dashboard). The exos-dice-import edge function checks it
-- with `viewer { id name }` and stores it in Vault (exos_dice:<org>), the
-- way the Eventbrite token is stored: no client role can read it back, and
-- exos_dice_connections has no client grant on secret_id. Then a sync reads,
-- through _shared/dice/client.ts (GraphQL QUERIES only: anything with a
-- mutation or subscription is refused before it is sent):
--
--   events     -> a DRAFT link-out Exos event per upcoming DICE event
--                 (link_out, ticket_backend / primary_source 'dice',
--                 external_ticket_url the DICE page, an exos_event_imports
--                 row with platform 'dice'): the 20261029170500 mode, so Exos
--                 never sells inventory DICE is selling (every sell table
--                 refuses a row for it). Ticket types are display only
--                 (exos_event_imports.ticket_types) and kept in the id map.
--                 A DICE event that is over, archived or cancelled is
--                 recorded in the id map but not created; its tickets and
--                 orders still bring their fans in.
--   tickets    -> a 'DICE' guest list on the event (no cap, outside the
--                 house capacity) with one entry per ticket: the holder's
--                 name / email / phone, the ticket type as the label, and
--                 DICE's code as external_code. The door downloads and
--                 matches it like any imported code (exos_event_door_extras
--                 on the device, exos_door_code_lookup online) and checks it
--                 in with exos_guest_check_in.
--   orders     -> exos_dice_orders (amounts in cents, channel, promo,
--                 ipCity / ipCountry), the buyer as a fan, its tickets as
--                 above, its returns as below.
--   returns    -> the ticket's entry is VOIDED ('returned on DICE'):
--                 exos_guest_check_in refuses it, by scan or by name. A
--                 return that arrives before its ticket is kept and applied
--                 when the ticket comes.
--   transfers  -> the ticket's entry follows the new holder.
--   fans       -> exos_fans, one per (org, email), source 'dice'. Marketing
--                 consent (email_opt_in_at, source 'dice:optInPartners') is
--                 set ONLY when DICE's Fan.optInPartners is true, and never
--                 over an Exos unsubscribe. A fan whose DICE opt-in later
--                 reads false loses the DICE-sourced consent (unless they also
--                 confirmed an Exos signup). Everyone else is a ticket holder
--                 without marketing consent. No birthday, no address, no
--                 phone on the fan profile (the 20261031120000 rule); no SMS
--                 subscription ever comes from DICE.
--
-- Re-running is idempotent: exos_dice_id_map keys every DICE event, ticket
-- type, ticket, fan and return per org, so a second sync updates the same
-- rows in place. The connection keeps a cursor per entity (see
-- _shared/dice/sync.ts): a full first run, then incremental passes
-- (updatedAt / purchasedAt / returnedAt / transferredAt >= the last pass's
-- start minus five minutes); a run stopped by its caps resumes at DICE's
-- endCursor. Each run holds a 5-minute lease on the connection and every
-- page it writes presents it, so the cron and a manual sync never write at
-- the same time, and a run overtaken by a reconnect writes nothing.
--
-- Nothing is written to DICE. Disconnect deletes the token; what was
-- imported stays.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded policies and
-- constraints, union CHECK rebuilds). Prod apply needs operator OK.
-- ============================================================================

-- Add values to a "col IN (...)" / "col = ANY (ARRAY[...])" CHECK, keeping
-- whatever it allows now (another branch may have added its own values).
CREATE OR REPLACE FUNCTION pg_temp.exos_check_add(p_table regclass, p_con text, p_col text, p_add text[])
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_def text; v_vals text[]; v_new text[];
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint WHERE conrelid = p_table AND conname = p_con;
  IF v_def IS NULL THEN
    RAISE EXCEPTION '%: constraint % not present', p_table, p_con;
  END IF;
  SELECT array_agg(m[1] ORDER BY ord) INTO v_vals
    FROM regexp_matches(v_def, '''([a-z_]+)''', 'g') WITH ORDINALITY AS r(m, ord);
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_new FROM unnest(coalesce(v_vals, '{}') || p_add) x;
  IF v_vals @> p_add THEN
    RAISE NOTICE '%: % already allows %', p_table, p_con, p_add;
    RETURN;
  END IF;
  EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', p_table, p_con);
  EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%I = ANY (ARRAY[%s]))', p_table, p_con, p_col,
                 (SELECT string_agg(quote_literal(x) || '::text', ', ' ORDER BY x) FROM unnest(v_new) x));
END $$;

-- ---------------------------------------------------------------------------
-- 1. DICE as a platform.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_check_add('public.exos_events', 'exos_events_primary_source_check', 'primary_source', ARRAY['dice']);
SELECT pg_temp.exos_check_add('public.exos_events', 'exos_events_ticket_backend_chk', 'ticket_backend', ARRAY['dice']);
SELECT pg_temp.exos_check_add('public.exos_event_imports', 'exos_event_imports_platform_check', 'platform', ARRAY['dice']);
SELECT pg_temp.exos_check_add('public.exos_fans', 'exos_fans_source_check', 'source', ARRAY['dice']);

-- ---------------------------------------------------------------------------
-- 2. Tables.
-- ---------------------------------------------------------------------------
-- One DICE connection per org. The token is in Vault (secret_id), never here.
CREATE TABLE IF NOT EXISTS public.exos_dice_connections (
  org_id            uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  secret_id         uuid,                       -- vault.secrets id (exos_dice:<org>); NULL once disconnected
  status            text NOT NULL DEFAULT 'connected'
                      CONSTRAINT exos_dice_connections_status_chk CHECK (status IN ('connected', 'error', 'disconnected')),
  account_id        text CHECK (account_id IS NULL OR length(account_id) BETWEEN 1 AND 200),  -- DICE viewer.id
  account_name      text CHECK (account_name IS NULL OR length(account_name) <= 120),        -- DICE viewer.name
  connected_by      uuid,
  connected_at      timestamptz,
  disconnected_at   timestamptz,
  -- { events: {since, after, pass_started_at}, tickets: …, orders: …, returns: …, transfers: … }
  cursors           jsonb NOT NULL DEFAULT '{}'::jsonb
                      CHECK (jsonb_typeof(cursors) = 'object' AND pg_column_size(cursors) <= 8192),
  full_sync_done_at timestamptz,               -- every entity has finished one pass
  last_sync_at      timestamptz,
  last_ok_at        timestamptz,
  last_error        text CHECK (last_error IS NULL OR length(last_error) <= 300),
  lease_id          uuid,
  lease_until       timestamptz,
  run_id            uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_dice_connections_secret_chk CHECK (status = 'disconnected' OR secret_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_dice_connections_due_idx ON public.exos_dice_connections (last_sync_at NULLS FIRST)
  WHERE status = 'connected';
ALTER TABLE public.exos_dice_connections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_dice_connections FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_dice_connections TO service_role;
-- Owners / managers may read their connection's state; never secret_id or the lease.
GRANT SELECT (org_id, status, account_id, account_name, connected_at, disconnected_at, cursors,
              full_sync_done_at, last_sync_at, last_ok_at, last_error, created_at, updated_at)
  ON public.exos_dice_connections TO authenticated;
DROP POLICY IF EXISTS exos_dice_connections_sel ON public.exos_dice_connections;
CREATE POLICY exos_dice_connections_sel ON public.exos_dice_connections FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
DROP TRIGGER IF EXISTS exos_dice_connections_touch ON public.exos_dice_connections;
CREATE TRIGGER exos_dice_connections_touch BEFORE UPDATE ON public.exos_dice_connections
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_dice_connections IS
  'DICE import: an org''s DICE (MIO) API token in Vault (secret_id; no client grant on it), its status, sync cursors per entity and the run lease. Written by the exos_dice_* functions only. mig 20261106100000.';

CREATE TABLE IF NOT EXISTS public.exos_dice_import_runs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT exos_dice_runs_kind_chk CHECK (kind IN ('full', 'incremental')),
  trigger     text NOT NULL CONSTRAINT exos_dice_runs_trigger_chk CHECK (trigger IN ('dashboard', 'api', 'cron')),
  dry_run     boolean NOT NULL DEFAULT false,
  status      text NOT NULL DEFAULT 'running'
                CONSTRAINT exos_dice_runs_status_chk CHECK (status IN ('running', 'ok', 'partial', 'error')),
  started_by  uuid,
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  -- { events: {read, created, updated, …}, tickets: {…}, … } (+ preview for a dry run)
  counts      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(counts) = 'object' AND pg_column_size(counts) <= 16384),
  errors      jsonb NOT NULL DEFAULT '[]'::jsonb
                CHECK (jsonb_typeof(errors) = 'array' AND jsonb_array_length(errors) <= 50),
  error       text CHECK (error IS NULL OR length(error) <= 300),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_dice_import_runs_org_idx ON public.exos_dice_import_runs (org_id, started_at DESC);
ALTER TABLE public.exos_dice_import_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_dice_import_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.exos_dice_import_runs TO authenticated;
GRANT ALL ON TABLE public.exos_dice_import_runs TO service_role;
DROP POLICY IF EXISTS exos_dice_import_runs_sel ON public.exos_dice_import_runs;
CREATE POLICY exos_dice_import_runs_sel ON public.exos_dice_import_runs FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
DROP TRIGGER IF EXISTS exos_dice_import_runs_touch ON public.exos_dice_import_runs;
CREATE TRIGGER exos_dice_import_runs_touch BEFORE UPDATE ON public.exos_dice_import_runs
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_dice_import_runs IS
  'DICE import runs: kind, trigger, dry run or not, counts per entity, errors, start and finish. mig 20261106100000.';

-- DICE id -> Exos id, per org. exos_id by entity:
--   event        exos_events.id; NULL for a DICE event Exos didn't create
--                (over, archived or cancelled when first seen)
--   ticket_type  NULL: a link-out event has no Exos ticket types; the type is
--                display only (exos_event_imports.ticket_types), event_id set
--   ticket       exos_guest_list_entries.id; NULL while its event isn't an Exos event
--   fan          exos_fans.id (two DICE fans with one email share it)
--   return       the voided entry; NULL until its ticket arrives
-- parent_dice_id: the DICE event of a ticket type / ticket, the DICE ticket of a return.
CREATE TABLE IF NOT EXISTS public.exos_dice_id_map (
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  entity         text NOT NULL CONSTRAINT exos_dice_id_map_entity_chk
                   CHECK (entity IN ('event', 'ticket_type', 'ticket', 'fan', 'return')),
  dice_id        text NOT NULL CHECK (dice_id ~ '^\S{1,200}$'),
  exos_id        uuid,
  event_id       uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  parent_dice_id text CHECK (parent_dice_id IS NULL OR parent_dice_id ~ '^\S{1,200}$'),
  data           jsonb NOT NULL DEFAULT '{}'::jsonb
                   CHECK (jsonb_typeof(data) = 'object' AND pg_column_size(data) <= 32768),
  first_seen_at  timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, entity, dice_id)
);
CREATE INDEX IF NOT EXISTS exos_dice_id_map_parent_idx ON public.exos_dice_id_map (org_id, entity, parent_dice_id)
  WHERE parent_dice_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_dice_id_map_exos_idx ON public.exos_dice_id_map (exos_id) WHERE exos_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_dice_id_map_event_idx ON public.exos_dice_id_map (event_id) WHERE event_id IS NOT NULL;
ALTER TABLE public.exos_dice_id_map ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_dice_id_map FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.exos_dice_id_map TO authenticated;
GRANT ALL ON TABLE public.exos_dice_id_map TO service_role;
DROP POLICY IF EXISTS exos_dice_id_map_sel ON public.exos_dice_id_map;
CREATE POLICY exos_dice_id_map_sel ON public.exos_dice_id_map FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
DROP TRIGGER IF EXISTS exos_dice_id_map_touch ON public.exos_dice_id_map;
CREATE TRIGGER exos_dice_id_map_touch BEFORE UPDATE ON public.exos_dice_id_map
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_dice_id_map IS
  'DICE import: DICE id -> Exos id per org for events, ticket types, tickets, fans and returns (re-runs update in place), plus the DICE-side details Exos has no column for (data). mig 20261106100000.';

-- DICE orders: what was bought, for how much (integer cents, as DICE sends
-- them), where (IP city / country) and with which promo. Read only history.
CREATE TABLE IF NOT EXISTS public.exos_dice_orders (
  org_id                uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  dice_id               text NOT NULL CHECK (dice_id ~ '^\S{1,200}$'),
  dice_event_id         text CHECK (dice_event_id IS NULL OR dice_event_id ~ '^\S{1,200}$'),
  event_id              uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  dice_fan_id           text CHECK (dice_fan_id IS NULL OR dice_fan_id ~ '^\S{1,200}$'),
  fan_id                uuid REFERENCES public.exos_fans (id) ON DELETE SET NULL,
  purchased_at          timestamptz,
  quantity              integer CHECK (quantity IS NULL OR quantity BETWEEN 0 AND 100000),
  sales_channel         text CHECK (sales_channel IS NULL OR length(sales_channel) <= 20),
  currency              text CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
  full_price_cents      integer,
  commission_cents      integer,
  dice_commission_cents integer,
  total_cents           integer,
  fees                  jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(fees) = 'array' AND jsonb_array_length(fees) <= 30),
  adjustments           jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(adjustments) = 'array' AND jsonb_array_length(adjustments) <= 30),
  promo_code            text CHECK (promo_code IS NULL OR length(promo_code) <= 80),
  promo_name            text CHECK (promo_name IS NULL OR length(promo_name) <= 120),
  promo_discount_cents  integer,
  promo_type            text CHECK (promo_type IS NULL OR length(promo_type) <= 20),
  ip_city               text CHECK (ip_city IS NULL OR length(ip_city) <= 120),
  ip_country            text CHECK (ip_country IS NULL OR length(ip_country) <= 60),
  tickets               integer NOT NULL DEFAULT 0 CHECK (tickets >= 0),
  first_seen_at         timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, dice_id)
);
CREATE INDEX IF NOT EXISTS exos_dice_orders_event_idx ON public.exos_dice_orders (org_id, dice_event_id);
CREATE INDEX IF NOT EXISTS exos_dice_orders_fan_idx ON public.exos_dice_orders (fan_id) WHERE fan_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_dice_orders_exos_event_idx ON public.exos_dice_orders (event_id) WHERE event_id IS NOT NULL;
ALTER TABLE public.exos_dice_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_dice_orders FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.exos_dice_orders TO authenticated;
GRANT ALL ON TABLE public.exos_dice_orders TO service_role;
DROP POLICY IF EXISTS exos_dice_orders_sel ON public.exos_dice_orders;
CREATE POLICY exos_dice_orders_sel ON public.exos_dice_orders FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
DROP TRIGGER IF EXISTS exos_dice_orders_touch ON public.exos_dice_orders;
CREATE TRIGGER exos_dice_orders_touch BEFORE UPDATE ON public.exos_dice_orders
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_dice_orders IS
  'DICE import: DICE orders (amounts in cents, channel, promo, IP city / country), linked to the Exos event and fan. mig 20261106100000.';

-- ---------------------------------------------------------------------------
-- 3. Small helpers (service role only).
-- ---------------------------------------------------------------------------
-- A DICE ID as text (no whitespace, 1-200 chars), else NULL.
CREATE OR REPLACE FUNCTION public._exos_dice_id(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p ~ '^\S{1,200}$' THEN p END
$$;
REVOKE ALL ON FUNCTION public._exos_dice_id(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_id(text) TO service_role;

-- The id as Exos's narrower references take it (exos_event_imports.source_event_id,
-- guest external_ref 'dice:<ref>'): itself when it fits, else 'h' + its md5
-- (DICE ids are opaque and may carry '=' or '+').
CREATE OR REPLACE FUNCTION public._exos_dice_ref(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' THEN p WHEN p IS NOT NULL THEN 'h' || md5(p) END
$$;
REVOKE ALL ON FUNCTION public._exos_dice_ref(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_ref(text) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_dice_ts(p text)
RETURNS timestamptz LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
BEGIN
  IF p IS NULL OR length(p) > 40 THEN RETURN NULL; END IF;
  RETURN p::timestamptz;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_ts(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_ts(text) TO service_role;

-- {k: n} + {k: n}, numbers only.
CREATE OR REPLACE FUNCTION public._exos_dice_counts_merge(a jsonb, b jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
    FROM (SELECT k, sum(n) AS v
            FROM (SELECT e.key AS k, (e.value #>> '{}')::numeric AS n
                    FROM jsonb_each(CASE WHEN jsonb_typeof(a) = 'object' THEN a ELSE '{}'::jsonb END) e
                   WHERE jsonb_typeof(e.value) = 'number'
                  UNION ALL
                  SELECT e.key, (e.value #>> '{}')::numeric
                    FROM jsonb_each(CASE WHEN jsonb_typeof(b) = 'object' THEN b ELSE '{}'::jsonb END) e
                   WHERE jsonb_typeof(e.value) = 'number') x
           GROUP BY k) y
$$;
REVOKE ALL ON FUNCTION public._exos_dice_counts_merge(jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_counts_merge(jsonb, jsonb) TO service_role;

-- The event's 'DICE' door list (made when missing): no cap, no plus-ones,
-- outside the house capacity (DICE sold those seats, not Exos).
CREATE OR REPLACE FUNCTION public._exos_dice_list(p_event uuid, p_actor uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_list uuid; v_org uuid;
BEGIN
  SELECT id INTO v_list FROM public.exos_guest_lists
   WHERE event_id = p_event AND name = 'DICE' ORDER BY created_at, id LIMIT 1;
  IF v_list IS NULL THEN
    SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event;
    INSERT INTO public.exos_guest_lists (event_id, org_id, name, max_plus_ones, counts_toward_capacity, created_by)
    VALUES (p_event, v_org, 'DICE', 0, false, p_actor)
    RETURNING id INTO v_list;
  END IF;
  RETURN v_list;
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_list(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_list(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Fans. THE CONSENT RULE lives here: the org's email list only when
--    DICE's optInPartners is the JSON boolean true.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_dice_fan_upsert(p_org uuid, f jsonb, OUT fan_id uuid, OUT outcome text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_email   text := lower(btrim(coalesce(f ->> 'email', '')));
  v_dice    text := public._exos_dice_id(f ->> 'dice_id');
  v_first   text := left(nullif(btrim(coalesce(f ->> 'first_name', '')), ''), 60);
  v_last    text := left(nullif(btrim(coalesce(f ->> 'last_name', '')), ''), 60);
  v_consent boolean := jsonb_typeof(f) = 'object' AND (f -> 'opt_in_partners') = 'true'::jsonb;
  x         public.exos_fans%ROWTYPE;
  v_new     boolean := false;
BEGIN
  outcome := 'none';
  IF jsonb_typeof(f) IS DISTINCT FROM 'object' OR v_email !~ '^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$' OR length(v_email) > 254 THEN
    RETURN;  -- no usable email: a ticket holder without a fan profile
  END IF;
  INSERT INTO public.exos_fans (org_id, email, first_name, last_name, source)
  VALUES (p_org, v_email, v_first, v_last, 'dice')
  ON CONFLICT (org_id, email) DO NOTHING
  RETURNING * INTO x;
  v_new := x.id IS NOT NULL;
  IF NOT v_new THEN
    SELECT * INTO x FROM public.exos_fans WHERE org_id = p_org AND email = v_email FOR UPDATE;
    -- Names only fill gaps; a profile staff discarded stays discarded.
    IF x.discarded_at IS NULL AND ((x.first_name IS NULL AND v_first IS NOT NULL) OR (x.last_name IS NULL AND v_last IS NOT NULL)) THEN
      UPDATE public.exos_fans SET first_name = coalesce(first_name, v_first), last_name = coalesce(last_name, v_last)
       WHERE id = x.id;
    END IF;
  END IF;
  fan_id := x.id;
  outcome := CASE WHEN v_new THEN 'created' ELSE 'updated' END;

  IF x.discarded_at IS NULL THEN
    IF v_consent AND x.email_opt_in_at IS NULL AND x.email_opt_out_at IS NULL THEN
      -- The fan's own choice on DICE (optInPartners): the one non-Exos action
      -- the consent guard lets through, never over an Exos unsubscribe.
      PERFORM set_config('exos.fan_consent_action', 'on', true);
      UPDATE public.exos_fans SET email_opt_in_at = now(), email_opt_in_source = 'dice:optInPartners' WHERE id = x.id;
      PERFORM set_config('exos.fan_consent_action', '', true);
      outcome := outcome || '+consent';
    ELSIF (f -> 'opt_in_partners') = 'false'::jsonb AND x.email_opt_in_source = 'dice:optInPartners'
          AND x.email_opt_out_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM public.exos_signup_submissions s
                           WHERE s.fan_id = x.id AND s.email_requested AND s.confirmed_at IS NOT NULL) THEN
      -- DICE now says no: the consent that came from DICE goes.
      PERFORM set_config('exos.fan_consent_action', 'on', true);
      UPDATE public.exos_fans SET email_opt_in_at = NULL, email_opt_in_source = NULL WHERE id = x.id;
      PERFORM set_config('exos.fan_consent_action', '', true);
      outcome := outcome || '+withdrawn';
    END IF;
  END IF;

  IF v_dice IS NOT NULL THEN
    INSERT INTO public.exos_dice_id_map (org_id, entity, dice_id, exos_id, data)
    VALUES (p_org, 'fan', v_dice, x.id, jsonb_build_object('opt_in_partners', f -> 'opt_in_partners'))
    ON CONFLICT (org_id, entity, dice_id) DO UPDATE
       SET exos_id = EXCLUDED.exos_id, data = EXCLUDED.data, updated_at = now();
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_fan_upsert(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_fan_upsert(uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Events: a draft link-out Exos event per upcoming DICE event.
-- ---------------------------------------------------------------------------
-- Answers created | updated | past | invalid. Same "upcoming" rule as
-- _shared/dice/map.ts isUpcomingEvent.
CREATE OR REPLACE FUNCTION public._exos_dice_event_upsert(p_org uuid, p_actor uuid, e jsonb)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_id      text := public._exos_dice_id(e ->> 'dice_id');
  v_state   text := e ->> 'state';
  v_starts  timestamptz := public._exos_dice_ts(e ->> 'starts_at');
  v_ends    timestamptz := public._exos_dice_ts(e ->> 'ends_at');
  v_off     timestamptz := public._exos_dice_ts(e ->> 'off_sale_at');
  v_name    text := left(nullif(btrim(coalesce(e ->> 'name', '')), ''), 200);
  v_url     text := nullif(btrim(coalesce(e ->> 'url', '')), '');
  v_cur     text := upper(nullif(btrim(coalesce(e ->> 'currency', '')), ''));
  v_tz      text := nullif(btrim(coalesce(e #>> '{venue,timezone}', '')), '');
  v_img     text := nullif(btrim(coalesce(e ->> 'image_url', '')), '');
  v_cancel  boolean;
  v_over    boolean;
  v_src     text;
  v_types   jsonb;
  v_min     numeric;
  v_max     numeric;
  v_event   uuid;
  v_out     text;
  v_addr    jsonb;
  v_moved   boolean := false;
  i         public.exos_event_imports%ROWTYPE;
  ev        public.exos_events%ROWTYPE;
  t         jsonb;
BEGIN
  IF v_id IS NULL THEN RETURN 'invalid'; END IF;
  IF v_ends IS NOT NULL AND v_starts IS NOT NULL AND v_ends < v_starts THEN v_ends := NULL; END IF;
  v_cancel := v_state = 'CANCELLED';
  v_over := v_state = 'ARCHIVED'
            OR coalesce(v_ends, v_starts + interval '6 hours') < now() - interval '1 day';
  v_src := CASE WHEN v_cancel THEN 'cancelled'
                WHEN v_over THEN 'ended'
                WHEN v_state = 'APPROVED' AND (v_off IS NULL OR v_off > now()) THEN 'on_sale'
                ELSE 'unknown' END;
  IF v_url IS NULL OR v_url !~ '^https://[^\s/]+\.[^\s]+$' OR length(v_url) > 500 THEN
    v_url := 'https://dice.fm';   -- DICE didn't send the event page (hidden or restricted): its home
  END IF;
  IF v_cur IS NOT NULL AND v_cur !~ '^[A-Z]{3}$' THEN v_cur := NULL; END IF;
  IF v_tz IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_tz) THEN v_tz := NULL; END IF;
  IF v_img IS NOT NULL AND (v_img !~ '^https://[^\s/]+\.[^\s]+$' OR length(v_img) > 1000) THEN v_img := NULL; END IF;

  -- Display-only ticket types (what a buyer pays, in major units; never Exos tiers).
  SELECT public._exos_link_out_types(coalesce(jsonb_agg(jsonb_build_object(
           'name', x ->> 'name',
           'min_price', round(lo / 100.0, 2), 'max_price', round(hi / 100.0, 2),
           'sold_out', false, 'free', coalesce(hi, 0) = 0) ORDER BY ord), '[]'::jsonb)),
         min(lo) / 100.0, max(hi) / 100.0
    INTO v_types, v_min, v_max
    FROM (SELECT x, ord,
                 (SELECT min(p) FROM unnest(ARRAY[(x ->> 'price_cents')::numeric]
                    || ARRAY(SELECT (pt ->> 'price_cents')::numeric FROM jsonb_array_elements(coalesce(x -> 'price_tiers', '[]')) pt
                              WHERE (pt ->> 'price_cents') ~ '^[0-9]{1,9}$')) p WHERE p >= 0) AS lo,
                 (SELECT max(p) FROM unnest(ARRAY[(x ->> 'price_cents')::numeric]
                    || ARRAY(SELECT (pt ->> 'price_cents')::numeric FROM jsonb_array_elements(coalesce(x -> 'price_tiers', '[]')) pt
                              WHERE (pt ->> 'price_cents') ~ '^[0-9]{1,9}$')) p WHERE p >= 0) AS hi
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e -> 'ticket_types') = 'array' THEN e -> 'ticket_types' ELSE '[]' END)
                 WITH ORDINALITY AS a(x, ord)
           WHERE ord <= 50 AND jsonb_typeof(x) = 'object' AND (x -> 'archived') IS DISTINCT FROM 'true'::jsonb
             AND coalesce(x ->> 'price_cents', '0') ~ '^[0-9]{1,9}$') q;
  v_types := coalesce(v_types, '[]'::jsonb);

  SELECT m.exos_id INTO v_event FROM public.exos_dice_id_map m
    JOIN public.exos_events x ON x.id = m.exos_id AND x.org_id = p_org
   WHERE m.org_id = p_org AND m.entity = 'event' AND m.dice_id = v_id;

  IF v_event IS NULL AND NOT v_cancel AND NOT v_over THEN
    v_addr := jsonb_strip_nulls(jsonb_build_object(
      'street', left(nullif(btrim(e #>> '{venue,street}'), ''), 200),
      'city', left(nullif(btrim(e #>> '{venue,city}'), ''), 120),
      'region', left(nullif(btrim(coalesce(e #>> '{venue,state}', e #>> '{venue,region}')), ''), 120),
      'postal', left(nullif(btrim(e #>> '{venue,postal}'), ''), 20),
      'country', left(nullif(btrim(e #>> '{venue,country}'), ''), 60)));
    INSERT INTO public.exos_events (org_id, name, slug, status, starts_at, ends_at, timezone, currency,
                                    venue_name, venue_address, description, image_url, format,
                                    total_tickets, tickets_sold, created_by,
                                    link_out, ticket_backend, external_ticket_url, primary_source)
    VALUES (p_org, coalesce(v_name, 'DICE event'), public._exos_link_out_slug(coalesce(v_name, 'dice-event')), 'draft',
            v_starts, v_ends, v_tz, lower(coalesce(v_cur, 'USD')),
            left(nullif(btrim(coalesce(e #>> '{venue,name}', '')), ''), 200),
            CASE WHEN v_addr = '{}'::jsonb THEN NULL ELSE v_addr END,
            left(nullif(btrim(coalesce(e ->> 'description', '')), ''), 20000),
            v_img, 'in_person', 0, 0, p_actor,
            true, 'dice', v_url, 'dice')
    RETURNING id INTO v_event;
    INSERT INTO public.exos_event_imports (event_id, org_id, platform, source_event_id, source_url, origin, source_status,
                                           price_min, price_max, currency, is_free, ticket_types, checks_enabled,
                                           source_starts_at, last_checked_at, last_ok_at, imported_by)
    VALUES (v_event, p_org, 'dice', public._exos_dice_ref(v_id), v_url, 'account', v_src,
            v_min, v_max, v_cur, coalesce(v_max, 0) = 0 AND jsonb_array_length(v_types) > 0, v_types, false,
            v_starts, now(), now(), p_actor);
    v_out := 'created';
  ELSIF v_event IS NOT NULL THEN
    -- Again: what DICE owns (status, schedule, prices, link) follows DICE;
    -- what the organizer may have edited (name, text, image, venue) stays.
    SELECT * INTO i FROM public.exos_event_imports WHERE event_id = v_event FOR UPDATE;
    SELECT * INTO ev FROM public.exos_events WHERE id = v_event FOR UPDATE;
    IF v_starts IS NOT NULL AND i.source_starts_at IS NOT NULL AND NOT v_cancel
       AND abs(extract(epoch FROM v_starts - i.source_starts_at)) >= 60 THEN
      v_moved := true;
      UPDATE public.exos_events SET starts_at = v_starts, ends_at = v_ends WHERE id = v_event;
    END IF;
    IF v_cancel AND ev.status <> 'cancelled' THEN
      UPDATE public.exos_events SET status = 'cancelled' WHERE id = v_event;
    END IF;
    IF ev.external_ticket_url IS DISTINCT FROM v_url THEN
      UPDATE public.exos_events SET external_ticket_url = v_url WHERE id = v_event;
    END IF;
    UPDATE public.exos_event_imports
       SET source_url = v_url, source_status = v_src, price_min = v_min, price_max = v_max,
           currency = coalesce(v_cur, currency), is_free = coalesce(v_max, 0) = 0 AND jsonb_array_length(v_types) > 0,
           ticket_types = v_types, source_starts_at = coalesce(v_starts, source_starts_at),
           previous_starts_at = CASE WHEN v_moved THEN ev.starts_at ELSE previous_starts_at END,
           rescheduled_at = CASE WHEN v_moved THEN now() ELSE rescheduled_at END,
           last_checked_at = now(), last_ok_at = now(), updated_at = now()
     WHERE event_id = v_event;
    v_out := 'updated';
  ELSE
    v_out := 'past';
  END IF;

  INSERT INTO public.exos_dice_id_map (org_id, entity, dice_id, exos_id, event_id, data)
  VALUES (p_org, 'event', v_id, v_event, v_event, jsonb_strip_nulls(jsonb_build_object(
            'name', v_name, 'state', v_state, 'live_id', e ->> 'live_id', 'hidden', e -> 'hidden',
            'announce_at', e ->> 'announce_at', 'on_sale_at', e ->> 'on_sale_at', 'off_sale_at', e ->> 'off_sale_at',
            'starts_at', v_starts, 'ends_at', v_ends, 'allocation', e -> 'allocation', 'currency', v_cur,
            'url', nullif(v_url, 'https://dice.fm'), 'updated_at', e ->> 'updated_at',
            'artists', e -> 'artists', 'genres', e -> 'genres', 'genre_types', e -> 'genre_types',
            'images', e -> 'images', 'ticket_pools', e -> 'ticket_pools', 'venue', e -> 'venue',
            'venue_count', CASE WHEN jsonb_typeof(e -> 'venues') = 'array' THEN jsonb_array_length(e -> 'venues') END,
            'venue_space', e -> 'venue_space', 'products', e -> 'products', 'social_links', e -> 'social_links',
            'promoters', e -> 'promoters')))
  ON CONFLICT (org_id, entity, dice_id) DO UPDATE
     SET exos_id = coalesce(EXCLUDED.exos_id, exos_dice_id_map.exos_id),
         event_id = coalesce(EXCLUDED.event_id, exos_dice_id_map.event_id),
         data = EXCLUDED.data, updated_at = now();

  FOR t IN SELECT x FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e -> 'ticket_types') = 'array' THEN e -> 'ticket_types' ELSE '[]' END) x
            WHERE jsonb_typeof(x) = 'object' AND public._exos_dice_id(x ->> 'dice_id') IS NOT NULL LIMIT 50 LOOP
    INSERT INTO public.exos_dice_id_map (org_id, entity, dice_id, exos_id, event_id, parent_dice_id, data)
    VALUES (p_org, 'ticket_type', t ->> 'dice_id', NULL, v_event, v_id, t - 'dice_id')
    ON CONFLICT (org_id, entity, dice_id) DO UPDATE
       SET event_id = coalesce(EXCLUDED.event_id, exos_dice_id_map.event_id), parent_dice_id = EXCLUDED.parent_dice_id,
           data = EXCLUDED.data, updated_at = now();
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_event_upsert(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_event_upsert(uuid, uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Tickets -> door entries; returns void them; transfers move the holder.
-- ---------------------------------------------------------------------------
-- Answers created | updated | no_event | invalid | error (+ the fan's outcome
-- after a '/', e.g. 'created/created+consent').
CREATE OR REPLACE FUNCTION public._exos_dice_ticket_upsert(p_org uuid, p_actor uuid, t jsonb, p_event_dice text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tid     text := public._exos_dice_id(t ->> 'dice_id');
  v_ev_dice text;
  v_event   uuid;
  v_fan     record;
  v_list    uuid;
  v_ref     text;
  v_code    text := public._exos_door_code(t ->> 'code');
  v_name    text;
  v_email   text;
  v_phone   text;
  v_label   text := left(nullif(btrim(coalesce(t ->> 'ticket_type_name', '')), ''), 80);
  v_ret     boolean;
  v_retat   timestamptz;
  g         public.exos_guest_list_entries%ROWTYPE;
  v_guest   uuid;
  v_out     text;
  v_data    jsonb;
BEGIN
  IF jsonb_typeof(t) IS DISTINCT FROM 'object' OR v_tid IS NULL THEN RETURN 'invalid'; END IF;
  v_ref := 'dice:' || public._exos_dice_ref(v_tid);
  v_ev_dice := coalesce(public._exos_dice_id(t ->> 'dice_event_id'), public._exos_dice_id(p_event_dice),
                        (SELECT m.parent_dice_id FROM public.exos_dice_id_map m
                          WHERE m.org_id = p_org AND m.entity = 'ticket_type' AND m.dice_id = t ->> 'ticket_type_id'),
                        (SELECT m.parent_dice_id FROM public.exos_dice_id_map m
                          WHERE m.org_id = p_org AND m.entity = 'ticket' AND m.dice_id = v_tid));
  SELECT m.exos_id INTO v_event FROM public.exos_dice_id_map m
    JOIN public.exos_events x ON x.id = m.exos_id AND x.org_id = p_org
   WHERE m.org_id = p_org AND m.entity = 'event' AND m.dice_id = v_ev_dice;

  SELECT * INTO v_fan FROM public._exos_dice_fan_upsert(p_org, t -> 'holder');
  v_name := left(nullif(btrim(concat_ws(' ', t #>> '{holder,first_name}', t #>> '{holder,last_name}')), ''), 80);
  v_email := lower(nullif(btrim(coalesce(t #>> '{holder,email}', '')), ''));
  v_email := CASE WHEN v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(v_email) <= 254 THEN v_email END;
  v_phone := nullif(btrim(coalesce(t #>> '{holder,phone}', '')), '');
  v_phone := CASE WHEN v_phone ~ '^[0-9+() .-]{3,32}$' THEN v_phone END;
  SELECT min(public._exos_dice_ts(m.data ->> 'returned_at')), count(*) > 0 INTO v_retat, v_ret
    FROM public.exos_dice_id_map m
   WHERE m.org_id = p_org AND m.entity = 'return' AND m.parent_dice_id = v_tid;
  v_data := jsonb_strip_nulls(jsonb_build_object(
    'ticket_type_id', t ->> 'ticket_type_id', 'ticket_type_name', v_label, 'claimed_at', t ->> 'claimed_at',
    'full_price_cents', t -> 'full_price_cents', 'commission_cents', t -> 'commission_cents',
    'dice_commission_cents', t -> 'dice_commission_cents', 'total_cents', t -> 'total_cents', 'fees', t -> 'fees',
    'seat', t ->> 'seat', 'price_tier', t -> 'price_tier', 'survey_answers', t -> 'survey_answers',
    'extras', t -> 'extras', 'holder_dice_id', t #>> '{holder,dice_id}', 'has_code', v_code IS NOT NULL,
    'transferred_at', t ->> 'transferred_at'));

  IF v_event IS NULL THEN
    v_out := 'no_event';    -- a past (or unknown) DICE event: the fan came in, no door entry
  ELSE
    BEGIN
      v_list := public._exos_dice_list(v_event, p_actor);
      -- The ticket, or an entry a CSV import already made from the same code.
      SELECT * INTO g FROM public.exos_guest_list_entries x
       WHERE x.event_id = v_event
         AND (x.external_ref = v_ref OR (v_code IS NOT NULL AND x.external_code = v_code AND x.external_ref IS NULL))
       ORDER BY (x.external_ref = v_ref) DESC NULLS LAST
       LIMIT 1
       FOR UPDATE;
      IF g.id IS NULL THEN
        v_guest := public._exos_guest_insert(v_list, coalesce(v_name, 'DICE ticket holder'), v_email, v_phone, 0, NULL, p_actor, NULL);
        UPDATE public.exos_guest_list_entries
           SET external_ref = v_ref, external_code = v_code, ticket_label = v_label, source = 'DICE',
               voided_at = CASE WHEN v_ret THEN coalesce(v_retat, now()) END,
               void_reason = CASE WHEN v_ret THEN 'returned on DICE' END
         WHERE id = v_guest;
        v_out := 'created';
      ELSE
        v_guest := g.id;
        UPDATE public.exos_guest_list_entries
           SET external_ref  = v_ref,
               external_code = coalesce(v_code, external_code),
               guest_name    = coalesce(v_name, guest_name),
               email         = coalesce(v_email, email),
               phone         = coalesce(v_phone, phone),
               ticket_label  = coalesce(v_label, ticket_label),
               source        = coalesce(source, 'DICE'),
               -- A return is final: never un-voided here.
               voided_at     = CASE WHEN v_ret THEN coalesce(voided_at, v_retat, now()) ELSE voided_at END,
               void_reason   = CASE WHEN v_ret AND voided_at IS NULL THEN 'returned on DICE' ELSE void_reason END
         WHERE id = g.id;
        v_out := 'updated';
      END IF;
    EXCEPTION
      WHEN unique_violation OR check_violation OR raise_exception THEN
        -- e.g. a code another entry of the event holds, or a cancelled event.
        v_guest := NULL;
        v_out := 'error';
    END;
  END IF;

  INSERT INTO public.exos_dice_id_map (org_id, entity, dice_id, exos_id, event_id, parent_dice_id, data)
  VALUES (p_org, 'ticket', v_tid, v_guest, v_event, v_ev_dice, v_data)
  ON CONFLICT (org_id, entity, dice_id) DO UPDATE
     SET exos_id = coalesce(EXCLUDED.exos_id, exos_dice_id_map.exos_id),
         event_id = coalesce(EXCLUDED.event_id, exos_dice_id_map.event_id),
         parent_dice_id = coalesce(EXCLUDED.parent_dice_id, exos_dice_id_map.parent_dice_id),
         data = exos_dice_id_map.data || EXCLUDED.data, updated_at = now();
  IF v_guest IS NOT NULL AND v_ret THEN
    UPDATE public.exos_dice_id_map SET exos_id = v_guest, updated_at = now()
     WHERE org_id = p_org AND entity = 'return' AND parent_dice_id = v_tid AND exos_id IS DISTINCT FROM v_guest;
  END IF;
  RETURN v_out || '/' || coalesce(v_fan.outcome, 'none');
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_ticket_upsert(uuid, uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_ticket_upsert(uuid, uuid, jsonb, text) TO service_role;

-- Answers voided | pending (its ticket isn't here yet) | invalid.
CREATE OR REPLACE FUNCTION public._exos_dice_return_upsert(p_org uuid, r jsonb, p_order text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_rid   text := public._exos_dice_id(r ->> 'dice_id');
  v_tid   text := public._exos_dice_id(r ->> 'ticket_id');
  v_at    timestamptz := coalesce(public._exos_dice_ts(r ->> 'returned_at'), now());
  v_guest uuid;
BEGIN
  IF jsonb_typeof(r) IS DISTINCT FROM 'object' OR v_rid IS NULL OR v_tid IS NULL THEN RETURN 'invalid'; END IF;
  SELECT m.exos_id INTO v_guest FROM public.exos_dice_id_map m
    JOIN public.exos_guest_list_entries g ON g.id = m.exos_id AND g.org_id = p_org
   WHERE m.org_id = p_org AND m.entity = 'ticket' AND m.dice_id = v_tid;
  IF v_guest IS NOT NULL THEN
    UPDATE public.exos_guest_list_entries
       SET voided_at = coalesce(voided_at, v_at), void_reason = coalesce(void_reason, 'returned on DICE')
     WHERE id = v_guest AND voided_at IS NULL;
  END IF;
  INSERT INTO public.exos_dice_id_map (org_id, entity, dice_id, exos_id, parent_dice_id, data)
  VALUES (p_org, 'return', v_rid, v_guest, v_tid, jsonb_strip_nulls(jsonb_build_object(
            'returned_at', v_at, 'reason', left(r ->> 'reason', 200),
            'order_id', coalesce(public._exos_dice_id(r ->> 'order_id'), public._exos_dice_id(p_order)))))
  ON CONFLICT (org_id, entity, dice_id) DO UPDATE
     SET exos_id = coalesce(EXCLUDED.exos_id, exos_dice_id_map.exos_id), parent_dice_id = EXCLUDED.parent_dice_id,
         data = EXCLUDED.data, updated_at = now();
  RETURN CASE WHEN v_guest IS NOT NULL THEN 'voided' ELSE 'pending' END;
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_return_upsert(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_return_upsert(uuid, jsonb, text) TO service_role;

-- An order, its buyer, its tickets and its returns. Answers the counts.
CREATE OR REPLACE FUNCTION public._exos_dice_order_upsert(p_org uuid, p_actor uuid, o jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_oid   text := public._exos_dice_id(o ->> 'dice_id');
  v_ev    text := public._exos_dice_id(o ->> 'dice_event_id');
  v_event uuid;
  v_cur   text;
  v_fan   record;
  v_new   boolean;
  v_c     jsonb := '{}'::jsonb;
  v_res   text;
  x       jsonb;
  v_int   CONSTANT text := '^-?[0-9]{1,10}$';
BEGIN
  IF jsonb_typeof(o) IS DISTINCT FROM 'object' OR v_oid IS NULL THEN RETURN '{"invalid": 1}'::jsonb; END IF;
  SELECT m.exos_id, nullif(upper(m.data ->> 'currency'), '') INTO v_event, v_cur FROM public.exos_dice_id_map m
   WHERE m.org_id = p_org AND m.entity = 'event' AND m.dice_id = v_ev;
  IF v_event IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = v_event AND org_id = p_org) THEN
    v_event := NULL;
  END IF;
  SELECT * INTO v_fan FROM public._exos_dice_fan_upsert(p_org, o -> 'fan');
  IF v_fan.outcome LIKE '%+consent' THEN v_c := v_c || '{"fans_consented": 1}'; END IF;
  IF v_fan.outcome LIKE 'created%' THEN v_c := public._exos_dice_counts_merge(v_c, '{"fans_created": 1}'); END IF;

  INSERT INTO public.exos_dice_orders AS d (org_id, dice_id, dice_event_id, event_id, dice_fan_id, fan_id, purchased_at, quantity,
                                           sales_channel, currency, full_price_cents, commission_cents, dice_commission_cents,
                                           total_cents, fees, adjustments, promo_code, promo_name, promo_discount_cents,
                                           promo_type, ip_city, ip_country, tickets)
  VALUES (p_org, v_oid, v_ev, v_event, public._exos_dice_id(o #>> '{fan,dice_id}'), v_fan.fan_id,
          public._exos_dice_ts(o ->> 'purchased_at'),
          CASE WHEN (o ->> 'quantity') ~ '^[0-9]{1,6}$' AND (o ->> 'quantity')::int <= 100000 THEN (o ->> 'quantity')::int END,
          left(o ->> 'sales_channel', 20), CASE WHEN v_cur ~ '^[A-Z]{3}$' THEN v_cur END,
          CASE WHEN (o ->> 'full_price_cents') ~ v_int THEN (o ->> 'full_price_cents')::bigint::int END,
          CASE WHEN (o ->> 'commission_cents') ~ v_int THEN (o ->> 'commission_cents')::bigint::int END,
          CASE WHEN (o ->> 'dice_commission_cents') ~ v_int THEN (o ->> 'dice_commission_cents')::bigint::int END,
          CASE WHEN (o ->> 'total_cents') ~ v_int THEN (o ->> 'total_cents')::bigint::int END,
          CASE WHEN jsonb_typeof(o -> 'fees') = 'array' AND jsonb_array_length(o -> 'fees') <= 30 THEN o -> 'fees' ELSE '[]' END,
          CASE WHEN jsonb_typeof(o -> 'adjustments') = 'array' AND jsonb_array_length(o -> 'adjustments') <= 30 THEN o -> 'adjustments' ELSE '[]' END,
          left(o ->> 'promo_code', 80), left(o ->> 'promo_name', 120),
          CASE WHEN (o ->> 'promo_discount_cents') ~ v_int THEN (o ->> 'promo_discount_cents')::bigint::int END,
          left(o ->> 'promo_type', 20), left(o ->> 'ip_city', 120), left(o ->> 'ip_country', 60),
          CASE WHEN jsonb_typeof(o -> 'tickets') = 'array' THEN jsonb_array_length(o -> 'tickets') ELSE 0 END)
  ON CONFLICT (org_id, dice_id) DO UPDATE
     SET dice_event_id = EXCLUDED.dice_event_id, event_id = coalesce(EXCLUDED.event_id, d.event_id),
         dice_fan_id = EXCLUDED.dice_fan_id, fan_id = coalesce(EXCLUDED.fan_id, d.fan_id),
         purchased_at = EXCLUDED.purchased_at, quantity = EXCLUDED.quantity, sales_channel = EXCLUDED.sales_channel,
         currency = coalesce(EXCLUDED.currency, d.currency), full_price_cents = EXCLUDED.full_price_cents,
         commission_cents = EXCLUDED.commission_cents, dice_commission_cents = EXCLUDED.dice_commission_cents,
         total_cents = EXCLUDED.total_cents, fees = EXCLUDED.fees, adjustments = EXCLUDED.adjustments,
         promo_code = EXCLUDED.promo_code, promo_name = EXCLUDED.promo_name,
         promo_discount_cents = EXCLUDED.promo_discount_cents, promo_type = EXCLUDED.promo_type,
         ip_city = EXCLUDED.ip_city, ip_country = EXCLUDED.ip_country, tickets = EXCLUDED.tickets, updated_at = now()
  RETURNING (xmax = 0) INTO v_new;
  v_c := public._exos_dice_counts_merge(v_c, jsonb_build_object(CASE WHEN v_new THEN 'created' ELSE 'updated' END, 1));

  FOR x IN SELECT y FROM jsonb_array_elements(CASE WHEN jsonb_typeof(o -> 'tickets') = 'array' THEN o -> 'tickets' ELSE '[]' END) y LIMIT 100 LOOP
    v_res := public._exos_dice_ticket_upsert(p_org, p_actor, x, v_ev);
    v_c := public._exos_dice_counts_merge(v_c, jsonb_build_object('tickets_' || split_part(v_res, '/', 1), 1));
    IF v_res LIKE '%+consent' THEN v_c := public._exos_dice_counts_merge(v_c, '{"fans_consented": 1}'); END IF;
    IF split_part(v_res, '/', 2) LIKE 'created%' THEN v_c := public._exos_dice_counts_merge(v_c, '{"fans_created": 1}'); END IF;
  END LOOP;
  FOR x IN SELECT y FROM jsonb_array_elements(CASE WHEN jsonb_typeof(o -> 'returns') = 'array' THEN o -> 'returns' ELSE '[]' END) y LIMIT 100 LOOP
    v_c := public._exos_dice_counts_merge(v_c, jsonb_build_object('returns_' || public._exos_dice_return_upsert(p_org, x, v_oid), 1));
  END LOOP;
  RETURN v_c;
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_order_upsert(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_order_upsert(uuid, uuid, jsonb) TO service_role;

-- A transfer: each ticket again, with its new holder. Answers the counts.
CREATE OR REPLACE FUNCTION public._exos_dice_transfer_upsert(p_org uuid, p_actor uuid, tr jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_c jsonb := '{}'::jsonb; x jsonb; v_res text;
BEGIN
  IF jsonb_typeof(tr) IS DISTINCT FROM 'object' OR public._exos_dice_id(tr ->> 'dice_id') IS NULL THEN RETURN '{"invalid": 1}'::jsonb; END IF;
  FOR x IN SELECT y FROM jsonb_array_elements(CASE WHEN jsonb_typeof(tr -> 'tickets') = 'array' THEN tr -> 'tickets' ELSE '[]' END) y LIMIT 100 LOOP
    v_res := public._exos_dice_ticket_upsert(p_org, p_actor, x || jsonb_build_object('transferred_at', tr ->> 'transferred_at'));
    v_c := public._exos_dice_counts_merge(v_c, jsonb_build_object('tickets_' || split_part(v_res, '/', 1), 1));
    IF v_res LIKE '%+consent' THEN v_c := public._exos_dice_counts_merge(v_c, '{"fans_consented": 1}'); END IF;
    IF split_part(v_res, '/', 2) LIKE 'created%' THEN v_c := public._exos_dice_counts_merge(v_c, '{"fans_created": 1}'); END IF;
  END LOOP;
  RETURN public._exos_dice_counts_merge(v_c, '{"transfers": 1}');
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_transfer_upsert(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_transfer_upsert(uuid, uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Connect, disconnect, the token (service role: exos-dice-import, which
--    verified the user's JWT and checked the token with DICE).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_dice_connect(
  p_org_id uuid, p_user_id uuid, p_token text, p_account_id text, p_account_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_name   text := 'exos_dice:' || p_org_id::text;
  v_secret uuid;
  c        public.exos_dice_connections%ROWTYPE;
  v_acct   text := left(nullif(btrim(coalesce(p_account_name, '')), ''), 120);
  v_same   boolean;
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_dice_connect: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_token IS NULL OR length(p_token) NOT BETWEEN 16 AND 2048 OR p_token !~ '^[A-Za-z0-9._~+/=-]+$' THEN
    RAISE EXCEPTION 'exos_dice_connect: that doesn''t look like a DICE API token' USING ERRCODE = '22023';
  END IF;
  IF p_account_id IS NULL OR p_account_id !~ '^\S{1,200}$' THEN
    RAISE EXCEPTION 'exos_dice_connect: bad DICE account' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO c FROM public.exos_dice_connections WHERE org_id = p_org_id FOR UPDATE;
  v_secret := c.secret_id;
  IF v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_secret) THEN
    SELECT id INTO v_secret FROM vault.secrets WHERE name = v_name;
  END IF;
  IF v_secret IS NULL THEN
    v_secret := vault.create_secret(p_token, v_name, 'Exos: DICE (MIO) API token (read-only import)');
  ELSE
    PERFORM vault.update_secret(v_secret, p_token);
  END IF;
  -- The same DICE account keeps its cursors; another one starts over.
  v_same := c.org_id IS NOT NULL AND c.account_id = p_account_id;
  INSERT INTO public.exos_dice_connections AS x (org_id, secret_id, status, account_id, account_name, connected_by, connected_at)
  VALUES (p_org_id, v_secret, 'connected', p_account_id, v_acct, p_user_id, now())
  ON CONFLICT (org_id) DO UPDATE
     SET secret_id = EXCLUDED.secret_id, status = 'connected', account_id = EXCLUDED.account_id,
         account_name = EXCLUDED.account_name, connected_by = EXCLUDED.connected_by, connected_at = now(),
         disconnected_at = NULL, last_error = NULL,
         cursors = CASE WHEN v_same THEN x.cursors ELSE '{}'::jsonb END,
         full_sync_done_at = CASE WHEN v_same THEN x.full_sync_done_at END,
         -- a run still going for the old token loses its lease: its writes are refused
         lease_id = NULL, lease_until = NULL, run_id = NULL;
  UPDATE public.exos_dice_import_runs SET status = 'error', error = 'reconnected', finished_at = now()
   WHERE org_id = p_org_id AND status = 'running';
  RETURN jsonb_build_object('connected', true, 'account_name', v_acct, 'same_account', v_same);
END $$;
REVOKE ALL ON FUNCTION public.exos_dice_connect(uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_dice_connect(uuid, uuid, text, text, text) TO service_role;

-- The token is deleted from Vault; what was imported stays (events, door
-- entries, fans, the id map), so a reconnect re-run updates in place.
CREATE OR REPLACE FUNCTION public.exos_dice_disconnect(p_org_id uuid, p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_secret uuid;
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_dice_disconnect: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT secret_id INTO v_secret FROM public.exos_dice_connections WHERE org_id = p_org_id FOR UPDATE;
  DELETE FROM vault.secrets WHERE id = v_secret OR name = 'exos_dice:' || p_org_id::text;
  UPDATE public.exos_dice_connections
     SET secret_id = NULL, status = 'disconnected', disconnected_at = now(),
         lease_id = NULL, lease_until = NULL, run_id = NULL
   WHERE org_id = p_org_id;
  UPDATE public.exos_dice_import_runs SET status = 'error', error = 'disconnected', finished_at = now()
   WHERE org_id = p_org_id AND status = 'running';
  RETURN jsonb_build_object('connected', false);
END $$;
REVOKE ALL ON FUNCTION public.exos_dice_disconnect(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_dice_disconnect(uuid, uuid) TO service_role;

-- The token and cursors for a dry run (owner / manager). NULL row when not connected.
CREATE OR REPLACE FUNCTION public.exos_dice_token(p_org_id uuid, p_user_id uuid)
RETURNS TABLE (token text, cursors jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_dice_token: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT d.decrypted_secret::text, c.cursors FROM public.exos_dice_connections c
    JOIN vault.decrypted_secrets d ON d.id = c.secret_id
   WHERE c.org_id = p_org_id AND c.status <> 'disconnected';
END $$;
REVOKE ALL ON FUNCTION public.exos_dice_token(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_dice_token(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. A sync run: claim (lease + run row + token), apply pages, finish.
-- ---------------------------------------------------------------------------
-- p_org_id NULL: the cron; connected orgs that are due (a full first pass
--   still going: every run; else every 6 hours), oldest first.
-- p_org_id set: "Sync now" (dashboard) or POST /v1/dice-import/sync (api) by
--   p_user_id, owner / manager; refused while a run holds the lease or within
--   a minute of the last one.
CREATE OR REPLACE FUNCTION public.exos_dice_sync_claim(
  p_org_id uuid DEFAULT NULL, p_user_id uuid DEFAULT NULL, p_trigger text DEFAULT 'cron', p_limit integer DEFAULT 5
) RETURNS TABLE (org_id uuid, token text, cursors jsonb, lease_id uuid, run_id uuid, kind text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
#variable_conflict use_column
DECLARE
  c       public.exos_dice_connections%ROWTYPE;
  v_tok   text;
  v_lease uuid;
  v_run   uuid;
  v_kind  text;
BEGIN
  IF p_trigger IS NULL OR p_trigger NOT IN ('dashboard', 'api', 'cron') THEN
    RAISE EXCEPTION 'exos_dice_sync_claim: bad trigger' USING ERRCODE = '22023';
  END IF;
  IF p_org_id IS NOT NULL THEN
    IF p_trigger = 'cron' OR coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'exos_dice_sync_claim: owner or manager only' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO c FROM public.exos_dice_connections x WHERE x.org_id = p_org_id FOR UPDATE;
    IF c.org_id IS NULL OR c.status = 'disconnected' THEN
      RAISE EXCEPTION 'exos_dice_sync_claim: connect DICE first' USING ERRCODE = '22023';
    END IF;
    IF c.lease_until IS NOT NULL AND c.lease_until > now() THEN
      RAISE EXCEPTION 'exos_dice_sync_claim: a DICE sync is already running' USING ERRCODE = '55000';
    END IF;
    IF c.last_sync_at IS NOT NULL AND c.last_sync_at > now() - interval '1 minute' THEN
      RAISE EXCEPTION 'exos_dice_sync_claim: synced less than a minute ago' USING ERRCODE = '55000';
    END IF;
  ELSIF p_trigger <> 'cron' THEN
    RAISE EXCEPTION 'exos_dice_sync_claim: name the organization' USING ERRCODE = '22023';
  END IF;

  FOR c IN
    SELECT * FROM public.exos_dice_connections x
     WHERE CASE WHEN p_org_id IS NOT NULL THEN x.org_id = p_org_id
                ELSE x.status = 'connected'
                     AND (x.lease_until IS NULL OR x.lease_until < now())
                     AND (x.full_sync_done_at IS NULL OR x.last_sync_at IS NULL OR x.last_sync_at < now() - interval '6 hours'
                          OR (x.cursors::text LIKE '%"after": "%'))
                     -- after an error, wait an hour (a bad token stays bad: status 'error' isn't picked)
                     AND (x.last_error IS NULL OR x.last_sync_at < now() - interval '1 hour') END
     ORDER BY x.last_sync_at NULLS FIRST, x.org_id
     LIMIT CASE WHEN p_org_id IS NOT NULL THEN 1 ELSE greatest(1, least(coalesce(p_limit, 5), 20)) END
     FOR UPDATE OF x SKIP LOCKED
  LOOP
    SELECT d.decrypted_secret INTO v_tok FROM vault.decrypted_secrets d WHERE d.id = c.secret_id;
    IF v_tok IS NULL THEN
      UPDATE public.exos_dice_connections x
         SET status = 'error', last_error = 'The DICE token is missing. Connect DICE again.', last_sync_at = now()
       WHERE x.org_id = c.org_id;
      IF p_org_id IS NOT NULL THEN
        RAISE EXCEPTION 'exos_dice_sync_claim: the DICE token is missing; connect again' USING ERRCODE = '22023';
      END IF;
      CONTINUE;
    END IF;
    v_lease := gen_random_uuid();
    v_kind := CASE WHEN c.full_sync_done_at IS NULL THEN 'full' ELSE 'incremental' END;
    -- A run whose function died keeps 'running' until its lease lapses; the lease is free now: close it.
    UPDATE public.exos_dice_import_runs r SET status = 'error', error = 'interrupted', finished_at = now()
     WHERE r.org_id = c.org_id AND r.status = 'running' AND NOT r.dry_run;
    INSERT INTO public.exos_dice_import_runs (org_id, kind, trigger, dry_run, status, started_by)
    VALUES (c.org_id, v_kind, p_trigger, false, 'running', CASE WHEN p_org_id IS NOT NULL THEN p_user_id END)
    RETURNING id INTO v_run;
    UPDATE public.exos_dice_connections x
       SET lease_id = v_lease, lease_until = now() + interval '5 minutes', run_id = v_run, last_sync_at = now()
     WHERE x.org_id = c.org_id;
    org_id := c.org_id; token := v_tok; cursors := c.cursors; lease_id := v_lease; run_id := v_run; kind := v_kind;
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_dice_sync_claim(uuid, uuid, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_dice_sync_claim(uuid, uuid, text, integer) TO service_role;

-- One page of one entity, and the entity's cursor, in one transaction.
--   p_page: {after: DICE's endCursor or null, done: the pass's last page,
--            pass_started_at}
-- A stale lease (another run, a reconnect, a disconnect) writes nothing.
CREATE OR REPLACE FUNCTION public.exos_dice_apply(
  p_org_id uuid, p_lease uuid, p_entity text, p_rows jsonb, p_page jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c        public.exos_dice_connections%ROWTYPE;
  v_actor  uuid;
  v_counts jsonb := '{}'::jsonb;
  r        jsonb;
  v_res    text;
  v_done   boolean := (p_page -> 'done') = 'true'::jsonb;
  v_after  text := p_page ->> 'after';
  v_pass   timestamptz := public._exos_dice_ts(p_page ->> 'pass_started_at');
  v_cur    jsonb;
BEGIN
  SELECT * INTO c FROM public.exos_dice_connections WHERE org_id = p_org_id FOR UPDATE;
  IF c.org_id IS NULL OR c.lease_id IS NULL OR p_lease IS DISTINCT FROM c.lease_id OR c.status = 'disconnected' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  IF p_entity IS NULL OR p_entity NOT IN ('events', 'tickets', 'orders', 'returns', 'transfers') THEN
    RAISE EXCEPTION 'exos_dice_apply: bad entity' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) > 100 THEN
    RAISE EXCEPTION 'exos_dice_apply: rows must be an array of at most 100' USING ERRCODE = '22023';
  END IF;
  IF v_pass IS NULL OR (v_after IS NOT NULL AND length(v_after) > 1000) OR (NOT v_done AND v_after IS NULL) THEN
    RAISE EXCEPTION 'exos_dice_apply: bad page state' USING ERRCODE = '22023';
  END IF;
  v_actor := coalesce((SELECT started_by FROM public.exos_dice_import_runs WHERE id = c.run_id), c.connected_by);

  FOR r IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    BEGIN
      CASE p_entity
        WHEN 'events' THEN
          v_counts := public._exos_dice_counts_merge(v_counts, jsonb_build_object(public._exos_dice_event_upsert(p_org_id, v_actor, r), 1));
        WHEN 'tickets' THEN
          v_res := public._exos_dice_ticket_upsert(p_org_id, v_actor, r);
          v_counts := public._exos_dice_counts_merge(v_counts, jsonb_build_object(split_part(v_res, '/', 1), 1));
          IF v_res LIKE '%+consent' THEN v_counts := public._exos_dice_counts_merge(v_counts, '{"fans_consented": 1}'); END IF;
          IF split_part(v_res, '/', 2) LIKE 'created%' THEN v_counts := public._exos_dice_counts_merge(v_counts, '{"fans_created": 1}'); END IF;
        WHEN 'orders' THEN
          v_counts := public._exos_dice_counts_merge(v_counts, public._exos_dice_order_upsert(p_org_id, v_actor, r));
        WHEN 'returns' THEN
          v_counts := public._exos_dice_counts_merge(v_counts, jsonb_build_object(public._exos_dice_return_upsert(p_org_id, r), 1));
        ELSE
          v_counts := public._exos_dice_counts_merge(v_counts, public._exos_dice_transfer_upsert(p_org_id, v_actor, r));
      END CASE;
    EXCEPTION
      WHEN unique_violation OR check_violation OR not_null_violation OR foreign_key_violation
           OR invalid_text_representation OR numeric_value_out_of_range OR raise_exception THEN
        v_counts := public._exos_dice_counts_merge(v_counts, '{"errors": 1}');
    END;
  END LOOP;
  v_counts := public._exos_dice_counts_merge(v_counts, jsonb_build_object('read', jsonb_array_length(p_rows)));

  v_cur := CASE WHEN v_done
                THEN jsonb_build_object('since', v_pass, 'after', NULL, 'pass_started_at', NULL)
                ELSE jsonb_build_object('since', c.cursors #> ARRAY[p_entity, 'since'], 'after', v_after, 'pass_started_at', v_pass) END;
  UPDATE public.exos_dice_connections
     SET cursors = jsonb_set(cursors, ARRAY[p_entity], v_cur, true), lease_until = now() + interval '5 minutes'
   WHERE org_id = p_org_id;
  UPDATE public.exos_dice_import_runs
     SET counts = jsonb_set(counts, ARRAY[p_entity], public._exos_dice_counts_merge(counts -> p_entity, v_counts), true)
   WHERE id = c.run_id;
  RETURN v_counts;
END $$;
REVOKE ALL ON FUNCTION public.exos_dice_apply(uuid, uuid, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_dice_apply(uuid, uuid, text, jsonb, jsonb) TO service_role;

-- The run's outcome. p_auth_failed: DICE refused the token (the connection
-- goes to 'error' until it is connected again; the cron skips it).
CREATE OR REPLACE FUNCTION public.exos_dice_sync_finish(
  p_org_id uuid, p_lease uuid, p_status text, p_error text DEFAULT NULL, p_warnings jsonb DEFAULT '[]'::jsonb,
  p_auth_failed boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c      public.exos_dice_connections%ROWTYPE;
  v_full boolean;
  v_warn jsonb;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('ok', 'partial', 'error') THEN
    RAISE EXCEPTION 'exos_dice_sync_finish: bad status' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO c FROM public.exos_dice_connections WHERE org_id = p_org_id FOR UPDATE;
  IF c.org_id IS NULL OR c.lease_id IS NULL OR p_lease IS DISTINCT FROM c.lease_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  v_full := (SELECT bool_and(c.cursors #>> ARRAY[e, 'since'] IS NOT NULL)
               FROM unnest(ARRAY['events', 'tickets', 'orders', 'returns', 'transfers']) e);
  SELECT coalesce(jsonb_agg(to_jsonb(left(w #>> '{}', 300))), '[]'::jsonb) INTO v_warn
    FROM (SELECT w FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_warnings) = 'array' THEN p_warnings ELSE '[]' END) w
           WHERE jsonb_typeof(w) = 'string' LIMIT 50) q;
  UPDATE public.exos_dice_import_runs
     SET status = p_status, finished_at = now(), error = left(nullif(btrim(coalesce(p_error, '')), ''), 300), errors = v_warn
   WHERE id = c.run_id;
  UPDATE public.exos_dice_connections
     SET lease_id = NULL, lease_until = NULL, run_id = NULL,
         status = CASE WHEN p_auth_failed THEN 'error' WHEN p_status <> 'error' THEN 'connected' ELSE status END,
         last_ok_at = CASE WHEN p_status <> 'error' THEN now() ELSE last_ok_at END,
         last_error = CASE WHEN p_status = 'error' THEN left(coalesce(nullif(btrim(p_error), ''), 'The sync failed.'), 300) END,
         full_sync_done_at = coalesce(full_sync_done_at, CASE WHEN v_full THEN now() END)
   WHERE org_id = p_org_id;
  RETURN jsonb_build_object('ok', true, 'full_sync_done', v_full);
END $$;
REVOKE ALL ON FUNCTION public.exos_dice_sync_finish(uuid, uuid, text, text, jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_dice_sync_finish(uuid, uuid, text, text, jsonb, boolean) TO service_role;

-- A dry run's report, logged (owner / manager; at most 5 a minute per org).
-- Nothing else is written: no cursor, no event, no fan.
CREATE OR REPLACE FUNCTION public.exos_dice_log_dry_run(
  p_org_id uuid, p_user_id uuid, p_trigger text, p_status text, p_counts jsonb, p_error text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_dice_log_dry_run: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_trigger IS NULL OR p_trigger NOT IN ('dashboard', 'api') OR p_status IS NULL OR p_status NOT IN ('ok', 'partial', 'error') THEN
    RAISE EXCEPTION 'exos_dice_log_dry_run: bad trigger or status' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_dice_import_runs
       WHERE org_id = p_org_id AND dry_run AND started_at > now() - interval '1 minute') >= 5 THEN
    RAISE EXCEPTION 'exos_dice_log_dry_run: too many previews; wait a minute' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_dice_import_runs (org_id, kind, trigger, dry_run, status, started_by, finished_at, counts, error)
  VALUES (p_org_id,
          CASE WHEN (SELECT full_sync_done_at FROM public.exos_dice_connections WHERE org_id = p_org_id) IS NULL THEN 'full' ELSE 'incremental' END,
          p_trigger, true, p_status, p_user_id, now(),
          CASE WHEN jsonb_typeof(p_counts) = 'object' AND pg_column_size(p_counts) <= 16384 THEN p_counts ELSE '{}' END,
          left(nullif(btrim(coalesce(p_error, '')), ''), 300))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_dice_log_dry_run(uuid, uuid, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_dice_log_dry_run(uuid, uuid, text, text, jsonb, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Reading the state: the dashboard (authenticated, owner / manager) and
--    the partner API (service role, the key's org).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_dice_run_json(r public.exos_dice_import_runs)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', r.id, 'kind', r.kind, 'trigger', r.trigger, 'dry_run', r.dry_run, 'status', r.status,
                            'started_at', r.started_at, 'finished_at', r.finished_at, 'counts', r.counts,
                            'errors', r.errors, 'error', r.error)
$$;
REVOKE ALL ON FUNCTION public._exos_dice_run_json(public.exos_dice_import_runs) FROM PUBLIC, anon, authenticated;

-- Never the token, the secret id or the lease.
CREATE OR REPLACE FUNCTION public._exos_dice_status_json(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_dice_connections%ROWTYPE; v_last jsonb;
BEGIN
  SELECT * INTO c FROM public.exos_dice_connections WHERE org_id = p_org_id;
  SELECT public._exos_dice_run_json(r) INTO v_last FROM public.exos_dice_import_runs r
   WHERE r.org_id = p_org_id ORDER BY r.started_at DESC, r.id DESC LIMIT 1;
  RETURN jsonb_build_object(
    'connected', c.org_id IS NOT NULL AND c.status <> 'disconnected',
    'status', coalesce(c.status, 'not_connected'),
    'account_name', c.account_name,
    'connected_at', c.connected_at,
    'disconnected_at', c.disconnected_at,
    'syncing', c.lease_until IS NOT NULL AND c.lease_until > now(),
    'last_sync_at', c.last_sync_at,
    'last_ok_at', c.last_ok_at,
    'last_error', c.last_error,
    'full_sync_done_at', c.full_sync_done_at,
    'cursors', coalesce((SELECT jsonb_object_agg(e, jsonb_build_object(
                  'since', c.cursors #>> ARRAY[e, 'since'],
                  'resuming', c.cursors #>> ARRAY[e, 'after'] IS NOT NULL))
                FROM unnest(ARRAY['events', 'tickets', 'orders', 'returns', 'transfers']) e
               WHERE c.org_id IS NOT NULL), '{}'::jsonb),
    'imported', jsonb_build_object(
      'events', (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = p_org_id AND entity = 'event' AND exos_id IS NOT NULL),
      'events_past', (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = p_org_id AND entity = 'event' AND exos_id IS NULL),
      'ticket_types', (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = p_org_id AND entity = 'ticket_type'),
      'tickets', (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = p_org_id AND entity = 'ticket'),
      'door_entries', (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = p_org_id AND entity = 'ticket' AND exos_id IS NOT NULL),
      'returns', (SELECT count(*) FROM public.exos_dice_id_map WHERE org_id = p_org_id AND entity = 'return'),
      'orders', (SELECT count(*) FROM public.exos_dice_orders WHERE org_id = p_org_id),
      'fans', (SELECT count(DISTINCT exos_id) FROM public.exos_dice_id_map WHERE org_id = p_org_id AND entity = 'fan'),
      'fans_marketing_consent', (SELECT count(*) FROM public.exos_fans f
                                  WHERE f.org_id = p_org_id AND f.email_opt_in_source = 'dice:optInPartners'
                                    AND f.email_opt_in_at IS NOT NULL AND f.email_opt_out_at IS NULL AND f.discarded_at IS NULL)),
    'last_run', v_last);
END $$;
REVOKE ALL ON FUNCTION public._exos_dice_status_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_status_json(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_dice_runs(p_org_id uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM public.exos_dice_import_runs WHERE org_id = p_org_id),
    'rows', coalesce((SELECT jsonb_agg(public._exos_dice_run_json(r) ORDER BY r.started_at DESC, r.id DESC)
                        FROM (SELECT * FROM public.exos_dice_import_runs WHERE org_id = p_org_id
                               ORDER BY started_at DESC, id DESC
                               LIMIT greatest(1, least(coalesce(p_limit, 20), 200)) OFFSET greatest(coalesce(p_offset, 0), 0)) r), '[]'::jsonb))
$$;
REVOKE ALL ON FUNCTION public._exos_dice_runs(uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_dice_runs(uuid, integer, integer) TO service_role;

-- Org settings -> Integrations: the DICE card (owner / manager).
CREATE OR REPLACE FUNCTION public.exos_dice_org_status(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_dice_org_status: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'exos_dice_org_status: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_dice_status_json(p_org_id) || jsonb_build_object(
    'can_manage', true,
    'runs', (public._exos_dice_runs(p_org_id, 5, 0)) -> 'rows');
END $$;
REVOKE ALL ON FUNCTION public.exos_dice_org_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_dice_org_status(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Cron: hourly incremental sync (the claim decides who is due). Guarded
--     so a Postgres without pg_cron applies, and created INACTIVE like every
--     Exos cron on prod (scripts/rollout-prod.sh checks). Turn it on with:
--       SELECT cron.alter_job(jobid, active := true) FROM cron.job
--        WHERE jobname = 'exos-dice-import-sync-hourly';
--     after deploying exos-dice-import (CRON_SECRET, EXOS_DICE_IMPORT=on).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_job bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-dice-import-sync-hourly') THEN
      v_job := cron.schedule('exos-dice-import-sync-hourly', '23 * * * *', $cron$
        SELECT public._cron_invoke_edge_fn(
          'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-dice-import/cron', '{}'::jsonb);
      $cron$);
      PERFORM cron.alter_job(v_job, active := false);
    END IF;
  END IF;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos-dice-import-sync-hourly');
-- DROP the functions above and the four exos_dice_* tables; delete the
-- exos_dice:<org> Vault secrets; put the four CHECKs back without 'dice'
-- (no row may use it).
