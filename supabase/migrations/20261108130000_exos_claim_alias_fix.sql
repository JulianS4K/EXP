-- ============================================================================
-- Migration 20261108130000 — Exos: transfer claims work again (alias clash)
--
-- Branch:   claude/exos-harness-full
-- Touches:  W: FUNCTION exos_claim_transfer(uuid) (patched in place, marker
--              'exos: claim proof alias'); nothing else.
-- Callers:  exos_claim_transfer(uuid, text) (the claim link), the claim page,
--           marketplace / free-claim flows that claim through it.
-- Pre-reqs: 20260924200848 (prod's hardened body, which declares
--           `t public.exos_tickets%ROWTYPE`), 20261105100000 (the
--           'exos: proof before claim' block this fixes).
--
-- The bug: 20261105100000 added, inside exos_claim_transfer(uuid),
--   IF EXISTS (SELECT 1 FROM public.exos_tickets t JOIN public.exos_order_proofs p
--              ON p.session_id = t.order_ref WHERE t.id = tr.ticket_id ...)
-- Prod's body (from 20260924200848) also declares a row variable named `t`.
-- With plpgsql.variable_conflict = error (the default, and prod's setting),
-- `t.order_ref` is ambiguous, so every claim raised
--   column reference "t.order_ref" is ambiguous
-- from the moment 20261105100000 was applied (2026-11-05 rollout). The text
-- patch matched, so the rollout didn't notice; the SQL harness didn't either,
-- because it never built 20260924200848's body (fixed on this branch: run_p0.sh
-- now applies every *exos* migration).
--
-- The fix renames the table alias to `tk` in that one block. It runs only where
-- the ambiguous text is present: elsewhere (a body without the block, or a
-- replay) it raises a NOTICE and changes nothing. The search text is the block
-- as pg_get_functiondef prints it, newline and indentation included, and must
-- match exactly once (supabase/README.md migration rule 4).
--
-- Checked for the same class on a prod-like build (every *exos* migration in
-- order): no other plpgsql function in public has a row / record variable that
-- a query also uses as a table alias, and exos_claim_transfer(uuid) is the only
-- function whose declarations differ from the harness's old build.
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

DO $claim_alias$
DECLARE
  v_old text := $o$  IF EXISTS (SELECT 1 FROM public.exos_tickets t JOIN public.exos_order_proofs p ON p.session_id = t.order_ref
              WHERE t.id = tr.ticket_id AND p.status <> 'proven') THEN$o$;
  v_def text;
BEGIN
  IF to_regprocedure('public.exos_claim_transfer(uuid)') IS NULL THEN
    RAISE NOTICE 'exos_claim_transfer(uuid) not present; alias fix skipped';
    RETURN;
  END IF;
  v_def := replace(pg_get_functiondef('public.exos_claim_transfer(uuid)'::regprocedure), chr(13), '');
  IF position('/* exos: claim proof alias */' in v_def) > 0 THEN
    RAISE NOTICE 'exos_claim_transfer: alias already fixed; skipped';
  ELSIF position(v_old in v_def) = 0 THEN
    RAISE NOTICE 'exos_claim_transfer: no ambiguous proof block; alias fix skipped';
  ELSE
    PERFORM pg_temp.exos_patch_n('public.exos_claim_transfer(uuid)',
      '/* exos: claim proof alias */',
      v_old,
      $n$  /* exos: claim proof alias */ -- mig 20261108130000: `t` is also the ticket row variable
  IF EXISTS (SELECT 1 FROM public.exos_tickets tk JOIN public.exos_order_proofs p ON p.session_id = tk.order_ref
              WHERE tk.id = tr.ticket_id AND p.status <> 'proven') THEN$n$, 1);
  END IF;
END $claim_alias$;
