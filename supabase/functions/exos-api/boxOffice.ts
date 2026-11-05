// exos-api — the box office: printed tickets, membership reservations, staff
// shifts, and moving a tag assignment (mig 20261105120000,
// docs/api/box-office.json). Opendate's paths are aliases (routes.ts).
//
// Printing (docs/wallet.md "Printed tickets"): POST /tickets/:id/print and
// POST /orders/:id/print mint one-time print codes through _exos_api_print
// (tickets:write, a key whose creator is an owner or manager now) and answer
// them as JSON, a printable HTML page (?format=html) or a PDF (?format=pdf),
// never cached. A print is never replayed from an Idempotency-Key: the codes
// are in this answer only, and printing again voids the last paper.
//
// Membership reservations: _exos_api_membership_box_office (commerce:write,
// an owner / manager key). Staff shifts: clock in / out act as the token's
// user, so they need a personal or OAuth token (an org API key is not a
// person); the hours report needs an owner or manager (the key's creator, or
// the token's user). Retagging: _exos_tagged_item_retag with the key's org (a
// fan's tag also needs fans:write).
//
// No business rule lives here: it shapes requests and answers only.

import type { ApiRoute } from "../_shared/api/routes.ts";
import { hasScope } from "../_shared/api/scopes.ts";
import {
  BoxError, capacityBody, clockBody, printTicketId, reservationFields, retagBody, shiftWindow,
} from "../_shared/api/boxOffice.ts";
import { printFormat, printHtml, printPdf, type PrintTicket } from "../_shared/print/tickets.ts";
import { Answer, CoreError, type CoreCtx, sqlError } from "./core.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_RE = /^[A-Za-z0-9_-]{1,255}$/;
const TOKEN_RE = /^mbr_[A-Za-z0-9_-]{43}$/;

/** The route ids this module answers. */
export const BOX_OFFICE_ROUTES = new Set([
  "print-ticket", "void-ticket-print", "print-order", "get-membership-capacity", "set-membership-capacity",
  "create-membership-reservation", "cancel-membership-reservation", "complete-membership-reservation",
  "list-staff-shifts", "clock-in", "clock-out", "update-tagged-item",
]);

/** Writes a personal or OAuth token makes as its user (userTokenMayCall otherwise needs an org API key). */
export const USER_TOKEN_WRITES = new Set(["clock-in", "clock-out"]);

export interface BoxCtx extends CoreCtx {
  credKind: "api_key" | "pat" | "oauth";
  userId: string | null;
  role: string | null;
  scopes: readonly string[];
}

