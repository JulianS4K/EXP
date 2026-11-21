// Luma's shared count for exos-channel-sync (mig 20261019090000): read the
// guest list, apply the counts to Exos (exos_luma_inventory_apply), and set
// each mapped Luma ticket type's capacity to its target. Each ack stores the
// request this pass planned or sent, with ITS steps (mig 20261121100000: the
// plan used to keep an empty list). The database is injected, so the Deno
// tests drive it with a stand-in.
import { capacityUpdate, lumaTicketCounts } from "./luma.ts";
import type { Io, StepRecord } from "./model.ts";

/** The part of a Supabase client this uses. */
export interface LumaInventoryDb {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }>;
  from(table: string): any;
}

export async function lumaInventory(
  sb: LumaInventoryDb, io: Io, steps: StepRecord[], eventId: string, lumaId: string, live: boolean,
): Promise<{ ok: boolean; sent?: number; error?: string }> {
  const readAt = new Date().toISOString();
  const { counts, complete, error } = await lumaTicketCounts(io, lumaId);
  if (!complete) return { ok: false, error };
  const { data: links } = await sb.from("exos_luma_ticket_links")
    .select("luma_ticket_type_id, luma_capacity").eq("event_id", eventId).eq("luma_event_id", lumaId).eq("active", true);
  const current = new Map<string, number | null>(((links ?? []) as any[]).map((l) => [l.luma_ticket_type_id, l.luma_capacity]));
  const rows = [...current.keys()].map((id) => ({ id, sold: counts.get(id) ?? 0 }));
  const { data, error: e2 } = await sb.rpc("exos_luma_inventory_apply", { p_event_id: eventId, p_counts: rows, p_read_at: readAt });
  if (e2) return { ok: false, error: "apply failed" };
  let sent = 0;
  for (const r of (data ?? []) as any[]) {
    if (r.skip_reason) continue;
    const body = capacityUpdate(r.luma_ticket_type_id, r.target_capacity, current.get(r.luma_ticket_type_id) ?? null);
    if (!body) continue;
    const from = steps.length;
    const res = await io.req("POST", "/v1/events/ticket-types/update", body);
    // The steps this request added (planned on a dry run, sent when live).
    const mine = steps.slice(from);
    await sb.rpc("exos_luma_inventory_ack", {
      p_event_id: eventId, p_ticket_type_id: r.luma_ticket_type_id,
      p_plan: { dry_run: !live, path: "/v1/events/ticket-types/update", body, steps: mine },
      p_sent: live, p_capacity: r.target_capacity, p_error: res.ok ? null : `Luma: ${res.error ?? "failed"}`,
    });
    if (live && res.ok) sent++;
  }
  return { ok: true, sent };
}
