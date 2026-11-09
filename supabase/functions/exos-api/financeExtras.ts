// exos-api: deal brackets, ledger codes per revenue type, per-event
// overrides and backfills, imported ledger entries, reporting rows and the
// cash summary (mig 20261102120000, docs/api/finance-extras.json).
// Dispatched from index.ts by route id, after ./finance.ts.
//
// The function runs with the service role, so every query names the key's
// org (c.orgId) and the SQL cores take it as p_org: an id of another org is
// a 404. Brackets, overrides and revenue codes are rows whose triggers
// validate them; imports and backfills run through their SQL cores.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { BodyError, isUuid } from "../_shared/api/booking.ts";
import {
  assignmentBody, bracketBody, cashRange, enumParam, idParam, importBody, IMPORT_SOURCES, isoParam, REPORTING_SOURCE_TYPES,
  REVENUE_TYPES, revenueCodeBody,
} from "../_shared/api/financeExtras.ts";
import type { FinCtx, FinDeps } from "./finance.ts";

const BRACKET_COLS = "id, offer_id, basis, threshold, percentage, created_at, updated_at, offer:exos_offers!inner(budget_id, status)";
const ASSIGN_COLS = "id, event_id, revenue_type, gl_code_id, created_at, updated_at, gl:exos_gl_codes(code, name)";
const ENTRY_COLS =
  "id, event_id, source, description, amount_cents, tax_amount_cents, currency, gl_code, tax_gl_code, tax_name, posted_at, " +
  "source_system, source_line_id, source_order_id, import_run_id, created_via, created_at";
const ROW_COLS =
  "id, event_id, source_type, source_id, revenue_type, occurred_at, currency, amount_cents, payment_method, description, " +
  "gl_code_id, gl_code, imported, tagged_at";

// deno-lint-ignore no-explicit-any
function bracketView(r: any): Record<string, unknown> {
  const { offer, ...rest } = r;
  return { ...rest, percentage: Number(r.percentage), budget_id: offer?.budget_id ?? null, offer_status: offer?.status ?? null };
}

// deno-lint-ignore no-explicit-any
function assignmentView(r: any): Record<string, unknown> {
  const { gl, ...rest } = r;
  return { ...rest, gl_code: gl?.code ?? null, gl_code_name: gl?.name ?? null };
}

function param(c: FinCtx, d: FinDeps, name: string, what: string): string {
  const v = c.params[name];
  if (!isUuid(v)) throw d.notFound(what);
  return v;
}

// deno-lint-ignore no-explicit-any
async function one(p: PromiseLike<{ data: any; error: unknown }>, d: FinDeps, what: string): Promise<any> {
  const { data, error } = await p;
  if (error) throw error;
  if (!data) throw d.notFound(what);
  return data;
}

async function ownEvent(sb: SupabaseClient, orgId: string, c: FinCtx, d: FinDeps): Promise<string> {
  const id = param(c, d, "id", "event");
  await one(sb.from("exos_events").select("id").eq("org_id", orgId).eq("id", id).maybeSingle(), d, "event");
  return id;
}

