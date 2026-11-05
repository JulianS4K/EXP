// Which checkout answers a partner API credential sees on a ticket
// (claude/exos-checkout-questions, mig 20261106110000; exos-api/questions.ts).
// A ticket's own (per-ticket) answers come with tickets:read. Its order's
// answers are order data: only with orders:read (or a scope that covers it).
// The credential's scopes decide, never the role of its user or creator: an
// owner who mints a tickets:read-only key for a door integration means it to
// see per-ticket answers only (security review 2026-11-05). Scopes are already
// capped by the role (exos_role_token_scopes), so this never widens anything.
// Pure apart from the client handed in; vitest imports it.

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

/** May this credential read order-scope answers? Only with orders:read (or a scope covering it). */
export function orderAnswersDecision(cred: Pick<AnswerCred, "scopes">): boolean {
  return hasScope(cred.scopes, "orders:read");
}

/**
 * orderAnswersDecision for exos-api's call sites (async, same signature as
 * before; no role lookup: a role never stands in for the scope).
 */
// deno-lint-ignore require-await
export async function canReadOrderAnswers(_sb: RpcClient, _orgId: string, cred: AnswerCred): Promise<boolean> {
  return orderAnswersDecision(cred);
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

