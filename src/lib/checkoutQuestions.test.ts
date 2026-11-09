import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import {
  ANSWER_PROBLEMS, QUESTION_KINDS, QUESTION_LIMITS, answerDisplay, isEmptyAnswer, maxLengthFor, problemText,
  questionDefProblem, questionsFor, validateAnswers, type QuestionDef,
} from '../../supabase/functions/_shared/questions.ts';
import {
  answerColumns, answersBody, answersCsv, draftProblems, hasQuestions, parsePublicQuestions, ticketTiersFor, type AnswerRow,
} from './checkoutQuestions';

const root = resolve(__dirname, '../..');
const harness = readFileSync(resolve(root, 'tests/exos/test_checkout_questions.sql'), 'utf8');
const migration = readFileSync(resolve(root, 'supabase/migrations/20261106110000_exos_checkout_questions.sql'), 'utf8');

// The cases tests/exos/test_checkout_questions.sql (CQ12) runs through
// _exos_validate_answers_core: the same JSON, the same expectations.
const doc = JSON.parse(/-- CQ-CASES-BEGIN([\s\S]*?)-- CQ-CASES-END/.exec(harness)![1]) as {
  tiers: Record<string, string>;
  questions: Record<string, QuestionDef>;
  cases: { name: string; q: string[]; tiers: string[]; require: boolean; answers: unknown; expect: string[]; normalized?: unknown }[];
};
const idToName = Object.fromEntries(Object.entries(doc.questions).map(([k, q]) => [q.id, k]));
const toIds = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [doc.questions[k]?.id ?? k, v]));
const toNames = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [idToName[k] ?? k, v]));

describe('TS/SQL parity (tests/exos/test_checkout_questions.sql CQ12)', () => {
  it('has the shared cases', () => {
    expect(doc.cases.length).toBeGreaterThan(40);
  });
  for (const c of doc.cases) {
    it(c.name, () => {
      const qs = c.q.map((n) => doc.questions[n]);
      const tiers = c.tiers.map((t) => doc.tiers[t]);
      let answers: unknown = c.answers;
      if (answers && typeof answers === 'object' && !Array.isArray(answers)) {
        const a = answers as { order?: unknown; tickets?: unknown };
        answers = {
          ...(a.order !== undefined ? { order: a.order && typeof a.order === 'object' && !Array.isArray(a.order) ? toIds(a.order as Record<string, unknown>) : a.order } : {}),
          ...(a.tickets !== undefined ? {
            tickets: Array.isArray(a.tickets)
              ? a.tickets.map((t) => (t && typeof t === 'object' && !Array.isArray(t) ? toIds(t as Record<string, unknown>) : t))
              : a.tickets,
          } : {}),
        };
      }
      const r = validateAnswers(qs, answers, { ticketTiers: tiers, require: c.require });
      const got = r.problems.map((p) => `${p.code}|${p.question_id ? idToName[p.question_id] ?? p.question_id : ''}|${p.ticket ?? ''}`).sort();
      expect(got).toEqual([...c.expect].sort());
      if (c.normalized !== undefined) {
        expect(r.ok).toBe(true);
        expect({ order: toNames(r.answers!.order), tickets: r.answers!.tickets.map(toNames) }).toEqual(c.normalized);
      }
    });
  }
});

