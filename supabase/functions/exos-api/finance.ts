// exos-api: offers, budgets, offer pools, templates, imports, deals, finance
// categories, GL codes, finance items, settlements, profit and loss and
// ticket-count emails (migs 20261031100000 / 20261031100500,
// docs/offers-settlements.md). Dispatched from index.ts by route id.
//
// The function runs with the service role, so every query names the key's
// org (c.orgId) and every SQL core takes it as p_org: an id of another org is
// a 404. Offers and settlements are written only through the SQL cores
// (state machine, tokens, webhooks, mail); the plain tables are written as
// rows whose triggers validate them. The settlement and P&L numbers come
// from _shared/finance (the same file the dashboard runs).

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { Page } from "../_shared/api/paging.ts";
import { BodyError, isUuid } from "../_shared/api/booking.ts";
import {
  budgetLineBody, budgetPatch, categoryBody, dealBody, financeItemBody, glCodeBody, offerBody, OFFER_STATUS_FILTER,
  pnlRange, poolBody, settlementPatch, templateBody, ticketCountsBody, unwrapBody,
} from "../_shared/api/finance.ts";
import { orgPnl, orgPnlCsv, settle, showPnl, showPnlCsv, type SettlementInputs } from "../_shared/finance/settlementModel.ts";
import { offerPdf, settlementPdf } from "../_shared/finance/documents.ts";

export interface FinCtx {
  sb: SupabaseClient;
  orgId: string;
  key: { id: string };
  params: Record<string, string>;
  q: URLSearchParams;
  page: Page;
  body: Record<string, unknown>;
}

export interface FinDeps {
  notFound: (what: string) => Error;
  conflict: (msg: string) => Error;
  // deno-lint-ignore no-explicit-any
  paged: (r: { data: any; error: any; count: number | null }, page: Page) => unknown;
  // deno-lint-ignore no-explicit-any
  rpc: (sb: SupabaseClient, fn: string, args: Record<string, unknown>) => Promise<any>;
  created: (body: unknown) => unknown;
}

const OFFER_COLS =
  "id, budget_id, title, status, hold_id, event_id, venue_id, room_id, dates, currency, artist_id, artist_name, act_type, " +
  "terms, pool_share_percent, agent_name, agent_email, agent_company, agent_phone, boilerplate, notes, template_id, " +
  "import_id, expires_at, sent_at, sent_to, response, history, created_via, created_at, updated_at";
const TEMPLATE_COLS =
  "id, name, currency, terms, boilerplate, budget_lines, capacity, average_price_cents, sell_through_percent, " +
  "expires_in_days, created_at, updated_at";
const BUDGET_COLS =
  "id, name, currency, venue_id, hold_id, event_id, capacity, average_price_cents, sell_through_percent, notes, created_at, updated_at";
const LINE_COLS = "id, budget_id, category_id, kind, label, amount_cents, position, notes, created_at, updated_at";
const POOL_COLS = "id, budget_id, mode, terms, created_at, updated_at";
const IMPORT_COLS = "id, file_name, status, row_count, created_count, errors, created_via, created_at, updated_at";
const DEAL_COLS =
  "id, name, deal_type, stage, status, amount_cents, currency, probability, expected_close_on, owner_user_id, contact_name, " +
  "contact_email, company, offer_id, event_id, notes, discarded_at, created_at, updated_at";
const CATEGORY_COLS = "id, key, name, kind, system, gl_code_id, position, created_at, updated_at";
const GL_COLS = "id, code, name, kind, description, discarded_at, created_at, updated_at";
const ITEM_COLS =
  "id, event_id, category_id, kind, label, amount_cents, forecast_cents, estimate_cents, actual_cents, notes, auto, created_at, updated_at";

/** An offer row as the API shows it (agent folded, status as it reads now). */
// deno-lint-ignore no-explicit-any
export function offerView(o: any): Record<string, unknown> {
  const { agent_name, agent_email, agent_company, agent_phone, ...rest } = o;
  const expired = o.status === "sent" && o.expires_at && Date.parse(o.expires_at) <= Date.now();
  return {
    ...rest,
    status: expired ? "expired" : o.status,
    agent: agent_name === null && agent_email === null ? null
      : { name: agent_name, email: agent_email, company: agent_company, phone: agent_phone },
  };
}

