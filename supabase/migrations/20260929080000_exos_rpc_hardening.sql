-- ============================================================================
-- Migration 20260929080000 — Exos (Bridge / D4): RPC hardening
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_platform_fee_bps (search_path)
--           G: REVOKE EXECUTE from anon / authenticated on internal helpers:
--              exos_addon_exclusive_tax_percent, exos_tier_exclusive_tax_percent,
--              exos_tier_is_table, exos_tier_party_size, exos_channel_allocated,
--              exos_event_house_available, exos_redeem_discount_code (prod only);
--              from anon on exos_leave_waitlist, exos_has_org_role
--           W: FUNCTION exos_check_in_offline, exos_queue_mail,
--              exos_queue_ticket_issued (patched in place)
--           C: INDEX exos_mail_dedupe_idx
-- Pre-reqs: 20260929074000 (and 20260929060000 for exos_rate_hit)
--
-- From the 2026-09-28 audit of the Supabase security advisor findings
-- (docs/security.md has the full table, one row per function):
--
-- 1. exos_platform_fee_bps() had a mutable search_path (advisor
--    function_search_path_mutable). Every Exos SECURITY DEFINER function
--    already pins it; this was the one plain function left.
-- 2. Helpers no client calls were executable through /rest/v1/rpc:
--    - the tax / table-kind / party-size lookups (anon): they answer for ANY
--      tier or add-on id, including drafts and hidden tiers. Their only
--      readers are SECURITY DEFINER views (exos_public_tiers,
--      exos_public_addons) and SECURITY DEFINER functions, which run as the
--      owner, so the grant was never needed.
--    - exos_channel_allocated / exos_event_house_available (authenticated):
--      unscoped inventory counts for any tier or event, drafts included.
--    - exos_redeem_discount_code (authenticated, legacy, prod only): an
--      unthrottled lookup on the old exos_discount_codes table, i.e. a code
--      guessing oracle beside the throttled voucher check. Nothing calls it.
--    - exos_leave_waitlist (anon): a no-op for anon (it only matches the
--      caller's uid or verified JWT email); exos_has_org_role (anon in the
--      harness schema only; prod already had it signed-in only).
--    service_role keeps EXECUTE on all of them.
-- 3. exos_check_in_offline let ANY signed-in account write: it recorded the
--    client ref (and, for a ticket id of some org, a scan-reject row in that
--    org's door log) before exos_check_in_ticket's staff check ran, and read
--    back another device's cached result by client ref. It now requires
--    owner / manager / scanner on the event's org first (the per-event scanner
--    scope stays with exos_check_in_ticket, which answers "not-assigned").
-- 4. Mail-bombing: exos_queue_mail and exos_queue_ticket_issued queued a new
--    mail on every call. A sender could mail a transfer's (arbitrary)
--    receiver address, or an invite's, as often as they liked. Now the same
--    mail to the same address within 10 minutes returns the one already
--    queued, and a caller queues at most 10 mails a minute (exos_rate_hit).
--
-- Re-run safe: grants are idempotent; each patch asserts one match and is
-- skipped once applied; functions missing from a schema are skipped with a
-- NOTICE. D4 authors; applying to prod is operator-gated.
-- ============================================================================

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

-- ── 1. search_path ──────────────────────────────────────────────────────────

DO $sp$
BEGIN
  IF to_regprocedure('public.exos_platform_fee_bps()') IS NOT NULL THEN
    ALTER FUNCTION public.exos_platform_fee_bps() SET search_path = public, pg_temp;
  END IF;
END $sp$;

-- ── 2. Internal helpers: no client EXECUTE ──────────────────────────────────

DO $rv$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_addon_exclusive_tax_percent(uuid)',
    'public.exos_tier_exclusive_tax_percent(uuid)',
    'public.exos_tier_is_table(uuid)',
    'public.exos_tier_party_size(uuid)',
    'public.exos_channel_allocated(uuid)',
    'public.exos_event_house_available(uuid)',
    'public.exos_redeem_discount_code(uuid,text)'
  ] LOOP
    IF to_regprocedure(f) IS NULL THEN
      RAISE NOTICE '%: not present, skipped', f;
      CONTINUE;
    END IF;
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;

  -- Signed-in only.
  FOREACH f IN ARRAY ARRAY[
    'public.exos_leave_waitlist(uuid,text)',
    'public.exos_has_org_role(uuid,text[])'
  ] LOOP
    IF to_regprocedure(f) IS NULL THEN
      RAISE NOTICE '%: not present, skipped', f;
      CONTINUE;
    END IF;
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
END $rv$;

-- ── 3. Offline check-in: door staff only ────────────────────────────────────

SELECT pg_temp.exos_patch('public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text)',
  'exos_check_in_offline: not authorized',
  $o$  -- Same ref twice (a retry after a lost response): the first answer stands.$o$,
  $n$  -- rpc hardening (mig 20260929080000): only the event org's door staff
  -- write client refs and scan rejects, or read a ref's cached answer.
  IF NOT (public.exos_is_admin() OR EXISTS (
            SELECT 1 FROM public.exos_events e
             WHERE e.id = p_event_id
               AND public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'scanner']))) THEN
    RAISE EXCEPTION 'exos_check_in_offline: not authorized' USING ERRCODE = '42501';
  END IF;

  -- Same ref twice (a retry after a lost response): the first answer stands.$n$);

-- ── 4. Mail RPCs: no mail-bombing ───────────────────────────────────────────

CREATE INDEX IF NOT EXISTS exos_mail_dedupe_idx ON public.exos_mail (to_email, created_at);

SELECT pg_temp.exos_patch('public.exos_queue_mail(text,uuid)',
  'exos_queue_mail: too many emails',
  $o$    RAISE EXCEPTION 'Could not derive recipient for template %', p_template;
  END IF;
$o$,
  $n$    RAISE EXCEPTION 'Could not derive recipient for template %', p_template;
  END IF;

  -- rpc hardening (mig 20260929080000): the same mail to the same address
  -- within 10 minutes is the one already queued; a caller queues at most 10
  -- mails a minute.
  SELECT m.id INTO v_id FROM public.exos_mail m
   WHERE m.to_email = v_to_email AND m.template = p_template AND m.created_by = v_uid
     AND m.html = v_html AND m.created_at > now() - interval '10 minutes'
   ORDER BY m.created_at DESC LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;
  IF NOT public.exos_rate_hit('queue_mail:' || v_uid, 10) THEN
    RAISE EXCEPTION 'exos_queue_mail: too many emails, try again in a minute' USING ERRCODE = '54000';
  END IF;
$n$);

SELECT pg_temp.exos_patch('public.exos_queue_ticket_issued(uuid)',
  'exos_queue_ticket_issued: too many emails',
  $o$  v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');
$o$,
  $n$  v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');

  -- rpc hardening (mig 20260929080000): one "ticket ready" mail per event
  -- and address in 10 minutes; a caller queues at most 10 mails a minute.
  SELECT m.id INTO v_id FROM public.exos_mail m
   WHERE m.to_email = v_to AND m.template = 'ticket-issued' AND m.created_by = v_uid
     AND m.subject = left('Your ticket for ' || v_safe || ' is ready', 200)
     AND m.created_at > now() - interval '10 minutes'
   ORDER BY m.created_at DESC LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;
  IF NOT public.exos_rate_hit('queue_mail:' || v_uid, 10) THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: too many emails, try again in a minute' USING ERRCODE = '54000';
  END IF;
$n$);
