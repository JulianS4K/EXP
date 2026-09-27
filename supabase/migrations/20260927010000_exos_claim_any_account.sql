-- ============================================================================
-- Migration 20260927010000 — Exos (Bridge / D4): a transfer is claimed by
--                            link, into any Exos account
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_transfers (+receiver_name, +notify_sender),
--              exos_mail (templates 'transfer-sent', 'invite-accepted')
--              FUNCTION exos_create_transfer (+p_receiver_name; replaced),
--                exos_claim_invite, exos_check_voucher, exos_fulfill_checkout
--                (patched), exos_invite_preview (new),
--                exos_mail_escape (new)
--              FUNCTION exos_claim_transfer, exos_queue_mail,
--                exos_fulfil_marketplace_order, exos_issue_ticket_to_email,
--                exos_issue_comp_batch (patched in place)
--              FUNCTION exos_transfer_claim_preview (new)
--           R: exos_transfers, exos_tickets, exos_marketplace_orders
-- Pre-reqs: 20260926193000 (fulfil_marketplace_order), 20260925010000
--
-- Operator decision (2026-09-27): people sign in with whichever account they
-- want. The email a ticket was sent to only decides where the claim link is
-- mailed; it no longer decides who may claim. That covers marketplace sales
-- (the buyer email is often a relay address the marketplace forwards from)
-- and Exos-to-Exos transfers alike.
--
-- 1. exos_claim_transfer: any verified Exos account holding the transfer id
--    (the claim link) claims it; the first claim wins. Everything else is
--    unchanged: rows lock FOR UPDATE, the ticket must still point at this
--    transfer and belong to its sender, the barcode secret rotates, and the
--    ticket (owner, buyer, buyer_email) moves to the claimer.
-- 2. exos_queue_mail 'transfer-claimed': the claimer was authorised by their
--    email matching receiver_email. Now: the caller owns the ticket through
--    this transfer. A marketplace sale's sender is the organizer, who isn't
--    mailed once per claimed ticket.
-- 3. exos_fulfil_marketplace_order: the mail says "sign in with any Exos
--    account" instead of naming the order email. The friend-transfer mail
--    (exos_queue_mail 'transfer-initiated') now carries the claim link too;
--    it only said "open the app", which only works when signed in with the
--    addressed email. The link is {{app_url}}/claim/<id>, filled by
--    exos-mail-drain from EXOS_APP_URL.
--    Box-office and comp tickets sent to someone without an account
--    (exos_issue_ticket_to_email, exos_issue_comp_batch) said "sign in with
--    this email address"; they now say any account, with one link per ticket.
--    DEPLOY ORDER: the live exos-mail-drain (v1) predates {{app_url}}
--    filling. Redeploy it with EXOS_APP_URL set BEFORE applying this, or
--    friend-transfer mail goes out with an unfilled link.
-- 4. exos_transfer_claim_preview: RLS only lets the sender, the addressed
--    email and org staff read a transfer, so the claim page reads its display
--    fields through this function instead: no emails, no ticket id.
--
-- 5. A paper trail for the sender of an Exos-to-Exos transfer, sent by the
--    database so no client can skip it:
--    - 'transfer-sent' when they send it: the recipient's email and the
--      name the sender typed (optional; Exos doesn't look it up, so an
--      email can't be probed for whose account it is), the claim link, and
--      that they can cancel until it's claimed;
--    - 'transfer-claimed' when it's accepted: who claimed it (their Exos
--      display name and email, since any account may claim) and when.
--    Only transfers made with exos_create_transfer (notify_sender) mail the
--    sender; comps, box office and marketplace sales don't mail the
--    organizer per ticket. exos_queue_mail's client-called 'transfer-claimed'
--    is refused for those transfers so an older SPA can't double-send.
--
-- 6. First come, first served for org invites and reserved voucher codes
--    too (operator decision 2026-09-27):
--    - exos_claim_invite: any verified account with the invite link joins;
--      expiry, "never demote an owner" and "a stale invite never changes a
--      membership edited after it was sent" stay. The invite mail carries the
--      link ({{app_url}}/invite/<token>; it said "open the app"), and the
--      person who sent the invite gets an 'invite-accepted' receipt naming the
--      account that joined, so they can remove it. exos_invite_preview lets
--      the invite page load for an account RLS doesn't show the row to.
--    - Vouchers: reserved_email no longer restricts who redeems (it records
--      who the code was for). exos_check_voucher and exos_fulfill_checkout
--      drop the check; max_uses still makes a single-use code single-use.
--
-- The transfer id (a random UUID, only in the claim link) is the bearer
-- secret, as it already was for whoever the link reached.
--
-- Every patch asserts one match and is skipped once applied (re-run safe).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_transfers
  ADD COLUMN IF NOT EXISTS receiver_name text,
  -- NULL (jsonb_populate_record inserts) counts as false.
  ADD COLUMN IF NOT EXISTS notify_sender boolean DEFAULT false;
