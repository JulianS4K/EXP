-- ============================================================================
-- Migration 20261107120000 — Exos: partner reservations take a price step
--                             and lock shared pools in one order
--
-- Branch:   claude/exos-partner-steps (the two leftovers of #96: shared
--           capacity + price steps)
-- Touches:  W: FUNCTION _exos_partner_reserve (patched in place, markers
--              'exos: partner step var', 'exos: partner step lock',
--              'exos: partner price step', 'exos: partner hold step')
--           W: FUNCTION _exos_partner_reservation_complete (patched in place,
--              markers 'exos: partner pool lock order',
--              'exos: partner price step', 'exos: partner price step value')
--           R: exos_tier_current_price, exos_price_steps, exos_cart_holds
--              (price_step_id / unit_price_cents, mig 20261106130000)
-- Callers:  exos-api: the partner contract (POST /public/events/:id/
--           ticket_reservations, .../complete, comps) and the organizer
--           reservations (/v1/events/:id/organizer-reservations, /build,
--           /:token/complete). Both run the same SQL core.
-- Pre-reqs: 20261031130000 (partner sales), 20261104130000 / 20261104180000 /
--           20261104200000 (its later patches), 20261105100000 (cap0 closed
--           in complete), 20261106120000 (pool lock order), 20261106130000
--           (price steps).
--
-- 1. A reservation is a checkout hold for price steps (mig 20261106130000).
--    Before this, a partner or organizer reservation priced each line at the
--    current step but did not hold the step: its cart holds had no
--    price_step_id, so they didn't count against the step's places, and the
--    tickets got a step only at mint, from the exos_tickets_price_step trigger
--    (the CURRENT step then, not the one the partner was quoted). A partner
--    could reserve 10 at the early-bird price with 2 early birds left, and
--    the early-bird count could be oversold by a checkout in between.
--    Now, for a paid line (not a comp):
--      * reserve locks the type's steps (the lock exos_hold_lock_price and
--        exos_set_price_steps take) after the pools and the types, reads the
--        current step under it and, when the step ends on a count and the
--        line asks for more than it has left, refuses with XP410
--        price_step_remaining (exos-api: 409, reason price_step_remaining,
--        with remaining / price_cents / ticket_type_id). Boundary rule CAP,
--        as checkout: one step per line, the partner reserves what's left
--        and the rest at the next price. The /build dry run answers the same.
--      * the line records price_step_id, and every cart hold of the line
--        carries price_step_id + unit_price_cents, so the reservation counts
--        against the step like a locked checkout hold
--        (_exos_price_step_used). Expiry (the holds stop counting at
--        expires_at; the sweep marks them) and cancellation (the holds are
--        released) give the places back with no further change.
--      * complete mints at the locked price (the line's all-in price, as
--        before) and stamps each ticket with the hold's step, so a step that
--        advanced mid-reservation (its time passed, or the organizer re-saved
--        the steps) doesn't move the ticket to the new step. A reservation
--        made before this migration has no step on its holds: its tickets
--        still get one from the trigger.
--    Comps (price 0) take no step's place, as on the box office.
--
-- 2. One pool lock order for a multi-type reservation. reserve already took
--    every pool of every line by quota_id, then the types by id (exos_create_
--    hold's order). complete did not: it called exos_assert_quota line by
--    line (types by sort order), so a reservation of A (pool Q2) and B (pool
--    Q1) took Q2 then Q1 while a checkout of C (Q1 + Q2) took Q1 then Q2: a
--    deadlock. complete now locks every pool of every line by quota_id, then
--    every type by id, before it consumes the holds; exos_assert_quota then
--    re-checks under locks it already holds.
--
-- Lock order everywhere after this: pools (quota_id) -> types (id) -> a
-- type's steps (sort_order, id). exos_hold_lock_price: hold -> steps;
-- _exos_price_steps_apply: type -> steps; exos_create_hold: pools -> type.
--
-- No new tables, columns, grants or functions. Additive, replay-safe
-- (marker-checked patches of the CURRENT text). D4 authors; not applied.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
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

-- ===========================================================================
-- 1. Reserve: lock the steps, cap at the step, hold the step.
-- ===========================================================================

-- 1a. A variable for the current step of the line being priced.
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)',
  '/* exos: partner step var */',
  $o$  a          jsonb := coalesce(p_attrs, '{}'::jsonb);
BEGIN$o$,
  $n$  a          jsonb := coalesce(p_attrs, '{}'::jsonb);
  v_pstep    jsonb;   /* exos: partner step var */ -- mig 20261107120000
BEGIN$n$, 1);

-- 1b. After the pools and the types: the steps of the paid types, by type
--     then (sort_order, id), the order exos_hold_lock_price and
--     _exos_price_steps_apply lock one type's steps in.
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)',
  '/* exos: partner step lock */',
  $o$  PERFORM 1 FROM public.exos_ticket_tiers
    WHERE id IN (SELECT k::uuid FROM jsonb_object_keys(v_sel) k) ORDER BY id FOR UPDATE;$o$,
  $n$  PERFORM 1 FROM public.exos_ticket_tiers
    WHERE id IN (SELECT k::uuid FROM jsonb_object_keys(v_sel) k) ORDER BY id FOR UPDATE;
  /* exos: partner step lock */ -- mig 20261107120000
  IF NOT p_comp THEN
    PERFORM 1 FROM public.exos_price_steps
      WHERE tier_id IN (SELECT k::uuid FROM jsonb_object_keys(v_sel) k)
      ORDER BY tier_id, sort_order, id FOR UPDATE;
  END IF;$n$, 1);

