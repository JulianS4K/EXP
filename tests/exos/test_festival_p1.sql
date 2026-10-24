-- ============================================================================
-- Festival / series / waitlist fixes (mig 20261021130000), on the Brooklyn
-- Fall Festival scenario of the 2026-10-19 usage simulation:
--   F1 a series clone gets its own tax rule, quota (same member tiers), add-on,
--      check-in list and codes; sales windows, price steps, list windows and
--      code expiry move by the date's delta; personal codes stay behind
--   F2 waitlist on a shared quota: a GA seat (capacity-0 tier in the quota)
--      freed by a refund is offered in queue order, across the quota's tiers;
--      the public can't take seats owed to the queue; a join is capped at
--      maxPerOrder
--   F3 an expired group offer passes on its 4 seats (not 1) and stops
--      working; offers end by the event's end; none once the event is over
--   F4 reschedule: doors / end / future sales windows / list windows move
--      with the start; past windows stay; doors <= start <= end is checked
--   F5 add-on stock is held with the cart hold
--   F6 price_paid and the refund share leave the add-on's tax out
-- Self-contained (BEGIN / ROLLBACK).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('fe100000-0000-0000-0000-0000000000a0','owner@bff1.test',now()),
  ('fe100000-0000-0000-0000-0000000000b1','fan1@bff1.test',now()),
  ('fe100000-0000-0000-0000-0000000000b2','fan2@bff1.test',now()),
  ('fe100000-0000-0000-0000-0000000000b3','fan3@bff1.test',now()),
  ('fe100000-0000-0000-0000-0000000000b4','fan4@bff1.test',now()),
  ('fe100000-0000-0000-0000-0000000000b5','fan5@bff1.test',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('fe100000-0000-0000-0000-000000000001','Brooklyn Fall Fest','bff1-stub','fe100000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('fe100000-0000-0000-0000-000000000001','fe100000-0000-0000-0000-0000000000a0','owner');

CREATE FUNCTION pg_temp.act(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, false),
         set_config('app.jwt', json_build_object('email', p_email, 'sub', p_uid, 'role', 'authenticated')::text, false);
$$;
CREATE FUNCTION pg_temp.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'ok'; EXCEPTION WHEN others THEN RETURN SQLSTATE || ' ' || SQLERRM; END $$;

-- ---------------------------------------------------------------------------
-- F1. Series clone. Friday template: doors 18:00, start 19:00, end 01:30 NY.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,ends_at,timezone,total_tickets,tickets_sold,created_by,purchase_limits)
VALUES ('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-000000000001','Brooklyn Fall Festival','bff1-2026','published',
        '2026-11-06 19:00-05','2026-11-06 18:00-05','2026-11-07 01:30-05','America/New_York',0,0,
        'fe100000-0000-0000-0000-0000000000a0','{"maxPerOrder":4}');
INSERT INTO public.exos_tax_rules(id,event_id,name,rate_percent,price_includes_tax) VALUES
  ('fe100000-0000-0000-0000-0000000000c1','fe100000-0000-0000-0000-0000000000e1','NYC sales tax',8.875,false);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sales_end,price_schedule,tax_rate_id,sort_order) VALUES
  ('fe100000-0000-0000-0000-0000000000d1','fe100000-0000-0000-0000-0000000000e1','GA',45,0,0,'public','2026-11-06 23:00-05',
     '[{"startsAt":"2026-10-25T04:00:00Z","price":60},{"starts_at":"2026-11-01T04:00:00Z","price":70}]','fe100000-0000-0000-0000-0000000000c1',1),
  ('fe100000-0000-0000-0000-0000000000d2','fe100000-0000-0000-0000-0000000000e1','VIP',120,50,0,'public','2026-11-06 23:00-05',
     '[]','fe100000-0000-0000-0000-0000000000c1',2),
  ('fe100000-0000-0000-0000-0000000000d3','fe100000-0000-0000-0000-0000000000e1','Presale GA',40,0,0,'hidden','2026-10-23 23:59-04',
     '[]','fe100000-0000-0000-0000-0000000000c1',0);
INSERT INTO public.exos_quotas(id,event_id,org_id,name,size) VALUES
  ('fe100000-0000-0000-0000-0000000000f1','fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-000000000001','Site capacity',10);
INSERT INTO public.exos_quota_tiers(quota_id,tier_id) VALUES
  ('fe100000-0000-0000-0000-0000000000f1','fe100000-0000-0000-0000-0000000000d1'),
  ('fe100000-0000-0000-0000-0000000000f1','fe100000-0000-0000-0000-0000000000d2'),
  ('fe100000-0000-0000-0000-0000000000f1','fe100000-0000-0000-0000-0000000000d3');
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity,sold,max_per_order,tax_rate_id) VALUES
  ('fe100000-0000-0000-0000-0000000000a9','fe100000-0000-0000-0000-0000000000e1','Locker',10,3,2,1,'fe100000-0000-0000-0000-0000000000c1');
