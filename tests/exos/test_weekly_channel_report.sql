-- ============================================================================
-- Sales by channel + the weekly organizer report (mig 20261029120000).
--   C1 every sale is credited to a channel: Exos checkouts by promo link /
--      UTM / promoter / direct, free claims, box office, marketplaces,
--      Eventbrite / Luma; money per channel (gross, channel fee, Exos fee,
--      net) only where reported; refunds, voids and cancelled orders out
--   C2 a date range (the report week) keeps dated lines in it; undated
--      platform counts are to-date only
--   C3 comps (comp batches, staff issues, referral rewards, guest lists) and
--      imported door lists are listed but never sales or in the totals
--   C4 roles: owner / manager / finance read; scanner / outsider / anon
--      can't; internal helpers have no client grant; settings owner-only
--   C5 weekly run: one mail per owner / manager (opt-out respected), the
--      org's switch respected, orgs with no event in the window skipped, no
--      buyer data, the week's org-weekly-summary key claimed; the text only
--      with a number + a connected provider
--   C6 idempotent per org and ISO week; STOP turns the text off
--   C7 the dashboard reads (event + org) match the mailed document
--   C8 buyer-written utm_source ("evil.com", a phone number, markup) shows as
--      Other in the text and the mail; keys in output are [a-z0-9_-] only
-- Self-contained ids c3…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

