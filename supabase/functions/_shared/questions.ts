// Checkout questions (mig 20261106110000, docs/checkout-questions.md).
//
// An organizer asks buyers questions at checkout ("T-shirt size?", "Dietary
// needs?", "I agree to the venue's photo policy"), per order or per ticket,
// optionally only for some ticket types. This is the pure TypeScript half of
// the answer rules; the SQL half is public._exos_validate_answers_core, and
// both must agree. src/lib/checkoutQuestions.test.ts runs the cases embedded in
// tests/exos/test_checkout_questions.sql (between the CQ-CASES markers)
// through validateAnswers, and that harness runs the same cases through the
// SQL function, so a rule changed on one side only fails a test.
//
// The SPA uses it to show errors inline before anything is sent, and
// exos-checkout uses it to refuse a bad body before a hold or a Stripe
// session exists. The database checks again when it records the answers
// (exos_record_checkout_answers and friends), so the client is never trusted.
//
// Shapes (the same snake_case keys as the SQL and the public RPC):
//   QuestionDef  one active question (archived and hidden ones are never
//                passed in: an answer to one is an unknown question).
//   answers      { order: { <question id>: value },
//                  tickets: [ { <question id>: value }, ... ] }
//                tickets[i] is the i-th ticket of the order, in mint order;
//                a missing entry (or null) means "nothing answered for it".
//   ticketTiers  the ticket type of each ticket of the order (quantity x
//                party size entries; a table of 8 is 8 tickets).
//
// Pure, no imports: vitest, the SPA and Deno all load it.

export const QUESTION_KINDS = [
  'text', 'long_text', 'single_choice', 'multiple_choice', 'checkbox', 'number', 'date', 'phone', 'email',
] as const;
export type QuestionKind = (typeof QUESTION_KINDS)[number];

export const QUESTION_SCOPES = ['order', 'ticket'] as const;
export type QuestionScope = (typeof QUESTION_SCOPES)[number];

/** Kinds whose answers come from the question's options. */
export const CHOICE_KINDS: readonly QuestionKind[] = ['single_choice', 'multiple_choice'];

/** Limits shared with the SQL (CHECK constraints and _exos_validate_answers_core). */
export const QUESTION_LIMITS = {
  maxQuestionsPerEvent: 50,
  labelMax: 200,
  helpMax: 500,
  optionsMin: 2,
  optionsMax: 50,
  optionMax: 200,
  textDefaultMax: 500,
  textCap: 2000,
  longTextDefaultMax: 2000,
  longTextCap: 5000,
  emailMax: 254,
  maxTickets: 100,
  /** |number| must stay below this, with at most 6 decimals. */
  numberAbsBelow: 1e12,
} as const;

/** Problem codes, the same strings the SQL returns. */
export const ANSWER_PROBLEMS = [
  'bad_shape', 'too_many_tickets', 'unknown_question', 'wrong_scope', 'not_for_ticket_type', 'required',
  'invalid_value', 'invalid_choice', 'too_long', 'too_many_choices', 'too_few_choices', 'not_a_number',
  'out_of_range', 'invalid_date', 'invalid_phone', 'invalid_email',
] as const;
export type AnswerProblemCode = (typeof ANSWER_PROBLEMS)[number];

export interface QuestionDef {
  id: string;
  label: string;
  help_text?: string | null;
  kind: QuestionKind;
  options?: string[] | null;
  required: boolean;
  scope: QuestionScope;
  /** null (or empty): every ticket type. */
  tier_ids?: string[] | null;
  max_length?: number | null;
  min_choices?: number | null;
  max_choices?: number | null;
  min_value?: number | null;
  max_value?: number | null;
  sort_order?: number;
}

export type AnswerValue = string | number | boolean | string[];

export interface NormalizedAnswers {
  order: Record<string, AnswerValue>;
  tickets: Record<string, AnswerValue>[];
}

export interface AnswerProblem {
  code: AnswerProblemCode;
  /** The question, when the problem is about one. */
  question_id: string | null;
  /** 1-based ticket number for a per-ticket answer, else null. */
  ticket: number | null;
}

export type ValidateResult =
  | { ok: true; answers: NormalizedAnswers; problems: [] }
  | { ok: false; answers: null; problems: AnswerProblem[] };

const WS = /^[ \t\r\n]+|[ \t\r\n]+$/g;
/** Trim spaces, tabs and line breaks only (SQL: btrim(s, E' \t\r\n')). */
export function trimWs(s: string): string {
  return s.replace(WS, '');
}

/** Length in characters (code points), as SQL char_length counts. */
export function charLength(s: string): number {
  return Array.from(s).length;
}