INSERT INTO public.exos_checkin_lists(id,event_id,org_id,name,tier_ids,allow_reentry,valid_from,valid_until) VALUES
  ('fe100000-0000-0000-0000-00000000c111','fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-000000000001','VIP gate',
   ARRAY['fe100000-0000-0000-0000-0000000000d2']::uuid[],true,'2026-11-06 17:30-05','2026-11-07 02:00-05');
INSERT INTO public.exos_vouchers(id,event_id,code,tier_id,max_uses,used_count,valid_until,comment,reserved_email) VALUES
  ('fe100000-0000-0000-0000-0000000000e7','fe100000-0000-0000-0000-0000000000e1','BFFPRESALE','fe100000-0000-0000-0000-0000000000d3',50,7,'2026-10-23 23:59-04','presale',NULL),
  ('fe100000-0000-0000-0000-0000000000e8','fe100000-0000-0000-0000-0000000000e1','FALL10',NULL,100,3,NULL,NULL,NULL),
  ('fe100000-0000-0000-0000-0000000000e9','fe100000-0000-0000-0000-0000000000e1','FORDANA','fe100000-0000-0000-0000-0000000000d2',1,0,NULL,NULL,'dana@bff1.test'),
  ('fe100000-0000-0000-0000-0000000000ea','fe100000-0000-0000-0000-0000000000e1','WL0001','fe100000-0000-0000-0000-0000000000d2',1,0,NULL,'waitlist auto-offer','w@bff1.test');

SELECT pg_temp.act('fe100000-0000-0000-0000-0000000000a0', 'owner@bff1.test');
CREATE TEMP TABLE f1 AS
SELECT * FROM public.exos_create_event_series('fe100000-0000-0000-0000-0000000000e1',
  ARRAY['2026-11-07 19:00-05','2026-11-08 19:00-05']::timestamptz[], 'recurring', 'BFF 2026', NULL, NULL);

DO $$
DECLARE c record; v_d interval; t record; n int; v record;
BEGIN
  ASSERT (SELECT count(*) FROM f1) = 2, 'F1 two clones';
  FOR c IN SELECT * FROM f1 LOOP
    v_d := c.starts_at - '2026-11-06 19:00-05'::timestamptz;
    ASSERT (SELECT count(*) FROM public.exos_tax_rules WHERE event_id = c.event_id AND rate_percent = 8.875) = 1, 'F1 own tax rule';
    -- Every tier points at this date's own rule, and sells until this date's night.
    ASSERT NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers tt
                        WHERE tt.event_id = c.event_id
                          AND NOT EXISTS (SELECT 1 FROM public.exos_tax_rules r WHERE r.id = tt.tax_rate_id AND r.event_id = c.event_id)),
      'F1 tiers on the clone''s tax rule';
    SELECT * INTO t FROM public.exos_ticket_tiers WHERE event_id = c.event_id AND name = 'GA';
    ASSERT t.sales_end = '2026-11-06 23:00-05'::timestamptz + v_d, 'F1 GA sales end moved';
    ASSERT (t.price_schedule -> 0 ->> 'startsAt')::timestamptz = '2026-10-25T04:00:00Z'::timestamptz + v_d, 'F1 price step moved';
    ASSERT (t.price_schedule -> 1 ->> 'starts_at')::timestamptz = '2026-11-01T04:00:00Z'::timestamptz + v_d, 'F1 starts_at step moved too';
    ASSERT (t.price_schedule -> 0 ->> 'price')::numeric = 60, 'F1 step price kept';
    ASSERT (SELECT sales_end FROM public.exos_ticket_tiers WHERE event_id = c.event_id AND name = 'Presale GA')
           = '2026-10-23 23:59-04'::timestamptz + v_d, 'F1 presale end moved';
    ASSERT public.exos_tier_exclusive_tax_percent(t.id) = 8.875, 'F1 tax still applies';
    -- The site cap: one quota of 10 over this date's three tiers.
    SELECT count(*) INTO n FROM public.exos_quotas q JOIN public.exos_quota_tiers qt ON qt.quota_id = q.id
      JOIN public.exos_ticket_tiers tt ON tt.id = qt.tier_id AND tt.event_id = c.event_id
     WHERE q.event_id = c.event_id AND q.size = 10;
    ASSERT n = 3, format('F1 quota with its 3 tiers (got %s)', n);
    ASSERT (SELECT org_id FROM public.exos_quotas WHERE event_id = c.event_id) = 'fe100000-0000-0000-0000-000000000001', 'F1 quota org';
    -- Add-on: own stock, this date's tax rule.
    ASSERT (SELECT count(*) FROM public.exos_event_addons a JOIN public.exos_tax_rules r ON r.id = a.tax_rate_id AND r.event_id = c.event_id
             WHERE a.event_id = c.event_id AND a.sold = 0 AND a.capacity = 3) = 1, 'F1 add-on copied';
    -- List: this date's VIP tier, window moved.
    ASSERT (SELECT l.valid_from = '2026-11-06 17:30-05'::timestamptz + v_d
               AND l.valid_until = '2026-11-07 02:00-05'::timestamptz + v_d
               AND l.tier_ids = ARRAY[(SELECT id FROM public.exos_ticket_tiers WHERE event_id = c.event_id AND name = 'VIP')]
               AND l.allow_reentry
              FROM public.exos_checkin_lists l WHERE l.event_id = c.event_id), 'F1 list copied';
    -- Codes: presale + promo, unused; not the personal ones.
    ASSERT (SELECT count(*) FROM public.exos_vouchers WHERE event_id = c.event_id) = 2, 'F1 two codes copied';
    SELECT * INTO v FROM public.exos_vouchers WHERE event_id = c.event_id AND code = 'BFFPRESALE';
    ASSERT v.used_count = 0 AND v.max_uses = 50, 'F1 presale fresh';
    ASSERT v.tier_id = (SELECT id FROM public.exos_ticket_tiers WHERE event_id = c.event_id AND name = 'Presale GA'), 'F1 presale on the clone tier';
    ASSERT v.valid_until = '2026-10-23 23:59-04'::timestamptz + v_d, 'F1 presale expiry moved';
    ASSERT (SELECT tier_id IS NULL AND used_count = 0 AND valid_until IS NULL FROM public.exos_vouchers
             WHERE event_id = c.event_id AND code = 'FALL10'), 'F1 promo code copied';
  END LOOP;
  -- The template is untouched.
  ASSERT (SELECT count(*) FROM public.exos_vouchers WHERE event_id = 'fe100000-0000-0000-0000-0000000000e1') = 4, 'F1 template codes kept';
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE id = 'fe100000-0000-0000-0000-0000000000e7') = 7, 'F1 template use count kept';
END $$;

