import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import {
  CONDITION_MAX_DEPTH, CONDITION_PARENT_KINDS, conditionMet, conditionProblem, hiddenQuestions, validateAnswers,
  visibleQuestionsFor, type QuestionDef,
} from '../../supabase/functions/_shared/questions.ts';
import { answersBody, draftProblems } from './checkoutQuestions';

// "Show only if" questions (mig 20261107110000). The cases between the
// DG6-CASES markers of tests/exos/test_dice_gaps_6.sql run through the SQL
// (_exos_validate_answers_core, DG10) and here through _shared/questions.ts:
// the same JSON, the same expectations.
const root = resolve(__dirname, '../..');
const harness = readFileSync(resolve(root, 'tests/exos/test_dice_gaps_6.sql'), 'utf8');
const migration = readFileSync(resolve(root, 'supabase/migrations/20261107110000_exos_dice_gaps_6.sql'), 'utf8');

const doc = JSON.parse(/-- DG6-CASES-BEGIN([\s\S]*?)-- DG6-CASES-END/.exec(harness)![1]) as {
  tiers: Record<string, string>;
  questions: Record<string, QuestionDef>;
  cases: { name: string; q: string[]; tiers: string[]; require: boolean; answers: unknown; expect: string[]; normalized?: unknown }[];
};
const idToName = Object.fromEntries(Object.entries(doc.questions).map(([k, q]) => [q.id, k]));
const toIds = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [doc.questions[k]?.id ?? k, v]));
const toNames = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [idToName[k] ?? k, v]));