describe('the migration agrees with the TS constants', () => {
  it('kinds', () => {
    const m = /exos_event_questions_kind_chk CHECK \(kind IN\s*\(([^)]*)\)\)/.exec(migration)!;
    expect(m[1].replace(/\s+/g, ' ').match(/'([a-z_]+)'/g)!.map((s) => s.slice(1, -1))).toEqual([...QUESTION_KINDS]);
  });
  it('limits', () => {
    expect(migration).toContain(`kind = 'text' AND max_length BETWEEN 1 AND ${QUESTION_LIMITS.textCap}`);
    expect(migration).toContain(`kind = 'long_text' AND max_length BETWEEN 1 AND ${QUESTION_LIMITS.longTextCap}`);
    expect(migration).toContain(`cardinality(options) BETWEEN ${QUESTION_LIMITS.optionsMin} AND ${QUESTION_LIMITS.optionsMax}`);
    expect(migration).toContain(`char_length(btrim(label)) BETWEEN 1 AND ${QUESTION_LIMITS.labelMax}`);
    expect(migration).toContain(`char_length(help_text) <= ${QUESTION_LIMITS.helpMax}`);
    expect(migration).toContain(`def := CASE WHEN k = 'long_text' THEN ${QUESTION_LIMITS.longTextDefaultMax} ELSE ${QUESTION_LIMITS.textDefaultMax} END`);
    expect(migration).toContain(`ticket_index BETWEEN 1 AND ${QUESTION_LIMITS.maxTickets}`);
    expect(migration).toContain(`>= ${QUESTION_LIMITS.maxQuestionsPerEvent} THEN`);
    expect(migration).toContain(`char_length(s) <= ${QUESTION_LIMITS.emailMax}`);
  });
  it('every problem code the SQL can return is a TS code', () => {
    const sqlCodes = new Set([...migration.matchAll(/"problem":"([a-z_]+)"|'code', '([a-z_]+)'/g)].map((m) => m[1] ?? m[2]));
    expect(sqlCodes.size).toBeGreaterThan(10);
    for (const c of sqlCodes) expect(ANSWER_PROBLEMS as readonly string[]).toContain(c);
    // And the buyer-facing SQL message knows every code.
    const raise = /_exos_raise_answer_problem\(p_result jsonb, p_event_id uuid\)[\s\S]*?END \$\$;/.exec(migration)![0];
    for (const c of ANSWER_PROBLEMS) if (c !== 'invalid_value') expect(raise).toContain(`WHEN '${c}' THEN`);
  });
});

const Q = (over: Partial<QuestionDef>): QuestionDef => ({
  id: 'q1', label: 'Q', kind: 'text', options: [], required: false, scope: 'order', tier_ids: null, ...over,
});

describe('validateAnswers details', () => {
  it('a long_text defaults to 2000 characters and caps at 5000', () => {
    const q = Q({ kind: 'long_text' });
    expect(maxLengthFor(q)).toBe(2000);
    expect(maxLengthFor(Q({ kind: 'long_text', max_length: 99999 }))).toBe(5000);
    expect(validateAnswers([q], { order: { q1: 'x'.repeat(2000) } }, { ticketTiers: ['t'], require: true }).ok).toBe(true);
    expect(validateAnswers([q], { order: { q1: 'x'.repeat(2001) } }, { ticketTiers: ['t'], require: true }).problems[0].code).toBe('too_long');
  });
  it('counts characters, not UTF-16 units', () => {
    const q = Q({ max_length: 2 });
    expect(validateAnswers([q], { order: { q1: '😀😀' } }, { ticketTiers: ['t'], require: true }).ok).toBe(true);
  });
  it('more than 100 tickets is refused', () => {
    const r = validateAnswers([], {}, { ticketTiers: Array.from({ length: 101 }, () => 't'), require: true });
    expect(r.problems[0].code).toBe('too_many_tickets');
  });
  it('empty answers', () => {
    expect([null, undefined, false, '', '  \n', []].every(isEmptyAnswer)).toBe(true);
    expect([0, true, 'x', ['a']].some(isEmptyAnswer)).toBe(false);
  });
});

describe('questionsFor / hasQuestions / ticketTiersFor', () => {
  const qs = [
    Q({ id: 'a', scope: 'order', sort_order: 2 }),
    Q({ id: 'b', scope: 'ticket', sort_order: 1 }),
    Q({ id: 'c', scope: 'ticket', tier_ids: ['vip'], sort_order: 0 }),
  ];
  it('splits by scope and ticket type, in sort order', () => {
    const f = questionsFor(qs, ['ga', 'vip']);
    expect(f.order.map((q) => q.id)).toEqual(['a']);
    expect(f.ticket.map((l) => l.map((q) => q.id))).toEqual([['b'], ['c', 'b']]);
  });
  it('a table is asked per seat', () => {
    expect(ticketTiersFor('tbl', 2, { tbl: 4 })).toHaveLength(8);
    expect(ticketTiersFor('ga', 3)).toEqual(['ga', 'ga', 'ga']);
    expect(ticketTiersFor('tbl', 50, { tbl: 10 })).toHaveLength(100);
  });
  it('hasQuestions', () => {
    expect(hasQuestions([], ['ga'])).toBe(false);
    expect(hasQuestions([Q({ id: 'x', tier_ids: ['vip'] })], ['ga'])).toBe(false);
    expect(hasQuestions(qs, ['ga'])).toBe(true);
  });
});

