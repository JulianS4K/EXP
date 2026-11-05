-- ============================================================================
-- Migration 20261106110000 — Exos: checkout questions (KANBAN "DICE gaps" 2;
-- DICE's Ticket.fanSurveyAnswers { fanSurveyQuestion { title } value })
-- ============================================================================
-- Organizers ask buyers questions at checkout: "T-shirt size?", "Dietary
-- needs?", "Company name", "I agree to the venue's photo policy". Answers are
-- kept per order and per ticket, the organizer sees and exports them, door
-- staff see a ticket's answers, and the partner API exposes them
-- (docs/checkout-questions.md, docs/api/questions.json).
--
-- Design (borrowed from pretix Question / QuestionAnswer and hi.events'
-- question "belongs to" order or product; our own implementation):
--   * A question belongs to one event, optionally to some of its ticket types
--     (tier_ids NULL = all). Its scope is 'order' (asked once) or 'ticket'
--     (asked for every ticket, so a table of 8 is asked 8 times).
--   * Kinds: text, long_text, single_choice, multiple_choice, checkbox
--     ("I agree"), number, date, phone, email; limits: max_length (text),
--     min/max_choices (multiple choice), min/max_value (number).
--   * hidden: not asked at checkout (staff can still fill it at the door or
--     through the API); archived_at: "deleted". Both keep every answer.
--   * Each answer snapshots the question's label and kind at purchase, so
--     renaming a question later never rewrites what a buyer answered.
--     Changing the kind or scope of a question that has answers is refused
--     (archive it and add a new one); making it required changes nothing
--     for orders already placed (answers are checked when they're recorded).
--
-- Answers are recorded BEFORE the tickets exist, keyed by the order's
-- reference (the tickets' order_ref: the checkout session id, the free
-- claim's order ref, 'rsvp:<id>', 'po:<id>'), with a 1-based ticket number
-- for per-ticket answers and a cursor row per order. An AFTER INSERT trigger
-- on exos_tickets hands the n-th ticket minted for that order the answers of
-- ticket n. So nothing in exos_fulfill_checkout / exos_mint_tickets is
-- patched, and the answers of a paid order sit in the database from the
-- moment the Stripe session is created: a buyer who pays and comes back
-- hours later (or whose webhook is late, or who proves their email days
-- later) loses nothing. The proof-of-email release moves tickets to the
-- buyer by UPDATE (same ticket ids), and a trigger fills the answers' buyer.
--
-- 1. exos_event_questions (+ RLS: the event's org staff read; writes only
--    through the functions below).
-- 2. exos_question_answers (+ RLS: owner / manager / finance read every
--    answer of their org; the buyer reads their own; door staff of the
--    event read its per-ticket answers ("needs wheelchair access")).
-- 3. exos_question_answer_cursors: per order, how many tickets have taken
--    their answers (service role only).
-- 4. _exos_normalize_answer / _exos_validate_answers_core: the answer rules,
--    mirrored in TypeScript by supabase/functions/_shared/questions.ts; the
--    harness and src/lib/checkoutQuestions.test.ts run the same cases.
--    _exos_validate_answers(event, ticket tiers, answers, require): the
--    event's questions + the core.
-- 5. _exos_record_answers (core), exos_record_checkout_answers (exos-checkout,
--    service role), exos_claim_free_tickets_answered (the app's free claim /
--    RSVP), exos_rsvp_record_answers + exos_rsvp_questions (exos-rsvp, phone
--    RSVP), _exos_api_reservation_answers (organizer reservations, API),
--    exos_door_set_ticket_answers (door staff, optional answers at the door).
-- 6. Trigger exos_tickets_question_answers (attach on mint) and
--    exos_tickets_question_answers_buyer (fill the buyer when a parked
--    ticket is released to them).
-- 7. exos_claim_free_tickets: refuses a claim that skips required questions
--    (marker /* exos: checkout questions */). Its answered wrapper sets
--    exos.answers_ok for its own order ref.
-- 8. Organizer: exos_list_event_questions, exos_save_event_question,
--    exos_archive_event_question, exos_reorder_event_questions,
--    exos_event_question_answers (the answers table / CSV), and the API
--    cores _exos_api_questions, _exos_question_upsert, _exos_question_archive,
--    _exos_questions_reorder, _exos_event_answer_rows, _exos_answers_for.
-- 9. Buyers: exos_public_event_questions (anon: the questions of a published
--    event, and each table tier's party size).
--
-- Touches:  C: TABLE exos_event_questions, exos_question_answers,
--              exos_question_answer_cursors
--           C: FUNCTION (see above), TRIGGER on exos_tickets (AFTER INSERT,
--              AFTER UPDATE OF buyer_id)
--           W: FUNCTION exos_claim_free_tickets (marker patch, guard only)
-- Grants:   anon + authenticated: exos_public_event_questions (H3 allowlist)
--           authenticated: exos_claim_free_tickets_answered, the organizer
--              functions (owner / manager write; + finance read answers),
--              exos_door_set_ticket_answers (door staff of the event)
--           service_role: everything else; no client grant on the cores
-- Pre-reqs: 20260605132500 (free claim), 20260926050000 (party size),
--           20260929041000 (exos_can_door_event), 20261102150000 (phone
--           RSVP), 20261031130000 (partner reservations), 20261104180000
--           (_exos_api_key_actor), 20261105100000 (proof of email)
-- Additive and re-run safe.
-- ============================================================================

-- Marker-checked patches (pg_temp.exos_patch_n, as 20261105150000).
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
-- 1. Questions
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_event_questions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs(id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events(id) ON DELETE CASCADE,
  tier_ids    uuid[],
  label       text NOT NULL,
  help_text   text,
  kind        text NOT NULL,
  options     text[] NOT NULL DEFAULT '{}',
  required    boolean NOT NULL DEFAULT false,
  scope       text NOT NULL DEFAULT 'order',
  sort_order  integer NOT NULL DEFAULT 0,
  hidden      boolean NOT NULL DEFAULT false,
  archived_at timestamptz,
  max_length  integer,
  min_choices integer,
  max_choices integer,
  min_value   numeric,
  max_value   numeric,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_event_questions_kind_chk CHECK (kind IN
    ('text', 'long_text', 'single_choice', 'multiple_choice', 'checkbox', 'number', 'date', 'phone', 'email')),
  CONSTRAINT exos_event_questions_scope_chk CHECK (scope IN ('order', 'ticket')),
  CONSTRAINT exos_event_questions_label_chk CHECK (char_length(btrim(label)) BETWEEN 1 AND 200),
  CONSTRAINT exos_event_questions_help_chk CHECK (help_text IS NULL OR char_length(help_text) <= 500),
  CONSTRAINT exos_event_questions_options_chk CHECK (
    CASE WHEN kind IN ('single_choice', 'multiple_choice') THEN cardinality(options) BETWEEN 2 AND 50
         ELSE cardinality(options) = 0 END),
  CONSTRAINT exos_event_questions_tiers_chk CHECK (tier_ids IS NULL OR cardinality(tier_ids) BETWEEN 1 AND 200),
  CONSTRAINT exos_event_questions_length_chk CHECK (max_length IS NULL OR
    (kind = 'text' AND max_length BETWEEN 1 AND 2000) OR (kind = 'long_text' AND max_length BETWEEN 1 AND 5000)),
  CONSTRAINT exos_event_questions_choices_chk CHECK ((min_choices IS NULL AND max_choices IS NULL) OR (
    kind = 'multiple_choice' AND coalesce(min_choices, 0) >= 0 AND coalesce(max_choices, 1) >= 1
    AND coalesce(min_choices, 0) <= coalesce(max_choices, cardinality(options))
    AND coalesce(max_choices, 0) <= cardinality(options))),
  CONSTRAINT exos_event_questions_range_chk CHECK ((min_value IS NULL AND max_value IS NULL) OR (
    kind = 'number' AND (min_value IS NULL OR abs(min_value) < 1e12) AND (max_value IS NULL OR abs(max_value) < 1e12)
    AND (min_value IS NULL OR max_value IS NULL OR min_value <= max_value)))
);
CREATE INDEX IF NOT EXISTS exos_event_questions_event_idx ON public.exos_event_questions (event_id, sort_order);
CREATE INDEX IF NOT EXISTS exos_event_questions_org_idx ON public.exos_event_questions (org_id);
COMMENT ON TABLE public.exos_event_questions IS
  'Checkout questions of an event (mig 20261106110000, docs/checkout-questions.md). Written only through '
  'exos_save_event_question / _exos_question_upsert; archived_at = deleted (answers kept).';

ALTER TABLE public.exos_event_questions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_event_questions_staff_read ON public.exos_event_questions;
CREATE POLICY exos_event_questions_staff_read ON public.exos_event_questions
  FOR SELECT TO authenticated
  USING (public.exos_is_admin()
         OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance', 'scanner', 'content']));
REVOKE ALL ON public.exos_event_questions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_event_questions TO authenticated;
GRANT ALL ON public.exos_event_questions TO service_role;
DROP TRIGGER IF EXISTS exos_event_questions_touch ON public.exos_event_questions;
CREATE TRIGGER exos_event_questions_touch BEFORE UPDATE ON public.exos_event_questions
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ===========================================================================
-- 2. Answers
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_question_answers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs(id) ON DELETE CASCADE,
  event_id     uuid NOT NULL REFERENCES public.exos_events(id) ON DELETE CASCADE,
  question_id  uuid NOT NULL REFERENCES public.exos_event_questions(id) ON DELETE CASCADE,
  -- The order: exos_tickets.order_ref of its tickets (the checkout session id,
  -- a free claim's ref, 'rsvp:<id>', 'po:<id>').
  order_ref    text NOT NULL,
  scope        text NOT NULL,
  -- Per-ticket answers: the ticket's number in the order (1-based, mint
  -- order) until it is minted, then also ticket_id. An answer added at the
  -- door to an existing ticket has ticket_id only.
  ticket_index integer,
  ticket_id    uuid REFERENCES public.exos_tickets(id) ON DELETE SET NULL,
  label        text NOT NULL,     -- the question's label at purchase
  kind         text NOT NULL,     -- the question's kind at purchase
  value        jsonb NOT NULL,    -- normalised: string, number, true, or an array of strings
  display      text NOT NULL,     -- how it reads (exports, DICE's string value)
  source       text NOT NULL DEFAULT 'checkout',
  buyer_uid    uuid,
  attached_at  timestamptz,       -- when the order's tickets existed (NULL: not minted)
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_question_answers_scope_chk CHECK (
    (scope = 'order' AND ticket_index IS NULL AND ticket_id IS NULL)
    OR (scope = 'ticket' AND (ticket_index IS NOT NULL OR ticket_id IS NOT NULL))),
  CONSTRAINT exos_question_answers_index_chk CHECK (ticket_index IS NULL OR ticket_index BETWEEN 1 AND 100),
  CONSTRAINT exos_question_answers_ref_chk CHECK (char_length(order_ref) BETWEEN 1 AND 200),
  CONSTRAINT exos_question_answers_source_chk CHECK (source IN ('checkout', 'free_claim', 'rsvp', 'door', 'api')),
  CONSTRAINT exos_question_answers_value_chk CHECK (jsonb_typeof(value) IN ('string', 'number', 'boolean', 'array')
    AND length(value::text) <= 12000),
  CONSTRAINT exos_question_answers_display_chk CHECK (char_length(display) <= 12000)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_question_answers_order_uq
  ON public.exos_question_answers (order_ref, question_id) WHERE scope = 'order';
CREATE UNIQUE INDEX IF NOT EXISTS exos_question_answers_index_uq
  ON public.exos_question_answers (order_ref, question_id, ticket_index) WHERE ticket_index IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_question_answers_ticket_uq
  ON public.exos_question_answers (question_id, ticket_id) WHERE ticket_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_question_answers_event_idx ON public.exos_question_answers (event_id, created_at);
CREATE INDEX IF NOT EXISTS exos_question_answers_ticket_idx ON public.exos_question_answers (ticket_id) WHERE ticket_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_question_answers_ref_idx ON public.exos_question_answers (order_ref);
CREATE INDEX IF NOT EXISTS exos_question_answers_buyer_idx ON public.exos_question_answers (buyer_uid) WHERE buyer_uid IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_question_answers_org_idx ON public.exos_question_answers (org_id);
CREATE INDEX IF NOT EXISTS exos_question_answers_question_idx ON public.exos_question_answers (question_id);
COMMENT ON TABLE public.exos_question_answers IS
  'Buyers'' answers to checkout questions, per order or per ticket, with the question''s label at purchase '
  '(mig 20261106110000). Recorded before mint; trigger exos_tickets_question_answers attaches them.';

ALTER TABLE public.exos_question_answers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_question_answers_staff_read ON public.exos_question_answers;
CREATE POLICY exos_question_answers_staff_read ON public.exos_question_answers
  FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
DROP POLICY IF EXISTS exos_question_answers_buyer_read ON public.exos_question_answers;
CREATE POLICY exos_question_answers_buyer_read ON public.exos_question_answers
  FOR SELECT TO authenticated
  USING (buyer_uid IS NOT NULL AND buyer_uid = auth.uid());
-- Door staff: the per-ticket answers of an event they may scan.
DROP POLICY IF EXISTS exos_question_answers_door_read ON public.exos_question_answers;
CREATE POLICY exos_question_answers_door_read ON public.exos_question_answers
  FOR SELECT TO authenticated
  USING (scope = 'ticket' AND public.exos_can_door_event(event_id));
REVOKE ALL ON public.exos_question_answers FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_question_answers TO authenticated;
GRANT ALL ON public.exos_question_answers TO service_role;
DROP TRIGGER IF EXISTS exos_question_answers_touch ON public.exos_question_answers;
CREATE TRIGGER exos_question_answers_touch BEFORE UPDATE ON public.exos_question_answers
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ===========================================================================
-- 3. Per-order cursor: the next ticket number to hand answers to.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_question_answer_cursors (
  order_ref    text PRIMARY KEY,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs(id) ON DELETE CASCADE,
  event_id     uuid NOT NULL REFERENCES public.exos_events(id) ON DELETE CASCADE,
  -- Set when every ticket of the order is of one type: a ticket of another
  -- type with the same order ref never takes these answers.
  tier_id      uuid,
  buyer_uid    uuid,
  ticket_count integer NOT NULL CHECK (ticket_count BETWEEN 1 AND 100),
  next_index   integer NOT NULL DEFAULT 1 CHECK (next_index >= 1),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_question_answer_cursors_event_idx ON public.exos_question_answer_cursors (event_id);
CREATE INDEX IF NOT EXISTS exos_question_answer_cursors_org_idx ON public.exos_question_answer_cursors (org_id);
ALTER TABLE public.exos_question_answer_cursors ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_question_answer_cursors FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_question_answer_cursors TO service_role;
DROP TRIGGER IF EXISTS exos_question_answer_cursors_touch ON public.exos_question_answer_cursors;
CREATE TRIGGER exos_question_answer_cursors_touch BEFORE UPDATE ON public.exos_question_answer_cursors
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ===========================================================================
-- 4. The answer rules (mirror: supabase/functions/_shared/questions.ts)
-- ===========================================================================
-- "Nothing answered": missing, null, blank text, [], false.
CREATE OR REPLACE FUNCTION public._exos_answer_is_empty(p_v jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT p_v IS NULL OR jsonb_typeof(p_v) = 'null' OR p_v = 'false'::jsonb
      OR (jsonb_typeof(p_v) = 'string' AND btrim(p_v #>> '{}', E' \t\r\n') = '')
      OR (jsonb_typeof(p_v) = 'array' AND jsonb_array_length(p_v) = 0)
$$;

-- How an answer reads: 'Yes', the text, the number, the choices joined.
CREATE OR REPLACE FUNCTION public._exos_answer_display(p_v jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE jsonb_typeof(p_v)
           WHEN 'boolean' THEN CASE WHEN p_v = 'true'::jsonb THEN 'Yes' ELSE '' END
           WHEN 'array' THEN (SELECT coalesce(string_agg(x, ', ' ORDER BY n), '') FROM jsonb_array_elements_text(p_v) WITH ORDINALITY AS e(x, n))
           WHEN 'null' THEN ''
           ELSE coalesce(p_v #>> '{}', '') END
$$;

-- One non-empty answer to question p_q (a question as jsonb, the shape of
-- _exos_question_def): {"value": ...} or {"problem": "<code>"}.
CREATE OR REPLACE FUNCTION public._exos_normalize_answer(p_q jsonb, p_v jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  k      text := p_q->>'kind';
  t      text := jsonb_typeof(p_v);
  s      text;
  n      numeric;
  opts   text[];
  picked text[];
  v_out  text[];
  mx     int;
  cap    int;
  def    int;
  y int; mo int; d int; dim int;
  m      text[];
BEGIN
  opts := CASE WHEN jsonb_typeof(p_q->'options') = 'array'
               THEN ARRAY(SELECT jsonb_array_elements_text(p_q->'options')) ELSE '{}'::text[] END;
  IF k IN ('text', 'long_text') THEN
    IF t <> 'string' THEN RETURN '{"problem":"invalid_value"}'; END IF;
    s := btrim(p_v #>> '{}', E' \t\r\n');
    cap := CASE WHEN k = 'long_text' THEN 5000 ELSE 2000 END;
    def := CASE WHEN k = 'long_text' THEN 2000 ELSE 500 END;
    mx := CASE WHEN jsonb_typeof(p_q->'max_length') = 'number' THEN floor((p_q->>'max_length')::numeric)::int ELSE def END;
    mx := greatest(1, least(cap, mx));
    IF char_length(s) > mx THEN RETURN '{"problem":"too_long"}'; END IF;
    RETURN jsonb_build_object('value', s);
  ELSIF k = 'single_choice' THEN
    IF t <> 'string' THEN RETURN '{"problem":"invalid_value"}'; END IF;
    s := btrim(p_v #>> '{}', E' \t\r\n');
    IF s = ANY (opts) THEN RETURN jsonb_build_object('value', s); END IF;
    RETURN '{"problem":"invalid_choice"}';
  ELSIF k = 'multiple_choice' THEN
    IF t <> 'array' THEN RETURN '{"problem":"invalid_value"}'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_v) e WHERE jsonb_typeof(e) <> 'string') THEN
      RETURN '{"problem":"invalid_value"}';
    END IF;
    picked := ARRAY(SELECT DISTINCT btrim(x, E' \t\r\n') FROM jsonb_array_elements_text(p_v) x);
    IF EXISTS (SELECT 1 FROM unnest(picked) x WHERE NOT (x = ANY (opts))) THEN
      RETURN '{"problem":"invalid_choice"}';
    END IF;
    v_out := ARRAY(SELECT o FROM unnest(opts) WITH ORDINALITY AS u(o, i) WHERE o = ANY (picked) ORDER BY i);
    IF jsonb_typeof(p_q->'max_choices') = 'number' AND cardinality(v_out) > (p_q->>'max_choices')::int THEN
      RETURN '{"problem":"too_many_choices"}';
    END IF;
    IF jsonb_typeof(p_q->'min_choices') = 'number' AND cardinality(v_out) < (p_q->>'min_choices')::int THEN
      RETURN '{"problem":"too_few_choices"}';
    END IF;
    RETURN jsonb_build_object('value', to_jsonb(v_out));
  ELSIF k = 'checkbox' THEN
    IF p_v = 'true'::jsonb THEN RETURN '{"value":true}'; END IF;
    RETURN '{"problem":"invalid_value"}';
  ELSIF k = 'number' THEN
    IF t = 'number' THEN
      n := (p_v #>> '{}')::numeric;
      IF abs(n) >= 1e12 THEN RETURN '{"problem":"not_a_number"}'; END IF;
      s := trim_scale(n)::text;
    ELSIF t = 'string' THEN
      s := btrim(p_v #>> '{}', E' \t\r\n');
    ELSE
      RETURN '{"problem":"not_a_number"}';
    END IF;
    IF s !~ '^-?[0-9]{1,12}(\.[0-9]{1,6})?$' THEN RETURN '{"problem":"not_a_number"}'; END IF;
    n := s::numeric;
    IF (jsonb_typeof(p_q->'min_value') = 'number' AND n < (p_q->>'min_value')::numeric)
       OR (jsonb_typeof(p_q->'max_value') = 'number' AND n > (p_q->>'max_value')::numeric) THEN
      RETURN '{"problem":"out_of_range"}';
    END IF;
    RETURN jsonb_build_object('value', trim_scale(n));
  ELSIF k = 'date' THEN
    IF t <> 'string' THEN RETURN '{"problem":"invalid_date"}'; END IF;
    s := btrim(p_v #>> '{}', E' \t\r\n');
    m := regexp_match(s, '^([0-9]{4})-([0-9]{2})-([0-9]{2})$');
    IF m IS NULL THEN RETURN '{"problem":"invalid_date"}'; END IF;
    y := m[1]::int; mo := m[2]::int; d := m[3]::int;
    IF y < 1900 OR y > 2100 OR mo < 1 OR mo > 12 OR d < 1 THEN RETURN '{"problem":"invalid_date"}'; END IF;
    dim := (ARRAY[31, CASE WHEN (y % 4 = 0 AND y % 100 <> 0) OR y % 400 = 0 THEN 29 ELSE 28 END,
                  31, 30, 31, 30, 31, 31, 30, 31, 30, 31])[mo];
    IF d > dim THEN RETURN '{"problem":"invalid_date"}'; END IF;
    RETURN jsonb_build_object('value', s);
  ELSIF k = 'phone' THEN
    IF t <> 'string' THEN RETURN '{"problem":"invalid_phone"}'; END IF;
    s := regexp_replace(btrim(p_v #>> '{}', E' \t\r\n'), '[ ().-]', '', 'g');
    IF s ~ '^\+?[0-9]{7,15}$' THEN RETURN jsonb_build_object('value', s); END IF;
    RETURN '{"problem":"invalid_phone"}';
  ELSIF k = 'email' THEN
    IF t <> 'string' THEN RETURN '{"problem":"invalid_email"}'; END IF;
    s := lower(btrim(p_v #>> '{}', E' \t\r\n'));
    IF char_length(s) <= 254 AND s ~ E'^[^ \t\r\n@]+@[^ \t\r\n@]+\\.[^ \t\r\n@]+$' THEN
      RETURN jsonb_build_object('value', s);
    END IF;
    RETURN '{"problem":"invalid_email"}';
  END IF;
  RETURN '{"problem":"invalid_value"}';
END $$;

-- Does question p_q apply to a ticket of type p_tier?
CREATE OR REPLACE FUNCTION public._exos_question_applies(p_q jsonb, p_tier uuid)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_typeof(p_q->'tier_ids') IS DISTINCT FROM 'array'
      OR jsonb_array_length(p_q->'tier_ids') = 0
      OR (p_q->'tier_ids') ? p_tier::text
$$;

-- The answers to p_questions (a jsonb array of question defs) for an order
-- whose tickets are of types p_ticket_tiers. Returns
--   {"ok": true,  "answers": {"order": {...}, "tickets": [{...}, ...]}, "problems": []}
--   {"ok": false, "answers": null, "problems": [{"code", "question_id", "ticket"}]}
-- p_require false: the required check is skipped (the door, the API).
CREATE OR REPLACE FUNCTION public._exos_validate_answers_core(
  p_questions jsonb, p_ticket_tiers uuid[], p_answers jsonb, p_require boolean)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_body  jsonb := coalesce(p_answers, '{}'::jsonb);
  v_order jsonb;
  v_tix   jsonb;
  v_n     int := coalesce(cardinality(p_ticket_tiers), 0);
  v_qs    jsonb := CASE WHEN jsonb_typeof(p_questions) = 'array' THEN p_questions ELSE '[]'::jsonb END;
  v_probs jsonb := '[]'::jsonb;
  v_out_o jsonb := '{}'::jsonb;
  v_out_t jsonb := '[]'::jsonb;
  v_t     jsonb;
  v_row   jsonb;
  q       jsonb;
  k       text;
  r       jsonb;
  i       int;
  bad     CONSTANT jsonb := '{"ok": false, "answers": null}'::jsonb;
BEGIN
  IF jsonb_typeof(v_body) = 'null' THEN v_body := '{}'::jsonb; END IF;
  IF jsonb_typeof(v_body) <> 'object' THEN
    RETURN bad || jsonb_build_object('problems', jsonb_build_array(jsonb_build_object('code', 'bad_shape', 'question_id', NULL, 'ticket', NULL)));
  END IF;
  v_order := v_body->'order';
  IF v_order IS NULL OR jsonb_typeof(v_order) = 'null' THEN v_order := '{}'::jsonb; END IF;
  v_tix := v_body->'tickets';
  IF v_tix IS NULL OR jsonb_typeof(v_tix) = 'null' THEN v_tix := '[]'::jsonb; END IF;
  IF jsonb_typeof(v_order) <> 'object' OR jsonb_typeof(v_tix) <> 'array'
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_tix) e WHERE jsonb_typeof(e) NOT IN ('object', 'null')) THEN
    RETURN bad || jsonb_build_object('problems', jsonb_build_array(jsonb_build_object('code', 'bad_shape', 'question_id', NULL, 'ticket', NULL)));
  END IF;
  IF v_n > 100 OR jsonb_array_length(v_tix) > v_n THEN
    RETURN bad || jsonb_build_object('problems', jsonb_build_array(jsonb_build_object('code', 'too_many_tickets', 'question_id', NULL, 'ticket', NULL)));
  END IF;

  -- Keys that aren't a question asked here.
  FOR k IN SELECT jsonb_object_keys(v_order) LOOP
    q := (SELECT x FROM jsonb_array_elements(v_qs) x WHERE x->>'id' = k LIMIT 1);
    IF q IS NULL THEN
      v_probs := v_probs || jsonb_build_object('code', 'unknown_question', 'question_id', k, 'ticket', NULL);
    ELSIF q->>'scope' <> 'order' THEN
      v_probs := v_probs || jsonb_build_object('code', 'wrong_scope', 'question_id', k, 'ticket', NULL);
    ELSIF NOT EXISTS (SELECT 1 FROM unnest(p_ticket_tiers) tt WHERE public._exos_question_applies(q, tt)) THEN
      v_probs := v_probs || jsonb_build_object('code', 'not_for_ticket_type', 'question_id', k, 'ticket', NULL);
    END IF;
  END LOOP;
  FOR i IN 1..jsonb_array_length(v_tix) LOOP
    v_t := v_tix->(i - 1);
    IF jsonb_typeof(v_t) <> 'object' THEN CONTINUE; END IF;
    FOR k IN SELECT jsonb_object_keys(v_t) LOOP
      q := (SELECT x FROM jsonb_array_elements(v_qs) x WHERE x->>'id' = k LIMIT 1);
      IF q IS NULL THEN
        v_probs := v_probs || jsonb_build_object('code', 'unknown_question', 'question_id', k, 'ticket', i);
      ELSIF q->>'scope' <> 'ticket' THEN
        v_probs := v_probs || jsonb_build_object('code', 'wrong_scope', 'question_id', k, 'ticket', i);
      ELSIF NOT public._exos_question_applies(q, p_ticket_tiers[i]) THEN
        v_probs := v_probs || jsonb_build_object('code', 'not_for_ticket_type', 'question_id', k, 'ticket', i);
      END IF;
    END LOOP;
  END LOOP;

  -- Order-wide questions.
  FOR q IN SELECT x FROM jsonb_array_elements(v_qs) x LOOP
    CONTINUE WHEN q->>'scope' <> 'order'
               OR NOT EXISTS (SELECT 1 FROM unnest(p_ticket_tiers) tt WHERE public._exos_question_applies(q, tt));
    IF public._exos_answer_is_empty(v_order->(q->>'id')) THEN
      IF p_require AND (q->>'required')::boolean IS TRUE THEN
        v_probs := v_probs || jsonb_build_object('code', 'required', 'question_id', q->>'id', 'ticket', NULL);
      END IF;
      CONTINUE;
    END IF;
    r := public._exos_normalize_answer(q, v_order->(q->>'id'));
    IF r ? 'problem' THEN
      v_probs := v_probs || jsonb_build_object('code', r->>'problem', 'question_id', q->>'id', 'ticket', NULL);
    ELSE
      v_out_o := v_out_o || jsonb_build_object(q->>'id', r->'value');
    END IF;
  END LOOP;

  -- Per-ticket questions, ticket by ticket.
  FOR i IN 1..v_n LOOP
    v_t := v_tix->(i - 1);
    IF v_t IS NULL OR jsonb_typeof(v_t) <> 'object' THEN v_t := '{}'::jsonb; END IF;
    v_row := '{}'::jsonb;
    FOR q IN SELECT x FROM jsonb_array_elements(v_qs) x LOOP
      CONTINUE WHEN q->>'scope' <> 'ticket' OR NOT public._exos_question_applies(q, p_ticket_tiers[i]);
      IF public._exos_answer_is_empty(v_t->(q->>'id')) THEN
        IF p_require AND (q->>'required')::boolean IS TRUE THEN
          v_probs := v_probs || jsonb_build_object('code', 'required', 'question_id', q->>'id', 'ticket', i);
        END IF;
        CONTINUE;
      END IF;
      r := public._exos_normalize_answer(q, v_t->(q->>'id'));
      IF r ? 'problem' THEN
        v_probs := v_probs || jsonb_build_object('code', r->>'problem', 'question_id', q->>'id', 'ticket', i);
      ELSE
        v_row := v_row || jsonb_build_object(q->>'id', r->'value');
      END IF;
    END LOOP;
    v_out_t := v_out_t || jsonb_build_array(v_row);
  END LOOP;

  IF jsonb_array_length(v_probs) > 0 THEN
    RETURN bad || jsonb_build_object('problems', v_probs);
  END IF;
  RETURN jsonb_build_object('ok', true, 'answers', jsonb_build_object('order', v_out_o, 'tickets', v_out_t), 'problems', '[]'::jsonb);
END $$;

-- One question row as the jsonb shape the rules and the API use.
CREATE OR REPLACE FUNCTION public._exos_question_def(q public.exos_event_questions)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', q.id, 'event_id', q.event_id, 'label', q.label, 'help_text', q.help_text, 'kind', q.kind,
    'options', to_jsonb(q.options), 'required', q.required, 'scope', q.scope,
    'tier_ids', CASE WHEN q.tier_ids IS NULL THEN NULL ELSE to_jsonb(q.tier_ids) END,
    'max_length', q.max_length, 'min_choices', q.min_choices, 'max_choices', q.max_choices,
    'min_value', q.min_value, 'max_value', q.max_value, 'sort_order', q.sort_order,
    'hidden', q.hidden, 'archived', q.archived_at IS NOT NULL, 'archived_at', q.archived_at,
    'created_at', q.created_at, 'updated_at', q.updated_at)
$$;

-- The questions an event asks (active; hidden ones only when p_include_hidden).
CREATE OR REPLACE FUNCTION public._exos_question_defs(p_event_id uuid, p_include_hidden boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(public._exos_question_def(q) ORDER BY q.sort_order, q.created_at, q.id), '[]'::jsonb)
    FROM public.exos_event_questions q
   WHERE q.event_id = p_event_id AND q.archived_at IS NULL AND (p_include_hidden OR NOT q.hidden)
$$;

-- The event's questions + the rules.
CREATE OR REPLACE FUNCTION public._exos_validate_answers(
  p_event_id uuid, p_ticket_tiers uuid[], p_answers jsonb, p_require boolean, p_include_hidden boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_validate_answers_core(public._exos_question_defs(p_event_id, p_include_hidden),
                                            p_ticket_tiers, p_answers, p_require)
$$;

-- A validation result's first problem as a 22023 error a buyer can read.
-- The label named is only ever one of p_event's own questions, and never for
-- an unknown question (whatever id a caller sends, another event's or another
-- org's label can't be echoed back).
CREATE OR REPLACE FUNCTION public._exos_raise_answer_problem(p_result jsonb, p_event_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  p jsonb := p_result->'problems'->0;
  v_label text;
BEGIN
  IF p IS NULL THEN RETURN; END IF;
  IF p->>'code' IS DISTINCT FROM 'unknown_question' AND p_event_id IS NOT NULL THEN
    SELECT q.label INTO v_label FROM public.exos_event_questions q
      JOIN public.exos_events e ON e.id = q.event_id AND e.org_id = q.org_id
     WHERE q.event_id = p_event_id AND q.id::text = p->>'question_id';
  END IF;
  RAISE EXCEPTION '%', left(
    CASE WHEN v_label IS NOT NULL THEN 'checkout question "' || v_label || '"' ELSE 'checkout questions' END ||
    CASE WHEN p->>'ticket' IS NOT NULL THEN ' (ticket ' || (p->>'ticket') || ')' ELSE '' END || ': ' ||
    CASE p->>'code'
      WHEN 'required' THEN 'an answer is required'
      WHEN 'unknown_question' THEN 'this question is not asked for this event'
      WHEN 'wrong_scope' THEN 'answered at the wrong level (order vs ticket)'
      WHEN 'not_for_ticket_type' THEN 'not asked for this ticket type'
      WHEN 'invalid_choice' THEN 'pick one of the options'
      WHEN 'too_long' THEN 'the answer is too long'
      WHEN 'too_many_choices' THEN 'too many options picked'
      WHEN 'too_few_choices' THEN 'pick more options'
      WHEN 'not_a_number' THEN 'enter a number'
      WHEN 'out_of_range' THEN 'the number is out of range'
      WHEN 'invalid_date' THEN 'enter a date as YYYY-MM-DD'
      WHEN 'invalid_phone' THEN 'enter a phone number'
      WHEN 'invalid_email' THEN 'enter an email address'
      WHEN 'too_many_tickets' THEN 'answers for more tickets than the order has'
      WHEN 'bad_shape' THEN 'the answers are not in the expected form'
      ELSE 'the answer is not valid' END, 300)
    USING ERRCODE = '22023', DETAIL = (p_result->'problems')::text, HINT = coalesce(p->>'code', '');
END $$;

-- Are there required questions a buyer of these ticket types must answer?
CREATE OR REPLACE FUNCTION public._exos_required_questions_for(p_event_id uuid, p_tiers uuid[])
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_event_questions q
     WHERE q.event_id = p_event_id AND q.archived_at IS NULL AND NOT q.hidden AND q.required
       AND (q.tier_ids IS NULL OR q.tier_ids && p_tiers))
$$;

-- ===========================================================================
-- 5. Recording answers
-- ===========================================================================
-- Validate and store the answers of an order whose tickets don't exist yet.
-- Once per order ref: a retry (same ref, same buyer) records nothing again;
-- the ref of another buyer's or another event's order is refused. Returns the
-- number of answers stored.
CREATE OR REPLACE FUNCTION public._exos_record_answers(
  p_org uuid, p_event uuid, p_order_ref text, p_ticket_tiers uuid[], p_answers jsonb,
  p_require boolean, p_include_hidden boolean, p_source text, p_buyer uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_res   jsonb;
  v_cur   public.exos_question_answer_cursors%ROWTYPE;
  v_n     int := coalesce(cardinality(p_ticket_tiers), 0);
  v_count int := 0;
  v_tier  uuid;
  k       text;
  i       int;
  v_val   jsonb;
  q       public.exos_event_questions%ROWTYPE;
BEGIN
  IF p_order_ref IS NULL OR char_length(p_order_ref) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'checkout questions: an order reference is needed' USING ERRCODE = '22023';
  END IF;
  -- An event that asks nothing (any more): nothing to check or keep,
  -- whatever the size of the order; stale answers from an old page are dropped.
  IF NOT EXISTS (SELECT 1 FROM public.exos_event_questions eq
                  WHERE eq.event_id = p_event AND eq.archived_at IS NULL AND (p_include_hidden OR NOT eq.hidden)) THEN
    RETURN 0;
  END IF;
  IF v_n < 1 OR v_n > 100 THEN
    RAISE EXCEPTION 'checkout questions: an order has 1 to 100 tickets' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_cur FROM public.exos_question_answer_cursors WHERE order_ref = p_order_ref;
  IF FOUND THEN
    IF v_cur.event_id <> p_event OR v_cur.buyer_uid IS DISTINCT FROM p_buyer THEN
      RAISE EXCEPTION 'checkout questions: this order reference is already in use' USING ERRCODE = '42501';
    END IF;
    RETURN 0;
  END IF;

  v_res := public._exos_validate_answers(p_event, p_ticket_tiers, p_answers, p_require, p_include_hidden);
  IF (v_res->>'ok')::boolean IS NOT TRUE THEN
    PERFORM public._exos_raise_answer_problem(v_res, p_event);
  END IF;
  IF v_res->'answers'->'order' = '{}'::jsonb
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'answers'->'tickets') x WHERE x <> '{}'::jsonb) THEN
    RETURN 0;  -- nothing to keep
  END IF;

  v_tier := CASE WHEN (SELECT count(DISTINCT x) FROM unnest(p_ticket_tiers) x) = 1 THEN p_ticket_tiers[1] END;
  INSERT INTO public.exos_question_answer_cursors (order_ref, org_id, event_id, tier_id, buyer_uid, ticket_count)
  VALUES (p_order_ref, p_org, p_event, v_tier, p_buyer, v_n)
  ON CONFLICT (order_ref) DO NOTHING;
  IF NOT FOUND THEN
    RETURN 0;  -- a concurrent retry got there first
  END IF;

  FOR k, v_val IN SELECT key, value FROM jsonb_each(v_res->'answers'->'order') LOOP
    SELECT * INTO q FROM public.exos_event_questions WHERE id = k::uuid;
    INSERT INTO public.exos_question_answers (org_id, event_id, question_id, order_ref, scope, label, kind, value, display, source, buyer_uid)
    VALUES (p_org, p_event, q.id, p_order_ref, 'order', q.label, q.kind, v_val, public._exos_answer_display(v_val), p_source, p_buyer);
    v_count := v_count + 1;
  END LOOP;
  FOR i IN 1..v_n LOOP
    FOR k, v_val IN SELECT key, value FROM jsonb_each(v_res->'answers'->'tickets'->(i - 1)) LOOP
      SELECT * INTO q FROM public.exos_event_questions WHERE id = k::uuid;
      INSERT INTO public.exos_question_answers (org_id, event_id, question_id, order_ref, scope, ticket_index, label, kind, value, display, source, buyer_uid)
      VALUES (p_org, p_event, q.id, p_order_ref, 'ticket', i, q.label, q.kind, v_val, public._exos_answer_display(v_val), p_source, p_buyer);
      v_count := v_count + 1;
    END LOOP;
  END LOOP;
  RETURN v_count;
END $$;

-- exos-checkout (service role): the answers of a pending checkout session,
-- stored before the buyer is sent to pay. Required questions must be
-- answered. Returns {"recorded": n}.
CREATE OR REPLACE FUNCTION public.exos_record_checkout_answers(p_session_id text, p_answers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  s   public.exos_checkout_sessions%ROWTYPE;
  v_n int;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_record_checkout_answers: unknown session' USING ERRCODE = 'P0002';
  END IF;
  IF s.status <> 'pending' OR s.tier_id IS NULL THEN
    RAISE EXCEPTION 'exos_record_checkout_answers: the order is %', s.status USING ERRCODE = '22023';
  END IF;
  v_n := s.quantity * public.exos_tier_party_size(s.tier_id);
  RETURN jsonb_build_object('recorded', public._exos_record_answers(
    s.org_id, s.event_id, s.session_id, array_fill(s.tier_id, ARRAY[v_n]), p_answers, true, false, 'checkout', s.buyer_uid));
END $$;

-- What exos-checkout needs to check a body's answers (service role): the
-- buyer-facing questions and the ticket type of each ticket.
CREATE OR REPLACE FUNCTION public._exos_checkout_question_ctx(p_event_id uuid, p_tier_id uuid, p_quantity integer)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'questions', public._exos_question_defs(p_event_id, false),
    'ticket_tiers', to_jsonb(array_fill(p_tier_id, ARRAY[least(greatest(coalesce(p_quantity, 1), 1), 10) * public.exos_tier_party_size(p_tier_id)])))
$$;

-- The app's free claim (and free RSVP) with answers: records them for the
-- claim's order ref, then claims through exos_claim_free_tickets, which
-- refuses a claim that skips required questions unless it comes through
-- here (exos.answers_ok = this order ref, this transaction only).
CREATE OR REPLACE FUNCTION public.exos_claim_free_tickets_answered(
  p_event_id uuid, p_tier_id uuid, p_quantity integer DEFAULT 1, p_promoter_id text DEFAULT NULL,
  p_channel text DEFAULT NULL, p_order_ref text DEFAULT NULL, p_answers jsonb DEFAULT NULL)
RETURNS uuid[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_org  uuid;
  v_ids  uuid[];
  v_ref  text := btrim(coalesce(p_order_ref, ''));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_claim_free_tickets_answered: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF v_ref !~ '^[A-Za-z0-9_:-]{8,100}$' THEN
    RAISE EXCEPTION 'exos_claim_free_tickets_answered: an order reference is needed' USING ERRCODE = '22023';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 10 THEN
    RAISE EXCEPTION 'exos_claim_free_tickets_answered: quantity must be 1-10' USING ERRCODE = '22023';
  END IF;
  SELECT e.org_id INTO v_org FROM public.exos_events e
    JOIN public.exos_ticket_tiers t ON t.event_id = e.id AND t.id = p_tier_id
   WHERE e.id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_claim_free_tickets_answered: tier not found for this event';
  END IF;
  -- A retry of a claim that already minted returns its tickets.
  IF NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE event_id = p_event_id AND owner_id = v_uid AND order_ref = v_ref) THEN
    PERFORM public._exos_record_answers(v_org, p_event_id, v_ref,
      array_fill(p_tier_id, ARRAY[p_quantity * public.exos_tier_party_size(p_tier_id)]),
      p_answers, true, false, 'free_claim', v_uid);
  END IF;
  PERFORM set_config('exos.answers_ok', v_ref, true);
  v_ids := public.exos_claim_free_tickets(p_event_id, p_tier_id, p_quantity, p_promoter_id, p_channel, v_ref);
  PERFORM set_config('exos.answers_ok', '', true);
  RETURN v_ids;
END $$;

-- Phone RSVP (exos-rsvp, service role): the questions of the RSVP ticket
-- type, and the answers of a started RSVP (attached when it is verified;
-- its tickets' order ref is 'rsvp:<id>'). A refused answer expires the RSVP.
CREATE OR REPLACE FUNCTION public.exos_rsvp_questions(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tier uuid;
BEGIN
  SELECT o.tier_id INTO v_tier FROM public._exos_phone_rsvp_offer(p_event_id) o;
  IF v_tier IS NULL THEN RETURN jsonb_build_object('tier_id', NULL, 'questions', '[]'::jsonb); END IF;
  RETURN jsonb_build_object('tier_id', v_tier, 'questions', coalesce((
    SELECT jsonb_agg(x ORDER BY (x->>'sort_order')::int)
      FROM jsonb_array_elements(public._exos_question_defs(p_event_id, false)) x
     WHERE public._exos_question_applies(x, v_tier)), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION public.exos_rsvp_record_answers(p_rsvp_id uuid, p_answers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r     public.exos_phone_rsvps%ROWTYPE;
  v_n   int;
  v_res jsonb;
  v_cnt int;
BEGIN
  SELECT * INTO r FROM public.exos_phone_rsvps WHERE id = p_rsvp_id;
  IF NOT FOUND OR r.status <> 'pending' OR r.tier_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_pending');
  END IF;
  v_n := 1 + coalesce(r.plus_ones, 0);
  v_res := public._exos_validate_answers(r.event_id, array_fill(r.tier_id, ARRAY[v_n]), p_answers, true, false);
  IF (v_res->>'ok')::boolean IS NOT TRUE THEN
    UPDATE public.exos_phone_rsvps SET status = 'expired' WHERE id = r.id AND status = 'pending';
    RETURN jsonb_build_object('ok', false, 'error', 'answers', 'problems', v_res->'problems');
  END IF;
  v_cnt := public._exos_record_answers(r.org_id, r.event_id, 'rsvp:' || r.id, array_fill(r.tier_id, ARRAY[v_n]),
                                       p_answers, true, false, 'rsvp', NULL);
  RETURN jsonb_build_object('ok', true, 'recorded', v_cnt);
END $$;

-- Organizer reservations (exos-api, service role): optional answers sent
-- with the complete call; the reservation's tickets take them as they're
-- minted (order ref 'po:<id>'). Not required (the box office asks).
CREATE OR REPLACE FUNCTION public._exos_api_reservation_answers(p_org uuid, p_token text, p_answers jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r      public.exos_partner_reservations%ROWTYPE;
  v_tiers uuid[];
BEGIN
  SELECT * INTO r FROM public.exos_partner_reservations WHERE org_id = p_org AND token = p_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reservation not found' USING ERRCODE = 'P0002';
  END IF;
  IF r.status <> 'active' THEN
    RETURN 0;
  END IF;
  SELECT array_agg(t ORDER BY o, n) INTO v_tiers
    FROM jsonb_array_elements(r.lines) WITH ORDINALITY AS l(line, o),
         LATERAL generate_series(1, greatest(coalesce((line->>'quantity')::int, 0), 0)) AS g(n),
         LATERAL (SELECT (line->>'tier_id')::uuid AS t) x;
  IF v_tiers IS NULL THEN RETURN 0; END IF;
  RETURN public._exos_record_answers(p_org, r.event_id, 'po:' || r.id, v_tiers, p_answers, false, true, 'api', NULL);
END $$;

-- Set (or clear) answers on a ticket that exists: per-ticket questions only,
-- hidden ones included, nothing required. p_answers is { <question id>: value };
-- an empty value removes that answer. Returns the ticket's answers.
CREATE OR REPLACE FUNCTION public._exos_set_ticket_answers(p_ticket_id uuid, p_answers jsonb, p_source text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  t     public.exos_tickets%ROWTYPE;
  v_res jsonb;
  v_val jsonb;
  k     text;
  q     public.exos_event_questions%ROWTYPE;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ticket not found' USING ERRCODE = 'P0002'; END IF;
  IF p_answers IS NULL OR jsonb_typeof(p_answers) <> 'object' THEN
    RAISE EXCEPTION 'answers must be an object of question id: value' USING ERRCODE = '22023';
  END IF;
  v_res := public._exos_validate_answers(t.event_id, ARRAY[coalesce(t.tier_id, '00000000-0000-0000-0000-000000000000'::uuid)],
                                         jsonb_build_object('tickets', jsonb_build_array(p_answers)), false, true);
  IF (v_res->>'ok')::boolean IS NOT TRUE THEN
    PERFORM public._exos_raise_answer_problem(v_res, t.event_id);
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_answers) LOOP
    SELECT * INTO q FROM public.exos_event_questions WHERE id = k::uuid;
    v_val := v_res->'answers'->'tickets'->0->k;
    IF v_val IS NULL THEN
      DELETE FROM public.exos_question_answers WHERE question_id = q.id AND ticket_id = t.id;
      CONTINUE;
    END IF;
    UPDATE public.exos_question_answers
       SET value = v_val, display = public._exos_answer_display(v_val), source = p_source
     WHERE question_id = q.id AND ticket_id = t.id;
    IF NOT FOUND THEN
      INSERT INTO public.exos_question_answers (org_id, event_id, question_id, order_ref, scope, ticket_id, label, kind,
                                                value, display, source, buyer_uid, attached_at)
      VALUES (t.org_id, t.event_id, q.id, coalesce(t.order_ref, 'ticket:' || t.id), 'ticket', t.id, q.label, q.kind,
              v_val, public._exos_answer_display(v_val), p_source,
              (SELECT a.buyer_uid FROM public.exos_question_answers a WHERE a.order_ref = t.order_ref AND a.buyer_uid IS NOT NULL LIMIT 1),
              now());
    END IF;
  END LOOP;
  -- The door's own view: per-ticket answers only (as its RLS read).
  RETURN public._exos_answers_for(ARRAY[t.id], false) -> (t.id::text);
END $$;

-- Door staff (owner / manager, or a scanner of this event): answers taken at
-- the door, e.g. a walk-up's T-shirt size. Optional; never required.
CREATE OR REPLACE FUNCTION public.exos_door_set_ticket_answers(p_ticket_id uuid, p_answers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_event uuid;
BEGIN
  SELECT event_id INTO v_event FROM public.exos_tickets WHERE id = p_ticket_id;
  IF v_event IS NULL OR auth.uid() IS NULL OR NOT public.exos_can_door_event(v_event) THEN
    RAISE EXCEPTION 'exos_door_set_ticket_answers: not authorized for this ticket' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_set_ticket_answers(p_ticket_id, p_answers, 'door');
END $$;

-- ===========================================================================
-- 6. Triggers on exos_tickets
-- ===========================================================================
-- The n-th ticket minted for an order takes the answers of ticket n (and the
-- first one marks the order's own answers as attached). Only a ticket of the
-- order's buyer does: the ticket's buyer is the cursor's buyer, or the ticket
-- is parked on the org owner (as exos_fulfill_checkout parks a guest's or an
-- unconfirmed account's tickets until proof of email, and phone RSVPs and
-- organizer reservations are issued) for an order with no buyer, or for the
-- checkout session of that buyer. Anyone else minting with the same
-- order_ref takes nothing and moves nothing.
CREATE OR REPLACE FUNCTION public._exos_tg_ticket_answers_attach()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_i int;
BEGIN
  UPDATE public.exos_question_answer_cursors c
     SET next_index = c.next_index + 1
   WHERE c.order_ref = NEW.order_ref AND c.event_id = NEW.event_id
     AND (c.tier_id IS NULL OR c.tier_id = NEW.tier_id)
     AND c.next_index <= c.ticket_count
     AND (c.buyer_uid IS NOT DISTINCT FROM NEW.buyer_id
          OR (NEW.buyer_id IS NOT DISTINCT FROM (SELECT o.owner_uid FROM public.exos_orgs o WHERE o.id = NEW.org_id)
              AND (c.buyer_uid IS NULL
                   OR EXISTS (SELECT 1 FROM public.exos_checkout_sessions s
                               WHERE s.session_id = NEW.order_ref AND s.buyer_uid = c.buyer_uid))))
  RETURNING c.next_index - 1 INTO v_i;
  IF v_i IS NULL THEN RETURN NULL; END IF;
  UPDATE public.exos_question_answers
     SET ticket_id = NEW.id, attached_at = now()
   WHERE order_ref = NEW.order_ref AND ticket_index = v_i AND ticket_id IS NULL;
  IF v_i = 1 THEN
    UPDATE public.exos_question_answers SET attached_at = now()
     WHERE order_ref = NEW.order_ref AND scope = 'order' AND attached_at IS NULL;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS exos_tickets_question_answers ON public.exos_tickets;
CREATE TRIGGER exos_tickets_question_answers AFTER INSERT ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.order_ref IS NOT NULL) EXECUTE FUNCTION public._exos_tg_ticket_answers_attach();

-- A guest's (or unconfirmed account's) tickets are parked on the org owner
-- until the buyer proves their email; when they move to the buyer, the
-- buyer can read the order's answers.
CREATE OR REPLACE FUNCTION public._exos_tg_ticket_answers_buyer()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE public.exos_question_answers
     SET buyer_uid = NEW.buyer_id
   WHERE order_ref = NEW.order_ref AND event_id = NEW.event_id AND buyer_uid IS NULL
     AND NEW.buyer_id IS DISTINCT FROM (SELECT o.owner_uid FROM public.exos_orgs o WHERE o.id = NEW.org_id);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS exos_tickets_question_answers_buyer ON public.exos_tickets;
CREATE TRIGGER exos_tickets_question_answers_buyer AFTER UPDATE OF buyer_id ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.buyer_id IS DISTINCT FROM OLD.buyer_id AND NEW.buyer_id IS NOT NULL AND NEW.order_ref IS NOT NULL)
  EXECUTE FUNCTION public._exos_tg_ticket_answers_buyer();

-- ===========================================================================
-- 7. The free claim refuses to skip required questions
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_claim_free_tickets(uuid,uuid,integer,text,text,text)',
  '/* exos: checkout questions */',
  $o$  -- Per-person limit (cumulative; no admin bypass on the self-serve path).
$o$,
  $n$  /* exos: checkout questions */ -- mig 20261106110000: an order ref whose
  -- answers belong to another buyer (or to a guest / RSVP / reservation order)
  -- is refused; required questions are answered through
  -- exos_claim_free_tickets_answered (it sets exos.answers_ok).
  IF EXISTS (SELECT 1 FROM public.exos_question_answer_cursors c
              WHERE c.order_ref = nullif(p_order_ref, '') AND c.buyer_uid IS DISTINCT FROM v_uid) THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: this order reference is already in use' USING ERRCODE = '42501';
  END IF;
  IF coalesce(current_setting('exos.answers_ok', true), '') IS DISTINCT FROM coalesce(nullif(p_order_ref, ''), '-')
     AND public._exos_required_questions_for(p_event_id, ARRAY[p_tier_id]) THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: answer the checkout questions first' USING ERRCODE = '22023';
  END IF;
  -- Per-person limit (cumulative; no admin bypass on the self-serve path).
$n$, 1);

-- ===========================================================================
-- 8. Organizer: questions and the answers table
-- ===========================================================================
-- Every question of an event (archived included) with its answer count.
CREATE OR REPLACE FUNCTION public._exos_api_questions(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(public._exos_question_def(q) || jsonb_build_object(
           'answer_count', (SELECT count(*) FROM public.exos_question_answers a WHERE a.question_id = q.id))
         ORDER BY q.archived_at IS NOT NULL, q.sort_order, q.created_at, q.id), '[]'::jsonb)
    FROM public.exos_event_questions q
   WHERE q.event_id = p_event AND q.org_id = p_org
$$;

-- Create (p_id NULL) or change a question. p is the question as jsonb
-- (label, help_text, kind, options, required, scope, tier_ids, max_length,
-- min_choices, max_choices, min_value, max_value, hidden, archived,
-- sort_order); on a change only the keys present are changed.
CREATE OR REPLACE FUNCTION public._exos_question_upsert(p_org uuid, p_event uuid, p_id uuid, p jsonb, p_actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  q       public.exos_event_questions%ROWTYPE;
  v_new   boolean := p_id IS NULL;
  v_opts  text[];
  v_tiers uuid[];
  v_has   boolean;
  v_allowed CONSTANT text[] := ARRAY['label', 'help_text', 'kind', 'options', 'required', 'scope', 'tier_ids',
    'max_length', 'min_choices', 'max_choices', 'min_value', 'max_value', 'hidden', 'archived', 'sort_order'];
  k text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'send the question as an object' USING ERRCODE = '22023';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF NOT (k = ANY (v_allowed)) THEN
      RAISE EXCEPTION 'unknown field %', left(k, 60) USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_new THEN
    IF (SELECT count(*) FROM public.exos_event_questions WHERE event_id = p_event AND archived_at IS NULL) >= 50 THEN
      RAISE EXCEPTION 'an event asks at most 50 questions; archive one first' USING ERRCODE = '22023';
    END IF;
    q.id := gen_random_uuid(); q.org_id := p_org; q.event_id := p_event; q.created_by := p_actor;
    q.kind := 'text'; q.scope := 'order'; q.required := false; q.hidden := false; q.options := '{}';
    q.sort_order := coalesce((SELECT max(sort_order) + 1 FROM public.exos_event_questions WHERE event_id = p_event), 0);
    IF NOT (p ? 'label') OR NOT (p ? 'kind') THEN
      RAISE EXCEPTION 'a question needs a label and a kind' USING ERRCODE = '22023';
    END IF;
  ELSE
    SELECT * INTO q FROM public.exos_event_questions WHERE id = p_id AND event_id = p_event AND org_id = p_org FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'question not found' USING ERRCODE = 'P0002'; END IF;
  END IF;
  v_has := NOT v_new AND EXISTS (SELECT 1 FROM public.exos_question_answers a WHERE a.question_id = q.id);

  IF p ? 'label' THEN q.label := btrim(coalesce(p->>'label', ''), E' \t\r\n'); END IF;
  IF p ? 'help_text' THEN q.help_text := nullif(btrim(coalesce(p->>'help_text', ''), E' \t\r\n'), ''); END IF;
  IF p ? 'kind' THEN
    IF v_has AND p->>'kind' IS DISTINCT FROM q.kind THEN
      RAISE EXCEPTION 'this question has answers: its type can''t change (archive it and add a new one)' USING ERRCODE = '22023';
    END IF;
    q.kind := p->>'kind';
  END IF;
  IF p ? 'scope' THEN
    IF v_has AND p->>'scope' IS DISTINCT FROM q.scope THEN
      RAISE EXCEPTION 'this question has answers: per order / per ticket can''t change (archive it and add a new one)' USING ERRCODE = '22023';
    END IF;
    q.scope := p->>'scope';
  END IF;
  IF p ? 'required' THEN q.required := coalesce((p->>'required')::boolean, false); END IF;
  IF p ? 'hidden' THEN q.hidden := coalesce((p->>'hidden')::boolean, false); END IF;
  IF p ? 'sort_order' THEN q.sort_order := coalesce((p->>'sort_order')::int, 0); END IF;
  IF p ? 'archived' THEN
    q.archived_at := CASE WHEN (p->>'archived')::boolean IS TRUE THEN coalesce(q.archived_at, now()) END;
  END IF;
  IF p ? 'options' THEN
    IF jsonb_typeof(p->'options') = 'null' THEN v_opts := '{}';
    ELSIF jsonb_typeof(p->'options') <> 'array' THEN
      RAISE EXCEPTION 'options must be a list of strings' USING ERRCODE = '22023';
    ELSE
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(p->'options') e WHERE jsonb_typeof(e) <> 'string') THEN
        RAISE EXCEPTION 'options must be a list of strings' USING ERRCODE = '22023';
      END IF;
      v_opts := ARRAY(SELECT btrim(x, E' \t\r\n') FROM jsonb_array_elements_text(p->'options') WITH ORDINALITY AS e(x, n) ORDER BY n);
    END IF;
    q.options := v_opts;
  ELSIF p ? 'kind' AND q.kind NOT IN ('single_choice', 'multiple_choice') THEN
    q.options := '{}';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(q.options) o WHERE o = '' OR char_length(o) > 200) THEN
    RAISE EXCEPTION 'each option needs 1 to 200 characters' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(DISTINCT o) FROM unnest(q.options) o) <> cardinality(q.options) THEN
    RAISE EXCEPTION 'two options are the same' USING ERRCODE = '22023';
  END IF;
  IF p ? 'tier_ids' THEN
    IF jsonb_typeof(p->'tier_ids') = 'null' THEN v_tiers := NULL;
    ELSIF jsonb_typeof(p->'tier_ids') <> 'array' THEN
      RAISE EXCEPTION 'tier_ids must be a list of ticket type ids' USING ERRCODE = '22023';
    ELSE
      BEGIN
        v_tiers := ARRAY(SELECT DISTINCT x::uuid FROM jsonb_array_elements_text(p->'tier_ids') x);
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'tier_ids must be a list of ticket type ids' USING ERRCODE = '22023';
      END;
      IF cardinality(v_tiers) = 0 THEN v_tiers := NULL; END IF;
      IF EXISTS (SELECT 1 FROM unnest(v_tiers) x
                  WHERE NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers t WHERE t.id = x AND t.event_id = p_event)) THEN
        RAISE EXCEPTION 'a ticket type in tier_ids is not one of this event''s' USING ERRCODE = '22023';
      END IF;
    END IF;
    q.tier_ids := v_tiers;
  END IF;
  BEGIN
    IF p ? 'max_length' THEN q.max_length := (p->>'max_length')::int; END IF;
    IF p ? 'min_choices' THEN q.min_choices := (p->>'min_choices')::int; END IF;
    IF p ? 'max_choices' THEN q.max_choices := (p->>'max_choices')::int; END IF;
    IF p ? 'min_value' THEN q.min_value := (p->>'min_value')::numeric; END IF;
    IF p ? 'max_value' THEN q.max_value := (p->>'max_value')::numeric; END IF;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'a limit is not a number' USING ERRCODE = '22023';
  END;
  -- Limits that don't belong to the (new) kind go.
  IF q.kind NOT IN ('text', 'long_text') THEN q.max_length := NULL; END IF;
  IF q.kind <> 'multiple_choice' THEN q.min_choices := NULL; q.max_choices := NULL; END IF;
  IF q.kind <> 'number' THEN q.min_value := NULL; q.max_value := NULL; END IF;

  BEGIN
    IF v_new THEN
      INSERT INTO public.exos_event_questions (id, org_id, event_id, tier_ids, label, help_text, kind, options, required,
                                               scope, sort_order, hidden, archived_at, max_length, min_choices, max_choices,
                                               min_value, max_value, created_by)
      VALUES (q.id, q.org_id, q.event_id, q.tier_ids, q.label, q.help_text, q.kind, q.options, q.required,
              q.scope, q.sort_order, q.hidden, q.archived_at, q.max_length, q.min_choices, q.max_choices,
              q.min_value, q.max_value, q.created_by);
    ELSE
      UPDATE public.exos_event_questions SET
        tier_ids = q.tier_ids, label = q.label, help_text = q.help_text, kind = q.kind, options = q.options,
        required = q.required, scope = q.scope, sort_order = q.sort_order, hidden = q.hidden, archived_at = q.archived_at,
        max_length = q.max_length, min_choices = q.min_choices, max_choices = q.max_choices,
        min_value = q.min_value, max_value = q.max_value
       WHERE id = q.id;
    END IF;
  EXCEPTION WHEN check_violation THEN
    RAISE EXCEPTION '%', CASE
      WHEN SQLERRM LIKE '%kind_chk%' THEN 'unknown question type'
      WHEN SQLERRM LIKE '%scope_chk%' THEN 'scope must be order or ticket'
      WHEN SQLERRM LIKE '%label_chk%' THEN 'give the question a label of 1 to 200 characters'
      WHEN SQLERRM LIKE '%help_chk%' THEN 'keep the help text to 500 characters'
      WHEN SQLERRM LIKE '%options_chk%' THEN 'choice questions need 2 to 50 options; other types have none'
      WHEN SQLERRM LIKE '%length_chk%' THEN 'max_length is 1 to 2000 (text) or 5000 (long text)'
      WHEN SQLERRM LIKE '%choices_chk%' THEN 'the number of choices must fit the options'
      WHEN SQLERRM LIKE '%range_chk%' THEN 'min_value must not be above max_value'
      ELSE 'the question is not valid' END USING ERRCODE = '22023';
  END;
  SELECT * INTO q FROM public.exos_event_questions WHERE id = q.id;
  RETURN public._exos_question_def(q) || jsonb_build_object(
    'answer_count', (SELECT count(*) FROM public.exos_question_answers a WHERE a.question_id = q.id));
END $$;

-- "Delete": archive (answers kept). p_archived false restores it.
CREATE OR REPLACE FUNCTION public._exos_question_archive(p_org uuid, p_id uuid, p_archived boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_event uuid;
BEGIN
  SELECT event_id INTO v_event FROM public.exos_event_questions WHERE id = p_id AND org_id = p_org;
  IF v_event IS NULL THEN RAISE EXCEPTION 'question not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT coalesce(p_archived, true)
     AND (SELECT count(*) FROM public.exos_event_questions WHERE event_id = v_event AND archived_at IS NULL) >= 50 THEN
    RAISE EXCEPTION 'an event asks at most 50 questions; archive one first' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_question_upsert(p_org, v_event, p_id, jsonb_build_object('archived', coalesce(p_archived, true)), NULL);
END $$;

-- Put the event's questions in this order (ids not listed keep their place after).
CREATE OR REPLACE FUNCTION public._exos_questions_reorder(p_org uuid, p_event uuid, p_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 OR cardinality(p_ids) > 200
     OR (SELECT count(DISTINCT x) FROM unnest(p_ids) x) <> cardinality(p_ids) THEN
    RAISE EXCEPTION 'send each question id once' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_ids) x WHERE NOT EXISTS (
               SELECT 1 FROM public.exos_event_questions q WHERE q.id = x AND q.event_id = p_event)) THEN
    RAISE EXCEPTION 'a question id is not one of this event''s' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_event_questions q SET sort_order = o.n - 1
    FROM unnest(p_ids) WITH ORDINALITY AS o(id, n) WHERE q.id = o.id AND q.sort_order IS DISTINCT FROM o.n - 1;
  UPDATE public.exos_event_questions q SET sort_order = cardinality(p_ids) + r.n - 1
    FROM (SELECT id, row_number() OVER (ORDER BY sort_order, created_at, id) AS n
            FROM public.exos_event_questions WHERE event_id = p_event AND NOT (id = ANY (p_ids))) r
   WHERE q.id = r.id;
  RETURN public._exos_api_questions(p_org, p_event);
END $$;

-- The answers of a set of tickets: { <ticket id>: [ { question_id, label,
-- kind, value, display } ] }: the ticket's own answers, and its order's only
-- when p_include_order (order answers are order data: exos-api passes true
-- for orders:read, or a credential of an owner / manager / finance; a
-- tickets:read-only door integration gets per-ticket answers only).
CREATE OR REPLACE FUNCTION public._exos_answers_for(p_ticket_ids uuid[], p_include_order boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_object_agg(x.tid, x.answers), '{}'::jsonb) FROM (
    SELECT t.id::text AS tid, coalesce((
      SELECT jsonb_agg(jsonb_build_object('question_id', a.question_id, 'scope', a.scope, 'label', a.label,
                                          'kind', a.kind, 'value', a.value, 'display', a.display)
                       ORDER BY a.scope, q.sort_order, a.created_at)
        FROM public.exos_question_answers a
        JOIN public.exos_event_questions q ON q.id = a.question_id
       WHERE a.ticket_id = t.id
          OR (p_include_order IS TRUE AND a.scope = 'order' AND a.order_ref = t.order_ref AND a.event_id = t.event_id)), '[]'::jsonb) AS answers
      FROM public.exos_tickets t WHERE t.id = ANY (p_ticket_ids)) x
$$;

-- One row per answer of a minted order: the answers table, its CSV and the API.
CREATE OR REPLACE FUNCTION public._exos_event_answer_rows(p_event uuid)
RETURNS TABLE (
  answer_id uuid, question_id uuid, order_ref text, ticket_id uuid, ticket_index integer, scope text,
  label text, current_label text, kind text, value jsonb, display text, source text,
  attendee_name text, tier_name text, ticket_status text, buyer_email text, question_archived boolean,
  created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT a.id, a.question_id, a.order_ref, a.ticket_id, a.ticket_index, a.scope,
         a.label, q.label, a.kind, a.value, a.display, a.source,
         t.attendee_name, t.tier_name, t.status,
         coalesce((SELECT s.buyer_email FROM public.exos_checkout_sessions s WHERE s.session_id = a.order_ref), t.buyer_email),
         q.archived_at IS NOT NULL, a.created_at
    FROM public.exos_question_answers a
    JOIN public.exos_event_questions q ON q.id = a.question_id
    LEFT JOIN public.exos_tickets t ON t.id = a.ticket_id
   WHERE a.event_id = p_event AND a.attached_at IS NOT NULL
   ORDER BY a.created_at, a.order_ref, coalesce(a.ticket_index, 0), q.sort_order, a.id
$$;

-- Authenticated wrappers (the event editor and the report).
CREATE OR REPLACE FUNCTION public.exos_list_event_questions(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT (public.exos_is_admin()
       OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance', 'scanner', 'content'])) THEN
    RAISE EXCEPTION 'exos_list_event_questions: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_api_questions(v_org, p_event_id);
END $$;

CREATE OR REPLACE FUNCTION public.exos_save_event_question(p_event_id uuid, p_question jsonb, p_question_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT public._exos_can_edit_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_save_event_question: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_question_upsert(v_org, p_event_id, p_question_id, p_question, auth.uid());
END $$;

CREATE OR REPLACE FUNCTION public.exos_archive_event_question(p_question_id uuid, p_archived boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid; v_event uuid;
BEGIN
  SELECT org_id, event_id INTO v_org, v_event FROM public.exos_event_questions WHERE id = p_question_id;
  IF v_event IS NULL OR auth.uid() IS NULL OR NOT public._exos_can_edit_event(v_event) THEN
    RAISE EXCEPTION 'exos_archive_event_question: not authorized for this question' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_question_archive(v_org, p_question_id, p_archived);
END $$;

CREATE OR REPLACE FUNCTION public.exos_reorder_event_questions(p_event_id uuid, p_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT public._exos_can_edit_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_reorder_event_questions: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_questions_reorder(v_org, p_event_id, p_ids);
END $$;

-- The answers table (owner / manager / finance, like the other reports).
CREATE OR REPLACE FUNCTION public.exos_event_question_answers(p_event_id uuid)
RETURNS SETOF jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL OR NOT (public.exos_is_admin()
       OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_event_question_answers: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT to_jsonb(r) FROM public._exos_event_answer_rows(p_event_id) r;
END $$;

-- ===========================================================================
-- 9. Buyers: the questions of a published event (anon)
-- ===========================================================================
-- Labels, kinds, options and rules of the questions asked at checkout (never
-- hidden or archived ones, never answers), and the party size of each table
-- ticket type (a table of 8 is asked per-ticket questions 8 times). Staff of
-- the event's org may also read a draft's (the builder's preview).
CREATE OR REPLACE FUNCTION public.exos_public_event_questions(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_ev public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND OR (v_ev.status IS DISTINCT FROM 'published'
                   AND NOT (auth.uid() IS NOT NULL AND public._exos_can_edit_event(p_event_id))) THEN
    RETURN jsonb_build_object('questions', '[]'::jsonb, 'party_sizes', '{}'::jsonb);
  END IF;
  RETURN jsonb_build_object(
    'questions', (SELECT coalesce(jsonb_agg(x - 'event_id' - 'hidden' - 'archived' - 'archived_at' - 'created_at' - 'updated_at'
                                            ORDER BY (x->>'sort_order')::int), '[]'::jsonb)
                    FROM jsonb_array_elements(public._exos_question_defs(p_event_id, false)) x),
    'party_sizes', (SELECT coalesce(jsonb_object_agg(t.id, public.exos_tier_party_size(t.id)), '{}'::jsonb)
                      FROM public.exos_ticket_tiers t
                     WHERE t.event_id = p_event_id AND public.exos_tier_party_size(t.id) > 1));
END $$;

-- ===========================================================================
-- Grants
-- ===========================================================================
REVOKE ALL ON FUNCTION public._exos_answer_is_empty(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_answer_display(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_normalize_answer(jsonb, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_question_applies(jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_validate_answers_core(jsonb, uuid[], jsonb, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_question_def(public.exos_event_questions) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_question_defs(uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_validate_answers(uuid, uuid[], jsonb, boolean, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_raise_answer_problem(jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_required_questions_for(uuid, uuid[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_record_answers(uuid, uuid, text, uuid[], jsonb, boolean, boolean, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_record_checkout_answers(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_checkout_question_ctx(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_claim_free_tickets_answered(uuid, uuid, integer, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_rsvp_questions(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_rsvp_record_answers(uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_api_reservation_answers(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_set_ticket_answers(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_door_set_ticket_answers(uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_tg_ticket_answers_attach() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_tg_ticket_answers_buyer() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_api_questions(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_question_upsert(uuid, uuid, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_question_archive(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_questions_reorder(uuid, uuid, uuid[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_answers_for(uuid[], boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_event_answer_rows(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_list_event_questions(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_save_event_question(uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_archive_event_question(uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_reorder_event_questions(uuid, uuid[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_event_question_answers(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_public_event_questions(uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._exos_answer_is_empty(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_answer_display(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_normalize_answer(jsonb, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_question_applies(jsonb, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_validate_answers_core(jsonb, uuid[], jsonb, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_question_def(public.exos_event_questions) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_question_defs(uuid, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_validate_answers(uuid, uuid[], jsonb, boolean, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_required_questions_for(uuid, uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_record_checkout_answers(text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_checkout_question_ctx(uuid, uuid, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_rsvp_questions(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_rsvp_record_answers(uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_api_reservation_answers(uuid, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_set_ticket_answers(uuid, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_api_questions(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_question_upsert(uuid, uuid, uuid, jsonb, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_question_archive(uuid, uuid, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_questions_reorder(uuid, uuid, uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_answers_for(uuid[], boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_event_answer_rows(uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.exos_claim_free_tickets_answered(uuid, uuid, integer, text, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_door_set_ticket_answers(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_list_event_questions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_save_event_question(uuid, jsonb, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_archive_event_question(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_reorder_event_questions(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_question_answers(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_event_questions(uuid) TO anon, authenticated;
