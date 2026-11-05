-- ============================================================================
-- Migration 20261105100000 — Exos: mistake-simulation product decisions (2026-11-04)
-- ============================================================================
-- The four sim branches (buyer / organizer / door / partner) left a set of
-- KNOWN scenarios that needed a product call. These are the calls, each
-- pinned by its SIM-… scenario (now an OK check) in tests/exos/sim_*.sql.
--
-- 1. No unlimited capacity (SIM-ORG-3). Capacity 0 on a ticket type or an
--    add-on used to mean "uncapped"; an organizer who set 0 to stop sales
--    opened them wide. Now 0 means CLOSED: nothing sells. A sellable ticket
--    type or add-on needs a positive capacity. Every path that read 0 as
--    "no limit" is changed: exos_tier_available (0 left), the mints and
--    fulfilment (claims need capacity > 0), add-ons, the partner and
--    marketplace mints, Posh counts, the channel-split "uncapped" checks,
--    and the event-level helpers (exos_event_max_capacity / _remaining /
--    _capacity_bounded: a closed type adds 0). A trigger refuses any sale
--    into a closed type or add-on, so a path this migration missed (or a
--    later redefinition) still can't oversell. The event's total_tickets
--    stays optional: 0 there means "no extra overall cap", which is never
--    unlimited now because the ticket types are always bounded.
--    One-shot data step (first apply only, marked in exos_platform_settings):
--    an upcoming event's capacity-0 type is set to the event's overall cap
--    when it has one; otherwise it is left closed and listed in a NOTICE.
-- 2. A comp batch sent twice issues once (SIM-ORG-10, SIM-DOOR-19).
--    exos_issue_comp_batch(…, p_request_key) (new 6-argument form): the same
--    caller + key returns the first result; a different batch under the same
--    key is refused. With no key (the 5-argument form, old clients, the API
--    without an Idempotency-Key) an identical batch (same event, ticket type,
--    quantity, promoter and email set) by the same caller within 10 minutes
--    returns the first result. Results: exos_comp_batch_requests.
-- 3. A name that is (or contains) an email is refused (SIM-ORG-14): guest
--    imports (and their preview), guest adds and edits, promoter adds,
--    ticket attendee names (buyer and organizer edits), order buyer names
--    (order edits), the waitlist and phone RSVP. (Comps and guest checkout
--    take an email only; the attendee names on their tickets go through
--    exos_set_ticket_attendee / exos_ticket_update.) Import rows report it as invalid: "name looks like an
--    email; are your columns swapped?". One SQL helper (exos_name_has_email),
--    one TS helper (supabase/functions/_shared/nameGuard.ts).
-- 4. A checkout hold outlives Stripe's session (SIM-BUYER-8). The session
--    row now records the processor's expires_at (provider_expires_at, set
--    by exos-checkout); linking a hold to a session keeps it until that
--    moment + 10 minutes (Stripe sessions without the column: created_at +
--    30 minutes + 10). A late checkout.session.completed therefore never
--    finds its seat in someone else's live hold. When the session expires
--    (checkout.session.expired) its hold is released at once.
-- 5. Proof of email or phone before a guest's tickets are released
--    (SIM-BUYER-12/13). Who: guests, and a signed-in buyer whose email isn't
--    confirmed (a confirmed account skips it). The order is paid and its
--    seats are kept, but the tickets stay parked on the organizer (as
--    before) and are no longer attached to an existing account with that
--    email. exos_order_proofs holds one row per such order (open until the
--    event ends). The buyer proves the email with the 6-digit code mailed to
--    it (or the mail's "confirm here" link, which fills the code in), or a
--    phone by SMS code, on the page they paid on: a 256-bit browser token
--    from exos-checkout, stored hashed on the session, gates every proof
--    call, so the code in a mistyped inbox does nothing. Until proven, the
--    parked tickets don't scan (in transfer), can't be claimed (not even by
--    the account that owns the typed email, link or no link), the organizer
--    can't cancel their parked transfers (resend instead), and they are
--    nobody's; door staff can still check the buyer in by name. Proven: a
--    signed-in buyer's own account gets them; a guest's by email: an
--    account with that email, else the claim links are mailed; by phone:
--    the claim links are on the page. The organizer can send an order to a
--    corrected email from the Orders page (exos_order_proof_resend). The
--    order's email counts as the payer's (receipts, refund asks, reschedule
--    offers) only once proven (_exos_guest_email_ok).
--    Limits: 5 wrong codes lock the live code; 5 email and 3 SMS sends per
--    order, 60 s apart per channel; 3 SMS per number per 10 minutes.
-- 6. Waitlist (SIM-BUYER-26). A buyer who gets a ticket (any channel) while
--    on the waitlist is marked converted; an outstanding offer to them is
--    retired and passed to the next in line (unless they bought with it).
-- 7. Small ones:
--    a. A forced offline admission marks the ticket used (SIM-DOOR-16) for
--       wrong-list / invalid-time / doors-not-open / too-old on an active
--       ticket with no pending transfer; the conflict row stays.
--    b. Phone RSVP with a plus-one at the last seat answers not_enough_seats
--       with seats_left (SIM-BUYER-31).
--    c. A monthly donation whose card fails: one "update your card" mail per
--       failure streak (SIM-BUYER-34).
--    d. An imported code typed without its punctuation (EB12345678 for
--       EB-1234 5678) matches when there is no exact hit and exactly one
--       loose match (SIM-DOOR-9): exos_door_code_lookup.
--
-- Touches:  W: FUNCTION exos_tier_available, exos_claim_free_tickets,
--              exos_claim_free_addons, exos_fulfill_checkout, exos_issue_ticket_to_email,
--              exos_mint_tickets, exos_redeem_referral_reward, exos_fulfil_marketplace_order,
--              exos_issue_comp_batch(5), _exos_partner_reservation_complete,
--              exos_phone_rsvp_verify, exos_phone_rsvp_start, exos_set_channel_allocation,
--              exos_apply_channel_split, exos_set_s4k_split, _exos_posh_count,
--              exos_import_guests, _exos_guest_list_preview, _exos_guest_insert,
--              exos_update_guest, exos_set_ticket_attendee, exos_ticket_update,
--              exos_order_update, exos_cancel_transfer, _exos_refund_ask_payer_ok,
--              _exos_resched_actor_ok, exos_my_reschedule_offers, exos_my_invoices,
--              exos_invoice_document, exos_my_refund_asks (guest email = payer only once proven),
--              exos_join_waitlist, exos_claim_transfer(uuid), exos_api_write,
--              _exos_record_forced_checkin (all patched in place, marker-checked)
--           W: FUNCTION exos_event_max_capacity, exos_event_remaining,
--              exos_event_capacity_bounded (redefined, same signatures)
--           W: TABLE exos_checkout_sessions (+ provider_expires_at, proof_token_hash)
--           C: TABLE exos_comp_batch_requests, exos_order_proofs
--           C: FUNCTION exos_issue_comp_batch(6), exos_name_has_email,
--              exos_order_proof_status / _send / _verify (anon, token-gated),
--              exos_order_proof_resend, exos_org_order_proofs (owner / manager),
--              exos_door_code_lookup (door staff), _exos_door_code_loose,
--              _exos_proof_* / _exos_uid_email_confirmed / _exos_waitlist_convert
--              (internal), triggers (capacity backstop, hold grace, expired
--              session release, proof close, waitlist convert, donation mail)
-- Callers:  exos-checkout (Stripe expires_at, provider_expires_at, proof
--           token), the SPA (comp request key, proof step, Orders resend),
--           exos-commerce (recurring_donation_portal for the card mail).
-- Pre-reqs: every exos migration before this one.
-- Re-run safe: marker-checked patches (pg_temp.exos_patch_n), CREATE OR
-- REPLACE, IF NOT EXISTS, DROP TRIGGER IF EXISTS; the data step runs once.
-- D4 authors; not applied.
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
-- 1. Capacity 0 is closed, never unlimited.
-- ===========================================================================

-- 1a. One-shot data step (prod had 1 tier and none at 0 when this was written).
DO $d$
DECLARE r record; v_fixed int := 0; v_closed text[] := '{}';
BEGIN
  IF EXISTS (SELECT 1 FROM public.exos_platform_settings WHERE key = 'capacity_zero_is_closed') THEN
    RETURN;
  END IF;
  FOR r IN
    SELECT t.id, t.name, t.sold, e.id AS event_id, e.name AS event_name, e.total_tickets
      FROM public.exos_ticket_tiers t
      JOIN public.exos_events e ON e.id = t.event_id
     WHERE t.capacity = 0 AND e.status <> 'cancelled'
       AND (e.starts_at IS NULL OR e.starts_at > now() - interval '1 day')
  LOOP
    IF coalesce(r.total_tickets, 0) > 0 THEN
      UPDATE public.exos_ticket_tiers SET capacity = greatest(r.sold, r.total_tickets) WHERE id = r.id;
      v_fixed := v_fixed + 1;
    ELSE
      v_closed := array_append(v_closed, r.event_name || ' / ' || r.name || ' (' || r.id || ')');
    END IF;
  END LOOP;
  IF v_fixed > 0 THEN
    RAISE NOTICE 'exos capacity: % upcoming ticket type(s) at 0 set to their event''s overall cap', v_fixed;
  END IF;
  IF cardinality(v_closed) > 0 THEN
    RAISE NOTICE 'exos capacity: now closed (0, no overall cap to copy): %', array_to_string(v_closed, '; ');
  END IF;
  SELECT array_agg(a.id::text) INTO v_closed FROM public.exos_event_addons a JOIN public.exos_events e ON e.id = a.event_id
   WHERE a.capacity = 0 AND e.status <> 'cancelled' AND (e.starts_at IS NULL OR e.starts_at > now() - interval '1 day');
  IF v_closed IS NOT NULL THEN
    RAISE NOTICE 'exos capacity: add-ons at 0, now closed: %', array_to_string(v_closed, ', ');
  END IF;
  INSERT INTO public.exos_platform_settings (key, value)
  VALUES ('capacity_zero_is_closed', to_jsonb(now()::text))
  ON CONFLICT (key) DO NOTHING;
END $d$;

-- 1b. Availability: a closed type has 0 left.
SELECT pg_temp.exos_patch_n('public.exos_tier_available(uuid)',
  '/* exos: capacity 0 is closed */',
  $o$WHEN t.capacity = 0 THEN NULL                       -- uncapped$o$,
  $n$WHEN t.capacity <= 0 THEN 0 /* exos: capacity 0 is closed */$n$, 1);

-- 1c. The claims: "capacity = 0 OR sold + n <= capacity" becomes
-- "capacity > 0 AND sold + n <= capacity" everywhere.
DO $p1$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY[
    'public.exos_claim_free_tickets(uuid,uuid,integer,text,text,text)',
    'public.exos_claim_free_addons(uuid,text,jsonb)',
    'public.exos_issue_ticket_to_email(uuid,uuid,text,integer,text)',
    'public.exos_mint_tickets(uuid,uuid,integer,text,numeric,text)',
    'public.exos_redeem_referral_reward(uuid,uuid)',
    'public.exos_fulfil_marketplace_order(uuid,text)',
    'public.exos_issue_comp_batch(uuid,uuid,text[],integer,text)',
    'public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)',
    'public.exos_phone_rsvp_verify(uuid,text,text)',
    'public.exos_fulfill_checkout(text)'] LOOP
    PERFORM pg_temp.exos_patch_n(s, '/* exos: cap0 closed */',
      '(capacity = 0 OR sold + ', '(capacity > 0 /* exos: cap0 closed */ AND sold + ', 1);
  END LOOP;
END $p1$;
-- A bypass voucher may go past a capacity, never into a closed type.
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)',
  '/* exos: bypass not closed */',
  '(v_bypass OR capacity = 0 OR sold + s.quantity <= capacity)',
  '(capacity > 0 /* exos: bypass not closed */ AND (v_bypass OR sold + s.quantity <= capacity))', 1);

