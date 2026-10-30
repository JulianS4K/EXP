-- ============================================================================
-- Event import with link-out (distribution layer spec §7.2, operator 2026-10-29)
-- ============================================================================
-- Touches:  W: exos_events (+ link_out; CHECKs primary_source and
--              ticket_backend gain 'posh', rebuilt from their current lists;
--              + exos_events_link_out_chk)
--           C: TABLE exos_event_imports (RLS: owner / manager / finance read;
--              written by the definer functions below only)
--           C: FUNCTION exos_event_is_link_out, _exos_link_out_url_ok,
--              _exos_link_out_slug, _exos_link_out_types,
--              _exos_link_out_next_check, _exos_eventbrite_org_token,
--              exos_event_buy_link, exos_feed_where_to_buy,
--              exos_link_out_import, exos_link_out_check_claim,
--              exos_link_out_check_apply (service role only)
--           C: FUNCTION exos_public_link_out + VIEW exos_public_link_outs
--              (anon: published link-out events, where to buy and the
--              imported prices, nothing else)
--           R: FUNCTION exos_public_event_sale (same columns; where to buy now
--              comes from exos_event_buy_link)
--           C: TRIGGER exos_events_link_out_guard (exos_events),
--              exos_<table>_link_out (BEFORE INSERT on every Exos sell table)
--           W: FUNCTION exos_event_is_free_tier, exos_event_fee_terms,
--              exos_resale_unlocked, exos_event_last_call, _exos_feed_eligible,
--              exos_set_ticket_backend, exos_calendar_event_rows (patched in
--              place)
--           C: cron.schedule exos-event-import-check-15min (when pg_cron is
--              present), created INACTIVE like every Exos cron on prod
-- Pre-reqs: 20261029090000 (free tier), 20261029100000 (last call, where to
--           buy), 20261016100000 (ticket_backend / external_ticket_url),
--           20261013100000 (Eventbrite accounts + links), 20260929073000
--           (calendar feeds)
--
-- A LINK-OUT event is an Exos event whose tickets are sold only on the
-- organizer's own checkout (Eventbrite, Luma, Posh). Exos lists it (event
-- page, org page, discovery, Google, catalog and calendar feeds, tracking
-- links) and sends every buyer to the source URL. Exos sells nothing for it:
--
--   * exos_events.link_out = true. Its ticket_backend is the platform and
--     external_ticket_url the source URL (the CHECK keeps them set), so the
--     existing "sold elsewhere" paths apply too (cart holds, free claims,
--     exos-checkout all refuse ticket_backend <> 'exos').
--   * One trigger per sell table refuses any row for a link-out event,
--     whatever the path and the role: tickets (checkout fulfilment, free
--     claims, comps, box office, mint, bypass vouchers, referral rewards,
--     marketplace and S4K sales), ticket types, cart holds, vouchers,
--     discount codes, quotas, checkout sessions, table bookings, the
--     waitlist, channel mirrors (Exos must not push it back to the platform
--     it came from), marketplace links and listings, S4K listings, and
--     Eventbrite / Luma capacity mappings (no capacity write ever).
--   * Resale is never unlocked, last call never applies, the S4K / partner
--     feed leaves it out, and the event can't be put on a marketplace or the
--     S4K route (exos_events_link_out_guard).
--   * It is the free tier for fees (Exos sells nothing; free_tier_fee_bps).
--
-- The imported ticket types are DISPLAY ONLY (exos_event_imports.ticket_types:
-- name, price range, sold out); they are never exos_ticket_tiers, so there is
-- nothing an Exos path could sell.
--
-- Where the source lives:
--   exos_event_imports   one row per link-out event: platform, source id,
--                        source URL, status, prices, the re-check state.
--                        Unique per (org, platform, source id): re-importing
--                        updates, never duplicates.
--   exos_eventbrite_links  (20261013100000) also gets the Eventbrite event
--                        when the org has Eventbrite connected, so the door
--                        list syncs its attendees (read only) and the
--                        Eventbrite event can't be linked to a second Exos
--                        event. Its sync/lease columns are the attendee sync's,
--                        not a source registry, so the import keeps its own row.
--   exos_backend_links   (20261016100000, Luma) is not used: it is a door
--                        attendee sync keyed on Luma's evt- id that needs the
--                        Luma integration; a pasted Luma link only has the
--                        public slug. Linking one later is the existing
--                        "Tickets sold somewhere else" flow.
--
-- Status: on_sale | sold_out | cancelled | ended | unknown. The re-check job
-- (exos-event-import /cron, below) re-reads Eventbrite events with the org's
-- token: cancelled cancels the Exos event (no tickets, so nobody to tell), a
-- new start date moves it (previous_starts_at kept for Google's
-- EventRescheduled), and ended / cancelled stop the checks. Luma and Posh
-- imports are created from a pasted link with the organizer's own details
-- and are not re-checked (reading their public pages needs the operator's OK).
--
-- Re-run safe. Prod apply needs operator OK.
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
  -- Written as ARRAY['a'::text, ...] (what the existing ones print as), so a
  -- re-run reads the same list back.
  EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', p_table, p_con);
  EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%I = ANY (ARRAY[%s]))', p_table, p_con, p_col,
                 (SELECT string_agg(quote_literal(x) || '::text', ', ' ORDER BY x) FROM unnest(v_new) x));
END $$;

-- ---------------------------------------------------------------------------
-- 1. The mode, and Posh as a platform.
--    primary_source becomes (whatever it allowed) + 'posh'; ticket_backend
--    the same. On this branch: primary_source exos, eventbrite, luma, posh;
--    ticket_backend eventbrite, exos, hievents, luma, posh, pretix.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS link_out boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.exos_events.link_out IS
  'Link-out: listed by Exos, sold only on the organizer''s own checkout (exos_event_imports). Exos sells nothing for it. Set by exos_link_out_import only. mig 20261029170000.';