-- Extending the series from the template again copies once per new date.
SELECT count(*) AS extended FROM public.exos_create_event_series('fe100000-0000-0000-0000-0000000000e1',
  ARRAY['2026-11-08 19:00-05','2026-11-09 19:00-05']::timestamptz[], 'recurring', NULL, NULL, NULL);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_events WHERE series_id = (SELECT series_id FROM public.exos_events WHERE id = 'fe100000-0000-0000-0000-0000000000e1')) = 4,
    'F1 extend adds only the new date';
  ASSERT public._exos_shift_price_schedule('[{"startsAt":"nope","price":1},3]'::jsonb, interval '1 day')
         = '[{"startsAt":"nope","price":1},3]'::jsonb, 'F1 junk steps left as they are';
END $$;

-- ---------------------------------------------------------------------------
-- F2. Waitlist on the shared quota (the template: GA capacity 0, VIP 50,
--     site cap 10). Sold out: 6 GA + 4 VIP.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
SELECT ('fe100000-0000-0000-0000-0000000010' || lpad(g::text, 2, '0'))::uuid, 'fe100000-0000-0000-0000-0000000000e1', 'fe100000-0000-0000-0000-000000000001',
       CASE WHEN g <= 6 THEN 'fe100000-0000-0000-0000-0000000000d1'::uuid ELSE 'fe100000-0000-0000-0000-0000000000d2'::uuid END,
       CASE WHEN g <= 6 THEN 'GA' ELSE 'VIP' END,
       'fe100000-0000-0000-0000-0000000000b1', 'fe100000-0000-0000-0000-0000000000b1', 'active', 'sek-' || g, 45, 'f2-' || g
  FROM generate_series(1, 10) g;
UPDATE public.exos_ticket_tiers SET sold = 6 WHERE id = 'fe100000-0000-0000-0000-0000000000d1';
UPDATE public.exos_ticket_tiers SET sold = 4 WHERE id = 'fe100000-0000-0000-0000-0000000000d2';
-- Offers end by the event's end; the fixture show is in the future.
UPDATE public.exos_events SET starts_at = now() + interval '10 days', doors_at = now() + interval '10 days' - interval '1 hour',
       ends_at = now() + interval '10 days 6 hours' WHERE id = 'fe100000-0000-0000-0000-0000000000e1';
UPDATE public.exos_ticket_tiers SET sales_end = NULL WHERE event_id = 'fe100000-0000-0000-0000-0000000000e1';