-- 1d. Channel splits: no type is "uncapped" any more.
DO $p2$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY[
    'public.exos_set_channel_allocation(uuid,text,uuid,integer)',
    'public.exos_apply_channel_split(uuid)',
    'public.exos_set_s4k_split(uuid,jsonb)'] LOOP
    PERFORM pg_temp.exos_patch_n(s, '/* exos: no uncapped types */',
      'bool_or(capacity = 0)', 'bool_or(capacity < 0) /* exos: no uncapped types */', 1);
  END LOOP;
END $p2$;

-- 1e. Posh counts into a closed type take no room.
SELECT pg_temp.exos_patch_n('public._exos_posh_count(uuid)',
  '/* exos: closed has no room */',
  'v_room := CASE WHEN t.capacity > 0 THEN greatest(t.capacity - t.sold, 0) ELSE o.quantity END;',
  'v_room := CASE WHEN t.capacity > 0 THEN greatest(t.capacity - t.sold, 0) ELSE 0 /* exos: closed has no room */ END;', 1);

-- 1f. Event-level helpers: a closed type adds 0; never "no limit".
CREATE OR REPLACE FUNCTION public.exos_event_max_capacity(p_event_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  -- mig 20261105100000: capacity 0 is closed (adds 0), never uncapped.
  SELECT CASE
           WHEN coalesce(e.total_tickets, 0) > 0
             THEN least(e.total_tickets, coalesce(sum(greatest(t.capacity, 0) * CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) ELSE 1 END), 0))::int
           ELSE coalesce(sum(greatest(t.capacity, 0) * CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) ELSE 1 END), 0)::int
         END
    FROM public.exos_events e
    LEFT JOIN public.exos_ticket_tiers t ON t.event_id = e.id
   WHERE e.id = p_event_id
   GROUP BY e.id, e.total_tickets
$$;

CREATE OR REPLACE FUNCTION public.exos_event_capacity_bounded(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  -- mig 20261105100000: every ticket type is bounded (0 = closed), so an
  -- event is bounded as soon as it exists.
  SELECT true FROM public.exos_events e WHERE e.id = p_event_id
$$;

CREATE OR REPLACE FUNCTION public.exos_event_remaining(p_event_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  -- mig 20261105100000: the ticket types' room (closed = 0), under the
  -- overall cap when there is one. Never NULL ("no limit") for an event.
  SELECT CASE
           WHEN coalesce(e.total_tickets, 0) > 0
             THEN least(greatest(e.total_tickets - coalesce(e.tickets_sold, 0), 0),
                        coalesce(sum(greatest(t.capacity - t.sold, 0)
                            * CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) ELSE 1 END), 0))::int
           ELSE coalesce(sum(greatest(t.capacity - t.sold, 0)
                    * CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) ELSE 1 END), 0)::int
         END
    FROM public.exos_events e
    LEFT JOIN public.exos_ticket_tiers t ON t.event_id = e.id
   WHERE e.id = p_event_id
   GROUP BY e.id, e.total_tickets, e.tickets_sold
$$;

-- 1g. The backstop: no sale into a closed ticket type or add-on.
CREATE OR REPLACE FUNCTION public.exos_tg_capacity_closed()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.sold > OLD.sold AND NEW.capacity <= 0 THEN
    RAISE EXCEPTION 'exos: "%" is closed (capacity 0), so it is sold out', coalesce(NEW.name, 'this ticket type')
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_capacity_closed() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_ticket_tiers_capacity_closed ON public.exos_ticket_tiers;
CREATE TRIGGER exos_ticket_tiers_capacity_closed BEFORE UPDATE OF sold ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_capacity_closed();
DROP TRIGGER IF EXISTS exos_event_addons_capacity_closed ON public.exos_event_addons;
CREATE TRIGGER exos_event_addons_capacity_closed BEFORE UPDATE OF sold ON public.exos_event_addons
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_capacity_closed();

COMMENT ON COLUMN public.exos_ticket_tiers.capacity IS
  'Tickets this type may sell (tables for a table type). 0 = closed: nothing sells (mig 20261105100000); never unlimited.';
COMMENT ON COLUMN public.exos_event_addons.capacity IS
  'Units this add-on may sell. 0 = closed (mig 20261105100000); never unlimited.';

