-- ============================================================================
-- Helpers and the invariants of the end-to-end simulation, shared by
-- tests/exos/sim_full.sql (\ir) and tests/exos/race_full.sh (\i). The caller
-- defines pg_temp.u(text) -> uuid first (its id namespace): the org is
-- u('A'), the other org u('B'), its events u('e1') / u('e2'), and the users
-- u('oa') owner, u('fa') finance of A and u('ob') owner of B, with emails
-- e2?-<user>@x.com. Session-local (pg_temp); nothing here writes data.
-- ============================================================================
-- Sign in (app.uid / app.jwt are the harness's auth.uid() / auth.jwt()).
CREATE FUNCTION pg_temp.act(p_who text) RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  SELECT set_config('app.uid', coalesce(pg_temp.u(p_who)::text, ''), true),
         set_config('app.jwt', coalesce((SELECT jsonb_build_object('email', email)::text FROM auth.users WHERE id = pg_temp.u(p_who)), ''), true)
$$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
CREATE TEMP TABLE e2e (k text PRIMARY KEY, v text);
GRANT ALL ON e2e TO PUBLIC;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM e2e WHERE k = p_k $$;
CREATE FUNCTION pg_temp.put(p_k text, p_v text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO e2e VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v
$$;
-- exos-checkout's session row (status pending), with the fee record it
-- computes: application fee = Exos fee + card-fee estimate.
CREATE FUNCTION pg_temp.sess(p_sid text, p_event text, p_tier text, p_buyer text, p_email text, p_qty int, p_cents int,
                             p_app int, p_exos int, p_addons jsonb DEFAULT NULL, p_promoter text DEFAULT NULL,
                             p_step uuid DEFAULT NULL, p_slot text DEFAULT NULL, p_gift int DEFAULT 0, p_tax int DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, guest, quantity,
              amount_cents, currency, status, addons, promoter_id, price_step_id, slot_id, gift_card_cents, tax_cents,
              application_fee_cents, exos_fee_cents, card_fee_est_cents, fee_bps, fee_free, processor, provider_expires_at)
  VALUES (p_sid, pg_temp.u(p_event), pg_temp.u(p_tier), pg_temp.u('A'), CASE WHEN p_buyer IS NULL THEN NULL ELSE pg_temp.u(p_buyer) END,
          p_email, p_buyer IS NULL, p_qty, p_cents, 'usd', 'pending', p_addons, p_promoter, p_step, p_slot, p_gift, p_tax,
          p_app, p_exos, p_app - p_exos, 250, false, 'stripe', now() + interval '30 minutes')
$$;
-- Stripe-shaped ids for an order: pi_…, ch_…, evt_… (alphanumeric).
CREATE FUNCTION pg_temp.sid(p_prefix text, p_sid text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT p_prefix || '_' || substr(md5(p_sid), 1, 24)
$$;
-- stripe-webhook's checkout.session.completed (paid): fulfil, the PI on the
-- session, the payment ledger row.
CREATE FUNCTION pg_temp.paid(p_sid text) RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE v uuid[];
BEGIN
  v := public.exos_fulfill_checkout(p_sid);
  UPDATE public.exos_checkout_sessions SET payment_intent = pg_temp.sid('pi', p_sid) WHERE session_id = p_sid;
  PERFORM public.exos_record_payment(p_sid, pg_temp.sid('pi', p_sid),
            (SELECT amount_cents FROM public.exos_checkout_sessions WHERE session_id = p_sid), 'succeeded',
            pg_temp.sid('ch', p_sid), 'usd', NULL, pg_temp.sid('evt', p_sid));
  RETURN v;
END $$;
-- The app's rotating add-on pass code (A-...) for the door.
CREATE FUNCTION pg_temp.acode(p_pass uuid) RETURNS text LANGUAGE sql AS $$
  SELECT 'A-' || p.id || ':' || p.owner_id || ':' || b || ':' || public._exos_door_code_mac(p.id, p.owner_id, b, p.barcode_secret)
    FROM public.exos_addon_passes p, (SELECT floor(extract(epoch FROM now()) * 1000 / 30000)::bigint AS b) x
   WHERE p.id = p_pass
$$;
-- Fire the deferred journal and gift card checks now (they run at COMMIT;
-- this file rolls back), then defer them again.
CREATE FUNCTION pg_temp.commit_point() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  SET CONSTRAINTS exos_gift_card_ledger_journal IMMEDIATE;
  SET CONSTRAINTS exos_gift_card_ledger_journal DEFERRED;
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced IMMEDIATE;
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced DEFERRED;
END $$;

-- The invariants ---------------------------------------------------------------
-- Called as the session user (postgres = the service role here) between
-- steps. p_audit: the action:actor_kind of every audit row the step should
-- have written, in any order.
CREATE FUNCTION pg_temp.check_invariants(p_step text, p_audit text[] DEFAULT '{}') RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r record; n int; m int;
  v_uid text := current_setting('app.uid', true);
  v_jwt text := current_setting('app.jwt', true);
  v_mark bigint := coalesce(pg_temp.v('audit_mark')::bigint, 0);
  v_top bigint;
  v_got text[]; v_exp text[];
  v_orgs uuid[] := ARRAY[pg_temp.u('A'), pg_temp.u('B')];
  v_t text;
  v_email_re text := '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}';
  v_phones text[] := ARRAY['5550176', '5550177', '555-0176', '555-0177', '(212)', '+1212'];
BEGIN
  IF current_user <> session_user THEN
    RAISE EXCEPTION '%: check_invariants runs as the session user, not %', p_step, current_user;
  END IF;
  -- I2 (part): the deferred constraint triggers, now.
  PERFORM pg_temp.commit_point();

  -- I1 the trial balance: zero per org and currency, on every org in the database.
  FOR r IN SELECT e.org_id, e.currency, sum(l.debit_cents - l.credit_cents) AS d
             FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
            GROUP BY 1, 2 HAVING sum(l.debit_cents - l.credit_cents) <> 0 LOOP
    RAISE EXCEPTION '% I1: trial balance of org % (%) is %', p_step, r.org_id, r.currency, r.d;
  END LOOP;
  -- ... and through the reader the finance member uses (RLS, the chart join).
  PERFORM pg_temp.act('fa');
  SET LOCAL ROLE authenticated;
  FOR r IN SELECT currency, sum(balance_cents) AS b, sum(debit_cents) AS dr, sum(credit_cents) AS cr
             FROM public.exos_journal_trial_balance(pg_temp.u('A')) GROUP BY currency LOOP
    IF r.b <> 0 OR r.dr <> r.cr THEN
      RESET ROLE;
      RAISE EXCEPTION '% I1: exos_journal_trial_balance(A) % is % (debits %, credits %)', p_step, r.currency, r.b, r.dr, r.cr;
    END IF;
  END LOOP;
  SELECT count(*) INTO n FROM public.exos_journal_lines WHERE org_id = pg_temp.u('A');
  RESET ROLE;
  SELECT count(*) INTO m FROM public.exos_journal_lines WHERE org_id = pg_temp.u('A');
  IF n <> m THEN
    RAISE EXCEPTION '% I1: finance reads % of org A''s % journal lines', p_step, n, m;
  END IF;
  SELECT count(*) INTO n FROM public.exos_journal_lines l WHERE l.org_id = pg_temp.u('A')
     AND NOT EXISTS (SELECT 1 FROM public.exos_journal_accounts() a WHERE a.code = l.account);
  IF n > 0 THEN
    RAISE EXCEPTION '% I1: % journal lines on an account the chart (and the trial balance) doesn''t list', p_step, n;
  END IF;

  -- I2 every entry balances.
  FOR r IN SELECT e.id, e.kind, e.source_table, e.total_cents, count(l.id) AS nl,
                  coalesce(sum(l.debit_cents), 0) AS dr, coalesce(sum(l.credit_cents), 0) AS cr
             FROM public.exos_journal_entries e LEFT JOIN public.exos_journal_lines l ON l.entry_id = e.id
            WHERE e.org_id = ANY (v_orgs)
            GROUP BY e.id, e.kind, e.source_table, e.total_cents
           HAVING count(l.id) < 2 OR coalesce(sum(l.debit_cents), 0) <> coalesce(sum(l.credit_cents), 0)
               OR coalesce(sum(l.debit_cents), 0) <> e.total_cents LOOP
    RAISE EXCEPTION '% I2: entry % (% %) does not balance: % lines, Dr %, Cr %, total %', p_step, r.id, r.source_table, r.kind,
      r.nl, r.dr, r.cr, r.total_cents;
  END LOOP;

  -- I3 sold = live tickets per tier; tickets_sold = the tiers' sold; pools within their size.
  FOR r IN SELECT t.id, t.name, t.sold,
                  (SELECT count(*) FROM public.exos_tickets k WHERE k.tier_id = t.id AND k.status IN ('active', 'used')) AS live
             FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
            WHERE e.org_id = ANY (v_orgs) LOOP
    IF r.sold <> r.live THEN
      RAISE EXCEPTION '% I3: tier % sold % but % live tickets', p_step, r.name, r.sold, r.live;
    END IF;
  END LOOP;
  FOR r IN SELECT e.name, e.tickets_sold, (SELECT coalesce(sum(t.sold), 0) FROM public.exos_ticket_tiers t WHERE t.event_id = e.id) AS s
             FROM public.exos_events e WHERE e.org_id = ANY (v_orgs) LOOP
    IF r.tickets_sold <> r.s THEN
      RAISE EXCEPTION '% I3: event % tickets_sold % but its tiers sold %', p_step, r.name, r.tickets_sold, r.s;
    END IF;
  END LOOP;
  -- A pool's usage: its tickets (_exos_quota_used) plus the live carts on its types.
  FOR r IN SELECT q.name, q.size, public._exos_quota_used(q.id) AS used,
                  (SELECT coalesce(sum(h.quantity), 0) FROM public.exos_cart_holds h JOIN public.exos_quota_tiers qt ON qt.tier_id = h.tier_id
                    WHERE qt.quota_id = q.id AND h.status = 'active' AND h.expires_at > now()) AS held
             FROM public.exos_quotas q WHERE q.org_id = ANY (v_orgs) LOOP
    IF r.used + r.held > r.size THEN
      RAISE EXCEPTION '% I3: pool % (size %) uses % tickets + % held', p_step, r.name, r.size, r.used, r.held;
    END IF;
  END LOOP;

  -- I4 no ticket without an order record.
  FOR r IN SELECT k.id, k.order_ref, k.channel_source, k.status, k.buyer_email IS NULL AS no_email
             FROM public.exos_tickets k
            WHERE k.org_id = ANY (v_orgs)
              AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions s WHERE s.session_id = k.order_ref)
              AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions s WHERE s.free_kind IS NOT NULL AND k.id = ANY (s.ticket_ids))
              AND NOT (k.order_ref LIKE 'po:%' AND EXISTS (SELECT 1 FROM public.exos_partner_reservations p WHERE 'po:' || p.id = k.order_ref))
              AND NOT (k.order_ref LIKE 'pos:%' AND EXISTS (SELECT 1 FROM public.exos_pos_orders o WHERE 'pos:' || o.id = k.order_ref)) LOOP
    -- The journal migration's exemptions: a marketplace channel (its own
    -- record), a phone-only RSVP (nobody to record the order for).
    CONTINUE WHEN NOT (lower(btrim(coalesce(r.channel_source, ''))) IN ('', 'vibepass', 'boxoffice', 'comp', 'referral_reward', 'stripe', 'door', 'pos')
                       OR lower(coalesce(r.channel_source, '')) LIKE 'link:%');
    CONTINUE WHEN r.order_ref LIKE 'rsvp:%' AND r.no_email
              AND EXISTS (SELECT 1 FROM public.exos_phone_rsvps p WHERE 'rsvp:' || p.id = r.order_ref AND p.email IS NULL);
    RAISE EXCEPTION '% I4: ticket % (order_ref %, channel %, %) has no order record', p_step, r.id, r.order_ref, r.channel_source, r.status;
  END LOOP;

  -- I5 journal = settlement.ts per event (exos_order_money, the $0 orders left out).
  FOR r IN
    WITH o AS (
      SELECT m.event_id, m.gross_cents, m.refunded_cents, m.organizer_net_cents, coalesce(s.gift_card_cents, 0) AS gift
        FROM public.exos_order_money m JOIN public.exos_checkout_sessions s ON s.session_id = m.session_id
       WHERE m.org_id = pg_temp.u('A') AND m.status IN ('fulfilled', 'partially_refunded', 'refunded') AND s.free_kind IS NULL),
    st AS (
      SELECT event_id, sum(gross_cents) AS gross, sum(gift) AS gift, sum(refunded_cents) AS refunded,
             sum(CASE WHEN organizer_net_cents IS NULL THEN 0
                      WHEN gross_cents <= 0 OR refunded_cents = 0 THEN organizer_net_cents
                      ELSE organizer_net_cents - round(organizer_net_cents::numeric
                                                       * least(greatest(refunded_cents, 0), greatest(gross_cents, 0)) / gross_cents) END) AS net_after
        FROM o GROUP BY event_id),
    jl AS (
      SELECT e.event_id,
             sum(CASE WHEN e.source_table = 'exos_checkout_sessions' AND l.account IN ('ticket_revenue', 'buyer_fees', 'sales_tax_payable', 'donations')
                      THEN l.credit_cents - l.debit_cents ELSE 0 END) AS gross,
             sum(CASE WHEN l.account IN ('stripe_clearing', 'paypal_receivable') THEN l.debit_cents - l.credit_cents ELSE 0 END) AS net_after
        FROM public.exos_journal_entries e JOIN public.exos_journal_lines l ON l.entry_id = e.id
       WHERE e.org_id = pg_temp.u('A') AND e.source_table IN ('exos_checkout_sessions', 'exos_order_refunds')
       GROUP BY e.event_id),
    jr AS (
      SELECT e.event_id, sum(e.basis_cents) AS refunded FROM public.exos_journal_entries e
       WHERE e.org_id = pg_temp.u('A') AND e.source_table = 'exos_order_refunds' GROUP BY e.event_id)
    SELECT ev.name, coalesce(st.gross, 0) + coalesce(st.gift, 0) AS s_gross, coalesce(jl.gross, 0) AS j_gross,
           coalesce(st.refunded, 0) AS s_ref, coalesce(jr.refunded, 0) AS j_ref,
           coalesce(st.net_after, 0) AS s_net, coalesce(jl.net_after, 0) AS j_net
      FROM public.exos_events ev
      LEFT JOIN st ON st.event_id = ev.id LEFT JOIN jl ON jl.event_id = ev.id LEFT JOIN jr ON jr.event_id = ev.id
     WHERE ev.org_id = pg_temp.u('A')
  LOOP
    IF r.s_gross <> r.j_gross OR r.s_ref <> r.j_ref OR r.s_net <> r.j_net THEN
      RAISE EXCEPTION '% I5: event % settlement (gross+gift %, refunded %, net after refunds %) <> journal (%, %, %)', p_step, r.name,
        r.s_gross, r.s_ref, r.s_net, r.j_gross, r.j_ref, r.j_net;
    END IF;
  END LOOP;

  -- I5b promoter commissions: the journal's expense per event = settlement.ts's
  -- commissions.accruedCents (every row but the reversed ones).
  FOR r IN SELECT ev.name,
                  coalesce((SELECT sum(c.commission_cents) FROM public.exos_promoter_commissions c
                             WHERE c.event_id = ev.id AND c.status <> 'reversed'), 0) AS s_acc,
                  coalesce((SELECT sum(l.debit_cents - l.credit_cents) FROM public.exos_journal_lines l
                              JOIN public.exos_journal_entries e ON e.id = l.entry_id
                             WHERE e.event_id = ev.id AND l.account = 'promoter_commissions'), 0) AS j_acc
             FROM public.exos_events ev WHERE ev.org_id = pg_temp.u('A') LOOP
    IF r.s_acc <> r.j_acc THEN
      RAISE EXCEPTION '% I5: event % commissions: settlement % <> journal %', p_step, r.name, r.s_acc, r.j_acc;
    END IF;
  END LOOP;

  -- I6 the step's audit rows: exactly the expected action:actor_kind multiset.
  SELECT coalesce(max(id), 0) INTO v_top FROM public.exos_org_audit;
  SELECT coalesce(array_agg(a.action || ':' || a.actor_kind ORDER BY a.action || ':' || a.actor_kind), '{}') INTO v_got
    FROM public.exos_org_audit a WHERE a.id > v_mark AND a.org_id = ANY (v_orgs);
  SELECT coalesce(array_agg(x ORDER BY x), '{}') INTO v_exp FROM unnest(p_audit) x;
  IF v_got IS DISTINCT FROM v_exp THEN
    RAISE EXCEPTION '% I6: audit rows % <> expected %: %', p_step, v_got, v_exp,
      (SELECT string_agg(a.action || ' ' || a.actor_kind || ' ' || coalesce(a.actor_role, '-') || ' ' || a.source || ' ' || a.changes::text
                         || coalesce(' ' || a.amount_cents, ''), '; ' ORDER BY a.id)
         FROM public.exos_org_audit a WHERE a.id > v_mark AND a.org_id = ANY (v_orgs));
  END IF;
  PERFORM pg_temp.put('audit_n', cardinality(v_got)::text);
  PERFORM pg_temp.put('audit_mark', v_top::text);

  -- I7 no email or phone in an audit row or a journal memo.
  SELECT count(*) INTO n FROM public.exos_org_audit a
   WHERE a.org_id = ANY (v_orgs)
     AND (row_to_json(a)::text ~ v_email_re
          OR EXISTS (SELECT 1 FROM unnest(v_phones) ph WHERE position(ph IN row_to_json(a)::text) > 0));
  IF n > 0 THEN
    RAISE EXCEPTION '% I7: % audit rows hold an email or a phone', p_step, n;
  END IF;
  SELECT count(*) INTO n FROM public.exos_journal_entries e LEFT JOIN public.exos_journal_lines l ON l.entry_id = e.id
   WHERE e.org_id = ANY (v_orgs)
     AND (coalesce(e.memo, '') || ' ' || coalesce(l.memo, '') ~ v_email_re
          OR EXISTS (SELECT 1 FROM unnest(v_phones) ph WHERE position(ph IN coalesce(e.memo, '') || ' ' || coalesce(l.memo, '')) > 0));
  IF n > 0 THEN
    RAISE EXCEPTION '% I7: % journal memos hold an email or a phone', p_step, n;
  END IF;

  -- I8 org B's owner sees none of org A through RLS beyond what anyone sees
  -- (published events and their public types are a public catalog): per
  -- table, what the owner of B reads of org A = what anon reads of it.
  FOREACH v_t IN ARRAY ARRAY['exos_events', 'exos_ticket_tiers', 'exos_checkout_sessions', 'exos_order_money', 'exos_tickets',
                             'exos_journal_entries', 'exos_journal_lines', 'exos_journal_rows', 'exos_org_audit', 'exos_pos_orders',
                             'exos_pos_payments', 'exos_pos_drawer_sessions', 'exos_gift_cards', 'exos_gift_card_ledger',
                             'exos_disputes', 'exos_promoter_commissions', 'exos_promoters', 'exos_question_answers',
                             'exos_partner_reservations', 'exos_order_refunds', 'exos_refund_requests', 'exos_group_buys',
                             'exos_order_addons', 'exos_addon_passes', 'exos_fee_adjustments', 'exos_org_instant_payouts',
                             'exos_quotas', 'exos_price_steps', 'exos_event_questions', 'exos_api_keys', 'exos_pos_question_skips',
                             'exos_addon_pass_undos', 'exos_phone_rsvps', 'exos_cart_holds', 'exos_transfers'] LOOP
    IF to_regclass('public.' || v_t) IS NULL THEN CONTINUE; END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = v_t AND column_name = 'org_id') THEN
      v_got := ARRAY[format('SELECT count(*) FROM public.%I WHERE org_id = %L', v_t, pg_temp.u('A'))];
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = v_t AND column_name = 'event_id') THEN
      v_got := ARRAY[format('SELECT count(*) FROM public.%I WHERE event_id IN (%L, %L)', v_t, pg_temp.u('e1'), pg_temp.u('e2'))];
    ELSE
      CONTINUE;
    END IF;
    PERFORM pg_temp.act('ob');
    SET LOCAL ROLE authenticated;
    BEGIN
      EXECUTE v_got[1] INTO n;
    EXCEPTION WHEN insufficient_privilege THEN
      n := 0;   -- no grant at all: sees nothing
    END;
    RESET ROLE;
    PERFORM set_config('app.uid', '', true), set_config('app.jwt', '', true);
    SET LOCAL ROLE anon;
    BEGIN
      EXECUTE v_got[1] INTO m;
    EXCEPTION WHEN insufficient_privilege THEN
      m := 0;
    END;
    RESET ROLE;
    IF n > m THEN
      RAISE EXCEPTION '% I8: org B''s owner reads % rows of org A in % (anyone reads %)', p_step, n, v_t, m;
    END IF;
  END LOOP;
  PERFORM pg_temp.act('ob');
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_checkout_sessions WHERE org_id = pg_temp.u('B');
  IF n = 0 THEN
    RESET ROLE;
    RAISE EXCEPTION '% I8: org B''s owner reads none of their own orders (the check proves nothing)', p_step;
  END IF;
  v_t := pg_temp.st(format('SELECT public.exos_journal_trial_balance(%L)', pg_temp.u('A')));
  IF v_t NOT LIKE '42501%' THEN
    RESET ROLE;
    RAISE EXCEPTION '% I8: org B''s owner read org A''s trial balance: %', p_step, v_t;
  END IF;
  v_t := pg_temp.st(format('SELECT public.exos_org_audit_list(%L)', pg_temp.u('A')));
  IF v_t NOT LIKE '42501%' THEN
    RESET ROLE;
    RAISE EXCEPTION '% I8: org B''s owner read org A''s audit log: %', p_step, v_t;
  END IF;
  RESET ROLE;

  -- I9 gift cards outstanding = the cards' balances (holds count as spent).
  SELECT coalesce(-sum(l.debit_cents - l.credit_cents), 0) INTO n
    FROM public.exos_journal_lines l WHERE l.org_id = pg_temp.u('A') AND l.account = 'gift_cards_outstanding';
  SELECT coalesce(sum(balance_cents), 0) INTO m FROM public.exos_gift_cards WHERE org_id = pg_temp.u('A');
  IF n <> m + coalesce((SELECT sum(r2.amount_cents - r2.refunded_cents) FROM public.exos_gift_card_redemptions r2
                        WHERE r2.org_id = pg_temp.u('A') AND r2.status = 'held'), 0) THEN
    RAISE EXCEPTION '% I9: gift cards outstanding % <> balances %', p_step, n, m;
  END IF;

  PERFORM set_config('app.uid', coalesce(v_uid, ''), true), set_config('app.jwt', coalesce(v_jwt, ''), true);
  RAISE NOTICE 'OK  % (invariants I1-I9 hold; % audit rows)', p_step, pg_temp.v('audit_n');
END $$;