UPDATE public.exos_mail SET status = 'sent' WHERE status IN ('pending', 'sending');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('c3000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated;
-- The report week: the last full ISO week (Monday 00:00 UTC).
SELECT set_config('c3.w', public._exos_report_week(NULL, now())::text, true);
CREATE FUNCTION pg_temp.w() RETURNS timestamptz LANGUAGE sql STABLE AS $$ SELECT current_setting('c3.w')::timestamptz $$;
GRANT EXECUTE ON FUNCTION pg_temp.w() TO anon, authenticated;
-- One channel row of the to-date / week read as a json object.
CREATE FUNCTION pg_temp.ch(p_from timestamptz, p_to timestamptz, p_channel text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT to_jsonb(c) FROM public._exos_channel_sales(pg_temp.u('0000000000e1'), p_from, p_to) c WHERE c.channel = p_channel
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('c3000000-0000-0000-0000-0000000000a1', 'own-c3@x.com', now()),
  ('c3000000-0000-0000-0000-0000000000a2', 'mgr-c3@x.com', now()),
  ('c3000000-0000-0000-0000-0000000000a3', 'fin-c3@x.com', now()),
  ('c3000000-0000-0000-0000-0000000000a4', 'scan-c3@x.com', now()),
  ('c3000000-0000-0000-0000-0000000000a5', 'out-c3@x.com', now()),
  ('c3000000-0000-0000-0000-0000000000a6', 'own2-c3@x.com', now()),
  ('c3000000-0000-0000-0000-0000000000b1', 'fan1-c3@x.com', now()),
  ('c3000000-0000-0000-0000-0000000000b2', 'fan2-c3@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('c3000000-0000-0000-0000-000000000001', 'C3 <Org>', 'c3-org', 'c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-000000000002', 'C3 Far', 'c3-far', 'c3000000-0000-0000-0000-0000000000a6'),
  ('c3000000-0000-0000-0000-000000000003', 'C3 Off', 'c3-off', 'c3000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a1', 'owner'),
  ('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a2', 'manager'),
  ('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a3', 'finance'),
  ('c3000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a4', 'scanner'),
  ('c3000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000a6', 'owner'),
  ('c3000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-0000000000a6', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, currency, total_tickets, created_by) VALUES
  ('c3000000-0000-0000-0000-0000000000e1', 'c3000000-0000-0000-0000-000000000001', 'C3 <Show>', 'c3-show', 'published', now() + interval '10 days', 'America/New_York', 'usd', 200, 'c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-0000000000e2', 'c3000000-0000-0000-0000-000000000001', 'C3 Last', 'c3-last', 'published', now() - interval '3 days', 'America/New_York', 'usd', 50, 'c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-0000000000e3', 'c3000000-0000-0000-0000-000000000001', 'C3 Draft', 'c3-draft', 'draft', now() + interval '5 days', 'UTC', 'usd', 50, 'c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-0000000000e4', 'c3000000-0000-0000-0000-000000000002', 'C3 Far Show', 'c3-far-show', 'published', now() + interval '90 days', 'UTC', 'usd', 50, 'c3000000-0000-0000-0000-0000000000a6'),
  ('c3000000-0000-0000-0000-0000000000e5', 'c3000000-0000-0000-0000-000000000003', 'C3 Off Show', 'c3-off-show', 'published', now() + interval '3 days', 'UTC', 'usd', 50, 'c3000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold) VALUES
  ('c3000000-0000-0000-0000-0000000000d1', 'c3000000-0000-0000-0000-0000000000e1', 'GA', 25, 200, 0);

-- A promo link (email) for S2.
INSERT INTO public.exos_vouchers (id, event_id, code, max_uses, link_label, link_channel) VALUES
  ('c3000000-0000-0000-0000-0000000000f1', 'c3000000-0000-0000-0000-0000000000e1', 'C3NEWS', 10, 'Newsletter', 'email');

-- Exos checkouts.
--   S1 in the week, ?utm_source=ig, fee split recorded
--   S2 before the week, through the promo link, no fee split (older row)
--   S3 in the week, half refunded (one ticket voided), no source, fee-free
--   S4 fully refunded: out
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency, status,
                                           fulfilled_at, attribution, voucher_id, application_fee_cents, exos_fee_cents, card_fee_est_cents) VALUES
  ('c3-s1', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 2, 5000, 'usd', 'fulfilled',
     pg_temp.w() + interval '2 days', '{"utm_source":"ig","utm_medium":"social"}', NULL, 250, 150, 100),
  ('c3-s2', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 1, 3000, 'usd', 'fulfilled',
     pg_temp.w() - interval '10 days', '{"utm_source":"email","utm_medium":"promo_link"}', pg_temp.u('0000000000f1'), NULL, NULL, NULL),
  ('c3-s3', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 2, 6000, 'usd', 'partially_refunded',
     pg_temp.w() + interval '3 days', NULL, NULL, 300, 0, 300),
  ('c3-s4', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 1, 2500, 'usd', 'refunded',
     pg_temp.w() + interval '3 days', '{"utm_source":"tiktok"}', NULL, 125, 75, 50);
INSERT INTO public.exos_order_refunds (session_id, org_id, amount_cents, status) VALUES
  ('c3-s3', pg_temp.u('000000000001'), 3000, 'succeeded'),
  ('c3-s4', pg_temp.u('000000000001'), 2500, 'succeeded');

INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, owner_id, buyer_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source, promoter_id, created_at) VALUES
  -- paid through checkouts
  (pg_temp.u('000000000101'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 25, 'c3-s1', 'stripe', NULL, pg_temp.w() + interval '2 days'),
  (pg_temp.u('000000000102'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 25, 'c3-s1', 'stripe', NULL, pg_temp.w() + interval '2 days'),
  (pg_temp.u('000000000103'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b2'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 'active', 'x', 30, 'c3-s2', 'stripe', NULL, pg_temp.w() - interval '10 days'),
  (pg_temp.u('000000000104'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 30, 'c3-s3', 'stripe', NULL, pg_temp.w() + interval '3 days'),
  (pg_temp.u('000000000105'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'voided', 'x', 30, 'c3-s3', 'stripe', NULL, pg_temp.w() + interval '3 days'),
  (pg_temp.u('000000000106'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b2'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 'voided', 'x', 25, 'c3-s4', 'stripe', NULL, pg_temp.w() + interval '3 days'),
  -- free claims: ?utm_source=tiktok in the week; a promoter's link before it
  (pg_temp.u('000000000111'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 0, 'free_1', 'TikTok', NULL, pg_temp.w() + interval '1 day'),
  (pg_temp.u('000000000112'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b2'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 'active', 'x', 0, 'free_1', 'tiktok', NULL, pg_temp.w() + interval '1 day'),
  (pg_temp.u('000000000113'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b2'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 'active', 'x', 0, 'free_2', 'vibepass', 'dj-kay', pg_temp.w() - interval '5 days'),
  -- comps, a staff issue, a referral reward
  (pg_temp.u('000000000121'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 0, 'comp_1', 'comp', NULL, pg_temp.w() + interval '1 day'),
  (pg_temp.u('000000000122'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b2'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 'active', 'x', 0, 'comp_1', 'comp', NULL, pg_temp.w() + interval '1 day'),
  (pg_temp.u('000000000123'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b2'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 'active', 'x', 0, 'boxoffice', 'boxoffice', NULL, pg_temp.w() + interval '1 day'),
  (pg_temp.u('000000000124'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b2'), pg_temp.u('0000000000b2'), 'fan2-c3@x.com', 'active', 'x', 0, 'referral_1', 'referral_reward', NULL, pg_temp.w() + interval '1 day'),
  -- box office sale (staff mint with a price)
  (pg_temp.u('000000000131'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 40, 'door_1', 'vibepass', NULL, pg_temp.w() + interval '2 days'),
  -- minted for the StubHub order below: counted through the order
  (pg_temp.u('000000000141'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000a1'), pg_temp.u('0000000000a1'), 'own-c3@x.com', 'active', 'x', 45, 'sh_1', 'stubhub', NULL, pg_temp.w() + interval '4 days'),
  (pg_temp.u('000000000142'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000a1'), pg_temp.u('0000000000a1'), 'own-c3@x.com', 'active', 'x', 45, 'sh_1', 'stubhub', NULL, pg_temp.w() + interval '4 days'),
  -- the past event: one direct free claim in the week
  (pg_temp.u('000000000201'), pg_temp.u('0000000000e2'), pg_temp.u('000000000001'), NULL, pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'used', 'x', 0, 'free_3', 'vibepass', NULL, pg_temp.w() + interval '1 day'),
  -- ... and three claims whose ?utm_source anyone could have written (C8)
  (pg_temp.u('000000000202'), pg_temp.u('0000000000e2'), pg_temp.u('000000000001'), NULL, pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 0, 'free_4', 'evil.com', NULL, pg_temp.w() + interval '1 day'),
  (pg_temp.u('000000000203'), pg_temp.u('0000000000e2'), pg_temp.u('000000000001'), NULL, pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 0, 'free_5', '+1 212 555 0100', NULL, pg_temp.w() + interval '1 day'),
  (pg_temp.u('000000000204'), pg_temp.u('0000000000e2'), pg_temp.u('000000000001'), NULL, pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'fan1-c3@x.com', 'active', 'x', 0, 'free_6', '<b>x</b>', NULL, pg_temp.w() + interval '1 day');

-- Marketplace orders: StubHub (fee reported), SeatGeek (only the payout), Vivid cancelled.
INSERT INTO public.exos_marketplace_orders (channel, external_order_id, event_id, org_id, quantity, proceeds, currency, sale_status, status, sold_at, list_unit_price, ticket_ids, buyer_email) VALUES
  ('stubhub', 'c3-sh-1', pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 2, 90, 'usd', 'confirmed', 'fulfilled', pg_temp.w() + interval '4 days', 50,
     ARRAY[pg_temp.u('000000000141'), pg_temp.u('000000000142')], 'buyer-sh-c3@x.com'),
  ('seatgeek', 'c3-sg-1', pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 1, 40, 'usd', 'confirmed', 'received', pg_temp.w() - interval '3 days', NULL, '{}', NULL),
  ('vivid', 'c3-vv-1', pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 3, 120, 'usd', 'cancelled', 'cancelled', pg_temp.w() + interval '2 days', 45, '{}', NULL);

-- Door entries: Eventbrite attendees (one refunded = voided), a manual guest
-- list entry with a plus-one, a Posh CSV import; Luma counts from its links.
INSERT INTO public.exos_guest_lists (id, event_id, org_id, name) VALUES
  (pg_temp.u('0000000000c1'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'Eventbrite'),
  (pg_temp.u('0000000000c2'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'Friends'),
  (pg_temp.u('0000000000c3'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'Posh import');
INSERT INTO public.exos_guest_list_entries (list_id, event_id, org_id, guest_name, plus_ones, external_ref, external_code, source, voided_at, created_at) VALUES
  (pg_temp.u('0000000000c1'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'EB One', 0, 'eb:1001', 'EB1001', 'Eventbrite', NULL, pg_temp.w() + interval '2 days'),
  (pg_temp.u('0000000000c1'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'EB Two', 0, 'eb:1002', 'EB1002', 'Eventbrite', NULL, pg_temp.w() + interval '2 days'),
  (pg_temp.u('0000000000c1'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'EB Gone', 0, 'eb:1003', 'EB1003', 'Eventbrite', now(), pg_temp.w() + interval '2 days'),
  (pg_temp.u('0000000000c2'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'Pal', 1, NULL, NULL, NULL, NULL, pg_temp.w() + interval '2 days'),
  (pg_temp.u('0000000000c3'), pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'Posh Guest', 0, NULL, 'POSH1', 'Posh', NULL, pg_temp.w() + interval '2 days');
INSERT INTO public.exos_luma_ticket_links (event_id, luma_event_id, luma_ticket_type_id, tier_id, active, luma_sold) VALUES
  (pg_temp.u('0000000000e1'), 'evt-c3luma', 'tt-c3', pg_temp.u('0000000000d1'), true, 5);

-- C1 / C3 -------------------------------------------------------------------
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.ch(NULL, NULL, 'instagram');
  ASSERT (j->>'tickets')::int = 2 AND (j->>'gross_cents')::int = 5000 AND (j->>'fee_cents')::int = 100
     AND (j->>'exos_fee_cents')::int = 150 AND (j->>'net_cents')::int = 4750 AND j->>'fees' = 'reported'
     AND j->>'channel_group' = 'exos' AND j->>'label' = 'Instagram', 'C1 utm ig -> instagram: ' || coalesce(j::text, 'missing');
  j := pg_temp.ch(NULL, NULL, 'email');
  ASSERT (j->>'tickets')::int = 1 AND (j->>'gross_cents')::int = 3000 AND j->'fee_cents' = 'null'::jsonb
     AND j->'net_cents' = 'null'::jsonb AND j->>'fees' = 'not_reported', 'C1 promo link -> email, fees not reported: ' || coalesce(j::text, 'missing');
  j := pg_temp.ch(NULL, NULL, 'direct');
  ASSERT (j->>'tickets')::int = 1 AND (j->>'gross_cents')::int = 3000 AND (j->>'fee_cents')::int = 300
     AND (j->>'exos_fee_cents')::int = 0 AND (j->>'net_cents')::int = 2700, 'C1 refund + void: ' || coalesce(j::text, 'missing');
  j := pg_temp.ch(NULL, NULL, 'tiktok');
  ASSERT (j->>'tickets')::int = 2 AND (j->>'gross_cents')::int = 0 AND j->>'fees' = 'none', 'C1 free claims by utm (refunded S4 out): ' || coalesce(j::text, 'missing');
  j := pg_temp.ch(NULL, NULL, 'promoter:dj-kay');
  ASSERT (j->>'tickets')::int = 1 AND j->>'label' = 'Promoters' AND public._exos_channel_detail(j->>'channel') = 'dj-kay', 'C1 promoter: ' || coalesce(j::text, 'missing');
  j := pg_temp.ch(NULL, NULL, 'box_office');
  ASSERT (j->>'tickets')::int = 1 AND (j->>'gross_cents')::int = 4000 AND (j->>'net_cents')::int = 4000 AND j->>'channel_group' = 'box_office', 'C1 box office: ' || coalesce(j::text, 'missing');
  j := pg_temp.ch(NULL, NULL, 'stubhub');
  ASSERT (j->>'tickets')::int = 2 AND (j->>'gross_cents')::int = 10000 AND (j->>'fee_cents')::int = 1000
     AND (j->>'net_cents')::int = 9000 - (j->>'exos_fee_cents')::int AND j->>'channel_group' = 'marketplace', 'C1 stubhub once (not its minted tickets too): ' || coalesce(j::text, 'missing');
  j := pg_temp.ch(NULL, NULL, 'seatgeek');
  ASSERT (j->>'tickets')::int = 1 AND j->'gross_cents' = 'null'::jsonb AND j->'fee_cents' = 'null'::jsonb
     AND (j->>'net_cents')::numeric > 0 AND j->>'fees' = 'not_reported', 'C1 seatgeek fee unknown, payout known: ' || coalesce(j::text, 'missing');
  ASSERT pg_temp.ch(NULL, NULL, 'vivid') IS NULL, 'C1 cancelled marketplace order out';
  j := pg_temp.ch(NULL, NULL, 'eventbrite');
  ASSERT (j->>'tickets')::int = 2 AND j->'gross_cents' = 'null'::jsonb AND j->'net_cents' = 'null'::jsonb
     AND j->>'fees' = 'not_reported' AND (j->>'dated')::boolean, 'C1 eventbrite from synced attendees (voided out), never estimated: ' || coalesce(j::text, 'missing');
  j := pg_temp.ch(NULL, NULL, 'luma');
  ASSERT (j->>'tickets')::int = 5 AND NOT (j->>'dated')::boolean AND j->'gross_cents' = 'null'::jsonb, 'C1 luma count, undated: ' || coalesce(j::text, 'missing');
  -- C3: comps and imports
  ASSERT (pg_temp.ch(NULL, NULL, 'comp')->>'tickets')::int = 2 AND pg_temp.ch(NULL, NULL, 'comp')->>'kind' = 'comp', 'C3 comps';
  ASSERT pg_temp.ch(NULL, NULL, 'staff_issued')->>'kind' = 'comp' AND pg_temp.ch(NULL, NULL, 'referral_reward')->>'kind' = 'comp', 'C3 staff issue + reward are comps';
  ASSERT (pg_temp.ch(NULL, NULL, 'guest_list')->>'tickets')::int = 2 AND pg_temp.ch(NULL, NULL, 'guest_list')->>'kind' = 'comp', 'C3 guest list counts plus-ones';
  j := pg_temp.ch(NULL, NULL, 'import:posh');
  ASSERT (j->>'tickets')::int = 1 AND j->>'kind' = 'attendee' AND j->>'label' = 'Imported list (Posh)', 'C3 CSV import = attendees: ' || coalesce(j::text, 'missing');
  -- Every Exos-recorded sale has a channel: the non-comp, non-marketplace live
  -- tickets equal the Exos + box office sale tickets.
  ASSERT (SELECT sum(tickets) FROM public._exos_channel_sales(pg_temp.u('0000000000e1'), NULL, NULL)
           WHERE kind = 'sale' AND channel_group IN ('exos', 'box_office'))
       = (SELECT count(*) FROM public.exos_tickets t
           WHERE t.event_id = pg_temp.u('0000000000e1') AND t.status <> 'voided'
             AND t.channel_source NOT IN ('comp', 'referral_reward', 'boxoffice', 'stubhub')), 'C1 every Exos ticket credited';
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_channel_sales(pg_temp.u('0000000000e1'), NULL, NULL) WHERE channel IS NULL OR label IS NULL), 'C1 no blank channel';
  -- Totals: sales only.
  j := public._exos_channel_totals(ARRAY[pg_temp.u('0000000000e1')], NULL, NULL) -> 0;
  ASSERT (j->>'tickets')::int = 2 + 1 + 1 + 2 + 1 + 1 + 2 + 1 + 2 + 5, 'C3 totals exclude comps / imports: ' || j::text;
  ASSERT (j->>'gross_not_reported')::int = 1 + 2 + 5, 'C3 unreported gross counted: ' || j::text;
  ASSERT (j->>'net_not_reported')::int = 1 + 2 + 5, 'C3 unreported net counted: ' || j::text;
  RAISE NOTICE 'OK  C1 every sale credited to a channel; C3 comps / imports apart';
END $$;

-- C2 ------------------------------------------------------------------------
DO $$
DECLARE j jsonb; w timestamptz := pg_temp.w();
BEGIN
  ASSERT (pg_temp.ch(w, w + interval '7 days', 'instagram')->>'tickets')::int = 2, 'C2 instagram in week';
  ASSERT pg_temp.ch(w, w + interval '7 days', 'email') IS NULL, 'C2 email before the week';
  ASSERT pg_temp.ch(w, w + interval '7 days', 'seatgeek') IS NULL, 'C2 seatgeek before the week';
  ASSERT pg_temp.ch(w, w + interval '7 days', 'luma') IS NULL, 'C2 undated luma not in a week';
  ASSERT (pg_temp.ch(w, w + interval '7 days', 'eventbrite')->>'tickets')::int = 2, 'C2 eventbrite in week';
  j := public._exos_channel_totals(ARRAY[pg_temp.u('0000000000e1')], w, w + interval '7 days') -> 0;
  ASSERT (j->>'tickets')::int = 2 + 1 + 2 + 1 + 2 + 2, 'C2 week totals: ' || j::text;
  ASSERT (j->>'gross_cents')::int = 5000 + 3000 + 0 + 4000 + 10000, 'C2 week gross: ' || j::text;
  RAISE NOTICE 'OK  C2 date range';
END $$;

-- C4 ------------------------------------------------------------------------
INSERT INTO public.exos_org_integrations (org_id, provider, config, status) VALUES
  (pg_temp.u('000000000001'), 'twilio', '{"from":"+12125550199"}', 'connected');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a3');
SELECT set_config('c3.fin', (SELECT count(*)::text FROM public.exos_channel_sales(pg_temp.u('0000000000e1'))), true);
SELECT set_config('c3.fin_set', pg_temp.refused($$SELECT public.exos_set_channel_report(pg_temp.u('000000000001'), false)$$, 'owner only')::text, true);
SELECT set_config('c3.fin_settings', public.exos_channel_report_settings(pg_temp.u('000000000001'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a2');
SELECT set_config('c3.mgr', (SELECT count(*)::text FROM public.exos_channel_sales(pg_temp.u('0000000000e1'), pg_temp.w(), pg_temp.w() + interval '7 days')), true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a4');
SELECT set_config('c3.scan', pg_temp.refused($$SELECT * FROM public.exos_channel_sales(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT set_config('c3.scan_ev', pg_temp.refused($$SELECT public.exos_event_channel_report(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT set_config('c3.scan_org', pg_temp.refused($$SELECT public.exos_org_channel_report(pg_temp.u('000000000001'))$$, 'not authorized')::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a5');
SELECT set_config('c3.out', pg_temp.refused($$SELECT * FROM public.exos_channel_sales(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT set_config('c3.out_set', pg_temp.refused($$SELECT public.exos_channel_report_settings(pg_temp.u('000000000001'))$$, 'not authorized')::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
SELECT set_config('c3.badphone', pg_temp.refused($$SELECT public.exos_set_channel_report(pg_temp.u('000000000001'), true, 'call me')$$, 'mobile number')::text, true);
SELECT set_config('c3.own_set', public.exos_set_channel_report(pg_temp.u('000000000001'), true, '(212) 555-0142')::text, true);
-- NULL keeps the number; '' clears it (checked on org 2).
SELECT set_config('c3.keep', public.exos_set_channel_report(pg_temp.u('000000000001'), true)::text, true);
-- The dashboard reads, as the owner, for C7.
SELECT set_config('c3.ev', public.exos_event_channel_report(pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('c3.org', public.exos_org_channel_report(pg_temp.u('000000000001'))::text, true);
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
DECLARE s jsonb := current_setting('c3.own_set')::jsonb; f text;
BEGIN
  ASSERT current_setting('c3.fin')::int >= 10, 'C4 finance reads';
  ASSERT current_setting('c3.mgr')::int >= 5, 'C4 manager reads a range';
  ASSERT current_setting('c3.fin_set')::boolean, 'C4 finance can''t change settings';
  ASSERT (current_setting('c3.fin_settings')::jsonb->>'enabled')::boolean AND NOT (current_setting('c3.fin_settings')::jsonb->>'can_edit')::boolean, 'C4 default on; finance can''t edit';
  ASSERT current_setting('c3.scan')::boolean AND current_setting('c3.scan_ev')::boolean AND current_setting('c3.scan_org')::boolean, 'C4 scanner refused';
  ASSERT current_setting('c3.out')::boolean AND current_setting('c3.out_set')::boolean, 'C4 outsider refused';
  ASSERT current_setting('c3.badphone')::boolean, 'C4 bad number refused';
  ASSERT s->>'sms_phone_hint' = '…0142' AND s->>'sms_provider' = 'twilio' AND (s->>'can_edit')::boolean, 'C4 owner sets the number: ' || s::text;
  ASSERT (SELECT sms_phone FROM public.exos_channel_report_settings WHERE org_id = pg_temp.u('000000000001')) = '+12125550142', 'C4 number normalized';
  ASSERT current_setting('c3.keep')::jsonb->>'sms_phone_hint' = '…0142', 'C4 NULL keeps the number';
  FOREACH f IN ARRAY ARRAY['exos_channel_sales(uuid,timestamptz,timestamptz)', 'exos_event_channel_report(uuid,date)',
                           'exos_org_channel_report(uuid,date)', 'exos_channel_report_settings(uuid)',
                           'exos_set_channel_report(uuid,boolean,text)'] LOOP
    ASSERT NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'), 'C4 anon: ' || f;
    ASSERT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'), 'C4 authenticated: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['_exos_channel_lines(uuid)', '_exos_channel_sales(uuid,timestamptz,timestamptz)',
                           '_exos_channel_totals(uuid[],timestamptz,timestamptz)', '_exos_channel_event_json(uuid,timestamptz,timestamptz)',
                           '_exos_channel_report_payload(uuid,timestamptz,timestamptz,timestamptz)',
                           '_exos_sms_stopped(uuid,text)', 'exos_send_channel_reports(timestamptz,integer)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'), 'C4 internal: ' || f;
    ASSERT NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'), 'C4 internal (anon): ' || f;
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_send_channel_reports(timestamptz,integer)', 'EXECUTE'), 'C4 cron entry is service role';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_channel_report_settings', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_channel_reports', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_sms_stops', 'SELECT'), 'C4 tables are RPC-only';
  RAISE NOTICE 'OK  C4 roles and grants';
END $$;

-- C5 ------------------------------------------------------------------------
-- The manager unsubscribed from follow-ups; org 3 turned the report off.
INSERT INTO public.exos_mail_prefs (user_id, marketing_opt_out) VALUES (pg_temp.u('0000000000a2'), true)
  ON CONFLICT (user_id) DO UPDATE SET marketing_opt_out = true;
INSERT INTO public.exos_channel_report_settings (org_id, enabled) VALUES (pg_temp.u('000000000003'), false);
SELECT set_config('c3.run1', public.exos_send_channel_reports(now())::text, true);
DO $$
DECLARE r jsonb := current_setting('c3.run1')::jsonb; m public.exos_mail%ROWTYPE; p jsonb; o public.exos_sms_outbox%ROWTYPE; wk text;
BEGIN
  wk := to_char(pg_temp.w() AT TIME ZONE 'UTC', 'IYYY-"W"IW');
  ASSERT r->>'iso_week' = wk, 'C5 the last full ISO week: ' || r::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_channel_reports WHERE org_id = pg_temp.u('000000000001') AND iso_week = wk AND mails = 1 AND texts = 1), 'C5 org 1 reported once';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_channel_reports WHERE org_id IN (pg_temp.u('000000000002'), pg_temp.u('000000000003'))), 'C5 no event in the window / switched off: nothing';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'org-channel-report' AND payload->'org'->>'id' = pg_temp.u('000000000001')::text) = 1, 'C5 one mail (manager opted out)';
  SELECT * INTO m FROM public.exos_mail WHERE template = 'org-channel-report' AND payload->'org'->>'id' = pg_temp.u('000000000001')::text;
  p := m.payload;
  ASSERT m.to_email = 'own-c3@x.com' AND m.status = 'pending' AND m.html = '', 'C5 payload row to the owner';
  ASSERT (p->>'marketing')::boolean AND p->>'unsubscribe_token' ~ '^[0-9a-f]{64}$' AND m.list_unsubscribe LIKE '{{app_url}}/unsubscribe?t=%', 'C5 follow-up with unsubscribe';
  ASSERT jsonb_array_length(p->'events') = 2 AND p->'events'->0->>'name' = 'C3 Last' AND p->'events'->1->>'name' = 'C3 <Show>', 'C5 window events, soonest first, no draft';
  ASSERT p::text NOT LIKE '%fan1-c3%' AND p::text NOT LIKE '%fan2-c3%' AND p::text NOT LIKE '%buyer-sh-c3%' AND p::text NOT LIKE '%c3-s1%', 'C5 no buyer data';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail_dedupe
                  WHERE dedupe_key = 'org-weekly-summary:' || pg_temp.u('000000000001') || ':' || to_char(pg_temp.w() AT TIME ZONE 'UTC', 'YYYYMMDD') || ':' || pg_temp.u('0000000000a1')),
         'C5 replaces the week''s summary for the owner';
  SELECT * INTO o FROM public.exos_sms_outbox WHERE org_id = pg_temp.u('000000000001');
  ASSERT o.phone = '+12125550142' AND o.status = 'queued', 'C5 text queued: ' || row_to_json(o)::text;
  ASSERT o.body LIKE 'C3 <Org>: last week % tickets (%) , % to date. Report: {{app_url}}/orgs/' || pg_temp.u('000000000001') || '/channels Reply STOP to opt out.'
      OR o.body LIKE 'C3 <Org>: last week % tickets (%), % to date. Report: {{app_url}}/orgs/' || pg_temp.u('000000000001') || '/channels Reply STOP to opt out.', 'C5 text body: ' || o.body;
  -- C8: buyer-written utm_source never reaches the text or the mail payload's labels.
  ASSERT o.body LIKE '%(Other 3, %' AND o.body NOT LIKE '%evil%' AND o.body NOT LIKE '%0100%'
     AND o.body NOT LIKE '%<b>%' AND o.body NOT LIKE '%b-x-b%', 'C8 text shows Other only: ' || o.body;
  ASSERT p::text NOT LIKE '%evil.com%' AND p::text NOT LIKE '%<b>%' AND p::text NOT LIKE '%+1 212%' AND p::text NOT LIKE '%212 555%', 'C8 raw sources not in the payload';
  ASSERT (SELECT array_agg(DISTINCT c->>'label') FROM jsonb_array_elements(p->'events'->0->'channels') c
           WHERE c->>'channel' IN ('evil', '1-212-555-0100', 'b-x-b')) = ARRAY['Other'], 'C8 labelled Other: ' || (p->'events'->0->'channels')::text;
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p->'events') e, jsonb_array_elements(e->'channels') c
                      WHERE c->>'channel' !~ '^[a-z0-9_-]+$' OR coalesce(c->>'detail', 'x') !~ '^[a-z0-9_-]+$'), 'C8 keys / details [a-z0-9_-] only';
  ASSERT (SELECT audience FROM public.exos_sms_campaigns WHERE id = o.campaign_id) = 'staff_report', 'C5 staff_report campaign';
  ASSERT ((o.send_after AT TIME ZONE 'America/New_York')::time BETWEEN time '09:00' AND time '20:00'), 'C5 quiet hours';
  RAISE NOTICE 'OK  C5 weekly run';
END $$;

-- The older weekly summary isn't sent to the owner on top of this report.
SELECT count(*) FROM public.exos_send_mail_followups() \gset c3_
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'org-weekly-summary'
                      AND payload->'org'->>'id' = pg_temp.u('000000000001')::text), 'C5 no org-weekly-summary on top';
  RAISE NOTICE 'OK  C5 summary suppressed';
END $$;

-- C6 ------------------------------------------------------------------------
SELECT set_config('c3.run2', public.exos_send_channel_reports(now())::text, true);
SELECT public.exos_sms_inbound(pg_temp.u('000000000001'), '+1 212 555 0142', 'stop');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a6');
SELECT public.exos_set_channel_report(pg_temp.u('000000000002'), true, '+12125550177');
SELECT set_config('c3.clear', public.exos_set_channel_report(pg_temp.u('000000000002'), false, '')::text, true);
-- STOP is durable: the owner can't save that number again (any spelling).
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
SELECT set_config('c3.resave', pg_temp.refused($$SELECT public.exos_set_channel_report(pg_temp.u('000000000001'), true, '212-555-0142')$$, 'text START')::text, true);
RESET ROLE;
SELECT pg_temp.act(NULL);
SELECT set_config('c3.cleared', (SELECT (sms_phone IS NULL)::text FROM public.exos_channel_report_settings WHERE org_id = pg_temp.u('000000000001')), true);
-- Even with the number forced back into the settings, the send-time check holds.
UPDATE public.exos_channel_report_settings SET sms_phone = '+12125550142' WHERE org_id = pg_temp.u('000000000001');
SELECT set_config('c3.run3', public.exos_send_channel_reports(now() + interval '7 days')::text, true);
DO $$
DECLARE r jsonb := current_setting('c3.run2')::jsonb;
BEGIN
  ASSERT (r->>'orgs')::int = 0 AND (r->>'mails')::int = 0 AND (r->>'texts')::int = 0, 'C6 second run sends nothing: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'org-channel-report' AND payload->'org'->>'id' = pg_temp.u('000000000001')::text
           AND payload->>'iso_week' = to_char(pg_temp.w() AT TIME ZONE 'UTC', 'IYYY-"W"IW')) = 1, 'C6 still one mail for the week';
  ASSERT (SELECT count(*) FROM public.exos_sms_outbox WHERE org_id = pg_temp.u('000000000001')) = 1, 'C6 still one text';
  ASSERT (SELECT status FROM public.exos_sms_outbox WHERE org_id = pg_temp.u('000000000001') ORDER BY created_at LIMIT 1) = 'skipped', 'C6 STOP skips the queued text';
  ASSERT EXISTS (SELECT 1 FROM public.exos_sms_stops WHERE org_id = pg_temp.u('000000000001') AND phone = '+12125550142'), 'C6 STOP recorded';
  ASSERT current_setting('c3.cleared')::boolean, 'C6 STOP clears the number';
  ASSERT current_setting('c3.clear')::jsonb->'sms_phone_hint' = 'null'::jsonb AND NOT (current_setting('c3.clear')::jsonb->>'enabled')::boolean, 'C6 '''' clears the number; off';
  ASSERT current_setting('c3.resave')::boolean, 'C6 a stopped number can''t be saved again';
  -- A different week reports again (the key is the ISO week), without a text.
  ASSERT (current_setting('c3.run3')::jsonb->>'orgs')::int >= 1, 'C6 next week is a new report';
  ASSERT EXISTS (SELECT 1 FROM public.exos_channel_reports WHERE org_id = pg_temp.u('000000000001') AND week_start = pg_temp.w() + interval '7 days' AND texts = 0), 'C6 next week: no text';
  ASSERT (SELECT count(*) FROM public.exos_sms_outbox WHERE org_id = pg_temp.u('000000000001')) = 1, 'C6 nothing queued to a stopped number';
  RAISE NOTICE 'OK  C6 idempotent per org + ISO week; STOP is durable';
END $$;

-- START from the number lifts it; then the owner may save it again.
SELECT public.exos_sms_inbound(pg_temp.u('000000000001'), '+12125550142', 'START');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
SELECT set_config('c3.restart', public.exos_set_channel_report(pg_temp.u('000000000001'), true, '+12125550142')::text, true);
RESET ROLE;
SELECT pg_temp.act(NULL);
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_stops WHERE org_id = pg_temp.u('000000000001')), 'C6 START clears the stop';
  ASSERT current_setting('c3.restart')::jsonb->>'sms_phone_hint' = '…0142', 'C6 saved again after START';
  RAISE NOTICE 'OK  C6 START';
END $$;

-- C7 ------------------------------------------------------------------------
DO $$
DECLARE ev jsonb := current_setting('c3.ev')::jsonb; org jsonb := current_setting('c3.org')::jsonb; mailed jsonb; c jsonb;
BEGIN
  SELECT payload INTO mailed FROM public.exos_channel_reports
   WHERE org_id = pg_temp.u('000000000001') AND iso_week = to_char(pg_temp.w() AT TIME ZONE 'UTC', 'IYYY-"W"IW');
  ASSERT org->'events' = mailed->'events' AND org->'totals' = mailed->'totals', 'C7 org view = the mailed document';
  ASSERT ev->'channels' = mailed->'events'->1->'channels', 'C7 event card = its part of the mail';
  ASSERT ev->>'iso_week' = mailed->>'iso_week', 'C7 same week';
  SELECT x INTO c FROM jsonb_array_elements(ev->'channels') x WHERE x->>'channel' = 'instagram';
  ASSERT c->'week' = '[2, 5000, 100, 150, 4750]'::jsonb AND c->'to_date' = '[2, 5000, 100, 150, 4750]'::jsonb, 'C7 arrays: ' || c::text;
  SELECT x INTO c FROM jsonb_array_elements(ev->'channels') x WHERE x->>'channel' = 'luma';
  ASSERT c->'week' = 'null'::jsonb AND c->'to_date'->>0 = '5', 'C7 undated week is null: ' || c::text;
  SELECT x INTO c FROM jsonb_array_elements(ev->'channels') x WHERE x->>'channel' = 'email';
  ASSERT c->'week' = '[0, 0, 0, 0, 0]'::jsonb, 'C7 no sales this week = zeros: ' || c::text;
  ASSERT (SELECT bool_and(x->>'kind' = 'sale') FROM (SELECT x, row_number() OVER () AS n FROM jsonb_array_elements(ev->'channels') x) s
           WHERE s.n <= (SELECT count(*) FROM jsonb_array_elements(ev->'channels') y WHERE y->>'kind' = 'sale')), 'C7 sales listed first';
  RAISE NOTICE 'OK  C7 dashboard = email';
END $$;

\echo 'test_weekly_channel_report: all passed'
ROLLBACK;
