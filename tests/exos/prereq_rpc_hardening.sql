-- ============================================================================
-- Harness prereq for mig 20260929080000 (RPC hardening): the RPCs it patches
-- (exos_queue_mail, exos_queue_ticket_issued, exos_create_org) predate the Exos migration chain (Terminal-2's 20260520160000 /
-- 20260523210000 plus later prod-only edits), so the scratch schema doesn't
-- have them. These are prod's bodies as of 2026-09-28 (read with
-- pg_get_functiondef), verbatim, so the migration's patches run against the
-- same text they will meet in prod. Test harness only, never a migration.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_queue_mail(p_template text, p_ref_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid      uuid := auth.uid();
  v_to_email text;
  v_subject  text;
  v_html     text;
  v_id       uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  CASE p_template

  WHEN 'transfer-initiated' THEN
    SELECT lower(trim(t.receiver_email)),
           'Someone sent you a ticket',
           '<p>Someone sent you a ticket on Exos.</p><p><a href="{{app_url}}/claim/' || t.id ||
           '">Claim your ticket</a> and sign in with any Exos account, or create one.</p>'
           || '<p>Whoever claims the link first gets the ticket, so keep this email to yourself.</p>'
    INTO v_to_email, v_subject, v_html
    FROM public.exos_transfers t
    WHERE t.id = p_ref_id
      AND t.sender_id = v_uid
      AND t.status = 'pending';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Transfer not found or not authorized (id=%)', p_ref_id;
    END IF;

  WHEN 'transfer-claimed' THEN
    SELECT lower(trim(sender.email)),
           'Your ticket transfer was claimed',
           '<p>Good news — someone claimed the ticket you transferred. The transfer is complete and the new owner''s ticket is now active.</p>'
    INTO v_to_email, v_subject, v_html
    FROM public.exos_transfers t
    JOIN auth.users sender ON sender.id = t.sender_id
    JOIN auth.users caller ON caller.id = v_uid
    WHERE t.id = p_ref_id
      -- the caller owns the ticket through this transfer (any account can
      -- claim; mig 20260927010000). Marketplace sales: no per-ticket mail.
      AND EXISTS (SELECT 1 FROM public.exos_tickets tk
                   WHERE tk.id = t.ticket_id AND tk.transfer_id = t.id AND tk.owner_id = caller.id)
      AND NOT EXISTS (SELECT 1 FROM public.exos_marketplace_orders mo WHERE t.id = ANY (mo.transfer_ids))
      -- exos_claim_transfer mails these itself (section 5)
      AND NOT coalesce(t.notify_sender, false)
      AND t.status IN ('pending', 'completed');
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Transfer not found or not authorized for claim notification (id=%)', p_ref_id;
    END IF;

  WHEN 'org-invite' THEN
    SELECT lower(trim(i.email)),
           'You have been invited to join an organization',
           '<p>You have been invited to join an organization on Exos.</p><p><a href="{{app_url}}/invite/' || i.token ||
           '">Accept the invite</a> and sign in with any Exos account, or create one.</p>'
           || '<p>Whoever accepts the link first joins, so keep this email to yourself.</p>'
    INTO v_to_email, v_subject, v_html
    FROM public.exos_org_invites i
    WHERE i.token = p_ref_id
      AND i.created_by = v_uid
      AND i.status = 'pending';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Invite not found or not authorized (id=%)', p_ref_id;
    END IF;

  WHEN 'event-cancelled', 'event-updated' THEN
    SELECT lower(trim(u.email)),
           CASE p_template
             WHEN 'event-cancelled' THEN 'Your event has been cancelled'
             ELSE                        'Your event has been updated'
           END,
           CASE p_template
             WHEN 'event-cancelled' THEN '<p>We are sorry to inform you that the event associated with your ticket has been cancelled. Please check Exos for details and refund information.</p>'
             ELSE                        '<p>The event associated with your ticket has been updated. Please check Exos for the latest details.</p>'
           END
    INTO v_to_email, v_subject, v_html
    FROM public.exos_tickets tkt
    JOIN auth.users u ON u.id = tkt.owner_id
    WHERE tkt.id = p_ref_id
      AND EXISTS (
        SELECT 1
        FROM public.exos_org_memberships m
        JOIN public.exos_events ev ON ev.org_id = m.org_id
        WHERE m.user_id = v_uid
          AND m.disabled IS NOT TRUE
          AND m.role IN ('owner', 'manager')
          AND ev.id = tkt.event_id
      );
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ticket not found or caller lacks org-staff access (id=%)', p_ref_id;
    END IF;

  ELSE
    RAISE EXCEPTION 'Unknown template: %', p_template;
  END CASE;

  IF v_to_email IS NULL THEN
    RAISE EXCEPTION 'Could not derive recipient for template %', p_template;
  END IF;

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES (p_template, v_to_email, v_subject, v_html, v_uid, 'pending')
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.exos_queue_ticket_issued(p_ticket_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid    uuid := auth.uid();
  v_owner  uuid;
  v_org    uuid;
  v_to     text;
  v_evname text;
  v_tier   text;
  v_safe   text;
  v_id     uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT t.owner_id, t.org_id, t.tier_name, lower(u.email), e.name
    INTO v_owner, v_org, v_tier, v_to, v_evname
  FROM public.exos_tickets t
  JOIN auth.users u        ON u.id = t.owner_id
  JOIN public.exos_events e ON e.id = t.event_id
  WHERE t.id = p_ticket_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: ticket not found';
  END IF;
  IF NOT (v_owner = v_uid OR exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_to IS NULL THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: owner has no email';
  END IF;

  v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES (
    'ticket-issued', v_to,
    left('Your ticket for ' || v_safe || ' is ready', 200),
    '<p>Your ticket' ||
      CASE WHEN v_tier IS NOT NULL
           THEN ' (' || replace(replace(v_tier, '<', '&lt;'), '>', '&gt;') || ')'
           ELSE '' END ||
      ' for <strong>' || v_safe || '</strong> is in your wallet. Open the app to show your QR at the door.</p>',
    v_uid, 'pending'
  ) RETURNING id INTO v_id;

  RETURN v_id;
END $function$;

-- exos_create_org writes the membership's added_by (prod has the column; the
-- stub table in prereq.sql doesn't).
ALTER TABLE public.exos_org_memberships ADD COLUMN IF NOT EXISTS added_by uuid;

CREATE OR REPLACE FUNCTION public.exos_create_org(p_name text, p_slug text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_org_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_org: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR length(btrim(p_name)) = 0 OR length(p_name) > 100 THEN
    RAISE EXCEPTION 'exos_create_org: name must be 1-100 chars';
  END IF;
  IF p_slug !~ '^[a-z0-9][a-z0-9-]{0,79}$' THEN
    RAISE EXCEPTION 'exos_create_org: invalid slug %', p_slug;
  END IF;

  INSERT INTO public.exos_orgs (name, slug, owner_uid)
  VALUES (p_name, p_slug, v_uid)
  RETURNING id INTO v_org_id;

  INSERT INTO public.exos_org_memberships (org_id, user_id, role, added_by)
  VALUES (v_org_id, v_uid, 'owner', v_uid);

  RETURN v_org_id;
END $function$;

-- Prod's grants: signed-in callers only.
REVOKE ALL ON FUNCTION public.exos_queue_mail(text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_queue_ticket_issued(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_queue_mail(text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_queue_ticket_issued(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.exos_create_org(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_create_org(text, text) TO authenticated, service_role;
