-- ============================================================================
-- Marketplace orders that need a person (mig 20260929051000). Self-contained
-- (5b prefix), rolled back at the end.
--   A1 an order entering needs_attention mails the org's owner and active
--      managers (not finance, not a disabled manager), escaped, once per
--      order + reason: the poller's retries don't mail again
--   A2 mark handled: owner/manager only, only while it needs attention;
--      records who/when; a handled order is no longer retried
--   A3 resend claim links: owner/manager only, needs a buyer email and
--      pending transfers; one mail with a keyed link per unclaimed ticket;
--      at most once per 10 minutes
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_marketplace_attention.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5b000000-0000-0000-0000-0000000000a0','5b-owner@x.com',now()),
  ('5b000000-0000-0000-0000-0000000000a1','5b-manager@x.com',now()),
  ('5b000000-0000-0000-0000-0000000000a2','5b-finance@x.com',now()),
  ('5b000000-0000-0000-0000-0000000000a3','5b-gone@x.com',now()),
  ('5b000000-0000-0000-0000-0000000000a4','5b-outsider@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5b000000-0000-0000-0000-000000000001','5B Org','5b-org','5b000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('5b000000-0000-0000-0000-000000000001','5b000000-0000-0000-0000-0000000000a0','owner',false),
  ('5b000000-0000-0000-0000-000000000001','5b000000-0000-0000-0000-0000000000a1','manager',false),
  ('5b000000-0000-0000-0000-000000000001','5b000000-0000-0000-0000-0000000000a2','finance',false),
  ('5b000000-0000-0000-0000-000000000001','5b000000-0000-0000-0000-0000000000a3','manager',true);
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  ('5b000000-0000-0000-0000-0000000000e1','5b000000-0000-0000-0000-000000000001','<b>Alert</b> & Show','published','2027-01-01T02:00:00Z','Hall',100,0,ARRAY['stubhub']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('5b000000-0000-0000-0000-0000000000d1','5b000000-0000-0000-0000-0000000000e1','GA',50,20,0);
SELECT public.exos_set_channel_allocation('5b000000-0000-0000-0000-0000000000e1','stubhub','5b000000-0000-0000-0000-0000000000d1',10);

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.sale(p_id text, p_email text) RETURNS uuid LANGUAGE sql AS $$
  SELECT order_id FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','stubhub','external_order_id', p_id,
    'external_listing_id', (SELECT id::text FROM public.exos_distribution_listings
                             WHERE event_id = '5b000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub' AND tier_id IS NOT NULL),
    'quantity',2,'sale_status','confirmed','buyer_email', p_email));
$$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text, text) TO authenticated;

-- A1 -------------------------------------------------------------------------
DO $$
DECLARE o uuid; f record; n int; h text;
BEGIN
  o := pg_temp.sale('5b-1', NULL);
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(o, 'https://exos.example.test');
  IF f.status <> 'needs_attention' THEN RAISE EXCEPTION 'A1 FAIL: %', row_to_json(f); END IF;
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'marketplace-attention';
  IF n <> 2 OR NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'marketplace-attention' AND to_email = '5b-owner@x.com')
     OR NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'marketplace-attention' AND to_email = '5b-manager@x.com') THEN
    RAISE EXCEPTION 'A1 FAIL: recipients (% mails: %)', n, (SELECT string_agg(to_email, ',') FROM public.exos_mail WHERE template = 'marketplace-attention');
  END IF;
  SELECT html INTO h FROM public.exos_mail WHERE template = 'marketplace-attention' LIMIT 1;
  IF h LIKE '%<b>Alert</b>%' OR h NOT LIKE '%&lt;b&gt;Alert&lt;/b&gt; &amp; Show%' OR h NOT LIKE '%no buyer email%'
     OR h NOT LIKE '%{{app_url}}/edit-event/5b000000-0000-0000-0000-0000000000e1%' THEN
    RAISE EXCEPTION 'A1 FAIL: body %', h;
  END IF;
  -- The poller re-reports it: reset to received, parked again, same reason: no new mail.
  PERFORM pg_temp.sale('5b-1', NULL);
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(o, 'https://exos.example.test');
  IF f.status <> 'needs_attention' OR (SELECT count(*) FROM public.exos_mail WHERE template = 'marketplace-attention') <> 2 THEN
    RAISE EXCEPTION 'A1 FAIL: retry mailed again';
  END IF;
  RAISE NOTICE 'A1 ok: owner + active manager alerted once, body escaped, retries silent';
END $$;

-- A2 -------------------------------------------------------------------------
SELECT pg_temp.as_user('5b000000-0000-0000-0000-0000000000a2', '5b-finance@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_mark_marketplace_order_handled(
      (SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = '5b-1'), 'finance tries');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  IF NOT refused THEN RAISE EXCEPTION 'A2 FAIL: finance marked it handled'; END IF;
END $$;
RESET ROLE;
SELECT pg_temp.as_user('5b000000-0000-0000-0000-0000000000a1', '5b-manager@x.com');
SET LOCAL ROLE authenticated;
SELECT public.exos_mark_marketplace_order_handled(
  (SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = '5b-1'), 'delivered by hand');