-- 1c. Each paid line: the current step under that lock; CAP at its remainder;
--     the line remembers the step. (The unit price below comes from the same
--     step: _exos_partner_unit_price -> exos_rr_tier_price -> exos_tier_price_now.)
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)',
  '/* exos: partner price step */',
  $o$    pr := public._exos_partner_unit_price(t.id, p_comp);
    v_lines := v_lines || jsonb_build_object(
      'tier_id', t.id, 'name', t.name, 'quantity', t.qty,$o$,
  $n$    /* exos: partner price step */ -- mig 20261107120000
    v_pstep := NULL;
    IF NOT p_comp THEN
      v_pstep := public.exos_tier_current_price(t.id, now(), 'online');
      IF (v_pstep->>'step_id') IS NOT NULL AND (v_pstep->>'step_remaining') IS NOT NULL
         AND (v_pstep->>'step_remaining')::int < t.qty * public.exos_tier_party_size(t.id) THEN
        RAISE EXCEPTION 'price_step_remaining: only % of % left at this price; reserve those, then the rest at the next price',
          greatest((v_pstep->>'step_remaining')::int, 0), t.name
          USING ERRCODE = 'XP410',
                DETAIL = jsonb_build_object('remaining', greatest((v_pstep->>'step_remaining')::int, 0),
                                            'price_cents', (v_pstep->>'price_cents')::int, 'tier_id', t.id)::text;
      END IF;
    END IF;
    pr := public._exos_partner_unit_price(t.id, p_comp);
    v_lines := v_lines || jsonb_build_object(
      'tier_id', t.id, 'name', t.name, 'quantity', t.qty,
      'price_step_id', v_pstep->>'step_id',$n$, 1);

-- 1d. The holds carry the step and its price: they count against the step
--     until they expire, are released (cancel) or are consumed (complete).
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)',
  '/* exos: partner hold step */',
  $o$      INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, quantity, expires_at, partner_reservation_id)
      VALUES (p_event_id, (l->>'tier_id')::uuid, p_org_id, v_chunk, now() + interval '10 minutes', v_id);$o$,
  $n$      INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, quantity, expires_at, partner_reservation_id,
                                          price_step_id, unit_price_cents)   /* exos: partner hold step */
      VALUES (p_event_id, (l->>'tier_id')::uuid, p_org_id, v_chunk, now() + interval '10 minutes', v_id,
              (l->>'price_step_id')::uuid,
              CASE WHEN l->>'price_step_id' IS NOT NULL THEN (l->>'unit_cents')::int END);$n$, 1);

-- ===========================================================================
-- 2. Complete: every pool by quota_id, then every type by id; mint on the
--    hold's step.
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)',
  '/* exos: partner pool lock order */',
  $o$  UPDATE public.exos_cart_holds SET status = 'consumed', consumed_at = now()
   WHERE partner_reservation_id = r.id AND status = 'active';$o$,
  $n$  /* exos: partner pool lock order */ -- mig 20261107120000
  PERFORM 1 FROM public.exos_quotas q
    WHERE q.id IN (SELECT qt.quota_id FROM public.exos_quota_tiers qt
                    WHERE qt.tier_id IN (SELECT (x->>'tier_id')::uuid FROM jsonb_array_elements(r.lines) x))
    ORDER BY q.id FOR UPDATE;
  PERFORM 1 FROM public.exos_ticket_tiers
    WHERE id IN (SELECT (x->>'tier_id')::uuid FROM jsonb_array_elements(r.lines) x) ORDER BY id FOR UPDATE;
  UPDATE public.exos_cart_holds SET status = 'consumed', consumed_at = now()
   WHERE partner_reservation_id = r.id AND status = 'active';$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)',
  '/* exos: partner price step */',
  $o$        status, barcode_secret, price_paid, order_ref, channel_source, attendee_name
      ) VALUES ($o$,
  $n$        status, barcode_secret, price_paid, order_ref, channel_source, attendee_name,
        price_step_id /* exos: partner price step */
      ) VALUES ($n$, 1);

-- The step the reservation's holds locked (a step deleted since is NULL by
-- its foreign key; NULL lets the trigger decide, as before this migration).
SELECT pg_temp.exos_patch_n('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)',
  '/* exos: partner price step value */',
  $o$        'po:' || r.id, r.channel_source, v_name
      ) RETURNING id INTO v_id;$o$,
  $n$        'po:' || r.id, r.channel_source, v_name,
        (SELECT h.price_step_id FROM public.exos_cart_holds h
          WHERE h.partner_reservation_id = r.id AND h.tier_id = v_tier AND h.price_step_id IS NOT NULL
          ORDER BY h.created_at, h.id LIMIT 1) /* exos: partner price step value */
      ) RETURNING id INTO v_id;$n$, 1);

COMMENT ON COLUMN public.exos_cart_holds.price_step_id IS
  'The price step this hold counts against (mig 20261106130000): a checkout hold once exos_hold_lock_price '
  'locks it, a partner / organizer reservation''s holds from the start (mig 20261107120000).';