-- ===========================================================================
-- 2. A comp batch sent twice issues once.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_comp_batch_requests (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs(id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events(id) ON DELETE CASCADE,
  caller      uuid NOT NULL,
  request_key text CHECK (request_key IS NULL OR request_key ~ '^[A-Za-z0-9_.:-]{8,200}$'),
  fingerprint text NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
  results     jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_comp_batch_requests_key_uq
  ON public.exos_comp_batch_requests (caller, request_key) WHERE request_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_comp_batch_requests_fp_idx
  ON public.exos_comp_batch_requests (caller, fingerprint, created_at);
CREATE INDEX IF NOT EXISTS exos_comp_batch_requests_event_idx ON public.exos_comp_batch_requests (event_id);
ALTER TABLE public.exos_comp_batch_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_comp_batch_requests_staff_read ON public.exos_comp_batch_requests;
CREATE POLICY exos_comp_batch_requests_staff_read ON public.exos_comp_batch_requests
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_comp_batch_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_comp_batch_requests TO authenticated;
GRANT ALL ON public.exos_comp_batch_requests TO service_role;
DROP TRIGGER IF EXISTS exos_comp_batch_requests_touch ON public.exos_comp_batch_requests;
CREATE TRIGGER exos_comp_batch_requests_touch BEFORE UPDATE ON public.exos_comp_batch_requests
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- The keyed form. The 5-argument form forwards here (no key), so every call
-- goes through the guard; the guard runs the 5-argument body as the inner call.
CREATE OR REPLACE FUNCTION public.exos_issue_comp_batch(
  p_event_id uuid, p_tier_id uuid, p_emails text[], p_qty_each integer, p_promoter_id text, p_request_key text)
RETURNS TABLE(email text, outcome text, ticket_ids uuid[], detail text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_org  uuid;
  v_key  text := nullif(btrim(coalesce(p_request_key, '')), '');
  v_fp   text;
  v_prev public.exos_comp_batch_requests%ROWTYPE;
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF v_key IS NOT NULL AND v_key !~ '^[A-Za-z0-9_.:-]{8,200}$' THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: request key must be 8-200 letters, digits, _ . : or -' USING ERRCODE = '22023';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: event not found';
  END IF;
  -- What makes two batches "the same": event, type, quantity, promoter and
  -- the set of recipients (trimmed, lower-cased, de-duplicated, sorted).
  v_fp := encode(extensions.digest(concat_ws('|', p_event_id, coalesce(p_tier_id::text, '-'), coalesce(p_qty_each, 1),
            coalesce(nullif(p_promoter_id, ''), '-'),
            (SELECT string_agg(e, ',' ORDER BY e) FROM (SELECT DISTINCT lower(btrim(x)) AS e FROM unnest(coalesce(p_emails, '{}')) x
                                                        WHERE btrim(coalesce(x, '')) <> '') q)), 'sha256'), 'hex');
  -- Serialize this caller's twin submissions (double click, retry, two tabs).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_comp_batch:' || v_uid || ':' || coalesce('k:' || v_key, 'f:' || v_fp), 0));
  IF v_key IS NOT NULL THEN
    SELECT * INTO v_prev FROM public.exos_comp_batch_requests WHERE caller = v_uid AND request_key = v_key;
    IF FOUND AND v_prev.fingerprint <> v_fp THEN
      RAISE EXCEPTION 'exos_issue_comp_batch: this request key was already used for a different batch' USING ERRCODE = '22023';
    END IF;
  ELSE
    SELECT * INTO v_prev FROM public.exos_comp_batch_requests
     WHERE caller = v_uid AND fingerprint = v_fp AND created_at > now() - interval '10 minutes'
     ORDER BY created_at DESC LIMIT 1;
  END IF;
  IF v_prev.id IS NOT NULL THEN
    RETURN QUERY
      SELECT x.email, x.outcome, coalesce(x.ticket_ids, '{}'::uuid[]), x.detail
        FROM jsonb_to_recordset(v_prev.results) AS x(email text, outcome text, ticket_ids uuid[], detail text);
    RETURN;
  END IF;

  PERFORM set_config('exos.comp_batch_inner', 'on', true);
  SELECT coalesce(jsonb_agg(jsonb_build_object('email', r.email, 'outcome', r.outcome,
                                               'ticket_ids', to_jsonb(r.ticket_ids), 'detail', r.detail)), '[]'::jsonb)
    INTO v_rows
    FROM public.exos_issue_comp_batch(p_event_id, p_tier_id, p_emails, p_qty_each, p_promoter_id) r;
  PERFORM set_config('exos.comp_batch_inner', '', true);

  INSERT INTO public.exos_comp_batch_requests (org_id, event_id, caller, request_key, fingerprint, results)
  VALUES (v_org, p_event_id, v_uid, v_key, v_fp, v_rows);
  RETURN QUERY
    SELECT x.email, x.outcome, coalesce(x.ticket_ids, '{}'::uuid[]), x.detail
      FROM jsonb_to_recordset(v_rows) AS x(email text, outcome text, ticket_ids uuid[], detail text);
END $$;
REVOKE ALL ON FUNCTION public.exos_issue_comp_batch(uuid,uuid,text[],integer,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_issue_comp_batch(uuid,uuid,text[],integer,text,text) TO authenticated, service_role;

SELECT pg_temp.exos_patch_n('public.exos_issue_comp_batch(uuid,uuid,text[],integer,text)',
  '/* exos: comp batch guard */',
  $o$  IF p_qty_each < 1 OR p_qty_each > 10 THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: quantity per recipient must be 1-10';$o$,
  $n$  /* exos: comp batch guard */ -- mig 20261105100000: a direct call goes through
  -- the twin-submission guard (the keyed form runs this body as its inner call).
  IF current_setting('exos.comp_batch_inner', true) IS DISTINCT FROM 'on' THEN
    RETURN QUERY SELECT * FROM public.exos_issue_comp_batch(p_event_id, p_tier_id, p_emails, p_qty_each, p_promoter_id, NULL::text);
    RETURN;
  END IF;
  PERFORM set_config('exos.comp_batch_inner', '', true);
  IF p_qty_each < 1 OR p_qty_each > 10 THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: quantity per recipient must be 1-10';$n$, 1);

-- The API passes its Idempotency-Key through (per API key).
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid,text,text,jsonb,text)',
  '/* exos: comp request key */',
  $o$             coalesce((a ->> 'quantity_each')::int, 1), NULL) r;$o$,
  $n$             coalesce((a ->> 'quantity_each')::int, 1), NULL,
             /* exos: comp request key */ CASE WHEN p_idempotency_key IS NOT NULL
                  THEN 'api:' || replace(k.id::text, '-', '') || ':' || p_idempotency_key END) r;$n$, 1);

-- ===========================================================================
-- 3. A name that looks like an email is refused.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_name_has_email(p_name text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  -- Same rule as supabase/functions/_shared/nameGuard.ts nameLooksLikeEmail.
  SELECT coalesce(p_name, '') ~* '[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}'
$$;
GRANT EXECUTE ON FUNCTION public.exos_name_has_email(text) TO anon, authenticated, service_role;

SELECT pg_temp.exos_patch_n('public.exos_import_guests(uuid,jsonb)',
  '/* exos: name is an email */',
  $o$    IF jsonb_typeof(r) <> 'object' OR v_name IS NULL
       OR (nullif(btrim(coalesce(r->>'code', '')), '') IS NOT NULL AND v_code IS NULL) THEN
      v_invalid := v_invalid + 1;
      IF jsonb_array_length(v_errors) < 20 THEN
        v_errors := v_errors || jsonb_build_object('row', i,
          'reason', CASE WHEN v_name IS NULL THEN 'missing name' ELSE 'code too long' END);$o$,
  $n$    IF jsonb_typeof(r) <> 'object' OR v_name IS NULL OR public.exos_name_has_email(v_name) /* exos: name is an email */
       OR (nullif(btrim(coalesce(r->>'code', '')), '') IS NOT NULL AND v_code IS NULL) THEN
      v_invalid := v_invalid + 1;
      IF jsonb_array_length(v_errors) < 20 THEN
        v_errors := v_errors || jsonb_build_object('row', i,
          'reason', CASE WHEN v_name IS NULL THEN 'missing name'
                         WHEN public.exos_name_has_email(v_name) THEN 'name looks like an email; are your columns swapped?'
                         ELSE 'code too long' END);$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_guest_list_preview(uuid,uuid,uuid,jsonb)',
  '/* exos: name is an email */',
  $o$    ELSIF char_length(v_name) > 80 THEN
      v_status := 'invalid'; v_reason := 'name too long';$o$,
  $n$    ELSIF public.exos_name_has_email(v_name) THEN /* exos: name is an email */
      v_status := 'invalid'; v_reason := 'name looks like an email; are your columns swapped?';
    ELSIF char_length(v_name) > 80 THEN
      v_status := 'invalid'; v_reason := 'name too long';$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_guest_insert(uuid,text,text,text,integer,text,uuid,uuid)',
  '/* exos: name is an email */',
  $o$    RAISE EXCEPTION 'exos: add the guest''s name';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos: add the guest''s name';
  END IF;
  IF public.exos_name_has_email(p_guest_name) THEN /* exos: name is an email */
    RAISE EXCEPTION 'exos: name looks like an email; are your columns swapped?' USING ERRCODE = '23514';
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_update_guest(uuid,text,text,text,integer,text)',
  '/* exos: name is an email */',
  $o$    RAISE EXCEPTION 'exos_update_guest: add the guest''s name';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_update_guest: add the guest''s name';
  END IF;
  IF public.exos_name_has_email(p_guest_name) THEN /* exos: name is an email */
    RAISE EXCEPTION 'exos_update_guest: name looks like an email; are your columns swapped?' USING ERRCODE = '23514';
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_set_ticket_attendee(uuid,text)',
  '/* exos: name is an email */',
  $o$    RAISE EXCEPTION 'exos_set_ticket_attendee: name too long (max 80)';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_set_ticket_attendee: name too long (max 80)';
  END IF;
  IF public.exos_name_has_email(v_name) THEN /* exos: name is an email */
    RAISE EXCEPTION 'exos_set_ticket_attendee: name looks like an email; are your columns swapped?' USING ERRCODE = '23514';
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_ticket_update(uuid,jsonb)',
  '/* exos: name is an email */',
  $o$    RAISE EXCEPTION 'exos_ticket_update: name too long (max 80)' USING ERRCODE = '22023';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_ticket_update: name too long (max 80)' USING ERRCODE = '22023';
  END IF;
  IF v_name IS DISTINCT FROM t.attendee_name AND public.exos_name_has_email(v_name) THEN /* exos: name is an email */
    RAISE EXCEPTION 'exos_ticket_update: name looks like an email; are your columns swapped?' USING ERRCODE = '22023';
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_join_waitlist(uuid,text,uuid,text,integer,jsonb)',
  '/* exos: name is an email */',
  $o$  IF NOT EXISTS (SELECT 1 FROM public.exos_events e
                 WHERE e.id = p_event_id AND e.status = 'published') THEN$o$,
  $n$  IF public.exos_name_has_email(p_name) THEN /* exos: name is an email */
    RAISE EXCEPTION 'exos_join_waitlist: name looks like an email; are your columns swapped?' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e
                 WHERE e.id = p_event_id AND e.status = 'published') THEN$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_phone_rsvp_start(uuid,text,text,text,integer,text,boolean,text,text)',
  '/* exos: name is an email */',
  $o$  IF length(v_name) < 1 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_name'); END IF;$o$,
  $n$  IF length(v_name) < 1 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_name'); END IF;
  IF public.exos_name_has_email(v_name) THEN /* exos: name is an email */
    RETURN jsonb_build_object('ok', false, 'error', 'name_is_email');
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_order_update(text,jsonb)',
  '/* exos: name is an email */',
  $o$    RAISE EXCEPTION 'exos_order_update: names are at most 60 characters' USING ERRCODE = '22023';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_order_update: names are at most 60 characters' USING ERRCODE = '22023';
  END IF;
  IF (v_first IS DISTINCT FROM d.first_name AND public.exos_name_has_email(v_first))
     OR (v_last IS DISTINCT FROM d.last_name AND public.exos_name_has_email(v_last)) THEN /* exos: name is an email */
    RAISE EXCEPTION 'exos_order_update: name looks like an email; are your columns swapped?' USING ERRCODE = '22023';
  END IF;$n$, 1);

