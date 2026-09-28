// exos-pos — venue POS placeholder (Phase 3 scaffold, docs/pos.md).
//
// READ-ONLY scaffolding. No money moves here: Stripe Terminal is not wired,
// every payment action answers 501, and no card data is ever accepted or
// stored (the reader handles the card; Exos will only see an opaque
// PaymentIntent id, later).
//
// Auth: the caller's Supabase JWT (auth.getUser). Every read goes through a
// client carrying that JWT, so row-level security and the SQL role checks
// (mig 20260929074000) decide what the caller sees:
//   catalog              door staff of the event (exos_pos_can_ring: owner /
//                        manager, or a scanner org-wide or assigned to it)
//   settlement_preview   owner / manager / finance (exos_pos_settlement_summary)
// No service-role key is used.
//
// Actions (POST JSON):
//   { action: "catalog", event_id }
//     -> { event_id, items: [{ id, category, name, sku, price_cents, all_in_cents,
//          tax: { rate_percent, price_includes_tax } | null, active, is_86d,
//          inventory_count }] }  (the event's items plus the org-wide ones)
//   { action: "settlement_preview", event_id }
//     -> { preview: true, summary }  (exos_pos_settlement_summary; nothing recorded)
//   { action: "charge" | "collect_payment" | "card_payment" | "capture" |
//     "refund" | "preauth_tab" | "close_tab_payment" | "mint_walkup", ... }
//     -> 501 { error: "not_implemented", message }
//
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY. Deploy with JWT verification
// ON. Deploying is operator-gated like every function (CLAUDE.md).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { lineTotals, type PosCategory, PaymentsNotWiredError } from "../_shared/pos/index.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const PAYMENT_ACTIONS = new Set([
  "charge", "collect_payment", "card_payment", "capture", "refund",
  "preauth_tab", "close_tab_payment", "mint_walkup",
]);

type ItemRow = {
  id: string;
  category: PosCategory;
  name: string;
  sku: string | null;
  price_cents: number;
  active: boolean;
  is_86d: boolean;
  inventory_count: number | null;
  sort_order: number;
  exos_tax_rules: { rate_percent: number; price_includes_tax: boolean } | null;
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anon) return json({ error: "not configured" }, 503);
  const sb = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  // deno-lint-ignore no-explicit-any
  let p: any;
  try { p = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  if (!p || typeof p !== "object" || typeof p.action !== "string") return json({ error: "missing action" }, 400);

  if (PAYMENT_ACTIONS.has(p.action)) {
    return json({
      error: "not_implemented",
      message: new PaymentsNotWiredError(p.action).message +
        ". Cash and comp tenders are recorded through the database (RLS); card payments and walk-up ticket mints wait for the terminal integration.",
    }, 501);
  }

  const eventId = typeof p.event_id === "string" ? p.event_id : "";
  if (!UUID_RE.test(eventId)) return json({ error: "missing or bad event_id" }, 400);

  if (p.action === "catalog") {
    const { data: canRing, error: roleErr } = await sb.rpc("exos_pos_can_ring", { p_event_id: eventId });
    if (roleErr) return json({ error: "role check failed" }, 500);
    if (canRing !== true) return json({ error: "forbidden" }, 403);

    const { data: ev } = await sb.from("exos_events").select("org_id").eq("id", eventId).maybeSingle();
    const orgId = (ev as { org_id?: string } | null)?.org_id;
    if (!orgId) return json({ error: "event not found" }, 404);

    const { data, error } = await sb
      .from("exos_pos_items")
      .select("id, category, name, sku, price_cents, active, is_86d, inventory_count, sort_order, exos_tax_rules(rate_percent, price_includes_tax)")
      .eq("org_id", orgId)
      .or(`event_id.eq.${eventId},event_id.is.null`)
      .order("category")
      .order("sort_order")
      .order("name");
    if (error) return json({ error: "catalog read failed" }, 500);

    const items = ((data ?? []) as unknown as ItemRow[]).map((i) => {
      const tax = i.exos_tax_rules
        ? { rate_percent: Number(i.exos_tax_rules.rate_percent), price_includes_tax: i.exos_tax_rules.price_includes_tax === true }
        : null;
      const all_in_cents = lineTotals({
        category: i.category,
        unitPriceCents: i.price_cents,
        quantity: 1,
        tax: tax ? { ratePercent: tax.rate_percent, priceIncludesTax: tax.price_includes_tax } : null,
      }).totalCents;
      return {
        id: i.id, category: i.category, name: i.name, sku: i.sku, price_cents: i.price_cents, all_in_cents, tax,
        active: i.active, is_86d: i.is_86d, inventory_count: i.inventory_count,
      };
    });
    return json({ event_id: eventId, items });
  }

  if (p.action === "settlement_preview") {
    const { data, error } = await sb.rpc("exos_pos_settlement_summary", { p_event_id: eventId });
    if (error) {
      return error.code === "42501" ? json({ error: "forbidden" }, 403) : json({ error: "settlement read failed" }, 500);
    }
    return json({ preview: true, summary: data });
  }

  return json({ error: "unknown action" }, 400);
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
