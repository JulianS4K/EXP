-- ============================================================================
-- Migration 20260929051000 — Exos (Bridge / D4): marketplace orders that need
-- a person: alerts, resend, mark handled
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_marketplace_orders (+handled_at, handled_by,
--              handled_reason, links_resent_at, links_resent_by; alert trigger)
--              exos_mail (template 'marketplace-attention' allowed)
--           C: exos_marketplace_attention_alerts,
--              exos_tg_marketplace_attention(),
--              exos_resend_marketplace_claim_links(uuid),
--              exos_mark_marketplace_order_handled(uuid, text)
--           W: FUNCTION exos_record_marketplace_order(jsonb) (patched in place)
-- Pre-reqs: 20260929050000
--
-- A marketplace order that goes to 'needs_attention' (no buyer email,
-- oversold, several listings, cancelled after a scan, ...) only showed in the
-- event editor, so nobody knew to look.
--
-- 1. Alert. When an order enters needs_attention, or its reason changes, the
--    org's owner and active managers get a mail (template
--    'marketplace-attention'), built here with every value escaped and a link
--    to the event editor ({{app_url}}, filled by exos-mail-drain). Once per
--    order + reason (exos_marketplace_attention_alerts): the sales poller
--    re-reports parked orders every run, and those retries don't mail again.
--    An order already marked handled doesn't alert.
-- 2. Resend claim links. exos_resend_marketplace_claim_links(order) re-queues
--    the transfer mail to the order's buyer email with a claim link per
--    still-pending transfer (?k= claim key, as the original). Owner/manager
--    only; once per 10 minutes per order.
-- 3. Mark handled. exos_mark_marketplace_order_handled(order, note) records
--    who and when (and the reason they handled). A handled order is no longer
--    retried automatically: exos_record_marketplace_order leaves it parked,
--    so a person who delivered by hand never gets a second, automatic set of
--    tickets minted behind them. A marketplace cancellation still applies.
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE; the patch asserts one match
-- and is skipped once applied). D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_sig text, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected one match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

ALTER TABLE public.exos_marketplace_orders ADD COLUMN IF NOT EXISTS handled_at timestamptz;
ALTER TABLE public.exos_marketplace_orders ADD COLUMN IF NOT EXISTS handled_by uuid;
ALTER TABLE public.exos_marketplace_orders ADD COLUMN IF NOT EXISTS handled_reason text;
ALTER TABLE public.exos_marketplace_orders ADD COLUMN IF NOT EXISTS handled_note text;
ALTER TABLE public.exos_marketplace_orders ADD COLUMN IF NOT EXISTS links_resent_at timestamptz;
ALTER TABLE public.exos_marketplace_orders ADD COLUMN IF NOT EXISTS links_resent_by uuid;
COMMENT ON COLUMN public.exos_marketplace_orders.handled_at IS
  'A person marked this needs_attention order handled (exos_mark_marketplace_order_handled); it is no longer retried automatically.';

-- ── mail template ──────────────────────────────────────────────────────────

DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF strpos(coalesce(v_def, ''), '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live
      FROM regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g') AS m;
  END IF;
  IF 'marketplace-attention' = ANY (coalesce(v_live, '{}'::text[])) THEN
    RETURN;  -- already allowed; leave the live list alone
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION
    SELECT unnest(ARRAY[
      'transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled',
      'event-reminder','order-failed','checkout-abandoned','marketplace-attention'])
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- ── 1. Alert ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.exos_marketplace_attention_alerts (
  order_id   uuid NOT NULL REFERENCES public.exos_marketplace_orders(id) ON DELETE CASCADE,
  reason_md5 text NOT NULL,
  reason     text,
  recipients int  NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (order_id, reason_md5)
);
ALTER TABLE public.exos_marketplace_attention_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_marketplace_attention_alerts FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_channel_label(p_channel text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE p_channel WHEN 'stubhub' THEN 'StubHub' WHEN 'seatgeek' THEN 'SeatGeek' WHEN 'gametime' THEN 'Gametime'
    WHEN 'gotickets' THEN 'GoTickets' WHEN 'vivid' THEN 'Vivid Seats' WHEN 'tickpick' THEN 'TickPick'
    WHEN 'evo' THEN 'Ticket Evolution' WHEN 'automatiq' THEN 'Automatiq' ELSE initcap(coalesce(p_channel, 'marketplace')) END;
$$;

CREATE OR REPLACE FUNCTION public.exos_tg_marketplace_attention()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_reason text := coalesce(NEW.attention_reason, 'no reason given');
  v_ev     text;
  v_owner  uuid;
  v_n      int := 0;
  v_subj   text;
  v_html   text;
  r        record;
BEGIN
  IF NEW.status <> 'needs_attention' OR NEW.handled_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'needs_attention'
     AND OLD.attention_reason IS NOT DISTINCT FROM NEW.attention_reason THEN
    RETURN NEW;
  END IF;
  -- Once per order + reason.
  INSERT INTO public.exos_marketplace_attention_alerts (order_id, reason_md5, reason)
  VALUES (NEW.id, md5(v_reason), left(v_reason, 500))
  ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT name INTO v_ev FROM public.exos_events WHERE id = NEW.event_id;
  SELECT owner_uid INTO v_owner FROM public.exos_orgs WHERE id = NEW.org_id;
  v_subj := left('Action needed: ' || public.exos_channel_label(NEW.channel) || ' order ' ||
                 NEW.external_order_id || ' for ' || coalesce(v_ev, 'your event'), 200);
  v_html :=
    '<p>A ' || public.exos_mail_escape(public.exos_channel_label(NEW.channel)) || ' order for <strong>' ||
    public.exos_mail_escape(coalesce(v_ev, 'your event')) || '</strong> needs a person.</p>' ||
    '<p>Order ' || public.exos_mail_escape(NEW.external_order_id) || ' &middot; ' || NEW.quantity ||
    ' ticket' || CASE WHEN NEW.quantity = 1 THEN '' ELSE 's' END || '</p>' ||
    '<p><strong>Why:</strong> ' || public.exos_mail_escape(v_reason) || '</p>' ||
    '<p><a href="{{app_url}}/edit-event/' || NEW.event_id || '">Open the event</a> and look under Marketplace sales. ' ||
    'Once it''s taken care of, mark it handled there.</p>';
  FOR r IN
    SELECT DISTINCT lower(u.email) AS email
      FROM auth.users u
     WHERE u.email IS NOT NULL AND u.email <> ''
       AND (u.id = v_owner OR u.id IN (
             SELECT m.user_id FROM public.exos_org_memberships m
              WHERE m.org_id = NEW.org_id AND m.role IN ('owner','manager') AND m.disabled IS NOT TRUE))
  LOOP
    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES ('marketplace-attention', r.email, v_subj, v_html, v_owner, 'pending');
    v_n := v_n + 1;
  END LOOP;
  UPDATE public.exos_marketplace_attention_alerts SET recipients = v_n
   WHERE order_id = NEW.id AND reason_md5 = md5(v_reason);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_marketplace_attention() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_marketplace_orders_attention ON public.exos_marketplace_orders;
CREATE TRIGGER exos_marketplace_orders_attention
  AFTER INSERT OR UPDATE OF status, attention_reason ON public.exos_marketplace_orders
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_marketplace_attention();

-- ── 2. Resend claim links ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.exos_resend_marketplace_claim_links(p_order_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o       public.exos_marketplace_orders%ROWTYPE;
  v_ev    text;
  v_links text := '';
  v_n     int := 0;
  v_label text;
  r       record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_resend_marketplace_claim_links: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE id = p_order_id FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'exos_resend_marketplace_claim_links: order not found';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(o.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_resend_marketplace_claim_links: not authorized' USING ERRCODE = '42501';
  END IF;
  IF o.buyer_email IS NULL THEN
    RAISE EXCEPTION 'exos_resend_marketplace_claim_links: the marketplace gave no buyer email';
  END IF;
  IF o.links_resent_at IS NOT NULL AND o.links_resent_at > now() - interval '10 minutes' THEN
    RAISE EXCEPTION 'exos_resend_marketplace_claim_links: links were resent a few minutes ago; try again later';
  END IF;
  FOR r IN
    SELECT tr.id, tr.claim_key, row_number() OVER (ORDER BY array_position(o.transfer_ids, tr.id)) AS i
      FROM public.exos_transfers tr
     WHERE tr.id = ANY (o.transfer_ids) AND tr.status = 'pending'
     ORDER BY array_position(o.transfer_ids, tr.id)
  LOOP
    v_links := v_links || '<li><a href="{{app_url}}/claim/' || r.id ||
               CASE WHEN r.claim_key IS NOT NULL THEN '?k=' || public.exos_mail_escape(r.claim_key) ELSE '' END ||
               '">Claim ticket ' || r.i || '</a></li>';
    v_n := v_n + 1;
  END LOOP;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'exos_resend_marketplace_claim_links: no unclaimed tickets on this order';
  END IF;
  SELECT name INTO v_ev FROM public.exos_events WHERE id = o.event_id;
  v_label := public.exos_channel_label(o.channel);
  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES ('transfer-initiated', o.buyer_email,
          left('Your ' || v_label || ' ticket' || CASE WHEN v_n > 1 THEN 's' ELSE '' END || ' for ' || coalesce(v_ev, 'your event') || ' (links again)', 200),
          '<p>Here are the claim links for your ' || public.exos_mail_escape(v_label) || ' order ' ||
          public.exos_mail_escape(o.external_order_id) || ' for <strong>' ||
          public.exos_mail_escape(coalesce(v_ev, 'your event')) || '</strong> again. ' ||
          'Open a link and sign in with any Exos account, or create one, to claim the ticket and get your entry QR code.</p>' ||
          '<ul>' || v_links || '</ul>' ||
          '<p>Whoever claims a link first gets that ticket, so keep this email to yourself.</p>',
          auth.uid(), 'pending');
  UPDATE public.exos_marketplace_orders
     SET links_resent_at = now(), links_resent_by = auth.uid(), updated_at = now()
   WHERE id = o.id;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_resend_marketplace_claim_links(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_resend_marketplace_claim_links(uuid) TO authenticated;

-- ── 3. Mark handled ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.exos_mark_marketplace_order_handled(p_order_id uuid, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_marketplace_orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_mark_marketplace_order_handled: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE id = p_order_id FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'exos_mark_marketplace_order_handled: order not found';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(o.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_mark_marketplace_order_handled: not authorized' USING ERRCODE = '42501';
  END IF;
  IF o.status <> 'needs_attention' THEN
    RAISE EXCEPTION 'exos_mark_marketplace_order_handled: only an order that needs attention can be marked handled';
  END IF;
  UPDATE public.exos_marketplace_orders
     SET handled_at = now(), handled_by = auth.uid(), handled_reason = o.attention_reason,
         handled_note = left(nullif(btrim(p_note), ''), 500), updated_at = now()
   WHERE id = o.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_mark_marketplace_order_handled(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_mark_marketplace_order_handled(uuid, text) TO authenticated;

-- A handled order stays parked: a new report of the sale doesn't retry it.
SELECT pg_temp.exos_patch('public.exos_record_marketplace_order(jsonb)',
  'o.handled_at IS NULL',
  'IF v_sale <> ''cancelled'' AND o.status = ''needs_attention'' AND cardinality(o.ticket_ids) = 0 THEN',
  'IF v_sale <> ''cancelled'' AND o.status = ''needs_attention'' AND cardinality(o.ticket_ids) = 0 AND o.handled_at IS NULL THEN');
