-- ============================================================================
-- Migration 20261111100000 — Exos: fixes from the end-to-end simulation
-- ============================================================================
-- Branch: claude/exos-e2e-sim (wave 10). Found by tests/exos/sim_full.sql,
-- which drives one org through setup, sales and after-sale across waves 1-9
-- and checks the invariants after every step.
--
-- 1. One audit row per price-step change (sim_full E2E-2 / E2E-2b, I6).
--    exos_set_price_steps (dashboard) and _exos_api_price_steps_set (PUT
--    /v1/events/:id/ticket-types/:id/price-steps) log 'tier.price_steps'
--    themselves (mig 20261109100000), but the tier writes they make on the
--    way (the first step's price written back to exos_ticket_tiers.price,
--    price_schedule, door_price_cents) also fired the exos_ticket_tiers
--    audit trigger: one change was three rows (tier.price_steps + two
--    tier.update), and the explicit row's door price always said it was
--    unset before ([null, new]). Now, as exos_org_member_approve / _reject
--    already do for memberships, the RPC names its tier in a transaction
--    setting (exos.audit_tier_rpc) while it writes, the tier trigger skips
--    that tier's UPDATE rows, and the one 'tier.price_steps' row carries the
--    tier's real price and door price changes as [old, new].
--    Marker patches (each matching once on the current text):
--      _exos_tg_audit_row               /* exos: audit tier rpc */
--      exos_set_price_steps             /* exos: audit tier rpc */ (declare),
--                                       /* exos: audit tier rpc write */
--      _exos_api_price_steps_set        /* exos: audit tier rpc */ (declare),
--                                       /* exos: audit tier rpc write */
--    All three were created or last rewritten by 2026-11 migrations
--    (20261109100000, 20261106130000), so prod's bodies are the chain's
--    (supabase/README.md rule 4). The new markers don't match the
--    '/* exos: audit <group>.<verb> */' pattern test_org_audit.sql counts.
--
-- Touches:  W: FUNCTION _exos_tg_audit_row, exos_set_price_steps,
--              _exos_api_price_steps_set (marker patches, grants unchanged)
-- Grants:   nothing new (H3 unchanged). No table, no cron.
-- Additive, replay-safe (marker-checked patches). Not applied. Prod apply
-- needs operator OK.
-- ROLLBACK: re-run 20261109100000's definition of _exos_tg_audit_row and
--   its patches of exos_set_price_steps / _exos_api_price_steps_set (on
--   20261106130000's bodies).
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

-- ---------------------------------------------------------------------------
-- 1a. The tier trigger leaves a price-step RPC's own tier writes to the RPC.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public._exos_tg_audit_row()', '/* exos: audit tier rpc */',
  $o$        v_ch := public._exos_audit_diff(o, n, v_skip);
        IF v_ch = '{}'::jsonb THEN RETURN NULL; END IF;
        v_act := v_ent || '.update';$o$,
  $n$        v_ch := public._exos_audit_diff(o, n, v_skip);
        IF v_ch = '{}'::jsonb THEN RETURN NULL; END IF;
        /* exos: audit tier rpc */ -- mig 20261111100000: a price-step RPC logs its own change (one row)
        IF v_ent = 'tier' AND current_setting('exos.audit_tier_rpc', true) = v_id THEN RETURN NULL; END IF;
        v_act := v_ent || '.update';$n$, 1);

