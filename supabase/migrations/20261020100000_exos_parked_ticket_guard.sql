-- ============================================================================
-- Parked tickets: the person they're parked on can't act on them
-- ============================================================================
-- Touches:  C: FUNCTION _exos_ticket_held, _exos_parked_ok, _exos_parked_guard
--              (internal, no client grant)
--           R: CREATE OR REPLACE exos_cancel_transfer (a parked claim: current
--              owners / managers of the ticket's org only),
--              exos_can_read_ticket_secret (holder / buyer path skips held tickets),
--              exos_transfer_claim_key (held: current owners / managers only)
--           P: exos_create_transfer (held: current owners / managers only; a
--              reissue re-parks it on the sender for the new address),
--              exos_set_ticket_attendee, exos_set_ticket_access_needs,
--              exos_release_ticket (holder path), exos_wallet_issue_pass,
--              exos_wallet_reissue, exos_event_online_access (holder path),
--              _exos_resched_ticket_state (a parking on disabled or removed
--              staff is still a parking), exos_delete_my_account (keeps the
--              claim's email on a held ticket)
-- Pre-reqs: 20261019100000 (exos_can_read_ticket_secret), 20260929150000
--           (reschedules), 20260929130000 (_exos_ticket_parked), 20260929072000
--           (wallet passes), 20261005090000 (online access)
--
-- A ticket minted for an email with no account is parked on the issuing owner /
-- manager (comps, box office: owner_id = buyer_id = the caller) or on the org
-- owner (guest checkout, marketplace sales), with a pending claim-by-email
-- transfer to the ticket's buyer_email. Every holder check (owner_id or
-- buyer_id = auth.uid(), sender_id = auth.uid()) therefore let the parker act
-- as the holder: a manager disabled after issuing a comp could cancel the
-- guest's claim and send the ticket to themselves, and read its barcode secret.
--
-- "Held" (_exos_ticket_held) is that shape, whoever it sits on now: owner =
-- buyer, and a pending or cancelled transfer from the owner to the ticket's
-- buyer_email (a holder forwarding their own ticket has their own email there,
-- and can't send it to themselves). Cancelled covers a claim staff withdrew and
-- the door's by-name check-in, which cancels the claim; the ticket stays on the
-- parker. It does not look at memberships, so a parker who was disabled or
-- removed is still caught. _exos_ticket_parked (the door roster's flag) is
-- unchanged.
--
-- A held ticket is the org's: its claim can be cancelled, re-sent or edited by
-- a current, enabled owner / manager of the ticket's org (or the org owner, or a
-- platform admin), never by someone merely because it is parked on them. Its
-- barcode secret and wallet pass go to nobody on the holder path (the door uses
-- day keys). Claiming is unchanged: the claim link still works for the guest.
--
-- Re-run safe (CREATE OR REPLACE; each patch carries a marker and is skipped
-- once applied). D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- CRLF-safe patch-in-place (as 20261019120000).
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
-- 1. Helpers (internal: called from definer functions only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_ticket_held(p_ticket_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT t.owner_id IS NOT NULL
       AND t.buyer_id = t.owner_id
       AND nullif(btrim(t.buyer_email), '') IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.exos_transfers tr
                    WHERE tr.ticket_id = t.id
                      AND tr.sender_id = t.owner_id
                      AND tr.status IN ('pending', 'cancelled')
                      AND lower(btrim(tr.receiver_email)) = lower(btrim(t.buyer_email)))
      FROM public.exos_tickets t WHERE t.id = p_ticket_id), false);
$$;
REVOKE ALL ON FUNCTION public._exos_ticket_held(uuid) FROM PUBLIC, anon, authenticated;

-- May the caller act as this ticket's holder? Yes unless it is held, then only
-- current staff: an enabled owner / manager of its org, the org owner, an admin.
CREATE OR REPLACE FUNCTION public._exos_parked_ok(p_ticket_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT NOT public._exos_ticket_held(p_ticket_id)
      OR public.exos_is_admin()
      OR EXISTS (SELECT 1 FROM public.exos_tickets t
                  WHERE t.id = p_ticket_id
                    AND (public.exos_has_org_role(t.org_id, ARRAY['owner', 'manager'])
                         OR EXISTS (SELECT 1 FROM public.exos_orgs o
                                     WHERE o.id = t.org_id AND o.owner_uid = auth.uid())));
$$;
REVOKE ALL ON FUNCTION public._exos_parked_ok(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_parked_guard(p_ticket_id uuid, p_fn text)
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public._exos_parked_ok(p_ticket_id) THEN
    RAISE EXCEPTION '%: this ticket is waiting for its buyer to claim it; only the organizer''s owners and managers can change it', p_fn
      USING ERRCODE = '42501';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_parked_guard(uuid, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Cancel a transfer: the sender's own, or a held ticket's claim by staff.
--    (Body as 20260520130000 + 20260925010000 §4a, plus the guard.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_cancel_transfer(p_transfer_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  tr    public.exos_transfers%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_cancel_transfer: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO tr FROM public.exos_transfers WHERE id = p_transfer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_cancel_transfer: transfer not found';
  END IF;
  -- parked ticket guard (mig 20261020100000): a held ticket's claim is the
  -- org's to cancel (current owners / managers), not the parker's as such.
  IF public._exos_ticket_held(tr.ticket_id) THEN
    PERFORM public._exos_parked_guard(tr.ticket_id, 'exos_cancel_transfer');
  ELSIF tr.sender_id <> v_uid THEN
    RAISE EXCEPTION 'exos_cancel_transfer: not the sender' USING ERRCODE = '42501';
  END IF;
  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_cancel_transfer: transfer is %', tr.status;
  END IF;

  UPDATE public.exos_transfers SET status = 'cancelled' WHERE id = p_transfer_id;
  -- withdraw the unsent "someone sent you a ticket" mail
  DELETE FROM public.exos_mail
   WHERE template = 'transfer-initiated' AND status = 'pending'
     AND to_email = lower(trim(tr.receiver_email)) AND created_by = tr.sender_id
     AND created_at >= tr.created_at;
  UPDATE public.exos_tickets
     SET pending_transfer_id = NULL, last_reissue_at = now()
   WHERE id = tr.ticket_id AND pending_transfer_id = p_transfer_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_cancel_transfer(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_cancel_transfer(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. The barcode secret: holder / buyer only when the ticket isn't held.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_can_read_ticket_secret(p_ticket_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  -- door staff: exos_door_ticket_keys / exos_event_door_roster, not this
  -- (was: org door roles AND exos_can_door_event(t.event_id)).
  -- A held ticket (mig 20261020100000) is the claimant's, not the parker's.
  SELECT EXISTS (
    SELECT 1 FROM public.exos_tickets t
    WHERE t.id = p_ticket_id
      AND (((t.owner_id = auth.uid() OR t.buyer_id = auth.uid()) AND NOT public._exos_ticket_held(t.id))
           OR public.exos_is_admin())
  );
$$;
REVOKE EXECUTE ON FUNCTION public.exos_can_read_ticket_secret(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_can_read_ticket_secret(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. The claim key (the link claims into any account): not for a parker.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_transfer_claim_key(p_transfer_id uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT tr.claim_key FROM public.exos_transfers tr
   WHERE tr.id = p_transfer_id AND tr.sender_id = auth.uid() AND tr.status = 'pending'
     AND public._exos_parked_ok(tr.ticket_id);  -- parked ticket guard (mig 20261020100000)
$$;

-- ---------------------------------------------------------------------------
-- 5. Holder actions.
-- ---------------------------------------------------------------------------
-- Send: staff only for a held ticket; sending it again (after its claim was
-- cancelled) re-parks it on the sender for the new address, so the roster and
-- the by-name check-in see the new claim as a parking.
SELECT pg_temp.exos_patch_n('public.exos_create_transfer(uuid, text, text)', 'parked ticket guard (mig 20261020100000)',
  '  IF t.owner_id <> v_uid THEN
    RAISE EXCEPTION ''exos_create_transfer: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
',
  '  -- parked ticket guard (mig 20261020100000): a held ticket is moved by
  -- current owners / managers only; re-sending it re-parks it on the sender.
  IF public._exos_ticket_held(p_ticket_id) THEN
    PERFORM public._exos_parked_guard(p_ticket_id, ''exos_create_transfer'');
    IF t.pending_transfer_id IS NULL AND t.status = ''active'' AND v_recv <> v_email THEN
      UPDATE public.exos_tickets
         SET owner_id = v_uid, buyer_id = v_uid, buyer_email = v_recv
       WHERE id = p_ticket_id
      RETURNING * INTO t;
    END IF;
  ELSIF t.owner_id <> v_uid THEN
    RAISE EXCEPTION ''exos_create_transfer: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
', 1);

SELECT pg_temp.exos_patch_n('public.exos_set_ticket_attendee(uuid, text)', 'parked ticket guard (mig 20261020100000)',
  '    RAISE EXCEPTION ''exos_set_ticket_attendee: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
',
  '    RAISE EXCEPTION ''exos_set_ticket_attendee: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
  PERFORM public._exos_parked_guard(p_ticket_id, ''exos_set_ticket_attendee'');  -- parked ticket guard (mig 20261020100000)
', 1);

SELECT pg_temp.exos_patch_n('public.exos_set_ticket_access_needs(uuid, text[])', 'parked ticket guard (mig 20261020100000)',
  '    RAISE EXCEPTION ''exos_set_ticket_access_needs: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
',
  '    RAISE EXCEPTION ''exos_set_ticket_access_needs: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
  PERFORM public._exos_parked_guard(p_ticket_id, ''exos_set_ticket_access_needs'');  -- parked ticket guard (mig 20261020100000)
', 1);

-- Release: the staff path is unchanged; the holder path refuses a held ticket.
SELECT pg_temp.exos_patch_n('public.exos_release_ticket(uuid)', 'parked ticket guard (mig 20261020100000)',
  '    RAISE EXCEPTION ''exos_release_ticket: not authorized'' USING ERRCODE = ''42501'';
  END IF;
',
  '    RAISE EXCEPTION ''exos_release_ticket: not authorized'' USING ERRCODE = ''42501'';
  END IF;
  IF NOT v_staff THEN
    PERFORM public._exos_parked_guard(p_ticket_id, ''exos_release_ticket'');  -- parked ticket guard (mig 20261020100000)
  END IF;
', 1);

-- Wallet: a pass carries the barcode, so like the secret, nobody on the holder path.
SELECT pg_temp.exos_patch_n('public.exos_wallet_issue_pass(uuid, text, text, text)', 'parked ticket guard (mig 20261020100000)',
  '    RAISE EXCEPTION ''exos_wallet_issue_pass: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
',
  '    RAISE EXCEPTION ''exos_wallet_issue_pass: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
  IF public._exos_ticket_held(p_ticket_id) THEN  -- parked ticket guard (mig 20261020100000)
    RAISE EXCEPTION ''exos_wallet_issue_pass: this ticket is waiting for its buyer to claim it'' USING ERRCODE = ''42501'';
  END IF;
', 1);

SELECT pg_temp.exos_patch_n('public.exos_wallet_reissue(uuid)', 'parked ticket guard (mig 20261020100000)',
  '    RAISE EXCEPTION ''exos_wallet_reissue: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
',
  '    RAISE EXCEPTION ''exos_wallet_reissue: not the ticket owner'' USING ERRCODE = ''42501'';
  END IF;
  IF public._exos_ticket_held(p_ticket_id) THEN  -- parked ticket guard (mig 20261020100000)
    RAISE EXCEPTION ''exos_wallet_reissue: this ticket is waiting for its buyer to claim it'' USING ERRCODE = ''42501'';
  END IF;
', 1);

-- Online join link: a held ticket doesn't make its parker a holder (staff see it as staff).
SELECT pg_temp.exos_patch_n('public.exos_event_online_access(uuid)', 'parked ticket guard (mig 20261020100000)',
  '        WHERE t.event_id = p_event_id AND t.owner_id = auth.uid()
',
  '        WHERE t.event_id = p_event_id AND t.owner_id = auth.uid()
          AND NOT public._exos_ticket_held(t.id)  -- parked ticket guard (mig 20261020100000)
', 1);

-- Reschedules: a parking on staff who were since disabled or removed is still a
-- parking (the claim's email answers, not the parker), and a held ticket whose
-- claim was cancelled has no holder account.
SELECT pg_temp.exos_patch_n('public._exos_resched_ticket_state(uuid)', 'parked ticket guard (mig 20261020100000)',
  '      AND (t.owner_id IS NOT DISTINCT FROM v_owner
           OR EXISTS (SELECT 1 FROM public.exos_org_memberships m
                       WHERE m.org_id = t.org_id AND m.user_id = t.owner_id
                         AND m.role IN (''owner'', ''manager'') AND m.disabled IS NOT TRUE));
',
  '      -- parked ticket guard (mig 20261020100000): whoever it is parked on.
      AND t.buyer_id IS NOT DISTINCT FROM t.owner_id;
', 1);
SELECT pg_temp.exos_patch_n('public._exos_resched_ticket_state(uuid)', 'v_parked OR public._exos_ticket_held(t.id)',
  '    ''holder_uid'', CASE WHEN v_parked THEN NULL ELSE t.owner_id END,
',
  '    ''holder_uid'', CASE WHEN v_parked OR public._exos_ticket_held(t.id) THEN NULL ELSE t.owner_id END,
', 1);

-- Account deletion: the buyer_email on a held ticket is the claimant's, not the
-- deleter's personal data; keep it so the claim still matches.
SELECT pg_temp.exos_patch_n('public.exos_delete_my_account()', 'parked ticket guard (mig 20261020100000)',
  '  UPDATE public.exos_tickets SET buyer_email = NULL, attendee_name = NULL
   WHERE owner_id = v_uid OR buyer_id = v_uid;
',
  '  UPDATE public.exos_tickets SET buyer_email = NULL, attendee_name = NULL
   WHERE (owner_id = v_uid OR buyer_id = v_uid)
     AND NOT public._exos_ticket_held(id);  -- parked ticket guard (mig 20261020100000)
', 1);

-- ROLLBACK: re-run 20260520130000 §7d + 20260925010000 §4a (exos_cancel_transfer),
-- 20261019100000 (exos_can_read_ticket_secret), 20260929010000
-- (exos_transfer_claim_key); restore the patched bodies from their migrations;
-- DROP FUNCTION public._exos_parked_guard(uuid, text), public._exos_parked_ok(uuid),
-- public._exos_ticket_held(uuid).