const NUM_RE = /^-?[0-9]{1,12}(\.[0-9]{1,6})?$/;
const DATE_RE = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/;
const PHONE_STRIP = /[ ().\-]/g;
const PHONE_RE = /^\+?[0-9]{7,15}$/;
const EMAIL_RE = /^[^ \t\r\n@]+@[^ \t\r\n@]+\.[^ \t\r\n@]+$/;

/** The text length an answer to this question may have. */
export function maxLengthFor(q: Pick<QuestionDef, 'kind' | 'max_length'>): number {
  const long = q.kind === 'long_text';
  const cap = long ? QUESTION_LIMITS.longTextCap : QUESTION_LIMITS.textCap;
  const def = long ? QUESTION_LIMITS.longTextDefaultMax : QUESTION_LIMITS.textDefaultMax;
  const m = q.max_length == null ? def : Math.floor(Number(q.max_length));
  return Math.max(1, Math.min(cap, Number.isFinite(m) ? m : def));
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function validDate(s: string): boolean {
  const m = DATE_RE.exec(s);
  if (!m) return false;
  const y = Number(m[1]); const mo = Number(m[2]); const d = Number(m[3]);
  if (y < 1900 || y > 2100 || mo < 1 || mo > 12 || d < 1) return false;
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1];
  return d <= dim;
}

/** Is this raw value "nothing answered"? (null, blank text, [], false) */
export function isEmptyAnswer(v: unknown): boolean {
  if (v === null || v === undefined || v === false) return true;
  if (typeof v === 'string') return trimWs(v) === '';
  if (Array.isArray(v)) return v.length === 0;
  return false;
}

/**
 * One answer, normalised: `{ value }`, or `{ problem }`. Only called for a
 * value that isn't empty (isEmptyAnswer).
 */
export function normalizeAnswer(q: QuestionDef, v: unknown): { value: AnswerValue } | { problem: AnswerProblemCode } {
  const options = (q.options ?? []).map(String);
  switch (q.kind) {
    case 'text':
    case 'long_text': {
      if (typeof v !== 'string') return { problem: 'invalid_value' };
      const s = trimWs(v);
      return charLength(s) > maxLengthFor(q) ? { problem: 'too_long' } : { value: s };
    }
    case 'single_choice': {
      if (typeof v !== 'string') return { problem: 'invalid_value' };
      const s = trimWs(v);
      return options.includes(s) ? { value: s } : { problem: 'invalid_choice' };
    }
    case 'multiple_choice': {
      if (!Array.isArray(v)) return { problem: 'invalid_value' };
      if (v.some((x) => typeof x !== 'string')) return { problem: 'invalid_value' };
      const picked = new Set((v as string[]).map(trimWs));
      if ([...picked].some((x) => !options.includes(x))) return { problem: 'invalid_choice' };
      // Normalised to the options' order, each once.
      const value = options.filter((o, i) => picked.has(o) && options.indexOf(o) === i);
      if (q.max_choices != null && value.length > q.max_choices) return { problem: 'too_many_choices' };
      if (q.min_choices != null && value.length < q.min_choices) return { problem: 'too_few_choices' };
      return { value };
    }
    case 'checkbox':
      // false is "not ticked" (empty); anything but true is wrong.
      return v === true ? { value: true } : { problem: 'invalid_value' };
    case 'number': {
      let s: string;
      if (typeof v === 'number') {
        if (!Number.isFinite(v) || Math.abs(v) >= QUESTION_LIMITS.numberAbsBelow) return { problem: 'not_a_number' };
        s = String(v);
      } else if (typeof v === 'string') {
        s = trimWs(v);
      } else {
        return { problem: 'not_a_number' };
      }
      if (!NUM_RE.test(s)) return { problem: 'not_a_number' };
      const n = Number(s);
      if ((q.min_value != null && n < Number(q.min_value)) || (q.max_value != null && n > Number(q.max_value))) {
        return { problem: 'out_of_range' };
      }
      return { value: n === 0 ? 0 : n };
    }
    case 'date': {
      if (typeof v !== 'string') return { problem: 'invalid_date' };
      const s = trimWs(v);
      return validDate(s) ? { value: s } : { problem: 'invalid_date' };
    }
    case 'phone': {
      if (typeof v !== 'string') return { problem: 'invalid_phone' };
      const s = trimWs(v).replace(PHONE_STRIP, '');
      return PHONE_RE.test(s) ? { value: s } : { problem: 'invalid_phone' };
    }
    case 'email': {
      if (typeof v !== 'string') return { problem: 'invalid_email' };
      const s = trimWs(v).toLowerCase();
      return charLength(s) <= QUESTION_LIMITS.emailMax && EMAIL_RE.test(s) ? { value: s } : { problem: 'invalid_email' };
    }
  }
  return { problem: 'invalid_value' };
}

/** Does question q apply to a ticket of this type? */
export function appliesToTier(q: Pick<QuestionDef, 'tier_ids'>, tierId: string): boolean {
  const t = q.tier_ids ?? [];
  return t.length === 0 || t.includes(tierId);
}

