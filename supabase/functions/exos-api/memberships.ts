// exos-api — membership-product, membership and imported-attendee writes
// (mig 20261102100000, docs/memberships.md), plus the imported-attendee reads.
//
// Every write is ONE call to exos_api_commerce_write(key, action, target,
// args, idempotency key): the same steps as the core API's exos_api_write
// (the key's org, its scope again, runs as the member who created the key,
// Idempotency-Key replay, logged in exos_api_writes), then the dashboard's
// own RPC, so a write here behaves exactly like the same click in the
// dashboard. No business rule lives in this file.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";
import {
  BodyFieldError, importedAttendeeFields, membershipIssueFields, membershipProductFields, membershipUpdateFields,
  PRODUCT_ACTIONS,
} from "../_shared/api/memberships.ts";
import { Answer, CoreError } from "./core.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const IDEMPOTENCY_RE = /^[A-Za-z0-9_.:-]{8,100}$/;

const IMPORTED_COLS =
  "id, event_id, list_id, guest_name, email, phone, plus_ones, arrived, arrived_at, note, external_code, ticket_label, " +
  "source, external_ref, voided_at, created_at, updated_at, exos_events(name, starts_at)";
// An imported row: another platform's export or sync (mig 20261102100000).
const IMPORTED_FILTER = "source.not.is.null,external_code.not.is.null,external_ref.not.is.null";

export interface MembershipCtx {
  sb: SupabaseClient;
  orgId: string;
  keyId: string;
  params: Record<string, string>;
  q: URLSearchParams;
  page: Page;
  body: Record<string, unknown>;
  idempotencyKey: string | null;
}

/** The route ids this module answers. */
export const MEMBERSHIP_ROUTES = new Set([
  "create-membership-product", "update-membership-product", "publish-membership-product",
  "unpublish-membership-product", "archive-membership-product", "issue-membership", "update-membership",
  "list-migrated-attendees", "get-migrated-attendee", "update-migrated-attendee", "delete-migrated-attendee",
]);

export async function handleMemberships(route: ApiRoute, c: MembershipCtx): Promise<unknown> {
  const p = c.params;
  try {
    switch (route.id) {
      case "create-membership-product":
        return new Answer(201, { data: await write(c, "membership_product.create", null, membershipProductFields(c.body, "create")) });
      case "update-membership-product":
        return { data: await write(c, "membership_product.update", id404(p.id, "membership product"), membershipProductFields(c.body, "update")) };
      case "publish-membership-product":
      case "unpublish-membership-product":
      case "archive-membership-product": {
        const action = PRODUCT_ACTIONS[route.id];
        return { data: await write(c, `membership_product.${action}`, id404(p.id, "membership product"), {}) };
      }
      case "issue-membership": {
        const { fields, idempotencyKey } = membershipIssueFields(c.body);
        if (!c.idempotencyKey && idempotencyKey) {
          if (!IDEMPOTENCY_RE.test(idempotencyKey)) throw new CoreError(400, "idempotency_key must be 8-100 letters, digits, _ . : or -");
          c = { ...c, idempotencyKey };
        }
        return new Answer(201, { data: await write(c, "membership.issue", null, fields) });
      }
      case "update-membership":
        return { data: await write(c, "membership.update", id404(p.id, "membership"), membershipUpdateFields(c.body)) };
      case "list-migrated-attendees": {
        let q = c.sb.from("exos_guest_list_entries").select(IMPORTED_COLS, { count: "exact" })
          .eq("org_id", c.orgId).or(IMPORTED_FILTER);
        const ev = c.q.get("event_id");
        if (ev !== null) q = q.eq("event_id", uuid400(ev, "event_id"));
        const src = c.q.get("source");
        if (src !== null) q = q.ilike("source", src.replace(/[\\%_]/g, (m) => `\\${m}`).slice(0, 40));
        const r = await q.order("created_at", { ascending: false }).order("id").range(c.page.from, c.page.to);
        if (r.error) {
          if (r.error.code === "PGRST103") return pageEnvelope([], c.page, null);
          throw r.error;
        }
        return pageEnvelope((r.data ?? []).map(shapeImported), c.page, r.count);
      }
      case "get-migrated-attendee": {
        const { data, error } = await c.sb.from("exos_guest_list_entries").select(IMPORTED_COLS)
          .eq("org_id", c.orgId).eq("id", id404(p.id, "imported attendee")).or(IMPORTED_FILTER).maybeSingle();
        if (error) throw error;
        if (!data) throw new CoreError(404, "imported attendee not found");
        return { data: shapeImported(data) };
      }
      case "update-migrated-attendee":
        return { data: await write(c, "migrated_attendee.update", id404(p.id, "imported attendee"), importedAttendeeFields(c.body)) };
      case "delete-migrated-attendee":
        return { data: await write(c, "migrated_attendee.delete", id404(p.id, "imported attendee"), {}) };
    }
  } catch (e) {
    if (e instanceof BodyFieldError) throw new CoreError(400, e.message);
    throw e;
  }
  throw new CoreError(404, "not found");
}

async function write(c: MembershipCtx, action: string, target: string | null, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await c.sb.rpc("exos_api_commerce_write", {
    p_key_id: c.keyId, p_action: action, p_target: target, p_args: args, p_idempotency_key: c.idempotencyKey,
  });
  if (error) throw error;
  return data;
}

// deno-lint-ignore no-explicit-any
function shapeImported(r: any): Record<string, unknown> {
  const ev = r.exos_events ?? null;
  return {
    id: r.id, event_id: r.event_id, event_name: ev?.name ?? null, starts_at: ev?.starts_at ?? null, list_id: r.list_id,
    guest_name: r.guest_name, email: r.email, phone: r.phone, plus_ones: r.plus_ones, arrived: r.arrived,
    arrived_at: r.arrived_at, note: r.note, code: r.external_code, ticket_label: r.ticket_label, source: r.source,
    synced: r.external_ref !== null, voided: r.voided_at !== null, created_at: r.created_at, updated_at: r.updated_at,
  };
}

function id404(v: string | undefined, what: string): string {
  if (!v || !UUID_RE.test(v)) throw new CoreError(404, `${what} not found`);
  return v;
}

function uuid400(v: string, name: string): string {
  if (!UUID_RE.test(v)) throw new CoreError(400, `${name} must be a UUID.`);
  return v;
}
