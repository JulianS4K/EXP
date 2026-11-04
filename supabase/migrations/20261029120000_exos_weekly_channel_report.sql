-- ============================================================================
-- Sales by channel, and a weekly organizer report (distribution spec §7 item 7)
-- ============================================================================
-- Touches:  C: TABLE exos_channel_report_settings (per-org switch + the SMS
--              number; RPCs only), exos_channel_reports (one row per org and
--              ISO week: the idempotency key and what was sent),
--              exos_sms_stops (durable STOP per org + number, until START)
--           C: FUNCTION _exos_channel_key, _exos_channel_label,
--              _exos_channel_out_key, _exos_channel_detail (pure);
--              _exos_sms_stopped (internal);
--              _exos_channel_lines, _exos_channel_sales, _exos_channel_totals,
--              _exos_channel_event_json, _exos_channel_report_payload
--              (internal, no client grant);
--              exos_channel_sales, exos_event_channel_report,
--              exos_org_channel_report, exos_channel_report_settings
--              (owner / manager / finance), exos_set_channel_report (owner);
--              exos_send_channel_reports (service role, the cron entry)
--           W: exos_mail template allowlist (+ org-channel-report, union block),
--              exos_sms_campaigns audience (+ staff_report),
--              exos_mail_dedupe (claims the week's org-weekly-summary key for
--              everyone who got this report, so nobody gets two weekly mails)
--           R: CREATE OR REPLACE exos_sms_inbound (STOP also turns the weekly
--              text off for that number)
--           R: exos_tickets, exos_checkout_sessions, exos_vouchers,
--              exos_order_refunds, exos_marketplace_orders,
--              exos_guest_list_entries, exos_eventbrite_ticket_links,
--              exos_luma_ticket_links, exos_events, exos_orgs,
--              exos_org_integrations, exos_sms_subscribers
-- Pre-reqs: 20261016110000 (promo links), 20260924223000 (attribution),
--           20260929131000 (fee split per checkout), 20260929062000
--           (marketplace fees), 20261013100000 / 20261016100000 (Eventbrite
--           and backend attendees as door entries), 20261019090000 (Luma
--           ticket links), 20260929071000 / 20261001101000 (mail templates),
--           20261016120000 (SMS)
--
-- Every ticket Exos knows about is credited to one channel. A line is one
-- order (Exos checkout, marketplace order) or one ticket / door entry:
--
--   group        channel                           kind      where the data is
--   exos         promo link channel, else UTM      sale      exos_checkout_sessions (paid) and
--                source, promoter, AI assistant,              exos_tickets (free claims: the
--                ad click id; else "direct"                   ?utm_source / ?promoter they came with)
--   box_office   box_office                        sale      exos_tickets with a price, minted by staff
--   marketplace  stubhub, seatgeek, vivid, ...     sale      exos_marketplace_orders
--   eventbrite   eventbrite                        sale      door entries eb:<attendee> (sync), else
--                                                            exos_eventbrite_ticket_links.eb_sold (no dates)
--   luma         luma                              sale      door entries lu:<guest> (sync), else
--                                                            exos_luma_ticket_links.luma_sold (no dates)
--   platform     pretix, hievents                  sale      door entries px: / he: (backend sync)
--   comp         comp, staff_issued,               comp      comp batches, free staff issues, referral
--                referral_reward, guest_list                 rewards, manual guest-list entries
--   imported     import:<source>                   attendee  CSV door imports (Posh, ...): no price,
--                                                            so other-platform attendees, never sales
--
-- Comps and imported attendees are listed but are never sales and never in
-- the totals. Voided tickets, voided door entries, fully refunded checkouts
-- and cancelled marketplace orders are left out.
--
-- Money (cents) per line: gross, the channel's fee, the Exos fee, and net to
-- the organizer, using only what Exos recorded:
--   * Exos checkout: gross = amount charged less succeeded refunds; channel
--     fee = card processing charged to the organizer (card_fee_est_cents, the
--     part of the Stripe application fee set at checkout); Exos fee =
--     exos_fee_cents (0 in the free months); net = gross - application fee.
--     A paid checkout from before the fee split was recorded: fees not reported.
--   * Marketplace: gross = listed price x quantity, channel fee =
--     marketplace_fee, Exos fee = exos_fee, net = organizer_net (each NULL
--     when the marketplace didn't report it; mig 20260929062000).
--   * Eventbrite, Luma, pretix, hi.events: tickets only. Their syncs don't
--     read prices or fees, so gross, fee and net are NULL ("not reported").
--     A platform's fee is never estimated.
--   * Box office: gross = the ticket price, no fees.
-- NULL means "not reported"; a total adds the known values and counts the
-- tickets left out. Passed-on / absorbed org fee rules (exos_order_fees) are
-- not on this branch; they join when that table lands.
--
-- Dates: a checkout counts when it was fulfilled, a marketplace order when it
-- sold, a ticket when it was minted, a door entry when the sync first saw it
-- (within one sync of the sale). Platform counts read from ticket links have
-- no dates: they are in "to date" only.
--
-- Weekly report: exos_send_channel_reports() (service role) mails each org's
-- owner and managers the past ISO week (Monday to Monday, UTC) and to-date
-- numbers per channel for every event that started in the last 7 days or
-- starts in the next 60, plus totals. On by default (exos_channel_report_settings,
-- owner switch); a person who unsubscribed from follow-ups
-- (exos_mail_prefs.marketing_opt_out) is skipped. Once per org and ISO week:
-- exos_channel_reports (PK org_id, iso_week) plus a dedupe key per person.
-- It also claims the same week's org-weekly-summary key for each person it
-- mailed, so the older summary isn't sent on top. A text goes to the number
-- the owner set, only when the org has Twilio / Telnyx connected and that
-- number hasn't replied STOP; it waits for 9:00-20:00 New York time and is a
-- dry run until EXOS_SMS_LIVE=on (exos-sms-drain). STOP is durable
-- (exos_sms_stops): the number is cleared, can't be saved again, and is
-- re-checked at send time, until it texts START. (Follow-up, not built: verify
-- the number with a code when the owner saves it.)
--
-- Labels: utm_source is buyer-controlled, so the mail, the text and the SPA
-- only show labels from _exos_channel_label's fixed list; promoter codes and
-- import sources are grouped, every other key is "Other". Keys in any output
-- keep [a-z0-9_-] only.
--
-- Cron: scheduled INACTIVE when pg_cron is present (Exos crons are off on
-- prod; the operator turns it on, docs/email.md). A job that already exists is
-- left as it is. Re-run safe. Prod apply needs operator OK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Settings and the sent-report ledger
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_channel_report_settings (
  org_id      uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  enabled     boolean NOT NULL DEFAULT true,
  sms_phone   text CHECK (sms_phone IS NULL OR sms_phone ~ '^\+[1-9][0-9]{7,14}$'),
  updated_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.exos_channel_report_settings IS
  'Weekly channel report per org (mig 20261029120000). No row = on, no text. sms_phone: where the weekly text goes. RPCs only.';
ALTER TABLE public.exos_channel_report_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_channel_report_settings FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_channel_report_settings TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_channel_reports (
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  iso_week    text NOT NULL CHECK (iso_week ~ '^[0-9]{4}-W[0-9]{2}$'),
  week_start  timestamptz NOT NULL,
  payload     jsonb NOT NULL,
  mails       integer NOT NULL DEFAULT 0,
  texts       integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, iso_week)
);
COMMENT ON TABLE public.exos_channel_reports IS
  'One weekly channel report per org and ISO week (mig 20261029120000): the PK keeps a re-run from sending twice.';
ALTER TABLE public.exos_channel_reports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_channel_reports FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_channel_reports TO service_role;

-- Every STOP an org's number received, kept until that number texts START.
-- Durable: clearing the report number alone would let it be saved again.
-- (exos_sms_subscribers isn't used for this: a row there needs the fan's
-- consent text and feeds the fan audience and its opted-out count.)
CREATE TABLE IF NOT EXISTS public.exos_sms_stops (
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  phone       text NOT NULL CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  stopped_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, phone)
);
COMMENT ON TABLE public.exos_sms_stops IS
  'Numbers that replied STOP to an org (exos_sms_inbound; START removes the row). The weekly report text never goes to one, and it can''t be saved as the report number (mig 20261029120000).';
