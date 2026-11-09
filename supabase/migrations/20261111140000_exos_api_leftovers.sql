-- ============================================================================
-- Migration 20261111140000 — Exos: partner API leftovers (wave 11)
-- ============================================================================
-- Branch: claude/exos-api-leftovers
--
-- 1. A reservation update takes checkout answers (docs/partner-sales.md,
--    docs/checkout-questions.md). PUT /v1/public/confirms/:id/ticket_reservations/:token
--    and PUT /v1/events/:id/organizer-reservations/:token may carry `answers`
--    ({ order: {...}, tickets: [{...}] }, as the reserve). While the
--    reservation is open (active, not past expires_at, nothing minted) the
--    set is REPLACED: checked with the reserve's rules first
--    (_exos_reservation_answers_check: partners' required questions are
--    required, EXQRQ / 422 questions_required; organizers never required,
--    hidden questions allowed; "show only if" conditions; an invalid answer
--    is 22023), then the reservation's unattached answers and their cursor
--    are deleted and the new set recorded (_exos_record_answers, order ref
--    'po:<reservation>', source api). One _exos_audit row per replacement
--    (reservation.answers_replace: the counts before and after, never the
--    values). A completed reservation is 409 (EX409), as an attendee update
--    already was; an expired one answers its status (410 at the edge).
--    The reserve and complete keep their rule (one set, the first sent
--    wins); only the update replaces. All of it runs under the reservation's
--    row lock (_exos_partner_res_lock), which complete takes too, so an
--    update either replaces before the mint or sees the reservation
--    completed (tests/exos/race_api_leftovers.sh race 2).
--    Marker patch on _exos_partner_reservation_update:
--      /* exos: reservation answers update */
--
-- 2. Partner order reads carry answers. GET /v1/public/orders and
--    GET /v1/public/orders/:id (and the ticket_pdfs reads, which read the same
--    order) give each ticket `answers` (the shape of /v1/tickets/:id/answers:
--    question_id, scope, label, kind, value, display; the order's answers on
--    every ticket, then the ticket's own) and `custom_field_values`
--    (Opendate's ticket field: custom_field_id = question id, name = label,
--    value = display). Only the answers THE PARTNER submitted: each answer
--    row now carries its origin (exos_question_answers.partner_reservation_id,
--    set by a BEFORE INSERT trigger only for an 'api' answer recorded for
--    'po:<id>' of a partner reservation while it is still active, before any
--    ticket; cleared by a BEFORE UPDATE trigger whenever anyone later
--    rewrites the answer's value or source). The read also needs source 'api'
--    and a row created at or before the reservation's completion. So a door
--    answer, an organizer's or a later holder's answer (after a transfer, a
--    claim), or an in-place edit of the partner's answer, is never returned
--    to the partner. Only questions not hidden from checkout (hidden ones are
--    staff-only), only the partner's own completed orders (the existing
--    _exos_partner_orders / _exos_partner_order filters). Organizer reads
--    (p_partner_id NULL) are unchanged: their answers come with the
--    credential's scopes (docs/checkout-questions.md "API").
--    Marker patches: _exos_partner_orders /* exos: partner order answers */,
--                    _exos_partner_order  /* exos: partner order answers */
--
-- 3. The holder reissues an add-on wallet pass (docs/wallet.md "Add-on
--    passes"): exos_wallet_addon_reissue (authenticated, the pass's holder
--    only; 42501 for anyone else, the pass unnamed) bumps
--    exos_addon_passes.wallet_epoch, so every earlier A-…:a|g{epoch} code is
--    refused at the door (_exos_addon_wallet_check compares the live epoch;
--    the door's saved keys change with it), and returns the fresh pass
--    payload (exos_wallet_addon_pass). At most 5 a rolling day per holder
--    (counted in exos_addon_wallet_reissues under a per-holder advisory
--    lock, checked before anything changes; 'rate-limited' with
--    retry_after_seconds); a voided pass, or one never added to a wallet
--    ('no-pass'), is not reissued. Logged in exos_addon_wallet_reissues and
--    with _exos_audit (addon_pass.wallet_reissue).
--    exos_my_addon_passes also returns wallet_epoch (marker
--    /* exos: addon wallet epoch */) so the app offers "Reissue" only for a
--    pass that is in a wallet.
--
-- Touches:  C: TABLE exos_addon_wallet_reissues (RLS: owner / manager of the
--              org read; no client writes)
--           W: TABLE exos_question_answers (+partner_reservation_id, two
--              BEFORE triggers: _exos_tg_answer_partner_origin), backfilled
--              for partner answers recorded before this migration
--           C: FUNCTION _exos_reservation_answers_replace,
--              _exos_partner_ticket_answers, _exos_partner_order_answers_json
--              (service role only), exos_wallet_addon_reissue (authenticated)
--           W: FUNCTION _exos_partner_reservation_update, _exos_partner_orders,
--              _exos_partner_order (20261031130000), exos_my_addon_passes
--              (20261107110000): one marker patch each; all created by
--              2026-10/11 migrations and patched by none since, so prod's
--              bodies are the chain's (supabase/README.md rule 4).
-- Grants:   authenticated: exos_wallet_addon_reissue. Nothing new for anon
--           (H3 unchanged).
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked
-- patches). No cron. Not applied. Prod apply needs operator OK.
-- ROLLBACK: DROP the two exos_question_answers origin triggers, their
--           function and the partner_reservation_id column; DROP the four
--           functions and the table above; re-create
--           _exos_partner_reservation_update, _exos_partner_orders and
--           _exos_partner_order from 20261031130000 and exos_my_addon_passes
--           from 20261107110000.
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
-- 1. A reservation update replaces its answers while it is open
-- ===========================================================================
-- p_partner: the caller is a distribution partner (required questions are
-- required, hidden ones refused) rather than the organizer. The caller holds
-- the reservation's row lock (_exos_partner_res_lock); it is locked again
-- here so the function is safe on its own. Returns {replaced, recorded}.
CREATE OR REPLACE FUNCTION public._exos_reservation_answers_replace(p_res uuid, p_partner boolean, p_answers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r     public.exos_partner_reservations%ROWTYPE;
  v_ref text;
  v_old int;
  v_new int;
BEGIN
  SELECT * INTO r FROM public.exos_partner_reservations WHERE id = p_res FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reservation not found' USING ERRCODE = 'P0002';
  END IF;
  IF r.status <> 'active' OR r.expires_at <= now() THEN
    RAISE EXCEPTION 'answers can only change while the reservation is open (it is %)',
      CASE WHEN r.status = 'active' THEN 'expired' ELSE r.status END USING ERRCODE = 'EX409';
  END IF;
  IF p_answers IS NULL OR jsonb_typeof(p_answers) <> 'object' THEN
    RAISE EXCEPTION 'answers must be an object: { order: { <question id>: value }, tickets: [{ <question id>: value }] }'
      USING ERRCODE = '22023';
  END IF;
  v_ref := 'po:' || r.id;
  -- Nothing is minted while the reservation is active; an attached answer
  -- would mean a ticket already took it, so refuse rather than orphan it.
  IF EXISTS (SELECT 1 FROM public.exos_question_answers a
              WHERE a.order_ref = v_ref AND (a.attached_at IS NOT NULL OR a.ticket_id IS NOT NULL)) THEN
    RAISE EXCEPTION 'answers can only change while the reservation is open' USING ERRCODE = 'EX409';
  END IF;
  -- The reserve's rules, before anything is removed.
  PERFORM public._exos_reservation_answers_check(r.event_id, coalesce(p_partner, true), r.lines, p_answers);
  DELETE FROM public.exos_question_answers a WHERE a.order_ref = v_ref AND a.org_id = r.org_id AND a.event_id = r.event_id;
  GET DIAGNOSTICS v_old = ROW_COUNT;
  DELETE FROM public.exos_question_answer_cursors c WHERE c.order_ref = v_ref AND c.org_id = r.org_id;
  v_new := public._exos_record_answers(r.org_id, r.event_id, v_ref, public._exos_reservation_answer_tiers(r.lines),
                                       p_answers, false, NOT coalesce(p_partner, true), 'api', NULL);
  /* exos: audit reservation.answers_replace */
  PERFORM public._exos_audit(r.org_id, 'reservation.answers_replace', 'partner_reservation', r.id::text, r.event_id,
    jsonb_build_object('answers', jsonb_build_array(v_old, v_new), 'channel', r.channel), NULL, NULL, NULL, NULL, NULL, 'api');
  RETURN jsonb_build_object('replaced', v_old, 'recorded', v_new);
END $$;
REVOKE ALL ON FUNCTION public._exos_reservation_answers_replace(uuid, boolean, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_reservation_answers_replace(uuid, boolean, jsonb) TO service_role;

-- The update takes `answers` (p_attrs.answers) once the reservation is known
-- to be active, before the attendee fields change (one transaction).
SELECT pg_temp.exos_patch_n('public._exos_partner_reservation_update(uuid,uuid,text,jsonb)',
  '/* exos: reservation answers update */',
  '  IF r.status <> ''active'' THEN
    RAISE EXCEPTION ''this reservation is %'', r.status USING ERRCODE = ''EX409'';
  END IF;
',
  '  IF r.status <> ''active'' THEN
    RAISE EXCEPTION ''this reservation is %'', r.status USING ERRCODE = ''EX409'';
  END IF;
  /* exos: reservation answers update */ -- mig 20261111140000: replaced while open, partners'' required ones required
  IF a ? ''answers'' THEN
    PERFORM public._exos_reservation_answers_replace(r.id, p_partner_id IS NOT NULL, a -> ''answers'');
  END IF;
', 1);

-- ===========================================================================
-- 2. Partner order reads carry each ticket's answers
-- ===========================================================================
-- Where an answer came from. A partner's answers (reserve, comps, complete,
-- update) are all inserted by _exos_record_answers for 'po:<id>' with source
-- 'api' while the reservation is active and before any ticket exists; only
-- then is the origin set. An organizer reservation (no partner) never gets
-- one; neither does an answer added to a minted ticket (_exos_set_ticket_answers
-- inserts with ticket_id set) or anything after completion. The origin can
-- only be cleared: rewriting an answer's value, display, source or question
-- (the door, an org key, a later holder) drops it, and it can't be set or
-- moved by an UPDATE.
ALTER TABLE public.exos_question_answers ADD COLUMN IF NOT EXISTS partner_reservation_id uuid
  REFERENCES public.exos_partner_reservations (id) ON DELETE SET NULL;
COMMENT ON COLUMN public.exos_question_answers.partner_reservation_id IS
  'The partner reservation whose partner submitted this exact answer (mig 20261111140000); NULL for any other origin or once rewritten. Partner order reads return only these.';
CREATE INDEX IF NOT EXISTS exos_question_answers_partner_res_idx ON public.exos_question_answers (partner_reservation_id)
  WHERE partner_reservation_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public._exos_tg_answer_partner_origin()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.partner_reservation_id := NULL;
    IF NEW.source = 'api' AND NEW.ticket_id IS NULL AND NEW.attached_at IS NULL
       AND NEW.order_ref ~ '^po:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      SELECT r.id INTO NEW.partner_reservation_id FROM public.exos_partner_reservations r
       WHERE r.id = substr(NEW.order_ref, 4)::uuid AND r.org_id = NEW.org_id AND r.event_id = NEW.event_id
         AND r.partner_id IS NOT NULL AND r.status = 'active';
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE: never set or moved; cleared when the answer itself is rewritten.
  NEW.partner_reservation_id := CASE
    WHEN NEW.value IS DISTINCT FROM OLD.value OR NEW.display IS DISTINCT FROM OLD.display
      OR NEW.source IS DISTINCT FROM OLD.source OR NEW.question_id IS DISTINCT FROM OLD.question_id
      OR NEW.order_ref IS DISTINCT FROM OLD.order_ref THEN NULL
    ELSE OLD.partner_reservation_id END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_answer_partner_origin() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_question_answers_partner_origin_ins ON public.exos_question_answers;
CREATE TRIGGER exos_question_answers_partner_origin_ins BEFORE INSERT ON public.exos_question_answers
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_answer_partner_origin();
DROP TRIGGER IF EXISTS exos_question_answers_partner_origin_upd ON public.exos_question_answers;
CREATE TRIGGER exos_question_answers_partner_origin_upd BEFORE UPDATE ON public.exos_question_answers
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_answer_partner_origin();

-- Answers recorded before this migration (wave 9's reserve / complete): the
-- partner's when they are 'api' answers of a partner reservation, created
-- and last changed no later than its completion (the attach at complete
-- stamps updated_at in the same transaction), or of one still open.
-- Re-run safe: only rows without an origin.
UPDATE public.exos_question_answers a SET partner_reservation_id = r.id
  FROM public.exos_partner_reservations r
 WHERE a.partner_reservation_id IS NULL AND a.order_ref = 'po:' || r.id
   AND a.org_id = r.org_id AND a.event_id = r.event_id AND r.partner_id IS NOT NULL AND a.source = 'api'
   AND ((r.status = 'active' AND a.ticket_id IS NULL)
        OR (r.status = 'completed' AND a.created_at <= r.completed_at AND a.updated_at <= r.completed_at));

-- One ticket's answers as a partner sees them: only the ones that partner
-- submitted for this reservation (origin set, source api, created by its
-- completion), the order's and this ticket's, never a question hidden from
-- checkout (staff-only). The ticket must be one of the reservation's.
CREATE OR REPLACE FUNCTION public._exos_partner_ticket_answers(p_res uuid, p_ticket uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('question_id', a.question_id, 'scope', a.scope, 'label', a.label,
                                               'kind', a.kind, 'value', a.value, 'display', a.display)
                            ORDER BY a.scope, q.sort_order, a.created_at, a.id), '[]'::jsonb)
    FROM public.exos_partner_reservations r
    JOIN public.exos_question_answers a
      ON a.order_ref = 'po:' || r.id AND a.org_id = r.org_id AND a.event_id = r.event_id
     AND a.partner_reservation_id = r.id AND a.source = 'api' AND a.created_at <= r.completed_at
    JOIN public.exos_event_questions q ON q.id = a.question_id AND q.event_id = r.event_id
   WHERE r.id = p_res AND r.partner_id IS NOT NULL AND r.status = 'completed'
     AND p_ticket = ANY (r.ticket_ids) AND NOT q.hidden
     AND ((a.scope = 'order' AND a.attached_at IS NOT NULL) OR (a.scope = 'ticket' AND a.ticket_id = p_ticket))
$$;
REVOKE ALL ON FUNCTION public._exos_partner_ticket_answers(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_ticket_answers(uuid, uuid) TO service_role;

-- The partner's order: _exos_partner_order_json with answers and Opendate's
-- custom_field_values on each ticket.
CREATE OR REPLACE FUNCTION public._exos_partner_order_answers_json(p_id uuid, p_app_base text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN o.j IS NULL THEN NULL ELSE jsonb_set(o.j, '{tickets}', coalesce((
    SELECT jsonb_agg(t || jsonb_build_object(
             'answers', x.ans,
             'custom_field_values', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                       'custom_field_id', e ->> 'question_id', 'name', e ->> 'label', 'value', e ->> 'display')
                                       ORDER BY m), '[]'::jsonb)
                                       FROM jsonb_array_elements(x.ans) WITH ORDINALITY y(e, m)))
           ORDER BY n)
      FROM jsonb_array_elements(coalesce(o.j -> 'tickets', '[]'::jsonb)) WITH ORDINALITY z(t, n),
           LATERAL (SELECT public._exos_partner_ticket_answers(p_id, (t ->> 'id')::uuid) AS ans) x), '[]'::jsonb)) END
    FROM (SELECT public._exos_partner_order_json(p_id, p_app_base) AS j) o
$$;
REVOKE ALL ON FUNCTION public._exos_partner_order_answers_json(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_order_answers_json(uuid, text) TO service_role;

-- The list is partners' only (partner_id = p_partner_id, never NULL).
SELECT pg_temp.exos_patch_n('public._exos_partner_orders(uuid,uuid,jsonb,integer,integer,text)',
  '/* exos: partner order answers */',
  'public._exos_partner_order_json(p.id, p_app_base)',
  'public._exos_partner_order_answers_json(p.id, p_app_base) /* exos: partner order answers */', 1);
-- The single read serves organizers too (p_partner_id NULL): unchanged for them.
SELECT pg_temp.exos_patch_n('public._exos_partner_order(uuid,uuid,uuid,text)',
  '/* exos: partner order answers */',
  'public._exos_partner_order_json(r.id, p_app_base)',
  'CASE WHEN p_partner_id IS NOT NULL /* exos: partner order answers */
              THEN public._exos_partner_order_answers_json(r.id, p_app_base)
              ELSE public._exos_partner_order_json(r.id, p_app_base) END', 1);

-- ===========================================================================
-- 3. The holder reissues an add-on wallet pass
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_addon_wallet_reissues (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id   uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  pass_id    uuid NOT NULL REFERENCES public.exos_addon_passes (id) ON DELETE CASCADE,
  holder_id  uuid NOT NULL,
  old_epoch  integer NOT NULL,
  new_epoch  integer NOT NULL CHECK (new_epoch > old_epoch),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_addon_wallet_reissues_holder_idx ON public.exos_addon_wallet_reissues (holder_id, created_at);
CREATE INDEX IF NOT EXISTS exos_addon_wallet_reissues_org_idx ON public.exos_addon_wallet_reissues (org_id);
CREATE INDEX IF NOT EXISTS exos_addon_wallet_reissues_event_idx ON public.exos_addon_wallet_reissues (event_id);
CREATE INDEX IF NOT EXISTS exos_addon_wallet_reissues_pass_idx ON public.exos_addon_wallet_reissues (pass_id);
COMMENT ON TABLE public.exos_addon_wallet_reissues IS
  'A holder''s add-on wallet pass reissues (mig 20261111140000): the epoch before and after; the per-holder daily limit counts these.';
ALTER TABLE public.exos_addon_wallet_reissues ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_addon_wallet_reissues FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_addon_wallet_reissues TO authenticated;
GRANT ALL ON public.exos_addon_wallet_reissues TO service_role;
DROP POLICY IF EXISTS exos_addon_wallet_reissues_staff_read ON public.exos_addon_wallet_reissues;
CREATE POLICY exos_addon_wallet_reissues_staff_read ON public.exos_addon_wallet_reissues FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
DROP POLICY IF EXISTS exos_addon_wallet_reissues_holder_read ON public.exos_addon_wallet_reissues;
CREATE POLICY exos_addon_wallet_reissues_holder_read ON public.exos_addon_wallet_reissues FOR SELECT TO authenticated
  USING (holder_id = (SELECT auth.uid()));

-- POST /exos-wallet/addon-reissue (the holder's JWT). Order: the caller, the
-- per-holder lock, the pass (holder only), the limit, then the change.
CREATE OR REPLACE FUNCTION public.exos_wallet_addon_reissue(p_pass_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c_limit CONSTANT integer := 5;
  v_uid   uuid := auth.uid();
  ps      public.exos_addon_passes%ROWTYPE;
  v_n     integer;
  v_first timestamptz;
  v_new   integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_wallet_addon_reissue: not authenticated' USING ERRCODE = '42501';
  END IF;
  -- One reissue at a time per holder, so parallel calls can't both pass the count.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_addon_wallet_reissue:' || v_uid::text, 0));
  SELECT * INTO ps FROM public.exos_addon_passes WHERE id = p_pass_id FOR UPDATE;
  IF NOT FOUND OR ps.owner_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'exos_wallet_addon_reissue: not your add-on pass' USING ERRCODE = '42501';
  END IF;
  IF ps.status = 'voided' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'voided');
  END IF;
  IF ps.wallet_epoch IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no-pass');
  END IF;
  SELECT count(*), min(x.created_at) INTO v_n, v_first FROM public.exos_addon_wallet_reissues x
   WHERE x.holder_id = v_uid AND x.created_at > now() - interval '1 day';
  IF v_n >= c_limit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate-limited', 'limit', c_limit,
      'retry_after_seconds', greatest(ceil(extract(epoch FROM v_first + interval '1 day' - now()))::int, 1));
  END IF;
  UPDATE public.exos_addon_passes SET wallet_epoch = wallet_epoch + 1 WHERE id = ps.id RETURNING wallet_epoch INTO v_new;
  INSERT INTO public.exos_addon_wallet_reissues (org_id, event_id, pass_id, holder_id, old_epoch, new_epoch)
  VALUES (ps.org_id, ps.event_id, ps.id, v_uid, ps.wallet_epoch, v_new);
  /* exos: audit addon_pass.wallet_reissue */
  PERFORM public._exos_audit(ps.org_id, 'addon_pass.wallet_reissue', 'addon_pass', ps.id::text, ps.event_id,
    jsonb_build_object('wallet_epoch', jsonb_build_array(ps.wallet_epoch, v_new)), NULL, NULL, 'holder reissue');
  RETURN public.exos_wallet_addon_pass(ps.id)
         || jsonb_build_object('reissued', true, 'code_epoch', v_new, 'reissues_left', c_limit - v_n - 1);
END $$;
REVOKE ALL ON FUNCTION public.exos_wallet_addon_reissue(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wallet_addon_reissue(uuid) TO authenticated, service_role;

-- The app shows "Reissue" only for a unit that is in a wallet.
SELECT pg_temp.exos_patch_n('public.exos_my_addon_passes(uuid)', '/* exos: addon wallet epoch */',
  '''owner_id'', p.owner_id, ''barcode_secret'',',
  '''owner_id'', p.owner_id, ''wallet_epoch'', p.wallet_epoch /* exos: addon wallet epoch */, ''barcode_secret'',', 1);
