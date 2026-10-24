-- ============================================================================
-- Growth P1s: promo-link limits held, SMS consent / caps / quiet hours /
-- retries / STOP words, ad-conversions cron, one attribution per order,
-- abandoned-checkout link keeps the code and the referral
-- ============================================================================
-- Touches:  W: TABLE exos_cart_holds (+ voucher_id)
--           C: FUNCTION exos_voucher_in_flight, exos_voucher_uses_left
--              (service role), _exos_hold_voucher (internal), _exos_sms_tz
--           P: exos_create_hold, exos_create_guest_hold (a code's live holds
--              count against its limit; the hold records the code)
--           P: exos_sms_audience, exos_sms_create_campaign (dry runs don't
--              count toward the 8-per-30-days cap)
--           R: exos_sms_opt_in (no taking over a number another account
--              signed up, or one that texted STOP), exos_sms_claim (quiet
--              hours again at send time, in the recipient's zone; gives up
--              after 5 tries), exos_sms_mark (backoff, 5 tries then failed),
--              exos_sms_inbound (STOP said in more ways)
--           C: TRIGGER exos_tickets_attribution_precedence (a promoter's order
--              earns no fan referral)
--           P: exos_pc_accrue_ticket (no commission on the promoter's own
--              purchase), exos_send_checkout_reminders (link keeps coupon=
--              and ref=)
--           C: cron.schedule (exos-conversions-drain-5min, when pg_cron present)
-- Pre-reqs: 20261016110000 (promo links), 20261016120000 (SMS),
--           20260930100000 (ad conversions), 20260926020000 (commissions),
--           20260926060000 (abandoned checkout), 20260929030000 (holds)
--
-- Promo links: max_uses was checked against used_count only, which moves at
-- fulfillment, so every buyer who reached Stripe inside the same 30 minutes
-- saw the full limit: 3 paid for a 2-use link and the 3rd was refunded. A
-- hold now carries its voucher, and a new hold is refused when used +
-- live holds (+ open checkouts that skipped the hold: capacity-bypass codes)
-- + this one would pass the limit. Expired holds stop counting at once.
--
-- SMS: test campaigns in dry run used up the 30-day cap; a signed-in stranger
-- could re-point someone's number at their own account (and so cancel its
-- opt-out); a campaign queued for 9:00 New York went out at 6:00 in LA, or
-- hours late after a retry; a provider 429 / 5xx was retried every 5 minutes
-- forever; "Stop please" and "No more texts" were ignored.
--
-- Cron: exos-conversions-drain had no job on prod. Scheduled here like the
-- SMS drain (cron.* changes reach prod only when the operator applies this).
--
-- Re-run safe. Prod apply needs operator OK.
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
-- 1. Promo-link (voucher) limits count live holds
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_cart_holds
  ADD COLUMN IF NOT EXISTS voucher_id uuid REFERENCES public.exos_vouchers (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS exos_cart_holds_live_voucher_idx
  ON public.exos_cart_holds (voucher_id) WHERE status = 'active' AND voucher_id IS NOT NULL;

-- Tickets a code has promised but not yet used: live holds carrying it, plus
-- open checkouts with it that have no hold (capacity-bypass codes skip the
-- hold; 30 minutes = the hold and the Stripe session). The buyer's own holds
-- and checkouts are left out: a new checkout replaces them.
CREATE OR REPLACE FUNCTION public.exos_voucher_in_flight(p_voucher_id uuid, p_buyer_uid uuid DEFAULT NULL, p_email text DEFAULT NULL)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT (SELECT coalesce(sum(h.quantity), 0)::int FROM public.exos_cart_holds h
           WHERE h.voucher_id = p_voucher_id AND h.status = 'active' AND h.expires_at > now()
             AND NOT (h.buyer_uid IS NOT DISTINCT FROM p_buyer_uid
                      AND (p_buyer_uid IS NOT NULL OR (nullif(btrim(p_email), '') IS NOT NULL
                                                   AND lower(coalesce(h.buyer_email, '')) = lower(btrim(p_email))))))
       + (SELECT coalesce(sum(s.quantity), 0)::int FROM public.exos_checkout_sessions s
           WHERE s.voucher_id = p_voucher_id AND s.status = 'pending'
             AND s.created_at > now() - interval '30 minutes'
             AND NOT EXISTS (SELECT 1 FROM public.exos_cart_holds h WHERE h.checkout_session_id = s.session_id)
             AND NOT (s.buyer_uid IS NOT DISTINCT FROM p_buyer_uid
                      AND (p_buyer_uid IS NOT NULL OR (nullif(btrim(p_email), '') IS NOT NULL
                                                   AND lower(coalesce(s.buyer_email, '')) = lower(btrim(p_email))))))
$$;
REVOKE ALL ON FUNCTION public.exos_voucher_in_flight(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_voucher_in_flight(uuid, uuid, text) TO service_role;

-- exos-checkout: how many more tickets this buyer can buy with the code now.
CREATE OR REPLACE FUNCTION public.exos_voucher_uses_left(p_voucher_id uuid, p_buyer_uid uuid DEFAULT NULL, p_email text DEFAULT NULL)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT greatest(v.max_uses - v.used_count - public.exos_voucher_in_flight(v.id, p_buyer_uid, p_email), 0)
    FROM public.exos_vouchers v WHERE v.id = p_voucher_id
$$;
REVOKE ALL ON FUNCTION public.exos_voucher_uses_left(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_voucher_uses_left(uuid, uuid, text) TO service_role;

-- Inside a hold: lock the code, refuse if this hold would pass its limit, and
-- return its id for the hold row. No code (or one that doesn't match) -> NULL;
-- whether the code is valid at all is exos_check_voucher's job.
CREATE OR REPLACE FUNCTION public._exos_hold_voucher(p_event_id uuid, p_code text, p_quantity integer, p_buyer_uid uuid, p_email text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v public.exos_vouchers%ROWTYPE; v_left int;
BEGIN
  IF nullif(btrim(coalesce(p_code, '')), '') IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v FROM public.exos_vouchers
   WHERE event_id = p_event_id AND upper(code) = upper(btrim(p_code))
   FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_left := v.max_uses - v.used_count - public.exos_voucher_in_flight(v.id, p_buyer_uid, p_email);
  IF v_left < p_quantity THEN
    RAISE EXCEPTION 'exos_create_hold: this code covers % more ticket(s) right now', greatest(v_left, 0)
      USING ERRCODE = '23514';
  END IF;
  RETURN v.id;
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_voucher(uuid, text, integer, uuid, text) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch_n('public.exos_create_hold(uuid, uuid, integer, integer, text)', '/* voucher hold */',
  'INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, expires_at)
  VALUES (p_event_id, p_tier_id, v_org, v_uid, NULLIF(v_email, ''''), p_quantity, now() + make_interval(secs => v_ttl))',
  '-- A code''s limit counts live holds (mig 20261021140000). /* voucher hold */
  INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, expires_at, voucher_id)
  VALUES (p_event_id, p_tier_id, v_org, v_uid, NULLIF(v_email, ''''), p_quantity, now() + make_interval(secs => v_ttl),
          public._exos_hold_voucher(p_event_id, p_voucher_code, p_quantity, v_uid, NULLIF(v_email, '''')))', 1);

SELECT pg_temp.exos_patch_n('public.exos_create_guest_hold(uuid, uuid, integer, text, text, text)', '/* voucher hold */',
  'INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, buyer_email, ip_hash, quantity, expires_at)
  VALUES (p_event_id, p_tier_id, v_org, NULL, v_email, v_ip, p_quantity, now() + interval ''30 minutes'')',
  '-- A code''s limit counts live holds (mig 20261021140000). /* voucher hold */
  INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, buyer_email, ip_hash, quantity, expires_at, voucher_id)
  VALUES (p_event_id, p_tier_id, v_org, NULL, v_email, v_ip, p_quantity, now() + interval ''30 minutes'',
          public._exos_hold_voucher(p_event_id, p_voucher_code, p_quantity, NULL, v_email))', 1);

-- ---------------------------------------------------------------------------
-- 2. SMS
-- ---------------------------------------------------------------------------
-- Dry runs never reached anyone: they don't count toward the cap.
SELECT pg_temp.exos_patch_n('public.exos_sms_audience(uuid, text, uuid)', '/* dry runs don''t count */',
  'o.status IN (''queued'', ''sending'', ''sent'', ''dry_run'')',
  'o.status IN (''queued'', ''sending'', ''sent'') /* dry runs don''t count */', 1);
SELECT pg_temp.exos_patch_n('public.exos_sms_create_campaign(uuid, text, text, uuid, timestamp with time zone)', '/* dry runs don''t count */',
  'o.status IN (''queued'', ''sending'', ''sent'', ''dry_run'')',
  'o.status IN (''queued'', ''sending'', ''sent'') /* dry runs don''t count */', 1);

-- Opt in. A number already signed up from another account, or one that
-- texted STOP, isn't moved to this account: whoever has the phone texts
-- START from it instead (exos_sms_inbound), so nobody can sign up someone
-- else's number over them or undo their STOP.
CREATE OR REPLACE FUNCTION public.exos_sms_opt_in(
  p_org_id uuid, p_phone text, p_consent_text text, p_event_id uuid DEFAULT NULL, p_source text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_phone text := public.exos_sms_normalize_phone(p_phone);
  v_text  text := btrim(coalesce(p_consent_text, ''));
  v_owner uuid;
  v_out   timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_sms_opt_in: sign in first' USING ERRCODE = '42501';
  END IF;
  IF v_phone IS NULL THEN
    RAISE EXCEPTION 'exos_sms_opt_in: enter a mobile number, e.g. +1 212 555 0100' USING ERRCODE = '22023';
  END IF;
  IF length(v_text) < 20 OR length(v_text) > 600 OR v_text !~* 'stop' THEN
    RAISE EXCEPTION 'exos_sms_opt_in: missing consent text' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org_id) THEN
    RAISE EXCEPTION 'exos_sms_opt_in: organizer not found' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_sms_subscribers WHERE user_id = v_uid AND updated_at > now() - interval '1 day') >= 10 THEN
    RAISE EXCEPTION 'exos_sms_opt_in: too many sign-ups today' USING ERRCODE = '54000';
  END IF;
  SELECT s.user_id, s.opted_out_at INTO v_owner, v_out
    FROM public.exos_sms_subscribers s WHERE s.org_id = p_org_id AND s.phone = v_phone
   FOR UPDATE;
  IF FOUND AND v_owner IS DISTINCT FROM v_uid AND (v_owner IS NOT NULL OR v_out IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_sms_opt_in: that number can''t be signed up from this account; text START from the phone itself'
      USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_sms_subscribers AS s (org_id, phone, user_id, source, event_id, consent_text, consented_at, opted_out_at, updated_at)
  VALUES (p_org_id, v_phone, v_uid, left(nullif(btrim(coalesce(p_source, '')), ''), 40), p_event_id, v_text, now(), NULL, now())
  ON CONFLICT (org_id, phone) DO UPDATE
     SET user_id = EXCLUDED.user_id, source = EXCLUDED.source, event_id = coalesce(EXCLUDED.event_id, s.event_id),
         consent_text = EXCLUDED.consent_text, consented_at = now(), opted_out_at = NULL, updated_at = now();
  RETURN jsonb_build_object('subscribed', true, 'phone', v_phone);
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_opt_in(uuid, text, text, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_sms_opt_in(uuid, text, text, uuid, text) TO authenticated, service_role;

-- A time zone name Postgres knows, else New York (a bad name must not stop the drain).
CREATE OR REPLACE FUNCTION public._exos_sms_tz(p_tz text)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF nullif(p_tz, '') IS NULL THEN RETURN 'America/New_York'; END IF;
  PERFORM now() AT TIME ZONE p_tz;
  RETURN p_tz;
EXCEPTION WHEN others THEN
  RETURN 'America/New_York';
END $$;
REVOKE ALL ON FUNCTION public._exos_sms_tz(text) FROM PUBLIC, anon, authenticated;

-- Due messages with a 2-minute lease. Last checks before sending: a number
-- that opted out since queuing is skipped; one outside 9:00-20:00 where the
-- recipient is (the campaign's event, else the event they signed up at, else
-- New York) waits for 9:00 there; a row whose lease ran out 5 times is failed.
CREATE OR REPLACE FUNCTION public.exos_sms_claim(p_limit int DEFAULT 50)
RETURNS TABLE (id uuid, org_id uuid, provider text, phone text, body text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_sms_outbox o SET status = 'skipped', error = 'opted out'
   WHERE o.status = 'queued' AND o.send_after <= now()
     AND EXISTS (SELECT 1 FROM public.exos_sms_subscribers s
                  WHERE s.org_id = o.org_id AND s.phone = o.phone AND s.opted_out_at IS NOT NULL);
  UPDATE public.exos_sms_outbox o SET status = 'failed', error = 'gave up after 5 attempts', lease_until = NULL
   WHERE o.status = 'sending' AND o.lease_until < now() AND o.attempts >= 5;
  UPDATE public.exos_sms_outbox o
     SET send_after = (date_trunc('day', z.loc)
                       + CASE WHEN z.loc::time < time '09:00' THEN interval '9 hours' ELSE interval '1 day 9 hours' END)
                      AT TIME ZONE z.tz
    FROM (SELECT o2.id, x.tz, now() AT TIME ZONE x.tz AS loc
            FROM public.exos_sms_outbox o2
            JOIN public.exos_sms_campaigns c ON c.id = o2.campaign_id
            LEFT JOIN public.exos_events ce ON ce.id = c.event_id
            LEFT JOIN public.exos_sms_subscribers s ON s.org_id = o2.org_id AND s.phone = o2.phone
            LEFT JOIN public.exos_events se ON se.id = s.event_id
           CROSS JOIN LATERAL (SELECT public._exos_sms_tz(coalesce(nullif(ce.timezone, ''), se.timezone)) AS tz) x
           WHERE (o2.status = 'queued' OR (o2.status = 'sending' AND o2.lease_until < now()))
             AND o2.send_after <= now()) z
   WHERE o.id = z.id AND (z.loc::time < time '09:00' OR z.loc::time >= time '20:00');
  RETURN QUERY
  WITH due AS (
    SELECT o.id FROM public.exos_sms_outbox o
      JOIN public.exos_sms_campaigns c ON c.id = o.campaign_id AND c.status IN ('queued', 'sending')
     WHERE (o.status = 'queued' OR (o.status = 'sending' AND o.lease_until < now() AND o.attempts < 5))
       AND o.send_after <= now()
     ORDER BY o.send_after
     LIMIT greatest(1, least(coalesce(p_limit, 50), 200))
     FOR UPDATE OF o SKIP LOCKED
  )
  UPDATE public.exos_sms_outbox o
     SET status = 'sending', attempts = o.attempts + 1, lease_until = now() + interval '2 minutes'
    FROM due, public.exos_sms_campaigns c
   WHERE o.id = due.id AND c.id = o.campaign_id
  RETURNING o.id, o.org_id, c.provider, o.phone, o.body;
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_claim(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_claim(int) TO service_role;

-- 'queued' = try again (provider 429 / 5xx): 2, 4, 8, 16 minutes later, and
-- failed on the 5th attempt. The drain's own "out of time" hand-back isn't a
-- try (the message was never sent to the provider).
CREATE OR REPLACE FUNCTION public.exos_sms_mark(p_id uuid, p_status text, p_provider_id text DEFAULT NULL, p_error text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_campaign uuid; v_att int; v_status text := p_status; v_error text := p_error;
BEGIN
  IF p_status NOT IN ('sent', 'dry_run', 'failed', 'queued') THEN
    RAISE EXCEPTION 'exos_sms_mark: bad status' USING ERRCODE = '22023';
  END IF;
  SELECT o.attempts INTO v_att FROM public.exos_sms_outbox o WHERE o.id = p_id AND o.status = 'sending' FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  IF p_status = 'queued' AND p_error = 'out of time' THEN
    v_att := greatest(v_att - 1, 0);
  ELSIF p_status = 'queued' AND v_att >= 5 THEN
    v_status := 'failed';
    v_error := 'gave up after 5 attempts: ' || coalesce(p_error, '');
  END IF;
  UPDATE public.exos_sms_outbox
     SET status = v_status, provider_id = left(p_provider_id, 80), error = left(v_error, 200),
         attempts = v_att,
         sent_at = CASE WHEN v_status IN ('sent', 'dry_run') THEN now() END,
         lease_until = NULL,
         send_after = CASE WHEN v_status = 'queued'
                           THEN now() + least(interval '1 minute' * power(2, greatest(v_att, 1)), interval '1 hour')
                           ELSE send_after END
   WHERE id = p_id
  RETURNING campaign_id INTO v_campaign;
  UPDATE public.exos_sms_campaigns c
     SET status = CASE WHEN EXISTS (SELECT 1 FROM public.exos_sms_outbox o WHERE o.campaign_id = c.id AND o.status IN ('queued', 'sending'))
                       THEN 'sending' ELSE 'sent' END
   WHERE c.id = v_campaign AND c.status IN ('queued', 'sending');
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_mark(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_mark(uuid, text, text, text) TO service_role;

-- Inbound replies (verified by the edge function). Opting out errs on the
-- side of the fan: a STOP word anywhere first ("Stop please", "Unsubscribe
-- me", "cancel"), the usual phrases ("no more texts", "remove me"), or a lone
-- END / ARRET / PARAR. START / UNSTOP / YES opts back in (original consent).
CREATE OR REPLACE FUNCTION public.exos_sms_inbound(p_org_id uuid, p_from text, p_text text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_phone text := public.exos_sms_normalize_phone(p_from);
  v_word  text := upper(btrim(regexp_replace(regexp_replace(
                   translate(coalesce(p_text, ''), 'êÊéÉèÈàÀ''’', 'eEeEeEaA'),
                   '[^A-Za-z ]', ' ', 'g'), '\s+', ' ', 'g')));
  v_first text;
BEGIN
  IF v_phone IS NULL THEN RETURN 'ignored'; END IF;
  v_first := split_part(v_word, ' ', 1);
  IF v_first IN ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'UNSUB', 'CANCEL', 'QUIT', 'OPTOUT', 'REVOKE')
     OR v_word IN ('END', 'ARRET', 'PARAR', 'OPT OUT')
     OR v_word ~ '(^| )(NO MORE TEXTS?|NO MORE MESSAGES|OPT ME OUT|OPT OUT|REMOVE ME|TAKE ME OFF|DONT TEXT|DO NOT TEXT|STOP TEXTING|STOP MESSAGING|UNSUBSCRIBE)( |$)' THEN
    UPDATE public.exos_sms_subscribers SET opted_out_at = coalesce(opted_out_at, now()), updated_at = now()
     WHERE org_id = p_org_id AND phone = v_phone;
    UPDATE public.exos_sms_outbox SET status = 'skipped', error = 'opted out'
     WHERE org_id = p_org_id AND phone = v_phone AND status = 'queued';
    RETURN 'stopped';
  ELSIF v_word IN ('START', 'UNSTOP', 'YES') THEN
    UPDATE public.exos_sms_subscribers SET opted_out_at = NULL, updated_at = now()
     WHERE org_id = p_org_id AND phone = v_phone AND opted_out_at IS NOT NULL;
    RETURN CASE WHEN FOUND THEN 'started' ELSE 'ignored' END;
  ELSIF v_word = 'HELP' OR v_word = 'INFO' THEN
    RETURN 'help';
  END IF;
  RETURN 'ignored';
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_inbound(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_inbound(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. One attribution per order
-- ---------------------------------------------------------------------------
-- Promoter wins: a ticket sold through a real promoter's link earns that
-- promoter's commission and no fan referral credit (both used to pay).
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_attribution_precedence()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.referral_code IS NOT NULL AND NEW.promoter_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.exos_promoters p WHERE p.org_id = NEW.org_id AND p.code = NEW.promoter_id) THEN
    NEW.referral_code := NULL;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_ticket_attribution_precedence() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_attribution_precedence ON public.exos_tickets;
CREATE TRIGGER exos_tickets_attribution_precedence
  BEFORE INSERT OR UPDATE OF referral_code, promoter_id ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_attribution_precedence();

-- No commission on the promoter's own purchase (their email bought it, or the
-- buying account has it).
SELECT pg_temp.exos_patch_n('public.exos_pc_accrue_ticket(uuid)', '/* not their own purchase */',
  '  SELECT * INTO p FROM public.exos_promoters WHERE org_id = t.org_id AND code = t.promoter_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
',
  '  SELECT * INTO p FROM public.exos_promoters WHERE org_id = t.org_id AND code = t.promoter_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF p.email IS NOT NULL AND (lower(coalesce(t.buyer_email, '''')) = lower(p.email)  /* not their own purchase */
      OR EXISTS (SELECT 1 FROM auth.users u WHERE u.id = t.buyer_id AND lower(u.email) = lower(p.email))) THEN
    RETURN false;
  END IF;
', 1);

-- ---------------------------------------------------------------------------
-- 4. Abandoned checkout: the link keeps the code (while it still has uses)
--    and the fan referral
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_send_checkout_reminders(interval, interval, integer)', '/* coupon + ref */',
  's.promoter_id, lower(u.email) AS email,',
  's.promoter_id, s.voucher_id, s.attribution, lower(u.email) AS email, /* coupon + ref */', 1);
SELECT pg_temp.exos_patch_n('public.exos_send_checkout_reminders(interval, interval, integer)', '/* coupon= ref= */',
  '|| CASE WHEN r.promoter_id IS NOT NULL THEN ''&amp;promoter='' || r.promoter_id ELSE '''' END',
  '|| CASE WHEN r.promoter_id IS NOT NULL THEN ''&amp;promoter='' || r.promoter_id ELSE '''' END
              || coalesce((SELECT ''&amp;coupon='' || v.code FROM public.exos_vouchers v  /* coupon= ref= */
                            WHERE v.id = r.voucher_id AND v.code ~ ''^[A-Za-z0-9_-]{1,64}$''
                              AND (v.valid_until IS NULL OR v.valid_until > now())
                              AND v.used_count < v.max_uses), '''')
              || CASE WHEN r.attribution->>''ref'' ~ ''^[a-z0-9]{10}$'' THEN ''&amp;ref='' || (r.attribution->>''ref'') ELSE '''' END', 1);

-- ---------------------------------------------------------------------------
-- 5. Cron: the ad-conversions drain, every 5 minutes (off the :00 / :05
--    marks). Dry run until EXOS_CONVERSIONS_LIVE=true on the function.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-conversions-drain-5min') THEN
      PERFORM cron.unschedule('exos-conversions-drain-5min');
    END IF;
    PERFORM cron.schedule('exos-conversions-drain-5min', '2,7,12,17,22,27,32,37,42,47,52,57 * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        coalesce(nullif(current_setting('app.exos_functions_url', true), ''),
                 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-conversions-drain', '{}'::jsonb);
    $cron$);
  END IF;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos-conversions-drain-5min');
-- DROP TRIGGER exos_tickets_attribution_precedence ON exos_tickets; re-apply
-- 20261016120000's SMS functions and the earlier definitions of the patched
-- functions; drop exos_voucher_in_flight / exos_voucher_uses_left /
-- _exos_hold_voucher / _exos_sms_tz and exos_cart_holds.voucher_id.