describe('TS/SQL parity (tests/exos/test_dice_gaps_6.sql DG10)', () => {
  it('has the shared cases', () => {
    expect(doc.cases.length).toBeGreaterThan(20);
  });
  for (const c of doc.cases) {
    it(c.name, () => {
      const qs = c.q.map((n) => doc.questions[n]);
      const tiers = c.tiers.map((t) => doc.tiers[t]);
      const a = (c.answers ?? {}) as { order?: Record<string, unknown>; tickets?: (Record<string, unknown> | null)[] };
      const answers = {
        ...(a.order !== undefined ? { order: toIds(a.order) } : {}),
        ...(a.tickets !== undefined ? { tickets: a.tickets.map((t) => (t ? toIds(t) : t)) } : {}),
      };
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
  it('parent kinds and depth', () => {
    expect(migration).toContain(`p.kind NOT IN (${CONDITION_PARENT_KINDS.map((k) => `'${k}'`).join(', ')})`);
    expect(migration).toContain(`IF p_depth >= ${CONDITION_MAX_DEPTH} THEN RETURN false; END IF;`);
    expect(migration).toContain(`IF v_n > ${CONDITION_MAX_DEPTH} THEN`);
  });
});

const Q = (id: string, more: Partial<QuestionDef> = {}): QuestionDef => ({
  id, label: id, kind: 'text', options: [], required: false, scope: 'order', tier_ids: null, ...more,
});
const guest = Q('guest', { kind: 'single_choice', options: ['Yes', 'No'], required: true });
const name = Q('name', { required: true, parent_question_id: 'guest', parent_values: ['Yes'] });
const size = Q('size', { kind: 'single_choice', options: ['S', 'L'], scope: 'ticket' });
const tall = Q('tall', { kind: 'checkbox', scope: 'ticket', parent_question_id: 'size', parent_values: ['L'] });

describe('conditionMet', () => {
  it('choices, multiple choices, checkboxes; empty and invalid never meet', () => {
    expect(conditionMet(guest, 'Yes', ['Yes'])).toBe(true);
    expect(conditionMet(guest, ' Yes ', ['Yes'])).toBe(true);
    expect(conditionMet(guest, 'No', ['Yes'])).toBe(false);
    expect(conditionMet(guest, 'Maybe', ['Maybe'])).toBe(false);
    expect(conditionMet(guest, '', ['Yes'])).toBe(false);
    const multi = Q('m', { kind: 'multiple_choice', options: ['a', 'b', 'c'] });
    expect(conditionMet(multi, ['c', 'a'], ['a'])).toBe(true);
    expect(conditionMet(multi, ['c'], ['a', 'b'])).toBe(false);
    const box = Q('x', { kind: 'checkbox' });
    expect(conditionMet(box, true, ['true'])).toBe(true);
    expect(conditionMet(box, false, ['true'])).toBe(false);
    expect(conditionMet(guest, 'Yes', null)).toBe(false);
  });
});

describe('what the buyer sees', () => {
  it('B appears once A is answered with a value that shows it', () => {
    const qs = [guest, name];
    expect(visibleQuestionsFor(qs, ['t'], { order: {} }).order.map((q) => q.id)).toEqual(['guest']);
    expect(visibleQuestionsFor(qs, ['t'], { order: { guest: 'No' } }).order.map((q) => q.id)).toEqual(['guest']);
    expect(visibleQuestionsFor(qs, ['t'], { order: { guest: 'Yes' } }).order.map((q) => q.id)).toEqual(['guest', 'name']);
  });
  it('per ticket: each ticket on its own answer', () => {
    const v = visibleQuestionsFor([size, tall], ['t', 't'], { order: {}, tickets: [{ size: 'L' }, { size: 'S' }] });
    expect(v.ticket.map((l) => l.map((q) => q.id))).toEqual([['size', 'tall'], ['size']]);
    const h = hiddenQuestions([size, tall], { tickets: [{ size: 'L' }] }, ['t', 't']);
    expect([...h.tickets[0]]).toEqual([]);
    expect([...h.tickets[1]]).toEqual(['tall']);
  });
  it('a hidden answer left in the form is not sent, and not required', () => {
    const draft = { order: { guest: 'No', name: 'Stale' }, tickets: [] };
    expect(answersBody([guest, name], ['t'], draft)).toEqual({ order: { guest: 'No' }, tickets: [{}] });
    expect(draftProblems([guest, name], ['t'], draft)).toEqual({});
    const shown = { order: { guest: 'Yes' }, tickets: [] };
    expect(Object.keys(draftProblems([guest, name], ['t'], shown))).toEqual(['order:name']);
  });
});

describe('conditionProblem (the builder; the SQL refuses the same)', () => {
  const notes = Q('notes');
  const all = [guest, name, size, tall, notes];
  it('fine conditions', () => {
    expect(conditionProblem({ id: 'name', scope: 'order', parent_question_id: 'guest', parent_values: ['Yes'] }, all)).toBeNull();
    expect(conditionProblem({ id: 'x', scope: 'ticket', parent_question_id: 'guest', parent_values: ['No'] }, all)).toBeNull();
    expect(conditionProblem({ id: 'x', scope: 'ticket', parent_question_id: 'tall', parent_values: ['true'] }, all)).toBeNull();
    expect(conditionProblem({ id: 'x', scope: 'order' }, all)).toBeNull();
  });
  it('refused', () => {
    expect(conditionProblem({ id: 'x', scope: 'order', parent_question_id: 'notes', parent_values: ['a'] }, all)).toMatch(/choice or checkbox/);
    expect(conditionProblem({ id: 'x', scope: 'order', parent_question_id: 'guest', parent_values: ['Maybe'] }, all)).toMatch(/options/);
    expect(conditionProblem({ id: 'x', scope: 'order', parent_question_id: 'guest', parent_values: [] }, all)).toMatch(/Pick the answer/);
    expect(conditionProblem({ id: 'x', scope: 'order', parent_question_id: 'size', parent_values: ['L'] }, all)).toMatch(/per-order/);
    expect(conditionProblem({ id: 'x', scope: 'ticket', parent_question_id: 'tall', parent_values: ['Yes'] }, all)).toMatch(/ticked/);
    expect(conditionProblem({ id: 'x', scope: 'order', parent_question_id: 'gone', parent_values: ['Yes'] }, all)).toMatch(/this event/);
    expect(conditionProblem({ id: 'guest', scope: 'order', parent_question_id: 'guest', parent_values: ['Yes'] }, all)).toMatch(/itself/);
    // guest under a choice that is itself under guest: a loop.
    const pick = Q('pick', { kind: 'single_choice', options: ['x', 'y'], parent_question_id: 'guest', parent_values: ['Yes'] });
    expect(conditionProblem({ id: 'guest', scope: 'order', parent_question_id: 'pick', parent_values: ['x'] }, [...all, pick])).toMatch(/loop/);
  });
});
