-- ============================================================================
-- Migration 20260926191000 — Exos (Bridge / D4): event links to every marketplace
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_channel_event_links (new)
--              bridge_event_xref (W: sg_event_id / tevo_event_id / aq_short_event_id
--                mirrored from links; existing rows backfilled into links)
--              exos_distribution_listings (W: a manual decision re-queues the
--                event's StubHub request)
--              FUNCTION exos_link_channel_event (new)
--              FUNCTION exos_channel_links_mirror_xref (new, trigger)
-- Pre-reqs: 20260926190000 (StubHub event requests), 20260520120000 (bridge_event_xref)
--
-- One row per (Exos event, marketplace): which of the marketplace's events it
-- is. exos-distribute fills it with a read-only catalog search
-- (_shared/marketplace/match.ts):
--   linked     confident match (same local day, name, venue) or set by staff
--   created    the event was created on the marketplace from Exos (StubHub
--              PUT /sellerevents, once live writes are authorized)
--   review     close call: `candidates` holds the scored options for staff
--   unmatched  searched, nothing close; creation may go ahead where allowed
--   rejected   staff said none of the candidates is this event
-- A marketplace event maps to at most one Exos event (partial unique index),
-- so two Exos events can never both claim the same StubHub/SeatGeek event.
--
-- bridge_event_xref is the older per-event row Terminal-2 reads (D1 routes a
-- buy back to the Exos primary by tevo_event_id). Its SeatGeek / TEvo /
-- Automatiq ids now follow the links table (trigger), and existing values
-- are backfilled into links, so both stay in step.
--
-- Staff decide review rows with exos_link_channel_event(event, channel, id)
-- (id NULL = reject all candidates). Deciding a StubHub row re-queues the
-- event's StubHub request so exos-distribute acts on the decision.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_channel_event_links (
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  channel           text NOT NULL CHECK (channel IN ('stubhub','seatgeek','vivid','tickpick','evo','automatiq')),
  status            text NOT NULL DEFAULT 'unmatched'
                      CHECK (status IN ('unmatched','review','linked','created','rejected')),
  external_event_id text,
  method            text,            -- 'auto_match' | 'manual' | 'created' | 'tevo_xref' | 'backfill'
  confidence        numeric CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
  candidates        jsonb,           -- review: [{external_event_id, name, starts_at, venue, score, reasons}]
  checked_at        timestamptz,
  decided_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, channel),
  CHECK ((status IN ('linked','created')) = (external_event_id IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_channel_event_links_external_uidx
  ON public.exos_channel_event_links (channel, external_event_id)
  WHERE external_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_channel_event_links_status_idx
  ON public.exos_channel_event_links (channel, status);

ALTER TABLE public.exos_channel_event_links ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_channel_event_links_sel ON public.exos_channel_event_links;
CREATE POLICY exos_channel_event_links_sel ON public.exos_channel_event_links FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_channel_event_links FROM anon, authenticated;
GRANT  SELECT ON public.exos_channel_event_links TO authenticated;

-- ---------------------------------------------------------------------------
-- Mirror into bridge_event_xref (the row Terminal-2 reads).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_channel_links_mirror_xref()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ext  text;
  v_live boolean;
BEGIN
  IF NEW.channel NOT IN ('seatgeek','evo','automatiq') THEN
    RETURN NULL;
  END IF;
  v_live := NEW.status IN ('linked','created');
  v_ext  := CASE WHEN v_live THEN NEW.external_event_id END;
  -- bigint columns only take numeric ids; anything else stays out of the xref.
  IF v_ext IS NOT NULL AND NEW.channel IN ('seatgeek','evo') AND v_ext !~ '^[0-9]{1,18}$' THEN
    v_ext := NULL;
  END IF;

  INSERT INTO public.bridge_event_xref (exos_event_id, match_method, matched_at)
  VALUES (NEW.event_id, NEW.method, CASE WHEN v_live THEN now() END)
  ON CONFLICT (exos_event_id) DO NOTHING;

  UPDATE public.bridge_event_xref
     SET sg_event_id       = CASE WHEN NEW.channel = 'seatgeek'  THEN v_ext::bigint ELSE sg_event_id END,
         tevo_event_id     = CASE WHEN NEW.channel = 'evo'       THEN v_ext::bigint ELSE tevo_event_id END,
         aq_short_event_id = CASE WHEN NEW.channel = 'automatiq' THEN v_ext         ELSE aq_short_event_id END,
         match_method      = CASE WHEN v_ext IS NOT NULL THEN coalesce(NEW.method, match_method) ELSE match_method END,
         matched_at        = CASE WHEN v_ext IS NOT NULL THEN now() ELSE matched_at END,
         updated_at        = now()
   WHERE exos_event_id = NEW.event_id;
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_channel_links_mirror_xref() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_channel_event_links_mirror ON public.exos_channel_event_links;
CREATE TRIGGER exos_channel_event_links_mirror
  AFTER INSERT OR UPDATE OF status, external_event_id ON public.exos_channel_event_links
  FOR EACH ROW EXECUTE FUNCTION public.exos_channel_links_mirror_xref();

-- Backfill: ids already in bridge_event_xref become links (never overwrite one).
INSERT INTO public.exos_channel_event_links (event_id, org_id, channel, status, external_event_id, method, confidence, checked_at)
SELECT x.exos_event_id, e.org_id, v.channel, 'linked', v.ext, 'backfill', NULL, x.matched_at
  FROM public.bridge_event_xref x
  JOIN public.exos_events e ON e.id = x.exos_event_id
 CROSS JOIN LATERAL (VALUES
   ('seatgeek',  x.sg_event_id::text),
   ('evo',       x.tevo_event_id::text),
   ('automatiq', nullif(btrim(x.aq_short_event_id), ''))
 ) AS v(channel, ext)
 WHERE v.ext IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.exos_channel_event_links l
                    WHERE l.channel = v.channel AND l.external_event_id = v.ext)
ON CONFLICT (event_id, channel) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Staff: link an event by hand, or reject every candidate (id NULL).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_link_channel_event(
  p_event_id          uuid,
  p_channel           text,
  p_external_event_id text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_org   uuid;
  v_ext   text := nullif(btrim(coalesce(p_external_event_id, '')), '');
  v_other uuid;
  v_status text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_link_channel_event: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_link_channel_event: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_link_channel_event: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_channel NOT IN ('stubhub','seatgeek','vivid','tickpick','evo','automatiq') THEN
    RAISE EXCEPTION 'exos_link_channel_event: unknown channel %', p_channel;
  END IF;
  IF v_ext IS NOT NULL AND (length(v_ext) > 64 OR v_ext !~ '^[A-Za-z0-9._:-]+$') THEN
    RAISE EXCEPTION 'exos_link_channel_event: that is not a % event id', p_channel;
  END IF;
  IF v_ext IS NOT NULL THEN
    SELECT event_id INTO v_other FROM public.exos_channel_event_links
     WHERE channel = p_channel AND external_event_id = v_ext AND event_id <> p_event_id;
    IF v_other IS NOT NULL THEN
      RAISE EXCEPTION 'exos_link_channel_event: % event % is already linked to another Exos event', p_channel, v_ext
        USING ERRCODE = '23505';
    END IF;
  END IF;

  v_status := CASE WHEN v_ext IS NULL THEN 'rejected' ELSE 'linked' END;
  INSERT INTO public.exos_channel_event_links
    (event_id, org_id, channel, status, external_event_id, method, confidence, decided_by, checked_at)
  VALUES (p_event_id, v_org, p_channel, v_status, v_ext, 'manual', CASE WHEN v_ext IS NULL THEN NULL ELSE 1 END, v_uid, now())
  ON CONFLICT (event_id, channel) DO UPDATE
    SET status = EXCLUDED.status, external_event_id = EXCLUDED.external_event_id,
        method = 'manual', confidence = EXCLUDED.confidence, decided_by = v_uid,
        checked_at = now(), updated_at = now();

  -- Let exos-distribute act on the decision: link -> no event creation needed;
  -- reject -> the StubHub event may be created. The request row takes its
  -- event id from the link again, so a re-link replaces the old id. Rows with
  -- a listing on StubHub are left for a human.
  IF p_channel = 'stubhub' THEN
    UPDATE public.exos_distribution_listings
       SET status = 'pending', error = NULL, planned_request = NULL, external_event_id = NULL, updated_at = now()
     WHERE event_id = p_event_id AND channel = 'stubhub'
       AND external_listing_id IS NULL
       AND status IN ('pending','planned','failed');
  END IF;
  RETURN v_status;
END $$;
REVOKE ALL ON FUNCTION public.exos_link_channel_event(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_link_channel_event(uuid, text, text) TO authenticated;