COMMENT ON COLUMN public.exos_transfers.receiver_name IS
  'Name the sender typed for the recipient (optional; shown in the sender''s receipts only).';
COMMENT ON COLUMN public.exos_transfers.notify_sender IS
  'true for Exos-to-Exos transfers (exos_create_transfer): the sender is mailed when it is sent and when it is claimed.';

-- Patch helper: replace exactly one occurrence of p_old in a function body.
CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_sig text, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected one match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- 1. any verified account claims -----------------------------------------------
SELECT pg_temp.exos_patch('public.exos_claim_transfer(uuid)',
  'claimed into any account',
  '  IF v_email = '''' OR lower(tr.receiver_email) <> v_email THEN
    RAISE EXCEPTION ''exos_claim_transfer: transfer addressed to a different email'';
  END IF;',
  '  -- Transfers are claimed into any account (mig 20260927010000): the
  -- receiver email is only where the link was sent. First claim wins.');

-- 2. the "your transfer was claimed" mail -------------------------------------
SELECT pg_temp.exos_patch('public.exos_queue_mail(text, uuid)',
  'owns the ticket through this transfer',
  '      AND lower(trim(t.receiver_email)) = lower(trim(caller.email))',
  '      -- the caller owns the ticket through this transfer (any account can
      -- claim; mig 20260927010000). Marketplace sales: no per-ticket mail.
      AND EXISTS (SELECT 1 FROM public.exos_tickets tk
                   WHERE tk.id = t.ticket_id AND tk.transfer_id = t.id AND tk.owner_id = caller.id)
      AND NOT EXISTS (SELECT 1 FROM public.exos_marketplace_orders mo WHERE t.id = ANY (mo.transfer_ids))
      -- exos_claim_transfer mails these itself (section 5)
      AND NOT coalesce(t.notify_sender, false)');

-- 2b. the friend-transfer mail carries the claim link ------------------------
SELECT pg_temp.exos_patch('public.exos_queue_mail(text, uuid)',
  '{{app_url}}/claim/',
  '''<p>You have a pending ticket transfer waiting for you in Exos. Open the app to claim it.</p>''',
  '''<p>Someone sent you a ticket on Exos.</p><p><a href="{{app_url}}/claim/'' || t.id ||
           ''">Claim your ticket</a> and sign in with any Exos account, or create one.</p>''
           || ''<p>Whoever claims the link first gets the ticket, so keep this email to yourself.</p>''');

-- 2c. box office + comps: any account, with claim links -----------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.exos_issue_ticket_to_email(uuid, uuid, text, integer, text)', 'v_email'),
      ('public.exos_issue_comp_batch(uuid, uuid, text[], integer, text)',   'v_e')) AS t(sig, rcpt)
  LOOP
    PERFORM pg_temp.exos_patch(r.sig, 'with any Exos account',
      '''. Sign in to Exos with this email address to claim '' ||',
      '''. Sign in to Exos with any Exos account, or create one, to claim '' ||');
    PERFORM pg_temp.exos_patch(r.sig, '/claim/',
      'ELSE ''it'' END || ''.</p>'', v_uid, ''pending'');',
      'ELSE ''it'' END || ''.</p>'' ||
            coalesce((SELECT ''<ul>'' || string_agg(''<li><a href="{{app_url}}/claim/'' || tr.id || ''">Claim ticket</a></li>'', '''' ORDER BY tr.id) || ''</ul>''
                        FROM public.exos_transfers tr
                       WHERE tr.ticket_id = ANY (v_ids) AND tr.status = ''pending''
                         AND lower(tr.receiver_email) = ' || r.rcpt || '), ''''),
            v_uid, ''pending'');');
  END LOOP;
END $$;

-- 3. marketplace mail copy ----------------------------------------------------
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'any Exos account',
  '          '' been transferred to you on Exos. Sign in with '' || o.buyer_email || '' to claim '' ||
          CASE WHEN o.quantity > 1 THEN ''them'' ELSE ''it'' END ||
          '' and get your entry QR code.</p>'' || v_links,',
  '          '' been transferred to you on Exos. Open a claim link (below, or from your '' || v_label ||
          '' order) and sign in with any Exos account, or create one, to claim '' ||
          CASE WHEN o.quantity > 1 THEN ''them'' ELSE ''it'' END ||
          '' and get your entry QR code.</p>'' || v_links ||
          ''<p>Whoever claims a link first gets that ticket, so keep this email to yourself.</p>'',');

-- ---------------------------------------------------------------------------
-- 5. Sender paper trail
-- ---------------------------------------------------------------------------
DO $$
DECLARE c record; v_def text;
BEGIN
  SELECT conname, pg_get_constraintdef(oid) AS def INTO c
    FROM pg_constraint
   WHERE conrelid = 'public.exos_mail'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%transfer-initiated%';
  IF c.def IS NULL OR position('invite-accepted' in c.def) > 0 THEN RETURN; END IF;
  v_def := c.def;
  IF position('transfer-sent' in v_def) = 0 THEN
    v_def := replace(v_def, 'ARRAY[', 'ARRAY[''transfer-sent''::text, ');
  END IF;
  v_def := replace(v_def, 'ARRAY[', 'ARRAY[''invite-accepted''::text, ');
  EXECUTE format('ALTER TABLE public.exos_mail DROP CONSTRAINT %I', c.conname);
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT %I %s', c.conname, v_def);
END $$;

CREATE OR REPLACE FUNCTION public.exos_mail_escape(p text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;
REVOKE ALL ON FUNCTION public.exos_mail_escape(text) FROM PUBLIC, anon, authenticated;

-- exos_create_transfer gains an optional recipient name and mails the sender.
-- Replaced whole (prod definition from 20260924200848) because the signature
-- changes; a two-argument call still resolves to it through the default.
DROP FUNCTION IF EXISTS public.exos_create_transfer(uuid, text);
CREATE OR REPLACE FUNCTION public.exos_create_transfer(
  p_ticket_id      uuid,
  p_receiver_email text,
  p_receiver_name  text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_email       text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_recv        text := lower(btrim(coalesce(p_receiver_email, '')));
  v_name        text := nullif(left(btrim(regexp_replace(coalesce(p_receiver_name, ''), '\s+', ' ', 'g')), 100), '');
  t             public.exos_tickets%ROWTYPE;
  v_evt         public.exos_events%ROWTYPE;
  v_transfer_id uuid;
  v_event       text;
  v_who         text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_transfer: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF v_recv = '' OR position('@' in v_recv) = 0 THEN
    RAISE EXCEPTION 'exos_create_transfer: invalid receiver email';
  END IF;

  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_create_transfer: ticket not found';
  END IF;
  IF t.owner_id <> v_uid THEN
    RAISE EXCEPTION 'exos_create_transfer: not the ticket owner' USING ERRCODE = '42501';
  END IF;
  IF t.status <> 'active' THEN
    RAISE EXCEPTION 'exos_create_transfer: ticket is % (only active is transferable)', t.status;
  END IF;
  IF t.pending_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'exos_create_transfer: ticket already has a pending transfer';
  END IF;
  IF v_recv = v_email THEN
    RAISE EXCEPTION 'exos_create_transfer: cannot transfer a ticket to your own account';
  END IF;

  SELECT * INTO v_evt FROM public.exos_events WHERE id = t.event_id;
  IF v_evt.status = 'draft' THEN
    RAISE EXCEPTION 'exos_create_transfer: cannot transfer — event is still a draft';
  END IF;

  INSERT INTO public.exos_transfers (
    ticket_id, org_id, sender_id, sender_email, receiver_email, receiver_name, notify_sender, status,
    event_id, event_title, event_image, tier_name, organizer_id
  ) VALUES (
    p_ticket_id, t.org_id, v_uid, v_email, v_recv, v_name, true, 'pending',
    t.event_id, v_evt.name, v_evt.image_url, t.tier_name, v_evt.created_by
  ) RETURNING id INTO v_transfer_id;

  UPDATE public.exos_tickets
     SET pending_transfer_id = v_transfer_id, last_reissue_at = now()
   WHERE id = p_ticket_id AND pending_transfer_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_create_transfer: ticket already has a pending transfer';
  END IF;

  -- The sender's receipt: to whom, what, when, and the link they can forward.
  IF v_email <> '' THEN
    v_event := public.exos_mail_escape(coalesce(v_evt.name, 'your event'));
    v_who := CASE WHEN v_name IS NOT NULL
                  THEN '<strong>' || public.exos_mail_escape(v_name) || '</strong> (' || public.exos_mail_escape(v_recv) || ')'
                  ELSE '<strong>' || public.exos_mail_escape(v_recv) || '</strong>' END;
    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES ('transfer-sent', v_email,
            left('You sent your ticket for ' || coalesce(v_evt.name, 'your event') || ' to ' || coalesce(v_name, v_recv), 200),
            '<p>You sent your ' || public.exos_mail_escape(coalesce(t.tier_name, 'General')) ||
            ' ticket for <strong>' || v_event || '</strong> to ' || v_who ||
            ' on ' || to_char(now() AT TIME ZONE 'UTC', 'Mon FMDD, YYYY "at" HH24:MI "UTC"') || '.</p>' ||
            '<p>It stays in transfer until they claim it, and you can cancel it until then. ' ||
            'They were emailed this claim link; you can forward it too: ' ||
            '<a href="{{app_url}}/claim/' || v_transfer_id || '">{{app_url}}/claim/' || v_transfer_id || '</a></p>' ||
            '<p>Transfer reference: ' || v_transfer_id || '</p>',
            v_uid, 'pending');
  END IF;

  RETURN v_transfer_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_create_transfer(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_transfer(uuid, text, text) TO authenticated;

-- exos_claim_transfer mails the sender who accepted it.
SELECT pg_temp.exos_patch('public.exos_claim_transfer(uuid)',
  'transfer accepted receipt',
  '  RETURN tr.ticket_id;',
  '  -- transfer accepted receipt (mig 20260927010000): Exos-to-Exos transfers
  -- tell the sender who claimed it, since any account can.
  IF coalesce(tr.notify_sender, false) THEN
    DECLARE
      v_claimer text;
      v_to      text;
    BEGIN
      IF to_regclass(''public.exos_profiles'') IS NOT NULL THEN
        EXECUTE ''SELECT nullif(btrim(display_name), '''''''') FROM public.exos_profiles WHERE id = $1''
           INTO v_claimer USING v_uid;
      END IF;
      SELECT lower(coalesce(nullif(tr.sender_email, ''''), u.email)) INTO v_to
        FROM auth.users u WHERE u.id = tr.sender_id;
      IF coalesce(v_to, '''') <> '''' THEN
        INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
        VALUES (''transfer-claimed'', v_to,
                left(''Your ticket for '' || coalesce(tr.event_title, ''your event'') || '' was accepted'', 200),
                ''<p>Your '' || public.exos_mail_escape(coalesce(tr.tier_name, ''General'')) ||
                '' ticket for <strong>'' || public.exos_mail_escape(coalesce(tr.event_title, ''your event'')) ||
                ''</strong>, sent to '' ||
                CASE WHEN tr.receiver_name IS NOT NULL
                     THEN public.exos_mail_escape(tr.receiver_name) || '' ('' || public.exos_mail_escape(tr.receiver_email) || '')''
                     ELSE public.exos_mail_escape(tr.receiver_email) END ||
                '' on '' || to_char(tr.created_at AT TIME ZONE ''UTC'', ''Mon FMDD, YYYY'') ||
                '', was accepted on '' || to_char(now() AT TIME ZONE ''UTC'', ''Mon FMDD, YYYY "at" HH24:MI "UTC"'') ||
                '' by <strong>'' ||
                CASE WHEN v_claimer IS NOT NULL
                     THEN public.exos_mail_escape(v_claimer) || ''</strong> ('' || public.exos_mail_escape(v_email) || '')''
                     ELSE public.exos_mail_escape(v_email) || ''</strong>'' END ||
                ''.</p><p>The ticket and its entry QR code are theirs now. Transfer reference: '' || tr.id || ''</p>'',
                v_uid, ''pending'');
      END IF;
    END;
  END IF;

  RETURN tr.ticket_id;');

-- ---------------------------------------------------------------------------
-- 6. First come, first served: org invites and reserved voucher codes
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch('public.exos_claim_invite(uuid)',
  'any verified account with the link joins',
  '  IF v_email = '''' OR lower(v_inv.email) <> v_email THEN
    RAISE EXCEPTION ''exos_claim_invite: invite email does not match caller'';
  END IF;',
  '  -- any verified account with the link joins, first come first served
  -- (mig 20260927010000); the inviter gets a receipt naming it.');

SELECT pg_temp.exos_patch('public.exos_claim_invite(uuid)',
  'invite accepted receipt',
  '  RETURN v_inv.org_id;',
  '  -- invite accepted receipt (mig 20260927010000)
  DECLARE
    v_joiner text;
    v_to     text;
    v_org    text;
  BEGIN
    IF to_regclass(''public.exos_profiles'') IS NOT NULL THEN
      EXECUTE ''SELECT nullif(btrim(display_name), '''''''') FROM public.exos_profiles WHERE id = $1''
         INTO v_joiner USING v_uid;
    END IF;
    SELECT lower(u.email) INTO v_to FROM auth.users u WHERE u.id = v_inv.created_by;
    SELECT o.name INTO v_org FROM public.exos_orgs o WHERE o.id = v_inv.org_id;
    IF coalesce(v_to, '''') <> '''' THEN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES (''invite-accepted'', v_to,
              left(''Your invite to '' || coalesce(v_org, ''your organization'') || '' was accepted'', 200),
              ''<p>Your invite to join <strong>'' || public.exos_mail_escape(coalesce(v_org, ''your organization'')) ||
              ''</strong> as '' || public.exos_mail_escape(v_inv.role) || '', sent to '' || public.exos_mail_escape(v_inv.email) ||
              '' on '' || to_char(v_inv.created_at AT TIME ZONE ''UTC'', ''Mon FMDD, YYYY'') ||
              '', was accepted on '' || to_char(now() AT TIME ZONE ''UTC'', ''Mon FMDD, YYYY "at" HH24:MI "UTC"'') ||
              '' by <strong>'' ||
              CASE WHEN v_joiner IS NOT NULL
                   THEN public.exos_mail_escape(v_joiner) || ''</strong> ('' || public.exos_mail_escape(v_email) || '')''
                   ELSE public.exos_mail_escape(v_email) || ''</strong>'' END ||
              ''.</p><p>If that isn''''t who you meant, remove them under Members.</p>'',
              v_uid, ''pending'');
    END IF;
  END;

  RETURN v_inv.org_id;');

SELECT pg_temp.exos_patch('public.exos_queue_mail(text, uuid)',
  '{{app_url}}/invite/',
  '''<p>You have been invited to join an organization on Exos. Open the app to accept.</p>''',
  '''<p>You have been invited to join an organization on Exos.</p><p><a href="{{app_url}}/invite/'' || i.token ||
           ''">Accept the invite</a> and sign in with any Exos account, or create one.</p>''
           || ''<p>Whoever accepts the link first joins, so keep this email to yourself.</p>''');

-- The invite page, for an account RLS doesn't show the row to: no email.
DO $$
BEGIN
  IF to_regclass('public.exos_org_invites') IS NULL THEN
    RAISE NOTICE 'exos_org_invites: not present, exos_invite_preview skipped';
    RETURN;
  END IF;
  EXECUTE $f$
    CREATE OR REPLACE FUNCTION public.exos_invite_preview(p_token uuid)
    RETURNS TABLE (token uuid, org_id uuid, role text, status text,
                   expires_at timestamptz, created_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = public, pg_temp
    AS $b$
      SELECT i.token, i.org_id, i.role::text, i.status::text,
             least(coalesce(i.expires_at, i.created_at + interval '14 days'),
                   i.created_at + interval '30 days'),
             i.created_at
        FROM public.exos_org_invites i
       WHERE i.token = p_token;
    $b$;
    REVOKE ALL ON FUNCTION public.exos_invite_preview(uuid) FROM PUBLIC;
    GRANT  EXECUTE ON FUNCTION public.exos_invite_preview(uuid) TO anon, authenticated;
  $f$;
END $$;

SELECT pg_temp.exos_patch('public.exos_check_voucher(uuid, text, text)',
  'first redeemer wins',
  '  IF v.reserved_email IS NOT NULL AND v.reserved_email <> v_email THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, ''reserved for another buyer''; RETURN;
  END IF;',
  '  -- reserved_email records who the code was for; it no longer limits who
  -- redeems it: first redeemer wins (mig 20260927010000).');

SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  'first redeemer wins',
  '              AND (v.reserved_email IS NULL
                   OR lower(btrim(v.reserved_email)) = lower(btrim(coalesce(s.buyer_email, ''''))))
',
  '              -- reserved_email no longer limits who redeems: first redeemer wins
');

-- 4. claim page preview -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_transfer_claim_preview(p_transfer_id uuid)
RETURNS TABLE (id uuid, status text, event_id uuid, event_title text,
               event_image text, tier_name text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT tr.id, tr.status::text, tr.event_id, tr.event_title, tr.event_image,
         tr.tier_name, tr.created_at
    FROM public.exos_transfers tr
   WHERE tr.id = p_transfer_id;
$$;
REVOKE ALL ON FUNCTION public.exos_transfer_claim_preview(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_transfer_claim_preview(uuid) TO anon, authenticated;
