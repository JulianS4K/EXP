// exos-distribute — push Exos primary inventory to distribution channels
// (Automatiq/Lysted -> EVO/SeatGeek/StubHub) (D4 "Toast for tickets" SCAFFOLD).
//
// Three passes, each independent:
//
// 0. Event links (link.ts). Published, upcoming events are linked to their
//    event on each marketplace the organizer ticked, with a read-only catalog
//    search (_shared/marketplace; StubHub today). Close calls go to staff as
//    'review'. Writes exos_channel_event_links only.
//
// 1. Marketplace event rows (migs 20260926190000 / 20260927030000 / 040000).
//    Publishing an event with StubHub / SeatGeek / Gametime / GoTickets /
//    Vivid Seats ticked queues an event row
//    (no ticket type) per marketplace.
//    StubHub: if the event is already linked to a StubHub event, the plan just
//    records that: nothing to create. If a possible match waits on staff, the
//    row says so; if the catalog hasn't been searched yet, it waits for pass
//    0. Otherwise this pass builds the PUT /sellerevents body
//    (_shared/marketplace/stubhub) and records it as planned_request, status
//    'planned'. A mapping problem (no venue city, ...) marks the row 'failed'
//    with the reason, which the event editor shows the organizer.
//    SeatGeek has no event creation: the row records which SeatGeek event the
//    listings attach to (the link), or that they carry the event name and
//    venue for SeatGeek to match. Vivid Seats is the same: a linked event's
//    id goes on the listings as productionId, else Vivid's mapping team
//    matches them from the event name, venue and venue-local time. Gametime
//    has neither creation nor search: its listings always carry the event
//    name, venue and date.
//
// 1b. Listings, per allocation (a ticket type's seats set aside for a
//    marketplace with exos_set_channel_allocation). For published events,
//    each allocation's listings are planned: the same Exos listings on every
//    marketplace (_shared/marketplace/exosListing.ts: blocks of at most
//    maxPerOrder, each a run of the allocation's internal seat numbers, with
//    a stable "ex…" listing id), in that marketplace's fields,
//    and diffed against what the marketplace has (listed_snapshot):
//    create / update / delete (_shared/marketplace/sync.ts). Re-planned
//    every run, so listings follow price / limit / allocation / sale changes.
//    An allocation being pulled back ('delisting') gets a delist plan; one
//    with nothing on the marketplace is released at once.
//    Each marketplace holds a small pool (mig 20260928010000): 2 x max per
//    order at a time, topped up after each sale and here on every run
//    (exos_refill_channel_pools), up to the organizer's cap. A live listing
//    waiting to shrink is planned at list_qty (the lowest seats) while the
//    rest stay held until the marketplace confirms.
//    Scarcity mode (mig 20260928040000): 3 hours before doors every pool
//    goes to 0 (day-of sales are Exos's); marketplaces that sell are
//    reloaded first, stagnant ones aren't; near sellout pools shrink to one
//    order's worth and Exos keeps one order's worth for itself.
//
// 1c. The Gametime inventory file: Gametime takes listings only as a CSV of
//    the account's whole inventory (FTP), re-sent at least every six hours.
//    Every run plans the complete file; it is never sent (see below).
//
//    DRY-RUN ONLY: plans go in planned_request / planned_listing and nothing
//    is sent to a marketplace. Sending needs an operator WriteAuthorization
//    (Hard Rule #2) and seller credentials; see EXP docs/marketplace/.
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
// SUPABASE_SERVICE_ROLE_KEY. Optional: STUBHUB_ENV / STUBHUB_CLIENT_ID /
// STUBHUB_CLIENT_SECRET (catalog reads, pass 0), SEATGEEK_CLIENT_ID
// (SeatGeek Platform event search, pass 0), VIVID_API_TOKEN /
// VIVID_INTEGRATOR_TOKEN (Vivid Seats event search, pass 0),
// AUTOMATIQ_API_KEY (pass 2). Per-org distribution creds (e.g.
// lystedSellerId) live in exos_org_secrets.distribution.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { ListingMappingError, planStubHubEventRequest, type ExosEventRow } from "../_shared/marketplace/stubhub/eventRequest.ts";
import { channelsFromEnv } from "../_shared/marketplace/channels.ts";
import { planStubHubListing, type AllocationForListing } from "../_shared/marketplace/stubhub/listingPlan.ts";
import { planSeatGeekListings } from "../_shared/marketplace/seatgeek/listingPlan.ts";
import { planDelist, syncListings } from "../_shared/marketplace/sync.ts";
import { planGametimeListings, type GametimeCsvRow } from "../_shared/marketplace/gametime/inventory.ts";
import { GametimeWriter } from "../_shared/marketplace/gametime/writer.ts";
import { planGoTicketsListings } from "../_shared/marketplace/gotickets/listingPlan.ts";
import { planVividListings } from "../_shared/marketplace/vivid/listingPlan.ts";
import { linkEvents } from "./link.ts";

