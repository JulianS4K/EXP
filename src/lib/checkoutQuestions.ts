// Checkout questions (mig 20261106110000, docs/checkout-questions.md): the
// SPA's side. The rules themselves are shared with exos-checkout and mirrored
// in SQL (supabase/functions/_shared/questions.ts); this file is the data
// access plus the pure helpers the forms and the report use.
//
//   buyers     getPublicQuestions (anon RPC), the per-ticket count of an
//              order (table ticket types are asked per seat), the answers
//              body that rides in the checkout request (never only in
//              storage: in-app browsers have none)
//   organizer  list / save / archive / reorder (event editor), the answers
//              table and its CSV, answers in the attendee export
//   door       a ticket's answers (RLS: door staff read per-ticket answers
//              of their event) and setting one at the door

import { supabase } from './supabase';
import { toCsv } from './csv';
import {
  answerDisplay, questionsFor, validateAnswers, visibleQuestionsFor, type AnswerProblem, type AnswerValue, type QuestionDef,
} from '../../supabase/functions/_shared/questions.ts';

export type { AnswerProblem, AnswerValue, QuestionDef } from '../../supabase/functions/_shared/questions.ts';

/** What the buyer types or picks, before normalising (strings, booleans, lists). */
export type RawAnswer = string | boolean | string[] | number | null | undefined;

/** The form's state: order-wide answers and one map per ticket. */
export interface AnswerDraft {
  order: Record<string, RawAnswer>;
  tickets: Record<string, RawAnswer>[];
}

export const EMPTY_DRAFT: AnswerDraft = { order: {}, tickets: [] };

export interface PublicQuestions {
  questions: QuestionDef[];
  /** Ticket types sold as tables: tickets per unit (default 1). */
  partySizes: Record<string, number>;
}

/** An organizer's view of a question (archived included). */
export interface AdminQuestion extends QuestionDef {
  hidden: boolean;
  archived: boolean;
  answer_count: number;
}

/** One row of the answers table (exos_event_question_answers). */
export interface AnswerRow {
  answer_id: string;
  question_id: string;
  order_ref: string;
  ticket_id: string | null;
  ticket_index: number | null;
  scope: 'order' | 'ticket';
  label: string;
  current_label: string;
  kind: string;
  value: AnswerValue;
  display: string;
  source: string;
  attendee_name: string | null;
  tier_name: string | null;
  ticket_status: string | null;
  buyer_email: string | null;
  question_archived: boolean;
  created_at: string;
}

/** A ticket's answer (door, ticket detail). */
export interface TicketAnswer {
  question_id: string;
  scope: 'order' | 'ticket';
  label: string;
  kind: string;
  value: AnswerValue;
  display: string;
}

// ---------------------------------------------------------------- pure ------

/** Parse exos_public_event_questions. Anything malformed reads as "no questions". */
export function parsePublicQuestions(raw: unknown): PublicQuestions {
  const r = (raw ?? {}) as { questions?: unknown; party_sizes?: unknown };
  const questions = Array.isArray(r.questions)
    ? (r.questions as QuestionDef[]).filter((q) => q && typeof q.id === 'string' && typeof q.kind === 'string')
    : [];
  const partySizes: Record<string, number> = {};
  if (r.party_sizes && typeof r.party_sizes === 'object') {
    for (const [k, v] of Object.entries(r.party_sizes as Record<string, unknown>)) {
      const n = Math.floor(Number(v));
      if (Number.isFinite(n) && n > 1) partySizes[k] = n;
    }
  }
  return { questions, partySizes };
}

/** The ticket type of each ticket of an order of `quantity` units of `tierId`. */
export function ticketTiersFor(tierId: string, quantity: number, partySizes: Record<string, number> = {}): string[] {
  const n = Math.max(1, Math.floor(quantity || 1)) * (partySizes[tierId] ?? 1);
  return Array.from({ length: Math.min(n, 100) }, () => tierId);
}

/** Does this order have anything to ask? */
export function hasQuestions(qs: readonly QuestionDef[], ticketTiers: readonly string[]): boolean {
  const f = questionsFor(qs, ticketTiers);
  return f.order.length > 0 || f.ticket.some((t) => t.length > 0);
}

