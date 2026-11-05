// Which checkout answers a partner API credential sees on a ticket
// (claude/exos-checkout-questions, mig 20261106110000; exos-api/questions.ts).
// A ticket's own (per-ticket) answers come with tickets:read. Its order's
// answers are order data: only with orders:read (or a scope that covers it),
// or for a credential of an owner, manager or finance (a user token by its
// live role, an org API key by its creator's role, _exos_api_key_actor). So a
// door or check-in integration holding only tickets:read gets per-ticket
// answers only. Pure apart from the client handed in; vitest imports it.

import { hasScope } from './scopes.ts';

/** The least of a Supabase client this needs. */
export interface RpcClient {
  // deno-lint-ignore no-explicit-any
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: any; error: { code?: string; message?: string } | null }>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** What the API knows of the credential (index.ts Credential). */
export interface AnswerCred {
  kind: "api_key" | "pat" | "oauth";
  id: string;
  scopes: readonly string[];
  role: string | null;
}

/** Roles that see order data without orders:read. */
export const ORDER_ANSWER_ROLES = ["owner", "manager", "finance"] as const;

/**
 * May this credential read order-scope answers? true / false, or 'creator'
 * when it depends on the role of an org API key's creator (checked in SQL).
 */
export function orderAnswersDecision(cred: Pick<AnswerCred, "kind" | "scopes" | "role">): boolean | "creator" {
  if (hasScope(cred.scopes, "orders:read")) return true;
  if (cred.kind === "api_key") return "creator";
  return (ORDER_ANSWER_ROLES as readonly string[]).includes(cred.role ?? "");
}

/** orderAnswersDecision, resolving an API key's creator role (_exos_api_key_actor). */
export async function canReadOrderAnswers(sb: RpcClient, orgId: string, cred: AnswerCred): Promise<boolean> {
  const d = orderAnswersDecision(cred);
  if (d !== "creator") return d;
  const { error } = await sb.rpc("_exos_api_key_actor", { p_org: orgId, p_api_key: cred.id, p_roles: [...ORDER_ANSWER_ROLES] });
  return !error;
}

/**
 * Every ticket row gets `answers` (DICE's fanSurveyAnswers): its own, and its
 * order's only when `includeOrder` (canReadOrderAnswers). Rows without an
 * `id`, or a database without the migration, are returned as they are.
 */
export async function attachAnswers<T>(sb: RpcClient, rows: T, includeOrder: boolean): Promise<T> {
  const list = (Array.isArray(rows) ? rows : [rows]) as Record<string, unknown>[];
  const ids = list.map((r) => r?.id).filter((x): x is string => typeof x === "string" && UUID_RE.test(x));
  if (ids.length === 0) return rows;
  const { data, error } = await sb.rpc("_exos_answers_for", { p_ticket_ids: ids, p_include_order: includeOrder === true });
  if (error) {
    if (!["PGRST202", "42883"].includes(String(error.code))) console.error("exos-api: answers read failed", error.message);
    return rows;
  }
  const by = (data ?? {}) as Record<string, unknown>;
  for (const r of list) if (r && typeof r.id === "string") r.answers = by[r.id] ?? [];
  return rows;
}

/** attachAnswers on a { data: [...] } envelope. */
export async function attachAnswersPage<T extends { data: unknown }>(sb: RpcClient, page: T, includeOrder: boolean): Promise<T> {
  await attachAnswers(sb, page.data, includeOrder);
  return page;
}