-- ===========================================================================
-- 4. A checkout hold outlives the processor's session by 10 minutes.
-- ===========================================================================
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS provider_expires_at timestamptz;
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS proof_token_hash text;
DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_proof_token_chk') THEN
    ALTER TABLE public.exos_checkout_sessions ADD CONSTRAINT exos_checkout_sessions_proof_token_chk
      CHECK (proof_token_hash IS NULL OR proof_token_hash ~ '^[0-9a-f]{64}$');
  END IF;
END $c$;
COMMENT ON COLUMN public.exos_checkout_sessions.provider_expires_at IS
  'When the processor''s checkout page stops taking payment (Stripe expires_at). The hold is kept 10 minutes past it (mig 20261105100000).';
COMMENT ON COLUMN public.exos_checkout_sessions.proof_token_hash IS
  'SHA-256 hex of the guest''s browser token: gates exos_order_proof_* for this order (mig 20261105100000).';

CREATE OR REPLACE FUNCTION public.exos_tg_hold_session_grace()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_until timestamptz;
BEGIN
  IF NEW.checkout_session_id IS NULL OR NEW.status <> 'active'
     OR (TG_OP = 'UPDATE' AND NEW.checkout_session_id IS NOT DISTINCT FROM OLD.checkout_session_id) THEN
    RETURN NEW;
  END IF;
  SELECT coalesce(s.provider_expires_at,
                  CASE WHEN s.session_id LIKE 'cs\_%' THEN s.created_at + interval '30 minutes' END)
    INTO v_until
    FROM public.exos_checkout_sessions s WHERE s.session_id = NEW.checkout_session_id;
  IF v_until IS NOT NULL THEN
    -- Webhook grace: a payment made in time lands on a seat still held for it.
    NEW.expires_at := greatest(NEW.expires_at, v_until + interval '10 minutes');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_hold_session_grace() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_cart_holds_session_grace ON public.exos_cart_holds;
CREATE TRIGGER exos_cart_holds_session_grace BEFORE INSERT OR UPDATE OF checkout_session_id ON public.exos_cart_holds
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_hold_session_grace();

-- The processor says the page expired: nobody can pay into it, free the seats now.
CREATE OR REPLACE FUNCTION public.exos_tg_session_expired_release()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status = 'expired' AND OLD.status = 'pending' THEN
    UPDATE public.exos_cart_holds SET status = 'released', released_at = now()
     WHERE checkout_session_id = NEW.session_id AND status = 'active';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_session_expired_release() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_checkout_sessions_expired_release ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_sessions_expired_release AFTER UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_session_expired_release();

-- ===========================================================================
-- 5. Proof of email or phone before a guest's tickets are released.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_order_proofs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs(id) ON DELETE CASCADE,
  event_id        uuid NOT NULL REFERENCES public.exos_events(id) ON DELETE CASCADE,
  session_id      text NOT NULL UNIQUE REFERENCES public.exos_checkout_sessions(session_id) ON DELETE CASCADE,
  email           text NOT NULL CHECK (email = lower(email) AND char_length(email) BETWEEN 3 AND 320),
  original_email  text NOT NULL,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'proven', 'cancelled')),
  proven_via      text CHECK (proven_via IN ('email_code', 'sms', 'organizer')),
  proven_at       timestamptz,
  expires_at      timestamptz NOT NULL,
  token_hash      text CHECK (token_hash IS NULL OR token_hash ~ '^[0-9a-f]{64}$'),
  email_code_hash text,
  email_code_at   timestamptz,
  email_sends     integer NOT NULL DEFAULT 0,
  sms_phone       text,
  sms_code_hash   text,
  sms_code_at     timestamptz,
  sms_sends       integer NOT NULL DEFAULT 0,
  attempts        integer NOT NULL DEFAULT 0,
  last_sent_at    timestamptz,
  resends         integer NOT NULL DEFAULT 0,
  attached_uid    uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_order_proofs_event_idx ON public.exos_order_proofs (event_id, status);
CREATE INDEX IF NOT EXISTS exos_order_proofs_org_idx ON public.exos_order_proofs (org_id);
ALTER TABLE public.exos_order_proofs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_order_proofs_staff_read ON public.exos_order_proofs;
CREATE POLICY exos_order_proofs_staff_read ON public.exos_order_proofs
  FOR SELECT TO authenticated USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_order_proofs FROM PUBLIC, anon, authenticated;
-- No client column grant on the token / code hashes.
GRANT SELECT (id, org_id, event_id, session_id, email, original_email, status, proven_via, proven_at, expires_at,
              email_sends, sms_sends, attempts, last_sent_at, resends, created_at, updated_at)
  ON public.exos_order_proofs TO authenticated;