/** The request body's `answers`: only questions this order is asked (and shown, for
 *  "show only if" questions: a hidden one's stale answer is left out), one entry per ticket. */
export function answersBody(qs: readonly QuestionDef[], ticketTiers: readonly string[], draft: AnswerDraft): { order: Record<string, RawAnswer>; tickets: Record<string, RawAnswer>[] } | undefined {
  if (!hasQuestions(qs, ticketTiers)) return undefined;
  const f = visibleQuestionsFor(qs, ticketTiers, draft);
  const pick = (src: Record<string, RawAnswer> | undefined, list: QuestionDef[]) => {
    const out: Record<string, RawAnswer> = {};
    for (const q of list) {
      const v = src?.[q.id];
      if (v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && v.length === 0) && v !== false) out[q.id] = v;
    }
    return out;
  };
  return {
    order: pick(draft.order, f.order),
    tickets: f.ticket.map((list, i) => pick(draft.tickets[i], list)),
  };
}

/** Check a draft the way the server will; problems keyed for the form ("order:<id>" / "<ticket>:<id>"). */
export function draftProblems(qs: readonly QuestionDef[], ticketTiers: readonly string[], draft: AnswerDraft): Record<string, AnswerProblem> {
  const body = answersBody(qs, ticketTiers, draft);
  if (!body) return {};
  const r = validateAnswers(qs, body, { ticketTiers, require: true });
  const out: Record<string, AnswerProblem> = {};
  for (const p of r.problems) {
    const key = `${p.ticket ?? 'order'}:${p.question_id ?? ''}`;
    if (!out[key]) out[key] = p;
  }
  return out;
}

/** The answers table as CSV: one row per answer, the label the buyer saw and today's. */
export function answersCsv(rows: readonly AnswerRow[]): string {
  const header = [
    'order_ref', 'ticket_id', 'ticket_number', 'attendee_name', 'ticket_type', 'ticket_status', 'buyer_email',
    'question', 'question_now', 'scope', 'answer', 'source', 'answered_at',
  ];
  return toCsv(header, rows.map((r) => [
    r.order_ref, r.ticket_id ?? '', r.ticket_index ?? '', r.attendee_name ?? '', r.tier_name ?? '', r.ticket_status ?? '',
    r.buyer_email ?? '', r.label, r.current_label + (r.question_archived ? ' (archived)' : ''), r.scope, r.display || answerDisplay(r.value),
    r.source, r.created_at ? new Date(r.created_at) : '',
  ]));
}

/**
 * Answers as extra attendee-export columns: one column per question (in the
 * order they were first answered), the ticket's own answer or its order's.
 */
export function answerColumns(rows: readonly AnswerRow[]): { columns: string[]; forTicket: (ticketId: string, orderRef?: string | null) => string[] } {
  const ids: string[] = [];
  const names = new Map<string, string>();
  const byTicket = new Map<string, Map<string, string>>();
  const byOrder = new Map<string, Map<string, string>>();
  for (const r of rows) {
    if (!names.has(r.question_id)) { ids.push(r.question_id); names.set(r.question_id, r.current_label || r.label); }
    const text = r.display || answerDisplay(r.value);
    if (r.scope === 'ticket' && r.ticket_id) {
      if (!byTicket.has(r.ticket_id)) byTicket.set(r.ticket_id, new Map());
      byTicket.get(r.ticket_id)!.set(r.question_id, text);
    } else if (r.scope === 'order') {
      if (!byOrder.has(r.order_ref)) byOrder.set(r.order_ref, new Map());
      byOrder.get(r.order_ref)!.set(r.question_id, text);
    }
  }
  return {
    columns: ids.map((id) => names.get(id)!),
    forTicket: (ticketId, orderRef) => ids.map((id) => byTicket.get(ticketId)?.get(id) ?? (orderRef ? byOrder.get(orderRef)?.get(id) : undefined) ?? ''),
  };
}

/** The function's own error message, if any. */
function rpcError(error: unknown, fallback: string): Error {
  const m = (error as { message?: string } | null)?.message;
  return new Error(m ? m.replace(/^exos_[a-z_]+: /, '') : fallback);
}

// ---------------------------------------------------------------- data ------

