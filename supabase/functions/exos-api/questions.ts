// exos-api: checkout questions and their answers (claude/exos-checkout-questions,
// mig 20261106110000, docs/checkout-questions.md, docs/api/questions.json).
// Dispatched from index.ts by route id.
//
//   GET    /events/:id/questions            (events:read)  every question, archived included
//   POST   /events/:id/questions            (events:write) add one
//   PUT    /events/:id/questions/order      (events:write) reorder
//   GET    /questions/:id                   (events:read)
//   PATCH  /questions/:id                   (events:write) change (label, options, required, ...)
//   DELETE /questions/:id                   (events:write) archive (answers are kept)
//   GET    /events/:id/question-answers     (orders:read)  the answers table, paged
//   GET    /orders/:id/answers              (orders:read)  an order's answers
//   GET    /tickets/:id/answers             (tickets:read) a ticket's answers (+ its order's)
//
// And `answers` on every ticket the API returns (list-attendees, get-order,
// list-tickets, get-ticket: attachAnswers), the shape of DICE's
// Ticket.fanSurveyAnswers (label = fanSurveyQuestion.title, display = value).
// A ticket's own (per-ticket) answers come with tickets:read; its order's
// answers are order data and come only with orders:read, or to a credential
// of an owner / manager / finance (canReadOrderAnswers). A door or check-in
// integration holding only tickets:read sees per-ticket answers only.
//
// The function runs with the service role: every call names the key's org
// and the SQL cores take it, so another org's event or question is a 404.
// Writes need an org API key whose creator is an owner or manager now
// (_exos_api_key_actor, as the sibling routes). This file answers its own
// errors (a Response), so index.ts needs no case for them.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";
import { canReadOrderAnswers, type AnswerCred } from "../_shared/api/questionAnswers.ts";
export { attachAnswers, attachAnswersPage, canReadOrderAnswers, orderAnswersDecision } from "../_shared/api/questionAnswers.ts";

/** The route ids this module answers. */
export const QUESTION_ROUTES = new Set([
  "list-event-questions", "create-event-question", "reorder-event-questions", "get-question", "update-question",
  "archive-question", "list-event-question-answers", "get-order-answers", "get-ticket-answers",
]);