GRANT ALL ON public.exos_order_proofs TO service_role;
DROP TRIGGER IF EXISTS exos_order_proofs_touch ON public.exos_order_proofs;
CREATE TRIGGER exos_order_proofs_touch BEFORE UPDATE ON public.exos_order_proofs
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- A 6-digit code, and how it is stored: SHA-256(proof id : channel : code).
CREATE OR REPLACE FUNCTION public._exos_proof_code()
RETURNS text LANGUAGE sql VOLATILE SET search_path = public, pg_temp AS $$
  SELECT lpad((('x00000000' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(64)::bigint % 1000000)::text, 6, '0')
$$;
CREATE OR REPLACE FUNCTION public._exos_proof_hash(p_id uuid, p_channel text, p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT encode(extensions.digest(p_id::text || ':' || p_channel || ':' || p_code, 'sha256'), 'hex')
$$;
CREATE OR REPLACE FUNCTION public._exos_proof_mask_email(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p LIKE '%@%' THEN left(split_part(p, '@', 1), 2) || '…@' || split_part(p, '@', 2) END
$$;
REVOKE ALL ON FUNCTION public._exos_proof_code() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_proof_hash(uuid,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_proof_mask_email(text) FROM PUBLIC, anon, authenticated;

-- The code mail (rsvp-code template: the same one-time-code mail as the RSVP).
CREATE OR REPLACE FUNCTION public._exos_proof_mail_code(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  p public.exos_order_proofs%ROWTYPE; v_code text := public._exos_proof_code(); v_ev text; v_n int; v_paid boolean;
  v_many boolean;
BEGIN
  SELECT * INTO p FROM public.exos_order_proofs WHERE id = p_id;
  SELECT public.exos_mail_escape(coalesce(e.name, 'your event')) INTO v_ev FROM public.exos_events e WHERE e.id = p.event_id;
  SELECT coalesce(cardinality(s.ticket_ids), s.quantity), coalesce(s.amount_cents, 0) + coalesce(s.gift_card_cents, 0) > 0
    INTO v_n, v_paid FROM public.exos_checkout_sessions s WHERE s.session_id = p.session_id;
  v_n := coalesce(v_n, 1); v_many := v_n > 1;
  UPDATE public.exos_order_proofs
     SET email_code_hash = public._exos_proof_hash(p.id, 'email', v_code), email_code_at = now(),
         email_sends = email_sends + 1, attempts = 0, last_sent_at = now()
   WHERE id = p.id;
  -- The same one-time-code mail as the RSVP (rsvp-code). The link opens the
  -- confirm step and fills the code in; it only works in the browser the
  -- buyer paid in (the order's token is kept there), so in a mistyped inbox
  -- that belongs to someone else it does nothing.
  BEGIN
    INSERT INTO public.exos_mail (template, to_email, subject, html, status)
    VALUES ('rsvp-code', p.email, left('Confirm your email to get your tickets for ' || coalesce(v_ev, 'your event'), 200),
      '<p>' || CASE WHEN v_paid THEN 'Payment received. ' ELSE 'You''re in. ' END || 'Your ' || v_n || ' ticket' ||
      CASE WHEN v_many THEN 's' ELSE '' END || ' for <strong>' || coalesce(v_ev, 'your event') || '</strong> ' ||
      CASE WHEN v_many THEN 'are' ELSE 'is' END || ' saved for you. To get ' || CASE WHEN v_many THEN 'them' ELSE 'it' END ||
      ', enter this code on the page where you ' || CASE WHEN v_paid THEN 'paid' ELSE 'signed up' END ||
      ':</p><p style="font-size:28px;letter-spacing:6px"><strong>' || v_code || '</strong></p>' ||
      '<p>Or <a href="{{app_url}}/my-tickets?confirm=' || p.session_id || '&amp;proof_code=' || v_code ||
      '">confirm it here</a>, on the same device and browser. ' ||
      'If you didn''t order these tickets, ignore this email: nothing is sent to you without the code.</p>',
      'pending');
  EXCEPTION WHEN others THEN NULL;
  END;
END $$;
REVOKE ALL ON FUNCTION public._exos_proof_mail_code(uuid) FROM PUBLIC, anon, authenticated;

-- Whether an account has confirmed its email (signed-in buyers who haven't
-- prove it per order, like guests).
CREATE OR REPLACE FUNCTION public._exos_uid_email_confirmed(p_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT u.email_confirmed_at IS NOT NULL FROM auth.users u WHERE u.id = p_uid), false)
$$;
REVOKE ALL ON FUNCTION public._exos_uid_email_confirmed(uuid) FROM PUBLIC, anon, authenticated;

-- Opened by exos_fulfill_checkout for an order that needs proof: a guest's,
-- or a signed-in buyer whose email isn't confirmed. Idempotent: the order's
-- existing row comes back.
CREATE OR REPLACE FUNCTION public._exos_proof_open(p_session_id text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.exos_checkout_sessions%ROWTYPE; v_id uuid; v_start timestamptz;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF s.session_id IS NULL OR coalesce(s.buyer_email, '') = ''
     OR (s.buyer_uid IS NOT NULL AND public._exos_uid_email_confirmed(s.buyer_uid)) THEN
    RETURN NULL;
  END IF;
  SELECT id INTO v_id FROM public.exos_order_proofs WHERE session_id = p_session_id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  -- Open until the event is over (a buyer can still confirm at the door).
  SELECT coalesce(ends_at, starts_at + interval '12 hours') INTO v_start FROM public.exos_events WHERE id = s.event_id;
  INSERT INTO public.exos_order_proofs (org_id, event_id, session_id, email, original_email, expires_at, token_hash)
  VALUES (s.org_id, s.event_id, s.session_id, lower(s.buyer_email), lower(s.buyer_email),
          greatest(coalesce(v_start, now() + interval '30 days'), now() + interval '1 hour'), s.proof_token_hash)
  ON CONFLICT (session_id) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    PERFORM public._exos_proof_mail_code(v_id);
  ELSE
    SELECT id INTO v_id FROM public.exos_order_proofs WHERE session_id = p_session_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_proof_open(text) FROM PUBLIC, anon, authenticated;

-- The parked claim links of an order that are still open.
CREATE OR REPLACE FUNCTION public._exos_proof_links(p_session_id text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('ticket_id', t.id, 'transfer_id', tr.id, 'key', tr.claim_key,
                                               'path', '/claim/' || tr.id || '?k=' || tr.claim_key)
                            ORDER BY t.created_at, t.id), '[]'::jsonb)
    FROM public.exos_tickets t
    JOIN public.exos_transfers tr ON tr.id = t.pending_transfer_id AND tr.status = 'pending'
   WHERE t.order_ref = p_session_id AND t.status = 'active'
$$;
REVOKE ALL ON FUNCTION public._exos_proof_links(text) FROM PUBLIC, anon, authenticated;

-- Release a proven order. A signed-in buyer (unconfirmed email): their own
-- account gets the tickets, whichever way they proved. A guest whose email is
-- proven + an account with that email: the tickets move to it. Otherwise the
-- claim links (mailed when the email is the proven channel or the organizer
-- corrected it, returned to the page for a phone proof).
CREATE OR REPLACE FUNCTION public._exos_proof_release(p_id uuid, p_via text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  p     public.exos_order_proofs%ROWTYPE;
  v_uid uuid;
  v_ev  public.exos_events%ROWTYPE;
  v_n   int := 0;
  v_safe text;
  r     record;
BEGIN
  SELECT * INTO p FROM public.exos_order_proofs WHERE id = p_id FOR UPDATE;
  IF p.status = 'pending' THEN
    UPDATE public.exos_order_proofs SET status = 'proven', proven_via = p_via, proven_at = now(),
           email_code_hash = NULL, sms_code_hash = NULL
     WHERE id = p.id;
    p.status := 'proven'; p.proven_via := p_via;
  END IF;
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p.event_id;
  v_safe := public.exos_mail_escape(coalesce(v_ev.name, 'your event'));
  v_uid := (SELECT s.buyer_uid FROM public.exos_checkout_sessions s WHERE s.session_id = p.session_id);
  IF v_uid IS NULL AND p_via = 'email_code' THEN
    v_uid := public.exos_guest_owner(p.email);
  END IF;
  IF v_uid IS NOT NULL THEN
    FOR r IN SELECT t.id AS ticket_id, tr.id AS tr_id
               FROM public.exos_tickets t
               JOIN public.exos_transfers tr ON tr.id = t.pending_transfer_id AND tr.status = 'pending'
              WHERE t.order_ref = p.session_id AND t.status = 'active'
              FOR UPDATE OF t, tr LOOP
      UPDATE public.exos_transfers SET status = 'completed' WHERE id = r.tr_id;
      UPDATE public.exos_tickets
         SET owner_id = v_uid, buyer_id = v_uid, buyer_email = p.email, barcode_secret = gen_random_uuid()::text,
             transfer_id = r.tr_id, pending_transfer_id = NULL, last_reissue_at = now()
       WHERE id = r.ticket_id;
      v_n := v_n + 1;
    END LOOP;
    UPDATE public.exos_order_addons SET buyer_id = v_uid, owner_id = v_uid
     WHERE order_ref = p.session_id AND owner_id IS NULL;
    UPDATE public.exos_order_proofs SET attached_uid = v_uid WHERE id = p.id;
    IF v_n > 0 THEN
      BEGIN
        INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
        VALUES ('ticket-issued', p.email,
          left('Your ticket' || CASE WHEN v_n > 1 THEN 's' ELSE '' END || ' for ' || v_safe || ' ' ||
               CASE WHEN v_n > 1 THEN 'are' ELSE 'is' END || ' ready', 200),
          '<p>Email confirmed. Your ' || v_n || ' ticket' || CASE WHEN v_n > 1 THEN 's' ELSE '' END || ' for <strong>' ||
          v_safe || '</strong> ' || CASE WHEN v_n > 1 THEN 'are' ELSE 'is' END ||
          ' in your Exos wallet. Open the app to show your QR at the door.</p>', v_uid, 'pending');
      EXCEPTION WHEN others THEN NULL;
      END;
    END IF;
  ELSIF p_via IN ('email_code', 'organizer') THEN
    BEGIN
      INSERT INTO public.exos_mail (template, to_email, subject, html, status)
      VALUES ('transfer-initiated', p.email, left('Your tickets for ' || v_safe, 200),
        '<p>Your tickets for <strong>' || v_safe || '</strong> are ready. Open a link below and sign in ' ||
        '(a one-time code, no password) to get your entry QR code. Send a link to a friend and they can claim that ticket themselves.</p>' ||
        coalesce((SELECT '<ul>' || string_agg('<li><a href="{{app_url}}' || (l ->> 'path') || '">Claim ticket ' || n || '</a></li>', '' ORDER BY n) || '</ul>'
                    FROM jsonb_array_elements(public._exos_proof_links(p.session_id)) WITH ORDINALITY AS x(l, n)), ''),
        'pending');
    EXCEPTION WHEN others THEN NULL;
    END;
  END IF;
  -- A phone proof: the claim links are on the paying page (the SMS outbox
  -- sends bodies as they are, with no app address to build links from).
  -- The buyer is now known: take them off the waitlist (item 6).
  PERFORM public._exos_waitlist_convert(p.event_id, p.email, p.session_id);
  RETURN jsonb_build_object('ok', true, 'status', 'proven', 'attached', v_uid IS NOT NULL,
                            'tickets', CASE WHEN v_uid IS NULL THEN public._exos_proof_links(p.session_id) ELSE '[]'::jsonb END);
END $$;
REVOKE ALL ON FUNCTION public._exos_proof_release(uuid,text) FROM PUBLIC, anon, authenticated;

-- The browser's proof row, or nothing (a wrong token looks like no order).
CREATE OR REPLACE FUNCTION public._exos_proof_for(p_session_id text, p_token text)
RETURNS public.exos_order_proofs LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p.* FROM public.exos_order_proofs p
   WHERE p.session_id = btrim(coalesce(p_session_id, ''))
     AND p.token_hash IS NOT NULL AND length(coalesce(p_token, '')) BETWEEN 20 AND 200
     AND p.token_hash = encode(extensions.digest(btrim(p_token), 'sha256'), 'hex')
$$;
REVOKE ALL ON FUNCTION public._exos_proof_for(text,text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_order_proof_status(p_session_id text, p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_order_proofs%ROWTYPE; v_sess text;
BEGIN
  p := public._exos_proof_for(p_session_id, p_token);
  IF p.id IS NULL THEN RETURN jsonb_build_object('status', 'unknown'); END IF;
  SELECT status INTO v_sess FROM public.exos_checkout_sessions WHERE session_id = p.session_id;
  RETURN jsonb_build_object(
    'status', CASE WHEN p.status = 'cancelled' OR v_sess IN ('refunded', 'failed') THEN 'cancelled'
                   WHEN p.status = 'pending' AND now() > p.expires_at THEN 'expired' ELSE p.status END,
    'email', public._exos_proof_mask_email(p.email),
    'phone', CASE WHEN p.sms_phone IS NOT NULL THEN '…' || right(p.sms_phone, 4) END,
    'attempts_left', greatest(5 - p.attempts, 0),
    'expires_at', p.expires_at,
    'attached', p.attached_uid IS NOT NULL,
    'tickets', CASE WHEN p.status = 'proven' AND p.attached_uid IS NULL AND p.proven_via = 'sms'
                    THEN public._exos_proof_links(p.session_id) ELSE '[]'::jsonb END);
END $$;

CREATE OR REPLACE FUNCTION public.exos_order_proof_send(p_session_id text, p_token text, p_channel text, p_phone text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_order_proofs%ROWTYPE; v_phone text; v_code text; v_ev text;
BEGIN
  p := public._exos_proof_for(p_session_id, p_token);
  IF p.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'unknown'); END IF;
  SELECT * INTO p FROM public.exos_order_proofs WHERE id = p.id FOR UPDATE;
  IF p.status <> 'pending' THEN RETURN jsonb_build_object('ok', false, 'error', p.status); END IF;
  IF now() > p.expires_at THEN RETURN jsonb_build_object('ok', false, 'error', 'expired'); END IF;
  -- 60 seconds between codes on the same channel (the first email code goes
  -- out at payment, so a buyer who spots a typo can text a phone at once).
  IF (p_channel = 'email' AND p.email_code_at > now() - interval '60 seconds')
     OR (p_channel = 'sms' AND p.sms_code_at > now() - interval '60 seconds') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', 60);
  END IF;
  IF p_channel = 'email' THEN
    IF p.email_sends >= 5 THEN RETURN jsonb_build_object('ok', false, 'error', 'rate_limited'); END IF;
    PERFORM public._exos_proof_mail_code(p.id);
    RETURN jsonb_build_object('ok', true, 'channel', 'email', 'to', public._exos_proof_mask_email(p.email));
  ELSIF p_channel = 'sms' THEN
    v_phone := public.exos_sms_normalize_phone(p_phone);
    IF v_phone IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_phone'); END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('exos-proof-phone:' || v_phone, 0));
    IF p.sms_sends >= 3
       OR (SELECT count(*) FROM public.exos_rsvp_sms_outbox WHERE phone = v_phone AND created_at > now() - interval '10 minutes') >= 3
       OR EXISTS (SELECT 1 FROM public.exos_sms_subscribers ss WHERE ss.org_id = p.org_id AND ss.phone = v_phone AND ss.opted_out_at IS NOT NULL) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
    END IF;
    v_code := public._exos_proof_code();
    SELECT left(coalesce(e.name, 'your tickets'), 60) INTO v_ev FROM public.exos_events e WHERE e.id = p.event_id;
    UPDATE public.exos_order_proofs
       SET sms_phone = v_phone, sms_code_hash = public._exos_proof_hash(p.id, 'sms', v_code), sms_code_at = now(),
           sms_sends = sms_sends + 1, attempts = 0, last_sent_at = now()
     WHERE id = p.id;
    INSERT INTO public.exos_rsvp_sms_outbox (org_id, phone, body)
    VALUES (p.org_id, v_phone, v_code || ' is your code to get your tickets for ' || v_ev || '. It works for 10 minutes. Don''t share it.');
    RETURN jsonb_build_object('ok', true, 'channel', 'sms', 'to', '…' || right(v_phone, 4));
  END IF;
  RETURN jsonb_build_object('ok', false, 'error', 'bad_channel');
END $$;

CREATE OR REPLACE FUNCTION public.exos_order_proof_verify(p_session_id text, p_token text, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_order_proofs%ROWTYPE; v_code text := regexp_replace(coalesce(p_code, ''), '\s', '', 'g'); v_via text;
BEGIN
  p := public._exos_proof_for(p_session_id, p_token);
  IF p.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'unknown'); END IF;
  SELECT * INTO p FROM public.exos_order_proofs WHERE id = p.id FOR UPDATE;
  IF p.status = 'proven' THEN
    -- Idempotent: a second tab or a retry gets the same answer.
    RETURN jsonb_build_object('ok', true, 'status', 'proven', 'attached', p.attached_uid IS NOT NULL,
                              'tickets', CASE WHEN p.attached_uid IS NULL AND p.proven_via = 'sms'
                                              THEN public._exos_proof_links(p.session_id) ELSE '[]'::jsonb END);
  END IF;
  IF p.status <> 'pending' THEN RETURN jsonb_build_object('ok', false, 'error', p.status); END IF;
  IF now() > p.expires_at THEN RETURN jsonb_build_object('ok', false, 'error', 'expired'); END IF;
  IF p.attempts >= 5 THEN RETURN jsonb_build_object('ok', false, 'error', 'locked'); END IF;
  IF v_code !~ '^[0-9]{6}$' THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_code'); END IF;
  IF p.email_code_hash IS NOT NULL AND p.email_code_hash = public._exos_proof_hash(p.id, 'email', v_code) THEN
    v_via := 'email_code';
  ELSIF p.sms_code_hash IS NOT NULL AND p.sms_code_at > now() - interval '10 minutes'
        AND p.sms_code_hash = public._exos_proof_hash(p.id, 'sms', v_code) THEN
    v_via := 'sms';
  END IF;
  IF v_via IS NULL THEN
    UPDATE public.exos_order_proofs SET attempts = attempts + 1 WHERE id = p.id;
    IF p.attempts + 1 >= 5 THEN RETURN jsonb_build_object('ok', false, 'error', 'locked'); END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'wrong_code', 'attempts_left', 5 - (p.attempts + 1));
  END IF;
  RETURN public._exos_proof_release(p.id, v_via);
END $$;

-- Organizer: send an unproven order to a corrected email (Orders page).
CREATE OR REPLACE FUNCTION public.exos_order_proof_resend(p_session_id text, p_email text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  p      public.exos_order_proofs%ROWTYPE;
  v_new  text := lower(btrim(coalesce(p_email, '')));
  v_ev   public.exos_events%ROWTYPE;
  r      record;
  v_tr   uuid;
  v_sess text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_order_proof_resend: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO p FROM public.exos_order_proofs WHERE session_id = p_session_id FOR UPDATE;
  IF p.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_order_proof_resend: order not found' USING ERRCODE = '42501';
  END IF;
  IF length(v_new) > 254 OR v_new !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'exos_order_proof_resend: enter a valid email' USING ERRCODE = '22023';
  END IF;
  SELECT status INTO v_sess FROM public.exos_checkout_sessions WHERE session_id = p.session_id;
  IF p.status = 'cancelled' OR v_sess IN ('refunded', 'failed') THEN
    RAISE EXCEPTION 'exos_order_proof_resend: this order was refunded' USING ERRCODE = '23514';
  END IF;
  IF p.attached_uid IS NOT NULL THEN
    RAISE EXCEPTION 'exos_order_proof_resend: these tickets are already in the buyer''s account' USING ERRCODE = '23514';
  END IF;
  IF p.resends >= 5 THEN
    RAISE EXCEPTION 'exos_order_proof_resend: this order was resent 5 times already' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p.event_id;
  -- The old links die; new ones go to the corrected address.
  FOR r IN SELECT t.id AS ticket_id, tr.id AS tr_id, tr.sender_id
             FROM public.exos_tickets t
             JOIN public.exos_transfers tr ON tr.id = t.pending_transfer_id AND tr.status = 'pending'
            WHERE t.order_ref = p.session_id AND t.status = 'active'
            FOR UPDATE OF t, tr LOOP
    UPDATE public.exos_transfers SET status = 'cancelled' WHERE id = r.tr_id;
    INSERT INTO public.exos_transfers
    SELECT * FROM jsonb_populate_record(NULL::public.exos_transfers, jsonb_build_object(
      'id', gen_random_uuid(), 'ticket_id', r.ticket_id, 'org_id', p.org_id,
      'sender_id', r.sender_id, 'receiver_email', v_new,
      'status', 'pending', 'event_id', p.event_id, 'event_title', v_ev.name,
      'event_image', v_ev.image_url, 'tier_name', (SELECT tier_name FROM public.exos_tickets WHERE id = r.ticket_id),
      'organizer_id', v_ev.created_by,
      'claim_key', encode(extensions.gen_random_bytes(16), 'hex'),
      'created_at', now(), 'updated_at', now()))
    RETURNING id INTO v_tr;
    UPDATE public.exos_tickets SET pending_transfer_id = v_tr, buyer_email = v_new, last_reissue_at = now() WHERE id = r.ticket_id;
  END LOOP;
  UPDATE public.exos_order_proofs
     SET email = v_new, resends = resends + 1, status = 'proven', proven_via = 'organizer', proven_at = now(),
         email_code_hash = NULL, sms_code_hash = NULL
   WHERE id = p.id;
  RETURN public._exos_proof_release(p.id, 'organizer') - 'tickets';
END $$;

-- Organizer: the guest orders still waiting for proof (Orders page).
CREATE OR REPLACE FUNCTION public.exos_org_order_proofs(p_event_id uuid)
RETURNS TABLE(session_id text, email text, original_email text, status text, proven_via text,
              expires_at timestamptz, created_at timestamptz, tickets integer, resends integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_org_order_proofs: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT p.session_id, p.email, p.original_email,
           CASE WHEN p.status = 'pending' AND now() > p.expires_at THEN 'expired' ELSE p.status END,
           p.proven_via, p.expires_at, p.created_at,
           (SELECT count(*)::int FROM public.exos_tickets t WHERE t.order_ref = p.session_id AND t.status = 'active'
               AND t.pending_transfer_id IS NOT NULL),
           p.resends
      FROM public.exos_order_proofs p
     WHERE p.event_id = p_event_id
     ORDER BY (p.status = 'pending') DESC, p.created_at DESC
     LIMIT 500;
END $$;

DO $g$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY[
    'public.exos_order_proof_status(text,text)', 'public.exos_order_proof_send(text,text,text,text)',
    'public.exos_order_proof_verify(text,text,text)', 'public.exos_order_proof_resend(text,text)',
    'public.exos_org_order_proofs(uuid)', 'public._exos_proof_for(text,text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', s);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', s);
  END LOOP;
END $g$;
-- Bearer-token gated (a 256-bit token only the paying browser has).
GRANT EXECUTE ON FUNCTION public.exos_order_proof_status(text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_proof_send(text,text,text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_proof_verify(text,text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_order_proof_resend(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_order_proofs(uuid) TO authenticated;

-- Fulfilment: a guest's tickets are always parked (never straight into an
-- account with that email), and the order waits for proof.
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)',
  '/* exos: guests prove first */',
  'v_owner := public.exos_guest_owner(s.buyer_email);',
  'v_owner := NULL; /* exos: guests prove first */ -- mig 20261105100000: parked until proof', 1);
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)',
  '/* exos: unconfirmed prove first */',
  $o$    v_owner := s.buyer_uid;
    IF v_owner IS NULL THEN$o$,
  $n$    v_owner := s.buyer_uid;
    /* exos: unconfirmed prove first */ -- mig 20261105100000: a signed-in buyer
    -- whose email isn't confirmed proves it per order, like a guest.
    IF v_owner IS NOT NULL AND NOT public._exos_uid_email_confirmed(v_owner) THEN
      v_owner := NULL;
    END IF;
    IF v_owner IS NULL THEN$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)',
  '/* exos: guest proof */',
  $o$  -- Guest with no account yet: the claim links are the tickets.
  IF v_park THEN$o$,
  $n$  /* exos: guest proof */ -- mig 20261105100000: the claim links wait for proof
  -- of the email or a phone (exos_order_proofs); the mail carries a code.
  IF v_park AND public._exos_proof_open(p_session_id) IS NOT NULL THEN
    RETURN v_ids;
  END IF;
  -- Guest with no account yet: the claim links are the tickets.
  IF v_park THEN$n$, 1);

-- No claim of a parked guest ticket before proof: not by the link, and not
-- by the account that owns the typed email.
SELECT pg_temp.exos_patch_n('public.exos_claim_transfer(uuid)',
  '/* exos: proof before claim */',
  $o$  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer is %', tr.status;
  END IF;$o$,
  $n$  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer is %', tr.status;
  END IF;
  /* exos: proof before claim */ -- mig 20261105100000
  IF EXISTS (SELECT 1 FROM public.exos_tickets t JOIN public.exos_order_proofs p ON p.session_id = t.order_ref
              WHERE t.id = tr.ticket_id AND p.status <> 'proven') THEN
    RAISE EXCEPTION 'exos_claim_transfer: this order is waiting for the buyer to confirm their email or phone'
      USING ERRCODE = '42501';
  END IF;$n$, 1);

-- The organizer can't cancel a parked transfer of an order waiting for proof
-- (the tickets would sit in the organizer's wallet and the proof would have
-- nothing to release): "Send to another email" on the Orders page instead.
SELECT pg_temp.exos_patch_n('public.exos_cancel_transfer(uuid)',
  '/* exos: proof pending */',
  $o$  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_cancel_transfer: transfer is %', tr.status;
  END IF;$o$,
  $n$  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_cancel_transfer: transfer is %', tr.status;
  END IF;
  /* exos: proof pending */ -- mig 20261105100000
  IF EXISTS (SELECT 1 FROM public.exos_tickets t JOIN public.exos_order_proofs p ON p.session_id = t.order_ref
              WHERE t.id = tr.ticket_id AND p.status = 'pending') THEN
    RAISE EXCEPTION 'exos_cancel_transfer: this order is waiting for the buyer to confirm their email; use "Send to another email" on the Orders page'
      USING ERRCODE = '23514';
  END IF;$n$, 1);

-- A refunded / failed guest order closes its proof.
CREATE OR REPLACE FUNCTION public.exos_tg_session_proof_close()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status IN ('refunded', 'failed') AND OLD.status IS DISTINCT FROM NEW.status THEN
    UPDATE public.exos_order_proofs SET status = 'cancelled' WHERE session_id = NEW.session_id AND status = 'pending';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_session_proof_close() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_checkout_sessions_proof_close ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_sessions_proof_close AFTER UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_session_proof_close();

-- A guest order's email makes its owner the payer (receipts, refund asks,
-- reschedule offers) only once that email is proven. Before, a confirmed
-- account at a mistyped address saw a stranger's receipt and could ask to
-- refund their order. Orders from before proofs existed (no proof row) keep
-- the plain email match; account matches (buyer_uid) are unchanged.
CREATE OR REPLACE FUNCTION public._exos_guest_email_ok(p_session_id text, p_email text, p_order_email text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN nullif(btrim(coalesce(p_email, '')), '') IS NULL THEN false
    WHEN NOT EXISTS (SELECT 1 FROM public.exos_order_proofs p WHERE p.session_id = p_session_id)
      THEN lower(btrim(coalesce(p_order_email, ''))) = lower(btrim(p_email))
    -- Proven by the mailed code, or sent by the organizer to a corrected
    -- address: that address. A phone proof proves no email.
    ELSE EXISTS (SELECT 1 FROM public.exos_order_proofs p
                  WHERE p.session_id = p_session_id AND p.status = 'proven'
                    AND p.proven_via IN ('email_code', 'organizer') AND p.email = lower(btrim(p_email)))
  END
$$;
REVOKE ALL ON FUNCTION public._exos_guest_email_ok(text,text,text) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch_n('public._exos_refund_ask_payer_ok(jsonb,uuid)',
  '/* exos: proven email payer */',
  $o$  RETURN coalesce(v_email IS NOT NULL AND v_email = p_state->>'payer_email', false);$o$,
  $n$  /* exos: proven email payer */ -- mig 20261105100000
  RETURN coalesce(public._exos_guest_email_ok(p_state->>'session_id', v_email, p_state->>'payer_email'), false);$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_resched_actor_ok(jsonb,uuid)',
  '/* exos: proven email payer */',
  $o$        OR (p_state->>'payer_uid' IS NULL AND v_email IS NOT NULL AND v_email = p_state->>'payer_email');$o$,
  $n$        OR (p_state->>'payer_uid' IS NULL /* exos: proven email payer */ AND public._exos_guest_email_ok(
              (SELECT t.order_ref FROM public.exos_tickets t WHERE t.id = (p_state->>'ticket_id')::uuid), v_email, p_state->>'payer_email'));$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_resched_actor_ok(jsonb,uuid)',
  '/* exos: proven email holder */',
  $o$        OR (coalesce((p_state->>'parked')::boolean, false) AND v_email IS NOT NULL AND v_email = p_state->>'holder_email');$o$,
  $n$        OR (coalesce((p_state->>'parked')::boolean, false) AND v_email IS NOT NULL AND v_email = p_state->>'holder_email'
            /* exos: proven email holder */ AND public._exos_guest_email_ok(
              (SELECT t.order_ref FROM public.exos_tickets t WHERE t.id = (p_state->>'ticket_id')::uuid), v_email, v_email));$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_my_reschedule_offers()',
  '/* exos: proven email payer */',
  $o$                               OR (s.buyer_uid IS NULL AND v_email IS NOT NULL AND lower(s.buyer_email) = v_email))))$o$,
  $n$                               OR (s.buyer_uid IS NULL /* exos: proven email payer */
                                   AND public._exos_guest_email_ok(s.session_id, v_email, s.buyer_email)))))$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_my_reschedule_offers()',
  '/* exos: proven email holder */',
  $o$                  OR (coalesce((st.j->>'parked')::boolean, false) AND v_email IS NOT NULL
                      AND st.j->>'holder_email' = v_email), false)$o$,
  $n$                  OR (coalesce((st.j->>'parked')::boolean, false) AND v_email IS NOT NULL
                      AND st.j->>'holder_email' = v_email /* exos: proven email holder */
                      AND public._exos_guest_email_ok((SELECT t.order_ref FROM public.exos_tickets t WHERE t.id = st.id), v_email, v_email)), false)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_my_invoices()',
  '/* exos: proven email payer */',
  $o$          AND lower(coalesce(s.buyer_email, i.buyer_email)) = v_email)$o$,
  $n$          /* exos: proven email payer */ AND public._exos_guest_email_ok(i.session_id, v_email, coalesce(s.buyer_email, i.buyer_email)))$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_invoice_document(uuid)',
  '/* exos: proven email payer */',
  $o$                AND lower(coalesce(s.buyer_email, inv.buyer_email)) = v_email);$o$,
  $n$                /* exos: proven email payer */ AND public._exos_guest_email_ok(inv.session_id, v_email, coalesce(s.buyer_email, inv.buyer_email)));$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_my_refund_asks(uuid)',
  '/* exos: proven email payer */',
  $o$       AND (cs.buyer_uid = v_uid OR (v_email IS NOT NULL AND lower(btrim(coalesce(cs.buyer_email, ''))) = v_email))$o$,
  $n$       AND (cs.buyer_uid = v_uid OR (v_email IS NOT NULL /* exos: proven email payer */
                                      AND public._exos_guest_email_ok(cs.session_id, v_email, cs.buyer_email)))$n$, 1);

