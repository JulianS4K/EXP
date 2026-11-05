// exos-api: organization routes the Opendate gap list still pointed at the
// dashboard (claude/exos-fan-api, mig 20261105110000; _shared/api/gapWrites.ts):
//
//   GET / POST /api-keys, DELETE /api-keys/:id          (org:admin; owner keys)
//   POST /series, PATCH / DELETE /series/:id, POST /series/:id/cancel,
//     /series/:id/events, /series/:id/generate, /series/:id/cancel-date,
//     DELETE /series/:id/events/:eid                     (events:write)
//   POST /events/:id/fee-rules, PATCH / DELETE /events/:id/fee-rules/:rid
//   POST /events/:id/seat-reconciliation/release-orphans, POST
//     /migrated-attendees/bulk                           (tickets:write)
//   POST /membership-scans                               (checkin:write)
//   POST /membership-products/:id/gifts, DELETE /memberships/:id/gift, POST
//     /memberships/:id/cancel, GET /gift-card-products/:id/quote, POST
//     /gift-card-products/:id/gift-card-orders, POST
//     /giving-campaigns/:id/offline-donations, POST /donations  (commerce:*)
//
// Writes need an org API key (sk_live_…) whose creator holds the action's
// dashboard role now (actor(), _exos_api_key_actor, as the sibling routes),
// and the key's scopes as narrowed now (mig 20261104180000). Each is then
// one exos_api_gap_write call, which checks both again (POST
// /memberships/:id/cancel is exos_api_commerce_write's membership.update
// with status cancelled). No business rule lives in this file. A gift
// card's code is never returned: it is emailed to the recipient (or
// purchaser). A new API key's plaintext is returned once.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import {
  CANCEL_MEMBERSHIP_ROLES, GAP_ACTION_ROLES, GAP_ACTIONS, GAP_CREATED, GapBodyError, gapArgs, gapTarget, giftCardQuote,
} from "../_shared/api/gapWrites.ts";
import { Answer, CoreError } from "./core.ts";

export const GAP_ROUTES = new Set([...Object.keys(GAP_ACTIONS), "list-api-keys", "quote-gift-card-product", "cancel-membership"]);

export interface GapCtx {
  sb: SupabaseClient;
  orgId: string;
  keyId: string;
  credKind: "api_key" | "pat" | "oauth";
  params: Record<string, string>;
  q: URLSearchParams;
  body: Record<string, unknown>;
  idempotencyKey: string | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The acting member: the API key's creator holding one of `roles` now (SQL checks it). */
async function actor(c: GapCtx, roles: readonly string[]): Promise<string> {
  if (c.credKind !== "api_key") throw new CoreError(403, "this write needs an organization API key (sk_live_…)");
  const { data, error } = await c.sb.rpc("_exos_api_key_actor", { p_org: c.orgId, p_api_key: c.keyId, p_roles: roles });
  if (error) throw error;
  return data as string;
}

export async function handleGapWrites(route: ApiRoute, c: GapCtx): Promise<unknown> {
  switch (route.id) {
    case "list-api-keys": {
      // Never the hash: prefix, scopes and dates only.
      const { data, error } = await c.sb.from("exos_api_keys")
        .select("id, name, key_prefix, scopes, last_used_at, revoked_at, created_at")
        .eq("org_id", c.orgId).order("created_at", { ascending: false }).order("id");
      if (error) throw error;
      return { data: data ?? [] };
    }
    case "quote-gift-card-product": {
      const id = c.params.id;
      if (!id || !UUID_RE.test(id)) throw new CoreError(404, "gift card product not found");
      const { data, error } = await c.sb.from("exos_gift_card_products")
        .select("id, currency, amount_type, amounts_cents, min_cents, max_cents, active")
        .eq("org_id", c.orgId).eq("id", id).maybeSingle();
      if (error) throw error;
      if (!data) throw new CoreError(404, "gift card product not found");
      const q = giftCardQuote(data, c.q.get("amount_cents"));
      if ("error" in q) throw new CoreError(400, q.error);
      return { data: q };
    }
    case "cancel-membership": {
      const id = c.params.id;
      if (!id || !UUID_RE.test(id)) throw new CoreError(404, "membership not found");
      await actor(c, CANCEL_MEMBERSHIP_ROLES);
      const { data, error } = await c.sb.rpc("exos_api_commerce_write", {
        p_key_id: c.keyId, p_action: "membership.update", p_target: id, p_args: { status: "cancelled" },
        p_idempotency_key: c.idempotencyKey,
      });
      if (error) throw error;
      return { data };
    }
  }
  const spec = GAP_ACTIONS[route.id];
  if (!spec) throw new CoreError(404, "not found");
  let args: Record<string, unknown>;
  try {
    args = gapArgs(route.id, c.body, c.params);
  } catch (e) {
    if (e instanceof GapBodyError) throw new CoreError(400, e.message);
    throw e;
  }
  const target = gapTarget(route.id, c.params, args);
  if (spec.target && (!target || !UUID_RE.test(target))) throw new CoreError(404, "not found");
  await actor(c, GAP_ACTION_ROLES[spec.action] ?? ["owner"]);
  const { data, error } = await c.sb.rpc("exos_api_gap_write", {
    p_key_id: c.keyId, p_action: spec.action, p_target: target, p_args: args, p_idempotency_key: c.idempotencyKey,
  });
  if (error) throw error;
  return GAP_CREATED.has(route.id) ? new Answer(201, { data }) : { data };
}