RESET ROLE;
DO $$
DECLARE o public.exos_marketplace_orders%ROWTYPE; f record; bad boolean := false;
BEGIN
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = '5b-1';
  IF o.handled_at IS NULL OR o.handled_by <> '5b000000-0000-0000-0000-0000000000a1'
     OR o.handled_note <> 'delivered by hand' OR o.handled_reason IS DISTINCT FROM o.attention_reason THEN
    RAISE EXCEPTION 'A2 FAIL: not recorded %', row_to_json(o);
  END IF;
  -- The marketplace now sends an email: a handled order is not retried (no second set of tickets).
  PERFORM pg_temp.sale('5b-1', 'late@x.com');
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(o.id, 'https://exos.example.test');
  IF f.status <> 'needs_attention' OR EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'stubhub:5b-1') THEN
    RAISE EXCEPTION 'A2 FAIL: handled order retried %', row_to_json(f);
  END IF;
  -- Only an order that needs attention.
  PERFORM pg_temp.as_user('5b000000-0000-0000-0000-0000000000a0', '5b-owner@x.com');
  BEGIN
    PERFORM public.exos_mark_marketplace_order_handled(pg_temp.sale('5b-9', 'x9@x.com'), NULL);
  EXCEPTION WHEN others THEN bad := SQLERRM LIKE '%only an order that needs attention%';
  END;
  IF NOT bad THEN RAISE EXCEPTION 'A2 FAIL: a received order was marked handled'; END IF;
  RAISE NOTICE 'A2 ok: manager marks handled (finance cannot); who/when kept; handled orders are not retried';
END $$;

-- A3 -------------------------------------------------------------------------
DO $$
DECLARE o uuid; f record;
BEGIN
  o := pg_temp.sale('5b-2', 'buyer2@x.com');
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(o, 'https://exos.example.test');
  IF f.status <> 'fulfilled' THEN RAISE EXCEPTION 'A3 FAIL: setup %', row_to_json(f); END IF;
  PERFORM set_config('test.o2', o::text, true);
  PERFORM set_config('test.o1', pg_temp.sale('5b-3', NULL)::text, true);
END $$;
SELECT pg_temp.as_user('5b000000-0000-0000-0000-0000000000a4', '5b-outsider@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_resend_marketplace_claim_links(current_setting('test.o2')::uuid);
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  IF NOT refused THEN RAISE EXCEPTION 'A3 FAIL: an outsider resent links'; END IF;
END $$;
RESET ROLE;
SELECT pg_temp.as_user('5b000000-0000-0000-0000-0000000000a0', '5b-owner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int; h text; e text;
BEGIN
  n := public.exos_resend_marketplace_claim_links(current_setting('test.o2')::uuid);
  IF n <> 2 THEN RAISE EXCEPTION 'A3 FAIL: resent % links', n; END IF;
  BEGIN
    PERFORM public.exos_resend_marketplace_claim_links(current_setting('test.o2')::uuid);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e NOT LIKE '%a few minutes ago%' THEN RAISE EXCEPTION 'A3 FAIL: no rate limit (%)', e; END IF;
  e := NULL;
  BEGIN
    PERFORM public.exos_resend_marketplace_claim_links(current_setting('test.o1')::uuid);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e NOT LIKE '%no buyer email%' THEN RAISE EXCEPTION 'A3 FAIL: resend without an email (%)', e; END IF;
END $$;
RESET ROLE;
DO $$
DECLARE h text; o public.exos_marketplace_orders%ROWTYPE;
BEGIN
  SELECT html INTO h FROM public.exos_mail WHERE to_email = 'buyer2@x.com' AND subject LIKE '%(links again)';
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = '5b-2';
  IF h IS NULL OR h NOT LIKE '%{{app_url}}/claim/' || o.transfer_ids[1] || '?k=%'
     OR h NOT LIKE '%{{app_url}}/claim/' || o.transfer_ids[2] || '?k=%' THEN
    RAISE EXCEPTION 'A3 FAIL: body %', h;
  END IF;
  IF o.links_resent_by <> '5b000000-0000-0000-0000-0000000000a0' OR o.links_resent_at IS NULL THEN
    RAISE EXCEPTION 'A3 FAIL: resend not recorded';
  END IF;
  -- Once claimed, a ticket's link isn't resent.
  UPDATE public.exos_transfers SET status = 'completed' WHERE id = o.transfer_ids[1];
  UPDATE public.exos_marketplace_orders SET links_resent_at = now() - interval '1 hour' WHERE id = o.id;
  PERFORM pg_temp.as_user('5b000000-0000-0000-0000-0000000000a1', '5b-manager@x.com');
  IF public.exos_resend_marketplace_claim_links(o.id) <> 1 THEN RAISE EXCEPTION 'A3 FAIL: claimed link resent'; END IF;
  RAISE NOTICE 'A3 ok: owner/manager resend keyed links for unclaimed tickets only; rate-limited; needs a buyer email';
END $$;

ROLLBACK;
