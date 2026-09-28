-- ============================================================================
-- Migration 20260929050000 — Exos (Bridge / D4): marketplace sale notes
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_marketplace_orders (+sale_note)
--           W: FUNCTION exos_record_marketplace_order(jsonb),
--              exos_fulfil_marketplace_order(uuid, text) (patched in place)
-- Pre-reqs: 20260929020000
--
-- A Ticket Evolution order can hold several items. The sale used to take its
-- quantity from ALL items but its listing from the FIRST one, so an order
-- spanning two Exos listings would have been fulfilled entirely from the
-- first. normalizeTevoOrder now reports such an order (and one mixing Exos
-- and broker items) with status 'unknown' and a note saying why; the note
-- rides in the payload as sale_note, is stored on the order, and becomes the
-- attention reason instead of the generic "marketplace status is unknown".
-- A later report without a note clears it.
--
-- Re-run safe (IF NOT EXISTS; each patch asserts one match and is skipped
-- once applied). D4 authors; applying to prod is operator-gated.
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

ALTER TABLE public.exos_marketplace_orders ADD COLUMN IF NOT EXISTS sale_note text;
DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_marketplace_orders_sale_note_len') THEN
    ALTER TABLE public.exos_marketplace_orders
      ADD CONSTRAINT exos_marketplace_orders_sale_note_len CHECK (sale_note IS NULL OR length(sale_note) <= 300);
  END IF;
END $c$;
COMMENT ON COLUMN public.exos_marketplace_orders.sale_note IS
  'Why the channel adapter routed the sale to a person (e.g. a TEvo order spanning several Exos listings). Shown as the attention reason.';

-- Record: store the note on insert, replace it on every report that carries the key.
SELECT pg_temp.exos_patch('public.exos_record_marketplace_order(jsonb)',
  'sale_note',
  'confirm_by, ship_by, sold_at, raw
  ) VALUES (',
  'confirm_by, ship_by, sold_at, raw, sale_note
  ) VALUES (');
SELECT pg_temp.exos_patch('public.exos_record_marketplace_order(jsonb)',
  'left(nullif(btrim(coalesce(p_sale ->> ''sale_note''',
  'p_sale -> ''raw''
  )',
  'p_sale -> ''raw'', left(nullif(btrim(coalesce(p_sale ->> ''sale_note'', '''')), ''''), 300)
  )');
SELECT pg_temp.exos_patch('public.exos_record_marketplace_order(jsonb)',
  'sale_note   = CASE',
  'listing_ref = coalesce(EXCLUDED.listing_ref, m.listing_ref),',
  'listing_ref = coalesce(EXCLUDED.listing_ref, m.listing_ref),
        sale_note   = CASE WHEN p_sale ? ''sale_note'' THEN EXCLUDED.sale_note ELSE m.sale_note END,');

-- Fulfil: the note is the reason a person sees.
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'coalesce(o.sale_note,',
  'THEN ''marketplace status is '' || o.sale_status || '': check the sale''',
  'THEN coalesce(o.sale_note, ''marketplace status is '' || o.sale_status || '': check the sale'')');