const BATCH = 25;

type MarketChannel = "stubhub" | "seatgeek" | "gametime" | "gotickets" | "vivid";
const MARKET_CHANNELS: MarketChannel[] = ["stubhub", "seatgeek", "gametime", "gotickets", "vivid"];
const LABEL: Record<MarketChannel, string> = { stubhub: "StubHub", seatgeek: "SeatGeek", gametime: "Gametime", gotickets: "GoTickets", vivid: "Vivid Seats" };

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
    const channels = channelsFromEnv((k) => Deno.env.get(k));
    const links = await linkEvents(sb, channels);
    const events = await planEventRows(sb, {
      stubhub: !!channels.get("stubhub")?.findEvents,
      seatgeek: !!channels.get("seatgeek")?.findEvents,
      gametime: false,
      gotickets: false,
      vivid: !!channels.get("vivid")?.findEvents,
    });
    // Top every marketplace pool back up to its size, with free seats only
    // (mig 20260928010000): picks up seats freed since the last sale.
    const { data: refilled, error: rErr } = await sb.rpc("exos_refill_channel_pools");
    if (rErr) console.error("exos-distribute: pool refill failed", rErr.message);
    const stubhub = await syncChannel(sb, "stubhub");
    const seatgeek = await syncChannel(sb, "seatgeek");
    const gametime = await syncChannel(sb, "gametime");
    const gotickets = await syncChannel(sb, "gotickets");
    const vivid = await syncChannel(sb, "vivid");
    const gametimeFile = await planGametimeInventory(sb);
    const automatiq = await pushAutomatiq(sb);
    return json({ links, events, pools_refilled: refilled ?? null, listings: { stubhub, seatgeek, gametime, gotickets, vivid }, gametime_file: gametimeFile, automatiq });
  } catch (e) {
    console.error("exos-distribute failed", e);
    return json({ error: String(e) }, 500);
  }
});

// ── 1. Marketplace event rows (dry-run) ──────────────────────────────

interface EventRow {
  id: string;
  event_id: string;
  channel: MarketChannel;
  updated_at: string;
  exos_events: ExosEventRow | null;
}

type Link = { event_id: string; channel: string; status: string; external_event_id: string | null };

// How an unlinked marketplace finds the event from a listing.
const MATCHED_ON: Record<MarketChannel, string> = {
  stubhub: "event name + venue",
  seatgeek: "event name + venue",
  gametime: "event name + venue + date",
  gotickets: "GoTickets maps it (event name + venue + time, StubHub / SeatGeek ids)",
  vivid: "Vivid's mapping team (event name + venue + venue-local time)",
};