export interface QuestionsCtx {
  sb: SupabaseClient;
  orgId: string;
  keyId: string;
  cred: AnswerCred;
  params: Record<string, string>;
  page: Page;
  body: Record<string, unknown>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ORDER_RE = /^[A-Za-z0-9_:-]{1,200}$/;
/** The fields a question takes (the SQL checks them again). */
export const QUESTION_FIELDS = [
  "label", "help_text", "kind", "options", "required", "scope", "tier_ids", "max_length", "min_choices",
  "max_choices", "min_value", "max_value", "hidden", "archived", "sort_order",
] as const;

class QErr extends Error {
  constructor(public status: number, message: string) { super(message); }
}

function answer(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/** The body, or its one wrapped object ({ question: {...} }). */
export function unwrapQuestion(b: Record<string, unknown>): Record<string, unknown> {
  const inner = b.question;
  if (inner && typeof inner === "object" && !Array.isArray(inner) && Object.keys(b).length === 1) {
    return inner as Record<string, unknown>;
  }
  return b;
}

/** A first-pass check of a question body; null when fine. */
export function questionBodyProblem(b: Record<string, unknown>): string | null {
  const extra = Object.keys(b).find((k) => !(QUESTION_FIELDS as readonly string[]).includes(k));
  if (extra) return `unknown field ${extra.slice(0, 60)}`;
  if (Object.keys(b).length === 0) return "send at least one question field";
  return null;
}

function dbError(e: unknown): QErr {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === "string" ? err.code : "";
  const message = String(err?.message ?? "request refused").slice(0, 400);
  if (code === "P0002") return new QErr(404, message);
  if (code === "42501") return new QErr(403, message);
  if (["22023", "23514", "22P02", "22003"].includes(code)) return new QErr(400, message);
  console.error("exos-api questions:", code, message);
  return new QErr(500, "internal error");
}

// deno-lint-ignore no-explicit-any
async function rpc(c: QuestionsCtx, fn: string, args: Record<string, unknown>): Promise<any> {
  const { data, error } = await c.sb.rpc(fn, args);
  if (error) throw dbError(error);
  return data;
}

async function ownEvent(c: QuestionsCtx): Promise<string> {
  const id = c.params.id;
  if (!id || !UUID_RE.test(id)) throw new QErr(404, "event not found");
  const { data, error } = await c.sb.from("exos_events").select("id").eq("id", id).eq("org_id", c.orgId).maybeSingle();
  if (error) throw dbError(error);
  if (!data) throw new QErr(404, "event not found");
  return id;
}

async function ownQuestion(c: QuestionsCtx): Promise<{ id: string; event_id: string }> {
  const id = c.params.id;
  if (!id || !UUID_RE.test(id)) throw new QErr(404, "question not found");
  const { data, error } = await c.sb.from("exos_event_questions").select("id, event_id").eq("id", id).eq("org_id", c.orgId).maybeSingle();
  if (error) throw dbError(error);
  if (!data) throw new QErr(404, "question not found");
  return data as { id: string; event_id: string };
}

async function actor(c: QuestionsCtx): Promise<string> {
  return await rpc(c, "_exos_api_key_actor", { p_org: c.orgId, p_api_key: c.keyId, p_roles: ["owner", "manager"] });
}

/** Handles one of this module's routes; always a Response. */
export async function handleQuestions(route: ApiRoute, c: QuestionsCtx): Promise<Response> {
  try {
    return await dispatch(route, c);
  } catch (e) {
    const q = e instanceof QErr ? e : dbError(e);
    return answer({ error: q.message }, q.status);
  }
}

async function dispatch(route: ApiRoute, c: QuestionsCtx): Promise<Response> {
  switch (route.id) {
    case "list-event-questions": {
      const id = await ownEvent(c);
      return answer({ data: await rpc(c, "_exos_api_questions", { p_org: c.orgId, p_event: id }) });
    }
    case "create-event-question": {
      const id = await ownEvent(c);
      const body = unwrapQuestion(c.body);
      const problem = questionBodyProblem(body);
      if (problem) throw new QErr(400, problem);
      const uid = await actor(c);
      return answer({ data: await rpc(c, "_exos_question_upsert", { p_org: c.orgId, p_event: id, p_id: null, p: body, p_actor: uid }) }, 201);
    }
    case "reorder-event-questions": {
      const id = await ownEvent(c);
      const ids = c.body.question_ids ?? c.body.ids;
      if (!Array.isArray(ids) || ids.length === 0 || ids.length > 200 || ids.some((x) => typeof x !== "string" || !UUID_RE.test(x))) {
        throw new QErr(400, "question_ids must be a list of this event's question ids");
      }
      await actor(c);
      return answer({ data: await rpc(c, "_exos_questions_reorder", { p_org: c.orgId, p_event: id, p_ids: ids }) });
    }
    case "get-question": {
      const q = await ownQuestion(c);
      const all = await rpc(c, "_exos_api_questions", { p_org: c.orgId, p_event: q.event_id }) as { id: string }[];
      const one = (all ?? []).find((x) => x.id === q.id);
      if (!one) throw new QErr(404, "question not found");
      return answer({ data: one });
    }
    case "update-question": {
      const q = await ownQuestion(c);
      const body = unwrapQuestion(c.body);
      const problem = questionBodyProblem(body);
      if (problem) throw new QErr(400, problem);
      const uid = await actor(c);
      return answer({ data: await rpc(c, "_exos_question_upsert", { p_org: c.orgId, p_event: q.event_id, p_id: q.id, p: body, p_actor: uid }) });
    }
    case "archive-question": {
      const q = await ownQuestion(c);
      await actor(c);
      return answer({ data: await rpc(c, "_exos_question_archive", { p_org: c.orgId, p_id: q.id, p_archived: true }) });
    }
    case "list-event-question-answers": {
      const id = await ownEvent(c);
      const { data, error, count } = await c.sb.rpc("_exos_event_answer_rows", { p_event: id }, { count: "exact" })
        .range(c.page.from, c.page.to);
      if (error) {
        if (error.code === "PGRST103") return answer(pageEnvelope([], c.page, null));
        throw dbError(error);
      }
      return answer(pageEnvelope((data ?? []) as unknown[], c.page, count ?? null));
    }
    case "get-order-answers": {
      const ref = c.params.id;
      if (!ref || !ORDER_RE.test(ref)) throw new QErr(404, "order not found");
      const { data, error } = await c.sb.from("exos_question_answers")
        .select("question_id, scope, ticket_id, ticket_index, label, kind, value, display, source, created_at")
        .eq("org_id", c.orgId).eq("order_ref", ref).not("attached_at", "is", null)
        .order("ticket_index", { ascending: true, nullsFirst: true }).order("created_at");
      if (error) throw dbError(error);
      if ((data ?? []).length === 0) {
        // An order without answers is an empty list; an unknown one a 404.
        const [{ count: s }, { count: t }] = await Promise.all([
          c.sb.from("exos_checkout_sessions").select("session_id", { count: "exact", head: true }).eq("org_id", c.orgId).eq("session_id", ref),
          c.sb.from("exos_tickets").select("id", { count: "exact", head: true }).eq("org_id", c.orgId).eq("order_ref", ref),
        ]);
        if (!s && !t) throw new QErr(404, "order not found");
      }
      return answer({ data: data ?? [] });
    }
    case "get-ticket-answers": {
      const id = c.params.id;
      if (!id || !UUID_RE.test(id)) throw new QErr(404, "ticket not found");
      const { data: t, error } = await c.sb.from("exos_tickets").select("id").eq("id", id).eq("org_id", c.orgId).maybeSingle();
      if (error) throw dbError(error);
      if (!t) throw new QErr(404, "ticket not found");
      const all = await rpc(c, "_exos_answers_for", {
        p_ticket_ids: [id], p_include_order: await canReadOrderAnswers(c.sb, c.orgId, c.cred),
      }) as Record<string, unknown>;
      return answer({ data: all?.[id] ?? [] });
    }
  }
  throw new QErr(404, "not found");
}

/**
 * Optional answers sent with POST /events/:id/organizer-reservations/:token/complete
 * (`answers`, or `ticket_reservation.answers`): stored for the reservation's
 * tickets before they're minted. Not required (the box office asks), but
 * checked like a buyer's. Returns the body without them.
 */
export async function reservationAnswers(
  sb: SupabaseClient, orgId: string, token: string, body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const wrapped = body.ticket_reservation && typeof body.ticket_reservation === "object" && !Array.isArray(body.ticket_reservation)
    ? body.ticket_reservation as Record<string, unknown> : null;
  const answers = body.answers ?? wrapped?.answers;
  if (answers === undefined) return body;
  const { error } = await sb.rpc("_exos_api_reservation_answers", { p_org: orgId, p_token: token, p_answers: answers });
  if (error && !["PGRST202", "42883"].includes(String(error.code))) throw dbError(error);
  const rest = { ...body };
  delete rest.answers;
  if (wrapped) {
    const w = { ...wrapped };
    delete w.answers;
    rest.ticket_reservation = w;
  }
  return rest;
}

/** An error from reservationAnswers, as index.ts answers it. */
export function isQuestionsError(e: unknown): e is { status: number; message: string } {
  return e instanceof QErr;
}
