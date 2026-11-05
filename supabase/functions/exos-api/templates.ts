// exos-api: event templates, note templates, rental invoice templates and
// rental invoices, inbound booking submissions, and deleting a draft event
// (mig 20261102130000, docs/templates-inbound.md). Dispatched from index.ts
// by route id, after the finance routes.
//
// The function runs with the service role, so every query names the key's
// org (c.orgId) and every SQL core takes it as p_org: an id of another org is
// a 404. Templates are plain rows whose triggers validate them; rental
// invoices (numbering, totals, freezing), submissions (review, holds) and
// event deletion go through the _exos_* cores. Making an event (from a
// template) and deleting one also need the key's creator to be an owner or
// manager now, as in the dashboard.

import type { FinCtx, FinDeps } from "./finance.ts";
import { BodyError, isUuid } from "../_shared/api/booking.ts";
import {
  eventFromTemplateBody, eventTemplateBody, inboundBody, inboundPatch, INBOUND_STATUSES, noteTemplateBody,
  rentalInvoiceBody, rentalTemplateBody,
} from "../_shared/api/templates.ts";
import { unwrapBody } from "../_shared/api/finance.ts";

const EVENT_TPL_COLS =
  "id, name, status, event_name, description, capacity, doors_offset_minutes, duration_minutes, event_fields, tiers, " +
  "fee_rules, inherit_org_fees, use_count, last_used_at, created_at, updated_at";
const NOTE_TPL_COLS = "id, title, body, status, created_at, updated_at";
const NOTE_COLS = "id, event_id, body, author_id, author_name, created_at, updated_at";
const RENTAL_TPL_COLS =
  "id, title, status, currency, payee_name, notes, terms, attendance_count, discount_cents, items, deposits, tax_fees, " +
  "created_at, updated_at";
const RENTAL_COLS =
  "id, template_id, status, number, number_seq, title, currency, payee_name, bill_to_name, bill_to_email, notes, terms, " +
  "attendance_count, discount_cents, items, deposits, tax_fees, subtotal_cents, tax_cents, total_cents, deposits_cents, " +
  "hold_id, hold_position_id, venue_id, room_id, rental_date, event_id, due_on, issued_at, paid_at, voided_at, " +
  "void_reason, created_via, created_at, updated_at";
// Never the network hash, user agent or key id.
const INBOUND_COLS =
  "id, status, source, artist_name, contact_name, contact_role, email, phone, company, message, links, genres, " +
  "venue_id, preferred_dates, dates_flexible, expected_draw, hold_id, staff_note, reviewed_by, reviewed_at, " +
  "created_at, updated_at";
const TEMPLATE_STATUSES = new Set(["active", "archived"]);
const RENTAL_STATUSES = new Set(["draft", "issued", "paid", "void"]);

/** The route ids this module answers. */
export const TEMPLATE_ROUTES = new Set([
  "list-event-templates", "create-event-template", "get-event-template", "update-event-template",
  "delete-event-template", "create-event-from-template",
  "list-note-templates", "create-note-template", "get-note-template", "update-note-template", "delete-note-template",
  "apply-note-template",
  "list-rental-invoice-templates", "create-rental-invoice-template", "get-rental-invoice-template",
  "update-rental-invoice-template", "delete-rental-invoice-template",
  "list-rental-invoices", "create-rental-invoice", "get-rental-invoice", "update-rental-invoice",
  "delete-rental-invoice", "issue-rental-invoice", "pay-rental-invoice", "void-rental-invoice",
  "list-inbound-submissions", "create-inbound-submission", "get-inbound-submission", "update-inbound-submission",
  "delete-inbound-submission", "create-inbound-submission-hold",
  "delete-event",
]);

function idParam(c: FinCtx, d: TemplateDeps, what: string, name = "id"): string {
  const v = c.params[name];
  if (!isUuid(v)) throw d.notFound(what);
  return v;
}

// deno-lint-ignore no-explicit-any
async function one(p: PromiseLike<{ data: any; error: unknown }>, d: TemplateDeps, what: string): Promise<any> {
  const { data, error } = await p;
  if (error) throw error;
  if (!data) throw d.notFound(what);
  return data;
}

/** ?status= checked against a set (null: no filter). */
function statusFilter(c: FinCtx, allowed: Set<string> | readonly string[]): string | null {
  const s = c.q.get("status");
  if (s === null || s === "" || s === "all") return null;
  const ok = allowed instanceof Set ? allowed.has(s) : allowed.includes(s);
  if (!ok) throw new BodyError(`status must be one of ${[...allowed].join(", ")} (or all).`);
  return s;
}

