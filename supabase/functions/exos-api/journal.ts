// claude/exos-money-journal (mig 20261108100000): the org's double-entry
// journal (docs/journal.md, docs/api/journal.json).
//
//   GET /v1/journal   finance:read   one row per journal line, oldest first,
//                                    paged; ?from / ?to (ISO, on the entry's
//                                    date, to exclusive), ?event_id,
//                                    ?account, ?source
//
// Read-only: the journal is written by triggers on the money tables and is
// append-only. The function runs with the service role, so the query names
// the key's org; an event id of another org simply matches nothing. The
// credential's scope decides the read (never a role).

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";
import { enumParam, idParam, isoParam } from "../_shared/api/financeExtras.ts";

export const JOURNAL_ROUTES = new Set(["list-journal"]);

/** The chart (exos_journal_accounts()); the API filter takes these codes. */
export const JOURNAL_ACCOUNTS = [
  "stripe_clearing", "paypal_receivable", "pos_cash_drawer", "marketplace_receivable", "organizer_payable",
  "sales_tax_payable", "promoter_commissions_payable", "gift_cards_outstanding", "tips_payable", "ticket_revenue",
  "buyer_fees", "pos_other_sales", "donations", "refunds", "exos_fee", "card_fees", "disputes", "promoter_commissions",
  "pos_paid_outs",
] as const;

/** Where an entry came from (exos_journal_entries.source_table, without the exos_ prefix). */
export const JOURNAL_SOURCES = [
  "checkout_sessions", "order_refunds", "fee_adjustments", "disputes", "marketplace_orders", "org_payout_lines",
  "promoter_commissions", "pos_payments", "pos_paid_outs",
] as const;

const COLS =
  "line_id, entry_id, entry_number, event_id, occurred_at, currency, source_table, source_id, kind, session_id, reverses, " +
  "line_no, account, account_number, account_name, account_type, debit_cents, credit_cents, memo";

export class JournalError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export interface JournalCtx {
  sb: SupabaseClient;
  orgId: string;
  q: URLSearchParams;
  page: Page;
}

/** A line as the API shows it. */
// deno-lint-ignore no-explicit-any
export function apiJournalLine(r: any): Record<string, unknown> {
  return {
    id: r.line_id,
    entry_id: r.entry_id,
    entry_number: Number(r.entry_number),
    date: r.occurred_at,
    event_id: r.event_id ?? null,
    source: String(r.source_table ?? "").replace(/^exos_/, ""),
    source_id: r.source_id,
    kind: r.kind,
    order_id: r.session_id ?? null,
    reverses: r.reverses ?? null,
    line_no: r.line_no,
    account: r.account,
    account_number: r.account_number,
    account_name: r.account_name,
    account_type: r.account_type,
    debit_cents: Number(r.debit_cents),
    credit_cents: Number(r.credit_cents),
    currency: r.currency,
    memo: r.memo ?? "",
  };
}

export async function handleJournal(route: ApiRoute, c: JournalCtx): Promise<unknown> {
  if (route.id !== "list-journal") throw new JournalError(404, "not found");
  let q = c.sb.from("exos_journal_rows").select(COLS, { count: "exact" }).eq("org_id", c.orgId);
  const from = isoParam(c.q, "from");
  if (from) q = q.gte("occurred_at", from);
  const to = isoParam(c.q, "to");
  if (to) q = q.lt("occurred_at", to);
  const ev = idParam(c.q, "event_id");
  if (ev) q = q.eq("event_id", ev);
  const account = enumParam(c.q, JOURNAL_ACCOUNTS, "account");
  if (account) q = q.eq("account", account);
  const source = enumParam(c.q, JOURNAL_SOURCES, "source");
  if (source) q = q.eq("source_table", `exos_${source}`);
  const r = await q.order("occurred_at").order("entry_number").order("line_no").range(c.page.from, c.page.to);
  if (r.error) {
    if (r.error.code === "PGRST103") return pageEnvelope([], c.page, null); // past the end
    throw r.error;
  }
  return pageEnvelope((r.data ?? []).map(apiJournalLine), c.page, r.count);
}
