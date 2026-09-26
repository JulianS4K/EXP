// exos-distribute — push Exos primary inventory to distribution channels
// (Automatiq/Lysted -> EVO/SeatGeek/StubHub) (D4 "Toast for tickets" SCAFFOLD).
//
// Two independent passes over exos_distribution_listings:
//
// 1. StubHub event requests (mig 20260926190000). Publishing an event with
//    StubHub ticked queues a 'stubhub' row. This pass builds the StubHub
//    PUT /sellerevents body from the event (_shared/stubhub-event.ts) and
//    records it as planned_request, status 'planned'. DRY-RUN ONLY: nothing is
//    sent to StubHub. Sending needs an operator WriteAuthorization (Hard Rule
//    #2) and seller credentials; see EXP docs/marketplace/stubhub/README.md.
//    A mapping problem (no venue city, ...) marks the row 'failed' with the
//    reason, which the event editor shows the organizer.
//
// 2. Automatiq listings. Why this is the "it's both" path: D1's storefront
//    reads TEvo/EVO "owned" inventory, and Automatiq distributes INTO EVO, so
//    listing an org's primary inventory via Automatiq surfaces it in the D1
//    storefront AND the wider secondary ecosystem from one push.
//    bridge_event_xref.tevo_event_id links the resulting EVO listing back to
//    the Exos primary for buy-routing + dedupe.
//    ⚠ GATED: the actual Automatiq/Lysted listing call is a forbidden upstream
//    WRITE without explicit operator authorization (Hard Rule #2) + provider
//    creds. This pass is skipped until AUTOMATIQ_API_KEY is set, and the
//    listing call is a clearly marked TODO.
//
// Auth: cron-secret gated (Hard Rule #7: burns a paid upstream API + mutates).
//
// Required secrets (operator, when activated): CRON_SECRET, SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY, AUTOMATIQ_API_KEY (pass 2 only). Per-org
// distribution creds (e.g. lystedSellerId) live in exos_org_secrets.distribution.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { ListingMappingError, planStubHubEventRequest, type ExosEventRow } from "../_shared/stubhub-event.ts";

const BATCH = 25;

interface DistRow {
  id: string;
  event_id: string;
  org_id: string;
  channel: string;
  requested_qty: number | null;
  unit_price: number | null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const stubhub = await planStubHubEvents(sb);
    const automatiq = await pushAutomatiq(sb);
    return json({ stubhub, automatiq });
  } catch (e) {
    console.error("exos-distribute failed", e);
    return json({ error: String(e) }, 500);
  }
});

// ── 1. StubHub event requests (dry-run) ──────────────────────────────

interface StubHubRow {
  id: string;
  updated_at: string;
  exos_events: ExosEventRow | null;
}

async function planStubHubEvents(sb: SupabaseClient) {
  const { data, error } = await sb
    .from("exos_distribution_listings")
    .select("id, updated_at, exos_events(name, starts_at, venue_name, venue_location, venue_address)")
    .eq("channel", "stubhub")
    .eq("status", "pending")
    .order("updated_at", { ascending: true })
    .limit(BATCH);
  if (error) throw new Error(`read pending stubhub rows: ${error.message}`);

  let planned = 0;
  let failed = 0;
  for (const row of (data ?? []) as unknown as StubHubRow[]) {
    const now = new Date().toISOString();
    let patch: Record<string, unknown>;
    try {
      if (!row.exos_events) throw new ListingMappingError("event not found");
      patch = { status: "planned", planned_request: planStubHubEventRequest(row.exos_events), error: null };
      planned++;
    } catch (e) {
      const reason = e instanceof ListingMappingError ? e.message : `unexpected: ${String(e)}`;
      patch = { status: "failed", planned_request: null, error: reason.slice(0, 500) };
      failed++;
    }
    // Only if the row hasn't been re-queued meanwhile: an organizer edit
    // bumps updated_at, and that newer request wins on the next run.
    const { error: upErr } = await sb
      .from("exos_distribution_listings")
      .update({ ...patch, last_synced_at: now, updated_at: now })
      .eq("id", row.id)
      .eq("status", "pending")
      .eq("updated_at", row.updated_at);
    if (upErr) console.error("exos-distribute: stubhub row update failed", row.id, upErr);
  }
  return { mode: "dry-run", pending: data?.length ?? 0, planned, failed };
}

// ── 2. Automatiq listings (gated scaffold) ───────────────────────────

async function pushAutomatiq(sb: SupabaseClient) {
  const automatiqKey = Deno.env.get("AUTOMATIQ_API_KEY");
  if (!automatiqKey) {
    // Inert until the operator activates distribution (creds + Hard Rule #2 sign-off).
    return { skipped: "AUTOMATIQ_API_KEY unset (gated)" };
  }

  const { data: pending, error } = await sb
    .from("exos_distribution_listings")
    .select("id, event_id, org_id, channel, requested_qty, unit_price")
    .eq("status", "pending")
    .neq("channel", "stubhub")
    .limit(BATCH);
  if (error) throw new Error(`read pending automatiq rows: ${error.message}`);

  const rows = (pending ?? []) as DistRow[];
  let listed = 0;
  let failed = 0;

  for (const row of rows) {
    await sb.from("exos_distribution_listings")
      .update({ status: "listing", last_synced_at: new Date().toISOString() })
      .eq("id", row.id);
    try {
      // TODO(operator/A1): call Automatiq/Lysted to create the listing for this
      // event on `row.channel`, using AUTOMATIQ_API_KEY + the org's
      // exos_org_secrets.distribution creds. On success capture the external
      // listing id; for EVO, also record the resulting tevo_event_id into
      // bridge_event_xref so D1 routes the buy back to the Exos primary.
      throw new Error("automatiq integration not wired (scaffold)");
      // const ext = await automatiqCreateListing(...);
      // await sb.from("exos_distribution_listings").update({ status:"listed",
      //   external_listing_id: ext.id, last_synced_at: new Date().toISOString(),
      //   error: null }).eq("id", row.id);
      // listed++;
    } catch (e) {
      await sb.from("exos_distribution_listings")
        .update({ status: "failed", error: String(e).slice(0, 500), last_synced_at: new Date().toISOString() })
        .eq("id", row.id);
      failed++;
    }
  }

  return { pending: rows.length, listed, failed, note: "scaffold: listing call not wired" };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