-- fan4 waits for GA, then fan5 for VIP (fan5 asks 10: capped at maxPerOrder 4,
-- then lowers it to 1), then fan3 for 2 GA.
SELECT pg_temp.act('fe100000-0000-0000-0000-0000000000b4', 'fan4@bff1.test');
SELECT waitlist_id IS NOT NULL AS fan4_joined FROM public.exos_join_waitlist('fe100000-0000-0000-0000-0000000000e1', NULL, 'fe100000-0000-0000-0000-0000000000d1', 'Fan Four', 1, NULL);
UPDATE public.exos_waitlist SET created_at = now() - interval '3 hours' WHERE email = 'fan4@bff1.test';
SELECT pg_temp.act('fe100000-0000-0000-0000-0000000000b5', 'fan5@bff1.test');
SELECT waitlist_id IS NOT NULL AS fan5_joined FROM public.exos_join_waitlist('fe100000-0000-0000-0000-0000000000e1', NULL, 'fe100000-0000-0000-0000-0000000000d2', 'Fan Five', 10, NULL);
DO $$ BEGIN
  ASSERT (SELECT quantity FROM public.exos_waitlist WHERE email = 'fan5@bff1.test') = 4, 'F2 join capped at maxPerOrder';
END $$;
SELECT count(*) AS fan5_lowered FROM public.exos_join_waitlist('fe100000-0000-0000-0000-0000000000e1', NULL, 'fe100000-0000-0000-0000-0000000000d2', NULL, 1, NULL);
UPDATE public.exos_waitlist SET created_at = now() - interval '2 hours' WHERE email = 'fan5@bff1.test';
SELECT pg_temp.act('fe100000-0000-0000-0000-0000000000b3', 'fan3@bff1.test');
SELECT count(*) AS fan3_joined FROM public.exos_join_waitlist('fe100000-0000-0000-0000-0000000000e1', NULL, 'fe100000-0000-0000-0000-0000000000d1', NULL, 2, NULL);
UPDATE public.exos_waitlist SET created_at = now() - interval '1 hour' WHERE email = 'fan3@bff1.test';

DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_waitlist WHERE event_id = 'fe100000-0000-0000-0000-0000000000e1' AND status <> 'waiting'),
    'F2 nobody offered while sold out';
  ASSERT public.exos_waitlist_owed('fe100000-0000-0000-0000-0000000000d1') = 4, 'F2 GA owed 1 + 1 + 2';
END $$;

-- A GA ticket is refunded: the quota seat goes to fan4 (first in line), not
-- to the public, though GA itself has no capacity of its own.
UPDATE public.exos_tickets SET status = 'voided' WHERE id = 'fe100000-0000-0000-0000-000000001001';
UPDATE public.exos_ticket_tiers SET sold = sold - 1 WHERE id = 'fe100000-0000-0000-0000-0000000000d1';
DO $$ DECLARE w record; BEGIN
  SELECT * INTO w FROM public.exos_waitlist WHERE email = 'fan4@bff1.test';
  ASSERT w.status = 'offered', 'F2 fan4 offered the freed GA seat';
  ASSERT (SELECT tier_id = 'fe100000-0000-0000-0000-0000000000d1' AND block_quota AND max_uses = 1
            FROM public.exos_vouchers WHERE id = w.voucher_id), 'F2 the offer reserves the GA seat';
  ASSERT w.claim_expires_at <= now() + interval '48 hours', 'F2 48h offer';
  ASSERT (SELECT status FROM public.exos_waitlist WHERE email = 'fan5@bff1.test') = 'waiting', 'F2 fan5 still waiting';
  ASSERT public.exos_quota_available('fe100000-0000-0000-0000-0000000000f1') = 0, 'F2 the seat is reserved';
END $$;

-- A VIP refund: the quota seat goes to fan5 (next in line, VIP has room).
UPDATE public.exos_tickets SET status = 'voided' WHERE id = 'fe100000-0000-0000-0000-000000001007';
UPDATE public.exos_ticket_tiers SET sold = sold - 1 WHERE id = 'fe100000-0000-0000-0000-0000000000d2';
DO $$ BEGIN
  ASSERT (SELECT status FROM public.exos_waitlist WHERE email = 'fan5@bff1.test') = 'offered', 'F2 fan5 offered';
  ASSERT (SELECT v.tier_id FROM public.exos_waitlist w JOIN public.exos_vouchers v ON v.id = w.voucher_id
           WHERE w.email = 'fan5@bff1.test') = 'fe100000-0000-0000-0000-0000000000d2', 'F2 fan5 offered VIP';
END $$;