// canSearch: the marketplace's event search is configured, so an event with
// no link row yet hasn't been searched: it waits for pass 0 instead of
// risking a duplicate StubHub event (or listings on the wrong SeatGeek event).
async function planEventRows(sb: SupabaseClient, canSearch: Record<string, boolean>) {
  const { data, error } = await sb
    .from("exos_distribution_listings")
    .select("id, event_id, channel, updated_at, exos_events(name, starts_at, occurs_at_local, venue_name, venue_location, venue_address)")
    .in("channel", MARKET_CHANNELS)
    .is("tier_id", null)
    .eq("status", "pending")
    .order("updated_at", { ascending: true })
    .limit(BATCH);
  if (error) throw new Error(`read pending event rows: ${error.message}`);
  const rows = (data ?? []) as unknown as EventRow[];

  const { data: links, error: lErr } = rows.length
    ? await sb.from("exos_channel_event_links").select("event_id, channel, status, external_event_id")
      .in("channel", MARKET_CHANNELS).in("event_id", rows.map((r) => r.event_id))
    : { data: [], error: null };
  if (lErr) throw new Error(`read marketplace links: ${lErr.message}`);
  const linkBy = new Map(((links ?? []) as Link[]).map((l) => [`${l.channel}:${l.event_id}`, l]));

  const counts = { mode: "dry-run", pending: rows.length, planned: 0, linked: 0, waiting: 0, failed: 0 };
  for (const row of rows) {
    const now = new Date().toISOString();
    const label = LABEL[row.channel];
    const link = linkBy.get(`${row.channel}:${row.event_id}`);
    let patch: Record<string, unknown>;
    if (link && (link.status === "linked" || link.status === "created") && link.external_event_id) {
      // The marketplace already has this event: nothing to create. The id
      // stays in the plan, not in external_event_id (that column means the
      // marketplace has something of ours), so the row still follows edits.
      patch = { status: "planned", planned_request: { linked: true, external_event_id: link.external_event_id }, error: null };
      counts.linked++;
    } else if (link?.status === "review") {
      patch = {
        status: "failed",
        planned_request: null,
        error: row.channel === "stubhub"
          ? "StubHub may already have this event: confirm the match or reject it before a new one is requested"
          : `${label} may already have this event: confirm the match or reject it so the listings attach to the right event`,
      };
      counts.waiting++;
    } else if (!link && canSearch[row.channel]) {
      counts.waiting++;
      continue; // not searched yet: leave it pending for the next run's pass 0
    } else if (row.channel !== "stubhub") {
      // No event creation on the others: listings carry the event as text.
      patch = {
        status: "planned",
        planned_request: { linked: false, catalog_checked: !!link, matched_on: MATCHED_ON[row.channel] },
        error: null,
      };
      counts.planned++;
    } else {
      try {
        if (!row.exos_events) throw new ListingMappingError("event not found");
        // catalog_checked: a StubHub search found nothing (vs search not configured).
        const plan = planStubHubEventRequest(row.exos_events);
        patch = { status: "planned", planned_request: { ...plan, catalog_checked: !!link }, error: null };
        counts.planned++;
      } catch (e) {
        const reason = e instanceof ListingMappingError ? e.message : `unexpected: ${String(e)}`;
        patch = { status: "failed", planned_request: null, error: `${label}: ${reason}`.slice(0, 500) };
        counts.failed++;
      }
    }
    // Only if the row hasn't been re-queued meanwhile: an organizer edit
    // bumps updated_at, and that newer request wins on the next run.
    const { error: upErr } = await sb
      .from("exos_distribution_listings")
      .update({ ...patch, last_synced_at: now, updated_at: now })
      .eq("id", row.id)
      .eq("status", "pending")
      .eq("updated_at", row.updated_at);
    if (upErr) console.error("exos-distribute: event row update failed", row.id, upErr);
  }
  return counts;
}

// ── 1b. Listings per allocation: create / update / delist (dry-run) ──

interface AllocationRow {
  id: string;
  event_id: string;
  status: string;
  requested_qty: number | null;
  unit_price: number | string | null;
  external_listing_id: string | null;
  internal_seats: string | null;
  list_qty: number | null;
  listed_snapshot: unknown;
  planned_listing: unknown;
  /** Scarcity mode (mig 20260928040000): closed | stagnant | scarce | selling | normal | fixed. */
  exos_pool_state: string | null;
  exos_events: AllocationForListing["event"] & { timezone?: string | null; status?: string };
  exos_ticket_tiers: AllocationForListing["tier"];
}

// Why a pool holds nothing to list (scarcity mode, mig 20260928040000).
function emptyPoolReason(state: string | null, label: string): string {
  if (state === "closed") return `marketplace sales closed 3 hours before doors: Exos sells the rest, ${label} listings come down`;
  if (state === "stagnant") return `no ${label} sale lately and seats are short: they went back to Exos`;
  return `nothing held: no free seats for ${label} right now`;
}

const EVENT_FIELDS = "name, status, starts_at, occurs_at_local, timezone, venue_name, venue_location, venue_address, currency, purchase_limits";