describe('answersBody / draftProblems', () => {
  const qs = [
    Q({ id: 'size', kind: 'single_choice', options: ['S', 'M'], required: true, scope: 'ticket' }),
    Q({ id: 'agree', kind: 'checkbox', required: true }),
    Q({ id: 'vip', scope: 'ticket', tier_ids: ['vip'] }),
  ];
  it('keeps only what this order is asked, one entry per ticket', () => {
    const body = answersBody(qs, ['ga', 'ga'], {
      order: { agree: true, stale: 'x' }, tickets: [{ size: 'S', vip: 'nope' }, { size: '' }, { size: 'M' }],
    });
    expect(body).toEqual({ order: { agree: true }, tickets: [{ size: 'S' }, {}] });
  });
  it('nothing to ask: no body', () => {
    expect(answersBody([], ['ga'], { order: {}, tickets: [] })).toBeUndefined();
  });
  it('problems keyed for the form', () => {
    const p = draftProblems(qs, ['ga', 'ga'], { order: { agree: false }, tickets: [{ size: 'S' }] });
    expect(Object.keys(p).sort()).toEqual(['2:size', 'order:agree']);
    expect(p['2:size'].code).toBe('required');
  });
});

describe('questionDefProblem (the builder)', () => {
  it('accepts good definitions', () => {
    expect(questionDefProblem({ label: 'Size', kind: 'single_choice', options: ['S', 'M'], scope: 'ticket' })).toBeNull();
    expect(questionDefProblem({ label: 'Age', kind: 'number', min_value: 0, max_value: 120, scope: 'ticket' })).toBeNull();
    expect(questionDefProblem({ label: 'Pick', kind: 'multiple_choice', options: ['A', 'B', 'C'], min_choices: 1, max_choices: 2, scope: 'order' })).toBeNull();
  });
  it('refuses bad ones', () => {
    expect(questionDefProblem({ label: '', kind: 'text', scope: 'order' })).toMatch(/label/);
    expect(questionDefProblem({ label: 'x', kind: 'single_choice', options: ['A'], scope: 'order' })).toMatch(/options/);
    expect(questionDefProblem({ label: 'x', kind: 'single_choice', options: ['A', 'A'], scope: 'order' })).toMatch(/same/);
    expect(questionDefProblem({ label: 'x', kind: 'text', options: ['A', 'B'], scope: 'order' })).toMatch(/Only choice/);
    expect(questionDefProblem({ label: 'x', kind: 'number', max_length: 5, scope: 'order' })).toMatch(/maximum length/);
    expect(questionDefProblem({ label: 'x', kind: 'number', min_value: 5, max_value: 1, scope: 'order' })).toMatch(/above/);
    expect(questionDefProblem({ label: 'x', kind: 'multiple_choice', options: ['A', 'B'], max_choices: 3, scope: 'order' })).toMatch(/fit/);
    expect(questionDefProblem({ label: 'x', kind: 'essay' as never, scope: 'order' })).toMatch(/type/);
  });
});

describe('display, text, parsing, CSV', () => {
  it('answerDisplay', () => {
    expect(answerDisplay(true)).toBe('Yes');
    expect(answerDisplay(['Vegan', 'Halal'])).toBe('Vegan, Halal');
    expect(answerDisplay(12.5)).toBe('12.5');
  });
  it('problemText names the limit', () => {
    expect(problemText({ code: 'too_long' }, Q({ max_length: 20 }))).toBe('Keep it to 20 characters.');
    expect(problemText({ code: 'out_of_range' }, Q({ kind: 'number', min_value: 1, max_value: 9 }))).toBe('Enter a number from 1 to 9.');
    expect(problemText({ code: 'required' })).toBe('This answer is required.');
  });
  it('parsePublicQuestions tolerates junk', () => {
    expect(parsePublicQuestions(null)).toEqual({ questions: [], partySizes: {} });
    const p = parsePublicQuestions({ questions: [Q({}), { nope: 1 }], party_sizes: { tbl: 6, ga: 1, bad: 'x' } });
    expect(p.questions).toHaveLength(1);
    expect(p.partySizes).toEqual({ tbl: 6 });
  });
  const rows: AnswerRow[] = [
    { answer_id: '1', question_id: 'qa', order_ref: 'cs_1', ticket_id: null, ticket_index: null, scope: 'order', label: 'Company',
      current_label: 'Company name', kind: 'text', value: '=cmd', display: '=cmd', source: 'checkout', attendee_name: null,
      tier_name: null, ticket_status: null, buyer_email: 'a@x.com', question_archived: false, created_at: '2026-11-05T10:00:00Z' },
    { answer_id: '2', question_id: 'qs', order_ref: 'cs_1', ticket_id: 't1', ticket_index: 1, scope: 'ticket', label: 'Size',
      current_label: 'Size', kind: 'single_choice', value: 'M', display: 'M', source: 'checkout', attendee_name: 'Ada',
      tier_name: 'GA', ticket_status: 'active', buyer_email: 'a@x.com', question_archived: true, created_at: '2026-11-05T10:00:00Z' },
  ];
  it('answersCsv quotes formulas and marks archived questions', () => {
    const csv = answersCsv(rows);
    expect(csv.split('\r\n')[0]).toMatch(/^order_ref,ticket_id,ticket_number/);
    expect(csv).toContain("'=cmd");
    expect(csv).toContain('Size (archived)');
  });
  it('answerColumns: a ticket gets its own answer and its order\'s', () => {
    const a = answerColumns(rows);
    expect(a.columns).toEqual(['Company name', 'Size']);
    expect(a.forTicket('t1', 'cs_1')).toEqual(['=cmd', 'M']);
    expect(a.forTicket('t9', null)).toEqual(['', '']);
  });
});