ALTER TABLE public.exos_sms_stops ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_sms_stops FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_sms_stops TO service_role;

-- A number may not be texted by this org: it replied STOP (and not START since).
CREATE OR REPLACE FUNCTION public._exos_sms_stopped(p_org_id uuid, p_phone text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_sms_stops s WHERE s.org_id = p_org_id AND s.phone = p_phone)
      OR EXISTS (SELECT 1 FROM public.exos_sms_subscribers ss
                  WHERE ss.org_id = p_org_id AND ss.phone = p_phone AND ss.opted_out_at IS NOT NULL)
$$;
REVOKE ALL ON FUNCTION public._exos_sms_stopped(uuid, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Channel names
-- ---------------------------------------------------------------------------
-- A UTM source (or promo-link channel) as a channel key. Aliases merge
-- ("ig", "l.instagram.com" -> instagram); paid traffic from Meta / Google is
-- its own channel; anything else keeps its own name, cleaned.
CREATE OR REPLACE FUNCTION public._exos_channel_key(p_source text, p_medium text DEFAULT NULL)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  WITH s AS (
    SELECT regexp_replace(regexp_replace(regexp_replace(lower(btrim(coalesce(p_source, ''))),
             '^(https?://)?(www\.|m\.|l\.|lm\.|mobile\.)?', ''), '(\.com|\.co|\.net|\.ai)?(/.*)?$', ''),
             '[^a-z0-9._-]+', '-', 'g') AS v,
           lower(btrim(coalesce(p_medium, ''))) AS m
  ), k AS (
    SELECT CASE
      WHEN v IN ('instagram', 'ig', 'insta') THEN 'instagram'
      WHEN v IN ('facebook', 'fb') THEN 'facebook'
      WHEN v IN ('tiktok', 'tt') THEN 'tiktok'
      WHEN v IN ('x', 'twitter', 't') THEN 'x'
      WHEN v IN ('email', 'e-mail', 'newsletter', 'mailchimp', 'klaviyo', 'mail') THEN 'email'
      WHEN v IN ('sms', 'text', 'texts') THEN 'sms'
      WHEN v IN ('whatsapp', 'wa') THEN 'whatsapp'
      WHEN v IN ('flyer', 'qr', 'poster', 'print') THEN 'flyer'
      WHEN v IN ('partner', 'partners', 'partner-site') THEN 'partner'
      WHEN v IN ('meta-ads', 'facebook-ads', 'instagram-ads') THEN 'meta-ads'
      WHEN v IN ('google-ads', 'adwords') THEN 'google-ads'
      WHEN v = 'google' THEN 'google'
      WHEN v IN ('chatgpt', 'openai', 'chat.openai', 'claude', 'perplexity', 'gemini', 'gemini.google',
                 'copilot', 'copilot.microsoft', 'grok', 'mistral', 'deepseek', 'ai_assistant', 'ai') THEN 'ai'
      WHEN v = 'meta' THEN 'meta'
      WHEN v IN ('link', 'share_sheet', 'share') THEN 'share'
      WHEN v = '' THEN NULL
      -- Anyone can put anything in utm_source: an unknown key keeps only
      -- [a-z0-9_-] (no dots, so no domain), and its label is "Other".
      ELSE left(btrim(regexp_replace(v, '[^a-z0-9_-]+', '', 'g'), '-_'), 40)
    END AS c, m FROM s
  )
  SELECT CASE
    WHEN c IN ('instagram', 'facebook', 'meta') AND m IN ('cpc', 'paid', 'ppc', 'paid_social', 'paidsocial') THEN 'meta-ads'
    WHEN c = 'google' AND m IN ('cpc', 'paid', 'ppc') THEN 'google-ads'
    ELSE nullif(c, '')
  END FROM k
$$;
REVOKE ALL ON FUNCTION public._exos_channel_key(text, text) FROM PUBLIC, anon, authenticated;

-- THE one place a channel gets its display label (the mail, the text and the
-- SPA all show this label; nothing renders a buyer-supplied key as a label).
-- Fixed labels only: Exos' own channels, the platforms and marketplaces.
-- Promoter codes and import sources are grouped ("Promoters", "Imported
-- list"); every other key is "Other". The detail behind a grouped / Other
-- row is _exos_channel_detail ([a-z0-9_-] only), shown by the dashboard alone.
CREATE OR REPLACE FUNCTION public._exos_channel_label(p_channel text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE p_channel
    WHEN 'direct' THEN 'Direct / unknown'
    WHEN 'instagram' THEN 'Instagram'
    WHEN 'facebook' THEN 'Facebook'
    WHEN 'tiktok' THEN 'TikTok'
    WHEN 'x' THEN 'X / Twitter'
    WHEN 'email' THEN 'Email'
    WHEN 'sms' THEN 'Text message'
    WHEN 'whatsapp' THEN 'WhatsApp'
    WHEN 'flyer' THEN 'Flyer / QR code'
    WHEN 'partner' THEN 'Partner sites'
    WHEN 'meta-ads' THEN 'Meta ads'
    WHEN 'google-ads' THEN 'Google ads'
    WHEN 'google' THEN 'Google'
    WHEN 'meta' THEN 'Meta (Facebook / Instagram)'
    WHEN 'reddit' THEN 'Reddit'
    WHEN 'snapchat' THEN 'Snapchat'
    WHEN 'microsoft' THEN 'Microsoft Ads'
    WHEN 'embed' THEN 'Venue site embed'
    WHEN 'ai' THEN 'AI assistants'
    WHEN 'promo' THEN 'Promo links'
    WHEN 'share' THEN 'Shared links'
    WHEN 'box_office' THEN 'Box office'
    WHEN 'eventbrite' THEN 'Eventbrite'
    WHEN 'luma' THEN 'Luma'
    WHEN 'pretix' THEN 'pretix'
    WHEN 'hievents' THEN 'hi.events'
    WHEN 'stubhub' THEN 'StubHub'
    WHEN 'seatgeek' THEN 'SeatGeek'
    WHEN 'vivid' THEN 'Vivid Seats'
    WHEN 'gametime' THEN 'Gametime'
    WHEN 'tickpick' THEN 'TickPick'
    WHEN 'gotickets' THEN 'GoTickets'
    WHEN 'evo' THEN 'TEvo'
    WHEN 'tevo' THEN 'TEvo'
    WHEN 'automatiq' THEN 'Automatiq'
    WHEN 's4k' THEN 'S4K network'
    WHEN 'comp' THEN 'Comps'
    WHEN 'staff_issued' THEN 'Issued by staff'
    WHEN 'referral_reward' THEN 'Referral rewards'
    WHEN 'guest_list' THEN 'Guest lists'
    WHEN 'posh' THEN 'Posh'
    WHEN 'import' THEN 'Imported list'
    WHEN 'import:posh' THEN 'Imported list (Posh)'
    ELSE CASE
      WHEN p_channel LIKE 'promoter:%' THEN 'Promoters'
      WHEN p_channel LIKE 'import:%' THEN 'Imported list'
      ELSE 'Other'
    END
  END
$$;
REVOKE ALL ON FUNCTION public._exos_channel_label(text) FROM PUBLIC, anon, authenticated;

-- A channel key for output: [a-z0-9_-] only ("promoter:DJ-Kay" -> "promoter-dj-kay").
CREATE OR REPLACE FUNCTION public._exos_channel_out_key(p_channel text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT left(regexp_replace(replace(lower(coalesce(p_channel, '')), ':', '-'), '[^a-z0-9_-]+', '', 'g'), 80)
$$;
REVOKE ALL ON FUNCTION public._exos_channel_out_key(text) FROM PUBLIC, anon, authenticated;

-- What a grouped or "Other" label stands for (the promoter code, the import
-- source, the unknown key), [a-z0-9_-] only; NULL for a fixed channel.
CREATE OR REPLACE FUNCTION public._exos_channel_detail(p_channel text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN public._exos_channel_label(p_channel) NOT IN ('Promoters', 'Imported list', 'Other') THEN NULL
    ELSE nullif(left(regexp_replace(lower(regexp_replace(coalesce(p_channel, ''), '^(promoter|import):', '')), '[^a-z0-9_-]+', '', 'g'), 40), '')
  END
$$;
REVOKE ALL ON FUNCTION public._exos_channel_detail(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lines: one per order / ticket / door entry, with its channel and money
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_channel_lines(p_event_id uuid)
RETURNS TABLE (channel text, channel_group text, kind text, currency text, tickets integer,
               gross_cents bigint, fee_cents bigint, exos_fee_cents bigint, net_cents bigint,
               fees text, at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH ev AS (
    SELECT e.id, lower(coalesce(nullif(e.currency, ''), 'usd')) AS cur
      FROM public.exos_events e WHERE e.id = p_event_id
  ), mk AS (
    SELECT DISTINCT unnest(o.ticket_ids) AS tid
      FROM public.exos_marketplace_orders o
     WHERE o.event_id = p_event_id AND o.ticket_ids IS NOT NULL
  ), sess AS (
    SELECT s.session_id, s.amount_cents, s.currency, s.application_fee_cents, s.exos_fee_cents, s.card_fee_est_cents,
           s.attribution, s.ad_ids, s.fulfilled_at, s.created_at, v.link_label, v.link_channel,
           nullif(coalesce(nullif(s.promoter_id, ''), s.attribution ->> 'promoter'), '') AS promoter,
           (SELECT count(*) FROM public.exos_tickets t
             WHERE t.order_ref = s.session_id AND t.event_id = s.event_id AND t.status <> 'voided')::int AS live,
           coalesce((SELECT sum(rf.amount_cents) FROM public.exos_order_refunds rf
                      WHERE rf.session_id = s.session_id AND rf.status = 'succeeded'), 0)::bigint AS refunded
      FROM public.exos_checkout_sessions s
      LEFT JOIN public.exos_vouchers v ON v.id = s.voucher_id
     WHERE s.event_id = p_event_id AND s.status IN ('fulfilled', 'partially_refunded')
  ), tix AS (
    SELECT t.*, lower(coalesce(nullif(btrim(t.channel_source), ''), 'vibepass')) AS cs,
           round(coalesce(t.price_paid, 0) * 100)::bigint AS cents
      FROM public.exos_tickets t
     WHERE t.event_id = p_event_id AND t.status <> 'voided'
       AND NOT EXISTS (SELECT 1 FROM mk WHERE mk.tid = t.id)
       -- Paid Exos tickets are counted through their checkout below.
       AND NOT (lower(coalesce(t.channel_source, '')) = 'stripe'
                AND EXISTS (SELECT 1 FROM public.exos_checkout_sessions s2 WHERE s2.session_id = t.order_ref))
  ), entries AS (
    SELECT g.*, (1 + coalesce(g.plus_ones, 0))::int AS heads
      FROM public.exos_guest_list_entries g
     WHERE g.event_id = p_event_id AND g.voided_at IS NULL
  )
  -- Exos checkouts: credited to the promo link, else the UTM source, the
  -- promoter, the AI assistant, the ad click id; else direct.
  SELECT CASE
           WHEN s.link_label IS NOT NULL THEN coalesce(public._exos_channel_key(s.link_channel), 'promo')
           WHEN public._exos_channel_key(s.attribution ->> 'utm_source', s.attribution ->> 'utm_medium') IS NOT NULL
             THEN public._exos_channel_key(s.attribution ->> 'utm_source', s.attribution ->> 'utm_medium')
           WHEN s.promoter ~ '^[A-Za-z0-9_-]{1,64}$' THEN 'promoter:' || s.promoter
           WHEN nullif(s.attribution ->> 'ai_ref', '') IS NOT NULL THEN 'ai'
           WHEN coalesce(s.ad_ids ?| ARRAY['gclid', 'gbraid', 'wbraid'], false) THEN 'google'
           WHEN coalesce(s.ad_ids ?| ARRAY['fbclid', 'fbc'], false) OR coalesce(s.attribution ? 'fbclid', false) THEN 'meta'
           WHEN coalesce(s.ad_ids ? 'ttclid', false) THEN 'tiktok'
           WHEN coalesce(s.ad_ids ? 'rdt_cid', false) THEN 'reddit'
           WHEN coalesce(s.ad_ids ? 'ScCid', false) THEN 'snapchat'
           WHEN coalesce(s.ad_ids ? 'twclid', false) THEN 'x'
           WHEN coalesce(s.ad_ids ? 'msclkid', false) THEN 'microsoft'
           ELSE 'direct'
         END,
         'exos', 'sale', lower(coalesce(nullif(s.currency, ''), (SELECT cur FROM ev))), s.live,
         (s.amount_cents - s.refunded),
         CASE WHEN s.amount_cents = 0 THEN 0 WHEN s.application_fee_cents IS NULL THEN NULL
              ELSE coalesce(s.card_fee_est_cents, s.application_fee_cents - s.exos_fee_cents) END,
         CASE WHEN s.amount_cents = 0 THEN 0 WHEN s.application_fee_cents IS NULL THEN NULL
              ELSE coalesce(s.exos_fee_cents, s.application_fee_cents - s.card_fee_est_cents) END,
         CASE WHEN s.amount_cents = 0 THEN 0 WHEN s.application_fee_cents IS NULL THEN NULL
              ELSE s.amount_cents - s.refunded - s.application_fee_cents END,
         CASE WHEN s.amount_cents = 0 THEN 'none' WHEN s.application_fee_cents IS NULL THEN 'not_reported' ELSE 'reported' END,
         coalesce(s.fulfilled_at, s.created_at)
    FROM sess s
  UNION ALL
  -- Tickets minted outside a checkout.
  SELECT x.channel, x.grp, x.kind, (SELECT cur FROM ev), 1,
         CASE WHEN x.grp = 'comp' THEN NULL ELSE x.cents END,
         CASE WHEN x.fees = 'none' THEN 0 END,
         CASE WHEN x.fees = 'none' THEN 0 END,
         CASE WHEN x.fees = 'none' AND x.grp <> 'comp' THEN x.cents END,
         x.fees, x.created_at
    FROM (
      SELECT t.created_at, t.cents,
             CASE
               WHEN t.cs = 'comp' THEN 'comp'
               WHEN t.cs = 'referral_reward' THEN 'referral_reward'
               WHEN t.cs = 'boxoffice' AND t.cents = 0 THEN 'staff_issued'
               WHEN t.cs IN ('s4k', 'gotickets', 'gametime', 'stubhub', 'seatgeek', 'vivid', 'tickpick', 'evo', 'tevo', 'automatiq') THEN t.cs
               WHEN t.cs = 'stripe' AND t.promoter_id ~ '^[A-Za-z0-9_-]{1,64}$' THEN 'promoter:' || t.promoter_id
               WHEN t.cs = 'stripe' THEN 'direct'
               WHEN t.cents > 0 THEN 'box_office'
               WHEN t.cs NOT IN ('vibepass', 'exos', 'free', 'boxoffice', 'stripe') AND public._exos_channel_key(t.cs) IS NOT NULL
                 THEN public._exos_channel_key(t.cs)
               WHEN t.promoter_id ~ '^[A-Za-z0-9_-]{1,64}$' THEN 'promoter:' || t.promoter_id
               ELSE 'direct'
             END AS channel,
             CASE
               WHEN t.cs IN ('comp', 'referral_reward') OR (t.cs = 'boxoffice' AND t.cents = 0) THEN 'comp'
               WHEN t.cs IN ('s4k', 'gotickets', 'gametime', 'stubhub', 'seatgeek', 'vivid', 'tickpick', 'evo', 'tevo', 'automatiq') THEN 'marketplace'
               WHEN t.cents > 0 AND t.cs <> 'stripe' THEN 'box_office'
               ELSE 'exos'
             END AS grp,
             CASE WHEN t.cs IN ('comp', 'referral_reward') OR (t.cs = 'boxoffice' AND t.cents = 0) THEN 'comp' ELSE 'sale' END AS kind,
             CASE
               WHEN t.cs IN ('comp', 'referral_reward') OR (t.cs = 'boxoffice' AND t.cents = 0) THEN 'none'
               WHEN t.cs IN ('s4k', 'gotickets', 'gametime', 'stubhub', 'seatgeek', 'vivid', 'tickpick', 'evo', 'tevo', 'automatiq') THEN 'not_reported'
               -- A paid Exos ticket with no checkout row (older data): fees unknown.
               WHEN t.cs = 'stripe' AND t.cents > 0 THEN 'not_reported'
               ELSE 'none'
             END AS fees
        FROM tix t
    ) x
  UNION ALL
  -- Marketplace orders: the marketplace's own figures (mig 20260929062000).
  SELECT o.channel, 'marketplace', 'sale', lower(coalesce(nullif(o.currency, ''), (SELECT cur FROM ev))), o.quantity,
         round(o.list_unit_price * o.quantity * 100)::bigint,
         round(o.marketplace_fee * 100)::bigint,
         round(o.exos_fee * 100)::bigint,
         round(o.organizer_net * 100)::bigint,
         CASE WHEN o.marketplace_fee IS NULL THEN 'not_reported' ELSE 'reported' END,
         coalesce(o.sold_at, o.created_at)
    FROM public.exos_marketplace_orders o
   WHERE o.event_id = p_event_id AND o.status <> 'cancelled' AND o.sale_status <> 'cancelled'
  UNION ALL
  -- Other platforms, from the attendees their syncs bring in (counts only).
  SELECT CASE WHEN g.external_ref LIKE 'eb:%' THEN 'eventbrite' WHEN g.external_ref LIKE 'lu:%' THEN 'luma'
              WHEN g.external_ref LIKE 'px:%' THEN 'pretix' ELSE 'hievents' END,
         CASE WHEN g.external_ref LIKE 'eb:%' THEN 'eventbrite' WHEN g.external_ref LIKE 'lu:%' THEN 'luma' ELSE 'platform' END,
         'sale', (SELECT cur FROM ev), 1, NULL, NULL, 0, NULL, 'not_reported', g.created_at
    FROM entries g
   WHERE g.external_ref ~ '^(eb|lu|px|he):'
  UNION ALL
  -- No synced attendees: the platform's sold count from the inventory sync (no dates).
  SELECT 'eventbrite', 'eventbrite', 'sale', (SELECT cur FROM ev), sum(coalesce(l.eb_sold, 0))::int,
         NULL, NULL, 0, NULL, 'not_reported', NULL::timestamptz
    FROM public.exos_eventbrite_ticket_links l
   WHERE l.event_id = p_event_id AND l.active
     AND NOT EXISTS (SELECT 1 FROM entries g WHERE g.external_ref LIKE 'eb:%')
  HAVING sum(coalesce(l.eb_sold, 0)) > 0
  UNION ALL
  SELECT 'luma', 'luma', 'sale', (SELECT cur FROM ev), sum(coalesce(l.luma_sold, 0))::int,
         NULL, NULL, 0, NULL, 'not_reported', NULL::timestamptz
    FROM public.exos_luma_ticket_links l
   WHERE l.event_id = p_event_id AND l.active
     AND NOT EXISTS (SELECT 1 FROM entries g WHERE g.external_ref LIKE 'lu:%')
  HAVING sum(coalesce(l.luma_sold, 0)) > 0
  UNION ALL
  -- Guest lists (comps) and CSV door imports (other-platform attendees, no price).
  SELECT CASE WHEN g.external_code IS NULL AND g.source IS NULL THEN 'guest_list'
              ELSE coalesce('import:' || nullif(left(btrim(regexp_replace(lower(coalesce(g.source, '')), '[^a-z0-9_-]+', '-', 'g'), '-'), 30), ''),
                            'import') END,
         CASE WHEN g.external_code IS NULL AND g.source IS NULL THEN 'comp' ELSE 'imported' END,
         CASE WHEN g.external_code IS NULL AND g.source IS NULL THEN 'comp' ELSE 'attendee' END,
         (SELECT cur FROM ev), g.heads, NULL, NULL, NULL, NULL, 'none', g.created_at
    FROM entries g
   WHERE g.external_ref IS NULL OR g.external_ref !~ '^(eb|lu|px|he):'
$$;
REVOKE ALL ON FUNCTION public._exos_channel_lines(uuid) FROM PUBLIC, anon, authenticated;

-- Per channel for a date range: [p_from, p_to). Lines with no date (platform
-- counts) are only in an open-ended range (p_from IS NULL). A money column is
-- NULL when any line in it wasn't reported.
CREATE OR REPLACE FUNCTION public._exos_channel_sales(p_event_id uuid, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (channel text, label text, channel_group text, kind text, currency text, tickets integer,
               gross_cents bigint, fee_cents bigint, exos_fee_cents bigint, net_cents bigint,
               fees text, dated boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT l.channel, public._exos_channel_label(l.channel), l.channel_group, l.kind, l.currency,
         sum(l.tickets)::int,
         CASE WHEN count(*) FILTER (WHERE l.gross_cents IS NULL) = 0 THEN sum(l.gross_cents)::bigint END,
         CASE WHEN count(*) FILTER (WHERE l.fee_cents IS NULL) = 0 THEN sum(l.fee_cents)::bigint END,
         CASE WHEN count(*) FILTER (WHERE l.exos_fee_cents IS NULL) = 0 THEN sum(l.exos_fee_cents)::bigint END,
         CASE WHEN count(*) FILTER (WHERE l.net_cents IS NULL) = 0 THEN sum(l.net_cents)::bigint END,
         CASE WHEN bool_or(l.fees = 'not_reported') THEN 'not_reported'
              WHEN bool_or(l.fees = 'reported') THEN 'reported' ELSE 'none' END,
         bool_and(l.at IS NOT NULL)
    FROM public._exos_channel_lines(p_event_id) l
   WHERE (l.at IS NULL AND p_from IS NULL)
      OR (l.at IS NOT NULL AND (p_from IS NULL OR l.at >= p_from) AND (p_to IS NULL OR l.at < p_to))
   GROUP BY l.channel, l.channel_group, l.kind, l.currency
$$;
REVOKE ALL ON FUNCTION public._exos_channel_sales(uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- Sales totals per currency over events, for a range: the known money added
-- up, and the tickets whose gross / net wasn't reported.
CREATE OR REPLACE FUNCTION public._exos_channel_totals(p_event_ids uuid[], p_from timestamptz, p_to timestamptz)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'currency', t.currency, 'tickets', t.tickets, 'gross_cents', t.gross, 'fee_cents', t.fee,
           'exos_fee_cents', t.exos, 'net_cents', t.net,
           'gross_not_reported', t.gross_nr, 'net_not_reported', t.net_nr) ORDER BY t.currency), '[]'::jsonb)
    FROM (
      SELECT c.currency, sum(c.tickets)::int AS tickets,
             coalesce(sum(c.gross_cents), 0)::bigint AS gross, coalesce(sum(c.fee_cents), 0)::bigint AS fee,
             coalesce(sum(c.exos_fee_cents), 0)::bigint AS exos, coalesce(sum(c.net_cents), 0)::bigint AS net,
             coalesce(sum(c.tickets) FILTER (WHERE c.gross_cents IS NULL), 0)::int AS gross_nr,
             coalesce(sum(c.tickets) FILTER (WHERE c.net_cents IS NULL), 0)::int AS net_nr
        FROM unnest(coalesce(p_event_ids, '{}'::uuid[])) AS e(id)
        CROSS JOIN LATERAL public._exos_channel_sales(e.id, p_from, p_to) c
       WHERE c.kind = 'sale'
       GROUP BY c.currency
    ) t
$$;
REVOKE ALL ON FUNCTION public._exos_channel_totals(uuid[], timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- One event: every channel with the range ("week") and to-date figures.
-- week / to_date are [tickets, gross_cents, fee_cents, exos_fee_cents, net_cents]
-- (NULL = not reported); week is NULL for a channel with no dates.
CREATE OR REPLACE FUNCTION public._exos_channel_event_json(p_event_id uuid, p_from timestamptz, p_to timestamptz)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'timezone', e.timezone,
    'currency', lower(coalesce(nullif(e.currency, ''), 'usd')), 'capacity', e.total_tickets,
    'channels', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'channel', public._exos_channel_out_key(a.channel), 'label', a.label,
               'detail', public._exos_channel_detail(a.channel), 'group', a.channel_group, 'kind', a.kind,
               'currency', a.currency, 'fees', a.fees, 'dated', a.dated,
               'week', CASE WHEN a.dated THEN
                         CASE WHEN w.channel IS NULL THEN jsonb_build_array(0, 0, 0, 0, 0)
                              ELSE jsonb_build_array(w.tickets, w.gross_cents, w.fee_cents, w.exos_fee_cents, w.net_cents) END
                       END,
               'to_date', jsonb_build_array(a.tickets, a.gross_cents, a.fee_cents, a.exos_fee_cents, a.net_cents))
             ORDER BY (a.kind = 'sale') DESC, a.tickets DESC, a.channel)
        FROM public._exos_channel_sales(e.id, NULL, NULL) a
        LEFT JOIN public._exos_channel_sales(e.id, p_from, p_to) w
          ON w.channel = a.channel AND w.kind = a.kind AND w.currency = a.currency AND w.channel_group = a.channel_group
    ), '[]'::jsonb),
    'totals', jsonb_build_object('week', public._exos_channel_totals(ARRAY[e.id], p_from, p_to),
                                 'to_date', public._exos_channel_totals(ARRAY[e.id], NULL, NULL)))
    FROM public.exos_events e
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_channel_event_json(uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- The weekly report document for an org: events that started in the 7 days
-- before p_now or start in the 60 days after it (not drafts or cancelled),
-- soonest first, kept under the mail payload limit; plus totals.
CREATE OR REPLACE FUNCTION public._exos_channel_report_payload(p_org_id uuid, p_from timestamptz, p_to timestamptz, p_now timestamptz)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ids   uuid[];
  v_n     int;
  v_keep  int := 10;
  v_out   jsonb;
BEGIN
  SELECT array_agg(e.id ORDER BY e.starts_at, e.id) INTO v_ids
    FROM public.exos_events e
   WHERE e.org_id = p_org_id
     AND coalesce(e.status, '') NOT IN ('draft', 'cancelled')
     AND e.starts_at >= p_now - interval '7 days' AND e.starts_at < p_now + interval '60 days';
  v_n := coalesce(array_length(v_ids, 1), 0);
  LOOP
    v_out := jsonb_build_object(
      'org', (SELECT jsonb_build_object('id', o.id, 'name', o.name) FROM public.exos_orgs o WHERE o.id = p_org_id),
      'from', p_from, 'to', p_to,
      'iso_week', to_char(p_from AT TIME ZONE 'UTC', 'IYYY-"W"IW'),
      'events', coalesce((SELECT jsonb_agg(public._exos_channel_event_json(x.id, p_from, p_to) ORDER BY x.n)
                            FROM unnest(v_ids[1:v_keep]) WITH ORDINALITY AS x(id, n)), '[]'::jsonb),
      'more_events', greatest(v_n - v_keep, 0),
      'totals', jsonb_build_object('week', public._exos_channel_totals(v_ids, p_from, p_to),
                                   'to_date', public._exos_channel_totals(v_ids, NULL, NULL)));
    EXIT WHEN octet_length(v_out::text) <= 18000 OR v_keep <= 1;
    v_keep := greatest(v_keep - 2, 1);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_channel_report_payload(uuid, timestamptz, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- The ISO week before the one p_at falls in (Monday 00:00 UTC), or the week
-- that starts on / contains p_day.
CREATE OR REPLACE FUNCTION public._exos_report_week(p_day date, p_at timestamptz)
RETURNS timestamptz
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p_day IS NOT NULL
              THEN date_trunc('week', p_day::timestamp) AT TIME ZONE 'UTC'
              ELSE (date_trunc('week', coalesce(p_at, now()) AT TIME ZONE 'UTC') - interval '7 days') AT TIME ZONE 'UTC'
         END
$$;
REVOKE ALL ON FUNCTION public._exos_report_week(date, timestamptz) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Reads for the organizer (owner / manager / finance)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_channel_sales(p_event_id uuid, p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS TABLE (channel text, label text, channel_group text, kind text, currency text, tickets integer,
               gross_cents bigint, fee_cents bigint, exos_fee_cents bigint, net_cents bigint,
               fees text, dated boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_channel_sales: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT public._exos_channel_out_key(c.channel), c.label, c.channel_group, c.kind, c.currency, c.tickets,
                      c.gross_cents, c.fee_cents, c.exos_fee_cents, c.net_cents, c.fees, c.dated
                 FROM public._exos_channel_sales(p_event_id, p_from, p_to) c
                ORDER BY (c.kind = 'sale') DESC, c.tickets DESC, c.channel;
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_sales(uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_channel_sales(uuid, timestamptz, timestamptz) TO authenticated, service_role;

-- The event dashboard's Channels card: the same document the weekly mail
-- carries for this event. Week = the last full ISO week unless p_week_start.
CREATE OR REPLACE FUNCTION public.exos_event_channel_report(p_event_id uuid, p_week_start date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_from timestamptz := public._exos_report_week(p_week_start, now());
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_event_channel_report: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_channel_event_json(p_event_id, v_from, v_from + interval '7 days')
      || jsonb_build_object('from', v_from, 'to', v_from + interval '7 days',
                            'iso_week', to_char(v_from AT TIME ZONE 'UTC', 'IYYY-"W"IW'));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_channel_report(uuid, date) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_event_channel_report(uuid, date) TO authenticated, service_role;

-- The org's weekly report as the mail would carry it.
CREATE OR REPLACE FUNCTION public.exos_org_channel_report(p_org_id uuid, p_week_start date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_from timestamptz := public._exos_report_week(p_week_start, now());
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_org_channel_report: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_channel_report_payload(p_org_id, v_from, v_from + interval '7 days', now());
END $$;
REVOKE ALL ON FUNCTION public.exos_org_channel_report(uuid, date) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_org_channel_report(uuid, date) TO authenticated, service_role;

-- Settings: on / off, the text number (masked), whether texting can work.
CREATE OR REPLACE FUNCTION public.exos_channel_report_settings(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_channel_report_settings%ROWTYPE;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_channel_report_settings: not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO s FROM public.exos_channel_report_settings WHERE org_id = p_org_id;
  RETURN jsonb_build_object(
    'enabled', coalesce(s.enabled, true),
    'sms_phone_hint', CASE WHEN s.sms_phone IS NOT NULL THEN '…' || right(s.sms_phone, 4) END,
    'sms_provider', (SELECT i.provider FROM public.exos_org_integrations i
                      WHERE i.org_id = p_org_id AND i.provider IN ('twilio', 'telnyx') AND i.status = 'connected'
                      ORDER BY (i.provider = 'twilio') DESC LIMIT 1),
    'can_edit', public.exos_has_org_role(p_org_id, ARRAY['owner']),
    'last_week', (SELECT r.iso_week FROM public.exos_channel_reports r WHERE r.org_id = p_org_id ORDER BY r.week_start DESC LIMIT 1));
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_report_settings(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_channel_report_settings(uuid) TO authenticated, service_role;

-- Owner: turn the report on / off, and the number the weekly text goes to:
-- NULL keeps the number as it is, '' clears it (no text), anything else is
-- the new number.
CREATE OR REPLACE FUNCTION public.exos_set_channel_report(p_org_id uuid, p_enabled boolean, p_sms_phone text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_phone text; v_keep boolean := p_sms_phone IS NULL;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'exos_set_channel_report: owner only' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(coalesce(p_sms_phone, '')), '') IS NOT NULL THEN
    v_phone := public.exos_sms_normalize_phone(p_sms_phone);
    IF v_phone IS NULL THEN
      RAISE EXCEPTION 'exos_set_channel_report: enter a mobile number, e.g. +1 212 555 0100' USING ERRCODE = '22023';
    END IF;
    -- STOP is durable: only the number itself can undo it, by texting START.
    IF public._exos_sms_stopped(p_org_id, v_phone) THEN
      RAISE EXCEPTION 'exos_set_channel_report: that number replied STOP to your texts. To get the weekly text again, text START from it to your org''s number, then save it here.'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  INSERT INTO public.exos_channel_report_settings AS s (org_id, enabled, sms_phone, updated_by, updated_at)
  VALUES (p_org_id, coalesce(p_enabled, true), v_phone, auth.uid(), now())
  ON CONFLICT (org_id) DO UPDATE
     SET enabled = EXCLUDED.enabled,
         sms_phone = CASE WHEN v_keep THEN s.sms_phone ELSE EXCLUDED.sms_phone END,
         updated_by = EXCLUDED.updated_by, updated_at = now();
  RETURN public.exos_channel_report_settings(p_org_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_channel_report(uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_set_channel_report(uuid, boolean, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Mail template + SMS audience
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['org-channel-report'];
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
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN
    RETURN;  -- already allowed; leave the live list alone
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION
    SELECT unnest(ARRAY[
      'transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled',
      'event-reminder','order-failed','checkout-abandoned','marketplace-attention',
      'event-published','inventory-low','inventory-sold-out','payout-sent',
      'payout-pending','fee-free-ending','org-welcome','org-first-event',
      'org-connect-stripe','org-sales-digest','org-weekly-summary',
      'refund-issued','post-event','dispute-opened','dispute-won','dispute-lost'] || v_new)
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- The weekly text is a "campaign" of one to the org's own number.
DO $$
BEGIN
  IF position('staff_report' in coalesce((SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
                                           WHERE c.conrelid = 'public.exos_sms_campaigns'::regclass
                                             AND c.conname = 'exos_sms_campaigns_audience_check'), '')) = 0 THEN
    ALTER TABLE public.exos_sms_campaigns DROP CONSTRAINT IF EXISTS exos_sms_campaigns_audience_check;
    ALTER TABLE public.exos_sms_campaigns ADD CONSTRAINT exos_sms_campaigns_audience_check
      CHECK (audience IN ('org', 'event_buyers', 'staff_report'));
  END IF;
END $$;

-- STOP is recorded for the number (exos_sms_stops, any number, subscriber or
-- not) and turns the weekly text off; START removes it. Otherwise the same
-- body as mig 20261016120000.
CREATE OR REPLACE FUNCTION public.exos_sms_inbound(p_org_id uuid, p_from text, p_text text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_phone text := public.exos_sms_normalize_phone(p_from);
  v_word  text := upper(btrim(regexp_replace(coalesce(p_text, ''), '[^A-Za-z ]', '', 'g')));
  v_sub   int;
  v_stop  int;
BEGIN
  IF v_phone IS NULL THEN RETURN 'ignored'; END IF;
  IF v_word IN ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'STOP ALL', 'OPTOUT', 'REVOKE') THEN
    UPDATE public.exos_sms_subscribers SET opted_out_at = coalesce(opted_out_at, now()), updated_at = now()
     WHERE org_id = p_org_id AND phone = v_phone;
    UPDATE public.exos_sms_outbox SET status = 'skipped', error = 'opted out'
     WHERE org_id = p_org_id AND phone = v_phone AND status = 'queued';
    IF EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org_id) THEN
      INSERT INTO public.exos_sms_stops (org_id, phone) VALUES (p_org_id, v_phone)
      ON CONFLICT (org_id, phone) DO UPDATE SET stopped_at = now();
    END IF;
    UPDATE public.exos_channel_report_settings SET sms_phone = NULL, updated_at = now()
     WHERE org_id = p_org_id AND sms_phone = v_phone;
    RETURN 'stopped';
  ELSIF v_word IN ('START', 'UNSTOP', 'YES') THEN
    UPDATE public.exos_sms_subscribers SET opted_out_at = NULL, updated_at = now()
     WHERE org_id = p_org_id AND phone = v_phone AND opted_out_at IS NOT NULL;
    GET DIAGNOSTICS v_sub = ROW_COUNT;
    DELETE FROM public.exos_sms_stops WHERE org_id = p_org_id AND phone = v_phone;
    GET DIAGNOSTICS v_stop = ROW_COUNT;
    RETURN CASE WHEN v_sub + v_stop > 0 THEN 'started' ELSE 'ignored' END;
  ELSIF v_word = 'HELP' OR v_word = 'INFO' THEN
    RETURN 'help';
  END IF;
  RETURN 'ignored';
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_inbound(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_inbound(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. The weekly run (service role; the cron calls it Monday after midnight UTC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_send_channel_reports(p_now timestamptz DEFAULT NULL, p_limit integer DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_now     timestamptz := coalesce(p_now, now());
  v_from    timestamptz := public._exos_report_week(NULL, coalesce(p_now, now()));
  v_to      timestamptz;
  v_week    text;
  v_start   timestamptz := clock_timestamp();
  v_orgs    int := 0;
  v_mails   int := 0;
  v_texts   int := 0;
  v_failed  int := 0;
  v_m       int;
  v_t       int;
  v_payload jsonb;
  v_tz      text;
  v_at      timestamptz;
  v_local   timestamp;
  v_body    text;
  v_camp    uuid;
  v_prov    text;
  r         record;
  u         record;
BEGIN
  IF session_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_channel_reports: service role only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.cron_should_fire('exos_send_channel_reports') THEN
    RETURN jsonb_build_object('skipped', 'cron gate');
  END IF;
  v_to   := v_from + interval '7 days';
  v_week := to_char(v_from AT TIME ZONE 'UTC', 'IYYY-"W"IW');

  FOR r IN
    SELECT o.id, o.name, s.sms_phone
      FROM public.exos_orgs o
      LEFT JOIN public.exos_channel_report_settings s ON s.org_id = o.id
     WHERE coalesce(s.enabled, true)
       AND NOT EXISTS (SELECT 1 FROM public.exos_channel_reports x WHERE x.org_id = o.id AND x.iso_week = v_week)
       AND EXISTS (SELECT 1 FROM public.exos_events e
                    WHERE e.org_id = o.id AND coalesce(e.status, '') NOT IN ('draft', 'cancelled')
                      AND e.starts_at >= v_now - interval '7 days' AND e.starts_at < v_now + interval '60 days')
     ORDER BY o.id
     LIMIT greatest(coalesce(p_limit, 200), 1)
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '20 seconds';
    BEGIN
      v_payload := public._exos_channel_report_payload(r.id, v_from, v_to, v_now);
      -- The once-per-week gate: a concurrent or repeated run inserts nothing.
      INSERT INTO public.exos_channel_reports (org_id, iso_week, week_start, payload)
      VALUES (r.id, v_week, v_from, v_payload)
      ON CONFLICT (org_id, iso_week) DO NOTHING;
      CONTINUE WHEN NOT FOUND;
      v_m := 0;
      v_t := 0;
      FOR u IN SELECT * FROM public.exos_org_mail_recipients(r.id, ARRAY['owner', 'manager']) LOOP
        IF public.exos_mail_enqueue('org-channel-report', u.email, v_payload,
             'org-channel-report:' || r.id || ':' || v_week || ':' || u.user_id, u.user_id, true, NULL) IS NOT NULL THEN
          v_m := v_m + 1;
          -- This replaces the same week's org-weekly-summary for this person.
          INSERT INTO public.exos_mail_dedupe (dedupe_key, template)
          VALUES ('org-weekly-summary:' || r.id || ':' || to_char(v_from AT TIME ZONE 'UTC', 'YYYYMMDD') || ':' || u.user_id,
                  'org-weekly-summary')
          ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;

      -- The text: a set number, a connected provider, no STOP on that number.
      IF r.sms_phone IS NOT NULL
         AND NOT public._exos_sms_stopped(r.id, r.sms_phone) THEN
        SELECT i.provider INTO v_prov FROM public.exos_org_integrations i
         WHERE i.org_id = r.id AND i.provider IN ('twilio', 'telnyx') AND i.status = 'connected'
         ORDER BY (i.provider = 'twilio') DESC LIMIT 1;
        IF v_prov IS NOT NULL THEN
          v_body := left(r.name, 40) || ': last week '
            || coalesce((SELECT sum((t ->> 'tickets')::int) FROM jsonb_array_elements(v_payload -> 'totals' -> 'week') t), 0)
            || ' tickets'
            || coalesce(' (' || (SELECT string_agg(c.label || ' ' || c.n, ', ' ORDER BY c.n DESC, c.label)
                                  FROM (SELECT ch ->> 'label' AS label, sum((ch -> 'week' ->> 0)::int) AS n
                                          FROM jsonb_array_elements(v_payload -> 'events') ev,
                                               jsonb_array_elements(ev -> 'channels') ch
                                         WHERE ch ->> 'kind' = 'sale' AND jsonb_typeof(ch -> 'week') = 'array'
                                         GROUP BY 1 HAVING sum((ch -> 'week' ->> 0)::int) > 0
                                         ORDER BY 2 DESC, 1 LIMIT 3) c) || ')', '')
            || ', ' || coalesce((SELECT sum((t ->> 'tickets')::int) FROM jsonb_array_elements(v_payload -> 'totals' -> 'to_date') t), 0)
            || ' to date. Report: {{app_url}}/orgs/' || r.id || '/channels Reply STOP to opt out.';
          v_tz := 'America/New_York';
          v_at := v_now;
          v_local := v_at AT TIME ZONE v_tz;
          IF v_local::time < time '09:00' THEN
            v_at := (date_trunc('day', v_local) + interval '9 hours') AT TIME ZONE v_tz;
          ELSIF v_local::time >= time '20:00' THEN
            v_at := (date_trunc('day', v_local) + interval '1 day 9 hours') AT TIME ZONE v_tz;
          END IF;
          INSERT INTO public.exos_sms_campaigns (org_id, audience, body, provider, send_after, queued_count, status)
          VALUES (r.id, 'staff_report', left(v_body, 480), v_prov, v_at, 1, 'queued')
          RETURNING id INTO v_camp;
          INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after)
          VALUES (v_camp, r.id, r.sms_phone, left(v_body, 480), v_at);
          v_t := 1;
        END IF;
      END IF;

      UPDATE public.exos_channel_reports SET mails = v_m, texts = v_t WHERE org_id = r.id AND iso_week = v_week;
      v_orgs := v_orgs + 1;
      v_mails := v_mails + v_m;
      v_texts := v_texts + v_t;
    EXCEPTION WHEN others THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'exos_send_channel_reports: org %: % (%)', r.id, SQLERRM, SQLSTATE;
    END;
  END LOOP;

  RETURN jsonb_build_object('iso_week', v_week, 'from', v_from, 'to', v_to,
                            'orgs', v_orgs, 'mails', v_mails, 'texts', v_texts, 'failed', v_failed);
END $$;
REVOKE ALL ON FUNCTION public.exos_send_channel_reports(timestamptz, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_send_channel_reports(timestamptz, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Cron: Mondays 00:07 UTC (before the hourly follow-ups at :23, so this
--    report goes out instead of that week's summary). Created INACTIVE; an
--    existing job is never touched. The operator turns it on (docs/email.md).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_job bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos_send_channel_reports') THEN
    RETURN;
  END IF;
  v_job := cron.schedule('exos_send_channel_reports', '7 0 * * 1',
    $cron$SELECT public.exos_send_channel_reports();$cron$);
  BEGIN
    PERFORM cron.alter_job(job_id := v_job, active := false);
  EXCEPTION WHEN undefined_function THEN
    -- pg_cron without alter_job: don't leave it running.
    PERFORM cron.unschedule(v_job);
  END;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos_send_channel_reports');
-- drop the functions in sections 2-4 and 6; re-apply exos_sms_inbound from
-- 20261016120000; drop exos_channel_reports, exos_channel_report_settings and
-- exos_sms_stops.
-- The two allowlist values can stay.