/** Handles one of this module's routes; undefined = not ours. */
export async function handleFinanceExtras(id: string, c: FinCtx, d: FinDeps): Promise<unknown> {
  const { sb, orgId } = c;
  switch (id) {
    // ---- Deal brackets ------------------------------------------------------
    case "list-deal-brackets": {
      let q = sb.from("exos_deal_brackets").select(BRACKET_COLS, { count: "exact" }).eq("org_id", orgId);
      const offer = idParam(c.q, "offer_id", "q[v3_offer_id_eq]");
      if (offer) q = q.eq("offer_id", offer);
      const budget = idParam(c.q, "budget_id", "q[v3_budget_id_eq]");
      if (budget) q = q.eq("offer.budget_id", budget);
      const r = await q.order("offer_id").order("threshold").range(c.page.from, c.page.to);
      const out = d.paged(r, c.page) as { data: unknown[] };
      return { ...out, data: out.data.map(bracketView) };
    }
    case "get-deal-bracket":
      return {
        data: bracketView(await one(sb.from("exos_deal_brackets").select(BRACKET_COLS).eq("org_id", orgId)
          .eq("id", param(c, d, "id", "deal bracket")).maybeSingle(), d, "deal bracket")),
      };
    case "create-deal-bracket": {
      const { offerId, row } = bracketBody(c.body, true);
      // The offer must be the key's org's (the trigger takes the org from it).
      await one(sb.from("exos_offers").select("id").eq("org_id", orgId).eq("id", offerId!).maybeSingle(), d, "offer");
      return d.created({
        data: bracketView(await one(sb.from("exos_deal_brackets").insert({ ...row, offer_id: offerId, org_id: orgId })
          .select(BRACKET_COLS).single(), d, "deal bracket")),
      });
    }
    case "update-deal-bracket": {
      const { row } = bracketBody(c.body, false);
      return {
        data: bracketView(await one(sb.from("exos_deal_brackets").update(row).eq("org_id", orgId)
          .eq("id", param(c, d, "id", "deal bracket")).select(BRACKET_COLS).maybeSingle(), d, "deal bracket")),
      };
    }
    case "delete-deal-bracket": {
      const bid = param(c, d, "id", "deal bracket");
      const gone = await one(sb.from("exos_deal_brackets").delete().eq("org_id", orgId).eq("id", bid)
        .select(BRACKET_COLS).maybeSingle(), d, "deal bracket");
      return { data: { ...bracketView(gone), deleted: true } };
    }

    // ---- Ledger codes per revenue type ------------------------------------------
    case "list-gl-revenue-codes": {
      const { data, error } = await sb.from("exos_gl_revenue_codes").select("revenue_type, gl_code_id, updated_at, gl:exos_gl_codes(code, name)")
        .eq("org_id", orgId);
      if (error) throw error;
      // deno-lint-ignore no-explicit-any
      const by = new Map((data ?? []).map((r: any) => [r.revenue_type, r]));
      return {
        data: REVENUE_TYPES.map((t) => {
          // deno-lint-ignore no-explicit-any
          const r = by.get(t) as any;
          return { revenue_type: t, gl_code_id: r?.gl_code_id ?? null, gl_code: r?.gl?.code ?? null, gl_code_name: r?.gl?.name ?? null };
        }),
      };
    }
    case "set-gl-revenue-code": {
      const { revenueType, glCodeId } = revenueCodeBody(c.params.type, c.body);
      if (glCodeId === null) {
        const { error } = await sb.from("exos_gl_revenue_codes").delete().eq("org_id", orgId).eq("revenue_type", revenueType);
        if (error) throw error;
        return { data: { revenue_type: revenueType, gl_code_id: null } };
      }
      await one(sb.from("exos_gl_codes").select("id").eq("org_id", orgId).eq("id", glCodeId).is("discarded_at", null).maybeSingle(), d, "ledger code");
      const { error } = await sb.from("exos_gl_revenue_codes")
        .upsert({ org_id: orgId, revenue_type: revenueType, gl_code_id: glCodeId }, { onConflict: "org_id,revenue_type" });
      if (error) throw error;
      return { data: { revenue_type: revenueType, gl_code_id: glCodeId } };
    }

    // ---- Per-event overrides and backfills ----------------------------------------
    case "list-gl-code-assignments": {
      const ev = await ownEvent(sb, orgId, c, d);
      const { data, error } = await sb.from("exos_gl_code_assignments").select(ASSIGN_COLS).eq("org_id", orgId).eq("event_id", ev)
        .order("revenue_type");
      if (error) throw error;
      return { data: (data ?? []).map(assignmentView) };
    }
    case "create-gl-code-assignment": {
      const ev = await ownEvent(sb, orgId, c, d);
      const row = assignmentBody(c.body, true);
      await one(sb.from("exos_gl_codes").select("id").eq("org_id", orgId).eq("id", row.gl_code_id as string).maybeSingle(), d, "ledger code");
      return d.created({
        data: assignmentView(await one(sb.from("exos_gl_code_assignments").insert({ ...row, event_id: ev, org_id: orgId })
          .select(ASSIGN_COLS).single(), d, "override")),
      });
    }
    case "update-gl-code-assignment": {
      const row = assignmentBody(c.body, false);
      await one(sb.from("exos_gl_codes").select("id").eq("org_id", orgId).eq("id", row.gl_code_id as string).maybeSingle(), d, "ledger code");
      let q = sb.from("exos_gl_code_assignments").update(row).eq("org_id", orgId).eq("id", param(c, d, "id", "override"));
      if (c.params.eid !== undefined) q = q.eq("event_id", param(c, d, "eid", "override"));
      return { data: assignmentView(await one(q.select(ASSIGN_COLS).maybeSingle(), d, "override")) };
    }
    case "delete-gl-code-assignment": {
      const aid = param(c, d, "id", "override");
      let q = sb.from("exos_gl_code_assignments").delete().eq("org_id", orgId).eq("id", aid);
      if (c.params.eid !== undefined) q = q.eq("event_id", param(c, d, "eid", "override"));
      await one(q.select("id").maybeSingle(), d, "override");
      return { data: { id: aid, deleted: true } };
    }
    case "backfill-gl-codes":
      return { data: await d.rpc(sb, "_exos_gl_backfill", { p_org: orgId, p_event: param(c, d, "id", "event") }) };

    // ---- Imported ledger entries ------------------------------------------------------
    case "list-imported-ledger-entries": {
      let q = sb.from("exos_imported_ledger_entries").select(ENTRY_COLS, { count: "exact" }).eq("org_id", orgId);
      const ev = idParam(c.q, "event_id");
      if (ev) q = q.eq("event_id", ev);
      const src = enumParam(c.q, IMPORT_SOURCES, "source", "q[source_eq]");
      if (src) q = q.eq("source", src);
      for (const [col, names] of [["source_system", ["source_system", "q[source_system_eq]"]], ["import_run_id", ["import_run_id", "q[import_run_id_eq]"]],
        ["source_line_id", ["source_line_id", "q[source_line_id_eq]"]], ["gl_code", ["gl_code", "q[general_ledger_code_eq]"]]] as const) {
        for (const n of names) {
          const v = c.q.get(n);
          if (v === null || v === "") continue;
          if (v.length > 200) throw new BodyError(`${n} must be at most 200 characters.`);
          q = q.eq(col, col === "source_system" ? v.toLowerCase() : v);
          break;
        }
      }
      const from = isoParam(c.q, "posted_from", "q[posted_at_gteq]");
      if (from) q = q.gte("posted_at", from);
      const to = isoParam(c.q, "posted_to", "q[posted_at_lt]");
      if (to) q = q.lt("posted_at", to);
      return d.paged(await q.order("posted_at").order("id").range(c.page.from, c.page.to), c.page);
    }
    case "import-ledger-entries":
      return d.created({
        data: await d.rpc(sb, "_exos_ledger_import", { p_org: orgId, p_actor: null, p_via: "api", p_api_key: c.key.id, p_rows: importBody(c.body) }),
      });
    case "delete-imported-ledger-entry": {
      const eid = param(c, d, "id", "ledger entry");
      await one(sb.from("exos_imported_ledger_entries").delete().eq("org_id", orgId).eq("id", eid).select("id").maybeSingle(), d, "ledger entry");
      return { data: { id: eid, deleted: true } };
    }

    // ---- Reporting rows -------------------------------------------------------------------
    case "list-reporting-rows": {
      let q = sb.from("exos_reporting_rows").select(ROW_COLS, { count: "exact" }).eq("org_id", orgId);
      const ev = idParam(c.q, "event_id", "q[confirm_id_eq]");
      if (ev) q = q.eq("event_id", ev);
      const st = enumParam(c.q, REPORTING_SOURCE_TYPES, "source_type");
      if (st) q = q.eq("source_type", st);
      const rt = enumParam(c.q, REVENUE_TYPES, "revenue_type");
      if (rt) q = q.eq("revenue_type", rt);
      const imp = enumParam(c.q, ["true", "false"] as const, "imported");
      if (imp) q = q.eq("imported", imp === "true");
      const gl = c.q.get("gl_code");
      if (gl) {
        if (gl.length > 24) throw new BodyError("gl_code must be at most 24 characters.");
        q = q.eq("gl_code", gl);
      }
      const from = isoParam(c.q, "from");
      if (from) q = q.gte("occurred_at", from);
      const to = isoParam(c.q, "to");
      if (to) q = q.lt("occurred_at", to);
      return d.paged(await q.order("occurred_at").order("id").range(c.page.from, c.page.to), c.page);
    }
    case "get-reporting-row":
      return {
        data: await one(sb.from("exos_reporting_rows").select(ROW_COLS).eq("org_id", orgId)
          .eq("id", param(c, d, "id", "reporting row")).maybeSingle(), d, "reporting row"),
      };

    // ---- Cash summary -----------------------------------------------------------------------
    case "get-cash-summary": {
      const ev = param(c, d, "id", "event");
      const { from, to } = cashRange(c.q);
      return { data: await d.rpc(sb, "_exos_cash_summary", { p_org: orgId, p_event: ev, p_from: from, p_to: to }) };
    }
  }
  return undefined;
}