/** Does an order-wide question apply to an order of these tickets? */
export function appliesToOrder(q: Pick<QuestionDef, 'tier_ids'>, ticketTiers: readonly string[]): boolean {
  return ticketTiers.some((t) => appliesToTier(q, t));
}

/**
 * Check and normalise a buyer's answers. `require: false` (the door, the
 * organizer's API) skips the required check only; every other rule holds.
 */
export function validateAnswers(
  questions: readonly QuestionDef[],
  input: unknown,
  ctx: { ticketTiers: readonly string[]; require: boolean },
): ValidateResult {
  const problems: AnswerProblem[] = [];
  const bad = (code: AnswerProblemCode, question_id: string | null = null, ticket: number | null = null) =>
    problems.push({ code, question_id, ticket });
  const fail = (): ValidateResult => ({ ok: false, answers: null, problems });

  const body = input === null || input === undefined ? {} : input;
  if (!isObject(body)) { bad('bad_shape'); return fail(); }
  const orderIn = body.order === undefined || body.order === null ? {} : body.order;
  const ticketsIn = body.tickets === undefined || body.tickets === null ? [] : body.tickets;
  if (!isObject(orderIn) || !Array.isArray(ticketsIn)
    || ticketsIn.some((t) => t !== null && !isObject(t))) {
    bad('bad_shape');
    return fail();
  }
  const n = ctx.ticketTiers.length;
  if (n > QUESTION_LIMITS.maxTickets || ticketsIn.length > n) { bad('too_many_tickets'); return fail(); }

  const byId = new Map(questions.map((q) => [q.id, q]));
  const out: NormalizedAnswers = { order: {}, tickets: Array.from({ length: n }, () => ({})) };

  // Keys that aren't a question asked here.
  for (const k of Object.keys(orderIn)) {
    const q = byId.get(k);
    if (!q) bad('unknown_question', k);
    else if (q.scope !== 'order') bad('wrong_scope', k);
    else if (!appliesToOrder(q, ctx.ticketTiers)) bad('not_for_ticket_type', k);
  }
  ticketsIn.forEach((t, i) => {
    for (const k of Object.keys((t ?? {}) as Record<string, unknown>)) {
      const q = byId.get(k);
      if (!q) bad('unknown_question', k, i + 1);
      else if (q.scope !== 'ticket') bad('wrong_scope', k, i + 1);
      else if (!appliesToTier(q, ctx.ticketTiers[i])) bad('not_for_ticket_type', k, i + 1);
    }
  });

  const one = (q: QuestionDef, raw: unknown, ticket: number | null, put: (v: AnswerValue) => void) => {
    if (isEmptyAnswer(raw)) {
      if (ctx.require && q.required) bad('required', q.id, ticket);
      return;
    }
    const r = normalizeAnswer(q, raw);
    if ('problem' in r) bad(r.problem, q.id, ticket);
    else put(r.value);
  };

  for (const q of questions) {
    if (q.scope !== 'order' || !appliesToOrder(q, ctx.ticketTiers)) continue;
    one(q, (orderIn as Record<string, unknown>)[q.id], null, (v) => { out.order[q.id] = v; });
  }
  for (let i = 0; i < n; i++) {
    const t = ((ticketsIn[i] ?? {}) as Record<string, unknown>);
    for (const q of questions) {
      if (q.scope !== 'ticket' || !appliesToTier(q, ctx.ticketTiers[i])) continue;
      one(q, t[q.id], i + 1, (v) => { out.tickets[i][q.id] = v; });
    }
  }
  return problems.length > 0 ? fail() : { ok: true, answers: out, problems: [] };
}

/** The questions a buyer of these tickets is asked, split by scope, in order. */
export function questionsFor(
  questions: readonly QuestionDef[],
  ticketTiers: readonly string[],
): { order: QuestionDef[]; ticket: QuestionDef[][] } {
  const sorted = [...questions].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0));
  return {
    order: sorted.filter((q) => q.scope === 'order' && appliesToOrder(q, ticketTiers)),
    ticket: ticketTiers.map((tier) => sorted.filter((q) => q.scope === 'ticket' && appliesToTier(q, tier))),
  };
}

/** How an answer reads in a table, an export or DICE's string `value`. */
export function answerDisplay(v: unknown): string {
  if (v === true) return 'Yes';
  if (v === false || v === null || v === undefined) return '';
  if (Array.isArray(v)) return v.map(String).join(', ');
  return String(v);
}