async function syncChannel(sb: SupabaseClient, channel: MarketChannel) {
  const counts = { mode: "dry-run", allocations: 0, create: 0, update: 0, unchanged: 0, failed: 0, delist: 0, released: 0 };

  // Live and to-be-listed allocations of published events.
  const { data, error } = await sb
    .from("exos_distribution_listings")
    .select("id, event_id, status, requested_qty, list_qty, unit_price, external_listing_id, internal_seats, listed_snapshot, planned_listing, exos_pool_state, " +
      `exos_events!inner(${EVENT_FIELDS}), exos_ticket_tiers(name, price, section_label)`)
    .eq("channel", channel)
    .not("tier_id", "is", null)
    // Holding seats, or allowed to (a pool at 0 while Exos has none free).
    .or("requested_qty.gt.0,sell_cap.gt.0")
    .in("status", ["pending", "planned", "failed", "listing", "listed"])
    .eq("exos_events.status", "published")
    .limit(200);
  if (error) throw new Error(`read ${channel} allocations: ${error.message}`);
  const rows = (data ?? []) as unknown as AllocationRow[];
  counts.allocations = rows.length;

  if (rows.length) {
    const { data: links } = await sb.from("exos_channel_event_links").select("event_id, external_event_id")
      .eq("channel", channel).in("status", ["linked", "created"]).in("event_id", rows.map((r) => r.event_id));
    const linked = new Map(((links ?? []) as Array<{ event_id: string; external_event_id: string }>).map((l) => [l.event_id, l.external_event_id]));
    // GoTickets maps listings to its events itself; the StubHub / SeatGeek ids help it.
    const crossLinks = new Map<string, { stubhub?: string; seatgeek?: string }>();
    if (channel === "gotickets") {
      const { data: other } = await sb.from("exos_channel_event_links").select("event_id, channel, external_event_id")
        .in("channel", ["stubhub", "seatgeek"]).in("status", ["linked", "created"]).in("event_id", rows.map((r) => r.event_id));
      for (const l of (other ?? []) as Array<{ event_id: string; channel: "stubhub" | "seatgeek"; external_event_id: string }>) {
        crossLinks.set(l.event_id, { ...crossLinks.get(l.event_id), [l.channel]: l.external_event_id });
      }
    }

    for (const r of rows) {
      let plan: unknown;
      try {
        if ((r.list_qty ?? r.requested_qty ?? 0) <= 0) {
          // Empty pool: nothing to list now; anything live comes down (it refills when seats free up).
          plan = syncListings({
            channel, listings: [], per_order_cap: 0,
            unresolved: [emptyPoolReason(r.exos_pool_state, LABEL[channel])],
          }, r.listed_snapshot);
        } else if (channel === "stubhub") {
          const p = planStubHubListing({
            id: r.id, requested_qty: r.requested_qty, unit_price: r.unit_price,
            tier: r.exos_ticket_tiers, event: r.exos_events, stubhubEventId: linked.get(r.event_id) ?? null,
            internal_seats: r.internal_seats, list_qty: r.list_qty,
            previous: r.listed_snapshot ?? r.planned_listing,
          });
          plan = syncListings(p, r.listed_snapshot);
        } else if (channel === "seatgeek") {
          const p = planSeatGeekListings({
            id: r.id, requested_qty: r.requested_qty, unit_price: r.unit_price,
            tier: r.exos_ticket_tiers, event: r.exos_events, seatgeekEventId: linked.get(r.event_id) ?? null,
            internal_seats: r.internal_seats, list_qty: r.list_qty,
            previous: r.listed_snapshot ?? r.planned_listing,
          });
          plan = syncListings(p, r.listed_snapshot);
        } else if (channel === "vivid") {
          const p = planVividListings({
            id: r.id, requested_qty: r.requested_qty, unit_price: r.unit_price,
            tier: r.exos_ticket_tiers, event: r.exos_events, vividProductionId: linked.get(r.event_id) ?? null,
            internal_seats: r.internal_seats, list_qty: r.list_qty,
            previous: r.listed_snapshot ?? r.planned_listing,
          });
          plan = syncListings(p, r.listed_snapshot);
        } else if (channel === "gotickets") {
          const x = crossLinks.get(r.event_id) ?? {};
          const p = planGoTicketsListings({
            id: r.id, requested_qty: r.requested_qty, unit_price: r.unit_price,
            tier: r.exos_ticket_tiers, event: r.exos_events,
            internal_seats: r.internal_seats, list_qty: r.list_qty,
            previous: r.listed_snapshot ?? r.planned_listing,
            stubhubEventId: x.stubhub ?? null, seatgeekEventId: x.seatgeek ?? null,
          });
          plan = syncListings(p, r.listed_snapshot);
        } else {
          const p = planGametimeListings({
            id: r.id, requested_qty: r.requested_qty, unit_price: r.unit_price,
            tier: r.exos_ticket_tiers, event: r.exos_events,
            internal_seats: r.internal_seats, list_qty: r.list_qty,
            previous: r.listed_snapshot ?? r.planned_listing,
          });
          plan = syncListings(p, r.listed_snapshot);
        }
        const action = (plan as { action: string }).action;
        if (action === "create") counts.create++;
        else if (action === "update") counts.update++;
        else counts.unchanged++;
      } catch (e) {
        plan = { error: String(e instanceof Error ? e.message : e).slice(0, 300) };
        counts.failed++;
      }
      if (JSON.stringify(plan) === JSON.stringify(r.planned_listing)) continue;
      const { error: upErr } = await sb.from("exos_distribution_listings").update({ planned_listing: plan }).eq("id", r.id);
      if (upErr) console.error(`exos-distribute: ${channel} planned_listing not stored`, r.id, upErr.message);
    }
  }

  // Pulled back: delist what the marketplace has, then the seats come back.
  const { data: pulled, error: pErr } = await sb
    .from("exos_distribution_listings")
    .select("id, external_listing_id, listed_snapshot, planned_listing")
    .eq("channel", channel)
    .not("tier_id", "is", null)
    .eq("status", "delisting")
    .limit(200);
  if (pErr) throw new Error(`read ${channel} delistings: ${pErr.message}`);
  for (const r of (pulled ?? []) as Array<Pick<AllocationRow, "id" | "external_listing_id" | "listed_snapshot" | "planned_listing">>) {
    const plan = planDelist(channel, r.listed_snapshot)
      // Live by its marketplace id but no record of the listings: a person takes it down.
      ?? (r.external_listing_id ? { action: "delist", error: `live on ${LABEL[channel]} with no snapshot of its listings: take it down by hand` } : null);
    if (!plan) {
      // Nothing on the marketplace after all: release now.
      const { error: relErr } = await sb.from("exos_distribution_listings")
        .update({ status: "delisted", requested_qty: 0, internal_seats: "{}", planned_listing: null, updated_at: new Date().toISOString() })
        .eq("id", r.id).eq("status", "delisting");
      if (relErr) console.error(`exos-distribute: ${channel} release failed`, r.id, relErr.message);
      else counts.released++;
      continue;
    }
    counts.delist++;
    if (JSON.stringify(plan) === JSON.stringify(r.planned_listing)) continue;
    const { error: upErr } = await sb.from("exos_distribution_listings").update({ planned_listing: plan }).eq("id", r.id);
    if (upErr) console.error(`exos-distribute: ${channel} delist plan not stored`, r.id, upErr.message);
  }
  return counts;
}