/** The questions a buyer is asked for this event (none when the RPC is missing). */
export async function getPublicQuestions(eventId: string): Promise<PublicQuestions> {
  const { data, error } = await supabase.rpc('exos_public_event_questions', { p_event_id: eventId });
  if (error) {
    // Before mig 20261106110000 there is nothing to ask.
    if (['PGRST202', '42883'].includes(String((error as { code?: string }).code))) return { questions: [], partySizes: {} };
    throw rpcError(error, 'Could not load the checkout questions.');
  }
  return parsePublicQuestions(data);
}

export async function listEventQuestions(eventId: string): Promise<AdminQuestion[]> {
  const { data, error } = await supabase.rpc('exos_list_event_questions', { p_event_id: eventId });
  if (error) throw rpcError(error, 'Could not load the questions.');
  return (Array.isArray(data) ? data : []) as AdminQuestion[];
}

export async function saveEventQuestion(eventId: string, question: Partial<QuestionDef> & { hidden?: boolean }, questionId?: string): Promise<AdminQuestion> {
  const { id: _id, sort_order: _s, ...body } = question as QuestionDef & { hidden?: boolean };
  const { data, error } = await supabase.rpc('exos_save_event_question', {
    p_event_id: eventId, p_question: body, p_question_id: questionId ?? null,
  });
  if (error) throw rpcError(error, 'Could not save the question.');
  return data as AdminQuestion;
}

export async function archiveEventQuestion(questionId: string, archived = true): Promise<AdminQuestion> {
  const { data, error } = await supabase.rpc('exos_archive_event_question', { p_question_id: questionId, p_archived: archived });
  if (error) throw rpcError(error, 'Could not archive the question.');
  return data as AdminQuestion;
}

export async function reorderEventQuestions(eventId: string, ids: string[]): Promise<AdminQuestion[]> {
  const { data, error } = await supabase.rpc('exos_reorder_event_questions', { p_event_id: eventId, p_ids: ids });
  if (error) throw rpcError(error, 'Could not reorder the questions.');
  return (Array.isArray(data) ? data : []) as AdminQuestion[];
}

/** The answers table (owner / manager / finance). */
export async function listEventAnswers(eventId: string): Promise<AnswerRow[]> {
  const { data, error } = await supabase.rpc('exos_event_question_answers', { p_event_id: eventId });
  if (error) throw rpcError(error, 'Could not load the answers.');
  return (Array.isArray(data) ? data : []) as AnswerRow[];
}

/** A ticket's answers as the door sees them (per-ticket only for scanners). */
export async function listTicketAnswers(ticketId: string): Promise<TicketAnswer[]> {
  const { data, error } = await supabase.from('exos_question_answers')
    .select('question_id, scope, label, kind, value, display')
    .eq('ticket_id', ticketId)
    .order('created_at', { ascending: true });
  if (error) throw rpcError(error, 'Could not load the answers.');
  return (data ?? []) as TicketAnswer[];
}

/** The free claim with answers (exos_claim_free_tickets_answered). */
export async function claimFreeTicketsAnswered(input: {
  eventId: string; tierId: string; quantity: number; promoterId?: string | null; channel?: string | null;
  orderRef: string; answers: unknown;
}): Promise<string[]> {
  const { data, error } = await supabase.rpc('exos_claim_free_tickets_answered', {
    p_event_id: input.eventId, p_tier_id: input.tierId, p_quantity: input.quantity,
    p_promoter_id: input.promoterId ?? null, p_channel: input.channel ?? null,
    p_order_ref: input.orderRef, p_answers: input.answers ?? null,
  });
  if (error) throw rpcError(error, 'Could not reserve tickets.');
  return (data ?? []) as string[];
}

/** Door staff: set (or clear, with '') a ticket's per-ticket answers. */
export async function setTicketAnswersAtDoor(ticketId: string, answers: Record<string, RawAnswer>): Promise<TicketAnswer[]> {
  const { data, error } = await supabase.rpc('exos_door_set_ticket_answers', { p_ticket_id: ticketId, p_answers: answers });
  if (error) throw rpcError(error, 'Could not save the answer.');
  return (Array.isArray(data) ? data : []) as TicketAnswer[];
}