const PROBLEM_TEXT: Record<AnswerProblemCode, string> = {
  bad_shape: 'The answers were not in the expected form.',
  too_many_tickets: 'There are answers for more tickets than the order has.',
  unknown_question: 'This question is no longer asked.',
  wrong_scope: 'This question is answered once per order, not per ticket (or the other way round).',
  not_for_ticket_type: 'This question is not asked for this ticket type.',
  required: 'This answer is required.',
  invalid_value: 'This answer is not valid.',
  invalid_choice: 'Pick one of the options.',
  too_long: 'This answer is too long.',
  too_many_choices: 'Too many options picked.',
  too_few_choices: 'Pick more options.',
  not_a_number: 'Enter a number.',
  out_of_range: 'This number is out of range.',
  invalid_date: 'Enter a date (YYYY-MM-DD).',
  invalid_phone: 'Enter a phone number (7 to 15 digits).',
  invalid_email: 'Enter an email address.',
};

/** A short, buyer-facing sentence for a problem (the field shows it inline). */
export function problemText(p: Pick<AnswerProblem, 'code'>, q?: Pick<QuestionDef, 'kind' | 'max_length' | 'min_value' | 'max_value' | 'min_choices' | 'max_choices'>): string {
  if (q && p.code === 'too_long') return `Keep it to ${maxLengthFor(q)} characters.`;
  if (q && p.code === 'out_of_range') {
    if (q.min_value != null && q.max_value != null) return `Enter a number from ${q.min_value} to ${q.max_value}.`;
    if (q.min_value != null) return `Enter ${q.min_value} or more.`;
    if (q.max_value != null) return `Enter ${q.max_value} or less.`;
  }
  if (q && p.code === 'too_many_choices' && q.max_choices != null) return `Pick up to ${q.max_choices}.`;
  if (q && p.code === 'too_few_choices' && q.min_choices != null) return `Pick at least ${q.min_choices}.`;
  return PROBLEM_TEXT[p.code] ?? 'This answer is not valid.';
}

/**
 * A question definition an organizer may save, or the first problem with it
 * (the SQL refuses the same, _exos_question_upsert). Used by the builder.
 */
export function questionDefProblem(d: Partial<QuestionDef>): string | null {
  const label = trimWs(String(d.label ?? ''));
  if (label === '' || charLength(label) > QUESTION_LIMITS.labelMax) return `Give the question a label of 1 to ${QUESTION_LIMITS.labelMax} characters.`;
  if (d.help_text != null && charLength(trimWs(String(d.help_text))) > QUESTION_LIMITS.helpMax) return `Keep the help text to ${QUESTION_LIMITS.helpMax} characters.`;
  if (!d.kind || !(QUESTION_KINDS as readonly string[]).includes(d.kind)) return 'Pick a question type.';
  if (!d.scope || !(QUESTION_SCOPES as readonly string[]).includes(d.scope)) return 'Ask it per order or per ticket.';
  const opts = (d.options ?? []).map((o) => trimWs(String(o)));
  if (CHOICE_KINDS.includes(d.kind)) {
    if (opts.length < QUESTION_LIMITS.optionsMin || opts.length > QUESTION_LIMITS.optionsMax) return `Give ${QUESTION_LIMITS.optionsMin} to ${QUESTION_LIMITS.optionsMax} options.`;
    if (opts.some((o) => o === '' || charLength(o) > QUESTION_LIMITS.optionMax)) return `Each option needs 1 to ${QUESTION_LIMITS.optionMax} characters.`;
    if (new Set(opts).size !== opts.length) return 'Two options are the same.';
  } else if (opts.length > 0) {
    return 'Only choice questions have options.';
  }
  if (d.max_length != null) {
    if (d.kind !== 'text' && d.kind !== 'long_text') return 'Only text questions have a maximum length.';
    const cap = d.kind === 'long_text' ? QUESTION_LIMITS.longTextCap : QUESTION_LIMITS.textCap;
    if (!Number.isInteger(d.max_length) || d.max_length < 1 || d.max_length > cap) return `The maximum length is 1 to ${cap}.`;
  }
  if (d.min_choices != null || d.max_choices != null) {
    if (d.kind !== 'multiple_choice') return 'Only multiple-choice questions have a number of choices.';
    const min = d.min_choices ?? 0; const max = d.max_choices ?? opts.length;
    if (!Number.isInteger(min) || !Number.isInteger(max) || min < 0 || max < 1 || min > max || max > opts.length) {
      return 'The number of choices must fit the options.';
    }
  }
  if (d.min_value != null || d.max_value != null) {
    if (d.kind !== 'number') return 'Only number questions have a range.';
    const okNum = (x: unknown) => x == null || (typeof x === 'number' && Number.isFinite(x) && Math.abs(x) < QUESTION_LIMITS.numberAbsBelow);
    if (!okNum(d.min_value) || !okNum(d.max_value)) return 'The range must be numbers.';
    if (d.min_value != null && d.max_value != null && d.min_value > d.max_value) return 'The smallest number is above the largest.';
  }
  return null;
}