export async function handleBoxOffice(route: ApiRoute, c: BoxCtx): Promise<unknown> {
  const p = c.params;
  try {
    switch (route.id) {
      case "print-ticket":
      case "print-order": {
        const format = printFormat(c.q.get("format"));
        if (!format) throw new CoreError(400, "format must be json, html or pdf.");
        const target = route.id === "print-ticket" ? printTicketId(p.id) : (SESSION_RE.test(p.id ?? "") ? p.id : null);
        if (!target) throw new CoreError(404, route.id === "print-ticket" ? "ticket not found" : "order not found");
        const out = await rpc(c, "_exos_api_print", {
          p_org: c.orgId, p_api_key: c.keyId, p_kind: route.id === "print-ticket" ? "ticket" : "order",
          p_target: target, p_event: eventParam(p.eid),
        }) as { tickets: PrintTicket[]; skipped: unknown[] };
        return printAnswer(format, out, route.id === "print-ticket" ? `ticket-${target.slice(0, 8)}` : `order-${target.slice(0, 24)}`);
      }
      case "void-ticket-print": {
        const id = printTicketId(p.id);
        if (!id) throw new CoreError(404, "ticket not found");
        return { data: await rpc(c, "_exos_api_print", { p_org: c.orgId, p_api_key: c.keyId, p_kind: "ticket_void", p_target: id, p_event: null }) };
      }

      case "get-membership-capacity":
      case "set-membership-capacity":
      case "create-membership-reservation":
      case "cancel-membership-reservation":
      case "complete-membership-reservation": {
        const product = uuidOr404(p.id, "membership product");
        const action = {
          "get-membership-capacity": "capacity.get", "set-membership-capacity": "capacity.set",
          "create-membership-reservation": "reserve", "cancel-membership-reservation": "cancel",
          "complete-membership-reservation": "complete",
        }[route.id] as string;
        let token: string | null = null;
        if (action === "cancel" || action === "complete") {
          if (!TOKEN_RE.test(p.token ?? "")) throw new CoreError(404, "reservation not found");
          token = p.token;
        }
        const args = action === "reserve" ? reservationFields(c.body) : action === "capacity.set" ? capacityBody(c.body) : null;
        const data = await rpc(c, "_exos_api_membership_box_office", {
          p_org: c.orgId, p_api_key: c.keyId, p_action: action, p_product: product, p_token: token, p_args: args,
        });
        return action === "reserve" ? new Answer(201, { data }) : { data };
      }

      case "list-staff-shifts": {
        await managerOnly(c);
        const w = shiftWindow(c.q);
        return { data: await rpc(c, "_exos_staff_shift_report", { p_org: c.orgId, p_from: w.from, p_to: w.to }) };
      }
      case "clock-in":
      case "clock-out": {
        if (c.credKind === "api_key" || !c.userId) {
          throw new CoreError(403, "clock in and out with your own personal access token or OAuth token: an organization API key is not a person.");
        }
        const b = clockBody(c.body);
        const data = route.id === "clock-in"
          ? await rpc(c, "_exos_staff_clock_in", {
            p_org: c.orgId, p_uid: c.userId, p_event: b.event_id, p_device: b.device_id, p_note: b.note,
          })
          : await rpc(c, "_exos_staff_clock_out", { p_org: c.orgId, p_uid: c.userId, p_note: b.note });
        return route.id === "clock-in" ? new Answer(201, { data }) : { data };
      }

      case "update-tagged-item": {
        const id = uuidOr404(p.id, "tagged item");
        const { data: item, error } = await c.sb.from("exos_tagged_items").select("id, taggable_type")
          .eq("org_id", c.orgId).eq("id", id).maybeSingle();
        if (error) throw error;
        if (!item) throw new CoreError(404, "tagged item not found");
        if (item.taggable_type === "fan" && !hasScope(c.scopes, "fans:write")) {
          throw new CoreError(403, "insufficient scope", { required_scope: "fans:write" });
        }
        const b = retagBody(c.body);
        return {
          data: await rpc(c, "_exos_tagged_item_retag", {
            p_org_id: c.orgId, p_item_id: id, p_tag_id: b.tag_id, p_tag_name: b.tag_name, p_actor: null,
          }),
        };
      }
    }
  } catch (e) {
    if (e instanceof BoxError) throw new CoreError(e.status, e.message);
    if (e instanceof CoreError) throw e;
    const err = e as { code?: string; message?: string } | null;
    if (err?.code === "54000") {
      throw new CoreError(429, String(err.message ?? "too many requests").replace(/^(exos|_exos)_[a-z_]+: /, ""));
    }
    const db = sqlError(e);
    if (db) throw new CoreError(db.status, db.message);
    throw e;
  }
  throw new CoreError(404, "not found");
}

/** The print answer: JSON, or the page / PDF to print. Never cached, never indexed. */
function printAnswer(format: string, out: { tickets: PrintTicket[]; skipped: unknown[] }, name: string): unknown {
  if (format === "json") return new Answer(201, { data: out.tickets, skipped: out.skipped });
  const headers: Record<string, string> = {
    "cache-control": "no-store", "x-content-type-options": "nosniff", "x-robots-tag": "noindex",
    "x-exos-printed": String(out.tickets.length), "x-exos-skipped": String(out.skipped.length),
  };
  if (format === "html") {
    return new Response(printHtml(out.tickets), {
      status: 201,
      headers: {
        ...headers, "content-type": "text/html; charset=utf-8",
        // The page is static: no script, no remote anything.
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; frame-ancestors 'none'",
      },
    });
  }
  return new Response(printPdf(out.tickets) as unknown as BodyInit, {
    status: 201,
    headers: { ...headers, "content-type": "application/pdf", "content-disposition": `inline; filename="${name}.pdf"` },
  });
}

/** The hours report: an owner or manager (the key's creator now, or the token's user). */
async function managerOnly(c: BoxCtx): Promise<void> {
  if (c.credKind === "api_key") {
    await rpc(c, "_exos_api_key_actor", { p_org: c.orgId, p_api_key: c.keyId, p_roles: ["owner", "manager"] });
    return;
  }
  if (c.role !== "owner" && c.role !== "manager") {
    throw new CoreError(403, "only an owner or manager can read the hours report");
  }
}

async function rpc(c: CoreCtx, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await c.sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

/** Opendate's confirm_id in the path: the event the ticket / order must be on. */
function eventParam(v: string | undefined): string | null {
  if (v === undefined) return null;
  if (!UUID_RE.test(v)) throw new CoreError(404, "event not found");
  return v;
}

function uuidOr404(v: string | undefined, what: string): string {
  if (!v || !UUID_RE.test(v)) throw new CoreError(404, `${what} not found`);
  return v;
}