SELECT pg_temp.exos_check_add('public.exos_events', 'exos_events_primary_source_check', 'primary_source', ARRAY['posh']);
SELECT pg_temp.exos_check_add('public.exos_events', 'exos_events_ticket_backend_chk', 'ticket_backend', ARRAY['posh']);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_link_out_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_link_out_chk
      CHECK (NOT link_out OR (ticket_backend <> 'exos' AND external_ticket_url IS NOT NULL));
  END IF;
END $$;
GRANT SELECT (link_out) ON public.exos_events TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The source of each link-out event.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_event_imports (
  event_id           uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  platform           text NOT NULL CHECK (platform IN ('eventbrite', 'luma', 'posh')),
  -- Eventbrite: the numeric event id; Luma: evt- id or the public slug; Posh: the slug.
  source_event_id    text NOT NULL CHECK (source_event_id ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$'),
  source_url         text NOT NULL CHECK (source_url ~ '^https://[^\s/]+\.[^\s]+$' AND length(source_url) <= 500),
  origin             text NOT NULL CHECK (origin IN ('account', 'link')),
  source_status      text NOT NULL DEFAULT 'unknown'
                       CHECK (source_status IN ('on_sale', 'sold_out', 'cancelled', 'ended', 'unknown')),
  -- Display only: never Exos ticket types.
  price_min          numeric(12, 2) CHECK (price_min IS NULL OR price_min >= 0),
  price_max          numeric(12, 2) CHECK (price_max IS NULL OR price_max >= 0),
  currency           text CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
  is_free            boolean NOT NULL DEFAULT false,
  ticket_types       jsonb NOT NULL DEFAULT '[]'::jsonb
                       CHECK (jsonb_typeof(ticket_types) = 'array' AND jsonb_array_length(ticket_types) <= 50),
  -- Re-check (Eventbrite only for now).
  checks_enabled     boolean NOT NULL DEFAULT false,
  source_starts_at   timestamptz,         -- the start the source had at the last read
  previous_starts_at timestamptz,         -- before the last reschedule (Google's previousStartDate)
  rescheduled_at     timestamptz,
  last_checked_at    timestamptz,
  last_ok_at         timestamptz,
  next_check_at      timestamptz,
  check_errors       integer NOT NULL DEFAULT 0,
  last_error         text CHECK (last_error IS NULL OR length(last_error) <= 200),
  lease_id           uuid,
  lease_until        timestamptz,
  imported_by        uuid,
  imported_at        timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (price_min IS NULL OR price_max IS NULL OR price_min <= price_max),
  CONSTRAINT exos_event_imports_source_uq UNIQUE (org_id, platform, source_event_id)
);
CREATE INDEX IF NOT EXISTS exos_event_imports_due_idx
  ON public.exos_event_imports (next_check_at NULLS FIRST) WHERE checks_enabled;
ALTER TABLE public.exos_event_imports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_event_imports FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.exos_event_imports TO authenticated;
GRANT ALL ON TABLE public.exos_event_imports TO service_role;
DROP POLICY IF EXISTS exos_event_imports_sel ON public.exos_event_imports;
CREATE POLICY exos_event_imports_sel ON public.exos_event_imports FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
COMMENT ON TABLE public.exos_event_imports IS
  'Link-out events: where each one is sold (Eventbrite / Luma / Posh), its status and display-only prices, and the re-check state. Written by exos_link_out_import / exos_link_out_check_apply only. mig 20261029170000.';

CREATE OR REPLACE FUNCTION public.exos_event_is_link_out(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT e.link_out FROM public.exos_events e WHERE e.id = p_event_id), false)
$$;
REVOKE ALL ON FUNCTION public.exos_event_is_link_out(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_is_link_out(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Guards.
-- ---------------------------------------------------------------------------
-- exos_events: only the import sets link_out, and a signed-in client can't
-- move a link-out event's sale elsewhere (ticket_backend, URL, primary).
-- Nobody puts one on a marketplace or the S4K route. SECURITY INVOKER on
-- purpose: current_user is the client role for a direct table write, and the
-- function owner inside a definer RPC.
CREATE OR REPLACE FUNCTION public.exos_tg_event_link_out_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_client boolean := current_user IN ('anon', 'authenticated');
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.link_out AND v_client THEN
      RAISE EXCEPTION 'link-out events are created by importing them (List an event you sell elsewhere)' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF v_client AND (NEW.link_out IS DISTINCT FROM OLD.link_out
                     OR (OLD.link_out AND (NEW.ticket_backend, NEW.external_ticket_url, NEW.primary_source)
                                          IS DISTINCT FROM (OLD.ticket_backend, OLD.external_ticket_url, OLD.primary_source))) THEN
      RAISE EXCEPTION 'this event is sold on the organizer''s own checkout (link-out); its link is set by the import' USING ERRCODE = '42501';
    END IF;
    -- (Only the service role or a definer function gets here with a change.)
    IF NEW.link_out AND NOT OLD.link_out THEN
      IF EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.event_id = NEW.id) THEN
        RAISE EXCEPTION 'an event with Exos tickets can''t become link-out' USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;
  IF NEW.link_out AND (cardinality(coalesce(NEW.distribution_networks, '{}'::text[])) > 0 OR NEW.distribution_route = 's4k') THEN
    RAISE EXCEPTION 'Exos sells nothing for a link-out event: no marketplaces, no S4K' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_link_out_guard() FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE TRIGGER exos_events_link_out_guard
  BEFORE INSERT OR UPDATE ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_link_out_guard();

-- Every sell table refuses a row for a link-out event, whoever writes it.
CREATE OR REPLACE FUNCTION public.exos_tg_link_out_refuse()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.event_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = NEW.event_id AND e.link_out) THEN
    RAISE EXCEPTION 'link-out event: tickets are sold only on the organizer''s own checkout, Exos sells nothing (%)', TG_TABLE_NAME
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_link_out_refuse() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'exos_tickets', 'exos_ticket_tiers', 'exos_cart_holds', 'exos_vouchers', 'exos_discount_codes', 'exos_quotas',
    'exos_checkout_sessions', 'exos_table_bookings', 'exos_waitlist', 'exos_event_addons',
    'exos_channel_mirrors', 'exos_channel_event_links', 'exos_distribution_listings', 'exos_s4k_listings',
    'exos_eventbrite_ticket_links', 'exos_luma_ticket_links', 'exos_luma_comp_queue'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass('public.' || t) AND attname = 'event_id' AND NOT attisdropped) THEN
      RAISE NOTICE 'link-out guard: % not present here, skipped', t;
      CONTINUE;
    END IF;
    EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_tg_link_out_refuse()',
                   t || '_link_out', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Free tier for fees, never resold, no last call, off the S4K / partner