-- ===========================================================================
-- 6. Waitlist: a buyer is converted; their open offer moves on.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_waitlist_convert(p_event_id uuid, p_email text, p_order_ref text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE w record; v_n int := 0; v_used boolean; v_tier uuid;
BEGIN
  IF coalesce(p_email, '') = '' THEN RETURN 0; END IF;
  FOR w IN SELECT * FROM public.exos_waitlist
            WHERE event_id = p_event_id AND email = lower(btrim(p_email))
              AND status IN ('waiting', 'notified', 'offered')
            FOR UPDATE SKIP LOCKED LOOP
    UPDATE public.exos_waitlist SET status = 'converted' WHERE id = w.id;
    v_n := v_n + 1;
    IF w.status = 'offered' AND w.voucher_id IS NOT NULL THEN
      -- Bought with the offer itself: nothing to pass on.
      v_used := EXISTS (SELECT 1 FROM public.exos_vouchers v WHERE v.id = w.voucher_id AND v.used_count > 0)
                OR EXISTS (SELECT 1 FROM public.exos_checkout_sessions s WHERE s.session_id = p_order_ref AND s.voucher_id = w.voucher_id);
      IF NOT v_used THEN
        SELECT tier_id INTO v_tier FROM public.exos_vouchers WHERE id = w.voucher_id;
        UPDATE public.exos_vouchers SET valid_until = now() WHERE id = w.voucher_id AND used_count = 0;
        PERFORM public._exos_waitlist_offer_core(p_event_id, v_tier, greatest(1, coalesce(w.quantity, 1)),
                  greatest(1, coalesce(ceil(extract(epoch FROM (w.claim_expires_at - w.offered_at)) / 3600)::int, 48)));
      END IF;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_waitlist_convert(uuid,text,text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_tg_ticket_waitlist_convert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  -- A guest's order waits for proof (it converts on release, item 5).
  IF coalesce(NEW.buyer_email, '') = ''
     OR EXISTS (SELECT 1 FROM public.exos_checkout_sessions s WHERE s.session_id = NEW.order_ref
                 AND (s.buyer_uid IS NULL OR NOT public._exos_uid_email_confirmed(s.buyer_uid))) THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_waitlist w WHERE w.event_id = NEW.event_id AND w.email = lower(btrim(NEW.buyer_email))
                AND w.status IN ('waiting', 'notified', 'offered')) THEN
    BEGIN
      PERFORM public._exos_waitlist_convert(NEW.event_id, NEW.buyer_email, NEW.order_ref);
    EXCEPTION WHEN others THEN
      NULL;  -- best effort: never unwinds a sale
    END;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_ticket_waitlist_convert() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_waitlist_convert ON public.exos_tickets;
CREATE TRIGGER exos_tickets_waitlist_convert AFTER INSERT ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_waitlist_convert();

-- ===========================================================================
-- 7a. A forced offline admission uses the ticket.
-- ===========================================================================
SELECT pg_temp.exos_patch_n(
  'public._exos_record_forced_checkin(uuid,uuid,uuid,text,text,text,timestamptz,text,text)',
  '/* exos: forced entry uses the ticket */',
  $o$  RETURNING id INTO v_id;
  RETURN v_id;$o$,
  $n$  RETURNING id INTO v_id;
  /* exos: forced entry uses the ticket */ -- mig 20261105100000: the door let
  -- them in, so the ticket can't get in again. Voided / transfer conflicts
  -- keep the ticket as it is (the conflict row is the record).
  IF p_conflict IN ('wrong-list', 'invalid-time', 'doors-not-open', 'too-old') THEN
    UPDATE public.exos_tickets SET status = 'used', check_in_at = coalesce(p_scanned_at, now())
     WHERE id = t.id AND status = 'active' AND pending_transfer_id IS NULL;
  END IF;
  RETURN v_id;$n$, 1);

-- ===========================================================================
-- 7b. Phone RSVP: a plus-one at the last seat says how many are left.
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_phone_rsvp_start(uuid,text,text,text,integer,text,boolean,text,text)',
  '/* exos: not enough seats */',
  '  v_full := NOT o.ok OR o.seats_left < 1 + v_plus;',
  $n$  /* exos: not enough seats */ -- mig 20261105100000. seats_left is no RSVP
  -- oracle: the public offer already shows availability.
  IF o.ok AND o.seats_left >= 1 AND o.seats_left < 1 + v_plus THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_enough_seats', 'seats_left', o.seats_left);
  END IF;
  v_full := NOT o.ok OR o.seats_left < 1 + v_plus;$n$, 1);

