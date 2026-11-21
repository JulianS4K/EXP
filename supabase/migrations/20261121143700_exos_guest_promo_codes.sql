-- ============================================================================
-- 20261121143700_exos_guest_promo_codes.sql — promo codes for guest buyers
-- ============================================================================
-- Touches:  W: FUNCTION exos_voucher_throttle (replaced in full: its only
--              definition is mig 20260929010000; nothing patches it)
--           C: FUNCTION exos_check_voucher_guest (service role only)
--           C: INDEX exos_voucher_attempts_window_idx
-- Pre-reqs: 20260929010000 (exos_voucher_attempts, exos_voucher_throttle),
--           20260929080000 (codes need an account), 20261118100000 (drop list)
--
-- Why codes needed an account (mig 20260929080000): signed-out callers shared
-- one 60-miss bucket per event, so a guesser could try 60 codes per 10 minutes
-- per event, or lock everyone else out of codes. Signed-in accounts get 10
-- misses each, and exos-checkout (service role) 120 per event.
--
-- Guests (checkout with just an email) now enter ordinary promo codes too,
-- without opening the guessing hole again:
--   * anon still cannot call exos_check_voucher / exos_voucher_discount /
--     exos_voucher_tier (unchanged). A guest's code reaches the database only
--     through exos-checkout, which calls exos_check_voucher_guest with the
--     salted hash of the request's network (the guest hold's key).
--   * Guest misses count on their own buckets: 10 per network ('g:<hash>',
--     across all events; exos-checkout hashes an IPv6 address on its /64)
--     and 30 per event for all guests together ('ge:<event>'), per 10
--     minutes. They never touch an account's bucket or the service role's
--     's:<event>' bucket, so guesses can't lock signed-in buyers or checkout
--     out; at worst the guest path of one event pauses for 10 minutes and its
--     guests sign in instead.
--   * Each attempt is reserved FIRST, in one statement per bucket (upsert ...
--     RETURNING, as exos_rate_hit), network then event, and given back only
--     when the code turns out usable. Concurrent misses can't overshoot a cap
--     (the read-then-record order did: 91 against 30 under 64 connections),
--     and a network already over its budget never spends the event's.
--   * Every answer that isn't a usable code costs the attempt: invalid,
--     expired, already used and 'sign in required' (each of the last three
--     says a code exists).
--   * Only a published event takes guest codes; any other id (unknown, draft,
--     cancelled) answers 'invalid code' without writing a row.
--   * The SPA never checks a guest's link code (?code=) on page load: the code
--     waits in the field until the buyer taps Apply, so a bad link can't spend
--     every visitor's attempt and fill the event's budget.
--   * The guest check passes NO email: a drop-list presale code (members
--     only, mig 20261118100000) never passes for a guest (their email is
--     unproven until after payment).
--   * A capacity-bypass code, a code made for one person (reserved_email:
--     a waitlist offer, a carry-over; since mig 20260927010000 it no longer
--     limits who redeems it, so this keeps it off the guest path) and a code
--     for a hidden ticket type answer 'sign in required': those stay with
--     accounts, as exos-checkout already refuses a guest's bypass code.
-- Nothing else changes: exos_check_voucher's own checks, the drop-list marker
-- patch (/* exos: drop list code */) and every grant stay as they were.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ROLLBACK (manual): DROP FUNCTION public.exos_check_voucher_guest(uuid, text, text);
--   re-run 20260929010000's exos_voucher_throttle body (the index can stay).
-- ============================================================================

-- The 1-day sweep reads by window_start.
CREATE INDEX IF NOT EXISTS exos_voucher_attempts_window_idx ON public.exos_voucher_attempts (window_start);