// Security review (2026-11-05): a credential with only tickets:read (a door or
// check-in integration) gets per-ticket answers, never the order's.
describe('order-scope answers in the API (_shared/api/questionAnswers.ts)', async () => {
  const { orderAnswersDecision, canReadOrderAnswers, attachAnswers, attachAnswersPage } = await import('../../supabase/functions/_shared/api/questionAnswers.ts');
  it('orders:read (or a :write that covers it, or legacy read) sees them', () => {
    expect(orderAnswersDecision({ scopes: ['orders:read'] })).toBe(true);
    expect(orderAnswersDecision({ scopes: ['read'] })).toBe(true);
    expect(orderAnswersDecision({ scopes: ['tickets:read', 'orders:read'] })).toBe(true);
  });
  it('tickets:read only never sees them, whatever the role of its user or creator', () => {
    expect(orderAnswersDecision({ scopes: ['tickets:read'] })).toBe(false);
    expect(orderAnswersDecision({ scopes: ['tickets:read', 'checkin:write'] })).toBe(false);
  });
  const sbWith = () => {
    const calls: { fn: string; args: Record<string, unknown> }[] = [];
    const sb = {
      rpc: async (fn: string, args: Record<string, unknown>) => {
        calls.push({ fn, args });
        return { data: { 'aaaaaaaa-0000-4000-8000-000000000001': [{ scope: 'ticket', label: 'Size', value: 'M' }] }, error: null };
      },
    };
    return { sb: sb as never, calls };
  };
  it('the scope decides: an owner\'s or finance tickets:read-only credential is refused order answers, with no role lookup', async () => {
    for (const cred of [
      { kind: 'api_key' as const, id: 'k', scopes: ['tickets:read'], role: null },
      { kind: 'pat' as const, id: 'p', scopes: ['tickets:read'], role: 'owner' },
      { kind: 'oauth' as const, id: 'o', scopes: ['tickets:read', 'checkin:write'], role: 'finance' },
    ]) {
      const t = sbWith();
      expect(await canReadOrderAnswers(t.sb, 'org', cred)).toBe(false);
      expect(t.calls).toEqual([]);
    }
    const t = sbWith();
    expect(await canReadOrderAnswers(t.sb, 'org', { kind: 'api_key', id: 'k', scopes: ['tickets:read', 'orders:read'], role: null })).toBe(true);
    expect(t.calls).toEqual([]);
  });
  it('attachAnswers passes the flag to _exos_answers_for', async () => {
    const t = sbWith();
    const rows = [{ id: 'aaaaaaaa-0000-4000-8000-000000000001' }] as Record<string, unknown>[];
    await attachAnswers(t.sb, rows, false);
    expect(t.calls.at(-1)).toEqual({ fn: '_exos_answers_for', args: { p_ticket_ids: ['aaaaaaaa-0000-4000-8000-000000000001'], p_include_order: false } });
    expect(rows[0].answers).toEqual([{ scope: 'ticket', label: 'Size', value: 'M' }]);
    await attachAnswersPage(t.sb, { data: rows }, true);
    expect(t.calls.at(-1)!.args.p_include_order).toBe(true);
  });
});