-- ===========================================================================
-- 7c. A monthly gift's card fails: tell the donor once per failure streak.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_tg_recurring_donation_failed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c record; v_org text;
BEGIN
  IF NOT (coalesce(OLD.failed_payments, 0) = 0 AND NEW.failed_payments > 0) OR coalesce(NEW.donor_email, '') = '' THEN
    RETURN NULL;
  END IF;
  SELECT g.name, g.slug, o.slug AS org_slug, o.name AS org_name INTO c
    FROM public.exos_giving_campaigns g JOIN public.exos_orgs o ON o.id = g.org_id WHERE g.id = NEW.campaign_id;
  BEGIN
    INSERT INTO public.exos_mail (template, to_email, subject, html, status)
    VALUES ('order-failed', lower(NEW.donor_email),
      left('Your monthly gift to ' || coalesce(c.org_name, 'us') || ' didn''t go through', 200),
      '<p>Your card was declined for your monthly gift of ' || to_char(NEW.amount_cents / 100.0, 'FM999999990.00') || ' ' ||
      upper(NEW.currency) || ' to <strong>' || public.exos_mail_escape(coalesce(c.name, 'the campaign')) ||
      '</strong>. We''ll try the card again over the next few days. To keep your gift going, ' ||
      '<a href="{{app_url}}/give/' || coalesce(c.org_slug, '') || '/' || coalesce(c.slug, '') || '?update_card=' || NEW.id ||
      '">update your card</a> (sign in with this email).</p>' ||
      '<p>If the card works on the next try, you don''t need to do anything. You get this email once each time a payment starts failing.</p>',
      'pending');
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_recurring_donation_failed() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_recurring_donations_failed_mail ON public.exos_recurring_donations;
CREATE TRIGGER exos_recurring_donations_failed_mail AFTER UPDATE OF failed_payments ON public.exos_recurring_donations
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_recurring_donation_failed();