--    feed, and the backend can't be switched back to Exos.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_event_is_free_tier(uuid)',
  'link-out (mig 20261029170000)',
  $o$  SELECT coalesce(public.exos_event_capacity_bounded(p_event_id), false)
     AND public.exos_event_tier_size(p_event_id) <= public.exos_free_tier_max_capacity()$o$,
  $n$  SELECT public.exos_event_is_link_out(p_event_id)   -- link-out (mig 20261029170000): Exos sells nothing
     OR (coalesce(public.exos_event_capacity_bounded(p_event_id), false)
         AND public.exos_event_tier_size(p_event_id) <= public.exos_free_tier_max_capacity())$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_event_fee_terms(uuid, uuid, integer)',
  'link-out (mig 20261029170000)',
  $o$'free_tier', x.bounded AND greatest(x.cap, x.sold + x.adm) <= x.cut)$o$,
  $n$'free_tier', e.link_out /* link-out (mig 20261029170000) */ OR (x.bounded AND greatest(x.cap, x.sold + x.adm) <= x.cut))$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_resale_unlocked(uuid)',
  'link-out (mig 20261029170000)',
  $o$     AND (NOT public.exos_resale_consent_required() OR public.exos_resale_consent_active(p_event_id))$o$,
  $n$     AND (NOT public.exos_resale_consent_required() OR public.exos_resale_consent_active(p_event_id))
     AND NOT public.exos_event_is_link_out(p_event_id)   -- link-out (mig 20261029170000): never resold$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_event_last_call(uuid)',
  'link-out (mig 20261029170000)',
  $o$    SELECT e.status IS DISTINCT FROM 'cancelled'$o$,
  $n$    SELECT e.status IS DISTINCT FROM 'cancelled'
           AND NOT e.link_out   -- link-out (mig 20261029170000): Exos is no channel$n$, 1);

-- Anchored on the start of the last-call line, not its end: the fixed-block
-- migration (20261029160000) appends its own line after it.
SELECT pg_temp.exos_patch_n('public._exos_feed_eligible(uuid)',
  'link-out (mig 20261029170000)',
  $o$    AND NOT public.exos_event_last_call(p_event_id)$o$,
  $n$    AND NOT public.exos_event_is_link_out(p_event_id)   -- link-out (mig 20261029170000): no inventory to offer
    AND NOT public.exos_event_last_call(p_event_id)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_set_ticket_backend(uuid, text, text)',
  'link-out (mig 20261029170000)',
  $o$  IF p_backend IS NULL OR p_backend NOT IN ('exos', 'eventbrite', 'pretix', 'hievents', 'luma') THEN$o$,
  $n$  IF e.link_out THEN   -- link-out (mig 20261029170000)
    RAISE EXCEPTION 'exos_set_ticket_backend: this event is listed from the organizer''s own checkout; re-import it to change the link'
      USING ERRCODE = '22023';
  END IF;
  IF p_backend IS NULL OR p_backend NOT IN ('exos', 'eventbrite', 'pretix', 'hievents', 'luma') THEN$n$, 1);

