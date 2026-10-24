-- ============================================================================
-- Festival / series / waitlist fixes (usage simulation 2026-10-19, round 2)
-- ============================================================================
-- Touches:  R: exos_create_event_series (clones tax rules, quotas, add-ons,
--              check-in lists and codes; shifts every time by the date's delta)
--           C: _exos_shift_price_schedule, _exos_waitlist_offer_row,
--              _exos_waitlist_offer_freed, exos_waitlist_owed,
--              exos_addon_available, exos_hold_addons, _exos_addon_all_in_cents,
--              exos_tg_quota_waitlist (+ trigger on exos_quotas)
--           R: _exos_waitlist_offer_core, exos_tg_waitlist_autooffer,
--              exos_waitlist_expire_offers
--           P: exos_create_hold, exos_create_guest_hold (seats owed to the
--              queue), exos_join_waitlist (quantity capped at maxPerOrder;
--              seats held back for the queue are offered on join),
--              exos_reschedule_event (doors / end / windows move with the
--              start; doors <= start <= end), exos_fulfill_checkout and
--              exos_refund_ticket_state (the add-on's tax left out)
--           W: exos_cart_holds (+ addons)
-- Pre-reqs: the chain through 20261020120000
--
-- 1. Series clones kept Friday's sales end (Saturday and Sunday stopped
--    selling Friday night), pointed at Friday's tax rule and dropped the
--    quotas, add-ons, check-in lists and presale codes (the venue cap was gone
--    on the other days). Each date now gets its own copy of all of them, and
--    every time on them (sales windows, price steps, list windows, code
--    expiry) moves by that date's distance from the template. Personal codes
--    (waitlist offers, referral rewards, codes reserved for one email) aren't
--    copied.
-- 2. Waitlist with a shared quota. Offers were made only when the waited-for
--    tier itself had a capacity, so a seat freed in a quota (a GA tier with
--    capacity 0 inside a site cap) was never offered and went to the public.
--    Now a freed seat is offered across the quota's tiers in queue order (a
--    waiter whose own tier is full is passed over; otherwise the head of the
--    queue waits for enough seats, as before). While people wait, a public
--    hold can't take the seats they're owed. Expired offers pass on the seats
--    the code still held (max_uses - used_count), not one per offer, and the
--    expired code stops working. The sweep also offers seats that came free
--    another way (a hold that ran out, a bigger quota). Offers end by the
--    event's end (else its start) at the latest.
-- 3. Reschedule moved only the start. Doors and end now move by the same
--    amount unless new ones are given (a value equal to the old one counts as
--    "not given"), and doors <= start <= end is checked. Sales windows still
--    ahead and every check-in list window move too; windows already past (a
--    presale that ended) stay as they were. Price steps are left alone.
-- 4. Add-ons had no reservation: two buyers could pay for the last locker and
--    the loser's whole order failed and was refunded. exos-checkout now holds
--    add-on stock on the cart hold (exos_hold_addons) before the Stripe
--    session; a hold's add-ons count against the stock until it is consumed,
--    released or expires.
-- 5. A ticket's price_paid was the charge less the add-ons' pre-tax price, so
--    it carried the add-on's tax (and refunds returned part of it). It now
--    takes off the add-on's all-in price (the session's unit_all_in_cents,
--    else the add-on's exclusive tax rule).
-- 6. The price_schedule column comment said starts_at; the readers use
--    startsAt. Comment fixed; the clone shift accepts both.
--
-- Multi-day passes: "used" stays per ticket. The supported setup (one list per
-- day with that day's window and re-entry on) is spelled out in the list
-- editor, which also warns about per-day lists without re-entry.
--
-- Re-run safe. Prod apply needs operator OK. No cron change.
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

-- ---------------------------------------------------------------------------
-- 1. Series clones
-- ---------------------------------------------------------------------------
-- A price schedule with every step moved by p_delta. Steps use startsAt (the
-- readers' key); starts_at is moved too. An unparseable time is left as is.
CREATE OR REPLACE FUNCTION public._exos_shift_price_schedule(p_schedule jsonb, p_delta interval)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v_out jsonb := '[]'::jsonb; s jsonb; k text;
BEGIN
  IF p_schedule IS NULL OR jsonb_typeof(p_schedule) <> 'array' OR p_delta IS NULL THEN
    RETURN coalesce(p_schedule, '[]'::jsonb);
  END IF;
  FOR s IN SELECT x FROM jsonb_array_elements(p_schedule) AS x LOOP
    IF jsonb_typeof(s) = 'object' THEN
      FOREACH k IN ARRAY ARRAY['startsAt', 'starts_at'] LOOP
        IF jsonb_typeof(s -> k) = 'string' THEN
          BEGIN
            s := jsonb_set(s, ARRAY[k], to_jsonb(to_char(((s ->> k)::timestamptz + p_delta) AT TIME ZONE 'UTC',
                                                         'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
          EXCEPTION WHEN others THEN NULL;
          END;
        END IF;
      END LOOP;
    END IF;
    v_out := v_out || jsonb_build_array(s);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_shift_price_schedule(jsonb, interval) FROM PUBLIC, anon, authenticated;

COMMENT ON COLUMN public.exos_ticket_tiers.price_schedule IS
  'D4 mig 20260703122000: ordered [{startsAt, price}] time-based price steps (the key is startsAt).
   Effective price = latest step whose startsAt <= now(), else base price. Read-time
   computed (lib/pricing.ts, _shared/pricing.ts). Own primary inventory, not a RULE-2 upstream reprice.';

CREATE OR REPLACE FUNCTION public.exos_create_event_series(p_template_event_id uuid, p_starts_at timestamp with time zone[], p_kind text DEFAULT 'recurring'::text, p_name text DEFAULT NULL::text, p_rule jsonb DEFAULT NULL::jsonb, p_publish boolean DEFAULT NULL::boolean)
 RETURNS TABLE(event_id uuid, starts_at timestamp with time zone, series_index integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_tpl       public.exos_events%ROWTYPE;
  v_tpl_j     jsonb;
  v_series    uuid;
  v_next      int;
  v_tz        text;
  v_d_doors   interval;
  v_d_ends    interval;
  v_occ       timestamptz;
  v_occs      timestamptz[];
  v_new       uuid;
  v_status    text;
  v_slug      text;
  v_t         record;
  v_has_codes boolean;
  -- festival p1 (mig 20261021130000): per-date copies of the event's setup.
  v_delta     interval;
  v_id        uuid;
  v_tiers     jsonb;   -- template tier id -> this date's tier id
  v_taxes     jsonb;   -- template tax rule id -> this date's rule id
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_event_series: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_kind NOT IN ('recurring','timed-entry') THEN
    RAISE EXCEPTION 'exos_create_event_series: kind must be recurring or timed-entry';
  END IF;
  SELECT * INTO v_tpl FROM public.exos_events WHERE id = p_template_event_id;
  IF v_tpl.id IS NULL THEN
    RAISE EXCEPTION 'exos_create_event_series: template event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_tpl.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_create_event_series: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_tpl.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_create_event_series: template event is cancelled';
  END IF;
  IF v_tpl.starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_create_event_series: template event has no start time';
  END IF;

  -- Distinct, sorted, future-of-nothing (any time is allowed — a back-dated
  -- occurrence is the organizer's call), minus the template's own start AND
  -- minus any date already in the series (an "extend" call that repeats dates
  -- must not fail on the deterministic slug, nor duplicate slug-less events).
  SELECT array_agg(DISTINCT o ORDER BY o) INTO v_occs
    FROM unnest(coalesce(p_starts_at, '{}')) AS o
   WHERE o IS NOT NULL AND o <> v_tpl.starts_at
     AND (v_tpl.series_id IS NULL OR NOT EXISTS (
           SELECT 1 FROM public.exos_events m
            WHERE m.series_id = v_tpl.series_id AND m.starts_at = o));
  IF coalesce(array_length(v_occs, 1), 0) = 0 THEN
    RAISE EXCEPTION 'exos_create_event_series: no new occurrences — every date given is the template or already in this series';
  END IF;
  IF array_length(v_occs, 1) > 200 THEN
    RAISE EXCEPTION 'exos_create_event_series: max 200 occurrences per call';
  END IF;

  -- Validate the template timezone up front so occurs_at_local is never NULL
  -- on a clone; a bad name degrades to UTC with a warning, matching the app.
  v_tz := coalesce(nullif(v_tpl.timezone, ''), 'UTC');
  BEGIN
    PERFORM now() AT TIME ZONE v_tz;
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE WARNING 'exos_create_event_series: template % has an invalid timezone (%) — using UTC', v_tpl.id, v_tz;
    v_tz := 'UTC';
  END;
  v_d_doors := v_tpl.doors_at - v_tpl.starts_at;
  v_d_ends  := v_tpl.ends_at  - v_tpl.starts_at;
  v_status  := CASE WHEN p_publish IS TRUE THEN 'published'
                    WHEN p_publish IS FALSE THEN 'draft'
                    ELSE v_tpl.status END;

  -- Series row: reuse when the template already belongs to one (extend).
  v_series := v_tpl.series_id;
  IF v_series IS NULL THEN
    INSERT INTO public.exos_event_series (org_id, name, kind, template_event_id, timezone, rule, created_by)
    VALUES (v_tpl.org_id, left(coalesce(nullif(p_name, ''), v_tpl.name), 200), p_kind,
            v_tpl.id, v_tz, p_rule, v_uid)
    RETURNING id INTO v_series;
    UPDATE public.exos_events SET series_id = v_series, series_index = 0 WHERE id = v_tpl.id;
    v_next := 1;
  ELSE
    UPDATE public.exos_event_series
       SET rule = coalesce(p_rule, rule), updated_at = now()
     WHERE id = v_series;
    SELECT coalesce(max(e.series_index), 0) + 1 INTO v_next
      FROM public.exos_events e WHERE e.series_id = v_series;
  END IF;

  -- Column-agnostic template: strip per-run state. NOTE jsonb_populate_record
  -- yields NULL (not the column DEFAULT) for an absent key, so only NULLABLE
  -- columns may be stripped; NOT NULL DEFAULT columns get an explicit value in
  -- the override object below (tickets_sold, checkin_test_mode). Unknown keys
  -- are ignored, so overrides for columns a narrower schema lacks are harmless.
  v_tpl_j := to_jsonb(v_tpl)
             - 'cancelled_at' - 'cancel_reason'
             - 'reminder_24h_sent_at' - 'reminder_2h_sent_at' - 'reminder_manual_sent_at'
             - 'automatiq_listing_id' - 'sync_status' - 'checkin_test_until';

  v_has_codes := to_regclass('public.exos_discount_codes') IS NOT NULL;

  FOREACH v_occ IN ARRAY v_occs LOOP
    v_new  := gen_random_uuid();
    v_slug := CASE WHEN v_tpl.slug IS NULL THEN NULL
                   ELSE left(v_tpl.slug, 60) || '-' || to_char(v_occ AT TIME ZONE v_tz, 'YYYYMMDD-HH24MI') END;
    v_delta := v_occ - v_tpl.starts_at;
    v_tiers := '{}'::jsonb;
    v_taxes := '{}'::jsonb;

    INSERT INTO public.exos_events
    SELECT * FROM jsonb_populate_record(NULL::public.exos_events, v_tpl_j || jsonb_build_object(
      'id',              v_new,
      'slug',            v_slug,
      'status',          v_status,
      'starts_at',       v_occ,
      'doors_at',        CASE WHEN v_d_doors IS NULL THEN NULL ELSE v_occ + v_d_doors END,
      'ends_at',         CASE WHEN v_d_ends  IS NULL THEN NULL ELSE v_occ + v_d_ends  END,
      'occurs_at_local', public.exos_occurs_at_local(v_occ, v_tz),
      'tickets_sold',    0,
      'checkin_test_mode', false,
      'series_id',       v_series,
      'series_index',    v_next,
      'created_by',      v_uid,
      'created_at',      now(),
      'updated_at',      now()));

    -- Tax rules first: this date's tiers and add-ons point at its own copy.
    FOR v_t IN SELECT r.id, to_jsonb(r) AS j FROM public.exos_tax_rules r
                WHERE r.event_id = v_tpl.id ORDER BY r.created_at, r.id LOOP
      v_id := gen_random_uuid();
      INSERT INTO public.exos_tax_rules
      SELECT * FROM jsonb_populate_record(NULL::public.exos_tax_rules,
        (v_t.j - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
          'id', v_id, 'event_id', v_new, 'created_at', now(), 'updated_at', now()));
      v_taxes := v_taxes || jsonb_build_object(v_t.id::text, v_id);
    END LOOP;

    -- Tiers: same shape, fresh id, nothing sold, every time moved with the date.
    FOR v_t IN SELECT t.id, to_jsonb(t) AS j FROM public.exos_ticket_tiers t
                WHERE t.event_id = v_tpl.id ORDER BY t.sort_order, t.name LOOP
      v_id := gen_random_uuid();
      INSERT INTO public.exos_ticket_tiers
      SELECT * FROM jsonb_populate_record(NULL::public.exos_ticket_tiers,
        (v_t.j - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
          'id', v_id, 'event_id', v_new, 'sold', 0,
          'sales_start', (v_t.j ->> 'sales_start')::timestamptz + v_delta,
          'sales_end',   (v_t.j ->> 'sales_end')::timestamptz + v_delta,
          'price_schedule', public._exos_shift_price_schedule(v_t.j -> 'price_schedule', v_delta),
          'tax_rate_id', coalesce(v_taxes ->> (v_t.j ->> 'tax_rate_id'), v_t.j ->> 'tax_rate_id'),
          'created_at', now(), 'updated_at', now()));
      v_tiers := v_tiers || jsonb_build_object(v_t.id::text, v_id);
    END LOOP;

    -- Quotas (the venue cap) with the same member tiers.
    FOR v_t IN SELECT q.id, to_jsonb(q) AS j FROM public.exos_quotas q
                WHERE q.event_id = v_tpl.id ORDER BY q.created_at, q.id LOOP
      v_id := gen_random_uuid();
      INSERT INTO public.exos_quotas
      SELECT * FROM jsonb_populate_record(NULL::public.exos_quotas,
        (v_t.j - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
          'id', v_id, 'event_id', v_new, 'created_at', now(), 'updated_at', now()));
      INSERT INTO public.exos_quota_tiers (quota_id, tier_id)
      SELECT v_id, (v_tiers ->> qt.tier_id::text)::uuid
        FROM public.exos_quota_tiers qt
       WHERE qt.quota_id = v_t.id AND v_tiers ? qt.tier_id::text;
    END LOOP;

    -- Add-ons: own stock per date.
    FOR v_t IN SELECT a.id, to_jsonb(a) AS j FROM public.exos_event_addons a
                WHERE a.event_id = v_tpl.id ORDER BY a.sort_order, a.name LOOP
      INSERT INTO public.exos_event_addons
      SELECT * FROM jsonb_populate_record(NULL::public.exos_event_addons,
        (v_t.j - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
          'id', gen_random_uuid(), 'event_id', v_new, 'sold', 0,
          'tax_rate_id', v_taxes ->> (v_t.j ->> 'tax_rate_id'),
          'created_at', now(), 'updated_at', now()));
    END LOOP;

    -- Check-in lists: this date's tiers, the window moved with the date.
    FOR v_t IN SELECT l.id, l.tier_ids, to_jsonb(l) AS j FROM public.exos_checkin_lists l
                WHERE l.event_id = v_tpl.id ORDER BY l.sort_order, l.name LOOP
      INSERT INTO public.exos_checkin_lists
      SELECT * FROM jsonb_populate_record(NULL::public.exos_checkin_lists,
        (v_t.j - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
          'id', gen_random_uuid(), 'event_id', v_new,
          'tier_ids', CASE WHEN v_t.tier_ids IS NULL THEN NULL
                           ELSE to_jsonb(ARRAY(SELECT (v_tiers ->> x::text)::uuid FROM unnest(v_t.tier_ids) AS x
                                                WHERE v_tiers ? x::text)) END,
          'valid_from',  (v_t.j ->> 'valid_from')::timestamptz + v_delta,
          'valid_until', (v_t.j ->> 'valid_until')::timestamptz + v_delta,
          'created_at', now(), 'updated_at', now()));
    END LOOP;

    -- Codes (presale, promo links, discounts), unused. Personal ones stay put:
    -- waitlist offers, referral rewards, a code reserved for one email.
    FOR v_t IN SELECT v.id, to_jsonb(v) AS j FROM public.exos_vouchers v
                WHERE v.event_id = v_tpl.id AND v.reserved_email IS NULL
                  AND coalesce(v.comment, '') <> 'waitlist auto-offer'
                  AND NOT EXISTS (SELECT 1 FROM public.exos_waitlist w WHERE w.voucher_id = v.id)
                  AND NOT EXISTS (SELECT 1 FROM public.exos_referral_rewards rr WHERE rr.voucher_id = v.id)
                  AND (v.tier_id IS NULL OR v_tiers ? v.tier_id::text)
                ORDER BY v.created_at, v.id LOOP
      INSERT INTO public.exos_vouchers
      SELECT * FROM jsonb_populate_record(NULL::public.exos_vouchers,
        (v_t.j - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
          'id', gen_random_uuid(), 'event_id', v_new, 'used_count', 0, 'link_clicks', 0,
          'tier_id', v_tiers ->> (v_t.j ->> 'tier_id'),
          'valid_until', (v_t.j ->> 'valid_until')::timestamptz + v_delta,
          'created_at', now(), 'updated_at', now()));
    END LOOP;

    -- Discount codes (prod only; the offline harness has no such table).
    IF v_has_codes THEN
      EXECUTE format($q$
        INSERT INTO public.exos_discount_codes
        SELECT r.* FROM public.exos_discount_codes d,
          LATERAL jsonb_populate_record(NULL::public.exos_discount_codes,
          (to_jsonb(d) - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
            'id', gen_random_uuid(), 'event_id', %L::uuid, 'used_count', 0,
            'unlocks_tier_ids', NULL, 'created_at', now(), 'updated_at', now())) r
          WHERE d.event_id = %L::uuid
      $q$, v_new, v_tpl.id);
    END IF;

    event_id := v_new; starts_at := v_occ; series_index := v_next;
    RETURN NEXT;
    v_next := v_next + 1;
  END LOOP;
  RETURN;
END $function$;

-- ---------------------------------------------------------------------------
-- 2. Waitlist
-- ---------------------------------------------------------------------------
-- One offer: a code for the waiter's quantity on p_tier_id (reserving it in
-- the tier / quota), valid for p_hours but never past the event's end (else
-- its start). False when the event is already over: nothing is offered.
CREATE OR REPLACE FUNCTION public._exos_waitlist_offer_row(p_waitlist_id uuid, p_tier_id uuid, p_hours integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  w       public.exos_waitlist%ROWTYPE;
  e       public.exos_events%ROWTYPE;
  v_until timestamptz;
  v_qty   int;
  v_code  text;
  v_vid   uuid;
  v_safe  text;
  v_left  text;
BEGIN
  SELECT * INTO w FROM public.exos_waitlist WHERE id = p_waitlist_id AND status = 'waiting';
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = w.event_id;
  IF e.id IS NULL THEN RETURN false; END IF;
  v_until := now() + make_interval(hours => greatest(1, coalesce(p_hours, 48)));
  IF coalesce(e.ends_at, e.starts_at) IS NOT NULL THEN
    v_until := least(v_until, coalesce(e.ends_at, e.starts_at));
  END IF;
  IF v_until <= now() THEN RETURN false; END IF;
  v_qty := greatest(1, coalesce(w.quantity, 1));
  v_safe := replace(replace(coalesce(e.name, 'an event'), '<', '&lt;'), '>', '&gt;');
  v_left := CASE WHEN v_until - now() >= interval '90 minutes'
                 THEN round(extract(epoch FROM v_until - now()) / 3600)::int::text || ' hours'
                 ELSE greatest(1, floor(extract(epoch FROM v_until - now()) / 60))::int::text || ' minutes' END;

  v_code := upper(encode(extensions.gen_random_bytes(6), 'hex'));
  INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,
              block_quota, reserved_email, valid_until, comment)
  VALUES (w.event_id, v_code, p_tier_id, v_qty, true, p_tier_id IS NOT NULL, w.email,
          v_until, 'waitlist auto-offer')
  RETURNING id INTO v_vid;

  UPDATE public.exos_waitlist
     SET status = 'offered', offered_at = now(), claim_expires_at = v_until, voucher_id = v_vid
   WHERE id = w.id;

  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('waitlist-open', w.email,
    left('A spot opened up: ' || left(coalesce(e.name, 'your event'), 120), 200),
    '<p>Good news — a spot just opened up for <strong>' || v_safe ||
      '</strong>.</p><p>Your code <strong>' || v_code || '</strong> lets you buy ' ||
      CASE WHEN v_qty > 1 THEN 'up to ' || v_qty::text || ' tickets' ELSE 'it' END ||
      ', but only for the next ' || v_left ||
      ' — open Exos and enter it at checkout before it rolls to the next person.</p>',
    'pending');
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_waitlist_offer_row(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_waitlist_offer_row(uuid, uuid, integer) TO service_role;

-- The organizer's "offer the next N" and the RSVP release: same rules as
-- before (FIFO, a group waits for enough seats), offers through _offer_row.
CREATE OR REPLACE FUNCTION public._exos_waitlist_offer_core(
  p_event_id uuid, p_tier_id uuid, p_count integer, p_hours integer
) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_count int := 0;
  v_seats int := greatest(1, least(500, coalesce(p_count,1)));   -- seats to offer
  r record; v_qty int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id) THEN RETURN 0; END IF;
  FOR r IN
    SELECT id, quantity FROM public.exos_waitlist
    WHERE event_id = p_event_id AND status = 'waiting'
      AND (p_tier_id IS NULL OR tier_id = p_tier_id OR tier_id IS NULL)
    ORDER BY created_at, id
    LIMIT 500
    FOR UPDATE SKIP LOCKED
  LOOP
    v_qty := greatest(1, coalesce(r.quantity, 1));
    -- FIFO: the next group waits for enough seats rather than being skipped.
    EXIT WHEN v_qty > v_seats;
    EXIT WHEN NOT public._exos_waitlist_offer_row(r.id, p_tier_id, p_hours);
    v_count := v_count + 1;
    v_seats := v_seats - v_qty;
    EXIT WHEN v_seats <= 0;
  END LOOP;
  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public._exos_waitlist_offer_core(uuid, uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_waitlist_offer_core(uuid, uuid, integer, integer) TO service_role;

-- Seats freed on p_tier_id: offer them across every tier that shares a quota
-- with it, in queue order. Each waiter is offered their own tier (an
-- any-tier waiter, p_tier_id). A waiter whose own tier is full is passed over
-- (that tier can't take them anyway); otherwise the head of the queue waits
-- for enough seats. p_seats caps the seats handed out (NULL = what is free).
CREATE OR REPLACE FUNCTION public._exos_waitlist_offer_freed(
  p_event_id uuid, p_tier_id uuid, p_seats integer, p_hours integer
) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_tiers uuid[];
  v_left  int := p_seats;
  v_count int := 0;
  r record; v_qty int; v_tier uuid; v_local int; v_avail int; v_can int;
BEGIN
  IF p_tier_id IS NULL THEN
    RETURN CASE WHEN coalesce(p_seats, 0) > 0
                THEN public._exos_waitlist_offer_core(p_event_id, NULL, p_seats, p_hours) ELSE 0 END;
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_tiers FROM (
    SELECT p_tier_id AS x
    UNION
    SELECT qt2.tier_id FROM public.exos_quota_tiers qt1
      JOIN public.exos_quota_tiers qt2 ON qt2.quota_id = qt1.quota_id
     WHERE qt1.tier_id = p_tier_id) s;

  FOR r IN
    SELECT id, tier_id, quantity FROM public.exos_waitlist
    WHERE event_id = p_event_id AND status = 'waiting'
      AND (tier_id = ANY (v_tiers) OR tier_id IS NULL)
    ORDER BY created_at, id
    LIMIT 500
    FOR UPDATE SKIP LOCKED
  LOOP
    v_qty  := greatest(1, coalesce(r.quantity, 1));
    v_tier := coalesce(r.tier_id, p_tier_id);
    v_local := public.exos_tier_available(v_tier);
    IF v_local IS NOT NULL AND v_local < v_qty AND r.tier_id IS NOT NULL AND r.tier_id <> p_tier_id THEN
      CONTINUE;
    END IF;
    v_avail := public.exos_effective_available(v_tier);
    v_can := CASE WHEN v_avail IS NULL THEN v_left
                  WHEN v_left IS NULL THEN v_avail
                  ELSE least(v_avail, v_left) END;
    EXIT WHEN v_can IS NULL;          -- nothing capped: nobody is waiting for a seat
    EXIT WHEN v_qty > v_can;          -- FIFO: the group waits for enough seats
    EXIT WHEN NOT public._exos_waitlist_offer_row(r.id, v_tier, p_hours);
    v_count := v_count + 1;
    IF v_left IS NOT NULL THEN
      v_left := v_left - v_qty;
      EXIT WHEN v_left <= 0;
    END IF;
  END LOOP;
  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public._exos_waitlist_offer_freed(uuid, uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_waitlist_offer_freed(uuid, uuid, integer, integer) TO service_role;

-- Seats the queue is owed on this tier: what people wait for on it, on a tier
-- sharing a quota with it (while that tier still has room of its own), or on
-- any tier of the event. A public hold can't take them.
CREATE OR REPLACE FUNCTION public.exos_waitlist_owed(p_tier_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(sum(greatest(1, coalesce(w.quantity, 1))), 0)::int
    FROM public.exos_ticket_tiers t
    JOIN public.exos_waitlist w ON w.event_id = t.event_id AND w.status = 'waiting'
   WHERE t.id = p_tier_id
     AND (w.tier_id IS NULL OR w.tier_id = t.id
          OR (w.tier_id IN (SELECT qt2.tier_id FROM public.exos_quota_tiers qt1
                              JOIN public.exos_quota_tiers qt2 ON qt2.quota_id = qt1.quota_id
                             WHERE qt1.tier_id = t.id)
              AND coalesce(public.exos_tier_available(w.tier_id), 1) > 0));
$$;
REVOKE ALL ON FUNCTION public.exos_waitlist_owed(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_waitlist_owed(uuid) TO service_role;

-- A tier's seats came free (refund, void, more capacity): offer them, for an
-- uncapped tier too when it sits in a quota.
CREATE OR REPLACE FUNCTION public.exos_tg_waitlist_autooffer()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.sold < OLD.sold OR (OLD.capacity <> 0 AND (NEW.capacity = 0 OR NEW.capacity > OLD.capacity)) THEN
    IF EXISTS (SELECT 1 FROM public.exos_waitlist w
                WHERE w.event_id = NEW.event_id AND w.status = 'waiting') THEN
      PERFORM public._exos_waitlist_offer_freed(NEW.event_id, NEW.id, NULL, 48);
    END IF;
  END IF;
  RETURN NEW;
END $function$;

-- A quota grew or reopened: the same, for its tiers.
CREATE OR REPLACE FUNCTION public.exos_tg_quota_waitlist()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tier uuid;
BEGIN
  IF (OLD.closed AND NOT NEW.closed)
     OR (OLD.size IS NOT NULL AND (NEW.size IS NULL OR NEW.size > OLD.size)) THEN
    SELECT qt.tier_id INTO v_tier FROM public.exos_quota_tiers qt WHERE qt.quota_id = NEW.id ORDER BY qt.tier_id LIMIT 1;
    IF v_tier IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_waitlist w
                                       WHERE w.event_id = NEW.event_id AND w.status = 'waiting') THEN
      PERFORM public._exos_waitlist_offer_freed(NEW.event_id, v_tier, NULL, 48);
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_quota_waitlist() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_quotas_waitlist ON public.exos_quotas;
CREATE TRIGGER exos_quotas_waitlist AFTER UPDATE OF size, closed ON public.exos_quotas
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_quota_waitlist();

-- Expired offers: the code stops working and the seats it still held
-- (max_uses - used_count) go to the next in line. Then a sweep offers seats
-- that came free some other way (a hold that ran out, a bigger quota).
CREATE OR REPLACE FUNCTION public.exos_waitlist_expire_offers()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0; v_vids uuid[]; r record;
BEGIN
  WITH ex AS (
    UPDATE public.exos_waitlist SET status = 'expired'
     WHERE status = 'offered' AND claim_expires_at < now()
    RETURNING voucher_id)
  SELECT count(*), array_agg(voucher_id) FILTER (WHERE voucher_id IS NOT NULL) INTO v_n, v_vids FROM ex;

  UPDATE public.exos_vouchers SET valid_until = now()
   WHERE id = ANY (coalesce(v_vids, '{}')) AND (valid_until IS NULL OR valid_until > now());

  FOR r IN SELECT v.event_id, v.tier_id, sum(greatest(v.max_uses - v.used_count, 0))::int AS seats
             FROM public.exos_vouchers v WHERE v.id = ANY (coalesce(v_vids, '{}'))
            GROUP BY v.event_id, v.tier_id LOOP
    IF r.seats > 0 THEN
      PERFORM public._exos_waitlist_offer_freed(r.event_id, r.tier_id, r.seats, 48);
    END IF;
  END LOOP;

  FOR r IN SELECT DISTINCT w.event_id, w.tier_id
             FROM public.exos_waitlist w JOIN public.exos_events e ON e.id = w.event_id
            WHERE w.status = 'waiting' AND w.tier_id IS NOT NULL AND e.status = 'published'
              AND coalesce(e.ends_at, e.starts_at, now() + interval '1 day') > now() LOOP
    PERFORM public._exos_waitlist_offer_freed(r.event_id, r.tier_id, NULL, 48);
  END LOOP;
  RETURN v_n;
END $function$;

-- Holds: seats owed to the queue aren't the public's.
SELECT pg_temp.exos_patch_n('public.exos_create_hold(uuid, uuid, integer, integer, text)', '/* waitlist owed */',
  '  v_avail := public.exos_effective_available(p_tier_id);
',
  '  v_avail := public.exos_effective_available(p_tier_id) - public.exos_waitlist_owed(p_tier_id);  /* waitlist owed */
', 1);
SELECT pg_temp.exos_patch_n('public.exos_create_guest_hold(uuid, uuid, integer, text, text, text)', '/* waitlist owed */',
  '  v_avail := public.exos_effective_available(p_tier_id);
',
  '  v_avail := public.exos_effective_available(p_tier_id) - public.exos_waitlist_owed(p_tier_id);  /* waitlist owed */
', 1);

-- Join: a group can't wait for more than one order may buy; seats already held
-- back for the queue are offered right away (in queue order).
SELECT pg_temp.exos_patch_n('public.exos_join_waitlist(uuid, text, uuid, text, integer, jsonb)', '/* waitlist max per order */',
  '  SELECT w.id INTO v_id FROM public.exos_waitlist w
',
  '  SELECT least(v_qty, (e.purchase_limits ->> ''maxPerOrder'')::int) INTO v_qty  /* waitlist max per order */
    FROM public.exos_events e
   WHERE e.id = p_event_id AND e.purchase_limits ->> ''maxPerOrder'' ~ ''^[1-9][0-9]{0,3}$'';
  v_qty := coalesce(v_qty, greatest(1, least(50, coalesce(p_quantity, 1))));

  SELECT w.id INTO v_id FROM public.exos_waitlist w
', 1);
SELECT pg_temp.exos_patch_n('public.exos_join_waitlist(uuid, text, uuid, text, integer, jsonb)', '/* waitlist join offer */',
  '  RETURN QUERY SELECT v_id, v_pos;
',
  '  IF p_tier_id IS NOT NULL
     AND public.exos_effective_available(p_tier_id) <= public.exos_waitlist_owed(p_tier_id) THEN  /* waitlist join offer */
    PERFORM public._exos_waitlist_offer_freed(p_event_id, p_tier_id, NULL, 48);
  END IF;
  RETURN QUERY SELECT v_id, v_pos;
', 1);

-- ---------------------------------------------------------------------------
-- 3. Reschedule: doors, end and windows move with the start
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_reschedule_event(uuid, timestamp with time zone, timestamp with time zone, timestamp with time zone, text, text, boolean, timestamp with time zone)',
  '/* timing moves together */',
  '  v_n        int := 0;
',
  '  v_n        int := 0;
  v_delta    interval;     /* timing moves together */
  v_doors    timestamptz;
  v_ends     timestamptz;
', 1);
SELECT pg_temp.exos_patch_n('public.exos_reschedule_event(uuid, timestamp with time zone, timestamp with time zone, timestamp with time zone, text, text, boolean, timestamp with time zone)',
  '/* doors <= start <= end */',
  '  v_sold := EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.event_id = p_event_id AND t.status <> ''voided'');
',
  '  -- Doors and end move by the same amount unless new ones are given (the old
  -- value again counts as not given). /* doors <= start <= end */
  v_delta := p_new_starts_at - e.starts_at;
  v_doors := CASE WHEN p_new_doors_at IS NOT NULL AND p_new_doors_at IS DISTINCT FROM e.doors_at THEN p_new_doors_at
                  ELSE coalesce(e.doors_at + v_delta, e.doors_at) END;
  v_ends  := CASE WHEN p_new_ends_at IS NOT NULL AND p_new_ends_at IS DISTINCT FROM e.ends_at THEN p_new_ends_at
                  ELSE coalesce(e.ends_at + v_delta, e.ends_at) END;
  IF v_doors > p_new_starts_at THEN
    RAISE EXCEPTION ''exos_reschedule_event: doors can''''t open after the start'' USING ERRCODE = ''22023'';
  END IF;
  IF v_ends < p_new_starts_at THEN
    RAISE EXCEPTION ''exos_reschedule_event: the end can''''t be before the start'' USING ERRCODE = ''22023'';
  END IF;

  v_sold := EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.event_id = p_event_id AND t.status <> ''voided'');
', 1);
SELECT pg_temp.exos_patch_n('public.exos_reschedule_event(uuid, timestamp with time zone, timestamp with time zone, timestamp with time zone, text, text, boolean, timestamp with time zone)',
  '/* windows move too */',
  '         doors_at        = COALESCE(p_new_doors_at, doors_at),
         ends_at         = COALESCE(p_new_ends_at, ends_at),
         occurs_at_local = COALESCE(p_occurs_at_local, occurs_at_local),
         updated_at      = now()
   WHERE id = p_event_id;
',
  '         doors_at        = v_doors,
         ends_at         = v_ends,
         occurs_at_local = COALESCE(p_occurs_at_local, occurs_at_local),
         updated_at      = now()
   WHERE id = p_event_id;
  IF v_delta IS NOT NULL THEN
    -- Sales windows still ahead move with the show; past ones (a presale
    -- that ended) stay. Check-in list windows all move. /* windows move too */
    UPDATE public.exos_ticket_tiers
       SET sales_start = CASE WHEN sales_start > now() THEN sales_start + v_delta ELSE sales_start END,
           sales_end   = CASE WHEN sales_end   > now() THEN sales_end   + v_delta ELSE sales_end   END
     WHERE event_id = p_event_id AND (sales_start > now() OR sales_end > now());
    UPDATE public.exos_checkin_lists
       SET valid_from = valid_from + v_delta, valid_until = valid_until + v_delta
     WHERE event_id = p_event_id AND (valid_from IS NOT NULL OR valid_until IS NOT NULL);
  END IF;
', 1);

-- ---------------------------------------------------------------------------
-- 4. Add-on stock held with the cart hold
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_cart_holds ADD COLUMN IF NOT EXISTS addons jsonb;
DO $$ BEGIN
  ALTER TABLE public.exos_cart_holds ADD CONSTRAINT exos_cart_holds_addons_array
    CHECK (addons IS NULL OR jsonb_typeof(addons) = 'array');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON COLUMN public.exos_cart_holds.addons IS
  'Add-ons reserved with this hold, [{addon_id, quantity}] (exos_hold_addons, mig 20261021130000).';

-- Stock left: capacity less sold and less what live holds reserve. NULL = no cap.
CREATE OR REPLACE FUNCTION public.exos_addon_available(p_addon_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN a.capacity = 0 THEN NULL ELSE greatest(0, a.capacity - a.sold - coalesce((
           SELECT sum((x ->> 'quantity')::int)
             FROM public.exos_cart_holds h, jsonb_array_elements(h.addons) x
            WHERE h.event_id = a.event_id AND h.status = 'active' AND h.expires_at > now()
              AND h.addons IS NOT NULL AND x ->> 'addon_id' = a.id::text), 0))::int END
    FROM public.exos_event_addons a WHERE a.id = p_addon_id;
$$;
REVOKE ALL ON FUNCTION public.exos_addon_available(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_addon_available(uuid) TO service_role;

-- exos-checkout, after the ticket hold: reserve the order's add-ons on it, or
-- refuse (sold out) before anyone is charged. Service role only.
CREATE OR REPLACE FUNCTION public.exos_hold_addons(p_hold_id uuid, p_addons jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  h       public.exos_cart_holds%ROWTYPE;
  v_want  jsonb;
  r       record;
  v_avail int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_hold_addons: service role only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO h FROM public.exos_cart_holds WHERE id = p_hold_id FOR UPDATE;
  IF NOT FOUND OR h.status <> 'active' OR h.expires_at <= now() THEN
    RAISE EXCEPTION 'exos_hold_addons: the reservation ran out, start again' USING ERRCODE = '23514';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('addon_id', addon_id, 'quantity', qty) ORDER BY addon_id), '[]'::jsonb)
    INTO v_want
    FROM (SELECT (x ->> 'addon_id')::uuid AS addon_id, sum((x ->> 'quantity')::int)::int AS qty
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_addons) = 'array' THEN p_addons ELSE '[]'::jsonb END) x
           WHERE x ->> 'addon_id' IS NOT NULL AND coalesce((x ->> 'quantity')::int, 0) > 0
           GROUP BY 1) s;
  -- This hold's own earlier reservation doesn't count against it.
  UPDATE public.exos_cart_holds SET addons = NULL WHERE id = h.id;
  FOR r IN SELECT (x ->> 'addon_id')::uuid AS addon_id, (x ->> 'quantity')::int AS qty
             FROM jsonb_array_elements(v_want) x ORDER BY 1 LOOP
    PERFORM 1 FROM public.exos_event_addons a WHERE a.id = r.addon_id AND a.event_id = h.event_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos_hold_addons: add-on not available' USING ERRCODE = '23514';
    END IF;
    v_avail := public.exos_addon_available(r.addon_id);
    IF v_avail IS NOT NULL AND v_avail < r.qty THEN
      RAISE EXCEPTION 'exos_hold_addons: add-on "%" is sold out',
        (SELECT left(name, 80) FROM public.exos_event_addons WHERE id = r.addon_id) USING ERRCODE = '23514';
    END IF;
  END LOOP;
  UPDATE public.exos_cart_holds SET addons = nullif(v_want, '[]'::jsonb) WHERE id = h.id;
  RETURN v_want;
END $$;
REVOKE ALL ON FUNCTION public.exos_hold_addons(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_hold_addons(uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. price_paid without the add-on's tax
-- ---------------------------------------------------------------------------
-- An add-on's all-in unit price in cents (exclusive tax added as the checkout
-- does: allInCents in _shared/pricing.ts).
CREATE OR REPLACE FUNCTION public._exos_addon_all_in_cents(p_addon_id uuid, p_unit_cents integer)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(p_unit_cents, 0) + coalesce((
    SELECT round(coalesce(p_unit_cents, 0) * r.rate_percent / 100)::int
      FROM public.exos_event_addons a
      JOIN public.exos_tax_rules r ON r.id = a.tax_rate_id
     WHERE a.id = p_addon_id AND NOT r.price_includes_tax AND r.rate_percent > 0), 0);
$$;
REVOKE ALL ON FUNCTION public._exos_addon_all_in_cents(uuid, integer) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)', '_exos_addon_all_in_cents',
  'coalesce((a->>''unit_price_cents'')::int, 0)) FROM jsonb_array_elements(',
  'coalesce((a->>''unit_all_in_cents'')::int, public._exos_addon_all_in_cents((a->>''addon_id'')::uuid, coalesce((a->>''unit_price_cents'')::int, 0)))) FROM jsonb_array_elements(',
  1);
-- The per-ticket refund share is worked out the same way.
SELECT pg_temp.exos_patch_n('public.exos_refund_ticket_state(text)', '_exos_addon_all_in_cents',
  '* coalesce((a->>''unit_price_cents'')::int, 0))',
  '* coalesce((a->>''unit_all_in_cents'')::int, public._exos_addon_all_in_cents((a->>''addon_id'')::uuid, coalesce((a->>''unit_price_cents'')::int, 0))))',
  1);