function uuidFilter(c: FinCtx, name: string): string | null {
  const v = c.q.get(name);
  if (v === null || v === "") return null;
  if (!isUuid(v)) throw new BodyError(`${name} must be a UUID.`);
  return v;
}

/** The key's creator, who must be an owner or manager of the org now (events are theirs to make or delete). */
async function staffActor(c: FinCtx, d: TemplateDeps): Promise<string> {
  const { data: k, error } = await c.sb.from("exos_api_keys").select("created_by").eq("id", c.key.id).maybeSingle();
  if (error) throw error;
  const uid = k?.created_by as string | null | undefined;
  if (uid) {
    const { data: m, error: mErr } = await c.sb.from("exos_org_memberships").select("role, disabled")
      .eq("org_id", c.orgId).eq("user_id", uid).maybeSingle();
    if (mErr) throw mErr;
    if (m && m.disabled !== true && (m.role === "owner" || m.role === "manager")) return uid;
  }
  throw d.forbidden("only a key created by an owner or manager can make or delete events");
}

export interface TemplateDeps extends FinDeps {
  forbidden: (msg: string) => Error;
}

/** Handles one of this module's routes; undefined = not ours. */
export async function handleTemplates(id: string, c: FinCtx, d: TemplateDeps): Promise<unknown> {
  if (!TEMPLATE_ROUTES.has(id)) return undefined;
  const { sb, orgId, page } = c;
  switch (id) {
    // ---- Event templates --------------------------------------------------------
    case "list-event-templates": {
      let q = sb.from("exos_event_templates").select(EVENT_TPL_COLS, { count: "exact" }).eq("org_id", orgId);
      const s = statusFilter(c, TEMPLATE_STATUSES);
      if (s) q = q.eq("status", s);
      return d.paged(await q.order("name").order("id").range(page.from, page.to), page);
    }
    case "create-event-template": {
      const { row, fromEventId } = eventTemplateBody(c.body, false);
      if (fromEventId) {
        await one(sb.from("exos_events").select("id").eq("org_id", orgId).eq("id", fromEventId).maybeSingle(), d, "event");
        const tid = await d.rpc(sb, "_exos_event_template_from_event",
          { p_org: orgId, p_actor: null, p_event: fromEventId, p_name: (row.name as string | undefined) ?? null });
        return d.created({ data: await one(sb.from("exos_event_templates").select(EVENT_TPL_COLS).eq("id", tid).maybeSingle(), d, "template") });
      }
      return d.created({
        data: await one(sb.from("exos_event_templates").insert({ ...row, org_id: orgId }).select(EVENT_TPL_COLS).single(), d, "template"),
      });
    }
    case "get-event-template":
      return {
        data: await one(sb.from("exos_event_templates").select(EVENT_TPL_COLS).eq("org_id", orgId)
          .eq("id", idParam(c, d, "template")).maybeSingle(), d, "template"),
      };
    case "update-event-template":
      return {
        data: await one(sb.from("exos_event_templates").update(eventTemplateBody(c.body, true).row).eq("org_id", orgId)
          .eq("id", idParam(c, d, "template")).select(EVENT_TPL_COLS).maybeSingle(), d, "template"),
      };
    case "delete-event-template": {
      const tid = idParam(c, d, "template");
      await one(sb.from("exos_event_templates").delete().eq("org_id", orgId).eq("id", tid).select("id").maybeSingle(), d, "template");
      return { data: { id: tid, deleted: true } };
    }
    case "create-event-from-template": {
      const tid = idParam(c, d, "template");
      const args = eventFromTemplateBody(c.body);
      const actor = await staffActor(c, d);
      return d.created({
        data: await d.rpc(sb, "_exos_event_from_template", { p_org: orgId, p_actor: actor, p_template: tid, p_args: args }),
      });
    }

    // ---- Note templates -------------------------------------------------------------
    case "list-note-templates": {
      let q = sb.from("exos_note_templates").select(NOTE_TPL_COLS, { count: "exact" }).eq("org_id", orgId);
      const s = statusFilter(c, TEMPLATE_STATUSES);
      if (s) q = q.eq("status", s);
      return d.paged(await q.order("title").order("id").range(page.from, page.to), page);
    }
    case "create-note-template":
      return d.created({
        data: await one(sb.from("exos_note_templates").insert({ ...noteTemplateBody(c.body, false), org_id: orgId })
          .select(NOTE_TPL_COLS).single(), d, "template"),
      });
    case "get-note-template":
      return {
        data: await one(sb.from("exos_note_templates").select(NOTE_TPL_COLS).eq("org_id", orgId)
          .eq("id", idParam(c, d, "template")).maybeSingle(), d, "template"),
      };
    case "update-note-template":
      return {
        data: await one(sb.from("exos_note_templates").update(noteTemplateBody(c.body, true)).eq("org_id", orgId)
          .eq("id", idParam(c, d, "template")).select(NOTE_TPL_COLS).maybeSingle(), d, "template"),
      };
    case "delete-note-template": {
      const tid = idParam(c, d, "template");
      await one(sb.from("exos_note_templates").delete().eq("org_id", orgId).eq("id", tid).select("id").maybeSingle(), d, "template");
      return { data: { id: tid, deleted: true } };
    }
    case "apply-note-template": {
      const t = await one(sb.from("exos_note_templates").select("id, body, status").eq("org_id", orgId)
        .eq("id", idParam(c, d, "template")).maybeSingle(), d, "template");
      const b = unwrapBody(c.body);
      const eventId = b.event_id ?? b.calendar_event_id;
      if (!isUuid(eventId)) throw new BodyError("event_id is required (a UUID).");
      await one(sb.from("exos_events").select("id").eq("org_id", orgId).eq("id", eventId).maybeSingle(), d, "event");
      return d.created({
        data: await one(sb.from("exos_event_notes").insert({ event_id: eventId, org_id: orgId, body: t.body })
          .select(NOTE_COLS).single(), d, "note"),
      });
    }

    // ---- Rental invoice templates ------------------------------------------------------
    case "list-rental-invoice-templates": {
      let q = sb.from("exos_rental_invoice_templates").select(RENTAL_TPL_COLS, { count: "exact" }).eq("org_id", orgId);
      const s = statusFilter(c, TEMPLATE_STATUSES);
      if (s) q = q.eq("status", s);
      return d.paged(await q.order("title").order("id").range(page.from, page.to), page);
    }
    case "create-rental-invoice-template":
      return d.created({
        data: await one(sb.from("exos_rental_invoice_templates").insert({ ...rentalTemplateBody(c.body, false), org_id: orgId })
          .select(RENTAL_TPL_COLS).single(), d, "template"),
      });
    case "get-rental-invoice-template":
      return {
        data: await one(sb.from("exos_rental_invoice_templates").select(RENTAL_TPL_COLS).eq("org_id", orgId)
          .eq("id", idParam(c, d, "template")).maybeSingle(), d, "template"),
      };
    case "update-rental-invoice-template":
      return {
        data: await one(sb.from("exos_rental_invoice_templates").update(rentalTemplateBody(c.body, true)).eq("org_id", orgId)
          .eq("id", idParam(c, d, "template")).select(RENTAL_TPL_COLS).maybeSingle(), d, "template"),
      };
    case "delete-rental-invoice-template": {
      const tid = idParam(c, d, "template");
      await one(sb.from("exos_rental_invoice_templates").delete().eq("org_id", orgId).eq("id", tid).select("id").maybeSingle(), d, "template");
      return { data: { id: tid, deleted: true } };
    }

    // ---- Rental invoices -------------------------------------------------------------------
    case "list-rental-invoices": {
      let q = sb.from("exos_rental_invoices").select(RENTAL_COLS, { count: "exact" }).eq("org_id", orgId);
      const s = statusFilter(c, RENTAL_STATUSES);
      if (s) q = q.eq("status", s);
      const hold = uuidFilter(c, "hold_id");
      if (hold) q = q.eq("hold_id", hold);
      const ev = uuidFilter(c, "event_id");
      if (ev) q = q.eq("event_id", ev);
      return d.paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }
    case "create-rental-invoice":
      return d.created({
        data: await d.rpc(sb, "_exos_rental_invoice_create",
          { p_org: orgId, p_actor: null, p_via: "api", p: rentalInvoiceBody(c.body, false) }),
      });
    case "get-rental-invoice":
      return {
        data: await one(sb.from("exos_rental_invoices").select(RENTAL_COLS).eq("org_id", orgId)
          .eq("id", idParam(c, d, "rental invoice")).maybeSingle(), d, "rental invoice"),
      };
    case "update-rental-invoice":
      return {
        data: await d.rpc(sb, "_exos_rental_invoice_update",
          { p_org: orgId, p_id: idParam(c, d, "rental invoice"), p: rentalInvoiceBody(c.body, true) }),
      };
    case "delete-rental-invoice":
      return { data: await d.rpc(sb, "_exos_rental_invoice_delete", { p_org: orgId, p_id: idParam(c, d, "rental invoice") }) };
    case "issue-rental-invoice": {
      const b = unwrapBody(c.body);
      const due = b.due_on ?? null;
      if (due !== null && (typeof due !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(due))) throw new BodyError("due_on must be a date (YYYY-MM-DD).");
      return { data: await d.rpc(sb, "_exos_rental_invoice_issue", { p_org: orgId, p_id: idParam(c, d, "rental invoice"), p_due_on: due }) };
    }
    case "pay-rental-invoice":
    case "void-rental-invoice": {
      const b = unwrapBody(c.body);
      const reason = b.reason ?? null;
      if (reason !== null && (typeof reason !== "string" || reason.length > 500)) throw new BodyError("reason must be at most 500 characters.");
      return {
        data: await d.rpc(sb, "_exos_rental_invoice_set_status", {
          p_org: orgId, p_id: idParam(c, d, "rental invoice"), p_status: id === "pay-rental-invoice" ? "paid" : "void", p_reason: reason,
        }),
      };
    }

    // ---- Inbound submissions ------------------------------------------------------------------
    case "list-inbound-submissions": {
      let q = sb.from("exos_inbound_submissions").select(INBOUND_COLS, { count: "exact" }).eq("org_id", orgId);
      const s = statusFilter(c, INBOUND_STATUSES);
      if (s) q = q.eq("status", s);
      const venue = uuidFilter(c, "venue_id");
      if (venue) q = q.eq("venue_id", venue);
      const sort = c.q.get("q[s]") ?? c.q.get("sort");
      const asc = sort === "created_at asc";
      if (sort !== null && sort !== "created_at asc" && sort !== "created_at desc") {
        throw new BodyError("sort must be created_at desc or created_at asc.");
      }
      return d.paged(await q.order("created_at", { ascending: asc }).order("id").range(page.from, page.to), page);
    }
    case "create-inbound-submission": {
      const body = inboundBody(c.body);
      delete body.homepage;
      const sid = await d.rpc(sb, "_exos_inbound_create",
        { p_org: orgId, p_source: "api", p: body, p_ip_hash: null, p_ua: null, p_api_key: c.key.id });
      return d.created({ data: await one(sb.from("exos_inbound_submissions").select(INBOUND_COLS).eq("id", sid).maybeSingle(), d, "submission") });
    }
    case "get-inbound-submission":
      return {
        data: await one(sb.from("exos_inbound_submissions").select(INBOUND_COLS).eq("org_id", orgId)
          .eq("id", idParam(c, d, "submission")).maybeSingle(), d, "submission"),
      };
    case "update-inbound-submission": {
      const p = inboundPatch(c.body);
      await d.rpc(sb, "_exos_inbound_set_status",
        { p_org: orgId, p_actor: null, p_id: idParam(c, d, "submission"), p_status: p.status, p_note: p.staff_note });
      return {
        data: await one(sb.from("exos_inbound_submissions").select(INBOUND_COLS).eq("org_id", orgId)
          .eq("id", c.params.id).maybeSingle(), d, "submission"),
      };
    }
    case "delete-inbound-submission": {
      const sid = idParam(c, d, "submission");
      await one(sb.from("exos_inbound_submissions").delete().eq("org_id", orgId).eq("id", sid).select("id").maybeSingle(), d, "submission");
      return { data: { id: sid, deleted: true } };
    }
    case "create-inbound-submission-hold":
      return d.created({
        data: await d.rpc(sb, "_exos_inbound_hold", {
          p_org: orgId, p_actor: null, p_via: "api", p_api_key: c.key.id, p_id: idParam(c, d, "submission"),
          p: unwrapBody(c.body, "hold"),
        }),
      });

    // ---- Events --------------------------------------------------------------------------------
    case "delete-event": {
      const ev = idParam(c, d, "event");
      await staffActor(c, d);
      return { data: await d.rpc(sb, "_exos_event_delete", { p_org: orgId, p_event: ev }) };
    }
  }
  return undefined;
}