-- ---------------------------------------------------------------------------
-- 5. Where to buy: ONE function for the storefront and every feed.
--    link-out          the source URL (its platform)
--    sold elsewhere    ticket_backend's shop (external_ticket_url)
--    last call         the primary's page, when the primary isn't Exos
--    otherwise         Exos (url NULL: the Exos event page / checkout)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_buy_link(p_event_id uuid)
RETURNS TABLE (sells_on text, url text, link_out boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN e.link_out THEN coalesce(i.platform, e.ticket_backend)
              WHEN e.ticket_backend <> 'exos' AND e.external_ticket_url IS NOT NULL THEN e.ticket_backend
              WHEN x.lc AND e.primary_source <> 'exos' THEN e.primary_source
              ELSE 'exos' END,
         CASE WHEN e.link_out THEN coalesce(i.source_url, e.external_ticket_url)
              WHEN e.ticket_backend <> 'exos' AND e.external_ticket_url IS NOT NULL THEN e.external_ticket_url
              WHEN x.lc AND e.primary_source <> 'exos' THEN public._exos_primary_url(e.id)
         END,
         e.link_out
    FROM public.exos_events e
    LEFT JOIN public.exos_event_imports i ON i.event_id = e.id
    CROSS JOIN LATERAL (SELECT public.exos_event_last_call(e.id) AS lc) x
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public.exos_event_buy_link(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_buy_link(uuid) TO service_role;

-- The storefront view (mig 20261029100000): same columns, where to buy from
-- the one function. Outside last call an event Exos sells answers 'exos' as
-- before; a link-out or sold-elsewhere event answers its shop.
CREATE OR REPLACE FUNCTION public.exos_public_event_sale(p_event_id uuid)
RETURNS TABLE (last_call boolean, sells_on text, sells_on_url text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.exos_event_last_call(e.id), b.sells_on, b.url
    FROM public.exos_events e
    CROSS JOIN LATERAL public.exos_event_buy_link(e.id) b
   WHERE e.id = p_event_id AND e.status = 'published'
$$;
REVOKE ALL ON FUNCTION public.exos_public_event_sale(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_event_sale(uuid) TO anon, authenticated, service_role;

-- Link-out details the storefront and the catalog feed show (published events
-- only): where to buy, the source status, the imported price range and ticket
-- type names. No ids, no check state, nothing about the account.
CREATE OR REPLACE FUNCTION public.exos_public_link_out(p_event_id uuid)
RETURNS TABLE (platform text, url text, source_status text, price_min numeric, price_max numeric,
               currency text, is_free boolean, ticket_types jsonb, checked_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT i.platform, i.source_url, i.source_status, i.price_min, i.price_max, i.currency, i.is_free,
         i.ticket_types, i.last_ok_at
    FROM public.exos_event_imports i
    JOIN public.exos_events e ON e.id = i.event_id
   WHERE i.event_id = p_event_id AND e.status = 'published' AND e.link_out
$$;
REVOKE ALL ON FUNCTION public.exos_public_link_out(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_link_out(uuid) TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.exos_public_link_outs
WITH (security_barrier = true)
AS
SELECT e.id AS event_id, l.platform, l.url, l.source_status, l.price_min, l.price_max, l.currency,
       l.is_free, l.ticket_types, l.checked_at
  FROM public.exos_events e
  CROSS JOIN LATERAL public.exos_public_link_out(e.id) l
 WHERE e.status = 'published' AND e.link_out;
REVOKE ALL ON public.exos_public_link_outs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_link_outs TO anon, authenticated, service_role;
COMMENT ON VIEW public.exos_public_link_outs IS
  'Published link-out events: the organizer''s checkout URL, source status and display-only prices. mig 20261029170000.';

-- For the service-role feeds (Google, calendar): where to buy for many events
-- at once, any status, plus the link-out details.
CREATE OR REPLACE FUNCTION public.exos_feed_where_to_buy(p_event_ids uuid[])
RETURNS TABLE (event_id uuid, sells_on text, url text, link_out boolean, source_status text,
               price_min numeric, price_max numeric, currency text, is_free boolean, ticket_types jsonb,
               previous_starts_at timestamptz, rescheduled_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT e.id, b.sells_on, b.url, b.link_out, i.source_status, i.price_min, i.price_max, i.currency,
         coalesce(i.is_free, false), coalesce(i.ticket_types, '[]'::jsonb), i.previous_starts_at, i.rescheduled_at
    FROM public.exos_events e
    CROSS JOIN LATERAL public.exos_event_buy_link(e.id) b
    LEFT JOIN public.exos_event_imports i ON i.event_id = e.id
   WHERE e.id = ANY (coalesce(p_event_ids, '{}'::uuid[]))
   LIMIT 5000
$$;
REVOKE ALL ON FUNCTION public.exos_feed_where_to_buy(uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_where_to_buy(uuid[]) TO service_role;

-- The calendar entry's ticket link (exos-calendar): where to buy.
SELECT pg_temp.exos_patch_n('public.exos_calendar_event_rows(uuid[], uuid[])',
  'buy_url',
  $o$             'has_tickets', e.id = ANY (coalesce(p_ticketed, '{}')))$o$,
  $n$             'buy_on', (SELECT b.sells_on FROM public.exos_event_buy_link(e.id) b),   -- mig 20261029170000
             'buy_url', (SELECT b.url FROM public.exos_event_buy_link(e.id) b),
             'has_tickets', e.id = ANY (coalesce(p_ticketed, '{}')))$n$, 1);

-- ---------------------------------------------------------------------------
-- 6. Import (service role: exos-event-import, which verified the user's JWT
--    and read the source). Owner / manager of p_org_id.
-- ---------------------------------------------------------------------------
-- The URL belongs to the platform and names the source id. The edge function
-- parses the link itself (never a client-supplied platform); this checks again.
CREATE OR REPLACE FUNCTION public._exos_link_out_url_ok(p_platform text, p_id text, p_url text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT p_url IS NOT NULL AND p_id IS NOT NULL AND length(p_url) <= 500 AND p_url !~ '\s'
     AND CASE p_platform
           WHEN 'eventbrite' THEN
             p_id ~ '^[0-9]{1,24}$'
             AND p_url ~ '^https://(www\.)?eventbrite\.(com|ca|ie|de|fr|es|nl|it|be|at|ch|se|dk|fi|pt|pl|sg|hk|co\.uk|co\.nz|com\.au|com\.mx|com\.br|com\.ar|com\.pe|com\.co|cl)/'
             AND p_url ~ ('[^0-9]' || p_id || '([/?#]|$)')
           WHEN 'luma' THEN
             p_id ~ '^(evt-[A-Za-z0-9]{4,40}|[A-Za-z0-9][A-Za-z0-9-]{1,63})$'
             AND p_url ~ '^https://(www\.)?(lu\.ma|luma\.com)/'
             AND p_url ~ ('/' || p_id || '([/?#]|$)')
           WHEN 'posh' THEN
             p_id ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$'
             AND p_url ~ ('^https://(www\.)?posh\.vip/e/' || p_id || '([/?#]|$)')
           ELSE false
         END
$$;
REVOKE ALL ON FUNCTION public._exos_link_out_url_ok(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_link_out_url_ok(text, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_link_out_slug(p_name text)
RETURNS text LANGUAGE sql VOLATILE SET search_path = public, pg_temp AS $$
  SELECT coalesce(nullif(left(btrim(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g'), '-'), 60), ''), 'event')
         || '-' || substr(md5(gen_random_uuid()::text), 1, 6)
$$;
REVOKE ALL ON FUNCTION public._exos_link_out_slug(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_link_out_slug(text) TO service_role;

-- Display-only ticket types, rebuilt from what the caller sent (unknown keys
-- dropped, at most 50, names at most 120 characters).
CREATE OR REPLACE FUNCTION public._exos_link_out_types(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'name', left(btrim(x ->> 'name'), 120),
           'min_price', CASE WHEN (x ->> 'min_price') ~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN (x ->> 'min_price')::numeric END,
           'max_price', CASE WHEN (x ->> 'max_price') ~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN (x ->> 'max_price')::numeric END,
           'sold_out', (x ->> 'sold_out') = 'true',
           'free', (x ->> 'free') = 'true')) ORDER BY ord), '[]'::jsonb)
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p) = 'array' THEN p ELSE '[]'::jsonb END) WITH ORDINALITY AS a(x, ord)
   WHERE ord <= 50 AND jsonb_typeof(x) = 'object' AND coalesce(btrim(x ->> 'name'), '') <> ''
$$;
REVOKE ALL ON FUNCTION public._exos_link_out_types(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_link_out_types(jsonb) TO service_role;

-- When to read the source next: every 30 min in the last 2 days, every 2 h
-- in the last 2 weeks, else twice a day; errors back off (to a day at most).
CREATE OR REPLACE FUNCTION public._exos_link_out_next_check(p_starts timestamptz, p_errors integer)
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT now() + least(
    CASE WHEN p_starts IS NULL THEN interval '6 hours'
         WHEN p_starts - now() < interval '2 days' THEN interval '30 minutes'
         WHEN p_starts - now() < interval '14 days' THEN interval '2 hours'
         ELSE interval '12 hours' END * power(2, least(greatest(coalesce(p_errors, 0), 0), 6))::int,
    interval '24 hours')
$$;
REVOKE ALL ON FUNCTION public._exos_link_out_next_check(timestamptz, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_link_out_next_check(timestamptz, integer) TO service_role;

-- The org's Eventbrite token for the service paths (the re-check). The ONE
-- place the import reads it: OAuth (spec §7.1) replaces the body.
CREATE OR REPLACE FUNCTION public._exos_eventbrite_org_token(p_org_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT d.decrypted_secret FROM public.exos_eventbrite_accounts a
    JOIN vault.decrypted_secrets d ON d.id = a.secret_id
   WHERE a.org_id = p_org_id
$$;
REVOKE ALL ON FUNCTION public._exos_eventbrite_org_token(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_eventbrite_org_token(uuid) TO service_role;

-- p_data (what the edge function read, or the organizer typed for a pasted
-- Luma / Posh link):
--   source_event_id, source_url, source_status, name, summary, description,
--   starts_at, ends_at, timezone, venue_name, venue_address {street, city,
--   region, postal, country}, online, image_url, category, currency,
--   price_min, price_max, is_free, ticket_types [{name, min_price,
--   max_price, sold_out, free}], publish
-- Creates the event (published when asked and it has a start; a pasted Luma
-- or Posh link is always a draft), or, for a source this org already
-- imported, refreshes the source fields of that event and leaves what the
-- organizer may have edited (name, text, image, venue) alone.
-- Answers {event_id, created, status, platform, linked_door}.
CREATE OR REPLACE FUNCTION public.exos_link_out_import(
  p_org_id uuid, p_user_id uuid, p_platform text, p_origin text, p_data jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  d          jsonb := coalesce(p_data, '{}'::jsonb);
  v_id       text := btrim(coalesce(d ->> 'source_event_id', ''));
  v_url      text := btrim(coalesce(d ->> 'source_url', ''));
  v_status   text := coalesce(nullif(d ->> 'source_status', ''), 'unknown');
  v_name     text := left(nullif(btrim(coalesce(d ->> 'name', '')), ''), 200);
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_tz       text := nullif(btrim(coalesce(d ->> 'timezone', '')), '');
  v_cur      text := upper(nullif(btrim(coalesce(d ->> 'currency', '')), ''));
  v_min      numeric;
  v_max      numeric;
  v_publish  boolean;
  v_event    uuid;
  v_created  boolean := false;
  v_linked   boolean := false;
  v_addr     jsonb;
  v_img      text := nullif(btrim(coalesce(d ->> 'image_url', '')), '');
  v_old      public.exos_event_imports%ROWTYPE;
  v_estatus  text;
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_link_out_import: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_platform IS NULL OR p_platform NOT IN ('eventbrite', 'luma', 'posh') THEN
    RAISE EXCEPTION 'exos_link_out_import: Eventbrite, Luma or Posh' USING ERRCODE = '22023';
  END IF;
  IF p_origin IS NULL OR p_origin NOT IN ('account', 'link') OR (p_origin = 'account' AND p_platform <> 'eventbrite') THEN
    RAISE EXCEPTION 'exos_link_out_import: bad origin' USING ERRCODE = '22023';
  END IF;
  IF NOT public._exos_link_out_url_ok(p_platform, v_id, v_url) THEN
    RAISE EXCEPTION 'exos_link_out_import: that link isn''t a % event page', initcap(p_platform) USING ERRCODE = '22023';
  END IF;
  IF v_status NOT IN ('on_sale', 'sold_out', 'cancelled', 'ended', 'unknown') THEN
    RAISE EXCEPTION 'exos_link_out_import: bad status' USING ERRCODE = '22023';
  END IF;
  BEGIN
    v_starts := nullif(d ->> 'starts_at', '')::timestamptz;
    v_ends   := nullif(d ->> 'ends_at', '')::timestamptz;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'exos_link_out_import: bad date' USING ERRCODE = '22023';
  END;
  IF v_ends IS NOT NULL AND v_starts IS NOT NULL AND v_ends < v_starts THEN v_ends := NULL; END IF;
  IF v_tz IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_tz) THEN v_tz := NULL; END IF;
  IF v_cur IS NOT NULL AND v_cur !~ '^[A-Z]{3}$' THEN v_cur := NULL; END IF;
  v_min := CASE WHEN (d ->> 'price_min') ~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN (d ->> 'price_min')::numeric END;
  v_max := CASE WHEN (d ->> 'price_max') ~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN (d ->> 'price_max')::numeric END;
  IF v_min IS NOT NULL AND v_max IS NOT NULL AND v_min > v_max THEN
    v_min := v_max; v_max := (d ->> 'price_min')::numeric;
  END IF;
  IF v_img IS NOT NULL AND (v_img !~ '^https://[^\s/]+\.[^\s]+$' OR length(v_img) > 1000) THEN v_img := NULL; END IF;
  v_addr := CASE WHEN jsonb_typeof(d -> 'venue_address') = 'object' THEN jsonb_strip_nulls(jsonb_build_object(
              'street', left(nullif(btrim(d -> 'venue_address' ->> 'street'), ''), 200),
              'city', left(nullif(btrim(d -> 'venue_address' ->> 'city'), ''), 120),
              'region', left(nullif(btrim(d -> 'venue_address' ->> 'region'), ''), 120),
              'postal', left(nullif(btrim(d -> 'venue_address' ->> 'postal'), ''), 20),
              'country', left(nullif(btrim(d -> 'venue_address' ->> 'country'), ''), 60))) END;
  -- A pasted Luma / Posh link is a draft the organizer checks and publishes.
  v_publish := (d ->> 'publish') = 'true' AND v_starts IS NOT NULL AND v_name IS NOT NULL
               AND NOT (p_platform IN ('luma', 'posh') AND p_origin = 'link');

  -- One import per source, even for two taps at once.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_link_out:' || p_org_id || ':' || p_platform || ':' || v_id, 0));
  SELECT * INTO v_old FROM public.exos_event_imports
   WHERE org_id = p_org_id AND platform = p_platform AND source_event_id = v_id FOR UPDATE;

  IF v_old.event_id IS NULL THEN
    IF v_status IN ('cancelled', 'ended') THEN
      RAISE EXCEPTION 'exos_link_out_import: that event is % on %', CASE v_status WHEN 'cancelled' THEN 'cancelled' ELSE 'over' END, initcap(p_platform)
        USING ERRCODE = '22023';
    END IF;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'exos_link_out_import: give the event a name' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_events (org_id, name, slug, status, starts_at, ends_at, timezone, currency,
                                    venue_name, venue_address, description, summary, image_url, format,
                                    total_tickets, tickets_sold, created_by,
                                    link_out, ticket_backend, external_ticket_url, primary_source)
    VALUES (p_org_id, v_name, public._exos_link_out_slug(v_name),
            CASE WHEN v_publish THEN 'published' ELSE 'draft' END,
            v_starts, v_ends, v_tz, lower(coalesce(v_cur, 'USD')),
            left(nullif(btrim(coalesce(d ->> 'venue_name', '')), ''), 200), v_addr,
            left(nullif(btrim(coalesce(d ->> 'description', '')), ''), 20000),
            left(nullif(btrim(coalesce(d ->> 'summary', '')), ''), 160),
            v_img, CASE WHEN (d ->> 'online') = 'true' THEN 'online' ELSE 'in_person' END,
            0, 0, p_user_id,
            true, p_platform, v_url, p_platform)
    RETURNING id INTO v_event;
    v_created := true;
    -- The category column is on prod's exos_events (phase 1) but not on
    -- every database this applies to.
    IF nullif(btrim(coalesce(d ->> 'category', '')), '') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'exos_events' AND column_name = 'category') THEN
      EXECUTE 'UPDATE public.exos_events SET category = $1 WHERE id = $2'
        USING left(lower(btrim(d ->> 'category')), 60), v_event;
    END IF;
    INSERT INTO public.exos_event_imports (event_id, org_id, platform, source_event_id, source_url, origin, source_status,
                                           price_min, price_max, currency, is_free, ticket_types, checks_enabled,
                                           source_starts_at, last_checked_at, last_ok_at, next_check_at, imported_by)
    VALUES (v_event, p_org_id, p_platform, v_id, v_url, p_origin, v_status,
            v_min, v_max, v_cur, coalesce((d ->> 'is_free') = 'true', false), public._exos_link_out_types(d -> 'ticket_types'),
            p_platform = 'eventbrite', v_starts,
            CASE WHEN p_platform = 'eventbrite' THEN now() END, CASE WHEN p_platform = 'eventbrite' THEN now() END,
            CASE WHEN p_platform = 'eventbrite' THEN public._exos_link_out_next_check(v_starts, 0) END, p_user_id);
  ELSE
    -- Same source again: refresh what the source owns.
    v_event := v_old.event_id;
    UPDATE public.exos_event_imports
       SET source_url = v_url, source_status = v_status, price_min = v_min, price_max = v_max,
           currency = coalesce(v_cur, currency), is_free = coalesce((d ->> 'is_free') = 'true', false),
           ticket_types = public._exos_link_out_types(d -> 'ticket_types'),
           last_checked_at = CASE WHEN p_platform = 'eventbrite' THEN now() ELSE last_checked_at END,
           last_ok_at = CASE WHEN p_platform = 'eventbrite' THEN now() ELSE last_ok_at END,
           check_errors = 0, last_error = NULL, updated_at = now()
     WHERE event_id = v_event;
    UPDATE public.exos_events SET external_ticket_url = v_url WHERE id = v_event;
    IF v_status = 'cancelled' THEN
      UPDATE public.exos_events SET status = 'cancelled' WHERE id = v_event AND status <> 'cancelled';
    END IF;
  END IF;

  -- Eventbrite connected: the door list syncs its attendees (read only).
  IF p_platform = 'eventbrite' AND EXISTS (SELECT 1 FROM public.exos_eventbrite_accounts WHERE org_id = p_org_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_links WHERE event_id = v_event)
     AND (SELECT status FROM public.exos_events WHERE id = v_event) <> 'cancelled' THEN
    PERFORM public.exos_eventbrite_link(v_event, p_user_id, v_id, v_name);
    v_linked := true;
  END IF;
  v_linked := v_linked OR EXISTS (SELECT 1 FROM public.exos_eventbrite_links WHERE event_id = v_event);

  SELECT status INTO v_estatus FROM public.exos_events WHERE id = v_event;
  RETURN jsonb_build_object('event_id', v_event, 'created', v_created, 'status', v_estatus,
                            'platform', p_platform, 'linked_door', v_linked);
END $$;
REVOKE ALL ON FUNCTION public.exos_link_out_import(uuid, uuid, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_link_out_import(uuid, uuid, text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Re-check (exos-event-import /cron and "Check now").
-- ---------------------------------------------------------------------------
-- p_event_id NULL: the cron; up to p_limit due imports, oldest first, each
-- leased for 2 minutes. p_event_id + p_user_id: "Check now" by an owner /
-- manager (at most once a minute). Events a day past their end are marked
-- ended here without a read. Rows come back with the org's token; an org
-- that disconnected Eventbrite gets an error recorded instead.
CREATE OR REPLACE FUNCTION public.exos_link_out_check_claim(
  p_limit integer DEFAULT 20, p_event_id uuid DEFAULT NULL, p_user_id uuid DEFAULT NULL
) RETURNS TABLE (event_id uuid, platform text, source_event_id text, token text, lease_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE r record; v_tok text; v_lease uuid;
BEGIN
  IF p_event_id IS NOT NULL THEN
    IF coalesce(public._exos_eb_role((SELECT e.org_id FROM public.exos_events e WHERE e.id = p_event_id), p_user_id), '')
       NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'exos_link_out_check_claim: owner or manager only' USING ERRCODE = '42501';
    END IF;
  END IF;

  UPDATE public.exos_event_imports i
     SET source_status = 'ended', next_check_at = NULL, updated_at = now()
    FROM public.exos_events e
   WHERE e.id = i.event_id AND i.checks_enabled AND i.source_status NOT IN ('ended', 'cancelled')
     AND coalesce(e.ends_at, e.starts_at + interval '6 hours') < now() - interval '1 day'
     AND (p_event_id IS NULL OR i.event_id = p_event_id);

  FOR r IN
    SELECT i.event_id, i.org_id, i.platform, i.source_event_id
      FROM public.exos_event_imports i
      JOIN public.exos_events e ON e.id = i.event_id
     WHERE i.checks_enabled AND i.platform = 'eventbrite'
       AND i.source_status NOT IN ('cancelled', 'ended') AND e.status <> 'cancelled'
       AND (i.lease_until IS NULL OR i.lease_until < now())
       AND CASE WHEN p_event_id IS NULL THEN i.next_check_at IS NULL OR i.next_check_at <= now()
                ELSE i.event_id = p_event_id AND (i.last_checked_at IS NULL OR i.last_checked_at < now() - interval '1 minute') END
     ORDER BY i.next_check_at NULLS FIRST, i.event_id
     LIMIT greatest(1, least(coalesce(p_limit, 20), 100))
     FOR UPDATE OF i SKIP LOCKED
  LOOP
    v_tok := public._exos_eventbrite_org_token(r.org_id);
    IF v_tok IS NULL THEN
      UPDATE public.exos_event_imports
         SET last_checked_at = now(), check_errors = check_errors + 1, last_error = 'Eventbrite isn''t connected for this organizer.',
             next_check_at = now() + interval '24 hours', updated_at = now()
       WHERE exos_event_imports.event_id = r.event_id;
      CONTINUE;
    END IF;
    v_lease := gen_random_uuid();
    UPDATE public.exos_event_imports
       SET lease_id = v_lease, lease_until = now() + interval '2 minutes'
     WHERE exos_event_imports.event_id = r.event_id;
    event_id := r.event_id; platform := r.platform; source_event_id := r.source_event_id;
    token := v_tok; lease_id := v_lease;
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_link_out_check_claim(integer, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_link_out_check_claim(integer, uuid, uuid) TO service_role;

-- One read's outcome. p_result (null with p_error on a failed read):
--   source_status, starts_at, ends_at, price_min, price_max, currency,
--   is_free, ticket_types, source_url
-- Transitions: cancelled cancels the Exos event; a start the source moved
-- moves the Exos event (previous_starts_at kept); ended / cancelled stop
-- the checks. A stale lease writes nothing.
CREATE OR REPLACE FUNCTION public.exos_link_out_check_apply(
  p_event_id uuid, p_lease uuid, p_result jsonb, p_error text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  i        public.exos_event_imports%ROWTYPE;
  e        public.exos_events%ROWTYPE;
  d        jsonb := coalesce(p_result, '{}'::jsonb);
  v_status text;
  v_starts timestamptz;
  v_ends   timestamptz;
  v_min    numeric;
  v_max    numeric;
  v_moved  boolean := false;
  v_url    text;
BEGIN
  SELECT * INTO i FROM public.exos_event_imports WHERE event_id = p_event_id FOR UPDATE;
  IF i.event_id IS NULL OR p_lease IS NULL OR i.lease_id IS DISTINCT FROM p_lease THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;

  IF p_result IS NULL THEN
    UPDATE public.exos_event_imports
       SET last_checked_at = now(), check_errors = check_errors + 1,
           last_error = left(coalesce(nullif(p_error, ''), 'The source couldn''t be read.'), 200),
           next_check_at = public._exos_link_out_next_check(e.starts_at, check_errors + 1),
           lease_id = NULL, lease_until = NULL, updated_at = now()
     WHERE event_id = p_event_id;
    RETURN jsonb_build_object('ok', true, 'error', true);
  END IF;

  v_status := coalesce(nullif(d ->> 'source_status', ''), 'unknown');
  IF v_status NOT IN ('on_sale', 'sold_out', 'cancelled', 'ended', 'unknown') THEN v_status := 'unknown'; END IF;
  BEGIN
    v_starts := nullif(d ->> 'starts_at', '')::timestamptz;
    v_ends   := nullif(d ->> 'ends_at', '')::timestamptz;
  EXCEPTION WHEN others THEN
    v_starts := NULL; v_ends := NULL;
  END;
  v_min := CASE WHEN (d ->> 'price_min') ~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN (d ->> 'price_min')::numeric END;
  v_max := CASE WHEN (d ->> 'price_max') ~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN (d ->> 'price_max')::numeric END;
  IF v_min IS NOT NULL AND v_max IS NOT NULL AND v_min > v_max THEN v_min := v_max; END IF;
  v_url := btrim(coalesce(d ->> 'source_url', ''));
  IF v_url = '' OR NOT public._exos_link_out_url_ok(i.platform, i.source_event_id, v_url) THEN v_url := i.source_url; END IF;

  -- Rescheduled at the source (by more than a minute since the last read).
  IF v_starts IS NOT NULL AND i.source_starts_at IS NOT NULL
     AND abs(extract(epoch FROM v_starts - i.source_starts_at)) >= 60 AND v_status <> 'cancelled' THEN
    v_moved := true;
    UPDATE public.exos_events
       SET starts_at = v_starts, ends_at = CASE WHEN v_ends IS NOT NULL AND v_ends >= v_starts THEN v_ends END
     WHERE id = p_event_id;
  END IF;
  IF v_status = 'cancelled' AND e.status <> 'cancelled' THEN
    UPDATE public.exos_events SET status = 'cancelled' WHERE id = p_event_id;
  END IF;
  IF e.external_ticket_url IS DISTINCT FROM v_url THEN
    UPDATE public.exos_events SET external_ticket_url = v_url WHERE id = p_event_id;
  END IF;

  UPDATE public.exos_event_imports
     SET source_status = v_status, source_url = v_url,
         price_min = v_min, price_max = v_max,
         currency = coalesce(CASE WHEN upper(d ->> 'currency') ~ '^[A-Z]{3}$' THEN upper(d ->> 'currency') END, currency),
         is_free = coalesce((d ->> 'is_free') = 'true', false),
         ticket_types = CASE WHEN d ? 'ticket_types' THEN public._exos_link_out_types(d -> 'ticket_types') ELSE ticket_types END,
         source_starts_at = coalesce(v_starts, source_starts_at),
         previous_starts_at = CASE WHEN v_moved THEN e.starts_at ELSE previous_starts_at END,
         rescheduled_at = CASE WHEN v_moved THEN now() ELSE rescheduled_at END,
         last_checked_at = now(), last_ok_at = now(), check_errors = 0, last_error = NULL,
         next_check_at = CASE WHEN v_status IN ('cancelled', 'ended') THEN NULL
                              ELSE public._exos_link_out_next_check(coalesce(v_starts, e.starts_at), 0) END,
         lease_id = NULL, lease_until = NULL, updated_at = now()
   WHERE event_id = p_event_id;
  RETURN jsonb_build_object('ok', true, 'status', v_status, 'rescheduled', v_moved,
                            'cancelled', v_status = 'cancelled' AND e.status <> 'cancelled');
END $$;
REVOKE ALL ON FUNCTION public.exos_link_out_check_apply(uuid, uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_link_out_check_apply(uuid, uuid, jsonb, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Cron: every 15 minutes (the function decides what is due and keeps to a
--    time budget). Guarded so a Postgres without pg_cron applies, and created
--    INACTIVE: every Exos cron is off on prod (Terminal-2 20261021174000).
--    Turn it on with:
--      SELECT cron.alter_job(jobid, active := true) FROM cron.job
--       WHERE jobname = 'exos-event-import-check-15min';
--    after deploying exos-event-import (with CRON_SECRET set).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_job bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-event-import-check-15min') THEN
      v_job := cron.schedule('exos-event-import-check-15min', '7-59/15 * * * *', $cron$
        SELECT public._cron_invoke_edge_fn(
          'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-event-import/cron', '{}'::jsonb);
      $cron$);
      PERFORM cron.alter_job(v_job, active := false);
    END IF;
  END IF;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos-event-import-check-15min');
-- re-create exos_public_event_sale from 20261029100000 and the seven patched
-- functions from their sources; DROP the exos_*_link_out triggers,
-- exos_events_link_out_guard, VIEW exos_public_link_outs, TABLE
-- exos_event_imports and the functions above; DROP CONSTRAINT
-- exos_events_link_out_chk; put the two CHECKs back without 'posh' (no row
-- may use it); DROP COLUMN exos_events.link_out.