-- ---------------------------------------------------------------------------
-- 1b. The dashboard's exos_set_price_steps.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_set_price_steps(uuid,jsonb,integer,boolean)', '/* exos: audit tier rpc */',
  $o$DECLARE v_org uuid;$o$,
  $n$DECLARE v_org uuid; v_old jsonb; /* exos: audit tier rpc */$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_set_price_steps(uuid,jsonb,integer,boolean)', '/* exos: audit tier rpc write */',
  $o$  PERFORM public._exos_price_steps_apply(p_tier_id, p_steps);
  IF p_set_door THEN
    UPDATE public.exos_ticket_tiers SET door_price_cents = p_door_price_cents WHERE id = p_tier_id;
  END IF;
  /* exos: audit tier.price_steps */
  PERFORM public._exos_audit(v_org, 'tier.price_steps', 'tier', p_tier_id::text,
    (SELECT t.event_id FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id),
    jsonb_build_object('price_steps', jsonb_build_array(NULL, CASE WHEN jsonb_typeof(p_steps) = 'array' THEN jsonb_array_length(p_steps) END))
      || CASE WHEN p_set_door THEN jsonb_build_object('door_price_cents', jsonb_build_array(NULL, p_door_price_cents)) ELSE '{}'::jsonb END);
  RETURN public._exos_price_steps_json(p_tier_id);$o$,
  $n$  /* exos: audit tier rpc write */ -- mig 20261111100000: the tier's own writes are this one row, [old, new]
  SELECT to_jsonb(t) INTO v_old FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id;
  PERFORM set_config('exos.audit_tier_rpc', p_tier_id::text, true);
  PERFORM public._exos_price_steps_apply(p_tier_id, p_steps);
  IF p_set_door THEN
    UPDATE public.exos_ticket_tiers SET door_price_cents = p_door_price_cents WHERE id = p_tier_id;
  END IF;
  PERFORM set_config('exos.audit_tier_rpc', '', true);
  /* exos: audit tier.price_steps */
  PERFORM public._exos_audit(v_org, 'tier.price_steps', 'tier', p_tier_id::text,
    (SELECT t.event_id FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id),
    jsonb_build_object('price_steps', jsonb_build_array(NULL, CASE WHEN jsonb_typeof(p_steps) = 'array' THEN jsonb_array_length(p_steps) END))
      || public._exos_audit_diff(v_old, (SELECT to_jsonb(t) FROM public.exos_ticket_tiers t WHERE t.id = p_tier_id), '{}',
                                 ARRAY['price', 'door_price_cents']));
  RETURN public._exos_price_steps_json(p_tier_id);$n$, 1);

-- ---------------------------------------------------------------------------
-- 1c. The API's _exos_api_price_steps_set.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public._exos_api_price_steps_set(uuid,uuid,uuid,uuid,jsonb)', '/* exos: audit tier rpc */',
  $o$DECLARE v_key text;$o$,
  $n$DECLARE v_key text; v_old jsonb; /* exos: audit tier rpc */$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_api_price_steps_set(uuid,uuid,uuid,uuid,jsonb)', '/* exos: audit tier rpc write */',
  $o$  IF p ? 'steps' THEN
    PERFORM public._exos_price_steps_apply(p_tier, p -> 'steps');
  END IF;
  IF p ? 'door_price_cents' THEN
    UPDATE public.exos_ticket_tiers SET door_price_cents = (p ->> 'door_price_cents')::int WHERE id = p_tier;
  END IF;
  /* exos: audit tier.price_steps */
  PERFORM public._exos_audit(p_org, 'tier.price_steps', 'tier', p_tier::text, p_event,
    jsonb_build_object('price_steps', jsonb_build_array(NULL, CASE WHEN jsonb_typeof(p -> 'steps') = 'array' THEN jsonb_array_length(p -> 'steps') END))
      || CASE WHEN p ? 'door_price_cents' THEN jsonb_build_object('door_price_cents', jsonb_build_array(NULL, p -> 'door_price_cents')) ELSE '{}'::jsonb END,
    NULL, NULL, NULL, NULL, p_api_key);$o$,
  $n$  /* exos: audit tier rpc write */ -- mig 20261111100000: the tier's own writes are this one row, [old, new]
  SELECT to_jsonb(t) INTO v_old FROM public.exos_ticket_tiers t WHERE t.id = p_tier;
  PERFORM set_config('exos.audit_tier_rpc', p_tier::text, true);
  IF p ? 'steps' THEN
    PERFORM public._exos_price_steps_apply(p_tier, p -> 'steps');
  END IF;
  IF p ? 'door_price_cents' THEN
    UPDATE public.exos_ticket_tiers SET door_price_cents = (p ->> 'door_price_cents')::int WHERE id = p_tier;
  END IF;
  PERFORM set_config('exos.audit_tier_rpc', '', true);
  /* exos: audit tier.price_steps */
  PERFORM public._exos_audit(p_org, 'tier.price_steps', 'tier', p_tier::text, p_event,
    jsonb_build_object('price_steps', jsonb_build_array(NULL, CASE WHEN jsonb_typeof(p -> 'steps') = 'array' THEN jsonb_array_length(p -> 'steps') END))
      || public._exos_audit_diff(v_old, (SELECT to_jsonb(t) FROM public.exos_ticket_tiers t WHERE t.id = p_tier), '{}',
                                 ARRAY['price', 'door_price_cents']),
    NULL, NULL, NULL, NULL, p_api_key);$n$, 1);