-- One more GA seat: fan3 wants 2, so it waits; the public can't take it.
UPDATE public.exos_tickets SET status = 'voided' WHERE id = 'fe100000-0000-0000-0000-000000001002';
UPDATE public.exos_ticket_tiers SET sold = sold - 1 WHERE id = 'fe100000-0000-0000-0000-0000000000d1';
SELECT pg_temp.act('fe100000-0000-0000-0000-0000000000b2', 'fan2@bff1.test');
DO $$ BEGIN
  ASSERT (SELECT status FROM public.exos_waitlist WHERE email = 'fan3@bff1.test') = 'waiting', 'F2 the group of 2 waits';
  ASSERT public.exos_effective_available('fe100000-0000-0000-0000-0000000000d1') = 1, 'F2 one seat free';
  ASSERT pg_temp.try($q$SELECT public.exos_create_hold('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d1',1,1800,NULL)$q$)
         LIKE '23514%not enough tickets%', 'F2 public GA hold refused (owed to the queue)';
  ASSERT pg_temp.try($q$SELECT public.exos_create_hold('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d2',1,1800,NULL)$q$)
         LIKE '23514%not enough tickets%', 'F2 public VIP hold refused (same quota)';
  ASSERT pg_temp.try($q$SELECT public.exos_create_guest_hold('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d1',1,'guest@bff1.test',NULL,NULL)$q$)
         LIKE '23514%not enough tickets%', 'F2 guest GA hold refused';
END $$;
-- A second seat: fan3's group of 2 is offered.
UPDATE public.exos_tickets SET status = 'voided' WHERE id = 'fe100000-0000-0000-0000-000000001003';
UPDATE public.exos_ticket_tiers SET sold = sold - 1 WHERE id = 'fe100000-0000-0000-0000-0000000000d1';
DO $$ BEGIN
  ASSERT (SELECT w.status = 'offered' AND v.max_uses = 2 FROM public.exos_waitlist w JOIN public.exos_vouchers v ON v.id = w.voucher_id
           WHERE w.email = 'fan3@bff1.test'), 'F2 fan3 offered 2';
  ASSERT public.exos_waitlist_owed('fe100000-0000-0000-0000-0000000000d1') = 0, 'F2 nobody owed';
END $$;
-- Queue empty: a bigger quota is the public's again.
UPDATE public.exos_quotas SET size = 12 WHERE id = 'fe100000-0000-0000-0000-0000000000f1';
DO $$ BEGIN
  ASSERT pg_temp.try($q$SELECT public.exos_create_hold('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d1',2,1800,NULL)$q$) = 'ok',
    'F2 public hold once the queue is served';
END $$;

-- ---------------------------------------------------------------------------
-- F3. Cabanas (capacity 4, no quota): a group of 4 lets its offer lapse; the
--     4 seats go to the two groups of 2 behind it.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('fe100000-0000-0000-0000-0000000000d7','fe100000-0000-0000-0000-0000000000e1','Cabana',400,4,4);
INSERT INTO public.exos_waitlist(event_id,tier_id,user_id,email,quantity,status,created_at) VALUES
 ('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d7','fe100000-0000-0000-0000-0000000000b3','cab3@bff1.test',4,'waiting',now()-interval '3 h'),
 ('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d7','fe100000-0000-0000-0000-0000000000b4','cab4@bff1.test',2,'waiting',now()-interval '2 h'),
 ('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d7','fe100000-0000-0000-0000-0000000000b5','cab5@bff1.test',2,'waiting',now()-interval '1 h');
UPDATE public.exos_ticket_tiers SET sold = 0 WHERE id = 'fe100000-0000-0000-0000-0000000000d7';
DO $$ BEGIN
  ASSERT (SELECT status FROM public.exos_waitlist WHERE email = 'cab3@bff1.test') = 'offered', 'F3 the group of 4 offered';
  ASSERT (SELECT count(*) FROM public.exos_waitlist WHERE tier_id = 'fe100000-0000-0000-0000-0000000000d7' AND status = 'waiting') = 2, 'F3 the rest wait';
END $$;
UPDATE public.exos_waitlist SET claim_expires_at = now() - interval '1 minute' WHERE email = 'cab3@bff1.test';
SELECT public.exos_waitlist_expire_offers() AS expired;
-- Twice in one transaction is fine.
SELECT public.exos_waitlist_expire_offers() AS expired_again;
DO $$ BEGIN
  ASSERT (SELECT status FROM public.exos_waitlist WHERE email = 'cab3@bff1.test') = 'expired', 'F3 expired';
  ASSERT (SELECT v.valid_until <= now() FROM public.exos_waitlist w JOIN public.exos_vouchers v ON v.id = w.voucher_id
           WHERE w.email = 'cab3@bff1.test'), 'F3 the expired code stops working';
  ASSERT (SELECT count(*) FROM public.exos_waitlist WHERE tier_id = 'fe100000-0000-0000-0000-0000000000d7' AND status = 'offered') = 2,
    'F3 both groups of 2 offered (4 seats passed on)';
  ASSERT public.exos_effective_available('fe100000-0000-0000-0000-0000000000d7') = 0, 'F3 nothing left for the public';