// ── 1c. The Gametime inventory file (dry-run) ─────────────────────
//
// Gametime takes listings only as a CSV of the account's whole inventory on
// its FTP server, re-sent at least every six hours or every listing on the
// account is switched off. So every run builds the complete file from every
// planned Gametime listing of a published event. GametimeWriter plans the
// upload and refuses to send it unless the account is confirmed to hold Exos
// listings only (dedicatedAccount), and the FTP upload itself isn't built.

async function planGametimeInventory(sb: SupabaseClient) {
  const { data, error } = await sb
    .from("exos_distribution_listings")
    .select("planned_listing, exos_events!inner(status)")
    .eq("channel", "gametime")
    .not("tier_id", "is", null)
    .gt("requested_qty", 0)
    .in("status", ["pending", "planned", "listing", "listed"])
    .eq("exos_events.status", "published")
    .limit(5000);
  if (error) throw new Error(`read gametime inventory: ${error.message}`);
  const rows = ((data ?? []) as Array<{ planned_listing: { listings?: Array<{ request: { body: GametimeCsvRow } }> } | null }>)
    .flatMap((r) => r.planned_listing?.listings ?? [])
    .map((l) => l.request.body);
  const planned = new GametimeWriter().uploadInventory(rows).planned;
  return { mode: "dry-run", listings: rows.length, bytes: planned.csv?.length ?? 0, target: planned.url, sent: false };
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
    // StubHub, SeatGeek, Gametime, GoTickets and Vivid Seats are listed directly (passes 1b / 1c), not via Automatiq.
    .not("channel", "in", "(stubhub,seatgeek,gametime,gotickets,vivid)")
    .is("tier_id", null)
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