-- ===========================================================================
-- 7d. Imported codes typed without their punctuation.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_door_code_loose(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  -- Same rule as supabase/functions/_shared/guestImport.ts looseDoorCode.
  SELECT nullif(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), '')
$$;
CREATE INDEX IF NOT EXISTS exos_guest_list_entries_loose_code_idx
  ON public.exos_guest_list_entries (event_id, public._exos_door_code_loose(external_code))
  WHERE external_code IS NOT NULL;

-- The guest an imported code belongs to: the exact code, else the only
-- entry whose code matches with punctuation removed (two loose matches: none).
CREATE OR REPLACE FUNCTION public.exos_door_code_lookup(p_event_id uuid, p_code text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_ids uuid[];
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_door_code_lookup: not assigned to this event' USING ERRCODE = '42501';
  END IF;
  SELECT g.id INTO v_id FROM public.exos_guest_list_entries g
   WHERE g.event_id = p_event_id AND g.external_code = public._exos_door_code(p_code) LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  SELECT array_agg(g.id) INTO v_ids FROM (
    SELECT g0.id FROM public.exos_guest_list_entries g0
     WHERE g0.event_id = p_event_id AND g0.external_code IS NOT NULL
       AND public._exos_door_code_loose(g0.external_code) = public._exos_door_code_loose(p_code)
     LIMIT 2) g;
  RETURN CASE WHEN cardinality(v_ids) = 1 THEN v_ids[1] END;
END $$;
REVOKE ALL ON FUNCTION public.exos_door_code_lookup(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_door_code_lookup(uuid,text) TO authenticated, service_role;

-- ===========================================================================
-- 1h. The partner API: a new ticket type or add-on needs a capacity of 1+
-- (an update may set 0 to close it).
-- ===========================================================================
DO $p3$
DECLARE c_msg text := ' needs a capacity of 1 or more (0 closes sales; there is no unlimited)';
BEGIN
  PERFORM pg_temp.exos_patch_n('public.exos_api_write(uuid,text,text,jsonb,text)',
    '/* exos: event tiers need a capacity */',
    $o$      PERFORM public._exos_api_insert('public.exos_ticket_tiers', c_tier,$o$,
    $n$      IF coalesce(v_item ->> 'capacity', '') !~ '^[0-9]{1,9}$' OR (v_item ->> 'capacity')::int < 1 THEN /* exos: event tiers need a capacity */
        RAISE EXCEPTION 'exos_api_write: ticket type "%"$n$ || c_msg || $n$', left(v_item ->> 'name', 80) USING ERRCODE = '22023';
      END IF;
      PERFORM public._exos_api_insert('public.exos_ticket_tiers', c_tier,$n$, 1);
  PERFORM pg_temp.exos_patch_n('public.exos_api_write(uuid,text,text,jsonb,text)',
    '/* exos: a tier needs a capacity */',
    $o$    v_id := public._exos_api_insert('public.exos_ticket_tiers', c_tier, v_tmp, jsonb_build_object('event_id', v_event));$o$,
    $n$    IF coalesce(v_tmp ->> 'capacity', '') !~ '^[0-9]{1,9}$' OR (v_tmp ->> 'capacity')::int < 1 THEN /* exos: a tier needs a capacity */
      RAISE EXCEPTION 'exos_api_write: a ticket type$n$ || c_msg || $n$' USING ERRCODE = '22023';
    END IF;
    v_id := public._exos_api_insert('public.exos_ticket_tiers', c_tier, v_tmp, jsonb_build_object('event_id', v_event));$n$, 1);
  PERFORM pg_temp.exos_patch_n('public.exos_api_write(uuid,text,text,jsonb,text)',
    '/* exos: an add-on needs a capacity */',
    $o$    v_id := public._exos_api_insert('public.exos_event_addons', c_addon, v_tmp, jsonb_build_object('event_id', v_event));$o$,
    $n$    IF coalesce(v_tmp ->> 'capacity', '') !~ '^[0-9]{1,9}$' OR (v_tmp ->> 'capacity')::int < 1 THEN /* exos: an add-on needs a capacity */
      RAISE EXCEPTION 'exos_api_write: an add-on$n$ || c_msg || $n$' USING ERRCODE = '22023';
    END IF;
    v_id := public._exos_api_insert('public.exos_event_addons', c_addon, v_tmp, jsonb_build_object('event_id', v_event));$n$, 1);
END $p3$;