function idParam(c: FinCtx, d: FinDeps, name: string, what: string): string {
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

// deno-lint-ignore no-explicit-any
async function many(p: PromiseLike<{ data: any; error: unknown }>): Promise<any[]> {
  const { data, error } = await p;
  if (error) throw error;
  return data ?? [];
}

function pdfResponse(bytes: Uint8Array, name: string): Response {
  return new Response(bytes as unknown as BodyInit, {
    status: 200,
    headers: {
      "content-type": "application/pdf",
      "content-disposition": `inline; filename="${name.replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 80) || "document"}.pdf"`,
      "cache-control": "no-store",
    },
  });
}

function csvResponse(text: string, name: string): Response {
  return new Response(text, {
    status: 200,
    headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": `attachment; filename="${name}.csv"`, "cache-control": "no-store" },
  });
}

async function ownEvent(c: FinCtx, d: FinDeps, name = "id"): Promise<string> {
  const id = idParam(c, d, name, "event");
  await one(c.sb.from("exos_events").select("id").eq("org_id", c.orgId).eq("id", id).maybeSingle(), d, "event");
  return id;
}

/** A show's inputs: the snapshot when finalized, else live. Read-only. */
async function showInputs(c: FinCtx, d: FinDeps, eventId: string): Promise<{ inputs: SettlementInputs; finalized: boolean }> {
  const { data: st, error } = await c.sb.from("exos_settlements").select("status, snapshot").eq("event_id", eventId).maybeSingle();
  if (error) throw error;
  if (st?.status === "finalized" && st.snapshot) return { inputs: st.snapshot as SettlementInputs, finalized: true };
  const inputs = await d.rpc(c.sb, "_exos_settlement_inputs", { p_event: eventId });
  if (!inputs) throw d.notFound("event");
  return { inputs: inputs as SettlementInputs, finalized: false };
}

/** The settlement as the API shows it: the row, its inputs and the computed result. */
// deno-lint-ignore no-explicit-any
function settlementView(s: any): Record<string, unknown> {
  const computed = s?.inputs ? settle(s.inputs as SettlementInputs) : null;
  return { ...s, computed };
}

/** Handles one of this module's routes; undefined = not ours. */
export async function handleFinance(id: string, c: FinCtx, d: FinDeps): Promise<unknown> {
  const { sb, orgId } = c;
  switch (id) {
    // ---- Offers -------------------------------------------------------------
    case "list-offers": {
      await d.rpc(sb, "_exos_offers_expire", { p_org: orgId });
      let q = sb.from("exos_offers").select(OFFER_COLS, { count: "exact" }).eq("org_id", orgId);
      const status = c.q.get("status");
      if (status !== null) {
        if (!(OFFER_STATUS_FILTER as readonly string[]).includes(status)) throw new BodyError(`status must be one of ${OFFER_STATUS_FILTER.join(", ")}.`);
        q = q.eq("status", status);
      }
      for (const f of ["event_id", "hold_id", "budget_id", "artist_id"]) {
        const v = c.q.get(f);
        if (v === null) continue;
        if (!isUuid(v)) throw new BodyError(`${f} must be an id.`);
        q = q.eq(f, v);
      }
      const r = await q.order("created_at", { ascending: false }).order("id").range(c.page.from, c.page.to);
      const out = d.paged(r, c.page) as { data: unknown[] };
      return { ...out, data: out.data.map(offerView) };
    }
    case "create-offer":
      return d.created({
        data: await d.rpc(sb, "_exos_offer_save", {
          p_org: orgId, p_actor: null, p_via: "api", p_api_key: c.key.id, p_offer_id: null, p: offerBody(c.body, true),
        }),
      });
    case "get-offer": {
      const oid = idParam(c, d, "id", "offer");
      return { data: offerView(await one(sb.from("exos_offers").select(OFFER_COLS).eq("org_id", orgId).eq("id", oid).maybeSingle(), d, "offer")) };
    }
    case "update-offer":
      return {
        data: await d.rpc(sb, "_exos_offer_save", {
          p_org: orgId, p_actor: null, p_via: "api", p_api_key: c.key.id, p_offer_id: idParam(c, d, "id", "offer"), p: offerBody(c.body, false),
        }),
      };
    case "delete-offer": {
      const oid = idParam(c, d, "id", "offer");
      await d.rpc(sb, "_exos_offer_delete", { p_org: orgId, p_offer_id: oid });
      return { data: { id: oid, deleted: true } };
    }
    case "send-offer": {
      const b = unwrapBody(c.body, "offer", "v3_offer");
      const to = b.to ?? b.last_sent_to ?? null;
      if (to !== null && typeof to !== "string") throw new BodyError("to must be an email address.");
      const out = await d.rpc(sb, "_exos_offer_send", { p_org: orgId, p_actor: null, p_offer_id: idParam(c, d, "id", "offer"), p_to: to });
      return { data: out };
    }
    case "accept-offer":
    case "decline-offer": {
      const b = unwrapBody(c.body);
      if ((b.name !== undefined && b.name !== null && typeof b.name !== "string") || (b.note !== undefined && b.note !== null && typeof b.note !== "string")) {
        throw new BodyError("name and note must be strings.");
      }
      return {
        data: await d.rpc(sb, "_exos_offer_record_response", {
          p_org: orgId, p_actor: null, p_offer_id: idParam(c, d, "id", "offer"), p_action: id === "accept-offer" ? "accept" : "decline",
          p_name: b.name ?? null, p_note: b.note ?? null, p_via: "api", p_ip: null, p_user_agent: null,
        }),
      };
    }
    case "cancel-offer": {
      const b = unwrapBody(c.body);
      if (b.note !== undefined && b.note !== null && typeof b.note !== "string") throw new BodyError("note must be a string.");
      return { data: await d.rpc(sb, "_exos_offer_cancel", { p_org: orgId, p_actor: null, p_offer_id: idParam(c, d, "id", "offer"), p_note: b.note ?? null }) };
    }
    case "get-offer-pdf": {
      const oid = idParam(c, d, "id", "offer");
      const o = await one(sb.from("exos_offers").select(OFFER_COLS).eq("org_id", orgId).eq("id", oid).maybeSingle(), d, "offer");
      const [{ data: org }, { data: venue }, { data: room }, { data: budget }] = await Promise.all([
        sb.from("exos_orgs").select("name").eq("id", orgId).maybeSingle(),
        o.venue_id ? sb.from("exos_venues").select("name").eq("id", o.venue_id).maybeSingle() : Promise.resolve({ data: null }),
        o.room_id ? sb.from("exos_venue_rooms").select("name").eq("id", o.room_id).maybeSingle() : Promise.resolve({ data: null }),
        sb.from("exos_budgets").select("capacity, average_price_cents").eq("id", o.budget_id).maybeSingle(),
      ]);
      const v = offerView(o) as Record<string, unknown>;
      return pdfResponse(offerPdf({
        title: o.title, status: String(v.status), org: org ? { name: org.name } : null, artist_name: o.artist_name, act_type: o.act_type,
        dates: o.dates ?? [], currency: o.currency, venue: venue ? { name: venue.name, room: room?.name ?? null } : null,
        terms: o.terms ?? {}, budget, agent_name: o.agent_name, boilerplate: o.boilerplate, expires_at: o.expires_at,
        sent_at: o.sent_at, response: o.response,
      }), `offer-${o.artist_name}`);
    }

    // ---- Templates --------------------------------------------------------------
    case "list-offer-templates":
      return { data: await many(sb.from("exos_offer_templates").select(TEMPLATE_COLS).eq("org_id", orgId).order("name").order("id")) };
    case "create-offer-template":
      return d.created({
        data: await one(sb.from("exos_offer_templates").insert({ ...templateBody(c.body, false), org_id: orgId }).select(TEMPLATE_COLS).single(), d, "template"),
      });
    case "get-offer-template":
      return {
        data: await one(sb.from("exos_offer_templates").select(TEMPLATE_COLS).eq("org_id", orgId)
          .eq("id", idParam(c, d, "id", "template")).maybeSingle(), d, "template"),
      };
    case "update-offer-template":
      return {
        data: await one(sb.from("exos_offer_templates").update(templateBody(c.body, true)).eq("org_id", orgId)
          .eq("id", idParam(c, d, "id", "template")).select(TEMPLATE_COLS).maybeSingle(), d, "template"),
      };
    case "delete-offer-template": {
      const tid = idParam(c, d, "id", "template");
      await one(sb.from("exos_offer_templates").delete().eq("org_id", orgId).eq("id", tid).select("id").maybeSingle(), d, "template");
      return { data: { id: tid, deleted: true } };
    }
    case "apply-offer-template": {
      const t = await one(sb.from("exos_offer_templates").select(TEMPLATE_COLS).eq("org_id", orgId)
        .eq("id", idParam(c, d, "id", "template")).maybeSingle(), d, "template");
      const b = unwrapBody(c.body);
      const offerId = b.offer_id ?? b.v3_offer_id;
      if (!isUuid(offerId)) throw new BodyError("offer_id is required.");
      const patch: Record<string, unknown> = { terms: t.terms };
      if (t.boilerplate) patch.boilerplate = t.boilerplate;
      if (t.expires_in_days) patch.expires_at = new Date(Date.now() + t.expires_in_days * 86_400_000).toISOString();
      return {
        data: await d.rpc(sb, "_exos_offer_save", { p_org: orgId, p_actor: null, p_via: "api", p_api_key: c.key.id, p_offer_id: offerId, p: patch }),
      };
    }

    // ---- Budgets, lines, pools -------------------------------------------------------
    case "list-budgets": {
      let q = sb.from("exos_budgets").select(BUDGET_COLS, { count: "exact" }).eq("org_id", orgId);
      for (const f of ["event_id", "hold_id", "venue_id"]) {
        const v = c.q.get(f);
        if (v === null) continue;
        if (!isUuid(v)) throw new BodyError(`${f} must be an id.`);
        q = q.eq(f, v);
      }
      return d.paged(await q.order("created_at", { ascending: false }).order("id").range(c.page.from, c.page.to), c.page);
    }
    case "get-budget": {
      const bid = idParam(c, d, "id", "budget");
      const b = await one(sb.from("exos_budgets").select(BUDGET_COLS).eq("org_id", orgId).eq("id", bid).maybeSingle(), d, "budget");
      const [lines, offers, pool] = await Promise.all([
        many(sb.from("exos_budget_lines").select(LINE_COLS).eq("budget_id", bid).order("position").order("created_at")),
        many(sb.from("exos_offers").select("id, artist_name, status, terms, pool_share_percent").eq("budget_id", bid).order("created_at")),
        sb.from("exos_offer_pools").select(POOL_COLS).eq("budget_id", bid).maybeSingle(),
      ]);
      return { data: { ...b, lines, offers, pool: pool.data ?? null } };
    }
    case "update-budget":
      return {
        data: await one(sb.from("exos_budgets").update(budgetPatch(c.body)).eq("org_id", orgId)
          .eq("id", idParam(c, d, "id", "budget")).select(BUDGET_COLS).maybeSingle(), d, "budget"),
      };
    case "list-budget-lines": {
      const bid = idParam(c, d, "id", "budget");
      await one(sb.from("exos_budgets").select("id").eq("org_id", orgId).eq("id", bid).maybeSingle(), d, "budget");
      return { data: await many(sb.from("exos_budget_lines").select(LINE_COLS).eq("budget_id", bid).order("position").order("created_at")) };
    }
    case "create-budget-line": {
      const bid = idParam(c, d, "id", "budget");
      await one(sb.from("exos_budgets").select("id").eq("org_id", orgId).eq("id", bid).maybeSingle(), d, "budget");
      return d.created({
        data: await one(sb.from("exos_budget_lines").insert({ ...budgetLineBody(c.body, false), budget_id: bid, org_id: orgId })
          .select(LINE_COLS).single(), d, "line"),
      });
    }
    case "update-budget-line":
      return {
        data: await one(sb.from("exos_budget_lines").update(budgetLineBody(c.body, true)).eq("org_id", orgId)
          .eq("id", idParam(c, d, "id", "line")).select(LINE_COLS).maybeSingle(), d, "budget line"),
      };
    case "delete-budget-line": {
      const lid = idParam(c, d, "id", "line");
      await one(sb.from("exos_budget_lines").delete().eq("org_id", orgId).eq("id", lid).select("id").maybeSingle(), d, "budget line");
      return { data: { id: lid, deleted: true } };
    }
    case "create-offer-pool": {
      const p = poolBody(c.body, true);
      let budgetId = p.budgetId;
      if (p.offerId) {
        const o = await one(sb.from("exos_offers").select("budget_id").eq("org_id", orgId).eq("id", p.offerId).maybeSingle(), d, "offer");
        budgetId = o.budget_id;
      }
      return { data: await d.rpc(sb, "_exos_offer_pool_ensure", { p_org: orgId, p_actor: null, p_budget_id: budgetId, p_mode: p.mode, p_terms: p.terms }) };
    }
    case "get-offer-pool":
    case "update-offer-pool": {
      const pool = await one(sb.from("exos_offer_pools").select(POOL_COLS).eq("org_id", orgId)
        .eq("id", idParam(c, d, "id", "pool")).maybeSingle(), d, "pool");
      const p = id === "update-offer-pool" ? poolBody(c.body, false) : { mode: null, terms: null };
      return {
        data: await d.rpc(sb, "_exos_offer_pool_ensure", {
          p_org: orgId, p_actor: null, p_budget_id: pool.budget_id, p_mode: p.mode, p_terms: p.terms,
        }),
      };
    }

    // ---- Imports ------------------------------------------------------------------------
    case "list-offer-imports":
      return d.paged(await sb.from("exos_offer_imports").select(IMPORT_COLS, { count: "exact" }).eq("org_id", orgId)
        .order("created_at", { ascending: false }).order("id").range(c.page.from, c.page.to), c.page);
    case "create-offer-import": {
      const b = unwrapBody(c.body, "offer_import");
      if (!Array.isArray(b.rows)) throw new BodyError("rows must be a list of offers (at most 200).");
      if (b.file_name !== undefined && b.file_name !== null && typeof b.file_name !== "string") throw new BodyError("file_name must be a string.");
      return d.created({
        data: await d.rpc(sb, "_exos_offer_import", {
          p_org: orgId, p_actor: null, p_via: "api", p_api_key: c.key.id, p_file_name: b.file_name ?? null, p_rows: b.rows,
        }),
      });
    }
    case "get-offer-import": {
      const iid = idParam(c, d, "id", "import");
      const imp = await one(sb.from("exos_offer_imports").select(IMPORT_COLS).eq("org_id", orgId).eq("id", iid).maybeSingle(), d, "import");
      const offers = await many(sb.from("exos_offers").select("id").eq("import_id", iid).order("created_at"));
      return { data: { ...imp, offer_ids: offers.map((o) => o.id) } };
    }
    case "delete-offer-import": {
      const iid = idParam(c, d, "id", "import");
      await one(sb.from("exos_offer_imports").delete().eq("org_id", orgId).eq("id", iid).select("id").maybeSingle(), d, "import");
      return { data: { id: iid, deleted: true } };
    }

    // ---- Deals ----------------------------------------------------------------------------
    case "list-deals": {
      let q = sb.from("exos_crm_deals").select(DEAL_COLS, { count: "exact" }).eq("org_id", orgId);
      if (c.q.get("include_discarded") !== "true") q = q.is("discarded_at", null);
      const st = c.q.get("status");
      if (st !== null) {
        if (!["open", "won", "lost"].includes(st)) throw new BodyError("status must be open, won or lost.");
        q = q.eq("status", st);
      }
      const dt = c.q.get("deal_type");
      if (dt !== null) {
        if (!["sales", "fundraising"].includes(dt)) throw new BodyError("deal_type must be sales or fundraising.");
        q = q.eq("deal_type", dt);
      }
      return d.paged(await q.order("created_at", { ascending: false }).order("id").range(c.page.from, c.page.to), c.page);
    }
    case "create-deal":
      return d.created({ data: await one(sb.from("exos_crm_deals").insert({ ...dealBody(c.body, false), org_id: orgId }).select(DEAL_COLS).single(), d, "deal") });
    case "get-deal":
      return { data: await one(sb.from("exos_crm_deals").select(DEAL_COLS).eq("org_id", orgId).eq("id", idParam(c, d, "id", "deal")).maybeSingle(), d, "deal") };
    case "update-deal":
      return {
        data: await one(sb.from("exos_crm_deals").update(dealBody(c.body, true)).eq("org_id", orgId).is("discarded_at", null)
          .eq("id", idParam(c, d, "id", "deal")).select(DEAL_COLS).maybeSingle(), d, "deal"),
      };
    case "delete-deal": {
      const did = idParam(c, d, "id", "deal");
      await one(sb.from("exos_crm_deals").update({ discarded_at: new Date().toISOString() }).eq("org_id", orgId)
        .is("discarded_at", null).eq("id", did).select("id").maybeSingle(), d, "deal");
      return { data: { id: did, discarded: true } };
    }

    // ---- Finance categories and GL codes ------------------------------------------------------
    case "list-finance-categories":
      await d.rpc(sb, "_exos_fin_seed", { p_org: orgId });
      return { data: await many(sb.from("exos_finance_categories").select(CATEGORY_COLS).eq("org_id", orgId).order("position").order("name")) };
    case "create-finance-category":
      await d.rpc(sb, "_exos_fin_seed", { p_org: orgId });
      return d.created({
        data: await one(sb.from("exos_finance_categories").insert({ ...categoryBody(c.body, false), org_id: orgId }).select(CATEGORY_COLS).single(), d, "category"),
      });
    case "get-finance-category":
      return {
        data: await one(sb.from("exos_finance_categories").select(CATEGORY_COLS).eq("org_id", orgId)
          .eq("id", idParam(c, d, "id", "category")).maybeSingle(), d, "category"),
      };
    case "update-finance-category":
      return {
        data: await one(sb.from("exos_finance_categories").update(categoryBody(c.body, true)).eq("org_id", orgId)
          .eq("id", idParam(c, d, "id", "category")).select(CATEGORY_COLS).maybeSingle(), d, "category"),
      };
    case "delete-finance-category": {
      const cid = idParam(c, d, "id", "category");
      const cat = await one(sb.from("exos_finance_categories").select("id, system").eq("org_id", orgId).eq("id", cid).maybeSingle(), d, "category");
      if (cat.system) throw d.conflict("A built-in category can be renamed and coded, not deleted.");
      await one(sb.from("exos_finance_categories").delete().eq("org_id", orgId).eq("id", cid).select("id").maybeSingle(), d, "category");
      return { data: { id: cid, deleted: true } };
    }
    case "list-gl-codes": {
      let q = sb.from("exos_gl_codes").select(GL_COLS).eq("org_id", orgId);
      if (c.q.get("include_discarded") !== "true") q = q.is("discarded_at", null);
      return { data: await many(q.order("code").order("id")) };
    }
    case "create-gl-code":
      return d.created({ data: await one(sb.from("exos_gl_codes").insert({ ...glCodeBody(c.body, false), org_id: orgId }).select(GL_COLS).single(), d, "code") });
    case "get-gl-code":
      return { data: await one(sb.from("exos_gl_codes").select(GL_COLS).eq("org_id", orgId).eq("id", idParam(c, d, "id", "code")).maybeSingle(), d, "ledger code") };
    case "update-gl-code":
      return {
        data: await one(sb.from("exos_gl_codes").update(glCodeBody(c.body, true)).eq("org_id", orgId).is("discarded_at", null)
          .eq("id", idParam(c, d, "id", "code")).select(GL_COLS).maybeSingle(), d, "ledger code"),
      };
    case "delete-gl-code": {
      const gid = idParam(c, d, "id", "code");
      await one(sb.from("exos_gl_codes").update({ discarded_at: new Date().toISOString() }).eq("org_id", orgId)
        .is("discarded_at", null).eq("id", gid).select("id").maybeSingle(), d, "ledger code");
      return { data: { id: gid, discarded: true } };
    }

    // ---- Finance items ----------------------------------------------------------------------------
    case "list-finance-items": {
      const ev = await ownEvent(c, d);
      return { data: await many(sb.from("exos_finance_items").select(ITEM_COLS).eq("org_id", orgId).eq("event_id", ev).order("created_at")) };
    }
    case "create-finance-item": {
      const ev = await ownEvent(c, d);
      return d.created({
        data: await one(sb.from("exos_finance_items").insert({ ...financeItemBody(c.body, false), event_id: ev, org_id: orgId })
          .select(ITEM_COLS).single(), d, "item"),
      });
    }
    case "get-finance-item":
      return { data: await one(sb.from("exos_finance_items").select(ITEM_COLS).eq("org_id", orgId).eq("id", idParam(c, d, "id", "item")).maybeSingle(), d, "finance item") };
    case "update-finance-item":
      return {
        data: await one(sb.from("exos_finance_items").update(financeItemBody(c.body, true)).eq("org_id", orgId)
          .eq("id", idParam(c, d, "id", "item")).select(ITEM_COLS).maybeSingle(), d, "finance item"),
      };
    case "delete-finance-item": {
      const iid = idParam(c, d, "id", "item");
      await one(sb.from("exos_finance_items").delete().eq("org_id", orgId).eq("id", iid).select("id").maybeSingle(), d, "finance item");
      return { data: { id: iid, deleted: true } };
    }

    // ---- Settlement -------------------------------------------------------------------------------
    case "get-settlement":
      return { data: settlementView(await d.rpc(sb, "_exos_settlement_get", { p_org: orgId, p_event: idParam(c, d, "id", "event") })) };
    case "update-settlement": {
      const { patch, revision } = settlementPatch(c.body);
      return {
        data: settlementView(await d.rpc(sb, "_exos_settlement_update", {
          p_org: orgId, p_actor: null, p_event: idParam(c, d, "id", "event"), p: patch, p_revision: revision,
        })),
      };
    }
    case "finalize-settlement": {
      const b = unwrapBody(c.body);
      if (b.revision !== undefined && (typeof b.revision !== "number" || !Number.isInteger(b.revision))) throw new BodyError("revision must be a whole number.");
      return {
        data: settlementView(await d.rpc(sb, "_exos_settlement_finalize", {
          p_org: orgId, p_actor: null, p_event: idParam(c, d, "id", "event"), p_revision: b.revision ?? null,
        })),
      };
    }
    case "reopen-settlement":
      return { data: settlementView(await d.rpc(sb, "_exos_settlement_reopen", { p_org: orgId, p_actor: null, p_event: idParam(c, d, "id", "event") })) };
    case "get-settlement-pdf": {
      const s = await d.rpc(sb, "_exos_settlement_get", { p_org: orgId, p_event: idParam(c, d, "id", "event") });
      const { data: org } = await sb.from("exos_orgs").select("name").eq("id", orgId).maybeSingle();
      return pdfResponse(settlementPdf(s.inputs as SettlementInputs, {
        orgName: org?.name, includePromoterNet: c.q.get("for") !== "contacts", finalizedAt: s.finalized_at,
      }), `settlement-${s.inputs?.event?.name ?? "show"}`);
    }

    // ---- Profit and loss ---------------------------------------------------------------------------
    case "get-event-pnl": {
      const ev = await ownEvent(c, d);
      const { inputs, finalized } = await showInputs(c, d, ev);
      const p = showPnl(inputs);
      if (c.q.get("format") === "csv") return csvResponse(showPnlCsv(p), `profit-and-loss-${ev}`);
      return { data: { event_id: ev, finalized, ...p } };
    }
    case "get-org-pnl": {
      const { from, to } = pnlRange(c.q, new Date().toISOString().slice(0, 10));
      const raw = await d.rpc(sb, "_exos_pnl_inputs", { p_org: orgId, p_from: from, p_to: to });
      const p = orgPnl(raw.shows ?? []);
      if (c.q.get("format") === "csv") return csvResponse(orgPnlCsv(p), `profit-and-loss-${from}-${to}`);
      return { data: { from, to, truncated: raw.truncated === true, ...p } };
    }

    // ---- Ticket counts ---------------------------------------------------------------------------------
    case "get-ticket-counts":
      return { data: await d.rpc(sb, "_exos_tc_get", { p_org: orgId, p_event: idParam(c, d, "id", "event") }) };
    case "update-ticket-counts":
      return { data: await d.rpc(sb, "_exos_tc_save", { p_org: orgId, p_event: idParam(c, d, "id", "event"), p: ticketCountsBody(c.body) }) };
    case "send-ticket-counts":
      return { data: await d.rpc(sb, "_exos_tc_send_now", { p_org: orgId, p_event: idParam(c, d, "id", "event") }) };
  }
  return undefined;
}