-- p_failed NULL: may this caller look a code up now? true/false: record the
-- outcome (only failures count). Windows are 10 minutes. Signed-in accounts
-- get 10 misses; anonymous callers share 60 per event, the server
-- (exos-checkout, which has its own per-network limit) 120 per event. A guest
-- through the server (exos_check_voucher_guest sets exos.voucher_guest) is
-- passed through here: that function reserves and settles the attempt itself.
CREATE OR REPLACE FUNCTION public.exos_voucher_throttle(p_event_id uuid, p_failed boolean DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_role   text := coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                            nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
  v_bucket text;
  v_limit  int;
  v_win    timestamptz := to_timestamp(floor(extract(epoch FROM now()) / 600) * 600);
  v_n      int;
BEGIN
  IF v_uid IS NOT NULL THEN
    v_bucket := 'u:' || v_uid; v_limit := 10;
  ELSIF v_role = 'service_role'
        AND coalesce(current_setting('exos.voucher_guest', true), '') ~ '^[0-9a-f]{64}$' THEN
    -- exos: guest codes (mig 20261121143700): already reserved by the caller.
    RETURN true;
  ELSIF v_role = 'service_role' THEN
    v_bucket := 's:' || p_event_id; v_limit := 120;
  ELSE
    v_bucket := 'a:' || p_event_id; v_limit := 60;
  END IF;
  IF p_failed IS NULL THEN
    SELECT failures INTO v_n FROM public.exos_voucher_attempts WHERE bucket = v_bucket AND window_start = v_win;
    RETURN coalesce(v_n, 0) < v_limit;
  END IF;
  IF p_failed THEN
    INSERT INTO public.exos_voucher_attempts (bucket, window_start, failures) VALUES (v_bucket, v_win, 1)
    ON CONFLICT (bucket, window_start) DO UPDATE SET failures = public.exos_voucher_attempts.failures + 1;
    -- Old windows go now and then (one call in ~100), as exos_rate_hit.
    IF random() < 0.01 THEN
      DELETE FROM public.exos_voucher_attempts WHERE window_start < now() - interval '1 day';
    END IF;
  END IF;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_voucher_throttle(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- A guest's code, checked for exos-checkout (service role). p_net_hash is the
-- salted SHA-256 of the request's network (_shared/guest.ts hashIp). Returns
-- exos_check_voucher's row plus what the code takes off; never an email check.
CREATE OR REPLACE FUNCTION public.exos_check_voucher_guest(p_event_id uuid, p_code text, p_net_hash text)
RETURNS TABLE (is_valid boolean, voucher_id uuid, restrict_tier_id uuid, can_bypass boolean,
               override_price numeric, discount_percent numeric, discount_amount numeric, reason text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_net   CONSTANT int := 10;   -- misses per network per 10 minutes (all events)
  c_event CONSTANT int := 30;   -- misses per event per 10 minutes (all guests)
  v_win   timestamptz := to_timestamp(floor(extract(epoch FROM now()) / 600) * 600);
  v_net   text := 'g:' || p_net_hash;
  v_ev    text := 'ge:' || p_event_id;
  v_n     int;
  r       record;
  v_hid   boolean;
  v_mine  boolean;
  v_pct   numeric;
  v_amt   numeric;
BEGIN
  IF p_net_hash IS NULL OR p_net_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'exos_check_voucher_guest: network hash required' USING ERRCODE = '22023';
  END IF;
  IF auth.uid() IS NOT NULL THEN
    -- A signed-in caller has its own bucket; this path is for guests only.
    RAISE EXCEPTION 'exos_check_voucher_guest: guests only' USING ERRCODE = '42501';
  END IF;
  -- Only a published event takes guest codes; any other id writes nothing.
  IF p_event_id IS NULL OR coalesce(btrim(p_code), '') = ''
     OR NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.status = 'published') THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, NULL::numeric, NULL::numeric,
                        'invalid code'::text;
    RETURN;
  END IF;

  -- Reserve the attempt first, one atomic statement per bucket: the network,
  -- then (only if the network still has room) the event.
  INSERT INTO public.exos_voucher_attempts (bucket, window_start, failures) VALUES (v_net, v_win, 1)
  ON CONFLICT (bucket, window_start) DO UPDATE SET failures = public.exos_voucher_attempts.failures + 1
  RETURNING failures INTO v_n;
  IF v_n > c_net THEN
    UPDATE public.exos_voucher_attempts SET failures = failures - 1 WHERE bucket = v_net AND window_start = v_win;
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, NULL::numeric, NULL::numeric,
                        'too many attempts'::text;
    RETURN;
  END IF;
  INSERT INTO public.exos_voucher_attempts (bucket, window_start, failures) VALUES (v_ev, v_win, 1)
  ON CONFLICT (bucket, window_start) DO UPDATE SET failures = public.exos_voucher_attempts.failures + 1
  RETURNING failures INTO v_n;
  IF v_n > c_event THEN
    UPDATE public.exos_voucher_attempts SET failures = failures - 1
     WHERE bucket IN (v_net, v_ev) AND window_start = v_win;
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, NULL::numeric, NULL::numeric,
                        'too many attempts'::text;
    RETURN;
  END IF;
  IF random() < 0.01 THEN
    DELETE FROM public.exos_voucher_attempts WHERE window_start < now() - interval '1 day';
  END IF;

  -- The lookup itself (exos_voucher_throttle passes a reserved guest through).
  PERFORM set_config('exos.voucher_guest', p_net_hash, true);
  SELECT * INTO r FROM public.exos_check_voucher(p_event_id, p_code, NULL);
  PERFORM set_config('exos.voucher_guest', '', true);
  IF NOT coalesce(r.is_valid, false) THEN
    -- Invalid, expired, already used: the attempt stays spent.
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, NULL::numeric, NULL::numeric,
                        coalesce(r.reason, 'invalid code');
    RETURN;
  END IF;
  SELECT coalesce(t.visibility, 'public') <> 'public' INTO v_hid
    FROM public.exos_ticket_tiers t WHERE t.id = r.restrict_tier_id;
  SELECT v.reserved_email IS NOT NULL INTO v_mine FROM public.exos_vouchers v WHERE v.id = r.voucher_id;
  IF r.can_bypass IS TRUE OR coalesce(v_hid, false) OR coalesce(v_mine, false) THEN
    -- Kept for accounts; it says a code exists, so it costs the attempt too.
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, NULL::numeric, NULL::numeric,
                        'sign in required'::text;
    RETURN;
  END IF;
  -- A usable code: the attempt is given back.
  UPDATE public.exos_voucher_attempts SET failures = greatest(failures - 1, 0)
   WHERE bucket IN (v_net, v_ev) AND window_start = v_win;
  SELECT v.discount_percent, v.discount_amount INTO v_pct, v_amt FROM public.exos_vouchers v WHERE v.id = r.voucher_id;
  RETURN QUERY SELECT true, r.voucher_id, r.restrict_tier_id, false, r.override_price, v_pct, v_amt, NULL::text;
END $$;
REVOKE ALL ON FUNCTION public.exos_check_voucher_guest(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_check_voucher_guest(uuid, text, text) TO service_role;