END $$;

-- Offers end by the event's end; nothing is offered once it is over.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,ends_at,timezone,total_tickets,tickets_sold,created_by)
VALUES ('fe100000-0000-0000-0000-0000000000e3','fe100000-0000-0000-0000-000000000001','Late Show','bff1-late','published',
        now() + interval '1 hour', now() + interval '3 hours','America/New_York',0,0,'fe100000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('fe100000-0000-0000-0000-0000000000d8','fe100000-0000-0000-0000-0000000000e3','GA',20,2,2);
INSERT INTO public.exos_waitlist(event_id,tier_id,user_id,email,quantity,status,created_at) VALUES
 ('fe100000-0000-0000-0000-0000000000e3','fe100000-0000-0000-0000-0000000000d8','fe100000-0000-0000-0000-0000000000b3','late3@bff1.test',1,'waiting',now()-interval '1 h'),
 ('fe100000-0000-0000-0000-0000000000e3','fe100000-0000-0000-0000-0000000000d8','fe100000-0000-0000-0000-0000000000b4','late4@bff1.test',1,'waiting',now());
UPDATE public.exos_ticket_tiers SET sold = 1 WHERE id = 'fe100000-0000-0000-0000-0000000000d8';
DO $$ BEGIN
  ASSERT (SELECT claim_expires_at = now() + interval '3 hours' AND voucher_id IS NOT NULL FROM public.exos_waitlist WHERE email = 'late3@bff1.test'),
    'F3 the offer ends with the event';
  ASSERT (SELECT v.valid_until FROM public.exos_waitlist w JOIN public.exos_vouchers v ON v.id = w.voucher_id WHERE w.email = 'late3@bff1.test')
         = now() + interval '3 hours', 'F3 the code ends with the event';
END $$;
UPDATE public.exos_events SET starts_at = now() - interval '5 hours', ends_at = now() - interval '1 minute'
 WHERE id = 'fe100000-0000-0000-0000-0000000000e3';
UPDATE public.exos_ticket_tiers SET sold = 0 WHERE id = 'fe100000-0000-0000-0000-0000000000d8';
DO $$ BEGIN
  ASSERT (SELECT status FROM public.exos_waitlist WHERE email = 'late4@bff1.test') = 'waiting', 'F3 no offer after the event';
END $$;

-- ---------------------------------------------------------------------------
-- F4. Reschedule one week later, doors / end sent as they were.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,ends_at,timezone,total_tickets,tickets_sold,created_by)
VALUES ('fe100000-0000-0000-0000-0000000000e4','fe100000-0000-0000-0000-000000000001','Rain Date','bff1-rain','published',
        now() + interval '20 days', now() + interval '20 days' - interval '1 hour', now() + interval '20 days 6 hours','America/New_York',0,0,
        'fe100000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,sales_start,sales_end) VALUES
  ('fe100000-0000-0000-0000-0000000000da','fe100000-0000-0000-0000-0000000000e4','GA',30,100,0, now() - interval '5 days', now() + interval '20 days' - interval '2 hours'),
  ('fe100000-0000-0000-0000-0000000000db','fe100000-0000-0000-0000-0000000000e4','Presale',20,100,0, now() - interval '9 days', now() - interval '2 days'),
  ('fe100000-0000-0000-0000-0000000000dc','fe100000-0000-0000-0000-0000000000e4','Late',40,100,0, now() + interval '15 days', NULL);
INSERT INTO public.exos_checkin_lists(id,event_id,org_id,name,valid_from,valid_until) VALUES
  ('fe100000-0000-0000-0000-00000000c444','fe100000-0000-0000-0000-0000000000e4','fe100000-0000-0000-0000-000000000001','Main',
   now() + interval '20 days' - interval '90 minutes', now() + interval '20 days 7 hours');
CREATE TEMP TABLE f4 AS SELECT e.starts_at, e.doors_at, e.ends_at,
  (SELECT sales_start FROM public.exos_ticket_tiers WHERE id = 'fe100000-0000-0000-0000-0000000000da') ga_start,
  (SELECT sales_end FROM public.exos_ticket_tiers WHERE id = 'fe100000-0000-0000-0000-0000000000da') ga_end,
  (SELECT sales_end FROM public.exos_ticket_tiers WHERE id = 'fe100000-0000-0000-0000-0000000000db') pre_end,
  (SELECT sales_start FROM public.exos_ticket_tiers WHERE id = 'fe100000-0000-0000-0000-0000000000dc') late_start,
  (SELECT valid_from FROM public.exos_checkin_lists WHERE id = 'fe100000-0000-0000-0000-00000000c444') l_from,
  (SELECT valid_until FROM public.exos_checkin_lists WHERE id = 'fe100000-0000-0000-0000-00000000c444') l_until
  FROM public.exos_events e WHERE e.id = 'fe100000-0000-0000-0000-0000000000e4';
SELECT pg_temp.act('fe100000-0000-0000-0000-0000000000a0', 'owner@bff1.test');
DO $$ BEGIN
  ASSERT pg_temp.try($q$SELECT * FROM public.exos_reschedule_event('fe100000-0000-0000-0000-0000000000e4', now() + interval '27 days',
           now() + interval '27 days' + interval '1 minute', NULL, NULL, 'rain', false, NULL)$q$) LIKE '22023%doors%', 'F4 doors after the start refused';
  ASSERT pg_temp.try($q$SELECT * FROM public.exos_reschedule_event('fe100000-0000-0000-0000-0000000000e4', now() + interval '27 days',
           NULL, now() + interval '26 days', NULL, 'rain', false, NULL)$q$) LIKE '22023%end%', 'F4 end before the start refused';
END $$;
SELECT count(*) AS rescheduled FROM public.exos_reschedule_event('fe100000-0000-0000-0000-0000000000e4', (SELECT starts_at + interval '7 days' FROM f4),
   (SELECT doors_at FROM f4), (SELECT ends_at FROM f4), NULL, 'rain', false, NULL);
DO $$ DECLARE o record; e record; BEGIN
  SELECT * INTO o FROM f4;
  SELECT * INTO e FROM public.exos_events WHERE id = 'fe100000-0000-0000-0000-0000000000e4';
  ASSERT e.starts_at = o.starts_at + interval '7 days', 'F4 start';
  ASSERT e.doors_at = o.doors_at + interval '7 days', 'F4 doors moved';
  ASSERT e.ends_at = o.ends_at + interval '7 days', 'F4 end moved';
  ASSERT (SELECT sales_end FROM public.exos_ticket_tiers WHERE id = 'fe100000-0000-0000-0000-0000000000da') = o.ga_end + interval '7 days', 'F4 GA sales end moved';
  ASSERT (SELECT sales_start FROM public.exos_ticket_tiers WHERE id = 'fe100000-0000-0000-0000-0000000000da') = o.ga_start, 'F4 open sales stay open';
  ASSERT (SELECT sales_end FROM public.exos_ticket_tiers WHERE id = 'fe100000-0000-0000-0000-0000000000db') = o.pre_end, 'F4 ended presale stays ended';
  ASSERT (SELECT sales_start FROM public.exos_ticket_tiers WHERE id = 'fe100000-0000-0000-0000-0000000000dc') = o.late_start + interval '7 days', 'F4 a later sale start moved';
  ASSERT (SELECT valid_from = o.l_from + interval '7 days' AND valid_until = o.l_until + interval '7 days'
            FROM public.exos_checkin_lists WHERE id = 'fe100000-0000-0000-0000-00000000c444'), 'F4 list window moved';
END $$;
-- New doors given: used as given.
SELECT count(*) AS rescheduled_again FROM public.exos_reschedule_event('fe100000-0000-0000-0000-0000000000e4', (SELECT starts_at + interval '8 days' FROM f4),
   (SELECT starts_at + interval '8 days' - interval '30 minutes' FROM f4), NULL, NULL, NULL, false, NULL);
DO $$ DECLARE o record; BEGIN
  SELECT * INTO o FROM f4;
  ASSERT (SELECT doors_at = o.starts_at + interval '8 days' - interval '30 minutes' AND ends_at = o.ends_at + interval '8 days'
            FROM public.exos_events WHERE id = 'fe100000-0000-0000-0000-0000000000e4'), 'F4 given doors kept, end moved';
END $$;

-- ---------------------------------------------------------------------------
-- F5. One locker left (3 in stock, 2 sold): held by fan1's cart, refused to fan2.
-- ---------------------------------------------------------------------------
UPDATE public.exos_quotas SET size = 100 WHERE id = 'fe100000-0000-0000-0000-0000000000f1';
CREATE TEMP TABLE f5(k text PRIMARY KEY, id uuid);
SELECT pg_temp.act('fe100000-0000-0000-0000-0000000000b1', 'fan1@bff1.test');
INSERT INTO f5 SELECT 'h1', public.exos_create_hold('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d1',1,1800,NULL);
SELECT pg_temp.act('fe100000-0000-0000-0000-0000000000b2', 'fan2@bff1.test');
INSERT INTO f5 SELECT 'h2', public.exos_create_hold('fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d1',1,1800,NULL);
DO $$ DECLARE h1 uuid := (SELECT id FROM f5 WHERE k = 'h1'); h2 uuid := (SELECT id FROM f5 WHERE k = 'h2'); BEGIN
  ASSERT public.exos_addon_available('fe100000-0000-0000-0000-0000000000a9') = 1, 'F5 one locker';
  PERFORM public.exos_hold_addons(h1, '[{"addon_id":"fe100000-0000-0000-0000-0000000000a9","quantity":1}]');
  ASSERT public.exos_addon_available('fe100000-0000-0000-0000-0000000000a9') = 0, 'F5 held by fan1';
  -- Re-holding the same cart doesn't count its own reservation twice.
  PERFORM public.exos_hold_addons(h1, '[{"addon_id":"fe100000-0000-0000-0000-0000000000a9","quantity":1}]');
  ASSERT pg_temp.try(format($q$SELECT public.exos_hold_addons(%L, '[{"addon_id":"fe100000-0000-0000-0000-0000000000a9","quantity":1}]')$q$, h2))
         LIKE '23514%Locker%sold out%', 'F5 fan2 refused before paying';
  ASSERT (SELECT addons IS NULL FROM public.exos_cart_holds WHERE id = h2), 'F5 nothing held for fan2';
  -- fan1's cart is released: the locker is fan2's to hold.
  UPDATE public.exos_cart_holds SET status = 'released', released_at = now() WHERE id = h1;
  ASSERT pg_temp.try(format($q$SELECT public.exos_hold_addons(%L, '[{"addon_id":"fe100000-0000-0000-0000-0000000000a9","quantity":1}]')$q$, h2)) = 'ok',
    'F5 fan2 holds it after the release';
  ASSERT pg_temp.try(format($q$SELECT public.exos_hold_addons(%L, '[{"addon_id":"fe100000-0000-0000-0000-0000000000a9","quantity":1}]')$q$, h1))
         LIKE '23514%ran out%', 'F5 a released hold can''t reserve';
END $$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  ASSERT pg_temp.try($q$SELECT public.exos_hold_addons(gen_random_uuid(), '[]')$q$) LIKE '42501%', 'F5 service role only';
END $$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- F6. fan1 pays 4 presale @40 + a locker @10, 8.875% exclusive: ticket all-in
--     4355, locker all-in 1089. price_paid and the refund share are 43.55.
-- ---------------------------------------------------------------------------
UPDATE public.exos_cart_holds SET status = 'released' WHERE status = 'active';
UPDATE public.exos_event_addons SET sold = 0 WHERE id = 'fe100000-0000-0000-0000-0000000000a9';
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,addons,tax_cents,payment_intent,currency)
VALUES ('cs_f6a','fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d3','fe100000-0000-0000-0000-000000000001',
        'fe100000-0000-0000-0000-0000000000b4','fan4@bff1.test',4,4*4355+1089,'pending',
        '[{"addon_id":"fe100000-0000-0000-0000-0000000000a9","quantity":1,"unit_price_cents":1000,"name":"Locker"}]',4*355+89,'pi_cs_f6a','usd'),
       ('cs_f6b','fe100000-0000-0000-0000-0000000000e1','fe100000-0000-0000-0000-0000000000d3','fe100000-0000-0000-0000-000000000001',
        'fe100000-0000-0000-0000-0000000000b5','fan5@bff1.test',2,2*4355+1089,'pending',
        '[{"addon_id":"fe100000-0000-0000-0000-0000000000a9","quantity":1,"unit_price_cents":1000,"unit_all_in_cents":1089,"name":"Locker"}]',2*355+89,'pi_cs_f6b','usd');
SELECT cardinality(public.exos_fulfill_checkout('cs_f6a')) AS f6a, cardinality(public.exos_fulfill_checkout('cs_f6b')) AS f6b;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_f6a' AND price_paid = 43.55) = 4, 'F6 price_paid without the locker''s tax';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_f6b' AND price_paid = 43.55) = 2, 'F6 with the session''s all-in price';
  ASSERT (SELECT bool_and(share_cents = 4355) FROM public.exos_refund_ticket_state('cs_f6a')), 'F6 refund share is the ticket''s all-in price';
  ASSERT public._exos_addon_all_in_cents('fe100000-0000-0000-0000-0000000000a9', 1000) = 1089, 'F6 all-in add-on price';
END $$;

SELECT '*** festival p1: ALL ASSERTIONS PASSED ***' AS result;
ROLLBACK;
